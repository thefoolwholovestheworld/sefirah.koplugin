-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- Onglet Sources : sources Lua natives livrées avec le plugin ; il faut les
-- installer ici avant de pouvoir les utiliser dans Parcourir.
local UIManager   = require("ui/uimanager")
local ConfirmBox  = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local ExtMgr      = require("core.extmgr")
local Settings    = require("sefirah_settings")
local P           = require("ui.panel")
local LangFilter  = require("ui.lang_filter")
local Catalog     = require("core.catalog")

local Sources = {}
local _page = 1
local _search = nil   -- texte cherché parmi les extensions (nom, site, langue) ; nil = tout

-- Recherche d'une extension : demande un texte, puis filtre la liste ci-dessous.
local function open_search()
    local dlg
    dlg = InputDialog:new{
        title      = T("Rechercher une extension"),
        input      = _search or "",
        input_hint = T("Nom de l'extension..."),
        buttons    = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            {
                text = T("Rechercher"), is_enter_default = true,
                callback = function()
                    local term = (dlg:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dlg)
                    _search = term ~= "" and term or nil
                    _page = 1
                    require("ui.main_widget").show("sources")
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function matches(meta, q)
    q = q:lower()
    for _, f in ipairs({ meta.name, meta.site, meta.id, meta.lang }) do
        if f and tostring(f):lower():find(q, 1, true) then return true end
    end
    return false
end

local function rebuild()
    require("ui.main_widget").show("sources")
end

local function msg(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text })
end

local _auto_done = false   -- le catalogue en ligne n'est relu tout seul qu'une fois par ouverture de Sefirah

-- Relit le catalogue du Hub. manual = true : demande le Wi-Fi si besoin et affiche les erreurs.
local function refresh_catalog(manual)
    local NetworkMgr = require("ui/network/manager")
    local function go()
        local info
        if manual then
            info = require("ui/widget/infomessage"):new{ text = T("Lecture du catalogue…"), timeout = 30 }
            UIManager:show(info)
            UIManager:forceRePaint()
        end
        local ok, res = Catalog.refresh()
        if info then UIManager:close(info) end
        if ok then
            if res or manual then rebuild() end
        elseif manual then
            msg(T("Catalogue injoignable : ") .. tostring(res))
        end
    end
    if manual then
        NetworkMgr:runWhenOnline(go)
    else
        local okc, conn = pcall(NetworkMgr.isConnected, NetworkMgr)
        if okc and conn then go() end
    end
end

-- Télécharge une source du catalogue et l'installe.
local function install_remote(m)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local info = require("ui/widget/infomessage"):new{ text = T("Téléchargement de ") .. m.name .. "…", timeout = 60 }
        UIManager:show(info)
        UIManager:forceRePaint()
        local ok, err = Catalog.install(m)
        UIManager:close(info)
        if ok then
            rebuild()
        else
            msg(T("Installation impossible : ") .. tostring(err))
        end
    end)
end

local function close_all()
    if _G.sefirah_close_all then _G.sefirah_close_all() end
end

function Sources.ext_settings(meta)
    local SefirahUI = require("ui.main_widget")
    local ext = ExtMgr.get(meta.id)
    local sp = {}

    local function close_settings()
        if sp[1] then UIManager:close(sp[1]); sp[1] = nil end
        SefirahUI.clearDetail()
    end

    local rows = {
        P.makeRow(T("Source : ") .. meta.name, { dim = true, callback = function() end }),
        P.makeRow(T("Version : ") .. (meta.version or "native"), { dim = true, callback = function() end }),
        P.makeRow(T("Site : ") .. (meta.site or "?"), { dim = true, callback = function() end }),
    }

    if ext and ext.supports_page_mode then
        local pm = Settings:getExt(meta.id, "page_mode", false)
        table.insert(rows, P.makeRow(T("Mode Page : ") .. (pm and T("ACTIVÉ") or T("DÉSACTIVÉ")), {
            callback = function()
                Settings:toggleExt(meta.id, "page_mode", false)
                close_settings()
                rebuild()
            end,
        }))
    end

    -- Source venue du catalogue en ligne : mise à jour si le Hub en propose une plus récente.
    local upd = Catalog.updateFor(meta.id)
    if upd then
        table.insert(rows, P.makeRow(T("Mettre à jour : v") .. tostring(upd.version), {
            callback = function()
                close_settings()
                UIManager:show(ConfirmBox:new{
                    text = T("Mettre à jour la source ") .. meta.name .. " (v" .. tostring(upd.version) .. ") ?",
                    ok_text = T("Mettre à jour"),
                    ok_callback = function()
                        require("ui/network/manager"):runWhenOnline(function()
                            local ok, err = Catalog.install(upd)
                            if ok then msg(T("Source mise à jour : ") .. meta.name); rebuild()
                            else msg(T("Installation impossible : ") .. tostring(err)) end
                        end)
                    end,
                })
            end,
        }))
    end

    -- Réglages propres à l'extension (ex. Anime-Sama : adresse du site).
    if ext and ext.settingsRows then
        local ok, extra = pcall(ext.settingsRows, ext, {
            close = close_settings,
            reopen = function()
                local e = ExtMgr.get(meta.id)
                if e and e.site then meta.site = e.site end
                close_settings()
                Sources.ext_settings(meta)
            end,
            rebuild = rebuild,
        })
        if ok and extra then for _, r in ipairs(extra) do table.insert(rows, r) end end
    end

    table.insert(rows, P.makeRow(T("← Retour"), { callback = close_settings }))
    local p = P.showSubPanel(meta.name .. T(" — Réglages"), rows, close_settings, close_all)
    sp[1] = p
    SefirahUI.setDetail(p)
