-- core/receive.lua — Recevoir une source créée sur Sefirah Source Hub : on saisit le code à 4 chiffres affiché par le site.
-- Usage : require("core.receive").start()
local logger = require("logger")
local T = require("core.i18n").T
local Receive = {}

-- Adresse de TON Worker (le même que celui enregistré dans « Réglages du proxy » du Hub), sans « / » final.
local RELAY_URL = "https://sefirah-source-hub.ayman-mr1.workers.dev"
local POLL_EVERY, MAX_SIZE = 3, 300000
local ICON_MARKER = "%-%-SEFIRAH_ICON_PNG_BASE64:([A-Za-z0-9+/=]+)"

local _core_dir = (debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+%.lua$") or ""
local _plugin_dir = _core_dir:match("^(.+)/[^/]+$") or _core_dir

local function relay_url()
    local ok, S = pcall(require, "sefirah_settings")
    local u = ok and S and S:get("relay_url") or nil
    if type(u) == "string" and u:match("^https?://") then return (u:gsub("/+$", "")) end
    return RELAY_URL
end

local function http_get(url)
    local sink = {}
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    local mod = url:match("^https") and require("ssl.https") or require("socket.http")
    socketutil:set_timeout(8, 15)
    local ok, _, status = pcall(mod.request, { url = url, method = "GET", sink = ltn12.sink.table(sink) })
    socketutil:reset_timeout()
    if not ok then return nil, nil end
    return table.concat(sink), status
end

local function jdecode(s)
    local ok, J = pcall(require, "rapidjson")
    if not ok then J = require("json") end
    local ok2, d = pcall(J.decode, s)
    if ok2 and type(d) == "table" then return d end
    return nil
end

local function msg(text) require("ui/uimanager"):show(require("ui/widget/infomessage"):new{ text = text }) end

local function extract_icon(p)
    local encoded = tostring(p.lua or ""):match(ICON_MARKER)
    if not encoded then return nil end
    -- L'icône est transportée comme commentaire Lua afin de rester compatible
    -- avec le relais existant (qui ne connaît que id et lua).
    p.lua = tostring(p.lua):gsub("\n?%-%-SEFIRAH_ICON_PNG_BASE64:[A-Za-z0-9+/=]+", "")
    local ok, mime = pcall(require, "mime")
    if not ok or not mime or type(mime.unb64) ~= "function" then
        logger.warn("Sefirah receive: module MIME/base64 indisponible")
        return nil
    end
    local ok2, bytes = pcall(mime.unb64, encoded)
    if not ok2 or type(bytes) ~= "string" or #bytes < 8 or #bytes > 100000 then
        logger.warn("Sefirah receive: icône base64 invalide")
        return nil
    end
    -- N'accepte que des PNG (signature standard), pour éviter d'enregistrer
    -- un autre format avec une extension incorrecte.
    if bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        logger.warn("Sefirah receive: icône reçue non-PNG, ignorée")
        return nil
    end
    return bytes
end

local function save_icon(id, bytes)
    if not bytes then return false end
    local dir = _plugin_dir .. "/resources/sources"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then return false end
    local path = dir .. "/" .. id:lower() .. ".png"
    local f = io.open(path, "wb")
    if not f then
        logger.warn("Sefirah receive: impossible d'écrire l'icône", path)
        return false
    end
    f:write(bytes)
    f:close()
    return true
end

local function install(p)
    local lfs = require("libs/libkoreader-lfs")
    local ExtMgr = require("core.extmgr")
    local path = _plugin_dir .. "/extensions/" .. p.id .. ".lua"
    local bak
    if lfs.attributes(path, "mode") == "file" then
        bak = path .. ".bak"
        os.remove(bak)
        os.rename(path, bak)
    end
    local f = io.open(path, "wb")
    if not f then
        if bak then os.rename(bak, path) end
        return msg(T("Écriture impossible dans le dossier extensions."))
    end
    f:write(p.lua); f:close()
    local ok, err = ExtMgr.addFile(p.id)
    if not ok then
        os.remove(path)
        if bak then os.rename(bak, path) end
        logger.warn("Sefirah receive:", tostring(err))
        return msg(T("Source refusée : ") .. tostring(err))
    end
    ExtMgr.install(p.id)
    local icon_saved = save_icon(p.id, p._icon_bytes)
    if icon_saved then
        msg(T("Source installée avec son icône : ") .. p.id)
    else
        msg(T("Source installée : ") .. p.id
            .. (p._icon_bytes and "" or T(" (icône non disponible dans le transfert).")))
    end
end

local function confirm(p)
    local icon_bytes = extract_icon(p)
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local lfs = require("libs/libkoreader-lfs")
    p.id, p.lua = tostring(p.id or ""), tostring(p.lua or "")
    p._icon_bytes = icon_bytes
    if not p.id:match("^[%w_%-]+$") or #p.id > 40 then return msg(T("Identifiant de source invalide.")) end
    if #p.lua < 50 or #p.lua > MAX_SIZE then return msg(T("Fichier vide ou trop gros.")) end
    local chunk, err = (loadstring or load)(p.lua, "=" .. p.id) -- compile seulement, n'exécute rien
    if not chunk then return msg(T("Erreur de syntaxe : ") .. tostring(err)) end
    local exists = lfs.attributes(_plugin_dir .. "/extensions/" .. p.id .. ".lua", "mode") == "file"
    UIManager:show(ConfirmBox:new{
        text = T("Source reçue : ") .. p.id .. " (" .. math.floor(#p.lua / 1024 + 0.5) .. " Ko)\n\n"
            .. (exists and (T("Elle REMPLACERA la source existante du même nom.") .. "\n\n") or "")
            .. T("Ce code sera exécuté par le plugin. N'installe que ce que tu viens d'envoyer toi-même.")
            .. "\n\n" .. T("Installer ?"),
        ok_text = T("Installer"),
        ok_callback = function() install(p) end,
    })
end

-- Récupère le fichier déposé par le site sous ce code (essaie pendant ~90 s : le relais peut mettre
-- jusqu'à une minute à propager un nouveau code).
local function fetch(code)
    local UIManager = require("ui/uimanager")
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local deadline, cancelled, dialog = os.time() + 90, false, nil
        local function close() if dialog then UIManager:close(dialog); dialog = nil end end
        local function poll()
            if cancelled then return end
            local body, status = http_get(relay_url() .. "/relay/fetch?code=" .. code)
            if status == 200 and body and body ~= "" then
                local p = jdecode(body)
                if p then close(); return confirm(p) end
            elseif status == 400 or status == 501 then
                close(); return msg(T("Le service d'envoi est indisponible."))
            end
            if os.time() > deadline then close(); return msg(T("Code introuvable ou expiré. Vérifie le code sur le site.")) end
            UIManager:scheduleIn(POLL_EVERY, poll)
        end
        dialog = require("ui/widget/buttondialog"):new{
            title = T("Recherche de la source…") .. "\n" .. code,
            title_align = "center",
            buttons = {{{ text = T("Annuler"), callback = function() cancelled = true; close() end }}},
        }
        UIManager:show(dialog)
        UIManager:scheduleIn(1, poll)
    end)
end

-- Demande le code à 4 chiffres affiché par Sefirah Source Hub.
function Receive.start()
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = T("Code affiché par le site"),
        input = "", input_hint = "0000", input_type = "number",
        buttons = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            { text = T("Recevoir"), is_enter_default = true, callback = function()
                local code = (dlg:getInputText() or ""):gsub("%s", "")
                UIManager:close(dlg)
                if not code:match("^%d%d%d%d$") then return msg(T("Le code doit faire 4 chiffres.")) end
                fetch(code)
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

return Receive
