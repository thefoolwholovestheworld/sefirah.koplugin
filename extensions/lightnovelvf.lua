-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- lightnovelvf.lua
-- Extension Sefirah pour https://www.lightnovelvf.com (light novels en français).
--
-- Site Laravel rendu côté serveur : tout se lit dans le HTML, pas d'API JSON
-- connue. Structure relevée sur du vrai HTML (2026-10-05) :
--   * Fiche roman  : /novel/<slug>
--       h1[itemprop="name headline"]  titre
--       img[itemprop="image"]         couverture (/uploads/novel/<slug>/cover/<slug>.jpg)
--       a[itemprop="genre"]           genres (certains sont vides)
--       <b class="text-white">N</b> chapitres   nombre de chapitres
--       <span class="text-xs font-semibold px-2 py-0.5 rounded border …">Terminé</span>  statut
--       « #978 au Panthéon »          rang
--       .lnv-synopsis__body           résumé
--       ul#chapters-list > a.chapter_link[data-num][href]   chapitres + date « 05 oct. 2026 »
--   * Chapitre     : /novel/<slug>/<numéro>, texte dans div#read-novel
--   * Liste        : /novels-list?page=N  (+ &sort=update&sort_dir=desc pour les dernières sorties)
--   * Recherche    : /novels-list?search=<terme>
--   * Panthéon     : /pantheon?critere=<critère>&page=N  (20 romans par page)
--       onglets  : Général · Mieux notés · Plus lus · Populaires · Discutés
--       périodes : Semaine · Mois · Tout temps
--       CONFIRMÉ (onglet Network) : critere=rating (« Mieux notés »),
--       critere=discussed (« Discutés »), periode=week (« Semaine »).
--       NON CONFIRMÉ : critere pour « Plus lus » et « Populaires », et la
--       valeur de periode pour « Mois » -> PANTHEON_CRITERES / PANTHEON_PERIODES.
--
-- NON CONFIRMÉ (le HTML correspondant n'a pas encore été vu) :
--   * la pagination de la liste des chapitres des romans très longs
--     (data-multi-page="1" sur la fiche) : la liste complète est alors
--     reconstruite à partir des numéros (1 … dernier chapitre) ;
--   * la structure exacte des pages /novels-list (cartes de romans) : on lit
--     simplement tous les liens /novel/<slug> avec leur image.
-- En cas de liste vide ou d'échec, la réponse du site est enregistrée dans
-- sefirah/lightnovelvf_last_error.txt (dossier des réglages de KOReader).

local BASE   = "https://www.lightnovelvf.com"
local logger = require("logger")

local T = require("core.i18n").T

-- Même identité de navigateur que scribblehub.lua / 69shu.lua.
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
-- open_pattern est un pattern Lua (échapper les « - » avec « %- »).
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

-- Valeur d'un attribut dans une balise ouvrante. Le nom est cherché entre
-- deux séparateurs : « src » ne doit pas matcher la fin de « data-src ».
local function attr(tag, name)
    if not tag then return nil end
    local esc = name:gsub("%-", "%%-")
    local v = tag:match("[%s<]" .. esc .. '%s*=%s*"([^"]*)"')
           or tag:match("[%s<]" .. esc .. "%s*=%s*'([^']*)'")
    return v
end

-- Image d'une carte : le site charge les couvertures en lazy-load (src est un
-- GIF 1x1 « data: », la vraie URL est dans data-src).
local function img_url(block)
    if not block then return nil end
    local tag = block:match("<img[^>]*>")
    if not tag then return nil end
    for _, key in ipairs({ "data-src", "data-lazy-src", "data-original", "src" }) do
        local u = abs_url(attr(tag, key))
        if u then return u end
    end
    return nil
end

-- ── Debug ─────────────────────────────────────────────────────────────────────

local function write_debug(content)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local f = io.open(dir .. "/lightnovelvf_last_error.txt", "wb")
        if f then f:write(content); f:close() end
    end)
end

-- ── HTTP ──────────────────────────────────────────────────────────────────────

local last_fail = nil

local function headers(lite)
    local h = {
        ["User-Agent"]      = UA,
        ["Accept"]          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "fr-FR,fr;q=0.9,en;q=0.5",
    }
    if not lite then h["Referer"] = BASE .. "/" end
    return h
end

local function is_retryable(code)
    if type(code) ~= "number" then return true end -- erreur réseau / délai dépassé
    return code == 403 or code == 429 or code >= 500
