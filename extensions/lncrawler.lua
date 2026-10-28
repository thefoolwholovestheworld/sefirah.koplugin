-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- extensions/lncrawler.lua — LNCrawler (https://lncrawler.monster), agrégateur de novels
-- venant de centaines de sites. Le site est une appli React : on lit directement son API JSON
-- (https://api.lncrawler.monster).
--
-- Chemins stockés (sans domaine) :
--   roman    : « <slug>/<source> »                 (ex. shadow-slave/novelfire-net)
--   chapitre : « <slug>/<source>/chapter/<n> »
--
-- VÉRIFIÉ sur de vraies réponses JSON fournies :
--   · recherche  GET /novels/search/?query=…&page=N&page_size=24&sort_by=title&sort_order=asc
--       → { count, total_pages, current_page, results = [ { title, slug, languages,
--           prefered_source = { source_slug, cover_min_url, authors, tags,
--           chapters_count, available_chapters_count, … } } ] }
--   · chapitre   GET /novels/<slug>/<source>/chapter/<n>/
--       → { chapter_id, title, body (HTML, commence par <h1>), prev_chapter, next_chapter }
--   · fiche      GET /novels/<slug>/<source>/   (réponse réelle fournie le 25/10/2026)
--       → champs de LA SOURCE au premier niveau (title, synopsis, status, authors, tags,
--           cover_url, language, chapters_count, available_chapters_count, …) ET
--           novel = { title, slug, sources = [ { source_slug, source_name, language,
--           chapters_count, available_chapters_count, last_chapter_update, … } ], … }
--           → `novel.sources` sert au choix de la source (ext:listSources).
--   · filtres    GET /novels/search/?query=…&tag=…&author=…&language=…&min_rating=3.5
--       &sort_by=title|date_added&sort_order=asc|desc  (URL du site + réponse réelle, 25/10/2026)
--   · avis     GET /novels/<slug>/comments/  (réponse réelle fournie le 25/10/2026, voir parseReviews)
-- NON VÉRIFIÉ (aucune réponse fournie) :
--   · plusieurs valeurs pour tag / language / exclusion (répété ou séparé par des virgules ?),
--     le nom du paramètre d'exclusion et du contenu adulte, et les valeurs de sort_by autres que
--     title / date_added : voir la table PARAM et MULTI_MODE ci-dessous (un seul endroit à changer) ;
--   · les titres de la liste : /novels/<slug>/<source>/chapterlist/ — essayée, sinon les
--     chapitres sont numérotés 1…N (« Chapter N »), comme les chapitres de l'API (« chapter/N »).
--   · le tri « popularité » (sort_by=weekly_views) : repli sur le tri par titre si vide.
-- Si l'API répond par un refus, la réponse est enregistrée dans sefirah/lncrawler_last_error.txt.

local logger = require("logger")
local T      = require("core.i18n").T

local API  = "https://api.lncrawler.monster"
local SITE = "https://lncrawler.monster"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

-- ── Helpers ──────────────────────────────────────────────────────────────────
local function escape(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function url_encode(str)
    return (tostring(str):gsub("([^%w%-%.%_%~])", function(c) return string.format("%%%02X", c:byte()) end))
end

local function str(v)
    if type(v) == "string" then return v end
    if type(v) == "number" then return tostring(v) end
    return nil
end

local function dump_error(label, body, name)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local f = io.open(dir .. "/" .. (name or "lncrawler_last_error.txt"), "wb")
        if f then f:write(label .. "\n\n" .. tostring(body):sub(1, 200000)); f:close() end
    end)
end

local last_http = nil

local function get_json(url, quiet)
    local body, code, extra = require("core.net").get(url, { headers = {
        ["User-Agent"] = UA,
        ["Accept"] = "application/json",
        ["Referer"] = SITE .. "/",
    }, timeout = 20 })
    if not body or #body < 2 then
        last_http = tostring(code)
        if not quiet then
            dump_error("requête échouée : " .. url .. "\ncode : " .. tostring(code),
                type(extra) == "string" and extra or "")
            logger.warn("LNCrawler: échec", url, tostring(code))
        end
        return nil
    end
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then
        if not quiet then dump_error("JSON illisible : " .. url, body) end
        return nil
    end
    return data
end

-- ── Romans ───────────────────────────────────────────────────────────────────
local function split_path(path)
    local slug, source = tostring(path or ""):match("^/?([^/]+)/([^/]+)")
    return slug, source
end

-- La couverture « min » est en WebP, que KOReader ne sait pas toujours afficher :
-- le site publie aussi cover.jpg dans le même dossier.
local function cover_of(src)
    local c = str(src and src.cover_min_url)
    if not c then return nil end
    return (c:gsub("cover%.min%.webp$", "cover.jpg"))
end

local function join(list)
    local t = {}
    if type(list) == "table" then
        for _, v in ipairs(list) do
            if type(v) == "string" and v ~= "" then t[#t + 1] = v end
        end
    end
    return t
end

local function novel_of(r)
    local src = type(r.prefered_source) == "table" and r.prefered_source or nil
    local slug = str(r.slug)
    local source = src and str(src.source_slug)
    local title = str(r.title) or (src and str(src.title))
    if not slug or not source or not title then return nil end
    return { name = title, path = slug .. "/" .. source, cover = cover_of(src) }
end

local function search(params, page)
    local url = API .. "/novels/search/?" .. params .. "&page=" .. tostring(page or 1)
        .. "&page_size=24"
    -- Dernière requête de recherche : permet de la comparer à l'URL du site si un filtre ne réagit pas.
    dump_error(url, "", "lncrawler_last_url.txt")
    local data = get_json(url)
    local novels = {}
    if data and type(data.results) == "table" then
        for _, r in ipairs(data.results) do
            if type(r) == "table" then
                local n = novel_of(r)
                if n then novels[#novels + 1] = n end
            end
        end
    end
    return novels, data
end

local cache = {}

-- Retrouve les infos d'un roman via la recherche (titre ≈ slug) : fiable, car vérifiée.
local function find_in_search(slug, source)
    local q = slug:gsub("%-", " ")
    local _, data = search("query=" .. url_encode(q) .. "&sort_by=title&sort_order=asc", 1)
    if data and type(data.results) == "table" then
        for _, r in ipairs(data.results) do
            if type(r) == "table" and r.slug == slug then
                -- on préfère la source demandée si le roman en propose plusieurs
                local src = r.prefered_source
                if type(src) == "table" and (src.source_slug == source or not source) then
                    return r, src
                end
                return r, src
            end
        end
    end
    return nil
end

-- Liste des chapitres avec titres : tentative tolérante sur /chapterlist/ (non vérifiée).
local function try_titles(slug, source, total)
    local titles, count = {}, 0
    local base = API .. "/novels/" .. slug .. "/" .. source .. "/chapterlist/"
    for page = 1, 60 do
        local data = get_json(base .. "?page=" .. page, true)
        if not data then break end
        local arr = data.results or data.chapters or data.items or (data[1] and data) or nil
        if type(arr) ~= "table" or #arr == 0 then break end
        local got = 0
        for _, c in ipairs(arr) do
            if type(c) == "table" then
                local n = tonumber(c.chapter_id or c.chapter or c.number or c.id)
                local t = str(c.title)
                if n and t and t ~= "" then if not titles[n] then count = count + 1 end; titles[n] = t; got = got + 1 end
            end
        end
        if got == 0 then break end
        local pages = tonumber(data.total_pages)
        if not pages or page >= pages then break end
        if total and total > 0 and count >= total then break end
    end
    return titles
end

-- Sources d'un roman (réponse vérifiée : det.novel.sources). Mises en cache à part (30 min) :
-- le menu « Changer de source » ne doit pas relancer le chargement complet des chapitres.
local sources_cache = {}

local function parse_sources(det)
    local out = {}
    local list = type(det) == "table" and type(det.novel) == "table" and det.novel.sources
    if type(list) ~= "table" then return out end
    for _, s in ipairs(list) do
        if type(s) == "table" then
            local sid = str(s.source_slug)
            if sid then
                out[#out + 1] = {
                    source   = sid,
                    name     = str(s.source_name) or sid,
                    lang     = str(s.language) or "",
                    chapters = tonumber(s.available_chapters_count) or tonumber(s.chapters_count) or 0,
                    updated  = (str(s.last_chapter_update) or ""):sub(1, 10),
                }
            end
        end
    end
    return out
end

local function fetch_detail(slug, source, quiet)
    local det = get_json(API .. "/novels/" .. slug .. "/" .. source .. "/", quiet)
    if det then sources_cache[slug] = { t = os.time(), list = parse_sources(det) } end
    return det
end

-- LuaJIT (KOReader) n'a pas la bibliothèque `utf8` de Lua 5.3 : encodage UTF-8 à la main.
local function utf8_char(cp)
    if not cp or cp < 1 or cp > 0x10FFFF then return "" end
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- Les synopsis de certaines sources sont du HTML brut (« <p>…</p><p>Show More</p> ») : on le
-- convertit en texte. Une source coupe parfois une phrase entre deux <p> (le suivant commence
-- alors par un tiret ou une minuscule) : ces morceaux sont recollés.
local function html_to_text(v)
    if type(v) ~= "string" then return nil end
    local t = v
    t = t:gsub("[Bb][Rr]%s*/?>", "\n")
    t = t:gsub("</[Pp]>", "\n")
    t = t:gsub("<[^>]*>", "")
    local ent = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }
    t = t:gsub("&(%a+);", function(n) return ent[n:lower()] end)
    t = t:gsub("&#(%d+);", function(n)
        return utf8_char(tonumber(n))
    end)
    local paras = {}
    for raw in (t .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local prev = paras[#paras]
            if prev and (line:find("^\226\128[\147\148]") or line:find("^%-") or line:find("^%l")) then
                paras[#paras] = prev .. " " .. line
            else
                paras[#paras + 1] = line
            end
        end
    end
    -- « Show More » / « Show Less » : libellé du site, pas du résumé.
    local last = paras[#paras]
    if last and (last:lower() == "show more" or last:lower() == "show less") then
        paras[#paras] = nil
    elseif last then
        paras[#paras] = last:gsub("%s*[Ss]how [MmLl][oe][rs][es]%s*$", "")
    end
    if #paras == 0 then return nil end
    return table.concat(paras, "\n\n")
end

local function load_novel(path)
    local c = cache[path]
    if c and os.time() - c.t < 600 then return c.data end
    local slug, source = split_path(path)
    if not slug then return nil end

    local title, total, author, genres, cover, summary, status = nil, 0, nil, nil, nil, nil, nil

    -- Fiche détaillée : réponse vérifiée, champs de la source au premier niveau.
    local det = fetch_detail(slug, source, true)
    if det then
        title   = str(det.title) or str(det.novel_title)
        summary = html_to_text(str(det.synopsis))
        status  = str(det.status)
        total   = tonumber(det.available_chapters_count) or tonumber(det.chapters_count) or 0
        author  = table.concat(join(det.authors), ", ")
        genres  = join(det.tags)
        cover   = str(det.cover_url)
    else
        -- Repli : données de la recherche (auteur, genres, couverture, nombre de chapitres).
        local r, src = find_in_search(slug, source)
        if not r then
            dump_error("roman introuvable : " .. tostring(path), "")
            return nil
        end
        title = str(r.title)
        if src then
            total  = tonumber(src.available_chapters_count) or tonumber(src.chapters_count) or 0
            author = table.concat(join(src.authors), ", ")
            genres = join(src.tags)
            cover  = cover_of(src)
        end
    end
    title = title or (slug:gsub("%-", " "))

    local titles = total > 0 and try_titles(slug, source, total) or {}
    local chapters = {}
    for n = 1, total do
        local name = "Chapter " .. n
        if titles[n] then name = titles[n] end
        chapters[n] = { name = name, path = slug .. "/" .. source .. "/chapter/" .. n, chapter_number = n }
    end

    local data = {
        name = title, path = path, cover = cover, summary = summary or "",
        author = author or "", genres = genres or {}, status = status or "Ongoing",
        chapters = chapters, totalPages = 1,
    }
    cache[path] = { t = os.time(), data = data }
    return data
end


-- ── Filtres (ceux du site : écran « Rechercher des romans ») ─────────────────────────────────
-- Paramètres d'URL. VÉRIFIÉS : query, tag (une valeur), author, language, min_rating, sort_by
-- (title, date_added), sort_order. SUPPOSÉS (le site ne les montre pas dans les URL fournies) :
-- exclude, adult et les sort_by « rating », « total_views », « weekly_views », « last_updated ».
-- Si le site utilise d'autres noms, il suffit de les changer ici.
local PARAM = {
    query = "query", tag = "tag", exclude = "exclude_tag", author = "author",
    language = "language", min_rating = "min_rating",
    sort_by = "sort_by", sort_order = "sort_order", adult = "adult",
}
-- Plusieurs valeurs d'un même filtre : "repeat" → tag=A&tag=B ; "comma" → tag=A,B.
local MULTI_MODE = "repeat"

-- Tags proposés (noms exacts du site, les plus fréquents ; les autres : « Autres tags »).
local TAGS = {
    "Fantasy", "Romance", "Action", "Adventure", "Comedy", "Drama", "Slice of Life", "Harem",
    "Martial Arts", "Adult", "Supernatural", "Science Fiction", "Xianxia", "Male Lead",
    "School Life", "Mystery", "Xuanhuan", "Josei", "Female Protagonist", "Historical",
    "Psychological", "Yaoi", "Tragedy", "System", "Shounen", "Shoujo", "Smut", "Cultivation", "Sports",
}
-- Langues du site (liste du filtre « Langue »), codes ISO.
local LANGS = {
    { "en", "Anglais" }, { "fr", "Français" }, { "es", "Espagnol" }, { "de", "Allemand" },
    { "it", "Italien" }, { "ja", "Japonais" }, { "ko", "Coréen" }, { "zh", "Chinois" },
    { "pt", "Portugais" }, { "ru", "Russe" }, { "ar", "Arabe" }, { "hi", "Hindi" },
    { "th", "Thaï" }, { "vi", "Vietnamien" }, { "id", "Indonésien" }, { "tr", "Turc" },
    { "pl", "Polonais" }, { "nl", "Néerlandais" }, { "sv", "Suédois" }, { "da", "Danois" },
}
local SORTS = {
    { "title", "Titre" }, { "rating", "Note" }, { "date_added", "Date d'ajout" },
    { "total_views", "Vues totales" }, { "weekly_views", "Tendance (vues hebdomadaires)" },
    { "last_updated", "Dernière mise à jour" },
}

local function tag_options()
    local o = { { id = "", label = "Aucun" } }
    for _, t in ipairs(TAGS) do o[#o + 1] = { id = t, label = t } end
    return o
end

-- `sort` / `order` : tri par défaut (Populaire : tendance décroissante ; recherche : titre).
local function make_filters(sort, order)
    local langs = { { id = "", label = "Toutes les langues" } }
    for _, l in ipairs(LANGS) do langs[#langs + 1] = { id = l[1], label = l[2] } end
    local sorts = {}
    for _, x in ipairs(SORTS) do sorts[#sorts + 1] = { id = x[1], label = x[2] } end
    local ratings = { { id = "", label = "Toutes les notes" } }
    for _, r in ipairs({ "0", "0.5", "1", "1.5", "2", "2.5", "3", "3.5", "4", "4.5", "5" }) do
        ratings[#ratings + 1] = { id = r, label = "★ " .. r .. "+" }
    end
    return {
        { key = "sort",    label = "Trier par", default = sort, options = sorts },
        { key = "order",   label = "Ordre", default = order, options = {
            { id = "asc", label = "Croissant" }, { id = "desc", label = "Décroissant" } } },
        { key = "tags",    label = "Tags à inclure", default = "", multi = true, options = tag_options() },
        { key = "tags_x",  label = "Tags à exclure", default = "", multi = true, options = tag_options() },
        { key = "tags_o",  label = "Autres tags", default = "", multi = true, text = true,
          hint = "Tags séparés par des virgules", options = { { id = "", label = "" } } },
        { key = "author",  label = "Auteur", default = "", multi = true, text = true,
          hint = "Nom exact de l'auteur", options = { { id = "", label = "" } } },
        { key = "langs",   label = "Langues", default = "", multi = true, options = langs },
        { key = "rating",  label = "Note minimale", default = "", options = ratings },
        { key = "adult",   label = "Contenu adulte (R18)", default = "hide", options = {
            { id = "hide", label = "Masquer" }, { id = "show", label = "Afficher" },
            { id = "only", label = "Afficher uniquement" } } },
    }
end

local function split_csv(v, sep)
    local out = {}
    for raw in tostring(v or ""):gmatch("[^" .. (sep or ",") .. "]+") do
        local item = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if item ~= "" then out[#out + 1] = item end
    end
    return out
end

local function add_multi(parts, name, values)
    if #values == 0 then return end
    if MULTI_MODE == "comma" then
        parts[#parts + 1] = name .. "=" .. url_encode(table.concat(values, ","))
    else
        for _, v in ipairs(values) do parts[#parts + 1] = name .. "=" .. url_encode(v) end
    end
end

-- Construit la chaîne de paramètres à partir de la sélection du panneau de filtres.
-- `title_sort` : repli quand le tri choisi est refusé par le site (tri par titre).
local function build_params(term, f, title_sort)
    f = type(f) == "table" and f or {}
    local parts = {}
    if term and term ~= "" then parts[#parts + 1] = PARAM.query .. "=" .. url_encode(term) end
    local tags = split_csv(f.tags)
    for _, t in ipairs(split_csv(f.tags_o)) do tags[#tags + 1] = t end
    add_multi(parts, PARAM.tag, tags)
    add_multi(parts, PARAM.exclude, split_csv(f.tags_x))
    add_multi(parts, PARAM.author, split_csv(f.author, ";"))
    add_multi(parts, PARAM.language, split_csv(f.langs))
    if f.rating and f.rating ~= "" then parts[#parts + 1] = PARAM.min_rating .. "=" .. url_encode(f.rating) end
    if f.adult and f.adult ~= "" and f.adult ~= "hide" then
        parts[#parts + 1] = PARAM.adult .. "=" .. url_encode(f.adult)
    end
    local sort  = title_sort and "title" or (f.sort ~= "" and f.sort) or "title"
    local order = title_sort and "asc" or (f.order ~= "" and f.order) or "asc"
    parts[#parts + 1] = PARAM.sort_by .. "=" .. sort
    parts[#parts + 1] = PARAM.sort_order .. "=" .. order
    return table.concat(parts, "&")
end

-- ── Extension ────────────────────────────────────────────────────────────────
local ext = {
    id      = "lncrawler",
    name    = "LNCrawler",
    site    = SITE,
    lang    = "multi",
    version = "0.5.0",
    -- Avis = commentaires du roman (API JSON /novels/<slug>/comments/, voir parseReviews).
    maxReviews = 150,
    review_cache_rev = 2,
}

ext.popularFilters = make_filters("weekly_views", "desc")
ext.searchFilters  = make_filters("title", "asc")

-- Un tri refusé par le site (nom de sort_by inconnu) donne une page vide : on réessaie par titre.
local function filtered_search(term, page, options, default_sort)
    local f = (options and options.filters) or { sort = default_sort[1], order = default_sort[2] }
    local novels = search(build_params(term, f), page)
    if #novels == 0 and f.sort ~= "title" then
        novels = search(build_params(term, f, true), page)
    end
    return { novels = novels }
end

function ext:popularNovels(page, options)
    return filtered_search(nil, page, options, { "weekly_views", "desc" })
end

function ext:searchNovels(term, page, options)
    return filtered_search(term or "", page, options, { "title", "asc" })
end

-- Sources disponibles pour le roman de `path` (« <slug>/<source> »). Chaque source est un
-- roman à part pour Sefirah (autre chemin) : bibliothèque, progression et cache restent
-- séparés. Renvoie { { path, label, lang, chapters, updated, current } }, vide si inconnu.
function ext:listSources(path)
    local slug, current = split_path(path)
    if not slug then return {} end
    local c = sources_cache[slug]
    if not (c and os.time() - c.t < 1800) then
        fetch_detail(slug, current, true)
        c = sources_cache[slug]
    end
    local out = {}
    for _, s in ipairs(c and c.list or {}) do
        out[#out + 1] = {
            path     = slug .. "/" .. s.source,
            label    = string.format("%s · %s · %d ch", (s.lang ~= "" and s.lang:upper() or "?"), s.name, s.chapters),
            lang     = s.lang,
            chapters = s.chapters,
            updated  = s.updated,
            current  = (s.source == current),
        }
    end
    -- Les sources dans la langue du plugin passent en premier.
    local opts, seen = {}, {}
    for _, s in ipairs(out) do
        if s.lang ~= "" and not seen[s.lang] then seen[s.lang] = true; opts[#opts + 1] = { id = s.lang } end
    end
    local mine = require("core.i18n").matchLanguage(opts)
    table.sort(out, function(a, b)
        local am, bm = (mine ~= nil and a.lang == mine), (mine ~= nil and b.lang == mine)
        if am ~= bm then return am end
        if a.lang ~= b.lang then return a.lang < b.lang end
        if a.chapters ~= b.chapters then return a.chapters > b.chapters end
        return a.path < b.path
    end)
    return out
end

function ext:parseNovelMeta(path)
    local d = load_novel(path)
    if not d then return nil end
    return {
        name = d.name, path = d.path, cover = d.cover, summary = d.summary,
        author = d.author, status = d.status, total_chapters = #d.chapters,
    }
end

function ext:parseNovel(path)
    return load_novel(path)
end

-- Retire ce qui pourrait s'exécuter ou dupliquer le titre.
local function clean_body(body)
    body = body:gsub("^%s*<h1[^>]*>.-</h1>%s*", "")
    body = body:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt].-</[Ss][Cc][Rr][Ii][Pp][Tt]>", "")
    body = body:gsub("<[Ii][Ff][Rr][Aa][Mm][Ee].-</[Ii][Ff][Rr][Aa][Mm][Ee]>", "")
    return body
end

function ext:parseChapter(path)
    local slug, source = split_path(path)
    local num = tostring(path):match("/chapter/(%d+)")
    if not slug or not num then
        return "<p>" .. escape(T("Impossible de charger le chapitre.")) .. "</p>"
    end
    local data = get_json(API .. "/novels/" .. slug .. "/" .. source .. "/chapter/" .. num .. "/")
    if not data then return "<p>" .. escape(T("Impossible de charger le chapitre.")) .. "</p>" end
    local body = str(data.body)
    if not body or #body < 20 then
        dump_error("corps de chapitre introuvable : " .. tostring(path), "")
        return "<p>" .. escape(T("Impossible d'extraire le texte du chapitre.")) .. "</p>"
    end
    return clean_body(body)
end

-- ── Avis (commentaires du roman) ─────────────────────────────────────────────────────────────
-- VÉRIFIÉ sur une vraie réponse (25/10/2026) :
--   GET /novels/<slug>/comments/  →  [ { id, author_name, message, contains_spoiler,
--       created_at (ISO), upvotes, downvotes, vote_score, replies = [ … ], has_replies,
--       edited, … } ]
-- Les commentaires sont rattachés au roman (slug), pas à une source : tous les « ‹slug›/‹source› »
-- d'un même roman montrent donc les mêmes avis. La réponse est un simple tableau, sans pagination
-- connue : tout arrive en une page et le tri est fait ici.
local function plain(v)
    local t = tostring(v or "")
    t = t:gsub("[Bb][Rr]%s*/?>", "\n"):gsub("</[Pp]>", "\n\n"):gsub("<[^>]*>", "")
    t = t:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
        :gsub("&#x27;", "'"):gsub("&#39;", "'"):gsub("&nbsp;", " "):gsub("&amp;", "&")
    return (t:gsub("\n\n\n+", "\n\n"):match("^%s*(.-)%s*$"))
end

local function comment_body(c)
    if type(c) ~= "table" then return nil end
    local t = plain(str(c.message))
    if t == "" then return nil end
    if c.contains_spoiler == true then t = "[Spoiler] " .. t end
    return t
end

local function comment_author(c)
    local a = str(c.author_name)
    return (a and a ~= "") and a or "Anonyme"
end

-- Réponses récursives : chaque message est un avis autonome.
local function append_comments(list, parent_id, depth, out, seen)
    if type(list) ~= "table" then return end
    for _, c in ipairs(list) do
        if type(c) == "table" and not seen[c] then
            seen[c] = true
            local body = comment_body(c)
            local id = str(c.id)
            if body then
                out[#out + 1] = {
                    id = id, author = comment_author(c), content = body,
                    date = str(c.created_at),
                    likes = tonumber(c.upvotes) or 0,
                    dislikes = tonumber(c.downvotes) or 0,
                    parent_id = parent_id, depth = depth,
                }
            end
            append_comments(c.replies, id or parent_id, depth + 1, out, seen)
        end
    end
end

function ext:parseReviews(path, page, sort)
    page = page or 1
    if page > 1 then return { reviews = {}, has_more = false } end
    local slug = split_path(path)
    if not slug then return { reviews = {}, has_more = false } end

    local data = get_json(API .. "/novels/" .. slug .. "/comments/")
    if not data then
        return { reviews = {}, has_more = false, error = last_http or true }
    end
    -- Tableau direct (réponse vérifiée) ; on tolère aussi { results = [...] }.
    local list = data
    if type(data.results) == "table" then list = data.results end

    local items = {}
    append_comments(list, nil, 0, items, {})

    -- Tri côté client : newest | oldest | mostliked.
    table.sort(items, function(a, b)
        if sort == "mostliked" then
            local sa, sb = a.likes - a.dislikes, b.likes - b.dislikes
            if sa ~= sb then return sa > sb end
        end
        local da, db = a.date or "", b.date or ""
        if da ~= db then
            if sort == "oldest" then return da < db end
            return da > db
        end
        return (a.id or "") < (b.id or "")
    end)
    return { reviews = items, has_more = false }
end

return ext
