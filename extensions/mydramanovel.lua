-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- mydramanovel.lua
-- Extension Sefirah pour https://mydramanovel.com (romans chinois adaptés en
-- dramas, traduits en anglais).
--
-- Site WordPress (thème Newspaper / tagDiv), rendu côté serveur. Structure relevée
-- sur du vrai HTML (pages enregistrées le 2026-10-25) :
--   * Catalogue    : /novels/  -> 330 romans, a.td-ct-item[href="/<slug>/"]
--                    (nom dans span.td-ct-item-name), ordre alphabétique,
--                    SANS couverture.
--   * Fiche roman  : /<slug>/ = catégorie WordPress (id dans la classe du <body> :
--                    « category-1029 »). Titre : <meta og:title> « X — MyDramaNovel.com ».
--                    Résumé : div.tdb_category_description (titre original, auteur,
--                    synopsis). Aucune couverture.
--                    Chapitres : h3.entry-title > a[href="/<slug>/chapter-N-titre/"].
--   * Chapitre     : /<slug>/chapter-N-titre/ ; texte dans div.td-post-content,
--                    paragraphes <p class="wp-block-paragraph">, pubs adsbygoogle.
--
-- NON CONFIRMÉ (je n'ai pas pu interroger le site) :
--   * la liste des chapitres lue dans le HTML d'une fiche peut être tronquée /
--     paginée : on passe donc d'abord par l'API WordPress
--     /wp-json/wp/v2/posts?categories=<id>&per_page=100&page=N (liste complète,
--     légère), puis, si elle est bloquée, par le HTML + /<slug>/page/N/.
--   * la recherche du site (?s=) n'a pas été vue : la recherche filtre le
--     catalogue /novels/ en local.
-- En cas de liste vide ou d'échec, la réponse du site est enregistrée dans
-- sefirah/mydramanovel_last_error.txt (dossier des réglages de KOReader).

local BASE   = "https://mydramanovel.com"
local logger = require("logger")

local T = require("core.i18n").T

local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

-- Pas de couverture sur le site : le logo (resources/mydramanovel_cover.png) en
-- tient lieu, comme le logo AO3.
local _plugin_dir = ((debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+/[^/]+%.lua$")) or "."
if _plugin_dir:sub(1, 1) ~= "/" then
    local ok_l, l = pcall(require, "libs/libkoreader-lfs")
    local cwd = ok_l and l and l.currentdir and l.currentdir() or nil
    if cwd and cwd ~= "" then
        _plugin_dir = (_plugin_dir == ".") and cwd or (cwd .. "/" .. _plugin_dir)
    end
end
local COVER_URL = "local:" .. _plugin_dir .. "/resources/mydramanovel_cover.png"

-- ── Helpers HTML ──────────────────────────────────────────────────────────────

local function utf8_encode(cp)
    if not cp then return "" end
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + (math.floor(cp / 0x40) % 0x40),
                           0x80 + (cp % 0x40))
    else
        return string.char(0xF0 + math.floor(cp / 0x40000),
                           0x80 + (math.floor(cp / 0x1000) % 0x40),
                           0x80 + (math.floor(cp / 0x40) % 0x40),
                           0x80 + (cp % 0x40))
    end
end

local NAMED = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    hellip = "…", rsquo = "’", lsquo = "‘", rdquo = "”", ldquo = "“",
    laquo = "«", raquo = "»", ndash = "–", mdash = "—",
}

local function decode_entities(s)
    s = s:gsub("&#[xX](%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);",     function(d) return utf8_encode(tonumber(d)) end)
    -- &amp; en dernier : « &amp;lt; » doit rester « &lt; », pas devenir « < ».
    s = s:gsub("&(%a+);", function(n)
        if n == "amp" then return nil end
        return NAMED[n]
    end)
    s = s:gsub("&amp;", "&")
    return s
end

local function strip_tags(s)
    s = (s or ""):gsub("<[^>]+>", "")
    s = decode_entities(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Contenu équilibré d'un <div> : renvoie le contenu et la position qui suit.
-- open_pattern est un pattern Lua (échapper les « - » avec « %- »).
local function extract_div(html, open_pattern, start_pos)
    local s, e = html:find(open_pattern, start_pos or 1)
    if not s then return nil, nil end
    local tag_end = html:find(">", e, true)
    if not tag_end then return nil, nil end
    local depth, pos = 1, tag_end + 1
    while depth > 0 and pos <= #html do
        local open_pos  = html:find("<div", pos, true)
        local close_pos = html:find("</div>", pos, true)
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

local function to_path(u)
    u = tostring(u or ""):gsub("^https?://[^/]+", "")
    if u:sub(1, 1) ~= "/" then u = "/" .. u end
    return u
end

local function full_url(path)
    if path:match("^https?://") then return path end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return BASE .. path
end

-- Valeur d'un attribut dans une balise ouvrante (nom cherché entre séparateurs :
-- « src » ne doit pas matcher la fin de « data-src »).
local function attr(tag, name)
    if not tag then return nil end
    local esc = name:gsub("%-", "%%-")
    return tag:match("[%s<]" .. esc .. '%s*=%s*"([^"]*)"')
        or tag:match("[%s<]" .. esc .. "%s*=%s*'([^']*)'")
end

-- ── Debug ─────────────────────────────────────────────────────────────────────

local function write_debug(content)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local f = io.open(dir .. "/mydramanovel_last_error.txt", "wb")
        if f then f:write(content); f:close() end
    end)
