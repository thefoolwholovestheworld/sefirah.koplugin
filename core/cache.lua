-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- core/cache.lua — Cache de lecture hors-ligne + progression + téléchargement.
-- Réutilise le pattern de core/db.lua : un fichier résumé JSON (downloads.json)
-- + un fichier de contenu par chapitre sur disque.
local DataStorage = require("datastorage")
local logger      = require("logger")
local Avatars     = require("core.avatars")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local ok_json, JSON = pcall(require, "rapidjson")
if not ok_json then JSON = require("json") end

local Cache = {}

local base_dir     = DataStorage:getSettingsDir() .. "/sefirah"
local content_dir  = base_dir .. "/reader_cache"
local summary_path = base_dir .. "/downloads.json"

local _summary = nil  -- lazy: { novels = { [novel_key] = {...} } }

-- ── Internal ──────────────────────────────────────────────────────────────────

local function ensure_dirs()
    if lfs.attributes(base_dir, "mode") ~= "directory" then lfs.mkdir(base_dir) end
    if lfs.attributes(content_dir, "mode") ~= "directory" then lfs.mkdir(content_dir) end
end

local function novel_key(source_id, novel_path)
    return (source_id .. "__" .. novel_path):gsub("[^%w%-]", "_")
end

local function chapter_slug(chapter_path)
    return (chapter_path or ""):gsub("[^%w%-]", "_")
end

local function content_path(source_id, novel_path, chapter_path)
    return content_dir .. "/" .. novel_key(source_id, novel_path)
        .. "__" .. chapter_slug(chapter_path) .. ".html"
end

-- Fichier JSON séparé (un par chapitre) stockant le fil COMPLET des
-- commentaires de chaque paragraphe commenté — { [paragraph_id] = { {author,
-- content, ...}, ... }, ... }. Distinct de content_path (le HTML du
-- chapitre) : les commentaires peuvent être rafraîchis (nouveaux avis)
-- sans re-télécharger tout le chapitre, et vice-versa.
local function comments_path(source_id, novel_path, chapter_path)
    return content_dir .. "/" .. novel_key(source_id, novel_path)
        .. "__" .. chapter_slug(chapter_path) .. "__comments.json"
end

local function load_summary()
    if _summary then return _summary end
    ensure_dirs()
    local f = io.open(summary_path, "r")
    if not f then _summary = { novels = {} }; return _summary end
    local raw = f:read("*all"); f:close()
    local ok, parsed = pcall(JSON.decode, raw)
    _summary = (ok and parsed and parsed.novels) and parsed or { novels = {} }
    return _summary
end

local _save_pending = false

local function save_summary()
    _save_pending = false
    ensure_dirs()
    local f = io.open(summary_path, "w")
    if not f then logger.err("Sefirah/Cache: cannot write downloads.json"); return end
    f:write(JSON.encode(_summary))
    f:close()
end

-- Écriture différée : réécrire tout downloads.json après CHAQUE chapitre rendait
-- les gros téléchargements de plus en plus lents (le fichier grossit à chaque
-- chapitre). On regroupe les écritures : une seule, 3 s après la dernière demande,
-- et une écriture forcée à la fin d'un téléchargement (Cache.flush).
local function flush_summary()
    if _save_pending and _summary then save_summary() end
    _save_pending = false
end

local function schedule_save()
    if _save_pending then return end
    _save_pending = true
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok and UIManager then
        UIManager:scheduleIn(3, flush_summary)
    else
        flush_summary()
    end
end

function Cache.flush() flush_summary() end

-- create=true creates the entry (and its key) if it doesn't exist yet.
local function get_entry(source_id, novel_path, create)
    local data = load_summary()
    local key  = novel_key(source_id, novel_path)
    local e    = data.novels[key]
    if not e and create then
        e = {
            source_id  = source_id,
            novel_path = novel_path,
            chapters   = {},   -- [chapter_path] = { title, order, downloaded_at }
            progress   = nil,  -- dernier chapitre lu (compatibilité / reprise globale)
            progress_by_chapter = {}, -- [chapter_path] = { percent, updated_at }
            updated_at = os.time(),
        }
        data.novels[key] = e
    end
    return e
