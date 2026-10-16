-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- Sefirah — traduction automatique selon la langue de KOReader.
--
-- Les textes du code sont écrits en français : le français sert donc de
-- clé ET de langue d'origine. Chaque fichier locales/<code>.lua est une
-- table { ["texte français"] = "traduction" }.
--
-- Ordre de recherche d'une traduction :
--   1. locales/<langue complète>.lua   (ex. pt_BR)
--   2. locales/<langue de base>.lua    (ex. pt)
--   3. locales/en.lua                  (anglais, langue de repli)
--   4. le texte d'origine tel qu'écrit dans le code
--
-- Le français n'a pas de table « français → français » : il lit seulement
-- locales/fr.lua, qui traduit les rares textes écrits en anglais dans le code
-- (ex. messages de mise à jour).
--
-- Pour ajouter une langue : copier locales/en.lua en locales/<code>.lua
-- et traduire les valeurs (les clés ne changent jamais).

local I18n = {}

local _cached_code   -- dernière langue détectée
local _chain         -- liste de tables de traduction à consulter, dans l'ordre

-- Langue de KOReader : réglage utilisateur, sinon langue courante de gettext,
-- sinon variables d'environnement.
local function detect()
    local code
    -- Langue choisie dans Paramètres › Langue du plugin (prioritaire).
    local ok_s, S = pcall(require, "settings")
    if ok_s and type(S) == "table" and S.get then
        local ok_v, v = pcall(S.get, S, "plugin_language")
        if ok_v and type(v) == "string" and v ~= "" and v ~= "auto" then return v end
    end
    if type(G_reader_settings) == "table" and G_reader_settings.readSetting then
        local ok, v = pcall(G_reader_settings.readSetting, G_reader_settings, "language")
        if ok and type(v) == "string" and v ~= "" then code = v end
    end
    if not code then
        local ok, gt = pcall(require, "gettext")
        if ok and type(gt) == "table" and type(gt.current_lang) == "string" and gt.current_lang ~= "" then
            code = gt.current_lang
        end
    end
    if not code then
        code = os.getenv("LANGUAGE") or os.getenv("LC_ALL") or os.getenv("LANG")
        if code then code = code:match("^([^:%.@]+)") end
    end
    if not code or code == "" or code == "C" or code == "POSIX" then code = "en" end
    return code
end

local function load_locale(name)
    local ok, tbl = pcall(require, "locales." .. name)
    if ok and type(tbl) == "table" then return tbl end
    return nil
end

local function rebuild(code)
    _cached_code = code
    local full = code:gsub("-", "_")
    local base = full:match("^([^_]+)") or full
    _chain = {}
    local order = { full, base, "en" }
    if base:lower() == "fr" then order = { "fr" } end
    local seen = {}
    for _, name in ipairs(order) do
        if not seen[name] then
            seen[name] = true
            local t = load_locale(name)
            if t then _chain[#_chain + 1] = t end
        end
    end
end

-- Code de langue actuellement utilisé (ex. "fr_FR", "en_US").
function I18n.lang()
    return detect()
end

-- Traduit un texte (clé = texte français d'origine).
function I18n.T(s)
    if type(s) ~= "string" then return s end
    local code = detect()
    if code ~= _cached_code then rebuild(code) end
    for i = 1, #_chain do
        local v = _chain[i][s]
        if v then return v end
    end
    return s
end

-- Variante avec formatage : I18n.TF("%d chapitre(s)", n)
function I18n.TF(s, ...)
    local ok, out = pcall(string.format, I18n.T(s), ...)
    if ok then return out end
    return I18n.T(s)
end

return I18n
