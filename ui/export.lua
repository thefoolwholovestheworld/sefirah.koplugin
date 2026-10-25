-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- Dialogue d'export : choisir le mode, déclencher la génération EPUB.
local UIManager   = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local Online      = require("core.online")
local DataStorage = require("datastorage")
local logger      = require("logger")
local Epub        = require("core.epub")
local DB          = require("core.db")
local ExtMgr      = require("core.extmgr")
local P           = require("ui.panel")

local Export = {}

local function close_all()
    if _G.sefirah_close_all then _G.sefirah_close_all() end
end

local function sefirah_base_dir()
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if not home or home == "" then
        local full = DataStorage:getFullDataDir() or DataStorage:getDataDir()
        home = full:match("^(.*)/%.adds/") or full:match("^(.*)/koreader$") or full
    end
    local Settings = require("sefirah_settings")
    if Settings:get("export_location_flat") then return home end
    return home .. "/Sefirah"
end

local MODES = {
    { id = "all_in_one",  label = T("Tout en un seul EPUB"),         desc = T("Tous les chapitres → un seul fichier") },
    { id = "per_chapter", label = T("Un EPUB par chapitre"),    desc = T("Chaque chapitre → fichier séparé")    },
    { id = "every_n",     label = T("Regrouper tous les N chapitres"), desc = T("Regrouper en volumes")               },
    { id = "range",       label = T("Choisir une plage de chapitres"),  desc = T("Du chapitre X au chapitre Y → un seul fichier")  },
}

local _ctx   = nil
local _mode  = "all_in_one"
local _n     = 50
local _range_start = nil
local _range_end   = nil
local _include_reviews = false
local _include_comments = false
local _panel = nil

local function rebuild(ctx)
    Export.show(ctx)
end

-- Retourne les chapitres dont le numéro est compris dans la plage demandée.
local function chapter_number_value(ch, fallback)
    if ch and ch.chapter_number ~= nil then
        local n = tonumber(tostring(ch.chapter_number):match("[%d%.]+"))
        if n then return n end
    end
    local name = ch and (ch.name or ch.title) or ""
    local n = tonumber(tostring(name):match("(%d+[%d%.]*)"))
    return n or fallback
end

