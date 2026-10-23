-- core/anilist.lua — suivi de lecture AniList (manga et light novels).
--
-- * Lier un titre de la bibliothèque à une fiche AniList (recherche par titre) ;
-- * synchroniser la progression (nombre de chapitres lus) à la main ou
--   automatiquement dès qu'un chapitre est terminé ;
-- * ne fait JAMAIS reculer la progression d'AniList, ne bloque jamais la
--   lecture, et reste silencieux en cas de souci réseau (la synchro
--   automatique se refera au chapitre suivant ; la manuelle explique l'erreur).
--
-- Jeton : AniList ne propose pas de connexion par mot de passe pour les
-- applis tierces ; l'utilisateur crée un « client » sur
-- https://anilist.co/settings/developer (URL de redirection
-- https://anilist.co/api/v2/oauth/pin), ouvre le lien d'autorisation et colle
-- le jeton obtenu dans Paramètres › AniList.
local https  = require("ssl.https")
local ltn12  = require("ltn12")
local ok_json, JSON = pcall(require, "rapidjson")
if not ok_json then JSON = require("json") end
local Settings = require("settings")

local AniList = {}

local ENDPOINT = "https://graphql.anilist.co"

local function token()
    local t = Settings:get("anilist_token")
    return (type(t) == "string" and t ~= "") and t or nil
end

function AniList.has_token() return token() ~= nil end

-- Une valeur JSON « null » peut revenir sous forme d'objet spécial (et non nil)
-- selon la bibliothèque JSON : on ne garde que les vraies chaînes non vides.
local function str(x) return (type(x) == "string" and x ~= "") and x or nil end

-- Dernière erreur technique (affichée par le test de connexion).
AniList.last_error = nil

-- Deux adresses : l'API officielle puis celle du site (au cas où l'une serait
-- bloquée par le DNS / le réseau de la liseuse).
local ENDPOINTS = { ENDPOINT, "https://anilist.co/graphql" }

