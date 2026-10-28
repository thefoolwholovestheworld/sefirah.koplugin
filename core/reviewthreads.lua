-- Shared review threading. Depth is zero-based; each reply remains a review.
local Threads = {}
local function key(id)
    if id == nil or id == false then return nil end
    local s = tostring(id)
    if s == "" or s == "0" or s == "null" then return nil end
    return s
end

function Threads.flatten(reviews)
    local out, seen = {}, {}
    local function visit(list, parent, depth)
        for _, rev in ipairs(type(list) == "table" and list or {}) do
            if type(rev) == "table" and not seen[rev] then
                seen[rev] = true
                local copy = {}
                for k, v in pairs(rev) do if k ~= "replies" then copy[k] = v end end
                copy.parent_id = key(copy.parent_id or copy.parentId or copy.reply_to) or parent
                copy.depth = math.max(0, tonumber(copy.depth) or depth or (copy.parent_id and 1 or 0))
                out[#out + 1] = copy
                visit(rev.replies, key(copy.id) or copy.parent_id, copy.depth + 1)
            end
        end
    end
    visit(reviews, nil, nil)
    return out
end

-- Input is already sorted. Sort root threads without detaching their replies.
-- Orphans remain visible; duplicates/cycles must never hide a review.
function Threads.order(reviews)
    local by_id, children, roots, visited, out = {}, {}, {}, {}, {}
    for _, rev in ipairs(reviews) do
        local id = key(rev.id)
        if id and not by_id[id] then by_id[id] = rev end
    end
    for _, rev in ipairs(reviews) do
        local parent = by_id[key(rev.parent_id)]
        if parent and parent ~= rev then
            children[parent] = children[parent] or {}
            table.insert(children[parent], rev)
        else
            roots[#roots + 1] = rev
        end
    end
    local function emit(rev, depth)
        if visited[rev] then return end
        visited[rev] = true
        rev.depth = depth or math.max(0, tonumber(rev.depth) or (key(rev.parent_id) and 1 or 0))
        out[#out + 1] = rev
        for _, child in ipairs(children[rev] or {}) do emit(child, rev.depth + 1) end
    end
    for _, rev in ipairs(roots) do emit(rev) end
    for _, rev in ipairs(reviews) do emit(rev) end
    return out
end
return Threads
