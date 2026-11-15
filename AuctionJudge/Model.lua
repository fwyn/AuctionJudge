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

local huge = math.huge

function M.NewStore()
    return {
        rows = {},      -- in browse order
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
    local n = 0
    for _, row in ipairs(store.rows) do if row.state == "pending" then n = n + 1 end end
    store.pending = n
    store.nextDue = n > 0 and 0 or huge
end

---Forgets the rows (the auction house closed); the session caches stay.
function M.Clear(store)
    store.rows, store.byKey, store.byItem = {}, {}, {}
    store.lastCount = 0
    store.full = nil
    recount(store)
end

local function resetScore(store, row)
    row.upgradePct, row.value, row.specName, row.equipped, row.reason = nil, nil, nil, nil, nil
    setState(store, row, "pending")
    row.tries, row.nextTry = 0, 0
    markDue(store, 0)
end

local function setScore(store, row, result, reason)
    if result then
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

---Item info arrived for a row (from the game or the cache). Applies a cached score when there is one.
---info: { name, link, quality, icon, equipLoc }. equipLoc nil means unknown (unreadable): the row stays
---pending for a bounded retry and nothing is cached.
function M.ApplyInfo(store, row, info, now)
    if info.equipLoc == nil then
        M.Defer(store, row, now or 0, "EQUIP_LOC_UNKNOWN")
        return
    end
    store.info[row.itemString] = info
    row.info = true
    row.name, row.quality, row.icon, row.equipLoc = info.name, info.quality, info.icon, info.equipLoc
    row.link = info.link or row.itemString
    row.sortName = type(info.name) == "string" and info.name:lower() or ""
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
    else
        setState(store, row, "error")
        row.reason = reason or "ERROR"
    end
end

---Rebuilds the rows from browse entries { itemID, itemLevel, itemSuffix, minPrice, totalQuantity,
---equipLoc (optional instant hint, nil when unknown) }. One row per item string (item level variants
---merge); the lowest price wins. Rows already known keep their state; new rows take item info and
---scores from the session caches.
function M.Rebuild(store, entries)
    local old = store.byKey
    local rows, byKey, byItem = {}, {}, {}
    for _, e in ipairs(entries) do
        local id = tonumber(e.itemID)
        if id and id > 0 then
            local suffix, ilvl = tonumber(e.itemSuffix) or 0, tonumber(e.itemLevel) or 0
            local key = M.RowKey(id, suffix)
            local price = tonumber(e.minPrice)
            local row = byKey[key]
            if row then
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
                byKey[key] = row
                rows[#rows + 1] = row
                local list = byItem[id]
                if not list then list = {}; byItem[id] = list end
                list[#list + 1] = row
            end
        end
    end
    for _, row in ipairs(rows) do
        if row.state == "scored" then row.value = M.Value(row.upgradePct, row.price) end
    end
    store.rows, store.byKey, store.byItem = rows, byKey, byItem
    store.lastCount = #entries
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

---SGJ's scores changed: forget every score and judge all gear rows again.
function M.InvalidateScores(store)
    store.scores = {}
    for _, row in ipairs(store.rows) do
        if row.info and M.IsGear(row.equipLoc) then resetScore(store, row) end
    end
end

---Up to limit pending rows that are due, in browse order. No scan at all when no row is pending or
---none is due yet.
function M.NextBatch(store, now, limit)
    local batch = {}
    if store.pending <= 0 or now < store.nextDue then return batch end
    local nextDue = huge
    for _, row in ipairs(store.rows) do
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

function M.Counts(store)
    local c = { total = #store.rows, gear = 0, upgrades = 0, pending = 0, scored = 0, unusable = 0, error = 0,
        notgear = 0, resolving = 0 }
    for _, row in ipairs(store.rows) do
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
                if row.upgradePct > 0 then c.upgrades = c.upgrades + 1 end
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

---Rows to list: resolved gear only; options { upgradesOnly, hideUnusable }.
function M.Filter(store, opts)
    local out = {}
    for _, row in ipairs(store.rows) do
        local s = row.state
        local show = row.info and s ~= "notgear"
        if show and opts.upgradesOnly then show = s == "scored" and row.upgradePct > 0 end
        if show and opts.hideUnusable then show = s ~= "unusable" end
        if show then out[#out + 1] = row end
    end
    return out
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

---Upgrade column text and colour key.
function M.FormatUpgrade(row)
    local s = row.state
    if s == "scored" then
        return format("%+.1f%%", row.upgradePct), row.upgradePct > 0 and "good" or "dim"
    elseif s == "pending" then
        return "...", "dim"
    elseif s == "unusable" then
        return "unusable", "bad"
    end
    return "error", "bad"
end

---"0.84 %/g"; empty without a value.
function M.FormatValue(v)
    if type(v) ~= "number" then return "" end
    if v >= 100 then return format("%.0f %%/g", v) end
    if v >= 10 then return format("%.1f %%/g", v) end
    if v >= 0.01 then return format("%.2f %%/g", v) end
    return format("%.2g %%/g", v)
end

local function plural(n, one, many) return format("%d %s", n, n == 1 and one or many) end

---"37 gear items, 9 upgrades, 4 pending".
function M.CountLine(c, full)
    if c.total == 0 then return "No browse results yet: search the auction house." end
    local line = plural(c.gear, "gear item", "gear items") .. ", " .. plural(c.upgrades, "upgrade", "upgrades")
        .. ", " .. c.pending .. " pending"
    if full == false then line = line .. " (more results not loaded)" end
    return line
end

M.COLUMN_LABEL = { name = "Item", price = "Price", upgrade = "Upgrade", value = "% per gold" }

function M.SortLabel(opts)
    return (M.COLUMN_LABEL[opts.sortColumn] or "?") .. (opts.sortDesc and " descending" or " ascending")
end
