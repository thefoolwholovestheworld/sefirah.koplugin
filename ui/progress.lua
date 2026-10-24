-- ui/progress.lua — « Centre de progression » : 4 onglets (Progression, Quêtes,
-- Classement, Succès) en cartes, d'après la maquette. Données : core/quests.lua et
-- core/leaderboard.lua. Un seul panneau plein écran dont le corps est remplacé
-- sur place à chaque changement d'onglet.
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InfoMessage     = require("ui/widget/infomessage")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local P      = require("ui.panel")
local Quests = require("core.quests")
local Pdp    = require("ui.pdp")
local T      = require("core.i18n").T
local Settings = require("settings")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY         = Blitbuffer.Color8(0x88)   -- bordures
local LGRAY        = Blitbuffer.Color8(0xBB)   -- traits fins
local DARK         = Blitbuffer.COLOR_DARK_GRAY -- texte secondaire
local PALE         = Blitbuffer.Color8(0xE6)

local ROOT     = (debug.getinfo(1, "S").source or ""):match("^@(.+)/ui/progress%.lua$") or ""
local ICON_DIR = ROOT .. "/resources/progress/"

local W = P.W
local M = Screen:scaleBySize(14)
local function sc(n) return Screen:scaleBySize(n) end
local function units(px) return px / (Screen:scaleBySize(1000) / 1000) end

local HDR_H = sc(72)
local TAB_H = sc(76)

local Progress = {}
local _screen, _tab = nil, "progress"
local _qtab, _rtab, _atab = "daily", "general", "easy"
local _rpage = 1                               -- page du classement (1 : top 10, 2 : 11 à 20)
local _apage = 1                               -- page courante de la liste de succès
local _qpage = 1                               -- page courante de la liste de quêtes (Long terme)
local K = 1                                    -- facteur d'échelle vertical (petits écrans)
local function sz(n) return sc(math.floor(n * K)) end

-- ── Primitives ──────────────────────────────────────────────────────────────
local function text(s, size, o)
    o = o or {}
    return TextWidget:new{
        text = tostring(s), bold = o.bold, fgcolor = o.color or BLACK, max_width = o.max_w,
        face = Font:getFace("cfont", math.max(11, math.floor(size * K))),
    }
end

local function icon(name, size)
    return ImageWidget:new{
        file = ICON_DIR .. name .. ".png", width = size, height = size,
        scale_factor = 0, original_in_nightmode = false,
    }
end

local function avatar_widget(size)
    return Pdp.widget(size) or icon("avatar", size)
end

local function slot(w, h, child, mode)
    local C = (mode == "center" and CenterContainer) or (mode == "right" and RightContainer) or LeftContainer
    return C:new{ dimen = Geom:new{ w = w, h = h }, child }
end

