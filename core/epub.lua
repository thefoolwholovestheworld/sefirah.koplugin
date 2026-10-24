-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- EPUB 2.0 builder: cover image → synopsis → HTML ToC → chapters.
-- Pure-Lua ZIP writer (STORE, no external binary needed).
local DataStorage = require("datastorage")
local logger      = require("logger")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local bit = require("bit")
local band, rshift = bit.band, bit.rshift

-- ── Output path ───────────────────────────────────────────────────────────────

local function sefirah_base_dir()
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if not home or home == "" then
        local full = DataStorage:getFullDataDir() or DataStorage:getDataDir()
        home = full:match("^(.*)/%.adds/") or full:match("^(.*)/koreader$") or full
    end
    return home .. "/Sefirah"
end

-- ── Cover image fetch ─────────────────────────────────────────────────────────

-- Resolves a cover URL against the source's base site URL (the `referer`
-- extensions already pass in for the hotlink-protection header below).
-- Some sources (NovelFire, Royal Road, ...) hand back protocol-relative
-- ("//cdn.example.com/x.jpg") or root-relative ("/covers/x.jpg") URLs
-- straight from the page markup without normalizing them first. Left as-is,
-- such a URL fails silently a few lines down (`req` picks `http`, whose
-- `request{url=...}` simply errors out on a non-absolute URL), which shows
-- up to the user as "no cover" with nothing in the UI explaining why.
-- Resolving centrally here means every extension gets this for free instead
-- of each one having to remember to normalize its own scraped URLs.
local function resolve_cover_url(url, referer)
    if not url or url == "" then return url end
    if url:match("^https?://") then return url end
    if url:match("^//") then return "https:" .. url end
    if referer and referer ~= "" then
        local base = referer:gsub("/+$", "")
        if url:sub(1, 1) == "/" then
            return base .. url
        end
        return base .. "/" .. url
    end
    return url
end

local fetch_cover_one

-- Une « URL » peut en réalité être une liste d'URLs séparées par une tabulation
-- (de la plus légère à la plus lourde) : on essaie la suivante si la précédente
-- échoue, est trop grosse ou renvoie un faux positif minuscule.
local function fetch_cover(url, referer)
    if not url or url == "" then return nil end
    if url:find("\t", 1, true) then
        for part in url:gmatch("[^\t]+") do
            local data, ext = fetch_cover_one(part, referer, true)
            if data then return data, ext end
        end
        return nil
    end
    return fetch_cover_one(url, referer, false)
end

