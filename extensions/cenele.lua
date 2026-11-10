-- cenele — source générée par Sefirah Source Hub (modèle sans IA). À relire et tester.
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local BASE   = "https://cenele.com"
local SEARCH = "https://cenele.com/?s={q}&post_type=wp-manga"
local LISTP  = "/cont/"
local CHAPP  = "%d8%a7%d9%84%d9%81%d8%b5%d9%84-" -- « الفصل- » encodé (minuscules)
local CONT   = "reading-content"
local CONT2  = { "text-left", "entry-content", "chapter-content", "c-blog-post" }
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local UA2 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
local last_err = "?"
local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local net = require("core.net")
    local tries = {
        { ["User-Agent"] = UA, ["Referer"] = BASE .. "/", ["Accept"] = "text/html,application/xhtml+xml,*/*;q=0.8", ["Accept-Language"] = "ar,en;q=0.8" },
        { ["User-Agent"] = UA2, ["Accept"] = "text/html,application/xhtml+xml,*/*;q=0.8", ["Accept-Language"] = "ar,en;q=0.8" },
    }
    for _, h in ipairs(tries) do
        local body, code = net.get(url, { headers = h, timeout = 15 })
        if body and #body > 2 then return body end
        last_err = tostring(code)
        logger.warn("cenele: échec", url, last_err)
    end
    return nil, last_err
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
local function encurl(u)
    u = u:gsub("([^%w%-%._~:/?#%[%]@!$&'()*+,;=%%])", function(c) return string.format("%%%02X", c:byte()) end)
    return (u:gsub("%-150x150(%.%w+)$", "%1"))
end
local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src", "srcset" }) do
        local u = attr(img, k)
        if k == "srcset" and u then u = u:match("^%s*(%S+)") end
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true) and not u:lower():find("blank", 1, true) then
            return encurl(abs(unnext(dec(u))))
        end
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

