-- Sélecteur de langue cible de traduction.
local T = require("core.i18n").T
local UIManager = require("ui/uimanager")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local Settings = require("settings")

local Lang = {}
local dlg

local function close()
    if dlg then UIManager:close(dlg); dlg = nil end
end

function Lang.show(on_change)
    close()
    local ok, Translate = pcall(require, "core.translate")
    if not ok then return end
    local langs = Translate.languages()
    local rows = {}
    local row = {}
    for _, l in ipairs(langs) do
        row[#row + 1] = {
            text = T(l.label),
            callback = function()
                Settings:set("translate_lang", l.label)
                close()
                if on_change then on_change(l.label) end
            end,
        }
        if #row == 3 then
            rows[#rows + 1] = row
            row = {}
        end
    end
    if #row > 0 then rows[#rows + 1] = row end

    rows[#rows + 1] = {{
        text = "Annuler",
        callback = close,
    }}

    dlg = ButtonDialogTitle:new{
        title = "Langue cible — toutes les langues",
        buttons = rows,
    }
    UIManager:show(dlg)
end

return Lang
