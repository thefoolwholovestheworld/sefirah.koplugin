-- Blume-Verse — source générée par Sefirah Source Hub (modèle sans IA). À relire et tester.
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local BASE   = "https://blume-verse.com"
local SEARCH = "https://blume-verse.com/wp-json/wp/v2/search?search={q}&per_page=20&page={page}"
local LISTP  = "/series/"
local CONTS  = { "epcontent", "entry-content", "reader-area", "sersys",
    "reading-content", "chapter-content", "chapter_body", "chapter-body", "text-left" }
local CONT   = "entry-content"
-- lien de fiche : /series/<slug>/ (pas /series/ tout seul, pas un chapitre)
local function is_series(h)
    local p = h:gsub("^https?://[^/]+", ""):gsub("[?#].*$", "")
    return p:match("^/series/[^/]+/?$") ~= nil
end
-- lien de chapitre : contient « chapter » et n'est pas une fiche /series/
local function is_chapter(h)
    local p = h:gsub("^https?://[^/]+", ""):gsub("[?#].*$", ""):lower()
    return not p:match("^/series/") and (p:find("chapter", 1, true) ~= nil or p:match("^/[^/]+%-%d+/?$") ~= nil)
end
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 15 })
    if body and #body > 2 then return body end
    logger.warn("Blume-Verse: échec", url, tostring(code))
    return nil, tostring(code)
end

-- ===== décodage des entités HTML (&#x27; &#39; &amp; &eacute; …) en une seule passe =====
local function cp2utf8(c)
    if not c or c <= 0 or c > 0x10FFFF then return nil end
    if c < 0x80 then return string.char(c) end
    if c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
    if c < 0x10000 then return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64) end
    return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64, 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end
local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    rsquo = "’", lsquo = "‘", ldquo = "“", rdquo = "”", hellip = "…", ndash = "–", mdash = "—", laquo = "«", raquo = "»",
    eacute = "é", egrave = "è", ecirc = "ê", euml = "ë", agrave = "à", acirc = "â", ccedil = "ç", icirc = "î", iuml = "ï",
    ocirc = "ô", ugrave = "ù", ucirc = "û", uuml = "ü", oelig = "œ", Eacute = "É", Egrave = "È", Agrave = "À", Ccedil = "Ç" }
local function dec(s)
    if not s then return s end
    return (s:gsub("&(#?%w+);", function(e)
        local n = e:match("^#[xX](%x+)$")
        if n then return cp2utf8(tonumber(n, 16)) end
        n = e:match("^#(%d+)$")
        if n then return cp2utf8(tonumber(n)) end
        return ENT[e]
    end))
end
local function txt(h)
    h = (h or ""):gsub("<[^>]+>", " ")
    h = dec(h):gsub("%s+", " ")
    return (h:match("^%s*(.-)%s*$"))
end
local NL = string.char(10)
local function para(h) -- texte avec paragraphes (descriptions)
    h = (h or ""):gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    h = h:gsub("</p>", NL .. NL):gsub("<br%s*/?>", NL):gsub("<[^>]+>", "")
    h = dec(h):gsub(string.char(13), ""):gsub(" +", " ")
    h = h:gsub(" *" .. NL .. " *", NL):gsub(NL .. NL .. "+", NL .. NL)
    return (h:match("^%s*(.-)%s*$"))
end

local function attr(tag, n)
    local k = "%f[%w_%-]" .. n:gsub("%-", "%%-") .. "%s*=%s*"
    return tag:match(k .. '"([^"]*)"') or tag:match(k .. "'([^']*)'")