end

local function http_get(url)
    local Net = require("core.net")
    local body, code, extra = Net.get(url, { headers = headers(false), timeout = 12 })
    if not body and is_retryable(code) then
        pcall(function() require("socket").sleep(1.5) end)
        body, code, extra = Net.get(url, { headers = headers(true), timeout = 15 })
    end
    if body then
        last_fail = nil
        return body
    end
    last_fail = { code = code, body = tostring(extra or "") }
    logger.err("LightNovelVF: http_get FAILED", url, tostring(code))
    write_debug("URL : " .. url .. "\nStatut : " .. tostring(code)
        .. "\nDébut de la réponse :\n" .. last_fail.body .. "\n")
    return nil, code
end

-- Message affiché dans Parcourir quand la liste est vide à cause d'un échec.
local function failure_message()
    local f = last_fail or {}
    if f.code == 403 or f.code == 429 or f.code == 503
        or (f.body or ""):find("Just a moment", 1, true) then
        return T("LightNovelVF refuse la requête (HTTP ") .. tostring(f.code)
            .. T(", protection Cloudflare).")
    end
    return T("LightNovelVF injoignable : ") .. tostring(f.code or "erreur")
end

-- ── Listes de romans ──────────────────────────────────────────────────────────

-- /novel/<slug> (et rien après : pas /novel/<slug>/<chapitre>).
local function novel_path(href)
    local p = to_path(decode_entities(href or ""):gsub("[%?#].*$", ""))
    local slug = p:match("^/novel/([^/]+)/?$")
    if not slug then return nil end
    return "/novel/" .. slug
end

-- Parseur générique : tous les liens vers une fiche, regroupés par chemin.
-- Le nom vient (dans l'ordre) de title=, aria-label=, alt= de l'image, puis du
-- texte du lien ; la couverture de l'<img> du lien (qui peut être un autre lien
-- que celui du titre : dans les cartes, couverture et titre sont deux liens).
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
                local name = attr(open, "title") or attr(open, "aria-label")
                if not name or name == "" then
                    name = (inner:match("<img[^>]*>") and attr(inner:match("<img[^>]*>"), "alt")) or ""
                end
                name = strip_tags(name)
                if name == "" then name = strip_tags(inner) end
                if name ~= "" then e.name = name end
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

-- Liste vide : on garde le début de la page et on prévient à l'écran (page 1 seulement,
-- pour ne pas afficher d'erreur à la simple fin de la liste).
local function empty_list(url, html, page)
    write_debug("Liste vide pour : " .. url .. "\nTaille de la page : " .. #html
        .. " octets\nDébut de la page :\n" .. html:sub(1, 3000))
    if page and page > 1 then return { novels = {} } end
    return {
        novels = {},
        error  = T("LightNovelVF : page reçue mais aucun roman reconnu (")
            .. #html .. T(" octets). Voir sefirah/lightnovelvf_last_error.txt"),
    }
end

-- ── Dates ─────────────────────────────────────────────────────────────────────

