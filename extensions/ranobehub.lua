-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- ranobehub.lua
-- Extension Sefirah pour https://ranobehub.org (ranobés et web novels en russe).
--
-- Site Next.js rendu côté serveur. Structure relevée sur du vrai HTML
-- (pages enregistrées le 2026-10-17) :
--   * Accueil      : cartes div.home-recommendation-card > a[href=/ranobe/<id>-<slug>]
--                    avec <img> (couverture), <strong> (titre), <small> (note · chapitres)
--   * Fiche roman  : /ranobe/<id>-<slug>
--       h1                          titre
--       img[alt^="Постер"]          couverture (/_next/image?url=/api/media/<n>…)
--       #book-description           résumé
--       nav « Жанры »               genres
--       a[href*="/ranobe?status="]  statut (Завершено = terminé)
--       <b>N</b><small>глав</small> nombre de chapitres
--       #book-panel-chapters        chapitres, regroupés par tome (accordéon)
--         a#chapter-list-<id>[href] numéro (<small>), titre (<span>), date (<time>)
--   * Chapitre     : /ranobe/<id>-<slug>/chapter/<id-chapitre>
--       texte dans div#reader-content-<id-chapitre> (paragraphes <p>, blocs
--       <aside> publicitaires entre les paragraphes)
--
-- LISTES (confirmé sur la page enregistrée le 2026-10-18) : 24 romans par page, fournis en
-- JSON dans le flux Next.js de la page (voir extract_result) avec le total, le nombre de pages
-- et tous les filtres. Recherche et filtres passent par /ranobe?q=…&tag=9&tag=8…&page=N, lu
-- d'abord par la requête « flux » du site (en-tête RSC), puis par la page HTML.
--
-- NON CONFIRMÉ :
--   * la liste COMPLÈTE des chapitres : dans la page enregistrée, seul le tome ouvert contient
--     ses liens. On essaie /api/ranobe/<id>/contents (ancienne API, JSON) puis on retombe sur
--     les chapitres visibles + « Начать читать » ;
--   * les paramètres d'adresse des filtres event, country, yearFrom, yearTo, ratingFrom,
--     chaptersFrom (tag et status sont confirmés) : voir sefirah/ranobehub_last_url.txt.
-- En cas de liste vide ou d'échec, la réponse du site est enregistrée dans
-- sefirah/ranobehub_last_error.txt (dossier des réglages de KOReader).

local BASE   = "https://ranobehub.org"
local logger = require("logger")

-- Réseau qui bloque ranobehub.org (« connection refused » dès la sonde TCP, ou page
-- « Content blocked ») : core/net.lua bascule alors sur la résolution DNS-over-HTTPS.
local ok_bp, Bypass = pcall(require, "core.dnsbypass")
if not ok_bp then Bypass = nil end
if Bypass then Bypass.register("ranobehub.org") end

local T = require("core.i18n").T

local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

-- ── Helpers HTML ──────────────────────────────────────────────────────────────

local function utf8_encode(cp)
    if not cp then return "" end
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + (math.floor(cp / 0x40) % 0x40),
                           0x80 + (cp % 0x40))
    else
        return string.char(0xF0 + math.floor(cp / 0x40000),
                           0x80 + (math.floor(cp / 0x1000) % 0x40),
                           0x80 + (math.floor(cp / 0x40) % 0x40),
                           0x80 + (cp % 0x40))
    end
end

local NAMED = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    hellip = "…", rsquo = "’", lsquo = "‘", rdquo = "”", ldquo = "“",
    laquo = "«", raquo = "»", ndash = "–", mdash = "—",
}

local function decode_entities(s)
    s = s:gsub("&#[xX](%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);",     function(d) return utf8_encode(tonumber(d)) end)
    -- &amp; en dernier : « &amp;lt; » doit rester « &lt; », pas devenir « < ».
    s = s:gsub("&(%a+);", function(n)
        if n == "amp" then return nil end
        return NAMED[n]
    end)
    s = s:gsub("&amp;", "&")
    return s
end

