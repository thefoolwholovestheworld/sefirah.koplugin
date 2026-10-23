-- core/aimg.lua — images distantes du profil AniList (avatar, bannière, couvertures).
--
-- * téléchargement groupé (sous-processus en parallèle si possible) puis cache disque ;
-- * décodage + mise à l'échelle « cover » (recadrage centré) en mémoire ;
-- * les buffers décodés appartiennent à ce module : Aimg.release() les libère
--   (à appeler quand l'écran du profil se ferme).
local DataStorage = require("datastorage")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local Http     = require("core.http")
local Parallel = require("core.parallel")

local Aimg = {}

local MAX_BYTES = 800 * 1024
local base_dir  = DataStorage:getSettingsDir() .. "/sefirah"
local dir       = base_dir .. "/anilist_img"

local _failed = {}   -- url → true : échec constaté pendant cette session
local _memo   = {}   -- clé → BlitBuffer | false
local _pruned = false

local function ensure_dir()
    for _, d in ipairs({ base_dir, dir }) do
        if lfs.attributes(d, "mode") ~= "directory" then lfs.mkdir(d) end
    end
end

local function path_for(url)
    local s = tostring(url):gsub("[^%w%-]", "_")
    return dir .. "/" .. s:sub(-120) .. ".img"
end

local function read_file(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local d = f:read("*all"); f:close()
    return d ~= "" and d or nil
end

local function write_file(p, data)
    local f = io.open(p, "wb")
    if not f then return end
    f:write(data); f:close()
end

local function cached(url)
    return lfs.attributes(path_for(url), "mode") == "file"
end

-- Garde les `max_files` fichiers les plus récents (au plus une fois par session).
local function prune(max_files)
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local files = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local p = dir .. "/" .. name
            local a = lfs.attributes(p)
            if a and a.mode == "file" then files[#files + 1] = { p = p, t = a.modification or 0 } end
        end
    end
    if #files > max_files then
        table.sort(files, function(x, y) return x.t > y.t end)
        for i = max_files + 1, #files do os.remove(files[i].p) end
    end
end

-- Télécharge (si absentes du cache) les images de la liste d'URL.
function Aimg.prefetch(urls)
    ensure_dir()
    if not _pruned then _pruned = true; pcall(prune, 300) end
    local seen, todo = {}, {}
    for _, url in ipairs(urls or {}) do
        if type(url) == "string" and url ~= "" and not seen[url] and not _failed[url] and not cached(url) then
            seen[url] = true
            todo[#todo + 1] = url
        end
    end
    if #todo == 0 then return end

    if Parallel.available() then
        local jobs = {}
        for _, url in ipairs(todo) do
            jobs[#jobs + 1] = function()
                local data = Http.get(url, nil, 10, MAX_BYTES)
                if data and #data >= 64 then write_file(path_for(url), data) end
            end
        end
        if Parallel.runAndWait(jobs, 25) then
            for _, url in ipairs(todo) do if not cached(url) then _failed[url] = true end end
            return
        end
    end

    local misses = 0
    for _, url in ipairs(todo) do
        local data = Http.get(url, nil, 8, MAX_BYTES)
        if data and #data >= 64 then
            write_file(path_for(url), data)
            misses = 0
        else
            _failed[url] = true
            misses = misses + 1
            if misses >= 2 then break end   -- réseau coupé : inutile d'insister
        end
    end
end

-- Mise à l'échelle qui REMPLIT w × h puis recadre le surplus au centre.
-- Libère `native` ; l'appelant possède le buffer renvoyé.
local function scale_cover(native, nw, nh, w, h)
    local scale = math.max(w / nw, h / nh)
    local dw = math.max(w, math.ceil(nw * scale))
    local dh = math.max(h, math.ceil(nh * scale))
    local scaled = native:scale(dw, dh)
    native:free()
    if dw == w and dh == h then return scaled end
    local ok, out = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local target = Blitbuffer.new(w, h, scaled:getType())
        target:blitFrom(scaled, 0, 0, math.floor((dw - w) / 2), math.floor((dh - h) / 2), w, h)
        return target
    end)
    if ok and out then scaled:free(); return out end
    return scaled
end

-- BlitBuffer w × h pour l'URL (cache disque requis, voir prefetch), ou nil.
function Aimg.bb(url, w, h)
    if type(url) ~= "string" or url == "" then return nil end
    local key = url .. "|" .. w .. "x" .. h
    if _memo[key] ~= nil then return _memo[key] or nil end
    if not cached(url) then return nil end   -- pas encore téléchargée : on réessaiera
    local bb
    local p = path_for(url)
    local data = cached(url) and read_file(p) or nil
    if data and #data >= 64 and #data <= MAX_BYTES then
        local ok_ri, RenderImage = pcall(require, "ui/renderimage")
        if ok_ri then
            local ok, native = pcall(RenderImage.renderImageData, RenderImage, data, #data, false, w, h)
            if ok and native then
                local nw, nh = native:getWidth(), native:getHeight()
                if nw > 0 and nh > 0 then
                    local ok2, out = pcall(scale_cover, native, nw, nh, w, h)
                    bb = ok2 and out or nil
                else
                    native:free()
                end
            end
        end
        if not bb then os.remove(p) end   -- fichier corrompu : sera retéléchargé
    end
    _memo[key] = bb or false
    return bb
end

function Aimg.release()
    for _, bb in pairs(_memo) do
        if bb then pcall(bb.free, bb) end
    end
    _memo = {}
end

return Aimg