-- « 05 oct. 2026 » -> « 2026-10-05 » (format attendu par l'interface).
-- Mois reconnus par leurs premières lettres, accents compris (févr., août, déc.).
local function month_number(name)
    local n = name:lower()
    local checks = {
        { "^ja", 1 }, { "^f", 2 }, { "^mar", 3 }, { "^av", 4 }, { "^mai", 5 },
        { "^juin", 6 }, { "^juil", 7 }, { "^ao", 8 }, { "^se", 9 },
        { "^oc", 10 }, { "^no", 11 }, { "^d", 12 },
    }
    for _, c in ipairs(checks) do
        if n:find(c[1]) then return c[2] end
    end
    return nil
end

local function iso_date(s)
    if not s then return nil end
    local d, mon, y = s:match("(%d%d?)%s+([^%s%d]+)%.?%s+(%d%d%d%d)")
    local m = mon and month_number(mon)
    if not m then return nil end
    return string.format("%04d-%02d-%02d", tonumber(y), m, tonumber(d))
end

-- ── Fiche roman ───────────────────────────────────────────────────────────────

local function status_from_label(label)
    local l = (label or ""):lower()
    if     l:find("termin", 1, true)  then return "Completed"
    elseif l:find("cours", 1, true)   then return "Ongoing"
    elseif l:find("pause", 1, true) or l:find("hiatus", 1, true) then return "Hiatus"
    elseif l:find("abandon", 1, true) then return "Cancelled"
    end
    return "Unknown"
end

local function parse_meta(html)
    local title = strip_tags(html:match('<h1[^>]-itemprop="name headline"[^>]*>(.-)</h1>') or "")
    if title == "" then
        title = strip_tags(html:match("<h1[^>]*>(.-)</h1>") or "")
    end
    if title == "" then
        local og = html:match('<meta property="og:title" content="([^"]*)"') or ""
        title = strip_tags(og):gsub("%s*—%s*LightNovelVF%s*$", "")
    end

    -- Couverture : <img … itemprop="image" … src="…">
    local cover
    for tag in html:gmatch("<img[^>]*>") do
        if tag:find('itemprop="image"', 1, true) then
            cover = abs_url(attr(tag, "src")) or abs_url(attr(tag, "data-src"))
            break
        end
    end
    if not cover then
        cover = abs_url(html:match('<meta property="og:image" content="([^"]*)"'))
    end

    -- Résumé : texte brut avec ses propres sauts de ligne.
    local summary = ""
    local desc = html:match('<div[^>]-class="lnv%-synopsis__body[^"]*"[^>]*>(.-)</div>')
    if desc then
        desc = desc:gsub("<br[^>]*/?>", "\n"):gsub("</p>", "\n\n")
        summary = strip_tags(desc):gsub("\n\n\n+", "\n\n")
    end

    local genres = {}
    for tag, inner in html:gmatch('(<a[^>]-itemprop="genre"[^>]*>)(.-)</a>') do
        local g = strip_tags(inner)
        if g ~= "" then genres[#genres + 1] = g end
    end

    -- Statut : badge juste après le nombre de chapitres.
    local label = html:match('<span class="text%-xs font%-semibold px%-2 py%-0%.5 rounded border[^"]*">%s*(.-)%s*</span>')
    local status = status_from_label(label and strip_tags(label))

    -- Nombre de chapitres : « <b class="text-white">2 487</b> chapitres ».
    local total
    local raw_total = html:match('<b class="text%-white">([^<]*)</b>%s*chapitres')
    if raw_total then total = tonumber((raw_total:gsub("%D", ""))) end

    local rank = tonumber(html:match("#(%d+)%s+au%s+Panth"))

    return {
        title   = title,
        cover   = cover,
        summary = summary,
        genres  = table.concat(genres, ", "),
        status  = status,
        total   = total,
        rank    = rank,
    }
end

-- ── Chapitres ─────────────────────────────────────────────────────────────────

-- Chapitres listés dans le HTML de la fiche : { {num=, path=, date=}, … } triés
-- du plus ancien au plus récent.
local function parse_listed_chapters(html)
    local list, seen = {}, {}
    for open, inner in html:gmatch('(<a[^>]-class="chapter_link[^"]*"[^>]*>)(.-)</a>') do
        local href = attr(open, "href")
        local num  = tonumber(attr(open, "data-num"))
            or tonumber(tostring(href or ""):match("/(%d+)/?$"))
        if href and num and not seen[num] then
            seen[num] = true
            list[#list + 1] = {
                num  = num,
                path = to_path(href),
                date = iso_date(strip_tags(inner)),
            }
        end
    end
    table.sort(list, function(a, b) return a.num < b.num end)
    return list
end

-- Numéro du premier chapitre : bouton « Commencer — Ch. N ».
local function first_chapter_number(html)
    local tag = html:match('<a[^>]-id="btn%-start"[^>]*>')
    local href = tag and attr(tag, "href")
    return href and tonumber(href:match("/(%d+)/?$")) or nil
end

local MAX_FILL = 20000 -- garde-fou contre une boucle démesurée

-- Liste complète des chapitres d'une fiche.
-- Fiche à une seule page (data-multi-page="0") : tout est dans le HTML.
-- Fiche paginée : la pagination n'est pas confirmée (voir en-tête du fichier) ;
-- on complète donc la liste avec les numéros manquants entre le premier et le
-- dernier chapitre connus (numérotation continue supposée).
local function build_chapters(html, base_path, meta)
    local listed = parse_listed_chapters(html)
    local by_num = {}
    for _, c in ipairs(listed) do by_num[c.num] = c end

    local multi = html:find('data-multi-page="1"', 1, true) ~= nil
        or (tonumber(html:match('data-total-pages="(%d+)"')) or 1) > 1
    local missing = (meta.total or 0) > #listed

    local chapters = {}
    if (multi or missing) and meta.total and meta.total > 0 then
        local first = first_chapter_number(html) or (listed[1] and listed[1].num) or 1
        local last  = listed[#listed] and listed[#listed].num or (first + meta.total - 1)
        if last < first then first, last = last, first end
        if last - first + 1 > MAX_FILL then first = last - MAX_FILL + 1 end
        for n = math.floor(first), math.floor(last) do
            local c = by_num[n]
            chapters[#chapters + 1] = {
                name           = T("Chapitre ") .. n,
                path           = c and c.path or (base_path .. "/" .. n),
                chapter_number = n,
                date           = c and c.date or nil,
            }
        end
        if #listed < #chapters then
            write_debug("Liste de chapitres reconstruite pour " .. base_path
                .. "\nChapitres lus dans la page : " .. #listed
                .. "\nChapitres générés (numérotation continue supposée) : " .. #chapters
                .. "\ndata-multi-page / data-total-pages : " .. tostring(multi) .. "\n")
        end
    else
        for _, c in ipairs(listed) do
            chapters[#chapters + 1] = {
                name           = T("Chapitre ") .. c.num,
                path           = c.path,
                chapter_number = c.num,
                date           = c.date,
            }
        end
    end
    return chapters
end

-- ── Filtres « Parcourir » : le Panthéon du site ──────────────────────────────
-- Reprend les onglets de https://www.lightnovelvf.com/pantheon.
-- `param` = valeur envoyée dans ?critere= (nil = onglet par défaut du site).
-- ⚠ « rating » et « discussed » sont confirmés. Les autres valeurs sont des hypothèses :
-- si un onglet renvoie le même classement que « Général », corrige UNIQUEMENT
-- la valeur `param` correspondante ci-dessous (Network > clic sur l'onglet >
-- « Request URL »).
local PANTHEON_CRITERES = {
    general = { param = nil },
    rating  = { param = "rating" },    -- confirmé
    views   = { param = "views" },     -- à confirmer
    popular = { param = "popular" },   -- à confirmer
    comment = { param = "discussed" }, -- confirmé
}

-- Période : le nom du paramètre et « week » sont confirmés ; « month » ne l'est
-- pas. « Tout temps » est l'état par défaut du site (aucun paramètre dans
-- l'URL vue), donc on n'envoie rien dans ce cas.
local PANTHEON_PERIODE_PARAM = "periode"   -- confirmé
local PANTHEON_PERIODES = {
    all   = nil,
    week  = "week",    -- confirmé
    month = "month",   -- à confirmer
}

local POPULAR_FILTERS = {
    {
        key = "critere", label = "Classement", default = "general",
        options = {
            { id = "general", label = "Général" },
            { id = "rating",  label = "Mieux notés" },
            { id = "views",   label = "Plus lus" },
            { id = "popular", label = "Populaires" },
            { id = "comment", label = "Discutés" },
        },
    },
    {
        key = "period", label = "Période", default = "all",
        options = {
            { id = "week",  label = "Semaine" },
            { id = "month", label = "Mois" },
            { id = "all",   label = "Tout temps" },
        },
    },
}

local function pantheon_url(critere, period, page)
    local q = {}
    local c = PANTHEON_CRITERES[critere or "general"]
    if c and c.param then q[#q + 1] = "critere=" .. c.param end
    local p = PANTHEON_PERIODES[period or "all"]
    if p then q[#q + 1] = PANTHEON_PERIODE_PARAM .. "=" .. p end
    if page and page > 1 then q[#q + 1] = "page=" .. tostring(page) end
    local url = BASE .. "/pantheon"
    if #q > 0 then url = url .. "?" .. table.concat(q, "&") end
    return url
end

-- Recherche : on garde le catalogue (paramètre `search` confirmé).
local function list_url(page, search)
    local q = {}
    if search and search ~= "" then q[#q + 1] = "search=" .. url_encode(search) end
    if page and page > 1 then q[#q + 1] = "page=" .. tostring(page) end
    local url = BASE .. "/novels-list"
    if #q > 0 then url = url .. "?" .. table.concat(q, "&") end
    return url
end

-- Le Panthéon charge ses onglets en AJAX (réponse JSON dans l'onglet Network).
-- Une requête GET classique renvoie normalement la page HTML complète ; au cas
-- où le serveur répondrait quand même en JSON, on en extrait le HTML s'il y en a.
local function body_to_html(body)
    if not body or not body:match("^%s*[{%[]") then return body end
    local ok_j, json = pcall(require, "json")
    if not ok_j then return body end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then return body end
    local parts = {}
    local function walk(v)
        if type(v) == "string" then
            if v:find("/novel/", 1, true) then parts[#parts + 1] = v end
        elseif type(v) == "table" then
            for _, x in pairs(v) do walk(x) end
        end
    end
    walk(data)
    if #parts == 0 then return body end
    return table.concat(parts, "\n")
end

-- ── Extension ─────────────────────────────────────────────────────────────────

local ext = {
    id             = "lightnovelvf",
    name           = "LightNovelVF",
    site           = BASE,
    lang           = "fr",
    version        = "1.1.1",
    popularFilters = POPULAR_FILTERS,
    -- Le site n'a pas d'avis ni de commentaires exploitables : pas d'onglet
    -- « Avis » ni d'icône commentaire dans la fiche (comme 69shu).
    hasReviews     = false,
}

function ext:popularNovels(page, options)
    page = page or 1
    local f    = options and options.filters or {}
    local url  = pantheon_url(f.critere, f.period, page)
    logger.dbg("LightNovelVF: popularNovels", url)
    local html = http_get(url)
    if not html then return { novels = {}, error = failure_message() } end
    html = body_to_html(html)
    local novels = parse_novel_links(html)
    if #novels == 0 then return empty_list(url, html, page) end
    return { novels = novels }
end

function ext:searchNovels(term, page)
    page = page or 1
    local url = list_url(page, term)
    logger.dbg("LightNovelVF: searchNovels", url)
    local html = http_get(url)
    if not html then return { novels = {}, error = failure_message() } end
    local novels = parse_novel_links(html)
    if #novels == 0 then return empty_list(url, html, page) end
    return { novels = novels }
end

function ext:parseNovelMeta(path)
    local html = http_get(full_url(path))
    if not html then return nil end
    local meta = parse_meta(html)
    return {
        name           = meta.title,
        path           = path,
        cover          = meta.cover,
        summary        = meta.summary,
        status         = meta.status,
        rank           = meta.rank,
        total_chapters = meta.total or 0,
    }
end

function ext:parseNovel(path)
    local base_path = (path or ""):gsub("/+$", "")
    local html = http_get(full_url(base_path))
    if not html then
        logger.err("LightNovelVF: parseNovel fetch failed", path)
        return nil
    end
    local meta = parse_meta(html)
    if meta.title == "" then
        write_debug("Fiche illisible pour " .. base_path .. "\nTaille : " .. #html
            .. " octets\nDébut de la page :\n" .. html:sub(1, 3000))
        return nil
    end
    local chapters = build_chapters(html, base_path, meta)
    if #chapters == 0 then
        logger.err("LightNovelVF: aucun chapitre trouvé pour", path)
    end
    return {
        name       = meta.title,
        path       = path,
        cover      = meta.cover,
        summary    = meta.summary,
        genres     = meta.genres,
        status     = meta.status,
        rank       = meta.rank,
        chapters   = chapters,
        totalPages = 1,
    }
end

function ext:parseChapter(path)
    local html = http_get(full_url(path))
    if not html then return T("<p>Impossible de récupérer ce chapitre.</p>") end

    -- Les <script>/<style> sont retirés AVANT de compter les <div> : un « <div> »
    -- dans une chaîne JavaScript fausserait l'équilibre des balises.
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")

    -- Texte dans div#read-novel (les divs vides qu'il contient sont gérés par
    -- le comptage des <div> imbriqués).
    local content = extract_div(html, '<div[^>]-id="read%-novel"')
    if not content then
        write_debug("Chapitre : texte introuvable pour " .. path
            .. "\nDébut de la page :\n" .. html:sub(1, 3000))
        return T("<p>Impossible d'extraire le contenu de ce chapitre.</p>")
    end

    content = content:gsub("<div[^>]*>%s*</div>", "")   -- conteneurs vides
    content = content:gsub("<p[^>]*>%s*</p>", "")        -- paragraphes vides
    content = content:gsub("^%s+", ""):gsub("%s+$", "")
    if content == "" then
        return T("<p>Impossible d'extraire le contenu de ce chapitre.</p>")
    end
    return content
end

return ext
