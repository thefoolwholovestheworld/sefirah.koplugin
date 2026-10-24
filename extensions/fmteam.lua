-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- extensions/fmteam.lua — FMTeam (French Manga Team, scans en français), https://fmteam.fr
--
-- Source MANGA de Sefirah (même contrat que mangadex.lua : ext.type = "manga").
-- Le site est rendu côté serveur : le HTML brut contient tout (pas de JavaScript
-- nécessaire), contrairement à MangaFire.
--
-- ══ AVANCEMENT (2 parties) ═══════════════════════════════════════════════════
--   PARTIE 1  [fait]    1. Squelette de l'extension (ce fichier)
--                       2. Enregistrement dans core/extmgr.lua + icône
--                       3. Parcourir (« Dernières sorties » de l'accueil)
--                       4. Fiche de la série (résumé, auteur, genres, statut)
--                       5. Liste des chapitres
--   Accueil de Parcourir = « Tous les mangas » (catalogue /mangas, limité à 20 par le site, + séries de l'accueil) par défaut ; « Dernières sorties » reste dans le filtre Tri.
--   PARTIE 2  [fait]    6. Pages d'un chapitre (parseChapterImages) — testé sur un vrai chapitre
--                       7. Catalogue complet (/mangas) et recherche — NON vérifié : le HTML
--                          de /mangas n'a pas été fourni, l'analyse est générique (liens
--                          /manga/<slug>) ; en cas d'échec, voir fmteam_last_error.txt
--                       8. Chapitres « Tome/Punch… » et décimaux : adresses de lecture
--                          essayées dans l'ordre (n°, n° avec « - »), non vérifiées
--                       9. Tests, notes de version, zip final
--
-- ══ STRUCTURE DU SITE (relevée sur du vrai HTML le 2026-10-10) ═══════════════
--   * Accueil « / » : div.latest-item (une carte par chapitre sorti, donc une
--     série peut apparaître plusieurs fois) : img.latest-thumb (couverture),
--     div.latest-comic > a[href=/manga/<slug>] (titre).
--   * Série « /manga/<slug> » : h1.manga-title, img.manga-cover, span.meta-tag
--     (✍️ auteur, statut span.status-*, genres « A -B - C »), p.manga-desc,
--     div.chapter-item (label « Chapitre 157 : Titre », date, lien de
--     téléchargement …/fmapi/download?chapter_id=<id>&format=cbz).
--   * Lecteur « /read/<slug>/fr/ch/<n> » : div#reader-images contient les <img alt="Page">
--     dans /storage/comics/<série>/<chapitre>/NN.png (noms variables : 01a.jpg,
--     27-28.png pour une double page) → on garde l'ordre d'apparition.
--   * Recherche : formulaire GET /mangas?search=<texte> (HTML non fourni).
--
-- Chemins : série = « <slug> » ; chapitre = « <slug>|<n° dans l'URL>|<chapter_id> ».

local logger = require("logger")
local T      = require("core.i18n").T

local BASE = "https://fmteam.fr"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

-- ── Aides HTML ────────────────────────────────────────────────────────────────
local function utf8_encode(cp)
    if not cp then return "" end
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40), 0x80 + (cp % 0x40))
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
        0x80 + (math.floor(cp / 0x1000) % 0x40),
        0x80 + (math.floor(cp / 0x40) % 0x40), 0x80 + (cp % 0x40))
end

