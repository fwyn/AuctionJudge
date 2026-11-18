-- Pure bookkeeping: rows built from browse results, item info and score state, filtering, sorting and
-- formatting. No game calls here; everything the game provides is passed in. Unit-tested in tests/.
local ADDON, ns = ...

local M = {}
ns.Model = M

local floor, format, tonumber, type, pairs, ipairs = math.floor, string.format, tonumber, type, pairs, ipairs

M.BATCH_SIZE = 20       -- rows worked on per batch
M.BATCH_INTERVAL = 0.1  -- seconds between batches
M.RETRY_BASE = 0.5      -- first retry delay for a pending row, doubled per try
M.RETRY_MAX = 5         -- longest retry delay
M.MAX_TRIES = 12        -- a row still pending after this many tries becomes an error (about 45 s)
M.MAX_SKIPPED = 100     -- browse results without a row of their own kept for diagnostics
M.MAX_DUMP_ROWS = 400   -- rows in the saved diagnostic dump

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

-- Equip locations that are not gear worth judging. Empty and nil are not gear either.
-- INVTYPE_NON_EQUIP(_IGNORE) is what the modern client reports for items that cannot be worn.
M.NOT_GEAR = {
    INVTYPE_BAG = true, INVTYPE_QUIVER = true, INVTYPE_TABARD = true, INVTYPE_BODY = true,
    INVTYPE_NON_EQUIP = true, INVTYPE_NON_EQUIP_IGNORE = true,
}

function M.IsGear(equipLoc)
    return type(equipLoc) == "string" and equipLoc ~= "" and not M.NOT_GEAR[equipLoc]
end

---Item string for an auction item key: the random suffix is the 7th field of an item string.
function M.ItemString(itemID, suffix)
    itemID = tonumber(itemID)
    if not itemID then return nil end
    suffix = tonumber(suffix) or 0
    if suffix ~= 0 then return format("item:%d::::::%d", itemID, suffix) end
    return format("item:%d", itemID)
end

---One row per item string: item level variants of the same item and suffix share a link and a score.
function M.RowKey(itemID, suffix)
    return format("%d:%d", tonumber(itemID) or 0, tonumber(suffix) or 0)
end

---Upgrade per gold: upgradePct / (price in gold). Only for a real upgrade and a real price.
function M.Value(upgradePct, price)
    if type(upgradePct) ~= "number" or type(price) ~= "number" then return nil end
    if upgradePct <= 0 or price <= 0 then return nil end
    return upgradePct / (price / 10000)
end

---------------------------------------------------------------------------
-- Store: the current rows plus session caches
---------------------------------------------------------------------------
-- Row states:
--   pending   waiting for item info (row.info == nil) or for a score; retried at row.nextTry
--   scored    row.upgradePct is set
--   unusable  SGJ says this character cannot use it
--   notgear   not gear (equip location, or SGJ says NOT_EQUIPPABLE)
--   error     scoring failed, or still pending after MAX_TRIES
-- store.pending counts pending rows and store.nextDue is no later than the earliest retry, so a batch
-- costs nothing when there is no work.
-- store.rows are the browse rows (a random suffix row is a group of auctions with varying stats);
-- store.leaves are the rows judged and listed: each browse row, or in place of a group whose auctions
-- were read, one row per distinct auction link (row.isAuction, row.group).

local huge = math.huge

function M.NewStore()
    return {
        rows = {},      -- browse rows, in browse order
        leaves = {},    -- rows judged and listed
        byKey = {},     -- row key -> row
        byItem = {},    -- itemID -> list of rows
        info = {},      -- item string -> item info with a known equip location (session cache)
        scores = {},    -- link -> { result = r } or { reason = why } (session cache, final outcomes only)
        lastCount = 0,  -- browse results in the last read
        pending = 0,
        nextDue = huge,
    }
end

local function setState(store, row, state)
    if row.state == "pending" then store.pending = store.pending - 1 end
    if state == "pending" then store.pending = store.pending + 1 end
    row.state = state
end

local function markDue(store, t)
    if t < store.nextDue then store.nextDue = t end
end

