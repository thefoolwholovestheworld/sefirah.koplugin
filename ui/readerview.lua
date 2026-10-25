-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- ui/readerview.lua — Lecteur intégré Sefirah.
-- S'ouvre comme un 4e niveau de panneau (au-dessus de Detail, comme Export),
-- affiche le chapitre en texte défilant/paginé sans jamais quitter Sefirah.
--
-- Vérifié contre le vrai frontend/ui/widget/scrolltextwidget.lua de KOReader :
--  - scrollText(dir) ne renvoie rien → on utilise onScrollDown()/onScrollUp(),
--    qui renvoient true seulement si le widget a effectivement pu défiler
--    (sinon on est déjà en haut/bas → on change de chapitre).
--  - la position de lecture se lit via :getCharPos(), pas via un champ .charpos.
--  - `dialog` DOIT être fourni (une table quelconque suffit), sinon
--    updateScrollBar() plante sur `self.dialog.movable` au 1er tourne-page.
local UIManager        = require("ui/uimanager")
local logger            = require("logger")
local InfoMessage       = require("ui/widget/infomessage")
local Online      = require("core.online")
local GestureRange      = require("ui/gesturerange")
local InputContainer    = require("ui/widget/container/inputcontainer")
local Geom              = require("ui/geometry")
local Font              = require("ui/font")
local Device            = require("device")
local Screen            = Device.screen
local Blitbuffer        = require("ffi/blitbuffer")
local FrameContainer    = require("ui/widget/container/framecontainer")
local CenterContainer   = require("ui/widget/container/centercontainer")
local HorizontalGroup   = require("ui/widget/horizontalgroup")
local HorizontalSpan    = require("ui/widget/horizontalspan")
local VerticalGroup     = require("ui/widget/verticalgroup")
local OverlapGroup      = require("ui/widget/overlapgroup")
local TextWidget        = require("ui/widget/textwidget")
local TextBoxWidget     = require("ui/widget/textboxwidget")
local Menu              = require("ui/widget/menu")
local TextViewer        = require("ui/widget/textviewer")
local WidgetContainer   = require("ui/widget/container/widgetcontainer")
local ImageWidget       = require("ui/widget/imagewidget")
local LineWidget        = require("ui/widget/linewidget")

local Cache    = require("core.cache")
local Epub     = require("core.epub")
local DB       = require("core.db")
local Stats    = require("core.stats")  -- alimente les statistiques générales de KOReader
local Avatars  = require("core.avatars")
local Emoji    = require("core.emoji")
local P        = require("ui.panel")
local Settings = require("sefirah_settings")

