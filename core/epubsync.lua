-- core/epubsync.lua — relie la lecture dans le lecteur de Sefirah à l'EPUB
-- exporté par Sefirah (celui qui est dans la bibliothèque de KOReader).
--
--  * plugin -> EPUB : quand on lit dans Sefirah, la position est écrite dans le
--    fichier de progression de l'EPUB (début du chapitre lu + pourcentage), donc
--    la barre de la bibliothèque et la reprise dans KOReader suivent.
--  * EPUB -> plugin : quand on lit l'EPUB dans KOReader (fermeture du livre ou
--    mise en veille), le chapitre atteint est reporté dans Sefirah.
--  * statistiques : le temps lu dans Sefirah est compté sur la fiche du livre
--    EPUB dans les statistiques de KOReader (voir core/stats.lua).
--
-- Rien n'est modifié pour les EPUB que Sefirah ne reconnaît pas avec certitude :
-- l'EPUB doit exister, avoir été créé par Sefirah, et contenir exactement les
-- chapitres enregistrés dans exports.json (sinon on ne touche à rien).

local lfs    = require("libs/libkoreader-lfs")
local logger = require("logger")

local M = {}

local PUSH_DELAY = 15   -- secondes : regroupe les écritures pendant la lecture

local function dlog(...)
    local n, args = select("#", ...), { ... }
    pcall(function()
        local parts = {}
        for i = 1, n do parts[#parts + 1] = tostring(args[i]) end
        logger.info("Sefirah/sync: " .. table.concat(parts, " "))
    end)
end

-- ── Lecture de l'EPUB (zip « stocké », sans compression : voir core/epub.lua) ─

local function xml_unescape(s)
    if not s then return s end
    s = s:gsub("&#(%d+);", function(n)
        n = tonumber(n)
        if n and n < 128 then return string.char(n) end
        return utf8 and utf8.char(n) or ""
    end)
    return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

local _scan = {}   -- chemin -> { mtime, size, res }

-- Renvoie { n = nb de chapitres, offset = nb de pages avant le 1er chapitre,
-- title, author, language } ou nil si ce n'est pas un EPUB Sefirah lisible.
local function scan_epub(path)
    local at = lfs.attributes(path)
    if not at or at.mode ~= "file" then return nil end
    local c = _scan[path]
    if c and c.mtime == at.modification and c.size == at.size then return c.res end

    local res
    local f = io.open(path, "rb")
    if f then
        local size = at.size
        local want = math.min(size, 2 * 1024 * 1024)
        f:seek("set", size - want)
        local tail = f:read(want) or ""
        local names = {}
        for nm in tail:gmatch("OEBPS/Text/([%w_%.%-]+%.xhtml)") do names[nm] = true end
        local n, cover, reviews, toc = 0, false, false, false
        for nm in pairs(names) do
            if nm:match("^ch%d%d%d%d%.xhtml$") then n = n + 1
            elseif nm == "cover.xhtml" then cover = true
            elseif nm == "reviews.xhtml" then reviews = true
            elseif nm == "toc.xhtml" then toc = true end
        end
        if n >= 1 and names["synopsis.xhtml"] then
            f:seek("set", 0)
            local head = f:read(math.min(size, 256 * 1024)) or ""
            local opf = head:match("OEBPS/content%.opf(.-</package>)")
            res = {
                n      = n,
                -- Même ordre que le spine de core/epub.lua (make_opf).
                offset = (cover and 1 or 0) + 1 + (reviews and 1 or 0) + (toc and 1 or 0),
            }
            if opf then
                res.title    = xml_unescape(opf:match("<dc:title>(.-)</dc:title>"))
                res.author   = xml_unescape(opf:match("<dc:creator[^>]*>(.-)</dc:creator>"))
                res.language = xml_unescape(opf:match("<dc:language>(.-)</dc:language>"))
            end
        end
        f:close()
    end
    _scan[path] = { mtime = at.modification, size = at.size, res = res }
    return res
end

-- ── Retrouver l'EPUB d'un roman / le roman d'un EPUB (exports.json) ──────────

local function records()
    local ok, DB = pcall(require, "core.db")
    if not ok or not DB.exportRecords then return {} end
    return DB.exportRecords() or {}
end

-- Valide un enregistrement : fichier présent, EPUB Sefirah, même nombre de chapitres.
local function usable(rec)
    if not rec.epub_path or type(rec.chapter_paths) ~= "table" then return nil end
    local sc = scan_epub(rec.epub_path)
    if not sc or sc.n ~= #rec.chapter_paths then return nil end
    return sc
end

local function find_for_chapter(source_id, novel_path, chapter_path)
    local recs = records()
    for i = #recs, 1, -1 do          -- le plus récent d'abord
        local r = recs[i]
        if r.source_id == source_id and r.novel_path == novel_path then
            local sc = usable(r)
            if sc then
                for idx, cp in ipairs(r.chapter_paths) do
                    if cp == chapter_path then
                        return { epub = r.epub_path, idx = idx, n = sc.n, offset = sc.offset,
                                 paths = r.chapter_paths, scan = sc,
                                 source_id = source_id, novel_path = novel_path }
                    end
                end
            end
        end
    end
    return nil
end

local function find_for_epub(epub_path)
    local recs = records()
    for i = #recs, 1, -1 do
        local r = recs[i]
        if r.epub_path == epub_path then
            local sc = usable(r)
            if sc then
                return { epub = epub_path, n = sc.n, offset = sc.offset, paths = r.chapter_paths,
                         scan = sc, source_id = r.source_id, novel_path = r.novel_path }
            end
        end
    end
    return nil
end

-- ── Identité statistiques (voir core/stats.lua) ──────────────────────────────

local _md5 = {}
local function partial_md5(path)
    local at = lfs.attributes(path)
    if not at then return nil end
    local k = path .. "|" .. tostring(at.modification) .. "|" .. tostring(at.size)
    if _md5[k] == nil then
        local ok, md5 = pcall(function() return require("util").partialMD5(path) end)
        _md5[k] = (ok and md5) or false
    end
    return _md5[k] or nil
end

--- Fiche « livre » de l'EPUB qui contient ce chapitre, pour les statistiques.
-- Seulement si l'EPUB contient au moins 2 chapitres (un EPUB par chapitre
-- éparpillerait le temps de lecture sur autant de livres).
function M.stats_identity(source_id, novel_path, chapter_path)
    local ok, res = pcall(function()
        local info = find_for_chapter(source_id, novel_path, chapter_path)
        if not info or info.n < 2 then return nil end
        local md5 = partial_md5(info.epub)
        if not md5 then return nil end
        local sc = info.scan
        local authors = (sc.author and sc.author ~= "") and sc.author or "N/A"
        return {
            md5      = md5,
            title    = (sc.title and sc.title ~= "") and sc.title or nil,
            authors  = authors,
            language = (sc.language and sc.language ~= "") and sc.language or nil,
            epub     = info.epub,
            idx      = info.idx,   -- rang du chapitre dans CET EPUB
            n        = info.n,     -- nombre de chapitres de CET EPUB
        }
    end)
    if ok then return res end
    return nil
