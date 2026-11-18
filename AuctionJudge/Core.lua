-- Wiring: saved variables, events, the work loop while the auction house is open, slash commands.
-- AuctionJudge reads the current browse results. For random suffix groups (auctions whose stats vary)
-- it sends item searches through the queue (Queue.lua) to read the individual auctions' links. It never
-- sends browse queries, and never buys, bids or posts.
local ADDON, ns = ...

local M, Q, Game, Panel, Hist = ns.Model, ns.Queue, ns.Game, ns.Panel, ns.History

local PREFIX = "|cff33ccffAuctionJudge|r: "
local READ_DELAY = 0.2       -- debounce for browse result events
local REFRESH_INTERVAL = 0.2 -- the list is rebuilt and sorted at most 5 times a second while work goes on
local KEY_WAITS = 2          -- tries a random suffix group waits for its item key info (its suffixed name)
local DEFAULTS = { shown = true, upgradesOnly = true, hideUnusable = true, sortColumn = "value", sortDesc = true,
    exact = true, maxQueries = 60 }

local store = M.NewStore()
ns.store = store
local queue = Q.New()
ns.queue = queue

local open = false
local readAt, nextBatchAt, nextRefreshAt, dirty = nil, 0, 0, false
local instant = {}       -- itemID -> equip location from GetItemInfoInstant (known values only)
local sgjRegistered = false
local lastReadError
local specName
local exactDisabled      -- why item searches are off for this session (missing or failing API)
local lastWhy            -- why the queue did not send at its last turn
local search             -- the current search's summary while it runs (saved to the history when it ends)
local retained           -- the last search with results, after a new one replaced it: its store fields by
                         -- reference (no copy), so the dump can show it if the new search ends with nothing

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
    if type(db.maxQueries) ~= "number" or db.maxQueries < 0 then db.maxQueries = DEFAULTS.maxQueries end
    db.history = Hist.Clean(db.history)
    ns.db = db
    M.SetExactView(store, db.exact)
end

---Item searches for random suffix groups are on: setting on, API working, SGJ there to judge.
local function exactActive()
    return ns.db ~= nil and ns.db.exact == true and not exactDisabled and Game.SGJUsable()
end

---------------------------------------------------------------------------
-- View
---------------------------------------------------------------------------

---The item search state for row greying (ScanState) and the progress line (LookupState).
local function scanState()
    local db = ns.db
    return { on = db.exact == true, active = exactActive(), disabled = exactDisabled,
        capReached = queue.sent >= db.maxQueries, cap = db.maxQueries, sent = queue.sent,
        inflight = queue.inflight ~= nil }
end

