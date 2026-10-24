-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- Sefirah — point d'entrée principal du plugin.
_G.SEFIRAH_VERSION = "1.4"

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")

local plugin_dir = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]+$") or "."
package.path = plugin_dir .. "/?.lua;"
    .. plugin_dir .. "/?/init.lua;"
    .. package.path

local T = require("core.i18n").T

-- Aide à tout fermer : ferme tous les widgets Sefirah
local function close_all()
    local SefirahUI = package.loaded["ui.main_widget"]
    if SefirahUI then pcall(SefirahUI.close) end
end
_G.sefirah_close_all = close_all

-- Dossier du plugin et contrôle d'installation : une copie interrompue (USB
-- débranché trop tôt, dossier copié pendant que KOReader tourne) laisse des
-- fichiers manquants ; sans ce contrôle KOReader affiche seulement
-- « loop or previous error loading module » aux ouvertures suivantes.
local _main_dir = (debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+%.lua$") or "."
local REQUIRED_FILES = {
    "settings.lua",
    "core/i18n.lua", "core/db.lua", "core/cache.lua", "core/covers.lua", "core/epub.lua",
    "core/avatars.lua", "core/extmgr.lua", "core/net.lua", "core/online.lua", "core/http.lua", "core/newch.lua",
    "core/manga.lua", "core/parallel.lua", "core/dlqueue.lua", "core/stats.lua", "core/quests.lua", "core/night.lua", "core/translate.lua", "core/emoji.lua",
    "ui/main_widget.lua", "ui/library.lua", "ui/browse.lua", "ui/detail.lua", "ui/sources.lua",
    "ui/panel.lua", "ui/mangaopen.lua", "ui/export.lua", "ui/readerview.lua", "ui/imagereader.lua",
    "ui/settings_dialog.lua", "ui/newch_popups.lua", "ui/lang_filter.lua", "ui/translate_lang.lua", "ui/downloads.lua", "ui/progress.lua", "ui/pdp.lua", "core/imagesearch.lua",
    "ui/friends.lua", "core/leaderboard.lua", "core/dnsbypass.lua",
}

local function missing_files()
    local missing = {}
    for _, rel in ipairs(REQUIRED_FILES) do
        local f = io.open(_main_dir .. "/" .. rel, "rb")
        if f then
            local head = f:read(1)
            f:close()
            if not head then missing[#missing + 1] = rel .. " (vide)" end
        else
            missing[#missing + 1] = rel
        end
    end
    return missing
end

-- Après un échec de chargement, LuaJIT garde un marqueur dans package.loaded et
-- répond « loop or previous error » à chaque essai suivant : on l'efface pour
-- que la prochaine ouverture refasse un vrai chargement (et montre la vraie erreur).
local function forget_failed_modules()
    for name, mod in pairs(package.loaded) do
        if type(name) == "string" and type(mod) ~= "table" and type(mod) ~= "function"
            and (name:match("^ui%.") or name:match("^core%.") or name == "settings") then
            package.loaded[name] = nil
        end
    end
end

local _ready = false

local function open_sefirah()
    local missing = missing_files()
    if #missing > 0 then
        forget_failed_modules()
        local shown = {}
        for i = 1, math.min(#missing, 4) do shown[#shown + 1] = missing[i] end
        UIManager:show(require("ui/widget/infomessage"):new{
            text = T("Installation de Sefirah incomplète. Fichier(s) manquant(s) :\n")
                .. table.concat(shown, "\n")
                .. (#missing > 4 and ("\n… (+" .. (#missing - 4) .. ")") or "")
                .. "\n" .. T("Recopie le dossier sefirah.koplugin complet (KOReader fermé)."),
            timeout = 10,
        })
        return
    end
    local ok, err = xpcall(function()
        local SefirahUI = require("ui.main_widget")
        local Library  = require("ui.library")
        local Browse   = require("ui.browse")
        local Detail   = require("ui.detail")
        local Sources  = require("ui.sources")
        local ExtMgr   = require("core.extmgr")

        if not _ready then
            ExtMgr.init()

            -- Câblage des générateurs de lignes des onglets
            SefirahUI.get_library_rows = function() return Library.build_rows() end
            SefirahUI.get_browse_rows  = function() return Browse.build_rows()  end
            SefirahUI.get_sources_rows = function() return Sources.build_rows() end
            SefirahUI.get_settings_rows = function() return require("ui.settings_dialog").build_rows() end

            -- Bibliothèque : taper sur un roman ouvre Detail au-dessus du panneau bibliothèque
            Library.on_novel_tap = function(novel)
                SefirahUI.active_tab = "library"
                Detail.on_back = nil  -- le panneau d'onglet reste actif ; fermer detail le révèle
                Detail.fetch(novel.source_id, novel.path)
            end

            -- Parcourir : taper sur un roman ouvre Detail au-dessus du panneau de parcours
            Browse.on_novel_tap = function(source_id, novel_meta)
                SefirahUI.active_tab = "browse"
                Detail.on_back = nil
                Detail.fetch(source_id, novel_meta.path or novel_meta.sourceUrl or "")
            end

            _ready = true
        end

        pcall(function() require("core.night").apply() end)
        SefirahUI.show("library")

        -- Romans déjà en favoris : propose les alertes « nouveau chapitre ».
        pcall(function() require("core.newch").askForExisting() end)
    end, function(e) return tostring(e) .. "\n" .. (debug.traceback("", 2) or "") end)

    if not ok then
        forget_failed_modules()
        _ready = false
        -- La vraie erreur est écrite dans crash.log ET dans sefirah/last_open_error.txt
        -- (dossier des réglages de KOReader) : l'écran n'en montre que la première ligne.
        pcall(function() require("logger").err("Sefirah " .. _G.SEFIRAH_VERSION .. ": ouverture échouée", err) end)
        pcall(function()
            local dir = require("datastorage"):getSettingsDir() .. "/sefirah"
            pcall(function() require("libs/libkoreader-lfs").mkdir(dir) end)
            local f = io.open(dir .. "/last_open_error.txt", "wb")
            if f then f:write("Sefirah ", _G.SEFIRAH_VERSION, "\n\n", tostring(err)); f:close() end
        end)
        UIManager:show(require("ui/widget/infomessage"):new{
            text    = T("Échec de l'ouverture de Sefirah (v") .. _G.SEFIRAH_VERSION .. "):\n"
                .. tostring(err):match("^[^\n]*"),
            timeout = 6,
        })
    end
end

-- Ouvre la fiche d'un roman (utilisé par le popup « nouveau chapitre »).
-- force = true : recharge la liste des chapitres depuis le réseau.
_G.sefirah_open_novel = function(source_id, path, force, snap)
    open_sefirah()
    pcall(function()
        local SefirahUI = require("ui.main_widget")
        local Detail    = require("ui.detail")
        SefirahUI.active_tab = "library"
        Detail.on_back = nil
        -- Retour du lecteur : fiche rouverte directement depuis la copie en mémoire.
        if snap and snap.source_id == source_id and not force and Detail.restoreSnapshot(snap) then
            return
        end
        Detail.fetch(source_id, path, force and true or nil)
    end)
end

local Sefirah = WidgetContainer:extend{
    name        = "sefirah",
    fullname    = "Sefirah",
    description = T("Suivi de web novels et export EPUB"),
    is_doc_only = false,
}

-- Reprise unique des réglages de lecture enregistrés sous les anciennes clés lnreader_*.
local function migrate_legacy_settings()
    if not G_reader_settings then return end
    for _, k in ipairs({ "font_face_idx", "font_size", "line_spacing", "width_idx", "night_mode" }) do
        local old_key, new_key = "lnreader_" .. k, "sefirah_" .. k
        local v = G_reader_settings:readSetting(old_key)
        if v ~= nil and G_reader_settings:readSetting(new_key) == nil then
            G_reader_settings:saveSetting(new_key, v)
            G_reader_settings:delSetting(old_key)
        end
    end
end

function Sefirah:init()
    pcall(migrate_legacy_settings)
    -- Manga : dans le gestionnaire de fichiers, rouvre la fiche après la
    -- fermeture d'un CBZ ; dans le lecteur, oublie l'attente si autre document.
    pcall(function()
        local doc = self.ui and self.ui.document
        require("ui.mangaopen").onPluginInit(doc ~= nil, doc and doc.file)
    end)
    -- Alertes « nouveau chapitre » : boucle unique pour toute la session KOReader.
    pcall(function() require("core.newch").start() end)
    -- File de téléchargement : reprend celle de la session précédente, s'il en reste une.
    pcall(function() require("core.dlqueue").init() end)
    self.ui.menu:registerToMainMenu(self)
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher then
        Dispatcher:init()
        Dispatcher:registerAction("sefirah_open", {
            category   = "none",
            event      = "SefirahOpen",
            title      = T("Sefirah : Ouvrir"),
            general    = true,
        })
    end
end

-- Fermeture d'un document dans le lecteur : si c'est un CBZ ouvert par Sefirah,
-- enregistre la progression (page / total). Pas de « return true ».
-- Écritures différées (réglages, bibliothèque, progression) : on les force avant la mise en veille
-- ou la fermeture de KOReader. Pas de « return true » : l'évènement continue vers les autres plugins.
local function flush_all()
    pcall(function() require("settings").flushNow() end)
    pcall(function() require("core.db").flush() end)
    pcall(function() require("core.cache").flush() end)
end
function Sefirah:onFlushSettings() flush_all() end
function Sefirah:onSuspend() flush_all() end
function Sefirah:onExit() flush_all() end
function Sefirah:onClose() flush_all() end

function Sefirah:onCloseDocument()
    flush_all()
    pcall(function()
        local ui  = self.ui
        local doc = ui and ui.document
        if not doc or not doc.file then return end
        local page = (ui.paging and ui.paging.current_page)
            or (ui.view and ui.view.state and ui.view.state.page)
        require("ui.mangaopen").onDocumentClosed(doc.file, page, doc:getPageCount())
    end)
end

-- À chaque connexion Wi-Fi : vérifie les romans pour lesquels les alertes
-- « nouveau chapitre » ont été acceptées. Pas de « return true » : l'évènement
-- doit continuer vers les autres plugins.
function Sefirah:onNetworkConnected()
    pcall(function() require("core.newch").onNetworkConnected() end)
    -- Reprise de la file de téléchargement après une coupure réseau.
    pcall(function() require("core.dlqueue").onNetworkConnected() end)
end

function Sefirah:onSefirahOpen()
    open_sefirah()
    return true
end

function Sefirah:addToMainMenu(menu_items)
    menu_items["sefirah"] = {
        text         = "Sefirah",
        sorting_hint = "tools",
        callback     = open_sefirah,
    }
end

return Sefirah
