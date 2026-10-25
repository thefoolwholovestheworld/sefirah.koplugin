-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- NovelFire extension for Sefirah
-- Site: https://novelfire.net
-- Chapter list strategy (from reverse-engineering the site's JS):
--   1. Fetch {novelUrl}/chapters page
--   2. Scan inline <script> tags for "/listChapterDataAjax"
--   3. Build the DataTables AJAX URL and fetch JSON → all chapters at once
--   4. Fallback: parse paginated HTML chapter list (used in Page Mode)
-- Page Mode (extension-specific toggle):
--   OFF (default) – fetch all chapters via AJAX in one call
--   ON            – use HTML pagination; parsePage() fetches each page lazily

local BASE   = "https://novelfire.net"
local logger = require("logger")

-- ── HTML pattern helpers ──────────────────────────────────────────────────────

local function attr(tag_html, name)
    return tag_html:match(name .. '="([^"]*)"')
        or tag_html:match(name .. "='([^']*)'")
end

-- Encode un codepoint Unicode en UTF-8 — pour décoder les entités HTML
-- numériques (&#x27; &#xE9; ...) que strip_tags laissait telles quelles.
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
    s = s:gsub("&#x(%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);",  function(d) return utf8_encode(tonumber(d)) end)
    s = s:gsub("&amp;",  "&")
        :gsub("&lt;",   "<")
        :gsub("&gt;",   ">")
        :gsub("&quot;", '"')
        :gsub("&#39;",  "'")
        :gsub("&nbsp;", " ")
    return s:match("^%s*(.-)%s*$")
end

-- NovelFire peut renvoyer le numéro de position de la liste devant le vrai
-- titre ("4: Chapter 3184: Insidious Traps"). Ce numéro n'est pas le titre.
local function clean_chapter_title(title)
    title = strip_tags(title or "")
    title = title:gsub("^%s*%d+%s*:%s*", "")
    return title:match("^%s*(.-)%s*$")
end

-- Nettoie la description NovelFire : le site ajoute après le vrai synopsis
-- un message technique destiné aux lecteurs du site. On garde uniquement le
-- texte situé avant ce message.
local function clean_novelfire_summary(summary)
    summary = tostring(summary or "")
    local pos = summary:find("If you find any errors", 1, true)
    if pos then
        summary = summary:sub(1, pos - 1)
    end
    -- Étiquette "Summary" que NovelFire place juste au-dessus du synopsis
    -- (un petit titre dans leur propre mise en page, pas utile une fois le
    -- texte affiché dans la fiche du plugin) — toujours en tout début de bloc.
    summary = summary:gsub("^%s*[Ss]ummary%s*", "")
    -- Bouton "Show More" que NovelFire ajoute en fin de synopsis pour replier
    -- le texte sur leur site — sans effet ici puisque la fiche du plugin
    -- affiche toujours le texte en entier.
    summary = summary:gsub("%s*[Ss]how%s+[Mm]ore%.?%s*$", "")
    summary = summary:gsub("\n%s*\n%s*\n+", "\n\n")
    return summary:match("^%s*(.-)%s*$") or ""
end

-- ── Chapter list parsers ──────────────────────────────────────────────────────

-- Parse <ul class="chapter-list"> from LightNovelWorld-style HTML
-- Returns list of {name, path}
local function parse_chapter_list_html(html, novel_root)
    local chapters = {}
    -- Find all <a> inside ul.chapter-list
    local ul = html:match('<ul[^>]*class="[^"]*chapter%-list[^"]*"[^>]*>(.-)</ul>')
    if not ul then return chapters end
    for a_tag, inner in ul:gmatch('(<a[^>]+>)(.-)</a>') do
        local href = attr(a_tag, "href") or ""
        local path = href:match("^https?://[^/]+(/.+)$") or href
        local title_el = inner:match('<[^>]*class="[^"]*chapter%-title[^"]*"[^>]*>(.-)</')
        local no_el    = inner:match('<[^>]*class="[^"]*chapter%-no[^"]*"[^>]*>(.-)</')
        local title = ""
        local no_text = no_el and strip_tags(no_el) or nil
        if no_text and no_text ~= "" then
            -- Le titre contient déjà "Chapter 3209 ..." : préfixer par le
            -- numéro de la liste afficherait 3209 deux fois.
            local t = clean_chapter_title(title_el or "")
            local num = no_text:match("%d+[%.]?%d*")
            if t == "" then
                title = no_text
            elseif num and t:find(num, 1, true) then
                title = t
            else
                title = no_text .. ": " .. t
            end
        else
            title = clean_chapter_title(title_el or inner)
        end
        if path ~= "" then
            -- Numéro de chapitre : extrait de préférence de l'élément
            -- "chapter-no" ("Chapter 45" / "45"), sinon du titre lui-même
            -- ("Chapitre 45 : ..."). Sans ce champ, compute_step()
            -- (ui/readerview.lua) ne peut jamais détecter si cette page
            -- liste les chapitres du plus ancien au plus récent ou
            -- l'inverse, et retombe sur "ascendant" par défaut — ce qui
            -- inverse Chap. suivant/précédent dès que le site liste du
            -- plus récent au plus ancien.
            local chapter_number = tonumber((no_text or ""):match("%d+[%.]?%d*"))
                or tonumber(title:match("%d+[%.]?%d*"))
            table.insert(chapters, { name = title, path = path, chapter_number = chapter_number })
        end
    end
    return chapters
end

-- Build the DataTables AJAX URL from script tag content (NovelFire-specific)
local function build_ajax_url(chapters_html, base_url)
    local prefix = "/listChapterDataAjax"
    for script_content in chapters_html:gmatch('<script[^>]*>(.-)</script>') do
        local start_idx = script_content:find(prefix, 1, true)
        if start_idx then
            -- Extract from prefix up to the next `",` (end of the URL fragment)
            local frag_end = script_content:find('",', start_idx, true)
            if not frag_end then frag_end = script_content:find("'", start_idx + 1, true) end
            if frag_end then
                local frag = script_content:sub(start_idx, frag_end - 1)
                local host = base_url:match("^https?://([^/]+)")
                if host then
                    -- Append DataTables parameters to fetch all chapters sorted by n_sort
                    local params = table.concat({
                        "draw=1",
                        "columns%5B0%5D%5Bdata%5D=title",
                        "columns%5B0%5D%5Bsearchable%5D=true",
                        "columns%5B0%5D%5Borderable%5D=false",
                        "columns%5B1%5D%5Bdata%5D=created_at",
                        "columns%5B1%5D%5Bsearchable%5D=true",
                        "columns%5B1%5D%5Borderable%5D=true",
                        "columns%5B2%5D%5Bdata%5D=n_sort",
                        "columns%5B2%5D%5Borderable%5D=true",
                        "order%5B0%5D%5Bcolumn%5D=2",
                        "order%5B0%5D%5Bdir%5D=asc",
                        "start=0",
                        "length=-1",
                        "search%5Bvalue%5D=",
                        "search%5Bregex%5D=false",
                    }, "&")
                    return "https://" .. host .. frag .. "&" .. params
                end
            end
        end
    end
    return nil
end

-- ── Balanced-div extractor (handles nested divs correctly) ───────────────────
-- Finds the first div matching open_pattern and returns its full inner content.
-- start_pos/valeur de retour "position suivante" ajoutés pour parseReviews
-- (besoin de boucler sur plusieurs blocs) — rétrocompatible : les appels
-- existants ne récupèrent qu'une seule valeur de retour, donc ignorent
-- silencieusement le next_pos.
local function extract_div(html, open_pattern, start_pos)
    local s, e = html:find(open_pattern, start_pos or 1)
    if not s then return nil, nil end
    local tag_end = html:find('>', e)
    if not tag_end then return nil, nil end
    local depth = 1
    local pos   = tag_end + 1
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

-- ── HTTP helper ───────────────────────────────────────────────────────────────

-- novelfire.net ne renvoie plus la page demandée mais un petit écran « Loading… » qui redirige
-- en JavaScript (window.location.href = "https://novelphoenix.com/novel/…"). KOReader n'exécute
-- pas ce JavaScript : on lit l'adresse et on la suit nous-mêmes. Seuls ces deux domaines sont suivis.
local ALLOWED_HOSTS = { ["novelfire.net"] = true, ["novelphoenix.com"] = true }

local function stub_target(body)
    if type(body) ~= "string" or #body > 6000 then return nil end
    local u = body:match('window%.location%.href%s*=%s*"([^"]+)"')
        or body:match("window%.location%.href%s*=%s*'([^']+)'")
    if not u then return nil end
    u = u:gsub("\\/", "/")
    local host = u:match("^https?://([^/:%?#]+)")
    if host and ALLOWED_HOSTS[host:lower():gsub("^www%.", "")] then return u end
    return nil
end

local function origin_of(url)
    return url:match("^(https?://[^/]+)") or BASE
end

local function http_get(url)
    local body, code
    for _ = 1, 4 do
        body, code = require("core.net").get(url, {
            headers = {
                ["Accept"]  = "text/html,application/xhtml+xml,*/*;q=0.8",
                ["Referer"] = origin_of(url) .. "/",
            },
            timeout = 10,
        })
        if not body then break end
        local nxt = stub_target(body)
        if not nxt or nxt == url then break end
        logger.dbg("NovelFire: redirection JavaScript vers", nxt)
        url = nxt
    end
    if not body then
        logger.err("NovelFire: http_get FAILED url=", url, "code=", tostring(code))
        return nil, code
    end
    return body
end

local function http_get_json(url)
    logger.dbg("NovelFire: http_get_json url=", url)
    local body, err = http_get(url)
    if not body then
        logger.err("NovelFire: http_get_json fetch failed:", tostring(err))
        return nil, err
    end
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok2, data = pcall(JSON.decode, body)
    if not ok2 then
        logger.err("NovelFire: JSON decode error:", tostring(data))
        return nil, "json_error"
    end
    logger.dbg("NovelFire: http_get_json decode ok, type=", type(data))
    return data
end

-- ── Filtres « Parcourir » (ui/browse.lua : ext.popularFilters) ───────────────
-- NovelFire expose deux familles de listes, toutes deux couvertes ici :
--   • les pages de genre  : /genre-<genre>/sort-<tri>/status-<statut>/<pays>
--   • les classements     : /ranking, /ranking/ratings, /ranking/most-read,
--                           /ranking/most-review, /ranking/most-comment,
--                           /ranking/most-lib
-- Les classements sont globaux côté site : ils n'acceptent ni genre, ni
-- statut, ni pays. Quand un classement est choisi ET qu'un de ces trois
-- filtres n'est pas sur « Tous », on retombe donc sur la page de genre
-- correspondante triée par popularité (cf. build_browse_url plus bas) —
-- c'est ce qui se rapproche le plus d'un « classement filtré ».
local RANKING_PATHS = {
    ["rank"]         = "/ranking",
    ["ratings"]      = "/ranking/ratings",
    ["most-read"]    = "/ranking/most-read",
    ["most-review"]  = "/ranking/most-review",
    ["most-comment"] = "/ranking/most-comment",
    ["most-lib"]     = "/ranking/most-lib",
}

local POPULAR_FILTERS = {
    {
        key = "genre", label = "Genre", default = "all",
        options = {
            { id = "all", label = "All" },
            { id = "action", label = "Action" },
            { id = "adult", label = "Adult" },
            { id = "adventure", label = "Adventure" },
            { id = "anime", label = "Anime" },
            { id = "arts", label = "Arts" },
            { id = "comedy", label = "Comedy" },
            { id = "drama", label = "Drama" },
            { id = "eastern", label = "Eastern" },
            { id = "ecchi", label = "Ecchi" },
            { id = "fan-fiction", label = "Fan-fiction" },
            { id = "fantasy", label = "Fantasy" },
            { id = "game", label = "Game" },
            { id = "gender-bender", label = "Gender Bender" },
            { id = "harem", label = "Harem" },
            { id = "historical", label = "Historical" },
            { id = "horror", label = "Horror" },
            { id = "isekai", label = "Isekai" },
            { id = "josei", label = "Josei" },
            { id = "lgbt", label = "Lgbt+" },
            { id = "magic", label = "Magic" },
            { id = "magical-realism", label = "Magical realism" },
            { id = "manhua", label = "Manhua" },
            { id = "martial-arts", label = "Martial Arts" },
            { id = "mature", label = "Mature" },
            { id = "mecha", label = "Mecha" },
            { id = "military", label = "Military" },
            { id = "modern-life", label = "Modern life" },
            { id = "movies", label = "Movies" },
            { id = "mystery", label = "Mystery" },
            { id = "other", label = "Other" },
            { id = "psychological", label = "Psychological" },
            { id = "realistic-fiction", label = "Realistic fiction" },
            { id = "reincarnation", label = "Reincarnation" },
            { id = "romance", label = "Romance" },
            { id = "school-life", label = "School Life" },
            { id = "sci-fi", label = "Sci-fi" },
            { id = "seinen", label = "Seinen" },
            { id = "shoujo", label = "Shoujo" },
            { id = "shoujo-ai", label = "Shoujo ai" },
            { id = "shounen", label = "Shounen" },
            { id = "shounen-ai", label = "Shounen Ai" },
            { id = "slice-of-life", label = "Slice of Life" },
            { id = "smut", label = "Smut" },
            { id = "sports", label = "Sports" },
            { id = "supernatural", label = "Supernatural" },
            { id = "system", label = "System" },
            { id = "tragedy", label = "Tragedy" },
            { id = "urban", label = "Urban" },
            { id = "urban-life", label = "Urban life" },
            { id = "video-games", label = "Video games" },
            { id = "war", label = "War" },
            { id = "wuxia", label = "Wuxia" },
            { id = "xianxia", label = "Xianxia" },
            { id = "xuanhuan", label = "Xuanhuan" },
            { id = "yaoi", label = "Yaoi" },
            { id = "yuri", label = "Yuri" },
        },
    },
    {
        key = "sort", label = "Tri", default = "rank",
        options = {
            -- Classements (globaux)
            { id = "rank",           label = "Classement" },
            { id = "ratings",        label = "Note" },
            { id = "most-read",      label = "Lectures" },
            { id = "most-review",    label = "Avis" },
            { id = "most-comment",   label = "Commentaires" },
            { id = "most-lib",       label = "Collections" },
            -- Pages de genre
            { id = "new",            label = "Nouveautés" },
            { id = "popular",        label = "Populaire" },
            { id = "latest-release", label = "Mises à jour" },
        },
    },
    {
        key = "status", label = "Statut", default = "all",
        options = {
            { id = "all",       label = "Tous" },
            { id = "completed", label = "Terminé" },
            { id = "ongoing",   label = "En cours" },
        },
    },
    {
        key = "country", label = "Pays", default = "all-novel",
        options = {
            { id = "all-novel",      label = "Tous" },
            { id = "chinese-novel",  label = "Chinois" },
            { id = "japanese-novel", label = "Japonais" },
            { id = "english-novel",  label = "Anglais" },
        },
    },
}

-- Construit l'URL de liste à partir de la sélection de filtres (peut être nil
-- : on retombe alors sur le classement général, comportement d'origine).
local function build_browse_url(page, filters)
    filters = filters or {}
    local genre   = filters.genre   or "all"
    local sort    = filters.sort    or "rank"
    local status  = filters.status  or "all"
    local country = filters.country or "all-novel"

    local ranking = RANKING_PATHS[sort]
    if ranking then
        if genre == "all" and status == "all" and country == "all-novel" then
            return BASE .. ranking .. "?page=" .. page
        end
        -- Classement + filtres : le site ne sait pas faire, on bascule sur la
        -- page de genre triée par popularité.
        sort = "popular"
    end

    return string.format("%s/genre-%s/sort-%s/status-%s/%s?page=%d",
        BASE, genre, sort, status, country, page)
end

-- ── Extension table ───────────────────────────────────────────────────────────

local ext = {
    id              = "novelfire",
    name            = "NovelFire",
    site            = BASE,
    lang            = "en",
    version         = "1.4.0",
    maxReviews      = 150,  -- limite d'avis affichés (même valeur pour toutes les extensions) : au-delà, plus de page à droite
    supports_page_mode = true,  -- signals UI to show the Page Mode toggle
    -- Contrairement à novelfrance.lua, qui injecte ses commentaires de fin
    -- de chapitre directement en texte dans le chapitre, cette source
    -- expose ses commentaires via un panneau dédié à chargement incrémental
    -- (bouton "Charger plus", 10 par page) — cf. ext:parseChapterComments
    -- plus bas et ui/readerview.lua:ReaderView.openChapterComments.
    chapterCommentsPanel = true,
    -- Filtres proposés par l'onglet Parcourir (icône « tri ») — genre, tri /
    -- classement, statut de traduction et pays d'origine.
    popularFilters = POPULAR_FILTERS,
}

-- popularNovels(page, options) → {novels=[{name,path,cover}]}
-- Uses /ranking — novel cards are <li class="novel-item">
function ext:popularNovels(page, options)
    page = page or 1
    -- options.filters vient de ui/browse.lua (sélection courante des
    -- popularFilters ci-dessus) ; absent = classement général, comme avant.
    local url = build_browse_url(page, options and options.filters)
    logger.dbg("NovelFire: popularNovels page=", page, "url=", url)
    local html, err = http_get(url)
    if not html then
        logger.err("NovelFire: popularNovels fetch failed:", tostring(err))
        return {novels = {}}
    end
    logger.dbg("NovelFire: popularNovels html_len=", #html)

    local novels = {}
    for li_open, li_inner in html:gmatch('(<li[^>]*class="[^"]*novel%-item[^"]*"[^>]*>)(.-)</li>') do
        -- href may be on the wrapping <a> or on a nested <a>
        local a_href = li_inner:match('<a[^>]*href="(/book/[^"]+)"')
            or li_inner:match('<a[^>]*href="([^"]+)"')
        -- title: <h2 class="title ..."> or <h4 class="novel-title ...">
        local title = strip_tags(
            li_inner:match('<h%d[^>]*class="[^"]*title[^"]*"[^>]*>(.-)</h%d>') or "")
        local cover = li_inner:match('<img[^>]*data%-src="([^"]+)"')
            or li_inner:match('<img[^>]*src="([^"]+)"')
        if a_href and title ~= "" then
            local path = a_href:match("^https?://[^/]+(/.+)$") or a_href
            table.insert(novels, { name = title, path = path, cover = cover })
        end
    end
    logger.dbg("NovelFire: popularNovels found", #novels, "novels")
    if #novels == 0 then
        logger.warn("NovelFire: popularNovels got 0 results. HTML snippet (first 500):", html:sub(1, 500))
    end
    return { novels = novels }
end

-- searchNovels(term, page) → {novels=[{name,path,cover}]}
function ext:searchNovels(term, page)
    page = page or 1
    local encoded = term:gsub(" ", "+"):gsub("([^%w%+%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end)
    local url  = BASE .. "/search?keyword=" .. encoded .. "&page=" .. page
    logger.dbg("NovelFire: searchNovels term=", term, "url=", url)
    local html = http_get(url)
    if not html then
        logger.err("NovelFire: searchNovels fetch failed")
        return {novels = {}}
    end
    logger.dbg("NovelFire: searchNovels html_len=", #html)

    -- Search page: <li class="novel-item"><a href="/book/...">...<h4 class="novel-title ...">
    local novels = {}
    for li_open, li_inner in html:gmatch('(<li[^>]*class="[^"]*novel%-item[^"]*"[^>]*>)(.-)</li>') do
        local a_href = li_inner:match('<a[^>]*href="(/book/[^"]+)"')
            or li_inner:match('<a[^>]*href="([^"]+)"')
        local title = strip_tags(
            li_inner:match('<h%d[^>]*class="[^"]*title[^"]*"[^>]*>(.-)</h%d>') or "")
        local cover = li_inner:match('<img[^>]*src="([^"]+)"')
            or li_inner:match('<img[^>]*data%-src="([^"]+)"')
        if a_href and title ~= "" then
            local path = a_href:match("^https?://[^/]+(/.+)$") or a_href
            table.insert(novels, { name = title, path = path, cover = cover })
        end
    end
    logger.dbg("NovelFire: searchNovels found", #novels, "novels")
    if #novels == 0 then
        logger.warn("NovelFire: searchNovels got 0 results. HTML snippet (first 500):", html:sub(1, 500))
    end
    return { novels = novels }
end

-- parseNovelMeta(path) → {name,path,cover,summary,author,status,total_chapters}
-- Fast path used by Sefirah for chapter cache: fetches only the main novel page,
-- does NOT fetch the /chapters page. Returns total_chapters = 0 if the main page
-- doesn't expose a chapter count; Sefirah will fall back to parseNovel in that case.
function ext:parseNovelMeta(path)
    local novel_url = (path:match("^https?://") and path) or (BASE .. path)
    local html = http_get(novel_url)
    if not html then return nil end
    logger.dbg("NovelFire: parseNovelMeta html_len=", #html)

    local title = strip_tags(html:match('<h1[^>]*itemprop="name"[^>]*>(.-)</h1>')
        or html:match('<h1[^>]*>(.-)</h1>') or "")

    local author = strip_tags(html:match('<span[^>]*itemprop="author"[^>]*>(.-)</span>') or "")

    local status = "Ongoing"
    local st_class = html:match('<strong class="([%a]+)">[^<]*</strong>[^<]*<small>[^<]*[Ss]tatus')
    if st_class then
        status = st_class:sub(1,1):upper() .. st_class:sub(2)
    end

    local cover = html:match('<meta[^>]*property="og:image"[^>]*content="([^"]+)"')
        or html:match('<figure[^>]*class="[^"]*cover[^"]*"[^>]*>%s*<img[^>]*src="([^"]+)"')

    local summary = ""
    local summary_html = extract_div(html, '<div[^>]*class="[^"]*summary[^"]*"')
    if summary_html then
        summary_html = summary_html:gsub('<br[^>]*/?>%s*', '\n')
            :gsub('</p>%s*', '\n\n')
        summary = clean_novelfire_summary(strip_tags(summary_html))
    end

    -- Try to read chapter count from header-stats on the main page.
    -- Avoids fetching /chapters; returns 0 if no match (triggers full parseNovel).
    local total_chapters = 0
    local stats_block = html:match('<[^>]*class="[^"]*header%-stats[^"]*"[^>]*>(.-)</div>')
    if stats_block then
        -- Pattern: <strong>2010</strong><small>Chapters</small>
        local s = stats_block:match('<strong>([%d,]+)</strong>%s*<small>[^<]*[Cc]hapter')
        -- Fallback: icon-book-open adjacent to number
        if not s then
            s = stats_block:match('icon%-book%-open[^<]*</i>%s*([%d,]+)')
        end
        if s then total_chapters = tonumber((s:gsub(",", ""))) or 0 end
    end
    logger.dbg("NovelFire: parseNovelMeta title=", title, "total_chapters=", total_chapters)

    return {
        name           = title,
        path           = path,
        cover          = cover,
        summary        = summary,
        author         = author,
        status         = status,
        total_chapters = total_chapters,
    }
end

-- parseNovel(path) → {name,path,cover,summary,author,genres,status,chapters,totalPages}
function ext:parseNovel(path)
    local novel_url    = (path:match("^https?://") and path) or (BASE .. path)
    local chapters_url = novel_url:gsub("/?$", "/chapters")

    local main_html = http_get(novel_url)
    if not main_html then
        logger.err("NovelFire: parseNovel fetch failed for", novel_url)
        return nil
    end
    logger.dbg("NovelFire: parseNovel html_len=", #main_html)

    -- Title: <h1 itemprop="name" class="novel-title ...">
    local title = strip_tags(main_html:match('<h1[^>]*itemprop="name"[^>]*>(.-)</h1>')
        or main_html:match('<h1[^>]*>(.-)</h1>') or "")

    -- Author: <span itemprop="author">Name</span>
    local author = strip_tags(main_html:match('<span[^>]*itemprop="author"[^>]*>(.-)</span>') or "")

    -- Status: <strong class="completed">Completed</strong> <small>Status</small>
    local status = "Ongoing"
    local st_class = main_html:match('<strong class="([%a]+)">[^<]*</strong>[^<]*<small>[^<]*[Ss]tatus')
    if st_class then
        status = st_class:sub(1,1):upper() .. st_class:sub(2)
    end
    logger.dbg("NovelFire: parseNovel title=", title, "author=", author, "status=", status)

    -- Summary complet : on récupère tous les paragraphes du bloc, puis on
    -- retire le message technique ajouté par NovelFire après le synopsis.
    local summary = ""
    local summary_html = extract_div(main_html, '<div[^>]*class="[^"]*summary[^"]*"')
    if summary_html then
        summary_html = summary_html:gsub('<br[^>]*/?>%s*', '\n')
            :gsub('</p>%s*', '\n\n')
        summary = clean_novelfire_summary(strip_tags(summary_html))
    end

    -- Cover
    local cover = main_html:match('<meta[^>]*property="og:image"[^>]*content="([^"]+)"')
        or main_html:match('<figure[^>]*class="[^"]*cover[^"]*"[^>]*>%s*<img[^>]*src="([^"]+)"')

    -- Fetch /chapters (page 1)
    local chapters_html = http_get(chapters_url)
    if not chapters_html then
        logger.warn("NovelFire: parseNovel no chapters page for", chapters_url)
        return { name=title, path=path, cover=cover, author=author, status=status,
                 summary=summary, chapters={}, totalPages=1 }
    end
    logger.dbg("NovelFire: parseNovel chapters html_len=", #chapters_html)

    local chapters = {}

    -- Try AJAX first (some novels expose the DataTables endpoint)
    local ajax_url = build_ajax_url(chapters_html, chapters_url)
    if ajax_url then
        logger.dbg("NovelFire: parseNovel AJAX url=", ajax_url)
        local json = http_get_json(ajax_url)
        if json and json.data then
            local root = novel_url:gsub("/?$", "")
            for _, d in ipairs(json.data) do
                -- n_sort est l'ordre réel de tri utilisé par le site (colonne
                -- DataTables columns[2][data]=n_sort, cf. plus haut) : on le
                -- réutilise comme chapter_number pour que compute_step()
                -- (ui/readerview.lua) puisse détecter le sens de la liste.
                table.insert(chapters, {
                    name = clean_chapter_title(d.title or ("Chapter " .. tostring(d.n_sort))),
                    path = root .. "/chapter-" .. tostring(d.n_sort),
                    chapter_number = tonumber(d.n_sort),
                })
            end
            logger.dbg("NovelFire: parseNovel AJAX chapters=", #chapters)
        end
    end

    -- HTML pagination fallback: 100 chapters/page, total from input max attr
    if #chapters == 0 then
        -- Find total chapter count: <input id="gotochapno" ... max="130">
        local max_ch = tonumber(
            chapters_html:match('<input[^>]*id="gotochapno"[^>]*max="(%d+)"') or
            chapters_html:match('<input[^>]*max="(%d+)"[^>]*id="gotochapno"') or
            chapters_html:match('<input[^>]*max="(%d+)"[^>]*name="chapno"') or
            chapters_html:match('<input[^>]*name="chapno"[^>]*max="(%d+)"') or "0") or 0
        local total_pages = max_ch > 0 and math.ceil(max_ch / 100) or 1
        logger.dbg("NovelFire: parseNovel max_ch=", max_ch, "total_pages=", total_pages)

        chapters = parse_chapter_list_html(chapters_html, novel_url)
        logger.dbg("NovelFire: parseNovel page 1 chapters=", #chapters)

        for pg = 2, total_pages do
            logger.dbg("NovelFire: parseNovel fetching chapter page", pg)
            local pg_html = http_get(chapters_url .. "?page=" .. pg)
            if pg_html then
                local more = parse_chapter_list_html(pg_html, novel_url)
                logger.dbg("NovelFire: parseNovel page", pg, "chapters=", #more)
                for _, ch in ipairs(more) do table.insert(chapters, ch) end
            end
        end
        logger.dbg("NovelFire: parseNovel total chapters=", #chapters)
    end

    -- Filet de sécurité : si aucun chapitre n'a de chapter_number (ex. site
    -- qui change son HTML et fait échouer toutes les extractions ci-dessus),
    -- on numérote par ordre d'insertion — cet ordre reflète toujours l'ordre
    -- réel renvoyé par le site pour cette page/requête, donc compute_step()
    -- (ui/readerview.lua) peut au moins détecter s'il est croissant ou
    -- décroissant, plutôt que de retomber en silence sur "ascendant".
    do
        local any_number = false
        for _, ch in ipairs(chapters) do
            if ch.chapter_number then any_number = true break end
        end
        if not any_number then
            for i, ch in ipairs(chapters) do ch.chapter_number = i end
        end
    end

    return {
        name       = title,
        path       = path,
        cover      = cover,
        summary    = summary,
        author     = author,
        status     = status,
        chapters   = chapters,
        totalPages = 1,
    }
end

-- parsePage(path, page) → {chapters=[{name,path}]}
-- Called by the UI when Page Mode is ON and the user requests additional pages.
function ext:parsePage(path, page)
    local novel_url    = (path:match("^https?://") and path) or (BASE .. path)
    local chapters_url = novel_url:gsub("/?$", "/chapters") .. "?page=" .. tostring(page)
    local html = http_get(chapters_url)
    if not html then return { chapters = {} } end
    local chapters = parse_chapter_list_html(html, novel_url)
    return { chapters = chapters }
end

-- parseChapter(path) → HTML string of chapter body
function ext:parseChapter(path)
    local url  = (path:match("^https?://") and path) or (BASE .. path)
    local html = http_get(url)
    if not html then
        -- novelfire.net injoignable : on essaie directement novelphoenix.com (/book/ → /novel/).
        local alt = path:match("^/book/(.+)$")
        if alt then html = http_get("https://novelphoenix.com/novel/" .. alt) end
    end
    if not html then return "<p>Error fetching chapter.</p>" end

    -- Extract chapter content using the balanced-div extractor so nested divs are handled.
    local content = extract_div(html, '<div[^>]*id="chapter%-content"')
        or extract_div(html, '<div[^>]*id="content"[^>]*data%-chapter%-id')
        or extract_div(html, '<div[^>]*id="content"')
        or extract_div(html, '<div[^>]*class="[^"]*chapter%-content[^"]*"')
        or extract_div(html, '<div[^>]*data%-reader%-chapter%-container')
        or extract_div(html, '<div[^>]*id="chapter%-container"')

    -- Dernier recours : le site a changé de structure (ou de domaine : novelfire.net renvoie
    -- maintenant vers novelphoenix.com) — on prend les <p> de la page s'il y en a assez.
    if not content or #content < 200 then
        local paras = {}
        for p in html:gmatch("<p[^>]*>.-</p>") do
            local t = p:gsub("<[^>]+>", ""):gsub("%s+", " ")
            if #t > 3 then paras[#paras + 1] = p end
        end
        if #paras >= 8 then content = table.concat(paras, "\n") end
    end

    if not content then
        -- On garde la réponse reçue pour comprendre ce que le site renvoie.
        pcall(function()
            local dir = require("datastorage"):getSettingsDir() .. "/sefirah"
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
            local f = io.open(dir .. "/novelfire_last_error.txt", "wb")
            if f then
                f:write("chapitre sans contenu : " .. url .. "\ntaille : " .. #html .. "\n\n" .. html:sub(1, 200000))
                f:close()
            end
        end)
        return "<p>Could not extract chapter content.</p>"
    end

    -- Remove les éléments d'interface du site qui ne font pas partie du chapitre.
    -- Cela comprend "Restore scroll position", le bloc Tip/Report et leurs
    -- variantes lorsque NovelFire les place dans un <p>/<div>.
    content = content:gsub(
        '<[^>]*>[%s]*Restore%s+scroll%s+position[%s%S]-</[^>]+>',
        ""
    )
    content = content:gsub('Restore%s+scroll%s+position', "")

    content = content:gsub(
        '<[^>]*>[%s]*Tip:%s*You can use left, right keyboard keys to browse[%s%S]-</[^>]+>',
        ""
    )
    content = content:gsub(
        'Tip:%s*You can use left, right keyboard keys to browse[%s%S]-Report',
        ""
    )
    content = content:gsub('<p[^>]*>[%s]*Report[%s]*</p>', "")
    content = content:gsub('<div[^>]*>[%s]*Report[%s]*</div>', "")

    -- Autre variante du même message d'interface, observée en fin de chapitre
    -- ("Tap the middle of the screen to reveal Reading Options. If you find
    -- any errors (...) Please let us know so we can fix it as soon as
    -- possible. Report") : même stratégie que Tip: ci-dessus, un gsub pour le
    -- cas où c'est un seul bloc balisé, un second pour le texte brut qui
    -- s'étale sur plusieurs éléments jusqu'à "Report".
    content = content:gsub(
        '<[^>]*>[%s]*Tap%s+the%s+middle%s+of%s+the%s+screen%s+to%s+reveal%s+Reading%s+Options%.[%s%S]-</[^>]+>',
        ""
    )
    content = content:gsub(
        'Tap%s+the%s+middle%s+of%s+the%s+screen%s+to%s+reveal%s+Reading%s+Options%.[%s%S]-Report',
        ""
    )
    content = content:gsub(
        '<[^>]*>[%s]*If%s+you%s+find%s+any%s+errors[%s%S]-</[^>]+>',
        ""
    )
    content = content:gsub(
        'If%s+you%s+find%s+any%s+errors[%s%S]-Report',
        ""
    )

    -- « Report » isolé en fin de chapitre (bouton du site) : retire tout
    -- élément (p, div, a, button, span…) dont le seul texte est « Report »,
    -- même imbriqué (<p><a>Report</a></p>), puis le texte brut final.
    for _ = 1, 3 do
        content = content:gsub('<(%a[%w]*)[^>]*>%s*Report%s*</%1>', "")
        content = content:gsub('<(%a[%w]*)[^>]*>%s*</%1>', "")
    end
    content = content:gsub('%s*Report%s*$', "")

    -- Remove watermarks (elements with any class attribute, as per LightNovelWorldParser)
    content = content:gsub('<p[^>]*class="[^"]*"[^>]*>.-</p>', "")
    -- Remove nested strong watermarks
    content = content:gsub('<strong><strong>.-</strong></strong>', "")
    -- Collapse whitespace
    content = content:gsub("%s*\n%s*\n%s*", "\n\n")

    return content
end

-- ── Reviews ──────────────────────────────────────────────────────────────
-- Confirmé le 2026-09-13 sur du vrai HTML de novelfire.net/book/<slug>/reviews
-- (page "Shadow Slave Novel User Reviews") : contrairement à Royal Road, les
-- avis sont sur une page dédiée (novel_path .. "/reviews"), pas sur la page
-- fiche elle-même. Un avis = <div class="review-item" data-revid="<id>">
-- dans <div id="review_load">.
--
-- Pagination confirmée le 2026-09-14 (capture DevTools) : pas d'endpoint
-- Ajax séparé, une simple query string ?page=N sur l'URL /reviews
-- (novelfire.net/book/<slug>/reviews?page=2, navigation par numéros de
-- page classique). parseReviews fetch donc directement cette page ; comme
-- on n'a pas le nombre total de pages ni de marqueur fiable de "dernière
-- page" à parser dans le HTML, has_more est déduit du plus simple : tant
-- qu'une page renvoie au moins un avis, on considère qu'il peut y en avoir
-- une suivante (le bouton "Charger plus" appellera page+1, qui reviendra
-- vide et coupera has_more le cas échéant).
--
-- La date n'est affichée qu'en relatif ("16 hours ago", "3 days ago"), pas
-- de date ISO/timestamp exploitable trouvée dans le markup — rev.date
-- n'est donc pas rempli (format_review_date ne saurait pas la parser de
-- toute façon) ; le texte relatif est conservé en le préfixant au contenu
-- plutôt que d'être perdu.

local function block_to_review(block, id)
    local avatar = block:match('class="avatar" src="([^"]+)"')

    local author = strip_tags(
        block:match('itemprop="name">(.-)</strong>') or "")

    local rating = block:match('class="user%-rating" data%-rating="([%d%.]+)"')
    rating = rating and tonumber(rating) or nil

    local relative_date = strip_tags(
        block:match('class="review%-date">(.-)</span>') or "")

    local content_html = extract_div(block, '<div itemprop="reviewBody"')
    local content = ""
    if content_html then
        content_html = content_html:gsub('<br[^>]*/?>%s*', '\n'):gsub('</p>%s*', '\n\n')
        content = strip_tags(content_html):gsub('\n\n\n+', '\n\n'):match("^%s*(.-)%s*$")
    end
    if relative_date ~= "" then
        content = (content ~= "") and (relative_date .. "\n\n" .. content) or relative_date
    end

    if author == "" and content == "" then return nil end
    return {
        author  = author ~= "" and author or "Anonyme",
        rating  = rating,
        content = content,
        avatar  = avatar,
        id      = id,
    }
end

-- ── Commentaires de chapitre ────────────────────────────────────────────
-- Pas encore confirmé par capture DevTools (contrairement à parseReviews
-- ci-dessus) : NovelFire utilise le même gabarit que d'autres sites du
-- type "LightNovelWorld", dont les commentaires de chapitre vivent
-- généralement dans un conteneur #comment_load (même nommage que
-- #review_load pour les avis), un commentaire = <div class="comment-item"
-- data-commentid="ID">. Pagination essayée en query string ?page=N sur
-- l'URL du chapitre, par analogie avec /reviews?page=N déjà confirmé. À
-- ajuster si le HTML réel diffère (même démarche que pour parseReviews :
-- capture DevTools puis correction ciblée).
--
-- Toujours 10 commentaires par appel (PAGE_SIZE), indépendamment de ce que
-- le site renvoie par page côté serveur : on tronque si plus, et on
-- considère qu'il peut y avoir une suite tant qu'on a rempli une page
-- pleine (même heuristique que has_more pour les avis).
local function block_to_chapter_comment(block, id)
    local avatar = block:match('class="avatar" src="([^"]+)"')
    local author = strip_tags(
        block:match('itemprop="name">(.-)</strong>')
        or block:match('class="[^"]*comment%-name[^"]*"[^>]*>(.-)</')
        or "")
    local relative_date = strip_tags(
        block:match('class="[^"]*comment%-date[^"]*"[^>]*>(.-)</span>') or "")
    local content_html = extract_div(block, '<div[^>]*class="[^"]*comment%-content[^"]*"')
        or extract_div(block, '<div[^>]*class="[^"]*comment%-body[^"]*"')
    local content = ""
    if content_html then
        content_html = content_html:gsub('<br[^>]*/?>%s*', '\n'):gsub('</p>%s*', '\n\n')
        content = strip_tags(content_html):gsub('\n\n\n+', '\n\n'):match("^%s*(.-)%s*$")
    end
    if relative_date ~= "" then
        content = (content ~= "") and (relative_date .. "\n\n" .. content) or relative_date
    end
    if author == "" and content == "" then return nil end
    return {
        author  = author ~= "" and author or "Anonyme",
        content = content,
        avatar  = avatar,
        id      = id,
    }
end

function ext:parseChapterComments(path, page)
    page = tonumber(page) or 1
    if page < 1 then page = 1 end
    local PAGE_SIZE = 10

    local base_url = (path:match("^https?://") and path) or (BASE .. path)
    local url = base_url
    if page > 1 then
        url = base_url .. (base_url:find("?") and "&" or "?") .. "page=" .. tostring(page)
    end

    logger.dbg("NovelFire: parseChapterComments page=", page, "url=", url)
    local html = http_get(url)
    if not html then
        logger.err("NovelFire: parseChapterComments fetch failed for", url)
        return { comments = {}, has_more = false }
    end

    local list_html = extract_div(html, '<div[^>]*id="comment_load"')
        or extract_div(html, '<div[^>]*id="comments"')
        or html

    local comments = {}
    local pos = 1
    local comment_pat = '<div[^>]*class="[^"]*comment%-item[^"]*"[^>]*data%-commentid="(%d+)"'
    while pos <= #list_html and #comments < PAGE_SIZE do
        local s, _, id = list_html:find(comment_pat, pos)
        if not s then break end
        local block, next_pos = extract_div(
            list_html,
            '<div[^>]*class="[^"]*comment%-item[^"]*"[^>]*data%-commentid="%d+"',
            s
        )
        if not block then break end
        local ok, c = pcall(block_to_chapter_comment, block, id)
        if ok and c then comments[#comments + 1] = c end
        pos = next_pos or (#list_html + 1)
    end

    if #comments == 0 then
        return { comments = {}, has_more = false, page = page }
    end

    return {
        comments  = comments,
        has_more  = (#comments >= PAGE_SIZE),
        page      = page,
        next_page = page + 1,
    }
end

-- Tri des avis confirmé par capture Network le 2026-09-19 sur
-- novelfire.net/book/shadow-slave/reviews : paramètre `filter`, valeurs
-- newest (plus récents d'abord), oldest (plus anciens d'abord), mostliked
-- (plus aimés d'abord). Vocabulaire déjà identique à celui utilisé côté UI
-- (ui/detail.lua current_api_sort()) : passthrough direct, aucune table de
-- correspondance nécessaire.
local VALID_REVIEW_FILTERS = { newest = true, oldest = true, mostliked = true }

function ext:parseReviews(path, page, sort)
    page = tonumber(page) or 1
    if page < 1 then page = 1 end

    -- /reviews est la vraie page des avis. On garde exactement la même
    -- URL de base pour que "Charger plus" puisse demander page+1.
    local base_url
    if path:match("^https?://") then
        base_url = path
    else
        base_url = BASE .. path:gsub("/?$", "") .. "/reviews"
    end

    local qs = {}
    if VALID_REVIEW_FILTERS[sort] then qs[#qs + 1] = "filter=" .. sort end
    if page > 1 then qs[#qs + 1] = "page=" .. tostring(page) end
    local url = base_url
    if #qs > 0 then url = url .. "?" .. table.concat(qs, "&") end

    logger.dbg("NovelFire: parseReviews page=", page, "url=", url)

    local html = http_get(url)
    if not html then
        logger.err("NovelFire: parseReviews fetch failed for", url)
        -- Une erreur réseau ne doit surtout pas laisser l'onglet en
        -- chargement indéfini : on signale immédiatement la fin.
        return { reviews = {}, has_more = false, loading = false }
    end

    -- Limiter le parsing au conteneur des avis. Cela évite de reparcourir
    -- inutilement toute la page et accélère sensiblement les pages longues.
    local list_html = extract_div(html, '<div[^>]*id="review_load"') or ""

    local reviews = {}
    local pos = 1
    local review_pat = '<div[^>]*class="[^"]*review%-item[^"]*"[^>]*data%-revid="(%d+)"'
    while pos <= #list_html do
        local s, _, id = list_html:find(review_pat, pos)
        if not s then break end

        local block, next_pos = extract_div(
            list_html,
            '<div[^>]*class="[^"]*review%-item[^"]*"[^>]*data%-revid="%d+"',
            s
        )
        if not block then break end

        local ok, r = pcall(block_to_review, block, id)
        if ok and r then
            reviews[#reviews + 1] = r
        end

        pos = next_pos or (#list_html + 1)
    end

    if #reviews == 0 then
        logger.dbg("NovelFire: parseReviews — page vide, fin de pagination page=", page)
        -- Page vide = plus aucun avis. Le bouton "Charger plus" doit disparaître
        -- et l'état de chargement doit être libéré.
        return { reviews = {}, has_more = false, loading = false, page = page }
    end

    logger.dbg("NovelFire: parseReviews got", #reviews, "reviews on page", page)

    -- Tant qu'une page contient des avis, une page suivante peut exister.
    -- L'UI utilise has_more pour afficher "Charger plus" et libérer son état
    -- de chargement après réception de la réponse.
    return {
        reviews = reviews,
        has_more = true,
        loading = false,
        page = page,
        next_page = page + 1,
    }
end

return ext
