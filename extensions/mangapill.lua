-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- extensions/mangapill.lua — MangaPill (https://mangapill.com), manga en anglais.
-- Source MANGA (contrat : cf. extensions/mangadex.lua) : scraping HTML, écrite d'après
-- des pages réelles (accueil, fiche, chapitre). La RECHERCHE n'a pas été vue en vrai :
-- adresses essayées dans l'ordre, voir ext:searchNovels.
--
-- Chemins stockés (sans domaine) :
--   manga    : « <id>/<slug> »                       (ex. 3069/naruto)
--   chapitre : « /chapters/<id>-<n>/<slug>-chapter-N » (ex. /chapters/3069-10700500/naruto-chapter-700.5)
--
-- Si le site répond par un refus (Cloudflare…), le code HTTP est affiché et la réponse
-- est enregistrée dans sefirah/mangapill_last_error.txt.

local logger = require("logger")
local T      = require("core.i18n").T

local BASE = "https://mangapill.com"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

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

local function dump_error(label, body)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local f = io.open(dir .. "/mangapill_last_error.txt", "wb")
        if f then f:write(label .. "\n\n" .. tostring(body):sub(1, 200000)); f:close() end
    end)
end

local last_http = nil

local function get_html(path)
    local url = path:match("^https?://") and path or (BASE .. path)
    local body, code, extra = require("core.net").get(url, { headers = {
        ["User-Agent"] = UA,
        ["Accept"] = "text/html,application/xhtml+xml",
        ["Accept-Language"] = "en-US,en;q=0.8",
        ["Referer"] = BASE .. "/",
    }, timeout = 15 })
    if body and #body > 2 then return body end
    last_http = tostring(code)
    dump_error("requête échouée : " .. url .. "\ncode : " .. tostring(code), type(extra) == "string" and extra or "")
    logger.warn("MangaPill: échec", url, tostring(code))
    return nil, last_http
end

local function abs(u)
    if not u then return nil end
    if u:sub(1, 2) == "//" then return "https:" .. u end
    if u:sub(1, 1) == "/" then return BASE .. u end
    return u
end

-- ── Listes ───────────────────────────────────────────────────────────────────
-- Une série = lien /manga/<id>/<slug>. Titre : texte du lien / title / alt.
-- Couverture : <img> dans un lien de la série, ou n'importe quelle image
-- « …/mangapill/i/<id>.ext » (l'accueil n'affiche que des cartes de chapitres).
-- L'attribut alt des couvertures répète le titre (« Berserk Berserk ») : on ne garde qu'une moitié.
local function dedupe_title(t)
    t = tostring(t)
    local n = #t
    if n >= 3 and n % 2 == 1 then
        local h = (n - 1) / 2
        if t:sub(h + 1, h + 1) == " " and t:sub(1, h) == t:sub(h + 2) then return t:sub(1, h) end
    end
    return t
end

