-- Search history: one short summary per auction house search, the latest Hist.MAX kept in
-- AuctionJudgeDB.history (account-wide), oldest first. Core records them; this file only keeps the list
-- bounded and formats a summary for /aj history. Pure.
local ADDON, ns = ...

local Hist = {}
ns.History = Hist

Hist.MAX = 20

---The saved list as it can be used: a table of tables, at most MAX (the oldest dropped). Entries are
---kept as they were saved; nothing is filled in for searches that were not recorded.
function Hist.Clean(list)
    if type(list) ~= "table" then return {} end
    local out = {}
    for _, e in ipairs(list) do
        if type(e) == "table" then out[#out + 1] = e end
    end
    while #out > Hist.MAX do table.remove(out, 1) end
    return out
end

---Adds a summary as the newest; drops the oldest beyond MAX.
function Hist.Add(list, entry)
    list[#list + 1] = entry
    while #list > Hist.MAX do table.remove(list, 1) end
end

local START = { search = "search", added = "search (start not seen)", open = "results there on opening" }

local function n(v) return type(v) == "number" and v or 0 end
local function count(v, one, many) return n(v) .. " " .. (n(v) == 1 and one or many) end

---One summary as a line of text.
function Hist.Line(e)
    local parts = {}
    local head = tostring(e.time or "?")
    if e.spec then head = head .. " (" .. tostring(e.spec) .. ")" end
    head = head .. " " .. (START[e.start] or tostring(e.start or "search"))
    parts[1] = head
    if n(e.reads) == 0 then
        parts[#parts + 1] = "results not read"
    else
        parts[#parts + 1] = count(e.raw, "result", "results") .. (e.full == false and " (more not loaded)" or "") .. ", "
            .. count(e.rows, "row", "rows")
    end
    if e.readError then parts[#parts + 1] = "read error: " .. tostring(e.readError) end
    -- failed: sent without results in time, or could not be sent at all (so it can exceed lookups sent)
    local lookups = string.format("lookups: %d sent", n(e.lookups))
    if n(e.failures) > 0 then lookups = lookups .. ", " .. n(e.failures) .. " failed or not sent" end
    if n(e.groups) > 0 then lookups = lookups .. string.format(", groups %d/%d done", n(e.groupsDone), n(e.groups)) end
    parts[#parts + 1] = lookups
    if e.confirmedUpgrades ~= nil or e.estimatedUpgrades ~= nil then
        parts[#parts + 1] = string.format("upgrades %d confirmed, %d estimated", n(e.confirmedUpgrades),
            n(e.estimatedUpgrades))
    elseif e.upgrades ~= nil then
        parts[#parts + 1] = string.format("upgrades %d", n(e.upgrades))
    end
    local scan = "scan " .. tostring(e.stop or "?")
    if e.disabled then scan = scan .. " (" .. tostring(e.disabled) .. ")" end
    if n(e.queued) > 0 then scan = scan .. ", " .. n(e.queued) .. " queued" end
    if e.inflight then scan = scan .. ", one in flight" end
    if n(e.pending) > 0 then scan = scan .. ", " .. count(e.pending, "row", "rows") .. " pending" end
    if e.readPending then scan = scan .. ", more results not read yet" end
    parts[#parts + 1] = scan
    if e.ended then parts[#parts + 1] = tostring(e.ended) end
    return table.concat(parts, "; ")
end
