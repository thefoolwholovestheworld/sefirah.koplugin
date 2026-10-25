-- Courbe commune au plugin et au Worker : 250 XP, puis +75 XP par palier.
local Progression = {}
local function number(v) return math.max(0, tonumber(v) or 0) end
function Progression.threshold(level)
    local k = math.max(0, math.floor(number(level)) - 1)
    return k * (500.0 + 75 * (k - 1)) / 2
end
function Progression.cost(level)
    return 250 + 75 * (math.max(1, math.floor(number(level))) - 1)
end
function Progression.level(xp)
    xp = number(xp)
    local level = math.floor((math.sqrt(180625 + 600 * xp) - 425) / 150) + 1
    while Progression.threshold(level + 1) <= xp do level = level + 1 end
    while level > 1 and Progression.threshold(level) > xp do level = level - 1 end
    return level
end
function Progression.progress(xp)
    xp = number(xp)
    local level = Progression.level(xp)
    return level, xp - Progression.threshold(level), Progression.cost(level)
end
return Progression
