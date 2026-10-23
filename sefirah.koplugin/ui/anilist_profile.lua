-- ui/anilist_profile.lua — « Profil AniList » façon site AniList :
-- bannière + avatar + pseudo, onglets Aperçu / Anime / Manga / Favoris / Stats,
-- couvertures, barres de progression, notes. Tout est paginé (glisser ou ‹ ›).
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local ButtonDialog    = require("ui/widget/buttondialog")
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local T        = require("core.i18n").T
local AniList  = require("core.anilist")
local Settings = require("settings")
local Online   = require("core.online")
local Aimg     = require("core.aimg")
local P        = require("ui.panel")

local Screen = Device.screen
local function sc(n) return Screen:scaleBySize(n) end

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY, DARK   = Blitbuffer.COLOR_GRAY, Blitbuffer.COLOR_DARK_GRAY
local LIGHT        = Blitbuffer.COLOR_LIGHT_GRAY
local PALE         = Blitbuffer.Color8(0xEE)

local Profile = {}

local W        = P.W
local MARGIN   = P.MARGIN
local BANNER_H = math.floor(P.H * 0.19)
local AVATAR   = math.floor(BANNER_H * 0.60)
local TAB_H    = sc(58)
local COLS     = 5

local TABS = {
    { id = "overview", label = "Aperçu" },
    { id = "anime",    label = "Anime" },
    { id = "manga",    label = "Manga" },
    { id = "novel",    label = "Web novels" },
    { id = "favs",     label = "Favoris" },
    { id = "stats",    label = "Stats" },
}

-- Ordre d'affichage des statuts (comme sur le site).
local STATUSES = {
    { "CURRENT", "En cours" }, { "REPEATING", "Relecture" }, { "COMPLETED", "Terminés" },
    { "PAUSED", "En pause" }, { "DROPPED", "Abandonnés" }, { "PLANNING", "Planifiés" },
}
local function status_label(code)
    for _, s in ipairs(STATUSES) do if s[1] == code then return T(s[2]) end end
    return code
end

local FORMATS = {
    TV = "TV", TV_SHORT = "TV court", MOVIE = "Film", SPECIAL = "Spécial", OVA = "OVA", ONA = "ONA",
    MUSIC = "Musique", MANGA = "Manga", NOVEL = "Light novel", ONE_SHOT = "One-shot",
}

local S, _panel   -- état courant, panneau affiché

local function msg(text, timeout) UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 4 }) end

local function fail(err)
    local text = T("AniList : ") .. tostring(err)
    if AniList.last_error then text = text .. "\n" .. AniList.last_error end
    msg(text, 8)
end

-- ── Petits utilitaires ───────────────────────────────────────────────────────

local function image(bb, w, h)
    local ImageWidget = require("ui/widget/imagewidget")
    return ImageWidget:new{ image = bb, image_disposable = false, width = w, height = h }
end

local function free_bbs(list)
    for _, bb in ipairs(list or {}) do pcall(bb.free, bb) end
end

local function empty_frame(w, h, bg)
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, width = w, height = h,
        background = bg or WHITE, VerticalSpan:new{ width = 0 },
    }
end

local function first_char(s)
    return tostring(s or "?"):match("[%z\1-\127\194-\244][\128-\191]*") or "?"
end

local function placeholder(w, h, label)
    local b = sc(1)
    return FrameContainer:new{
        bordersize = b, color = LIGHT, background = PALE, padding = 0, margin = 0, width = w, height = h,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b },
            TextWidget:new{ text = first_char(label), face = Font:getFace("cfont", 22), fgcolor = GRAY },
        },
    }
end

-- Texte sur `max_lines` lignes au plus (… si trop long), dans un cadre de hauteur fixe.
local function text_lines(text, face, width, max_lines, opts)
    opts = opts or {}
    local lh = TextWidget:new{ text = "Ag", face = face, bold = opts.bold }:getSize().h
    local h = math.ceil(lh * 1.3) * max_lines + sc(2)
    local tb = TextBoxWidget:new{
        text = text, face = face, width = width, bold = opts.bold, fgcolor = opts.fgcolor,
        alignment = opts.alignment or "left", height = h, height_overflow_show_ellipsis = true,
    }
    return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, width = width, height = h, tb }, h
end