local function hline(w) return LineWidget:new{ dimen = Geom:new{ w = w, h = sc(1) }, background = LGRAY } end
local function gap(h) return VerticalSpan:new{ width = h } end
-- Espaces « de rangée » : leur hauteur est augmentée après coup pour remplir l'écran (cf. stretch).
local _rg = {}
local function rgap(h) local g = VerticalSpan:new{ width = h }; _rg[#_rg + 1] = g; return g end
local function hgap(w) return HorizontalSpan:new{ width = w } end
local function inset(w) return HorizontalGroup:new{ hgap(M), w } end

local function fmt(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^%s+", ""))
end

local function bar(w, h, frac)
    frac = math.max(0, math.min(1, frac or 0))
    local fw = math.floor(w * frac + 0.5)
    local parts = {}
    if fw > 0 then parts[#parts + 1] = LineWidget:new{ dimen = Geom:new{ w = fw, h = h }, background = BLACK } end
    if w - fw > 0 then parts[#parts + 1] = LineWidget:new{ dimen = Geom:new{ w = w - fw, h = h }, background = LGRAY } end
    return HorizontalGroup:new(parts)
end

-- Carte à bordure fine, coins arrondis ; h = hauteur extérieure.
local function card(w, h, child, o)
    o = o or {}
    local b = sc(1)
    local C = o.center and CenterContainer or LeftContainer
    return FrameContainer:new{
        bordersize = b, color = o.color or GRAY, radius = sc(6), margin = 0, padding = 0,
        background = o.bg or WHITE,
        C:new{ dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b }, child },
    }
end
local function card_auto(w, child, o)
    return card(w, child:getSize().h + 2 * sc(1), child, o)
end

-- ── En-tête et barre d'onglets ──────────────────────────────────────────────
-- Popup d'aide : toutes les façons de gagner de l'XP + le système de niveaux.
local function show_help()
    local lines = {
        T("NIVEAUX"),
        T("• Chaque tranche de 250 XP te fait gagner un niveau."),
        T("• Tu commences au niveau 1 ; niveau 2 à 250 XP, niveau 3 à 500 XP, etc. Il n'y a pas de limite."),
        T("• L'XP totale et le niveau sont ceux affichés dans le classement."),
        "",
        T("LIRE DES NOVELS"),
        T("• +5 XP par page lue (page restée affichée entre 15 s et 5 min)."),
        T("• +20 XP par chapitre terminé (une seule fois par chapitre)."),
        "",
        T("LIRE DES MANGAS"),
        T("• +2 XP par page tournée (page restée affichée au moins 5 s)."),
        T("• +10 XP par chapitre terminé."),
        T("• Moins que les novels, car il y a moins de lecture par page."),
        "",
        T("QUÊTES"),
        T("• Quotidiennes, hebdomadaires et du mois : chaque quête terminée donne un bonus d'XP."),
        T("• Les récompenses quotidiennes et hebdomadaires augmentent avec ton niveau."),
        "",
        T("SUCCÈS"),
        T("• Faciles, Moyens et Difficiles : un bonus d'XP unique à chaque succès débloqué."),
        T("• Les Difficiles rapportent énormément d'XP."),
        "",
        T("BON À SAVOIR"),
        T("• Seule la lecture vers l'avant compte : relire ou feuilleter vite ne rapporte rien."),
        T("• Laisser la liseuse allumée sur une page ne rapporte rien non plus."),
    }
    local text_ = table.concat(lines, "\n")
    local ok = pcall(function()
        local TextViewer = require("ui/widget/textviewer")
        UIManager:show(TextViewer:new{
            title = T("Gagner de l'XP et niveaux"),
            text = text_,
            justified = false,
        })
    end)
    if not ok then UIManager:show(InfoMessage:new{ text = text_ }) end
end
Progress.showHelp = show_help

local function make_header(title, sub, icon_name, on_back)
    local back = P.wrapTappable(slot(sc(46), HDR_H, text("←", 26, { bold = true }), "center"), on_back)
    local ic = slot(sc(54), HDR_H, icon(icon_name, sc(38)), "center")
    local info_w = sc(56)
    local info = P.wrapTappable(slot(info_w, HDR_H, icon("info", sc(34)), "center"), show_help)
    local rest = W - sc(46) - sc(54) - sc(10) - info_w
    local titles = VerticalGroup:new{ align = "left",
        text(title, 24, { bold = true, max_w = rest }),
        text(sub, 13, { color = DARK, max_w = rest }),
    }
    return HorizontalGroup:new{ back, ic, slot(rest + sc(10), HDR_H, titles, "left"), info }
end

local TABS = {
    { id = "progress", label = "Progression", icon = "tab_progress", on = "tab_progress_on" },
    { id = "quests",   label = "Quêtes",      icon = "tab_quests",   on = "tab_quests_on" },
    { id = "rank",     label = "Classement",  icon = "tab_rank",     on = "tab_rank" },
    { id = "achv",     label = "Succès",      icon = "tab_achv",     on = "tab_achv_on" },
}

local function make_tabbar(active, switch)
    local cells = {}
    local base = math.floor(W / #TABS)
    for i, t in ipairs(TABS) do
        local cw = (i == #TABS) and (W - base * (#TABS - 1)) or base
        local on = t.id == active
        local ind = LineWidget:new{ dimen = Geom:new{ w = cw, h = sc(4) }, background = on and BLACK or LGRAY }
        local inner = VerticalGroup:new{ align = "center",
            icon(on and t.on or t.icon, sc(30)), gap(sc(3)),
            TextWidget:new{ text = T(t.label), bold = on, face = Font:getFace("cfont", 15), fgcolor = BLACK },
        }
        local cell = VerticalGroup:new{ align = "left", ind, slot(cw, TAB_H - sc(4), inner, "center") }
        cells[#cells + 1] = on and cell or P.wrapTappable(cell, function() switch(t.id) end)
    end
    return HorizontalGroup:new(cells)
end

-- Sélecteur segmenté (Quotidiennes | Hebdomadaires | Long terme, Général | Hebdomadaire).
local function segmented(items, active_id, on_pick)
    local total, h, b = W - 2 * M, sz(40), sc(1)
    local n = #items
    local base = math.floor(total / n)
    local cells = {}
    for i, it in ipairs(items) do
        local cw = (i == n) and (total - base * (n - 1)) or base
        local on = it.id == active_id
        local f = FrameContainer:new{
            bordersize = b, color = BLACK, margin = 0, padding = 0, background = on and BLACK or WHITE,
            slot(cw - 2 * b, h - 2 * b, text(T(it.label), 16, { bold = on, color = on and WHITE or BLACK }), "center"),
        }
        cells[#cells + 1] = on and f or P.wrapTappable(f, function() on_pick(it.id) end)
    end
    return inset(HorizontalGroup:new(cells))
end

-- ── Quêtes ──────────────────────────────────────────────────────────────────
local function quest_content(q, w, h)
    local iw, chw = sc(54), sc(30)
    local bw, bh = sc(84), sz(32)
    local mw = w - iw - (bw + sc(4)) - chw
    local prog = text(q.cur .. " / " .. q.goal, 14)
    local barw = math.max(sc(40), mw - prog:getSize().w - sc(16))
    local mid = VerticalGroup:new{ align = "left",
        text(q.title, 17, { bold = true, max_w = mw - sc(6) }),
        text(q.desc, 13, { color = DARK, max_w = mw - sc(6) }),
        gap(sz(4)),
        HorizontalGroup:new{ bar(barw, sz(8), q.cur / q.goal), hgap(sc(10)), prog },
    }
    local badge = FrameContainer:new{
        bordersize = 0, radius = sc(4), margin = 0, padding = 0, background = q.done and LGRAY or PALE,
        slot(bw, bh, text("+ " .. q.xp .. " XP", 15, { bold = true }), "center"),
    }
    return HorizontalGroup:new{
        slot(iw, h, icon(q.done and "check_p" or q.icon, sz(30)), "center"),
        slot(mw, h, mid, "left"),
        slot(bw + sc(4), h, badge, "center"),
        slot(chw, h, text(q.done and "✓" or "›", q.done and 22 or 28, { bold = true }), "center"),
    }
end

local function quest_hint(q)
    return q.title .. "\n" .. q.desc .. "\n" .. q.cur .. " / " .. q.goal .. "  ·  +" .. q.xp .. " XP"
        .. (q.done and ("\n" .. T("✓ Terminée")) or "")
end

-- ── Écran Progression ───────────────────────────────────────────────────────
local function build_progress(avail, go, redraw)
    K = math.min(1, units(avail) / 520)
    local p, qs = Quests.getProgress(), Quests.getQuests()
    local w, b = W - 2 * M, sc(1)
    local iw = w - 2 * b
    local rows = { rgap(sz(12)) }

    -- Niveau / expérience
    do
        local h = sz(120)
        local hh = h - 2 * b
        local av = sz(72)
        local aw = av + sc(28)
        local lw = sc(104)
        local rw = iw - aw - lw - sc(1) - sc(30)
        local avatar = P.wrapTappable(slot(aw, hh, avatar_widget(av), "center"), function()
            Pdp.menu(function() redraw(true) end)
        end)
        local left = slot(lw, hh, HorizontalGroup:new{ hgap(sc(6)), VerticalGroup:new{ align = "left",
            text(T("NIVEAU"), 15, { bold = true }), text(tostring(p.level), 52, { bold = true }) } }, "left")
        local sep = slot(sc(1), hh, LineWidget:new{ dimen = Geom:new{ w = sc(1), h = hh - sz(26) }, background = LGRAY }, "center")
        local right = slot(iw - aw - lw - sc(1), hh, HorizontalGroup:new{ hgap(sc(16)), VerticalGroup:new{ align = "left",
            text(T("EXPÉRIENCE"), 14, { color = DARK }),
            text(fmt(p.into_level) .. " / " .. fmt(p.next_level) .. " XP", 22, { bold = true, max_w = rw }),
            gap(sz(8)), bar(rw, sz(14), p.into_level / p.next_level), gap(sz(8)),
            text(T("Encore %d XP avant le niveau %d"):format(p.next_level - p.into_level, p.level + 1), 13, { max_w = rw }),
        } }, "left")
        rows[#rows + 1] = inset(card(w, h, HorizontalGroup:new{ avatar, left, sep, right }))
        rows[#rows + 1] = rgap(sz(12))
    end

    -- Statistiques de lecture
    do
        local hh = sz(36)
        local head = HorizontalGroup:new{
            slot(math.floor(iw * 0.6), hh, HorizontalGroup:new{ hgap(sc(14)), text(T("STATISTIQUES DE LECTURE"), 16, { bold = true }) }, "left"),
            slot(iw - math.floor(iw * 0.6), hh, HorizontalGroup:new{ text(T("Aujourd'hui"), 13, { color = DARK }), hgap(sc(14)) }, "right"),
        }
        local stats = {
            { "book",     p.daily_pages,  T("pages"),     T("aujourd'hui") },
            { "calendar", p.weekly_pages, T("pages"),     T("cette semaine") },
            { "doc",      p.chapters,     T("chapitres"), T("terminés") },
            { "flame",    p.streak,       T("jours"),     T("de série") },
        }
        local colh = sz(116)
        local base = math.floor((iw - 3) / 4)
        local cols = {}
        for i, s in ipairs(stats) do
            local cw = (i == 4) and (iw - 3 - base * 3) or base
            cols[#cols + 1] = slot(cw, colh, VerticalGroup:new{ align = "center",
                icon(s[1], sz(24)), text(fmt(s[2]), 22, { bold = true, max_w = cw - sc(6) }),
                text(s[3], 12, { color = DARK, max_w = cw - sc(6) }), text(s[4], 12, { color = DARK, max_w = cw - sc(6) }),
                gap(sz(6)) }, "center")
            if i < 4 then cols[#cols + 1] = slot(sc(1), colh, LineWidget:new{ dimen = Geom:new{ w = sc(1), h = colh - sz(20) }, background = LGRAY }, "center") end
        end
        local vg = VerticalGroup:new{ align = "left", head, hline(iw), HorizontalGroup:new(cols) }
        rows[#rows + 1] = inset(card_auto(w, vg))
        rows[#rows + 1] = rgap(sz(12))
    end

    -- Quêtes en cours : uniquement celles qui sont réellement commencées (0 < progression < objectif),
    -- les plus avancées d'abord.
    do
        local started, remaining = {}, 0
        for i, q in ipairs(qs.daily) do
            if not q.done then
                remaining = remaining + 1
                if q.cur > 0 then q._i = i; started[#started + 1] = q end
            end
        end
        table.sort(started, function(a, b)
            local fa, fb = a.cur / a.goal, b.cur / b.goal
            if fa ~= fb then return fa > fb end
            return a._i < b._i
        end)
        local shown = {}
        for i = 1, math.min(2, #started) do shown[i] = started[i] end
        local hh = sz(36)
        local count = (#started > #shown) and (T("%d / %d en cours"):format(#shown, #started)) or (T("%d en cours"):format(#started))
        local head = HorizontalGroup:new{
            slot(math.floor(iw * 0.6), hh, HorizontalGroup:new{ hgap(sc(14)), text(T("QUÊTES EN COURS"), 16, { bold = true }) }, "left"),
            slot(iw - math.floor(iw * 0.6), hh, HorizontalGroup:new{ text(count, 13, { color = DARK }), hgap(sc(14)) }, "right"),
        }
        local items = { head }
        if #shown == 0 then
            items[#items + 1] = hline(iw)
            local msg = remaining == 0 and T("Toutes les quêtes du jour sont terminées ✓") or T("Aucune quête commencée pour l'instant.")
            items[#items + 1] = slot(iw, sz(60), text(msg, 15, { max_w = iw - sc(24) }), "center")
        end
        for _, q in ipairs(shown) do
            items[#items + 1] = hline(iw)
            items[#items + 1] = P.wrapTappable(quest_content(q, iw, sz(74)), function() go("quests") end)
        end
        rows[#rows + 1] = inset(card_auto(w, VerticalGroup:new(items)))
    end
    rows[#rows + 1] = rgap(sz(8))
    return rows
end

-- ── Écran Quêtes ────────────────────────────────────────────────────────────
local QUESTS_PER_PAGE = 5

local function pager(page, total, on_prev, on_next)
    local tw, h, b = W - 2 * M, sz(40), sc(1)
    local cw = math.floor(tw / 3)
    local function cell(width, label, cb, bold)
        local f = FrameContainer:new{ bordersize = b, color = cb and GRAY or LGRAY, radius = sc(4), margin = 0, padding = 0, background = WHITE,
            slot(width - 2 * b, h - 2 * b, text(label, 15, { bold = bold }), "center") }
        return cb and P.wrapTappable(f, cb) or f
    end
    return inset(HorizontalGroup:new{
        cell(cw, page > 1 and T("‹ Précédent") or " ", page > 1 and on_prev or nil),
        cell(tw - 2 * cw, page .. " / " .. total, nil, true),
        cell(cw, page < total and T("Suivant ›") or " ", page < total and on_next or nil),
    })
end

local function build_quests(avail, redraw)
    local qs = Quests.getQuests()
    local list = qs[_qtab] or qs.daily
    if _qtab == "long" then
        -- Les paliers à atteindre d'abord, les paliers déjà validés ensuite.
        local todo, done = {}, {}
        for _, q in ipairs(list) do if q.done then done[#done + 1] = q else todo[#todo + 1] = q end end
        list = {}
        for _, q in ipairs(todo) do list[#list + 1] = q end
        for _, q in ipairs(done) do list[#list + 1] = q end
    end
    local paged = #list > 6
    local npages = paged and math.ceil(#list / QUESTS_PER_PAGE) or 1
    _qpage = math.max(1, math.min(_qpage, npages))
    local shown = list
    if paged then
        shown = {}
        for i = (_qpage - 1) * QUESTS_PER_PAGE + 1, math.min(#list, _qpage * QUESTS_PER_PAGE) do shown[#shown + 1] = list[i] end
    end
    local n = math.max(1, #shown)
    local extra = paged and 52 or 0
    K = math.min(1, units(avail) / (12 + 40 + 12 + n * 90 + extra))
    local ch = math.max(80, math.min(104, math.floor((units(avail) - 70 - extra) / n - 10)))
    local w = W - 2 * M
    local rows = { rgap(sz(12)),
        segmented({ { id = "daily", label = T("Quotidiennes") }, { id = "weekly", label = T("Hebdomadaires") }, { id = "long", label = T("Long terme") } },
            _qtab, function(id) _qtab = id; _qpage = 1; redraw(true) end),
        rgap(sz(12)) }
    for _, q in ipairs(shown) do
        local h = sz(ch)
        local c = card(w, h, quest_content(q, w - 2 * sc(1), h - 2 * sc(1)), { bg = q.done and PALE or WHITE })
        rows[#rows + 1] = inset(P.wrapTappable(c, function()
            UIManager:show(InfoMessage:new{ text = quest_hint(q), timeout = 5 })
        end))
        rows[#rows + 1] = rgap(sz(10))
    end
    if paged then
        rows[#rows + 1] = pager(_qpage, npages,
            function() _qpage = _qpage - 1; redraw(true) end,
            function() _qpage = _qpage + 1; redraw(true) end)
        rows[#rows + 1] = rgap(sz(8))
    end
    return rows
end


-- ── Écran Succès ────────────────────────────────────────────────────────────
-- Faciles / Moyens / Difficiles : de l'XP (les Difficiles en donnent beaucoup).
local ACHV_PER_PAGE = 5

local function achv_content(q, w, h)
    local iw, chw = sc(60), sc(30)
    local rw = q.badge and sc(96) or (sc(104) + sc(4))
    local mw = w - iw - rw - chw
    local prog = text(fmt(q.cur) .. " / " .. fmt(q.goal), 14)
    local barw = math.max(sc(40), mw - prog:getSize().w - sc(16))
    local title = HorizontalGroup:new{
        text(q.title, 17, { bold = true, max_w = mw - sc(34) }),
        hgap(sc(6)),
        q.done and hgap(0) or icon("lock", sz(16)),
    }
    local lines = { align = "left", title, text(q.desc, 13, { color = DARK, max_w = mw - sc(6) }) }
    if q.badge and q.novel then lines[#lines + 1] = text("« " .. q.novel .. " »", 12, { color = DARK, max_w = mw - sc(6) }) end
    lines[#lines + 1] = gap(sz(4))
    lines[#lines + 1] = HorizontalGroup:new{ bar(barw, sz(8), q.cur / q.goal), hgap(sc(10)), prog }
    local mid = VerticalGroup:new(lines)
    local left
    if q.badge then
        left = slot(iw, h, icon(q.icon .. (q.done and "" or "_off"), sz(48)), "center")
    else
        left = slot(iw, h, icon(q.done and "check_p" or q.icon, sz(30)), "center")
    end
    local right
    if q.badge then
        right = FrameContainer:new{
            bordersize = 0, radius = sc(4), margin = 0, padding = 0, background = q.done and LGRAY or PALE,
            slot(rw - sc(8), sz(32), text(q.done and T("Obtenu") or T("Badge"), 14, { bold = true }), "center"),
        }
    else
        right = FrameContainer:new{
            bordersize = 0, radius = sc(4), margin = 0, padding = 0, background = q.done and LGRAY or PALE,
            slot(sc(104), sz(32), text("+ " .. fmt(q.xp) .. " XP", 15, { bold = true }), "center"),
        }
    end
    return HorizontalGroup:new{
        left,
        slot(mw, h, mid, "left"),
        slot(rw, h, right, "center"),
        slot(chw, h, text(q.done and "✓" or "›", q.done and 22 or 28, { bold = true }), "center"),
    }
end

local function achv_hint(q)
    local t = q.title .. "\n" .. q.desc .. "\n" .. fmt(q.cur) .. " / " .. fmt(q.goal)
    if q.badge then
        t = t .. "\n" .. T("Badge") .. " · " .. (q.novel or "")
    else
        t = t .. "  ·  +" .. fmt(q.xp) .. " XP"
    end
    return t .. (q.done and ("\n" .. T("✓ Obtenu")) or "")
end

local function build_achv(avail, redraw)
    local all = Quests.getAchievements()
    local src = all[_atab] or all.easy
    -- Les succès à débloquer d'abord, ceux déjà obtenus ensuite.
    local todo, done = {}, {}
    for _, q in ipairs(src) do if q.done then done[#done + 1] = q else todo[#todo + 1] = q end end
    local list = {}
    -- Le badge Créateur (unique) reste toujours tout en haut, même une fois obtenu.
    for _, q in ipairs(done) do if q.id == "h_creator" then list[#list + 1] = q end end
    for _, q in ipairs(todo) do list[#list + 1] = q end
    for _, q in ipairs(done) do if q.id ~= "h_creator" then list[#list + 1] = q end end
    local paged = #list > 6
    local npages = paged and math.ceil(#list / ACHV_PER_PAGE) or 1
    _apage = math.max(1, math.min(_apage, npages))
    local shown = list
    if paged then
        shown = {}
        for i = (_apage - 1) * ACHV_PER_PAGE + 1, math.min(#list, _apage * ACHV_PER_PAGE) do shown[#shown + 1] = list[i] end
    end
    local n = math.max(1, #shown)
    local extra = paged and 52 or 0
    K = math.min(1, units(avail) / (12 + 40 + 12 + n * 90 + extra))
    local ch = math.max(80, math.min(104, math.floor((units(avail) - 70 - extra) / n - 10)))
    local w = W - 2 * M
    local rows = { rgap(sz(12)),
        segmented({ { id = "easy", label = T("Faciles") }, { id = "medium", label = T("Moyens") }, { id = "hard", label = T("Difficiles") } },
            _atab, function(id) _atab = id; _apage = 1; redraw(true) end),
        rgap(sz(12)) }
    for _, q in ipairs(shown) do
        local h = sz(ch)
        local c = card(w, h, achv_content(q, w - 2 * sc(1), h - 2 * sc(1)), { bg = q.done and PALE or WHITE })
        rows[#rows + 1] = inset(P.wrapTappable(c, function()
            UIManager:show(InfoMessage:new{ text = achv_hint(q), timeout = 5 })
        end))
        rows[#rows + 1] = rgap(sz(10))
    end
    if paged then
        rows[#rows + 1] = pager(_apage, npages,
            function() _apage = _apage - 1; redraw(true) end,
            function() _apage = _apage + 1; redraw(true) end)
        rows[#rows + 1] = rgap(sz(8))
    end
    return rows
end

-- ── Écran Classement ────────────────────────────────────────────────────────
local function player_fields(pl)
    local xp = math.max(0, tonumber(pl.xp) or 0)
    local name = tostring(pl.username or pl.pseudo or T("Lecteur"))
    local lvl = math.max(1, tonumber(pl.level) or (math.floor(xp / 250) + 1))
    return name, lvl, xp
end

-- Marque « Créateur » à droite du pseudo (serveur : pl.creator ; moi : reconnu localement).
local function is_creator_pl(pl, mine)
    if pl and pl.creator == true then return true end
    if mine then
        local ok, c = pcall(function() return require("core.quests").isCreator() end)
        return ok and c == true
    end
    return false
end
local function name_widget(name, mark, pt, max_w, bold)
    if not mark then return text(name, pt, { bold = bold, max_w = max_w }) end
    local isz = sz(pt + 4)
    return HorizontalGroup:new{ text(name, pt, { bold = bold, max_w = max_w - isz - sc(4) }), hgap(sc(4)), icon("star", isz) }
end

-- Ma pdp (locale) si c'est moi ; sinon celle envoyée par le joueur au serveur ; sinon l'icône par défaut.
local function podium_avatar(pl, mine, size)
    local wdg
    if mine then wdg = avatar_widget(size)
    elseif pl and pl.avatar then
        local ok, w2 = pcall(Pdp.widgetFromBase64, pl.avatar, size)
        if ok and w2 then wdg = w2 end
    end
    wdg = wdg or icon("avatar", size)
    if not pl then return wdg end
    -- Toucher la pdp l'affiche en grand, avec le pseudo, le niveau et l'XP.
    local name, lvl, xp = player_fields(pl)
    return P.wrapTappable(wdg, function()
        local stats = T("Niv. %d"):format(lvl) .. "  ·  " .. fmt(xp) .. " XP"
        local cap = name .. "\n" .. stats
        if is_creator_pl(pl, mine) then cap = name .. "\n" .. T("— CRÉATEUR —") .. "\n" .. stats end
        Pdp.showLarge(cap, pl.avatar, mine, ICON_DIR .. "avatar.png")
    end)
end

local PODIUM_H = 168   -- hauteur de la carte du 1er (unités) : assez pour que rien ne dépasse de la case
local function podium_card(rank, pl, w, h, mine)
    local first = rank == 1
    local name, lvl, xp = "—", nil, nil
    if pl then name, lvl, xp = player_fields(pl) end
    local vg = VerticalGroup:new{ align = "center",
        HorizontalGroup:new{ icon(first and "crown" or "medal", sz(first and 24 or 20)), hgap(sc(4)), text(rank, 16, { bold = true }) },
        gap(sz(4)), podium_avatar(pl, mine, sz(first and 62 or 52)), gap(sz(4)),
        name_widget(name, pl and is_creator_pl(pl, mine), 15, w - sc(12), true),
        text(lvl and T("Niv. %d"):format(lvl) or " ", 13, { color = DARK }),
        text(xp and (fmt(xp) .. " XP") or " ", 14, { bold = true, max_w = w - sc(12) }),
    }
    return card(w, h, vg, { center = true, color = first and BLACK or GRAY })
end

-- Sous-onglets du Classement (partagés par le classement général et l'écran Amis).
local function rank_tabs(redraw)
    local LB = require("core.leaderboard")
    return segmented({ { id = "general", label = T("Général") }, { id = "weekly", label = T("Semaine") },
                       { id = "works", label = T("Populaires") }, { id = "friends", label = T("Amis") } },
        _rtab, function(id)
            _rtab = id
            _rpage = 1
            redraw(true)
            local again = function() if _screen and _tab == "rank" then redraw(true) end end
            if id == "friends" then LB.refreshFriendsAsync(again)
            elseif id ~= "works" then LB.refreshAsync(id, again) end
        end)
end

-- Écran Amis : classement entre amis (toi inclus), demandes, recherche par pseudo.
local function build_friends(avail, redraw)
    local LB = require("core.leaderboard")
    local Friends = require("ui.friends")
    local st = LB.getState()
    local fr = st.friends or {}
    local incoming, outgoing = fr.incoming or {}, fr.outgoing or {}
    local me = Quests.getProgress()
    local my_name = LB.username()

    local list = {}
    for _, f in ipairs(fr.friends or {}) do
        local name, lvl, xp = player_fields(f)
        list[#list + 1] = { name = name, lvl = lvl, xp = xp }
    end
    list[#list + 1] = { name = T("%s (vous)"):format(my_name ~= "" and my_name or T("Vous")), lvl = me.level, xp = me.xp, me = true }
    table.sort(list, function(a, b) if a.xp ~= b.xp then return a.xp > b.xp end return a.name < b.name end)
    for i, e in ipairs(list) do e.rank = i end

    local FIXED = 12 + 40 + 12 + 30 + 4 + 12 + 30 + 10 + 34 + 8
    local nrows = math.max(1, math.min(#list, 10, math.floor((units(avail) - FIXED) / 34)))
    K = math.min(1, units(avail) / (FIXED + 34 * nrows))
    local shown = {}
    for i = 1, nrows do shown[i] = list[i] end
    local mine_shown = false
    for _, e in ipairs(shown) do if e.me then mine_shown = true end end
    if not mine_shown then for _, e in ipairs(list) do if e.me then shown[#shown] = e end end end

    local w = W - 2 * M
    local function again() if _screen and _tab == "rank" and _rtab == "friends" then redraw(true) end end
    local function run_online(fn)
        local okO, Online = pcall(require, "core.online")
        if okO and Online and Online.run then Online.run(fn) else fn() end
    end
    local function manual_refresh()
        run_online(function()
            local ok, err = LB.refreshFriends()
            if not ok then UIManager:show(InfoMessage:new{ text = err or T("Actualisation impossible."), timeout = 4 }) end
            again()
        end)
    end

    local rows = { rgap(sz(12)), rank_tabs(redraw), rgap(sz(12)) }

    local pad = sc(10)
    local inner = w - 2 * pad
    local c1, c3, c4 = sc(44), math.floor(inner * 0.2), math.floor(inner * 0.26)
    local c2 = inner - c1 - c3 - c4
    local function trow(a, b, c, d, o)
        o = o or {}
        local h = o.h or sz(32)
        local function cell(cw, t, mode) return slot(cw, h, text(t, 15, { bold = o.bold, max_w = cw - sc(4) }), mode) end
        local line = HorizontalGroup:new{ hgap(pad), cell(c1, a, "left"), cell(c2, b, "left"),
            cell(c3, c, "center"), cell(c4, d, "right"), hgap(pad) }
        return inset(FrameContainer:new{ bordersize = 0, margin = 0, padding = 0, background = o.bg or WHITE, line })
    end

    rows[#rows + 1] = trow("#", T("Ami"), T("Niveau"), T("XP totale"), { bold = true, h = sz(30) })
    rows[#rows + 1] = inset(hline(w))
    for _, e in ipairs(shown) do
        local r = trow(tostring(e.rank), e.name, tostring(e.lvl), fmt(e.xp), { bold = e.me, bg = e.me and PALE or WHITE })
        if e.me then rows[#rows + 1] = r
        else rows[#rows + 1] = P.wrapTappable(r, function() Friends.manage(e.name, e.lvl, function() again() end) end) end
        rows[#rows + 1] = inset(hline(w))
    end
    rows[#rows + 1] = rgap(sz(12))

    -- Ligne d'information
    local note
    if my_name == "" then note = T("Choisis d'abord ton pseudo dans l'onglet Général.")
    elseif #incoming > 0 then note = (#incoming > 1 and T("• %d demandes d'amis en attente") or T("• %d demande d'ami en attente")):format(#incoming)
    elseif st.friends_error and not fr.loaded then note = T(st.friends_error)
    elseif #(fr.friends or {}) == 0 then note = T("Aucun ami pour l'instant : cherche un joueur par son pseudo.")
    elseif #outgoing > 0 then note = (#outgoing > 1 and T("%d demandes envoyées, en attente de réponse") or T("%d demande envoyée, en attente de réponse")):format(#outgoing)
    else note = T("Touche un ami pour le retirer de ta liste.") end
    rows[#rows + 1] = inset(slot(w, sz(30), text(note, 14, { color = DARK, bold = #incoming > 0, max_w = w - sc(8) }), "center"))
    rows[#rows + 1] = rgap(sz(10))

    local function act(label, cb)
        local cw = math.floor((w - 2 * sc(6)) / 3)
        local f = FrameContainer:new{ bordersize = sc(1), color = GRAY, radius = sc(4), margin = 0, padding = 0, background = WHITE,
            slot(cw - 2 * sc(1), sz(34) - 2 * sc(1), text(label, 14, { bold = true, max_w = cw - sc(8) }), "center") }
        return P.wrapTappable(f, cb)
    end
    rows[#rows + 1] = inset(HorizontalGroup:new{
        act(T("Chercher"), function() Friends.search(function() again() end) end), hgap(sc(6)),
        act(T("Demandes (%d)"):format(#incoming), function() Friends.requests(function() again() end) end), hgap(sc(6)),
        act(T("↻ Actualiser"), manual_refresh),
    })
    rows[#rows + 1] = rgap(sz(8))
    return rows
end

local function build_rank(avail, redraw)
    if _rtab == "friends" then return build_friends(avail, redraw) end
    local LB = require("core.leaderboard")
    local st = LB.getState()
    local players = st.players or {}
    local works = st.works or {}
    local me = Quests.getProgress()
    local showing_works = _rtab == "works"
    local count = showing_works and #works or #players
    -- Classement : le podium (1 à 3) est au-dessus ; page 1 = rangs 4 à 10, page 2 = rangs 11 à 20.
    local paged = not showing_works and count > 10
    local npages = paged and 2 or 1
    _rpage = math.max(1, math.min(_rpage, npages))
    local first_row, last_row
    if showing_works then first_row, last_row = 1, math.min(count, 12)
    elseif _rpage == 1 then first_row, last_row = 4, math.min(count, 10)
    else first_row, last_row = 11, math.min(count, 20) end
    local show_podium = not showing_works and _rpage == 1
    local FIXED = 12 + 40 + 12 + (show_podium and PODIUM_H + 12 or 0) + 30 + 12 + (showing_works and 46 or 40 + 12) + 36 + 12 + (paged and 52 or 0)
    local nrows = math.max(0, last_row - first_row + 1)
    local fit = math.floor((units(avail) - FIXED) / 34)
    nrows = math.min(nrows, math.max(fit, 4))     -- l'échelle verticale (K) s'adapte si l'écran est petit
    last_row = first_row + nrows - 1
    K = math.min(1, units(avail) / (FIXED + 34 * nrows))
    local w = W - 2 * M
    local my_id, my_name = LB.selfId(), LB.username()
    local function is_me(pl)
        return pl and ((pl.player_id and pl.player_id == my_id) or (pl.id and pl.id == my_id)
            or (my_name ~= "" and (pl.username or pl.pseudo) == my_name)) and true or false
    end

    local function run_online(fn)
        local okO, Online = pcall(require, "core.online")
        if okO and Online and Online.run then Online.run(fn) else fn() end
    end
    local function manual_refresh()
        run_online(function()
            local ok, err = LB.refresh(_rtab == "weekly" and "weekly" or "general")
            if not ok then UIManager:show(InfoMessage:new{ text = err or T("Actualisation impossible."), timeout = 4 }) end
            if _screen and _tab == "rank" then redraw(true) end
        end)
    end

    local rows = { rgap(sz(12)), rank_tabs(redraw), rgap(sz(12)) }

    -- Podium 2 · 1 · 3
    if show_podium then
        local g = sc(8)
        local side_w = math.floor((w - 2 * g) * 0.31)
        local mid_w = w - 2 * g - 2 * side_w
        local hc, hs = sz(PODIUM_H), sz(PODIUM_H - 14)
        local function side(rank)
            return VerticalGroup:new{ align = "left", gap(hc - hs), podium_card(rank, players[rank], side_w, hs, is_me(players[rank])) }
        end
        rows[#rows + 1] = inset(HorizontalGroup:new{ side(2), hgap(g), podium_card(1, players[1], mid_w, hc, is_me(players[1])), hgap(g), side(3) })
        rows[#rows + 1] = rgap(sz(12))
    end

    -- Tableau
    local pad = sc(10)
    local inner = w - 2 * pad
    local c1, c3, c4 = sc(44), math.floor(inner * 0.2), math.floor(inner * 0.26)
    local c2 = inner - c1 - c3 - c4
    local function trow(a, b, c, d, o)
        o = o or {}
        local h = o.h or sz(32)
        local function cell(cw, t, mode)
            return slot(cw, h, text(t, 15, { bold = o.bold, max_w = cw - sc(4) }), mode)
        end
        local name_cell = o.creator and slot(c2, h, name_widget(b, true, 15, c2 - sc(4), o.bold), "left") or cell(c2, b, "left")
        local line = HorizontalGroup:new{ hgap(pad), cell(c1, a, "left"), name_cell,
            cell(c3, c, "center"), cell(c4, d, "right"), hgap(pad) }
        return inset(FrameContainer:new{ bordersize = 0, margin = 0, padding = 0, background = o.bg or WHITE, line })
    end

    if count == 0 then
        local msg = showing_works and T("Pas encore de statistiques communautaires.")
            or (st.error and T(st.error) or T("Aucun joueur dans le classement pour le moment."))
        rows[#rows + 1] = inset(card(w, sz(90), text(msg, 15, { color = DARK, max_w = w - sc(24) }), { center = true }))
        rows[#rows + 1] = rgap(sz(12))
    elseif showing_works then
        rows[#rows + 1] = trow("#", T("Œuvre"), "", T("Lecteurs"), { bold = true, h = sz(30) })
        rows[#rows + 1] = inset(hline(w))
        for i = first_row, last_row do
            local wk = works[i]
            rows[#rows + 1] = trow(tostring(i), tostring(wk.title or T("Œuvre")), "", tostring(tonumber(wk.readers) or 0))
            rows[#rows + 1] = inset(hline(w))
        end
        rows[#rows + 1] = rgap(sz(12))
        rows[#rows + 1] = rgap(sz(0))
    else
        rows[#rows + 1] = trow("#", T("Joueur"), T("Niveau"), T("XP totale"), { bold = true, h = sz(30) })
        rows[#rows + 1] = inset(hline(w))
        for i = first_row, last_row do
            local name, lvl, xp = player_fields(players[i])
            local mine_row = is_me(players[i])
            rows[#rows + 1] = trow(tostring(i), name, tostring(lvl), fmt(xp), { bold = mine_row, bg = mine_row and PALE or WHITE, creator = is_creator_pl(players[i], mine_row) })
            rows[#rows + 1] = inset(hline(w))
        end
        if paged then
            rows[#rows + 1] = rgap(sz(6))
            rows[#rows + 1] = pager(_rpage, npages,
                function() _rpage = _rpage - 1; redraw(true) end,
                function() _rpage = _rpage + 1; redraw(true) end)
        end
        rows[#rows + 1] = rgap(sz(12))
        local my_rank
        for i, pl in ipairs(players) do
            if is_me(pl) then my_rank = i; break end
        end
        rows[#rows + 1] = trow(my_rank and tostring(my_rank) or "—", T("Vous"), tostring(me.level), fmt(me.xp),
            { bold = true, bg = PALE, h = sz(40), creator = is_creator_pl(nil, true) })
        rows[#rows + 1] = rgap(sz(12))
    end

    if showing_works then
    local hidden = LB.worksHidden()
    local hf = FrameContainer:new{ bordersize = sc(1), color = GRAY, radius = sc(4), margin = 0, padding = 0, background = hidden and PALE or WHITE,
        slot(w - 2 * sc(1), sz(34) - 2 * sc(1), text(hidden and T("Mes œuvres : masquées (toucher pour réafficher)") or T("Masquer mes œuvres dans Populaires"), 14, { bold = true, max_w = w - sc(16) }), "center") }
    rows[#rows + 1] = inset(P.wrapTappable(hf, function()
        LB.setWorksHidden(not hidden)
        if not hidden then
            UIManager:show(InfoMessage:new{ text = T("Tes œuvres seront retirées de Populaires à la prochaine actualisation."), timeout = 4 })
        end
        redraw(true)
        if not hidden then manual_refresh() end
    end))
    rows[#rows + 1] = rgap(sz(12))
    end

    -- Actions : actualiser / pseudo / serveur
    local function act(label, cb)
        local cw = math.floor((w - 2 * sc(6)) / 3)
        local f = FrameContainer:new{ bordersize = sc(1), color = GRAY, radius = sc(4), margin = 0, padding = 0, background = WHITE,
            slot(cw - 2 * sc(1), sz(34) - 2 * sc(1), text(label, 14, { bold = true }), "center") }
        return P.wrapTappable(f, cb)
    end
    local b1 = act(T("↻ Actualiser"), manual_refresh)
    local b2 = act(T("Pseudo"), function()
        LB.configure("leaderboard_username", T("Pseudo public"), function()
            redraw(true)
            manual_refresh()      -- nouveau pseudo : envoi immédiat puis rafraîchissement
        end)
    end)
    local b3 = act(T("Serveur"), function()
        LB.configure("leaderboard_url", T("URL de l'API (ex. https://mon-serveur.example)"), function() redraw(true) end)
    end)
    rows[#rows + 1] = inset(HorizontalGroup:new{ b1, hgap(sc(6)), b2, hgap(sc(6)), b3 })
    rows[#rows + 1] = rgap(sz(8))
    return rows
end

-- ── Assemblage ──────────────────────────────────────────────────────────────
local function close_screen()
    if _screen then UIManager:close(_screen); _screen = nil end
end
local function close_all()
    close_screen()
    if _G.sefirah_close_all then _G.sefirah_close_all() end
end
local function back()
    close_screen()
    require("ui.main_widget").show("settings")
end

local redraw
local function rank_autorefresh()
    pcall(function()
        local LB = require("core.leaderboard")
        local again = function() if _screen and _tab == "rank" then redraw(true) end end
        if _rtab == "friends" then LB.refreshFriendsAsync(again) else LB.autoRefresh(again) end
    end)
end
local function go(tab)
    _tab = tab
    redraw(false)
    if tab == "rank" then rank_autorefresh() end
end

local META = {
    progress = { "CENTRE DE PROGRESSION", "Lire. Progresser. Aller plus loin.", "hdr_bars" },
    quests   = { "JOURNAL DE QUÊTES", "Des lectures d'aujourd'hui pour de plus grands horizons.", "hdr_quests" },
    rank     = { "CLASSEMENT", "Une communauté de lecteurs, plus loin ensemble.", "hdr_bars" },
    achv     = { "SUCCÈS", "Des défis difficiles pour les lecteurs d'exception.", "medal" },
}

local function build_body()
    local avail = P.H - HDR_H - TAB_H - 2 * P.HAIRLINE
    local rows
    _rg = {}
    if _tab == "quests" then rows = build_quests(avail, redraw)
    elseif _tab == "rank" then rows = build_rank(avail, redraw)
    elseif _tab == "achv" then rows = build_achv(avail, redraw)
    else rows = build_progress(avail, go, redraw) end
    -- Répartit la hauteur restante entre les espaces de rangée : plus de « trou blanc » en bas.
    do
        local used = 0
        for _, r in ipairs(rows) do used = used + r:getSize().h end
        local extra = avail - used
        if extra > 0 and #_rg > 0 then
            local per = math.min(math.floor(extra / #_rg), sz(40))
            for _, g in ipairs(_rg) do g.width = g.width + per end
        end
    end
    local m = META[_tab] or META.progress
    return VerticalGroup:new{ align = "left",
        make_header(T(m[1]), T(m[2]), m[3], back),
        P.hairline(),
        FrameContainer:new{ bordersize = 0, margin = 0, padding = 0, width = W, height = avail, P.contentFrame(rows, avail) },
        P.hairline(),
        make_tabbar(_tab, go),
    }
end

redraw = function(same_tab)
    local body = build_body()
    if _screen then
        _screen:swapBody(body, close_all, same_tab)
    else
        _screen = P.showFreePanel(body, close_all)
    end
end

function Progress.show(tab)
    close_screen()
    _tab = tab or "progress"
    redraw(false)
    if _tab == "rank" then rank_autorefresh() end
    -- Première ouverture du centre de progression : on explique tout (comme le bouton « i »).
    if Settings:get("progress_help_seen") ~= true then
        Settings:set("progress_help_seen", true)
        UIManager:scheduleIn(0.3, show_help)
    end
end

return Progress
