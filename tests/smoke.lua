-- Loads the whole addon into a fake client and plays sessions: login, the auction house opening (its
-- frame created on first open), browse results arriving and growing, items resolving in two steps,
-- scores filling in under the batch limit, sorting, filters, scrolling, tooltips and clicks,
-- SCORES_CHANGED rescoring, slash commands, closing and reopening; and a session without Sharpie's
-- Gear Judge. Widgets accept only the methods listed for their type, so a mistyped method fails.
-- Fails on Lua errors, reads of undefined globals and stray global writes.
local H = ...
local test, eq, ok = H.test, H.eq, H.ok

---------------------------------------------------------------------------
-- Fake client
---------------------------------------------------------------------------

local FRAME = {
    "SetPoint", "ClearAllPoints", "SetWidth", "SetHeight", "SetSize", "SetFrameStrata", "GetFrameStrata",
    "SetFrameLevel", "GetFrameLevel", "Show", "Hide", "IsShown", "IsVisible", "SetShown", "SetScript", "GetScript",
    "EnableMouse", "EnableMouseWheel", "CreateTexture", "CreateFontString", "RegisterEvent", "UnregisterEvent",
    "GetParent", "SetAllPoints", "GetName",
}
local BUTTON = { "RegisterForClicks", "SetText", "GetText", "Click", "Enable", "Disable", "SetHighlightTexture" }
local CHECK = { "SetChecked", "GetChecked" }
local BACKDROP = { "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor" }
local METHODS = {
    Texture = { "SetPoint", "SetAllPoints", "SetSize", "SetWidth", "SetHeight", "SetTexture", "SetColorTexture",
        "SetTexCoord", "SetBlendMode", "Show", "Hide", "SetShown", "SetAlpha", "SetDesaturated" },
    FontString = { "SetPoint", "SetAllPoints", "SetWidth", "SetHeight", "SetText", "GetText", "SetTextColor",
        "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetFontObject", "Show", "Hide", "SetShown" },
    GameTooltip = { "SetOwner", "SetHyperlink", "Show", "Hide", "AddLine", "ClearLines", "IsShown" },
}

