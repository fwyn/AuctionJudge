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
        "SetTexCoord", "SetBlendMode", "Show", "Hide", "SetShown", "SetAlpha" },
    FontString = { "SetPoint", "SetAllPoints", "SetWidth", "SetHeight", "SetText", "GetText", "SetTextColor",
        "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetFontObject", "Show", "Hide", "SetShown" },
    GameTooltip = { "SetOwner", "SetHyperlink", "Show", "Hide", "AddLine", "ClearLines" },
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
            SetHyperlink = function(self, link) self.link = link end,
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
    local suffixes = { [1200] = " of the Bear" }
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

    local function getItemInfo(s)
        count("GetItemInfo")
        local id, suffix
        if type(s) == "number" then id, suffix = s, 0 else id, suffix = parse(s) end
        local it = id and items[id]
        if not it or not it.cached then return nil end
        local name = it.name .. (suffix ~= 0 and (suffixes[suffix] or "") or "")
        local istr = suffix ~= 0 and ("item:" .. id .. "::::::" .. suffix) or ("item:" .. id)
        local link = "|cff1eff00|H" .. istr .. "::::::::60:::::|h[" .. name .. "]|h|r"
        return name, link, it.quality or 2, 60, 55, "Armor", "Plate", 1, it.equipLoc, "icon" .. id
    end

    G.issecretvalue = function() return false end
    G.GetTime = function() return C.clock end
    G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        C.printed[#C.printed + 1] = table.concat(parts, " ")
    end
    G.C_Timer = { After = function(d, fn) C.timers[#C.timers + 1] = { at = C.clock + d, fn = fn } end }
    G.CreateFrame = function(kind, _, parent, template) return widget(kind, parent, template) end
    G.UIParent = widget("Frame")
    G.SlashCmdList = {}
    G.BackdropTemplateMixin = {}
    G.GameTooltip = widget("GameTooltip")
    G.IsShiftKeyDown = function() return C.shift == true end
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
            return id, "Armor", "Plate", it.equipLoc, "icon" .. id, 4, 4
        end,
        GetItemNameByID = function(id) local it = items[id]; return it and it.cached and it.name or nil end,
        RequestLoadItemDataByID = function(id) C.requested[id] = (C.requested[id] or 0) + 1 end,
    }
    -- Auction house: the addon may only read.
    C.results, C.full = {}, true
    local function forbidden(name) return function() error("AuctionJudge must not call C_AuctionHouse." .. name) end end
    G.C_AuctionHouse = {
        GetBrowseResults = function()
            count("GetBrowseResults")
            local out = {}
            for i, r in ipairs(C.results) do out[i] = r end
            return out
        end,
        HasFullBrowseResults = function() return C.full end,
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
                local name, _, _, _, _, _, _, _, equipLoc = getItemInfo(link)
                if not name then return nil, "NOT_CACHED" end
                if equipLoc == "" then return nil, "NOT_EQUIPPABLE" end
                local id = parse(link)
                local p = pct[id]
                if p == "NOT_USABLE" then return nil, "NOT_USABLE" end
                if p == nil then return nil, "ERROR" end
                return { upgradePct = p * C.factor, upgrade = p * 5, itemScore = 50, equippedScore = 40, slot = 5,
                    equipped = false, spec = "RET_STANDARD", specName = "Retribution: Raid", itemLink = link }
            end,
        }
    end

    local OPTIONAL = { "^AuctionJudgeDB$", "^AuctionHouseFrame$", "^ChatFrameUtil$", "^SharpiesGearJudgeAPI$" }
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
    C.fire("ADDON_LOADED", "AuctionJudge")
    C.fire("PLAYER_LOGIN")
    local db = G.AuctionJudgeDB
    ok(db, "saved variables")
    eq(db.shown and db.upgradesOnly and db.hideUnusable, true, "defaults on")
    eq(db.sortColumn .. tostring(db.sortDesc), "valuetrue", "default sort % per gold descending")
    eq(#C.sgjCallbacks, 1, "one SCORES_CHANGED callback")
    eq(C.updaters(), 0, "no OnUpdate while the auction house is closed")
    C.advance(1)
    eq(C.calls.ScoreItem, nil, "nothing scored before the auction house opens")
end)

test("auction house opens: panel created on the right edge, no results yet", function()
    C.openAH()
    C.advance(0.3)
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
    eq(C.updaters(), 1, "work loop running")
end)

test("results arrive: gear kept, duplicates priced low, uncached items wait", function()
    C.results = {
        result(101, 50000),            -- 4.2% at 5g: 0.84 %/g
        result(102, 20000, 1200),      -- Bandit's Cloak of the Bear: 1.5% at 2g
        result(103, 400000),           -- uncached: 8% at 40g
        result(104, 15000),            -- uncached: 2% at 1.5g
        result(105, 1000),             -- downgrade
        result(106, 30000),            -- unusable
        result(201, 50),               -- not gear
        result(202, 10000),            -- bag
        result(203, 10000),            -- tabard, uncached: filtered by GetItemInfoInstant
        result(101, 80000),            -- same key, dearer
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
    eq(store.byKey["101:0:60"].price, 50000, "lower price kept")
    eq(store.byKey["102:1200:60"].name, "Bandit's Cloak of the Bear", "suffix resolved through the item string")
    eq(store.byKey["203:0:60"].state, "notgear", "tabard")
    eq(store.byKey["202:0:60"].state, "notgear", "bag")
    eq(store.byKey["201:0:60"].state, "notgear", "cloth")
    eq(store.byKey["103:0:60"].state, "pending", "uncached robe")
    ok(C.requested[103] and C.requested[104], "uncached items requested")
    eq(C.requested[203], nil, "the tabard is never requested")
    eq(C.rowNames(), "Lionheart Helm,Bandit's Cloak of the Bear", "upgrades by % per gold")
    ok(C.hasText("^4 gear items, 2 upgrades, 2 pending$"), "count line")
end)

test("rows show quality colour, coin text, upgrade and value", function()
    local b = C.shownRows()[1]
    eq(b.cells.name.color[1] .. "," .. b.cells.name.color[2], "0.64,0.21", "epic colour")
    eq(b.icon.texture, "icon101", "icon")
    eq(b.cells.price.text, "coin:50000", "coin text")
    eq(b.cells.upgrade.text, "+4.2%", "upgrade")
    eq(b.cells.upgrade.color[2], 1, "green")
    eq(b.cells.value.text, "0.84 %/g", "value")
end)

test("uncached items resolve on GET_ITEM_INFO_RECEIVED and get scored", function()
    items[103].cached, items[104].cached = true, true
    C.fire("GET_ITEM_INFO_RECEIVED", 103, true)
    C.fire("GET_ITEM_INFO_RECEIVED", 104, true)
    C.advance(0.2)
    eq(C.ns.store.byKey["103:0:60"].state, "scored", "robe scored")
    eq(C.rowNames(), "Heavy Boots,Lionheart Helm,Bandit's Cloak of the Bear,Robe of Frost", "by % per gold")
    ok(C.hasText("^6 gear items, 4 upgrades, 0 pending$"), "count line")
end)

local function headerByLabel(label)
    for _, h in ipairs(C.headers()) do if h.label.text:find("^" .. label) then return h end end
end
local function click(w, button) w.scripts.OnClick(w, button or "LeftButton") end

test("sorting by header clicks", function()
    ok(headerByLabel("%% per gold").label.text:find(" v$"), "% per gold marked descending")
    click(headerByLabel("Price"))
    eq(C.rowNames(), "Heavy Boots,Bandit's Cloak of the Bear,Lionheart Helm,Robe of Frost", "price ascending")
    ok(headerByLabel("Price").label.text:find(" %^$"), "price marked ascending")
    click(headerByLabel("Price"))
    eq(C.rowNames(), "Robe of Frost,Lionheart Helm,Bandit's Cloak of the Bear,Heavy Boots", "price descending")
    click(headerByLabel("Upgrade"))
    eq(C.rowNames(), "Robe of Frost,Lionheart Helm,Heavy Boots,Bandit's Cloak of the Bear", "upgrade descending")
    click(headerByLabel("Item"))
    eq(C.rowNames(), "Bandit's Cloak of the Bear,Heavy Boots,Lionheart Helm,Robe of Frost", "name ascending")
    click(headerByLabel("%% per gold"))
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
    local perBatch = {}
    for _ = 1, 8 do
        local n = C.calls.ScoreItem
        C.step()
        perBatch[#perBatch + 1] = C.calls.ScoreItem - n
    end
    for _, n in ipairs(perBatch) do ok(n <= 20, "at most 20 scores per batch: " .. table.concat(perBatch, ",")) end
    C.advance(0.5)
    eq(C.calls.ScoreItem - before, 60, "the 60 new rows scored once each")
    ok(C.hasText("^66 gear items, 64 upgrades, 0 pending %(more results not loaded%)$"), "count line")
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
    C.advance(0.5)
    eq(C.calls.ScoreItem, before, "no new scoring")
end)

test("row tooltip, search click, shift-click link", function()
    local b = C.shownRows()[1]
    b.scripts.OnEnter(b)
    ok(G.GameTooltip.owner == b and G.GameTooltip.link == C.ns.store.byKey["104:0:60"].link, "tooltip shows the link")
    b.scripts.OnLeave(b)

    -- The cloak: searched by its base name.
    local cloak
    for _, r in ipairs(C.shownRows()) do if r.cells.name.text == "Bandit's Cloak of the Bear" then cloak = r end end
    click(cloak)
    eq(C.searched, "Bandit's Cloak", "search by base name")

    C.shift = true
    C.chatOpen = true
    click(b)
    eq(C.inserted, C.ns.store.byKey["104:0:60"].link, "link inserted into chat")
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
    C.advance(0.1)
    local pending
    for _, t in ipairs(C.texts()) do pending = pending or tonumber(t:match("^%d+ gear items, %d+ upgrades, (%d+) pending")) end
    ok(pending and pending > 0, "pending while rescoring: " .. tostring(pending))
    C.advance(1)
    eq(C.calls.ScoreItem - before, 66, "every gear row scored again")
    local b = C.shownRows()[1]
    eq(b.cells.name.text, "Heavy Boots", "still first")
    eq(b.cells.upgrade.text, "+4.0%", "new score")
    eq(b.cells.value.text, "2.67 %/g", "new value")
end)

test("SGJ not ready: rows wait, then score", function()
    C.ready = false
    for _, fn in ipairs(C.sgjCallbacks) do fn() end
    C.advance(0.5)
    ok(C.hasText("^Waiting for Sharpie's Gear Judge"), "waiting line")
    eq(C.ns.store.byKey["101:0:60"].state, "pending", "pending")
    C.ready = true
    for _, fn in ipairs(C.sgjCallbacks) do fn() end
    C.advance(1)
    eq(C.ns.store.byKey["101:0:60"].state, "scored", "scored once ready")
end)

test("slash commands", function()
    local n = #C.printed
    C.slash("status")
    ok(C.printedSince(n, "Sharpie's Gear Judge: loaded, ready yes, version 1, 3.2.7, spec Retribution: Raid"), "SGJ line")
    ok(C.printedSince(n, "SGJ API: IsReady ok, ScoreItem ok, RegisterCallback ok, GetSpec ok, GetVersion ok; "
        .. "SCORES_CHANGED registered yes"), "API line")
    ok(C.printedSince(n, "Auction house: open; last browse results 71 %(all loaded: no%)"), "browse line")
    ok(C.printedSince(n, "Rows: 69 %(gear 66, upgrades 64; scored 65, pending 0 of which resolving 0, unusable 1, "
        .. "error 0, not gear 3%)"), "rows line")
    ok(C.printedSince(n, "sort %% per gold descending"), "panel line")
    n = #C.printed
    C.slash("debug")
    ok(C.printedSince(n, "69 rows"), "debug header")
    ok(C.printedSince(n, "^.*2%. 102:1200:60 .*Bandit's Cloak of the Bear.* scored price 20000 upgrade 3"), "debug row")
    ok(C.printedSince(n, "7%. 201:0:60 item:201 notgear %(EQUIP_LOC%)"), "not gear row with reason")
    local lines = #C.printed - n
    eq(lines, 16, "header and 15 rows")
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
    eq(C.updaters(), 0, "no OnUpdate")
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
    local errs = N.errors()
    eq(#errs, 0, "errors: " .. table.concat(errs, " / "))
    local names = {}
    for k in pairs(N.missing) do names[#names + 1] = k end
    eq(#names, 0, "undefined globals read: " .. table.concat(names, ", "))
end)

return H
