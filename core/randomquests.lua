-- Tirages locaux persistants ; aucun reseed global de math.random.
local T = require("core.i18n").T
local RandomQuests = {}
local MOD = 2147483647
local function hash(text)
    local value = 1
    for i = 1, #text do value = (value * 131.0 + text:byte(i)) % MOD end
    return math.max(1, value)
end
local function rng(seed)
    local value = math.max(1, tonumber(seed) or 1) % MOD
    return function(lo, hi)
        value = (value * 16807.0) % MOD
        return lo + value % (hi - lo + 1)
    end
end
function RandomQuests.ensure(d)
    local changed = false
    if not d.quest_salt then
        d.quest_salt = tostring(os.time()) .. ":" .. tostring(math.random(1, 1000000))
        changed = true
    end
    for _, entry in ipairs({ { "daily", d.daily_date }, { "weekly", d.week_key } }) do
        local prefix, key = entry[1], tostring(entry[2])
        if d[prefix .. "_quest_key"] ~= key or not d[prefix .. "_quest_seed"] then
            d[prefix .. "_quest_key"] = key
            d[prefix .. "_quest_seed"] = hash(d.quest_salt .. ":" .. prefix .. ":" .. key)
            changed = true
        end
    end
    return changed
end
local function shuffle(list, rand)
    for i = #list, 2, -1 do
        local j = rand(1, i)
        list[i], list[j] = list[j], list[i]
    end
end
-- Quêtes du jour / de la semaine : 10 par période, réparties sur 5 paliers de difficulté
-- (25, 50, 100, 200, 500 XP). Plus le niveau monte, plus les paliers difficiles sont nombreux
-- et plus les objectifs grandissent. Pages et minutes : toujours des multiples de 5.
local XP_TIERS = { 25, 50, 100, 200, 500 }

-- Paliers (1 à 5) des 10 quêtes selon le niveau, triés du plus facile au plus difficile.
-- Avec 5 familles, chaque famille reçoit 2 quêtes de paliers toujours différents.
local function tiers_for(level)
    if level < 5 then return { 1, 1, 1, 2, 2, 2, 3, 3, 3, 4 } end
    if level < 10 then return { 1, 1, 2, 2, 3, 3, 3, 4, 4, 5 } end
    if level < 20 then return { 1, 2, 2, 3, 3, 4, 4, 4, 5, 5 } end
    return { 2, 2, 3, 3, 4, 4, 5, 5, 5, 5 }
end

local function round5(v) return math.max(5, 5 * math.floor(v / 5 + 0.5)) end

