-- Required levels (Model.lua): a row above the player's level keeps its place in the list and gets a
-- "Requires 15" label; an auction row's own link may need another level than its group.
local H = ...
local test, eq, ok = H.test, H.eq, H.ok

local ns = {}
H.load("Model.lua", ns)
local M = ns.Model

local function info(name, minLevel, extra)
    local t = { name = name, link = "|cff1eff00|Hitem:" .. name .. "|h[" .. name .. "]|h|r", quality = 2,
        equipLoc = "INVTYPE_CHEST", minLevel = minLevel }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

test("level label: only above the player's level, only when both are known, '?' when a guess", function()
    local own = { minLevel = 15, minLevelSource = "item" }
    eq(M.LevelText(own, 12), "Requires 15", "above")
    eq(M.LevelText({ minLevel = 12, minLevelSource = "item" }, 12), nil, "at the player's level")
    eq(M.LevelText({ minLevel = 5, minLevelSource = "item" }, 12), nil, "below")
    eq(M.LevelText({}, 12), nil, "item level requirement unknown")
    eq(M.LevelText(own, nil), nil, "player level unknown")
    eq(M.LevelText({ minLevel = 15, minLevelSource = "item", approximate = true }, 12), "Requires 15?",
        "random suffix group: its base item's level")
    eq(M.LevelText({ minLevel = 15, minLevelSource = "key", approximate = true }, 12), "Requires 15",
        "random suffix group: the auction house's own level for its item key")
    eq(M.LevelText({ minLevel = 15, minLevelSource = "link", isAuction = true }, 12), "Requires 15",
        "auction row on its own link's level")
end)

test("level: above the player's level stays listed with Hide unusable; name, sort and link untouched", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 1, minPrice = 10000 }, { itemID = 2, minPrice = 10000 },
        { itemID = 3, minPrice = 10000 } })
    M.ApplyInfo(store, store.rows[1], info("Zealot Helm", 15), 0)
    M.ApplyInfo(store, store.rows[2], info("Apprentice Helm", 5), 0)
    M.ApplyInfo(store, store.rows[3], info("Mystery Helm", nil), 0)
    for i, pct in ipairs({ 4, 2, 1 }) do M.ApplyScore(store, store.rows[i], { upgradePct = pct }, nil, 0) end
    local opts = { upgradesOnly = true, hideUnusable = true, sortColumn = "name", sortDesc = false }
    local names = {}
    for i, row in ipairs(M.View(store, opts)) do names[i] = row.name end
    eq(table.concat(names, ","), "Apprentice Helm,Mystery Helm,Zealot Helm", "all listed, sorted by the plain name")
    local zealot = store.rows[1]
    eq(zealot.state, "scored", "not unusable")
    eq(zealot.link, "|cff1eff00|Hitem:Zealot Helm|h[Zealot Helm]|h|r", "link kept")
    eq(zealot.minLevel .. " " .. zealot.minLevelSource, "15 item", "level from the item info")
    eq(store.rows[3].minLevel, nil, "unknown level stays unknown")
    eq(store.rows[3].minLevelSource, nil, "and has no source")
    eq(#M.FindRows(store, "requires"), 0, "the label is not part of the searchable name")
    local d = M.DumpRow(zealot, opts)
    eq(d.minLevel .. " " .. d.minLevelSource .. " " .. tostring(d.shown), "15 item true", "level in the dump")
    -- the level survives a rescore and comes back from the item info cache in a later search
    M.InvalidateScores(store)
    eq(zealot.minLevel, 15, "kept through SCORES_CHANGED")
    M.Clear(store)
    M.Rebuild(store, { { itemID = 1, minPrice = 9000 } })
    eq(store.rows[1].minLevel, 15, "from the item info cache")
end)

test("level: MergeInfo prefers the item key's level, read for the variant shown, over the base item's", function()
    local base = { name = "Cadet Vest", link = "|Hitem:501|h[Cadet Vest]|h", quality = 2, equipLoc = "INVTYPE_CHEST",
        minLevel = 10 }
    local g = M.MergeInfo(base, { name = "Cadet Vest of Healing" }, 14315)
    eq(g.minLevel .. " " .. g.minLevelSource .. " " .. tostring(g.minLevelItemLevel), "10 item nil", "base level")
    local k = M.MergeInfo(base, nil, 14315, 12, 23)
    eq(k.minLevel .. " " .. k.minLevelSource .. " " .. k.minLevelItemLevel, "12 key 23", "keyed level")
    base.minLevel = nil
    eq(M.MergeInfo(base, nil, 0).minLevel, nil, "unknown stays unknown")
end)