local LISTN = LISTP:lower()
local function is_novel_path(k) -- k = lien normalisé ; vrai seulement pour /cont/<slug>
    if k:sub(1, #LISTN) ~= LISTN then return false end
    local rest = k:sub(#LISTN + 1)
    return rest ~= "" and not rest:find("/", 1, true)
end

local function parse_list(html)
    local out, idx = {}, {}
    local pos = 1
    while true do
        local s1, e1, tag, inner_html = html:find("(<a%s[^>]->)(.-)</a>", pos)
        if not s1 then break end
        pos = e1 + 1
        local href = attr(tag, "href")
        local k = href and norm(href)
        if k and is_novel_path(k) then
            local img = inner_html:match("<img[^>]->")
            if not img then -- image placée juste avant le lien (ex. classement « رواية معززة »)
                local before = html:sub(math.max(1, s1 - 600), s1 - 1)
                local last = 0
                for q in before:gmatch("()</a>") do last = q end
                local seg = before:sub(last + 1)
                for im in seg:gmatch("<img[^>]->") do img = im end
            end
            local name = img and attr(img, "alt")
            if not name or name == "" then
                local st = inner_html:match("<strong[^>]*>(.-)</strong>")
                if st and txt(st) ~= "" then name = txt(st) end
            end
            if not name or name == "" then name = attr(tag, "title") end
            if name and name ~= "" then name = dec(name) else name = txt(inner_html) end
            local cover = cover_of(img)
            local it = idx[k]
            if it then
                if it.name == "" and name ~= "" then it.name = name end
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name, path = rel(href), cover = cover }
                idx[k] = it
                out[#out+1] = it
            end
        end
    end
    local res = {}
    for _, it in ipairs(out) do if it.name ~= "" then res[#res+1] = it end end
    return res
end

local function meta(html, path)
    local t = html:match("<h1[^>]*>(.-)</h1>")
    local name = t and txt(t) or ""
    if name == "" then name = dec(html:match('property="og:title"[^>]-content="([^"]*)"') or "") end
    if name == "" then name = path end
    local og = html:match('property="og:description"[^>]-content="([^"]*)"')
        or html:match('content="([^"]*)"[^>]-property="og:description"')
        or html:match('name="description"[^>]-content="([^"]*)"') or ""
    og = dec(og)
    local summary = og
    -- description souvent tronquée (« … ») dans og:description : on cherche la version complète dans la page
    if og == "" or og:sub(-3) == "..." or og:sub(-3) == "…" or #og < 200 then
        local head = (og:gsub("%s+", " ")):sub(1, 25)
        for _, k in ipairs({ "synopsis", "summary", "description", "resume", "story", "desc" }) do
            local b = grab(html, k)
            if b and select(2, b:gsub("<a%s", "")) <= 3 then
                local d = para(b)
                if #d > #og and #d > 60 and #d < 4000 and (head == "" or (d:gsub("%s+", " ")):find(head, 1, true)) then
                    summary = d
                    break
                end
            end
        end
    end
    return { name = name, path = path,
        cover = (function() local c = abs(dec(html:match('property="og:image"[^>]-content="([^"]*)"') or "")); return c and c ~= "" and encurl(c) or nil end)(),
        summary = summary, author = "", status = "", genres = {} }
end

local ext = { id = "cenele", name = "cenele", site = BASE, lang = "ar", version = "0.3.3",
    popularFilters = {}, searchFilters = {}, hasReviews = false, chapterCommentsPanel = false }

-- le site injecte des textes anti-copie (« هذا التطبيق يسرق… » + code hexadécimal, lettres étirées par des tatweel)
local TATWEEL = string.char(0xD9, 0x80)
local function bad_text(t)
    if t:find("انطوت الصفحة", 1, true) then return true end
    if select(2, t:gsub(TATWEEL, "")) >= 6 then return true end
    if t:match("^%s*%x%x%x%x%x%x%x%x%x%x%s*$") then return true end
    return false
end
-- Retire les éléments inutiles (navigation, infos du chapitre, pub appli, avertissement final).
local NAV = { "السابق", "التالي", "صفحة الرواية", "Report a problem", "تنويه" }
local JUNK = { "عدد الكلمات", "تاريخ النشر", "Google Play", "تطبيق فضاء", "جميع ما يتم ترجمته",
    "استغفر الله وأتوب", "Report a problem", "إبلاغ عن مشكلة",
    "قراءة أسرع", "غوغل بلاي", "تنبيهات الفصول", "الدخول للتصويت", "روايات مشابهة", "اكتب تعليق", "أضف تعليق" }
local function is_junk(t)
    if t == "" or #t > 900 then return false end
    for _, w in ipairs(JUNK) do if t:find(w, 1, true) then return true end end
    if t:sub(1, #"مانهوا") == "مانهوا" and #t < 80 then return true end
    if t:find("من%s*[%d,٬%.]+%s*فصل") and #t < 200 then return true end          -- « الفصل 3238 من 3,241 فصل »
    if t:find("^المجلد%s*%d+") and #t < 200 then return true end                  -- « المجلد 13 : … »
    if t:find("←", 1, true) and #t < 120 then return true end                     -- cartes « روايات مشابهة »
    if #t < 40 and (t:find("^قبل%s+%d*%s*%S+$") or t:find("^منذ%s+%d*%s*%S+$")) then return true end -- « قبل 6 ساعات »
    local r = t
    for _, w in ipairs(NAV) do r = r:gsub(w:gsub("%p", "%%%0"), "") end
    return (r:gsub("[%s%p]", "")) == ""
end
local STRIP_TAGS = { a = 1, span = 1, p = 1, li = 1, ul = 1, ol = 1, nav = 1, div = 1, section = 1,
    small = 1, strong = 1, em = 1, b = 1, h1 = 1, h2 = 1, h3 = 1, h4 = 1, h5 = 1, h6 = 1, blockquote = 1, button = 1, header = 1, footer = 1 }
local function strip_junk(h)
    local out, pos = {}, 1
    while true do
        local s, e, tn = h:find("<(%a%w*)[^>]*>", pos)
        if not s then break end
        local ltn = tn:lower()
        local c = STRIP_TAGS[ltn] and inner(h, e + 1, ltn)
        if c and (c:find("<p[%s>]") or c:find("<div[%s>]") or c:find("<ul[%s>]") or c:find("<li[%s>]")
            or c:find("<section[%s>]") or c:find("<h%d") or c:find("<blockquote")) then c = nil end
        if c and is_junk(txt(c)) then
            out[#out + 1] = h:sub(pos, s - 1)
            local close_e = h:find(">", e + 1 + #c, true)
            pos = (close_e or (e + #c)) + 1
        else
            out[#out + 1] = h:sub(pos, e)
            pos = e + 1
        end
    end
    out[#out + 1] = h:sub(pos)
    return table.concat(out)
end
local TAIL = { "rspc", "nhv-reco", "nhv-comments", "comment-respond", 'id="comments"', "nhv-gems", "nhv-novel-support" }
local function cut_tail(h)
    local best
    for _, m in ipairs(TAIL) do
        local i = h:find(m, 1, true)
        if i and (not best or i < best) then best = i end
    end
    if not best then return h end
    local lt = best
    while lt > 1 and h:sub(lt, lt) ~= "<" do lt = lt - 1 end
    if lt < 200 then return h end -- sécurité : ne jamais vider le chapitre
    return h:sub(1, lt - 1)
end
local function clean_chapter(h)
    h = cut_tail(h)
    h = strip_junk(h)
    h = h:gsub(">([^<]+)<", function(t) if bad_text(t) then return "><" end end)
    h = h:gsub("<blockquote[^>]*>%s*</blockquote>", ""):gsub("<p[^>]*>%s*</p>", "")
    return h
end

function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapitre injoignable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    local body = grab(html, CONT)
    if not body then for _, c in ipairs(CONT2) do body = grab(html, c); if body then break end end end
    if not body then
        local ps, n = {}, 0
        for p in html:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
            local t = txt(p)
            if #t > 1 and not bad_text(t) then ps[#ps+1] = "<p>" .. p .. "</p>"; n = n + #t end
        end
        if #ps >= 3 and n > 300 then body = table.concat(ps) end
    end
    if not body or #body < 50 then return "<p>Texte du chapitre introuvable.</p>" end
    return clean_chapter(body)
end

-- ===== MOTEUR MADARA (WordPress), adapté à cenele : œuvres sous /cont/ =====
local function m_list_url(page, order)
    local p = tonumber(page) or 1
    return BASE .. "/cont/" .. (p > 1 and ("page/" .. p .. "/") or "") .. "?m_orderby=" .. order
end

function ext:popularNovels(page)
    local p = tonumber(page) or 1
    local list, err = {}, nil
    for _, u in ipairs({ m_list_url(p, "views"), m_list_url(p, "latest") , BASE .. "/cont/" .. (p > 1 and ("page/" .. p .. "/") or "") }) do
        local html, e = get(u)
        if html then list = parse_list(html) else err = e end
        if #list > 0 then break end
    end
    if #list == 0 and p == 1 then -- repli : accueil
        local h2, e2 = get("/")
        if h2 then list = parse_list(h2) else err = e2 end
    end
    if #list == 0 then return { novels = {}, error = "Site injoignable (" .. tostring(err or last_err) .. ")" } end
    return { novels = list }
end

local function rest_search(term, p)
    local ok, json = pcall(require, "json")
    if not ok then return {} end
    local body = get("/wp-json/wp/v2/search?search=" .. enc(term) .. "&per_page=20&page=" .. p)
    if not body then return {} end
    local ok2, arr = pcall(json.decode, body)
    if not ok2 or type(arr) ~= "table" then return {} end
    local res = {}
    for _, it in ipairs(arr) do
        if type(it) == "table" and it.url and is_novel_path(norm(it.url)) then
            res[#res + 1] = { name = dec(it.title or ""), path = rel(it.url) }
        end
    end
    return res
end

function ext:searchNovels(term, page)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page) end
    local p = tonumber(page) or 1
    local html = get(BASE .. (p > 1 and ("/page/" .. p) or "") .. "/?s=" .. enc(term) .. "&post_type=wp-manga")
    local list = html and parse_list(html) or {}
    if #list == 0 then -- repli : recherche REST de WordPress
        list = rest_search(term, p)
    end
    return { novels = list }
end

local function m_meta(html, path)
    local m = meta(html, path)
    local sm = grab(html, "summary__content") or grab(html, "description-summary")
    if sm then local d = para(sm); if #d > 40 then m.summary = d end end
    local a = html:match('/cont%-author/[^"]*"[^>]*>(.-)</a>') or html:match('class="author%-content"[^>]*>(.-)</div>')
    if a then m.author = txt(a) end
    local seen = {}
    for x in html:gmatch('href="[^"]*/cont%-genre/[^"]*"[^>]*>(.-)</a>') do
        local g = txt(x)
        if g ~= "" and g ~= "الروايات المكتملة" and not seen[g] then seen[g] = true; m.genres[#m.genres + 1] = g end
    end
    return m
end

function ext:parseNovelMeta(path)
    local html, e = get(path); if not html then error("Cenele : page injoignable (" .. tostring(e) .. ") " .. tostring(path)) end
    local m = m_meta(html, path); m.total_chapters = 0; return m
end

local MCH = CHAPP:lower()
local function m_collect(html, path, seen, ch)
    local pk = norm(path)
    for tag, ih in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href then
            local k = norm(href)
            if not seen[k] and k ~= pk and k:find(pk, 1, true) and k:find(MCH, 1, true) then
                seen[k] = true
                local name = txt(ih)
                if name == "" then name = dec(attr(tag, "title") or "") end
                if name == "" then name = "Chapitre " .. (#ch + 1) end
                ch[#ch + 1] = { name = name, path = rel(href) }
            end
        end
    end
end

local function m_post(url, body)
    local net = require("core.net")
    if type(net.post) ~= "function" then return nil end
    local ok, b = pcall(net.post, url, body, { timeout = 20, headers = {
        ["User-Agent"] = UA, ["Referer"] = BASE .. "/", ["X-Requested-With"] = "XMLHttpRequest",
        ["Content-Type"] = "application/x-www-form-urlencoded" } })
    if ok and type(b) == "string" and #b > 20 then return b end
    return nil
end

-- liste complète : Madara charge les chapitres en AJAX (la page n'en montre que 8)
local function m_ajax(html, path)
    local rp = path:gsub("^https?://[^/]+", ""):gsub("/+$", "")
    local tries = { { BASE .. rp .. "/ajax/chapters/", "" } }
    local id = html:match("postid%-(%d+)") or html:match('"manga_id"%s*:%s*"?(%d+)') or html:match('data%-id="(%d+)"')
        or html:match("[?&]p=(%d+)")
    if id then tries[#tries + 1] = { BASE .. "/wp-admin/admin-ajax.php", "action=manga_get_chapters&manga=" .. id } end
    local nonce = html:match('chaptersNonce"%s*:%s*"(%w+)"')
    if id and nonce then
        for _, act in ipairs({ "nhv_novel_chapters", "nhv_get_chapters", "nhv_load_chapters", "nhv_novel_v2_chapters" }) do
            tries[#tries + 1] = { BASE .. "/wp-admin/admin-ajax.php", "action=" .. act .. "&nonce=" .. nonce .. "&post_id=" .. id .. "&manga=" .. id }
        end
    end
    for _, t in ipairs(tries) do
        local body = m_post(t[1], t[2])
        if body and body:sub(1, 1) == "{" then body = body:gsub('\\"', '"'):gsub("\\/", "/"):gsub("\\u(%x%x%x%x)", function(h) return cp2utf8(tonumber(h, 16)) end) end
        if body then
            local ch = {}
            m_collect(body, path, {}, ch)
            if #ch > 0 then return ch end
        end
    end
    return nil
end

local function ch_num(x)
    local n = norm(x.path):match("%-(%d+%.?%d*)$") or (x.name or ""):match("(%d+%.?%d*)%s*$")
    return tonumber(n)
end

function ext:parseNovel(path)
    local html, e = get(path); if not html then error("Cenele : page injoignable (" .. tostring(e) .. ") " .. tostring(path)) end
    local m = m_meta(html, path)
    local ch = m_ajax(html, path)
    if not ch then ch = {}; m_collect(html, path, {}, ch) end

    -- repli ultime : la page n'a donné que les derniers chapitres -> on reconstruit 1..N (romans sans volumes)
    if #ch > 0 and #ch <= 12 then
        -- liste incomplète (le site charge les vrais chapitres en AJAX) : on reconstruit 1..N
        -- en gardant les vrais liens trouvés (ex. volume dans l'URL) quand on les a.
        local mx, real = 0, {}
        for _, x in ipairs(ch) do
            local n = ch_num(x)
            if n then real[n] = x; if n > mx then mx = n end end
        end
        if mx > #ch then
            local base = path:gsub("^https?://[^/]+", ""):gsub("/+$", "")
            local gen = {}
            for i = 1, mx do gen[#gen + 1] = real[i] or { name = "الفصل " .. i, path = base .. "/" .. CHAPP .. i .. "/" } end
            ch = gen
        end
    end

    -- tri croissant par numéro si les numéros sont tous présents et uniques ; sinon on inverse si la liste est décroissante
    local nums, dup, all = {}, false, true
    for i, x in ipairs(ch) do
        local n = ch_num(x); x._i = i; x._n = n
        if not n then all = false elseif nums[n] then dup = true else nums[n] = true end
    end
    if all and not dup then
        table.sort(ch, function(a, b) if a._n ~= b._n then return a._n < b._n end return a._i < b._i end)
    else
        local a, b = ch[1] and ch[1]._n, ch[#ch] and ch[#ch]._n
        if (a and b and a > b) or not (a and b) then
            for i = 1, math.floor(#ch / 2) do ch[i], ch[#ch + 1 - i] = ch[#ch + 1 - i], ch[i] end
        end
    end
    for i, x in ipairs(ch) do x.chapter_number = i; x._i = nil; x._n = nil end
    m.chapters, m.totalPages = ch, 1
    return m
end

return ext
