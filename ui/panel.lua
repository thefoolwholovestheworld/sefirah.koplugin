-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- UI partagée Sefirah : base FullScreenPanel + assistants de lignes/en-têtes/onglets.
-- Tous les écrans sont construits comme UN SEUL widget FullScreenPanel affiché via UIManager,
-- pour que la barre d'onglets et le contenu partagent un seul arbre de widgets sans problème d'ordre z.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local Screen = Device.screen

-- Chemin absolu vers la racine du plugin (calculé une fois au chargement depuis le chemin de ce fichier)
local _PLUGIN_ROOT = (debug.getinfo(1, "S").source or ""):match("^@(.+)/ui/panel%.lua$") or ""
local _LOGO_PATH   = _PLUGIN_ROOT .. "/resources/logo.png"
local _SEARCH_ICON_PATH = _PLUGIN_ROOT .. "/resources/chapter_search.png"
-- Filtre/tri de Bibliothèque/Parcourir : même icône que le sélecteur de critère
-- (Étoiles/Date) de l'onglet Avis (sort.png) — les deux ouvrent un menu déroulant
-- de choix, contrairement à review_sort.png qui est une simple bascule de sens.
local _FILTER_ICON_PATH = _PLUGIN_ROOT .. "/resources/sort.png"

local P = {}

-- Icônes bitmap de la barre d'actions Détails/Chapitres (P.makeCustomActionBar).
-- Mêmes contraintes que _SEARCH_ICON_PATH ci-dessus : on évite les glyphes
-- Unicode (⇩, ↑/↓) qui ne sont pas dans la police système sur Kobo et
-- s'affichent comme des carrés noirs de remplacement.
P.ICON_DOWNLOAD       = _PLUGIN_ROOT .. "/resources/download.png"
-- Icône « installer » affichée à droite d'une source pas encore installée
-- (onglet Sources, via opts.right_icon de P.makeSourceRow).
P.ICON_INSTALL        = _PLUGIN_ROOT .. "/resources/install.png"
-- Icône « réglages » affichée à droite d'une source déjà installée
-- (remplace l'ancien texte « Installée »).
P.ICON_GEAR           = _PLUGIN_ROOT .. "/resources/gear.png"
-- Mode sélection de l'onglet Chapitres : « Quitter » (leave) et « Page »
-- (cocher toute la page) remplacés par des icônes.
P.ICON_QUIT           = _PLUGIN_ROOT .. "/resources/quit.png"
P.ICON_PAGE           = _PLUGIN_ROOT .. "/resources/page.png"
P.ICON_MENU           = _PLUGIN_ROOT .. "/resources/menu.png"
P.ICON_SORT           = _PLUGIN_ROOT .. "/resources/sort.png"
P.ICON_REVIEW_SORT    = _PLUGIN_ROOT .. "/resources/review_sort.png"
P.ICON_CHAPTER_SEARCH = _PLUGIN_ROOT .. "/resources/chapter_search.png"
P.ICON_COMMENT        = _PLUGIN_ROOT .. "/resources/comment.png"
-- Bouton « Traduire » de la barre d'actions des chapitres (ui/detail.lua).
P.ICON_TRANSLATE      = _PLUGIN_ROOT .. "/resources/translate.png"
-- Variante affichée quand les commentaires sont masqués (onglet Avis retiré) :
-- remplace entièrement l'icône ci-dessus au lieu de superposer un "X" dessus
-- (cf. ic.image_off dans P.makeCustomActionBar).
P.ICON_COMMENT_OFF     = _PLUGIN_ROOT .. "/resources/comment_off.png"

-- Suit les rafraîchissements partiels (tourne-page) consécutifs pour pouvoir passer en
-- "flashui" toutes les N pages pour effacer le fantôme e-ink. Doit vivre ici car
-- les instances de FullScreenPanel sont recréées à chaque rebuild().
local _partial_count    = 0
local _FLASHUI_INTERVAL = 6

-- ── Dimensions ────────────────────────────────────────────────────────────────

P.W         = Screen:getWidth()
P.H         = Screen:getHeight()
-- Bandeau d'app "Sefirah" tout en haut des 3 écrans d'onglet principaux, au-dessus
-- de la barre de titre (Bibliothèque/Parcourir/Sources). Pris sur la hauteur de
-- contenu, jamais sur P.TAB_H, pour que la barre d'onglets du bas ne bouge pas.
P.APP_H     = Screen:scaleBySize(64)
P.TITLE_H   = Screen:scaleBySize(56)
P.TAB_H     = Screen:scaleBySize(104)
-- Barre Détails/Chapitres : même hauteur que la barre principale (P.TAB_H) pour que ses
-- libellés tombent à la même hauteur à l'écran que Bibliothèque/Parcourir/Sources.
P.CUSTOM_TAB_H = P.TAB_H
P.ROW_H     = Screen:scaleBySize(48)
P.MARGIN    = Screen:scaleBySize(16)
P.HAIRLINE  = math.max(1, Screen:scaleBySize(1))

-- Hauteur de contenu disponible dans un écran d'onglet (entre le bandeau Sefirah et la barre d'onglets)
-- (2 hairlines : sous le bandeau Sefirah, et sous la barre de titre — la barre d'onglets
-- du bas n'en dessine plus une elle-même, cf. P.makeTabBar)
P.CONTENT_H = P.H - P.APP_H - P.TITLE_H - 2 * P.HAIRLINE - P.TAB_H
-- Hauteur de contenu pour les sous-écrans (pas de barre d'onglets)
P.SUB_H     = P.H - P.TITLE_H - P.HAIRLINE

-- Combien de lignes tiennent dans chaque contexte
P.MAX_ROWS     = math.floor(P.CONTENT_H / P.ROW_H)
P.MAX_SUB_ROWS = math.floor(P.SUB_H     / P.ROW_H)

-- Hauteur des gros boutons "‹ Chap. précédent" / "Chap. suivant ›" du lecteur.
-- Source unique de vérité : les boutons de nav de readerview.lua ET tous les autres
-- "gros bouton du bas" (P.makeBigButton, lignes d'action de l'écran détails) sont dimensionnés
-- à partir de cette même constante pour qu'ils fassent tous la même taille.
P.BIG_BTN_H     = Screen:scaleBySize(80)

-- Barre de nav (ligne < > précédent/suivant entre le contenu et la barre d'onglets).
-- Même hauteur que P.BIG_BTN_H (les boutons Chap. précédent/suivant du lecteur),
-- pour que la barre de pagination Bibliothèque/Sources/Parcourir en bas de chaque écran
-- fasse cette même taille aussi.
P.NAV_ROW_H     = P.BIG_BTN_H
-- Hauteur de contenu quand la barre de nav est visible (réserve HAIRLINE + NAV_ROW_H)
P.CONTENT_H_NAV = P.CONTENT_H - P.NAV_ROW_H - P.HAIRLINE
P.MAX_ROWS_NAV  = math.floor(P.CONTENT_H_NAV / P.ROW_H)

-- Hauteur de contenu pour l'écran à barre d'onglets personnalisée (Détails/Chapitres).
-- À NE PAS confondre avec P.CONTENT_H ci-dessus : cet écran est un sous-écran, pas un onglet
-- principal, donc il n'a PAS le bandeau d'app P.APP_H (sa barre du bas fait la même hauteur
-- que P.TAB_H, cf. P.CUSTOM_TAB_H ci-dessus). Calculée directement à partir de P.H pour que
-- titre + contenu + (nav) + barre d'onglets personnalisée remplissent exactement l'écran, sans
-- zone morte au-dessus de la barre d'onglets ni de chapitres manquants au-dessus de la nav.
P.CUSTOM_CONTENT_H     = P.H - P.TITLE_H - P.HAIRLINE - P.CUSTOM_TAB_H
-- Hauteur réduite de la barre de pagination uniquement pour l'onglet
-- Détails/Chapitres. Cela libère quelques lignes supplémentaires pour les
-- chapitres sans modifier la barre de pagination du lecteur de chapitre
-- ni celle des onglets principaux.
P.CUSTOM_NAV_ROW_H     = Screen:scaleBySize(56)
P.CUSTOM_CONTENT_H_NAV = P.CUSTOM_CONTENT_H - P.CUSTOM_NAV_ROW_H - P.HAIRLINE

local TABS = {
    { id = "library", label = T("Bibliothèque") },
    { id = "browse",  label = T("Parcourir")  },
    { id = "sources", label = "Sources" },
    { id = "settings", label = T("Paramètres"), key = "Paramètres" },
}

-- ── Gesture wrapper ───────────────────────────────────────────────────────────

-- Exécute un callback d'icône/bouton sans laisser une erreur Lua faire planter
-- KOReader : l'erreur est journalisée (crash.log) et affichée à l'écran.
function P.safeCall(fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        pcall(function() require("logger").err("Sefirah: erreur dans un callback :", tostring(err)) end)
        pcall(function()
            local msg = tostring(err):gsub("\n.*", "")   -- 1re ligne = message d'erreur
            UIManager:show(require("ui/widget/infomessage"):new{
                text    = T("Sefirah — erreur :\n") .. msg,
                timeout = 12,
            })
        end)
    end
end

function P.wrapTappable(widget, callback, hold_callback)
    if not callback and not hold_callback then return widget end
    local sz = widget:getSize()
    local wrapper = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h }, widget }
    wrapper.ges_events = {}
    if callback then
        wrapper.ges_events.Tap = {
            GestureRange:new{ ges = "tap", range = wrapper.dimen }
        }
        wrapper.onTap = function() P.safeCall(callback); return true end
    end
    if hold_callback then
        wrapper.ges_events.Hold = {
            GestureRange:new{ ges = "hold", range = wrapper.dimen }
        }
        wrapper.onHold = function() P.safeCall(hold_callback); return true end
    end
    return wrapper
end

-- ── Primitives ────────────────────────────────────────────────────────────────

function P.hairline()
    return LineWidget:new{
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        dimen = Geom:new{ w = P.W, h = P.HAIRLINE },
    }
end

function P.spacer(h)
    return VerticalSpan:new{ width = h }
end

-- ── Row widget ────────────────────────────────────────────────────────────────
-- opts : { bold, dim, selected, mandatory, trailing, mandatory_bold, callback, hold_callback,
--          icon, icon_callback }  (selected = ligne grisée, ex. chapitre coché)  (icon = fichier image affiché à droite, avec son propre toucher)

function P.makeRow(text, opts)
    opts = opts or {}
    local face       = Font:getFace("cfont", opts.font_size or 18)
    local small_face = Font:getFace("cfont", 14)
    local fgcolor    = opts.dim and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK

    local row_h       = opts.height or P.ROW_H
    local icon_zone_w = (opts.icon and opts.icon_callback) and (row_h + Screen:scaleBySize(10)) or 0
    local full_w      = P.W - icon_zone_w

    -- Parties secondaires (date, progression) créées d'abord pour connaître
    -- leur largeur et borner le titre (ellipse au lieu de déborder).
    local extras, extras_w = {}, 0
    local function add_extra(w)
        table.insert(extras, HorizontalSpan:new{ width = P.MARGIN })
        table.insert(extras, w)
        extras_w = extras_w + P.MARGIN + w:getSize().w
    end
    if opts.mandatory and opts.mandatory ~= "" then
        add_extra(TextWidget:new{
            text    = tostring(opts.mandatory),
            face    = small_face,
            bold    = opts.mandatory_bold or false,
            fgcolor = opts.mandatory_bold and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        })
    end
    if opts.trailing and opts.trailing ~= "" then
        add_extra(TextWidget:new{
            text    = tostring(opts.trailing),
            face    = small_face,
            bold    = opts.trailing == "✓✓",
            fgcolor = opts.trailing == "✓✓" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        })
    end

    local label = TextWidget:new{
        text      = text or "",
        face      = face,
        bold      = opts.bold,
        fgcolor   = fgcolor,
        max_width = math.max(Screen:scaleBySize(60), full_w - 2 * P.MARGIN - extras_w),
    }

    local parts = { label }
    for _, w in ipairs(extras) do table.insert(parts, w) end
    -- Remplissage jusqu'à la largeur de la ligne : le fond (gris quand le
    -- chapitre est coché) couvre ainsi TOUTE la ligne, sans dépendre du champ
    -- `width` de FrameContainer (ignoré par certaines versions de KOReader,
    -- d'où les bandes grises de largeur irrégulière).
    local used_w = label:getSize().w + extras_w
    local fill_w = full_w - P.MARGIN - used_w
    if fill_w > 0 then
        table.insert(parts, HorizontalSpan:new{ width = fill_w })
    end
    local inner = HorizontalGroup:new(parts)

    -- Centrage vertical
    local inner_h   = inner:getSize().h
    local v_top     = math.max(0, math.floor((row_h - inner_h) / 2))
    local v_bottom  = math.max(0, row_h - inner_h - v_top)

    local frame = FrameContainer:new{
        bordersize     = 0,
        margin         = 0,
        padding        = 0,
        padding_top    = v_top,
        padding_bottom = v_bottom,
        padding_left   = P.MARGIN,
        padding_right  = 0,
        background     = opts.selected and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        inner,
    }
    if opts.row_ref then opts.row_ref.frame = frame end
    if icon_zone_w == 0 then
        return P.wrapTappable(frame, opts.callback, opts.hold_callback)
    end

    -- Ligne en 2 zones tactiles : le texte (version normale) et l'icône à
    -- droite (version traduite).
    local ImageWidget = require("ui/widget/imagewidget")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local icon_size = Screen:scaleBySize(32)
    -- Le cadre du texte ne prend que la largeur de son contenu : on le met dans
    -- un conteneur de largeur fixe pour que l'icône reste calée à droite de la
    -- ligne (et non collée juste après le texte gris).
    local left_zone = LeftContainer:new{
        dimen = Geom:new{ w = P.W - icon_zone_w, h = row_h },
        frame,
    }
    local icon_zone = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = icon_zone_w, h = row_h },
            ImageWidget:new{
                file = opts.icon, width = icon_size, height = icon_size, scale_factor = 0,
            },
        },
    }
    return HorizontalGroup:new{
        P.wrapTappable(left_zone, opts.callback, opts.hold_callback),
        P.wrapTappable(icon_zone, opts.icon_callback),
    }
