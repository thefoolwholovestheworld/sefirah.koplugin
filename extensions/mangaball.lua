-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- extensions/mangaball.lua — MangaBall (https://mangaball.com), manga/manhwa/manhua multilingues.
-- Source MANGA (contrat : cf. extensions/mangadex.lua).
--
-- ══ VÉRIFIÉ SUR DE VRAIES PAGES (relevé du 2026-10-22) ═══════════════════════
--   * Site Next.js : les pages enregistrées sont un DOM déjà hydraté par le JavaScript.
--   * Série : /title-detail/<id-mongo>-<slug> ; couverture
--     bulbasaur.poke-black-and-white.net/covers/<id-mongo>/cover_<n>.webp (og:image sur la fiche).
--   * Fiche : h1 = titre, « Publication Status: <strong>ongoing</strong> », « Author: <strong>… »,
--     genres = liens /search-advanced?included_tags=<id>. Liste de chapitres en <nav class="sr-only">
--     (liens « Read <titre> Chapter N (<langue>) - … »), un lien par traduction.
--   * Chapitre : /chapter-detail/<id-chapitre>?chapter=<n>. Images :
--     chikorita.red-and-blue.net/storage/<id-mongo>/0/<n>/mangadot/<langue>/<id-chapitre>-001.webp ;
--     le DOM n'en contient que 6, mais « Page N of 10 » donne le total : on complète la suite.
--
-- ══ NON VÉRIFIÉ (aucune capture) ═════════════════════════════════════════════
--   * La liste COMPLÈTE des chapitres (1422 pour One Piece) est chargée par JS depuis une API non
--     capturée : on lit ce que le HTML brut contient (liens sr-only). Un site qui ne les sert pas
--     en HTML brut donnera « aucun chapitre ».
--   * Recherche (/search-advanced?keyword=…), nouveautés (/recently-updated) et pagination (&page=N).
--   Dans tous les cas la réponse est enregistrée dans sefirah/mangaball_last_error.txt.
--
-- Chemins stockés :
--   manga    : « <id-mongo>-<slug> »
--   chapitre : « <id-chapitre>?chapter=<n> »

local logger = require("logger")
local T      = require("core.i18n").T

-- Les anciennes versions ont mis en cache disque la bannière « You can read this at MangaDex »
-- à la place des vraies couvertures (cdn_mangadex refuse le hotlink). Le cache n'est jamais
-- réécrit s'il existe déjà : on le vide UNE fois pour que les bonnes couvertures se retéléchargent.
pcall(function() require("core.db").purgeCoverCacheOnce("mangaball", "covers_v6") end)
-- Les listes de chapitres en cache gardent l'ancien choix de traduction (mangadot / groupe « Ho-oh »,
-- qui sert un autre manga sur Code Geass ch. 1-2) : on les vide UNE fois.
pcall(function() require("core.db").purgeChapterCacheOnce("mangaball", "chapters_v8") end)

local BASE = "https://mangaball.com"
local API  = "https://api.mangaball.com/api/v1"
local CDN  = "https://chikorita.red-and-blue.net"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

-- ── Helpers ──────────────────────────────────────────────────────────────────
local function utf8_encode(cp)
    if not cp then return "" end
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function decode(s)
    s = (s or ""):gsub("&#x(%x+);", function(h) return utf8_encode(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8_encode(tonumber(d)) end)
    return (s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " "))
end

