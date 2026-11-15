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
    -- the raw count (or the error text when entries is nil) and the results left out by the reader
    local entries, rawOrError, skipped = Game.BrowseResults()
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
    M.Rebuild(store, entries, skipped)
    store.lastCount = raw
    store.full = Game.HasFullBrowseResults()
    markDirty()
end

local KEY_WAITS = 2    -- tries a suffixed row waits for item key info (its suffixed name)
local SUFFIX_TRIES = 3 -- tries a suffixed row waits for one of its candidate links to resolve

---The verified link of a random suffix row: the first candidate whose resolved name is the item key's
---suffixed name. Candidates: every link the client gives for the item key (key tooltip, scan tooltip),
---then links built from the first of them (or the item info link) with the suffix as a bonus ID or in
---field 7. Every candidate is resolved and recorded. Returns link, source; or nil when none verified.
local function suffixLink(row, base, keyInfo)
    local list = Game.KeyLinks(row.itemID, row.itemLevel, row.suffix)
    local baseLink = list[1] and list[1].link or base.link
    for _, c in ipairs(M.SuffixCandidates(baseLink, row.suffix, keyInfo.name)) do list[#list + 1] = c end
    row.baseLink, row.candidates = baseLink, list
    local resolved, accepted = {}, nil
    for _, c in ipairs(list) do
        local r = resolved[c.link]
        if not r then
            r = { Game.ResolveLinkName(c.link, base.name) }
            resolved[c.link] = r
        end
        c.name, c.tooltipName = r[1], r[2]
        if not accepted and (c.name == keyInfo.name or c.tooltipName == keyInfo.name) then
            c.accepted = true
            accepted = c
        end
    end
    if accepted then return accepted.link, accepted.source end
    return nil
end

local function work(row, now)
    if not row.info then
        local base = Game.ItemInfo(row.itemString)
        if not base then
            Game.RequestItem(row.itemID)
            M.Defer(store, row, now, "ITEM_INFO")
            return
        end
        -- The real name comes from the item key. GetItemInfo of a suffixed item string gives the base item,
        -- and the key tooltip link is generic for the item id: the suffixed link has to be built and checked.
        local keyInfo = Game.ItemKeyInfo(row.itemID, row.itemLevel, row.suffix)
        local keyLink, source
        if row.suffix == 0 then
            keyLink, source = Game.KeyLink(row.itemID, row.itemLevel, row.suffix)
        elseif M.IsGear(base.equipLoc) then
            if not keyInfo and (row.keyWaits or 0) < KEY_WAITS then
                row.keyWaits = (row.keyWaits or 0) + 1
                M.Defer(store, row, now, "ITEM_KEY_INFO")
                return
            end
            if keyInfo then
                keyLink, source = suffixLink(row, base, keyInfo)
                if not keyLink and (row.suffixTries or 0) < SUFFIX_TRIES then
                    row.suffixTries = (row.suffixTries or 0) + 1
                    M.Defer(store, row, now, "SUFFIX_LINK")
                    return
                end
            else
                keyLink, source = nil, nil -- no suffixed name to check against: judged as the base item
            end
        end
        local info = M.MergeInfo(base, keyInfo, keyLink, source, row.suffix)
        info.baseLink, info.candidates = row.baseLink, row.candidates
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
    pcall(driver.RegisterEvent, driver, "ITEM_KEY_ITEM_INFO_RECEIVED") -- may not exist on this client
    specName = Game.SGJReady() and Game.SpecName() or nil
    if Panel.Ensure() then Panel.SetVisible(ns.db.shown) end
    Panel.ResetScroll()
    nextBatchAt, nextRefreshAt = 0, 0
    scheduleRead()
    markDirty()
end

---Saves what the auction house showed into AuctionJudgeDB.lastDump (plain values only). Built only when
---the auction house closes or the player logs out with it open.
local function writeDump(why)
    if not ns.db then return end
    local d = M.Dump(store, ns.db)
    d.time = Game.DateText()
    d.why = why
    d.sgjLoaded = Game.SGJUsable()
    d.sgjReady = Game.SGJReady()
    d.spec = Game.SpecName()
    d.lastReadError = lastReadError
    -- the first suffixed row's tooltip text, key tooltip vs the judged link, to compare stats by eye
    for _, row in ipairs(store.rows) do
        if row.suffix ~= 0 and row.info and row.state ~= "notgear" then
            d.suffixSample = {
                key = row.key, name = row.name, link = row.link, linkSource = row.linkSource,
                keyTooltipLines = Game.KeyTooltipLines(row.itemID, row.itemLevel, row.suffix, 12),
                linkTooltipLines = Game.LinkTooltipLines(row.link, 12),
            }
            break
        end
    end
    ns.db.lastDump = d
end

function handlers.PLAYER_LOGOUT()
    if open then safe("dump", writeDump, "logout") end
end

function handlers.AUCTION_HOUSE_CLOSED()
    if open then safe("dump", writeDump, "closed") end
    open = false
    sleep()
    driver:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
    pcall(driver.UnregisterEvent, driver, "ITEM_KEY_ITEM_INFO_RECEIVED")
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
handlers.ITEM_KEY_ITEM_INFO_RECEIVED = handlers.GET_ITEM_INFO_RECEIVED

driver:SetScript("OnEvent", function(_, event, ...)
    local fn = handlers[event]
    if fn then safe(event, fn, ...) end
end)
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_LOGOUT")
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
    local sources = M.LinkSourceCounts(store)
    local approx = 0
    for _, row in ipairs(store.rows) do if row.approximate then approx = approx + 1 end end
    local parts = {}
    local names = {}
    for name in pairs(sources) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do parts[#parts + 1] = name .. " " .. sources[name] end
    if #parts == 0 then parts[1] = "none yet" end
    local TI = C_TooltipInfo
    ns.Print(string.format("Links: %s; %d suffixed rows judged as the base item (*); C_TooltipInfo.GetItemKey %s, "
        .. "GetHyperlink %s", table.concat(parts, ", "), approx, yesno(type(TI) == "table" and TI.GetItemKey),
        yesno(type(TI) == "table" and TI.GetHyperlink)))
    local db = ns.db
    ns.Print(string.format("Panel: %s, %s; upgrades only %s, hide unusable %s, sort %s",
        Panel.Exists() and "created" or "not created", db.shown and "on" or "off", yesno(db.upgradesOnly),
        yesno(db.hideUnusable), M.SortLabel(db)))
end

---/aj debug <text>: every row whose name contains text, hidden ones included.
local function debugFind(text)
    local found = M.FindRows(store, text)
    ns.Print(string.format("%d of %d rows match \"%s\":", #found, #store.rows, text))
    for _, row in ipairs(found) do
        local a, b, extra = M.DebugLines(M.DumpRow(row, ns.db))
        ns.Print(a)
        ns.Print(b)
        for _, line in ipairs(extra) do ns.Print(line) end
    end
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
        local text = (msg or ""):match("^%s*%S+%s+(.-)%s*$")
        if text and text ~= "" then debugFind(text) else debug() end
    else
        ns.Print("/aj show | hide | toggle | status | debug [name text]")
    end
end

SLASH_AUCTIONJUDGE1 = "/auctionjudge"
SLASH_AUCTIONJUDGE2 = "/aj"
SlashCmdList.AUCTIONJUDGE = function(msg)
    if not ns.db then initDB() end
    safe("slash", slash, msg)
end
