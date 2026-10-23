-- ui/anilist_list.lua — « Ma liste AniList » : statuts, chapitres lus, +1/−1…
local UIManager    = require("ui/uimanager")
local Menu         = require("ui/widget/menu")
local InfoMessage  = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog  = require("ui/widget/inputdialog")
local Device       = require("device")
local T            = require("core.i18n").T
local AniList      = require("core.anilist")
local Online       = require("core.online")

local List = {}

local STATUSES = {
    { "CURRENT",   "En cours" },
    { "PLANNING",  "Planifiés" },
    { "COMPLETED", "Terminés" },
    { "PAUSED",    "En pause" },
    { "DROPPED",   "Abandonnés" },
    { "REPEATING", "Relecture" },
}
local function status_label(code)
    for _, s in ipairs(STATUSES) do if s[1] == code then return T(s[2]) end end
    return code
end

local _menu, _data
local _in_list = {}   -- media_id -> entrée de ma liste (pour repérer les titres déjà suivis)

local function msg(text, timeout) UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 }) end

local function fail(err)
    if err == "réseau" then
        Online.explain_failure()
        if AniList.last_error then msg(AniList.last_error, 6) end
    elseif err == "jeton refusé" then msg(T("Jeton AniList refusé : génère-en un nouveau."), 5)
    else msg(T("AniList : ") .. tostring(err), 5) end
end

local show_main, show_lists, show_status, show_media_list

local function find_entry(e)
    -- Retire l'entrée de sa liste actuelle (changement de statut).
    for st, arr in pairs(_data.lists) do
        for i, x in ipairs(arr) do
            if x == e then table.remove(arr, i); return st end
        end
    end
end

-- Applique une modification : envoi à AniList puis mise à jour locale.
local function apply(e, progress, status, back_to)
    progress = math.max(0, progress)
    if e.chapters and e.chapters > 0 and progress > e.chapters then progress = e.chapters end
    Online.run(function()
        local ok, err = AniList.save(e.media_id, progress, status)
        if not ok then return fail(err) end
        if status ~= e.status then
            find_entry(e)
            e.status = status
            _data.lists[status] = _data.lists[status] or {}
            table.insert(_data.lists[status], 1, e)
        end
        e.progress = progress
        show_status(back_to)
    end)
end

