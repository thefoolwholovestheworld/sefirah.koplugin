-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- SkyNovels extension for Sefirah.koplugin
-- Site : https://www.skynovels.net/
-- API  : https://api.skynovels.net/api/   (JSON pur, aucun HTML à parser)
--
--   GET novels?page=N[&order=rating|updated][&genres=9,4][&q=terme]
--        -> { novels = [ { id, nvl_title, nvl_name, image, nvl_writer, ... } ] }
--   GET novel/<id>/reading
--        -> { novel = [ { ..., genres, volumes = [ { chapters } ], novel_ratings } ] }
--   GET novel-chapter/<id>
--        -> { chapter = [ { chp_content, chp_index_title, ... } ] }
--
-- Format de `path` (identique au site) :
--   roman    : novelas/<novel_id>/<nvl_name>/
--   chapitre : novelas/<novel_id>/<nvl_name>/<chapter_id>/<chp_name>
--
-- ── Filtres ──────────────────────────────────────────────────────────────────
-- Le catalogue du site propose État / Trier par / Origine / Genres. Seuls
-- `genres`, `order` (rating|updated) et `q` sont des paramètres d'API vérifiés ;
-- les autres critères sont appliqués CÔTÉ PLUGIN sur les romans renvoyés (les
-- objets de la liste contiennent déjà le statut, le nombre de chapitres, la
-- note, la date de mise à jour...). Conséquence : une page peut contenir moins
-- de 20 romans quand un filtre client est actif — d'où FETCH_PAGES ci-dessous,
-- qui agrège plusieurs pages d'API pour remplir une page d'affichage.
-- Si un jour l'API expose ces critères, il suffira de les ajouter dans
-- build_endpoint() : le filtrage client redeviendra un simple filet de sécurité.

local BASE   = "https://www.skynovels.net"
local API    = "https://api.skynovels.net/api/"
local logger = require("logger")

local FETCH_PAGES = 3   -- pages d'API agrégées quand un filtre client est actif
local PAGE_SIZE   = 20  -- romans renvoyés par page d'affichage
local REVIEWS_PER_PAGE = 10  -- valeur utilisée par le site lui-même (capture réseau)

-- ── HTTP / JSON ──────────────────────────────────────────────────────────────

local function http_get(url)
    local body, code, snippet = require("core.net").get(url, {
        headers = {
            ["Accept"]        = "application/json, text/plain, */*",
            ["Cache-Control"] = "no-cache",
        },
        timeout = 10,
    })
    if not body then
        logger.err("SkyNovels: http_get FAILED", url, tostring(code),
                   (tostring(snippet or ""):sub(1, 160):gsub("%s+", " ")))
        return nil, code
    end
    return body
end

-- rapidjson décode le JSON `null` en un sentinelle de type userdata
-- (rapidjson.null), PAS en nil. Les champs à null (ex. "image": null pour un
-- utilisateur sans avatar) faisaient donc planter tout code du genre
-- `API .. image` (« attempt to concatenate a userdata value ») : c'est ce qui
-- vidait l'onglet Avis dès qu'un seul avis de la page avait un avatar null.
-- On les retire une fois pour toutes ici, pour tout le fichier.
local function strip_nulls(t)
    if type(t) ~= "table" then return t end
    for k, v in pairs(t) do
        local tv = type(v)
        if tv == "userdata" then
            t[k] = nil
        elseif tv == "table" then
            strip_nulls(v)
        end
    end
    return t
end

local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return strip_nulls(data)
end

local function api_get(endpoint)
    local body = http_get(API .. endpoint)
    if not body then return nil end
    local data = json_decode(body)
    if not data then
        logger.err("SkyNovels: JSON invalide pour", endpoint)
        return nil
    end
    return data
end

-- Essaie plusieurs variantes d'un endpoint. SkyNovels a changé certains
-- chemins API au fil des versions ; cela évite qu'une seule variation casse
-- la lecture ou l'onglet Avis.
local function api_get_first(endpoints)
    for _, endpoint in ipairs(endpoints) do
        local data = api_get(endpoint)
        if data then return data, endpoint end
    end
    return nil, nil
end

-- Liste (triée) des clés de premier niveau d'une table, pour le journal.
-- Sert uniquement à diagnostiquer un changement de format d'API sans avoir
-- à republier une nouvelle version à l'aveugle : si "contenu introuvable"
-- ou "aucun avis" réapparaît, ces clés (visibles dans les logs KOReader)
-- indiquent exactement quel champ l'API a renommé.
local function dump_keys(t)
    if type(t) ~= "table" then return "(" .. type(t) .. ")" end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return "{" .. table.concat(keys, ",") .. "}"
end

-- Un endpoint peut renvoyer soit un tableau à un élément ([1] = objet),
-- soit directement l'objet unique (sans enrobage tableau) selon la version
-- de l'API. On accepte les deux plutôt que de supposer une seule forme.
local function first_or_self(v)
    if type(v) ~= "table" then return nil end
    if type(v[1]) == "table" then return v[1] end
    if next(v) ~= nil then return v end
    return nil
