-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- Onglet Parcourir : sélecteur de source → liste de romans.
local UIManager   = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr  = require("ui/network/manager")
local Online      = require("core.online")
local ExtMgr      = require("core.extmgr")
local Covers      = require("core.covers")
local Settings    = require("settings")
local P           = require("ui.panel")
local LangFilter  = require("ui.lang_filter")

local Browse = {}
Browse.on_novel_tap = nil

Browse._state       = "picker"
Browse._source_id   = nil
Browse._novels      = {}
Browse._page        = 1
Browse._picker_page = 1
Browse._search      = nil

-- Écran propre aux sources qui déclarent ext.fandomList (AO3) :
-- « fandoms » (cases paginées, ouverture instantanée).
Browse._fandom_items = {}
Browse._fpage        = 1

-- Recherche dans toutes les sources (état « global ») : résultats agrégés
-- { { source_id, source_name, novel }, ... }, paginés en liste texte.
Browse._gresults    = {}
Browse._gterm       = nil
Browse._gpage       = 1

-- Sélections de filtres « Populaire » par source (ex. catégorie/période de
-- classement), indexées par source_id → { [filter_key] = selected_option_id }.
-- Une extension déclare ses filtres via `ext.popularFilters` (voir plus bas) ;
-- une extension qui ne le déclare pas n'a simplement pas cette icône.
Browse._filters = {}

-- Fait correspondre une « page app » à l'écran (ce à quoi Next/Prev/`p.N` font référence) à la première
-- page côté source à récupérer pour elle. Une page source renvoie souvent
-- moins de romans que ce que la grille peut afficher sur un écran (ex. 3
-- romans par page source contre 2 rangées × 3 colonnes = 6 emplacements à l'écran), donc une
-- page app est remplie en tirant autant de pages source consécutives que nécessaire.
-- Réinitialisé à {[1] = 1} chaque fois que la page 1 est (re)affichée — nouvelle source, nouvelle recherche,
-- ou retour au début.
Browse._page_start = { [1] = 1 }
-- Romans restants d’une page source quand elle contient plus de 6 romans.
-- Cela évite de sauter les romans 7, 8, 9… lorsque l’écran ne doit afficher
-- que 6 romans par page.
Browse._page_buffer = {}

-- Limite de sécurité sur le nombre de récupérations côté source qu'une page app enchaînera
-- au cas où une source continuerait à renvoyer de minuscules pages non vides.
local MAX_SRC_FETCHES = 6

local _fetch_id = 0
local _prefetch_token = 0

-- BlitBuffers de couvertures pour la page actuellement affichée, libérés à chaque reconstruction.
local _cover_bbs = {}
local function free_covers()
    for _, bb in ipairs(_cover_bbs) do
        if bb then bb:free() end
    end
    _cover_bbs = {}
end

-- Romans dont la récupération de couverture a déjà réussi/échoué cette session, indexés
-- par source_id|path, pour qu'une reconstruction ne les redemande pas sans arrêt.
local _cover_prefetch_done = {}

local function rebuild()
    require("ui.main_widget").show("browse")
end

local function novel_key(source_id, novel)
    return source_id .. "|" .. (novel.path or novel.sourceUrl or "")
end

-- Télécharge (et met en cache disque) les couvertures pour tout `novels` pas encore en cache,
-- puis reconstruit pour que la grille se redessine avec les vraies couvertures au lieu des
-- espaces réservés. Ne fait rien de coûteux une fois que tout sur la page est en cache.
local function prefetch_missing_covers(source_id, novels)
    local site = (ExtMgr.getMeta(source_id) or {}).site
    local missing = {}
    for _, novel in ipairs(novels) do
        local key  = novel_key(source_id, novel)
        local path = novel.path or novel.sourceUrl or ""
        if novel.cover and novel.cover ~= "" and not _cover_prefetch_done[key] then
            if not require("core.db").loadCoverCache(source_id, path)
                or tostring(novel.cover):match("^local:") then
                table.insert(missing, novel)
            end
        end
    end
    if #missing == 0 then return end

    _prefetch_token = _prefetch_token + 1
    local my_token = _prefetch_token

    Online.run(function()
        if my_token ~= _prefetch_token then return end
        local loading = InfoMessage:new{ text = T("Chargement des couvertures…") }
        UIManager:show(loading)
        -- Voie rapide : toutes les couvertures manquantes se téléchargent EN MÊME TEMPS
        -- (sous-processus). La latence réseau ne se paie qu'une fois, pas 6 fois.
        local Parallel = require("core.parallel")
        if Parallel.available() then
            local jobs = {}
            for _, novel in ipairs(missing) do
                local path = novel.path or novel.sourceUrl or ""
                local cover = novel.cover
                jobs[#jobs + 1] = function()
                    Covers.prefetchRaw(source_id, path, cover, site)
                end
                _cover_prefetch_done[novel_key(source_id, novel)] = true
            end
            local started = Parallel.run(jobs, function()
                UIManager:close(loading)
                if my_token == _prefetch_token then rebuild() end
            end, 25)
            if started then return end
        end

        local idx, fails = 0, 0
        -- Repli séquentiel : une couverture par tick : l'interface reste réactive entre deux
        -- téléchargements, et on abandonne si l'utilisateur a changé de page.
        local function step()
            if my_token ~= _prefetch_token then
                UIManager:close(loading)
                return
            end
            idx = idx + 1
            local novel = missing[idx]
            if not novel then
                UIManager:close(loading)
                rebuild()
                return
            end
            local key  = novel_key(source_id, novel)
            local path = novel.path or novel.sourceUrl or ""
            local got = Covers.prefetchRaw(source_id, path, novel.cover, site)
            _cover_prefetch_done[key] = true
            fails = got and 0 or (fails + 1)
            if fails >= 2 then
                -- Serveur d'images lent ou injoignable : on n'attend pas les autres
                -- (elles sont marquées « essayées » pour ne pas réessayer en boucle).
                for k = idx + 1, #missing do
                    _cover_prefetch_done[novel_key(source_id, missing[k])] = true
                end
                UIManager:close(loading)
                rebuild()
                return
            end
            UIManager:scheduleIn(0.02, step)
        end
        UIManager:scheduleIn(0.05, step)
    end)
end

-- Clavier propre à une source : une extension peut déclarer
--   ext.keyboardLayouts = { "zh_CN", "zh" }   -- par ordre de préférence
-- (codes de disposition du clavier virtuel de KOReader : zh_CN = pinyin,
-- zh = traits). On active la première disposition réellement disponible dans
-- CETTE version de KOReader le temps de la saisie, puis on remet l'ancien
-- réglage à la fermeture de la boîte : le clavier des autres sources et de
-- KOReader n'est pas modifié. Renvoie la fonction de restauration.
local function use_source_keyboard(ext)
    local noop = function() end
    local wanted = ext and ext.keyboardLayouts
    if type(wanted) ~= "table" or not G_reader_settings then return noop end

    local ok, VK = pcall(require, "ui/widget/virtualkeyboard")
    local known = ok and type(VK) == "table" and VK.lang_to_keyboard_layout or nil
    if not known then return noop end

    local chosen
    for _, code in ipairs(wanted) do
        if known[code] then chosen = code; break end
    end
    if not chosen then return noop end

    local previous = G_reader_settings:readSetting("keyboard_layout")
    G_reader_settings:saveSetting("keyboard_layout", chosen)
    local restored = false
    return function()
        if restored then return end
        restored = true
        if previous then
            G_reader_settings:saveSetting("keyboard_layout", previous)
        else
            G_reader_settings:delSetting("keyboard_layout")
        end
    end
end

local function open_search()
    local sid  = Browse._source_id
    local meta = ExtMgr.getMeta(sid) or {}
    local ext  = ExtMgr.get(sid)
    -- Doit être fait AVANT InputDialog:new : le clavier lit le réglage à sa création.
    local restore_keyboard = use_source_keyboard(ext)
    local dlg
    dlg = InputDialog:new{
        title      = T("Rechercher — ") .. (meta.name or sid),
        input_hint = (ext and ext.searchHint) or T("Titre du roman..."),
        buttons    = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            {
                text             = T("Rechercher"),
                is_enter_default = true,
                callback         = function()
                    local term = dlg:getInputText()
                    UIManager:close(dlg)
                    if term and term ~= "" then
                        Browse._search = term
                        Browse.fetchAndShow(sid, 1, term)
                    end
                end,
            },
        }},
    }
    -- Quelle que soit la façon dont la boîte se ferme (boutons, tap à côté,
    -- touche retour), on restaure le clavier d'origine.
    local orig_close = dlg.onCloseWidget
    dlg.onCloseWidget = function(self_, ...)
        restore_keyboard()
        if orig_close then return orig_close(self_, ...) end
    end
    UIManager:show(dlg)