-- Masquage global des commentaires (bascule par appui long sur l'icône
-- commentaire de l'onglet Chapitres, cf. ui/detail.lua). Quand c'est actif,
-- le lecteur n'affiche ni les bulles de commentaires par paragraphe, ni les
-- pdp de la section de fin de chapitre, ni l'accès au panneau de
-- commentaires ; la section « Commentaires » injectée en texte par certaines
-- sources est également retirée du chapitre affiché.
local function comments_hidden()
    return Settings:get("comments_hidden") and true or false
end

local ReaderView = {}

local _ctx        = nil   -- { source_id, ext, novel, chapters, index }
local _panel       = nil
local _scroll_w    = nil  -- ScrollTextWidget courant
local _gestures_wired = false
local _restoring_position = false

-- Métadonnées "avis par paragraphe" du chapitre affiché : { chapterId,
-- marks = { { id, count, preview }, ... } }, ou nil si aucun avis. Extrait
-- du trailer JSON `<!--LNREADER_META:...-->` que novelfrance.lua ajoute en
-- fin de HTML (cf. section "Avis par paragraphe" dans open_index/render()
-- plus bas) — réinitialisé à chaque rendu de chapitre. C'est une extension
-- spécifique à novelfrance.lua pour l'instant : les autres sources n'ajoutent
-- pas ce trailer, donc _chapter_marks reste simplement nil pour elles (aucun
-- badge affiché, comportement inchangé).
local _chapter_marks = nil

-- Boutons d'icônes "comment.png" superposés au texte (un par paragraphe
-- commenté), construits une fois par ouverture de chapitre dans render()
-- via build_comment_overlays(). Doivent rester accessibles depuis
-- refresh_page_indicator() (fonction top-level, PAS imbriquée dans render())
-- pour que celle-ci puisse les réinsérer dans le corps du panneau qu'elle
-- reconstruit à chaque scroll — sinon ces boutons sont silencieusement
-- perdus (swapBody remplace tout l'arbre de widgets) et les icônes
-- disparaissent dès le premier défilement. Cf. refresh_page_indicator plus
-- bas pour le détail du bug corrigé.
local _comment_buttons = nil
local _comment_visuals = nil
-- pdp superposées à côté des lignes "Auteur — date" de la section
-- "Commentaires" de fin de chapitre (cf. build_avatar_overlays plus bas) —
-- même raison d'être au niveau module que _comment_visuals ci-dessus :
-- refresh_page_indicator() (hors de la fermeture de render()) doit pouvoir
-- les réinsérer à chaque swapBody.
local _avatar_visuals = nil
local _paragraph_popup = nil

-- Descripteur nav réutilisé à chaque (re)création du panneau : c'est ce que
-- FullScreenPanel:onSwipe (ui/panel.lua) lit pour convertir un swipe
-- ouest/est en tourne-page — le même mécanisme déjà utilisé par Browse et
-- Library, donc pas besoin de câbler notre propre Swipe en plus.
local _nav = {
    on_next = function() ReaderView.nextPage() end,
    on_prev = function() ReaderView.prevPage() end,
}
-- Hauteur des 2 gros boutons de navigation de chapitre en bas de l'écran
-- (nettement plus grand que P.NAV_ROW_H pour être facile à taper au doigt).
-- Vient de P.BIG_BTN_H, la même constante que les gros boutons d'action de
-- l'écran Détails (Track/Untrack, Refresh Chapter List), pour que tous ces
-- boutons du bas fassent exactement la même taille.
local NAV_BTN_H     = P.BIG_BTN_H
-- Les onglets "Chapters / Detail" ne sont pas créés ici : leur taille dépend
-- de ui/panel.lua. On ne touche donc pas à leur géométrie dans ce fichier.
-- Hauteur de la petite ligne "index / total" affichée juste au-dessus des
-- boutons Chap. précédent/suivant (une seule ligne de texte centrée).
local PAGE_IND_H    = Screen:scaleBySize(36)
-- Taille du bouton Réglages (icône ⚙), désormais superposé DANS la barre de
-- titre (coin haut-droit) au lieu d'occuper sa propre ligne en dessous — cf.
-- make_settings_gear_button()/make_title_row() plus bas. Comme il n'occupe
-- plus de ligne à lui, il ne se soustrait plus de _text_area_h.
local GEAR_BTN_SIZE = Screen:scaleBySize(52)
-- Bande de texte ajoutée sous le texte défilant (auparavant un espace vide
-- inutilisé, réservé pour un "titre" qui vivait ici avant d'être déplacé
-- dans la barre du haut) — cf. make_novel_title_row() plus bas. Toute la
-- logique de pagination (chars_per_screen) et la hauteur réelle du
-- ScrollTextWidget DOIVENT utiliser cette même constante pour rester
-- cohérentes entre elles.
local NOVEL_TITLE_ROW_H = 0 -- supprimé : aucun titre de roman gris au-dessus de l’indicateur
local _text_area_h  = P.SUB_H - NAV_BTN_H - PAGE_IND_H
local _title_extra_h = 0

local function reader_text_area_h()
    return math.max(Screen:scaleBySize(100), _text_area_h - _title_extra_h)
end

local function clean_reader_title(title)
    title = tostring(title or "")
    -- Le numéro de chapitre est séparé du sous-titre par un ':' sur certaines
    -- sources. L'affichage demandé est "Chapter 3184 Insidious Traps".
    title = title:gsub("^(%s*[Cc]hapter%s+[%d%.]+)%s*:%s*", "%1 ")
    title = title:gsub("^(%s*[Cc]hapitre%s+[%d%.]+)%s*:%s*", "%1 ")
    return title:match("^%s*(.-)%s*$") or ""
end

local function title_row_metrics(title)
    local BTN_W = Screen:scaleBySize(48)
    local title_w = math.max(Screen:scaleBySize(160), P.W - 2 * BTN_W - GEAR_BTN_SIZE - Screen:scaleBySize(8))
    local face = Font:getFace("cfont", 18)
    local probe = TextBoxWidget:new{
        text = clean_reader_title(title),
        face = face,
        bold = true,
        width = title_w,
        alignment = "center",
    }
    local natural_h = probe:getSize().h
    local max_h = Screen:scaleBySize(108)
    local h = math.min(max_h, math.max(P.TITLE_H, natural_h + Screen:scaleBySize(8)))
    return h, title_w
end

local function close_all()
    if _G.sefirah_close_all then _G.sefirah_close_all() end
end

-- Sortie globale du plugin déclenchée par le swipe vertical.
-- Important : passer par SefirahUI.close() ferme d'abord ReaderView proprement,
-- puis les panneaux Detail/onglet. Cela évite de laisser _panel/_scroll_w
-- vivants et permet de rouvrir un chapitre normalement ensuite.
local function close_plugin_from_swipe()
    local ok, SefirahUI = pcall(require, "ui.main_widget")
    if ok and SefirahUI and SefirahUI.close then
        SefirahUI.close()
    elseif ReaderView and ReaderView.close then
        ReaderView.close()
    elseif _G.sefirah_close_all then
        _G.sefirah_close_all()
    end
end

-- Pendant la lecture d'un chapitre, le panneau ne doit jamais se fermer
-- parce qu'un événement remonte jusqu'au FullScreenPanel. La sortie du
-- chapitre se fait uniquement via la petite flèche ou le nom du chapitre
-- dans la barre de titre, ou via le geste vertical dédié haut-centre -> bas-centre.
local function chapter_close_guard()
    return true
end

-- Largeur de la zone centrale du titre qui doit rester cliquable pour sortir.
-- Les zones vides à gauche/droite du titre sont volontairement bloquées afin
-- qu'un tap dans ces espaces ne ferme plus le chapitre.
local TITLE_ACTIVE_W = Screen:scaleBySize(250)
-- Déclaré tôt (avant make_nav_button un peu plus bas, qui s'en sert déjà
-- pour choisir ses couleurs) : tous les widgets DESSINÉS DANS CE FICHIER
-- (boutons de nav, indicateur de page, bande titre du roman, icône ⚙, lignes
-- du panneau Réglages, texte du chapitre) passent par bg_color()/fg_color()
-- au lieu de Blitbuffer.COLOR_WHITE/COLOR_BLACK en dur, pour s'inverser
-- ensemble. La vraie valeur de _night_mode est chargée/persistée plus bas
-- avec les autres réglages (cf. load_reader_settings/save_reader_settings),
-- qui réassignent ce même upvalue au chargement du module.
-- LIMITE CONNUE : la barre de titre (P.makeTitleBar) et les séparateurs
-- (P.hairline()) viennent de ui/panel.lua, pas de ce fichier — leurs
-- couleurs ne sont donc pas inversées ici.
local _night_mode = false

local function bg_color()
    return _night_mode and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
end
local function fg_color()
    return _night_mode and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
end

-- ── Direction de lecture ──────────────────────────────────────────────────────
-- `_ctx.chapters` vient tel quel de la source : certaines listent du plus
-- récent au plus ancien (Ch.3149 en position 1, Ch.3140 plus loin dans la
-- liste — cf. l'écran Chapters), d'autres du plus ancien au plus récent.
-- On détecte le sens via chapter_number et on en déduit `step` : le pas
-- d'INDEX (dans le tableau) qui correspond à "avancer dans l'histoire".
-- Ainsi Chap. suivant = toujours +step (avance), Chap. précédent = -step
-- (recule), quel que soit l'ordre brut du tableau.
local function chapter_number_value(ch)
    if not ch then return nil end
    local n = ch.chapter_number
    if type(n) == "number" then return n end
    if type(n) == "string" then
        n = tonumber(n)
        if n then return n end
    end
    -- Fallback : extraire le numéro depuis le titre/nom de chapitre.
    -- Les sources ne sont pas toutes en anglais/français (ex. "Capítulo 12").
    local text = tostring(ch.name or ch.title or ch.path or "")
    local raw = text:match("[Cc]hapter%s*[#%-]?%s*(%d+%.?%d*)")
        or text:match("[Cc]hapitre%s*[#%-]?%s*(%d+%.?%d*)")
        or text:match("[Cc]ap[ií]tulo%s*[#%-]?%s*(%d+%.?%d*)")
        or text:match("[Cc]ap%.?%s*[#%-]?%s*(%d+%.?%d*)")
        or text:match("[Cc]h%.?%s*[#%-]?%s*(%d+%.?%d*)")
    return raw and tonumber(raw) or nil
end

-- BUG corrigé ici : l'ancienne version cherchait, sur TOUT le tableau, le
-- chapitre dont le numéro était le plus proche du courant (« plus petit
-- numéro strictement supérieur », etc.). Ça casse dès qu'un chapitre spécial
-- (prologue/bonus ajouté après coup, ex. « chapitre 0.1 ») traîne à une
-- extrémité de la liste avec un numéro qui n'est pas dans la continuité :
-- exemple vécu (un roman à 703 chapitres) : chapitres 1..701 dans
-- l'ordre puis, en TOUTE DERNIÈRE position, un chapitre numéroté 0.1.
--   • Depuis le chapitre 1, « précédent » trouvait ce 0.1 (0.1 < 1) et
--     renvoyait donc VRAI alors qu'on est censé être au tout premier chapitre.
--   • Depuis ce chapitre 0.1 (positionnellement le DERNIER), « suivant »
--     trouvait le chapitre 1 (le plus petit numéro strictement > 0.1) et
--     renvoyait donc VRAI alors qu'on est censé être au tout dernier chapitre.
-- Résultat : les boutons ne se désactivaient jamais aux deux bornes réelles
-- de la liste, et pire, « suivant »/« précédent » pouvait faire sauter à
-- l'autre bout du roman.
--
-- Le vrai « y a-t-il un chapitre suivant/précédent » ne peut être QUE une
-- question de POSITION dans le tableau (on a atteint la première ou la
-- dernière entrée listée par la source, point final) — jamais une question
-- de numéro, qui n'est qu'un indice pour savoir dans quel SENS avancer.
-- `chapter_number` garde donc un seul rôle : détecter le sens global de la
-- liste (ascendante/descendante) une fois pour toutes via compute_step.
local function compute_step(chapters)
    if not chapters or #chapters < 2 then return 1 end

    -- Le tableau fourni par une source peut être ASC (1,2,3...) ou DESC
    -- (3,2,1...). On ne suppose jamais que les deux premières entrées
    -- contiennent des numéros exploitables : certaines sources mélangent
    -- prologues, bonus ou titres sans numéro.
    --
    -- On prend la première paire de numéros DISTINCTS rencontrée et on
    -- mémorise le sens de la liste. La navigation elle-même reste
    -- strictement positionnelle : on ne saute jamais vers un autre chapitre
    -- en cherchant un numéro "proche".
    local prev_num
    for _, ch in ipairs(chapters) do
        local n = chapter_number_value(ch)
        if n then
            if prev_num then
                if n < prev_num then return -1 end
                if n > prev_num then return 1 end
            end
            prev_num = n
        end
    end

    -- Numéros absents ou identiques : on conserve l'ordre fourni par la
    -- source plutôt que d'inventer un sens.
    return 1
end

-- Adjacent = position ± step dans le tableau, sans exception. C'est ce qui
-- garantit que « suivant » est indisponible (nil) sur la toute dernière
-- entrée de la liste et « précédent » sur la toute première, quels que
-- soient les numéros de chapitre rencontrés en chemin.
local function get_adjacent_index(direction)
    if not _ctx or not _ctx.chapters or not _ctx.index then return nil end
    local idx = _ctx.index + direction * (_ctx.step or 1)
    return _ctx.chapters[idx] and idx or nil
end

-- ── Grands boutons « Chap. précédent » / « Chap. suivant » ───────────────────
-- Remplace l'ancienne barre de progression texte : navigation directe de
-- chapitre à chapitre (pas juste défilement de page).
-- IMPORTANT sens des flèches : le bouton de GAUCHE ("‹ Chap. précédent")
-- doit toujours ramener au chapitre précédent (index - 1), et celui de
-- DROITE ("Chap. suivant ›") doit toujours avancer au chapitre suivant
-- (index + 1). Ne pas inverser les callbacks ci-dessous.

local function make_nav_button(label, enabled, callback, width)
    local face = Font:getFace("cfont", 20)
    local txt = TextWidget:new{
        text    = label,
        face    = face,
        bold    = true,
        fgcolor = enabled and fg_color() or Blitbuffer.COLOR_GRAY,
    }
    local half_w = width or math.floor(P.W / 2)
    local frame = FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        width      = half_w,
        height     = NAV_BTN_H,
        background = bg_color(),
        CenterContainer:new{
            dimen = Geom:new{ w = half_w, h = NAV_BTN_H },
            txt,
        },
    }
    if enabled then
        return P.wrapTappable(frame, callback)
    end
    return frame
end

-- ── Indicateur de page (position de défilement DANS le chapitre) ─────────────
-- Le widget de texte défile en continu (pas de pagination native), donc on
-- estime un nombre de "pages" virtuelles à partir de la taille de la zone de
-- texte et de la taille de police : combien de caractères tiennent sur un
-- écran, puis combien d'"écrans" (pages) fait le chapitre entier. C'est une
-- approximation (chasse variable des caractères, lignes vides, etc.) mais
-- suffisante pour donner un repère de progression, comme le ferait un lecteur paginé.
local READER_FONT_SIZE = 20

-- ── Réglages de lecture : police et taille ───────────────────────────────────
-- Modifiables en direct via l'icône "⚙" en haut à droite (voir
-- make_settings_gear_button / ReaderView.openSettings plus bas).
--
-- Vérifié contre le vrai frontend/ui/font.lua de KOReader : Font:getFace(font, size)
-- cherche d'abord `font` dans Font.fontmap (des ALIAS comme "cfont"/"tfont"
-- utilisés dans toute l'UI) ; si `font` n'y figure pas, il l'utilise TEL QUEL
-- comme nom de fichier réel. On peut donc passer directement un nom de
-- fichier .ttf ici, sans toucher à Font.fontmap.
-- L'ancienne 2e entrée ("tfont") N'ÉTAIT PAS une police différente : dans
-- font.lua, tfont == "NotoSans-Bold.ttf", c'est-à-dire la MÊME police que
-- cfont ("NotoSans-Regular.ttf"), juste en gras — d'où le nom trompeur
-- "Police alternative" qui ne changeait en fait que la graisse.
-- Remplacée ici par "NotoSerif-Regular.ttf", une police RÉELLEMENT différente
-- (serif, donc visuellement bien distincte de NotoSans) : ce nom de fichier
-- est explicitement référencé dans font.lua (table _bold_font_variant, avec
-- son pendant "NotoSerif-Bold.ttf"), donc bundlée par KOReader au même titre
-- que NotoSans.
-- À VÉRIFIER SUR CET APPAREIL : si malgré tout NotoSerif-Regular.ttf n'est
-- pas présent dans ta build (certaines builds allégées suppriment des
-- polices), le texte tombera en général sur une police de repli plutôt que
-- de planter — mais teste et dis-moi si "Police Serif" ne change rien à
-- l'affichage, je remplacerai par un autre nom de fichier bundlé chez toi.
-- Liste des polices du lecteur.
-- On récupère les polices réellement visibles par KOReader (polices intégrées
-- + polices ajoutées par l'utilisateur/système). Cela permet d'en proposer
-- bien plus que 2, et surtout d'éviter de sélectionner une police inexistante.
local function build_font_faces()
    local faces = {
        { id = "cfont", label = T("Noto Sans (système)") },
        { id = "NotoSerif-Regular.ttf", label = "Noto Serif" },
    }
    local seen = {
        ["cfont"] = true,
        ["NotoSerif-Regular.ttf"] = true,
    }

    -- KOReader expose ici les polices réellement installées (fonts/ et
    -- dossier de polices externe). Pour les polices externes, on conserve le
    -- chemin complet : Font:getFace() sait ensuite ouvrir directement ce chemin.
    local ok, FontList = pcall(require, "fontlist")
    if ok and FontList then
        local ok_list, paths = pcall(function() return FontList:getFontList() end)
        if ok_list and type(paths) == "table" then
            local candidates = {}
            for _, path in ipairs(paths) do
                local filename = tostring(path):match("([^/]+)$") or tostring(path)
                if filename ~= "" and not seen[path] then
                    local label = filename
                    local info = FontList.fontinfo and FontList.fontinfo[path]
                    if info and info[1] then
                        label = info[1].name or filename
                        local localized = pcall(function()
                            return FontList:getLocalizedFontName(path, 0)
                        end)
                        if localized then
                            local ok_local, local_name = pcall(function()
                                return FontList:getLocalizedFontName(path, 0)
                            end)
                            if ok_local and local_name and local_name ~= "" then
                                label = local_name
                            end
                        end
                    end
                    table.insert(candidates, { id = path, label = label })
                end
            end
            table.sort(candidates, function(a, b)
                return a.label:lower() < b.label:lower()
            end)
            for _, item in ipairs(candidates) do
                if not seen[item.id] then
                    table.insert(faces, item)
                    seen[item.id] = true
                end
            end
        end
    end

    -- Polices intégrées de KOReader qui peuvent être utilisées même lorsqu'elles
    -- ne sont pas retournées comme fichiers externes par FontList.
    local common = {
        {"NotoSans-Bold.ttf", "Noto Sans Bold"},
        {"NotoSans-Italic.ttf", "Noto Sans Italic"},
        {"NotoSans-BoldItalic.ttf", "Noto Sans Bold Italic"},
        {"NotoSerif-Bold.ttf", "Noto Serif Bold"},
        {"NotoSerif-Italic.ttf", "Noto Serif Italic"},
        {"NotoSerif-BoldItalic.ttf", "Noto Serif Bold Italic"},
        {"DroidSansMono.ttf", "Droid Sans Mono"},
        {"NotoSansArabicUI-Regular.ttf", "Noto Sans Arabic"},
        {"NotoSansArabicUI-Bold.ttf", "Noto Sans Arabic Bold"},
        {"NotoSansDevanagariUI-Regular.ttf", "Noto Sans Devanagari"},
        {"NotoSansBengaliUI-Regular.ttf", "Noto Sans Bengali"},
        {"NotoSansCJKsc-Regular.otf", "Noto Sans CJK"},
        {"freefont/FreeSans.ttf", "FreeSans"},
        {"freefont/FreeSerif.ttf", "FreeSerif"},
        {"nerdfonts/symbols.ttf", "Nerd Fonts Symbols"},
    }
    for _, item in ipairs(common) do
        if not seen[item[1]] then
            table.insert(faces, { id = item[1], label = item[2] })
            seen[item[1]] = true
        end
    end

    return faces
end

local FONT_FACES = build_font_faces()
local FONT_SIZE_MIN, FONT_SIZE_MAX, FONT_SIZE_STEP = 14, 32, 2
-- ── Interligne (5 presets nommés, du plus compact au plus aéré) ─────────────
-- Même unité que le champ `line_height` du vrai TextBoxWidget de KOReader :
-- un facteur en "em" AJOUTÉ à 1 pour obtenir la hauteur de ligne
-- (hauteur_ligne_px = (1 + line_height) * taille_police_px). 0.3 est la
-- valeur par défaut native de TextBoxWidget → preset "Normal" ci-dessous,
-- donc le rendu par défaut ne change pas tant que l'utilisateur ne touche
-- pas ce réglage. Presets à écart volontairement large (0.3-0.5 par cran)
-- pour que chaque tap donne un saut net, au lieu d'un delta continu de
-- quelques pixels (invisible sur liseuse) comme la précédente version.
local LINE_SPACING_PRESETS = {
    { label = T("Compact"), value = 0.0 },
    { label = T("Normal"),  value = 0.3 },
    { label = T("Confort"), value = 0.6 },
    { label = T("Aéré"),    value = 1.0 },
    { label = T("Large"),   value = 1.5 },
}

-- ── Largeur du texte (marge gauche/droite du bloc de texte) ─────────────────
-- P.MARGIN (ui/panel.lua) est la SEULE marge utilisée pour le bloc de texte
-- dans ce fichier (chars_per_screen, largeur du ScrollTextWidget, span
-- gauche de text_row) : elle ne sert à rien d'autre ici, donc on peut la
-- remplacer partout par text_margin() sans toucher le reste de l'UI.
-- Preset "Normale" = P.MARGIN telle quelle, donc le rendu par défaut ne
-- change pas tant que l'utilisateur ne touche pas ce réglage.
local WIDTH_PRESETS = {
    { label = T("Large"),   margin = math.max(0, P.MARGIN - Screen:scaleBySize(15)) },
    { label = T("Normale"), margin = P.MARGIN },
    { label = T("Confort"), margin = P.MARGIN + Screen:scaleBySize(30) },
    { label = T("Étroite"), margin = P.MARGIN + Screen:scaleBySize(70) },
}

local _font_face_idx     = 1
local _font_size         = READER_FONT_SIZE
local _line_spacing_idx  = 2 -- "Normal" (0.3 = défaut natif TextBoxWidget)
local _width_idx         = 2 -- "Normale"

local function line_spacing()
    return LINE_SPACING_PRESETS[_line_spacing_idx].value
end

local function text_margin()
    return WIDTH_PRESETS[_width_idx].margin
end

-- ── Persistance des réglages (survit à un redémarrage de l'appareil) ────────
-- Utilise G_reader_settings, le magasin de réglages GLOBAL de KOReader (déjà
-- initialisé par reader.lua au démarrage, sérialisé dans
-- <DataDir>/settings.reader.lua) au lieu d'un stockage maison : c'est le
-- mécanisme standard déjà utilisé par tous les modules ReaderXxx du cœur
-- KOReader (ex. readerdictionary.lua) pour des réglages simples clé/valeur,
-- et il survit nativement aux redémarrages de l'appli ET de l'appareil.
-- On appelle flush() juste après CHAQUE changement pour écrire tout de suite
-- sur le disque (pas seulement à la fermeture propre de l'appli) : sur
-- liseuse, un redémarrage peut très bien survenir sans arrêt "propre" de
-- KOReader (batterie à plat, plantage, redémarrage forcé…).
local SETTINGS_KEY_FACE_IDX     = "sefirah_font_face_idx"
local SETTINGS_KEY_FONT_SIZE    = "sefirah_font_size"
local SETTINGS_KEY_LINE_SPACING = "sefirah_line_spacing"
local SETTINGS_KEY_WIDTH_IDX    = "sefirah_width_idx"
local SETTINGS_KEY_NIGHT_MODE   = "sefirah_night_mode"

local function load_reader_settings()
    if not G_reader_settings then return end -- pas encore initialisé (ne devrait pas arriver ici)
    local idx = G_reader_settings:readSetting(SETTINGS_KEY_FACE_IDX)
    if idx and FONT_FACES[idx] then _font_face_idx = idx end
    local size = G_reader_settings:readSetting(SETTINGS_KEY_FONT_SIZE)
    if size then
        _font_size = math.max(FONT_SIZE_MIN, math.min(FONT_SIZE_MAX, size))
    end
    local spacing_idx = G_reader_settings:readSetting(SETTINGS_KEY_LINE_SPACING)
    -- Ancienne version : stockait un float continu (ex. 0.3) sous cette même
    -- clé. Un float ne correspond à aucun index valide de LINE_SPACING_PRESETS
    -- (table 1..5), donc la condition ci-dessous l'ignore silencieusement et
    -- l'index par défaut (2 = "Normal") reste en place — migration sans casse.
    if spacing_idx and LINE_SPACING_PRESETS[spacing_idx] then _line_spacing_idx = spacing_idx end
    local width_idx = G_reader_settings:readSetting(SETTINGS_KEY_WIDTH_IDX)
    if width_idx and WIDTH_PRESETS[width_idx] then _width_idx = width_idx end
    -- Le mode nuit est géré par core/night.lua (inversion de tout l'écran) :
    -- ne plus colorer le lecteur lui-même, ce serait une double inversion.
    _night_mode = false
end

local function save_reader_settings()
    if not G_reader_settings then return end
    G_reader_settings:saveSetting(SETTINGS_KEY_FACE_IDX, _font_face_idx)
    G_reader_settings:saveSetting(SETTINGS_KEY_FONT_SIZE, _font_size)
    G_reader_settings:saveSetting(SETTINGS_KEY_LINE_SPACING, _line_spacing_idx)
    G_reader_settings:saveSetting(SETTINGS_KEY_WIDTH_IDX, _width_idx)
    G_reader_settings:saveSetting(SETTINGS_KEY_NIGHT_MODE, _night_mode)
    G_reader_settings:flush()
end

load_reader_settings() -- restaure les valeurs sauvegardées dès le chargement de ce module

-- Longueur en CARACTÈRES utf8, pas en octets. C'était le vrai bug : l'opérateur
-- Lua `#` compte les OCTETS, alors que ScrollTextWidget:getCharPos() renvoie une
-- position dans self.charlist (un index de CARACTÈRE, cf. TextBoxWidget). Sur du
-- texte français plein d'accents (é, à, è, ç, ê, î, ô, œ… — 2 octets chacun en
-- UTF-8), #text gonflait la longueur totale d'environ 10-20 %, ce qui faussait
-- à la fois le nombre total de pages ET la page courante (les deux compteurs
-- n'utilisaient pas la même unité que charpos).
local function utf8_len(s)
    local len = 0
    for _ in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        len = len + 1
    end
    return len
end

-- Renvoie (page_courante, pages_totales) pour le widget de défilement actuel.
--
-- IMPORTANT — pourquoi l'estimation par caractères ne suffit pas :
-- chars_per_screen() est une approximation (police proportionnelle, largeur
-- moyenne de caractère arbitraire) qui peut aboutir à un "per_page" trop
-- grand par rapport à ce que le widget fait réellement défiler à chaque
-- onScrollUp()/onScrollDown(). Résultat concret : charpos avance bien à
-- chaque tap/swipe, mais pas assez pour franchir le seuil `per_page` →
-- current_page reste identique pendant plusieurs tourne-pages d'affilée,
-- ce qui donne l'impression que le compteur "ne change pas".
--
-- v_scroll_bar.low / .high sont mis à jour par
-- ScrollTextWidget:updateScrollBar(), appelée à CHAQUE onScrollUp/onScrollDown
-- (que le scrollbar soit affiché ou non — on ne fait que masquer son rendu
-- plus haut, pas son calcul). (low, high) = fraction du texte total
-- actuellement visible à l'écran : c'est une mesure directe du défilement
-- réel, contrairement au comptage de caractères. Cette version s'en sert en
-- priorité, et ne retombe sur l'ancienne estimation que si le scrollbar
-- n'est pas disponible.
--
-- À VÉRIFIER : je n'ai pas pu confirmer les noms exacts des champs
-- (low/high) sur ce device — si le compteur ne bouge toujours pas après ce
-- changement, ajoute un print(pairs(_scroll_w.v_scroll_bar)) ou regarde
-- frontend/ui/widget/verticalscrollbar.lua pour voir comment le scrollbar
-- stocke sa position (peut-être .low/.high, peut-être des noms différents).
-- Renvoie (page_courante, pages_totales, ready). `ready` = false quand la
-- mesure n'est pas fiable (widget pas encore mis en page : juste après
-- l'ouverture d'un chapitre, avant que vertical_string_list/lines_per_page
-- soient calculés). Dans ce cas la fonction renvoie (1, 1) par défaut pour
-- l'affichage (l'indicateur de page a besoin de DEUX nombres, même
-- approximatifs, dès la 1ère image) — mais (1, 1) qui ressemble à "page 1
-- sur 1 = terminé" ne doit JAMAIS être écrit dans le cache de progression :
-- les appelants qui SAUVEGARDENT (cache_current_position, save_current_progress)
-- vérifient `ready` et n'écrivent rien s'il est faux, pour ne pas écraser
-- une vraie progression (ex. 4/25) par une fausse coche ✓.
local function compute_page_progress()
    if not _scroll_w or not _scroll_w.text_widget then
        return 1, 1, false
    end

    -- ScrollTextWidget uses real logical lines, not the scrollbar's
    -- floating-point size, to perform a page turn:
    --   scrollDown() += lines_per_page
    --   scrollUp()   -= lines_per_page
    --
    -- Using v_scroll_bar.high - low here was wrong: those values are
    -- normalized positions and can produce absurd totals (9/9 -> 141/141)
    -- depending on the exact text layout.
    local tw = _scroll_w.text_widget
    local total_lines = #(tw.vertical_string_list or {})
    local lines_per_page = tw.lines_per_page or 1

    if total_lines <= 0 then
        return 1, 1, false
    end

    local total_pages = math.max(
        1,
        1 + math.floor((total_lines - 1) / lines_per_page)
    )

    local current_line = tw.virtual_line_num or 1
    local current_page = 1 + math.floor((current_line - 1) / lines_per_page)

    -- The final view can be shorter than a complete page. Clamp it to the
    -- actual last page instead of creating a fake extra page.
    current_page = math.max(1, math.min(total_pages, current_page))

    return current_page, total_pages, true
end

-- Ligne centrée "page / total" — même style que le "N / M" déjà utilisé par
-- P.makeNavBar ailleurs dans l'app (texte gris, gras).
-- Demandé (2026-09-12) : le badge "💬 + nombre d'avis" (tapable, ouvrait la
-- liste des paragraphes commentés via ReaderView.openChapterMarks()) est
-- retiré — la ligne redevient un simple "N / M", sans rien de tapable. Les
-- icônes comment.png superposées directement sur chaque paragraphe commenté
-- (build_comment_overlays plus haut) restent, elles, inchangées : c'est un
-- mécanisme séparé, toujours le point d'entrée pour ouvrir le fil d'UN
-- paragraphe précis.
-- on_tap_comments (optionnel) : callback appelé au tap sur l'indicateur.
-- Fourni uniquement pour les sources à panneau de commentaires de chapitre
-- séparé (ext.chapterCommentsPanel, cf. royalroad.lua/novelfire.lua) — pas
-- pour novelfrance, dont les commentaires de fin de chapitre sont déjà
-- injectés en texte dans le chapitre (pas besoin d'un second point d'entrée).
-- Le préfixe "Avis" signale que la ligne est tapable — un emoji (💬, comme
-- utilisé ici avant, ou 👍/👎 ailleurs dans l'app, cf. detail.lua) ne
-- s'affiche pas sur l'écran e-ink de la liseuse et ressort en "?" (signalé
-- 2026-09-15) : un mot en texte simple reste le seul choix fiable.
local function make_page_indicator(current_page, total_pages, chapter_marks, on_tap_comments)
    local face = Font:getFace("cfont", 18)
    -- « 1 / 19 » : le texte central reste tapable (commentaires) quand
    -- on_tap_comments est fourni ; « et » aux extrémités sautent à la
    -- première / dernière page du chapitre.
    local label_text = string.format("%d / %d", current_page, total_pages)
    local page_lbl = TextWidget:new{
        text    = label_text,
        face    = face,
        bold    = true,
        fgcolor = Blitbuffer.COLOR_GRAY,
    }
    local edge_w = math.floor(P.W * 0.14)
    local mid_w  = P.W - 2 * edge_w

    local function make_edge(label, enabled, cb, w)
        local txt = TextWidget:new{
            text    = label,
            face    = Font:getFace("cfont", 22),
            bold    = true,
            fgcolor = enabled and fg_color() or Blitbuffer.COLOR_GRAY,
        }
        local frame = FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            width      = w,
            height     = PAGE_IND_H,
            background = bg_color(),
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = PAGE_IND_H },
                txt,
            },
        }
        if enabled then return P.wrapTappable(frame, cb) end
        return frame
    end

    local center = FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        width      = mid_w,
        height     = PAGE_IND_H,
        background = bg_color(),
        CenterContainer:new{
            dimen = Geom:new{ w = mid_w, h = PAGE_IND_H },
            page_lbl,
        },
    }
    if on_tap_comments then
        center = P.wrapTappable(center, on_tap_comments)
    end

    return HorizontalGroup:new{
        make_edge("«", current_page > 1, function() ReaderView.firstPage() end, edge_w),
        center,
        make_edge("»", current_page < total_pages, function() ReaderView.lastPage() end, P.W - edge_w - mid_w),
    }
