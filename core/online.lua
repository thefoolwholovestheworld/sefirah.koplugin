-- core/online.lua — passerelle réseau unique de Sefirah.
--
-- Problèmes réglés :
--  * NetworkMgr:runWhenConnected relançait parfois le Wi-Fi alors que la
--    liseuse était déjà connectée (état Kobo mal lu après une veille) ;
--  * des tentatives en rafale d'activation du Wi-Fi quand la puce ne répond
--    plus (« wlan0 : No such device ») précèdent les plantages natifs ;
--  * quand le Wi-Fi ne démarre pas, l'utilisateur ne savait pas quoi faire.
--
-- Online.run(cb)           : exécute cb dès que le réseau est utilisable.
-- Online.is_up()           : vrai si une connexion TCP sortante réussit (sans DNS).
-- Online.explain_failure() : explique à l'écran la cause probable d'un échec.
-- Online.safe(fn)          : exécute fn en capturant toute erreur Lua.
local socket = require("socket")

local Online = {}

local HOSTS = { { "1.1.1.1", 443 }, { "8.8.8.8", 53 }, { "9.9.9.9", 443 } }
local OK_TTL, KO_TTL = 20, 4
local RETRY_GAP = 45          -- secondes mini entre deux demandes d'activation du Wi-Fi

local function tr(s)
    local ok, T = pcall(function() return require("core.i18n").T end)
    return (ok and T) and T(s) or s
end

local _cache = { t = 0, ok = false }
local _last_wifi_request = nil

local function tcp_ok(host, port)
    local s = socket.tcp()
    if not s then return false end
    s:settimeout(2)
    local ok = s:connect(host, port)
    pcall(s.close, s)
    return ok and true or false
end

function Online.is_up(force)
    local now = socket.gettime()
    if not force and now - _cache.t < (_cache.ok and OK_TTL or KO_TTL) then
        return _cache.ok
    end
    local up = false
    for _, h in ipairs(HOSTS) do
        if tcp_ok(h[1], h[2]) then up = true; break end
    end
    _cache = { t = now, ok = up }
    return up
end

function Online.invalidate() _cache.t = 0 end

-- Message d'information (jamais depuis un sous-processus, et pas plus d'un
-- toutes les 20 s pour ne pas empiler les fenêtres).
local _last_msg = 0
local function say(text, timeout)
    if _G.__sefirah_in_child then return end
    local now = os.time()
    if now - _last_msg < 20 then return end
    _last_msg = now
    local ok, UIManager = pcall(require, "ui/uimanager")
    local ok2, InfoMessage = pcall(require, "ui/widget/infomessage")
    if ok and ok2 then
        UIManager:nextTick(function()
            pcall(function()
                UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 6 })
            end)
        end)
    end
end
Online.say = say

-- Appelé quand une requête échoue : explique la cause probable
-- (Wi-Fi coupé ou puce Wi-Fi bloquée, ou simple site injoignable).
function Online.explain_failure()
    if not Online.is_up(true) then
        say(tr("Pas de connexion Internet. Vérifie le Wi-Fi de la liseuse. S'il ne démarre pas, éteins complètement la liseuse puis rallume-la."))
    else
        say(tr("Le site ne répond pas pour le moment (ta connexion Wi-Fi fonctionne). Réessaie plus tard."))
    end
end

-- Exécute une action en capturant toute erreur Lua : une erreur ici ne doit
-- jamais faire tomber KOReader.
function Online.safe(fn)
    local ok, err = pcall(fn)
    if not ok then
        pcall(function() require("logger").warn("Sefirah/Online: erreur :", tostring(err)) end)
    end
end

-- Propose de relancer le Wi-Fi (coupure, pause de 3 s pour laisser le pilote
-- Kobo se réinitialiser, puis rallumage).
local function offer_wifi_restart(callback)
    local ok, UIManager = pcall(require, "ui/uimanager")
    local ok2, ConfirmBox = pcall(require, "ui/widget/confirmbox")
    if not (ok and ok2) then return end
    UIManager:show(ConfirmBox:new{
        text = tr("Le Wi-Fi n'a pas pu démarrer. Le relancer ?\n\nSi ça ne marche toujours pas, éteins complètement la liseuse puis rallume-la."),
        ok_text = tr("Relancer"),
        cancel_text = tr("Annuler"),
        ok_callback = function()
            pcall(function()
                local NM = require("ui/network/manager")
                NM:turnOffWifi(function()
                    UIManager:scheduleIn(3, function()
                        _last_wifi_request = nil
                        Online.invalidate()
                        NM:turnOnWifiAndWaitForConnection(function()
                            Online.invalidate()
                            Online.safe(callback)
                        end)
                    end)
                end)
            end)
        end,
    })
end

function Online.run(callback)
    -- Déjà connecté : on n'appelle surtout pas la logique d'activation du Wi-Fi.
    if Online.is_up() then return Online.safe(callback) end

    local now = os.time()
    if _last_wifi_request and now - _last_wifi_request < RETRY_GAP then
        -- Une activation vient d'échouer : pas de nouvelle rafale.
        Online.explain_failure()
        return
    end
    _last_wifi_request = now
    Online.invalidate()

    local connected = false
    require("ui/network/manager"):runWhenConnected(function()
        connected = true
        _last_wifi_request = nil
        Online.invalidate()
        Online.safe(callback)
    end)

    -- Garde-fou : si au bout de 50 s le Wi-Fi n'est toujours pas là, on le dit
    -- et on propose de le relancer.
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok then
        UIManager:scheduleIn(50, function()
            if connected or _G.__sefirah_in_child or Online.is_up(true) then return end
            offer_wifi_restart(callback)
        end)
    end
end

return Online
