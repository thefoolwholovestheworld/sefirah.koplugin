-- Sefirah Community: no synthetic users, posts or messages.
local Settings = require("sefirah_settings")
local LB = require("core.leaderboard")
local Model = {}
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function state()
    local s = Settings:get("social_cache_v1")
    if type(s) ~= "table" then s = { posts = {}, conversations = {}, messages = {} } end
    s.posts, s.conversations, s.messages = s.posts or {}, s.conversations or {}, s.messages or {}
    return s
end
local function save(s) Settings:set("social_cache_v1", s) end
function Model.posts() return state().posts end
function Model.conversations() return state().conversations end
function Model.messages(peer) return state().messages[peer] or {} end
-- Sans réglage manuel, la Communauté utilise le même serveur que le classement (community_config.lua).
function Model.server()
    local own = trim(Settings:get("social_server_url"))
    if own ~= "" then return own end
    local ok, cfg = pcall(require, "community_config")
    local url = ok and type(cfg) == "table" and trim(cfg.url) or ""
    return (url:gsub("/+$", ""))
end
function Model.setServer(url)
    url = trim(url):gsub("/+$", "")
    if url ~= "" and not url:match("^https://[%w%.%-]+$") then
        return nil, "Utilise une URL HTTPS sans chemin ni identifiants."
    end
    Settings:set("social_server_url", url)
    -- A cache from another server must not appear as data from the new server.
    Settings:set("social_cache_v1", {posts={}, conversations={}, messages={}})
    Settings.flushNow()
    return true
end
local function call(route, data)
    if Model.server() == "" then return nil, "Serveur social non configuré. Ouvre « Serveur » : le Worker fourni doit d’abord être déployé." end
    if LB.username() == "" then return nil, "Choisis ton pseudo dans Quêtes & niveaux → Classement, puis synchronise ton compte." end
    local res, err = LB.socialRequest(route, data or {}, Model.server())
    if not res then return nil, err end
    if res.error then return nil, tostring(res.error) end
    return res
end
function Model.refreshFeed()
    local res, err = call("feed/list", {})
    if not res then return nil, err end
    if type(res.posts) ~= "table" then return nil, "Réponse invalide : publications absentes." end
    local s = state(); s.posts = res.posts; s.updated_at = os.time(); save(s)
    return true
end
function Model.refreshConversations()
    local res, err = call("conversations/list", {})
    if not res then return nil, err end
    if type(res.conversations) ~= "table" then return nil, "Réponse invalide : conversations absentes." end
    local s = state(); s.conversations = res.conversations; save(s); return true
end
function Model.refreshMessages(peer)
    local res, err = call("messages/list", {peer=peer})
    if not res then return nil, err end
    if type(res.messages) ~= "table" then return nil, "Réponse invalide : messages absents." end
    local s = state(); s.messages[peer] = res.messages; save(s); return true
end
function Model.draft()
    local d = Settings:get("social_draft_v1")
    if type(d) ~= "table" then d = {text="", quote="", rating=0, spoiler=false, audience="friends"} end
    return d
end
function Model.saveDraft(d) Settings:set("social_draft_v1", d); Settings.flushNow() end
function Model.nonce()
    local n = (tonumber(Settings:get("social_serial")) or 0) + 1
    Settings:set("social_serial", n); Settings.flushNow()
    return tostring(os.time()) .. "-" .. tostring(n)
end
function Model.publish()
    local d = Model.draft()
    if type(d.book) ~= "table" or trim(d.book.title) == "" then return nil, "Choisis un livre." end
    if trim(d.text) == "" then return nil, "Écris ton avis avant de publier." end
    if #d.text > 2000 or #(d.quote or "") > 600 then return nil, "Avis : 2 000 octets maximum ; citation : 600 octets." end
    if not d.client_id then d.client_id = Model.nonce(); Model.saveDraft(d) end
    local res, err = call("post/create", d)
    if not res then return nil, err end
    if type(res.post) ~= "table" or not res.post.id then return nil, "Publication non confirmée. Le brouillon est conservé." end
    local s = state()
    local found = false
    for _, p in ipairs(s.posts) do if p.id == res.post.id then found = true end end
    if not found then table.insert(s.posts, 1, res.post) end
    while #s.posts > 50 do table.remove(s.posts) end
    save(s); Model.saveDraft({text="", quote="", rating=0, spoiler=false, audience="friends"})
    return res.post
end
function Model.like(id)
    local res, err = call("post/like", {id=id})
    if not res then return nil, err end
    local s = state()
    for _, p in ipairs(s.posts) do if p.id == id then p.liked = res.liked; p.likes = res.likes end end
    save(s); return true
end
function Model.comments(id)
    local res, err = call("comment/list", {id=id})
    if not res then return nil, err end
    return res.comments or {}
end
function Model.comment(id, text, client_id)
    if trim(text) == "" or #text > 1000 then return nil, "Commentaire : de 1 à 1 000 octets." end
    return call("comment/create", {id=id, text=text, client_id=client_id})
end
function Model.send(peer, text, spoiler)
    if trim(text) == "" or #text > 1000 then return nil, "Message : de 1 à 1 000 octets." end
    local drafts = Settings:get("social_message_drafts") or {}
    local d = drafts[peer]
    if not d or d.text ~= text or d.spoiler ~= spoiler then
        d = {text=text, spoiler=spoiler or false, client_id=Model.nonce()}
    end
    drafts[peer] = d; Settings:set("social_message_drafts", drafts); Settings.flushNow()
    local res, err = call("messages/send", {peer=peer, text=text, spoiler=d.spoiler, client_id=d.client_id})
    if not res then return nil, err end
    if type(res.message) ~= "table" or not res.message.id then return nil, "Envoi non confirmé. Le brouillon est conservé." end
    local s = state(); s.messages[peer] = s.messages[peer] or {}
    local found = false
    for _, m in ipairs(s.messages[peer]) do if m.id == res.message.id then found = true end end
    if not found then table.insert(s.messages[peer], res.message) end
    while #s.messages[peer] > 100 do table.remove(s.messages[peer], 1) end
    save(s); drafts[peer] = nil; Settings:set("social_message_drafts", drafts); Settings.flushNow()
    return true
end
function Model.messageDraft(peer)
    return (Settings:get("social_message_drafts") or {})[peer] or {text="",spoiler=false}
end
return Model
