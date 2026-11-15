-- Wiring: saved variables, events, the work loop while the auction house is open, slash commands.
-- AuctionJudge only reads what the current auction house search returned; it sends no queries.
local ADDON, ns = ...

local M, Game, Panel = ns.Model, ns.Game, ns.Panel

local PREFIX = "|cff33ccffAuctionJudge|r: "
local READ_DELAY = 0.2       -- debounce for browse result events
local REFRESH_INTERVAL = 0.2 -- the list is rebuilt and sorted at most 5 times a second while work goes on
local DEFAULTS = { shown = true, upgradesOnly = true, hideUnusable = true, sortColumn = "value", sortDesc = true }

local store = M.NewStore()
ns.store = store

local open = false
local readAt, nextBatchAt, nextRefreshAt, dirty = nil, 0, 0, false
local instant = {}       -- itemID -> equip location from GetItemInfoInstant (known values only)
local sgjRegistered = false
local lastReadError
local specName

function ns.Print(msg) print(PREFIX .. msg) end

local errorsShown = {}
local function report(where, err)
    local line = where .. ": " .. tostring(err)
    if errorsShown[line] then return end
    errorsShown[line] = true
    ns.Print("|cffff5555error|r in " .. line)
end

local function safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then report(where, err) end
    return ok
end

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------

local function initDB()
    if type(AuctionJudgeDB) ~= "table" then AuctionJudgeDB = {} end
    local db = AuctionJudgeDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    local known = false
    for _, col in ipairs(M.COLUMNS) do if db.sortColumn == col then known = true end end
    if not known then db.sortColumn, db.sortDesc = DEFAULTS.sortColumn, DEFAULTS.sortDesc end
    ns.db = db
end

---------------------------------------------------------------------------
-- View
---------------------------------------------------------------------------

local function buildView()
    local usable = Game.SGJUsable()
    local db = ns.db
    return {
        sgj = usable and "ok" or "missing",
        ready = usable and Game.SGJReady(),
        spec = specName,
        counts = M.Counts(store),
        full = store.full,
        list = usable and M.View(store, db) or {},
        opts = db,
    }
end
ns.BuildView = buildView

local function refresh()
    if not Panel.Exists() then return end
    if not specName and Game.SGJReady() then specName = Game.SpecName() end
    Panel.Refresh(buildView())
end

---------------------------------------------------------------------------
-- Work loop: OnUpdate only while the auction house is open and there is something to do
---------------------------------------------------------------------------

local driver = CreateFrame("Frame")
local running = false
local onUpdate

local function wake()
    if open and not running then
        running = true
        driver:SetScript("OnUpdate", onUpdate)
    end
end

local function sleep()
    if running then
        running = false
        driver:SetScript("OnUpdate", nil)
    end
end

local function markDirty()
    dirty = true
    wake()
end

local function readResults()
    local entries, rawOrError = Game.BrowseResults() -- the raw count, or the error text when entries is nil
    if not entries then
        lastReadError = rawOrError
        return
    end
    local raw = rawOrError
    lastReadError = nil
    for _, e in ipairs(entries) do
        local loc = instant[e.itemID]
        if loc == nil then
            loc = Game.InstantEquipLoc(e.itemID) -- nil: unknown, resolved through full item info
            instant[e.itemID] = loc
        end
        e.equipLoc = loc
    end
    M.Rebuild(store, entries)
    store.lastCount = raw
    store.full = Game.HasFullBrowseResults()
    markDirty()
end

local function work(row, now)
    if not row.info then
        local info = Game.ItemInfo(row.itemString)
        if not info then
            Game.RequestItem(row.itemID)
            M.Defer(store, row, now, "ITEM_INFO")
            return
        end
        M.ApplyInfo(store, row, info, now)
        -- not gear, a cached outcome, or an unknown equip location deferred for a retry
        if row.state ~= "pending" or not row.info then return end
    end
    local result, reason = Game.Score(row.link)
    M.ApplyScore(store, row, result, reason, now)
