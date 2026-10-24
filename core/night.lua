-- core/night.lua — mode nuit de tout le plugin.
-- On s'appuie sur le mode nuit natif de KOReader (inversion de l'écran) : tous
-- les écrans de Sefirah s'inversent d'un coup, les couvertures restent normales.
-- L'état d'origine de KOReader est remémorisé à l'ouverture du plugin et
-- remis à la fermeture.
local UIManager = require("ui/uimanager")
local Settings  = require("settings")

local Night = {}
local _orig = nil   -- état du mode nuit de KOReader avant l'ouverture de Sefirah

local function screen()
    local ok, Device = pcall(require, "device")
    return ok and Device and Device.screen or nil
end

local function current(Screen)
    return Screen.night_mode == true
end

local function set(want)
    local Screen = screen()
    if not Screen then return end
    if current(Screen) ~= want then
        pcall(function() Screen:toggleNightMode() end)
        UIManager:setDirty("all", "full")
    end
end

function Night.enabled()
    return Settings:get("ui_night_mode") == true
end

-- À l'ouverture de Sefirah : applique le réglage du plugin.
function Night.apply()
    local Screen = screen()
    if not Screen then return end
    if _orig == nil then _orig = current(Screen) end
    set(Night.enabled())
end

-- À la fermeture de Sefirah : remet le mode nuit comme KOReader l'avait.
function Night.restore()
    if _orig == nil then return end
    local want = _orig
    _orig = nil
    set(want)
end

-- Bascule le réglage et l'applique tout de suite.
function Night.toggle()
    Settings:set("ui_night_mode", not Night.enabled())
    Night.apply()
end

return Night