end

-- ── HTTP ──────────────────────────────────────────────────────────────────────

local last_fail = nil

local function headers(lite, json)
    local h = {
        ["User-Agent"]      = UA,
        ["Accept"]          = json and "application/json,*/*;q=0.5"
                                    or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.9",
    }
    if not lite then h["Referer"] = BASE .. "/" end
    return h
end

local function is_retryable(code)
    if type(code) ~= "number" then return true end -- erreur réseau / délai dépassé
    return code == 403 or code == 429 or code >= 500
end

-- quiet : n'enregistre pas l'échec (essais « facultatifs » comme l'API JSON).
local function http_get(url, json, quiet)
    local Net = require("core.net")
    local body, code, extra = Net.get(url, { headers = headers(false, json), timeout = 12 })
    if not body and is_retryable(code) then
        pcall(function() require("socket").sleep(1.5) end)
        body, code, extra = Net.get(url, { headers = headers(true, json), timeout = 15 })
    end
    if body then
        if not quiet then last_fail = nil end
        return body
    end
    if not quiet then
        last_fail = { code = code, body = tostring(extra or "") }
        logger.err("MyDramaNovel: http_get FAILED", url, tostring(code))
        write_debug("URL : " .. url .. "\nStatut : " .. tostring(code)
            .. "\nDébut de la réponse :\n" .. last_fail.body .. "\n")
    end
    return nil, code
end

local function failure_message()
    local f = last_fail or {}
    if f.code == 403 or f.code == 429 or f.code == 503
        or (f.body or ""):find("Just a moment", 1, true) then
        return T("MyDramaNovel refuse la requête (HTTP ") .. tostring(f.code)
            .. T(", protection anti-robot).")
    end
    return T("MyDramaNovel injoignable : ") .. tostring(f.code or "erreur")
end

local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then ok_j, JSON = pcall(require, "json") end
    if not ok_j then return nil end
    local ok, data = pcall(JSON.decode, str)
    if ok and type(data) == "table" then return data end
    return nil
end

-- ── Catalogue ─────────────────────────────────────────────────────────────────

local PAGE_SIZE = 24

-- /<slug>/ et rien d'autre (pas /<slug>/chapter-…).
local function novel_slug(href)
    local p = to_path(decode_entities(href or ""):gsub("[%?#].*$", ""))
    return p:match("^/([^/]+)/?$")
end

-- Liste de TOUS les romans du catalogue (une seule requête, gardée en mémoire).
local _catalog = nil

local function parse_catalog(html)
    local list, seen = {}, {}
    for open, inner in html:gmatch('(<a[^>]-class="td%-ct%-item"[^>]*>)(.-)</a>') do
        local slug = novel_slug(attr(open, "href"))
        local name = strip_tags(inner:match('class="td%-ct%-item%-name"[^>]*>(.-)</span>') or inner)
        if slug and name ~= "" and not seen[slug] then
            seen[slug] = true
            list[#list + 1] = { name = name, path = "/" .. slug .. "/", cover = COVER_URL }
        end
    end
    return list
end

local function get_catalog()
    if _catalog then return _catalog end
    local html = http_get(BASE .. "/novels/")
    if not html then return nil end
    local list = parse_catalog(html)
    if #list == 0 then
        write_debug("Catalogue vide pour " .. BASE .. "/novels/\nTaille de la page : " .. #html
            .. " octets\nDébut de la page :\n" .. html:sub(1, 3000))
        return {}, #html
    end
    _catalog = list
    return _catalog
end

local function slice(list, page)
    page = page or 1
    local out = {}
    local first = (page - 1) * PAGE_SIZE + 1
    for i = first, math.min(first + PAGE_SIZE - 1, #list) do out[#out + 1] = list[i] end
    return out
end

local function empty_list(size, page)
    if page and page > 1 then return { novels = {} } end
    return {
        novels = {},
        error  = T("MyDramaNovel : page reçue mais aucun roman reconnu (")
            .. tostring(size or 0) .. T(" octets). Voir sefirah/mydramanovel_last_error.txt"),
    }
end

-- ── Fiche roman ───────────────────────────────────────────────────────────────

local function parse_meta(html)
    -- og:title = « Titre — MyDramaNovel.com ». Le tiret long est retiré par son
    -- texte UTF-8 (jamais dans une classe [...] : ses octets seraient coupés).
    local title = strip_tags(html:match('<meta property="og:title" content="([^"]*)"') or "")
    title = title:gsub("%s*\226\128[\147\148]%s*MyDramaNovel%.com%s*$", "")
    title = title:gsub("%s*[%-|]%s*MyDramaNovel%.com%s*$", "")
    if title == "" then
        title = strip_tags(html:match("<h1[^>]*>(.-)</h1>") or "")
    end

    -- Bloc de description de la catégorie : il contient du CSS (<style>) puis
    -- « Original Title / Author / Raw Link / Male Lead / Female Lead / Synopsis ».
    local summary, author = "", nil
    local desc = extract_div(html, '<div[^>]-class="[^"]*tdb_category_description')
    if desc then
        desc = desc:gsub("<style.-</style>", ""):gsub("<script.-</script>", "")
        desc = desc:gsub("<br[^>]*/?>", "\n"):gsub("</p>", "\n\n")
        local text = strip_tags(desc):gsub("[ \t]+\n", "\n"):gsub("\n[ \t]+", "\n")

        -- Auteur : ligne « Author: … » (une seule ligne).
        author = text:match("[Aa]uthor%s*:%s*([^\n]+)")
        if author then
            author = author:gsub("%s+$", "")
            if author == "" then author = nil end
        end

        -- Résumé : uniquement ce qui suit « Synopsis: » jusqu'à la fin.
        local _, e = text:find("[Ss]ynopsis%s*:")
        if e then text = text:sub(e + 1) end
        summary = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n\n\n+", "\n\n")
    end

    local cat_id = tonumber(html:match('<body[^>]-class="[^"]-category%-(%d+)'))
        or tonumber(html:match("/wp%-json/wp/v2/categories/(%d+)"))

    return { title = title, summary = summary, author = author, cat_id = cat_id }
end

-- ── Chapitres ─────────────────────────────────────────────────────────────────

local function chapter_number(path, fallback)
    return tonumber(tostring(path):match("/chapter%-(%d+)"))
        or tonumber(tostring(path):match("(%d+)/?$"))
        or fallback
end

local function finish_chapters(raw)
    -- raw : { {name=, path=, date=}, … } dans l'ordre trouvé. Tri par numéro de
    -- chapitre (ordre trouvé en cas d'égalité), doublons retirés.
    local seen, list = {}, {}
    for i, c in ipairs(raw) do
        local prev = seen[c.path]
        if not prev then
            c.num = chapter_number(c.path, i)
            c.idx = i
            seen[c.path] = c
            list[#list + 1] = c
        elseif (prev.name or "") == "" and (c.name or "") ~= "" then
            prev.name = c.name -- le lien de la vignette n'a pas de texte : on prend celui du titre
        end
    end
    table.sort(list, function(a, b)
        if a.num ~= b.num then return a.num < b.num end
        return a.idx < b.idx
    end)
    local out = {}
    for i, c in ipairs(list) do
        out[i] = {
            name           = c.name ~= "" and c.name or (T("Chapitre ") .. c.num),
            path           = c.path,
            chapter_number = c.num,
            date           = c.date,
        }
    end
    return out
end

local MAX_API_PAGES = 60  -- 6000 chapitres : garde-fou

-- Liste complète via l'API WordPress. nil si elle est inaccessible.
local function chapters_from_api(cat_id, slug)
    if not cat_id then return nil end
    local raw = {}
    for page = 1, MAX_API_PAGES do
        local url = BASE .. "/wp-json/wp/v2/posts?categories=" .. cat_id
            .. "&per_page=100&page=" .. page
            .. "&orderby=date&order=asc&_fields=link,title,date"
        local body = http_get(url, true, true)
        if not body then break end
        local data = json_decode(body)
        if not data or #data == 0 then break end
        for _, p in ipairs(data) do
            local link = p.link and to_path(p.link)
            if link and link:find("^/" .. slug:gsub("%-", "%%-") .. "/") then
                raw[#raw + 1] = {
                    name = strip_tags(type(p.title) == "table" and p.title.rendered or ""),
                    path = link,
                    date = type(p.date) == "string" and p.date:match("^(%d%d%d%d%-%d%d%-%d%d)") or nil,
                }
            end
        end
        if #data < 100 then break end
    end
    if #raw == 0 then return nil end
    return finish_chapters(raw)
end

local function scan_chapter_links(html, slug, raw)
    local prefix = "/" .. slug .. "/chapter-"
    local n = 0
    for open, inner in html:gmatch('(<a[^>]-rel="bookmark"[^>]*>)(.-)</a>') do
        local href = attr(open, "href")
        local path = href and to_path(decode_entities(href):gsub("[%?#].*$", ""))
        if path and path:sub(1, #prefix) == prefix then
            raw[#raw + 1] = { name = strip_tags(inner), path = path }
            n = n + 1
        end
    end
    return n
end

-- Repli : liens de la fiche + /<slug>/page/N/ tant qu'il y a de nouveaux chapitres.
local function chapters_from_html(html, slug)
    local raw = {}
    scan_chapter_links(html, slug, raw)
    local known = {}
    for _, c in ipairs(raw) do known[c.path] = true end
    for page = 2, 80 do
        local h = http_get(BASE .. "/" .. slug .. "/page/" .. page .. "/", false, true)
        if not h then break end
        local more = {}
        scan_chapter_links(h, slug, more)
        local added = 0
        for _, c in ipairs(more) do
            if not known[c.path] then
                known[c.path] = true
                raw[#raw + 1] = c
                added = added + 1
            end
        end
        if added == 0 then break end
    end
    return finish_chapters(raw)
end

-- ── Extension ─────────────────────────────────────────────────────────────────

local ext = {
    id         = "mydramanovel",
    name       = "MyDramaNovel",
    site       = BASE,
    lang       = "en",
    version    = "0.1.0",
    -- Pas d'avis exploitables sur le site (seulement des commentaires WordPress).
    hasReviews = false,
}

function ext:popularNovels(page, options)
    page = page or 1
    local list, size = get_catalog()
    if not list then return { novels = {}, error = failure_message() } end
    if #list == 0 then return empty_list(size, page) end
    return { novels = slice(list, page) }
end

function ext:searchNovels(term, page)
    page = page or 1
    local list, size = get_catalog()
    if not list then return { novels = {}, error = failure_message() } end
    if #list == 0 then return empty_list(size, page) end
    local q = (term or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local starts, contains = {}, {}
    for _, n in ipairs(list) do
        local name = n.name:lower()
        local pos = name:find(q, 1, true)
        if pos == 1 then starts[#starts + 1] = n
        elseif pos then contains[#contains + 1] = n end
    end
    for _, n in ipairs(contains) do starts[#starts + 1] = n end
    return { novels = slice(starts, page) }
end

function ext:parseNovelMeta(path)
    local html = http_get(full_url(path))
    if not html then return nil end
    local meta = parse_meta(html)
    return {
        name           = meta.title,
        path           = path,
        cover          = COVER_URL,
        summary        = meta.summary,
        author         = meta.author,
        no_author      = true,                       -- pas de 2e « Inconnu » devant
        status         = meta.author or "MyDramaNovel", -- affiché à la place du statut
        total_chapters = 0,
    }
end

function ext:parseNovel(path)
    local slug = novel_slug(path)
    if not slug then
        logger.err("MyDramaNovel: chemin de roman invalide", tostring(path))
        return nil
    end
    local html = http_get(full_url("/" .. slug .. "/"))
    if not html then
        logger.err("MyDramaNovel: parseNovel fetch failed", path)
        return nil
    end
    local meta = parse_meta(html)
    if meta.title == "" then
        write_debug("Fiche illisible pour " .. slug .. "\nTaille : " .. #html
            .. " octets\nDébut de la page :\n" .. html:sub(1, 3000))
        return nil
    end

    local chapters = chapters_from_api(meta.cat_id, slug)
    if not chapters then chapters = chapters_from_html(html, slug) end
    if #chapters == 0 then
        write_debug("Aucun chapitre trouvé pour " .. slug .. "\nid de catégorie : "
            .. tostring(meta.cat_id) .. "\nTaille de la page : " .. #html .. " octets\n")
        logger.err("MyDramaNovel: aucun chapitre trouvé pour", path)
    end

    return {
        name       = meta.title,
        path       = path,
        cover      = COVER_URL,
        summary    = meta.summary,
        genres     = "",
        author     = meta.author,
        no_author  = true,                           -- pas de 2e « Inconnu » devant
        status     = meta.author or "MyDramaNovel",  -- l'auteur remplace « Unknown »
        chapters   = chapters,
        totalPages = 1,
    }
end

function ext:parseChapter(path)
    local html = http_get(full_url(path))
    if not html then return T("<p>Impossible de récupérer ce chapitre.</p>") end

    -- <script>/<style> retirés AVANT de compter les <div> (un « <div> » dans une
    -- chaîne JavaScript fausserait l'équilibre des balises).
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")

    local content = extract_div(html, '<div[^>]-class="[^"]*td%-post%-content')
    if not content then
        write_debug("Chapitre : texte introuvable pour " .. path
            .. "\nDébut de la page :\n" .. html:sub(1, 3000))
        return T("<p>Impossible d'extraire le contenu de ce chapitre.</p>")
    end

    -- Pubs (adsbygoogle), conteneurs <div> et commentaires HTML retirés ; on ne
    -- garde que le texte (<p>, titres, séparateurs, images éventuelles).
    content = content:gsub("<ins.-</ins>", "")
    content = content:gsub("<!%-%-.-%-%->", "")
    content = content:gsub("<span[^>]*></span>", "")
    content = content:gsub("</?div[^>]*>", "")
    content = content:gsub("<p[^>]*>%s*</p>", "")
    content = content:gsub("<p[^>]*>%s*&nbsp;%s*</p>", "")
    content = content:gsub("^%s+", ""):gsub("%s+$", "")
    if content == "" then
        return T("<p>Impossible d'extraire le contenu de ce chapitre.</p>")
    end
    return content
end

return ext
