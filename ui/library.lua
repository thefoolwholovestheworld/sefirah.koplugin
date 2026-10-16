-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- Onglet Bibliothèque : liste des romans suivis.
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local DB          = require("core.db")
local Cache       = require("core.cache")
local Covers      = require("core.covers")
local ExtMgr      = require("core.extmgr")
local Settings    = require("settings")
local P           = require("ui.panel")
local VerticalSpan = require("ui/widget/verticalspan")

local Library = {}
Library.on_novel_tap = nil

local _page     = 1
local _fetch_id = 0
-- Terme de filtre courant (nil = pas de filtre). Chargé depuis les réglages
-- persistants au démarrage du module, pour survivre à un redémarrage de l'appareil.
local _search   = Settings:get("library_search")

-- Centralise la mutation de _search : met toujours à jour la valeur ET la
-- sauvegarde sur disque, pour qu'aucun point d'appel ne puisse oublier l'un des deux.
local function set_search(term)
    _search = (term and term ~= "") and term or nil
    Settings:set("library_search", _search)
end
local _SORTS = {
    { id = "title_asc",  label = T("Titre (A → Z)") },
    { id = "title_desc", label = T("Titre (Z → A)") },
    { id = "new_first",  label = T("Nouveaux chapitres d'abord") },
    { id = "recent",     label = T("Ajoutés récemment") },
    { id = "last_read",  label = T("Lu récemment") },
}
-- Choix de tri courant. Chargé depuis les réglages persistants au démarrage
-- du module, pour survivre à un redémarrage de l'appareil. "title_asc" reste
-- la valeur par défaut la toute première fois (rien encore sauvegardé).
local _sort = Settings:get("library_sort") or "title_asc"

-- Titres enregistrés avec le nom répété (« Berserk Berserk », ancien défaut MangaPill) : on n'en garde qu'un.
local function collapse_repeated_title(t)
    if type(t) ~= "string" then return t end
    local n = #t
    if n >= 3 and n % 2 == 1 then
        local h = (n - 1) / 2
        if t:sub(h + 1, h + 1) == " " and t:sub(1, h) == t:sub(h + 2) then return t:sub(1, h) end
    end
    return t
end

local function apply_search_and_sort(novels)
    for _, n in ipairs(novels) do n.title = collapse_repeated_title(n.title) end
    local out = novels
    if _search and _search ~= "" then
        local needle = _search:lower()
        local filtered = {}
        for _, n in ipairs(out) do
            if (n.title or ""):lower():find(needle, 1, true) then
                table.insert(filtered, n)
            end
        end
        out = filtered
    end

    local sorted = {}
    for i, n in ipairs(out) do sorted[i] = n end
    if _sort == "title_asc" then
        table.sort(sorted, function(a, b) return (a.title or ""):lower() < (b.title or ""):lower() end)
    elseif _sort == "title_desc" then
        table.sort(sorted, function(a, b) return (a.title or ""):lower() > (b.title or ""):lower() end)
    elseif _sort == "new_first" then
        table.sort(sorted, function(a, b) return (a.new_chapters or 0) > (b.new_chapters or 0) end)
    elseif _sort == "recent" then
        table.sort(sorted, function(a, b) return (a.added_at or 0) > (b.added_at or 0) end)
    elseif _sort == "last_read" then
        table.sort(sorted, function(a, b) return (a.last_read_at or 0) > (b.last_read_at or 0) end)
    end
    return sorted
end

-- BlitBuffers de couvertures alloués pour la page actuellement affichée — libérés au
-- début de chaque reconstruction (et lors de Library.close) pour que la mémoire limitée de l'e-ink
-- ne s'accumule pas au fil des cycles de pagination / rafraîchissement.
local _cover_bbs = {}
local function free_covers()
    for _, bb in ipairs(_cover_bbs) do
        if bb then bb:free() end
    end
    _cover_bbs = {}
end

-- Romans dont la récupération de couverture a déjà échoué cette session — éviter de réessayer
-- à chaque reconstruction jusqu'à la réouverture de l'app.
local _cover_prefetch_done = {}