local function strip_tags(s)
    s = (s or ""):gsub("<[^>]+>", "")
    s = decode_entities(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Contenu équilibré d'un <div> : renvoie le contenu et la position qui suit.
local function extract_div(html, open_pattern, start_pos)
    local s, e = html:find(open_pattern, start_pos or 1)
    if not s then return nil, nil end
    local tag_end = html:find(">", e, true)
    if not tag_end then return nil, nil end
    local depth, pos = 1, tag_end + 1
    while depth > 0 and pos <= #html do
        local open_pos  = html:find("<div", pos, true)
        local close_pos = html:find("</div>", pos, true)
        if not close_pos then break end
        if open_pos and open_pos < close_pos then
            depth = depth + 1
            pos   = open_pos + 4
        else
            depth = depth - 1
            if depth == 0 then
                return html:sub(tag_end + 1, close_pos - 1), close_pos + 6
            end
            pos = close_pos + 6
        end
    end
    return nil, nil
end

local function url_encode(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function url_decode(str)
    return (str:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function abs_url(u)
    if not u then return nil end
    u = decode_entities(tostring(u)):gsub("^%s+", ""):gsub("%s+$", "")
    if u == "" or u:match("^data:") then return nil end
    if u:sub(1, 2) == "//" then return "https:" .. u end
    if u:sub(1, 1) == "/"  then return BASE .. u end
    return u
end

-- URL absolue ou relative -> « /chemin » (sans domaine, avec « / » initial).
local function to_path(u)
    u = tostring(u or ""):gsub("^https?://[^/]+", "")
    if u:sub(1, 1) ~= "/" then u = "/" .. u end
    return u
end

local function full_url(path)
    if path:match("^https?://") then return path end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return BASE .. path
end

local function attr(tag, name)
    if not tag then return nil end
    local esc = name:gsub("%-", "%%-")
    local v = tag:match("[%s<]" .. esc .. '%s*=%s*"([^"]*)"')
           or tag:match("[%s<]" .. esc .. "%s*=%s*'([^']*)'")
    return v
end

-- Les images passent par /_next/image?url=<chemin encodé>&w=…&q=… : on
-- reprend directement l'image d'origine (/api/media/<n>?v=5&size=…).
local function media_url(u)
    if not u then return nil end
    u = decode_entities(tostring(u))
    if u:find("/_next/image", 1, true) then
        local inner = u:match("[?&]url=([^&]+)")
        if inner then u = url_decode(inner) end
    end
    return abs_url(u)
end

-- Couverture : plusieurs adresses candidates (séparées par une tabulation), de la
-- plus légère à la plus lourde. Next.js sert l'image via /_next/image avec un
-- srcset ; la <img> peut aussi n'avoir qu'un espace réservé « data: » (chargement
-- différé) avec la vraie adresse dans data-src / data-srcset. Avant, on ne
-- gardait qu'UNE adresse (l'originale, parfois très lourde) : si elle échouait
-- ou dépassait 2 Mo, la couverture restait vide.
-- React/Next.js écrit « srcSet » (S majuscule) dans le HTML serveur : attr() est
-- sensible à la casse, d'où cette variante qui essaie plusieurs graphies.
local function attr_any(tag, names)
    for _, n in ipairs(names) do
        local v = attr(tag, n)
        if v and v ~= "" then return v end
    end
    return nil
end

local function srcset_list(v)
    local out = {}
    if not v or v == "" then return out end
    v = decode_entities(v)
    for u, n in v:gmatch("(%S+)%s+([%d%.]+)[wx]%s*,?") do
        local a = abs_url((u:gsub("^,", "")))
        if a then out[#out + 1] = { url = a, n = tonumber(n) or 0 } end
    end
    table.sort(out, function(a, b) return a.n < b.n end)
    return out
end

local function cover_candidates(block)
    if not block then return nil end
    local cands, seen = {}, {}
    local function add(u)
        if u and not seen[u] then seen[u] = true; cands[#cands + 1] = u end
    end
    local tags = {}
    for tag in block:gmatch("<img[^>]*>") do tags[#tags + 1] = tag end
    for tag in block:gmatch("<source[^>]*>") do tags[#tags + 1] = tag end
    if #tags == 0 then return nil end

    local sets, raws = {}, {}
    for _, tag in ipairs(tags) do
        local ss = attr_any(tag, { "srcSet", "srcset", "data-srcset", "data-srcSet" })
        for _, e in ipairs(srcset_list(ss)) do sets[#sets + 1] = e end
        for _, key in ipairs({ "src", "data-src", "data-lazy-src" }) do
            local u = abs_url(attr(tag, key))
            if u then raws[#raws + 1] = u end
        end
    end
    table.sort(sets, function(a, b) return a.n < b.n end)

    -- 1. l'image d'origine « size=medium » (petite, sans passer par l'optimiseur)
    for _, u in ipairs(sets) do add(media_url(u.url)) end
    for _, u in ipairs(raws) do add(media_url(u)) end
    -- 2. la plus petite variante du srcset d'au moins 256 px, puis les suivantes
    for _, e in ipairs(sets) do
        if e.n >= 256 and e.n <= 640 then add(e.url) end
    end
    -- 3. en dernier recours seulement : les versions lourdes (src = 3840 px)
    for _, u in ipairs(raws) do add(u) end

    if #cands == 0 then return nil end
    return table.concat(cands, "\t")
end

local function img_url(block)
    return cover_candidates(block)
end

-- ── Debug ─────────────────────────────────────────────────────────────────────

local function write_debug_file(name, content)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local f = io.open(dir .. "/" .. name, "wb")
        if f then f:write(content); f:close() end
    end)
end

local function write_debug(content)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local f = io.open(dir .. "/ranobehub_last_error.txt", "wb")
        if f then
            f:write(content)
            if Bypass then f:write("\n\n--- contournement DNS ---\n", Bypass.journal(), "\n") end
            f:close()
        end
    end)
end

-- ── HTTP ──────────────────────────────────────────────────────────────────────

local last_fail = nil

local function headers(lite, json, extra)
    local h = {
        ["User-Agent"]      = UA,
        ["Accept"]          = json and "application/json, text/plain, */*"
                                    or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "ru-RU,ru;q=0.9,en;q=0.5",
    }
    if not lite then h["Referer"] = BASE .. "/" end
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
end

local function is_retryable(code)
    if type(code) ~= "number" then return true end
    return code == 403 or code == 429 or code >= 500
end

local function http_get(url, json, extra_headers)
    local Net = require("core.net")
    local body, code, extra = Net.get(url, { headers = headers(false, json, extra_headers), timeout = 12 })
    if not body and is_retryable(code) then
        pcall(function() require("socket").sleep(1.5) end)
        body, code, extra = Net.get(url, { headers = headers(true, json, extra_headers), timeout = 15 })
    end
    if body then
        last_fail = nil
        return body
    end
    last_fail = { code = code, body = tostring(extra or "") }
    logger.err("RanobeHub: http_get FAILED", url, tostring(code))
    write_debug("URL : " .. url .. "\nStatut : " .. tostring(code)
        .. "\nDébut de la réponse :\n" .. last_fail.body .. "\n")
    return nil, code
end

-- La fiche est demandée deux fois de suite par l'interface (parseNovelMeta puis
-- parseNovel) : on garde la page nettoyée quelques minutes en mémoire.
local extract_volumes  -- défini plus bas (lit le JSON Next.js de la page)
local page_cache = { path = nil, raw = nil, html = nil, vols = nil, vols_done = false, meta = nil, t = 0 }

-- Les tomes (JSON des <script>) ne sont extraits que si on les demande : cette
-- extraction (recomposition du flux Next.js + décodage JSON) est lourde sur une
-- liseuse, et parseNovelMeta (chemin le plus courant : liste de chapitres déjà en
-- cache) n'en a pas besoin. Les métadonnées sont aussi gardées pour ne pas être
-- recalculées par l'appel suivant (parseNovel après parseNovelMeta).
local function get_novel_html(path, want_vols)
    local now = os.time()
    local pc = page_cache
    if not (pc.path == path and pc.html and (now - pc.t) < 300) then
        local raw = http_get(full_url(path))
        if not raw then return nil end
        local html = raw:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
        pc = { path = path, raw = raw, html = html, vols = nil, vols_done = false, meta = nil, t = now }
        page_cache = pc
    end
    if want_vols and not pc.vols_done then
        pc.vols = (extract_volumes and pc.raw) and extract_volumes(pc.raw) or nil
        pc.vols_done = true
        pc.raw = nil   -- libère la page brute (plusieurs centaines de Ko)
    end
    return pc.html, pc.vols, pc
end

-- ── Diagnostic couvertures ────────────────────────────────────────────────────
-- Une seule fois par session : télécharge la couverture du premier roman de la liste
-- et note dans sefirah/ranobehub_cover_debug.txt ce que le serveur répond (statut,
-- taille, type, premiers octets) et si KOReader sait décoder l'image.
local diag_done = false
local function cover_diag(novels)
    if diag_done then return end
    diag_done = true
    pcall(function()
        local first
        for _, n in ipairs(novels or {}) do
            if n.cover and n.cover ~= "" then first = n; break end
        end
        if not first then
            write_debug_file("ranobehub_cover_debug.txt",
                "Aucun roman avec couverture dans la liste (" .. #(novels or {}) .. " romans).\n")
            return
        end
        local out = { "Roman : " .. tostring(first.name) .. "\n" }
        local Net = require("core.net")
        local i = 0
        for u in first.cover:gmatch("[^\t]+") do
            i = i + 1
            if i > 3 then break end
            local t0 = os.time()
            local data, code, rh = Net.get(u, {
                headers = { ["Accept"] = "image/*,*/*;q=0.5", ["Referer"] = BASE .. "/" },
                timeout = 6, deadline = 9, max_bytes = 3 * 1024 * 1024, no_gzip = true,
            })
            out[#out + 1] = "URL " .. i .. " : " .. u
            if data then
                local hex = data:sub(1, 12):gsub(".", function(c) return string.format("%02x", c:byte()) end)
                local ct = type(rh) == "table" and (rh["content-type"] or rh["Content-Type"]) or "?"
                local dec = "?"
                local ok_ri, RI = pcall(require, "ui/renderimage")
                if ok_ri then
                    local ok_d, bb = pcall(RI.renderImageData, RI, data, #data, false, 200, 300)
                    dec = (ok_d and bb) and "OUI" or "NON"
                    if ok_d and bb and bb.free then pcall(bb.free, bb) end
                end
                out[#out + 1] = string.format("  -> statut %s, %d octets, type %s, début %s, décodable : %s, %d s",
                    tostring(code), #data, tostring(ct), hex, dec, os.time() - t0)
            else
                out[#out + 1] = string.format("  -> ÉCHEC code %s (%s), %d s",
                    tostring(code), tostring(rh):sub(1, 120), os.time() - t0)
            end
        end
        write_debug_file("ranobehub_cover_debug.txt", table.concat(out, "\n") .. "\n")
    end)
end

local function failure_message()
    local f = last_fail or {}
    if f.code == 403 or f.code == 429 or f.code == 503
        or (f.body or ""):find("Just a moment", 1, true) then
        return T("RanobeHub refuse la requête (HTTP ") .. tostring(f.code)
            .. T(", protection Cloudflare).")
    end
    return T("RanobeHub injoignable : ") .. tostring(f.code or "erreur")
end

local function json_decode(body)
    if not body or not body:match("^%s*[{%[]") then return nil end
    local ok_j, json = pcall(require, "json")
    if not ok_j then return nil end
    local ok, data = pcall(json.decode, body)
    if ok and type(data) == "table" then return data end
    return nil
end

-- ── Listes de romans ──────────────────────────────────────────────────────────

-- /ranobe/<id>-<slug> (et rien après : pas /ranobe/<id>-<slug>/chapter/…).
local function novel_path(href)
    local p = to_path(decode_entities(href or ""):gsub("[%?#].*$", ""))
    local slug = p:match("^/ranobe/(%d+[^/]*)/?$")
    if not slug then return nil end
    return "/ranobe/" .. slug
end

local function looks_like_title(name)
    return name ~= "" and not name:match("^[%d%.,%s·]+$")
end

-- Parseur générique : tous les liens vers une fiche, regroupés par chemin.
-- Sur l'accueil (confirmé) le titre est dans <strong>, la couverture dans <img>.
local function parse_novel_links(html)
    local order, by_path = {}, {}
    for open, inner in html:gmatch("(<a[%s>][^>]*>)(.-)</a>") do
        local path = novel_path(attr(open, "href"))
        if path then
            local e = by_path[path]
            if not e then
                e = { path = path }
                by_path[path] = e
                order[#order + 1] = path
            end
            if not e.name then
                local name = strip_tags(inner:match("<strong[^>]*>(.-)</strong>")
                    or inner:match("<h%d[^>]*>(.-)</h%d>") or "")
                if not looks_like_title(name) then
                    name = strip_tags(attr(open, "title") or attr(open, "aria-label") or "")
                end
                if not looks_like_title(name) then
                    local img = inner:match("<img[^>]*>")
                    name = strip_tags(img and attr(img, "alt") or "")
                end
                if not looks_like_title(name) then name = strip_tags(inner) end
                if looks_like_title(name) then e.name = name end
            end
            if not e.cover then e.cover = img_url(inner) end
        end
    end
    local novels = {}
    for _, p in ipairs(order) do
        local e = by_path[p]
        if e.name then
            novels[#novels + 1] = { name = e.name, path = e.path, cover = e.cover }
        end
    end
    return novels
end

-- ── Fiche roman ───────────────────────────────────────────────────────────────

local function status_from_label(label)
    -- string.lower ne touche pas au cyrillique : on cherche des radicaux sans
    -- leur première lettre (« Завершено » -> « авершен »).
    local l = label or ""
    if     l:find("авершен", 1, true) then return "Completed"
    elseif l:find("процесс", 1, true) or l:find("родолж", 1, true)
        or l:find("нгоинг", 1, true) then return "Ongoing"
    elseif l:find("аморож", 1, true) or l:find("риостан", 1, true) then return "Hiatus"
    elseif l:find("рошен", 1, true) then return "Cancelled"
    end
    return "Unknown"
end

local function parse_meta(html)
    local title = strip_tags(html:match("<h1[^>]*>(.-)</h1>") or "")
    if title == "" then
        local og = html:match('<meta property="og:title" content="([^"]*)"') or ""
        title = strip_tags(og):gsub("%s*—%s*RanobeHub%s*$", "")
    end

    -- Couverture : <img alt="Постер «…»" src="…">
    local cover
    for tag in html:gmatch("<img[^>]*>") do
        local alt = attr(tag, "alt") or ""
        if alt:find("Постер", 1, true) then
            cover = cover_candidates(tag)
            break
        end
    end
    if not cover then
        cover = media_url(html:match('<meta property="og:image" content="([^"]*)"'))
    end

    -- Résumé : #book-description (paragraphes) ou, à défaut, <meta description>.
    local summary = ""
    local desc = extract_div(html, '<div[^>]-id="book%-description"')
    if desc then
        desc = desc:gsub("<br[^>]*/?>", "\n"):gsub("</p>", "\n\n")
        summary = strip_tags(desc):gsub("\n\n\n+", "\n\n")
    end
    if summary == "" then
        summary = strip_tags(html:match('<meta name="description" content="([^"]*)"') or "")
    end

    -- Genres : <nav><span>Жанры</span><a>…</a>…</nav>
    local genres = {}
    local gblock = html:match("Жанры</span>(.-)</nav>")
    if gblock then
        for inner in gblock:gmatch("<a[^>]*>(.-)</a>") do
            local g = strip_tags(inner)
            if g ~= "" then genres[#genres + 1] = g end
        end
    end

    -- Statut : lien /ranobe?status=N (« Завершено », « В процессе »…).
    local label
    for open, inner in html:gmatch("(<a[%s][^>]*>)(.-)</a>") do
        local href = attr(open, "href") or ""
        if href:find("/ranobe?status=", 1, true) then
            label = strip_tags(inner)
            break
        end
    end

    -- Nombre de chapitres : « <b>407</b><small>глав</small> ».
    local total
    local raw = html:match("<b>([%d%s&;nbsp]-)</b>%s*<small>%s*глав")
        or html:match("<strong>([%d%s&;nbsp]-)</strong>%s*глав")
    if raw then total = tonumber((decode_entities(raw):gsub("%D", ""))) end

    return {
        title   = title,
        cover   = cover,
        summary = summary,
        genres  = table.concat(genres, ", "),
        status  = status_from_label(label),
        total   = total,
    }
end

-- ── Chapitres ─────────────────────────────────────────────────────────────────

local function chapter_path(base_path, id)
    return base_path .. "/chapter/" .. tostring(id)
end

-- Chapitres présents dans le HTML de la fiche (tomes dépliés seulement).
local function parse_listed_chapters(html, base_path)
    local list, seen = {}, {}
    for open, inner in html:gmatch('(<a[^>]-id="chapter%-list%-%d+"[^>]*>)(.-)</a>') do
        local id = tonumber(attr(open, "id"):match("(%d+)$"))
        if id and not seen[id] then
            seen[id] = true
            local title = strip_tags(inner:match("<span[^>]*>(.-)</span>") or "")
            local dt = inner:match('<time[^>]-datetime="(%d%d%d%d%-%d%d%-%d%d)')
            list[#list + 1] = {
                id    = id,
                name  = title ~= "" and title or (T("Chapitre ") .. id),
                path  = chapter_path(base_path, id),
                date  = dt,
            }
        end
    end
    return list
end

-- Bouton « Начать читать » : lien vers le premier chapitre.
local function first_chapter_id(html)
    for open, inner in html:gmatch("(<a[%s][^>]*>)(.-)</a>") do
        if inner:find("Начать читать", 1, true) then
            return tonumber((attr(open, "href") or ""):match("/chapter/(%d+)"))
        end
    end
    return nil
end

local chapters_from_volumes  -- défini plus bas

local function build_chapters(html, base_path, meta, vols)
    local novel_id = base_path:match("^/ranobe/(%d+)")
    local list = nil
    if vols then
        list = chapters_from_volumes(vols, base_path, meta, novel_id)
    end
    if not list then
        list = parse_listed_chapters(html, base_path)
        local first = first_chapter_id(html)
        local have = {}
        for _, c in ipairs(list) do have[c.id] = true end
        if first and not have[first] then
            table.insert(list, 1, {
                id   = first,
                name = T("Chapitre ") .. 1,
                path = chapter_path(base_path, first),
            })
        end
        -- Sans l'API, seuls les tomes dépliés sont connus.
        table.sort(list, function(a, b) return a.id < b.id end)
        if meta.total and meta.total > #list then
            write_debug("Liste de chapitres incomplète pour " .. base_path
                .. "\nChapitres lus dans la page : " .. #list
                .. "\nChapitres annoncés : " .. meta.total
                .. "\n(/api/ranobe/" .. tostring(novel_id) .. "/contents n'a pas répondu comme prévu)\n")
        end
    end
    local chapters = {}
    for i, c in ipairs(list) do
        chapters[#chapters + 1] = {
            name           = c.name,
            path           = c.path,
            chapter_number = i,
            date           = c.date,
        }
    end
    return chapters
end


-- ── Données JSON intégrées à la page (Next.js) ────────────────────────────────
-- Constaté sur la vraie page /ranobe (enregistrée le 2026-10-18) : la liste des
-- romans (24 par page), le total, le nombre de pages et TOUS les filtres (genres,
-- événements, statuts, pays, avec leurs identifiants) sont fournis en JSON dans
-- des appels « self.__next_f.push([1,"…"]) » : {"result":{"items":[…],"total":…,
-- "page":…,"pages":…,"facets":{…}}}. C'est plus fiable que de lire les cartes HTML
-- (titre, chemin et affiche exacts, rien de tronqué).

local function js_unescape(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local j = s:find("\\", i, true)
        if not j then out[#out + 1] = s:sub(i); break end
        if j > i then out[#out + 1] = s:sub(i, j - 1) end
        local c = s:sub(j + 1, j + 1)
        local step = 2
        if c == "u" and s:match("^%x%x%x%x", j + 2) then
            local cp = tonumber(s:sub(j + 2, j + 5), 16)
            step = 6
            if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j + 6, j + 7) == "\\u"
                and s:match("^%x%x%x%x", j + 8) then
                local lo = tonumber(s:sub(j + 8, j + 11), 16)
                if lo >= 0xDC00 and lo <= 0xDFFF then
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    step = 12
                end
            end
            out[#out + 1] = utf8_encode(cp)
        elseif c == "n" then out[#out + 1] = "\n"
        elseif c == "r" then out[#out + 1] = "\r"
        elseif c == "t" then out[#out + 1] = "\t"
        elseif c == "b" then out[#out + 1] = "\b"
        elseif c == "f" then out[#out + 1] = "\f"
        else out[#out + 1] = c end
        i = j + step
    end
    return table.concat(out)
end

-- Texte complet du flux (les morceaux sont à mettre bout à bout : un objet JSON
-- peut être coupé au milieu entre deux appels).
local function flight_text(html)
    local parts = {}
    for chunk in html:gmatch('self%.__next_f%.push%(%[1,"(.-)"%]%)</script>') do
        parts[#parts + 1] = js_unescape(chunk)
    end
    return table.concat(parts)
end

-- Objet JSON équilibré commençant à « { » (position `start`), en tenant compte des
-- chaînes entre guillemets.
local function extract_json_object(text, start)
    local depth, in_str, esc = 0, false, false
    for i = start, #text do
        local c = text:byte(i)
        if in_str then
            if esc then esc = false
            elseif c == 92 then esc = true
            elseif c == 34 then in_str = false end
        elseif c == 34 then in_str = true
        elseif c == 123 or c == 91 then depth = depth + 1
        elseif c == 125 or c == 93 then
            depth = depth - 1
            if depth == 0 then return text:sub(start, i) end
        end
    end
    return nil
end

local RESULT_KEY = '"result":{"items":'

-- Renvoie la table { items, total, page, pages, facets, _initial_q } ou nil.
-- Accepte la réponse « flux » brute (en-tête RSC) comme la page HTML complète.
local function extract_result(body)
    if type(body) ~= "string" or body == "" then return nil end
    local text = body
    local s = text:find(RESULT_KEY, 1, true)
    if not s and body:find("__next_f", 1, true) then
        text = flight_text(body)
        s = text:find(RESULT_KEY, 1, true)
    end
    if not s then return nil end
    local obj = extract_json_object(text, s + #'"result":')
    if not obj then return nil end
    local ok_j, json = pcall(require, "json")
    if not ok_j then return nil end
    local ok, data = pcall(json.decode, obj)
    if not ok or type(data) ~= "table" or type(data.items) ~= "table" then return nil end
    data._initial_q = text:match('"initial":{"q":"([^"]*)"')
    return data
end

-- Tomes et chapitres fournis par la page : « volumes":[{id, number, chapters:[…],
-- chapterCount, truncated}] ». Le site n'en envoie qu'une partie par tome (début et fin,
-- « truncated »), le reste se charge au défilement.
extract_volumes = function(body)
    if type(body) ~= "string" or not body:find("__next_f", 1, true) then return nil end
    local text = flight_text(body)
    local s = text:find('"volumes":[{"id":', 1, true)
    if not s then return nil end
    local obj = extract_json_object(text, s + #'"volumes":')
    if not obj then return nil end
    local ok_j, json = pcall(require, "json")
    if not ok_j then return nil end
    local ok, data = pcall(json.decode, obj)
    if not ok or type(data) ~= "table" or #data == 0 then return nil end
    return data
end

-- Suite d'un tome : /api/books/<id>/chapters?volume=<n>&sort=desc&offset=…&limit=180
-- (adresse relevée dans la page : c'est ce que le site appelle au défilement ; réponse
-- { items, total, offset, nextOffset }). Les 24 derniers chapitres du tome sont déjà
-- dans la page, on repart donc de l'offset 24.
-- Cache disque d'un tome : la clé contient le nombre de chapitres annoncé, donc
-- il se périme tout seul quand le tome reçoit un nouveau chapitre.
local function vol_cache_path(novel_id, vnum, count)
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok then return nil end
    local dir = DataStorage:getSettingsDir() .. "/sefirah/ranobehub_cache"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs then
        pcall(lfs.mkdir, DataStorage:getSettingsDir() .. "/sefirah")
        pcall(lfs.mkdir, dir)
    end
    return string.format("%s/vol_%s_%s_%s.json", dir, tostring(novel_id), tostring(vnum), tostring(count))
end

local function vol_cache_read(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local raw = f:read("*all"); f:close()
    local data = json_decode(raw)
    if data and type(data.items) == "table" and #data.items > 0 then return data.items end
    return nil
end

local function vol_cache_write(path, items)
    if not path or #items == 0 then return end
    pcall(function()
        local json = require("json")
        local slim = {}
        for _, c in ipairs(items) do
            slim[#slim + 1] = { id = c.id, number = c.number, title = c.title, publishedAt = c.publishedAt }
        end
        local tmp = path .. ".tmp"
        local f = io.open(tmp, "wb")
        if not f then return end
        f:write(json.encode({ items = slim })); f:close()
        os.rename(tmp, path)
    end)
end

-- { items, total, offset, nextOffset }). Les 24 derniers chapitres du tome sont déjà
-- dans la page, on repart donc de l'offset 24.
local function fetch_volume_rest(novel_id, vnum, start, count)
    local cpath = vol_cache_path(novel_id, vnum, count)
    local cached = vol_cache_read(cpath)
    if cached then return cached end

    local out, offset, guard, complete = {}, start, 0, false
    while guard < 60 do
        guard = guard + 1
        if guard > 1 then pcall(function() require("socket").sleep(0.1) end) end
        local body = http_get(BASE .. "/api/books/" .. novel_id .. "/chapters?volume="
            .. tostring(vnum) .. "&sort=desc&offset=" .. offset .. "&limit=180", true)
        local data = json_decode(body)
        if not data or type(data.items) ~= "table" then break end
        for _, c in ipairs(data.items) do out[#out + 1] = c end
        local nxt, total = tonumber(data.nextOffset), tonumber(data.total) or 0
        if not nxt or nxt <= offset or nxt >= total then complete = true; break end
        offset = nxt
    end
    -- On ne garde sur disque que les tomes récupérés en entier.
    if complete then vol_cache_write(cpath, out) end
    return out
end

chapters_from_volumes = function(vols, base_path, meta, novel_id)
    local known, seen = {}, {}
    for _, v in ipairs(vols) do
        if type(v) == "table" and type(v.chapters) == "table" then
            for _, c in ipairs(v.chapters) do
                local id, num = tonumber(c.id), tonumber(c.number)
                if id and num and not seen[id] then
                    seen[id] = true
                    local title = type(c.title) == "string" and strip_tags(c.title) or ""
                    known[#known + 1] = {
                        id = id, number = num, volume = tonumber(v.number),
                        name = title ~= "" and title or (T("Chapitre ") .. num),
                        date = tostring(c.publishedAt or ""):match("^(%d%d%d%d%-%d%d%-%d%d)"),
                    }
                end
            end
        end
    end
    -- Décompresse chaque tome incomplet.
    if novel_id then
        -- Tomes incomplets sans cache disque : on les télécharge EN PARALLÈLE
        -- (5 à la fois, chacun dans son sous-processus qui écrit son cache), puis la
        -- boucle ci-dessous relit simplement les fichiers. Repli séquentiel si le
        -- parallélisme n'est pas disponible.
        local todo = {}
        for _, v in ipairs(vols) do
            local vnum, count = tonumber(v.number), tonumber(v.chapterCount) or 0
            if vnum and type(v.chapters) == "table" and #v.chapters < count
               and not vol_cache_read(vol_cache_path(novel_id, vnum, count)) then
                todo[#todo + 1] = { vnum = vnum, count = count }
            end
        end
        if #todo > 1 then
            local okp, Parallel = pcall(require, "core.parallel")
            if okp and Parallel.available() then
                local i = 1
                while i <= #todo do
                    local jobs = {}
                    for k = i, math.min(i + 5, #todo) do
                        local t = todo[k]
                        jobs[#jobs + 1] = function()
                            fetch_volume_rest(novel_id, t.vnum, 24, t.count)
                        end
                    end
                    if not Parallel.runAndWait(jobs, 45) then break end
                    i = i + 6
                end
            end
        end
        for _, v in ipairs(vols) do
            local vnum, count = tonumber(v.number), tonumber(v.chapterCount) or 0
            if vnum and type(v.chapters) == "table" and #v.chapters < count then
                for _, c in ipairs(fetch_volume_rest(novel_id, vnum, 24, count)) do
                    local id, num = tonumber(c.id), tonumber(c.number)
                    if id and num and not seen[id] then
                        seen[id] = true
                        local title = type(c.title) == "string" and strip_tags(c.title) or ""
                        known[#known + 1] = {
                            id = id, number = num, volume = vnum,
                            name = title ~= "" and title or (T("Chapitre ") .. num),
                            date = tostring(c.publishedAt or ""):match("^(%d%d%d%d%-%d%d%-%d%d)"),
                        }
                    end
                end
            end
        end
    end
    if #known == 0 then return nil end
    table.sort(known, function(a, b)
        if a.number ~= b.number then return a.number < b.number end
        return a.id < b.id
    end)
    -- Trous : si deux chapitres connus ont le même décalage (id - numéro), les
    -- chapitres entre eux ont des identifiants consécutifs (cas des traductions
    -- importées d'un bloc) : on les reconstitue.
    local list = {}
    for i, a in ipairs(known) do
        list[#list + 1] = a
        local b = known[i + 1]
        if b and b.number - a.number > 1 and b.number - a.number <= 3000
            and (b.id - b.number) == (a.id - a.number) then
            for n = a.number + 1, b.number - 1 do
                list[#list + 1] = {
                    id = n + (a.id - a.number), number = n, volume = a.volume,
                    name = T("Chapitre ") .. n,
                }
            end
        end
    end
    local out = {}
    for _, c in ipairs(list) do
        out[#out + 1] = { id = c.id, name = c.name, path = chapter_path(base_path, c.id), date = c.date, volume = c.volume }
    end
    if meta and meta.total and meta.total > #out then
        write_debug("Liste de chapitres encore incomplète pour " .. base_path
            .. "\nChapitres obtenus : " .. #out .. " / " .. meta.total
            .. "\n(le reste des tomes se charge au défilement sur le site : adresse à relever)\n")
    end
    return out
end

-- Affiches : l'optimiseur du site (/_next/image) sert un JPEG léger (~20-35 Ko) que
-- KOReader décode toujours ; l'original est un WebP bien plus lourd. On essaie donc le
-- JPEG léger d'abord, puis l'original, puis une version plus grande.
local function poster_candidates(p)
    if type(p) ~= "string" or p == "" then return nil end
    if p:sub(1, 1) ~= "/" then return abs_url(p) end
    local enc = url_encode(p)
    return table.concat({
        BASE .. "/_next/image?url=" .. enc .. "&w=384&q=75",
        BASE .. "/_next/image?url=" .. enc .. "&w=256&q=75",
        BASE .. p,
        BASE .. "/_next/image?url=" .. enc .. "&w=640&q=75",
    }, "\t")
end

local function item_to_novel(it)
    if type(it) ~= "table" then return nil end
    local id = tonumber(it.id)
    local title = type(it.title) == "string" and strip_tags(it.title) or ""
    if not id or title == "" then return nil end
    local slug = type(it.slug) == "string" and it.slug or ""
    local path = "/ranobe/" .. string.format("%d", id)
        .. (slug ~= "" and ("-" .. url_encode(slug)) or "")
    return { name = title, path = path, cover = poster_candidates(it.posterUrl) }
end

-- ── Filtres ───────────────────────────────────────────────────────────────────
-- Identifiants relevés dans la page du site. Genres, statuts et pays sont complets ;
-- pour les événements (plus de 700) on garde les plus fréquents, et ext:loadFilters()
-- relit la liste complète sur le site à la 1re ouverture de « Filtrer ».
-- Paramètres d'adresse : tag, event, status, country (répétés pour une sélection
-- multiple : ?tag=9&tag=8). « tag » et « status » sont confirmés par le site ;
-- event, country, yearFrom, yearTo, ratingFrom, chaptersFrom suivent les noms de
-- l'état interne de la page (à vérifier : voir sefirah/ranobehub_last_url.txt).

local function parse_pairs(str)
    local list = {}
    for id, title in str:gmatch("(%d+)|([^;]+);") do
        list[#list + 1] = { id = id, label = title }
    end
    return list
end

local function clean_label(s)
    s = tostring(s or ""):gsub("[\r\n]+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function multi_options(list)
    local o = { { id = "", label = T("Tous") } }
    for _, e in ipairs(list) do o[#o + 1] = { id = e.id, label = e.label } end
    return o
end

local GENRES = parse_pairs("8|Фэнтези;9|Романтика;11|Приключение;17|Комедия;14|Экшн;7|Драма;114|Гарем;20|Сверхъестественное;93|Повседневность;22|Боевые искусства;189|Сёнэн;2|Мистика;15|Сёдзё;18|Психология;1071|Исекай;216|Дзёсэй;19|Трагедия;5|Сэйнэн;13|Научная фантастика;21|Школьная жизнь;1078|Фантастика;327|Эччи;115|Зрелая тематика;1070|Школа;1092|История;1|Ужасы;242|Сюаньхуа;1090|Игра;3|Триллер;993|Видеоигры;12|Милитари;1108|Героическое фэнтези;364|Сянься;1077|Детектив;24|Меха;101|Исторический;1095|Безумие;246|Гендер бендер;1116|Военное;1107|Супер сила;747|Непристойность;1114|Космос;720|Уся;420|Спорт;1119|Киберпанк;1093|Машины;1133|Арт;638|Лоликон;922|Магический реализм;907|Восточное фэнтези;1063|Магия;1123|Самурайский боевик;")
local EVENTS = parse_pairs("39|Главный герой — мужчина;63|Главный герой — женщина;38|Магия;33|Умный главный герой;281|Реинкарнация;69|Монстры;6|Демоны;42|Всемогущий главный герой;30|Прекрасная героиня;152|Игровые элементы;27|Есть манга-адаптация;184|Средневековье;211|Боги;195|Драконы;123|Культивация;107|Красивый герой;95|Рост персонажа;81|Из слабого в сильного;55|Меч и магия;1073|Воспоминания из другого мира;172|Эльфы;32|Спокойный главный герой;40|Современность;37|Трудолюбивый главный герой;26|Есть аниме-адаптация;43|Политика;219|Подземелья;544|Борьба за власть;126|Фэнтези мир;80|Путешествие во времени;290|Выживание;161|Сильный любовный интерес;209|Расы зооморфов;")
local STATUSES = parse_pairs("1|В процессе;2|Завершено;3|Заморожено;4|Неизвестно;")
local COUNTRIES = parse_pairs("2|Китай;3|Корея;4|США;1|Япония;")

local function single_options(list)
    local o = {}
    for _, e in ipairs(list) do o[#o + 1] = { id = e[1], label = T(e[2]) } end
    return o
end

local F_SORT = { key = "sort", label = T("Tri"), default = "updated", options = single_options({
    { "updated",     "Mises à jour" },
    { "popular",     "Populaires" },
    { "rating",      "Mieux notés" },
    { "new",         "Nouveautés" },
    { "underrated",  "Perles cachées" },
    { "rediscover",  "Du fond du catalogue" },
    { "chapters",    "Plus de chapitres" },
}) }
local F_TAG     = { key = "tag",     label = T("Genres"),     default = "", multi = true, options = multi_options(GENRES) }
local F_EVENT   = { key = "event",   label = T("Événements"), default = "", multi = true, options = multi_options(EVENTS) }
local F_STATUS  = { key = "status",  label = T("Statut"),     default = "", multi = true, options = multi_options(STATUSES) }
local F_COUNTRY = { key = "country", label = T("Pays"),       default = "", multi = true, options = multi_options(COUNTRIES) }
local F_YEAR_FROM = { key = "yearFrom", label = T("Année min."), default = "", options = single_options({
    { "", "Toutes" }, { "2026", "2026" }, { "2025", "2025" }, { "2024", "2024" }, { "2023", "2023" },
    { "2022", "2022" }, { "2021", "2021" }, { "2020", "2020" }, { "2018", "2018" }, { "2015", "2015" },
    { "2010", "2010" }, { "2000", "2000" },
}) }
local F_YEAR_TO = { key = "yearTo", label = T("Année max."), default = "", options = single_options({
    { "", "Toutes" }, { "2025", "2025" }, { "2023", "2023" }, { "2020", "2020" }, { "2015", "2015" },
    { "2010", "2010" }, { "2000", "2000" },
}) }
local F_RATING = { key = "ratingFrom", label = T("Note min."), default = "", options = single_options({
    { "", "Toutes" }, { "6", "6+" }, { "7", "7+" }, { "8", "8+" }, { "9", "9+" },
}) }
local F_CHAPTERS = { key = "chaptersFrom", label = T("Chapitres min."), default = "", options = single_options({
    { "", "Tous" }, { "10", "10+" }, { "50", "50+" }, { "100", "100+" }, { "200", "200+" },
    { "500", "500+" }, { "1000", "1000+" },
}) }

local POPULAR_FILTERS = { F_SORT, F_TAG, F_EVENT, F_STATUS, F_COUNTRY, F_YEAR_FROM, F_YEAR_TO, F_RATING, F_CHAPTERS }

-- Adresse de liste : /ranobe?q=…&sort=…&tag=9&tag=8&…&page=N
local function build_qs(term, page, f)
    f = f or {}
    local qs = {}
    local function add(k, v) qs[#qs + 1] = k .. "=" .. url_encode(tostring(v)) end
    if term and term ~= "" then add("q", term) end
    if f.sort and f.sort ~= "" and f.sort ~= "updated" then add("sort", f.sort) end
    for _, k in ipairs({ "tag", "event", "status", "country" }) do
        for id in tostring(f[k] or ""):gmatch("[^,]+") do add(k, id) end
    end
    for _, k in ipairs({ "yearFrom", "yearTo", "ratingFrom", "chaptersFrom" }) do
        if f[k] and f[k] ~= "" then add(k, f[k]) end
    end
    if page and page > 1 then add("page", page) end
    return table.concat(qs, "&")
end

-- Une liste : d'abord la requête « flux » du site (celle que fait la page elle-même
-- quand on tape une recherche ou coche un filtre : en-tête RSC + _rsc=…), puis la
-- page HTML complète. Le serveur ignore parfois ?q= dans la page HTML : on détecte
-- ce cas (état « initial.q » vide) pour ne pas afficher le catalogue entier à la place
-- des résultats.
local RSC_HEADERS = { ["RSC"] = "1", ["Accept"] = "text/x-component" }

local function fetch_listing(term, page, filters)
    local qs = build_qs(term, page, filters)
    local path = "/ranobe" .. (qs ~= "" and ("?" .. qs) or "")
    local how, data, html_body

    local function ok_for(d)
        if not d then return nil end
        if term ~= "" and d._initial_q == "" then return nil end
        return d
    end

    local body = http_get(BASE .. path .. (qs ~= "" and "&" or "?") .. "_rsc=sefirah", false, RSC_HEADERS)
    data = ok_for(extract_result(body))
    if data then how = "rsc" end

    if not data then
        html_body = http_get(BASE .. path)
        data = ok_for(extract_result(html_body))
        if data then how = "html-json" end
    end
    pcall(write_debug_file, "ranobehub_last_url.txt",
        "URL : " .. BASE .. path .. "\nMéthode : " .. tostring(how or "échec")
        .. "\nRomans : " .. tostring(data and #data.items or 0)
        .. "\nTotal : " .. tostring(data and data.total or "?")
        .. "\nPage : " .. tostring(data and data.page or "?")
        .. " / " .. tostring(data and data.pages or "?") .. "\n")
    return data, html_body
end

local function listing(term, page, options)
    page = page or 1
    local data, html_body = fetch_listing(term, page, options and options.filters)
    if data then
        -- Page hors limites : le site renvoie parfois la dernière page en boucle.
        if (data.page and tonumber(data.page) ~= page)
            or (data.pages and page > tonumber(data.pages)) then
            return { novels = {} }
        end
        local novels = {}
        for _, it in ipairs(data.items) do
            local n = item_to_novel(it)
            if n then novels[#novels + 1] = n end
        end
        cover_diag(novels)
        return { novels = novels }
    end
    -- Dernier recours (liste sans filtre seulement) : cartes HTML de la page.
    if term == "" and html_body then
        local novels = parse_novel_links(html_body)
        if #novels > 0 then cover_diag(novels); return { novels = novels } end
    end
    if not html_body and not last_fail then return { novels = {} } end
    if last_fail then return { novels = {}, error = failure_message() } end
    return { novels = {}, error = T("RanobeHub : réponse non reconnue (voir sefirah/ranobehub_last_url.txt)") }
end

-- ── Extension ─────────────────────────────────────────────────────────────────

local ext = {
    id         = "ranobehub",
    name       = "RanobeHub",
    site       = BASE,
    lang       = "ru",
    version    = "0.7.0",
    -- Avis = commentaires du roman (API JSON /api/comments, voir parseReviews).
    maxReviews = 150,
    review_cache_rev = 4,
    popularFilters = POPULAR_FILTERS,
    searchFilters  = POPULAR_FILTERS,
}

function ext:popularNovels(page, options)
    return listing("", page, options)
end

function ext:searchNovels(term, page, options)
    return listing(term or "", page, options)
end

-- Relit les filtres sur le site (événements : liste complète, avec les nouveaux
-- identifiants éventuels) ; en cas d'échec, la liste intégrée reste utilisée.
function ext:loadFilters()
    local data = extract_result(http_get(BASE .. "/ranobe"))
    local f = data and data.facets
    if type(f) == "table" then
        local function refresh(group, list)
            if type(list) ~= "table" then return end
            local items = {}
            for _, e in ipairs(list) do
                local id = tonumber(e.id)
                local title = clean_label(e.title)
                if id and title ~= "" then
                    items[#items + 1] = { id = string.format("%d", id), label = title }
                end
            end
            if #items > 0 then group.options = multi_options(items) end
        end
        refresh(F_TAG, f.tags)
        refresh(F_EVENT, f.events)
        refresh(F_STATUS, f.statuses)
        refresh(F_COUNTRY, f.countries)
    end
    self.filters_ready = true
end

function ext:parseNovelMeta(path)
    local base_path = (path or ""):gsub("[%?#].*$", ""):gsub("/+$", "")
    local html, _, pc = get_novel_html(base_path)
    if not html then return nil end
    local meta = pc.meta or parse_meta(html)
    pc.meta = meta
    return {
        name           = meta.title,
        path           = path,
        cover          = meta.cover,
        summary        = meta.summary,
        status         = meta.status,
        total_chapters = meta.total or 0,
    }
end

local novel_memo = { path = nil, t = 0, res = nil }

function ext:parseNovel(path)
    local base_path = (path or ""):gsub("[%?#].*$", ""):gsub("/+$", "")
    -- Même fiche redemandée dans les 2 minutes (ouverture, actualisation) : on
    -- renvoie le résultat déjà construit au lieu de tout recalculer.
    if novel_memo.path == base_path and novel_memo.res and os.time() - novel_memo.t < 120 then
        return novel_memo.res
    end
    local html, vols, pc = get_novel_html(base_path, true)
    if not html then
        logger.err("RanobeHub: parseNovel fetch failed", path)
        return nil
    end
    local meta = pc.meta or parse_meta(html)
    pc.meta = meta
    if meta.title == "" then
        write_debug("Fiche illisible pour " .. base_path .. "\nTaille : " .. #html
            .. " octets\nDébut de la page :\n" .. html:sub(1, 3000))
        return nil
    end
    local chapters = build_chapters(html, base_path, meta, vols)
    if #chapters == 0 then
        logger.err("RanobeHub: aucun chapitre trouvé pour", path)
    end
    local res = {
        name       = meta.title,
        path       = path,
        cover      = meta.cover,
        summary    = meta.summary,
        genres     = meta.genres,
        status     = meta.status,
        chapters   = chapters,
        totalPages = 1,
    }
    if #chapters > 0 then novel_memo = { path = base_path, t = os.time(), res = res } end
    return res
end

function ext:parseChapter(path)
    local html = http_get(full_url(path))
    if not html then return T("<p>Impossible de récupérer ce chapitre.</p>") end

    -- Scripts/styles retirés AVANT de compter les <div> (un « <div> » dans une
    -- chaîne JavaScript fausserait l'équilibre des balises).
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")

    local content = extract_div(html, '<div[^>]-id="reader%-content%-%d+"')
    if not content then
        write_debug("Chapitre : texte introuvable pour " .. path
            .. "\nDébut de la page :\n" .. html:sub(1, 3000))
        return T("<p>Impossible d'extraire le contenu de ce chapitre.</p>")
    end

    content = content:gsub("<aside.-</aside>", "")            -- blocs publicitaires
    content = content:gsub("</?font[^>]*>", "")               -- balises ajoutées par un traducteur de navigateur
    content = content:gsub("</?div[^>]*>", "")                -- conteneurs : seuls les <p> comptent
    -- Illustrations : adresse directe vers l'image d'origine.
    content = content:gsub('(<img[^>]-src=")([^"]+)(")', function(a, u, c)
        return a .. (media_url(u) or u) .. c
    end)
    content = content:gsub("<p[^>]*>%s*</p>", "")             -- paragraphes vides
    content = content:gsub("^%s+", ""):gsub("%s+$", "")
    if content == "" then
        return T("<p>Impossible d'extraire le contenu de ce chapitre.</p>")
    end
    return content
end

-- ── Avis (commentaires du roman) ──────────────────────────────────────────────
-- API confirmée (captures DevTools) :
--   GET /api/comments?targetType=ranobe&targetId=<id>&sort=top|old&limit=30&rh_client=modern
--   GET /api/comments?...&parentId=<id du commentaire>&limit=100&sort=old   (réponses)
-- Réponse : { items = { {id, userName, text, score, replyCount, isDeleted, isSpoiler,
--   createdAt, avatarUrl, ...} }, total, rootTotal, nextCursor, nextScore }.
-- NON CONFIRMÉ : valeur de tri « new » (le plus récent) et noms des paramètres de page
-- suivante (cursor / score, valeurs nextCursor / nextScore). En cas d'échec, la réponse
-- est enregistrée dans sefirah/ranobehub_last_error.txt.
local REVIEW_PAGE_SIZE  = 30
local REVIEW_SORT_MAP   = { newest = "new", oldest = "old", mostliked = "top" }
local review_state      = {}     -- [novel_id|sort] = { cursor, score, seen = {id = true} }

local function review_text(t)
    t = tostring(t or "")
    t = t:gsub("<br[^>]*/?>%s*", "\n"):gsub("</p>%s*", "\n\n")
    t = strip_tags(t)
    return (t:gsub("\n\n\n+", "\n\n"):match("^%s*(.-)%s*$"))
end

local function comments_url(novel_id, sort, extra)
    local u = BASE .. "/api/comments?targetType=ranobe&targetId=" .. novel_id
        .. "&sort=" .. sort .. (extra or "") .. "&rh_client=modern"
    return u
end

-- Date : l'API peut renvoyer un texte ISO ou un timestamp (s ou ms) ; ui/detail.lua
-- attend « YYYY-MM-DD… » ou un nombre en secondes.
local function review_date(v)
    if type(v) == "number" then
        if v > 1e12 then v = v / 1000 end
        return math.floor(v)
    end
    if type(v) == "string" and v:match("^%d%d%d%d%-%d%d%-%d%d") then return v end
    local n = tonumber(v)
    if n then
        if n > 1e12 then n = n / 1000 end
        return math.floor(n)
    end
    return nil
end

local function comment_text(it)
    if type(it) ~= "table" or it.isDeleted then return nil end
    local content = review_text(it.text)
    if content == "" then return nil end
    if it.isSpoiler then content = "[Spoiler] " .. content end
    return content
end

local function comment_author(it)
    return (type(it.userName) == "string" and it.userName ~= "") and it.userName or "Anonyme"
end

-- Les réponses sont converties en avis distincts, jamais en texte ajouté au parent.
local function fetch_replies(novel_id, parent_id)
    local u = comments_url(novel_id, "old", "&parentId=" .. tostring(parent_id) .. "&limit=100")
    local ok, b = pcall(http_get, u, true)
    if not ok or not b then return nil end
    local d = json_decode(b)
    if not d or type(d.items) ~= "table" then return nil end
    return d.items
end

local function comment_to_review(it, novel_id, parent_id, depth, seen)
    if type(it) ~= "table" then return nil end
    depth, seen = depth or 0, seen or {}
    local id = it.id and tostring(it.id)
    if id and seen[id] then return nil end
    if id then seen[id] = true end
    local content = comment_text(it)
    if not content then return nil end
    local score = tonumber(it.score) or 0
    local avatar = type(it.avatarUrl) == "string" and it.avatarUrl ~= "" and abs_url(it.avatarUrl) or nil
    local review = {
        id       = it.id,
        author   = comment_author(it),
        content  = content,
        date     = review_date(it.createdAt),
        avatar   = avatar,
        likes    = score > 0 and score or 0,
        dislikes = score < 0 and -score or 0,
        parent_id = parent_id,
        depth = depth,
    }
    if (tonumber(it.replyCount) or 0) > 0 and id and depth < 20 then
        local replies = fetch_replies(novel_id, it.id)
        if replies then
            review.replies = {}
            for _, r in ipairs(replies) do
                local child = comment_to_review(r, novel_id, id, depth + 1, seen)
                if child then review.replies[#review.replies + 1] = child end
            end
        end
    end
    return review
end

function ext:parseReviews(path, page, sort)
    page = page or 1
    local novel_id = tostring(path or ""):match("/ranobe/(%d+)")
    if not novel_id then return { reviews = {}, has_more = false } end
    local api_sort = REVIEW_SORT_MAP[sort] or "top"
    local key = novel_id .. "|" .. api_sort
    if page == 1 then review_state[key] = { seen = {} } end
    local st = review_state[key]
    if not st then return { reviews = {}, has_more = false } end

    local extra = "&limit=" .. REVIEW_PAGE_SIZE
    if page > 1 then
        if st.cursor == nil and st.score == nil then return { reviews = {}, has_more = false } end
        if st.cursor ~= nil then extra = extra .. "&cursor=" .. url_encode(tostring(st.cursor)) end
        if st.score  ~= nil then extra = extra .. "&score="  .. url_encode(tostring(st.score)) end
    end

    -- Valeur du tri « récent » non confirmée : on essaie plusieurs noms, puis « top »
    -- (confirmé) en dernier recours ; celui qui répond est mémorisé pour la suite.
    local candidates = { api_sort }
    if sort == "newest" then
        candidates = { review_state.newest_ok or "new", "newest", "desc", "date", "top" }
    end
    local body, data, tried = nil, nil, {}
    for _, sv in ipairs(candidates) do
        local u = comments_url(novel_id, sv, extra)
        local b, code = http_get(u, true)
        tried[#tried + 1] = sv .. " -> " .. (b and (#b .. " octets") or ("échec " .. tostring(code)))
        local d = json_decode(b)
        if d and type(d.items) == "table" then
            body, data = b, d
            if sort == "newest" then review_state.newest_ok = sv end
            break
        end
        body = body or b
    end
    if not data then
        write_debug("Avis : réponse illisible pour " .. tostring(path)
            .. "\nEssais : " .. table.concat(tried, " ; ")
            .. "\nDébut de la réponse :\n" .. tostring(body):sub(1, 2000))
        return { reviews = {}, has_more = false, error = body and true or failure_message() }
    end
    if #data.items == 0 and page == 1 then
        write_debug("Avis : liste vide pour " .. tostring(path)
            .. "\nEssais : " .. table.concat(tried, " ; ")
            .. "\nRéponse :\n" .. tostring(body):sub(1, 1500))
    end

    local reviews = {}
    local new_count = 0
    for _, it in ipairs(data.items) do
        if it.id and not st.seen[it.id] then
            st.seen[it.id] = true
            new_count = new_count + 1
            local r = comment_to_review(it, novel_id)
            if r then
                reviews[#reviews + 1] = r
            end
        end
    end

    -- JSON null peut revenir sous forme de sentinelle (userdata) : on ne garde que texte/nombre.
    local function scalar(v) if type(v) == "string" or type(v) == "number" then return v end end
    st.cursor = scalar(data.nextCursor)
    st.score  = scalar(data.nextScore)
    -- new_count == 0 : le site a renvoyé la même page (paramètres de pagination ignorés).
    local has_more = (st.cursor ~= nil or st.score ~= nil) and new_count > 0
    return { reviews = reviews, has_more = has_more }
end

return ext
