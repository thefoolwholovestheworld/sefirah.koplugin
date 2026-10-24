-- Sefirah — WEBTOON (éditeur officiel). Source manga en Lua.
-- Écrite d'après des pages réelles : accueil, fiche (list?title_no=…) et épisode (viewer).
-- Le moteur de recherche (/fr/search) et le classement (/fr/ranking/trending) n'ont pas été
-- vus en vrai : le même analyseur de cartes (parse_list) sert pour toutes les listes.
--
-- MULTILINGUE : WEBTOON publie un site par langue (/fr/, /en/, /es/, /de/, /id/, /th/,
-- /zh-hant/). La langue est un filtre « Langue » (Parcourir et recherche), français par défaut.
-- Les fiches et les épisodes gardent leur langue dans leur adresse (/en/action/…/list?…),
-- donc la lecture n'a besoin d'aucun réglage : seules les listes, le classement et la
-- recherche dépendent du filtre. Les pages des langues autres que /fr/ n'ont pas été vues en
-- vrai : les adresses de genre essaient « slice_of_life » puis « slice-of-life ».
local logger = require("logger")
local T = require("core.i18n").T
local ext = { type = "manga" }
local BASE = "https://www.webtoons.com"
local UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
local MAX_LIST_PAGES = 80   -- garde-fou : 10 épisodes par page, donc 800 épisodes max

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
    return (s:gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&nbsp;", " "):gsub("&amp;", "&"))
end
local function text_of(s)
    return (decode((s or ""):gsub("<[^>]+>", " ")):gsub("%s+", " "):match("^%s*(.-)%s*$")) or ""
end
-- Les tirets sont des quantificateurs en Lua : « data-url » doit devenir « data%-url »,
-- sinon l'attribut n'est jamais trouvé (c'était le bug des couvertures et des pages).
local function attr(tag, name)
    name = name:gsub("%-", "%%-")
    return tag:match("%f[%w_%-]" .. name .. '%s*=%s*"([^"]*)"') or tag:match("%f[%w_%-]" .. name .. "%s*=%s*'([^']*)'")
end
local function abs(u)
    if not u or u == "" then return nil end
    u = decode(u):gsub(" ", "%%20")
    if u:sub(1, 2) == "//" then return "https:" .. u end
    if u:sub(1, 1) == "/" then return BASE .. u end
    return u
end
local function real_img(tag)
    -- Vraie image : data-url (lazy-loading) avant src ; on ignore le pixel transparent.
    for _, k in ipairs({ "data-url", "data-src", "data-lazy-src", "src" }) do
        local u = attr(tag, k)
        if u and u ~= "" and not u:find("bg_transparency", 1, true) and not u:find("^data:") then
            return abs(u)
        end
    end
    local ss = attr(tag, "srcset") or attr(tag, "data-srcset")
    if ss then
        local first = ss:match("^%s*([^,%s]+)")
        if first then return abs(first) end
    end
    return nil
end
-- ── Langues du site ──────────────────────────────────────────────────────────
local DEFAULT_LANG = "fr"
local LANGUAGES = {
    { id = "fr",      label = "Français",         accept = "fr-FR,fr;q=0.9,en;q=0.7" },
    { id = "en",      label = "English",          accept = "en-US,en;q=0.9" },
    { id = "es",      label = "Español",          accept = "es-ES,es;q=0.9,en;q=0.7" },
    { id = "de",      label = "Deutsch",          accept = "de-DE,de;q=0.9,en;q=0.7" },
    { id = "id",      label = "Bahasa Indonesia", accept = "id-ID,id;q=0.9,en;q=0.7" },
    { id = "th",      label = "ไทย",              accept = "th-TH,th;q=0.9,en;q=0.7" },
    { id = "zh-hant", label = "繁體中文",          accept = "zh-TW,zh;q=0.9,en;q=0.7" },
}
local LANG_BY_ID = {}
for _, l in ipairs(LANGUAGES) do LANG_BY_ID[l.id] = l end

local function valid_lang(id)
    return (type(id) == "string" and LANG_BY_ID[id]) and id or DEFAULT_LANG
end
-- Langue lue dans une adresse (« /en/… » ou « https://www.webtoons.com/en/… »).
local function lang_of(path)
    local p = tostring(path or ""):gsub("^https?://[^/]+", "")
    return valid_lang(p:match("^/([%w%-]+)/"))
end

local function get(path)
    local url = path:match("^https?://") and path or BASE .. path
    local lang = lang_of(path)
    local body, code = require("core.net").get(url, { headers = {
        ["User-Agent"] = UA, ["Accept-Language"] = LANG_BY_ID[lang].accept, ["Referer"] = BASE .. "/" .. lang .. "/" }, timeout = 20 })
    if not body or #body < 100 then logger.warn("WEBTOON: requête échouée", url, tostring(code)); return nil end
    return body
end
local function url_encode(s)
    return (tostring(s):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", c:byte()) end))
end

-- ── Listes (accueil, classement, recherche) ──────────────────────────────────
-- On lit UNIQUEMENT l'intérieur de la balise <a>…</a> de chaque carte : l'ancienne version
-- regardait 1800 caractères avant le lien et prenait titre + couverture de la carte précédente.
local function parse_list(html)
    local out, seen = {}, {}
    local pos = 1
    while true do
        local s, e, open, inner = html:find("<a(%s[^>]-)>(.-)</a>", pos)
        if not s then break end
        pos = e + 1
        local href = decode(attr(open, "href") or "")
        local id = href:match("title_no=(%d+)")
        local path = href:match("(/[%w%-_]+/[^/?#\"']+/[^/?#\"']+/list%?[^\"'#]*title_no=%d+)")
        if id and path and not href:find("/viewer", 1, true) and not seen[id] then
            local title = inner:match('<[%a]+[^>]-class="[^"]*%f[%w]title%f[%W][^"]*"[^>]*>(.-)</')
                or inner:match('<[%a]+[^>]-class="[^"]*%f[%w]subj%f[%W][^"]*"[^>]*>(.-)</')
                or attr(open, "title") or attr(open, "aria-label")
            local cover
            for img in inner:gmatch("<img[^>]->") do
                cover = real_img(img)
                if not title or title == "" then title = attr(img, "alt") end
                if cover then break end
            end
            title = text_of(title or "")
            if title == "" or title == id then title = "WEBTOON " .. id end
            seen[id] = true
            out[#out + 1] = { name = title, path = path, cover = cover, type = "manga", id = id }
        end
    end
    return out
end

-- ── Filtres « Parcourir » (ui/browse.lua : ext.popularFilters) ───────────────
-- Un seul choix « Section » : un classement (/fr/ranking/<onglet>) OU une catégorie
-- (/fr/genres/<genre>). Le tri ne sert que pour les catégories.
local VIEW_OPTIONS = {
    { id = "trending",      label = T("Tendance") },
    { id = "popular",       label = T("Populaire") },
    { id = "originals",     label = T("Original") },
    { id = "canvas",        label = T("Canvas") },
    { id = "genres",        label = T("Tous les genres") },
    { id = "drama",         label = T("Drama") },
    { id = "fantasy",       label = T("Fantastique") },
    { id = "comedy",        label = T("Comédie") },
    { id = "action",        label = T("Action") },
    { id = "slice_of_life", label = T("Tranche de vie") },
    { id = "romance",       label = T("Romance") },
    { id = "super_hero",    label = T("Superhéros") },
    { id = "thriller",      label = T("Thriller") },
    { id = "sports",        label = T("Sport") },
    { id = "sf",            label = T("SF") },
    { id = "horror",        label = T("Horreur") },
    { id = "tiptoon",       label = T("Éducatif") },
    { id = "local",         label = T("Local") },
}
local RANKINGS = { trending = true, popular = true, originals = true, canvas = true }
local SORT_OPTIONS = {
    { id = "MANA",   label = T("Popularité") },
    { id = "LIKEIT", label = T("Likes") },
    { id = "UPDATE", label = T("Date") },
}
local LANG_FILTER = { key = "lang", label = T("Langue"), default = DEFAULT_LANG, options = LANGUAGES }
ext.popularFilters = {
    { key = "view", label = T("Section"), default = "trending", options = VIEW_OPTIONS },
    { key = "sort", label = T("Tri (genres)"), default = "MANA", options = SORT_OPTIONS },
    LANG_FILTER,
}
-- Recherche : filtre par genre (le genre est lu dans l'adresse /fr/<genre>/<série>/list).
local SEARCH_GENRES = { { id = "", label = T("Tous les genres") } }
for _, o in ipairs(VIEW_OPTIONS) do
    if not RANKINGS[o.id] and o.id ~= "genres" then SEARCH_GENRES[#SEARCH_GENRES + 1] = o end
end
ext.searchFilters = {
    { key = "genre", label = T("Genre"), default = "", options = SEARCH_GENRES },
    LANG_FILTER,
}
local function genre_of(n)
    local g = (n.path or ""):match("^/[^/]+/([^/]+)/") or ""
    return (g:gsub("%-", "_"))
end
local function filter_genre(all, genre)
    if not genre or genre == "" then return all end
    local out = {}
    for _, n in ipairs(all) do if genre_of(n) == genre then out[#out + 1] = n end end
    return out
end

local function valid(options, id, default)
    for _, o in ipairs(options) do if o.id == id then return id end end
    return default
end

-- Adresses candidates d'une section (classement ou genre) selon les filtres, dans l'ordre
-- d'essai. Le genre s'écrit « slice_of_life » sur /fr/ ; sur les autres langues on essaie
-- aussi la graphie à tirets, au cas où.
local function section_paths(f, lang)
    local view = valid(VIEW_OPTIONS, f.view, "trending")
    local root = "/" .. lang
    if RANKINGS[view] then return { root .. "/ranking/" .. view }, view end
    local sort = valid(SORT_OPTIONS, f.sort, "MANA")
    if view == "genres" then return { root .. "/genres?sortOrder=" .. sort }, view end
    local out = { root .. "/genres/" .. view .. "?sortOrder=" .. sort }
    local dashed = view:gsub("_", "-")
    if dashed ~= view then out[#out + 1] = root .. "/genres/" .. dashed .. "?sortOrder=" .. sort end
    return out, view
end

local function page_slice(all, page)
    local p = math.max(1, tonumber(page) or 1); local out = {}
    for i = (p - 1) * 20 + 1, math.min(#all, p * 20) do out[#out + 1] = all[i] end
    return { novels = out }
end
-- Minuscules sans accents, pour comparer un titre à la recherche.
local ACCENTS = { ["à"]="a",["â"]="a",["ä"]="a",["á"]="a",["ã"]="a",["å"]="a",["ç"]="c",["è"]="e",["é"]="e",["ê"]="e",["ë"]="e",
    ["ì"]="i",["í"]="i",["î"]="i",["ï"]="i",["ñ"]="n",["ò"]="o",["ó"]="o",["ô"]="o",["ö"]="o",["õ"]="o",["ù"]="u",["ú"]="u",
    ["û"]="u",["ü"]="u",["ÿ"]="y",["œ"]="oe",["’"]="'",["‘"]="'" }
local function norm(s)
    s = tostring(s or ""):lower()
    s = s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c) return ACCENTS[c] or c end)
    return (s:gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end
local function matches(title, term)
    local t, q = norm(title), norm(term)
    if q == "" then return false end
    if t:find(q, 1, true) then return true end
    for w in q:gmatch("%S+") do   -- tous les mots du terme présents
        if not t:find(w, 1, true) then return false end
    end
    return true
end

-- Catalogue local : toutes les catégories + les classements (listes rendues côté serveur,
-- ce sont celles qu'on sait lire). Gardé en mémoire le temps de la session.
local index_cache = {}   -- un catalogue par langue
local function build_index(lang)
    if index_cache[lang] then return index_cache[lang] end
    local all, seen, reached = {}, {}, false
    local root = "/" .. lang
    for _, p in ipairs({ root .. "/genres?sortOrder=MANA", root .. "/ranking/trending", root .. "/ranking/popular", root .. "/ranking/originals" }) do
        local html = get(p)
        if html then
            reached = true
            for _, n in ipairs(parse_list(html)) do
                if not seen[n.id] then seen[n.id] = true; all[#all + 1] = n end
            end
        end
    end
    if reached then index_cache[lang] = all end
    return all, reached
end

local last_search = { term = nil, lang = nil, all = nil }
function ext:searchNovels(term, page, options)
    term = tostring(term or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if term == "" then return self:popularNovels(page, options) end
    local filters = (options and options.filters) or {}
    local genre = valid(SEARCH_GENRES, filters.genre or "", "")
    local lang = valid_lang(filters.lang)
    if last_search.term == term and last_search.lang == lang and last_search.all then
        return page_slice(filter_genre(last_search.all, genre), page)
    end

    local found, reached = {}, false
    -- 1) Recherche du site (mots-clés), si sa page contient des résultats lisibles.
    for _, p in ipairs({ "/" .. lang .. "/search?keyword=", "/" .. lang .. "/search/originals?keyword=" }) do
        local html = get(p .. url_encode(term))
        if html then
            reached = true
            local ok = {}
            for _, n in ipairs(parse_list(html)) do
                if matches(n.name, term) then ok[#ok + 1] = n end
            end
            if #ok > 0 then found = ok; break end
        end
    end
    -- 2) Repli : on filtre les titres du catalogue local.
    if #found == 0 then
        local idx, r2 = build_index(lang)
        reached = reached or r2
        for _, n in ipairs(idx or {}) do
            if matches(n.name, term) then found[#found + 1] = n end
        end
    end
    if not reached then return { novels = {}, error = T("WEBTOON inaccessible pour le moment.") } end
    last_search = { term = term, lang = lang, all = found }
    return page_slice(filter_genre(found, genre), page)
end

function ext:popularNovels(page, options)
    local f = (options and options.filters) or {}
    local lang = valid_lang(f.lang)
    local candidates, view = section_paths(f, lang)
    if view == "trending" then candidates = { "/" .. lang .. "/ranking/trending", "/" .. lang .. "/ranking", "/" .. lang .. "/" } end
    local all, reached = {}, false
    for _, p in ipairs(candidates) do
        local html = get(p)
        if html then
            reached = true
            all = parse_list(html)
            if #all > 0 then break end
        end
    end
    if not reached then return { novels = {}, error = T("WEBTOON inaccessible pour le moment.") } end
    return page_slice(all, page)
end

-- ── Fiche ────────────────────────────────────────────────────────────────────
local function parse_meta(html, path)
    local name = html:match('<h1[^>]-class="subj"[^>]*>(.-)</h1>')
        or html:match('<meta[^>]-property="og:title"[^>]-content="([^"]+)"')
        or html:match("<title>(.-)</title>") or "WEBTOON"
    name = text_of(name):gsub("%s*|%s*WEBTOON%s*$", "")   -- ne coupe plus les titres contenant un « - »
    local cover = html:match('<meta[^>]-property="og:image"[^>]-content="([^"]+)"')
        or html:match('<meta[^>]-content="([^"]+)"[^>]-property="og:image"')
    cover = abs(cover)
    -- og:image est un carré recadré (crop540_540) : on demande l'affiche entière, comme dans les listes.
    if cover then cover = cover:gsub("%?type=[^&]*$", "?type=q90") end
    local summary = html:match('<p[^>]-class="summary"[^>]*>(.-)</p>')
        or html:match('<meta[^>]-property="og:description"[^>]-content="([^"]+)"') or ""
    local author = html:match('<div[^>]-class="author_area"[^>]*>(.-)</div>') or ""
    author = text_of(author:gsub("<button.-</button>", ""):gsub("<script.-</script>", ""))
    author = author:gsub("%s*,%s*", ", "):gsub("%s*%.%.%.%s*$", ""):gsub(",%s*$", "")
    local genre = html:match('<h2[^>]-class="genre[^"]*"[^>]*>(.-)</h2>')
    local day = text_of(html:match('<p[^>]-class="day_info"[^>]*>(.-)</p>') or "")
    local status = "Unknown"
    if day ~= "" then
        local d = day:lower()
        -- « terminé », « completed/completado », « finalizado », « abgeschlossen », « tamat », « 完結 », « จบ »
        local done = false
        for _, k in ipairs({ "termin", "complet", "fini", "finaliz", "abgeschlossen", "tamat", "完結", "完结", "จบ" }) do
            if d:find(k, 1, true) then done = true; break end
        end
        status = done and "Completed" or "Ongoing"
    end
    return { name = name, path = path, cover = cover, summary = text_of(summary), author = author,
        genres = genre and { text_of(genre) } or {}, status = status, type = "manga", rtl = false }
end
local function parse_episodes(html, into, seen)
    -- Seulement la liste (<ul id="_listUl">) : la page contient aussi un lien « premier épisode ».
    local zone = html:match('id="_listUl"(.-)</ul>')
    if not zone then return 0 end
    html = zone
    local added, pos = 0, 1
    while true do
        local s, e, open, inner = html:find("<a(%s[^>]-)>(.-)</a>", pos)
        if not s then break end
        pos = e + 1
        local href = decode(attr(open, "href") or "")
        local no = href:match("episode_no=(%d+)")
        local ep = href:match("(/[%w%-_]+/[^/?#\"']+/[^/?#\"']+/[^/?#\"']+/viewer%?[^\"'#]*)")
        if ep and no and not seen[no] then
            seen[no] = true
            local title = text_of(inner:match('<span[^>]-class="subj"[^>]*>(.-)</span>%s*<span') or inner:match('<span[^>]-class="subj"[^>]*>(.-)</span>') or "")
            if title == "" then title = "Épisode " .. no end
            into[#into + 1] = { name = title, path = abs(ep), chapter_number = tonumber(no), rtl = false }
            added = added + 1
        end
    end
    return added
end
-- all_pages=false : fiche seule (rapide, pour parseNovelMeta). true : tous les épisodes.
-- La liste est paginée par 10 épisodes (?page=N) ; l'ancienne version ne lisait que la page 1.
local function fetch(path, all_pages)
    local html = get(path); if not html then return nil end
    local m = parse_meta(html, path)
    local chapters, seen = {}, {}
    local per_page = parse_episodes(html, chapters, seen)
    if all_pages and per_page > 0 then
        local sep = path:find("?", 1, true) and "&" or "?"
        local page = 2
        while page <= MAX_LIST_PAGES do
            local h = get(path .. sep .. "page=" .. page)
            if not h then break end
            local n = parse_episodes(h, chapters, seen)
            if n == 0 or n < per_page then break end   -- page partielle = dernière page
            page = page + 1
        end
    end
    table.sort(chapters, function(a, b) return a.chapter_number < b.chapter_number end)
    m.chapters = chapters; m.totalPages = 1
    return m
end
-- ── Ouverture rapide d'une fiche ─────────────────────────────────────────────
-- La fiche appelle d'abord parseNovelMeta : si `total_chapters` est égal au nombre
-- d'épisodes déjà en cache, Sefirah réutilise le cache (1 seule requête). Avant, ce
-- nombre valait toujours 0 : la liste entière (10 épisodes par requête) était donc
-- retéléchargée à chaque ouverture. Ici le total est le numéro du dernier épisode lu sur
-- la page 1 (la plus récente en premier). Si la numérotation a des trous, on retombe sur
-- le rechargement complet, comme avant. `known` retient (pour la session) le vrai nombre
-- d'épisodes de chaque série quand une liste complète a été lue.
local known = {}   -- path -> { max = dernier n° d'épisode, count = nombre d'épisodes }
local function top_episode(chapters)
    local top = chapters and chapters[#chapters]   -- liste triée par numéro croissant
    return top and tonumber(top.chapter_number) or 0
end
function ext:parseNovelMeta(path)
    local m = fetch(path, false)
    if not m then return nil end
    local maxep = top_episode(m.chapters)
    local k = known[path]
    m.total_chapters = (k and k.max == maxep) and k.count or maxep
    return m
end
function ext:parseNovel(path)
    local m = fetch(path, true); if not m then return nil end
    if #m.chapters == 0 then
        m.summary = (m.summary or "") .. "\n\n" .. T("Aucun épisode reconnu. WEBTOON peut avoir modifié sa page ou demander une session web.")
    else
        known[path] = { max = top_episode(m.chapters), count = #m.chapters }
    end
    return m
end

-- Mise à jour incrémentale (ui/detail.lua : « delta »). `chapters_per_page = 1` fait que
-- `offset` est le nombre d'épisodes déjà en cache ; on ne lit que les pages les plus
-- récentes, jusqu'à retrouver un épisode déjà connu. Si le compte final ne tombe pas juste,
-- Sefirah refait de lui-même un chargement complet.
ext.chapters_per_page = 1
function ext:parsePage() return { chapters = {}, failed = true } end   -- inutilisée : voir parseChaptersFrom
function ext:parseChaptersFrom(path, offset)
    offset = tonumber(offset) or 0
    local sep = path:find("?", 1, true) and "&" or "?"
    local out, seen = {}, {}
    for page = 1, MAX_LIST_PAGES do
        local html = get(page == 1 and path or (path .. sep .. "page=" .. page))
        if not html then return { chapters = {}, failed = true } end
        local got = {}
        local n = parse_episodes(html, got, seen)
        local lowest
        for _, ch in ipairs(got) do
            local no = tonumber(ch.chapter_number)
            if no and (not lowest or no < lowest) then lowest = no end
            if no and no > offset then out[#out + 1] = ch end
        end
        if n == 0 or not lowest or lowest <= offset then break end   -- on a rejoint le cache
    end
    table.sort(out, function(a, b) return a.chapter_number < b.chapter_number end)
    return { chapters = out }
end

-- ── Pages d'un épisode ───────────────────────────────────────────────────────
function ext:parseChapterImages(path)
    local html = get(path); if not html then return nil, "chapter_unreachable" end
    -- On se limite à la zone de lecture pour ne pas ramasser les miniatures des autres épisodes.
    local zone = html:match('id="_imageList"(.*)') or html
    local images, seen = {}, {}
    for tag in zone:gmatch("<img[^>]->") do
        local cls = attr(tag, "class") or ""
        if cls:find("_images", 1, true) then
            local u = real_img(tag)
            if u and not seen[u] then seen[u] = true; images[#images + 1] = u end
        end
    end
    if #images == 0 then return nil, "no_pages" end
    return { images = images, headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" } }
end
function ext:parseChapter(path)
    return "<p>" .. T("Ce chapitre est un manga : il s’ouvre dans le lecteur d’images.") .. "</p>"
end
return ext
