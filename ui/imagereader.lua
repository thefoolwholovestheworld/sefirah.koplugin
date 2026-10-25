-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- ui/imagereader.lua — Lecteur d'images intégré à Sefirah (manga).
-- Contrat, extraction des pages, affichage, changement de page, zoom et
-- déplacement, préchargement, menu et n° de page, chapitres suivant / précédent.
--
-- ══ CONTRAT ══════════════════════════════════════════════════════════════════
--   ImageReader.open{
--       cbz        = "/chemin/chapitre.cbz",   -- obligatoire
--       title      = "Vol. 3 Ch. 21",          -- optionnel
--       start_page = 1,                        -- optionnel
--       rtl        = true,                     -- true = lecture droite→gauche
--       has_prev   = true, has_next = true,    -- chapitres voisins disponibles ?
--       auto_next  = true,                     -- dernière page → chapitre suivant
--       on_close   = function(page, total, nav) end
--           nav = +1 (chapitre suivant demandé), -1 (précédent) ou nil
--   }  -> widget | nil, "raison"
--
--   Commandes
--     toucher le bord droit / gauche (35 %)   page suivante / précédente
--                                              (inversé en lecture manga)
--     glisser gauche / droite                  idem
--     croix « × » en haut à droite             fermer le lecteur
--     toucher le centre                        menu (zoom, page, chapitre, sens…)
--     pincer / écarter                         zoom − / +
--     appui long sur une case                  la case est agrandie au maximum
--     glisser (zoomé)                          déplacer la page
--     boutons de page, touche Retour           page suivante / précédente, fermer
--   Page suivante sur la dernière page : chapitre suivant (si auto_next) ou
--   fermeture ; dans les deux cas page == total, donc « lu ».
local UIManager       = require("ui/uimanager")
local Device          = require("device")
local Screen          = Device.screen
local Blitbuffer      = require("ffi/blitbuffer")
local Geom            = require("ui/geometry")
local DataStorage     = require("datastorage")
local InputContainer  = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local ImageWidget     = require("ui/widget/imagewidget")
local InfoMessage     = require("ui/widget/infomessage")
local GestureRange    = require("ui/gesturerange")
local Font            = require("ui/font")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local InputDialog     = require("ui/widget/inputdialog")
local RenderImage     = require("ui/renderimage")
local Settings        = require("sefirah_settings")
local logger          = require("logger")
local T               = require("core.i18n").T

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

-- Boîte de boutons : selon la version de KOReader.
local ok_bd, ButtonDialog = pcall(require, "ui/widget/buttondialogtitle")
if not ok_bd then ok_bd, ButtonDialog = pcall(require, "ui/widget/buttondialog") end

local ImageReader = {}

local ZOOM_LEVELS = { 1, 1.5, 2, 3 }

local REFRESH_EVERY = 6   -- un rafraîchissement complet (flash) toutes les N pages

-- ── Fichiers ─────────────────────────────────────────────────────────────────
local function mkdirs(path)
    local cur = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        cur = cur .. part
        if lfs.attributes(cur, "mode") ~= "directory" then lfs.mkdir(cur) end
        cur = cur .. "/"
    end
    return lfs.attributes(path, "mode") == "directory"
end

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

local IMAGE_EXT = { jpg = true, jpeg = true, png = true, webp = true, gif = true }

local function is_image(name)
    local e = name:match("%.(%w+)$")
    return e ~= nil and IMAGE_EXT[e:lower()] == true
end

-- Tri « naturel » : page2 avant page10.
local function natural_key(s)
    return (s:lower():gsub("%d+", function(d) return string.format("%012d", tonumber(d) or 0) end))
end

-- Images d'un dossier, dans l'ordre de lecture.
local function list_images(dir)
    local files = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return files end
    for f in lfs.dir(dir) do
        if f ~= "." and f ~= ".." and is_image(f) and not f:match("^0000_cover") then files[#files + 1] = f end
    end
    table.sort(files, function(a, b) return natural_key(a) < natural_key(b) end)
    for i, f in ipairs(files) do files[i] = dir .. "/" .. f end
    return files
end

-- ── Extraction du CBZ ────────────────────────────────────────────────────────
local function cache_root()
    return DataStorage:getFullDataDir() .. "/cache/sefirah_pages"
end

local function extract_cbz(cbz, dest)
    -- 1) archiveur natif de KOReader
    local ok_a, Archiver = pcall(require, "ffi/archiver")
    if ok_a and Archiver and Archiver.Reader then
        local ok, err = pcall(function()
            local r = Archiver.Reader:new()
            if not r:open(cbz) then error("open_failed") end
            for entry in r:iterate() do
                if entry.mode == "file" then
                    local name = entry.path:match("([^/\\]+)$")
                    if name and is_image(name) then
                        r:extractToPath(entry.path, dest .. "/" .. name)
                    end
                end
            end
            r:close()
        end)
        if not ok then logger.warn("Sefirah/ImageReader: archiveur natif en échec", tostring(err)) end
        if #list_images(dest) > 0 then return true end
    end
    -- 2) repli : binaire unzip présent sur la liseuse
    logger.warn("Sefirah/ImageReader: repli sur unzip")
    os.execute(string.format('unzip -o -q "%s" -d "%s" 2>/dev/null', cbz, dest))
    return #list_images(dest) > 0
end

-- ── Décodage ─────────────────────────────────────────────────────────────────
local function load_bb(path)
    local ok, bb = pcall(function() return RenderImage:renderImageFile(path, false) end)
    if ok and bb then return bb end
    logger.warn("Sefirah/ImageReader: image illisible", path, ok and "" or tostring(bb))
    return nil
end

-- Extrait un CBZ dans un dossier temporaire : renvoie (files, dest) ou (nil, erreur).
local function prepare_cbz(cbz)
    if type(cbz) ~= "string" or lfs.attributes(cbz, "mode") ~= "file" then
        return nil, "cbz_missing"
    end
    local base = (cbz:match("([^/]+)$") or "chapitre"):gsub("%.cbz$", ""):gsub("[^%w]", "_"):sub(1, 40)
    local size = lfs.attributes(cbz, "size") or 0
    local dest = string.format("%s/%s_%d", cache_root(), base, size)
    rm_rf(dest)
    if not mkdirs(dest) then return nil, "mkdir_failed" end
    local files = extract_cbz(cbz, dest) and list_images(dest) or {}
    if #files == 0 then
        rm_rf(dest)
        UIManager:show(InfoMessage:new{ text = T("Impossible de lire les pages de ce chapitre."), timeout = 4 })
        return nil, "no_pages"
    end
    return files, dest
