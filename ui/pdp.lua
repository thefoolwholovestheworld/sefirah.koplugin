-- ui/pdp.lua — photo de profil (pdp) du Centre de progression.
-- Trois façons de la choisir : un fichier de la liseuse, une recherche d'images en ligne
-- (Openverse / Wikimedia Commons, via core/imagesearch.lua) ou un lien collé
-- (adresse d'une image, ou d'une page web dont on prend l'image principale).
-- L'image est recadrée en carré, réduite à 256 px et enregistrée en local ; elle est
-- affichée en rond. Une version réduite (64 px) est envoyée au classement communautaire pour
-- apparaître sur le podium des autres joueurs.
local Blitbuffer      = require("ffi/blitbuffer")
local DataStorage     = require("datastorage")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local ButtonTable     = require("ui/widget/buttontable")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local P = require("ui.panel")
local Settings = require("sefirah_settings")
local T = require("core.i18n").T

local Screen = Device.screen
local function sc(n) return Screen:scaleBySize(n) end

local DIR   = DataStorage:getSettingsDir() .. "/sefirah"
local FILE  = DIR .. "/profile_pic.png"
local STORE = 256

local Pdp = {}
local _cache = {}     -- taille → blitbuffer rond

local function say(t, to) UIManager:show(InfoMessage:new{ text = t, timeout = to or 4 }) end
local function trim(s) local r = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""); return r end

local function IS() return require("core.imagesearch") end
local function browser_headers(url)
    return {
        ["User-Agent"] = IS().BROWSER_UA, ["Accept"] = "image/*,text/html;q=0.8,*/*;q=0.5",
        ["Referer"] = url and url:match("^(https?://[^/]+/)") or nil,
    }
end

local function clear_cache()
    for k, bb in pairs(_cache) do pcall(function() bb:free() end); _cache[k] = nil end
end

-- Carré size×size, coins passés en blanc (disque inscrit). `src` est libéré.
local function circle(src, size)
    local scaled = src
    if src:getWidth() ~= size or src:getHeight() ~= size then
        scaled = src:scale(size, size)
        src:free()
    end
    local out = Blitbuffer.new(size, size)
    out:fill(Blitbuffer.COLOR_WHITE)
    out:blitFrom(scaled, 0, 0, 0, 0, size, size)
    scaled:free()
    local r = size / 2
    local r2 = r * r
    for y = 0, size - 1 do
        local dy = (y - r) + 0.5
        for x = 0, size - 1 do
            local dx = (x - r) + 0.5
            if dx * dx + dy * dy > r2 then out:setPixel(x, y, Blitbuffer.COLOR_WHITE) end
        end
    end
    return out
end

local function decode(bytes, max_side)
    if type(bytes) ~= "string" or #bytes < 64 then return nil end
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri then return nil end
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, bytes, #bytes, false, max_side, max_side)
    if ok and bb then return bb end
    return nil
end

function Pdp.exists()
    local f = io.open(FILE, "rb")
    if f then f:close(); return true end
    return false
end

-- Widget rond de la pdp, ou nil s'il n'y en a pas.
function Pdp.widget(size)
    if not _cache[size] then
        local f = io.open(FILE, "rb")
        if not f then return nil end
        local data = f:read("*a"); f:close()
        local native = decode(data, STORE * 2)
        if not native then return nil end
        local ok, rd = pcall(circle, native, size)
        if not ok or not rd then return nil end
        _cache[size] = rd
    end
    return ImageWidget:new{
        image = _cache[size], width = size, height = size, scale_factor = 0,
        image_disposable = false, original_in_nightmode = true,
    }
end

function Pdp.remove()
    os.remove(FILE)
    clear_cache()
    Settings:set("pdp_version", os.time())   -- le classement en ligne retirera aussi la photo
end

-- Octets d'image → pdp enregistrée. Retourne true ou nil, message.
function Pdp.setFromBytes(bytes)
    local native = decode(bytes, 600)
    if not native then return nil, T("Image illisible (formats : JPEG, PNG, GIF, WebP…).") end
    local w, h = native:getWidth(), native:getHeight()
    local s = math.min(w, h)
    if s <= 0 then native:free(); return nil, T("Image vide.") end
    local square = Blitbuffer.new(s, s)
    square:fill(Blitbuffer.COLOR_WHITE)
    square:blitFrom(native, 0, 0, math.floor((w - s) / 2), math.floor((h - s) / 2), s, s)
    native:free()
    local small = square
    if s > STORE then small = square:scale(STORE, STORE); square:free() end
    local tmp = FILE .. ".tmp"
    pcall(function() require("libs/libkoreader-lfs").mkdir(DIR) end)
    local ok = pcall(function() small:writePNG(tmp) end)
    small:free()
    if not ok or not os.rename(tmp, FILE) then os.remove(tmp); return nil, T("Impossible d'enregistrer la photo.") end
    clear_cache()
    Settings:set("pdp_version", os.time())   -- le classement en ligne enverra la nouvelle photo
    return true