end

-- ── Recherche globale (toutes les sources visibles, donc filtrées par langue) ──

local MAX_PER_SOURCE = 30

-- Normalisation pour la comparaison de titres : minuscules, ponctuation ASCII
-- retirée, espaces multiples réduits. Les caractères non ASCII (accents,
-- caractères chinois…) sont conservés tels quels.
local function norm_title(s)
    s = tostring(s or ""):lower():gsub("%p", " "):gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Browse.globalSearch(term)
    if not term or term == "" then return end
    local sources = ExtMgr.visible()
    if #sources == 0 then
        local msg = (#ExtMgr.installed() == 0)
            and T("Aucune source installée — allez dans l'onglet Sources")
            or  T("Aucune source pour ce filtre de langue.")
        UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
        return
    end

    _fetch_id = _fetch_id + 1
    local my_id = _fetch_id

    Online.run(function()
        if my_id ~= _fetch_id then return end

        local results, failed = {}, 0
        local i, progress = 0, nil

        local function finish()
            if progress then UIManager:close(progress); progress = nil end
            if #results == 0 then
                UIManager:show(InfoMessage:new{
                    text = T("Aucun titre exactement égal à « ") .. term .. T(" »")
                        .. (failed > 0 and ("\n(" .. failed .. T(" source(s) en erreur)")) or ""),
                    timeout = 4,
                })
                return
            end
            Browse._state    = "global"
            Browse._gresults = results
            Browse._gterm    = term
            Browse._gpage    = 1
            if failed > 0 then
                UIManager:show(InfoMessage:new{ text = failed .. T(" source(s) en erreur ignorée(s)."), timeout = 3 })
            end
            require("ui.main_widget").show("browse")
        end

        local function step()
            if progress then UIManager:close(progress); progress = nil end
            if my_id ~= _fetch_id then return end
            i = i + 1
            if i > #sources then return finish() end

            local m = sources[i]
            progress = InfoMessage:new{
                text = string.format(T("Recherche… (%d/%d)\n%s"), i, #sources, m.name or m.id),
            }
            UIManager:show(progress)
            UIManager:scheduleIn(0.1, function()
                if my_id ~= _fetch_id then
                    if progress then UIManager:close(progress); progress = nil end
                    return
                end
                local ext = ExtMgr.get(m.id)
                if ext and ext.searchNovels then
                    local ok, res = pcall(ext.searchNovels, ext, term, 1)
                    if ok and res then
                        local novels = res.novels or res
                        -- Recherche globale : uniquement les titres EXACTEMENT
                        -- égaux au terme saisi (ex. « shadow slave » ne ramène
                        -- pas « shadow »… et inversement).
                        local wanted = norm_title(term)
                        local kept = 0
                        for n = 1, #novels do
                            local nv = novels[n]
                            if norm_title(nv.name or nv.title) == wanted then
                                table.insert(results, { source_id = m.id, source_name = m.name or m.id, novel = nv })
                                kept = kept + 1
                                if kept >= MAX_PER_SOURCE then break end
                            end
                        end
                    else
                        failed = failed + 1
                    end
                end
                UIManager:scheduleIn(0.05, step)
            end)
        end

        step()
    end)
end

function Browse.globalSearchPrompt()
    local dlg
    dlg = InputDialog:new{
        title      = T("Rechercher dans toutes les sources") .. ExtMgr.langTitleSuffix(),
        input_hint = T("Titre du roman..."),
        buttons    = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            {
                text             = T("Rechercher"),
                is_enter_default = true,
                callback         = function()
                    local term = dlg:getInputText()
                    UIManager:close(dlg)
                    if term and term ~= "" then Browse.globalSearch(term) end
                end,
            },
        }},
    }
    UIManager:show(dlg)