-- Une requête vers une adresse. Retourne data, nil | nil, err, retenter?
local function request(url, body, t)
    local sink = {}
    local headers = {
        ["Content-Type"]   = "application/json",
        ["Accept"]         = "application/json",
        ["User-Agent"]     = "Sefirah-KOReader/1.0",
        ["Referer"]        = "https://anilist.co/",
        ["Content-Length"] = tostring(#body),
    }
    if t then headers["Authorization"] = "Bearer " .. t end
    -- https.request{} renvoie (1, code HTTP, en-têtes, statut) ou (nil, erreur).
    local ok, r1, code = pcall(https.request, {
        url = url, method = "POST", headers = headers,
        source = ltn12.source.string(body),
        sink   = ltn12.sink.table(sink),
        timeout = 15,
    })
    local resp = table.concat(sink)
    if not ok or not r1 then
        AniList.last_error = url .. " : connexion impossible (" .. tostring(not ok and r1 or code) .. ")"
        return nil, "réseau", true
    end
    code = tonumber(code)
    local okd, data = pcall(JSON.decode, resp)
    AniList.last_error = url .. " : HTTP " .. tostring(code) .. " · " .. (resp:sub(1, 160):gsub("%s+", " "))
    if code == 401 or (code == 400 and okd and type(data) == "table" and data.errors
       and tostring(data.errors[1] and data.errors[1].message or ""):lower():find("invalid token")) then
        return nil, "jeton refusé", false
    end
    if code == 429 then return nil, "trop de requêtes, réessaie dans une minute", false end
    if not okd or type(data) ~= "table" then
        return nil, "réponse illisible (HTTP " .. tostring(code) .. ")", true
    end
    if data.errors and data.errors[1] then
        return nil, tostring(data.errors[1].message or "erreur AniList"), false
    end
    AniList.last_error = nil
    return data.data, nil, false
end

-- Requête GraphQL. Retourne data, nil  ou  nil, "message".
-- noauth = true : requête publique (profil, listes), sans jeton.
local function gql(query, variables, noauth)
    local t = (not noauth) and token() or nil
    if not t and not noauth then return nil, "jeton absent" end
    local payload = { query = query }
    if type(variables) == "table" and next(variables) ~= nil then payload.variables = variables end
    local body = JSON.encode(payload)
    local last
    for _, url in ipairs(ENDPOINTS) do
        local data, err, retry = request(url, body, t)
        if data then return data, nil end
        if not retry then return nil, err end
        last = err
    end
    return nil, last
end

-- Vérifie le jeton : retourne le pseudo ou nil, err.
function AniList.whoami()
    local d, err = gql("query { Viewer { name } }")
    if not d then return nil, err end
    return d.Viewer and d.Viewer.name, nil
end

-- Test de connexion : retourne un texte lisible (pseudo ou cause exacte de l'échec).
function AniList.diagnose()
    if not token() then return "Aucun jeton enregistré." end
    local name, err = AniList.whoami()
    if name then return "Connecté à AniList : " .. name end
    return "Échec : " .. tostring(err) .. (AniList.last_error and ("\n" .. AniList.last_error) or "")
end

-- Recherche par titre (manga + light novels). Retourne une liste de
-- { id, title, format, chapters } ou nil, err.
function AniList.search(title)
    local d, err = gql([[query($q:String){ Page(perPage:8){ media(search:$q, type:MANGA){
        id format chapters title{ romaji english } } } }]], { q = title })
    if not d then return nil, err end
    local out = {}
    local media = d.Page and d.Page.media or {}
    for _, m in ipairs(media) do
        local t = type(m.title) == "table" and m.title or {}
        out[#out + 1] = {
            id = m.id, title = str(t.english) or str(t.romaji) or "?",
            format = str(m.format), chapters = tonumber(m.chapters),
        }
    end
    return out, nil
end

-- ── Liens roman/manga ↔ fiche AniList (stockés dans les réglages) ────────────

local function key(source_id, path) return tostring(source_id) .. "::" .. tostring(path) end

function AniList.get_link(source_id, path)
    local all = Settings:get("anilist_links")
    return type(all) == "table" and all[key(source_id, path)] or nil
end

local function set_link(source_id, path, link)
    local all = Settings:get("anilist_links")
    if type(all) ~= "table" then all = {} end
    all[key(source_id, path)] = link
    Settings:set("anilist_links", all)
end

function AniList.unlink(source_id, path) set_link(source_id, path, nil) end

-- Lie le titre à la fiche AniList `media` ; mémorise la progression déjà
-- présente côté AniList (« base ») pour ne jamais la faire reculer.
function AniList.link(source_id, path, media)
    local d = gql([[query($id:Int){ Media(id:$id){ mediaListEntry{ progress } } }]], { id = media.id })
    -- mediaListEntry vaut « null » (objet spécial, pas nil) tant que le titre n'est
    -- pas dans ta liste AniList : on ne l'indexe que si c'est une vraie table.
    local media_d = type(d) == "table" and type(d.Media) == "table" and d.Media or nil
    local entry = media_d and type(media_d.mediaListEntry) == "table" and media_d.mediaListEntry or nil
    local base = entry and tonumber(entry.progress) or 0
    set_link(source_id, path, {
        id = media.id, title = media.title, chapters = media.chapters,
        base = base, pushed = base,
    })
end

local function completed_count(source_id, path)
    local ok, Cache = pcall(require, "core.cache")
    if not ok then return 0 end
    local e = Cache.getNovelEntry and Cache.getNovelEntry(source_id, path)
    local n = 0
    for _, v in pairs(e and e.progress_by_chapter or {}) do
        if type(v) == "table" and v.completed then n = n + 1 end
    end
    return n
end

-- Envoie la progression. Retourne progress, nil  ou  nil, err.
function AniList.push(source_id, path)
    local link = AniList.get_link(source_id, path)
    if not link then return nil, "titre non lié" end
    local progress = math.max(tonumber(link.base) or 0, completed_count(source_id, path))
    if progress < (tonumber(link.pushed) or 0) then progress = tonumber(link.pushed) end
    local status = "CURRENT"
    if link.chapters and link.chapters > 0 and progress >= link.chapters then status = "COMPLETED" end
    local d, err = gql([[mutation($id:Int,$p:Int,$s:MediaListStatus){
        SaveMediaListEntry(mediaId:$id, progress:$p, status:$s){ progress } }]],
        { id = link.id, p = progress, s = status })
    if not d then return nil, err end
    link.pushed = progress
    set_link(source_id, path, link)
    return progress, nil
end

-- Appelé par core/cache.lua quand un chapitre passe à « terminé ».
-- Silencieux : ne doit jamais gêner la lecture.
function AniList.on_chapter_completed(source_id, path)
    if Settings:get("anilist_autosync") == false then return end
    if not token() or not AniList.get_link(source_id, path) then return end
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok then return end
    UIManager:scheduleIn(3, function()
        pcall(function()
            if not require("core.online").is_up() then return end
            AniList.push(source_id, path)
        end)
    end)
end

-- ── Ma liste (écran ui/anilist_list.lua) ────────────────────────────────────

-- Retourne { name = pseudo, lists = { [STATUT] = { entrées } } } ou nil, err.
-- Chaque entrée : { media_id, title, format, chapters, progress, status }.
function AniList.my_list()
    local v, err = gql("query { Viewer { id name } }")
    if not v or not v.Viewer then return nil, err or "réseau" end
    local d, err2 = gql([[query($u:Int){ MediaListCollection(userId:$u, type:MANGA, sort:UPDATED_TIME_DESC){
        lists{ status entries{ progress status score(format:POINT_100) media{ id format chapters title{ romaji english } } } } } }]],
        { u = v.Viewer.id })
    if not d then return nil, err2 end
    local out = { name = v.Viewer.name, lists = {} }
    local coll = d.MediaListCollection and d.MediaListCollection.lists or {}
    for _, l in ipairs(coll) do
        for _, e in ipairs(l.entries or {}) do
            local m = e.media or {}
            local st = e.status or l.status or "CURRENT"
            out.lists[st] = out.lists[st] or {}
            table.insert(out.lists[st], {
                media_id = m.id,
                title    = (type(m.title) == "table" and (str(m.title.english) or str(m.title.romaji))) or "?",
                format   = str(m.format),
                chapters = tonumber(m.chapters),
                progress = tonumber(e.progress) or 0,
                score    = tonumber(e.score) or 0,
                status   = st,
            })
        end
    end
    return out, nil
end

-- Modifie une entrée (progression et/ou statut). Retourne true ou nil, err.
function AniList.save(media_id, progress, status)
    local d, err = gql([[mutation($id:Int,$p:Int,$s:MediaListStatus){
        SaveMediaListEntry(mediaId:$id, progress:$p, status:$s){ id } }]],
        { id = media_id, p = progress, s = status })
    if not d then return nil, err end
    return true, nil
end

-- ── Profil (écran ui/anilist_profile.lua) ───────────────────────────────────

-- Champs de base (toujours acceptés par l'API) et champs enrichis (avatar,
-- bannière, genres, favoris). Si la requête enrichie est refusée, on retombe
-- sur la version de base plutôt que de perdre tout le profil.
local PROFILE_BASE = [[id name siteUrl about(asHtml:false)
    statistics{ anime{ count episodesWatched minutesWatched meanScore }
                manga{ count chaptersRead volumesRead meanScore } }]]

local FAV_NODES = [[nodes{ id title{ romaji english } coverImage{ large medium } }]]
local PROFILE_RICH = [[id name siteUrl about(asHtml:false) bannerImage avatar{ large medium }
    statistics{ anime{ count episodesWatched minutesWatched meanScore genres(limit:6, sort:COUNT_DESC){ genre count } }
                manga{ count chaptersRead volumesRead meanScore genres(limit:6, sort:COUNT_DESC){ genre count } } }
    favourites{ anime(perPage:12){ ]] .. FAV_NODES .. [[ } manga(perPage:12){ ]] .. FAV_NODES .. [[ } }]]

local function fetch_user(fields, username)
    local u, err
    if token() then
        local d, e = gql("query { Viewer { " .. fields .. " } }")
        u, err = d and d.Viewer, e
    end
    if not u and type(username) == "string" and username ~= "" then
        local d, e = gql("query($n:String){ User(name:$n){ " .. fields .. " } }", { n = username }, true)
        u, err = d and d.User, e or err
    end
    return u, err
end

local function norm_favs(conn)
    local out = {}
    for _, n in ipairs(type(conn) == "table" and conn.nodes or {}) do
        local t = n.title or {}
        local c = type(n.coverImage) == "table" and n.coverImage or {}
        out[#out + 1] = {
            id = n.id, title = str(t.english) or str(t.romaji) or "?",
            cover = str(c.large) or str(c.medium),
        }
    end
    return out
end

local function norm_genres(list)
    local out = {}
    for _, g in ipairs(type(list) == "table" and list or {}) do
        if str(g.genre) then out[#out + 1] = { genre = g.genre, count = tonumber(g.count) or 0 } end
    end
    return out
end

-- Profil public ou celui du jeton. `username` sert si le jeton est absent/refusé.
-- Retourne { id, name, siteUrl, about, avatar, banner, anime = {…, genres}, manga = {…, genres},
-- favs = { anime = {…}, manga = {…} } } ou nil, err.
function AniList.profile(username)
    local u, err = fetch_user(PROFILE_RICH, username)
    if not u and err ~= "réseau" then u, err = fetch_user(PROFILE_BASE, username) end
    if not u then return nil, err or "aucun pseudo AniList renseigné" end
    local st  = u.statistics or {}
    local fav = type(u.favourites) == "table" and u.favourites or {}
    local av  = type(u.avatar) == "table" and u.avatar or {}
    local a, m = st.anime or {}, st.manga or {}
    a.genres, m.genres = norm_genres(a.genres), norm_genres(m.genres)
    return {
        id = u.id, name = u.name, siteUrl = u.siteUrl, about = str(u.about),
        avatar = str(av.large) or str(av.medium), banner = str(u.bannerImage),
        anime = a, manga = m,
        favs = { anime = norm_favs(fav.anime), manga = norm_favs(fav.manga) },
    }, nil
end

-- Une liste complète (anime ou manga) d'un utilisateur. AniList la découpe en
-- « chunks » de 500 entrées : on les enchaîne. Les listes personnalisées sont
-- ignorées (leurs entrées figurent déjà dans les listes de statut).
-- Retourne { by_status = { [STATUT] = {entrées} }, all = {entrées} } ou nil, err.
local function fetch_collection(user_id, kind)
    local by_status, all = {}, {}
    local chunk = 1
    while chunk <= 8 do
        local d, err = gql([[query($u:Int,$t:MediaType,$c:Int){
            MediaListCollection(userId:$u, type:$t, sort:UPDATED_TIME_DESC, chunk:$c, perChunk:500){
            hasNextChunk lists{ status isCustomList entries{ progress status updatedAt score(format:POINT_100)
            media{ id format chapters episodes title{ romaji english } coverImage{ medium large } } } } } }]],
            { u = user_id, t = kind, c = chunk }, true)
        if not d then return nil, err end
        local coll = d.MediaListCollection or {}
        for _, l in ipairs(coll.lists or {}) do
            if l.isCustomList ~= true then
                for _, e in ipairs(l.entries or {}) do
                    local m = e.media or {}
                    local t = m.title or {}
                    local c = type(m.coverImage) == "table" and m.coverImage or {}
                    local st = str(e.status) or str(l.status) or "CURRENT"
                    local item = {
                        id       = m.id,
                        title    = str(t.english) or str(t.romaji) or "?",
                        format   = str(m.format),
                        progress = tonumber(e.progress) or 0,
                        total    = tonumber(kind == "ANIME" and m.episodes or m.chapters),
                        score    = tonumber(e.score) or 0,
                        status   = st,
                        updated  = tonumber(e.updatedAt) or 0,
                        cover    = str(c.medium),
                        cover_l  = str(c.large) or str(c.medium),
                    }
                    by_status[st] = by_status[st] or {}
                    by_status[st][#by_status[st] + 1] = item
                    all[#all + 1] = item
                end
            end
        end
        if coll.hasNextChunk ~= true then break end
        chunk = chunk + 1
    end
    local function recent_first(a, b) return a.updated > b.updated end
    table.sort(all, recent_first)
    for _, arr in pairs(by_status) do table.sort(arr, recent_first) end
    return { by_status = by_status, all = all }, nil
end

-- Listes anime + manga d'un utilisateur (par identifiant).
-- Retourne { anime = …, manga = … }, err — une liste qui échoue est simplement
-- absente du résultat (err décrit alors le problème) ; nil, err si les deux échouent.
function AniList.user_lists(user_id)
    local out, last_err = {}, nil
    for _, kind in ipairs({ "ANIME", "MANGA" }) do
        local c, err = fetch_collection(user_id, kind)
        if c then out[kind:lower()] = c else last_err = err end
    end
    if not out.anime and not out.manga then return nil, last_err end
    return out, last_err
end

-- ── Découverte : tendances, populaires, recommandations, genres, recherche ──

local MEDIA_FIELDS = [[id format chapters status averageScore genres description(asHtml:false)
    startDate{ year } title{ romaji english }]]

local function norm_media(m)
    local t = m.title or {}
    return {
        id       = m.id,
        title    = t.english or t.romaji or "?",
        alt      = (t.romaji and t.romaji ~= (t.english or t.romaji)) and t.romaji or nil,
        format   = m.format,
        chapters = tonumber(m.chapters),
        status   = m.status,
        score    = tonumber(m.averageScore),
        genres   = m.genres or {},
        year     = m.startDate and tonumber(m.startDate.year) or nil,
        desc     = m.description,
    }
end

-- opts : { sort = "TRENDING_DESC"|"POPULARITY_DESC"|"SCORE_DESC", formats = {…},
--          genre = "Action", search = "texte" }
function AniList.discover(opts)
    opts = opts or {}
    local d, err = gql("query($s:[MediaSort],$f:[MediaFormat],$g:String,$q:String){ Page(perPage:30){ media("
        .. "type:MANGA, sort:$s, format_in:$f, genre:$g, search:$q, isAdult:false){ " .. MEDIA_FIELDS .. " } } }", {
        s = (not opts.search) and { opts.sort or "POPULARITY_DESC" } or nil,
        f = opts.formats, g = opts.genre, q = opts.search,
    })
    if not d then return nil, err end
    local out = {}
    for _, m in ipairs(d.Page and d.Page.media or {}) do out[#out + 1] = norm_media(m) end
    return out, nil
end

-- Recommandations communautaires à partir de quelques titres appréciés.
-- `seeds` : liste d'identifiants AniList ; `known` : set d'identifiants à exclure.
function AniList.recommend(seeds, known)
    local acc, order = {}, {}
    local last_err
    for _, id in ipairs(seeds) do
        local d, err = gql("query($id:Int){ Media(id:$id){ recommendations(sort:RATING_DESC, perPage:10){ nodes{ rating "
            .. "mediaRecommendation{ " .. MEDIA_FIELDS .. " } } } } }", { id = id })
        if d and d.Media and d.Media.recommendations then
            for _, n in ipairs(d.Media.recommendations.nodes or {}) do
                local m = n.mediaRecommendation
                if m and m.id and not (known and known[m.id]) and (n.rating or 0) > 0 then
                    if not acc[m.id] then acc[m.id] = { m = norm_media(m), r = 0 }; order[#order + 1] = m.id end
                    acc[m.id].r = acc[m.id].r + (n.rating or 0)
                end
            end
        else
            last_err = err
        end
    end
    if #order == 0 then return nil, last_err end
    table.sort(order, function(a, b) return acc[a].r > acc[b].r end)
    local out = {}
    for i = 1, math.min(30, #order) do out[i] = acc[order[i]].m end
    return out, nil
end

return AniList
