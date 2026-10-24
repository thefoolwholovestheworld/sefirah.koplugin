-- ui/friends.lua — amis : recherche par pseudo, demandes envoyées / reçues, retrait.
-- Les appels réseau passent par core/leaderboard.lua ; l'écran « Amis » est dans ui/progress.lua.
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage  = require("ui/widget/infomessage")
local InputDialog  = require("ui/widget/inputdialog")
local UIManager    = require("ui/uimanager")
local LB           = require("core.leaderboard")
local T            = require("core.i18n").T

local Friends = {}

local function say(text, timeout)
    UIManager:show(InfoMessage:new{ text = tostring(text), timeout = timeout or 4 })
end
local function trim(s) local r = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""); return r end
local function lvl_of(x) return math.max(1, tonumber(x and x.level) or (math.floor((tonumber(x and x.xp) or 0) / 250) + 1)) end

local function run_online(fn)
    local ok, Online = pcall(require, "core.online")
    if ok and Online and Online.run then Online.run(fn) else fn() end
end

-- Exécute une action réseau (bloquante) derrière un message d'attente, puis appelle done(res, err).
local function call(label, fn, done)
    run_online(function()
        local info = InfoMessage:new{ text = label }
        UIManager:show(info)
        UIManager:scheduleIn(0.15, function()
            local ok, res, err = pcall(fn)
            UIManager:close(info)
            if not ok then res, err = nil, tostring(res) end
            done(res, err)
        end)
    end)
end

-- Petit menu : une option par ligne. options = { { "texte", fonction_ou_nil }, ... }
local function choose(title, options)
    local dlg
    local rows = {}
    for _, o in ipairs(options) do
        rows[#rows + 1] = {{ text = o[1], callback = function()
            UIManager:close(dlg)
            if o[2] then o[2]() end
        end }}
    end
    dlg = ButtonDialog:new{ title = title, title_align = "center", buttons = rows }
    UIManager:show(dlg)
end

-- Action serveur, puis rechargement de la liste d'amis et redessin de l'écran.
local function act(label, fn, success, redraw)
    call(label, function()
        local res, err = fn()
        if not res then return nil, err end
        pcall(LB.refreshFriends)
        return res
    end, function(res, err)
        if not res then say(err or T("Action impossible."))
        else say(type(success) == "function" and success(res) or success, 3) end
        if redraw then redraw() end
    end)
end

local function do_request(name, redraw)
    act(T("Envoi de la demande…"), function() return LB.friendRequest(name) end, function(res)
        if res.state == "friend" then return T("Vous êtes maintenant amis avec %s !"):format(name) end
        return T("Demande envoyée à %s."):format(name)
    end, redraw)
end
local function do_respond(name, accept, redraw)
    act("…", function() return LB.friendRespond(name, accept) end,
        accept and T("%s est maintenant ton ami."):format(name) or T("Demande refusée."), redraw)
end
local function do_remove(name, redraw, text)
    act("…", function() return LB.friendRemove(name) end, text or T("%s retiré de tes amis."):format(name), redraw)
end

function Friends.confirmRemove(name, redraw)
    choose(T("Retirer %s de tes amis ?"):format(name), {
        { T("Retirer"), function() do_remove(name, redraw) end },
        { T("Annuler") },
    })
end

-- Appui sur un ami dans le classement des amis.
function Friends.manage(name, level, redraw)
    choose(name .. "  ·  " .. T("Niv. %d"):format(tonumber(level) or 1), {
        { T("Retirer des amis"), function() Friends.confirmRemove(name, redraw) end },
        { T("Fermer") },
    })
end

-- Fiche d'un joueur (résultat de recherche ou demande reçue) : l'action dépend de la relation.
-- pl = { username, level, relation = none | friend | sent | received }
function Friends.player(pl, redraw)
    local name, rel = pl.username, pl.relation or "none"
    local head = name .. "  ·  " .. T("Niv. %d"):format(lvl_of(pl))
    if rel == "friend" then
        choose(head .. "\n" .. T("Vous êtes amis."), {
            { T("Retirer des amis"), function() Friends.confirmRemove(name, redraw) end }, { T("Fermer") } })
    elseif rel == "sent" then
        choose(head .. "\n" .. T("Demande envoyée, en attente de sa réponse."), {
            { T("Annuler la demande"), function() do_remove(name, redraw, T("Demande annulée.")) end }, { T("Fermer") } })
    elseif rel == "received" then
        choose(head .. "\n" .. T("Te demande en ami."), {
            { T("Accepter"), function() do_respond(name, true, redraw) end },
            { T("Refuser"), function() do_respond(name, false, redraw) end },
            { T("Plus tard") } })
    else
        choose(T("Demander %s en ami ?"):format(name), {
            { T("Envoyer la demande"), function() do_request(name, redraw) end }, { T("Annuler") } })
    end
end

-- Demandes d'amis reçues.
function Friends.requests(redraw)
    local incoming = (LB.getState().friends or {}).incoming or {}
    if #incoming == 0 then say(T("Aucune demande d'ami reçue.")); return end
    local options = {}
    for i, f in ipairs(incoming) do
        if i > 8 then break end
        local pl = { username = f.username, level = f.level, xp = f.xp, relation = "received" }
        options[#options + 1] = { tostring(f.username) .. "  ·  " .. T("Niv. %d"):format(lvl_of(f)), function() Friends.player(pl, redraw) end }
    end
    options[#options + 1] = { T("Fermer") }
    choose(T("Demandes d'amis (%d)"):format(#incoming), options)
end

local function rel_tag(r)
    if r == "friend"   then return "  ·  " .. T("ami") end
    if r == "sent"     then return "  ·  " .. T("demande envoyée") end
    if r == "received" then return "  ·  " .. T("te demande en ami") end
    return ""
end

function Friends.results(q, redraw)
    call(T("Recherche…"), function() return LB.searchPlayers(q) end, function(players, err)
        if not players then say(err or T("Recherche impossible.")); return end
        if #players == 0 then say(T("Aucun joueur trouvé pour « %s »."):format(q)); return end
        local options = {}
        for _, pl in ipairs(players) do
            options[#options + 1] = {
                tostring(pl.username) .. "  ·  " .. T("Niv. %d"):format(lvl_of(pl)) .. rel_tag(pl.relation),
                function() Friends.player(pl, redraw) end,
            }
        end
        options[#options + 1] = { T("Nouvelle recherche"), function() Friends.search(redraw) end }
        options[#options + 1] = { T("Fermer") }
        choose(T("Résultats pour « %s »"):format(q), options)
    end)
end

-- Saisie d'un pseudo (ou du début d'un pseudo), puis liste des joueurs trouvés.
function Friends.search(redraw)
    if LB.username() == "" then
        say(T("Choisis d'abord ton pseudo public (bouton « Pseudo » de l'onglet Général)."))
        return
    end
    local dlg
    dlg = InputDialog:new{
        title = T("Rechercher un joueur"),
        input = "", input_hint = T("Pseudo (2 lettres minimum)"),
        buttons = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            { text = T("Rechercher"), is_enter_default = true, callback = function()
                local q = trim(dlg:getInputText())
                UIManager:close(dlg)
                if #q < 2 then say(T("Entre au moins 2 lettres.")); return end
                Friends.results(q, redraw)
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

return Friends
