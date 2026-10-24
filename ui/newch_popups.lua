-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- ui/newch_popups.lua — popups liés aux nouveaux chapitres :
--   • Popups.favoritePrompt(novel, on_done) : proposé à l'ajout d'un roman aux
--     favoris, avec deux cases à cocher « ne plus demander » ;
--   • Popups.newChapters(opts) : alerte « nouveau chapitre » avec la couverture
--     au milieu du popup. Utilisable partout dans KOReader.

local T = require("core.i18n").T

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local Screen = Device.screen

local Popups = {}

-- ── Case à cocher dessinée (carré + ✓), tapable ──────────────────────────────

local function checkbox_row(width, label, checked, on_tap)
    local box_sz = Screen:scaleBySize(30)
    local inner  = checked
        and TextWidget:new{ text = "✓", face = Font:getFace("cfont", 20), bold = true }
        or  HorizontalSpan:new{ width = 1 }
    local box = FrameContainer:new{
        bordersize = Screen:scaleBySize(2),
        padding    = 0,
        margin     = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = box_sz, h = box_sz },
            inner,
        },
    }
    local gap = Screen:scaleBySize(12)
    local text = TextBoxWidget:new{
        text  = label,
        face  = Font:getFace("cfont", 15),
        width = width - box:getSize().w - gap,
    }
    local row = HorizontalGroup:new{ align = "center", box, HorizontalSpan:new{ width = gap }, text }

    -- HorizontalGroup:getSize() renvoie une table simple (pas une Geom) : sans
    -- conversion, GestureRange plante (« attempt to call method 'contains' »).
    local sz = row:getSize()
    local wrapper = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h }, row }
    wrapper.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = wrapper.dimen } },
    }
    wrapper.onTap = function() on_tap(); return true end
    return wrapper
end

local function back_key_events()
    if Device:hasKeys() then
        return { Close = { { Device.input.group.Back } } }
    end
    return nil
end

-- ── 1. Popup d'ajout aux favoris ─────────────────────────────────────────────

local FavPrompt = InputContainer:extend{
    novel_title = "",
    on_done     = nil,
}

function FavPrompt:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.state = self.state or { no_this = false, no_all = false }
    self.key_events = back_key_events()
    self:_build()
end

function FavPrompt:_build()
    local W, H    = Screen:getWidth(), Screen:getHeight()
    local BOX_W   = math.floor(W * 0.88)
    local PADDING = Screen:scaleBySize(22)
    local INNER_W = BOX_W - 2 * PADDING
    local st      = self.state

    local group = VerticalGroup:new{ align = "center" }
    local function add(w) group[#group + 1] = w end

    add(TextBoxWidget:new{
        text      = T("Être prévenu des nouveaux chapitres ?"),
        face      = Font:getFace("cfont", 20),
        bold      = true,
        width     = INNER_W,
        alignment = "center",
    })
    add(VerticalSpan:new{ width = Screen:scaleBySize(10) })
    add(TextBoxWidget:new{
        text      = self.novel_title,
        face      = Font:getFace("cfont", 16),
        width     = INNER_W,
        alignment = "center",
    })
    add(VerticalSpan:new{ width = Screen:scaleBySize(10) })
    add(TextBoxWidget:new{
        text      = T("Un popup s'affichera n'importe où dans KOReader (quand le Wi-Fi est actif) dès qu'un nouveau chapitre est publié."),
        face      = Font:getFace("cfont", 14),
        width     = INNER_W,
        alignment = "center",
    })
    add(VerticalSpan:new{ width = Screen:scaleBySize(18) })

    add(checkbox_row(INNER_W, T("Ne plus me poser la question pour ce roman"), st.no_this, function()
        st.no_this = not st.no_this
        self:_refresh()
    end))
    add(VerticalSpan:new{ width = Screen:scaleBySize(12) })
    add(checkbox_row(INNER_W, T("Ne plus me poser la question pour tous les romans"), st.no_all, function()
        st.no_all = not st.no_all
        self:_refresh()
    end))
    add(VerticalSpan:new{ width = Screen:scaleBySize(18) })

    local function answer(notify)
        UIManager:close(self)
        if self.on_done then
            pcall(self.on_done, { notify = notify, no_this = st.no_this, no_all = st.no_all })
        end
    end
    add(ButtonTable:new{
        width       = INNER_W,
        zero_sep    = true,
        show_parent = self,
        buttons     = {
            {
                { text = T("Non merci"),         callback = function() answer(false) end },
                { text = T("Oui, me prévenir"),  callback = function() answer(true) end },
            },
        },
    })

    self[1] = CenterContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = W, h = H },
        FrameContainer:new{
            bordersize = Screen:scaleBySize(1),
            radius     = Screen:scaleBySize(8),
            background = Blitbuffer.COLOR_WHITE,
            padding    = PADDING,
            group,
        },
    }
end

function FavPrompt:_refresh()
    self:_build()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

