-- Every read from the game and from Sharpie's Gear Judge, each behind a small guarded function.
-- A failed or unreadable (secret) value is treated as missing.
local ADDON, ns = ...

local Game = {}
ns.Game = Game

local pcall, type, tostring = pcall, type, tostring

local function isSecret(v)
    local f = issecretvalue
    if not f then return false end
    local ok, secret = pcall(f, v)
    return ok and secret == true
end

---The value, or nil when it is secret.
local function plain(v)
    if v ~= nil and isSecret(v) then return nil end
    return v
end
Game.plain = plain

---------------------------------------------------------------------------
-- Auction house
---------------------------------------------------------------------------

local function num(v)
    v = plain(v)
    if type(v) == "number" then return v end
    return nil
end

---A plain entry, or nil and why it was left out (with the item id and suffix when readable).
local function readEntry(r)
    if type(r) ~= "table" then return nil, "not a table" end
    local key = r.itemKey
    if type(key) ~= "table" then return nil, "no item key" end
    local id, suffix = num(key.itemID), num(key.itemSuffix)
    local pet = num(key.battlePetSpeciesID)
    if pet and pet ~= 0 then return nil, "battle pet", id, suffix end
    if not id then return nil, "item id unreadable", nil, suffix end
    return {
        itemID = id, itemLevel = num(key.itemLevel), itemSuffix = suffix,
        minPrice = num(r.minPrice), totalQuantity = num(r.totalQuantity),
        itemKey = key, -- the game's own table, passed back unchanged to an item search
    }
end

