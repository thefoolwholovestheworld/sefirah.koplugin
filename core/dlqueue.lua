-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- core/dlqueue.lua — file d'attente de téléchargement des chapitres.
--
--  * File persistante (sefirah/dlqueue.json) : survit à un redémarrage de KOReader.
--  * Un roman = une « tâche ». Les tâches passent l'une après l'autre ; les
--    tâches « auto » (chapitres d'avance pendant la lecture) passent en premier.
--  * Le travail se fait par petites tranches (quelques chapitres) avec une pause
--    entre deux : l'interface reste utilisable, et pause / annulation prennent
--    effet à la fin de la tranche en cours.
--  * Coupure réseau : la file se met en attente (sans jamais rallumer le Wi-Fi
--    toute seule) et reprend à la reconnexion (évènement NetworkConnected).
--  * Un site qui répond en erreur ne fait pas « brûler » toute la file : après
--    3 tranches sans aucun succès, la tâche attend 5 minutes avant de réessayer.
--
-- Le téléchargement lui-même reste Cache.downloadChapters (parallélisme par
-- source, nouvelles tentatives) : rien ne change côté extensions.
--
-- Réglages (settings.lua) : dl_ahead, dl_autoresume, dl_notify.

local UIManager   = require("ui/uimanager")
local logger      = require("logger")
local DataStorage = require("datastorage")
local socket      = require("socket")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local ok_json, JSON = pcall(require, "rapidjson")
if not ok_json then JSON = require("json") end

local Dlq = {}

local base_dir  = DataStorage:getSettingsDir() .. "/sefirah"
local file_path = base_dir .. "/dlqueue.json"

local STEP_GAP       = 0.3    -- pause entre deux tranches (l'interface reprend la main)
local MAX_ATTEMPTS   = 3      -- essais par chapitre (réseau OK) avant de l'abandonner
local STALL_SLICES   = 3      -- tranches de suite sans aucun succès → on laisse souffler le site
local STALL_RETRY    = 300    -- secondes d'attente après un blocage du site
local MAX_STALLS     = 3      -- blocages de suite avant d'abandonner la tâche (à relancer à la main)
local NET_RETRY      = 60     -- secondes entre deux contrôles quand le réseau est coupé
local CONNECT_DELAY  = 6      -- laisse la connexion se stabiliser après NetworkConnected
local INIT_DELAY     = 25     -- reprise après le démarrage de KOReader
local SLICE_WATCHDOG = 900    -- une tranche qui ne rend jamais la main est abandonnée
local SAVE_EVERY     = 20     -- chapitres entre deux écritures du fichier de file
local KEEP_DONE      = 8      -- tâches terminées gardées dans la liste
local TOAST_EVERY    = 25     -- une notification de progression tous les N chapitres

-- ── État ─────────────────────────────────────────────────────────────────────

local _q            = nil     -- { paused, next_id, jobs = { ... } }
local _busy         = false   -- une tranche est en cours
local _cur_job      = nil     -- tâche de la tranche en cours
local _token        = 0       -- identifie la tranche en cours (garde-fou)
local _since_save   = 0
local _last_connect = nil
local _net_timer    = false
local _net_toasted  = false
local _listeners    = {}
local _last_event   = setmetatable({}, { __mode = "k" })

local step            -- déclarée plus bas
local schedule

local function tr(s)
    local ok, I = pcall(require, "core.i18n")
    if ok and I and I.T then return I.T(s) end
    return s
end

local function setting(key)
    local ok, S = pcall(require, "settings")
    if not ok or type(S) ~= "table" then return nil end
    local ok2, v = pcall(S.get, S, key)
    if ok2 then return v end
    return nil
end

local function get_cache() return require("core.cache") end

-- Coupe un texte en respectant l'UTF-8.
local function cut(s, n)
    s = tostring(s or "")
    local chars, i = 0, 1
    while i <= #s do
        if chars >= n then return s:sub(1, i - 1) .. "…" end
        local c = s:byte(i)
        local len = (c < 0x80 and 1) or (c < 0xE0 and 2) or (c < 0xF0 and 3) or 4
        i = i + len
        chars = chars + 1
    end
    return s
end

local function finite(n)
    n = tonumber(n)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function ref_of(ch)
    local p = ch.path
    if p == nil or p == "" then p = ch.sourceUrl end
    if p == nil or p == "" then return nil end
    return p
end

-- Copie légère d'un chapitre (le fichier de file reste petit même pour 3000 chapitres).
local function compact(ch)
    return {
        path           = ch.path,
        sourceUrl      = ch.sourceUrl,
        name           = ch.name,
        title          = ch.title,
        chapter_number = finite(ch.chapter_number),
        order          = finite(ch.order),
    }
end

-- Notification discrète (ne bloque ni l'écran ni les touches).
local function toast(text, timeout, force)
    if _G.__sefirah_in_child then return end
    if not force and setting("dl_notify") == false then return end
    pcall(function()
        local Notification = require("ui/widget/notification")
        UIManager:show(Notification:new{ text = text, timeout = timeout or 2 })
    end)
end

-- ── Fichier ──────────────────────────────────────────────────────────────────

local function load_q()
    if _q then return _q end
    _q = { paused = false, next_id = 1, jobs = {} }
    local f = io.open(file_path, "r")
    if not f then return _q end
    local raw = f:read("*all"); f:close()
    local ok, parsed = pcall(JSON.decode, raw)
    if ok and type(parsed) == "table" and type(parsed.jobs) == "table" then
        _q.paused  = parsed.paused and true or false
        _q.next_id = tonumber(parsed.next_id) or 1
        for _, j in ipairs(parsed.jobs) do
            if type(j) == "table" and j.source_id and j.novel_path then
                j.chapters = type(j.chapters) == "table" and j.chapters or {}
                j.retry_at = nil
                -- Une tâche interrompue par l'arrêt de KOReader repart à zéro côté état.
                if j.state == "running" or j.state == "waiting_network" then j.state = "queued" end
                _q.jobs[#_q.jobs + 1] = j
            end
        end
    end
    return _q
end

local function save_q()
    if not _q then return end
    _since_save = 0
    pcall(function()
        if lfs.attributes(base_dir, "mode") ~= "directory" then lfs.mkdir(base_dir) end
        local ok, raw = pcall(JSON.encode, { paused = _q.paused, next_id = _q.next_id, jobs = _q.jobs })
        if not ok or type(raw) ~= "string" then return end
        -- Écriture dans un fichier temporaire puis renommage : jamais de file tronquée.
        local tmp = file_path .. ".tmp"
        local f = io.open(tmp, "w")
        if not f then return end
        f:write(raw)
        f:close()
        os.rename(tmp, file_path)
    end)
end

-- ── Évènements (écrans qui veulent suivre la progression) ────────────────────

function Dlq.setListener(name, fn)
    _listeners[name] = fn
end

local function notify(ev, job)
    for _, fn in pairs(_listeners) do pcall(fn, ev, job) end
end

-- ── Utilitaires de tâches ────────────────────────────────────────────────────

local function is_active(j)
    return j.state ~= "done" and j.state ~= "failed"
end

local function runnable(j)
    return is_active(j) and not j.paused and #j.chapters > 0
        and (j.retry_at == nil or j.retry_at <= os.time())
end

local function find_job(source_id, novel_path, kind)
    for _, j in ipairs(load_q().jobs) do
        if j.source_id == source_id and j.novel_path == novel_path
           and j.kind == kind and is_active(j) then
            return j
        end
    end
    return nil
end

local function find_by_id(id)
    for _, j in ipairs(load_q().jobs) do
        if j.id == id then return j end
    end
    return nil
end

local function remove_job(job)
    local q = load_q()
    for i, j in ipairs(q.jobs) do
        if j == job then table.remove(q.jobs, i); return true end
    end
    return false
end

local function prune_done()
    local q = load_q()
    local done = {}
    for _, j in ipairs(q.jobs) do
        if j.state == "done" then done[#done + 1] = j end
    end
    -- les plus anciennes d'abord : on retire l'excédent
    for i = 1, #done - KEEP_DONE do remove_job(done[i]) end
end

local function recount(job)
    job.total = (job.done or 0) + (job.failed or 0) + #job.chapters
end

-- Réseau : jamais de demande d'activation du Wi-Fi ici (la file ne doit pas
-- ouvrir de popup toute seule). `strict` = vrai test de connexion.
local function fast_offline()
    local ok, NM = pcall(require, "ui/network/manager")
    if ok and NM and NM.isConnected then
        local ok2, conn = pcall(NM.isConnected, NM)
        if ok2 and conn == false then return true end
    end
    return false
end

local function network_ok(strict)
    if fast_offline() then return false end
    local ok, Online = pcall(require, "core.online")
    if ok and Online and Online.is_up then
        local ok2, up = pcall(Online.is_up, strict and true or false)
        if ok2 then return up and true or false end
    end
    return true
end

local function pick_job()
    local q = load_q()
    for _, j in ipairs(q.jobs) do
        if runnable(j) and j.kind == "auto" then return j end
    end
    for _, j in ipairs(q.jobs) do
        if runnable(j) then return j end
    end
    return nil
end

-- ── Planification ────────────────────────────────────────────────────────────

local _sched_fn, _sched_at = nil, nil

-- Un seul réveil à la fois ; une nouvelle demande ne remplace l'ancienne que
-- si elle est plus proche.
schedule = function(delay)
    delay = delay or STEP_GAP
    local at = socket.gettime() + delay
    if _sched_fn then
        if _sched_at and _sched_at <= at then return end
        UIManager:unschedule(_sched_fn)
        _sched_fn = nil
    end
    _sched_at = at
    local fn
    fn = function()
        if _sched_fn == fn then _sched_fn = nil; _sched_at = nil end
        local ok, err = pcall(step)
        if not ok then
            logger.warn("Sefirah/Dlq: erreur :", tostring(err))
            _busy = false
            _cur_job = nil
        end
    end
    _sched_fn = fn
    UIManager:scheduleIn(delay, fn)
end

local function wait_for_network()
    local q = load_q()
    local changed = false
    for _, j in ipairs(q.jobs) do
        if runnable(j) and j.state ~= "waiting_network" then
            j.state = "waiting_network"
            changed = true
        end
    end
    if changed then
        save_q()
        notify("state")
        if not _net_toasted then
            _net_toasted = true
            toast(tr("Réseau perdu : les téléchargements reprendront à la reconnexion."), 3)
        end
    end
    if _net_timer then return end
    _net_timer = true
    UIManager:scheduleIn(NET_RETRY, function()
        _net_timer = false
        schedule(0.5)
    end)
end

-- Prochain réveil quand toutes les tâches sont en attente (blocage d'un site).
local function wake_later()
    local q = load_q()
    local soonest
    for _, j in ipairs(q.jobs) do
        if is_active(j) and not j.paused and #j.chapters > 0 and j.retry_at then
            if not soonest or j.retry_at < soonest then soonest = j.retry_at end
        end
    end
    if soonest then
        schedule(math.max(1, soonest - os.time() + 1))
    end
end

-- ── Fin d'une tranche ────────────────────────────────────────────────────────

local function finish_slice(job, slice, results)
    if job.cancelled then return end   -- annulée pendant la tranche : rien à enregistrer
    local ckey = get_cache().chapterKey
    local n_ok, any_fail = 0, false
    local retry, inslice = {}, {}
    for i, ch in ipairs(slice) do
        inslice[ckey(ch)] = true
        local r = results[i]
        if r and r.ok then
            n_ok = n_ok + 1
        else
            any_fail = true
            retry[#retry + 1] = ch
        end
    end

    -- On retire la tranche par clé (et non par position) : la liste a pu changer
    -- pendant le téléchargement (nouvelle fenêtre « auto », ajout de chapitres).
    local rest = {}
    for _, c in ipairs(job.chapters) do
        if not inslice[ckey(c)] then rest[#rest + 1] = c end
    end

    local prev_done = job.done or 0
    job.done = prev_done + n_ok

    local stalled = false
    if any_fail then
        local online = network_ok(true)
        if not online then
            -- Coupure : on remet les chapitres en tête, sans compter d'essai.
            for i = #retry, 1, -1 do table.insert(rest, 1, retry[i]) end
            job.state = "waiting_network"
        else
            -- Un chapitre n'est abandonné qu'après plusieurs échecs ET soit une tranche
            -- où les autres chapitres ont réussi (le site répond, c'est ce chapitre-là
            -- qui pose problème), soit une pause d'attente déjà passée. Une panne du
            -- site ne vide donc pas la file en quelques secondes.
            local mixed = n_ok > 0
            for _, ch in ipairs(retry) do
                ch.attempts = (ch.attempts or 0) + 1
                if ch.attempts >= MAX_ATTEMPTS and (mixed or (job.stalls or 0) >= 1) then
                    job.failed = (job.failed or 0) + 1
                else
                    rest[#rest + 1] = ch   -- à la fin : les autres chapitres passent d'abord
                end
            end
            if mixed then
                job.streak, job.stalls = 0, 0
            else
                job.streak = (job.streak or 0) + 1
                if job.streak >= STALL_SLICES then
                    -- Le site (ou la connexion) ne répond plus : on laisse souffler.
                    stalled = true
                    job.streak = 0
                    job.stalls = (job.stalls or 0) + 1
                    job.retry_at = os.time() + STALL_RETRY
                end
            end
        end
    else
        job.streak, job.stalls = 0, 0
        _net_toasted = false
    end

    job.chapters = rest
    _since_save = _since_save + n_ok

    if #rest == 0 then
        job.state = "done"
        job.finished_at = os.time()
        job.chapters = {}
        recount(job)
        pcall(function() get_cache().flush() end)
        if job.kind == "auto" then
            remove_job(job)
        else
            prune_done()
            local name = cut(job.novel_name or job.novel_path, 30)
            if (job.failed or 0) > 0 then
                toast(string.format(tr("%s : terminé, %d chapitre(s) en échec."), name, job.failed), 4)
            else
                toast(string.format(tr("Téléchargement terminé : %s"), name), 3)
            end
        end
        save_q()
        notify("job_done", job)
    else
        if job.state == "running" then job.state = "queued" end
        recount(job)
        if stalled and (job.stalls or 0) >= MAX_STALLS then
            -- Plusieurs blocages de suite : on s'arrête là, l'utilisateur relancera.
            job.state = "failed"
            job.error = "stalled"
            job.retry_at = nil
            if job.kind == "auto" then remove_job(job) end
            toast(string.format(tr("%s : téléchargement bloqué. Réessaie depuis la file d'attente."),
                cut(job.novel_name or job.novel_path, 24)), 4)
            save_q()
            notify("state", job)
        elseif stalled then
            toast(string.format(tr("%s : le site ne répond pas, nouvel essai dans quelques minutes."),
                cut(job.novel_name or job.novel_path, 24)), 4)
            save_q()
            notify("state", job)
        elseif _since_save >= SAVE_EVERY or job.state == "waiting_network" then
            save_q()
        end
        if job.kind == "manual"
           and math.floor(job.done / TOAST_EVERY) > math.floor(prev_done / TOAST_EVERY) then
            toast(string.format(tr("Téléchargement : %s — %d/%d"),
                cut(job.novel_name or job.novel_path, 24), job.done, job.total), 2)
        end
        -- Un évènement de progression tous les 10 chapitres (la fiche se redessine à ce rythme).
        local last = _last_event[job] or 0
        if math.floor(job.done / 10) > math.floor(last / 10) then
            _last_event[job] = job.done
            notify("progress", job)
        end
    end
end

-- ── Boucle principale ────────────────────────────────────────────────────────

step = function()
    if _busy then return end
    local q = load_q()
    if q.paused then return end

    local job = pick_job()
    if not job then
        wake_later()
        return
    end

    if not network_ok(false) then
        wait_for_network()
        return
    end

    local ok_e, ExtMgr = pcall(require, "core.extmgr")
    local ext = ok_e and ExtMgr.get(job.source_id) or nil
    if not ext then
        -- Source introuvable (désinstallée ?) : cette tâche est mise de côté.
        job.state = "failed"
        job.error = "source_unavailable"
        save_q()
        notify("state", job)
        return schedule(STEP_GAP)
    end

    -- Taille de la tranche : en parallèle, deux « vagues » ; sinon quelques chapitres
    -- d'affilée (l'interface reprend la main entre chaque chapitre).
    local width = 1
    local Cache = get_cache()
    local ok_w, w = pcall(Cache.parallelWidth, job.source_id)
    if ok_w and tonumber(w) then width = tonumber(w) end
    local ok_p, Parallel = pcall(require, "core.parallel")
    if setting("offline_comments") or not ok_p or not Parallel.available() then width = 1 end
    local n = (width > 1) and (width * 2) or 4
    n = math.min(n, #job.chapters)

    local slice = {}
    for i = 1, n do slice[i] = job.chapters[i] end

    _busy = true
    _cur_job = job
    _token = _token + 1
    local my_token = _token
    local results, finished = {}, false
    job.state = "running"
    if _last_event[job] == nil then _last_event[job] = job.done or 0 end

    local function done_cb()
        if finished then return end
        finished = true
        local ok, err = pcall(finish_slice, job, slice, results)
        if not ok then logger.warn("Sefirah/Dlq: fin de tranche :", tostring(err)) end
        _busy = false
        _cur_job = nil
        schedule(STEP_GAP)
    end

    -- Garde-fou : une tranche qui ne revient jamais ne doit pas bloquer la file.
    UIManager:scheduleIn(SLICE_WATCHDOG, function()
        if _busy and _token == my_token then
            logger.warn("Sefirah/Dlq: tranche bloquée, on continue")
            done_cb()
        end
    end)

    local ok_call, call_err = pcall(Cache.downloadChapters, ext, job.source_id, job.novel_path, slice,
        function(done, _total, ok, err)
            results[done] = { ok = ok and true or false, err = err }
        end,
        done_cb)
    if not ok_call then
        logger.warn("Sefirah/Dlq: downloadChapters :", tostring(call_err))
        done_cb()
    end
end

-- ── API publique : ajout ─────────────────────────────────────────────────────

-- Ajoute des chapitres à la file.
--   opts.kind   "manual" (défaut) ou "auto" (chapitres d'avance)
--   opts.force  re-télécharge même ce qui est déjà en cache
--   opts.silent pas de notification de confirmation
-- Renvoie : ajoutés, déjà téléchargés, verrouillés, déjà dans la file.
function Dlq.enqueue(source_id, novel_path, novel_name, chapters, opts)
    opts = opts or {}
    novel_path = novel_path or ""
    local q     = load_q()
    local Cache = get_cache()
    local ckey  = Cache.chapterKey
    local kind  = opts.kind or "manual"

    local job = find_job(source_id, novel_path, kind)
    local present = {}
    if job then
        for _, c in ipairs(job.chapters) do present[ckey(c)] = true end
    end

    local list = {}
    local added, cached, locked, dup = 0, 0, 0, 0
    for _, ch in ipairs(chapters or {}) do
        local key = ckey(ch)
        if ch.locked == true then
            locked = locked + 1
        elseif not ref_of(ch) then
            -- chapitre sans adresse : rien à télécharger
        elseif present[key] then
            dup = dup + 1
        elseif not opts.force and Cache.isChapterCached(source_id, novel_path, key) then
            cached = cached + 1
        else
            present[key] = true
            list[#list + 1] = compact(ch)
            added = added + 1
        end
    end

    if added == 0 then
        if not opts.silent then
            toast(tr("Rien à télécharger : tout est déjà sur la liseuse."), 2, true)
        end
        return 0, cached, locked, dup
    end

    if not job then
        job = {
            id = q.next_id, source_id = source_id, novel_path = novel_path,
            novel_name = novel_name or novel_path, kind = kind, state = "queued",
            done = 0, failed = 0, total = 0, chapters = {}, created_at = os.time(),
        }
        q.next_id = q.next_id + 1
        q.jobs[#q.jobs + 1] = job
    elseif novel_name and novel_name ~= "" then
        job.novel_name = novel_name
    end
    for _, c in ipairs(list) do job.chapters[#job.chapters + 1] = c end
    job.retry_at = nil
    recount(job)
    save_q()
    notify("enqueued", job)

    if not opts.silent then
        local msg = string.format(tr("%d chapitre(s) ajouté(s) à la file d'attente."), added)
        if q.paused then msg = msg .. " " .. tr("(file en pause)") end
        toast(msg, 2, true)
    end
    if not q.paused then schedule(0.8) end
    return added, cached, locked, dup
end

-- Chapitres d'avance pendant la lecture : garde les N prochains chapitres
-- téléchargés. Appelé à chaque ouverture de chapitre (ui/readerview.lua).
-- Hors ligne, ne fait rien (et ne demande jamais d'allumer le Wi-Fi).
function Dlq.prefetchAhead(ctx)
    if type(ctx) ~= "table" or type(ctx.chapters) ~= "table" or not ctx.novel then return end
    local n = tonumber(setting("dl_ahead"))
    if n == nil then n = 3 end
    if n <= 0 then return end
    if fast_offline() then return end

    local step_dir = ctx.step or 1
    if step_dir == 0 then step_dir = 1 end
    local idx = ctx.index or 1
    local list = {}
    for k = 1, n do
        local ch = ctx.chapters[idx + k * step_dir]
        if not ch then break end
        list[#list + 1] = ch
    end
    if #list == 0 then return end

    local path = ctx.novel.path or ""

    -- La nouvelle fenêtre remplace l'ancienne : si le lecteur a sauté plusieurs
    -- chapitres, on ne télécharge pas ceux qu'il a laissés derrière lui.
    local old = find_job(ctx.source_id, path, "auto")
    if old then
        old.chapters = {}
        recount(old)
    end

    Dlq.enqueue(ctx.source_id, path, ctx.novel.title or ctx.novel.name or path, list,
        { kind = "auto", silent = true })

    -- Tâche vide (tout est déjà en cache) : on ne la laisse pas traîner.
    local job = find_job(ctx.source_id, path, "auto")
    if job and #job.chapters == 0 and job ~= _cur_job then remove_job(job) end
end

-- ── API publique : contrôle ──────────────────────────────────────────────────

function Dlq.jobs()
    local out = {}
    for _, j in ipairs(load_q().jobs) do out[#out + 1] = j end
    return out
end

-- Nombre de tâches pas encore terminées (avec des chapitres à télécharger).
function Dlq.count()
    local n = 0
    for _, j in ipairs(load_q().jobs) do
        if is_active(j) and #j.chapters > 0 then n = n + 1 end
    end
    return n
end

function Dlq.pendingChapters()
    local n = 0
    for _, j in ipairs(load_q().jobs) do
        if is_active(j) then n = n + #j.chapters end
    end
    return n
end

function Dlq.isPaused() return load_q().paused and true or false end

-- Code d'état à afficher : running, queued, paused, waiting, stalled, done, failed.
function Dlq.stateOf(job)
    if job.state == "done" then return "done" end
    if job.state == "failed" then return "failed" end
    if load_q().paused or job.paused then return "paused" end
    if job.state == "waiting_network" then return "waiting" end
    if job.retry_at and job.retry_at > os.time() then return "stalled" end
    if job.state == "running" then return "running" end
    return "queued"
end

function Dlq.pauseAll()
    load_q().paused = true
    save_q()
    notify("state")
end

function Dlq.resumeAll()
    local q = load_q()
    q.paused = false
    for _, j in ipairs(q.jobs) do
        j.retry_at = nil
        if j.state == "waiting_network" then j.state = "queued" end
    end
    save_q()
    notify("state")
    schedule(0.3)
end

function Dlq.pauseJob(id, paused)
    local j = find_by_id(id)
    if not j then return end
    j.paused = paused and true or nil
    if not paused then j.retry_at = nil end
    save_q()
    notify("state", j)
    if not paused and not load_q().paused then schedule(0.3) end
end

function Dlq.moveFirst(id)
    local j = find_by_id(id)
    if not j then return end
    remove_job(j)
    table.insert(load_q().jobs, 1, j)
    save_q()
    notify("state", j)
end

-- Relance une tâche en échec (ou bloquée) : les compteurs d'essais repartent à zéro.
function Dlq.retryJob(id)
    local j = find_by_id(id)
    if not j then return end
    if j.state == "failed" then j.state = "queued"; j.error = nil end
    j.retry_at = nil
    j.streak, j.stalls = 0, 0
    for _, c in ipairs(j.chapters) do c.attempts = nil end
    save_q()
    notify("state", j)
    if not load_q().paused then schedule(0.3) end
end

-- Annule une tâche : les chapitres déjà téléchargés restent sur la liseuse.
function Dlq.cancelJob(id)
    local j = find_by_id(id)
    if not j then return end
    j.cancelled = true
    j.chapters = {}
    remove_job(j)
    save_q()
    notify("state", j)
end

function Dlq.clearDone()
    local q = load_q()
    local keep = {}
    for _, j in ipairs(q.jobs) do
        if j.state ~= "done" then keep[#keep + 1] = j end
    end
    q.jobs = keep
    save_q()
    notify("state")
end

-- ── Démarrage / reconnexion ──────────────────────────────────────────────────

-- Appelé une fois par session KOReader (Sefirah:init) : reprend une file
-- laissée en route par la session précédente.
function Dlq.init()
    if _G.__sefirah_dlq_started then return end
    _G.__sefirah_dlq_started = true
    local q = load_q()
    if q.paused or setting("dl_autoresume") == false then return end
    for _, j in ipairs(q.jobs) do
        if runnable(j) then schedule(INIT_DELAY); return end
    end
end

-- Appelé par Sefirah:onNetworkConnected : reprise automatique.
function Dlq.onNetworkConnected()
    local q = load_q()
    if q.paused or setting("dl_autoresume") == false then return end
    local now = os.time()
    if _last_connect and now - _last_connect >= 0 and now - _last_connect < 15 then return end
    _last_connect = now

    local any, was_waiting = false, false
    for _, j in ipairs(q.jobs) do
        if is_active(j) and #j.chapters > 0 and not j.paused then
            any = true
            if j.state == "waiting_network" then
                was_waiting = true
                j.state = "queued"
            end
            j.retry_at = nil
        end
    end
    if not any then return end
    _net_toasted = false
    if was_waiting then
        save_q()
        notify("state")
        toast(tr("Connexion retrouvée : reprise des téléchargements."), 3)
    end
    schedule(CONNECT_DELAY)
end

return Dlq