local function recount(store)
    local leaves = {}
    local useAuctions = store.useAuctions ~= false
    for _, row in ipairs(store.rows) do
        if row.auctions and useAuctions then
            for _, a in ipairs(row.auctions) do leaves[#leaves + 1] = a end
        else
            leaves[#leaves + 1] = row
        end
    end
    store.leaves = leaves
    local n = 0
    for _, row in ipairs(leaves) do if row.state == "pending" then n = n + 1 end end
    store.pending = n
    store.nextDue = n > 0 and 0 or huge
end

---Forgets the rows (a new browse search, or the auction house closed); the session caches stay.
function M.Clear(store)
    store.rows, store.byKey, store.byItem = {}, {}, {}
    store.skipped, store.skippedCount = {}, 0
    store.lastCount = 0
    store.full = nil
    recount(store)
end

local function resetScore(store, row)
    row.upgradePct, row.value, row.specName, row.equipped, row.reason = nil, nil, nil, nil, nil
    row.itemScore, row.equippedScore, row.slot, row.sgjReason, row.sgjLink = nil, nil, nil, nil, nil
    setState(store, row, "pending")
    row.tries, row.nextTry = 0, 0
    markDue(store, 0)
end

local function setScore(store, row, result, reason)
    row.sgjReason = (not result) and reason or nil
    if result then
        -- plain numbers only (kept for diagnostics)
        row.itemScore, row.equippedScore, row.slot =
            tonumber(result.itemScore), tonumber(result.equippedScore), tonumber(result.slot)
        -- the link SGJ judged (it normalises through GetItemInfo): shows whether the suffix survived
        row.sgjLink = type(result.itemLink) == "string" and result.itemLink or nil
        local pct = tonumber(result.upgradePct)
        if pct then
            setState(store, row, "scored")
            row.reason = nil
            row.upgradePct = pct
            row.value = M.Value(pct, row.price)
            row.specName = result.specName
            row.equipped = result.equipped == true
        else
            -- SGJ leaves upgradePct nil when the character's score is 0
            setState(store, row, "error")
            row.reason = "NO_PERCENT"
        end
    elseif reason == "NOT_USABLE" then
        setState(store, row, "unusable")
        row.reason = reason
    else -- NOT_EQUIPPABLE
        setState(store, row, "notgear")
        row.reason = reason
    end
end

---Puts a pending row back for a later try; gives up after MAX_TRIES.
function M.Defer(store, row, now, reason)
    row.tries = (row.tries or 0) + 1
    row.reason = reason
    if row.tries >= M.MAX_TRIES then
        setState(store, row, "error")
        row.reason = "GAVE_UP " .. tostring(reason)
        return
    end
    setState(store, row, "pending")
    local delay = M.RETRY_BASE * 2 ^ (row.tries - 1)
    if delay > M.RETRY_MAX then delay = M.RETRY_MAX end
    row.nextTry = now + delay
    markDue(store, row.nextTry)
end

---The name inside a hyperlink ("|h[Cadet Vest of the Whale]|h"), or nil.
function M.LinkName(link)
    if type(link) ~= "string" then return nil end
    local name = link:match("|h%[(.-)%]|h")
    if name and name ~= "" then return name end
    return nil
end

---Row info for a browse row from the base item info (GetItemInfo of the item string: equip location and
---link; for a random suffix group only the base item) and the item key info ({ name, quality, icon } or
---nil: the group's suffixed name). A random suffix group is approximate: a browse row is a group of
---auctions whose stats vary, and the item key has no exact link. Its base score stands in until the
---group's auctions are read (SetAuctions). The required level (minLevel) is the item key's (keyLevel, read
---for the row's item level variant itemLevel) when the client gives one, else the base item's.
function M.MergeInfo(base, keyInfo, suffix, keyLevel, itemLevel)
    keyInfo = keyInfo or {}
    local keyed = type(keyLevel) == "number"
    return {
        name = keyInfo.name or base.name,
        link = base.link,
        linkSource = "iteminfo",
        quality = keyInfo.quality or base.quality,
        icon = keyInfo.icon or base.icon,
        equipLoc = base.equipLoc,
        minLevel = keyed and keyLevel or base.minLevel,
        minLevelSource = keyed and "key" or "item",
        minLevelItemLevel = keyed and itemLevel or nil,
        approximate = (tonumber(suffix) or 0) ~= 0,
    }
end

---A browse row that needs its auctions read for exact scores: a scored random suffix group (stats vary
---per auction) without auction rows and not queued yet. Unusable and non-gear groups never need it.
function M.NeedsQuery(row)
    return not row.isAuction and (row.suffix or 0) ~= 0 and row.info == true and row.auctions == nil
        and row.query == nil and (row.state == "scored" or row.state == "error")
end

---Rows per link source ("iteminfo" for browse rows, "auction" for rows from a group's auctions).
function M.LinkSourceCounts(store)
    local c = {}
    for _, row in ipairs(store.leaves) do
        if row.info then
            local s = row.linkSource or "iteminfo"
            c[s] = (c[s] or 0) + 1
        end
    end
    return c
end

---Item info arrived for a row (from the game or the cache). Applies a cached score when there is one.
---info: { name, link, quality, icon, equipLoc, minLevel, minLevelSource }. equipLoc nil means unknown
---(unreadable): the row stays pending for a bounded retry and nothing is cached. minLevel nil means the
---required level is unknown; minLevelSource says where a known one came from: "item" (the default: the
---item info of the row's item string), "key" (the browse item key, read for item level minLevelItemLevel)
---or "link" (an auction row's own link, see SetMinLevel).
function M.ApplyInfo(store, row, info, now)
    if info.equipLoc == nil then
        M.Defer(store, row, now or 0, "EQUIP_LOC_UNKNOWN")
        return
    end
    -- an approximate (base item) link is not kept: a later read may get the real one
    if not info.approximate then store.info[row.itemString] = info end
    row.info = true
    row.name, row.quality, row.icon, row.equipLoc = info.name, info.quality, info.icon, info.equipLoc
    row.link = info.link or row.itemString
    row.linkSource = info.linkSource or "iteminfo"
    row.approximate = info.approximate == true
    row.sortName = type(info.name) == "string" and info.name:lower() or ""
    row.minLevel = type(info.minLevel) == "number" and info.minLevel or nil
    row.minLevelSource = row.minLevel and (info.minLevelSource or "item") or nil
    row.minLevelItemLevel = row.minLevelSource == "key" and info.minLevelItemLevel or nil
    if not M.IsGear(info.equipLoc) then
        setState(store, row, "notgear")
        row.reason = "EQUIP_LOC"
        return
    end
    local cached = store.scores[row.link]
    if cached then
        setScore(store, row, cached.result, cached.reason)
    else
        resetScore(store, row)
    end
end

---Applies what ScoreItem returned: a result table, or nil and a reason.
function M.ApplyScore(store, row, result, reason, now)
    if result or reason == "NOT_USABLE" or reason == "NOT_EQUIPPABLE" then
        setScore(store, row, result, reason)
        store.scores[row.link] = { result = result, reason = (not result) and reason or nil }
    elseif reason == "NOT_CACHED" or reason == "NOT_READY" then
        M.Defer(store, row, now, reason)
        row.sgjReason = reason
    else
        setState(store, row, "error")
        row.reason = reason or "ERROR"
        row.sgjReason = reason
    end
end

---Rebuilds the rows from browse entries { itemID, itemLevel, itemSuffix, minPrice, totalQuantity,
---equipLoc (optional instant hint, nil when unknown) }. One row per item string (item level variants
---merge); the lowest price wins. Rows already known keep their state; new rows take item info and
---scores from the session caches.
---skipped (optional): browse results already left out by the reader, { itemID, itemSuffix, reason };
---entries that do not become rows of their own are added to it (for diagnostics, up to MAX_SKIPPED).
function M.Rebuild(store, entries, skipped)
    local old = store.byKey
    local rows, byKey, byItem = {}, {}, {}
    local skip, skipCount = {}, 0
    local function skipEntry(s)
        skipCount = skipCount + 1
        if #skip < M.MAX_SKIPPED then skip[#skip + 1] = s end
    end
    for _, s in ipairs(skipped or {}) do skipEntry(s) end
    for _, e in ipairs(entries) do
        local id = tonumber(e.itemID)
        if not (id and id > 0) then
            skipEntry({ itemID = id, itemSuffix = tonumber(e.itemSuffix), reason = "bad item id" })
        else
            local suffix, ilvl = tonumber(e.itemSuffix) or 0, tonumber(e.itemLevel) or 0
            local key = M.RowKey(id, suffix)
            local price = tonumber(e.minPrice)
            local row = byKey[key]
            if row then
                skipEntry({ itemID = id, itemSuffix = suffix, itemLevel = ilvl, price = price,
                    reason = "merged into row " .. key .. " (lowest price kept)" })
                if price and (not row.price or price < row.price) then
                    row.price, row.quantity, row.itemLevel = price, tonumber(e.totalQuantity), ilvl
                end
            else
                row = old[key]
                if not row then
                    row = { key = key, itemID = id, suffix = suffix,
                        itemString = M.ItemString(id, suffix), state = "pending", tries = 0, nextTry = 0 }
                    local info = store.info[row.itemString]
                    if info then
                        M.ApplyInfo(store, row, info)
                    elseif e.equipLoc ~= nil and not M.IsGear(e.equipLoc) then
                        row.state, row.reason = "notgear", "EQUIP_LOC"
                    end
                end
                row.price, row.quantity, row.itemLevel = price, tonumber(e.totalQuantity), ilvl
                row.itemKeyRef = e.itemKey -- the browse result's own item key, for an item search
                byKey[key] = row
                rows[#rows + 1] = row
                local list = byItem[id]
                if not list then list = {}; byItem[id] = list end
                list[#list + 1] = row
            end
        end
    end
    for _, row in ipairs(rows) do
        if row.minLevelSource == "key" and row.minLevelItemLevel ~= row.itemLevel then
            row.minLevel, row.minLevelSource, row.minLevelItemLevel, row.levelMisses = nil, nil, nil, nil
        end
        if row.state == "scored" then row.value = M.Value(row.upgradePct, row.price) end
    end
    store.rows, store.byKey, store.byItem = rows, byKey, byItem
    store.lastCount = #entries
    store.skipped, store.skippedCount = skip, skipCount
    recount(store)
end

---The client loaded an item: its rows waiting for item info are tried at the next batch.
function M.InfoArrived(store, itemID)
    local list = store.byItem[tonumber(itemID) or 0]
    if not list then return false end
    local any = false
    for _, row in ipairs(list) do
        if row.state == "pending" and not row.info then row.nextTry = 0; any = true end
    end
    if any then markDue(store, 0) end
    return any
end

---The item an auction link describes, as a string: item id, enchant, gems and suffix field (payload fields
---1-8) and the bonus IDs (field 13 is their count; sorted). Link level, spec, modifier mask, item context,
---the modifier section after the bonus IDs (a count, then type:value pairs), colour and name are left
---out: auctions differing only there are the same item. A link that cannot be parsed is its own identity.
function M.ItemIdentity(link)
    if type(link) ~= "string" then return nil end
    local payload = link:match("|Hitem:([^|]*)") or link:match("^item:([^|]*)")
    if not payload then return link end
    local f = {}
    for x in (payload .. ":"):gmatch("([^:]*):") do f[#f + 1] = x end
    if not tonumber(f[1]) then return link end
    local head = {}
    for i = 1, 8 do
        local x = f[i] or ""
        if i > 1 and tonumber(x) == 0 then x = "" end
        head[i] = x
    end
    local n = tonumber(f[13]) or 0
    local bonus = {}
    for i = 14, 13 + n do
        local b = tonumber(f[i])
        if not b then return link end -- fewer bonus IDs than counted: not a link we understand
        bonus[#bonus + 1] = b
    end
    table.sort(bonus)
    return table.concat(head, ":") .. "|" .. table.concat(bonus, ":")
end

---A group's item search results arrived: results { link, buyout, bid, quantity } (plain values). The group
---is listed as one row per distinct item (ItemIdentity), with the lowest-priced auction's link (price is
---the buyout, else the bid, then marked bid; at the same price a buyout wins) and the number of auctions
---merged (shown in /aj debug and the dump only). Each row is judged by its own link; rows take item info from the group and cached scores.
---The required level is the one read from the auction's own link before (SetMinLevel, kept in the item info
---cache), else unknown until it is read: the group's level is not the auction's.
---Returns the number of auction rows.
function M.SetAuctions(store, group, results)
    local byId, order = {}, {}
    for _, r in ipairs(results) do
        local link = r.link
        local buyout, bid = tonumber(r.buyout), tonumber(r.bid)
        if buyout == 0 then buyout = nil end
        local price = buyout or bid
        if type(link) == "string" and link:find("item:", 1, true) and price then
            local id = M.ItemIdentity(link)
            local a = byId[id]
            local isBid = buyout == nil
            if not a then
                order[#order + 1] = id
                byId[id] = { link = link, price = price, bid = isBid, count = 1 }
            else
                a.count = a.count + 1
                if price < a.price or (price == a.price and a.bid and not isBid) then
                    a.link, a.price, a.bid = link, price, isBid
                end
            end
        end
    end
    local old = {}
    for _, a in ipairs(group.auctions or {}) do old[a.identity] = a end
    local rows = {}
    for i, id in ipairs(order) do
        local a = byId[id]
        local row = old[id]
        if not row then
            row = { key = group.key .. "#" .. i, itemID = group.itemID, suffix = group.suffix,
                itemLevel = group.itemLevel, itemString = a.link, isAuction = true, group = group, identity = id,
                state = "pending", tries = 0, nextTry = 0 }
            row.price = a.price
            local known = store.info[a.link]
            local exact = known and known.minLevelSource == "link" and known.minLevel or nil
            M.ApplyInfo(store, row, {
                name = M.LinkName(a.link) or group.name, link = a.link, linkSource = "auction",
                quality = group.quality, icon = group.icon, equipLoc = group.equipLoc,
                minLevel = exact, minLevelSource = "link",
            })
        end
        row.price, row.bid, row.auctionCount = a.price, a.bid, a.count
        if row.state == "scored" then row.value = M.Value(row.upgradePct, row.price) end
        rows[#rows + 1] = row
    end
    group.auctions = rows
    recount(store)
    return #rows
end

M.MAX_LEVEL_MISSES = 3 -- reads of a row's readable item data that still gave no required level

---A required level read later (LevelWanted): source "link" (an auction row's own link), "key" (the browse
---item key, for item level itemLevel) or "item" (the item info). Kept in the item info cache of the row's
---item string, so later searches start with it. nil (not readable) changes nothing. true when it was set.
function M.SetMinLevel(store, row, level, source, itemLevel)
    if type(level) ~= "number" then return false end
    source = source or (row.isAuction and "link" or "item")
    local at = source == "key" and itemLevel or nil
    row.minLevel, row.minLevelSource, row.minLevelItemLevel = level, source, at
    local cached = store.info[row.itemString]
    if cached then cached.minLevel, cached.minLevelSource, cached.minLevelItemLevel = level, source, at end
    return true
end

---true when a row's required level should be read (again): it is unknown (delayed or unreadable item data,
---an auction link not read yet, a cached row from an earlier search), or it came from the item key of
---another item level variant than the row shows now. Not after MAX_LEVEL_MISSES readable reads without one.
function M.LevelWanted(row)
    if not row.info or row.state == "notgear" or (row.levelMisses or 0) >= M.MAX_LEVEL_MISSES then return false end
    if row.minLevel == nil then return true end
    return row.minLevelSource == "key" and row.minLevelItemLevel ~= row.itemLevel
end

---The rows of an item: its browse rows and their auction rows.
function M.ItemRows(store, itemID)
    local out = {}
    for _, row in ipairs(store.byItem[tonumber(itemID) or 0] or {}) do
        out[#out + 1] = row
        for _, a in ipairs(row.auctions or {}) do out[#out + 1] = a end
    end
    return out
end

---true when the row's required level is its own item's: a fixed-stat item, the browse item key's (what the
---auction house itself shows for the row), or an auction row's own link. A random suffix group's base item
---level is a guess: its auctions' own links may need another level.
function M.LevelConfirmed(row)
    local s = row.minLevelSource
    if s == "link" or s == "key" then return true end
    return s == "item" and not row.approximate
end

---"Requires 15" when the row needs a higher level than the player's, "Requires 15?" when that level is only
---a guess (LevelConfirmed), else nil (also when either level is unknown). Only a label: such rows are not
---unusable, the player grows into them.
function M.LevelText(row, playerLevel)
    local need = row.minLevel
    if type(need) ~= "number" or type(playerLevel) ~= "number" or need <= playerLevel then return nil end
    return format("Requires %d", need) .. (M.LevelConfirmed(row) and "" or "?")
end

---Exact mode on: groups whose auctions were read are listed as their auction rows; off: as their own
---(starred) group rows. The auction rows are kept either way.
function M.SetExactView(store, on)
    store.useAuctions = on and true or false
    recount(store)
end

---SGJ's scores changed: forget every score and judge all gear rows again (groups and auction rows alike,
---listed or not).
function M.InvalidateScores(store)
    store.scores = {}
    local function reset(row)
        if row.info and M.IsGear(row.equipLoc) then resetScore(store, row) end
    end
    for _, row in ipairs(store.rows) do
        reset(row)
        for _, a in ipairs(row.auctions or {}) do reset(a) end
    end
    recount(store)
end

---Up to limit pending rows that are due, in browse order. No scan at all when no row is pending or
---none is due yet.
function M.NextBatch(store, now, limit)
    local batch = {}
    if store.pending <= 0 or now < store.nextDue then return batch end
    local nextDue = huge
    for _, row in ipairs(store.leaves) do
        if row.state == "pending" then
            local t = row.nextTry or 0
            if t <= now and #batch < limit then
                batch[#batch + 1] = row
            elseif t < nextDue then
                nextDue = t
            end
        end
    end
    -- the batch rows leave the pending state or set their own retry time through Defer
    store.nextDue = nextDue
    return batch
end

---Query states of random suffix groups: done means resolved, failed or timed out.
local QUERY_DONE = { resolved = true, failed = true, timeout = true }

---Counts of the listed rows. upgrades = confirmedUpgrades (a fixed-stat item or an auction row: an exact
---score) + estimatedUpgrades (a random suffix group listed with its starred base score). A group whose base
---score is not an upgrade is in neither, but is still looked up: its auctions may be. groups: random suffix
---gear groups; groupsDone: their item search finished (resolved, failed or timed out); groupsResolved: it
---returned auctions (checked; not necessarily every auction of the group).
function M.Counts(store)
    local c = { total = #store.rows, gear = 0, upgrades = 0, confirmedUpgrades = 0, estimatedUpgrades = 0,
        pending = 0, scored = 0, unusable = 0, error = 0, notgear = 0, resolving = 0, groups = 0, groupsDone = 0,
        groupsResolved = 0, groupsAwaitingInfo = 0 }
    for _, row in ipairs(store.rows) do
        if (row.suffix or 0) ~= 0 and not row.info and row.state == "pending" then
            c.groupsAwaitingInfo = c.groupsAwaitingInfo + 1
        elseif (row.suffix or 0) ~= 0 and row.info and row.state ~= "notgear" and row.state ~= "unusable" then
            c.groups = c.groups + 1
            local qs = row.query and row.query.state
            if row.auctions or qs == "resolved" then
                c.groupsDone, c.groupsResolved = c.groupsDone + 1, c.groupsResolved + 1
            elseif QUERY_DONE[qs] then
                c.groupsDone = c.groupsDone + 1
            end
        end
    end
    for _, row in ipairs(store.leaves) do
        local s = row.state
        if s == "notgear" then
            c.notgear = c.notgear + 1
        elseif not row.info then
            if s == "pending" then
                c.resolving, c.pending = c.resolving + 1, c.pending + 1
            else
                c.error = c.error + 1
            end
        else
            c.gear = c.gear + 1
            if s == "pending" then
                c.pending = c.pending + 1
            elseif s == "scored" then
                c.scored = c.scored + 1
                if row.upgradePct > 0 then
                    c.upgrades = c.upgrades + 1
                    if row.approximate and not row.isAuction then
                        c.estimatedUpgrades = c.estimatedUpgrades + 1
                    else
                        c.confirmedUpgrades = c.confirmedUpgrades + 1
                    end
                end
            elseif s == "unusable" then
                c.unusable = c.unusable + 1
            else
                c.error = c.error + 1
            end
        end
    end
    return c
end

---------------------------------------------------------------------------
-- View: filtering and sorting
---------------------------------------------------------------------------

M.COLUMNS = { "name", "price", "upgrade", "value" }
M.DEFAULT_DESC = { name = false, price = false, upgrade = true, value = true }

---Why a row is not listed, or nil when it is. options { upgradesOnly, hideUnusable }.
function M.HiddenReason(row, opts)
    local s = row.state
    if s == "notgear" then return "not gear" end
    if not row.info then return s == "pending" and "item info not loaded" or "item info failed" end
    if s == "unusable" and (opts.hideUnusable or opts.upgradesOnly) then return "unusable" end
    if opts.upgradesOnly then
        if s == "scored" then
            if row.upgradePct > 0 then return nil end
            return "not an upgrade"
        end
        if s == "pending" then return "not scored yet (upgrades only)" end
        return "scoring failed (upgrades only)"
    end
    return nil
end

---Rows to list: resolved gear only, as the options allow.
function M.Filter(store, opts)
    local out = {}
    for _, row in ipairs(store.leaves) do
        if not M.HiddenReason(row, opts) then out[#out + 1] = row end
    end
    return out
end

---------------------------------------------------------------------------
-- Diagnostics (built on demand only: the dump on close/logout, /aj debug <text>)
---------------------------------------------------------------------------

---A row as plain values.
function M.DumpRow(row, opts)
    local hidden = M.HiddenReason(row, opts)
    return {
        key = row.key, itemID = row.itemID, itemSuffix = row.suffix, itemLevel = row.itemLevel,
        itemString = row.itemString, name = row.name, link = row.link, equipLoc = row.equipLoc,
        state = row.state, reason = row.reason, sgjReason = row.sgjReason,
        upgradePct = row.upgradePct, itemScore = row.itemScore, equippedScore = row.equippedScore, slot = row.slot,
        price = row.price, value = row.value, shown = hidden == nil, hiddenBy = hidden,
        linkSource = row.linkSource, approximate = row.approximate == true, sgjLink = row.sgjLink,
        auction = row.isAuction == true, group = row.group and row.group.key or nil, bid = row.bid == true,
        auctionCount = row.auctionCount, identity = row.identity, query = M.QueryText(row),
        minLevel = row.minLevel, minLevelSource = row.minLevelSource, minLevelItemLevel = row.minLevelItemLevel,
        levelMisses = row.levelMisses,
    }
end

M.APPROXIMATE_NOTE = "base item score, exact auctions not read"

---A group's item search state as text, e.g. "resolved, 1 attempt, 23 results, 9 rows", or nil.
function M.QueryText(row)
    local q = row.query
    if not q then return nil end
    local text = q.state .. ", " .. (q.attempts or 0) .. " attempt" .. ((q.attempts or 0) == 1 and "" or "s")
    if q.results then text = text .. ", " .. q.results .. " results" end
    if row.auctions then text = text .. ", " .. #row.auctions .. " rows" end
    if q.reason then text = text .. " (" .. q.reason .. ")" end
    return text
end

---Listed rows (and groups whose auctions replaced them) whose name or item string contains text,
---case-insensitive.
function M.FindRows(store, text)
    local needle = text:lower()
    local out = {}
    local function check(row)
        local hay = (row.name or "") .. " " .. (row.itemString or "")
        if hay:lower():find(needle, 1, true) then out[#out + 1] = row end
    end
    for _, row in ipairs(store.rows) do
        check(row)
        for _, a in ipairs(row.auctions or {}) do check(a) end
    end
    return out
end

---The diagnostic dump: settings, counts, the listed rows (judged rows first, then not-gear rows, up to
---MAX_DUMP_ROWS), the random suffix groups with their item search state, and the browse results without
---a row of their own.
function M.Dump(store, opts)
    local rows = {}
    for pass = 1, 2 do
        for _, row in ipairs(store.leaves) do
            if #rows >= M.MAX_DUMP_ROWS then break end
            if (row.state == "notgear") == (pass == 2) then rows[#rows + 1] = M.DumpRow(row, opts) end
        end
    end
    local groups = {}
    for _, row in ipairs(store.rows) do
        if (row.suffix or 0) ~= 0 and row.state ~= "notgear" and #groups < M.MAX_DUMP_ROWS then
            local q = row.query or {}
            groups[#groups + 1] = { key = row.key, name = row.name, price = row.price, state = row.state,
                upgradePct = row.upgradePct, query = q.state or "none", attempts = q.attempts, results = q.results,
                reason = q.reason, auctionRows = row.auctions and #row.auctions or nil }
        end
    end
    local skipped = {}
    for i, s in ipairs(store.skipped or {}) do
        skipped[i] = { itemID = s.itemID, itemSuffix = s.itemSuffix, itemLevel = s.itemLevel, price = s.price,
            reason = s.reason }
    end
    return {
        filters = { upgradesOnly = opts.upgradesOnly == true, hideUnusable = opts.hideUnusable == true,
            sortColumn = opts.sortColumn, sortDesc = opts.sortDesc == true },
        counts = M.Counts(store),
        rawCount = store.lastCount, full = store.full, rowCount = #store.rows, leafCount = #store.leaves,
        rows = rows, groups = groups, skipped = skipped, skippedCount = store.skippedCount or 0,
        linkSources = M.LinkSourceCounts(store),
    }
end

local function v(x) return x == nil and "-" or tostring(x) end

---Two lines for /aj debug.
function M.DebugLines(d)
    local where
    if d.auction then
        where = "; auction of group " .. d.group .. (d.auctionCount and d.auctionCount > 1 and
            (" (" .. d.auctionCount .. " auctions of this item)") or "")
    else
        local resolved = d.query and d.query:find("^resolved")
        where = (d.query and ("; item search " .. d.query .. (resolved and ", listed as its auction rows" or "")) or "")
            .. ((d.approximate and not resolved) and ("; " .. M.APPROXIMATE_NOTE) or "")
    end
    return format("%s %s: %s%s%s; upgrade %s, item %s vs equipped %s (slot %s); price %s%s, value %s; %s",
            d.key, v(d.name), d.state, d.reason and (" (" .. d.reason .. ")") or "",
            d.sgjReason and (" SGJ " .. d.sgjReason) or "", v(d.upgradePct), v(d.itemScore), v(d.equippedScore),
            v(d.slot), v(d.price), d.bid and " (bid)" or "", v(d.value), d.shown and "shown" or ("hidden: " .. d.hiddenBy)),
        format("    id %s suffix %s ilvl %s, %s, %s, link (%s) %s, SGJ judged %s%s", v(d.itemID), v(d.itemSuffix),
            v(d.itemLevel), v(d.itemString), v(d.equipLoc), v(d.linkSource), v(d.link), v(d.sgjLink), where or "")
end

local RANK = { scored = 0, pending = 1, error = 2, unusable = 3 }

local function sortValue(row, col)
    if col == "name" then return row.sortName end
    if col == "price" then return row.price end
    if col == "upgrade" then return row.state == "scored" and row.upgradePct or nil end
    return row.value
end

---Sorts in place. Rows without a value for the column go last whatever the direction: scored rows
---first (by upgrade), then pending, error, unusable. Ties by name, then key.
function M.Sort(list, col, desc)
    table.sort(list, function(a, b)
        local va, vb = sortValue(a, col), sortValue(b, col)
        if va ~= nil and vb ~= nil then
            if va ~= vb then
                if desc then return va > vb end
                return va < vb
            end
        elseif va ~= nil then
            return true
        elseif vb ~= nil then
            return false
        else
            local ra, rb = RANK[a.state] or 9, RANK[b.state] or 9
            if ra ~= rb then return ra < rb end
            if a.state == "scored" and a.upgradePct ~= b.upgradePct then return a.upgradePct > b.upgradePct end
        end
        local na, nb = a.sortName or "", b.sortName or ""
        if na ~= nb then return na < nb end
        return a.key < b.key
    end)
    return list
end

function M.View(store, opts)
    return M.Sort(M.Filter(store, opts), opts.sortColumn or "value", opts.sortDesc ~= false)
end

---Header click: a new column starts in its natural direction, the same column reverses.
function M.ToggleSort(opts, col)
    if opts.sortColumn == col then
        opts.sortDesc = not opts.sortDesc
    else
        opts.sortColumn = col
        opts.sortDesc = M.DEFAULT_DESC[col]
    end
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

M.QUALITY_RGB = {
    [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 },
    [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 }, [6] = { 0.9, 0.8, 0.5 }, [7] = { 0, 0.8, 1 },
}
M.COLOR = { good = { 0.1, 1, 0.1 }, dim = { 0.6, 0.6, 0.6 }, bad = { 1, 0.35, 0.35 }, normal = { 1, 1, 1 } }

---Copper as shown in the list: from 1 gold up the copper part is dropped.
function M.DisplayCopper(copper)
    if type(copper) ~= "number" then return nil end
    copper = floor(copper)
    if copper >= 10000 then return floor(copper / 100) * 100 end
    return copper
end

---"12g 34s", "5s 20c", "7c"; nil price gives "?".
function M.FormatMoney(copper)
    copper = M.DisplayCopper(copper)
    if not copper then return "?" end
    local g, s, c = floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
    if g > 0 then
        if s > 0 then return format("%dg %ds", g, s) end
        return format("%dg", g)
    end
    if s > 0 then
        if c > 0 then return format("%ds %dc", s, c) end
        return format("%ds", s)
    end
    return format("%dc", c)
end

---Why a listed row's score is only its group's starred base score, or nil when the row is exact (a
---fixed-stat item, an auction row, or a group that will not be scored at all: unusable, not gear).
---ctx: { on = the "Scan specific items" setting, disabled = why searching is off this session,
---capReached = the queries of this search used up }. Such rows are drawn greyed.
function M.ScanState(row, ctx)
    if row.isAuction or not row.approximate then return nil end
    if row.state == "notgear" or row.state == "unusable" then return nil end
    if not ctx.on then return "Scan specific items is off" end
    if ctx.disabled then return "Lookup not available" end
    local qs = row.query and row.query.state
    if qs == "resolved" then return nil end
    if qs == "sent" then return "Looking up..." end
    if qs == "failed" or qs == "timeout" then return "Lookup failed" end
    if ctx.capReached then return "Not looked up (limit reached)" end
    return "Waiting to be looked up"
end

---Upgrade column text and colour key.
function M.FormatUpgrade(row)
    local s = row.state
    if s == "scored" then
        -- "*": a random suffix item judged as its base item
        return format("%+.1f%%", row.upgradePct) .. (row.approximate and "*" or ""),
            row.upgradePct > 0 and "good" or "dim"
    elseif s == "pending" then
        return "...", "dim"
    elseif s == "unusable" then
        return "unusable", "bad"
    end
    return "error", "bad"
end

---Value text: v is % per gold. Shown per silver ("0.84%/s") when the price is under 1 gold, per gold
---("0.84%/g") otherwise; sorting always uses v itself. Empty without a value.
function M.FormatValue(v, price)
    if type(v) ~= "number" then return "" end
    local unit = "g"
    if type(price) == "number" and price < 10000 then v, unit = v / 100, "s" end
    if v >= 100 then return format("%.0f%%/%s", v, unit) end
    if v >= 10 then return format("%.1f%%/%s", v, unit) end
    return format("%.2f%%/%s", v, unit)
end

local function plural(n, one, many) return format("%d %s", n, n == 1 and one or many) end

local DOT = " \194\183 " -- " · "

---The summary line: "498 gear items · 60 confirmed upgrades · 370 estimated · 4 pending". Confirmed: an exact
---score; estimated: random suffix groups whose starred base score is an upgrade (shown only when there are
---any). An estimate is neither a lower nor an upper bound: groups whose base score is not an upgrade are
---looked up too.
function M.CountLine(c)
    if c.total == 0 then return "No browse results yet: search the auction house." end
    local estimated = c.estimatedUpgrades or 0
    return plural(c.gear, "gear item", "gear items") .. DOT
        .. plural(c.confirmedUpgrades or 0, "confirmed upgrade", "confirmed upgrades")
        .. (estimated > 0 and (DOT .. estimated .. " estimated") or "") .. DOT .. c.pending .. " pending"
end

---Where the item searches for random suffix groups stand. lookup (Core's view.scan): { on = the setting,
---active = searches can go out, disabled = why not this session, cap, sent = this search, inflight }.
---  nil        nothing to look up, the setting is off, or nothing can be judged (SGJ missing)
---  disabled   the setting is on but the search API is missing or failed this session
---  pending    remaining groups are waiting for item info before they can be judged for lookup
---  complete   every group's search finished (some may have failed)
---  stopped    the cap is used up with groups left and nothing in flight (also a cap of 0)
---  looking    searches go on (queued, held, spaced, throttled, or the last one allowed in flight)
function M.LookupState(c, lookup)
    local groups, awaiting = c.groups or 0, c.groupsAwaitingInfo or 0
    if not (lookup and lookup.on) or (groups == 0 and awaiting == 0) then return nil end
    if lookup.disabled then return "disabled" end
    if not lookup.active then return nil end
    if (c.groupsDone or 0) >= groups then return awaiting > 0 and "pending" or "complete" end
    if not lookup.inflight and (lookup.sent or 0) >= (lookup.cap or huge) then return "stopped" end
    return "looking"
end

---The progress line under the summary: the item search state and the incomplete-browse notice, e.g.
---"Lookup limit 60 reached: 12/23 checked, 1 failed; more results not loaded", "Lookups complete: 18/18
---checked". "" when there is nothing to say. Checked: the group's item search returned auctions (it may not have listed every auction); failed:
---it timed out or could not be sent. Neither counts the other.
function M.ProgressLine(c, full, lookup)
    local parts = {}
    local state = M.LookupState(c, lookup)
    local checked, groups = c.groupsResolved or 0, c.groups or 0
    local failed = (c.groupsDone or 0) - checked
    local progress = checked .. "/" .. groups .. " checked" .. (failed > 0 and (", " .. failed .. " failed") or "")
    if state == "disabled" then
        parts[1] = "Lookup not available: " .. tostring(lookup.disabled)
    elseif state == "pending" then
        parts[1] = "Waiting for item info"
    elseif state == "stopped" then
        parts[1] = "Lookup limit " .. (lookup.cap or 0) .. " reached: " .. progress
    elseif state == "looking" then
        parts[1] = "Checking random-stat items: " .. progress
    elseif state == "complete" then
        parts[1] = "Lookups complete: " .. progress
    end
    if full == false then parts[#parts + 1] = #parts == 0 and "More results not loaded" or "more results not loaded" end
    return table.concat(parts, "; ")
end

M.COLUMN_LABEL = { name = "Item", price = "Price", upgrade = "Upgrade", value = "Value" }

function M.SortLabel(opts)
    return (M.COLUMN_LABEL[opts.sortColumn] or "?") .. (opts.sortDesc and " descending" or " ascending")
end
