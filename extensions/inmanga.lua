-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- extensions/inmanga.lua — InManga (https://inmanga.com), manga en espagnol.
-- Source MANGA (contrat : cf. extensions/mangadex.lua).
--
-- ══ CE QUI A ÉTÉ VÉRIFIÉ SUR DE VRAIES PAGES (relevé du 2026-10-14) ═════════
--   * Accueil « / » : « Últimas Actualizaciones » (div#RecentChaptersContainer, une carte
--     par chapitre sorti, lien /ver/manga/<Slug>/<n°>/<id-chapitre>, couverture
--     cdn1.intomanga.com/i/m/<id-manga>/t/o/<id-manga>.jpg) et « Mangas Populares »
--     (div#MostViewedMangasContainer, lien /ver/manga/<Slug>/<id-manga>).
--   * Fiche « /ver/manga/<Slug>/<id-manga> » : h1 = titre, div.panel-body = résumé,
--     « Estado » (En emisión / Finalizado), « Publicación » (jj/mm/aaaa).
--     Pas d'auteur ni de genres sur la fiche.
--   * Liste des chapitres : <a href=".../ver/manga/<Slug>/<n°>/<id-chapitre>" data-c-number="1,195">.
--   * Lecteur : <select id="PageList"> (options = id des pages) ; image d'une page =
--     https://cdn1.intomanga.com/i/m/<id-manga>/c/<id-chapitre>/o/<id-page>.jpg
--
-- ══ CE QUI N'A PAS PU ÊTRE VÉRIFIÉ (pas de page enregistrée) ═════════════════
--   * Liste/recherche « /manga/getMangasConsultResult » (POST, réponse HTML) et liste de chapitres
--     « /chapter/getall?mangaIdentification=… » (JSON) et « /chapter/chapterIndexControls?
--     identification=… » (HTML) : adresses connues de l'API interne du site, mais lues de
--     mémoire. Chacune a un REPLI (accueil / page de la fiche / page du chapitre) et, en cas
--     d'échec, la réponse du site est enregistrée dans sefirah/inmanga_last_error.txt.
--
-- Chemins stockés :
--   manga    : « <Slug>/<id-manga> »            (ex. One-Piece/dfc7ecb5-e9b3-4aa5-a61b-a498993cd935)
--   chapitre : « <id-manga>|<id-chapitre> »

local logger = require("logger")
local T      = require("core.i18n").T

local BASE = "https://inmanga.com"
local CDN  = "https://cdn1.intomanga.com"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
local PAGE_SIZE = 10   -- « filter[take] » du site

local UUID_PAT = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

-- ── Helpers ──────────────────────────────────────────────────────────────────
local function utf8_encode(cp)
    if not cp then return "" end
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function decode(s)
    s = (s or ""):gsub("&#x(%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8_encode(tonumber(d)) end)
    return (s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " "))
end

local function text_of(html)
    return (decode((html or ""):gsub("<[^>]+>", " ")):gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function attr(tag, name)
    name = name:gsub("%-", "%%-")   -- « - » est un quantificateur dans les motifs Lua
    return tag:match("%f[%w_%-]" .. name .. '%s*=%s*"([^"]*)"') or tag:match("%f[%w_%-]" .. name .. "%s*=%s*'([^']*)'")
end

local function url_encode(str)
    return (tostring(str):gsub("([^%w%-%.%_%~])", function(c) return string.format("%%%02X", c:byte()) end))
end

local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return data
end

-- Un `null` JSON n'est PAS nil pour rapidjson : on ne garde que du vrai texte / des vrais nombres.
local function str(v)
    if type(v) == "string" then return v ~= "" and v or nil end
    if type(v) == "number" then return tostring(v) end
    return nil
end

local function dump_error(label, body)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local path = dir .. "/inmanga_last_error.txt"
        local f = io.open(path, "ab")
        if not f then return end
        local size = f:seek("end") or 0
        if size > 150000 then   -- on repart de zéro quand le fichier devient gros
            f:close()
            f = io.open(path, "wb")
            if not f then return end
        end
        f:write("\n=== " .. label .. " ===\n" .. tostring(body):sub(1, 12000) .. "\n")
        f:close()
    end)
end

local last_http = nil

local function req_headers(extra)
    local h = {
        ["User-Agent"] = UA,
        ["Accept"] = "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "es-ES,es;q=0.9,en;q=0.5",
        ["Referer"] = BASE .. "/",
    }
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
end

local function get_html(path, extra)
    local url = path:match("^https?://") and path or (BASE .. path)
    local body, code, info = require("core.net").get(url, { headers = req_headers(extra), timeout = 15 })
    if body and #body > 2 then return body end
    last_http = tostring(code)
    dump_error("requête échouée : " .. url .. "\ncode : " .. tostring(code), type(info) == "string" and info or "")
    logger.warn("InManga: échec", url, tostring(code))
    return nil, last_http
end

-- POST de formulaire (core/net.lua ne sait faire que des GET).
local function post_form(path, body, extra)
    local https  = require("ssl.https")
    local ltn12  = require("ltn12")
    local url = BASE .. path
    local headers = req_headers({
        ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
        ["Content-Length"] = tostring(#body),
        ["X-Requested-With"] = "XMLHttpRequest",
        ["Origin"] = BASE,
        ["Referer"] = BASE .. "/manga/consult",
    })
    for k, v in pairs(extra or {}) do headers[k] = v end
    local sink = {}
    local ok, code = https.request {
        url = url, method = "POST", headers = headers,
        source = ltn12.source.string(body), sink = ltn12.sink.table(sink), timeout = 15,
    }
    local resp = table.concat(sink)
    if ok and code == 200 and #resp > 2 then return resp end
    last_http = tostring(code or ok)
    dump_error("POST échoué : " .. url .. "\ncode : " .. tostring(code), resp)
    logger.warn("InManga: POST échec", url, tostring(code))
    return nil, last_http
end

-- ── Listes ───────────────────────────────────────────────────────────────────
local function cover_of(id)
    return CDN .. "/i/m/" .. id .. "/t/o/" .. id .. ".jpg"
end

local function clean_alt(alt)
    alt = decode(alt or "")
    alt = alt:gsub("%s*Manga Online %- InManga%s*$", ""):gsub("%s+[%d,%.]+$", "")
    return alt
end

-- Dernier recours : n'importe quel lien /ver/manga/<Slug>/<id> dans la page, même hors d'une
-- balise <a> (lien dans un script, JSON échappé « \\/ »…). Le titre est déduit du slug.
local function parse_loose(html)
    html = (html:gsub("\\/", "/"))
    local out, seen = {}, {}
    for slug, raw in html:gmatch("/ver/manga/([^/%?#\"'%s<>\\]+)/(" .. UUID_PAT .. ")") do
        local id = raw:lower()
        if not seen[id] then
            seen[id] = true
            local title = slug:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end):gsub("%-", " ")
            out[#out + 1] = { name = title, path = slug .. "/" .. id, cover = cover_of(id) }
        end
    end
    return out
end

-- Une série = lien /ver/manga/<Slug>/<id-manga>, OU carte de chapitre
-- /ver/manga/<Slug>/<n°>/<id-chapitre> (alors l'id du manga est dans l'adresse de la couverture).
local function parse_list(html)
    local out, seen = {}, {}
    for a_tag, inner in html:gmatch("(<a%s[^>]-href%s*=%s*[^>]->)(.-)</a>") do
        local href = attr(a_tag, "href")
        local slug, rest
        if href then slug, rest = href:match("/ver/manga/([^/%?#\"']+)/([^%?#\"']+)") end
        if not slug then
            if href then slug, rest = href:match("/manga/([^/%?#\"']+)/([^%?#\"']+)") end
        end
        if slug and rest then
            local img = inner:match("<img[^>]->")
            local src = img and (attr(img, "data-src") or attr(img, "src"))
            local id
            if rest:match("^" .. UUID_PAT .. "$") then
                id = rest:lower()
            elseif rest:match("^[^/]+/" .. UUID_PAT) then
                id = src and src:match("/i/m/(" .. UUID_PAT .. ")/")
                id = id and id:lower()
            end
            if id and not seen[id] then
                local title = inner:match("<h4[^>]*>(.-)</h4>")
                title = title and text_of(title)
                if not title or title == "" then
                    local s = inner:match("<strong[^>]*>(.-)</strong>")
                    title = s and text_of(s)
                end
                if (not title or title == "") and img then title = clean_alt(attr(img, "alt")) end
                if title and title ~= "" then
                    seen[id] = true
                    local cover = src and src:match("^https?://[^%s]*intomanga[^%s]*") or cover_of(id)
                    out[#out + 1] = { name = title, path = slug .. "/" .. id, cover = cover }
                end
            end
        end
    end
    if #out == 0 then out = parse_loose(html) end
    return out
end

-- Filtres relevés sur la page « Listado de mangas » (https://inmanga.com/manga/consult).
-- « Ordenar por » : 1 Vistos, 2 Relevancia, 3 Recién actualizado, 4 Recién agregado,
-- 5 Nombre, 6 Más capítulos, 7 Menos capítulos. « Estado » : 0 Todos, 1 En emisión, 2 Finalizado.
local SORT_OPTIONS = {
    { id = "1", label = T("Populaires") },
    { id = "3", label = T("Dernières sorties") },
    { id = "4", label = T("Ajoutés récemment") },
    { id = "5", label = T("Nom") },
    { id = "6", label = T("Plus de chapitres") },
}
local STATUS_OPTIONS = {
    { id = "0", label = T("Tous") },
    { id = "1", label = T("En cours") },
    { id = "2", label = T("Terminé") },
}
-- Genres du site (id = valeur envoyée dans filter[generes][]) ; doublons du site omis.
local GENRES = {
    { 33, "Aventura" }, { 34, "Shounen" }, { 35, "Suspenso" }, { 36, "Misterio" }, { 37, "Acción" },
    { 38, "Fantasía" }, { 39, "Gore" }, { 40, "Sobrenatural" }, { 41, "Romance" }, { 42, "Drama" },
    { 43, "Artes Marciales" }, { 44, "Ciencia Ficción" }, { 45, "Thriller" }, { 46, "Comedia" },
    { 47, "Mecha" }, { 49, "Tragedia" }, { 50, "Adulto" }, { 51, "Harem" }, { 52, "Yuri" },
    { 53, "Seinen" }, { 54, "Horror" }, { 55, "Webtoon" }, { 56, "Apocalíptico" }, { 57, "Boys Love" },
    { 58, "Ciberpunk" }, { 59, "Crimen" }, { 60, "Demonios" }, { 61, "Deporte" }, { 62, "Ecchi" },
    { 63, "Extranjero" }, { 64, "Familia" }, { 66, "Género Bender" }, { 67, "Girls Love" },
    { 68, "Guerra" }, { 69, "Historia" }, { 70, "Magia" }, { 71, "Militar" }, { 72, "Música" },
    { 73, "Parodia" }, { 74, "Policiaco" }, { 75, "Psicológico" }, { 76, "Realidad" },
    { 77, "Realidad Virtual" }, { 78, "Recuentos de la vida" }, { 79, "Reencarnación" },
    { 80, "Samurái" }, { 81, "Superpoderes" }, { 82, "Supervivencia" }, { 83, "Vampiros" },
    { 84, "Vida Escolar" }, { 85, "Cooking" },
}
local GENRE_OPTIONS = { { id = "", label = T("Tous") } }
for _, g in ipairs(GENRES) do GENRE_OPTIONS[#GENRE_OPTIONS + 1] = { id = tostring(g[1]), label = g[2] } end

-- Requête de liste : POST /manga/getMangasConsult (réponse = cartes <a class="manga-result">).
-- Repli 1 : même requête en GET. Repli 2 : page /manga/consult elle-même (page 1 sans filtre).
-- Renvoie { novels } ou nil, « raisons des échecs ».
local function consult(term, page, o)
    page = tonumber(page) or 1
    o = o or {}
    local genres = {}
    for g in tostring(o.genre or ""):gmatch("[^,]+") do genres[#genres + 1] = g end
    local gbody = ""
    for _, g in ipairs(genres) do gbody = gbody .. "&filter%5Bgeneres%5D%5B%5D=" .. url_encode(g) end
    if gbody == "" then gbody = "&filter%5Bgeneres%5D%5B%5D=-1" end
    local body = gbody:sub(2)
        .. "&filter%5BqueryString%5D=" .. url_encode(term or "")
        .. "&filter%5Bskip%5D=" .. ((page - 1) * PAGE_SIZE)
        .. "&filter%5Btake%5D=" .. PAGE_SIZE
        .. "&filter%5Bsortby%5D=" .. url_encode(o.sort or "1")
        .. "&filter%5BbroadcastStatus%5D=" .. url_encode(o.status or "0")
        .. "&filter%5BonlyFavorites%5D=false&d="

    local reasons = {}
    local function attempt(name, html, why)
        if not html then
            reasons[#reasons + 1] = name .. ": HTTP " .. tostring(why)
            return nil
        end
        local novels = parse_list(html)
        if #novels > 0 then return { novels = novels } end
        if page > 1 and name:find("^POST") then return { novels = {} } end   -- fin de liste
        dump_error(name .. " : réponse sans série reconnue", html)
        reasons[#reasons + 1] = name .. ": " .. T("réponse inattendue")
        return nil
    end

    -- Le site a renommé l'adresse : « getMangasConsultResult » (l'ancienne « getMangasConsult »
    -- répond par une page 404, relevé du 2026-10-15). On essaie la bonne d'abord, puis l'ancienne.
    local r, html, why
    for _, route in ipairs({ "/manga/getMangasConsultResult", "/manga/getMangasConsult" }) do
        html, why = post_form(route, body)
        r = attempt("POST " .. route, html, why)
        if r then return r end
    end

    local xhr = { ["X-Requested-With"] = "XMLHttpRequest" }
    html, why = get_html("/manga/getMangasConsultResult?" .. body, xhr)
    r = attempt("GET", html, why)
    if r then return r end

    if (term or "") == "" and page == 1 and #genres == 0 then
        html, why = get_html("/manga/consult")
        r = attempt("page", html, why)
        if r then return r end
    end
    return nil, table.concat(reasons, " ; ")
end

local function fail(reason)
    return { novels = {}, error = string.format(
        T("InManga : liste indisponible (%s). Voir sefirah/inmanga_last_error.txt"), tostring(reason or "?")) }
end

-- ── Extension ────────────────────────────────────────────────────────────────
local ext = {
    id      = "inmanga",
    name    = "InManga",
    site    = BASE,
    lang    = "es",
    version = "0.2.1",
    type    = "manga",
    popularFilters = {
        { key = "sort", label = T("Tri"), default = "1", options = SORT_OPTIONS },
        { key = "status", label = T("Statut"), default = "0", options = STATUS_OPTIONS },
        { key = "genre", label = T("Genre"), default = "", multi = true, options = GENRE_OPTIONS },
    },
    searchFilters = {},
    hasReviews = false,
    chapterCommentsPanel = false,
}

function ext:popularNovels(page, options)
    local f = (options and options.filters) or {}
    local r, why = consult("", page, { sort = f.sort, status = f.status, genre = f.genre })
    return r or fail(why)
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if term == "" then return ext:popularNovels(page, options) end
    local r, why = consult(term, page, {})
    return r or fail(why)
end

-- ── Fiche + chapitres ────────────────────────────────────────────────────────
local function split_path(path)
    local slug, id = tostring(path or ""):match("^(.-)/(" .. UUID_PAT .. ")$")
    if not slug then return nil end
    return slug, id:lower()
end

local function parse_meta(html, path, id)
    local m = { path = path, type = "manga", cover = cover_of(id) }
    local h1 = html:match("<h1[^>]*>(.-)</h1>")
    m.name = h1 and text_of(h1) or path
    local summary = html:match('</h1>.-<div[^>]-class="panel%-body"[^>]*>(.-)</div>')
    m.summary = summary and text_of(summary) or ""
    local st = html:match('<span[^>]-class="label[^"]*"[^>]*>%s*([^<]-)%s*</span>%s*<em[^>]-></em>%s*Estado')
    st = decode(st or ""):lower()
    m.status = (st:find("emisi", 1, true) or st:find("curso", 1, true)) and "Ongoing"
        or (st:find("finaliz", 1, true) or st:find("complet", 1, true)) and "Completed" or "Unknown"
    local pub = html:match('<span[^>]-class="label[^"]*"[^>]*>%s*(%d%d/%d%d/%d%d%d%d)%s*</span>')
    m.year = pub and pub:match("(%d%d%d%d)$") or nil
    m.no_author = true
    m.genres = {}
    m.rtl = true   -- manga japonais : lecture droite → gauche
    return m
end

local function fmt_number(n)
    if n == math.floor(n) then return string.format("%d", n) end
    return (string.format("%.2f", n):gsub("0+$", ""):gsub("%.$", ""))
end

-- Liste des chapitres via l'API JSON du site (non vérifiée : voir l'en-tête).
local function chapters_from_api(id)
    local body = get_html("/chapter/getall?mangaIdentification=" .. id, {
        ["X-Requested-With"] = "XMLHttpRequest",
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
    })
    if not body then return nil end
    local data = json_decode(body)
    if type(data) ~= "table" then return nil end
    -- « data » est une chaîne JSON à décoder une seconde fois (ou déjà une table).
    local inner = data.data
    if type(inner) == "string" then inner = json_decode(inner) end
    if type(inner) ~= "table" then inner = data end
    local list = inner.result or inner.Result
    if type(list) ~= "table" then return nil end
    local chapters, seen = {}, {}
    for _, c in ipairs(list) do
        local ok = pcall(function()
            local cid = str(c.Identification)
            local num = tonumber(c.Number) or tonumber((((str(c.FriendlyChapterNumber) or ""):gsub(",", ""))))
            if cid and not seen[cid:lower()] then
                seen[cid:lower()] = true
                chapters[#chapters + 1] = {
                    name = "Capítulo " .. (num and fmt_number(num) or (str(c.FriendlyChapterNumber) or "?")),
                    path = id .. "|" .. cid:lower(),
                    chapter_number = num,
                    rtl = true,
                }
            end
        end)
        if not ok then logger.warn("InManga: chapitre ignoré (entrée illisible)") end
    end
    return chapters
end

-- Repli : liens de chapitres dans la page de la fiche.
local function chapters_from_html(html, id)
    local chapters, seen = {}, {}
    for a_tag in html:gmatch("<a%s[^>]-href%s*=%s*[^>]->") do
        local href = attr(a_tag, "href")
        local cid = href and href:match("/ver/manga/[^/]+/[^/]+/(" .. UUID_PAT .. ")")
        if cid and not seen[cid:lower()] then
            seen[cid:lower()] = true
            local label = attr(a_tag, "data-c-number") or href:match("/ver/manga/[^/]+/([^/]+)/")
            local num = tonumber(((label or ""):gsub(",", "")))
            chapters[#chapters + 1] = {
                name = "Capítulo " .. (num and fmt_number(num) or tostring(label or "?")),
                path = id .. "|" .. cid:lower(),
                chapter_number = num,
                rtl = true,
            }
        end
    end
    return chapters
end

local function sort_chapters(chapters)
    table.sort(chapters, function(a, b)
        local x, y = a.chapter_number, b.chapter_number
        if x and y and x ~= y then return x < y end
        return false
    end)
    for i, c in ipairs(chapters) do c.chapter_number = c.chapter_number or i end
    return chapters
end

local function fetch_manga(path, want_chapters)
    local slug, id = split_path(path)
    if not slug then return nil end
    local html = get_html("/ver/manga/" .. slug .. "/" .. id)
    if not html then return nil end
    local m = parse_meta(html, slug .. "/" .. id, id)
    if not want_chapters then return m end
    local chapters = chapters_from_api(id)
    if not chapters or #chapters == 0 then chapters = chapters_from_html(html, id) end
    if #chapters == 0 then dump_error("fiche sans chapitre : " .. path, html) end
    return m, sort_chapters(chapters)
end

function ext:parseNovelMeta(path)
    local m = fetch_manga(path, false)
    if not m then return nil end
    m.total_chapters = 0
    return m
end

function ext:parseNovel(path)
    local m, chapters = fetch_manga(path, true)
    if not m then
        logger.err("InManga: fiche introuvable", tostring(path))
        return nil
    end
    m.chapters = chapters
    m.totalPages = 1
    if #chapters == 0 then
        m.summary = T("⚠ Aucun chapitre reconnu (voir sefirah/inmanga_last_error.txt).")
            .. "\n\n" .. (m.summary or "")
    end
    return m
end

-- ── Pages d'un chapitre ──────────────────────────────────────────────────────
local function page_ids(cid)
    local html = get_html("/chapter/chapterIndexControls?identification=" .. cid, {
        ["X-Requested-With"] = "XMLHttpRequest",
    })
    if not html then return nil end
    local zone = html:match('<select[^>]-id%s*=%s*"PageList"[^>]*>(.-)</select>')
        or html:match('<select[^>]-PageListClass[^>]*>(.-)</select>')
    if not zone then
        dump_error("liste des pages introuvable : " .. cid, html)
        return nil
    end
    local ids, seen = {}, {}
    for raw in zone:gmatch('<option[^>]-value%s*=%s*"(' .. UUID_PAT .. ')"') do
        local v = raw:lower()
        if not seen[v] then seen[v] = true; ids[#ids + 1] = v end
    end
    return ids
end

-- Le CDN peut ne pas avoir une image : on teste la 1re (HEAD) ; seulement un 404/403 explicite
-- fait basculer sur l'adresse « officielle » du site (/page/getPageImage).
local function cdn_missing(url)
    local ok, https = pcall(require, "ssl.https")
    if not ok then return false end
    local _, code = https.request { url = url, method = "HEAD", timeout = 10,
        headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" } }
    return code == 404 or code == 403
end

function ext:parseChapterImages(path)
    local mid, cid = tostring(path or ""):match("^(" .. UUID_PAT .. ")|(" .. UUID_PAT .. ")$")
    if not mid then return nil, "bad_path" end
    mid, cid = mid:lower(), cid:lower()
    local ids = page_ids(cid)
    if not ids or #ids == 0 then return nil, "no_pages" end
    local function cdn(pid) return CDN .. "/i/m/" .. mid .. "/c/" .. cid .. "/o/" .. pid .. ".jpg" end
    local function api(pid) return BASE .. "/page/getPageImage/?identification=" .. pid end
    local build = cdn
    if cdn_missing(cdn(ids[1])) then build = api end
    local images = {}
    for _, pid in ipairs(ids) do images[#images + 1] = build(pid) end
    -- Le CDN d'images attend un Referer du site.
    return { images = images, headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" } }
end

function ext:parseChapter(path)
    return "<p>" .. T("Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.") .. "</p>"
end

return ext