local function choose_status(e, back_to)
    local dlg
    local buttons = {}
    for _, s in ipairs(STATUSES) do
        buttons[#buttons + 1] = {{
            text = T(s[2]) .. (s[1] == e.status and "  ✓" or ""),
            callback = function() UIManager:close(dlg); apply(e, e.progress, s[1], back_to) end,
        }}
    end
    buttons[#buttons + 1] = {{ text = T("Annuler"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = T("Statut"), buttons = buttons }
    UIManager:show(dlg)
end

local function set_chapter(e, back_to)
    local input
    input = InputDialog:new{
        title = T("Chapitre lu"), input = tostring(e.progress), input_type = "number",
        buttons = {{
            { text = T("Annuler"), callback = function() UIManager:close(input) end },
            { text = T("OK"), is_enter_default = true, callback = function()
                local n = tonumber(input:getInputText())
                UIManager:close(input)
                if n then apply(e, math.floor(n), e.status, back_to) end
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

local function entry_actions(e, back_to)
    local dlg
    local function close_then(fn) return function() UIManager:close(dlg); fn() end end
    local ch = e.chapters and ("/" .. e.chapters) or ""
    dlg = ButtonDialog:new{
        title = e.title .. "\n" .. e.progress .. ch .. " · " .. status_label(e.status),
        buttons = {
            {
                { text = "−1", callback = close_then(function() apply(e, e.progress - 1, e.status, back_to) end) },
                { text = "+1", callback = close_then(function()
                    local st = e.status
                    if st == "PLANNING" or st == "PAUSED" or st == "DROPPED" then st = "CURRENT" end
                    local p = e.progress + 1
                    if e.chapters and e.chapters > 0 and p >= e.chapters then st = "COMPLETED" end
                    apply(e, p, st, back_to)
                end) },
            },
            {{ text = T("Définir le chapitre…"), callback = close_then(function() set_chapter(e, back_to) end) }},
            {{ text = T("Marquer comme terminé"), callback = close_then(function()
                apply(e, (e.chapters and e.chapters > 0) and e.chapters or e.progress, "COMPLETED", back_to)
            end) }},
            {{ text = T("Changer le statut"), callback = close_then(function() choose_status(e, back_to) end) }},
            {{ text = T("Fermer"), callback = function() UIManager:close(dlg) end }},
        },
    }
    UIManager:show(dlg)
end

show_status = function(code)
    if not _menu then return end
    local items = {{ text = "← " .. T("Retour"), callback = function() show_lists() end }}
    for _, e in ipairs(_data.lists[code] or {}) do
        items[#items + 1] = {
            text = e.title,
            mandatory = e.progress .. (e.chapters and ("/" .. e.chapters) or ""),
            callback = function() entry_actions(e, code) end,
        }
    end
    _menu:switchItemTable("AniList · " .. status_label(code), items)
end

show_lists = function()
    if not _menu then return end
    local items = {{ text = "← " .. T("Retour"), callback = function() show_main() end }}
    for _, s in ipairs(STATUSES) do
        local n = #(_data.lists[s[1]] or {})
        if n > 0 then
            items[#items + 1] = {
                text = T(s[2]), mandatory = tostring(n),
                callback = function() show_status(s[1]) end,
            }
        end
    end
    if #items == 1 then items[2] = { text = T("Ta liste est vide pour l'instant."), callback = function() end } end
    _menu:switchItemTable("AniList · " .. T("Ma liste"), items)
end

-- ── Découverte ───────────────────────────────────────────────────────────────

local function clean_desc(d)
    d = tostring(d or ""):gsub("<br%s*/?>", "\n"):gsub("<[^>]+>", "")
    d = d:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#039;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
    d = d:gsub("\n%s*\n+", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if #d > 600 then d = d:sub(1, 600):gsub("[\128-\191]*$", "") .. "…" end
    return d
end

local FORMAT_FR = { MANGA = "Manga", NOVEL = "Light novel", ONE_SHOT = "One-shot" }
local STATUS_FR = { FINISHED = "Terminé", RELEASING = "En cours", NOT_YET_RELEASED = "À venir",
                    CANCELLED = "Annulé", HIATUS = "En pause" }

local function add_to_list(m)
    Online.run(function()
        local ok, err = AniList.save(m.id, 0, "PLANNING")
        if not ok then return fail(err) end
        local e = { media_id = m.id, title = m.title, format = m.format, chapters = m.chapters,
                    progress = 0, score = 0, status = "PLANNING" }
        _data.lists.PLANNING = _data.lists.PLANNING or {}
        table.insert(_data.lists.PLANNING, 1, e)
        _in_list[m.id] = e
        msg(T("Ajouté à « Planifiés » : ") .. m.title, 3)
    end)
end

local function read_in_sources(term)
    if _menu then UIManager:close(_menu); _menu = nil end
    require("ui.browse").globalSearch(term)
end

local function media_dialog(m, back)
    local dlg
    local info = {}
    info[#info + 1] = (FORMAT_FR[m.format] or m.format or "")
        .. (m.chapters and (" · " .. m.chapters .. " ch.") or "")
        .. (m.status and (" · " .. (STATUS_FR[m.status] or m.status)) or "")
        .. (m.year and (" · " .. m.year) or "")
    if m.score then info[#info + 1] = string.format("★ %.1f / 10", m.score / 10) end
    if #m.genres > 0 then info[#info + 1] = table.concat(m.genres, ", ") end
    local d = clean_desc(m.desc)
    if d ~= "" then info[#info + 1] = "\n" .. d end
    local mine = _in_list[m.id]
    local buttons = {
        {{ text = T("Lire : chercher dans mes sources"), callback = function()
            UIManager:close(dlg); read_in_sources(m.title)
        end }},
    }
    if m.alt then
        buttons[#buttons + 1] = {{ text = T("Chercher avec le titre : ") .. m.alt, callback = function()
            UIManager:close(dlg); read_in_sources(m.alt)
        end }}
    end
    if mine then
        buttons[#buttons + 1] = {{ text = T("Dans ta liste : ") .. status_label(mine.status)
            .. " (" .. mine.progress .. ")", callback = function() UIManager:close(dlg) end }}
    else
        buttons[#buttons + 1] = {{ text = T("Ajouter à ma liste (Planifié)"), callback = function()
            UIManager:close(dlg); add_to_list(m)
        end }}
    end
    buttons[#buttons + 1] = {{ text = T("Fermer"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = m.title .. "\n" .. table.concat(info, "\n"), buttons = buttons }
    UIManager:show(dlg)
end

show_media_list = function(title, list)
    if not _menu then return end
    local items = {{ text = "← " .. T("Retour"), callback = function() show_main() end }}
    for _, m in ipairs(list) do
        items[#items + 1] = {
            text = (_in_list[m.id] and "✓ " or "") .. m.title,
            mandatory = m.score and string.format("%.1f ★", m.score / 10) or "",
            callback = function() media_dialog(m) end,
        }
    end
    if #items == 1 then items[2] = { text = T("Aucun résultat."), callback = function() end } end
    _menu:switchItemTable(title, items)
end

local function with_loading(text, fn)
    Online.run(function()
        local loading = InfoMessage:new{ text = text }
        UIManager:show(loading)
        UIManager:nextTick(function()
            local ok, err = pcall(fn)
            UIManager:close(loading)
            if not ok then pcall(function() require("logger").warn("Sefirah/AniList:", tostring(err)) end) end
        end)
    end)
end

local function discover(title, opts)
    with_loading(T("Chargement…"), function()
        local res, err = AniList.discover(opts)
        if not res then return fail(err) end
        show_media_list(title, res)
    end)
end

local function recommended()
    -- Titres de départ : les mieux notés de ta liste (sinon ceux en cours/terminés).
    local pool = {}
    for _, arr in pairs(_data.lists) do
        for _, e in ipairs(arr) do
            if e.status == "COMPLETED" or e.status == "CURRENT" or e.status == "REPEATING" then
                pool[#pool + 1] = e
            end
        end
    end
    if #pool == 0 then
        msg(T("Ajoute ou lis quelques titres pour recevoir des recommandations. Voici les tendances en attendant."), 5)
        return discover("AniList · " .. T("Tendances"), { sort = "TRENDING_DESC" })
    end
    table.sort(pool, function(a, b) return (a.score or 0) > (b.score or 0) end)
    local seeds = {}
    for i = 1, math.min(3, #pool) do seeds[i] = pool[i].media_id end
    with_loading(T("Recherche de recommandations…"), function()
        local res, err = AniList.recommend(seeds, _in_list)
        if not res then
            if err then return fail(err) end
            return msg(T("Pas encore de recommandation pour tes titres."), 4)
        end
        show_media_list("AniList · " .. T("Pour toi"), res)
    end)
end

local GENRES = { "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Horror", "Mystery",
                 "Psychological", "Romance", "Sci-Fi", "Slice of Life", "Supernatural", "Sports" }

local function pick_genre()
    local dlg
    local buttons = {}
    for i = 1, #GENRES, 2 do
        local row = {}
        for j = i, math.min(i + 1, #GENRES) do
            local g = GENRES[j]
            row[#row + 1] = { text = g, callback = function()
                UIManager:close(dlg)
                discover("AniList · " .. g, { sort = "POPULARITY_DESC", genre = g })
            end }
        end
        buttons[#buttons + 1] = row
    end
    buttons[#buttons + 1] = {{ text = T("Annuler"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = T("Genre"), buttons = buttons }
    UIManager:show(dlg)
end

local function search_prompt()
    local input
    input = InputDialog:new{
        title = T("Rechercher sur AniList"), input_hint = T("Titre…"),
        buttons = {{
            { text = T("Annuler"), callback = function() UIManager:close(input) end },
            { text = T("Rechercher"), is_enter_default = true, callback = function()
                local term = input:getInputText()
                UIManager:close(input)
                if term and term ~= "" then discover("AniList · " .. term, { search = term }) end
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

local MANGA  = { "MANGA", "ONE_SHOT" }
local NOVELS = { "NOVEL" }

show_main = function()
    if not _menu then return end
    local n = 0
    for _, arr in pairs(_data.lists) do n = n + #arr end
    local function d(label, title, opts) return {
        text = label, callback = function() discover("AniList · " .. title, opts) end,
    } end
    local items = {
        { text = T("Ma liste"), mandatory = tostring(n), callback = function() show_lists() end },
        { text = T("Recommandés pour toi"), callback = recommended },
        d(T("Tendances · Manga"),       T("Tendances manga"),       { sort = "TRENDING_DESC",   formats = MANGA }),
        d(T("Tendances · Light novels"), T("Tendances light novels"), { sort = "TRENDING_DESC",   formats = NOVELS }),
        d(T("Populaires · Manga"),       T("Populaires manga"),       { sort = "POPULARITY_DESC", formats = MANGA }),
        d(T("Populaires · Light novels"), T("Populaires light novels"), { sort = "POPULARITY_DESC", formats = NOVELS }),
        d(T("Mieux notés · Manga"),      T("Mieux notés manga"),      { sort = "SCORE_DESC",      formats = MANGA }),
        d(T("Mieux notés · Light novels"), T("Mieux notés light novels"), { sort = "SCORE_DESC",    formats = NOVELS }),
        { text = T("Par genre…"), callback = pick_genre },
        { text = T("Rechercher sur AniList…"), callback = search_prompt },
    }
    _menu:switchItemTable("AniList · " .. tostring(_data.name or ""), items)
end

function List.show()
    if not AniList.has_token() then
        return msg(T("Ajoute d'abord ton jeton AniList : Paramètres › AniList."), 5)
    end
    Online.run(function()
        local loading = InfoMessage:new{ text = T("Chargement de ta liste AniList…") }
        UIManager:show(loading)
        UIManager:nextTick(function()
            local data, err = AniList.my_list()
            UIManager:close(loading)
            if not data then return fail(err) end
            _data = data
            _in_list = {}
            for _, arr in pairs(data.lists) do for _, e in ipairs(arr) do _in_list[e.media_id] = e end end
            _menu = Menu:new{
                title = "AniList", item_table = {{ text = "…", callback = function() end }},
                is_borderless = true, is_popout = false, title_bar_fm_style = true,
                width = Device.screen:getWidth(), height = Device.screen:getHeight(),
                close_callback = function() UIManager:close(_menu); _menu = nil end,
            }
            UIManager:show(_menu)
            show_main()
        end)
    end)
end

return List
