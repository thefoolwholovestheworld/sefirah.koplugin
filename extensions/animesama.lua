-- Anime-Sama — source scans manga/manhwa/webtoon for Sefirah.
-- Le site est un catalogue HTML (rendu côté serveur) ; la liste des chapitres et
-- le nombre de pages viennent d'une petite API JSON du site.
-- Cette source ne gère volontairement PAS les épisodes/animes.
--
-- v0.2.0 : · si le site est bloqué par un filtre DNS (« Content blocked »), l'adresse
--            est résolue en DNS-over-HTTPS puis le site est joint directement
--            (core/dnsbypass.lua) — pages, listes ET images de chapitre ;
--          · recherche et pagination faites par le site (avant : la 1re page du
--            catalogue seulement, d'où « aucun manga » dès qu'un titre n'y était pas) ;
--          · chapitres : creerListe()/newSP() + API get_nb_chap_et_img.php.
--          Si le site change de domaine, modifier HOST ci-dessous.
local T = require("core.i18n").T
local DEFAULT_HOST = "anime-sama.to"
local PORTAL = "https://anime-sama.pw/"   -- page officielle qui indique le domaine actuel

-- Domaine choisi par l'utilisateur (Sources ▸ Anime-Sama ▸ ⚙ ▸ Adresse du site).
local function clean_host(h)
    h = tostring(h or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^%a+://", ""):gsub("/.*$", ""):gsub("^www%.", "")
    if h:match("^[%w%-]+%.[%w%.%-]+$") then return h:lower() end
    return nil
end
local function saved_host()
    local ok, Settings = pcall(require, "sefirah_settings")
    if not ok or not Settings then return nil end
    local ok2, v = pcall(function() return Settings:getExt("animesama", "host", nil) end)
    return ok2 and clean_host(v) or nil
end
local HOST = saved_host() or DEFAULT_HOST
local BASE = "https://" .. HOST
local UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

local ok_bp, Bypass = pcall(require, "core.dnsbypass")
if not ok_bp then Bypass = nil end
if Bypass then Bypass.register(HOST) end

-- ── Texte ────────────────────────────────────────────────────────────────────
local function utf8char(n)
    if not n then return "?" end
    if n < 128 then return string.char(n)
    elseif n < 2048 then return string.char(192 + math.floor(n / 64), 128 + (n % 64))
    elseif n < 65536 then
        return string.char(224 + math.floor(n / 4096), 128 + (math.floor(n / 64) % 64), 128 + (n % 64))
    end
    return string.char(240 + math.floor(n / 262144), 128 + (math.floor(n / 4096) % 64),
        128 + (math.floor(n / 64) % 64), 128 + (n % 64))
end
local function decode(s)
    s = tostring(s or "")
    s = s:gsub("&#[xX](%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8char(tonumber(d)) end)
    s = s:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&nbsp;", " "):gsub("&amp;", "&")
    return s
end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function strip(s)
    s = tostring(s or "")
    s = s:gsub("<script.-</script>", " "):gsub("<style.-</style>", " "):gsub("<[^>]+>", " ")
    s = decode(s)
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end
local function attr(tag, name)
    if not tag then return nil end
    local pat = name:gsub("%-", "%%-")
    return tag:match("%f[%w_%-]" .. pat .. '%s*=%s*"([^"]*)"')
        or tag:match("%f[%w_%-]" .. pat .. "%s*=%s*'([^']*)'")
end
local function enc(s)
    return (tostring(s or ""):gsub("([^%w%-%.%_%~])", function(c) return string.format("%%%02X", c:byte()) end))
end
local function abs(u)
    if not u or u == "" then return nil end
    u = decode(trim(u))
    if u:sub(1, 2) == "//" then return "https:" .. u end
    if u:sub(1, 1) == "/" then return BASE .. u end
    if not u:match("^%a+://") then return BASE .. "/" .. u end
    return u
end
local function slug_from_path(path)
    return tostring(path or ""):match("^/?([^/|]+)") or tostring(path or "")
end

-- ── Diagnostic (sefirah/animesama_last_error.txt) ────────────────────────────
local notes, state = {}, { blocked = false }
local function note(...)
    local p = {}
    for i = 1, select("#", ...) do p[#p + 1] = tostring((select(i, ...))) end
    notes[#notes + 1] = os.date("%H:%M:%S ") .. table.concat(p, " ")
    if #notes > 40 then table.remove(notes, 1) end
end

local function dump_error(label, body)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local f = io.open(dir .. "/animesama_last_error.txt", "wb")
        if f then
            f:write(tostring(label), "\n\n--- requêtes ---\n", table.concat(notes, "\n"))
            if Bypass then f:write("\n\n--- contournement DNS ---\n", Bypass.journal()) end
            f:write("\n\n--- début de la réponse ---\n", tostring(body or ""):sub(1, 4000))
            f:close()
        end
    end)
end

-- ── Réseau : accès direct, puis contournement DNS si bloqué ──────────────────
local function req_headers()
    return {
        ["User-Agent"] = UA,
        ["Accept"] = "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "fr-FR,fr;q=0.9,en;q=0.7",
        ["Referer"] = BASE .. "/",
    }
end

-- Raison pour laquelle une réponse n'est pas la vraie page (nil = utilisable).
local function unusable(body, kind)
    if type(body) ~= "string" or body == "" then return "vide" end
    if Bypass and Bypass.looks_blocked(body) then return "bloquée" end
    if kind ~= "json" and not body:lower():find("anime%-sama") then return "inattendue" end
    return nil
end

-- kind : "html" (défaut) ou "json". Renvoie body, ou nil, code.
local function fetch(url, kind)
    if url:sub(1, 1) == "/" then url = BASE .. url end
    local keep, code
    if not (Bypass and Bypass.is_active(url)) then
        local body, c = require("core.net").get(url, { headers = req_headers(), timeout = 20 })
        code = c
        local why = body and unusable(body, kind)
        if body and not why then return body end
        if why == "bloquée" then state.blocked = true end
        if why == "inattendue" then keep = body end
        note("direct", url, "code=" .. tostring(c), why or "pas de réponse")
        -- 404, 500… : le site répond, ce n'est pas un blocage réseau.
        if body == nil and type(c) == "number" and c ~= 403 then return nil, c end
    end
    if Bypass then
        local body, c = Bypass.get(url, { headers = req_headers(), timeout = 15, deadline = 45 })
        if body then
            local why = unusable(body, kind)
            if not why then Bypass.set_active(url, true); return body end
            if why == "bloquée" then state.blocked = true end
            if why == "inattendue" and not keep then keep = body end
            note("contournement", url, why)
        else
            note("contournement", url, "échec :", tostring(c))
            code = code or c
        end
    end
    if keep then return keep end
    return nil, code
end

local function failure_message()
    if state.blocked then
        return T("Anime-Sama est bloqué sur ce réseau (filtre DNS) et le contournement n'a pas abouti. Voir sefirah/animesama_last_error.txt")
    end
    return T("Anime-Sama est injoignable depuis la liseuse. Voir sefirah/animesama_last_error.txt")
end

-- ── Catalogue ────────────────────────────────────────────────────────────────
local function fold(s)
    s = tostring(s or ""):lower()
    local map = { ["é"]="e", ["è"]="e", ["ê"]="e", ["ë"]="e", ["à"]="a", ["â"]="a", ["ä"]="a",
        ["ç"]="c", ["î"]="i", ["ï"]="i", ["ô"]="o", ["ö"]="o", ["ù"]="u", ["û"]="u", ["ü"]="u" }
    return (s:gsub("[\192-\255][\128-\191]+", function(c) return map[c] or c end))
end

local function fallback_title(slug)
    local title = tostring(slug or ""):gsub("%-", " ")
    return (title:gsub("%S+", function(w) return w:sub(1, 1):upper() .. w:sub(2) end))
end

-- Une fiche = <div class="card"> : <a href="/catalogue/<slug>"><img></a>, puis
-- h2.card-title et p.info-value (types : « Anime, Scans »…) À CÔTÉ du lien, pas dedans.
-- On lit donc la « fenêtre » qui va du lien jusqu'au lien de la fiche suivante.
local function parse_cards(html, filtered_scans)
    local out, by_slug = {}, {}
    if type(html) ~= "string" or html == "" then return out end

    local anchors, pos = {}, 1
    while true do
        local s, e = html:find("<a%s[^>]-href%s*=%s*[^>]->", pos)
        if not s then break end
        local tag = html:sub(s, e)
        local href = attr(tag, "href")
        local slug = href and href:match("/catalogue/([^/%?#\"']+)")
        if slug and slug ~= "" then
            anchors[#anchors + 1] = { s = s, e = e, href = href, slug = slug }
        end
        pos = e + 1
    end

    for i, a in ipairs(anchors) do
        local prev = anchors[i - 1]
        if not (prev and prev.slug == a.slug) then       -- 1er lien de la fiche
            local j = i + 1
            while anchors[j] and anchors[j].slug == a.slug do j = j + 1 end
            local wend = anchors[j] and (anchors[j].s - 1) or #html
            wend = math.min(wend, a.s + 3000)
            local win = html:sub(a.s, wend)

            local types = {}
            for inner in win:gmatch('<p[^>]-class="[^"]*info%-value[^"]*"[^>]*>(.-)</p>') do
                local t = strip(inner)
                if t ~= "" then types[#types + 1] = t end
            end
            local types_txt = table.concat(types, ", ")
            local is_scan = types_txt ~= "" and fold(types_txt):find("scan", 1, true) ~= nil
            local keep
            if types_txt ~= "" then
                keep = is_scan                      -- type connu : « Scans » obligatoire
            else
                keep = filtered_scans == true or a.href:lower():find("/scan/", 1, true) ~= nil
            end

            if keep then
                local h2 = win:match('<h2[^>]-class=["\'][^"\']*card%-title[^"\']*["\'][^>]*>(.-)</h2>')
                local cover, image_title
                for img in win:gmatch("<img[^>]->") do
                    local src = attr(img, "data-src") or attr(img, "data-lazy-src") or attr(img, "src")
                    if src and not src:lower():find("flag_", 1, true) then
                        cover = src
                        image_title = strip(attr(img, "alt") or attr(img, "title") or "")
                        break
                    end
                end
                local title = strip(h2 or "")
                if title == "" then title = image_title or "" end
                if title == "" then title = fallback_title(a.slug) end
                if not by_slug[a.slug] then
                    local entry = { name = title, path = a.slug, cover = abs(cover) }
                    by_slug[a.slug] = entry
                    out[#out + 1] = entry
                end
            end
        end
    end
    return out
end

-- Filtres (statut = un seul choix ; genres = sélection multiple, combinés par le site).
local function filters_of(options)
    local f = (options and options.filters) or {}
    local status = f.status
    if status ~= "En cours" and status ~= "Terminé" then status = "" end
    local genres = {}
    for g in tostring(f.genre or ""):gmatch("[^,]+") do genres[#genres + 1] = g end
    return status, genres
end

local seen_by_term = {}   -- slugs déjà renvoyés pour une recherche (le site répète les mêmes fiches)

local function listing_raw(term, page, options)
    page = tonumber(page) or 1
    term = trim(term)
    local status, genres = filters_of(options)
    local skey = term .. "|" .. status .. "|" .. table.concat(genres, ",")
    if page <= 1 then seen_by_term[skey] = {} end
    local seen = seen_by_term[skey]
    if not seen then seen = {}; seen_by_term[skey] = seen end
    local cur = status ~= "" and ("&current%5B%5D=" .. enc(status)) or ""
    local gq = {}
    for _, g in ipairs(genres) do gq[#gq + 1] = "&genre%5B%5D=" .. enc(g) end
    local path = "/catalogue/?type%5B%5D=Scans" .. cur
        .. "&annee_min=&annee_max=&episodes_min=&episodes_max=&chapitres_min=&chapitres_max="
        .. table.concat(gq) .. "&search=" .. enc(term) .. "&page=" .. page
    local html = fetch(path, "html")
    if not html then
        dump_error("catalogue inaccessible : " .. path, "")
        return { novels = {}, error = failure_message() }
    end
    local all = parse_cards(html, true)
    local novels = {}
    for _, n in ipairs(all) do
        if not seen[n.path] then seen[n.path] = true; novels[#novels + 1] = n end
    end
    if term ~= "" and #novels > 1 then
        -- Pertinence : titre identique, puis titre qui commence par la recherche, puis qui la contient.
        local q = fold(term)
        local function score(n)
            local t = fold(n.name)
            if t == q then return 0 end
            if t:sub(1, #q) == q then return 1 end
            if t:find(q, 1, true) then return 2 end
            return 3
        end
        for i, n in ipairs(novels) do n._i = i; n._s = score(n) end
        table.sort(novels, function(a, b)
            if a._s ~= b._s then return a._s < b._s end
            return a._i < b._i
        end)
    end
    if #novels == 0 and #all > 0 then
        -- Le site renvoie les mêmes fiches au-delà de la dernière page : fin de liste.
        return { novels = {} }
    end
    if #novels == 0 then
        -- Page vide : fin de liste (page > 1) ou recherche sans résultat — pas une erreur,
        -- tant que la page est bien un catalogue.
        if html:find("list_catalog", 1, true) or page > 1 then return { novels = {} } end
        dump_error("aucune fiche reconnue dans le catalogue : " .. path, html)
        return { novels = {}, error = T("Anime-Sama : aucune fiche de manga/manhwa/webtoon reconnue. Voir sefirah/animesama_last_error.txt") }
    end
    return { novels = novels }
end

-- ── Fiche d'une œuvre ────────────────────────────────────────────────────────
local function text_by_id(html, id, first_node, keep_edges)
    local s = html:find('id="' .. id .. '"', 1, true) or html:find("id='" .. id .. "'", 1, true)
    if not s then return nil end
    local gt = html:find(">", s, true)
    if not gt then return nil end
    local close = html:find("</", gt + 1, true)
    local inner = close and html:sub(gt + 1, close - 1) or html:sub(gt + 1, gt + 600)
    if first_node then inner = inner:match("^%s*([^<]*)") or inner end
    if keep_edges then
        -- Titre brut : le site garde des espaces finaux (« Naruto␣␣ ») qui font partie de la clé de l'API.
        local raw = decode(inner:gsub("<[^>]+>", ""):gsub("[\r\n\t]", " "))
        raw = raw:gsub("^%s+", "")
        return raw ~= "" and raw or nil
    end
    local t = strip(inner)
    return t ~= "" and t or nil
end

local function info_value(html, label)
    local items = {}
    for inner in html:gmatch("<span[^>]*>(.-)</span>") do items[#items + 1] = strip(inner) end
    for i = 1, #items - 1 do
        if items[i] == label and items[i + 1] ~= "" and items[i + 1] ~= label then return items[i + 1] end
    end
    return nil
end

-- Clés sans accents : on les compare à fold(texte du site).
local STATUS_MAP = { ["termine"] = "Completed", ["en cours"] = "Ongoing", ["en pause"] = "Hiatus",
    ["abandonne"] = "Cancelled", ["annule"] = "Cancelled" }

local function parse_genres(html)
    local out, seen = {}, {}
    for inner in html:gmatch('<span[^>]-class="[^"]*genre%-pill[^"]*"[^>]*>(.-)</span>') do
        local g = strip(inner)
        if g ~= "" and not seen[g] then seen[g] = true; out[#out + 1] = g end
    end
    return out
end

local function parse_fiche(html, slug)
    local title = strip(html:match("<h1[^>]*>(.-)</h1>") or "")
    if title == "" then title = text_by_id(html, "titreOeuvre", true) or "" end
    if title == "" then
        title = strip(html:match('<meta property=["\']og:title["\'] content=["\']([^"\']+)') or "")
    end
    if title == "" then title = fallback_title(slug) end
    -- Même vignette (portrait) que dans la liste du catalogue ; l'image de la fiche
    -- est une bannière large, qui laissait du vide dans l'écran de détails.
    local cover = "https://cdn.jsdelivr.net/gh/Anime-Sama/IMG@img/contenu/thumb/" .. enc(slug) .. ".webp"
    local summary = text_by_id(html, "synopsisText") or ""
    local etat = info_value(html, "État")
    return {
        name = title, path = slug, cover = abs(cover),
        summary = summary ~= "" and summary or T("Scans disponibles selon les versions proposées par Anime-Sama."),
        author = info_value(html, "Créateur") or info_value(html, "Auteur"),
        status = (etat and STATUS_MAP[fold(etat)]) or "Unknown",
        genres = parse_genres(html),
        type = "manga",
    }
end

-- panneauScan("Scans", "scan/vf") ; l'URL « va » (sans « scan ») = version animée → ignorée.
local function scan_panels(html)
    local out = {}
    for name, url in html:gmatch('panneauScan%(%s*"([^"]+)"%s*,%s*"([^"]+)"%s*%)') do
        local u = url:gsub("^/", ""):gsub("/$", "")
        if u:match("^scan") then out[#out + 1] = { name = name, url = u } end
    end
    table.sort(out, function(a, b)
        local av, bv = a.url:find("vf", 1, true) and 0 or 1, b.url:find("vf", 1, true) and 0 or 1
        return av < bv
    end)
    return out
end

-- ── Chapitres : page de scans + API JSON ─────────────────────────────────────
local ok_json, JSON = pcall(require, "rapidjson")
if not ok_json then ok_json, JSON = pcall(require, "json") end

local counts_cache, panel_cache, work_titles = {}, {}, {}

local function parse_counts(body)
    local err = body:match('"error"%s*:%s*"([^"]*)"')
    if err then return nil, err end
    local map = {}
    if ok_json and JSON and JSON.decode then
        local pok, decoded = pcall(JSON.decode, body)
        if pok and type(decoded) == "table" then
            for k, v in pairs(decoded) do
                local n = tonumber(v)
                if n then map[tostring(k)] = n end
            end
            if next(map) then return map end
        end
    end
    for k, v in body:gmatch('"([^"]+)"%s*:%s*(%d+)') do map[k] = tonumber(v) end
    if not next(map) then return nil, "réponse vide" end
    return map
end

local function fetch_counts(oeuvre)
    local c = counts_cache[oeuvre]
    if c and os.time() - c.t < 1800 then return c.map end
    local body = fetch("/s2/scans/get_nb_chap_et_img.php?oeuvre=" .. enc(oeuvre), "json")
    if not body then return nil, "api inaccessible" end
    local map, err = parse_counts(body)
    if not map then note("API", oeuvre, tostring(err)); return nil, err end
    counts_cache[oeuvre] = { t = os.time(), map = map }
    return map
end

-- Titre exact de l'œuvre (clé de l'API) : #titreOeuvre, parfois sur la fiche principale
-- vers laquelle pointe le lien de l'image grisée.
local function resolve_work_title(html)
    for anchor in html:gmatch("(<a%s+[^>]*>.-</a>)") do
        if anchor:find("imgOeuvre", 1, true) and anchor:find("grayscale", 1, true) then
            local href = attr(anchor:match("<a%s+[^>]*>") or "", "href")
            if href then
                local page = fetch(abs(href), "html")
                local t = page and text_by_id(page, "titreOeuvre", true, true)
                if t then return t end
            end
        end
    end
    return text_by_id(html, "titreOeuvre", true, true)
end

-- Essaie le titre brut puis ses variantes (avec/sans espaces finaux) jusqu'à ce que l'API réponde.
local function counts_for(info)
    if not info.oeuvre then return nil end
    if info.counts_ok then return fetch_counts(info.oeuvre) end
    local base = trim(info.oeuvre)
    local cands, seen = { info.oeuvre, base, base .. "  ", base .. " " }, {}
    for _, c in ipairs(cands) do
        if c ~= "" and not seen[c] then
            seen[c] = true
            local map = fetch_counts(c)
            if map then info.oeuvre = c; info.counts_ok = true; return map end
        end
    end
    return nil
end

local function load_panel(slug, panel)
    local key = slug .. "|" .. panel
    if panel_cache[key] then return panel_cache[key] end
    local html = fetch("/catalogue/" .. slug .. "/" .. panel .. "/", "html")
    if not html then return nil end
    local ext_img = html:match("/s2/scans/[^\"']-/%d+/%d+%.(%a+)")
    ext_img = ext_img and ext_img:lower() or "jpg"
    if not ({ jpg = 1, jpeg = 1, png = 1, webp = 1, gif = 1 })[ext_img] then ext_img = "jpg" end
    -- Le titre exact de l'œuvre est le même pour tous les panneaux d'une fiche : on évite
    -- de re-télécharger la fiche principale à chaque panneau.
    local title = work_titles[slug] or resolve_work_title(html)
    if title then work_titles[slug] = title end
    local info = { html = html, oeuvre = title, img_ext = ext_img }
    panel_cache[key] = info
    return info
end

-- Suite des chapitres : creerListe(a,b), newSP("Spécial") ou newSP(12.5) dans le HTML.
local function chapter_labels(html, total)
    local seq, delay, pos = {}, 0, 1
    while true do
        local s1, e1, a, b = html:find("creerListe%(%s*(%d+)%s*,%s*(%d+)%)", pos)
        local s2, e2, nm = html:find('newSP%(%s*"([^"]+)"%s*%)', pos)
        local s3, e3, nu = html:find("newSP%(%s*([%d%.]+)%s*%)", pos)
        local first = math.huge
        for _, v in ipairs({ s1 or math.huge, s2 or math.huge, s3 or math.huge }) do
            if v < first then first = v end
        end
        if first == math.huge then break end
        if s1 and first == s1 then
            for i = tonumber(a), tonumber(b) do seq[#seq + 1] = tostring(i) end
            pos = e1 + 1
        elseif s2 and first == s2 then
            seq[#seq + 1] = nm; delay = delay + 1; pos = e2 + 1
        else
            seq[#seq + 1] = nu; delay = delay + 1; pos = e3 + 1
        end
    end
    while #seq < total do seq[#seq + 1] = tostring(#seq + 1 - delay) end
    return seq
end

local function chapters_for(slug, panel)
    local info = load_panel(slug, panel)
    if not info then return {} end
    local out = {}
    local counts
    counts = counts_for(info)
    if counts then
        local total = 0
        for _ in pairs(counts) do total = total + 1 end
        local labels = chapter_labels(info.html, total)
        for idx = 1, math.min(#labels, total) do
            local label = labels[idx]
            out[#out + 1] = { name = "Chapitre " .. label, path = slug .. "|" .. panel .. "|" .. idx,
                chapter_number = tonumber(label) or idx }
        end
        return out
    end
    -- Repli : liste déroulante des chapitres présente dans le HTML.
    local select = info.html:match('<select[^>]-id=["\']selectChapitres["\'][^>]*>(.-)</select>') or ""
    local idx = 0
    for label in select:gmatch("<option[^>]*>(.-)</option>") do
        idx = idx + 1
        label = strip(label)
        if label ~= "" then
            out[#out + 1] = { name = label, path = slug .. "|" .. panel .. "|" .. idx,
                chapter_number = tonumber(label:match("(%d+%.?%d*)")) or idx }
        end
    end
    return out
end

-- ── Filtres du navigateur ────────────────────────────────────────────────────
local GENRES = {
    "Action",
    "Adolescence",
    "Aliens / Extra-terrestres",
    "Amitié",
    "Amour",
    "Apocalypse",
    "Art",
    "Arts martiaux",
    "Assassinat",
    "Autre monde",
    "Aventure",
    "Combats",
    "Comédie",
    "Crime",
    "Cyberpunk",
    "Danse",
    "Démons",
    "Détective",
    "Donghua",
    "Dragon",
    "Drame",
    "Ecchi",
    "Ecole",
    "Elfe",
    "Enquête",
    "Famille",
    "Fantastique",
    "Fantasy",
    "Fantômes",
    "Futur",
    "Gastronomie",
    "Ghibli",
    "Guerre",
    "Harcèlement",
    "Harem",
    "Harem inversé",
    "Histoire",
    "Historique",
    "Homosexualité",
    "Horreur",
    "Isekai",
    "Jeunesse",
    "Jeux",
    "Jeux vidéo",
    "Josei",
    "Journalisme",
    "Kaï",
    "LGBT+",
    "Mafia",
    "Magical girl",
    "Magie",
    "Maladie",
    "Mariage",
    "Mature",
    "Mechas",
    "Médiéval",
    "Militaire",
    "Monde virtuel",
    "Monstres",
    "Musique",
    "Mystère",
    "Nekketsu",
    "Ninjas",
    "Nostalgie",
    "Paranormal",
    "Philosophie",
    "Pirates",
    "Police",
    "Politique",
    "Post-apocalyptique",
    "Pouvoirs psychiques",
    "Préhistoire",
    "Prison",
    "Psychologique",
    "Quotidien",
    "Religion",
    "Réincarnation / Transmigration",
    "Romance",
    "Samouraïs",
    "School Life",
    "Science-Fantasy",
    "Science-fiction",
    "Scientifique",
    "Seinen",
    "Shôjo",
    "Shôjo-Ai",
    "Shônen",
    "Shônen-Ai",
    "Slice of Life",
    "Société",
    "Sport",
    "Super pouvoirs",
    "Super-héros",
    "Surnaturel",
    "Survie",
    "Survival game",
    "Technologies",
    "Thriller",
    "Tournois",
    "Travail",
    "Vampires",
    "Vengeance",
    "Voyage",
    "Voyage temporel",
    "Webcomic",
    "Yakuza",
    "Yaoi",
    "Yokai",
    "Yuri",
}

local function genre_options(list)
    local o = { { id = "", label = T("Tous") } }
    for _, g in ipairs(list) do o[#o + 1] = { id = g, label = g } end
    return o
end

local STATUS_FILTER = {
    key = "status", label = T("Statut"), default = "",
    options = {
        { id = "",         label = T("Tous") },
        { id = "En cours", label = T("En cours") },
        { id = "Terminé",  label = T("Terminé") },
    },
}
local GENRE_FILTER = { key = "genre", label = T("Genre"), default = "", multi = true, options = genre_options(GENRES) }

-- ── Fiches sans scans ────────────────────────────────────────────────────────
-- Le catalogue « Scans » contient des fiches (ex. 07 Ghost) dont la page n'a AUCUN
-- chapitre de scan (seulement l'anime). On les masque : chaque fiche inconnue est
-- vérifiée en parallèle (sous-processus), puis le verdict est mémorisé sur disque.
-- Verdict incertain (réseau, erreur) → la fiche reste affichée.
local HIDE_EMPTY       = true
local VERDICT_TTL_NO   = 3 * 86400     -- « sans scans » : revérifié après 3 jours
local VERDICT_TTL_YES  = 30 * 86400
local CHECK_BATCH      = 10            -- vérifications simultanées

local function verdict_dir()
    local ok, dir = pcall(function()
        local DataStorage = require("datastorage")
        local d = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then
            pcall(lfs.mkdir, d)
            d = d .. "/animesama_scans"
            pcall(lfs.mkdir, d)
        end
        return d
    end)
    return ok and dir or nil
end

local function safe_slug(slug) return (tostring(slug):gsub("[^%w%-%._]", "_")) end

-- true = a des scans, false = aucun, nil = inconnu / périmé.
local function read_verdict(dir, slug)
    local f = io.open(dir .. "/" .. safe_slug(slug) .. ".txt", "rb")
    if not f then return nil end
    local raw = f:read("*a") or ""
    f:close()
    local ts, v = raw:match("^(%d+)%s+([01])")
    if not ts then return nil end
    local age = os.time() - tonumber(ts)
    if v == "1" then
        if age < VERDICT_TTL_YES then return true end
        return nil
    end
    if age < VERDICT_TTL_NO then return false end
    return nil
end

local function write_verdict(dir, slug, has)
    local f = io.open(dir .. "/" .. safe_slug(slug) .. ".txt", "wb")
    if f then f:write(os.time(), " ", has and "1" or "0"); f:close() end
end

-- Contrôle d'UNE fiche. Renvoie true / false / nil (incertain).
local function check_has_scans(slug)
    local html, code = fetch("/catalogue/" .. slug .. "/", "html")
    if not html then return (code == 404) and false or nil end
    if #scan_panels(html) > 0 then return true end
    -- Pas de panneau de scan annoncé : on regarde quand même les pages de lecture directes.
    local answered = 0   -- pages de lecture qui ont répondu (200 ou 404) : verdict fiable
    for _, panel in ipairs({ "scan/vf", "scan/va" }) do
        local ph, pcode = fetch("/catalogue/" .. slug .. "/" .. panel .. "/", "html")
        if ph then
            answered = answered + 1
            local sel = ph:match('<select[^>]-id=["\']selectChapitres["\'][^>]*>(.-)</select>') or ""
            if ph:find("creerListe%(") or ph:find("newSP%(") or sel:find("<option", 1, true) then
                return true
            end
        elseif pcode == 404 then
            answered = answered + 1
        end
    end
    if answered == 2 then return false end
    return nil
end

local function filter_empty(novels)
    if not HIDE_EMPTY or #novels == 0 then return novels end
    local dir = verdict_dir()
    if not dir then return novels end

    local verdict, unknown = {}, {}
    for _, n in ipairs(novels) do
        local v = read_verdict(dir, n.path)
        if v == nil then unknown[#unknown + 1] = n else verdict[n.path] = v end
    end

    if #unknown > 0 then
        local ok_p, Parallel = pcall(require, "core.parallel")
        if ok_p and Parallel.available() then
            local i = 1
            while i <= #unknown do
                local jobs = {}
                for k = i, math.min(i + CHECK_BATCH - 1, #unknown) do
                    local slug = unknown[k].path
                    jobs[#jobs + 1] = function()
                        local has = check_has_scans(slug)
                        if has ~= nil then write_verdict(dir, slug, has) end
                    end
                end
                Parallel.runAndWait(jobs, 30)
                i = i + CHECK_BATCH
            end
        else
            -- Pas de sous-processus : on ne vérifie que les 4 premières (sinon trop lent).
            for k = 1, math.min(4, #unknown) do
                local has = check_has_scans(unknown[k].path)
                if has ~= nil then write_verdict(dir, unknown[k].path, has) end
            end
        end
        for _, n in ipairs(unknown) do verdict[n.path] = read_verdict(dir, n.path) end
    end

    local out = {}
    for _, n in ipairs(novels) do
        if verdict[n.path] ~= false then out[#out + 1] = n end   -- false = confirmé sans scans
    end
    return out
end

-- Décalage de pages : si une page du site ne contient QUE des fiches sans scans, on passe
-- aux pages suivantes ici (sinon le navigateur croirait la liste terminée).
local page_shift = {}

local function listing(term, page, options)
    page = tonumber(page) or 1
    local status, genres = filters_of(options)
    local skey = trim(term) .. "|" .. status .. "|" .. table.concat(genres, ",")
    if page <= 1 then page_shift[skey] = 0 end
    local shift = page_shift[skey] or 0
    local res
    for _ = 0, 4 do
        res = listing_raw(term, page + shift, options)
        if res.error or not res.novels or #res.novels == 0 then return res end
        local kept = filter_empty(res.novels)
        if #kept > 0 then
            res.novels = kept
            page_shift[skey] = shift
            return res
        end
        shift = shift + 1        -- toute la page est sans scans : page suivante du site
    end
    page_shift[skey] = shift
    return { novels = {} }
end

-- ── Contrat de l'extension ───────────────────────────────────────────────────
local ext = {
    id = "animesama", name = "Anime-Sama", site = BASE, lang = "fr",
    version = "0.4.0", type = "manga", refreshCover = true, centerCover = true, gridFill = true, hasReviews = false, chapterCommentsPanel = false,
    popularFilters = { STATUS_FILTER, GENRE_FILTER },
    searchFilters = { STATUS_FILTER, GENRE_FILTER },
}
-- ── Adresse du site (menu des réglages) ──────────────────────────────────────
function ext:setHost(h)
    h = clean_host(h)
    if not h then return false end
    HOST = h
    BASE = "https://" .. HOST
    self.site = BASE
    if Bypass then Bypass.register(HOST) end
    state.blocked = false
    pcall(function() require("sefirah_settings"):setExt("animesama", "host", HOST) end)
    return true
end

-- Lit la page officielle anime-sama.pw (le bouton « Accéder à Anime-Sama » donne le domaine).
-- Si la page est injoignable, essaie les domaines connus un par un.
local function portal_get(url)
    local body, c = require("core.net").get(url, { headers = req_headers(), timeout = 20 })
    local blocked = body and Bypass and Bypass.looks_blocked(body)
    if body and body ~= "" and not blocked then return body end
    note("portail direct", url, "code=" .. tostring(c), blocked and "bloqué" or "pas de réponse")
    if Bypass then
        Bypass.register(url)
        local b2, c2 = Bypass.get(url, { headers = req_headers(), timeout = 15, deadline = 45 })
        if b2 and b2 ~= "" and not Bypass.looks_blocked(b2) then return b2 end
        note("portail contournement", url, "échec :", tostring(c2))
        c = c or c2
    end
    return nil, c
end

function ext:detectHost()
    local body, code = portal_get(PORTAL)
    if not body then body = portal_get("https://anime-sama.pw") end
    -- Le tableau du portail est rempli par ?check=<domaine> (JSON). Le domaine principal est
    -- celui dont le statut est « online » ; les autres (.si, .tv, .org) ne font que rediriger.
    if body then
        for _, cand in ipairs({ "anime-sama.to", "anime-sama.si", "anime-sama.tv", "anime-sama.org" }) do
            local j = portal_get(PORTAL .. "?check=" .. cand)
            if j and j:find('"status"%s*:%s*"online"') then return cand end
        end
    end
    if body then
        local href = body:match('class="btn%-primary"[^>]-href="([^"]+)"')
            or body:match('href="([^"]+)"[^>]-class="btn%-primary"')
        local h = href and clean_host(href)
        if h then return h end
        note("portail : bouton officiel introuvable")
    end
    -- Plan B : on teste les domaines connus (le premier qui répond comme Anime-Sama).
    for _, cand in ipairs({ "anime-sama.to", "anime-sama.si", "anime-sama.tv", "anime-sama.org" }) do
        local page = portal_get("https://" .. cand .. "/")
        if page and page:find("anime", 1, true) and page:find("catalogue", 1, true) then return cand end
    end
    dump_error("détection de l'adresse : portail et domaines connus injoignables (code=" .. tostring(code) .. ")", "")
    local why = tostring(code or "réseau")
    if why:find("not known", 1, true) or why:find("not provided", 1, true) then
        return nil, T("Aucune résolution DNS : vérifie le Wi-Fi/internet de la liseuse, ou saisis l'adresse à la main.")
    end
    return nil, T("Page officielle inaccessible") .. " (" .. why .. ")"
end

-- Lignes ajoutées au panneau ⚙ de la source (Sources ▸ Anime-Sama).
function ext:settingsRows(ctx)
    local P = require("ui.panel")
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local InputDialog = require("ui/widget/inputdialog")
    local self_ = self

    local function apply(h)
        if self_:setHost(h) then
            pcall(function() require("core.extmgr").refreshSite("animesama", BASE) end)
            UIManager:show(InfoMessage:new{ text = T("Adresse enregistrée : ") .. BASE, timeout = 3 })
            ctx.reopen()
        else
            UIManager:show(InfoMessage:new{ text = T("Adresse invalide (ex. anime-sama.to)") })
        end
    end

    return {
        P.makeRow(T("Adresse du site : ") .. HOST, { callback = function()
            local dlg
            dlg = InputDialog:new{
                title = T("Adresse d'Anime-Sama"),
                input = HOST,
                input_hint = "anime-sama.to",
                buttons = {{
                    { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
                    { text = T("Enregistrer"), is_enter_default = true, callback = function()
                        local v = dlg:getInputText()
                        UIManager:close(dlg)
                        apply(v)
                    end },
                }},
            }
            UIManager:show(dlg)
            dlg:onShowKeyboard()
        end }),
        P.makeRow(T("Trouver l'adresse officielle (anime-sama.pw)"), { callback = function()
            UIManager:show(InfoMessage:new{ text = T("Recherche de l'adresse officielle…"), timeout = 1 })
            UIManager:scheduleIn(0.3, function()
                local h, err = self_:detectHost()
                if h then apply(h)
                else UIManager:show(InfoMessage:new{ text = err or T("Échec") }) end
            end)
        end }),
        P.makeRow(T("Rétablir l'adresse par défaut (") .. DEFAULT_HOST .. ")", { callback = function()
            apply(DEFAULT_HOST)
        end }),
    }
end

function ext:searchNovels(term, page, options) return listing(term, page, options) end
function ext:popularNovels(page, options) return listing("", page, options) end

-- Relit la liste des genres sur le site ; en cas d'échec, la liste intégrée reste utilisée.
function ext:loadFilters()
    local html = fetch("/catalogue/", "html")
    if html then
        local list, seen = {}, {}
        for raw in html:gmatch('name="genre%[%]"%s*value="([^"]+)"') do
            local v = trim(decode(raw))
            if v ~= "" and not seen[v] then seen[v] = true; list[#list + 1] = v end
        end
        if #list > 10 then GENRE_FILTER.options = genre_options(list) end
    end
    self.filters_ready = true
end

function ext:parseNovelMeta(path)
    local slug = slug_from_path(path)
    local html = fetch("/catalogue/" .. slug .. "/", "html")
    if not html then dump_error("fiche inaccessible : " .. slug, ""); return nil end
    local m = parse_fiche(html, slug)
    m.total_chapters = 0
    return m
end

function ext:parseNovel(path)
    local slug = slug_from_path(path)
    local html = fetch("/catalogue/" .. slug .. "/", "html")
    if not html then dump_error("fiche inaccessible : " .. slug, ""); return nil end
    local m = parse_fiche(html, slug)

    local panels = scan_panels(html)
    if #panels == 0 then panels = { { name = "Scans", url = "scan/vf" }, { name = "Scans", url = "scan/va" } } end
    local chapters = {}
    for _, p in ipairs(panels) do
        chapters = chapters_for(slug, p.url)
        if #chapters > 0 then break end
    end
    if #chapters == 0 then
        dump_error("aucun chapitre pour " .. slug, html)
        m.summary = T("⚠ Anime-Sama : aucune liste de chapitres de scan détectée.") .. "\n\n" .. (m.summary or "")
    end
    m.chapters = chapters
    m.totalPages = 1
    return m
end

function ext:parseChapterImages(path)
    local slug, panel, idx = tostring(path or ""):match("^([^|]+)|([^|]+)|(%d+)$")
    if not slug then return nil, "invalid_chapter_path" end
    if not panel:find("/", 1, true) then panel = "scan/" .. panel end   -- anciens chemins « slug|vf|N »
    local info = load_panel(slug, panel)
    if not info then
        dump_error("page de lecture inaccessible : " .. slug .. "/" .. panel, "")
        return nil, failure_message()
    end

    local images = {}
    if info.oeuvre then
        local counts = counts_for(info)
        local n = counts and counts[idx]
        if n and n > 0 then
            local base = BASE .. "/s2/scans/" .. enc(info.oeuvre) .. "/" .. idx .. "/"
            for i = 1, n do images[i] = base .. i .. "." .. info.img_ext end
        end
    end
    if #images == 0 then
        -- Dernier recours : images déjà présentes dans le HTML (souvent le chapitre 1 seulement).
        local seen = {}
        for tag in info.html:gmatch("<img[^>]->") do
            local src = attr(tag, "src") or attr(tag, "data-src")
            if src and src:find("/s2/scans/", 1, true)
                and src:match("/scans/.-/(%d+)/%d+%.%w+") == idx then
                src = abs(src)
                if not seen[src] then seen[src] = true; images[#images + 1] = src end
            end
        end
        table.sort(images, function(a, b)
            return (tonumber(a:match("/(%d+)%.%w+$")) or 0) < (tonumber(b:match("/(%d+)%.%w+$")) or 0)
        end)
    end
    if #images == 0 then
        dump_error("aucune page pour " .. tostring(path), info.html)
        return nil, T("Anime-Sama : pages du chapitre introuvables (API du site). Voir sefirah/animesama_last_error.txt")
    end
    return { images = images, headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, batch = true }
end

function ext:parseChapter(path)
    return "<p>" .. T("Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.") .. "</p>"
end

ext._test = { parse_cards = parse_cards, parse_fiche = parse_fiche, scan_panels = scan_panels,
    chapter_labels = chapter_labels, parse_counts = parse_counts }

return ext
