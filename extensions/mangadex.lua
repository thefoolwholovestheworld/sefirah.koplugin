-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- extensions/mangadex.lua — MangaDex (API officielle https://api.mangadex.org)
-- Première source MANGA de Sefirah : contrat, recherche/Parcourir, fiche, liste des
-- chapitres, URLs des pages. Le téléchargement CBZ est dans core/manga.lua.
--
-- ══ CONTRAT « SOURCE MANGA » (étape 1) ══════════════════════════════════════
-- Une extension manga est une extension normale (mêmes méthodes que wattpad.lua :
-- searchNovels, popularNovels, parseNovelMeta, parseNovel) avec en plus :
--
--   ext.type = "manga"
--       Le lecteur texte n'est jamais utilisé pour cette source. Un appui sur un
--       chapitre télécharge les pages puis ouvre un CBZ dans le lecteur natif de
--       KOReader (étapes 9 à 13).
--
--   ext:parseChapterImages(path) -> { images = { url1, url2, … }, headers = {…}? }
--       `path` = le champ `path` d'une entrée de `chapters` (ici : l'UUID du
--       chapitre MangaDex). `images` est dans l'ordre de lecture. `headers`
--       (optionnel) est ajouté à chaque téléchargement d'image. En cas d'échec :
--       return nil, "raison" (même convention que parseChapter).
--
--   ext:parseChapter(path)
--       Non utilisée pour le manga ; renvoie un court message de secours si un
--       appelant la déclenche par erreur.
--
-- Chaque chapitre de `parseNovel().chapters` garde la forme habituelle
--   { name = "Vol. 3 Ch. 21 — Titre", path = "<uuid>", chapter_number = n }
-- et `parseNovel()` renvoie aussi `type = "manga"` pour la fiche.
--
-- ══ MEMO API MANGADEX (pour les étapes suivantes) ═══════════════════════════
--   Liste/recherche : GET /manga?title=…&limit=20&offset=…
--       &availableTranslatedLanguage[]=fr&includes[]=cover_art
--       &order[followedCount]=desc|order[latestUploadedChapter]=desc
--       &contentRating[]=safe&contentRating[]=suggestive
--   Couverture      : https://uploads.mangadex.org/covers/<mangaId>/<fileName>.256.jpg
--   Chapitres       : GET /manga/<id>/feed?translatedLanguage[]=fr&order[chapter]=asc
--                     &limit=500&offset=…  (pagination ; dédoublonner par n° de chapitre)
--   Pages           : GET /at-home/server/<chapterId>
--       -> { baseUrl, chapter = { hash, data = {…}, dataSaver = {…} } }
--       image = <baseUrl>/data/<hash>/<fichier>   (qualité complète)
--             | <baseUrl>/data-saver/<hash>/<fichier> (compressée, par défaut ici)
--   Un User-Agent explicite est obligatoire ; ne pas dépasser ~5 requêtes/s.

local logger = require("logger")
local T      = require("core.i18n").T

local BASE        = "https://api.mangadex.org"
local COVERS_BASE = "https://uploads.mangadex.org/covers"
local UA          = "Sefirah-KOReader/1.0 (+https://github.com/thefoolwholovestheworld/sefirah.koplugin)"
local PAGE_SIZE   = 20

-- Langue de lecture par défaut : français.
local DEFAULT_LANG = "fr"

local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return data
end

local function http_get(url, extra)
    local headers = { ["Accept"] = "application/json", ["User-Agent"] = UA }
    for k, v in pairs(extra or {}) do headers[k] = v end
    local body, code, prefix = require("core.net").get(url, { headers = headers, timeout = 15 })
    if not body then
        logger.err("MangaDex: http_get FAILED", url, tostring(code),
            type(prefix) == "string" and prefix:sub(1, 200) or "")
        return nil, code
    end
    return body
end

local function api_get(path_and_query)
    local body = http_get(BASE .. path_and_query)
    if not body then return nil end
    local data = json_decode(body)
    if data == nil then
        logger.err("MangaDex: JSON illisible pour", path_and_query)
    end
    return data
end

