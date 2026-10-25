-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- Popup de réglages : active/désactive l'affichage des couvertures par écran.
-- Se rouvre après chaque bascule pour que les libellés des boutons restent à jour.
local UIManager        = require("ui/uimanager")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local Settings         = require("sefirah_settings")
local InputDialog      = require("ui/widget/inputdialog")
local InfoMessage      = require("ui/widget/infomessage")
local ConfirmBox       = require("ui/widget/confirmbox")

local SettingsDialog = {}
local _dlg = nil
local _page = 1

-- ── Langue du plugin ────────────────────────────────────────────────────────
-- "auto" = suit la langue de KOReader ; sinon un code de locales/ (fr, en, de…).
local PLUGIN_LANGS = {
    { "auto",  nil },
    { "fr",    "Français" },
    { "en",    "English" },
    { "de",    "Deutsch" },
    { "es",    "Español" },
    { "it_IT", "Italiano" },
    { "pt_BR", "Português (Brasil)" },
    { "pt_PT", "Português (Portugal)" },
    { "nl_NL", "Nederlands" },
    { "pl",    "Polski" },
    { "ru",    "Русский" },
    { "tr",    "Türkçe" },
    { "id",    "Bahasa Indonesia" },
    { "ar",    "العربية" },
    { "ja",    "日本語" },
    { "ko_KR", "한국어" },
    { "zh_CN", "简体中文" },
    { "zh_TW", "繁體中文" },
}

local function lang_name(code)
    for _, l in ipairs(PLUGIN_LANGS) do
        if l[1] == code then return l[2] or T("Automatique (KOReader)") end
    end
    return tostring(code)
end

local function plugin_lang_label()
    return lang_name(Settings:get("plugin_language") or "auto")
end

