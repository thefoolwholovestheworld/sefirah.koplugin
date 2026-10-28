-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- Novel Mania extension for Sefirah
-- Site : https://novelmania.com.br  (web novels / light novels en portugais)
--
-- Le site est une application React rendue côté serveur (TanStack Start) :
--   * listes (/novels, /genero/<slug>) : cartes <a href="/novels/<slug>"> avec
--     couverture, titre et auteur ;
--   * fiche d'un roman : métadonnées en HTML + la PREMIÈRE page de chapitres
--     (50) embarquée dans l'état « dehydrated » du script de la page
--     (title / slug / position de chaque chapitre, meta = {pages, count}) ;
--   * pages suivantes de la liste de chapitres : chargées par le navigateur
--     au défilement (infinite scroll). L'adresse exacte de cette requête n'est
--     pas visible dans le HTML : on essaie plusieurs adresses probables et on
--     retient celle qui répond (voir CHAPTER_PAGE_CANDIDATES), en notant tout
--     dans sefirah/novelmania_last_error.txt pour pouvoir corriger ensuite ;
--   * texte d'un chapitre : <div class="rich-text-content …"> de la page
--     /novels/<slug>/capitulos/<chapitre>.
--
-- Chemins utilisés par Sefirah :
--   roman    : novels/<slug>
--   chapitre : novels/<slug>/capitulos/<slug-du-chapitre>

local BASE   = "https://novelmania.com.br"
local logger = require("logger")
local T      = require("core.i18n").T

local PAGE_SIZE = 50   -- taille d'une page de la liste de chapitres (meta.limit du site)

-- ── Helpers texte ─────────────────────────────────────────────────────────────

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
    eacute = "é", egrave = "è", ecirc = "ê", agrave = "à", acirc = "â", atilde = "ã",
    ccedil = "ç", iacute = "í", oacute = "ó", ocirc = "ô", otilde = "õ", uacute = "ú",
    Eacute = "É", Aacute = "Á", Iacute = "Í", Oacute = "Ó", Uacute = "Ú", Ccedil = "Ç",
    Atilde = "Ã", Otilde = "Õ", Acirc = "Â", Ecirc = "Ê", Ocirc = "Ô",
    hellip = "…", mdash = "—", ndash = "–", laquo = "«", raquo = "»",
    ldquo = "“", rdquo = "”", lsquo = "‘", rsquo = "’",
}

local function decode_entities(s)
    s = s:gsub("&#x(%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);",  function(d) return utf8_encode(tonumber(d)) end)
    s = s:gsub("&(%a+);",   function(n) return NAMED[n] end)
    return s
end

local function strip_tags(s)
    s = (s or ""):gsub("<[^>]+>", "")
    s = decode_entities(s)
    return s:match("^%s*(.-)%s*$") or ""
end

