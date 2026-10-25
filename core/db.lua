-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- JSON-based persistence for tracked novels.
-- Stored at: <koreader_settings>/sefirah/tracked.json
local DataStorage = require("datastorage")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local ok_json, JSON = pcall(require, "rapidjson")
if not ok_json then JSON = require("json") end

local DB = {}

local db_dir      = DataStorage:getSettingsDir() .. "/sefirah"
local db_path     = db_dir .. "/tracked.json"
local exports_path = db_dir .. "/exports.json"
local _data    = nil  -- lazy loaded
local _exports = nil  -- lazy loaded

local function ensure_dir()
    if lfs.attributes(db_dir, "mode") ~= "directory" then
        lfs.mkdir(db_dir)
    end
end

local function load()
    if _data then return _data end
    ensure_dir()
    local f = io.open(db_path, "r")
    if not f then
        _data = { novels = {} }
        return _data
    end
    local raw = f:read("*all")
    f:close()
    local ok, parsed = pcall(JSON.decode, raw)
    _data = (ok and parsed and parsed.novels) and parsed or { novels = {} }
    return _data
end

local _save_pending = false
local function save_now()
    _save_pending = false
    if not _data then return false end
    ensure_dir()
    local f = io.open(db_path, "w")
    if not f then return false end
    f:write(JSON.encode(_data))
    f:close()
    return true
end

-- Écriture différée (regroupe les mises à jour rapprochées) ; DB.flush() force l'écriture.
local function save()
    if _save_pending then return true end
    _save_pending = true
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok and UIManager then
        UIManager:scheduleIn(2, function() if _save_pending then save_now() end end)
    else
        save_now()
    end
    return true
end

function DB.flush()
    if _save_pending then save_now() end
end

function DB.getAll()
    return load().novels
end

function DB.getByFilter(status_filter)
    local novels = load().novels
    if not status_filter or status_filter == "all" then return novels end
    local out = {}
    for _, n in ipairs(novels) do
        local s = (n.status or ""):lower()
        if status_filter == "ongoing" and s == "ongoing" then
            table.insert(out, n)
        elseif status_filter == "completed" and s:match("complet") then
            table.insert(out, n)
        end
    end
    return out
end

function DB.find(source_id, path)
    for _, n in ipairs(load().novels) do
        if n.source_id == source_id and n.path == path then return n end
    end
    return nil
end

-- Track or update a novel.  novel must have: title, source_id, path
function DB.track(novel)
    local data = load()
    for i, n in ipairs(data.novels) do
        if n.source_id == novel.source_id and n.path == novel.path then
            local prev_ch = n.total_chapters or 0
            for k, v in pairs(novel) do n[k] = v end
            n.new_chapters = math.max(0, (n.total_chapters or 0) - prev_ch)
            data.novels[i] = n
            save()
            return n
        end
    end
    -- New entry
    novel.id              = novel.source_id .. ":" .. novel.path
    novel.tracked_at      = os.time()
    novel.new_chapters    = 0
    novel.last_seen_count = novel.total_chapters or 0
    table.insert(data.novels, novel)
    save()
    return novel
end

function DB.untrack(source_id, path)
    local data = load()
    for i, n in ipairs(data.novels) do
        if n.source_id == source_id and n.path == path then
            table.remove(data.novels, i)
            save()
            return true
        end
    end
    return false
end

-- Merge fields into an existing entry by source_id+path
function DB.update(source_id, path, fields)
    local data = load()
    for i, n in ipairs(data.novels) do
        if n.source_id == source_id and n.path == path then
            local prev_ch = n.last_seen_count or n.total_chapters or 0
            for k, v in pairs(fields) do n[k] = v end
            n.new_chapters = math.max(0, (n.total_chapters or 0) - prev_ch)
            data.novels[i] = n
            save()
            return n
        end
    end
    return nil
end

-- ── Export tracking ──────────────────────────────────────────────────────────

local function load_exports()
    if _exports then return _exports end
    ensure_dir()
    local f = io.open(exports_path, "r")
    if not f then _exports = { records = {} }; return _exports end
    local raw = f:read("*all"); f:close()
    local ok, parsed = pcall(JSON.decode, raw)
    _exports = (ok and parsed and parsed.records) and parsed or { records = {} }
    return _exports
end

local function save_exports()
    ensure_dir()
    local f = io.open(exports_path, "w")
    if not f then return false end
    f:write(JSON.encode(_exports))
    f:close()
    return true
end

-- Record which chapter paths were exported to which epub file.
function DB.recordExport(source_id, novel_path, chapter_paths, epub_path)
    DB.exportRev = (DB.exportRev or 0) + 1   -- invalide le cache de ui/detail.lua
    local data = load_exports()
    table.insert(data.records, {
        source_id     = source_id,
        novel_path    = novel_path,
        chapter_paths = chapter_paths,
        epub_path     = epub_path,
        exported_at   = os.time(),
    })
    save_exports()
end