local function buildView()
    local usable = Game.SGJUsable()
    local db = ns.db
    return {
        sgj = usable and "ok" or "missing",
        ready = usable and Game.SGJReady(),
        spec = specName,
        counts = M.Counts(store),
        full = store.full,
        exact = exactActive(),
        exactDisabled = exactDisabled,
        scan = scanState(),
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

local function enqueue(row)
    if exactActive() and M.NeedsQuery(row) then
        Q.Enqueue(queue, row)
        wake()
    end
end

local function enqueueAll()
    for _, row in ipairs(store.rows) do enqueue(row) end
end

---------------------------------------------------------------------------
-- Search history: one summary per search, from a fresh browse search (RESULTS_UPDATED), more results
-- without a search seen (RESULTS_ADDED), or results already there on opening; until replaced or closed.
---------------------------------------------------------------------------

---start: "search", "added" (its start was not seen) or "open".
local function newSearch(start)
    search = { start = start, time = Game.DateText(), spec = Game.SpecName(), reads = 0 }
end

---Why the item searches stopped (or never ran) for search s and the current results: unread, read failed,
---complete, disabled, cap, incomplete (looking still), pending (rows not resolved yet), nothing to look up,
---inactive (no SGJ) or off.
local function scanStop(s, c)
    if s.reads == 0 then return s.readError and "read failed" or "unread" end
    local state = M.LookupState(c, scanState())
    if state == "stopped" then return "cap" end
    if state == "looking" then return "incomplete" end
    if state then return state end
    if c.groups == 0 then return store.pending > 0 and "pending" or "nothing to look up" end
    return ns.db.exact == true and "inactive" or "off"
end

---Search s's summary as plain values, from the store and the queue (its counts are per search) as they are now.
local function summarize(s, ended)
    local c = M.Counts(store)
    local e = {
        time = s.time, start = s.start, ended = ended, spec = Game.SpecName() or s.spec, -- as scored last
        reads = s.reads, raw = s.raw, rows = s.rows, full = s.full, readError = s.readError,
        lookups = queue.sent, failures = queue.failures, stop = scanStop(s, c), disabled = exactDisabled,
    }
    -- not read at all is stop "unread"; read, then more results added and not read, is readPending
    if s.reads > 0 then
        e.readPending = readAt ~= nil or nil
        e.queued, e.inflight, e.pending = Q.Length(queue), queue.inflight ~= nil or nil, store.pending
        e.upgrades, e.confirmedUpgrades, e.estimatedUpgrades = c.upgrades, c.confirmedUpgrades, c.estimatedUpgrades
        e.groups, e.groupsDone, e.groupsResolved = c.groups, c.groupsDone, c.groupsResolved
    end
    return e
end

local finished -- the summary of the search ended last this session (the dump's search)

---Ends the current search and saves its summary, once: ended is "replaced", "closed" or "logout". Reads
---the store and the queue, so it runs before they are cleared.
local function finishSearch(ended)
    local s = search
    if not s or not ns.db then return end
    search = nil
    finished = summarize(s, ended)
    Hist.Add(ns.db.history, finished)
end

---Reads a row's required level when it is wanted (Model.LevelWanted): an auction row from its own link, a
---browse row from the item key of the variant it shows (when the client has that), else its item info. Not
---cached item data is left to its GET_ITEM_INFO_RECEIVED; readable data without a level counts as a miss.
---true when a level was set.
local function readLevel(row)
    if not M.LevelWanted(row) then return false end
    if not row.isAuction then
        local level = Game.ItemKeyRequiredLevel(row.itemID, row.itemLevel, row.suffix)
        if level then return M.SetMinLevel(store, row, level, "key", row.itemLevel) end
    end
    local info = Game.ItemInfo(row.isAuction and row.link or row.itemString)
    if not info then return false end
    if M.SetMinLevel(store, row, info.minLevel, row.isAuction and "link" or "item") then return true end
    row.levelMisses = (row.levelMisses or 0) + 1
    return false
end

local function readLevels(list)
    local any = false
    for _, row in ipairs(list) do
        if readLevel(row) then any = true end
    end
    return any
end

local function readResults()
    -- the raw count (or the error text when entries is nil) and the results left out by the reader
    local entries, rawOrError, skipped = Game.BrowseResults()
    if not entries then
        lastReadError = rawOrError
        if search then search.readError = rawOrError end
        return
    end
    local raw = rawOrError
    lastReadError = nil
    -- results there on opening (no search seen) count as a search; an empty list on opening does not
    if not search and raw > 0 then newSearch("open") end
    for _, e in ipairs(entries) do
        local loc = instant[e.itemID]
        if loc == nil then
            loc = Game.InstantEquipLoc(e.itemID) -- nil: unknown, resolved through full item info
            instant[e.itemID] = loc
        end
        e.equipLoc = loc
    end
    M.Rebuild(store, entries, skipped)
    readLevels(store.rows) -- rows from the caches with an unknown level, or a keyed level of another variant
    store.lastCount = raw
    store.full = Game.HasFullBrowseResults()
    if search then
        search.reads, search.raw, search.rows, search.full = search.reads + 1, raw, #store.rows, store.full
        search.readError = nil
    end
    if raw > 0 then retained = nil end -- the dump shows these results now
    enqueueAll() -- groups already judged from the caches
    markDirty()
end

local function work(row, now)
    if not row.info then
        local base = Game.ItemInfo(row.itemString)
        if not base then
            Game.RequestItem(row.itemID)
            M.Defer(store, row, now, "ITEM_INFO")
            return
        end
        -- The group's name comes from the item key (GetItemInfo of a suffixed item string gives the base item).
        local keyInfo = Game.ItemKeyInfo(row.itemID, row.itemLevel, row.suffix)
        if not keyInfo and row.suffix ~= 0 and M.IsGear(base.equipLoc) and (row.keyWaits or 0) < KEY_WAITS then
            row.keyWaits = (row.keyWaits or 0) + 1
            M.Defer(store, row, now, "ITEM_KEY_INFO")
            return
        end
        local keyLevel = Game.ItemKeyRequiredLevel(row.itemID, row.itemLevel, row.suffix)
        M.ApplyInfo(store, row, M.MergeInfo(base, keyInfo, row.suffix, keyLevel, row.itemLevel), now)
        -- not gear, a cached outcome, or an unknown equip location deferred for a retry
        if row.state ~= "pending" or not row.info then
            enqueue(row)
            return
        end
    end
    -- an auction's own link may need another level than its group: read as it is judged (SGJ needs the same
    -- item info, so a link not cached yet is read again with the next try)
    if row.isAuction then readLevel(row) end
    -- auction rows carry their own auction link; browse rows the item info link
    local result, reason = Game.Score(row.link)
    if reason == "NOT_CACHED" then Game.RequestItem(row.itemID) end
    M.ApplyScore(store, row, result, reason, now)
    enqueue(row)
end

local function processBatch(now)
    if not Game.SGJUsable() then return end
    local batch = M.NextBatch(store, now, M.BATCH_SIZE)
    for _, row in ipairs(batch) do work(row, now) end
    if #batch > 0 then markDirty() end
end

---One turn of the item search queue.
local function runQueue(now)
    if not exactActive() then return end
    if Q.CheckTimeout(queue, now) then markDirty() end
    local group, why = Q.Next(queue, now, Game.ThrottleReady(), ns.db.maxQueries)
    lastWhy = why
    if not group then return end
    local ok, err = Game.SendSearch(group.itemKeyRef)
    if ok then
        Q.Sent(queue, group, now)
    else
        Q.SendFailed(queue, group, err)
        if err ~= "no item key" then
            exactDisabled = err
            ns.Print("exact scores for random suffix items are off for this session: " .. err)
        end
    end
    markDirty()
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
    runQueue(now)
    if dirty and now >= nextRefreshAt then
        dirty = false
        nextRefreshAt = now + REFRESH_INTERVAL
        refresh()
    end
    -- idle: nothing to read, to work on, to search for or to draw
    local working = store.pending > 0 and Game.SGJUsable()
    local searching = exactActive() and Q.Waiting(queue, ns.db.maxQueries)
    if not readAt and not dirty and Panel.Exists() and not working and not searching then
        sleep()
    end
end

onUpdate = function() safe("update", tick) end

local function scheduleRead()
    if not readAt then readAt = GetTime() + READ_DELAY end
    wake()
end

---Item search results for a key: only for a group we searched for (in flight, or resolved and getting
---more results). The results are read for our own copy of the key.
local function onItemSearchResults(itemKey)
    local group = queue.inflight
    if not (group and (itemKey == nil or Game.SameKey(group.itemKeyRef, itemKey))) then
        group = nil
        for _, row in ipairs(store.rows) do
            if row.query and row.query.state == "resolved" and Game.SameKey(row.itemKeyRef, itemKey) then
                group = row
                break
            end
        end
    end
    if not group then return end
    local results, total = Game.ItemSearchResults(group.itemKeyRef)
    if not results or #results == 0 then return end -- not there yet: more events follow, or the timeout
    M.SetAuctions(store, group, results)
    readLevels(group.auctions) -- auction rows with a cached score are not judged again
    Q.Resolved(queue, group, total)
    markDirty()
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

---Exact mode ("Scan specific items", /aj exact): off stops the queue at once and lists resolved groups as
---their starred group rows again; on lists their auctions again and queues the groups not resolved yet.
---The searches already sent still count towards this search's cap.
local function setExact(on)
    ns.db.exact = on and true or false
    if ns.db.exact then
        M.SetExactView(store, true)
        enqueueAll()
    else
        Q.Stop(queue)
        M.SetExactView(store, false)
    end
    Panel.ResetScroll()
    markDirty()
    refresh()
end

function ns.SetOption(key, value)
    if key == "exact" then return setExact(value) end
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
    -- the full name as listed, random suffix included; the base name only when there is none
    local group = row.group or row
    local name = row.name or group.name or Game.BaseName(group.itemID)
    if not Game.Search(name) then ns.Print("could not search the auction house for " .. link) end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}