end

local function apply(bytes, on_change)
    local ok, err = Pdp.setFromBytes(bytes)
    if ok then
        say(T("Photo de profil mise à jour."), 2)
        if on_change then on_change() end
    else
        say(err or T("Échec."))
    end
end

local function online(fn)
    local okO, Online = pcall(require, "core.online")
    if okO and Online and Online.run then Online.run(fn) else fn() end
end

-- ── 1. Depuis un fichier ────────────────────────────────────────────────────
function Pdp.pickFile(on_change)
    local PathChooser = require("ui/widget/pathchooser")
    local start = (G_reader_settings and G_reader_settings:readSetting("home_dir")) or "/"
    UIManager:show(PathChooser:new{
        title = T("Choisir une image"), select_directory = false, select_file = true, path = start,
        onConfirm = function(path)
            local f = io.open(path, "rb")
            if not f then say(T("Fichier introuvable.")); return end
            local bytes = f:read(12 * 1024 * 1024); f:close()
            apply(bytes, on_change)
        end,
    })
end

-- ── 2. Lien collé ───────────────────────────────────────────────────────────
local function is_image_data(b)
    if type(b) ~= "string" then return false end
    return b:sub(1, 2) == "\255\216" or b:sub(2, 4) == "PNG" or b:sub(1, 3) == "GIF"
        or (b:sub(1, 4) == "RIFF" and b:sub(9, 12) == "WEBP")
end

local function unescape(u)
    u = u:gsub("&amp;", "&"):gsub("\\u002F", "/"):gsub("\\/", "/"):gsub("&#x2F;", "/")
    return u
end