test("level: an unknown level is wanted again, a keyed level of another variant too; misses are capped", function()
    local store = M.NewStore()
    M.Rebuild(store, { { itemID = 1, minPrice = 900, itemLevel = 20 }, { itemID = 2, minPrice = 900, itemLevel = 20 } })
    local a, b = store.rows[1], store.rows[2]
    M.ApplyInfo(store, a, info("Delayed Helm", nil), 0)
    M.ApplyScore(store, a, { upgradePct = 3 }, nil, 0)
    M.ApplyInfo(store, b, M.MergeInfo(info("Keyed Helm", 10), nil, 0, 14, 20), 0)
    ok(M.LevelWanted(a), "scored row with an unknown level")
    ok(not M.LevelWanted(b), "keyed level for the variant shown")
    eq(#M.ItemRows(store, 1), 1, "rows of an item")
    ok(M.SetMinLevel(store, a, 15, "item"), "delayed level arrives")
    eq(a.minLevel .. " " .. a.state .. " " .. store.info[a.itemString].minLevel, "15 scored 15",
        "set and cached, the score kept")
    -- a cheaper variant at another item level takes the row: its key level is read again
    M.Rebuild(store, { { itemID = 1, minPrice = 900, itemLevel = 20 }, { itemID = 2, minPrice = 500, itemLevel = 25 } })
    ok(M.LevelWanted(b), "keyed level read for item level 20, the row shows 25 now")
    M.SetMinLevel(store, b, 16, "key", 25)
    ok(not M.LevelWanted(b), "read for the variant shown")
    eq(b.minLevel, 16, "the shown variant's level")
    -- a level that stays unreadable is not read forever
    local c = { info = true, state = "scored", levelMisses = M.MAX_LEVEL_MISSES }
    ok(not M.LevelWanted(c), "capped")
    ok(not M.LevelWanted({ info = true, state = "notgear" }), "not gear: never")
end)

test("level: auction rows are unknown until their own link is read, then keep it across searches", function()
    local store = M.NewStore()
    local function group()
        M.Rebuild(store, { { itemID = 501, itemSuffix = 14315, minPrice = 449 } })
        local g = store.rows[1]
        M.ApplyInfo(store, g, M.MergeInfo({ name = "Cadet Vest", link = "|Hitem:501|h[Cadet Vest]|h", quality = 2,
            equipLoc = "INVTYPE_CHEST", minLevel = 10 }, { name = "Cadet Vest of Healing" }, 14315), 0)
        M.ApplyScore(store, g, { upgradePct = 2.5 }, nil, 0)
        return g
    end
    local g = group()
    eq(M.LevelText(g, 8), "Requires 10?", "the group's base item level is a guess")
    local L1 = "|cnIQ2:|Hitem:501::::::::15:1486:::1:12725::::::|h[Cadet Vest of Healing]|h|r"
    local L2 = "|cnIQ2:|Hitem:501::::::::15:1486:::1:12726::::::|h[Cadet Vest of Healing]|h|r"
    local L3 = "|cnIQ2:|Hitem:501::::::::15:1486:::1:12727::::::|h[Cadet Vest of Healing]|h|r"
    M.SetAuctions(store, g, { { link = L1, buyout = 449 }, { link = L2, buyout = 900 } })
    local a1, a2 = g.auctions[1], g.auctions[2]
    eq(a1.minLevel, nil, "not the group's level")
    eq(tostring(M.LevelText(a1, 8)), "nil", "no label while unknown")
    ok(M.LevelWanted(a1), "to be read")
    eq(#M.ItemRows(store, 501), 3, "the group and its auctions")
    ok(M.SetMinLevel(store, a1, 15, "link"), "link level taken")
    ok(M.SetMinLevel(store, a2, 8, "link"), "a link may need less than its group")
    eq(M.LevelText(a1, 12) .. " " .. tostring(M.LevelText(a2, 8)), "Requires 15 nil", "each by its own link")
    eq(M.DumpRow(a1, {}).minLevel .. " " .. M.DumpRow(a1, {}).minLevelSource, "15 link", "in the dump")
    -- a new search lists the same auctions again: known link levels from the cache, an unread link unknown
    M.Clear(store)
    g = group()
    M.SetAuctions(store, g, { { link = L1, buyout = 449 }, { link = L2, buyout = 900 }, { link = L3, buyout = 950 } })
    eq(g.auctions[1].minLevel .. " " .. g.auctions[2].minLevel, "15 8", "link levels reused")
    eq(g.auctions[3].minLevel, nil, "unread link: unknown, not the group's")
end)

return H