-- Retire les balises et décode les entités (&#x27; &amp; &quot; …).
local function strip_tags(s)
    s = (s or ""):gsub("<br%s*/?>", "\n"):gsub("<[^>]+>", "")
    s = s:gsub("&#[xX](%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8_encode(tonumber(d)) end)
    s = s:gsub("&nbsp;", " "):gsub("&quot;", '"'):gsub("&apos;", "'")
         :gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
    s = s:gsub("[ \t]+", " "):gsub("%s*\n%s*", "\n")
    return (s:match("^%s*(.-)%s*$"))
end

local function one_line(s) return (strip_tags(s):gsub("%s+", " ")) end

local function abs_url(u)
    if not u or u == "" then return nil end
    if u:match("^https?://") then return (u:gsub("&amp;", "&")) end
    if u:sub(1, 2) == "//" then return "https:" .. u end
    if u:sub(1, 1) == "/" then return BASE .. u end
    return BASE .. "/" .. u
end

local function slug_of(href)
    return href and href:match("/manga/([^/%?#\"]+)")
end

-- ── Réseau ───────────────────────────────────────────────────────────────────
-- En cas de souci, la réponse du site est enregistrée dans
-- sefirah/fmteam_last_error.txt (dossier des réglages de KOReader).
local function dump(tag, text)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        pcall(function() require("libs/libkoreader-lfs").mkdir(dir) end)
        local f = io.open(dir .. "/fmteam_last_error.txt", "wb")
        if f then
            f:write(tag, "\n\n", tostring(text):sub(1, 12000))
            f:close()
        end
    end)
end

-- Message à l'écran (la liseuse n'a pas de console).
local function notify(text)
    pcall(function()
        local UIManager   = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = text, timeout = 8 })
    end)
end

local function title_of(body)
    return (body:match("<[tT][iI][tT][lL][eE][^>]*>(.-)</[tT][iI][tT][lL][eE]>") or "")
end

-- path = « /manga/<slug> » : renvoie le HTML ou nil, erreur.
local function http_get(path, quiet)
    local headers = {
        ["User-Agent"]      = UA,
        ["Accept"]          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "fr-FR,fr;q=0.9,en;q=0.5",
        ["Referer"]         = BASE .. "/",
    }
    local body, code, prefix = require("core.net").get(BASE .. path, { headers = headers, timeout = 20 })
    if body and #body > 500 then
        local t = title_of(body):lower()
        local blocked = (t:find("block", 1, true) or t:find("denied", 1, true)
            or t:find("just a moment", 1, true) or t:find("attention required", 1, true))
            and not body:find("latest-item", 1, true) and not body:find("manga-title", 1, true)
        if not blocked then return body end
        dump("Page de blocage reçue pour " .. path .. " (" .. title_of(body) .. ")", body)
        if quiet then return nil, "blocked" end
        notify("FMTeam : accès bloqué (« " .. one_line(title_of(body)):sub(1, 40) .. " »).\n"
            .. "Ce blocage vient du réseau ou du site, pas du plugin.")
        return nil, "blocked"
    end
    logger.err("FMTeam: http_get FAILED", path, tostring(code))
    if quiet then return nil, code end
    dump("Échec réseau pour " .. path .. "\nCode : " .. tostring(code),
        type(prefix) == "string" and prefix or "")
    notify("FMTeam : le site ne répond pas (code " .. tostring(code) .. ").")
    return nil, code
end

-- ── Filtres (onglet Parcourir) ───────────────────────────────────────────────
-- Genres du site (liste du <select name="genre"> de /mangas, relevée le 2026-10-10).
-- ext:loadFilters() la relit sur le site à la 1re ouverture de « Filtrer » ;
-- cette liste sert de repli si le site ne répond pas.
local DEFAULT_GENRES = {
    "Action", "Aventure", "Comédie", "Drame", "Fantastique", "Furyo", "Historique",
    "Horreur", "Mystère", "Psychologique", "Science-fiction", "Seinen", "Shonen",
    "Slice of Life", "Sports", "Surnaturel", "Survie", "Thriller", "Tragédie",
}