local function rebuild()
    require("ui.main_widget").show("library")
end

local function do_refresh_confirmed()
    _fetch_id = _fetch_id + 1
    local my_id = _fetch_id

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        if my_id ~= _fetch_id then return end

        local loading = InfoMessage:new{ text = T("Recherche de mises à jour…") }
        UIManager:show(loading)
        UIManager:scheduleIn(0.1, function()
            if my_id ~= _fetch_id then
                UIManager:close(loading)
                return
            end

            local novels  = DB.getAll()
            local updated = 0
            for _, novel in ipairs(novels) do
                local ext = ExtMgr.get(novel.source_id)
                if ext then
                    local ok, info = pcall(ext.parseNovel, ext, novel.path)
                    if ok and info then
                        local new_total = info.chapters and #info.chapters or 0
                        if new_total ~= (novel.total_chapters or 0) then
                            DB.update(novel.source_id, novel.path, { total_chapters = new_total })
                            updated = updated + 1
                        end
                    end
                end
            end
            UIManager:close(loading)
            UIManager:show(InfoMessage:new{
                text    = updated > 0
                    and (updated .. T(" roman(s) ont de nouveaux chapitres !"))
                    or  T("Aucun nouveau chapitre trouvé."),
                timeout = 3,
            })
            _page = 1
            rebuild()
        end)
    end)
end

local function do_refresh()
    UIManager:show(ConfirmBox:new{
        text        = T("Ceci vérifie les nouveaux chapitres pour chaque roman suivi.\n\nPlus vous avez de romans suivis, plus cela prend du temps. Pour mettre à jour un seul roman, ouvrez-le individuellement à la place.\n\nContinuer ?"),
        ok_text     = T("Tout actualiser"),
        cancel_text = T("Annuler"),
        ok_callback = do_refresh_confirmed,
    })
end

-- Récupère (et met en cache disque) les couvertures pour tout `novels` qui n'en a pas
-- déjà en cache, puis reconstruit l'onglet. S'exécute une fois par lot de romans manquants —
-- au moment du nouveau rendu, le chemin de cache disque de Covers.get répond vite.
local function prefetch_missing_covers(novels)
    local missing = {}
    for _, novel in ipairs(novels) do
        local key = (novel.source_id or "?") .. "|" .. (novel.path or "")
        if novel.cover and novel.cover ~= "" and not _cover_prefetch_done[key] then
            if not DB.loadCoverCache(novel.source_id, novel.path or "") then
                table.insert(missing, novel)
            end
        end
    end
    if #missing == 0 then return end

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        local loading = InfoMessage:new{ text = T("Chargement des couvertures…") }
        UIManager:show(loading)
        UIManager:scheduleIn(0.1, function()
            for _, novel in ipairs(missing) do
                local key  = (novel.source_id or "?") .. "|" .. (novel.path or "")
                local site = (ExtMgr.getMeta(novel.source_id) or {}).site
                Covers.prefetchRaw(novel.source_id, novel.path or "", novel.cover, site)
                _cover_prefetch_done[key] = true
            end
            UIManager:close(loading)
            rebuild()
        end)
    end)
end

-- ── Rendu en liste texte (couvertures désactivées) ────────────────────────────