local function chapters_in_range(chapters, first_num, last_num)
    first_num, last_num = tonumber(first_num), tonumber(last_num)
    if not first_num or not last_num then return {} end
    if first_num > last_num then first_num, last_num = last_num, first_num end
    local out = {}
    for _, ch in ipairs(chapters or {}) do
        local n = chapter_number_value(ch, nil)
        if n and n >= first_num and n <= last_num then out[#out + 1] = ch end
    end
    table.sort(out, function(a,b) return chapter_number_value(a, math.huge) < chapter_number_value(b, math.huge) end)
    return out
end

-- Trie toujours les chapitres dans l'ordre chronologique du novel
-- (1, 2, 3, ... 56), indépendamment de l'ordre reçu par la source/API.
local function sort_chapters_oldest_first(chapters)
    local out = {}
    for i, ch in ipairs(chapters or {}) do
        out[#out + 1] = { ch = ch, original_index = i }
    end

    table.sort(out, function(a, b)
        local na = chapter_number_value(a.ch, nil)
        local nb = chapter_number_value(b.ch, nil)

        -- Les chapitres numérotés passent avant ceux sans numéro.
        if na == nil and nb ~= nil then return false end
        if na ~= nil and nb == nil then return true end

        -- Tri numérique : 1, 2, 3, ... 10, 11, ... 56
        if na ~= nil and nb ~= nil and na ~= nb then
            return na < nb
        end

        -- Ordre stable pour les égalités / chapitres sans numéro.
        return a.original_index < b.original_index
    end)

    local sorted = {}
    for i, item in ipairs(out) do
        sorted[i] = item.ch
    end
    return sorted
end
-- ── Export MANGA en CBZ ──────────────────────────────────────────────────────
-- Les mangas n'ont pas de texte mais des images : l'export EPUB sortait des pages
-- vides. Pour une source manga, chaque chapitre est téléchargé en CBZ (images
-- comprises, via core/manga.lua) puis rangé / regroupé selon le mode choisi.
local function is_manga_source(source_id)
    local ext = ExtMgr.get(source_id)
    if ext and ext.type == "manga" and ext.parseChapterImages then return true, ext end
    return false, ext
end

local function file_name_safe(s, max)
    s = tostring(s or ""):gsub('[<>:"/\\|?*%c]', "_"):gsub("%s+", " ")
    s = s:match("^[%s%._]*(.-)[%s%._]*$") or ""
    if #s > (max or 100) then s = s:sub(1, max or 100) end
    if s == "" then s = "manga" end
    return s
end

local function mkdirs_p(path)
    local lfs = require("libs/libkoreader-lfs")
    local cur = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        cur = cur .. part
        if lfs.attributes(cur, "mode") ~= "directory" then lfs.mkdir(cur) end
        cur = cur .. "/"
    end
    return lfs.attributes(path, "mode") == "directory"
end

local function fetch_manga_cover(ctx)
    return require("core.manga").fetchCover(ctx.source_id, ctx.novel)
end

-- Construit UN CBZ : couverture en première entrée (« 0000_cover.* » passe avant toutes
-- les pages, donc KOReader l'utilise comme vignette), puis les pages de chaque chapitre.
-- `sources` : liste d'éléments { pages = {{name,path}…} } (pages déjà téléchargées)
--             ou chaîne = chemin d'un CBZ déjà en cache (relu page par page).
local function build_group_cbz(sources, dest, cover, cover_kind)
    local Manga = require("core.manga")
    local ok_a, Archiver = pcall(require, "ffi/archiver")
    local items = {}
    if cover and cover_kind then
        items[#items + 1] = { name = "0000_cover." .. cover_kind, get = function() return cover end }
    end
    local readers = {}
    for ci, src in ipairs(sources) do
        if type(src) == "table" then
            for _, pg in ipairs(src.pages or {}) do
                items[#items + 1] = { name = string.format("%04d_%s", ci, pg.name), path = pg.path }
            end
        elseif type(src) == "string" and ok_a and Archiver and Archiver.Reader then
            local r = Archiver.Reader:new()
            if r:open(src) then
                readers[#readers + 1] = r
                local names = {}
                for entry in r:iterate() do
                    if entry.mode == "file" and entry.path then names[#names + 1] = entry.path end
                end
                table.sort(names)
                for _, name in ipairs(names) do
                    local base = name:match("[^/]+$") or name
                    -- Ignore une éventuelle ancienne couverture déjà présente.
                    if not base:match("^0000_cover") then
                        items[#items + 1] = {
                            name = string.format("%04d_%s", ci, base),
                            get  = function() return r:extractToMemory(name) end,
                        }
                    end
                end
            end
        end
    end
    local ok = #items > (cover and 1 or 0) and Manga.writeCbz(dest, items)
    for _, r in ipairs(readers) do pcall(r.close, r) end
    return ok
end

local function run_manga_export(ctx, ext, chapters, title, out_dir, progress_msg)
    local Manga = require("core.manga")
    local novel = ctx.novel
    local total = #chapters
    local cbz_paths, errors = {}, 0   -- cbz_paths[i] = { pages, tmp } ou chemin d'un CBZ en cache
    local popup = progress_msg

    local function say(text)
        if popup then UIManager:close(popup) end
        popup = InfoMessage:new{ text = text, timeout = 120 }
        UIManager:show(popup)
        pcall(function() UIManager:forceRePaint() end)
    end

    local function ch_label(ch, i)
        return file_name_safe(ch.name or ch.title or (T("Chapitre ") .. i), 60)
    end

    local function finish()
        if popup then UIManager:close(popup); popup = nil end
        if not mkdirs_p(out_dir) then
            UIManager:show(InfoMessage:new{ text = T("Impossible de créer le dossier d'export."), timeout = 4 })
            return
        end

        -- Groupes de chapitres (un groupe = un fichier CBZ).
        local groups = {}
        if _mode == "per_chapter" then
            for i, ch in ipairs(chapters) do
                groups[#groups + 1] = { name = file_name_safe(title) .. " - " .. string.format("%04d", i) .. " " .. ch_label(ch, i), idx = { i } }
            end
        elseif _mode == "every_n" then
            local n = math.max(1, math.floor(_n))
            local i = 1
            while i <= total do
                local j = math.min(total, i + n - 1)
                local idx = {}
                for k = i, j do idx[#idx + 1] = k end
                groups[#groups + 1] = { name = string.format("%s - %04d a %04d", file_name_safe(title), i, j), idx = idx }
                i = j + 1
            end
        else
            local idx = {}
            for k = 1, total do idx[k] = k end
            local suffix = (_mode == "range" and _range_start and _range_end)
                and string.format(T(" - chapitres %g a %g"), _range_start, _range_end) or ""
            groups[1] = { name = file_name_safe(title) .. suffix, idx = idx }
        end

        say(T("Ajout de la couverture…"))
        local cover, cover_kind = fetch_manga_cover(ctx)

        local exported = {}
        for _, g in ipairs(groups) do
            local srcs = {}
            for _, k in ipairs(g.idx) do
                if cbz_paths[k] then srcs[#srcs + 1] = cbz_paths[k] end
            end
            if #srcs > 0 then
                local dest = out_dir .. "/" .. g.name .. ".cbz"
                if build_group_cbz(srcs, dest, cover, cover_kind) then
                    exported[#exported + 1] = dest
                    local ch_paths = {}
                    for _, k in ipairs(g.idx) do
                        ch_paths[#ch_paths + 1] = chapters[k].path or chapters[k].sourceUrl or ""
                    end
                    pcall(DB.recordExport, ctx.source_id, novel.path or "", ch_paths, dest)
                    -- Pages temporaires libérées seulement une fois le CBZ écrit.
                    for _, src in ipairs(srcs) do pcall(Manga.cleanPages, src) end
                else
                    errors = errors + #g.idx
                end
            end
        end
        if popup then UIManager:close(popup); popup = nil end

        UIManager:show(InfoMessage:new{
            text = string.format(
                T("Export terminé.\n%d fichier%s CBZ enregistré(s) dans\n%s\n%s"),
                #exported, #exported == 1 and "" or "s", out_dir,
                errors > 0 and (tostring(errors) .. T(" chapitre(s) en échec.")) or ""),
            timeout = 8,
        })
    end

    -- Chapitres en chevauchement : dès que toutes les images d'un chapitre sont
    -- lancées (il ne reste que la « queue » lente), le chapitre suivant démarre.
    -- Au plus 2 chapitres en vol ; le plafond global de sous-processus
    -- (core/parallel.lua) empêche de dépasser la capacité de la liseuse.
    local started, finished_n, in_flight = 0, 0, 0
    local MAX_IN_FLIGHT = 3
    local finished_all = false
    local start_next

    local function start_chapter(i)
        local ch = chapters[i]
        in_flight = in_flight + 1
        say(string.format(T("Export %d / %d…"), i, total))
        local called, tailed = false, false
        local function on_tail()
            if tailed then return end
            tailed = true
            -- Planifié (pas d'appel direct) : on sort d'abord du lancement du pool courant.
            UIManager:scheduleIn(0, function() start_next() end)
        end
        local function done(ok, value)
            if called then return end
            called = true
            in_flight = in_flight - 1
            finished_n = finished_n + 1
            if ok then cbz_paths[i] = value else errors = errors + 1 end
            if finished_n >= total then
                if not finished_all then
                    finished_all = true
                    UIManager:scheduleIn(0.05, finish)
                end
            else
                UIManager:scheduleIn(0.05, function() start_next() end)
            end
        end
        local ok_call, err = pcall(Manga.download, {
            ext = ext, chapter = ch, novel_title = title, index = i,
            no_zip = true, wave = 20,
            on_tail = on_tail,
            on_progress = function(d, t)
                if d == t or d % 20 == 0 then
                    say(string.format(T("Export %d / %d — page %d / %d"), i, total, d, t))
                end
            end,
            on_done = done,
        })
        if not ok_call then
            logger.warn("Sefirah/Export: échec manga", tostring(err))
            done(false, err)
        end
    end

    start_next = function()
        while not finished_all and started < total and in_flight < MAX_IN_FLIGHT do
            started = started + 1
            start_chapter(started)
        end
    end

    if total == 0 then return finish() end
    start_next()
end

-- ── Pré-téléchargement parallèle des chapitres (export EPUB) ─────────────────
-- Avant : les chapitres étaient récupérés un par un pendant la fabrication de l'EPUB.
-- Maintenant : `width` chapitres sont téléchargés en même temps (sous-processus) dans
-- un dossier temporaire, puis l'EPUB est construit à partir de ces fichiers. Un chapitre
-- en échec est simplement re-demandé en séquentiel par fetch_fn. Le cache de lecture
-- n'est PAS modifié (les chapitres ne sont pas marqués « téléchargés »).
local function rm_dir(dir)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return end
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for f in lfs.dir(dir) do
        if f ~= "." and f ~= ".." then os.remove(dir .. "/" .. f) end
    end
    lfs.rmdir(dir)
end

local function mkdirs(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return false end
    local cur = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        cur = cur .. part
        if lfs.attributes(cur, "mode") ~= "directory" then lfs.mkdir(cur) end
        cur = cur .. "/"
    end
    return lfs.attributes(path, "mode") == "directory"
end

-- cont(fetch_fn, cleanup) est appelé quand c'est prêt (toujours, même sans parallélisme).
local function prefetch_parallel(ctx, chapters, options, out_dir, on_progress, cont)
    local fetch = ctx.fetch_fn
    local ok_p, Parallel = pcall(require, "core.parallel")
    local ok_c, Cache    = pcall(require, "core.cache")
    local width = (ok_c and Cache.parallelWidth) and Cache.parallelWidth(ctx.source_id) or 3
    if options.include_comments then width = math.min(width, 3) end
    if type(fetch) ~= "function" or not ok_p or not Parallel.available()
       or width <= 1 or #chapters < 2 then
        return cont(fetch, nil)
    end

    local tmp = out_dir .. "/.tmp_export"
    if not mkdirs(tmp) then return cont(fetch, nil) end

    local novel_path = (ctx.novel and ctx.novel.path) or ""
    local map, jobs = {}, {}
    for k, ch in ipairs(chapters) do
        local path = ch.path
        local cached = ok_c and path and not options.include_comments
            and Cache.isChapterCached(ctx.source_id, novel_path, path)
        if path and not cached and not map[path] then
            local file = tmp .. "/" .. k .. ".html"
            map[path] = file
            jobs[#jobs + 1] = function()
                for _ = 1, 2 do
                    local ok, html = pcall(fetch, path, options)
                    if ok and type(html) == "string" and html ~= "" then
                        local part = file .. ".part"
                        local f = io.open(part, "wb")
                        if f then
                            f:write(html)
                            f:close()
                            os.rename(part, file)
                        end
                        return
                    end
                end
            end
        end
    end
    if #jobs == 0 then rm_dir(tmp); return cont(fetch, nil) end

    local function wrapped(path, opts)
        local file = map[path]
        if file then
            local f = io.open(file, "rb")
            if f then
                local d = f:read("*a")
                f:close()
                if d and d ~= "" then return d end
            end
        end
        return fetch(path, opts)   -- repli : séquentiel (nouvel essai)
    end
    local function cleanup() rm_dir(tmp) end

    local started = Parallel.pool(jobs, width, function() cont(wrapped, cleanup) end, {
        job_timeout = 60,
        timeout     = 3600,
        on_progress = on_progress,
    })
    if not started then
        cleanup()
        return cont(fetch, nil)
    end
end

-- ── Exécution ─────────────────────────────────────────────────────────────────

function Export.run(ctx)
    -- Ferme le panneau d'options d'export → le panneau détails redevient visible
    Export.close()

    local novel   = ctx.novel
    local title   = novel.name or novel.title or T("Roman")
    local out_dir = sefirah_base_dir() .. "/" .. title:gsub('[<>:"/\\|?*]', "_")
    -- IMPORTANT : l'EPUB doit toujours aller du chapitre le plus ancien au plus récent.
    local chapters = sort_chapters_oldest_first(ctx.chapters or {})
    if _mode == "range" then
        chapters = chapters_in_range(chapters, _range_start, _range_end)
        if #chapters == 0 then
            UIManager:show(InfoMessage:new{ text = T("Aucune plage valide à exporter."), timeout = 3 })
            return
        end
    end
    logger.dbg("Sefirah/Export: title=", title, "out_dir=", out_dir)

    -- Suit automatiquement le roman quand un export démarre
    DB.track({
        title          = title,
        source_id      = ctx.source_id,
        path           = novel.path or "",
        cover          = novel.cover,
        author         = novel.author,
        status         = novel.status,
        total_chapters = ctx.total_chapters or novel.total_chapters or #chapters,
    })

    -- Affiche l'indicateur ; scheduleIn cède la main pour qu'UIManager le peigne avant le travail bloquant
    local progress_msg = InfoMessage:new{ text = T("Démarrage de l'export…") }
    UIManager:show(progress_msg)

    local manga_src, manga_ext = is_manga_source(ctx.source_id)
    if manga_src then
        UIManager:scheduleIn(0.1, function()
            Online.run(function()
                local ok_m, err_m = pcall(run_manga_export, ctx, manga_ext, chapters, title, out_dir, progress_msg)
                if not ok_m then
                    if progress_msg then UIManager:close(progress_msg) end
                    UIManager:show(InfoMessage:new{ text = T("Export CBZ : ") .. tostring(err_m), timeout = 6 })
                end
            end)
        end)
        return
    end

    UIManager:scheduleIn(0.1, function()
        Online.run(function()
            local options = {
                title     = title,
                author    = novel.author,
                language  = "fr",
                series    = title,
                n         = _n,
                out_dir   = out_dir,
                cover_url     = novel.cover,
                cover_referer = (ExtMgr.getMeta(ctx.source_id) or {}).site,
                summary       = novel.summary,
                include_reviews = _include_reviews,
                include_comments = _include_comments,
                reviews_fn = ctx.reviews_fn,
            }

            local function build_epubs(fetch_fn, cleanup)
            local last_repaint = os.time()
            local results = Epub.export(
                _mode, options, chapters, fetch_fn,
                function(done, total)
                    if done % 10 == 0 or done == total then
                        if progress_msg then UIManager:close(progress_msg) end
                        progress_msg = InfoMessage:new{
                            text    = string.format(T("Export %d / %d…"), done, total),
                            timeout = 120,
                        }
                        UIManager:show(progress_msg)
                        -- Force un rafraîchissement d'écran au plus toutes les 10 s (le rafraîchissement e-ink est lent)
                        local now = os.time()
                        if now - last_repaint >= 10 then
                            last_repaint = now
                            pcall(function() UIManager:forceRePaint() end)
                        end
                    end
                end)

            if progress_msg then UIManager:close(progress_msg); progress_msg = nil end

            -- Enregistre les chapitres exportés dans la BD
            if #results.exported > 0 then
                local ch_paths = {}
                for _, ch in ipairs(chapters) do
                    ch_paths[#ch_paths + 1] = ch.path or ch.sourceUrl or ""
                end
                for _, epub_path in ipairs(results.exported) do
                    DB.recordExport(ctx.source_id, novel.path or "", ch_paths, epub_path)
                end
            end

            local n_ok  = #results.exported
            local n_err = #results.errors
            UIManager:show(InfoMessage:new{
                text = string.format(
                    T("Export terminé.\n%d fichier%s enregistré(s) dans\n%s\n%s"),
                    n_ok, n_ok == 1 and "" or "s", out_dir,
                    n_err > 0 and (tostring(n_err) .. T(" chapitre(s) en échec.")) or ""),
                timeout = 6,
            })
            if cleanup then pcall(cleanup) end
            end   -- build_epubs

            local last_msg = 0
            prefetch_parallel(ctx, chapters, options, out_dir, function(n, total)
                local now = os.time()
                if n >= total or now - last_msg >= 2 then
                    last_msg = now
                    if progress_msg then UIManager:close(progress_msg) end
                    progress_msg = InfoMessage:new{
                        text    = string.format(T("Téléchargement %d / %d…"), n, total),
                        timeout = 120,
                    }
                    UIManager:show(progress_msg)
                end
            end, build_epubs)
        end)
    end)
end

-- ── Affichage ───────────────────────────────────────────────────────────────

function Export.show(ctx)
    local SefirahUI = require("ui.main_widget")
    if _ctx ~= ctx then
        _range_start, _range_end = nil, nil
        _mode = "all_in_one"
        _n = 50
        _include_reviews = false
        _include_comments = false
    end
    _ctx           = ctx
    local ch_cnt   = #(ctx.chapters or {})
    local Settings = require("sefirah_settings")
    local flat     = Settings:get("export_location_flat")

    local is_manga = is_manga_source(ctx.source_id)
    local function fmt(txt)
        if not is_manga then return txt end
        return (txt:gsub("EPUB", "CBZ"):gsub("%.epub", ".cbz"))
    end

    local rows = {}

    table.insert(rows, P.makeRow(
        string.format(T("%d chapitre%s disponible(s)"), ch_cnt, ch_cnt == 1 and "" or "s"),
        { dim = true, callback = function() end }
    ))

    local locked_cnt = 0
    for _, ch in ipairs(ctx.chapters or {}) do
        if ch.locked then locked_cnt = locked_cnt + 1 end
    end
    if locked_cnt > 0 then
        table.insert(rows, P.makeRow(
            string.format(T("[!] %d chapitre%s verrouillé(s) dans la liste"),
                locked_cnt, locked_cnt == 1 and "" or "s"),
            { bold = true, callback = function() end }
        ))
        table.insert(rows, P.makeRow(
            T("Les chapitres verrouillés n'ont pas de contenu accessible et seront exportés en pages vides."),
            { dim = true, callback = function() end }
        ))
    end

    table.insert(rows, P.hairline())

    -- Sélection du mode
    for _, m in ipairs(MODES) do
        local mid = m.id
        table.insert(rows, P.makeRow(
            (mid == _mode and "> " or "  ") .. fmt(m.label), {
                mandatory = m.desc,
                bold      = mid == _mode,
                callback  = function() _mode = mid; rebuild(ctx) end,
            }
        ))
    end

    -- Sélecteur de N (uniquement quand every_n est actif)
    if _mode == "every_n" then
        table.insert(rows, P.makeRow(
            string.format(T("Chapitres par volume : %d  (appuyer pour changer)"), _n), {
                callback = function()
                    local dlg
                    dlg = InputDialog:new{
                        title      = T("Chapitres par volume"),
                        input_type = "number",
                        input_hint = tostring(_n),
                        buttons    = {{
                            {
                                text             = "OK",
                                is_enter_default = true,
                                callback         = function()
                                    local v = tonumber(dlg:getInputText())
                                    if v and v > 0 then _n = math.floor(v) end
                                    UIManager:close(dlg)
                                    rebuild(ctx)
                                end,
                            },
                            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
                        }},
                    }
                    UIManager:show(dlg)
                end,
            }
        ))
    end

    if _mode == "range" then
        local range_label = (_range_start and _range_end)
            and string.format(T("Chapitres %g à %g"), _range_start, _range_end)
            or T("Choisir les chapitres à exporter")
        table.insert(rows, P.makeRow(range_label, {
            mandatory = T("appuyer pour choisir"),
            bold = true,
            callback = function()
                local first_dlg
                first_dlg = InputDialog:new{
                    title = T("Premier chapitre"), input_type = "number", input_hint = T("Ex. 1629"),
                    buttons = {{
                        { text = T("Annuler"), callback = function() UIManager:close(first_dlg) end },
                        { text = T("Suivant"), is_enter_default = true, callback = function()
                            local first = tonumber(first_dlg:getInputText())
                            if not first then return end
                            UIManager:close(first_dlg)
                            local last_dlg
                            last_dlg = InputDialog:new{
                                title = T("Dernier chapitre"), input_type = "number", input_hint = T("Ex. 2003"),
                                buttons = {{
                                    { text = T("Annuler"), callback = function() UIManager:close(last_dlg) end },
                                    { text = T("Valider"), is_enter_default = true, callback = function()
                                        local last = tonumber(last_dlg:getInputText())
                                        UIManager:close(last_dlg)
                                        if not last then return end
                                        local count = #chapters_in_range(ctx.chapters, first, last)
                                        if count == 0 then
                                            UIManager:show(InfoMessage:new{ text = T("Aucun chapitre trouvé dans cette plage."), timeout = 3 })
                                            return
                                        end
                                        _range_start, _range_end = first, last
                                        rebuild(ctx)
                                    end },
                                }},
                            }
                            UIManager:show(last_dlg)
                        end },
                    }},
                }
                UIManager:show(first_dlg)
            end,
        }))
    end

    -- FIX : options "Avis des lecteurs au début du livre" et "Tous les
    -- commentaires dans les chapitres" retirées (demandé) — _include_reviews
    -- et _include_comments restent déclarées ci-dessus mais valent toujours
    -- false désormais, faute de case à cocher pour les activer.
    table.insert(rows, P.hairline())

    -- Bascule de l'emplacement
    table.insert(rows, P.makeRow(
        (not flat and "> " or "  ") .. fmt(T("Home/Sefirah/Série/Livre.epub")), {
            mandatory = T("organisé"),
            bold      = not flat,
            callback  = function()
                Settings:set("export_location_flat", false)
                rebuild(ctx)
            end,
        }
    ))
    table.insert(rows, P.makeRow(
        (flat and "> " or "  ") .. fmt(T("Home/Série/Livre.epub")), {
            mandatory = T("plat"),
            bold      = flat == true,
            callback  = function()
                Settings:set("export_location_flat", true)
                rebuild(ctx)
            end,
        }
    ))

    local out_dir = sefirah_base_dir() .. "/"
        .. (ctx.novel.name or ctx.novel.title or T("Roman")):gsub('[<>:"/\\|?*]', "_")
    table.insert(rows, P.makeRow(T("Sortie : ") .. out_dir, { dim = true, callback = function() end }))

    table.insert(rows, P.hairline())
    table.insert(rows, P.makeRow(T("Lancer l'export"), {
        bold = true,
        callback = function() Export.run(ctx) end,
    }))
    table.insert(rows, P.makeRow(T("Annuler"), {
        callback = function() Export.close() end,
    }))

    local function on_back()
        Export.close()
    end

    -- Ferme l'ancien panneau avant d'afficher le nouveau
    if _panel then UIManager:close(_panel) end
    _panel = P.showSubPanel(T("Options d'export"), rows, on_back, close_all)
    SefirahUI.setExport(_panel)
end

function Export.close()
    if _panel then
        UIManager:close(_panel)
        _panel = nil
    end
    local ok, SefirahUI = pcall(require, "ui.main_widget")
    if ok then SefirahUI.clearExport() end
end

return Export
