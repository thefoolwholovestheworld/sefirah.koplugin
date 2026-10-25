-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- ui/mangaopen.lua — Ouverture d'un chapitre de MANGA (étapes 12 à 17).
-- Appelé par ReaderView.open quand ctx.ext.type == "manga" : télécharge les
-- pages en CBZ (core/manga.lua) puis ouvre le CBZ dans le lecteur natif de
-- KOReader (zoom, recadrage, sens manga, marque-pages).
local UIManager  = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
-- Boîte avec bouton « Annuler » : selon la version de KOReader ; repli sans bouton.
local ok_bd, ButtonDialogTitle = pcall(require, "ui/widget/buttondialogtitle")
if not ok_bd then ok_bd, ButtonDialogTitle = pcall(require, "ui/widget/buttondialog") end
local Settings   = require("sefirah_settings")
local Online      = require("core.online")
local logger     = require("logger")
local T          = require("core.i18n").T
local Manga      = require("core.manga")
local Cache      = require("core.cache")
local DB         = require("core.db")

local MangaOpen = {}

local ERRORS = {
    missing_pages  = "Certaines pages n'ont pas pu être téléchargées (connexion ?). Les pages déjà reçues sont conservées : retouche le chapitre pour reprendre.",
    cancelled      = "Téléchargement annulé. Les pages déjà reçues sont conservées.",
    no_images      = "Aucune page disponible pour ce chapitre.",
    at_home_unavailable = "Le serveur d'images de MangaDex est indisponible. Réessaie plus tard.",
    no_pages       = "Aucune page disponible pour ce chapitre.",
    zip_failed     = "Impossible de créer le fichier CBZ (espace disque ?).",
    mkdir_failed   = "Impossible de créer le dossier de téléchargement.",
}

local function show_error(err)
    UIManager:show(InfoMessage:new{
        text = T(ERRORS[tostring(err)] or "Impossible de télécharger ce chapitre."),
        timeout = 5,
    })
end

-- ── Retour à Sefirah + suivi de lecture (étapes 13 et 14) ───────────────────
-- État partagé entre l'instance du plugin dans le lecteur (qui voit la
-- fermeture du CBZ) et celle du gestionnaire de fichiers (qui rouvre Sefirah).
local pending = nil   -- { source_id, novel_path, chapter_path, cbz, closed_at? }
local RETURN_DELAY = 8   -- s : au-delà, ce n'est plus « la fermeture du CBZ »

-- Appelé par le plugin quand le lecteur ferme un document.
-- `page`/`total` viennent du lecteur natif (mode pages, donc CBZ).
function MangaOpen.onDocumentClosed(file, page, total)
    local p = pending
    if not p or p.cbz ~= file then return end
    p.closed_at = os.time()
    page, total = tonumber(page), tonumber(total)
    if not page or not total or total < 1 then return end
    page = math.max(1, math.min(page, total))
    p.completed = page >= total
    -- « Lu » = dernière page atteinte. Sinon le chapitre reste en cours.
    pcall(Cache.setProgress, p.source_id, p.novel_path, p.chapter_path,
        page / total, page, total, page >= total or nil)
    pcall(DB.update, p.source_id, p.novel_path, { last_read_at = os.time() })
end

