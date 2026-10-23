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

-- Contournement d'un filtre DNS / blocage du fournisseur (core/dnsbypass.lua) :
-- uniquement pour les sites déclarés par leur extension via Bypass.register().
local ok_bp, Bypass = pcall(require, "core.dnsbypass")
if not ok_bp then Bypass = nil end

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

-- Codes de redirection. LuaSocket suit lui-même 301/302/303/307 mais PAS 308
-- (redirection permanente utilisée par Next.js pour retirer/ajouter le « / » final
-- d'une adresse) : sans ce traitement, la requête échouait avec « HTTP 308 ».
local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }
local MAX_HOPS = 5

-- Erreurs passagères (réseau instable, serveur qui sature) : un second essai
-- après une courte pause réussit très souvent. « timeout » simple n'en fait pas
-- partie : retenter un serveur qui ne répond pas ne ferait que doubler l'attente.
local TRANSIENT = { "wantread", "wantwrite", "connection reset",
                    "closed", "broken pipe" }
local function is_transient(code)
    if type(code) == "number" then
        return code == 429 or code == 502 or code == 503 or code == 504
    end
    local s = tostring(code or ""):lower()
    for _, k in ipairs(TRANSIENT) do
        if s:find(k, 1, true) then return true end
    end
    return false
end
Net.is_transient = is_transient

local function resolve_location(base, loc)
    loc = tostring(loc or ""):gsub("%s", "")
    if loc == "" then return nil end
    if loc:match("^https?://") then return loc end
    local ok, url = pcall(require, "socket.url")
    if ok and url then
        local ok2, abs = pcall(url.absolute, base, loc)
        if ok2 and abs then return abs end
    end
    return nil
end


-- Sonde de connexion : un simple connect TCP court avant la vraie requête.
-- Si le serveur est injoignable (refusé, DNS KO, réseau pas prêt), on abandonne
-- tout de suite au lieu de lancer des handshakes TLS qui échouent — c'est ce
-- qui pouvait faire planter KOReader (segfault natif) juste après un échec.
-- Résultat gardé en mémoire (échec 15 s, succès 60 s) : la fiche d'un roman,
-- demandée plusieurs fois de suite, n'est pas retentée en boucle.
local _probe = {}
local function probe(url)
    local scheme, host, port = url:match("^(https?)://([^/:%?#]+):?(%d*)")
    if not host then return true end
    port = tonumber(port) or (scheme == "https" and 443 or 80)
    local key = host .. ":" .. port
    local now = socket.gettime()
    local c = _probe[key]
    if c and now - c.t < (c.ok and 60 or 15) then return c.ok, c.err end
    local sock = socket.tcp()
    sock:settimeout(5)
    local ok, err = sock:connect(host, port)
    pcall(sock.close, sock)
    local res_ok = ok and true or false
    local res_err = nil
    if not res_ok then
        res_err = tostring(err or "connection refused")
    end
    _probe[key] = { t = now, ok = res_ok, err = res_err }
    return res_ok, res_err
end
Net.probe = probe

-- Une tentative complète (redirections comprises).
local function attempt(url, opts, headers, t0, deadline)
    local https = require("ssl.https")
    local http  = require("socket.http")
    local chunks, total
    local function sink(chunk)
        if chunk then
            total = total + #chunk
            if opts.max_bytes and total > opts.max_bytes then return nil, "too_large" end
            if socket.gettime() - t0 > deadline then return nil, "deadline" end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end

    for _ = 1, MAX_HOPS + 1 do
        chunks, total = {}, 0
        local req = url:match("^https") and https or http
        local ok, code, rh = req.request {
            url     = url,
            sink    = sink,
            headers = headers,
            timeout = opts.timeout or 12,
        }
        if ok and REDIRECT[code] and type(rh) == "table" and (rh.location or rh.Location) then
            local nxt = resolve_location(url, rh.location or rh.Location)
            if not nxt or nxt == url then
                return nil, code, table.concat(chunks):sub(1, 400)
            end
            url = nxt
        else
            return ok, code, rh, chunks
        end
    end
    return nil, "too_many_redirects", nil
