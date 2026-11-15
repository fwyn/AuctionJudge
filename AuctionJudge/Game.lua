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
-- Item keys: the real (random suffix) name and link, the way the Blizzard list gets them. No queries.
---------------------------------------------------------------------------

local function makeItemKey(itemID, itemLevel, itemSuffix)
    local AH = C_AuctionHouse
    if type(AH) == "table" and type(AH.MakeItemKey) == "function" then
        local ok, key = pcall(AH.MakeItemKey, itemID, itemLevel, itemSuffix)
        if ok and type(key) == "table" then return key end
    end
    return { itemID = itemID, itemLevel = itemLevel or 0, itemSuffix = itemSuffix or 0, battlePetSpeciesID = 0 }
end

---{ name, quality, icon } from C_AuctionHouse.GetItemKeyInfo, or nil until the client has it
---(ITEM_KEY_ITEM_INFO_RECEIVED follows).
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

---A readable link string for this item id, or nil.
local function checkLink(link, itemID)
    link = plain(link)
    if type(link) ~= "string" then return nil end
    local id = link:match("item:(%-?%d+)")
    if not id or tonumber(id) ~= itemID then return nil end
    return link
end

local scanTip -- false once creating it failed
local function scanTooltip()
    if scanTip == nil then
        local ok, tip = pcall(CreateFrame, "GameTooltip", "AuctionJudgeScanTooltip", nil, "GameTooltipTemplate")
        scanTip = ok and tip or false
    end
    return scanTip or nil
end

---The item key's link and where it came from ("keytooltip", "scantooltip"), or nil.
function Game.KeyLink(itemID, itemLevel, itemSuffix)
    itemLevel, itemSuffix = itemLevel or 0, itemSuffix or 0
    local TI = C_TooltipInfo
    if type(TI) == "table" and type(TI.GetItemKey) == "function" then
        local ok, data = pcall(TI.GetItemKey, itemID, itemLevel, itemSuffix)
        if ok and type(data) == "table" and not isSecret(data) then
            local ok2, link = pcall(function() return checkLink(data.hyperlink, itemID) end)
            if ok2 and link then return link, "keytooltip" end
        end
    end
    local tip = scanTooltip()
    if tip then
        local ok, link = pcall(function()
            tip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
            tip:ClearLines()
            tip:SetItemKey(itemID, itemLevel, itemSuffix)
            local _, l = tip:GetItem()
            tip:Hide()
            return checkLink(l, itemID)
        end)
        if ok and link then return link, "scantooltip" end
    end
    return nil
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