end

-- ── plugin -> EPUB ───────────────────────────────────────────────────────────

local function reading_in_koreader(epub)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local inst = ok and ReaderUI and ReaderUI.instance
    return inst and inst.document and inst.document.file == epub
end

local function push_now(p)
    local info = find_for_chapter(p.source_id, p.novel_path, p.chapter_path)
    if not info then return end
    if reading_in_koreader(info.epub) then return end   -- KOReader écrirait par-dessus

    local frag = info.offset + info.idx
    local pc = math.max(0, math.min(1, tonumber(p.percent) or 0))
    local overall = math.min(1, (info.idx - 1 + pc) / info.n)
    local finished = (info.idx >= info.n) and (p.completed == true)

    local DocSettings = require("docsettings")
    local ds = DocSettings:open(info.epub)
    ds:saveSetting("percent_finished", overall)
    local summary = ds:readSetting("summary") or {}
    summary.status   = finished and "complete" or "reading"
    summary.modified = os.date("%Y-%m-%d")
    ds:saveSetting("summary", summary)

    -- Position : début du chapitre lu. On déclare aussi une version de DOM
    -- récente, sinon KOReader croirait le livre ancien et proposerait une
    -- migration à l'ouverture.
    local xp = string.format("/body/DocFragment[%d]/body", frag)
    local ok_dom, dom = pcall(function()
        return require("document/credocument"):engineInit().getLatestDomVersion()
    end)
    if ok_dom and tonumber(dom) then
        if not ds:readSetting("cre_dom_version") then ds:saveSetting("cre_dom_version", dom) end
        ds:saveSetting("last_xpointer", xp)
        ds:delSetting("last_percent")
    else
        ds:saveSetting("last_percent", overall)
    end
    ds:flush()

    -- Mémorise ce qu'on vient d'écrire : à la fermeture de l'EPUB, une position
    -- identique n'est pas renvoyée vers le plugin (pas d'écho).
    M._pushed = M._pushed or {}
    M._pushed[info.epub] = xp

    -- Fait remonter le livre dans l'historique (une fois, pas à chaque écriture).
    pcall(function()
        local RH = require("readhistory")
        local first = RH.hist and RH.hist[1]
        if not first or first.file ~= info.epub then RH:addItem(info.epub) end
    end)
    dlog("push ->", info.epub, "chapitre", info.idx, "/", info.n, "fragment", frag)