end

function Sources.build_rows()
    local rows = {}

    -- Toutes les sources livrées avec le plugin, installées ou non. Seules les
    -- sources installées apparaissent dans Parcourir et la recherche globale.
    Catalog.entries()   -- dernier catalogue connu (hors ligne) ; la mise à jour se fait après l'affichage
    if not _auto_done then
        _auto_done = true
        if Catalog.stale() then UIManager:nextTick(function() refresh_catalog(false) end) end
    end
    local all = ExtMgr.visibleAll()
    if _search then
        local found = {}
        for _, m in ipairs(all) do if matches(m, _search) then found[#found + 1] = m end end
        all = found
        table.insert(rows, P.makeRow(T('Recherche : « ') .. _search .. T(' »  ·  toucher pour changer'), {
            dim = true, callback = open_search,
            -- Appui long : efface la recherche (le titre est remplacé par Novels | Mangas).
            hold_callback = function() _search = nil; _page = 1; rebuild() end,
        }))
        table.insert(rows, P.hairline())
    end
    if #all == 0 then
        table.insert(rows, P.makeRow(_search and T("(aucune extension trouvée)") or T("(aucune source native)"),
            { dim = true, callback = function() end }))
    else
        for _, meta in ipairs(all) do
            local m = meta
            local is_installed = ExtMgr.isInstalled(m.id)
            table.insert(rows, P.makeSourceRow(
                m.name,
                (m.lang == "multi" and T("Multilingue") or m.lang or T("Français")) .. "  ·  " .. (m.site or ""), {
                    id = m.id,
                    right_icon = is_installed and P.ICON_GEAR or P.ICON_INSTALL,
                    right_callback = function()
                        if is_installed then
                            Sources.ext_settings(m)
                        elseif m.remote then
                            UIManager:show(ConfirmBox:new{
                                text = T("Installer la source ") .. m.name .. " (v" .. tostring(m.version) .. ") ?\n\n"
                                    .. T("Elle sera téléchargée depuis Sefirah Source Hub. Ce code sera exécuté par le plugin."),
                                ok_text = T("Installer"),
                                ok_callback = function() install_remote(m) end,
                            })
                        else
                            UIManager:show(ConfirmBox:new{
                                text = T("Installer la source ") .. m.name .. " ?",
                                ok_text = T("Installer"),
                                ok_callback = function()
                                    ExtMgr.install(m.id)
                                    rebuild()
                                end,
                            })
                        end
                    end,
                    hold_callback = function()
                        if not is_installed then return end
                        ExtMgr.uninstall(m.id)
                        rebuild()
                    end,
                }
            ))
        end
    end

    -- Pagination par hauteur RÉELLE des lignes, pas par un simple compte.
    -- Cet onglet mélange des lignes d'en-tête basses (P.ROW_H, via P.makeRow)
    -- et des lignes de source plus hautes (P.SOURCE_ROW_H, via P.makeSourceRow).
    -- L'ancien calcul (P.MAX_ROWS, prévu pour des lignes P.ROW_H uniquement)
    -- sous-estimait donc la hauteur totale dès qu'il y avait des sources
    -- installées : le contenu débordait de sa zone réservée et venait
    -- chevaucher/rogner la barre Bibliothèque / Parcourir / Sources en bas.
    -- On empile ici les lignes une à une par leur hauteur réelle, avec une
    -- marge de sécurité (P.MARGIN) — quitte à laisser une source de moins sur
    -- la page plutôt que de risquer un débordement.
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
    if _page > max_pages then _page = max_pages end
    local visible = pages[_page]

    local nav = max_pages > 1 and {
        page = _page,
        max_pages = max_pages,
        on_prev = _page > 1 and function() _page = _page - 1; rebuild() end or nil,
        on_next = _page < max_pages and function() _page = _page + 1; rebuild() end or nil,
    } or nil

    local actions = {
        kind_switch = P.kindSwitch(function() _page = 1; rebuild() end, { scope = "available" }),
        on_search = open_search,
        -- Icône antenne : reçoit une source envoyée depuis Sefirah Source Hub (code à 4 chiffres).
        on_receive = function()
            local dlg
            dlg = require("ui/widget/buttondialog"):new{
                title = T("Ajouter des sources"),
                title_align = "center",
                buttons = {
                    {{ text = T("Actualiser le catalogue"), callback = function()
                        UIManager:close(dlg); refresh_catalog(true) end }},
                    {{ text = T("Recevoir avec un code"), callback = function()
                        UIManager:close(dlg); require("core.receive").start() end }},
                },
            }
            UIManager:show(dlg)
        end,
        on_lang = function()
            LangFilter.show(function()
                _page = 1
                rebuild()
            end, true)
        end,
    }

    return visible, T("Sources") .. (_search and (" (" .. #all .. ")") or "") .. ExtMgr.langTitleSuffix(true), nav, actions
end

return Sources