end

-- ── Taille d'une image sans la décoder (en-têtes PNG / JPEG / WebP) ──────────
local function image_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(32) or ""
    local w, h
    if head:sub(1, 8) == "\137PNG\r\n\26\n" then
        local a, b, c, d, e, g, i, j = head:byte(17, 24)
        if j then w = ((a * 256 + b) * 256 + c) * 256 + d; h = ((e * 256 + g) * 256 + i) * 256 + j end
    elseif head:sub(1, 2) == "\255\216" then
        f:seek("set", 2)
        while true do
            local b = f:read(1)
            if not b then break end
            if b == "\255" then
                local m = f:read(1)
                if not m then break end
                local mb = m:byte()
                if mb == 0xFF then f:seek("cur", -1)
                elseif mb == 0xD8 or mb == 0x01 or (mb >= 0xD0 and mb <= 0xD7) then -- sans longueur
                else
                    local l = f:read(2)
                    if not l or #l < 2 then break end
                    local len = l:byte(1) * 256 + l:byte(2)
                    if (mb >= 0xC0 and mb <= 0xCF) and mb ~= 0xC4 and mb ~= 0xC8 and mb ~= 0xCC then
                        local d = f:read(5)
                        if d and #d == 5 then
                            h = d:byte(2) * 256 + d:byte(3)
                            w = d:byte(4) * 256 + d:byte(5)
                        end
                        break
                    end
                    f:seek("cur", len - 2)
                end
            end
        end
    elseif head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
        local kind = head:sub(13, 16)
        if kind == "VP8X" then
            local a, b, c, d, e, g = head:byte(25, 30)
            if g then w = a + b * 256 + c * 65536 + 1; h = d + e * 256 + g * 65536 + 1 end
        elseif kind == "VP8L" then
            local b1, b2, b3, b4 = head:byte(22, 25)
            if b4 then
                local bits = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
                w = (bits % 16384) + 1
                h = (math.floor(bits / 16384) % 16384) + 1
            end
        elseif kind == "VP8 " then
            local a, b, c, d = head:byte(27, 30)
            if d then w = (a + b * 256) % 16384; h = (c + d * 256) % 16384 end
        end
    end
    f:close()
    if w and h and w > 0 and h > 0 then return w, h end
    return nil
end

-- ── Découpage des pages hautes (webtoons / manhwa) ───────────────────────────
-- Une image plus haute qu'un écran et demi (à pleine largeur) est coupée en
-- tranches : chaque tranche = une « page » qui remplit la largeur de l'écran.
-- Le nombre de tranches est connu d'avance (en-têtes) ; les coupes sont ajustées
-- plus tard sur une bande vide (gouttière) entre deux cases, à ±5 % d'écran.
local SNAP = 0.05