-- Texte AniList (Markdown/HTML) → texte brut lisible.
local function clean(d, max)
    d = tostring(d or "")
    d = d:gsub("~!.-!~", ""):gsub("img%d*%b()", ""):gsub("[Ii]mg%d*%b()", "")
         :gsub("[Yy]outube%b()", ""):gsub("[Ww]ebm%b()", "")
    d = d:gsub("<br%s*/?>", "\n"):gsub("<[^>]+>", "")
    d = d:gsub("%[([^%]]*)%]%b()", "%1")
    d = d:gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
    d = d:gsub("[_%*~`]+", "")
    d = d:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#039;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
    d = d:gsub("\r", ""):gsub("\n%s*\n+", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if max and #d > max then d = d:sub(1, max):gsub("[\128-\191]*$", "") .. "…" end
    return d
end

local function fmt_score(s) return string.format("%.1f", (tonumber(s) or 0) / 10) end

-- ── Briques d'interface ──────────────────────────────────────────────────────
-- Un « bloc » = { widget, h, urls = {images à précharger}, keep = vrai pour un titre
-- de section qui ne doit pas rester seul en bas de page }.

local function block_section(label)
    local h = sc(48)
    local bar = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = BLACK, width = sc(6), height = sc(24),
        VerticalSpan:new{ width = 0 },
    }
    local row = HorizontalGroup:new{
        align = "center", bar, HorizontalSpan:new{ width = sc(10) },
        TextWidget:new{ text = label, face = Font:getFace("cfont", 21), bold = true },
    }
    local pad = math.max(0, math.floor((h - row:getSize().h) / 2))
    local w = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, padding_left = MARGIN, padding_top = pad,
        width = W, height = h, row,
    }
    return { widget = w, h = h, keep = true }
end

local function block_sub(label)
    local h = sc(40)
    local w = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, padding_left = MARGIN, padding_top = sc(6), width = W, height = h,
        TextWidget:new{ text = label, face = Font:getFace("cfont", 16), bold = true, fgcolor = DARK },
    }
    return { widget = w, h = h, keep = true }
end

local function block_note(text)
    local h = sc(70)
    local w = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, width = W, height = h,
        CenterContainer:new{
            dimen = Geom:new{ w = W, h = h },
            TextWidget:new{ text = text, face = Font:getFace("cfont", 16), fgcolor = GRAY, max_width = W - 2 * MARGIN },
        },
    }
    return { widget = w, h = h }
end