end

-- ── Query ─────────────────────────────────────────────────────────────────────

-- Identifiant stable d'un chapitre. Exporté (Cache.chapterKey) pour que TOUT
-- le code (detail.lua, readerview.lua, cache.lua) dérive la même clé à partir
-- du même chapitre : avant ce correctif, detail.lua utilisait un repli
-- différent (tostring(idx) au lieu de ""), ce qui pouvait faire pointer
-- l'affichage (coche téléchargé, progression) et le stockage disque vers
-- deux clés différentes pour un même chapitre sans `path`/`sourceUrl`.
-- On traite aussi une chaîne vide comme "absente" (Lua considère "" comme
-- vrai), pour ne pas regrouper par erreur plusieurs chapitres sous la clé "".
local function ch_key(ch)
    local p = ch.path
    if p == nil or p == "" then p = ch.sourceUrl end
    if p == nil or p == "" then p = nil end
    return p or ("idx:" .. tostring(ch.chapter_number or ch.order or ch.name or ch.title or "?"))
end
Cache.chapterKey = ch_key

function Cache.isChapterCached(source_id, novel_path, chapter_path)
    local e = get_entry(source_id, novel_path, false)
    if not e or not e.chapters[chapter_path] then return false end
    return lfs.attributes(content_path(source_id, novel_path, chapter_path), "mode") == "file"
end

function Cache.getChapterHtml(source_id, novel_path, chapter_path)
    local f = io.open(content_path(source_id, novel_path, chapter_path), "r")
    if not f then return nil end
    local html = f:read("*all"); f:close()
    return html
end

-- ── Traductions (core/translate.lua) ───────────────────────────────────────
-- Un fichier par chapitre ET par langue cible, à côté de l'original (jamais modifié).
local function translation_path(source_id, novel_path, chapter_path, lang)
    return content_path(source_id, novel_path, chapter_path)
        .. ".tr_" .. (lang or ""):gsub("[^%w]", "_")
end

function Cache.getTranslation(source_id, novel_path, chapter_path, lang)
    local f = io.open(translation_path(source_id, novel_path, chapter_path, lang), "r")
    if not f then return nil end
    local html = f:read("*all"); f:close()
    if html == "" then return nil end
    return html
end

-- Test rapide (1 octet lu) : sert à afficher l'icône « version traduite »
-- à côté des chapitres de la fiche sans relire tout le fichier.
function Cache.hasTranslation(source_id, novel_path, chapter_path, lang)
    local f = io.open(translation_path(source_id, novel_path, chapter_path, lang), "r")
    if not f then return false end
    local c = f:read(1); f:close()
    return c ~= nil
end

function Cache.storeTranslation(source_id, novel_path, chapter_path, lang, html)
    ensure_dirs()
    local f = io.open(translation_path(source_id, novel_path, chapter_path, lang), "w")
    if not f then return false end
    f:write(html); f:close()
    return true
end

function Cache.removeTranslation(source_id, novel_path, chapter_path, lang)
    return os.remove(translation_path(source_id, novel_path, chapter_path, lang)) and true or false
end

