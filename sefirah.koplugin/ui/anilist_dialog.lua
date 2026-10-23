-- ui/anilist_dialog.lua — lier / synchroniser / délier un titre avec AniList.
local UIManager    = require("ui/uimanager")
local InfoMessage  = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local T            = require("core.i18n").T
local AniList      = require("core.anilist")
local Online       = require("core.online")

local Dialog = {}

local function info_msg(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 4 })
end

local function explain(err)
    if err == "réseau" then
        Online.explain_failure()
        if AniList.last_error then info_msg(AniList.last_error, 6) end
    elseif err == "jeton refusé" then
        info_msg(T("Jeton AniList refusé : génère-en un nouveau (Paramètres › AniList › Comment obtenir le jeton)."), 6)
    else
        info_msg(T("AniList : ") .. tostring(err), 5)
    end
end

-- Online.run avale les erreurs (journal seulement) : on les affiche pour ne
-- jamais laisser l'utilisateur devant un bouton « qui ne fait rien ».
local function guarded(fn)
    return function()
        local ok, err = pcall(fn)
        if not ok then info_msg(T("AniList : ") .. tostring(err):gsub("\n.*", ""), 8) end
    end
end

local function do_push(source_id, path)
    Online.run(guarded(function()
        local p, err = AniList.push(source_id, path)
        if p then
            info_msg(string.format(T("AniList synchronisé : %d chapitre(s) lu(s)."), p), 3)
        else
            explain(err)
        end
    end))
end

local function choose_media(source_id, path, results)
    local dlg
    local buttons = {}
    for _, m in ipairs(results) do
        local label = m.title .. (m.format and (" · " .. m.format) or "")
            .. (m.chapters and (" · " .. m.chapters .. " ch.") or "")
        buttons[#buttons + 1] = {{
            text = label, align = "left",
            callback = function()
                UIManager:close(dlg)
                Online.run(guarded(function()
                    AniList.link(source_id, path, m)
                    info_msg(T("Lié à : ") .. m.title, 3)
                    do_push(source_id, path)
                end))
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = T("Annuler"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = T("Choisis la fiche AniList"), buttons = buttons }
    UIManager:show(dlg)
end

local function search_and_link(source_id, path, title)
    Online.run(guarded(function()
        local searching = InfoMessage:new{ text = T("Recherche sur AniList…") }
        UIManager:show(searching)
        UIManager:nextTick(guarded(function()
            local res, err = AniList.search(title)
            UIManager:close(searching)
            if not res then return explain(err) end
            if #res == 0 then
                return info_msg(T("Aucune fiche AniList trouvée pour : ") .. tostring(title), 4)
            end
            choose_media(source_id, path, res)
        end))
    end))
end

-- Point d'entrée : menu AniList pour le titre ouvert dans la fiche.
function Dialog.show(source_id, info)
    local path  = info.path or ""
    local title = info.name or info.title or ""
    if not AniList.has_token() then
        return info_msg(T("Ajoute d'abord ton jeton AniList : Paramètres › AniList."), 5)
    end
    local link = AniList.get_link(source_id, path)
    local dlg
    local buttons
    if link then
        buttons = {
            {{ text = T("Synchroniser maintenant"), callback = function()
                UIManager:close(dlg); do_push(source_id, path)
            end }},
            {{ text = T("Changer de fiche"), callback = function()
                UIManager:close(dlg); search_and_link(source_id, path, title)
            end }},
            {{ text = T("Délier"), callback = function()
                UIManager:close(dlg); AniList.unlink(source_id, path)
                info_msg(T("Titre délié d'AniList."), 2)
            end }},
            {{ text = T("Fermer"), callback = function() UIManager:close(dlg) end }},
        }
    else
        buttons = {
            {{ text = T("Lier à AniList"), callback = function()
                UIManager:close(dlg); search_and_link(source_id, path, title)
            end }},
            {{ text = T("Fermer"), callback = function() UIManager:close(dlg) end }},
        }
    end
    dlg = ButtonDialog:new{
        title = "AniList" .. (link and (" — " .. tostring(link.title)) or ""),
        buttons = buttons,
    }
    UIManager:show(dlg)
end

return Dialog
