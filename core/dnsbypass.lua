-- core/dnsbypass.lua — contournement d'un filtre DNS (sites bloqués par le
-- fournisseur d'accès ou le réseau, qui répond « Content blocked »).
--
-- Principe : le nom de domaine est résolu via DNS-over-HTTPS en passant par
-- une adresse IP FIXE (1.1.1.1, 8.8.8.8…), donc sans le DNS de la liseuse ;
-- puis on se connecte directement à l'IP obtenue, avec le bon nom de site
-- (SNI + en-tête Host). Rien à changer dans le Wi-Fi ni dans le DNS.
--
-- N'est utilisé qu'en repli, pour les sites déclarés avec Bypass.register().
-- Limites : HTTPS uniquement ; ne marche pas si le blocage se fait aussi
-- sur l'adresse IP (ou si le port 443 vers 1.1.1.1 / 8.8.8.8 est coupé).
local socket = require("socket")

local M = {}

local UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

local registered, active, ipcache = {}, {}, {}
local journal = {}

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    journal[#journal + 1] = os.date("%H:%M:%S ") .. table.concat(parts, " ")
    if #journal > 60 then table.remove(journal, 1) end
end

function M.journal() return table.concat(journal, "\n") end

-- ── Utilitaires ──────────────────────────────────────────────────────────────
local function host_of(url)
    local h = tostring(url or ""):match("^https?://([^/:%?#]+)")
    if not h then h = tostring(url or ""):match("^([%w%.%-]+)$") end
    return h and h:lower() or nil
end

local function bare(h) return (tostring(h or ""):gsub("^www%.", "")) end

function M.register(host) registered[bare(host_of(host) or host)] = true end

function M.is_registered(url)
    local h = host_of(url)
    return h ~= nil and registered[bare(h)] == true
end

function M.set_active(url, on)
    local h = host_of(url)
    if h then active[bare(h)] = on and true or nil end
end

function M.is_active(url)
    local h = host_of(url)
    return h ~= nil and active[bare(h)] == true
end

-- Réponse d'un filtre (coque Angular « Content blocked » ou page de blocage).
function M.looks_blocked(body)
    if type(body) ~= "string" then return false end
    local head = body:sub(1, 6000)
    if head:find("Content blocked", 1, true) then return true end
    if head:find("data-beasties-container", 1, true) then return true end
    if head:find("<app-root", 1, true) and head:find("</app-root>", 1, true) then return true end
    return false
end

local function parse_url(url)
    local scheme, rest = tostring(url):match("^(%a+)://(.+)$")
    if not scheme then return nil end
    local hostport, path = rest:match("^([^/%?#]+)(.*)$")
    if not hostport then return nil end
    path = path:gsub("#.*$", "")
    if path == "" then path = "/" elseif path:sub(1, 1) ~= "/" then path = "/" .. path end
    local host, port = hostport:match("^([^:]+):(%d+)$")
    if not host then host = hostport end
    scheme = scheme:lower()
    return scheme, host:lower(), tonumber(port) or (scheme == "https" and 443 or 80), path
end

local function absolute(loc, host, port)
    if loc:match("^%a+://") then return loc end
    if loc:sub(1, 2) == "//" then return "https:" .. loc end
    local hp = host .. ((port ~= 443) and (":" .. port) or "")
    if loc:sub(1, 1) == "/" then return "https://" .. hp .. loc end
    return "https://" .. hp .. "/" .. loc
end

-- ── Connexion TLS (remplaçable pour les tests) ───────────────────────────────
function M._connect(ip, port, sni, timeout)
    local ok_ssl, ssl = pcall(require, "ssl")
    if not ok_ssl or type(ssl) ~= "table" then return nil, "module ssl absent" end
    local sock = socket.tcp()
    if not sock then return nil, "socket impossible" end
    sock:settimeout(timeout)
    local ok, err = sock:connect(ip, port)
    if not ok then sock:close(); return nil, "connexion : " .. tostring(err) end
    local conn, werr
    for _, proto in ipairs({ "any", "tlsv1_2" }) do
        conn, werr = ssl.wrap(sock, {
            mode = "client", protocol = proto, verify = "none",
            options = { "all", "no_sslv2", "no_sslv3" },
        })
        if conn then break end
    end
    if not conn then sock:close(); return nil, "tls wrap : " .. tostring(werr) end
    if conn.sni then
        local okn, nerr = pcall(conn.sni, conn, sni)
        if not okn then log("sni indisponible :", tostring(nerr)) end
    end
    conn:settimeout(timeout)
    local hok, herr = conn:dohandshake()
    if not hok then conn:close(); return nil, "handshake : " .. tostring(herr) end
    return conn
end

-- ── Lecture d'une réponse HTTP/1.1 ───────────────────────────────────────────
local function read_headers(conn)
    local status, err = conn:receive("*l")
    if not status then return nil, "pas de réponse : " .. tostring(err) end
    local code = tonumber(status:match("^HTTP/%d%.%d%s+(%d%d%d)"))
    if not code then return nil, "statut illisible : " .. status:sub(1, 60) end
    local hdrs = {}
    while true do
        local line, e = conn:receive("*l")
        if not line then return nil, "en-têtes : " .. tostring(e) end
        line = line:gsub("\r$", "")
        if line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.-)%s*$")
        if k then
            k = k:lower()
            hdrs[k] = hdrs[k] and (hdrs[k] .. ", " .. v) or v
        end
    end
    return code, hdrs
