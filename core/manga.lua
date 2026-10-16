-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- core/manga.lua — Téléchargement d'un chapitre de manga et assemblage en CBZ
-- (étapes 9 à 11, 15, 16). Le CBZ est ensuite ouvert par le lecteur natif de KOReader.
--
--   Manga.cbzPath(novel_title, chapter, index)  -> chemin du CBZ (attendu)
--   Manga.isDownloaded(novel_title, chapter, index)
--   Manga.download{ ext, chapter, novel_title, index, on_progress, on_done }
--       on_progress(done, total)   — optionnel
--       is_cancelled()             — optionnel ; vrai = arrêter (pages déjà reçues gardées)
--       on_done(ok, cbz_path | erreur)   (erreur "cancelled" si annulé)
--   Un téléchargement interrompu (annulation, coupure, pages manquantes) est
--   REPRIS au prochain essai : les pages déjà reçues restent dans .tmp_*.
--   Manga.usedBytes(), Manga.clearAll(), Manga.cleanTemp(jours)
--   Manga.enforceLimit(max_mb, keep_path)  -> supprime les plus anciens CBZ
--
-- À appeler depuis NetworkMgr:runWhenConnected (comme Cache.downloadChapter).
local logger      = require("logger")
local DataStorage = require("datastorage")
local Http        = require("core.http")
local Parallel    = require("core.parallel")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

local Manga = {}

local WAVE        = 20    -- images téléchargées en même temps (fenêtre glissante)
local GLOBAL_CAP  = 28    -- plafond de sous-processus, tous chapitres confondus
local JOB_TIMEOUT = 40    -- secondes max par image (2 essais de 20 s) avant arrêt de la tâche
local TRY_TIMEOUT = 15    -- secondes max par essai (une connexion qui traîne est relancée vite)
local TOTAL_TIMEOUT = 1200 -- secondes max pour tout un chapitre
local MIN_BYTES   = 256   -- en dessous : réponse d'erreur, pas une image

-- ── Chemins ──────────────────────────────────────────────────────────────────
local function base_dir()
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if not home or home == "" then
        local full = DataStorage:getFullDataDir() or DataStorage:getDataDir()
        home = full:match("^(.*)/%.adds/") or full:match("^(.*)/koreader$") or full
    end
    return home .. "/Sefirah/Manga"
end

local function safe_name(s, fallback)
    s = tostring(s or ""):gsub('[/\\:*?"<>|%c]', "_"):gsub("%s+", " ")
    s = s:match("^[%s%._]*(.-)[%s%._]*$") or ""
    if #s > 80 then s = s:sub(1, 80) end
    if s == "" then s = fallback or "sans-titre" end
    return s
end

local function mkdirs(path)
    local cur = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        cur = cur .. part
        if lfs.attributes(cur, "mode") ~= "directory" then lfs.mkdir(cur) end
        cur = cur .. "/"
    end
    return lfs.attributes(path, "mode") == "directory"
end

function Manga.cbzPath(novel_title, chapter, index)
    local name = string.format("%04d - %s", tonumber(index) or 0, safe_name(chapter and chapter.name, "chapitre"))
    return base_dir() .. "/" .. safe_name(novel_title, "manga") .. "/" .. name .. ".cbz"
end

function Manga.isDownloaded(novel_title, chapter, index)
    local a = lfs.attributes(Manga.cbzPath(novel_title, chapter, index))
    return a and a.mode == "file" and (a.size or 0) > 1024 or false
end

