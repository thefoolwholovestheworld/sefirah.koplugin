-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- core/avatars.lua — Avatar fetch + disk-cache + decode + scale helper for
-- review authors (ui/detail.lua). Mirrors core/covers.lua's approach but
-- keyed by avatar URL (shared across novels/reviews) rather than by
-- (source_id, novel_path).
local DB   = require("core.db")
local Http = require("core.http")

local Avatars = {}

-- Un avatar d'avis s'affiche en ~48 px : au-delà de 256 Ko c'est une photo
-- brute (jusqu'à 3 Mo, ou un GIF animé de 200 images) dont le décodage figeait
-- l'onglet Avis. Ces fichiers sont refusés au téléchargement ET à la lecture.
local MAX_AVATAR_BYTES = 96 * 1024
local _failed = {}   -- url → true : échec déjà constaté pendant cette session
local _pruned = false

-- Recadre bb (déjà mis à l'échelle pour que son plus petit côté fasse
-- exactement size) en un carré size×size centré, puis découpe un cercle
-- inscrit dedans (coins passés en blanc) — pour une pdp ronde plutôt que le
-- carré brut décodé depuis le site. Protégé par pcall côté appelant : en cas
-- de souci avec une API blitbuffer inattendue, on préfère l'avatar carré
-- d'origine à un plantage de l'onglet Avis.
local function mask_circle(bb, size)
    local Blitbuffer = require("ffi/blitbuffer")
    local w, h = bb:getWidth(), bb:getHeight()
    local off_x = math.max(0, math.floor((w - size) / 2))
    local off_y = math.max(0, math.floor((h - size) / 2))

    local square = Blitbuffer.new(size, size)
    square:fill(Blitbuffer.COLOR_WHITE)
    square:blitFrom(bb, 0, 0, off_x, off_y, size, size)

    local r  = size / 2
    local r2 = r * r
    for y = 0, size - 1 do
        local dy = (y - r) + 0.5
        local dy2 = dy * dy
        for x = 0, size - 1 do
            local dx = (x - r) + 0.5
            if dx * dx + dy2 > r2 then
                square:setPixel(x, y, Blitbuffer.COLOR_WHITE)
            end
        end
    end
    -- bb (le carré mis à l'échelle non recadré) n'est libéré qu'une fois le
    -- masquage terminé sans erreur : si le pcall appelant échoue en cours de
    -- route, bb reste valide pour le repli sur l'avatar carré d'origine.
    bb:free()
    return square
end

local function try_render(data, size)
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not data or #data < 64 then return nil end
    local ok_bb, native = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok_bb or not native then return nil end
    local nw, nh = native:getWidth(), native:getHeight()
    if nw <= 0 or nh <= 0 then native:free(); return nil end
    local scale = math.max(size / nw, size / nh)
    local dw = math.max(size, math.ceil(nw * scale))
    local dh = math.max(size, math.ceil(nh * scale))
    local scaled = native:scale(dw, dh)
    native:free()

    local ok_mask, rounded = pcall(mask_circle, scaled, size)
    if ok_mask and rounded then return rounded end
    return scaled
end

-- Disk cache only (no network) — safe to call synchronously while building
-- review rows. Returns nil if not cached yet (caller falls back to
-- initials).
function Avatars.getCached(url, size)
    if not url or url == "" then return nil end
    local data = DB.loadAvatarCache(url)
    if data and #data > MAX_AVATAR_BYTES then return nil end
    return try_render(data, size)
end

-- Downloads + disk-caches the raw bytes for a batch of URLs that aren't
-- already cached. Meant to be called once per page of reviews fetched, from
-- inside NetworkMgr:runWhenConnected (same place chapters/covers already do
-- their networking) — never from row rendering. Sequential and blocking,
-- like the rest of this codebase's network calls; fine for ~10 small
-- avatars per page, but it is extra latency added to every "Actualiser".
function Avatars.prefetch(urls)
    if not _pruned then
        _pruned = true
        pcall(DB.pruneAvatars, 150, MAX_AVATAR_BYTES)
    end
    local seen, todo = {}, {}
    for _, url in ipairs(urls) do
        if url and url ~= "" and not seen[url] and not _failed[url]
           and not DB.loadAvatarCache(url) then
            seen[url] = true
            todo[#todo + 1] = url
        end
    end
    if #todo == 0 then return end

    -- Tous les avatars en même temps (sous-processus) : ~1 latence réseau au lieu de N.
    local Parallel = require("core.parallel")
    if Parallel.available() then
        local jobs = {}
        for _, url in ipairs(todo) do
            jobs[#jobs + 1] = function()
                local data = Http.get(url, nil, 8, MAX_AVATAR_BYTES)
                if data and #data >= 64 then DB.saveAvatarCache(url, data) end
            end
        end
        if Parallel.runAndWait(jobs, 20) then
            for _, url in ipairs(todo) do
                if not DB.loadAvatarCache(url) then _failed[url] = true end
            end
            return
        end
    end

    for _, url in ipairs(todo) do
        local data = Http.get(url, nil, 8, MAX_AVATAR_BYTES)
        if data and #data >= 64 then
            DB.saveAvatarCache(url, data)
        else
            _failed[url] = true
        end
    end
end

return Avatars
