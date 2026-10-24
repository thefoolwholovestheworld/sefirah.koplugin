-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- ui/downloads.lua — fenêtre « File d'attente de téléchargement » (core/dlqueue.lua).
-- Liste les tâches avec leur progression ; toucher une ligne ouvre ses actions
-- (pause, passer en premier, réessayer, annuler). « Actualiser » redessine la liste.
local T = require("core.i18n").T

local UIManager         = require("ui/uimanager")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")

local Downloads = {}
local _dlg  = nil
local _menu = nil

local MAX_ROWS = 8

local function close_all_dialogs()
    if _dlg  then UIManager:close(_dlg);  _dlg  = nil end
    if _menu then UIManager:close(_menu); _menu = nil end
end

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

local function state_label(code)
    if code == "running" then return T("en cours") end
    if code == "queued"  then return T("en attente") end
    if code == "paused"  then return T("en pause") end
    if code == "waiting" then return T("attente du réseau") end
    if code == "stalled" then return T("site injoignable, nouvel essai bientôt") end
    if code == "done"    then return T("terminé") end
    if code == "failed"  then return T("bloqué") end
    return ""
end

local function job_text(Dlq, j)
    local code = Dlq.stateOf(j)
    local total = tonumber(j.total) or 0
    local done  = tonumber(j.done) or 0
    local pct   = total > 0 and math.floor(done * 100 / total) or 0
    local prefix = (j.kind == "auto") and (T("Lecture") .. " · ") or ""
    local line = string.format("%s%s — %d/%d (%d %%) · %s",
        prefix, cut(j.novel_name or j.novel_path, 22), done, total, pct, state_label(code))
    if (j.failed or 0) > 0 then
        line = line .. string.format(" · %d %s", j.failed, T("échec(s)"))
    end
    return line
end

local function job_menu(j)
    local Dlq = require("core.dlqueue")
    if _menu then UIManager:close(_menu); _menu = nil end
    local code = Dlq.stateOf(j)
    local rows = {}

    if code ~= "done" then
        if j.paused then
            rows[#rows + 1] = {{ text = T("Reprendre"), callback = function()
                UIManager:close(_menu); _menu = nil
                Dlq.pauseJob(j.id, false)
                Downloads.show()
            end }}
        else
            rows[#rows + 1] = {{ text = T("Mettre en pause"), callback = function()
                UIManager:close(_menu); _menu = nil
                Dlq.pauseJob(j.id, true)
                Downloads.show()
            end }}
        end
        rows[#rows + 1] = {{ text = T("Passer en premier"), callback = function()
            UIManager:close(_menu); _menu = nil
            Dlq.moveFirst(j.id)
            Downloads.show()
        end }}
    end
    if code == "failed" or code == "stalled" or code == "waiting" then
        rows[#rows + 1] = {{ text = T("Réessayer maintenant"), callback = function()
            UIManager:close(_menu); _menu = nil
            Dlq.retryJob(j.id)
            Downloads.show()
        end }}
    end
    rows[#rows + 1] = {{ text = code == "done" and T("Retirer de la liste") or T("Annuler le téléchargement"),
        callback = function()
            UIManager:close(_menu); _menu = nil
            Dlq.cancelJob(j.id)
            Downloads.show()
        end }}
    rows[#rows + 1] = {{ text = T("Retour"), callback = function()
        UIManager:close(_menu); _menu = nil
        Downloads.show()
    end }}

    _menu = ButtonDialogTitle:new{ title = cut(j.novel_name or j.novel_path, 40), buttons = rows }
    UIManager:show(_menu)
end

function Downloads.show()
    local Dlq = require("core.dlqueue")
    close_all_dialogs()

    local jobs = Dlq.jobs()
    local rows = {}
    local shown = 0
    for _, j in ipairs(jobs) do
        if shown >= MAX_ROWS then break end
        shown = shown + 1
        local job = j
        rows[#rows + 1] = {{ text = job_text(Dlq, job), callback = function()
            job_menu(job)
        end }}
    end
    if #jobs == 0 then
        rows[#rows + 1] = {{ text = T("Aucun téléchargement en cours."), enabled = false, callback = function() end }}
    elseif #jobs > shown then
        rows[#rows + 1] = {{ text = string.format("… +%d", #jobs - shown), enabled = false, callback = function() end }}
    end

    local paused = Dlq.isPaused()
    rows[#rows + 1] = {
        { text = paused and T("Reprendre tout") or T("Tout mettre en pause"), callback = function()
            if paused then Dlq.resumeAll() else Dlq.pauseAll() end
            Downloads.show()
        end },
        { text = T("Actualiser"), callback = function() Downloads.show() end },
    }
    rows[#rows + 1] = {
        { text = T("Vider les terminés"), callback = function()
            Dlq.clearDone()
            Downloads.show()
        end },
        { text = T("Fermer"), callback = function() close_all_dialogs() end },
    }

    local pending = Dlq.pendingChapters()
    local title = T("File d'attente de téléchargement")
    if pending > 0 then
        title = title .. string.format(" — %d %s", pending, T("chapitre(s) restant(s)"))
    end
    if paused then title = title .. " · " .. T("en pause") end

    _dlg = ButtonDialogTitle:new{ title = title, buttons = rows }
    UIManager:show(_dlg)
end

return Downloads
