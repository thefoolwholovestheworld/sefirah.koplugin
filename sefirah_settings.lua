-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- Réglages Sefirah. Version sans dépôt distant et sans JavaScript.
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

local DEFAULTS = {
    -- Classement communautaire facultatif : URL de l’API et pseudo public.
    leaderboard_url = "",
    leaderboard_username = "",
    leaderboard_player_id = "",
    leaderboard_player_token = "",
    -- Langue du plugin : "auto" (suit KOReader) ou un code de locales/ (fr, en, de…).
    plugin_language = "auto",
    -- Mode nuit de tout le plugin (cf. core/night.lua).
    ui_night_mode   = false,
    -- Type de contenu affiché dans Bibliothèque / Parcourir / Sources : "novels" ou "manga".
    content_kind    = "novels",
    covers_library  = true,
    covers_browse   = true,
    covers_detail   = true,
    extension_settings = {},
    -- Sources installées par l'utilisateur (onglet Sources). Une source non
    -- installée n'apparaît pas dans Parcourir. Vide par défaut.
    installed_sources = {},
    -- Catalogue en ligne (Sefirah Source Hub) : adresse du site, dernier manifeste lu,
    -- et version des sources téléchargées depuis le Hub (pour proposer les mises à jour).
    hub_url = "https://thefoolwholovestheworld.github.io/Sefirah-Source-Hub/",
    hub_cache = {},
    hub_versions = {},
    chapters_ascending = false,
    -- Derniers filtres choisis dans Parcourir, par source : { [store] = { [clé] = id } }
    -- (store = source_id, ou source_id..":search" pour la recherche).
    browse_filters = {},
    -- Masquage global des commentaires/avis (bascule par appui long sur
    -- l'icône commentaire de l'onglet Chapitres, cf. ui/detail.lua) :
    -- true = onglet « Avis » caché, bulles de commentaires du lecteur
    -- retirées, section « Commentaires » de fin de chapitre masquée.
    comments_hidden = false,
    -- Filtre de langues des onglets Parcourir / Sources : liste de codes
    -- (ex. { "fr", "en" }). Liste vide = toutes les langues.
    lang_filter = {},
    -- Téléchargement des commentaires paragraphe par paragraphe avec chaque
    -- chapitre (consultables hors ligne). Beaucoup plus lent : désactivé par défaut.
    offline_comments = false,
    -- Manga (étapes 9-11/17) : espace max occupé par les CBZ téléchargés
    -- (en Mo, 0 = illimité) et qualité d'origine des pages.
    manga_max_mb = 1000,
    manga_full_quality = false,
    -- Sens de lecture des CBZ : "auto" (japonais = droite→gauche), "rtl" ou "ltr".
    manga_direction = "auto",
    -- Supprime le CBZ dès que le chapitre est lu jusqu'à la dernière page.
    manga_autoclean = false,
    -- Lecteur des chapitres manga : "koreader" (lecteur natif) ou "sefirah" (intégré, défaut).
    manga_reader = "sefirah",
    -- Lecteur intégré : n° de page affiché en bas ; dernière page → chapitre suivant.
    manga_pageinfo = true,
    manga_mode = "auto",
    -- Doubles pages (image bien plus large que haute) : "off", "cw" (tourne de 90° vers la droite)
    -- ou "ccw" (vers la gauche), pour qu'elles remplissent l'écran en portrait.
    manga_rotate_spread = "off",
    manga_autonext = true,
    -- Précharge en silence le chapitre suivant pendant la lecture (lecteur intégré).
    manga_prefetch = true,
    -- Téléchargement intelligent (core/dlqueue.lua) :
    -- dl_ahead : chapitres téléchargés d'avance pendant la lecture (0 = désactivé) ;
    -- dl_autoresume : la file reprend toute seule après une coupure réseau / un redémarrage ;
    -- dl_notify : petites notifications de progression (non bloquantes).
    dl_ahead      = 3,
    dl_autoresume = true,
    dl_notify     = true,
    -- Lecteur de roman : les deux gros boutons « Chap. précédent / suivant » en bas.
    -- reader_nav_asked : la question posée à la 1re ouverture du lecteur a déjà reçu une réponse.
    reader_nav_buttons = true,
    reader_nav_asked   = false,
    -- Petits popups de quêtes / succès / niveau pendant la lecture : désactivés par défaut.
    quest_notifications = false,
    -- Alertes « nouveau chapitre » : "ask" (demander à chaque favori), "all", "none".
    newch_mode = "ask",
    newch_novels = {},
    -- Traduction : sans clé, Google Traduction est utilisé ; DeepL / Gemini si une clé est saisie.
    translate_enabled = false,
    translate_deepl_key = "",
    translate_api_key = "",
    translate_lang    = "Français",
    translate_model   = "gemini-flash-latest",
    -- Moteur : deepl, google (gratuit sans clé) ou gemini.
    translate_engine  = "deepl",
}

local Settings = {}
local _file = nil

local function get_file()
    if not _file then
        local dir      = DataStorage:getSettingsDir()
        local new_path = dir .. "/sefirah.lua"
        local old_path = dir .. "/lnreader.lua"
        -- Reprise unique de l'ancien fichier de réglages (avant le renommage).
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(new_path, "mode") ~= "file" and lfs.attributes(old_path, "mode") == "file" then
            os.rename(old_path, new_path)
        end
        _file = LuaSettings:open(new_path)
    end
    return _file
end

function Settings:get(key)
    local val = get_file():readSetting(key)
    if val == nil then return DEFAULTS[key] end
    return val
end

-- Écriture différée : réécrire tout le fichier de réglages à CHAQUE changement (ex. à chaque page
-- tournée pour l'XP) ralentissait beaucoup la lecture. On regroupe : une écriture 2 s après le dernier
-- changement, et une écriture forcée à la fermeture (Settings.flushNow).
local _flush_pending = false
function Settings.flushNow()
    if not _flush_pending then return end
    _flush_pending = false
    pcall(function() get_file():flush() end)
end
function Settings:set(key, value)
    get_file():saveSetting(key, value)
    if _flush_pending then return end
    _flush_pending = true
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok and UIManager then
        UIManager:scheduleIn(2, Settings.flushNow)
    else
        Settings.flushNow()
    end
end

function Settings:toggle(key)
    self:set(key, not self:get(key))
end

function Settings:getExt(ext_id, key, default)
    local all = self:get("extension_settings") or {}
    local ext = all[ext_id] or {}
    local val = ext[key]
    if val == nil then return default end
    return val
end

function Settings:setExt(ext_id, key, value)
    local all = self:get("extension_settings") or {}
    if not all[ext_id] then all[ext_id] = {} end
    all[ext_id][key] = value
    self:set("extension_settings", all)
end

function Settings:toggleExt(ext_id, key, default)
    self:setExt(ext_id, key, not self:getExt(ext_id, key, default))
end

return Settings