end

local function read_exact(conn, n, sink)
    while n > 0 do
        local data, err, partial = conn:receive(math.min(n, 16384))
        data = data or partial
        if data and #data > 0 then
            local ok, serr = sink(data)
            if not ok then return nil, serr or "sink" end
            n = n - #data
        else
            return nil, err or "lecture incomplète"
        end
    end
    return true
end

local function read_chunked(conn, sink)
    while true do
        local line, err = conn:receive("*l")
        if not line then return nil, "taille de bloc : " .. tostring(err) end
        local size = tonumber(line:match("^%s*(%x+)") or "", 16)
        if not size then return nil, "bloc invalide" end
        if size == 0 then
            while true do
                local l = conn:receive("*l")
                if not l or l == "" or l == "\r" then break end
            end
            return true
        end
        local ok, e = read_exact(conn, size, sink)
        if not ok then return nil, e end
        conn:receive("*l")   -- CRLF après le bloc
    end
end

local function read_until_close(conn, sink)
    while true do
        local data, err, partial = conn:receive(8192)
        local chunk = data or partial
        if chunk and #chunk > 0 then
            local ok, serr = sink(chunk)
            if not ok then return nil, serr or "sink" end
        end
        if err then
            if err == "closed" then return true end
            return nil, err
        end
        if not chunk or #chunk == 0 then return true end
    end
end

