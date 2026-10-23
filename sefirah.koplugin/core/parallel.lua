-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- core/parallel.lua — exécute plusieurs téléchargements EN MÊME TEMPS, chacun dans
-- son propre sous-processus (ffi/util.runInSubProcess, comme le fait KOReader).
--
-- Pourquoi : sur une liseuse, chaque connexion HTTPS coûte plusieurs secondes de
-- latence (DNS + TLS), même pour une petite image. 6 couvertures l'une après
-- l'autre = 6 × la latence ; en parallèle = environ 1 × la latence.
-- Chaque tâche écrit directement son résultat sur disque (cache), le processus
-- principal n'a plus qu'à relire les fichiers.
local socket = require("socket")

local Parallel = {}

-- Nombre de sous-processus de Parallel.pool en cours, tous pools confondus.
-- Permet à plusieurs pools (ex. deux chapitres de manga qui se chevauchent)
-- de partager un plafond global : on ne dépasse jamais `opts.global_cap`.
local _active = 0

local function ffiutil()
    local ok, u = pcall(require, "ffi/util")
    if ok and type(u) == "table"
       and type(u.runInSubProcess) == "function"
       and type(u.isSubProcessDone) == "function" then
        return u
    end
    return nil
end

function Parallel.available()
    return ffiutil() ~= nil
end

