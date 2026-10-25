-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- core/translate.lua — traduction des chapitres (Google Traduction sans clé, DeepL Free ou Gemini avec clé).
-- Le chapitre original n'est jamais modifié : la traduction est stockée à côté
-- (cache par chapitre et par langue) et n'est donc faite qu'une seule fois.

local https  = require("ssl.https")
local ltn12  = require("ltn12")
local socket = require("socket")
local logger = require("logger")
local ok_json, JSON = pcall(require, "rapidjson")
if not ok_json then JSON = require("json") end
local Settings = require("sefirah_settings")
local Cache    = require("core.cache")

local Translate = {}

-- Gros blocs = moins d'allers-retours HTTPS (chacun coûte plusieurs secondes
-- sur une liseuse). Gemini Flash gère largement ~9000 caractères en sortie.
local CHUNK_CHARS = 9000
local MAX_TRIES   = 4

function Translate.enabled()
    -- Google Traduction fonctionne sans clé : seul le réglage compte.
    return Settings:get("translate_enabled") and true or false
end

function Translate.lang()
    local l = Settings:get("translate_lang")
    if type(l) ~= "string" or l == "" then return "français" end
    return l
end

-- Découpe le HTML en blocs ≤ CHUNK_CHARS en coupant après un </p>
-- (ou à défaut après un saut de ligne).

