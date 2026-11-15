-- Unit tests of the pure model (Model.lua).
local H = ...
local test, eq, ok, near = H.test, H.eq, H.ok, H.near

local ns = {}
H.load("Model.lua", ns)
local M = ns.Model

local function info(name, equipLoc, extra)
    local t = { name = name, link = "|cff1eff00|Hitem:" .. name .. "|h[" .. name .. "]|h|r", quality = 2,
        equipLoc = equipLoc or "INVTYPE_CHEST" }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

-- A store with resolved, scored rows: { name, price, state, pct }.
local function scoredStore(spec)
    local store = M.NewStore()
    local entries = {}
    for i, s in ipairs(spec) do entries[i] = { itemID = i, minPrice = s[2] } end
    M.Rebuild(store, entries)
    for i, s in ipairs(spec) do
        local row = store.rows[i]
        M.ApplyInfo(store, row, info(s[1]))
        local state = s[3]
        if state == "scored" then
            M.ApplyScore(store, row, { upgradePct = s[4], specName = "Spec" }, nil, 0)
        elseif state == "unusable" then
            M.ApplyScore(store, row, nil, "NOT_USABLE", 0)
        elseif state == "error" then
            M.ApplyScore(store, row, nil, "ERROR", 0)
        end -- "pending": leave
    end
    return store
end

local function names(list)
    local out = {}
    for i, r in ipairs(list) do out[i] = r.name end
    return table.concat(out, ",")
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

test("item string without a suffix", function()
    eq(M.ItemString(19019), "item:19019", "no suffix")
    eq(M.ItemString(19019, 0), "item:19019", "suffix 0")
    eq(M.ItemString("19019", nil), "item:19019", "string id, nil suffix")
    eq(M.ItemString(nil, 5), nil, "no item id")
end)