end

-- Requête par DNS-over-HTTPS (IP obtenue via 1.1.1.1 / 8.8.8.8, SNI et Host corrects).
-- Renvoie le même format que Net.get.
local function via_bypass(url, opts, headers)
    local body, code, rh = Bypass.get(url, {
        headers   = headers,
        timeout   = opts.timeout or 12,
        deadline  = opts.deadline or 40,
        max_bytes = opts.max_bytes,
    })
    if body and body ~= true and not Bypass.looks_blocked(body) then
        Bypass.set_active(url, true)
        return body, code, rh
    end
    if body and Bypass.looks_blocked(body) then return nil, "blocked", "" end
    return nil, code or "error", type(rh) == "string" and rh or ""
end

-- opts : headers, timeout (par lecture, déf. 12), deadline (total, déf. 40),
--        max_bytes, no_gzip, retries (essais supplémentaires sur erreur passagère,
--        déf. 1 ; 0 = aucun)
-- Renvoie body, code, headers  — ou nil, code_ou_erreur, début_du_corps.
function Net.get(url, opts)
    opts = opts or {}
    local headers = { ["User-Agent"] = UA }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    local gz = (not opts.no_gzip) and gunzip_fn()
    if gz and headers["Accept-Encoding"] == nil then headers["Accept-Encoding"] = "gzip" end

    -- Site déclaré (filtre DNS connu) : si le contournement a déjà servi, on y va
    -- directement ; sinon on tente d'abord la connexion normale.
    local bypassable = Bypass ~= nil and Bypass.is_registered(url)
    if bypassable and Bypass.is_active(url) then
        local b, c, r = via_bypass(url, opts, headers)
        if b then return b, c, r end
        Bypass.set_active(url, false)   -- le contournement ne marche plus : on retente en direct
    end

    if not opts.no_probe then
        local pok, perr = probe(url)
        if not pok then
            if bypassable then return via_bypass(url, opts, headers) end
            -- Explique la cause (Wi-Fi coupé / site injoignable) sans bloquer.
            pcall(function() require("core.online").explain_failure() end)
            return nil, perr or "connection refused", ""
        end
    end

    local t0, deadline = socket.gettime(), opts.deadline or 40
    local retries = opts.retries
    if retries == nil then retries = 1 end

    local ok, code, rh, chunks
    local tries = 0
    while true do
        ok, code, rh, chunks = attempt(url, opts, headers, t0, deadline)
        if ok and code == 200 then break end
        tries = tries + 1
        -- Seconde chance seulement si l'erreur est passagère ET qu'il reste du temps.
        if tries > retries or not is_transient(code)
           or (socket.gettime() - t0) > deadline * 0.5 then
            break
        end
        pcall(socket.sleep, 0.7 * tries)
    end

    if (not ok or code ~= 200) and bypassable
       and (not ok or code == 403 or type(code) ~= "number") then
        local b, c, r = via_bypass(url, opts, headers)
        if b then return b, c, r end
    end

    if not ok or code ~= 200 then
        local head = ""
        if type(chunks) == "table" then head = table.concat(chunks):sub(1, 400)
        elseif type(rh) == "string" then head = rh end
        return nil, code or "error", head
    end

    local body = table.concat(chunks)
    if bypassable and Bypass.looks_blocked(body) then
        local b, c, r = via_bypass(url, opts, headers)
        if b then return b, c, r end
        return nil, "blocked", ""
    end
    local enc = rh and (rh["content-encoding"] or rh["Content-Encoding"])
    if enc and tostring(enc):lower():find("gzip", 1, true) then
        local okd, plain = pcall(gz or gunzip_fn() or function() return nil end, body)
        if not okd or not plain then return nil, "gunzip_failed" end
        body = plain
    end
    return body, code, rh
end

return Net