end

-- ── Barre de recherche (champ cerclé, texte indicatif grisé) ─────────────────
-- Toucher la barre ouvre la saisie ; si `value` est donné, il remplace l'indication.
P.SEARCH_BAR_H       = Screen:scaleBySize(56)   -- hauteur totale du champ, bordures comprises
P.SEARCH_BAR_PAD_TOP = Screen:scaleBySize(8)
P.SEARCH_BAR_PAD_BOT = Screen:scaleBySize(24)   -- marge sous le champ : décale les cases vers le bas
P.SEARCH_BAR_BLOCK_H = P.SEARCH_BAR_H + P.SEARCH_BAR_PAD_TOP + P.SEARCH_BAR_PAD_BOT

function P.makeSearchBar(hint, callback, value)
    local face   = Font:getFace("cfont", 18)
    local bar_w  = P.W - 2 * P.MARGIN
    local border = Screen:scaleBySize(2)
    local has_value = value and value ~= ""
    local label = TextWidget:new{
        text      = has_value and value or hint,
        face      = face,
        fgcolor   = has_value and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        max_width = bar_w - 2 * P.MARGIN - 2 * border,
    }
    -- Hauteur obtenue par le remplissage (comme P.makeRow) plutôt que par `height` :
    -- un cadre à hauteur fixe + coins arrondis perdait son bord du bas à l'écran.
    local pad_v = math.max(0, math.floor((P.SEARCH_BAR_H - 2 * border - label:getSize().h) / 2))
    local field = FrameContainer:new{
        bordersize     = border,
        color          = Blitbuffer.COLOR_BLACK,
        margin         = 0,
        padding        = 0,
        padding_top    = pad_v,
        padding_bottom = pad_v,
        padding_left   = P.MARGIN,
        padding_right  = 0,
        width          = bar_w,
        background     = Blitbuffer.COLOR_WHITE,
        label,
    }
    local outer = FrameContainer:new{
        bordersize     = 0,
        padding_left   = P.MARGIN,
        padding_right  = P.MARGIN,
        padding_top    = P.SEARCH_BAR_PAD_TOP,
        padding_bottom = P.SEARCH_BAR_PAD_BOT,
        background     = Blitbuffer.COLOR_WHITE,
        field,
    }
    -- Zone tactile = TOUT le bloc (pleine largeur, bordures et marges comprises) :
    -- la taille calculée du cadre pouvait être plus petite que ce qui est dessiné,
    -- et seul le texte réagissait au toucher.
    local wrapper = P.wrapTappable(outer, callback)
    if callback then
        local full = Geom:new{ x = 0, y = 0, w = P.W, h = P.SEARCH_BAR_BLOCK_H }
        wrapper.dimen = full
        wrapper.ges_events.Tap = { GestureRange:new{ ges = "tap", range = full } }
    end
    return wrapper
end

-- ── Big action button (full-width, bordered, large bold label) ───────────────
-- Pour une action principale unique qui doit se démarquer de la liste de lignes,
-- ex. "Reprendre la lecture".

function P.makeBigButton(text, callback)
    local face = Font:getFace("cfont", 22)
    local label = TextWidget:new{
        text    = text or "",
        face    = face,
        bold    = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    -- Même hauteur que les boutons "‹ Chap. précédent" / "Chap. suivant ›" du
    -- lecteur (P.BIG_BTN_H), pour que tous les gros boutons du bas correspondent.
    local btn_h = P.BIG_BTN_H
    local btn_w = P.W - 2 * P.MARGIN
    -- Bouton « pilule » (coins complètement arrondis). Hauteur obtenue par le remplissage
    -- vertical plutôt que par `height` : un cadre à hauteur fixe + coins arrondis perd son
    -- bord du bas à l'écran (même remarque que P.makeSearchBar).
    local border = Screen:scaleBySize(2)
    local label_h = label:getSize().h
    local pad_v = math.max(0, math.floor((btn_h - 2 * border - label_h) / 2))
    local btn = FrameContainer:new{
        bordersize     = border,
        color          = Blitbuffer.COLOR_BLACK,
        radius         = math.floor(btn_h / 2),
        padding        = 0,
        padding_top    = pad_v,
        padding_bottom = pad_v,
        margin         = 0,
        width          = btn_w,
        background     = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = btn_w - 2 * border, h = label_h }, label },
    }
    local outer = FrameContainer:new{
        bordersize     = 0,
        padding_left   = P.MARGIN,
        padding_right  = P.MARGIN,
        padding_top    = Screen:scaleBySize(8),
        padding_bottom = Screen:scaleBySize(8),
        background     = Blitbuffer.COLOR_WHITE,
        btn,
    }
    return P.wrapTappable(outer, callback)
end

-- ── Multi-line text block (for synopsis, descriptions) ────────────────────────
-- opts : { min_height, callback } — min_height force une hauteur mini pour le
-- cadre (texte plus court affiché en haut, avec du blanc en dessous), pour
-- qu'une série de blocs tronqués à la même longueur rendent tous à la même
-- taille. callback rend le bloc tapotable (ex. avis tronqué → tout afficher).

-- opts.width (optionnel) : largeur totale du bloc, pour un appelant qui ne
-- couvre pas toute la largeur de l'écran (ex. le panneau flottant des
-- commentaires de ui/readerview.lua, plus étroit que P.W). Par défaut P.W,
-- comme avant — tous les appels existants gardent donc le même rendu.
function P.makeTextBlock(text, max_chars, opts)
    opts = opts or {}
    max_chars = max_chars or 400
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local face      = Font:getFace("cfont", 16)
    local width     = opts.width or P.W
    local inner_w   = width - 2 * P.MARGIN
    local display   = (text or ""):match("^%s*(.-)%s*$")
    if #display > max_chars then
        display = display:sub(1, max_chars) .. "…"
    end
    local tw = TextBoxWidget:new{
        text      = display,
        face      = face,
        width     = inner_w,
        alignment = "left",
    }
    local pad_v     = Screen:scaleBySize(6)
    local content_h = tw:getSize().h + 2 * pad_v
    local frame = FrameContainer:new{
        bordersize     = 0,
        padding_left   = P.MARGIN,
        padding_right  = P.MARGIN,
        padding_top    = pad_v,
        padding_bottom = pad_v,
        width          = width,
        height         = opts.min_height and math.max(opts.min_height, content_h) or nil,
        background     = Blitbuffer.COLOR_WHITE,
        tw,
    }
    return P.wrapTappable(frame, opts.callback)
end

-- ── Detail header (cover + synopsis side by side) ────────────────────────────
-- Emplacement de couverture à taille fixe à gauche (image centrée/ajustée à l'intérieur, même
-- emprise quelles que soient les dimensions de l'illustration source) avec la ligne meta
-- + synopsis remplissant la largeur restante à droite, alignés en haut pour que
-- les deux colonnes soient parallèles. L'appelant doit contraindre la couverture récupérée à
-- P.DETAIL_COVER_W × P.DETAIL_COVER_H avant de la transmettre.

P.DETAIL_COVER_W = Screen:scaleBySize(190)
P.DETAIL_COVER_H = math.floor(P.DETAIL_COVER_W * 1.45)

local function ImageWidget_for_header(bb)
    local ImageWidget = require("ui/widget/imagewidget")
    return ImageWidget:new{ image = bb, width = bb:getWidth(), height = bb:getHeight() }
end

function P.makeDetailHeader(cover_bb, meta_str, summary, max_chars, on_tap, centered)
    max_chars = max_chars or 500
    local TextBoxWidget = require("ui/widget/textboxwidget")

    local cover_slot
    if cover_bb then
        local ImageWidget = require("ui/widget/imagewidget")
        cover_slot = CenterContainer:new{
            dimen = Geom:new{ w = P.DETAIL_COVER_W, h = P.DETAIL_COVER_H },
            ImageWidget:new{
                image  = cover_bb,
                width  = cover_bb:getWidth(),
                height = cover_bb:getHeight(),
            },
        }
    else
        cover_slot = FrameContainer:new{
            bordersize = Screen:scaleBySize(1),
            color      = Blitbuffer.COLOR_LIGHT_GRAY,
            width      = P.DETAIL_COVER_W,
            height     = P.DETAIL_COVER_H,
            background = Blitbuffer.COLOR_WHITE,
            VerticalSpan:new{ width = 0 },
        }
    end

    if centered then
        -- Mise en page « manga » : couverture centrée en haut, puis infos et synopsis court dessous.
        local full_w = P.W - 2 * P.MARGIN
        local cover_row = CenterContainer:new{
            dimen = Geom:new{ w = full_w, h = cover_bb and (cover_bb:getHeight()) or P.DETAIL_COVER_H },
            cover_bb and ImageWidget_for_header(cover_bb) or cover_slot,
        }
        local meta_c = TextWidget:new{
            text = meta_str or "", face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.COLOR_GRAY,
            max_width = full_w,
        }
        local meta_row = CenterContainer:new{ dimen = Geom:new{ w = full_w, h = meta_c:getSize().h }, meta_c }
        local disp = (summary or ""):match("^%s*(.-)%s*$")
        if #disp > max_chars then disp = disp:sub(1, max_chars) .. "…" end
        local syn = TextBoxWidget:new{
            text = disp, face = Font:getFace("cfont", 15), width = full_w,
            height = Screen:scaleBySize(70), alignment = "left",
        }
        local frame = FrameContainer:new{
            bordersize = 0, padding_left = P.MARGIN, padding_right = P.MARGIN,
            padding_top = Screen:scaleBySize(8), padding_bottom = Screen:scaleBySize(8),
            background = Blitbuffer.COLOR_WHITE,
            VerticalGroup:new{
                align = "left",
                cover_row,
                VerticalSpan:new{ width = Screen:scaleBySize(6) },
                meta_row,
                VerticalSpan:new{ width = Screen:scaleBySize(4) },
                syn,
            },
        }
        return on_tap and P.wrapTappable(frame, on_tap) or frame
    end

    local text_w = P.W - P.DETAIL_COVER_W - 3 * P.MARGIN

    local meta_widget = TextWidget:new{
        text    = meta_str or "",
        face    = Font:getFace("cfont", 14),
        fgcolor = Blitbuffer.COLOR_GRAY,
    }

    local display = (summary or ""):match("^%s*(.-)%s*$")
    if #display > max_chars then
        display = display:sub(1, max_chars) .. "…"
    end

    -- Hauteur disponible pour le synopsis sous la ligne meta — toujours calée sur
    -- l'emplacement de couverture, pour que l'en-tête (et donc tout ce qui suit,
    -- y compris la barre Détails/Chapitres) fasse toujours la même hauteur d'un
    -- roman à l'autre.
    local meta_spacer_h = Screen:scaleBySize(6)
    local avail_h       = math.max(0, P.DETAIL_COVER_H - meta_widget:getSize().h - meta_spacer_h)

    -- Mesure d'abord la hauteur naturelle du synopsis (sans contrainte) pour
    -- savoir s'il tient dans l'espace disponible ou s'il faut le tronquer.
    local synopsis_widget = TextBoxWidget:new{
        text      = display,
        face      = Font:getFace("cfont", 15),
        width     = text_w,
        alignment = "left",
    }
    local natural_h = synopsis_widget:getSize().h

    if natural_h > avail_h then
        -- Trop long pour la place disponible : on le contraint à occuper tout
        -- l'espace restant (TextBoxWidget tronque silencieusement ce qui dépasse,
        -- le texte complet reste consultable en appuyant sur l'en-tête via
        -- show_full_summary) plutôt que de laisser l'en-tête déborder.
        synopsis_widget = TextBoxWidget:new{
            text      = display,
            face      = Font:getFace("cfont", 15),
            width     = text_w,
            height    = avail_h,
            alignment = "left",
        }
    end

    local right_content = VerticalGroup:new{
        align = "left",
        meta_widget,
        VerticalSpan:new{ width = meta_spacer_h },
        synopsis_widget,
    }

    -- Centre ce bloc verticalement à côté de la couverture quand il est plus
    -- court que son emplacement (roman avec peu de texte) ; quand le synopsis a
    -- été tronqué ci-dessus, le bloc remplit déjà toute la hauteur et le
    -- centrage ne change rien.
    local right_col = CenterContainer:new{
        dimen = Geom:new{ w = text_w, h = P.DETAIL_COVER_H },
        right_content,
    }

    local header_frame = FrameContainer:new{
        bordersize     = 0,
        padding_left   = P.MARGIN,
        padding_right  = P.MARGIN,
        padding_top    = Screen:scaleBySize(8),
        padding_bottom = Screen:scaleBySize(8),
        background     = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            cover_slot,
            HorizontalSpan:new{ width = P.MARGIN },
            right_col,
        },
    }
    return on_tap and P.wrapTappable(header_frame, on_tap) or header_frame
