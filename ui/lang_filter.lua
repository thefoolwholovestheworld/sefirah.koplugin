-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- Popup « Filtrer par langue » pour les onglets Parcourir et Sources.
-- Sélection multiple ; aucune case cochée (ou toutes cochées) = toutes les
-- langues. Les changements ne sont enregistrés qu'au tap sur « Appliquer ».
local UIManager         = require("ui/uimanager")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local ExtMgr            = require("core.extmgr")
local Settings          = require("settings")

local LangFilter = {}
local _dlg = nil

local function close_dlg()
    if _dlg then UIManager:close(_dlg); _dlg = nil end
end

local function open(work, on_change, all_sources)
    close_dlg()

    local langs   = ExtMgr.languages(all_sources)
    local buttons = {}

    for _, l in ipairs(langs) do
        local code = l.code
        table.insert(buttons, {{
            text     = (work[code] and "[x]  " or "[  ]  ") .. l.label .. "  (" .. l.count .. ")",
            callback = function()
                work[code] = not work[code] or nil
                open(work, on_change, all_sources)
            end,
        }})
    end

    table.insert(buttons, {{
        text     = T("Toutes les langues"),
        callback = function()
            for k in pairs(work) do work[k] = nil end
            open(work, on_change, all_sources)
        end,
    }})

    table.insert(buttons, {
        {
            text     = T("Annuler"),
            callback = close_dlg,
        },
        {
            text     = T("Appliquer"),
            callback = function()
                local chosen = {}
                for _, l in ipairs(langs) do
                    if work[l.code] then chosen[#chosen + 1] = l.code end
                end
                -- Toutes cochées = équivalent à pas de filtre.
                if #chosen == #langs then chosen = {} end
                Settings:set("lang_filter", chosen)
                close_dlg()
                if on_change then on_change() end
            end,
        },
    })

    _dlg = ButtonDialogTitle:new{
        title   = T("Filtrer par langue"),
        buttons = buttons,
    }
    UIManager:show(_dlg)
end

-- on_change() est appelé après « Appliquer » pour que l'onglet se reconstruise.
function LangFilter.show(on_change, all_sources)
    local work = {}
    for _, c in ipairs(ExtMgr.activeLangCodes(all_sources)) do work[c] = true end
    open(work, on_change, all_sources)
end

return LangFilter