-- Entités HTML : le texte des chapitres contient des &#x27; &amp; etc. Envoyés tels
-- quels à Google, ils ressortaient doublement échappés et s'affichaient en clair
-- (« l&#x27;arcade »). On décode avant envoi, on ré-échappe après.
local function utf8_char(n)
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then
        return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
    end
    if n < 0x10000 then
        return string.char(0xE0 + math.floor(n / 0x1000),
            0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
    end
    return string.char(0xF0 + math.floor(n / 0x40000),
        0x80 + math.floor(n / 0x1000) % 0x40,
        0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
end

local NAMED_ENT = {
    nbsp = "\194\160", quot = '"', apos = "'", lt = "<", gt = ">",
    hellip = "\226\128\166", mdash = "\226\128\148", ndash = "\226\128\147",
    lsquo = "\226\128\152", rsquo = "\226\128\153",
    ldquo = "\226\128\156", rdquo = "\226\128\157",
    laquo = "\194\171", raquo = "\194\187",
}

local function decode_entities(s)
    s = s:gsub("&amp;(#x?%x+;)", "&%1")  -- double échappement éventuel
    s = s:gsub("&#[xX](%x+);", function(h) return utf8_char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8_char(tonumber(d)) end)
    s = s:gsub("&(%a+);", function(n) return NAMED_ENT[n] end)
    return (s:gsub("&amp;", "&"))
end

local function escape_text(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Répare une traduction déjà en cache (ou renvoyée par un moteur) dont les
-- entités numériques sont doublement échappées (&amp;#x27; -> &#x27;).
local function fix_double_escape(s)
    return (s:gsub("&amp;(#x?%x+;)", "&%1"))
end

function Translate.fix(s) return fix_double_escape(s) end

-- Découpe le HTML en blocs ≤ CHUNK_CHARS (voir ci-dessus)
local function split_chunks(html)
    local pieces = {}
    local pos = 1
    while pos <= #html do
        local s, e = html:find("</[pP]>", pos)
        if not s then
            pieces[#pieces + 1] = html:sub(pos)
            break
        end
        pieces[#pieces + 1] = html:sub(pos, e)
        pos = e + 1
    end
    if #pieces == 1 and #pieces[1] > CHUNK_CHARS then
        pieces = {}
        for line in (html .. "\n"):gmatch("(.-)\n") do pieces[#pieces + 1] = line .. "\n" end
    end
    local chunks, cur = {}, {}
    local len = 0
    for _, p in ipairs(pieces) do
        if len > 0 and len + #p > CHUNK_CHARS then
            chunks[#chunks + 1] = table.concat(cur)
            cur, len = {}, 0
        end
        cur[#cur + 1] = p
        len = len + #p
    end
    if len > 0 then chunks[#chunks + 1] = table.concat(cur) end
    return chunks
end

local function build_prompt(lang, context)
    return "Traduis ce HTML de roman web vers : " .. lang .. ". "
        .. "Langue d'origine détectée automatiquement ; si déjà en " .. lang .. ", renvoie tel quel. "
        .. "Traduction naturelle et fluide. Garde EXACTEMENT les mêmes balises HTML et le même nombre de paragraphes. "
        .. "Noms propres cohérents. Aucune note, aucun bloc Markdown : réponds uniquement avec le HTML.\n"
        .. (context ~= "" and ("Contexte (fin du passage précédent, ne pas retraduire) : " .. context .. "\n") or "")
        .. "HTML :\n"
end

-- Modèles essayés dans l'ordre. Google a retiré gemini-2.5-* (404 « no longer
-- available ») : on ignore donc tout modèle 1.x/2.x enregistré dans les réglages
-- et on enchaîne sur des modèles actuels si l'un répond 404.
local FALLBACK_MODELS = { "gemini-flash-latest", "gemini-3-flash-preview", "gemini-3.1-flash-lite" }

local function model_list()
    local list, seen = {}, {}
    local function add(m)
        if type(m) == "string" and m ~= "" and not seen[m] then
            seen[m] = true; list[#list + 1] = m
        end
    end
    local cfg = Settings:get("translate_model")
    if type(cfg) == "string" and not cfg:find("^gemini%-[12]%.") then add(cfg) end
    for _, m in ipairs(FALLBACK_MODELS) do add(m) end
    return list
end

local _good_model = nil  -- dernier modèle qui a répondu (évite de re-tester les 404)

-- DeepL API Free en priorité. DeepL offre une excellente qualité de traduction
-- avec un quota gratuit mensuel. L'URL api-free est utilisée par défaut.
-- Gemini reste disponible comme secours si une clé Gemini est configurée.
local DEEPL_LANGS = {
    {code="BG", label="Български (bulgare)"}, {code="CS", label="Čeština (tchèque)"},
    {code="DA", label="Dansk (danois)"}, {code="DE", label="Deutsch (allemand)"},
    {code="EL", label="Ελληνικά (grec)"}, {code="EN", label="English (anglais)"},
    {code="ES", label="Español (espagnol)"}, {code="ET", label="Eesti (estonien)"},
    {code="FI", label="Suomi (finnois)"}, {code="FR", label="Français"},
    {code="HU", label="Magyar (hongrois)"}, {code="ID", label="Bahasa Indonesia"},
    {code="IT", label="Italiano (italien)"}, {code="JA", label="日本語 (japonais)"},
    {code="KO", label="한국어 (coréen)"}, {code="LT", label="Lietuvių (lituanien)"},
    {code="LV", label="Latviešu (letton)"}, {code="NB", label="Norsk (norvégien)"},
    {code="NL", label="Nederlands (néerlandais)"}, {code="PL", label="Polski (polonais)"},
    {code="PT-BR", label="Português (Brésil)"}, {code="PT-PT", label="Português (Portugal)"},
    {code="RO", label="Română (roumain)"}, {code="RU", label="Русский (russe)"},
    {code="SK", label="Slovenčina (slovaque)"}, {code="SL", label="Slovenščina (slovène)"},
    {code="SV", label="Svenska (suédois)"}, {code="TR", label="Türkçe (turc)"},
    {code="UK", label="Українська (ukrainien)"}, {code="ZH", label="中文 (chinois)"}
}

local DEEPL_LABEL_TO_CODE = {}
for _, x in ipairs(DEEPL_LANGS) do DEEPL_LABEL_TO_CODE[x.label] = x.code end

function Translate.languages()
    return DEEPL_LANGS
end

local function target_code()
    local lang = Translate.lang()
    if DEEPL_LABEL_TO_CODE[lang] then return DEEPL_LABEL_TO_CODE[lang] end
    -- Les anciens réglages (« français », « English », etc.) restent valides.
    local l = lang:lower()
    if l:find("fran") then return "FR" end
    if l:find("engl") then return "EN" end
    if l:find("espa") or l:find("span") then return "ES" end
    if l:find("allem") or l:find("german") then return "DE" end
    return lang:upper():sub(1, 2)
end

-- Une requête Google Traduction (« gtx », gratuit, sans clé). POST : un GET avec
-- plusieurs milliers de caractères dans l'URL est refusé par Google.
local function gtx_request(text, target)
    local urlmod = require("socket.url")
    local body = "client=gtx&sl=auto&tl=" .. urlmod.escape(target)
        .. "&dt=t&q=" .. urlmod.escape(text)
    local sink = {}
    local ok, code = https.request {
        url = "https://translate.googleapis.com/translate_a/single",
        method = "POST",
        headers = {
            ["User-Agent"] = "Mozilla/5.0",
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink), timeout = 90,
    }
    local resp = table.concat(sink)
    if not ok or code ~= 200 then
        return nil, "Google Traduction indisponible (" .. tostring(code) .. ")"
    end
    local okd, data = pcall(JSON.decode, resp)
    if not okd or type(data) ~= "table" or type(data[1]) ~= "table" then
        return nil, "réponse Google Traduction invalide"
    end
    local out = {}
    for _, row in ipairs(data[1]) do
        if type(row) == "table" and type(row[1]) == "string" then
            out[#out + 1] = row[1]
        end
    end
    local tr = table.concat(out)
    if tr == "" then return nil, "réponse Google Traduction vide" end
    return tr
end

local function split_lines(str, n)
    local t = {}
    for line in (str .. "\n"):gmatch("(.-)\n") do t[#t + 1] = line end
    while #t > n and t[#t] == "" do t[#t] = nil end
    return t
end

-- Google abîme les balises HTML : on ne lui envoie que les textes (un par ligne)
-- et on remet les balises d'origine autour.
local function call_google(html)
    local target = target_code():lower()
    if target == "pt-br" or target == "pt-pt" then target = "pt" end

    local parts, texts = {}, {}
    local pos = 1
    while pos <= #html do
        local s1, e1 = html:find("<[^>]*>", pos)
        local text = html:sub(pos, (s1 or (#html + 1)) - 1)
        if text ~= "" then
            if text:find("%S") then
                local lead  = text:match("^%s*")
                local trail = text:match("%s*$")
                local core  = text:sub(#lead + 1, #text - #trail):gsub("%s*\n%s*", " ")
                core = decode_entities(core)
                texts[#texts + 1] = core
                parts[#parts + 1] = { idx = #texts, lead = lead, trail = trail }
            else
                parts[#parts + 1] = { raw = text }
            end
        end
        if not s1 then break end
        parts[#parts + 1] = { raw = html:sub(s1, e1) }
        pos = e1 + 1
    end
    if #texts == 0 then return html end

    -- Lots de ~4000 caractères.
    local translated = {}
    local i = 1
    while i <= #texts do
        local j, len = i, 0
        while j <= #texts and (j == i or len + #texts[j] < 4000) do
            len = len + #texts[j] + 1
            j = j + 1
        end
        local batch = {}
        for k = i, j - 1 do batch[#batch + 1] = texts[k] end
        local tr, err = gtx_request(table.concat(batch, "\n"), target)
        if not tr then return nil, err end
        local lines = split_lines(tr, #batch)
        if #lines == #batch then
            for k = 1, #batch do translated[i + k - 1] = lines[k] end
        else
            -- Nombre de lignes différent : on retraduit texte par texte.
            for k = 1, #batch do
                local one, err2 = gtx_request(batch[k], target)
                if not one then return nil, err2 end
                translated[i + k - 1] = (one:gsub("\n", " "))
            end
        end
        i = j
    end

    local out = {}
    for _, p in ipairs(parts) do
        if p.raw then out[#out + 1] = p.raw
        else out[#out + 1] = p.lead .. escape_text(translated[p.idx]) .. p.trail end
    end
    return table.concat(out)
end

local function call_deepl(html)
    local key = Settings:get("translate_deepl_key")
    if type(key) ~= "string" or key == "" then
        return nil, "clé DeepL manquante"
    end
    local target = target_code()
    local params = require("socket.url")
    local body = "text=" .. params.escape(html)
        .. "&target_lang=" .. params.escape(target)
        .. "&tag_handling=html&split_sentences=nonewlines"
    local sink = {}
    local ok, code = https.request {
        url = "https://api-free.deepl.com/v2/translate",
        method = "POST",
        headers = {
            ["Authorization"] = "DeepL-Auth-Key " .. key,
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
        timeout = 90,
    }
    local resp = table.concat(sink)
    if ok and code == 200 then
        local okd, data = pcall(JSON.decode, resp)
        local tr = okd and type(data) == "table" and data.translations
            and data.translations[1] and data.translations[1].text
        if type(tr) == "string" and tr ~= "" then return tr end
        return nil, "réponse DeepL vide"
    end
    if code == 429 then return nil, "quota/limite DeepL atteinte (429)" end
    if code == 403 then return nil, "clé DeepL refusée (403)" end
    return nil, "DeepL indisponible (" .. tostring(code) .. ")"
end

-- Gemini est conservé comme solution de secours.
local function call_gemini(prompt)
    local key = Settings:get("translate_api_key")
    if type(key) ~= "string" or key == "" then return nil, "clé Gemini absente" end
    local models = model_list()
    if _good_model then table.insert(models, 1, _good_model) end
    local last_err = "erreur inconnue"
    for _, model in ipairs(models) do
        local url = "https://generativelanguage.googleapis.com/v1beta/models/"
            .. model .. ":generateContent?key=" .. key
        for attempt = 1, MAX_TRIES do
            local body = JSON.encode({
                contents = { { parts = { { text = prompt } } } },
                generationConfig = { temperature = 0.2 },
            })
            local sink = {}
            local ok, code = https.request {
                url=url, method="POST",
                headers={["Content-Type"]="application/json",["Content-Length"]=tostring(#body)},
                source=ltn12.source.string(body), sink=ltn12.sink.table(sink), timeout=90,
            }
            local resp=table.concat(sink)
            if ok and code==200 then
                local okd,data=pcall(JSON.decode,resp)
                local parts=okd and type(data)=="table" and data.candidates and data.candidates[1]
                    and data.candidates[1].content and data.candidates[1].content.parts
                if type(parts)=="table" then
                    local acc={}
                    for _,part in ipairs(parts) do
                        if type(part.text)=="string" and not part.thought then acc[#acc+1]=part.text end
                    end
                    local text=table.concat(acc)
                    if text~="" then _good_model=model; return text end
                end
                last_err="réponse Gemini vide"
            elseif code==429 or code==500 or code==503 then
                last_err="limite Gemini ("..tostring(code)..")"; socket.sleep(4*attempt)
            elseif code==404 then
                last_err="modèle Gemini indisponible"; break
            else
                last_err="Gemini ("..tostring(code)..")"; break
            end
        end
    end
    return nil,last_err
end

local function strip_fences(s)
    s = s:gsub("^%s*```%w*%s*\n", ""):gsub("\n%s*```%s*$", "")
    return s
end

-- Traduit le HTML d'un chapitre (avec cache). progress(i, n) optionnel.
-- Renvoie html_traduit ou nil, erreur.
function Translate.chapter(html, source_id, novel_path, key, progress)
    local lang = Translate.lang()
    local cached = Cache.getTranslation(source_id, novel_path, key, lang)
    if cached then return fix_double_escape(cached) end

    -- Le trailer de métadonnées (avis par paragraphe) n'est pas traduit.
    local meta = html:match("<!%-%-LNREADER_META:.-%-%->")
    local body = meta and html:gsub("<!%-%-LNREADER_META:.-%-%->", "") or html

    local chunks = split_chunks(body)
    local out, context = {}, ""
    for i, chunk in ipairs(chunks) do
        if progress then progress(i, #chunks) end
        local engine = Settings:get("translate_engine") or "deepl"
        local function has(k)
            local v = Settings:get(k)
            return type(v) == "string" and v ~= ""
        end
        -- Moteur choisi sans clé configurée -> Google Traduction (sans clé).
        if (engine == "deepl" and not has("translate_deepl_key"))
            or (engine == "gemini" and not has("translate_api_key")) then
            engine = "google"
        end
        local tr, err
        if engine == "google" then
            tr, err = call_google(chunk)
        elseif engine == "gemini" then
            tr, err = call_gemini(build_prompt(lang, context) .. chunk)
        else
            tr, err = call_deepl(chunk)
        end
        -- Si le moteur choisi échoue, tente les autres moteurs disponibles.
        if not tr and engine ~= "google" then
            tr, err = call_google(chunk)
        end
        if not tr and engine ~= "gemini" and has("translate_api_key") then
            tr, err = call_gemini(build_prompt(lang, context) .. chunk)
        end
        if not tr then return nil, err end
        tr = fix_double_escape(strip_fences(tr))
        out[#out + 1] = tr
        context = tr:gsub("<[^>]+>", ""):sub(-400)
    end

    local result = table.concat(out, "\n")
    if meta then result = result .. "\n" .. meta end
    Cache.storeTranslation(source_id, novel_path, key, lang, result)
    return result
end

return Translate
