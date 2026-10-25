-- Classement communautaire Sefirah MangaBall.
-- Les scores restent locaux hors ligne ; les XP en attente sont envoyés par lots
-- idempotents lorsque l'utilisateur ouvre le classement ou demande une actualisation.
-- Important : l'identifiant local n'est pas une preuve cryptographique d'identité.
local Settings = require("sefirah_settings")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local P = require("ui.panel")
local T = require("core.i18n").T
local ok_json, JSON = pcall(require, "rapidjson")
if not ok_json then JSON = require("json") end
local ltn12 = require("ltn12")
local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
local Leaderboard = {}
local cache = { players = {}, works = {}, error = "Classement non chargé." }

local function msg(text, timeout)
    UIManager:show(InfoMessage:new{ text = tostring(text), timeout = timeout or 4 })
end
local function trim(s) local r = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""); return r end
local function player_token()
    local token = Settings:get("leaderboard_player_token")
    if type(token) == "string" and token ~= "" then return token end
    math.randomseed(os.time() + math.floor((socket.gettime() or 0) * 1000) + 17)
    token = string.format("%08x%08x%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff), math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
    Settings:set("leaderboard_player_token", token)
    return token
end
local function default_url()
    local ok, cfg = pcall(require, "community_config")
    local url = ok and type(cfg) == "table" and trim(cfg.url) or ""
    if url:find("REMPLACER", 1, true) then return "" end
    return url
end
local function base_url()
    local url = trim(Settings:get("leaderboard_url"))
    if url == "" then url = default_url() end
    return (url:gsub("/+$", ""))
end
local function player_id()
    local id = Settings:get("leaderboard_player_id")
    if type(id) == "string" and id ~= "" then return id end
    math.randomseed(os.time() + math.floor((socket.gettime() or 0) * 1000))
    id = string.format("p-%x-%04x%04x", os.time(), math.random(0, 65535), math.random(0, 65535))
    Settings:set("leaderboard_player_id", id)
    return id
end
local API_ERRORS = {
    username_taken     = "Ce pseudo est déjà pris par un autre joueur.",
    user_not_found     = "Aucun joueur avec ce pseudo.",
    cannot_friend_self = "Tu ne peux pas t'ajouter toi-même.",
    friend_limit       = "Limite d'amis atteinte (100).",
    request_limit      = "Trop de demandes en attente (30 maximum).",
    request_not_found  = "Cette demande n'existe plus.",
    query_too_short    = "Entre au moins 2 lettres.",
    daily_xp_limit     = "Limite d'XP atteinte pour le moment : la suite sera envoyée plus tard.",
    rate_limited       = "Trop de requêtes : réessaie dans une minute.",
    banned             = "Ce compte a été bloqué par le serveur.",
    not_found          = "Le serveur n'est pas à jour : redéploie worker.js pour activer les amis.",
}
local function request(method, path, payload, root_override)
    local root = root_override or base_url()
    if root == "" then return nil, T("Configure d'abord l'URL du serveur.") end
    if not root:match("^https?://") then return nil, T("L'URL doit commencer par https:// ou http://.") end
    local body = payload and JSON.encode(payload) or nil
    local headers = { ["User-Agent"] = "Sefirah-MangaBall/1.0", ["Accept"] = "application/json" }
    if body then headers["Content-Type"] = "application/json"; headers["Content-Length"] = tostring(#body) end
    local url = root .. path
    local response = {}
    local req = url:match("^https://") and https or http
    local pok, ok, code, rh = pcall(req.request, {
        url = url, method = method, headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response), timeout = 6,
    })
    local raw
    if pok and ok and tonumber(code) and tonumber(code) >= 200 and tonumber(code) < 300 then
        raw = table.concat(response)
    elseif url:match("^https://") and (not pok or not tonumber(code)) then
        -- Le DNS de la liseuse ne résout pas le serveur (« host or service not known ») :
        -- repli par DNS-over-HTTPS (core/dnsbypass.lua), sans rien changer au Wi-Fi.
        local okb, Bypass = pcall(require, "core.dnsbypass")
        if okb and Bypass then
            local pb, b, bcode = pcall(Bypass.get, url, {
                method = method, body = body, headers = headers,
                timeout = 8, deadline = 25, max_bytes = 524288,
            })
            if pb and type(b) == "string" then raw = b
            else code = pb and bcode or code end
        end
    end
    if not raw then
        -- Le serveur a répondu, mais par une erreur connue : on affiche un message clair.
        if tonumber(code) and tonumber(code) >= 400 and #response > 0 then
            local dok, derr = pcall(JSON.decode, table.concat(response))
            if dok and type(derr) == "table" and type(derr.error) == "string" and API_ERRORS[derr.error] then
                return nil, T(API_ERRORS[derr.error]), derr.error
            end
        end
        return nil, T("Serveur inaccessible (%s).")
:format(tostring(code or rh or T("réseau")))
    end
    local success, decoded = pcall(JSON.decode, raw)
    if not success or type(decoded) ~= "table" then return nil, T("Réponse serveur invalide.") end
    return decoded
end

local function wifi_up()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isConnected then return false end
    local okc, up = pcall(NetworkMgr.isConnected, NetworkMgr)
    return okc and up and true or false
end

local function progress_data()
    local d = Settings:get("community_progress")
    if type(d) ~= "table" then d = {} end
    return d
end
local function save_progress(d) Settings:set("community_progress", d) end

function Leaderboard.configure(key, title, callback)
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = tostring(Settings:get(key) or ""),
        buttons = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            { text = T("Enregistrer"), is_enter_default = true, callback = function()
                local value = trim(dlg:getInputText())
                UIManager:close(dlg)
                Settings:set(key, value)
                if callback then callback() end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Ajoute localement une consultation d'œuvre ; l'envoi réseau se fait lors de l'actualisation,
-- jamais pendant l'ouverture d'une fiche (pour ne pas ralentir la navigation).
function Leaderboard.queueWork(work)
    if type(work) ~= "table" then return end
    if Settings:get("leaderboard_hide_works") == true then return end   -- « Masquer mes œuvres » : rien n'est partagé
    local title = trim(work.title or work.name)
    local source = trim(work.source or "inconnu")
    local work_id = trim(work.work_id or work.id or work.path)
    if title == "" or work_id == "" then return end
    local d = progress_data()
    d.pending_work_events = type(d.pending_work_events) == "table" and d.pending_work_events or {}
    local key = source .. "|" .. work_id
    local now = os.time()
    -- Évite de compter plusieurs fois la même fiche pendant 24 heures sur cet appareil.
    if d.last_work_seen and d.last_work_seen[key] and now - d.last_work_seen[key] < 86400 then return end
    d.last_work_seen = type(d.last_work_seen) == "table" and d.last_work_seen or {}
    d.last_work_seen[key] = now
    d.work_counter = (tonumber(d.work_counter) or 0) + 1
    local event_id = player_id() .. "-w-" .. tostring(d.work_counter)
    d.pending_work_events[#d.pending_work_events + 1] = {
        work_id = key, title = title, source = source,
        kind = tostring(work.kind or "other"), event_id = event_id, event_type = "open",
    }
    while #d.pending_work_events > 100 do table.remove(d.pending_work_events, 1) end
    save_progress(d)
end

-- Pseudo refusé par le serveur (déjà pris) : on remet le dernier pseudo accepté.
local function username_refused()
    local prev = trim(Settings:get("leaderboard_username_synced"))
    Settings:set("leaderboard_username", prev)
    if prev ~= "" then
        return T("Ce pseudo est déjà pris. Ton pseudo actuel « %s » est conservé."):format(prev)
    end
    return T("Ce pseudo est déjà pris. Choisis-en un autre.")
end

-- Le serveur ne change le pseudo d'un joueur que lorsqu'il reçoit un message : sans ceci, un nouveau
-- pseudo n'apparaissait au classement qu'après avoir gagné de l'XP en lisant. « leaderboard_username_synced »
-- garde le dernier pseudo effectivement envoyé.
local function avatar_state()
    local ok, Pdp = pcall(require, "ui.pdp")
    if not ok or not Pdp or not Pdp.syncState then return nil end
    local cur, synced = Pdp.syncState(), Settings:get("leaderboard_avatar_synced")
    if cur == "none" and synced == nil then return nil end        -- jamais de photo : rien à faire
    if tostring(cur) == tostring(synced) then return nil end      -- déjà à jour sur le serveur
    return cur, Pdp
end
local function creator_check_due() return Settings:get("leaderboard_creator_check") ~= os.date("%Y-%m-%d") end

-- Le serveur indique si ce compte est le créateur (badge « Créateur » automatique, cf. worker.js).
local function note_creator(res)
    if type(res) == "table" and type(res.creator) == "boolean" then
        Settings:set("leaderboard_is_creator", res.creator)
        Settings:set("leaderboard_creator_check", os.date("%Y-%m-%d"))
    end
end

local function sync_profile()
    local username = trim(Settings:get("leaderboard_username"))
    if username == "" or base_url() == "" then return false end
    local name_ok = Settings:get("leaderboard_username_synced") == username
    local avatar_cur = avatar_state()
    if name_ok and not avatar_cur and not creator_check_due() then return true end
    local res, err, code = request("POST", "/api/profile", {
        player_id = player_id(), player_token = player_token(), username = username,
    })
    if res and res.ok then
        Settings:set("leaderboard_username_synced", username)
        note_creator(res)
    elseif code == "username_taken" then return false, username_refused(), code
    else return false end   -- ancien serveur sans /api/profile, ou joueur encore inconnu : le prochain envoi d'XP renommera
    -- Photo de profil (envoi séparé : une photo refusée ne bloque pas le pseudo).
    local cur, Pdp = avatar_state()
    if cur then
        local payload = { player_id = player_id(), player_token = player_token(), username = username }
        if cur == "none" then payload.avatar_clear = true else payload.avatar = Pdp.exportSmall() end
        if cur == "none" or payload.avatar then
            local ares = request("POST", "/api/profile", payload)
            if ares and ares.ok then Settings:set("leaderboard_avatar_synced", cur) end
        end
    end
    return true
end

local function sync_work_events()
    if Settings:get("leaderboard_hide_works") == true then
        local d0 = progress_data()
        if type(d0.pending_work_events) == "table" and #d0.pending_work_events > 0 then
            d0.pending_work_events = {}
            save_progress(d0)
        end
        if Settings:get("leaderboard_works_forget_pending") then
            local res, err, code = request("POST", "/api/works/forget", {
                player_id = player_id(), player_token = player_token(),
                username = trim(Settings:get("leaderboard_username")),
            })
            if (res and res.ok) or code == "not_found" then Settings:set("leaderboard_works_forget_pending", false)
            else return false, err end
        end
        return true
    end
    local d = progress_data()
    d.pending_work_events = type(d.pending_work_events) == "table" and d.pending_work_events or {}
    local username = trim(Settings:get("leaderboard_username"))
    if username == "" then return false, T("Choisis d'abord un pseudo public.") end
    while #d.pending_work_events > 0 do
        local work = d.pending_work_events[1]
        local res, err, code = request("POST", "/api/works/event", {
            player_id = player_id(), player_token = player_token(), username = username,
            work_id = work.work_id, title = work.title, source = work.source,
            kind = work.kind, event_id = work.event_id, event_type = work.event_type,
        })
        if not res then
            if code == "username_taken" then return false, username_refused(), code end
            return false, err
        end
        table.remove(d.pending_work_events, 1)
        save_progress(d)
    end
    return true
end

-- Remise à zéro demandée par l'utilisateur : le serveur garde l'XP cumulée, donc il faut aussi la lui faire
-- oublier. Le drapeau reste posé jusqu'à ce que le serveur confirme (hors ligne : réessayé à la prochaine synchro).
function Leaderboard.resetRemote()
    if not Settings:get("leaderboard_reset_pending") then return true end
    local username = trim(Settings:get("leaderboard_username"))
    if username == "" or base_url() == "" then return true end   -- jamais inscrit : rien à effacer
    local res, err, code = request("POST", "/api/reset", {
        player_id = player_id(), player_token = player_token(), username = username,
    })
    if res and res.ok then
        Settings:set("leaderboard_reset_pending", false)
        cache.players = {}
        return true
    end
    if code == "not_found" then
        -- Ancien serveur sans /api/reset : on abandonne (sinon la synchro resterait bloquée) et on prévient.
        Settings:set("leaderboard_reset_pending", false)
        msg(T("Ton serveur n'est pas à jour : redéploie backend/worker.js pour effacer ton ancienne XP du classement."), 8)
        return true
    end
    return false, err
end

function Leaderboard.sync()
    local rok, rerr = Leaderboard.resetRemote()
    if not rok then return false, rerr end
    local d = progress_data()
    d.pending_xp = math.max(0, math.floor(tonumber(d.pending_xp) or 0))
    local username = trim(Settings:get("leaderboard_username"))
    if username == "" then return false, T("Choisis d'abord un pseudo public.") end
    if base_url() == "" then return false, T("Configure d'abord l'URL du serveur.") end
    local id = player_id()
    -- Les XP sont envoyées par lots de 5 000 maximum (les gros succès rapportent plus de 500 XP).
    while d.pending_xp > 0 do
        if not d.pending_batch_id then
            d.batch_counter = (tonumber(d.batch_counter) or 0) + 1
            d.pending_batch_xp = math.min(5000, d.pending_xp)
            d.pending_batch_id = id .. "-" .. tostring(d.batch_counter)
            save_progress(d)
        end
        local amount = math.min(5000, tonumber(d.pending_batch_xp) or 0)
        if amount <= 0 then d.pending_batch_id, d.pending_batch_xp = nil, nil; save_progress(d); break end
        local res, err, code = request("POST", "/api/xp", {
            player_id = id, player_token = player_token(), username = username, event_id = d.pending_batch_id,
            xp_delta = amount,
        })
        if not res then
            if code == "username_taken" then return false, username_refused(), code end
            return false, err
        end
        Settings:set("leaderboard_username_synced", username)   -- l'envoi d'XP met aussi le pseudo à jour
        note_creator(res)
        d.pending_xp = math.max(0, d.pending_xp - amount)
        d.pending_batch_id, d.pending_batch_xp = nil, nil
        save_progress(d)
    end
    return true
end

function Leaderboard.refresh(period)
    period = period or cache.period or "general"
    period = (period == "weekly") and "weekly" or "general"
    cache.period = period
    local pok, _pres, perr, pcode = pcall(sync_profile)
    if pok and pcode == "username_taken" then return false, perr end
    local ok, err, code = Leaderboard.sync()
    if not ok and code == "username_taken" then return false, err end
    if not ok and (err == T("Configure d'abord l'URL du serveur.") or err == T("Choisis d'abord un pseudo public.")) then
        cache.players, cache.error = {}, err
        return false, err
    end
    local works_ok, works_err = sync_work_events()
    local path = "/api/leaderboard?limit=20" .. (period == "weekly" and "&period=weekly" or "")
    local res, fetch_err = request("GET", path, nil)
    if not res then cache.error = fetch_err; return false, fetch_err end
    cache.players = type(res.players) == "table" and res.players or (type(res.leaderboard) == "table" and res.leaderboard or {})
    local popular = request("GET", "/api/works/popular?period=week&limit=10", nil)
    cache.works = popular and type(popular.works) == "table" and popular.works or {}
    cache.error = nil
    cache.last_try = os.time()
    if not works_ok and works_err then cache.sync_error = works_err end
    return true
end

-- Accès lecture pour l'écran ui/progress.lua.
function Leaderboard.getState() return cache end
function Leaderboard.worksHidden() return Settings:get("leaderboard_hide_works") == true end
-- Paramètre « Masquer mes œuvres dans Populaires » : activé, mes consultations ne sont plus envoyées
-- et celles déjà envoyées sont effacées du serveur à la prochaine synchro.
function Leaderboard.setWorksHidden(on)
    Settings:set("leaderboard_hide_works", on and true or false)
    if on then Settings:set("leaderboard_works_forget_pending", true) end
end
function Leaderboard.selfId() return player_id() end
function Leaderboard.username() return trim(Settings:get("leaderboard_username")) end

-- ── Amis ────────────────────────────────────────────────────────────────────
-- Tous les appels sont bloquants (à lancer via core.online / une tâche différée).
cache.friends = { friends = {}, incoming = {}, outgoing = {}, loaded = false }

local function friend_call(path, extra)
    local username = trim(Settings:get("leaderboard_username"))
    if username == "" then return nil, T("Choisis d'abord un pseudo public.") end
    local payload = extra or {}
    payload.player_id, payload.player_token, payload.username = player_id(), player_token(), username
    local res, err, code = request("POST", path, payload)
    if not res and code == "username_taken" then return nil, username_refused(), code end
    return res, err, code
end

function Leaderboard.refreshFriends()
    local res, err = friend_call("/api/friends/list")
    if not res then cache.friends_error = err; return false, err end
    cache.friends = {
        friends = type(res.friends) == "table" and res.friends or {},
        incoming = type(res.incoming) == "table" and res.incoming or {},
        outgoing = type(res.outgoing) == "table" and res.outgoing or {},
        loaded = true,
    }
    cache.friends_error = nil
    return true
end

-- Recherche par pseudo (début du pseudo, majuscules ignorées). Retourne la liste ou nil, erreur.
function Leaderboard.searchPlayers(q)
    local res, err = friend_call("/api/friends/search", { q = trim(q) })
    if not res then return nil, err end
    return type(res.players) == "table" and res.players or {}
end

function Leaderboard.friendRequest(name) return friend_call("/api/friends/request", { target = name }) end
function Leaderboard.friendRespond(name, accept) return friend_call("/api/friends/respond", { from = name, accept = accept and true or false }) end
function Leaderboard.friendRemove(name) return friend_call("/api/friends/remove", { target = name }) end

-- Actualisation non bloquante de la liste d'amis (ouverture de l'onglet) : hors ligne, on garde
-- ce qui est affiché.
function Leaderboard.refreshFriendsAsync(redraw)
    if cache.fbusy or not wifi_up() then return end
    cache.fbusy = true
    UIManager:scheduleIn(0.2, function()
        pcall(Leaderboard.refreshFriends)
        cache.fbusy = false
        if redraw then pcall(redraw) end
    end)
end


-- Actualisation automatique à l'ouverture de l'onglet (au plus une fois par 2 min, sans invite Wi-Fi :
-- hors ligne, on ne fait rien).
function Leaderboard.autoRefresh(redraw)
    if cache.busy then return end
    local now = os.time()
    if cache.last_try and now - cache.last_try < 120 then return end
    cache.last_try = now
    if not wifi_up() then return end
    cache.busy = true
    UIManager:scheduleIn(0.3, function()
        pcall(Leaderboard.refresh)
        cache.busy = false
        cache.last_try = os.time()
        if redraw then pcall(redraw) end
    end)
end

-- Actualisation non bloquante pour une période donnée (changement de sous-onglet) : hors ligne,
-- on garde simplement les données affichées.
function Leaderboard.refreshAsync(period, redraw)
    cache.period = (period == "weekly") and "weekly" or "general"
    if cache.busy or not wifi_up() then return end
    cache.busy = true
    UIManager:scheduleIn(0.2, function()
        pcall(Leaderboard.refresh, cache.period)
        cache.busy = false
        if redraw then pcall(redraw) end
    end)
end

-- Envoi discret des XP / consultations / pseudo en attente (appelé depuis la lecture, au changement de
-- chapitre) : au plus toutes les 5 min, seulement si le Wi-Fi est déjà connecté.
function Leaderboard.backgroundSync()
    if cache.bg_at and os.time() - cache.bg_at < 300 then return end
    local d = progress_data()
    local username = trim(Settings:get("leaderboard_username"))
    if username == "" or base_url() == "" then return end
    local pending = (tonumber(d.pending_xp) or 0) > 0 or #(d.pending_work_events or {}) > 0
        or Settings:get("leaderboard_username_synced") ~= username or avatar_state() ~= nil
    if not pending or not wifi_up() then return end
    cache.bg_at = os.time()
    UIManager:scheduleIn(2, function()
        pcall(sync_profile)
        pcall(Leaderboard.sync)
        pcall(sync_work_events)
    end)
end

function Leaderboard.makeRows(PANEL, redraw)
    if redraw then Leaderboard.autoRefresh(redraw) end
    local rows = {}
    rows[#rows + 1] = PANEL.makeRow("CLASSEMENT COMMUNAUTAIRE", { bold = true, height = PANEL.ROW_H })
    rows[#rows + 1] = PANEL.makeRow("Pseudo : " .. (trim(Settings:get("leaderboard_username")) ~= "" and trim(Settings:get("leaderboard_username")) or "non configuré"), {
        trailing = "Modifier", callback = function()
            Leaderboard.configure("leaderboard_username", "Pseudo public", function()
                -- Nouveau pseudo : envoi immédiat au serveur puis rafraîchissement du classement.
                local okO, Online = pcall(require, "core.online")
                local function go()
                    local ok, err = Leaderboard.refresh()
                    if not ok then msg(err or "Actualisation impossible.") end
                    if redraw then redraw() end
                end
                if redraw then redraw() end
                if okO and Online and Online.run then Online.run(go) else go() end
            end)
        end,
    })
    local url = base_url()
    rows[#rows + 1] = PANEL.makeRow("Serveur : " .. (url ~= "" and url or "non configuré"), {
        trailing = "Modifier", callback = function()
            Leaderboard.configure("leaderboard_url", "URL de l'API (ex. https://mon-serveur.example)", redraw)
        end,
    })
    rows[#rows + 1] = PANEL.makeRow("Actualiser et synchroniser", { bold = true, mandatory = "↻", callback = function()
        -- Allume le Wi-Fi si besoin (invite de connexion de la liseuse), puis synchronise.
        local okO, Online = pcall(require, "core.online")
        local function go()
            local ok, err = Leaderboard.refresh()
            if not ok then msg(err or "Actualisation impossible.") end
            if redraw then redraw() end
        end
        if okO and Online and Online.run then Online.run(go) else go() end
    end })
    rows[#rows + 1] = PANEL.hairline()
    rows[#rows + 1] = PANEL.makeRow("RANG     JOUEUR / NIVEAU                         XP", { bold = true })
    if cache.error then
        rows[#rows + 1] = PANEL.makeRow(cache.error, { dim = true, height = PANEL.ROW_H + 12 })
        rows[#rows + 1] = PANEL.makeRow("Les XP gagnées hors ligne restent enregistrées sur cet appareil.", { dim = true, height = PANEL.ROW_H + 12 })
    elseif #cache.players == 0 then
        rows[#rows + 1] = PANEL.makeRow("Aucun joueur dans le classement pour le moment.", { dim = true })
    else
        for i, player in ipairs(cache.players) do
            if i > 20 then break end
            local name = tostring(player.username or player.pseudo or "Lecteur")
            local level = math.max(1, tonumber(player.level) or require("core.progression").level(player.xp))
            local xp = math.max(0, tonumber(player.xp) or 0)
            rows[#rows + 1] = PANEL.makeRow(string.format("%02d. %s  ·  Niv. %d", i, name, level), { trailing = tostring(xp) .. " XP", height = PANEL.ROW_H + 2 })
        end
    end
    rows[#rows + 1] = PANEL.hairline()
    rows[#rows + 1] = PANEL.makeRow("ŒUVRES POPULAIRES — 7 DERNIERS JOURS", { bold = true, height = PANEL.ROW_H })
    if #cache.works == 0 then
        rows[#rows + 1] = PANEL.makeRow("Pas encore de statistiques communautaires.", { dim = true, height = PANEL.ROW_H + 6 })
    else
        for i, work in ipairs(cache.works) do
            if i > 10 then break end
            local title = tostring(work.title or "Œuvre")
            local readers = tonumber(work.readers) or 0
            local activity = tonumber(work.activity) or 0
            rows[#rows + 1] = PANEL.makeRow(string.format("%02d. %s", i, title), { trailing = tostring(readers) .. " lecteurs", height = PANEL.ROW_H + 2 })
        end
    end
    rows[#rows + 1] = PANEL.hairline()
    rows[#rows + 1] = PANEL.makeRow("Les scores en attente : " .. tostring(progress_data().pending_xp or 0) .. " XP", { dim = true })
    rows[#rows + 1] = PANEL.makeRow("Consultations en attente : " .. tostring(#(progress_data().pending_work_events or {})), { dim = true })
    rows[#rows + 1] = PANEL.makeRow("Les données se synchronisent lors de l'actualisation avec un serveur configuré.", { dim = true, height = PANEL.ROW_H + 8 })
    return rows
end

-- Routes sociales distinctes de l'API du classement.
function Leaderboard.socialRequest(route, payload, root)
    local allowed = {
        ["feed/list"] = true, ["post/create"] = true, ["post/like"] = true,
        ["comment/list"] = true, ["comment/create"] = true,
        ["conversations/list"] = true, ["messages/list"] = true, ["messages/send"] = true,
    }
    route = tostring(route or "")
    if not allowed[route] then return nil, T("Route sociale inconnue.") end
    root = trim(root or ""):gsub("/+$", "")
    if not root:match("^https://[%w%.%-]+$") then
        return nil, T("Le serveur social doit être une URL HTTPS sans chemin.")
    end
    local username = trim(Settings:get("leaderboard_username"))
    if username == "" then return nil, T("Choisis d'abord un pseudo public.") end
    payload = type(payload) == "table" and payload or {}
    payload.player_id, payload.player_token, payload.username = player_id(), player_token(), username
    return request("POST", "/api/social/" .. route, payload, root)
end

return Leaderboard
