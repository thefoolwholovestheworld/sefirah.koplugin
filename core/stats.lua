-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- core/stats.lua — alimente les statistiques GÉNÉRALES de KOReader avec le
-- temps et les pages lus dans le lecteur intégré (ui/readerview.lua).
--
-- Rien n'est affiché par ce module : il écrit dans settings/statistics.sqlite3,
-- la base du plugin Statistiques de KOReader, si bien que le temps passé sur
-- une web novel se retrouve dans l'écran « Statistiques » de la liseuse
-- (total, aujourd'hui, calendrier, moyenne par jour) comme pour un EPUB.
--
-- ── Performance (v2) ─────────────────────────────────────────────────────────
-- La v1 ouvrait la base, écrivait une ligne et la refermait à CHAQUE page
-- tournée, avec en prime un UPDATE contenant deux sous-requêtes d'agrégat.
-- Sur une Kobo (carte SD lente, journal WAL, fsync), cela ajoutait une latence
-- très visible à chaque tourne-page et pouvait bloquer sur un verrou quand le
-- plugin Statistiques écrivait en même temps. Cette version :
--   * garde UNE connexion ouverte (rouverte à la demande) avec busy_timeout,
--   * accumule les pages lues en mémoire et ne les écrit que par lots
--     (changement de chapitre, BUFFER_MAX lignes, ou fermeture du lecteur),
--     le tout dans une seule transaction,
--   * ne recalcule les totaux de la table `book` qu'à la fermeture,
--   * limite la pagination virtuelle à 20 pages par chapitre, ce qui garde
--     book.pages petit — la vue page_stat de KOReader duplique des lignes
--     proportionnellement à l'écart entre book.pages et total_pages, et c'est
--     ce qui rendait l'écran Statistiques lent à charger.
--
-- Schéma visé (KOReader, PRAGMA user_version=20221111) :
--   book(id, title, authors, notes, last_open, highlights, pages, series,
--        language, md5, total_read_time, total_read_pages)  UNIQUE(title,authors,md5)
--   page_stat_data(id_book, page, start_time, duration, total_pages)
--                                             UNIQUE(id_book, page, start_time)

local DataStorage = require("datastorage")
local logger      = require("logger")
local lfs         = require("libs/libkoreader-lfs")

local DB_PATH = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local PAGES_PER_CHAPTER = 20   -- bloc de pages virtuelles réservé à chaque chapitre
local MAX_SEC           = 120  -- plafond par page : évite de compter la liseuse en veille
local MIN_SEC           = 3    -- en deçà, page traversée sans être lue
local BUFFER_MAX        = 12   -- pages accumulées avant écriture d'un lot
local GROW_RATIO        = 1.10 -- book.pages n'est réécrit qu'au-delà de +10 % de chapitres

local Stats = {}

local session  = nil   -- { key, id_book, page, total_pages, start_ts }
local buffer   = {}    -- lignes page_stat_data en attente d'écriture
local book_ids = {}    -- cache clé_roman -> id_book
local conn     = nil
local disabled = false

-- ── Connexion ────────────────────────────────────────────────────────────────

local function get_conn()
    if disabled then return nil end
    if conn then return conn end

    if lfs.attributes(DB_PATH, "mode") ~= "file" then
        -- Base absente : le plugin Statistiques de KOReader n'a jamais tourné.
        -- On ne la crée pas (schéma et migrations lui appartiennent).
        logger.warn("Sefirah stats : statistics.sqlite3 absent, suivi désactivé")
        disabled = true
        return nil
    end

    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then
        logger.warn("Sefirah stats : SQLite indisponible")
        disabled = true
        return nil
    end

    local ok2, c = pcall(SQ3.open, DB_PATH)
    if not ok2 or not c then
        logger.warn("Sefirah stats : ouverture impossible", tostring(c))
        return nil
    end
    -- Le plugin Statistiques écrit dans la même base : sans busy_timeout, une
    -- écriture concurrente renvoie SQLITE_BUSY immédiatement.
    pcall(c.exec, c, "PRAGMA busy_timeout=3000;")
    pcall(c.exec, c, "PRAGMA synchronous=NORMAL;")
    conn = c
    return conn
end

local function close_conn()
    if conn then
        pcall(conn.close, conn)
        conn = nil
    end
end

-- ── Utilitaires ──────────────────────────────────────────────────────────────

local function hash(s)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.md5 then
        local ok2, digest = pcall(sha2.md5, s)
        if ok2 and digest then return digest end
    end
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 0x100000000 end
    return string.format("lnr%08x%08x", h, #s)
end

local function get_id_book(c, title, authors, md5, pages, language)
    local stmt = c:prepare("SELECT id, pages FROM book WHERE title = ? AND authors = ? AND md5 = ?;")
    local row  = stmt:reset():bind(title, authors, md5):step()
    stmt:close()

    if row and row[1] then
        local id  = tonumber(row[1])
        local cur = tonumber(row[2]) or 0
        -- Réécrit book.pages seulement si le roman a nettement grandi : chaque
        -- écart entre book.pages et le total_pages des anciennes lignes fait
        -- travailler la vue page_stat davantage.
        if cur == 0 or pages > cur * GROW_RATIO then
            local up = c:prepare("UPDATE book SET pages = ?, last_open = ? WHERE id = ?;")
            up:reset():bind(pages, os.time(), id):step()
            up:close()
            return id, pages
        end
        return id, cur
    end

    local ins = c:prepare("INSERT INTO book VALUES(NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
    ins:reset():bind(title, authors, 0, os.time(), 0, pages,
                     "N/A", language or "N/A", md5, 0, 0):step()
    ins:close()
    return tonumber(c:rowexec("SELECT last_insert_rowid();")), pages
end

-- ── Écriture par lots ────────────────────────────────────────────────────────

local function write_buffer()
    if #buffer == 0 then return end
    local c = get_conn()
    if not c then buffer = {} ; return end

    local rows = buffer
    buffer = {}

    local ok, err = pcall(function()
        c:exec("BEGIN;")
        local stmt = c:prepare([[
            INSERT OR IGNORE INTO page_stat_data
                (id_book, page, start_time, duration, total_pages)
            VALUES (?, ?, ?, ?, ?);
        ]])
        for _, r in ipairs(rows) do
            stmt:reset():bind(r[1], r[2], r[3], r[4], r[5]):step()
        end
        stmt:close()
        c:exec("COMMIT;")
    end)

    if not ok then
        pcall(c.exec, c, "ROLLBACK;")
        logger.warn("Sefirah stats : lot non écrit", tostring(err))
        close_conn()
    else
        logger.dbg("Sefirah stats :", #rows, "pages écrites")
    end
end

-- Range la page courante dans le tampon (aucune I/O ici).
local function buffer_session(now)
    if not session then return end
    local duration = (now or os.time()) - session.start_ts
    if duration < MIN_SEC then return end
    if duration > MAX_SEC then duration = MAX_SEC end
    buffer[#buffer + 1] = {
        session.id_book, session.page, session.start_ts, duration, session.total_pages,
    }
    if #buffer >= BUFFER_MAX then write_buffer() end
end

local function update_totals(id_book)
    local c = get_conn()
    if not c or not id_book then return end
    pcall(function()
        local up = c:prepare([[
            UPDATE book
            SET    last_open        = ?,
                   total_read_time  = (SELECT IFNULL(sum(duration), 0) FROM page_stat_data WHERE id_book = ?),
                   total_read_pages = (SELECT count(DISTINCT page)     FROM page_stat_data WHERE id_book = ?)
            WHERE  id = ?;
        ]])
        up:reset():bind(os.time(), id_book, id_book, id_book):step()
        up:close()
    end)
end

-- ── API publique ─────────────────────────────────────────────────────────────

--- Signale la page actuellement affichée.
-- Appelée à l'ouverture d'un chapitre et à chaque tourne-page. Si la page n'a
-- pas changé, l'appel ne fait rien : c'est le changement de page qui valide le
-- temps passé sur la précédente.
-- @param ctx table du lecteur (_ctx) : source_id, novel, chapters, index
-- @param page_in_chapter numéro de page dans le chapitre courant
function Stats.track(ctx, page_in_chapter)
    if disabled then return end
    local ok, err = pcall(function()
        if not ctx or not ctx.novel or not ctx.chapters then return end

        local novel     = ctx.novel
        local novel_key = tostring(ctx.source_id) .. ":" .. tostring(novel.path or novel.name or "?")
        local nb_chap   = math.max(1, #ctx.chapters)
        local wanted    = nb_chap * PAGES_PER_CHAPTER

        local index = math.max(1, tonumber(ctx.index) or 1)
        local p     = math.max(1, math.min(PAGES_PER_CHAPTER, tonumber(page_in_chapter) or 1))
        local page  = (index - 1) * PAGES_PER_CHAPTER + p

        local now = os.time()
        if session and session.key == novel_key and session.page == page then
            return -- même page : rien à faire
        end

        local chapter_changed = session and session.page
            and math.floor((session.page - 1) / PAGES_PER_CHAPTER) ~= (index - 1)

        buffer_session(now)

        local cached = book_ids[novel_key]
        if not cached then
            local c = get_conn()
            if not c then return end
            local ok2, id, pages = pcall(get_id_book, c,
                novel.name or "Web novel",
                novel.author or "N/A",
                hash("sefirah:" .. novel_key),
                wanted,
                novel.lang)
            if not ok2 or not id then
                logger.warn("Sefirah stats : id_book introuvable", tostring(id))
                return
            end
            cached = { id = id, pages = pages or wanted }
            book_ids[novel_key] = cached
        end

        session = {
            key         = novel_key,
            id_book     = cached.id,
            page        = page,
            -- total_pages DOIT rester aligné sur book.pages, sinon la vue
            -- page_stat duplique chaque ligne au prorata de l'écart.
            total_pages = cached.pages,
            start_ts    = now,
        }

        -- Un changement de chapitre est un bon moment pour vider le tampon :
        -- l'utilisateur attend déjà le chargement du chapitre suivant.
        if chapter_changed then write_buffer() end
    end)
    if not ok then
        logger.warn("Sefirah stats : track a échoué", tostring(err))
    end
end

--- Clôt la session (fermeture du lecteur) : vide le tampon et met à jour les
--- totaux de la table book, puis libère la connexion.
function Stats.stop()
    if disabled then return end
    local id_book = session and session.id_book
    buffer_session(os.time())
    session = nil
    write_buffer()
    if id_book then update_totals(id_book) end
    close_conn()
end

--- Vide le tampon sans clore la session (veille, sortie du plugin...).
function Stats.flush()
    if disabled then return end
    buffer_session(os.time())
    if session then session.start_ts = os.time() end
    write_buffer()
end

function Stats.reset()
    Stats.stop()
    book_ids = {}
end

return Stats
