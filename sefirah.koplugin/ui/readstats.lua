-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- ui/readstats.lua — « Statistiques de lecture » : temps passé, chapitres,
-- série de jours, activité des 14 derniers jours, classement des romans et des
-- sources. Les chiffres viennent de core/stats.lua (base de KOReader) ; rien
-- n'est envoyé sur internet.
local UIManager       = require("ui/uimanager")
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InfoMessage     = require("ui/widget/infomessage")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local T = require("core.i18n").T
local P = require("ui.panel")

local Screen = Device.screen
local function sc(n) return Screen:scaleBySize(n) end

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY, DARK   = Blitbuffer.COLOR_GRAY, Blitbuffer.COLOR_DARK_GRAY
local PALE         = Blitbuffer.Color8(0xEE)

local W      = P.W
local MARGIN = P.MARGIN

local ReadStats = {}

local TABS = {
    { id = "summary", label = "Résumé" },
    { id = "activity", label = "Activité" },
    { id = "novels",  label = "Romans" },
    { id = "sources", label = "Sources" },
}

local S       = nil   -- { tab, page, data, err }
local _panel  = nil

-- ── Formats ──────────────────────────────────────────────────────────────────

local function fmt_dur(secs)
    secs = math.floor(tonumber(secs) or 0)
    if secs < 60 then return secs .. " s" end
    local m = math.floor(secs / 60)
    if m < 60 then return m .. " min" end
    return string.format("%d h %02d", math.floor(m / 60), m % 60)
end

local function weekday(date)
    local y, m, d = date:match("^(%d+)-(%d+)-(%d+)$")
    if not y then return date end
    local t = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
    local names = { T("Dim"), T("Lun"), T("Mar"), T("Mer"), T("Jeu"), T("Ven"), T("Sam") }
    return names[tonumber(os.date("%w", t)) + 1] .. " " .. d .. "/" .. m
end

local function source_name(id)
    local ok, name = pcall(function()
        local meta = require("core.extmgr").getMeta(id)
        return meta and meta.name
    end)
    return (ok and name) or tostring(id or "?")
end

local function chapters_label(n)
    return string.format("%d %s", n, n > 1 and T("chapitres") or T("chapitre"))
end

-- ── Briques d'interface (chacune renvoie un widget à hauteur connue) ─────────

local function section(label)
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
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, padding_left = MARGIN, padding_top = pad,
        width = W, height = h, row,
    }
end

local function note(text, h)
    h = h or sc(90)
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, width = W, height = h,
        CenterContainer:new{
            dimen = Geom:new{ w = W, h = h },
            TextWidget:new{ text = text, face = Font:getFace("cfont", 16), fgcolor = GRAY, max_width = W - 2 * MARGIN },
        },
    }
end

-- Rangée de cartes « valeur + libellé ».
local function cards(items)
    local gap, b = sc(10), sc(2)
    local n = #items
    local card_w = math.floor((W - 2 * MARGIN - gap * (n - 1)) / n)
    local card_h = sc(84)
    local parts = { HorizontalSpan:new{ width = MARGIN } }
    for i, it in ipairs(items) do
        local inner = card_w - 2 * b - sc(8)
        parts[#parts + 1] = FrameContainer:new{
            bordersize = b, color = DARK, radius = sc(8), padding = 0, margin = 0,
            width = card_w, height = card_h, background = WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = card_w - 2 * b, h = card_h - 2 * b },
                VerticalGroup:new{
                    align = "center",
                    TextWidget:new{ text = it.value, face = Font:getFace("cfont", 24), bold = true, max_width = inner },
                    TextWidget:new{ text = it.label, face = Font:getFace("cfont", 14), fgcolor = DARK, max_width = inner },
                },
            },
        }
        if i < n then parts[#parts + 1] = HorizontalSpan:new{ width = gap } end
    end
    return VerticalGroup:new{
        align = "left", HorizontalGroup:new(parts), VerticalSpan:new{ width = sc(14) },
    }
end

-- Barre pleine largeur (fond clair + remplissage noir).
local function bar(width, frac, bar_h)
    local track = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = PALE, width = width, height = bar_h,
        VerticalSpan:new{ width = 0 },
    }
    local fill = frac > 0 and math.max(sc(4), math.floor(width * math.min(1, frac))) or 0
    if fill == 0 then return track end
    return OverlapGroup:new{
        dimen = Geom:new{ w = width, h = bar_h }, track,
        FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0, background = BLACK, width = fill, height = bar_h,
            VerticalSpan:new{ width = 0 },
        },
    }
end