end

local function make_nav_row(chapter_idx, total)
    local has_prev = get_adjacent_index(-1) ~= nil
    local has_next = get_adjacent_index(1) ~= nil
    local half_w = math.floor(P.W / 2)
    return require("ui/widget/verticalgroup"):new{
        align = "left",
        P.hairline(),
        HorizontalGroup:new{
            make_nav_button(T("Chap. précédent"), has_prev, function() ReaderView.prevChapter() end, half_w),
            make_nav_button(T("Chap. suivant"),   has_next, function() ReaderView.nextChapter() end, P.W - half_w),
        },
    }
end

-- ── Icône Réglages (⚙) superposée sur la barre de titre ─────────────────────
-- Avant : bande dédiée sous le titre (make_settings_row), qui prenait sa
-- propre ligne. Maintenant : l'icône est superposée en haut à droite, SUR LA
-- MÊME LIGNE que le titre du chapitre, via OverlapGroup (empile des widgets
-- les uns sur les autres au lieu de les mettre bout à bout).
--
-- Vérifié contre le vrai frontend/ui/widget/overlapgroup.lua de KOReader :
--  - `overlap_align = "right"` aligne seulement horizontalement (peint
--    toujours à y = y du parent, donc collé en HAUT) ;
--  - seul `overlap_offset = {dx, dy}` donne un contrôle explicite des DEUX
--    axes — mais il est ignoré si overlap_align est aussi présent (l'un ou
--    l'autre, pas les deux). On utilise donc overlap_offset seul ci-dessous.
-- À VÉRIFIER / À AJUSTER : P.makeTitleBar (ui/panel.lua) n'est pas
-- disponible ici, donc sa hauteur exacte et son padding interne ne sont pas
-- connus — GEAR_TOP_OFFSET est une estimation. Si l'icône n'est pas bien
-- centrée verticalement à côté du titre, ajuste juste cette constante.
--
-- "⚙" (U+2699) plutôt que "Aa" : c'est ce que tu as demandé, mais attention,
-- contrairement à "Aa" (2 lettres latines, garanties dans n'importe quelle
-- police), ce glyphe n'est pas forcément inclus dans la police embarquée
-- si elle a été allégée pour l'e-ink (sous-ensemble de caractères réduit).
-- Si tu vois un carré vide/tofu à la place de l'engrenage, dis-le-moi : je
-- remplacerai par un autre caractère (ex. "⛭") ou reviendrai à du texte.
local GEAR_TOP_OFFSET = Screen:scaleBySize(8) -- À VÉRIFIER / À AJUSTER

local function make_settings_gear_button(row_h)
    local face = Font:getFace("cfont", 24)
    local txt = TextWidget:new{
        text    = "⚙",
        face    = face,
        bold    = true,
        fgcolor = fg_color(),
    }
    local frame = FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        width      = GEAR_BTN_SIZE,
        height     = GEAR_BTN_SIZE,
        background = bg_color(),
        CenterContainer:new{
            dimen = Geom:new{ w = GEAR_BTN_SIZE, h = GEAR_BTN_SIZE },
            txt,
        },
    }
    local tappable = P.wrapTappable(frame, function() ReaderView.openSettings() end)
    -- Table Lua ordinaire : on peut lui ajouter ces champs même si on ne
    -- connaît pas le type exact renvoyé par wrapTappable (déjà utilisé tel
    -- quel comme enfant direct de HorizontalGroup ailleurs dans ce fichier,
    -- donc on sait qu'il se comporte comme un widget peignable normal).
    local gear_y = row_h and math.max(0, math.floor((row_h - GEAR_BTN_SIZE) / 2)) or GEAR_TOP_OFFSET
    tappable.overlap_offset = { P.W - GEAR_BTN_SIZE, gear_y }
    return tappable
end

-- Équivalent coloré de P.makeTitleBar (ui/panel.lua), pour la barre de titre
-- du lecteur ET celle du panneau Réglages.
--
-- Parcourir/Sources et code ses couleurs en dur (Blitbuffer.COLOR_WHITE/texte
-- Ici, seules les zones vides autour du titre (eat_tap, plus bas) suivaient
-- bg_color()/fg_color() : la flèche retour ET le texte du titre restaient
-- donc dans un rectangle BLANC fixe, même écran totalement inversé autour —
-- l'impression que la fonctionnalité ne marche pas. On ne touche pas à
-- localement la même mise en page avec bg_color()/fg_color().
local function make_reader_title_bar(title, on_back)
    local H, title_w = title_row_metrics(title)
    local bface = Font:getFace("cfont", 22)
    local BTN_W = Screen:scaleBySize(48)
    local spacer_w = BTN_W

    local function btn_frame(text_str, cb)
        local btn = TextWidget:new{ text = text_str, face = bface, fgcolor = fg_color() }
        local f = FrameContainer:new{
            bordersize = 0, padding = 0,
            width = BTN_W, height = H,
            background = bg_color(),
            CenterContainer:new{ dimen = Geom:new{ w = BTN_W, h = H }, btn },
        }
        return P.wrapTappable(f, cb)
    end

    local spacer_blocker = TextWidget:new{
        text = " ", face = Font:getFace("cfont", 1), fgcolor = bg_color(),
    }
    local spacer_frame = FrameContainer:new{
        bordersize = 0, padding = 0,
        width = spacer_w, height = H,
        background = bg_color(),
        CenterContainer:new{ dimen = Geom:new{ w = spacer_w, h = H }, spacer_blocker },
    }

    -- TextBoxWidget, contrairement à TextWidget, effectue réellement le
    -- retour à la ligne. Le titre reste donc entièrement dans la zone centrale
    -- et ne peut plus passer sous la flèche de retour ou l'engrenage.
    local title_widget = TextBoxWidget:new{
        text      = clean_reader_title(title),
        face      = Font:getFace("cfont", 18),
        bold      = true,
        width     = title_w,
        height    = H - Screen:scaleBySize(4),
        alignment = "center",
    }
    local title_frame = FrameContainer:new{
        bordersize = 0, padding = 0,
        width = title_w, height = H,
        background = bg_color(),
        CenterContainer:new{ dimen = Geom:new{ w = title_w, h = H }, title_widget },
    }

    return HorizontalGroup:new{
        btn_frame("←", on_back),
        title_frame,
        spacer_frame,
    }
end

-- Combine la barre de titre (bouton retour + nom du chapitre) et l'icône
-- Réglages, superposées sur la même ligne.
local function make_title_row(title)
    -- Zone de fermeture historique : on garde exactement le même découpage
    -- eat_tap qu'avant (comportement de tap inchangé) — seul le rendu de la
    -- barre elle-même change (cf. make_reader_title_bar ci-dessus) pour que
    -- aux zones vides autour.
    local row_h = title_row_metrics(title)
    _title_extra_h = math.max(0, row_h - P.TITLE_H)
    local title_bar = make_reader_title_bar(title, function() ReaderView.close() end)

    local function eat_tap(x, width)
        -- IMPORTANT : FrameContainer ne doit pas être vide. Sur certaines builds
        -- Kobo, wrapTappable() appelle getSize() sur son enfant et un frame vide
        -- provoque exactement le crash framecontainer.lua:55 observé à l'ouverture
        -- d'un chapitre. On lui donne donc un contenu transparent de taille connue.
        local blocker = TextWidget:new{
            text = " ",
            face = Font:getFace("cfont", 1),
            fgcolor = bg_color(),
        }
        local frame = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            width = width,
            height = Screen:scaleBySize(48),
            background = bg_color(),
            CenterContainer:new{
                dimen = Geom:new{ w = width, h = Screen:scaleBySize(48) },
                blocker,
            },
        }
        local tappable = P.wrapTappable(frame, function() return true end)
        tappable.overlap_offset = { x, GEAR_TOP_OFFSET }
        return tappable
    end

    -- Le titre est centré : on laisse une bande suffisamment large pour son
    -- texte et bloque les deux côtés. Le côté droit s'arrête avant l'engrenage.
    local arrow_zone_w = Screen:scaleBySize(64)
    local title_start_x = math.floor((P.W - TITLE_ACTIVE_W) / 2)
    local left_block_x = arrow_zone_w
    local left_block_w = math.max(0, title_start_x - arrow_zone_w)
    local right_block_x = math.floor((P.W + TITLE_ACTIVE_W) / 2) + Screen:scaleBySize(4)
    local right_block_w = math.max(0, P.W - GEAR_BTN_SIZE - right_block_x)

    return OverlapGroup:new{
        title_bar,
        eat_tap(left_block_x, left_block_w),
        eat_tap(right_block_x, right_block_w),
        make_settings_gear_button(row_h),
    }
end

-- ── Cartes arrondies du panneau Réglages (icône · libellé centré · chevrons) ──
local _RS_ROOT = (debug.getinfo(1, "S").source:match("^@(.*)/ui/[^/]*$")) or "."

local function rs_icon(name)
    local suffix = _night_mode and "_n" or ""
    return _RS_ROOT .. "/resources/rs_" .. name .. suffix .. ".png"
end

local function make_settings_card(opts)
    local margin  = Screen:scaleBySize(12)
    local border  = Screen:scaleBySize(1)
    local H       = NAV_BTN_H
    local gap     = Screen:scaleBySize(6)
    local inner_w = P.W - 2 * margin - 2 * border
    local face    = Font:getFace("cfont", 20)

    local function zone(w, child, cb)
        local f = FrameContainer:new{
            bordersize = 0, padding = 0, background = bg_color(),
            CenterContainer:new{ dimen = Geom:new{ w = w, h = H }, child },
        }
        return cb and P.wrapTappable(f, cb) or f
    end

    local function chevron(txt)
        return TextWidget:new{ text = txt, face = Font:getFace("cfont", 26), fgcolor = fg_color() }
    end

    local row
    if opts.header then
        row = zone(inner_w, TextWidget:new{
            text = opts.label, face = Font:getFace("cfont", 21), bold = true, fgcolor = fg_color(),
            max_width = inner_w - 2 * margin,
        }, opts.on_tap)
    else
        local icon_w  = Screen:scaleBySize(64)
        local chev_w  = opts.on_prev and Screen:scaleBySize(100) or Screen:scaleBySize(56)
        local label_w = inner_w - icon_w - chev_w
        local icon = ImageWidget:new{
            file = rs_icon(opts.icon), alpha = true, scale_factor = 0,
            width = Screen:scaleBySize(28), height = Screen:scaleBySize(28),
            -- Mode nuit = inversion de tout l'écran (core/night.lua) : l'icône
            -- noire doit s'inverser avec lui (→ blanche). Avec la valeur par
            -- défaut (true), KOReader la ré-inverse et elle reste noire sur noir.
            original_in_nightmode = false,
        }
        local label = TextWidget:new{
            text = opts.label, face = face, fgcolor = fg_color(),
            max_width = label_w - gap,
        }
        local chevrons
        if opts.on_prev then
            local half = math.floor(chev_w / 2)
            chevrons = HorizontalGroup:new{
                zone(half, chevron("‹"), opts.on_prev),
                zone(chev_w - half, chevron("›"), opts.on_next),
            }
        else
            chevrons = zone(chev_w, chevron("›"), opts.on_next)
        end
        row = HorizontalGroup:new{
            zone(icon_w, icon, opts.on_next),
            zone(label_w, label, opts.on_next),
            chevrons,
        }
    end

    local card = FrameContainer:new{
        bordersize = border, radius = Screen:scaleBySize(10), padding = 0, margin = 0,
        color = Blitbuffer.COLOR_GRAY, background = bg_color(),
        row,
    }
    return HorizontalGroup:new{
        HorizontalSpan:new{ width = margin },
        card,
        HorizontalSpan:new{ width = margin },
    }
end

-- ── Préchargement du chapitre suivant (objectif « fluidité ») ────────────────

local function prefetch_next()
    -- File de téléchargement (core/dlqueue.lua) : garde N chapitres d'avance
    -- (réglage « Télécharger d'avance en lisant »), sans jamais rallumer le Wi-Fi.
    -- Repli sur l'ancien préchargement d'un seul chapitre si le module échoue.
    local ok_q = pcall(function() require("core.dlqueue").prefetchAhead(_ctx) end)
    if ok_q then return end
    local nxt = _ctx.chapters[_ctx.index + (_ctx.step or 1)]
    if not nxt then return end
    if Cache.isChapterCached(_ctx.source_id, _ctx.novel.path, nxt.path or nxt.sourceUrl) then return end
    UIManager:scheduleIn(0.3, function()
        Cache.downloadChapterAsync(_ctx.ext, _ctx.source_id, _ctx.novel.path, nxt, function() end)
    end)
end

-- Le geste vertical global de sortie est maintenant géré par ui/panel.lua
-- pour TOUS les écrans Sefirah, pas seulement le lecteur de chapitre.

-- ── Zones tactiles : moitié droite = page suivante, moitié gauche = précédente ─
local function wire_gestures(panel)
    panel.ges_events = panel.ges_events or {}
    panel.ges_events.Tap = {
        GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = P.W, h = P.H } }
    }
    panel.onTap = function(_, ges)
        local x = (ges and ges.pos and ges.pos.x) or (P.W / 2)
        if x < P.W / 2 then ReaderView.prevPage() else ReaderView.nextPage() end
        return true
    end
    _gestures_wired = true
end

-- Déclaration anticipée : ScrollTextWidget appelle scroll_callback après
-- chaque défilement, y compris les taps. Le callback doit donc pouvoir
-- rafraîchir l'indicateur même si le tap est consommé directement par
-- ScrollTextWidget (et n'arrive jamais jusqu'au panel).
local refresh_page_indicator
local function notify_detail_progress()
    -- Le lecteur et la liste des chapitres utilisent le même Cache. On notifie
    -- Detail après l'écriture de la progression pour que l'écran soit déjà
    -- synchronisé dès qu'on y revient, sans action manuelle.
    local ok, Detail = pcall(require, "ui.detail")
    if ok and Detail and Detail.refreshChapterProgress then
        UIManager:scheduleIn(0, function()
            pcall(Detail.refreshChapterProgress)
        end)
    end
end

local function cache_current_position()
    if _restoring_position then return end
    if not _ctx or not _scroll_w then return end
    local chapter = _ctx.chapters[_ctx.index]
    if not chapter then return end
    local key = chapter.path or chapter.sourceUrl or ""
    local charpos, top_line_num = _scroll_w:getCharPos()
    local total_chars = utf8_len(_scroll_w.text or "")
    local percent = (charpos and total_chars > 0) and (charpos / total_chars) or 0
    local current_page, total_pages, ready = compute_page_progress()
    if not ready then return end -- widget pas encore mis en page : ne pas écraser une progression valide par une fausse mesure
    local completed = current_page >= total_pages
    Cache.setProgress(_ctx.source_id, _ctx.novel.path or "", key, percent, current_page, total_pages, completed, charpos, top_line_num)
end

-- Reprise fiable par page.
-- KOReader peut accepter charpos/top_line_num à la construction mais, selon la
-- version/layout, la position peut être recalculée après init. Ici on utilise
-- la même primitive que le tourne-page normal. Les tours sont exécutés dans
-- une seule callback UI : l'utilisateur ne voit donc pas 5, 6, 7 rafraîchissements
-- intermédiaires, seulement la page finale.
local function restore_saved_page(resume)
    local wanted = resume and tonumber(resume.current_page)
    if not wanted or wanted <= 1 or not _scroll_w then
        return
    end

    _restoring_position = true
    local target = math.max(1, math.floor(wanted))
    local safety = 0

    while safety < target - 1 do
        safety = safety + 1
        local ok, moved = pcall(function()
            return _scroll_w:onScrollDown()
        end)
        if not ok or not moved then
            break
        end
    end

    _restoring_position = false

    -- Recalcule immédiatement l'indicateur et persiste la position réellement
    -- atteinte. Aucun téléchargement/reparse supplémentaire n'est effectué.
    if _scroll_w then
        local chapter = _ctx and _ctx.chapters[_ctx.index]
        if chapter and _ctx then
            local key = chapter.path or chapter.sourceUrl or ""
            local cp, tp, ready = compute_page_progress()
            if ready then
                local charpos, top_line_num = _scroll_w:getCharPos()
                local total_chars = utf8_len(_scroll_w.text or "")
                local percent = (charpos and total_chars > 0) and (charpos / total_chars) or 0
                Cache.setProgress(_ctx.source_id, _ctx.novel.path or "", key,
                    percent, cp, tp, cp >= tp, charpos, top_line_num)
            end
        end
    end
end

-- Retour des Réglages de lecture : le chapitre est reconstruit (police, taille, interligne…), donc le
-- découpage en pages change. On retrouve la bonne page à partir de la position en lignes (fraction du
-- chapitre) au lieu de repartir de la page 1. Sans réglage modifié, on retombe exactement sur la même page.
local function restore_to_fraction(frac)
    frac = tonumber(frac)
    if not frac or frac <= 0 or not _scroll_w or not _scroll_w.text_widget then return end
    local tw = _scroll_w.text_widget
    local total_lines = #(tw.vertical_string_list or {})
    local lpp = tw.lines_per_page or 1
    if total_lines <= 0 then return end
    local target_line = math.floor(frac * total_lines + 0.5)
    local target = 1 + math.floor(target_line / math.max(1, lpp))
    _restoring_position = true
    local guard = 0
    while guard < 2000 do
        guard = guard + 1
        local cp, tp, ready = compute_page_progress()
        if not ready then break end
        target = math.max(1, math.min(tp, target))
        if cp == target then break end
        local ok, moved = pcall(function()
            if cp < target then return _scroll_w:onScrollDown() end
            return _scroll_w:onScrollUp()
        end)
        if not ok or not moved then break end
    end
    _restoring_position = false
    local chapter = _ctx and _ctx.chapters[_ctx.index]
    if chapter then
        local cp, tp, ready = compute_page_progress()
        if ready then
            local charpos, top_line_num = _scroll_w:getCharPos()
            local total_chars = utf8_len(_scroll_w.text or "")
            local percent = (charpos and total_chars > 0) and (charpos / total_chars) or 0
            Cache.setProgress(_ctx.source_id, _ctx.novel.path or "", chapter.path or chapter.sourceUrl or "",
                percent, cp, tp, cp >= tp, charpos, top_line_num)
        end
    end