local function build_list_rows(novels, header_rows, SefirahUI)
    local novel_rows = {}
    if #novels == 0 then
        table.insert(novel_rows, P.makeRow(T("Aucun roman suivi pour l'instant — allez dans Parcourir"), {
            dim = true,
            callback = function() SefirahUI.show("browse") end,
        }))
    else
        for _, n in ipairs(novels) do
            local novel  = n
            local new    = novel.new_chapters or 0
            local badge  = ""
            local src    = novel.source_id or "?"
            local ch     = novel.total_chapters or 0

            local dl_count = Cache.getDownloadedCount(novel.source_id, novel.path or "")
            local dl_str   = ""
            if dl_count > 0 then
                local prog = Cache.getProgress(novel.source_id, novel.path or "")
                local pct  = prog and math.floor((prog.percent or 0) * 100) or 0
                dl_str = string.format("  ·  ⭳ %d/%d · %d%%", dl_count, ch, pct)
            end

            table.insert(novel_rows, P.makeRow(
                (novel.title or T("Inconnu")) .. badge, {
                    mandatory = src .. "  ·  " .. ch .. " ch" .. dl_str,
                    bold      = new > 0,
                    callback  = function()
                        if Library.on_novel_tap then Library.on_novel_tap(novel) end
                    end,
                    hold_callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = T('Ne plus suivre « ') .. (novel.title or "?") .. T(' » ?'),
                            ok_callback = function()
                                DB.untrack(novel.source_id, novel.path)
                                _page = 1
                                rebuild()
                            end,
                        })
                    end,
                }
            ))
        end
    end

    local fixed_h        = 0
    for _, r in ipairs(header_rows) do fixed_h = fixed_h + r:getSize().h end
    local total           = #novel_rows
    local per_page_full   = math.max(1, math.floor((P.CONTENT_H     - fixed_h) / P.ROW_H))
    local use_nav         = math.ceil(total / per_page_full) > 1
    -- Aucune barre de navigation numérique n'est plus affichée (la barre d'onglets la remplace), donc
    -- il n'y a pas de ligne supplémentaire à réserver — toujours utiliser la page entière.
    local per_page        = per_page_full
    local max_pages = math.max(1, math.ceil(total / per_page))
    if _page > max_pages then _page = max_pages end

    local page_novel_rows = {}
    local start = (_page - 1) * per_page + 1
    for i = start, math.min(start + per_page - 1, total) do
        table.insert(page_novel_rows, novel_rows[i])
    end

    local all_rows = {}
    for _, r in ipairs(header_rows)     do table.insert(all_rows, r) end
    for _, r in ipairs(page_novel_rows) do table.insert(all_rows, r) end

    local nav = use_nav and {
        page      = _page,
        max_pages = max_pages,
        on_prev   = _page > 1 and function() _page = _page - 1; rebuild() end or nil,
        on_next   = _page < max_pages and function() _page = _page + 1; rebuild() end or nil,
    } or nil

    return all_rows, nav
end

-- ── Rendu en grille de couvertures (couvertures activées) ────────────────────

-- Fixé à 2 rangées × P.GRID_COLS (3) = 6 romans par page, exactement comme
-- BROWSE_GRID_ROWS de Browse. Les couvertures gardent leur taille normale
-- (P.GRID_COVER_W × P.GRID_COVER_H) tant que ces 2 rangées tiennent dans l'espace
-- dispo au-dessus de la barre Bibliothèque / Parcourir / Sources — cette barre
-- (P.TAB_H) n'est jamais rognée pour leur faire de la place. Si l'espace vient à
-- manquer, on réduit — en tout dernier recours seulement — l'affichage de toutes
-- les couvertures de la page à 90 % pour que les 2 rangées tiennent quand même.
local LIBRARY_GRID_ROWS = 2

