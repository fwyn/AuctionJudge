-- The side panel on the right edge of the auction house. Created on the first AUCTION_HOUSE_SHOW, as a
-- child of AuctionHouseFrame (so it shows, hides and stacks with it); AuctionHouseFrame itself is not
-- changed. Row frames are made once and reused.
local ADDON, ns = ...

local M, Game = ns.Model, ns.Game

local Panel = {}
ns.Panel = Panel

local WIDTH, ROWS, ROW_H = 420, 20, 20
local TOP_ROWS = -96 -- y of the first row below the panel's top edge

-- Column x positions inside a row (rows start 8 px from the panel's left edge).
local COLS = {
    { id = "name", x = 0, w = 196, justify = "LEFT" },
    { id = "price", x = 198, w = 86, justify = "RIGHT" },
    { id = "upgrade", x = 288, w = 56, justify = "RIGHT" },
    { id = "value", x = 346, w = 58, justify = "RIGHT" },
}

local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local frame, toggle, title, countLine, emptyText, footer
local headers, rows, checks = {}, {}, {}
local offset, lastView = 0, nil

local function color(fs, key)
    local c = M.COLOR[key] or M.COLOR.normal
    fs:SetTextColor(c[1], c[2], c[3])
end

local function text(parent, template, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", template)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function makeHeader(col)
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(col.w, 18)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", 8 + col.x, TOP_ROWS + 20)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.1)
    b.label = text(b, "GameFontNormalSmall", col.justify)
    b.label:SetAllPoints()
    b:SetScript("OnClick", function() ns.SortBy(col.id) end)
    headers[col.id] = b
end

-- tooltip of the "Scan specific items" checkbox; the reason it is off for the session is added below
local EXACT_TIP = "Looks up the individual auctions of items with random stats to judge them exactly. "
    .. "Sends extra auction house searches. When off, such items show their base score marked with *."

local function makeCheck(key, label, x, width, tip)
    local c = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    c:SetSize(22, 22)
    c:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -50)
    local fs = text(c, "GameFontHighlightSmall")
    fs:SetPoint("LEFT", c, "RIGHT", 2, 0)
    fs:SetWidth(width) -- the three fit the panel width side by side
    fs:SetText(label)
    c.label = fs
    c:SetScript("OnClick", function(self) ns.SetOption(key, self:GetChecked() and true or false) end)
    if tip then
        c:SetScript("OnEnter", function(self)
            pcall(function()
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(label, 1, 0.82, 0)
                GameTooltip:AddLine(tip(), 1, 1, 1, true)
                GameTooltip:Show()
            end)
        end)
        c:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
    end
    checks[key] = c
end

local exactDisabledReason
local function exactTip()
    if exactDisabledReason then
        return EXACT_TIP .. " Not available this session: " .. exactDisabledReason .. "."
    end
    return EXACT_TIP
end

local function makeRow(i)
    local b = CreateFrame("Button", nil, frame)
    b:SetHeight(ROW_H)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, TOP_ROWS - (i - 1) * ROW_H)
    b:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
    b:RegisterForClicks("LeftButtonUp")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("LEFT", b, "LEFT", 0, 0)
    b.cells = {}
    for _, col in ipairs(COLS) do
        local fs = text(b, "GameFontHighlightSmall", col.justify)
        if col.id == "name" then
            fs:SetPoint("LEFT", b, "LEFT", col.x + 20, 0)
            fs:SetWidth(col.w - 20)
        else
            fs:SetPoint("LEFT", b, "LEFT", col.x, 0)
            fs:SetWidth(col.w)
        end
        b.cells[col.id] = fs
    end
    b:SetScript("OnEnter", function(self)
        if not self.row then return end
        local link, approximate = self.row.link, self.row.approximate
        pcall(function()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(link)
            if approximate then GameTooltip:AddLine("AuctionJudge: * " .. M.APPROXIMATE_NOTE, 1, 0.5, 0.25) end
            GameTooltip:Show()
        end)
    end)
    b:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
    b:SetScript("OnClick", function(self, button)
        if self.row then ns.RowClicked(self.row, button) end
    end)
    b:Hide()
    rows[i] = b
end