end

-- ── Icônes de commentaires directement à côté des paragraphes ─────────────
-- BUG CORRIGÉ (2026-09-12) : même bug de double antislash que
-- novelfrance.lua:utf8_prefix (voir son commentaire) — "\\1" au lieu de
-- "\1" produisait une classe de caractères sans rapport avec de l'UTF-8,
-- qui tronquait `needle` à un seul caractère pour tout texte accentué,
-- avant même le passage dans find_comment_mark_charpos. Les deux bugs
-- combinés (ici ET dans novelfrance.lua) empêchaient purement et
-- simplement toute icône 💬 de s'afficher pour un paragraphe français
-- normal.
local function utf8_sub(s, n)
    if not s or n <= 0 then return "" end
    local out, count = {}, 0
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > n then break end
        table.insert(out, c)
    end
    return table.concat(out)
end

-- BUG CORRIGÉ (2026-09-12) : certains paragraphes commentés n'affichaient
-- jamais leur icône 💬, même avec un `mark.needle` correct venant de
-- novelfrance.lua. Cause : `needle` est construit côté novelfrance.lua avec
-- TOUT run d'espaces/tabulations/retours à la ligne réduit à un simple
-- espace (`(clean_content or ""):gsub("%s+", " ")`), mais le texte réel
-- affiché ici (`scroll_widget.text`, sorti de Epub.html_to_text) ne subit
-- PAS la même normalisation : un retour à la ligne interne à UN paragraphe
-- (dialogue/poème sur plusieurs lignes dans le HTML source) reste un `\n`
-- littéral dans le texte final, jamais réduit à un espace. Une recherche
-- exacte en texte brut (`plain = true`) ne matchait donc jamais ces
-- paragraphes-là — échec silencieux, sans log, puisque build_comment_overlays
-- se contente de sauter le mark si find_comment_mark_charpos renvoie nil.
-- Fix : on transforme `needle` en pattern Lua où chaque espace (donc aussi
-- chaque endroit qui était à l'origine un \n/\t/plusieurs espaces avant la
-- normalisation ci-dessus) accepte n'importe quelle suite d'espaces blancs
-- (`%s+`) dans le texte réel, et on échappe tous les caractères spéciaux
-- Lua restants pour que ponctuation/parenthèses/etc. soient toujours
-- cherchés tels quels.
local function find_comment_mark_charpos(text, needle, from_byte)
    -- Le texte affiché par Epub.html_to_text peut légèrement différer du
    -- contenu source (retours à la ligne, espaces ajoutés/supprimés autour
    -- des balises HTML, etc.). Une recherche avec les 80 premiers caractères
    -- échoue donc parfois alors que le paragraphe est bien présent.
    --
    -- On essaie d'abord le repère complet, puis des préfixes de plus en plus
    -- courts. Cela permet de retrouver TOUS les repères sans changer leur
    -- ordre : from_byte reste toujours la position du repère précédent.
    needle = (needle or ""):gsub("%s+", " ")
    if needle == "" then return nil end

    local from = from_byte or 1
    local lengths = { 80, 60, 45, 32, 24 }
    for _, wanted_len in ipairs(lengths) do
        local candidate = utf8_sub(needle, wanted_len)
        if candidate ~= "" then
            local pattern = candidate:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
            pattern = pattern:gsub(" ", "%%s+")
            local byte_pos, end_byte = text:find(pattern, from)
            if byte_pos then
                return utf8_len(text:sub(1, byte_pos - 1)) + 1, end_byte + 1
            end
        end
    end

    -- Dernier secours : le début du repère peut être précédé d'une
    -- ponctuation/espace produit par html_to_text. On retente avec un
    -- préfixe très court, mais toujours après le dernier repère trouvé.
    local candidate = utf8_sub(needle, 16)
    if candidate ~= "" then
        local pattern = candidate:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
        pattern = pattern:gsub(" ", "%%s+")
        local byte_pos, end_byte = text:find(pattern, from)
        if byte_pos then
            return utf8_len(text:sub(1, byte_pos - 1)) + 1, end_byte + 1
        end
    end

    return nil
end

local function build_comment_overlays(scroll_widget, marks)
    if not scroll_widget or not scroll_widget.text_widget or not marks or #marks == 0 then
        return nil, function() end
    end

    local text_widget = scroll_widget.text_widget
    local buttons, positions = {}, {}
    local search_from = 1
    -- La bulle est calée sur la hauteur RÉELLE d'une ligne de texte
    -- (line_height_px, déjà calculée par TextBoxWidget au moment où ce
    -- widget existe). Avant, badge_h (46) dépassait largement line_h
    -- (souvent ~24-30) : verticalement, la bulle débordait donc sur la
    -- ligne du dessus ET celle du dessous, ce qui donnait l'impression
    -- qu'elle était posée "sur" le paragraphe. En la contraignant à
    -- line_h, elle reste cantonnée à sa propre ligne.
    local line_h = text_widget.line_height_px or Screen:scaleBySize(24)
    local icon_size = math.max(Screen:scaleBySize(16), math.min(Screen:scaleBySize(24), line_h))
    local badge_w = Screen:scaleBySize(26)
    local badge_h = line_h
    local total_w = icon_size + Screen:scaleBySize(3) + badge_w
    local count_face = Font:getFace("cfont", 16)

    -- IMPORTANT : les boutons de commentaire sont superposés au ScrollTextWidget.
    -- Le ScrollTextWidget consomme lui-même les taps de page. S'il est placé
    -- avant les boutons dans l'arbre, il reçoit donc le tap en premier et la
    -- bulle "4" ne peut jamais ouvrir son panneau.
    --
    -- On sépare donc :
    --   1) une couche transparente InputContainer AVANT le texte -> reçoit le tap
    --   2) le texte
    --   3) la couche visuelle de la bulle APRÈS le texte -> reste visible
    --
    -- Ainsi, appuyer n'importe où sur l'icône OU sur le nombre ouvre directement
    -- le fil du BON paragraphe.
    local CommentTap = InputContainer:extend{
        width = total_w,
        height = badge_h,
        callback = nil,
    }
    function CommentTap:init()
        self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
        self.ges_events = {
            TapComment = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return self.dimen end,
                },
            },
        }
    end
    -- BUG CORRIGÉ : CommentTap n'a jamais d'enfant (self[1] == nil, c'est
    -- une couche tactile invisible). Or InputContainer:paintTo (dans le vrai
    -- KOReader) fait `if self[1] == nil then return end` AVANT la ligne qui
    -- met à jour self.dimen.x/self.dimen.y. Résultat : le dimen de CommentTap
    -- reste figé à sa valeur d'init, (x=0, y=0), quel que soit l'overlap_offset
    -- qu'on lui donne ensuite dans refresh(). La zone de tap réelle restait
    -- donc coincée en haut à gauche du panneau, jamais synchronisée avec la
    -- position affichée de la bulle "💬 4" — donc au tap sur la bulle, aucun
    -- CommentTap ne matchait, et l'événement retombait sur le ScrollTextWidget
    -- en dessous, qui l'interprétait comme un tourne-page.
    -- Fix : on définit notre propre paintTo qui met à jour dimen.x/y à chaque
    -- passage (rien à peindre, la couche visuelle séparée s'en charge).
    function CommentTap:paintTo(bb, x, y)
        self.dimen.x = x
        self.dimen.y = y
    end
    function CommentTap:onTapComment()
        if self.callback then self.callback() end
        return true
    end

    local visual_buttons = {}

    for _, mark in ipairs(marks) do
        local charpos, next_byte = find_comment_mark_charpos(
            scroll_widget.text or "", mark.needle or mark.preview, search_from)
        if charpos then
            search_from = next_byte or search_from
            local count = tonumber(mark.count) or 0
            local count_lbl = TextWidget:new{
                text = tostring(count), face = count_face, bold = true, fgcolor = fg_color(),
            }
            -- Plus de FrameContainer avec bordersize/bordercolor : c'était le
            -- "cadre noir" (bordure grise, mais très marquée sur un écran
            -- e-ink) qui encadrait comment.png. Ici, juste l'icône + le
            -- nombre, sans bordure ni fond opaque — même famille visuelle que
            -- le badge du "N / M" (make_page_indicator ci-dessus), qui n'a
            -- jamais eu ce cadre.
            local content = FrameContainer:new{
                bordersize = 0,
                padding = 0,
                width = total_w, height = badge_h,
                CenterContainer:new{
                    dimen = Geom:new{ w = total_w, h = badge_h },
                    HorizontalGroup:new{
                        ImageWidget:new{
                            file = P.ICON_COMMENT, width = icon_size, height = icon_size, scale_factor = 0,
                            original_in_nightmode = false,
                        },
                        HorizontalSpan:new{ width = Screen:scaleBySize(3) },
                        count_lbl,
                    },
                },
            }

            -- Couche tactile transparente : elle doit être placée AVANT le
            -- ScrollTextWidget pour recevoir le tap avant que celui-ci ne le
            -- transforme en changement de page.
            -- "local button; button = ..." (et non "local button = ...")
            -- exprès : le callback lit button.overlap_offset pour connaître
            -- la position ÉCRAN de la bulle au moment du tap (mise à jour à
            -- chaque refresh()) et la transmettre à openParagraphThread, qui
            -- s'en sert pour placer le panneau juste au-dessus/en dessous du
            -- paragraphe. Avec "local button = CommentTap:new{...}", la
            -- variable "button" référencée DANS la table passée en argument
            -- désignerait, en Lua, une variable extérieure (ou nil) et pas
            -- ce nouvel objet — la portée du nouveau local ne commence
            -- qu'après l'instruction complète.
            local button
            button = CommentTap:new{
                width = total_w, height = badge_h,
                callback = function()
                    if _chapter_marks and _chapter_marks.chapterId then
                        local anchor_y = button.overlap_offset and button.overlap_offset[2]
                        ReaderView.openParagraphThread(
                            _chapter_marks.chapterId, mark.id, mark.preview, anchor_y)
                    end
                end,
            }

            -- Couche visuelle indépendante, placée au-dessus du texte.
            local visual = WidgetContainer:new{ content }
            visual.dimen = Geom:new{ x = 0, y = 0, w = total_w, h = badge_h }

            button._comment_charpos = charpos
            visual._comment_charpos = charpos
            table.insert(buttons, button)
            table.insert(visual_buttons, visual)
            table.insert(positions, { button = button, visual = visual, charpos = charpos })
        end
    end

    local function refresh()
        local current_line = tonumber(text_widget.virtual_line_num) or 1
        local line_h = text_widget.line_height_px or Screen:scaleBySize(24)
        local tw_width = text_widget.width or (P.W - 2 * text_margin())
        local left = text_margin()
        local lines_per_page = text_widget.lines_per_page or 1
        local vsl = text_widget.vertical_string_list or {}
        -- Marge de sécurité en plus de total_w, pour ne jamais coller la
        -- bulle contre le dernier caractère d'une ligne.
        local safety_gap = Screen:scaleBySize(4)

        for _, item in ipairs(positions) do
            local line_num
            for ln, candidate in ipairs(vsl) do
                if candidate.offset and item.charpos >= candidate.offset
                        and (not candidate.end_offset or item.charpos <= candidate.end_offset + 1) then
                    line_num = ln
                    break
                end
            end

            local placed = false
            if line_num and line_num >= current_line and line_num < current_line + lines_per_page then
                -- Avant, la bulle était systématiquement posée sur la ligne
                -- où le paragraphe a été repéré, quitte à recouvrir ses
                -- derniers caractères quand cette ligne est presque pleine
                -- (pas assez de place en fin de ligne pour total_w). On
                -- cherche maintenant, à partir de cette ligne et parmi les
                -- suivantes visibles sur la même page, la première qui
                -- laisse VRAIMENT assez de place vide en fin de ligne pour
                -- toute la bulle (une ligne blanche entre deux paragraphes,
                -- largeur 0, convient toujours) — jamais par-dessus du
                -- texte, jamais hors de la page affichée (la recherche ne
                -- sort pas de current_line..current_line+lines_per_page-1).
                for probe = line_num, current_line + lines_per_page - 1 do
                    local candidate = vsl[probe]
                    local cand_width = candidate and candidate.width or 0
                    if (tw_width - cand_width) >= (total_w + safety_gap) then
                        local x = left + cand_width + Screen:scaleBySize(6)
                        x = math.min(x, P.W - text_margin() - total_w)
                        x = math.max(left, x)
                        local y = (probe - current_line) * line_h
                            + math.max(0, math.floor((line_h - badge_h) / 2))
                        item.button.overlap_offset = { x, y }
                        item.visual.overlap_offset = { x, y }
                        item.button.hide = false
                        item.visual.hide = false
                        placed = true
                        break
                    end
                end
            end

            if not placed then
                -- Aucun endroit sûr trouvé sur la page visible : on masque
                -- plutôt que de recouvrir du texte ou déborder de l'écran.
                item.button.overlap_offset = { -total_w - 20, -badge_h - 20 }
                item.visual.overlap_offset = { -total_w - 20, -badge_h - 20 }
                item.button.hide = true
                item.visual.hide = true
            end
        end
        if _panel then UIManager:setDirty("all", "partial") end
    end
    -- Les boutons transparents doivent être ajoutés AVANT le texte.
    -- Les éléments visuels sont ajoutés séparément APRÈS le texte.
    -- C'est ce qui garantit que le tap sur "💬 4" est intercepté par
    -- CommentTap au lieu d'être interprété comme un changement de page.
    return buttons, refresh, visual_buttons
end

-- ── pdp superposées pour les commentaires de fin de chapitre ───────────────
-- Même mécanique de repérage que build_comment_overlays ci-dessus
-- (find_comment_mark_charpos + recalcul de position au scroll), mais
-- purement décorative : pas de couche tactile (CommentTap), juste l'image
-- de la pdp — ou, à défaut (pas encore en cache disque, cf.
-- core/cache.lua:cache_chapter_comments qui la précharge au téléchargement
-- du chapitre), une tuile-monogramme des 2 premières lettres du pseudo,
-- même repli que P.makeSourceRow pour les avis/commentaires par paragraphe.
-- JAMAIS de réseau ici : Avatars.getCached ne lit que le cache disque.
local function avatar_or_monogram(avatar_url, author, size)
    local avatar_bb = Avatars.getCached(avatar_url, size)
    if avatar_bb then
        return ImageWidget:new{ image = avatar_bb, width = size, height = size, scale_factor = 0 }
    end
    local initials = (author or "?"):sub(1, 2):upper()
    return FrameContainer:new{
        bordersize = 0,
        radius     = Screen:scaleBySize(6),
        width      = size,
        height     = size,
        background = Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{ w = size, h = size },
            TextWidget:new{
                text = initials, face = Font:getFace("cfont", 12),
                bold = true, fgcolor = Blitbuffer.COLOR_WHITE,
            },
        },
    }
end

local function build_avatar_overlays(scroll_widget, avatar_marks)
    if not scroll_widget or not scroll_widget.text_widget or not avatar_marks or #avatar_marks == 0 then
        return nil, function() end
    end

    local text_widget = scroll_widget.text_widget
    local visuals, positions = {}, {}
    local search_from = 1
    -- Plus grande que les icônes 💬 (16-24px) — demandé explicitement. Pas
    -- calée sur line_h : elle peut légèrement déborder sur la ligne du
    -- dessus, acceptable pour un élément purement décoratif.
    local icon_size = Screen:scaleBySize(34)

    for _, mark in ipairs(avatar_marks) do
        local charpos, next_byte = find_comment_mark_charpos(
            scroll_widget.text or "", mark.needle, search_from)
        if charpos then
            search_from = next_byte or search_from
            local content = avatar_or_monogram(mark.avatar, mark.author, icon_size)
            local visual = WidgetContainer:new{ content }
            visual.dimen = Geom:new{ x = 0, y = 0, w = icon_size, h = icon_size }
            visual._comment_charpos = charpos
            table.insert(visuals, visual)
            table.insert(positions, { visual = visual, charpos = charpos })
        end
    end

    if #positions == 0 then return nil, function() end end

    local function refresh()
        local current_line = tonumber(text_widget.virtual_line_num) or 1
        local line_h2 = text_widget.line_height_px or Screen:scaleBySize(24)
        local left = text_margin()
        local lines_per_page = text_widget.lines_per_page or 1
        local vsl = text_widget.vertical_string_list or {}

        for _, item in ipairs(positions) do
            local line_num
            for ln, candidate in ipairs(vsl) do
                if candidate.offset and item.charpos >= candidate.offset
                        and (not candidate.end_offset or item.charpos <= candidate.end_offset + 1) then
                    line_num = ln
                    break
                end
            end

            -- À GAUCHE du pseudo : toujours calée sur le bord gauche de la
            -- colonne de texte (novelfrance.lua réserve la place avec des
            -- espaces au début de la ligne "Auteur — date"), plus de
            -- recherche d'espace libre en fin de ligne.
            if line_num and line_num >= current_line and line_num < current_line + lines_per_page then
                local y = (line_num - current_line) * line_h2
                    + math.max(0, math.floor((line_h2 - icon_size) / 2))
                item.visual.overlap_offset = { left, y }
                item.visual.hide = false
            else
                item.visual.overlap_offset = { -icon_size - 20, -icon_size - 20 }
                item.visual.hide = true
            end
        end
    end

    return visuals, refresh
end

