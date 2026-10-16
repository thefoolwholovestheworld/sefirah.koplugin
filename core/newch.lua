-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- core/newch.lua — alertes « nouveau chapitre » pour les romans favoris.
--
-- Réglages (settings.lua) :
--   newch_mode   "ask" (défaut : demande à chaque ajout aux favoris, sauf
--                case « ne plus demander ») | "all" (tous les romans) | "none"
--   newch_novels table  id → { notify = bool, no_ask = bool }  (par roman)
--
-- Une boucle unique (UIManager:scheduleIn) vérifie UN roman à la fois, quand la
-- liseuse est déjà en ligne, partout dans KOReader (liste de fichiers, lecture…).
--
-- En plus, à CHAQUE connexion Wi-Fi (évènement KOReader « NetworkConnected »),
-- tous les romans pour lesquels l'utilisateur a accepté les alertes sont
-- vérifiés, et un popup s'affiche pour chacun de ceux qui ont du nouveau.

local UIManager = require("ui/uimanager")
local logger    = require("logger")

local Newch = {}

local FIRST_DELAY  = 90          -- 1re vérification, 90 s après le démarrage
local TICK         = 10 * 60     -- un roman vérifié toutes les 10 min au plus
local PER_NOVEL    = 3 * 3600    -- chaque roman est revérifié au plus toutes les 3 h

local function Settings() return require("settings") end
local function DB()       return require("core.db") end

local function novel_key(source_id, path)
    return tostring(source_id) .. ":" .. tostring(path)
end

local function decisions()
    local t = Settings():get("newch_novels")
    return type(t) == "table" and t or {}
end

function Newch.mode()
    local m = Settings():get("newch_mode")
    if m == "all" or m == "none" then return m end
    return "ask"
end

function Newch.setNovel(source_id, path, notify, no_ask)
    local copy = {}
    for k, v in pairs(decisions()) do copy[k] = v end
    copy[novel_key(source_id, path)] = { notify = notify and true or false, no_ask = no_ask and true or false }
    Settings():set("newch_novels", copy)
end

-- Une source doit être installée (onglet Sources) pour être vérifiée.
local function source_installed(source_id)
    local ok, v = pcall(function() return require("core.extmgr").isInstalled(source_id) end)
    if not ok then return true end   -- en cas de doute, on ne coupe pas les alertes
    return v == true
end

