-- core/catalog.lua — Catalogue de sources en ligne : lit le manifeste de Sefirah Source Hub
-- (sources/manifest.json), liste les sources qui ne sont pas encore sur la liseuse et les
-- télécharge dans extensions/ à la demande. Utilisé par l'onglet Sources.
local logger = require("logger")
local T = require("core.i18n").T
local Catalog = {}

local DEFAULT_HUB = "https://thefoolwholovestheworld.github.io/Sefirah-Source-Hub/"
local MAX_SIZE = 300000      -- taille max d'un .lua
local STALE_AFTER = 1800     -- secondes avant de re-lire le manifeste tout seul

local _core_dir = (debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+%.lua$") or ""
local _plugin_dir = _core_dir:match("^(.+)/[^/]+$") or _core_dir

local _list = nil            -- liste en mémoire
local _stamp = 0

local function settings()
    local ok, S = pcall(require, "sefirah_settings")
    return ok and S or nil
end

local function hub_base()
    local S = settings()
    local u = S and S:get("hub_url")
    if type(u) ~= "string" or not u:match("^https?://") then u = DEFAULT_HUB end
    return (u:gsub("/*$", "/"))
end

local function hub_origin() return hub_base():match("^(https?://[^/]+)") end

-- Adresse d'un fichier du Hub. Seul le site du Hub est autorisé (le code téléchargé est exécuté).
local function resolve(path)
    if type(path) ~= "string" or path == "" or path:find("..", 1, true) then return nil end
    if path:match("^https?://") then
        local o = hub_origin()
        if o and path:sub(1, #o + 1) == o .. "/" then return path end
        return nil
    end
    return hub_base() .. path:gsub("^/+", "")
end

local function jdecode(s)
    local ok, J = pcall(require, "rapidjson")
    if not ok then J = require("json") end
    local ok2, d = pcall(J.decode, s)
    if ok2 and type(d) == "table" then return d end
    return nil
end

local function parse(j)
    local arr = j.sources or j
    local out = {}
    if type(arr) ~= "table" then return out end
    for _, s in ipairs(arr) do
        if type(s) == "table" and type(s.id) == "string" and s.id:match("^[%w_%-]+$") and #s.id <= 40 then
            local file = resolve(s.file or ("sources/" .. s.id .. ".lua"))
            if file then
                out[#out + 1] = {
                    id = s.id, name = tostring(s.name or s.id), site = type(s.site) == "string" and s.site or nil,
                    lang = type(s.lang) == "string" and s.lang or "multi",
                    version = tostring(s.version or "0.0.0"), runtime = "lua",
                    type = s.type == "manga" and "manga" or nil,
                    remote = true, hub_file = file, hub_status = s.status,
                    hub_icon = type(s.icon) == "string" and resolve(s.icon) or nil,
                }
            end
        end
    end
    return out
end

local function sig(list)
    local t = {}
    for _, m in ipairs(list or {}) do t[#t + 1] = m.id .. "@" .. m.version end
    table.sort(t)
    return table.concat(t, ",")
end

local function publish(list)
    _list = list
    require("core.extmgr").setRemote(list)
end

-- Liste connue (mémoire, sinon dernier catalogue gardé dans les réglages). Ne touche pas au réseau.
function Catalog.entries()
    if _list then return _list end
    local S = settings()
    local c = S and S:get("hub_cache")
    if type(c) == "table" and type(c.list) == "table" then
        _stamp = tonumber(c.t) or 0
        publish(c.list)
        return _list
    end
    return {}
end

function Catalog.stale()
    Catalog.entries()
    return os.time() - _stamp > STALE_AFTER
end

-- Lit le manifeste. Renvoie true, changed — ou nil, message.
function Catalog.refresh()
    local url = hub_base() .. "sources/manifest.json"
    local body, code = require("core.net").get(url, { timeout = 10, deadline = 25, no_gzip = true })
    if not body then return nil, tostring(code) end
    local j = jdecode(body)
    if not j then return nil, T("réponse illisible") end
    local list = parse(j)
    local changed = sig(list) ~= sig(_list or Catalog.entries())
    _stamp = os.time()
    local S = settings()
    if S then S:set("hub_cache", { t = _stamp, list = list }) end
    publish(list)
    return true, changed
end

local function vnum(v)
    local t = {}
    for n in tostring(v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end
local function newer(a, b)
    local x, y = vnum(a), vnum(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

-- Entrée du catalogue plus récente que la source posée sur la liseuse (seulement pour les
-- sources qui viennent du Hub).
function Catalog.updateFor(id)
    local S = settings()
    local mine = S and (S:get("hub_versions") or {})[id]
    if not mine then return nil end
    for _, m in ipairs(Catalog.entries()) do
        if m.id == id and newer(m.version, mine) then return m end
    end
    return nil
end

-- Télécharge, vérifie et installe une source du catalogue. Renvoie true — ou nil, message.
function Catalog.install(m)
    if type(m) ~= "table" or not m.id or not m.id:match("^[%w_%-]+$") or not m.hub_file then
        return nil, T("Identifiant de source invalide.")
    end
    local Net = require("core.net")
    local body, code = Net.get(m.hub_file, { timeout = 15, deadline = 40, no_gzip = true })
    if not body then return nil, tostring(code) end
    if #body < 50 or #body > MAX_SIZE then return nil, T("Fichier vide ou trop gros.") end
    local chunk, err = (loadstring or load)(body, "=" .. m.id)   -- compile seulement
    if not chunk then return nil, T("Erreur de syntaxe : ") .. tostring(err) end

    local lfs = require("libs/libkoreader-lfs")
    local path = _plugin_dir .. "/extensions/" .. m.id .. ".lua"
    local bak
    if lfs.attributes(path, "mode") == "file" then
        bak = path .. ".bak"
        os.remove(bak)
        os.rename(path, bak)
    end
    local f = io.open(path, "wb")
    if not f then
        if bak then os.rename(bak, path) end
        return nil, T("Écriture impossible dans le dossier extensions.")
    end
    f:write(body); f:close()

    local ExtMgr = require("core.extmgr")
    local ok, e2 = ExtMgr.addFile(m.id)
    if not ok then
        os.remove(path)
        if bak then os.rename(bak, path) end
        logger.warn("Sefirah catalogue:", tostring(e2))
        return nil, T("Source refusée : ") .. tostring(e2)
    end
    ExtMgr.install(m.id)

    local S = settings()
    if S then
        local v = {}
        for k, x in pairs(S:get("hub_versions") or {}) do v[k] = x end
        v[m.id] = m.version
        S:set("hub_versions", v)
    end
    -- Icône : facultative (champ « icon » du manifeste), sans conséquence si elle échoue.
    if m.hub_icon and lfs.attributes(_plugin_dir .. "/resources/sources/" .. m.id:lower() .. ".png", "mode") ~= "file" then
        pcall(function()
            local img = Net.get(m.hub_icon, { timeout = 10, deadline = 15, no_gzip = true })
            if img and #img > 100 and #img < 500000 then
                local fi = io.open(_plugin_dir .. "/resources/sources/" .. m.id:lower() .. ".png", "wb")
                if fi then fi:write(img); fi:close() end
            end
        end)
    end
    return true
end

return Catalog