end

local function url_encode(str)
    return (tostring(str):gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function cover_url(image)
    if type(image) ~= "string" or image == "" then return nil end
    return API .. "get-image/" .. image .. "/novels/false"
end

local function avatar_url(image)
    if type(image) ~= "string" or image == "" then return nil end
    return API .. "get-image/" .. image .. "/users/false"
end

-- ── Texte ────────────────────────────────────────────────────────────────────

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

local function strip_tags(s)
    s = tostring(s or "")
    s = s:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n\n")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&#x(%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);",  function(d) return utf8_encode(tonumber(d)) end)
    s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&nbsp;", " ")
    s = s:gsub("\n%s*\n%s*\n+", "\n\n")
    return s:match("^%s*(.-)%s*$") or ""
end

-- Comparaison insensible à la casse ET aux accents (le statut renvoyé par
-- l'API est "Activa"/"Finalizada", parfois accentué selon les entrées).
local ACCENTS = {
    ["á"]="a", ["à"]="a", ["ä"]="a", ["â"]="a", ["é"]="e", ["è"]="e", ["ë"]="e",
    ["ê"]="e", ["í"]="i", ["ì"]="i", ["ï"]="i", ["î"]="i", ["ó"]="o", ["ò"]="o",
    ["ö"]="o", ["ô"]="o", ["ú"]="u", ["ù"]="u", ["ü"]="u", ["û"]="u", ["ñ"]="n",
    ["ç"]="c",
}

local function fold(s)
    s = tostring(s or ""):lower()
    for from, to in pairs(ACCENTS) do s = s:gsub(from, to) end
    return s
end

-- IMPORTANT : on ne peut pas utiliser gmatch("[^/]+") ici, car il "avale"
-- les segments vides. Quand nvl_name est absent ou vide (ce qui arrive côté
-- API pour certains romans/certaines réponses), le chemin contient un double
-- slash ("novelas/123//456/nom") : avec [^/]+, ce double slash disparaît et
-- TOUS les index qui suivent se décalent d'une case — parts[4] devient alors
-- le nom (texte) du chapitre au lieu de son id numérique, et l'appel à
-- novel-chapter/<id> échoue systématiquement ("Error al obtener el
-- capítulo") pour tous les chapitres de tous les romans concernés.
-- En capturant "(.-)/", on conserve les segments vides et les index restent
-- fiables quel que soit le contenu de nvl_name.
local function split_path(path)
    local parts = {}
    for seg in (tostring(path or "") .. "/"):gmatch("(.-)/") do
        parts[#parts + 1] = seg
    end
    return parts -- [1]="novelas", [2]=novel_id, [3]=slug (peut être ""), [4]=chapter_id
end

-- ── Filtres ──────────────────────────────────────────────────────────────────

local STATUS_MATCH = {
    activa     = "activa",
    inactiva   = "inactiva",
    finalizada = "finalizada",
}

-- Mots-clés cherchés dans les champs texte du roman pour déduire son origine.
-- L'API ne documente pas de champ « origine » : on inspecte les valeurs texte
-- du roman (hors titre et synopsis, trop bruyants) à la recherche de ces mots.
local ORIGIN_KEYWORDS = {
    originales = { "original" },
    inglesas   = { "ingles", "english" },
    coreanas   = { "corean", "korean" },
    chinas     = { "chin" },
    japonesas  = { "japon", "japanese" },
}

local ORIGIN_IGNORED_KEYS = {
    nvl_content = true, nvl_title = true, nvl_name = true, nvl_acronym = true,
    image = true, createdAt = true, updatedAt = true,
}

local function origin_of(res)
    local found = {}
    for k, v in pairs(res) do
        if type(v) == "string" and not ORIGIN_IGNORED_KEYS[k] then
            found[#found + 1] = fold(v)
        end
    end
    return table.concat(found, " ")
end

local function matches_origin(res, want)
    local keywords = ORIGIN_KEYWORDS[want]
    if not keywords then return true end
    local haystack = origin_of(res)
    for _, kw in ipairs(keywords) do
        if haystack:find(kw, 1, true) then return true end
    end
    return false
end

-- Renvoie la première valeur numérique trouvée parmi plusieurs noms de champ
-- possibles (l'API n'expose pas les mêmes compteurs partout).
local function num_field(res, candidates)
    for _, key in ipairs(candidates) do
        local v = tonumber(res[key])
        if v then return v end
    end
    return nil
end

local SORT_FIELDS = {
    nombre        = { kind = "text", keys = { "nvl_title" } },
    popularidad   = { kind = "num",  keys = { "nvl_bookmarks", "bookmarks_count", "nvl_recommended", "nvl_rating" } },
    capitulos     = { kind = "num",  keys = { "nvl_chapters" } },
    seguidores    = { kind = "num",  keys = { "nvl_bookmarks", "bookmarks_count", "nvl_followers", "followers" } },
    comentarios   = { kind = "num",  keys = { "nvl_comments", "comments_count", "comments" } },
    megusta       = { kind = "num",  keys = { "nvl_likes", "likes_count", "nvl_ratings_count" } },
    actualizacion = { kind = "text", keys = { "nvl_last_update", "updatedAt" } },
    valoracion    = { kind = "num",  keys = { "nvl_rating" } },
}

local function sort_novels(list, sort_key, descending)
    local spec = SORT_FIELDS[sort_key]
    if not spec then return end

    local function value(res)
        if spec.kind == "num" then
            return num_field(res, spec.keys) or -1
        end
        for _, k in ipairs(spec.keys) do
            if type(res[k]) == "string" then return fold(res[k]) end
        end
        return ""
    end

    -- Tri stable : on mémorise l'ordre d'arrivée pour départager les ex æquo
    -- (sinon table.sort peut renvoyer un ordre différent à chaque page).
    local rank = {}
    for i, res in ipairs(list) do rank[res] = i end

    table.sort(list, function(a, b)
        local va, vb = value(a), value(b)
        if va == vb then return rank[a] < rank[b] end
        if descending then return va > vb end
        return va < vb
    end)
end

local POPULAR_FILTERS = {
    {
        key = "estado", label = "État", default = "",
        options = {
            { id = "",           label = "Tous" },
            { id = "activa",     label = "Active" },
            { id = "inactiva",   label = "Inactive" },
            { id = "finalizada", label = "Terminée" },
        },
    },
    {
        key = "orden", label = "Trier par", default = "actualizacion",
        options = {
            { id = "actualizacion", label = "Mise à jour" },
            { id = "valoracion",    label = "Note" },
            { id = "popularidad",   label = "Popularité" },
            { id = "nombre",        label = "Nom" },
            { id = "capitulos",     label = "Chapitres" },
            { id = "seguidores",    label = "Abonnés" },
            { id = "comentarios",   label = "Commentaires" },
            { id = "megusta",       label = "J'aime" },
        },
    },
    {
        key = "sentido", label = "Ordre", default = "desc",
        options = {
            { id = "desc", label = "Décroissant" },
            { id = "asc",  label = "Croissant" },
        },
    },
    {
        key = "origen", label = "Origine", default = "",
        options = {
            { id = "",           label = "Toutes" },
            { id = "originales", label = "Originales SkyNovels" },
            { id = "inglesas",   label = "Anglaises" },
            { id = "coreanas",   label = "Coréennes" },
            { id = "chinas",     label = "Chinoises" },
            { id = "japonesas",  label = "Japonaises" },
        },
    },
    {
        key = "genre", label = "Genre", default = "",
        options = {
            { id = "",   label = "Tous" },
            { id = "9",  label = "Action" },
            { id = "38", label = "Adulte" },
            { id = "3",  label = "Arts martiaux" },
            { id = "2",  label = "Aventure" },
            { id = "40", label = "BL" },
            { id = "7",  label = "Comédie" },
            { id = "26", label = "Choses de la vie" },
            { id = "19", label = "Cultivation" },
            { id = "8",  label = "Drame" },
            { id = "21", label = "Ecchi" },
            { id = "4",  label = "Fantasy" },
            { id = "10", label = "Gender Bender" },
            { id = "41", label = "GL" },
            { id = "12", label = "Harem" },
            { id = "32", label = "Historique" },
            { id = "39", label = "Horreur" },
            { id = "31", label = "LitRPG" },
            { id = "1",  label = "Mature" },
            { id = "16", label = "Magie" },
            { id = "22", label = "Mystère" },
            { id = "34", label = "Monde moderne" },
            { id = "27", label = "Psychologique" },
            { id = "36", label = "Récits de vie" },
            { id = "23", label = "Réincarnation" },
            { id = "5",  label = "Romance" },
            { id = "17", label = "Sci-Fi" },
            { id = "18", label = "Seinen" },
            { id = "33", label = "Shoujo" },
            { id = "13", label = "Shounen" },
            { id = "20", label = "Surnaturel" },
            { id = "25", label = "Survie" },
            { id = "35", label = "Suspense" },
            { id = "14", label = "Tragédie" },
            { id = "24", label = "Transmigration" },
            { id = "29", label = "Vie scolaire" },
            { id = "6",  label = "Xianxia" },
            { id = "11", label = "Xuanhuan" },
            { id = "30", label = "Yaoi" },
            { id = "37", label = "Sans genre indiqué" },
        },
    },
}

-- ── Construction de la liste ─────────────────────────────────────────────────

local function novel_item(res)
    if not res or not res.id then return nil end
    return {
        name  = res.nvl_title or "Sin título",
        path  = "novelas/" .. res.id .. "/" .. (res.nvl_name or "") .. "/",
        cover = cover_url(res.image),
    }
end

-- Paramètre `order` de l'API : seules deux valeurs sont connues. Pour les
-- autres tris, on demande la liste la plus large possible et on trie ensuite.
local function api_order(sort_key)
    if sort_key == "valoracion" or sort_key == "popularidad" then return "rating" end
    return "updated"
end

local function fetch_pages(base_endpoint, first_page, count)
    local all = {}
    for i = 0, count - 1 do
        local data = api_get(base_endpoint:gsub("__PAGE__", tostring(first_page + i)))
        local novels = data and data.novels
        if type(novels) ~= "table" or #novels == 0 then break end
        for _, res in ipairs(novels) do all[#all + 1] = res end
        if #novels < PAGE_SIZE then break end -- dernière page atteinte
    end
    return all
end

-- ── Table d'extension ────────────────────────────────────────────────────────

local ext = {
    id      = "skynovels",
    name    = "SkyNovels",
    site    = BASE,
    lang    = "es",
    version = "1.2.0",
    maxReviewPages = 15, -- l'API pagine par 10 : 15 pages = 150 avis max
    maxReviews = 150,    -- limite d'avis affichés (même valeur pour toutes les extensions) : au-delà, plus de page à droite
    chapterCommentsPanel = false,
    popularFilters = POPULAR_FILTERS,
}

function ext:popularNovels(page, options)
    page = page or 1
    local filters = (options and options.filters) or {}
    local genre   = filters.genre  or ""
    local estado  = filters.estado or ""
    local origen  = filters.origen or ""
    local orden   = filters.orden  or "actualizacion"
    local desc    = (filters.sentido or "desc") ~= "asc"

    local endpoint = "novels?page=__PAGE__&order=" .. api_order(orden)
    if genre ~= "" then endpoint = endpoint .. "&genres=" .. genre end

    -- Un seul appel suffit quand aucun filtre/tri client n'est actif.
    local client_side = (estado ~= "" or origen ~= "" or orden ~= "actualizacion" or not desc)
    local raw = fetch_pages(endpoint,
        client_side and ((page - 1) * FETCH_PAGES + 1) or page,
        client_side and FETCH_PAGES or 1)

    -- Filtrage
    local kept = {}
    local origin_supported = false
    for _, res in ipairs(raw) do
        local ok = true
        if estado ~= "" then
            ok = fold(res.nvl_status) == STATUS_MATCH[estado]
        end
        if ok and origen ~= "" then
            ok = matches_origin(res, origen)
            if ok then origin_supported = true end
        end
        if ok then kept[#kept + 1] = res end
    end

    -- Si AUCUN roman ne correspond à l'origine demandée, c'est très
    -- probablement que l'API n'expose pas cette information : mieux vaut
    -- afficher la liste non filtrée qu'un écran vide.
    if origen ~= "" and not origin_supported then
        logger.warn("SkyNovels: origine non exposée par l'API, filtre ignoré")
        kept = {}
        for _, res in ipairs(raw) do
            if estado == "" or fold(res.nvl_status) == STATUS_MATCH[estado] then
                kept[#kept + 1] = res
            end
        end
    end

    sort_novels(kept, orden, desc)

    local novels = {}
    for _, res in ipairs(kept) do
        local item = novel_item(res)
        if item then
            novels[#novels + 1] = item
            if #novels >= PAGE_SIZE then break end
        end
    end

    logger.dbg("SkyNovels: popularNovels page=", page, "brut=", #raw, "retenus=", #novels)
    return { novels = novels }
end

function ext:searchNovels(term, page)
    page = page or 1
    local endpoint = "novels?page=" .. page .. "&q=" .. url_encode(tostring(term):lower())
    local data = api_get(endpoint)
    local novels = {}
    if data and type(data.novels) == "table" then
        for _, res in ipairs(data.novels) do
            local item = novel_item(res)
            if item then novels[#novels + 1] = item end
        end
    end
    logger.dbg("SkyNovels: searchNovels term=", term, "found", #novels)
    return { novels = novels }
end

-- ── Fiche roman ──────────────────────────────────────────────────────────────

-- Un seul appel sert à la fois la fiche et les avis (l'onglet Avis a son
-- propre endpoint paginé, voir plus bas) : on garde la dernière réponse pour
-- éviter de la retélécharger quand l'onglet Avis s'ouvre juste après Détails.
local _last = { path = nil, item = nil, ts = 0 }

local function fetch_item(path)
    local now = os.time()
    if _last.path == path and _last.item and (now - _last.ts) < 120 then
        return _last.item
    end

    local parts    = split_path(path)
    local novel_id = parts[2]
    if not novel_id then
        logger.err("SkyNovels: path invalide", tostring(path))
        return nil
    end

    local data = api_get("novel/" .. novel_id .. "/reading")
    local item = data and data.novel and data.novel[1]
    if not item then
        logger.err("SkyNovels: fiche introuvable", tostring(novel_id))
        return nil
    end

    _last = { path = path, item = item, ts = now }
    return item
end

-- Chapitres d'un volume : endpoint dédié, confirmé par capture réseau du
-- site (GET volumes/<novel_id>/<volume_id>/chapters?page=N&limit=2000).
-- Ne PAS se fier au tableau "chapters" parfois présent dans les volumes
-- renvoyés par novel/<id>/reading : il peut être absent ou incomplet, cet
-- endpoint est la source que le site lui-même utilise pour afficher la
-- liste, donc la seule fiable pour "lire les chapitres normalement".
local CHAPTERS_PAGE_LIMIT = 2000

local function fetch_volume_chapters(novel_id, volume_id)
    local all, page = {}, 1
    while true do
        local data = api_get("volumes/" .. novel_id .. "/" .. volume_id
            .. "/chapters?page=" .. page .. "&limit=" .. CHAPTERS_PAGE_LIMIT)
        local items = data and data.items
        if type(items) ~= "table" or #items == 0 then break end
        for _, ch in ipairs(items) do all[#all + 1] = ch end
        local pag = data.pagination
        if not (pag and pag.hasMore) then break end
        page = page + 1
    end
    return all
end

local function build_novel(path, item, with_chapters)
    local parts    = split_path(path)
    local novel_id = parts[2]

    local genres = {}
    if type(item.genres) == "table" then
        for _, g in ipairs(item.genres) do
            if g.genre_name then genres[#genres + 1] = g.genre_name end
        end
    end

    local chapters, count = {}, 0
    if type(item.volumes) == "table" then
        for _, vol in ipairs(item.volumes) do
            local vol_chapters
            if with_chapters and vol.id then
                vol_chapters = fetch_volume_chapters(novel_id, vol.id)
            end
            -- Filet de sécurité si l'endpoint dédié échoue ou si le volume
            -- n'a pas d'id exploitable : on retombe sur les chapitres déjà
            -- embarqués dans la fiche, quand ils existent.
            if type(vol_chapters) ~= "table" or #vol_chapters == 0 then
                vol_chapters = type(vol.chapters) == "table" and vol.chapters or {}
            end
            for _, ch in ipairs(vol_chapters) do
                count = count + 1
                if with_chapters and ch.id then
                    chapters[#chapters + 1] = {
                        name           = ch.chp_index_title or ("Capítulo " .. tostring(ch.chp_number or count)),
                        path           = "novelas/" .. novel_id .. "/" .. (item.nvl_name or "")
                                         .. "/" .. ch.id .. "/" .. (ch.chp_name or ""),
                        chapter_number = tonumber(ch.chp_number) or count,
                        released       = ch.createdAt,
                        status         = ch.chp_status,
                    }
                end
            end
        end
    end

    return {
        name           = item.nvl_title or "Sin título",
        path           = path,
        cover          = cover_url(item.image),
        summary        = strip_tags(item.nvl_content),
        author         = item.nvl_writer or item.nvl_translator,
        genres         = genres,
        status         = item.nvl_status,
        rating         = tonumber(item.nvl_rating),
        chapters       = chapters,
        total_chapters = tonumber(item.nvl_chapters) or count,
        totalPages     = 1,
    }
end

function ext:parseNovelMeta(path)
    local item = fetch_item(path)
    if not item then return nil end
    local novel = build_novel(path, item, false)
    return {
        name           = novel.name,
        path           = path,
        cover          = novel.cover,
        summary        = novel.summary,
        author         = novel.author,
        status         = novel.status,
        total_chapters = novel.total_chapters,
    }
end

function ext:parseNovel(path)
    local item = fetch_item(path)
    if not item then return nil end
    local novel = build_novel(path, item, true)
    logger.dbg("SkyNovels: parseNovel", novel.name, "chapitres=", #novel.chapters)
    return novel
end

-- ── Chapitre ─────────────────────────────────────────────────────────────────

function ext:parseChapter(path)
    local parts = split_path(path)
    local chapter_id = parts[4]
    if not chapter_id or chapter_id == "" then
        logger.err("SkyNovels: identifiant de chapitre invalide", tostring(path))
        return nil, "invalid_chapter_path"
    end

    -- Endpoint principal + replis. Confirmé par vos logs (crash.log du
    -- 16/09) : "novel-chapter/<id>" renvoie du JSON invalide (probablement
    -- une page d'erreur HTML) et "chapter/<id>" renvoie du 404 — c'est
    -- "chapters/<id>" (pluriel) qui répond correctement (200 + JSON valide).
    -- On le met donc en premier pour ne plus gaspiller deux requêtes vouées
    -- à l'échec à chaque chapitre ; les anciennes formes restent en repli
    -- au cas où l'API varie selon le roman.
    local endpoints = {
        "chapters/" .. tostring(chapter_id),
        "novel-chapter/" .. tostring(chapter_id),
        "chapter/" .. tostring(chapter_id),
        "novel/chapter/" .. tostring(chapter_id),
    }
    local data, used_endpoint = api_get_first(endpoints)
    if not data then
        -- Distingue "aucun endpoint n'a répondu" (réseau, chemin d'API
        -- changé...) de "un endpoint a répondu mais le champ contenu est
        -- introuvable/renommé" : sans cette distinction, les deux pannes
        -- remontaient sous le même message générique, impossible à
        -- diagnostiquer depuis les logs.
        logger.err("SkyNovels: aucun endpoint chapitre n'a répondu pour", tostring(chapter_id),
            "essayés=", table.concat(endpoints, " | "))
        return nil, "chapter_api_unreachable"
    end

    local item = first_or_self(data and data.chapter)
    if not item and data then item = first_or_self(data.chapters) end
    if not item and data then item = first_or_self(data.data) end
    if not item and data then item = first_or_self(data.item) end
    if not item and data and (data.chp_content or data.content or data.chapter_content) then
        -- Certaines réponses renvoient directement l'objet chapitre à la
        -- racine, sans clé "chapter"/"data" englobante.
        item = data
    end

    local content = item and (
        item.chp_content or item.content or item.chapter_content
        or item.chapterContent or item.chp_text or item.text or item.body
        or item.html or item.chp_html
    )
    if type(content) ~= "string" or content == "" then
        logger.err("SkyNovels: contenu introuvable pour le chapitre", tostring(chapter_id),
            "endpoint=", tostring(used_endpoint),
            "clés réponse=", dump_keys(data),
            "clés item=", dump_keys(item))
        return nil, "chapter_content_not_found"
    end

    -- Certains chapitres sont renvoyés en texte brut, d'autres en HTML.
    -- On conserve le HTML existant et on transforme proprement le texte brut.
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    if not content:find("<p", 1, true) and not content:find("<br", 1, true)
        and not content:find("<div", 1, true) then
        local paragraphs = {}
        for para in (content .. "\n"):gmatch("(.-)\n") do
            para = para:match("^%s*(.-)%s*$")
            if para ~= "" then
                paragraphs[#paragraphs + 1] = "<p>" .. para .. "</p>"
            end
        end
        content = table.concat(paragraphs, "\n")
    else
        -- Ne pas remplacer les retours déjà présents dans les balises HTML
        -- par des <br> multiples.
        content = content:gsub("\n%s*\n+", "<br><br>")
        content = content:gsub("\n", "<br>")
    end

    return content
end

-- ── Avis / commentaires ─────────────────────────────────────────────────────
-- La fiche roman (novelas/<id>/<slug>) est une SPA : les avis n'existent PAS
-- dans le HTML brut (la page affiche « Reseñas 0 » avant que le JS ne les
-- charge — vérifié le 2026-09-19), donc aucun scraping HTML ici.
--
-- Deux sources JSON, essayées dans cet ordre :
--   1. l'endpoint dédié, paginé   : novels/<id>/ratings?page=N&limit=10&sort=<tri>
--      -> { ratings = [ {...} ], pagination = { page, total, totalPages, hasMore } }
--      (repli sur la forme au singulier novel/<id>/ratings, qui répondait bien
--       pour les petits romans — cache du 17/09 — mais renvoie 500 sur les gros)
--   2. le champ `novel_ratings` de novel/<id>/reading (page 1 uniquement, non
--      paginé) quand l'endpoint dédié est en erreur.
--
-- Tri : trois valeurs API vérifiées par capture Network sur le roman 179 —
-- popular (défaut du site), latest (plus récents d'abord), oldest (plus
-- anciens d'abord, 2026-09-19). L'onglet Avis (ui/detail.lua) parle un
-- vocabulaire GÉNÉRIQUE commun à toutes les extensions — "newest" | "oldest"
-- | "mostliked" — traduit ici vers les valeurs propres à l'API SkyNovels.
-- Une valeur non reconnue retombe sur popular plutôt que d'envoyer un
-- paramètre au hasard à l'API.
--
-- Tout ce qui ne marche pas est journalisé en WARN/ERROR avec le code HTTP et
-- le début de la réponse : le crash.log suffit à voir quelle forme l'API a.

local SORT_MAP = { newest = "latest", oldest = "oldest", mostliked = "popular" }
local VALID_RATING_SORTS = { popular = true, latest = true, oldest = true }

-- Mémorise le préfixe (pluriel "novels" ou singulier "novel") qui a déjà
-- répondu correctement, pour l'essayer en premier la prochaine fois — y
-- compris quand le tri demandé change (le préfixe qui marche ne dépend pas
-- du tri).
local _ratings_prefix = nil

local function ratings_candidates(novel_id, page, generic_sort)
    local id, p, l = tostring(novel_id), tostring(page or 1), tostring(REVIEWS_PER_PAGE)
    local api_sort = SORT_MAP[generic_sort]
    local sort = VALID_RATING_SORTS[api_sort] and api_sort or "popular"
    local prefixes = (_ratings_prefix == "novel") and { "novel", "novels" } or { "novels", "novel" }
    local cands = {}
    for _, prefix in ipairs(prefixes) do
        cands[#cands + 1] = prefix .. "/" .. id .. "/ratings?page=" .. p .. "&limit=" .. l .. "&sort=" .. sort
    end
    -- Le tri demandé peut ne pas être honoré par une version de l'API (ou le
    -- paramètre peut être temporairement en erreur) : on retombe sur popular
    -- (le seul tri vérifié dès l'origine), puis sur aucun paramètre de tri du
    -- tout — mieux vaut un ordre différent de celui demandé qu'aucun avis.
    if sort ~= "popular" then
        cands[#cands + 1] = prefixes[1] .. "/" .. id .. "/ratings?page=" .. p .. "&limit=" .. l .. "&sort=popular"
    end
    cands[#cands + 1] = prefixes[1] .. "/" .. id .. "/ratings?page=" .. p .. "&limit=" .. l
    return cands
end

local _ratings_variant = nil -- indice du dernier candidat qui a répondu correctement

-- Premier champ non vide parmi `keys` (les noms varient selon l'endpoint :
-- l'endpoint paginé et `novel_ratings` ne nomment pas forcément pareil).
local function pick(r, keys)
    if type(r) ~= "table" then return nil end
    for _, k in ipairs(keys) do
        local v = r[k]
        if v ~= "" and (type(v) == "string" or type(v) == "number") then return v end
    end
    return nil
end

local function map_rating(r)
    if type(r) ~= "table" then return nil end
    local u = type(r.user) == "table" and r.user or {}
    local content = strip_tags(pick(r, { "rate_comment", "comment", "content", "text", "body", "review" }) or "")
    local rating  = tonumber(pick(r, { "rate_value", "rating", "rate", "value", "score", "stars" }))
    if content == "" and not rating then return nil end
    local author = pick(r, { "user_login", "username", "user_name", "nickname", "author" })
                or pick(u, { "user_login", "username", "name" })
    return {
        author  = author and tostring(author) or "Anónimo",
        rating  = rating,
        content = content,
        date    = tostring(pick(r, { "createdAt", "created_at", "date", "updatedAt" }) or ""),
        avatar  = avatar_url(pick(r, { "image", "user_image", "avatar" }) or pick(u, { "image", "avatar" })),
        likes   = tonumber(pick(r, { "likes_count", "likes", "total_likes" })) or 0,
    }
end

local function map_list(list)
    local reviews = {}
    for _, r in ipairs(list or {}) do
        local mapped = map_rating(r)
        if mapped then reviews[#reviews + 1] = mapped end
    end
    return reviews
end

-- Renvoie la liste d'avis (éventuellement VIDE) si la réponse a une forme
-- reconnue, nil sinon. Distinguer « liste vide » de « forme inconnue » évite
-- de conclure « aucun avis » sur une réponse qu'on n'a simplement pas comprise.
local function find_rating_list(data)
    if type(data) ~= "table" then return nil end
    if type(data[1]) == "table" then return data end
    for _, key in ipairs({ "ratings", "novel_ratings", "reviews", "items", "results", "data", "list" }) do
        local v = data[key]
        if type(v) == "table" then
            if type(v[1]) == "table" or next(v) == nil then return v end
            for _, k2 in ipairs({ "ratings", "items", "results", "list" }) do
                if type(v[k2]) == "table" then return v[k2] end
            end
        end
    end
    return nil
end

local function novel_id_from_path(path)
    local p = tostring(path or ""):gsub("^/+", ""):gsub("/+$", "")
    local parts = split_path(p)
    if parts[1] ~= "novelas" or not parts[2] or parts[2] == "" then return nil end
    return parts[2]
end

-- Pas de « cooldown » sur les échecs : une nouvelle demande (onglet rouvert,
-- bouton ↻, ligne « réessayer ») doit TOUJOURS refaire de vrais appels réseau.
-- (Une ancienne version mémorisait l'échec 10 min et le rejouait instantanément
-- sans rien télécharger, ce qui rendait « réessayer » inopérant.)

-- Comme api_get, mais renvoie aussi un statut lisible pour l'écran/le journal.
local function fetch_json(endpoint)
    local body, code = http_get(API .. endpoint)
    if not body then return nil, "HTTP " .. tostring(code) end
    local data = json_decode(body)
    if not data then
        logger.warn("SkyNovels: JSON invalide pour", endpoint, (body:sub(1, 120):gsub("%s+", " ")))
        return nil, "JSON invalide"
    end
    return data, "ok", body
end

-- `sort` (vocabulaire générique commun à toutes les extensions, voir
-- ui/detail.lua current_api_sort()) : "newest" | "oldest" | "mostliked" —
-- traduit vers popular/latest/oldest côté API (voir SORT_MAP,
-- ratings_candidates). L'onglet Avis garde en plus son propre tri côté
-- plugin (note/date, ordre inversé) sur les avis déjà récupérés ; passer le
-- bon `sort` ici sert surtout à ce que les pages effectivement téléchargées
-- (limitées par MAX_REVIEW_PAGES côté UI) soient les bonnes quand un roman a
-- plus d'avis que ce qui est chargé.
function ext:parseReviews(path, page, sort)
    page = tonumber(page) or 1
    local novel_id = novel_id_from_path(path)
    if not novel_id then
        logger.warn("SkyNovels: chemin invalide pour les avis", tostring(path))
        return { reviews = {}, has_more = false, error = "chemin invalide" }
    end

    local got_answer = false -- au moins une réponse HTTP 200 de forme reconnue
    local diag, seen = {}, {} -- causes d'échec (dédoublonnées), affichées à l'écran
    local function note(msg)
        if not seen[msg] then seen[msg] = true; diag[#diag + 1] = msg end
    end

    -- 1) endpoint dédié (candidats), en commençant par celui qui a déjà marché
    local cands = ratings_candidates(novel_id, page, sort)
    local order = {}
    if _ratings_variant and cands[_ratings_variant] then order[1] = _ratings_variant end
    for i = 1, #cands do
        if i ~= _ratings_variant then order[#order + 1] = i end
    end

    for _, i in ipairs(order) do
        local data, status, body = fetch_json(cands[i])
        local list = find_rating_list(data)
        if list then
            got_answer = true
            local reviews = map_list(list)
            local pag = type(data) == "table" and type(data.pagination) == "table" and data.pagination or nil
            local total = pag and tonumber(pag.total) or nil
            local has_more = #reviews >= REVIEWS_PER_PAGE
            if pag then
                if pag.hasMore ~= nil then
                    has_more = pag.hasMore and true or false
                elseif tonumber(pag.totalPages) and tonumber(pag.page) then
                    has_more = tonumber(pag.page) < tonumber(pag.totalPages)
                end
            end
            -- Réponse fiable : des avis, ou une fin de liste (page > 1), ou un
            -- total explicitement à 0. Une liste vide SANS total en page 1 est
            -- suspecte (mauvais paramètre ?) : on essaie le candidat suivant.
            if #reviews > 0 or page > 1 or total == 0 then
                _ratings_variant = i
                _ratings_prefix  = cands[i]:match("^(%a+)/")
                logger.dbg("SkyNovels: avis OK", cands[i], "trouvés=", #reviews, "total=", tostring(total))
                return { reviews = reviews, has_more = has_more, total = total }
            end
            logger.warn("SkyNovels: liste d'avis vide sans total pour", cands[i], dump_keys(data))
            note("liste vide")
        elseif data then
            -- HTTP 200 + JSON valide mais forme non reconnue : on journalise les clés
            -- et le début de la réponse, c'est ce qui permet d'adapter le parseur.
            logger.warn("SkyNovels: forme d'avis inconnue pour", cands[i], dump_keys(data),
                (tostring(body or ""):sub(1, 200):gsub("%s+", " ")))
            note("forme inconnue " .. dump_keys(data))
        else
            note(status)
        end
    end

    -- Les pages suivantes n'existent pas dans le repli (non paginé).
    if page > 1 then return { reviews = {}, has_more = false } end

    -- 2) repli : novel_ratings embarqué dans novel/<id>/reading
    local item = fetch_item(path)
    if item then
        local list = find_rating_list({ novel_ratings = item.novel_ratings })
        if list then
            got_answer = true
            local reviews = map_list(list)
            logger.warn("SkyNovels: repli novel_ratings novel_id=", tostring(novel_id),
                "entrées=", #list, "avis exploitables=", #reviews)
            if #reviews > 0 then
                return { reviews = reviews, has_more = false, total = #reviews }
            end
        else
            logger.warn("SkyNovels: novel_ratings de forme inconnue", type(item.novel_ratings),
                tostring(item.novel_ratings), dump_keys(item.novel_ratings))
            note("novel_ratings: " .. type(item.novel_ratings))
        end
    else
        note("fiche introuvable")
    end

    -- Aucun avis trouvé. `error` (texte) = on n'a obtenu AUCUNE réponse
    -- exploitable : l'onglet affiche la cause + « réessayer » au lieu de
    -- « aucun avis », et ne met rien en cache.
    local err = false
    if not got_answer then err = table.concat(diag, " ; ") ~= "" and table.concat(diag, " ; ") or true end
    return { reviews = {}, has_more = false, error = err }
end

return ext