local function show_plugin_lang_picker(on_change)
    local picker
    local rows, row = {}, {}
    local cur = Settings:get("plugin_language") or "auto"
    for _, l in ipairs(PLUGIN_LANGS) do
        local code = l[1]
        local name = (l[2] or T("Automatique (KOReader)")) .. (code == cur and "  ✓" or "")
        row[#row + 1] = {
            text = name,
            callback = function()
                UIManager:close(picker)
                Settings:set("plugin_language", code)
                if on_change then on_change() end
                UIManager:show(InfoMessage:new{
                    text = T("Langue modifiée. Rouvrez Sefirah pour tout appliquer."),
                    timeout = 4,
                })
            end,
        }
        if #row == 2 then rows[#rows + 1] = row; row = {} end
    end
    if #row > 0 then rows[#rows + 1] = row end
    rows[#rows + 1] = {{ text = T("Annuler"), callback = function() UIManager:close(picker) end }}
    picker = ButtonDialogTitle:new{ title = T("Choisir la langue du plugin"), buttons = rows }
    UIManager:show(picker)
end

local function newch_label()
    local m = Settings:get("newch_mode")
    if m == "all" then return T("TOUS LES ROMANS") end
    if m == "none" then return T("DÉSACTIVÉES") end
    return T("PAR ROMAN")
end

local function on_off(key)
    return Settings:get(key) and T("ACTIVÉ") or T("DÉSACTIVÉ")
end

-- ── Téléchargements ─────────────────────────────────────────────────────────
local AHEAD_STEPS = { 0, 1, 3, 5, 10 }   -- chapitres d'avance (0 = désactivé)

local function ahead_label()
    local n = tonumber(Settings:get("dl_ahead")) or 3
    if n <= 0 then return T("DÉSACTIVÉ") end
    return string.format("%d %s", n, T("chapitre(s)"))
end

local function queue_label()
    local ok, n = pcall(function() return require("core.dlqueue").count() end)
    n = (ok and tonumber(n)) or 0
    if n <= 0 then return T("VIDE") end
    return string.format("%d %s", n, T("roman(s)"))
end

-- ── Manga (étape 17) ────────────────────────────────────────────────────────
local MAX_MB_STEPS = { 500, 1000, 2000, 5000, 0 }   -- 0 = illimité

local function manga_dir_label()
    local d = Settings:get("manga_direction") or "auto"
    if d == "rtl" then return T("DROITE → GAUCHE") end
    if d == "ltr" then return T("GAUCHE → DROITE") end
    return T("AUTO")
end

local function manga_max_label()
    local mb = tonumber(Settings:get("manga_max_mb")) or 1000
    if mb <= 0 then return T("ILLIMITÉ") end
    return string.format(T("%d Mo"), mb)
end

local function manga_used_label()
    local ok, bytes = pcall(function() return require("core.manga").usedBytes() end)
    return string.format("%.1f %s", ((ok and bytes) or 0) / 1048576, T("Mo"))
end

-- Saisie d'un texte enregistré dans le réglage `key`, puis retour au dialogue.
function SettingsDialog.askText(title, key, on_saved, refresh)
    refresh = refresh or SettingsDialog.show
    if _dlg then UIManager:close(_dlg); _dlg = nil end
    local input
    input = InputDialog:new{
        title   = title,
        input   = tostring(Settings:get(key) or ""),
        buttons = {{
            { text = T("Annuler"), callback = function()
                UIManager:close(input); refresh()
            end },
            { text = T("Enregistrer"), is_enter_default = true, callback = function()
                local v = (input:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                Settings:set(key, v)
                UIManager:close(input)
                if on_saved and v ~= "" then on_saved() end
                refresh()
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

-- Réglages classés par catégorie : C[id] = liste de rangées de boutons { text, callback }.
-- `refresh` redessine l'écran appelant.
local function categories(refresh)
    local C = {}
    C.general = {
        {
            {
                text     = T("Mode nuit : ") .. on_off("ui_night_mode"),
                callback = function()
                    require("core.night").toggle()
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Langue du plugin : ") .. plugin_lang_label(),
                callback = function() show_plugin_lang_picker(refresh) end,
            },
        },

        {
            {
                text     = T("Alertes nouveaux chapitres : ") .. newch_label(),
                callback = function()
                    local m = Settings:get("newch_mode")
                    Settings:set("newch_mode", (m == "ask" or m == nil) and "all" or (m == "all" and "none" or "ask"))
                    if Settings:get("newch_mode") == "all" then
                        pcall(function() require("core.newch").start() end)
                    end
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Commentaires hors ligne (plus lent) : ") .. on_off("offline_comments"),
                callback = function()
                    Settings:toggle("offline_comments")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Réinitialiser les statistiques"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T("Réinitialiser les statistiques ?\n\nXP, niveau, quêtes, pages et chapitres lus repartent de zéro sur cette liseuse. Ton pseudo, tes téléchargements et ta bibliothèque ne changent pas."),
                        ok_text = T("Réinitialiser"),
                        cancel_text = T("Annuler"),
                        ok_callback = function()
                            require("core.quests").reset()
                            UIManager:show(InfoMessage:new{ text = T("Statistiques réinitialisées."), timeout = 3 })
                            refresh()
                        end,
                    })
                end,
            },
        },
    }
    C.downloads = {
        {
            {
                text     = T("File d'attente : ") .. queue_label(),
                callback = function() require("ui.downloads").show() end,
            },
        },
        {
            {
                text     = T("Télécharger d'avance en lisant : ") .. ahead_label(),
                callback = function()
                    local cur = tonumber(Settings:get("dl_ahead")) or 3
                    local nxt = AHEAD_STEPS[1]
                    for i, v in ipairs(AHEAD_STEPS) do
                        if v == cur then nxt = AHEAD_STEPS[i % #AHEAD_STEPS + 1]; break end
                    end
                    Settings:set("dl_ahead", nxt)
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Reprise automatique : ") .. on_off("dl_autoresume"),
                callback = function()
                    Settings:toggle("dl_autoresume")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Notifications de progression : ") .. on_off("dl_notify"),
                callback = function()
                    Settings:toggle("dl_notify")
                    refresh()
                end,
            },
        },
    }
    C.covers = {
        {
            {
                text     = T("Couvertures · Page Bibliothèque : ") .. on_off("covers_library"),
                callback = function()
                    Settings:toggle("covers_library")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Couvertures · Page Parcourir : ") .. on_off("covers_browse"),
                callback = function()
                    Settings:toggle("covers_browse")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Couvertures · Page Détails : ") .. on_off("covers_detail"),
                callback = function()
                    Settings:toggle("covers_detail")
                    refresh()
                end,
            },
        },
    }
    C.translate = {
        {
            {
                text     = T("Traduction automatique : ") .. on_off("translate_enabled"),
                callback = function()
                    Settings:toggle("translate_enabled")
                    refresh()
                end,
            },
        },
        {
            {
                text = T("Traduction · Moteur : ") .. tostring(Settings:get("translate_engine") or "deepl"),
                callback = function()
                    local e = Settings:get("translate_engine") or "deepl"
                    local next = (e == "deepl" and "google") or (e == "google" and "gemini") or "deepl"
                    Settings:set("translate_engine", next)
                    refresh()
                    local k = Settings:get("translate_api_key", nil, refresh)
                    if next == "gemini" and (type(k) ~= "string" or k == "") then
                        UIManager:show(InfoMessage:new{
                            text = T("La trad sans clé API prend une éternité."),
                        })
                    end
                end,
            },
            {
                text     = T("Traduction · Langue cible : ") .. tostring(Settings:get("translate_lang")),
                callback = function()
                    local Lang = require("ui.translate_lang")
                    Lang.show(function() refresh() end)
                end,
            },
            {
                text     = T("Traduction · Clé DeepL Free"),
                callback = function()
                    SettingsDialog.askText(
                        T("Clé API DeepL Free (500 000 caractères/mois)"),
                        "translate_deepl_key", nil, refresh)
                end,
            },
        },
        {
            {
                text     = T("Traduction · Clé Gemini"),
                callback = function()
                    SettingsDialog.askText(
                        T("Clé API Gemini"),
                        "translate_api_key", nil, refresh)
                end,
            },
        },
    }
    C.manga = {
        {
            {
                text     = T("Manga · Lecteur : ")
                    .. (Settings:get("manga_reader") == "sefirah" and "SEFIRAH" or "KOREADER"),
                callback = function()
                    Settings:set("manga_reader", Settings:get("manga_reader") == "sefirah" and "koreader" or "sefirah")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Manga · Sens de lecture : ") .. manga_dir_label(),
                callback = function()
                    local d = Settings:get("manga_direction") or "auto"
                    Settings:set("manga_direction", (d == "auto" and "rtl") or (d == "rtl" and "ltr") or "auto")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Manga · Mode : ") .. ((Settings:get("manga_mode") or "auto") == "manhwa" and "MANHWA"
                    or (Settings:get("manga_mode") or "auto") == "manga" and "MANGA" or "AUTO"),
                callback = function()
                    local m = Settings:get("manga_mode") or "auto"
                    Settings:set("manga_mode", (m == "auto" and "manhwa") or (m == "manhwa" and "manga") or "auto")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Manga · Doubles pages : ") .. (({ off = "NON", cw = "90° ↻", ccw = "90° ↺" })[Settings:get("manga_rotate_spread") or "off"] or "NON"),
                callback = function()
                    local r = Settings:get("manga_rotate_spread") or "off"
                    Settings:set("manga_rotate_spread", (r == "off" and "cw") or (r == "cw" and "ccw") or "off")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Manga · N° de page : ") .. on_off("manga_pageinfo"),
                callback = function()
                    Settings:toggle("manga_pageinfo")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Manga · Chapitre suivant auto : ") .. on_off("manga_autonext"),
                callback = function()
                    Settings:toggle("manga_autonext")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Manga · Précharger le chapitre suivant : ") .. on_off("manga_prefetch"),
                callback = function()
                    Settings:toggle("manga_prefetch")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Manga · Qualité des pages : ")
                    .. (Settings:get("manga_full_quality") and T("ORIGINALE") or T("COMPRESSÉE")),
                callback = function()
                    Settings:toggle("manga_full_quality")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Manga · Supprimer après lecture : ") .. on_off("manga_autoclean"),
                callback = function()
                    Settings:toggle("manga_autoclean")
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Manga · Espace maximum : ") .. manga_max_label(),
                callback = function()
                    local cur = tonumber(Settings:get("manga_max_mb")) or 1000
                    local nxt = MAX_MB_STEPS[1]
                    for i, v in ipairs(MAX_MB_STEPS) do
                        if v == cur then nxt = MAX_MB_STEPS[i % #MAX_MB_STEPS + 1]; break end
                    end
                    Settings:set("manga_max_mb", nxt)
                    refresh()
                end,
            },
        },
        {
            {
                text     = T("Manga · Vider les téléchargements (") .. manga_used_label() .. ")",
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T("Supprimer tous les mangas téléchargés ?"),
                        ok_text = T("Supprimer"),
                        ok_callback = function()
                            local ok, freed = pcall(function() return require("core.manga").clearAll() end)
                            UIManager:show(InfoMessage:new{
                                text = string.format(T("Espace libéré : %.1f Mo"), ((ok and freed) or 0) / 1048576),
                                timeout = 3,
                            })
                            refresh()
                        end,
                    })
                end,
            },
        },
    }
    return C
end

-- Cartes affichées dans l'onglet « Plus » : { id, libellé, sous-titre, icône }.
-- (Les icônes resources/set_*.png sont des pictogrammes au trait fin ; set_chevron.png
-- est la flèche de droite.)
local CATEGORIES = {
    { "settings",    "Paramètres",       "Général, téléchargements, couvertures, traduction, manga", "set_general" },
    { "progression", "Quêtes & niveaux", "Progression, défis et succès de lecture", "set_stats" },
}
-- Sections regroupées dans « Paramètres » : { id dans categories(), titre de section }.
local SETTINGS_SECTIONS = {
    { "general",   "Général" },
    { "downloads", "Téléchargements" },
    { "covers",    "Couvertures" },
    { "translate", "Traduction" },
    { "manga",     "Manga" },
}
local PLUGIN_ROOT = (debug.getinfo(1, "S").source or ""):match("^@(.+)/ui/settings_dialog%.lua$") or ""
local function icon_path(name) return PLUGIN_ROOT .. "/resources/" .. name .. ".png" end

-- ── Mise en page « liste de réglages » : lignes icône / titre / sous-titre / chevron ──
local function build_cards(P, on_pick)
    local Blitbuffer      = require("ffi/blitbuffer")
    local Device          = require("device")
    local Font            = require("ui/font")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local Geom            = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local ImageWidget     = require("ui/widget/imagewidget")
    local LineWidget      = require("ui/widget/linewidget")
    local TextWidget      = require("ui/widget/textwidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local Screen          = Device.screen
    local sz = function(n) return Screen:scaleBySize(n) end

    local side     = P.MARGIN + sz(8)              -- marge gauche/droite des lignes
    local icon_sz  = sz(34)
    local chev_sz  = sz(22)
    local function img(name, size)
        return ImageWidget:new{
            file = icon_path(name), width = size, height = size,
            scale_factor = 0, original_in_nightmode = false,
        }
    end
    local function centered_block(row_h, content)
        local h = content:getSize().h
        local top = math.max(0, math.floor((row_h - h) / 2))
        return FrameContainer:new{
            bordersize = 0, margin = 0, padding = 0,
            padding_top = top, padding_bottom = math.max(0, row_h - h - top),
            background = Blitbuffer.COLOR_WHITE,
            content,
        }
    end

    -- Hauteur des lignes : toutes les catégories tiennent sur une page si l'écran le permet.
    local n = #CATEGORIES
    local row_h = math.floor((P.CONTENT_H - P.MARGIN - n * P.HAIRLINE) / n)
    row_h = math.max(sz(56), math.min(sz(84), row_h))

    local function make_cat(c, last)
        local text_w = P.W - side - icon_sz - P.MARGIN - chev_sz - 2 * side
        local tb = VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = T(c[2]), face = Font:getFace("cfont", 19),
                fgcolor = Blitbuffer.COLOR_BLACK, max_width = text_w },
            VerticalSpan:new{ width = sz(2) },
            TextWidget:new{ text = T(c[3]), face = Font:getFace("cfont", 14),
                fgcolor = Blitbuffer.COLOR_GRAY, max_width = text_w },
        }
        local fill = math.max(0, text_w - tb:getSize().w) + side
        local row = centered_block(row_h, HorizontalGroup:new{
            HorizontalSpan:new{ width = side },
            img(c[4], icon_sz),
            HorizontalSpan:new{ width = P.MARGIN },
            tb,
            HorizontalSpan:new{ width = fill },
            img("set_chevron", chev_sz),
            HorizontalSpan:new{ width = side },
        })
        local id = c[1]
        local tappable = P.wrapTappable(row, function() on_pick(id) end)
        if last then return tappable end
        -- Séparateur fin, en retrait des deux côtés.
        return VerticalGroup:new{
            align = "left",
            tappable,
            HorizontalGroup:new{
                HorizontalSpan:new{ width = side },
                LineWidget:new{ background = Blitbuffer.COLOR_LIGHT_GRAY,
                    dimen = Geom:new{ w = P.W - 2 * side, h = P.HAIRLINE } },
            },
        }
    end

    local rows = {}
    for i, c in ipairs(CATEGORIES) do rows[#rows + 1] = make_cat(c, i == n) end
    return rows
end
local _cat = nil   -- catégorie ouverte (nil = liste des catégories)

-- Onglet « Plus » (à droite de Sources).
function SettingsDialog.build_rows()
    local P = require("ui.panel")
    local function rebuild() require("ui.main_widget").show("settings") end
    local rows = {}
    local back_row = nil
    local title = T("Plus")
    if _cat then
        local C = categories(rebuild)
        for _, c in ipairs(CATEGORIES) do
            if c[1] == _cat then title = T(c[2]) end
        end
        back_row = P.makeRow(T("← Retour"), {
            bold = true,
            callback = function() _cat = nil; _page = 1; rebuild() end,
        })
        if _cat == "settings" then
            -- Tous les réglages dans une seule liste, une rubrique par section.
            for _, sec in ipairs(SETTINGS_SECTIONS) do
                table.insert(rows, P.makeRow(T(sec[2]), { bold = true, dim = true, font_size = 15, height = P.ROW_H - require("device").screen:scaleBySize(10) }))
                for _, group in ipairs(C[sec[1]] or {}) do
                    for _, e in ipairs(group) do
                        local cb = e.callback
                        table.insert(rows, P.makeRow(e.text, { callback = function() cb() end }))
                    end
                end
            end
        else
            for _, group in ipairs(C[_cat] or {}) do
                for _, e in ipairs(group) do
                    local cb = e.callback
                    table.insert(rows, P.makeRow(e.text, { callback = function() cb() end }))
                end
            end
        end
    else
        rows = build_cards(P, function(id)
            -- « Quêtes & niveaux » ouvre directement le Centre de progression.
            if id == "progression" then require("core.quests").show(); return end
            _cat = id; _page = 1; rebuild()
        end)
    end

    -- Pagination par hauteur réelle des lignes (même méthode que l'onglet Sources).
    local budget = P.CONTENT_H - P.MARGIN - (back_row and back_row:getSize().h or 0)
    local pages, cur, used = {}, {}, 0
    for _, r in ipairs(rows) do
        local h = r:getSize().h
        if used + h > budget and #cur > 0 then
            table.insert(pages, cur); cur, used = {}, 0
        end
        table.insert(cur, r); used = used + h
    end
    table.insert(pages, cur)
    local max_pages = #pages
    if _page > max_pages then _page = max_pages end
    local nav = max_pages > 1 and {
        page = _page, max_pages = max_pages,
        on_prev = _page > 1 and function() _page = _page - 1; rebuild() end or nil,
        on_next = _page < max_pages and function() _page = _page + 1; rebuild() end or nil,
    } or nil
    local page_rows = pages[_page]
    if back_row then   -- « ← Retour » reste visible sur chaque page de la catégorie
        page_rows = { back_row, table.unpack(page_rows) }
    end
    return page_rows, title, nav, {}
end

-- Ouvre l'onglet Plus (le menu ⋮ → Réglages passe aussi par ici).
function SettingsDialog.show()
    _page = 1
    _cat = nil
    require("ui.main_widget").show("settings")
end

return SettingsDialog