end

local function build_global_rows()
    local res = Browse._gresults
    local cap = math.max(1, math.floor(P.CONTENT_H_NAV / P.ROW_H))
    local max_pages = math.max(1, math.ceil(#res / cap))
    if Browse._gpage > max_pages then Browse._gpage = max_pages end
    if Browse._gpage < 1 then Browse._gpage = 1 end

    local rows  = {}
    local first = (Browse._gpage - 1) * cap + 1
    for i = first, math.min(#res, first + cap - 1) do
        local r = res[i]
        table.insert(rows, P.makeRow(r.novel.name or r.novel.title or "?", {
            mandatory = r.source_name,
            callback  = function()
                if Browse.on_novel_tap then Browse.on_novel_tap(r.source_id, r.novel) end
            end,
        }))
    end

    local nav = {
        page        = Browse._gpage,
        max_pages   = max_pages,
        show_visual = true,
        on_prev = Browse._gpage > 1 and function() Browse._gpage = Browse._gpage - 1; rebuild() end or nil,
        on_next = Browse._gpage < max_pages and function() Browse._gpage = Browse._gpage + 1; rebuild() end or nil,
    }
    local title = "« " .. (Browse._gterm or "") .. " » (" .. #res .. ")"
    return rows, title, nav
end

local function build_source_picker_rows()
    local SefirahUI  = require("ui.main_widget")
    local installed = ExtMgr.visible()
    local rows = {}

    if #installed == 0 then
        table.insert(rows, P.makeRow(T("Aucune source installée — allez dans l'onglet Sources"), {
            dim = true,
            callback = function() SefirahUI.show("sources") end,
        }))
        return rows, T("Parcourir"), nil, {
            kind_switch = P.kindSwitch(function() Browse._picker_page = 1; rebuild() end, { scope = "installed" }),
        }
    end

    for _, meta in ipairs(installed) do
        local m = meta
        table.insert(rows, P.makeSourceRow(m.name, (m.lang or "en"):upper(), {
            id        = m.id,
            callback  = function()
                Browse._source_id = m.id
                Browse._search    = nil
                -- Source avec écran d'accueil (AO3) : on l'affiche tout de
                -- suite, SANS aucune requête réseau.
                local x = ExtMgr.get(m.id)
                if x and x.fandomList then
                    Browse.openFandoms()
                    return
                end
                Browse.fetchAndShow(m.id, 1, nil)
            end,
            hold_callback = function()
                ExtMgr.uninstall(m.id)
                Browse._picker_page = 1
                rebuild()
            end,
        }))
    end

    -- Pagination : avec 15 sources natives + NovelFrance, la liste ne tient pas sur
    -- un seul écran. Auparavant elle était simplement tronquée à ce qui rentrait
    -- (cf. le bloc de troncature ci-dessous, maintenant retiré) et le reste des
    -- sources était invisible et inatteignable. Même mécanisme page/nav que
    -- l'onglet Sources (ui/sources.lua) : Suivant/Précédent, glisser gauche/droite.
    -- Pagination par hauteur RÉELLE des lignes (pas un compte deviné) : la
    -- barre Bibliothèque / Parcourir / Sources est ancrée en bas de l'écran et
    -- ne doit jamais être chevauchée/rognée par la liste des extensions. On
    -- empile les lignes une à une par leur hauteur réelle jusqu'à P.CONTENT_H
    -- (moins une marge de sécurité P.MARGIN), quitte à laisser une extension
    -- de moins sur la page plutôt que de risquer un débordement.
    local budget = P.CONTENT_H - P.MARGIN
    local pages, cur, used = {}, {}, 0
    for _, r in ipairs(rows) do
        local h = r:getSize().h
        if used + h > budget and #cur > 0 then
            table.insert(pages, cur)
            cur, used = {}, 0
        end
        table.insert(cur, r)
        used = used + h
    end
    table.insert(pages, cur)

    local max_pages = #pages
    if Browse._picker_page > max_pages then Browse._picker_page = max_pages end
    local visible = pages[Browse._picker_page]

    local nav = max_pages > 1 and {
        page        = Browse._picker_page,
        max_pages   = max_pages,
        -- Pas de barre 1/M ni de flèches : l'espace reste disponible pour les extensions.
        -- Le panneau conserve néanmoins `nav`, donc le glissement gauche/droite fonctionne.
        show_visual = false,
        on_prev   = Browse._picker_page > 1 and function() Browse._picker_page = Browse._picker_page - 1; rebuild() end or nil,
        on_next   = Browse._picker_page < max_pages and function() Browse._picker_page = Browse._picker_page + 1; rebuild() end or nil,
    } or nil

    local actions = {
        kind_switch = P.kindSwitch(function() Browse._picker_page = 1; rebuild() end, { scope = "installed" }),
        on_search = Browse.globalSearchPrompt,
        on_lang = function()
            LangFilter.show(function()
                Browse._picker_page = 1
                rebuild()
            end)
        end,
    }

    return visible, T("Parcourir") .. ExtMgr.langTitleSuffix(), nav, actions
end

-- ── Filtres « Populaire » déclarés par l'extension (ex. catégorie/période) ──
-- Contrat attendu, optionnel, sur la table d'extension :
--   ext.popularFilters = {
--       { key = "category", label = "Classement", default = "general",
--         options = { { id = "general", label = "Général" }, ... } },
--       { key = "period",   label = "Période",    default = "all",
--         options = { { id = "week", label = "Semaine" }, ... } },
--   }
-- Chaque groupe est passé tel quel dans `options.filters` à ext:popularNovels.

-- En recherche d'œuvres, une extension peut déclarer ses propres filtres dans
-- `ext.searchFilters` (même format) ; sans cela, pas de bouton filtre en recherche.
local function get_filter_defs(source_id, is_search)
    local ext = ExtMgr.get(source_id)
    if not ext then return nil end
    -- Une liste de filtres vide = pas de filtres (sinon bouton filtre + panneau vide).
    local defs
    if is_search then defs = ext.searchFilters else defs = ext.popularFilters end
    if type(defs) == "table" and #defs == 0 then return nil end
    return defs
end

-- Renvoie (et initialise si besoin, à partir des défauts déclarés par
-- l'extension) la sélection courante de filtres pour cette source.
local function get_filters(source_id, is_search)
    local defs = get_filter_defs(source_id, is_search)
    if not defs then return nil end
    -- Sélection séparée pour la recherche (tri par défaut différent).
    local store = is_search and (source_id .. ":search") or source_id
    local cur = Browse._filters[store]
    if not cur then
        cur = {}
        -- Reprend les derniers filtres choisis (mémorisés entre deux sessions) ;
        -- une valeur qui n'existe plus dans les options connues retombe sur le défaut.
        local saved = (require("settings"):get("browse_filters") or {})[store] or {}
        for _, f in ipairs(defs) do
            local v = saved[f.key]
            local ok = false
            if v ~= nil then
                if f.multi then
                    ok = type(v) == "string"   -- sélection multiple : « id1,id2,… »
                elseif f.options and #f.options > 0 then
                    for _, o in ipairs(f.options) do
                        if o.id == v then ok = true break end
                    end
                else
                    ok = true -- options chargées plus tard (genres, tags…)
                end
            end
            if ok then cur[f.key] = v else cur[f.key] = f.default end
        end
        Browse._filters[store] = cur
    end
    return cur
end

-- Mémorise la sélection courante pour la prochaine ouverture.
local function save_filters(source_id, is_search)
    local store = is_search and (source_id .. ":search") or source_id
    local cur = Browse._filters[store]
    if not cur then return end
    local Settings = require("settings")
    local all = Settings:get("browse_filters") or {}
    local copy = {}
    for k, v in pairs(cur) do
        if type(v) ~= "table" and type(v) ~= "function" then copy[k] = v end
    end
    all[store] = copy
    Settings:set("browse_filters", all)
end

local function result_title()
    local meta      = ExtMgr.getMeta(Browse._source_id) or {}
    local is_search  = Browse._search ~= nil
    local xe = (not is_search) and ExtMgr.get(Browse._source_id) or nil
    if xe and xe.listTitle then return xe:listTitle() end

    if is_search then
        return (meta.name or Browse._source_id) .. "  —  \"" .. Browse._search .. "\""
    end

    -- Demandé (2026-09-15) : plus de récapitulatif des filtres à droite du nom
    -- de la source. Avec une source à plusieurs groupes de filtres (NovelFire :
    -- Genre · Tri · Statut · Pays), ce libellé mangeait toute la barre de titre
    -- et poussait les icônes loupe / filtre / ⋮ hors de l'écran. Le nom seul
    -- suffit : la sélection courante reste visible (cochée) dans l'écran de
    -- filtres lui-même.
    return meta.name or Browse._source_id
end

-- Ouvre l'écran de filtres : deux colonnes côte à côte (une par groupe, ex.
-- Catégorie / Période), sélection locale tant qu'on n'a pas touché
-- "Appliquer" (← annule sans rien changer).
local function show_filters_panel(source_id)
    local is_search = Browse._search ~= nil
    local defs = get_filter_defs(source_id, is_search)
    if not defs then return end
    local cur = get_filters(source_id, is_search)
    local term = Browse._search

    -- Les options (genres, tags...) peuvent avoir été relues sur le site :
    -- complète les groupes nouveaux et remet à leur défaut les sélections
    -- qui n'existent plus dans la liste.
    for _, f in ipairs(defs) do
        local found = false
        if f.multi then
            found = type(cur[f.key]) == "string"
        else
            for _, o in ipairs(f.options or {}) do
                if o.id == cur[f.key] then found = true break end
            end
        end
        if not found then cur[f.key] = f.default end
    end

    P.showFilterPanel(T("Filtrer"), defs, cur, function(work)
        for _, f in ipairs(defs) do
            cur[f.key] = work[f.key]
        end
        pcall(save_filters, source_id, is_search)
        Browse.fetchAndShow(source_id, 1, term)
    end, function()
        rebuild()
    end)
end

local function open_filters()
    local source_id = Browse._source_id
    if not get_filter_defs(source_id, Browse._search ~= nil) then return end
    local ext = ExtMgr.get(source_id)

    -- Extension qui sait lire ses filtres sur le site (genres, tags,
    -- statuts) : 1re ouverture = quelques requêtes, ensuite instantané.
    if ext and ext.loadFilters and not ext.filters_ready then
        Online.run(function()
            local loading = InfoMessage:new{ text = T("Chargement des filtres…") }
            UIManager:show(loading)
            UIManager:scheduleIn(0.1, function()
                pcall(ext.loadFilters, ext)
                UIManager:close(loading)
                show_filters_panel(source_id)
            end)
        end)
        return
    end
    show_filters_panel(source_id)
end

-- Combien de romans remplissent une page de parcours à l'écran, dans le mode d'affichage
-- *actuel* (grille de couvertures vs liste texte). Reflète exactement le calcul que les générateurs de lignes
-- ci-dessous utilisent, pour que la boucle de récupération tire exactement autant de pages source que ce que
-- l'écran peut réellement afficher — pas de page à moitié vide, pas de récupérations gaspillées.
-- Fixé à 2 rangées × P.GRID_COLS (3) = 6 romans par page en mode grille de couvertures,
-- indépendamment du nombre de rangées qui tiendraient autrement dans la hauteur de l'écran.
local BROWSE_GRID_ROWS = 2

-- Couvertures en grille, sauf pour les sources marquées `listMode` (Scribble Hub :
-- une ligne de texte par roman).
local function covers_on(source_id)
    if source_id and (ExtMgr.getMeta(source_id) or {}).listMode then return false end
    return Settings:get("covers_browse") and true or false
end

-- Source à lignes « riches » (icône + titre + sous-titre, ex. AO3 avec le logo
-- à la place de la couverture) : lignes plus hautes, donc moins par page.
local function is_rich(source_id)
    return source_id and (ExtMgr.getMeta(source_id) or {}).richList and true or false
end

local function page_capacity(source_id)
    if is_rich(source_id) then
        return math.max(1, math.floor(P.CONTENT_H_NAV / P.SOURCE_ROW_H))
    end
    if covers_on(source_id) then
        return P.GRID_COLS * BROWSE_GRID_ROWS
    else
        return math.max(1, math.floor(P.CONTENT_H_NAV / P.ROW_H))
    end
end

local function result_nav(source_id, page)
    return {
        page    = page,
        on_prev = page > 1 and function()
            Browse.fetchAndShow(source_id, page - 1, Browse._search)
        end or nil,
        on_next = function()
            Browse.fetchAndShow(source_id, page + 1, Browse._search)
        end,
    }
end

-- ── Rendu en liste texte (couvertures désactivées) ────────────────────────────

local function build_novel_list_rows()
    local source_id = Browse._source_id
    local novels    = Browse._novels
    local rows      = {}

    local rich = is_rich(source_id)
    local max_novel_rows = math.max(1, math.floor(P.CONTENT_H_NAV / (rich and P.SOURCE_ROW_H or P.ROW_H)))

    if #novels == 0 then
        table.insert(rows, P.makeRow(T("Aucun résultat"), { dim = true, callback = function() end }))
    elseif rich then
        local icon = P.ICON_SORT:gsub("sort%.png$", "ao3_icon.png")
        for i = 1, math.min(#novels, max_novel_rows) do
            local novel = novels[i]
            table.insert(rows, P.makeSourceRow(novel.name or novel.title or "?", novel.subtitle or novel.author or "", {
                icon_file = icon,
                mandatory = novel.badge,
                callback  = function()
                    if Browse.on_novel_tap then Browse.on_novel_tap(source_id, novel) end
                end,
            }))
        end
    else
        for i = 1, math.min(#novels, max_novel_rows) do
            local novel = novels[i]
            table.insert(rows, P.makeRow(novel.name or novel.title or "?", {
                mandatory = novel.author or "",
                callback  = function()
                    if Browse.on_novel_tap then Browse.on_novel_tap(source_id, novel) end
                end,
            }))
        end
    end

    return rows, result_title(), result_nav(source_id, Browse._page)
end

-- ── Rendu en grille de couvertures (couvertures activées) ────────────────────

local function build_novel_grid_rows()
    free_covers()

    local source_id = Browse._source_id
    local novels     = Browse._novels

    if #novels == 0 then
        local rows = {}
        table.insert(rows, P.makeRow(T("Aucun résultat"), { dim = true, callback = function() end }))
        return rows, result_title(), nil
    end

    -- Espace dispo pour la grille, sans jamais toucher à P.CONTENT_H_NAV (donc jamais
    -- à P.TAB_H / la barre Bibliothèque / Parcourir / Sources en bas) — même logique de
    -- dernier recours que Bibliothèque (build_grid_rows dans library.lua).
    local content_h = P.CONTENT_H_NAV

    local function cell_and_need(cover_h)
        local cell_h = cover_h + P.GRID_TITLE_H + P.GRID_CELL_PAD
        return cell_h, BROWSE_GRID_ROWS * cell_h + P.GRID_BOTTOM_GAP
    end

    -- 1) Taille normale d'abord.
    local browse_cover_w      = P.GRID_COVER_DISP_W
    local browse_cover_h      = P.GRID_COVER_DISP_H
    local browse_cell_h, need = cell_and_need(browse_cover_h)

    -- Source « gridFill » (Anime-Sama) : les couvertures remplissent la hauteur libre
    -- au lieu de laisser du vide sous la grille. La grille de Parcourir n'a pas de
    -- barre ‹ N/M › visible (la zone de contenu fait donc P.CONTENT_H, pas
    -- P.CONTENT_H_NAV) : on dimensionne les 2 rangées pour qu'elles tiennent
    -- EXACTEMENT dans cet espace. Avant, la hauteur « normale » (trop grande) servait de
    -- plancher et la grille débordait, ce qui poussait la barre
    -- Bibliothèque / Parcourir / Sources / Paramètres vers le bas, hors de l'écran.
    local xe_grid = ExtMgr.get(source_id)
    local fill = xe_grid and xe_grid.gridFill
    if fill then
        browse_cover_w = P.GRID_COVER_W
        local avail = math.floor((P.CONTENT_H - P.GRID_BOTTOM_GAP) / BROWSE_GRID_ROWS)
            - P.GRID_TITLE_H - P.GRID_CELL_PAD
        browse_cover_h = math.max(1, math.min(avail, math.floor(browse_cover_w * 1.6)))
        browse_cell_h, need = cell_and_need(browse_cover_h)
    end

    -- 2) Dernier recours seulement : les 2 rangées à taille normale ne tiennent pas
    -- dans l'espace dispo → on réduit l'affichage de toutes les couvertures de la page.
    if need > content_h and not fill then
        browse_cover_w = math.floor(browse_cover_w * 0.9)
        browse_cover_h = math.floor(browse_cover_w * 1.45)
        browse_cell_h  = cell_and_need(browse_cover_h)
    end

    local max_per_page   = P.GRID_COLS * BROWSE_GRID_ROWS
    local page_novels    = {}
    for i = 1, math.min(#novels, max_per_page) do
        table.insert(page_novels, novels[i])
    end

    local site = (ExtMgr.getMeta(source_id) or {}).site
    local items = {}
    for _, novel in ipairs(page_novels) do
        local path     = novel.path or novel.sourceUrl or ""
        local cover_bb = Covers.get(source_id, path, nil, nil, browse_cover_w, browse_cover_h)
        if cover_bb then table.insert(_cover_bbs, cover_bb) end

        table.insert(items, {
            title    = novel.name or novel.title or "?",
            cover_bb = cover_bb,
            cover_w  = browse_cover_w,
            cover_h  = browse_cover_h,
            cell_h   = browse_cell_h,
            callback = function()
                if Browse.on_novel_tap then Browse.on_novel_tap(source_id, novel) end
            end,
        })
    end

    local grid = P.makeCoverGrid(items, browse_cell_h * math.ceil(#page_novels / P.GRID_COLS))
    local rows = { grid }

    prefetch_missing_covers(source_id, page_novels)

    return rows, result_title(), result_nav(source_id, Browse._page)
end

-- ── Accueil d'une source (AO3) : menu instantané, rien n'est chargé ─────────

local function trunc(s, n)
    s = tostring(s or "")
    local count, i = 0, 1
    while i <= #s do
        local c = s:byte(i)
        local len = c < 0x80 and 1 or (c < 0xE0 and 2 or (c < 0xF0 and 3 or 4))
        count = count + 1
        if count > n then return s:sub(1, i - 1) .. "…" end
        i = i + len
    end
    return s
end

local function back_to_picker()
    Browse._state = "picker"
    rebuild()
end

-- Ouverture INSTANTANÉE : cache disque/mémoire, sinon liste hors ligne
-- embarquée. Aucune requête réseau ; « Actualiser » charge la liste complète.
function Browse.openFandoms()
    local ext = ExtMgr.get(Browse._source_id)
    if not ext or not ext.fandomList then return end
    local items = ext.cachedFandoms and ext:cachedFandoms()
    Browse._fandoms_fallback = (items == nil)
    Browse._fandom_items = items or ext:fallbackFandoms()
    Browse._fpage  = 1
    Browse._fandom_sub = false
    Browse._state  = "fandoms"
    rebuild()
end

function Browse.refreshFandoms()
    local ext = ExtMgr.get(Browse._source_id)
    if not ext or not ext.fandomList then return end
    Online.run(function()
        local loading = InfoMessage:new{ text = T("Chargement des fandoms…") }
        UIManager:show(loading)
        UIManager:scheduleIn(0.1, function()
            local ok, items, live = pcall(ext.fandomList, ext)
            UIManager:close(loading)
            if ok and items then
                Browse._fandoms_fallback = not live
                Browse._fandom_items = items
                Browse._fandom_sub = false
                Browse._fpage = 1
                Browse._state = "fandoms"
                rebuild()
            else
                UIManager:show(InfoMessage:new{ text = T("Erreur : ") .. tostring(items), timeout = 4 })
            end
        end)
    end)
end

local function search_fandom_prompt()
    local sid = Browse._source_id
    local ext = ExtMgr.get(sid)
    if not ext or not ext.searchFandoms then return end
    local dlg
    dlg = InputDialog:new{
        title      = T("Rechercher un fandom"),
        input_hint = T("Nom du fandom..."),
        buttons    = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            {
                text             = T("Rechercher"),
                is_enter_default = true,
                callback         = function()
                    local term = dlg:getInputText()
                    UIManager:close(dlg)
                    if not term or term == "" then return end
                    Online.run(function()
                        local loading = InfoMessage:new{ text = T("Recherche…") }
                        UIManager:show(loading)
                        UIManager:scheduleIn(0.1, function()
                            local ok, items, err = pcall(ext.searchFandoms, ext, term)
                            UIManager:close(loading)
                            if ok and items then
                                local list = { { header = true, text = "« " .. term .. " »" } }
                                for _, it in ipairs(items) do list[#list + 1] = it end
                                Browse._fandom_items = list
                                Browse._fandom_sub = true
                                Browse._fpage = 1
                                rebuild()
                            else
                                UIManager:show(InfoMessage:new{
                                    text = (ok and err) or tostring(items), timeout = 4 })
                            end
                        end)
                    end)
                end,
            },
        }},
    }
    UIManager:show(dlg)
end

-- Case « All » : tous les fandoms d'une catégorie (réseau), avec une ligne de retour.
local function open_category_all(header)
    local ext = ExtMgr.get(Browse._source_id)
    if not ext or not ext.categoryFandoms then return end
    Online.run(function()
        local loading = InfoMessage:new{ text = T("Chargement de la liste complète… (la première fois, cela peut prendre une à deux minutes)") }
        UIManager:show(loading)
        UIManager:scheduleIn(0.1, function()
            local ok, items, err = pcall(ext.categoryFandoms, ext, header.href, header.text)
            UIManager:close(loading)
            if ok and items then
                local list = { { header = true, text = header.text .. " — All" } }
                for _, it in ipairs(items) do list[#list + 1] = it end
                Browse._fandom_items = list
                Browse._fandom_sub = true
                Browse._fpage = 1
                rebuild()
            else
                UIManager:show(InfoMessage:new{ text = (ok and err) or tostring(items), timeout = 10 })
            end
        end)
    end)
end

-- Fandoms en cases (2 par rangée), regroupés par catégorie de média.
function Browse.build_fandom_rows()
    local sid = Browse._source_id
    local ext = ExtMgr.get(sid)
    local blocks = {}   -- { widget, h }
    local function add(w, h) blocks[#blocks + 1] = { w = w, h = h, header = false } return blocks[#blocks] end
    -- Barre de recherche de fandoms (la loupe du bandeau cherche, elle, des œuvres).
    add(P.makeSearchBar(T("Rechercher un fandom…"), search_fandom_prompt), P.SEARCH_BAR_BLOCK_H)
    if Browse._fandom_sub then
        add(P.makeRow("‹ " .. T("Fandoms"), { bold = true, callback = Browse.openFandoms }), P.ROW_H)
    elseif Browse._fandoms_fallback then
        add(P.makeRow(T("Charger la liste complète depuis AO3"), { bold = true, callback = Browse.refreshFandoms }), P.ROW_H)
    end
    local pending = {}
    local function flush()
        if #pending > 0 then add(P.makeTileRow(pending, 2), P.TILE_ROW_H); pending = {} end
    end
    -- Case « All » en fin de catégorie (sauf dans la vue « All » elle-même).
    local cur_header
    local function add_all_tile()
        if cur_header and not Browse._fandom_sub then
            local hd = cur_header
            pending[#pending + 1] = {
                title = "All", sub = "…",
                callback = function() open_category_all(hd) end,
            }
            if #pending == 2 then flush() end
        end
        cur_header = nil
    end
    for _, it in ipairs(Browse._fandom_items or {}) do
        if it.header then
            add_all_tile()
            flush()
            cur_header = it
            add(P.makeRow(trunc(it.text, 40), { dim = true, bold = true, callback = function() end }), P.ROW_H).header = true
        else
            local item = it
            pending[#pending + 1] = {
                title = item.name, sub = item.count,
                callback = function()
                    if ext and ext.setContext then ext:setContext(item.href, item.name) end
                    Browse._search = nil
                    Browse.fetchAndShow(sid, 1, nil)
                end,
            }
            if #pending == 2 then flush() end
        end
    end
    add_all_tile()
    flush()

    -- Pagination par hauteur cumulée ; un titre de catégorie n'est jamais seul en bas de page.
    local pages, cur, used = {}, {}, 0
    for i, b in ipairs(blocks) do
        local nxt = blocks[i + 1]
        local need = b.h + ((b.header and nxt) and nxt.h or 0)
        if #cur > 0 and used + need > P.CONTENT_H then
            pages[#pages + 1] = cur; cur, used = {}, 0
        end
        cur[#cur + 1] = b.w; used = used + b.h
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    if #pages == 0 then pages[1] = {} end
    local max_pages = #pages
    Browse._fpage = math.min(math.max(Browse._fpage or 1, 1), max_pages)
    local nav = {
        page = Browse._fpage, max_pages = max_pages, show_visual = false, -- pas de barre ‹ N/M › : balayage gauche/droite
        on_prev = Browse._fpage > 1 and function() Browse._fpage = Browse._fpage - 1; rebuild() end or nil,
        on_next = Browse._fpage < max_pages and function() Browse._fpage = Browse._fpage + 1; rebuild() end or nil,
    }
    local actions = {
        on_search    = open_search,   -- loupe = recherche d'œuvres (comme /works/search)
        on_sort      = nil,   -- pas de filtre sur l'accueil ni sur la recherche de fandoms
        on_logo_tap  = back_to_picker,
        on_title_tap = back_to_picker,
    }
    return pages[Browse._fpage], T("Fandoms"), nav, actions
end

function Browse.build_rows()
    local rows, title, nav
    local actions = nil
    if Browse._state == "fandoms" then
        free_covers()
        rows, title, nav, actions = Browse.build_fandom_rows()
    elseif Browse._state == "list" then
        if covers_on(Browse._source_id) then
            rows, title, nav = build_novel_grid_rows()
        else
            free_covers()
            rows, title, nav = build_novel_list_rows()
        end
        -- Icône loupe (à côté de ⋮) au lieu d'une ligne "Rechercher" dans le contenu ;
        -- toucher le bandeau "Sefirah" en haut remplace la ligne "← Retour à la
        -- sélection de source".
        actions = {
            on_search   = open_search,
            -- Icône « filtre » : affichée si la source déclare des filtres pour ce
            -- contexte (popularFilters pour une liste, searchFilters pour une
            -- recherche d'œuvres — voir get_filter_defs). Jamais sur l'écran des fandoms.
            on_sort     = get_filter_defs(Browse._source_id, Browse._search ~= nil) and open_filters or nil,
            on_logo_tap = function()
                Browse._state = "picker"
                rebuild()
            end,
            -- Toucher le titre ("NovelFrance — "recherche"") efface directement la
            -- recherche en cours et recharge la page « Populaire » (page 1, sans terme).
            on_title_tap = function()
                local x = ExtMgr.get(Browse._source_id)
                if x and x.fandomList then
                    Browse._search = nil
                    Browse._state  = "fandoms"
                    rebuild()
                elseif Browse._search then
                    Browse._search = nil
                    Browse.fetchAndShow(Browse._source_id, 1, nil)
                end
            end,
        }
    elseif Browse._state == "global" and #Browse._gresults > 0 then
        free_covers()
        rows, title, nav = build_global_rows()
        local function back_to_picker()
            Browse._state = "picker"
            rebuild()
        end
        actions = {
            on_search    = Browse.globalSearchPrompt,
            -- Changer de langue relance la même recherche sur les nouvelles sources.
            on_lang      = function()
                LangFilter.show(function() Browse.globalSearch(Browse._gterm) end)
            end,
            on_logo_tap  = back_to_picker,
            on_title_tap = back_to_picker,
        }
    else
        free_covers()
        Browse._state = "picker"
        rows, title, nav, actions = build_source_picker_rows()
    end

    return rows, title, nav, actions
end

function Browse.fetchAndShow(source_id, page, search_term)
    local ext = ExtMgr.get(source_id)
    if not ext then
        UIManager:show(InfoMessage:new{
            text    = T("Extension non chargée : ") .. tostring(source_id),
            timeout = 3,
        })
        return
    end

    -- La page 1 est toujours le point d'entrée (nouvelle source, nouvelle recherche, ou « Retour à
    -- la sélection de source » → resélectionnée) — réinitialise le suivi des pages source pour que
    -- d'anciennes correspondances d'une session de parcours précédente ne puissent pas s'infiltrer.
    if page == 1 then
        Browse._page_start = { [1] = 1 }
        Browse._page_buffer = {}
    end

    -- Pages déjà affichées : on les resert telles quelles (retour en arrière sans
    -- re-télécharger ni décaler les romans mis en réserve d'une page à l'autre).
    if page == 1 then Browse._page_cache = {} end
    local cached = page > 1 and Browse._page_cache and Browse._page_cache[page]
    if cached then
        _fetch_id = _fetch_id + 1
        _prefetch_token = _prefetch_token + 1
        Browse._state     = "list"
        Browse._source_id = source_id
        Browse._novels    = cached
        Browse._page      = page
        Browse._search    = (search_term and search_term ~= "") and search_term or nil
        rebuild()
        return
    end

    _fetch_id = _fetch_id + 1
    _prefetch_token = _prefetch_token + 1
    local my_id = _fetch_id

    Online.run(function()
        if my_id ~= _fetch_id then return end

        local loading = InfoMessage:new{ text = T("Chargement…") }
        UIManager:show(loading)

        UIManager:scheduleIn(0.1, function()
            if my_id ~= _fetch_id then
                UIManager:close(loading)
                return
            end

            -- Une page d’écran = exactement 6 romans en mode grille.
            -- Si la source renvoie 12/20 romans d’un coup, on conserve les
            -- romans restants pour la page suivante au lieu de les perdre.
            local capacity  = page_capacity(source_id)
            local src_page  = Browse._page_start[page] or 1
            local all_novels = Browse._page_buffer[page] or {}
            Browse._page_buffer[page] = nil
            -- Correctif : une source qui renvoie beaucoup de romans d'un coup (ex. 15 ou 24)
            -- en laissait plus que l'écran n'en affiche dans la réserve ; l'excédent était
            -- alors perdu (« les 3 derniers résultats n'apparaissent pas »). On le remet en
            -- réserve pour la page suivante.
            if #all_novels > capacity then
                local rest = {}
                for i = capacity + 1, #all_novels do rest[#rest + 1] = all_novels[i] end
                for i = #all_novels, capacity + 1, -1 do all_novels[i] = nil end
                Browse._page_buffer[page + 1] = rest
            end
            local err
            -- Distinct from `err` (a Lua error from pcall): this is a normal
            -- return value some extensions set (res.error) when they detect
            -- they were blocked (e.g. a Cloudflare challenge page) rather
            -- than genuinely finding zero novels — so "Aucun résultat" and
            -- "bloqué par le site" don't look identical to the user.
            local blocked_reason
            local fetches = 0
            -- Résolu une seule fois par appel : nil pour une source sans filtres
            -- déclarés (ext.popularFilters absent), sinon la sélection courante
            -- ({ [filter_key] = selected_option_id }, initialisée aux défauts).
            local is_search_fetch = search_term and search_term ~= ""
            local popular_filters = (not is_search_fetch) and get_filters(source_id) or nil
            local search_filters  = is_search_fetch and get_filters(source_id, true) or nil

            -- Enchaîne des pages côté source consécutives jusqu'à ce que l'écran soit plein
            -- (ou que la source soit épuisée / échoue).
            while #all_novels < capacity and fetches < MAX_SRC_FETCHES do
                fetches = fetches + 1
                local novels
                if search_term and search_term ~= "" then
                    local ok, res = pcall(ext.searchNovels, ext, search_term, src_page, { filters = search_filters })
                    if ok and res then
                        novels = res.novels or res
                        blocked_reason = blocked_reason or res.error
                    else
                        err = tostring(res)
                    end
                else
                    local ok, res = pcall(ext.popularNovels, ext, src_page, { filters = popular_filters })
                    if ok and res then
                        novels = res.novels or res
                        blocked_reason = blocked_reason or res.error
                    else
                        err = tostring(res)
                    end
                end

                if err then break end

                if not novels or #novels == 0 then
                    -- La page source n'existait pas vraiment / était vide —
                    -- ne pas la compter comme consommée, pour que retaper sur Suivant plus tard
                    -- réessaie depuis le même endroit au lieu de sauter en avant.
                    src_page = src_page - 1
                    break
                end

                local needed = capacity - #all_novels
                if #novels <= needed then
                    for _, n in ipairs(novels) do table.insert(all_novels, n) end
                    src_page = src_page + 1
                else
                    -- La source a fourni plus que ce que l’écran peut afficher.
                    -- On garde le surplus pour la prochaine page app.
                    for i = 1, needed do
                        table.insert(all_novels, novels[i])
                    end
                    local rest = {}
                    for i = needed + 1, #novels do
                        table.insert(rest, novels[i])
                    end
                    Browse._page_buffer[page + 1] = rest
                    src_page = src_page + 1
                    break
                end
            end

            -- src_page pointe maintenant vers la première page source *non consommée* —
            -- c'est de là que la prochaine page app devrait partir.
            Browse._page_start[page + 1] = src_page

            UIManager:close(loading)

            if err then
                UIManager:show(InfoMessage:new{ text = T("Erreur : ") .. err, timeout = 4 })
                return
            end

            if #all_novels == 0 and blocked_reason then
                UIManager:show(InfoMessage:new{ text = blocked_reason, timeout = 5 })
            end

            Browse._state     = "list"
            Browse._source_id = source_id
            Browse._novels    = all_novels
            Browse._page      = page
            Browse._search    = (search_term and search_term ~= "") and search_term or nil
            Browse._page_cache = Browse._page_cache or {}
            if #all_novels > 0 then Browse._page_cache[page] = all_novels end
            rebuild()
        end)
    end)
end

function Browse.close()
    free_covers()
end

return Browse
