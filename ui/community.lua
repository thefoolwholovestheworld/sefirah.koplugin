-- Communauté Sefirah — interface e-ink monochrome, données uniquement depuis le serveur.
local P = require("ui.panel")
local Model = require("community_model")
local LB = require("core.leaderboard")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local ImageWidget = require("ui/widget/imagewidget")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local LineWidget = require("ui/widget/linewidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local T = require("core.i18n").T
local Community = {}
local _screen, _tab, _peer, _revealed = nil, "feed", nil, {}
local _page, _filter = { feed = 1, friends = 1, messages = 1 }, ""
local _from, _off, _spoiler = "messages", 0, false
local _input, _kb_h = nil, 0
local function sc(n) return Device.screen:scaleBySize(n) end
local function say(s) UIManager:show(InfoMessage:new{text=tostring(s or "Erreur inconnue"), timeout=5}) end
local function online(fn)
    local ok, O = pcall(require, "core.online")
    if ok and O and O.run then O.run(fn) else fn() end
end
local function request(label, fn, done)
    online(function()
        local wait = InfoMessage:new{text=label or T("Connexion…")}
        UIManager:show(wait)
        UIManager:scheduleIn(0.12, function()
            local ok, a, b = pcall(fn)
            UIManager:close(wait)
            if not ok then a, b = nil, tostring(a) end
            done(a, b)
        end)
    end)
end
local redraw
local function titlebar(tab)
    return {id=tab,label=({feed=T("Fil"),friends=T("Amis"),messages=T("Messages")})[tab]}
end
local function card(rows)
    return FrameContainer:new{
        bordersize=sc(1), color=Blitbuffer.COLOR_GRAY, radius=sc(5),
        margin=sc(4), padding=sc(5), background=Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{align="left", table.unpack(rows)},
    }
end
local function input(title, value, hint, submit)
    local dlg
    dlg = InputDialog:new{title=title, input=value or "", input_hint=hint or "", buttons={{
        {text=T("Annuler"),callback=function() UIManager:close(dlg) end},
        {text=T("Valider"),is_enter_default=true,callback=function()
            local v=dlg:getInputText(); UIManager:close(dlg); submit(v)
        end},
    }}}
    UIManager:show(dlg); dlg:onShowKeyboard()
end
local function menu(title, options)
    local dlg; local buttons={}
    for _, item in ipairs(options) do
        buttons[#buttons+1]={{text=item[1],callback=function()
            UIManager:close(dlg); if item[2] then item[2]() end
        end}}
    end
    dlg=ButtonDialog:new{title=title,title_align="center",buttons=buttons}; UIManager:show(dlg)