test("item string with a suffix puts it in the 7th field", function()
    local s = M.ItemString(15210, 1200)
    eq(s, "item:15210::::::1200", "suffix")
    local fields = {}
    for f in (s:sub(6) .. ":"):gmatch("([^:]*):") do fields[#fields + 1] = f end
    eq(fields[1], "15210", "1st field item id")
    eq(fields[7], "1200", "7th field suffix")
    eq(M.ItemString(15210, -37), "item:15210::::::-37", "negative suffix kept")
end)

test("row key: item and suffix, the same parts as the item string", function()
    ok(M.RowKey(1, 0) ~= M.RowKey(1, 5), "suffix")
    eq(M.RowKey(1, nil), "1:0", "missing suffix is 0")
end)

test("gear filter by equip location", function()
    for _, loc in ipairs({ "INVTYPE_HEAD", "INVTYPE_CHEST", "INVTYPE_ROBE", "INVTYPE_WEAPON", "INVTYPE_2HWEAPON",
        "INVTYPE_FINGER", "INVTYPE_TRINKET", "INVTYPE_RANGED", "INVTYPE_CLOAK", "INVTYPE_HOLDABLE", "INVTYPE_RELIC" }) do
        eq(M.IsGear(loc), true, loc)
    end
    for _, loc in ipairs({ "INVTYPE_BAG", "INVTYPE_QUIVER", "INVTYPE_TABARD", "INVTYPE_BODY", "INVTYPE_NON_EQUIP",
        "INVTYPE_NON_EQUIP_IGNORE", "" }) do
        eq(M.IsGear(loc), false, loc)
    end
    eq(M.IsGear(nil), false, "nil")
end)

---------------------------------------------------------------------------
-- Rebuild
---------------------------------------------------------------------------

test("duplicate item keys keep the lower price, in either order", function()
    local store = M.NewStore()
    M.Rebuild(store, {
        { itemID = 10, itemLevel = 60, minPrice = 5000, totalQuantity = 1 },
        { itemID = 10, itemLevel = 60, minPrice = 3000, totalQuantity = 2 },
        { itemID = 11, minPrice = 100 },
        { itemID = 11, minPrice = 900 },
        { itemID = 10, itemLevel = 60, itemSuffix = 7, minPrice = 8000 },
    })
    eq(#store.rows, 3, "rows")
    eq(store.byKey["10:0"].price, 3000, "lower second")
    eq(store.byKey["10:0"].quantity, 2, "quantity of the cheaper entry")
    eq(store.byKey["11:0"].price, 100, "lower first")
    eq(store.byKey["10:7"].price, 8000, "suffix row separate")
    eq(store.byKey["10:7"].itemString, "item:10::::::7", "suffix row item string")
    eq(#store.byItem[10], 2, "both rows indexed by item id")
    eq(store.lastCount, 5, "entries counted")
end)

test("item level variants of one item string are one row with the lowest price (one link, one score)", function()
    local store = M.NewStore()
    M.Rebuild(store, {
        { itemID = 20, itemLevel = 60, minPrice = 9000 },
        { itemID = 20, itemLevel = 63, minPrice = 4000 },
        { itemID = 20, itemLevel = 58, minPrice = 6000 },
    })
    eq(#store.rows, 1, "one row")
    local row = store.rows[1]
    eq(row.price, 4000, "lowest price")
    eq(row.itemLevel, 63, "item level of the cheapest entry")
    eq(#M.NextBatch(store, 0, 20), 1, "scored once")
end)

test("rebuild skips bad entries, keeps known rows, takes info and scores from the caches", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 1, minPrice = 100 }, { itemID = 0 }, { itemID = nil }, { itemID = "x" } })
    eq(#store.rows, 1, "only the valid entry")
    local row = store.rows[1]
    M.ApplyInfo(store, row, info("Vest"))
    M.ApplyScore(store, row, { upgradePct = 2 }, nil, 0)
    near(row.value, 2 / 0.01, "value at 1s")

    M.Rebuild(store, { { itemID = 1, minPrice = 200 } })
    ok(store.rows[1] == row, "same row object kept")
    near(row.value, 2 / 0.02, "value follows the new price")

    M.Clear(store)
    eq(#store.rows, 0, "cleared")
    M.Rebuild(store, { { itemID = 1, minPrice = 400 } })
    local again = store.rows[1]
    ok(again ~= row, "a new row after clearing")
    eq(again.state, "scored", "score from the cache")
    near(again.value, 2 / 0.04, "value from the cached score and the new price")
    eq(again.name, "Vest", "info from the cache")
end)

test("an instant equip location that is not gear skips resolution", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 1, equipLoc = "" }, { itemID = 2, equipLoc = "INVTYPE_BAG" },
        { itemID = 3, equipLoc = "INVTYPE_FEET" }, { itemID = 4 } })
    eq(store.rows[1].state, "notgear", "empty equip loc")
    eq(store.rows[2].state, "notgear", "bag")
    eq(store.rows[3].state, "pending", "gear still needs item info")
    eq(store.rows[4].state, "pending", "unknown")
    eq(#M.NextBatch(store, 0, 20), 2, "only the possible gear is worked on")
end)

---------------------------------------------------------------------------
-- Value and scores
---------------------------------------------------------------------------

test("value: upgrade per gold and its edge cases", function()
    near(M.Value(4.2, 50000), 0.84, "4.2% at 5g")
    near(M.Value(1, 10000), 1, "1% at 1g")
    near(M.Value(1, 50), 200, "1% at 50c")
    eq(M.Value(4.2, 0), nil, "zero price")
    eq(M.Value(4.2, nil), nil, "no price")
    eq(M.Value(-1.3, 50000), nil, "negative upgrade")
    eq(M.Value(0, 50000), nil, "no upgrade")
    eq(M.Value(nil, 50000), nil, "no score")
end)

test("score outcomes set the row state; final ones are cached per link", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 1, minPrice = 10000 }, { itemID = 2, minPrice = 10000 }, { itemID = 3 },
        { itemID = 4 }, { itemID = 5 }, { itemID = 6 } })
    local r = store.rows
    for i = 1, 6 do M.ApplyInfo(store, r[i], info("I" .. i)) end
    M.ApplyScore(store, r[1], { upgradePct = 3, specName = "Holy", equipped = false }, nil, 0)
    M.ApplyScore(store, r[2], nil, "NOT_USABLE", 0)
    M.ApplyScore(store, r[3], nil, "NOT_EQUIPPABLE", 0)
    M.ApplyScore(store, r[4], nil, "NOT_CACHED", 10)
    M.ApplyScore(store, r[5], nil, "ERROR", 0)
    M.ApplyScore(store, r[6], { upgradePct = nil }, nil, 0)
    eq(r[1].state, "scored", "scored")
    eq(r[1].specName, "Holy", "spec kept")
    near(r[1].value, 3, "value")
    eq(r[2].state, "unusable", "unusable")
    eq(r[3].state, "notgear", "SGJ: not equippable")
    eq(r[4].state, "pending", "not cached: retry")
    eq(r[4].nextTry, 10 + M.RETRY_BASE, "retry later")
    eq(r[5].state, "error", "error")
    eq(r[5].reason, "ERROR", "reason")
    eq(r[6].state, "error", "no percentage")
    ok(store.scores[r[1].link] and store.scores[r[2].link] and store.scores[r[3].link], "final outcomes cached")
    eq(store.scores[r[4].link], nil, "pending not cached")
    eq(store.scores[r[5].link], nil, "errors not cached: tried again with the next results")
end)

test("item info that is not gear makes the row not gear", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 1 } })
    M.ApplyInfo(store, store.rows[1], info("Linen Cloth", ""))
    eq(store.rows[1].state, "notgear", "state")
    eq(store.rows[1].link, "|cff1eff00|Hitem:Linen Cloth|h[Linen Cloth]|h|r", "link kept")
    M.Rebuild(store, { { itemID = 1 } })
    M.ApplyInfo(store, store.rows[1], { name = "No Link", equipLoc = "INVTYPE_HEAD" })
    eq(store.rows[1].link, "item:1", "item string when the client gives no link")
end)

---------------------------------------------------------------------------
-- Batches
---------------------------------------------------------------------------