-- Ligne « étiquette — barre — valeur » (activité par jour).
local function bar_row(label, value_text, frac)
    local h = sc(40)
    local label_w, value_w, gap = math.floor(W * 0.26), sc(88), sc(10)
    local area = W - 2 * MARGIN - label_w - value_w - gap
    local lbl = TextWidget:new{ text = label, face = Font:getFace("cfont", 16), max_width = label_w - sc(6) }
    local val = TextWidget:new{ text = value_text, face = Font:getFace("cfont", 16), bold = true, max_width = value_w }
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = MARGIN }, lbl,
        HorizontalSpan:new{ width = math.max(0, label_w - lbl:getSize().w) },
        bar(area, frac, sc(14)), HorizontalSpan:new{ width = gap }, val,
    }
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, width = W, height = h,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = h }, row },
    }
end

-- Ligne « titre / sous-titre / barre » avec le temps à droite (romans, sources).
local function item_row(title, sub, right, frac, on_tap)
    local h = sc(78)
    local right_w = sc(96)
    local text_w = W - 2 * MARGIN - right_w - sc(8)
    local col = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = title, face = Font:getFace("cfont", 18), bold = true, max_width = text_w },
        VerticalSpan:new{ width = sc(2) },
        TextWidget:new{ text = sub, face = Font:getFace("cfont", 14), fgcolor = DARK, max_width = text_w },
        VerticalSpan:new{ width = sc(6) },
        bar(text_w, frac, sc(5)),
    }
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = MARGIN }, col, HorizontalSpan:new{ width = sc(8) },
        CenterContainer:new{
            dimen = Geom:new{ w = right_w, h = h },
            TextWidget:new{ text = right, face = Font:getFace("cfont", 17), bold = true, max_width = right_w },
        },
    }
    local frame = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, width = W, height = h - P.HAIRLINE,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = h - P.HAIRLINE }, row },
    }
    return VerticalGroup:new{
        align = "left",
        on_tap and P.wrapTappable(frame, on_tap) or frame,
        P.hairline(),
    }
end

-- ── Contenu des onglets ──────────────────────────────────────────────────────

local function empty_rows()
    if S.err == "nodb" then
        return { note(T("Base de statistiques de KOReader introuvable.\nActive le plugin « Statistiques » de KOReader, ouvre un livre une fois, puis reviens ici."), sc(150)) }
    end
    return { note(T("Aucune lecture enregistrée pour l'instant.\nLis un chapitre dans le lecteur de Sefirah."), sc(130)) }
end