local function text_of(html)
    return (decode((html or ""):gsub("<[^>]+>", " ")):gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function attr(tag, name)
    name = name:gsub("%-", "%%-")   -- « - » est un quantificateur dans les motifs Lua
    return tag:match("%f[%w_%-]" .. name .. '%s*=%s*"([^"]*)"') or tag:match("%f[%w_%-]" .. name .. "%s*=%s*'([^']*)'")
end

local function url_encode(str)
    return (tostring(str):gsub("([^%w%-%.%_%~])", function(c) return string.format("%%%02X", c:byte()) end))
end

local LOG_RING = {}   -- dernières entrées du journal (le fichier est réécrit en entier à chaque ajout)
local function dump_error(label, body)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
        local entry = os.date("%H:%M:%S") .. "  " .. tostring(label)
        if body and tostring(body) ~= "" then entry = entry .. "\n" .. tostring(body):sub(1, 3000) end
        LOG_RING[#LOG_RING + 1] = entry
        while #LOG_RING > 12 do table.remove(LOG_RING, 1) end
        local f = io.open(dir .. "/mangaball_last_error.txt", "wb")
        if f then f:write(table.concat(LOG_RING, "\n\n--------\n\n")); f:close() end
    end)
end

local last_http = nil

local function get_html(path)
    local url = path:match("^https?://") and path or (BASE .. path)
    local body, code, extra = require("core.net").get(url, { headers = {
        ["User-Agent"] = UA,
        ["Accept"] = "text/html,application/xhtml+xml",
        ["Accept-Language"] = "en-US,en;q=0.8",
        ["Referer"] = BASE .. "/",
    }, timeout = 15 })
    if body and #body > 2 then return body end
    last_http = tostring(code)
    dump_error("requête échouée : " .. url .. "\ncode : " .. tostring(code), type(extra) == "string" and extra or "")
    logger.warn("MangaBall: échec", url, tostring(code))
    return nil, last_http
end

-- Le chemin d'un manga est « <id>-<slug>|<langue> » : la langue choisie dans le filtre reste
-- attachée à l'entrée (bibliothèque, détails) sans dépendre des filtres.
local function make_path(base, lang) return base .. "|" .. (lang or "en") end

local function split_path(path, fallback)
    path = tostring(path or "")
    local base, lang = path:match("^(.-)|([%w%-_]+)$")
    if base then return base, lang end
    return path, fallback or "en"
end

local function abs(u)
    if not u then return nil end
    if u:sub(1, 2) == "//" then return "https:" .. u end
    if u:sub(1, 1) == "/" then return BASE .. u end
    return u
end

-- ── Langues : liste « available_languages » renvoyée par l'API (relevé du 2026-10-22) ─────────
-- Le chinois s'appelle « cn » côté API ; le japonais n'y figure pas.
local LANGUAGES = {
    { id = "en", label = "English" },     { id = "fr", label = "Français" },
    { id = "es", label = "Español" },     { id = "pt-br", label = "Português (BR)" },
    { id = "pt", label = "Português" },    { id = "de", label = "Deutsch" },
    { id = "it", label = "Italiano" },    { id = "nl", label = "Nederlands" },
    { id = "pl", label = "Polski" },      { id = "ro", label = "Română" },
    { id = "ru", label = "Русский" },     { id = "uk", label = "Українська" },
    { id = "tr", label = "Türkçe" },      { id = "ar", label = "العربية" },
    { id = "he", label = "עברית" },       { id = "hi", label = "हिन्दी" },
    { id = "id", label = "Indonesia" },   { id = "th", label = "ไทย" },
    { id = "vi", label = "Tiếng Việt" },  { id = "tl", label = "Filipino" },
    { id = "cn", label = "中文" },         { id = "ko", label = "한국어" },
    { id = "bg", label = "Български" },   { id = "cs", label = "Čeština" },
    { id = "da", label = "Dansk" },       { id = "el", label = "Ελληνικά" },
    { id = "fi", label = "Suomi" },       { id = "hu", label = "Magyar" },
    { id = "ka", label = "ქართული" },     { id = "la", label = "Latina" },
    { id = "lt", label = "Lietuvių" },    { id = "mn", label = "Монгол" },
    { id = "my", label = "မြန်မာ" },       { id = "no", label = "Norsk" },
    { id = "sv", label = "Svenska" },
}
-- Langue de Sefirah → code MangaBall (« zh_CN » → « cn », « nb » → « no »…).
local LANG_MAP = { zh = "cn", nb = "no", nn = "no", fil = "tl", iw = "he" }
local function sefirah_lang()
    local ok, I18n = pcall(require, "core.i18n")
    if not ok then return "en" end
    local okm, m = pcall(I18n.matchLanguage, LANGUAGES)
    if okm and m then return m end
    local okl, code = pcall(I18n.lang)
    local base = okl and tostring(code or ""):lower():match("^(%a+)") or ""
    local mapped = LANG_MAP[base]
    return mapped or "en"
end

-- ── Listes ───────────────────────────────────────────────────────────────────
local function clean_title(t)
    t = tostring(t or "")
    t = t:gsub("^Read%s+", ""):gsub("%s+Online Free%s*$", ""):gsub("%s+online free %- MangaBall%s*$", "")
    return t
end

-- ── Contenu adulte (18+) : jamais affiché ────────────────────────────────────
-- Champs inconnus de l'API de recherche : on teste tous les noms plausibles + les étiquettes + le
-- titre (« [H] … » = hentai sur ce site). Le 1er résultat brut est noté dans mangaball_last_error.txt
-- pour pouvoir affiner si un titre adulte passe encore.
local ADULT_TAGS = {
    hentai = true, smut = true, erotica = true, pornographic = true, adult = true,
    mature = true, mature17 = true, explicit = true, nsfw = true, r18 = true, r18plus = true,
    ecchi = true, sexualviolence = true, sexualcontent = true, adultcontent = true,
    loli = true, shota = true,
}

local function is_adult_title(name)
    local l = tostring(name or ""):lower()
    if l:match("^%s*[%[%(]%s*h%s*[%]%)]") then return true end
    if l:find("18+", 1, true) or l:find("r-18", 1, true) or l:find("r18", 1, true) then return true end
    for _, word in ipairs({ "adult", "mature", "hentai", "smut", "erotica", "pornographic", "explicit", "nsfw", "ecchi" }) do
        if l:find("%f[%w]" .. word .. "%f[%W]") then return true end
    end
    return false
end

local function is_adult(it)
    if type(it) ~= "table" then return false end
    for _, k in ipairs({ "is18plus", "is18Plus", "is_18plus", "isAdult", "is_adult", "adult", "nsfw",
        "is_nsfw", "isNsfw", "is18", "r18", "is_r18", "explicit" }) do
        local v = it[k]
        if v == true or v == 1 or v == "true" or v == "1" or v == "yes" then return true end
    end
    for _, k in ipairs({ "contentRating", "content_rating", "rating_type", "ageRating", "age_rating",
        "rating", "contentWarning", "content_warning" }) do
        local raw = it[k]
        local v = tostring(raw or ""):lower():gsub("[%s%p_]+", "")
        if ADULT_TAGS[v] or v == "18plus" or v == "17plus" or v == "mature17plus" then return true end
        local age = tonumber(raw)
        if age and age >= 18 then return true end
    end
    if type(it.tags) == "table" then
        for _, t in ipairs(it.tags) do
            local nm = type(t) == "table" and (t.name or t.label or t.slug) or t
            local key = tostring(nm or ""):lower():gsub("[%s%p_]+", "")
            if ADULT_TAGS[key] then return true end
            if type(t) == "table" and (t.adult == true or t.isAdult == true or t.is_adult == true) then return true end
        end
    end
    return is_adult_title(it.name)
end

-- Normalisation pour comparer titres et mot cherché (minuscules, sans ponctuation).
local function norm(str)
    str = tostring(str or ""):lower():gsub("[%p%s]+", " ")
    return (str:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Note de pertinence : 0 = titre exact, 1 = commence par, 2 = contient l'expression entière,
-- 3 = un titre alternatif contient l'expression, nil = ne contient pas l'expression.
local function relevance(it, term)
    local t = norm(term)
    if t == "" then return 2 end
    local n = norm(it.name)
    if n == t then return 0 end
    if n:sub(1, #t + 1) == t .. " " then return 1 end
    if (" " .. n .. " "):find(" " .. t .. " ", 1, true) then return 2 end
    if type(it.alternateName) == "table" then
        for _, a in ipairs(it.alternateName) do
            local na = norm(a)
            if na == t then return 3 end
            if (" " .. na .. " "):find(" " .. t .. " ", 1, true) then return 3 end
        end
    end
    return nil
end

local first_dump_done = false

local function parse_list(html, lang)
    local covers = {}
    for tag in html:gmatch("<img[^>]->") do
        local u = attr(tag, "src") or attr(tag, "data-src")
        local id = u and u:match("/covers/(%x+)/")
        if id and not covers[id] then covers[id] = abs(u) end
    end
    local novels, by_id = {}, {}
    for a_tag, inner in html:gmatch("(<a%s[^>]-href%s*=%s*[^>]->)(.-)</a>") do
        local href = attr(a_tag, "href")
        local id, slug
        if href then id, slug = href:match("/title%-detail/(%x+)%-([^/%?#\"']+)") end
        if id then
            local n = by_id[id]
            if not n then
                n = { path = make_path(id .. "-" .. slug, lang), cover = covers[id] }
                by_id[id] = n
                novels[#novels + 1] = n
            end
            if not n.name then
                local title = text_of(inner)
                if title == "" then
                    local img = inner:match("<img[^>]->")
                    title = img and attr(img, "alt") or ""
                end
                title = clean_title(decode(title))
                if title ~= "" then n.name = title end
            end
        end
    end
    local out = {}
    for _, n in ipairs(novels) do
        if n.name and not is_adult_title(n.name) then out[#out + 1] = n end
    end
    return out
end

local function list_page(path, lang)
    local html = get_html(path)
    if not html then
        return { novels = {}, error = T("MangaBall injoignable (code ") .. tostring(last_http) .. ")" }
    end
    local novels = parse_list(html, lang)
    if #novels == 0 then
        dump_error("liste vide : " .. path, html)
        return { novels = {}, error = T("MangaBall : aucune série reconnue. Voir sefirah/mangaball_last_error.txt") }
    end
    return { novels = novels }
end

-- ── Filtres de la recherche avancée (page /search-advanced du site) ──────────
-- VÉRIFIÉ (relevé du 2026-10-23, GET api.mangaball.com/api/v1/title/search-advanced) :
--   status=ongoing · sort_by=lastupdate · sort_order=desc · adult_mode=no_18 · tag_mode=AND
--   included_tags=<id>,<id> · use_user_settings=true · page · limit=24 · user_id=demo_user.
--   Chaque résultat porte : status, originalLanguage, publicationDemographic,
--   availableTranslatedLanguages et tags = [{ id, name, group }].
-- NON VÉRIFIÉ (aucune capture) : le nom des paramètres « type de publication », « public »,
--   « exclure des tags », les valeurs « completed / hiatus / cancelled » et les valeurs de tri
--   autres que lastupdate. Le code les ESSAIE (plusieurs noms) et ne retient que celui dont les
--   résultats prouvent que le filtre a joué (cf. resolve() plus bas) ; en plus, les résultats sont
--   re-filtrés ici d'après leurs propres champs. Détail dans sefirah/mangaball_last_error.txt.
-- Le contenu 18+ n'est jamais demandé (adult_mode=no_18) : ses étiquettes ne sont donc pas proposées.

local function opt(id, label) return { id = id, label = label } end
local function nkey(s) return (tostring(s or ""):lower():gsub("[^%w]", "")) end

local function settings_get(k)
    local ok, S = pcall(require, "sefirah_settings")
    if ok and type(S) == "table" and S.get then
        local ok2, v = pcall(S.get, S, k)
        if ok2 then return v end
    end
    return nil
end

local function settings_set(k, v)
    local ok, S = pcall(require, "sefirah_settings")
    if ok and type(S) == "table" and S.set then pcall(S.set, S, k, v) end
end

-- Étiquettes connues (id relevés dans la réponse de l'API le 2026-10-23). Les autres sont
-- découvertes à la 1re ouverture de « Filtrer » (ext:loadFilters) puis gardées sur disque.
local TAG_SEED = {
    "685146c5f3ed681c80f257e1|Reincarnation|theme", "685146c5f3ed681c80f257e2|Monsters|theme",
    "685146c5f3ed681c80f257e3|Action|genre",        "685146c5f3ed681c80f257e4|Demons|theme",
    "685146c5f3ed681c80f257e5|Comedy|genre",        "685146c5f3ed681c80f257e6|Adventure|genre",
    "685146c5f3ed681c80f257e8|Harem|theme",         "685146c5f3ed681c80f257e9|Isekai|genre",
    "685146c5f3ed681c80f257ea|Fantasy|genre",       "685148cf15e8b86aae68e4db|Romance|genre",
    "685148cf15e8b86aae68e4dc|Survival|theme",      "685148cf15e8b86aae68e4dd|Drama|genre",
    "685148cf15e8b86aae68e4de|Adaptation|format",   "685148d015e8b86aae68e4e3|Slice of Life|genre",
    "685148d015e8b86aae68e4e7|School Life|theme",   "685148d115e8b86aae68e4ec|4-Koma|format",
    "685148d115e8b86aae68e4f3|Gore|content",        "685148d215e8b86aae68e4f4|Mystery|genre",
    "685148d215e8b86aae68e4f8|Cooking|theme",       "685148d615e8b86aae68e501|Ghosts|theme",
    "685148d615e8b86aae68e502|Full Color|format",   "685148d715e8b86aae68e505|Genderswap|theme",
    "685148d715e8b86aae68e506|Loli|theme",          "685148d715e8b86aae68e507|Psychological|genre",
    "685148d715e8b86aae68e509|Magic|theme",         "685148d715e8b86aae68e50d|Web Comic|format",
    "685148d915e8b86aae68e517|Long Strip|format",   "685148d915e8b86aae68e518|Mafia|theme",
    "685148d915e8b86aae68e51e|Thriller|genre",      "685148da15e8b86aae68e520|Horror|genre",
    "685148db15e8b86aae68e527|Historical|genre",    "685148db15e8b86aae68e528|Supernatural|theme",
    "685148db15e8b86aae68e529|Tragedy|genre",       "685148db15e8b86aae68e52c|Monster Girls|theme",
    "685148e115e8b86aae68e53c|Video Games|theme",   "685148e215e8b86aae68e540|Post-Apocalyptic|theme",
    "685148e215e8b86aae68e544|Philosophical|genre", "685148e715e8b86aae68e54b|Animals|theme",
    "6851490415e8b86aae68e5b9|Samurai|theme",       "6851490615e8b86aae68e5c2|Martial Arts|theme",
    "6851490c15e8b86aae68e5d1|Time Travel|theme",   "6851492115e8b86aae68e602|Villainess|theme",
}

-- Étiquettes affichées par le site (captures du 2026-10-23, sans les étiquettes 18+) : sert à
-- signaler dans mangaball_last_error.txt celles dont l'id n'a pas pu être découvert.
local TAG_EXPECTED = {
    "Adaptation", "4-Koma", "Full Color", "Web Comic", "Long Strip", "Anthology", "Oneshot",
    "Award Winning", "Doujinshi", "Self-Published", "Official Colored", "Fan Colored",
    "Action", "Comedy", "Adventure", "Isekai", "Fantasy", "Sci-Fi", "Romance", "Drama",
    "Slice of Life", "Mystery", "Psychological", "Thriller", "Crime", "Horror", "Girls' Love",
    "Historical", "Tragedy", "Philosophical", "Boys' Love", "Sports", "Wuxia", "Mecha",
    "Magical Girls", "Superhero", "Medical", "Ecchi", "User Created", "Mature", "Yaoi", "Yuri",
    "Shounen Ai", "Manga", "Manhwa", "Manhua", "Comic", "Josei(W)", "Shoujo(G)", "Revenge",
    "Reincarnation", "Monsters", "Demons", "Harem", "Survival", "Music", "School Life", "Gyaru",
    "Shota", "Cooking", "Office Workers", "Ghosts", "Genderswap", "Loli", "Ninja", "Magic",
    "Mafia", "Delinquents", "Supernatural", "Monster Girls", "Reverse Harem", "Crossdressing",
    "Video Games", "Post-Apocalyptic", "Military", "Animals", "Incest", "Vampires", "Samurai",
    "Martial Arts", "Time Travel", "Zombies", "Aliens", "Villainess", "Traditional Games",
    "Police", "Virtual Reality", "Comics", "Seinen", "3D", "Gore",
}

-- Jamais proposées : le contenu 18+ est masqué par l'extension (cf. is_adult).
local TAG_HIDDEN = { hentai = true, smut = true, adult = true, manhwa18 = true,
    sexualviolence = true, ["18"] = true }

local TAG_GROUP_DEFS = {
    { group = "genre",   key = "tag_genre",   label = T("Genres") },
    { group = "theme",   key = "tag_theme",   label = T("Thèmes") },
    { group = "format",  key = "tag_format",  label = T("Formats") },
    { group = "content", key = "tag_content", label = T("Avertissements") },
}
local TAG_KEYS = { "tag_genre", "tag_theme", "tag_format", "tag_content" }

local TAGS, TAG_N = {}, 0   -- id → { name, group }

local function add_tag(id, name, group)
    id = tostring(id or "")
    name = tostring(name or ""):gsub("[|;\r\n]", " ")
    group = tostring(group or ""):lower()
    if #id ~= 24 or not id:match("^%x+$") or name:match("^%s*$") then return false end
    local known = false
    for _, g in ipairs(TAG_GROUP_DEFS) do
        if g.group == group then known = true end
    end
    if not known or TAG_HIDDEN[nkey(name)] or TAGS[id] then return false end
    TAGS[id] = { name = name, group = group }
    TAG_N = TAG_N + 1
    return true
end

local FILTER_TAGS = {}   -- groupe → filtre à sélection multiple
for _, g in ipairs(TAG_GROUP_DEFS) do
    FILTER_TAGS[g.group] = { key = g.key, label = g.label, default = "", multi = true,
        options = { opt("", T("Tous")) } }
end
local F_EXCL = { key = "tag_excl", label = T("Exclure ces tags"), default = "", multi = true,
    options = { opt("", T("Aucun")) } }

local function sorted_tags(group)
    local list = {}
    for id, t in pairs(TAGS) do
        if not group or t.group == group then list[#list + 1] = { id = id, name = t.name } end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

local function rebuild_tag_options()
    for _, g in ipairs(TAG_GROUP_DEFS) do
        local o = { opt("", T("Tous")) }
        for _, e in ipairs(sorted_tags(g.group)) do o[#o + 1] = opt(e.id, e.name) end
        FILTER_TAGS[g.group].options = o
    end
    local x = { opt("", T("Aucun")) }
    for _, e in ipairs(sorted_tags(nil)) do x[#x + 1] = opt(e.id, e.name) end
    F_EXCL.options = x
end

local function tags_save()
    local parts = {}
    for id, t in pairs(TAGS) do parts[#parts + 1] = id .. "|" .. t.name .. "|" .. t.group .. ";" end
    table.sort(parts)
    settings_set("mangaball_tags", table.concat(parts))
end

for _, s in ipairs(TAG_SEED) do
    local id, name, group = s:match("^(%x+)|([^|]+)|(%a+)$")
    add_tag(id, name, group)
end
local TAG_N_SEED = TAG_N
do
    local raw = settings_get("mangaball_tags")
    if type(raw) == "string" then
        for id, name, group in raw:gmatch("(%x+)|([^|;]+)|(%a+);") do add_tag(id, name, group) end
    end
end
rebuild_tag_options()

local F_SORT = { key = "sort", label = T("Tri"), default = "lastupdate", options = {
    opt("lastupdate", T("Dernières mises à jour")), opt("views", T("Plus lus")),
    opt("rating", T("Mieux notés")), opt("created", T("Derniers ajoutés")),
    opt("title", T("Titre A-Z")) } }
local F_ORDER = { key = "order", label = T("Ordre"), default = "", options = {
    opt("", T("Auto")), opt("desc", T("Décroissant")), opt("asc", T("Croissant")) } }
local F_STATUS = { key = "status", label = T("Statut"), default = "", options = {
    opt("", T("Tous")), opt("ongoing", T("En cours")), opt("completed", T("Terminé")),
    opt("hiatus", T("En pause")), opt("cancelled", T("Annulé")) } }
local F_ORIGIN = { key = "origin", label = T("Type"), default = "", options = {
    opt("", T("Tous")), opt("manga", T("Manga (japonais)")), opt("manhwa", T("Manhwa (coréen)")),
    opt("manhua", T("Manhua (chinois)")), opt("comics", T("Comics (occidental)")) } }
local F_DEMO = { key = "demo", label = T("Public"), default = "", options = {
    opt("", T("Tous")), opt("shounen", "Shounen"), opt("shoujo", "Shoujo"),
    opt("seinen", "Seinen"), opt("josei", "Josei") } }
local F_MODE = { key = "tagmode", label = T("Tags : correspondance"), default = "AND", options = {
    opt("AND", T("Tous les tags")), opt("OR", T("Au moins un tag")) } }
local F_LANG = { key = "lang", label = T("Langue"), default = sefirah_lang(), options = LANGUAGES }
local FILTERS = { F_LANG, F_SORT, F_ORDER, F_STATUS, F_ORIGIN, F_DEMO, F_MODE,
    FILTER_TAGS.genre, FILTER_TAGS.theme, FILTER_TAGS.format, FILTER_TAGS.content, F_EXCL }

-- ── Extension ────────────────────────────────────────────────────────────────
local ext = {
    id      = "mangaball",
    name    = "MangaBall",
    site    = BASE,
    lang    = "multi",
    version = "0.6.3",
    type    = "manga",
    popularFilters = FILTERS,
    searchFilters = FILTERS,
    hasReviews = false,
    chapterCommentsPanel = false,
    -- Mise à jour incrémentale de la liste des chapitres (cf. ui/detail.lua) : 1 chapitre par « page »,
    -- parseChaptersFrom(path, n) ne renvoie que les chapitres à partir du n-ième.
    chapters_per_page = 1,
}

-- Sans filtre transmis (recherche globale, bibliothèque, anciennes entrées) : langue de Sefirah.
local function lang_of(options)
    local f = (options and options.filters) or {}
    return (f.lang and f.lang ~= "") and f.lang or sefirah_lang()
end

local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return data
end

local function sv(v)
    if type(v) == "string" and v ~= "" then return v end
    if type(v) == "number" then return tostring(v) end
    return nil
end

-- ── Requêtes en parallèle ────────────────────────────────────────────────────
-- Sur une liseuse chaque requête HTTPS coûte plusieurs secondes (DNS + TLS) : N pages l'une après
-- l'autre = N × la latence. Chaque requête tourne dans son sous-processus (core/parallel.lua) et
-- écrit sa réponse dans un fichier temporaire ; on relit ensuite les fichiers.
local API_HEADERS = { ["User-Agent"] = UA, ["Accept"] = "application/json",
    ["Referer"] = BASE .. "/", ["Origin"] = BASE }
local tmp_counter = 0

local function tmp_dir()
    local dir
    pcall(function()
        local DataStorage = require("datastorage")
        dir = DataStorage:getSettingsDir() .. "/sefirah"
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
    end)
    return dir
end

-- reqs : { { key = …, url = … }, … } → { [key] = corps } (les requêtes échouées sont absentes).
local function fetch_many(reqs, width, timeout, headers)
    local out = {}
    if #reqs < 2 then return out end
    local ok_p, Parallel = pcall(require, "core.parallel")
    local dir = tmp_dir()
    if not (ok_p and Parallel.available() and dir) then return out end
    tmp_counter = tmp_counter + 1
    local stamp = tostring(os.time()) .. "_" .. tmp_counter
    local i = 1
    while i <= #reqs do
        local jobs, files = {}, {}
        for k = i, math.min(i + width - 1, #reqs) do
            local r = reqs[k]
            local fpath = string.format("%s/mb_tmp_%s_%d.json", dir, stamp, k)
            files[#files + 1] = { key = r.key, path = fpath }
            jobs[#jobs + 1] = function()
                local body = require("core.net").get(r.url, { headers = r.headers or headers or API_HEADERS,
                    timeout = 12, no_probe = true, retries = 0 })
                if body and #body > 2 then
                    local f = io.open(fpath, "wb")
                    if f then f:write(body); f:close() end
                end
            end
        end
        if not Parallel.runAndWait(jobs, timeout or 45) then break end
        for _, fl in ipairs(files) do
            local f = io.open(fl.path, "rb")
            if f then
                local body = f:read("*a"); f:close()
                if body and #body > 2 then out[fl.key] = body end
            end
            pcall(os.remove, fl.path)
        end
        i = i + width
    end
    return out
end

local function listing_query(tid, page, limit, order, server_lang)
    return "/title/chapter-listing?title_id=" .. tid .. "&page=" .. page .. "&limit=" .. limit
        .. "&group_by=chapter_number&sort_order=" .. order
        .. "&language=" .. url_encode(server_lang or "") .. "&search=&user_id="
end

-- ── Filtre de langue des listes ──────────────────────────────────────────────
-- Les pages de liste du site (/recently-updated) ne sont pas filtrables par langue : on interroge
-- l'API des chapitres (limit=1, relevée) pour savoir si une série a des chapitres dans la langue.
-- Résultat gardé pour la session ; série inconnue (requête échouée) = conservée.
local LANG_TOTAL = {}   -- « id|langue » → nombre de chapitres (numéros distincts)

-- ── Couvertures manquantes dans les listes ───────────────────────────────────
-- Certaines séries n'ont pas d'image de couverture exploitable dans la liste (chargement différé,
-- champ vide dans l'API) alors que leur fiche l'a (og:image). On va la chercher sur la fiche,
-- en parallèle, pour les seules séries sans couverture.
local HTML_HEADERS = { ["User-Agent"] = UA, ["Accept"] = "text/html,application/xhtml+xml",
    ["Accept-Language"] = "en-US,en;q=0.8", ["Referer"] = BASE .. "/" }
local COVER_OF = {}   -- chemin de base → URL (gardé pour la session)

local function og_image(html)
    return abs(html:match('<meta[^>]-property%s*=%s*"og:image"[^>]-content%s*=%s*"([^"]*)"')
        or html:match('<meta[^>]-content%s*=%s*"([^"]*)"[^>]-property%s*=%s*"og:image"'))
end

local function fill_covers(novels)
    local reqs, by_key = {}, {}
    for i, n in ipairs(novels) do
        if not n.cover or n.cover == "" then
            local base = split_path(n.path)
            if COVER_OF[base] then
                n.cover = COVER_OF[base]
            elseif #reqs < 12 then
                reqs[#reqs + 1] = { key = i, url = BASE .. "/title-detail/" .. base }
                by_key[i] = base
            end
        end
    end
    if #reqs == 0 then return end
    local bodies
    if #reqs == 1 then
        local h = get_html(reqs[1].url)
        bodies = { [reqs[1].key] = h }
    else
        bodies = fetch_many(reqs, 12, 25, HTML_HEADERS)
    end
    for i, body in pairs(bodies) do
        local u = body and og_image(body)
        if u and u ~= "" then
            COVER_OF[by_key[i]] = u
            novels[i].cover = u
        end
    end
end

local function filter_by_lang(novels, lang)
    local reqs, seen = {}, {}
    for _, n in ipairs(novels) do
        local tid = split_path(n.path):match("^(%x+)")
        local key = tid and (tid .. "|" .. lang)
        if key and LANG_TOTAL[key] == nil and not seen[key] then
            seen[key] = true
            reqs[#reqs + 1] = { key = key, url = API .. listing_query(tid, 1, 1, "desc", lang) }
        end
    end
    if #reqs > 0 then
        for key, body in pairs(fetch_many(reqs, 12, 25)) do
            local d = json_decode(body)
            if type(d) == "table" and type(d.data) == "table" then
                local pg = type(d.pagination) == "table" and d.pagination or {}
                LANG_TOTAL[key] = tonumber(pg.total) or #d.data
            end
        end
    end
    local kept = {}
    for _, n in ipairs(novels) do
        local tid = split_path(n.path):match("^(%x+)")
        local total = tid and LANG_TOTAL[tid .. "|" .. lang]
        if total == nil or total > 0 then kept[#kept + 1] = n end
    end
    return kept
end

local function html_popular(page, lang)
    -- Nouveautés ; l'accueil sert de repli (seule page de liste réellement vue).
    local r = list_page("/recently-updated" .. (page > 1 and ("?page=" .. page) or ""), lang)
    if #r.novels == 0 and page == 1 then r = list_page("/", lang) end
    if #r.novels > 0 then
        local kept = filter_by_lang(r.novels, lang)
        -- Une page vide signifierait « fin de la liste » pour l'écran Parcourir : si aucune série de
        -- la page n'a de chapitres dans cette langue, on garde la page telle quelle plutôt que de bloquer.
        if #kept > 0 then r.novels = kept end
        pcall(fill_covers, r.novels)
    end
    return r
end

-- ── Recherche : API du site (GET https://api.mangaball.com/api/v1/title/search/) ──────────────
-- Réponse relevée le 2026-10-22 : { data = [ { id, slug, name, alternateName = {…},
--   image = { cdn_mangadex, cover = { path } }, status, … } ], pagination = { total, page, limit, total_pages } }
-- NON VÉRIFIÉ : le nom du paramètre qui porte le mot cherché (la page enregistrée ne le montre pas).
-- On essaie les noms courants ; on retient le premier dont les résultats contiennent vraiment le mot.
local SEARCH_PARAMS = { "q", "query", "keyword", "search", "title", "name", "keywords", "text", "s" }
local function saved_param(k)
    local v = settings_get(k)
    return (type(v) == "string" and v ~= "") and v or nil
end
local search_param = saved_param("mangaball_sp")   -- nom qui a fonctionné (gardé sur disque)

local function json_get(url)
    local body, code, extra = require("core.net").get(url, { headers = {
        ["User-Agent"] = UA, ["Accept"] = "application/json",
        ["Referer"] = BASE .. "/", ["Origin"] = BASE,
    }, timeout = 20, retries = 0 })
    if not body then return nil, tostring(code) .. " " .. (type(extra) == "string" and extra:sub(1, 200) or "") end
    local data = json_decode(body)
    if type(data) ~= "table" then return nil, "JSON illisible : " .. tostring(body):sub(1, 200) end
    return data
end

local function item_cover(it)
    -- Couverture hébergée par MangaBall (adresse relevée sur les fiches). On n'utilise PLUS « cdn_mangadex » :
    -- MangaDex refuse le téléchargement depuis un autre site et renvoie à la place une image
    -- « You can read this at MangaDex » (c'est ce qui s'affichait dans les résultats).
    local im = type(it.image) == "table" and it.image or {}
    local c = type(im.cover) == "table" and im.cover or {}
    local p = sv(c.path)
    if p then return "https://bulbasaur.poke-black-and-white.net/covers/" .. (p:gsub("\\", "/")) end
    return nil
end

local function item_matches(it, term)
    local t = term:lower()
    if tostring(it.name or ""):lower():find(t, 1, true) then return true end
    if type(it.alternateName) == "table" then
        for _, a in ipairs(it.alternateName) do
            if tostring(a):lower():find(t, 1, true) then return true end
        end
    end
    return false
end

local function search_url(param, term, page)
    return API .. "/title/search/?" .. param .. "=" .. url_encode(term) .. "&page=" .. page .. "&limit=20"
end


local function convert_items(list, lang, term)
    if not first_dump_done and type(list[1]) == "table" then
        first_dump_done = true
        local keys = {}
        for k, v in pairs(list[1]) do keys[#keys + 1] = tostring(k) .. "=" .. tostring(type(v) == "table" and "{…}" or v):sub(1, 60) end
        table.sort(keys)
        dump_error("champs d'un résultat de recherche : " .. table.concat(keys, " ; "), "")
    end
    local scored = {}
    for i, it in ipairs(list) do
        if type(it) == "table" and it.id and sv(it.slug) and sv(it.name) and not is_adult(it) then
            scored[#scored + 1] = { it = it, i = i, r = term and relevance(it, term) or 2 }
        end
    end
    -- On ne garde que les titres qui contiennent l'expression entière (« one piece », pas
    -- « Honey Piece ») ; si aucun ne la contient, on garde tout plutôt que d'afficher une page vide.
    local any = false
    for _, e in ipairs(scored) do if e.r then any = true; break end end
    local kept = {}
    for _, e in ipairs(scored) do
        if e.r or not any then e.r = e.r or 9; kept[#kept + 1] = e end
    end
    table.sort(kept, function(a, b) if a.r ~= b.r then return a.r < b.r end return a.i < b.i end)
    local novels = {}
    for _, e in ipairs(kept) do
        local it = e.it
        novels[#novels + 1] = { path = make_path(tostring(it.id) .. "-" .. it.slug, lang), name = it.name, cover = item_cover(it) }
    end
    return novels
end

-- ── Recherche avancée : adresse, paramètres à confirmer, contrôle des résultats ─────────
local PAGE_LIMIT = 24
local RESOLVED = {}   -- « sort:views » → « sort_by=views » (paramètres confirmés, gardés sur disque)

do
    local raw = settings_get("mangaball_params")
    if type(raw) == "string" then
        for k, v in raw:gmatch("([^>;]+)>([^;]+);") do RESOLVED[k] = v end
    end
end

local FAIL_TTL = 7 * 86400
local function resolved(key)
    local v = RESOLVED[key]
    if not v then return nil end
    local ts, cand = v:match("^!(%d+)!(.+)$")
    if ts then
        if os.time() - tonumber(ts) > FAIL_TTL then RESOLVED[key] = nil; return nil end
        return cand
    end
    return v
end

local function res_save()
    local t = {}
    for k, v in pairs(RESOLVED) do t[#t + 1] = k .. ">" .. v .. ";" end
    table.sort(t)
    settings_set("mangaball_params", table.concat(t))
end

local function included_ids(f)
    local out, seen = {}, {}
    for _, k in ipairs(TAG_KEYS) do
        for id in tostring((f or {})[k] or ""):gmatch("[^,]+") do
            if not seen[id] then seen[id] = true; out[#out + 1] = id end
        end
    end
    return out
end

local function base_params(f, page)
    f = f or {}
    local q = { "adult_mode=no_18", "tag_mode=" .. (f.tagmode == "OR" and "OR" or "AND"),
        "use_user_settings=true", "page=" .. tostring(page or 1), "limit=" .. PAGE_LIMIT,
        "user_id=demo_user" }
    local inc = included_ids(f)
    if #inc > 0 then q[#q + 1] = "included_tags=" .. table.concat(inc, ",") end
    return q
end

local function adv_url(params, extra)
    local q = {}
    for _, p in ipairs(params) do q[#q + 1] = p end
    for _, p in ipairs(extra or {}) do q[#q + 1] = p end
    return API .. "/title/search-advanced?" .. table.concat(q, "&")
end

local function is_data(d) return type(d) == "table" and type(d.data) == "table" end

-- Plusieurs adresses en parallèle → { [i] = JSON décodé }. Sans sous-processus, on n'en fait que
-- quelques-unes l'une après l'autre (seq_max) pour ne pas bloquer la liseuse.
local function json_many(urls, seq_max)
    local reqs = {}
    for i, u in ipairs(urls) do reqs[i] = { key = i, url = u } end
    local out = {}
    local bodies = fetch_many(reqs, 12, 40)
    if next(bodies) ~= nil then
        for i = 1, #urls do
            local d = bodies[i] and json_decode(bodies[i])
            if type(d) == "table" then out[i] = d end
        end
    else
        for i = 1, math.min(#urls, seq_max or 6) do
            local d = json_get(urls[i])
            if type(d) == "table" then out[i] = d end
        end
    end
    return out
end

-- Index de la 1re adresse dont la réponse non vide satisfait check(items), sinon nil.
local function first_valid(urls, check)
    local res = json_many(urls, 6)
    for i = 1, #urls do
        local d = res[i]
        if is_data(d) and #d.data > 0 and check(d.data) then return i end
    end
    return nil
end

-- true si la suite est ordonnée (dir « asc » / « desc »), avec au plus `tol` inversions, et pas constante.
local function sequence_ok(items, get, dir, tol)
    if #items < 3 then return false end
    local inv, distinct, prev = 0, false, nil
    for _, it in ipairs(items) do
        local v = get(it)
        if prev ~= nil then
            if v ~= prev then distinct = true end
            if (dir == "desc" and v > prev) or (dir == "asc" and v < prev) then inv = inv + 1 end
        end
        prev = v
    end
    return distinct and inv <= (tol or 0)
end

local function stat_of(it, k)
    local st = type(it.stats) == "table" and it.stats or {}
    return tonumber(st[k]) or tonumber(it[k]) or 0
end

-- Cherche, parmi `cands` (liste de « param=valeur »), celui dont les résultats prouvent l'effet.
-- `fixed` : paramètres ajoutés à chaque essai. Aucun confirmé → on prend le 1er (noté dans le fichier d'erreur).
local function resolve(key, cands, check, fixed)
    local known = resolved(key)
    if known then return known end
    local base = base_params({}, 1)
    local urls = {}
    for i, c in ipairs(cands) do
        local ex = { c }
        for _, p in ipairs(fixed or {}) do ex[#ex + 1] = p end
        urls[i] = adv_url(base, ex)
    end
    local i = first_valid(urls, check)
    if i then
        RESOLVED[key] = cands[i]
        res_save()
        return cands[i]
    end
    dump_error("MangaBall : paramètre « " .. key .. " » non confirmé, le 1er candidat est utilisé "
        .. "(les résultats sont re-filtrés localement).", table.concat(urls, "\n"))
    RESOLVED[key] = "!" .. os.time() .. "!" .. cands[1]   -- ne pas resonder à chaque page
    res_save()
    return cands[1]
end

local SORT_RULES = {
    views   = { dir = "desc", tol = 0, cands = { "views", "most_viewed", "view_count", "popular", "views_count", "mostviewed" },
                get = function(it) return stat_of(it, "views") end },
    rating  = { dir = "desc", tol = 0, cands = { "rating", "top_rated", "rating_average", "toprated", "ratings", "score" },
                get = function(it) return type(it.ratings) == "table" and tonumber(it.ratings.rating_average) or 0 end },
    created = { dir = "desc", tol = 0, cands = { "created", "created_at", "recently_added", "createdat", "newest", "added" },
                get = function(it) return tostring(it.created_at or "") end },
    title   = { dir = "asc", tol = 1, cands = { "title", "name", "title_az", "alphabetical", "az" },
                get = function(it) return norm(it.name) end },
}

local function resolve_sort(kind)
    local rule = SORT_RULES[kind]
    local cands = {}
    for _, v in ipairs(rule.cands) do cands[#cands + 1] = "sort_by=" .. v end
    return resolve("sort:" .. kind, cands,
        function(items) return sequence_ok(items, rule.get, rule.dir, rule.tol) end,
        { "sort_order=" .. rule.dir })
end

local STATUS_VALUES = {
    completed = { "completed", "complete", "finished" },
    hiatus    = { "hiatus", "on_hiatus", "paused" },
    cancelled = { "cancelled", "canceled", "dropped" },
}
local STATUS_OK = {
    ongoing   = { ongoing = true },
    completed = { completed = true, complete = true, finished = true },
    hiatus    = { hiatus = true, on_hiatus = true, paused = true },
    cancelled = { cancelled = true, canceled = true, dropped = true },
}

local function resolve_status(id)
    local cands = {}
    for _, v in ipairs(STATUS_VALUES[id] or { id }) do cands[#cands + 1] = "status=" .. v end
    return resolve("status:" .. id, cands, function(items)
        local first = tostring(items[1].status or ""):lower()
        if first == "" or first == "ongoing" then return false end
        for _, it in ipairs(items) do
            if tostring(it.status or ""):lower() ~= first then return false end
        end
        return true
    end)
end

local ORIGIN = {
    manga  = { lang = "ja", values = { "ja", "manga", "japanese" } },
    manhwa = { lang = "ko", values = { "ko", "manhwa", "korean" } },
    manhua = { lang = "cn", values = { "cn", "manhua", "chinese" } },
    comics = { lang = "en", values = { "en", "comics", "western" } },
}
local ORIGIN_PARAMS = { "original_language", "originalLanguage", "origin", "publication_type", "type" }

local function resolve_origin(id)
    local o = ORIGIN[id]
    local cands = {}
    for _, v in ipairs(o.values) do
        for _, p in ipairs(ORIGIN_PARAMS) do cands[#cands + 1] = p .. "=" .. v end
    end
    return resolve("origin:" .. id, cands, function(items)
        for _, it in ipairs(items) do
            if it.originalLanguage ~= o.lang then return false end
        end
        return true
    end)
end

local DEMO_OK = { shounen = true, shoujo = true, seinen = true, josei = true }
local DEMO_PARAMS = { "demographic", "publication_demographic", "publicationDemographic", "demographics" }

local function resolve_demo(id)
    local cands = {}
    for _, v in ipairs({ id, id:sub(1, 1):upper() .. id:sub(2) }) do
        for _, p in ipairs(DEMO_PARAMS) do cands[#cands + 1] = p .. "=" .. v end
    end
    return resolve("demo:" .. id, cands, function(items)
        for _, it in ipairs(items) do
            if tostring(it.publicationDemographic or ""):lower() ~= id then return false end
        end
        return true
    end)
end

local excl_session = nil
local EXCL_PARAMS = { "excluded_tags", "exclude_tags", "excludedTags", "excluded", "exclude" }

-- Renvoie le NOM du paramètre d'exclusion de tags (la valeur « id,id » est ajoutée par l'appelant).
local function resolve_excl(csv)
    local known = resolved("excl")
    if known then return known end
    if excl_session then return excl_session end
    local ids = {}
    for id in csv:gmatch("[^,]+") do ids[id] = true end
    local function has_bad(items)
        for _, it in ipairs(items) do
            if type(it.tags) == "table" then
                for _, t in ipairs(it.tags) do
                    if type(t) == "table" and ids[tostring(t.id or t._id or "")] then return true end
                end
            end
        end
        return false
    end
    local base = base_params({}, 1)
    local urls = { adv_url(base) }
    for _, p in ipairs(EXCL_PARAMS) do urls[#urls + 1] = adv_url(base, { p .. "=" .. csv }) end
    local res = json_many(urls, 3)
    -- Vérifiable seulement si la page SANS exclusion contient bien un titre portant l'un de ces tags.
    if is_data(res[1]) and has_bad(res[1].data) then
        for i, p in ipairs(EXCL_PARAMS) do
            local d = res[i + 1]
            if is_data(d) and #d.data > 0 and not has_bad(d.data) then
                RESOLVED["excl"] = p
                res_save()
                return p
            end
        end
        dump_error("MangaBall : paramètre d'exclusion de tags non confirmé (1er candidat utilisé, "
            .. "résultats re-filtrés localement).", table.concat(urls, "\n"))
        RESOLVED["excl"] = "!" .. os.time() .. "!" .. EXCL_PARAMS[1]
        res_save()
    end
    excl_session = EXCL_PARAMS[1]
    return EXCL_PARAMS[1]
end

local function has_filters(f)
    f = f or {}
    if (f.sort and f.sort ~= "lastupdate") or (f.order and f.order ~= "") then return true end
    for _, k in ipairs({ "status", "origin", "demo", "tag_excl", "tag_genre", "tag_theme",
        "tag_format", "tag_content" }) do
        if f[k] and f[k] ~= "" then return true end
    end
    return false
end

local function adv_params(f, page)
    f = f or {}
    local q = base_params(f, page)
    local sort = f.sort or "lastupdate"
    local rule = SORT_RULES[sort]
    local order = (f.order and f.order ~= "") and f.order or (rule and rule.dir or "desc")
    q[#q + 1] = rule and resolve_sort(sort) or "sort_by=lastupdate"
    q[#q + 1] = "sort_order=" .. order
    if f.status and f.status ~= "" then
        q[#q + 1] = (f.status == "ongoing") and "status=ongoing" or resolve_status(f.status)
    end
    if f.origin and ORIGIN[f.origin] then q[#q + 1] = resolve_origin(f.origin) end
    if f.demo and DEMO_OK[f.demo] then q[#q + 1] = resolve_demo(f.demo) end
    local ex = tostring(f.tag_excl or "")
    if ex ~= "" then q[#q + 1] = resolve_excl(ex) .. "=" .. ex end
    return q
end

-- Filet de sécurité : re-filtre chaque page d'après les champs du résultat (inoffensif si le
-- serveur a déjà filtré ; garde le bon résultat si un paramètre n'a pas pu être confirmé).
local function post_filter(items, f)
    f = f or {}
    local inc, exc = included_ids(f), {}
    for id in tostring(f.tag_excl or ""):gmatch("[^,]+") do exc[#exc + 1] = id end
    local any_mode = f.tagmode == "OR"
    local out = {}
    for _, it in ipairs(items) do
        local keep = type(it) == "table" and not is_adult(it)
        if keep and f.origin and ORIGIN[f.origin] and type(it.originalLanguage) == "string"
            and it.originalLanguage ~= ORIGIN[f.origin].lang then keep = false end
        if keep and f.demo and DEMO_OK[f.demo]
            and tostring(it.publicationDemographic or ""):lower() ~= f.demo then keep = false end
        if keep and f.status and STATUS_OK[f.status] and type(it.status) == "string"
            and not STATUS_OK[f.status][it.status:lower()] then keep = false end
        if keep and type(it.tags) == "table" and (#inc > 0 or #exc > 0) then
            local set = {}
            for _, t in ipairs(it.tags) do
                if type(t) == "table" then set[tostring(t.id or t._id or "")] = true end
            end
            if #inc > 0 then
                local hit = 0
                for _, id in ipairs(inc) do if set[id] then hit = hit + 1 end end
                if (any_mode and hit == 0) or (not any_mode and hit < #inc) then keep = false end
            end
            for _, id in ipairs(exc) do if set[id] then keep = false end end
        end
        if keep then out[#out + 1] = it end
    end
    return out
end

local function same_lang(l, want)
    l = tostring(l or ""):lower()
    return l == want or (want == "pt-br" and l == "pt_br")
end

-- Langue : le résultat donne availableTranslatedLanguages, pas besoin d'une requête par série.
-- Aucun résultat dans la langue → la page est gardée telle quelle (comme avant).
local function lang_filter_items(items, lang)
    local kept = {}
    for _, it in ipairs(items) do
        local av = type(it) == "table" and it.availableTranslatedLanguages
        if type(av) ~= "table" then
            kept[#kept + 1] = it
        else
            for _, l in ipairs(av) do
                if same_lang(l, lang) then kept[#kept + 1] = it; break end
            end
        end
    end
    return #kept > 0 and kept or items
end

local function adv_get(f, page, extra)
    local d, err = json_get(adv_url(adv_params(f, page), extra))
    if is_data(d) then return d end
    return nil, err or "réponse inattendue"
end

-- ── Découverte des étiquettes (id) ───────────────────────────────────────────
-- Aucun point d'accès « liste des tags » n'a été relevé : on lit les étiquettes portées par les
-- résultats de recherche (id, name, group), à partir des tags connus puis de ceux découverts.
-- Fait une fois (résultat gardé sur disque), refait au plus une fois par semaine si la liste est incomplète.
local TAG_HUBS = { "romance", "comedy", "drama", "sliceoflife", "action", "adventure", "fantasy",
    "horror", "mystery", "psychological", "thriller", "historical", "tragedy", "schoollife",
    "martialarts", "survival", "postapocalyptic", "videogames", "genderswap", "mafia",
    "villainess", "harem", "longstrip", "fullcolor", "webcomic", "adaptation", "magic", "supernatural" }

local function harvest(d)
    local added = 0
    if is_data(d) then
        for _, it in ipairs(d.data) do
            if type(it) == "table" and type(it.tags) == "table" then
                for _, t in ipairs(it.tags) do
                    if type(t) == "table" and add_tag(t.id or t._id, t.name, t.group) then added = added + 1 end
                end
            end
        end
    end
    return added
end

local function discover_tags()
    local last = tonumber(settings_get("mangaball_tags_scan")) or 0
    if TAG_N >= #TAG_EXPECTED - 3 then return end
    if TAG_N > TAG_N_SEED and os.time() - last < 7 * 86400 then return end

    local used, urls = {}, {}
    for p = 1, 4 do urls[#urls + 1] = adv_url(base_params({}, p)) end
    for _, hub in ipairs(TAG_HUBS) do
        for id, t in pairs(TAGS) do
            if nkey(t.name) == hub then
                used[id] = true
                urls[#urls + 1] = adv_url(base_params({ tag_genre = id }, 1))
                break
            end
        end
    end
    for _, d in pairs(json_many(urls, 6)) do harvest(d) end

    -- 2e tour : les étiquettes découvertes servent à leur tour de point de départ
    -- (inutile si le 1er tour a déjà tout trouvé).
    local urls2 = {}
    for _, e in ipairs(sorted_tags(nil)) do
        if TAG_N >= #TAG_EXPECTED - 3 then break end
        if not used[e.id] and #urls2 < 24 then
            used[e.id] = true
            urls2[#urls2 + 1] = adv_url(base_params({ tag_genre = e.id }, 1))
        end
    end
    if #urls2 > 0 then
        for _, d in pairs(json_many(urls2, 3)) do harvest(d) end
    end

    rebuild_tag_options()
    tags_save()
    settings_set("mangaball_tags_scan", os.time())

    local have, miss = {}, {}
    for _, t in pairs(TAGS) do have[nkey(t.name)] = true end
    for _, n in ipairs(TAG_EXPECTED) do
        if not have[nkey(n)] then miss[#miss + 1] = n end
    end
    if #miss > 0 then
        dump_error("MangaBall : " .. #miss .. " étiquette(s) du site sans id découvert : "
            .. table.concat(miss, ", "), "")
    end
end

function ext:loadFilters()
    pcall(discover_tags)
    self.filters_ready = true
end

function ext:popularNovels(page, options)
    page = tonumber(page) or 1
    local f = (options and options.filters) or {}
    local lang = lang_of(options)
    local data, err = adv_get(f, page)
    if not data then
        dump_error("MangaBall : recherche avancée échouée (page " .. page .. ") : " .. tostring(err), "")
        if has_filters(f) then
            return { novels = {}, error = T("MangaBall injoignable (filtres). Voir sefirah/mangaball_last_error.txt") }
        end
        -- Pas de repli HTML : il n'expose pas les champs de classification 18+.
        return { novels = {}, error = T("MangaBall : catalogue indisponible ; liste masquée par sécurité.") }
    end
    if #data.data == 0 then return { novels = {} } end
    local items = post_filter(data.data, f)
    if #items == 0 then
        return { novels = {}, error = T("MangaBall : aucun titre de cette page ne correspond aux filtres.") }
    end
    local novels = convert_items(lang_filter_items(items, lang), lang, nil)
    pcall(fill_covers, novels)
    return { novels = novels }
end

local adv_search_param = saved_param("mangaball_asp")   -- idem pour search-advanced (gardé sur disque)

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if term == "" then return ext:popularNovels(page, options) end
    page = tonumber(page) or 1
    local f = (options and options.filters) or {}
    local filtered = has_filters(f)

    -- Avec des filtres : recherche avancée (mot cherché + filtres) ; sans : recherche simple d'origine.
    local function build(param)
        -- Même la recherche simple doit passer par l'API avancée : adult_mode=no_18
        -- y est ajouté systématiquement par base_params().
        return adv_url(adv_params(f, page), { param .. "=" .. url_encode(term) })
    end

    local remembered = filtered and adv_search_param or search_param
    local order = {}
    if remembered then order[1] = remembered end
    for _, p in ipairs(SEARCH_PARAMS) do
        if p ~= remembered then order[#order + 1] = p end
    end

    -- Nom inconnu : les candidats sont interrogés EN MÊME TEMPS (au lieu de 9 requêtes à la suite).
    local pre
    if not remembered then
        local reqs = {}
        for _, p in ipairs(order) do
            reqs[#reqs + 1] = { key = p, url = build(p), headers = {
                ["User-Agent"] = UA, ["Accept"] = "application/json",
                ["Referer"] = BASE .. "/", ["Origin"] = BASE } }
        end
        pre = fetch_many(reqs, #reqs, 25)
        if next(pre) == nil then pre = nil end
    end

    local log, structure_ok = {}, false
    for _, param in ipairs(order) do
        local url = build(param)
        local data, err
        if pre then
            local body = pre[param]
            data = body and json_decode(body)
            err = body and "JSON illisible" or "pas de réponse"
        else
            data, err = json_get(url)
        end
        if data and type(data.data) == "table" then
            structure_ok = true
            local matched = false
            for _, it in ipairs(data.data) do
                if type(it) == "table" and item_matches(it, term) then matched = true; break end
            end
            if matched then
                if filtered then
                    adv_search_param = param; settings_set("mangaball_asp", param)
                else
                    search_param = param; settings_set("mangaball_sp", param)
                end
                local lang = lang_of(options)
                if filtered then
                    local items = lang_filter_items(post_filter(data.data, f), lang)
                    local kept = convert_items(items, lang, term)
                    pcall(fill_covers, kept)
                    return { novels = kept }
                end
                local has_field = false
                for _, it in ipairs(data.data) do
                    if type(it) == "table" and type(it.availableTranslatedLanguages) == "table" then has_field = true; break end
                end
                local kept
                if has_field then
                    kept = convert_items(lang_filter_items(data.data, lang), lang, term)
                else
                    local all = convert_items(data.data, lang, term)
                    kept = filter_by_lang(all, lang)
                    kept = #kept > 0 and kept or all
                end
                pcall(fill_covers, kept)
                return { novels = kept }
            end
            local total = type(data.pagination) == "table" and data.pagination.total or "?"
            log[#log + 1] = url .. "\n  → réponse valide mais aucun résultat ne contient le mot (total " .. tostring(total) .. ")"
            if remembered == param then
                -- paramètre déjà validé : simple absence de résultats (ou fin de la pagination)
                return { novels = {} }
            end
        else
            log[#log + 1] = url .. "\n  → " .. tostring(err)
        end
    end
    dump_error("recherche « " .. term .. " » : aucun paramètre n'a donné de résultat\n\n" .. table.concat(log, "\n"), "")
    if page > 1 then return { novels = {} } end
    if structure_ok then
        return { novels = {}, error = T("MangaBall : aucun résultat (ou paramètre de recherche inconnu, voir sefirah/mangaball_last_error.txt)") }
    end
    return { novels = {}, error = T("MangaBall injoignable. Voir sefirah/mangaball_last_error.txt") }
end

-- ── Fiche + chapitres ────────────────────────────────────────────────────────
-- Liste des chapitres : API du site (relevée le 2026-10-22) :
--   GET api.mangaball.com/api/v1/title/chapter-listing?title_id=<id>&page=<n>&limit=<k>
--       &group_by=chapter_number&sort_order=asc&language=<code>&search=&user_id=
--   → { data = [traductions], grouped_data = [{chapter_number, releases}], pagination = { total_pages } }
-- Une page = « limit » numéros de chapitre ; « total » = nombre de numéros distincts.
local function api_get(query, retries)
    local url = API .. query
    local body, code = require("core.net").get(url, { headers = {
        ["User-Agent"] = UA, ["Accept"] = "application/json",
        ["Referer"] = BASE .. "/", ["Origin"] = BASE,
    }, timeout = 20, retries = retries })
    if not body then
        last_http = tostring(code)
        dump_error("API échouée : " .. url .. "\ncode : " .. tostring(code), "")
        return nil
    end
    local data = json_decode(body)
    if type(data) ~= "table" then dump_error("JSON illisible : " .. url, body) end
    return data
end

local function lang_ok(l, want)
    l = tostring(l or ""):lower()
    if l == want then return true end
    return want == "pt-br" and l == "pt_br"
end

-- Taille de page : on essaie 100, puis on descend si l'API refuse (le site lui-même demande 5).
-- Si l'API plafonne la taille (pagination.limit renvoyé < demandé), on adopte la valeur renvoyée.
local LIMITS = { 100, 50, 20, 5 }
local good_limit = tonumber(settings_get("mangaball_gl"))   -- taille de page acceptée par l'API (gardée sur disque)
if good_limit and good_limit < 1 then good_limit = nil end
local CH_CACHE = {}           -- « id|langue » → chapitres (évite de tout recharger)
local META_CACHE = {}         -- chemin de base → fiche
local TOTALS = {}             -- « id|langue » → { api = total API, count = chapitres obtenus }
local LAST_API = {}           -- « id|langue » → { n = total API, t = heure }

-- Fiabilité des hébergeurs : « comick » est servi derrière une protection Cloudflare (page
-- « Just a moment… », HTTP 403) que la liseuse ne peut pas passer → on le prend en DERNIER recours.
-- « mangadot » passe en dernier recours : sur certaines séries (ex. Code Geass, chapitres 1-2 et 4) il
-- renvoie les pages d'un AUTRE manga rangé sous le bon identifiant (57 pages au lieu de 25-29), et le
-- contrôle d'identifiant de série ne peut pas le voir. mangadex / mangakatana passent avant.
local function site_rank(site)
    site = tostring(site or ""):lower()
    if site == "mangadex" then return 0 end
    if site == "mangakatana" then return 1 end
    if site == "mangadot" then return 8 end   -- groupe « Ho-oh » : dernier recours (choisissable à la main)
    if site == "comick" then return 9 end
    return 5
end

local function release_of(r)
    return { id = tostring(r.id), number = sv(r.number) or sv(r.chapter_number) or "0",
        volume = sv(r.volume) or "0", site = sv(r.site) or "", lang = sv(r.lang) or "",
        name = sv(r.name) }
end

local function release_path(rel, tid, alts)
    local p = table.concat({ rel.id .. "?chapter=" .. rel.number, tid or "", rel.volume, rel.site, rel.lang }, "|")
    if alts and #alts > 0 then
        local a = {}
        for _, x in ipairs(alts) do a[#a + 1] = table.concat({ x.id, x.volume, x.site, x.lang }, "~") end
        p = p .. "|" .. table.concat(a, ";")
    end
    return p
end


-- Certaines traductions d'un « chapitre N » sont en réalité un TOME entier (ex. « Chapter 6 » = tome 6,
-- 91 pages). On les met en dernier choix quand une autre traduction existe (heuristique : nom ou
-- numéro de volume ; non vérifié sur les données réelles).
local function is_volume_release(r)
    local nm = tostring(r.name or ""):lower()
    if nm:find("tome", 1, true) or nm:find("volume", 1, true) or nm:find("vol%.") or nm:find("book", 1, true) then
        return true
    end
    -- Le champ « volume » de MangaBall est le tome qui contient le chapitre (mangadex : 1, 2, 3…), pas
    -- un signe de tome complet : il ne doit pas pénaliser la traduction.
    return false
end
local function rel_rank(r) return site_rank(r.site) + (is_volume_release(r) and 20 or 0) end

-- Regroupe les traductions par numéro de chapitre.
local function new_grouper(lang)
    local st = { groups = {}, order = {} }
    local function take(r)
        if type(r) == "table" and r.id and lang_ok(r.lang, lang) then
            local num = tonumber(r.number) or tonumber(r.chapter_number)
            local key = tostring(num or r.id)
            local g = st.groups[key]
            if not g then
                g = { num = num, rels = {}, ids = {} }
                st.groups[key] = g
                st.order[#st.order + 1] = key
            end
            if not g.ids[tostring(r.id)] then   -- même traduction vue deux fois
                g.ids[tostring(r.id)] = true
                g.rels[#g.rels + 1] = release_of(r)
            end
        end
    end
    function st.feed(data)
        for _, r in ipairs(data.data) do
            take(r)
            if type(r) == "table" and type(r.releases) == "table" then
                for _, x in ipairs(r.releases) do take(x) end
            end
        end
        if type(data.grouped_data) == "table" then
            for _, gd in ipairs(data.grouped_data) do
                if type(gd) == "table" and type(gd.releases) == "table" then
                    for _, x in ipairs(gd.releases) do take(x) end
                end
            end
        end
    end
    function st.count() return #st.order end
    function st.build(tid)
        local chapters = {}
        for _, key in ipairs(st.order) do
            local g = st.groups[key]
            table.sort(g.rels, function(a, b) return rel_rank(a) < rel_rank(b) end)
            local best = table.remove(g.rels, 1)
            local label = "Chapter " .. best.number
            local nm = best.name
            -- on ignore les noms génériques en majuscules (« MANGA PLUS », « SCAN »)
            if nm and not nm:find("%d") and nm:find("%l") then label = label .. " — " .. nm end
            chapters[#chapters + 1] = { name = label, path = release_path(best, tid, g.rels),
                chapter_number = g.num or #chapters + 1, rtl = false }
        end
        table.sort(chapters, function(x, y) return (x.chapter_number or 0) < (y.chapter_number or 0) end)
        return chapters
    end
    return st
end

local function valid(d) return type(d) == "table" and type(d.data) == "table" end

-- Page 1 (sert aussi à négocier la taille de page). Renvoie data, limite_effective.
local function first_page(tid, server_lang, order)
    local tries = good_limit and { good_limit } or LIMITS
    for i, lim in ipairs(tries) do
        local data = api_get(listing_query(tid, 1, lim, order, server_lang),
            (not good_limit and i < #tries) and 0 or nil)
        if valid(data) then
            local pg = type(data.pagination) == "table" and data.pagination or {}
            local eff = tonumber(pg.limit)
            if eff and eff > 0 and eff < lim then lim = eff end   -- l'API plafonne la taille
            if good_limit ~= lim then settings_set("mangaball_gl", lim) end
            good_limit = lim
            return data, lim
        end
    end
    return nil
end

-- Renvoie chapitres, statut ("ok" | "incomplete" | "failed").
local function fetch_chapters(tid, lang, server_lang)
    local srv = server_lang or lang
    local data, limit = first_page(tid, srv, "asc")
    if not data then return {}, "failed" end
    local st = new_grouper(lang)
    st.feed(data)
    local pg = type(data.pagination) == "table" and data.pagination or {}
    local total_pages = tonumber(pg.total_pages) or 1
    local status = "ok"
    if total_pages > 1 and #data.data > 0 then
        total_pages = math.min(total_pages, 600)
        -- Pages 2…N en parallèle (6 à la fois) ; repli séquentiel pour celles qui manquent.
        local reqs = {}
        for n = 2, total_pages do
            reqs[#reqs + 1] = { key = n, url = API .. listing_query(tid, n, limit, "asc", srv) }
        end
        local bodies = fetch_many(reqs, 10, 45)
        for n = 2, total_pages do
            local d = bodies[n] and json_decode(bodies[n])
            if not valid(d) then d = api_get(listing_query(tid, n, limit, "asc", srv)) end
            if valid(d) then st.feed(d) else status = "incomplete" end
        end
    end
    local chapters = st.build(tid)
    if status == "ok" and not server_lang then
        TOTALS[tid .. "|" .. lang] = { api = tonumber(pg.total), count = #chapters }
    end
    return chapters, status
end

-- Nombre de chapitres actuel côté API (1 seule requête légère).
local function api_total(tid, lang)
    local key = tid .. "|" .. lang
    local d = api_get(listing_query(tid, 1, 1, "desc", lang), 0)
    if not valid(d) then return nil end
    local pg = type(d.pagination) == "table" and d.pagination or {}
    local n = tonumber(pg.total) or #d.data
    LAST_API[key] = { n = n, t = os.time() }
    return n
end

local function parse_meta(html, path)
    local m = { path = path, type = "manga" }
    local h1 = html:match("<h1[^>]*>(.-)</h1>")
    m.name = h1 and text_of(h1) or path
    m.cover = abs(html:match('<meta[^>]-property%s*=%s*"og:image"[^>]-content%s*=%s*"([^"]*)"')
        or html:match('<meta[^>]-content%s*=%s*"([^"]*)"[^>]-property%s*=%s*"og:image"'))
    local st = html:match("Publication Status:%s*<strong[^>]*>(.-)</strong>")
    st = st and text_of(st):lower() or ""
    m.status = (st == "completed" or st == "finished") and "Completed"
        or (st == "ongoing") and "Ongoing" or "Unknown"
    local au = html:match("Author:%s*<strong[^>]*>(.-)</strong>")
    if au then
        -- « Oda Eiichiro, Oda Eiichiro » : on retire les doublons.
        local seen, list = {}, {}
        for a_raw in text_of(au):gmatch("[^,]+") do
            local a = a_raw:match("^%s*(.-)%s*$")
            if a ~= "" and not seen[a] then seen[a] = true; list[#list + 1] = a end
        end
        m.author = table.concat(list, ", ")
    else
        m.no_author = true
    end
    local genres, gseen = {}, {}
    for a_tag, inner in html:gmatch("(<a%s[^>]-href%s*=%s*[^>]->)(.-)</a>") do
        local href = attr(a_tag, "href") or ""
        if href:find("included_tags=", 1, true) then
            local g = text_of(inner)
            if g ~= "" and not gseen[g] then gseen[g] = true; genres[#genres + 1] = g end
        end
    end
    m.genres = genres

    -- MangaBall est rendu par Next.js : la description n'est pas forcément présente
    -- dans le HTML sous forme de balise <meta> classique. Elle est souvent incluse
    -- dans le flux JSON hydraté (__next_f.push) sous name="description".
    local description
    local function usable_description(v)
        if not v then return nil end
        v = tostring(v)
        v = v:gsub("\\\\n", " "):gsub("\\\\r", " "):gsub("\\\\t", " ")
             :gsub("\\\\u0026", "&"):gsub("\\\\/", "/")
        v = decode(v)
        v = v:gsub("%s+", " "):match("^%s*(.-)%s*$")
        if not v or v == "" then return nil end
        if v:lower() == (m.name or ""):lower() then return nil end
        return v
    end

    -- Priorité au texte complet de la fiche : les balises meta ne contiennent
    -- qu'un extrait SEO se terminant par « ... ».
    -- MangaBall affiche la description complète dans un paragraphe line-clamp-3.
    for tag, inner in html:gmatch('(<p%s[^>]-line%-clamp%-3[^>]*>)(.-)</p>') do
        local candidate = usable_description(text_of(inner))
        if candidate and #candidate > 80 then
            description = candidate
            break
        end
    end

    -- Certaines versions embarquent aussi la description complète dans les données
    -- de l'API sérialisées dans la page, sous description:["…"].
    if not description then
        local raw = html:match([=["description"%s*:%s*%[%s*"(.-)"%s*%]]=])
        if raw then description = usable_description(raw) end
    end

    -- Cas HTML classique : utile en dernier recours, mais souvent tronqué par le site.
    if not description then
        for tag in html:gmatch("<meta[^>]*>") do
            local meta_name = attr(tag, "name") or attr(tag, "property") or ""
            if meta_name:lower() == "description" or meta_name:lower() == "og:description" then
                description = usable_description(attr(tag, "content"))
                if description then break end
            end
        end
    end

    -- Ancien flux Next.js sérialisé, pour compatibilité avec les anciennes pages.
    if not description then
        local raw = html:match([=[\"name\":\"description\",\"content\":\"(.-)\"]=])
        if not raw then
            raw = html:match([=[\"property\":\"og:description\",\"content\":\"(.-)\"]=])
        end
        description = usable_description(raw)
    end

    -- Ancien format de fiche, conservé en dernier recours.
    if not description then
        local p = html:match("You are reading%s*<strong[^>]*>.-</strong>(.-)</p>")
        description = p and usable_description(text_of(p):gsub("^%(Alternative Titles:.-%)", "")) or nil
    end
    m.summary = description or ""
    return m
end

local function fetch_meta(path)
    local base = split_path(path)
    if META_CACHE[base] then return META_CACHE[base] end
    local html = get_html("/title-detail/" .. base)
    if not html then return nil end
    local m = parse_meta(html, path)
    META_CACHE[base] = m
    return m
end

local function chapters_for(base, lang)
    local tid = base:match("^(%x+)")
    if not tid then return {}, "failed" end
    local key = tid .. "|" .. lang
    if CH_CACHE[key] then return CH_CACHE[key], "ok" end
    local chapters, status = fetch_chapters(tid, lang)
    -- Repli sans filtre de langue UNIQUEMENT si l'API n'a pas répondu (une réponse vide valide
    -- = aucune traduction dans cette langue ; recharger toutes les langues serait très lent).
    if status == "failed" then chapters, status = fetch_chapters(tid, lang, "") end
    if #chapters == 0 and status == "ok" then
        dump_error("fiche sans chapitre : " .. base .. " (langue " .. tostring(lang) .. ")", "")
    end
    if #chapters > 0 and status == "ok" then CH_CACHE[key] = chapters end
    return chapters, status
end

-- Popularité (classement communautaire) : file locale, aucune requête réseau ; dédoublonné sur 24 h.
local function track_work(m, base)
    local ok_lb, Leaderboard = pcall(require, "core/leaderboard")
    if ok_lb and Leaderboard and Leaderboard.queueWork then
        pcall(Leaderboard.queueWork, { title = m.name or m.title or base, source = "MangaBall", work_id = base, kind = "manga" })
    end
end

-- Métadonnées + NOMBRE DE CHAPITRES (2 requêtes légères). Avant, total_chapters valait toujours 0 :
-- la fiche ne pouvait donc jamais réutiliser sa liste en cache et rechargeait tout à chaque ouverture.
-- Fiche HTML + nombre de chapitres chargés EN MÊME TEMPS (au lieu de l'un après l'autre).
local function prefetch_meta(path, base, tid, lang)
    if not tid or META_CACHE[base] then return end
    local la = LAST_API[tid .. "|" .. lang]
    if la and os.time() - la.t < 120 then return end
    local b = fetch_many({
        { key = "html", url = BASE .. "/title-detail/" .. base, headers = HTML_HEADERS },
        { key = "api", url = API .. listing_query(tid, 1, 1, "desc", lang), headers = {
            ["User-Agent"] = UA, ["Accept"] = "application/json",
            ["Referer"] = BASE .. "/", ["Origin"] = BASE } },
    }, 2, 25)
    if b.html and #b.html > 100 then
        local ok, m = pcall(parse_meta, b.html, path)
        if ok and m then META_CACHE[base] = m end
    end
    if b.api then
        local d = json_decode(b.api)
        if valid(d) then
            local pg = type(d.pagination) == "table" and d.pagination or {}
            LAST_API[tid .. "|" .. lang] = { n = tonumber(pg.total) or #d.data, t = os.time() }
        end
    end
end

function ext:parseNovelMeta(path)
    do
        local base0, lang0 = split_path(path, lang_of())
        pcall(prefetch_meta, path, base0, base0:match("^(%x+)"), lang0)
    end
    local m = fetch_meta(path)
    if not m then return nil end
    local c = {}
    for k, v in pairs(m) do c[k] = v end
    local base, lang = split_path(path, lang_of())
    local tid = base:match("^(%x+)")
    local total = 0
    if tid then
        local la = LAST_API[tid .. "|" .. lang]
        local n = (la and os.time() - la.t < 120) and la.n or api_total(tid, lang)
        if n and n > 0 then
            local t = TOTALS[tid .. "|" .. lang]
            total = (t and t.api == n) and t.count or n
        end
    end
    c.total_chapters = total
    track_work(c, base)
    return c
end

-- Mise à jour incrémentale : seuls les chapitres à partir du n-ième (ordre croissant) — les plus
-- récents — sont téléchargés (pages triées du plus récent au plus ancien, arrêt dès que c'est couvert).
function ext:parseChaptersFrom(path, offset)
    local base, lang = split_path(path, lang_of())
    local tid = base:match("^(%x+)")
    if not tid then return { failed = true } end
    offset = tonumber(offset) or 0
    local la = LAST_API[tid .. "|" .. lang]
    local total = (la and os.time() - la.t < 120) and la.n or api_total(tid, lang)
    if not total then return { failed = true } end
    local count = total - offset
    if count <= 0 then return { chapters = {} } end
    local data, limit = first_page(tid, lang, "desc")
    if not data then return { failed = true } end
    local st = new_grouper(lang)
    st.feed(data)
    local pg = type(data.pagination) == "table" and data.pagination or {}
    local total_pages = tonumber(pg.total_pages) or 1
    local n = 1
    while st.count() < count and n < total_pages do
        n = n + 1
        local d = api_get(listing_query(tid, n, limit, "desc", lang))
        if not valid(d) then return { failed = true } end
        st.feed(d)
    end
    local all = st.build(tid)
    local chapters = {}
    for i = math.max(1, #all - count + 1), #all do chapters[#chapters + 1] = all[i] end
    return { chapters = chapters }
end

-- Une « page » = 1 chapitre (chapters_per_page = 1) ; utilisée seulement si parseChaptersFrom manque.
function ext:parsePage(path, page)
    local r = ext:parseChaptersFrom(path, (tonumber(page) or 1) - 1)
    if r.failed then return { chapters = {}, failed = true } end
    return { chapters = { r.chapters[1] } }
end

function ext:parseNovel(path, options)
    local base, lang = split_path(path, lang_of(options))
    local m0 = fetch_meta(path)
    if not m0 then
        logger.err("MangaBall: fiche introuvable", tostring(path))
        return nil
    end
    local m = {}
    for k, v in pairs(m0) do m[k] = v end
    track_work(m, base)
    local chapters, status = chapters_for(base, lang)
    m.chapters = chapters
    m.totalPages = 1
    if status ~= "ok" then m.incomplete = true end   -- ne pas mettre en cache une liste partielle
    if #chapters == 0 and status == "ok" then
        m.summary = string.format(T("⚠ Aucun chapitre disponible en « %s » (essayez une autre langue dans le filtre)."), lang)
            .. "\n\n" .. (m.summary or "")
    end
    return m
end

-- ── Pages d'un chapitre ──────────────────────────────────────────────────────
-- Adresse d'une page : <CDN>/storage/<id-série>/<volume>/<n°>/<site>/<langue>/<id-chapitre>-001.webp
-- (vérifié pour le site « mangadot »). Le DOM du lecteur n'a que les premières images, la suite est
-- chargée par JS : on complète d'après « Page N of M » ; à défaut on essaie les numéros suivants.
local HDRS = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/",
    ["Accept"] = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
    ["Accept-Language"] = "en-US,en;q=0.8" }

-- Une image n'est acceptée que si son chemin identifie exactement la série, le chapitre,
-- le site et la langue demandés. Cela évite qu'une page hydratée mélange des séries/chapitres.
local function belongs_to_release(u, cid, num, tid, vol, site, lang)
    if not (cid and cid ~= "" and tid and tid ~= "" and site and site ~= "" and lang and lang ~= "") then return false end
    local p_tid, p_vol, p_num, p_site, p_lang, filename = tostring(u):match(
        "/storage/([^/]+)/([^/]+)/([^/]+)/([^/]+)/([^/]+)/([^/?#]+)")
    if not p_tid then return false end
    if p_tid ~= tid or p_site ~= site or p_lang ~= lang then return false end
    if vol and vol ~= "" and p_vol ~= vol then return false end
    if num and num ~= "" and p_num ~= num then return false end
    if filename:sub(1, #cid) ~= cid or filename:sub(#cid + 1, #cid + 1) ~= "-" then return false end
    return true
end

-- Charge les adresses d'images d'UNE traduction. Renvoie images, html (ou nil, raison).
local function load_release(cid, num, tid, vol, site, lang)
    local html = get_html("/chapter-detail/" .. cid .. "?chapter=" .. tostring(num or ""))
    if not html then return nil, "chapter_unreachable" end
    local flat = html:gsub("\\/", "/")
    local clean = flat:gsub("<!%-%-.-%-%->", "")   -- React insère des <!-- --> dans « Page 7 of 10 »
    local images, seen = {}, {}
    local function add(u)
        u = abs(u)
        if u and not seen[u] then seen[u] = true; images[#images + 1] = u end
    end
    -- 1) Liste COMPLÈTE dans le JSON Next.js : \"pages\":[\"https://…-001.webp\",…]
    for blob in flat:gmatch('\\"pages\\":%[(.-)%]') do
        for u in blob:gmatch('https?://[^"\\%s]+') do
            if u:find("/storage/", 1, true) then add(u) end
        end
        if #images > 0 then break end
    end
    if #images == 0 then
        for blob in flat:gmatch('"pages":%[(.-)%]') do
            for u in blob:gmatch('https?://[^"\\%s]+') do
                if u:find("/storage/", 1, true) then add(u) end
            end
            if #images > 0 then break end
        end
    end
    for tag in flat:gmatch("<img[^>]->") do
        local u = attr(tag, "src") or attr(tag, "data-src")
        if u and u:find("/storage/", 1, true) and u:match("%-%d+%.%w+$") then add(u) end
    end
    if #images == 0 then   -- JSON embarqué (Next.js)
        for u in flat:gmatch('https?://[%w%.%-]+/storage/[^"\'%s\\<>]-%-%d+%.%w+') do add(u) end
    end
    -- Garde-fou fail-closed : vérifier l'identifiant de série ET le chemin complet de la version.
    if #images > 0 then
        local mine, rejected = {}, {}
        for _, u in ipairs(images) do
            if belongs_to_release(u, cid, num, tid, vol, site, lang) then
                mine[#mine + 1] = u
            else
                rejected[#rejected + 1] = u
            end
        end
        if #rejected > 0 then
            dump_error("images ne correspondant pas à la série/au chapitre demandés : série " .. tostring(tid)
                .. ", chapitre " .. tostring(cid) .. " (n° " .. tostring(num) .. "), gardées " .. #mine
                .. ", rejetées " .. #rejected .. "\n" .. table.concat(rejected, "\n"), "")
        end
        images, seen = mine, {}
        for _, u in ipairs(images) do seen[u] = true end
    end
    local total = 0
    for n in clean:gmatch("Page %d+ of (%d+)") do total = math.max(total, tonumber(n) or 0) end
    for n in clean:gmatch(">%d+ / (%d+)<") do total = math.max(total, tonumber(n) or 0) end
    if #images == 0 and cid and tid and tid ~= "" and site ~= "" then   -- reconstruction
        local function url_of(i)
            return string.format("%s/storage/%s/%s/%s/%s/%s/%s-%03d.webp", CDN, tid,
                (vol ~= "" and vol or "0"), tostring(num), site, lang, cid, i)
        end
        local i = 1
        while i <= (total > 0 and total or 150) do
            local u = url_of(i)
            if total == 0 then   -- total inconnu : on s'arrête à la première page absente
                local body = require("core.net").get(u, { headers = HDRS, timeout = 15 })
                if not body or #body < 200 then break end
            end
            images[#images + 1] = u
            i = i + 1
        end
    elseif total > #images and #images > 0 then
        local prefix, digits, ext_ = images[1]:match("^(.-%-)(%d+)(%.%w+)$")
        if prefix then
            for i = #images + 1, total do
                images[i] = prefix .. string.format("%0" .. #digits .. "d", i) .. ext_
            end
        end
    end
    if #images == 0 then
        dump_error("chapitre sans image : " .. cid, html)
        return nil, "no_pages"
    end
    return images, html
end

-- Une image est-elle vraiment téléchargeable ? (Cloudflare renvoie 403 + page « Just a moment »,
-- un hébergeur peut aussi refuser le hotlink). Pas de mémoire par hébergeur : chaque traduction
-- est vérifiée sur sa 1re ET sa dernière page.
local function image_ok(u)
    local b, c, e = require("core.net").get(u, { headers = HDRS, timeout = 15, retries = 0 })
    if b and #b >= 256 and b:sub(1, 1) ~= "<" then return true end
    if tostring(c) == "429" then return true end   -- limite de débit du CDN : le serveur répond, ce n'est pas un refus
    dump_error("image injoignable : " .. u .. "\ncode : " .. tostring(c), type(e) == "string" and e or tostring(b or ""):sub(1, 3000))
    return false
end

-- Hébergeurs fiables (mangadex / mangakatana) : pas de contrôle préalable (il retéléchargeait une
-- image entière pour rien) ; un échec éventuel est rattrapé par la 2e passe lente du téléchargement.
-- Les hébergeurs risqués (comick = Cloudflare, mangadot) gardent le contrôle de la 1re page.
local function release_ok(images, site)
    if images == nil or #images == 0 then return false end
    if site_rank(site) <= 1 then return true end
    return image_ok(images[1])
end

-- ── Groupe de traduction choisi par l'utilisateur ───────────────────────────
-- Sur MangaBall, chaque « site » est un groupe : mangadex = Raikou, mangakatana = Tyranitar,
-- mangadot = Ho-oh. Le choix est gardé par manga (clé = id de la série) et appliqué au
-- téléchargement : « auto » (vide) = ordre habituel, sinon le groupe choisi passe en premier.
local SITE_LABEL = {
    mangadex    = "Raikou (MangaDex)",
    mangakatana = "Tyranitar (MangaKatana)",
    mangadot    = "Ho-oh (MangaDot)",
}
local function site_label(site)
    site = tostring(site or ""):lower()
    return SITE_LABEL[site] or (site:sub(1, 1):upper() .. site:sub(2))
end

local function group_setting(tid) return "mangaball_group_" .. tostring(tid or "") end

local function group_pref(tid)
    local v = settings_get(group_setting(tid))
    return type(v) == "string" and v or ""
end

local function tid_of(novel_path)
    return tostring(novel_path or ""):match("^(%x+)")
end

-- Groupes disponibles d'après les chapitres déjà chargés (chaque chemin de chapitre contient sa
-- traduction principale + les autres). Renvoie { { id, label, count } } trié par nom.
function ext:listGroups(chapters)
    local count, order = {}, {}
    local function note(site)
        site = tostring(site or ""):lower()
        if site == "" then return end
        if not count[site] then count[site] = 0; order[#order + 1] = site end
        count[site] = count[site] + 1
    end
    for _, ch in ipairs(chapters or {}) do
        local f = {}
        for part in (tostring(ch.path or "") .. "|"):gmatch("([^|]*)|") do f[#f + 1] = part end
        note(f[4])
        for item in (f[6] or ""):gmatch("[^;]+") do
            local _, _, s = item:match("^(%x+)~([^~]*)~([^~]*)~([^~]*)$")
            note(s)
        end
    end
    table.sort(order, function(a, b) return site_label(a):lower() < site_label(b):lower() end)
    local out = {}
    for _, site in ipairs(order) do out[#out + 1] = { id = site, label = site_label(site), count = count[site] } end
    return out
end

function ext:getGroup(novel_path)
    local tid = tid_of(novel_path)
    if not tid then return "" end
    return group_pref(tid)
end

function ext:setGroup(novel_path, site)
    local tid = tid_of(novel_path)
    if not tid then return false end
    settings_set(group_setting(tid), site or "")
    return true
end

function ext:groupLabel(site) return site_label(site) end

-- Appelé par core/manga.lua quand des pages restent introuvables : on note pourquoi (code HTTP du
-- serveur d'images) dans sefirah/mangaball_last_error.txt.
function ext:onDownloadFailed(info)
    pcall(function()
        info = info or {}
        local lines = { "téléchargement incomplet : " .. tostring(info.missing and #info.missing or "?")
            .. " page(s) sur " .. tostring(info.total) .. " — chapitre " .. tostring(info.chapter) }
        for k, u in ipairs(info.missing or {}) do
            if k > 4 then break end
            local b, c, e = require("core.net").get(u, { headers = HDRS, timeout = 15, retries = 0 })
            lines[#lines + 1] = "  " .. u .. "\n    → " .. (b and (#b .. " octets, début : " .. tostring(b):sub(1, 60):gsub("[%c]", " "))
                or ("échec, code " .. tostring(c)))
            if type(e) == "string" then lines[#lines + 1] = "    " .. e:sub(1, 300) end
        end
        dump_error(table.concat(lines, "\n"), "")
    end)
end

-- 1re passe RAPIDE (8 images à la fois, pause courte) ; seules les pages ratées (limite de débit du
-- CDN, 429/403) repassent en mode LENT (2 à la fois, pause 0,6 s) — l'ancien réglage appliqué à tout.
local FAST = { wave = 8, try_timeout = 20, pace = 0.1 }
local SLOW = { wave = 2, try_timeout = 30, pace = 0.6 }

function ext:parseChapterImages(path)
    path = tostring(path)
    local f = {}
    for part in (path .. "|"):gmatch("([^|]*)|") do f[#f + 1] = part end
    local cid, num = (f[1] or ""):match("^(%x+)%?chapter=(.*)$")
    cid = cid or (f[1] or ""):match("^(%x+)")
    local tid, vol, site, lang = f[2] or "", f[3] or "", f[4] or "", f[5] or ""
    -- Toutes les traductions de ce numéro : la principale d'abord, puis les autres hébergeurs.
    local cands = { { id = cid, vol = vol, site = site, lang = lang } }
    for item in (f[6] or ""):gmatch("[^;]+") do
        local id, v, s, l = item:match("^(%x+)~([^~]*)~([^~]*)~([^~]*)$")
        if id then cands[#cands + 1] = { id = id, vol = v, site = s, lang = l } end
    end
    -- Groupe choisi par l'utilisateur : ses traductions passent devant (ordre d'origine conservé).
    local pref = group_pref(tid)
    if pref ~= "" then
        local first, rest = {}, {}
        for _, c in ipairs(cands) do
            if tostring(c.site):lower() == pref then first[#first + 1] = c else rest[#rest + 1] = c end
        end
        if #first > 0 then
            cands = {}
            for _, c in ipairs(first) do cands[#cands + 1] = c end
            for _, c in ipairs(rest) do cands[#cands + 1] = c end
        end
    end

    local log = { "chapitre " .. tostring(num) .. " (groupe choisi : " .. (pref ~= "" and pref or "auto") .. ")" }
    local fallback, fallback_tag   -- 1re traduction chargée, gardée si aucune n'est vérifiée
    local last_why = "no_pages"
    for n, c in ipairs(cands) do
        local imgs, why = load_release(c.id, num, tid, c.vol, c.site, c.lang)
        if not imgs then
            last_why = why or last_why
            log[#log + 1] = "  " .. c.id .. " (" .. tostring(c.site) .. ") : illisible (" .. tostring(why) .. ")"
        else
            -- Un chapitre de plus de 40 pages est suspect (tome complet publié comme chapitre) : en mode
            -- auto on le garde seulement si aucune autre traduction n'est plus courte.
            local suspect = pref == "" and #imgs > 40 and n < #cands
            local ok = (not suspect) and release_ok(imgs, c.site)
            log[#log + 1] = "  " .. c.id .. " (" .. tostring(c.site) .. ") = " .. #imgs .. " pages"
                .. (suspect and " [suspect, trop long]" or (ok and " [ok]" or " [images injoignables]"))
            if ok then
                dump_error(table.concat(log, "\n"), "")
                return { images = imgs, headers = HDRS, wave = FAST.wave, try_timeout = FAST.try_timeout, pace = FAST.pace, slow = SLOW, tag = c.id }
            end
            if not fallback then fallback, fallback_tag = imgs, c.id end
        end
    end
    dump_error(table.concat(log, "\n"), "")
    if fallback then return { images = fallback, headers = HDRS, wave = FAST.wave, try_timeout = FAST.try_timeout, pace = FAST.pace, slow = SLOW, tag = fallback_tag } end
    return nil, last_why
end

function ext:parseChapter(path)
    return "<p>" .. T("Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.") .. "</p>"
end

return ext