end

-- ── Image block (for book covers) ─────────────────────────────────────────────
-- bb doit déjà être mis à l'échelle à la taille d'affichage voulue par l'appelant.

-- ── Cover grid ────────────────────────────────────────────────────────────────
-- Une cellule "couverture + titre" tapable, disposée N par ligne (P.GRID_COLS), utilisée par
-- les onglets Bibliothèque et Parcourir quand leur réglage "Couvertures" est activé.
--
-- item = { title, cover_bb (ou nil → boîte d'espace réservé), bold, callback, hold_callback }
-- cover_bb doit déjà être mis à l'échelle pour tenir dans P.GRID_COVER_W × P.GRID_COVER_H
-- (Covers.get dans core/covers.lua le fait pour vous).

P.GRID_COLS      = 3
-- Nombre minimum de rangées garanti par page de grille. Était auparavant forcé à 2 quel que soit
-- le calcul de hauteur ci-dessous, à l'époque où la barre d'onglets (P.TAB_H) était assez petite
-- pour que 2 rangées tiennent toujours avec de la marge. Maintenant que la barre d'onglets est bien
-- plus haute, forcer 2 rangées peut déborder de l'écran visible et recouvrir les
-- boutons de la barre d'onglets — donc les appelants doivent utiliser math.max(P.GRID_MIN_ROWS, computed)
-- uniquement comme un plancher de 1, jamais pour forcer plus de rangées que ce qui tient réellement.
P.GRID_MIN_ROWS  = 1
-- Marge supplémentaire réservée au-dessus de la barre d'onglets pour que la dernière rangée de la grille
-- ne soit jamais collée contre elle (garde les boutons d'onglets confortablement tapables).
P.GRID_BOTTOM_GAP = Screen:scaleBySize(20)
P.GRID_CELL_PAD  = Screen:scaleBySize(8)
-- Taille d'emplacement : pilote le calcul de colonnes de la grille (largeur/position de cellule) et reste
-- fixe pour que la disposition à 3 colonnes ne bouge jamais.
P.GRID_COVER_W   = math.floor((P.W - (P.GRID_COLS + 1) * P.GRID_CELL_PAD) / P.GRID_COLS)
P.GRID_COVER_H   = math.floor(P.GRID_COVER_W * 1.45)  -- ~2:3 book-cover ratio
-- Taille d'affichage réduite — utilisée uniquement par Parcourir (la grille "Populaire"), pas
-- la Bibliothèque, dont les couvertures étaient déjà assez petites telles quelles. Centrée dans
-- l'emplacement (inchangé) ci-dessus, pour que la disposition en colonnes de la grille ne bouge jamais.
P.GRID_COVER_SCALE   = 0.96
P.GRID_COVER_DISP_W  = math.floor(P.GRID_COVER_W * P.GRID_COVER_SCALE)
P.GRID_COVER_DISP_H  = math.floor(P.GRID_COVER_DISP_W * 1.45)
P.GRID_TITLE_H   = Screen:scaleBySize(40)             -- ~2 lines at small font
P.GRID_CELL_H    = P.GRID_COVER_H + P.GRID_TITLE_H + P.GRID_CELL_PAD

-- item.cover_w/cover_h (optionnel) définissent la taille de la boîte d'espace réservé quand il n'y a
-- pas encore de cover_bb — passez le même w/h que celui demandé à Covers.get pour qu'une
-- couverture manquante n'affiche pas une taille différente de ce que sera la vraie illustration.
-- Par défaut, la taille complète de l'emplacement (P.GRID_COVER_W × P.GRID_COVER_H).
function P.makeCoverCell(item)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local w = P.GRID_COVER_W
    -- Des appelants comme Bibliothèque peuvent fournir un emplacement plus petit quand deux rangées de grille
    -- déborderaient sinon dans la barre d'onglets fixe du bas.
    local cover_h = item.cover_h or P.GRID_COVER_H
    local cell_h  = item.cell_h  or (cover_h + P.GRID_TITLE_H + P.GRID_CELL_PAD)

    local cover_slot
    if item.cover_bb then
        -- item.cover_bb est pré-mis à l'échelle par l'appelant. Garder la hauteur d'emplacement
        -- explicite pour qu'un appelant puisse faire tenir deux rangées sans déborder
        -- de la barre d'onglets.
        local ImageWidget = require("ui/widget/imagewidget")
        cover_slot = CenterContainer:new{
            dimen = Geom:new{ w = w, h = cover_h },
            ImageWidget:new{
                image  = item.cover_bb,
                width  = item.cover_bb:getWidth(),
                height = item.cover_bb:getHeight(),
            },
        }
    else
        -- Boîte d'espace réservé pour que la grille reste alignée même sans couverture.
        local ph_w = item.cover_w or P.GRID_COVER_W
        local ph_h = item.cover_h or cover_h
        local ph_label = TextWidget:new{
            text    = item.title or "?",
            face    = Font:getFace("cfont", 13),
            fgcolor = Blitbuffer.COLOR_GRAY,
        }
        local placeholder = FrameContainer:new{
            bordersize = Screen:scaleBySize(1),
            color      = Blitbuffer.COLOR_LIGHT_GRAY,
            width      = ph_w,
            height     = ph_h,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = ph_w - 2 * Screen:scaleBySize(1), h = ph_h },
                ph_label,
            },
        }
        cover_slot = CenterContainer:new{
            dimen = Geom:new{ w = w, h = cover_h },
            placeholder,
        }
    end

    local title_box = TextBoxWidget:new{
        text      = item.title or "?",
        face      = Font:getFace("cfont", 13),
        bold      = item.bold or false,
        width     = w,
        height    = P.GRID_TITLE_H,
        alignment = "center",
    }

    local outer = FrameContainer:new{
        bordersize = 0,
        padding    = math.floor(P.GRID_CELL_PAD / 2),
        width      = w + P.GRID_CELL_PAD,
        height     = cell_h,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left", cover_slot, title_box },
    }
    return P.wrapTappable(outer, item.callback, item.hold_callback)
end

-- Dispose `items` (déjà tronqué à ce qui tient) dans une grille P.GRID_COLS,
-- renvoyée comme un VerticalGroup complété à exactement `height` — même
-- contrat que P.contentFrame, donc s'insère directement dans un corps d'onglet.
function P.makeCoverGrid(items, height)
    local grid_cell_h = (items[1] and items[1].cell_h) or P.GRID_CELL_H
    local blank_cell = function()
        return FrameContainer:new{
            bordersize = 0,
            width      = P.GRID_COVER_W + P.GRID_CELL_PAD,
            height     = grid_cell_h,
            background = Blitbuffer.COLOR_WHITE,
            VerticalSpan:new{ width = 0 },  -- FrameContainer needs a child widget
        }
    end
    local grid_rows = {}
    local i = 1
    while i <= #items do
        local row_cells = {}
        for c = 1, P.GRID_COLS do
            local it = items[i]
            table.insert(row_cells, it and P.makeCoverCell(it) or blank_cell())
            i = i + 1
        end
        table.insert(grid_rows, HorizontalGroup:new(row_cells))
    end
    return P.contentFrame(grid_rows, height)
end

-- ── Cases (tuiles) de texte ─────────────────────────────────────────────────
-- Une rangée de `cols` cases bordées : items = { {title, sub, callback}, … }.
-- Hauteur de rangée fixe : P.TILE_ROW_H (case + espace vertical).
P.TILE_H     = Screen:scaleBySize(88)
P.TILE_GAP   = Screen:scaleBySize(10)
P.TILE_ROW_H = P.TILE_H + P.TILE_GAP

function P.makeTileRow(items, cols)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    cols = cols or 2
    local gap    = P.TILE_GAP
    local tile_w = math.floor((P.W - 2 * P.MARGIN - gap * (cols - 1)) / cols)
    local border = Screen:scaleBySize(2)
    local parts  = { HorizontalSpan:new{ width = P.MARGIN } }
    for c = 1, cols do
        local it = items[c]
        local cell
        if it then
            local inner_w = tile_w - 2 * border - 2 * Screen:scaleBySize(8)
            local group = VerticalGroup:new{
                align = "center",
                TextBoxWidget:new{
                    text      = it.title or "?",
                    face      = Font:getFace("cfont", 16),
                    bold      = true,
                    width     = inner_w,
                    height    = Screen:scaleBySize(54),
                    height_overflow_show_ellipsis = true,
                    alignment = "center",
                },
            }
            if it.sub and it.sub ~= "" then
                table.insert(group, TextWidget:new{
                    text    = it.sub,
                    face    = Font:getFace("cfont", 13),
                    fgcolor = Blitbuffer.COLOR_GRAY,
                })
            end
            cell = FrameContainer:new{
                bordersize = border,
                color      = Blitbuffer.COLOR_DARK_GRAY,
                radius     = Screen:scaleBySize(6),
                padding    = 0,
                margin     = 0,
                width      = tile_w,
                height     = P.TILE_H,
                background = Blitbuffer.COLOR_WHITE,
                CenterContainer:new{
                    dimen = Geom:new{ w = tile_w - 2 * border, h = P.TILE_H - 2 * border },
                    group,
                },
            }
            cell = P.wrapTappable(cell, it.callback, it.hold_callback)
        else
            cell = FrameContainer:new{
                bordersize = 0, width = tile_w, height = P.TILE_H,
                background = Blitbuffer.COLOR_WHITE, VerticalSpan:new{ width = 0 },
            }
        end
        table.insert(parts, cell)
        if c < cols then table.insert(parts, HorizontalSpan:new{ width = gap }) end
    end
    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new(parts),
        VerticalSpan:new{ width = gap },
    }
end

-- ── Source row (Browse source picker) ────────────────────────────────────────
-- Ligne plus haute avec une tuile style "icône d'app" sombre à gauche — les
-- lettres capitales de la source en monogramme (ex. "NovelFrance" → "NF") car les sources
-- ne fournissent pas de vraies images de logo — titre + sous-titre à côté, et une
-- indication de statut optionnelle à droite. Reproduit le look en tuile-icône des listes
-- de sources d'autres apps de lecture.

local function _source_initials(name)
    name = name or "?"
    local caps = name:gsub("[^A-Z]", "")
    if #caps >= 2 then return caps:sub(1, 2) end
    if #caps == 1 then
        local second = name:sub(2, 2):upper()
        return caps .. (second ~= "" and second or "")
    end
    return name:sub(1, 2):upper()
end

-- Les sources peuvent fournir une vraie icône à resources/sources/<id>.png (minuscules).
-- Si présente, elle remplace le monogramme d'initiales en tuile noire ci-dessous.
local function _source_icon_path(id)
    if not id or id == "" then return nil end
    local path = _PLUGIN_ROOT .. "/resources/sources/" .. id:lower() .. ".png"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs.attributes(path, "mode") == "file" then
        return path
    end
    return nil
