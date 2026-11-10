-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- Archive of Our Own (AO3) extension for Sefirah
-- Site: https://archiveofourown.org
--
-- Age gate:
--   Mature/Explicit works show an age confirmation page. Appending
--   ?view_adult=true to any work URL bypasses it — no WebView needed.
--
-- Pas de couverture sur AO3 : le logo AO3 (resources/ao3_cover.png) sert de
-- couverture par défaut (URL « local: » comprise par core/epub.lua).
--
-- v2.0 : ouverture directe sur les fandoms (cases, sans réseau), liste d'œuvres lue sur
-- les pages de tag /tags/<tag>/works (défaut : Sherlock Holmes & Related
-- Fandoms), cache mémoire des pages, erreurs explicites au lieu d'une liste
-- vide silencieuse, dernier HTML inattendu dans sefirah/ao3_last_error.txt.
--
-- Login-restricted works ("Registered users only") cannot be read without an
-- AO3 session ; parseChapter returns a readable message instead of a blank page.
--
-- Filtres « Parcourir » (ui/browse.lua : ext.popularFilters) :
--   chaque groupe est à choix unique et se traduit en paramètre de
--   /works/search (work_search[...]). Voir POPULAR_FILTERS / build_browse_url.
--
-- Chapter list strategy (3 méthodes, dans l'ordre) :
--   1. Liste déroulante (#chapter_index) de la page du roman
--   2. Titres inline (#chapters h3.title a)
--   3. /works/<id>/navigate (index complet) si le roman a > 1 chapitre
--   4. Repli : roman à chapitre unique, l'URL du roman sert de chapitre

local BASE   = "https://archiveofourown.org"
local logger = require("logger")
local T      = require("core.i18n").T

-- ── HTML helpers ──────────────────────────────────────────────────────────────

-- KOReader tourne sur LuaJIT (pas de bibliothèque utf8) : encodage manuel.
local function utf8_encode(cp)
    if not cp then return "" end
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + (math.floor(cp / 0x40) % 0x40), 0x80 + (cp % 0x40))
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
                       0x80 + (math.floor(cp / 0x1000) % 0x40),
                       0x80 + (math.floor(cp / 0x40) % 0x40), 0x80 + (cp % 0x40))
end

local function strip_tags(s)
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&#x(%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);",  function(d) return utf8_encode(tonumber(d)) end)
    s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
    return s:match("^%s*(.-)%s*$")
end

local function extract_div(html, open_pattern, start_pos)
    local s, e = html:find(open_pattern, start_pos or 1)
    if not s then return nil, nil end
    local tag_end = html:find('>', e)
    if not tag_end then return nil, nil end
    local depth, pos = 1, tag_end + 1
    while depth > 0 and pos <= #html do
        local open_pos  = html:find('<div', pos, true)
        local close_pos = html:find('</div>', pos, true)
        if not close_pos then break end
        if open_pos and open_pos < close_pos then
            depth = depth + 1
            pos   = open_pos + 4
        else
            depth = depth - 1
            if depth == 0 then
                return html:sub(tag_end + 1, close_pos - 1), close_pos + 6
            end
            pos = close_pos + 6
        end
    end
    return nil, nil
end

-- ── HTTP helper ───────────────────────────────────────────────────────────────

-- Même identité de navigateur que scribblehub.lua : l'UA « KOReader » nu est
-- une cause probable de refus (403) côté AO3, qui se traduisait par une liste vide.
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local _plugin_dir = ((debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+/[^/]+%.lua$")) or "."
-- Chemin relatif (« plugins/sefirah.koplugin ») : on le rend absolu pour ne pas dépendre
-- du dossier courant du processus (sous-processus de téléchargement des couvertures).
if _plugin_dir:sub(1, 1) ~= "/" then
    local ok_l, l = pcall(require, "libs/libkoreader-lfs")
    local cwd = ok_l and l and l.currentdir and l.currentdir() or nil
    if cwd and cwd ~= "" then
        _plugin_dir = (_plugin_dir == ".") and cwd or (cwd .. "/" .. _plugin_dir)
    end
end
local COVER_URL = "local:" .. _plugin_dir .. "/resources/ao3_cover.png"

local function write_debug(msg)
    pcall(function()
        local dir = require("datastorage"):getSettingsDir() .. "/sefirah"
        require("libs/libkoreader-lfs").mkdir(dir)
        local f = io.open(dir .. "/ao3_last_error.txt", "w")
        if f then f:write(msg); f:close() end
    end)
end

local function http_get(url)
    logger.dbg("AO3: http_get", url)
    local body, code = require("core.net").get(url, {
        headers = {
            ["Accept"] = "text/html,application/xhtml+xml,*/*;q=0.8",
            ["User-Agent"] = UA,
            ["Accept-Language"] = "en-US,en;q=0.7",
        },
        timeout = 15,
        deadline = 30,
    })
    if not body then
        logger.err("AO3: http_get FAILED", url, tostring(code))
        return nil, code
    end
    return body
end

local function url_encode(str)
    return (tostring(str):gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- Nom de tag AO3 → segment d'URL (« / » = *s*, « & » = *a*, « . » = *d*,
-- « # » = *h*, « ? » = *q*).
local function tag_segment(name)
    local s = name:gsub("/", "*s*"):gsub("&", "*a*"):gsub("%.", "*d*")
        :gsub("#", "*h*"):gsub("%?", "*q*")
    return (s:gsub("([^%w%-%_%~%*'!%(%)])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function tag_href(name) return "/tags/" .. tag_segment(name) .. "/works" end

local DEFAULT_TAG_NAME = "Sherlock Holmes & Related Fandoms"
local DEFAULT_TAG_HREF = tag_href(DEFAULT_TAG_NAME)  -- /tags/Sherlock%20Holmes%20*a*%20Related%20Fandoms/works

-- ── URL helpers ───────────────────────────────────────────────────────────────

local function to_url(path)
    if path:match("^https?://") then return path end
    if path:match("^/")        then return BASE .. path end
    return BASE .. "/" .. path
end

-- ?view_adult=true : saute la page de confirmation d'âge.
local function adult_url(path)
    local url = to_url(path)
    return url .. (url:match("%?") and "&" or "?") .. "view_adult=true"
end

-- ── Tag collector ─────────────────────────────────────────────────────────────

-- <dd class="TAGTYPE tags"><ul><li><a class="tag">…  → "a, b, c"
local function collect_tags(html, dd_class)
    local tags = {}
    local dd_pos = html:find('<dd[^>]*class="[^"]*' .. dd_class .. '[^"]*"')
    if not dd_pos then return "" end
    local dd_end = html:find('</dd>', dd_pos)
    if not dd_end then return "" end
    local block = html:sub(dd_pos, dd_end)
    for tag in block:gmatch('<a[^>]*class="[^"]*tag[^"]*"[^>]*>([^<]+)</a>') do
        table.insert(tags, strip_tags(tag))
    end
    return table.concat(tags, ", ")
end

-- ── Liste d'œuvres ────────────────────────────────────────────────────────────

local function fmt_num(s)
    local n = tonumber((tostring(s or ""):gsub("[^%d]", "")))
    if not n then return nil end
    if n >= 1000000 then return (string.format("%.1fM", n / 1e6):gsub("%.0M", "M")) end
    if n >= 1000 then return (string.format("%.1fk", n / 1000):gsub("%.0k", "k")) end
    return tostring(n)
end

local RATING_LETTER = { ["general-audience"] = "G", teen = "T", mature = "M", explicit = "E", notrated = "NR" }

local function clean_summary(bq)
    bq = bq:gsub("<br[^>]*/?>%s*", "\n"):gsub("</p>%s*", "\n\n")
    return (strip_tags(bq):gsub("\n\n\n+", "\n\n"))
end

-- Un résultat = <li id="work_ID" class="work blurb group …"> … </li>.
-- On découpe par position des id="work_…" (les <li> de tags sont imbriqués,
-- donc pas de recherche de </li> fermant).
local function parse_works(html)
    local starts = {}
    for pos, id in html:gmatch('()<li[^>]-id="work_(%d+)"') do
        starts[#starts + 1] = { pos = pos, id = id }
    end
    local novels, seen = {}, {}
    for i, st in ipairs(starts) do
        local stop = starts[i + 1] and (starts[i + 1].pos - 1) or nil
        if not stop then
            stop = html:find("</ol>", st.pos, true) or #html
        end
        local block = html:sub(st.pos, stop)
        -- Œuvre réservée aux membres (cadenas dans le titre) : illisible sans
        -- compte AO3, on ne l'affiche pas dans les listes.
        local restricted = block:find('class="restricted"', 1, true)
            or block:find('alt="(Restricted)"', 1, true)
        if restricted then
            seen[st.id] = true
        elseif not seen[st.id] then
            seen[st.id] = true
            local h4 = block:match("<h4[^>]*>(.-)</h4>") or ""
            local title = h4:match('<a[^>]-href="/works/%d+"[^>]*>(.-)</a>')
            local authors = {}
            for a in h4:gmatch('<a[^>]-rel="author"[^>]*>(.-)</a>') do authors[#authors + 1] = strip_tags(a) end
            local author = #authors > 0 and table.concat(authors, ", ") or "Anonymous"

            local fandom = ""
            local h5 = block:match('<h5[^>]-class="fandoms[^"]*"[^>]*>(.-)</h5>') or ""
            local fl = {}
            for f in h5:gmatch('<a[^>]-class="tag"[^>]*>(.-)</a>') do fl[#fl + 1] = strip_tags(f) end
            fandom = fl[1] or ""

            local rating = RATING_LETTER[block:match('class="rating%-([%a%-]+) rating"') or ""] or ""
            local complete = block:match('complete%-(%a+) iswip')
            local words    = fmt_num(block:match('<dd class="words">(.-)</dd>'))
            local chap     = strip_tags(block:match('<dd class="chapters">(.-)</dd>') or "")
            local kudos    = fmt_num(strip_tags(block:match('<dd class="kudos">(.-)</dd>') or ""))
            local summary  = block:match('<blockquote class="userstuff summary">(.-)</blockquote>')

            local parts = {}
            if rating ~= "" then parts[#parts + 1] = rating end
            parts[#parts + 1] = author
            if words and words ~= "" then parts[#parts + 1] = words .. " " .. T("mots") end
            if chap ~= "" then parts[#parts + 1] = chap .. " ch." end
            if kudos then parts[#parts + 1] = kudos .. " kudos" end

            table.insert(novels, {
                name     = strip_tags(title or ("Work " .. st.id)),
                path     = "works/" .. st.id,
                author   = author,
                cover    = COVER_URL,
                subtitle = table.concat(parts, " · "),
                badge    = complete == "yes" and T("Terminé") or (complete == "no" and T("En cours") or nil),
                fandom   = fandom,
                summary  = summary and clean_summary(summary) or nil,
            })
        end
    end
    -- Repli : ancienne méthode (titres <h4 class="heading">) si le gabarit change.
    if #novels == 0 then
        local pos = 1
        while true do
            local h4_s = html:find('<h4[^>]*class="[^"]*heading[^"]*"', pos)
            if not h4_s then break end
            local h4_e = html:find('</h4>', h4_s)
            if not h4_e then break end
            local block = html:sub(h4_s, h4_e)
            local id, title = block:match('<a[^>]*href="/works/(%d+)"[^>]*>([^<]+)</a>')
            if id and title and not seen[id] then
                seen[id] = true
                local author = block:match('<a[^>]*rel="author"[^>]*>([^<]+)</a>')
                table.insert(novels, { name = strip_tags(title), path = "works/" .. id,
                    author = author and strip_tags(author) or nil, cover = COVER_URL,
                    subtitle = author and strip_tags(author) or "" })
            end
            pos = h4_e + 5
        end
    end
    return novels
end

-- ── Cache mémoire des pages (revenir en arrière = instantané) ────────────────
local _cache, _cache_keys = {}, {}
local CACHE_TTL, CACHE_MAX = 900, 30
local function cache_get(url)
    local e = _cache[url]
    if e and os.time() - e.t < CACHE_TTL then return e.v end
    return nil
end
local function cache_put(url, v)
    if not _cache[url] then
        _cache_keys[#_cache_keys + 1] = url
        if #_cache_keys > CACHE_MAX then _cache[table.remove(_cache_keys, 1)] = nil end
    end
    _cache[url] = { t = os.time(), v = v }
end

-- Récupère + analyse une page de liste. Renvoie { novels = …, error = … }.
local function fetch_list(url)
    local cached = cache_get(url)
    if cached then return { novels = cached } end
    local html, code = http_get(url)
    if not html then
        local c = tostring(code)
        if c == "429" or c == "503" then
            return { novels = {}, error = T("AO3 limite les requêtes (429) — réessaie dans une minute.") }
        end
        return { novels = {}, error = T("AO3 injoignable") .. " (" .. c .. ")" }
    end
    local novels = parse_works(html)
    if #novels > 0 then
        cache_put(url, novels)
        return { novels = novels }
    end
    if html:find("Retry later", 1, true) or html:find("Too Many Requests", 1, true) then
        return { novels = {}, error = T("AO3 limite les requêtes (429) — réessaie dans une minute.") }
    end
    if html:find("Just a moment", 1, true) or html:find("cf%-challenge") then
        return { novels = {}, error = T("AO3 a demandé une vérification (Cloudflare) — réessaie plus tard.") }
    end
    if html:find("No results found", 1, true) or html:find("0 Works", 1, true)
       or html:find("0 %- 0 of 0") then
        return { novels = {}, error = T("Aucune œuvre pour ces critères.") }
    end
    write_debug("Liste vide inattendue pour " .. url .. "\n\n" .. html:sub(1, 4000))
    return { novels = {}, error = T("Page AO3 inattendue (voir sefirah/ao3_last_error.txt).") }
end

-- ── Filtres « Parcourir » ─────────────────────────────────────────────────────
-- Volontairement courts (huit groupes) : l'écran de filtres se construit
-- vite et tient sur peu de pages. Fandom et tag libre : voir l'accueil.

local function opts(list)
    local r = {}
    for _, o in ipairs(list) do r[#r + 1] = { id = o[1], label = T(o[2]) } end
    return r
end

local POPULAR_FILTERS = {
    { key = "sort", label = T("Tri"), default = "revised_at", options = opts({
        { "revised_at",      "Dernière mise à jour" },
        { "hits",            "Plus de vues" },
        { "kudos_count",     "Plus de kudos" },
        { "bookmarks_count", "Plus de favoris" },
        { "comments_count",  "Plus de commentaires" },
        { "created_at",      "Date de publication" },
        { "word_count",      "Nombre de mots" },
    }) },
    { key = "language", label = T("Langue"), default = "", options = opts({
        { "",    "Toutes" },
        { "en",  "Anglais" },
        { "fr",  "Français" },
        { "es",  "Espagnol" },
        { "de",  "Allemand" },
        { "it",  "Italien" },
        { "ptBR","Portugais (Brésil)" },
        { "ru",  "Russe" },
        { "zh",  "Chinois" },
        { "ja",  "Japonais" },
    }) },
    { key = "rating", label = T("Classification"), default = "", options = opts({
        { "",   "Toutes" },
        { "10", "Tout public" },
        { "11", "Ados" },
        { "12", "Adulte" },
        { "13", "Explicite" },
        { "9",  "Non classé" },
    }) },
    { key = "status", label = T("Statut"), default = "", options = opts({
        { "",  "Tous" },
        { "T", "Terminées" },
        { "F", "En cours" },
    }) },
    { key = "category", label = T("Catégorie"), default = "", options = opts({
        { "",     "Toutes" },
        { "116",  "Gen (sans romance)" },
        { "21",   "F/M" },
        { "2246", "M/M" },
        { "22",   "F/F" },
        { "23",   "Multi" },
        { "24",   "Autre" },
    }) },
    { key = "warning", label = T("Avertissements"), default = "", options = opts({
        { "",   "Tous" },
        { "14", "Aucun avertissement" },
        { "17", "Non précisé" },
        { "18", "Violence graphique" },
        { "16", "Mort de personnage majeur" },
        { "19", "Non-consentement" },
        { "20", "Personnage mineur" },
    }) },
    { key = "length", label = T("Longueur"), default = "", options = opts({
        { "",             "Toutes" },
        { "<5000",        "Moins de 5 000 mots" },
        { "5000-20000",   "5 000 – 20 000 mots" },
        { "20000-100000", "20 000 – 100 000 mots" },
        { ">100000",      "Plus de 100 000 mots" },
    }) },
    { key = "updated", label = T("Mise à jour"), default = "", options = opts({
        { "",          "Toutes" },
        { "<1 week",   "Moins d'une semaine" },
        { "<1 month",  "Moins d'un mois" },
        { "<6 months", "Moins de 6 mois" },
        { "<1 year",   "Moins d'un an" },
    }) },
}

-- Filtres de la recherche d'œuvres : mêmes groupes que « Parcourir », mais le tri par
-- défaut est « Meilleure correspondance » (comme le site) et non « Dernière mise à jour ».
local SEARCH_FILTERS = {}
for i, g in ipairs(POPULAR_FILTERS) do
    if g.key == "sort" then
        local o = { { id = "_score", label = T("Meilleure correspondance") } }
        for _, x in ipairs(g.options) do o[#o + 1] = x end
        SEARCH_FILTERS[i] = { key = "sort", label = g.label, default = "_score", options = o }
    else
        SEARCH_FILTERS[i] = g
    end
end

-- Paramètres communs (valeurs scalaires de work_search[...]).
local SCALAR_PARAM = { language = "language_id", status = "complete", length = "word_count", updated = "revised_at" }
-- Cases à cocher de la barre latérale des pages de tag.
local INCLUDE_PARAM = { rating = "rating_ids", category = "category_ids", warning = "archive_warning_ids" }

local function qs_add(qs, key, value)
    if value and value ~= "" then qs[#qs + 1] = url_encode(key) .. "=" .. url_encode(value) end
end

-- Page de tag : /tags/<tag>/works?… (même formulaire que le site).
local function build_tag_url(href, page, f)
    f = f or {}
    local qs = { "commit=Sort+and+Filter", "page=" .. page }
    qs_add(qs, "work_search[sort_column]", f.sort ~= "" and f.sort or "revised_at")
    for fkey, param in pairs(SCALAR_PARAM) do qs_add(qs, "work_search[" .. param .. "]", f[fkey]) end
    for fkey, param in pairs(INCLUDE_PARAM) do qs_add(qs, "include_work_search[" .. param .. "][]", f[fkey]) end
    return BASE .. href .. "?" .. table.concat(qs, "&")
end

-- Recherche libre = l'URL du site :
--   /works/search?work_search[query]=<terme>   (tri par défaut : meilleure correspondance)
-- Les filtres (bouton filtre de la liste de résultats) ne sont ajoutés que s'ils
-- diffèrent des valeurs par défaut : sans rien toucher, la liste est celle du site.
local SEARCH_SCALARS = { "language", "status", "length", "updated" }

local function build_search_url(term, page, f)
    f = f or {}
    local qs = { url_encode("work_search[query]") .. "=" .. url_encode(term) }
    if f.sort and f.sort ~= "" and f.sort ~= "_score" then
        qs_add(qs, "work_search[sort_column]", f.sort)
        qs_add(qs, "work_search[sort_direction]", "desc")
    end
    for _, fkey in ipairs(SEARCH_SCALARS) do
        qs_add(qs, "work_search[" .. SCALAR_PARAM[fkey] .. "]", f[fkey])
    end
    qs_add(qs, "work_search[rating_ids]", f.rating)
    qs_add(qs, "work_search[category_ids][]", f.category)
    qs_add(qs, "work_search[archive_warning_ids][]", f.warning)
    if page and page > 1 then qs[#qs + 1] = "page=" .. page end
    return BASE .. "/works/search?" .. table.concat(qs, "&")
end

-- ── Fandoms ───────────────────────────────────────────────────────────────────

-- Liens <a class="tag" href="/tags/…"> d'un fragment : itérateur (href, nom, position_fin).
local function tag_anchors(block)
    local list = {}
    for attrs, text, e in block:gmatch('<a(%s[^>]-)>(.-)</a>()') do
        local href = attrs:match('href="([^"]+)"')
        local cls  = attrs:match('class="([^"]*)"')
        if href and cls and cls:find("tag", 1, true) and href:match("^/tags/") then
            list[#list + 1] = { href = href, name = strip_tags(text), e = e }
        end
    end
    return list
end

local function works_href(href)
    href = href:gsub("%?.*$", "")
    if not href:match("/works$") then href = href:gsub("/$", "") .. "/works" end
    return href
end

-- Liste embarquée (hors ligne, affichage instantané) : fandoms les plus
-- fréquentés de /media. « Charger la liste complète » la remplace par la vraie.
local FALLBACK = {
    { "Anime & Manga", {
        { "僕のヒーローアカデミア | Boku no Hero Academia | My Hero Academia (Anime & Manga)", "371k" },
        { "Haikyuu!!", "172k" }, { "Naruto (Anime & Manga)", "148k" },
        { "呪術廻戦 | Jujutsu Kaisen (Anime & Manga)", "123k" } } },
    { "Books & Literature", {
        { "Harry Potter - J. K. Rowling", "614k" }, { "Star Wars - All Media Types", "260k" },
        { "Sherlock Holmes & Related Fandoms", "142k" }, { "A Song of Ice and Fire & Related Fandoms", "124k" },
        { "J. R. R. Tolkien's Middle-earth Legendarium & Related Fandoms", "116k" } } },
    { "Cartoons & Comics & Graphic Novels", {
        { "Marvel", "702k" }, { "Marvel Cinematic Universe", "559k" }, { "DCU", "402k" } } },
    { "Celebrities & Real People", {
        { "Real Person Fiction", "956k" }, { "Video Blogging RPF", "345k" },
        { "Sports RPF", "193k" }, { "Actor RPF", "169k" } } },
}

local function fallback_fandoms()
    local items = {}
    for _, cat in ipairs(FALLBACK) do
        items[#items + 1] = { header = true, text = cat[1], href = "/media/" .. tag_segment(cat[1]) }
        for _, f in ipairs(cat[2]) do
            items[#items + 1] = { name = f[1], count = f[2], href = tag_href(f[1]) }
        end
    end
    return items
end

-- Parse /media : { {header=true,text=}, {name=,count=,href=}, … }
local function parse_media(html)
    local heads = {}
    for pos, mhref, title in html:gmatch('()<h3[^>]-class="heading"[^>]*>%s*<a[^>]-href="(/media/[^"]+)"[^>]*>(.-)</a>') do
        heads[#heads + 1] = { pos = pos, text = strip_tags(title), href = mhref }
    end
    local items = {}
    for i, h in ipairs(heads) do
        local stop = heads[i + 1] and (heads[i + 1].pos - 1) or #html
        local block = html:sub(h.pos, stop)
        local rows = {}
        for _, a in ipairs(tag_anchors(block)) do
            local count = block:sub(a.e, a.e + 40):match("%(([%d,]+)%)")
            rows[#rows + 1] = { name = a.name, count = fmt_num(count), href = works_href(a.href) }
        end
        if #rows > 0 then
            items[#items + 1] = { header = true, text = h.text, href = h.href }
            for _, r in ipairs(rows) do items[#items + 1] = r end
        end
    end
    return items
end

-- ── Extension table ───────────────────────────────────────────────────────────

local Settings = require("sefirah_settings")

local ext = {
    review_cache_rev = 3,  -- change quand le format des avis change (invalide le cache disque)
    id      = "ao3",
    name    = "Archive of Our Own",
    site    = BASE,
    lang    = "multi",
    version = "2.2.0",
    popularFilters = POPULAR_FILTERS,
    searchFilters  = SEARCH_FILTERS,
    searchHint = T("Titre, auteur, tag…"),
}

-- Fandom / tag courant (mémorisé entre deux ouvertures).
function ext:getContext()
    return Settings:getExt("ao3", "tag_href", DEFAULT_TAG_HREF),
           Settings:getExt("ao3", "tag_name", DEFAULT_TAG_NAME)
end

function ext:setContext(href, name)
    Settings:setExt("ao3", "tag_href", works_href(href))
    Settings:setExt("ao3", "tag_name", name)
end

function ext:listTitle()
    local _, name = self:getContext()
    local t = "AO3 · " .. name
    if #t > 30 then t = t:sub(1, 28):gsub("[\128-\191]*$", "") .. "…" end
    return t
end

function ext:fallbackFandoms() return fallback_fandoms() end

local function remember(filters) ext.last_filters = filters end

function ext:popularNovels(page, options)
    page = page or 1
    local filters = options and options.filters
    remember(filters)
    local href = self:getContext()
    local url = build_tag_url(href, page, filters)
    logger.dbg("AO3: popularNovels", url)
    return fetch_list(url)
end

function ext:searchNovels(term, page, options)
    page = page or 1
    local url = build_search_url(term, page, options and options.filters)
    logger.dbg("AO3: searchNovels", url)
    return fetch_list(url)
end

-- ── Fandoms ───────────────────────────────────────────────────────────────────

local FANDOM_TTL = 30 * 86400

function ext:cachedFandoms()
    if self._fandoms then return self._fandoms end
    local c = Settings:getExt("ao3", "fandoms", nil)
    if type(c) == "table" and c.items and #c.items > 0 and os.time() - (c.t or 0) < FANDOM_TTL then
        self._fandoms = c.items
        return c.items
    end
    return nil
end

-- 1 requête (/media), puis cache disque 30 jours. En cas d'échec : liste de secours.
function ext:fandomList()
    local html = http_get(BASE .. "/media")
    local items = html and parse_media(html) or {}
    if #items > 0 then
        self._fandoms = items
        Settings:setExt("ao3", "fandoms", { t = os.time(), items = items })
        return items, true
    end
    if html then write_debug("Page /media inattendue\n\n" .. html:sub(1, 3000)) end
    return self:fallbackFandoms(), false
end

-- Case « All » d'une catégorie : fandoms de /media/<catégorie>/fandoms, triés par
-- nombre d'œuvres décroissant (limités à ALL_MAX pour rester fluide).
--
-- Cette page AO3 est ÉNORME (plusieurs dizaines de milliers de fandoms pour
-- « Anime & Manga », plusieurs Mo de HTML) : avec les délais habituels (15 s /
-- 30 s) la requête échouait et la case « All » restait vide. On utilise donc
-- des délais larges, une analyse légère (le nom n'est nettoyé que pour les
-- ALL_MAX premiers) et un cache disque de 30 jours par catégorie : seule la
-- première ouverture est longue.
local ALL_MAX = 300
local CAT_TTL = 30 * 86400

local function http_get_big(url)
    logger.dbg("AO3: http_get_big", url)
    local body, code = require("core.net").get(url, {
        headers = {
            ["Accept"] = "text/html,application/xhtml+xml,*/*;q=0.8",
            ["User-Agent"] = UA,
            ["Accept-Language"] = "en-US,en;q=0.7",
        },
        timeout   = 45,
        deadline  = 300,
        max_bytes = 60 * 1024 * 1024,
    })
    if not body then
        logger.err("AO3: http_get_big FAILED", url, tostring(code))
        return nil, code
    end
    return body
end

function ext:categoryFandoms(href, name)
    href = href or ("/media/" .. tag_segment(name or ""))
    href = href:gsub("%?.*$", ""):gsub("/fandoms$", ""):gsub("/$", "")

    -- Cache disque par catégorie.
    local store = Settings:getExt("ao3", "cat_fandoms", nil)
    local c = type(store) == "table" and store[href] or nil
    if type(c) == "table" and type(c.items) == "table" and #c.items > 0
       and os.time() - (c.t or 0) < CAT_TTL then
        return c.items
    end

    local html, code = http_get_big(BASE .. href .. "/fandoms")
    if not html then return nil, T("AO3 injoignable") .. " (" .. tostring(code) .. ")" end

    -- Analyse légère : href, texte brut et compteur, sans strip_tags.
    local list, seen = {}, {}
    for attrs, text, e in html:gmatch('<a(%s[^>]-)>(.-)</a>()') do
        local h = attrs:match('href="(/tags/[^"]+)"')
        if h and not h:match("^/tags/search") then
            h = works_href(h)
            if not seen[h] then
                seen[h] = true
                local raw = html:sub(e, e + 40):match("%(([%d,]+)%)")
                list[#list + 1] = { raw = text, href = h, raw_n = raw,
                                    n = tonumber((((raw or "0"):gsub(",", "")))) or 0 }
            end
        end
    end
    html = nil
    if #list == 0 then
        write_debug("Page " .. href .. "/fandoms inattendue (0 fandom analysé)")
        return nil, T("Aucun fandom trouvé.")
    end
    table.sort(list, function(a, b) return a.n > b.n end)
    local items = {}
    for i = 1, math.min(#list, ALL_MAX) do
        local it = list[i]
        items[i] = { name = strip_tags(it.raw), count = fmt_num(it.raw_n), href = it.href }
    end

    local newstore = type(store) == "table" and store or {}
    newstore[href] = { t = os.time(), items = items }
    Settings:setExt("ao3", "cat_fandoms", newstore)
    return items
end

-- Recherche d'un fandom par nom (/tags/search).
--
-- Avant : une seule page de 20 résultats, triés par ordre alphabétique et mêlés aux
-- tags non canoniques (« #Naruto », « abbyrose: Naruto »…) : le vrai fandom
-- (« Naruto (Anime & Manga) ») tombait souvent sur une page jamais lue.
-- Maintenant : tags canoniques triés par nombre d'œuvres, sur plusieurs pages ;
-- si AO3 refuse ces options, repli sur la recherche simple (plus de pages).
local function fandom_search_url(term, page, strict)
    local qs = {
        "commit=Search+Tags",
        url_encode("tag_search[name]") .. "=" .. url_encode(term),
        url_encode("tag_search[type]") .. "=Fandom",
    }
    if strict then
        qs[#qs + 1] = url_encode("tag_search[wrangling_status]") .. "=canonical"
        qs[#qs + 1] = url_encode("tag_search[sort_column]") .. "=uses"
        qs[#qs + 1] = url_encode("tag_search[sort_direction]") .. "=desc"
    end
    if page > 1 then qs[#qs + 1] = "page=" .. page end
    return BASE .. "/tags/search?" .. table.concat(qs, "&")
end

local function run_fandom_search(term, strict, max_pages)
    local list, seen, err = {}, {}, nil
    for page = 1, max_pages do
        local html, code = http_get(fandom_search_url(term, page, strict))
        if not html then
            err = T("AO3 injoignable") .. " (" .. tostring(code) .. ")"
            break
        end
        local before = #list
        for _, a in ipairs(tag_anchors(html)) do
            local h = works_href(a.href)
            if not seen[h] and not a.href:match("^/tags/search") then
                seen[h] = true
                local raw = html:sub(a.e, a.e + 40):match("%(([%d,]+)%)")
                list[#list + 1] = {
                    name = a.name, count = fmt_num(raw), href = h,
                    n = tonumber((((raw or "0"):gsub(",", "")))) or 0, idx = #list + 1,
                }
            end
        end
        if #list == before or not html:find('rel="next"', 1, true) then break end
    end
    return list, err
end

function ext:searchFandoms(term)
    local list, err = run_fandom_search(term, true, 4)
    if #list == 0 then list, err = run_fandom_search(term, false, 6) end
    if #list == 0 then return nil, err or T("Aucun fandom trouvé.") end
    -- Les plus fournis d'abord (les tags sans compteur vont en bas) ; ordre du site à égalité.
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.idx < b.idx
    end)
    -- Même chiffre que l'accueil : /media et /tags/search donnent des totaux un peu
    -- différents ; on reprend celui de l'accueil quand le fandom y figure.
    local known = {}
    for _, it in ipairs(self:cachedFandoms() or self:fallbackFandoms()) do
        if it.href and it.count then known[it.href] = it.count end
    end
    local items = {}
    for i, it in ipairs(list) do
        items[i] = { name = it.name, count = known[it.href] or it.count, href = it.href }
    end
    return items
end

-- ── Métadonnées d'un roman ────────────────────────────────────────────────────

local function parse_title(html)
    local h2_s = html:find('<h2[^>]*class="[^"]*title[^"]*"')
    if h2_s then
        local h2_e = html:find('</h2>', h2_s)
        if h2_e then
            local t = strip_tags(html:sub(h2_s, h2_e))
            if t ~= "" then return t end
        end
    end
    return "Untitled"
end

local function parse_authors(html)
    local authors = {}
    for name in html:gmatch('<a[^>]*rel="author"[^>]*>([^<]+)</a>') do
        table.insert(authors, strip_tags(name))
    end
    if #authors == 0 and html:find('Anonymous', 1, true) then authors[1] = "Anonymous" end
    return table.concat(authors, ", ")
end

local function parse_status(html)
    local dt = html:match('<dt[^>]*class="[^"]*status[^"]*"[^>]*>([^<]+)</dt>') or ""
    return dt:match("Updated") and "Ongoing" or "Completed"
end

function ext:parseNovelMeta(path)
    local html = http_get(adult_url(path))
    if not html then return nil end
    local ch_text = html:match('<dd[^>]*class="[^"]*chapters[^"]*"[^>]*>([^<]+)</dd>') or ""
    return {
        name           = parse_title(html),
        path           = path,
        cover          = COVER_URL,
        author         = parse_authors(html),
        status         = parse_status(html),
        total_chapters = tonumber(ch_text:match("^%s*(%d+)")) or 0,
    }
end

function ext:parseNovel(path)
    logger.dbg("AO3: parseNovel", path)
    local html = http_get(adult_url(path))
    if not html then return nil end

    local title   = parse_title(html)
    local author  = parse_authors(html)
    local status  = parse_status(html)

    local fandom  = collect_tags(html, "fandom")
    local rating  = collect_tags(html, "rating")
    local warning = collect_tags(html, "warning")
    local genres  = collect_tags(html, "freeform")
    local rels    = collect_tags(html, "relationship")
    local chars   = collect_tags(html, "character")

    -- Résumé : uniquement le bloc « summary module » (sinon on risquerait de
    -- prendre les notes de l'auteur ou le texte du chapitre).
    local raw_summary = ""
    local sum_pos = html:find('class="summary module"', 1, true)
    if sum_pos then
        local bq_s = html:find('<blockquote[^>]*class="[^"]*userstuff[^"]*"', sum_pos)
        local bq_e = bq_s and html:find('</blockquote>', bq_s)
        if bq_s and bq_e then
            local bq = html:sub(bq_s, bq_e)
            bq = bq:gsub('<br[^>]*/?>%s*', '\n'):gsub('</p>%s*', '\n\n')
            raw_summary = strip_tags(bq):gsub('\n\n\n+', '\n\n')
        end
    end

    local function stat(cls) return strip_tags(html:match('<dd class="' .. cls .. '">(.-)</dd>') or "") end
    local stats = {}
    for _, s in ipairs({ { "words", "Mots" }, { "chapters", "Chapitres" }, { "kudos", "Kudos" }, { "hits", "Vues" } }) do
        local v = stat(s[1])
        if v ~= "" then stats[#stats + 1] = T(s[2]) .. " : " .. v end
    end

    local parts = {}
    if #stats > 0 then table.insert(parts, table.concat(stats, "  ·  ")) end
    if fandom      ~= "" then table.insert(parts, "Fandom: "        .. fandom)      end
    if rating      ~= "" then table.insert(parts, "Rating: "        .. rating)      end
    if warning     ~= "" then table.insert(parts, "Warning: "       .. warning)     end
    if raw_summary ~= "" then table.insert(parts, "Summary:\n"      .. raw_summary) end
    if rels        ~= "" then table.insert(parts, "Relationships: " .. rels)        end
    if chars       ~= "" then table.insert(parts, "Characters: "    .. chars)       end
    local summary = table.concat(parts, "\n\n")

    local work_id = path:match("works/(%d+)") or ""
    local ch_text = html:match('<dd[^>]*class="[^"]*chapters[^"]*"[^>]*>([^<]+)</dd>') or ""
    local n_published = tonumber(ch_text:match("^%s*(%d+)")) or 1

    -- ── Liste des chapitres ──────────────────────────────────────────────────
    local chapters = {}

    -- 1. Liste déroulante #chapter_index
    local ci_pos = html:find('id="chapter_index"', 1, true)
    if ci_pos then
        local sel_s = html:find('<select', ci_pos)
        local sel_e = html:find('</select>', ci_pos)
        if sel_s and sel_e then
            for opt_open, opt_text in html:sub(sel_s, sel_e):gmatch('(<option[^>]*>)([^<]*)') do
                local val  = opt_open:match('value="([^"]+)"')
                local name = strip_tags(opt_text)
                if val and name ~= "" then
                    table.insert(chapters, {
                        name = name,
                        path = "works/" .. work_id .. "/chapters/" .. val,
                    })
                end
            end
        end
    end

    -- 2. Titres inline dans #chapters
    if #chapters == 0 then
        local ch_div_pos = html:find('id="chapters"', 1, true)
        if ch_div_pos then
            local area, pos2 = html:sub(ch_div_pos), 1
            while true do
                local h3_s = area:find('<h3[^>]*class="[^"]*title[^"]*"', pos2)
                if not h3_s then break end
                local h3_e = area:find('</h3>', h3_s)
                if not h3_e then break end
                local h3_block = area:sub(h3_s, h3_e)
                local ch_id    = h3_block:match('/chapters/(%d+)')
                if ch_id then
                    local full = strip_tags(h3_block)
                    local name = full:match("[Cc]hapter%s+%d+:%s*(.+)") or full:match(":%s*(.+)$") or full
                    table.insert(chapters, {
                        name = name,
                        path = "works/" .. work_id .. "/chapters/" .. ch_id,
                    })
                end
                pos2 = h3_e + 5
            end
        end
    end

    -- 3. Index complet /works/<id>/navigate (roman à plusieurs chapitres seulement)
    if #chapters == 0 and n_published > 1 and work_id ~= "" then
        local nav = http_get(adult_url("works/" .. work_id .. "/navigate"))
        if nav then
            for ch_id, inner in nav:gmatch('<a[^>]*href="/works/%d+/chapters/(%d+)"[^>]*>(.-)</a>') do
                local name = strip_tags(inner)
                if name ~= "" then
                    table.insert(chapters, {
                        name = name,
                        path = "works/" .. work_id .. "/chapters/" .. ch_id,
                    })
                end
            end
        end
    end

    -- 4. Chapitre unique : le texte est sur la page du roman
    if #chapters == 0 then
        table.insert(chapters, { name = title, path = path })
    end

    return {
        name       = title,
        path       = path,
        cover      = COVER_URL,
        summary    = summary,
        author     = author,
        genres     = genres,
        status     = status,
        chapters   = chapters,
        totalPages = 1,
    }
end

function ext:parseChapter(path)
    local html = http_get(adult_url(path))
    if not html then return "<p>Error fetching chapter.</p>" end

    if html:match('id="login%-form"') or
       (html:match('Log [Ii]n') and not html:find('id="chapters"', 1, true)) then
        return "<p>This work is restricted to registered users on AO3 and cannot be accessed without logging in.</p>"
    end

    local chapters_div = extract_div(html, '<div[^>]*id="chapters"')
    if not chapters_div then
        write_debug("Chapitre : #chapters introuvable pour " .. path .. "\n\n" .. html:sub(1, 3000))
        return "<p>Could not extract chapter content.</p>"
    end

    -- Le texte est dans <div class="userstuff module">. Le premier <div> de
    -- #chapters est, sur une œuvre à plusieurs chapitres, l'en-tête
    -- (titre/résumé/notes) : l'ancien code renvoyait donc l'en-tête et non le texte.
    local content = extract_div(chapters_div, '<div[^>]-class="userstuff[^"]*"')
    if not content then
        write_debug("Chapitre : texte introuvable pour " .. path .. "\n\n" .. chapters_div:sub(1, 3000))
        return "<p>Could not extract chapter content.</p>"
    end

    -- Les liens ne fonctionnent pas dans l'epub
    content = content:gsub(' href="[^"]*"', '')
    -- Titre de repère inséré par AO3 (« Chapter Text » / « Work Text: »)
    content = content:gsub('<h3[^>]*id="work"[^>]*>[^<]*</h3>', '')
    content = content:gsub("<script.-</script>", "")

    -- Notes de fin de chapitre (si présentes)
    local end_notes = extract_div(html, '<div[^>]-class="end notes module"')
    if end_notes then
        local bq = end_notes:match('<blockquote[^>]*>(.-)</blockquote>')
        if bq and strip_tags(bq) ~= "" then
            content = content .. "<hr/><p><em>Notes</em></p>" .. bq:gsub(' href="[^"]*"', '')
        end
    end
    return content
end

-- ── Commentaires (onglet Avis) ────────────────────────────────────────────────
-- /comments/show_comments?work_id=ID&page=N : AO3 répond par du JavaScript
-- ($j("#comments_placeholder").append("…HTML échappé…")). On décode les
-- échappements JS (\" \/ \n \uXXXX), puis un <li id="comment_ID"> = un commentaire
-- (réponses incluses, à plat). L'ancienne URL /works/ID/comments n'existe pas.
local function js_unescape(s)
    -- Émojis : JS les écrit en paires de substituts (\ud83d\ude2d).
    s = s:gsub("\\u([dD][89abAB]%x%x)\\u([dD][c-fC-F]%x%x)", function(hi, lo)
        local cp = 0x10000 + (tonumber(hi, 16) - 0xD800) * 0x400 + (tonumber(lo, 16) - 0xDC00)
        return utf8_encode(cp)
    end)
    s = s:gsub("\\u(%x%x%x%x)", function(h) return utf8_encode(tonumber(h, 16)) end)
    return (s:gsub("\\(.)", function(c)
        if c == "n" then return "\n" elseif c == "t" then return " " elseif c == "r" then return "" end
        return c
    end))
end

-- pdp d'un commentaire : <img class="icon" src="..."> (AO3 héberge les icônes
-- sur s3.amazonaws.com/otw-ao3-icons). Les invités et comptes sans icône
-- reçoivent l'icône par défaut (/images/skins/iconsets/default/icon_user*.png) :
-- on renvoie nil pour que l'onglet Avis affiche le monogramme habituel.
local function comment_avatar(block)
    local src
    for tag in block:gmatch('<img[^>]->') do
        local cand = tag:match('src="([^"]+)"') or tag:match("src='([^']+)'")
        if cand and (tag:find('class="icon"', 1, true) or tag:find('icon', 1, true)
                     or cand:find("ao3-icons", 1, true)) then
            src = cand; break
        end
    end
    if not src or src == "" then return nil end
    src = src:gsub("&amp;", "&")
    if src:find("icon_user", 1, true) or src:find("/iconsets/default/", 1, true) then
        return nil
    end
    if src:sub(1, 2) == "//" then src = "https:" .. src
    elseif src:sub(1, 1) == "/" then src = BASE .. src end
    return src
end

local function parse_comments(html)
    local starts, hierarchy, stack = {}, {}, {}
    for pos, tag, attrs in html:gmatch('()<(/?[%w]+)([^>]*)>') do
        if tag == "li" then
            local id = attrs:match('id="comment_(%d+)"')
            local parent, depth = nil, 0
            for _, entry in ipairs(stack) do
                if entry then parent, depth = entry, depth + 1 end
            end
            stack[#stack + 1] = id or false
            if id then
                starts[#starts + 1] = pos
                hierarchy[pos] = { id = id, parent_id = parent, depth = depth }
            end
        elseif tag == "/li" then
            stack[#stack] = nil
        end
    end
    local reviews = {}
    for i, pos in ipairs(starts) do
        local block = html:sub(pos, (starts[i + 1] or (#html + 1)) - 1)
        local head = block:match('<h4[^>]-class="heading byline"[^>]*>(.-)</h4>') or ""
        local author = head:match('<a[^>]-href="/users/[^"]*"[^>]*>(.-)</a>')
            or head:match('^%s*<span>(.-)</span>')   -- invité : <span>Nom</span><span class="role"> (Guest)</span>
        author = author and strip_tags(author) or ""
        if author == "" then author = "Guest" end
        local body = block:match('<blockquote[^>]-class="userstuff"[^>]*>(.-)</blockquote>')
        if body then
            body = body:gsub('<br[^>]*/?>%s*', '\n'):gsub('</p>%s*', '\n\n')
            local text = strip_tags(body)
            if text ~= "" then
                local h = hierarchy[pos]
                reviews[#reviews + 1] = { id = h.id, parent_id = h.parent_id, depth = h.depth,
                                           author = author, content = text, likes = 0, dislikes = 0,
                                           avatar = comment_avatar(block:sub(1, (block:find("<blockquote", 1, true) or #block))) }
            end
        end
    end
    return reviews
end

function ext:parseReviews(path, page, sort)
    page = page or 1
    local work_id = tostring(path):match("works/(%d+)")
    if not work_id then return { reviews = {}, has_more = false } end
    local url = BASE .. "/comments/show_comments?work_id=" .. work_id .. "&page=" .. page
    local body = require("core.net").get(url, {
        headers = {
            ["Accept"] = "text/javascript, application/javascript, */*; q=0.01",
            ["User-Agent"] = UA,
            ["X-Requested-With"] = "XMLHttpRequest",
            ["Accept-Language"] = "en-US,en;q=0.7",
            ["Referer"] = BASE .. "/works/" .. work_id,
        },
        timeout = 15, deadline = 30,
    })
    if not body then return { reviews = {}, has_more = false } end

    local html = js_unescape(body)
    local reviews = parse_comments(html)
    if #reviews == 0 and page == 1 and not html:find("(0)", 1, true) and not html:find("No comments", 1, true) then
        write_debug("Commentaires : rien d'analysable pour " .. url .. "\n\n" .. body:sub(1, 3000))
    end
    -- Diagnostic : commentaires trouvés mais aucune pdp extraite → on garde
    -- l'en-tête du 1er commentaire dans ao3_last_error.txt (réglages/sefirah).
    if page == 1 and #reviews > 0 then
        local any = false
        for _, r in ipairs(reviews) do if r.avatar then any = true; break end end
        if not any then
            local first = html:match('<li[^>]-id="comment_%d+".-<blockquote') or html:sub(1, 2500)
            write_debug("Aucune pdp extraite pour " .. url .. "\n\n" .. first:sub(1, 3000))
        end
    end
    local has_more = html:find('rel="next"', 1, true) ~= nil
    return { reviews = reviews, has_more = has_more }
end

return ext
