-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- Coquille d'onglets : suit l'onglet actif et le panneau principal persistant.
-- Quatre niveaux de navigation :
--   _panel  — onglet principal (Bibliothèque / Parcourir / Sources / Paramètres) — reste actif entre les reconstructions
--   _detail — sous-écran détails/réglages affiché au-dessus du panneau d'onglet
--   _export — sous-écran d'export affiché au-dessus du panneau détails
--   _reader — vue lecteur intégrée, affichée au-dessus du panneau détails (mutuellement
--             exclusive avec _export — ouvrir l'un ferme l'autre)
-- Chaque niveau s'affiche sans fermer celui du dessous, donc fermer un niveau
-- révèle automatiquement ce qui était en dessous via UIManager.
local UIManager = require("ui/uimanager")

local SefirahUI = {}

SefirahUI.active_tab = "library"

-- Rempli par main.lua — chacun renvoie (rows, title, nav) pour son onglet
SefirahUI.get_library_rows = nil
SefirahUI.get_browse_rows  = nil
SefirahUI.get_sources_rows = nil
SefirahUI.get_settings_rows = nil

local _panel  = nil  -- niveau 1 : panneau d'onglet principal (persistant)
local _detail = nil  -- niveau 2 : sous-écran détails / réglages de source
local _export = nil  -- niveau 3a : sous-écran d'export
local _reader = nil  -- niveau 3b : vue lecteur (exclusive avec _export)

local function close_reader()
    if not _reader then return end
    local ok, ReaderView = pcall(require, "ui.readerview")
    if ok and ReaderView and ReaderView.close then
        ReaderView.close()
    else
        UIManager:close(_reader)
        _reader = nil
    end
end

local function close_fn()
    if _G.sefirah_close_all then _G.sefirah_close_all() end
end

-- ── Niveau 1 : onglet principal ───────────────────────────────────────────────

function SefirahUI.show(tab)
    pcall(function() require("core.quests").touch() end)
    if _reader then close_reader() end
    if _export then UIManager:close(_export); _export = nil end
    if _detail then UIManager:close(_detail); _detail = nil end

    local same_tab = _panel ~= nil and SefirahUI.active_tab == (tab or "library")
    SefirahUI.active_tab = tab or "library"

    local rows, title, nav, actions
    if SefirahUI.active_tab == "library" and SefirahUI.get_library_rows then
        rows, title, nav, actions = SefirahUI.get_library_rows()
    elseif SefirahUI.active_tab == "browse" and SefirahUI.get_browse_rows then
        rows, title, nav, actions = SefirahUI.get_browse_rows()
    elseif SefirahUI.active_tab == "sources" and SefirahUI.get_sources_rows then
        rows, title, nav, actions = SefirahUI.get_sources_rows()
    elseif SefirahUI.active_tab == "settings" and SefirahUI.get_settings_rows then
        rows, title, nav, actions = SefirahUI.get_settings_rows()
    end

    if not rows then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text    = T("Onglet non prêt : ") .. tostring(SefirahUI.active_tab),
            timeout = 2,
        })
        return
    end

    local P = require("ui.panel")
    if _panel then
        _panel:swapBody(P.buildTabBody(SefirahUI.active_tab, rows, title, close_fn, nav, actions), close_fn, same_tab, nav)
    else
        _panel = P.showTabPanel(SefirahUI.active_tab, rows, title, close_fn, nav, actions)
    end
end

-- ── Niveau 2 : panneau détails ────────────────────────────────────────────────

function SefirahUI.setDetail(widget)
    if _reader then close_reader() end
    if _export then UIManager:close(_export); _export = nil end
    if _detail then UIManager:close(_detail) end
    _detail = widget
end

function SefirahUI.clearDetail()
    if _reader then close_reader() end
    if _export then UIManager:close(_export); _export = nil end
    _detail = nil
end

-- ── Niveau 3a : panneau d'export ───────────────────────────────────────────────

function SefirahUI.setExport(widget)
    if _reader then close_reader() end
    if _export then UIManager:close(_export) end
    _export = widget
end

function SefirahUI.clearExport()
    _export = nil
end

-- ── Niveau 3b : panneau lecteur ───────────────────────────────────────────────
-- Mutuellement exclusif avec l'export — ouvrir le lecteur ferme tout export
-- ouvert et vice-versa (les deux révèlent _detail à la fermeture).

function SefirahUI.setReader(widget)
    if _export then UIManager:close(_export); _export = nil end
    if _reader and _reader ~= widget then UIManager:close(_reader) end
    _reader = widget
end

function SefirahUI.clearReader()
    _reader = nil
end

-- Vrai si le lecteur ou l'export est affiché au-dessus de la fiche : reconstruire
-- la fiche à ce moment-là fermerait le lecteur (cf. setDetail).
function SefirahUI.isOverlayOpen()
    return _reader ~= nil or _export ~= nil
end

-- ── Alias historiques ─────────────────────────────────────────────────────────

-- ── Tout fermer ───────────────────────────────────────────────────────────────

function SefirahUI.close()
    pcall(function() require("settings").flushNow() end)
    pcall(function() require("core.db").flush() end)
    pcall(function() require("core.cache").flush() end)
    -- IMPORTANT : Detail garde son propre pointeur vers le FullScreenPanel et
    -- des callbacks réseau d'Avis. Fermer uniquement le widget ici laisse
    -- un panneau mort en mémoire ; au prochain lancement le tap Bibliothèque
    -- peut alors cibler cet ancien panneau. On demande donc d'abord à Detail
    -- d'invalider tous ses callbacks et de remettre son état à zéro.
    local ok, Detail = pcall(require, "ui.detail")
    if ok and Detail and Detail.shutdown then
        pcall(Detail.shutdown)
    end
    if _reader then close_reader() end
    if _export then UIManager:close(_export); _export = nil end
    if _detail then UIManager:close(_detail); _detail = nil end
    if _panel  then UIManager:close(_panel);  _panel  = nil end
    -- Rend à KOReader son propre réglage de mode nuit.
    pcall(function() require("core.night").restore() end)
end

return SefirahUI