-- Source qui échoue (ex. blocage Cloudflare) : après FAIL_LIMIT échecs de suite,
-- on la laisse tranquille FAIL_PAUSE secondes (jusqu'au prochain redémarrage au plus).
local FAIL_LIMIT = 2
local FAIL_PAUSE = 2 * 3600
local _fails = {}   -- source_id -> { n = échecs de suite, pause_until = heure }

local function source_paused(source_id)
    local f = _fails[source_id]
    if not f or not f.pause_until then return false end
    local now = os.time()
    if now >= f.pause_until or f.pause_until - now > FAIL_PAUSE then
        _fails[source_id] = nil
        return false
    end
    return true
end

local function note_result(source_id, ok)
    if ok then _fails[source_id] = nil; return end
    local f = _fails[source_id] or { n = 0 }
    f.n = f.n + 1
    if f.n >= FAIL_LIMIT then
        f.pause_until = os.time() + FAIL_PAUSE
        logger.warn("Sefirah/Newch: source en pause :", tostring(source_id))
    end
    _fails[source_id] = f
end

function Newch.isEnabledFor(source_id, path)
    local mode = Newch.mode()
    if mode == "none" then return false end
    if not source_installed(source_id) then return false end
    if mode == "all"  then return true end
    local d = decisions()[novel_key(source_id, path)]
    return d ~= nil and d.notify == true
end

local function shouldAsk(source_id, path)
    if Newch.mode() ~= "ask" then return false end
    local d = decisions()[novel_key(source_id, path)]
    return not (d and d.no_ask)
end

-- Point de départ : on ne prévient que des chapitres publiés APRÈS l'activation.
local function set_baseline(source_id, path, total)
    if total and total > 0 then
        pcall(function() DB().update(source_id, path, { notified_count = total }) end)
    end
end

-- Applique la réponse du popup (cases à cocher incluses).
local function apply_answer(sid, path, total, res)
    if res.no_all then
        Settings():set("newch_mode", res.notify and "all" or "none")
    end
    Newch.setNovel(sid, path, res.notify, res.no_this or res.no_all)
    if res.notify then
        set_baseline(sid, path, total)
        Newch.start()
    end
end

-- ── Appelé juste après l'ajout d'un roman aux favoris ────────────────────────
function Newch.onFavorited(novel)
    local sid, path = novel.source_id, novel.path or ""
    if not shouldAsk(sid, path) then
        if Newch.isEnabledFor(sid, path) then
            set_baseline(sid, path, novel.total_chapters)
            Newch.start()
        end
        return
    end

    require("ui.newch_popups").favoritePrompt(novel.title, function(res)
        if res.dismissed then return end
        apply_answer(sid, path, novel.total_chapters, res)
    end)
end

-- ── Romans DÉJÀ en favoris, sans choix enregistré ───────────────────────────
-- Appelé à l'ouverture de Sefirah : pose la question, un roman après l'autre,
-- une seule fois par session KOReader. Cocher « tous les romans » met fin à la
-- série ; Retour l'interrompt (la question sera reposée à la prochaine session).
local _existing_started = false

function Newch.askForExisting()
    if _existing_started or Newch.mode() ~= "ask" then return end

    local pending, d = {}, decisions()
    for _, n in ipairs(DB().getAll()) do
        if d[novel_key(n.source_id, n.path)] == nil then pending[#pending + 1] = n end
    end
    if #pending == 0 then return end
    _existing_started = true

    local Popups = require("ui.newch_popups")
    local i = 0
    local function nxt()
        i = i + 1
        local n = pending[i]
        if not n or Newch.mode() ~= "ask" then return end
        local label = (n.title or "?") .. (#pending > 1 and ("  (" .. i .. "/" .. #pending .. ")") or "")
        Popups.favoritePrompt(label, function(res)
            if res.dismissed then return end
            apply_answer(n.source_id, n.path or "", n.total_chapters, res)
            UIManager:scheduleIn(0.3, nxt)
        end)
    end
    UIManager:scheduleIn(1.5, nxt)
end

-- ── Vérification d'un roman ──────────────────────────────────────────────────

local function pick_candidate()
    local now, best, best_t = os.time(), nil, nil
    for _, n in ipairs(DB().getAll()) do
        if Newch.isEnabledFor(n.source_id, n.path) and not source_paused(n.source_id) then
            local last = n.newch_checked_at or 0
            if last > now then last = 0 end
            if now - last >= PER_NOVEL and (not best or last < best_t) then
                best, best_t = n, last
            end
        end
    end
    return best
end

-- state.fresh = true : la liste des chapitres a déjà été mise à jour sur le
-- disque, la fiche s'ouvre donc tout de suite depuis la bibliothèque, sans
-- refaire de requêtes réseau.
local function open_callback(n, state)
    return function()
        if _G.sefirah_open_novel then
            _G.sefirah_open_novel(n.source_id, n.path, not (state and state.fresh))
        end
    end
end

-- Met à jour la liste des chapitres en cache (même résultat qu'« Actualiser la
-- liste des chapitres »). Renvoie true si le cache a bien été réécrit.
local function refresh_chapter_list(ext, n)
    if type(ext.parseNovel) ~= "function" then return false end
    -- Sources avec pagination (NovelFrance…) : parseNovel = des dizaines de requêtes
    -- synchrones qui figent la liseuse (le popup mettait « 10 ans » à ouvrir le roman).
    -- On ne fait rien ici : à l'ouverture, la fiche ne récupère que les nouvelles pages.
    if type(ext.parsePage) == "function" and ext.chapters_per_page then return false end
    local ok, full = pcall(ext.parseNovel, ext, n.path)
    if not ok or type(full) ~= "table" or type(full.chapters) ~= "table" or #full.chapters == 0 then
        return false
    end
    DB().saveChapterCache(n.source_id, n.path, full.chapters, #full.chapters)
    return true
end

local function check_one(n)
    local ExtMgr = require("core.extmgr")
    local ext = ExtMgr.get(n.source_id)
    DB().update(n.source_id, n.path, { newch_checked_at = os.time() })
    if not ext then return end

    -- Requête légère d'abord (nombre total de chapitres), liste complète sinon.
    local total, last_title
    if type(ext.parseNovelMeta) == "function" then
        local ok, meta = pcall(ext.parseNovelMeta, ext, n.path)
        if ok and type(meta) == "table" and tonumber(meta.total_chapters) and meta.total_chapters > 0 then
            total = meta.total_chapters
        end
    end
    if not total and type(ext.parseNovel) == "function" then
        local ok, info = pcall(ext.parseNovel, ext, n.path)
        if ok and type(info) == "table" and type(info.chapters) == "table" and #info.chapters > 0 then
            total = #info.chapters
            local ch = info.chapters[total]
            last_title = ch and (ch.name or ch.title)
        end
    end
    note_result(n.source_id, total ~= nil)
    if not total then return end

    local base = n.notified_count or n.total_chapters or 0
    if total <= base then
        if n.notified_count == nil then set_baseline(n.source_id, n.path, total) end
        return
    end

    -- Chapitres que l'utilisateur voit déjà dans sa liste (cache de la fiche) :
    -- ils ne comptent pas comme « nouveaux », même si la valeur mémorisée à
    -- l'activation des alertes était plus ancienne.
    local seen = n.total_chapters or 0
    local okc, cache = pcall(function() return DB().loadChapterCache(n.source_id, n.path) end)
    if okc and type(cache) == "table" then
        seen = math.max(seen, tonumber(cache.total) or #(cache.chapters or {}))
    end
    if seen > base and seen <= total then base = seen end
    if total <= base then
        DB().update(n.source_id, n.path, { notified_count = total })
        return
    end

    DB().update(n.source_id, n.path, { total_chapters = total, notified_count = total })

    local cover_bb
    pcall(function()
        local Screen = require("device").screen
        local Covers = require("core.covers")
        local site   = (ExtMgr.getMeta(n.source_id) or {}).site
        cover_bb = Covers.get(n.source_id, n.path or "", n.cover, site,
            math.floor(Screen:getWidth() * 0.5), math.floor(Screen:getHeight() * 0.36))
    end)

    local state = { fresh = false }
    require("ui.newch_popups").newChapters{
        title      = n.title or "?",
        added      = total - base,
        last_title = last_title,
        cover_bb   = cover_bb,
        on_open    = open_callback(n, state),
    }

    -- Une fois le popup affiché, met la liste des chapitres à jour en arrière-plan :
    -- quand on tape « Ouvrir le roman », la fiche s'ouvre alors instantanément.
    UIManager:scheduleIn(0.8, function()
        local okr, done = pcall(refresh_chapter_list, ext, n)
        state.fresh = okr and done and true or false
    end)
end

local function run_tick()
    if Newch.mode() == "none" then return end
    local Popups = require("ui.newch_popups")
    if Popups.isBusy() then return end

    local n = pick_candidate()
    if not n then return end

    local online = false
    pcall(function() online = require("ui/network/manager"):isOnline() end)
    if not online then return end

    local ok, err = pcall(check_one, n)
    if not ok then logger.warn("Sefirah/Newch: check failed:", tostring(err)) end
end

-- ── À chaque connexion Wi-Fi ────────────────────────────────────────────────
-- Seuls les romans pour lesquels l'utilisateur a dit « oui » sont vérifiés
-- (isEnabledFor). Un roman à la fois, avec une courte pause entre deux, pour
-- que la liseuse reste utilisable pendant la vérification.

local CONNECT_DELAY    = 4    -- laisse la connexion se stabiliser
local CONNECT_DEBOUNCE = 60   -- ignore les évènements en rafale
local STEP_DELAY       = 1.5  -- pause entre deux romans
local MAX_ONLINE_WAIT  = 5    -- nombre d'attentes (3 s) si le réseau n'est pas encore prêt

local _sweeping     = false
local _last_connect = nil

local function is_online()
    local online = false
    pcall(function() online = require("ui/network/manager"):isOnline() end)
    return online
end

local function sweep()
    local todo = {}
    for _, n in ipairs(DB().getAll()) do
        if Newch.isEnabledFor(n.source_id, n.path) and not source_paused(n.source_id) then
            todo[#todo + 1] = { n.source_id, n.path }
        end
    end

    local i = 0
    local function step()
        if Newch.mode() == "none" or not is_online() then _sweeping = false; return end
        i = i + 1
        local ref = todo[i]
        if not ref then _sweeping = false; return end

        -- Fiche relue à chaque pas : la boucle de fond a pu la mettre à jour.
        local n = DB().find(ref[1], ref[2])
        if n and Newch.isEnabledFor(n.source_id, n.path) and not source_paused(n.source_id) then
            local ok, err = pcall(check_one, n)
            if not ok then logger.warn("Sefirah/Newch: check failed:", tostring(err)) end
        end
        UIManager:scheduleIn(STEP_DELAY, step)
    end
    step()
end

local function wait_online(attempt)
    if is_online() then return sweep() end
    if attempt >= MAX_ONLINE_WAIT then _sweeping = false; return end
    UIManager:scheduleIn(3, function() wait_online(attempt + 1) end)
end

-- Appelé par Sefirah:onNetworkConnected (main.lua).
function Newch.onNetworkConnected()
    if Newch.mode() == "none" or _sweeping then return end

    local now = os.time()
    if _last_connect then
        local d = now - _last_connect
        if d >= 0 and d < CONNECT_DEBOUNCE then return end
    end
    _last_connect = now

    _sweeping = true
    UIManager:scheduleIn(CONNECT_DELAY, function() wait_online(0) end)
end

-- ── Boucle unique, valable pour toute la session KOReader ───────────────────

local function tick()
    pcall(run_tick)
    UIManager:scheduleIn(TICK, tick)
end

function Newch.start()
    if _G.__sefirah_newch_loop then return end
    _G.__sefirah_newch_loop = true
    UIManager:scheduleIn(FIRST_DELAY, tick)
end

return Newch