local function build_grid_rows(novels, header_rows, SefirahUI)
    free_covers()

    if #novels == 0 then
        local rows = {}
        for _, r in ipairs(header_rows) do table.insert(rows, r) end
        table.insert(rows, P.makeRow(T("Aucun roman suivi pour l'instant — allez dans Parcourir"), {
            dim = true,
            callback = function() SefirahUI.show("browse") end,
        }))
        return rows, nil
    end

    local fixed_h = 0
    for _, r in ipairs(header_rows) do fixed_h = fixed_h + r:getSize().h end

    -- Espace dispo pour la grille, sans jamais toucher à P.CONTENT_H (donc jamais
    -- à P.TAB_H / la barre Bibliothèque / Parcourir / Sources en bas).
    local content_h = P.CONTENT_H - fixed_h

    local function cell_and_need(cover_h)
        local cell_h = cover_h + P.GRID_TITLE_H + P.GRID_CELL_PAD
        return cell_h, LIBRARY_GRID_ROWS * cell_h + P.GRID_BOTTOM_GAP
    end

    -- 1) Taille normale d'abord.
    local library_cover_w      = P.GRID_COVER_W
    local library_cover_h      = P.GRID_COVER_H
    local library_cell_h, need = cell_and_need(library_cover_h)

    -- 2) Dernier recours seulement : les 2 rangées à taille normale ne tiennent
    -- pas dans l'espace dispo → on réduit l'affichage de toutes les couvertures à 90 %.
    if need > content_h then
        -- Ajustement exact : la hauteur de cellule qui fait tenir les rangées.
        local per_row   = math.floor((content_h - P.GRID_BOTTOM_GAP) / LIBRARY_GRID_ROWS)
        library_cover_h = math.max(40, math.min(P.GRID_COVER_H, per_row - P.GRID_TITLE_H - P.GRID_CELL_PAD))
        library_cover_w = math.floor(library_cover_h / 1.45)
        library_cell_h  = cell_and_need(library_cover_h)
    end

    local total     = #novels
    local per_page  = P.GRID_COLS * LIBRARY_GRID_ROWS
    local use_nav   = total > per_page
    local max_pages = math.max(1, math.ceil(total / per_page))
    if _page > max_pages then _page = max_pages end

    local start = (_page - 1) * per_page + 1
    local page_novels = {}
    for i = start, math.min(start + per_page - 1, total) do
        table.insert(page_novels, novels[i])
    end

    local items = {}
    for _, novel in ipairs(page_novels) do
        local new      = novel.new_chapters or 0
        local cover_bb = Covers.get(novel.source_id, novel.path or "", nil, nil,
            library_cover_w, library_cover_h)
        if cover_bb then table.insert(_cover_bbs, cover_bb) end

        table.insert(items, {
            title    = (novel.title or T("Inconnu")),
            cover_bb = cover_bb,
            cover_w  = library_cover_w,
            cover_h  = library_cover_h,
            cell_h   = library_cell_h,
            bold     = new > 0,
            callback = function()
                if Library.on_novel_tap then Library.on_novel_tap(novel) end
            end,
            hold_callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T('Ne plus suivre « ') .. (novel.title or "?") .. T(' » ?'),
                    ok_callback = function()
                        DB.untrack(novel.source_id, novel.path)
                        _page = 1
                        rebuild()
                    end,
                })
            end,
        })
    end

    local grid = P.makeCoverGrid(items, library_cell_h * math.ceil(#page_novels / P.GRID_COLS))

    -- Centrage vertical : l'espace libre (au-dessus de la barre d'onglets) est
    -- réparti moitié en haut, moitié en bas, calculé pour 2 rangées pleines afin
    -- que la grille ne saute pas d'une page à l'autre.
    local top_pad = math.max(0, math.floor((content_h - LIBRARY_GRID_ROWS * library_cell_h) / 2))

    local all_rows = {}
    for _, r in ipairs(header_rows) do table.insert(all_rows, r) end
    if top_pad > 0 then
        table.insert(all_rows, VerticalSpan:new{ width = top_pad })
    end
    table.insert(all_rows, grid)

    -- Quand une recherche est active, l'espace vide sous la grille (résultats < 1 page)
    -- devient lui-même une zone tactile qui efface le filtre — on dimensionne la grille
    -- à sa hauteur naturelle ci-dessus (au lieu de la laisser se remplir toute seule avec
    -- un espace inerte) et on ajoute ici une vraie ligne tappable (même mécanisme que les
    -- autres lignes de l'app, ex. « Filtre : ... ») qui absorbe le reste de la hauteur.
    if _search then
        local used = library_cell_h * math.ceil(#page_novels / P.GRID_COLS)
        local remaining = content_h - used - top_pad
        if remaining > 0 then
            table.insert(all_rows, P.makeRow("", {
                height = remaining,
                callback = function()
                    set_search(nil)
                    _page = 1
                    rebuild()
                end,
            }))
        end
    end

    local nav = use_nav and {
        page      = _page,
        max_pages = max_pages,
        on_prev   = _page > 1 and function() _page = _page - 1; rebuild() end or nil,
        on_next   = _page < max_pages and function() _page = _page + 1; rebuild() end or nil,
    } or nil

    -- Lance une récupération en arrière-plan pour tout ce qui manque sur cette page ;
    -- rebuild() sera appelé une fois terminé pour remplir les espaces réservés.
    prefetch_missing_covers(page_novels)

    return all_rows, nav
end

-- ── Recherche / tri (icônes de la barre de titre) ─────────────────────────────

local function open_search()
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title      = T("Rechercher dans la bibliothèque"),
        input      = _search,
        input_hint = T("Titre du roman..."),
        buttons    = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            { text = T("Effacer"),  callback = function()
                UIManager:close(dlg)
                set_search(nil)
                _page = 1
                rebuild()
            end },
            {
                text             = T("Rechercher"),
                is_enter_default = true,
                callback         = function()
                    local term = dlg:getInputText()
                    UIManager:close(dlg)
                    set_search(term)
                    _page = 1
                    rebuild()
                end,
            },
        }},
    }
    UIManager:show(dlg)
