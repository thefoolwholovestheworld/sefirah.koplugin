-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- Détail du roman : onglet Détails (couverture, meta, synopsis, suivi) +
-- onglet Chapitres (liste paginée avec marqueurs de cache/export).
local UIManager   = require("ui/uimanager")
local Blitbuffer  = require("ffi/blitbuffer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer  = require("ui/widget/textviewer")
local Online      = require("core.online")
local ExtMgr      = require("core.extmgr")
local DB          = require("core.db")
local Avatars     = require("core.avatars")
local logger      = require("logger")
local Cache       = require("core.cache")
local Settings    = require("sefirah_settings")
local P           = require("ui.panel")
local Device      = require("device")
local Screen      = Device.screen
local Epub        = require("core.epub")
local Emoji       = require("core.emoji")
local Covers      = require("core.covers")

local function get_export_ui() return require("ui.export") end
local function get_reader_ui() return require("ui.readerview") end

local Detail = {}
Detail.on_back = nil

local _source_id    = nil
local _novel_info   = nil
local _all_chapters = {}
local _page         = 1
local _vol_filter   = nil  -- numéro de tome affiché dans l'onglet Chapitres (nil = tous)
local _vol_path     = nil  -- roman auquel se rapporte _vol_filter
local _detail_tab   = "details"  -- "details" | "chapters" | "reviews"
-- FIX : ordre des chapitres affichés par défaut. Auparavant "Settings:get(...) or false"
-- confondait "jamais réglé" (nil) et "explicitement décroissant" (false), les deux
-- tombant sur false → chapitres du plus récent au plus ancien à la première ouverture,
-- ce que personne ne lit dans cet ordre. On veut désormais croissant (1, 2, 3 ... N) par
-- défaut, tout en respectant un choix explicite déjà enregistré par l'utilisateur.
local function default_chapters_ascending()
    local v = Settings:get("chapters_ascending")
    if v == nil then return true end
    return v
end
local _ascending    = default_chapters_ascending() -- ordre des chapitres affichés, persisté (cf. sefirah_settings.lua)
local _panel        = nil
local _cover_bb     = nil
local _cover_data   = nil  -- octets bruts de la couverture décodée avec succès — permet de la
                           -- remettre en cache disque au moment du favori sans repasser par le réseau
local _fetch_id     = 0  -- cancels stale in-flight fetches
local _switch_generation = 0  -- debounces rapid Détails/Chapitres/Avis switches

-- ── Mode sélection de chapitres ───────────────────────────────────────────
-- Appui long sur un chapitre (ou « Sélectionner des chapitres » dans le menu
-- de l'icône téléchargement) : chaque chapitre devient cochable. Les actions
-- (télécharger / exporter / traduire) s'appliquent alors à la sélection.
local _sel_mode   = false
local _sel        = {}    -- [clé du chapitre] = true
local _sel_count  = 0
local _sel_anchor = nil   -- dernier index (dans _all_chapters) coché/décoché

local function sel_reset()
    _sel_mode, _sel, _sel_count, _sel_anchor = false, {}, 0, nil
end

-- ── Caches de l'onglet Chapitres (fluidité) ───────────────────────────────
-- Avant : à CHAQUE changement de page, tout le roman (parfois 3000+
-- chapitres) était retrié avec une regex par comparaison, et la liste des
-- exports relue. Désormais le tri n'est refait que si la liste, son nombre
-- ou le sens changent.
local _idx_cache = { chapters = nil, n = 0, asc = nil, list = nil, nums = nil }
local _exp_cache = { key = nil, rev = nil, set = nil }

-- Avis : pas de cache disque (contrairement aux chapitres), juste en mémoire
-- pour la session, avec pagination (page "Charger plus d'avis" côté site).
-- _reviews_key identifie le roman pour lequel _reviews est valide, pour ne
-- pas garder/afficher les avis d'un roman précédent.
local _reviews          = nil     -- nil = pas encore chargé ; {} = chargé mais vide ; liste normalisée sinon
local _reviews_key      = nil
local _reviews_page     = 0       -- dernière page d'avis chargée (0 = aucune)
local _reviews_has_more = false
local _reviews_loading  = false
local _reviews_error    = false  -- true ou texte de la cause = échec réseau/API au 1er chargement (≠ « aucun avis ») : affiche « réessayer » et n'écrit rien en cache
local _reviews_fetch_id = 0  -- même logique que _fetch_id, pour annuler un fetch d'avis obsolète
-- Tri de l'onglet Avis : "newest" (Nouveau) | "oldest" (Ancien) | "mostliked"
-- (Plus aimé). Même vocabulaire que celui passé aux extensions
-- (ext.parseReviews(path, page, sort)), donc plus de traduction à faire.
local _reviews_sort      = "newest"
local _reviews_view_page = 1  -- page actuellement affichée dans l'onglet Avis (tourne-page comme
                               -- Chapitres ; chaque avis a une hauteur fixe — voir
                               -- REVIEW_TEXT_MAX_CHARS — donc la pagination est un simple découpage
                               -- séquentiel par budget de hauteur)

-- Nombre de pages-liseuse (tourne-page de l'onglet Avis, PAS des pages d'API
-- réseau — chaque avis a une hauteur fixe, donc plusieurs avis tiennent sur
-- une page-liseuse) qu'on garde d'avance chargées devant la page affichée.
-- Tant que ce tampon n'est pas plein et qu'il reste des avis côté site, une
-- page réseau supplémentaire est demandée EN ARRIÈRE-PLAN pendant que
-- l'utilisateur lit/tourne les pages — jamais en bloquant le tourne-page
-- lui-même (même principe que prefetch_next() pour les chapitres, en
-- ui/readerview.lua).
local MAX_REVIEW_LOOKAHEAD_PAGES = 5

-- Limite dure (haute, garde-fou uniquement) du nombre de pages d'avis réseau
-- récupérées par roman. Certaines sources (ex. NovelFire) ne renvoient jamais
-- de page vide tant que d'autres avis existent : sans cette limite, le
-- préchargement en arrière-plan pourrait enchaîner les requêtes à l'infini
-- sur un roman à des milliers d'avis. Au-delà, on arrête d'appeler le réseau
-- et on traite la liste comme définitive (has_more = false) — en pratique le
-- tampon de MAX_REVIEW_LOOKAHEAD_PAGES pages-liseuse arrête déjà le
-- préchargement bien avant d'atteindre cette limite pour la quasi-totalité
-- des romans.
local MAX_REVIEW_PAGES = 40

-- Limite d'avis gardés par roman, COMMUNE à toutes les extensions (une
-- extension peut la changer avec `maxReviews` dans sa table `ext`). Une fois
-- atteinte, la liste est définitive : plus aucune requête réseau et plus de
-- page vers la droite — on ne peut pas dépasser la limite, même en continuant
-- à tourner les pages.
local MAX_REVIEWS = 150

-- Nombre d'avis maximum pour cette extension.
local function review_limit(ext)
    return tonumber(ext and ext.maxReviews) or MAX_REVIEWS
end