-- Supprime un CBZ lu (et son dossier de réglages .sdr, et son entrée d'historique).
local function delete_cbz(cbz)
    if type(cbz) ~= "string" or not cbz:match("%.cbz$") then return end
    os.remove(cbz)
    local ok_l, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_l then ok_l, lfs = pcall(require, "lfs") end
    local sdr = cbz:gsub("%.cbz$", ".sdr")
    if ok_l and lfs.attributes(sdr, "mode") == "directory" then
        for f in lfs.dir(sdr) do
            if f ~= "." and f ~= ".." then os.remove(sdr .. "/" .. f) end
        end
        lfs.rmdir(sdr)
    end
    pcall(function() require("readhistory"):removeItemByPath(cbz) end)
end

-- Appelé à chaque démarrage du plugin. Dans le lecteur : oublie l'attente si
-- on ouvre autre chose que notre CBZ. Dans le gestionnaire de fichiers :
-- rouvre la fiche du manga juste après la fermeture du CBZ.
function MangaOpen.onPluginInit(in_reader, doc_file)
    local p = pending
    if not p then return end
    if in_reader then
        if doc_file ~= p.cbz then pending = nil end
        return
    end
    pending = nil
    if not p.closed_at then return end
    -- Étape 17 : « supprimer après lecture » (le lecteur a déjà tout enregistré).
    if p.completed and Settings:get("manga_autoclean") then delete_cbz(p.cbz) end
    if os.time() - p.closed_at > RETURN_DELAY then return end
    UIManager:scheduleIn(0.3, function()
        if _G.sefirah_open_novel then
            pcall(_G.sefirah_open_novel, p.source_id, p.novel_path)
        end
    end)
end

-- Étape 17 : sens de lecture. Réglage « inverse_reading_order » du lecteur natif,
-- posé UNE fois par CBZ (s'il n'existe pas encore) pour ne pas écraser un choix
-- fait ensuite dans le lecteur.
local function direction_rtl(chapter)
    local mode = Settings:get("manga_direction") or "auto"
    if mode == "rtl" then return true end
    if mode == "ltr" then return false end
    return chapter.rtl ~= false
end

local function apply_direction(cbz, chapter)
    local rtl = direction_rtl(chapter)
    pcall(function()
        local DocSettings = require("docsettings")
        local ds = DocSettings:open(cbz)
        if ds:readSetting("inverse_reading_order") == nil then
            ds:saveSetting("inverse_reading_order", rtl)
            ds:flush()
        end
    end)
end

-- Sens de la liste de chapitres (ascendante = +1, descendante = -1), d'après les
-- numéros de chapitre. La navigation reste positionnelle (idx ± step).
local function list_step(chapters)
    local prev
    for _, ch in ipairs(chapters or {}) do
        local n = tonumber(ch.chapter_number)
        if n then
            if prev then
                if n < prev then return -1 end
                if n > prev then return 1 end
            end
            prev = n
        end
    end
    return 1
end

-- Préchargement silencieux du chapitre suivant : il démarre dès l'ouverture du
-- chapitre en cours (après ~1 s, le temps d'afficher la 1re page), pendant qu'on lit.
-- Quand on arrive à la dernière page, le CBZ est déjà prêt. Aucun popup ; toute
-- erreur est ignorée (les pages reçues restent dans .tmp_* et servent à la reprise).
-- Largeur 12 (au lieu de 8) : la lecture, elle, ne consomme presque rien ; le plafond
-- global de sous-processus (core/manga.lua) empêche tout dépassement.
local PREFETCH_WAVE  = 12
local PREFETCH_DELAY = 1
local _prefetching = {}
local function prefetch_chapter(ctx, idx)
    if Settings:get("manga_prefetch") == false then return end
    local chapter = ctx.chapters and ctx.chapters[idx]
    if not chapter or not chapter.path then return end
    local novel_title = ctx.novel.name or ctx.novel.title or ctx.novel.path or "manga"
    if Manga.isDownloaded(novel_title, chapter, idx) then return end
    local key = tostring(ctx.source_id) .. "|" .. tostring(chapter.path)
    if _prefetching[key] then return end
    _prefetching[key] = true
    UIManager:scheduleIn(PREFETCH_DELAY, function()
        local ok = pcall(Manga.download, {
            ext = ctx.ext, chapter = chapter, novel_title = novel_title, index = idx,
            wave = PREFETCH_WAVE,
            cover_fn = function() return Manga.fetchCover(ctx.source_id, ctx.novel) end,
            on_done = function() _prefetching[key] = nil end,
        })
        if not ok then _prefetching[key] = nil end
    end)
end

-- Lecteur d'images intégré (ui/imagereader.lua).
-- Chapitre suivant / précédent : le lecteur RESTE ouvert (écran « Chargement… »
-- dans le lecteur) et on remplace simplement ses pages (host:swap) : plus de
-- sortie du plugin. À la fermeture (croix, retour), la fiche du manga est rouverte
-- par-dessus le lecteur, puis le lecteur se ferme.
-- host = lecteur déjà ouvert (changement de chapitre) ou nil (première ouverture).
local function open_in_sefirah(ctx, chapter, cbz, idx, host)
    local source_id, novel_path = ctx.source_id, ctx.novel.path or ""
    local step = list_step(ctx.chapters)
    -- Le chapitre lu devient le plus récent : la limite d'espace (enforceLimit) supprime
    -- les plus anciens et ne doit jamais toucher le chapitre qu'on est en train de lire.
    pcall(function()
        local ok_l, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_l and lfs and lfs.touch then lfs.touch(cbz) end
    end)
    local prev_i, next_i = idx - step, idx + step
    -- Copie de la fiche (prise avant que le plugin se ferme) pour la rouvrir sans attente.
    if not host then
        local ok_s, snap = pcall(function() return require("ui.detail").snapshot() end)
        _G.sefirah_detail_snapshot = (ok_s and snap and snap.source_id == source_id) and snap or nil
    end
    local function back()
        if _G.sefirah_open_novel then
            pcall(_G.sefirah_open_novel, source_id, novel_path, nil, _G.sefirah_detail_snapshot)
        end
    end
    local prev = Cache.getChapterProgress(source_id, novel_path, chapter.path)
    local start = (prev and not prev.completed and tonumber(prev.current_page)) or 1
    local auto_next = Settings:get("manga_autonext")
    if auto_next == nil then auto_next = true end

    -- Enregistre la progression du chapitre quitté.
    local function record(page, total)
        total = math.max(1, tonumber(total) or 1)
        page = tonumber(page) or 1
        local completed = page >= total
        pcall(Cache.setProgress, source_id, novel_path, chapter.path,
            page / total, page, total, completed or nil)
        pcall(DB.update, source_id, novel_path, { last_read_at = os.time() })
        if completed and Settings:get("manga_autoclean") then delete_cbz(cbz) end
    end

    -- XP des mangas : une page tournée = quelques XP (moins que les novels), cf. core/quests.lua.
    local qctx = { source_id = source_id, novel = ctx.novel, chapters = ctx.chapters, index = idx, step = step }
    local function on_page(page, total)
        pcall(function()
            require("core.quests").track(qctx, page, page >= total, total, "manga")
        end)
    end

    local opts = {
        cbz = cbz, title = chapter.name, start_page = start, on_page = on_page,
        rtl = direction_rtl(chapter),
        has_prev = ctx.chapters[prev_i] ~= nil,
        has_next = ctx.chapters[next_i] ~= nil,
        auto_next = auto_next,
        on_close = function(page, total)
            record(page, total)
            back()
        end,
        on_nav = function(dir, page, total, reader)
            record(page, total)
            local target = idx + dir * step
            if ctx.chapters[target] then
                return MangaOpen.open(ctx, target, reader)
            end
            reader:restore()
        end,
    }

    if host then
        local ok, err = pcall(function() return host:swap(opts) end)
        if not ok or err == nil then
            if not ok then logger.err("Sefirah/ImageReader:", tostring(err)) end
            host:restore(T("Impossible de lire les pages de ce chapitre."))
        else
            if ctx.chapters[next_i] then pcall(prefetch_chapter, ctx, next_i) end
        end
        return
    end

    if _G.sefirah_close_all then pcall(_G.sefirah_close_all) end
    local ok, reader = pcall(function() return require("ui.imagereader").open(opts) end)
    if ok and reader and ctx.chapters[next_i] then pcall(prefetch_chapter, ctx, next_i) end
    if not ok or not reader then
        if not ok then
            logger.err("Sefirah/ImageReader:", tostring(reader))
            UIManager:show(InfoMessage:new{ text = "Sefirah/ImageReader : " .. tostring(reader) })
        end
        back()
    end
end

-- Ferme l'interface Sefirah puis ouvre le CBZ dans le lecteur KOReader.
local function open_in_koreader(cbz)
    if _G.sefirah_close_all then pcall(_G.sefirah_close_all) end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then
        return UIManager:show(InfoMessage:new{ text = T("Lecteur KOReader introuvable."), timeout = 4 })
    end
    ReaderUI:showReader(cbz)
end

-- host = lecteur intégré déjà ouvert (changement de chapitre) : il reste affiché
-- pendant le téléchargement ; en cas d'échec ou d'annulation il revient à la
-- page qu'on lisait (on ne quitte plus le plugin).
function MangaOpen.open(ctx, start_index, host)
    local idx = start_index or 1
    local chapter = ctx.chapters and ctx.chapters[idx]
    if not chapter then
        if host and host.restore then host:restore() end
        return
    end
    if host and type(host) ~= "table" then host = nil end
    local novel_title = ctx.novel.name or ctx.novel.title or ctx.novel.path or "manga"
    local token = host and host._nav_token
    -- Le lecteur a-t-il été annulé / fermé entre-temps ?
    local function alive()
        return not host or (not host._gone and host._busy and host._nav_token == token)
    end
    local function fail_in_place(msg)
        if host and not host._gone then host:restore(msg) end
    end
    local function back_to_novel()
        fail_in_place()
    end

    local function finish(cbz)
        if host and not alive() then return end
        local novel_path = ctx.novel.path or ""
        -- Étape 14 : plus de « lu » à l'ouverture. On garde la progression
        -- existante ; elle est mise à jour à la fermeture du CBZ.
        local prev = Cache.getChapterProgress(ctx.source_id, novel_path, chapter.path)
        pcall(Cache.setProgress, ctx.source_id, novel_path, chapter.path,
            prev and prev.percent or 0, nil, nil, nil)
        pcall(DB.update, ctx.source_id, novel_path, { last_read_at = os.time() })
        if host or Settings:get("manga_reader") == "sefirah" then
            return open_in_sefirah(ctx, chapter, cbz, idx, host)
        end
        -- Étape 13 : de quoi revenir à la fiche du manga à la fermeture.
        pending = { source_id = ctx.source_id, novel_path = novel_path,
                    chapter_path = chapter.path, cbz = cbz }
        apply_direction(cbz, chapter)
        -- Lecteur natif KOReader : le chapitre suivant se télécharge aussi dès l'ouverture.
        local nxt = idx + list_step(ctx.chapters)
        if ctx.chapters[nxt] then pcall(prefetch_chapter, ctx, nxt) end
        open_in_koreader(cbz)
    end

    if Manga.isDownloaded(novel_title, chapter, idx) then
        return finish(Manga.cbzPath(novel_title, chapter, idx))
    end

    local popup
    local cancelled = false
    -- Toucher l'écran « Chargement… » du lecteur annule le téléchargement.
    if host then
        host._on_busy_cancel = function()
            cancelled = true
            if popup then UIManager:close(popup); popup = nil end
        end
    end
    Online.run(function()
        -- Étape 15 : popup de progression avec bouton « Annuler ». L'annulation
        -- prend effet à la fin de la vague de pages en cours.
        local function say(text, with_cancel)
            if popup then UIManager:close(popup); popup = nil end
            if with_cancel and ok_bd then
                popup = ButtonDialogTitle:new{
                    title = text,
                    buttons = {{{
                        text = T("Annuler"),
                        callback = function()
                            cancelled = true
                            say(T("Annulation…"))
                        end,
                    }}},
                }
            else
                popup = InfoMessage:new{ text = text }
            end
            UIManager:show(popup)
            UIManager:forceRePaint()
        end
        say(T("Récupération des pages…"))
        -- Laisse l'écran se rafraîchir avant la requête (bloquante).
        UIManager:scheduleIn(0.2, function()
            if cancelled then return end
            local ok_dl, err_dl = pcall(Manga.download, {
                ext = ctx.ext, chapter = chapter, novel_title = novel_title, index = idx,
                cover_fn = function() return Manga.fetchCover(ctx.source_id, ctx.novel) end,
                is_cancelled = function() return cancelled end,
                on_progress = function(done, total)
                    if cancelled then return end
                    say(string.format(T("Téléchargement : %d / %d pages"), done, total), true)
                end,
                on_done = function(ok, value)
                    if popup then UIManager:close(popup); popup = nil end
                    if host and not alive() then return end   -- déjà annulé depuis le lecteur
                    if ok then return finish(value) end
                    logger.warn("Sefirah/Manga: échec du chapitre", tostring(chapter.path), tostring(value))
                    show_error(value)
                    back_to_novel()
                end,
            })
            if not ok_dl then
                if popup then UIManager:close(popup); popup = nil end
                logger.err("Sefirah/Manga: erreur interne", tostring(err_dl))
                UIManager:show(InfoMessage:new{ text = "Sefirah/Manga : " .. tostring(err_dl) })
                back_to_novel()
            end
        end)
    end)
end

return MangaOpen