end

P.SOURCE_ICON  = Screen:scaleBySize(44)
P.SOURCE_ROW_H = P.SOURCE_ICON + 2 * Screen:scaleBySize(10)

-- opts : { id, mandatory, mandatory_bold, right_icon, right_callback, callback, hold_callback, width }
-- opts.right_icon (optionnel) : chemin d'une image affichée à droite de la ligne,
-- à la place du texte opts.mandatory.
-- opts.id, si fourni, sert à rechercher une image d'icône par source (voir
-- _source_icon_path ci-dessus) ; se rabat sur la tuile monogramme d'initiales.
-- opts.width (optionnel, défaut P.W) : largeur totale de la ligne — pour un
-- appelant plus étroit que l'écran (ex. panneau flottant des commentaires de
-- ui/readerview.lua). Tous les appels existants (Détails/Chapitres/Avis, pleine
-- largeur) gardent le même rendu qu'avant puisqu'ils ne passent pas cette option.
function P.makeSourceRow(name, subtitle, opts)
    opts = opts or {}
    local width     = opts.width or P.W
    local icon_size = opts.icon_size or P.SOURCE_ICON
    local icon_path = opts.icon_file or _source_icon_path(opts.id)
    local mandatory_w0 = ((opts.mandatory and opts.mandatory ~= "") or opts.right_icon)
        and Screen:scaleBySize(90) or 0
    local text_max_w = math.max(50, width - icon_size - 3 * P.MARGIN - mandatory_w0)

    local icon
    if opts.icon_bb then
        -- Blitbuffer déjà décodé et mis à l'échelle par l'appelant (ex. avatar
        -- d'auteur d'avis téléchargé et mis en cache par core/avatars.lua),
        -- par opposition aux icônes de sources bundlées résolues via id/fichier.
        local ImageWidget = require("ui/widget/imagewidget")
        icon = FrameContainer:new{
            bordersize = 0,
            width      = icon_size,
            height     = icon_size,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = icon_size, h = icon_size },
                ImageWidget:new{
                    image  = opts.icon_bb,
                    width  = opts.icon_bb:getWidth(),
                    height = opts.icon_bb:getHeight(),
                },
            },
        }
    elseif icon_path then
        local ImageWidget = require("ui/widget/imagewidget")
        icon = FrameContainer:new{
            bordersize = 0,
            width      = icon_size,
            height     = icon_size,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = icon_size, h = icon_size },
                ImageWidget:new{
                    file   = icon_path,
                    width  = icon_size,
                    height = icon_size,
                },
            },
        }
    else
        icon = FrameContainer:new{
            bordersize = 0,
            radius     = Screen:scaleBySize(8),
            width      = icon_size,
            height     = icon_size,
            background = Blitbuffer.COLOR_BLACK,
            CenterContainer:new{
                dimen = Geom:new{ w = icon_size, h = icon_size },
                TextWidget:new{
                    text    = _source_initials(name),
                    face    = Font:getFace("cfont", 16),
                    bold    = true,
                    fgcolor = Blitbuffer.COLOR_WHITE,
                },
            },
        }
    end

    local text_group = {
        align = "left",
        TextWidget:new{
            text    = name or "?",
            face    = Font:getFace("cfont", 17),
            bold    = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = text_max_w,
        },
    }
    if subtitle and subtitle ~= "" then
        table.insert(text_group, VerticalSpan:new{ width = Screen:scaleBySize(2) })
        table.insert(text_group, TextWidget:new{
            text    = subtitle,
            face    = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_GRAY,
            max_width = text_max_w,
        })
    end
    local text_block = VerticalGroup:new(text_group)

    local mandatory_w = ((opts.mandatory and opts.mandatory ~= "") or opts.right_icon)
        and Screen:scaleBySize(90) or 0
    local text_pad     = math.max(0, math.floor((icon_size - text_block:getSize().h) / 2))
    local text_wrapped = FrameContainer:new{
        bordersize     = 0,
        padding_top    = text_pad,
        padding_bottom = 0,
        width          = width - icon_size - 3 * P.MARGIN - mandatory_w,
        background     = Blitbuffer.COLOR_WHITE,
        text_block,
    }

    local row_children = {
        HorizontalSpan:new{ width = P.MARGIN },
        icon,
        HorizontalSpan:new{ width = P.MARGIN },
        text_wrapped,
    }
    if mandatory_w > 0 and opts.right_icon then
        local ImageWidget = require("ui/widget/imagewidget")
        local ri = Screen:scaleBySize(30)
        local right_icon_widget = CenterContainer:new{
            dimen = Geom:new{ w = mandatory_w, h = icon_size },
            ImageWidget:new{
                file   = opts.right_icon,
                width  = ri,
                height = ri,
            },
        }
        if opts.right_callback then
            right_icon_widget = P.wrapTappable(right_icon_widget, opts.right_callback, nil)
        end
        table.insert(row_children, right_icon_widget)
    elseif mandatory_w > 0 then
        table.insert(row_children, CenterContainer:new{
            dimen = Geom:new{ w = mandatory_w, h = icon_size },
            TextWidget:new{
                text    = tostring(opts.mandatory),
                face    = Font:getFace("cfont", 13),
                bold    = opts.mandatory_bold or false,
                fgcolor = opts.mandatory_bold and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            },
        })
    end

    local v_top    = math.floor((P.SOURCE_ROW_H - icon_size) / 2)
    local v_bottom = P.SOURCE_ROW_H - icon_size - v_top

    local frame = FrameContainer:new{
        bordersize     = 0,
        padding_top    = v_top,
        padding_bottom = v_bottom,
        width          = width,
        background     = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new(row_children),
    }
    return P.wrapTappable(frame, opts.callback, opts.hold_callback)
end

-- ── About popup ───────────────────────────────────────────────────────────────

local AboutWidget = InputContainer:extend{}

