-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- extensions/kakuyomu.lua — Kakuyomu (カクヨム, https://kakuyomu.jp), romans japonais.
-- Source NOVEL (contrat : cf. extensions/royalroad.lua), écrite d'après de vraies
-- pages enregistrées (accueil, fiche d'une œuvre, page d'un épisode).
--
-- Chemins stockés (sans domaine) :
--   roman    : « works/<id> »                        (ex. works/16818622171970452623)
--   chapitre : « works/<id>/episodes/<id_épisode> »
--
-- Stratégie pour la liste des chapitres (vérifiée sur une vraie page d'épisode) :
--   la page d'un ÉPISODE (HTML classique, rendu côté serveur) contient la table des
--   matières COMPLÈTE de l'œuvre (<li class="widget-toc-episode">, avec les titres de
--   chapitres <li class="widget-toc-chapter">). On lit donc la fiche de l'œuvre pour
--   trouver le lien du 1er épisode, puis cette page-là. Si ça échoue, repli sur les
--   données Next.js de la fiche (__NEXT_DATA__ / __APOLLO_STATE__), non vérifiées
--   (les pages enregistrées n'en contiennent pas : les scripts avaient été retirés).
--
-- Épisodes « Kakuyomu Next » (cadenas) : réservés aux abonnés, leur texte n'est pas
-- accessible sans compte ; ils sont listés avec le préfixe « [Next] ».
--
-- Si le site répond par un refus, le code HTTP est affiché et la réponse est
-- enregistrée dans sefirah/kakuyomu_last_error.txt.

local logger = require("logger")
local T      = require("core.i18n").T

local BASE = "https://kakuyomu.jp"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local _plugin_dir = ((debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+/[^/]+%.lua$")) or "."
-- Chemin relatif (« plugins/sefirah.koplugin ») : on le rend absolu pour ne pas dépendre
-- du dossier courant du processus (sous-processus de téléchargement des couvertures).
if _plugin_dir:sub(1, 1) ~= "/" then
    local ok_l, l = pcall(require, "libs/libkoreader-lfs")
    local cwd = ok_l and l and l.currentdir and l.currentdir() or nil
    if cwd and cwd ~= "" then
        _plugin_dir = (_plugin_dir == ".") and cwd or (cwd .. "/" .. _plugin_dir)
    end
end
-- ── Couvertures ──────────────────────────────────────────────────────────────
-- Avant : le logo local passait TOUJOURS en premier, donc toutes les œuvres avaient la
-- même image. Maintenant, par ordre de préférence (essayées l'une après l'autre) :
--   1. la vraie couverture publiée par l'auteur/Next (adminCoverImageUrl, adminSquareImageUrl,
--      promotionalImageUrl) lue dans les données Next.js de la page ;
--   2. l'image de partage (og:image) que le site génère pour chaque œuvre.
-- Pas de repli sur le logo : s'il était mis en cache disque, il empêcherait ensuite
-- de récupérer la vraie couverture.
local COVER_FIELDS = { "adminCoverImageUrl", "adminSquareImageUrl", "promotionalImageUrl" }

local function clean_url(u)
    u = (u or ""):gsub("\\u0026", "&"):gsub("\\/", "/"):gsub("&amp;", "&")
    if u:match("^https?://") then return u end
    return nil
end

-- Parcourt le JSON __NEXT_DATA__ et renvoie { [id_œuvre] = { url1, url2, … } }.
local function scan_covers(html)
    local map = {}
    if not html or html == "" then return map end
    local raw = html:match('<script id="__NEXT_DATA__"[^>]*>(.-)</script>') or html
    local pos = 1
    while true do
        local _, e, id = raw:find('"__typename":"Work","id":"(%d+)"', pos)
        if not e then break end
        local nxt = raw:find('"__typename":"', e, true)
        local seg_end = math.min((nxt or (#raw + 1)) - 1, e + 900)
        local seg = raw:sub(e, seg_end)
        for _, field in ipairs(COVER_FIELDS) do
            local u = clean_url(seg:match('"' .. field .. '":"([^"]+)"'))
            if u then
                map[id] = map[id] or {}
                local dup = false
                for _, x in ipairs(map[id]) do if x == u then dup = true end end
                if not dup then map[id][#map[id] + 1] = u end
            end
        end
        pos = e + 1
    end
    return map
end

local function cover_for(id, real)
    local parts = {}
    if real then for _, u in ipairs(real) do parts[#parts + 1] = u end end
    if id then parts[#parts + 1] = "https://cdn-static.kakuyomu.jp/works/" .. id .. "/ogimage.png" end
    if #parts == 0 then return nil end
    return table.concat(parts, "\t")
end

-- Les couvertures déjà en cache disque (l'ancien logo identique pour toutes les œuvres)
-- sont supprimées UNE fois, pour que les vraies couvertures soient re-téléchargées.
pcall(function() require("core.db").purgeCoverCacheOnce("kakuyomu", "covers_v5") end)

-- ── Helpers ──────────────────────────────────────────────────────────────────
local function utf8_encode(cp)
    if not cp then return "" end
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function decode(s)
    s = (s or ""):gsub("&#x(%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8_encode(tonumber(d)) end)
    return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
        :gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&nbsp;", " "):gsub("&amp;", "&"))
end

local function text_of(html)
    html = (html or ""):gsub("<[^>]+>", " ")
    return (decode(html):gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function escape(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function attr(tag, name)
    name = name:gsub("%-", "%%-")
    return tag:match("%f[%w_%-]" .. name .. '%s*=%s*"([^"]*)"')
        or tag:match("%f[%w_%-]" .. name .. "%s*=%s*'([^']*)'")
end

local function url_encode(str)
    return (tostring(str):gsub("([^%w%-%.%_%~])", function(c) return string.format("%%%02X", c:byte()) end))
end

local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return data
end

local function dump_error(label, body)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local f = io.open(dir .. "/kakuyomu_last_error.txt", "wb")
        if f then f:write(label .. "\n\n" .. tostring(body):sub(1, 200000)); f:close() end
    end)
end

local last_http = nil

local function get_html(path)
    local url = path:match("^https?://") and path or (BASE .. "/" .. path:gsub("^/", ""))
    local body, code, extra = require("core.net").get(url, { headers = {
        ["User-Agent"] = UA,
        ["Accept"] = "text/html,application/xhtml+xml",
        ["Accept-Language"] = "ja,en;q=0.7",
        ["Referer"] = BASE .. "/",
    }, timeout = 20 })
    if body and #body > 2 then return body end
    last_http = tostring(code)
    dump_error("requête échouée : " .. url .. "\ncode : " .. tostring(code), type(extra) == "string" and extra or "")
    logger.warn("Kakuyomu: échec", url, tostring(code))
    return nil, last_http
end

-- ── Filtres de l'onglet Parcourir ────────────────────────────────────────────
-- order=weekly_ranking et genre_name=<GENRE> sont des paramètres vus tels quels dans
-- les liens de la page d'accueil ; les autres valeurs de tri sont celles du site.
local POPULAR_FILTERS = {
    {
        key = "order", label = T("Tri"), default = "weekly_ranking",
        options = {
            { id = "weekly_ranking",           label = T("Classement de la semaine") },
            { id = "popular",                  label = T("Popularité") },
            { id = "last_episode_published_at", label = T("Dernières mises à jour") },
            { id = "published_at",             label = T("Nouveautés") },
        },
    },
    {
        key = "genre", label = T("Genre"), default = "",
        options = {
            { id = "",          label = T("Tous") },
            { id = "FANTASY",   label = "Fantasy" },
            { id = "ACTION",    label = "Action" },
            { id = "SF",        label = "SF" },
            { id = "LOVE_STORY", label = "Love story" },
            { id = "ROMANCE",   label = "Romance" },
            { id = "DRAMA",     label = "Drama" },
            { id = "HORROR",    label = "Horror" },
            { id = "MYSTERY",   label = "Mystery" },
            { id = "NONFICTION", label = "Non-fiction" },
            { id = "HISTORY",   label = "History" },
            { id = "CRITICISM", label = "Criticism" },
            { id = "OTHERS",    label = "Others" },
        },
    },
}

local function build_search_url(page, term, filters)
    filters = filters or {}
    local q = {}
    if term and term ~= "" then q[#q + 1] = "q=" .. url_encode(term) end
    local order = filters.order
    if (not order or order == "") and not (term and term ~= "") then order = "weekly_ranking" end
    if order and order ~= "" then q[#q + 1] = "order=" .. url_encode(order) end
    if filters.genre and filters.genre ~= "" then q[#q + 1] = "genre_name=" .. url_encode(filters.genre) end
    if page and page > 1 then q[#q + 1] = "page=" .. page end
    return BASE .. "/search" .. (#q > 0 and ("?" .. table.concat(q, "&")) or "")
end

-- ── Listes ───────────────────────────────────────────────────────────────────
-- Fiche d'une œuvre dans une liste : un <h3> contenant le lien du titre
-- (<a title="…" href=".../works/<id>">) puis le lien de l'auteur (/users/<nom>).
local function parse_list_dom(html, covers)
    covers = covers or {}
    local novels, seen = {}, {}
    for h3 in html:gmatch("<h3[^>]*>(.-)</h3>") do
        local id
        local a_tag, a_inner
        for tag, inner in h3:gmatch("(<a%s[^>]-href%s*=%s*[^>]->)(.-)</a>") do
            local href = attr(tag, "href")
            local wid = href and href:match("/works/(%d+)$")
            if wid then id, a_tag, a_inner = wid, tag, inner; break end
        end
        if id and not seen[id] then
            seen[id] = true
            local title = attr(a_tag, "title")
            if not title or title == "" then title = text_of(a_inner) end
            local author
            for tag, inner in h3:gmatch("(<a%s[^>]-href%s*=%s*[^>]->)(.-)</a>") do
                local href = attr(tag, "href")
                if href and href:find("/users/", 1, true) then author = text_of(inner); break end
            end
            title = decode(title or "")
            if title ~= "" then
                novels[#novels + 1] = { name = title, path = "works/" .. id, cover = cover_for(id, covers[id]), author = author }
            end
        end
    end
    return novels
end

-- Repli : données Next.js (__APOLLO_STATE__) — l'ordre des résultats n'y est pas garanti.
local function apollo_state(html)
    local raw = html:match('<script id="__NEXT_DATA__"[^>]*>(.-)</script>')
    local data = raw and json_decode(raw)
    local ok, st = pcall(function() return data.props.pageProps.__APOLLO_STATE__ end)
    if ok and type(st) == "table" then return st end
    return nil
end

local function parse_list_apollo(html, covers)
    covers = covers or {}
    local st = apollo_state(html)
    if not st then return {} end
    local out = {}
    for key, w in pairs(st) do
        local id = type(key) == "string" and key:match("^Work:(%d+)$")
        if id and type(w) == "table" and type(w.title) == "string" then
            out[#out + 1] = { name = w.title, path = "works/" .. id, cover = cover_for(id, covers[id]) }
        end
    end
    table.sort(out, function(a, b) return a.path > b.path end)
    return out
end

local function list_page(url)
    local html = get_html(url)
    if not html then
        return { novels = {}, error = T("Kakuyomu injoignable (code ") .. tostring(last_http) .. ")" }
    end
    local covers = scan_covers(html)
    local novels = parse_list_dom(html, covers)
    if #novels == 0 then novels = parse_list_apollo(html, covers) end
    if #novels == 0 then dump_error("liste vide : " .. url, html) end
    return { novels = novels }
end

-- ── Fiche d'une œuvre ────────────────────────────────────────────────────────
local function parse_meta(html, path)
    local meta = {}
    local h1 = html:match("<h1[^>]*>(.-)</h1>")
    if h1 then
        local a = h1:match("<a[^>]*>")
        meta.title = (a and attr(a, "title")) or text_of(h1)
        meta.title = decode(meta.title or "")
    end
    if not meta.title or meta.title == "" then
        local t = html:match("<title[^>]*>(.-)</title>")
        if t then
            t = decode(t):gsub("%s*[%-–]%s*カクヨム.*$", ""):gsub("%s*[%(（][^%(%)（）]*[%)）]%s*$", "")
            meta.title = t
        end
    end

    -- Auteur : premier lien /users/… après le <h1>.
    local after = h1 and select(2, html:find("<h1[^>]*>.-</h1>")) or 1
    for tag, inner in html:sub(after or 1, (after or 1) + 6000):gmatch("(<a%s[^>]-href%s*=%s*[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and href:find("/users/", 1, true) then meta.author = text_of(inner); break end
    end

    -- Synopsis : accroche (première ligne) + texte complet du bloc repliable.
    local intro = html:match('<div[^>]-class="[^"]*CollapseTextWithKakuyomuLinks_collapseText[^"]*"[^>]*>(.-)</div>')
    local summary
    if intro then
        intro = intro:gsub("<br%s*/?>", "\n")
        summary = decode((intro:gsub("<[^>]+>", ""))):gsub("\n%s*\n%s*\n+", "\n\n"):match("^%s*(.-)%s*$")
    end
    if not summary or summary == "" then
        local d = html:match('<meta[^>]-name="description"[^>]-content="([^"]*)"')
            or html:match('<meta[^>]-property="og:description"[^>]-content="([^"]*)"')
        summary = d and decode(d) or ""
    end
    meta.summary = summary

    -- Tags (/tags/…), statut (連載中 / 完結済).
    local tags = {}
    for tag, inner in html:gmatch("(<a%s[^>]-href%s*=%s*[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and href:find("/tags/", 1, true) then
            local t = text_of(inner)
            if t ~= "" and #tags < 12 then tags[#tags + 1] = t end
        end
    end
    meta.genres = tags
    if html:find("完結済", 1, true) then meta.status = "Completed"
    elseif html:find("連載中", 1, true) then meta.status = "Ongoing" end
    return meta
end

-- Table des matières d'une page d'épisode (vérifiée sur une vraie page).
local function parse_toc(html, work_id)
    local chapters = {}
    local ol = html:match('<ol[^>]-class="[^"]*widget%-toc%-items[^"]*"[^>]*>(.-)</ol>')
    if not ol then return chapters end
    for li_tag, li in ol:gmatch("(<li[^>]->)(.-)</li>") do
        local cls = attr(li_tag, "class") or ""
        if cls:find("widget-toc-episode", 1, true) then
            local a = li:match("<a[^>]*>")
            local href = a and attr(a, "href")
            local eid = href and href:match("/episodes/(%d+)")
            if eid then
                local name = li:match('<span[^>]-class="[^"]*widget%-toc%-episode%-titleLabel[^"]*"[^>]*>(.-)</span>')
                name = decode(text_of(name or ""))
                if name == "" then name = "Episode " .. (#chapters + 1) end
                if (attr(a, "class") or ""):find("kakuyomu%-next") or li:find("kakuyomuNext-badge", 1, true) then
                    name = "[Next] " .. name
                end
                chapters[#chapters + 1] = {
                    name = name,
                    path = "works/" .. work_id .. "/episodes/" .. eid,
                    chapter_number = #chapters + 1,
                }
            end
        end
    end
    return chapters
end

-- Repli 1 : texte brut des données Next.js de la fiche (sans décoder le JSON) :
-- références « Episode:<id> » dans l'ordre, titres lus dans les objets « Episode:<id> ».
local function json_unescape(str)
    str = str:gsub("\\u(%x%x%x%x)", function(h) return utf8_encode(tonumber(h, 16)) end)
    return (str:gsub("\\(.)", function(c)
        if c == "n" then return "\n" elseif c == "t" or c == "r" then return " " end
        return c
    end))
end

local function chapters_from_raw(html, work_id)
    local ids, seen = {}, {}
    for id in html:gmatch('"__ref"%s*:%s*"Episode:(%d+)"') do
        if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
    if #ids == 0 then
        for id in html:gmatch('"Episode:(%d+)"%s*:%s*{') do
            if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
        end
    end
    local out = {}
    for _, id in ipairs(ids) do
        local pos = html:find('"Episode:' .. id .. '"%s*:%s*{')
        local title
        if pos then
            title = html:sub(pos, pos + 1200):match('"title"%s*:%s*"(.-)"%s*[,}]')
        end
        title = title and json_unescape(title) or ""
        if title == "" then title = "Episode " .. (#out + 1) end
        out[#out + 1] = {
            name = decode(title), path = "works/" .. work_id .. "/episodes/" .. id,
            chapter_number = #out + 1,
        }
    end
    return out
end

-- Repli 2 : tous les liens d'épisodes présents dans la fiche (dans l'ordre).
local function chapters_from_links(html, work_id)
    local out, seen = {}, {}
    for tag, inner in html:gmatch("(<a%s[^>]-href%s*=%s*[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        local eid = href and href:match("/works/" .. work_id .. "/episodes/(%d+)")
        if eid and not seen[eid] then
            seen[eid] = true
            local name = decode(text_of(inner))
            if name == "" then name = "Episode " .. (#out + 1) end
            out[#out + 1] = {
                name = name, path = "works/" .. work_id .. "/episodes/" .. eid,
                chapter_number = #out + 1,
            }
        end
    end
    return out
end

local function work_id_of(path)
    return tostring(path or ""):match("works/(%d+)")
end

local cache = {}   -- path -> { t = os.time(), data = … } (évite de refaire 2 requêtes d'affilée)

local function load_novel(path)
    local hit = cache[path]
    if hit and os.time() - hit.t < 90 then return hit.data end
    local wid = work_id_of(path)
    if not wid then return nil end
    local html = get_html("works/" .. wid)
    if not html then return nil end
    local meta = parse_meta(html, path)

    -- Plusieurs méthodes ; on garde celle qui trouve le plus de chapitres
    -- (la table des matières de la page d'épisode est préférée à égalité).
    local from_raw   = chapters_from_raw(html, wid)
    local from_links = chapters_from_links(html, wid)
    local from_apollo = {}
    do local ok, r = pcall(chapters_from_apollo, html, wid); if ok and r then from_apollo = r end end

    local first = (from_links[1] and from_links[1].path:match("/episodes/(%d+)"))
        or (from_raw[1] and from_raw[1].path:match("/episodes/(%d+)"))
        or html:match("/works/" .. wid .. "/episodes/(%d+)")
    local from_toc = {}
    if first then
        local ep_html = get_html("works/" .. wid .. "/episodes/" .. first)
        if ep_html then from_toc = parse_toc(ep_html, wid) end
    end

    local chapters = from_toc
    for _, cand in ipairs({ from_apollo, from_raw, from_links }) do
        if #cand > #chapters then chapters = cand end
    end
    if #chapters == 0 then
        dump_error(string.format(
            "aucun chapitre trouvé : works/%s\nhtml=%d octets ; __NEXT_DATA__=%s ; '/episodes/'=%d fois ; premier épisode=%s ; toc=%d apollo=%d raw=%d liens=%d",
            wid, #html, tostring(html:find("__NEXT_DATA__", 1, true) ~= nil),
            select(2, html:gsub("/episodes/", "")), tostring(first),
            #from_toc, #from_apollo, #from_raw, #from_links), html)
    end

    local data = {
        name = meta.title, path = "works/" .. wid, cover = cover_for(wid, scan_covers(html)[wid]),
        summary = meta.summary, author = meta.author, genres = meta.genres,
        status = meta.status, chapters = chapters, totalPages = 1,
    }
    cache[path] = { t = os.time(), data = data }
    return data
end

-- ── Extension ────────────────────────────────────────────────────────────────
local ext = {
    id      = "kakuyomu",
    name    = "Kakuyomu",
    site    = BASE,
    lang    = "ja",
    version = "0.1.2",
    popularFilters = POPULAR_FILTERS,
}

function ext:popularNovels(page, options)
    return list_page(build_search_url(page or 1, nil, options and options.filters))
end

function ext:searchNovels(term, page)
    return list_page(build_search_url(page or 1, term, nil))
end

function ext:parseNovelMeta(path)
    local d = load_novel(path)
    if not d then return nil end
    return {
        name = d.name, path = d.path, cover = d.cover, summary = d.summary,
        author = d.author, status = d.status, total_chapters = #d.chapters,
    }
end

function ext:parseNovel(path)
    return load_novel(path)
end

-- ── Avis (★ + texte) ─────────────────────────────────────────────────────────
-- Page : /works/<id>/reviews (paramètres connus : work_review_order=created_at_desc, page=N).
-- Les avis sont lus dans les données Next.js (__APOLLO_STATE__) : objets
-- « TextualWorkReview:<id> » avec title, body, point (1 à 3 ★), likeCount, textualCreatedAt
-- et reviewerUser (référence vers « UserAccount:… »). Seul created_at_desc est confirmé ;
-- les autres valeurs de tri sont des suppositions (repli sans paramètre si la page est vide),
-- et un tri local est de toute façon appliqué à chaque page.
local REVIEW_ORDER = { newest = "created_at_desc", oldest = "created_at_asc", mostliked = "like_count_desc" }
local review_seen = {}   -- wid -> { [id_avis] = true } (évite les doublons si le site ignore « page »)

local function reviews_from_apollo(html, wid)
    local st = apollo_state(html)
    if not st then return {} end
    local out = {}
    for key, r in pairs(st) do
        local id = type(key) == "string" and key:match("^TextualWorkReview:(%d+)$")
        if id and type(r) == "table" and type(r.body) == "string" and r.body ~= "" then
            local wref = type(r.work) == "table" and r.work.__ref or nil
            if not wref or wref == "Work:" .. wid then
                local ref = (type(r.reviewerUser) == "table" and r.reviewerUser.__ref)
                    or (type(r.reviewer) == "table" and r.reviewer.__ref)
                local u = ref and st[ref]
                local author = (type(u) == "table" and (u.activityName or u.name)) or T("Anonyme")
                local content = r.body:gsub("\r", ""):gsub("%s+$", "")
                local title = type(r.title) == "string" and r.title or ""
                if r.isSpoiler then title = "[" .. T("Spoiler") .. "] " .. title end
                if title ~= "" then content = title .. "\n\n" .. content end
                out[#out + 1] = {
                    id = id, author = author, rating = tonumber(r.point),
                    content = content, likes = tonumber(r.likeCount) or 0,
                    date = r.textualCreatedAt or r.createdAt,
                }
            end
        end
    end
    return out
end

function ext:parseReviews(path, page, sort)
    page = tonumber(page) or 1
    local wid = work_id_of(path)
    if not wid then return { reviews = {}, has_more = false } end
    if page == 1 then review_seen[wid] = {} end
    local seen = review_seen[wid] or {}
    review_seen[wid] = seen

    local function url_for(order)
        local q = {}
        if order then q[#q + 1] = "work_review_order=" .. order end
        if page > 1 then q[#q + 1] = "page=" .. page end
        return "works/" .. wid .. "/reviews" .. (#q > 0 and ("?" .. table.concat(q, "&")) or "")
    end

    local order = REVIEW_ORDER[sort or "newest"] or "created_at_desc"
    local html = get_html(url_for(order))
    local revs = html and reviews_from_apollo(html, wid) or {}
    if #revs == 0 and page == 1 and order ~= "created_at_desc" then
        html = get_html(url_for(nil))
        revs = html and reviews_from_apollo(html, wid) or {}
    end
    if #revs == 0 and page == 1 then
        -- Repli : les 2 derniers avis affichés sur la fiche de l'œuvre.
        local wh = get_html("works/" .. wid)
        revs = wh and reviews_from_apollo(wh, wid) or {}
        if #revs == 0 then
            if html then dump_error("avis vide : " .. url_for(order), html) end
            return { reviews = {}, has_more = false,
                error = html and nil or (T("Kakuyomu injoignable (code ") .. tostring(last_http) .. ")") }
        end
        html = nil
    end

    local fresh = {}
    for _, r in ipairs(revs) do
        if not seen[r.id] then seen[r.id] = true; fresh[#fresh + 1] = r end
    end

    local mode = sort or "newest"
    table.sort(fresh, function(a, b)
        if mode == "mostliked" and a.likes ~= b.likes then return a.likes > b.likes end
        local da, db = a.date or "", b.date or ""
        if mode == "oldest" then return da < db end
        return da > db
    end)

    local has_more = false
    if html and #fresh > 0 then
        has_more = html:find("page=" .. (page + 1), 1, true) ~= nil or #fresh >= 10
    end
    return { reviews = fresh, has_more = has_more }
end

-- Texte d'un épisode : <div class="widget-episodeBody …"> contenant uniquement des
-- <p id="pN"> (les lignes vides sont <p class="blank"><br></p>). Pas de <div>
-- imbriqué, donc le premier </div> clôture le corps.
function ext:parseChapter(path)
    local html = get_html(path)
    if not html then return "<p>" .. escape(T("Impossible de charger l'épisode.")) .. "</p>" end

    local body = html:match('<div[^>]-class="[^"]*widget%-episodeBody[^"]*"[^>]*>(.-)</div>')
    if not body or body == "" then
        if html:find("kakuyomuNext", 1, true) or html:find("js-promote-enter-kakuyomu-next", 1, true) then
            return "<p>" .. escape(T("Épisode réservé aux abonnés Kakuyomu Next.")) .. "</p>"
        end
        dump_error("corps d'épisode introuvable : " .. path, html)
        return "<p>" .. escape(T("Impossible d'extraire le texte de l'épisode.")) .. "</p>"
    end

    local out = {}
    local title = html:match('<p[^>]-class="[^"]*widget%-episodeTitle[^"]*"[^>]*>(.-)</p>')
    title = title and text_of(title) or ""
    if title ~= "" then out[#out + 1] = "<h3>" .. escape(title) .. "</h3>" end

    local blank = false
    for p_tag, inner in body:gmatch("(<p[^>]*>)(.-)</p>") do
        local cls = attr(p_tag, "class") or ""
        inner = inner:gsub("<rp>.-</rp>", ""):gsub("<rt>.-</rt>", "")
        local txt = decode((inner:gsub("<br%s*/?>", "\n"):gsub("<[^>]+>", "")))
        txt = txt:gsub("^%s+", ""):gsub("%s+$", "")
        if cls:find("blank", 1, true) or txt == "" then
            if not blank then out[#out + 1] = "<p>&#160;</p>"; blank = true end
        else
            out[#out + 1] = "<p>" .. escape(txt):gsub("\n", "<br/>") .. "</p>"
            blank = false
        end
    end
    return table.concat(out, "\n")
end

return ext