-- Retour = « Non merci » sans rien mémoriser (aucune case prise en compte).
function FavPrompt:onClose()
    UIManager:close(self)
    if self.on_done then
        pcall(self.on_done, { notify = false, no_this = false, no_all = false, dismissed = true })
    end
    return true
end
function FavPrompt:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end
function FavPrompt:onCloseWidget()
    UIManager:setDirty(nil, function() return "partial", self.dimen end)
end

function Popups.favoritePrompt(novel_title, on_done)
    UIManager:show(FavPrompt:new{ novel_title = novel_title or "", on_done = on_done })
end

-- ── 2. Alerte « nouveau chapitre » avec couverture au milieu ────────────────

local _queue  = {}
local _active = nil

local NewChPopup = InputContainer:extend{
    opts = nil,
}

function NewChPopup:init()
    local W, H    = Screen:getWidth(), Screen:getHeight()
    local o       = self.opts
    local BOX_W   = math.floor(W * 0.86)
    local PADDING = Screen:scaleBySize(22)
    local INNER_W = BOX_W - 2 * PADDING
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.key_events = back_key_events()

    local group = VerticalGroup:new{ align = "center" }
    local function add(w) group[#group + 1] = w end

    local added = o.added or 1
    add(TextWidget:new{
        text = added > 1 and T("Nouveaux chapitres !") or T("Nouveau chapitre !"),
        face = Font:getFace("cfont", 22),
        bold = true,
    })
    add(VerticalSpan:new{ width = Screen:scaleBySize(14) })

    -- Couverture au milieu du popup (≈ la moitié de la largeur de l'écran).
    if o.cover_bb then
        self._cover_bb = o.cover_bb
        local ImageWidget = require("ui/widget/imagewidget")
        local ok, img = pcall(function()
            return ImageWidget:new{
                image            = o.cover_bb,
                image_disposable = false,
            }
        end)
        if ok and img then
            add(CenterContainer:new{
                dimen = Geom:new{ w = INNER_W, h = img:getSize().h },
                img,
            })
            add(VerticalSpan:new{ width = Screen:scaleBySize(14) })
        end
    end

    add(TextBoxWidget:new{
        text      = o.title or "",
        face      = Font:getFace("cfont", 18),
        bold      = true,
        width     = INNER_W,
        alignment = "center",
    })
    add(VerticalSpan:new{ width = Screen:scaleBySize(6) })

    local line = added > 1
        and (tostring(added) .. T(" nouveaux chapitres"))
        or  T("1 nouveau chapitre")
    add(TextBoxWidget:new{
        text      = line,
        face      = Font:getFace("cfont", 16),
        width     = INNER_W,
        alignment = "center",
    })
    if o.last_title and o.last_title ~= "" then
        local lt = o.last_title
        if #lt > 90 then lt = lt:sub(1, 90) .. "…" end
        add(VerticalSpan:new{ width = Screen:scaleBySize(4) })
        add(TextBoxWidget:new{
            text      = lt,
            face      = Font:getFace("cfont", 14),
            fgcolor   = Blitbuffer.COLOR_DARK_GRAY,
            width     = INNER_W,
            alignment = "center",
        })
    end
    add(VerticalSpan:new{ width = Screen:scaleBySize(16) })

    add(ButtonTable:new{
        width       = INNER_W,
        zero_sep    = true,
        show_parent = self,
        buttons     = {
            {
                { text = T("Fermer"), callback = function() self:onClose() end },
                { text = T("Ouvrir le roman"), callback = function()
                    UIManager:close(self)
                    self:_finish()
                    if o.on_open then pcall(o.on_open) end
                end },
            },
        },
    })

    self[1] = CenterContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = W, h = H },
        FrameContainer:new{
            bordersize = Screen:scaleBySize(1),
            radius     = Screen:scaleBySize(8),
            background = Blitbuffer.COLOR_WHITE,
            padding    = PADDING,
            group,
        },
    }
end

-- Libère l'image et enchaîne sur le popup suivant de la file.
function NewChPopup:_finish()
    if self._finished then return end
    self._finished = true
    if self._cover_bb then
        pcall(function() self._cover_bb:free() end)
        self._cover_bb = nil
    end
    _active = nil
    local nxt = table.remove(_queue, 1)
    if nxt then
        UIManager:scheduleIn(0.5, function() Popups.newChapters(nxt) end)
    end
end

function NewChPopup:onClose()
    UIManager:close(self)
    self:_finish()
    return true
end
function NewChPopup:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end
function NewChPopup:onCloseWidget()
    UIManager:setDirty(nil, function() return "partial", self.dimen end)
end

function Popups.isBusy()
    return _active ~= nil
end

-- opts = { title, added, last_title, cover_bb, on_open }
function Popups.newChapters(opts)
    if _active then
        _queue[#_queue + 1] = opts
        return
    end
    local ok, popup = pcall(function() return NewChPopup:new{ opts = opts } end)
    if not ok or not popup then
        if opts.cover_bb then pcall(function() opts.cover_bb:free() end) end
        return
    end
    _active = popup
    UIManager:show(popup)
end

return Popups
