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

---Row info from the base item info (GetItemInfo of the item string: equip location; for a random suffix
---item possibly only the base item's name and link), the item key info ({ name, quality, icon } or nil)
---and the link read from the item key (or nil) with its source. Without a key link a suffixed row is
---approximate: its score is the base item's.
function M.MergeInfo(base, keyInfo, keyLink, keySource, suffix)
    keyInfo = keyInfo or {}
    local link = keyLink or base.link
    return {
        name = keyInfo.name or M.LinkName(keyLink) or base.name,
        link = link,
        linkSource = keyLink and keySource or "iteminfo",
        quality = keyInfo.quality or base.quality,
        icon = keyInfo.icon or base.icon,
        equipLoc = base.equipLoc,
        approximate = (tonumber(suffix) or 0) ~= 0 and keyLink == nil,
    }
end

---Splits an item hyperlink "<prefix>|Hitem:<payload>|h[<name>]|h<tail>". Payload fields after "item:":
---1 itemID, 2 enchant, 3-6 gems, 7 suffix, 8 unique, 9 link level, 10 spec, 11 modifiers mask,
---12 item context, 13 number of bonus IDs, 14.. the bonus IDs, then the rest (kept as is).
---Returns { prefix, head (fields 1-12), bonus (list), rest (list), name, tail } or nil.
function M.ParseLink(link)
    if type(link) ~= "string" then return nil end
    local prefix, payload, name, tail = link:match("^(.-)|Hitem:([^|]*)|h%[(.-)%]|h(.*)$")
    if not payload then return nil end
    local f = {}
    for x in (payload .. ":"):gmatch("([^:]*):") do f[#f + 1] = x end
    local head, bonus, rest = {}, {}, {}
    for i = 1, 12 do head[i] = f[i] or "" end
    local n = tonumber(f[13]) or 0
    local i = 14
    while #bonus < n and f[i] ~= nil do
        bonus[#bonus + 1] = f[i]
        i = i + 1
    end
    while f[i] ~= nil do
        rest[#rest + 1] = f[i]
        i = i + 1
    end
    return { prefix = prefix, head = head, bonus = bonus, rest = rest, name = name, tail = tail }
end

local function buildLink(p, head, bonus, name)
    local f = {}
    for i = 1, 12 do f[i] = head[i] end
    f[13] = #bonus > 0 and tostring(#bonus) or ""
    for _, b in ipairs(bonus) do f[#f + 1] = tostring(b) end
    for _, r in ipairs(p.rest) do f[#f + 1] = r end
    return p.prefix .. "|Hitem:" .. table.concat(f, ":") .. "|h[" .. name .. "]|h" .. p.tail
end

---Candidate links for a random suffix, built from a base hyperlink, in the order to try:
---  suffixbonus   bonus list replaced by 1:<suffix>
---  suffixbonus+  existing bonus IDs kept, the suffix appended (left out when it equals the first)
---  suffixfield   the legacy form: suffix in field 7, no bonus IDs
---The display name becomes name (the item key's suffixed name). Returns a list of { source, link }.
function M.SuffixCandidates(baseLink, suffix, name)
    local p = M.ParseLink(baseLink)
    if not p then return {} end
    suffix = tostring(suffix)
    name = name or p.name
    local out, seen = {}, {}
    local function add(source, link)
        if seen[link] then return end
        seen[link] = true
        out[#out + 1] = { source = source, link = link }
    end
    add("suffixbonus", buildLink(p, p.head, { suffix }, name))
    local more = {}
    for _, b in ipairs(p.bonus) do more[#more + 1] = b end
    more[#more + 1] = suffix
    add("suffixbonus+", buildLink(p, p.head, more, name))
    local legacy = {}
    for i = 1, 12 do legacy[i] = p.head[i] end
    legacy[7] = suffix
    add("suffixfield", buildLink(p, legacy, {}, name))
    return out
end

---Rows per link source (keytooltip[+lvl], scan:displayed / scan:data / scan:getitem[+lvl], suffixbonus,
---suffixbonus+, suffixfield, iteminfo), resolved rows only.
function M.LinkSourceCounts(store)
    local c = {}
    for _, row in ipairs(store.rows) do
        if row.info then
            local s = row.linkSource or "iteminfo"
            c[s] = (c[s] or 0) + 1
        end
    end
    return c
end

---Item info arrived for a row (from the game or the cache). Applies a cached score when there is one.
---info: { name, link, quality, icon, equipLoc }. equipLoc nil means unknown (unreadable): the row stays
---pending for a bounded retry and nothing is cached.
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
    row.baseLink, row.candidates = info.baseLink, info.candidates
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
    for _, row in ipairs(store.rows) do
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
        baseLink = row.baseLink, candidates = M.CopyCandidates(row.candidates),
    }
end

---Suffix link candidates as plain values: { source, link, name (GetItemInfo), tooltipName, accepted }.
function M.CopyCandidates(list)
    if not list then return nil end
    local out = {}
    for i, c in ipairs(list) do
        out[i] = { source = c.source, link = c.link, name = c.name, tooltipName = c.tooltipName,
            accepted = c.accepted == true }
    end
    return out
end

M.APPROXIMATE_NOTE = "base item score, suffix not resolved"

---Rows whose name (or item string) contains text, case-insensitive.
function M.FindRows(store, text)
    local needle = text:lower()
    local out = {}
    for _, row in ipairs(store.rows) do
        local hay = (row.name or "") .. " " .. (row.itemString or "")
        if hay:lower():find(needle, 1, true) then out[#out + 1] = row end
    end
    return out
end

---The diagnostic dump: settings, counts, rows (judged rows first, then not-gear rows, in browse order,
---up to MAX_DUMP_ROWS) and the browse results without a row of their own.
function M.Dump(store, opts)
    local rows = {}
    for pass = 1, 2 do
        for _, row in ipairs(store.rows) do
            if #rows >= M.MAX_DUMP_ROWS then break end
            if (row.state == "notgear") == (pass == 2) then rows[#rows + 1] = M.DumpRow(row, opts) end
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
        rawCount = store.lastCount, full = store.full, rowCount = #store.rows,
        rows = rows, skipped = skipped, skippedCount = store.skippedCount or 0,
        linkSources = M.LinkSourceCounts(store),
    }
end

local function v(x) return x == nil and "-" or tostring(x) end

---Lines for /aj debug: two per row, plus one per suffix link candidate tried.
function M.DebugLines(d)
    local extra = {}
    if d.baseLink then extra[#extra + 1] = "    suffix: base link " .. d.baseLink end
    for _, c in ipairs(d.candidates or {}) do
        extra[#extra + 1] = format("    try %s: item info %s, tooltip %s%s: %s", c.source, v(c.name), v(c.tooltipName),
            c.accepted and " ACCEPTED" or "", c.link)
    end
    return format("%s %s: %s%s%s; upgrade %s, item %s vs equipped %s (slot %s); price %s, value %s; %s",
            d.key, v(d.name), d.state, d.reason and (" (" .. d.reason .. ")") or "",
            d.sgjReason and (" SGJ " .. d.sgjReason) or "", v(d.upgradePct), v(d.itemScore), v(d.equippedScore),
            v(d.slot), v(d.price), v(d.value), d.shown and "shown" or ("hidden: " .. d.hiddenBy)),
        format("    id %s suffix %s ilvl %s, %s, %s, link (%s) %s, SGJ judged %s%s", v(d.itemID), v(d.itemSuffix),
            v(d.itemLevel), v(d.itemString), v(d.equipLoc), v(d.linkSource), v(d.link), v(d.sgjLink),
            d.approximate and ("; " .. M.APPROXIMATE_NOTE) or ""),
        extra
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

---Value text: v is % per gold. Shown per silver ("0.84 %/s") when the price is under 1 gold, per gold
---("0.84 %/g") otherwise; sorting always uses v itself. Empty without a value.
function M.FormatValue(v, price)
    if type(v) ~= "number" then return "" end
    local unit = "g"
    if type(price) == "number" and price < 10000 then v, unit = v / 100, "s" end
    if v >= 100 then return format("%.0f %%/%s", v, unit) end
    if v >= 10 then return format("%.1f %%/%s", v, unit) end
    if v >= 0.01 then return format("%.2f %%/%s", v, unit) end
    return format("%.2g %%/%s", v, unit)
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

M.COLUMN_LABEL = { name = "Item", price = "Price", upgrade = "Upgrade", value = "Value" }

function M.SortLabel(opts)
    return (M.COLUMN_LABEL[opts.sortColumn] or "?") .. (opts.sortDesc and " descending" or " ascending")
end