local function build_units(files, sw, sh, slice)
    local units = {}
    for i, f in ipairs(files) do
        local w, h = image_size(f)
        local n = 1
        if false then
            local vh = sh * w / sw                    -- hauteur d'image visible à pleine largeur
        end
        for k = 1, n do units[#units + 1] = { i = i, k = k, n = n, w = w, h = h } end
    end
    return units
end

-- Ligne « vide » : peu de variation de gris sur quelques colonnes.
local function row_is_blank(bb, y, iw)
    local lo, hi = 255, 0
    local cols = 24
    for c = 0, cols - 1 do
        local x = math.floor((c + 0.5) * iw / cols)
        local px = bb:getPixel(x, y)
        local g = px:getColor8().a
        if g < lo then lo = g end
        if g > hi then hi = g end
        if hi - lo > 14 then return false end
    end
    return true
end

-- Coupes (y de chaque frontière, 0 … ih) d'une image découpée en n tranches.
local function compute_cuts(bb, n, sw, sh)
    local iw, ih = bb:getWidth(), bb:getHeight()
    local vh = sh * iw / sw
    local cuts = { 0 }
    local L = ih / n
    for k = 1, n - 1 do
        local ideal = math.floor(k * L)
        local best = ideal
        local ok = pcall(function()
            local span = math.floor(vh * SNAP)
            local lo, hi = math.max(cuts[#cuts] + 1, ideal - span), math.min(ih - 2, ideal + span)
            local run_start, best_len, best_mid
            local y = lo
            while y <= hi + 2 do
                local blank = y <= hi and row_is_blank(bb, y, iw)
                if blank then
                    run_start = run_start or y
                elseif run_start then
                    local len = y - run_start
                    local mid = math.floor((run_start + y - 1) / 2)
                    if len >= 3 and (not best_len or len > best_len
                        or (len == best_len and math.abs(mid - ideal) < math.abs(best_mid - ideal))) then
                        best_len, best_mid = len, mid
                    end
                    run_start = nil
                end
                y = y + 2
            end
            if best_mid then best = best_mid end
        end)
        if not ok then best = ideal end
        cuts[#cuts + 1] = best
    end
    cuts[#cuts + 1] = ih
    return cuts
end

-- ── Détection d'une case (appui long) ────────────────────────────────────────
-- Découpage récursif par gouttières : on cherche les lignes / colonnes
-- entièrement « fond » (blanches, ou noires sur une page sombre) qui séparent
-- les cases, et on descend jusqu'à celle qui contient le point appuyé.
-- getlum(x, y) -> 0..255 ; zone (rx, ry, rw, rh) et point (px, py) en pixels
-- d'origine. Renvoie x0, y0, x1, y1 (x1 / y1 exclus) ou nil.
local function find_panel(getlum, rx, ry, rw, rh, px, py)
    local step = math.max(2, math.floor(math.max(rw, rh) / 400))
    local gw, gh = math.floor(rw / step), math.floor(rh / step)
    if gw < 8 or gh < 8 then return nil end
    local half = math.floor(step / 2)

    local lum, sum, cnt = {}, 0, 0
    for gy = 1, gh do
        local row = {}
        local y = ry + (gy - 1) * step + half
        for gx = 1, gw do
            local v = getlum(rx + (gx - 1) * step + half, y)
            row[gx] = v
            if gy == 1 or gy == gh or gx == 1 or gx == gw then sum = sum + v; cnt = cnt + 1 end
        end
        lum[gy] = row
    end
    local light = (sum / cnt) >= 128          -- fond clair (cas normal) ou sombre
    local ink = {}                            -- ink[gy][gx] : cette cellule n'est pas du fond
    for gy = 1, gh do
        local row, src = {}, lum[gy]
        for gx = 1, gw do
            local v = src[gx]
            row[gx] = light and (v < 215) or ((not light) and v > 40)
        end
        ink[gy] = row
    end

    local function row_is_bg(gy, a, b)
        local n, row = 0, ink[gy]
        for gx = a, b do if row[gx] then n = n + 1 end end
        return n <= math.floor((b - a + 1) * 0.012)
    end
    local function col_is_bg(gx, a, b)
        local n = 0
        for gy = a, b do if ink[gy][gx] then n = n + 1 end end
        return n <= math.floor((b - a + 1) * 0.012)
    end
    -- Plages de lignes « contenu », séparées par au moins min_gap lignes « fond ».
    local function runs(lo, hi, is_bg, min_gap)
        local out, i = {}, lo
        while i <= hi do
            if is_bg(i) then
                i = i + 1
            else
                local last, gap, j = i, 0, i
                while j <= hi do
                    if is_bg(j) then
                        gap = gap + 1
                        if gap >= min_gap then break end
                    else
                        gap, last = 0, j
                    end
                    j = j + 1
                end
                out[#out + 1] = { i, last }
                i = last + 1
            end
        end
        return out
    end
    local function pick(list, p)
        local best, bd
        for _, r in ipairs(list) do
            if p >= r[1] and p <= r[2] then return r[1], r[2] end
            local d = math.min(math.abs(p - r[1]), math.abs(p - r[2]))
            if not bd or d < bd then best, bd = r, d end
        end
        return best[1], best[2]
    end
    local function gap_cells(n_cells)
        return math.max(2, math.ceil(math.max(5, 0.008 * n_cells * step) / step))
    end

    local gpx = math.max(1, math.min(gw, math.floor((px - rx) / step) + 1))
    local gpy = math.max(1, math.min(gh, math.floor((py - ry) / step) + 1))
    local x0, y0, x1, y1 = 1, 1, gw, gh
    for _ = 1, 16 do
        local ox0, oy0, ox1, oy1 = x0, y0, x1, y1
        local sy = runs(y0, y1, function(gy) return row_is_bg(gy, x0, x1) end, gap_cells(y1 - y0 + 1))
        if #sy == 0 then return nil end
        y0, y1 = pick(sy, gpy)
        local sx = runs(x0, x1, function(gx) return col_is_bg(gx, y0, y1) end, gap_cells(x1 - x0 + 1))
        if #sx == 0 then return nil end
        x0, x1 = pick(sx, gpx)
        if x0 == ox0 and y0 == oy0 and x1 == ox1 and y1 == oy1 then break end
    end
    local X0, Y0 = rx + (x0 - 1) * step, ry + (y0 - 1) * step
    local X1, Y1 = rx + x1 * step, ry + y1 * step

    -- Affinage au pixel près : on rentre tant que la ligne / colonne de bord est
    -- du fond, puis on ressort d'un cran pour garder le trait de cadre.
    local function ink_px(v) if light then return v < 215 end; return v > 40 end
    local function row_ink(y, xa, xb)
        local n, tot = 0, 0
        for x = xa, xb - 1, 2 do
            tot = tot + 1
            if ink_px(getlum(x, y)) then n = n + 1 end
        end
        return n > math.floor(tot * 0.012)
    end
    local function col_ink(x, ya, yb)
        local n, tot = 0, 0
        for y = ya, yb - 1, 2 do
            tot = tot + 1
            if ink_px(getlum(x, y)) then n = n + 1 end
        end
        return n > math.floor(tot * 0.012)
    end
    local maxin = step * 3
    local function clampx(x) return math.max(rx, math.min(rx + rw - 1, x)) end
    local function clampy(y) return math.max(ry, math.min(ry + rh - 1, y)) end
    local k = 0
    while k < maxin and Y0 < Y1 - 8 and not row_ink(clampy(Y0), X0, X1) do Y0 = Y0 + 1; k = k + 1 end
    k = 0
    while k < maxin and Y1 > Y0 + 8 and not row_ink(clampy(Y1 - 1), X0, X1) do Y1 = Y1 - 1; k = k + 1 end
    k = 0
    while k < maxin and X0 < X1 - 8 and not col_ink(clampx(X0), Y0, Y1) do X0 = X0 + 1; k = k + 1 end
    k = 0
    while k < maxin and X1 > X0 + 8 and not col_ink(clampx(X1 - 1), Y0, Y1) do X1 = X1 - 1; k = k + 1 end
    return X0, Y0, X1, Y1
end

-- Blanchit tout ce qui est hors du rectangle (l, t, r, b) (coordonnées de la vue) :
-- les cases voisines ne doivent pas apparaître autour de la case agrandie.
local function mask_outside(view, vw, vh, l, t, r, b)
    local W = Blitbuffer.COLOR_WHITE
    l, t = math.max(0, math.floor(l + 0.5)), math.max(0, math.floor(t + 0.5))
    r, b = math.min(vw, math.ceil(r)), math.min(vh, math.ceil(b))
    if r <= l or b <= t then view:paintRect(0, 0, vw, vh, W); return end
    if t > 0 then view:paintRect(0, 0, vw, t, W) end
    if b < vh then view:paintRect(0, b, vw, vh - b, W) end
    if l > 0 then view:paintRect(0, t, l, b - t, W) end
    if r < vw then view:paintRect(r, t, vw - r, b - t, W) end
end

-- ── Widget ───────────────────────────────────────────────────────────────────
local Reader = InputContainer:extend{
    name = "sefirah_image_reader",
    covers_fullscreen = true,
}

function Reader:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self._enter = "top"
    self:_makeUnits()
    self.page = math.max(1, math.min(tonumber(self.start_page) or 1, #self.units))
    self._turns = 0
    self._cache = {}          -- n° de fichier -> BlitBuffer (false = illisible)
    self._cuts = {}           -- n° de fichier -> coupes des tranches
    self._sc = {}             -- n° de page -> page mise à l'échelle (tranches)
    self.zoom, self.cx, self.cy = 1, 0, 0
    self._preload = function()
        if self._gone or self._busy then return end
        local u = self.units[self.page + 1]
        if u then
            pcall(function()
                if u.n > 1 then self:_sliceView(self.page + 1) else self:_get(u.i) end
            end)
        end
    end

    if Device:hasKeys() then
        local g = Device.input and Device.input.group or {}
        self.key_events = {
            Close    = { { "Back" } },
            PageNext = { g.PgFwd or { "RPgFwd", "LPgFwd" } },
            PagePrev = { g.PgBack or { "RPgBack", "LPgBack" } },
        }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapPage    = { GestureRange:new{ ges = "tap",    range = self.dimen } },
            SwipePage  = { GestureRange:new{ ges = "swipe",  range = self.dimen } },
            SpreadPage = { GestureRange:new{ ges = "spread", range = self.dimen } },
            PinchPage  = { GestureRange:new{ ges = "pinch",  range = self.dimen } },
            HoldPage   = { GestureRange:new{ ges = "hold",   range = self.dimen } },
        }
    end
    self:_render()
end

function Reader:_makeUnits()
    local slice = Settings:get("manga_slice") ~= false
    self.units = build_units(self.files, self.dimen.w, self.dimen.h, slice)
end

-- Image décodée (en cache : la page courante et ses voisines).
function Reader:_get(i)
    local c = self._cache[i]
    if c == nil then
        c = load_bb(self.files[i]) or false
        -- Double page (nettement plus large que haute) sur un écran en portrait :
        -- on tourne l'image de 90° pour qu'elle remplisse l'écran (réglage
        -- « manga_rotate_spread »). Tout le reste (zoom, coupes) travaille ensuite
        -- sur l'image déjà tournée.
        local rot = Settings:get("manga_rotate_spread") or "off"
        if c and rot ~= "off" and self.dimen.w < self.dimen.h
           and c:getWidth() >= c:getHeight() * 1.1 then
            local ok, rb = pcall(function()
                return c:rotatedCopy(rot == "ccw" and 270 or 90)
            end)
            if ok and rb then
                if c.free then pcall(c.free, c) end
                c = rb
                self._rot = self._rot or {}
                self._rot[i] = true
            end
        end
        self._cache[i] = c
    end
    return c or nil
end

-- Change le réglage des doubles pages (OFF → 90° droite → 90° gauche) et
-- redessine : le cache d'images est vidé car il contient les pages déjà tournées.
local ROT_NEXT = { off = "cw", cw = "ccw", ccw = "off" }
function Reader:cycleSpread()
    Settings:set("manga_rotate_spread", ROT_NEXT[Settings:get("manga_rotate_spread") or "off"] or "off")
    for k, bb in pairs(self._cache) do
        if bb and bb.free then pcall(bb.free, bb) end
        self._cache[k] = nil
    end
    self._cuts, self._rot = {}, {}
    self:_freeScaled()
    self.zoom = 1
    self._enter = "top"
    self:_render()
end

function Reader:_freeScaled()
    for k, bb in pairs(self._sc) do
        if bb and bb.free then bb:free() end
        self._sc[k] = nil
    end
    if self._zb then
        if self._zb.bb then self._zb.bb:free() end
        self._zb = nil
    end
end

-- Libère ce qui est à plus d'une page de la page courante.
function Reader:_trim()
    local cur = self.units[self.page]
    local ci = cur and cur.i or 1
    for i, bb in pairs(self._cache) do
        if math.abs(i - ci) > 1 then
            if bb then bb:free() end
            self._cache[i] = nil
            self._cuts[i] = nil
        end
    end
    for k, bb in pairs(self._sc) do
        if math.abs(k - self.page) > 1 then
            if bb and bb.free then bb:free() end
            self._sc[k] = nil
        end
    end
end

-- Zone de l'image affichée par la page n : (x, y, largeur, hauteur) en pixels d'origine.
function Reader:_region(n, bb)
    local u = self.units[n]
    local iw, ih = bb:getWidth(), bb:getHeight()
    if not u or u.n <= 1 then return 0, 0, iw, ih end
    local cuts = self._cuts[u.i]
    if not cuts or #cuts ~= u.n + 1 then
        cuts = compute_cuts(bb, u.n, self.dimen.w, self.dimen.h)
        self._cuts[u.i] = cuts
    end
    local y0, y1 = cuts[u.k], cuts[u.k + 1]
    return 0, y0, iw, math.max(1, y1 - y0)
end

-- Tranche mise à l'échelle de l'écran (en cache : plus de calcul au défilement).
function Reader:_sliceView(n)
    local c = self._sc[n]
    if c then return c end
    local u = self.units[n]
    local bb = u and self:_get(u.i)
    if not bb then return nil end
    local rx, ry, rw, rh = self:_region(n, bb)
    local sw, sh = self.dimen.w, self.dimen.h
    local s = math.min(sw / rw, sh / rh)
    local tw, th = math.max(1, math.floor(rw * s + 0.5)), math.max(1, math.floor(rh * s + 0.5))
    local crop = Blitbuffer.new(rw, rh, bb:getType())
    crop:blitFrom(bb, 0, 0, rx, ry, rw, rh)
    c = RenderImage:scaleBlitBuffer(crop, tw, th, true)
    self._sc[n] = c
    return c
end

-- Page zoomée : la zone est mise à l'échelle UNE fois, puis on ne fait que
-- découper la partie visible (le défilement n'a plus de recalcul).
function Reader:_zoomBase(bb, rx, ry, rw, rh, s)
    local z = self._zb
    if z and z.page == self.page and math.abs(z.s - s) < 1e-6 then return z end
    if z and z.bb then z.bb:free() end
    self._zb = nil
    if not bb then return nil end
    local tw, th = math.max(1, math.floor(rw * s + 0.5)), math.max(1, math.floor(rh * s + 0.5))
    local ctype = bb:getType()
    local bpp = 4
    pcall(function() bpp = math.max(1, math.floor(bb:getBpp() / 8)) end)
    -- Liseuse sans couleur : travailler en niveaux de gris (4× moins de mémoire).
    local color = false
    pcall(function() color = Screen.isColorEnabled and Screen:isColorEnabled() or false end)
    if not color and bpp > 1 then ctype = Blitbuffer.TYPE_BB8; bpp = 1 end
    local LIMIT = 24 * 1024 * 1024
    if tw * th * bpp > LIMIT then
        if bpp > 1 and tw * th <= LIMIT then
            ctype = Blitbuffer.TYPE_BB8; bpp = 1
        else
            return nil
        end
    end
    local src, free_src = bb, false
    if not (rx == 0 and ry == 0 and rw == bb:getWidth() and rh == bb:getHeight() and ctype == bb:getType()) then
        src = Blitbuffer.new(rw, rh, ctype)
        src:blitFrom(bb, 0, 0, rx, ry, rw, rh)
        free_src = true
    end
    local scaled = RenderImage:scaleBlitBuffer(src, tw, th, free_src)
    self._zb = { page = self.page, s = s, bb = scaled, w = tw, h = th, rx = rx, ry = ry, rw = rw, rh = rh }
    -- Page haute : l'original décodé ne sert plus (le défilement utilise la version à l'échelle).
    local u = self.units[self.page]
    if self._tall and u and self._cache[u.i] == bb then
        bb:free()
        self._cache[u.i] = nil
    end
    return self._zb
end

function Reader:_buildView()
    local sw, sh = self.dimen.w, self.dimen.h
    local u = self.units[self.page]
    local bb, rx, ry, rw, rh
    local z0 = self._zb
    if z0 and z0.page == self.page and self.zoom > 1.001 and z0.rw
       and math.abs(z0.s - math.min(sw / z0.rw, sh / z0.rh) * self.zoom) < 1e-6 then
        -- Défilement : la page est déjà prête (l'original décodé a été libéré).
        rx, ry, rw, rh = z0.rx, z0.ry, z0.rw, z0.rh
    else
        bb = u and self:_get(u.i)
        if not bb then
            return CenterContainer:new{
                dimen = self.dimen,
                TextWidget:new{ text = T("Page illisible"), face = Font:getFace("cfont", 22) },
            }
        end
        rx, ry, rw, rh = self:_region(self.page, bb)
    end
    local s0 = math.min(sw / rw, sh / rh)           -- échelle « zone entière »
    self._s0, self._iw, self._ih = s0, rw, rh
    self._rx, self._ry = rx, ry
    -- Page haute (webtoon) : ouverte directement à pleine largeur, on la fait défiler.
    local mode = Settings:get("manga_mode") or "auto"
    local ratio = (rh * sw / rw) / sh               -- hauteur à pleine largeur / hauteur d'écran
    self._tall = (mode == "manhwa" and ratio > 1.02) or (mode == "auto" and ratio > 1.5)
    if self._rot and self._rot[u.i] then self._tall = false end   -- double page tournée : page entière
    if self._tall and self._enter then
        self.zoom = math.max(1, (sw / rw) / s0)
        self.cx = rx + rw / 2
        self.cy = (self._enter == "bottom") and (ry + rh) or ry
    end
    self._enter = nil

    local img
    if self.zoom <= 1.001 then
        if u.n > 1 then
            local sc = self:_sliceView(self.page)
            img = ImageWidget:new{
                image = sc, image_disposable = false,    -- le cache garde la tranche
                width = sc:getWidth(), height = sc:getHeight(), scale_factor = 0, alpha = false,
            }
        else
            img = ImageWidget:new{
                image = bb, image_disposable = false,    -- le cache garde la page
                width = sw, height = sh, scale_factor = 0, alpha = false,
            }
        end
    else
        local s = s0 * self.zoom
        local zb = self:_zoomBase(bb, rx, ry, rw, rh, s)
        if zb then
            local vw, vh = math.min(sw, zb.w), math.min(sh, zb.h)
            local px = (self.cx - rx) * s
            local py = (self.cy - ry) * s
            local x0 = math.max(0, math.min(zb.w - vw, math.floor(px - vw / 2 + 0.5)))
            local y0 = math.max(0, math.min(zb.h - vh, math.floor(py - vh / 2 + 0.5)))
            self.cx, self.cy = rx + (x0 + vw / 2) / s, ry + (y0 + vh / 2) / s
            self._atTop, self._atBottom = y0 <= 0, y0 + vh >= zb.h - 1
            local view = Blitbuffer.new(vw, vh, zb.bb:getType())
            view:blitFrom(zb.bb, 0, 0, x0, y0, vw, vh)
            local P = self._panel
            if P then
                mask_outside(view, vw, vh, (P[1] - rx) * s - x0, (P[2] - ry) * s - y0,
                    (P[3] - rx) * s - x0, (P[4] - ry) * s - y0)
            end
            img = ImageWidget:new{
                image = view, image_disposable = true,
                width = vw, height = vh, scale_factor = 0, alpha = false,
            }
        else
            -- Image trop grande pour être mise à l'échelle d'un coup : ancien calcul.
            local vw = math.min(rw, math.floor(sw / s + 0.5))
            local vh = math.min(rh, math.floor(sh / s + 0.5))
            local x0 = math.max(rx, math.min(rx + rw - vw, math.floor(self.cx - vw / 2 + 0.5)))
            local y0 = math.max(ry, math.min(ry + rh - vh, math.floor(self.cy - vh / 2 + 0.5)))
            self.cx, self.cy = x0 + vw / 2, y0 + vh / 2
            self._atTop, self._atBottom = y0 <= ry, y0 + vh >= ry + rh - 1
            local crop = Blitbuffer.new(vw, vh, bb:getType())
            crop:blitFrom(bb, 0, 0, x0, y0, vw, vh)
            local tw = math.min(sw, math.max(1, math.floor(vw * s + 0.5)))
            local th = math.min(sh, math.max(1, math.floor(vh * s + 0.5)))
            local scaled = RenderImage:scaleBlitBuffer(crop, tw, th, true)
            local P = self._panel
            if P then
                mask_outside(scaled, tw, th, (P[1] - x0) * s, (P[2] - y0) * s,
                    (P[3] - x0) * s, (P[4] - y0) * s)
            end
            img = ImageWidget:new{
                image = scaled, image_disposable = true,
                width = tw, height = th, scale_factor = 0, alpha = false,
            }
        end
    end
    self._img = img
    return CenterContainer:new{ dimen = self.dimen, img }
end

-- Petit « 12 / 34 » en bas de page (réglage « manga_pageinfo »).
function Reader:_footer()
    if not Settings:get("manga_pageinfo") then return nil end
    local ok, w = pcall(function()
        return BottomContainer:new{
            dimen = self.dimen,
            FrameContainer:new{
                bordersize = 0, padding = 2, margin = 0,
                background = Blitbuffer.COLOR_WHITE,
                TextWidget:new{
                    text = string.format("%d / %d", self.page, #self.units),
                    face = Font:getFace("cfont", 14),
                },
            },
        }
    end)
    return ok and w or nil
end

-- Bouton « Page entière » (en haut à gauche, visible seulement quand on est zoomé).
function Reader:_pageButton()
    local ok, btn = pcall(function()
        local Button = require("ui/widget/button")
        local b = Button:new{
            text = T("Page entière"), text_font_size = 20,
            bordersize = Screen:scaleBySize(1), margin = 0, padding = Screen:scaleBySize(4), radius = 0,
            callback = function() self:setZoom(1) end,
            show_parent = self,
        }
        local m = Screen:scaleBySize(6)
        b.overlap_offset = { m, m }
        return b
    end)
    if not ok then logger.warn("Sefirah/ImageReader: bouton page entière indisponible", tostring(btn)) end
    return ok and btn or nil
end

-- Croix « × » en haut à droite : ferme le lecteur.
function Reader:_closeButton()
    local ok, btn = pcall(function()
        local Button = require("ui/widget/button")
        local b = Button:new{
            text = "×", text_font_size = 30,
            bordersize = 0, margin = 0, padding = Screen:scaleBySize(2), radius = 0,
            width = Screen:scaleBySize(44),
            callback = function() self:close() end,
            show_parent = self,
        }
        local sz = b:getSize()
        local m = Screen:scaleBySize(6)
        b.overlap_offset = { self.dimen.w - sz.w - m, m }
        return b
    end)
    if not ok then logger.warn("Sefirah/ImageReader: croix indisponible", tostring(btn)) end
    return ok and btn or nil
end

function Reader:_render(partial_only, fast)
    if self._img then self._img:free(); self._img = nil end
    local frame = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self:_buildView(),
    }
    local layers = { dimen = self.dimen, frame }
    local footer = self:_footer()
    if footer then layers[#layers + 1] = footer end
    if self._cross == nil then self._cross = self:_closeButton() or false end
    if self._cross then layers[#layers + 1] = self._cross end
    if self.zoom > 1.001 then
        if self._pagebtn == nil then self._pagebtn = self:_pageButton() or false end
        if self._pagebtn then layers[#layers + 1] = self._pagebtn end
    end
    self[1] = OverlapGroup:new(layers)
    self:_trim()
    local full = (not partial_only) and self._turns > 0 and self._turns % REFRESH_EVERY == 0
    local mode = full and "full" or "partial"
    if fast then
        -- Défilement : rafraîchissement « partial » (le mode « fast » laissait des traînées),
        -- et un rafraîchissement complet tous les 12 défilements pour nettoyer l'écran.
        self._pans = (self._pans or 0) + 1
        if self._pans % 12 == 0 then mode = "full" end
    end
    UIManager:setDirty(self, mode)
    -- Précharge la page suivante pendant que tu lis celle-ci.
    UIManager:unschedule(self._preload)
    UIManager:scheduleIn(0.4, self._preload)
end

function Reader:gotoPage(n, from_end)
    if n < 1 then return end
    self._enter = from_end and "bottom" or "top"
    if n > #self.units then
        if self.has_next and self.auto_next then return self:requestChapter(1) end
        return self:close()
    end
    self.page = n
    self.zoom = 1
    self._panel = nil
    if self._zb then
        if self._zb.bb then self._zb.bb:free() end
        self._zb = nil
    end
    self._turns = self._turns + 1
    self:_render()
    if self.on_page then pcall(self.on_page, self.page, #self.units) end
end

-- dir = +1 : page suivante ; -1 : page précédente.
function Reader:step(dir)
    -- Page haute : on fait défiler d'un écran (90 %) avant de changer de page.
    if self._tall and self.zoom > 1.001 and self._s0 then
        local s = self._s0 * self.zoom
        if dir > 0 and not self._atBottom then return self:pan(0, self.dimen.h * 0.9) end
        if dir < 0 and not self._atTop then return self:pan(0, -self.dimen.h * 0.9) end
    end
    self:gotoPage(self.page + dir, dir < 0)
end

-- ── Zoom et déplacement ──────────────────────────────────────────────────────
function Reader:setZoom(z, top)
    if z > 1.001 and self.zoom <= 1.001 then
        self.cx = (self._rx or 0) + (self._iw or 0) / 2
        self.cy = (self._ry or 0) + (self._ih or 0) / 2
    end
    if z > 1.001 and top then self.cy = self._ry or 0 end
    self.zoom = z
    self._panel = nil
    self:_render(true)
end

function Reader:zoomBy(dir)
    local z, target = self.zoom, nil
    if dir > 0 then
        for _, l in ipairs(ZOOM_LEVELS) do
            if l > z + 0.01 then target = l; break end
        end
    else
        for i = #ZOOM_LEVELS, 1, -1 do
            if ZOOM_LEVELS[i] < z - 0.01 then target = ZOOM_LEVELS[i]; break end
        end
    end
    if target then self:setZoom(target) end
end

-- Page remplissant la largeur de l'écran, calée en haut (pages doubles, webtoons).
function Reader:fitWidth()
    if not self._s0 or not self._iw then return end
    local z = (self.dimen.w / self._iw) / self._s0
    self:setZoom(math.max(1, z), true)
end

function Reader:pan(dx, dy)
    if self.zoom <= 1.001 or not self._s0 then return end
    local s = self._s0 * self.zoom
    self.cx = self.cx + dx / s
    self.cy = self.cy + dy / s
    self:_render(true, true)
end

-- ── Menu, page, infos ────────────────────────────────────────────────────────
function Reader:showInfo()
    local label = string.format(T("Page %d / %d"), self.page, #self.units)
    if self.title and self.title ~= "" then label = self.title .. "\n" .. label end
    UIManager:show(InfoMessage:new{ text = label, timeout = 1.5 })
end

-- Écran d'attente DANS le lecteur : le lecteur ne se ferme jamais pendant un
-- changement de chapitre, donc on ne voit plus le gestionnaire de fichiers.
function Reader:_showBusy()
    local txt = T("Chargement du chapitre…") .. "\n\n" .. T("(touche l'écran pour annuler)")
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = self.dimen,
            TextBoxWidget:new{ text = txt, face = Font:getFace("cfont", 22),
                               width = math.floor(self.dimen.w * 0.8), alignment = "center" },
        },
    }
    UIManager:setDirty(self, "ui")
end

function Reader:beginBusy()
    self._nav_token = (self._nav_token or 0) + 1
    self._busy = true
    self:_showBusy()
    return self._nav_token
end

-- Revient à la page affichée avant la demande (échec / annulation).
function Reader:restore(msg)
    if self._gone then return end
    self._nav_token = (self._nav_token or 0) + 1
    self._busy = false
    self._on_busy_cancel = nil
    self:_render(true)
    if msg then UIManager:show(InfoMessage:new{ text = msg, timeout = 4 }) end
end

function Reader:cancelBusy()
    local cb = self._on_busy_cancel
    self._on_busy_cancel = nil
    if cb then pcall(cb) end
    self:restore()
end

-- Remplace le chapitre affiché par un autre CBZ, sans fermer le lecteur.
function Reader:swap(opts)
    local files, dest = prepare_cbz(opts.cbz)
    if not files then return nil, dest end
    for _, bb in pairs(self._cache) do
        if bb then bb:free() end
    end
    self._cache, self._cuts, self._rot = {}, {}, {}
    self:_freeScaled()
    if self.dest and self.dest ~= dest then rm_rf(self.dest) end
    self.files, self.dest, self.title = files, dest, opts.title
    self:_makeUnits()
    self.rtl = opts.rtl and true or false
    self.has_prev, self.has_next, self.auto_next = opts.has_prev, opts.has_next, opts.auto_next
    self.on_close, self.on_nav, self.on_page = opts.on_close, opts.on_nav, opts.on_page
    self._closed, self._nav, self._on_busy_cancel = false, nil, nil
    self._busy = false
    self._nav_token = (self._nav_token or 0) + 1
    self.page = math.max(1, math.min(tonumber(opts.start_page) or 1, #self.units))
    self.zoom = 1
    self._turns = 0
    self._enter = "top"
    self:_render()
    if self.on_page then pcall(self.on_page, self.page, #self.units) end
    return true
end

function Reader:requestChapter(dir)
    if not self.on_nav then
        self._nav = dir
        return self:close()
    end
    if self._busy then return end
    self:beginBusy()
    -- Laisse l'écran d'attente se dessiner avant le (long) travail.
    UIManager:scheduleIn(0.15, function()
        if self._gone or not self._busy then return end
        local ok, err = pcall(self.on_nav, dir, self.page, #self.units, self)
        if not ok then
            logger.err("Sefirah/ImageReader: changement de chapitre", tostring(err))
            self:restore("Sefirah : " .. tostring(err))
        end
    end)
end

function Reader:askPage()
    local dlg
    dlg = InputDialog:new{
        title = string.format(T("Aller à la page (1–%d)"), #self.units),
        input = tostring(self.page),
        input_type = "number",
        buttons = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            { text = T("Aller"), is_enter_default = true, callback = function()
                local n = tonumber(dlg:getInputText())
                UIManager:close(dlg)
                if n then self:gotoPage(math.max(1, math.min(#self.units, math.floor(n)))) end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Mode de lecture : AUTO (défilement des seules pages hautes) → MANHWA (toutes
-- les pages à pleine largeur, on défile) → MANGA (page entière).
local MODES = { auto = "manhwa", manhwa = "manga", manga = "auto" }
function Reader:cycleMode()
    Settings:set("manga_mode", MODES[Settings:get("manga_mode") or "auto"] or "auto")
    self.zoom = 1
    if self._zb then
        if self._zb.bb then self._zb.bb:free() end
        self._zb = nil
    end
    self._enter = "top"
    self:_render()
end

function Reader:showMenu()
    if not ok_bd then return self:showInfo() end
    local dlg
    local function act(fn)
        return function() UIManager:close(dlg); fn() end
    end
    local label = string.format(T("Page %d / %d"), self.page, #self.units)
    if self.title and self.title ~= "" then label = self.title .. "\n" .. label end
    dlg = ButtonDialog:new{
        title = label,
        buttons = {
            {
                { text = T("Chapitre précédent"), enabled = self.has_prev and true or false,
                  callback = act(function() self:requestChapter(-1) end) },
                { text = T("Chapitre suivant"), enabled = self.has_next and true or false,
                  callback = act(function() self:requestChapter(1) end) },
            },
            {
                { text = T("Aller à la page…"), callback = act(function() self:askPage() end) },
            },
            {
                { text = T("Zoom −"), callback = act(function() self:zoomBy(-1) end) },
                { text = T("Zoom +"), callback = act(function() self:zoomBy(1) end) },
            },
            {
                { text = T("Ajuster la largeur"), callback = act(function() self:fitWidth() end) },
                { text = T("Ajuster la page"), callback = act(function() self:setZoom(1) end) },
            },
            {
                { text = self.rtl and T("Sens : DROITE → GAUCHE") or T("Sens : GAUCHE → DROITE"),
                  callback = act(function()
                      self.rtl = not self.rtl
                      Settings:set("manga_direction", self.rtl and "rtl" or "ltr")
                  end) },
                { text = T("Mode : ") .. ((Settings:get("manga_mode") or "auto") == "manhwa" and "MANHWA"
                      or (Settings:get("manga_mode") or "auto") == "manga" and "MANGA" or "AUTO"),
                  callback = act(function() self:cycleMode() end) },
                { text = T("Doubles pages : ") .. (({ off = "NON", cw = "90° ↻", ccw = "90° ↺" })[Settings:get("manga_rotate_spread") or "off"] or "NON"),
                  callback = act(function() self:cycleSpread() end) },
                { text = T("N° de page : ") .. (Settings:get("manga_pageinfo") and T("OUI") or T("NON")),
                  callback = act(function()
                      Settings:toggle("manga_pageinfo")
                      self:_render(true)
                  end) },
            },
            {
                { text = T("Fermer le lecteur"), callback = act(function() self:close() end) },
            },
        },
    }
    UIManager:show(dlg)
end

-- ── Événements ───────────────────────────────────────────────────────────────
-- Fermeture : on prévient d'abord Sefirah (qui rouvre la fiche du manga PAR-DESSUS
-- le lecteur), puis on ferme le lecteur. Le gestionnaire de fichiers n'apparaît donc jamais.
function Reader:close()
    if self._closing then return end
    self._closing = true
    if self.on_close and not self._closed then
        self._closed = true
        local ok, err = pcall(self.on_close, self.page, #self.units, self._nav)
        if not ok then
            logger.err("Sefirah/ImageReader: retour impossible", tostring(err))
            UIManager:show(InfoMessage:new{ text = "Sefirah : " .. tostring(err), timeout = 6 })
        end
    end
    UIManager:close(self)
end

function Reader:onClose()
    if self._busy then self:cancelBusy(); return true end
    self:close()
    return true
end
function Reader:onPageNext() if not self._busy then self:step(1) end; return true end
function Reader:onPagePrev() if not self._busy then self:step(-1) end; return true end

-- Droite = page suivante en lecture normale, page précédente en manga (rtl).
function Reader:onTapPage(_, ges)
    if self._busy then self:cancelBusy(); return true end
    local x, w = ges.pos.x, self.dimen.w
    if ges.pos.y > self.dimen.h * 0.93 and x > w * 0.3 and x < w * 0.7 then
        self:showMenu()
        return true
    end
    if self._tall and self.zoom > 1.001 then
        local y, h = ges.pos.y, self.dimen.h
        if x > w * 0.3 and x < w * 0.7 and y > h * 0.3 and y < h * 0.7 then
            self:showMenu()
        else
            self:step(y > h * 0.5 and 1 or -1)
        end
        return true
    end
    if x > w * 0.65 then
        self:step(self.rtl and -1 or 1)
    elseif x < w * 0.35 then
        self:step(self.rtl and 1 or -1)
    else
        self:showMenu()
    end
    return true
end

function Reader:onSwipePage(_, ges)
    if self._busy then return true end
    local d = ges.direction or ""
    local west, east = d:find("west") ~= nil, d:find("east") ~= nil
    local north, south = d:find("north") ~= nil, d:find("south") ~= nil
    if self.zoom > 1.001 then
        -- Zoomé : le glissement déplace la page (doigt vers la gauche = on voit la droite).
        local dist = (tonumber(ges.distance) or 0) * (self._tall and 1.8 or 1)
        local k = ((west or east) and (north or south)) and 0.707 or 1
        local dx = ((west and 1 or 0) - (east and 1 or 0)) * dist * k
        local dy = ((north and 1 or 0) - (south and 1 or 0)) * dist * k
        self:pan(dx, dy)
    elseif west and not (north or south) then
        self:step(self.rtl and -1 or 1)
    elseif east and not (north or south) then
        self:step(self.rtl and 1 or -1)
    end
    return true
end

-- Appui long : repère la case sous le doigt et l'agrandit au maximum.
function Reader:zoomToPanel(sx, sy)
    local u = self.units[self.page]
    local bb = u and self:_get(u.i)
    if not bb or not self._s0 or not self._iw then return end
    local sw, sh = self.dimen.w, self.dimen.h
    local rx, ry, rw, rh = self._rx or 0, self._ry or 0, self._iw, self._ih
    local z = self.zoom > 1.001 and self.zoom or 1
    local s = self._s0 * z
    local ccx, ccy = rx + rw / 2, ry + rh / 2
    if z > 1 then ccx, ccy = self.cx, self.cy end
    local px = ccx + (sx - sw / 2) / s
    local py = ccy + (sy - sh / 2) / s
    local function getlum(x, y) return bb:getPixel(x, y):getColor8().a end
    local ok, X0, Y0, X1, Y1 = pcall(find_panel, getlum, rx, ry, rw, rh, px, py)
    if not ok then
        logger.warn("Sefirah/ImageReader: détection de case en échec", tostring(X0))
        return
    end
    local w, h = (X1 or 0) - (X0 or 0), (Y1 or 0) - (Y0 or 0)
    if not X0 or w < 8 or h < 8 or w * h > 0.85 * rw * rh then
        UIManager:show(InfoMessage:new{ text = T("Aucune case détectée ici."), timeout = 1.2 })
        return
    end
    X0, X1 = math.max(rx, X0 - 1), math.min(rx + rw, X1 + 1)
    Y0, Y1 = math.max(ry, Y0 - 1), math.min(ry + rh, Y1 + 1)
    w, h = X1 - X0, Y1 - Y0
    local zoom = math.max(1, math.min(8, math.min(sw / w, sh / h) / self._s0))
    self.zoom = zoom
    self.cx, self.cy = (X0 + X1) / 2, (Y0 + Y1) / 2
    self._panel = { X0, Y0, X1, Y1 }
    self:_render(true)
end

function Reader:onHoldPage(_, ges)
    if self._busy then return true end
    if ges and ges.pos then self:zoomToPanel(ges.pos.x, ges.pos.y) end
    return true
end

function Reader:onSpreadPage() if not self._busy then self:zoomBy(1) end; return true end
function Reader:onPinchPage() if not self._busy then self:zoomBy(-1) end; return true end

function Reader:onCloseWidget()
    self._gone = true
    UIManager:unschedule(self._preload)
    if self._img then self._img:free(); self._img = nil end
    for _, bb in pairs(self._cache) do
        if bb then bb:free() end
    end
    self._cache, self._rot = {}, {}
    pcall(function() self:_freeScaled() end)
    if self.dest then rm_rf(self.dest) end
    UIManager:setDirty(nil, "full")
    if self.on_close and not self._closed then
        self._closed = true
        local cb, page, total, nav = self.on_close, self.page, #self.units, self._nav
        UIManager:nextTick(function()
            local ok, err = pcall(cb, page, total, nav)
            if not ok then logger.err("Sefirah/ImageReader: retour impossible", tostring(err)) end
        end)
    end
end

-- ── Ouverture ────────────────────────────────────────────────────────────────
function ImageReader.open(opts)
    local files, dest = prepare_cbz(opts and opts.cbz)
    if not files then return nil, dest end

    local reader = Reader:new{
        files = files, dest = dest, title = opts.title,
        start_page = opts.start_page, rtl = opts.rtl and true or false,
        has_prev = opts.has_prev, has_next = opts.has_next, auto_next = opts.auto_next,
        on_close = opts.on_close, on_nav = opts.on_nav, on_page = opts.on_page,
    }
    UIManager:show(reader)
    if reader.on_page then pcall(reader.on_page, reader.page, #reader.units) end
    return reader
end

return ImageReader