-- ── Éviter un titre "Commentaires" orphelin en bas de page ──────────────────
-- Repère le repère texte fixe "Commentaires" (toujours inséré tel quel par
-- novelfrance.lua, jamais ailleurs dans un chapitre) et, s'il ne reste pas la
-- place d'au moins le titre + un début de commentaire sur la page où il
-- tomberait, insère des lignes vides juste avant pour le pousser au tout
-- début de la page suivante. Manipule directement le texte déjà mis en page
-- (post Epub.html_to_text) : aucun rapport avec la pagination EPUB, ni avec
-- clean_html côté export (cf. ce fichier, "\n\n\n+" -> "\n\n") qui a déjà
-- joué et ne repassera pas sur ces lignes ajoutées ici.
-- Protégé par pcall côté appelant : en cas de souci (structure interne du
-- TextBoxWidget différente d'une version de KOReader à l'autre), on préfère
-- laisser "Commentaires" là où il tombe plutôt que de casser l'affichage du
-- chapitre.
local function push_comments_heading_to_next_page(scroll_widget)
    if not scroll_widget or not scroll_widget.text_widget then return end
    local tw = scroll_widget.text_widget
    local lines_per_page = tonumber(tw.lines_per_page)
    if not lines_per_page or lines_per_page < 1 then return end

    local text = scroll_widget.text or ""
    local start_byte = text:find("\nCommentaires\n", 1, true)
    if not start_byte then return end

    local vsl = tw.vertical_string_list or {}
    if #vsl == 0 then return end
    -- Position (en caractères) du "C" de "Commentaires" lui-même (juste
    -- après le \n qui précède, à start_byte).
    local charpos = utf8_len(text:sub(1, start_byte)) + 1

    local line_num
    for ln, candidate in ipairs(vsl) do
        if candidate.offset and charpos >= candidate.offset
                and (not candidate.end_offset or charpos <= candidate.end_offset + 1) then
            line_num = ln
            break
        end
    end
    if not line_num then return end

    local pos_in_page = ((line_num - 1) % lines_per_page) + 1
    -- Place minimale voulue après le titre : lui-même + au moins la ligne
    -- "Auteur — date" + une ligne de contenu du 1er commentaire.
    local MIN_LINES_AFTER_HEADING = 3
    if (lines_per_page - pos_in_page) >= MIN_LINES_AFTER_HEADING then
        return -- assez de place sur la page courante, rien à faire
    end

    local target_line = math.ceil(line_num / lines_per_page) * lines_per_page + 1
    local pad = target_line - line_num
    if pad <= 0 then return end

    local padded = text:sub(1, start_byte - 1) .. string.rep("\n", pad) .. text:sub(start_byte)
    scroll_widget.text = padded
    tw.text = padded
    tw:free()
    tw:init()
