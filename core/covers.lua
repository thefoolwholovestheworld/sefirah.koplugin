-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- core/covers.lua — Shared cover fetch + disk-cache + decode + scale helper.
-- Used by ui/detail.lua, ui/library.lua and ui/browse.lua so cover handling
-- (disk cache, corrupt-data rejection, aspect-preserving scale) lives in
-- exactly one place instead of being duplicated per screen.
local DB   = require("core.db")
local Epub = require("core.epub")

local Covers = {}

-- Certains sites publient parfois un GIF ANIMÉ comme couverture
-- pour un roman — visuellement ~400×700px mais pesant 10-20 Mo une fois toutes
-- les frames d'animation incluses. Décoder ça avec RenderImage sur la mémoire
-- limitée d'une liseuse peut planter l'app entière (vu en pratique : un
-- Segmentation fault juste après le téléchargement d'une telle couverture).
-- On rejette donc toute donnée au-delà de ce seuil AVANT de tenter le décodage —
-- pas de couverture affichée pour ce roman, mais pas de crash non plus.
local MAX_COVER_BYTES = 2 * 1024 * 1024
Covers.MAX_COVER_BYTES = MAX_COVER_BYTES -- exposé pour ui/detail.lua (logique dupliquée)

-- Tries to decode `data` into a usable BlitBuffer; returns nil (freeing
-- nothing, since nothing was allocated) if the data is missing, too small,
-- too large, or fails to decode. Rejecting bad data here — instead of trusting
-- whatever happens to be on disk — lets a previously-corrupted cached cover
-- self-heal the next time it's requested with a cover_url.
local function try_render(data, fit_w, fit_h)
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not data or #data < 512 or #data > MAX_COVER_BYTES then return nil end
    -- fit_w/fit_h : le décodeur réduit l'image dès le décodage (moins de mémoire,
    -- beaucoup plus rapide sur liseuse). Ignorés par les versions de KOReader
    -- qui n'acceptent pas ces paramètres.
    local ok_bb, native = pcall(RenderImage.renderImageData, RenderImage, data, #data, false, fit_w, fit_h)
    if not ok_bb or not native then return nil end
    local nw, nh = native:getWidth(), native:getHeight()
    if nw <= 0 or nh <= 0 then native:free(); return nil end
    return native, nw, nh
end

-- Scales `native` (nw × nh) to fully COVER a max_w × max_h box — i.e. scale
-- so the *smaller* margin touches the edge, then center-crop the overflow —
-- instead of the old "contain" behaviour (scale so the *larger* margin fit
-- inside, leaving letterboxed blank space around off-ratio covers). This is
-- what makes every grid cell show a same-size cover regardless of the
-- source image's own aspect ratio.
-- Frees `native`; caller owns the returned buffer and must :free() it.
local function scale_to_cover(native, nw, nh, max_w, max_h)
    local scale = math.max(max_w / nw, max_h / nh)
    local dw = math.max(max_w, math.ceil(nw * scale))
    local dh = math.max(max_h, math.ceil(nh * scale))
    local scaled = native:scale(dw, dh)
    native:free()

    if dw == max_w and dh == max_h then
        return scaled
    end

    local ok_crop, cropped = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local target = Blitbuffer.new(max_w, max_h, scaled:getType())
        local off_x  = math.floor((dw - max_w) / 2)
        local off_y  = math.floor((dh - max_h) / 2)
        target:blitFrom(scaled, 0, 0, off_x, off_y, max_w, max_h)
        return target
    end)

    if ok_crop and cropped then
        scaled:free()
        return cropped
    end

    -- Cropping unsupported on this platform for some reason — fall back to
    -- the (still cover-filling, just not center-cropped) scaled buffer
    -- rather than losing the cover entirely.
    return scaled
end

