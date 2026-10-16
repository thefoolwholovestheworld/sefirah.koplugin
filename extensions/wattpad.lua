-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- Wattpad extension for Sefirah
-- Site: https://www.wattpad.com
--
-- Chemins utilisés par l'extension :
--   roman    : "story/<storyId>"            (ex. story/328675409)
--   chapitre : "<partId>"                   (ex. 1293412583)
--
-- Stratégie (vérifiée sur des pages enregistrées de wattpad.com) :
--   * Recherche : page /search/<terme> rendue côté serveur (cartes
--     <a class="story-card" href=".../story/<id>">). La pagination « Charger plus
--     d'histoires » étant faite en JavaScript, on utilise d'abord l'API publique
--     /api/v3/stories (query / limit / offset) et on retombe sur le HTML pour la
--     page 1 si l'API ne répond pas.
--   * Fiche roman : la page /story/<id> ne contient PAS la liste des chapitres
--     (chargée en JS). La liste est lue dans la « Table des matières » de la
--     page du premier chapitre (<ul class="table-of-contents">), atteinte via le
--     lien « Commencer la lecture ». Repli : API /api/v3/stories/<id>?fields=parts.
--   * Chapitre : le texte est dans <pre><p data-p-id="...">…</p></pre>. Wattpad
--     découpe un long chapitre en plusieurs pages (<link rel="next" …/page/N>) :
--     on les enchaîne jusqu'à la dernière. Les pastilles de commentaires par
--     paragraphe (<button class="comment-marker">) sont retirées.
--
-- Les classes CSS de Wattpad (_2kR5x, NE7VZ...) sont générées et changent à
-- chaque déploiement : on s'appuie sur les attributs data-testid et sur la
-- structure, pas sur ces classes.

local BASE   = "https://www.wattpad.com"
local logger = require("logger")
local T      = require("core.i18n").T

-- ── Helpers texte / HTML ─────────────────────────────────────────────────────

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

local function unescape(s)
    s = s:gsub("&#x(%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);",  function(d) return utf8_encode(tonumber(d)) end)
    s = s:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">")
         :gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    return s
end

local function strip_tags(s)
    s = (s or ""):gsub("<[^>]+>", "")
    return unescape(s):match("^%s*(.-)%s*$") or ""
end