end

local _pending = nil
local _timer = function() M.flush() end

--- Appelée à chaque sauvegarde de progression du lecteur Sefirah.
function M.notify(source_id, novel_path, chapter_path, percent, completed)
    _pending = { source_id = source_id, novel_path = novel_path, chapter_path = chapter_path,
                 percent = percent, completed = completed }
    pcall(function()
        local UIManager = require("ui/uimanager")
        UIManager:unschedule(_timer)
        UIManager:scheduleIn(PUSH_DELAY, _timer)
    end)
end

--- Écrit tout de suite la dernière position en attente (fermeture, veille).
function M.flush()
    local p = _pending
    _pending = nil
    pcall(function() require("ui/uimanager"):unschedule(_timer) end)
    if not p then return end
    local ok, err = pcall(push_now, p)
    if not ok then dlog("push a échoué:", err) end
end

-- ── EPUB -> plugin ───────────────────────────────────────────────────────────

--- À appeler quand un livre ouvert dans KOReader se ferme ou que la liseuse
-- se met en veille. `ui` est le ReaderUI courant.
function M.pull(ui)
    local ok, err = pcall(function()
        local doc = ui and ui.document
        if not doc or not doc.file or not doc.file:lower():match("%.epub$") then return end
        local info = find_for_epub(doc.file)
        if not info then return end

        local xp = doc:getXPointer()
        local frag = tonumber(xp and xp:match("DocFragment%[(%d+)%]"))
        if not frag then return end
        local idx = frag - info.offset
        if idx < 1 or idx > info.n then return end            -- couverture, synopsis, sommaire
        if M._pushed and M._pushed[info.epub] == xp then return end   -- écho de notre propre écriture

        -- Avancement dans le chapitre, d'après les pages du livre.
        local function page_of(n)
            local okp, pg = pcall(function()
                return doc:getPageFromXPointer(string.format("/body/DocFragment[%d]/body", n))
            end)
            return okp and tonumber(pg) or nil
        end
        local p0  = page_of(frag)
        local p1  = (idx < info.n and page_of(frag + 1)) or ((tonumber(doc:getPageCount()) or 0) + 1)
        local cur = tonumber(doc:getCurrentPage())
        local pc = 0
        local done_cur = false
        if p0 and p1 and cur and p1 > p0 then
            pc = math.max(0, math.min(1, (cur - p0) / (p1 - p0)))
            -- Dernière page du chapitre = chapitre terminé (même règle que le lecteur du plugin).
            if cur >= p1 - 1 then done_cur = true; pc = 1 end
        end

        local Cache = require("core.cache")
        local sid, np = info.source_id, info.novel_path

        -- Chapitres précédents : lus. Pour que le plugin affiche « ✓ », la page
        -- courante doit égaler le total (voir chapter_progress_label dans detail.lua).
        for i = 1, idx - 1 do
            local cp  = info.paths[i]
            local old = Cache.getChapterProgress(sid, np, cp)
            local tp  = math.max(2, tonumber(old and old.total_pages) or 2)
            if not (old and tonumber(old.current_page) and tonumber(old.current_page) >= tp
                    and tonumber(old.total_pages) and tonumber(old.total_pages) >= 2) then
                Cache.setProgress(sid, np, cp, 1, tp, tp, true)
            end
        end

        -- Chapitre courant : même clé et mêmes champs que le lecteur du plugin.
        local cp  = info.paths[idx]
        local old = Cache.getChapterProgress(sid, np, cp)
        local tp  = tonumber(old and old.total_pages)
        Cache.setProgress(sid, np, cp, pc, nil, nil, done_cur)
        local e = Cache.getNovelEntry(sid, np)
        local v = e and e.progress_by_chapter and e.progress_by_chapter[cp]
        if v then
            if done_cur then
                -- « ✓ » dans la liste des chapitres : page courante = total (min. 2 pages).
                local t = (tp and tp > 1) and tp or 2
                v.total_pages, v.current_page, v.percent, v.completed = t, t, 1, true
            elseif tp and tp > 1 then
                v.total_pages  = tp
                v.current_page = math.max(1, math.min(tp, math.floor(pc * tp) + 1))
            else
                v.current_page = nil     -- reprise par pourcentage (voir readerview.lua)
            end
            v.charpos, v.top_line_num, v.line_frac = nil, nil, nil
            e.progress = v
        end
        Cache.flush()

        pcall(function()
            require("core.db").update(sid, np, { last_read_at = os.time() })
        end)
        dlog("pull <-", doc.file, "chapitre", idx, "/", info.n, "avancement", string.format("%.2f", pc))
    end)
    if not ok then dlog("pull a échoué:", err) end
end

return M