local function url_encode(str)
    return (tostring(str):gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- Décode une chaîne littérale JavaScript (état « dehydrated » de la page).
local function js_unescape(s)
    if not s:find("\\", 1, true) then return s end
    s = s:gsub("\\u(%x%x%x%x)", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("\\x(%x%x)",     function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("\\(.)", function(c)
        if c == "n" then return "\n" elseif c == "t" then return "\t" end
        return c
    end)
    return s
end

-- ── Journal de diagnostic ─────────────────────────────────────────────────────
-- Même principe que InManga / Anime-Sama : sefirah/novelmania_last_error.txt
-- dans le dossier de réglages de KOReader.

local function dump(label, body)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local path = dir .. "/novelmania_last_error.txt"
        local f = io.open(path, "ab")
        if not f then return end
        local size = f:seek("end") or 0
        if size > 150000 then
            f:close()
            f = io.open(path, "wb")
            if not f then return end
        end
        f:write("\n=== " .. label .. " ===\n" .. tostring(body):sub(1, 12000) .. "\n")
        f:close()
    end)
end

-- ── HTTP ──────────────────────────────────────────────────────────────────────

local last_http = nil

local function http_get(url, accept)
    local body, code, extra = require("core.net").get(url, {
        headers = {
            ["Accept"]          = accept or "text/html,application/xhtml+xml,*/*;q=0.8",
            ["Accept-Language"] = "pt-BR,pt;q=0.9,en;q=0.5",
            ["Referer"]         = BASE .. "/",
        },
        timeout  = 12,
        deadline = 40,
    })
    if not body then
        last_http = tostring(code)
        logger.err("NovelMania: GET échoué", url, tostring(code))
        dump("GET échoué " .. url, tostring(code) .. "\n" .. tostring(extra or ""):sub(1, 1500))
        return nil, code
    end
    last_http = nil
    return body
end

-- Fiche d'un roman : parseNovelMeta puis parseNovel la demandent coup sur coup.
-- On la garde 2 minutes en mémoire pour ne la télécharger qu'une fois.
local page_memo = {}
local function http_get_page(url)
    local now = os.time()
    local m = page_memo[url]
    if m and now - m.t < 120 then return m.body end
    local body, code = http_get(url)
    if body then page_memo = { [url] = { t = now, body = body } } end
    return body, code
end

local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return data
end

-- Un `null` JSON n'est pas nil pour rapidjson : on ne garde que du vrai texte / nombre.
local function str(v)
    if type(v) == "string" then return v ~= "" and v or nil end
    if type(v) == "number" then return tostring(v) end
    return nil
end

-- ── Chemins ───────────────────────────────────────────────────────────────────

local function slug_of(path)
    path = tostring(path or "")
    path = path:gsub("^https?://[^/]+", "")
    return path:match("^/?novels/([^/?#]+)") or path:match("^/?([^/?#]+)$")
end

local function abs_url(path)
    if path:match("^https?://") then return path end
    if path:sub(1, 1) == "/" then return BASE .. path end
    return BASE .. "/" .. path
end

-- ── Listes de romans (accueil, /novels, /genero/<slug>, recherche) ───────────

local function parse_novel_list(html)
    local novels, seen = {}, {}
    for href, inner in html:gmatch('<a[^>]-href="([^"]+)"[^>]*>(.-)</a>') do
        local slug = href:gsub("^https?://[^/]+", ""):match("^/novels/([^/?#]+)/?$")
        if slug and not seen[slug] then
            local img   = inner:match("<img[^>]*>")
            local cover = img and img:match('src="([^"]+)"')
            local title = inner:match('<p[^>]-class="[^"]*line%-clamp[^"]*"[^>]*>(.-)</p>')
            title = title and strip_tags(title) or ""
            if title == "" and img then title = strip_tags(img:match('alt="([^"]*)"') or "") end
            if title ~= "" then
                seen[slug] = true
                local author = inner:match('<p[^>]-class="[^"]*truncate[^"]*"[^>]*>(.-)</p>')
                novels[#novels + 1] = {
                    name   = title,
                    path   = "novels/" .. slug,
                    cover  = cover and decode_entities(cover) or nil,
                    author = author and strip_tags(author) or nil,
                }
            end
        end
    end
    return novels
end

-- ── Filtres « Parcourir » ─────────────────────────────────────────────────────
-- Les deux tris exposés par le site lui-même (liens de l'accueil :
-- /novels?sort=views_count_desc et /novels?sort=created_at_desc) et les genres
-- du pied de page (/genero/<slug>).
local POPULAR_FILTERS = {
    {
        key = "sort", label = "Tri", default = "views_count_desc",
        options = {
            { id = "views_count_desc", label = "Plus lus" },
            { id = "created_at_desc",  label = "Récents" },
        },
    },
    {
        key = "genre", label = "Genre", default = "",
        options = {
            { id = "",                label = "Tous" },
            { id = "acao",            label = "Action" },
            { id = "aventura",        label = "Aventure" },
            { id = "fantasia",        label = "Fantasy" },
            { id = "romance",         label = "Romance" },
            { id = "comedia",         label = "Comédie" },
            { id = "drama",           label = "Drame" },
            { id = "artes-marciais",  label = "Arts martiaux" },
            { id = "cultivo",         label = "Cultivation" },
            { id = "isekai",          label = "Isekai" },
            { id = "sistema-de-jogo", label = "Système de jeu" },
            { id = "xianxia",         label = "Xianxia" },
            { id = "misterio",        label = "Mystère" },
        },
    },
}

local function build_browse_url(page, filters)
    filters = filters or {}
    local sort  = filters.sort  or "views_count_desc"
    local genre = filters.genre or ""
    local base  = (genre ~= "") and (BASE .. "/genero/" .. genre) or (BASE .. "/novels")
    return base .. "?sort=" .. sort .. "&page=" .. page
end

-- ── Recherche ─────────────────────────────────────────────────────────────────
-- Le champ « Buscar novels » du site et la recherche de chapitres utilisent la
-- clé `q`. Si /novels ignorait un paramètre inconnu il renverrait simplement la
-- liste générale : on vérifie donc que les résultats ressemblent au terme
-- cherché avant de retenir un paramètre.
local SEARCH_PARAMS = { "q", "search", "busca", "query" }
local search_param_ok = nil   -- paramètre qui a fonctionné (retenu pour la session)

local function results_match(novels, term)
    local first = tostring(term):lower():match("%S+")
    if not first then return true end
    for _, n in ipairs(novels) do
        if (n.name or ""):lower():find(first, 1, true) then return true end
    end
    return false
end

-- ── Fiche d'un roman ──────────────────────────────────────────────────────────

local function map_status(s)
    s = (s or ""):lower()
    if s == "" then return "Unknown" end
    if s:find("ativ") or s:find("andamento") or s:find("curso") then return "Ongoing" end
    if s:find("complet") or s:find("finaliz") or s:find("conclu") then return "Completed" end
    if s:find("hiato") or s:find("paus") then return "Hiatus" end
    if s:find("cancel") or s:find("abandon") or s:find("drop") then return "Cancelled" end
    return "Unknown"
end

-- Bloc <dd> qui suit un <dt> donné ("Autor", "Status"…).
local function dl_value(html, label)
    local dd = html:match("<dt[^>]*>%s*" .. label .. "%s*</dt>%s*<dd[^>]*>(.-)</dd>")
    return dd and strip_tags(dd) or nil
end

local function parse_meta(html)
    local _, _, h1 = html:find("<h1[^>]*>(.-)</h1>")
    local title = strip_tags(h1 or "")
    if title == "" then
        title = strip_tags((html:match("<title>(.-)</title>") or ""):gsub("%s*•.*$", ""))
        title = title:gsub("^Novel%s+", "")
    end

    local author = dl_value(html, "Autor")
    local status = map_status(dl_value(html, "Status"))

    local cover = html:match('<meta[^>]-property="og:image"[^>]-content="([^"]+)"')
    if not cover then
        local img = html:match('<img[^>]-class="[^"]*object%-cover[^"]*"[^>]*>')
        cover = img and img:match('src="([^"]+)"')
    end

    -- Synopsis : <div data-testid="novel-synopsis"> … <p>…</p></div>
    local summary = ""
    local syn_s = html:find('data%-testid="novel%-synopsis"')
    if syn_s then
        local seg = html:sub(syn_s, syn_s + 12000)
        local inner = seg:match('rich%-text%-content[^>]*>(.-)</div></div>')
                   or seg:match('rich%-text%-content[^>]*>(.-)</div>')
        if inner then
            inner = inner:gsub("<br[^>]*/?>", "\n"):gsub("</p>", "\n\n")
            summary = strip_tags(inner):gsub("\n%s*\n%s*\n+", "\n\n")
        end
    end
    if summary == "" then
        summary = decode_entities(html:match('<meta[^>]-name="description"[^>]-content="([^"]*)"') or "")
    end

    -- Genres : liens /genero/ situés entre le titre et le bloc « Autor »
    -- (le pied de page en contient aussi : on ne le regarde pas).
    local genres = {}
    local seg_s = h1_e or 1
    local seg_e = html:find(">Autor<", seg_s, true) or (seg_s + 6000)
    for g in html:sub(seg_s, seg_e):gmatch('<a[^>]-href="[^"]*/genero/[^"]+"[^>]*>(.-)</a>') do
        local t = strip_tags(g)
        if t ~= "" then genres[#genres + 1] = t end
    end

    return {
        title   = title,
        author  = author or "",
        cover   = cover and decode_entities(cover) or nil,
        status  = status,
        summary = summary,
        genres  = table.concat(genres, ", "),
    }
end

-- ── Liste de chapitres ────────────────────────────────────────────────────────

-- État « dehydrated » : …,title:"Capítulo 1: …",slug:"livro-1-capitulo-1",
--                       longTitle:"Livro 1 – Capítulo 1",position:1,…
-- On part du slug (jamais ambigu) puis on relit le titre juste devant.
local function parse_chapters_dehydrated(html, slug)
    local list = {}
    local from = html:find("chapters:%$R%[%d+%]=%[")
    local seg  = from and html:sub(from) or html
    for at, cslug, pos in seg:gmatch('()slug:"([^"]+)",longTitle:"[^"]*",position:(%d+)') do
        local pre   = seg:sub(math.max(1, at - 400), at - 1)
        local title = pre:match('.*title:"(.-)",$')
        if title then
            list[#list + 1] = {
                name           = js_unescape(title),
                path           = "novels/" .. slug .. "/capitulos/" .. js_unescape(cslug),
                chapter_number = tonumber(pos),
            }
        end
    end
    return list
end

-- Page enregistrée après rendu (ou rendue côté client) : liste de liens
-- <a id="chapter-…" href=".../capitulos/<slug>"><span …>Titre</span>…
local function parse_chapters_dom(html, slug)
    local list, seen = {}, {}
    for href, inner in html:gmatch('<a[^>]-id="chapter%-[^"]*"[^>]-href="([^"]+)"[^>]*>(.-)</a>') do
        local cslug = href:match("/capitulos/([^/?#]+)")
        if cslug and not seen[cslug] then
            seen[cslug] = true
            local t = inner:match('<span[^>]-class="[^"]*line%-clamp[^"]*"[^>]*>(.-)</span>')
            local name = strip_tags(t or inner)
            list[#list + 1] = {
                name = name,
                path = "novels/" .. slug .. "/capitulos/" .. cslug,
                chapter_number = tonumber(name:match("[Cc]ap[ií]tulo%s+(%d+)")),
            }
        end
    end
    return list
end

local function parse_chapters(html, slug)
    local list = parse_chapters_dehydrated(html, slug)
    if #list == 0 then list = parse_chapters_dom(html, slug) end
    return list
end

local function parse_chapter_counts(html)
    local pages = tonumber(html:match("meta:%$R%[%d+%]={page:%d+,limit:%d+,pages:(%d+)"))
    local count = tonumber(html:match("meta:%$R%[%d+%]={page:%d+,limit:%d+,pages:%d+,count:(%d+)"))
              or tonumber(html:match("chaptersCount:(%d+)"))
    if not count then
        local c = html:match(">([%d%.]+)<!%-%- %-%->%s*<!%-%- %-%->capítulos<")
        if c then count = tonumber((c:gsub("%.", ""))) end
    end
    local limit = tonumber(html:match("meta:%$R%[%d+%]={page:%d+,limit:(%d+)")) or PAGE_SIZE
    if not pages and count then pages = math.ceil(count / limit) end
    return count, pages, limit
end

-- ── Pages suivantes de la liste de chapitres ─────────────────────────────────
-- L'adresse de l'infinite scroll n'étant pas dans le HTML, on essaie plusieurs
-- candidats ; chacun est validé (JSON avec une liste d'objets portant un
-- `slug`, ou page HTML dont le premier chapitre a la bonne position) avant
-- d'être retenu pour la suite de la session.

local discovered = nil   -- { urls = {...} } trouvés dans les scripts du site

-- Adresse de pagination qui a déjà fonctionné : mémorisée sur disque pour ne plus
-- essayer à chaque session les adresses qui répondent « 404 » (chaque essai raté coûte
-- une connexion TLS complète sur la liseuse).
local function pref_path()
    local ok, DS = pcall(require, "datastorage")
    if not ok or not DS then return nil end
    return DS:getSettingsDir() .. "/sefirah/novelmania_endpoint.txt"
end
local function load_pref()
    local p = pref_path()
    local f = p and io.open(p, "rb")
    if not f then return nil end
    local v = f:read("*l")
    f:close()
    return v and v:match("^%S+$") or nil
end
local function save_pref(key)
    pcall(function()
        local p = pref_path()
        if not p then return end
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, p:match("^(.*)/[^/]+$")) end
        local f = io.open(p, "wb")
        if f then f:write(tostring(key), "\n"); f:close() end
    end)
end
local pref_key = load_pref()

local function candidate_urls(slug, page, limit)
    local q = "page=" .. page .. "&limit=" .. limit .. "&sort=asc&q="
    local urls = {
        { key = "s1", kind = "json", url = BASE .. "/api/novels/" .. slug .. "/chapters?" .. q },
        { key = "s2", kind = "json", url = BASE .. "/api/v1/novels/" .. slug .. "/chapters?" .. q },
        { key = "s3", kind = "json", url = BASE .. "/novels/" .. slug .. "/chapters?" .. q },
        { key = "s4", kind = "html", url = BASE .. "/novels/" .. slug .. "?page=" .. page },
        { key = "s5", kind = "html", url = BASE .. "/novels/" .. slug .. "?chapters_page=" .. page },
    }
    -- Adresses repérées dans les scripts du site (voir discover_from_bundles).
    if discovered then
        for i, d in ipairs(discovered) do
            local u = d:gsub("%${[^}]*}", "@@SLUG@@", 1):gsub("%${[^}]*}", "")
            u = u:gsub("@@SLUG@@", slug)
            if not u:find("?", 1, true) then u = u .. "?" .. q end
            table.insert(urls, i, { key = "d" .. i, kind = "json", url = abs_url(u) })
        end
    end
    -- L'adresse qui a marché lors d'une session précédente passe en premier.
    if pref_key then
        for i, c in ipairs(urls) do
            if c.key == pref_key then
                if i > 1 then table.insert(urls, 1, table.remove(urls, i)) end
                break
            end
        end
    end
    return urls
end

local function json_chapters(slug, body)
    local data = json_decode(body)
    if type(data) ~= "table" then return nil end
    local arr = data.chapters or data.data or data.items or data.results or data
    if type(arr) == "table" and type(arr.chapters) == "table" then arr = arr.chapters end
    if type(arr) ~= "table" then return nil end
    local list = {}
    for _, ch in ipairs(arr) do
        if type(ch) == "table" and str(ch.slug) then
            local pos = tonumber(ch.position or ch.number or ch.order)
            list[#list + 1] = {
                name           = str(ch.title) or str(ch.longTitle) or ("Capítulo " .. tostring(pos or #list + 1)),
                path           = "novels/" .. slug .. "/capitulos/" .. ch.slug,
                chapter_number = pos,
            }
        end
    end
    return list, tonumber(type(data.meta) == "table" and data.meta.pages or nil)
end

-- Cherche, dans les scripts chargés par la fiche, des adresses contenant
-- « chapters » : sert à deviner l'endpoint et alimente le journal.
local function discover_from_bundles(html)
    if discovered ~= nil then return end
    discovered = {}
    local found_log = {}
    local tried = 0
    for href in html:gmatch('<link[^>]-rel="modulepreload"[^>]-href="(/assets/[^"]+%.js)"') do
        local name = href:match("/assets/([%w_%-]+)%-[%w_%-]+%.js$") or ""
        if name == "novels" or name == "chapter-list" or name == "_slug" or name == "chapters" then
            tried = tried + 1
            local js = http_get(BASE .. href, "*/*")
            if js then
                for lit in js:gmatch('[`"\']([^`"\'\n]*chapters[^`"\'\n]*)[`"\']') do
                    found_log[#found_log + 1] = name .. ": " .. lit
                    if lit:find("^/") and lit:find("/chapters", 1, true) and not lit:find("^/novels/%${[^}]*}/capitulos") then
                        discovered[#discovered + 1] = lit
                    end
                end
                for sf in js:gmatch('/_serverFn/[%w_%-%.%%]+') do
                    found_log[#found_log + 1] = name .. ": serverFn " .. sf
                end
                for api in js:gmatch('https://[%w%.%-]*novelmania[%w%.%-]*[%w/_%-]*') do
                    found_log[#found_log + 1] = name .. ": host " .. api
                end
            end
        end
        if tried >= 6 then break end
    end
    if #found_log > 0 then
        dump("scripts du site (adresses contenant « chapters »)", table.concat(found_log, "\n"))
    end
end

local good_candidate = nil   -- { kind=, idx= } une fois qu'une adresse a répondu

local function fetch_chapter_page(slug, page, limit, html0, json_only)
    local expected_first = (page - 1) * limit + 1
    local function try(c)
        local body = http_get(c.url, c.kind == "json" and "application/json,*/*;q=0.5" or nil)
        if not body then return nil end
        if c.kind == "json" then
            local list = json_chapters(slug, body)
            if list and #list > 0 then return list end
            dump("réponse JSON non reconnue " .. c.url, body:sub(1, 800))
        else
            local list = parse_chapters(body, slug)
            if #list > 0 and list[1].chapter_number == expected_first then return list end
            if #list > 0 then
                dump("page HTML sans pagination " .. c.url,
                    "premier chapitre = " .. tostring(list[1].chapter_number) .. ", attendu " .. expected_first)
            end
        end
        return nil
    end

    if good_candidate then
        local cands = candidate_urls(slug, page, limit)
        local c = cands[good_candidate.idx]
        if c and c.kind == good_candidate.kind and (not json_only or c.kind == "json") then
            local list = try(c)
            if list then return list end
        end
    end

    local cands = candidate_urls(slug, page, limit)
    for i, c in ipairs(cands) do
        local list = (not json_only or c.kind == "json") and try(c) or nil
        if list then
            good_candidate = { idx = i, kind = c.kind }
            if c.key and c.key ~= pref_key then
                pref_key = c.key
                save_pref(c.key)
                -- candidate_urls() place désormais cette adresse en tête de liste.
                good_candidate.idx = 1
            end
            dump("adresse de pagination retenue", c.url)
            return list
        end
        if last_http == "closed" or last_http == "timeout" then break end
    end
    return nil
end

-- ── Extension ─────────────────────────────────────────────────────────────────

local ext = {
    id      = "novelmania",
    name    = "Novel Mania",
    site    = BASE,
    lang    = "pt",
    version = "0.3.0",
    review_cache_rev = 1,
    popularFilters = POPULAR_FILTERS,
    maxReviews = 150, -- limite d'avis affichés (même valeur pour toutes les extensions)
}

function ext:popularNovels(page, options)
    page = page or 1
    local url = build_browse_url(page, options and options.filters)
    logger.dbg("NovelMania: popularNovels", url)
    local html = http_get(url)
    if not html then return { novels = {} } end
    local novels = parse_novel_list(html)
    if #novels == 0 then
        dump("liste vide " .. url, html:sub(1, 3000))
    end
    return { novels = novels }
end

function ext:searchNovels(term, page)
    page = page or 1
    term = tostring(term or "")
    local order = {}
    if search_param_ok then order[1] = search_param_ok end
    for _, p in ipairs(SEARCH_PARAMS) do
        if p ~= search_param_ok then order[#order + 1] = p end
    end
    local last = {}
    for _, p in ipairs(order) do
        local url = BASE .. "/novels?" .. p .. "=" .. url_encode(term) .. "&page=" .. page
        local html = http_get(url)
        if html then
            local novels = parse_novel_list(html)
            if #novels > 0 and results_match(novels, term) then
                search_param_ok = p
                return { novels = novels }
            end
            last = novels
            -- La clé est reconnue mais rien ne correspond : inutile d'essayer les autres.
            if search_param_ok == p then return { novels = {} } end
        else
            break
        end
    end
    if #last > 0 then
        dump("recherche « " .. term .. " » : paramètre non reconnu",
            "Les résultats ne correspondent pas au terme ; paramètres essayés : " .. table.concat(SEARCH_PARAMS, ", "))
    end
    return { novels = {} }
end

function ext:parseNovelMeta(path)
    local slug = slug_of(path)
    if not slug then return nil end
    local html = http_get_page(BASE .. "/novels/" .. slug)
    if not html then return nil end
    local meta = parse_meta(html)
    local count = parse_chapter_counts(html)
    return {
        name           = meta.title,
        path           = "novels/" .. slug,
        cover          = meta.cover,
        summary        = meta.summary,
        author         = meta.author,
        status         = meta.status,
        total_chapters = count or #parse_chapters(html, slug),
    }
end

-- Mise à jour incrémentale (ui/detail.lua) : seules les nouvelles pages de
-- chapitres sont téléchargées quand le total augmente.
ext.chapters_per_page = PAGE_SIZE

function ext:parsePage(path, page)
    local slug = slug_of(path)
    page = tonumber(page) or 1
    if not slug then return { chapters = {} } end
    if page <= 1 then
        local html = http_get_page(BASE .. "/novels/" .. slug)
        return { chapters = html and parse_chapters(html, slug) or {} }
    end
    discover_from_bundles(http_get_page(BASE .. "/novels/" .. slug) or "")
    local list = fetch_chapter_page(slug, page, PAGE_SIZE, nil)
    if not list then return { chapters = {}, failed = true } end
    return { chapters = list }
end

function ext:parseNovel(path)
    local slug = slug_of(path)
    if not slug then return nil end
    local html = http_get_page(BASE .. "/novels/" .. slug)
    if not html then return nil end

    local meta = parse_meta(html)
    local chapters = parse_chapters(html, slug)
    local count, pages, limit = parse_chapter_counts(html)
    limit = limit or PAGE_SIZE

    local missing_note = nil
    if #chapters == 0 then
        dump("aucun chapitre reconnu sur la fiche " .. slug, html:sub(1, 4000))
        missing_note = T("⚠ Aucun chapitre reconnu (voir sefirah/novelmania_last_error.txt).")
    elseif pages and pages > 1 then
        discover_from_bundles(html)
        local seen = {}
        for _, c in ipairs(chapters) do seen[c.path] = true end

        -- Essai « tout d'un coup » : une seule requête JSON avec une grande
        -- limite au lieu d'une requête par tranche de 50 chapitres. Si le site
        -- plafonne la limite, la réponse reste une page de 50 : on garde alors
        -- l'adresse trouvée et la boucle classique ci-dessous prend le relais.
        local bulk_limit = math.min(math.max(count or 0, limit), 3000)
        local first_page = 2
        if bulk_limit > limit then
            local bulk = fetch_chapter_page(slug, 1, bulk_limit, html, true)
            if bulk and #bulk > #chapters then
                for _, c in ipairs(bulk) do
                    if not seen[c.path] then
                        seen[c.path] = true
                        chapters[#chapters + 1] = c
                    end
                end
                first_page = pages + 1   -- tout est déjà là
            end
        end
        for p = first_page, pages do
            local list = fetch_chapter_page(slug, p, limit, html)
            if not list then
                dump("pagination impossible " .. slug,
                    "page " .. p .. "/" .. pages .. " introuvable ; chapitres récupérés : " .. #chapters
                    .. " sur " .. tostring(count))
                missing_note = string.format(
                    T("⚠ Liste de chapitres incomplète (%d sur %s). Voir sefirah/novelmania_last_error.txt."),
                    #chapters, tostring(count or "?"))
                break
            end
            for _, c in ipairs(list) do
                if not seen[c.path] then
                    seen[c.path] = true
                    chapters[#chapters + 1] = c
                end
            end
        end
    end

    local summary = meta.summary
    if missing_note then
        summary = missing_note .. "\n\n" .. (summary or "")
    end

    return {
        name       = meta.title,
        path       = "novels/" .. slug,
        cover      = meta.cover,
        summary    = summary,
        author     = meta.author,
        genres     = meta.genres,
        status     = meta.status,
        chapters   = chapters,
        totalPages = 1,
        -- true : pagination impossible, liste tronquée (le cache existant est conservé).
        incomplete = (missing_note ~= nil and #chapters > 0) or nil,
    }
end

-- ── Avis (onglet « Avis ») ────────────────────────────────────────────────────
-- API des commentaires du site (confirmée par l'utilisateur) :
--   GET /api/comments?commentable_type=Novel&commentable_id=<ID SIGNÉ>&sort=<tri>&page=N
--   tri : newest | best | oldest
-- <ID SIGNÉ> a la forme « ODc=--449e2e55…b6dc » (base64 de l'id numérique, « -- »,
-- puis une signature hexadécimale de 40 caractères) : elle ne peut pas être
-- calculée côté client, il faut la lire dans la fiche du roman.
-- Réponse confirmée : { success, data = [ { id, createdAt, body, score, user = {
-- username, avatar = { thumb, small, original, large } | null }, replies } ],
-- meta = { page, limit, pages, count, has_more } }. Le parseur reste tolérant et
-- la première réponse reçue est enregistrée dans sefirah/novelmania_last_error.txt.

-- Vocabulaire générique de ui/detail.lua → valeur `sort` du site.
local REVIEW_SORT = { newest = "newest", oldest = "oldest", mostliked = "best" }

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_IDX = {}
for i = 1, #B64 do B64_IDX[B64:sub(i, i)] = i - 1 end

local function b64_decode(s)
    s = s:gsub("=+$", "")
    local out, bits, nbits = {}, 0, 0
    for c in s:gmatch(".") do
        local v = B64_IDX[c]
        if not v then return nil end
        bits  = bits * 64 + v
        nbits = nbits + 6
        if nbits >= 8 then
            nbits = nbits - 8
            local p2 = 2 ^ nbits
            out[#out + 1] = string.char(math.floor(bits / p2))
            bits = bits % p2
        end
    end
    return table.concat(out)
end

-- Identifiant signé du roman, lu dans sa fiche. On cherche tout motif
-- « <base64 d'un nombre>--<40 hex> » ; s'il y en a plusieurs (ex. chapitres), on
-- préfère celui qui suit le mot « comment », sinon le plus fréquent, sinon le
-- premier. Résultat gardé en mémoire par roman.
local commentable_ids = {}

local function find_commentable_id(html, slug)
    local h = html
    h = h:gsub("\\u003[dD]", "="):gsub("\\u002[bB]", "+"):gsub("\\/", "/")
    h = h:gsub("%%3[dD]", "="):gsub("%%2[bB]", "+"):gsub("&#61;", "="):gsub("&#x3[dD];", "=")

    local cands, order = {}, {}
    for at, tok, hex in h:gmatch("()([%w%+/=]+)%-%-(%x+)") do
        local n = #hex
        if n >= 40 and #tok >= 2 and #tok <= 16 then
            local dec = b64_decode(tok)
            if dec and dec:match("^%d+$") then
                local id = tok .. "--" .. hex:sub(1, (n == 64) and 64 or 40)
                local c = cands[id]
                if not c then
                    c = { id = id, count = 0, near_comment = false }
                    cands[id] = c
                    order[#order + 1] = c
                end
                c.count = c.count + 1
                local before = h:sub(math.max(1, at - 400), at):lower()
                if before:find("comment", 1, true) then c.near_comment = true end
            end
        end
    end
    if #order == 0 then return nil end

    -- Ancrage sur le slug : l'objet « roman » du site est sérialisé comme
    -- {id, createdAt, updatedAt, title, slug, …}. On prend l'identifiant signé
    -- qui précède de peu un `slug:"<slug du roman>"` (et non un lien de chapitre).
    if slug and slug ~= "" then
        local anchored, aorder, from = {}, {}, 1
        while true do
            local s_at = h:find(slug, from, true)
            if not s_at then break end
            from = s_at + #slug
            local pre = h:sub(math.max(1, s_at - 12), s_at - 1)
            if pre:find("slug", 1, true) and pre:find(":", 1, true) then
                local win = h:sub(math.max(1, s_at - 600), s_at - 1)
                local last
                for tok, hex in win:gmatch("([%w%+/=]+)%-%-(%x+)") do
                    local n = #hex
                    if n >= 40 and #tok >= 2 and #tok <= 16 then
                        local dec = b64_decode(tok)
                        if dec and dec:match("^%d+$") then
                            last = tok .. "--" .. hex:sub(1, (n == 64) and 64 or 40)
                        end
                    end
                end
                if last then
                    if not anchored[last] then anchored[last] = 0; aorder[#aorder + 1] = last end
                    anchored[last] = anchored[last] + 1
                end
            end
        end
        local pick
        for _, id in ipairs(aorder) do
            if not pick or anchored[id] > anchored[pick] then pick = id end
        end
        if pick then
            dump("identifiant du roman (ancré sur le slug " .. slug .. ")", pick .. "  (x" .. anchored[pick] .. ")")
            return pick
        end
        dump("aucun identifiant ancré sur le slug " .. slug .. " — repli sur l'heuristique", "")
    end

    local best
    for _, c in ipairs(order) do
        if not best
            or (c.near_comment and not best.near_comment)
            or (c.near_comment == best.near_comment and c.count > best.count) then
            best = c
        end
    end
    if #order > 1 then
        local lines = {}
        for _, c in ipairs(order) do
            lines[#lines + 1] = string.format("%s  (x%d%s)", c.id, c.count, c.near_comment and ", près de « comment »" or "")
        end
        dump("plusieurs identifiants signés dans la fiche (retenu : " .. best.id .. ")", table.concat(lines, "\n"))
    end
    return best.id
end

local function commentable_id_for(slug)
    if commentable_ids[slug] then return commentable_ids[slug] end
    local html = http_get_page(BASE .. "/novels/" .. slug)
    if not html then return nil end
    local id = find_commentable_id(html, slug)
    if id then
        commentable_ids[slug] = id
        return id
    end
    -- Rien trouvé : on garde les environs des mots « comment » pour adapter le code.
    local snippets, from = {}, 1
    while #snippets < 4 do
        local at = html:lower():find("comment", from, true)
        if not at then break end
        snippets[#snippets + 1] = html:sub(math.max(1, at - 150), at + 350)
        from = at + 400
    end
    dump("identifiant signé introuvable dans la fiche " .. slug,
        #snippets > 0 and table.concat(snippets, "\n---\n") or "aucune occurrence de « comment » dans la fiche")
    return nil
end

local function first_of(t, keys)
    for _, k in ipairs(keys) do
        local v = t[k]
        if v ~= nil and (type(v) == "string" or type(v) == "number" or type(v) == "table") then
            return v
        end
    end
    return nil
end

local function find_comment_list(data)
    if type(data) ~= "table" then return nil end
    if data[1] ~= nil then return data end
    for _, k in ipairs({ "comments", "data", "items", "results", "records" }) do
        local v = data[k]
        if type(v) == "table" then
            if v[1] ~= nil then return v end
            local inner = find_comment_list(v)
            if inner then return inner end
        end
    end
    -- Réponse valide mais vide : on reconnaît la forme grâce à un tableau vide.
    for _, k in ipairs({ "comments", "data", "items", "results" }) do
        if type(data[k]) == "table" then return data[k] end
    end
    return nil
end

local function html_to_text(s)
    s = s:gsub("<br[^>]*/?>", "\n"):gsub("</p>", "\n\n"):gsub("</div>", "\n")
    s = strip_tags(s)
    return (s:gsub("\n%s*\n%s*\n+", "\n\n"))
end

local function comment_to_review(c)
    if type(c) ~= "table" then return nil end
    local user = first_of(c, { "user", "author", "commenter", "profile", "owner" })
    if type(user) ~= "table" then user = {} end

    local name = str(user.name) or str(user.username) or str(user.display_name) or str(user.displayName)
              or str(user.nickname) or str(user.nome) or str(user.login)
              or str(c.user_name) or str(c.username) or str(c.author_name) or str(c.userName)
              or str(c.author) or str(c.user)

    local body = first_of(c, { "body", "content", "text", "comment", "message", "html", "body_html", "content_html" })
    local content = ""
    if type(body) == "table" then
        body = str(body.html) or str(body.text) or str(body.body) or str(body.content)
    end
    if type(body) == "string" then content = html_to_text(body) end

    local likes = tonumber(c.likes_count) or tonumber(c.likesCount) or tonumber(c.likes)
               or tonumber(c.upvotes) or tonumber(c.votes) or tonumber(c.score)
    if not likes and type(c.reactions) == "table" then
        likes = tonumber(c.reactions.like) or tonumber(c.reactions.likes)
    end

    local avatar = str(user.avatar_url) or str(user.avatarUrl) or str(user.avatar)
                or str(user.image) or str(user.picture) or str(user.photo)
                or str(c.avatar_url) or str(c.avatar)
    if not avatar and type(user.avatar) == "table" then
        -- Format réel du site : { original, thumb, small, large } — on prend la
        -- plus petite (l'avatar s'affiche en ~48 px et les gros fichiers sont refusés).
        avatar = str(user.avatar.thumb) or str(user.avatar.small) or str(user.avatar.url)
              or str(user.avatar.src) or str(user.avatar.original) or str(user.avatar.large)
    end
    if avatar then
        avatar = decode_entities(avatar)
        if avatar:sub(1, 2) == "//" then avatar = "https:" .. avatar
        elseif avatar:sub(1, 1) == "/" then avatar = BASE .. avatar end
        if not avatar:match("^https?://") then avatar = nil end
    end

    return {
        id       = str(c.id) or str(c.uuid),
        parent_id = str(c.parent_id) or str(c.parentId),
        author   = name or "Anônimo",
        rating   = nil,
        content  = content,
        likes    = likes or 0,
        dislikes = tonumber(c.dislikes_count) or tonumber(c.dislikesCount) or tonumber(c.dislikes) or 0,
        avatar   = avatar,
        date     = str(c.created_at) or str(c.createdAt) or str(c.published_at) or str(c.publishedAt)
                or str(c.date) or str(c.updated_at) or str(c.updatedAt),
        _id      = str(c.id) or str(c.uuid),
    }
end

-- Pages d'avis déjà vues par (roman, tri) : protège d'une boucle infinie si le
-- site ignorait `page` et renvoyait toujours les mêmes commentaires.
local review_seen = {}
local review_logged = false

function ext:parseReviews(path, page, sort)
    page = tonumber(page) or 1
    local slug = slug_of(path)
    if not slug then return { reviews = {}, has_more = false, error = "chemin invalide" } end

    local cid = commentable_id_for(slug)
    if not cid then
        return { reviews = {}, has_more = false,
                 error = "identifiant des commentaires introuvable (voir sefirah/novelmania_last_error.txt)" }
    end

    local sort_by = REVIEW_SORT[sort or "newest"] or "newest"
    local url = string.format("%s/api/comments?commentable_type=Novel&commentable_id=%s&sort=%s&page=%d",
        BASE, url_encode(cid), sort_by, page)

    local body, code = require("core.net").get(url, {
        headers = {
            ["Accept"]          = "application/json,text/plain,*/*;q=0.5",
            ["Accept-Language"] = "pt-BR,pt;q=0.9,en;q=0.5",
            ["Referer"]         = BASE .. "/novels/" .. slug,
        },
        timeout  = 12,
        deadline = 40,
    })
    if not body then
        logger.err("NovelMania: avis — GET échoué", url, tostring(code))
        dump("avis : GET échoué " .. url, tostring(code))
        return { reviews = {}, has_more = false, error = "HTTP " .. tostring(code) }
    end

    if review_logged ~= slug then
        review_logged = slug
        dump("avis : première réponse (" .. url .. ")", body:sub(1, 3000))
    end

    local data = json_decode(body)
    local list = find_comment_list(data)
    if not list then
        dump("avis : forme de réponse inconnue " .. url, body:sub(1, 1500))
        return { reviews = {}, has_more = false, error = "réponse des commentaires non reconnue" }
    end

    local reviews, visited = {}, {}
    local function append_comments(comments, parent, depth)
        if type(comments) ~= "table" then return end
        for _, c in ipairs(comments) do
            if type(c) == "table" and not visited[c] then
                visited[c] = true
                local ok, r = pcall(comment_to_review, c)
                if ok and r then
                    r.parent_id = r.parent_id or parent
                    r.depth = depth or (r.parent_id and 1 or 0)
                    reviews[#reviews + 1] = r
                    append_comments(c.replies, r.id or parent, r.depth + 1)
                elseif not ok then
                    logger.err("NovelMania: comment_to_review a échoué", tostring(r))
                end
            end
        end
    end
    append_comments(list, nil, nil)

    -- Garde-fou anti-doublons (page ignorée par le site).
    local key = slug .. "|" .. sort_by
    if page == 1 then review_seen[key] = {} end
    local seen = review_seen[key] or {}
    review_seen[key] = seen
    if page > 1 and #reviews > 0 then
        local fresh = 0
        for _, r in ipairs(reviews) do
            local k = r._id or (r.author .. "|" .. (r.date or "") .. "|" .. r.content:sub(1, 60))
            if not seen[k] then fresh = fresh + 1 end
        end
        if fresh == 0 then return { reviews = {}, has_more = false } end
    end
    for _, r in ipairs(reviews) do
        local k = r._id or (r.author .. "|" .. (r.date or "") .. "|" .. r.content:sub(1, 60))
        seen[k] = true
    end

    -- Pagination : on lit ce que l'API indique, sinon « il y en a encore tant
    -- que la page n'est pas vide ».
    local has_more
    local meta = type(data) == "table" and (data.meta or data.pagination or data.paging) or nil
    if type(data) == "table" then
        local v = data.has_more
        if v == nil then v = data.hasMore end
        if v == nil and type(meta) == "table" then
            v = meta.has_more
            if v == nil then v = meta.hasMore end
            if v == nil then
                local nxt = meta.next_page or meta.nextPage or meta.next
                if nxt ~= nil and type(nxt) ~= "userdata" then v = (nxt and nxt ~= false) and true or false end
            end
            if v == nil then
                local total_pages = tonumber(meta.pages) or tonumber(meta.total_pages) or tonumber(meta.totalPages)
                                 or tonumber(meta.last_page) or tonumber(meta.lastPage)
                local cur = tonumber(meta.page) or tonumber(meta.current_page) or tonumber(meta.currentPage) or page
                if total_pages then v = cur < total_pages end
            end
        end
        if v == nil and type(data.next_page) ~= "userdata" and data.next_page ~= nil then
            v = data.next_page and true or false
        end
        if type(v) == "boolean" then has_more = v end
    end
    if has_more == nil then has_more = #reviews > 0 end

    return { reviews = reviews, has_more = has_more }
end

-- ── Texte d'un chapitre ───────────────────────────────────────────────────────

-- Extrait le <div> équilibré qui commence à start_pos.
local function balanced_div(html, start_pos)
    local tag_end = html:find(">", start_pos, true)
    if not tag_end then return nil end
    local depth, pos = 1, tag_end + 1
    while depth > 0 do
        local o = html:find("<div", pos, true)
        local c = html:find("</div>", pos, true)
        if not c then return nil end
        if o and o < c then
            depth = depth + 1
            pos = o + 4
        else
            depth = depth - 1
            if depth == 0 then return html:sub(tag_end + 1, c - 1) end
            pos = c + 6
        end
    end
    return nil
end

function ext:parseChapter(path)
    local html = http_get(abs_url(path))
    if not html then return "<p>" .. T("Erreur de chargement du chapitre.") .. "</p>" end

    local s = html:find('<div[^>]-class="[^"]*rich%-text%-content[^"]*_body_[^"]*"')
           or html:find('<div[^>]-class="[^"]*rich%-text%-content[^"]*"')
    local content = s and balanced_div(html, s)
    if not content or not content:find("%S") then
        dump("chapitre sans contenu " .. tostring(path), html:sub(1, 3000))
        return "<p>" .. T("Contenu du chapitre introuvable.") .. "</p>"
    end

    -- Nettoyage : scripts, styles et commentaires éventuels.
    content = content:gsub("<script.-</script>", ""):gsub("<style.-</style>", ""):gsub("<!%-%-.-%-%->", "")

    -- Pied de page des traducteurs (Discord, WhatsApp, dons Live-Pix…) : un
    -- bloc de liens et de compteurs ajouté après le texte, souvent derrière
    -- des <hr>. On le retire seulement s'il se trouve dans la dernière moitié
    -- du chapitre, pour ne jamais couper l'histoire.
    local promo_at
    for _, dom in ipairs({ "discord.gg", "chat.whatsapp.com", "livepix.gg", "tipa.ai",
                           "patreon.com", "ko-fi.com", "apoia.se", "catarse.me" }) do
        local at = content:find(dom, 1, true)
        if at and (not promo_at or at < promo_at) then promo_at = at end
    end
    if promo_at and promo_at > #content * 0.5 then
        local cut
        local from = 1
        while true do
            local h = content:find("<hr", from, true)
            if not h or h >= promo_at then break end
            cut = h
            from = h + 3
        end
        if cut then
            -- Remonte aux <hr> voisins (annonce « il reste N chapitres », etc.).
            while true do
                local prev
                local f2 = 1
                while true do
                    local h = content:find("<hr", f2, true)
                    if not h or h >= cut then break end
                    prev = h
                    f2 = h + 3
                end
                if prev and cut - prev < 700 then cut = prev else break end
            end
            content = content:sub(1, cut - 1)
        end
    end
    return content
end

return ext