-- Rangée de 3 cartes « valeur + libellé ».
local function block_stats(items)
    local gap, b = sc(10), sc(2)
    local n = #items
    local card_w = math.floor((W - 2 * MARGIN - gap * (n - 1)) / n)
    local card_h = sc(84)
    local parts = { HorizontalSpan:new{ width = MARGIN } }
    for i, it in ipairs(items) do
        local inner = card_w - 2 * b - sc(8)
        local card = FrameContainer:new{
            bordersize = b, color = DARK, radius = sc(8), padding = 0, margin = 0,
            width = card_w, height = card_h, background = WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = card_w - 2 * b, h = card_h - 2 * b },
                VerticalGroup:new{
                    align = "center",
                    TextWidget:new{ text = it.value, face = Font:getFace("cfont", 26), bold = true, max_width = inner },
                    TextWidget:new{ text = it.label, face = Font:getFace("cfont", 14), fgcolor = DARK, max_width = inner },
                },
            },
        }
        parts[#parts + 1] = card
        if i < n then parts[#parts + 1] = HorizontalSpan:new{ width = gap } end
    end
    local h = card_h + sc(14)
    return { widget = VerticalGroup:new{ align = "left", HorizontalGroup:new(parts), VerticalSpan:new{ width = sc(14) } }, h = h }
end

-- Biographie dans une carte (touche = texte complet).
local function block_about(text)
    local b = sc(2)
    local inner_w = W - 2 * MARGIN - 2 * b - 2 * sc(12)
    local short = clean(text, 260)
    local tb, th = text_lines(short, Font:getFace("cfont", 16), inner_w, 5)
    local card = FrameContainer:new{
        bordersize = b, color = LIGHT, radius = sc(8), padding = sc(12), margin = 0,
        width = W - 2 * MARGIN, tb,
    }
    local tappable = P.wrapTappable(card, function() msg(clean(text, 1500), 20) end)
    local h = card:getSize().h + sc(14)
    local w = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{ HorizontalSpan:new{ width = MARGIN }, tappable },
        VerticalSpan:new{ width = sc(14) },
    }
    return { widget = w, h = h }
end

local function entry_info(e, kind)
    if e.progress == nil then return msg(e.title, 4) end   -- favori : pas de progression
    local lines = { e.title }
    local meta = {}
    if e.format then meta[#meta + 1] = T(FORMATS[e.format] or e.format) end
    meta[#meta + 1] = e.progress .. (e.total and ("/" .. e.total) or "") .. " "
        .. (kind == "anime" and T("ép.") or T("ch."))
    if e.status then meta[#meta + 1] = status_label(e.status) end
    lines[#lines + 1] = table.concat(meta, " · ")
    if (e.score or 0) > 0 then lines[#lines + 1] = "★ " .. fmt_score(e.score) .. " / 10" end
    msg(table.concat(lines, "\n"), 6)
end

-- Une rangée de couvertures (COLS par rangée). `entries` : { title, cover, … }.
local function block_covers(entries, kind)
    local cell_w  = math.floor((W - 2 * MARGIN) / COLS)
    local cover_w = cell_w - sc(10)
    local cover_h = math.floor(cover_w * 1.42)
    local lines   = 2
    local face    = Font:getFace("cfont", 13)
    local urls, cells = {}, { HorizontalSpan:new{ width = MARGIN } }
    local title_h
    for i = 1, COLS do
        local e = entries[i]
        if e then
            urls[#urls + 1] = e.cover_url
            local bb = Aimg.bb(e.cover_url, cover_w, cover_h)
            local pic = bb and image(bb, cover_w, cover_h) or placeholder(cover_w, cover_h, e.title)
            local tb
            tb, title_h = text_lines(e.title, face, cover_w, lines, { alignment = "center" })
            local cell = FrameContainer:new{
                bordersize = 0, padding = 0, margin = 0, width = cell_w, height = cover_h + title_h + sc(14),
                CenterContainer:new{
                    dimen = Geom:new{ w = cell_w, h = cover_h + title_h + sc(14) },
                    VerticalGroup:new{ align = "center", pic, VerticalSpan:new{ width = sc(4) }, tb },
                },
            }
            cells[#cells + 1] = P.wrapTappable(cell, function() entry_info(e.raw or e, kind) end)
        else
            cells[#cells + 1] = empty_frame(cell_w, cover_h + sc(14))
        end
    end
    local h = cover_h + (title_h or 0) + sc(14)
    return { widget = HorizontalGroup:new(cells), h = h, urls = urls }
end

local function cover_rows(entries, kind, url_key)
    local rows, cur = {}, {}
    for _, e in ipairs(entries) do
        cur[#cur + 1] = { title = e.title, cover_url = e[url_key], raw = e }
        if #cur == COLS then rows[#rows + 1] = block_covers(cur, kind); cur = {} end
    end
    if #cur > 0 then rows[#rows + 1] = block_covers(cur, kind) end
    return rows
end

-- Ligne de liste : miniature, titre, méta, barre de progression, note.
local function block_entry(e, kind)
    local h = sc(94)
    local thumb_w, thumb_h = sc(56), sc(80)
    local score_w = sc(70)
    local text_w = W - 2 * MARGIN - thumb_w - sc(12) - score_w
    local bb = Aimg.bb(e.cover, thumb_w, thumb_h)
    local pic = bb and image(bb, thumb_w, thumb_h) or placeholder(thumb_w, thumb_h, e.title)

    local meta = {}
    if e.format then meta[#meta + 1] = T(FORMATS[e.format] or e.format) end
    meta[#meta + 1] = e.progress .. (e.total and ("/" .. e.total) or "") .. " "
        .. (kind == "anime" and T("ép.") or T("ch."))
    local title_w = text_lines(e.title, Font:getFace("cfont", 18), text_w, 2, { bold = true })
    local meta_w  = TextWidget:new{
        text = table.concat(meta, " · "), face = Font:getFace("cfont", 14), fgcolor = DARK, max_width = text_w,
    }
    local col = { align = "left", title_w, VerticalSpan:new{ width = sc(3) }, meta_w }
    if e.total and e.total > 0 then
        local bar_h = sc(5)
        local fill = math.floor(text_w * math.min(1, e.progress / e.total))
        local track = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0, background = LIGHT, width = text_w, height = bar_h,
            VerticalSpan:new{ width = 0 },
        }
        local bar = track
        if fill > 0 then
            bar = OverlapGroup:new{
                dimen = Geom:new{ w = text_w, h = bar_h }, track,
                FrameContainer:new{
                    bordersize = 0, padding = 0, margin = 0, background = BLACK, width = fill, height = bar_h,
                    VerticalSpan:new{ width = 0 },
                },
            }
        end
        col[#col + 1] = VerticalSpan:new{ width = sc(6) }
        col[#col + 1] = bar
    end
    local score = (e.score or 0) > 0
        and TextWidget:new{ text = "★ " .. fmt_score(e.score), face = Font:getFace("cfont", 17), bold = true }
        or TextWidget:new{ text = "–", face = Font:getFace("cfont", 17), fgcolor = LIGHT }
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = MARGIN }, pic, HorizontalSpan:new{ width = sc(12) },
        VerticalGroup:new(col),
        CenterContainer:new{ dimen = Geom:new{ w = score_w, h = h }, score },
    }
    local frame = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, width = W, height = h - P.HAIRLINE,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = h - P.HAIRLINE }, row },
    }
    local w = VerticalGroup:new{ align = "left", P.wrapTappable(frame, function() entry_info(e, kind) end), P.hairline() }
    return { widget = w, h = h, urls = { e.cover } }
end

-- Ligne de barre horizontale (genres, statuts).
local function block_bar(label, value, max)
    local h = sc(40)
    local label_w, count_w, gap = math.floor(W * 0.30), sc(64), sc(10)
    local area = W - 2 * MARGIN - label_w - count_w - gap
    local bar_h = sc(14)
    local fill = (max > 0 and value > 0) and math.max(sc(4), math.floor(area * value / max)) or 0
    local track = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = PALE, width = area, height = bar_h,
        VerticalSpan:new{ width = 0 },
    }
    local bar = track
    if fill > 0 then
        bar = OverlapGroup:new{
            dimen = Geom:new{ w = area, h = bar_h }, track,
            FrameContainer:new{
                bordersize = 0, padding = 0, margin = 0, background = BLACK, width = fill, height = bar_h,
                VerticalSpan:new{ width = 0 },
            },
        }
    end
    local count = TextWidget:new{ text = tostring(value), face = Font:getFace("cfont", 16), bold = true, max_width = count_w }
    local lbl = TextWidget:new{ text = label, face = Font:getFace("cfont", 16), max_width = label_w - sc(6) }
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = MARGIN }, lbl,
        HorizontalSpan:new{ width = math.max(0, label_w - lbl:getSize().w) },
        bar, HorizontalSpan:new{ width = gap }, count,
    }
    local w = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, width = W, height = h,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = h }, row },
    }
    return { widget = w, h = h }
end

-- ── Web novels : lectures locales du plugin (rien à voir avec AniList) ───────

-- Les web novels étrangers (Shadow Slave…) n'existent pas sur AniList : on
-- affiche ce que le plugin sait déjà (bibliothèque + chapitres terminés).
local function local_novels()
    local ok1, DB       = pcall(require, "core.db")
    local ok2, Cache    = pcall(require, "core.cache")
    local ok3, ExtMgr   = pcall(require, "core.extmgr")
    if not (ok1 and ok2 and ok3) then return {} end
    local out = {}
    for _, n in ipairs(DB.getAll() or {}) do
        if ExtMgr.kindOf(n.source_id) == "novels" then
            local e = Cache.getNovelEntry(n.source_id, n.path or "")
            local read, last = 0, 0
            for _, v in pairs(e and e.progress_by_chapter or {}) do
                if type(v) == "table" then
                    if v.completed then read = read + 1 end
                    last = math.max(last, tonumber(v.updated_at) or 0)
                end
            end
            local meta = ExtMgr.getMeta(n.source_id)
            out[#out + 1] = {
                n = n, title = tostring(n.title or n.name or "?"), read = read, last = last,
                total = tonumber(n.total_chapters) or 0, source = meta and meta.name or tostring(n.source_id),
            }
        end
    end
    table.sort(out, function(a, b)
        if a.last ~= b.last then return a.last > b.last end
        return a.title:lower() < b.title:lower()
    end)
    return out
end

local function block_local_novel(it)
    local h = sc(94)
    return { h = h, build = function()
        local thumb_w, thumb_h = sc(56), sc(80)
        local count_w = sc(96)
        local text_w = W - 2 * MARGIN - thumb_w - sc(12) - count_w
        local ok, Covers = pcall(require, "core.covers")
        local bb = ok and Covers.get(it.n.source_id, it.n.path or "", nil, nil, thumb_w, thumb_h) or nil
        if bb then S.cover_bbs[#S.cover_bbs + 1] = bb end
        local pic = bb and image(bb, thumb_w, thumb_h) or placeholder(thumb_w, thumb_h, it.title)
        local when = it.last > 0 and os.date("%d/%m/%Y", it.last) or T("Pas encore lu")
        local col = {
            align = "left",
            (text_lines(it.title, Font:getFace("cfont", 18), text_w, 2, { bold = true })),
            VerticalSpan:new{ width = sc(3) },
            TextWidget:new{ text = it.source .. " · " .. when, face = Font:getFace("cfont", 14), fgcolor = DARK, max_width = text_w },
        }
        if it.total > 0 then
            local bar_h = sc(5)
            local fill = math.floor(text_w * math.min(1, it.read / it.total))
            local track = FrameContainer:new{
                bordersize = 0, padding = 0, margin = 0, background = LIGHT, width = text_w, height = bar_h,
                VerticalSpan:new{ width = 0 },
            }
            local bar = track
            if fill > 0 then
                bar = OverlapGroup:new{
                    dimen = Geom:new{ w = text_w, h = bar_h }, track,
                    FrameContainer:new{
                        bordersize = 0, padding = 0, margin = 0, background = BLACK, width = fill, height = bar_h,
                        VerticalSpan:new{ width = 0 },
                    },
                }
            end
            col[#col + 1] = VerticalSpan:new{ width = sc(6) }
            col[#col + 1] = bar
        end
        local count = TextWidget:new{
            text = it.read .. (it.total > 0 and ("/" .. it.total) or ""),
            face = Font:getFace("cfont", 17), bold = true, max_width = count_w,
        }
        local row = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = MARGIN }, pic, HorizontalSpan:new{ width = sc(12) },
            VerticalGroup:new(col),
            CenterContainer:new{ dimen = Geom:new{ w = count_w, h = h }, count },
        }
        local frame = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0, width = W, height = h - P.HAIRLINE,
            CenterContainer:new{ dimen = Geom:new{ w = W, h = h - P.HAIRLINE }, row },
        }
        local info = it.title .. "\n" .. it.read .. (it.total > 0 and (" / " .. it.total) or "") .. " " .. T("chapitres lus")
        return VerticalGroup:new{
            align = "left", P.wrapTappable(frame, function() msg(info, 5) end), P.hairline(),
        }
    end }
end

local function novels_blocks()
    local list = local_novels()
    if #list == 0 then return { block_note(T("Aucun web novel dans ta bibliothèque.")) } end
    local total_read, in_progress = 0, 0
    for _, it in ipairs(list) do
        total_read = total_read + it.read
        if it.read > 0 and (it.total == 0 or it.read < it.total) then in_progress = in_progress + 1 end
    end
    local blocks = { block_stats({
        { value = tostring(#list),       label = T("Web novels") },
        { value = tostring(total_read),  label = T("Chapitres lus") },
        { value = tostring(in_progress), label = T("En cours") },
    }) }
    for _, it in ipairs(list) do blocks[#blocks + 1] = block_local_novel(it) end
    return blocks
end

-- ── Contenu des onglets ──────────────────────────────────────────────────────

local function kind_title(kind)
    if kind == "anime" then return T("Anime") end
    if kind == "novel" then return T("Web novels") end
    return T("Manga")
end

local function stat_items(kind)
    local st = S.p[kind] or {}
    local mean = fmt_score(st.meanScore)
    if kind == "anime" then
        return {
            { value = tostring(st.count or 0), label = T("Anime") },
            { value = string.format("%.1f", (st.minutesWatched or 0) / 1440), label = T("Jours") },
            { value = mean, label = T("Note moy.") },
        }
    end
    return {
        { value = tostring(st.count or 0), label = T("Manga") },
        { value = tostring(st.chaptersRead or 0), label = T("Chapitres lus") },
        { value = mean, label = T("Note moy.") },
    }
end

local function lists_missing_note(blocks)
    blocks[#blocks + 1] = block_note(T("Listes indisponibles. Touche ↺ pour réessayer."))
end

local function overview_blocks()
    local blocks = {}
    if S.p.about and clean(S.p.about) ~= "" then blocks[#blocks + 1] = block_about(S.p.about) end
    for _, kind in ipairs({ "anime", "manga" }) do
        blocks[#blocks + 1] = block_section(kind_title(kind))
        blocks[#blocks + 1] = block_stats(stat_items(kind))
        blocks[#blocks].keep = true
        local L = S.lists and S.lists[kind]
        if not L then
            lists_missing_note(blocks)
        elseif #L.all > 0 then
            local recent = {}
            for i = 1, math.min(COLS, #L.all) do recent[i] = L.all[i] end
            for _, r in ipairs(cover_rows(recent, kind, "cover_l")) do blocks[#blocks + 1] = r end
        end
    end
    return blocks
end

local function favs_blocks()
    local blocks = {}
    for _, kind in ipairs({ "anime", "manga" }) do
        local favs = S.p.favs and S.p.favs[kind] or {}
        if #favs > 0 then
            blocks[#blocks + 1] = block_section(kind_title(kind))
            for _, r in ipairs(cover_rows(favs, kind, "cover")) do blocks[#blocks + 1] = r end
        end
    end
    if #blocks == 0 then blocks[1] = block_note(T("Aucun favori.")) end
    return blocks
end

local function stats_blocks()
    local blocks = {}
    for _, kind in ipairs({ "anime", "manga" }) do
        local st = S.p[kind] or {}
        blocks[#blocks + 1] = block_section(kind_title(kind))
        local genres = st.genres or {}
        if #genres > 0 then
            blocks[#blocks + 1] = block_sub(T("Genres"))
            local max = 0
            for _, g in ipairs(genres) do max = math.max(max, g.count) end
            for _, g in ipairs(genres) do blocks[#blocks + 1] = block_bar(g.genre, g.count, max) end
        end
        local L = S.lists and S.lists[kind]
        if L then
            local counts, max = {}, 0
            for _, s in ipairs(STATUSES) do
                local n = #(L.by_status[s[1]] or {})
                if n > 0 then counts[#counts + 1] = { s[1], n }; max = math.max(max, n) end
            end
            if #counts > 0 then
                blocks[#blocks + 1] = block_sub(T("Statuts"))
                for _, c in ipairs(counts) do blocks[#blocks + 1] = block_bar(status_label(c[1]), c[2], max) end
            end
        else
            lists_missing_note(blocks)
        end
    end
    return blocks
end

-- Onglets Anime / Manga : barre de statut fixe + lignes paginées.
local function status_counts(L)
    local avail = {}
    for _, s in ipairs(STATUSES) do
        local n = #(L.by_status[s[1]] or {})
        if n > 0 then avail[#avail + 1] = { code = s[1], n = n } end
    end
    return avail
end

local choose_status

local function filter_bar(kind, code, n)
    local h = sc(52)
    local row = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = status_label(code), face = Font:getFace("cfont", 19), bold = true },
        HorizontalSpan:new{ width = sc(10) },
        TextWidget:new{ text = "(" .. n .. ")", face = Font:getFace("cfont", 16), fgcolor = DARK },
        HorizontalSpan:new{ width = sc(14) },
        TextWidget:new{ text = "▾", face = Font:getFace("cfont", 20), bold = true },
    }
    local left = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = PALE, width = W, height = h,
        padding_left = MARGIN, padding_top = math.floor((h - row:getSize().h) / 2), row,
    }
    return P.wrapTappable(left, function() choose_status(kind) end), h
end

local function list_view(kind)
    local L = S.lists and S.lists[kind]
    if not L then
        local b = {}
        lists_missing_note(b)
        return b, nil, 0
    end
    local avail = status_counts(L)
    if #avail == 0 then return { block_note(T("Liste vide.")) }, nil, 0 end
    local code = S.status[kind]
    local n = #(L.by_status[code or ""] or {})
    if n == 0 then code = avail[1].code; n = avail[1].n; S.status[kind] = code end
    local blocks = {}
    for _, e in ipairs(L.by_status[code]) do blocks[#blocks + 1] = block_entry(e, kind) end
    local top, top_h = filter_bar(kind, code, n)
    return blocks, top, top_h
end

choose_status = function(kind)
    local L = S.lists and S.lists[kind]
    if not L then return end
    local dlg
    local buttons = {}
    for _, a in ipairs(status_counts(L)) do
        buttons[#buttons + 1] = {{
            text = status_label(a.code) .. "  (" .. a.n .. ")" .. (a.code == S.status[kind] and "  ✓" or ""),
            callback = function()
                UIManager:close(dlg)
                S.status[kind] = a.code
                S.page = 1
                Profile._render(false)
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = T("Fermer"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = kind_title(kind), buttons = buttons }
    UIManager:show(dlg)
end

-- ── En-tête : bannière, avatar, pseudo, boutons ──────────────────────────────

local function gradient(w, h)
    if S.grad then return S.grad end
    local bb = Blitbuffer.new(w, h)
    for y = 0, h - 1 do
        local v = math.floor(0x3C - (0x3C - 0x10) * y / math.max(1, h - 1))
        bb:paintRect(0, y, w, 1, Blitbuffer.Color8(v))
    end
    S.grad = bb
    return bb
end

local function round_button(glyph, cb)
    local sz = sc(52)
    local btn = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = BLACK, radius = math.floor(sz / 2), width = sz, height = sz,
        CenterContainer:new{
            dimen = Geom:new{ w = sz, h = sz },
            TextWidget:new{ text = glyph, face = Font:getFace("cfont", 22), bold = true, fgcolor = WHITE },
        },
    }
    return P.wrapTappable(btn, cb)
end

local function build_header()
    local bb = Aimg.bb(S.p.banner, W, BANNER_H) or gradient(W, BANNER_H)
    local frame_b = sc(4)
    local av_bb = Aimg.bb(S.p.avatar, AVATAR, AVATAR)
    local av_inner = av_bb and image(av_bb, AVATAR, AVATAR) or placeholder(AVATAR, AVATAR, S.p.name)
    local avatar = FrameContainer:new{
        bordersize = frame_b, color = WHITE, padding = 0, margin = 0, background = WHITE, av_inner,
    }
    local av_size = avatar:getSize()
    local chip = FrameContainer:new{
        bordersize = 0, background = BLACK, padding_left = sc(14), padding_right = sc(14),
        padding_top = sc(5), padding_bottom = sc(5), margin = 0,
        TextWidget:new{
            text = S.p.name or "?", face = Font:getFace("cfont", 24), bold = true, fgcolor = WHITE,
            max_width = W - av_size.w - 2 * MARGIN - sc(30),
        },
    }
    local back = round_button("←", function() if _panel then _panel:onClose() end end)
    local refresh = round_button("↺", function() Profile._reload() end)

    local banner = image(bb, W, BANNER_H)
    local pad = sc(12)
    avatar.overlap_offset = { MARGIN, BANNER_H - av_size.h - pad }
    chip.overlap_offset   = { MARGIN + av_size.w + sc(14), BANNER_H - chip:getSize().h - pad - sc(2) }
    back.overlap_offset    = { sc(10), sc(10) }
    refresh.overlap_offset = { W - sc(52) - sc(10), sc(10) }
    return OverlapGroup:new{ dimen = Geom:new{ w = W, h = BANNER_H }, banner, avatar, chip, back, refresh }
end

local function build_tabs()
    local seg = math.floor(W / #TABS)
    local cells = {}
    for i, tab in ipairs(TABS) do
        local active = tab.id == S.tab
        local cw = (i == #TABS) and (W - seg * (#TABS - 1)) or seg
        local ind_h = sc(4)
        local lbl = TextWidget:new{
            text = T(tab.label), face = Font:getFace("cfont", active and 20 or 18), bold = active,
            fgcolor = active and BLACK or DARK, max_width = cw - sc(8),
        }
        local cell = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0, background = PALE, width = cw, height = TAB_H,
            VerticalGroup:new{
                align = "center",
                CenterContainer:new{ dimen = Geom:new{ w = cw, h = TAB_H - ind_h }, lbl },
                FrameContainer:new{
                    bordersize = 0, padding = 0, margin = 0, width = cw, height = ind_h,
                    background = active and BLACK or PALE, VerticalSpan:new{ width = 0 },
                },
            },
        }
        cells[#cells + 1] = active and cell or P.wrapTappable(cell, function()
            S.tab, S.page = tab.id, 1
            Profile._render(false)
        end)
    end
    return HorizontalGroup:new(cells)
end

-- ── Pagination ───────────────────────────────────────────────────────────────

local function paginate(blocks, avail)
    local pages, cur, used = {}, {}, 0
    for i, b in ipairs(blocks) do
        local need, j = b.h, i
        while blocks[j].keep and blocks[j + 1] do j = j + 1; need = need + blocks[j].h end
        if used + need > avail and #cur > 0 then
            pages[#pages + 1] = cur; cur, used = {}, 0
        end
        cur[#cur + 1] = b
        used = used + b.h
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    if #pages == 0 then pages[1] = {} end
    return pages
end

local function tab_content()
    if S.tab == "anime" or S.tab == "manga" then return list_view(S.tab) end
    if S.tab == "novel" then return novels_blocks() end
    if S.tab == "favs" then return favs_blocks() end
    if S.tab == "stats" then return stats_blocks() end
    return overview_blocks()
end

local function layout()
    local blocks, top, top_h = tab_content()
    top_h = top_h or 0
    local avail = P.H - (BANNER_H + TAB_H + P.HAIRLINE + top_h)
    local pages = paginate(blocks, avail)
    if #pages > 1 then avail = avail - (P.NAV_ROW_H + P.HAIRLINE); pages = paginate(blocks, avail) end
    S.page = math.max(1, math.min(S.page or 1, #pages))
    return pages, top, avail
end

local function build_body()
    local pages, top, avail = layout()
    -- Images de la page : téléchargées en une fois, puis la page est reconstruite avec.
    local urls = {}
    for _, b in ipairs(pages[S.page]) do for _, u in ipairs(b.urls or {}) do urls[#urls + 1] = u end end
    if #urls > 0 then
        Aimg.prefetch(urls)
        pages, top, avail = layout()
    end
    local page, max_pages = pages[S.page], #pages
    local header = build_header()
    local tabs = build_tabs()

    local rows = {}
    for _, b in ipairs(page) do rows[#rows + 1] = b.widget or b.build() end
    local children = { header, tabs, P.hairline() }
    if top then children[#children + 1] = top end
    children[#children + 1] = P.contentFrame(rows, avail)

    local nav
    if max_pages > 1 then
        local function go(n)
            n = math.max(1, math.min(max_pages, n))
            if n ~= S.page then S.page = n; Profile._render(true) end
        end
        nav = {
            page = S.page, max_pages = max_pages,
            on_prev  = S.page > 1 and function() go(S.page - 1) end or nil,
            on_next  = S.page < max_pages and function() go(S.page + 1) end or nil,
            on_first = S.page > 1 and function() go(1) end or nil,
            on_last  = S.page < max_pages and function() go(max_pages) end or nil,
            on_jump  = go,
        }
        children[#children + 1] = P.hairline()
        children[#children + 1] = P.makeNavBar(nav)
    end
    return VerticalGroup:new{ align = "left", table.unpack(children) }, nav
end

-- ── Affichage ────────────────────────────────────────────────────────────────

local function close_all()
    Aimg.release()
    if S then free_bbs(S.cover_bbs) end
    if S and S.grad then pcall(S.grad.free, S.grad) end
    S, _panel = nil, nil
end

function Profile._render(same_tab)
    if not S then return end
    local old_bbs = S.cover_bbs
    S.cover_bbs = {}
    local ok, body, nav = pcall(build_body)
    if not ok then
        pcall(function() require("logger").err("Sefirah profil AniList :", tostring(body)) end)
        return msg(T("Sefirah — erreur :\n") .. tostring(body):gsub("\n.*", ""), 8)
    end
    if not _panel then
        _panel = P.FullScreenPanel:new{ body = body, close_callback = close_all, nav = nav }
        UIManager:show(_panel)
    else
        _panel:swapBody(body, close_all, same_tab, nav)
    end
    if S then free_bbs(old_bbs) end
end

local function load_all()
    local p, err = AniList.profile(Settings:get("anilist_username"))
    if not p then return nil, nil, err end
    local lists, lerr = AniList.user_lists(p.id)
    Aimg.prefetch({ p.avatar, p.banner })
    return p, lists, nil, lerr
end

function Profile._reload()
    Online.run(function()
        local loading = InfoMessage:new{ text = T("Chargement du profil AniList…") }
        UIManager:show(loading)
        UIManager:nextTick(function()
            local p, lists, err = load_all()
            UIManager:close(loading)
            if not p then return fail(err) end
            if S then S.p, S.lists = p, lists; Profile._render(false) end
        end)
    end)
end

function Profile.show()
    Online.run(function()
        local loading = InfoMessage:new{ text = T("Chargement du profil AniList…") }
        UIManager:show(loading)
        UIManager:nextTick(function()
            local p, lists, err = load_all()
            UIManager:close(loading)
            if not p then return fail(err) end
            if _panel then UIManager:close(_panel); close_all() end
            S = { p = p, lists = lists, tab = "overview", page = 1, status = {}, cover_bbs = {} }
            Profile._render(false)
        end)
    end)
end

return Profile