-- Returns a BlitBuffer for (source_id, novel_path) scaled to fill
-- max_w × max_h exactly (cropped to that size, see scale_to_cover above),
-- or nil if no cover is cached and either no cover_url was given or the
-- fetch/decode failed.
-- Caller owns the returned buffer and must :free() it.
--
-- Pass cover_url = nil to check the disk cache only (no network) — use this
-- for fast synchronous grid renders; pass the real URL when you want a
-- cache-miss to trigger a fetch (e.g. from a prefetch step).
-- Mémoire LRU des couvertures déjà décodées + mises à l'échelle : revenir sur une
-- page, ou reconstruire la grille après le chargement des couvertures, ne redécode
-- plus les images. Le cache garde ses propres buffers ; l'appelant reçoit une copie
-- (il la libère comme avant).
local MEMO_MAX   = 18
local _memo      = {}
local _memo_keys = {}

local function memo_get(key)
    local bb = _memo[key]
    if not bb then return nil end
    for i, k in ipairs(_memo_keys) do
        if k == key then table.remove(_memo_keys, i); break end
    end
    table.insert(_memo_keys, key)
    local ok, copy = pcall(bb.copy, bb)
    if ok and copy then return copy end
    return nil
end

local function memo_put(key, bb)
    local ok, copy = pcall(bb.copy, bb)
    if not ok or not copy then return end
    if _memo[key] then pcall(_memo[key].free, _memo[key]) else table.insert(_memo_keys, key) end
    _memo[key] = copy
    while #_memo_keys > MEMO_MAX do
        local old = table.remove(_memo_keys, 1)
        if _memo[old] then pcall(_memo[old].free, _memo[old]); _memo[old] = nil end
    end
end

function Covers.get(source_id, novel_path, cover_url, site, max_w, max_h)
    if not source_id or not novel_path then return nil end

    local key = source_id .. "|" .. novel_path .. "|" .. tostring(max_w) .. "x" .. tostring(max_h)
    local cached = memo_get(key)
    if cached then return cached end

    local cdata = DB.loadCoverCache(source_id, novel_path)
    local native, nw, nh = try_render(cdata, max_w, max_h)

    if not native and cover_url and cover_url ~= "" then
        cdata = Epub.fetch_cover(cover_url, site)
        native, nw, nh = try_render(cdata, max_w, max_h)
        if native then
            -- Only overwrite the disk cache once we have a confirmed-good
            -- decode, so a transient network hiccup can't wipe out a
            -- previously-good cover.
            DB.saveCoverCache(source_id, novel_path, cdata)
        end
    end

    if not native then return nil end

    local out = scale_to_cover(native, nw, nh, max_w, max_h)
    if out then memo_put(key, out) end
    return out
end

-- Downloads and disk-caches the raw cover bytes only (no decode/scale) —
-- cheap way to "warm" the cache for a batch of novels before a grid render.
-- Returns true if the cover is cached on disk after this call (either it
-- already was, or the fetch just succeeded).
function Covers.prefetchRaw(source_id, novel_path, cover_url, site)
    if not source_id or not novel_path or not cover_url or cover_url == "" then
        return false
    end
    local existing = DB.loadCoverCache(source_id, novel_path)
    -- Couverture livrée avec le plugin (« local: ») : on réécrit toujours le cache
    -- (lecture disque, quasi gratuite) pour réparer un ancien fichier invalide.
    local is_local = tostring(cover_url):match("^local:") ~= nil
    if existing and #existing >= 512 and not is_local then return true end

    local data = Epub.fetch_cover(cover_url, site)
    -- Ne jamais mettre en cache disque une couverture au-delà du seuil : elle
    -- ne sera de toute façon jamais décodée par try_render (voir plus haut),
    -- autant ne pas la re-télécharger/re-tester à chaque prefetch.
    if data and #data >= 512 and #data <= MAX_COVER_BYTES then
        DB.saveCoverCache(source_id, novel_path, data)
        return true
    end
    return false
end

return Covers
