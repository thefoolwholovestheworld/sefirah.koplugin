-- Sefirah: progression locale (XP, niveaux et quêtes) + classement communautaire optionnel.
-- Les données (core) sont ici ; l'écran « Centre de progression » est dans ui/progress.lua.
--
-- Quêtes : les objectifs quotidiens et hebdomadaires grandissent avec le niveau du joueur
-- (faciles au niveau 1, de plus en plus exigeants ensuite) ; le niveau pris en compte est figé
-- au début de la journée / de la semaine pour que les objectifs ne bougent pas en cours de route.
local Settings = require("sefirah_settings")
local T = require("core.i18n").T
local Quests = {}

local function today() return os.date("%Y-%m-%d") end
local function yesterday() return os.date("%Y-%m-%d", os.time() - 86400) end
local function week() return os.date("%Y-W%W") end
local function month() return os.date("%Y-%m") end
local function n(v) return tonumber(v) or 0 end

-- Règles anti-« farming » : une page n'est comptée que si elle a vraiment été lue.
local MIN_PAGE_SECS     = 15    -- page restée affichée moins de 15 s : survolée, rien n'est compté
local MAX_PAGE_SECS     = 300   -- au-delà de 5 min : pause / liseuse posée, rien n'est compté non plus
local MIN_MANGA_PAGE_SECS = 5   -- mangas : une page d'images se lit vite, seuil plus bas
local XP_PAGE, XP_CHAPTER = 5, 20              -- novels
local XP_PAGE_MANGA, XP_CHAPTER_MANGA = 2, 10  -- mangas (moins de lecture par page)
local MIN_CHAPTER_PAGES = 3     -- pages réellement lues pour qu'un chapitre soit « terminé »

local Progression = require("core.progression")
local RandomQuests = require("core.randomquests")
local level_of = Progression.level

local function count_true(t, key_only)
    local c = 0
    for _, v in pairs(type(t) == "table" and t or {}) do
        if key_only then if v then c = c + 1 end elseif n(v) > 0 then c = c + 1 end
    end
    return c
end

-- Créateur : reconnu automatiquement par le serveur (worker.js). Plus de succès : une marque à côté de son nom.
-- Le serveur répond « creator = true » à la synchro ; la liseuse mémorise le résultat dans
-- « leaderboard_is_creator ». CREATOR_IDS reste utilisable en secours (identifiant joueur local).
local CREATOR_IDS = { }
local CREATOR_NAME = "Elmyk"
local function is_creator()
    if Settings:get("leaderboard_is_creator") == true then return true end
    -- Pseudo « Elmyk » accepté par le serveur (pseudos uniques) : fonctionne même si le serveur est ancien.
    if Settings:get("leaderboard_username_synced") == CREATOR_NAME
        and Settings:get("leaderboard_username") == CREATOR_NAME then return true end
    local id = Settings:get("leaderboard_player_id")
    for _, v in ipairs(CREATOR_IDS) do if v == id then return true end end
    return false
end

local function data()
    local d = Settings:get("community_progress")
    if type(d) ~= "table" then
        d = { xp = 0, pages = 0, daily_date = today(), daily_pages = 0,
              week_key = week(), weekly_pages = 0, last_position = "", last_chapter = "", pending_xp = 0 }
    end
    return d
end
local function save(d) Settings:set("community_progress", d) end