-- Cherche l'image principale d'une page web : balises og:image / twitter:image (quel que soit
-- l'ordre des attributs), sinon la première image i.pinimg.com trouvée dans la page.
local function extract_image_url(html)
    for tag in html:gmatch("<[Mm][Ee][Tt][Aa][^>]-[Oo][Gg]:[Ii][Mm][Aa][Gg][Ee][^>]*>") do
        local u = tag:match('content%s*=%s*"([^"]+)"') or tag:match("content%s*=%s*'([^']+)'")
        if u and u:match("^https?:") then return unescape(u) end
    end
    for tag in html:gmatch("<[Mm][Ee][Tt][Aa][^>]-[Tt][Ww][Ii][Tt][Tt][Ee][Rr]:[Ii][Mm][Aa][Gg][Ee][^>]*>") do
        local u = tag:match('content%s*=%s*"([^"]+)"') or tag:match("content%s*=%s*'([^']+)'")
        if u and u:match("^https?:") then return unescape(u) end
    end
    local best
    for u in html:gmatch("https:\\?/\\?/i%.pinimg%.com[^\"'%s<>\\]*[^\"'%s<>]-%.[%a][%a][%a]?[%a]?") do
        u = unescape(u)
        if u:find("/originals/", 1, true) then return u end
        best = best or u
    end
    return best
end

local function fetch_link(url, on_change)
    url = url:gsub("^https?://(https?://)", "%1")
    if not url:match("^https?://") then url = "https://" .. url end
    online(function()
        local info = InfoMessage:new{ text = T("Téléchargement…") }
        UIManager:show(info)
        UIManager:scheduleIn(0.2, function()
            local IM = IS()
            local body, err = IM.httpGet(url, 15, 40, browser_headers(url))
            local page_err
            if body and not is_image_data(body) then
                -- Page web (ex. une épingle Pinterest) : on prend son image principale.
                local img = extract_image_url(body)
                if img then
                    -- Pinterest sert des versions réduites (236x, 474x…) : on demande la 736x.
                    img = img:gsub("/%d%d%d?x/", "/736x/")
                    body, err = IM.httpGet(img, 15, 40, browser_headers(img))
                else
                    body, page_err = nil, T("Aucune image trouvée dans cette page.")
                end
            end
            UIManager:close(info)
            if not body then
                local why = page_err or (err and T("Échec (%s)."):format(tostring(err))) or T("Échec du téléchargement.")
                say(why .. "\n" .. T("Astuce : ouvre l'image sur Pinterest, copie l'adresse de l'image elle-même (i.pinimg.com/…) et colle-la ici."), 8)
                return
            end
            apply(body, on_change)
        end)
    end)
end

function Pdp.askLink(on_change)
    local dlg
    dlg = InputDialog:new{
        title = T("Adresse de l'image (ou de la page)"),
        input = "https://", input_hint = "https://…",
        buttons = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            { text = T("Valider"), is_enter_default = true, callback = function()
                local url = trim(dlg:getInputText())
                UIManager:close(dlg)
                if url ~= "" and url ~= "https://" then fetch_link(url, on_change) end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- ── 3. Recherche en ligne ───────────────────────────────────────────────────
local show_results

local function grid_screen(query, page, items, on_change)
    local W, M, g = P.W, sc(14), sc(8)
    local H_HDR = sc(72)
    local avail = P.H - H_HDR - P.HAIRLINE
    local panel
    local function close()
        if panel then UIManager:close(panel); panel = nil end
        for _, it in ipairs(items) do pcall(function() it.bb:free() end) end
    end
    local function pick(it)
        local bytes = it.bytes
        close()
        apply(bytes, on_change)
    end

    local back = P.wrapTappable(CenterContainer:new{ dimen = Geom:new{ w = sc(46), h = H_HDR },
        TextWidget:new{ text = "←", face = Font:getFace("cfont", 26), bold = true } }, close)
    local titles = VerticalGroup:new{ align = "left",
        TextWidget:new{ text = T("CHOISIR UNE PHOTO"), face = Font:getFace("cfont", 22), bold = true, max_width = W - sc(70) },
        TextWidget:new{ text = T("« %s » · page %d"):format(query, page), face = Font:getFace("cfont", 13),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = W - sc(70) },
    }
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local header = HorizontalGroup:new{ back, LeftContainer:new{ dimen = Geom:new{ w = W - sc(46), h = H_HDR }, titles } }

    local cell = math.floor((W - 2 * M - 2 * g) / 3)
    local function thumb(it)
        local inner = cell - 2 * sc(1)
        local w = FrameContainer:new{ bordersize = sc(1), color = Blitbuffer.Color8(0x88), margin = 0, padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = inner, h = inner }, it and ImageWidget:new{
                image = it.bb, width = inner, height = inner, scale_factor = 0, image_disposable = false,
                original_in_nightmode = true } or VerticalSpan:new{ width = 1 } } }
        return it and P.wrapTappable(w, function() pick(it) end) or w
    end
    local rows = { VerticalSpan:new{ width = sc(12) } }
    for r = 0, 1 do
        local line = {}
        for c = 1, 3 do
            line[#line + 1] = thumb(items[r * 3 + c])
            if c < 3 then line[#line + 1] = HorizontalSpan:new{ width = g } end
        end
        rows[#rows + 1] = HorizontalGroup:new{ HorizontalSpan:new{ width = M }, HorizontalGroup:new(line) }
        rows[#rows + 1] = VerticalSpan:new{ width = sc(12) }
    end

    local function btn(label, cb, w)
        local f = FrameContainer:new{ bordersize = sc(1), color = Blitbuffer.Color8(0x88), radius = sc(4), margin = 0,
            padding = 0, background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = w - 2 * sc(1), h = sc(48) - 2 * sc(1) },
                TextWidget:new{ text = label, face = Font:getFace("cfont", 15), bold = true } } }
        return cb and P.wrapTappable(f, cb) or f
    end
    local bw = math.floor((W - 2 * M - 2 * g) / 3)
    rows[#rows + 1] = HorizontalGroup:new{ HorizontalSpan:new{ width = M },
        btn(page > 1 and T("‹ Précédent") or " ", page > 1 and function() close(); show_results(query, page - 1, on_change) end or nil, bw),
        HorizontalSpan:new{ width = g },
        btn(T("Nouvelle recherche"), function() close(); Pdp.search(on_change) end, bw),
        HorizontalSpan:new{ width = g },
        btn(T("Suivant ›"), function() close(); show_results(query, page + 1, on_change) end, bw) }

    local body = VerticalGroup:new{ align = "left", header, P.hairline(),
        FrameContainer:new{ bordersize = 0, margin = 0, padding = 0, width = W, height = avail,
            P.contentFrame(rows, avail) } }
    panel = P.showFreePanel(body, close)
end

show_results = function(query, page, on_change)
    online(function()
        local info = InfoMessage:new{ text = T("Recherche…") }
        UIManager:show(info)
        UIManager:scheduleIn(0.2, function()
            local IM = IS()
            local okc, res = pcall(IM.searchPage, query, { page = page, page_size = 6 })
            local items = {}
            if okc and res and res.results then
                for _, r in ipairs(res.results) do
                    local bytes = IM.httpGet(r.thumb, 10, 20, browser_headers(r.thumb))
                    local bb = bytes and IM.decode(bytes, 300)
                    if bb then items[#items + 1] = { bb = bb, bytes = bytes } end
                    if #items >= 6 then break end
                end
            end
            UIManager:close(info)
            if not okc or not res or not res.net_ok then say(T("Recherche impossible (connexion ?)."), 5); return end
            if #items == 0 then say(T("Aucun résultat pour « %s »."):format(query), 4); return end
            grid_screen(query, page, items, on_change)
        end)
    end)
end

function Pdp.search(on_change)
    local dlg
    dlg = InputDialog:new{
        title = T("Rechercher une image"), input = "", input_hint = T("ex. chat, paysage, anime…"),
        buttons = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            { text = T("Rechercher"), is_enter_default = true, callback = function()
                local q = trim(dlg:getInputText())
                UIManager:close(dlg)
                if q ~= "" then show_results(q, 1, on_change) end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- ── Menu principal ──────────────────────────────────────────────────────────
-- Popup « Photo de profil » : la pdp en grand au-dessus de toutes les options
-- (à défaut de photo, l'avatar par défaut).
local ROOT = (debug.getinfo(1, "S").source or ""):match("^@(.+)/ui/pdp%.lua$") or ""
local DEFAULT_AVATAR = ROOT .. "/resources/progress/avatar.png"

local function back_key_events()
    if Device:hasKeys() then return { Close = { { Device.input.group.Back } } } end
    return nil
end

local MenuDialog = InputContainer:extend{ on_change = nil }

function MenuDialog:init()
    local W, H    = Screen:getWidth(), Screen:getHeight()
    local BOX_W   = math.floor(W * 0.86)
    local PADDING = sc(16)
    local INNER_W = BOX_W - 2 * PADDING
    self.dimen      = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.key_events = back_key_events()
    self.ges_events = { TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } } }

    local function act(fn)
        return function() UIManager:close(self); fn() end
    end
    local on_change = self.on_change
    local function row(label, fn) return { { text = label, callback = act(fn) } } end
    local buttons = {
        row(T("Depuis un fichier de la liseuse"), function() Pdp.pickFile(on_change) end),
        row(T("Rechercher une image en ligne"),   function() Pdp.search(on_change) end),
        row(T("Coller un lien (image ou page)"),  function() Pdp.askLink(on_change) end),
    }
    if Pdp.exists() then
        buttons[#buttons + 1] = row(T("Retirer la photo"), function() Pdp.remove(); if on_change then on_change() end end)
    end
    buttons[#buttons + 1] = { { text = T("Annuler"), callback = function() self:onClose() end } }

    -- Photo en grand : ~28 % de la hauteur de l'écran, sans dépasser la largeur du popup.
    local size = math.max(sc(120), math.min(INNER_W, math.floor(H * 0.28)))
    local photo = Pdp.widget(size) or ImageWidget:new{
        file = DEFAULT_AVATAR, width = size, height = size, scale_factor = 0, original_in_nightmode = false,
    }

    local group = VerticalGroup:new{ align = "center",
        TextWidget:new{ text = T("Photo de profil"), face = Font:getFace("cfont", 20), bold = true },
        VerticalSpan:new{ width = sc(12) },
        CenterContainer:new{ dimen = Geom:new{ w = INNER_W, h = size }, photo },
        VerticalSpan:new{ width = sc(14) },
        ButtonTable:new{ width = INNER_W, show_parent = self, buttons = buttons },
    }
    self.frame = FrameContainer:new{
        bordersize = sc(1), radius = sc(8), background = Blitbuffer.COLOR_WHITE, padding = PADDING, group,
    }
    self[1] = CenterContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = W, h = H }, self.frame }
end

function MenuDialog:onTapOutside(_arg, ges)
    if self.frame and self.frame.dimen and ges and ges.pos and ges.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
        return true
    end
    return false
end
function MenuDialog:onClose() UIManager:close(self); return true end
function MenuDialog:onShow() UIManager:setDirty(self, function() return "ui", self.dimen end) end
function MenuDialog:onCloseWidget() UIManager:setDirty(nil, function() return "partial", self.dimen end) end

-- ── Partage de la pdp avec le classement communautaire ──────────────────────
-- Une version réduite (64 px, PNG) est envoyée au serveur ; les autres liseuses l'affichent
-- sur le podium. base64 en Lua pur (pas de dépendance à luasocket/mime).
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_REV = {}
for i = 1, #B64 do B64_REV[B64:byte(i)] = i - 1 end

local function b64_encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(v / 262144) % 64
        local c2 = math.floor(v / 4096) % 64
        local c3 = math.floor(v / 64) % 64
        local c4 = v % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

local function b64_decode(str)
    local out, acc, n = {}, 0, 0
    for i = 1, #str do
        local v = B64_REV[str:byte(i)]
        if v then
            acc = acc * 64 + v
            n = n + 1
            if n == 4 then
                out[#out + 1] = string.char(math.floor(acc / 65536) % 256, math.floor(acc / 256) % 256, acc % 256)
                acc, n = 0, 0
            end
        end
    end
    if n == 3 then
        out[#out + 1] = string.char(math.floor(acc / 1024) % 256, math.floor(acc / 4) % 256)
    elseif n == 2 then
        out[#out + 1] = string.char(math.floor(acc / 16) % 256)
    end
    return table.concat(out)
end

-- Identifiant de l'état actuel de la pdp : "none" (aucune) ou un numéro de version.
function Pdp.syncState()
    if not Pdp.exists() then return "none" end
    return tostring(Settings:get("pdp_version") or "legacy") .. "#hq"   -- #hq : photo envoyée en grand format
end

-- PNG réduit (192 px max, plus petit si trop lourd) en base64 (≤ 44 000 caractères, limite du serveur), ou nil.
function Pdp.exportSmall()
    local f = io.open(FILE, "rb")
    if not f then return nil end
    local data = f:read("*a"); f:close()
    for _, side in ipairs({ 192, 160, 128, 96, 64, 48 }) do
        local native = decode(data, STORE * 2)
        if not native then return nil end
        local w, h = native:getWidth(), native:getHeight()
        local s = math.min(w, h)
        if s <= 0 then native:free(); return nil end
        local square = Blitbuffer.new(s, s)
        square:fill(Blitbuffer.COLOR_WHITE)
        square:blitFrom(native, 0, 0, math.floor((w - s) / 2), math.floor((h - s) / 2), s, s)
        native:free()
        local small = square:scale(side, side)
        square:free()
        local tmp = DIR .. "/profile_pic_small.png"
        local ok = pcall(function() small:writePNG(tmp) end)
        small:free()
        local tf = ok and io.open(tmp, "rb")
        if tf then
            local bytes = tf:read("*a"); tf:close()
            os.remove(tmp)
            local b64 = b64_encode(bytes)
            if #b64 <= 44000 then return b64 end
        end
    end
    return nil
end

-- Widget rond d'une pdp reçue du serveur (PNG en base64), ou nil. Mis en cache par contenu.
local _remote = {}
function Pdp.widgetFromBase64(b64, size)
    if type(b64) ~= "string" or #b64 < 100 then return nil end
    local key = #b64 .. ":" .. b64:sub(-24) .. ":" .. size
    if not _remote[key] then
        local native = decode(b64_decode(b64), 256)
        if not native then return nil end
        local ok, rd = pcall(circle, native, size)
        if not ok or not rd then return nil end
        _remote[key] = rd
    end
    return ImageWidget:new{
        image = _remote[key], width = size, height = size, scale_factor = 0,
        image_disposable = false, original_in_nightmode = true,
    }
end

-- Agrandit une pdp (la mienne ou celle d'un autre joueur reçue en base64) avec une légende.
function Pdp.showLarge(caption, b64, mine, fallback_file)
    local data
    if mine then
        local f = io.open(FILE, "rb")
        if f then data = f:read("*a"); f:close() end
    elseif type(b64) == "string" and #b64 >= 100 then
        data = b64_decode(b64)
    end
    if not data and fallback_file then   -- joueur sans photo : on agrandit l'icône par défaut
        local f = io.open(fallback_file, "rb")
        if f then data = f:read("*a"); f:close() end
    end
    local side = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.55)
    local bb
    if data then
        local native = decode(data, STORE * 2)
        if native then
            local ok, rd = pcall(circle, native, side)
            if ok and rd then bb = rd end
        end
    end
    local args = { text = tostring(caption or "") }
    if bb then args.image, args.image_width, args.image_height = bb, side, side end
    UIManager:show(InfoMessage:new(args))
end

function Pdp.menu(on_change)
    UIManager:show(MenuDialog:new{ on_change = on_change })
end

return Pdp