local OPTIONAL_EVENTS = { "ITEM_KEY_ITEM_INFO_RECEIVED", "EXTRA_BROWSE_INFO_RECEIVED", "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED",
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" }

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
    for _, e in ipairs(OPTIONAL_EVENTS) do pcall(driver.RegisterEvent, driver, e) end -- may not exist here
    specName = Game.SGJReady() and Game.SpecName() or nil
    if Panel.Ensure() then Panel.SetVisible(ns.db.shown) end
    Panel.ResetScroll()
    nextBatchAt, nextRefreshAt = 0, 0
    scheduleRead()
    markDirty()
end

local function exactState()
    local api = Game.SearchAPI()
    local found = {}
    for _, name in ipairs(Game.SEARCH_FUNCTIONS) do found[#found + 1] = name .. (api[name] and " ok" or " MISSING") end
    return {
        setting = ns.db.exact == true, active = exactActive(), disabled = exactDisabled, maxQueries = ns.db.maxQueries,
        api = table.concat(found, ", "), sort = api.sort or "none", queued = Q.Length(queue), sent = queue.sent,
        failures = queue.failures, inflight = queue.inflight and queue.inflight.key or nil, waiting = lastWhy,
    }
end

---A table's fields, the plain ones only when plain (a copy, not deep).
local function copy(t, plain)
    if not t then return nil end
    local out = {}
    for k, v in pairs(t) do if not (plain and type(v) == "table") then out[k] = v end end
    return out
end

---What a dump records beside the rows, as it is now: time, why, SGJ, settings, read error, queue, search.
local function dumpContext(why)
    return { time = Game.DateText(), why = why, sgjLoaded = Game.SGJUsable(), sgjReady = Game.SGJReady(),
        spec = Game.SpecName(), lastReadError = lastReadError, exact = exactState(), opts = copy(ns.db, true),
        search = copy(finished) }
end

---Saves what the auction house showed into AuctionJudgeDB.lastDump (plain values only). Built only when
---the auction house closes or the player logs out with it open: from the results shown, or when there
---are none (an empty visit, a search not read yet) from the search they replaced, as it was then. With
---neither, the last dump stays.
local function writeDump(why)
    if not ns.db then return end
    local src, ctx = store, nil
    if store.lastCount == 0 and retained then
        src, ctx = retained.store, retained.ctx
    elseif store.lastCount == 0 and ns.db.lastDump ~= nil then
        return
    else
        ctx = dumpContext(why)
        if store.lastCount == 0 then ctx.search = nil end -- nothing read: the last search is not this one
    end
    local d = M.Dump(src, ctx.opts)
    for k, v in pairs(ctx) do if k ~= "opts" then d[k] = v end end
    d.writeReason = why ~= ctx.why and why or nil
    -- the first random suffix group's tooltip text next to its first auction's, to compare stats by eye
    for _, row in ipairs(src.rows) do
        if row.suffix ~= 0 and row.info and row.state ~= "notgear" then
            local first = row.auctions and row.auctions[1]
            d.suffixSample = {
                key = row.key, name = row.name, auctionLink = first and first.link or nil,
                keyTooltipLines = Game.KeyTooltipLines(row.itemID, row.itemLevel, row.suffix, 12),
                linkTooltipLines = first and Game.LinkTooltipLines(first.link, 12) or nil,
            }
            break
        end
    end
    ns.db.lastDump = d
end

-- Logging out (or a reload) with the auction house open ends the search; closing after that finds it
-- ended and records nothing more.
function handlers.PLAYER_LOGOUT()
    if open then
        safe("history", finishSearch, "logout")
        safe("dump", writeDump, "logout")
    end
end

function handlers.AUCTION_HOUSE_CLOSED()
    if open then
        safe("history", finishSearch, "closed")
        safe("dump", writeDump, "closed")
    end
    search, retained = nil, nil
    open = false
    sleep()
    driver:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
    for _, e in ipairs(OPTIONAL_EVENTS) do pcall(driver.UnregisterEvent, driver, e) end
    readAt, dirty = nil, false
    Q.Cancel(queue)
    M.Clear(store)
    Panel.SetVisible(false)
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
    if not open then return end
    -- a new search replaced the results: the old rows go now (their auctions, browse prices and item searches
    -- are stale; a late item search reply finds no group). The list stays empty until the new results are
    -- read; groups judged before are scored from the session caches and looked up afresh.
    -- Keep the last useful results until the replacement search supplies its own.
    safe("history", finishSearch, "replaced")
    if store.lastCount > 0 then
        local ok, ctx = pcall(dumpContext, "replaced")
        if ok then retained = { store = copy(store), ctx = ctx } else report("history", ctx) end
    end
    Q.Cancel(queue, true)
    M.Clear(store)
    newSearch("search")
    Q.Hold(queue, GetTime())
    Panel.ResetScroll()
    scheduleRead()
    markDirty()
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_ADDED()
    if not open then return end
    if not search then newSearch("added") end -- results without a search seen: one that started unseen
    Q.Hold(queue, GetTime())
    scheduleRead()
end

function handlers.GET_ITEM_INFO_RECEIVED(itemID)
    if not open then return end
    if M.InfoArrived(store, itemID) then wake() end
    -- delayed required levels, scored rows included
    if readLevels(M.ItemRows(store, itemID)) then markDirty() end
end
handlers.ITEM_KEY_ITEM_INFO_RECEIVED = handlers.GET_ITEM_INFO_RECEIVED

-- The auction house can supply a key's level after the base item has already been scored.
function handlers.EXTRA_BROWSE_INFO_RECEIVED(itemID)
    if not open then return end
    for _, row in ipairs(store.byItem[itemID] or {}) do
        if row.info and row.state ~= "notgear" then
            local level = Game.ItemKeyRequiredLevel(row.itemID, row.itemLevel, row.suffix)
            if level ~= nil and (row.minLevelSource ~= "key" or row.minLevel ~= level) then
                M.SetMinLevel(store, row, level, "key", row.itemLevel)
                markDirty()
            end
        end
    end
end

function handlers.ITEM_SEARCH_RESULTS_UPDATED(itemKey)
    if open then onItemSearchResults(itemKey) end
end
handlers.ITEM_SEARCH_RESULTS_ADDED = handlers.ITEM_SEARCH_RESULTS_UPDATED

function handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
    wake()
end

---SGJ's SCORES_CHANGED follows a level-up too (and redraws); this redraws the "Requires" labels at once with
---the new level, which UnitLevel may not give yet.
function handlers.PLAYER_LEVEL_UP(level)
    Game.NoteLevelUp(level)
    if open then markDirty() end
end

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
driver:RegisterEvent("PLAYER_LEVEL_UP")

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
    ns.Print(string.format("Rows: %d listed from %d browse rows (gear %d, upgrades %d: confirmed %d, estimated %d; "
        .. "scored %d, pending %d of which resolving %d, unusable %d, error %d, not gear %d); %d scores cached",
        #store.leaves, c.total, c.gear, c.upgrades, c.confirmedUpgrades, c.estimatedUpgrades, c.scored, c.pending,
        c.resolving, c.unusable, c.error, c.notgear, cached))
    local x = exactState()
    ns.Print(string.format("Exact scores: %s%s; random suffix groups %d, done %d (checked %d); lookups %s; queue %d "
        .. "queued, %d sent this search (max %d), %d failed%s%s", x.active and "on" or (x.setting and "on but inactive" or "off"),
        x.disabled and (" (disabled: " .. x.disabled .. ")") or "", c.groups, c.groupsDone, c.groupsResolved,
        M.LookupState(c, scanState()) or "-", x.queued, x.sent, x.maxQueries, x.failures,
        x.inflight and ("; in flight " .. x.inflight) or "", x.waiting and ("; waiting: " .. x.waiting) or ""))
    ns.Print("Item search API: " .. x.api .. "; sort " .. x.sort)
    local db = ns.db
    ns.Print(string.format("Panel: %s, %s; upgrades only %s, hide unusable %s, sort %s",
        Panel.Exists() and "created" or "not created", db.shown and "on" or "off", yesno(db.upgradesOnly),
        yesno(db.hideUnusable), M.SortLabel(db)))
end

---/aj debug <text>: every row whose name contains text, hidden ones and replaced groups included.
local function debugFind(text)
    local found = M.FindRows(store, text)
    ns.Print(string.format("Rows matching \"%s\": %d", text, #found))
    for _, row in ipairs(found) do
        local a, b = M.DebugLines(M.DumpRow(row, ns.db))
        ns.Print(a)
        ns.Print(b)
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

---/aj history: the recorded searches, newest first, and the one running now.
local function history()
    local list = ns.db.history
    ns.Print(string.format("Searches: %d recorded (the latest %d are kept), newest first", #list, Hist.MAX))
    if search then ns.Print("now: " .. Hist.Line(summarize(search, nil))) end
    for i = #list, 1, -1 do ns.Print(Hist.Line(list[i])) end
end

local function slash(msg)
    local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
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
        if arg ~= "" then debugFind(arg) else debug() end
    elseif cmd == "exact" and (arg == "on" or arg == "off") then
        setExact(arg == "on")
        ns.Print("exact scores for random suffix items " .. arg .. (exactDisabled and (" (disabled this session: "
            .. exactDisabled .. ")") or ""))
    elseif cmd == "history" then
        history()
    elseif cmd == "maxqueries" and tonumber(arg) then
        ns.db.maxQueries = math.max(0, math.floor(tonumber(arg)))
        ns.Print("at most " .. ns.db.maxQueries .. " item searches per auction house search")
        markDirty() -- the lookup progress and the greyed rows follow the new cap at once
    else
        ns.Print("/aj show | hide | toggle | status | debug [name text] | exact on|off | maxqueries <n> | history")
    end
end

SLASH_AUCTIONJUDGE1 = "/auctionjudge"
SLASH_AUCTIONJUDGE2 = "/aj"
SlashCmdList.AUCTIONJUDGE = function(msg)
    if not ns.db then initDB() end
    safe("slash", slash, msg)
end
