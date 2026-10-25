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
local function make(period, c, level, seed)
    local rand = rng(seed)
    local daily = period == "daily"
    local p = daily and "daily_" or "weekly_"
    local L = math.max(1, tonumber(level) or 1)
    local function scale(base, step, cap)
        return math.min(cap, base + step * (L - 1))
    end
    local groups = {}
    -- Chaque famille offre trois variantes ; objectifs et récompenses varient aussi.
    local function family(key, icon, titles, metric, base, xp, description)
        local variants = {}
        for i, factor in ipairs({ 0.8, 1.2, 1.8 }) do
            local goal = math.max(i, math.floor(base * factor * rand(90, 115) / 100 + 0.5))
            local cur = math.max(0, tonumber(c[metric]) or 0)
            variants[#variants + 1] = {
                period = period, id = (daily and "rd_" or "rw_") .. key .. "_" .. i,
                icon = icon, title = T(titles[i]), desc = T(description):format(goal),
                xp = math.max(1, math.floor(xp * factor * math.min(3, 1 + 0.08 * (L - 1)) + 0.5)),
                cur = math.min(cur, goal), goal = goal, done = cur >= goal,
            }
        end
        shuffle(variants, rand)
        groups[#groups + 1] = variants
    end
    family("pages", "book", { "Quelques pages d'évasion", "Voyage entre les lignes", "Le défi des pages" },
        p .. "pages", daily and scale(10, 4, 120) or scale(40, 20, 700), daily and 25 or 65,
        daily and "Lire %d pages aujourd'hui" or "Lire %d pages cette semaine")
    family("chapters", "doc", { "Une histoire avance", "Au prochain chapitre", "Chapitres à la chaîne" },
        p .. "chapters", daily and scale(1, 0.2, 6) or scale(3, 1, 30), daily and 35 or 70,
        daily and "Terminer %d chapitre(s) aujourd'hui" or "Terminer %d chapitre(s) cette semaine")
    family("time", "clock", { "Une pause pour lire", "Du temps pour soi", "Immersion prolongée" },
        p .. "minutes", daily and scale(5, 2, 60) or scale(20, 10, 420), daily and 30 or 65,
        daily and "Lire pendant %d minutes aujourd'hui" or "Lire pendant %d minutes cette semaine")
    family("new", "star", { "À la découverte", "Nouveaux horizons", "Explorateur d'histoires" },
        p .. "new", daily and scale(1, 0.05, 2) or scale(1, 0.17, 5), daily and 35 or 70,
        daily and "Commencer %d nouveau(x) titre(s) aujourd'hui" or "Commencer %d nouveau(x) titre(s) cette semaine")
    if daily then
        family("titles", "book", { "Changer d'univers", "Lectures variées", "La tournée des histoires" },
            "daily_titles_n", scale(2, 0.125, 4), 30, "Lire dans %d titres différents aujourd'hui")
        family("focus", "flame", { "Une histoire captivante", "Au cœur d'un récit", "Impossible de décrocher" },
            "daily_best", scale(8, 3, 80), 30, "Lire %d pages dans un même titre aujourd'hui")
    else
        local variants = {}
        local goals = { 3, 5, 7 }
        for i, goal in ipairs(goals) do
            variants[i] = { period = period, id = "rw_days_" .. i, icon = "calendar",
                title = T(({ "Le rendez-vous lecture", "Une semaine de lecteur", "Tous les jours une histoire" })[i]),
                desc = T("Lire %d jours cette semaine"):format(goal), xp = 40 + goal * 10,
                cur = math.min(c.weekly_days or 0, goal), goal = goal, done = (c.weekly_days or 0) >= goal }
        end
        shuffle(variants, rand)
        groups[#groups + 1] = variants
    end
    -- Défis combinés : les deux conditions doivent être satisfaites.
    local combos = {}
    for i = 1, 3 do
        local pages = math.max(1, math.floor((daily and scale(8, 3, 90) or scale(30, 12, 400)) * i))
        local minutes = math.max(1, math.floor((daily and scale(4, 1, 40) or scale(15, 5, 180)) * i))
        local cur = math.min(tonumber(c[p .. "pages"]) or 0, pages) + math.min(tonumber(c[p .. "minutes"]) or 0, minutes)
        local goal = pages + minutes
        combos[i] = { period = period, id = (daily and "rd_" or "rw_") .. "combo_" .. i,
            icon = "star", title = T(({ "Lecture équilibrée", "L'aventure complète", "Le double défi" })[i]),
            desc = (daily and T("Aujourd'hui : %d pages ET %d minutes de lecture") or T("Cette semaine : %d pages ET %d minutes de lecture")):format(pages, minutes),
            xp = math.floor((daily and 40 or 90) * i * math.min(3, 1 + 0.08 * (L - 1))),
            cur = cur, goal = goal, done = cur >= goal }
    end
    shuffle(combos, rand)
    groups[#groups + 1] = combos
    -- Une première quête par famille, puis un second passage mélangé : jamais plus de deux par famille.
    shuffle(groups, rand)
    local selected = {}
    for _, group in ipairs(groups) do selected[#selected + 1] = group[1] end
    shuffle(groups, rand)
    for _, group in ipairs(groups) do
        if #selected >= 10 then break end
        selected[#selected + 1] = group[2]
    end
    shuffle(selected, rand)
    return selected
end
function RandomQuests.build(c, dlev, wlev, d)
    return make("daily", c, dlev, d.daily_quest_seed), make("weekly", c, wlev, d.weekly_quest_seed)
end
return RandomQuests