local function concat(...)
    local out = {}
    for _, list in ipairs({ ... }) do for _, m in ipairs(list) do out[#out + 1] = m end end
    return out
end

local function Client(opts)
    opts = opts or {}
    local C = { clock = 1000, timers = {}, printed = {}, widgets = {}, missing = {}, written = {}, calls = {} }
    local G = {}
    for k, v in pairs(_G) do G[k] = v end
    G._G = G
    C.G = G

    local function count(name) C.calls[name] = (C.calls[name] or 0) + 1 end

    local function widget(kind, parent, template)
        local list
        if kind == "Frame" then list = FRAME
        elseif kind == "Button" then list = concat(FRAME, BUTTON)
        elseif kind == "CheckButton" then list = concat(FRAME, BUTTON, CHECK)
        else list = METHODS[kind] end
        if template == "BackdropTemplate" then list = concat(list, BACKDROP) end
        assert(list, "unknown widget type " .. tostring(kind))
        local w = { kind = kind, parent = parent, template = template, shown = true, scripts = {}, events = {},
            children = {}, points = {} }
        if parent then parent.children[#parent.children + 1] = w end
        local allowed = {}
        for _, m in ipairs(list) do allowed[m] = true end
        local impl = {
            CreateTexture = function(self) return widget("Texture", self) end,
            CreateFontString = function(self) return widget("FontString", self) end,
            SetScript = function(self, name, fn) self.scripts[name] = fn end,
            GetScript = function(self, name) return self.scripts[name] end,
            Show = function(self) self.shown = true end,
            Hide = function(self) self.shown = false end,
            SetShown = function(self, v) self.shown = v and true or false end,
            IsShown = function(self) return self.shown end,
            IsVisible = function(self)
                local f = self
                while f do
                    if not f.shown then return false end
                    f = f.parent
                end
                return true
            end,
            GetParent = function(self) return self.parent end,
            GetFrameStrata = function() return "HIGH" end,
            SetFrameStrata = function(self, s) self.strata = s end,
            SetPoint = function(self, point, rel, relPoint, x, y)
                self.points[#self.points + 1] = { point, rel, relPoint, x, y }
            end,
            SetWidth = function(self, v) self.width = v end,
            SetText = function(self, t) self.text = t end,
            GetText = function(self) return self.text end,
            SetTextColor = function(self, r, g, b) self.color = { r, g, b } end,
            SetChecked = function(self, v) self.checked = v and true or false end,
            GetChecked = function(self) return self.checked == true end,
            SetTexture = function(self, t) self.texture = t end,
            RegisterEvent = function(self, e)
                if e:find("^COMBAT_LOG_EVENT") then error("forbidden event " .. e) end
                self.events[e] = true
            end,
            UnregisterEvent = function(self, e) self.events[e] = nil end,
            SetBackdrop = function(self, b) self.backdrop = b end,
            SetOwner = function(self, owner) self.owner = owner end,
            SetHyperlink = function(self, link) self.link = link; self.lines = {} end,
            AddLine = function(self, text) self.lines = self.lines or {}; self.lines[#self.lines + 1] = text end,
            ClearLines = function(self) self.lines = {} end,
            SetDesaturated = function(self, v) self.desaturated = v and true or false end,
            Enable = function(self) self.disabled = false end,
            Disable = function(self) self.disabled = true end,
        }
        setmetatable(w, { __index = function(_, k)
            if allowed[k] then return impl[k] or function() end end
            -- Widget methods are PascalCase; anything else is a field the addon may read as nil.
            if type(k) == "string" and k:find("^%u") then error("unknown " .. kind .. " method " .. k, 2) end
            return nil
        end })
        C.widgets[#C.widgets + 1] = w
        return w
    end
    C.widget = widget

    -- Items: id -> { name, quality, equipLoc, cached }. Suffix names by suffix id.
    local items = opts.items
    local suffixes = { [1200] = " of the Bear", [14315] = " of Healing", [14301] = " of the Whale",
        [14309] = " of Intellect" }
    C.items, C.requested = items, {}

    local function parse(s)
        s = s:match("|H(item:[^|]+)|h") or s
        local body = s:match("^item:(.*)$")
        if not body then return nil end
        local fields = {}
        for f in (body .. ":"):gmatch("([^:]*):") do fields[#fields + 1] = f end
        return tonumber(fields[1]), tonumber(fields[7]) or 0
    end
    C.parse = parse

    function C.suffixName(id, suffix) return items[id].name .. (suffixes[suffix] or "") end

    -- As in the game: the generic link the client gives for an item id (key tooltip, scan tooltip, item
    -- info of a bare item string): no suffix, maybe an existing bonus ID (it.bonus).
    function C.genericLink(id)
        local it = items[id]
        local f = { tostring(id), "", "", "", "", "", "", "", "10", "1486", "", "" }
        f[13] = it.bonus and tostring(#it.bonus) or ""
        for _, b in ipairs(it.bonus or {}) do f[#f + 1] = tostring(b) end
        for _ = 1, 6 do f[#f + 1] = "" end
        return "|cnIQ" .. (it.quality or 2) .. ":|Hitem:" .. table.concat(f, ":") .. "|h[" .. it.name .. "]|h|r"
    end

    -- As in the game: a bare item string (with or without a suffix) resolves to the base item and the
    -- generic link; a hyperlink (an auction's own link) resolves to the name in it and keeps its link.
    local function getItemInfo(s)
        count("GetItemInfo")
        local id
        if type(s) == "number" then id = s else id = parse(s) end
        local it = id and items[id]
        if not it or not it.cached then return nil end
        local name, link
        if type(s) == "string" and s:find("|H", 1, true) then
            name = s:match("|h%[(.-)%]|h") or it.name
            link = s
        else
            name, link = it.name, C.genericLink(id)
        end
        local loc = it.secretFull and C.SECRET or it.equipLoc
        -- required level: per auction link (it.linkLevels), per item (it.minLevel), else 55; "secret" unreadable
        local minLevel = (it.linkLevels and it.linkLevels[link]) or it.minLevel or 55
        if minLevel == "secret" then minLevel = C.SECRET end
        return name, link, it.quality or 2, 60, minLevel, "Armor", "Plate", 1, loc, "icon" .. id
    end

    C.SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
    G.issecretvalue = function(v) return v == C.SECRET end
    G.GetTime = function() return C.clock end
    G.date = function() return "2026-11-15 12:00:00" end
    G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        C.printed[#C.printed + 1] = table.concat(parts, " ")
    end
    G.C_Timer = { After = function(d, fn) C.timers[#C.timers + 1] = { at = C.clock + d, fn = fn } end }
    G.CreateFrame = function(kind, _, parent, template) return widget(kind, parent, template) end
    G.UIParent = widget("Frame")
    if not opts.noKeyTooltip then
        G.C_TooltipInfo = {
            GetItemKey = function(id, _, suffix)
                count("GetItemKeyTooltip")
                local it = items[id]
                if not it or not it.cached then return nil end
                -- generic, as in the game
                return { type = 0, hyperlink = C.genericLink(id), lines = { { leftText = C.suffixName(id, suffix) },
                    { leftText = "Chest" }, { leftText = "Items in this group may vary in stats and appearance." } } }
            end,
            GetHyperlink = function(link)
                count("GetHyperlinkTooltip")
                local id = parse(link)
                local it = id and items[id]
                if not it or not it.cached then return nil end
                return { type = 0, lines = { { leftText = link:match("|h%[(.-)%]|h") or it.name }, { leftText = "Chest" } } }
            end,
        }
    end
    G.Enum = { AuctionHouseSortOrder = { Price = 0, Name = 1, Level = 2, Bid = 3, Buyout = 4, TimeRemaining = 5 } }
    G.SlashCmdList = {}
    G.BackdropTemplateMixin = {}
    G.GameTooltip = widget("GameTooltip")
    G.IsShiftKeyDown = function() return C.shift == true end
    -- the player's level: C.playerLevel (default 60, above every item's default 55), "secret" unreadable
    G.UnitLevel = function(unit)
        count("UnitLevel")
        if unit ~= "player" then return nil end
        if C.playerLevel == "secret" then return C.SECRET end
        return C.playerLevel or 60
    end
    G.GetCoinTextureString = function(copper) return "coin:" .. copper end
    C.chatOpen = false
    G.ChatEdit_InsertLink = function(link)
        if not C.chatOpen then return false end
        C.inserted = link
        return true
    end
    G.C_Item = {
        GetItemInfo = getItemInfo,
        GetItemInfoInstant = function(id)
            count("GetItemInfoInstant")
            local it = items[id]
            if not it then return nil end
            return id, "Armor", "Plate", it.secretInstant and C.SECRET or it.equipLoc, "icon" .. id, 4, 4
        end,
        GetItemNameByID = function(id) local it = items[id]; return it and it.cached and it.name or nil end,
        RequestLoadItemDataByID = function(id) C.requested[id] = (C.requested[id] or 0) + 1 end,
    }
    -- Auction house: the addon may only read.
    C.results, C.full = {}, true
    C.auctions, C.searches, C.searchReady, C.throttleReady = opts.auctions or {}, {}, {}, true
    -- Every attempt is recorded before throwing: a pcall in the addon could swallow the error.
    C.forbidden = {}
    local function forbidden(name)
        return function()
            C.forbidden[#C.forbidden + 1] = name
            error("AuctionJudge must not call C_AuctionHouse." .. name)
        end
    end
    G.C_AuctionHouse = {
        GetBrowseResults = function()
            count("GetBrowseResults")
            local out = {}
            for i, r in ipairs(C.results) do out[i] = r end
            return out
        end,
        HasFullBrowseResults = function() return C.full end,
        -- optional, as in the Forever client: opts.keyLevels["id:itemLevel:suffix"]
        GetItemKeyRequiredLevel = opts.keyLevels and function(key)
            count("GetItemKeyRequiredLevel")
            return opts.keyLevels[key.itemID .. ":" .. key.itemLevel .. ":" .. key.itemSuffix]
        end or nil,
        MakeItemKey = function(id, ilvl, suffix)
            return { itemID = id, itemLevel = ilvl or 0, itemSuffix = suffix or 0, battlePetSpeciesID = 0 }
        end,
        GetItemKeyInfo = function(key)
            local it = items[key.itemID]
            if not it or not it.cached or it.keyInfoLoaded == false then return nil end
            local name = C.suffixName(key.itemID, key.itemSuffix or 0)
            return { itemID = key.itemID, itemName = name, quality = it.quality or 2, iconFileID = "icon" .. key.itemID,
                isEquipment = it.equipLoc ~= "", isCommodity = false, isPet = false }
        end,
        -- Item searches: allowed, recorded with the time, the throttle state and the arguments. Results
        -- (opts.auctions["id:suffix"]) arrive 0.3 s later unless opts.noReply[key].
        IsThrottledMessageSystemReady = function() return C.throttleReady end,
        SendSearchQuery = (not opts.noSearchAPI) and function(itemKey, sorts, separate)
            if opts.searchErrors then error("search refused") end
            local k = itemKey.itemID .. ":" .. itemKey.itemSuffix
            C.searches[#C.searches + 1] = { key = k, at = C.clock, ready = C.throttleReady, sorts = sorts,
                itemKey = itemKey, separate = separate }
            if C.auctions[k] and not (opts.noReply and opts.noReply[k]) then
                C.timers[#C.timers + 1] = { at = C.clock + 0.3, fn = function()
                    C.searchReady[k] = true
                    -- the event carries an item key of its own (a different table)
                    C.fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = itemKey.itemID, itemLevel = itemKey.itemLevel,
                        itemSuffix = itemKey.itemSuffix, battlePetSpeciesID = 0 })
                end }
            end
        end or nil,
        GetNumItemSearchResults = function(key)
            local k = key.itemID .. ":" .. key.itemSuffix
            return C.searchReady[k] and #C.auctions[k] or 0
        end,
        GetItemSearchResultInfo = function(key, i)
            local a = C.auctions[key.itemID .. ":" .. key.itemSuffix][i]
            return a and { itemLink = a.link, buyoutAmount = a.buyout, bidAmount = a.bid, quantity = 1, auctionID = i,
                containsOwnerItem = false }
        end,
        HasFullItemSearchResults = function() return true end,
        SendBrowseQuery = forbidden("SendBrowseQuery"),
        RequestMoreBrowseResults = forbidden("RequestMoreBrowseResults"),
        PlaceBid = forbidden("PlaceBid"),
        StartCommoditiesPurchase = forbidden("StartCommoditiesPurchase"),
        PostItem = forbidden("PostItem"),
    }

    -- Sharpie's Gear Judge: pct[id] = number or "NOT_USABLE"; upgradePct scales with C.factor.
    if opts.sgj then
        C.sgjCallbacks, C.factor, C.ready = {}, 1, true
        local pct = opts.sgj
        C.pct = pct
        G.SharpiesGearJudgeAPI = {
            IsReady = function() return C.ready end,
            GetVersion = function() return 1, "3.2.7" end,
            GetSpec = function() if C.ready then return "RET_STANDARD", "Retribution: Raid" end end,
            RegisterCallback = function(event, fn)
                if event ~= "SCORES_CHANGED" and event ~= "SCORES_RECEIVED" then return false end
                C.sgjCallbacks[#C.sgjCallbacks + 1] = fn
                return true
            end,
            ScoreItem = function(link)
                count("ScoreItem")
                C.scoredLinks = C.scoredLinks or {}
                C.scoredLinks[#C.scoredLinks + 1] = link
                if not C.ready then return nil, "NOT_READY" end
                if type(link) ~= "string" or not link:find("item:%-?%d+") then return nil, "BAD_LINK" end
                -- like SGJ: GetItemInfo(link), and the returned link is the one judged
                local name, fullLink, _, _, _, _, _, _, equipLoc = getItemInfo(link)
                if not name then return nil, "NOT_CACHED" end
                link = fullLink or link
                if equipLoc == "" then return nil, "NOT_EQUIPPABLE" end
                local p = pct[link]
                if p == nil then p = pct[parse(link)] end
                if p == "NOT_USABLE" then return nil, "NOT_USABLE" end
                if p == nil then return nil, "ERROR" end
                return { upgradePct = p * C.factor, upgrade = p * 5, itemScore = 50, equippedScore = 40, slot = 5,
                    equipped = false, spec = "RET_STANDARD", specName = "Retribution: Raid", itemLink = link }
            end,
        }
    end

    local OPTIONAL = { "^AuctionJudgeDB$", "^AuctionHouseFrame$", "^ChatFrameUtil$", "^SharpiesGearJudgeAPI$" }
    if opts.noKeyTooltip then OPTIONAL[#OPTIONAL + 1] = "^C_TooltipInfo$" end
    setmetatable(G, {
        __index = function(_, k)
            local optional = false
            for _, p in ipairs(OPTIONAL) do if type(k) == "string" and k:find(p) then optional = true end end
            if not optional then C.missing[tostring(k)] = true end
            return nil
        end,
        __newindex = function(t, k, v) C.written[tostring(k)] = true; rawset(t, k, v) end,
    })

    C.ns = {}
    function C.load()
        for line in H.read("AuctionJudge/AuctionJudge.toc"):gmatch("[^\r\n]+") do
            if line:find("%.lua$") then H.load(line, C.ns, G) end
        end
    end

    function C.fire(event, ...)
        local list = {}
        for _, w in ipairs(C.widgets) do if w.scripts.OnEvent and w.events[event] then list[#list + 1] = w end end
        for _, w in ipairs(list) do w.scripts.OnEvent(w, event, ...) end
    end

    function C.updaters()
        local n = 0
        for _, w in ipairs(C.widgets) do if w.scripts.OnUpdate then n = n + 1 end end
        return n
    end

    function C.step()
        C.clock = C.clock + 0.05
        for i = #C.timers, 1, -1 do
            local t = C.timers[i]
            if t.at <= C.clock then table.remove(C.timers, i); t.fn() end
        end
        for _, w in ipairs(C.widgets) do
            if w.scripts.OnUpdate then w.scripts.OnUpdate(w, 0.05) end
        end
    end

    function C.advance(seconds)
        local stop = C.clock + seconds - 1e-9
        while C.clock < stop do C.step() end
    end

    -- The auction house UI: its frame exists from the first open on.
    function C.openAH()
        if not rawget(G, "AuctionHouseFrame") then
            local ah = widget("Frame", G.UIParent)
            ah.SearchBar = {
                SearchBox = { SetText = function(_, t) C.searchText = t end },
                StartSearch = function() C.searched = C.searchText end,
                FilterButton = widget("Button"),
            }
            rawset(G, "AuctionHouseFrame", ah)
        end
        G.AuctionHouseFrame:Show()
        C.fire("AUCTION_HOUSE_SHOW")
    end

    function C.closeAH()
        G.AuctionHouseFrame:Hide()
        C.fire("AUCTION_HOUSE_CLOSED")
    end

    function C.slash(msg) G.SlashCmdList.AUCTIONJUDGE(msg) end

    function C.printedSince(n, pattern)
        for i = n + 1, #C.printed do if C.printed[i]:find(pattern) then return true end end
        return false
    end

    function C.errors()
        local list = {}
        for _, line in ipairs(C.printed) do if line:find("|cffff5555error|r", 1, true) then list[#list + 1] = line end end
        return list
    end

    -- The panel and its parts, found by structure.
    function C.panel()
        local ah = rawget(G, "AuctionHouseFrame")
        if not ah then return nil end
        for _, c in ipairs(ah.children) do if c.kind == "Frame" and rawget(c, "template") == "BackdropTemplate" then return c end end
    end
    function C.rows()
        local list = {}
        for _, c in ipairs(C.panel().children) do if c.kind == "Button" and rawget(c, "cells") then list[#list + 1] = c end end
        return list
    end
    function C.shownRows()
        local list = {}
        for _, b in ipairs(C.rows()) do if b.shown then list[#list + 1] = b end end
        return list
    end
    function C.rowNames()
        local out = {}
        for i, b in ipairs(C.shownRows()) do out[i] = b.cells.name.text end
        return table.concat(out, ",")
    end
    function C.headers()
        local list = {}
        for _, c in ipairs(C.panel().children) do
            if c.kind == "Button" and rawget(c, "label") and not rawget(c, "cells") then list[#list + 1] = c end
        end
        return list
    end
    function C.checks()
        local list = {}
        for _, c in ipairs(C.panel().children) do if c.kind == "CheckButton" then list[#list + 1] = c end end
        return list
    end
    function C.texts()
        local out = {}
        for _, c in ipairs(C.panel().children) do
            if c.kind == "FontString" and rawget(c, "text") then out[#out + 1] = c.text end
        end
        return out
    end
    function C.hasText(pattern)
        for _, t in ipairs(C.texts()) do if t:find(pattern) then return true end end
        return false
    end
    function C.toggleButton()
        for _, c in ipairs(G.AuctionHouseFrame.children) do
            if c.kind == "Button" and rawget(c, "text") == "AJ" then return c end
        end
    end
    function C.closeButton()
        for _, c in ipairs(C.panel().children) do
            if c.kind == "Button" and rawget(c, "template") == "UIPanelCloseButton" then return c end
        end
    end

    return C
end

local function result(id, price, suffix, ilvl)
    return { itemKey = { itemID = id, itemLevel = ilvl or 60, itemSuffix = suffix or 0, battlePetSpeciesID = 0 },
        minPrice = price, totalQuantity = 1 }
end

---------------------------------------------------------------------------
-- Session with Sharpie's Gear Judge
---------------------------------------------------------------------------

local items = {
    [101] = { name = "Lionheart Helm", quality = 4, equipLoc = "INVTYPE_HEAD", cached = true },
    [102] = { name = "Bandit's Cloak", quality = 2, equipLoc = "INVTYPE_CLOAK", cached = true },
    [103] = { name = "Robe of Frost", quality = 3, equipLoc = "INVTYPE_ROBE", cached = false },
    [104] = { name = "Heavy Boots", quality = 2, equipLoc = "INVTYPE_FEET", cached = false },
    [105] = { name = "Shoddy Ring", quality = 1, equipLoc = "INVTYPE_FINGER", cached = true },
    [106] = { name = "Mage Staff", quality = 3, equipLoc = "INVTYPE_2HWEAPON", cached = true },
    [201] = { name = "Linen Cloth", quality = 1, equipLoc = "", cached = true },
    [202] = { name = "Small Bag", quality = 1, equipLoc = "INVTYPE_BAG", cached = true },
    [203] = { name = "Guild Tabard", quality = 1, equipLoc = "INVTYPE_TABARD", cached = false },
}
local pct = { [101] = 4.2, [102] = 1.5, [103] = 8, [104] = 2, [105] = -1.3, [106] = "NOT_USABLE" }
-- Many more cached gear items, for the batch limit and scrolling.
for i = 301, 360 do
    items[i] = { name = string.format("Plate Bracers %02d", i - 300), quality = 2, equipLoc = "INVTYPE_WRIST", cached = true }
    pct[i] = (i - 300) / 10
end

local C = Client({ items = items, sgj = pct })
local G = C.G

test("loads in TOC order; saved variables and the SGJ callback set up", function()
    C.load()
    G.AuctionJudgeDB = { exact = false } -- this session judges browse rows only (exact mode: its own sessions)
    C.fire("ADDON_LOADED", "AuctionJudge")
    C.fire("PLAYER_LOGIN")
    local db = G.AuctionJudgeDB
    ok(db, "saved variables")
    eq(db.maxQueries, 60, "max queries default")
    eq(db.shown and db.upgradesOnly and db.hideUnusable, true, "defaults on")
    eq(db.sortColumn .. tostring(db.sortDesc), "valuetrue", "default sort % per gold descending")
    eq(#C.sgjCallbacks, 1, "one SCORES_CHANGED callback")
    eq(C.updaters(), 0, "no OnUpdate while the auction house is closed")
    C.advance(1)
    eq(C.calls.ScoreItem, nil, "nothing scored before the auction house opens")
end)

test("auction house opens: panel created on the right edge, no results yet", function()
    C.openAH()
    eq(C.updaters(), 1, "work loop started")
    C.advance(0.3)
    eq(C.updaters(), 0, "work loop stopped when idle")
    local p = C.panel()
    ok(p, "panel created as a child of AuctionHouseFrame")
    eq(p.width, 420, "width")
    eq(p.points[1][1] .. p.points[1][3], "TOPLEFTTOPRIGHT", "top anchored to the right edge")
    eq(p.points[2][1] .. p.points[2][3], "BOTTOMLEFTBOTTOMRIGHT", "full height")
    ok(p.points[1][2] == G.AuctionHouseFrame, "anchored to AuctionHouseFrame")
    eq(p.strata, "HIGH", "same strata")
    ok(p:IsVisible(), "shown")
    ok(C.hasText("^AuctionJudge: Retribution: Raid$"), "title with the spec")
    ok(C.hasText("No browse results yet"), "empty count line")
    eq(#C.rows(), 20, "20 rows")
end)

test("results arrive: gear kept, duplicates priced low, uncached items wait", function()
    C.results = {
        result(101, 50000),            -- 4.2% at 5g: 0.84%/g
        result(102, 20000, 1200),      -- Bandit's Cloak of the Bear: 1.5% at 2g
        result(103, 400000),           -- uncached: 8% at 40g
        result(104, 15000),            -- uncached: 2% at 1.5g
        result(105, 1000),             -- downgrade
        result(106, 30000),            -- unusable
        result(201, 50),               -- not gear
        result(202, 10000),            -- bag
        result(203, 10000),            -- tabard, uncached: filtered by GetItemInfoInstant
        result(101, 80000),            -- same key, dearer
        result(101, 60000, 0, 63),     -- item level variant: same item string, same row
        { itemKey = { itemID = 0, battlePetSpeciesID = 39, itemLevel = 1, itemSuffix = 0 }, minPrice = 100,
            totalQuantity = 1 }, -- battle pet
    }
    local reads = C.calls.GetBrowseResults or 0
    C.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    C.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED") -- debounced: one read
    C.advance(0.5)
    eq(C.calls.GetBrowseResults - reads, 1, "one read for both events")
    local store = C.ns.store
    eq(#store.rows, 9, "one row per item key, pet skipped")
    eq(store.byKey["101:0"].price, 50000, "lower price kept")
    eq(store.byKey["102:1200"].name, "Bandit's Cloak of the Bear", "suffix resolved through the item string")
    eq(store.byKey["203:0"].state, "notgear", "tabard")
    eq(store.byKey["202:0"].state, "notgear", "bag")
    eq(store.byKey["201:0"].state, "notgear", "cloth")
    eq(store.byKey["103:0"].state, "pending", "uncached robe")
    ok(C.requested[103] and C.requested[104], "uncached items requested")
    eq(C.requested[203], nil, "the tabard is never requested")
    eq(C.rowNames(), "Lionheart Helm,Bandit's Cloak of the Bear", "upgrades by % per gold")
    ok(C.hasText("^4 gear items · 1 confirmed upgrade · 1 estimated · 2 pending$"), "count line")
end)

test("rows show quality colour, coin text, upgrade and value", function()
    local b = C.shownRows()[1]
    eq(b.cells.name.color[1] .. "," .. b.cells.name.color[2], "0.64,0.21", "epic colour")
    eq(b.icon.texture, "icon101", "icon")
    eq(b.cells.price.text, "coin:50000", "coin text")
    eq(b.cells.upgrade.text, "+4.2%", "upgrade")
    eq(b.cells.upgrade.color[2], 1, "green")
    eq(b.cells.value.text, "0.84%/g", "value")
end)

test("uncached items resolve on GET_ITEM_INFO_RECEIVED and get scored", function()
    items[103].cached, items[104].cached = true, true
    C.fire("GET_ITEM_INFO_RECEIVED", 103, true)
    C.fire("GET_ITEM_INFO_RECEIVED", 104, true)
    C.advance(0.5) -- one batch, then the next list refresh (at most 0.2 s later)
    eq(C.ns.store.byKey["103:0"].state, "scored", "robe scored")
    eq(C.rowNames(), "Heavy Boots,Lionheart Helm,Bandit's Cloak of the Bear,Robe of Frost", "by % per gold")
    ok(C.hasText("^6 gear items · 3 confirmed upgrades · 1 estimated · 0 pending$"), "count line")
end)

local function headerByLabel(label)
    for _, h in ipairs(C.headers()) do if h.label.text:find("^" .. label) then return h end end
end
local function click(w, button) w.scripts.OnClick(w, button or "LeftButton") end

test("sorting by header clicks", function()
    ok(headerByLabel("Value").label.text:find(" v$"), "Value marked descending")
    click(headerByLabel("Price"))
    eq(C.rowNames(), "Heavy Boots,Bandit's Cloak of the Bear,Lionheart Helm,Robe of Frost", "price ascending")
    ok(headerByLabel("Price").label.text:find(" %^$"), "price marked ascending")
    click(headerByLabel("Price"))
    eq(C.rowNames(), "Robe of Frost,Lionheart Helm,Bandit's Cloak of the Bear,Heavy Boots", "price descending")
    click(headerByLabel("Upgrade"))
    eq(C.rowNames(), "Robe of Frost,Lionheart Helm,Heavy Boots,Bandit's Cloak of the Bear", "upgrade descending")
    click(headerByLabel("Item"))
    eq(C.rowNames(), "Bandit's Cloak of the Bear,Heavy Boots,Lionheart Helm,Robe of Frost", "name ascending")
    click(headerByLabel("Value"))
    eq(G.AuctionJudgeDB.sortColumn .. tostring(G.AuctionJudgeDB.sortDesc), "valuetrue", "saved")
end)

test("filters: show all gear, then unusable too", function()
    local upgradesOnly, hideUnusable = C.checks()[1], C.checks()[2]
    eq(upgradesOnly.checked and hideUnusable.checked, true, "both checked")
    upgradesOnly.checked = false
    click(upgradesOnly)
    eq(G.AuctionJudgeDB.upgradesOnly, false, "saved")
    eq(C.rowNames(), "Heavy Boots,Lionheart Helm,Bandit's Cloak of the Bear,Robe of Frost,Shoddy Ring", "downgrade last")
    hideUnusable.checked = false
    click(hideUnusable)
    eq(C.rowNames(), "Heavy Boots,Lionheart Helm,Bandit's Cloak of the Bear,Robe of Frost,Shoddy Ring,Mage Staff",
        "unusable after the downgrade")
    local rows = C.shownRows()
    eq(rows[5].cells.upgrade.text, "-1.3%", "downgrade text")
    eq(rows[5].cells.upgrade.color[1], 0.6, "downgrade grey")
    eq(rows[5].cells.value.text, "", "no value for a downgrade")
    eq(rows[6].cells.upgrade.text, "unusable", "unusable text")
    eq(C.calls.ScoreItem, 6, "each gear row scored once: uncached items wait for item info, not for SGJ")
end)

test("more results: scored under the batch limit, scrollable", function()
    for i = 301, 360 do C.results[#C.results + 1] = result(i, 1000000) end -- 100g: below the others in % per gold
    C.full = false
    local before = C.calls.ScoreItem
    C.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    C.advance(0.2)
    local refreshes = 0
    local refresh = C.ns.Panel.Refresh
    C.ns.Panel.Refresh = function(...) refreshes = refreshes + 1; return refresh(...) end
    local perBatch = {}
    for _ = 1, 8 do
        local n = C.calls.ScoreItem
        C.step()
        perBatch[#perBatch + 1] = C.calls.ScoreItem - n
    end
    C.ns.Panel.Refresh = refresh
    ok(refreshes <= 3, "list rebuilt at most about 5 times a second while scoring: " .. refreshes .. " in 0.4 s")
    for _, n in ipairs(perBatch) do ok(n <= 20, "at most 20 scores per batch: " .. table.concat(perBatch, ",")) end
    C.advance(0.5)
    eq(C.calls.ScoreItem - before, 60, "the 60 new rows scored once each")
    eq(C.updaters(), 0, "nothing pending: work loop stopped")
    ok(C.hasText("^66 gear items · 63 confirmed upgrades · 1 estimated · 0 pending$"), "count line")
    ok(C.hasText("^More results not loaded$"), "incomplete-browse notice on the second line")
    eq(#C.shownRows(), 20, "20 rows shown")
    eq(C.shownRows()[1].cells.name.text, "Heavy Boots", "top before scrolling")
    local p = C.panel()
    p.scripts.OnMouseWheel(p, -1)
    eq(C.shownRows()[1].cells.name.text, C.ns.BuildView().list[4].name, "scrolled by 3")
    ok(C.hasText("^4%-23 of 66"), "footer range")
    for _ = 1, 30 do p.scripts.OnMouseWheel(p, -1) end
    ok(C.hasText("^47%-66 of 66"), "clamped at the end")
    for _ = 1, 30 do p.scripts.OnMouseWheel(p, 1) end
    ok(C.hasText("^1%-20 of 66"), "clamped at the top")
end)

test("the same results again use the score cache", function()
    local before = C.calls.ScoreItem
    C.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    C.advance(0.6) -- the read, then a batch for the random suffix groups (their item info is not cached), then a redraw
    eq(C.calls.ScoreItem, before, "no new scoring")
end)

test("row tooltip, search click, shift-click link", function()
    local b = C.shownRows()[1]
    b.scripts.OnEnter(b)
    ok(G.GameTooltip.owner == b and G.GameTooltip.link == C.ns.store.byKey["104:0"].link, "tooltip shows the link")
    b.scripts.OnLeave(b)

    -- The cloak: searched by its base name.
    local cloak
    for _, r in ipairs(C.shownRows()) do if r.cells.name.text == "Bandit's Cloak of the Bear" then cloak = r end end
    click(cloak)
    eq(C.searched, "Bandit's Cloak of the Bear", "search by the full name, random suffix included")

    C.shift = true
    C.chatOpen = true
    click(b)
    eq(C.inserted, C.ns.store.byKey["104:0"].link, "link inserted into chat")
    C.chatOpen = false
    local n = #C.printed
    click(b)
    ok(C.printedSince(n, "Heavy Boots"), "no chat box open: link printed")
    C.shift = false

    G.AuctionHouseFrame.SearchBar.StartSearch = function() error("search bar changed") end
    n = #C.printed
    click(b)
    ok(C.printedSince(n, "could not search.*Heavy Boots"), "failed search prints the link")
end)

test("SCORES_CHANGED rescores everything", function()
    local before = C.calls.ScoreItem
    C.factor = 2
    for _, fn in ipairs(C.sgjCallbacks) do fn() end
    C.advance(0.2) -- a redraw at most 0.2 s away; 66 rows take four batches
    local pending
    for _, t in ipairs(C.texts()) do pending = pending or tonumber(t:match("^%d+ gear items .- (%d+) pending$")) end
    ok(pending and pending > 0, "pending while rescoring: " .. tostring(pending))
    C.advance(1)
    eq(C.calls.ScoreItem - before, 66, "every gear row scored again")
    local b = C.shownRows()[1]
    eq(b.cells.name.text, "Heavy Boots", "still first")
    eq(b.cells.upgrade.text, "+4.0%", "new score")
    eq(b.cells.value.text, "2.67%/g", "new value")
end)

test("SGJ not ready: rows wait, then score", function()
    C.ready = false
    for _, fn in ipairs(C.sgjCallbacks) do fn() end
    C.advance(0.5)
    ok(C.hasText("^Waiting for Sharpie's Gear Judge"), "waiting line")
    eq(C.ns.store.byKey["101:0"].state, "pending", "pending")
    C.ready = true
    for _, fn in ipairs(C.sgjCallbacks) do fn() end
    C.advance(1)
    eq(C.ns.store.byKey["101:0"].state, "scored", "scored once ready")
end)

test("slash commands", function()
    local n = #C.printed
    C.slash("status")
    ok(C.printedSince(n, "Sharpie's Gear Judge: loaded, ready yes, version 1, 3.2.7, spec Retribution: Raid"), "SGJ line")
    ok(C.printedSince(n, "SGJ API: IsReady ok, ScoreItem ok, RegisterCallback ok, GetSpec ok, GetVersion ok; "
        .. "SCORES_CHANGED registered yes"), "API line")
    ok(C.printedSince(n, "Auction house: open; last browse results 72 %(all loaded: no%)"), "browse line")
    ok(C.printedSince(n, "Rows: 69 listed from 69 browse rows %(gear 66, upgrades 64: confirmed 63, estimated 1; "
        .. "scored 65, pending 0 of which resolving 0, unusable 1, error 0, not gear 3%)"), "rows line")
    ok(C.printedSince(n, "Exact scores: off; random suffix groups 1, done 0 %(checked 0%); lookups %-; queue 0 queued, "
        .. "0 sent"), "exact line")
    ok(C.printedSince(n, "sort Value descending"), "panel line")
    n = #C.printed
    C.slash("debug")
    ok(C.printedSince(n, "69 rows"), "debug header")
    ok(C.printedSince(n, "^.*2%. 102:1200 .*%[Bandit's Cloak%].* scored price 20000 upgrade 3"), "debug row")
    ok(C.printedSince(n, "7%. 201:0 item:201 notgear %(EQUIP_LOC%)"), "not gear row with reason")
    local lines = #C.printed - n
    eq(lines, 16, "header and 15 rows")
    n = #C.printed
    C.slash("debug CLOAK")
    ok(C.printedSince(n, "Rows matching \"CLOAK\": 1"), "debug lookup header")
    ok(C.printedSince(n, "102:1200 Bandit's Cloak of the Bear: scored; upgrade 3, item 50 vs equipped 40 %(slot 5%); "
        .. "price 20000, value 1.5; shown"), "debug lookup row")
    ok(C.printedSince(n, "id 102 suffix 1200 ilvl 60, item:102::::::1200, INVTYPE_CLOAK, link %(iteminfo%) "
        .. "|cnIQ2:|Hitem:102::::::::10:1486:.*; base item score, exact auctions not read"), "debug lookup second line")
    n = #C.printed
    C.slash("debug item:201")
    ok(C.printedSince(n, "201:0 %-: notgear %(EQUIP_LOC%).*hidden: not gear"), "hidden not-gear row (no name: found by item string)")
    n = #C.printed
    C.slash("")
    ok(C.printedSince(n, "/aj show | hide | toggle | status | debug"), "help")
end)

test("hide, show, toggle, close button and reopen button", function()
    local p = C.panel()
    C.slash("hide")
    eq(p.shown, false, "hidden")
    eq(G.AuctionJudgeDB.shown, false, "saved")
    ok(C.toggleButton().shown, "reopen button visible")
    click(C.toggleButton())
    eq(p.shown, true, "reopened")
    eq(C.toggleButton().shown, false, "reopen button hidden")
    click(C.closeButton())
    eq(p.shown, false, "close button")
    C.slash("toggle")
    eq(p.shown, true, "toggle")
    C.slash("show")
    eq(p.shown, true, "show")
end)

test("auction house closes: loop stops, rows dropped; reopening reuses the panel and caches", function()
    local panelsBefore = 0
    for _, c in ipairs(G.AuctionHouseFrame.children) do if rawget(c, "template") == "BackdropTemplate" then panelsBefore = panelsBefore + 1 end end
    C.closeAH()
    local d = G.AuctionJudgeDB.lastDump
    ok(d, "dump written on close")
    eq(d.why .. " " .. d.time, "closed 2026-11-15 12:00:00", "why and when")
    eq(d.sgjReady and d.spec, "Retribution: Raid", "SGJ state")
    eq(d.rawCount .. " " .. d.rowCount .. " " .. #d.rows, "72 69 69", "counts")
    eq(d.full, false, "HasFullBrowseResults")
    eq(d.filters.upgradesOnly, false, "filters")
    eq(d.counts.scored, 65, "counts by state")
    eq(d.rows[#d.rows].state, "notgear", "not-gear rows last")
    local pet, merged = 0, 0
    for _, s in ipairs(d.skipped) do
        if s.reason == "battle pet" then pet = pet + 1 end
        if s.reason:find("^merged into row 101:0") then merged = merged + 1 end
    end
    eq(pet .. " " .. merged, "1 2", "skipped: the pet and the two merged 101 entries")
    local function plainOnly(t, path)
        for k, v in pairs(t) do
            local tv = type(v)
            if v == C.SECRET then error(path .. "." .. k .. " is secret") end
            if tv == "table" then plainOnly(v, path .. "." .. tostring(k))
            elseif tv ~= "string" and tv ~= "number" and tv ~= "boolean" then error(path .. "." .. k .. " is " .. tv) end
        end
    end
    plainOnly(d, "lastDump")
    eq(C.updaters(), 0, "no OnUpdate")
    C.fire("PLAYER_LOGOUT")
    eq(G.AuctionJudgeDB.lastDump, d, "no dump on logout while closed")
    eq(#C.ns.store.rows, 0, "rows dropped")
    eq(C.panel():IsVisible(), false, "panel hidden")
    local before = C.calls.GetBrowseResults
    C.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    C.advance(1)
    eq(C.calls.GetBrowseResults, before, "no reads while closed")

    C.results = { result(101, 50000), result(104, 15000) }
    local scored = C.calls.ScoreItem
    C.openAH()
    C.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    C.advance(0.5)
    local panels = 0
    for _, c in ipairs(G.AuctionHouseFrame.children) do if rawget(c, "template") == "BackdropTemplate" then panels = panels + 1 end end
    eq(panels, panelsBefore, "panel reused")
    eq(C.rowNames(), "Heavy Boots,Lionheart Helm", "results from the cache")
    eq(C.calls.ScoreItem, scored, "no new scoring")
    C.closeAH()
    C.advance(1)
end)

test("no errors, no undefined globals read, no stray globals written, no queries sent", function()
    local errs = C.errors()
    eq(#errs, 0, "errors: " .. table.concat(errs, " / "))
    local names = {}
    for k in pairs(C.missing) do names[#names + 1] = k end
    table.sort(names)
    eq(#names, 0, "undefined globals read: " .. table.concat(names, ", "))
    local allowed = { AuctionJudgeDB = true, SLASH_AUCTIONJUDGE1 = true, SLASH_AUCTIONJUDGE2 = true }
    local stray = {}
    for k in pairs(C.written) do if not allowed[k] then stray[#stray + 1] = k end end
    table.sort(stray)
    eq(#stray, 0, "stray globals: " .. table.concat(stray, ", "))
    eq(#C.forbidden, 0, "forbidden auction house calls: " .. table.concat(C.forbidden, ", "))
end)

---------------------------------------------------------------------------
-- Session with unreadable (secret) equip locations
---------------------------------------------------------------------------

local secretItems = {
    [401] = { name = "Veiled Gloves", equipLoc = "INVTYPE_HANDS", cached = true, secretInstant = true },
    [402] = { name = "Masked Belt", equipLoc = "INVTYPE_WAIST", cached = true, secretFull = true },
}
local S = Client({ items = secretItems, sgj = { [401] = 3, [402] = 2 } })

test("unreadable equip locations are unknown, not 'not gear'", function()
    S.load()
    S.fire("ADDON_LOADED", "AuctionJudge")
    S.openAH()
    S.results = { result(401, 10000), result(402, 5000) } -- the belt costs silver
    S.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    S.advance(0.5)
    local store = S.ns.store
    eq(store.byKey["401:0"].state, "scored", "secret instant equip location: resolved through full item info")
    local belt = store.byKey["402:0"]
    eq(belt.state, "pending", "secret full-info equip location: still pending")
    eq(belt.reason, "EQUIP_LOC_UNKNOWN", "reason")
    eq(store.info[belt.itemString], nil, "not cached")
    secretItems[402].secretFull = false
    S.advance(3)
    eq(belt.state, "scored", "scored on a retry once readable")
    -- belt: 2% at 50s = 4%/g, shown per silver; gloves: 3% at 1g = 3%/g
    eq(S.rowNames(), "Masked Belt,Veiled Gloves", "both listed, by the true ratio")
    eq(S.shownRows()[1].cells.value.text, "0.04%/s", "per silver under 1 gold")
    eq(S.shownRows()[2].cells.value.text, "3.00%/g", "per gold")
    S.fire("PLAYER_LOGOUT")
    local d = S.G.AuctionJudgeDB.lastDump
    eq(d.why .. " " .. #d.rows, "logout 2", "dump on logout with the auction house open")
    S.closeAH()
    eq(S.G.AuctionJudgeDB.lastDump.why, "closed", "and again on close")
    local errs = S.errors()
    eq(#errs, 0, "errors: " .. table.concat(errs, " / "))
    local names = {}
    for k in pairs(S.missing) do names[#names + 1] = k end
    eq(#names, 0, "undefined globals read: " .. table.concat(names, ", "))
    eq(#S.forbidden, 0, "forbidden auction house calls")
end)

---------------------------------------------------------------------------
-- Random suffix groups and exact scores: a browse row is a group of auctions whose stats vary; the
-- auctions' own links come from an item search, sent only through the queue.
---------------------------------------------------------------------------

local HEALING, WHALE, INTELLECT = 14315, 14301, 14309
local function auctionLink(bonus, name)
    return "|cnIQ2:|Hitem:501::::::::15:1486:::1:" .. bonus .. "::::::|h[" .. name .. "]|h|r"
end
local H1, H2 = auctionLink(12725, "Cadet Vest of Healing"), auctionLink(12726, "Cadet Vest of Healing")
local W1, I1 = auctionLink(12730, "Cadet Vest of the Whale"), auctionLink(12740, "Cadet Vest of Intellect")
-- the same item as H1, differing only in link metadata (item context 1, a modifier pair), as seen in the game
local H1b = "|cnIQ2:|Hitem:501::::::::15:1486::1:1:12725:1:28:5256:::::|h[Cadet Vest of Healing]|h|r"
-- the base item 2.5%, the auctions what SGJ's tooltip shows on each
local EXACT_PCT = { [501] = 2.5, [601] = 3, [701] = "NOT_USABLE", [H1] = 15.4, [H2] = 9, [W1] = 11.8, [I1] = 6 }
local AUCTIONS = {
    ["501:" .. HEALING] = { { link = H1, buyout = 449 }, { link = H1b, buyout = 900 }, { link = H2, bid = 300 } },
    ["501:" .. WHALE] = { { link = W1, buyout = 50000 } },
    ["501:" .. INTELLECT] = { { link = I1, buyout = 155000 } },
}

local function exactSession(xopts)
    local list = {
        [501] = { name = "Cadet Vest", quality = 2, equipLoc = "INVTYPE_CHEST", cached = true, bonus = { 3524 } },
        [601] = { name = "Iron Helm", quality = 2, equipLoc = "INVTYPE_HEAD", cached = true },
        [701] = { name = "Plate Vest", quality = 2, equipLoc = "INVTYPE_CHEST", cached = true },
    }
    local X = Client({ items = xopts.items or list, sgj = xopts.sgj or EXACT_PCT, auctions = xopts.auctions or AUCTIONS,
        noReply = xopts.noReply,
        noSearchAPI = xopts.noSearchAPI, searchErrors = xopts.searchErrors })
    X.throttleReady = xopts.throttle ~= false
    X.load()
    X.fire("ADDON_LOADED", "AuctionJudge")
    if xopts.slash then X.slash(xopts.slash) end
    X.openAH()
    X.results = xopts.results or { result(501, 449, HEALING), result(501, 50000, WHALE), result(501, 155000, INTELLECT),
        result(601, 30000), result(701, 1000, HEALING) }
    X.browseAt = X.clock
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    X.advance(xopts.wait or 4)
    return X
end

local function upgrades(X)
    local out = {}
    for i, b in ipairs(X.shownRows()) do out[i] = b.cells.upgrade.text end
    return table.concat(out, ",")
end

local function searched(X)
    local out = {}
    for i, q in ipairs(X.searches) do out[i] = q.key end
    return table.concat(out, ",")
end

local function countLine(X)
    for _, t in ipairs(X.texts()) do if t:find("gear item") then return t end end
end

-- the line under the count line: lookup progress and the incomplete-browse notice
local function progressLine(X)
    local after = false
    for _, c in ipairs(X.panel().children) do
        if c.kind == "FontString" then
            local t = rawget(c, "text")
            if after then return t or "" end
            after = t ~= nil and t:find("gear item") ~= nil
        end
    end
end

local function clean(X)
    local errs = X.errors()
    eq(#errs, 0, "errors: " .. table.concat(errs, " / "))
    local names = {}
    for k in pairs(X.missing) do names[#names + 1] = k end
    eq(#names, 0, "undefined globals read: " .. table.concat(names, ", "))
    eq(#X.forbidden, 0, "forbidden auction house calls: " .. table.concat(X.forbidden, ", "))
    for _, q in ipairs(X.searches) do ok(q.ready, "item search only while the throttle is ready") end
    for i = 2, #X.searches do
        ok(X.searches[i].at - X.searches[i - 1].at >= 0.5 - 1e-9, "item searches at least 0.5 s apart")
    end
end

test("exact: random suffix groups replaced by their auctions, each judged by its own link", function()
    local X = exactSession({})
    eq(searched(X), "501:" .. HEALING .. ",501:" .. WHALE .. ",501:" .. INTELLECT, "cheapest group first; fixed-stat "
        .. "and unusable items never searched")
    ok(X.searches[1].at >= X.browseAt + 1.5 - 1e-9, "held off 1.5 s after the browse results")
    eq(X.searches[1].sorts[1].sortOrder, 4, "sorted by buyout")
    ok(X.searches[1].itemKey == X.results[1].itemKey, "the browse result's own item key is passed")
    eq(X.rowNames(), "Cadet Vest of Healing,Cadet Vest of Healing,Cadet Vest of the Whale,Iron Helm,"
        .. "Cadet Vest of Intellect", "one row per distinct item (link metadata ignored), by value")
    eq(upgrades(X), "+15.4%,+9.0%,+11.8%,+3.0%,+6.0%", "exact scores, none starred")
    local rows = X.shownRows()
    eq(rows[1].cells.price.text, "coin:449", "same item: the lowest buyout kept")
    eq(rows[2].cells.price.text, "coin:300 bid", "bid-only auction priced at its bid, marked")
    local healing = X.ns.store.byKey["501:" .. HEALING]
    eq(#healing.auctions, 2, "two distinct items")
    eq(healing.auctions[1].link, H1, "the cheaper auction's link")
    eq(healing.auctions[1].auctionCount, 2, "merge count kept for debug and the dump")
    local click = function(b) b.scripts.OnClick(b, "LeftButton") end
    click(rows[1])
    eq(X.searched, "Cadet Vest of Healing", "auction row: search by its full name")
    eq(healing.auctions[1].sgjLink, H1, "SGJ judged the auction's link")
    eq(countLine(X), "6 gear items · 5 confirmed upgrades · 0 pending", "count line, all confirmed")
    eq(progressLine(X), "Lookups complete: 3/3 checked", "completion confirmed with the group count")
    eq(X.updaters(), 0, "idle once done")
    local n = #X.printed
    X.slash("debug healing")
    ok(X.printedSince(n, "item search resolved, 1 attempt, 3 results, 2 rows, listed as its auction rows"), "group line")
    ok(X.printedSince(n, "auction of group 501:" .. HEALING .. " %(2 auctions of this item%)"), "auction line")
    n = #X.printed
    X.slash("status")
    ok(X.printedSince(n, "Exact scores: on; random suffix groups 3, done 3 %(checked 3%); lookups complete; queue 0 queued, "
        .. "3 sent this search %(max 60%), 0 failed"), "status queue line")
    ok(X.printedSince(n, "Item search API: SendSearchQuery ok, GetNumItemSearchResults ok, GetItemSearchResultInfo ok, "
        .. "HasFullItemSearchResults ok, IsThrottledMessageSystemReady ok; sort Buyout"), "status API line")

    -- SGJ's scores change: the auction rows are judged again, nothing searched again
    local before = #X.searches
    X.factor = 2
    for _, fn in ipairs(X.sgjCallbacks) do fn() end
    X.advance(1)
    eq(upgrades(X), "+30.8%,+18.0%,+23.6%,+6.0%,+12.0%", "rescored")
    eq(#X.searches, before, "no new searches")

    X.closeAH()
    local d = X.G.AuctionJudgeDB.lastDump
    local g = d.groups[1]
    eq(g.key .. " " .. g.query .. " " .. g.attempts .. " " .. g.results .. " " .. g.auctionRows,
        "501:" .. HEALING .. " resolved 1 3 2", "group in the dump")
    local r = d.rows[1]
    eq(tostring(r.auction) .. " " .. r.group .. " " .. r.link .. " " .. r.sgjLink, "true 501:" .. HEALING .. " " .. H1 .. " "
        .. H1, "auction row in the dump")
    eq(d.exact.sent .. " " .. d.exact.failures .. " " .. tostring(d.exact.active), "3 0 true", "queue in the dump")
    eq(d.suffixSample.auctionLink, H1, "tooltip sample: the first auction")
    eq(d.suffixSample.keyTooltipLines[3], "Items in this group may vary in stats and appearance.", "key tooltip lines")
    eq(d.suffixSample.linkTooltipLines[1], "Cadet Vest of Healing", "auction tooltip lines")
    clean(X)
end)

local GREY = "0.6,0.6,0.6"
local function rgb(c) return table.concat(c, ",") end

test("exact: nothing is searched while the throttle is not ready", function()
    local X = exactSession({ throttle = false, wait = 3 })
    eq(#X.searches, 0, "no searches")
    eq(upgrades(X), "+2.5%*,+3.0%,+2.5%*,+2.5%*", "base scores starred meanwhile")
    -- rows waiting to be scanned are greyed; the fixed-stat Iron Helm is not
    local rows = X.shownRows()
    local g, helm = rows[1], rows[2]
    eq(rgb(g.cells.name.color) .. " / " .. rgb(g.cells.upgrade.color) .. " / " .. rgb(g.cells.value.color), GREY .. " / "
        .. GREY .. " / " .. GREY, "group row: name, upgrade, value grey")
    eq(tostring(g.icon.desaturated), "true", "icon desaturated")
    eq(g.cells.price.color, nil, "price keeps its colour")
    eq(rgb(helm.cells.name.color) .. " " .. rgb(helm.cells.upgrade.color) .. " " .. tostring(helm.icon.desaturated),
        "0.12,1,0 0.1,1,0.1 false", "fixed-stat row: quality colour, green upgrade")
    g.scripts.OnEnter(g)
    eq(X.G.GameTooltip.lines[1], "AuctionJudge: * base item score. Waiting to be looked up", "tooltip reason")
    helm.scripts.OnEnter(helm)
    eq(#X.G.GameTooltip.lines, 0, "no extra line for an exact row")
    eq(countLine(X), "5 gear items · 1 confirmed upgrade · 3 estimated · 0 pending", "starred groups are estimates")
    eq(progressLine(X), "Checking random-stat items: 0/3 checked", "progress")
    local n = #X.printed
    X.slash("status")
    ok(X.printedSince(n, "waiting: throttle"), "status says why")
    X.throttleReady = true
    X.fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    X.advance(3)
    eq(#X.searches, 3, "searches once ready")
    local first = X.shownRows()[1]
    eq(first.cells.name.text .. " " .. rgb(first.cells.name.color) .. " " .. tostring(first.icon.desaturated),
        "Cadet Vest of Healing 0.12,1,0 false", "resolved auction rows in normal colours")
    for _, b in ipairs(X.shownRows()) do eq(b.scanReason, nil, "no row greyed once resolved") end
    X.closeAH()
    clean(X)
end)

test("exact: browse events hold the queue; a new search cancels it; the cap holds per search", function()
    local X = exactSession({ slash = "maxqueries 1", wait = 1.7 })
    eq(#X.searches, 1, "one search")
    -- more browse results (the user scrolls): 1.5 s of quiet
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    local at = X.clock
    X.advance(3)
    eq(#X.searches, 1, "cap: still one search")
    eq(X.updaters(), 0, "capped: idle")
    eq(countLine(X), "6 gear items · 3 confirmed upgrades · 2 estimated · 0 pending", "count line")
    eq(progressLine(X), "Lookup limit 1 reached: 1/3 checked", "stopped at the cap")
    local capped = X.shownRows()[#X.shownRows()]
    eq(capped.scanReason, "Not looked up (limit reached)", "over the cap: greyed with the reason")
    -- the cap changed while the queue is parked on the throttle: the panel follows at once
    X.throttleReady = false
    X.slash("maxqueries 2")
    X.advance(0.3)
    eq(progressLine(X) .. " / " .. tostring(X.shownRows()[#X.shownRows()].scanReason),
        "Checking random-stat items: 1/3 checked / Waiting to be looked up", "raised: no longer stopped")
    eq(#X.searches, 1, "nothing sent under the throttle")
    X.slash("maxqueries 1")
    X.advance(0.3) -- the list redraws at most 5 times a second
    eq(progressLine(X) .. " / " .. tostring(X.shownRows()[#X.shownRows()].scanReason),
        "Lookup limit 1 reached: 1/3 checked / Not looked up (limit reached)", "lowered again: stopped")
    X.throttleReady = true
    -- a new search: queue cancelled, the cap starts again
    X.slash("maxqueries 60")
    X.results = { result(501, 50000, WHALE) }
    local resolvedBefore = X.ns.store.byKey["501:" .. HEALING].query.state
    eq(resolvedBefore, "resolved", "the first group was resolved")
    at = X.clock
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    X.advance(1.4)
    eq(#X.searches, 1, "held after the new search")
    X.advance(1.5)
    eq(searched(X), "501:" .. HEALING .. ",501:" .. WHALE, "the new search's group")
    ok(X.searches[2].at >= at + 1.5 - 1e-9, "not before the hold ended")
    eq(X.rowNames(), "Cadet Vest of the Whale", "its auction row")
    X.closeAH()
    clean(X)
end)

test("exact: a query in flight is dropped when the results change; closing cancels the queue", function()
    local X = exactSession({ wait = 1.6 })
    eq(#X.searches, 1, "first search sent")
    -- replaced before the reply arrives: the reply is ignored
    X.results = { result(601, 30000) }
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    X.advance(2)
    eq(X.rowNames(), "Iron Helm", "only the new results")
    eq(X.ns.queue.inflight, nil, "nothing in flight")
    eq(#X.searches, 1, "nothing more to search")
    -- closing with groups queued: nothing is sent while closed, nothing left after
    X.results = { result(501, 449, HEALING), result(501, 50000, WHALE) }
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    X.advance(0.5)
    ok(X.ns.Queue.Length(X.ns.queue) > 0, "queued")
    X.closeAH()
    eq(X.ns.Queue.Length(X.ns.queue), 0, "queue cancelled on close")
    X.advance(3)
    eq(#X.searches, 1, "nothing sent while closed")
    clean(X)
end)

test("exact: a query without results times out; the queue goes on", function()
    local X = exactSession({ noReply = { ["501:" .. HEALING] = true }, wait = 9 })
    eq(searched(X), "501:" .. HEALING .. ",501:" .. WHALE .. ",501:" .. INTELLECT, "all three sent")
    local healing = X.ns.store.byKey["501:" .. HEALING]
    eq(healing.query.state, "timeout", "timed out")
    eq(healing.upgradePct .. " " .. tostring(healing.approximate), "2.5 true", "stays starred")
    ok(X.searches[2].at - X.searches[1].at >= 5 - 1e-9, "the next one after the timeout")
    local n = #X.printed
    X.slash("status")
    ok(X.printedSince(n, "random suffix groups 3, done 3 %(checked 2%); lookups complete; queue 0 queued, 3 sent this "
        .. "search %(max 60%), 1 failed"), "status")
    eq(progressLine(X), "Lookups complete: 2/3 checked, 1 failed", "the timeout is not counted as checked")
    X.closeAH()
    eq(X.G.AuctionJudgeDB.lastDump.groups[1].query, "timeout", "dump")
    clean(X)
end)

test("exact: missing item search API disables it for the session; base scores starred", function()
    local X = exactSession({ noSearchAPI = true })
    eq(#X.searches, 0, "nothing sent")
    eq(upgrades(X), "+2.5%*,+3.0%,+2.5%*,+2.5%*", "starred")
    ok(X.printedSince(0, "exact scores for random suffix items are off for this session: SendSearchQuery missing"),
        "said so")
    local n = #X.printed
    X.slash("status")
    ok(X.printedSince(n, "Exact scores: on but inactive %(disabled: SendSearchQuery missing%)"), "status")
    ok(X.printedSince(n, "Item search API: SendSearchQuery MISSING"), "API line")
    eq(progressLine(X), "Lookup not available: SendSearchQuery missing", "progress line")
    eq(X.updaters(), 0, "idle")
    X.closeAH()
    clean(X)
end)

test("exact: an erroring item search disables it for the session", function()
    local X = exactSession({ searchErrors = true })
    ok(X.printedSince(0, "off for this session: SendSearchQuery error: .*search refused"), "said so")
    eq(upgrades(X), "+2.5%*,+3.0%,+2.5%*,+2.5%*", "starred")
    X.closeAH()
    clean(X)
end)

local function exactBox(X) return X.checks()[3] end
local function clickBox(X, checked)
    local box = exactBox(X)
    box.checked = checked -- the client toggles the box before OnClick
    box.scripts.OnClick(box, "LeftButton")
end

test("Scan specific items checkbox: off lists starred groups and cancels the queue, on restores", function()
    local X = exactSession({ wait = 1.6 })
    local box = exactBox(X)
    eq(box.label.text .. " " .. tostring(box.checked) .. " " .. tostring(box.disabled), "Scan specific items true false",
        "third checkbox, checked by default, enabled")
    for _, c in ipairs(X.checks()) do ok(c.points[1][4] + 24 + c.label.width <= 412, "fits the panel width") end
    box.scripts.OnEnter(box)
    eq(X.G.GameTooltip.lines[2], "Looks up the individual auctions of items with random stats to judge them exactly. "
        .. "Sends extra auction house searches. When off, such items show their base score marked with *.", "tooltip")
    eq(#X.searches, 1, "first search in flight")

    clickBox(X, false) -- mid-queue
    eq(X.G.AuctionJudgeDB.exact, false, "saved")
    eq(X.ns.queue.inflight, nil, "query in flight dropped at once")
    eq(X.ns.Queue.Length(X.ns.queue), 0, "queue cancelled at once")
    X.advance(3)
    eq(#X.searches, 1, "nothing more sent")
    eq(upgrades(X), "+2.5%*,+3.0%,+2.5%*,+2.5%*", "starred group rows")

    clickBox(X, true)
    eq(X.G.AuctionJudgeDB.exact, true, "saved")
    X.advance(4)
    eq(searched(X), "501:" .. HEALING .. ",501:" .. HEALING .. ",501:" .. WHALE .. ",501:" .. INTELLECT,
        "the unresolved groups queued again (the dropped one searched again)")
    eq(upgrades(X), "+15.4%,+9.0%,+11.8%,+3.0%,+6.0%", "exact rows")

    -- resolved groups go back to their starred rows and return without searching again
    clickBox(X, false)
    eq(X.rowNames(), "Cadet Vest of Healing,Iron Helm,Cadet Vest of the Whale,Cadet Vest of Intellect", "group rows")
    eq(upgrades(X), "+2.5%*,+3.0%,+2.5%*,+2.5%*", "starred")
    -- the slash command and the box stay in sync
    X.slash("exact on")
    X.advance(0.5)
    eq(exactBox(X).checked, true, "box follows /aj exact on")
    eq(upgrades(X), "+15.4%,+9.0%,+11.8%,+3.0%,+6.0%", "auction rows back")
    eq(#X.searches, 4, "no new searches")
    X.slash("exact off")
    X.advance(0.5)
    eq(exactBox(X).checked, false, "box follows /aj exact off")
    X.closeAH()
    clean(X)
end)

-- As seen in the game: the same random suffix group searched again showed browse price 999 instead of 449,
-- but the auction rows read for the first search stayed listed and no item search was sent.
test("exact: a fresh search clears the list and looks a group up again; more results of the same search do not", function()
    local X = exactSession({})
    local hkey = "501:" .. HEALING
    local function group() return X.ns.store.byKey[hkey] end
    local first = group()
    local function lateReply() -- an item search event for the key, e.g. a late reply to the old query
        X.fire("ITEM_SEARCH_RESULTS_ADDED", { itemID = 501, itemLevel = 60, itemSuffix = HEALING, battlePetSpeciesID = 0 })
    end
    eq(X.shownRows()[1].cells.price.text, "coin:449", "first search: the auction's price")

    -- more results of the same search: the rows and their auctions stay, nothing searched again
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    X.advance(3)
    eq(#X.searches, 3, "no new searches")
    ok(group() == first, "the same group row")
    eq(#first.auctions, 2, "auction rows kept")

    -- the auctions change; the user searches for the group again
    X.auctions = { [hkey] = { { link = H1, buyout = 999 } } }
    X.results = { result(501, 999, HEALING), result(601, 30000) }
    local scored = #X.scoredLinks
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    lateReply()
    eq(group(), nil, "old rows dropped at once; a late reply finds no group")
    X.step() -- drawn at the next frame, before the debounced read
    eq(X.rowNames(), "", "empty while the new results are not read")
    X.advance(0.6) -- the read, a batch for the group (its item info is not cached), then a redraw
    lateReply()
    eq(group().auctions, nil, "a late reply after the read is not taken for the new search")
    eq(X.rowNames(), "Cadet Vest of Healing,Iron Helm", "the new results")
    eq(upgrades(X) .. " " .. X.shownRows()[1].cells.price.text, "+2.5%*,+3.0% coin:999", "the group starred, at the new browse price")
    X.advance(3)
    eq(searched(X), "501:" .. HEALING .. ",501:" .. WHALE .. ",501:" .. INTELLECT .. ",501:" .. HEALING,
        "the group looked up again")
    eq(X.rowNames(), "Cadet Vest of Healing,Iron Helm", "one auction row")
    eq(upgrades(X) .. " " .. X.shownRows()[1].cells.price.text, "+15.4%,+3.0% coin:999", "exact, at the new price")
    eq(#X.scoredLinks, scored, "every score came from the session cache")
    local n = #X.printed
    X.slash("status")
    ok(X.printedSince(n, "1 sent this search"), "the cap counts this search only")

    -- exact off during a new search: on again looks the group up
    clickBox(X, false)
    X.auctions = { [hkey] = { { link = H2, buyout = 500 } } }
    X.results = { result(501, 500, HEALING) }
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    X.advance(3)
    eq(#X.searches, 4, "off: nothing searched")
    clickBox(X, true)
    eq(upgrades(X), "+2.5%*", "on: starred until looked up")
    X.advance(3)
    eq(#X.searches, 5, "looked up")
    eq(upgrades(X) .. " " .. X.shownRows()[1].cells.price.text, "+9.0% coin:500", "the new auction")

    -- a new search whose results cannot be read: nothing stale listed, no lookups until a read succeeds
    local AH = X.G.C_AuctionHouse
    local getBrowse = AH.GetBrowseResults
    AH.GetBrowseResults = function() error("not now") end
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    X.advance(3)
    eq(X.rowNames(), "", "empty, not the old rows or their browse price")
    eq(#X.searches, 5, "nothing searched")
    eq(X.updaters(), 0, "idle")
    AH.GetBrowseResults = getBrowse
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    X.advance(3)
    eq(#X.searches, 6, "looked up once the results are read")
    eq(upgrades(X), "+9.0%", "exact again")
    X.closeAH()
    clean(X)
end)

test("Scan specific items checkbox is greyed with the reason when the search functions are missing", function()
    local X = exactSession({ noSearchAPI = true })
    local box = exactBox(X)
    eq(tostring(box.disabled) .. " " .. box.label.color[1], "true 0.5", "disabled and greyed")
    box.scripts.OnEnter(box)
    ok(X.G.GameTooltip.lines[2]:find("Not available this session: SendSearchQuery missing.", 1, true), "reason in the tooltip")
    X.closeAH()
    clean(X)
end)

test("exact: the last query allowed in flight is not stopped; a cap of 0 is; toggling keeps the cap", function()
    local X = exactSession({ slash = "maxqueries 1", noReply = { ["501:" .. HEALING] = true }, wait = 2 })
    eq(#X.searches .. " " .. tostring(X.ns.queue.inflight ~= nil), "1 true", "the only query allowed, in flight")
    eq(progressLine(X), "Checking random-stat items: 0/3 checked", "in flight at the cap: still checking")
    X.advance(5)
    eq(progressLine(X), "Lookup limit 1 reached: 0/3 checked, 1 failed", "timed out: stopped at the cap")
    -- off and on again in the same search: no fresh allowance
    clickBox(X, false)
    clickBox(X, true)
    X.advance(3)
    eq(#X.searches, 1, "nothing more sent")
    eq(progressLine(X), "Lookup limit 1 reached: 0/3 checked, 1 failed", "still stopped, the failure kept")
    X.closeAH()
    clean(X)

    local Z = exactSession({ slash = "maxqueries 0" })
    eq(#Z.searches, 0, "cap 0: nothing sent")
    eq(progressLine(Z), "Lookup limit 0 reached: 0/3 checked", "cap 0 shown as stopped")
    eq(Z.updaters(), 0, "idle")
    Z.closeAH()
    clean(Z)
end)

-- As seen in the game: a shield's random suffix group with a negative base score was an upgrade once its
-- auctions were read. Hidden under "Upgrades only" meanwhile, it is still looked up.
test("exact: a group whose base score is not an upgrade is looked up and confirmed", function()
    local S1 = "|cnIQ2:|Hitem:801::::::::15:1486:::1:12750::::::|h[Kite Shield of Healing]|h|r"
    local X = exactSession({ throttle = false, wait = 3,
        items = { [801] = { name = "Kite Shield", quality = 2, equipLoc = "INVTYPE_SHIELD", cached = true } },
        sgj = { [801] = -1.5, [S1] = 4 }, auctions = { ["801:" .. HEALING] = { { link = S1, buyout = 1000 } } },
        results = { result(801, 1000, HEALING) } })
    eq(X.rowNames(), "", "base score not an upgrade: hidden")
    eq(countLine(X), "1 gear item \194\183 0 confirmed upgrades \194\183 0 pending", "no estimate either")
    eq(progressLine(X), "Checking random-stat items: 0/1 checked", "but queued")
    X.throttleReady = true
    X.fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    X.advance(2)
    eq(X.rowNames() .. " " .. upgrades(X), "Kite Shield of Healing +4.0%", "its auction: an upgrade")
    eq(countLine(X), "1 gear item \194\183 1 confirmed upgrade \194\183 0 pending", "confirmed")
    eq(progressLine(X), "Lookups complete: 1/1 checked", "complete")
    X.closeAH()
    clean(X)
end)

test("exact off: no searches, base scores starred", function()
    local X = exactSession({ slash = "exact off" })
    eq(#X.searches, 0, "nothing sent")
    eq(upgrades(X), "+2.5%*,+3.0%,+2.5%*,+2.5%*", "starred")
    eq(countLine(X), "5 gear items · 1 confirmed upgrade · 3 estimated · 0 pending", "starred groups are estimates")
    eq(progressLine(X), "", "no lookup progress while off")
    local b = X.shownRows()[1]
    b.scripts.OnEnter(b)
    eq(X.G.GameTooltip.lines[1], "AuctionJudge: * base item score. Scan specific items is off", "tooltip note")
    b.scripts.OnClick(b, "LeftButton")
    eq(X.searched, "Cadet Vest of Healing", "group row: search by its full name")
    X.slash("exact on")
    X.advance(4)
    eq(#X.searches, 3, "on again: searched")
    X.closeAH()
    clean(X)
end)
---------------------------------------------------------------------------
-- Session without Sharpie's Gear Judge
---------------------------------------------------------------------------

local N = Client({ items = items })

test("without SGJ: the panel says so and lists nothing", function()
    N.load()
    N.G.AuctionJudgeDB = { shown = true, upgradesOnly = false, sortColumn = "bogus" }
    N.fire("ADDON_LOADED", "AuctionJudge")
    eq(N.G.AuctionJudgeDB.sortColumn, "value", "bad saved sort repaired")
    eq(N.G.AuctionJudgeDB.upgradesOnly, false, "saved option kept")
    N.openAH()
    N.results = { result(101, 50000), result(102, 20000, 1200) }
    N.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    N.advance(1)
    ok(N.hasText("^Sharpie's Gear Judge is not loaded"), "message")
    eq(#N.shownRows(), 0, "no rows")
    ok(N.hasText("^AuctionJudge$"), "title without a spec")
    local n = #N.printed
    N.slash("status")
    ok(N.printedSince(n, "Sharpie's Gear Judge: not loaded"), "status says so")
    N.slash("debug")
    N.closeAH()
    eq(N.updaters(), 0, "nothing to work on without SGJ: work loop stopped")
    eq(#N.forbidden, 0, "forbidden auction house calls")
    local errs = N.errors()
    eq(#errs, 0, "errors: " .. table.concat(errs, " / "))
    local names = {}
    for k in pairs(N.missing) do names[#names + 1] = k end
    eq(#names, 0, "undefined globals read: " .. table.concat(names, ", "))
end)

---------------------------------------------------------------------------
-- Search history (AuctionJudgeDB.history) and which search the dump keeps
---------------------------------------------------------------------------

test("history: one summary per search; empty visits add none; the dump keeps the last search with results", function()
    local X = exactSession({})
    local db = X.G.AuctionJudgeDB
    eq(#db.history, 0, "nothing saved while the search runs")
    local n = #X.printed
    X.slash("history")
    ok(X.printedSince(n, "now: 2026%-11%-15 12:00:00 %(Retribution: Raid%) search; 5 results, 5 rows; lookups: 3 sent, "
        .. "groups 3/3 done; .*; scan complete$"), "the running search")

    -- replaced by a search whose results cannot be read, then by one closed before it is read
    local AH = X.G.C_AuctionHouse
    local getBrowse = AH.GetBrowseResults
    AH.GetBrowseResults = function() error("not now") end
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    X.advance(1)
    AH.GetBrowseResults = getBrowse
    X.results = { result(601, 30000) }
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    X.closeAH()
    local h = db.history
    eq(#h, 3, "three searches")
    local a, b, c = h[1], h[2], h[3]
    eq(table.concat({ a.start, a.ended, a.stop, a.raw, a.rows, a.lookups, a.failures, a.groups, a.groupsDone, a.spec }, " "),
        "search replaced complete 5 5 3 0 3 3 Retribution: Raid", "the first search")
    eq(b.stop .. " " .. b.reads .. " " .. tostring(b.readError:find("not now", 1, true) ~= nil), "read failed 0 true",
        "the unreadable one")
    eq(c.stop .. " " .. c.ended .. " " .. tostring(c.readPending), "unread closed nil", "closed before its read")
    local d = db.lastDump
    eq(d.why .. " " .. d.writeReason .. " " .. d.rawCount .. " " .. d.search.stop, "replaced closed 5 complete",
        "the dump: the first search, the last with results")
    eq(tostring(d.lastReadError) .. " " .. d.exact.sent, "nil 3", "its own read error (none) and lookups, not later ones")

    -- an empty visit: no search, the dump stays
    X.results = {}
    X.openAH()
    X.advance(1)
    X.closeAH()
    eq(#db.history, 3, "an empty visit records nothing")
    ok(db.lastDump == d, "and keeps the dump")

    -- results there on opening; more added, not read; logout then close: recorded once
    X.results = { result(601, 30000) }
    X.openAH()
    X.advance(1)
    X.results[2] = result(501, 50000, WHALE)
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    X.fire("PLAYER_LOGOUT")
    X.closeAH()
    eq(#db.history, 4, "logout and close: one summary")
    local e = db.history[4]
    eq(table.concat({ e.start, e.ended, tostring(e.readPending), e.raw, e.stop }, " "),
        "open logout true 1 nothing to look up", "read, then more results not read")

    -- more results with no search seen, closed before they are read
    X.results = {}
    X.openAH()
    X.advance(1)
    X.results = { result(601, 30000) }
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    X.closeAH()
    e = db.history[5]
    eq(e.start .. " " .. e.stop .. " " .. tostring(e.readPending), "added unread nil", "a search whose start was not seen")

    n = #X.printed
    X.slash("history")
    eq(X.printed[n + 1], "|cff33ccffAuctionJudge|r: Searches: 5 recorded (the latest 20 are kept), newest first", "header")
    ok(X.printed[n + 2]:find("search %(start not seen%); results not read; lookups: 0 sent; scan unread; closed$"),
        "newest first: " .. X.printed[n + 2])
    ok(X.printed[n + 3]:find("results there on opening; 1 result, 1 row; .*more results not read yet; logout$"),
        "singular counts: " .. X.printed[n + 3])
    clean(X)
end)

test("history: lookups cut by the cap, or left queued and in flight when replaced; the dump keeps their state", function()
    local X = exactSession({ slash = "maxqueries 1", wait = 1.6 })
    local n = #X.printed
    X.slash("history")
    ok(X.printedSince(n, "now: .*scan incomplete, 2 queued, one in flight"), "the last allowed lookup in flight: not the cap")
    X.advance(1)
    X.results = { result(601, 30000) }
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    X.closeAH()
    local e = X.G.AuctionJudgeDB.history[1]
    eq(e.stop .. " " .. e.lookups .. " " .. e.queued .. " " .. e.groupsResolved, "cap 1 2 1", "stopped by the cap")
    clean(X)

    X = exactSession({ wait = 1.6 }) -- the first lookup in flight
    X.results = { result(601, 30000) }
    X.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    X.closeAH()
    e = X.G.AuctionJudgeDB.history[1]
    eq(e.stop .. " " .. e.ended .. " " .. e.queued .. " " .. tostring(e.inflight), "incomplete replaced 2 true", "summary")
    local g = X.G.AuctionJudgeDB.lastDump.groups
    eq(g[1].query .. " " .. g[2].query .. " " .. g[3].query, "sent queued queued", "the dump: lookup states before the cancel")
    clean(X)
end)

test("history: an old saved DB keeps its dump and gets no made-up history; the list keeps the latest 20", function()
    local Y = Client({ items = { [601] = { name = "Iron Helm", quality = 2, equipLoc = "INVTYPE_HEAD", cached = true } },
        sgj = { [601] = 3 } })
    Y.load()
    local old = { why = "closed", rows = {} }
    Y.G.AuctionJudgeDB = { exact = false, lastDump = old }
    Y.fire("ADDON_LOADED", "AuctionJudge")
    local db = Y.G.AuctionJudgeDB
    eq(#db.history, 0, "no history built from the old dump")
    ok(db.lastDump == old, "old dump kept")
    Y.openAH()
    for i = 1, 22 do
        Y.results = {}
        for j = 1, i do Y.results[j] = result(601, 1000 * j) end
        Y.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        Y.advance(0.3)
    end
    Y.closeAH()
    eq(#db.history .. " " .. db.history[1].raw .. " " .. db.history[20].raw, "20 3 22", "the oldest two dropped")
    db.history[21] = "junk"
    table.insert(db.history, 1, 7)
    Y.fire("ADDON_LOADED", "AuctionJudge") -- as after a reload
    eq(#db.history .. " " .. db.history[1].raw, "20 3", "damaged entries dropped, saved summaries kept")
    eq(#Y.errors(), 0, "errors: " .. table.concat(Y.errors(), " / "))
end)

---------------------------------------------------------------------------
-- Required levels: items above the player's level stay listed (Hide unusable on) with a "Requires 15"
-- label beside the name; an auction's own link decides its level; delayed levels and level-ups redraw.
---------------------------------------------------------------------------

local function vestLink(bonus)
    return "|cnIQ2:|Hitem:803::::::::15:1486:::1:" .. bonus .. "::::::|h[Initiate Vest of Healing]|h|r"
end
local V1, V2, V3 = vestLink(13001), vestLink(13002), vestLink(13003)
local LONG = "Zealot Helm of the Extraordinarily Long Name"

local function levelSession()
    local list = {
        [801] = { name = LONG, equipLoc = "INVTYPE_HEAD", cached = true, minLevel = 15 },
        [802] = { name = "Squire Boots", equipLoc = "INVTYPE_FEET", cached = true, minLevel = 10 },
        -- the group's base item says 14; its auctions' links say 15, unreadable, and 11
        [803] = { name = "Initiate Vest", equipLoc = "INVTYPE_CHEST", cached = true, minLevel = 14,
            linkLevels = { [V1] = 15, [V2] = "secret", [V3] = 11 } },
        [804] = { name = "Late Gloves", equipLoc = "INVTYPE_HANDS", cached = true, minLevel = "secret" },
        [805] = { name = "Keyed Belt", equipLoc = "INVTYPE_WAIST", cached = true, minLevel = 10 },
    }
    local L = Client({ items = list, sgj = { [801] = 5, [802] = 4, [803] = 3, [804] = 2, [805] = 1 },
        auctions = { ["803:" .. HEALING] = { { link = V1, buyout = 1000 }, { link = V2, buyout = 1100 },
            { link = V3, buyout = 1200 } } },
        keyLevels = { ["805:60:0"] = 13, ["805:63:0"] = 16 } })
    L.playerLevel = 12
    L.load()
    L.fire("ADDON_LOADED", "AuctionJudge")
    L.openAH()
    L.results = { result(801, 10000), result(802, 10000), result(803, 10000, HEALING), result(804, 10000),
        result(805, 10000) }
    L.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    L.advance(4)
    return L, list
end

local function rowBy(L, pred)
    for _, b in ipairs(L.shownRows()) do if pred(b.row) then return b end end
end
local function byLink(link) return function(r) return r.link == link end end
local function byItem(id) return function(r) return r.itemID == id and not r.isAuction end end
local function label(b) return b.level.shown and b.level.text or "-" end

test("level: rows above the player's level are listed with Hide unusable and labelled beside the name", function()
    local L = levelSession()
    local db = L.G.AuctionJudgeDB
    ok(db.hideUnusable and db.upgradesOnly, "Hide unusable and Upgrades only on")
    eq(#L.shownRows(), 7, "every row listed: four fixed items, three auctions")
    local helm = rowBy(L, byItem(801))
    eq(label(helm), "Requires 15", "label")
    eq(helm.cells.name.text, LONG, "the name unchanged")
    eq(helm.cells.name.width .. " " .. helm.level.width, "110 62", "the name gives way, the label keeps its width")
    eq(helm.level.color[1] .. "," .. helm.level.color[2], "1,0.35", "red")
    local boots = rowBy(L, byItem(802))
    eq(label(boots) .. " " .. boots.cells.name.width, "- 176", "at or below the player's level: no label, full name")
    -- the auctions of a random suffix group, each by its own link: 15, unreadable (no label, not the group's
    -- 14), and 11 (below the group's)
    eq(label(rowBy(L, byLink(V1))) .. "|" .. label(rowBy(L, byLink(V2))) .. "|" .. label(rowBy(L, byLink(V3))),
        "Requires 15|-|-", "auction rows")
    eq(label(rowBy(L, byItem(805))), "Requires 13", "the item key's level wins over the item info's")
    -- clicks keep the plain name and the item link
    L.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED") -- nothing new; just checks clicks after a re-read
    L.advance(0.5)
    helm = rowBy(L, byItem(801))
    helm.scripts.OnClick(helm, "LeftButton")
    eq(L.searched, LONG, "search by the name")
    L.chatOpen, L.shift = true, true
    helm.scripts.OnClick(helm, "LeftButton")
    eq(L.inserted, helm.row.link, "shift-click inserts the item link")
    L.chatOpen, L.shift = false, false
    -- the player's level is read once per redraw, scrolling included
    local n = L.calls.UnitLevel
    local p = L.panel()
    p.scripts.OnMouseWheel(p, -1)
    eq(L.calls.UnitLevel - n, 1, "one read for a redraw of seven rows")
    clean(L)
end)

test("level: delayed and unreadable levels, a cheaper variant, and a level-up while idle", function()
    local L, list = levelSession()
    local gloves = rowBy(L, byItem(804))
    eq(gloves.row.state .. " " .. label(gloves), "scored -", "unreadable level: scored, no label")
    -- the level becomes readable: the next item data event labels the row without judging it again
    local scored = L.calls.ScoreItem
    list[804].minLevel = 15
    L.fire("GET_ITEM_INFO_RECEIVED", 804, true)
    L.advance(0.3)
    eq(label(rowBy(L, byItem(804))), "Requires 15", "delayed level shown")
    eq(L.calls.ScoreItem, scored, "not judged again")
    -- Key data arrives after the boots have been scored from base item info (level 10).
    local keyLevel, original = 16, L.G.C_AuctionHouse.GetItemKeyRequiredLevel
    L.G.C_AuctionHouse.GetItemKeyRequiredLevel = function(key)
        if key.itemID == 802 then return keyLevel end
        return original(key)
    end
    L.fire("EXTRA_BROWSE_INFO_RECEIVED", 802)
    L.advance(0.3)
    eq(label(rowBy(L, byItem(802))), "Requires 16", "the browse key supersedes the base item")
    keyLevel = 0
    L.fire("EXTRA_BROWSE_INFO_RECEIVED", 802)
    L.advance(0.3)
    eq(label(rowBy(L, byItem(802))), "-", "the key explicitly reports no requirement")
    eq(rowBy(L, byItem(802)).row.minLevel, 0, "known zero is distinct from missing key data")
    eq(L.calls.ScoreItem, scored, "key updates do not rescore the item")
    -- an auction link whose level stays unreadable is not read forever
    for _ = 1, 6 do L.fire("GET_ITEM_INFO_RECEIVED", 803, true) end
    local v2 = rowBy(L, byLink(V2)).row
    eq(v2.levelMisses .. " " .. tostring(v2.minLevel), L.ns.Model.MAX_LEVEL_MISSES .. " nil", "capped, still unknown")
    -- a cheaper item level variant of the belt takes its row: the item key's level for that variant
    L.results[#L.results + 1] = result(805, 5000, 0, 63)
    L.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    L.advance(2)
    eq(label(rowBy(L, byItem(805))), "Requires 16", "the shown variant's level")
    -- level-up with the panel idle; UnitLevel still gives 12 during the event
    L.advance(2)
    eq(L.updaters(), 0, "idle")
    L.fire("PLAYER_LEVEL_UP", 15)
    L.advance(0.3)
    eq(label(rowBy(L, byItem(801))) .. "|" .. label(rowBy(L, byLink(V1))) .. "|" .. label(rowBy(L, byItem(805))),
        "-|-|Requires 16", "redrawn at the new level")
    -- and SGJ's SCORES_CHANGED (which follows a level-up) redraws at the level UnitLevel gives then
    L.playerLevel = 16
    for _, fn in ipairs(L.sgjCallbacks) do fn() end
    L.advance(1)
    eq(label(rowBy(L, byItem(805))), "-", "no labels left")
    L.closeAH()
    local d = L.G.AuctionJudgeDB.lastDump
    local src = {}
    for _, r in ipairs(d.rows) do src[r.link] = tostring(r.minLevel) .. " " .. tostring(r.minLevelSource) end
    eq(src[V1] .. "|" .. src[V2], "15 link|nil nil", "levels and their sources in the dump")
    clean(L)
end)

return H