local function url_encode(str)
    return (tostring(str):gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return data
end

-- Les couvertures de liste sont en 80/100/144 px : on demande la version 256.
-- .../cover/<id>-100-k486215.jpg  ->  .../cover/<id>-256-k486215.jpg
local function upgrade_cover(u)
    if not u or u == "" then return nil end
    return (u:gsub("(/cover/%d+%-)%d+(%-[%w]+%.jpg)", "%1256%2"))
end

local function story_id_from(path)
    path = tostring(path or "")
    return path:match("/story/(%d+)") or path:match("^story/(%d+)")
        or path:match("^(%d+)$")
end

local function digits(s)
    local d = tostring(s or ""):gsub("[^%d]", "")
    return tonumber(d)
end

-- ── HTTP ─────────────────────────────────────────────────────────────────────

-- Accept-Language en : les libellés (Completed / Ongoing…) restent stables
-- quelle que soit la langue du compte.
local function http_get(url, accept, extra)
    local headers = {
        ["Accept"]          = accept or "text/html,application/xhtml+xml,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.9",
        ["User-Agent"]      = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                              .. "(KHTML, like Gecko) Chrome/124.0 Safari/537.36",
    }
    for k, v in pairs(extra or {}) do headers[k] = v end
    local body, code, prefix = require("core.net").get(url, { headers = headers, timeout = 12 })
    if not body then
        logger.err("Wattpad: http_get FAILED", url, tostring(code),
            type(prefix) == "string" and prefix:sub(1, 200) or "")
        return nil, code
    end
    return body
end

local function api_get(path_and_query, extra)
    local body = http_get(BASE .. path_and_query, "application/json", extra)
    if not body then return nil end
    local data = json_decode(body)
    if data == nil then
        logger.err("Wattpad: réponse JSON illisible pour", path_and_query, body:sub(1, 120))
    end
    return data
end

-- ── Listes de romans ─────────────────────────────────────────────────────────

local PAGE_SIZE = 15
local LIST_FIELDS = "stories(id,title,cover,user(name),completed,numParts)"

local function api_stories(query_string, page, lang_id)
    page = page or 1
    local url = "/api/v3/stories?" .. query_string
        .. (lang_id and ("&language=" .. lang_id) or "")
        .. "&limit=" .. PAGE_SIZE
        .. "&offset=" .. ((page - 1) * PAGE_SIZE)
        .. "&fields=" .. url_encode(LIST_FIELDS)
    local data = api_get(url)
    if type(data) ~= "table" or type(data.stories) ~= "table" then return nil end
    local novels = {}
    for _, s in ipairs(data.stories) do
        if s.id and s.title and s.title ~= "" then
            novels[#novels + 1] = {
                name  = tostring(s.title),
                path  = "story/" .. string.format("%d", tonumber(s.id)),
                cover = upgrade_cover(s.cover),
            }
        end
    end
    return novels
end

-- ── Filtre de langue ─────────────────────────────────────────────────────────
-- L'API filtre avec un identifiant numérique (language=<id>). Seul l'id de
-- l'anglais est documenté ; les autres ne sont pas publiés de façon fiable.
-- On les DÉCOUVRE donc à la première utilisation : on interroge l'API avec
-- language=1, 2, 3… et on garde l'id dont la langue renvoyée (champ
-- language(id,name), identique à celui des fiches) correspond au nom cherché.
-- Résultat mémorisé pour la session. Si rien ne correspond, le filtre est
-- ignoré (et journalisé) plutôt que de renvoyer une liste vide ou fausse.
local LANGS = {
    { id = "en", label = "Anglais",    pat = { "english" } },
    { id = "fr", label = "Français",   pat = { "fran", "french" } },
    { id = "es", label = "Espagnol",   pat = { "espa", "spanish" } },
    { id = "de", label = "Allemand",   pat = { "deutsch", "german" } },
    { id = "it", label = "Italien",    pat = { "italia" } },
    { id = "pt", label = "Portugais",  pat = { "portug" } },
    { id = "id", label = "Indonésien", pat = { "indones", "bahasa" } },
    { id = "tr", label = "Turc",       pat = { "turk", "t\195\188rk" } },
    { id = "ru", label = "Russe",      pat = { "russian", "\209\128\209\131\209\129" } },
    { id = "ar", label = "Arabe",      pat = { "arab", "\216\185\216\177\216\168" } },
}
local lang_ids = {}   -- code -> id numérique (ou false si introuvable)

local function lang_matches(def, name)
    name = tostring(name or ""):lower()
    for _, p in ipairs(def.pat) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

local function resolve_lang_id(code)
    if not code or code == "" then return nil end
    if lang_ids[code] ~= nil then return lang_ids[code] or nil end
    local def
    for _, l in ipairs(LANGS) do if l.id == code then def = l end end
    if not def then lang_ids[code] = false; return nil end
    local fields = url_encode("stories(id,language(id,name))")
    for n = 1, 30 do
        local data = api_get("/api/v3/stories?filter=hot&language=" .. n
            .. "&limit=3&fields=" .. fields)
        local st = type(data) == "table" and type(data.stories) == "table" and data.stories
        if st then
            for _, story in ipairs(st) do
                local lg = story.language
                if type(lg) == "table" and lang_matches(def, lg.name) then
                    lang_ids[code] = n
                    logger.dbg("Wattpad: langue", code, "= id", n, tostring(lg.name))
                    return n
                end
            end
        end
    end
    logger.warn("Wattpad: id de langue introuvable pour", code, "- filtre ignoré")
    lang_ids[code] = false
    return nil
end