local function parse_list(html)
    local covers = {}
    for tag in html:gmatch("<img[^>]->") do
        local u = attr(tag, "data-src") or attr(tag, "src")
        local id = u and u:match("/i/(%d+)%.")
        if id and not covers[id] then covers[id] = abs(u) end
    end
    local novels, by_id = {}, {}
    for a_tag, inner in html:gmatch("(<a%s[^>]-href%s*=%s*[^>]->)(.-)</a>") do
        local href = attr(a_tag, "href")
        local id, slug
        if href then id, slug = href:match("/manga/(%d+)/([^/%?#\"']+)") end
        if id then
            local n = by_id[id]
            if not n then
                n = { path = id .. "/" .. slug, cover = covers[id] }
                by_id[id] = n
                novels[#novels + 1] = n
            end
            local title = attr(a_tag, "title")
            local img = inner:match("<img[^>]->")
            if (not title or title == "") and img then title = attr(img, "alt") end
            if not title or title == "" then title = text_of(inner) end
            if title and title ~= "" and not n.name then n.name = dedupe_title(decode(title)) end
        end
    end
    local out = {}
    for _, n in ipairs(novels) do
        if n.name then
            -- Pas d'image trouvée dans la page : on devine l'adresse standard des couvertures
            -- (le format réel, jpg / jpeg / webp, varie selon la série).
            if not n.cover then
                n.cover = "https://cdn.readdetectiveconan.com/file/mangapill/i/" .. n.path:match("^(%d+)") .. ".jpg"
            end
            out[#out + 1] = n
        end
    end
    return out
end

local function list_page(path)
    local html = get_html(path)
    if not html then
        return { novels = {}, error = T("MangaPill injoignable (code ") .. tostring(last_http) .. ")" }
    end
    local novels = parse_list(html)
    if #novels == 0 then
        dump_error("liste vide : " .. path, html)
        return { novels = {}, error = T("MangaPill : aucune série reconnue. Voir sefirah/mangapill_last_error.txt") }
    end
    return { novels = novels }
end

-- ── Filtres du site (relevés sur mangapill.com/search le 2026-10-11) ──────────
local TYPE_OPTIONS = {
    { id = "",          label = T("Tous") },
    { id = "manga",     label = "Manga" },
    { id = "novel",     label = "Novel" },
    { id = "one-shot",  label = "One-shot" },
    { id = "doujinshi", label = "Doujinshi" },
    { id = "manhua",    label = "Manhua" },
    { id = "oel",       label = "OEL" },
}
local STATUS_OPTIONS = {
    { id = "",                  label = T("Tous") },
    { id = "publishing",        label = T("En cours") },
    { id = "finished",          label = T("Terminé") },
    { id = "on hiatus",         label = T("En pause") },
    { id = "discontinued",      label = T("Abandonné") },
    { id = "not yet published", label = T("Pas encore publié") },
}
local GENRE_NAMES = {
    "Action", "Adventure", "Cars", "Comedy", "Dementia", "Demons", "Doujinshi", "Drama",
    "Ecchi", "Fantasy", "Game", "Gender Bender", "Harem", "Historical", "Horror", "Isekai",
    "Josei", "Kids", "Magic", "Martial Arts", "Mecha", "Military", "Music", "Mystery",
    "Parody", "Police", "Psychological", "Romance", "Samurai", "School", "Sci-Fi", "Seinen",
    "Shoujo", "Shoujo Ai", "Shounen", "Shounen Ai", "Slice of Life", "Space", "Sports",
    "Super Power", "Supernatural", "Thriller", "Tragedy", "Vampire", "Yaoi", "Yuri",
}
local GENRE_OPTIONS = { { id = "", label = T("Tous") } }
for _, g in ipairs(GENRE_NAMES) do GENRE_OPTIONS[#GENRE_OPTIONS + 1] = { id = g, label = g } end

-- ── Extension ────────────────────────────────────────────────────────────────
local ext = {
    id      = "mangapill",
    name    = "MangaPill",
    site    = BASE,
    lang    = "en",
    version = "0.1.0",
    type    = "manga",
    popularFilters = {
        { key = "type", label = T("Type"), default = "manga", options = TYPE_OPTIONS },
        { key = "status", label = T("Statut"), default = "", options = STATUS_OPTIONS },
        -- Sélection multiple : le site combine les genres cochés (ET).
        { key = "genre", label = T("Genre"), default = "", multi = true, options = GENRE_OPTIONS },
    },
    searchFilters = {},
    hasReviews = false,
    chapterCommentsPanel = false,
}

function ext:popularNovels(page, options)
    page = tonumber(page) or 1
    local f = (options and options.filters) or {}
    local ty, st = f.type or "", f.status or ""
    local genres = f.genre or ""
    -- Une recherche à champ VIDE sans aucun filtre n'affiche rien sur le site.
    if ty == "" and st == "" and genres == "" then
        return { novels = {}, error = T("MangaPill : choisis au moins un filtre (type, statut ou genre).") }
    end
    local path = "/search?q=&type=" .. url_encode(ty) .. "&status=" .. url_encode(st)
    for g in tostring(genres):gmatch("[^,]+") do
        path = path .. "&genre=" .. url_encode(g)
    end
    return list_page(path .. "&page=" .. page)
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if term == "" then return ext:popularNovels(page, options) end
    page = page or 1
    local q = url_encode(term)
    -- /search?q=… est la recherche complète ; /quick-search?q=… (utilisée par la boîte de
    -- recherche du site) sert de repli.
    local candidates = {
        "/search?q=" .. q .. "&type=&status=&page=" .. page,
        "/quick-search?q=" .. q,
    }
    local last
    for _, path in ipairs(candidates) do
        local html = get_html(path)
        if html then
            local novels = parse_list(html)
            if #novels > 0 then return { novels = novels } end
            last = last or html
        end
    end
    if last then
        dump_error("recherche sans résultat : " .. term, last)
        return { novels = {}, error = T("MangaPill : recherche sans résultat (voir sefirah/mangapill_last_error.txt)") }
    end
    return { novels = {}, error = T("MangaPill injoignable (code ") .. tostring(last_http) .. ")" }
end

-- ── Fiche + chapitres ────────────────────────────────────────────────────────
local function chapter_number(href)
    local n = href:match("chapter[-_](%d+%.?%d*)[^%d]*$")
    return n and tonumber(n) or nil
end

local function parse_chapters(html)
    local chapters, seen = {}, {}
    for a_tag, inner in html:gmatch("(<a%s[^>]-href%s*=%s*[^>]->)(.-)</a>") do
        local href = attr(a_tag, "href")
        local path = href and href:match("(/chapters/[^%?#\"']+)")
        if path and not seen[path] then
            seen[path] = true
            local name = text_of(inner)
            if name == "" then name = text_of(attr(a_tag, "title") or "") end
            local num = chapter_number(path)
            if name == "" then name = "Chapter " .. (num and tostring(num) or path) end
            chapters[#chapters + 1] = { name = name, path = path, chapter_number = num, rtl = true }
        end
    end
    -- Le site liste du plus récent au plus ancien : ordre de lecture croissant.
    table.sort(chapters, function(a, b)
        local x, y = a.chapter_number, b.chapter_number
        if x and y and x ~= y then return x < y end
        return false
    end)
    for i, c in ipairs(chapters) do c.chapter_number = c.chapter_number or i end
    return chapters
end

local function parse_meta(html, path)
    local m = { path = path, type = "manga" }
    local h1 = html:match("<h1[^>]*>(.-)</h1>")
    m.name = h1 and dedupe_title(text_of(h1)) or path
    m.cover = abs(html:match('<meta[^>]-property%s*=%s*"og:image"[^>]-content%s*=%s*"([^"]*)"'))
    local p = html:match("</h1>.-<p[^>]*>(.-)</p>")
    m.summary = p and text_of(p) or ""
    local info = {}
    for label, val in html:gmatch('<label[^>]*>(%a+)</label>%s*<div>([^<]*)</div>') do
        info[label:lower()] = text_of(val)
    end
    local st = (info.status or ""):lower()
    m.status = (st == "finished" or st == "completed") and "Completed"
        or (st == "publishing" or st == "ongoing") and "Ongoing" or "Unknown"
    m.year = info.year
    m.no_author = true   -- le site n'affiche pas d'auteur : la fiche montre l'année à la place
    m.rtl = ((info.type or ""):lower() == "manga")   -- manga japonais : lecture droite → gauche
    local genres = {}
    for raw in html:gmatch('href="[^"]*search%?genre=([^"&]+)"') do
        local g = decode(raw):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end):gsub("%+", " ")
        genres[#genres + 1] = g
    end
    m.genres = genres
    return m
end

local function fetch_manga(path)
    local id, slug = tostring(path):match("^(%d+)/(.+)$")
    if not id then return nil end
    local html = get_html("/manga/" .. id .. "/" .. slug)
    if not html then return nil end
    local m = parse_meta(html, path)
    local zone = html:match('id%s*=%s*"chapters"(.*)') or html
    local chapters = parse_chapters(zone)
    if #chapters == 0 then dump_error("fiche sans chapitre : " .. path, html) end
    for _, c in ipairs(chapters) do c.rtl = m.rtl end
    return m, chapters
end

function ext:parseNovelMeta(path)
    local m = fetch_manga(path)
    if not m then return nil end
    m.total_chapters = 0
    return m
end

function ext:parseNovel(path)
    local m, chapters = fetch_manga(path)
    if not m then
        logger.err("MangaPill: fiche introuvable", tostring(path))
        return nil
    end
    m.chapters = chapters
    m.totalPages = 1
    if #chapters == 0 then
        m.summary = T("⚠ Aucun chapitre reconnu sur la page (voir sefirah/mangapill_last_error.txt).")
            .. "\n\n" .. (m.summary or "")
    end
    return m
end

-- ── Pages d'un chapitre ──────────────────────────────────────────────────────
function ext:parseChapterImages(path)
    local html = get_html(path)
    if not html then return nil, "chapter_unreachable" end
    local images, seen = {}, {}
    for tag in html:gmatch("<img[^>]->") do
        local cls = attr(tag, "class") or ""
        if cls:find("js-page", 1, true) then
            local u = abs(attr(tag, "data-src") or attr(tag, "src"))
            if u and not seen[u] then
                seen[u] = true
                images[#images + 1] = u
            end
        end
    end
    if #images == 0 then
        dump_error("chapitre sans image : " .. path, html)
        return nil, "no_pages"
    end
    -- Le CDN d'images attend un Referer du site.
    return { images = images, headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" } }
end

function ext:parseChapter(path)
    return "<p>" .. T("Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.") .. "</p>"
end

return ext