-- Returns a set table {chapter_path = true} of exported chapters whose epub still exists.
function DB.getExportedChapterSet(source_id, novel_path)
    local data = load_exports()
    local set  = {}
    local seen_epub = {}   -- un même .epub est partagé par de nombreux enregistrements
    for _, rec in ipairs(data.records) do
        if rec.source_id == source_id and rec.novel_path == novel_path then
            -- Only include chapters from records where the epub file is still on disk
            local exists = false
            if rec.epub_path then
                exists = seen_epub[rec.epub_path]
                if exists == nil then
                    exists = lfs.attributes(rec.epub_path, "mode") == "file"
                    seen_epub[rec.epub_path] = exists
                end
            end
            if exists then
                for _, cp in ipairs(rec.chapter_paths or {}) do
                    set[cp] = true
                end
            end
        end
    end
    return set
end

-- ── Chapter list cache ────────────────────────────────────────────────────────
-- One JSON file per novel: <db_dir>/chapter_cache/<key>.json
-- key is source_id__novel_path with non-alphanumeric chars replaced by "_".

local chapter_cache_dir = db_dir .. "/chapter_cache"
local cover_cache_dir   = db_dir .. "/covers"

local function ensure_chapter_cache_dir()
    ensure_dir()
    if lfs.attributes(chapter_cache_dir, "mode") ~= "directory" then
        lfs.mkdir(chapter_cache_dir)
    end
end

local function ensure_cover_cache_dir()
    ensure_dir()
    if lfs.attributes(cover_cache_dir, "mode") ~= "directory" then
        lfs.mkdir(cover_cache_dir)
    end
end

local function cache_key(source_id, novel_path)
    return (source_id .. "__" .. novel_path):gsub("[^%w%-]", "_")
end

function DB.loadChapterCache(source_id, novel_path)
    local key  = cache_key(source_id, novel_path)
    local path = chapter_cache_dir .. "/" .. key .. ".json"
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*all"); f:close()
    local ok, data = pcall(JSON.decode, raw)
    if not ok or not data or not data.chapters then return nil end
    return data
end

function DB.saveChapterCache(source_id, novel_path, chapters, total)
    ensure_chapter_cache_dir()
    local key  = cache_key(source_id, novel_path)
    local path = chapter_cache_dir .. "/" .. key .. ".json"
    local f = io.open(path, "w")
    if not f then return end
    f:write(JSON.encode({ chapters = chapters, total = total, saved_at = os.time() }))
    f:close()
end