local function url_encode(str)
    return (tostring(str):gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- ── Filtres ──────────────────────────────────────────────────────────────────
local LANGUAGES = {
    { id = "fr", label = "Français" },
    { id = "en", label = "English" },
    { id = "es", label = "Español" },
    { id = "pt-br", label = "Português (BR)" },
    { id = "de", label = "Deutsch" },
    { id = "it", label = "Italiano" },
    { id = "pt", label = "Português (PT)" },
    { id = "nl", label = "Nederlands" },
    { id = "pl", label = "Polski" },
    { id = "ru", label = "Русский" },
    { id = "tr", label = "Türkçe" },
    { id = "id", label = "Bahasa Indonesia" },
    { id = "ar", label = "العربية" },
    { id = "ja", label = "日本語" },
    { id = "ko", label = "한국어" },
    { id = "zh", label = "中文 (简体)" },
    { id = "zh-hk", label = "中文 (繁體)" },
}

local LANG_FILTER = { key = "lang", label = T("Langue"), default = DEFAULT_LANG, options = LANGUAGES }

local POPULAR_FILTERS = {
    {
        key = "sort", label = T("Tri"), default = "followedCount",
        options = {
            { id = "followedCount",        label = T("Populaires") },
            { id = "latestUploadedChapter", label = T("Dernières sorties") },
            { id = "createdAt",            label = T("Nouveautés") },
        },
    },
    LANG_FILTER,
}

local SEARCH_FILTERS = { LANG_FILTER }

local ext = {
    id             = "mangadex",
    name           = "MangaDex",
    site           = "https://mangadex.org",
    lang           = "multi",
    version        = "1.0.1",
    type           = "manga",     -- cf. contrat ci-dessus
    popularFilters = POPULAR_FILTERS,
    searchFilters  = SEARCH_FILTERS,
    hasReviews     = false,
    chapterCommentsPanel = false,
}

-- ── Aides ────────────────────────────────────────────────────────────────────
local RATINGS = "&contentRating%5B%5D=safe&contentRating%5B%5D=suggestive&contentRating%5B%5D=erotica"
local INCLUDES = "&includes%5B%5D=cover_art&includes%5B%5D=author"

-- Le chemin d'un manga est « <uuid>|<langue> » : la langue choisie reste
-- attachée à l'entrée (bibliothèque, notifications) sans dépendre des filtres.
local function make_path(id, lang) return id .. "|" .. (lang or DEFAULT_LANG) end

local function split_path(path)
    path = tostring(path or "")
    local id, lang = path:match("^([%w%-]+)|([%w%-]+)$")
    if id then return id, lang end
    return path:match("^([%w%-]+)") or path, DEFAULT_LANG
end

local function pick_lang(map, lang)
    if type(map) ~= "table" then return nil end
    if type(map[lang]) == "string" and map[lang] ~= "" then return map[lang] end
    return nil
end

local function pick_title(attrs, lang)
    local t = pick_lang(attrs.title, lang)
    if t then return t end
    for _, alt in ipairs(attrs.altTitles or {}) do
        t = pick_lang(alt, lang)
        if t then return t end
    end
    t = pick_lang(attrs.title, "en")
    if t then return t end
    for _, v in pairs(attrs.title or {}) do
        if type(v) == "string" and v ~= "" then return v end
    end
    return "?"
end

local function rel(m, kind)
    for _, r in ipairs(m.relationships or {}) do
        if r.type == kind then return r end
    end
end

local function cover_of(m)
    local c = rel(m, "cover_art")
    local f = c and c.attributes and c.attributes.fileName
    if type(f) == "string" and f ~= "" then
        return COVERS_BASE .. "/" .. m.id .. "/" .. f .. ".256.jpg"
    end
end

local function authors_of(m)
    local names, seen = {}, {}
    for _, r in ipairs(m.relationships or {}) do
        if r.type == "author" and r.attributes and r.attributes.name and not seen[r.attributes.name] then
            seen[r.attributes.name] = true
            names[#names + 1] = r.attributes.name
        end
    end
    return #names > 0 and table.concat(names, ", ") or nil
end

local function to_novel(m, lang)
    local a = m.attributes or {}
    return { name = pick_title(a, lang), path = make_path(m.id, lang), cover = cover_of(m) }
end

local function list_manga(query, page, lang)
    page = page or 1
    local url = "/manga?limit=" .. PAGE_SIZE .. "&offset=" .. ((page - 1) * PAGE_SIZE)
        .. "&availableTranslatedLanguage%5B%5D=" .. url_encode(lang)
        .. "&hasAvailableChapters=true" .. RATINGS .. INCLUDES .. query
    local data = api_get(url)
    local novels = {}
    if type(data) == "table" and type(data.data) == "table" then
        for _, m in ipairs(data.data) do
            if m.id then novels[#novels + 1] = to_novel(m, lang) end
        end
    end
    return { novels = novels }
end

-- ── Étape 3 : recherche et Parcourir ─────────────────────────────────────────
function ext:searchNovels(term, page, options)
    local f = (options and options.filters) or {}
    local lang = (f.lang and f.lang ~= "") and f.lang or DEFAULT_LANG
    term = tostring(term or "")
    if term == "" then return list_manga("&order%5BfollowedCount%5D=desc", page, lang) end
    return list_manga("&title=" .. url_encode(term) .. "&order%5Brelevance%5D=desc", page, lang)
end

function ext:popularNovels(page, options)
    local f = (options and options.filters) or {}
    local lang = (f.lang and f.lang ~= "") and f.lang or DEFAULT_LANG
    local sort = (f.sort and f.sort ~= "") and f.sort or "followedCount"
    return list_manga("&order%5B" .. sort .. "%5D=desc", page, lang)
end

-- ── Étape 4 : fiche du manga ─────────────────────────────────────────────────
local STATUS = { completed = "Completed", ongoing = "Ongoing", hiatus = "Ongoing" }

local function fetch_manga(path)
    local id, lang = split_path(path)
    local data = api_get("/manga/" .. id .. "?" .. INCLUDES:sub(2))
    local m = type(data) == "table" and data.data
    if type(m) ~= "table" or not m.id then return nil end
    local a = m.attributes or {}
    local genres = {}
    for _, t in ipairs(a.tags or {}) do
        local n = t.attributes and (pick_lang(t.attributes.name, lang) or pick_lang(t.attributes.name, "en"))
        if n then genres[#genres + 1] = n end
    end
    return {
        name    = pick_title(a, lang),
        path    = make_path(m.id, lang),
        cover   = cover_of(m),
        summary = pick_lang(a.description, lang) or pick_lang(a.description, "en") or "",
        author  = authors_of(m),
        genres  = genres,
        status  = STATUS[a.status or ""] or "Unknown",
        original_language = a.originalLanguage,
        type    = "manga",
    }
end

function ext:parseNovelMeta(path)
    local m = fetch_manga(path)
    if not m then return nil end
    m.total_chapters = 0
    return m
end

-- ── Étape 5 : liste des chapitres ────────────────────────────────────────────
-- Un `null` JSON n'est PAS nil pour rapidjson (c'est un objet « vrai » en Lua) :
-- concaténer un volume / titre / chapitre nul faisait planter toute la liste
-- (cas de Berserk : chapitres sans volume ni titre). On ne garde donc que du texte.
local function str(v)
    if type(v) == "string" then return v ~= "" and v or nil end
    if type(v) == "number" then return tostring(v) end
    return nil
end

local function chapter_name(a)
    local parts = {}
    local vol, chap, title = str(a.volume), str(a.chapter), str(a.title)
    if vol then parts[#parts + 1] = "Vol. " .. vol end
    if chap then parts[#parts + 1] = "Ch. " .. chap end
    local label = #parts > 0 and table.concat(parts, " ") or "Oneshot"
    if title then label = label .. " — " .. title end
    return label
end

local function fetch_chapters(id, lang, rtl)
    local chapters, seen = {}, {}
    -- Bilan pour expliquer une liste vide : listés / externes / retirés / sans pages.
    local stats = { listed = 0, external = 0, unavailable = 0, nopages = 0, skipped = 0 }
    local offset, total, guard = 0, nil, 0
    while guard < 12 and (not total or offset < total) do
        guard = guard + 1
        local data = api_get("/manga/" .. id .. "/feed?limit=500&offset=" .. offset
            .. "&translatedLanguage%5B%5D=" .. url_encode(lang)
            .. "&order%5Bvolume%5D=asc&order%5Bchapter%5D=asc" .. RATINGS)
        if type(data) ~= "table" or type(data.data) ~= "table" then break end
        total = tonumber(data.total) or 0
        for _, c in ipairs(data.data) do
            -- pcall par chapitre : une entrée inattendue ne doit jamais faire
            -- perdre toute la liste.
            local ok_c, err_c = pcall(function()
                local a = c.attributes or {}
                stats.listed = stats.listed + 1
                -- Chapitres hébergés ailleurs (externalUrl), retirés (isUnavailable)
                -- ou vides : illisibles ici.
                local ext_url = str(a.externalUrl)
                local unavailable = (a.isUnavailable == true)
                local pages = tonumber(a.pages) or 0
                local readable = type(c.id) == "string" and ext_url == nil
                    and (not unavailable) and pages > 0
                if ext_url ~= nil then
                    stats.external = stats.external + 1
                elseif unavailable then
                    stats.unavailable = stats.unavailable + 1
                elseif pages <= 0 then
                    stats.nopages = stats.nopages + 1
                end
                if readable then
                    local chap = str(a.chapter)
                    local num = chap and ((str(a.volume) or "") .. "/" .. chap) or nil
                    if not num or not seen[num] then   -- une seule version par numéro
                        if num then seen[num] = true end
                        chapters[#chapters + 1] = {
                            name = chapter_name(a),
                            path = c.id,
                            chapter_number = tonumber(chap) or #chapters + 1,
                            rtl = rtl,   -- sens de lecture (japonais = droite→gauche), cf. ui/mangaopen.lua
                        }
                    end
                end
            end)
            if not ok_c then
                stats.skipped = stats.skipped + 1
                logger.warn("MangaDex: chapitre ignoré", tostring(c and c.id), tostring(err_c))
            end
        end
        if #data.data == 0 then break end
        offset = offset + 500
    end
    return chapters, stats.external, stats
end

-- Bilan de la dernière liste chargée par manga (affiché dans l'onglet Chapitres
-- quand il est vide, cf. ui/detail.lua) : explique POURQUOI il n'y a rien à lire.
local NOTES = {}

local function build_note(stats, readable)
    local lines = {}
    if stats.listed == 0 then
        lines[1] = T("MangaDex ne liste aucun chapitre dans cette langue.")
        return lines
    end
    lines[1] = string.format(T("MangaDex liste %d chapitres dans cette langue :"), stats.listed)
    lines[#lines + 1] = string.format(T("• %d lisibles"), readable)
    if stats.external > 0 then
        lines[#lines + 1] = string.format(T("• %d chez l'éditeur officiel (lien externe)"), stats.external)
    end
    if stats.unavailable > 0 then
        lines[#lines + 1] = string.format(T("• %d retirés (indisponibles)"), stats.unavailable)
    end
    if stats.nopages > 0 then
        lines[#lines + 1] = string.format(T("• %d sans pages"), stats.nopages)
    end
    if stats.skipped > 0 then
        lines[#lines + 1] = string.format(T("• %d ignorés (erreur de lecture)"), stats.skipped)
    end
    return lines
end

function ext:chaptersNote(path)
    local id, lang = split_path(path)
    return NOTES[id .. "|" .. lang]
end

function ext:parseNovel(path)
    local id, lang = split_path(path)
    local m = fetch_manga(path)
    if not m then
        logger.err("MangaDex: parseNovel fetch failed", tostring(path))
        return nil
    end
    local external, stats
    local rtl = (m.original_language == "ja")
    m.chapters, external, stats = fetch_chapters(id, lang, rtl)
    NOTES[id .. "|" .. lang] = build_note(stats, #m.chapters)
    m.totalPages = 1
    -- Repli : aucun chapitre lisible dans la langue choisie -> on tente l'anglais
    -- (cas fréquent : titre licencié en français, scans anglais encore en ligne).
    local fallback_note
    if #m.chapters == 0 and lang ~= "en" then
        local en_chapters = fetch_chapters(id, "en", rtl)
        if #en_chapters > 0 then
            m.chapters = en_chapters
            fallback_note = T("ℹ Aucun chapitre lisible dans cette langue : chapitres en anglais affichés.")
        end
    end
    -- Titre licencié : MangaDex renvoie vers l'éditeur officiel, sans pages lisibles.
    if fallback_note then
        m.summary = fallback_note .. "\n\n" .. (m.summary or "")
    elseif #m.chapters == 0 or (external or 0) > #m.chapters then
        local note = (#m.chapters == 0)
            and T("⚠ Aucun chapitre lisible dans cette langue sur MangaDex")
            or T("⚠ Une partie des chapitres n'est disponible que chez l'éditeur officiel")
        if (external or 0) > 0 then note = note .. string.format(T(" (%d chapitres externes)"), external) end
        m.summary = note .. ".\n\n" .. (m.summary or "")
    end
    logger.dbg("MangaDex: parseNovel", m.name, "chapitres =", #m.chapters)
    return m
end

-- ── Étape 6 : URLs des pages d'un chapitre ───────────────────────────────────
-- Qualité compressée (« data-saver ») par défaut : beaucoup plus légère pour
-- l'e-ink. Réglage « manga_full_quality » (Réglages Sefirah) pour la qualité d'origine.
function ext:parseChapterImages(path)
    local id = split_path(path)
    local data = api_get("/at-home/server/" .. id)
    if type(data) ~= "table" or not data.baseUrl or type(data.chapter) ~= "table" then
        return nil, "at_home_unavailable"
    end
    local full = false
    local ok_s, Settings = pcall(require, "sefirah_settings")
    if ok_s and Settings and Settings:get("manga_full_quality") then full = true end

    local files = full and data.chapter.data or data.chapter.dataSaver
    local dir   = full and "data" or "data-saver"
    if type(files) ~= "table" or #files == 0 then
        files, dir = data.chapter.data, "data"   -- repli si pas de version compressée
    end
    if type(files) ~= "table" or #files == 0 or not data.chapter.hash then
        return nil, "no_pages"
    end

    local images = {}
    for _, f in ipairs(files) do
        images[#images + 1] = data.baseUrl .. "/" .. dir .. "/" .. data.chapter.hash .. "/" .. f
    end
    return { images = images, headers = { ["User-Agent"] = UA } }
end

-- Filet de sécurité : le lecteur texte ne doit jamais appeler ceci pour un manga.
function ext:parseChapter(path)
    return "<p>" .. T("Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.") .. "</p>"
end

return ext