function AboutWidget:init()
    local W, H    = P.W, P.H
    local BOX_W   = math.floor(W * 0.85)
    local PADDING = Screen:scaleBySize(28)
    local INNER_W = BOX_W - 2 * PADDING
    local version = _G.SEFIRAH_VERSION or "0.2"

    -- ── Logo ──────────────────────────────────────────────────────────────────
    local logo_w = nil
    do
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
        if ok_lfs and lfs.attributes(_LOGO_PATH, "mode") == "file" then
            local logo_px    = Screen:scaleBySize(96)
            local ImageWidget = require("ui/widget/imagewidget")
            logo_w = CenterContainer:new{
                dimen = Geom:new{ w = INNER_W, h = logo_px },
                -- alpha = true compose par-dessus le fond blanc de la boîte,
                -- pour que les zones transparentes affichent du blanc au lieu du noir
                ImageWidget:new{
                    file   = _LOGO_PATH,
                    width  = logo_px,
                    height = logo_px,
                    alpha  = true,
                },
            }
        end
    end

    -- ── Descriptor text (word-wrapped) ────────────────────────────────────────
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local desc = TextBoxWidget:new{
        text      = T("Une simple bibliothèque de web novels pour KOReader.\nParcourez, suivez et exportez vos histoires préférées en EPUB pour les lire hors ligne."),
        face      = Font:getFace("cfont", 14),
        width     = INNER_W,
        alignment = "center",
    }

    -- ── Crédit ────────────────────────────────────────────────────────────────
    local credit = TextBoxWidget:new{
        text      = "thefoolwholovestheworld\nhttps://github.com/thefoolwholovestheworld/sefirah.koplugin",
        face      = Font:getFace("cfont", 13),
        width     = INNER_W,
        alignment = "center",
    }

    -- ── Assemble content ──────────────────────────────────────────────────────
    local group_args = { align = "center" }
    if logo_w then
        group_args[#group_args + 1] = logo_w
        group_args[#group_args + 1] = VerticalSpan:new{ width = Screen:scaleBySize(14) }
    end
    group_args[#group_args + 1] = TextWidget:new{
        text = "Sefirah",
        face = Font:getFace("cfont", 24),
        bold = true,
    }
    group_args[#group_args + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
    group_args[#group_args + 1] = TextWidget:new{
        text    = "v" .. version,
        face    = Font:getFace("cfont", 15),
        fgcolor = Blitbuffer.COLOR_GRAY,
    }
    group_args[#group_args + 1] = VerticalSpan:new{ width = Screen:scaleBySize(22) }
    group_args[#group_args + 1] = desc
    group_args[#group_args + 1] = VerticalSpan:new{ width = Screen:scaleBySize(16) }
    group_args[#group_args + 1] = credit
    group_args[#group_args + 1] = VerticalSpan:new{ width = Screen:scaleBySize(22) }
    group_args[#group_args + 1] = TextWidget:new{
        text    = T("toucher n'importe où pour fermer"),
        face    = Font:getFace("cfont", 12),
        fgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
    }

    local content = VerticalGroup:new(group_args)
    local box = FrameContainer:new{
        bordersize = Screen:scaleBySize(1),
        radius     = Screen:scaleBySize(8),
        background = Blitbuffer.COLOR_WHITE,
        padding    = PADDING,
        content,
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = W, h = H },
        box,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function AboutWidget:onTap()    UIManager:close(self); return true end
function AboutWidget:onClose()  UIManager:close(self); return true end
function AboutWidget:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end
function AboutWidget:onCloseWidget()
    UIManager:setDirty(self, function() return "partial", self.dimen end)
end

-- ── Menu déroulant générique (ancré en haut à droite, sous la barre de titre) ─
-- items = liste de { label, callback } (callback reçoit rien, doit fermer lui-même si besoin —
-- le menu se ferme automatiquement après l'appel).

function P.showDropdown(items, custom_y)
    local W, H   = P.W, P.H
    local ITEM_H = Screen:scaleBySize(48)
    local BORDER = Screen:scaleBySize(1)
    local face   = Font:getFace("cfont", 16)
    -- Largeur = max(290, texte le plus long + marges) pour ne plus couper la fin
    -- des libellés ; le menu s'étend vers la gauche (il reste calé à droite).
    local MENU_W = Screen:scaleBySize(290)
    for _, item in ipairs(items) do
        local m = TextWidget:new{ text = item[1], face = face }
        local need = m:getSize().w + 2 * Screen:scaleBySize(16) + 2 * BORDER + Screen:scaleBySize(4)
        m:free()
        if need > MENU_W then MENU_W = need end
    end
    MENU_W = math.min(MENU_W, W - 2 * Screen:scaleBySize(6))

    local menu_x    = math.max(Screen:scaleBySize(6), W - MENU_W - Screen:scaleBySize(8))
    -- Ancré sous les DEUX bandeaux empilés en haut des onglets (Sefirah + Bibliothèque/
    -- Parcourir/Sources) ; utiliser seulement P.TITLE_H le plaçait trop haut, sous le
    -- bandeau "Sefirah" au lieu de sous la barre de titre de l'onglet.
    local menu_y    = custom_y or (P.APP_H + P.TITLE_H + P.HAIRLINE)
    local n         = #items
    local inner_w   = MENU_W - 2 * BORDER
    local total_h   = n * ITEM_H + (n - 1) * BORDER + 2 * BORDER
    local menu_rect = Geom:new{ x = menu_x, y = menu_y, w = MENU_W, h = total_h }

    local dropdown  -- forward declaration
    local function close_menu() UIManager:close(dropdown) end

    -- Précalcule le rectangle écran de chaque item pour la détection de tap dans onTap.
    local item_rects = {}
    local iy = menu_y + BORDER
    for i = 1, n do
        item_rects[i] = Geom:new{ x = menu_x + BORDER, y = iy, w = inner_w, h = ITEM_H }
        iy = iy + ITEM_H + BORDER
    end

    local item_widgets = {}
    for i, item in ipairs(items) do
        local lbl   = TextWidget:new{ text = item[1], face = face }
        local lbl_h = lbl:getSize().h
        local pad_v = math.max(0, math.floor((ITEM_H - lbl_h) / 2))
        local frame = FrameContainer:new{
            bordersize     = 0,
            padding_left   = Screen:scaleBySize(16),
            padding_right  = Screen:scaleBySize(16),
            padding_top    = pad_v,
            padding_bottom = math.max(0, ITEM_H - lbl_h - pad_v),
            width          = inner_w,
            background     = Blitbuffer.COLOR_WHITE,
            lbl,
        }
        table.insert(item_widgets, frame)
        if i < n then
            table.insert(item_widgets, LineWidget:new{
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                dimen      = Geom:new{ w = inner_w, h = BORDER },
            })
        end
    end

    local vg_items = { align = "left" }
    for _, w in ipairs(item_widgets) do table.insert(vg_items, w) end
    local menu_box = FrameContainer:new{
        bordersize = BORDER,
        background = Blitbuffer.COLOR_WHITE,
        padding    = 0,
        VerticalGroup:new(vg_items),
    }

    local DropdownMenu = InputContainer:extend{}
    function DropdownMenu:init()
        self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
        self[1]    = menu_box
        local full = Geom:new{ x = 0, y = 0, w = W, h = H }
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = full } },
        }
    end
    function DropdownMenu:paintTo(bb, x, y)
        self.dimen.x = x
        self.dimen.y = y
        self[1]:paintTo(bb, menu_x, menu_y)
    end
    function DropdownMenu:onTap(_, ges)
        if not ges.pos then return true end
        if not ges.pos:intersectWith(menu_rect) then
            UIManager:close(self)
            return true
        end
        for i, rect in ipairs(item_rects) do
            if ges.pos:intersectWith(rect) then
                close_menu()
                items[i][2]()
                return true
            end
        end
        return true
    end
    function DropdownMenu:onShow()
        UIManager:setDirty(self, function() return "ui", self.dimen end)
    end
    function DropdownMenu:onCloseWidget()
        UIManager:setDirty(self, function() return "partial", self.dimen end)
    end

    dropdown = DropdownMenu:new{}
    UIManager:show(dropdown)
end

-- ── Hamburger menu ────────────────────────────────────────────────────────────

function P.showHamburgerMenu(close_fn, extra_items)
    local items = {}
    if extra_items then
        for _, it in ipairs(extra_items) do table.insert(items, it) end
    end
    table.insert(items, { T("À propos"), function()
        UIManager:show(AboutWidget:new{})
    end })
    table.insert(items, { T("Réglages"), function()
        require("ui.settings_dialog").show()
    end })
    table.insert(items, { T("Quitter Sefirah"), function()
        close_fn()
    end })
    P.showDropdown(items)
end

-- ── Title bar ─────────────────────────────────────────────────────────────────
-- on_back :  ← callback (nil = pas de bouton retour)
-- on_close : ✕ callback (nil = pas de bouton fermer)
-- on_menu :  ≡ callback (nil = pas de bouton menu) ; prime sur on_close si les deux sont définis

-- Barre de titre des 3 onglets principaux (Bibliothèque / Parcourir / Sources) :
-- titre aligné à gauche + jusqu'à 3 icônes à droite (recherche, tri, menu ⋮),
-- calquée sur l'app NovelFrance de référence. `icons` = liste ordonnée de
-- { glyph = "…", callback = fn } ; nil ou absent = pas d'icône à cet emplacement.
-- Bandeau d'app tout en haut des écrans d'onglet principaux : juste "Sefirah"
-- en gras, centré, sur fond clair — au-dessus de la barre de titre de l'onglet
-- (Bibliothèque/Parcourir/Sources), qui reste inchangée juste en dessous.
function P.makeAppTitleBar(on_tap)
    local H     = P.APP_H
    local W     = P.W
    local face  = Font:getFace("cfont", 16)
    local label = TextWidget:new{ text = "Sefirah", face = face, bold = true }
    local frame = FrameContainer:new{
        bordersize = 0, padding = 0,
        width      = W, height = H,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = H }, label },
    }
    -- on_tap (optionnel) : ex. Parcourir l'utilise pour remonter à la sélection de
    -- source sans avoir besoin d'une ligne "← Retour" dédiée dans le contenu.
    return P.wrapTappable(frame, on_tap)
end

-- Bascule « Novels | Mangas » affichée à la place du titre d'onglet.
-- kind_switch = { active = "novels"|"manga", on_select = function(kind) end }
-- options.counts : nombres par type, qui servent aussi à désactiver un type vide
-- (Bibliothèque). options.scope = "installed" | "available" : nombre d'extensions par
-- type, uniquement pour accorder « Novel(s) » / « Manga(s) » (jamais de désactivation).
function P.kindSwitch(on_changed, options)
    local ExtMgr = require("core.extmgr")
    options = options or {}
    local label_counts = options.counts
    if not label_counts and options.scope then
        pcall(function() label_counts = ExtMgr.kindCounts(options.scope == "available") end)
    end
    return {
        active    = ExtMgr.currentKind(),
        counts    = options.counts,
        label_counts = label_counts,
        on_select = function(kind)
            -- Un type sans contenu peut être désactivé (option utilisée uniquement
            -- par l'onglet Bibliothèque).
            if options.counts and (options.counts[kind] or 0) == 0 then return end
            ExtMgr.setKind(kind)
            if on_changed then on_changed() end
        end,
    }
end

function P.makeTabTitleBar(title, icons, on_title_tap, kind_switch)
    icons = icons or {}
    local H    = P.TITLE_H
    local W    = P.W
    local face = Font:getFace("cfont", 20)
    local BTN_W = Screen:scaleBySize(48)

    local right_cells = {}
    for _, ic in ipairs(icons) do
        local btn
        if ic.image then
            -- Icône bitmap (ex. loupe de recherche) : évite de dépendre d'un glyphe
            -- Unicode ("⌕") absent de la police système, qui s'affichait comme un
            -- gros carré noir de remplacement au lieu d'une petite icône.
            local ImageWidget = require("ui/widget/imagewidget")
            local icon_size = Screen:scaleBySize(22)
            btn = ImageWidget:new{
                file   = ic.image,
                width  = icon_size,
                height = icon_size,
                scale_factor = 0,
            }
        else
            btn = TextWidget:new{ text = ic.glyph, face = Font:getFace("cfont", 22) }
        end
        local f = FrameContainer:new{
            bordersize = 0, padding = 0,
            width = BTN_W, height = H,
            CenterContainer:new{ dimen = Geom:new{ w = BTN_W, h = H }, btn },
        }
        table.insert(right_cells, P.wrapTappable(f, ic.callback))
    end
    local right_w = BTN_W * #right_cells

    local title_natural_w, title_frame
    local switch_cells = nil
    if kind_switch then
        -- « Novels | Mangas » : le type actif est en gras et noir, l'autre en gris (toucher pour basculer).
        local PAD = Screen:scaleBySize(10)
        local function label_cell(kind, default_text)
            local active = kind_switch.active == kind
            local count = kind_switch.counts and kind_switch.counts[kind] or nil
            local disabled = kind_switch.counts ~= nil and (count or 0) == 0
            local text = default_text
            -- Pluriel seulement quand il y a plus d'un livre / d'une extension.
            local n = kind_switch.label_counts and kind_switch.label_counts[kind] or nil
            if n ~= nil then
                if kind == "novels" then
                    text = n > 1 and T("Novels") or T("Novel")
                else
                    text = n > 1 and T("Mangas") or T("Manga")
                end
            else
                text = T(default_text)
            end
            local tw = TextWidget:new{
                text = text, face = face, bold = active,
                fgcolor = disabled and Blitbuffer.COLOR_LIGHT_GRAY
                    or (active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY),
            }
            local w = tw:getSize().w + 2 * PAD
            local frame = FrameContainer:new{
                bordersize = 0, margin = 0, padding = 0,
                padding_left = PAD, padding_right = PAD,
                width = w, height = H,
                VerticalGroup:new{
                    align = "left",
                    VerticalSpan:new{ width = math.floor((H - tw:getSize().h) / 2) },
                    tw,
                },
            }
            local cb = (not active and not disabled) and function() kind_switch.on_select(kind) end or nil
            return P.wrapTappable(frame, cb), w
        end
        local lead = HorizontalSpan:new{ width = math.max(0, P.MARGIN - PAD) }
        local c1, w1 = label_cell("novels", "Novels")
        local sep = TextWidget:new{ text = "|", face = face, fgcolor = Blitbuffer.COLOR_GRAY }
        local sep_frame = FrameContainer:new{
            bordersize = 0, margin = 0, padding = 0, height = H, width = sep:getSize().w,
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = math.floor((H - sep:getSize().h) / 2) },
                sep,
            },
        }
        local c2, w2 = label_cell("manga", "Mangas")
        switch_cells = { lead, c1, sep_frame, c2 }
        title_natural_w = lead:getSize().w + w1 + sep:getSize().w + w2
    else
        local title_widget = TextWidget:new{ text = title or "", face = face, bold = true }
        title_natural_w = title_widget:getSize().w + P.MARGIN
        title_frame  = FrameContainer:new{
            bordersize     = 0,
            padding_left   = P.MARGIN,
            padding_right  = 0,
            width          = title_natural_w,
            height         = H,
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = math.floor((H - title_widget:getSize().h) / 2) },
                title_widget,
            },
        }
    end

    -- Espace élastique explicite : garantit que le groupe d'icônes (recherche/tri/menu)
    -- reste toujours collé au bord droit de l'écran, quelle que soit la longueur du titre.
    local spacer_w = math.max(0, W - title_natural_w - right_w)
    local spacer = HorizontalSpan:new{ width = spacer_w }

    -- on_title_tap (optionnel) : ex. Bibliothèque / Parcourir l'utilisent pour effacer
    -- directement la recherche/filtre en cours d'un simple appui sur le titre.
    local children
    if switch_cells then
        children = { table.unpack(switch_cells) }
        table.insert(children, spacer)
    else
        if on_title_tap then
            children = { P.wrapTappable(HorizontalGroup:new{ title_frame, spacer }, on_title_tap) }
        else
            children = { P.wrapTappable(title_frame, on_title_tap), spacer }
        end
    end
    for _, c in ipairs(right_cells) do table.insert(children, c) end
    return HorizontalGroup:new(children)
end

function P.makeTitleBar(title, on_back, on_close, on_menu, on_refresh, on_title_tap)
    local H     = P.TITLE_H
    local W     = P.W
    local face  = Font:getFace("cfont", 18)
    local bface = Font:getFace("cfont", 22)

    local right_cb    = on_menu or on_close
    local right_glyph = on_menu and "≡" or "✕"
    local BTN_W = Screen:scaleBySize(48)
    local mid_w = W - 2 * BTN_W  -- always symmetric so title is truly centered

    local function btnFrame(text_str, cb)
        local btn = TextWidget:new{ text = text_str, face = bface }
        local f = FrameContainer:new{
            bordersize = 0, padding = 0,
            width = BTN_W, height = H,
            CenterContainer:new{ dimen = Geom:new{ w = BTN_W, h = H }, btn },
        }
        return P.wrapTappable(f, cb)
    end

    local function spacer()
        return LineWidget:new{
            dimen      = Geom:new{ w = BTN_W, h = H },
            background = Blitbuffer.COLOR_WHITE,
        }
    end

    local left
    if on_back then
        left = btnFrame("←", on_back)
    elseif on_refresh then
        left = btnFrame("↺", on_refresh)
    else
        left = spacer()
    end

    -- Force le titre en noir : certaines builds de KOReader utilisent une
    -- couleur de texte par défaut qui peut être invisible sur le fond blanc.
    -- Le titre doit rester visible pour tous les romans, quelle que soit la source.
    -- Titre trop large pour la barre (ex. certains titres RoyalRoad à
    -- rallonge) : au lieu de le laisser déborder/se faire couper net par le
    -- bord de l'écran, on bascule sur un widget qui le coupe sur plusieurs
    -- lignes (police plus petite), toujours dans la même hauteur de barre
    -- H — P.TITLE_H est une constante utilisée ailleurs pour calculer
    -- CONTENT_H/SUB_H, donc on ne peut pas agrandir la barre elle-même.
    local avail_w = mid_w - Screen:scaleBySize(8)
    local single_line = TextWidget:new{
        text    = title or "",
        face    = face,
        bold    = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local title_widget
    if single_line:getSize().w <= avail_w then
        title_widget = single_line
    else
        local TextBoxWidget = require("ui/widget/textboxwidget")
        title_widget = TextBoxWidget:new{
            text      = title or "",
            face      = Font:getFace("cfont", 14),
            bold      = true,
            fgcolor   = Blitbuffer.COLOR_BLACK,
            width     = avail_w,
            height    = H,
            alignment = "center",
        }
    end
    local title_frame  = FrameContainer:new{
        bordersize = 0, padding = 0,
        width = mid_w, height = H,
        CenterContainer:new{ dimen = Geom:new{ w = mid_w, h = H }, title_widget },
    }
    -- on_title_tap (optionnel) : le titre lui-même devient un second point de
    -- sortie, en plus de la flèche ← — utile sur les écrans où le titre EST
    -- l'action de retour (ex. « Filtrer » sur l'écran de filtres).
    if on_title_tap then
        title_frame = P.wrapTappable(title_frame, on_title_tap)
    end

    return HorizontalGroup:new{
        left,
        title_frame,
        right_cb and btnFrame(right_glyph, right_cb) or spacer(),
    }
end

-- ── Tab bar (main navigation: Library / Browse / Sources) ────────────────────

function P.makeTabBar(active_id)
    local W      = P.W
    local H      = P.TAB_H
    local seg_w  = math.floor(W / #TABS)
    local cells  = {}

    for i, tab in ipairs(TABS) do
        local t        = tab
        local is_active = t.id == active_id
        local cell_w   = (i == #TABS) and (W - seg_w * (#TABS - 1)) or seg_w
        -- Taille de police fixe pour les 3 onglets (auparavant 22 si actif / 19
        -- sinon) : ce delta de taille donnait l'impression que la barre entière
        -- "rétrécissait/grossissait" à chaque changement d'onglet. Seuls le gras
        -- et la barre noire au-dessus indiquent désormais l'onglet actif.
        local face     = Font:getFace("cfont", 20)

        local ind_h = Screen:scaleBySize(4)
        local indicator = FrameContainer:new{
            bordersize = 0, padding = 0,
            width = cell_w, height = ind_h,
            background = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
            HorizontalSpan:new{ width = cell_w },
        }
        local lbl = TextWidget:new{ text = t.key and T(t.key) or t.label, face = face, bold = is_active }
        local cell_body = VerticalGroup:new{
            align = "center",
            indicator,
            VerticalSpan:new{ width = Screen:scaleBySize(20) },
            lbl,
        }
        local cell_frame = FrameContainer:new{
            bordersize = 0, padding = 0,
            width = cell_w, height = H,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = H }, cell_body },
        }

        if is_active then
            table.insert(cells, cell_frame)
        else
            table.insert(cells, P.wrapTappable(cell_frame, function()
                require("ui.main_widget").show(t.id)
            end))
        end
    end

    return HorizontalGroup:new(cells)
end

-- ── Custom tab bar (for in-screen 2-tab layouts like Details / Chapters) ─────

function P.makeCustomTabBar(tabs, active_id, switch_fn)
    local W     = P.W
    local H     = P.CUSTOM_TAB_H
    local seg_w = math.floor(W / #tabs)
    local cells = {}

    for i, tab in ipairs(tabs) do
        local t        = tab
        local is_active = t.id == active_id
        local cell_w   = (i == #tabs) and (W - seg_w * (#tabs - 1)) or seg_w
        local face     = Font:getFace("cfont", is_active and 22 or 19)

        local ind_h = Screen:scaleBySize(4)
        local indicator = FrameContainer:new{
            bordersize = 0, padding = 0,
            width = cell_w, height = ind_h,
            background = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
            HorizontalSpan:new{ width = cell_w },
        }
        local lbl = TextWidget:new{ text = t.label, face = face, bold = is_active }
        local cell_body = VerticalGroup:new{
            align = "center",
            indicator,
            VerticalSpan:new{ width = Screen:scaleBySize(20) },
            lbl,
        }
        local cell_frame = FrameContainer:new{
            bordersize = 0, padding = 0,
            width = cell_w, height = H,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = H }, cell_body },
        }

        if is_active then
            table.insert(cells, cell_frame)
        else
            table.insert(cells, P.wrapTappable(cell_frame, function()
                switch_fn(t.id)
            end))
        end
    end

    return HorizontalGroup:new(cells)
end

-- ── Barre d'actions compacte (icônes en haut à droite) ───────────────────────
-- Utilisée par les écrans Détails/Chapitres pour garder un maximum de place au contenu.
function P.makeCustomActionBar(icons)
    icons = icons or {}
    local W = P.W
    local H = Screen:scaleBySize(50)
    local BTN_W = Screen:scaleBySize(52)
    local cells = {}

    local used = 0
    for _, ic in ipairs(icons) do
        used = used + Screen:scaleBySize(ic.width or 52)
    end
    local left = math.max(0, W - used)
    if left > 0 then
        table.insert(cells, HorizontalSpan:new{ width = left })
    end

    for _, ic in ipairs(icons) do
        local cell_w = Screen:scaleBySize(ic.width or 52)
        local content
        if ic.image then
            -- Icône bitmap (télécharger / trier / rechercher un chapitre) : même
            -- raison que dans P.makeTabTitleBar, on évite les glyphes Unicode.
            local ImageWidget = require("ui/widget/imagewidget")
            local icon_size = Screen:scaleBySize(ic.size or 26)
            -- ic.image_off : variante à afficher à la place de ic.image quand
            -- ic.crossed est actif (ex. icône commentaire "barrée" quand les
            -- commentaires/l'onglet Avis sont masqués). Remplace l'icône
            -- entière au lieu d'un simple X superposé — préféré quand une
            -- vraie icône "désactivée" existe (cf. ui/detail.lua,
            -- chapter_actions_bar).
            local img = ImageWidget:new{
                file   = (ic.crossed and ic.image_off) or ic.image,
                width  = icon_size,
                height = icon_size,
                scale_factor = 0,
            }
            if ic.crossed and not ic.image_off then
                -- État « barré » (ex. commentaires masqués) : un X noir gras
                -- superposé à l'icône. On reste sur la lettre X d'une police
                -- système plutôt qu'un glyphe Unicode (✗, ⊘…), absent des
                -- polices de la liseuse et rendu en carré/point d'interrogation.
                local cross = TextWidget:new{
                    text    = "X",
                    face    = Font:getFace("cfont", math.floor((ic.size or 26) * 1.15)),
                    bold    = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                -- Croix centrée, remontée de quelques pixels (demandé 2026-09-15,
                -- après un essai parfaitement centré jugé encore un chouïa bas) :
                -- décalage vertical fixe en pixels plutôt qu'une fraction de la
                -- taille de l'icône, pour rester un ajustement discret à toute
                -- taille d'icône.
                --
                -- Cause du "chouïa bas" : cross:getSize().h correspond à la
                -- hauteur de police (ascent + descent), qui réserve de la
                -- place sous la ligne de base pour les jambages (g, y, p...)
                -- que "X" n'utilise jamais. Centrer sur cette hauteur place
                -- donc le glyphe visible plus bas que le centre réel du
                -- bouton — d'où le petit ajustement fixe ci-dessous.
                local box         = Geom:new{ w = icon_size, h = icon_size }
                local cross_size  = cross:getSize()
                local RAISE_PX    = Screen:scaleBySize(2)
                local pad_top     = math.max(0, math.floor((icon_size - cross_size.h) / 2) - RAISE_PX)
                local pad_left    = math.max(0, math.floor((icon_size - cross_size.w) / 2))
                content = OverlapGroup:new{
                    dimen = box:copy(),
                    img,
                    VerticalGroup:new{
                        VerticalSpan:new{ width = pad_top },
                        HorizontalGroup:new{ HorizontalSpan:new{ width = pad_left }, cross },
                    },
                }
            else
                content = img
            end
        elseif ic.label then
            local face = Font:getFace("cfont", ic.size or 18)
            content = TextWidget:new{
                text = ic.label,
                face = face,
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        else
            local face = Font:getFace("cfont", ic.size or 28)
            content = TextWidget:new{
                text = ic.glyph or "",
                face = face,
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        end
        local frame = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            width = cell_w,
            height = H,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = H }, content },
        }
        -- hold_callback : appui long sur l'icône (ex. masquer/afficher les
        -- commentaires depuis l'onglet Chapitres).
        table.insert(cells, P.wrapTappable(frame, ic.callback, ic.hold_callback))
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        width = W,
        height = H,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new(cells),
    }
end

-- ── Nav bar (< > row above the tab bar for paginated screens) ────────────────
-- nav = { page, max_pages (nil = inconnu), on_prev (nil = désactivé), on_next (nil = désactivé),
--         hide_page_label (optionnel) = true pour garder juste les flèches, sans le
--         repère "N / M" ni le tap pour aller à une page (ex. onglet Avis, où la
--         pagination dépend du remplissage des pages plutôt que d'un vrai numéro
--         de page stable pour l'utilisateur) }
-- Hauteur du widget émis = HAIRLINE + NAV_ROW_H.

function P.makeNavBar(nav)
    local W = P.W
    local H = nav.row_h or P.NAV_ROW_H

    -- Aide partagée : cadre de bouton de largeur/hauteur explicite, tapable en option
    local function cell(w, lbl_str, face, cb)
        local color = cb and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY
        local lbl   = TextWidget:new{ text = lbl_str, face = face, bold = true, fgcolor = color }
        local f     = FrameContainer:new{
            bordersize = 0, padding = 0, width = w, height = H,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = w, h = H }, lbl },
        }
        return cb and P.wrapTappable(f, cb) or f
    end

    local row

    if nav.max_pages then
        -- Disposition étendue (nombre de pages connu) : «  ‹  [N/M tapable]  ›  »
        local ff_w  = Screen:scaleBySize(52)   -- « and »
        local nav_w = Screen:scaleBySize(60)   -- ‹ and ›
        local mid_w = W - 2 * (ff_w + nav_w)

        local ff_face  = Font:getFace("cfont", 22)
        local arr_face = Font:getFace("cfont", 30)
        local lbl_face = Font:getFace("cfont", 18)

        -- Dialogue « aller à la page » (ouvert en tapant sur l'étiquette centrale)
        local function open_jump()
            local InputDialog = require("ui/widget/inputdialog")
            local dlg
            dlg = InputDialog:new{
                title      = T("Aller à la page (1 – ") .. tostring(nav.max_pages) .. ")",
                input_type = "number",
                buttons = {{
                    { text = "Go", is_enter_default = true, callback = function()
                        local n = tonumber(dlg:getInputText())
                        UIManager:close(dlg)
                        if n then nav.on_jump(n) end
                    end },
                    { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
                }},
            }
            UIManager:show(dlg)
        end

        local page_str  = tostring(nav.page) .. " / " .. tostring(nav.max_pages)
        local mid_lbl   = TextWidget:new{
            text    = nav.hide_page_label and "" or page_str,
            face    = lbl_face,
            bold    = true,
            fgcolor = Blitbuffer.COLOR_GRAY,
        }
        local mid_frame = FrameContainer:new{
            bordersize = 0, padding = 0, width = mid_w, height = H,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = mid_w, h = H }, mid_lbl },
        }
        local mid = (nav.on_jump and not nav.hide_page_label) and P.wrapTappable(mid_frame, open_jump) or mid_frame

        row = HorizontalGroup:new{
            cell(ff_w,  "«", ff_face,  nav.on_first),
            cell(nav_w, "‹", arr_face, nav.on_prev),
            mid,
            cell(nav_w, "›", arr_face, nav.on_next),
            cell(ff_w,  "»", ff_face,  nav.on_last),
        }
    else
        -- Total inconnu : on garde la pagination par swipe, mais on affiche aussi
        -- des boutons ‹ / › pour les écrans qui n'ont pas de nombre de pages connu
        -- (notamment Parcourir). Cela évite d'avoir une navigation invisible.
        local nav_w   = Screen:scaleBySize(72)
        local side_w  = math.max(0, math.floor((W - 2 * nav_w) / 2))
        local arr_face = Font:getFace("cfont", 30)
        row = HorizontalGroup:new{
            FrameContainer:new{
                bordersize = 0, padding = 0, width = side_w, height = H,
                background = Blitbuffer.COLOR_WHITE,
            },
            cell(nav_w, "‹", arr_face, nav.on_prev),
            cell(nav_w, "›", arr_face, nav.on_next),
            FrameContainer:new{
                bordersize = 0, padding = 0, width = side_w, height = H,
                background = Blitbuffer.COLOR_WHITE,
            },
        }
    end

    return VerticalGroup:new{
        align = "left",
        -- Ligne invisible (au lieu d'un LineWidget gris) : cette barre n'est
        -- utilisée que par Parcourir (Bibliothèque/Sources connaissent leur
        -- nombre de pages et passent par P.spacer(0) à la place). On garde la
        -- même hauteur réservée (P.HAIRLINE) pour ne rien décaler dans la mise
        -- en page, mais sans dessiner la ligne grise juste au-dessus de la
        -- barre d'onglets.
        LineWidget:new{
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = W, h = P.HAIRLINE },
        },
        row,
    }
end

-- ── FullScreenPanel ───────────────────────────────────────────────────────────

local FullScreenPanel = InputContainer:extend{
    body           = nil,
    close_callback = nil,
    swipe_close_callback = nil,
    partial        = false,
    nav            = nil,  -- { page, max_pages, on_prev, on_next, ... } — enables swipe paging
}

function FullScreenPanel:init()
    local W, H = P.W, P.H
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self.covers_fullscreen = true
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0,
        width = W, height = H,
        self.body,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }

    -- Glisser gauche/droite = page suivante/précédente, partout où un descripteur `nav` est
    -- défini (maintenu synchronisé entre les reconstructions via le 4e argument de swapBody).
    self.ges_events = self.ges_events or {}
    self.ges_events.Swipe = {
        GestureRange:new{ ges = "swipe", range = self.dimen }
    }