-- Supprime UNE seule fois (repère « .<marker> » dans le dossier) les listes de chapitres en cache
-- d'une source — utile quand l'ancien choix de traduction enregistré dans la liste était mauvais.
function DB.purgeChapterCacheOnce(source_id, marker)
    ensure_chapter_cache_dir()
    local mpath = chapter_cache_dir .. "/." .. tostring(marker)
    if lfs.attributes(mpath, "mode") == "file" then return 0 end
    local prefix = (source_id .. "__"):gsub("[^%w%-]", "_")
    local n = 0
    for name in lfs.dir(chapter_cache_dir) do
        if name:sub(1, #prefix) == prefix and name:match("%.json$") then
            if os.remove(chapter_cache_dir .. "/" .. name) then n = n + 1 end
        end
    end
    local f = io.open(mpath, "wb")
    if f then f:write("1"); f:close() end
    return n
end

-- ── Cover image cache ─────────────────────────────────────────────────────────
-- Raw image bytes stored as <db_dir>/covers/<key>.img

function DB.loadCoverCache(source_id, novel_path)
    local key  = cache_key(source_id, novel_path)
    local path = cover_cache_dir .. "/" .. key .. ".img"
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*all"); f:close()
    return data ~= "" and data or nil
end

function DB.saveCoverCache(source_id, novel_path, data)
    ensure_cover_cache_dir()
    local key  = cache_key(source_id, novel_path)
    local path = cover_cache_dir .. "/" .. key .. ".img"
    local f = io.open(path, "wb")
    if not f then return end
    f:write(data); f:close()
end

-- Supprime UNE seule fois (repère « .<marker> » dans le dossier) toutes les couvertures
-- en cache d'une source — utile quand l'ancienne image mise en cache était fausse.
function DB.purgeCoverCacheOnce(source_id, marker)
    ensure_cover_cache_dir()
    local mpath = cover_cache_dir .. "/." .. tostring(marker)
    if lfs.attributes(mpath, "mode") == "file" then return 0 end
    local prefix = (source_id .. "__"):gsub("[^%w%-]", "_")
    local n = 0
    for name in lfs.dir(cover_cache_dir) do
        if name:sub(1, #prefix) == prefix and name:match("%.img$") then
            if os.remove(cover_cache_dir .. "/" .. name) then n = n + 1 end
        end
    end
    local f = io.open(mpath, "wb")
    if f then f:write("1"); f:close() end
    return n
end

-- ── Reviews cache ────────────────────────────────────────────────────────────
-- One JSON file per novel: <db_dir>/review_cache/<key>.json
-- Contrairement au cache de chapitres, on garde aussi la page et has_more
-- pour reprendre la pagination hors ligne sans tout retélécharger.

local review_cache_dir = db_dir .. "/review_cache"
local avatar_cache_dir = db_dir .. "/avatars"

local function ensure_review_cache_dir()
    ensure_dir()
    if lfs.attributes(review_cache_dir, "mode") ~= "directory" then
        lfs.mkdir(review_cache_dir)
    end
end

local function ensure_avatar_cache_dir()
    ensure_dir()
    if lfs.attributes(avatar_cache_dir, "mode") ~= "directory" then
        lfs.mkdir(avatar_cache_dir)
    end
end

function DB.loadReviewCache(source_id, novel_path)
    local key  = cache_key(source_id, novel_path)
    local path = review_cache_dir .. "/" .. key .. ".json"
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*all"); f:close()
    local ok, data = pcall(JSON.decode, raw)
    if not ok or not data or not data.reviews then return nil end
    return data
end

function DB.saveReviewCache(source_id, novel_path, reviews, page, has_more, rev)
    ensure_review_cache_dir()
    local key  = cache_key(source_id, novel_path)
    local path = review_cache_dir .. "/" .. key .. ".json"
    local f = io.open(path, "w")
    if not f then return end
    f:write(JSON.encode({ reviews = reviews, page = page, has_more = has_more, saved_at = os.time(), rev = rev }))
    f:close()
end

function DB.clearReviewCache(source_id, novel_path)
    local key  = cache_key(source_id, novel_path)
    os.remove(review_cache_dir .. "/" .. key .. ".json")
end

-- ── Chapter comments cache ───────────────────────────────────────────────────
-- One JSON file per chapter: <db_dir>/chapter_comment_cache/<key>.json
-- Même principe que le cache des avis (ci-dessus), mais la clé est le
-- chapitre (source_id + chapter path) plutôt que le roman : les commentaires
-- sont propres à CE chapitre, pas au roman entier. cache_key() est déjà
-- générique (concatène + assainit deux chaînes), donc réutilisable telle
-- quelle avec un chemin de chapitre à la place d'un chemin de roman.

local chapter_comment_cache_dir = db_dir .. "/chapter_comment_cache"

local function ensure_chapter_comment_cache_dir()
    ensure_dir()
    if lfs.attributes(chapter_comment_cache_dir, "mode") ~= "directory" then
        lfs.mkdir(chapter_comment_cache_dir)
    end
end

function DB.loadChapterCommentsCache(source_id, chapter_path)
    local key  = cache_key(source_id, chapter_path)
    local path = chapter_comment_cache_dir .. "/" .. key .. ".json"
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*all"); f:close()
    local ok, data = pcall(JSON.decode, raw)
    if not ok or not data or not data.comments then return nil end
    return data
end

function DB.saveChapterCommentsCache(source_id, chapter_path, comments, next_page, has_more)
    ensure_chapter_comment_cache_dir()
    local key  = cache_key(source_id, chapter_path)
    local path = chapter_comment_cache_dir .. "/" .. key .. ".json"
    local f = io.open(path, "w")
    if not f then return end
    f:write(JSON.encode({ comments = comments, next_page = next_page, has_more = has_more, saved_at = os.time() }))
    f:close()
end

-- ── Avatar cache ─────────────────────────────────────────────────────────────
-- Raw image bytes, keyed by URL (pas par roman : le même auteur peut
-- commenter plusieurs romans, inutile de retélécharger son avatar).

local function avatar_key(url)
    return tostring(url):gsub("[^%w%-]", "_")
end

function DB.loadAvatarCache(url)
    if not url or url == "" then return nil end
    local path = avatar_cache_dir .. "/" .. avatar_key(url) .. ".img"
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*all"); f:close()
    return data ~= "" and data or nil
end

-- Purge au plus 1 fois par session : supprime les fichiers trop gros, puis les
-- plus anciens au-delà de max_files.
function DB.pruneAvatars(max_files, max_bytes)
    if lfs.attributes(avatar_cache_dir, "mode") ~= "directory" then return end
    local files = {}
    for name in lfs.dir(avatar_cache_dir) do
        if name ~= "." and name ~= ".." then
            local p = avatar_cache_dir .. "/" .. name
            local a = lfs.attributes(p)
            if a and a.mode == "file" then
                if max_bytes and a.size > max_bytes then
                    os.remove(p)
                else
                    files[#files + 1] = { p = p, t = a.modification or 0 }
                end
            end
        end
    end
    if max_files and #files > max_files then
        table.sort(files, function(x, y) return x.t > y.t end)
        for i = max_files + 1, #files do os.remove(files[i].p) end
    end
end

function DB.saveAvatarCache(url, data)
    if not url or url == "" or not data or #data == 0 then return end
    ensure_avatar_cache_dir()
    local f = io.open(avatar_cache_dir .. "/" .. avatar_key(url) .. ".img", "wb")
    if not f then return end
    f:write(data); f:close()
end

return DB