local function make(period, c, level, seed)
    local rand = rng(seed)
    local daily = period == "daily"
    local p = daily and "daily_" or "weekly_"
    local L = math.max(1, tonumber(level) or 1)
    local lf = math.min(2.5, 1 + 0.08 * (L - 1))   -- facteur de niveau sur les objectifs

    -- Objectifs des 5 paliers d'une famille : strictement croissants, multiples de 5 si `five`.
    local function goals(base, mults, cap, five, minimum, scaled)
        local out, prev = {}, 0
        for i = 1, 5 do
            local v = base * mults[i] * (scaled == false and 1 or lf)
            v = math.min(cap, v)
            v = five and round5(v) or math.max(1, math.floor(v + 0.5))
            v = math.max(v, minimum or 1, prev + (five and 5 or 1))
            out[i], prev = v, v
        end
        return out
    end

    local families = {}
    local function family(key, icon, titles, metric, goal_list, description, singular)
        families[#families + 1] = { key = key, icon = icon, titles = titles, metric = metric,
            goals = goal_list, desc = description, singular = singular }
    end
    local PAGE_M = { 0.4, 0.7, 1, 1.6, 2.4 }
    if daily then
        family("chapters", "doc", { "Une histoire avance", "Au prochain chapitre", "Chapitres à la chaîne", "Soif d'histoires", "Marathon de chapitres" },
            "daily_chapters", goals(2, { 1, 1.5, 2, 3, 4.5 }, 25, false, 2), "Terminer %d chapitres aujourd'hui")
        family("pages", "book", { "Une bonne séance", "Voyage entre les lignes", "Le défi des pages", "Dévoreur de pages", "Journée de lecture" },
            "daily_pages", goals(25, PAGE_M, 300, true), "Lire %d pages aujourd'hui")
        family("time", "clock", { "Une vraie pause lecture", "Du temps pour soi", "Immersion prolongée", "Plongée profonde", "Journée immergée" },
            "daily_minutes", goals(20, { 0.5, 0.75, 1, 1.75, 2.75 }, 150, true), "Lire pendant %d minutes aujourd'hui")
        family("focus", "flame", { "Une histoire captivante", "Au cœur d'un récit", "Impossible de décrocher", "Fidèle à un récit", "Dévoré d'une traite" },
            "daily_best", goals(20, PAGE_M, 250, true), "Lire %d pages dans un même titre aujourd'hui")
        family("new", "star", { "À la découverte", "Nouveaux horizons", "Explorateur d'histoires", "Grand explorateur", "Chasseur de pépites" },
            "daily_new", goals(1, { 1, 2, 3, 4, 5 }, 5, false, 1, false), "Commencer %d nouveaux titres aujourd'hui",
            "Commencer %d nouveau titre aujourd'hui")
    else
        family("chapters", "doc", { "Une histoire avance", "Au prochain chapitre", "Chapitres à la chaîne", "Soif d'histoires", "Marathon de chapitres" },
            "weekly_chapters", goals(8, { 0.5, 0.75, 1, 1.5, 2.2 }, 60, false, 4), "Terminer %d chapitres cette semaine")
        family("pages", "book", { "Une belle semaine", "Voyage entre les lignes", "Le défi des pages", "Dévoreur de pages", "Semaine de lecture" },
            "weekly_pages", goals(120, PAGE_M, 1500, true), "Lire %d pages cette semaine")
        family("time", "clock", { "Du temps pour soi", "Une semaine immergée", "Immersion prolongée", "Plongée profonde", "Semaine d'ermite" },
            "weekly_minutes", goals(90, { 0.5, 0.75, 1, 1.75, 2.75 }, 600, true), "Lire pendant %d minutes cette semaine")
        family("new", "star", { "À la découverte", "Nouveaux horizons", "Explorateur d'histoires", "Grand explorateur", "Chasseur de pépites" },
            "weekly_new", { 1, 2, 3, 5, 8 }, "Commencer %d nouveaux titres cette semaine", "Commencer %d nouveau titre cette semaine")
        family("days", "calendar", { "Le rendez-vous lecture", "Une semaine de lecteur", "Un jour sur deux", "Presque tous les jours", "Tous les jours une histoire" },
            "weekly_days", { 1, 2, 3, 5, 7 }, "Lire %d jours cette semaine", "Lire %d jour cette semaine")
    end

    shuffle(families, rand)
    local tiers = tiers_for(L)
    local selected = {}
    for i, tier in ipairs(tiers) do
        local f = families[(i - 1) % #families + 1]
        local goal = f.goals[tier]
        local cur = math.max(0, tonumber(c[f.metric]) or 0)
        local text = (goal == 1 and f.singular) or f.desc
        selected[#selected + 1] = {
            period = period, id = (daily and "rd_" or "rw_") .. f.key .. "_" .. tier,
            icon = f.icon, title = T(f.titles[tier]), desc = T(text):format(goal),
            xp = XP_TIERS[tier], tier = tier,
            cur = math.min(cur, goal), goal = goal, done = cur >= goal,
        }
    end
    return selected
end
function RandomQuests.build(c, dlev, wlev, d)
    return make("daily", c, dlev, d.daily_quest_seed), make("weekly", c, wlev, d.weekly_quest_seed)
end
return RandomQuests