-- Supprime les traductions d'un chapitre dans TOUTES les langues (fichiers
-- <chapitre>.html.tr_*). Renvoie le nombre de fichiers supprimés.
function Cache.removeAllTranslations(source_id, novel_path, chapter_path)
    local full = content_path(source_id, novel_path, chapter_path)
    local dir, base = full:match("^(.*)/([^/]+)$")
    if not dir then return 0 end
    local prefix = base .. ".tr_"
    local n, seen = 0, {}

    -- Suppression directe des langues connues : plus fiable sur Kobo que
    -- certaines itérations lfs.dir, qui peuvent échouer silencieusement.
    local langs = {
        "Français", "English", "Español", "Deutsch", "Italiano", "Nederlands",
        "Português (Brésil)", "Português (Portugal)", "Русский", "中文",
        "日本語", "한국어", "Polski", "Türkçe", "Українська", "Čeština",
        "Dansk", "Ελληνικά", "Svenska", "Norsk", "Română"
    }
    for _, lang in ipairs(langs) do
        local safe = lang:gsub("[^%w]", "_")
        local path = dir .. "/" .. prefix .. safe
        seen[path] = true
        if os.remove(path) then n = n + 1 end
    end

    -- Et pour les langues ajoutées ultérieurement / anciennes variantes,
    -- tente aussi le parcours du dossier sans dépendre de son résultat.
    local ok, iter, dobj = pcall(lfs.dir, dir)
    if ok and iter then
        for name in iter, dobj do
            if name:sub(1, #prefix) == prefix then
                local path = dir .. "/" .. name
                if not seen[path] and os.remove(path) then n = n + 1 end
            end
        end
    end
    return n
end

-- Supprime TOUTES les traductions d'un roman en un seul parcours du dossier de
-- cache (au lieu d'un parcours complet par chapitre, qui gelait/plantait la
-- liseuse sur les gros romans). Renvoie le nombre de fichiers supprimés.
function Cache.removeNovelTranslations(source_id, novel_path)
    local prefix = (novel_key(source_id, novel_path)) .. "__"
    local names = {}
    local ok, iter, dobj = pcall(lfs.dir, content_dir)
    if not ok or not iter then return 0 end
    for name in iter, dobj do
        if name:sub(1, #prefix) == prefix and name:find("%.html%.tr_", 1, false) then
            names[#names + 1] = name
        end
    end
    local n = 0
    for _, name in ipairs(names) do
        if os.remove(content_dir .. "/" .. name) then n = n + 1 end
    end
    return n
end

-- ── Commentaires par paragraphe (cache hors-ligne) ──────────────────────────
-- Remplis par cache_chapter_comments() plus bas (au moment du téléchargement
-- d'un chapitre) ET, en secours, par readerview.lua lui-même après chaque
-- consultation en ligne réussie d'un fil de paragraphe (Cache.mergeParagraphComments) —
-- pour que même un chapitre non explicitement "téléchargé" (juste lu en
-- ligne) garde ses commentaires déjà vus disponibles hors-ligne ensuite.

local function read_comments_file(source_id, novel_path, chapter_path)
    local f = io.open(comments_path(source_id, novel_path, chapter_path), "r")
    if not f then return {} end
    local raw = f:read("*all"); f:close()
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" then return {} end
    return data
end

local function write_comments_file(source_id, novel_path, chapter_path, by_paragraph)
    ensure_dirs()
    local ok_enc, encoded = pcall(JSON.encode, by_paragraph)
    if not ok_enc then return false end
    local f = io.open(comments_path(source_id, novel_path, chapter_path), "w")
    if not f then return false end
    f:write(encoded)
    f:close()
    return true
end

-- Renvoie le fil déjà en cache pour CE paragraphe, ou nil si absent (jamais
-- téléchargé/consulté, ou fichier de cache manquant/corrompu).
function Cache.getParagraphComments(source_id, novel_path, chapter_path, paragraph_id)
    local data = read_comments_file(source_id, novel_path, chapter_path)
    return data[paragraph_id]
end

-- Remplace en bloc TOUS les fils de commentaires d'un chapitre (utilisé au
-- téléchargement, où on récupère tout d'un coup) — by_paragraph :
-- { [paragraph_id] = { comments... }, ... }.
function Cache.storeAllParagraphComments(source_id, novel_path, chapter_path, by_paragraph)
    return write_comments_file(source_id, novel_path, chapter_path, by_paragraph)
end

-- Ajoute/remplace le fil d'UN SEUL paragraphe sans toucher aux autres déjà en
-- cache pour ce chapitre (lecture en ligne au fil de l'eau, cf. plus haut).
function Cache.mergeParagraphComments(source_id, novel_path, chapter_path, paragraph_id, comments)
    local data = read_comments_file(source_id, novel_path, chapter_path)
    data[paragraph_id] = comments
    return write_comments_file(source_id, novel_path, chapter_path, data)
end

function Cache.getNovelEntry(source_id, novel_path)
    return get_entry(source_id, novel_path, false)
end

function Cache.getDownloadedCount(source_id, novel_path)
    local e = get_entry(source_id, novel_path, false)
    if not e then return 0 end
    local n = 0
    for _ in pairs(e.chapters) do n = n + 1 end
    return n
end

-- ── Write ─────────────────────────────────────────────────────────────────────

-- Note un chapitre comme téléchargé (le fichier HTML est déjà sur le disque).
local function register_chapter(source_id, novel_path, chapter, key)
    local e = get_entry(source_id, novel_path, true)
    e.chapters[key] = {
        title         = chapter.name or chapter.title,
        order         = chapter.chapter_number,
        downloaded_at = os.time(),
    }
    e.updated_at = os.time()
    schedule_save()
end

-- Stocke un chapitre déjà récupéré (html brut renvoyé par ext:parseChapter).
function Cache.storeChapter(source_id, novel_path, chapter, html)
    ensure_dirs()
    local key = ch_key(chapter)
    local f = io.open(content_path(source_id, novel_path, key), "w")
    if not f then return false, "write_error" end
    f:write(html)
    f:close()
    register_chapter(source_id, novel_path, chapter, key)
    return true
end

function Cache.removeNovel(source_id, novel_path)
    local e = get_entry(source_id, novel_path, false)
    if not e then return end
    for cp in pairs(e.chapters) do
        os.remove(content_path(source_id, novel_path, cp))
        os.remove(comments_path(source_id, novel_path, cp))
    end
    local data = load_summary()
    data.novels[novel_key(source_id, novel_path)] = nil
    save_summary()
end

-- Supprime du cache tous les chapitres téléchargés d'une source (HTML, commentaires, traductions),
-- en gardant les romans de la bibliothèque et la progression de lecture. Renvoie le nombre de chapitres.
function Cache.purgeSource(source_id)
    local data = load_summary()
    local n = 0
    for _, e in pairs(data.novels) do
        if e.source_id == source_id then
            for cp in pairs(e.chapters or {}) do
                os.remove(content_path(source_id, e.novel_path, cp))
                os.remove(comments_path(source_id, e.novel_path, cp))
                pcall(Cache.removeAllTranslations, source_id, e.novel_path, cp)
                n = n + 1
            end
            e.chapters = {}
        end
    end
    if n > 0 then save_summary() end
    return n
end

-- ── Progression de lecture ────────────────────────────────────────────────────

function Cache.setProgress(source_id, novel_path, chapter_path, percent, current_page, total_pages, completed, charpos, top_line_num)
    local e = get_entry(source_id, novel_path, true)
    e.progress_by_chapter = e.progress_by_chapter or {}
    local old = e.progress_by_chapter[chapter_path] or {}
    local value = {
        chapter_path = chapter_path,
        percent      = math.max(0, math.min(1, tonumber(percent) or 0)),
        current_page = math.max(1, tonumber(current_page) or tonumber(old.current_page) or 1),
        total_pages  = math.max(1, tonumber(total_pages) or tonumber(old.total_pages) or 1),
        completed    = completed ~= nil and (completed and true or false) or (old.completed and true or false),
        charpos      = tonumber(charpos) or tonumber(old.charpos) or nil,
        top_line_num = tonumber(top_line_num) or tonumber(old.top_line_num) or nil,
        updated_at   = os.time(),
    }
    -- On garde aussi le dernier chapitre lu dans `progress` pour les anciennes
    -- versions et pour la reprise générale du roman. La table par chapitre
    -- permet surtout d'afficher la progression de CHAQUE chapitre.
    e.progress = value
    e.progress_by_chapter[chapter_path] = value
    e.updated_at = os.time()
    schedule_save()
end

function Cache.getProgress(source_id, novel_path)
    local e = get_entry(source_id, novel_path, false)
    return e and e.progress or nil
end

function Cache.getChapterProgress(source_id, novel_path, chapter_path)
    local e = get_entry(source_id, novel_path, false)
    if not e then return nil end
    if e.progress_by_chapter and e.progress_by_chapter[chapter_path] then
        return e.progress_by_chapter[chapter_path]
    end
    -- Compatibilité avec les anciennes données : l'ancien format ne pouvait
    -- mémoriser qu'un seul chapitre.
    if e.progress and e.progress.chapter_path == chapter_path then
        return e.progress
    end
    return nil
end

-- ── Téléchargement réseau ─────────────────────────────────────────────────────
-- Réutilise exactement le même point d'entrée que core/epub.lua pour l'export
-- (ext:parseChapter), donc aucune extension existante n'a besoin d'être modifiée.

-- URL/identifiant source réellement transmis à l'extension pour récupérer un
-- chapitre. On rejette explicitement la chaîne vide : "" est truthy en Lua,
-- donc `chapter.path or chapter.sourceUrl` renvoyait "" (et jamais sourceUrl)
-- pour un chapitre mal formé dont `path` valait "", causant un échec de fetch
-- systématique sur ces chapitres-là.
local function ch_source_ref(chapter)
    local p = chapter.path
    if p == nil or p == "" then p = chapter.sourceUrl end
    if p == nil or p == "" then return nil end
    return p
end

-- Nombre de tentatives réseau avant d'abandonner un chapitre. Certains échecs
-- de téléchargement n'étaient dus qu'à un aléa réseau transitoire (timeout,
-- coupure Wi-Fi Kobo) : aucune tentative n'était rejouée auparavant, donc un
-- seul accroc suffisait à rendre un chapitre durablement "en échec".
local CHAPTER_FETCH_ATTEMPTS = 2

-- BUG CORRIGÉ (2026-09-12) : demandé — que les commentaires par paragraphe
-- soient disponibles HORS LIGNE pour les chapitres déjà téléchargés, sans
-- attendre d'être connecté au moment de taper sur chaque icône 💬. On
-- récupère donc ici, une fois le HTML du chapitre stocké, le fil COMPLET de
-- CHAQUE paragraphe commenté (`marks`, embarqué dans ce même HTML par
-- novelfrance.lua — cf. le trailer `<!--LNREADER_META:...-->`), et on les
-- range dans le cache séparé (Cache.storeAllParagraphComments ci-dessus).
-- `ext.parseParagraphComments` : n'existe que pour novelfrance.lua pour
-- l'instant — no-op silencieux pour toute autre source. pcall à chaque étape
-- (JSON, réseau) : un souci ici ne doit JAMAIS faire échouer le
-- téléchargement du chapitre lui-même, qui est déjà stocké avec succès à ce
-- stade — au pire, ce chapitre n'aura simplement pas ses commentaires en
-- cache (comme avant ce correctif), pas d'échec en cascade.
local function cache_chapter_comments(ext, source_id, novel_path, key, html)
    if not ext.parseParagraphComments then return end

    local ok_j, JSONc = pcall(require, "rapidjson")
    if not ok_j then JSONc = require("json") end

    local meta_json = html:match("<!%-%-LNREADER_META:(.-)%-%->")
    if not meta_json then return end
    local ok_dec, decoded = pcall(JSONc.decode, meta_json)
    if not ok_dec or type(decoded) ~= "table" or type(decoded.marks) ~= "table" or not decoded.chapterId then
        return
    end

    -- Plafonds : un chapitre populaire peut porter des centaines de paragraphes
    -- commentés, soit des centaines de requêtes réseau sérielles par chapitre.
    local MAX_MARKS, MAX_PAGES = 60, 5
    local by_paragraph = {}
    for mi, mark in ipairs(decoded.marks) do
        if mi > MAX_MARKS then break end
        if mark.id then
            local comments = {}
            local page, has_more, page_ok = 1, true, true
            while has_more and page <= MAX_PAGES do
                local ok_p, data = pcall(ext.parseParagraphComments, ext, decoded.chapterId, mark.id, page)
                if not ok_p then
                    page_ok = false
                    break
                end
                for _, c in ipairs((data and data.comments) or {}) do
                    table.insert(comments, c)
                end
                has_more = data and data.has_more or false
                page = page + 1
            end
            -- On ne stocke que si la récupération a réellement abouti (au
            -- moins une page sans erreur) — mieux vaut ne pas mettre ce
            -- paragraphe en cache que d'y écrire une liste tronquée par une
            -- panne réseau en cours de route, qui passerait ensuite pour
            -- "0 commentaire" alors qu'il en a.
            if page_ok then
                by_paragraph[mark.id] = comments
            end
        end
    end

    if next(by_paragraph) then
        pcall(Cache.storeAllParagraphComments, source_id, novel_path, key, by_paragraph)
    end

    -- pdp des commentaires de fin de chapitre (cf. chapterCommentMarks dans
    -- le trailer, ajouté par novelfrance.lua) : téléchargées et mises en
    -- cache disque ICI, dans le même contexte réseau que le reste de cette
    -- fonction (déjà appelée depuis Cache.downloadChapter, lui-même toujours
    -- dans un NetworkMgr:runWhenConnected côté appelant) — jamais au simple
    -- affichage d'un chapitre déjà en cache, pour ne jamais redéclencher de
    -- connexion Wi-Fi à l'improviste pendant la lecture hors-ligne.
    if type(decoded.chapterCommentMarks) == "table" and #decoded.chapterCommentMarks > 0 then
        local urls = {}
        for _, mark in ipairs(decoded.chapterCommentMarks) do
            if mark.avatar and mark.avatar ~= "" then
                table.insert(urls, mark.avatar)
            end
        end
        if #urls > 0 then
            pcall(Avatars.prefetch, urls)
        end
    end
end

-- `force` (optionnel) : si true, re-télécharge et écrase le cache même si le
-- chapitre est déjà présent, au lieu de renvoyer immédiatement on_done(true).
-- Sert à rafraîchir les avis/commentaires d'un chapitre déjà téléchargé,
-- qui sont embarqués dans le HTML renvoyé par ext:parseChapter — cf.
-- Detail.fetchForceRefresh (ui/detail.lua) qui appelle ceci avec force=true
-- pour tous les chapitres déjà en cache d'un roman quand on actualise ce
-- roman, afin de découvrir les nouveaux avis sans attendre que chaque
-- chapitre soit relu manuellement.
function Cache.downloadChapter(ext, source_id, novel_path, chapter, on_done, force)
    local key = ch_key(chapter)
    if not force and Cache.isChapterCached(source_id, novel_path, key) then
        return on_done(true)
    end
    local ref = ch_source_ref(chapter)
    if not ref then
        logger.warn("Sefirah/Cache: chapter has no path/sourceUrl, cannot fetch:", key)
        return on_done(false, "missing_chapter_reference")
    end

    local ok, html, parse_err, last_err
    for attempt = 1, CHAPTER_FETCH_ATTEMPTS do
        ok, html, parse_err = pcall(ext.parseChapter, ext, ref)
        if ok and html and html ~= "" then break end
        -- pcall renvoie (true, nil, "raison") quand parseChapter échoue
        -- proprement (return nil, "raison") plutôt que de lever une erreur :
        -- il faut donc regarder parse_err même si ok est vrai, sinon la
        -- vraie cause (ex. "chapter_content_not_found") est perdue et on
        -- affiche toujours le message générique "empty_response".
        last_err = (not ok) and html or (parse_err or "empty_response")
        logger.warn("Sefirah/Cache: fetch attempt", attempt, "failed for", key, ":", tostring(last_err))
    end
    if not ok or not html or html == "" then
        logger.warn("Sefirah/Cache: download failed for", key, "after", CHAPTER_FETCH_ATTEMPTS, "attempts:", tostring(last_err))
        return on_done(false, tostring(last_err))
    end
    local stored, err = Cache.storeChapter(source_id, novel_path, chapter, html)
    -- Commentaires hors ligne : désactivés par défaut (réglage « Commentaires
    -- hors ligne ») car ils multiplient le temps de téléchargement d'un chapitre.
    -- Sans eux, les commentaires restent consultables en ligne en tapant 💬.
    if stored then
        local ok_s, Settings = pcall(require, "sefirah_settings")
        if ok_s and Settings:get("offline_comments") then
            pcall(cache_chapter_comments, ext, source_id, novel_path, key, html)
        end
    end
    on_done(stored, err)
end

-- File d'attente (œuvre entière ou sélection).
-- Aucun délai artificiel entre deux chapitres. Quand c'est possible, plusieurs
-- chapitres sont téléchargés EN MÊME TEMPS (sous-processus, comme les couvertures) :
-- sur une liseuse, chaque requête HTTPS coûte surtout de la latence, donc 3 en
-- parallèle vont à peu près 3 fois plus vite. Sources fragiles (limitation de débit,
-- Cloudflare) : une seule à la fois. Commentaires hors ligne activés : séquentiel.
-- `force` : voir Cache.downloadChapter ci-dessus.
local PAR_WIDTH_DEFAULT = 5
-- novelfrance : un seul à la fois. Cinq sous-processus (fork de toute la liseuse, avec la
-- liste de milliers de chapitres en mémoire) faisaient tuer KOReader par manque de mémoire
-- (Kobo Clara) juste après l'actualisation d'un roman long comme Shadow Slave.
local PAR_WIDTH = { ao3 = 1, lightnovelvf = 1, mydramanovel = 2, wordrain = 2, wattpad = 2, novelfrance = 1 }
local PAR_JOB_TIMEOUT = 60      -- un chapitre trop lent est arrêté (puis réessayé en séquentiel)
local PAR_TOTAL_TIMEOUT = 600

-- Tâche exécutée DANS un sous-processus : télécharge un chapitre et l'écrit sur disque
-- (fichier .part puis renommage : jamais de chapitre tronqué). Le processus principal
-- (interface) n'attend donc jamais le réseau.
local function make_fetch_job(ext, ref, dest)
    return function()
        for _ = 1, CHAPTER_FETCH_ATTEMPTS do
            local ok, html = pcall(ext.parseChapter, ext, ref)
            if ok and type(html) == "string" and html ~= "" then
                local part = dest .. ".part"
                local f = io.open(part, "w")
                if f then
                    f:write(html)
                    f:close()
                    os.rename(part, dest)
                end
                return
            end
        end
    end
end

-- Version « arrière-plan » de Cache.downloadChapter : le téléchargement se fait dans un
-- sous-processus, l'interface reste utilisable (ex. préchargement du chapitre suivant
-- pendant la lecture). Repli sur la version synchrone si les sous-processus sont indisponibles.
function Cache.downloadChapterAsync(ext, source_id, novel_path, chapter, on_done)
    local key = ch_key(chapter)
    if Cache.isChapterCached(source_id, novel_path, key) then return on_done(true) end
    local ref = ch_source_ref(chapter)
    local ok_s, Settings = pcall(require, "sefirah_settings")
    local ok_p, Parallel = pcall(require, "core.parallel")
    if not ref or not ok_p or not Parallel.available()
       or (ok_s and Settings:get("offline_comments")) then
        return Cache.downloadChapter(ext, source_id, novel_path, chapter, on_done)
    end
    ensure_dirs()
    local dest   = content_path(source_id, novel_path, key)
    local before = lfs.attributes(dest, "modification")
    local function after()
        os.remove(dest .. ".part")
        local now = lfs.attributes(dest, "modification")
        if now and (before == nil or now > before) then
            register_chapter(source_id, novel_path, chapter, key)
            return on_done(true)
        end
        on_done(false, "download_failed")   -- pas de nouvel essai bloquant : l'appelant décide
    end
    if not Parallel.pool({ make_fetch_job(ext, ref, dest) }, 1, after,
            { job_timeout = PAR_JOB_TIMEOUT, timeout = PAR_JOB_TIMEOUT + 10 }) then
        return Cache.downloadChapter(ext, source_id, novel_path, chapter, on_done)
    end
end

-- Nombre de chapitres téléchargés en même temps pour une source (1 = séquentiel).
function Cache.parallelWidth(source_id)
    return PAR_WIDTH[source_id] or PAR_WIDTH_DEFAULT
end

function Cache.downloadChapters(ext, source_id, novel_path, chapters, on_progress, on_complete, force)
    local UIManager = require("ui/uimanager")
    local total = #chapters
    local i = 0

    local function report(ok, err)
        if on_progress then on_progress(i, total, ok, err) end
    end

    -- Repli / mode simple : un chapitre à la fois.
    local function step_seq()
        i = i + 1
        if i > total then flush_summary(); return on_complete() end
        Cache.downloadChapter(ext, source_id, novel_path, chapters[i], function(ok, err)
            report(ok, err)
            -- Laisser UIManager reprendre la main, sans imposer 20 ms de pause.
            UIManager:scheduleIn(0, step_seq)
        end, force)
    end

    local width = Cache.parallelWidth(source_id)
    local ok_s, Settings = pcall(require, "sefirah_settings")
    local offline_comments = ok_s and Settings:get("offline_comments")
    local ok_p, Parallel = pcall(require, "core.parallel")
    -- Même pour une source « une seule à la fois » (width = 1) ou un seul chapitre, le
    -- téléchargement passe par un sous-processus : sinon chaque requête bloquait toute
    -- l'interface de la liseuse pendant sa durée. Seul le mode « commentaires hors ligne »
    -- reste dans le processus principal.
    if offline_comments or not ok_p or not Parallel.available() then
        return step_seq()
    end
    width = math.max(1, width)

    local function step_par()
        if i >= total then flush_summary(); return on_complete() end

        local batch, need, before = {}, {}, {}
        -- Fenêtre glissante dans le lot : le lot ne sert qu'à enregistrer les chapitres reçus.
        for j = i + 1, math.min(total, i + width * 3) do batch[#batch + 1] = chapters[j] end
        local jobs, pooled = {}, false
        for _, ch in ipairs(batch) do
            local key = ch_key(ch)
            local ref = ch_source_ref(ch)
            if ref and (force or not Cache.isChapterCached(source_id, novel_path, key)) then
                local dest = content_path(source_id, novel_path, key)
                need[key] = true
                before[key] = lfs.attributes(dest, "modification")
                jobs[#jobs + 1] = make_fetch_job(ext, ref, dest)
            end
        end

        local function after_batch()
            for _, ch in ipairs(batch) do
                i = i + 1
                local key = ch_key(ch)
                local done_ok = false
                if need[key] then
                    local dest  = content_path(source_id, novel_path, key)
                    local after = lfs.attributes(dest, "modification")
                    os.remove(dest .. ".part")
                    if after and (before[key] == nil or after > before[key]) then
                        register_chapter(source_id, novel_path, ch, key)
                        done_ok = true
                    end
                end
                if done_ok then
                    report(true)
                elseif need[key] and pooled then
                    -- Échec dans le sous-processus (qui a déjà fait ses tentatives) : on le
                    -- signale sans relancer de requête bloquante dans l'interface.
                    report(false, "download_failed")
                else
                    -- Chapitre déjà en cache, sans référence, ou sous-processus indisponible :
                    -- le chemin simple s'en occupe (messages d'erreur).
                    Cache.downloadChapter(ext, source_id, novel_path, ch, function(ok, err)
                        report(ok, err)
                    end, force)
                end
            end
            UIManager:scheduleIn(0, step_par)
        end

        if #jobs == 0 then
            after_batch()   -- rien à télécharger dans ce lot
        elseif Parallel.pool(jobs, width, function() pooled = true; after_batch() end,
                { job_timeout = PAR_JOB_TIMEOUT, timeout = PAR_TOTAL_TIMEOUT }) then
            -- en cours en arrière-plan : after_batch est appelé à la fin
        else
            after_batch()   -- parallélisme indisponible : repli synchrone
        end
    end
    step_par()
end

return Cache
