-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

local logger      = require("logger")
local ExtMgr = {}

-- Dossier du plugin (…/sefirah.koplugin) : les sources « maison » y sont livrées
-- dans extensions/, donc une simple installation du plugin suffit.
local _core_dir   = (debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+%.lua$") or ""
local _plugin_dir = _core_dir:match("^(.+)/[^/]+$") or _core_dir

-- Sources actives : sites "maison" (chacun un fichier .lua dans
-- extensions/, chargé via dofile à la demande).
--
-- WebNovel retirée : WebNovel.com est protégé par un challenge Cloudflare
-- (JS) que des requêtes HTTP brutes en Lua ne peuvent pas résoudre — pas de
-- contournement possible sans moteur JS embarqué, qui n'existe pas dans
-- KOReader. AO3 est de retour (extensions/ao3.lua, avec filtres).
local metas = {
    { id = "novelfrance", name = "NovelFrance",          site = "https://novelfrance.fr",         lang = "fr",    version = "1.0.0", runtime = "lua" },
    { id = "lightnovelvf", name = "LightNovelVF",        site = "https://www.lightnovelvf.com",   lang = "fr",    version = "1.1.1", runtime = "lua" },
    { id = "novelfire",   name = "NovelFire",            site = "https://novelfire.net",          lang = "en",    version = "1.1.0", runtime = "lua" },
    { id = "royalroad",   name = "Royal Road",           site = "https://www.royalroad.com",      lang = "en",    version = "1.0.0", runtime = "lua" },
    { id = "skynovels",   name = "SkyNovels",            site = "https://www.skynovels.net",     lang = "es",    version = "1.0.0", runtime = "lua" },
    { id = "ao3",         name = "Archive of Our Own",   site = "https://archiveofourown.org",    lang = "multi",    version = "2.1.0", runtime = "lua", listMode = true, richList = true },
    { id = "wattpad",     name = "Wattpad",              site = "https://www.wattpad.com",        lang = "multi",    version = "1.1.0", runtime = "lua" },
    { id = "mangadex",    name = "MangaDex",             site = "https://mangadex.org",           lang = "multi",    version = "1.0.1", runtime = "lua", type = "manga" },
    { id = "mangapill",   name = "MangaPill",            site = "https://mangapill.com",          lang = "en",    version = "0.1.0", runtime = "lua", type = "manga" },
    { id = "animesama",   name = "Anime-Sama",   site = "https://anime-sama.to",          lang = "fr",    version = "0.2.0", runtime = "lua", type = "manga" },
    { id = "fmteam",      name = "FMTeam",               site = "https://fmteam.fr",              lang = "fr",    version = "0.2.0", runtime = "lua", type = "manga" },
    { id = "69shu",       name = "69书吧",                   site = "https://www.69shu.xyz",         lang = "zh",    version = "1.5.0", runtime = "lua" },
}

local loaded = {}

local function loadone(id)
    if loaded[id] then return loaded[id] end

    -- Extension livrée avec le plugin (extensions/<id>.lua).
    local ok, x = pcall(dofile, _plugin_dir .. "/extensions/" .. id .. ".lua")
    if ok and type(x) == "table" then
        loaded[id] = x
        return x
    end
    logger.err("Sefirah: impossible de charger l'extension", id, tostring(x))
    return nil
end

-- Chargement paresseux : chaque extension n'est compilée qu'à sa première
-- utilisation (ExtMgr.get), plus toutes d'un coup à l'ouverture de Sefirah.
function ExtMgr.init() end

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

-- Une source est disponible si son fichier existe — sans charger le fichier.
local function available(id)
    return lfs.attributes(_plugin_dir .. "/extensions/" .. id .. ".lua", "mode") == "file"
end

function ExtMgr.get(id)
    return loadone(id)
end

function ExtMgr.getMeta(id)
    for _, m in ipairs(metas) do
        if m.id == id then return m end
    end
    return nil
end

-- Toutes les sources livrées avec le plugin (installées ou non).
function ExtMgr.available()
    local r = {}
    for _, m in ipairs(metas) do
        if available(m.id) then
            local x = {}
            for k, v in pairs(m) do x[k] = v end
            r[#r + 1] = x
        end
    end
    table.sort(r, function(a, b)
        return tostring(a.name or a.id):lower() < tostring(b.name or b.id):lower()
    end)
    return r
end

-- Une source doit être installée explicitement (onglet Sources) avant
-- d'apparaître dans Parcourir et d'être utilisée par la recherche globale.
local function installed_set()
    local set = {}
    local list = require("settings"):get("installed_sources")
    if type(list) == "table" then
        for _, id in ipairs(list) do set[id] = true end
    end
    return set
end

function ExtMgr.isInstalled(id)
    return installed_set()[id] == true
end

function ExtMgr.installed()
    local set, r = installed_set(), {}
    for _, m in ipairs(ExtMgr.available()) do
        if set[m.id] then r[#r + 1] = m end
    end
    table.sort(r, function(a, b)
        return tostring(a.name or a.id):lower() < tostring(b.name or b.id):lower()
    end)
    return r
end

-- ── Langues ───────────────────────────────────────────────────────────────────
local LANG_LABELS = {
    fr = T("Français"), en = T("Anglais"), es = T("Espagnol"), zh = T("Chinois"),
    pt = T("Portugais"), de = T("Allemand"), it = T("Italien"), ja = T("Japonais"),
    ko = T("Coréen"), multi = T("Multilingue"), ru = T("Russe"), id = T("Indonésien"), tr = T("Turc"), ar = T("Arabe"),
}

function ExtMgr.langCode(m)
    return ((m.lang or "en"):lower():match("^(%a+)")) or "en"
end

function ExtMgr.langLabel(code)
    return LANG_LABELS[code] or code:upper()
end

-- Langues présentes parmi les sources disponibles : { {code=, label=, count=}, ... }
function ExtMgr.languages(all_sources)
    local counts, list = {}, {}
    for _, m in ipairs(all_sources and ExtMgr.available() or ExtMgr.installed()) do
        local c = ExtMgr.langCode(m)
        -- Les sources multilingues (« multi ») n'ont pas d'entrée propre : elles
        -- restent visibles quel que soit le filtre de langue choisi.
        if c ~= "multi" and not counts[c] then
            counts[c] = { code = c, label = ExtMgr.langLabel(c), count = 0 }
            list[#list + 1] = counts[c]
        end
        if counts[c] then counts[c].count = counts[c].count + 1 end
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    return list
end

-- Codes de langue actuellement retenus par le filtre (ordre d'affichage),
-- limités aux langues qui existent encore. Liste vide = pas de filtre.
function ExtMgr.activeLangCodes(all_sources)
    local sel = require("settings"):get("lang_filter")
    if type(sel) ~= "table" or #sel == 0 then return {} end
    local wanted = {}
    for _, c in ipairs(sel) do wanted[c] = true end
    local r = {}
    for _, l in ipairs(ExtMgr.languages(all_sources)) do
        if wanted[l.code] then r[#r + 1] = l.code end
    end
    return r
end

local function filter_by_lang(all, all_sources)
    local codes = ExtMgr.activeLangCodes(all_sources)
    if #codes == 0 then return all end
    local set = {}
    for _, c in ipairs(codes) do set[c] = true end
    local r = {}
    for _, m in ipairs(all) do
        local c = ExtMgr.langCode(m)
        if c == "multi" or set[c] then r[#r + 1] = m end
    end
    return r
end

-- ── Type de contenu : « novels » ou « manga » (bascule Novels | Mangas en haut) ──
function ExtMgr.kindOf(id)
    local m = ExtMgr.getMeta(id)
    return (m and m.type == "manga") and "manga" or "novels"
end

function ExtMgr.currentKind()
    return require("settings"):get("content_kind") == "manga" and "manga" or "novels"
end

function ExtMgr.setKind(k)
    require("settings"):set("content_kind", k == "manga" and "manga" or "novels")
end

local function filter_by_kind(all)
    local k, r = ExtMgr.currentKind(), {}
    for _, m in ipairs(all) do
        if ExtMgr.kindOf(m.id) == k then r[#r + 1] = m end
    end
    return r
end

-- Nombre de sources par type { novels = n, manga = n } (filtre de langue appliqué),
-- parmi les sources installées ou, avec all_sources, toutes les sources disponibles.
function ExtMgr.kindCounts(all_sources)
    local c = { novels = 0, manga = 0 }
    for _, m in ipairs(filter_by_lang(all_sources and ExtMgr.available() or ExtMgr.installed(), all_sources)) do
        local k = ExtMgr.kindOf(m.id)
        c[k] = c[k] + 1
    end
    return c
end

-- Sources INSTALLÉES, filtrées par langue et par type (utilisé par Parcourir).
function ExtMgr.visible()
    return filter_by_kind(filter_by_lang(ExtMgr.installed()))
end

-- Toutes les sources disponibles, filtrées par langue (onglet Sources).
function ExtMgr.visibleAll()
    return filter_by_kind(filter_by_lang(ExtMgr.available(), true))
end

-- Suffixe de titre « · FR/EN » quand un filtre est actif, sinon "".
function ExtMgr.langTitleSuffix(all_sources)
    local codes = ExtMgr.activeLangCodes(all_sources)
    if #codes == 0 then return "" end
    local up = {}
    for i, c in ipairs(codes) do up[i] = c:upper() end
    return "  ·  " .. table.concat(up, "/")
end

function ExtMgr.install(id)
    if not ExtMgr.getMeta(id) or not available(id) then
        return false, T("Source introuvable")
    end
    if ExtMgr.isInstalled(id) then return true end
    local Settings = require("settings")
    local list = {}
    for _, v in ipairs(Settings:get("installed_sources") or {}) do list[#list + 1] = v end
    list[#list + 1] = id
    Settings:set("installed_sources", list)
    return true
end

function ExtMgr.uninstall(id)
    local Settings = require("settings")
    local list = {}
    for _, v in ipairs(Settings:get("installed_sources") or {}) do
        if v ~= id then list[#list + 1] = v end
    end
    Settings:set("installed_sources", list)
    return true
end

return ExtMgr