-- Cartes de résultats rendues côté serveur sur /search/<terme>.
-- Chaque carte apparaît deux fois dans le HTML (variante mobile « shown-xxs »
-- puis variante large « hidden-xxs ») : on ne lit que le premier bloc.
local function parse_cards_html(html)
    local novels, seen = {}, {}
    for card in html:gmatch('<a class="story%-card"[^>]*>.-</a></li>') do
        local id = card:match('href="[^"]*/story/(%d+)')
        if id and not seen[id] then
            seen[id] = true
            local title = card:match('<div class="title"[^>]*>(.-)</div>')
                       or card:match('<span class="sr%-only">(.-)</span>')
            local cover = card:match('<img[^>]-src="([^"]+)"')
            title = strip_tags(title or "")
            if title ~= "" then
                novels[#novels + 1] = {
                    name  = title,
                    path  = "story/" .. id,
                    cover = upgrade_cover(cover),
                }
            end
        end
    end
    return novels
end

local function search_html(term, page)
    -- Pas de pagination fiable en HTML (« Charger plus » = JavaScript) : on ne
    -- sert que la page 1 ; les suivantes viennent de l'API.
    if (page or 1) > 1 then return {} end
    local html = http_get(BASE .. "/search/" .. url_encode(term))
    if not html then return {} end
    return parse_cards_html(html)
end

