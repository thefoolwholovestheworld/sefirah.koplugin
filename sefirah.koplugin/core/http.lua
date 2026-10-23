-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- Thin HTTP/HTTPS client for Sefirah extensions.
-- Returns body string on success, nil+code on failure.
local https   = require("ssl.https")
local http    = require("socket.http")
local ltn12   = require("ltn12")
local ok_json, JSON = pcall(require, "rapidjson")
if not ok_json then JSON = require("json") end

local UA = "Mozilla/5.0 (Linux; Android 9; KOReader) AppleWebKit/537.36"

-- Contournement d'un filtre DNS (voir core/dnsbypass.lua) : uniquement pour les
-- sites déclarés par leur extension via Bypass.register(). Les autres sources
-- ne sont pas touchées.
local ok_bp, Bypass = pcall(require, "core.dnsbypass")
if not ok_bp then Bypass = nil end
local function bypass_host(url) return Bypass ~= nil and Bypass.is_registered(url) end

-- Une page de blocage enregistrée à la place d'une image (HTML au lieu de JPEG/PNG).
local function file_is_html(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(64) or ""
    f:close()
    return head:match("^%s*<") ~= nil
end

local HttpClient = {}

-- max_bytes (optionnel) : coupe le téléchargement dès que la taille est dépassée
-- au lieu de tout rapatrier (avatars de 2 Mo, GIF animés de 20 Mo…).
local function limited_sink(t, max_bytes)
    if not max_bytes then return ltn12.sink.table(t) end
    local total = 0
    return function(chunk, err)
        if chunk then
            total = total + #chunk
            if total > max_bytes then return nil, "too_large" end
            t[#t + 1] = chunk
        end
        return 1
    end
end

-- LuaSocket suit 301/302/303/307 mais pas 308 (redirection permanente de Next.js).
local function next_location(url, code, resp_h)
    if code ~= 308 or type(resp_h) ~= "table" then return nil end
    local loc = tostring(resp_h.location or resp_h.Location or ""):gsub("%s", "")
    if loc == "" then return nil end
    if loc:match("^https?://") then return loc end
    local okU, U = pcall(require, "socket.url")
    if okU and U then
        local okA, abs = pcall(U.absolute, url, loc)
        if okA and abs and abs ~= url then return abs end
    end
    return nil
end

local function plain_request(url, headers, timeout, max_bytes, hops)
    local sink = {}
    local req_h = {
        ["User-Agent"]      = UA,
        ["Accept"]          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
    }
    if headers then
        for k, v in pairs(headers) do req_h[k] = v end
    end
    local requester = url:match("^https") and https or http
    local ok, code, resp_h = requester.request {
        url     = url,
        sink    = limited_sink(sink, max_bytes),
        headers = req_h,
        timeout = timeout or 20,
    }
    if not ok then return nil, tostring(code) end
    if code ~= 200 then
        local nxt = (hops or 0) < 4 and next_location(url, code, resp_h) or nil
        if nxt then return plain_request(nxt, headers, timeout, max_bytes, (hops or 0) + 1) end
        return nil, code
    end
    return table.concat(sink), code, resp_h
end

local function do_request(url, headers, timeout, max_bytes)
    if not bypass_host(url) then return plain_request(url, headers, timeout, max_bytes) end
    local function via_bypass()
        local body, code, rh = Bypass.get(url, { headers = headers, timeout = timeout or 20, max_bytes = max_bytes })
        if body and not Bypass.looks_blocked(body) then
            Bypass.set_active(url, true)
            return body, code, rh
        end
        return nil, tostring(code)
    end
    if Bypass.is_active(url) then return via_bypass() end
    local body, code, rh = plain_request(url, headers, timeout, max_bytes)
    if body and not Bypass.looks_blocked(body) then return body, code, rh end
    if type(code) == "number" and code ~= 403 then return nil, code end   -- 404 etc. : inutile de réessayer
    return via_bypass()
end

function HttpClient.get(url, headers, timeout, max_bytes)
    return do_request(url, headers, timeout, max_bytes)
end

-- Download url to a local file path; returns true/false, code
local function plain_download(url, dest_path, timeout, headers, hops)
    local f = io.open(dest_path, "wb")
    if not f then return false, "open_error" end
    local requester = url:match("^https") and https or http
    local ok, code, resp_h = requester.request {
        url     = url,
        sink    = ltn12.sink.file(f),
        headers = headers,
        timeout = timeout or 60,
    }
    -- ltn12.sink.file closes f automatically; calling f:close() again crashes
    local success = ok and (code == 200)
    if not success then
        os.remove(dest_path)
        local nxt = ok and (hops or 0) < 4 and next_location(url, code, resp_h) or nil
        if nxt then return plain_download(nxt, dest_path, timeout, headers, (hops or 0) + 1) end
    end
    return success, code
end

function HttpClient.download(url, dest_path, timeout, headers)
    if not bypass_host(url) then return plain_download(url, dest_path, timeout, headers) end
    local function via_bypass()
        local ok, code = Bypass.get(url, { headers = headers, timeout = timeout or 60, deadline = 90, file = dest_path })
        if ok == true and not file_is_html(dest_path) then
            Bypass.set_active(url, true)
            return true, 200
        end
        os.remove(dest_path)
        return false, code
    end
    if Bypass.is_active(url) then return via_bypass() end
    local success, code = plain_download(url, dest_path, timeout, headers)
    if success and file_is_html(dest_path) then
        os.remove(dest_path)          -- page « Content blocked » au lieu de l'image
        success = false
    end
    if success then return true, code end
    if type(code) == "number" and code ~= 403 then return false, code end
    return via_bypass()
end

-- Plusieurs téléchargements d'un même hôte sur UNE connexion (voir Bypass.get_files).
-- items = { { url, dest }, … } ; on_file(i, ok) après chaque fichier. Renvoie ok[i].
-- Hôte non déclaré (ou module absent) : un téléchargement classique par fichier.
function HttpClient.download_many(items, timeout, headers, on_file)
    local first = items[1]
    if first and Bypass and Bypass.get_files and Bypass.is_registered(first.url) then
        local list = {}
        for i, it in ipairs(items) do list[i] = { url = it.url, file = it.dest } end
        local ok, res = pcall(Bypass.get_files, list, {
            headers = headers, timeout = timeout or 15, deadline = 900,
            doh = Bypass.is_active(first.url), on_file = on_file,
        })
        if ok and type(res) == "table" then return res end
    end
    local out = {}
    for i, it in ipairs(items) do
        out[i] = HttpClient.download(it.url, it.dest, timeout, headers) and true or false
        if on_file then pcall(on_file, i, out[i]) end
    end
    return out
end

return HttpClient