end

function FullScreenPanel:onSwipe(_, ges)
    local direction = ges and ges.direction

    -- Sur certaines versions/configurations de KOReader, le champ direction
    -- peut être absent de l'événement transmis au panneau. Dans ce cas,
    -- reconstruire la direction à partir des positions du geste afin que la
    -- pagination par glissement reste fonctionnelle.
    if not direction and ges and ges.pos and ges.end_pos then
        local dx = ges.end_pos.x - ges.pos.x
        local dy = ges.end_pos.y - ges.pos.y
        if math.abs(dx) >= math.abs(dy) then
            direction = dx < 0 and "west" or "east"
        else
            direction = dy < 0 and "north" or "south"
        end
    end

    -- Geste global Sefirah : glisser du haut vers le bas, depuis n'importe
    -- quel endroit d'un écran Sefirah, ferme le panneau et rend la main à
    -- KOReader. Le callback du panneau est volontairement utilisé ici :
    -- sur le lecteur il nettoie aussi l'état privé de ReaderView.
    if direction == "south" then
        -- Le swipe vertical est une sortie du plugin Sefirah.
        -- Un écran peut fournir un callback dédié afin de nettoyer ses
        -- propres références avant de fermer toute la pile Sefirah.
        if self.swipe_close_callback then
            self.swipe_close_callback()
        else
            self:onClose()
        end
        return true
    end

    local nav = self.nav
    if not nav then return false end
    if direction == "west" and nav.on_next then
        nav.on_next()
        return true
    elseif direction == "east" and nav.on_prev then
        nav.on_prev()
        return true
    end
    return false