end

local function open_sort()
    local items = {}
    for _, s in ipairs(_SORTS) do
        table.insert(items, {
            (s.id == _sort and "✓ " or "   ") .. s.label,
            function()
                _sort = s.id
                Settings:set("library_sort", _sort)
                _page = 1
                rebuild()
            end,
        })
    end
    P.showDropdown(items)
end

-- ── Public ──────────────────────────────────────────────────────────────────

function Library.build_rows()
    local SefirahUI = require("ui.main_widget")
    -- Dans la Bibliothèque uniquement, les libellés reflètent les contenus suivis.
    -- Un type vide reste visible mais désactivé si l'autre type contient des éléments.
    local all_tracked = DB.getByFilter("all")
    local kind_counts = { novels = 0, manga = 0 }
    for _, n in ipairs(all_tracked) do
        local tracked_kind = ExtMgr.kindOf(n.source_id)
        kind_counts[tracked_kind] = (kind_counts[tracked_kind] or 0) + 1
    end

    -- Si le type actif est vide, basculer vers celui qui contient des éléments.
    local kind = ExtMgr.currentKind()
    if kind_counts[kind] == 0 then
        if kind_counts.novels > 0 then
            kind = "novels"
            ExtMgr.setKind(kind)
        elseif kind_counts.manga > 0 then
            kind = "manga"
            ExtMgr.setKind(kind)
        end
    end

    local kind_novels = {}
    for _, n in ipairs(all_tracked) do
        if ExtMgr.kindOf(n.source_id) == kind then kind_novels[#kind_novels + 1] = n end
    end
    local novels   = apply_search_and_sort(kind_novels)

    local header_rows = {}
    if _search then
        table.insert(header_rows, P.makeRow(T('Filtre : « ') .. _search .. T(' »  ·  toucher pour changer'), {
            dim = true, callback = open_search,
            -- Appui long : efface le filtre (le titre est remplacé par Novels | Mangas).
            hold_callback = function() set_search(nil); _page = 1; rebuild() end,
        }))
        table.insert(header_rows, P.hairline())
    end

    local all_rows, nav
    if Settings:get("covers_library") then
        all_rows, nav = build_grid_rows(novels, header_rows, SefirahUI)
    else
        free_covers()
        all_rows, nav = build_list_rows(novels, header_rows, SefirahUI)
    end

    local title = _search and (T("Bibliothèque (") .. #novels .. ")") or T("Bibliothèque")
    local actions = {
        kind_switch = (kind_counts.novels + kind_counts.manga > 0) and P.kindSwitch(
            function() _page = 1; rebuild() end,
            { counts = kind_counts }
        ) or nil,
        on_search = open_search,
        on_sort   = open_sort,
        -- Toucher le titre efface directement le filtre en cours (pas de dialogue,
        -- contrairement à la ligne "Filtre : ... · toucher pour changer" qui rouvre
        -- la recherche pour la modifier).
        on_title_tap = function()
            if _search then
                set_search(nil)
                _page = 1
                rebuild()
            end
        end,
        menu_extra_items = {
            { T("Actualiser"), do_refresh },
        },
    }
    return all_rows, title, nav, actions
end

function Library.close()
    free_covers()
end

return Library