fetch_cover_one = function(url, referer, multi)
    if not url or url == "" then return nil end
    -- « local:/chemin/image.png » : image livrée avec le plugin (logo AO3),
    -- lue sur disque, sans réseau.
    if url:match("^local:") then
        local path = url:sub(7)
        local f = io.open(path, "rb")
        if not f then
            logger.warn("Sefirah/Epub: couverture locale introuvable path=", path)
            return nil
        end
        local data = f:read("*a")
        f:close()
        if not data or #data < 512 then
            logger.warn("Sefirah/Epub: couverture locale vide ou trop petite path=", path)
            return nil
        end
        return data, ((path:match("%.(%w+)$") or "png"):lower())
    end
    url = resolve_cover_url(url, referer)
    -- Many sites hotlink-protect their cover images: sending a same-origin
    -- Referer avoids being served a tiny placeholder instead of the cover.
    local origin = referer or url:match("^(https?://[^/]+)/")
    local headers = { ["Accept"] = "image/*,*/*;q=0.5" }
    if origin then headers["Referer"] = origin .. "/" end

    -- Une couverture dépasse rarement 300 Ko. Plafond 2 Mo et délai TOTAL de 12 s :
    -- avant, un seul fichier lent (jusqu'à 6 Mo, goutte-à-goutte) bloquait la
    -- liseuse pendant plusieurs minutes.
    local data, code = require("core.net").get(url, {
        headers   = headers,
        timeout   = 6,
        deadline  = multi and 9 or 12,
        max_bytes = 2 * 1024 * 1024,
        no_gzip   = true,
    })
    if not data then
        logger.warn("Sefirah/Epub: cover fetch failed url=", url, "code=", tostring(code))
        return nil
    end

    -- Guard against the hotlink-protection fallback image slipping through
    -- with a 200 status: reject implausibly small "covers" (typically a
    -- 1x1 GIF/PNG placeholder, well under 1KB) rather than rendering them.
    if #data < 512 then
        logger.warn("Sefirah/Epub: cover fetch returned suspiciously small payload (",
            #data, " bytes) for url=", url, " — treating as blocked/placeholder")
        return nil
    end

    local ext  = (url:match("%.(%w+)%??[^%.]*$") or "jpg"):lower()
    if ext ~= "png" and ext ~= "webp" then ext = "jpg" end
    logger.dbg("Sefirah/Epub: cover fetched bytes=", #data, "ext=", ext)
    return data, ext
end

-- ── CRC32 ─────────────────────────────────────────────────────────────────────

local crc_table
local function init_crc()
    crc_table = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if band(c, 1) == 1 then c = bit.bxor(0xEDB88320, rshift(c, 1))
            else c = rshift(c, 1) end
        end
        crc_table[i] = c
    end
end

local function crc32(data)
    if not crc_table then init_crc() end
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        crc = bit.bxor(crc_table[band(bit.bxor(crc, data:byte(i)), 0xFF)], rshift(crc, 8))
    end
    return band(bit.bxor(crc, 0xFFFFFFFF), 0xFFFFFFFF)
end

-- ── Binary helpers ────────────────────────────────────────────────────────────

local function le2(n) return string.char(band(n,0xFF), band(rshift(n,8),0xFF)) end
local function le4(n)
    n = band(n, 0xFFFFFFFF)
    return string.char(band(n,0xFF), band(rshift(n,8),0xFF),
                       band(rshift(n,16),0xFF), band(rshift(n,24),0xFF))
end

-- ── ZIP writer ────────────────────────────────────────────────────────────────

local function write_zip(f, entries)
    local cd, offset = {}, 0
    local MOD = le2(0) .. le2(0)
    for _, e in ipairs(entries) do
        local crc, size, nm = crc32(e.data), #e.data, e.name
        local nlen = le2(#nm)
        local lfh  = table.concat({
            "\x50\x4B\x03\x04", le2(20), le2(0), le2(0),
            MOD, le4(crc), le4(size), le4(size), nlen, le2(0), nm,
        })
        f:write(lfh); f:write(e.data)
        table.insert(cd, table.concat({
            "\x50\x4B\x01\x02", le2(20), le2(20), le2(0), le2(0),
            MOD, le4(crc), le4(size), le4(size),
            nlen, le2(0), le2(0), le2(0), le2(0), le4(0), le4(offset), nm,
        }))
        offset = offset + #lfh + size
    end
    local cd_start, cd_size = offset, 0
    for _, r in ipairs(cd) do f:write(r); cd_size = cd_size + #r end
    f:write(table.concat({
        "\x50\x4B\x05\x06", le2(0), le2(0),
        le2(#entries), le2(#entries), le4(cd_size), le4(cd_start), le2(0),
    }))
end

-- ── XML / HTML helpers ────────────────────────────────────────────────────────

local function xml_esc(s)
    return (s or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;")
end

local function chapter_id(i) return string.format("ch%04d", i) end

local XHTML_HEAD = '<?xml version="1.0" encoding="UTF-8"?>\n'
    .. '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" '
    .. '"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n'
    .. '<html xmlns="http://www.w3.org/1999/xhtml">\n'

-- ── EPUB content builders ─────────────────────────────────────────────────────

local CONTAINER_XML = [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]

local STYLESHEET = [[body{margin:5% 8%;font-family:serif;line-height:1.7}
h1{text-align:center;margin:1em 0 .5em}
h2{margin:1em 0 .3em}
p{margin:0;text-indent:1.5em}
p+p{margin-top:.3em}
ul{list-style:none;padding:0}
li{padding:.2em 0;border-bottom:1px solid #ccc}
li a{text-decoration:none}
.cover-wrap{text-align:center;margin:0;padding:0}
.cover-wrap img{max-width:100%;display:block;margin:auto}]]

local function make_opf(meta, chapters, cover_ext)
    local man, spine = {}, {}

    if cover_ext then
        local mime = cover_ext == "png" and "image/png" or "image/jpeg"
        table.insert(man, ('    <item id="cover-img" href="Images/cover.%s" media-type="%s"/>'):format(cover_ext, mime))
        table.insert(man, '    <item id="cover-page" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>')
        table.insert(spine, '    <itemref idref="cover-page" linear="yes"/>')
    end

    -- FIX : "Avis" doit venir APRÈS "Synopsis" dans l'ordre de lecture du livre
    -- (demandé), pas avant.
    table.insert(man,   '    <item id="synopsis" href="Text/synopsis.xhtml" media-type="application/xhtml+xml"/>')
    table.insert(spine, '    <itemref idref="synopsis"/>')

    if meta.include_reviews then
        table.insert(man,   '    <item id="reviews" href="Text/reviews.xhtml" media-type="application/xhtml+xml"/>')
        table.insert(spine, '    <itemref idref="reviews"/>')
    end


    if #chapters > 1 then
        table.insert(man,   '    <item id="toc-page" href="Text/toc.xhtml" media-type="application/xhtml+xml"/>')
        table.insert(spine, '    <itemref idref="toc-page"/>')
    end

    for i = 1, #chapters do
        local id = chapter_id(i)
        table.insert(man,   ('    <item id="%s" href="Text/%s.xhtml" media-type="application/xhtml+xml"/>'):format(id, id))
        table.insert(spine, ('    <itemref idref="%s"/>'):format(id))
    end

    local series_meta = ""
    if meta.series then
        series_meta = ('    <meta name="calibre:series" content="%s"/>\n'
            .. '    <meta name="calibre:series_index" content="%s"/>'):format(
            xml_esc(meta.series), tostring(meta.series_index or 1))
    end
    local cover_meta = cover_ext and '\n    <meta name="cover" content="cover-img"/>' or ""

    return ([[<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf" xmlns:calibre="http://calibre-ebook.com">
    <dc:title>%s</dc:title>
    <dc:creator opf:role="aut">%s</dc:creator>
    <dc:identifier id="bid">sefirah:%s</dc:identifier>
    <dc:language>%s</dc:language>
    <dc:description>%s</dc:description>
    <meta name="calibre:annotation" content="%s"/>
%s%s
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="Styles/style.css" media-type="text/css"/>
%s
  </manifest>
  <spine toc="ncx">
%s
  </spine>
</package>]]):format(
        xml_esc(meta.title), xml_esc(meta.author or ""),
        xml_esc(meta.title) .. tostring(os.time()),
        meta.language or "en",
        xml_esc(meta.summary or ""),
        xml_esc(meta.summary or ""),
        series_meta, cover_meta,
        table.concat(man, "\n"), table.concat(spine, "\n"))
end

local function make_ncx(meta, chapters, has_cover)
    local nav  = {}
    local play = 1
    if has_cover then
        table.insert(nav, ('    <navPoint id="cover" playOrder="%d"><navLabel><text>Cover</text></navLabel><content src="Text/cover.xhtml"/></navPoint>'):format(play))
        play = play + 1
    end
    -- FIX : "Avis" après "Synopsis" (même ordre que le manifeste ci-dessus).
    table.insert(nav, ('    <navPoint id="synopsis" playOrder="%d"><navLabel><text>Synopsis</text></navLabel><content src="Text/synopsis.xhtml"/></navPoint>'):format(play))
    play = play + 1
    if meta.include_reviews then
        table.insert(nav, ('    <navPoint id="reviews" playOrder="%d"><navLabel><text>' .. xml_esc(T("Avis des lecteurs")) .. '</text></navLabel><content src="Text/reviews.xhtml"/></navPoint>'):format(play))
        play = play + 1
    end
    if #chapters > 1 then
        table.insert(nav, ('    <navPoint id="toc-page" playOrder="%d"><navLabel><text>Table of Contents</text></navLabel><content src="Text/toc.xhtml"/></navPoint>'):format(play))
        play = play + 1
    end
    for i, ch in ipairs(chapters) do
        table.insert(nav, ('    <navPoint id="n%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="Text/%s.xhtml"/></navPoint>'):format(
            i, play, xml_esc(ch.title or ("Chapter " .. i)), chapter_id(i)))
        play = play + 1
    end
    return ([[<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="sefirah:%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <navMap>
%s
  </navMap>
</ncx>]]):format(xml_esc(meta.title), xml_esc(meta.title), table.concat(nav, "\n"))
end

local function make_cover_xhtml(cover_ext)
    return XHTML_HEAD .. ([[<head><title>Cover</title>
<style type="text/css">body{margin:0;padding:0}img{max-width:100%%;display:block;margin:auto}</style>
</head>
<body><div class="cover-wrap"><img src="../Images/cover.%s" alt="Cover"/></div></body>
</html>]]):format(cover_ext)
end

local function make_synopsis_xhtml(meta)
    local paras = ""
    local summary = (meta.summary or ""):match("^%s*(.-)%s*$")
    if summary ~= "" then
        -- Each double-newline or single newline becomes a paragraph
        for line in (summary .. "\n\n"):gmatch("(.-)\n%s*\n") do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" then
                paras = paras .. "<p>" .. xml_esc(line) .. "</p>\n"
            end
        end
    end
    if paras == "" then paras = "<p>—</p>\n" end
    return XHTML_HEAD .. ([[<head><title>Synopsis</title>
<link rel="stylesheet" type="text/css" href="../Styles/style.css"/></head>
<body>
<h1>%s</h1>
<p><em>by %s</em></p>
<hr/>
%s</body>
</html>]]):format(xml_esc(meta.title), xml_esc(meta.author or "Unknown"), paras)
end

local function make_toc_xhtml(meta, chapters)
    local items = {}
    -- FIX : "Avis" après "Synopsis" dans la table des matières aussi.
    table.insert(items, '  <li><a href="synopsis.xhtml">Synopsis</a></li>')
    if meta.include_reviews then
        table.insert(items, '  <li><a href="reviews.xhtml">' .. xml_esc(T("Avis des lecteurs")) .. '</a></li>')
    end
    for i, ch in ipairs(chapters) do
        table.insert(items, ('  <li><a href="%s.xhtml">%s</a></li>'):format(
            chapter_id(i), xml_esc(ch.title or ("Chapter " .. i))))
    end
    return XHTML_HEAD .. ([[<head><title>Table of Contents</title>
<link rel="stylesheet" type="text/css" href="../Styles/style.css"/></head>
<body>
<h1>Table of Contents</h1>
<ul>
%s
</ul>
</body>
</html>]]):format(table.concat(items, "\n"))
end

-- Strip images, scripts, selects, all tag attributes from chapter HTML.
-- Uses a sentinel (ASCII \1) to make Lua patterns match across newlines.
-- \0 cannot appear inside Lua bracket classes, so we use \1 instead.
local SENT = "\1"
local function clean_html(body)
    body = body:gsub("\r\n", "\n"):gsub("\r", "\n")
    -- Replace newlines with sentinel so patterns cross line boundaries
    body = body:gsub("\n", SENT)
    for _, tag in ipairs({"script","style","select","noscript","iframe",
                          "button","aside","figure","picture","nav","form",
                          "header","footer"}) do
        body = body:gsub("<" .. tag .. "[^>]*>.-</" .. tag .. ">", "")
        body = body:gsub("<" .. tag .. "[^>]*/?>", "")
    end
    -- Strip leading h1/h2 — make_chapter_xhtml adds its own h1.
    -- Use repeated gsub to skip leading whitespace/sentinels without a bracket class.
    body = body:gsub("^[\1 \t\r]*<h[12][^>]*>.-</h[12]>", "")
    body = body:gsub(SENT, "\n")
    body = body:gsub("<img[^>]*/?>", "")
    body = body:gsub("<input[^>]*/?>", "")
    body = body:gsub("<source[^>]*/?>", "")
    body = body:gsub("<(%a[%w%-]*)%s[^>]*>", "<%1>")
    body = body:gsub("<br>",  "<br/>")
    body = body:gsub("<hr>",  "<hr/>")
    body = body:gsub("<p>%s*</p>", "")
    body = body:gsub("<div>%s*</div>", "")
    body = body:gsub("(\n%s*){3,}", "\n\n")
    return body
end

local function make_reviews_html(reviews)
    local parts = {
        "<h1>" .. xml_esc(T("Avis des lecteurs")) .. "</h1>",
    }
    for _, rev in ipairs(reviews or {}) do
        local author = xml_esc(rev.author or T("Anonyme"))
        local rating = tonumber(rev.rating)
        local rating_text = rating and string.format(" — %g/5", rating) or ""
        local date = rev.date and (" — " .. xml_esc(tostring(rev.date))) or ""
        local likes = tonumber(rev.likes)
        local dislikes = tonumber(rev.dislikes)
        local reactions = ""
        if likes or dislikes then
            reactions = string.format("<br/>Likes : %d   Dislikes : %d", likes or 0, dislikes or 0)
        end
        table.insert(parts, "<p><strong>" .. author .. rating_text .. date .. "</strong><br/>"
            .. xml_esc(rev.content or "") .. reactions .. "</p>")
    end
    if #(reviews or {}) == 0 then
        table.insert(parts, "<p>" .. xml_esc(T("Aucun avis n'a pu être récupéré.")) .. "</p>")
    end
    return table.concat(parts, "\n")
end

local function make_chapter_xhtml(title, body)
    body = clean_html(body)
    return XHTML_HEAD .. ([[<head><title>%s</title>
<link rel="stylesheet" type="text/css" href="../Styles/style.css"/></head>
<body>
<h1>%s</h1>
%s
</body>
</html>]]):format(xml_esc(title), xml_esc(title), body)
end

-- ── HTML → texte brut (pour le lecteur intégré, ScrollTextWidget) ─────────────
-- Réutilise clean_html pour le pré-nettoyage, puis retire les balises restantes
-- et convertit les paragraphes/<br> en retours à la ligne.
local function is_valid_utf8(s)
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        if b < 0x80 then i = i + 1
        elseif b >= 0xC2 and b <= 0xDF then
            local b2 = s:byte(i+1)
            if not b2 or b2 < 0x80 or b2 > 0xBF then return false end
            i = i + 2
        elseif b >= 0xE0 and b <= 0xEF then
            local b2,b3=s:byte(i+1),s:byte(i+2)
            if not b2 or not b3 or b2<0x80 or b2>0xBF or b3<0x80 or b3>0xBF then return false end
            if b==0xE0 and b2<0xA0 then return false end
            if b==0xED and b2>=0xA0 then return false end
            i=i+3
        elseif b >= 0xF0 and b <= 0xF4 then
            local b2,b3,b4=s:byte(i+1),s:byte(i+2),s:byte(i+3)
            if not b2 or not b3 or not b4 or b2<0x80 or b2>0xBF or b3<0x80 or b3>0xBF or b4<0x80 or b4>0xBF then return false end
            if b==0xF0 and b2<0x90 then return false end
            if b==0xF4 and b2>0x8F then return false end
            i=i+4
        else return false end
    end
    return true
end

local function normalize_utf8(s)
    if type(s) ~= "string" or is_valid_utf8(s) then return s end
    local out={}
    for i=1,#s do
        local b=s:byte(i)
        if b<0x80 then out[#out+1]=string.char(b)
        else out[#out+1]=string.char(0xC0+math.floor(b/64),0x80+(b%64)) end
    end
    return table.concat(out)
end

local function cp_to_utf8(n)
    if not n or n < 0 or n > 0x10FFFF then return "" end
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then return string.char(0xC0+math.floor(n/64),0x80+(n%64)) end
    if n < 0x10000 then return string.char(0xE0+math.floor(n/4096),0x80+(math.floor(n/64)%64),0x80+(n%64)) end
    return string.char(0xF0+math.floor(n/262144),0x80+(math.floor(n/4096)%64),0x80+(math.floor(n/64)%64),0x80+(n%64))
end

local NAMED_ENTITIES = {
    nbsp = " ", quot = '"', apos = "'", lt = "<", gt = ">",
    rsquo = "\u{2019}", lsquo = "\u{2018}", ldquo = "\u{201C}", rdquo = "\u{201D}",
    hellip = "\u{2026}", mdash = "\u{2014}", ndash = "\u{2013}",
    laquo = "\u{AB}", raquo = "\u{BB}",
}

-- Décode les entités HTML (nommées, décimales et hexadécimales : &#x27; &#233; ...).
-- Deux passes : certaines sources (ou la traduction) échappent deux fois
-- (&amp;#x27;), et « &amp; » doit être décodé en dernier.
local function unescape_entities(s)
    for _ = 1, 2 do
        s = s:gsub("&#[xX](%x+);", function(h) return cp_to_utf8(tonumber(h, 16)) end)
             :gsub("&#(%d+);", function(d) return cp_to_utf8(tonumber(d)) end)
             :gsub("&(%a+);", function(n) return NAMED_ENTITIES[n] end)
             :gsub("&amp;", "&")
    end
    return s
end

local function html_to_text(body)
    body = normalize_utf8(body or "")
    body = clean_html(body)
    body = body:gsub("</p>", "\n\n"):gsub("<br/>", "\n"):gsub("<br>", "\n")
    body = body:gsub("<[^>]+>", "")           -- balises restantes
    body = unescape_entities(body)
    body = body:gsub("[ \t]+", " ")
    body = body:gsub("\n[ \t]+", "\n")
    body = body:gsub("\n\n\n+", "\n\n")
    return body:match("^%s*(.-)%s*$")
end

-- ── mkdir -p ──────────────────────────────────────────────────────────────────

local function mkdirp(path)
    local cur = path:match("^/") and "/" or ""
    for p in path:gmatch("[^/\\]+") do
        cur = cur .. p .. "/"
        if lfs.attributes(cur, "mode") ~= "directory" then lfs.mkdir(cur) end
    end
end

-- ── Public: build one EPUB ────────────────────────────────────────────────────
-- meta: {title, author, language, series, series_index, cover_url, summary}
-- chapters: [{title, content}]

local function build(meta, chapters, output_path)
    mkdirp(output_path:match("^(.*)[/\\][^/\\]+$") or ".")

    -- Fetch cover (optional)
    local cover_data, cover_ext
    if meta.cover_url and meta.cover_url ~= "" then
        cover_data, cover_ext = fetch_cover(meta.cover_url, meta.cover_referer)
    end

    local entries = {}
    local function add(name, data) table.insert(entries, {name=name, data=data}) end

    add("mimetype",               "application/epub+zip")
    add("META-INF/container.xml", CONTAINER_XML)
    add("OEBPS/content.opf",      make_opf(meta, chapters, cover_ext))
    add("OEBPS/toc.ncx",          make_ncx(meta, chapters, cover_ext ~= nil))
    add("OEBPS/Styles/style.css", STYLESHEET)

    if cover_data then
        add("OEBPS/Images/cover." .. cover_ext, cover_data)
        add("OEBPS/Text/cover.xhtml",           make_cover_xhtml(cover_ext))
    end

    -- FIX : "Avis" écrit après "Synopsis" (l'ordre d'écriture ici n'affecte pas
    -- la lecture — c'est le spine de make_opf qui fait foi côté liseuse — mais
    -- on garde les deux cohérents).
    add("OEBPS/Text/synopsis.xhtml", make_synopsis_xhtml(meta))

    if meta.include_reviews then
        add("OEBPS/Text/reviews.xhtml", make_chapter_xhtml(T("Avis des lecteurs"), make_reviews_html(meta.reviews or {})))
    end


    if #chapters > 1 then
        add("OEBPS/Text/toc.xhtml", make_toc_xhtml(meta, chapters))
    end

    for i, ch in ipairs(chapters) do
        add("OEBPS/Text/" .. chapter_id(i) .. ".xhtml",
            make_chapter_xhtml(ch.title or ("Chapter " .. i), ch.content or "<p></p>"))
    end

    local f = io.open(output_path, "wb")
    if not f then return false, "cannot_write: " .. output_path end
    write_zip(f, entries)
    f:close()
    logger.dbg("Sefirah/Epub: wrote", output_path)
    return true
end

-- ── Public: export with 4 modes ───────────────────────────────────────────────
-- mode:     "all_in_one" | "per_chapter" | "every_n" | "range"
-- options:  {title, author, language, series, n, cover_url, summary, out_dir}
-- chapters: [{name, path, chapter_number}]
-- fetch_fn: function(path) -> HTML | nil
-- progress: function(done, total)

local function export(mode, options, chapters, fetch_fn, progress)
    local title     = options.title or "Novel"
    local safe      = title:gsub('[<>:"/\\|?*]', "_")
    local out_dir   = options.out_dir or (sefirah_base_dir() .. "/" .. safe)
    logger.dbg("Sefirah/Epub: export mode=", mode, "out_dir=", out_dir, "chapters=", #chapters)
    mkdirp(out_dir)

    local base_meta = {
        title         = title,
        author        = options.author,
        language      = options.language or "en",
        series        = options.series or title,
        cover_url     = options.cover_url,
        cover_referer = options.cover_referer,
        summary       = options.summary,
        include_reviews = options.include_reviews == true,
    }

    local exported, errors = {}, {}
    local total = #chapters

    local function fetch_reviews()
        if not options.include_reviews or type(options.reviews_fn) ~= "function" then return {} end
        local all, page, has_more = {}, 1, true
        while has_more and page <= 1000 do
            local ok, data = pcall(options.reviews_fn, page)
            if not ok or type(data) ~= "table" then
                table.insert(errors, "reviews_fetch_failed:" .. tostring(page))
                break
            end
            for _, rev in ipairs(data.reviews or {}) do all[#all + 1] = rev end
            has_more = data.has_more == true
            if #(data.reviews or {}) == 0 and not has_more then break end
            page = page + 1
        end
        return all
    end

    local reviews = fetch_reviews()
    if options.include_reviews and #reviews == 0 then
        logger.warn("Sefirah/Epub: avis demandés mais aucun avis récupéré")
    end
    base_meta.reviews = reviews

    local function fetch_batch(batch)
        local ch_data = {}
        for i, ch in ipairs(batch) do
            if progress then progress(i, #batch) end
            local html = fetch_fn(ch.path, options)
            if html then
                table.insert(ch_data, {title = ch.name, content = html})
            else
                table.insert(errors, "fetch_failed:" .. tostring(ch.path))
            end
        end
        return ch_data
    end

    local function do_build(filename, vol_meta, ch_data)
        local path = out_dir .. "/" .. filename:gsub('[<>:"/\\|?*]', "_") .. ".epub"
        local ok, err = build(vol_meta, ch_data, path)
        if ok then table.insert(exported, path)
        else table.insert(errors, tostring(err)) end
    end

    if mode == "all_in_one" or mode == "range" then
        local ch_data = fetch_batch(chapters)
        do_build(options.custom_name or title, base_meta, ch_data)

    elseif mode == "per_chapter" then
        -- Cover + synopsis once; no ToC (single chapter per file)
        for idx, ch in ipairs(chapters) do
            if progress then progress(idx, total) end
            local html = fetch_fn(ch.path, options)
            if html then
                local cnum = ch.chapter_number or idx
                do_build(string.format("%s - %04d", title, cnum), {
                    title        = ch.name,
                    author       = options.author,
                    language     = options.language or "en",
                    series       = base_meta.series,
                    series_index = cnum,
                    cover_url     = options.cover_url,
                    cover_referer = options.cover_referer,
                    summary      = options.summary,
                    reviews      = reviews,
                    include_reviews = options.include_reviews == true,
                }, {{title=ch.name, content=html}})
            else
                table.insert(errors, "fetch_failed:" .. tostring(ch.path))
            end
        end

    elseif mode == "every_n" then
        local n, vol = math.max(1, options.n or 50), 0
        for i = 1, total, n do
            vol = vol + 1
            local batch = {}
            for j = i, math.min(i+n-1, total) do table.insert(batch, chapters[j]) end
            local first_n = batch[1].chapter_number or i
            local last_n  = batch[#batch].chapter_number or (i+n-1)
            do_build(
                string.format("%s Vol.%d (Ch.%d-%d)", title, vol, first_n, last_n),
                {
                    title        = string.format("%s Vol.%d", title, vol),
                    author       = options.author,
                    language     = options.language or "en",
                    series       = base_meta.series,
                    series_index = vol,
                    cover_url     = options.cover_url,
                    cover_referer = options.cover_referer,
                    summary      = options.summary,
                    reviews      = reviews,
                    include_reviews = options.include_reviews == true,
                },
                fetch_batch(batch))
        end
    end

    return { exported = exported, errors = errors }
end

return { build = build, export = export, fetch_cover = fetch_cover, html_to_text = html_to_text }