end

function FullScreenPanel:onShow()
    if self.partial == "flash" then
        -- Rafraîchissement flashui explicite et complet — utilisé quand un changement d'onglet passe
        -- vers/depuis un écran avec une image (la couverture), pour que tout fantôme e-ink
        -- laissé par l'image soit entièrement effacé au lieu de persister sous le
        -- nouveau contenu.
        _partial_count = 0
        UIManager:setDirty(self, function() return "flashui", self.dimen end)
    elseif self.partial then
        -- tourne-pages de showCustomTabPanel (vue détails/chapitre)
        _partial_count = _partial_count + 1
        local rtype = (_partial_count % _FLASHUI_INTERVAL == 0) and "flashui" or "partial"
        UIManager:setDirty(self, function() return rtype, self.dimen end)
    else
        _partial_count = 0
        UIManager:setDirty(self, function() return "full", self.dimen end)
    end
end

function FullScreenPanel:onCloseWidget()
    local rtype = self.partial and "partial" or "full"
    UIManager:setDirty(self, function() return rtype, self.dimen end)
end

-- Remplace le corps sur place sans fermer/rouvrir le panneau.
-- same_tab=true  → tourne-page dans un onglet  → "partial" (rapide, sans flash)
-- same_tab=false → changement d'onglet       → "ui"      (propre, sans flash complet)
function FullScreenPanel:swapBody(new_body, new_close_fn, same_tab, new_nav, new_swipe_close_fn)
    self[1][1]          = new_body
    self.close_callback = new_close_fn
    self.swipe_close_callback = new_swipe_close_fn
    self.nav             = new_nav
    local rtype
    if same_tab then
        _partial_count = _partial_count + 1
        rtype = (_partial_count % _FLASHUI_INTERVAL == 0) and "flashui" or "partial"
    else
        _partial_count = 0
        rtype = "ui"
    end
    UIManager:setDirty(self, function() return rtype, self.dimen end)
end

function FullScreenPanel:onClose()
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
    return true
end

P.FullScreenPanel = FullScreenPanel

-- ── Content frame ─────────────────────────────────────────────────────────────
-- Renvoie un VerticalGroup qui indique exactement `height` pixels de haut en ajoutant
-- un espaceur de remplissage. Cela garantit que la barre d'onglets tombe toujours au bon y.

function P.contentFrame(rows, height)
    local used = 0
    for _, r in ipairs(rows) do
        local s = r:getSize()
        used = used + (s.h or 0)
    end
    local fill = math.max(0, height - used)
    local children = {}
    for _, r in ipairs(rows) do table.insert(children, r) end
    if fill > 0 then
        table.insert(children, VerticalSpan:new{ width = fill })
    end
    return VerticalGroup:new{ align = "left", table.unpack(children) }
end

-- ── Panel builders ────────────────────────────────────────────────────────────

-- Construit le VerticalGroup du corps pour un écran d'onglet principal.
-- Séparé de show pour que main_widget puisse le remplacer sur place pour les tourne-pages / changements d'onglet.
local function _buildTabBody(active_id, rows, title, close_fn, nav, actions)
    -- La pagination est normalement masquée sur les onglets principaux pour
    -- conserver la place maximale au contenu. Certaines pages en ont toutefois
    -- besoin visuellement (ex. la sélection des extensions dans Parcourir).
    -- `show_visual = true` force alors l'affichage de « ‹ N/M › ».
    local show_navbar = nav and nav.show_visual == true
    local content_h   = show_navbar and P.CONTENT_H_NAV or P.CONTENT_H

    actions = actions or {}
    local icons = {}
    if actions.on_search then table.insert(icons, { image = _SEARCH_ICON_PATH, callback = actions.on_search }) end
    if actions.on_sort   then table.insert(icons, { image = _FILTER_ICON_PATH, callback = actions.on_sort   }) end
    -- Filtre de langues (Parcourir / Sources) : même icône que le tri (sort.png).
    if actions.on_lang   then table.insert(icons, { image = _FILTER_ICON_PATH, callback = actions.on_lang   }) end
    table.insert(icons, { glyph = "⋮", callback = function() P.showHamburgerMenu(close_fn, actions.menu_extra_items) end })

    return VerticalGroup:new{
        align = "left",
        P.makeAppTitleBar(actions.on_logo_tap),
        P.hairline(),
        P.makeTabTitleBar(title, icons, actions.on_title_tap, actions.kind_switch),
        P.hairline(),
        -- Fixe la zone de contenu à sa hauteur réelle. Certaines pages (notamment
        -- la première page de Parcourir) contiennent plus de lignes que prévu ;
        -- sans ce cadre, le VerticalGroup grandit et pousse la barre
        -- Bibliothèque / Parcourir / Sources hors écran.
        -- Zone strictement réservée au contenu : sa hauteur ne dépend jamais
        -- du nombre de lignes reçues par l'onglet. La barre principale reste
        -- donc toujours au même endroit, même quand Parcourir possède beaucoup
        -- d'extensions (elles sont paginées côté browse.lua).
        FrameContainer:new{
            bordersize = 0, padding = 0,
            width = P.W, height = content_h,
            P.contentFrame(rows, content_h),
        },
        show_navbar and P.makeNavBar(nav) or P.spacer(0),
        P.makeTabBar(active_id),
    }
end

P.buildTabBody = _buildTabBody

-- Construit et affiche un écran d'onglet principal (Bibliothèque / Parcourir / Sources).
-- Pour l'affichage initial uniquement — les reconstructions suivantes passent par FullScreenPanel:swapBody.
function P.showTabPanel(active_id, rows, title, close_fn, nav, actions)
    local body  = _buildTabBody(active_id, rows, title, close_fn, nav, actions)
    local panel = FullScreenPanel:new{ body = body, close_callback = close_fn, nav = nav }
    UIManager:show(panel)
    return panel
end

