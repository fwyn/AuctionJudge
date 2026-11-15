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

local function readEntry(r)
    if type(r) ~= "table" then return nil end
    local key = r.itemKey
    if type(key) ~= "table" then return nil end
    local pet = plain(key.battlePetSpeciesID)
    if type(pet) == "number" and pet ~= 0 then return nil end
    local id = plain(key.itemID)
    if type(id) ~= "number" then return nil end
    local price, qty = plain(r.minPrice), plain(r.totalQuantity)
    return {
        itemID = id, itemLevel = plain(key.itemLevel), itemSuffix = plain(key.itemSuffix),
        minPrice = type(price) == "number" and price or nil, totalQuantity = type(qty) == "number" and qty or nil,
    }
end

---The current browse results as plain entries (pets and unreadable entries left out) and the raw result
---count, or nil and an error text.
function Game.BrowseResults()
    local AH = C_AuctionHouse
    if type(AH) ~= "table" or type(AH.GetBrowseResults) ~= "function" then
        return nil, "C_AuctionHouse.GetBrowseResults missing"
    end
    local ok, results = pcall(AH.GetBrowseResults)
    if not ok then return nil, tostring(results) end
    local out, n = {}, 0
    if type(results) ~= "table" or isSecret(results) then return out, 0 end
    local ok2, err = pcall(function()
        n = #results
        for i = 1, n do
            local ok3, e = pcall(readEntry, results[i])
            if ok3 and e then out[#out + 1] = e end
        end
    end)
    if not ok2 then return nil, tostring(err) end
    return out, n
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

---The equip location without needing the item cached ("" for non-gear), or nil when unknown.
function Game.InstantEquipLoc(itemID)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if type(f) ~= "function" then return nil end
    local ok, id, _, _, equipLoc = pcall(f, itemID)
    if not ok or id == nil then return nil end
    equipLoc = plain(equipLoc)
    if equipLoc == nil then return "" end
    if type(equipLoc) ~= "string" then return nil end
    return equipLoc
end

---{ name, link, quality, icon, equipLoc } for an item string, or nil while the item is not cached.
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
        equipLoc = type(equipLoc) == "string" and equipLoc or "",
        icon = icon,
    }
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