local function create(ah)
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    frame = CreateFrame("Frame", "AuctionJudgePanel", ah, template)
    frame:SetWidth(WIDTH)
    frame:SetPoint("TOPLEFT", ah, "TOPRIGHT", 2, 0)
    frame:SetPoint("BOTTOMLEFT", ah, "BOTTOMRIGHT", 2, 0)
    pcall(function() frame:SetFrameStrata(ah:GetFrameStrata()) end)
    frame:EnableMouse(true)
    frame:EnableMouseWheel(true)
    if frame.SetBackdrop then
        frame:SetBackdrop(BACKDROP)
        frame:SetBackdropColor(0, 0, 0, 0.9)
    else
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.85)
    end

    title = text(frame, "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -10)
    title:SetWidth(WIDTH - 50)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() ns.SetShown(false) end)

    countLine = text(frame, "GameFontHighlightSmall")
    countLine:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -30)
    countLine:SetWidth(WIDTH - 20)

    -- 3 x (22 box + 2 + label) in 404 px: 8 + 24 + 96, 132 + 24 + 96, 256 + 24 + 128 = 408
    makeCheck("upgradesOnly", "Upgrades only", 8, 96)
    makeCheck("hideUnusable", "Hide unusable", 132, 96)
    makeCheck("exact", "Scan specific items", 256, 128, exactTip)

    for _, col in ipairs(COLS) do makeHeader(col) end
    for i = 1, ROWS do makeRow(i) end

    emptyText = text(frame, "GameFontDisableSmall")
    emptyText:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, TOP_ROWS - 4)
    emptyText:SetWidth(WIDTH - 20)

    footer = text(frame, "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
    footer:SetWidth(WIDTH - 20)

    frame:SetScript("OnMouseWheel", function(_, delta) Panel.Scroll(-delta * 3) end)

    -- Reopens the panel after it was closed; shown only while the panel is hidden.
    toggle = CreateFrame("Button", nil, ah, "UIPanelButtonTemplate")
    toggle:SetSize(36, 22)
    toggle:SetPoint("TOPLEFT", ah, "TOPRIGHT", 2, -30)
    toggle:SetText("AJ")
    toggle:SetScript("OnClick", function() ns.SetShown(true) end)
    toggle:Hide()
end

---Creates the panel once AuctionHouseFrame exists. true when the panel is there.
function Panel.Ensure()
    if frame then return true end
    local ah = Game.AuctionFrame()
    if not ah then return false end
    create(ah)
    return true
end

function Panel.Exists() return frame ~= nil end
function Panel.IsShown() return frame ~= nil and frame:IsShown() end

function Panel.SetVisible(show)
    if not frame then return end
    frame:SetShown(show)
    toggle:SetShown(not show)
end

function Panel.ResetScroll() offset = 0 end

function Panel.Scroll(delta)
    offset = offset + delta
    if lastView then Panel.Refresh(lastView) end
end

local function fill(b, row)
    b.row = row
    b.icon:SetTexture(row.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    local q = M.QUALITY_RGB[row.quality or 1] or M.QUALITY_RGB[1]
    local c = b.cells
    c.name:SetText(M.DisplayName(row))
    c.name:SetTextColor(q[1], q[2], q[3])
    c.price:SetText(Game.CoinText(row.price) .. (row.bid and " bid" or ""))
    local up, key = M.FormatUpgrade(row)
    c.upgrade:SetText(up)
    color(c.upgrade, key)
    c.value:SetText(M.FormatValue(row.value, row.price))
    color(c.value, "normal")
    b:Show()
end

---view: { sgj = "ok" | "missing", ready, spec, counts, full, list, opts }
function Panel.Refresh(view)
    if not frame then return end
    lastView = view
    local opts = view.opts
    title:SetText("AuctionJudge" .. (view.spec and (": " .. view.spec) or ""))
    checks.upgradesOnly:SetChecked(opts.upgradesOnly and true or false)
    checks.hideUnusable:SetChecked(opts.hideUnusable and true or false)
    local exact = checks.exact
    exact:SetChecked(opts.exact and true or false)
    exactDisabledReason = view.exactDisabled
    if exactDisabledReason then
        exact:Disable()
        exact.label:SetTextColor(0.5, 0.5, 0.5)
    else
        exact:Enable()
        exact.label:SetTextColor(1, 1, 1)
    end
    for _, col in ipairs(COLS) do
        local label = M.COLUMN_LABEL[col.id]
        if opts.sortColumn == col.id then label = label .. (opts.sortDesc and " v" or " ^") end
        headers[col.id].label:SetText(label)
    end

    local list = view.list
    if view.sgj ~= "ok" then
        countLine:SetText("Sharpie's Gear Judge is not loaded: nothing to judge.")
        list = {}
    elseif not view.ready then
        countLine:SetText("Waiting for Sharpie's Gear Judge to finish loading. " .. M.CountLine(view.counts, view.full, view.exact))
    else
        countLine:SetText(M.CountLine(view.counts, view.full, view.exact))
    end

    local total = #list
    local maxOffset = total - ROWS
    if maxOffset < 0 then maxOffset = 0 end
    if offset > maxOffset then offset = maxOffset end
    if offset < 0 then offset = 0 end
    for i, b in ipairs(rows) do
        local row = list[offset + i]
        if row then
            fill(b, row)
        else
            b.row = nil
            b:Hide()
        end
    end

    if total == 0 and view.sgj == "ok" and view.counts.total > 0 then
        emptyText:SetText(opts.upgradesOnly and "No upgrades in these results (yet)." or "No gear in these results.")
    else
        emptyText:SetText("")
    end
    if total > 0 then
        local last = offset + ROWS
        if last > total then last = total end
        footer:SetText(string.format("%d-%d of %d   Click: search   Shift-click: link", offset + 1, last, total))
    else
        footer:SetText("")
    end
end

Panel.ROWS = ROWS