end
-- force_flash : voir le commentaire de toggle_night_mode()/reapply_reader_settings()
-- plus bas — force un rafraîchissement e-ink complet ("flashui") au lieu du
-- "partial" habituel utilisé pour les tourne-pages classiques.
local function open_index(index, resume, force_flash)
    _ctx.index = index
    local chapter = _ctx.chapters[index]
    if not chapter then return end

    local key         = Cache.chapterKey(chapter)
    local novel_path  = _ctx.novel.path or ""

    local function render_raw(html)
        if _paragraph_popup then
            UIManager:close(_paragraph_popup)
            _paragraph_popup = nil
        end
        -- Avis par paragraphe (novelfrance.lua uniquement) : extraction du
        -- trailer JSON AVANT html_to_text, qui supprime les balises
        -- `<!-- -->` mais laisserait le JSON qu'elles contiennent s'afficher
        -- tel quel comme texte brut sinon. pcall partout : un JSON mal formé
        -- (source modifiée, tronquée par la limite "-->" documentée côté
        -- novelfrance.lua…) ne doit jamais empêcher l'affichage du chapitre.
        local meta_json = html:match("<!%-%-LNREADER_META:(.-)%-%->")
        local html_body = meta_json and html:gsub("<!%-%-LNREADER_META:.-%-%->", "") or html
        _chapter_marks = nil
        if meta_json then
            local ok_j, JSON = pcall(require, "rapidjson")
            if not ok_j then JSON = require("json") end
            local ok_dec, decoded = pcall(JSON.decode, meta_json)
            if ok_dec and type(decoded) == "table" and decoded.marks then
                _chapter_marks = decoded
            else
                logger.err("Sefirah: LNREADER_META invalide pour", chapter.path or chapter.sourceUrl)
            end
        end

        local text = Epub.html_to_text(html_body)

        -- Commentaires masqués : on oublie les repères de commentaires
        -- (plus aucune bulle par paragraphe, plus aucune pdp superposée)
        -- et on coupe la section « Commentaires » que certaines sources
        -- injectent en fin de chapitre. Le repère "\nCommentaires\n" est le
        -- même que celui utilisé par push_comments_heading_to_next_page.
        if comments_hidden() then
            _chapter_marks = nil
            local cut = text:find("\nCommentaires\n", 1, true)
            if cut then
                text = text:sub(1, cut - 1)
            end
        end

        -- CORRECTIF (boutons « Chap. précédent / suivant » hors écran) :
        -- quand le titre du chapitre tient sur plusieurs lignes (ex. noms
        -- « chap 1 / volume / sous-titre »), la barre de titre est
        -- plus haute que P.TITLE_H. Avant, le ScrollTextWidget était créé avec
        -- la hauteur NON réduite (_text_area_h) alors que P.contentFrame() se
        -- cale sur la taille réelle de son contenu : le corps dépassait de
        -- l'écran de tout ce surplus de titre et poussait les deux boutons du
        -- bas hors de la zone visible (il ne restait que leur ligne de
        -- séparation). On calcule donc le surplus AVANT de créer le widget, et
        -- on utilise la même hauteur réduite (reader_text_area_h) partout.
        do
            local layout_title = chapter.name or chapter.title or (T("Chapitre ") .. index)
            _title_extra_h = math.max(0, title_row_metrics(layout_title) - P.TITLE_H)
        end

        local ScrollTextWidget = require("ui/widget/scrolltextwidget")
        _scroll_w = ScrollTextWidget:new{
            text   = text,
            face   = Font:getFace(FONT_FACES[_font_face_idx].id, _font_size),
            width  = P.W - 2 * text_margin(),
            height = reader_text_area_h() - NOVEL_TITLE_ROW_H, -- réserve pour la bande "titre du roman" (make_novel_title_row) ET le surplus de titre multi-lignes
            fgcolor = fg_color(),
            -- Reprise : si une page a été enregistrée, on repart volontairement
            -- de la page 1 puis on rejoue les tours de page AVANT que KOReader
            -- ne rende l'écran. C'est beaucoup plus fiable que charpos/top_line_num
            -- seuls, qui peuvent être recalculés différemment après la mise en page.
            -- Pour les anciennes données qui n'ont pas current_page, on conserve
            -- charpos/top_line_num comme solution de compatibilité.
            charpos = (resume and not tonumber(resume.current_page) and tonumber(resume.charpos))
                or ((resume and not tonumber(resume.current_page) and (tonumber(resume.percent) or 0) > 0)
                    and math.floor(utf8_len(text) * (tonumber(resume.percent) or 0)) or nil),
            top_line_num = (resume and not tonumber(resume.current_page)) and tonumber(resume.top_line_num) or nil,
        }

        -- BUG RÉEL DE L'INTERLIGNE / DU FOND EN MODE NUIT (vérifié dans le vrai
        -- frontend/ui/widget/scrolltextwidget.lua de KOReader, pas une supposition) :
        -- ScrollTextWidget N'HÉRITE PAS de TextBoxWidget contrairement à ce que
        -- disait l'ancien commentaire ici — il le CONTIENT :
        --   function ScrollTextWidget:init()
        --       self.text_widget = TextBoxWidget:new{ text=..., face=...,
        --           fgcolor=..., width=..., height=..., ... }
        --   end
        -- Cette liste de champs recopiés vers le TextBoxWidget interne est figée
        -- et n'inclut ni `line_height` ni `bgcolor`. Donc les passer à
        -- ScrollTextWidget:new{...} (ce que faisait l'ancien code) ne fait
        -- RIEN : ce sont des champs inertes posés sur le wrapper, jamais lus
        -- par le TextBoxWidget qui dessine vraiment le texte — celui-ci garde
        -- ses valeurs par défaut (line_height=0.3 "Normal", bgcolor=blanc),
        -- quel que soit le preset choisi dans les Réglages. `fgcolor` lui
        -- EST recopié (d'où le mode nuit qui semblait "à moitié" marcher :
        -- texte blanc sur fond resté blanc = invisible, pas juste ignoré).
        -- Le message [DEBUG] précédent ne prouvait rien : il relisait nos
        -- propres presets, jamais ce que ScrollTextWidget appliquait réellement.
        --
        -- Fix : écrire ces 2 champs directement sur le TextBoxWidget interne,
        -- puis le forcer à se relayouter — même pattern que
        -- TextBoxWidget:unfocus()/:focus() dans le vrai KOReader (free()+init()).
        _scroll_w.text_widget.line_height = line_spacing()
        _scroll_w.text_widget.bgcolor     = bg_color()
        _scroll_w.text_widget:free()
        _scroll_w.text_widget:init()

        -- Doit être fait AVANT la construction des icônes/pdp superposées
        -- (elles cherchent leur repère dans _scroll_w.text, qu'il faut donc
        -- déjà avoir sous sa forme finale, padding éventuel compris).
        pcall(push_comments_heading_to_next_page, _scroll_w)

        -- Masque la barre de défilement native (purement cosmétique — enveloppé
        -- dans un pcall pour ne jamais casser le défilement si ce champ interne
        -- change d'un côté à l'autre des versions de KOReader).
        pcall(function()
            if _scroll_w.v_scroll_bar then
                _scroll_w.v_scroll_bar.enable = false
            end
        end)

        -- Marge gauche identique à la marge droite déjà réservée par le widget
        -- (au lieu d'être collé au bord gauche de l'écran).
        local text_row = HorizontalGroup:new{
            -- Réserve aussi la marge droite dans le même conteneur que les
            -- icônes. Sans cette marge, OverlapGroup prenait seulement la
            -- largeur du texte (P.W - marge gauche) et les icônes placées
            -- dans la marge droite pouvaient être coupées sur liseuse.
            HorizontalSpan:new{ width = text_margin() },
            _scroll_w,
            HorizontalSpan:new{ width = text_margin() },
        }

        -- Les icônes comment.png sont superposées au texte, à la position du
        -- début de chaque paragraphe commenté. Elles sont donc indépendantes
        -- de la pagination et restent directement cliquables.
        local comment_buttons, refresh_comment_icons, comment_visuals = build_comment_overlays(
            _scroll_w, _chapter_marks and _chapter_marks.marks)
        _comment_buttons = comment_buttons -- couche tactile
        _comment_visuals = comment_visuals -- couche visuelle
        -- pdp de la section "Commentaires" de fin de chapitre — même
        -- principe, purement visuel (pas de couche tactile).
        local avatar_visuals, refresh_avatar_overlays = build_avatar_overlays(
            _scroll_w, _chapter_marks and _chapter_marks.chapterCommentMarks)
        _avatar_visuals = avatar_visuals
        local text_overlay_children = {}
        for _, button in ipairs(comment_buttons or {}) do
            table.insert(text_overlay_children, button)
        end
        table.insert(text_overlay_children, text_row)
        for _, visual in ipairs(comment_visuals or {}) do
            table.insert(text_overlay_children, visual)
        end
        for _, visual in ipairs(avatar_visuals or {}) do
            table.insert(text_overlay_children, visual)
        end
        local text_overlay = OverlapGroup:new(text_overlay_children)

        local title = chapter.name or chapter.title or (T("Chapitre ") .. index)
        local row_h = title_row_metrics(title)
        _title_extra_h = math.max(0, row_h - P.TITLE_H)
        local cur_page, total_pages = compute_page_progress()
        -- Démarre le décompte dès l'affichage du chapitre : sans cela, le
        -- temps passé sur la première page de chaque chapitre serait perdu
        -- (save_current_progress n'est appelée qu'au premier tourne-page).
        Stats.track(_ctx, cur_page)
        pcall(function() require("core.quests").track(_ctx, cur_page, cur_page >= total_pages, total_pages) end)
        local ext = _ctx.ext
        local on_tap_comments = (not comments_hidden())
            and (ext and ext.chapterCommentsPanel and ext.parseChapterComments and chapter.path)
            and function() ReaderView.openChapterComments(chapter) end or nil
        local body = VerticalGroup:new{
            align = "left",
            make_title_row(title),
            P.hairline(),
            P.contentFrame({ text_overlay }, reader_text_area_h()),
            make_page_indicator(cur_page, total_pages, _chapter_marks, on_tap_comments),
            make_nav_row(index, #_ctx.chapters),
        }

        if _panel then
            _panel:swapBody(body, chapter_close_guard, force_flash and "flash" or true, _nav, close_plugin_from_swipe)
        else
            _panel = P.FullScreenPanel:new{
                body = body,
                close_callback = chapter_close_guard,
                swipe_close_callback = close_plugin_from_swipe,
                partial = true,
                nav = _nav,
            }
            UIManager:show(_panel)
        end

        -- Requis par ScrollTextWidget:updateScrollBar() — sans ça, ça plante
        -- au 1er appel à scrollText/onScrollUp/onScrollDown (self.dialog.movable
        -- sur nil). Le panneau lui-même convient très bien comme "dialog".
        _scroll_w.dialog = _panel
        refresh_comment_icons()
        refresh_avatar_overlays()

        -- La mise en page du TextBoxWidget est maintenant terminée. Rejoue
        -- la page sauvegardée avant le prochain rendu UI, sans animation visible.
        if resume and tonumber(resume.line_frac) and tonumber(resume.line_frac) > 0 then
            local frac = tonumber(resume.line_frac)
            UIManager:scheduleIn(0, function()
                if _scroll_w and _ctx and _ctx.index == index then
                    restore_to_fraction(frac)
                    if refresh_page_indicator then refresh_page_indicator() end
                    if refresh_comment_icons then refresh_comment_icons() end
                    if refresh_avatar_overlays then refresh_avatar_overlays() end
                end
            end)
        end
        if resume and tonumber(resume.current_page) and tonumber(resume.current_page) > 1 then
            UIManager:scheduleIn(0, function()
                if _scroll_w and _ctx and _ctx.index == index then
                    restore_saved_page(resume)
                    if refresh_page_indicator then
                        refresh_page_indicator()
                    end
                    if refresh_comment_icons then
                        refresh_comment_icons()
                    end
                    if refresh_avatar_overlays then
                        refresh_avatar_overlays()
                    end
                end
            end)
        end

        -- IMPORTANT : les taps sont gérés directement par ScrollTextWidget
        -- (onTapScrollText -> onScrollUp/onScrollDown). Le panel.onTap ci-dessus
        -- peut donc ne jamais être appelé. Le swipe, lui, passe par _nav et
        -- rafraîchissait déjà l'indicateur.
        --
        -- Le scroll_callback est appelé par updateScrollBar() après chaque
        -- déplacement réel, quelle que soit son origine (tap, swipe, bouton,
        -- clavier, etc.). On met donc l'indicateur à jour à cet endroit.
        _scroll_w.scroll_callback = function()
            cache_current_position()
            if refresh_page_indicator then
                refresh_page_indicator()
            end
            if refresh_comment_icons then
                refresh_comment_icons()
            end
            if refresh_avatar_overlays then
                refresh_avatar_overlays()
            end
        end

        -- IMPORTANT : ScrollTextWidget consumes taps itself. When it reaches
        -- the first/last page, its native onTapScrollText returns false, so
        -- the event bubbles to FullScreenPanel and can close the reader /
        -- return to the Chapters panel instead of changing chapter.
        --
        -- Handle the tap at the ScrollTextWidget level and ALWAYS consume it.
        -- ReaderView.nextPage()/prevPage() already knows how to distinguish
        -- "scroll inside chapter" from "chapter boundary".
        -- BUG CORRIGÉ : KOReader appelle ce handler avec (self, arg, ges) —
        -- `arg` est un champ interne (souvent nil), le VRAI événement gestuel
        -- (celui qui a .pos.x) est le 3e paramètre. En ne déclarant que
        -- (_, ges), `ges` récupérait en fait `arg` (nil), donc `ges.pos`
        -- était toujours absent → x retombait sur Screen:getWidth()/2 (le
        -- centre) → `x < centre` était TOUJOURS faux → nextPage() à chaque
        -- tap, quel que soit le côté. D'où "gauche ET droite vont à droite".
        --
        -- Fix : on cherche, parmi TOUS les arguments reçus, celui qui a
        -- effectivement un .pos.x (peu importe sa position exacte dans les
        -- varargs — ça marche donc que l'appel soit (self, ges) ou
        -- (self, arg, ges)). Si aucun n'en a, on ignore le tap au lieu de
        -- deviner un côté par défaut (l'ancien fallback masquait le bug).
        _scroll_w.onTapScrollText = function(self, ...)
            local ges
            for i = 1, select("#", ...) do
                local a = select(i, ...)
                if type(a) == "table" and a.pos and a.pos.x then
                    ges = a
                    break
                end
            end
            if not ges then
                return true -- position introuvable : on ignore, on ne devine pas
            end
            local x = ges.pos.x
            if x < Screen:getWidth() / 2 then
                ReaderView.prevPage()
            else
                ReaderView.nextPage()
            end
            return true
        end

        -- Appui long sur un mot : recherche dans le dictionnaire de KOReader.
        -- On reprend EXACTEMENT le mécanisme de KOReader (DictQuickLookup,
        -- InputText…) : le TextBoxWidget interne gère lui-même HoldStartText /
        -- HoldPanText / HoldReleaseText (sélection + surlignage natifs) ; le
        -- widget qui le contient doit seulement déclarer les gestes et fournir,
        -- dans `args`, la fonction appelée au relâchement avec le texte
        -- sélectionné. (Avant, on redéfinissait onHoldStartText sur le
        -- ScrollTextWidget : jamais appelé, car l'enfant TextBoxWidget
        -- consomme l'évènement en premier.)
        local function in_text() return _scroll_w and _scroll_w.dimen end
        _scroll_w.ges_events = _scroll_w.ges_events or {}
        _scroll_w.ges_events.HoldStartText = {
            GestureRange:new{ ges = "hold", range = in_text },
        }
        _scroll_w.ges_events.HoldPanText = {
            GestureRange:new{ ges = "hold_pan", range = in_text },
            rate = (Screen.low_pan_rate and 5.0) or 10.0,
        }
        _scroll_w.ges_events.HoldReleaseText = {
            GestureRange:new{ ges = "hold_release", range = in_text },
            -- appelé par TextBoxWidget:onHoldReleaseText(callback, ges)
            args = function(selected_text)
                local tw = _scroll_w and _scroll_w.text_widget
                local word = tostring(selected_text or ""):gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:nextTick(function()
                    if word ~= "" then
                        ReaderView.lookupWord(word)
                    end
                    -- enlève le surlignage de sélection une fois la recherche lancée
                    UIManager:scheduleIn(0.3, function()
                        pcall(function()
                            if tw and tw.clearHighlight and tw:clearHighlight() then
                                tw:redrawHighlight()
                            end
                        end)
                    end)
                end)
            end,
        }

        if not _gestures_wired then wire_gestures(_panel) end

        local SefirahUI = require("ui.main_widget")
        SefirahUI.setReader(_panel)

        prefetch_next()
    end

    -- Traduction (réglage « Traduction automatique ») : si activée, on affiche la
    -- version traduite (cache disque, une seule traduction par chapitre/langue).
    -- En cas d'échec, on affiche l'original avec un message.
    local function render(html)
        local okT, Translate = pcall(require, "core.translate")
        if not okT then return render_raw(html) end
        -- Une traduction déjà faite (bouton Traduire de la fiche ou mode auto)
        -- est toujours affichée ; seule la traduction à la volée dépend du réglage.
        -- Version traduite seulement si demandée (icône de traduction à côté du
        -- chapitre dans la fiche) ou si la traduction automatique est activée.
        -- Toucher le chapitre lui-même ouvre toujours la version normale.
        local want_tr = _ctx.translated or Translate.enabled()
        if not want_tr then return render_raw(html) end
        local cached = Cache.getTranslation(_ctx.source_id, novel_path, key, Translate.lang())
        if cached then return render_raw(Translate.fix(cached)) end
        Online.run(function()
            local loading = InfoMessage:new{
                text = T("Traduction du chapitre…") }
            UIManager:show(loading)
            UIManager:scheduleIn(0.1, function()
                local ok, tr, err = pcall(Translate.chapter, html, _ctx.source_id, novel_path, key)
                UIManager:close(loading)
                if ok and tr then
                    render_raw(tr)
                else
                    UIManager:show(InfoMessage:new{
                        text = T("Traduction impossible : ") .. tostring(ok and err or tr),
                        timeout = 5,
                    })
                    render_raw(html)
                end
            end)
        end)
    end

    if Cache.isChapterCached(_ctx.source_id, novel_path, key) then
        render(Cache.getChapterHtml(_ctx.source_id, novel_path, key))
        return
    end

    -- Pas en cache : téléchargement à la demande (premier chapitre non pré-téléchargé)
    Online.run(function()
        local loading = InfoMessage:new{ text = T("Chargement du chapitre…") }
        UIManager:show(loading)
        UIManager:scheduleIn(0.1, function()
            Cache.downloadChapter(_ctx.ext, _ctx.source_id, novel_path, chapter, function(ok, err)
                UIManager:close(loading)
                if not ok then
                    UIManager:show(InfoMessage:new{ text = T("Erreur : ") .. tostring(err), timeout = 4 })
                    return
                end
                render(Cache.getChapterHtml(_ctx.source_id, novel_path, key))
            end)
        end)
    end)
end

-- ── Navigation ────────────────────────────────────────────────────────────────

local function save_current_progress()
    if not _ctx or not _scroll_w then return end
    local chapter = _ctx.chapters[_ctx.index]
    local key     = chapter.path or chapter.sourceUrl or ""
    local percent = 0
    local charpos, top_line_num = _scroll_w:getCharPos()
    if charpos and _scroll_w.text and utf8_len(_scroll_w.text) > 0 then
        percent = charpos / utf8_len(_scroll_w.text)
    end
    -- Si la vue courante est la dernière page réelle du chapitre, on enregistre
    -- 100 %. Cela permet à la liste des chapitres d'afficher ✓✓ même si
    -- l'utilisateur ferme le lecteur sans tenter de passer au chapitre suivant.
    local current_page, total_pages, ready = compute_page_progress()
    if not ready then return end -- widget pas encore mis en page : ne pas écraser une progression valide par une fausse mesure
    local completed = current_page >= total_pages
    if completed then
        percent = 1
    end
    Cache.setProgress(_ctx.source_id, _ctx.novel.path, key, percent, current_page, total_pages, completed, charpos, top_line_num)
    -- Comptabilise la page qui vient d'être quittée dans les statistiques
    -- générales de la liseuse (core/stats.lua).
    Stats.track(_ctx, current_page)
    pcall(function() require("core.quests").track(_ctx, current_page, completed, total_pages) end)
    notify_detail_progress()
end

-- Reconstruit les rangées autour du widget de défilement (même widget, donc
-- même position de lecture) pour que l'indicateur de page affiche la bonne
-- valeur après un simple défilement — sans re-télécharger ni re-parser le chapitre.
refresh_page_indicator = function()
    if not _panel or not _ctx or not _scroll_w then return end
    local chapter = _ctx.chapters[_ctx.index]
    if not chapter then return end
    local title = chapter.name or chapter.title or (T("Chapitre ") .. _ctx.index)
    local row_h = title_row_metrics(title)
    _title_extra_h = math.max(0, row_h - P.TITLE_H)
    local cur_page, total_pages = compute_page_progress()
    local text_row = HorizontalGroup:new{
        HorizontalSpan:new{ width = text_margin() },
        _scroll_w,
        HorizontalSpan:new{ width = text_margin() },
    }

    -- BUG CORRIGÉ : cette fonction est appelée à CHAQUE défilement (via
    -- _scroll_w.scroll_callback) et reconstruit tout le corps du panneau
    -- avec _panel:swapBody(). Avant, elle utilisait `text_row` tout nu ici,
    -- sans les boutons d'icônes "comment.png" (_comment_buttons) ajoutés
    -- par render() dans un OverlapGroup séparé. Comme swapBody REMPLACE
    -- entièrement l'arbre de widgets affiché, ces boutons — pourtant
    -- toujours vivants en mémoire — n'étaient simplement plus dans l'arbre
    -- peint à l'écran : les icônes de commentaires disparaissaient dès le
    -- premier scroll (elles n'étaient visibles qu'au tout premier rendu du
    -- chapitre, avant le moindre défilement). Le fix : reconstruire le même
    -- OverlapGroup{ text_row, comment_buttons... } que render(), avec les
    -- MÊMES objets bouton (_comment_buttons, mémorisés au niveau module),
    -- pour que refresh_comment_icons() (appelé juste après par le code qui
    -- nous a déclenchés) puisse continuer à les repositionner/afficher.
    local text_overlay_children = {}
    -- Couche tactile en premier : les bulles interceptent le tap avant
    -- ScrollTextWidget.
    for _, button in ipairs(_comment_buttons or {}) do
        table.insert(text_overlay_children, button)
    end
    table.insert(text_overlay_children, text_row)
    -- Couche visuelle en dernier : les bulles restent visibles au-dessus du texte.
    for _, visual in ipairs(_comment_visuals or {}) do
        table.insert(text_overlay_children, visual)
    end
    -- pdp de la section "Commentaires" de fin de chapitre (mêmes objets
    -- _avatar_visuals mémorisés au niveau module, cf. render()).
    for _, visual in ipairs(_avatar_visuals or {}) do
        table.insert(text_overlay_children, visual)
    end
    local text_overlay = OverlapGroup:new(text_overlay_children)

    local ext = _ctx.ext
    local on_tap_comments = (not comments_hidden())
        and (ext and ext.chapterCommentsPanel and ext.parseChapterComments and chapter.path)
        and function() ReaderView.openChapterComments(chapter) end or nil
    local body = VerticalGroup:new{
        align = "left",
        make_title_row(title),
        P.hairline(),
        P.contentFrame({ text_overlay }, reader_text_area_h()),
        make_page_indicator(cur_page, total_pages, _chapter_marks, on_tap_comments),
        make_nav_row(_ctx.index, #_ctx.chapters),
    }
    _panel:swapBody(body, chapter_close_guard, true, _nav, close_plugin_from_swipe)
end

-- onScrollDown()/onScrollUp() renvoient true uniquement si le widget a pu
-- défiler ; nil/false = on est déjà en bas/haut → on change de chapitre.
function ReaderView.nextPage()
    if _scroll_w and _scroll_w:onScrollDown() then
        save_current_progress()
        return
    end
    save_current_progress()
    local idx = get_adjacent_index(1)
    if idx then open_index(idx, nil) end
end

function ReaderView.prevPage()
    if _scroll_w and _scroll_w:onScrollUp() then
        save_current_progress()
        return
    end
    save_current_progress()
    local idx = get_adjacent_index(-1)
    if idx then open_index(idx, nil) end
end

-- « / » autour de « N / M » : première / dernière page du chapitre.
function ReaderView.firstPage()
    if not _scroll_w then return end
    local guard = 0
    while guard < 2000 and _scroll_w:onScrollUp() do guard = guard + 1 end
    save_current_progress()
end

function ReaderView.lastPage()
    if not _scroll_w then return end
    local guard = 0
    while guard < 2000 and _scroll_w:onScrollDown() do guard = guard + 1 end
    save_current_progress()
end

-- Boutons du bas : navigation directe selon le numéro du chapitre,
-- indépendamment de l'ordre dans lequel l'extension renvoie sa liste.
function ReaderView.prevChapter()
    if not _ctx or not _ctx.chapters or not _ctx.index then return end
    local idx = get_adjacent_index(-1)
    if not idx then return end
    save_current_progress()
    open_index(idx, nil)
end

function ReaderView.nextChapter()
    if not _ctx or not _ctx.chapters or not _ctx.index then return end
    local idx = get_adjacent_index(1)
    if not idx then return end
    save_current_progress()
    open_index(idx, nil)
end

-- ── Panneau Réglages (police / taille / dictionnaire) ───────────────────────

-- Reconstruit la vue de lecture avec les réglages courants (_font_face_idx,
-- _font_size), à la même position approximative dans le chapitre. Réutilise
-- entièrement le pipeline open_index()/render() existant : le chapitre est
-- déjà en cache, donc ça ne re-télécharge ni ne re-parse rien — juste un
-- nouveau ScrollTextWidget avec la police/taille à jour.
local function reapply_reader_settings()
    if not _ctx then return end
    local resume = nil
    if _scroll_w then
        local charpos, top_line_num = _scroll_w:getCharPos()
        local percent = 0
        if charpos and _scroll_w.text and utf8_len(_scroll_w.text) > 0 then
            percent = charpos / utf8_len(_scroll_w.text)
        end
        local tw = _scroll_w.text_widget
        local tl = tw and #(tw.vertical_string_list or {}) or 0
        resume = {
            percent = percent,
            charpos = charpos,
            top_line_num = top_line_num,
            line_frac = (tl > 0) and (((tonumber(tw.virtual_line_num) or 1) - 1) / tl) or nil,
        }
    end
    -- force_flash=true : on revient des Réglages, potentiellement après un
    -- rendu (couleurs et/ou découpage de lignes) fantômé sous le nouveau.
    open_index(_ctx.index, resume, true)
end

local function build_settings_body()
    local function change_size(delta)
        _font_size = math.max(FONT_SIZE_MIN, math.min(FONT_SIZE_MAX, _font_size + delta))
        save_reader_settings()
        ReaderView.openSettings()
    end
    local function cycle_line_spacing(delta)
        _line_spacing_idx = ((_line_spacing_idx - 1 + delta) % #LINE_SPACING_PRESETS) + 1
        save_reader_settings()
        ReaderView.openSettings()
    end
    local function cycle_width(delta)
        _width_idx = ((_width_idx - 1 + delta) % #WIDTH_PRESETS) + 1
        save_reader_settings()
        ReaderView.openSettings()
    end

    local function openFontList()
        -- IMPORTANT : déclarer font_menu AVANT de créer les callbacks.
        -- Sinon les callbacks des polices peuvent capturer une autre variable
        -- (ou nil) et le tap semble ne rien faire.
        local font_menu

        local function choose_font(index)
            _font_face_idx = index
            save_reader_settings()

            -- Ferme immédiatement la liste, puis réapplique la police.
            if font_menu then
                UIManager:close(font_menu)
            end

            UIManager:nextTick(function()
                reapply_reader_settings()
            end)
        end

        local items = {}
        for i, face in ipairs(FONT_FACES) do
            table.insert(items, {
                text = face.label,
                -- KOReader utilise TextBoxWidget quand multilines_forced=true,
                -- donc les noms longs peuvent être affichés sur plusieurs lignes.
                callback = function()
                    choose_font(i)
                end,
            })
        end

        -- Menu utilise ce champ pour positionner la sélection actuelle.
        items.current = _font_face_idx

        font_menu = Menu:new{
            -- Vraie liste plein écran.
            title = T("Choisir une police"),
            item_table = items,
            items_max_lines = 3,
            multilines_forced = true,
            items_font_size = 18,
            is_popout = false,
            is_borderless = true,
            width = Screen:getWidth(),
            height = Screen:getHeight(),

            -- Sécurité supplémentaire : si le menu est fermé par son bouton
            -- de retour, il ne doit pas réappliquer une police.
            close_callback = function()
                -- rien ici : le choix est appliqué uniquement dans choose_font()
            end,
        }

        UIManager:show(font_menu)
    end

    local face_row = make_settings_card{
        header = true,
        label  = T("Police : ") .. FONT_FACES[_font_face_idx].label,
        on_tap = openFontList,
    }
    local size_row = make_settings_card{
        icon = "size", label = T("Taille : ") .. tostring(_font_size),
        on_prev = function() change_size(-FONT_SIZE_STEP) end,
        on_next = function() change_size(FONT_SIZE_STEP) end,
    }
    local line_spacing_row = make_settings_card{
        icon = "spacing", label = T("Interligne : ") .. LINE_SPACING_PRESETS[_line_spacing_idx].label,
        on_prev = function() cycle_line_spacing(-1) end,
        on_next = function() cycle_line_spacing(1) end,
    }
    local width_row = make_settings_card{
        icon = "width", label = T("Largeur : ") .. WIDTH_PRESETS[_width_idx].label,
        on_prev = function() cycle_width(-1) end,
        on_next = function() cycle_width(1) end,
    }
    local dict_btn = make_settings_card{
        icon = "dict", label = T("Dictionnaire"),
        on_next = function() ReaderView.openDictionary() end,
    }
    local night_row = make_settings_card{
        header = true,
        label  = T("Mode nuit : ") .. (require("core.night").enabled() and T("ACTIVÉ") or T("DÉSACTIVÉ")),
        on_tap = function()
            require("core.night").toggle()
            ReaderView.openSettings(true)
        end,
    }
    local function gap() return P.spacer(Screen:scaleBySize(8)) end

    return VerticalGroup:new{
        align = "left",
        make_reader_title_bar(T("Réglages de lecture"), function() ReaderView.closeSettings() end),
        P.hairline(),
        gap(),
        face_row,
        gap(),
        size_row,
        gap(),
        line_spacing_row,
        gap(),
        width_row,
        gap(),
        dict_btn,
        gap(),
        night_row,
    }
end

-- ── Dictionnaire ──────────────────────────────────────────────────────────
-- Utilise le vrai moteur/interface de dictionnaire de KOReader.
--
-- Cette vue de lecture est indépendante de ReaderUI, donc on lui fournit un
-- petit "ReaderUI" compatible uniquement pour les services dont
-- ReaderDictionary/DictQuickLookup ont besoin. Le rendu, la recherche sdcv,
-- les boutons et la navigation entre dictionnaires restent ceux de KOReader.
--
-- Cela évite l'ancien TextViewer maison qui affichait seulement le texte brut
-- des résultats et ne ressemblait pas au dictionnaire natif visible dans
-- KOReader.

local _native_dictionary = nil
local _native_dictionary_ui = nil

local function get_native_dictionary()
    if _native_dictionary then
        return _native_dictionary
    end

    local ok, ReaderDictionary = pcall(require, "apps/reader/modules/readerdictionary")
    if not ok or not ReaderDictionary then
        UIManager:show(InfoMessage:new{
            text = T("Le module dictionnaire natif de KOReader est introuvable."),
            timeout = 4,
        })
        return nil
    end

    -- ReaderDictionary attend normalement un ReaderUI complet. Notre lecteur
    -- maison n'en a pas, donc on fournit uniquement les morceaux nécessaires
    -- au module de dictionnaire et à DictQuickLookup.
    _native_dictionary_ui = {
        menu = {
            registerToMainMenu = function() end,
        },
        document = nil,
        doc_settings = nil,
        doc_props = {
            display_title = (_ctx and _ctx.novel and _ctx.novel.title) or T("Lecture"),
        },
        view = nil,
        languagesupport = nil,
        wikipedia = nil,
        handleEvent = function() end,
    }

    local ok_new, dictionary = pcall(function()
        return ReaderDictionary:new{
            ui = _native_dictionary_ui,
            view = nil,
            dialog = nil,
            document = nil,
        }
    end)

    if not ok_new or not dictionary then
        UIManager:show(InfoMessage:new{
            text = T("Impossible d'initialiser le dictionnaire natif de KOReader.\n\n")
                .. tostring(dictionary),
            timeout = 5,
        })
        _native_dictionary_ui = nil
        return nil
    end

    -- DictQuickLookup utilise ui.dictionary pour récupérer la configuration
    -- des boutons et les réglages du ReaderDictionary.
    _native_dictionary_ui.dictionary = dictionary
    _native_dictionary = dictionary

    return _native_dictionary
end

-- Popup du dictionnaire : grande fenêtre, un seul bouton « Fermer ».
local function configure_dictionary_popup()
    if G_reader_settings then
        G_reader_settings:saveSetting("dict_largewindow", true)
        G_reader_settings:saveSetting("dict_button_config", {
            layout = { { "close" } },
            order = { "close" },
            row_count = { 1 },
        })
        G_reader_settings:flush()
    end
end

function ReaderView.lookupWord(word)
    if not word or word == "" then
        UIManager:show(InfoMessage:new{ text = T("Mot introuvable dans le texte."), timeout = 2 })
        return
    end
    configure_dictionary_popup()
    local dictionary = get_native_dictionary()
    if not dictionary then return end
    local ok, err = pcall(dictionary.onLookupWord, dictionary, word)
    if not ok then
        pcall(function() require("logger").err("Sefirah dictionnaire :", tostring(err)) end)
        UIManager:show(InfoMessage:new{ text = tostring(err):match("^[^\n]*"), timeout = 4 })
    end
end

function ReaderView.openDictionary()
    -- Le popup natif de KOReader sait utiliser ces réglages :
    -- * grande fenêtre (presque plein écran) ;
    -- * un seul bouton en bas : Fermer.
    -- On les applique avant de créer le DictQuickLookup pour que sa géométrie
    -- et sa barre de boutons soient calculées directement avec ces valeurs.
    if G_reader_settings then
        G_reader_settings:saveSetting("dict_largewindow", true)
        G_reader_settings:saveSetting("dict_button_config", {
            layout = { { "close" } },
            order = { "close" },
            row_count = { 1 },
        })
        G_reader_settings:flush()
    end

    local dictionary = get_native_dictionary()
    if not dictionary then return end

    -- Même boîte de saisie que le dictionnaire standard de KOReader.
    dictionary:onShowDictionaryLookup()
end

function ReaderView.openSettings(force_flash)
    if not _panel then return end
    _panel:swapBody(build_settings_body(), close_all, force_flash and "flash" or true, nil)
end

-- Appelé par le bouton retour de la barre de titre du panneau Réglages :
-- applique les changements (rebuild du ScrollTextWidget) et revient à la
-- lecture, à la même position.
function ReaderView.closeSettings()
    reapply_reader_settings()
end

-- ── Public ────────────────────────────────────────────────────────────────────

-- ctx = { source_id, ext, novel, chapters (liste ordonnée) }
-- start_index : chapitre à ouvrir en premier (1-based)
function ReaderView.open(ctx, start_index)
    -- Sources manga : pas de lecteur texte, le chapitre devient un CBZ ouvert
    -- dans le lecteur natif de KOReader (ui/mangaopen.lua).
    if ctx.ext and ctx.ext.type == "manga" then
        return require("ui.mangaopen").open(ctx, start_index)
    end
    _ctx = ctx
    _ctx.step = compute_step(ctx.chapters)
    _gestures_wired = false
    -- Horodate la dernière lecture pour le tri "Lu récemment" de la Bibliothèque.
    DB.update(ctx.source_id, ctx.novel.path or "", { last_read_at = os.time() })
    local idx = start_index or 1
    local resume = nil
    if ctx.chapters[idx] then
        local key = ctx.chapters[idx].path or ctx.chapters[idx].sourceUrl or ""
        resume = Cache.getChapterProgress(ctx.source_id, ctx.novel.path or "", key)
    end
    open_index(idx, resume)
end

-- ── Avis par paragraphe (novelfrance.lua) ────────────────────────────────
-- Deux écrans, tous deux de simples Menu (même pattern que le sélecteur de
-- police existant plus haut dans ce fichier) — pas de composant maison :
--   1) openChapterMarks()   : liste des paragraphes commentés du chapitre
--   2) openParagraphThread(): fil complet d'UN paragraphe, chaque avis
--      tronqué étant lui-même tapable pour l'afficher en entier (TextViewer,
--      même pattern que show_full_review dans ui/detail.lua).
-- Rien de tout ceci ne s'affiche si _chapter_marks est nil (extensions
-- autres que novelfrance.lua, ou chapitre sans aucun avis).

local function show_full_comment_text(title, content)
    content = (content or ""):match("^%s*(.-)%s*$")
    if content == "" then return end
    local viewer
    viewer = TextViewer:new{
        title                = title,
        text                 = content,
        width                = math.floor(Screen:getWidth() * 0.94),
        height               = math.floor(Screen:getHeight() * 0.90),
        show_menu            = false,
        add_default_buttons  = false,
        buttons_table        = {{
            { text = T("Fermer"), callback = function() UIManager:close(viewer) end },
        }},
        text_padding         = Screen:scaleBySize(18),
        text_margin          = Screen:scaleBySize(6),
        alignment            = "left",
    }
    UIManager:show(viewer)
end

-- Convertit une date de commentaire (ISO ou timestamp epoch) en valeur
-- numérique comparable, pour trier chronologiquement (même logique que
-- review_date_value dans ui/detail.lua). 0 en repli sur tout format
-- inattendu, pour que ces entrées se retrouvent en tête plutôt que de
-- planter le tri.
local function comment_date_value(date)
    if type(date) == "number" then return date end
    if not date or date == "" then return 0 end
    local y, m, d, hh, mm, ss = tostring(date):match(
        "^(%d%d%d%d)-(%d%d)-(%d%d)[T ]?(%d?%d?):?(%d?%d?):?(%d?%d?)")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y or not m or not d then return 0 end
    hh, mm, ss = tonumber(hh) or 0, tonumber(mm) or 0, tonumber(ss) or 0
    return os.time({ year = y, month = m, day = d, hour = hh, min = mm, sec = ss }) or 0
end

-- Le site intègre les mentions "en réponse à" DIRECTEMENT dans le texte du
-- commentaire, sous la forme "<@<id du commentaire visé>>" (visible tel
-- quel — un identifiant illisible — dans le fil hors-ligne du Kobo). Le
-- site web les résout côté client en "@pseudo" en cherchant l'auteur du
-- commentaire dont l'id correspond ; on reproduit la même résolution ici, à
-- partir des commentaires DÉJÀ récupérés pour ce paragraphe (le commentaire
-- visé — presque toujours le parent direct, cf. parent_id — s'y trouve
-- normalement puisqu'ils sont chargés ensemble). Une mention non résolvable
-- (commentaire visé absent du lot, ex. sur une page jamais chargée) est
-- retirée plutôt que laissée en clair, comme demandé.
local function resolve_comment_mentions(comments)
    local id_author = {}
    for _, c in ipairs(comments) do
        if c.id then id_author[c.id] = c.author end
    end
    for _, c in ipairs(comments) do
        local content = c.content or ""
        content = content:gsub("<@([%w]+)>%s*", function(id)
            local author = id_author[id]
            return author and ("@" .. author .. " ") or ""
        end)
        content = content:match("^%s*(.-)%s*$")
        -- CORRIGÉ (2026-09-12, capture du site) : en pratique, l'API ne
        -- renvoie JAMAIS le marqueur littéral "<@id>" ci-dessus dans
        -- `content` — c'est le site qui ajoute lui-même "@pseudo " devant
        -- le texte d'une réponse, côté client, à partir de son parentId
        -- (jamais présent dans le texte brut). On reproduit donc ça
        -- directement à partir de parent_id, sans dépendre d'un marqueur
        -- qui n'existe pas dans les données réelles.
        if c.parent_id and c.parent_id ~= "" and not content:match("^@") then
            local author = id_author[c.parent_id]
            if author then
                content = "@" .. author .. " " .. content
            end
        end
        c.content = Emoji.sanitize(content)
    end
end

-- L'API (sortBy=newest) renvoie les commentaires du plus récent au plus
-- ancien, TOUS niveaux mélangés — une fois aplatis tels quels dans la liste
-- affichée, une réponse (forcément postée après son parent) se retrouve donc
-- AVANT le commentaire auquel elle répond. Reconstitue l'ordre "fil de
-- discussion" du site à la place : chaque commentaire racine (parent_id nil)
-- par ordre chronologique, suivi immédiatement de ses réponses (même ordre
-- chronologique), récursivement. Un commentaire dont le parent référencé
-- n'a pas été retrouvé (page manquante) est quand même affiché, en fin de
-- liste, plutôt que silencieusement perdu.
local function order_comment_thread(comments)
    local children, roots = {}, {}
    for _, c in ipairs(comments) do
        if c.parent_id and c.parent_id ~= "" then
            children[c.parent_id] = children[c.parent_id] or {}
            table.insert(children[c.parent_id], c)
        else
            table.insert(roots, c)
        end
    end
    local function by_date_asc(a, b) return comment_date_value(a.date) < comment_date_value(b.date) end
    table.sort(roots, by_date_asc)
    for _, list in pairs(children) do table.sort(list, by_date_asc) end

    local ordered, seen = {}, {}
    local function append(c)
        table.insert(ordered, c)
        seen[c] = true
        for _, reply in ipairs(children[c.id] or {}) do append(reply) end
    end
    for _, root in ipairs(roots) do append(root) end
    if #ordered < #comments then
        for _, c in ipairs(comments) do
            if not seen[c] then table.insert(ordered, c) end
        end
    end
    return ordered
end

-- Formate une date de commentaire (même logique que format_review_date dans
-- ui/detail.lua — dupliquée ici car non exportée par ce module, qui n'a pas
-- accès aux locals de detail.lua).
local function format_comment_date(date)
    if not date or date == "" then return nil end
    local y, m, d
    if type(date) == "number" then
        local t = os.date("*t", date)
        y, m, d = t.year, t.month, t.day
    else
        y, m, d = tostring(date):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    end
    if not y then return nil end
    return string.format("%s/%s/%s", d, m, y)
end

-- Panneau flottant générique (position/dimensions arbitraires, PAS plein
-- écran) — même principe que FullScreenPanel de ui/panel.lua (InputContainer
-- montré directement à UIManager, dimen = position réelle à l'écran, ce qui
-- ancre correctement toutes les zones tapables imbriquées via
-- P.wrapTappable, cf. le bug documenté plus haut pour CommentTap), mais avec
-- un dimen configurable au lieu du (0,0,P.W,P.H) fixe de FullScreenPanel.
-- Remplace l'ancien thread_menu (Menu KOReader) pour permettre des lignes
-- personnalisées (pdp + auteur + date, comme l'onglet Avis de ui/detail.lua)
-- au lieu de simples items texte.
local FloatPanel = InputContainer:extend{
    body           = nil,
    close_callback = nil,
    on_swipe_next  = nil,
    on_swipe_prev  = nil,
    x = 0, y = 0, w = 0, h = 0,
}

function FloatPanel:init()
    self.dimen = Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        width      = self.w,
        height     = self.h,
        self.body,
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    -- Glisser gauche/droite pour tourner les pages de commentaires (mêmes
    -- directions que le reste du plugin, cf. FullScreenPanel:onSwipe dans
    -- ui/panel.lua) ; glisser du haut vers le bas ferme l'écran Commentaires
    -- et rend la main à la lecture (même geste que le reste du plugin pour
    -- quitter un écran). Toujours enregistré, contrairement au tourne-page
    -- gauche/droite qui ne l'est que si on_swipe_next/prev sont fournis.
    self.ges_events = self.ges_events or {}
    self.ges_events.Swipe = {
        GestureRange:new{ ges = "swipe", range = self.dimen }
    }
end

function FloatPanel:onSwipe(_, ges)
    local direction = ges and ges.direction
    if direction == "south" then
        self:onClose()
        return true
    elseif direction == "west" and self.on_swipe_next then
        self.on_swipe_next()
        return true
    elseif direction == "east" and self.on_swipe_prev then
        self.on_swipe_prev()
        return true
    end
    return false
end

function FloatPanel:onClose()
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
    return true
end

function FloatPanel:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function FloatPanel:onCloseWidget()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

-- Séparateur fin entre deux commentaires d'une même page (même logique que
-- review_separator_h/hairline dans ui/detail.lua).
local function comment_separator(popup_w)
    return LineWidget:new{
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        dimen = Geom:new{ w = popup_w, h = P.HAIRLINE },
    }
end

local function comment_rows_height(rows)
    local h = 0
    for _, r in ipairs(rows) do h = h + (r:getSize().h or 0) end
    return h
end

-- Lignes d'UN commentaire : ligne auteur avec pdp (P.makeSourceRow, même
-- helper que build_review_item_rows dans ui/detail.lua — pdp téléchargée et
-- mise en cache par core/avatars.lua, monogramme d'initiales en repli tant
-- qu'elle n'est pas encore en cache) puis le texte, tronqué et tapable pour
-- l'afficher en entier (show_full_comment_text), exactement comme un avis.
local function build_comment_item_rows(c, popup_w, comment_trunc)
    local author    = c.author or T("Anonyme")
    local avatar_bb = Avatars.getCached(c.avatar, P.SOURCE_ICON)
    local date_str  = format_comment_date(c.date)
    c.content       = Emoji.sanitize(c.content or "")
    local content   = c.content:gsub("%s+", " ")
    local truncated = #content > comment_trunc

    local rows = {}
    table.insert(rows, P.makeSourceRow(author, date_str, {
        icon_bb = avatar_bb,
        width   = popup_w,
    }))
    if content ~= "" then
        table.insert(rows, P.makeTextBlock(content, comment_trunc, {
            width    = popup_w,
            callback = truncated and function() show_full_comment_text(author, c.content) end or nil,
        }))
    end
    return rows
end

-- Range les commentaires en pages qui tiennent chacune dans budget_h (même
-- découpage séquentiel glouton que reviews_pack_pages dans ui/detail.lua).
local function pack_comment_pages(comments, popup_w, comment_trunc, budget_h)
    local sep_h = Screen:scaleBySize(4) + P.HAIRLINE
    local pages, page, used_h = {}, {}, 0
    for i, c in ipairs(comments) do
        local item_h = comment_rows_height(build_comment_item_rows(c, popup_w, comment_trunc))
        local need = (#page == 0) and item_h or (item_h + sep_h)
        if used_h + need > budget_h and #page > 0 then
            table.insert(pages, page)
            page, used_h = {}, 0
            need = item_h
        end
        table.insert(page, i)
        used_h = used_h + need
    end
    if #page > 0 then table.insert(pages, page) end
    if #pages == 0 then pages = { {} } end
    return pages
end

-- Construit et affiche le panneau "Commentaires" à partir d'une liste de
-- commentaires DÉJÀ récupérée (peu importe la source : cache hors-ligne ou
-- réseau) — factorisé pour que le chemin "cache" (instantané, pas de
-- réseau) et le chemin "réseau" (fallback ci-dessous) partagent exactement
-- le même rendu, au lieu de dupliquer toute la logique de mise en page.
-- Chaque commentaire affiche désormais sa pdp (avatar) comme un avis de
-- l'onglet Avis (ui/detail.lua), via P.makeSourceRow + core/avatars.lua.
local function show_comments_panel(comments, anchor_y)
    -- Résout les mentions "<@id>" en "@pseudo" (ou les retire si non
    -- résolvables) et remet les réponses juste après le commentaire auquel
    -- elles répondent, AVANT tout calcul de mise en page — corrige aussi
    -- bien un fil tout juste récupéré en ligne qu'un fil déjà en cache
    -- (donc affiché avec l'ancien défaut) sans avoir besoin de re-télécharger.
    resolve_comment_mentions(comments)
    comments = order_comment_thread(comments)

    local COMMENT_TRUNC = 110

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Le panneau occupe désormais TOUJOURS toute la page, sans aucune marge
    -- (bord à bord) : le moindre espace laissé libre sur les côtés laissait
    -- transparaître des restes de l'écran du dessous (lignes fantômes e-ink)
    -- — que l'appel vienne d'une bulle 💬 précise (anchor_y défini) ou de la
    -- liste des paragraphes du chapitre (anchor_y nil). anchor_y n'est donc
    -- plus utilisé pour la géométrie, seulement conservé dans la signature
    -- pour les appelants existants.
    local avail_top = 0
    local avail_bottom = screen_h

    local popup_x = 0
    local popup_w = screen_w
    local popup_y = avail_top
    local popup_h = avail_bottom - avail_top

    -- IMPORTANT : ce panneau (FloatPanel, cf. plus haut) est passé
    -- DIRECTEMENT à UIManager:show(), comme l'était déjà thread_menu (Menu)
    -- avant lui — c'est ce qui garantit que ses propres zones tapables
    -- (croix ×, flèches ‹ ›, texte tronqué) reçoivent bien le tap : voir le
    -- commentaire de CommentTap plus haut dans ce fichier sur ce même bug de
    -- dimen quand un widget tapable est niché sous un widget jamais montré
    -- lui-même. On perd la fermeture en tapant "à côté" du panneau (rien
    -- pour intercepter ce tap) : la croix "×" est le seul moyen de fermer,
    -- comme c'était déjà le cas avec le Menu.
    local title_face = Font:getFace("cfont", 18)
    local nav_face   = Font:getFace("cfont", 16)
    local bar_pad_v  = Screen:scaleBySize(8)
    -- Réduite au plus près du texte (pas de marge en trop au-dessus) :
    -- "monte" le "X / Y" encore plus haut que la première réduction.
    local nav_pad_v  = Screen:scaleBySize(2)
    local nav_h      = TextWidget:new{ text = "0 / 0", face = nav_face }:getSize().h + 2 * nav_pad_v
    local title_bar_h = TextWidget:new{ text = T("Commentaires"), face = title_face, bold = true }:getSize().h
        + 2 * bar_pad_v

    -- Plus de croix "×" : appuyer sur le titre "Commentaires" lui-même (ou
    -- glisser du haut vers le bas, cf. FloatPanel:onSwipe plus haut, ou la
    -- touche Retour) ferme l'écran et revient à la lecture.
    local function make_title_bar(on_close)
        return P.wrapTappable(FrameContainer:new{
            bordersize = 0,
            width      = popup_w,
            height     = title_bar_h,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = popup_w, h = title_bar_h },
                TextWidget:new{ text = T("Commentaires"), face = title_face, bold = true, fgcolor = Blitbuffer.COLOR_BLACK },
            },
        }, on_close)
    end

    -- Plus de flèches ‹ › : le changement de page se fait uniquement en
    -- glissant (west = page suivante, east = page précédente, cf. l'onSwipe
    -- de FloatPanel plus bas). Cette bande ne sert donc plus qu'à afficher
    -- "X / Y", en simple indicateur non tapable (plus de mot "Page").
    local function make_nav_bar(page, max_pages)
        return CenterContainer:new{ dimen = Geom:new{ w = popup_w, h = nav_h },
            TextWidget:new{ text = string.format("%d / %d", page, max_pages),
                face = nav_face, fgcolor = Blitbuffer.COLOR_GRAY },
        }
    end

    -- Pagination : comme build_chapters_rows dans ui/detail.lua, on teste
    -- d'abord SANS bande de navigation, et seulement si ça déborde sur
    -- plusieurs pages on repagine avec la place qu'elle occupe réellement
    -- soustraite du budget disponible.
    local budget_full = math.max(P.ROW_H, popup_h - title_bar_h - P.HAIRLINE)
    local pages = pack_comment_pages(comments, popup_w, COMMENT_TRUNC, budget_full)
    if #pages > 1 then
        local budget_nav = math.max(P.ROW_H, budget_full - nav_h)
        pages = pack_comment_pages(comments, popup_w, COMMENT_TRUNC, budget_nav)
    end

    local current_page = 1

    local function render()
        local has_nav = #pages > 1
        local content_h = popup_h - title_bar_h - P.HAIRLINE
        if has_nav then content_h = content_h - nav_h end
        content_h = math.max(P.ROW_H, content_h)

        local rows = {}
        local idxs = pages[current_page] or {}
        for pos, i in ipairs(idxs) do
            if pos > 1 then table.insert(rows, comment_separator(popup_w)) end
            for _, r in ipairs(build_comment_item_rows(comments[i], popup_w, COMMENT_TRUNC)) do
                table.insert(rows, r)
            end
        end
        if #rows == 0 then
            table.insert(rows, FrameContainer:new{
                bordersize = 0, padding = P.MARGIN, width = popup_w, background = Blitbuffer.COLOR_WHITE,
                TextWidget:new{ text = T("Aucun commentaire."), face = Font:getFace("cfont", 16), fgcolor = Blitbuffer.COLOR_GRAY },
            })
        end

        local close_fn = function()
            if _paragraph_popup then UIManager:close(_paragraph_popup) end
            _paragraph_popup = nil
        end

        local body_children = {
            align = "left",
            make_title_bar(close_fn),
            comment_separator(popup_w),
            P.contentFrame(rows, content_h),
        }
        if has_nav then
            table.insert(body_children, make_nav_bar(current_page, #pages))
        end

        if _paragraph_popup then
            UIManager:close(_paragraph_popup)
        end
        local panel
        panel = FloatPanel:new{
            body = VerticalGroup:new(body_children),
            x = popup_x, y = popup_y, w = popup_w, h = popup_h,
            close_callback = function()
                if _paragraph_popup == panel then _paragraph_popup = nil end
            end,
            -- Glisser gauche/droite tourne les pages de commentaires (même
            -- convention que FullScreenPanel:onSwipe dans ui/panel.lua :
            -- west = suivant, east = précédent).
            on_swipe_next = has_nav and function()
                if current_page < #pages then
                    current_page = current_page + 1
                    render()
                end
            end or nil,
            on_swipe_prev = has_nav and function()
                if current_page > 1 then
                    current_page = current_page - 1
                    render()
                end
            end or nil,
        }
        _paragraph_popup = panel
        UIManager:show(panel)
    end

    render()
end

-- ---------------------------------------------------------------------
-- Panneau "Commentaires" de CHAPITRE à chargement incrémental — pour les
-- sources qui exposent ext.parseChapterComments via un vrai panneau
-- (ext.chapterCommentsPanel == true, cf. royalroad.lua/novelfire.lua) au
-- lieu de les injecter en texte dans le chapitre (novelfrance.lua).
--
-- Différent de show_comments_panel ci-dessus (avis/commentaires de
-- paragraphe), qui précharge TOUTES les pages d'un coup puis pagine par
-- swipe : ici on ne charge qu'UNE page à la fois (10 commentaires), sur
-- tap explicite du bouton "Charger plus" — demandé tel quel.
-- ---------------------------------------------------------------------

-- state = { ext, path, source_id, comments, has_more, next_page, loading }
local function show_chapter_comments_panel(state)
    local COMMENT_TRUNC = 110
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local popup_w = screen_w
    local popup_h = screen_h

    local title_face  = Font:getFace("cfont", 18)
    local footer_face = Font:getFace("cfont", 16)
    local bar_pad_v   = Screen:scaleBySize(8)
    local title_bar_h = TextWidget:new{ text = T("Commentaires"), face = title_face, bold = true }:getSize().h
        + 2 * bar_pad_v
    local footer_h = TextWidget:new{ text = T("Charger plus"), face = footer_face }:getSize().h + 2 * bar_pad_v
    local BTN_W = Screen:scaleBySize(48)

    local render -- forward decl : référencée par make_footer/make_title_bar

    -- Retélécharge la page 1 en réseau (ignore le cache disque) puis
    -- ré-enregistre le résultat dedans — bouton "↺" de la barre de titre.
    -- Séparé de load_more (qui, lui, avance dans la pagination) : ici on
    -- repart de zéro pour rafraîchir les commentaires les plus récents.
    local function refresh_from_network()
        if state.loading then return end
        state.loading  = true
        state.comments = {}
        render()
        Online.run(function()
            UIManager:scheduleIn(0, function()
                local ok_page, data = pcall(state.ext.parseChapterComments, state.ext, state.path, 1)
                state.loading = false
                if ok_page and data and data.comments then
                    state.comments  = data.comments
                    state.has_more  = data.has_more or false
                    state.next_page = data.next_page or 2
                    pcall(DB.saveChapterCommentsCache, state.source_id, state.path,
                        state.comments, state.next_page, state.has_more)
                    local avatar_urls = {}
                    for _, c in ipairs(state.comments) do
                        if c.avatar and c.avatar ~= "" then table.insert(avatar_urls, c.avatar) end
                    end
                    if #avatar_urls > 0 then pcall(Avatars.prefetch, avatar_urls) end
                else
                    state.has_more = false
                    UIManager:show(InfoMessage:new{ text = T("Impossible d'actualiser les commentaires."), timeout = 3 })
                end
                render()
            end)
        end)
    end

    local function btn_frame(text_str, cb)
        local f = FrameContainer:new{
            bordersize = 0, padding = 0, width = BTN_W, height = title_bar_h,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = BTN_W, h = title_bar_h },
                TextWidget:new{ text = text_str, face = title_face, fgcolor = Blitbuffer.COLOR_BLACK },
            },
        }
        return P.wrapTappable(f, cb)
    end

    local function make_title_bar(on_close)
        local mid_w = popup_w - 2 * BTN_W
        local title_frame = FrameContainer:new{
            bordersize = 0,
            width      = mid_w,
            height     = title_bar_h,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = mid_w, h = title_bar_h },
                TextWidget:new{ text = T("Commentaires"), face = title_face, bold = true, fgcolor = Blitbuffer.COLOR_BLACK },
            },
        }
        return HorizontalGroup:new{
            btn_frame("↺", refresh_from_network),
            title_frame,
            btn_frame("✕", on_close),
        }
    end

    -- Récupère la page suivante en réseau puis ré-affiche. loading est
    -- remis à false dans tous les cas (succès, page vide, erreur) pour ne
    -- jamais laisser le bouton bloqué sur "Chargement…".
    local function load_more()
        if state.loading or not state.has_more then return end
        state.loading = true
        render()
        Online.run(function()
            UIManager:scheduleIn(0, function()
                local ok_page, data = pcall(state.ext.parseChapterComments, state.ext, state.path, state.next_page)
                state.loading = false
                if ok_page and data and data.comments and #data.comments > 0 then
                    local avatar_urls = {}
                    for _, c in ipairs(data.comments) do
                        table.insert(state.comments, c)
                        if c.avatar and c.avatar ~= "" then table.insert(avatar_urls, c.avatar) end
                    end
                    if #avatar_urls > 0 then pcall(Avatars.prefetch, avatar_urls) end
                    state.has_more  = data.has_more or false
                    state.next_page = data.next_page or (state.next_page + 1)
                    pcall(DB.saveChapterCommentsCache, state.source_id, state.path,
                        state.comments, state.next_page, state.has_more)
                else
                    state.has_more = false
                    if not ok_page then
                        UIManager:show(InfoMessage:new{ text = T("Impossible de charger la suite des commentaires."), timeout = 3 })
                    end
                end
                render()
            end)
        end)
    end

    local function make_footer()
        local label, tappable
        if state.loading then
            label = T("Chargement…")
        elseif state.has_more then
            label, tappable = T("Charger plus"), true
        else
            label = (#state.comments > 0) and T("Fin des commentaires") or ""
        end
        local content = FrameContainer:new{
            bordersize = 0,
            width      = popup_w,
            height     = footer_h,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = popup_w, h = footer_h },
                TextWidget:new{ text = label, face = footer_face, fgcolor = Blitbuffer.COLOR_GRAY },
            },
        }
        if tappable then
            return P.wrapTappable(content, load_more)
        end
        return content
    end

    render = function()
        local content_h = math.max(P.ROW_H, popup_h - title_bar_h - P.HAIRLINE - footer_h)

        local rows = {}
        for i, c in ipairs(state.comments) do
            if i > 1 then table.insert(rows, comment_separator(popup_w)) end
            for _, r in ipairs(build_comment_item_rows(c, popup_w, COMMENT_TRUNC)) do
                table.insert(rows, r)
            end
        end
        if #rows == 0 and not state.loading then
            table.insert(rows, FrameContainer:new{
                bordersize = 0, padding = P.MARGIN, width = popup_w, background = Blitbuffer.COLOR_WHITE,
                TextWidget:new{ text = T("Aucun commentaire."), face = Font:getFace("cfont", 16), fgcolor = Blitbuffer.COLOR_GRAY },
            })
        end

        local close_fn = function()
            if _paragraph_popup then UIManager:close(_paragraph_popup) end
            _paragraph_popup = nil
        end

        if _paragraph_popup then
            UIManager:close(_paragraph_popup)
        end
        local panel
        panel = FloatPanel:new{
            body = VerticalGroup:new{
                align = "left",
                make_title_bar(close_fn),
                comment_separator(popup_w),
                P.contentFrame(rows, content_h),
                make_footer(),
            },
            x = 0, y = 0, w = popup_w, h = popup_h,
            close_callback = function()
                if _paragraph_popup == panel then _paragraph_popup = nil end
            end,
        }
        _paragraph_popup = panel
        UIManager:show(panel)
    end

    render()
