-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- core/net.lua — GET HTTP(S) partagé par toutes les extensions.
--  * délai TOTAL maximal par requête (le `timeout` de LuaSocket ne vaut que
--    pour chaque lecture : un serveur qui goutte-à-goutte bloquait la liseuse
--    pendant des minutes) ;
--  * plafond de taille ;
--  * compression gzip quand KOReader sait la décompresser (testé au démarrage :
--    si ce n'est pas le cas on n'envoie simplement pas Accept-Encoding).
local socket = require("socket")

local Net = {}

local UA = "Mozilla/5.0 (Linux; Android 9; KOReader)"

-- gzip("ok"), sert à vérifier qu'une fonction de décompression fonctionne vraiment.
local TEST_BLOB = "\031\139\008\000\000\000\000\000\002\003\203\207\006\000\071\221\220\121\002\000\000\000"

local _gunzip, _checked = nil, false
local function gunzip_fn()
    if _checked then return _gunzip end
    _checked = true
    local ok, Z = pcall(require, "ffi/zlib")
    if not ok or type(Z) ~= "table" then return nil end
    for _, name in ipairs({ "gunzip", "gzip_uncompress", "gzip_decompress", "inflate_gzip" }) do
        local f = Z[name]
        if type(f) == "function" then
            local ok2, out = pcall(f, TEST_BLOB)
            if ok2 and out == "ok" then _gunzip = f; break end
        end
    end
    return _gunzip
end

-- opts : headers, timeout (par lecture, déf. 12), deadline (total, déf. 40),
--        max_bytes, no_gzip
-- Renvoie body, code, headers  — ou nil, code_ou_erreur, début_du_corps.
function Net.get(url, opts)
    opts = opts or {}
    local https = require("ssl.https")
    local http  = require("socket.http")
    local req   = url:match("^https") and https or http

    local headers = { ["User-Agent"] = UA }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    local gz = (not opts.no_gzip) and gunzip_fn()
    if gz and headers["Accept-Encoding"] == nil then headers["Accept-Encoding"] = "gzip" end

    local t0, deadline = socket.gettime(), opts.deadline or 40
    local chunks, total = {}, 0
    local function sink(chunk)
        if chunk then
            total = total + #chunk
            if opts.max_bytes and total > opts.max_bytes then return nil, "too_large" end
            if socket.gettime() - t0 > deadline then return nil, "deadline" end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end

    local ok, code, rh = req.request {
        url     = url,
        sink    = sink,
        headers = headers,
        timeout = opts.timeout or 12,
    }
    if not ok or code ~= 200 then
        return nil, code or "error", table.concat(chunks):sub(1, 400)
    end

    local body = table.concat(chunks)
    local enc = rh and (rh["content-encoding"] or rh["Content-Encoding"])
    if enc and tostring(enc):lower():find("gzip", 1, true) then
        local okd, plain = pcall(gz or gunzip_fn() or function() return nil end, body)
        if not okd or not plain then return nil, "gunzip_failed" end
        body = plain
    end
    return body, code, rh
end

return Net