end
local function show_book_picker()
    local DB=require("core.db")
    local novels=DB.getAll() or {}
    if #novels==0 then say(T("Ta bibliothèque est vide : ajoute un livre avant de publier.")); return end
    local opts={}
    for i,n in ipairs(novels) do
        if i>30 then break end
        local novel=n
        opts[#opts+1]={tostring(novel.title or T("Livre sans titre")),function()
            local d=Model.draft(); d.book={title=tostring(novel.title or ""),author=tostring(novel.author or "")}; Model.saveDraft(d)
            compose_review()
        end}
    end
    opts[#opts+1]={T("Annuler")}; menu(T("Choisir un livre"),opts)
end
function compose_review()
    local d=Model.draft()
    if not (d.book and d.book.title) then show_book_picker(); return end
    input(T("Ton avis sur ")..d.book.title,d.text,T("Écris ton avis…"),function(text)
        if text:gsub("%s","")=="" then say(T("Écris ton avis avant de continuer.")); return end
        d.text=text; Model.saveDraft(d)
        input(T("Citer un passage (facultatif)"),d.quote,T("Citation, 600 caractères max"),function(quote)
            d.quote=quote:sub(1,600); Model.saveDraft(d); publish_options()
        end)
    end)
end
function publish_options()
    local d=Model.draft(); local opts={}
    for rating=1,5 do
        local r=rating
        opts[#opts+1]={T("Note : ")..string.rep("★",r)..string.rep("☆",5-r),function()
            d.rating=r; Model.saveDraft(d); publish_options()
        end}
    end
    opts[#opts+1]={T("Audience : ")..(d.audience=="public" and T("Tout le monde") or T("Mes amis")),function()
        d.audience=d.audience=="public" and "friends" or "public"; Model.saveDraft(d); publish_options()
    end}
    opts[#opts+1]={d.spoiler and T("Spoilers : oui") or T("Contient des spoilers : non"),function()
        d.spoiler=not d.spoiler; Model.saveDraft(d); publish_options()
    end}
    if d.rating and d.rating>0 then
        opts[#opts+1]={T("Publier"),function()
            request(T("Publication…"),function() return Model.publish() end,function(post,err)
                if not post then say(err); return end
                say(T("Publication envoyée.")); redraw()
            end)
        end}
    end
    opts[#opts+1]={T("Modifier mon avis"),compose_review}; opts[#opts+1]={T("Annuler")}
    menu(T("Créer un post").." · "..d.book.title,opts)
end
local function comments(post)
    request(T("Chargement des commentaires…"),function() return Model.comments(post.id) end,function(items,err)
        if not items then say(err); return end
        local opts={}
        for _,c in ipairs(items) do opts[#opts+1]={tostring(c.username or "?")..": "..tostring(c.text or ""),nil} end
        opts[#opts+1]={T("Ajouter un commentaire"),function()
            input(T("Commenter"),"",T("Ton commentaire…"),function(text)
                request(T("Envoi…"),function() return Model.comment(post.id,text,Model.nonce()) end,function(res,e)
                    if not res then say(e) else say(T("Commentaire envoyé.")); comments(post) end
                end)
            end)
        end}
        opts[#opts+1]={T("Fermer")}; menu(T("Commentaires"),opts)
    end)
end

-- ── Mise en page « maquette » : onglets en haut, cartes avec avatar ─────────────────────────
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY, LGRAY, DARK, PALE = Blitbuffer.Color8(0x88), Blitbuffer.Color8(0xBB), Blitbuffer.COLOR_DARK_GRAY, Blitbuffer.Color8(0xE6)
local ROOT = (debug.getinfo(1, "S").source or ""):match("^@(.+)/ui/community%.lua$") or ""
local W, M = P.W, Device.screen:scaleBySize(14)
local TABS_H, GAP = P.CUSTOM_TAB_H, sc(8)
local function txt(s, size, o)
    o = o or {}
    return TextWidget:new{ text = tostring(s), bold = o.bold, fgcolor = o.color or BLACK, max_width = o.max_w,
        face = Font:getFace("cfont", size) }
end
local function slot(w, h, child, mode)
    local C = (mode == "center" and CenterContainer) or (mode == "right" and RightContainer) or LeftContainer
    return C:new{ dimen = Geom:new{ w = w, h = h }, child }
end
local function hgap(w) return HorizontalSpan:new{ width = w } end
local function vgap(h) return VerticalSpan:new{ width = h } end
local function inset(w) return HorizontalGroup:new{ hgap(M), w } end
local function avatar(size)
    return ImageWidget:new{ file = ROOT .. "/resources/progress/avatar.png", width = size, height = size,
        scale_factor = 0, original_in_nightmode = false }
end
local function ago(ts)
    local d = os.time() - (tonumber(ts) or os.time())
    if d < 60 then return T("À l'instant") end
    if d < 3600 then return T("Il y a %d min"):format(math.floor(d / 60)) end
    if d < 86400 then return T("Il y a %d h"):format(math.floor(d / 3600)) end
    return T("Il y a %d j"):format(math.floor(d / 86400))
end
local function clock(ts)
    ts = tonumber(ts); if not ts then return "" end
    if os.date("%Y-%m-%d", ts) == os.date("%Y-%m-%d") then return os.date("%H:%M", ts) end
    if os.date("%Y-%m-%d", ts) == os.date("%Y-%m-%d", os.time() - 86400) then return T("Hier") end
    if os.time() - ts < 6 * 86400 then
        return T(({ "Dim", "Lun", "Mar", "Mer", "Jeu", "Ven", "Sam" })[tonumber(os.date("%w", ts)) + 1])
    end
    return os.date("%d/%m", ts)
end
local function box(w, h, child, o)
    o = o or {}
    local b = sc(1)
    return FrameContainer:new{ bordersize = b, color = o.color or GRAY, radius = sc(6), margin = 0, padding = 0,
        background = o.bg or WHITE, LeftContainer:new{ dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b }, child } }
end
-- Carte de liste : avatar, texte (VerticalGroup fourni), chevron optionnel.
local function list_card(h, body_fn, chevron, cb, hold)
    local w = W - 2 * M
    local av, chw = sc(50), chevron and sc(30) or 0
    local bw = w - 2 * sc(1) - sc(12) - av - sc(12) - chw - sc(6)
    local row = HorizontalGroup:new{ hgap(sc(12)), slot(av, h, avatar(av), "center"), hgap(sc(12)),
        slot(bw, h, body_fn(bw), "left"),
        chevron and slot(chw, h, txt("›", 28, { bold = true }), "center") or hgap(0) }
    return inset(P.wrapTappable(box(w, h, row), cb, hold))
end
local function line(left, right, bw, size, o)
    o = o or {}
    local rw = right and (right:getSize().w + sc(8)) or 0
    return HorizontalGroup:new{ slot(bw - rw, left:getSize().h, left, "left"),
        right and slot(rw, left:getSize().h, right, "right") or hgap(0) }
end
local function button(label, w, cb, hold)
    local h = sc(48)
    local f = box(w, h, CenterContainer:new{ dimen = Geom:new{ w = w - 2 * sc(1), h = h - 2 * sc(1) }, txt(label, 17, { bold = true }) })
    return P.wrapTappable(f, cb, hold)
end
local function top_tabs(active, switch)
    local ids = { "feed", "friends", "messages" }
    local cw = math.floor(W / 3)
    local cells = {}
    for i, id in ipairs(ids) do
        local on, w = id == active, (i == 3) and (W - 2 * cw) or cw
        local ind = LineWidget:new{ dimen = Geom:new{ w = w - 2 * M, h = on and sc(4) or sc(1) }, background = on and BLACK or LGRAY }
        local label = slot(w, TABS_H - sc(8), txt(titlebar(id).label, on and 22 or 20, { bold = on, color = on and BLACK or DARK }), "center")
        local cell = VerticalGroup:new{ align = "center", HorizontalGroup:new{ hgap(M), ind }, label }
        cells[#cells + 1] = on and cell or P.wrapTappable(cell, function() switch(id) end)
    end
    return HorizontalGroup:new(cells)
end
local function pager(tab, total, per, redraw_fn)
    local pages = math.max(1, math.ceil(total / per))
    _page[tab] = math.max(1, math.min(_page[tab], pages))
    if pages == 1 then return nil end
    local w = W - 2 * M
    local cw = math.floor(w / 3)
    local function cell(wd, label, cb)
        local f = box(wd, sc(40), CenterContainer:new{ dimen = Geom:new{ w = wd - 2 * sc(1), h = sc(38) }, txt(label, 15, { bold = not cb }) },
            { color = cb and GRAY or LGRAY })
        return cb and P.wrapTappable(f, cb) or f
    end
    local p = _page[tab]
    return inset(HorizontalGroup:new{
        cell(cw, p > 1 and T("‹ Précédent") or " ", p > 1 and function() _page[tab] = p - 1; redraw_fn() end or nil),
        cell(w - 2 * cw, p .. " / " .. pages, nil),
        cell(cw, p < pages and T("Suivant ›") or " ", p < pages and function() _page[tab] = p + 1; redraw_fn() end or nil),
    })
end
local function slice(list, tab, per)
    local out, p = {}, _page[tab]
    for i = (p - 1) * per + 1, math.min(#list, p * per) do out[#out + 1] = list[i] end
    return out
end
local function stars(n)
    n = math.max(0, math.min(5, tonumber(n) or 0))
    return string.rep("★", n) .. string.rep("☆", 5 - n)
end

local function post_menu(post)
    menu(T("Publication"), {
        { post.liked and T("Retirer J’aime") or T("J’aime"), function()
            request(T("Mise à jour…"), function() return Model.like(post.id) end, function(ok, err) if not ok then say(err) end; redraw() end)
        end },
        { T("Voir / commenter"), function() comments(post) end },
        { T("Fermer") },
    })
end
local function configure_server()
    input(T("URL du serveur communautaire"), Model.server(), T("https://ton-worker.example.workers.dev"), function(url)
        local ok, err = Model.setServer(url)
        if not ok then say(err); return end
        say(T("Serveur enregistré. Actualise le fil pour vérifier l’API.")); redraw()
    end)
end
local function refresh_btn(w, label, fn, label_wait)
    return button(label, w, function() request(label_wait, fn, function(ok, err) if not ok then say(err) end; redraw() end) end,
        configure_server)
end

local function open_chat(name, from)
    _peer, _from, _off = name, from or "messages", 0
    request(T("Chargement des messages…"), function() return Model.refreshMessages(name) end,
        function(ok, err) if not ok then say(err) end; redraw() end)
end

local function build_feed(avail)
    local w = W - 2 * M
    local rows = { vgap(sc(10)) }
    local half = math.floor((w - sc(8)) / 2)
    rows[#rows + 1] = inset(HorizontalGroup:new{
        button(T("✎  Créer un post"), half, compose_review), hgap(sc(8)),
        refresh_btn(w - half - sc(8), T("↻  Actualiser"), function() return Model.refreshFeed() end, T("Chargement du fil…")) })
    rows[#rows + 1] = vgap(GAP + sc(2))
    local posts, ch = Model.posts(), sc(92)
    local used = sc(10) + sc(48) + GAP + sc(2) + sc(48)
    local per = math.max(2, math.floor((avail - used) / (ch + GAP)))
    if #posts == 0 then
        rows[#rows + 1] = inset(txt(T("Aucune publication. Actualise le fil ou publie ton avis."), 16, { color = DARK, max_w = w }))
    end
    for _, post in ipairs(slice(posts, "feed", per)) do
        local book = type(post.book) == "table" and post.book or {}
        local title = tostring(book.title or post.book_title or T("Livre"))
        rows[#rows + 1] = list_card(ch, function(bw)
            return VerticalGroup:new{ align = "left",
                line(txt(tostring(post.username or T("Lecteur")), 19, { bold = true, max_w = math.floor(bw * 0.55) }),
                    txt(ago(post.created_at), 13, { color = DARK }), bw),
                txt(T("a publié un avis sur"), 14, { color = DARK, max_w = bw }),
                line(txt(title, 16, { bold = true, max_w = bw - sc(90) }),
                    txt(stars(post.rating), 14), bw) }
        end, false, function() post_menu(post) end)
        rows[#rows + 1] = vgap(GAP)
    end
    local pg = pager("feed", #posts, per, redraw)
    if pg then rows[#rows + 1] = pg end
    return rows
end

local function build_friends(avail)
    local fr = LB.getState().friends or {}
    local friends, w = fr.friends or {}, W - 2 * M
    local rows = { vgap(sc(10)) }
    local bw_add = sc(130)
    local search_w = w - bw_add - sc(8)
    local sf = box(search_w, sc(48), HorizontalGroup:new{ hgap(sc(12)),
        txt("⌕  " .. (_filter ~= "" and _filter or T("Rechercher un ami…")), 16, { color = _filter ~= "" and BLACK or DARK, max_w = search_w - sc(24) }) })
    rows[#rows + 1] = inset(HorizontalGroup:new{
        P.wrapTappable(sf, function()
            input(T("Rechercher un ami"), _filter, T("Pseudo"), function(v) _filter = (v or ""):gsub("^%s+", ""):gsub("%s+$", ""); _page.friends = 1; redraw(true) end)
        end),
        hgap(sc(8)),
        button(T("+  Ajouter"), bw_add, function() require("ui.friends").search(redraw) end,
            function() pcall(LB.refreshFriendsAsync, function() redraw(true) end) end) })
    rows[#rows + 1] = vgap(GAP + sc(2))
    -- Statistiques : amis, demandes envoyées, demandes reçues.
    local incoming, outgoing = fr.incoming or {}, fr.outgoing or {}
    local cw3, sh = math.floor((w - 2 * sc(1)) / 3), sc(66)
    local function stat(n, label, cb)
        local c = slot(cw3, sh, VerticalGroup:new{ align = "center", txt(tostring(n), 22, { bold = true }), txt(label, 14, { color = DARK }) }, "center")
        return cb and P.wrapTappable(c, cb) or c
    end
    local function sep() return LineWidget:new{ dimen = Geom:new{ w = sc(1), h = sh - sc(20) }, background = LGRAY } end
    rows[#rows + 1] = inset(box(w, sh + sc(2), HorizontalGroup:new{
        stat(#friends, T("Amis")), slot(sc(1), sh, sep(), "center"),
        stat(#outgoing, T("Envoyées")), slot(sc(1), sh, sep(), "center"),
        stat(#incoming, T("Reçues"), #incoming > 0 and function() require("ui.friends").requests(redraw) end or nil) }))
    rows[#rows + 1] = vgap(GAP + sc(2))
    local list = {}
    for _, f in ipairs(friends) do
        local name = tostring(f.username or f.name or "")
        if name ~= "" and (_filter == "" or name:lower():find(_filter:lower(), 1, true)) then list[#list + 1] = f end
    end
    table.sort(list, function(a, b) return (tonumber(a.xp) or 0) > (tonumber(b.xp) or 0) end)
    local ch = sc(74)
    local used = sc(10) + sc(48) + GAP + sc(2) + sh + sc(2) + GAP + sc(2) + sc(48)
    local per = math.max(2, math.floor((avail - used) / (ch + GAP)))
    if #list == 0 then
        local msg = #friends == 0 and T("Aucun ami pour l'instant. Touche « Ajouter » pour en inviter.") or T("Aucun ami ne correspond à cette recherche.")
        rows[#rows + 1] = inset(txt(msg, 16, { color = DARK, max_w = w }))
    end
    for _, f in ipairs(slice(list, "friends", per)) do
        local name = tostring(f.username or f.name)
        local level = math.max(1, tonumber(f.level) or require("core.progression").level(f.xp))
        rows[#rows + 1] = list_card(ch, function(bw)
            return VerticalGroup:new{ align = "left",
                line(txt(name, 19, { bold = true, max_w = bw - sc(110) }), txt((tonumber(f.xp) or 0) .. " XP", 16), bw),
                txt(T("Niveau %d"):format(level), 15, { color = DARK }) }
        end, true, function() open_chat(name, "friends") end,
        function() require("ui.friends").manage(name, level, redraw) end)
        rows[#rows + 1] = vgap(GAP)
    end
    local pg = pager("friends", #list, per, redraw)
    if pg then rows[#rows + 1] = pg end
    return rows
end

local function send_message()
    if not _peer then say(T("Choisis un ami d’abord.")); return end
    local d = Model.messageDraft(_peer)
    input(T("Message à ") .. _peer, d.text, T("Écrire un message…"), function(text)
        if text:gsub("%s", "") == "" then return end
        d.text = text
        menu(T("Options du message"), {
            { d.spoiler and T("Spoiler : oui") or T("Masquer comme spoiler"), function()
                d.spoiler = not d.spoiler
                request(T("Envoi du message…"), function() return Model.send(_peer, text, d.spoiler) end, function(ok, err)
                    if not ok then say(err) else say(T("Message envoyé.")) end; redraw()
                end)
            end },
            { T("Envoyer sans spoiler"), function()
                request(T("Envoi du message…"), function() return Model.send(_peer, text, false) end, function(ok, err)
                    if not ok then say(err) else say(T("Message envoyé.")) end; redraw()
                end)
            end },
            { T("Annuler") },
        })
    end)
end

local function build_messages(avail)
    local w = W - 2 * M
    if not _peer then
        local rows = { vgap(sc(10)),
            inset(refresh_btn(w, T("↻  Actualiser les conversations"), function() return Model.refreshConversations() end, T("Chargement…"))),
            vgap(GAP + sc(2)) }
        local conv, ch = Model.conversations(), sc(82)
        local used = sc(10) + sc(48) + GAP + sc(2) + sc(48)
        local per = math.max(2, math.floor((avail - used) / (ch + GAP)))
        if #conv == 0 then
            rows[#rows + 1] = inset(txt(T("Aucune conversation. Ouvre l’onglet Amis et choisis un ami."), 16, { color = DARK, max_w = w }))
        end
        for _, c in ipairs(slice(conv, "messages", per)) do
            local name = tostring(c.peer or "")
            local msgs = Model.messages(name)
            local last = msgs[#msgs]
            local preview = last and (last.spoiler and T("Spoiler masqué") or tostring(last.text or "")) or T("Toucher pour ouvrir la conversation")
            rows[#rows + 1] = list_card(ch, function(bw)
                return VerticalGroup:new{ align = "left",
                    line(txt(name, 19, { bold = true, max_w = bw - sc(90) }), txt(clock(c.updated_at), 14, { color = DARK }), bw),
                    txt((preview:gsub("\n", " ")), 15, { color = DARK, max_w = bw }) }
            end, true, function() open_chat(name, "messages") end)
            rows[#rows + 1] = vgap(GAP)
        end
        local pg = pager("messages", #conv, per, redraw)
        if pg then rows[#rows + 1] = pg end
        return rows
    end
    return {}
end

-- Écran de discussion : bulles (moi à droite, l'ami à gauche), saisie en bas.
local COMPOSER_H = sc(66)
local function bubble(m, mine)
    local hidden = m.spoiler and not _revealed[m.id]
    local body = hidden and T("Spoiler masqué — toucher pour afficher") or tostring(m.text or "")
    local maxw = math.floor(W * 0.72)
    local pad = sc(10)
    local tw = maxw - 2 * pad - 2 * sc(1)
    local face = Font:getFace("cfont", 17)
    local content
    local one = TextWidget:new{ text = body, face = face, fgcolor = BLACK }
    if not body:find("\n") and one:getSize().w <= tw then content = one
    else
        one:free()
        content = TextBoxWidget:new{ text = body, face = face, width = tw, fgcolor = BLACK }
    end
    local stamp = txt(clock(m.created_at), 12, { color = DARK })
    local inner_w = math.max(content:getSize().w, stamp:getSize().w)
    local f = FrameContainer:new{ bordersize = sc(1), color = GRAY, radius = sc(14), margin = 0, padding = pad,
        background = mine and PALE or WHITE,
        VerticalGroup:new{ align = "left", content, vgap(sc(3)), slot(inner_w, stamp:getSize().h, stamp, "right") } }
    local h = f:getSize().h
    local wrapped = hidden and P.wrapTappable(f, function() _revealed[m.id] = true; redraw(true) end) or f
    if mine then return HorizontalGroup:new{ slot(W - M, h, wrapped, "right") } end
    return HorizontalGroup:new{ hgap(M), slot(W - M, h, wrapped, "left") }
end
local function close_input()
    local i = _input
    _input, _kb_h = nil, 0
    if _screen then _screen.is_always_active = nil end
    if i then
        pcall(function() i:onCloseKeyboard() end)
        pcall(function() if i.keyboard then UIManager:close(i.keyboard) end end)
    end
end
-- Secours : ancienne fenêtre de saisie, si la saisie intégrée n'est pas disponible.
local function send_text(peer, text)
    online(function()
        UIManager:scheduleIn(0.05, function()
            local ok, res, err = pcall(Model.send, peer, text, _spoiler)
            if not ok then res, err = nil, tostring(res) end
            if not res then say(err or T("Envoi impossible.")) else _spoiler = false; _off = 0 end
            if _screen then redraw(true) end
        end)
    end)
end
local function dialog_send()
    local peer = _peer
    local d = Model.messageDraft(peer)
    input(T("Message à ") .. peer, d.text, T("Écrire un message…"), function(text)
        if text:gsub("%s", "") == "" then return end
        send_text(peer, text)
    end)
end
local function do_send()
    local text = _input and _input:getText() or ""
    local peer = _peer
    if not peer or text:gsub("%s", "") == "" then return end
    close_input(); redraw(true)
    send_text(peer, text)
end
local function start_input()
    if _input then return end
    local peer = _peer
    local ok = pcall(function()
        local InputText = require("ui/widget/inputtext")
        if _screen and not _screen.onSwitchFocus then _screen.onSwitchFocus = function() return true end end
        -- Clavier ouvert = widget modal : sans ce drapeau, KOReader ne transmet plus les appuis
        -- à cet écran et le bouton « Envoyer » (hors du clavier) ne réagit à rien.
        if _screen then _screen.is_always_active = true end
        local fw = W - 2 * M - sc(56) - sc(96) - 2 * sc(8)
        _input = InputText:new{ text = Model.messageDraft(peer).text or "", hint = T("Écrire un message…"),
            face = Font:getFace("cfont", 17), width = fw - sc(24), scroll = false, focused = true,
            parent = _screen, bordersize = 0, padding = sc(4), margin = 0,
            enter_callback = function() pcall(do_send) end }
        _input:onShowKeyboard()
        local kb = _input.keyboard
        local kh = kb and ((kb.dimen and kb.dimen.h) or kb.height or (kb.getSize and kb:getSize().h)) or 0
        _kb_h = tonumber(kh) or 0
    end)
    if not ok or not _input then close_input(); dialog_send(); return end
    redraw(true)
end
local function composer()
    local w = W - 2 * M
    local tog, send_w = sc(56), sc(96)
    local fw = w - tog - send_w - 2 * sc(8)
    local inner = _input or txt(T("Écrire un message…"), 16, { color = DARK, max_w = fw - sc(24) })
    local field = box(fw, sc(48), HorizontalGroup:new{ hgap(sc(10)), inner })
    local toggle = box(tog, sc(48), CenterContainer:new{ dimen = Geom:new{ w = tog - 2 * sc(1), h = sc(46) },
        txt(_spoiler and "◉" or "○", 22, { bold = true }) }, { bg = _spoiler and PALE or WHITE })
    local send = box(send_w, sc(48), CenterContainer:new{ dimen = Geom:new{ w = send_w - 2 * sc(1), h = sc(46) },
        txt(T("Envoyer"), 16, { bold = true }) })
    return VerticalGroup:new{ align = "left", P.hairline(), slot(W, COMPOSER_H - P.HAIRLINE, inset(HorizontalGroup:new{
        P.wrapTappable(toggle, function()
            _spoiler = not _spoiler
            say(_spoiler and T("Prochain message masqué comme spoiler.") or T("Spoiler désactivé."))
            redraw(true)
        end),
        hgap(sc(8)),
        _input and field or P.wrapTappable(field, start_input),
        hgap(sc(8)),
        P.wrapTappable(send, function() if _input then do_send() else start_input() end end) }), "center") }
end
local function build_chat()
    local avail = P.H - P.TITLE_H - P.HAIRLINE - COMPOSER_H - _kb_h
    local msgs = Model.messages(_peer)
    local top_h = sc(44)
    local items, used = {}, 0
    local last = #msgs - _off
    local first = last + 1
    for i = last, 1, -1 do
        local b = bubble(msgs[i], LB.username() == tostring(msgs[i].username or ""))
        local h = b:getSize().h + sc(8)
        if used + h > avail - top_h - sc(10) and #items > 0 then break end
        table.insert(items, 1, b); used = used + h; first = i
    end
    local rows = { vgap(sc(6)) }
    local shown = #items
    local older, newer = first > 1, _off > 0
    if older or newer then
        local half = math.floor((W - 2 * M - sc(8)) / 2)
        local function nav(label, cb, on)
            if not on then return hgap(half) end
            return button(label, half, cb)
        end
        rows[#rows + 1] = inset(HorizontalGroup:new{
            nav(T("↑  Plus anciens"), function() _off = _off + math.max(1, shown); redraw(true) end, older), hgap(sc(8)),
            nav(T("↓  Plus récents"), function() _off = math.max(0, _off - math.max(1, shown)); redraw(true) end, newer) })
        rows[#rows + 1] = vgap(sc(6))
    end
    if #msgs == 0 then
        rows[#rows + 1] = inset(txt(T("Aucun message. Écris le premier !"), 16, { color = DARK, max_w = W - 2 * M }))
    end
    for _, b in ipairs(items) do rows[#rows + 1] = b; rows[#rows + 1] = vgap(sc(8)) end
    return VerticalGroup:new{ align = "left",
        P.makeTitleBar(_peer, function() close_input(); _peer = nil; _tab = _from; redraw(false) end, nil), P.hairline(),
        P.contentFrame(rows, avail), composer() }
end

local function on_back()
    Community.close(); require("ui.main_widget").show("settings")
end
local function build(tab)
    if _peer then return build_chat() end
    local avail = P.H - P.TITLE_H - P.HAIRLINE - TABS_H
    local rows
    if tab == "friends" then rows = build_friends(avail) elseif tab == "messages" then rows = build_messages(avail) else rows = build_feed(avail) end
    return VerticalGroup:new{ align = "left",
        P.makeTitleBar(T("Communauté"), on_back, nil), P.hairline(),
        P.contentFrame(rows, avail),
        P.makeCustomTabBar({ titlebar("feed"), titlebar("friends"), titlebar("messages") }, tab, function(id) _tab = id; redraw(true)
            if id == "friends" then pcall(LB.refreshFriendsAsync, function() if _screen and _tab == "friends" and not _peer then redraw(true) end end) end
        end) }
end
redraw = function(same)
    local body = build(_tab)
    local close = function() Community.close(); require("ui.main_widget").show("settings") end
    if _screen then _screen:swapBody(body, close, same)
    else _screen = P.showFreePanel(body, close) end
end
function Community.close() close_input(); if _screen then UIManager:close(_screen); _screen = nil end; _peer = nil end
function Community.show(tab)
    Community.close(); _tab = tab or "feed"; _revealed = {}; _filter = ""; _page = { feed = 1, friends = 1, messages = 1 }
    redraw(false)
    if _tab == "friends" then pcall(LB.refreshFriendsAsync, function() if _screen and _tab == "friends" then redraw(true) end end) end
end
return Community