test("batches: limited size, due rows only, backoff, give up", function()
    local store = M.NewStore()
    local entries = {}
    for i = 1, 45 do entries[i] = { itemID = i } end
    M.Rebuild(store, entries)
    local b1 = M.NextBatch(store, 0, 20)
    eq(#b1, 20, "first batch limited")
    eq(b1[1].itemID, 1, "browse order")
    for _, row in ipairs(b1) do M.Defer(store, row, 0, "ITEM_INFO") end
    local b2 = M.NextBatch(store, 0, 20)
    eq(#b2, 20, "second batch")
    eq(b2[1].itemID, 21, "deferred rows are not due")
    for _, row in ipairs(b2) do M.Defer(store, row, 0, "ITEM_INFO") end
    eq(#M.NextBatch(store, 0, 20), 5, "the rest")
    eq(#M.NextBatch(store, M.RETRY_BASE, 100), 45, "all due after the first delay")

    local row = store.rows[1]
    local delays = {}
    for i = 2, 6 do
        M.Defer(store, row, 100, "ITEM_INFO")
        delays[#delays + 1] = row.nextTry - 100
    end
    eq(table.concat(delays, ","), "1,2,4,5,5", "doubling up to the maximum")
    for _ = 7, M.MAX_TRIES do M.Defer(store, row, 100, "NOT_READY") end
    eq(row.state, "error", "gave up")
    eq(row.reason, "GAVE_UP NOT_READY", "reason names the last wait")
end)

test("unknown equip location (unreadable) is not \"not gear\": it waits for a bounded retry, uncached", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 1, equipLoc = nil }, { itemID = 2 } })
    eq(store.rows[1].state, "pending", "unknown instant equip location stays eligible")
    local row = store.rows[2]
    M.ApplyInfo(store, row, { name = "Veiled Gloves", link = "|Hitem:2|h", equipLoc = nil }, 10)
    eq(row.state, "pending", "unknown full-info equip location: pending")
    eq(row.info, nil, "info not taken")
    eq(row.reason, "EQUIP_LOC_UNKNOWN", "reason")
    eq(row.nextTry, 10 + M.RETRY_BASE, "retried later")
    eq(store.info[row.itemString], nil, "never cached")
    M.ApplyInfo(store, row, { name = "Veiled Gloves", link = "|Hitem:2|h", equipLoc = "INVTYPE_HANDS" }, 11)
    eq(row.state, "pending", "now known gear: waiting for a score")
    eq(row.info, true, "info taken")
    eq(row.tries, 0, "tries reset for scoring")
    for i = 1, M.MAX_TRIES do M.ApplyInfo(store, store.rows[1], { name = "X", equipLoc = nil }, i) end
    eq(store.rows[1].state, "error", "bounded: gives up as an error, not as not gear")
end)

test("pending count: batches do no scan when nothing is pending or due", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 1 }, { itemID = 2 }, { itemID = 3, equipLoc = "" } })
    eq(store.pending, 2, "two pending after rebuild")
    M.ApplyInfo(store, store.rows[1], info("A"), 0)
    M.ApplyScore(store, store.rows[1], { upgradePct = 1 }, nil, 0)
    M.ApplyInfo(store, store.rows[2], info("B", "INVTYPE_BAG"), 0)
    eq(store.pending, 0, "none pending")
    -- a pending row slipped in behind the bookkeeping would be found by any scan
    local sentinel = { key = "s", state = "pending", nextTry = 0 }
    table.insert(store.rows, sentinel)
    eq(#M.NextBatch(store, 100, 20), 0, "no scan with nothing pending")
    table.remove(store.rows)

    M.InvalidateScores(store)
    eq(store.pending, 1, "the scored gear row is pending again")
    eq(#M.NextBatch(store, 0, 20), 1, "and due")
    M.Defer(store, store.rows[1], 0, "NOT_READY")
    eq(store.nextDue, M.RETRY_BASE, "next due at the retry")
    table.insert(store.rows, sentinel)
    eq(#M.NextBatch(store, 0.1, 20), 0, "no scan before the next retry is due")
    table.remove(store.rows)
    eq(#M.NextBatch(store, M.RETRY_BASE, 20), 1, "due again")
    M.Clear(store)
    eq(store.pending, 0, "cleared")
end)

test("item info arriving makes waiting rows of that item due", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 7 }, { itemID = 7, itemSuffix = 3 }, { itemID = 8 } })
    for _, row in ipairs(store.rows) do M.Defer(store, row, 0, "ITEM_INFO") end
    eq(#M.NextBatch(store, 0.1, 20), 0, "none due")
    eq(M.InfoArrived(store, 7), true, "rows found")
    eq(M.InfoArrived(store, 99), false, "unknown item")
    local due = M.NextBatch(store, 0.1, 20)
    eq(#due, 2, "both rows of item 7")
end)

test("SCORES_CHANGED resets gear rows and drops the cache, not-gear rows stay", function()
    local store = scoredStore({ { "A", 10000, "scored", 2 }, { "B", 10000, "unusable" }, { "C", 10000, "pending" } })
    M.Rebuild(store, { { itemID = 1, minPrice = 10000 }, { itemID = 2, minPrice = 10000 }, { itemID = 3, minPrice = 10000 },
        { itemID = 4, equipLoc = "" } })
    M.Defer(store, store.rows[3], 0, "NOT_READY")
    M.InvalidateScores(store)
    eq(next(store.scores), nil, "cache dropped")
    for i = 1, 3 do
        eq(store.rows[i].state, "pending", "row " .. i .. " pending")
        eq(store.rows[i].nextTry, 0, "row " .. i .. " due now")
        eq(store.rows[i].upgradePct, nil, "row " .. i .. " old score gone")
    end
    eq(store.rows[4].state, "notgear", "not gear untouched")
end)

---------------------------------------------------------------------------
-- Filter and sort
---------------------------------------------------------------------------

local SPEC = {
    { "Alpha", 20000, "scored", 4 },    -- value 2
    { "Bravo", 5000, "scored", 1 },     -- value 2, cheaper
    { "Charlie", 100000, "scored", 9 }, -- value 0.9
    { "Delta", 1000, "scored", -2 },    -- downgrade, no value
    { "Echo", 3000, "pending" },
    { "Foxtrot", 2000, "unusable" },
    { "Golf", 4000, "error" },
}

test("filters: upgrades only, hide unusable", function()
    local store = scoredStore(SPEC)
    M.Rebuild(store, { { itemID = 1, minPrice = 20000 }, { itemID = 2, minPrice = 5000 }, { itemID = 3, minPrice = 100000 },
        { itemID = 4, minPrice = 1000 }, { itemID = 5, minPrice = 3000 }, { itemID = 6, minPrice = 2000 },
        { itemID = 7, minPrice = 4000 }, { itemID = 8, minPrice = 10 }, { itemID = 9, equipLoc = "" } })
    -- row 8: unresolved, row 9: not gear: never listed
    local function count(opts) return #M.Filter(store, opts) end
    eq(count({ upgradesOnly = true, hideUnusable = true }), 3, "upgrades only")
    eq(count({ upgradesOnly = true, hideUnusable = false }), 3, "upgrades are usable")
    eq(count({ upgradesOnly = false, hideUnusable = true }), 6, "all resolved gear but unusable")
    eq(count({ upgradesOnly = false, hideUnusable = false }), 7, "all resolved gear")
end)

test("sort by % per gold: value, then rows without one (scored by upgrade, pending, error, unusable)", function()
    local store = scoredStore(SPEC)
    local all = { upgradesOnly = false, hideUnusable = false }
    eq(names(M.Sort(M.Filter(store, all), "value", true)), "Alpha,Bravo,Charlie,Delta,Echo,Golf,Foxtrot", "descending")
    eq(names(M.Sort(M.Filter(store, all), "value", false)), "Charlie,Alpha,Bravo,Delta,Echo,Golf,Foxtrot",
        "ascending: rows without a value still last")
end)

test("sort by upgrade", function()
    local store = scoredStore(SPEC)
    local all = { upgradesOnly = false, hideUnusable = false }
    eq(names(M.Sort(M.Filter(store, all), "upgrade", true)), "Charlie,Alpha,Bravo,Delta,Echo,Golf,Foxtrot", "descending")
    eq(names(M.Sort(M.Filter(store, all), "upgrade", false)), "Delta,Bravo,Alpha,Charlie,Echo,Golf,Foxtrot", "ascending")
end)

test("sort by price and by name", function()
    local store = scoredStore(SPEC)
    local all = { upgradesOnly = false, hideUnusable = false }
    eq(names(M.Sort(M.Filter(store, all), "price", false)), "Delta,Foxtrot,Echo,Golf,Bravo,Alpha,Charlie", "price ascending")
    eq(names(M.Sort(M.Filter(store, all), "price", true)), "Charlie,Alpha,Bravo,Golf,Echo,Foxtrot,Delta", "price descending")
    eq(names(M.Sort(M.Filter(store, all), "name", false)), "Alpha,Bravo,Charlie,Delta,Echo,Foxtrot,Golf", "name ascending")
    eq(names(M.Sort(M.Filter(store, all), "name", true)), "Golf,Foxtrot,Echo,Delta,Charlie,Bravo,Alpha", "name descending")
    store.rows[1].price = nil
    eq(names(M.Sort(M.Filter(store, all), "price", true)):sub(-5), "Alpha", "no price: last")
end)

test("view uses the saved sort; header clicks pick a natural direction, then reverse", function()
    local store = scoredStore(SPEC)
    local opts = { upgradesOnly = true, hideUnusable = true, sortColumn = "value", sortDesc = true }
    eq(names(M.View(store, opts)), "Alpha,Bravo,Charlie", "default % per gold descending")
    M.ToggleSort(opts, "value")
    eq(opts.sortDesc, false, "same column reverses")
    M.ToggleSort(opts, "price")
    eq(opts.sortColumn .. tostring(opts.sortDesc), "pricefalse", "price starts ascending")
    eq(names(M.View(store, opts)), "Bravo,Alpha,Charlie", "by price")
    M.ToggleSort(opts, "upgrade")
    eq(opts.sortColumn .. tostring(opts.sortDesc), "upgradetrue", "upgrade starts descending")
    M.ToggleSort(opts, "name")
    eq(opts.sortColumn .. tostring(opts.sortDesc), "namefalse", "name starts ascending")
    eq(M.SortLabel({ sortColumn = "value", sortDesc = true }), "Value descending", "label")
end)

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

test("money formatting", function()
    eq(M.FormatMoney(0), "0c", "zero")
    eq(M.FormatMoney(7), "7c", "copper")
    eq(M.FormatMoney(520), "5s 20c", "silver and copper")
    eq(M.FormatMoney(500), "5s", "silver")
    eq(M.FormatMoney(123456), "12g 34s", "gold drops copper")
    eq(M.FormatMoney(120000), "12g", "even gold")
    eq(M.FormatMoney(120056), "12g", "gold with only copper")
    eq(M.FormatMoney(nil), "?", "no price")
    eq(M.DisplayCopper(123456), 123400, "coin text without copper from 1g")
    eq(M.DisplayCopper(9999), 9999, "below 1g unchanged")
end)

test("upgrade and value formatting", function()
    local function up(row) local t, c = M.FormatUpgrade(row); return t .. " " .. c end
    eq(up({ state = "scored", upgradePct = 4.2 }), "+4.2% good", "upgrade")
    eq(up({ state = "scored", upgradePct = -1.3 }), "-1.3% dim", "downgrade")
    eq(up({ state = "scored", upgradePct = 0 }), "+0.0% dim", "no change")
    eq(up({ state = "pending" }), "... dim", "pending")
    eq(up({ state = "unusable" }), "unusable bad", "unusable")
    eq(up({ state = "error" }), "error bad", "error")
    eq(M.FormatValue(0.84), "0.84 %/g", "value")
    eq(M.FormatValue(12.345), "12.3 %/g", "tens")
    eq(M.FormatValue(250), "250 %/g", "hundreds")
    eq(M.FormatValue(0.0012), "0.0012 %/g", "tiny")
    eq(M.FormatValue(nil), "", "no value")
end)

test("value is shown per silver under 1 gold, per gold from 1 gold; sorting uses the true ratio", function()
    eq(M.FormatValue(M.Value(4.2, 50000), 50000), "0.84 %/g", "4.2% at 5g")
    eq(M.FormatValue(M.Value(4.2, 500), 500), "0.84 %/s", "4.2% at 5s")
    eq(M.FormatValue(M.Value(1, 10000), 10000), "1.00 %/g", "exactly 1g: per gold")
    eq(M.FormatValue(M.Value(1, 9999), 9999), "0.01 %/s", "just under 1g: per silver")
    local store = scoredStore({ { "Cheap", 500, "scored", 0.5 }, { "Dear", 20000, "scored", 4 } })
    -- Cheap: 0.5% at 5s = 10 %/g (shown 0.10 %/s); Dear: 4% at 2g = 2 %/g (shown 2.00 %/g)
    eq(names(M.Sort(M.Filter(store, {}), "value", true)), "Cheap,Dear", "order by the true ratio")
    eq(M.FormatValue(store.rows[1].value, store.rows[1].price), "0.10 %/s", "cheap shown per silver")
end)

test("hidden reasons follow the filters", function()
    local store = scoredStore(SPEC)
    M.Rebuild(store, { { itemID = 1 }, { itemID = 2 }, { itemID = 3 }, { itemID = 4 }, { itemID = 5 }, { itemID = 6 },
        { itemID = 7 }, { itemID = 8 }, { itemID = 9, equipLoc = "" } })
    local r = store.rows
    local on = { upgradesOnly = true, hideUnusable = true }
    local off = { upgradesOnly = false, hideUnusable = false }
    eq(M.HiddenReason(r[1], on), nil, "upgrade shown")
    eq(M.HiddenReason(r[4], on), "not an upgrade", "downgrade")
    eq(M.HiddenReason(r[5], on), "not scored yet (upgrades only)", "pending")
    eq(M.HiddenReason(r[6], on), "unusable", "unusable")
    eq(M.HiddenReason(r[6], { hideUnusable = true }), "unusable", "unusable, all gear")
    eq(M.HiddenReason(r[7], on), "scoring failed (upgrades only)", "error")
    eq(M.HiddenReason(r[8], off), "item info not loaded", "unresolved")
    eq(M.HiddenReason(r[9], off), "not gear", "not gear")
    for i = 1, 7 do eq(M.HiddenReason(r[i], off), nil, "row " .. i .. " shown without filters") end
end)

test("dump: plain values, judged rows first, rows and skipped results capped", function()
    local store = M.NewStore()
    local entries = { { itemID = 9, equipLoc = "" }, { itemID = 1, itemSuffix = 7, itemLevel = 60, minPrice = 500 },
        { itemID = 1, itemSuffix = 7, itemLevel = 62, minPrice = 900 }, { itemID = 0 } }
    M.Rebuild(store, entries, { { itemID = 5, reason = "battle pet" } })
    local row = store.byKey["1:7"]
    M.ApplyInfo(store, row, info("Cloak", "INVTYPE_CLOAK"), 0)
    M.ApplyScore(store, row, { upgradePct = -2, itemScore = 30, equippedScore = 31, slot = 15, specName = "S" }, nil, 0)
    local d = M.Dump(store, { upgradesOnly = true, hideUnusable = true, sortColumn = "value", sortDesc = true })
    eq(d.rawCount, 4, "raw count")
    eq(d.rowCount, 2, "rows")
    eq(d.rows[1].key, "1:7", "judged row first")
    eq(d.rows[2].hiddenBy, "not gear", "not-gear row after")
    local c = d.rows[1]
    eq(c.itemSuffix .. " " .. c.itemLevel .. " " .. c.itemString, "7 60 item:1::::::7", "key parts")
    eq(c.itemScore .. " " .. c.equippedScore .. " " .. c.slot .. " " .. c.upgradePct, "30 31 15 -2", "score parts")
    eq(c.shown, false, "hidden")
    eq(c.hiddenBy, "not an upgrade", "why")
    eq(d.skippedCount, 3, "pet, merged variant, bad id")
    eq(d.skipped[1].reason, "battle pet", "from the reader")
    eq(d.skipped[2].reason, "merged into row 1:7 (lowest price kept)", "merged")
    eq(d.skipped[2].itemLevel, 62, "merged entry item level")
    eq(d.skipped[3].reason, "bad item id", "bad id")
    eq(d.counts.notgear, 1, "counts")
    local function plainOnly(t, path)
        for k, v in pairs(t) do
            local tv = type(v)
            if tv == "table" then plainOnly(v, path .. "." .. tostring(k))
            elseif tv ~= "string" and tv ~= "number" and tv ~= "boolean" then error(path .. "." .. k .. " is " .. tv) end
        end
    end
    plainOnly(d, "dump")
    ok(d.rows[1] ~= row, "a copy, not the row")

    local big = M.NewStore()
    local many = {}
    for i = 1, 450 do many[i] = { itemID = i } end
    for i = 1, 120 do many[#many + 1] = { itemID = 1 } end
    M.Rebuild(big, many)
    local bd = M.Dump(big, {})
    eq(#bd.rows, M.MAX_DUMP_ROWS, "rows capped")
    eq(#bd.skipped, M.MAX_SKIPPED, "skipped capped")
    eq(bd.skippedCount, 120, "but all counted")
end)

test("debug lookup: by name, case-insensitive, hidden rows included", function()
    local store = scoredStore(SPEC)
    local found = M.FindRows(store, "ECHO")
    eq(#found, 1, "one match")
    local a, b = M.DebugLines(M.DumpRow(found[1], { upgradesOnly = true }))
    ok(a:find("Echo: pending", 1, true) and a:find("hidden: not scored yet", 1, true), "state and why: " .. a)
    ok(b:find("id 5 suffix 0", 1, true) and b:find("item:5", 1, true), "key parts: " .. b)
    eq(#M.FindRows(store, "item:3"), 1, "item string matches too")
    eq(#M.FindRows(store, "zulu"), 0, "no match")
end)

test("random suffix groups: key name, base link, approximate; which rows need an item search", function()
    local base = { name = "Cadet Vest", link = "|cff1eff00|Hitem:501|h[Cadet Vest]|h|r", quality = 2, icon = 1,
        equipLoc = "INVTYPE_CHEST" }
    local g = M.MergeInfo(base, { name = "Cadet Vest of the Whale", quality = 3, icon = 7 }, 14301)
    eq(g.name .. "|" .. g.link .. "|" .. g.linkSource, "Cadet Vest of the Whale|" .. base.link .. "|iteminfo", "group info")
    eq(g.quality .. " " .. g.icon .. " " .. g.equipLoc .. " " .. tostring(g.approximate), "3 7 INVTYPE_CHEST true", "parts")
    local f = M.MergeInfo(base, nil, 0)
    eq(f.name .. " " .. tostring(f.approximate), "Cadet Vest false", "fixed-stat item: exact")
    eq(M.LinkName("|cnIQ2:|Hitem:501::::::::15:1486:::1:12725::::::|h[Cadet Vest of Healing]|h|r"), "Cadet Vest of Healing",
        "link name")
    eq(M.LinkName("item:5"), nil, "no name in an item string")

    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 501, itemSuffix = 14301 }, { itemID = 601 }, { itemID = 701, itemSuffix = 14301 },
        { itemID = 801, itemSuffix = 14301 } })
    local r = store.rows
    M.ApplyInfo(store, r[1], g, 0)
    M.ApplyInfo(store, r[2], f, 0)
    M.ApplyInfo(store, r[3], M.MergeInfo(base, nil, 14301), 0)
    M.ApplyScore(store, r[1], { upgradePct = 2.5 }, nil, 0)
    M.ApplyScore(store, r[2], { upgradePct = 3 }, nil, 0)
    M.ApplyScore(store, r[3], nil, "NOT_USABLE", 0)
    eq(store.info["item:501::::::14301"], nil, "approximate info not cached")
    eq(M.NeedsQuery(r[1]), true, "scored random suffix group")
    eq(M.NeedsQuery(r[2]), false, "fixed-stat item")
    eq(M.NeedsQuery(r[3]), false, "unusable group")
    eq(M.NeedsQuery(r[4]), false, "not resolved yet")
    r[1].query = { state = "queued" }
    eq(M.NeedsQuery(r[1]), false, "already queued")
    eq((M.FormatUpgrade(r[1])), "+2.5%*", "group starred")
end)

test("auctions: one row per distinct link, lowest price kept, bid-only marked, cached scores", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 501, itemSuffix = 14315, minPrice = 449 }, { itemID = 601, minPrice = 30000 } })
    local group = store.rows[1]
    M.ApplyInfo(store, group, M.MergeInfo({ name = "Cadet Vest", link = "|Hitem:501|h[Cadet Vest]|h", quality = 2,
        equipLoc = "INVTYPE_CHEST" }, { name = "Cadet Vest of Healing" }, 14315), 0)
    M.ApplyScore(store, group, { upgradePct = 2.5 }, nil, 0)
    M.ApplyInfo(store, store.rows[2], info("Iron Helm", "INVTYPE_HEAD"), 0)
    M.ApplyScore(store, store.rows[2], { upgradePct = 3 }, nil, 0)
    local H1 = "|cnIQ2:|Hitem:501::::::::15:1486:::1:12725::::::|h[Cadet Vest of Healing]|h|r"
    local H2 = "|cnIQ2:|Hitem:501::::::::15:1486:::1:12726::::::|h[Cadet Vest of Healing]|h|r"
    local H3 = "|cnIQ2:|Hitem:501::::::::15:1486:::1:12727::::::|h[Cadet Vest of Healing]|h|r"
    store.scores[H3] = { result = { upgradePct = 7 } } -- judged earlier this session
    local n = M.SetAuctions(store, group, {
        { link = H1, buyout = 900 }, { link = H1, buyout = 449 }, { link = H2, bid = 300, buyout = 0 },
        { link = H3, buyout = 1000, bid = 500 }, { link = nil, buyout = 5 }, { link = H2 },
    })
    eq(n, 3, "three distinct links (no link, no price: left out)")
    local a = group.auctions
    eq(a[1].link .. " " .. a[1].price .. " " .. tostring(a[1].bid) .. " " .. a[1].auctionCount, H1 .. " 449 false 2",
        "identical links: lowest buyout")
    eq(a[2].price .. " " .. tostring(a[2].bid), "300 true", "bid-only (buyout 0): its bid, marked")
    eq(a[3].price .. " " .. tostring(a[3].bid), "1000 false", "buyout preferred over the bid")
    eq(a[1].name .. " " .. a[1].linkSource .. " " .. tostring(a[1].approximate) .. " " .. a[1].equipLoc,
        "Cadet Vest of Healing auction false INVTYPE_CHEST", "auction row info")
    ok(a[1].isAuction and a[1].group == group, "linked to its group")
    eq(a[1].state, "pending", "to be judged")
    eq(a[3].state .. " " .. a[3].upgradePct, "scored 7", "cached score by link")
    eq(#store.leaves, 4, "the group replaced by its three auctions, plus the helm")
    eq(store.pending, 2, "two auction rows pending")
    eq(#M.NextBatch(store, 0, 20), 2, "and due")
    local c = M.Counts(store)
    eq(c.gear .. " " .. c.groups .. " " .. c.groupsDone, "4 1 1", "counts: leaves, groups done")
    eq(M.CountLine(c, true, true), "4 gear items, 2 upgrades, 2 pending", "nothing left resolving")
    eq(M.CountLine({ total = 3, gear = 3, upgrades = 1, pending = 0, groups = 23, groupsDone = 5 }, true, true),
        "3 gear items, 1 upgrade, 0 pending, resolving 5/23", "resolving part")
    eq(M.CountLine({ total = 3, gear = 3, upgrades = 1, pending = 0, groups = 23, groupsDone = 5 }, true, false),
        "3 gear items, 1 upgrade, 0 pending", "not in exact mode")

    -- the same results again (more results added): rows kept
    local first = a[1]
    M.SetAuctions(store, group, { { link = H1, buyout = 449 }, { link = H2, bid = 300 }, { link = H3, buyout = 1000 } })
    ok(group.auctions[1] == first, "row kept")
    -- a rebuild keeps the group's auctions
    M.Rebuild(store, { { itemID = 501, itemSuffix = 14315, minPrice = 449 } })
    eq(#store.leaves, 3, "still listed as auctions")
    local d = M.Dump(store, {})
    eq(d.groups[1].query .. " " .. d.groups[1].auctionRows, "none 3", "group in the dump")
    eq(tostring(d.rows[1].auction) .. " " .. d.rows[1].group, "true 501:14315", "auction row in the dump")
    eq(#M.FindRows(store, "healing"), 4, "debug lookup: the group and its auctions")
end)
test("item identity: link metadata and modifiers ignored, bonus IDs kept", function()
    local a = "|Hitem:9765::::::::10:1486:::1:12729::::::|h[Cadet Vest of Intellect]|h"
    local b = "|cnIQ2:|Hitem:9765::::::::10:1486::1:1:12729:1:28:5256:::::|h[Cadet Vest of Intellect]|h|r"
    eq(M.ItemIdentity(a), "9765:::::::|12729", "identity")
    eq(M.ItemIdentity(b), M.ItemIdentity(a), "context, modifier pair, level, colour: same item")
    ok(M.ItemIdentity("|Hitem:9765::::::::10:1486:::1:12730::::::|h[x]|h") ~= M.ItemIdentity(a), "other bonus ID")
    -- the modifier section (count 2, then 28:5256 and 9:15) is not read as bonus IDs
    eq(M.ItemIdentity("|Hitem:9765::::::::10:1486::1:2:12729:3524:2:28:5256:9:15::::|h[x]|h"), "9765:::::::|3524:12729",
        "two bonus IDs, sorted; modifiers left out")
    eq(M.ItemIdentity("|Hitem:9765::::::::10:1486::1:2:3524:12729:1:28:1::::|h[x]|h"), "9765:::::::|3524:12729",
        "bonus order does not matter")
    ok(M.ItemIdentity("|Hitem:9765:5:::::::10:1486:::1:12729::::::|h[x]|h") ~= M.ItemIdentity(a), "enchant counts")
    eq(M.ItemIdentity("|Hitem:9765:0:::::::10:1486:::1:12729::::::|h[x]|h"), M.ItemIdentity(a), "enchant 0 is none")
    eq(M.ItemIdentity("|Hitem:junk|h[x]|h"), "|Hitem:junk|h[x]|h", "unparsable: the raw link")
    eq(M.ItemIdentity("|Hitem:9765::::::::10:1486:::3:12729|h[x]|h"), "|Hitem:9765::::::::10:1486:::3:12729|h[x]|h",
        "fewer bonus IDs than counted: the raw link")
end)

test("auctions merged by item identity: count kept, cheapest kept, buyout before bid at the same price", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 9765, itemSuffix = 14309, minPrice = 500 } })
    local group = store.rows[1]
    M.ApplyInfo(store, group, M.MergeInfo({ name = "Cadet Vest", link = "|Hitem:9765|h[Cadet Vest]|h",
        equipLoc = "INVTYPE_CHEST" }, { name = "Cadet Vest of Intellect" }, 14309), 0)
    local a = "|Hitem:9765::::::::10:1486:::1:12729::::::|h[Cadet Vest of Intellect]|h"
    local b = "|cnIQ2:|Hitem:9765::::::::10:1486::1:1:12729:1:28:5256:::::|h[Cadet Vest of Intellect]|h|r"
    local c = "|Hitem:9765::::::::10:1486:::1:12731::::::|h[Cadet Vest of Intellect]|h"
    eq(M.SetAuctions(store, group, { { link = a, buyout = 700 }, { link = b, buyout = 500 }, { link = c, bid = 400 },
        { link = c, buyout = 400 } }), 2, "the two links of one item are one row; another bonus ID is another")
    local r1, r2 = group.auctions[1], group.auctions[2]
    eq(r1.auctionCount .. " " .. r1.price .. " " .. r1.link, "2 500 " .. b, "merged: cheapest auction's link and price")
    eq(r2.price .. " " .. tostring(r2.bid), "400 false", "same price: the buyout wins over the bid-only auction")
    eq(M.DumpRow(r1, {}).auctionCount .. " " .. M.DumpRow(r1, {}).identity, "2 9765:::::::|12729", "in the dump")
end)

test("exact view off lists the group rows; rescoring also resets hidden auction rows", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 501, itemSuffix = 14315, minPrice = 449 } })
    local group = store.rows[1]
    M.ApplyInfo(store, group, M.MergeInfo({ name = "Cadet Vest", link = "|Hitem:501|h[Cadet Vest]|h",
        equipLoc = "INVTYPE_CHEST" }, { name = "Cadet Vest of Healing" }, 14315), 0)
    M.ApplyScore(store, group, { upgradePct = 2.5 }, nil, 0)
    local H1 = "|Hitem:501::::::::15:1486:::1:12725::::::|h[Cadet Vest of Healing]|h"
    M.SetAuctions(store, group, { { link = H1, buyout = 449 } })
    M.ApplyScore(store, group.auctions[1], { upgradePct = 15.4 }, nil, 0)
    ok(store.leaves[1] == group.auctions[1], "auction row listed")
    M.SetExactView(store, false)
    ok(store.leaves[1] == group and #store.leaves == 1, "group row listed instead")
    eq(store.pending, 0, "nothing pending")
    M.InvalidateScores(store)
    eq(group.auctions[1].state, "pending", "hidden auction row reset too")
    eq(store.pending, 1, "only the listed group counted pending")
    M.SetExactView(store, true)
    ok(store.leaves[1] == group.auctions[1], "auction row back")
    eq(store.pending, 1, "the auction row pending")
end)

test("scan state: why a row is only its starred base score", function()
    local on = { on = true }
    local function group(state, qs) return { approximate = true, state = state, query = qs and { state = qs } or nil } end
    eq(M.ScanState({ approximate = false, state = "scored" }, on), nil, "fixed-stat item: exact")
    eq(M.ScanState({ isAuction = true, state = "scored" }, on), nil, "auction row: exact")
    eq(M.ScanState(group("unusable"), on), nil, "unusable group: never scanned, not greyed")
    eq(M.ScanState(group("notgear"), on), nil, "not gear")
    eq(M.ScanState(group("scored", "queued"), on), "Waiting to be looked up", "queued")
    eq(M.ScanState(group("pending"), on), "Waiting to be looked up", "not queued yet")
    eq(M.ScanState(group("scored", "sent"), on), "Looking up...", "in flight")
    eq(M.ScanState(group("scored", "failed"), on), "Lookup failed", "failed")
    eq(M.ScanState(group("scored", "timeout"), on), "Lookup failed", "timed out")
    eq(M.ScanState(group("scored", "queued"), { on = true, capReached = true }), "Not looked up (limit reached)", "cap")
    eq(M.ScanState(group("scored", "sent"), { on = true, capReached = true }), "Looking up...", "in flight beats cap")
    eq(M.ScanState(group("scored", "queued"), { on = false }), "Scan specific items is off", "setting off")
    eq(M.ScanState(group("scored"), { on = true, disabled = "SendSearchQuery missing" }), "Lookup not available",
        "search API missing")
    eq(M.ScanState(group("scored", "resolved"), on), nil, "resolved")
end)

test("count line", function()
    local store = scoredStore(SPEC)
    M.Rebuild(store, { { itemID = 1 }, { itemID = 2 }, { itemID = 3 }, { itemID = 4 }, { itemID = 5 }, { itemID = 6 },
        { itemID = 7 }, { itemID = 8 }, { itemID = 9, equipLoc = "" } })
    local c = M.Counts(store)
    eq(c.gear, 7, "gear")
    eq(c.upgrades, 3, "upgrades")
    eq(c.pending, 2, "pending: one to score, one to resolve")
    eq(c.resolving, 1, "resolving")
    eq(c.notgear, 1, "not gear")
    eq(M.CountLine(c, true), "7 gear items, 3 upgrades, 2 pending", "line")
    eq(M.CountLine({ total = 1, gear = 1, upgrades = 1, pending = 0 }), "1 gear item, 1 upgrade, 0 pending", "singular")
    eq(M.CountLine(c, false), "7 gear items, 3 upgrades, 2 pending (more results not loaded)", "partial")
    eq(M.CountLine({ total = 0 }), "No browse results yet: search the auction house.", "empty")
end)

return H