-- Remet à zéro les compteurs du jour / de la semaine quand la date change, et fige le niveau de référence.
-- Retourne d, rolled (rolled = quelque chose a changé : l'appelant peut sauvegarder).
local function roll(d)
    local date, wk = today(), week()
    local rolled = false
    if d.daily_date ~= date then
        d.daily_date, d.daily_pages, d.daily_chapters, d.daily_seconds = date, 0, 0, 0
        d.daily_new, d.daily_open, d.daily_titles = 0, false, {}
        d.daily_level = level_of(d.xp)
        rolled = true
    end
    if d.week_key ~= wk then
        d.week_key, d.weekly_pages, d.weekly_chapters, d.weekly_days = wk, 0, 0, 0
        d.weekly_seconds, d.weekly_new = 0, 0
        d.week_level = level_of(d.xp)
        rolled = true
    end
    local mo = month()
    if d.month_key ~= mo then   -- nouveau mois : les quêtes « Long terme » repartent de zéro
        d.month_key, d.monthly_pages, d.monthly_chapters, d.monthly_days = mo, 0, 0, 0
        d.monthly_seconds, d.monthly_new = 0, 0
        rolled = true
    end
    if type(d.daily_titles) ~= "table" then d.daily_titles = {}; rolled = true end
    if not d.daily_level then d.daily_level = level_of(d.xp); rolled = true end
    if not d.week_level then d.week_level = level_of(d.xp); rolled = true end
    if d.progression_version ~= 2 then
        d.progression_version = 2
        d.daily_level, d.week_level = level_of(d.xp), level_of(d.xp)
        rolled = true
    end
    if RandomQuests.ensure(d) then rolled = true end
    return d, rolled
end

-- Compteurs « à plat » utilisés par les quêtes et par l'écran.
local function counters(d)
    local streak = n(d.streak)
    if d.last_read_date ~= today() and d.last_read_date ~= yesterday() then streak = 0 end
    local best = 0
    for _, c in pairs(d.daily_titles or {}) do if n(c) > best then best = n(c) end end
    local extra = {}
    return {
        extra = extra,
        novels_done = n(d.novels_done), novels_fast = n(d.novels_fast),
        best_day_chapters = math.max(n(d.best_day_chapters), n(d.daily_chapters)),
        best_week_chapters = math.max(n(d.best_week_chapters), n(d.weekly_chapters)),
        pages = n(d.pages), chapters = n(d.chapters), streak = streak,
        best_streak = math.max(n(d.best_streak), streak),
        daily_pages = n(d.daily_pages), weekly_pages = n(d.weekly_pages),
        daily_chapters = n(d.daily_chapters), weekly_chapters = n(d.weekly_chapters),
        daily_minutes = math.floor(n(d.daily_seconds) / 60),
        weekly_minutes = math.floor(n(d.weekly_seconds) / 60),
        total_minutes = math.floor(n(d.total_seconds) / 60),
        daily_new = n(d.daily_new), weekly_new = n(d.weekly_new), daily_open = d.daily_open and 1 or 0,
        daily_best = best, daily_titles_n = count_true(d.daily_titles), weekly_days = n(d.weekly_days),
        titles = count_true(d.seen, true), level = level_of(d.xp),
        monthly_pages = n(d.monthly_pages), monthly_chapters = n(d.monthly_chapters),
        monthly_minutes = math.floor(n(d.monthly_seconds) / 60), monthly_days = n(d.monthly_days),
        monthly_new = n(d.monthly_new),
    }
end

-- ── Difficulté progressive ──────────────────────────────────────────────────
-- ramp(base, pas, plafond, niveau) : objectif de départ + pas par niveau, plafonné.
local function ramp(base, step, cap, level)
    local v = math.min(cap, base + step * (level - 1))
    v = math.floor(v + 0.5)
    if v >= 25 then v = 5 * math.floor(v / 5 + 0.5) end   -- chiffres ronds pour les grands objectifs
    return math.max(base, v)
end
-- Récompense : +8 % par niveau, jusqu'à ×3.
local function reward(base, level) return math.floor(base * math.min(3, 1 + 0.08 * (level - 1)) + 0.5) end
local function lvl(v) return math.max(1, math.floor(n(v))) end
local function s(k) return k > 1 and "s" or "" end

-- Quêtes « Long terme » : 20 objectifs qui se renouvellent CHAQUE MOIS (progression remise à zéro
-- au changement de mois, XP de nouveau gagnable). Paliers fixes, indépendants du niveau.
-- { id, icône, titre (catégorie), description (modèle), XP, compteur, objectif, nombre affiché }
local LONG = {
    { "mo_p50", "book", "Pages du mois", "Valider %d pages ce mois-ci", 30, "monthly_pages", 50 },
    { "mo_p150", "book", "Pages du mois", "Valider %d pages ce mois-ci", 60, "monthly_pages", 150 },
    { "mo_p300", "book", "Pages du mois", "Valider %d pages ce mois-ci", 100, "monthly_pages", 300 },
    { "mo_p600", "book", "Pages du mois", "Valider %d pages ce mois-ci", 180, "monthly_pages", 600 },
    { "mo_p1000", "book", "Pages du mois", "Valider %d pages ce mois-ci", 300, "monthly_pages", 1000 },
    { "mo_p1500", "book", "Pages du mois", "Valider %d pages ce mois-ci", 450, "monthly_pages", 1500 },
    { "mo_c5", "doc", "Chapitres du mois", "Terminer %d chapitres ce mois-ci", 40, "monthly_chapters", 5 },
    { "mo_c15", "doc", "Chapitres du mois", "Terminer %d chapitres ce mois-ci", 90, "monthly_chapters", 15 },
    { "mo_c30", "doc", "Chapitres du mois", "Terminer %d chapitres ce mois-ci", 160, "monthly_chapters", 30 },
    { "mo_c60", "doc", "Chapitres du mois", "Terminer %d chapitres ce mois-ci", 280, "monthly_chapters", 60 },
    { "mo_c100", "doc", "Chapitres du mois", "Terminer %d chapitres ce mois-ci", 450, "monthly_chapters", 100 },
    { "mo_m120", "clock", "Temps du mois", "Lire %d heures ce mois-ci", 40, "monthly_minutes", 120, 2 },
    { "mo_m600", "clock", "Temps du mois", "Lire %d heures ce mois-ci", 150, "monthly_minutes", 600, 10 },
    { "mo_m1200", "clock", "Temps du mois", "Lire %d heures ce mois-ci", 280, "monthly_minutes", 1200, 20 },
    { "mo_m2400", "clock", "Temps du mois", "Lire %d heures ce mois-ci", 500, "monthly_minutes", 2400, 40 },
    { "mo_d7", "flame", "Jours de lecture", "Lire %d jours différents ce mois-ci", 70, "monthly_days", 7 },
    { "mo_d15", "flame", "Jours de lecture", "Lire %d jours différents ce mois-ci", 150, "monthly_days", 15 },
    { "mo_d25", "flame", "Jours de lecture", "Lire %d jours différents ce mois-ci", 300, "monthly_days", 25 },
    { "mo_n2", "star", "Découvertes du mois", "Découvrir %d nouveaux titres ce mois-ci", 50, "monthly_new", 2 },
    { "mo_n5", "star", "Découvertes du mois", "Découvrir %d nouveaux titres ce mois-ci", 140, "monthly_new", 5 },
}

-- ── Succès ──────────────────────────────────────────────────────────────────
-- Faciles, Moyens et Difficiles rapportent de l'XP (les Difficiles beaucoup). Titres et descriptions sont
-- des modèles traduisibles : « %d » reçoit le nombre affiché (par défaut l'objectif).
-- { id, niveau, icône, titre, description, XP, compteur, objectif, nombre affiché }
local ACH = {
    { "a_p100", "easy", "book",     "%d pages",              "Valider %d pages",            40,  "pages",         100 },
    { "a_c10",  "easy", "doc",      "%d chapitres",          "Terminer %d chapitres",       50,  "chapters",      10 },
    { "a_t5",   "easy", "star",     "%d histoires",          "Lire %d titres différents",   60,  "titles",        5 },
    { "a_s7",   "easy", "flame",    "%d jours de suite",     "Lire %d jours d'affilée",     80,  "best_streak",   7 },
    { "a_h2",   "easy", "clock",    "%d heures de lecture",  "Lire %d heures au total",     80,  "total_minutes", 120, 2 },
    { "a_lv4",  "easy", "calendar", "Niveau %d",             "Atteindre le niveau %d",      60,  "level",         4 },
    { "a_c25",  "easy", "doc",      "%d chapitres",          "Terminer %d chapitres",       100, "chapters",      25 },
    { "a_p500", "easy", "book",     "%d pages",              "Valider %d pages",            120, "pages",         500 },
    { "a_t8",   "easy", "star",     "%d histoires",          "Lire %d titres différents",   90,  "titles",        8 },
    { "a_h5",   "easy", "clock",    "%d heures de lecture",  "Lire %d heures au total",     110, "total_minutes", 300, 5 },

    { "m_p1000","medium", "book",   "%d pages",              "Valider %d pages",            200, "pages",         1000 },
    { "m_c100", "medium", "doc",    "%d chapitres",          "Terminer %d chapitres",       250, "chapters",      100 },
    { "m_t15",  "medium", "star",   "%d histoires",          "Lire %d titres différents",   250, "titles",        15 },
    { "m_s30",  "medium", "flame",  "%d jours de suite",     "Lire %d jours d'affilée",     400, "best_streak",   30 },
    { "m_h20",  "medium", "clock",  "%d heures de lecture",  "Lire %d heures au total",     350, "total_minutes", 1200, 20 },
    { "m_lv12", "medium", "calendar","Niveau %d",            "Atteindre le niveau %d",      400, "level",         12 },
    { "m_p3000","medium", "book",   "%d pages",              "Valider %d pages",            500, "pages",         3000 },
    { "m_c300", "medium", "doc",    "%d chapitres",          "Terminer %d chapitres",       600, "chapters",      300 },
    { "m_t25",  "medium", "star",   "%d histoires",          "Lire %d titres différents",   400, "titles",        25 },
    { "m_s14",  "medium", "flame",  "%d jours de suite",     "Lire %d jours d'affilée",     300, "best_streak",   14 },

    { "h_novel7",  "hard", "flame", "Novel en une semaine",  "Finir un novel complet (20 chapitres min.) en 7 jours", 2000, "novels_fast", 1 },
    { "h_novel7x3","hard", "flame", "Dévoreur de novels",    "Finir %d novels complets, chacun en 7 jours max",       4000, "novels_fast", 3 },
    { "h_novel10", "hard", "book",  "Bibliothécaire",        "Finir %d novels complets",                              4000, "novels_done", 10 },
    { "h_day50",   "hard", "doc",   "Journée infernale",     "%d chapitres terminés en un jour",                      2000, "best_day_chapters", 50 },
    { "h_week100", "hard", "doc",   "Sprint de 100 chapitres","%d chapitres terminés en une semaine",                 1500, "best_week_chapters", 100 },
    { "h_streak60","hard", "flame", "%d jours de suite",     "Lire %d jours d'affilée",                               3000, "best_streak", 60 },
    { "h_h100",    "hard", "clock", "%d heures de lecture",  "Lire %d heures au total",                               3000, "total_minutes", 6000, 100 },
    { "h_c1000",   "hard", "doc",   "%d chapitres",          "Terminer %d chapitres",                                 4000, "chapters", 1000 },
    { "h_p10000",  "hard", "book",  "%d pages",              "Valider %d pages",                                      4000, "pages", 10000 },
    { "h_t100",    "hard", "star",  "%d histoires",          "Lire %d titres différents",                             3500, "titles", 100 },
}

-- Traduit un modèle puis y insère le nombre (« %d »), s'il y en a un.
local function tpl(key, num)
    local t = T(key)
    if t:find("%%d") then return t:format(num) end
    return t
end
local ROMAN = { "I", "II", "III", "IV", "V", "VI" }

-- Définition des quêtes. period : "daily" | "weekly" | "long".
local function defs(c, dlev, wlev, seed)
    local function q(period, id, icon, title, desc, xp, cur, goal)
        return { period = period, id = id, icon = icon, title = title, desc = desc, xp = xp,
                 cur = math.min(cur, goal), goal = goal, done = cur >= goal }
    end

    -- 4 quêtes par période, tirées dans des familles variées ; tirage figé jusqu'au renouvellement.
    local daily, weekly = RandomQuests.build(c, dlev, wlev, seed)

    local long = {}
    local rank_in = {}
    for _, m in ipairs(LONG) do
        rank_in[m[3]] = (rank_in[m[3]] or 0) + 1
        local num = m[8] or m[7]
        long[#long + 1] = q("long", m[1], m[2], T(m[3]) .. " " .. (ROMAN[rank_in[m[3]]] or tostring(rank_in[m[3]])),
            tpl(m[4], num), m[5], c[m[6]], m[7])
    end
    local achv = { easy = {}, medium = {}, hard = {} }
    for _, m in ipairs(ACH) do
      do
        local num = m[9] or m[8]
        local a = q("achv", m[1], m[3], tpl(m[4], num), tpl(m[5], num), m[6], (c[m[7]] or c.extra[m[7]] or 0), m[8])
        a.tier, a.novel, a.badge = m[2], nil, false
        achv[m[2]][#achv[m[2]] + 1] = a
      end
    end
    return { daily = daily, weekly = weekly, long = long, achv = achv }
end

local function all_defs(d)
    return defs(counters(d), lvl(d.daily_level), lvl(d.week_level), d)
end

local function period_key(period)
    if period == "daily" then return today() end
    if period == "weekly" then return week() end
    if period == "achv" then return "A" end
    return "M" .. month()   -- « long » : renouvelé chaque mois
end

-- Accorde (une seule fois par période) l'XP bonus des quêtes terminées.
-- Retourne la liste des quêtes qui viennent d'être validées.
local function check_rewards(d)
    if type(d.claimed) ~= "table" then d.claimed = {} end
    local date, wk, mo = today(), week(), "M" .. month()
    for k in pairs(d.claimed) do
        local per = tostring(k):match("^(.-)|")
        if per ~= mo and per ~= "A" and per ~= date and per ~= wk then d.claimed[k] = nil end
    end
    local all = all_defs(d)
    local fresh = {}
    local groups = { all.daily, all.weekly, all.long, all.achv.easy, all.achv.medium, all.achv.hard }
    for _, list in ipairs(groups) do
        for _, q in ipairs(list) do
            local key = period_key(q.period) .. "|" .. q.id
            if q.done and not d.claimed[key] then
                d.claimed[key] = true
                d.xp = n(d.xp) + q.xp
                d.pending_xp = math.max(0, n(d.pending_xp)) + q.xp
                fresh[#fresh + 1] = q
            end
        end
    end
    return fresh
end

-- Petit message discret quand une quête est terminée ou qu'un niveau est franchi.
local function announce(fresh, level_before, level_after)
    if not Settings:get("quest_notifications") then return end
    local lines = {}
    for i, q in ipairs(fresh) do
        if i > 3 then lines[#lines + 1] = ((#fresh - 3) > 1 and T("+ %d autres quêtes") or T("+ %d autre quête")):format(#fresh - 3); break end
        if q.badge then lines[#lines + 1] = T("Badge débloqué : %s"):format(q.title)
        elseif q.period == "achv" then lines[#lines + 1] = T("Succès débloqué : %s (+%d XP)"):format(q.title, q.xp)
        else lines[#lines + 1] = T("Quête terminée : %s (+%d XP)"):format(q.title, q.xp) end
    end
    if level_after > level_before then lines[#lines + 1] = T("Niveau %d atteint !"):format(level_after) end
    if #lines == 0 then return end
    pcall(function()
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n"), timeout = 3 })
    end)
end

function Quests.track(ctx, page, completed, total, kind)
    local manga = (kind == "manga")
    if not ctx or not ctx.novel or not ctx.chapters then return end
    local d = roll(data())
    local date = today()
    local novel = ctx.novel
    local novel_key = tostring(ctx.source_id or "?") .. ":" .. tostring(novel.path or novel.name or "?")
    local index = math.max(1, tonumber(ctx.index) or 1)
    -- Sens de lecture de la liste : 1 (chapitres croissants) ou -1 (liste affichée du plus récent au plus ancien,
    -- comme NovelFrance). Sans ceci, « avancer » dans une liste décroissante n'était jamais compté.
    local step = (tonumber(ctx.step) or 1) < 0 and -1 or 1
    local p = math.max(1, tonumber(page) or 1)
    local position = novel_key .. ":" .. index .. ":" .. p
    if position == d.last_position then
        -- Reprise sur la même page qu'avant : on démarre simplement le chronomètre.
        if n(d.last_ts) == 0 then d.last_ts = os.time(); save(d) end
        return
    end

    -- Temps passé sur la page précédente. Une page ne compte (XP, pages, minutes, chapitre)
    -- que si elle est restée affichée entre MIN_PAGE_SECS et MAX_PAGE_SECS : feuilleter
    -- vite ou laisser la liseuse allumée ne rapporte plus rien.
    local now = os.time()
    local last_ts = n(d.last_ts)
    local dt = (last_ts > 0 and now >= last_ts) and (now - last_ts) or 0
    local valid = dt >= (manga and MIN_MANGA_PAGE_SECS or MIN_PAGE_SECS) and dt <= MAX_PAGE_SECS
    d.last_ts = now

    -- N'accorde des points qu'en avançant dans la lecture, pour limiter le farming en arrière.
    local chapter_key = novel_key .. ":" .. index
    local level_before = level_of(d.xp)
    local before_xp = n(d.xp)
    local same_novel = d.last_novel == novel_key
    local forward = same_novel and ((index - n(d.last_index)) * step > 0
        or (index == n(d.last_index) and p > n(d.last_page)))
    local chapter_changed = d.last_chapter ~= chapter_key

    if forward and valid then
        d.xp = n(d.xp) + (manga and XP_PAGE_MANGA or XP_PAGE)
        d.pages = n(d.pages) + 1
        d.daily_pages = n(d.daily_pages) + 1
        d.weekly_pages = n(d.weekly_pages) + 1
        d.monthly_pages = n(d.monthly_pages) + 1
        d.daily_seconds = n(d.daily_seconds) + dt
        d.weekly_seconds = n(d.weekly_seconds) + dt
        d.monthly_seconds = n(d.monthly_seconds) + dt
        d.total_seconds = n(d.total_seconds) + dt
        d.chap_pages = n(d.chap_pages) + 1
        d.daily_titles[novel_key] = n(d.daily_titles[novel_key]) + 1
        -- Titre jamais lu auparavant : compté à la première vraie page lue, pas à l'ouverture.
        if type(d.seen) ~= "table" then d.seen = {} end
        if not d.seen[novel_key] then
            d.seen[novel_key] = true
            d.daily_new = n(d.daily_new) + 1
            d.weekly_new = n(d.weekly_new) + 1
            d.monthly_new = n(d.monthly_new) + 1
        end
        if d.last_read_date ~= date then
            d.streak = (d.last_read_date == yesterday()) and (n(d.streak) + 1) or 1
            d.last_read_date = date
            d.weekly_days = n(d.weekly_days) + 1
            d.monthly_days = n(d.monthly_days) + 1
        end
        d.best_streak = math.max(n(d.best_streak), n(d.streak))
    end

    -- Chapitre terminé : compté une seule fois par chapitre (d.counted), soit en ARRIVANT sur sa dernière page
    -- (c'est aussi ce qui affiche le ✓ dans la liste), soit en le QUITTANT depuis sa dernière page (chapitres
    -- très courts). Il faut y avoir réellement lu quelques pages (pas juste feuilleté).
    if type(d.counted) ~= "table" then d.counted = {} end
    local function count_chapter(key, nk, nchap)
        if d.counted[key] then return end
        d.counted[key] = true
        d.xp = n(d.xp) + (manga and XP_CHAPTER_MANGA or XP_CHAPTER)
        d.chapters = n(d.chapters) + 1
        d.daily_chapters = n(d.daily_chapters) + 1
        d.weekly_chapters = n(d.weekly_chapters) + 1
        d.monthly_chapters = n(d.monthly_chapters) + 1
        d.best_day_chapters = math.max(n(d.best_day_chapters), d.daily_chapters)
        d.best_week_chapters = math.max(n(d.best_week_chapters), d.weekly_chapters)
        d.counted_n = n(d.counted_n) + 1
        if d.counted_n > 6000 then d.counted, d.counted_n = { [key] = true }, 1 end   -- garde-fou de taille
        -- Suivi par novel : un novel est « complet » quand 100 % de ses chapitres (20 minimum) sont terminés ;
        -- « en 7 jours » = entre le 1er chapitre compté et le dernier.
        if nk and nchap and nchap >= 20 then
            if type(d.novel_prog) ~= "table" then d.novel_prog = {} end
            local np = d.novel_prog[nk]
            if not np then np = { first = os.time(), n = 0 }; d.novel_prog[nk] = np end
            np.n = n(np.n) + 1
            if not np.done and np.n >= nchap then
                np.done = true
                d.novels_done = n(d.novels_done) + 1
                if os.time() - n(np.first) <= 7 * 86400 then d.novels_fast = n(d.novels_fast) + 1 end
            end
            local cnt = 0
            for _ in pairs(d.novel_prog) do cnt = cnt + 1 end
            if cnt > 80 then   -- garde-fou : on oublie d'abord les novels déjà terminés
                for k, v in pairs(d.novel_prog) do if v.done and k ~= nk then d.novel_prog[k] = nil; cnt = cnt - 1; if cnt <= 60 then break end end end
            end
        end
    end
    local nchap_now = type(ctx.chapters) == "table" and #ctx.chapters or 0
    local total_pages = math.max(1, math.floor(tonumber(total) or 1))
    local need = math.min(MIN_CHAPTER_PAGES, math.max(0, total_pages - 1))
    if chapter_changed and d.last_chapter ~= "" and d.last_completed and valid
        and n(d.chap_pages) >= n(d.last_need) then
        count_chapter(d.last_chapter, same_novel and novel_key or nil, nchap_now)
    end
    if chapter_changed then d.chap_pages = 0 end
    if completed and total_pages >= 2 and n(d.chap_pages) >= need then
        count_chapter(chapter_key, novel_key, nchap_now)
    end
    d.last_completed, d.last_need = completed and true or false, need

    -- XP de lecture (les bonus de quêtes ajoutent leur propre part à pending_xp).
    local earned = math.max(0, n(d.xp) - before_xp)
    d.pending_xp = math.max(0, n(d.pending_xp)) + earned
    local fresh = (earned > 0 or chapter_changed) and check_rewards(d) or {}
    d.last_position, d.last_novel = position, novel_key
    d.last_index, d.last_page = index, p
    d.last_chapter = chapter_key
    save(d)
    announce(fresh, level_before, level_of(d.xp))
    -- Envoi discret des XP au serveur communautaire (au plus toutes les 5 min, si déjà en ligne).
    if chapter_changed then pcall(function() require("core.leaderboard").backgroundSync() end) end
end

-- « Retour quotidien » : appelé à l'ouverture de Sefirah.
function Quests.touch()
    local d = roll(data())
    d.last_ts = 0     -- le temps passé hors lecture (menus, recherche…) ne compte jamais
    if not d.daily_open then
        d.daily_open = true
        check_rewards(d)
    end
    save(d)
end

function Quests.getProgress()
    local d, rolled = roll(data())
    if rolled then save(d) end
    local c = counters(d)
    local xp = math.max(0, n(d.xp))
    local level, into_level, next_level = Progression.progress(xp)
    c.xp, c.level, c.into_level, c.next_level = xp, level, into_level, next_level
    return c
end

-- { daily = {...}, weekly = {...}, long = {...} }
function Quests.getQuests()
    local d, rolled = roll(data())
    if rolled then save(d) end
    return all_defs(d)
end

function Quests.getAchievements()
    local d, rolled = roll(data())
    if rolled then save(d) end
    return all_defs(d).achv
end

-- Remet à zéro XP, niveau, quêtes, pages, chapitres et séries de CET appareil.
-- On garde ce qui évite de casser l'envoi au classement : le compteur de lots (identifiants d'événements
-- uniques côté serveur) et les consultations d'œuvres en attente. Les XP pas encore envoyées sont abandonnées.
function Quests.reset()
    local old = Settings:get("community_progress")
    local fresh = {}
    if type(old) == "table" then
        fresh.batch_counter = old.batch_counter
        fresh.pending_work_events = old.pending_work_events
        fresh.last_work_seen = old.last_work_seen
    end
    fresh.xp, fresh.pending_xp = 0, 0
    Settings:set("community_progress", fresh)
    Settings:set("leaderboard_reset_pending", true)   -- le classement en ligne est remis à zéro à la prochaine synchro
    local d = roll(data())
    save(d)
    return true
end

function Quests.show()
    require("ui.progress").show()
end

-- Le créateur est reconnu (serveur ou pseudo confirmé) : sert à afficher sa marque à côté de son nom.
function Quests.isCreator() return is_creator() end

return Quests