-- ── Filter panel (multi-column picker + Appliquer) ───────────────────────────
-- Écran plein-écran à N colonnes côte à côte (une par groupe de filtre,
-- ex. Catégorie / Période), chaque option touchable togglant la sélection
-- LOCALE (pas encore appliquée), plus un gros bouton "Appliquer" en bas qui
-- valide. ← revient en arrière SANS appliquer. Généralisé ici (plutôt que
-- codé en dur dans browse.lua) pour que toute extension déclarant
-- `ext.popularFilters` en bénéficie.
--
-- groups    : { { key, label, options = { {id,label}, ... } }, ... }
-- selection : { [key] = selected_id, ... } — sélection de départ, jamais mutée
--             (une copie de travail locale est utilisée jusqu'au tap sur Appliquer)
-- on_apply(selection) : appelé avec la copie de travail au tap sur "Appliquer"
-- on_back()            : appelé au tap sur ← (annule, sélection de départ inchangée)
function P.showFilterPanel(title, groups, selection, on_apply, on_back)
    local work = {}
    for k, v in pairs(selection or {}) do work[k] = v end

    local header_face = Font:getFace("cfont", 17)
    local opt_face    = Font:getFace("cfont", 16)

    -- Largeur/hauteur disponibles pour la grille d'options.
    local MIN_COL_W = Screen:scaleBySize(170)
    local cols      = math.max(1, math.floor(P.W / MIN_COL_W))

    local NAV_H    = Screen:scaleBySize(44)
    local header_h = P.ROW_H
    local full_h   = P.SUB_H - P.BIG_BTN_H - 2 * Screen:scaleBySize(8)

    local function rows_per_col(with_nav)
        local h = full_h - header_h - P.HAIRLINE - (with_nav and (NAV_H + P.HAIRLINE) or 0)
        return math.max(1, math.floor(h / P.ROW_H))
    end

    -- ── Répartition en pages ────────────────────────────────────────────────
    -- Demandé (2026-09-15) : ne plus réserver systématiquement une page par
    -- type de filtre — les petits types (Statut, Pays...) doivent partager
    -- une page quand la largeur le permet, alors qu'un gros type (Genre) qui
    -- ne tient pas sur une seule page continue de s'étaler sur plusieurs,
    -- mais SEUL (jamais un type scindé pour faire de la place à un autre).
    --
    -- Empilement glouton par « étagères » : chaque groupe a besoin d'un
    -- nombre de colonnes = ceil(options / per_col). S'il tient dans les
    -- colonnes restantes de la page en cours, il la rejoint ; sinon une
    -- nouvelle page démarre. Un groupe qui ne tient dans AUCUNE page (besoin
    -- > cols) reçoit ses propres pages pleine largeur, seul.
    local function pack(per_col)
        local pages = {}
        local cur_entries, cur_used = {}, 0
        local function flush()
            if cur_used > 0 then
                table.insert(pages, cur_entries)
                cur_entries, cur_used = {}, 0
            end
        end
        for gi, g in ipairs(groups) do
            local n_opts  = math.max(1, #(g.options or {}))
            local needed  = math.max(1, math.ceil(n_opts / per_col))
            if needed > cols then
                flush()
                local n_pages = math.ceil(needed / cols)
                for k = 1, n_pages do
                    table.insert(pages, { { group = gi, cols = cols, opt_page = k, opt_pages = n_pages } })
                end
            else
                if cur_used + needed > cols then flush() end
                table.insert(cur_entries, { group = gi, cols = needed, opt_page = 1, opt_pages = 1 })
                cur_used = cur_used + needed
            end
        end
        flush()
        return pages
    end

    -- Deux passes : la barre de pagination ne réserve de la hauteur que si
    -- elle est réellement nécessaire, et sa présence change per_col — donc le
    -- découpage est refait une fois qu'on sait si elle s'affiche.
    local per_col   = rows_per_col(false)
    local pages     = pack(per_col)
    local has_nav   = #pages > 1
    if has_nav then
        per_col = rows_per_col(true)
        pages   = pack(per_col)
        has_nav = #pages > 1
    end

    local page = 1
    local content_h = full_h - (has_nav and (NAV_H + P.HAIRLINE) or 0)
    local col_w = math.floor((P.W - (cols - 1) * P.HAIRLINE) / cols)

    local panel         -- déclaration anticipée (assignée après la 1re construction)
    local build_body    -- déclaration anticipée (référencée par les callbacks de tap)
    local safe_rebuild   -- déclaration anticipée

    -- Correctif (2026-09-15) : la flèche ← appelait on_back() directement,
    -- SANS jamais fermer le panneau lui-même (contrairement à « Appliquer »,
    -- qui fait bien UIManager:close(panel) avant d'agir) — le panneau de
    -- filtres restait donc un widget actif au-dessus de l'écran Parcourir
    -- fraîchement redessiné en dessous, d'où l'impression que « ça ne
    -- quitte pas ». do_back ferme explicitement le panneau d'abord.
    local function do_back()
        UIManager:close(panel)
        if on_back then on_back() end
    end

    -- ── Reconstruction différée (correctif 2026-09-15) ──────────────────────
    -- Avant, chaque tap (option, flèche de page) appelait panel:swapBody(...)
    -- DIRECTEMENT dans le callback du geste. Exactement le même piège que
    -- documenté dans ui/detail.lua pour le changement d'onglet Détails/
    -- Chapitres/Avis : remplacer l'arbre de widgets PENDANT que KOReader est
    -- encore en train de traiter l'événement tactile en cours laisse l'ancien
    -- InputContainer dans la chaîne de traitement — sur cet écran, ça se
    -- traduisait par « plus aucun tap ne répond » après la toute première
    -- interaction (flèche ←, flèche de page, ou tap sur une option), symptôme
    -- rapporté par l'utilisateur. Fix : mémoriser le changement puis
    -- reconstruire au prochain tick de l'UI, jamais pendant le geste — même
    -- pattern que Detail.rebuild/switch_tab.
    local generation = 0
    safe_rebuild = function()
        generation = generation + 1
        local my_generation = generation
        UIManager:scheduleIn(0, function()
            if my_generation ~= generation then return end
            if not panel then return end
            panel:swapBody(build_body(), on_back, true, has_nav and {
                on_prev = page > 1 and function() page = page - 1; safe_rebuild() end or nil,
                on_next = page < #pages and function() page = page + 1; safe_rebuild() end or nil,
            } or nil)
        end)
    end

    -- Un bloc = un type de filtre entier (en-tête + ses options réparties sur
    -- entry.cols colonnes). Plusieurs blocs peuvent apparaître côte à côte sur
    -- une même page (regroupement des petits types), séparés par un filet
    -- vertical pour bien distinguer les types entre eux.
    local function build_entry_block(entry)
        local g       = groups[entry.group]
        local opts    = g.options or {}
        local n_opts  = math.max(1, #opts)
        local block_w = entry.cols * col_w + (entry.cols - 1) * P.HAIRLINE

        local first_opt = 1
        if entry.opt_pages > 1 then
            first_opt = (entry.opt_page - 1) * entry.cols * per_col + 1
        end
        local last_opt = math.min(first_opt + entry.cols * per_col - 1, n_opts)

        local header_text = T(g.label or "")
        if entry.opt_pages > 1 then
            header_text = header_text .. "  (" .. tostring(entry.opt_page) ..
                "/" .. tostring(entry.opt_pages) .. ")"
        end
        local header = TextWidget:new{
            text = header_text, face = header_face, bold = true,
            max_width = block_w - P.MARGIN - Screen:scaleBySize(8),
        }
        local header_frame = FrameContainer:new{
            bordersize = 0, padding_top = Screen:scaleBySize(10),
            padding_bottom = Screen:scaleBySize(6), padding_left = P.MARGIN,
            width = block_w, background = Blitbuffer.COLOR_WHITE,
            header,
        }
        local header_line = LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new{ w = block_w, h = P.HAIRLINE },
        }

        local inner_cols = {}
        for lc = 1, entry.cols do
            local col_first = first_opt + (lc - 1) * per_col
            local children = { align = "left" }
            for oi = col_first, math.min(col_first + per_col - 1, last_opt) do
                local opt = opts[oi]
                local selected
                if g.multi then
                    -- Sélection multiple : work[key] = « id1,id2,… » ; « Tous » (id "") = rien de coché.
                    if opt.id == "" then
                        selected = (work[g.key] or "") == ""
                    else
                        selected = ("," .. (work[g.key] or "") .. ","):find("," .. opt.id .. ",", 1, true) ~= nil
                    end
                else
                    selected = work[g.key] == opt.id
                end
                local lbl = TextWidget:new{
                    text    = (selected and "✓ " or "   ") .. T(opt.label),
                    face    = opt_face,
                    bold    = selected,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = col_w - P.MARGIN - Screen:scaleBySize(8),
                }
                local lbl_h = lbl:getSize().h
                local pad_v = math.max(0, math.floor((P.ROW_H - lbl_h) / 2))
                local frame = FrameContainer:new{
                    bordersize = 0, padding_left = P.MARGIN, padding_right = Screen:scaleBySize(4),
                    padding_top = pad_v, padding_bottom = math.max(0, P.ROW_H - lbl_h - pad_v),
                    width = col_w, background = Blitbuffer.COLOR_WHITE,
                    lbl,
                }
                local gkey, oid, gdefault = g.key, opt.id, g.default
                table.insert(children, P.wrapTappable(frame, function()
                    -- Re-taper l'option déjà choisie la désélectionne (retour
                    -- à la valeur par défaut du groupe) au lieu de rester
                    -- bloquée dessus — demandé 2026-09-15.
                    if g.multi then
                        local list = {}
                        local present = false
                        for id in tostring(work[gkey] or ""):gmatch("[^,]+") do
                            if id == oid then present = true else list[#list + 1] = id end
                        end
                        if oid ~= "" and not present then list[#list + 1] = oid end
                        work[gkey] = table.concat(list, ",")
                    else
                        work[gkey] = (work[gkey] == oid) and gdefault or oid
                    end
                    safe_rebuild()
                end))
            end
            -- Pas de filet entre les colonnes internes d'un même type (2026-09-15) :
            -- elles appartiennent au même groupe, un séparateur n'y apporte
            -- rien et ne fait qu'alourdir l'écran. Seul le filet ENTRE deux
            -- types différents (build_page_body ci-dessous) reste, lui, utile.
            table.insert(inner_cols, VerticalGroup:new(children))
        end

        return VerticalGroup:new{ align = "left", header_frame, header_line, HorizontalGroup:new(inner_cols) }
    end

    local function build_page_body()
        local entries = pages[page]
        local blocks  = {}
        local total_w = 0
        for ei, entry in ipairs(entries) do
            local block = build_entry_block(entry)
            total_w = total_w + block:getSize().w
            table.insert(blocks, block)
            if ei < #entries then
                table.insert(blocks, LineWidget:new{
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                    dimen = Geom:new{ w = P.HAIRLINE, h = content_h },
                })
                total_w = total_w + P.HAIRLINE
            end
        end
        -- Centré horizontalement plutôt que collé à gauche (2026-09-15) :
        -- une page avec peu de types (ex. Statut seul) n'occupait alors pas
        -- tout l'écran, d'où l'impression que les filtres étaient "entassés"
        -- contre le bord gauche. Un HorizontalSpan de tête (plutôt qu'un
        -- CenterContainer) ne touche que l'axe horizontal — le contenu reste
        -- ancré en haut, comme avant.
        if total_w < P.W then
            local left_pad = math.floor((P.W - total_w) / 2)
            table.insert(blocks, 1, HorizontalSpan:new{ width = left_pad })
        end
        return HorizontalGroup:new(blocks)
    end

    -- Barre de pagination compacte « ‹  n / m  › » sous la grille — les
    -- flèches passent par safe_rebuild (jamais de swapBody direct dans le
    -- geste, cf. plus haut). Le glissement gauche/droite fait la même chose
    -- via panel.nav (câblé dans safe_rebuild et à la création du panneau).
    local function build_nav()
        local arr_face = Font:getFace("cfont", 26)
        local lbl_face = Font:getFace("cfont", 16)
        local side_w   = Screen:scaleBySize(80)
        local mid_w    = P.W - 2 * side_w

        local function arrow(text, enabled, delta)
            local color = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY
            local lbl = TextWidget:new{ text = text, face = arr_face, bold = true, fgcolor = color }
            local f = FrameContainer:new{
                bordersize = 0, padding = 0, width = side_w, height = NAV_H,
                background = Blitbuffer.COLOR_WHITE,
                CenterContainer:new{ dimen = Geom:new{ w = side_w, h = NAV_H }, lbl },
            }
            if not enabled then return f end
            return P.wrapTappable(f, function()
                page = page + delta
                safe_rebuild()
            end)
        end

        local mid = TextWidget:new{
            text = tostring(page) .. " / " .. tostring(#pages),
            face = lbl_face, bold = true, fgcolor = Blitbuffer.COLOR_GRAY,
            max_width = mid_w - Screen:scaleBySize(8),
        }
        return VerticalGroup:new{
            align = "left",
            LineWidget:new{
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                dimen = Geom:new{ w = P.W, h = P.HAIRLINE },
            },
            HorizontalGroup:new{
                arrow("‹", page > 1, -1),
                FrameContainer:new{
                    bordersize = 0, padding = 0, width = mid_w, height = NAV_H,
                    background = Blitbuffer.COLOR_WHITE,
                    CenterContainer:new{ dimen = Geom:new{ w = mid_w, h = NAV_H }, mid },
                },
                arrow("›", page < #pages, 1),
            },
        }
    end

    build_body = function()
        local children = {
            P.makeTitleBar(title, do_back, nil, nil, nil, do_back),
            P.hairline(),
            P.contentFrame({ build_page_body() }, content_h),
        }
        if has_nav then
            table.insert(children, build_nav())
        end
        table.insert(children, P.makeBigButton(T("Appliquer"), function()
            UIManager:close(panel)
            on_apply(work)
        end))
        return VerticalGroup:new{ align = "left", table.unpack(children) }
    end

    panel = FullScreenPanel:new{
        body = build_body(),
        close_callback = on_back,
        -- nav (west/east) active le glissement pour changer de page, en plus
        -- des flèches ‹ › — mêmes callbacks, toujours via safe_rebuild.
        nav = has_nav and {
            on_prev = page > 1 and function() page = page - 1; safe_rebuild() end or nil,
            on_next = page < #pages and function() page = page + 1; safe_rebuild() end or nil,
        } or nil,
    }
    UIManager:show(panel)
    return panel
end

-- Construit et affiche un sous-écran (options d'export, réglages de source).
-- Pas de bouton X — les sous-écrans n'utilisent que ← retour ; X vit sur les écrans d'onglet principaux.
function P.showSubPanel(title, rows, on_back, close_fn)
    local body = VerticalGroup:new{
        align = "left",
        P.makeTitleBar(title, on_back, nil),
        P.hairline(),
        P.contentFrame(rows, P.SUB_H),
    }
    local panel = FullScreenPanel:new{ body = body, close_callback = close_fn }
    UIManager:show(panel)
    return panel
end

-- Construit et affiche un écran avec une barre à 2 onglets personnalisée (ex. Détails / Chapitres).
-- Pas de bouton X — utilise uniquement ← retour ; X vit sur les écrans d'onglet principaux.
-- nav (optionnel) = { page, max_pages, on_prev, on_next, on_first, on_last, on_jump }
-- partial (optionnel) = true pour utiliser un rafraîchissement e-ink partiel au lieu de complet.
function P.buildCustomTabBody(tabs, active_id, switch_fn, rows, title, on_back, nav, actions)
    actions = actions or {}
    local ACTION_H = Screen:scaleBySize(50)
    local has_actions = #actions > 0
    -- Some paginated screens (notably Avis) keep swipe pagination but hide the
    -- visual navigation bar. In that case, give the saved nav-bar height back
    -- to the content so there is no empty strip at the bottom.
    local visual_nav = nav and not nav.hide_visual
    local base_h = visual_nav and P.CUSTOM_CONTENT_H_NAV or P.CUSTOM_CONTENT_H
    local content_h = has_actions and (base_h - ACTION_H - P.HAIRLINE) or base_h
    local children = {
        P.makeTitleBar(title, on_back, nil),
        P.hairline(),
    }
    if has_actions then
        table.insert(children, P.makeCustomActionBar(actions))
        table.insert(children, P.hairline())
    end
    table.insert(children, P.contentFrame(rows, math.max(P.ROW_H, content_h)))
    if visual_nav then
        table.insert(children, P.makeNavBar(nav))
    else
        table.insert(children, P.spacer(0))
    end
    table.insert(children, P.makeCustomTabBar(tabs, active_id, switch_fn))
    return VerticalGroup:new{ align = "left", table.unpack(children) }
end

function P.showCustomTabPanel(tabs, active_id, switch_fn, rows, title, on_back, close_fn, nav, partial, actions)
    local body = P.buildCustomTabBody(tabs, active_id, switch_fn, rows, title, on_back, nav, actions)
    local panel = FullScreenPanel:new{ body = body, close_callback = close_fn, partial = partial or false, nav = nav }
    UIManager:show(panel)
    return panel
end

return P
