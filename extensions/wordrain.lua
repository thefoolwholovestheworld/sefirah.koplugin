-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- wordrain.lua
-- Extension Sefirah pour https://wordrain69.com (romans chinois traduits en anglais,
-- traductrice « Miao »).
--
-- Site WordPress avec le thème Madara (même famille que les sites de manga/novel
-- « wp-manga »). Structure relevée sur le vrai HTML (pages enregistrées le 2026-10-25) :
--   * Catalogue   : /manga/ puis /manga/page/N/ (16 romans par page, 41 au total, 3 pages).
--                   Chaque roman = div.page-listing-item ; lien + titre dans
--                   div.item-thumb a[href] et h3.h5 a ; couverture dans <img data-src>
--                   (le src est une image « lazy » vide).
--   * Fiche roman : /manga/<slug>/ ; titre = <meta og:title>, couverture = <meta og:image>,
--                   résumé = div.summary__content, genres = div.genres-content,
--                   statut = bloc « Status ». L'identifiant du roman est dans
--                   #manga-chapters-holder[data-id].
--                   LA LISTE DES CHAPITRES N'EST PAS DANS LE HTML : elle est chargée après
--                   coup par AJAX (le holder ne contient qu'une roue de chargement).
--   * Chapitre    : /manga/<slug>/chapter-N/ ; texte dans div.reading-content > div.text-left
--                   (paragraphes <p>). Tous les chapitres vus sont gratuits (free-chap).
--
-- NON CONFIRMÉ (je n'ai pas pu interroger le site, seulement lire les pages enregistrées) :
--   * la requête AJAX qui renvoie les chapitres. On essaie dans l'ordre :
--       1. POST /manga/<slug>/ajax/chapters/   (route standard de Madara)
--       2. POST /word-ajax.php  action=manga_get_chapters&manga=<id>
--          (l'adresse admin-ajax est renommée sur ce site : « word-ajax.php »)
--       3. à défaut, les chapitres 1..N sont fabriqués à partir du lien « dernier chapitre »
--          de la fiche (les URL sont /chapter-N/), sans titres ni dates.
--   * Commentaires : WordPress classique, sur la fiche du roman (avis) et en bas de chaque
--                   chapitre : <li class="comment … depth-N" id="comment-ID"> avec
--                   h6.heading.fn (pseudo), div.comment-content, div.comment-metadata
--                   (date) et <img> gravatar (pdp). Les réponses sont imbriquées (depth-2…).
--
-- NON CONFIRMÉ (suite) :
--   * la recherche du site n'a pas été vue : la recherche filtre le catalogue en local.
-- En cas de liste vide ou d'échec, la réponse du site est enregistrée dans
-- sefirah/wordrain_last_error.txt (dossier des réglages de KOReader).

local BASE   = "https://wordrain69.com"
local logger = require("logger")

local T = require("core.i18n").T

local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

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
        local f = io.open(dir .. "/wordrain_last_error.txt", "wb")
        if f then f:write(content); f:close() end
    end)
end

-- ── HTTP ──────────────────────────────────────────────────────────────────────

local last_fail = nil

local function headers(lite)
    local h = {
        ["User-Agent"]      = UA,
        ["Accept"]          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.9",
    }
    if not lite then h["Referer"] = BASE .. "/" end
    return h
end

local function is_retryable(code)
    if type(code) ~= "number" then return true end -- erreur réseau / délai dépassé
    return code == 403 or code == 429 or code >= 500
end

-- quiet : n'enregistre pas l'échec (essais « facultatifs »).
local function http_get(url, quiet)
    local Net = require("core.net")
    local body, code, extra = Net.get(url, { headers = headers(false), timeout = 12 })
    if not body and is_retryable(code) then
        pcall(function() require("socket").sleep(1.5) end)
        body, code, extra = Net.get(url, { headers = headers(true), timeout = 15 })
    end
    if body then
        if not quiet then last_fail = nil end
        return body
    end
    if not quiet then
        last_fail = { code = code, body = tostring(extra or "") }
        logger.err("Wordrain: http_get FAILED", url, tostring(code))
        write_debug("URL : " .. url .. "\nStatut : " .. tostring(code)
            .. "\nDébut de la réponse :\n" .. last_fail.body .. "\n")
    end
    return nil, code
end

-- POST de formulaire (core/net.lua ne sait faire que des GET). Renvoie le corps ou nil.
local function http_post(url, body, referer)
    local ok_l, ltn12 = pcall(require, "ltn12")
    if not ok_l then return nil end
    local req = url:match("^https") and require("ssl.https") or require("socket.http")
    local h = headers(true)
    h["Content-Type"]     = "application/x-www-form-urlencoded; charset=UTF-8"
    h["Content-Length"]   = tostring(#body)
    h["X-Requested-With"] = "XMLHttpRequest"
    h["Origin"]           = BASE
    h["Referer"]          = referer or (BASE .. "/")
    local sink = {}
    local okc, ok, code = pcall(req.request, {
        url = url, method = "POST", headers = h,
        source = ltn12.source.string(body), sink = ltn12.sink.table(sink), timeout = 15,
    })
    local resp = table.concat(sink)
    if okc and ok and code == 200 and #resp > 2 then return resp end
    logger.warn("Wordrain: POST sans résultat", url, tostring(code))
    return nil
end

local function failure_message()
    local f = last_fail or {}
    if f.code == 403 or f.code == 429 or f.code == 503
        or (f.body or ""):find("Just a moment", 1, true) then
        return T("Wordrain refuse la requête (HTTP ") .. tostring(f.code)
            .. T(", protection anti-robot).")
    end
    return T("Wordrain injoignable : ") .. tostring(f.code or "erreur")
end

-- ── Catalogue ─────────────────────────────────────────────────────────────────

-- /manga/<slug>/ et rien d'autre (pas /manga/<slug>/chapter-…).
local function novel_slug(href)
    local p = to_path(decode_entities(href or ""):gsub("[%?#].*$", ""))
    return p:match("^/manga/([^/]+)/?$")
end

-- Romans d'une page du catalogue. Renvoie la liste et « y a-t-il une page suivante ».
local function parse_listing(html)
    local starts = {}
    local from = 1
    while true do
        local s = html:find('class="page-listing-item"', from, true)
        if not s then break end
        starts[#starts + 1] = s
        from = s + 10
    end
    local list, seen = {}, {}
    for i, s in ipairs(starts) do
        local block = html:sub(s, (starts[i + 1] or (#html + 1)) - 1)
        -- Le bloc de la dernière carte va jusqu'à la fin de la page : on coupe à la
        -- navigation pour ne pas lire le reste du site.
        local nav = block:find('<nav class="navigation', 1, true)
        if nav then block = block:sub(1, nav - 1) end

        local href = block:match('<div id="manga%-item%-%d+"[^>]*>%s*<a href="([^"]+)"')
            or block:match('<h3[^>]*>.-<a href="([^"]+)"')
        local slug = novel_slug(href)
        local h3   = block:match("<h3[^>]*>(.-)</h3>") or ""
        local name = strip_tags(h3:gsub('<span class="manga%-title%-badges.-</span></span>', ""))
        local cover = block:match('<img[^>]-data%-src="([^"]+)"')
        if slug and name ~= "" and not seen[slug] then
            seen[slug] = true
            list[#list + 1] = {
                name  = name,
                path  = "/manga/" .. slug .. "/",
                cover = cover and decode_entities(cover) or nil,
            }
        end
    end
    local has_next = html:find('class="nav%-previous') ~= nil
    return list, has_next
end

local function listing_url(page, genre)
    local path = "/manga/"
    if genre and genre ~= "all" and genre:match("^[%w%-]+$") then
        path = "/manga-genre/" .. genre .. "/"
    end
    if page > 1 then path = path .. "page/" .. page .. "/" end
    return BASE .. path
end

-- Catalogue complet (recherche) : toutes les pages, une seule fois, gardé en mémoire.
local _catalog = {}

local function get_catalog(genre)
    genre = genre or "all"
    if _catalog[genre] then return _catalog[genre] end
    local all, seen = {}, {}
    for page = 1, 12 do
        local html = http_get(listing_url(page, genre), page > 1)
        if not html then
            if page == 1 then return nil end
            break
        end
        local list, has_next = parse_listing(html)
        if page == 1 and #list == 0 then
            write_debug("Catalogue vide pour " .. listing_url(page) .. "\nTaille de la page : "
                .. #html .. " octets\nDébut de la page :\n" .. html:sub(1, 3000))
            return {}, #html
        end
        for _, n in ipairs(list) do
            if not seen[n.path] then
                seen[n.path] = true
                all[#all + 1] = n
            end
        end
        if not has_next then break end
    end
    _catalog[genre] = all
    return all
end

local PAGE_SIZE = 16

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
        error  = T("Wordrain : page reçue mais aucun roman reconnu (")
            .. tostring(size or 0) .. T(" octets). Voir sefirah/wordrain_last_error.txt"),
    }
end

-- ── Fiche roman ───────────────────────────────────────────────────────────────

local function parse_meta(html)
    local title = strip_tags(html:match('<meta property="og:title" content="([^"]*)"') or "")
    title = title:gsub("%s*[%-|]%s*Wordrain%s*$", "")
    if title == "" then
        title = strip_tags(html:match('<div class="post%-title">.-<h1[^>]*>(.-)</h1>') or "")
    end

    local cover = html:match('<meta property="og:image" content="([^"]*)"')
    if cover and cover ~= "" then cover = decode_entities(cover) else cover = nil end

    -- Résumé : les lignes sont séparées par des <br />.
    local summary = ""
    local sum = extract_div(html, '<div[^>]-class="[^"]*summary__content')
    if sum then
        sum = sum:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
        sum = sum:gsub("<br[^>]*/?>", "\n"):gsub("</p>", "\n\n")
        summary = strip_tags(sum):gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n")
    end

    local genres = html:match('<div class="genres%-content">(.-)</div>')
    genres = genres and strip_tags(genres) or ""

    local status = html:match('<h5>%s*Status%s*</h5>%s*</div>%s*<div class="summary%-content">%s*(.-)%s*</div>')
    status = status and strip_tags(status) or ""

    local translator = html:match('<div class="author%-content">(.-)</div>')
    translator = translator and strip_tags(translator) or ""

    local id = html:match('id="manga%-chapters%-holder"[^>]-data%-id="(%d+)"')
        or html:match('"manga_id":"(%d+)"')
        or html:match('class="rating%-post%-id" value="(%d+)"')

    return {
        title = title, cover = cover, summary = summary, genres = genres,
        status = status, translator = translator, id = id,
    }
end

-- ── Chapitres ─────────────────────────────────────────────────────────────────

local function chapter_number(path, fallback)
    local a, b = tostring(path):match("/chapter%-(%d+)%-(%d+)/?$")
    if a then return tonumber(a .. "." .. b) end
    return tonumber(tostring(path):match("/chapter%-(%d+)"))
        or tonumber(tostring(path):match("(%d+)/?$"))
        or fallback
end

local function finish_chapters(raw)
    local seen, list = {}, {}
    for i, c in ipairs(raw) do
        if not seen[c.path] then
            c.num = chapter_number(c.path, i)
            c.idx = i
            seen[c.path] = true
            list[#list + 1] = c
        end
    end
    table.sort(list, function(a, b)
        if a.num ~= b.num then return a.num < b.num end
        return a.idx < b.idx
    end)
    local out = {}
    for i, c in ipairs(list) do
        local name = c.name
        if not name or name == "" then name = T("Chapitre ") .. tostring(c.num) end
        out[i] = { name = name, path = c.path, chapter_number = c.num, date = c.date }
    end
    return out
end

-- Liste renvoyée par l'AJAX de Madara : <li class="wp-manga-chapter"><a href=…>Titre</a>…
local function parse_chapter_list(html, slug)
    local prefix = "/manga/" .. slug .. "/"
    local raw = {}
    for li in html:gmatch('<li[^>]-class="[^"]*wp%-manga%-chapter[^"]*"[^>]*>(.-)</li>') do
        local open = li:match("(<a[^>]*>)")
        local href = attr(open, "href")
        local path = href and to_path(decode_entities(href):gsub("[%?#].*$", ""))
        if path and path:sub(1, #prefix) == prefix and path:find("/chapter", 1, true) then
            local inner = li:match("<a[^>]*>(.-)</a>") or ""
            raw[#raw + 1] = { name = strip_tags(inner), path = path }
        end
    end
    return raw
end

-- Dernier recours : chapitres 1..N d'après le plus grand « chapter-N » de la fiche.
local function chapters_from_range(html, slug)
    local max = 0
    local links = html:match('<div id="init%-links"[^>]*>(.-)</div>') or ""
    for n in links:gmatch("/chapter%-(%d+)/") do
        if tonumber(n) > max then max = tonumber(n) end
    end
    if max == 0 then return {} end
    local raw = {}
    for n = 1, max do
        raw[#raw + 1] = { name = T("Chapitre ") .. n, path = "/manga/" .. slug .. "/chapter-" .. n .. "/" }
    end
    return raw
end

local function get_chapters(html, slug, manga_id)
    local novel_url = BASE .. "/manga/" .. slug .. "/"

    -- 1. Route standard de Madara.
    local resp = http_post(novel_url .. "ajax/chapters/", "", novel_url)
    local raw = resp and parse_chapter_list(resp, slug) or {}

    -- 2. admin-ajax renommé sur ce site.
    if #raw == 0 and manga_id then
        local resp2 = http_post(BASE .. "/word-ajax.php", "action=manga_get_chapters&manga=" .. manga_id, novel_url)
        raw = resp2 and parse_chapter_list(resp2, slug) or {}
        if #raw == 0 then
            write_debug("Chapitres : AJAX sans résultat pour " .. slug
                .. "\nPOST ajax/chapters : " .. tostring(resp and #resp or "aucune réponse") .. " octets"
                .. "\nDébut :\n" .. tostring(resp and resp:sub(1, 600) or "")
                .. "\n\nPOST word-ajax.php : " .. tostring(resp2 and #resp2 or "aucune réponse") .. " octets"
                .. "\nDébut :\n" .. tostring(resp2 and resp2:sub(1, 600) or "") .. "\n")
        end
    end

    -- 3. Chapitres fabriqués d'après le dernier numéro connu.
    if #raw == 0 then raw = chapters_from_range(html, slug) end
    return finish_chapters(raw)
end

-- ── Commentaires (WordPress) ──────────────────────────────────────────────────

local function escape_html(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Liste PLATE des commentaires d'une page, dans l'ordre d'affichage (une réponse suit
-- son parent). Chaque <li class="comment …" id="comment-N"> va jusqu'au <li> suivant :
-- les réponses étant imbriquées, le bloc d'un parent ne contient donc que son propre texte.
local function parse_comment_list(html)
    local items = {}
    local starts = {}
    local from = 1
    while true do
        local s, e = html:find('<li[^>]-id="comment%-%d+"', from)
        if not s then break end
        starts[#starts + 1] = s
        from = e + 1
    end
    for i, s in ipairs(starts) do
        local block = html:sub(s, (starts[i + 1] or (#html + 1)) - 1)
        local id    = block:match('^<li[^>]-id="comment%-(%d+)"')
        local depth = tonumber(block:match('^<li[^>]-class="[^"]-depth%-(%d+)')) or 1
        local author = strip_tags(block:match('<h6[^>]*>(.-)</h6>') or "")
        local body = block:match('<div class="comment%-content">(.-)</div>') or ""
        body = body:gsub("<br[^>]*/?>", "\n"):gsub("</p>", "\n\n")
        body = strip_tags(body):gsub("\n\n\n+", "\n\n")
        local date = strip_tags(block:match('<div class="comment%-metadata">%s*<a[^>]*>(.-)</a>') or "")
        local img = block:match("(<img[^>]*>)")
        local avatar = img and attr(img, "src") or nil
        if avatar then
            avatar = decode_entities(avatar)
            if avatar:sub(1, 2) == "//" then avatar = "https:" .. avatar end
            if not avatar:match("^https?://") then avatar = nil end
        end
        if id and body ~= "" then
            items[#items + 1] = {
                id = id, depth = depth, author = author ~= "" and author or "Anonymous",
                content = body, date = date, avatar = avatar,
            }
        end
    end
    return items
end

-- ── Extension ─────────────────────────────────────────────────────────────────

local ext = {
    id         = "wordrain",
    name       = "Wordrain",
    site       = BASE,
    lang       = "en",
    version    = "0.3.0",
    review_cache_rev = 1,
    -- Avis = commentaires WordPress de la fiche du roman (voir parseReviews).
    -- Ceux des chapitres sont ajoutés en texte à la fin du chapitre (pas de panneau).
    chapterCommentsPanel = false,
}

-- Genres relevés dans les liens manga-genre du site (25/10/2026).
local GENRE_FILTERS = {{
    key = "genre", label = T("Genre"), default = "all",
    options = {
        { id = "all", label = T("Tous") },
        { id = "action", label = "Action" },
        { id = "adventure", label = "Adventure" },
        { id = "comedy", label = "Comedy" },
        { id = "completed", label = "Completed" },
        { id = "drama", label = "Drama" },
        { id = "fantasy", label = "Fantasy" },
        { id = "futuristic", label = "Futuristic" },
        { id = "gender-bender", label = "Gender Bender" },
        { id = "historical", label = "Historical" },
        { id = "horror", label = "Horror" },
        { id = "one-shot", label = "One shot" },
        { id = "psychological", label = "Psychological" },
        { id = "reincarnation", label = "Reincarnation" },
        { id = "romance", label = "Romance" },
        { id = "school-life", label = "School Life" },
        { id = "sci-fi", label = "Sci-Fi" },
        { id = "slice-of-life", label = "Slice of Life" },
        { id = "supernatural", label = "Supernatural" },
        { id = "thriller", label = "Thriller" },
        { id = "tragedy", label = "Tragedy" },
        { id = "transmigration", label = "Transmigration" },
        { id = "yaoi", label = "Yaoi" },
        { id = "yuri", label = "Yuri" },
    },
}}
ext.popularFilters = GENRE_FILTERS
ext.searchFilters = GENRE_FILTERS

function ext:popularNovels(page, options)
    page = page or 1
    local genre = options and options.filters and options.filters.genre
    local html = http_get(listing_url(page, genre), page > 1)
    if not html then
        if page > 1 then return { novels = {} } end
        return { novels = {}, error = failure_message() }
    end
    local list = parse_listing(html)
    if #list == 0 then
        if page > 1 then return { novels = {} } end
        write_debug("Catalogue vide pour " .. listing_url(page) .. "\nTaille de la page : "
            .. #html .. " octets\nDébut de la page :\n" .. html:sub(1, 3000))
        return empty_list(#html, page)
    end
    return { novels = list }
end

function ext:searchNovels(term, page, options)
    page = page or 1
    local genre = options and options.filters and options.filters.genre
    local list, size = get_catalog(genre)
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
        cover          = meta.cover,
        summary        = meta.summary,
        author         = meta.translator ~= "" and meta.translator or nil,
        status         = meta.status,
        total_chapters = 0,
    }
end

function ext:parseNovel(path)
    local slug = novel_slug(path)
    if not slug then
        logger.err("Wordrain: chemin de roman invalide", tostring(path))
        return nil
    end
    local html = http_get(full_url("/manga/" .. slug .. "/"))
    if not html then
        logger.err("Wordrain: parseNovel fetch failed", path)
        return nil
    end
    local meta = parse_meta(html)
    if meta.title == "" then
        write_debug("Fiche illisible pour " .. slug .. "\nTaille : " .. #html
            .. " octets\nDébut de la page :\n" .. html:sub(1, 3000))
        return nil
    end

    local chapters = get_chapters(html, slug, meta.id)
    if #chapters == 0 then
        write_debug("Aucun chapitre trouvé pour " .. slug .. "\nid du roman : "
            .. tostring(meta.id) .. "\nTaille de la page : " .. #html .. " octets\n")
        logger.err("Wordrain: aucun chapitre trouvé pour", path)
    end

    return {
        name       = meta.title,
        path       = path,
        cover      = meta.cover,
        summary    = meta.summary,
        genres     = meta.genres,
        author     = meta.translator ~= "" and meta.translator or nil,
        status     = meta.status,
        chapters   = chapters,
        totalPages = 1,
    }
end

function ext:parseReviews(path, page, sort)
    page = page or 1
    if page > 1 then return { reviews = {}, has_more = false } end
    local slug = novel_slug(path)
    if not slug then return { reviews = {}, has_more = false } end
    local html = http_get(full_url("/manga/" .. slug .. "/"))
    if not html then return { reviews = {}, has_more = false, error = true } end

    -- Chaque réponse garde son propre auteur, avatar, date et texte.
    local items, ancestors = {}, {}
    for _, c in ipairs(parse_comment_list(html)) do
        local depth = math.max(0, (c.depth or 1) - 1)
        local parent = depth > 0 and ancestors[depth] or nil
        items[#items + 1] = {
            id = c.id, author = c.author, content = c.content, date = c.date,
            avatar = c.avatar, likes = 0, dislikes = 0,
            depth = depth, parent_id = parent,
        }
        ancestors[depth + 1] = c.id
        for level in pairs(ancestors) do
            if level > depth + 1 then ancestors[level] = nil end
        end
    end

    -- Les numéros de commentaire grandissent avec le temps : ils servent de date.
    table.sort(items, function(a, b)
        local na, nb = tonumber(a.id) or 0, tonumber(b.id) or 0
        if sort == "oldest" then return na < nb end
        return na > nb
    end)
    return { reviews = items, has_more = false }
end

function ext:parseChapter(path)
    local html = http_get(full_url(path))
    if not html then return T("<p>Impossible de récupérer ce chapitre.</p>") end

    -- <script>/<style> retirés AVANT de compter les <div> (un « <div> » dans une
    -- chaîne JavaScript fausserait l'équilibre des balises).
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")

    local content = extract_div(html, '<div[^>]-class="[^"]*text%-left')
    if not content then
        write_debug("Chapitre : texte introuvable pour " .. path
            .. "\nDébut de la page :\n" .. html:sub(1, 3000))
        if html:find("Premium Chapter", 1, true) and not html:find("reading%-content") then
            return T("<p>Ce chapitre est réservé (premium) : il faut se connecter sur le site.</p>")
        end
        return T("<p>Impossible d'extraire le contenu de ce chapitre.</p>")
    end

    -- On ne garde que le texte : balises <span style=…> et conteneurs retirés,
    -- paragraphes vides supprimés.
    content = content:gsub("<!%-%-.-%-%->", "")
    content = content:gsub("</?span[^>]*>", "")
    content = content:gsub("</?div[^>]*>", "")
    content = content:gsub("<p[^>]*>%s*</p>", "")
    content = content:gsub("<p[^>]*>%s*&nbsp;%s*</p>", "")
    content = content:gsub("^%s+", ""):gsub("%s+$", "")
    if content == "" then
        return T("<p>Impossible d'extraire le contenu de ce chapitre.</p>")
    end

    -- Commentaires du chapitre (déjà dans la page : aucune requête de plus), ajoutés en
    -- texte à la fin, comme sur NovelFrance. Une erreur ici n'empêche jamais la lecture.
    local ok_cc, extra = pcall(function()
        local list = parse_comment_list(html)
        if #list == 0 then return "" end
        local parts = { "<hr/>", "<p></p>", "<p>――――――――――――</p>",
                        "<h1>" .. T("Commentaires") .. "</h1>", "<p></p>" }
        for _, c in ipairs(list) do
            local head = c.author .. (c.date ~= "" and (" — " .. c.date) or "")
            local pre = c.depth > 1 and "&gt; " or ""
            parts[#parts + 1] = "<p><em>" .. pre .. escape_html(head) .. "</em><br/>"
                .. escape_html(c.content):gsub("\n", "<br/>") .. "</p>"
        end
        return table.concat(parts, "\n")
    end)
    if ok_cc and type(extra) == "string" and extra ~= "" then content = content .. "\n" .. extra end
    return content
end

return ext