local function summary_rows(d)
    local rows = {}
    rows[#rows + 1] = section(T("Temps de lecture"))
    rows[#rows + 1] = cards({
        { value = fmt_dur(d.today.secs), label = T("Aujourd'hui") },
        { value = fmt_dur(d.week.secs),  label = T("7 jours") },
        { value = fmt_dur(d.month.secs), label = T("30 jours") },
    })
    rows[#rows + 1] = cards({
        { value = fmt_dur(d.total.secs), label = T("Total") },
        { value = tostring(d.total.chapters), label = T("Chapitres lus") },
        { value = tostring(d.streak) .. " " .. T("j"), label = T("Série en cours") },
    })
    rows[#rows + 1] = section(T("Détails"))
    rows[#rows + 1] = P.makeRow(T("Moyenne par jour de lecture"), { mandatory = fmt_dur(d.avg), mandatory_bold = true })
    if d.best.date then
        rows[#rows + 1] = P.makeRow(T("Meilleur jour") .. " · " .. weekday(d.best.date),
            { mandatory = fmt_dur(d.best.secs), mandatory_bold = true })
    end
    rows[#rows + 1] = P.makeRow(T("Jours de lecture"), { mandatory = tostring(d.days), mandatory_bold = true })
    rows[#rows + 1] = P.makeRow(T("Romans lus"), { mandatory = tostring(#d.books), mandatory_bold = true })
    rows[#rows + 1] = P.makeRow(T("Chapitres (7 jours)"), { mandatory = tostring(d.week.chapters), mandatory_bold = true })
    return rows
end

local function activity_rows(d)
    local rows = { section(T("14 derniers jours")) }
    local max = 0
    for _, day in ipairs(d.daily) do max = math.max(max, day.secs) end
    for i = #d.daily, 1, -1 do   -- le plus récent en haut
        local day = d.daily[i]
        rows[#rows + 1] = bar_row(weekday(day.date), day.secs > 0 and fmt_dur(day.secs) or "–",
            max > 0 and day.secs / max or 0)
    end
    return rows
end

local function novels_rows(d)
    local rows = { section(T("Romans les plus lus")) }
    local max = d.books[1] and d.books[1].secs or 0
    for _, b in ipairs(d.books) do
        local book = b
        rows[#rows + 1] = item_row(
            book.name or "?",
            source_name(book.source) .. " · " .. chapters_label(book.chapters),
            fmt_dur(book.secs),
            max > 0 and book.secs / max or 0,
            function()
                local last = book.last > 0 and os.date("%d/%m/%Y", book.last) or "–"
                UIManager:show(InfoMessage:new{
                    text = string.format("%s\n%s : %s\n%s : %d\n%s : %s",
                        book.name or "?", T("Temps de lecture"), fmt_dur(book.secs),
                        T("Chapitres lus"), book.chapters, T("Dernière lecture"), last),
                    timeout = 8,
                })
            end)
    end
    return rows
end

local function sources_rows(d)
    local rows = { section(T("Temps par source")) }
    local max = d.sources[1] and d.sources[1].secs or 0
    for _, s in ipairs(d.sources) do
        rows[#rows + 1] = item_row(
            source_name(s.id),
            string.format("%d %s", s.books, s.books > 1 and T("romans") or T("roman")),
            fmt_dur(s.secs),
            max > 0 and s.secs / max or 0)
    end
    return rows
end

local function tab_rows()
    local d = S.data
    if not d or not d.has_data then return empty_rows() end
    if S.tab == "activity" then return activity_rows(d) end
    if S.tab == "novels"   then return novels_rows(d) end
    if S.tab == "sources"  then return sources_rows(d) end
    return summary_rows(d)
end

-- ── Pagination par hauteur réelle des lignes ─────────────────────────────────

local function paginate(rows, budget)
    local pages, cur, used = {}, {}, 0
    for _, r in ipairs(rows) do
        local h = r:getSize().h
        if used + h > budget and #cur > 0 then
            pages[#pages + 1] = cur; cur, used = {}, 0
        end
        cur[#cur + 1] = r
        used = used + h
    end
    pages[#pages + 1] = cur
    return pages
end

-- ── Affichage ────────────────────────────────────────────────────────────────

local function on_back()
    if _panel then UIManager:close(_panel) end
    _panel, S = nil, nil
end

local function tabs_labels()
    local t = {}
    for _, tab in ipairs(TABS) do t[#t + 1] = { id = tab.id, label = T(tab.label) } end
    return t
end

local render

local function switch_tab(id)
    if not S then return end
    S.tab, S.page = id, 1
    render(false)
end

render = function(same_tab)
    if not S then return end
    local rows = tab_rows()
    local pages = paginate(rows, P.CUSTOM_CONTENT_H)
    if #pages > 1 then pages = paginate(rows, P.CUSTOM_CONTENT_H_NAV) end
    local max_pages = #pages
    S.page = math.max(1, math.min(S.page or 1, max_pages))

    local function go(n)
        n = math.max(1, math.min(max_pages, n))
        if n ~= S.page then S.page = n; render(true) end
    end
    local nav = max_pages > 1 and {
        page = S.page, max_pages = max_pages,
        on_prev  = S.page > 1 and function() go(S.page - 1) end or nil,
        on_next  = S.page < max_pages and function() go(S.page + 1) end or nil,
        on_first = S.page > 1 and function() go(1) end or nil,
        on_last  = S.page < max_pages and function() go(max_pages) end or nil,
        on_jump  = go,
    } or nil

    local ok, body = pcall(P.buildCustomTabBody,
        tabs_labels(), S.tab, switch_tab, pages[S.page], T("Statistiques de lecture"), on_back, nav, nil)
    if not ok then
        pcall(function() require("logger").err("Sefirah statistiques :", tostring(body)) end)
        UIManager:show(InfoMessage:new{ text = T("Sefirah — erreur :\n") .. tostring(body):gsub("\n.*", ""), timeout = 6 })
        return
    end
    if not _panel then
        _panel = P.FullScreenPanel:new{
            body = body, close_callback = function() _panel, S = nil, nil end, nav = nav,
        }
        UIManager:show(_panel)
    else
        _panel:swapBody(body, function() _panel, S = nil, nil end, same_tab, nav)
    end
end

function ReadStats.show()
    local Stats = require("core.stats")
    local ok, data, err = pcall(Stats.summary)
    if not ok then
        pcall(function() require("logger").err("Sefirah statistiques :", tostring(data)) end)
        data, err = nil, "error"
    end
    if _panel then UIManager:close(_panel); _panel = nil end
    S = { tab = "summary", page = 1, data = data, err = err }
    render(false)
end

return ReadStats