-- Renvoie code, en-têtes, extrait (corps tronqué si code ~= 200) — ou nil, erreur.
function M._request(ip, port, sni, req_host, path, headers, timeout, deadline_at, sink, max_bytes, method, body)
    local conn, cerr = M._connect(ip, port, sni, timeout)
    if not conn then return nil, cerr end

    local lines = { (method or "GET") .. " " .. path .. " HTTP/1.1", "Host: " .. req_host }
    local seen = { host = true, ["accept-encoding"] = true, connection = true }
    for k, v in pairs(headers or {}) do
        local lk = tostring(k):lower()
        if not seen[lk] then seen[lk] = true; lines[#lines + 1] = tostring(k) .. ": " .. tostring(v) end
    end
    if not seen["user-agent"] then lines[#lines + 1] = "User-Agent: " .. UA end
    if body and not seen["content-length"] then lines[#lines + 1] = "Content-Length: " .. #body end
    lines[#lines + 1] = "Accept-Encoding: identity"
    lines[#lines + 1] = "Connection: close"

    local sent, serr = conn:send(table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or ""))
    if not sent then conn:close(); return nil, "envoi : " .. tostring(serr) end

    local code, hdrs = read_headers(conn)
    if not code then conn:close(); return nil, hdrs end
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        conn:close()
        return code, hdrs
    end

    local total, extra = 0, nil
    local target = sink
    if code ~= 200 then
        extra = {}
        target = function(d)
            if #extra < 4 then extra[#extra + 1] = d end
            return nil, "stop"
        end
    end
    local function wsink(d)
        total = total + #d
        if max_bytes and total > max_bytes then return nil, "trop gros" end
        if socket.gettime() > deadline_at then return nil, "délai dépassé" end
        return target(d)
    end

    local te = tostring(hdrs["transfer-encoding"] or ""):lower()
    local cl = tonumber(hdrs["content-length"])
    local ok, rerr
    if te:find("chunked", 1, true) then ok, rerr = read_chunked(conn, wsink)
    elseif cl then ok, rerr = read_exact(conn, cl, wsink)
    else ok, rerr = read_until_close(conn, wsink) end
    conn:close()

    if code == 200 and not ok then return nil, "corps : " .. tostring(rerr) end
    return code, hdrs, extra and table.concat(extra):sub(1, 1500) or nil
end

-- ── Résolution DNS-over-HTTPS (adresses IP fixes : pas de DNS nécessaire) ────
local DOH = {
    { ip = "1.1.1.1", host = "cloudflare-dns.com", path = "/dns-query?name=%s&type=A" },
    { ip = "8.8.8.8", host = "dns.google",         path = "/resolve?name=%s&type=A" },
    { ip = "1.0.0.1", host = "cloudflare-dns.com", path = "/dns-query?name=%s&type=A" },
    { ip = "8.8.4.4", host = "dns.google",         path = "/resolve?name=%s&type=A" },
}

function M._parse_doh(body)
    local ips, seen = {}, {}
    for obj in tostring(body or ""):gmatch("{[^{}]*}") do
        if obj:find('"type"%s*:%s*1[^%d]') then
            local ip = obj:match('"data"%s*:%s*"(%d+%.%d+%.%d+%.%d+)"')
            if ip and not seen[ip] then seen[ip] = true; ips[#ips + 1] = ip end
        end
    end
    return ips
end

function M.resolve(host)
    local c = ipcache[host]
    if c and socket.gettime() - c.t < 900 then return c.ips end
    for _, ep in ipairs(DOH) do
        local buf = {}
        local code, h2 = M._request(ep.ip, 443, ep.host, ep.host, string.format(ep.path, host),
            { Accept = "application/dns-json" }, 6, socket.gettime() + 10,
            function(d) buf[#buf + 1] = d; return 1 end, 65536)
        if code == 200 then
            local ips = M._parse_doh(table.concat(buf))
            if #ips > 0 then
                log("DoH", ep.ip, host, "→", table.concat(ips, ","))
                ipcache[host] = { t = socket.gettime(), ips = ips }
                return ips
            end
            log("DoH", ep.ip, "réponse sans adresse pour", host)
        else
            log("DoH", ep.ip, "échec :", tostring(code), type(h2) == "string" and h2 or "")
        end
    end
    return nil, "résolution DoH impossible (1.1.1.1 / 8.8.8.8 injoignables ?)"
end

-- opts : headers, timeout, deadline, max_bytes, file (écrit le corps dans ce fichier)
-- Renvoie body, 200, headers  (body = true si `file`) — ou nil, code_ou_erreur, extrait.
function M.get(url, opts)
    opts = opts or {}
    local timeout = opts.timeout or 15
    local deadline_at = socket.gettime() + (opts.deadline or 45)
    local cur = url
    for _ = 0, 4 do
        local scheme, host, port, path = parse_url(cur)
        if scheme ~= "https" then return nil, "schéma non géré : " .. tostring(scheme) end
        local ips, rerr = M.resolve(host)
        if not ips then return nil, rerr end
        local req_host = host .. ((port ~= 443) and (":" .. port) or "")

        local code, hdrs, extra, buf, last_err
        for i = 1, math.min(#ips, 3) do
            local f
            buf = {}
            local sink
            if opts.file then
                f = io.open(opts.file, "wb")
                if not f then return nil, "open_error" end
                sink = function(d) f:write(d); return 1 end
            else
                sink = function(d) buf[#buf + 1] = d; return 1 end
            end
            code, hdrs, extra = M._request(ips[i], port, host, req_host, path,
                opts.headers, timeout, deadline_at, sink, opts.max_bytes, opts.method, opts.body)
            if f then f:close() end
            if code then break end
            last_err = hdrs
            log("connexion", ips[i], host, "échec :", tostring(hdrs))
            if opts.file then os.remove(opts.file) end
        end
        if not code then return nil, last_err or "échec" end

        if (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) and hdrs.location then
            cur = absolute(hdrs.location, host, port)
            log("redirection →", cur)
        elseif code == 200 then
            if opts.file then return true, 200, hdrs end
            return table.concat(buf), 200, hdrs
        else
            if opts.file then os.remove(opts.file) end
            return nil, code, extra
        end
    end
    return nil, "trop de redirections"
end

-- ── Plusieurs fichiers sur UNE connexion TLS (keep-alive) ────────────────────
-- Sur liseuse, la poignée de main TLS coûte cher (CPU faible) : une connexion par image
-- ralentit tout. Ici un même sous-processus enchaîne ses images sur la même connexion.
-- Toute image en échec est simplement laissée de côté : l'appelant la retente avec la
-- méthode classique (une connexion par image).
local function file_is_html(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(64) or ""
    f:close()
    return head:match("^%s*<") ~= nil
end

-- GET sur une connexion déjà ouverte. Renvoie code, en-têtes, réutilisable — ou nil, erreur.
local function request_on(conn, req_host, path, headers, deadline_at, sink)
    local lines = { "GET " .. path .. " HTTP/1.1", "Host: " .. req_host }
    local seen = { host = true, ["accept-encoding"] = true, connection = true }
    for k, v in pairs(headers or {}) do
        local lk = tostring(k):lower()
        if not seen[lk] then seen[lk] = true; lines[#lines + 1] = tostring(k) .. ": " .. tostring(v) end
    end
    if not seen["user-agent"] then lines[#lines + 1] = "User-Agent: " .. UA end
    lines[#lines + 1] = "Accept-Encoding: identity"
    lines[#lines + 1] = "Connection: keep-alive"
    local sent, serr = conn:send(table.concat(lines, "\r\n") .. "\r\n\r\n")
    if not sent then return nil, "envoi : " .. tostring(serr) end
    local code, hdrs = read_headers(conn)
    if not code then return nil, hdrs end
    if code ~= 200 then return code, hdrs, false end   -- corps non lu : connexion à fermer
    local function wsink(d)
        if socket.gettime() > deadline_at then return nil, "délai dépassé" end
        return sink(d)
    end
    local te = tostring(hdrs["transfer-encoding"] or ""):lower()
    local cl = tonumber(hdrs["content-length"])
    local ok, rerr, reusable
    if te:find("chunked", 1, true) then ok, rerr = read_chunked(conn, wsink); reusable = true
    elseif cl then ok, rerr = read_exact(conn, cl, wsink); reusable = true
    else ok, rerr = read_until_close(conn, wsink); reusable = false end
    if not ok then return nil, "corps : " .. tostring(rerr) end
    if tostring(hdrs.connection or ""):lower():find("close", 1, true) then reusable = false end
    return 200, hdrs, reusable
end

-- items : { { url, file }, … } ; opts : headers, timeout, deadline, doh (true = résoudre
-- en DoH, sinon DNS du système puis DoH), on_file(i, ok) appelé après chaque fichier.
-- Renvoie une table results[i] = true/false.
function M.get_files(items, opts)
    opts = opts or {}
    local timeout = opts.timeout or 15
    local deadline_at = socket.gettime() + (opts.deadline or 600)
    local results, conn, conn_key = {}, nil, nil
    local function drop()
        if conn then pcall(conn.close, conn) end
        conn, conn_key = nil, nil
    end
    local function open(host, port)
        local ips
        if opts.doh then ips = M.resolve(host) end
        if not ips then
            local ok_d, ip = pcall(function() return socket.dns.toip(host) end)
            if ok_d and ip then ips = { ip } end
        end
        if not ips and not opts.doh then ips = M.resolve(host) end
        if not ips then return nil end
        for k = 1, math.min(#ips, 3) do
            local c = M._connect(ips[k], port, host, timeout)
            if c then return c end
        end
        return nil
    end

    for i, it in ipairs(items) do
        local scheme, host, port, path = parse_url(it.url)
        local ok = false
        if scheme == "https" then
            for _ = 1, 2 do
                local key = host .. ":" .. port
                if conn and conn_key ~= key then drop() end
                local fresh = false
                if not conn then
                    conn = open(host, port)
                    if not conn then break end
                    conn_key, fresh = key, true
                end
                local f = io.open(it.file, "wb")
                if not f then break end
                local req_host = host .. ((port ~= 443) and (":" .. port) or "")
                local code, _, reusable = request_on(conn, req_host, path, opts.headers, deadline_at,
                    function(d) f:write(d); return 1 end)
                f:close()
                if code == 200 and not file_is_html(it.file) then
                    ok = true
                    if not reusable then drop() end
                    break
                end
                os.remove(it.file)
                drop()
                if fresh then break end     -- déjà une connexion neuve : inutile de réessayer
            end
        end
        results[i] = ok
        if opts.on_file then pcall(opts.on_file, i, ok) end
    end
    drop()
    return results
end

return M