-- ── Fichiers temporaires ─────────────────────────────────────────────────────
local function rm_tree(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for f in lfs.dir(dir) do
        if f ~= "." and f ~= ".." then os.remove(dir .. "/" .. f) end
    end
    lfs.rmdir(dir)
end

local function file_size(path)
    local a = lfs.attributes(path)
    return a and a.size or 0
end

local function image_ext(url)
    local e = (url:match("%.(%w+)%??[^%./]*$") or "jpg"):lower()
    if e == "jpeg" then e = "jpg" end
    if e ~= "png" and e ~= "webp" and e ~= "gif" then e = "jpg" end
    return e
end

-- ── Nettoyage / espace disque ────────────────────────────────────────────────
local function rm_rf(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        for f in lfs.dir(path) do
            if f ~= "." and f ~= ".." then rm_rf(path .. "/" .. f) end
        end
        lfs.rmdir(path)
    elseif mode then
        os.remove(path)
    end
end

local function tree_size(path)
    local a = lfs.attributes(path)
    if not a then return 0 end
    if a.mode ~= "directory" then return a.size or 0 end
    local n = 0
    for f in lfs.dir(path) do
        if f ~= "." and f ~= ".." then n = n + tree_size(path .. "/" .. f) end
    end
    return n
end

function Manga.usedBytes() return tree_size(base_dir()) end

-- Supprime TOUS les mangas téléchargés ; renvoie le nombre d'octets libérés.
function Manga.clearAll()
    local root = base_dir()
    local before = tree_size(root)
    if lfs.attributes(root, "mode") == "directory" then
        for f in lfs.dir(root) do
            if f ~= "." and f ~= ".." then rm_rf(root .. "/" .. f) end
        end
    end
    return before
end

-- Supprime les téléchargements (CBZ + pages temporaires) d'UN manga ; renvoie les octets libérés.
function Manga.removeNovel(novel_title)
    local dir = base_dir() .. "/" .. safe_name(novel_title, "manga")
    local before = tree_size(dir)
    rm_rf(dir)
    return before
end

-- Supprime les téléchargements interrompus abandonnés depuis plus de `days` jours.
function Manga.cleanTemp(days)
    local root = base_dir()
    if lfs.attributes(root, "mode") ~= "directory" then return end
    local limit = os.time() - (days or 3) * 86400
    for series in lfs.dir(root) do
        if series ~= "." and series ~= ".." then
            local sdir = root .. "/" .. series
            if lfs.attributes(sdir, "mode") == "directory" then
                for f in lfs.dir(sdir) do
                    if f:match("^%.tmp_") then
                        local a = lfs.attributes(sdir .. "/" .. f)
                        if a and (a.modification or 0) < limit then rm_rf(sdir .. "/" .. f) end
                    end
                end
            end
        end
    end
end

-- ── Téléchargement par vagues ────────────────────────────────────────────────
-- Écrit dans « .part » puis renomme : un sous-processus tué au timeout ne laisse
-- jamais une image tronquée qui passerait pour une page complète à la reprise.
local function download_one(url, dest, headers)
    local part = dest .. ".part"
    for _ = 1, 2 do
        local ok = Http.download(url, part, TRY_TIMEOUT, headers)
        if ok and file_size(part) >= MIN_BYTES then
            os.remove(dest)
            if os.rename(part, dest) then return true end
        end
        os.remove(part)
    end
    return false
end

-- Télécharge les `todo` (liste d'indices) avec `wave_size` images en cours en permanence
-- (dès qu'une finit, la suivante démarre : on n'attend plus la plus lente d'une vague).
-- done(aborted) : aborted = true si `cancelled()` a coupé la boucle.
local BATCH_WIDTH = 10   -- connexions simultanées en mode « batch » (plusieurs images par connexion)

local function run_waves(items, todo, on_progress, done_count, total, done, cancelled, wave_size, on_tail, batch)
    wave_size = wave_size or WAVE
    local socket = require("socket")

    -- Mode « batch » (source qui le demande, 1re passe seulement) : chaque sous-processus
    -- télécharge plusieurs images à la suite sur UNE connexion TLS, au lieu d'une connexion
    -- (donc une poignée de main TLS coûteuse) par image. Les images en échec sont reprises
    -- ensuite par la 2e passe classique.
    local jobs, batch_mode = {}, false
    local workers = 0
    if batch and #todo >= 4 then
        batch_mode = true
        workers = math.min(BATCH_WIDTH, math.ceil(#todo / 3))
        local groups = {}
        for g = 1, workers do groups[g] = {} end
        for k, idx in ipairs(todo) do
            local g = (k - 1) % workers + 1
            groups[g][#groups[g] + 1] = idx
        end
        for _, grp in ipairs(groups) do
            jobs[#jobs + 1] = function()
                local list = {}
                for _, idx in ipairs(grp) do
                    list[#list + 1] = { url = items[idx].url, dest = items[idx].path .. ".part", idx = idx }
                end
                Http.download_many(list, TRY_TIMEOUT, items[grp[1]].headers, function(k, ok)
                    local e = list[k]
                    if ok and file_size(e.dest) >= MIN_BYTES then
                        os.remove(items[e.idx].path)
                        if not os.rename(e.dest, items[e.idx].path) then os.remove(e.dest) end
                    else
                        os.remove(e.dest)
                    end
                end)
            end
        end
    else
        for _, idx in ipairs(todo) do
            local it = items[idx]
            jobs[#jobs + 1] = function() download_one(it.url, it.path, it.headers) end
        end
    end

    -- Progression limitée à ~1 fois par seconde (le rafraîchissement e-ink est lent).
    local last = 0
    local function progress(n)
        if not on_progress then return end
        local now = socket.gettime()
        if n >= #todo or now - last >= 1 then
            last = now
            pcall(on_progress, math.min(done_count + n, total), total)
        end
    end
    -- En batch, la fin d'un job = la fin de toutes SES images : on compte donc les fichiers reçus.
    local last_tick = 0
    local function on_tick()
        local now = socket.gettime()
        if now - last_tick < 1 then return end
        last_tick = now
        local n = 0
        for _, idx in ipairs(todo) do
            if file_size(items[idx].path) >= MIN_BYTES then n = n + 1 end
        end
        progress(n)
    end

    local job_timeout = JOB_TIMEOUT
    if batch_mode then
        job_timeout = math.min(900, JOB_TIMEOUT * math.ceil(#todo / workers))
    end

    local started = Parallel.pool(jobs, math.max(wave_size, batch_mode and workers or 0),
        function(aborted) done(aborted) end, {
        job_timeout  = job_timeout,
        timeout      = TOTAL_TIMEOUT,
        is_cancelled = cancelled,
        on_progress  = (not batch_mode) and function(n) progress(n) end or nil,
        on_tick      = batch_mode and on_tick or nil,
        global_cap   = GLOBAL_CAP,
        on_all_launched = on_tail,
    })
    if started then return end
    if on_tail then pcall(on_tail) end

    -- Pas de sous-processus disponibles : séquentiel.
    for k, idx in ipairs(todo) do
        if cancelled and cancelled() then return done(true) end
        local it = items[idx]
        download_one(it.url, it.path, it.headers)
        progress(k)
    end
    done(false)
end

-- ── Assemblage du CBZ ────────────────────────────────────────────────────────
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

-- Archiveur natif de KOReader (rapide, CRC en C), sans compression : les
-- images sont déjà compressées.
local function zip_native(cbz, items)
    local ok_a, Archiver = pcall(require, "ffi/archiver")
    if not ok_a or not Archiver or not Archiver.Writer then return false end
    local w = Archiver.Writer:new{}
    if not w:open(cbz, "zip") then return false end
    pcall(function() w:setZipCompression("store") end)
    for _, it in ipairs(items) do
        local data = it.get and it.get() or read_file(it.path)
        if not data or not w:addFileFromMemory(it.name, data, os.time()) then
            w:close()
            return false
        end
    end
    w:close()
    return true
end

-- Repli : écrivain ZIP « stored » en Lua pur (CRC32 lent mais correct).
local function zip_fallback(cbz, items)
    local bit = require("bit")
    local band, rshift, bxor = bit.band, bit.rshift, bit.bxor
    local function le2(n) return string.char(band(n, 0xFF), band(rshift(n, 8), 0xFF)) end
    local function le4(n)
        n = band(n, 0xFFFFFFFF)
        return string.char(band(n, 0xFF), band(rshift(n, 8), 0xFF), band(rshift(n, 16), 0xFF), band(rshift(n, 24), 0xFF))
    end
    local tbl = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do c = (band(c, 1) == 1) and bxor(0xEDB88320, rshift(c, 1)) or rshift(c, 1) end
        tbl[i] = c
    end
    local function crc32(data)
        local crc = 0xFFFFFFFF
        for i = 1, #data do crc = bxor(tbl[band(bxor(crc, data:byte(i)), 0xFF)], rshift(crc, 8)) end
        return band(bxor(crc, 0xFFFFFFFF), 0xFFFFFFFF)
    end
    local f = io.open(cbz, "wb")
    if not f then return false end
    local cd, offset = {}, 0
    local zero = le2(0) .. le2(0)
    for _, it in ipairs(items) do
        local data = it.get and it.get() or read_file(it.path)
        if not data then f:close(); return false end
        local crc, size, nm = crc32(data), #data, it.name
        local lfh = table.concat({ "PK\3\4", le2(20), le2(0), le2(0), zero, le4(crc), le4(size), le4(size), le2(#nm), le2(0), nm })
        f:write(lfh); f:write(data)
        cd[#cd + 1] = table.concat({ "PK\1\2", le2(20), le2(20), le2(0), le2(0), zero, le4(crc), le4(size), le4(size),
            le2(#nm), le2(0), le2(0), le2(0), le2(0), le4(0), le4(offset), nm })
        offset = offset + #lfh + size
    end
    local cd_size = 0
    for _, r in ipairs(cd) do f:write(r); cd_size = cd_size + #r end
    f:write(table.concat({ "PK\5\6", le2(0), le2(0), le2(#items), le2(#items), le4(cd_size), le4(offset), le2(0) }))
    f:close()
    return true
end

-- ── Couverture du manga (pas la 1re page d'un chapitre) ──────────────────────
local function image_kind(data)
    if type(data) ~= "string" or #data < 12 then return nil end
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 4) == "\137PNG" then return "png" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
    if data:sub(1, 3) == "GIF" then return "gif" end
    return nil
end

local _cover_memo = {}

-- Renvoie octets, extension (ou nil). Ordre : URL MangaDex 512 px, URL d'origine,
-- puis cache disque de Sefirah. Mémorisé par manga pour ne pas retélécharger à chaque chapitre.
function Manga.fetchCover(source_id, novel)
    novel = novel or {}
    local key = tostring(source_id) .. "|" .. tostring(novel.path or novel.name or "")
    local m = _cover_memo[key]
    if m then return m[1], m[2] end
    local Epub = require("core.epub")
    local ok_e, ExtMgr = pcall(require, "core.extmgr")
    local site = ok_e and (ExtMgr.getMeta(source_id) or {}).site or nil
    local urls = {}
    if novel.cover and novel.cover ~= "" then
        local big = novel.cover:gsub("%.256%.jpg$", ".512.jpg")
        if big ~= novel.cover then urls[#urls + 1] = big end
        urls[#urls + 1] = novel.cover
    end
    for _, u in ipairs(urls) do
        local ok_f, data = pcall(Epub.fetch_cover, u, site)
        local kind = ok_f and image_kind(data)
        if kind then _cover_memo[key] = { data, kind }; return data, kind end
    end
    local ok_d, DB = pcall(require, "core.db")
    if ok_d then
        local ok_c, cached = pcall(DB.loadCoverCache, source_id, novel.path or "")
        if ok_c and image_kind(cached) then
            _cover_memo[key] = { cached, image_kind(cached) }
            return cached, image_kind(cached)
        end
    end
    return nil
end

-- Écrit un CBZ à partir d'entrées { name, path | get = function() -> octets }.
-- Utilisé par l'export (couverture du manga en première page + pages des chapitres).
function Manga.writeCbz(dest, items)
    os.remove(dest)
    local ok = zip_native(dest, items)
    if not ok then
        os.remove(dest)
        ok = zip_fallback(dest, items)
    end
    if not ok or file_size(dest) < 1024 then os.remove(dest); return false end
    return true
end

-- Supprime le dossier temporaire d'un téléchargement `no_zip` une fois l'export écrit.
function Manga.cleanPages(handle)
    if type(handle) == "table" and handle.tmp then rm_tree(handle.tmp) end
end

-- ── Téléchargement d'un chapitre ─────────────────────────────────────────────
-- opts.no_zip = true : ne crée PAS de CBZ ; renvoie { pages = {{name,path}…}, tmp = dossier }
-- (l'export assemble lui-même un seul CBZ avec la couverture → deux fois moins d'écriture disque).
-- opts.wave : nombre d'images téléchargées en parallèle (défaut 20).
-- opts.on_tail : appelé UNE fois quand la dernière image du chapitre vient d'être
-- lancée (il ne reste que la « queue » en cours) : l'appelant peut démarrer le
-- chapitre suivant tout de suite au lieu d'attendre la fin de la plus lente image.
function Manga.download(opts)
    local tail_fired = false
    local function fire_tail()
        if tail_fired then return end
        tail_fired = true
        if opts.on_tail then pcall(opts.on_tail) end
    end
    local on_done_raw = opts.on_done or function() end
    local function on_done(...) fire_tail(); return on_done_raw(...) end
    local cancelled = opts.is_cancelled
    local ext, chapter = opts.ext, opts.chapter
    if not ext or not ext.parseChapterImages or not chapter or not chapter.path then
        return on_done(false, "bad_arguments")
    end

    local cbz = Manga.cbzPath(opts.novel_title, chapter, opts.index)
    if Manga.isDownloaded(opts.novel_title, chapter, opts.index) then
        return on_done(true, cbz)   -- déjà en cache (CBZ) : l'appelant gère les deux formes
    end
    pcall(Manga.cleanTemp, 3)

    local ok_p, res, perr = pcall(ext.parseChapterImages, ext, chapter.path)
    if not ok_p or type(res) ~= "table" or type(res.images) ~= "table" or #res.images == 0 then
        logger.warn("Sefirah/Manga: pas d'images pour", tostring(chapter.path), tostring(ok_p and perr or res))
        return on_done(false, (ok_p and perr) or "no_images")
    end

    local dir = cbz:match("^(.*)/[^/]+$")
    if not mkdirs(dir) then return on_done(false, "mkdir_failed") end
    -- Dossier temporaire STABLE (pas vidé au départ) : reprise d'un téléchargement
    -- interrompu. Les pages sont reconnues par leur numéro, pas par leur URL
    -- (le serveur d'images MangaDex change d'un essai à l'autre).
    local tmp = dir .. "/.tmp_" .. safe_name(string.format("%04d_%s", tonumber(opts.index) or 0, tostring(chapter.path):sub(-20)), "x")
    if not mkdirs(tmp) then return on_done(false, "mkdir_failed") end

    local items, todo, have = {}, {}, 0
    for i, url in ipairs(res.images) do
        local name = string.format("%04d.%s", i, image_ext(url))
        items[i] = { url = url, name = name, path = tmp .. "/" .. name, headers = res.headers }
        if file_size(items[i].path) >= MIN_BYTES then
            have = have + 1
        else
            todo[#todo + 1] = i
        end
    end
    local total = #items
    if have > 0 then
        logger.dbg("Sefirah/Manga: reprise,", have, "/", total, "pages déjà présentes")
        if opts.on_progress then pcall(opts.on_progress, have, total) end
    end

    -- Succès : on supprime le dossier temporaire. Échec/annulation : on le GARDE.
    local function finish(ok, value)
        if ok then rm_tree(tmp) else os.remove(cbz) end
        on_done(ok, value)
    end

    local function assemble()
        if opts.no_zip then
            return on_done(true, { pages = items, tmp = tmp })
        end
        -- Couverture du manga en première entrée : les vignettes (explorateur de
        -- fichiers, bookshelf) prennent la première image du CBZ.
        if opts.cover_fn then
            local ok_c, cdata, ckind = pcall(opts.cover_fn)
            if ok_c and cdata and ckind then
                table.insert(items, 1, { name = "0000_cover." .. ckind, get = function() return cdata end })
            end
        end
        local ok = zip_native(cbz, items)
        if not ok then
            logger.warn("Sefirah/Manga: archiveur natif indisponible, repli Lua")
            ok = zip_fallback(cbz, items)
        end
        if not ok or file_size(cbz) < 1024 then return finish(false, "zip_failed") end
        pcall(Manga.enforceLimit, nil, cbz)
        finish(true, cbz)
    end

    local function count_missing()
        local missing = {}
        for i, it in ipairs(items) do
            if file_size(it.path) < MIN_BYTES then missing[#missing + 1] = i end
        end
        return missing
    end

    local function on_first_pass(aborted)
        if aborted then return finish(false, "cancelled") end
        local missing = count_missing()
        if #missing == 0 then return assemble() end
        -- Une seconde passe pour les pages manquantes (coupure réseau, timeout).
        logger.warn("Sefirah/Manga:", #missing, "pages manquantes, nouvel essai")
        run_waves(items, missing, nil, 0, #missing, function(aborted2)
            if aborted2 then return finish(false, "cancelled") end
            if #count_missing() > 0 then return finish(false, "missing_pages") end
            assemble()
        end, cancelled, math.max(2, math.floor((opts.wave or WAVE) / 2)))
    end

    if #todo == 0 then return assemble() end
    run_waves(items, todo, opts.on_progress, have, total, on_first_pass, cancelled, opts.wave, fire_tail, res.batch)
end

-- ── Espace disque (étape 11) ─────────────────────────────────────────────────
-- Supprime les CBZ les plus anciens tant que le total dépasse la limite.
-- `keep` (chemin) n'est jamais supprimé (le chapitre qu'on vient de créer).
function Manga.enforceLimit(max_mb, keep)
    if not max_mb then
        local ok_s, Settings = pcall(require, "settings")
        max_mb = ok_s and tonumber(Settings:get("manga_max_mb")) or 1000
    end
    if max_mb <= 0 then return end   -- 0 = illimité
    local root = base_dir()
    if lfs.attributes(root, "mode") ~= "directory" then return end

    local files, total = {}, 0
    for series in lfs.dir(root) do
        if series ~= "." and series ~= ".." then
            local sdir = root .. "/" .. series
            if lfs.attributes(sdir, "mode") == "directory" then
                for f in lfs.dir(sdir) do
                    if f:match("%.cbz$") then
                        local p = sdir .. "/" .. f
                        local a = lfs.attributes(p)
                        if a and a.mode == "file" then
                            files[#files + 1] = { path = p, size = a.size, time = a.modification or 0 }
                            total = total + a.size
                        end
                    end
                end
            end
        end
    end
    local cap = max_mb * 1024 * 1024
    if total <= cap then return end
    table.sort(files, function(a, b) return a.time < b.time end)
    for _, f in ipairs(files) do
        if total <= cap then break end
        if f.path ~= keep then
            os.remove(f.path)
            total = total - f.size
            logger.dbg("Sefirah/Manga: supprimé (limite d'espace)", f.path)
        end
    end
end

return Manga
