-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- Royal Road extension for Sefirah
-- Site: https://www.royalroad.com
--
-- Chapter list strategy:
--   The novel page embeds all chapters as  window.chapters = [...]  in an
--   inline <script> tag.  One page fetch gets everything — no pagination.
--
-- Anti-scraping note:
--   RR injects hidden <span> elements with a random CSS class name into chapter
--   text.  They contain junk words and are hidden via  display:none  in a
--   <style> block.  We detect the class name from that style rule and strip
--   matching elements before returning the content.

local BASE   = "https://www.royalroad.com"
local logger = require("logger")

-- ── HTML helpers ──────────────────────────────────────────────────────────────

-- Encode a Unicode codepoint as UTF-8 bytes. Needed for numeric HTML
-- entities (&#x27; &#xED; &#xA0; ...), which RR's review titles/content use
-- heavily for apostrophes, accented letters and non-breaking spaces —
-- strip_tags used to leave these as literal "&#x27;" etc. in the text.
local function utf8_encode(cp)
    if not cp then return "" end
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40),
                            0x80 + (cp % 0x40))
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
    -- Entités numériques d'abord (&#x27; &#xED; &#xA0; ...), avant les
    -- entités nommées ci-dessous.
    s = s:gsub("&#x(%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);",  function(d) return utf8_encode(tonumber(d)) end)
    s = s:gsub("&amp;",  "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
    return s:match("^%s*(.-)%s*$")
end

-- Royal Road : les auteurs ajoutent souvent, à la suite du vrai synopsis,
-- des paragraphes promotionnels (Discord, Patreon, planning de publication,
-- crédit de cover) — parfois après une ligne séparatrice (*****, -----,
-- ─────...), parfois sans aucun séparateur. On retire ce superflu pour ne
-- garder que le synopsis.
local NOISE_PATTERNS = {
    "discord%.gg", "discord%.com/invite", "join .- discord", "discord server",
    "patreon%.com", "on patreon", "support me on", "support the author",
    "ko%-fi%.com", "buy me a coffee",
    "follow me on", "twitter%.com", "x%.com/", "instagram%.com", "reddit%.com/r/",
    "cover art by", "cover art credit", "cover by", "cover credit", "cover design by",
    "release schedule", "publication schedule", "posting schedule",
    "chapters? a week", "chapters? per week", "new chapters? every",
    "chapters? on .- days",
}

local function is_noise_paragraph(p)
    local lower = p:lower()
    for _, pat in ipairs(NOISE_PATTERNS) do
        if lower:find(pat) then return true end
    end
    return false
end

local function clean_royalroad_summary(summary)
    summary = tostring(summary or "")

    -- Coupe au premier séparateur ligne (*****, -----, =====, ~~~~~,
    -- ───── , # # # # #...) : tout ce qui suit n'est généralement plus le
    -- synopsis mais une section promo.
    local sep_pos = summary:find("[%*%-=~_#]%s*[%*%-=~_#]%s*[%*%-=~_#]%s*[%*%-=~_#]%s*[%*%-=~_#]")
    if sep_pos then summary = summary:sub(1, sep_pos - 1) end
    local dash_pos = summary:find("[─―—]%s*[─―—]%s*[─―—]%s*[─―—]%s*[─―—]")
    if dash_pos then summary = summary:sub(1, dash_pos - 1) end

    -- Retire ensuite, paragraphe par paragraphe, le bruit qui traîne sans
    -- séparateur (Discord/Patreon/planning/crédits), où qu'il se trouve.
    local kept = {}
    for para in (summary .. "\n\n"):gmatch("(.-)\n%s*\n") do
        if para:match("%S") and not is_noise_paragraph(para) then
            table.insert(kept, para)
        end
    end
    summary = table.concat(kept, "\n\n")

    return summary:gsub("\n%s*\n%s*\n+", "\n\n"):match("^%s*(.-)%s*$") or ""
end

-- Balanced-div extractor.  Returns inner content and the position immediately
-- after the closing </div>, so callers can continue scanning past it.
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

-- ── HTTP helpers ──────────────────────────────────────────────────────────────

local function http_get(url)
    local body, code = require("core.net").get(url, {
        headers = { ["Accept"] = "text/html,application/xhtml+xml,*/*;q=0.8" },
        timeout = 10,
    })
    if not body then
        logger.err("RoyalRoad: http_get FAILED", url, tostring(code))
        return nil, code
    end
    return body
end

local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return data
end

local function url_encode(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- ── Novel list parser (popular + search share the same card layout) ───────────

-- Novel cards on browse/search pages live inside <figure> tags:
--   <figure>
--     <a href="/fiction/ID/slug">
--       <img alt="Novel Title" src="cover_url" class="thumbnail ...">
--     </a>
--   </figure>
local function parse_novel_list(html)
    local novels = {}
    local seen   = {}
    for fig_inner in html:gmatch('<figure[^>]*>(.-)</figure>') do
        -- Only grab figures that link to a fiction (numeric ID in path)
        local href = fig_inner:match('<a[^>]*href="(/fiction/%d+/[^"]+)"')
        if href then
            local path = href:match("^/(.+)") or href
            if not seen[path] then
                seen[path] = true
                local img   = fig_inner:match('<img[^>]*/?>') or ""
                local name  = img:match('alt="([^"]*)"') or ""
                local cover = img:match('src="([^"]*)"')
                if name ~= "" then
                    table.insert(novels, { name = name, path = path, cover = cover })
                end
            end
        end
    end
    return novels
end

-- ── Shared metadata extractor ─────────────────────────────────────────────────

-- Extracts title, author, cover, status, summary and genres from a novel page.
-- Used by both parseNovelMeta and parseNovel to avoid duplication.
local function parse_meta(html)
    local title  = strip_tags(html:match('<h1[^>]*>(.-)</h1>') or "")
    local author = strip_tags(html:match('<a[^>]*href="/profile/[^"]*"[^>]*>(.-)</a>') or "")

    -- Cover: img with class "thumbnail"
    local cover = html:match('<img[^>]*class="[^"]*thumbnail[^"]*"[^>]*src="([^"]+)"')
               or html:match('<img[^>]*src="([^"]+)"[^>]*class="[^"]*thumbnail[^"]*"')

    -- Status: RR shows two label-sm spans; the second is the novel status.
    -- e.g. <span class="label-sm label-default">ORIGINAL</span>
    --      <span class="label-sm label-warning">ONGOING</span>
    local status  = "Unknown"
    local label_n = 0
    for inner in html:gmatch('<span[^>]*class="[^"]*label%-sm[^"]*"[^>]*>(.-)</span>') do
        label_n = label_n + 1
        if label_n == 2 then
            local t = strip_tags(inner):upper()
            if     t == "ONGOING"   then status = "Ongoing"
            elseif t == "HIATUS"    then status = "Hiatus"
            elseif t == "COMPLETED" then status = "Completed"
            elseif t == "DROPPED"   then status = "Cancelled"
            end
            break
        end
    end

    -- Summary: div.description contains HTML with <p>, <br>, <hr>
    local summary = ""
    local desc = extract_div(html, '<div[^>]*class="[^"]*description[^"]*"')
    if desc then
        desc = desc:gsub('<br[^>]*/?>',   '\n')
               :gsub('<hr[^>]*/?>',       '\n---\n')
               :gsub('</p>',              '\n\n')
        summary = clean_royalroad_summary(strip_tags(desc))
    end

    -- Genres/tags: <span class="tags"><a href="/tag/...">Tag</a> ...</span>
    local genres = {}
    local tags_s = html:find('<span[^>]*class="[^"]*tags[^"]*"')
    if tags_s then
        local tags_e = html:find('</span>', tags_s)
        if tags_e then
            for a_inner in html:sub(tags_s, tags_e):gmatch('<a[^>]*>(.-)</a>') do
                local t = strip_tags(a_inner)
                if t ~= "" then table.insert(genres, t) end
            end
        end
    end

    return {
        title   = title,
        author  = author,
        cover   = cover,
        status  = status,
        summary = summary,
        genres  = table.concat(genres, ", "),
    }
end

-- ── Chapter path helper ───────────────────────────────────────────────────────

-- Converts a full chapter URL from window.chapters into a routable path.
-- Input:  /fiction/12345/novel-slug/chapter/67890/chapter-slug
-- Output: fiction/12345/chapter/67890
-- RR routes by numeric ID; the slugs are only for SEO and can be dropped.
local function chapter_url_to_path(url)
    local parts = {}
    for p in url:gmatch("[^/]+") do table.insert(parts, p) end
    -- [1]=fiction [2]=novelID [3]=novel-slug [4]=chapter [5]=chapterID
    if parts[1] and parts[2] and parts[4] and parts[5] then
        return parts[1] .. "/" .. parts[2] .. "/" .. parts[4] .. "/" .. parts[5]
    end
    return url:match("^/(.+)") or url
end

-- ── Filtres « Parcourir » (ui/browse.lua : ext.popularFilters) ───────────────
-- Les pages de classement de Royal Road (Best Rated, Trending, Ongoing…)
-- acceptent chacune un filtre de genre via ?genre=<id>&page=<n> (le <select
-- name="genre"> visible en haut de chaque page soumet sur elle-même en GET).
-- La liste de genres ci-dessous est celle exposée par ce sélecteur.
local SORT_PATHS = {
    -- "popularity" garde l'ancien comportement par défaut (recherche triée
    -- par popularité) — cette page-là n'accepte pas ?genre=, d'où l'absence
    -- d'entrée ici (cf. build_browse_url : filtre de genre ignoré dessus).
    ["best-rated"]      = "/fictions/best-rated",
    ["trending"]        = "/fictions/trending",
    ["active-popular"]  = "/fictions/active-popular",
    ["complete"]        = "/fictions/complete",
    ["weekly-popular"]  = "/fictions/weekly-popular",
    ["latest-updates"]  = "/fictions/latest-updates",
    ["new"]             = "/fictions/new",
    ["rising-stars"]    = "/fictions/rising-stars",
    ["writathon"]       = "/fictions/writathon",
}

local POPULAR_FILTERS = {
    {
        key = "sort", label = "Tri", default = "popularity",
        options = {
            { id = "popularity",      label = "Popularité" },
            { id = "best-rated",      label = "Mieux notées" },
            { id = "trending",        label = "Tendance" },
            { id = "active-popular",  label = "En cours" },
            { id = "complete",        label = "Terminées" },
            { id = "weekly-popular",  label = "Popu. semaine" },
            { id = "latest-updates",  label = "Dernières M.à.j" },
            { id = "new",             label = "Nouveautés" },
            { id = "rising-stars",    label = "Étoiles montantes" },
            { id = "writathon",       label = "Writathon" },
        },
    },
    {
        key = "genre", label = "Genre", default = "",
        options = {
            { id = "",              label = "Tous" },
            { id = "action",        label = "Action" },
            { id = "adventure",     label = "Adventure" },
            { id = "comedy",        label = "Comedy" },
            { id = "contemporary",  label = "Contemporary" },
            { id = "drama",         label = "Drama" },
            { id = "fantasy",       label = "Fantasy" },
            { id = "historical",    label = "Historical" },
            { id = "horror",        label = "Horror" },
            { id = "mystery",       label = "Mystery" },
            { id = "psychological", label = "Psychological" },
            { id = "romance_main",  label = "Romance" },
            { id = "satire",        label = "Satire" },
            { id = "sci_fi",        label = "Sci-fi" },
            { id = "one_shot",      label = "Short Story" },
            { id = "thriller",      label = "Thriller" },
            { id = "tragedy",       label = "Tragedy" },
        },
    },
}

-- Construit l'URL de liste à partir de la sélection de filtres (peut être nil
-- : comportement d'origine, /fictions/search trié par popularité).
local function build_browse_url(page, filters)
    filters = filters or {}
    local sort  = filters.sort or "popularity"
    local genre = filters.genre or ""

    local path = SORT_PATHS[sort]
    if not path then
        -- "popularity" : pas de ?genre= possible sur cette page (elle utilise
        -- un système de tags différent, /fictions/search?tagsAdd=...).
        return BASE .. "/fictions/search?page=" .. page .. "&orderBy=popularity"
    end

    local url = BASE .. path .. "?page=" .. page
    if genre ~= "" then
        url = url .. "&genre=" .. genre
    end
    return url
end

-- ── Extension table ───────────────────────────────────────────────────────────

local ext = {
    id      = "royalroad",
    name    = "Royal Road",
    site    = BASE,
    lang    = "en",
    version = "1.2.0",
    maxReviews = 150, -- limite d'avis affichés (même valeur pour toutes les extensions) : au-delà, plus de page à droite
    -- Contrairement à novelfrance.lua, qui injecte ses commentaires de fin
    -- de chapitre directement en texte dans le chapitre, cette source
    -- expose ses commentaires via un panneau dédié à chargement incrémental
    -- (bouton "Charger plus", 10 par page) — cf. ext:parseChapterComments
    -- plus bas et ui/readerview.lua:ReaderView.openChapterComments.
    chapterCommentsPanel = true,
    -- Filtres proposés par l'onglet Parcourir (icône « tri ») — classement /
    -- tri et genre.
    popularFilters = POPULAR_FILTERS,
}

function ext:popularNovels(page, options)
    page = page or 1
    -- options.filters vient de ui/browse.lua (sélection courante des
    -- popularFilters ci-dessus) ; absent = comportement d'origine.
    local url = build_browse_url(page, options and options.filters)
    logger.dbg("RoyalRoad: popularNovels page=", page, "url=", url)
    local html = http_get(url)
    if not html then return { novels = {} } end
    local novels = parse_novel_list(html)
    logger.dbg("RoyalRoad: popularNovels found", #novels)
    return { novels = novels }
end

function ext:searchNovels(term, page)
    page = page or 1
    local url = BASE .. "/fictions/search?page=" .. page
        .. "&title=" .. url_encode(term) .. "&globalFilters=true"
    logger.dbg("RoyalRoad: searchNovels term=", term)
    local html = http_get(url)
    if not html then return { novels = {} } end
    local novels = parse_novel_list(html)
    logger.dbg("RoyalRoad: searchNovels found", #novels)
    return { novels = novels }
end

-- parseNovelMeta: fast path for chapter cache.
-- Fetches the novel page once and counts chapters from window.chapters
-- without doing a full JSON decode — just counts "id": occurrences.
function ext:parseNovelMeta(path)
    local url = (path:match("^https?://") and path) or (BASE .. "/" .. path)
    local html = http_get(url)
    if not html then return nil end

    local meta = parse_meta(html)

    local total_chapters = 0
    local raw = html:match('window%.chapters%s*=%s*(%b[])')
    if raw then
        for _ in raw:gmatch('"id"%s*:') do
            total_chapters = total_chapters + 1
        end
    end

    logger.dbg("RoyalRoad: parseNovelMeta title=", meta.title, "total_chapters=", total_chapters)
    return {
        name           = meta.title,
        path           = path,
        cover          = meta.cover,
        summary        = meta.summary,
        author         = meta.author,
        status         = meta.status,
        total_chapters = total_chapters,
    }
end

function ext:parseNovel(path)
    local url = (path:match("^https?://") and path) or (BASE .. "/" .. path)
    logger.dbg("RoyalRoad: parseNovel", url)
    local html = http_get(url)
    if not html then
        logger.err("RoyalRoad: parseNovel fetch failed", url)
        return nil
    end

    local meta = parse_meta(html)

    -- Chapter list from embedded window.chapters JSON
    local chapters = {}
    local raw = html:match('window%.chapters%s*=%s*(%b[])')
    if raw then
        local data = json_decode(raw)
        if data then
            for _, ch in ipairs(data) do
                if ch.url then
                    table.insert(chapters, {
                        name           = ch.title or ("Chapter " .. tostring(ch.order or #chapters + 1)),
                        path           = chapter_url_to_path(ch.url),
                        chapter_number = ch.order,
                    })
                end
            end
            logger.dbg("RoyalRoad: parseNovel chapters=", #chapters)
        else
            logger.warn("RoyalRoad: parseNovel could not decode window.chapters")
        end
    else
        logger.warn("RoyalRoad: parseNovel window.chapters not found in page")
    end

    return {
        name       = meta.title,
        path       = path,
        cover      = meta.cover,
        summary    = meta.summary,
        author     = meta.author,
        genres     = meta.genres,
        status     = meta.status,
        chapters   = chapters,
        totalPages = 1,
    }
end

function ext:parseChapter(path)
    local url = (path:match("^https?://") and path) or (BASE .. "/" .. path)
    local html = http_get(url)
    if not html then return "<p>Error fetching chapter.</p>" end

    -- Detect RR's hidden-text class from the inline style block.
    -- RR adds  .randomClassName { display: none; }  and injects spans with that
    -- class into the chapter text to break naive scrapers.
    local hidden_class = html:match('<style>%s*%.([%w_%-]+)%s*{[^}]-display%s*:%s*none')
    if hidden_class then
        logger.dbg("RoyalRoad: hidden class detected:", hidden_class)
    end

    -- Chapter body only. Les notes d'auteur (author-note-portlet, avant et/ou
    -- après le texte) ne font pas partie du chapitre : ce sont des messages
    -- de l'auteur (promo Discord/Patreon/Kindle/Tapas, avatar, bannières
    -- d'autres romans...) qui alourdissent chaque chapitre téléchargé pour
    -- rien (images à récupérer, texte à afficher) sans rien apporter à la
    -- lecture — on ne les récupère donc même plus (économise aussi la
    -- recherche de leur position dans le HTML).
    local content = extract_div(html, '<div[^>]*class="[^"]*chapter%-content[^"]*"')
    if not content then
        return "<p>Could not extract chapter content.</p>"
    end

    -- Strip hidden spam elements by their class
    if hidden_class then
        local esc = hidden_class:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1')
        content = content:gsub('<[^>]*class="[^"]*' .. esc .. '[^"]*"[^>]*>(.-)</', '</')
    end

    -- Le texte du chapitre lui-même peut contenir des images (illustrations
    -- d'auteur intégrées au récit) : celles-ci restent, seule la note
    -- d'auteur ci-dessus est retirée.

    return content
end

-- ── Reviews ──────────────────────────────────────────────────────────────
-- Confirmé le 2026-09-13 sur du vrai HTML royalroad.com : les avis sont
-- intégrés directement dans la page fiche du roman (pas d'API JSON séparée
-- comme novelfrance.fr), un bloc `<div class="review" id="review-<id>">`
-- par avis, paginés classiquement via `?reviews=N` (10 avis/page). La page
-- affiche une barre de pagination en bas avec un lien "Next ›" tant qu'il
-- reste des pages — c'est ce qu'on utilise pour has_more.

-- Score global : <div aria-label="Overall Score">Overall</div> suivi de
-- <div aria-label="4.5 stars">...</div> — le nombre est dans l'attribut
-- aria-label du second <div>, pas dans les classes star-XX (qui existent
-- aussi mais sont moins directes à parser, ex. star-45 = 4.5 avec /5 —
-- l'aria-label donne directement la valeur décimale).
local function extract_review_score(block)
    local s = block:match('aria%-label="Overall Score">.-aria%-label="([%d%.]+) stars"')
    return s and tonumber(s) or nil
end

local function block_to_review(block, id)
    local author = strip_tags(
        block:match('<a class="small" href="/profile/%d+">(.-)</a>') or "")

    local avatar = block:match('class="img%-circle"[^>]*src="([^"]+)"')
    if avatar and avatar:match("anon%.jpg$") then
        -- Avatar par défaut de RR pour les comptes sans photo : pas la peine
        -- de la (télé)charger, ce n'est jamais qu'un placeholder générique.
        avatar = nil
    elseif avatar and not avatar:match("^https?://") then
        avatar = BASE .. avatar
    end

    local rating = extract_review_score(block)

    -- <time unixtime="1714053190" datetime="2024-04-25T13:53:10.0000000" ...>
    -- Le format_review_date de ui/detail.lua attend juste "YYYY-MM-DD..." en
    -- tête de chaîne, ce que ce datetime fournit tel quel.
    local date = block:match('<time[^>]*datetime="([^"]+)"')

    local title = strip_tags(
        block:match('<h4 class="bold font%-blue%-dark">(.-)</h4>') or "")

    local content_html = extract_div(block, '<div class="review%-inner"')
    local content = ""
    if content_html then
        content_html = content_html:gsub('<br[^>]*/?>%s*', '\n'):gsub('</p>%s*', '\n\n')
        content = strip_tags(content_html):gsub('\n\n\n+', '\n\n'):match("^%s*(.-)%s*$")
    end
    -- Le titre de l'avis ("It's quite good.", "Not for me"...) n'a pas son
    -- propre champ dans le contrat parseReviews — on le préfixe au contenu
    -- plutôt que de le perdre, comme le fait novelfrance.lua pour ses avis.
    if title ~= "" then
        content = (content ~= "") and (title .. "\n\n" .. content) or title
    end

    if author == "" and content == "" then return nil end
    return {
        author  = author ~= "" and author or "Anonyme",
        rating  = rating,
        content = content,
        avatar  = avatar,
        date    = date,
        id      = id,
    }
end

-- Extrait tous les blocs .review d'un HTML de page (fiche roman OU page
-- dédiée /fictions/reviews/<id>, cf. plus bas) — factorisé pour ne parser
-- qu'une seule fois quelle que soit l'URL essayée.
local function parse_review_blocks(html)
    local reviews = {}
    local pos = 1
    while true do
        local id
        local s = html:find('<div class="review" id="review%-%d+"', pos)
        if not s then break end
        id = html:match('id="review%-(%d+)"', s)
        local block, next_pos = extract_div(html, '<div class="review" id="review%-%d+"', pos)
        if not block then break end
        local ok, r = pcall(block_to_review, block, id)
        if ok and r then table.insert(reviews, r) end
        pos = next_pos or (#html + 1)
    end
    return reviews
end

local function fiction_id_from_path(path)
    return tostring(path or ""):match("fiction/(%d+)")
end

-- Tri des avis : URL dédiée confirmée par capture Network le 2026-09-19 —
-- https://www.royalroad.com/fictions/reviews/<fictionId>?sorting=newest|oldest|upvotes
-- — DISTINCTE de la page fiche utilisée jusqu'ici pour le parsing
-- (`?reviews=N` sur /fiction/<id>/<slug>, confirmé le 2026-09-13, sans tri
-- possible). On suppose que le composant .review y est identique (même
-- gabarit réutilisé sur les deux pages), mais ce n'est PAS vérifié aussi
-- précisément que la page fiche : si ça renvoie 0 avis en page 1 (forme
-- inattendue), on retombe sur la page fiche sans tri plutôt que d'afficher
-- un onglet vide — mieux vaut ignorer le tri demandé qu'un échec silencieux.
local REVIEW_SORT_MAP = { newest = "newest", oldest = "oldest", mostliked = "upvotes" }

function ext:parseReviews(path, page, sort)
    page = page or 1
    local sorting     = REVIEW_SORT_MAP[sort]
    local fiction_id  = fiction_id_from_path(path)
    local fallback_url = (path:match("^https?://") and path) or (BASE .. "/" .. path)
    fallback_url = fallback_url .. "?reviews=" .. tostring(page)

    local urls = {}
    if sorting and fiction_id then
        urls[#urls + 1] = BASE .. "/fictions/reviews/" .. fiction_id
            .. "?sorting=" .. sorting .. "&page=" .. tostring(page)
    end
    urls[#urls + 1] = fallback_url

    for i, url in ipairs(urls) do
        local html = http_get(url)
        if not html then
            logger.err("RoyalRoad: parseReviews fetch failed for", url)
        else
            local reviews = parse_review_blocks(html)
            local has_more = html:find("Next &rsaquo;", 1, true) ~= nil
            -- Réponse exploitable : des avis, une fin de liste (page > 1), ou
            -- le dernier candidat de toute façon (mieux vaut un résultat non
            -- trié qu'aucun résultat). Sinon on essaie le candidat suivant.
            if #reviews > 0 or page > 1 or i == #urls then
                if i > 1 and sorting then
                    logger.warn("RoyalRoad: parseReviews — endpoint trié en échec, repli sans tri pour", path)
                end
                if #reviews == 0 and page == 1 then
                    logger.warn("RoyalRoad: parseReviews — 0 avis extraits pour", path)
                end
                return { reviews = reviews, has_more = has_more }
            end
        end
    end

    return { reviews = {}, has_more = false }
end

-- ── Commentaires de chapitre ────────────────────────────────────────────
-- Pas encore confirmé par capture DevTools (contrairement à parseReviews
-- ci-dessus, confirmé le 2026-09-13). RR affiche, sous le texte de chaque
-- chapitre, une section de commentaires paginée classiquement, par
-- analogie avec la pagination `?reviews=N` déjà confirmée pour les avis
-- sur la page fiche : on essaie `?comments=N` sur l'URL du chapitre. Un
-- commentaire suit vraisemblablement le même gabarit Bootstrap que les
-- avis : <div class="comment" id="comment-<id>">...<div class="comment-inner">
-- (par analogie avec class="review" id="review-<id>" / div.review-inner).
-- À ajuster si le HTML réel diffère (même démarche que pour parseReviews :
-- capture DevTools puis correction ciblée).
--
-- Toujours 10 commentaires par appel (PAGE_SIZE), indépendamment de ce que
-- RR renvoie par page côté serveur.
local function block_to_chapter_comment(block, id)
    local author = strip_tags(
        block:match('<a class="small" href="/profile/%d+">(.-)</a>') or "")

    local avatar = block:match('class="img%-circle"[^>]*src="([^"]+)"')
    if avatar and avatar:match("anon%.jpg$") then
        avatar = nil
    elseif avatar and not avatar:match("^https?://") then
        avatar = BASE .. avatar
    end

    local date = block:match('<time[^>]*datetime="([^"]+)"')

    local content_html = extract_div(block, '<div class="comment%-inner"')
        or extract_div(block, '<div class="media%-body"')
    local content = ""
    if content_html then
        content_html = content_html:gsub('<br[^>]*/?>%s*', '\n'):gsub('</p>%s*', '\n\n')
        content = strip_tags(content_html):gsub('\n\n\n+', '\n\n'):match("^%s*(.-)%s*$")
    end

    if author == "" and content == "" then return nil end
    return {
        author  = author ~= "" and author or "Anonyme",
        content = content,
        avatar  = avatar,
        date    = date,
        id      = id,
    }
end

function ext:parseChapterComments(path, page)
    page = tonumber(page) or 1
    if page < 1 then page = 1 end
    local PAGE_SIZE = 10

    local url = (path:match("^https?://") and path) or (BASE .. "/" .. path)
    url = url .. (url:find("?") and "&" or "?") .. "comments=" .. tostring(page)

    logger.dbg("RoyalRoad: parseChapterComments page=", page, "url=", url)
    local html = http_get(url)
    if not html then
        logger.err("RoyalRoad: parseChapterComments fetch failed for", url)
        return { comments = {}, has_more = false }
    end

    local comments = {}
    local pos = 1
    while #comments < PAGE_SIZE do
        local s = html:find('<div class="comment" id="comment%-%d+"', pos)
        if not s then break end
        local id = html:match('id="comment%-(%d+)"', s)
        local block, next_pos = extract_div(html, '<div class="comment" id="comment%-%d+"', pos)
        if not block then break end
        local ok, c = pcall(block_to_chapter_comment, block, id)
        if ok and c then comments[#comments + 1] = c end
        pos = next_pos or (#html + 1)
    end

    -- Pagination : présence d'un lien "Next ›" (même marqueur que pour les
    -- avis, cf. parseReviews plus haut).
    local has_more = html:find("Next &rsaquo;", 1, true) ~= nil

    return { comments = comments, has_more = has_more, page = page }
end

return ext