local function genre_options(list)
    local o = { { id = "", label = T("Tous les genres") } }
    for _, g in ipairs(list) do o[#o + 1] = { id = g, label = g } end
    return o
end

local GENRE_FILTER = {
    key = "genre", label = T("Genre"), default = "",
    options = genre_options(DEFAULT_GENRES),
}

local POPULAR_FILTERS = {
    {
        key = "sort", label = T("Tri"), default = "catalogue",
        options = {
            { id = "catalogue", label = T("Tous les mangas") },
            { id = "latest",    label = T("Dernières sorties") },
        },
    },
    GENRE_FILTER,
}

local ext = {
    id             = "fmteam",
    name           = "FMTeam",
    site           = BASE,
    lang           = "fr",
    version        = "0.2.0",
    type           = "manga",     -- cf. contrat dans mangadex.lua
    popularFilters = POPULAR_FILTERS,
    -- Recherche : le genre peut aussi être combiné au texte cherché.
    searchFilters  = { GENRE_FILTER },
    hasReviews     = false,
    chapterCommentsPanel = false,
}

-- ── Étape 3 : Parcourir = « Dernières sorties » de l'accueil ─────────────────
local function parse_latest(html)
    local novels, seen = {}, {}
    local MARK = 'class="latest-item'
    local positions, pos = {}, 1
    while true do
        local s = html:find(MARK, pos, true)
        if not s then break end
        positions[#positions + 1] = s
        pos = s + #MARK
    end
    for i, s in ipairs(positions) do
        local seg = html:sub(s, (positions[i + 1] or #html + 1) - 1)
        local href = seg:match('class="latest%-comic"%s*>%s*<a%s+href="([^"]+)"')
        local slug = slug_of(href)
        local title = one_line(seg:match('class="latest%-comic"%s*>%s*<a[^>]*>(.-)</a>') or "")
        if slug and title ~= "" and not seen[slug] then
            seen[slug] = true
            local cover = abs_url(seg:match('class="latest%-thumb"%s+src="([^"]+)"'))
            novels[#novels + 1] = { name = title, path = slug, cover = cover }
        end
    end
    return novels
end

-- Catalogue / recherche (/mangas) : analyse GÉNÉRIQUE, le HTML de cette page n'a pas
-- été fourni. On repère tous les liens « /manga/<slug> » de la zone principale ; le
-- titre vient du texte du lien (ou de l'attribut alt de l'image), la couverture de la
-- première image /storage/comics/ rencontrée.
local function parse_cards(html)
    local novels, order, by = {}, {}, {}

    -- Format réel de /mangas (relevé le 2026-10-10) : une carte
    --   <div class="manga-row" onclick="window.location='/manga/<slug>'">
    --     <img class="manga-row-cover" src="/storage/comics/…">
    --     <div class="manga-row-name">Titre </div> …
    -- (aucun lien <a> : c'est le onclick qui porte l'adresse de la série).
    local MARK = 'class="manga-row"'
    local positions, pos = {}, 1
    while true do
        local st = html:find(MARK, pos, true)
        if not st then break end
        positions[#positions + 1] = st
        pos = st + #MARK
    end
    for i, st in ipairs(positions) do
        local seg = html:sub(st, (positions[i + 1] or #html + 1) - 1)
        local slug = seg:match("window%.location='/manga/([^'/?#]+)")
        local name = one_line(seg:match('class="manga%-row%-name"[^>]*>(.-)</div>') or "")
        if slug and name ~= "" and not by[slug] then
            by[slug] = true
            local cover = abs_url(seg:match('class="manga%-row%-cover"[^>]-src="([^"]+)"'))
            novels[#novels + 1] = { name = name, path = slug, cover = cover }
        end
    end
    if #novels > 0 then return novels end

    -- Repli : analyse générique des liens « /manga/<slug> ».
    local from = html:find("<main", 1, true) or 1
    local body = html:sub(from)
    for href, inner in body:gmatch('<a%s[^>]-href="([^"]*/manga/[^"]+)"[^>]*>(.-)</a>') do
        local slug = slug_of(href)
        if slug then
            local e = by[slug]
            if not e or e == true then
                e = { path = slug }
                by[slug] = e
                order[#order + 1] = slug
            end
            local img = inner:match('<img[^>]-src="([^"]+)"')
            if img and not e.cover then e.cover = abs_url(img) end
            local text = one_line((inner:gsub("<img[^>]*>", "")))
            if text == "" then text = one_line(inner:match('<img[^>]-alt="([^"]*)"') or "") end
            if text ~= "" and (not e.name or #text > #e.name) then e.name = text end
        end
    end
    for _, slug in ipairs(order) do
        local e = by[slug]
        if e.name and e.name ~= "" and not e.name:match("^[←→]") and not e.name:find("Retour", 1, true) then
            novels[#novels + 1] = { name = e.name, path = e.path, cover = e.cover }
        end
    end
    return novels
end

local _last_first  -- première série de la page précédente (détection « page inexistante »)

local function list_mangas(term, page, genre)
    page = tonumber(page) or 1
    local url = require("socket.url")
    local path = "/mangas?"
    if term and term ~= "" then path = path .. "search=" .. url.escape(term) .. "&" end
    if genre and genre ~= "" then path = path .. "genre=" .. url.escape(genre) .. "&" end
    path = path .. "page=" .. page
    local html = http_get(path)
    if not html then return { novels = {} } end
    local novels = parse_cards(html)
    if #novels == 0 then
        -- Une page au-delà de la fin (ou un genre vide) n'est pas une erreur.
        if page > 1 then
            -- Diagnostic : on garde la FIN de la page reçue (là où serait la pagination).
            dump("Page " .. page .. " du catalogue vide : " .. path .. " (" .. #html .. " octets)\n"
                .. "Titre : " .. one_line(title_of(html)) .. "\n"
                .. "manga-row : " .. select(2, html:gsub('class="manga%-row"', "")) .. "\n\n[FIN DE LA PAGE]",
                html:sub(-6000))
            return { novels = {} }
        end
        if html:find("manga%-row") == nil and (genre and genre ~= "" or (term and term ~= "")) then
            return { novels = {} }
        end
        logger.warn("FMTeam: aucune carte reconnue pour", path)
        dump("Aucune carte reconnue pour " .. path .. " (" .. #html .. " octets)", html)
        notify("FMTeam : page reçue (" .. #html .. " octets) mais aucune série reconnue.\n"
            .. one_line(title_of(html)):sub(1, 90))
        return { novels = {} }
    end
    -- Le site renvoie parfois la dernière page au-delà de la fin : on s'arrête si on
    -- retombe sur la même première série.
    local key = (genre or "") .. "|" .. (term or "")
    if page > 1 and _last_first == key .. novels[1].path then return { novels = {} } end
    _last_first = key .. novels[1].path
    return { novels = novels }
end

local _latest_seen = {}  -- séries déjà listées dans « Dernières sorties » (cette session de parcours)

function ext:popularNovels(page, options)
    local f = (options and options.filters) or {}
    page = tonumber(page) or 1
    -- Un genre choisi = catalogue filtré (/mangas?genre=…).
    if f.genre and f.genre ~= "" then
        return list_mangas("", page, f.genre)
    end
    -- « Tous les mangas » (défaut) = catalogue /mangas (limité à 20 séries par le site,
    -- sans pagination) + toutes les séries vues sur l'accueil (« Dernières sorties »,
    -- pages ?page=N), sans doublon. « Dernières sorties » seul = choix « Tri ».
    local want_all = f.sort ~= "latest"
    local novels = {}
    if page == 1 then
        _latest_seen = {}
        if want_all then
            for _, n in ipairs(list_mangas("", 1, nil).novels) do
                if not _latest_seen[n.path] then
                    _latest_seen[n.path] = true
                    novels[#novels + 1] = n
                end
            end
        end
    end
    -- Une série qui sort plusieurs chapitres apparaît plusieurs fois sur l'accueil :
    -- on ne la garde qu'une fois.
    local html = http_get(page == 1 and "/" or ("/?page=" .. page), page > 1)
    if not html then return { novels = novels } end
    local found = parse_latest(html)
    for _, n in ipairs(found) do
        if not _latest_seen[n.path] then
            _latest_seen[n.path] = true
            novels[#novels + 1] = n
        end
    end
    if #found == 0 and page == 1 then
        logger.warn("FMTeam: aucune carte reconnue sur l'accueil")
        dump("Aucune carte reconnue sur l'accueil (" .. #html .. " octets)", html)
        notify("FMTeam : page reçue (" .. #html .. " octets) mais aucune série reconnue.\n"
            .. one_line(title_of(html)):sub(1, 90))
    end
    return { novels = novels }
end

function ext:searchNovels(term, page, options)
    term = tostring(term or "")
    local f = (options and options.filters) or {}
    if term == "" and (not f.genre or f.genre == "") then return self:popularNovels(page, options) end
    return list_mangas(term, page, f.genre)
end

-- Relit la liste des genres sur le site (<select name="genre"> de /mangas) ;
-- en cas d'échec, la liste par défaut reste utilisée.
function ext:loadFilters()
    local html = http_get("/mangas", true)
    if html then
        local sel = html:match('<select[^>]-name="genre"[^>]*>(.-)</select>')
        if sel then
            local list = {}
            for v in sel:gmatch('<option%s+value="([^"]+)"') do
                local g = one_line(v)
                if g ~= "" then list[#list + 1] = g end
            end
            if #list > 0 then
                local opts = genre_options(list)
                GENRE_FILTER.options = opts
            end
        end
    end
    self.filters_ready = true
end

-- ── Étape 4 : fiche de la série ──────────────────────────────────────────────
local function parse_series(html, slug)
    local title = one_line((html:match('class="manga%-title"[^>]*>(.-)</h1>') or ""):gsub("<span.-</span>", ""))
    if title == "" then return nil end

    local author, status, genres = nil, "Unknown", {}
    local header = html:match('class="manga%-meta"[^>]*>(.-)</div>') or ""
    for cls, inner in header:gmatch('<span class="meta%-tag([^"]*)"[^>]*>(.-)</span>') do
        local txt = one_line(inner)
        if txt:find("✍", 1, true) then
            author = (txt:gsub("^✍️?%s*", ""))
        elseif cls:find("status%-") then
            local low = txt:lower()
            if low:find("termin", 1, true) then status = "Completed"
            elseif low:find("cours", 1, true) then status = "Ongoing"
            else status = "Unknown" end
        elseif not txt:find("★", 1, true) and txt ~= "" then
            -- « Action -Sports - Drame » : séparateur = tiret entouré d'espaces
            -- d'un côté au moins (les tirets internes « Slice-of-Life » restent).
            local s = txt:gsub("%s+%-%s*", "|"):gsub("%s*%-%s+", "|")
            for g0 in s:gmatch("[^|]+") do
                local g = g0:match("^%s*(.-)%s*$")
                if g ~= "" then genres[#genres + 1] = g end
            end
        end
    end

    return {
        name    = title,
        path    = slug,
        cover   = abs_url(html:match('class="manga%-cover"%s+src="([^"]+)"')),
        summary = strip_tags(html:match('class="manga%-desc"[^>]*>(.-)</p>') or ""),
        author  = author,
        genres  = genres,
        status  = status,
        type    = "manga",
    }
end

local function fetch_series(slug)
    local html = http_get("/manga/" .. slug)
    if not html then return nil end
    return parse_series(html, slug), html
end

function ext:parseNovelMeta(path)
    local m = fetch_series(tostring(path or ""))
    if not m then return nil, "Fiche FMTeam illisible" end
    m.total_chapters = 0
    return m
end

-- ── Étape 5 : liste des chapitres ────────────────────────────────────────────
-- Libellé « Chapitre 157 : Titre » → n° 157. Les libellés « Tome 4 - Chapitre 33 »
-- et « Punch 239 » donnent respectivement 33 et 239 ; leur adresse de lecture
-- exacte sera vérifiée en partie 2.
local function number_of(label)
    local n = label:match("[Cc]hapitre%s+(%d+[%.,]?%d*)")
        or label:match("^[^:]-(%d+[%.,]?%d*)%s*:")
        or label:match("(%d+[%.,]?%d*)")
    return n and (n:gsub(",", "."))
end

local function parse_chapters(html, slug)
    local chapters = {}
    local MARK = 'class="chapter-item'
    local positions, pos = {}, 1
    while true do
        local s = html:find(MARK, pos, true)
        if not s then break end
        positions[#positions + 1] = s
        pos = s + #MARK
    end
    for i, s in ipairs(positions) do
        local seg = html:sub(s, (positions[i + 1] or #html + 1) - 1)
        local label = one_line(seg:match('class="chapter%-label"[^>]*>(.-)</div>') or "")
        local cid = seg:match("chapter_id=(%d+)")
        local num = number_of(label)
        if label ~= "" and num then
            chapters[#chapters + 1] = {
                name = label,
                path = slug .. "|" .. num .. "|" .. (cid or ""),
                chapter_number = tonumber(num) or 0,
                date = one_line(seg:match('class="chapter%-date"[^>]*>(.-)</div>') or ""),
            }
        end
    end
    -- Le site liste du plus récent au plus ancien ; Sefirah attend l'ordre croissant.
    local rev = {}
    for i = #chapters, 1, -1 do rev[#rev + 1] = chapters[i] end
    return rev
end

function ext:parseNovel(path)
    local slug = tostring(path or "")
    local m, html = fetch_series(slug)
    if not m then
        logger.err("FMTeam: parseNovel fetch failed", slug)
        return nil
    end
    m.chapters   = parse_chapters(html, slug)
    m.totalPages = 1
    if #m.chapters == 0 then
        m.summary = T("⚠ Aucun chapitre trouvé sur cette page.") .. "\n\n" .. (m.summary or "")
    end
    logger.dbg("FMTeam: parseNovel", m.name, "chapitres =", #m.chapters)
    return m
end

-- ── Étape 6 : pages d'un chapitre ────────────────────────────────────────────
-- path = « <slug>|<n°>|<chapter_id> ». Les <img alt="Page"> de #reader-images sont dans
-- le HTML du lecteur, dans l'ordre de lecture.
local function parse_pages(html)
    local from = html:find('id="reader-images"', 1, true) or 1
    local block = html:sub(from)
    local images, seen = {}, {}
    for tag in block:gmatch("<img[^>]+>") do
        if tag:find('alt="Page"', 1, true) then
            local src = tag:match('data%-src="([^"]+)"') or tag:match('src="([^"]+)"')
            src = abs_url(src)
            if src and src:find("/storage/comics/", 1, true) and not seen[src] then
                seen[src] = true
                images[#images + 1] = src
            end
        end
    end
    return images
end

function ext:parseChapterImages(path)
    local slug, num = tostring(path or ""):match("^([^|]+)|([^|]+)")
    if not slug or not num then return nil, "chapitre_invalide" end
    -- Adresse habituelle ; pour les numéros décimaux on essaie aussi la variante « - ».
    local variants = { num }
    if num:find(".", 1, true) then variants[#variants + 1] = (num:gsub("%.", "-")) end
    local last_html
    for _, n in ipairs(variants) do
        local html = http_get("/read/" .. slug .. "/fr/ch/" .. n, true)
        if html then
            last_html = html
            local images = parse_pages(html)
            if #images > 0 then
                return { images = images, headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" } }
            end
        end
    end
    if last_html then dump("Aucune page trouvée pour " .. tostring(path), last_html) end
    return nil, "no_pages"
end

function ext:parseChapter(path)
    return "<p>" .. T("Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.") .. "</p>"
end

return ext
