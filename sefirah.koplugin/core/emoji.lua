-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.
local T = require("core.i18n").T

-- core/emoji.lua
--
-- Remplace les emoji les plus courants (avis, commentaires) par une étiquette
-- texte entre crochets. La police utilisée par l'interface de KOReader sur le
-- Kobo ne contient pas ces glyphes : un emoji non reconnu par la police
-- s'affiche en "?", ce qui rendait les avis/commentaires illisibles à ces
-- endroits. Plutôt que de patcher chaque extension séparément (ce qui avait
-- été fait ponctuellement pour 👍/👎 dans NovelFrance/RoyalRoad), ce module
-- est appliqué une seule fois, aux points d'assemblage du texte affiché dans
-- ui/detail.lua (avis) et ui/readerview.lua (commentaires de paragraphe et de
-- chapitre) — donc valable pour TOUTES les sources, actuelles et futures.
--
-- Liste non exhaustive : seulement les emoji effectivement vus dans les avis/
-- commentaires des sources actuelles. Un emoji absent de cette liste reste
-- affiché tel quel (donc potentiellement en "?" sur cet écran) — si ça
-- arrive, dis-moi lequel pour que je l'ajoute ici.
local EMOJI = {
    { "\u{1F44D}",         T("[j'aime]") },     -- 👍
    { "\u{1F44E}",         T("[j'aime pas]") }, -- 👎
    { "\u{2764}\u{FE0F}",  T("[coeur]") },      -- ❤️ (avec variation selector)
    { "\u{2764}",          T("[coeur]") },      -- ❤
    { "\u{1F495}",         T("[coeur]") },      -- 💕
    { "\u{1F49E}",         T("[coeur]") },      -- 💞
    { "\u{1F60D}",         T("[amour]") },      -- 😍
    { "\u{1F970}",         T("[amour]") },      -- 🥰
    { "\u{1F602}",         T("[rire]") },       -- 😂
    { "\u{1F923}",         T("[rire]") },       -- 🤣
    { "\u{1F606}",         T("[rire]") },       -- 😆
    { "\u{1F60A}",         T("[sourire]") },    -- 😊
    { "\u{1F642}",         T("[sourire]") },    -- 🙂
    { "\u{1F643}",         T("[sourire]") },    -- 🙃
    { "\u{1F62D}",         T("[pleure]") },     -- 😭
    { "\u{1F622}",         T("[triste]") },     -- 😢
    { "\u{1F614}",         T("[triste]") },     -- 😔
    { "\u{1F62E}",         T("[waouh]") },      -- 😮
    { "\u{1F631}",         T("[peur]") },       -- 😱
    { "\u{1F621}",         T("[colère]") },     -- 😡
    { "\u{1F620}",         T("[colère]") },     -- 😠
    { "\u{1F914}",         T("[réfléchit]") },  -- 🤔
    { "\u{1F644}",         T("[blasé]") },      -- 🙄
    { "\u{1F62C}",         T("[gêné]") },       -- 😬
    { "\u{1F634}",         T("[dort]") },       -- 😴
    { "\u{1F60E}",         "[cool]" },       -- 😎
    { "\u{1F44F}",         T("[applaudit]") },  -- 👏
    { "\u{1F4AA}",         T("[force]") },      -- 💪
    { "\u{1F64F}",         T("[prie]") },       -- 🙏
    { "\u{1F525}",         T("[feu]") },        -- 🔥
    { "\u{1F4AF}",         "[100]" },        -- 💯
    { "\u{2728}",          T("[étincelles]") }, -- ✨
    { "\u{1F389}",         T("[fête]") },       -- 🎉
    { "\u{1F60F}",         T("[malicieux]") },  -- 😏
    { "\u{1F624}",         T("[soupir]") },     -- 😤
    { "\u{1F4AC}",         T("[bulle]") },      -- 💬
}

local M = {}

-- Les emoji sont des séquences d'octets UTF-8 (tous ≥ 0x80) : aucun ne
-- correspond à un caractère magique des patterns Lua (^$()%.[]*+-?, tous
-- ASCII < 0x80), donc gsub direct sans échappement est sûr ici.
function M.sanitize(text)
    if type(text) ~= "string" or text == "" then return text end
    for _, pair in ipairs(EMOJI) do
        text = text:gsub(pair[1], pair[2])
    end
    return text
end

return M