end

-- Point d'entrée : ouvre le panneau de commentaires du CHAPITRE affiché
-- (10 premiers, les plus récents), avec bouton "Charger plus" pour la
-- suite. chapter vient de _ctx.chapters[_ctx.index] (cf. les deux appels
-- dans make_page_indicator ci-dessus) — jamais construit à la main.
--
-- Cache disque (2026-09-15) : contrairement aux avis (déjà mis en cache
-- côté ui/detail.lua), ces commentaires n'étaient jamais enregistrés —
-- chaque ouverture du panneau retapait le réseau, même pour un chapitre déjà
-- consulté. On regarde maintenant DB.loadChapterCommentsCache en premier :
-- si un cache existe, le panneau s'ouvre instantanément avec (bouton "↺"
-- pour forcer un réseau frais) ; sinon on retombe sur le fetch réseau
-- habituel, qui enregistre son résultat pour la prochaine fois.
function ReaderView.openChapterComments(chapter)
    -- Garde-fou : quand les commentaires sont masqués, ce panneau ne doit
    -- jamais s'ouvrir, même si un appel traînait encore (callback différé).
    if comments_hidden() then return end
    if not _ctx or not _ctx.ext or not _ctx.ext.parseChapterComments then return end
    if not chapter or not chapter.path then return end
    local ext = _ctx.ext
    local source_id = _ctx.source_id

    if _paragraph_popup then
        UIManager:close(_paragraph_popup)
        _paragraph_popup = nil
    end

    local cached = DB.loadChapterCommentsCache(source_id, chapter.path)
    if cached and cached.comments and #cached.comments > 0 then
        show_chapter_comments_panel{
            ext = ext, path = chapter.path, source_id = source_id,
            comments = cached.comments, has_more = cached.has_more or false,
            next_page = cached.next_page or 2, loading = false,
        }
        return
    end

    local loading = InfoMessage:new{ text = T("Chargement des commentaires…") }
    UIManager:show(loading)

    Online.run(function()
        UIManager:scheduleIn(0, function()
            local ok_page, data = pcall(ext.parseChapterComments, ext, chapter.path, 1)
            UIManager:close(loading)

            local comments  = (ok_page and data and data.comments) or {}
            local has_more  = ok_page and data and data.has_more or false
            local next_page = (ok_page and data and data.next_page) or 2

            if #comments == 0 then
                UIManager:show(InfoMessage:new{
                    text = ok_page and T("Aucun commentaire pour ce chapitre.") or T("Impossible de charger les commentaires."),
                    timeout = 3,
                })
                return
            end

            local avatar_urls = {}
            for _, c in ipairs(comments) do
                if c.avatar and c.avatar ~= "" then table.insert(avatar_urls, c.avatar) end
            end
            if #avatar_urls > 0 then pcall(Avatars.prefetch, avatar_urls) end

            pcall(DB.saveChapterCommentsCache, source_id, chapter.path, comments, next_page, has_more)

            show_chapter_comments_panel{
                ext = ext, path = chapter.path, source_id = source_id,
                comments = comments, has_more = has_more, next_page = next_page,
                loading = false,
            }
        end)
    end)