-- ── Filtres « Parcourir » ────────────────────────────────────────────────────
-- Tri : /api/v3/stories?filter=hot|new. Le genre est traité comme une
-- recherche par mot-clé (comme les pastilles de tags de Wattpad).
local function lang_filter()
    local opts = { { id = "", label = "Toutes" } }
    for _, l in ipairs(LANGS) do opts[#opts + 1] = { id = l.id, label = l.label } end
    return { key = "lang", label = "Langue", default = "", options = opts }
end

local POPULAR_FILTERS = {
    {
        key = "sort", label = "Tri", default = "hot",
        options = {
            { id = "hot", label = "Populaires" },
            { id = "new", label = "Nouveautés" },
        },
    },
    lang_filter(),
    {
        key = "genre", label = "Genre", default = "",
        options = {
            { id = "",              label = "Tous" },
            { id = "fanfiction",    label = "Fanfiction" },
            { id = "romance",       label = "Romance" },
            { id = "fantasy",       label = "Fantasy" },
            { id = "action",        label = "Action" },
            { id = "adventure",     label = "Aventure" },
            { id = "mystery",       label = "Mystère" },
            { id = "thriller",      label = "Thriller" },
            { id = "horror",        label = "Horreur" },
            { id = "sciencefiction", label = "Science-fiction" },
            { id = "humor",         label = "Humour" },
            { id = "paranormal",    label = "Paranormal" },
            { id = "werewolf",      label = "Loups-garous" },
            { id = "historicalfiction", label = "Roman historique" },
            { id = "teenfiction",   label = "Roman ado" },
        },
    },
}

-- Recherche : mêmes filtres que Parcourir (tri, langue, genre). Le genre est
-- ajouté à la requête sous forme de mot-clé « #genre » (syntaxe de Wattpad).
local SEARCH_FILTERS = {
    {
        key = "sort", label = "Tri", default = "",
        options = {
            { id = "",    label = "Pertinence" },
            { id = "hot", label = "Populaires" },
            { id = "new", label = "Nouveautés" },
        },
    },
    lang_filter(),
    POPULAR_FILTERS[3],
}

-- ── Métadonnées d'une fiche roman ────────────────────────────────────────────

local function parse_meta(html)
    local title  = strip_tags(html:match('<h1[^>]-data%-testid="title"[^>]*>(.-)</h1>') or "")
    if title == "" then
        title = strip_tags(html:match('<h1[^>]*>(.-)</h1>') or "")
    end

    local author = html:match('<a[^>]-href="https://www%.wattpad%.com/user/[^"]+"[^>]*>([^<]+)</a>')
    author = strip_tags(author or "")

    local cover = html:match('data%-testid="cover"[^>]*>%s*<img[^>]-src="([^"]+)"')
    cover = upgrade_cover(cover) or cover

    -- Statut : <span data-testid="story-status-with-first-published-tooltip">Terminée</span>
    local status = "Unknown"
    local st = html:match('data%-testid="story%-status[^"]*"[^>]*>(.-)</span>')
    if st then
        st = strip_tags(st):lower()
        if st:find("termin") or st:find("complet") or st:find("abgeschlossen")
            or st:find("conclu") or st:find("finished") then
            status = "Completed"
        elseif st ~= "" then
            status = "Ongoing"
        end
    end

    -- Résumé : <div style="-webkit-line-clamp: 3;">texte<div data-testid="copyright">…
    local summary = ""
    local desc = html:match('%-webkit%-line%-clamp:%s*%d+;?"[^>]*>(.-)<div[^>]-data%-testid="copyright"')
    if desc and desc:match("%S") then
        desc = desc:gsub("<br[^>]*/?>", "\n")
        summary = strip_tags(desc)
    else
        local m = html:match('<meta name="description" content="([^"]*)"')
        if m then summary = strip_tags(m) end
    end

    -- Catégorie + mots-clés
    local genres, seen = {}, {}
    local function add(g)
        g = strip_tags(g)
        if g ~= "" and not seen[g:lower()] then
            seen[g:lower()] = true
            genres[#genres + 1] = g
        end
    end
    for lab in html:gmatch('data%-testid="label">([^<]+)') do add(lab) end
    local tags = html:match('data%-testid="tags"[^>]*>(.-)</div>')
    if tags then
        for inner in tags:gmatch('<a[^>]-href="https://www%.wattpad%.com/stories/[^"]+"[^>]*>(.-)</a>') do
            add(inner)
        end
    end

    -- Nombre de chapitres : 3ᵉ statistique de l'en-tête (Lectures, Votes, Chapitres).
    local tips = {}
    for tip in html:gmatch('data%-tip="([^"]*)"') do
        tips[#tips + 1] = tip
        if #tips == 3 then break end
    end
    local total = (#tips >= 3) and digits(tips[3]) or nil

    -- Lien du premier chapitre (couverture cliquable / « Commencer la lecture »).
    local first = html:match('href="https://www%.wattpad%.com/(%d+)[^"]*"[^>]*>%s*<div[^>]-data%-testid="cover"')
               or html:match('href="https://www%.wattpad%.com/(%d+)[%-"/?]')

    return {
        title    = title,
        author   = author,
        cover    = cover,
        status   = status,
        summary  = summary,
        genres   = table.concat(genres, ", "),
        total    = total,
        first_id = first,
    }
end

-- Cache de session (2 min) : ouvrir un roman depuis la notification de nouveau
-- chapitre enchaîne parseNovelMeta puis parseNovel — sans cache, la fiche était
-- téléchargée deux fois (~80 Ko chacune).
local CACHE_TTL = 120
local story_cache, chapters_cache = {}, {}

local function cached(tbl, key)
    local e = tbl[key]
    if e and os.time() - e.t < CACHE_TTL then return e.v end
    return nil
end

local function story_url(path)
    if tostring(path):match("^https?://") then return path end
    local id = story_id_from(path)
    if id then return BASE .. "/story/" .. id end
    return BASE .. "/" .. tostring(path):gsub("^/", "")
end

-- ── Liste des chapitres ──────────────────────────────────────────────────────

-- <ul class="table-of-contents"><li><a href="https://www.wattpad.com/<partId>-slug">
--   <div class="part-title"> Titre <div class="part-meta"></div></div></a></li>…
local function parse_toc(html)
    local chapters, seen = {}, {}
    local ul = html:match('<ul class="table%-of%-contents">(.-)</ul>')
    if not ul then return chapters end
    for li in ul:gmatch("<li[^>]*>(.-)</li>") do
        local id = li:match('href="https://www%.wattpad%.com/(%d+)')
        if id and not seen[id] then
            seen[id] = true
            local raw = li:match('<div class="part%-title">(.-)</div>') or ""
            raw = raw:gsub('<div class="part%-meta".*$', "")
            local name = strip_tags(raw)
            local n = #chapters + 1
            if name == "" then
                name = T("Chapitre ") .. n
            elseif name:match("^%d+%.?$") then
                name = T("Chapitre ") .. name:match("%d+")
            end
            chapters[n] = { name = name, path = id, chapter_number = n }
        end
    end
    return chapters
end

local function chapters_from_api(story_id)
    local data = api_get("/api/v3/stories/" .. story_id
        .. "?fields=" .. url_encode("parts(id,title)"))
    local chapters = {}
    if type(data) == "table" and type(data.parts) == "table" then
        for i, p in ipairs(data.parts) do
            if p.id then
                local name = tostring(p.title or "")
                if name == "" then name = T("Chapitre ") .. i
                elseif name:match("^%d+%.?$") then name = T("Chapitre ") .. name:match("%d+") end
                chapters[#chapters + 1] = {
                    name = name,
                    path = string.format("%d", tonumber(p.id)),
                    chapter_number = i,
                }
            end
        end
    end
    return chapters
end

-- ── Extension ────────────────────────────────────────────────────────────────

local ext = {
    id      = "wattpad",
    name    = "Wattpad",
    site    = BASE,
    lang    = "multi",
    version = "1.1.0",
    popularFilters = POPULAR_FILTERS,
    searchFilters  = SEARCH_FILTERS,
    -- Pas d'onglet « Avis » ni de bouton commentaires sur la fiche du roman
    -- (Wattpad n'a pas d'avis). Les commentaires du chapitre ne passent plus
    -- par un panneau (appui sur l'indicateur de page) : ils sont ajoutés en
    -- texte à la fin du chapitre, comme novelfrance (cf. ext:parseChapter).
    hasReviews = false,
    chapterCommentsPanel = false,
}

local function do_search(term, page, f)
    f = f or {}
    term = tostring(term or "")
    local query = term
    if f.tag and f.tag ~= "" then query = term .. " #" .. f.tag end
    local lang_id = resolve_lang_id(f.lang)
    local qs = "query=" .. url_encode(query)
    local novels
    if f.sort and f.sort ~= "" then
        novels = api_stories(qs .. "&filter=" .. url_encode(f.sort), page, lang_id)
    end
    -- Tri ignoré/refusé par l'API : on retombe sur la recherche sans tri.
    if not novels or #novels == 0 then
        novels = api_stories(qs, page, lang_id)
    end
    if not novels or (#novels == 0 and page == 1) then
        logger.dbg("Wattpad: recherche API vide, repli HTML (langue/tri non filtrés) pour", query)
        novels = search_html(query, page)
    end
    logger.dbg("Wattpad: recherche", query, "page", page, "lang", tostring(f.lang), "->", #novels)
    return { novels = novels or {} }
end

function ext:searchNovels(term, page, options)
    local f = (options and options.filters) or {}
    return do_search(term, page or 1, { lang = f.lang, sort = f.sort, tag = f.genre })
end

function ext:popularNovels(page, options)
    page = page or 1
    local filters = (options and options.filters) or {}
    local genre = filters.genre or ""
    if genre ~= "" then
        return do_search(genre, page, { lang = filters.lang, sort = filters.sort })
    end
    local sort = filters.sort or "hot"
    local novels = api_stories("filter=" .. url_encode(sort), page, resolve_lang_id(filters.lang))
    if not novels or (#novels == 0 and page == 1) then
        logger.dbg("Wattpad: popularNovels API vide, repli sur une recherche HTML")
        novels = search_html("wattpad", page)
    end
    logger.dbg("Wattpad: popularNovels page", page, "->", #novels)
    return { novels = novels or {} }
end

local function story_meta(path)
    local key = story_id_from(path) or tostring(path)
    local m = cached(story_cache, key)
    if m then return m end
    local html = http_get(story_url(path))
    if not html then return nil end
    m = parse_meta(html)
    story_cache[key] = { t = os.time(), v = m }
    return m
end

function ext:parseNovelMeta(path)
    local m = story_meta(path)
    if not m then return nil end
    return {
        name           = m.title,
        path           = path,
        cover          = m.cover,
        summary        = m.summary,
        author         = m.author,
        status         = m.status,
        total_chapters = m.total or 0,
    }
end

function ext:parseNovel(path)
    local story_id = story_id_from(path)
    local m = story_meta(path)
    if not m then
        logger.err("Wattpad: parseNovel fetch failed", tostring(path))
        return nil
    end

    -- Liste des chapitres, par ordre de coût :
    --  1) cache de session ;
    --  2) API (un petit JSON, rapide) — retenue seulement si elle est complète
    --     (autant de chapitres que le compteur de la fiche) ;
    --  3) table des matières de la page du premier chapitre (~160 Ko).
    local chapters = story_id and cached(chapters_cache, story_id)
    if not chapters then
        chapters = {}
        if story_id then
            local api = chapters_from_api(story_id)
            if #api > 0 and (not m.total or #api >= m.total) then
                chapters = api
            end
        end
        if #chapters == 0 then
            if m.first_id then
                local ch_html = http_get(BASE .. "/" .. m.first_id)
                if ch_html then chapters = parse_toc(ch_html) end
            else
                logger.warn("Wattpad: lien du premier chapitre introuvable pour", path)
            end
            -- TOC tronquée : on prend l'API si elle en donne plus.
            if story_id and m.total and #chapters < m.total then
                local api = chapters_from_api(story_id)
                if #api > #chapters then chapters = api end
            end
        end
        if story_id and #chapters > 0 then
            chapters_cache[story_id] = { t = os.time(), v = chapters }
        end
    end
    logger.dbg("Wattpad: parseNovel", m.title, "chapitres =", #chapters)

    return {
        name       = m.title,
        path       = path,
        cover      = m.cover,
        summary    = m.summary,
        author     = m.author,
        genres     = m.genres,
        status     = m.status,
        chapters   = chapters,
        totalPages = 1,
    }
end

-- ── Chapitre ─────────────────────────────────────────────────────────────────

local KEEP = { b = true, i = true, u = true, em = true, strong = true, s = true,
               sub = true, sup = true }

local function clean_inline(inner)
    inner = inner:gsub("<(/?)([%w]+)([^>]*)>", function(slash, tag, attrs)
        tag = tag:lower()
        if tag == "br" then return "<br/>" end
        if tag == "img" then
            if slash ~= "" then return "" end
            local src = attrs:match('src="([^"]+)"')
            return src and ('<img src="' .. src .. '"/>') or ""
        end
        if KEEP[tag] then return "<" .. slash .. tag .. ">" end
        return ""
    end)
    return inner
end

-- Wattpad écrit les apostrophes en &apos; (absent de HTML 4) : le moteur de
-- rendu de KOReader l'affiche alors littéralement. On remplace toutes les
-- entités autres que &amp; &lt; &gt; par le caractère UTF-8 correspondant.
local NAMED = {
    apos = "'", quot = '"', nbsp = "\194\160", hellip = "\226\128\166",
    ndash = "\226\128\147", mdash = "\226\128\148",
    lsquo = "\226\128\152", rsquo = "\226\128\153",
    ldquo = "\226\128\156", rdquo = "\226\128\157",
}

local function normalize_entities(t)
    t = t:gsub("&#[xX](%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    t = t:gsub("&#(%d+);", function(d) return utf8_encode(tonumber(d)) end)
    t = t:gsub("&(%a+);", function(name) return NAMED[name] end)
    return t
end

-- Extrait les paragraphes d'une page de chapitre. `seen` évite les doublons
-- (une page enregistrée par un navigateur peut contenir plusieurs pages).
local function extract_paragraphs(html, seen, out)
    for pre_raw in html:gmatch("<pre>(.-)</pre>") do
        if pre_raw:find("data%-p%-id") then
            local pre = pre_raw
            -- Pastilles de commentaires par paragraphe : le chiffre à l'intérieur
            -- s'afficherait sinon comme du texte.
            pre = pre:gsub("<button.-</button>", "")
            for attrs, inner in pre:gmatch("<p([^>]*)>(.-)</p>") do
                local pid = attrs:match('data%-p%-id="([^"]+)"')
                if not (pid and seen[pid]) then
                    if pid then seen[pid] = true end
                    local body = normalize_entities(clean_inline(inner))
                    local visible = body:gsub("<br/>", ""):gsub("<[^>]+>", "")
                    if visible:match("%S") or body:find("<img") then
                        out[#out + 1] = "<p>" .. body:match("^%s*(.-)%s*$") .. "</p>"
                    end
                end
            end
        end
    end
end

function ext:parseChapter(path)
    local url = (tostring(path):match("^https?://") and path)
        or (BASE .. "/" .. tostring(path):match("(%d+)") )
    local seen, visited, out = {}, {}, {}

    local page_url, pages = url, 0
    while page_url and not visited[page_url] and pages < 60 do
        visited[page_url] = true
        pages = pages + 1
        local html = http_get(page_url)
        if not html then
            if pages == 1 then return T("<p>Erreur de chargement du chapitre.</p>") end
            logger.warn("Wattpad: page", pages, "du chapitre introuvable, texte partiel", url)
            break
        end
        extract_paragraphs(html, seen, out)

        -- Page suivante du même chapitre : <link rel="next" href=".../page/2">
        local nxt = html:match('<link rel="next" href="([^"]+)"')
        if nxt and nxt:match("^https?://[%w%.]*wattpad%.com/") then
            page_url = unescape(nxt)
        else
            page_url = nil
        end
    end

    if #out == 0 then
        return T("<p>Impossible d'extraire le texte du chapitre (chapitre payant, restreint ou page modifiée).</p>")
    end
    logger.dbg("Wattpad: parseChapter", url, "pages =", pages, "paragraphes =", #out)
    return self:_appendChapterComments(path, table.concat(out, "\n"))
end

-- ── Commentaires de chapitre ─────────────────────────────────────────────────
-- Endpoint (confirmé par capture) :
--   /v5/comments/namespaces/parts/resources/<partId>/comments?limit=N[&after=<curseur>]
-- Réponse : { comments = [...], pagination = { after = { resourceId = ... } } }.
-- Un seul fil mélange commentaires de chapitre (namespace "parts") et de
-- paragraphe ("paragraphs"). pagination.after disparaît à la dernière page. Le
-- curseur renvoyé utilise « _ » entre ses composants alors que le site envoie
-- « # » (partId#paragrapheId#horodatage#hash) : on convertit.
-- Les commentaires étiquetés « offensive » sont ignorés ; les réponses
-- (replyCount) ne sont pas récupérées, seulement comptées.
local comment_cursors = {}   -- partId -> { [page] = curseur }

local function fetch_comments(part_id, cursor)
    local base = "/v5/comments/namespaces/parts/resources/" .. part_id .. "/comments"
    local hdr = { ["Referer"] = BASE .. "/" .. part_id, ["Origin"] = BASE }
    local q = "?limit=10" .. ((cursor and cursor ~= "") and ("&after=" .. url_encode(cursor)) or "")
    local data = api_get(base .. q, hdr)
    if type(data) ~= "table" or type(data.comments) ~= "table" then
        local q2 = (cursor and cursor ~= "") and ("?after=" .. url_encode(cursor)) or ""
        data = api_get(base .. q2, hdr)
    end
    if type(data) ~= "table" or type(data.comments) ~= "table" then
        logger.warn("Wattpad: commentaires — réponse inattendue pour", base)
        return nil
    end

    local list = {}
    for _, c in ipairs(data.comments) do
        local offensive = false
        if type(c.labels) == "table" then
            for _, lab in ipairs(c.labels) do
                if tostring(lab) == "offensive" then offensive = true end
            end
        end
        local text = tostring(c.text or "")
        if not offensive and text:match("%S") then
            local user = type(c.user) == "table" and c.user or {}
            -- On garde aussi les pdp par défaut de Wattpad : tout le monde en a une.
            local avatar = user.avatar
            if type(avatar) ~= "string" or avatar == "" then avatar = nil end
            local replies = tonumber(c.replyCount) or 0
            if replies > 0 then
                text = text .. "\n↳ " .. replies .. (replies > 1 and T(" réponses") or T(" réponse"))
            end
            local cid = type(c.commentId) == "table" and c.commentId.resourceId or nil
            list[#list + 1] = {
                author  = (user.name and user.name ~= "") and tostring(user.name) or "Anonyme",
                content = text,
                avatar  = avatar,
                date    = c.created,
                id      = cid,
            }
        end
    end

    local nxt
    local after = type(data.pagination) == "table" and data.pagination.after
    if type(after) == "table" and after.resourceId then
        nxt = tostring(after.resourceId):gsub("_", "#")
    end
    return list, nxt
end

function ext:parseChapterComments(path, page)
    page = tonumber(page) or 1
    if page < 1 then page = 1 end
    local part_id = tostring(path):match("(%d+)")
    if not part_id then return { comments = {}, has_more = false, page = page } end

    local cur = comment_cursors[part_id]
    if page == 1 or not cur then
        cur = { [1] = "" }
        comment_cursors[part_id] = cur
    end

    local k = 1
    while cur[k + 1] do k = k + 1 end
    while k < page do
        local _, nxt = fetch_comments(part_id, cur[k])
        if not nxt then return { comments = {}, has_more = false, page = page } end
        cur[k + 1] = nxt
        k = k + 1
    end

    local list, nxt = fetch_comments(part_id, cur[page])
    if not list then
        return { comments = {}, has_more = false, page = page }
    end
    if nxt then cur[page + 1] = nxt end
    return { comments = list, has_more = (nxt ~= nil and #list > 0), page = page }
end

-- ── Commentaires de fin de chapitre (texte) ──────────────────────────────────
-- Même rendu que novelfrance : séparateur, titre « Commentaires » (repère
-- utilisé par ui/readerview.lua pour masquer la section), puis un bloc par
-- commentaire « Auteur — jj/mm/aaaa » + texte. Les pdp sont superposées par le
-- lecteur grâce au trailer LNREADER_META (chapterCommentMarks).
local function html_escape(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function format_comment_date(date)
    local y, m, d = tostring(date or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return nil end
    return string.format("%s/%s/%s", d, m, y)
end

function ext:_appendChapterComments(path, body_html)
    local part_id = tostring(path):match("(%d+)")
    if not part_id then return body_html end

    local PAGE_CAP = self._export_all_comments and 1000 or 5
    local ok, all = pcall(function()
        local list = {}
        local page, has_more = 1, true
        while has_more and page <= PAGE_CAP do
            local data = self:parseChapterComments(part_id, page)
            for _, c in ipairs((data and data.comments) or {}) do
                list[#list + 1] = c
            end
            has_more = data and data.has_more or false
            page = page + 1
        end
        return list
    end)
    if not ok then
        logger.warn("Wattpad: échec récupération des commentaires de fin de chapitre", tostring(all))
        return body_html
    end
    if #all == 0 then return body_html end

    local parts = { body_html, "<hr/>", "<p></p>", "<p>――――――――――――</p>",
                    "<h1>Commentaires</h1>", "<p></p>" }
    local marks = {}
    local NBSP = "\194\160" -- espaces insécables : html_to_text écrase les espaces normaux
    for _, c in ipairs(all) do
        local has_avatar = c.avatar and c.avatar ~= ""
        local author_date = c.author or "Anonyme"
        local date_str = format_comment_date(c.date)
        if date_str then author_date = author_date .. " — " .. date_str end
        local header = (has_avatar and string.rep(NBSP, 11) or "") .. author_date
        local content = html_escape(c.content):gsub("\n", "<br/>")
        parts[#parts + 1] = "<p><em>" .. html_escape(header) .. "</em><br/>" .. content .. "</p>"
        if has_avatar then
            marks[#marks + 1] = { avatar = c.avatar, author = c.author, needle = author_date }
        end
    end

    local out = table.concat(parts, "\n")
    if #marks > 0 then
        -- Téléchargement des pdp ici (on est déjà en ligne, le chapitre vient
        -- d'être récupéré) : le lecteur ne lit que le cache disque.
        local ok_a, Avatars = pcall(require, "core.avatars")
        if ok_a and Avatars and Avatars.prefetch then
            local urls = {}
            for _, m in ipairs(marks) do urls[#urls + 1] = m.avatar end
            pcall(Avatars.prefetch, urls)
        end
        local ok_j, JSON = pcall(require, "rapidjson")
        if not ok_j then JSON = require("json") end
        local ok_enc, encoded = pcall(JSON.encode, {
            chapterId = part_id,
            marks = {},
            chapterCommentMarks = marks,
        })
        if ok_enc and encoded then
            out = out .. "\n<!--LNREADER_META:" .. encoded .. "-->"
        end
    end
    return out
end

return ext