---The current browse results as plain entries, the raw result count, and the results left out (pets,
---unreadable entries: { itemID, itemSuffix, reason }, at most 100); or nil and an error text.
function Game.BrowseResults()
    local AH = C_AuctionHouse
    if type(AH) ~= "table" or type(AH.GetBrowseResults) ~= "function" then
        return nil, "C_AuctionHouse.GetBrowseResults missing"
    end
    local ok, results = pcall(AH.GetBrowseResults)
    if not ok then return nil, tostring(results) end
    local out, n, skipped = {}, 0, {}
    if type(results) ~= "table" or isSecret(results) then return out, 0, skipped end
    local ok2, err = pcall(function()
        n = #results
        for i = 1, n do
            local ok3, e, why, id, suffix = pcall(readEntry, results[i])
            if ok3 and e then
                out[#out + 1] = e
            elseif #skipped < 100 then
                skipped[#skipped + 1] = { itemID = id, itemSuffix = suffix,
                    reason = ok3 and why or ("read failed: " .. tostring(e)) }
            end
        end
    end)
    if not ok2 then return nil, tostring(err) end
    return out, n, skipped
end

---Local date and time text, or nil.
function Game.DateText()
    local f = date
    if type(f) ~= "function" then return nil end
    local ok, text = pcall(f, "%Y-%m-%d %H:%M:%S")
    if ok and type(text) == "string" then return text end
    return nil
end

---true / false, or nil when unknown.
function Game.HasFullBrowseResults()
    local AH = C_AuctionHouse
    if type(AH) ~= "table" or type(AH.HasFullBrowseResults) ~= "function" then return nil end
    local ok, full = pcall(AH.HasFullBrowseResults)
    full = ok and plain(full)
    if type(full) == "boolean" then return full end
    return nil
end

function Game.AuctionFrame()
    local f = AuctionHouseFrame
    if type(f) == "table" then return f end
    return nil
end

---Searches the auction house for a name through the Blizzard search bar. true when it worked.
function Game.Search(name)
    if type(name) ~= "string" or name == "" then return false end
    local ok = pcall(function()
        local bar = AuctionHouseFrame.SearchBar
        bar.SearchBox:SetText(name)
        bar:StartSearch()
    end)
    return ok
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

---The equip location without needing the item cached ("" for non-gear), or nil when unknown (no
---function, a failed call, or a missing, secret or non-string value). Unknown is never "not gear".
function Game.InstantEquipLoc(itemID)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if type(f) ~= "function" then return nil end
    local ok, id, _, _, equipLoc = pcall(f, itemID)
    if not ok or id == nil then return nil end
    equipLoc = plain(equipLoc)
    if type(equipLoc) ~= "string" then return nil end
    return equipLoc
end

---{ name, link, quality, icon, equipLoc } for an item string, or nil while the item is not cached.
---equipLoc is nil when it cannot be read (missing, secret): unknown, not "not gear".
function Game.ItemInfo(itemString)
    local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if type(f) ~= "function" then return nil end
    local ok, name, link, quality, _, _, _, _, _, equipLoc, icon = pcall(f, itemString)
    if not ok then return nil end
    name = plain(name)
    if type(name) ~= "string" or name == "" then return nil end
    link, quality, equipLoc, icon = plain(link), plain(quality), plain(equipLoc), plain(icon)
    return {
        name = name,
        link = type(link) == "string" and link or nil,
        quality = type(quality) == "number" and quality or nil,
        equipLoc = type(equipLoc) == "string" and equipLoc or nil,
        icon = icon,
    }
end

---------------------------------------------------------------------------
-- Item keys and item searches. A browse row is a group of auctions; for a random suffix group the key
-- has no exact link (its stats vary per auction), so exact links come from an item search for the key.
---------------------------------------------------------------------------

local function makeItemKey(itemID, itemLevel, itemSuffix)
    local AH = C_AuctionHouse
    if type(AH) == "table" and type(AH.MakeItemKey) == "function" then
        local ok, key = pcall(AH.MakeItemKey, itemID, itemLevel, itemSuffix)
        if ok and type(key) == "table" then return key end
    end
    return { itemID = itemID, itemLevel = itemLevel or 0, itemSuffix = itemSuffix or 0, battlePetSpeciesID = 0 }
end

---{ name, quality, icon } from C_AuctionHouse.GetItemKeyInfo (the group's suffixed name), or nil until
---the client has it (ITEM_KEY_ITEM_INFO_RECEIVED follows).
function Game.ItemKeyInfo(itemID, itemLevel, itemSuffix)
    local AH = C_AuctionHouse
    if type(AH) ~= "table" or type(AH.GetItemKeyInfo) ~= "function" then return nil end
    local ok, info = pcall(AH.GetItemKeyInfo, makeItemKey(itemID, itemLevel, itemSuffix))
    if not ok or type(info) ~= "table" or isSecret(info) then return nil end
    local ok2, out = pcall(function()
        local name, quality, icon = plain(info.itemName), plain(info.quality), plain(info.iconFileID)
        return {
            name = type(name) == "string" and name ~= "" and name or nil,
            quality = type(quality) == "number" and quality or nil,
            icon = (type(icon) == "number" or type(icon) == "string") and icon or nil,
        }
    end)
    if not ok2 or not out.name then return nil end
    return out
end

Game.SEARCH_FUNCTIONS = { "SendSearchQuery", "GetNumItemSearchResults", "GetItemSearchResultInfo",
    "HasFullItemSearchResults", "IsThrottledMessageSystemReady" }

---Which item search functions exist, and the sort order used: { name = true/false, sort = "Buyout" ... }.
function Game.SearchAPI()
    local AH = C_AuctionHouse
    local out = {}
    for _, name in ipairs(Game.SEARCH_FUNCTIONS) do
        out[name] = type(AH) == "table" and type(AH[name]) == "function"
    end
    local E = type(Enum) == "table" and Enum.AuctionHouseSortOrder
    if type(E) == "table" then
        if E.Buyout ~= nil then out.sort = "Buyout" elseif E.Price ~= nil then out.sort = "Price" end
    end
    return out
end

---true when the auction house accepts a query now (true when the client has no such check).
function Game.ThrottleReady()
    local AH = C_AuctionHouse
    if type(AH) ~= "table" or type(AH.IsThrottledMessageSystemReady) ~= "function" then return true end
    local ok, ready = pcall(AH.IsThrottledMessageSystemReady)
    return ok and plain(ready) == true
end

---Sends an item search for the browse result's own item key, cheapest first. true, or false and why.
function Game.SendSearch(itemKey)
    local AH = C_AuctionHouse
    if type(AH) ~= "table" or type(AH.SendSearchQuery) ~= "function" then return false, "SendSearchQuery missing" end
    if type(itemKey) ~= "table" then return false, "no item key" end
    local sorts = {}
    local E = type(Enum) == "table" and Enum.AuctionHouseSortOrder
    local order = type(E) == "table" and (E.Buyout or E.Price)
    if order ~= nil then sorts[1] = { sortOrder = order, reverseSort = false } end
    local ok, err = pcall(AH.SendSearchQuery, itemKey, sorts, false)
    if not ok then return false, "SendSearchQuery error: " .. tostring(err) end
    return true
end

local function keyField(key, name)
    local v = plain(key[name])
    return type(v) == "number" and v or 0
end

---true when two item keys name the same group (item id, item level, suffix).
function Game.SameKey(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local ok, same = pcall(function()
        return keyField(a, "itemID") == keyField(b, "itemID") and keyField(a, "itemLevel") == keyField(b, "itemLevel")
            and keyField(a, "itemSuffix") == keyField(b, "itemSuffix")
    end)
    return ok and same
end

---The item search results for a key as plain values { link, buyout, bid, quantity } (at most 200), the
---number of results and whether they are complete; or nil and why.
function Game.ItemSearchResults(itemKey)
    local AH = C_AuctionHouse
    if type(AH) ~= "table" or type(AH.GetNumItemSearchResults) ~= "function"
        or type(AH.GetItemSearchResultInfo) ~= "function" then
        return nil, "item search result functions missing"
    end
    local ok, n = pcall(AH.GetNumItemSearchResults, itemKey)
    n = ok and plain(n)
    if type(n) ~= "number" then return nil, "no result count" end
    local out = {}
    for i = 1, math.min(n, 200) do
        local ok2, info = pcall(AH.GetItemSearchResultInfo, itemKey, i)
        if ok2 and type(info) == "table" and not isSecret(info) then
            local ok3, r = pcall(function()
                local link = plain(info.itemLink)
                local buyout, bid, qty = plain(info.buyoutAmount), plain(info.bidAmount), plain(info.quantity)
                return { link = type(link) == "string" and link or nil,
                    buyout = type(buyout) == "number" and buyout or nil, bid = type(bid) == "number" and bid or nil,
                    quantity = type(qty) == "number" and qty or nil }
            end)
            if ok3 and r.link then out[#out + 1] = r end
        end
    end
    local full
    if type(AH.HasFullItemSearchResults) == "function" then
        local ok4, f = pcall(AH.HasFullItemSearchResults, itemKey)
        full = ok4 and plain(f)
    end
    return out, n, full
end

---The key tooltip data from C_TooltipInfo.GetItemKey, or nil.
local function keyTooltipData(itemID, itemLevel, itemSuffix)
    local TI = C_TooltipInfo
    if type(TI) ~= "table" or type(TI.GetItemKey) ~= "function" then return nil end
    local ok, data = pcall(TI.GetItemKey, itemID, itemLevel, itemSuffix)
    if ok and type(data) == "table" and not isSecret(data) then return data end
    return nil
end

local function textLines(data, max)
    local out = {}
    if type(data) ~= "table" or type(data.lines) ~= "table" then return out end
    for i = 1, max do
        local line = data.lines[i]
        if type(line) ~= "table" then break end
        local text = plain(line.leftText)
        out[i] = type(text) == "string" and text or ""
    end
    return out
end

---Up to max left-hand text lines of the key tooltip data (for the diagnostic dump).
function Game.KeyTooltipLines(itemID, itemLevel, itemSuffix, max)
    local ok, lines = pcall(textLines, keyTooltipData(itemID, itemLevel or 0, itemSuffix or 0), max)
    return ok and lines or {}
end

---Up to max left-hand text lines of C_TooltipInfo.GetHyperlink(link) (for the diagnostic dump).
function Game.LinkTooltipLines(link, max)
    local TI = C_TooltipInfo
    if type(TI) ~= "table" or type(TI.GetHyperlink) ~= "function" or type(link) ~= "string" then return {} end
    local ok, lines = pcall(function() return textLines(TI.GetHyperlink(link), max) end)
    return ok and lines or {}
end
---The item's base name (without a random suffix), for searching.
function Game.BaseName(itemID)
    local f = C_Item and C_Item.GetItemNameByID
    if type(f) == "function" then
        local ok, name = pcall(f, itemID)
        name = ok and plain(name)
        if type(name) == "string" and name ~= "" then return name end
    end
    local info = Game.ItemInfo("item:" .. tostring(itemID))
    return info and info.name
end

function Game.RequestItem(itemID)
    local f = C_Item and C_Item.RequestLoadItemDataByID
    if type(f) == "function" then pcall(f, itemID) end
end

---Coin text with the client's coin icons when it has them, else "12g 34s".
function Game.CoinText(copper)
    local M = ns.Model
    local amount = M.DisplayCopper(copper)
    if not amount then return "?" end
    local f = GetCoinTextureString
    if type(f) == "function" then
        local ok, text = pcall(f, amount)
        if ok and type(text) == "string" and not isSecret(text) then return text end
    end
    return M.FormatMoney(amount)
end

---Puts a link into an open chat edit box. true when it went in.
function Game.InsertLink(link)
    if type(link) ~= "string" then return false end
    local util = ChatFrameUtil
    local f = (type(util) == "table" and util.InsertLink) or ChatEdit_InsertLink
    if type(f) ~= "function" then return false end
    local ok, inserted = pcall(f, link)
    return ok and inserted and true or false
end

function Game.ShiftDown()
    local f = IsShiftKeyDown
    if type(f) ~= "function" then return false end
    local ok, down = pcall(f)
    return ok and down and true or false
end

---------------------------------------------------------------------------
-- Sharpie's Gear Judge (public API only)
---------------------------------------------------------------------------

function Game.SGJ()
    local api = SharpiesGearJudgeAPI
    if type(api) == "table" then return api end
    return nil
end

Game.SGJ_FUNCTIONS = { "IsReady", "ScoreItem", "RegisterCallback", "GetSpec", "GetVersion" }

---true when SGJ is loaded and can score.
function Game.SGJUsable()
    local api = Game.SGJ()
    return api ~= nil and type(api.ScoreItem) == "function"
end

function Game.SGJReady()
    local api = Game.SGJ()
    if not api or type(api.IsReady) ~= "function" then return false end
    local ok, ready = pcall(api.IsReady)
    return ok and ready == true
end

---The spec display name SGJ judges for, or nil.
function Game.SpecName()
    local api = Game.SGJ()
    if not api or type(api.GetSpec) ~= "function" then return nil end
    local ok, key, name = pcall(api.GetSpec)
    if not ok then return nil end
    name = name or key
    if type(name) == "string" then return name end
    return nil
end

---API version and addon version text, or nil.
function Game.SGJVersion()
    local api = Game.SGJ()
    if not api or type(api.GetVersion) ~= "function" then return nil end
    local ok, v, text = pcall(api.GetVersion)
    if not ok then return nil end
    return tostring(v) .. ", " .. tostring(text)
end

---ScoreItem(link): the result table, or nil and a reason.
function Game.Score(link)
    local api = Game.SGJ()
    if not api or type(api.ScoreItem) ~= "function" then return nil, "NO_SGJ" end
    local ok, result, reason = pcall(api.ScoreItem, link)
    if not ok then return nil, "ERROR" end
    if type(result) == "table" then return result end
    return nil, type(reason) == "string" and reason or "ERROR"
end

---Registers fn for SCORES_CHANGED. true when SGJ accepted it.
function Game.OnScoresChanged(fn)
    local api = Game.SGJ()
    if not api or type(api.RegisterCallback) ~= "function" then return false end
    local ok, accepted = pcall(api.RegisterCallback, "SCORES_CHANGED", fn)
    return ok and accepted ~= false
end