end

-- Fil complet d'un paragraphe donné. chapter_id/paragraph_id viennent de
-- _chapter_marks (chapterId) et d'une entrée de marks (id) — jamais tapés à
-- la main, donc pas besoin de les valider ici au-delà du pcall sur l'appel
-- réseau lui-même.
function ReaderView.openParagraphThread(chapter_id, paragraph_id, paragraph_preview, anchor_y)
    if not _ctx or not _ctx.ext or not _ctx.ext.parseParagraphComments then return end
    local ext = _ctx.ext

    -- Si un fil est déjà ouvert, on le remplace. Cela évite d'avoir plusieurs
    -- fenêtres empilées quand on tape rapidement plusieurs bulles.
    if _paragraph_popup then
        UIManager:close(_paragraph_popup)
        _paragraph_popup = nil
    end

    -- Demandé (2026-09-12) : les commentaires des chapitres déjà téléchargés
    -- doivent être consultables hors-ligne. S'ils ont été mis en cache (au
    -- téléchargement du chapitre — cf. core/cache.lua:cache_chapter_comments
    -- — ou lors d'une consultation en ligne précédente, voir plus bas), on
    -- les affiche directement : pas de "Chargement…", pas besoin de réseau.
    local cur_chapter = _ctx.chapters and _ctx.chapters[_ctx.index]
    local chapter_cache_key = cur_chapter and Cache.chapterKey(cur_chapter)
    local cached = chapter_cache_key
        and Cache.getParagraphComments(_ctx.source_id, _ctx.novel.path or "", chapter_cache_key, paragraph_id)
    if cached then
        show_comments_panel(cached, anchor_y)
        return
    end

    local loading = InfoMessage:new{ text = T("Chargement des commentaires…") }
    UIManager:show(loading)

    Online.run(function()
        UIManager:scheduleIn(0, function()
            local comments = {}
            local page = 1
            local has_more = true
            local ok = true

            while has_more and page <= 100 do
                local ok_page, data = pcall(
                    ext.parseParagraphComments, ext, chapter_id, paragraph_id, page)
                if not ok_page then
                    ok = false
                    break
                end
                for _, c in ipairs((data and data.comments) or {}) do
                    table.insert(comments, c)
                end
                has_more = data and data.has_more or false
                page = page + 1
            end

            UIManager:close(loading)

            if #comments == 0 then
                UIManager:show(InfoMessage:new{
                    text = ok and T("Aucun commentaire pour ce paragraphe.") or T("Impossible de charger les commentaires."),
                    timeout = 3
                })
                return
            end

            -- Alimente le cache hors-ligne au passage (best-effort — un
            -- chapitre juste LU, même sans avoir été explicitement
            -- "téléchargé", garde ainsi ses commentaires déjà vus
            -- disponibles hors-ligne la prochaine fois).
            if ok and chapter_cache_key then
                pcall(Cache.mergeParagraphComments,
                    _ctx.source_id, _ctx.novel.path or "", chapter_cache_key, paragraph_id, comments)
            end

            -- Télécharge + met en cache disque les pdp pas encore vues, comme
            -- fetch_reviews_page le fait pour l'onglet Avis (core/avatars.lua) —
            -- on est déjà dans NetworkMgr:runWhenConnected, donc le réseau est
            -- disponible. show_comments_panel() lit ensuite ce cache de façon
            -- synchrone via Avatars.getCached (jamais de réseau depuis le rendu).
            local avatar_urls = {}
            for _, c in ipairs(comments) do
                if c.avatar and c.avatar ~= "" then
                    table.insert(avatar_urls, c.avatar)
                end
            end
            if #avatar_urls > 0 then
                pcall(Avatars.prefetch, avatar_urls)
            end

            show_comments_panel(comments, anchor_y)
        end)
    end)
end

function ReaderView.close()
    if _paragraph_popup then
        UIManager:close(_paragraph_popup)
        _paragraph_popup = nil
    end
    save_current_progress()
    Stats.stop()  -- clôt la session de lecture en cours
    if _panel then
        -- Refresh complet (pas "partial") à la fermeture : le panneau qui
        -- réapparaît en dessous (Detail, avec sa couverture) redessine une
        -- image juste après — enchaîner deux rafraîchissements e-ink
        -- partiels/rapides coup sur coup est une cause connue de crash bas
        -- niveau sur certains drivers Kobo. À tester si le segfault
        -- persiste : si oui, la cause est ailleurs.
        _panel.partial = false
        UIManager:close(_panel)
        _panel = nil
    end
    _scroll_w = nil
    _gestures_wired = false
    _chapter_marks = nil
    _comment_buttons = nil
    _comment_visuals = nil
    _ctx = nil
    local ok, SefirahUI = pcall(require, "ui.main_widget")
    if ok then SefirahUI.clearReader() end
end

return ReaderView