end
local function abs(u) if not u then return nil end if u:sub(1,2)=="//" then return "https:"..u end if u:sub(1,1)=="/" then return BASE..u end return u end
local function enc(s) return (tostring(s):gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", c:byte()) end)) end
local function rel(h) return (h:gsub("^"..BASE:gsub("%p","%%%0"), "")) end
-- clé de comparaison d'un lien : sans domaine, sans ?query, sans # ni / final, en minuscules
local function norm(h)
    h = h:gsub("^https?://[^/]+", ""):gsub("[?#].*$", ""):gsub("/+$", "")
    return h:lower()
end
-- /_next/image?url=XXX&w=… (Next.js) -> l'image d'origine XXX
local function unnext(u)
    local q = u:match("/_next/image%?url=([^&]+)")
    if not q then return u end
    return (q:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src", "srcset" }) do
        local u = attr(img, k)
        if k == "srcset" and u then u = u:match("^%s*(%S+)") end
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true) and not u:lower():find("blank", 1, true) then
            return abs(unnext(dec(u)))
        end
    end
    return nil
end

-- première <img> de classe ts-post-image (couverture sur ce thème)
local function ts_img(html)
    for img in html:gmatch("<img[^>]->") do
        local c = attr(img, "class")
        if c and c:find("ts-post-image", 1, true) then return img end
    end
    return nil
end

-- contenu (équilibré) de la balise ouverte en position "from" : gère les <div> imbriquées
local function inner(html, from, tn)
    local open, close = "<" .. tn, "</" .. tn
    local depth, p = 1, from
    while true do
        local a = html:find(open, p, true)
        local b = html:find(close, p, true)
        if not b then return nil end
        if a and a < b then
            if not html:sub(a + #open, a + #open):match("%w") then depth = depth + 1 end
            p = a + #open
        else
            if not html:sub(b + #close, b + #close):match("%w") then
                depth = depth - 1
                if depth == 0 then return html:sub(from, b - 1) end
            end
            p = b + #close
        end
    end
end
-- premier élément (div, article, section…) dont la classe contient cls ; renvoie son contenu complet
local function grab(html, cls)
    local pos = 1
    while true do
        local s, e, tn, attrs = html:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s then return nil end
        local c = attr(attrs, "class")
        if c and c:find(cls, 1, true) then
            local out = inner(html, e + 1, tn)
            if out and #out > 50 then return out end
        end
        pos = e + 1
    end
end

-- Libellés d'interface du site (badges, boutons de mode) : ce n'est JAMAIS un titre d'œuvre.
-- Ex. « Text Mode » : lien/badge présent dans certaines cartes, qui servait de titre à tort.
local UI_LABELS = {
    ["text mode"] = true, ["image mode"] = true, ["dark mode"] = true, ["light mode"] = true,
    ["list mode"] = true, ["grid mode"] = true, ["reading mode"] = true, ["night mode"] = true,
    ["text"] = true, ["image"] = true, ["novel"] = true, ["novels"] = true, ["new"] = true,
    ["hot"] = true, ["read"] = true, ["read now"] = true, ["read more"] = true, ["bookmark"] = true,
    ["completed"] = true, ["ongoing"] = true, ["hiatus"] = true, ["popular"] = true,
    ["latest"] = true, ["premium"] = true, ["adult"] = true, ["18+"] = true, ["end"] = true,
    ["series"] = true, ["view"] = true,
}
local function bad_title(n)
    if not n then return true end
    local l = n:lower():gsub("[%s_%-]+", " "):match("^%s*(.-)%s*$")
    return l == "" or UI_LABELS[l] == true
end
-- retire un libellé d'interface collé au début ou à la fin d'un vrai titre
local function clean_title(n)
    n = n or ""
    for _, lab in ipairs({ "text mode", "image mode" }) do
        local l = n:lower()
        if l:sub(1, #lab + 1) == lab .. " " then n = n:sub(#lab + 2) end
        l = n:lower()
        if #n > #lab + 1 and l:sub(-(#lab + 1)) == " " .. lab then n = n:sub(1, #n - #lab - 1) end
    end
    return (n:match("^%s*(.-)%s*$"))
end
-- dernier recours : titre déduit de l'adresse (/series/mon-titre/ -> « Mon Titre »)
local function slug_name(href)
    local s = href:gsub("^https?://[^/]+", ""):gsub("[?#].*$", ""):match("^/series/([^/]+)")
    if not s then return "" end
    s = s:gsub("%-", " ")
    return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end
-- titre porté par un <h1-6> ou un élément de classe « tt » / « title » dans la carte
local function title_in(h)
    local t = h:match("<h%d[^>]*>(.-)</h%d>")
    if t then
        local x = txt(t)
        if x ~= "" and not bad_title(x) then return x end
    end
    for _, at, body in h:gmatch("<(%a%w*)(%s[^>]*)>(.-)</%1>") do
        local c = attr(at, "class")
        if c then
            local cl = " " .. c:lower() .. " "
            if cl:find(" tt ", 1, true) or cl:find("title", 1, true) then
                local x = txt(body)
                if x ~= "" and #x < 200 and not bad_title(x) then return x end
            end
        end
    end
    return nil
end
-- clé de comparaison : lettres/chiffres ASCII en minuscules (« Wrong Meal! » -> « wrongmeal »)
local function key(s) return ((s or ""):lower():gsub("[^%w]", "")) end
-- mémorise un nom candidat pour une œuvre (rang : 4 titre > 3 title/alt > 1 texte brut)
local function consider(it, name, rank)
    name = clean_title(dec(name or ""))
    if bad_title(name) then return end
    it.cands = it.cands or {}
    it.cands[#it.cands + 1] = { name = name, rank = rank }
end
-- Choix du vrai titre. L'adresse (/series/wrong-meal/) est la seule chose fiable :
-- un candidat qui lui correspond gagne toujours. Sinon on écarte tout libellé répété
-- sur plusieurs œuvres de la page (= bouton/badge du site) ou contenant « mode ».
local function pick_name(it, freq, total)
    local sk = key(slug_name(it.path))
    local best, bscore
    if sk ~= "" then
        for _, c in ipairs(it.cands or {}) do
            local ck = key(c.name)
            local exact = ck == sk
            local ok = exact or ck:find(sk, 1, true)
                or (#ck >= 4 and sk:find(ck, 1, true) and #ck >= 0.7 * #sk)
            if ok then
                local sc = (exact and 10 or 0) + c.rank
                if not bscore or sc > bscore then best, bscore = c.name, sc end
            end
        end
        if best then return best end
    end
    for _, c in ipairs(it.cands or {}) do
        local repeated = total >= 3 and (freq[key(c.name)] or 0) >= 2
        local uimode = c.name:lower():find("%f[%a]mode%f[%A]") ~= nil
        if not repeated and not uimode and (not bscore or c.rank > bscore) then
            best, bscore = c.name, c.rank
        end
    end
    return best or slug_name(it.path)
end

local function parse_list(html)
    local out, idx = {}, {}
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_series(href) then
            local k = norm(href)
            local img = inner_html:match("<img[^>]->")
            local it = idx[k]
            if not it then -- première fois qu'on voit cette œuvre
                it = { name = "", path = rel(href), rank = -1 }
                idx[k] = it
                out[#out+1] = it
            end
            -- même œuvre vue plusieurs fois (badge, cover, titre…) : le meilleur nom l'emporte
            consider(it, title_in(inner_html), 4)
            consider(it, attr(tag, "title"), 3)
            consider(it, img and attr(img, "alt"), 3)
            consider(it, txt(inner_html), 1)
            if not it.cover then it.cover = cover_of(img) end
        end
    end
    -- combien d'œuvres différentes portent le même libellé ? (un bouton du site se répète)
    local freq = {}
    for _, it in ipairs(out) do
        local seen = {}
        for _, c in ipairs(it.cands or {}) do
            local k = key(c.name)
            if not seen[k] then seen[k] = true; freq[k] = (freq[k] or 0) + 1 end
        end
    end
    local res = {}
    for _, it in ipairs(out) do
        it.name = pick_name(it, freq, #out)
        it.rank, it.cands = nil, nil
        -- faux roman « List Mode » / « Text Mode » : on le retire de la liste
        local kn, ks = key(it.name), key(slug_name(it.path))
        local banned = kn == "listmode" or ks == "listmode" or kn == "textmode" or ks == "textmode"
        if it.name ~= "" and not banned then res[#res+1] = it end
    end
    return res
end

-- ===== FILTRES : l'adresse de la liste est construite à partir des choix de l'utilisateur =====
-- Une valeur vide ou « all » = pas de filtre : le paramètre est retiré de l'adresse.
local BROWSE = ""
local FJOIN  = {  }

local POPULAR_FILTERS = {
    { key = "genre", label = "Genre", default = "all", multi = false,
      options = {
        { id = "all", label = "Tous" },
        { id = "first-love", label = "First Love" },
        { id = "historical-omegaverse", label = "Historical Omegaverse" },
        { id = "novel-to-manhwa", label = "Novel to Manhwa" },
        { id = "comedy-gag", label = "Comedy/Gag" },
        { id = "misunderstanding-misconception", label = "Misunderstanding/Misconception" },
        { id = "college-students", label = "College Students" },
        { id = "confinement", label = "Confinement" },
        { id = "dimension-travel", label = "Dimension Travel" },
        { id = "dragon", label = "Dragon" },
        { id = "battleromance", label = "BattleRomance" },
        { id = "harem", label = "Harem" },
        { id = "mystery-thriller", label = "Mystery/Thriller" },
        { id = "school-campus", label = "School/Campus" },
        { id = "bittersweet-poignant", label = "Bittersweet/Poignant" },
        { id = "cohabitation-spouse", label = "Cohabitation/Spouse" },
        { id = "dimensiontravel-soulswap", label = "DimensionTravel/SoulSwap" },
        { id = "fantasy", label = "Fantasy" },
        { id = "firstlove", label = "FirstLove" },
        { id = "fluff-sweetness", label = "Fluff/Sweetness" },
        { id = "forbiddenrelationship", label = "ForbiddenRelationship" },
        { id = "jealousy", label = "Jealousy" },
        { id = "loveandhate", label = "LoveAndHate" },
        { id = "misunderstanding-delusion", label = "Misunderstanding/Delusion" },
        { id = "nonhumanentity", label = "NonHumanEntity" },
        { id = "plot-heavy", label = "Plot-heavy" },
        { id = "reverseheightgap", label = "ReverseHeightGap" },
        { id = "royalty-nobility", label = "Royalty/Nobility" },
        { id = "salvation", label = "Salvation" },
        { id = "western", label = "Western" },
        { id = "hunter", label = "Hunter" },
        { id = "misunderstanding", label = "Misunderstanding" },
        { id = "modern", label = "Modern" },
        { id = "revenge", label = "Revenge" },
        { id = "superpowers", label = "Superpowers" },
        { id = "timeregression", label = "TimeRegression" },
        { id = "omegaverse", label = "Omegaverse" },
        { id = "politics-society-chaebol", label = "Politics/Society/Chaebol" },
        { id = "slice-of-life", label = "Slice of Life" },
        { id = "contract", label = "Contract" },
        { id = "dimension-transfer-soul-swap", label = "Dimension Transfer/Soul Swap" },
        { id = "living-together-spouse", label = "Living Together/Spouse" },
        { id = "one-night-stand", label = "One Night Stand" },
        { id = "salvation-rescue", label = "Salvation/Rescue" },
        { id = "tragedy-angst", label = "Tragedy/Angst" },
        { id = "agegap", label = "AgeGap" },
        { id = "healing", label = "Healing" },
        { id = "modernfantasy", label = "ModernFantasy" },
        { id = "nonhumanexistence", label = "NonHumanExistence" },
        { id = "sliceoflife", label = "SliceOfLife" },
        { id = "sweet", label = "Sweet" },
        { id = "beautiful-gong", label = "Beautiful Gong" },
        { id = "capable-shou", label = "Capable Shou" },
        { id = "childish-gong", label = "Childish Gong" },
        { id = "coldblooded-gong", label = "Coldblooded Gong" },
        { id = "crybaby-gong", label = "Crybaby Gong" },
        { id = "degrading-gong", label = "Degrading Gong" },
        { id = "dimensioncrossing-soulswap", label = "DimensionCrossing/SoulSwap" },
        { id = "emperor-gong", label = "Emperor Gong" },
        { id = "gentle-gong", label = "Gentle Gong" },
      } },
    { key = "status", label = "Status", default = "all", multi = false,
      options = {
        { id = "all", label = "Tous" },
        { id = "ongoing", label = "En cours" },
        { id = "completed", label = "Terminé" },
        { id = "hiatus", label = "En pause" },
        { id = "cancelled", label = "Abandonné" },
      } },
}

local function split(s, sep)
    local t, i = {}, 1
    while true do
        local a = s:find(sep, i, true)
        if not a then t[#t + 1] = s:sub(i); break end
        t[#t + 1] = s:sub(i, a - 1)
        i = a + 1
    end
    return t
end
-- valeur choisie pour un filtre (nil si vide ou « all »)
local function fval(sel, key)
    local v = sel and sel[key]
    if v == nil or v == "" or v == "all" then return nil end
    return tostring(v)
end
-- remplace {genre}, {page}, {q}… dans une adresse ; retire ce qui dépend d'un filtre vide
local function expand(tpl, sel, term, page)
    tpl = tpl:gsub("#.*$", "")
    local origin, rest = tpl:match("^(https?://[^/?]+)(.*)$")
    if not origin then origin, rest = "", tpl end
    local path, query = rest:match("^([^?]*)%??(.*)$")
    local function sub(s)
        local ok = true
        local r = s:gsub("{([%w_%-]+)}", function(k)
            if k == "page" then return tostring(page or 1) end
            if k == "q" then return enc(term or "") end
            local v = fval(sel, k)
            if not v then ok = false; return "" end
            local t = {}
            for x in v:gmatch("[^,]+") do t[#t + 1] = enc(x) end
            return table.concat(t, ",")
        end)
        return r, ok
    end
    local segs = {}
    for _, seg in ipairs(split(path, "/")) do
        local r, ok = sub(seg)
        if ok then segs[#segs + 1] = r end
    end
    local out = origin .. table.concat(segs, "/")
    local ps = {}
    if query ~= "" then
        for _, p in ipairs(split(query, "&")) do
            local name, key = p:match("^([^=]*)={([%w_%-]+)}$")
            local v = (key and key ~= "page" and key ~= "q") and fval(sel, key) or nil
            if v and FJOIN[key] == "rep" and v:find(",", 1, true) then
                for x in v:gmatch("[^,]+") do ps[#ps + 1] = name .. "=" .. enc(x) end
            else
                local r, ok = sub(p)
                if ok then ps[#ps + 1] = r end
            end
        end
    end
    if #ps > 0 then out = out .. "?" .. table.concat(ps, "&") end
    return out
end
local function browse_url(page, options)
    local sel = options and options.filters
    page = tonumber(page) or 1
    local genre, status = fval(sel, "genre"), fval(sel, "status")
    local q = {}
    if status then q[#q + 1] = "status=" .. enc(status) end
    if genre then
        local u = BASE .. "/genre/" .. enc(genre) .. "/"
        if page > 1 then u = u .. "page/" .. page .. "/" end
        return u .. (#q > 0 and ("?" .. table.concat(q, "&")) or "")
    end
    table.insert(q, 1, "page=" .. page)
    q[#q + 1] = "order=popular"
    return BASE .. "/series/?" .. table.concat(q, "&")
end

local ext = { id = "blumeverse", name = "Blume-Verse", site = BASE, lang = "en", version = "0.1.4",
    popularFilters = POPULAR_FILTERS, searchFilters = {}, hasReviews = false, chapterCommentsPanel = false }

function ext:popularNovels(page, options)
    local html, err = get(browse_url(page, options))
    if not html then return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    local url = expand(SEARCH, options and options.filters, term, page)
    local html, err = get(url)
    if not html then return { novels = {}, error = "Recherche impossible (" .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

local function meta(html, path)
    local t = html:match("<h1[^>]*>(.-)</h1>")
    local name = t and txt(t) or ""
    if name == "" then name = dec(html:match('property="og:title"[^>]-content="([^"]*)"') or "") end
    if name == "" then name = path end

    -- Sources multiples : og > meta/twitter > HTML > JSON-LD
    local og = html:match('property="og:description"[^>]-content="([^"]*)"')
        or html:match('content="([^"]*)"[^>]-property="og:description"')
        or ""
    og = dec(og)

    local summary = og
    local candidates = {}

    -- 1) Classes connues (Madara + thèmes custom : summary__content, description-summary…)
    for _, k in ipairs({
        "manga-excerpt", "summary__content", "description-summary",
        "summary-content", "entry-summary", "series-summary",
        "series-synops", "novel-synops", "synops", "synopsis",
        "summary", "description", "resume", "story", "desc", "excerpt"
    }) do
        local b = grab(html, k)
        if b then
            local d = para(b)
            local dlow = d:lower()
            local nlinks = select(2, b:gsub("<a%s", ""))
            -- évite menus / listes de liens / titres de chapitres
            if #d > 60 and #d < 8000 and nlinks <= 5
               and not dlow:find("^chapitre%s")
               and not dlow:find("^chapter%s")
               and not dlow:find("^episode%s")
               and not dlow:find("^synopsis%s*$") then
                candidates[#candidates+1] = d
            end
        end
    end

    -- 2) JSON-LD structuré
    for ld in html:gmatch('<script[^>]*application/ld%+json[^>]*>(.-)</script>') do
        local desc = ld:match('"description"%s*:%s*"([^"]+)"')
        if desc and #desc > 60 then candidates[#candidates+1] = dec(desc) end
    end

    -- 3) meta name="description" et twitter:description (souvent plus complets que og)
    local md = dec(html:match('name="description"[^>]-content="([^"]*)"') or "")
    if md ~= "" and md ~= og and #md > 60 then candidates[#candidates+1] = md end
    local tw = dec(html:match('name="twitter:description"[^>]-content="([^"]*)"') or "")
    if tw ~= "" and tw ~= og and tw ~= md and #tw > 60 then candidates[#candidates+1] = tw end

    -- Certains modèles Blume-Verse affichent le synopsis en paragraphes
    -- directement après le titre, sans classe CSS dédiée reconnue ci-dessus.
    -- Dans ce cas, on lit les paragraphes situés entre le titre et les genres.
    if #summary < 60 then
        local h1_end = html:find("</h1>", 1, true)
        if h1_end then
            local stop = html:find('class="sertogenre"', h1_end + 5, true)
                or html:find("Bookmark", h1_end + 5, true)
                or (#html + 1)
            local section = html:sub(h1_end + 5, stop - 1)
            local paragraphs = {}
            for p in section:gmatch("<p[^>]*>(.-)</p>") do
                local d = para(p)
                local low = d:lower()
                if #d > 40
                    and not low:find("released", 1, true)
                    and not low:find("views", 1, true)
                    and not low:find("bookmark", 1, true)
                    and not low:find("followed", 1, true) then
                    paragraphs[#paragraphs + 1] = d
                end
            end
            local fallback = table.concat(paragraphs, NL .. NL)
            if #fallback > #summary then summary = fallback end
        end
    end

    -- On garde la plus longue (donc la plus complète)
    for _, c in ipairs(candidates) do
        if #c > #summary then summary = c end
    end

    local status = ""
    local st = html:match('class="sertostat"[^>]*>(.-)</div>')
    if st then status = txt(st) end
    local genres = {}
    local gb = html:match('class="sertogenre"[^>]*>(.-)</div>')
    if gb then for g in gb:gmatch("<a%s[^>]*>(.-)</a>") do local x = txt(g); if x ~= "" then genres[#genres + 1] = x end end end
    local cover = html:match('property="og:image"[^>]-content="([^"]*)"')
    cover = cover and abs(dec(cover)) or nil
    if not cover then
        local th = grab(html, "thumb")
        cover = cover_of(th and ts_img(th)) or cover_of(ts_img(html))
    end
    return { name = name, path = path,
        cover = cover,
        summary = summary, description = summary,
        author = "", status = status, genres = genres }
end

function ext:parseNovelMeta(path)
    local m = ext:parseNovel(path); if not m then return nil end
    m.total_chapters = #(m.chapters or {}); return m
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = meta(html, path), {}, {}
    local zone = grab(html, "eplister") or grab(html, "chapterlist") or html
    for tag, inner_html in zone:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_chapter(href) and not seen[norm(href)] then
            seen[norm(href)] = true
            local name = ""
            local ti = inner_html:match('class="epl%-title"[^>]*>(.-)</div>')
            if ti then name = txt(ti) end
            if name == "" then name = txt(inner_html) end
            if name == "" then name = dec(attr(tag, "title") or "") end
            if name == "" then name = "Chapitre " .. (#ch + 1) end
            -- Le thème peut exposer des liens de compte (ex. « Register »)
            -- dans la page. Ils ne sont pas des chapitres, même si leur URL
            -- contient un mot ressemblant à « chapter ».
            local lname = name:lower():gsub("%s+", " "):match("^%s*(.-)%s*$")
            local lhref = href:lower():gsub("[?#].*$", "")
            local is_account_link = lname == "register" or lname == "login"
                or lname == "sign up" or lname == "subscribe" or lname == "bookmark"
                or lhref:find("/register", 1, true) ~= nil
                or lhref:find("/login", 1, true) ~= nil
            if not is_account_link then
                ch[#ch+1] = { name = name, path = rel(href) }
            end
        end
    end
    -- tri croissant d'après le numéro dans l'adresse (si présent partout)
    local all = #ch > 0
    for i, c in ipairs(ch) do
        c.i = i
        local a = c.path:lower():match("%-(%d+)/?$")
        c.num = a and tonumber(a) or nil
        if not c.num then all = false end
    end
    if all then table.sort(ch, function(x, y) if x.num ~= y.num then return x.num < y.num end return x.i < y.i end) end
    for i, c in ipairs(ch) do c.chapter_number = i end
    m.chapters, m.totalPages, m.total_chapters = ch, 1, #ch
    return m
end

function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapitre injoignable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    -- 1) le conteneur de classe CONT (balise quelconque, <div> imbriquées gérées)
    local body
    for _, k in ipairs(CONTS) do
        local b = grab(html, k)
        if b then
            local n = select(2, b:gsub("<p%f[%s>]", ""))
            local plain = txt(b)
            -- Certains chapitres sont découpés en div/span plutôt qu'en p.
            if #plain > 300 and ((n >= 3 and #b > 500) or #plain > 1200) then
                body = b; break
            end
        end
    end
    -- 2) repli : tous les paragraphes <p> de la page
    if not body then
        local ps, n = {}, 0
        for p in html:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
            local t = txt(p)
            if #t > 1 then ps[#ps+1] = "<p>" .. p .. "</p>"; n = n + #t end
        end
        if #ps >= 3 and n > 300 then body = table.concat(ps) end
    end
    if not body or #body < 50 then return "<p>Texte du chapitre introuvable.</p>" end
    return body
end

-- ===== MOTEUR WORDPRESS REST : recherche JSON =====
local function wp_json(s)
    local ok_j, J = pcall(require, "rapidjson")
    if not ok_j then J = require("json") end
    local ok, d = pcall(J.decode, s)
    if ok then return d end
    return nil
end
function ext:searchNovels(term, page)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page) end
    local body, err = get(BASE .. "/wp-json/wp/v2/search?search=" .. enc(term) .. "&per_page=20&page=" .. tostring(tonumber(page) or 1) .. "&_fields=id,title,url")
    local data = body and wp_json(body)
    if type(data) ~= "table" then return { novels = {}, error = "Recherche REST impossible (" .. tostring(err) .. ")" } end
    local out = {}
    for _, n in ipairs(data) do
        if type(n) == "table" and type(n.url) == "string" and is_series(n.url) then
            out[#out + 1] = { name = dec(tostring(n.title or n.url)), path = rel(n.url) }
        end
    end
    return { novels = out }
end

return ext