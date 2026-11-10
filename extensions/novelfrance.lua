-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- novelfrance.lua
-- Extension Sefirah pour https://novelfrance.fr
--
-- NovelFrance est une app Next.js qui embarque ses données (novel, liste de
-- chapitres, contenu du chapitre) sous forme de JSON dans le payload React
-- Server Components (les balises <script>self.__next_f.push([1,"..."])</script>).
-- On extrait ce JSON directement plutôt que de parser le HTML rendu, ce qui
-- est beaucoup plus fiable que du regex sur des classes Tailwind.
--
-- La liste complète des chapitres est récupérée via l'API JSON interne du
-- site (trouvée dans l'onglet Network des DevTools) :
--   GET /api/chapters/<slug>?skip=N&take=50&order=asc
--   -> { chapters: [...], total, skip, take, order, hasMore }
-- On boucle en incrémentant skip de 50 jusqu'à hasMore = false. C'est du
-- JSON standard, pas besoin de dé-échapper quoi que ce soit ici.
--
-- CHAPITRES VERROUILLÉS : les chapitres avec "isPremium": true sont
-- marqués locked = true et ne sont jamais téléchargés/affichés. C'est
-- volontaire : ce sont des chapitres en avance réservés aux abonnés
-- Premium de NovelFrance, cette extension ne cherche pas à les contourner.

local logger = require("logger")
local Epub   = require("core.epub")

local BASE = "https://novelfrance.fr"

-- ---------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------

local function http_get(url)
    -- Les pages NovelFrance/RSC peuvent répondre lentement sur la Kobo.
    -- Une seule requête avec timeout court évite de bloquer longtemps l'interface.
    -- Toujours renvoyer nil + erreur en cas d'échec : les appelants doivent
    -- conserver le cache au lieu de traiter une réponse réseau absente comme
    -- une liste de chapitres vide.
    local ok, body, code = pcall(function()
        local response, status = require("core.net").get(url, {
            headers = { ["Accept"] = "text/html,application/xhtml+xml,*/*;q=0.8" },
            timeout = 12,
        })
        return response, status
    end)
    if not ok then
        logger.err("novelfrance: http_get exception:", url, tostring(body))
        return nil, body
    end
    if not body then
        logger.err("novelfrance: http_get failed:", url, tostring(code))
        return nil, code
    end
    return body
end

-- Fiche d'un roman : parseNovelMeta puis parseNovel la demandent coup sur coup
-- (même page, lourde). On la garde 2 minutes en mémoire pour ne la télécharger
-- qu'une seule fois à l'ouverture d'un roman.
local page_memo = {}
local function http_get_page(url)
    local now = os.time()
    local m = page_memo[url]
    if m and now - m.t < 120 then return m.body end
    local body, err = http_get(url)
    if body then
        page_memo = { [url] = { t = now, body = body } }   -- une seule entrée gardée
    end
    return body, err
end

-- Trace des échecs : sefirah/novelfrance_last_error.txt (dossier des réglages de KOReader).
local function save_last_error(what, url, body)
    pcall(function()
        local dir = require("datastorage"):getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local f = io.open(dir .. "/novelfrance_last_error.txt", "wb")
        if f then
            f:write(os.date("%Y-%m-%d %H:%M:%S"), "\n", tostring(what), "\n", tostring(url), "\n",
                "taille : ", tostring(body and #tostring(body) or 0), "\n\n",
                tostring(body or ""):sub(1, 60000))
            f:close()
        end
    end)
end

local function url_encode(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- ---------------------------------------------------------------------
-- JSON helpers
-- ---------------------------------------------------------------------

local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return data
end

-- The RSC payload is a JS string literal, so quotes/backslashes inside it
-- are escaped (\" and \\). Undo that so the fragment becomes valid JSON.
local function unescape_js(s)
    if not s then return nil end
    return (s:gsub("\\(.)", function(c)
        if c == "n" then return "\n"
        elseif c == "t" then return "\t"
        elseif c == "r" then return "\r"
        elseif c == '"' then return '"'
        elseif c == "\\" then return "\\"
        elseif c == "/" then return "/"
        -- Conserver les échappements JSON inconnus (notamment \uXXXX) :
        -- le décodeur JSON doit encore les voir pour restaurer les accents.
        else return "\\" .. c end
    end))
end

-- Find `\"<key>\":{ ... }` in the raw (still-escaped) HTML and return the
-- balanced {...} substring, still escaped. Returns nil if not found.
local function find_balanced_json_object(text, key, needle)
    if not text then return nil end
    needle = needle or ('"' .. key .. '":{')
    local s, e = text:find(needle, 1, true)
    if not s then return nil end

    -- Ne pas utiliser %%b{} ici : la description peut elle-même contenir des
    -- accolades. On parcourt donc le JSON en respectant les chaînes JSON et
    -- leurs échappements.
    local start = e
    local depth = 0
    local in_string = false
    local escaped = false
    for i = start, #text do
        local c = text:sub(i, i)
        if in_string then
            if escaped then
                escaped = false
            elseif c == "\\" then
                escaped = true
            elseif c == '"' then
                in_string = false
            end
        else
            if c == '"' then
                in_string = true
            elseif c == '{' then
                depth = depth + 1
            elseif c == '}' then
                depth = depth - 1
                if depth == 0 then
                    return text:sub(start, i)
                end
            end
        end
    end
    return nil
end

-- Compatibilité avec l'ancien payload HTML brut : dans certains builds Next.js
-- le JSON de initialNovel reste directement dans la chaîne échappée.
local function find_json_object(html, key)
    local raw = find_balanced_json_object(html, key, '\\"' .. key .. '\\":{')
    if raw then return raw end
    return find_balanced_json_object(html, key)
end

-- Extrait tout le flux texte Flight de Next.js. On cherche .push([1,"...")
-- plutôt qu'une forme exacte de self.__next_f, car Next.js change parfois le
-- préfixe généré autour de __next_f.
local function extract_rsc_push_strings(html)
    local chunks = {}
    local pos = 1
    local marker = '.push([1,"'
    while true do
        local a = html:find(marker, pos, true)
        if not a then break end
        local i = a + #marker
        local out = {}
        while i <= #html do
            local c = html:sub(i, i)
            if c == '"' then
                local bs = 0
                local j = i - 1
                while j >= 1 and html:sub(j, j) == "\\" do
                    bs = bs + 1
                    j = j - 1
                end
                if bs % 2 == 0 then break end
            end
            out[#out + 1] = c
            i = i + 1
        end
        chunks[#chunks + 1] = unescape_js(table.concat(out))
        pos = math.max(i + 1, a + 1)
    end
    return chunks
end

local function build_rsc_stream(html)
    return table.concat(extract_rsc_push_strings(html), "")
end

-- Fetch a page and decode a named JSON object from its RSC payload.
-- Important : on NovelFrance, initialNovel can be split over several Flight
-- rows. We therefore search the decoded Flight stream first, then only use the
-- old raw-HTML fallback if necessary.
local function fetch_json_field(url, key)
    local html, err = http_get(url)
    if not html then return nil, err end

    local stream = build_rsc_stream(html)
    local raw_stream = find_balanced_json_object(stream, key)
    if raw_stream then
        local decoded = json_decode(raw_stream)
        if decoded then return decoded end
    end

    local raw = find_json_object(html, key)
    if not raw then return nil, "field_not_found" end
    return json_decode(unescape_js(raw))
end

local function escape_html(s)
    if not s then return "" end
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Le champ "description" renvoyé par l'API (initialNovel.description) est
-- stocké en HTML côté site (balises <p>/<br>, entités &...;) — normal sur
-- le site lui-même qui le rend tel quel dans le navigateur, mais affiché
-- BRUT (balises visibles, entités non décodées) une fois collé tel quel
-- dans un TextBoxWidget côté lecteur (cf. ui/detail.lua, résumé "buggé"
-- signalé le 2026-09-13). On réutilise Epub.html_to_text (déjà éprouvé pour
-- le corps des chapitres) pour obtenir le même texte propre que celui
-- affiché par le site — sans effet si la chaîne était déjà du texte brut
-- (aucune balise/entité à traiter).
-- Next.js Flight peut externaliser les longues chaînes dans des lignes
-- `id:T<hexlen>,<texte>`.  Les champs de initialNovel peuvent alors contenir
-- une référence `$<id>` au lieu du texte réel.  L'ancien parseur décodait le
-- JSON mais ne résolvait pas ces références, ce qui laissait apparaître des
-- morceaux comme `34:T622,\"]self.__next_f.push(...)` sur la liseuse.
local function build_rsc_text_rows(html)
    local stream = build_rsc_stream(html)
    local rows = {}
    local pos = 1
    while pos <= #stream do
        local s, e, id, hexlen = stream:find("([0-9a-zA-Z]+):T([0-9a-fA-F]+),", pos)
        if not s then break end
        local len = tonumber(hexlen, 16)
        if not len then
            pos = e + 1
        else
            local data_start = e + 1
            local data_end = data_start + len - 1
            if data_end > #stream then
                break
            end
            rows[id] = stream:sub(data_start, data_end)
            pos = data_end + 1
        end
    end
    return rows
end

local function resolve_rsc_string(s, rows)
    if type(s) ~= "string" or not rows then return s end
    local out = s
    -- Une référence peut elle-même pointer vers une autre ligne. Limite basse
    -- volontaire pour éviter toute boucle si NovelFrance envoie une référence
    -- cyclique ou malformée.
    for _ = 1, 8 do
        local changed = false
        out = out:gsub("%$([0-9a-zA-Z]+)", function(id)
            local v = rows[id]
            if v ~= nil then
                changed = true
                return v
            end
            return "$" .. id
        end)
        if not changed then break end
    end
    return out
end

local function clean_summary(s, rsc_rows)
    if not s or s == "" then return "" end
    s = resolve_rsc_string(s, rsc_rows)
    -- Filet de sécurité : une version du site peut encore laisser une ligne
    -- Flight au début de la valeur. On la retire avant le décodage HTML.
    s = s:gsub("^%s*%d+:T[0-9a-fA-F]+,", "")
    s = s:gsub("^%s*%$[0-9a-zA-Z]+%s*$", "")
    local ok, cleaned = pcall(Epub.html_to_text, s)
    if ok and type(cleaned) == "string" then
        cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
        return cleaned
    end
    return s
end

local STATUS_MAP = {
    ONGOING   = "Ongoing",
    COMPLETED = "Completed",
    HIATUS    = "Hiatus",
    CANCELLED = "Cancelled",
}

local CHAPTERS_PER_PAGE = 50

-- ---------------------------------------------------------------------
-- Classements (/rankings)
-- ---------------------------------------------------------------------
--
-- https://novelfrance.fr/rankings affiche 2 rangées d'onglets : catégorie
-- (Général/Mieux notés/Plus lus/Populaires/Discutés) et période (Semaine/
-- Mois/Tout temps). Confirmé par captures Network d'un utilisateur réel
-- (2026-09-10, deux séries de captures) :
--
--   GET /api/rankings/weekly?skip=0&take=20            -- "Plus lus" + "Semaine"
--   GET /api/rankings/monthly?skip=0&take=20            -- "Plus lus" + "Mois"
--   GET /api/rankings/all-time?skip=0&take=20            -- "Plus lus" + "Tout temps"
--   GET /api/rankings/most-rated?skip=0&take=20          -- "Mieux notés" (période ignorée, PAS de &period=)
--   GET /api/rankings/most-bookmarked?skip=0&take=20&period=weekly  -- "Populaires"
--   GET /api/rankings/most-discussed?skip=0&take=20&period=weekly  -- "Discutés"
--   -> { novels: [...], total: N }, entrées plates (title, slug, coverImage,
--      author, rating, views, totalViews, _count.chapters, rank, ...).
--
-- Donc DEUX mécaniques différentes pour la période selon la catégorie :
--   - "Plus lus" : la période EST le segment de chemin (weekly/monthly/all-time),
--     pas de paramètre séparé.
--   - "Populaires"/"Discutés" : chemin fixe (most-bookmarked/most-discussed),
--     période en paramètre `&period=weekly|monthly|all-time`.
--   - "Mieux notés" : chemin fixe (most-rated), PAS de paramètre période du
--     tout (confirmé : même requête quelle que soit la période affichée).
-- resolve_ranking_api() ci-dessous encode ces trois cas.
--
-- ⚠️ "Général" (combiné) : pas de requête XHR observée sur le site pour ce
-- cas. Reconstruit LOCALEMENT à la place (moyenne des positions dans les 4
-- classements ci-dessus) — voir compute_general() plus bas pour le détail.
-- Si tu trouves un jour la vraie URL du site pour "Général", dis-le-moi et
-- on pourra basculer dessus (plus fiable qu'une reconstruction locale).
local RANKING_CATEGORIES = {
    { id = "general",         label = "Général" },
    { id = "top_rated",       label = "Mieux notés (toute période)" },
    { id = "most_read",       label = "Plus lus" },
    { id = "popular",         label = "Populaires" },
    { id = "most_discussed",  label = "Discutés" },
}
local RANKING_PERIODS = {
    { id = "week",  label = "Semaine" },
    { id = "month", label = "Mois" },
    { id = "all",   label = "Tout temps" },
}

-- id de période interne -> segment/valeur d'API confirmé.
local PERIOD_API = { week = "weekly", month = "monthly", all = "all-time" }

-- (catégorie, période) -> (segment de chemin /api/rankings/<segment>,
-- paramètre de query string additionnel ou nil, confirmé ou deviné).
local function resolve_ranking_api(category_id, period_id)
    local period_seg = PERIOD_API[period_id] or "weekly"
    if category_id == "most_read" then
        return period_seg, nil, true
    elseif category_id == "top_rated" then
        return "most-rated", nil, true
    elseif category_id == "popular" then
        return "most-bookmarked", "&period=" .. period_seg, true
    elseif category_id == "most_discussed" then
        return "most-discussed", "&period=" .. period_seg, true
    end
    -- N'est normalement jamais atteint pour category_id == "general" : ce cas
    -- est intercepté plus tôt dans ext:popularNovels (voir compute_general).
    -- Filet de sécurité pour un id de catégorie inconnu.
    return "most-rated", nil, true
end

-- Essaie plusieurs noms de clé RSC possibles pour le JSON embarqué dans la
-- page HTML /rankings (utilisé uniquement en dernier repli, quand l'API JSON
-- directe /api/rankings/<slug> échoue) — liste de suppositions par ordre de
-- plausibilité (même convention que `initialNovel`/`initialChapter` ailleurs
-- dans ce fichier).
local RANKING_JSON_KEYS = { "initialRankings", "rankingsData", "rankings", "searchResults" }

local function find_rankings_json(html)
    for _, key in ipairs(RANKING_JSON_KEYS) do
        local raw = find_json_object(html, key)
        if raw then
            local data = json_decode(unescape_js(raw))
            if data then return data, key end
        end
    end
    return nil, nil
end

-- Un item de classement peut être une entrée "plate" (title/slug directement
-- dessus — confirmé pour /api/rankings/<type>) ou imbriquée sous `.novel`
-- (au cas où la forme diffère sur la page /rankings servie en repli) — on
-- gère les deux défensivement.
local function ranking_item_to_novel(item)
    local n = item.novel or item
    if not n or not n.slug then return nil end
    return {
        name   = n.title,
        path   = "/novel/" .. n.slug,
        cover  = n.coverImage and (BASE .. n.coverImage) or nil,
        author = n.author,
    }
end

-- ---------------------------------------------------------------------
-- "Général" reconstruit localement (aucun endpoint confirmé pour ce cas —
-- voir le commentaire au-dessus de RANKING_CATEGORIES) : moyenne des
-- positions dans les 4 classements confirmés (Mieux notés, Plus lus,
-- Populaires, Discutés). Chaque sous-liste est ramenée à un score
-- normalisé 0..1 selon le RANG (1er = 1.0, dernier récupéré = 0.0) plutôt
-- que la valeur brute, pour pouvoir moyenner des métriques d'échelles très
-- différentes (note sur 5, vues, favoris, messages) sans qu'une écrase les
-- autres. Un roman absent d'une sous-liste compte pour 0 sur celle-ci
-- (pénalise plutôt que d'ignorer, pour éviter qu'un roman visible dans une
-- seule petite liste de niche ne monte artificiellement en tête).
--
-- Semaine : PAS de requête "weekly" dédiée pour ce calcul — on réutilise les
-- données "Mois" (divisées par 4, comme demandé) pour éviter 3 requêtes
-- API en plus. Note honnête : cette division ne change PAS l'ordre final —
-- diviser une liste entière par la même constante ne modifie pas son
-- classement interne (le score normalisé par rang serait strictement
-- identique avec ou sans la division). Elle est appliquée quand même sur
-- la valeur brute, uniquement par cohérence avec ce qui a été demandé.
local GENERAL_FETCH_N   = 40  -- profondeur récupérée par sous-classement
local GENERAL_CACHE_TTL = 600 -- secondes ; évite de tout re-fetcher à chaque page tournée
local GENERAL_CACHE = {}      -- [period_id] = { items = {...}, ts = os.time() }

local function fetch_ranking_list(path, extra_qs, n)
    local url = string.format("%s/api/rankings/%s?skip=0&take=%d%s", BASE, path, n, extra_qs or "")
    local body = http_get(url)
    local data = body and json_decode(body)
    if not data or not data.novels then return {} end
    return data.novels
end

local function compute_general(period_id)
    local now = os.time()
    local cached = GENERAL_CACHE[period_id]
    if cached and (now - cached.ts) < GENERAL_CACHE_TTL then
        return cached.items
    end

    local sub_seg = PERIOD_API[period_id] or "weekly"
    local views = fetch_ranking_list(sub_seg, nil, GENERAL_FETCH_N)
    if #views == 0 and period_id == "week" then
        -- Le classement hebdomadaire n'a rien renvoyé : repli sur le mois
        -- plutôt que d'afficher un « Général » vide ou faussé.
        sub_seg = "monthly"
        views = fetch_ranking_list(sub_seg, nil, GENERAL_FETCH_N)
    end

    local lists = {
        fetch_ranking_list("most-rated", nil, GENERAL_FETCH_N),
        views,
        fetch_ranking_list("most-bookmarked", "&period=" .. sub_seg, GENERAL_FETCH_N),
        fetch_ranking_list("most-discussed", "&period=" .. sub_seg, GENERAL_FETCH_N),
    }

    local scores = {} -- [slug] = { total = N, novel = {...} }
    for _, list in ipairs(lists) do
        local n = #list
        if n > 0 then
            for i, item in ipairs(list) do
                if item.slug then
                    local rank_score = (n > 1) and ((n - i) / (n - 1)) or 1 -- 1er = 1.0, dernier = 0.0
                    local entry = scores[item.slug]
                    if not entry then
                        entry = { total = 0, novel = ranking_item_to_novel(item) }
                        scores[item.slug] = entry
                    end
                    entry.total = entry.total + rank_score
                end
            end
        end
    end

    local merged = {}
    for _, entry in pairs(scores) do
        if entry.novel then
            entry.avg = entry.total / #lists -- sur 4 classements ; absence d'une liste = 0 sur celle-ci
            table.insert(merged, entry)
        end
    end
    table.sort(merged, function(a, b) return a.avg > b.avg end)

    local items = {}
    for _, entry in ipairs(merged) do table.insert(items, entry.novel) end

    GENERAL_CACHE[period_id] = { items = items, ts = now }
    return items
end

-- Loop over the internal chapters API until every chapter has been fetched.
-- Returns a plain array of raw chapter objects (title, slug, chapterNumber,
-- isPremium, ...), or {} on failure.
-- Ce tableau est utilisé TEL QUEL comme liste de chapitres à exporter
-- (ui/export.lua -> ctx.chapters -> Epub.export), sans être re-trié avant
-- l'écriture de l'EPUB — l'ordre renvoyé ici EST l'ordre du fichier final.
-- On récupère toujours les pages en order=asc (skip stable même si de
-- nouveaux chapitres sont publiés pendant la boucle — cf. le gros
-- commentaire sur parsePage plus bas), puis on inverse le tableau une fois
-- complet pour renvoyer les chapitres du plus récent au plus ancien.
-- Récupère les chapitres à partir de l'index `skip` (0 = tout), en ordre croissant.
-- Renvoie (liste, total_annoncé) — ou (nil, erreur) si la liste est INCOMPLÈTE parce
-- qu'une requête a échoué. Avant, un échec en cours de route (« wantread »,
-- « connection refused »…) renvoyait silencieusement la liste partielle, qui était
-- ensuite enregistrée dans le cache comme si elle était complète : les chapitres
-- manquants ne revenaient plus jamais à l'actualisation.
local function fetch_chapters_from(slug, skip)
    local chapters = {}
    skip = tonumber(skip) or 0
    local take = 500
    local announced
    local function page_url()
        return string.format("%s/api/chapters/%s?skip=%d&take=%d&order=asc",
            BASE, slug, skip, take)
    end
    for _ = 1, 200 do
        local body, err = http_get(page_url())
        local data = body and json_decode(body)
        -- Le site plafonne/refuse peut-être les grosses pages (réponse 4xx ou JSON
        -- inattendu) : on retombe sur 50. Une erreur RÉSEAU (texte : refused,
        -- wantread…) n'est PAS un motif de repli — le réessai est fait par core.net.
        local refused = (not body and type(err) == "number" and err >= 400 and err < 500)
        if (refused or (body and not (data and data.chapters))) and take > CHAPTERS_PER_PAGE then
            take = CHAPTERS_PER_PAGE
            body, err = http_get(page_url())
            data = body and json_decode(body)
        end
        if not body then
            logger.err("novelfrance: chapitres incomplets, échec à skip=", skip, tostring(err))
            return nil, err or "network"
        end
        if not data or not data.chapters then
            logger.err("novelfrance: JSON invalide à skip=", skip)
            return nil, "invalid_json"
        end
        for _, c in ipairs(data.chapters) do
            chapters[#chapters + 1] = c
        end
        announced = tonumber(data.total) or announced
        if not data.hasMore or #data.chapters == 0 then
            return chapters, announced
        end
        skip = skip + #data.chapters
        -- Courte pause entre deux pages : une rafale de requêtes d'affilée est ce
        -- qui faisait refuser la connexion sur les très longs romans.
        pcall(function() require("socket").sleep(0.2) end)
    end
    return nil, "too_many_pages"
end

local function map_chapter(base_path, c)
    return {
        name           = c.title,
        path           = base_path .. "/" .. c.slug,
        chapter_number = c.chapterNumber,
        date           = c.publishedAt or c.createdAt or c.date or c.updatedAt,
        locked         = c.isPremium or nil,
    }
end

-- Liste complète, la plus récente en premier (ordre attendu par l'interface).
-- Renvoie nil, erreur si elle n'a pas pu être récupérée en entier.
local function fetch_all_chapters(slug)
    local chapters, err = fetch_chapters_from(slug, 0)
    if not chapters then return nil, err end
    local reversed = {}
    for i = #chapters, 1, -1 do
        reversed[#reversed + 1] = chapters[i]
    end
    return reversed
end

-- ---------------------------------------------------------------------
-- Extension
-- ---------------------------------------------------------------------

local ext = {
    id      = "novelfrance",
    name    = "NovelFrance",
    site    = BASE,
    lang    = "fr",
    version = "1.1.0",
    review_cache_rev = 1,
    maxReviews = 150, -- limite d'avis affichés (même valeur pour toutes les extensions) : au-delà, plus de page à droite
}

-- Lu par sefirah.koplugin/ui/browse.lua : affiche l'icône de tri sur
-- l'onglet Parcourir → Populaire et construit l'écran de filtres à deux
-- colonnes (Catégorie / Période) + bouton Appliquer. La sélection est
-- renvoyée dans `options.filters = { category = <id>, period = <id> }` à
-- ext:popularNovels, qui les combine via resolve_ranking_api() (voir le
-- commentaire au-dessus de RANKING_CATEGORIES — la période n'a d'effet
-- réel que pour la catégorie "Plus lus").
ext.popularFilters = {
    {
        key     = "category",
        label   = "Catégorie",
        default = "general", -- même vue que le site par défaut (Général + Semaine)
        options = (function()
            local o = {}
            for _, c in ipairs(RANKING_CATEGORIES) do
                table.insert(o, { id = c.id, label = c.label })
            end
            return o
        end)(),
    },
    {
        key     = "period",
        label   = "Période",
        default = "week",
        options = (function()
            local o = {}
            for _, p in ipairs(RANKING_PERIODS) do
                table.insert(o, { id = p.id, label = p.label })
            end
            return o
        end)(),
    },
}

-- Onglet Parcourir → Populaire = page /rankings du site (Hall of Fame).
-- Voir le commentaire au-dessus de RANKING_CATEGORIES pour le détail de ce
-- qui est confirmé (weekly/monthly/most-rated) et deviné (le reste).
function ext:popularNovels(page, options)
    local filters   = options and options.filters
    local category  = (filters and filters.category) or "top_rated"
    local period    = (filters and filters.period) or "week"

    -- take=6 : voir le commentaire plus bas ; s'applique aussi ici pour la
    -- pagination du classement "Général" reconstruit localement.
    local take = 6
    local skip = ((page or 1) - 1) * take

    if category == "general" then
        local items = compute_general(period)
        local novels = {}
        for i = skip + 1, math.min(#items, skip + take) do
            table.insert(novels, items[i])
        end
        return { novels = novels }
    end

    local path, extra_qs, confirmed = resolve_ranking_api(category, period)

    -- 6, PAS 20 : l'app (sefirah.koplugin/ui/browse.lua) affiche 6 romans par
    -- page en mode grille (2 rangées × 3 colonnes) et enchaîne automatiquement
    -- plusieurs appels à popularNovels(page, ...) si un seul n'en fournit pas
    -- assez pour remplir l'écran — mais elle ne redécoupe PAS un lot trop
    -- grand renvoyé par un seul appel. Avec take=20, le 1er appel renvoyait à
    -- lui seul de quoi remplir l'écran (20 ≥ 6), donc l'app considérait cette
    -- tranche de 20 comme "consommée" en entier et repartait de skip=20 pour
    -- la page suivante — les romans 7 à 20 n'étaient jamais affichés, cassant
    -- la continuité 1-6 / 7-12 / 13-18 attendue. En alignant take sur la
    -- taille d'une page d'écran, chaque appel = exactement une page app.
    local url  = string.format("%s/api/rankings/%s?skip=%d&take=%d%s", BASE, path, skip, take, extra_qs or "")

    local body = http_get(url)
    local data = body and json_decode(body)

    -- « Semaine » indisponible côté API (liste vide dès la 1re page) : repli
    -- sur « Mois » pour les catégories qui dépendent de la période.
    if skip == 0 and period == "week" and category ~= "top_rated"
       and (not data or not data.novels or #data.novels == 0) then
        local p2, q2 = resolve_ranking_api(category, "month")
        logger.warn("novelfrance: classement hebdomadaire vide, repli sur le mois")
        url  = string.format("%s/api/rankings/%s?skip=%d&take=%d%s", BASE, p2, skip, take, q2 or "")
        body = http_get(url)
        data = body and json_decode(body)
    end

    if (not data or not data.novels) and not confirmed then
        -- Repli : "most-rated" est CONFIRMÉ fonctionner (200 OK observé en
        -- capture réelle), contrairement au slug deviné ("general", pour
        -- l'instant le seul cas encore non confirmé). Mieux vaut afficher
        -- "Mieux notés" que rien du tout.
        logger.warn("novelfrance: /api/rankings/" .. path ..
            " a échoué ou renvoyé un JSON inattendu, repli sur most-rated")
        body = http_get(string.format("%s/api/rankings/most-rated?skip=%d&take=%d", BASE, skip, take))
        data = body and json_decode(body)
    end

    if not data or not data.novels then
        -- Repli n°2, dernier recours : page /rankings rendue côté serveur
        -- (RSC) — la forme du JSON qu'elle embarque n'est pas confirmée
        -- (voir RANKING_JSON_KEYS plus haut), donc ce chemin peut lui aussi
        -- échouer silencieusement.
        logger.warn("novelfrance: repli most-rated aussi en échec, tentative sur la page /rankings")
        local html, err2 = http_get(BASE .. "/rankings")
        if not html then
            logger.err("novelfrance: popularNovels — repli /rankings a aussi échoué", tostring(err2))
            return { novels = {} }
        end
        data = find_rankings_json(html)
        if not data then
            logger.err("novelfrance: popularNovels — aucune donnée exploitable (ni API JSON, ni RSC)")
            return { novels = {} }
        end
    end

    local raw_items = data.novels or data.rankings or data.items or data
    local novels = {}
    if type(raw_items) == "table" then
        for _, item in ipairs(raw_items) do
            local n = ranking_item_to_novel(item)
            if n then table.insert(novels, n) end
        end
    end

    if #novels == 0 then
        logger.err("novelfrance: popularNovels — 0 roman extrait pour", url)
    end
    return { novels = novels }
end

function ext:searchNovels(term, page)
    -- NovelFrance's search is a client-side instant-search widget (no
    -- dedicated /search page), backed by this JSON endpoint. It returns a
    -- flat top-N list of matches with NO pagination. IMPORTANT : l'appli
    -- (ui/browse.lua) rappelle searchNovels avec page+1 tant que l'écran n'est
    -- pas plein ; si on renvoyait à nouveau les mêmes résultats, la grille
    -- se remplissait de doublons (6× le même roman). Page > 1 = liste vide.
    if page and page > 1 then return { novels = {} } end

    local url = BASE .. "/api/search/autocomplete?q=" .. url_encode(term)
    local body, err = http_get(url)
    if not body then
        logger.err("novelfrance: searchNovels fetch failed", tostring(err))
        return { novels = {} }
    end

    local data = json_decode(body)
    if not data then
        logger.err("novelfrance: searchNovels invalid JSON for", term)
        return { novels = {} }
    end
    -- Selon la version de l'API, la liste peut être enveloppée.
    if type(data) == "table" and not data[1] then
        data = data.novels or data.results or data.items or data
    end

    -- URL de couverture : l'autocomplete peut la donner relative
    -- ("/uploads/covers/x.webp"), absolue, ou sous un autre nom de clé.
    -- L'ancien code préfixait toujours BASE, ce qui cassait les URLs absolues.
    local function cover_url(n)
        local c = n.coverImage or n.cover or n.coverUrl or n.image or n.thumbnail
        if type(c) ~= "string" then return nil end
        c = c:gsub("^%s+", ""):gsub("%s+$", "")
        if c == "" or c == "null" then return nil end
        if c:match("^https?://") then return c end
        if c:sub(1, 2) == "//" then return "https:" .. c end
        return BASE .. (c:sub(1, 1) == "/" and "" or "/") .. c
    end

    -- Un seul résultat par roman (même slug OU même titre normalisé) ;
    -- en cas de doublon, on garde celui qui a une couverture.
    local novels, by_key = {}, {}
    for _, n in ipairs(data) do
        if type(n) == "table" and n.slug then
            local title = n.title or n.name or ""
            local key = title:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            if key == "" then key = n.slug end
            local entry = {
                name   = title,
                path   = "/novel/" .. n.slug,
                cover  = cover_url(n),
                author = n.author,
            }
            local idx = by_key[key]
            if not idx then
                table.insert(novels, entry)
                by_key[key] = #novels
            elseif not novels[idx].cover and entry.cover then
                novels[idx] = entry
            end
        end
    end

    -- Couvertures absentes de l'autocomplete : on les récupère sur la fiche
    -- du roman (au plus 6 requêtes, une page d'écran) pour que la grille
    -- affiche tout de suite les couvertures.
    local fetched = 0
    for _, entry in ipairs(novels) do
        if not entry.cover and fetched < 6 then
            fetched = fetched + 1
            local ok, meta = pcall(ext.parseNovelMeta, ext, entry.path)
            if ok and type(meta) == "table" and meta.cover then
                entry.cover = meta.cover
            end
        end
    end
    return { novels = novels }
end

function ext:parseNovelMeta(path)
    local html, err = http_get_page(BASE .. path)
    if not html then
        -- Échec réseau : ne jamais présenter une fiche vide comme une réponse
        -- valide. Le gestionnaire de détail peut alors interrompre l'actualisation
        -- proprement et conserver les métadonnées/chapitres déjà en cache.
        logger.err("novelfrance: parseNovelMeta failed for", path, tostring(err))
        return nil, err or "network_error"
    end
    local rsc_stream = build_rsc_stream(html)
    local novel_raw = find_balanced_json_object(rsc_stream, "initialNovel")
    local novel = novel_raw and json_decode(novel_raw)
    if not novel then
        novel_raw = find_json_object(html, "initialNovel")
        novel = novel_raw and json_decode(unescape_js(novel_raw))
    end
    if not novel then
        logger.err("novelfrance: parseNovelMeta invalid initialNovel for", path)
        return { name = "", path = path, total_chapters = 0 }
    end
    local rsc_rows = build_rsc_text_rows(html)

    return {
        name           = novel.title,
        path           = path,
        cover          = novel.coverImage and (BASE .. novel.coverImage) or nil,
        summary        = clean_summary(novel.description, rsc_rows),
        author         = novel.author,
        status         = STATUS_MAP[novel.status] or "Unknown",
        rating         = novel.rating,
        rank           = novel.allTimeRank,
        total_chapters = (novel._count and novel._count.chapters) or 0,
    }
end

-- Confirmé par capture Network (2026-09-12) : l'API accepte order=asc (en
-- plus de desc, utilisé par fetch_all_chapters ci-dessus) —
--   GET /api/chapters/<slug>?skip=0&take=5&order=asc
--   -> chapterNumber 0,1,2,3,4 (les tout premiers), total, hasMore
-- IMPORTANT : parsePage() a BESOIN de order=asc, PAS desc. detail.lua
-- (Detail.fetch, récupération "delta") suppose que le numéro de page d'un
-- chapitre est stable dans le temps — les nouveaux chapitres s'ajoutent
-- uniquement à la fin, sur de nouvelles pages, sans jamais faire bouger les
-- anciens. En desc (skip=0 = les plus récents), l'inverse se produit : tout
-- décale d'une page à chaque nouveau chapitre publié, ce qui casserait
-- complètement la fusion incrémentale de detail.lua.
ext.chapters_per_page = CHAPTERS_PER_PAGE

-- Une page de chapitres (1-based), déjà mappée au même format que
-- ext:parseNovel (name/path/chapter_number/date/locked) — pas les champs
-- bruts de l'API. Permet à ui/detail.lua de ne récupérer QUE les nouvelles
-- pages quand le nombre de chapitres augmente, au lieu de tout retélécharger
-- via parseNovel (fetch_all_chapters) à chaque "Actualiser la liste des
-- chapitres". Sur un roman à plusieurs milliers de chapitres (Shadow Slave,
-- 3180+), un parseNovel complet fait ~32 requêtes HTTP synchrones
-- d'affilée sans jamais rendre la main à l'UI — symptôme observé : l'appli
-- se ferme/redémarre (probablement un timeout système faute de réponse de
-- l'UI, pas un vrai crash logiciel). parsePage() rend chaque "Actualiser"
-- normal (pas de nouveaux chapitres) instantané, et un vrai ajout de
-- chapitres ne coûte plus qu'une poignée de requêtes au lieu de 32+.
function ext:parsePage(path, page)
    local base_path = path:gsub("/+$", "")
    local slug = base_path:match("([^/]+)$")
    page = tonumber(page) or 1
    local skip = (page - 1) * CHAPTERS_PER_PAGE

    local url = string.format("%s/api/chapters/%s?skip=%d&take=%d&order=asc",
        BASE, slug, skip, CHAPTERS_PER_PAGE)
    local body, err = http_get(url)
    if not body then
        logger.err("novelfrance: parsePage fetch failed for", slug, "page", page, tostring(err))
        return { chapters = {}, failed = true }
    end

    local data = json_decode(body)
    if not data or not data.chapters then
        logger.err("novelfrance: parsePage invalid JSON for", slug, "page", page)
        return { chapters = {}, failed = true }
    end

    local chapters = {}
    for _, c in ipairs(data.chapters) do
        table.insert(chapters, map_chapter(base_path, c))
    end
    return { chapters = chapters }
end

-- Tous les chapitres à partir de l'index `skip` (0-based, ordre croissant) en
-- quelques grosses requêtes (500 par page) au lieu d'une requête par tranche de 50.
-- Sert à ui/detail.lua pour récupérer UNIQUEMENT les nouveaux chapitres à
-- l'actualisation. `failed = true` si la récupération est incomplète : l'appelant
-- garde alors sa liste en cache.
function ext:parseChaptersFrom(path, skip)
    local base_path = path:gsub("/+$", "")
    local slug = base_path:match("([^/]+)$")
    local list, announced = fetch_chapters_from(slug, skip)
    if not list then return { chapters = {}, failed = true } end
    local chapters = {}
    for _, c in ipairs(list) do
        table.insert(chapters, map_chapter(base_path, c))
    end
    return { chapters = chapters, total = announced }
end

function ext:parseNovel(path)
    local base_path = path:gsub("/+$", "")
    local html, err = http_get_page(BASE .. path)
    if not html then
        logger.err("novelfrance: parseNovel fetch failed for", path, tostring(err))
        return { name = "", path = path, chapters = {}, totalPages = 1 }
    end

    local rsc_stream = build_rsc_stream(html)
    local novel_raw = find_balanced_json_object(rsc_stream, "initialNovel")
    local novel = novel_raw and json_decode(novel_raw)
    if not novel then
        novel_raw = find_json_object(html, "initialNovel")
        novel = novel_raw and json_decode(unescape_js(novel_raw))
    end
    if not novel then
        logger.err("novelfrance: could not parse initialNovel for", path)
        return { name = "", path = path, chapters = {}, totalPages = 1 }
    end

    local rsc_rows = build_rsc_text_rows(html)

    -- Prefer the slug parsed from the path itself (matches novel.slug in
    -- practice, but doesn't depend on it being present/correct).
    local slug = base_path:match("([^/]+)$") or novel.slug

    local raw_chapters, fetch_err = fetch_all_chapters(slug)
    local incomplete = (raw_chapters == nil)
    local chapters = {}
    for _, c in ipairs(raw_chapters or {}) do
        table.insert(chapters, map_chapter(base_path, c))
    end
    if incomplete then
        logger.err("novelfrance: liste de chapitres non récupérée pour", slug, tostring(fetch_err))
    elseif #chapters == 0 then
        logger.err("novelfrance: aucun chapitre renvoyé pour", slug)
    end

    local genres = nil
    if novel.genres then
        local names = {}
        for _, g in ipairs(novel.genres) do table.insert(names, g.name) end
        genres = table.concat(names, ", ")
    end

    -- Note moyenne (ex. "4.9") et rang dans un classement (ex. "#1"), affichés
    -- sur la page détail du site juste sous la couverture. Confirmés par une
    -- vraie capture du JSON initialNovel (2026-09-11) :
    --   "rating":4.897959183673469, "ratingCount":98, ..., "allTimeRank":1
    -- rating est un flottant brut (arrondi à l'affichage, pas ici) ; allTimeRank
    -- n'existe probablement que pour les romans classés (nil sinon → pas de
    -- badge affiché, cf. ui/detail.lua).
    local rating = novel.rating
    local rank   = novel.allTimeRank

    return {
        name       = novel.title,
        path       = path,
        cover      = novel.coverImage and (BASE .. novel.coverImage) or nil,
        summary    = clean_summary(novel.description, rsc_rows),
        author     = novel.author,
        genres     = genres,
        status     = STATUS_MAP[novel.status] or "Unknown",
        rating     = rating,
        rank       = rank,
        chapters   = chapters,
        totalPages = 1,
        -- true : la liste n'a pas pu être récupérée en entier. L'appelant doit
        -- alors garder sa liste en cache et surtout ne pas l'écraser par celle-ci.
        incomplete = incomplete or nil,
    }
end

-- ---------------------------------------------------------------------
-- Commentaires par paragraphe (/api/comments/chapter/...)
-- ---------------------------------------------------------------------
--
-- Confirmé par capture Network (2026-09-11), fil complet d'UN paragraphe :
--   GET /api/comments/chapter/<chapterId>/paragraph/<paragraphId>?sortBy=newest&page=N&limit=100
--   -> { comments: [...], total, page, limit, hasMore }
-- Chaque entrée de `comments` porte son propre paragraphId (utile pour un
-- éventuel threading côté client) et parentId (null pour un commentaire
-- racine, sinon l'id du commentaire parent — cf. replyTo pour l'extrait
-- affiché par le site).
--
-- as_str() : même nécessité que pour les avis (cf. plus bas) — certaines
-- libs JSON Lua décodent `null` en une valeur sentinelle, pas un vrai nil.
local function as_str(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end
-- BUG CORRIGÉ (2026-09-12) : double antislash dans le pattern gmatch
-- ("\\1" au lieu de "\1", etc.) — en Lua, dans une chaîne entre guillemets,
-- "\1" est l'échappement décimal produisant l'OCTET de valeur 1, alors que
-- "\\1" produit DEUX octets littéraux : un antislash suivi du caractère '1'.
-- Le pattern voulu (classe de caractères UTF-8 standard : octet de tête
-- 0x01-0x7F/0xC2-0xF4 suivi de 0 à 3 octets de continuation 0x80-0xBF)
-- devenait donc une classe de caractères ASCII complètement différente et
-- sans rapport (des antislashs/chiffres littéraux), qui ne matchait quasi
-- rien dès le premier caractère accentué — `utf8_prefix("Il régarda...", 80)`
-- renvoyait juste "I" au lieu de toute la phrase. Résultat concret : pour
-- tout texte français normal (accents), le `needle` construit ci-dessous
-- était tronqué à quasi rien, et readerview.lua ne retrouvait plus JAMAIS
-- la position du paragraphe dans le texte affiché → aucune icône 💬,
-- quel que soit le paragraphe. Fix : un seul antislash (vrais octets).
local function utf8_prefix(s, n)
    s = s or ""
    local out, count = {}, 0
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > n then break end
        table.insert(out, c)
    end
    return table.concat(out)
end

-- BUG CORRIGÉ (2026-09-12) : certains paragraphes renvoyés par l'API du site
-- portent DÉJÀ un repère "[N avis]" en toutes lettres, directement à
-- l'intérieur de `p.content` — ce n'est PAS quelque chose que ce plugin
-- ajoutait lui-même (cf. fetch_chapter_comment_counts et le champ `marks`
-- plus bas, un mécanisme totalement séparé, basé sur un second endpoint
-- /paragraph-counts). Comme rien ne retirait jamais ce texte de p.content
-- avant affichage, il apparaissait tel quel, en clair et non tapable, dans
-- le chapitre affiché — dupliquant, sans aucune interaction possible, ce
-- que l'icône comment.png (superposée par ui/readerview.lua) est censée
-- représenter.
-- Fix : on détecte ce repère, on l'enlève du texte affiché, et on récupère
-- le nombre qu'il contient comme repli si /paragraph-counts n'a pas cette
-- entrée (ex. léger désaccord entre les deux endpoints du site) — pour que
-- CE paragraphe obtienne quand même son icône tapable, plutôt que de perdre
-- purement et simplement l'information de commentaire.
local function strip_inline_avis_marker(text)
    text = text or ""
    -- "avis" est invariable en français (identique au singulier et au
    -- pluriel) : pas besoin de gérer un "s" optionnel ici.
    local n = text:match("%s*%[%s*(%d+)%s+avis%s*%]%s*$")
    if not n then return text, nil end
    local stripped = text:gsub("%s*%[%s*%d+%s+avis%s*%]%s*$", "")
    return stripped, tonumber(n)
end

-- Résolution d'URL d'avatar partagée entre avis (comment_to_review, section
-- "Avis" plus bas) et commentaires de paragraphe (comment_to_paragraph_comment
-- ci-dessous) : mêmes variantes de champ possibles, même règle pour les
-- chemins relatifs (/uploads/avatars/...) à préfixer par BASE.
local function resolve_avatar_url(author)
    local avatar = as_str(author.avatar) or as_str(author.avatarUrl)
        or as_str(author.image) or as_str(author.imageUrl)
    if avatar and not avatar:match("^https?://") then
        avatar = BASE .. avatar
    end
    return avatar
end

-- Confirmé par capture Network (2026-09-11) : il existe un endpoint dédié
-- pour l'aperçu par chapitre, distinct du fil complet d'un paragraphe —
-- pas besoin de regrouper une liste de commentaires nous-mêmes :
--   GET /api/comments/chapter/<chapterId>/paragraph-counts
--   -> { "<paragraphId>": <count>, "<paragraphId>": <count>, ... }
-- (objet JSON brut, pas de champ "comments"/"hasMore" — un simple map
-- paragraphId -> nombre de commentaires sur CE paragraphe.)
local function fetch_chapter_comment_counts(chapter_id)
    local url = string.format(
        "%s/api/comments/chapter/%s/paragraph-counts",
        BASE, url_encode(chapter_id))
    local body, err = http_get(url)
    if not body then
        logger.err("novelfrance: fetch_chapter_comment_counts failed for", chapter_id, tostring(err))
        return {}
    end

    local data = json_decode(body)
    if not data or type(data) ~= "table" then
        logger.err("novelfrance: fetch_chapter_comment_counts invalid JSON for", chapter_id)
        return {}
    end

    -- data est déjà le map paragraphId -> count attendu par parseChapter ;
    -- on filtre juste les valeurs non numériques par prudence (une lib JSON
    -- Lua mal lunée pourrait décoder un compteur en string).
    local counts = {}
    for pid, n in pairs(data) do
        n = tonumber(n)
        if n and n > 0 then
            counts[pid] = n
        end
    end
    return counts
end

-- Contrat normalisé (même esprit que comment_to_review) : { id, author,
-- avatar, content, date, likes, dislikes, parent_id, reply_count }.
-- parent_id/reply_count sont conservés (pas juste ignorés comme pour les
-- avis) car le fil d'un paragraphe est threadé (réponses imbriquées),
-- contrairement aux avis qui sont une simple liste plate.
local function comment_to_paragraph_comment(c)
    if not c then return nil end
    local author    = c.author or {}
    local reactions = c.reactions or {}

    return {
        id          = as_str(c.id),
        author      = as_str(author.username) or "Anonyme",
        avatar      = resolve_avatar_url(author),
        content     = as_str(c.content) or "",
        date        = as_str(c.createdAt) or as_str(c.publishedAt)
            or as_str(c.date) or as_str(c.updatedAt),
        likes       = reactions.like,
        dislikes    = reactions.dislike,
        parent_id   = as_str(c.parentId),
        reply_count = c.replyCount,
    }
end

-- Fil complet d'un paragraphe donné (pas encore branché à une UI — pour
-- l'instant seul parseChapter s'en sert indirectement via le repère
-- "[N avis]" ; cette méthode sert à récupérer le détail quand on tape
-- dessus, une fois l'écran correspondant construit côté ui/).
function ext:parseParagraphComments(chapter_id, paragraph_id, page)
    page = page or 1
    local url = string.format(
        "%s/api/comments/chapter/%s/paragraph/%s?sortBy=newest&page=%d&limit=100",
        BASE, url_encode(chapter_id), url_encode(paragraph_id), page)
    local body, err = http_get(url)
    if not body then
        logger.err("novelfrance: parseParagraphComments fetch failed for", chapter_id, paragraph_id, "page", page, tostring(err))
        return { comments = {}, has_more = false }
    end

    local data = json_decode(body)
    if not data or not data.comments then
        logger.err("novelfrance: parseParagraphComments invalid JSON for", chapter_id, paragraph_id, "page", page)
        return { comments = {}, has_more = false }
    end

    local comments = {}
    for _, c in ipairs(data.comments) do
        -- pcall : un champ inattendu sur UN commentaire ne doit jamais faire
        -- perdre tout le fil (même raisonnement que pour parseReviews).
        local ok_c, r = pcall(comment_to_paragraph_comment, c)
        if ok_c and r then
            table.insert(comments, r)
        elseif not ok_c then
            logger.err("novelfrance: comment_to_paragraph_comment failed for", tostring(c and c.id), tostring(r))
        end
    end

    return { comments = comments, has_more = data.hasMore or false }
end

-- ---------------------------------------------------------------------
-- Commentaires de FIN DE CHAPITRE (/api/comments/chapter/<id>, SANS le
-- suffixe /paragraph/<paragraphId>)
-- ---------------------------------------------------------------------
--
-- Confirmé par capture Network (2026-09-12) : le site affiche, sous le
-- texte de chaque chapitre, une section "Commentaires" distincte des
-- commentaires PAR paragraphe (ceux-ci ont paragraphId = null, type =
-- "CHAPTER") :
--   GET /api/comments/chapter/<chapterId>?sortBy=newest&page=N&limit=20
--   -> { comments: [...], total, page, limit, hasMore }
-- Même forme d'entrée par commentaire que /paragraph/<id> (author,
-- content, reactions, createdAt, parentId pour une réponse) : on
-- réutilise donc directement comment_to_paragraph_comment ci-dessus pour
-- la conversion — pas besoin d'une fonction de mapping séparée.
function ext:parseChapterComments(chapter_id, page)
    page = page or 1
    local url = string.format(
        "%s/api/comments/chapter/%s?sortBy=newest&page=%d&limit=20",
        BASE, url_encode(chapter_id), page)
    local body, err = http_get(url)
    if not body then
        logger.err("novelfrance: parseChapterComments fetch failed for", chapter_id, "page", page, tostring(err))
        return { comments = {}, has_more = false, total = 0 }
    end

    local data = json_decode(body)
    if not data or not data.comments then
        logger.err("novelfrance: parseChapterComments invalid JSON for", chapter_id, "page", page)
        return { comments = {}, has_more = false, total = 0 }
    end

    local comments = {}
    for _, c in ipairs(data.comments) do
        -- pcall : un champ inattendu sur UN commentaire ne doit jamais faire
        -- perdre toute la section (même raisonnement que pour les avis et
        -- les commentaires par paragraphe).
        local ok_c, r = pcall(comment_to_paragraph_comment, c)
        if ok_c and r then
            table.insert(comments, r)
        elseif not ok_c then
            logger.err("novelfrance: comment_to_paragraph_comment (fin de chapitre) failed for", tostring(c and c.id), tostring(r))
        end
    end

    return { comments = comments, has_more = data.hasMore or false, total = tonumber(data.total) or #comments }
end

-- dd/mm/yyyy à partir d'une date ISO ("2026-09-10T19:12:52.206Z") — même
-- logique que format_comment_date dans ui/readerview.lua, dupliquée ici car
-- non exportée par ce module (novelfrance.lua ne dépend pas de ui/).
local function format_chapter_comment_date(date)
    if not date or date == "" then return nil end
    local y, m, d = tostring(date):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return nil end
    return string.format("%s/%s/%s", d, m, y)
end

function ext:parseChapter(path)
    local html, err = http_get(BASE .. path)
    if not html then
        logger.err("novelfrance: parseChapter fetch failed for", path, tostring(err))
        save_last_error("chapitre : téléchargement impossible (" .. tostring(err) .. ")", BASE .. path, nil)
        return T("<p>Impossible de récupérer ce chapitre.</p>")
    end

    -- FIX : comme pour initialNovel (cf. parseNovel/parseNovelMeta), initialChapter
    -- peut lui aussi être découpé sur plusieurs lignes du flux Flight de Next.js.
    -- L'ancien code ne cherchait QUE dans le HTML brut échappé (find_json_object),
    -- ce qui ratait l'objet (ou récupérait un fragment tronqué) dès que le JSON du
    -- chapitre était réparti sur plusieurs push() — d'où "Impossible d'extraire le
    -- contenu de ce chapitre" sur des chapitres pourtant valides. On cherche
    -- désormais D'ABORD dans le flux Flight déjà reconstitué (fiable même réparti),
    -- et on ne retombe sur l'ancienne méthode qu'en dernier recours.
    local rsc_stream = build_rsc_stream(html)
    local chapter_raw = find_balanced_json_object(rsc_stream, "initialChapter")
    local chapter = chapter_raw and json_decode(chapter_raw)
    if not chapter then
        chapter_raw = find_json_object(html, "initialChapter")
        chapter = chapter_raw and json_decode(unescape_js(chapter_raw))
    end
    if not chapter then
        logger.err("novelfrance: could not parse initialChapter for", path)
        save_last_error("chapitre : initialChapter introuvable", BASE .. path, html)
        return T("<p>Impossible d'extraire le contenu de ce chapitre.</p>")
    end

    -- Comme pour novel.description (cf. clean_summary) : le titre/les paragraphes
    -- peuvent contenir une référence "$id" vers une ligne texte externalisée du
    -- flux Flight au lieu du texte réel, si le chapitre est long. On les résout
    -- avant tout traitement pour éviter d'afficher ces références brutes.
    local rsc_rows = build_rsc_text_rows(html)
    if chapter.title then
        chapter.title = resolve_rsc_string(chapter.title, rsc_rows)
    end
    if chapter.paragraphs then
        for _, p in ipairs(chapter.paragraphs) do
            if p.content then
                p.content = resolve_rsc_string(p.content, rsc_rows)
            end
        end
    end

    if chapter.isPremium then
        return T("<p>Ce chapitre est réservé aux membres Premium et n'est pas encore disponible gratuitement.</p>")
    end

    -- Repères "[N avis]" sur les paragraphes commentés : un seul fetch
    -- groupé par chapitre (cf. fetch_chapter_comment_counts ci-dessus)
    -- plutôt qu'un fetch par paragraphe. pcall : un souci sur cet appel ne
    -- doit jamais empêcher l'affichage du chapitre lui-même — au pire,
    -- aucun repère n'apparaît pour ce chargement.
    -- PAS d'emoji (💬) : testé sur liseuse, la police du lecteur (NotoSans,
    -- sans glyphes couleur/emoji) l'affiche en tofu/case vide — juste du
    -- texte ASCII simple, garanti de s'afficher partout.
    local comment_counts = {}
    if chapter.id then
        local ok_cc, counts = pcall(fetch_chapter_comment_counts, chapter.id)
        if ok_cc and type(counts) == "table" then
            comment_counts = counts
        end
    end

    -- `marks` : version ordonnée (même ordre que chapter.paragraphs) des
    -- SEULS paragraphes commentés, avec un aperçu tronqué du texte — sert à
    -- construire le sélecteur tap-to-open côté lecteur (ui/readerview.lua),
    -- qui ne voit normalement que le texte brut final et n'a pas accès à
    -- chapter.paragraphs. Transporté en pièce jointe JSON en fin de HTML
    -- (cf. plus bas), PAS comme attribut/balise, pour survivre au trajet
    -- Cache (fichier disque) -> ReaderView, tout en restant invisible du
    -- texte affiché une fois extrait côté lecteur.
    local marks = {}
    -- pdp (avatars) à superposer par ui/readerview.lua à côté des lignes
    -- "Auteur — date" de la section "Commentaires" de fin de chapitre
    -- construite plus bas — même mécanisme que `marks` ci-dessus, transporté
    -- lui aussi dans le trailer LNREADER_META.
    local chapter_comment_marks = {}

    local parts = {}
    if chapter.title and chapter.title ~= "" then
        -- Défensif : si le site accolait un jour ce même repère au titre,
        -- on ne veut pas non plus le laisser traîner en clair dans le H1.
        local title_text = strip_inline_avis_marker(chapter.title)
        table.insert(parts, "<h1>" .. escape_html(title_text) .. "</h1>")
    end

    if chapter.paragraphs then
        for _, p in ipairs(chapter.paragraphs) do
            -- Retire un éventuel repère "[N avis]" déjà présent dans le
            -- texte brut du paragraphe (cf. strip_inline_avis_marker
            -- ci-dessus) AVANT tout le reste, pour que ni l'affichage ni le
            -- `needle` de repérage plus bas n'en gardent la moindre trace.
            local clean_content, inline_n = strip_inline_avis_marker(p.content)
            local text = escape_html(clean_content)
            local n = comment_counts[p.id] or inline_n
            if n and n > 0 then
                -- Le texte "[N avis]" est désormais remplacé par une icône
                -- comment.png superposée au paragraphe dans readerview.lua.
                -- `needle` permet au lecteur de retrouver précisément la
                -- position du paragraphe dans le texte déjà paginé —
                -- construit à partir du texte NETTOYÉ (clean_content), pour
                -- que la recherche de position côté lecteur corresponde
                -- exactement à ce qui est réellement affiché.
                local normalized = (clean_content or ""):gsub("%s+", " ")
                local needle = utf8_prefix(normalized, 80)
                local preview = needle
                if #preview > 70 then
                    preview = utf8_prefix(needle, 70) .. "…"
                elseif #preview > 70 then
                    preview = utf8_prefix(needle, 70) .. "…"
                end
                table.insert(marks, {
                    id = p.id,
                    count = n,
                    preview = preview,
                    needle = needle,
                })
            end
            table.insert(parts, "<p>" .. text .. "</p>")

            -- Export option : insère le fil COMPLET des commentaires liés à
            -- ce paragraphe directement après celui-ci. En lecture normale,
            -- on ne fait jamais ces requêtes supplémentaires.
            if self._export_all_comments and n and n > 0 and p.id then
                local ok_pc, paragraph_comments = pcall(function()
                    local all = {}
                    local page, has_more = 1, true
                    while has_more and page <= 1000 do
                        local data = self:parseParagraphComments(chapter.id, p.id, page)
                        for _, c in ipairs((data and data.comments) or {}) do
                            all[#all + 1] = c
                        end
                        has_more = data and data.has_more or false
                        if #(data and data.comments or {}) == 0 and not has_more then break end
                        page = page + 1
                    end
                    return all
                end)
                if ok_pc and type(paragraph_comments) == "table" and #paragraph_comments > 0 then
                    table.insert(parts, T("<p><strong>Commentaires du paragraphe</strong></p>"))
                    for _, c in ipairs(paragraph_comments) do
                        local author_date = c.author or "Anonyme"
                        local date_str = format_chapter_comment_date(c.date)
                        if date_str then author_date = author_date .. " — " .. date_str end
                        table.insert(parts, "<p><em>" .. escape_html(author_date) .. "</em><br/>"
                            .. escape_html(c.content or "") .. "</p>")
                    end
                elseif not ok_pc then
                    logger.err("novelfrance: échec récupération commentaires paragraphe pour export", tostring(p.id), tostring(paragraph_comments))
                end
            end
        end
    elseif chapter.content then
        table.insert(parts, "<p>" .. escape_html(chapter.content) .. "</p>")
    else
        table.insert(parts, T("<p>(chapitre vide)</p>"))
    end

    -- Commentaires de fin de chapitre (section "Commentaires" du site, cf.
    -- ext:parseChapterComments ci-dessus) : ajoutés en TEXTE à la suite du
    -- dernier paragraphe, exactement comme le fait le site lui-même — pas
    -- besoin d'une UI dédiée (pas de fil imbriqué ni de "voir plus" : on
    -- récupère plusieurs pages d'affilée, cf. PAGE_CAP ci-dessous).
    -- pcall englobant : un souci réseau/JSON ici ne doit jamais empêcher
    -- l'affichage du chapitre lui-même (au pire, pas de section
    -- Commentaires pour ce chargement).
    if chapter.id then
        local PAGE_CAP = self._export_all_comments and 1000 or 5
        local ok_cc, chapter_comments = pcall(function()
            local all = {}
            local page, has_more = 1, true
            while has_more and page <= PAGE_CAP do
                local data = self:parseChapterComments(chapter.id, page)
                for _, c in ipairs((data and data.comments) or {}) do
                    table.insert(all, c)
                end
                has_more = data and data.has_more or false
                page = page + 1
            end
            return all
        end)
        if not ok_cc then
            logger.err("novelfrance: échec récupération des commentaires de fin de chapitre pour", chapter.id, tostring(chapter_comments))
            chapter_comments = {}
        end

        if #chapter_comments > 0 then
            table.insert(parts, "<hr/>")
            -- Espacement + ligne de séparation du titre : pas de vraie mise
            -- en forme possible ici (texte brut une fois passé par
            -- Epub.html_to_text, qui supprime TOUTES les balises), donc on
            -- simule avec une ligne vide et une ligne de tirets AU-DESSUS
            -- de "Commentaires" (déplacée depuis en-dessous, demandé).
            table.insert(parts, "<p></p>")
            table.insert(parts, "<p>――――――――――――</p>")
            table.insert(parts, "<h1>Commentaires</h1>")
            table.insert(parts, "<p></p>")
            for _, c in ipairs(chapter_comments) do
                -- Indentation réservée pour la pdp superposée par
                -- ui/readerview.lua (build_avatar_overlays), placée à
                -- GAUCHE du pseudo. Approximation : un nombre fixe
                -- d'espaces, pas un calcul pixel-exact (la taille de police
                -- de lecture est réglable par l'utilisateur après coup) —
                -- suffisant pour laisser la place à la pdp sans recouvrir
                -- le pseudo dans les tailles de police courantes.
                local has_avatar = c.avatar and c.avatar ~= ""
                -- BUG TROUVÉ : Epub.html_to_text (core/epub.lua) fait
                -- `body:gsub("[ \t]+", " ")` — TOUTE suite d'espaces/tabs
                -- normaux est réduite à UN SEUL espace. C'est pour ça
                -- qu'augmenter le nombre d'espaces classiques (10, puis 26,
                -- puis 40) n'avait STRICTEMENT AUCUN effet visible : ils
                -- finissaient tous écrasés à 1 seul espace. Fix : on réserve
                -- la place avec des espaces INSÉCABLES (U+00A0), que ce
                -- gsub ne touche pas (il ne matche que 0x20/0x09).
                local NBSP = "\194\160" -- U+00A0 en UTF-8
                local indent = has_avatar and string.rep(NBSP, 11) or ""
                local author_date = c.author or "Anonyme"
                local date_str = format_chapter_comment_date(c.date)
                if date_str then
                    author_date = author_date .. " — " .. date_str
                end
                local header_raw = indent .. author_date
                local content = escape_html(c.content or "")
                table.insert(parts, "<p><em>" .. escape_html(header_raw) .. "</em><br/>" .. content .. "</p>")

                -- Repère pour la pdp superposée par ui/readerview.lua (même
                -- mécanisme que `marks` pour les icônes de paragraphe
                -- ci-dessus). needle = "Auteur — date" SANS l'indentation :
                -- avec les espaces en tête, la position trouvée tombait sur
                -- la ligne SUIVANTE (le rendu du lecteur ne compte
                -- apparemment pas ces espaces de début de ligne dans
                -- l'intervalle de la ligne "Auteur — date", donc le repère
                -- retombait dans l'intervalle de la ligne du contenu du
                -- commentaire juste en dessous — d'où les pdp décalées d'une
                -- ligne signalées). En cherchant directement "Auteur — date"
                -- (qui, lui, est bien à l'intérieur de la ligne), le repère
                -- retombe correctement dans CETTE ligne — seule la position
                -- verticale (quelle ligne) compte pour la pdp, l'horizontale
                -- est fixée au bord gauche côté lecteur, donc peu importe
                -- que le repère pointe légèrement après le début de ligne.
                -- Pas de pdp pour un auteur sans avatar : rien à superposer.
                if has_avatar then
                    table.insert(chapter_comment_marks, { avatar = c.avatar, author = c.author, needle = author_date })
                end
            end
        end
    end

    local body_html = table.concat(parts, "\n")

    -- Trailer JSON consommé par ui/readerview.lua AVANT sa conversion en
    -- texte brut (Epub.html_to_text) — cf. commentaire plus haut : cette
    -- fonction supprime toutes les balises `<...>`, y compris un
    -- commentaire HTML `<!-- -->`, mais PAS le texte brut qu'il
    -- contiendrait. readerview.lua doit donc explicitement extraire ce
    -- bloc avant d'appeler html_to_text, sans quoi le JSON apparaîtrait
    -- tel quel dans le chapitre affiché.
    -- LIMITE CONNUE (acceptée, très improbable en prose FR) : l'extraction
    -- côté lecteur s'arrête au premier "-->" rencontré — si `preview`
    -- contenait littéralement cette séquence, le JSON serait tronqué.
    if (#marks > 0 or #chapter_comment_marks > 0) and chapter.id then
        local ok_j, JSON = pcall(require, "rapidjson")
        if not ok_j then JSON = require("json") end
        local ok_enc, encoded = pcall(JSON.encode, {
            chapterId = chapter.id,
            marks = marks,
            chapterCommentMarks = chapter_comment_marks,
        })
        if ok_enc and encoded then
            body_html = body_html .. "\n<!--LNREADER_META:" .. encoded .. "-->"
        else
            logger.err("novelfrance: échec encodage LNREADER_META pour", chapter.id)
        end
    end

    return body_html
end

-- ---------------------------------------------------------------------
-- Avis (/api/comments)
-- ---------------------------------------------------------------------
--
-- Les avis ne sont PAS dans le payload RSC de la page (contrairement à
-- initialNovel/initialChapter) : la section est en
-- BAILOUT_TO_CLIENT_SIDE_RENDERING côté React et se charge via une vraie
-- API JSON, confirmée par capture Network (2026-09-11) :
--
--   GET /api/comments?novelId=<id>&type=REVIEW&sortBy=newest&page=N&limit=10&hasRating=true
--   -> { comments: [...], total, page, limit, hasMore }
--
-- <id> est l'identifiant interne du roman (ex. "cmlwq37fc000a5eudd9xwmj3x"),
-- PAS le slug utilisé dans l'URL. On le récupère via initialNovel.id, avec
-- le même mécanisme que parseNovelMeta ci-dessus (une requête HTML de plus —
-- ce fichier ne mutualise pas les fetches entre méthodes ext, cf. parseNovel
-- qui refait aussi son propre http_get plutôt que de réutiliser
-- parseNovelMeta).
--
-- Réponse brute de /api/comments, par entrée de `comments` :
--   { content, rating (1-5), author = { username, avatar, ... },
--     reactions = { like, dislike, love, ... }, ... }
-- Contrat normalisé attendu par ui/detail.lua (build_reviews_rows) :
--   { reviews = { { author, rating, content, likes, dislikes }, ... },
--     has_more = bool }

-- Confirmé par capture Network (2026-09-11, page 2 de /api/comments) :
-- author.avatar (URL absolue Google ou chemin relatif /uploads/avatars/...,
-- ou JSON null si l'auteur n'a pas de pdp) et c.createdAt (ISO 8601).
-- as_str() est nécessaire car certaines libs JSON Lua décodent `null` en une
-- valeur sentinelle (pas un vrai nil) — sans ça, un seul avis avec avatar
-- null (ex. l'auteur "Cain" dans les avis de Shadow Slave) fait planter
-- avatar:match(...), ce qui remonte jusqu'au pcall de ext:parseReviews et
-- fait rejeter TOUTE la page d'avis (symptôme observé : "Aucun avis pour ce
-- roman" alors que l'API renvoyait pourtant des avis).
-- as_str() et resolve_avatar_url() sont maintenant définies plus haut dans
-- ce fichier (section "Commentaires par paragraphe"), et partagées avec
-- comment_to_paragraph_comment — même règles de résolution d'avatar.
local function comment_to_review(c)
    if not c then return nil end
    local author    = c.author or {}
    local reactions = c.reactions or {}

    return {
        id       = as_str(c.id),
        parent_id = as_str(c.parentId),
        author   = as_str(author.username) or "Anonyme",
        rating   = c.rating,
        content  = as_str(c.content) or "",
        likes    = reactions.like,
        dislikes = reactions.dislike,
        avatar   = resolve_avatar_url(author),
        date     = as_str(c.createdAt) or as_str(c.publishedAt)
            or as_str(c.date) or as_str(c.updatedAt),
    }
end

-- Tri des avis : vocabulaire générique commun à toutes les extensions (voir
-- ui/detail.lua current_api_sort()) — "newest" | "oldest" | "mostliked".
-- Seul sortBy=newest est confirmé par capture Network (2026-09-11) pour
-- cette API ; "oldest" et "mostLiked" sont des valeurs plausibles PAR
-- ANALOGIE (convention camelCase de cette même API : novelId, hasMore,
-- createdAt...) mais NON vérifiées par capture. Repli automatique sur
-- sortBy=newest (seule valeur garantie) si le candidat deviné renvoie 0 avis
-- en page 1 ou échoue — le tri demandé peut donc silencieusement ne pas être
-- honoré tant que ces deux valeurs n'auront pas été confirmées par une vraie
-- capture DevTools (même précaution que ratings_candidates de skynovels.lua).
local SORT_MAP = { newest = "newest", oldest = "oldest", mostliked = "mostLiked" }

-- Fait l'étape 2 (interroger l'API des avis) pour une valeur de sortBy
-- donnée. Factorisé pour être appelé une ou deux fois par parseReviews (tri
-- deviné, puis repli sur newest si besoin) sans dupliquer le parsing.
local function fetch_reviews_sorted(novel_id, page, sort_by)
    local url = string.format(
        "%s/api/comments?novelId=%s&type=REVIEW&sortBy=%s&page=%d&limit=10&hasRating=true",
        BASE, url_encode(novel_id), sort_by, page)
    local body, err = http_get(url)
    if not body then return nil, "HTTP: " .. tostring(err) end

    local data = json_decode(body)
    if not data or not data.comments then return nil, "JSON invalide" end

    local reviews = {}
    for _, c in ipairs(data.comments) do
        -- pcall : un champ inattendu sur UN avis ne doit jamais faire perdre
        -- toute la page (c'est ce qui s'est produit avec un avatar `null`
        -- avant le durcissement de comment_to_review ci-dessus).
        local ok_c, r = pcall(comment_to_review, c)
        if ok_c and r then
            table.insert(reviews, r)
        elseif not ok_c then
            logger.err("novelfrance: comment_to_review failed for", tostring(c and c.id), tostring(r))
        end
    end
    return { reviews = reviews, has_more = data.hasMore or false }
end

function ext:parseReviews(path, page, sort)
    page = page or 1

    -- Étape 1 : résoudre l'id interne du roman depuis la page HTML.
    local novel, err = fetch_json_field(BASE .. path, "initialNovel")
    if not novel or not novel.id then
        logger.err("novelfrance: parseReviews could not resolve novel id for", path, tostring(err))
        return { reviews = {}, has_more = false }
    end

    local sort_by = SORT_MAP[sort] or "newest"
    local result, err2 = fetch_reviews_sorted(novel.id, page, sort_by)
    if result and (#result.reviews > 0 or page > 1) then
        return result
    end
    if sort_by ~= "newest" then
        -- Le tri deviné n'a rien donné (forme non reconnue, erreur, ou
        -- simplement 0 avis en page 1 alors qu'il pourrait y en avoir avec
        -- le tri par défaut) : on retombe sur la seule valeur confirmée.
        logger.warn("novelfrance: parseReviews — sortBy=", sort_by, "sans résultat, repli sur newest (",
            tostring(err2 or (result and "0 avis")), ")")
        result, err2 = fetch_reviews_sorted(novel.id, page, "newest")
    end
    if not result then
        logger.err("novelfrance: parseReviews fetch failed for", path, "page", page, tostring(err2))
        return { reviews = {}, has_more = false }
    end
    if #result.reviews == 0 then
        logger.warn("novelfrance: parseReviews — 0 avis extrait pour", path, "page", page)
    end
    return result
end

return ext