-- Nombre maximum de pages RÉSEAU pour cette extension (garde-fou en plus de
-- la limite en nombre d'avis ci-dessus).
local function review_page_limit(ext)
    return tonumber(ext and ext.maxReviewPages) or MAX_REVIEW_PAGES
end

-- Coupe la liste à la limite et dit si elle est atteinte (auquel cas il n'y
-- a plus de "suite" à charger). Modifie `list` en place.
local function clamp_reviews(list, ext)
    local cap = review_limit(ext)
    while #list > cap do table.remove(list) end
    return #list >= cap
end

-- Cache de rendu des avis : évite de refaire le tri et le calcul de toutes les
-- pages à chaque tourne-page. La liste normalisée reste la source de vérité ;
-- ce cache ne contient que les résultats de présentation.
local _reviews_sorted_cache = nil
local _reviews_pages_cache  = nil
local _reviews_cache_key    = nil

-- Empêche de programmer plusieurs préchargements en double pour la même
-- page réseau : build_reviews_rows_impl tourne à chaque rebuild (bien plus
-- souvent qu'un tourne-page), scheduleIn seul ne suffirait pas à éviter les
-- doublons pendant les ~0.3s d'attente.
local _reviews_prefetch_scheduled_for = nil -- numéro de la page réseau déjà programmée

local function invalidate_reviews_render_cache()
    _reviews_sorted_cache = nil
    _reviews_pages_cache  = nil
    _reviews_cache_key    = nil
end

local DETAIL_TABS = {
    { id = "details",  label = T("Détails")  },
    { id = "chapters", label = T("Chapitres") },
    { id = "reviews",  label = T("Avis")     },
}

-- ── Masquage global des commentaires ────────────────────────────────────────
-- Bascule par appui long sur l'icône commentaire de la barre d'actions de
-- l'onglet Chapitres (cf. chapter_actions_bar plus bas). Quand c'est actif :
--   • l'onglet « Avis » disparaît de la barre d'onglets ;
--   • les avis déjà chargés en mémoire sont oubliés ;
--   • le lecteur n'affiche plus les bulles de commentaires par paragraphe, ni
--     l'accès au panneau de commentaires de chapitre, ni la section
--     « Commentaires » de fin de chapitre (cf. ui/readerview.lua).
-- L'état est persisté (sefirah_settings.lua : comments_hidden) et la bascule est
-- purement locale : aucun appel réseau, l'écran est reconstruit immédiatement.
local function comments_hidden()
    return Settings:get("comments_hidden") and true or false
end

-- Onglets réellement affichés : « Avis » est retiré quand les commentaires
-- sont masqués (la table DETAIL_TABS reste la référence complète).
-- Une source peut déclarer `hasReviews = false` dans sa table d'extension (ex.
-- 69shu : le site n'a aucune section d'avis) : l'onglet « Avis » disparaît alors
-- POUR CETTE SOURCE UNIQUEMENT, indépendamment du réglage global ci-dessus.
local function source_has_no_reviews()
    local ext = _source_id and ExtMgr.get(_source_id)
    return ext ~= nil and ext.hasReviews == false
end

local function visible_tabs()
    if not comments_hidden() and not source_has_no_reviews() then return DETAIL_TABS end
    local tabs = {}
    for _, t in ipairs(DETAIL_TABS) do
        if t.id ~= "reviews" then table.insert(tabs, t) end
    end
    return tabs
end

local function tab_is_visible(id)
    for _, t in ipairs(visible_tabs()) do
        if t.id == id then return true end
    end
    return false
end

local function close_all()
    if _G.sefirah_close_all then _G.sefirah_close_all() end
end

-- Délègue à Cache.chapterKey : c'est désormais la SEULE source de vérité pour
-- l'identité d'un chapitre. Avant ce correctif, detail.lua calculait sa propre
-- clé avec un repli différent (tostring(idx) au lieu de "") de celui utilisé
-- par core/cache.lua et ui/readerview.lua pour stocker/lire le contenu en
-- cache. Résultat : pour un chapitre sans `path`/`sourceUrl`, la coche
-- "téléchargé" et la progression affichées ici pouvaient ne jamais
-- correspondre au fichier réellement présent sur le disque.
local function ch_path(ch, idx)
    return Cache.chapterKey(ch)
end

local function is_valid_utf8(s)
    if not s or s == "" then return true end
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        if c < 0x80 then
            i = i + 1
        elseif c >= 0xC2 and c <= 0xDF then
            local c2 = s:byte(i + 1)
            if not c2 or c2 < 0x80 or c2 > 0xBF then return false end
            i = i + 2
        elseif c >= 0xE0 and c <= 0xEF then
            local c2, c3 = s:byte(i + 1), s:byte(i + 2)
            if not c2 or not c3 or c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF then return false end
            if c == 0xE0 and c2 < 0xA0 then return false end
            if c == 0xED and c2 >= 0xA0 then return false end
            i = i + 3
        elseif c >= 0xF0 and c <= 0xF4 then
            local c2, c3, c4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
            if not c2 or not c3 or not c4 or c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF or c4 < 0x80 or c4 > 0xBF then return false end
            if c == 0xF0 and c2 < 0x90 then return false end
            if c == 0xF4 and c2 > 0x8F then return false end
            i = i + 4
        else
            return false
        end
    end
    return true
end

local function latin1_to_utf8(s)
    if not s or s == "" or is_valid_utf8(s) then return s end
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 then
            out[#out + 1] = string.char(b)
        else
            out[#out + 1] = string.char(0xC0 + math.floor(b / 64), 0x80 + (b % 64))
        end
    end
    return table.concat(out)
end

-- Certains serveurs renvoient les titres en ISO-8859-1, d'autres en UTF-8.
-- On normalise ici avant TextWidget pour éviter les "�" sur les accents.
local function clean_chapter_title(s)
    s = latin1_to_utf8(tostring(s or ""))
    s = s:gsub("&eacute;", "é"):gsub("&Eacute;", "É")
        :gsub("&#233;", "é"):gsub("&#201;", "É")
        :gsub("&#xE9;", "é"):gsub("&#xe9;", "é")
        :gsub("&#xC9;", "É"):gsub("&#xc9;", "É")
    -- Les titres actuellement fournis par NovelFrance peuvent contenir le
    -- caractère de remplacement à la place de "é". Dans un titre français,
    -- ce cas correspond aux intitulés visibles sur la Kobo (Première, Présents...).
    s = s:gsub("�", "é")
    -- NovelFire (et anciens caches) : "3209: Chapter 3209 Merry Men" -> le
    -- numéro de position est déjà dans le titre, on ne l'affiche qu'une fois.
    local num, rest = s:match("^%s*(%d+)%s*:%s*(.-)%s*$")
    if num and rest and rest:find(num, 1, true) and rest:match("^%a+%s+%d") then
        s = rest
    end
    return s
end

-- Même repère simple que le lecteur : la progression stockée est un pourcentage.
-- On l'affiche sous forme de pages virtuelles (ex. 2/11). Le nombre est calculé
-- à partir du texte réellement mis en cache, donc il reste cohérent pour chaque chapitre.
local function chapter_progress_label(source_id, novel_path, ch)
    local key = ch_path(ch, 0)
    local progress = Cache.getChapterProgress(source_id, novel_path, key)
    if not progress or progress.chapter_path ~= key then return nil end

    -- La position courante a priorité sur l'ancien état "terminé".
    -- Ainsi, si un chapitre avait ✓ puis qu'on le rouvre et qu'on revient
    -- par exemple à la page 3/19, l'affichage devient immédiatement 3/19.
    local total_pages = tonumber(progress.total_pages)
    local current = tonumber(progress.current_page)
    if not total_pages or total_pages < 1 then
        total_pages = 1
    end
    if not current then
        current = 1
    end
    current = math.max(1, math.min(total_pages, current))

    -- IMPORTANT : la page 1 n'affiche JAMAIS de progression.
    -- Cela doit aussi écraser un ancien état "completed=true" provenant
    -- d'un chapitre qui affichait auparavant ✓.
    if current <= 1 then
        return nil
    end

    -- Dès qu'on a quitté la page 1, la position courante prime sur l'ancien
    -- état "completed". Ainsi un ancien ✓ devient 2/19, 3/19, etc.
    if current < total_pages then
        return string.format("%d/%d", current, total_pages)
    end

    -- ✓ uniquement lorsque la position enregistrée est réellement la dernière page.
    if current >= total_pages then
        return "✓"
    end

    return nil
end

-- ── Lignes de l'onglet Détails ───────────────────────────────────────────────

-- Affiche le résumé complet dans une vraie fenêtre défilable, sans
-- reconstruire l'écran Détails ni ouvrir l'onglet Chapitres.
local function show_full_summary(info)
    local summary = (info and info.summary or ""):match("^%s*(.-)%s*$")
    if summary == "" then
        UIManager:show(InfoMessage:new{ text = T("Aucune description disponible."), timeout = 2 })
        return
    end

    local viewer
    viewer = TextViewer:new{
        title            = info.name or info.title or T("Description"),
        text             = summary,
        width            = math.floor(Screen:getWidth() * 0.94),
        height           = math.floor(Screen:getHeight() * 0.90),
        show_menu        = false,
        add_default_buttons = false,
        buttons_table    = {{
            {
                text = T("Fermer"),
                callback = function() UIManager:close(viewer) end,
            },
        }},
        text_padding     = Screen:scaleBySize(18),
        text_margin      = Screen:scaleBySize(6),
        alignment        = "left",
    }
    UIManager:show(viewer)
end

-- Anime-Sama (centerCover) : couverture agrandie pour occuper tout l'espace libre de
-- l'onglet Détails (plus de vide entre les boutons et la barre du bas). Re-décode les octets
-- bruts de la couverture (déjà sur disque) à la taille voulue, ratio conservé.
local _center_target = nil
local _center_for = nil   -- dernier _cover_bb déjà ajusté (évite de re-décoder à chaque rebuild)

local function render_center_cover(info, box_w, box_h)
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri then return nil end
    local cdata = _cover_data or DB.loadCoverCache(_source_id, info.path or "")
    if not cdata or #cdata < 512 or #cdata > Covers.MAX_COVER_BYTES then return nil end
    local ok_bb, native = pcall(RenderImage.renderImageData, RenderImage, cdata, #cdata, false, box_w, box_h)
    if not ok_bb or not native then return nil end
    local nw, nh = native:getWidth(), native:getHeight()
    if nw <= 0 or nh <= 0 then native:free(); return nil end
    local scale = math.min(box_w / nw, box_h / nh)
    local dw = math.max(1, math.floor(nw * scale))
    local dh = math.max(1, math.floor(nh * scale))
    local ok_sc, out = pcall(native.scale, native, dw, dh)
    native:free()
    if ok_sc and out then return out end
    return nil
end

local function build_details_rows(info)
    local is_tracked = DB.find(_source_id, info.path or "") ~= nil
    local rows = {}

    -- Couverture (gauche) + métadonnées/synopsis (droite), côte à côte, alignés en haut
    -- (déjà mis à l'échelle en respectant le ratio dans l'emplacement P.DETAIL_COVER_W/H lors de la récupération).
    -- Note (★) et rang (#) d'abord si l'extension les fournit (ex. NovelFrance :
    -- novel.rating/novel.allTimeRank, confirmés par capture JSON réelle), puis
    -- auteur/statut/nb de chapitres comme avant. rating est arrondi à 1
    -- décimale ici (la valeur brute de la source est un flottant du type
    -- 4.897959183673469, pas 4.9).
    local badges = {}
    if info.rating then table.insert(badges, "★" .. string.format("%.1f", info.rating)) end
    if info.rank   then table.insert(badges, "#" .. tostring(info.rank)) end
    -- Source sans auteur (info.no_author, ex. MangaPill) : on affiche l'année de parution à la place.
    local who
    if info.no_author then
        who = info.year and tostring(info.year) or nil
    else
        who = info.author or T("Inconnu")
    end
    local meta_str = (#badges > 0 and (table.concat(badges, "  ·  ") .. "  ·  ") or "")
        .. (who and (who .. "  ·  ") or "")
        .. (info.status or "?")
        .. "  ·  " .. #_all_chapters .. " ch"
    local ext_hdr = ExtMgr.get(_source_id)
    local function mk_header()
        return P.makeDetailHeader(
            _cover_bb, meta_str, info.summary,
            500,
            function()
                show_full_summary(info)
            end,
            ext_hdr and ext_hdr.centerCover   -- Anime-Sama : couverture centrée au-dessus du texte
        )
    end
    table.insert(rows, mk_header())

    table.insert(rows, P.hairline())

    -- Reprendre / Commencer la lecture — saute directement dans le lecteur intégré,
    -- en reprenant au dernier chapitre lu (et à la position) quand disponible.
    -- Affiché en premier : c'est l'action la plus utilisée.
    local function insert_resume_button()
        if #_all_chapters == 0 then return end
        local progress   = Cache.getProgress(_source_id, info.path or "")
        local resume_idx = nil
        if progress and progress.chapter_path then
            for i, ch in ipairs(_all_chapters) do
                if (ch.path or ch.sourceUrl or "") == progress.chapter_path then
                    resume_idx = i
                    break
                end
            end
        end

        -- Affiche le vrai numéro/titre du chapitre, pas sa position dans le
        -- tableau — certaines sources renvoient les chapitres du plus récent au plus ancien, donc l'index
        -- du tableau peut être très différent du vrai numéro de chapitre.
        local function chapter_display(ch, fallback_idx)
            if not ch then return tostring(fallback_idx) end
            if ch.chapter_number then return tostring(ch.chapter_number) end
            local name = ch.name or ch.title
            if name then
                return name:match("(%d[%d%.]*)") or name
            end
            return tostring(fallback_idx)
        end

        local label = resume_idx
            and (T("▶  Reprendre — Chap. ") .. chapter_display(_all_chapters[resume_idx], resume_idx))
            or  T("▶  Commencer la lecture")

        table.insert(rows, P.makeBigButton(label, function()
            local ext = ExtMgr.get(_source_id)
            if not ext then
                UIManager:show(InfoMessage:new{
                    text    = T("Extension non chargée : ") .. tostring(_source_id),
                    timeout = 3,
                })
                return
            end
            get_reader_ui().open({
                source_id = _source_id,
                ext       = ext,
                novel     = info,
                chapters  = _all_chapters,
            }, resume_idx or 1)
        end))
    end

    insert_resume_button()

    -- Petit espace entre les 3 boutons d'action — les répartit dans l'espace
    -- libéré par l'en-tête compact couverture+synopsis au lieu de le laisser
    -- comme une seule zone morte en bas, au-dessus des onglets Détails/Chapitres.
    table.insert(rows, P.spacer(Screen:scaleBySize(14)))

    -- Suivre / Ne plus suivre — même taille que les boutons Chap. précédent/suivant
    -- du lecteur (P.makeBigButton est construit à partir de P.BIG_BTN_H).
    table.insert(rows, P.makeBigButton(
        is_tracked and T("♥ Retirer des favoris") or T("♡ Ajouter aux favoris"),
        function()
            if is_tracked then
                DB.untrack(_source_id, info.path or "")
            else
                DB.track({
                    title          = info.name or info.title or T("Roman"),
                    source_id      = _source_id,
                    path           = info.path or "",
                    cover          = info.cover,
                    author         = info.author,
                    status         = info.status,
                    summary        = info.summary,
                    rating         = info.rating,
                    rank           = info.rank,
                    total_chapters = #_all_chapters,
                })
                -- Persiste tout de suite ce qui est déjà en mémoire (liste des
                -- chapitres + couverture décodée) : DB.track vient de créer la
                -- fiche du roman, donc c'est le bon moment pour garantir que le
                -- cache est bien écrit sur le disque, sans attendre un nouveau
                -- chargement réseau. Aucune requête réseau ici, tout est déjà
                -- en mémoire depuis Detail.fetch.
                if #_all_chapters > 0 then
                    DB.saveChapterCache(_source_id, info.path or "", _all_chapters, #_all_chapters)
                end
                if _cover_data then
                    DB.saveCoverCache(_source_id, info.path or "", _cover_data)
                end
                -- Propose les alertes « nouveau chapitre » (popup à 2 cases à cocher).
                pcall(function()
                    require("core.newch").onFavorited({
                        title          = info.name or info.title or T("Roman"),
                        source_id      = _source_id,
                        path           = info.path or "",
                        total_chapters = #_all_chapters,
                    })
                end)
            end
            Detail.rebuild(info, true)
        end
    ))

    table.insert(rows, P.spacer(Screen:scaleBySize(14)))

    -- Même taille que le bouton ci-dessus / que Chap. précédent/suivant.
    table.insert(rows, P.makeBigButton(T("Actualiser la liste des chapitres"), function()
        Detail.fetchForceRefresh(_source_id, info.path or "")
    end))

    -- Anime-Sama : agrandit la couverture pour remplir la hauteur restante (hauteur de
    -- l'écran − autres lignes − en-tête hors couverture), AVEC des limites :
    --  • la place du bouton « Commencer la lecture » est toujours réservée, même si les
    --    chapitres ne sont pas encore chargés (sinon le bouton est caché à l'arrivée) ;
    --  • hauteur plafonnée à une part de l'écran, pour ne jamais cacher de bouton.
    if ext_hdr and ext_hdr.centerCover and _cover_bb then
        pcall(function()
            local used = 0
            for i = 2, #rows do used = used + (rows[i]:getSize().h or 0) end
            if #_all_chapters == 0 then used = used + P.BIG_BTN_H end
            local hdr_h     = rows[1]:getSize().h or 0
            local cover_cur = _cover_bb:getHeight()
            local overhead  = hdr_h - cover_cur
            local target_h  = P.CUSTOM_CONTENT_H - used - overhead - Screen:scaleBySize(24)
            target_h = math.min(target_h, math.floor(P.CUSTOM_CONTENT_H * 0.42))
            local box_w     = P.W - 2 * P.MARGIN
            if target_h > Screen:scaleBySize(100)
               and (_center_for ~= _cover_bb or _center_target ~= target_h)
               and math.abs(target_h - cover_cur) > Screen:scaleBySize(6) then
                local big = render_center_cover(info, box_w, target_h)
                if big then
                    -- L'ancien buffer reste référencé par l'ancien en-tête : on le laisse au
                    -- ramasse-miettes (pas de free explicite).
                    _cover_bb = big
                    rows[1]   = mk_header()
                end
            end
            _center_for    = _cover_bb
            _center_target = target_h
        end)
    end

    return rows
end

-- ── Lignes de l'onglet Chapitres ─────────────────────────────────────────────
-- Renvoie rows, nav où nav est le descripteur de barre de pagination (ou nil).

local function chapter_number_value(ch, fallback)
    if ch and ch.chapter_number ~= nil then
        local n = tonumber(tostring(ch.chapter_number):match("[%d%.]+"))
        if n then return n end
    end
    local name = ch and (ch.name or ch.title) or ""
    local n = tonumber(tostring(name):match("(%d+[%d%.]*)"))
    return n or fallback
end

-- Filet de sécurité générique : garantit que `chapters` est bien trié de
-- façon strictement monotone selon `chapter_number` (utilisé par
-- ui/readerview.lua pour la navigation Précédent/Suivant, qui suppose un
-- ordre global cohérent). Corrige silencieusement toute liste déjà cassée
-- en cache (ex. delta de mise à jour mal fusionné avant ce correctif) en
-- plus d'empêcher toute nouvelle corruption, quelle que soit la source.
-- Le sens (croissant/décroissant) est détecté sur la première paire de
-- numéros distincts rencontrée, comme compute_step() dans readerview.lua,
-- afin que les deux fichiers s'accordent toujours sur le même sens.
local function normalize_chapter_order(chapters)
    if not chapters or #chapters < 2 then return chapters end

    local descending = false
    do
        local prev_num
        for _, ch in ipairs(chapters) do
            local n = chapter_number_value(ch, nil)
            if n then
                if prev_num then
                    if n < prev_num then descending = true end
                    break
                end
                prev_num = n
            end
        end
    end

    -- Déjà cohérent ? On vérifie avant de trier pour ne jamais perturber
    -- l'ordre d'origine des chapitres sans numéro détectable (repli sur
    -- l'ordre d'insertion), et pour rester bon marché dans le cas normal
    -- (pas de mise à jour delta mal fusionnée).
    local ok = true
    local prev_num
    for _, ch in ipairs(chapters) do
        local n = chapter_number_value(ch, nil)
        if n and prev_num then
            if descending and n > prev_num then ok = false; break end
            if not descending and n < prev_num then ok = false; break end
        end
        if n then prev_num = n end
    end
    if ok then return chapters end

    local indexed = {}
    for i, ch in ipairs(chapters) do
        indexed[i] = { ch = ch, i = i, n = chapter_number_value(ch, nil) }
    end
    table.sort(indexed, function(a, b)
        if a.n == nil and b.n == nil then return a.i < b.i end
        if a.n == nil then return false end
        if b.n == nil then return true end
        if a.n == b.n then return a.i < b.i end
        if descending then return a.n > b.n end
        return a.n < b.n
    end)
    local out = {}
    for i, e in ipairs(indexed) do out[i] = e.ch end
    return out
end

local function display_chapter_indices()
    local n = #_all_chapters
    local vf = _vol_filter
    if _idx_cache.list and _idx_cache.chapters == _all_chapters
       and _idx_cache.n == n and _idx_cache.asc == _ascending and _idx_cache.vol == vf then
        return _idx_cache.list, _idx_cache.nums
    end
    local nums, indices = {}, {}
    for i = 1, n do
        nums[i] = chapter_number_value(_all_chapters[i], i)
        if vf == nil or tonumber(_all_chapters[i].volume) == vf then
            indices[#indices + 1] = i
        end
    end
    local asc = _ascending
    table.sort(indices, function(a, b)
        local na, nb = nums[a], nums[b]
        if na == nb then return a < b end
        if asc then return na < nb end
        return na > nb
    end)
    _idx_cache.chapters, _idx_cache.n, _idx_cache.asc, _idx_cache.vol = _all_chapters, n, asc, vf
    _idx_cache.list, _idx_cache.nums = indices, nums
    return indices, nums
end

-- Tomes présents dans la liste (si la source les fournit) : { {num, count}, ... }.
local function chapter_volumes()
    local counts, order = {}, {}
    for _, ch in ipairs(_all_chapters) do
        local v = tonumber(ch.volume)
        if v then
            if not counts[v] then counts[v] = 0; order[#order + 1] = v end
            counts[v] = counts[v] + 1
        end
    end
    table.sort(order)
    local out = {}
    for _, v in ipairs(order) do out[#out + 1] = { v, counts[v] } end
    return out
end

-- Ensemble des chapitres déjà exportés, mis en cache : relu seulement si un
-- export a eu lieu (DB.exportRev) ou si on change d'onglet / de roman.
local function get_exported_set(info)
    local key = tostring(_source_id) .. "|" .. tostring(info.path or "")
    local rev = DB.exportRev or 0
    if _exp_cache.set and _exp_cache.key == key and _exp_cache.rev == rev then
        return _exp_cache.set
    end
    local set = DB.getExportedChapterSet(_source_id, info.path or "")
    _exp_cache.key, _exp_cache.rev, _exp_cache.set = key, rev, set
    return set
end

-- ── Sélection : helpers ───────────────────────────────────────────────────
local function sel_is(ch) return _sel[ch_path(ch, 0)] == true end

local function sel_set(ch, on)
    if ch.locked == true then return end
    local k = ch_path(ch, 0)
    if on and not _sel[k] then _sel[k] = true; _sel_count = _sel_count + 1
    elseif (not on) and _sel[k] then _sel[k] = nil; _sel_count = _sel_count - 1 end
end

-- Reconstruction différée (mode sélection) : même précaution que switch_tab —
-- ne jamais remplacer l'arbre de widgets pendant le traitement du tap, sinon
-- l'écran peut se corrompre/saccader sur Kobo. Plusieurs taps rapprochés ne
-- déclenchent qu'une seule reconstruction (la dernière).
local function rebuild_after_tap(info)
    _switch_generation = _switch_generation + 1
    local generation = _switch_generation
    UIManager:scheduleIn(0, function()
        if generation ~= _switch_generation then return end
        if not _panel or not _novel_info then return end
        Detail.rebuild(info, true)
    end)
end

-- Chapitres sélectionnés, du plus ancien au plus récent.
local function selected_chapters()
    local indices, nums = display_chapter_indices()
    local out = {}
    for _, i in ipairs(indices) do
        if sel_is(_all_chapters[i]) then out[#out + 1] = { ch = _all_chapters[i], n = nums[i], i = i } end
    end
    table.sort(out, function(a, b)
        if a.n ~= b.n then return a.n < b.n end
        return a.i < b.i
    end)
    local chs = {}
    for k, e in ipairs(out) do chs[k] = e.ch end
    return chs
end

local function chapters_in_range(first_num, last_num)
    first_num = tonumber(first_num)
    last_num  = tonumber(last_num)
    if not first_num or not last_num then return {} end
    if first_num > last_num then first_num, last_num = last_num, first_num end

    local out = {}
    for i, ch in ipairs(_all_chapters) do
        local n = chapter_number_value(ch, nil)
        if n and n >= first_num and n <= last_num then
            out[#out + 1] = ch
        end
    end
    table.sort(out, function(a, b)
        local na, nb = chapter_number_value(a, math.huge), chapter_number_value(b, math.huge)
        if na ~= nb then return na < nb end
        -- Même risque qu'en ligne ~1080 (tri des avis) : sans dernier critère,
        -- de nombreux chapitres à égalité (ex. plusieurs sans numéro
        -- détectable, tous à math.huge) peuvent faire planter table.sort
        -- avec "invalid order function for sorting". On force un ordre
        -- total avec le nom en repli.
        return tostring(a.name or a.title or "") < tostring(b.name or b.title or "")
    end)
    return out
end

local function open_export(info, only_chapters)
    if not info or #_all_chapters == 0 then
        UIManager:show(InfoMessage:new{ text = T("Aucun chapitre à exporter."), timeout = 2 })
        return
    end
    local ext = ExtMgr.get(_source_id)
    if not ext then
        UIManager:show(InfoMessage:new{ text = T("Extension non chargée : ") .. tostring(_source_id), timeout = 3 })
        return
    end
    get_export_ui().show({
        chapters       = only_chapters or _all_chapters,
        novel          = info,
        source_id      = _source_id,
        total_chapters = #_all_chapters,
        fetch_fn       = function(path, export_options)
            -- Quand tous les commentaires sont demandés, on force parseChapter
            -- afin de reconstruire le chapitre avec les fils complets des
            -- paragraphes. Sinon on conserve le chemin cache ultra-rapide.
            if export_options and export_options.include_comments then
                local previous = ext._export_all_comments
                ext._export_all_comments = true
                local ok, html = pcall(ext.parseChapter, ext, path)
                ext._export_all_comments = previous
                return ok and html or nil
            end
            -- Exporter depuis le cache est beaucoup plus rapide que de
            -- re-télécharger les chapitres déjà présents hors ligne.
            local cached = Cache.getChapterHtml(_source_id, info.path or "", path)
            if cached and cached ~= "" then return cached end
            local ok, html = pcall(ext.parseChapter, ext, path)
            return ok and html or nil
        end,
        reviews_fn     = function(page)
            if not ext.parseReviews then return { reviews = {}, has_more = false } end
            return ext:parseReviews(info.path, page, current_api_sort())
        end,
    })
end

local function start_download(info, chapters)
    local ext = ExtMgr.get(_source_id)
    if not ext or #chapters == 0 then
        UIManager:show(InfoMessage:new{ text = T("Aucun chapitre à télécharger dans cette plage."), timeout = 2 })
        return
    end
    -- Romans : les chapitres vont dans la file d'attente (core/dlqueue.lua). Elle
    -- travaille en arrière-plan, reprend après une coupure réseau et laisse
    -- l'écran libre. Mangas : on garde l'ancien téléchargement direct.
    if ext.type ~= "manga" then
        local ok_q, Dlq = pcall(require, "core.dlqueue")
        if ok_q then
            local ok_e, err = pcall(Dlq.enqueue, _source_id, info.path or "",
                info.title or info.name, chapters, { kind = "manual" })
            if ok_e then return end
            require("logger").warn("Sefirah/Detail: file de téléchargement indisponible :", tostring(err))
        end
    end
    local progress_msg = InfoMessage:new{ text = T("Téléchargement…") }
    UIManager:show(progress_msg)
    local my_fetch_id = _fetch_id  -- fige l'identité du roman affiché au lancement du téléchargement
    Cache.downloadChapters(ext, _source_id, info.path or "", chapters,
        function(done, total)
            -- Rebuild périodique seulement : reconstruire tout l'écran après
            -- chaque chapitre ralentissait fortement les gros téléchargements.
            if (done % 10 == 0 or done == total) and my_fetch_id == _fetch_id and _panel and _detail_tab == "chapters" then
                Detail.rebuild(info, true)
            end
            if done % 10 == 0 or done == total then
                if progress_msg then UIManager:close(progress_msg) end
                progress_msg = InfoMessage:new{
                    text = string.format(T("Téléchargement %d / %d…"), done, total),
                    timeout = 60,
                }
                UIManager:show(progress_msg)

                -- Rafraîchit les coches "✓" de la liste au fur et à mesure, sans
                -- attendre la fin de tout le lot. Avant ce correctif, seul
                -- `on_complete` (ci-dessous) reconstruisait l'écran, donc les
                -- coches restaient figées jusqu'à la fin d'un téléchargement
                -- pouvant durer plusieurs minutes — l'utilisateur devait changer
                -- de page ou d'onglet pour forcer un rebuild et les voir apparaître.
                -- On ne rafraîchit que si on est toujours sur le même roman/onglet
                -- (l'utilisateur a pu naviguer ailleurs pendant le téléchargement).
            end
        end,
        function()
            if progress_msg then UIManager:close(progress_msg); progress_msg = nil end
            UIManager:show(InfoMessage:new{ text = T("Téléchargement terminé."), timeout = 2 })
            if my_fetch_id == _fetch_id and _panel then
                Detail.rebuild(info, true)
            end
        end)
end

-- Demande « premier / dernier chapitre » puis appelle on_chapters(liste).
-- Partagé par le téléchargement et la traduction.
local function ask_chapter_range(confirm_text, on_chapters)
    local first_dlg
    first_dlg = InputDialog:new{
        title = T("Premier chapitre"),
        input_hint = T("Ex. 1629"),
        input_type = "number",
        buttons = {{
            { text = T("Annuler"), callback = function() UIManager:close(first_dlg) end },
            { text = T("Suivant"), is_enter_default = true, callback = function()
                local first = tonumber(first_dlg:getInputText())
                if not first then
                    UIManager:show(InfoMessage:new{ text = T("Numéro de chapitre invalide."), timeout = 2 })
                    return
                end
                UIManager:close(first_dlg)

                local last_dlg
                last_dlg = InputDialog:new{
                    title = T("Dernier chapitre"),
                    input_hint = T("Ex. 2003"),
                    input_type = "number",
                    buttons = {{
                        { text = T("Annuler"), callback = function() UIManager:close(last_dlg) end },
                        { text = confirm_text, is_enter_default = true, callback = function()
                            local last = tonumber(last_dlg:getInputText())
                            UIManager:close(last_dlg)
                            if not last then
                                UIManager:show(InfoMessage:new{ text = T("Numéro de chapitre invalide."), timeout = 2 })
                                return
                            end
                            local chapters = chapters_in_range(first, last)
                            if #chapters == 0 then
                                UIManager:show(InfoMessage:new{ text = string.format(T("Aucun chapitre trouvé entre %g et %g."), first, last), timeout = 3 })
                                return
                            end
                            on_chapters(chapters)
                        end },
                    }},
                }
                UIManager:show(last_dlg)
            end },
        }},
    }
    UIManager:show(first_dlg)
end

local function ask_download_range(info)
    ask_chapter_range(T("Télécharger"), function(chapters) start_download(info, chapters) end)
end

local function show_download_menu(info)
    local action_y = P.TITLE_H + P.HAIRLINE + Screen:scaleBySize(50)
    P.showDropdown({
        { T("Télécharger tous les chapitres"), function()
            start_download(info, _all_chapters)
        end },
        { T("Télécharger une plage de chapitres"), function()
            ask_download_range(info)
        end },
    }, action_y)
end

-- ── Traduction des chapitres (bouton « Traduire » de la barre d'actions) ──────
-- Utilise core/translate.lua. Chaque chapitre est téléchargé s'il ne
-- l'est pas déjà, puis traduit ; le résultat est mis en cache (une fois par
-- chapitre et par langue) et le lecteur l'affiche ensuite automatiquement.
local function ask_setting_text(title, key, on_saved)
    local input
    input = InputDialog:new{
        title   = title,
        input   = tostring(Settings:get(key) or ""),
        buttons = {{
            { text = T("Annuler"), callback = function() UIManager:close(input) end },
            { text = T("Enregistrer"), is_enter_default = true, callback = function()
                local v = (input:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(input)
                if v == "" then return end
                Settings:set(key, v)
                if on_saved then on_saved() end
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

local function translate_chapters(info, chapters)
    local okT, Translate = pcall(require, "core.translate")
    if not okT then
        UIManager:show(InfoMessage:new{ text = T("Traduction impossible : ") .. tostring(Translate), timeout = 4 })
        return
    end
    local ext = ExtMgr.get(_source_id)
    if not ext or #chapters == 0 then
        UIManager:show(InfoMessage:new{ text = T("Aucun chapitre à traduire dans cette plage."), timeout = 2 })
        return
    end

    Online.run(function()
        local lang       = Translate.lang()
        local novel_path = info.path or ""
        local total      = #chapters
        local my_fetch_id = _fetch_id
        local cancelled, closing = false, false
        local progress_msg
        local n_done, n_skipped, n_failed = 0, 0, 0

        local function close_progress()
            if progress_msg then
                closing = true
                UIManager:close(progress_msg)
                closing = false
                progress_msg = nil
            end
        end

        local function show_progress(i)
            close_progress()
            progress_msg = InfoMessage:new{
                text = string.format(T("Traduction %d / %d…"), i, total),
                timeout = 600,
                dismiss_callback = function()
                    if not closing then cancelled = true end
                end,
            }
            UIManager:show(progress_msg)
        end

        local function finish(err)
            close_progress()
            local msg
            if err then
                msg = T("Traduction interrompue : ") .. tostring(err)
            elseif cancelled then
                msg = T("Traduction arrêtée.")
            else
                msg = T("Traduction terminée.")
            end
            msg = msg .. string.format("  (%d " .. T("traduits") .. ", %d " .. T("déjà faits") .. ", %d " .. T("échecs") .. ")",
                n_done, n_skipped, n_failed)
            UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
            if my_fetch_id == _fetch_id and _panel then Detail.rebuild(info, true) end
        end

        local step
        step = function(i)
            if cancelled then return finish() end
            if i > total then return finish() end
            local ch  = chapters[i]
            local key = Cache.chapterKey(ch)

            if ch.locked == true then
                n_failed = n_failed + 1
                return step(i + 1)
            end
            if Cache.getTranslation(_source_id, novel_path, key, lang) then
                n_skipped = n_skipped + 1
                return step(i + 1)
            end

            show_progress(i)
            UIManager:scheduleIn(0.1, function()
                local function do_translate()
                    local html = Cache.getChapterHtml(_source_id, novel_path, key)
                    if not html or html == "" then
                        n_failed = n_failed + 1
                        return step(i + 1)
                    end
                    local ok, tr, err = pcall(Translate.chapter, html, _source_id, novel_path, key)
                    if ok and tr then
                        n_done = n_done + 1
                        -- Rend la main à l'UI avant le chapitre suivant : un
                        -- appui pendant la traduction est ainsi pris en compte
                        -- (arrêt) au lieu d'être perdu.
                        UIManager:scheduleIn(0.3, function() step(i + 1) end)
                    else
                        -- Clé refusée / quota : inutile d'insister sur les chapitres suivants.
                        finish(ok and err or tr)
                    end
                end

                if Cache.isChapterCached(_source_id, novel_path, key) then
                    do_translate()
                else
                    Cache.downloadChapter(ext, _source_id, novel_path, ch, function(ok)
                        if ok then
                            do_translate()
                        else
                            n_failed = n_failed + 1
                            step(i + 1)
                        end
                    end)
                end
            end)
        end

        step(1)
    end)
end

local function remove_translations(info)
    local ok, res = pcall(Cache.removeNovelTranslations, _source_id, info.path or "")
    local n = ok and tonumber(res) or 0
    UIManager:show(InfoMessage:new{
        text = ok and string.format(T("%d traduction(s) supprimée(s)."), n)
                   or (T("Erreur : ") .. tostring(res)),
        timeout = 2,
    })
    -- Rafraîchit la fiche : sinon les icônes « traduit » restent affichées.
    -- Différé au tick suivant : on ne reconstruit pas le panneau pendant le
    -- traitement du tap (cause de plantage sur Kobo, voir Detail.rebuild).
    UIManager:scheduleIn(0.1, function()
        if _panel and _novel_info then pcall(Detail.rebuild, info, true) end
    end)
end

local function show_translate_menu(info)
    local okT, Translate = pcall(require, "core.translate")
    if not okT then
        UIManager:show(InfoMessage:new{ text = T("Traduction impossible : ") .. tostring(Translate), timeout = 4 })
        return
    end
    local action_y = P.TITLE_H + P.HAIRLINE + Screen:scaleBySize(50)
    P.showDropdown({
        { T("Traduire tous les chapitres"), function()
            translate_chapters(info, _all_chapters)
        end },
        { T("Traduire une plage de chapitres"), function()
            ask_chapter_range(T("Traduire"), function(chapters) translate_chapters(info, chapters) end)
        end },
        { T("Langue cible : ") .. Translate.lang(), function()
            local Lang = require("ui.translate_lang")
            Lang.show(function() show_translate_menu(info) end)
        end },
        { T("Moteur de traduction : ") .. tostring(Settings:get("translate_engine") or "deepl"), function()
            local current = Settings:get("translate_engine") or "deepl"
            P.showDropdown({
                { T("DeepL Free (clé)"), function()
                    Settings:set("translate_engine", "deepl")
                    show_translate_menu(info)
                end },
                { T("Google Traduction (gratuit, sans clé)"), function()
                    Settings:set("translate_engine", "google")
                    show_translate_menu(info)
                end },
                { T("Gemini (clé gratuite)"), function()
                    Settings:set("translate_engine", "gemini")
                    show_translate_menu(info)
                    local k = Settings:get("translate_api_key")
                    if type(k) ~= "string" or k == "" then
                        UIManager:show(InfoMessage:new{
                            text = T("La trad sans clé API prend une éternité."),
                        })
                    end
                end },
            }, action_y)
        end },
        { T("Clé API DeepL Free"), function()
            ask_setting_text(T("Clé API DeepL Free"), "translate_deepl_key")
        end },
        { T("Clé API Gemini"), function()
            ask_setting_text(T("Clé API Gemini"), "translate_api_key")
        end },
        { T("Supprimer les traductions de ce roman"), function()
            remove_translations(info)
        end },
    }, action_y)
end

local function show_volume_menu(info)
    local action_y = P.TITLE_H + P.HAIRLINE + Screen:scaleBySize(50)
    local items = {
        { T("Tous les tomes") .. (_vol_filter == nil and "  ✓" or ""), function()
            _vol_filter = nil; _page = 1; Detail.rebuild(info, true)
        end },
    }
    for _, e in ipairs(chapter_volumes()) do
        local v, c = e[1], e[2]
        items[#items + 1] = { string.format("%s %d  (%d)", T("Tome"), v, c)
            .. (_vol_filter == v and "  ✓" or ""), function()
            _vol_filter = v; _page = 1; Detail.rebuild(info, true)
        end }
    end
    P.showDropdown(items, action_y)
end

-- Choix du groupe de traduction (sources manga qui le proposent : MangaBall). Le choix est gardé
-- par manga et appliqué aux prochains téléchargements ; un chapitre déjà téléchargé reste tel quel.
local function show_group_menu(info)
    local ext = ExtMgr.get(_source_id)
    if not (ext and ext.listGroups) then return end
    local action_y = P.TITLE_H + P.HAIRLINE + Screen:scaleBySize(50)
    local ok_g, groups = pcall(ext.listGroups, ext, _all_chapters)
    groups = ok_g and groups or {}
    local current = ""
    pcall(function() current = ext:getGroup(info.path or "") or "" end)
    local function choose(id, label)
        pcall(ext.setGroup, ext, info.path or "", id)
        UIManager:show(InfoMessage:new{
            text = (id == "") and T("Groupe : automatique.\nLes chapitres déjà téléchargés ne changent pas : « Vider le cache des chapitres » pour les retélécharger.")
                or string.format(T("Groupe : %s.\nLes chapitres déjà téléchargés ne changent pas : « Vider le cache des chapitres » pour les retélécharger."), label),
            timeout = 4,
        })
    end
    local items = {
        { T("Automatique") .. (current == "" and "  ✓" or ""), function() choose("", "") end },
    }
    for _, g in ipairs(groups) do
        local id, label = g.id, g.label
        items[#items + 1] = { string.format("%s  (%d)", label, g.count or 0)
            .. (current == id and "  ✓" or ""), function() choose(id, label) end }
    end
    P.showDropdown(items, action_y)
end

local function show_chapter_actions(info)
    local action_y = P.TITLE_H + P.HAIRLINE + Screen:scaleBySize(50)
    local items = {
        { T("Sélectionner des chapitres"), function()
            _sel_mode = true
            Detail.rebuild(info, true)
        end },
        { T("Télécharger"), function() show_download_menu(info) end },
        { (function()
            local ok_n, n = pcall(function() return require("core.dlqueue").count() end)
            n = (ok_n and tonumber(n)) or 0
            return n > 0 and (T("File d'attente de téléchargement") .. " (" .. n .. ")")
                or T("File d'attente de téléchargement")
        end)(), function() require("ui.downloads").show() end },
        { T("Exporter"), function() open_export(info) end },
        { T("Vider le cache des chapitres"), function()
            Cache.removeNovel(_source_id, info.path or "")
            local ext_m = ExtMgr.get(_source_id)
            if ext_m and ext_m.type == "manga" then
                -- Mangas : les « téléchargements » sont des CBZ sur le disque.
                local ok_mg, Manga = pcall(require, "core.manga")
                if ok_mg then
                    pcall(Manga.removeNovel, info.name or info.title or info.path or "manga")
                end
            end
            UIManager:show(InfoMessage:new{ text = T("Cache des chapitres supprimé."), timeout = 2 })
            Detail.rebuild(info, true)
        end },
    }
    local ext_g = ExtMgr.get(_source_id)
    if ext_g and ext_g.type == "manga" and ext_g.listGroups then
        table.insert(items, 3, { T("Groupe de traduction"), function() show_group_menu(info) end })
    end
    P.showDropdown(items, action_y)
end

-- Menu des actions sur la sélection (bouton « Actions » de la barre).
local function show_selection_menu(info)
    local action_y = P.TITLE_H + P.HAIRLINE + Screen:scaleBySize(50)
    local function need_sel()
        if _sel_count == 0 then
            UIManager:show(InfoMessage:new{ text = T("Aucun chapitre sélectionné."), timeout = 2 })
            return false
        end
        return true
    end
    local items = {
        { string.format(T("Télécharger la sélection (%d)"), _sel_count), function()
            if not need_sel() then return end
            local chs = selected_chapters()
            sel_reset()
            Detail.rebuild(info, true)
            start_download(info, chs)
        end },
        { string.format(T("Exporter la sélection (%d)"), _sel_count), function()
            if not need_sel() then return end
            local chs = selected_chapters()
            sel_reset()
            Detail.rebuild(info, true)
            open_export(info, chs)
        end },
        { string.format(T("Traduire la sélection (%d)"), _sel_count), function()
            if not need_sel() then return end
            local chs = selected_chapters()
            sel_reset()
            Detail.rebuild(info, true)
            translate_chapters(info, chs)
        end },
        { T("Tout sélectionner"), function()
            for _, ch in ipairs(_all_chapters) do sel_set(ch, true) end
            Detail.rebuild(info, true)
        end },
        { T("Tout désélectionner"), function()
            _sel, _sel_count, _sel_anchor = {}, 0, nil
            Detail.rebuild(info, true)
        end },
    }
    -- Pas de « Traduire » pour les sources manga.
    local ext_t = ExtMgr.get(_source_id)
    if ext_t and ext_t.type == "manga" then table.remove(items, 3) end
    P.showDropdown(items, action_y)
end

-- Trouve l'index (dans _all_chapters) du chapitre dont le numéro correspond à
-- target. Cherche d'abord une correspondance exacte (ch.chapter_number, ou à
-- défaut le nombre extrait du nom/titre) ; si aucune correspondance exacte
-- n'existe, ouvre le chapitre numéroté le plus proche plutôt que d'échouer.
local function find_chapter_index_for_number(target)
    if #_all_chapters == 0 then return nil end
    local exact_idx, best_idx, best_diff
    for i, ch in ipairs(_all_chapters) do
        local n = chapter_number_value(ch, nil)
        if n then
            if n == target then
                exact_idx = i
                break
            end
            local diff = math.abs(n - target)
            if not best_diff or diff < best_diff then
                best_diff = diff
                best_idx  = i
            end
        end
    end
    return exact_idx or best_idx
end

-- Dialogue « Aller au chapitre » (icône loupe de la barre d'actions Chapitres) :
-- saisie d'un numéro de chapitre, ouverture directe dans le lecteur, sans avoir
-- à parcourir les pages de la liste pour le retrouver.
local function show_chapter_jump_dialog(info)
    if #_all_chapters == 0 then
        UIManager:show(InfoMessage:new{ text = T("Aucun chapitre disponible."), timeout = 2 })
        return
    end
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title      = T("Aller au chapitre"),
        input_hint = T("Numéro de chapitre"),
        input_type = "number",
        buttons    = {{
            { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
            { text = T("Aller"), is_enter_default = true, callback = function()
                local n = tonumber(dlg:getInputText())
                UIManager:close(dlg)
                if not n then return end

                local idx = find_chapter_index_for_number(n)
                if not idx then
                    UIManager:show(InfoMessage:new{ text = T("Chapitre introuvable."), timeout = 2 })
                    return
                end

                local ext = ExtMgr.get(_source_id)
                if not ext then
                    UIManager:show(InfoMessage:new{
                        text    = T("Extension non chargée : ") .. tostring(_source_id),
                        timeout = 3,
                    })
                    return
                end
                get_reader_ui().open({
                    source_id = _source_id,
                    ext       = ext,
                    novel     = info,
                    chapters  = _all_chapters,
                }, idx)
            end },
        }},
    }
    UIManager:show(dlg)
end

-- Icône de la barre d'actions de l'onglet Avis (actualiser) — juste l'icône,
-- alignée à droite comme la barre de Chapitres (P.makeCustomActionBar pousse
-- les icônes à droite), plus de long libellé "Actualiser (wifi requis)".
-- Relance le chargement des avis depuis la page 1 avec le tri API courant
-- (current_api_sort()). Nécessaire à chaque changement de tri (Nouveau /
-- Ancien / Plus aimé) : les pages déjà en mémoire ont pu être récupérées dans
-- un autre ordre côté API, donc le sous-ensemble en mémoire n'est pas
-- forcément le bon — un vrai appel réseau est nécessaire, un simple tri local
-- ne suffit pas.
-- Définie plus bas (assignée, pas re-déclarée) une fois fetch_reviews_page
-- disponible ; déclarée ici en local d'avance pour que review_actions_bar
-- (juste en dessous) puisse déjà capturer la bonne variable.
local refetch_reviews_for_sort

-- Change le tri des avis. Les trois tris (Nouveau / Ancien / Plus aimé) ont un
-- équivalent côté API sur toutes les sources : les avis déjà en mémoire ont pu
-- être récupérés dans un autre ordre (donc pas forcément le bon sous-ensemble)
-- — un vrai rechargement depuis la page 1 est nécessaire à chaque changement.
local function select_review_sort(info, new_sort)
    if _reviews_sort == new_sort then return end -- déjà actif : rien à refaire
    _reviews_sort      = new_sort
    _reviews_view_page = 1
    invalidate_reviews_render_cache()
    refetch_reviews_for_sort(info)
end

local function review_actions_bar(info)
    if _reviews_loading then
        return {
            -- Plus large que les boutons d'icônes : le texte complet reste
            -- visible même sur les petites largeurs d'écran.
            { label = T("Chargement…"), width = Screen:scaleBySize(132), size = 17, callback = function() end },
        }
    end
    return {
        -- Filtre : Nouveau / Ancien / Plus aimé. (Plus de flèches haut/bas ici :
        -- le sens est déjà contenu dans le choix Nouveau/Ancien.)
        { image = P.ICON_SORT, size = 26, callback = function()
            P.showDropdown({
                { T("Nouveau"),   function() select_review_sort(info, "newest")    end },
                { T("Ancien"),    function() select_review_sort(info, "oldest")    end },
                { T("Plus aimé"), function() select_review_sort(info, "mostliked") end },
            }, Screen:scaleBySize(108))
        end },
        -- Actualiser reste disponible à droite.
        { glyph = "↻", size = 34, callback = function()
            Detail.fetchForceRefreshReviews(_source_id, info.path)
        end },
    }
end

-- Bascule masquer/afficher les commentaires (appui long sur l'icône
-- commentaire, cf. chapter_actions_bar ci-dessous). Les avis gardés en
-- mémoire sont oubliés à la volée pour que plus rien ne subsiste à l'écran ;
-- la reconstruction est repoussée au prochain tick, jamais faite pendant le
-- traitement du geste (même précaution que switch_tab — remplacer l'arbre de
-- widgets sous l'InputContainer qui traite l'événement plante sur Kobo).
local function toggle_comments_hidden(info)
    local now_hidden = not comments_hidden()
    Settings:set("comments_hidden", now_hidden)
    if now_hidden then
        _reviews          = nil
        _reviews_key      = nil
        _reviews_page     = 0
        _reviews_has_more = false
        _reviews_view_page = 1
        invalidate_reviews_render_cache()
        if _detail_tab == "reviews" then _detail_tab = "chapters" end
    end
    _switch_generation = _switch_generation + 1
    local generation = _switch_generation
    UIManager:scheduleIn(0, function()
        if generation ~= _switch_generation then return end
        if not _panel or not _novel_info then return end
        Detail.rebuild(_novel_info, true)
    end)
end

-- Icônes de la barre d'actions de l'onglet Chapitres (loupe / téléchargement / tri).
-- 3e icône : bascule récent ↔ ancien (icône haut/bas, P.ICON_REVIEW_SORT), pour ne
-- pas la confondre visuellement avec l'icône "filtre" (P.ICON_SORT) utilisée pour
-- les menus déroulants. L'onglet Avis n'a plus de flèches haut/bas.
-- Icône commentaire de l'onglet Chapitres : comportement différent pour
-- NovelFrance (seule source dont les commentaires sont injectés en texte
-- dans le chapitre lui-même, donc "rafraîchir" veut dire retélécharger les
-- chapitres en cache — cf. Detail.refreshCachedChaptersComments) que pour
-- les autres sources (panneau de commentaires à part ou simples avis, où
-- retélécharger le chapitre ne rafraîchirait rien) :
--   • NovelFrance : tap = cherche de nouveaux commentaires dans les
--     chapitres déjà en cache disque ; appui long = masque/réaffiche
--     l'onglet Avis (icône remplacée par la variante "off").
--   • Autres sources : un seul tap masque/réaffiche directement l'onglet
--     Avis et remplace l'icône (pas de rafraîchissement de cache dédié).
local function chapter_actions_bar(info)
    if _sel_mode then
        return {
            { image = P.ICON_QUIT, width = 46, size = 26, callback = function()
                sel_reset()
                rebuild_after_tap(info)
            end },
            { image = P.ICON_PAGE, width = 46, size = 26, callback = function()
                -- coche toute la page affichée (voir build_chapters_rows)
                if Detail._sel_page_fn then Detail._sel_page_fn() end
            end },
            { image = P.ICON_MENU, width = 46, size = 26,
              callback = function() show_selection_menu(info) end },
        }
    end
    local hidden = comments_hidden()
    local is_novelfrance = _source_id == "novelfrance"

    -- Icône commentaire retirée pour les sources sans avis/commentaires
    -- (ex. 69shu, hasReviews = false) : elle ne ferait que basculer un
    -- réglage sans aucun effet visible pour ces sources-là.
    local comment_icon
    if not source_has_no_reviews() then
        if is_novelfrance then
            comment_icon = {
                image = P.ICON_COMMENT, image_off = P.ICON_COMMENT_OFF, size = 26, crossed = hidden,
                hold_callback = function() toggle_comments_hidden(info) end,
                callback = function()
                    if comments_hidden() then
                        UIManager:show(InfoMessage:new{
                            text    = T("Commentaires masqués — appui long sur cette icône pour les réafficher."),
                            timeout = 2,
                        })
                        return
                    end
                    Detail.refreshCachedChaptersComments(_source_id, info.path or "")
                end,
            }
        else
            comment_icon = {
                image = P.ICON_COMMENT, image_off = P.ICON_COMMENT_OFF, size = 26, crossed = hidden,
                callback = function() toggle_comments_hidden(info) end,
            }
        end
    end

    -- Nouveau roman : on oublie le tome choisi pour le précédent.
    if _vol_path ~= (info.path or "") then _vol_path = info.path or ""; _vol_filter = nil end
    local bar = {
        { image = P.ICON_CHAPTER_SEARCH, size = 26, callback = function() show_chapter_jump_dialog(info) end },
    }
    if #chapter_volumes() > 1 then
        table.insert(bar, { image = P.ICON_MENU, size = 26, callback = function() show_volume_menu(info) end })
    end
    if comment_icon then table.insert(bar, comment_icon) end
    table.insert(bar, { image = P.ICON_DOWNLOAD, size = 26, callback = function() show_chapter_actions(info) end })
    -- Pas de bouton « Traduire » pour les sources manga (pages = images, rien à traduire en texte).
    local ext_t = ExtMgr.get(_source_id)
    if not (ext_t and ext_t.type == "manga") then
        table.insert(bar, { image = P.ICON_TRANSLATE, size = 36, callback = function() show_translate_menu(info) end })
    end
    table.insert(bar, { image = P.ICON_REVIEW_SORT, size = 26, callback = function()
        _ascending = not _ascending
        Settings:set("chapters_ascending", _ascending)
        _page = 1
        Detail.rebuild(info, true)
    end })
    return bar
end

-- Formate une date (chaîne ISO ou timestamp epoch selon ce que renvoie
-- l'extension) en date FR courte. Reste silencieux (retourne nil) sur tout
-- format inattendu plutôt que d'afficher un texte cassé. Partagée entre les
-- chapitres (ch.date) et les avis (rev.date) — d'où le nom générique.
local function format_review_date(date)
    if not date or date == "" then return nil end
    local y, m, d
    if type(date) == "number" then
        d = os.date("*t", date)
        y, m, d = d.year, d.month, d.day
    else
        y, m, d = tostring(date):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    end
    if not y then return nil end
    return string.format("%s/%s/%s", d, m, y)
end

-- ── Lignes de l'onglet Chapitres ─────────────────────────────────────────────
-- La sélection et les actions sont désormais dans une petite barre d'icônes au-dessus.
local function build_chapters_rows(info)
    local exported_set = get_exported_set(info)
    local rows = {}
    local indices = display_chapter_indices()

    -- Plus de gros bloc d'actions : toute la hauteur libérée est rendue aux chapitres.
    local total_ch = #indices
    local action_h = Screen:scaleBySize(50)
    local fixed_h  = action_h + P.HAIRLINE
    local per_page_full = math.max(1, math.floor((P.CUSTOM_CONTENT_H - fixed_h) / P.ROW_H))
    local per_page_nav  = math.max(1, math.floor((P.CUSTOM_CONTENT_H_NAV - fixed_h) / P.ROW_H))
    local use_nav = math.ceil(total_ch / per_page_full) > 1
    -- AO3 : pas de barre ‹ N/M › en bas, pagination par balayage uniquement.
    local hide_nav = (_source_id == "ao3")
    local per_page = (use_nav and not hide_nav) and per_page_nav or per_page_full
    local max_pages = math.max(1, math.ceil(total_ch / per_page))
    if _page > max_pages then _page = max_pages end

    if total_ch == 0 then
        table.insert(rows, P.makeRow(T("Aucun chapitre trouvé"), { dim = true, callback = function() end }))
        -- Source qui sait expliquer pourquoi (ex. MangaDex : chapitres chez l'éditeur officiel).
        local ext_n = ExtMgr.get(_source_id)
        if ext_n and type(ext_n.chaptersNote) == "function" then
            local ok_n, lines = pcall(ext_n.chaptersNote, ext_n, info.path or "")
            if ok_n and type(lines) == "table" then
                for _, line in ipairs(lines) do
                    table.insert(rows, P.makeRow(line, { dim = true, callback = function() end }))
                end
            end
        end
    else
        local ch_start = (_page - 1) * per_page + 1
        local ch_end   = math.min(ch_start + per_page - 1, total_ch)
        local tr_lang  = Settings:get("translate_lang")
        if type(tr_lang) ~= "string" or tr_lang == "" then tr_lang = "français" end
        for pos = ch_start, ch_end do
            local i         = indices[pos]
            local ch        = _all_chapters[i]
            local p         = ch_path(ch, i)
            local label     = clean_chapter_title(ch.name or ch.title or (T("Chapitre ") .. i))
            local inf       = info
            local idx       = i
            local is_exp    = exported_set[p] and true or false
            local is_locked = ch.locked == true
            local progress  = chapter_progress_label(_source_id, info.path or "", ch)
            -- La progression de lecture est le marqueur principal :
            --   ✓    = chapitre réellement terminé
            --   2/22 = chapitre commencé mais pas terminé
            -- Le cache/téléchargement seul ne déclenche donc plus de ✓.
            local prefix    = (is_exp and "⇩ " or "")
            local is_selected = _sel_mode and (not is_locked) and sel_is(ch) or false
            -- Date du chapitre (ch.date, rempli par l'extension depuis
            -- publishedAt/createdAt/date/updatedAt selon la source) — combinée
            -- avec le numéro de chapitre dans le même champ "mandatory" plutôt
            -- que d'ajouter un nouveau slot, pour ne pas alourdir la ligne.
            local date_str  = format_review_date(ch.date)
            local meta_bits = {}
            if date_str   then table.insert(meta_bits, date_str) end
            local mandatory = #meta_bits > 0 and table.concat(meta_bits, "  ·  ") or nil
            local display   = is_locked
                and (prefix .. T("(verrouillé) ") .. label)
                or  (prefix .. label)
            local function open_chapter(translated)
                local ext = ExtMgr.get(_source_id)
                if not ext then return end
                get_reader_ui().open({
                    source_id  = _source_id,
                    ext        = ext,
                    novel      = inf,
                    chapters   = _all_chapters,
                    translated = translated and true or false,
                }, idx)
            end
            -- Chapitre déjà traduit : icône « Traduire » à côté du titre.
            -- Toucher le chapitre = version normale ; toucher l'icône = version traduite.
            local has_tr = (not is_locked)
                and Cache.hasTranslation(_source_id, info.path or "", Cache.chapterKey(ch), tr_lang)
            local pos_in_list = pos
            local row_ref = {}
            local function toggle_this()
                local on = not sel_is(ch)
                sel_set(ch, on)
                _sel_anchor = pos_in_list
                -- Mise à jour sur place : on ne change que la couleur de fond
                -- de cette ligne et on ne rafraîchit que sa zone (pas de
                -- reconstruction de toute la liste -> bien plus fluide).
                local fr = row_ref.frame
                if fr and fr.dimen and _panel then
                    fr.background = on and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
                    UIManager:setDirty(_panel, "ui", fr.dimen)
                else
                    rebuild_after_tap(info)
                end
            end
            -- Appui long : entre en mode sélection (et coche ce chapitre) ;
            -- en mode sélection, coche tout depuis le dernier chapitre touché
            -- jusqu'à celui-ci (sélection d'une plage sans tout toucher).
            local function hold_this()
                if is_locked then return end
                if not _sel_mode then
                    _sel_mode = true
                    sel_set(ch, true)
                    _sel_anchor = pos_in_list
                elseif _sel_anchor then
                    local a, b = _sel_anchor, pos_in_list
                    if a > b then a, b = b, a end
                    for q = a, b do sel_set(_all_chapters[indices[q]], true) end
                    _sel_anchor = pos_in_list
                else
                    sel_set(ch, true)
                    _sel_anchor = pos_in_list
                end
                rebuild_after_tap(info)
            end
            table.insert(rows, P.makeRow(display, {
                mandatory = mandatory,
                trailing  = progress,
                dim       = is_locked,
                selected  = is_selected,
                row_ref   = row_ref,
                callback  = is_locked and function() end
                            or (_sel_mode and toggle_this or function() open_chapter(false) end),
                hold_callback = hold_this,
                icon          = (has_tr and not _sel_mode) and P.ICON_TRANSLATE or nil,
                icon_callback = (has_tr and not _sel_mode) and function() open_chapter(true) end or nil,
            }))
        end
    end

    -- Icône « Page » : coche tous les chapitres de la page ; si ils le sont
    -- DÉJÀ tous (chapitres verrouillés ignorés), la page est désélectionnée.
    Detail._sel_page_fn = function()
        local from, to = (_page - 1) * per_page + 1, math.min(_page * per_page, total_ch)
        local selectable, all_selected = 0, true
        for q = from, to do
            local c = _all_chapters[indices[q]]
            if c and c.locked ~= true then
                selectable = selectable + 1
                if not sel_is(c) then all_selected = false end
            end
        end
        if selectable == 0 then return end
        local want = not all_selected
        for q = from, to do
            sel_set(_all_chapters[indices[q]], want)
        end
        rebuild_after_tap(info)
    end

    local nav = use_nav and {
        page      = _page,
        max_pages = max_pages,
        row_h     = P.CUSTOM_NAV_ROW_H,
        hide_visual = hide_nav,
        on_prev  = _page > 1 and function() _page = _page - 1; Detail.rebuild(info, true) end or nil,
        on_next  = _page < max_pages and function() _page = _page + 1; Detail.rebuild(info, true) end or nil,
        on_first = _page > 1 and function() _page = 1; Detail.rebuild(info, true) end or nil,
        on_last  = _page < max_pages and function() _page = max_pages; Detail.rebuild(info, true) end or nil,
        on_jump  = function(n)
            _page = math.max(1, math.min(max_pages, math.floor(n)))
            Detail.rebuild(info, true)
        end,
    } or nil

    return rows, nav
end

-- ── Onglet Avis ───────────────────────────────────────────────────────────
-- ext.parseReviews(path, page) est optionnel : une source qui ne l'implémente
-- pas (pas encore, ou site sans avis) fait simplement afficher un message,
-- sans planter. Contrat normalisé attendu en retour (les extensions font le
-- travail de mapper le format spécifique au site vers cette forme, pour que
-- cet onglet reste le même pour toutes les sources) :
--   { reviews = { { author = "pseudo", rating = 5, content = "texte",
--                   likes = 3, dislikes = 1 }, ... },
--     has_more = true/false }
-- Pas de cache disque ici — juste _reviews en mémoire pour la session,
-- invalidé dès que _reviews_key ne correspond plus au roman affiché.

local function reviews_key(source_id, path)
    return tostring(source_id) .. "|" .. tostring(path)
end

-- Tri passé aux extensions (ext.parseReviews(path, page, sort), 3e argument
-- optionnel) — vocabulaire GÉNÉRIQUE : "newest" | "oldest" | "mostliked".
-- Chaque extension le traduit vers son propre paramètre d'API ; c'est déjà
-- exactement la valeur de _reviews_sort.
local function current_api_sort()
    return _reviews_sort
end

-- Récupère une page d'avis et fusionne le résultat dans _reviews. Rappelée à
-- la fois pour le premier chargement (page 1) et pour "Charger plus d'avis".
local function fetch_reviews_page(ext, source_id, path, page, replace_first_page)
    -- Limite atteinte (nombre d'avis OU nombre de pages réseau) : on ne tape
    -- plus le réseau. La page 1 passe toujours (chargement initial / tri /
    -- actualisation : la liste en mémoire y est remplacée, pas prolongée).
    if page > 1 and (page > review_page_limit(ext)
                     or (_reviews and #_reviews >= review_limit(ext))) then
        -- On fige la liste telle quelle (has_more = false) pour que l'UI
        -- arrête de proposer/déclencher un chargement supplémentaire.
        _reviews_has_more = false
        invalidate_reviews_render_cache()
        if _reviews then
            DB.saveReviewCache(source_id, path, _reviews, _reviews_page, _reviews_has_more, ext and ext.review_cache_rev)
        end
        if _panel and _detail_tab == "reviews" and _novel_info then
            Detail.rebuild(_novel_info, false)
        end
        return
    end

    _reviews_loading  = true
    _reviews_fetch_id = _reviews_fetch_id + 1
    local my_fetch_id = _reviews_fetch_id

    Online.run(function()
        UIManager:scheduleIn(0, function()
            -- annulé si le roman/onglet a changé pendant le fetch
            if my_fetch_id ~= _reviews_fetch_id then return end
            local ok, data = pcall(ext.parseReviews, ext, path, page, current_api_sort())
            if my_fetch_id ~= _reviews_fetch_id then return end

            _reviews_loading = false
            if ok and data and data.reviews then
                local ok_apply, err_apply = pcall(function()
                    if replace_first_page and page == 1 then
                        _reviews = {}
                    else
                        _reviews = _reviews or {}
                    end
                    for _, rev in ipairs(data.reviews) do
                        table.insert(_reviews, rev)
                    end
                    _reviews_key       = reviews_key(source_id, path)
                    _reviews_page      = page
                    _reviews_has_more  = data.has_more or false
                    -- Limite atteinte : liste coupée pile à la limite et
                    -- définitive, même si le site dit qu'il reste des avis.
                    if clamp_reviews(_reviews, ext) or page >= review_page_limit(ext) then
                        _reviews_has_more = false
                    end
                    _reviews_error     = (page == 1 and data.error and #_reviews == 0) and data.error or false
                    invalidate_reviews_render_cache()
                    -- Une liste vide (échec ou roman sans avis) n'est JAMAIS écrite en
                    -- cache : sinon elle était relue telle quelle à chaque ouverture, sans
                    -- aucun appel réseau, et l'onglet restait vide même après correction.
                    if #_reviews > 0 then
                        DB.saveReviewCache(source_id, path, _reviews, _reviews_page, _reviews_has_more, ext and ext.review_cache_rev)
                    else
                        DB.clearReviewCache(source_id, path)
                    end

                    local avatar_urls = {}
                    for _, rev in ipairs(data.reviews) do
                        if rev.avatar and rev.avatar ~= "" then
                            table.insert(avatar_urls, rev.avatar)
                        end
                    end
                    if #avatar_urls > 0 then
                        Avatars.prefetch(avatar_urls)
                    end
                end)
                if not ok_apply then
                    -- Le cache disque, le fusionnage ou les pdp ont échoué : on
                    -- log l'erreur mais on affiche quand même les avis reçus
                    -- plutôt que de rester bloqué sur "Chargement…" pour toujours.
                    logger.err("sefirah: post-fetch reviews processing failed:", tostring(err_apply))
                    _reviews          = _reviews or data.reviews
                    _reviews_key      = reviews_key(source_id, path)
                    _reviews_page     = page
                    _reviews_has_more = data.has_more or false
                    if clamp_reviews(_reviews, ext) or page >= review_page_limit(ext) then
                        _reviews_has_more = false
                    end
                end
            elseif _reviews == nil then
                -- échec du tout premier chargement : affiche une liste vide
                -- plutôt que de rester bloqué sur "Chargement…"
                _reviews       = {}
                _reviews_key   = reviews_key(source_id, path)
                _reviews_error = true
            end

            if _panel and _detail_tab == "reviews" and _novel_info then
                Detail.rebuild(_novel_info, false)
            end
        end)
    end)
end

refetch_reviews_for_sort = function(info)
    local ext = ExtMgr.get(_source_id)
    if not ext or type(ext.parseReviews) ~= "function" then return end

    -- Ne vide pas l'écran pendant le rechargement : les avis déjà en mémoire
    -- (dans le mauvais tri) restent visibles pendant que le réseau travaille,
    -- même schéma que Detail.fetchForceRefreshReviews.
    _reviews_loading   = true
    _reviews_fetch_id  = _reviews_fetch_id + 1
    invalidate_reviews_render_cache()

    fetch_reviews_page(ext, _source_id, info.path, 1, true)

    if _panel and _detail_tab == "reviews" and _novel_info then
        UIManager:scheduleIn(0, function()
            if _panel and _detail_tab == "reviews" and _novel_info then
                Detail.rebuild(_novel_info, true)
            end
        end)
    end
end

-- Lignes d'un seul avis (ligne auteur + note, puis le texte), sans séparateur :
-- le séparateur dépend de la position dans la PAGE affichée, pas de la position
-- dans la liste complète, donc build_reviews_rows l'ajoute lui-même.
-- Plus de 👍/👎 : ces emojis ne s'affichent pas sur l'écran e-ink du Kobo (ils
-- sortent en "?"), donc on ne garde que la note/étoile. (format_review_date
-- est maintenant définie plus haut, avant build_chapters_rows, pour être
-- réutilisable pour les dates de chapitre.)

-- Tous les avis sont tronqués à la même longueur (REVIEW_TEXT_MAX_CHARS) —
-- ça borne la hauteur maximale d'un avis sans forcer les avis plus courts à
-- occuper le même espace (un avis d'une ligne ne laisse plus un grand vide
-- blanc en dessous avant le suivant). Un avis tronqué reste tapotable pour
-- tout afficher (show_full_review), au lieu d'être coupé en morceaux
-- "(suite)".
local REVIEW_TEXT_MAX_CHARS = 260

-- Affiche l'avis en entier dans une fenêtre défilable (le bloc de la liste,
-- lui, est tronqué à taille fixe) — appelé au tap sur un avis tronqué.
local function show_full_review(rev)
    local content = Emoji.sanitize((rev.content or ""):match("^%s*(.-)%s*$"))
    if content == "" then return end

    local title = rev.author or T("Anonyme")
    if rev.rating then
        title = title .. " — " .. tostring(rev.rating) .. "★"
    end

    local viewer
    viewer = TextViewer:new{
        title                = title,
        text                 = content,
        width                = math.floor(Screen:getWidth() * 0.94),
        height               = math.floor(Screen:getHeight() * 0.90),
        show_menu            = false,
        add_default_buttons  = false,
        buttons_table        = {{
            {
                text     = T("Fermer"),
                callback = function() UIManager:close(viewer) end,
            },
        }},
        text_padding         = Screen:scaleBySize(18),
        text_margin          = Screen:scaleBySize(6),
        alignment            = "left",
    }
    UIManager:show(viewer)
end

local function build_review_item_rows(rev)
    local rows = {}
    local avatar_bb = Avatars.getCached(rev.avatar, P.SOURCE_ICON)
    local date_str  = format_review_date(rev.date)

    table.insert(rows, P.makeSourceRow(rev.author or T("Anonyme"), date_str, {
        icon_bb   = avatar_bb,
        mandatory = rev.rating and (tostring(rev.rating) .. "★") or nil,
    }))

    local content = Emoji.sanitize((rev.content or ""):match("^%s*(.-)%s*$"))
    if content ~= "" then
        local truncated = #content > REVIEW_TEXT_MAX_CHARS
        table.insert(rows, P.makeTextBlock(content, REVIEW_TEXT_MAX_CHARS, {
            callback = truncated and function() show_full_review(rev) end or nil,
        }))
    end
    return rows
end

local function rows_height(rows)
    local h = 0
    for _, r in ipairs(rows) do h = h + (r:getSize().h or 0) end
    return h
end

local function review_separator_h()
    return Screen:scaleBySize(4) + P.HAIRLINE
end

local function review_date_value(date)
    if type(date) == "number" then return date end
    if not date or date == "" then return 0 end
    local y, m, d, hh, mm, ss = tostring(date):match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ]?(%d?%d?):?(%d?%d?):?(%d?%d?)")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y or not m or not d then return 0 end
    hh, mm, ss = tonumber(hh) or 0, tonumber(mm) or 0, tonumber(ss) or 0
    return os.time({ year = y, month = m, day = d, hour = hh, min = mm, sec = ss }) or 0
end

local function sorted_reviews(reviews)
    local list = {}
    for i, rev in ipairs(reviews or {}) do
        list[i] = { rev = rev, idx = i }
    end
    -- table.sort() de Lua peut lever "invalid order function for sorting"
    -- quand beaucoup d'éléments sont à égalité sur toutes les clés de tri
    -- (avis sans note, sans date exploitable, avec le même auteur "Anónimo"
    -- par exemple) : ce n'est pas un bug du comparateur au sens mathématique,
    -- mais l'algorithme de tri de Lua 5.1 suppose peu d'égalités et peut
    -- planter avec beaucoup de doublons. On élimine le risque en ajoutant
    -- l'indice d'origine comme dernier critère : deux éléments distincts ne
    -- sont alors JAMAIS strictement égaux pour le comparateur.
    -- Nouveau / Ancien : par date. Plus aimé : par nombre de likes décroissant
    -- (les sources qui ne fournissent pas `likes` ont déjà reçu les avis triés
    -- « plus aimés » par le site : à égalité, on garde donc l'ordre d'arrivée
    -- de l'API plutôt que de le mélanger avec la note ou l'auteur).
    table.sort(list, function(wa, wb)
        local a, b = wa.rev, wb.rev
        if _reviews_sort == "mostliked" then
            local la, lb = tonumber(a.likes) or 0, tonumber(b.likes) or 0
            if la ~= lb then return la > lb end
        else
            local da, db = review_date_value(a.date), review_date_value(b.date)
            if da ~= db then
                if _reviews_sort == "oldest" then return da < db end
                return da > db
            end
        end
        -- Dernier recours : indice d'origine, toujours distinct entre deux
        -- éléments différents -> plus jamais d'égalité totale possible.
        return wa.idx < wb.idx
    end)
    local out = {}
    for i, w in ipairs(list) do out[i] = w.rev end
    return out
end

-- Range les avis en pages qui tiennent chacune dans budget_h. Comme chaque
-- avis a désormais une hauteur fixe (voir build_review_item_rows), un simple
-- découpage séquentiel suffit — plus besoin du bin-packing glouton d'avant
-- (qui existait pour combler les trous laissés par des avis de hauteurs très
-- variables) : l'ordre d'affichage reste donc strictement chronologique.
local function reviews_pack_pages(reviews, budget_h)
    local n = #reviews
    if n == 0 then return {} end
    local sep_h = review_separator_h()
    local pages, page, used_h = {}, {}, 0

    for i = 1, n do
        local item_h = rows_height(build_review_item_rows(reviews[i]))
        local need   = (#page == 0) and item_h or (item_h + sep_h)
        if used_h + need > budget_h and #page > 0 then
            table.insert(pages, page)
            page, used_h = {}, 0
            need = item_h
        end
        table.insert(page, i)
        used_h = used_h + need
    end
    if #page > 0 then table.insert(pages, page) end
    return pages
end

local function build_reviews_rows_impl(info)
    local rows = {}
    local ext  = ExtMgr.get(_source_id)
    local key  = reviews_key(_source_id, info.path or "")

    if not ext or type(ext.parseReviews) ~= "function" then
        table.insert(rows, P.makeRow(T("Cette source ne propose pas encore les avis"),
            { dim = true, callback = function() end }))
        return rows, nil
    end

    if key ~= _reviews_key then
        -- Nouveau roman (ou premier passage sur cet onglet) : repart de zéro,
        -- mais on regarde d'abord le cache disque avant de retélécharger —
        -- ça permet de consulter les avis déjà vus sans wifi.
        _reviews           = nil
        _reviews_page      = 0
        _reviews_has_more  = false
        _reviews_view_page = 1
        _reviews_sort      = "newest"
        _reviews_error     = false
        invalidate_reviews_render_cache()

        local cached = DB.loadReviewCache(_source_id, info.path or "")
        -- Cache écrit par une ancienne version de l'extension (ex. avant les pdp
        -- AO3) : on l'ignore pour refaire une vraie requête réseau.
        if cached and ext and ext.review_cache_rev and cached.rev ~= ext.review_cache_rev then
            DB.clearReviewCache(_source_id, info.path or "")
            cached = nil
        end
        if cached and type(cached.reviews) == "table" and #cached.reviews > 0 then
            _reviews          = cached.reviews
            _reviews_page     = cached.page or 1
            _reviews_has_more = cached.has_more or false
            _reviews_key      = key
            -- Un ancien cache (enregistré avec une limite plus haute) ne doit
            -- pas non plus dépasser la limite actuelle.
            if clamp_reviews(_reviews, ext) or _reviews_page >= review_page_limit(ext) then
                _reviews_has_more = false
            end
        end
    end

    if _reviews == nil then
        if not _reviews_loading then
            fetch_reviews_page(ext, _source_id, info.path, 1)
        end
        table.insert(rows, P.makeRow(T("Chargement des avis…"),
            { dim = true, callback = function() end }))
        return rows, nil
    end

    if #_reviews == 0 then
        if _reviews_loading then
            table.insert(rows, P.makeRow(T("Chargement des avis…"),
                { dim = true, callback = function() end }))
        elseif _reviews_error then
            local function retry()
                if _reviews_loading then return end
                -- Retour visuel immédiat : sur e-ink, on ne voit pas toujours le
                -- « Chargement… » passer, et une 2e erreur identique ressemblait
                -- à un bouton mort.
                UIManager:show(InfoMessage:new{ text = T("Nouvelle tentative…"), timeout = 1 })
                Detail.fetchForceRefreshReviews(_source_id, info.path or "")
            end
            table.insert(rows, P.makeRow(T("Impossible de charger les avis — touchez pour réessayer"),
                { dim = true, callback = retry }))
            if type(_reviews_error) == "string" then
                table.insert(rows, P.makeRow(T("Cause : ") .. _reviews_error:sub(1, 60),
                    { dim = true, callback = retry }))
            end
        else
            table.insert(rows, P.makeRow(T("Aucun avis pour ce roman"),
                { dim = true, callback = function() end }))
        end
        return rows, nil
    end

    -- La barre d'action reste en haut, mais l'ancienne barre de flèches du bas
    -- est volontairement masquée. Les gestes gauche/droite continuent de
    -- changer de page grâce au nav conservé sur FullScreenPanel. On rend donc
    -- toute la hauteur libérée aux avis.
    local action_h = Screen:scaleBySize(50)
    local budget_h = P.CUSTOM_CONTENT_H - action_h - P.HAIRLINE
    local render_key = tostring(_reviews_key) .. "|" .. tostring(_reviews_sort) .. "|" .. tostring(budget_h) .. "|" .. tostring(#_reviews)
    if _reviews_cache_key ~= render_key then
        _reviews_sorted_cache = sorted_reviews(_reviews)
        _reviews_pages_cache  = reviews_pack_pages(_reviews_sorted_cache, budget_h)
        _reviews_cache_key    = render_key
    end
    local display_reviews = _reviews_sorted_cache
    local pages            = _reviews_pages_cache

    -- S'il reste de la place sur la page actuelle et que le site a encore des
    -- avis, on charge tout de suite (synchrone) la page suivante. Ainsi, un
    -- avis court n'est jamais suivi d'un grand espace vide simplement parce
    -- que la page réseau suivante n'a pas encore été demandée.
    local current_page = pages[_reviews_view_page] or {}
    if _reviews_has_more and not _reviews_loading and #current_page > 0 then
        local used_h = 0
        local sep_h = review_separator_h()
        for pos, idx in ipairs(current_page) do
            local item_h = rows_height(build_review_item_rows(display_reviews[idx]))
            used_h = used_h + item_h + (pos > 1 and sep_h or 0)
        end
        if used_h < budget_h then
            fetch_reviews_page(ext, _source_id, info.path, _reviews_page + 1)
        end
    end

    -- Préchargement en arrière-plan : tant qu'il n'y a pas
    -- MAX_REVIEW_LOOKAHEAD_PAGES pages-liseuse déjà chargées devant la page
    -- affichée et qu'il reste des avis côté site, une page réseau de plus est
    -- demandée SANS bloquer le tourne-page (délai de 0.3s, même principe que
    -- prefetch_next() pour les chapitres en ui/readerview.lua) — l'utilisateur
    -- continue de lire/tourner les pages pendant que ça télécharge derrière.
    if _reviews_has_more and not _reviews_loading
        and (#pages - _reviews_view_page) < MAX_REVIEW_LOOKAHEAD_PAGES
        and _reviews_prefetch_scheduled_for ~= (_reviews_page + 1) then
        local next_page          = _reviews_page + 1
        local schedule_path      = info.path
        _reviews_prefetch_scheduled_for = next_page
        UIManager:scheduleIn(0.3, function()
            if _reviews_prefetch_scheduled_for == next_page then
                _reviews_prefetch_scheduled_for = nil
            end
            -- Le roman/onglet affiché a pu changer entretemps : on évite
            -- d'appeler le réseau pour un chemin qui n'est plus à l'écran
            -- (fetch_reviews_page vérifie déjà _reviews_fetch_id de son côté,
            -- ceci évite en plus le tir réseau lui-même).
            if not _novel_info or _novel_info.path ~= schedule_path then return end
            if _reviews_loading or _reviews_page + 1 ~= next_page then return end
            fetch_reviews_page(ext, _source_id, schedule_path, next_page)
        end)
    end

    if _reviews_view_page > #pages then _reviews_view_page = math.max(1, #pages) end

    local page_indices = pages[_reviews_view_page] or {}
    for pos, idx in ipairs(page_indices) do
        if pos > 1 then
            table.insert(rows, P.spacer(Screen:scaleBySize(4)))
            table.insert(rows, P.hairline())
        end
        for _, r in ipairs(build_review_item_rows(display_reviews[idx])) do
            table.insert(rows, r)
        end
    end

    local max_pages      = #pages
    local is_last_range  = (_reviews_view_page == max_pages)
    local can_go_further = (not is_last_range) or _reviews_has_more

    -- max_pages grandit au fil des chargements et devient définitif une fois
    -- _reviews_has_more = false ; hide_page_label car ce numéro de page dépend
    -- du remplissage (donc peu stable/utile à afficher), seules les flèches
    -- de navigation comptent ici.
    local nav = {
        page            = _reviews_view_page,
        max_pages       = max_pages,
        row_h           = P.CUSTOM_NAV_ROW_H,
        hide_page_label = true,
        hide_visual     = true, -- pagination par swipe uniquement : pas de flèches en bas
        on_prev  = _reviews_view_page > 1 and function()
            _reviews_view_page = _reviews_view_page - 1
            Detail.rebuild(info, true)
        end or nil,
        on_first = _reviews_view_page > 1 and function()
            _reviews_view_page = 1
            Detail.rebuild(info, true)
        end or nil,
        on_last  = _reviews_view_page < max_pages and function()
            _reviews_view_page = max_pages
            Detail.rebuild(info, true)
        end or nil,
        on_next  = can_go_further and function()
            if is_last_range and _reviews_has_more then
                -- La page suivante n'est pas encore chargée : on va la
                -- chercher sur le site (même logique que l'ancien bouton
                -- "Charger plus d'avis"), reconstruction différée d'un tick
                -- pour ne pas remplacer le panneau pendant que le
                -- tap/glissement est encore en cours de traitement.
                if not _reviews_loading then
                    fetch_reviews_page(ext, _source_id, info.path, _reviews_page + 1)
                end
                _reviews_view_page = _reviews_view_page + 1
                UIManager:scheduleIn(0, function()
                    if not _novel_info or not _panel or _detail_tab ~= "reviews" then return end
                    Detail.rebuild(_novel_info, false)
                end)
            else
                _reviews_view_page = _reviews_view_page + 1
                Detail.rebuild(info, true)
            end
        end or nil,
        on_jump  = function(n)
            _reviews_view_page = math.max(1, math.min(max_pages, math.floor(n)))
            Detail.rebuild(info, true)
        end,
    }

    return rows, nav
end

-- Enveloppe l'implémentation ci-dessus dans un pcall : une erreur de rendu
-- (mise en page pdp/date/troncature des avis — le plus susceptible d'avoir
-- un bug non prévu) ne doit jamais laisser l'onglet bloqué sur "Chargement…"
-- ni planter tout le panneau ; elle s'affiche comme un message, avec le
-- détail loggé pour diagnostic.
local function build_reviews_rows(info)
    local ok, rows_or_err, nav = pcall(build_reviews_rows_impl, info)
    if ok then return rows_or_err, nav end
    logger.err("sefirah: build_reviews_rows failed:", tostring(rows_or_err))
    return {
        P.makeRow(T("Erreur d'affichage des avis (voir logs)"),
            { dim = true, callback = function() end }),
    }, nil
end

-- ── Reconstruction ─────────────────────────────────────────────────────────
-- partial = true utilise un rafraîchissement e-ink partiel (coches de chapitre, changements de pagination).

function Detail.rebuild(info, partial)
    local SefirahUI = require("ui.main_widget")
    local title    = info.name or info.title or T("Roman")

    -- Les commentaires peuvent avoir été masqués (appui long sur l'icône
    -- commentaire) alors que l'onglet Avis était actif : on retombe sur
    -- Chapitres avant de construire quoi que ce soit.
    local tabs = visible_tabs()
    if not tab_is_visible(_detail_tab) then
        _detail_tab = "chapters"
        _page = 1
    end

    local rows, nav
    if _detail_tab == "chapters" then
        rows, nav = build_chapters_rows(info)
    elseif _detail_tab == "reviews" then
        rows, nav = build_reviews_rows(info)
    else
        rows = build_details_rows(info)
    end

    local actions = (_detail_tab == "chapters" and chapter_actions_bar(info))
        or (_detail_tab == "reviews" and review_actions_bar(info))
        or nil

    -- IMPORTANT : le callback des onglets est appelé pendant le traitement du tap.
    -- Il ne faut PAS reconstruire/remplacer le panneau à cet instant : sur Kobo,
    -- le widget qui traite le tap est encore dans la chaîne InputContainer et le
    -- remplacement immédiat de _panel peut laisser l'ancien arbre de widgets dans
    -- l'événement en cours. C'est la cause du crash observé lors de
    -- "Chapitres" -> "Détails" (callback -> Detail.rebuild -> nouveau panneau).
    --
    -- On mémorise simplement l'onglet demandé et on laisse l'événement se terminer.
    -- La reconstruction est ensuite exécutée au prochain tick de l'UI.
    local function switch_tab(id)
        if id ~= "details" and id ~= "chapters" and id ~= "reviews" then return end
        if not tab_is_visible(id) then return end
        if id == _detail_tab then return end

        _switch_generation = _switch_generation + 1
        local generation = _switch_generation
        sel_reset()
        _exp_cache.set = nil   -- les fichiers EPUB ont pu être supprimés entre-temps
        _detail_tab = id
        _page = 1
        _reviews_view_page = 1

        -- Ne remplace jamais l'arbre de widgets pendant le traitement du tap.
        -- Le prochain tick reconstruit le contenu dans le MEME FullScreenPanel via
        -- swapBody(). Cela évite de fermer/détruire l'ancien InputContainer alors
        -- que KOReader est encore en train de traiter son événement tactile.
        UIManager:scheduleIn(0, function()
            if generation ~= _switch_generation then return end
            if not _novel_info or not _panel then return end
            Detail.rebuild(_novel_info, false)
        end)
    end

    local function on_back()
        -- En mode sélection, « retour » quitte d'abord la sélection.
        if _sel_mode and _detail_tab == "chapters" and _panel then
            sel_reset()
            UIManager:scheduleIn(0, function()
                if _novel_info and _panel then Detail.rebuild(_novel_info, true) end
            end)
            return
        end
        Detail.close()
        SefirahUI.clearDetail()
        if Detail.on_back then Detail.on_back() end
    end

    -- Une fois le panneau Détails créé, on le réutilise toujours.
    -- Recréer/fermer un FullScreenPanel à chaque changement d'onglet est dangereux
    -- sur Kobo : le tap est encore propagé dans l'ancien arbre de widgets.
    local body = nil
    if _panel then
        -- showCustomTabPanel construit le même corps que ci-dessous. On passe par
        -- swapBody pour remplacer uniquement le contenu, sans toucher à l'InputContainer.
        body = P.buildCustomTabBody(tabs, _detail_tab, switch_tab, rows, title, on_back, nav, actions)
        _panel:swapBody(body, close_all, partial and true or false, nav)
    else
        _panel = P.showCustomTabPanel(
            tabs, _detail_tab, switch_tab,
            rows, title, on_back, close_all, nav, partial, actions
        )
        SefirahUI.setDetail(_panel)
    end
end

-- ── Public ──────────────────────────────────────────────────────────────────

-- Vide le cache de chapitres puis récupère tout depuis zéro.
-- IMPORTANT (2026-09-12) : ne vide plus le cache disque des chapitres avant
-- de relancer Detail.fetch — un roman à plusieurs milliers de chapitres
-- (Shadow Slave, 3180+) forçait alors un parseNovel complet (~32 requêtes
-- HTTP synchrones d'affilée, aucun rendu UI entre-temps), symptôme observé :
-- l'appli se ferme/redémarre. En gardant le cache, Detail.fetch (chemin
-- réseau ci-dessous, force_refresh=true) peut faire la même comparaison
-- "delta" que le chargement normal : total inchangé -> rien à retélécharger,
-- total en hausse -> uniquement les nouvelles pages via ext:parsePage.
function Detail.fetchForceRefresh(source_id, path)
    Detail.fetch(source_id, path, true)
end

-- Bouton dédié "chercher de nouveaux commentaires" (comment.png, barre
-- d'actions de l'onglet Chapitres) : re-télécharge (force=true) les
-- chapitres DÉJÀ présents dans le cache disque de CE roman (lecture hors
-- ligne / téléchargement groupé), pour découvrir des commentaires ajoutés
-- depuis leur mise en cache — AVIS PAR PARAGRAPHE INCLUS (cf. novelfrance.lua,
-- bloc LNREADER_META). Sans ceci, un chapitre déjà lu/téléchargé continuerait
-- à afficher indéfiniment les mêmes commentaires, même des mois après leur
-- ajout, puisque ui/readerview.lua sert directement Cache.getChapterHtml()
-- depuis le disque sans jamais retourner sur le réseau tant que le chapitre
-- est en cache.
-- CORRIGÉ (2026-09-12) : ceci se déclenchait automatiquement à CHAQUE
-- "Actualiser la liste des chapitres", donc retéléchargeait TOUT le cache du
-- roman (potentiellement des centaines de chapitres) à chaque clic. C'est
-- maintenant une action manuelle séparée (ce bouton), pendant que
-- "Actualiser la liste des chapitres" ne s'occupe plus que des chapitres
-- réellement nouveaux (cf. download_new_chapters_comments ci-dessous).
local function refresh_downloaded_chapters_comments(source_id, novel_path, chapters)
    local ext = ExtMgr.get(source_id)
    if not ext or type(ext.parseChapter) ~= "function" then return end

    local entry = Cache.getNovelEntry(source_id, novel_path)
    if not entry or not entry.chapters then return end

    local to_refresh = {}
    for _, ch in ipairs(chapters) do
        if entry.chapters[Cache.chapterKey(ch)] then
            table.insert(to_refresh, ch)
        end
    end
    if #to_refresh == 0 then
        UIManager:show(InfoMessage:new{
            text    = T("Aucun chapitre en cache pour ce roman."),
            timeout = 3,
        })
        return
    end

    -- Fige l'identité du roman affiché au lancement : si l'utilisateur
    -- quitte ce roman avant la fin, on continue le travail en arrière-plan
    -- (le cache disque profite à tout le monde) mais on n'affiche plus de
    -- messages de progression qui ne le concerneraient plus.
    local my_fetch_id = _fetch_id
    local progress_msg
    Cache.downloadChapters(ext, source_id, novel_path, to_refresh,
        function(done, total)
            if my_fetch_id ~= _fetch_id then return end
            if done == 1 or done % 10 == 0 or done == total then
                if progress_msg then UIManager:close(progress_msg) end
                progress_msg = InfoMessage:new{
                    text    = string.format(T("Recherche de nouveaux commentaires : %d / %d…"), done, total),
                    timeout = 60,
                }
                UIManager:show(progress_msg)
            end
        end,
        function()
            if progress_msg then UIManager:close(progress_msg) end
            if my_fetch_id == _fetch_id then
                UIManager:show(InfoMessage:new{
                    text    = T("Commentaires actualisés pour les chapitres en cache."),
                    timeout = 3,
                })
            end
        end,
        true -- force : réécrit même les chapitres déjà en cache
    )
end

-- Action déclenchée par le bouton comment.png de l'onglet Chapitres.
function Detail.refreshCachedChaptersComments(source_id, path)
    refresh_downloaded_chapters_comments(source_id, path, _all_chapters)
end

-- Appelé automatiquement après "Actualiser la liste des chapitres" (au lieu
-- de refresh_downloaded_chapters_comments ci-dessus, désormais manuel) :
-- télécharge SEULEMENT les chapitres qui viennent d'apparaître dans la liste
-- (pas encore en cache par définition), pour que leurs commentaires soient
-- disponibles immédiatement — sans jamais toucher aux chapitres déjà en
-- cache. `chapters` doit être la liste exacte des chapitres nouvellement
-- détectés (jamais tout le roman).
local function download_new_chapters_comments(source_id, novel_path, chapters)
    if not chapters or #chapters == 0 then return end
    local ext = ExtMgr.get(source_id)
    if not ext or type(ext.parseChapter) ~= "function" then return end

    -- NovelFrance : on ne précharge automatiquement que les 8 derniers nouveaux chapitres
    -- (les autres se téléchargent à la lecture) — un gros rattrapage d'un coup, avec les
    -- commentaires de chaque paragraphe, saturait la mémoire de la liseuse.
    if source_id == "novelfrance" and #chapters > 8 then
        local last = {}
        for i = #chapters - 7, #chapters do last[#last + 1] = chapters[i] end
        chapters = last
    end
    collectgarbage()
    collectgarbage()

    local my_fetch_id = _fetch_id
    local progress_msg
    Cache.downloadChapters(ext, source_id, novel_path, chapters,
        function(done, total)
            if my_fetch_id ~= _fetch_id then return end
            if done == 1 or done % 10 == 0 or done == total then
                if progress_msg then UIManager:close(progress_msg) end
                progress_msg = InfoMessage:new{
                    text    = string.format(T("Nouveaux chapitres : %d / %d…"), done, total),
                    timeout = 60,
                }
                UIManager:show(progress_msg)
            end
        end,
        function()
            if progress_msg then UIManager:close(progress_msg) end
            if my_fetch_id == _fetch_id then
                UIManager:show(InfoMessage:new{
                    text    = string.format(T("%d nouveau(x) chapitre(s) et leurs commentaires mis en cache."), #chapters),
                    timeout = 3,
                })
            end
        end
        -- pas de force : ces chapitres ne sont par définition pas encore en
        -- cache, donc rien à écraser.
    )
end

-- Bouton "Actualiser" de l'onglet Avis : vide le cache disque des avis et
-- retélécharge la page 1 depuis le site (nécessite le wifi, comme tout
-- appel réseau de ce plugin — passe par NetworkMgr:runWhenConnected dans
-- fetch_reviews_page, qui invite à activer le wifi si besoin).
function Detail.fetchForceRefreshReviews(source_id, path)
    local ext = ExtMgr.get(source_id)
    if not ext or type(ext.parseReviews) ~= "function" then return end

    -- Ne vide surtout pas l'écran pendant l'actualisation : les avis déjà
    -- présents restent visibles et le réseau travaille en arrière-plan.
    -- Cela rend le bouton instantané même sur une liseuse lente.
    DB.clearReviewCache(source_id, path)
    _reviews_loading = true
    _reviews_fetch_id = _reviews_fetch_id + 1
    _reviews_view_page = 1
    invalidate_reviews_render_cache()

    -- Rafraîchissement réseau asynchrone : à la réception, la page 1
    -- remplacera les anciens avis au lieu de les dupliquer.
    fetch_reviews_page(ext, source_id, path, 1, true)

    -- Petit rafraîchissement partiel immédiat pour que le tap soit pris en
    -- compte sans reconstruire tout le panneau.
    if _panel and _detail_tab == "reviews" and _novel_info then
        UIManager:scheduleIn(0, function()
            if _panel and _detail_tab == "reviews" and _novel_info then
                Detail.rebuild(_novel_info, true)
            end
        end)
    end
end

-- Charge les octets de couverture déjà présents sur le disque et les décode dans
-- _cover_bb. Ne touche jamais au réseau — utilisé par le chemin détails hors ligne
-- pour qu'un roman favori avec une couverture en cache n'ait pas besoin de connectivité juste
-- pour être consulté. Renvoie true si une couverture a été définie.
local function load_cover_from_disk_only(source_id, path, given_data)
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri then return false end
    local cdata = given_data or DB.loadCoverCache(source_id, path)
    -- Rejette aussi les couvertures anormalement lourdes (ex. GIF animés de
    -- 10-20 Mo vus sur certains sites) : les décoder peut planter l'app sur
    -- une liseuse — voir core/covers.lua pour le détail.
    if not cdata or #cdata < 512 or #cdata > Covers.MAX_COVER_BYTES then return false end
    local ok_bb, native = pcall(RenderImage.renderImageData, RenderImage, cdata, #cdata, false)
    if not ok_bb or not native then return false end
    local nw, nh = native:getWidth(), native:getHeight()
    if nw <= 0 or nh <= 0 then native:free(); return false end
    local max_w = P.DETAIL_COVER_W
    local max_h = P.DETAIL_COVER_H
    local scale = math.min(max_w / nw, max_h / nh)
    local dw = math.max(1, math.floor(nw * scale))
    local dh = math.max(1, math.floor(nh * scale))
    _cover_bb = native:scale(dw, dh)
    native:free()
    return true
end

-- Construit une table `info` directement depuis l'enregistrement BD du roman suivi — pas
-- besoin d'aller-retour réseau pour un roman déjà dans la bibliothèque.
local function build_offline_info(tracked, path)
    return {
        name           = tracked.title,
        title          = tracked.title,
        path           = tracked.path or path,
        cover          = tracked.cover,
        author         = tracked.author,
        status         = tracked.status,
        summary        = tracked.summary,
        rating         = tracked.rating,
        rank           = tracked.rank,
        total_chapters = tracked.total_chapters,
    }
end

-- Rafraîchit uniquement l'onglet Chapitres. Cette fonction est appelée par
-- le lecteur dès qu'une nouvelle position est enregistrée, et par le moteur
-- de téléchargement dès qu'un chapitre est terminé. Ainsi, quand on revient
-- à la liste, les marqueurs sont déjà à jour : aucun bouton "Actualiser" n'est
-- nécessaire.
function Detail.refreshChapterProgress()
    if not _panel or not _novel_info or _detail_tab ~= "chapters" then return end
    Detail.rebuild(_novel_info, true)
end

function Detail.fetch(source_id, path, force_refresh)
    _fetch_id     = _fetch_id + 1
    _switch_generation = _switch_generation + 1
    local my_id   = _fetch_id
    _source_id    = source_id
    sel_reset()
    _exp_cache.set = nil
    _all_chapters = {}
    _novel_info   = nil
    _page         = 1
    _detail_tab   = "details"
    -- Préférence persistée (cf. sefirah_settings.lua) : ne PAS remettre à false ici
    -- à chaque nouveau roman ouvert, sinon la sauvegarde n'aurait aucun
    -- effet visible au-delà du roman courant.
    _ascending    = default_chapters_ascending()
    if _cover_bb then _cover_bb:free(); _cover_bb = nil end
    _cover_data   = nil
    _reviews      = nil
    _reviews_key  = nil
    _reviews_view_page = 1

    local ext = ExtMgr.get(source_id)
    if not ext then
        UIManager:show(InfoMessage:new{
            text    = T("Extension non chargée : ") .. tostring(source_id),
            timeout = 3,
        })
        return
    end

    -- ── Chemin rapide hors ligne ─────────────────────────────────────────
    -- Déjà favori + on a une liste de chapitres en cache → l'affiche directement
    -- depuis le disque, aucune connectivité requise. Internet n'est nécessaire que pour
    -- « Actualiser la liste des chapitres » ou télécharger/lire un chapitre qui n'est pas
    -- encore en cache.
    -- force_refresh (bouton "Actualiser la liste des chapitres") ignore
    -- volontairement ce raccourci : il doit toujours vérifier le réseau,
    -- jamais rester purement local — sinon le bouton ne ferait rien.
    local tracked   = DB.find(source_id, path)
    local ch_cache  = tracked and DB.loadChapterCache(source_id, path)
    if not force_refresh and tracked and ch_cache and ch_cache.chapters and #ch_cache.chapters > 0 then
        if my_id ~= _fetch_id then return end
        local info    = build_offline_info(tracked, path)
        _all_chapters = ch_cache.chapters
        _novel_info   = info
        load_cover_from_disk_only(source_id, path)
        Detail.rebuild(info)

        -- Migration des anciens résumés corrompus : les versions précédentes
        -- pouvaient avoir enregistré directement un morceau du protocole RSC
        -- de NovelFrance (ex. `34:T622,...`). Dans ce cas, ne pas laisser le
        -- cache hors-ligne figer cette mauvaise valeur. On affiche d'abord
        -- immédiatement le contenu local, puis on ne fait qu'une requête
        -- `parseNovelMeta` en arrière-plan pour récupérer le vrai résumé et le
        -- sauvegarder dans tracked.json. Les romans qui ont déjà un résumé
        -- propre restent 100%% hors-ligne.
        local cached_summary = tracked.summary or ""
        local summary_is_bad = cached_summary:match("^%s*%d+:T[0-9a-fA-F]+,")
            or cached_summary:match("self%.__next_f%.push")
            or cached_summary:match("^%s*%$[0-9a-zA-Z]+%s*$")
        if summary_is_bad then
            Online.run(function()
                if my_id ~= _fetch_id then return end
                UIManager:scheduleIn(0, function()
                    if my_id ~= _fetch_id then return end
                    local meta_fn = ext.parseNovelMeta
                    if type(meta_fn) ~= "function" then return end
                    local ok_meta, fresh = pcall(meta_fn, ext, path)
                    if not ok_meta or type(fresh) ~= "table" then return end
                    local fresh_summary = fresh.summary
                    if not fresh_summary or fresh_summary == "" then return end
                    local current = DB.find(source_id, path)
                    if not current then return end
                    DB.update(source_id, path, {
                        summary = fresh_summary,
                        rating  = fresh.rating,
                        rank    = fresh.rank,
                    })
                    -- Met aussi à jour la fiche affichée immédiatement, sans
                    -- demander à l'utilisateur d'actualiser les chapitres.
                    if _novel_info and _novel_info.path == path then
                        _novel_info.summary = fresh_summary
                        if fresh.rating ~= nil then _novel_info.rating = fresh.rating end
                        if fresh.rank ~= nil then _novel_info.rank = fresh.rank end
                        Detail.rebuild(_novel_info, true)
                    end
                end)
            end)
        end
        return
    end

    Online.run(function()
        local loading = InfoMessage:new{ text = T("Chargement des détails du roman…") }
        UIManager:show(loading)

        UIManager:scheduleIn(0.1, function()
            if my_id ~= _fetch_id then return end

            local info
            -- Rempli UNIQUEMENT dans le chemin delta ci-dessous, avec les
            -- chapitres qui n'existaient PAS dans le cache liste avant ce
            -- fetch (voir plus bas : téléchargement + commentaires
            -- automatique de CEUX-LÀ seulement quand force_refresh).
            local new_chapters_this_fetch = nil
            local refresh_warning = nil

            if type(ext.parseNovelMeta) == "function" then
                -- ── Chemin rapide : récupération des métadonnées seules + chargement intelligent des chapitres ────
                -- Seulement 1 requête HTTP quand le nombre de chapitres n'a pas changé.
                local ok, meta = pcall(ext.parseNovelMeta, ext, path)
                if not ok or not meta then
                    UIManager:close(loading)
                    UIManager:show(InfoMessage:new{
                        text    = T("Échec du chargement du roman : ") .. tostring(meta),
                        timeout = 4,
                    })
                    return
                end
                info = meta

                local new_total = tonumber(info.total_chapters) or 0
                local cache     = DB.loadChapterCache(source_id, path)

                -- NovelFrance peut momentanément renvoyer total_chapters=0 si sa
                -- page de métadonnées n'a pas pu être décodée. Ne lance surtout
                -- pas parseNovel dans ce cas : cette fonction télécharge toute
                -- la liste en dizaines de requêtes synchrones et peut bloquer
                -- KOReader. On garde la liste locale et on signale l'échec.
                if source_id == "novelfrance" and cache and cache.chapters
                   and #cache.chapters > 0 and new_total <= 0 then
                    _all_chapters = normalize_chapter_order(cache.chapters)
                    if tracked then
                        local cached_info = build_offline_info(tracked, path)
                        for k, v in pairs(cached_info) do
                            if info[k] == nil or info[k] == "" then info[k] = v end
                        end
                    end
                    info.total_chapters = #_all_chapters
                    refresh_warning = T("Impossible de vérifier les nouveaux chapitres de NovelFrance. La liste en cache a été conservée.")
                elseif cache and cache.total == new_total and new_total > 0 then
                    -- Cache trouvé : nombre de chapitres inchangé, utilise la liste en cache
                    -- (normalize_chapter_order répare silencieusement un cache déjà
                    -- corrompu par une fusion delta bugguée avant ce correctif)
                    _all_chapters = normalize_chapter_order(cache.chapters)
                    if _all_chapters ~= cache.chapters then
                        -- La réparation a changé l'ordre : on la persiste tout de
                        -- suite, sinon elle ne serait refaite qu'en mémoire à
                        -- chaque ouverture sans jamais corriger le cache disque.
                        DB.saveChapterCache(source_id, path, _all_chapters, #_all_chapters)
                    end
                elseif cache and cache.total > 0 and new_total > cache.total
                       and type(ext.parsePage) == "function" and ext.chapters_per_page then
                    -- Delta : récupère uniquement les nouvelles pages
                    local per_page     = ext.chapters_per_page
                    local first_new_pg = math.floor(cache.total / per_page) + 1
                    local last_pg      = math.ceil(new_total / per_page)
                    local new_chs      = {}
                    local delta_failed = false
                    if type(ext.parseChaptersFrom) == "function" then
                        -- Une seule requête groupée (grosses pages) au lieu d'une
                        -- requête par tranche de chapitres : bien plus fluide, et
                        -- beaucoup moins de risques de connexion refusée.
                        local ok_p, pdata = pcall(ext.parseChaptersFrom, ext, path,
                            (first_new_pg - 1) * per_page)
                        if ok_p and pdata and not pdata.failed and pdata.chapters then
                            new_chs = pdata.chapters
                        else
                            delta_failed = true
                        end
                    else
                        for pg = first_new_pg, last_pg do
                            local ok_p, pdata = pcall(ext.parsePage, ext, path, tostring(pg))
                            if ok_p and pdata and pdata.chapters and not pdata.failed then
                                for _, ch in ipairs(pdata.chapters) do
                                    table.insert(new_chs, ch)
                                end
                            else
                                delta_failed = true
                            end
                        end
                    end
                    -- IMPORTANT : dédupliquer avec la même clé que partout ailleurs
                    -- (Cache.chapterKey). L'ancien code utilisait `ch.path or ""`,
                    -- donc tout chapitre sans `path` (mais avec un `sourceUrl`)
                    -- retombait sur la clé "" : au-delà du premier, ces
                    -- chapitres étaient silencieusement écrasés/perdus dès qu'une
                    -- récupération incrémentale avait lieu — une cause plausible
                    -- des chapitres manquants signalés.
                    --
                    -- BUG corrigé ici : `new_chs` contient toujours les chapitres
                    -- les PLUS RÉCENTS (les nouvelles pages, en `order=asc` côté
                    -- extension), mais `cache.chapters` peut être trié dans les
                    -- deux sens selon la source : croissant (1,2,3...) OU
                    -- décroissant, le plus récent en premier (ex. novelfrance.lua,
                    -- cf. fetch_all_chapters). Ajouter systématiquement `new_chs`
                    -- EN FIN de `_all_chapters` n'est correct que dans le cas
                    -- croissant. En décroissant, ça place les chapitres les plus
                    -- récents après les plus anciens (ex. vécu : [3189,3188,...,
                    -- 1,0, 3190,3191] au lieu de [3191,3190,3189,...,1,0]) — le
                    -- tableau n'est alors plus monotone, ce qui fait dérailler la
                    -- navigation Précédent/Suivant de ui/readerview.lua (qui
                    -- suppose un ordre global cohérent) tout près des tout
                    -- derniers chapitres.
                    -- On détecte le sens de `cache.chapters` (même méthode que
                    -- compute_step dans readerview.lua : première paire de
                    -- numéros distincts rencontrée) et on insère les nouveaux
                    -- chapitres du bon côté : en tête (et dans l'ordre inverse,
                    -- pour rester le plus récent en premier) si décroissant, en
                    -- fin sinon.
                    local cache_descending = false
                    do
                        local prev_num
                        for _, ch in ipairs(cache.chapters) do
                            local n = chapter_number_value(ch, nil)
                            if n then
                                if prev_num then
                                    if n < prev_num then cache_descending = true end
                                    break
                                end
                                prev_num = n
                            end
                        end
                    end

                    local seen = {}
                    for _, ch in ipairs(cache.chapters) do
                        seen[Cache.chapterKey(ch)] = true
                    end
                    local genuinely_new = {}
                    for _, ch in ipairs(new_chs) do
                        if not seen[Cache.chapterKey(ch)] then
                            seen[Cache.chapterKey(ch)] = true
                            table.insert(genuinely_new, ch)
                        end
                    end

                    _all_chapters = {}
                    if cache_descending then
                        for i = #genuinely_new, 1, -1 do
                            table.insert(_all_chapters, genuinely_new[i])
                        end
                        for _, ch in ipairs(cache.chapters) do
                            table.insert(_all_chapters, ch)
                        end
                    else
                        for _, ch in ipairs(cache.chapters) do
                            table.insert(_all_chapters, ch)
                        end
                        for _, ch in ipairs(genuinely_new) do
                            table.insert(_all_chapters, ch)
                        end
                    end
                    -- Filet de sécurité final : si `cache.chapters` lui-même était
                    -- déjà corrompu (ancienne fusion buguée), le repère de sens
                    -- basé sur ses deux premiers numéros peut être faux — on
                    -- revalide/répare l'ensemble avant de sauvegarder.
                    _all_chapters = normalize_chapter_order(_all_chapters)

                    -- Filet de sécurité : cette fusion incrémentale suppose que la
                    -- pagination du site est stable et purement additive (les
                    -- nouveaux chapitres s'ajoutent à la fin, les anciens ne
                    -- changent jamais de page). Si le site trie différemment
                    -- (nouveautés en premier, réorganisation, tri variable) ou si
                    -- le total obtenu ne correspond pas à ce qu'on attendait, la
                    -- fusion par page peut laisser des trous. Dans ce cas, on
                    -- retombe sur une récupération complète plutôt que de mettre
                    -- en cache une liste silencieusement incomplète.
                    if (#_all_chapters ~= new_total or (delta_failed and source_id == "novelfrance"))
                       and type(ext.parseNovel) == "function" then
                        if source_id == "novelfrance" then
                            -- Ne pas retomber sur parseNovel : il charge toute
                            -- la liste via de nombreuses requêtes synchrones.
                            -- Si une page delta a échoué, mieux vaut garder le
                            -- cache intact que remplacer la liste par une liste
                            -- partielle ou bloquer la liseuse.
                            _all_chapters = normalize_chapter_order(cache.chapters)
                            genuinely_new = nil
                            refresh_warning = T("La mise à jour des chapitres NovelFrance a échoué. La liste précédente a été conservée ; réessaie plus tard.")
                        else
                            local ok_full, full = pcall(ext.parseNovel, ext, path)
                            if ok_full and full and full.chapters then
                                _all_chapters = full.chapters
                                -- La liste "genuinely_new" ne correspond plus à rien
                                -- de fiable après un remplacement complet.
                                genuinely_new = nil
                            end
                        end
                    end

                    if not refresh_warning then
                        DB.saveChapterCache(source_id, path, _all_chapters, #_all_chapters)
                        new_chapters_this_fetch = genuinely_new
                    end
                else
                    -- Récupération complète (cache manquant ou source sans delta).
                    -- Pour NovelFrance, une baisse temporaire/erronée du compteur
                    -- ne doit pas déclencher le téléchargement complet de tous
                    -- les chapitres pendant l'actualisation.
                    if source_id == "novelfrance" and cache and cache.chapters
                       and #cache.chapters > 0 and new_total < (tonumber(cache.total) or #cache.chapters) then
                        _all_chapters = normalize_chapter_order(cache.chapters)
                        refresh_warning = T("Le compteur de chapitres NovelFrance semble incorrect. La liste en cache a été conservée.")
                    else
                        local ok_n, full = pcall(ext.parseNovel, ext, path)
                        local failed_full = (not ok_n) or (not full) or (full.incomplete == true)
                        if failed_full and cache and cache.chapters and #cache.chapters > 0 then
                            -- Échec réseau : on garde la liste précédente telle quelle.
                            _all_chapters = normalize_chapter_order(cache.chapters)
                            refresh_warning = T("La mise à jour des chapitres NovelFrance a échoué. La liste précédente a été conservée ; réessaie plus tard.")
                        else
                            if ok_n and full then
                                _all_chapters = full.chapters or {}
                                for k, v in pairs(full) do
                                    if info[k] == nil then info[k] = v end
                                end
                            end
                            -- Jamais de cache vide ni partiel : sinon la liste resterait
                            -- vide (ou tronquée) à toutes les ouvertures suivantes.
                            if failed_full then
                                refresh_warning = T("La liste des chapitres n'a pas pu être chargée. Vérifie la connexion et réessaie.")
                            else
                                DB.saveChapterCache(source_id, path, _all_chapters, #_all_chapters)
                            end
                        end
                    end
                end
                info.total_chapters = #_all_chapters

            else
                -- ── Chemin historique : parseNovel renvoie tout ────────────────
                local ok, full = pcall(ext.parseNovel, ext, path)
                if not ok or not full then
                    UIManager:close(loading)
                    UIManager:show(InfoMessage:new{
                        text    = T("Échec du chargement du roman : ") .. tostring(full),
                        timeout = 4,
                    })
                    return
                end
                info          = full
                _all_chapters = full.chapters or {}
                DB.saveChapterCache(source_id, path, _all_chapters, #_all_chapters)
            end

            UIManager:close(loading)
            _novel_info = info
            if refresh_warning then
                UIManager:show(InfoMessage:new{ text = refresh_warning, timeout = 5 })
            end

            -- ── Couverture : cache disque d'abord, téléchargement si manquante/corrompue ────────────
            if info.cover and info.cover ~= "" then
                local ok_epub, Epub       = pcall(require, "core.epub")
                local ok_ri,  RenderImage = pcall(require, "ui/renderimage")
                if ok_epub and ok_ri then
                    -- Essaie de décoder `data` en un BlitBuffer utilisable ; renvoie
                    -- nil (et ne libère rien, puisque rien n'a été alloué) si
                    -- les données sont absentes, trop petites, ou échouent au décodage.
                    -- Rejeter les mauvaises données ici — plutôt que de faire confiance à ce qui
                    -- se trouve sur le disque — c'est ce qui permet à une couverture en cache
                    -- précédemment corrompue de se réparer à la prochaine visite de cette page.
                    local function try_render(data)
                        if not data or #data < 512 or #data > Covers.MAX_COVER_BYTES then return nil end
                        local ok_bb, native = pcall(
                            RenderImage.renderImageData, RenderImage, data, #data, false)
                        if not ok_bb or not native then return nil end
                        local nw, nh = native:getWidth(), native:getHeight()
                        if nw <= 0 or nh <= 0 then native:free(); return nil end
                        return native, nw, nh
                    end

                    local xe_cover = ExtMgr.get(source_id)
                    local cdata = (not (xe_cover and xe_cover.refreshCover)) and DB.loadCoverCache(source_id, path) or nil
                    local native, nw, nh = try_render(cdata)

                    if not native then
                        local ext_meta = ExtMgr.getMeta(source_id)
                        cdata = Epub.fetch_cover(info.cover, ext_meta and ext_meta.site)
                        native, nw, nh = try_render(cdata)
                        if native then
                            -- (native non-nil implique déjà #cdata <= MAX_COVER_BYTES, voir try_render ci-dessus)
                            -- N'écraser le cache disque qu'une fois qu'on a un
                            -- décodage confirmé bon, pour qu'un incident réseau
                            -- transitoire ne puisse pas effacer une couverture précédemment bonne.
                            DB.saveCoverCache(source_id, path, cdata)
                        end
                    end

                    if native then
                        local max_w = P.DETAIL_COVER_W
                        local max_h = P.DETAIL_COVER_H
                        local scale = math.min(max_w / nw, max_h / nh)
                        local dw = math.max(1, math.floor(nw * scale))
                        local dh = math.max(1, math.floor(nh * scale))
                        _cover_bb   = native:scale(dw, dh)
                        _cover_data = cdata
                        native:free()
                    end
                end
            end

            -- ── Persiste résumé / note / rang pour les romans suivis ─────────────────
            -- Le résumé ne change quasiment jamais : on ne l'écrit qu'une fois, s'il
            -- manquait. La note et le rang, eux, évoluent dans le temps (nouveaux
            -- votes, classement qui bouge) : on les rafraîchit à chaque fetch réseau
            -- réussi, pour qu'un roman suivi affiche une valeur à jour même consulté
            -- hors ligne ensuite (cf. build_offline_info).
            do
                local tracked = DB.find(source_id, info.path or path)
                if tracked then
                    local updates = {}
                    if info.summary and info.summary ~= "" and info.summary ~= tracked.summary then
                        updates.summary = info.summary
                    end
                    if info.rating ~= nil then updates.rating = info.rating end
                    if info.rank   ~= nil then updates.rank   = info.rank   end
                    if next(updates) then
                        DB.update(source_id, info.path or path, updates)
                    end
                end
            end

            Detail.rebuild(info)

            -- Bouton "Actualiser la liste des chapitres" uniquement (pas un
            -- chargement normal de l'écran Détails) : ne télécharge QUE les
            -- chapitres nouvellement détectés (jamais tout le cache du
            -- roman — cf. download_new_chapters_comments plus haut). Pour
            -- rafraîchir les commentaires des chapitres déjà en cache, voir
            -- le bouton dédié (Detail.refreshCachedChaptersComments).
            if force_refresh and new_chapters_this_fetch and #new_chapters_this_fetch > 0 then
                download_new_chapters_comments(source_id, info.path or path, new_chapters_this_fetch)
            end
        end)
    end)
end

-- Copie en mémoire de la fiche ouverte : le lecteur de manga ferme tout Sefirah
-- (Detail.shutdown remet l'état à zéro) ; à la fermeture du lecteur, on rouvre la
-- fiche instantanément depuis cette copie, sans passer par la bibliothèque ni le réseau.
function Detail.snapshot()
    if not _novel_info or not _all_chapters or #_all_chapters == 0 then return nil end
    return {
        source_id = _source_id, info = _novel_info, chapters = _all_chapters,
        tab = _detail_tab, page = _page, ascending = _ascending, cover_data = _cover_data,
    }
end

function Detail.restoreSnapshot(snap)
    if type(snap) ~= "table" or not snap.info then return false end
    _fetch_id = _fetch_id + 1
    _switch_generation = _switch_generation + 1
    sel_reset()
    _exp_cache.set = nil
    _source_id    = snap.source_id
    _novel_info   = snap.info
    _all_chapters = snap.chapters
    _detail_tab   = snap.tab or "details"
    _page         = snap.page or 1
    _ascending    = snap.ascending
    _reviews, _reviews_key, _reviews_view_page = nil, nil, 1
    if _cover_bb then _cover_bb:free(); _cover_bb = nil end
    _cover_data = snap.cover_data
    load_cover_from_disk_only(snap.source_id, snap.info.path or "", snap.cover_data)
    Detail.rebuild(snap.info)
    return true
end

function Detail.shutdown()
    -- Appelé par la sortie globale du plugin (notamment le swipe haut -> bas).
    -- Invalide immédiatement tous les callbacks réseau/planifiés et détruit
    -- le panneau privé de Detail, afin qu'un prochain lancement reparte avec
    -- un arbre de widgets neuf.
    _fetch_id = _fetch_id + 1
    _switch_generation = _switch_generation + 1
    _reviews_fetch_id = _reviews_fetch_id + 1
    _reviews_loading = false
    if _panel then pcall(UIManager.close, UIManager, _panel) end
    _panel = nil
    if _cover_bb then pcall(_cover_bb.free, _cover_bb); _cover_bb = nil end
    _cover_data = nil
    _novel_info = nil
    _all_chapters = {}
    sel_reset()
    _idx_cache.list = nil
    _exp_cache.set = nil
    _reviews = nil
    _reviews_key = nil
    _reviews_page = 0
    _reviews_has_more = false
    _reviews_view_page = 1
    invalidate_reviews_render_cache()
end

function Detail.close()
    if _panel then
        UIManager:close(_panel)
        _panel = nil
    end
    if _cover_bb then
        _cover_bb:free()
        _cover_bb = nil
    end
    _cover_data = nil
end

-- File de téléchargement : redessine la liste des chapitres (coches « ✓ ») tous
-- les ~10 chapitres, uniquement pour un téléchargement lancé à la main et tant
-- que la fiche de CE roman est affichée sur l'onglet Chapitres.
pcall(function()
    require("core.dlqueue").setListener("detail", function(ev, job)
        if ev ~= "progress" and ev ~= "job_done" then return end
        if not job or job.kind ~= "manual" then return end
        -- Lecteur / export ouvert au-dessus de la fiche : on ne touche à rien
        -- (reconstruire la fiche fermerait le lecteur).
        local ok_m, SefirahUI = pcall(require, "ui.main_widget")
        if ok_m and SefirahUI.isOverlayOpen and SefirahUI.isOverlayOpen() then return end
        if _panel and _novel_info and _source_id == job.source_id
           and (_novel_info.path or "") == job.novel_path and _detail_tab == "chapters" then
            Detail.rebuild(_novel_info, true)
        end
    end)
end)

return Detail