local function spawn(jobs)
    local u = ffiutil()
    if not u then return nil end
    local pids = {}
    for _, job in ipairs(jobs) do
        local ok, pid = pcall(u.runInSubProcess, function() _G.__sefirah_in_child = true; pcall(job) end)
        if ok and pid then pids[#pids + 1] = pid end
    end
    return pids, u
end

local function kill_and_reap(pids, u)
    for _, pid in ipairs(pids) do pcall(u.terminateSubProcess, pid) end
    -- Les processus terminés doivent être « récoltés » pour ne pas rester zombies.
    local UIManager = require("ui/uimanager")
    local left = pids
    local function reap()
        local still = {}
        for _, pid in ipairs(left) do
            local ok, done = pcall(u.isSubProcessDone, pid)
            if ok and not done then still[#still + 1] = pid end
        end
        left = still
        if #left > 0 then UIManager:scheduleIn(1, reap) end
    end
    UIManager:scheduleIn(1, reap)
end

-- Asynchrone (l'interface reste utilisable) : on_done() est appelé quand toutes les
-- tâches sont finies, ou après `timeout` secondes (les retardataires sont arrêtées).
-- Renvoie false si le parallélisme n'est pas disponible (l'appelant se replie alors
-- sur le téléchargement séquentiel) ; on_done n'est alors PAS appelé.
function Parallel.run(jobs, on_done, timeout)
    if #jobs == 0 then return false end
    local pids, u = spawn(jobs)
    if not pids or #pids == 0 then return false end
    local UIManager = require("ui/uimanager")
    local t0 = socket.gettime()
    timeout = timeout or 25
    local function poll()
        local alive = {}
        for _, pid in ipairs(pids) do
            local ok, done = pcall(u.isSubProcessDone, pid)
            if ok and not done then alive[#alive + 1] = pid end
        end
        pids = alive
        if #pids == 0 then return on_done() end
        if socket.gettime() - t0 > timeout then
            kill_and_reap(pids, u)
            return on_done()
        end
        UIManager:scheduleIn(0.4, poll)
    end
    UIManager:scheduleIn(0.4, poll)
    return true
end

-- Fenêtre glissante : garde `width` tâches en cours en permanence et en relance une
-- dès qu'une se termine (au lieu d'attendre la plus lente d'une « vague » entière).
-- Asynchrone. on_done(aborted) à la fin (aborted = true si is_cancelled() a coupé).
-- opts : on_progress(n_terminées, total), is_cancelled(), job_timeout (déf. 60 s,
--        la tâche trop lente est arrêtée), timeout (global, déf. 600 s),
--        global_cap (plafond de sous-processus tous pools confondus),
--        on_tick() (appelé à chaque cycle de surveillance, ~0,15 s),
--        on_all_launched() (appelé UNE fois quand la dernière tâche vient d'être
--        lancée : permet de démarrer le travail suivant pendant la « queue »).
-- Renvoie false si le parallélisme est indisponible (on_done n'est alors PAS appelé).
function Parallel.pool(jobs, width, on_done, opts)
    opts = opts or {}
    if #jobs == 0 then return false end
    local u = ffiutil()
    if not u then return false end
    local UIManager = require("ui/uimanager")
    width = math.max(1, width or 6)
    local job_timeout   = opts.job_timeout or 60
    local total_timeout = opts.timeout or 600
    local t0 = socket.gettime()
    local nxt, done_n, running, finished = 1, 0, {}, false
    local tail_called = false
    local cap = opts.global_cap

    local function finish(aborted)
        if finished then return end
        finished = true
        local pids = {}
        for _, r in ipairs(running) do pids[#pids + 1] = r.pid end
        _active = math.max(0, _active - #running)
        running = {}
        if #pids > 0 then kill_and_reap(pids, u) end
        on_done(aborted and true or false)
    end

    local function launch()
        while #running < width and nxt <= #jobs and (not cap or _active < cap or #running == 0) do
            local job = jobs[nxt]
            nxt = nxt + 1
            local ok, pid = pcall(u.runInSubProcess, function() _G.__sefirah_in_child = true; pcall(job) end)
            if ok and pid then
                running[#running + 1] = { pid = pid, t = socket.gettime() }
                _active = _active + 1
            else
                done_n = done_n + 1   -- impossible à lancer : l'appelant gère le manque
            end
        end
        if nxt > #jobs and not tail_called then
            tail_called = true
            if opts.on_all_launched then pcall(opts.on_all_launched) end
        end
    end

    launch()
    if #running == 0 then return false end

    local function poll()
        if finished then return end
        if opts.is_cancelled and opts.is_cancelled() then return finish(true) end
        local now, alive, before = socket.gettime(), {}, done_n
        for _, r in ipairs(running) do
            local ok, done = pcall(u.isSubProcessDone, r.pid)
            if ok and not done then
                if now - r.t > job_timeout then
                    kill_and_reap({ r.pid }, u)
                    done_n = done_n + 1
                    _active = math.max(0, _active - 1)
                else
                    alive[#alive + 1] = r
                end
            else
                done_n = done_n + 1
                _active = math.max(0, _active - 1)
            end
        end
        running = alive
        launch()
        if opts.on_tick then pcall(opts.on_tick) end
        if done_n ~= before and opts.on_progress then
            pcall(opts.on_progress, math.min(done_n, #jobs), #jobs)
        end
        if #running == 0 and nxt > #jobs then return finish(false) end
        if now - t0 > total_timeout then return finish(false) end
        UIManager:scheduleIn(0.15, poll)
    end
    UIManager:scheduleIn(0.15, poll)
    return true
end

-- Synchrone : bloque jusqu'à la fin de toutes les tâches (ou `timeout`), mais elles
-- tournent en parallèle. Renvoie false si indisponible.
function Parallel.runAndWait(jobs, timeout)
    if #jobs == 0 then return true end
    local pids, u = spawn(jobs)
    if not pids or #pids == 0 then return false end
    local t0 = socket.gettime()
    timeout = timeout or 20
    while #pids > 0 do
        local alive = {}
        for _, pid in ipairs(pids) do
            local ok, done = pcall(u.isSubProcessDone, pid)
            if ok and not done then alive[#alive + 1] = pid end
        end
        pids = alive
        if #pids == 0 then break end
        if socket.gettime() - t0 > timeout then
            kill_and_reap(pids, u)
            break
        end
        socket.sleep(0.1)
    end
    return true
end

return Parallel