end

local function processBatch(now)
    if not Game.SGJUsable() then return end
    local batch = M.NextBatch(store, now, M.BATCH_SIZE)
    for _, row in ipairs(batch) do work(row, now) end
    if #batch > 0 then markDirty() end
end

local function tick()
    local now = GetTime()
    if not Panel.Exists() and Panel.Ensure() then
        Panel.SetVisible(ns.db.shown)
        markDirty()
    end
    if readAt and now >= readAt then
        readAt = nil
        readResults()
    end
    if now >= nextBatchAt then
        nextBatchAt = now + M.BATCH_INTERVAL
        processBatch(now)
    end
    if dirty and now >= nextRefreshAt then
        dirty = false
        nextRefreshAt = now + REFRESH_INTERVAL
        refresh()
    end
    -- idle: nothing to read, to work on or to draw
    if not readAt and not dirty and Panel.Exists() and (store.pending <= 0 or not Game.SGJUsable()) then
        sleep()
    end
end

onUpdate = function() safe("update", tick) end

local function scheduleRead()
    if not readAt then readAt = GetTime() + READ_DELAY end
    wake()
end

---------------------------------------------------------------------------
-- Sharpie's Gear Judge
---------------------------------------------------------------------------

local function onScoresChanged()
    M.InvalidateScores(store)
    specName = Game.SGJReady() and Game.SpecName() or nil
    markDirty()
end

local function registerSGJ()
    if sgjRegistered then return end
    sgjRegistered = Game.OnScoresChanged(function() safe("SCORES_CHANGED", onScoresChanged) end)
end

---------------------------------------------------------------------------
-- Actions from the panel
---------------------------------------------------------------------------

function ns.SetShown(show)
    ns.db.shown = show and true or false
    if open then
        Panel.SetVisible(ns.db.shown)
        markDirty()
    end
end

function ns.SortBy(col)
    M.ToggleSort(ns.db, col)
    Panel.ResetScroll()
    refresh()
end

function ns.SetOption(key, value)
    ns.db[key] = value and true or false
    Panel.ResetScroll()
    refresh()
end

function ns.RowClicked(row)
    local link = row.link or row.itemString
    if Game.ShiftDown() then
        if not Game.InsertLink(link) then ns.Print(link) end
        return
    end
    local name = Game.BaseName(row.itemID) or row.name
    if not Game.Search(name) then ns.Print("could not search the auction house for " .. link) end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= ADDON then return end
    initDB()
    registerSGJ()
end

function handlers.PLAYER_LOGIN()
    registerSGJ()
end

function handlers.AUCTION_HOUSE_SHOW()
    if not ns.db then initDB() end
    open = true
    registerSGJ()
    driver:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    specName = Game.SGJReady() and Game.SpecName() or nil
    if Panel.Ensure() then Panel.SetVisible(ns.db.shown) end
    Panel.ResetScroll()
    nextBatchAt, nextRefreshAt = 0, 0
    scheduleRead()
    markDirty()
end

function handlers.AUCTION_HOUSE_CLOSED()
    open = false
    sleep()
    driver:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
    readAt, dirty = nil, false
    M.Clear(store)
    Panel.SetVisible(false)
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
    if not open then return end
    Panel.ResetScroll()
    scheduleRead()
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_ADDED()
    if not open then return end
    scheduleRead()
end

function handlers.GET_ITEM_INFO_RECEIVED(itemID)
    if open and M.InfoArrived(store, itemID) then wake() end
end

driver:SetScript("OnEvent", function(_, event, ...)
    local fn = handlers[event]
    if fn then safe(event, fn, ...) end
end)
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("AUCTION_HOUSE_SHOW")
driver:RegisterEvent("AUCTION_HOUSE_CLOSED")
driver:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
driver:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function yesno(v) return v and "yes" or "no" end

