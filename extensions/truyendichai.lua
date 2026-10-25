-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- extensions/truyendichai.lua — TruyenDichAI (https://truyendich.space), romans
-- chinois traduits en vietnamien (traduction IA, « Convert » brut, ou traduction humaine).
-- Source NOVEL (contrat : cf. extensions/kakuyomu.lua), écrite d'après 3 vraies pages
-- enregistrées : accueil, fiche d'un roman (Thái Hư Chí Tôn), page d'un chapitre.
--
-- Chemins stockés (sans domaine) :
--   roman    : « doc-truyen/<slug> »
--   chapitre : « doc-truyen/<slug>/chuong-<n> »     (édition « Dịch AI », celle par défaut)
--              l'édition brute « Convert » vit sous « doc-truyen/cv/<slug>/chuong-<n> »
--
-- VÉRIFIÉ sur les pages enregistrées :
--   · fiche : titre (<h1>), auteur, nombre de chapitres, statut, genres, résumé, couverture (og:image) ;
--   · cartes de l'accueil : lien « /doc-truyen/<slug> » + <img alt="Ảnh bìa truyện …"> ;
--   · chapitre : texte dans <section class="prose-novel"> sous forme de <p> ;
--   · les chapitres sont numérotés 1…N (« chuong-N ») : la liste est générée d'après le total.
--     Les titres ne sont lus que pour les chapitres visibles sur la 1re page de la fiche
--     (les 50 premiers + les derniers) ; les autres s'appellent « Chương N ».
-- NON VÉRIFIÉ (absent des pages enregistrées, le site pagine/recherche en JavaScript) :
--   · l'adresse de la recherche (plusieurs adresses sont essayées, la 1re qui répond est gardée) ;
--   · la pagination des listes (« ?page=N ») ;
--   · le texte de l'édition « Dịch AI » (seule l'édition « Convert » a été enregistrée ; on suppose
--     la même structure, et on retombe sur « Convert » si l'édition IA est vide).
--
-- Si le site répond par un refus, le code HTTP est affiché et la réponse est
-- enregistrée dans sefirah/truyendichai_last_error.txt.

local logger = require("logger")
local T      = require("core.i18n").T

local BASE = "https://truyendich.space"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

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

local function pat_escape(s)
    return (tostring(s):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function dump_error(label, body)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local f = io.open(dir .. "/truyendichai_last_error.txt", "wb")
        if f then f:write(label .. "\n\n" .. tostring(body):sub(1, 200000)); f:close() end
    end)
end

local last_http = nil

local function get_html(path)
    local url = path:match("^https?://") and path or (BASE .. "/" .. path:gsub("^/", ""))
    local body, code, extra = require("core.net").get(url, { headers = {
        ["User-Agent"] = UA,
        ["Accept"] = "text/html,application/xhtml+xml",
        ["Accept-Language"] = "vi,en;q=0.7",
        ["Referer"] = BASE .. "/",
    }, timeout = 20 })
    if body and #body > 2 then return body end
    last_http = tostring(code)
    dump_error("requête échouée : " .. url .. "\ncode : " .. tostring(code), type(extra) == "string" and extra or "")
    logger.warn("TruyenDichAI: échec", url, tostring(code))
    return nil, last_http
end

-- ── Filtres de l'onglet Parcourir ────────────────────────────────────────────
-- Listes vues dans le menu du site (/danh-sach/<id>) et genres (/the-loai/<id>).
local POPULAR_FILTERS = {
    {
        key = "list", label = T("Liste"), default = "truyen-hot",
        options = {
            { id = "truyen-hot",     label = T("Populaires") },
            { id = "truyen-moi",     label = T("Nouveautés") },
            { id = "truyen-full",    label = T("Terminés") },
            { id = "truyen-dich-ai", label = T("Traduction IA") },
            { id = "truyen-dich",    label = T("Traduction humaine") },
            { id = "truyen-convert", label = "Convert" },
        },
    },
    {
        key = "genre", label = T("Genre"), default = "",
        options = {
            { id = "",           label = T("Tous") },
            { id = "tien-hiep",  label = "Tiên Hiệp" },
            { id = "huyen-huyen", label = "Huyền Huyễn" },
            { id = "kiem-hiep",  label = "Kiếm Hiệp" },
            { id = "do-thi",     label = "Đô Thị" },
            { id = "he-thong",   label = "Hệ Thống" },
            { id = "di-gioi",    label = "Dị Giới" },
            { id = "khoa-huyen", label = "Khoa Huyễn" },
            { id = "xuyen-nhanh", label = "Xuyên Nhanh" },
            { id = "ngon-tinh",  label = "Ngôn Tình" },
            { id = "dam-my",     label = "Đam Mỹ" },
            { id = "bach-hop",   label = "Bách Hợp" },
            { id = "nu-cuong",   label = "Nữ Cường" },
            { id = "cung-dau",   label = "Cung Đấu" },
            { id = "lich-su",    label = "Lịch Sử" },
            { id = "quan-su",    label = "Quân Sự" },
            { id = "linh-di",    label = "Linh Dị" },
            { id = "trinh-tham", label = "Trinh Thám" },
            { id = "mat-the",    label = "Mạt Thế" },
            { id = "vong-du",    label = "Võng Du" },
            { id = "tham-hiem",  label = "Thám Hiểm" },
        },
    },
}

local function with_page(url, page)
    if page and page > 1 then
        return url .. (url:find("?", 1, true) and "&" or "?") .. "page=" .. page
    end
    return url
end

-- ── Listes ───────────────────────────────────────────────────────────────────
-- Carte d'un roman : <a href=".../doc-truyen/<slug>"> … <img alt="Ảnh bìa truyện <titre>"
-- src=".../anh-bia/<slug>-<id>.webp?v=…"> … </a>. La carte « à la une » de l'accueil est un
-- lien vide (aria-label="Đọc truyện <titre>") vers « …/<slug>/chuong-1 » : l'image est ailleurs.
local function cover_of(html, slug)
    local u = html:match('https://truyendich%.space/anh%-bia/' .. pat_escape(slug) .. '%-%d+%.%w+[^"%s<>]*')
    return u and decode(u) or nil
end

local function parse_list(html)
    local novels, seen = {}, {}
    for a_tag, inner in html:gmatch('(<a%s[^>]-href%s*=%s*"[^"]-/doc%-truyen/[^"]*"[^>]*>)(.-)</a>') do
        local href = attr(a_tag, "href") or ""
        local slug = href:match("/doc%-truyen/([%w%-]+)")
        if slug and slug ~= "cv" and not seen[slug] then
            local title
            local img = inner:match("<img[^>]->")
            local alt = img and attr(img, "alt")
            if alt and alt:find("Ảnh bìa truyện", 1, true) then
                title = decode(alt:gsub("^Ảnh bìa truyện%s*", ""))
            end
            if not title or title == "" then
                local label = attr(a_tag, "aria-label")
                if label and label:find("Đọc truyện", 1, true) then
                    title = decode(label:gsub("^Đọc truyện%s*", ""))
                end
            end
            if title and title ~= "" then
                seen[slug] = true
                local cover = (img and attr(img, "src")) and decode(attr(img, "src")) or cover_of(html, slug)
                novels[#novels + 1] = { name = title, path = "doc-truyen/" .. slug, cover = cover }
            end
        end
    end
    return novels
end

local function list_page(url)
    local html = get_html(url)
    if not html then
        return { novels = {}, error = T("TruyenDichAI injoignable (code ") .. tostring(last_http) .. ")" }
    end
    local novels = parse_list(html)
    if #novels == 0 then dump_error("liste vide : " .. url, html) end
    return { novels = novels }
end

-- Adresses de recherche possibles (le site cherche en JavaScript : l'adresse exacte n'est pas
-- visible dans les pages enregistrées). La 1re qui renvoie des romans est gardée.
local SEARCH_URLS = {
    "/tim-kiem?q=%s", "/tim-kiem?keyword=%s", "/tim-kiem?tu-khoa=%s", "/search?q=%s", "/search?keyword=%s",
}
local search_ok = nil

-- ── Fiche d'un roman ─────────────────────────────────────────────────────────
local cache = {}

local function slug_of(path)
    return tostring(path or ""):match("doc%-truyen/cv/([%w%-]+)") or tostring(path or ""):match("doc%-truyen/([%w%-]+)")
end

local function to_int(s)
    local d = tostring(s or ""):gsub("[^%d]", "")
    return tonumber(d)
end

local function load_novel(path)
    local hit = cache[path]
    if hit and os.time() - hit.t < 90 then return hit.data end
    local slug = slug_of(path)
    if not slug then return nil end
    local html = get_html("doc-truyen/" .. slug)
    if not html then return nil end

    local title
    local h1 = html:match("<h1[^>]*>(.-)</h1>")
    if h1 then title = text_of(h1) end
    if not title or title == "" then
        local t = html:match("<title[^>]*>(.-)</title>")
        title = t and decode(t):gsub("%s*|%s*TruyenDichAI.*$", "") or slug
    end

    local cover
    for tag in html:gmatch("<meta[^>]->") do
        if attr(tag, "property") == "og:image" then cover = decode(attr(tag, "content") or ""); break end
    end
    if not cover or cover == "" then cover = cover_of(html, slug) end

    local author = html:match("Tác giả</span>%s*</div>%s*<p[^>]*>(.-)</p>")
    author = author and text_of(author) or nil

    local status
    local st = html:match("Trạng thái</span>%s*</div>%s*<p[^>]*>%s*([^<]+)")
    if st then
        st = st:lower()
        if st:find("hoàn", 1, true) or st:find("full", 1, true) then status = "Completed"
        elseif st:find("đang", 1, true) or st:find("Đang", 1, true) or st:find("ang ra", 1, true) then status = "Ongoing" end
    end

    local genres
    do
        local seg = html:match("Thể loại</span>(.-)</div></div>") or ""
        local list = {}
        for g in seg:gmatch('<a[^>]-href="[^"]-/the%-loai/[^"]*"[^>]*>(.-)</a>') do
            local name = text_of(g)
            if name ~= "" then list[#list + 1] = name end
        end
        if #list > 0 then genres = table.concat(list, ", ") end
    end

    local summary
    do
        local s = html:match("Giới thiệu truyện</h2>%s*<div[^>]*>%s*<div[^>]*>(.-)</div>")
        if s then
            s = decode((s:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n"):gsub("<[^>]+>", "")))
            s = s:gsub("[ \t]+", " "):gsub("\n%s*\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
            if s ~= "" then summary = s end
        end
    end

    -- Chapitres : « chuong-1 » … « chuong-N », N = « Số chương » (ou le plus grand numéro vu).
    local titles, max_seen = {}, 0
    for a_tag, inner in html:gmatch('(<a%s[^>]-href%s*=%s*"[^"]-/doc%-truyen/' .. pat_escape(slug)
            .. '/chuong%-%d+"[^>]*>)(.-)</a>') do
        local n = tonumber((attr(a_tag, "href") or ""):match("/chuong%-(%d+)"))
        if n then
            if n > max_seen then max_seen = n end
            local t = inner:match('<span[^>]-tracking%-tight[^>]*>(.-)</span>')
            t = t and text_of(t) or ""
            if t ~= "" and not titles[n] then titles[n] = t end
        end
    end
    local total = to_int(html:match("Số chương</span>%s*</div>%s*<p[^>]*>(.-)</p>"))
        or to_int(html:match("•%s*([%d%.,%s]+)%s*[Cc]hương")) or 0
    local n_max = math.max(total, max_seen)

    local chapters = {}
    for n = 1, n_max do
        local name = "Chương " .. n
        if titles[n] then name = name .. ": " .. titles[n] end
        chapters[n] = { name = name, path = "doc-truyen/" .. slug .. "/chuong-" .. n, chapter_number = n }
    end
    if #chapters == 0 then
        dump_error(string.format("aucun chapitre trouvé : %s\nhtml=%d octets ; total=%s ; liens=%d",
            slug, #html, tostring(total), max_seen), html)
    end

    local data = {
        name = title, path = "doc-truyen/" .. slug, cover = cover, summary = summary,
        author = author, genres = genres, status = status, chapters = chapters, totalPages = 1,
    }
    cache[path] = { t = os.time(), data = data }
    return data
end

-- ── Extension ────────────────────────────────────────────────────────────────
local ext = {
    id      = "truyendichai",
    name    = "TruyenDichAI",
    site    = BASE,
    lang    = "vi",
    version = "0.1.0",
    popularFilters = POPULAR_FILTERS,
}

function ext:popularNovels(page, options)
    local f = options and options.filters or {}
    local url
    if f.genre and f.genre ~= "" then
        url = BASE .. "/the-loai/" .. f.genre
    else
        url = BASE .. "/danh-sach/" .. ((f.list and f.list ~= "") and f.list or "truyen-hot")
    end
    return list_page(with_page(url, page or 1))
end

function ext:searchNovels(term, page)
    page = page or 1
    local q = url_encode(term or "")
    local candidates = {}
    if search_ok then candidates[1] = search_ok
    else for _, u in ipairs(SEARCH_URLS) do candidates[#candidates + 1] = u end end
    local tried = {}
    for _, pattern in ipairs(candidates) do
        local url = BASE .. pattern:format(q)
        local html = get_html(with_page(url, page))
        if html then
            local novels = parse_list(html)
            if #novels > 0 then
                search_ok = pattern
                return { novels = novels }
            end
        end
        tried[#tried + 1] = url
    end
    dump_error("recherche sans résultat : " .. tostring(term) .. "\nadresses essayées :\n" .. table.concat(tried, "\n"), "")
    return { novels = {} }
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

-- Texte d'un chapitre : <section class="prose-novel …"> contenant des <p>. La 1re ligne est
-- souvent « Thứ N chương <titre> » / « Chương N … » : elle est omise (le titre est déjà affiché).
local function chapter_html(html)
    local sec = html:match('<section[^>]-prose%-novel[^>]*>(.-)</section>')
    if not sec or sec == "" then return nil end
    local out = {}
    local title = html:match("<h1[^>]*>(.-)</h1>")
    title = title and text_of(title) or ""
    if title ~= "" then out[#out + 1] = "<h3>" .. escape(title) .. "</h3>" end
    local first = true
    for inner in sec:gmatch("<p[^>]*>(.-)</p>") do
        local txt = decode((inner:gsub("<br%s*/?>", "\n"):gsub("<[^>]+>", "")))
        txt = txt:gsub("^%s+", ""):gsub("%s+$", "")
        if txt ~= "" then
            local is_head = first and #txt < 160 and (txt:match("^Thứ%s+%d+%s+[Cc]hương") or txt:match("^[Cc]hương%s+%d"))
            if not is_head then out[#out + 1] = "<p>" .. escape(txt):gsub("\n", "<br/>") .. "</p>" end
            first = false
        end
    end
    if #out <= 1 then return nil end
    return table.concat(out, "\n")
end

function ext:parseChapter(path)
    local slug = slug_of(path)
    local num = tostring(path):match("/chuong%-(%d+)")
    if not slug or not num then
        return "<p>" .. escape(T("Impossible de charger le chapitre.")) .. "</p>"
    end
    -- Édition IA d'abord, puis « Convert » si elle est vide ou introuvable.
    local urls = { "doc-truyen/" .. slug .. "/chuong-" .. num, "doc-truyen/cv/" .. slug .. "/chuong-" .. num }
    local last_html
    for _, u in ipairs(urls) do
        local html = get_html(u)
        if html then
            last_html = html
            local body = chapter_html(html)
            if body then return body end
        end
    end
    if not last_html then return "<p>" .. escape(T("Impossible de charger le chapitre.")) .. "</p>" end
    dump_error("corps de chapitre introuvable : " .. tostring(path), last_html)
    return "<p>" .. escape(T("Impossible d'extraire le texte du chapitre.")) .. "</p>"
end

return ext
