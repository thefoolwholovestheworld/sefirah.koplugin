-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- 69shu.lua
-- Extension Sefirah pour https://www.69shu.xyz
--
-- Réécrit à partir d'une vraie page envoyée par l'utilisateur
-- (https://www.69shu.xyz/book/5516, capturée le 2026-09-19), PAS des
-- sélecteurs de lncrawl utilisés dans une version précédente de ce fichier.
-- Ceux-ci ciblaient un gabarit totalement différent (booknav2/bookimg2/
-- txtnav — probablement celui d'un autre domaine de la famille 69shu, genre
-- 69shuba.com) : rien de tout ça n'existe sur 69shu.xyz, qui utilise un
-- thème différent ("wucuo", visible dans les chemins CSS/JS de la page).
-- D'où le "aucun résultat" : mauvais domaine ET mauvais sélecteurs à la fois.
--
-- Sélecteurs confirmés par la page envoyée (/book/<id>) :
--   - Titre     : h1.name
--   - Couverture: premier <img class="thumbnail"> de la page (celui de la
--                 fiche ; les recommandations en bas de page en ont d'autres,
--                 mais elles arrivent après dans le HTML)
--   - Auteur    : <a href=".../author/...">
--   - Résumé    : <p id="bookIntro"> (contient un préfixe "<strong>xxx：</strong>"
--                 retiré au parsing)
--   - Genre     : 2e lien de la barre "fil d'Ariane" (<ol class="breadcrumb">),
--                 le 1er étant toujours "首页" (Accueil)
--   - Chapitres : la page contient DEUX blocs <dl class="panel-chapterlist">
--                 ("最新章节列表" = 12 derniers, puis "全部章节目录" = liste
--                 complète) ; on garde celui qui a le plus d'entrées. ATTENTION
--                 (non résolu) : au-delà d'un certain nombre de chapitres, le
--                 bloc complet a lui-même un "trou" au milieu avec un lien
--                 "点击查看中间隐藏的【N】章节" vers une page séparée
--                 (/index/5/<id>/1.html/ sur l'exemple reçu — le "5" n'est pas
--                 identifié, peut-être un id de catégorie) : les chapitres de
--                 ce trou ne sont PAS récupérés pour l'instant. Si un roman
--                 suivi a moins de chapitres que "total_chapters" ne l'indique,
--                 c'est ce trou.
--   - Recherche : le formulaire de la page elle-même donne l'endpoint réel :
--                 POST /search, champ "searchkey" (pas
--                 /modules/article/search.php comme supposé avant, qui vient
--                 d'un autre domaine/thème).
--
-- NON CONFIRMÉ faute d'exemple :
--   - Page de lecture d'un chapitre (/read/<id>/<chapId>.html) : structure du
--     contenu inconnue. parseChapter ci-dessous essaie plusieurs sélecteurs
--     usuels sur ce type de thème, mais RIEN ne garantit qu'un seul marche
--     (à confirmer sur une vraie page de lecture).
--   - Page de recherche (résultat de POST /search) : parse_novel_list ci-
--     dessous réutilise le gabarit "book-coverlist" vu dans la section
--     recommandations de la page fiche roman (même thème, donc probable),
--     mais ce n'est pas la page de résultats elle-même — à confirmer/corriger
--     si la recherche renvoie toujours 0 résultat.
--   - Classement (popularNovels) : aucune page de classement observée —
--     l'URL et le sélecteur ci-dessous sont une supposition pure.
--
-- v1.2.0 (recherche "Aucun résultat") : POST /search suivi manuellement en cas de
-- redirection (LuaSocket ne le fait pas après un POST), parseur de secours basé
-- sur les liens /book/<id>, erreurs HTTP remontées à l'écran au lieu d'un
-- "Aucun résultat" muet, plus de re-POST en double pour page > 1, et copie de la
-- dernière réponse dans sefirah/69shu_last_search.html quand rien n'est reconnu.
--
-- v1.2.1 (log KOReader du 19/09) : le « Aucun résultat » venait de l'écran de
-- navigation à l'ouverture de la source (popularNovels), pas de la recherche :
-- /top/monthvisit/ (URL héritée de 69shuba) répondait 403. Remplacé par
-- /sort/all/<page>.html ; erreurs HTTP maintenant affichées ; UA de navigateur.
--
-- v1.3.0 : le 403 persistait avec v1.2.1 (écran « liste indisponible (HTTP 403) »).
-- Requêtes réécrites façon navigateur (Sec-Fetch-*, sec-ch-ua, cookies de session,
-- accueil visité d'abord, 2e tentative après pause) + réponse du serveur
-- enregistrée dans sefirah/69shu_last_error.txt pour diagnostiquer le blocage.
--
-- v1.4.0 : ouverture directe sur /rank/allvisit/1.html, filtres de liste
-- (classement, 分类 toutes / 玄幻 / 都市, 全本), onglet Avis masqué pour cette
-- source (hasReviews = false), clavier chinois pour la recherche.
--
-- v1.5.0 : nom affiché « 69alphabetmandarin » ; filtres de l'écran Parcourir
-- DÉCOUVERTS SUR LE SITE (voir « Filtres découverts » plus bas) : les liens
-- /rank/<liste>/N.html, /sort/<catégorie>/N.html et /full/<catégorie>/N.html
-- présents dans les pages du site (accueil, page de liste) sont lus au vol, mis
-- en cache dans sefirah/69shu_filters.lua et proposés tous dans « Filtrer ».
-- Aucun slug n'est deviné : seuls ceux que le site expose (ou déjà confirmés
-- plus haut) apparaissent.
--
-- ENCODAGE : la page reçue déclare <meta charset="UTF-8"> et le texte chinois
-- est lisible tel quel — UTF-8 confirmé pour ce domaine (contrairement à la
-- supposition GBK d'une version précédente, qui visait un autre domaine).

local logger = require("logger")

local BASE       = "https://www.69shu.xyz"
local SEARCH_URL = BASE .. "/search"
-- Chrome mobile « réduit » (format UA réel de Chrome sur Android).
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 " ..
           "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

-- ── HTTP ──────────────────────────────────────────────────────────────────
-- Le site répond 403 à KOReader (écran « liste indisponible (HTTP 403) » et
-- lignes « http_get failed … 403 » du log). Ce bloc envoie donc une requête la
-- plus proche possible d'une navigation Chrome : en-têtes Sec-Fetch-* / sec-ch-ua,
-- cookies conservés pendant la session (page d'accueil visitée d'abord), une
-- nouvelle tentative après pause, redirections suivies à la main (cookies
-- gardés). En cas d'échec, la réponse du serveur est enregistrée pour voir ce
-- qui bloque vraiment (voir write_debug / 69shu_last_error.txt).

local function write_debug(name, content)
    pcall(function()
        local DataStorage = require("datastorage")
        local f = io.open(DataStorage:getSettingsDir() .. "/sefirah/" .. name, "wb")
        if f then f:write(content); f:close() end
    end)
end

local cookie_jar = {}      -- nom -> valeur, pour la durée de la session KOReader
local warmed_up  = false

local COOKIE_ATTRS = {
    expires = true, path = true, domain = true, ["max-age"] = true, secure = true,
    httponly = true, samesite = true, priority = true, partitioned = true,
}

local function store_cookies(resp_h)
    local sc = resp_h and resp_h["set-cookie"]
    if not sc then return end
    for name, value in sc:gmatch("([^=;,%s]+)=([^;,]*)") do
        if not COOKIE_ATTRS[name:lower()] then cookie_jar[name] = value end
    end
end

local function cookie_header()
    local parts = {}
    for k, v in pairs(cookie_jar) do parts[#parts + 1] = k .. "=" .. v end
    if #parts == 0 then return nil end
    return table.concat(parts, "; ")
end

local function browser_headers(same_origin)
    local h = {
        ["User-Agent"]                = UA,
        ["Accept"]                    = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
        ["Accept-Language"]           = "zh-CN,zh;q=0.9,en;q=0.8",
        ["Upgrade-Insecure-Requests"] = "1",
        ["Sec-Fetch-Dest"]            = "document",
        ["Sec-Fetch-Mode"]            = "navigate",
        ["Sec-Fetch-Site"]            = same_origin and "same-origin" or "none",
        ["Sec-Fetch-User"]            = "?1",
        ["sec-ch-ua"]                 = '"Chromium";v="140", "Google Chrome";v="140", "Not=A?Brand";v="24"',
        ["sec-ch-ua-mobile"]          = "?1",
        ["sec-ch-ua-platform"]        = '"Android"',
    }
    if same_origin then h["Referer"] = BASE .. "/" end
    local ck = cookie_header()
    if ck then h["Cookie"] = ck end
    return h
end

-- Résout un en-tête Location (absolu, //hôte, /chemin ou relatif) par rapport à `base`.
local function resolve_location(loc, base)
    loc = loc:gsub("%s", "")
    if loc:match("^https?://") then return loc end
    local scheme = base:match("^(https?):") or "https"
    local origin = base:match("^(https?://[^/]+)") or BASE
    if loc:sub(1, 2) == "//" then return scheme .. ":" .. loc end
    if loc:sub(1, 1) == "/"  then return origin .. loc end
    local dir = base:match("^(https?://[^?#]+/)") or (origin .. "/")
    return dir .. loc
end

-- Une requête (GET, ou POST si opts.body), redirections suivies à la main.
-- Renvoie { code, body, headers } ou { err = "message" }.
local function fetch(url, opts)
    opts = opts or {}
    local https = require("ssl.https")
    local http  = require("socket.http")
    local ltn12 = require("ltn12")
    local is_post, same_origin, extra = opts.body ~= nil, opts.same_origin, opts.headers
    local cur_url = url
    for _ = 0, 5 do
        local sink = {}
        local h = browser_headers(same_origin)
        if extra then for k, v in pairs(extra) do h[k] = v end end
        local r = {
            url      = cur_url,
            sink     = ltn12.sink.table(sink),
            headers  = h,
            timeout  = 20,
            redirect = false,
        }
        if is_post then
            r.method = "POST"
            r.source = ltn12.source.string(opts.body)
        end
        local req = cur_url:match("^https") and https or http
        local ok, code, resp_h = req.request(r)
        if not ok then return { err = tostring(code) } end
        resp_h = resp_h or {}
        store_cookies(resp_h)
        local loc = resp_h.location
        if loc and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) then
            cur_url = resolve_location(loc, cur_url)
            logger.dbg("69shu: redirect ->", cur_url)
            is_post, same_origin, extra = false, true, nil   -- la suite se fait en GET
        else
            return { code = code, body = table.concat(sink), headers = resp_h }
        end
    end
    return { err = "trop de redirections" }
end

local function is_challenge(res)
    local b = res.body or ""
    local h = res.headers or {}
    return (h["cf-mitigated"] ~= nil)
        or b:find("Just a moment", 1, true) ~= nil
        or b:find("cf-chl", 1, true) ~= nil
        or b:find("challenge-platform", 1, true) ~= nil
end

-- Déclarée ici, définie plus bas (section « Filtres découverts ») : la page
-- d'accueil visitée par warm_up sert aussi à repérer les listes du site.
local harvest_lists

-- Page d'accueil d'abord (comme un navigateur) pour récupérer d'éventuels cookies.
local function warm_up()
    if warmed_up then return end
    warmed_up = true
    local res = fetch(BASE .. "/", {})
    logger.dbg("69shu: warm_up code=", tostring(res.code or res.err),
               "cookies=", cookie_header() or "aucun")
    if res.code == 200 and res.body and harvest_lists then
        pcall(harvest_lists, res.body)
    end
end

local function request(url, opts)
    warm_up()
    local res = fetch(url, opts)
    if res.code == 403 or res.code == 429 or res.code == 503 then
        -- une seule nouvelle tentative après une courte pause (limite de débit)
        pcall(function() require("socket").sleep(1.5) end)
        res = fetch(url, opts)
    end
    return res
end

-- Échec : garde la réponse du serveur dans sefirah/69shu_last_error.txt et renvoie
-- une table décrivant l'échec (voir describe_failure).
local function record_failure(url, res)
    local h = res.headers or {}
    local fail = {
        code      = res.code,
        err       = res.err,
        server    = h.server,
        cf        = (h["cf-ray"] ~= nil) or (h["cf-mitigated"] ~= nil)
                    or tostring(h.server or ""):lower():find("cloudflare", 1, true) ~= nil,
        challenge = is_challenge(res),
    }
    local lines = { "URL : " .. url, "Statut : " .. tostring(res.code or res.err), "En-têtes :" }
    for k, v in pairs(h) do lines[#lines + 1] = "  " .. k .. ": " .. tostring(v) end
    lines[#lines + 1] = "Cookies envoyés : " .. (cookie_header() or "aucun")
    lines[#lines + 1] = "Corps (3000 premiers octets) :"
    lines[#lines + 1] = (res.body or ""):sub(1, 3000)
    write_debug("69shu_last_error.txt", table.concat(lines, "\n"))
    return fail
end

-- Renvoie : body | nil, fail
local function http_get(url)
    local res = request(url, { same_origin = true })
    if res.code == 200 then return res.body, 200 end
    logger.err("69shu: http_get failed:", url, tostring(res.code or res.err))
    return nil, record_failure(url, res)
end

-- POST d'un formulaire (application/x-www-form-urlencoded).
-- Renvoie : body | nil, fail
local function http_post_form(url, fields, extra_headers)
    local parts = {}
    for k, v in pairs(fields) do parts[#parts + 1] = k .. "=" .. v end
    local body = table.concat(parts, "&")
    local headers = {
        ["Content-Type"]   = "application/x-www-form-urlencoded",
        ["Content-Length"] = tostring(#body),
        ["Sec-Fetch-Site"] = "same-origin",
    }
    if extra_headers then for k, v in pairs(extra_headers) do headers[k] = v end end
    local res = request(url, { body = body, headers = headers, same_origin = true })
    if res.code == 200 then return res.body, 200 end
    logger.err("69shu: http_post_form failed:", url, tostring(res.code or res.err))
    return nil, record_failure(url, res)
end

local function url_encode(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- ── HTML helpers (mêmes conventions que royalroad.lua / skynovels.lua) ────

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

local function strip_tags(s)
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&#x(%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);",  function(d) return utf8_encode(tonumber(d)) end)
    s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
    return s:match("^%s*(.-)%s*$") or ""
end

-- Extracteur de <div>...</div> équilibré (mêmes limites/usage que dans
-- royalroad.lua : ne gère que les <div> imbriqués, pas les autres balises).
local function extract_div(html, open_pattern, start_pos)
    local s, e = html:find(open_pattern, start_pos or 1)
    if not s then return nil, nil end
    local tag_end = html:find('>', e)
    if not tag_end then return nil, nil end
    local depth, pos = 1, tag_end + 1
    while depth > 0 and pos <= #html do
        local open_pos  = html:find('<div', pos, true)
        local close_pos = html:find('</div>', pos, true)
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

-- ── Chemins / identifiants ─────────────────────────────────────────────────
-- path stocké au format "book/<id>" (SANS ".htm" — confirmé par la page
-- reçue : le lien canonique et tous les liens internes pointent vers
-- /book/<id> sans extension).

local function novel_id_from_path(path)
    return tostring(path or ""):match("book/(%d+)")
end

local function info_url_from_id(id)
    return BASE .. "/book/" .. id
end

-- Convertit /read/<id>/<chapId>.html (ou une URL complète) en chemin routable.
local function chapter_href_to_path(href)
    href = href:match("^https?://[^/]+(.+)") or href
    return href:match("^/(.+)") or href
end

-- ── Métadonnées de la fiche roman ──────────────────────────────────────────

local function parse_meta(html)
    local title = strip_tags(html:match('<h1[^>]*class="[^"]*name[^"]*"[^>]*>(.-)</h1>')
        or html:match('<h1[^>]*>(.-)</h1>') or "")

    -- Premier <img class="thumbnail"> de la page = couverture de la fiche
    -- (les cartes de recommandation en bas de page en ont d'autres, mais
    -- elles arrivent plus loin dans le HTML).
    local cover = html:match('<img[^>]*class="[^"]*thumbnail[^"]*"[^>]*src="([^"]+)"')
    if cover and not cover:match("^https?://") then
        cover = BASE .. (cover:match("^/") and cover or ("/" .. cover))
    end

    local author = strip_tags(
        html:match('<a[^>]*href="[^"]*/author/[^"]*"[^>]*>(.-)</a>') or "")

    -- Le résumé est dans <p id="bookIntro">, précédé d'une étiquette
    -- "<strong>小说简介：</strong>" retirée ici (elle n'apporte rien en UI).
    local intro_raw = html:match('<p[^>]*id="bookIntro"[^>]*>(.-)</p>') or ""
    intro_raw = intro_raw:gsub('^%s*<strong>.-</strong>%s*', '')
    local summary = strip_tags(intro_raw)

    -- Genre = 2e lien du fil d'Ariane (<ol class="breadcrumb">) ; le premier
    -- est toujours "首页" (Accueil), le 3e (sans lien, class="active") est le
    -- titre du roman.
    local genre = ""
    local crumb = html:match('<ol[^>]*class="[^"]*breadcrumb[^"]*"[^>]*>(.-)</ol>')
    if crumb then
        local i = 0
        for link_text in crumb:gmatch('<a[^>]*>(.-)</a>') do
            i = i + 1
            if i == 2 then
                genre = strip_tags(link_text)
                break
            end
        end
    end

    return {
        title   = title,
        author  = author,
        cover   = cover,
        summary = summary,
        genres  = genre,
    }
end

-- ── Table des chapitres (directement sur la page fiche roman) ─────────────
-- Voir le commentaire d'en-tête : le "trou" du milieu sur les romans à
-- beaucoup de chapitres n'est pas géré ici.

local function parse_chapters_from_book_page(html)
    local best_chapters, best_count = {}, -1
    local pos = 1
    while true do
        -- extract_div est fait pour <div>, mais <dl>/</dl> n'est jamais
        -- imbriqué ici donc un simple find/match suffit à la place :
        local s = html:find('<dl[^>]*class="[^"]*panel%-chapterlist[^"]*"', pos)
        if not s then break end
        local tag_end = html:find('>', s)
        local close_s = html:find('</dl>', tag_end)
        if not tag_end or not close_s then break end
        local block = html:sub(tag_end + 1, close_s - 1)

        local chapters, n = {}, 0
        for href, name in block:gmatch('<a%s+href="(/read/[^"]+)"[^>]*>(.-)</a>') do
            n = n + 1
            table.insert(chapters, {
                name           = strip_tags(name),
                path           = chapter_href_to_path(href),
                chapter_number = n,
            })
        end
        if n > best_count then
            best_count, best_chapters = n, chapters
        end
        pos = close_s + 5
    end
    return best_chapters
end

-- Nombre total de chapitres annoncé par le site (ex. "共182章"), utile même
-- quand la liste récupérée ci-dessus est incomplète (trou du milieu).
local function parse_total_chapters(html)
    local n = html:match('共(%d+)章')
    return tonumber(n) or 0
end

-- ── Liste de romans (recherche / classements) ─────────────────────────────
-- Gabarit "book-coverlist" vu dans les recommandations de la page fiche
-- roman — PAS confirmé pour la page de résultats de recherche elle-même
-- (voir commentaire d'en-tête).

local function parse_novel_list(html)
    local novels = {}
    for card in html:gmatch('<div[^>]*class="[^"]*book%-coverlist[^"]*"[^>]*>(.-)</div>%s*</div>') do
        local href  = card:match('<a[^>]*class="[^"]*cover[^"]*"[^>]*href="([^"]+)"')
            or card:match('<a[^>]*href="([^"]+)"')
        local title = strip_tags(card:match('<h4[^>]*class="[^"]*name[^"]*"[^>]*>(.-)</h4>') or "")
        if href and title ~= "" then
            local cover = card:match('<img[^>]*src="([^"]+)"')
            table.insert(novels, {
                name  = title,
                path  = chapter_href_to_path(href),
                cover = cover,
            })
        end
    end
    return novels
end

-- Parseur de secours, indépendant du gabarit : toute page de résultats doit
-- forcément lier chaque roman vers /book/<id>. On collecte ces liens (dédoublés
-- par id) et on prend comme titre l'attribut title, sinon le texte du lien,
-- sinon l'alt de l'image. Si `term` apparaît dans au moins un titre, on ne garde
-- que ceux-là (évite les romans "recommandés" d'une barre latérale).
local function parse_novel_list_loose(html, term)
    local byid, order = {}, {}
    for attrs, inner in html:gmatch('<a%s([^>]-)>(.-)</a>') do
        local id = attrs:match('href="[^"]*/book/(%d+)')
        if id then
            -- rang du titre : 3 = attribut title, 2 = texte du lien, 1 = alt de
            -- l'image (un meilleur rang remplace un moins bon pour le même id).
            local t, rank = attrs:match('title="([^"]+)"'), 3
            if not t or strip_tags(t) == "" then
                t, rank = strip_tags(inner), 2
                if t == "" then
                    t, rank = inner:match('<img[^>]-alt="([^"]+)"') or "", 1
                end
            end
            t = strip_tags(t)
            if not byid[id] then
                byid[id] = { name = "", rank = 0, path = "book/" .. id }
                order[#order + 1] = id
            end
            if t ~= "" and rank > byid[id].rank then
                byid[id].name, byid[id].rank = t, rank
            end
        end
    end
    local list = {}
    for _, id in ipairs(order) do
        if byid[id].name ~= "" then
            list[#list + 1] = { name = byid[id].name, path = byid[id].path }
        end
    end
    if term and term ~= "" then
        local matched = {}
        for _, n in ipairs(list) do
            if n.name:find(term, 1, true) then matched[#matched + 1] = n end
        end
        if #matched > 0 then list = matched end
    end
    return list
end

-- Sauvegarde la dernière réponse brute quand aucun roman n'est reconnu, pour
-- pouvoir voir ce que le site renvoie réellement (fichier lisible depuis un PC).
local DEBUG_FILE = "69shu_last_search.html"
local function dump_debug(body, name)
    write_debug(name or DEBUG_FILE, body)
end

local function describe_failure(f)
    if type(f) ~= "table" then
        if type(f) == "number" then return "HTTP " .. f end
        return tostring(f)
    end
    if f.err then return f.err end
    if f.challenge then
        return "HTTP " .. tostring(f.code) ..
            " — challenge anti-bot (Cloudflare/JavaScript), impossible à passer depuis KOReader"
    end
    if f.code == 403 or f.code == 429 or f.code == 503 then
        return "HTTP " .. f.code .. " — le site refuse la requête" ..
            (f.cf and " (Cloudflare)" or "") ..
            " ; détails : sefirah/69shu_last_error.txt"
    end
    return "HTTP " .. tostring(f.code)
end

-- ── Extension ──────────────────────────────────────────────────────────────

-- ── Filtres découverts sur le site ─────────────────────────────────────────
-- Toutes les listes du site ont la même forme /<famille>/<liste>/<page>.html :
--   rank = 排行榜 (classements)   sort = 分类 (catégories)   full = 全本 (terminés)
-- Confirmées par des URL réelles du site :
--   /rank/allvisit/1.html (page d'ouverture), /sort/xuanhuan/1.html, /sort/dushi/1.html,
--   /sort/all/1.html, /full/all/1.html.
-- Les AUTRES listes (autres catégories, autres classements) ne sont pas devinées :
-- on les lit dans les liens des pages du site (accueil, pages de liste), on les
-- garde dans sefirah/69shu_filters.lua (dispo dès l'ouverture suivante) et on les
-- ajoute à « Filtrer ». Les listes confirmées ci-dessus sont toujours proposées.

local FAMILIES     = { "rank", "sort", "full" }
local FAMILY_NAME  = { rank = "排行榜", sort = "分类", full = "全本" }
local DEFAULT_LIST = "rank/allvisit"

-- Listes confirmées (toujours présentes, même si la découverte échoue).
local CONFIRMED = {
    rank = { { "allvisit", "总点击" } },
    sort = { { "all", "全部" }, { "xuanhuan", "玄幻" }, { "dushi", "都市" } },
    full = { { "all", "全部" } },
}

-- Petit lexique pour afficher une traduction à côté du libellé chinois du site.
local GLOSSARY = {
    ["全部"] = "Toutes", ["全部分类"] = "Toutes", ["玄幻"] = "Fantasy", ["奇幻"] = "Fantasy occidentale",
    ["武侠"] = "Wuxia", ["仙侠"] = "Xianxia", ["修真"] = "Cultivation", ["都市"] = "Urbain",
    ["现实"] = "Réaliste", ["军事"] = "Militaire", ["历史"] = "Histoire", ["游戏"] = "Jeux",
    ["网游"] = "Jeux en ligne", ["竞技"] = "Compétition", ["体育"] = "Sport", ["科幻"] = "Science-fiction",
    ["悬疑"] = "Mystère", ["灵异"] = "Surnaturel", ["恐怖"] = "Horreur", ["言情"] = "Romance",
    ["穿越"] = "Transmigration", ["重生"] = "Renaissance", ["同人"] = "Fanfiction", ["轻小说"] = "Light novel",
    ["青春"] = "Jeunesse", ["校园"] = "Campus", ["女生"] = "Filles", ["男生"] = "Garçons",
    ["其他"] = "Autres", ["其它"] = "Autres", ["总点击"] = "Clics (total)", ["点击"] = "Clics",
    ["月点击"] = "Clics du mois", ["周点击"] = "Clics de la semaine", ["日点击"] = "Clics du jour",
    ["总推荐"] = "Recommandations", ["推荐"] = "Recommandations", ["收藏"] = "Favoris",
    ["字数"] = "Nombre de mots", ["最新"] = "Nouveautés", ["更新"] = "Dernières MAJ", ["新书"] = "Nouveaux romans",
    ["完结"] = "Terminés", ["完本"] = "Terminés", ["全本"] = "Terminés", ["连载"] = "En cours",
}

local function hint_for(label)
    if GLOSSARY[label] then return GLOSSARY[label] end
    -- suffixes courants : « 玄幻小说 », « 总点击榜 », « 月点击排行 »…
    local core = label:gsub("小说$", ""):gsub("排行榜$", ""):gsub("排行$", ""):gsub("榜$", "")
    if core ~= label and GLOSSARY[core] then return GLOSSARY[core] end
    return nil
end

-- État : disc[famille] = { order = { slug… }, label = { [slug] = libellé }, generic = { [slug] = true } }
-- generic = libellé vague (celui du menu principal : « 排行榜 », « 分类 », « 全本 ») qu'un
-- libellé plus précis vu ailleurs pour le même slug remplace.
local disc = {}
for _, fam in ipairs(FAMILIES) do disc[fam] = { order = {}, label = {}, generic = {} } end
local discovery_tried = {}     -- famille -> true : page de base déjà demandée cette session
local filters_dirty   = false  -- true : le cache disque n'est pas à jour

local function disc_add(fam, slug, label)
    local d = disc[fam]
    if not d then return end
    local is_generic = (label == "" or label == FAMILY_NAME[fam])
    if not d.label[slug] then
        d.order[#d.order + 1] = slug
        d.label[slug]   = is_generic and "" or label
        d.generic[slug] = is_generic or nil
        filters_dirty = true
    elseif d.generic[slug] and not is_generic then
        d.label[slug]   = label
        d.generic[slug] = nil
        filters_dirty = true
    end
end

-- Libellés qui ne sont pas des noms de liste (pagination, « accueil »…).
local NOT_A_LABEL = {
    ["首页"] = true, ["尾页"] = true, ["末页"] = true, ["上一页"] = true, ["下一页"] = true,
    ["上页"] = true, ["下页"] = true, ["第一页"] = true, ["最后一页"] = true, ["更多"] = true,
    ["More"] = true, ["more"] = true, ["Next"] = true, ["Prev"] = true,
}

-- Vrai pour « 2 », « > », « « », « 12 » … : liens de pagination, pas des noms de liste.
local function is_pager_label(label)
    if NOT_A_LABEL[label] then return true end
    local t = label:gsub("[%d%s<>%.%-]", "")
    t = t:gsub("‹", ""):gsub("›", ""):gsub("«", ""):gsub("»", "")
    return t == ""
end

-- Lit tous les liens /rank|sort|full/<slug>/N.html d'une page HTML.
harvest_lists = function(html)
    if type(html) ~= "string" then return end
    for attrs, inner in html:gmatch("<a%s([^>]-)>(.-)</a>") do
        local href = attrs:match('href="([^"]+)"') or attrs:match("href='([^']+)'")
        if href then
            local fam, slug = href:match("/(%a+)/([%w_%-]+)/%d+%.html")
            if not fam then fam, slug = href:match("/(%a+)/([%w_%-]+)/?$") end
            if fam and slug and disc[fam] then
                local label = strip_tags(inner)
                if label == "" or (#label <= 60 and not is_pager_label(label)) then
                    disc_add(fam, slug, label)
                end
            end
        end
    end
end

-- Cache disque (sefirah/69shu_filters.lua) : chargé au démarrage pour que tous les
-- filtres soient là dès l'ouverture, réécrit quand la découverte a trouvé du nouveau.
local function filters_cache_path()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok then return nil end
    return DataStorage:getSettingsDir() .. "/sefirah/69shu_filters.lua"
end

local function load_filters_cache()
    local path = filters_cache_path()
    if not path then return end
    local ok, t = pcall(dofile, path)
    if not ok or type(t) ~= "table" then return end
    for _, fam in ipairs(FAMILIES) do
        for _, e in ipairs(t[fam] or {}) do
            if type(e) == "table" and type(e[1]) == "string" and e[1] ~= "" then
                disc_add(fam, e[1], type(e[2]) == "string" and e[2] or "")
            end
        end
    end
    filters_dirty = false
end

local function save_filters_cache()
    if not filters_dirty then return end
    local lines, report = { "return {" }, { "Filtres découverts sur " .. BASE, "" }
    for _, fam in ipairs(FAMILIES) do
        lines[#lines + 1] = "  " .. fam .. " = {"
        report[#report + 1] = fam .. " (" .. FAMILY_NAME[fam] .. ") :"
        for _, slug in ipairs(disc[fam].order) do
            local label = disc[fam].label[slug] or ""
            lines[#lines + 1] = string.format("    { %q, %q },", slug, label)
            report[#report + 1] = string.format("  /%s/%s/N.html  %s", fam, slug, label)
        end
        lines[#lines + 1] = "  },"
        report[#report + 1] = ""
    end
    lines[#lines + 1] = "}"
    write_debug("69shu_filters.lua", table.concat(lines, "\n") .. "\n")
    write_debug("69shu_last_filters.txt", table.concat(report, "\n") .. "\n")
    filters_dirty = false
end

-- Identifiant d'option « famille/slug » (ex. « sort/xuanhuan ») ; accepte aussi
-- l'ancien format « sort_xuanhuan ». Renvoie famille, slug (défaut si invalide).
local function parse_list_id(id)
    local fam, slug = tostring(id or ""):match("^(%a+)[/_]([%w_%-]+)$")
    if fam and slug and disc[fam] then return fam, slug end
    return DEFAULT_LIST:match("^(%a+)/(.+)$")
end

local function list_url(fam, slug, page)
    return string.format("%s/%s/%s/%d.html", BASE, fam, slug, page)
end

-- Options du filtre « Liste » : listes confirmées + listes découvertes, par famille,
-- dans l'ordre du site.
local function build_options()
    local opts = {}
    for _, fam in ipairs(FAMILIES) do
        local seen, entries = {}, {}
        local function push(slug, label)
            if seen[slug] then return end
            seen[slug] = true
            entries[#entries + 1] = { slug = slug, label = label }
        end
        for _, c in ipairs(CONFIRMED[fam]) do
            push(c[1], (disc[fam].label[c[1]] ~= nil and disc[fam].label[c[1]] ~= "") and disc[fam].label[c[1]] or c[2])
        end
        for _, slug in ipairs(disc[fam].order) do
            local l = disc[fam].label[slug]
            push(slug, (l and l ~= "") and l or slug)
        end
        for _, e in ipairs(entries) do
            local hint  = hint_for(e.label)
            if hint then hint = T(hint) end
            local label = FAMILY_NAME[fam] .. " · " .. e.label .. (hint and (" (" .. hint .. ")") or "")
            opts[#opts + 1] = { id = fam .. "/" .. e.slug, label = label }
        end
    end
    return opts
end

-- Met à jour, EN PLACE, la liste d'options déjà déclarée dans ext.popularFilters
-- (ui/browse.lua relit ext.popularFilters à chaque ouverture de « Filtrer »).
local ext   -- déclarée ici, remplie juste après
local function refresh_filter_options()
    if ext and ext.popularFilters and ext.popularFilters[1] then
        ext.popularFilters[1].options = build_options()
    end
end

load_filters_cache()

ext = {
    id      = "69shu",
    name    = "69书吧",
    site    = BASE,
    lang    = "zh",
    version = "1.5.0",

    -- Le site n'a aucune section d'avis (page fiche vérifiée) : l'onglet « Avis »
    -- est masqué pour cette source uniquement (voir ui/detail.lua).
    hasReviews = false,

    -- Clavier de la recherche : pinyin (zh_CN) si KOReader l'a, sinon traits (zh).
    -- Restauré à la fermeture de la boîte (voir ui/browse.lua, use_source_keyboard).
    keyboardLayouts = { "zh_CN", "zh" },
    searchHint      = "请输入书名或作者名",   -- libellé du champ de recherche du site

    -- Filtres de l'écran « Parcourir » (contrat : ui/browse.lua, popularFilters).
    -- Un seul groupe : le site propose des LISTES (classements, catégories, terminés),
    -- une à la fois. Les options sont (re)construites par build_options().
    popularFilters = {
        {
            key     = "list",
            label   = "Liste",
            default = DEFAULT_LIST,
            options = {},
        },
    },
}
refresh_filter_options()

function ext:searchNovels(term, page)
    page = page or 1
    -- Le site n'expose pas de pagination de recherche : toute la réponse tient
    -- sur la « page 1 ». Sans ce garde-fou, ui/browse.lua enchaîne les pages
    -- source pour remplir l'écran et re-POSTe la même recherche jusqu'à 6 fois
    -- (résultats en double).
    if page > 1 then return { novels = {} } end

    local body, code = http_post_form(SEARCH_URL, {
        searchkey = url_encode(term),
    }, {
        ["Origin"]  = BASE,
        ["Referer"] = BASE .. "/",
    })
    if not body then
        return { novels = {},
                 error = "69shu : recherche impossible (" .. describe_failure(code) .. ")" }
    end

    local novels = parse_novel_list(body)
    if #novels == 0 then
        novels = parse_novel_list_loose(body, term)
    end
    logger.dbg("69shu: searchNovels term=", term, "found=", #novels)

    if #novels == 0 then
        dump_debug(body)
        logger.warn("69shu: searchNovels — 0 roman reconnu pour '" .. tostring(term) ..
            "' (" .. #body .. " octets reçus, copie dans sefirah/" .. DEBUG_FILE .. ")")
        local challenge = body:find("Just a moment", 1, true) or body:find("cf-chl", 1, true)
            or body:find("challenge-platform", 1, true)
        return { novels = {},
                 error = challenge
                     and "69shu : le site répond par un challenge anti-bot (Cloudflare), impossible à passer depuis KOReader"
                     or ("69shu : aucun roman reconnu dans la réponse (copie : sefirah/" .. DEBUG_FILE .. ")") }
    end
    return { novels = novels }
end

-- Découverte complémentaire : pour chaque famille (rank / sort / full) dont on n'a
-- vu AUCUN lien sur les pages déjà chargées (accueil, liste courante), on charge
-- sa page de base une fois par session pour y lire ses onglets. Au plus 3 requêtes,
-- seulement à la 1re page de liste, et un échec est simplement ignoré.
local function discover_missing_families()
    for _, fam in ipairs(FAMILIES) do
        local d = disc[fam]
        if #d.order < 2 and not discovery_tried[fam] then
            discovery_tried[fam] = true
            local base_slug = CONFIRMED[fam][1][1]
            local html = http_get(list_url(fam, base_slug, 1))
            if html then pcall(harvest_lists, html) end
        end
    end
end

-- Liste de navigation (écran affiché à l'ouverture de la source) : par défaut le
-- classement /rank/allvisit/<page>.html, sinon la liste choisie dans « Filtrer »
-- (id « famille/slug », voir build_options). Le gabarit de ces pages n'a pas été
-- vu en entier : parseur strict (cartes « book-coverlist ») puis parseur de
-- secours (liens /book/<id>).
function ext:popularNovels(page, options)
    page = page or 1
    local chosen   = options and options.filters and options.filters.list
    local fam, slug = parse_list_id(chosen)
    local url      = list_url(fam, slug, page)

    local html, fail = http_get(url)
    if not html then
        return { novels = {},
                 error = "69shu : liste indisponible (" .. describe_failure(fail) .. ")" }
    end

    -- La page est déjà là : on y lit gratuitement les autres listes du site.
    pcall(harvest_lists, html)
    if page == 1 then pcall(discover_missing_families) end
    if filters_dirty then
        refresh_filter_options()
        pcall(save_filters_cache)
    end

    local novels = parse_novel_list(html)
    if #novels == 0 then novels = parse_novel_list_loose(html, nil) end
    if #novels == 0 then
        dump_debug(html, "69shu_last_list.html")
        logger.warn("69shu: popularNovels — 0 roman reconnu pour", url,
            "(copie dans sefirah/69shu_last_list.html)")
        return { novels = {},
                 error = "69shu : aucun roman reconnu dans la liste (copie : sefirah/69shu_last_list.html)" }
    end
    return { novels = novels }
end

function ext:parseNovelMeta(path)
    local id = novel_id_from_path(path)
    if not id then
        logger.err("69shu: parseNovelMeta — id introuvable dans", tostring(path))
        return nil
    end
    local html = http_get(info_url_from_id(id))
    if not html then return nil end
    local meta = parse_meta(html)

    return {
        name           = meta.title,
        path           = path,
        cover          = meta.cover,
        summary        = meta.summary,
        author         = meta.author,
        total_chapters = parse_total_chapters(html),
    }
end

function ext:parseNovel(path)
    local id = novel_id_from_path(path)
    if not id then
        logger.err("69shu: parseNovel — id introuvable dans", tostring(path))
        return nil
    end

    local html = http_get(info_url_from_id(id))
    if not html then
        logger.err("69shu: parseNovel — échec fiche roman", tostring(path))
        return nil
    end
    local meta     = parse_meta(html)
    local chapters = parse_chapters_from_book_page(html)

    local total = parse_total_chapters(html)
    if total > 0 and #chapters < total then
        logger.warn("69shu: parseNovel —", #chapters, "chapitres récupérés sur", total,
            "annoncés (trou du milieu non géré, voir commentaire d'en-tête de 69shu.lua)")
    end

    return {
        name       = meta.title,
        path       = path,
        cover      = meta.cover,
        summary    = meta.summary,
        author     = meta.author,
        genres     = meta.genres,
        chapters   = chapters,
        totalPages = 1,
    }
end

function ext:parseChapter(path)
    local url = (path:match("^https?://") and path) or (BASE .. "/" .. path)
    local html = http_get(url)
    if not html then return T("<p>Erreur de récupération du chapitre.</p>") end

    -- NON CONFIRMÉ (voir commentaire d'en-tête) : aucune page de lecture
    -- réelle n'a été fournie. On essaie plusieurs sélecteurs usuels pour ce
    -- genre de thème, dans cet ordre, et on garde le premier qui matche.
    local content
        =  extract_div(html, '<div[^>]*id="content"')
        or extract_div(html, '<div[^>]*id="chaptercontent"')
        or extract_div(html, '<div[^>]*class="[^"]*content[^"]*"')
        or extract_div(html, '<div[^>]*class="[^"]*read%-content[^"]*"')

    if not content then
        logger.err("69shu: parseChapter — aucun sélecteur connu ne correspond pour", url,
            "(page de lecture jamais confirmée — envoie le HTML de cette page)")
        return T("<p>Impossible d'extraire le contenu du chapitre (sélecteur à confirmer).</p>")
    end

    content = content:gsub('<h1[^>]*>.-</h1>', '')
    content = content:gsub('<br%s*/?>', '\n')

    return content
end

return ext