local function status()
    local api = Game.SGJ()
    if api then
        ns.Print(string.format("Sharpie's Gear Judge: loaded, ready %s, version %s, spec %s", yesno(Game.SGJReady()),
            tostring(Game.SGJVersion()), tostring(Game.SpecName())))
        local found = {}
        for _, name in ipairs(Game.SGJ_FUNCTIONS) do
            found[#found + 1] = name .. (type(api[name]) == "function" and " ok" or " MISSING")
        end
        ns.Print("SGJ API: " .. table.concat(found, ", ") .. "; SCORES_CHANGED registered " .. yesno(sgjRegistered))
    else
        ns.Print("Sharpie's Gear Judge: not loaded (SharpiesGearJudgeAPI missing); nothing can be judged")
    end
    local AH = C_AuctionHouse
    local item = C_Item
    local ah = Game.AuctionFrame()
    ns.Print(string.format("Client: GetBrowseResults %s, HasFullBrowseResults %s, GetItemKeyInfo %s, "
        .. "C_Item.GetItemInfo %s, GetItemInfoInstant %s, RequestLoadItemDataByID %s, AuctionHouseFrame %s, "
        .. "search bar %s",
        yesno(type(AH) == "table" and AH.GetBrowseResults), yesno(type(AH) == "table" and AH.HasFullBrowseResults),
        yesno(type(AH) == "table" and AH.GetItemKeyInfo), yesno(type(item) == "table" and item.GetItemInfo),
        yesno(type(item) == "table" and item.GetItemInfoInstant),
        yesno(type(item) == "table" and item.RequestLoadItemDataByID), yesno(ah),
        yesno(ah and type(ah.SearchBar) == "table" and ah.SearchBar.SearchBox and ah.SearchBar.StartSearch)))
    local full = store.full
    ns.Print(string.format("Auction house: %s; last browse results %d (all loaded: %s)%s", open and "open" or "closed",
        store.lastCount, full == nil and "unknown" or yesno(full),
        lastReadError and ("; last read error: " .. lastReadError) or ""))
    local c = M.Counts(store)
    local cached = 0
    for _ in pairs(store.scores) do cached = cached + 1 end
    ns.Print(string.format("Rows: %d (gear %d, upgrades %d; scored %d, pending %d of which resolving %d, unusable %d, "
        .. "error %d, not gear %d); %d scores cached", c.total, c.gear, c.upgrades, c.scored, c.pending, c.resolving,
        c.unusable, c.error, c.notgear, cached))
    local db = ns.db
    ns.Print(string.format("Panel: %s, %s; upgrades only %s, hide unusable %s, sort %s",
        Panel.Exists() and "created" or "not created", db.shown and "on" or "off", yesno(db.upgradesOnly),
        yesno(db.hideUnusable), M.SortLabel(db)))
end

local function debug()
    local n = #store.rows
    ns.Print(string.format("%d rows (first 15, browse order):", n))
    for i = 1, math.min(15, n) do
        local r = store.rows[i]
        ns.Print(string.format("%d. %s %s %s%s price %s upgrade %s value %s", i, r.key, r.link or r.itemString,
            r.state, r.reason and (" (" .. r.reason .. ")") or "", tostring(r.price), tostring(r.upgradePct),
            tostring(r.value)))
    end
end

local function slash(msg)
    local cmd = (msg or ""):match("^%s*(%S*)"):lower()
    if cmd == "show" then
        ns.SetShown(true)
        if not open then ns.Print("the panel will show at the auction house") end
    elseif cmd == "hide" then
        ns.SetShown(false)
    elseif cmd == "toggle" then
        ns.SetShown(not ns.db.shown)
    elseif cmd == "status" then
        status()
    elseif cmd == "debug" then
        debug()
    else
        ns.Print("/aj show | hide | toggle | status | debug")
    end
end

SLASH_AUCTIONJUDGE1 = "/auctionjudge"
SLASH_AUCTIONJUDGE2 = "/aj"
SlashCmdList.AUCTIONJUDGE = function(msg)
    if not ns.db then initDB() end
    safe("slash", slash, msg)
end
