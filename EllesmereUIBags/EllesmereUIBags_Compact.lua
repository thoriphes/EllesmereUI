if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIBags_Compact.lua
--  Compact display (bagDisplayMode = "compact"; bank: bankCompactView): each
--  group's icons stay together and in order, and the next group starts one
--  blank cell after it on the same row, wrapping mid-group at the row end, so
--  every icon stays on the grid's columns. Once any group in the pass is
--  named, every row carries a thin band; a group's name sits in it above the
--  group's first icon.
--  Shared by the bag window (the grid pass feeds its groups to the collector
--  below, then CompactBagsPlace draws them) and the bank (RefreshBank re-places
--  its layout entries with CompactSegmentLayout + CompactPack).
--  At load this file only defines functions, constants and empty work tables:
--  frames and the pack output are made on the first compact pass, so the Grid
--  and List displays never build anything here.
-------------------------------------------------------------------------------
local ns = select(2, ...)
if not (ns and ns.GetSelection) then return end

local EUI = EllesmereUI
local _emptyP = {}
local function BP() return (EUI._bagsDB and EUI._bagsDB.profile) or _emptyP end
local ceil = math.ceil

local SLOT_SIZE, SPACING = ns.SLOT_SIZE, ns.SPACING
local PITCH = SLOT_SIZE + SPACING
-- Band height above the label font size; space a label leaves before the next group
local BAND_PAD, LABEL_PAD = 4, 6
-- Less than this much room (two cells) cannot show a cut-off label readably
local MIN_LABEL_ROOM = 2 * PITCH - SPACING
-- Recent Items' Clear link: its width plus a gap, and the label room it needs
local CLEAR_RESERVE, CLEAR_MIN_ROOM = 40, 80

local SetBagFont = ns.SetBagFont
local GetCatTitleSize = ns.GetCatTitleSize
local GetOrCreateSlot = ns.GetOrCreateSlot
local RenderButton = ns.RenderButton
local GetOrCreatePinOverlay = ns.GetOrCreatePinOverlay
local GetOrCreateAssignOverlay = ns.GetOrCreateAssignOverlay
local ShowRecentClearButton = ns.ShowRecentClearButton
local BuildSlotBuckets = ns.BuildSlotBuckets
local BuildExpansionBuckets = ns.BuildExpansionBuckets

-- Height of a label band for a label font size (default: the bags' Category Title Size)
function ns.CompactBandHeight(size)
    return (size or GetCatTitleSize()) + BAND_PAD
end

-- The bank display ("grid" | "list" | "compact") from the bank profile keys:
-- List View keeps its own switch and wins; bankCompactView adds Compact.
function ns.BankDisplayMode(p)
    if p.bankListView == true then return "list" end
    if p.bankCompactView == true then return "compact" end
    return "grid"
end

-------------------------------------------------------------------------------
--  Packer (pure: no game API, no allocation)
-------------------------------------------------------------------------------
-- Output tables for CompactPack; the caller keeps one and reuses it.
function ns.CompactNewOut()
    return {
        cellX = {}, cellRow = {},                 -- per cell, in group order
        groupX = {}, groupRow = {}, labelRoom = {}, -- per group: first cell (label spot)
        rowTop = {}, rowIconY = {}, rowBand = {}, rowCells = {}, -- per row
    }
end

-- Packs n groups of cells into rows of `columns` cells, in order, on the
-- grid's columns: a group starts one blank cell after the previous one and
-- wraps mid-group; it starts on the next row instead only when no cell fits,
-- or when it would wrap from the row's last cell and its label does not fit
-- there. size[g] = cells of group g (0 = a label with no cells), labelW[g] =
-- its label's text width in px (0 = no label). When any group has a label,
-- every row gets a band of bandH px above its icons, so rows stay evenly
-- spaced. x values are px from the row start, y values child space (negative
-- down) from startY. Fills `out` (see CompactNewOut) and returns cells, rows,
-- bottomY (6 px below the last row, like a grid section end).
function ns.CompactPack(size, labelW, n, columns, bandH, startY, out)
    if n < 1 then return 0, 0, startY end
    local cellX, cellRow = out.cellX, out.cellRow
    local groupX, groupRow, labelRoom = out.groupX, out.groupRow, out.labelRoom
    local rowTop, rowIconY, rowBand, rowCells = out.rowTop, out.rowIconY, out.rowBand, out.rowCells
    if columns < 1 then columns = 1 end
    local rowW = columns * PITCH - SPACING
    local row, col, ci = 1, 0, 0
    local banded = false
    rowCells[1] = 0
    for g = 1, n do
        local s, lw = size[g], labelW[g]
        if lw > 0 then banded = true end
        if col > 0 then
            local nc = col + 1  -- one blank cell after the previous group
            local wrap
            if s > 0 then
                local fit = columns - nc
                local room = fit * PITCH - SPACING
                wrap = fit < 1 or (s > fit and lw > room and room < MIN_LABEL_ROOM)
            else
                wrap = nc * PITCH + lw > rowW
            end
            if wrap then
                row, col = row + 1, 0
                rowCells[row] = 0
            else
                col = nc
            end
        end
        groupX[g], groupRow[g] = col * PITCH, row
        for _ = 1, s do
            if col >= columns then
                row, col = row + 1, 0
                rowCells[row] = 0
            end
            ci = ci + 1
            cellX[ci], cellRow[ci] = col * PITCH, row
            rowCells[row] = rowCells[row] + 1
            col = col + 1
        end
        -- A label with no cells keeps its own width on the row, in whole cells
        if s == 0 and lw > 0 then col = col + ceil((lw + SPACING) / PITCH) end
    end
    -- A label may run to the next group start on its row, or to the row end
    for g = 1, n do
        local nextX = rowW + LABEL_PAD
        if g < n and groupRow[g + 1] == groupRow[g] then nextX = groupX[g + 1] end
        labelRoom[g] = nextX - groupX[g] - LABEL_PAD
    end
    local band = banded and bandH or 0
    local y = startY
    for r = 1, row do
        rowTop[r] = y
        rowBand[r] = banded
        local iconY = y - band
        rowIconY[r] = iconY
        y = (rowCells[r] > 0) and (iconY - PITCH) or iconY
    end
    return ci, row, y - 6
end

-------------------------------------------------------------------------------
--  Bank layout segmentation (pure)
-------------------------------------------------------------------------------
-- Splits a bank layout (header and slot entries as RefreshBank's view builders
-- emit them) into compact groups and compacts it in place: each group keeps
-- one header entry, its label, followed by its slot entries. A group's label
-- joins the names (entry.name, else entry.label) of the headers that open it,
-- outermost first ("Midnight: Armor"). A header with no slots under it is
-- dropped, unless the layout has no slot at all (it then stays as a label-only
-- group); slots before the first header form a group with no label.
-- Fills size[g], labelText[g] (string or false), labelEntry[g] (the kept
-- header entry or false) and returns the group count.
do
    local path = {}
    local function Join(lo, hi)
        local s
        for d = lo, hi do
            local p = path[d]
            if p then s = s and (s .. ": " .. p) or p end
        end
        return s or false
    end

    function ns.CompactSegmentLayout(layout, size, labelText, labelEntry)
        local n, w, total = 0, 0, #layout
        local chainLast, freshMin, curDepth, maxDepth = nil, nil, 0, -1
        for i = 1, total do
            local e = layout[i]
            if e.isHeader then
                local d = e.depth or 0
                path[d] = e.name or e.label
                for k = d + 1, maxDepth do path[k] = nil end
                if d > maxDepth then maxDepth = d end
                if not freshMin or d < freshMin then freshMin = d end
                curDepth, chainLast = d, e
            else
                if chainLast then
                    n = n + 1
                    size[n], labelText[n], labelEntry[n] = 0, Join(freshMin, curDepth), chainLast
                    w = w + 1; layout[w] = chainLast
                    chainLast, freshMin = nil, nil
                elseif n == 0 then
                    n = 1
                    size[1], labelText[1], labelEntry[1] = 0, false, false
                end
                size[n] = size[n] + 1
                w = w + 1; layout[w] = e
            end
        end
        if chainLast and n == 0 then
            n = 1
            size[1], labelText[1], labelEntry[1] = 0, Join(freshMin, curDepth), chainLast
            w = 1; layout[1] = chainLast
        end
        for i = w + 1, total do layout[i] = nil end
        for d = 0, maxDepth do path[d] = nil end
        return n
    end
end

-------------------------------------------------------------------------------
--  Group labels (bags and bank): pooled plain frames
-------------------------------------------------------------------------------
-- A label is a frame the size of its room in the band: one left-aligned line
-- that ends in "..." when cut off. Hovering a cut-off label shows the full
-- name, and the hint when it has one; clicks and item drops pass through to
-- the window.
local function LabelOnEnter(self)
    local tip = self._cut and self._text or nil
    if self._hint then tip = tip and (tip .. "\n" .. self._hint) or self._hint end
    if tip then EUI.ShowWidgetTooltip(self, tip) end
end
local function LabelOnLeave()
    EUI.HideWidgetTooltip()
end

-- A frame that takes mouse motion is still the mouse focus: it drops every
-- click and item drop on it, and takes hover from the frames beneath (the bag
-- window's drop target), unless it passes them on. Those switches are protected
-- (out of combat only): a label made in combat takes no mouse until a later
-- paint out of combat turns them on. Returns whether the label passes clicks on.
local function PassClicks(lf)
    if lf._passClicks or not lf.SetPropagateMouseClicks then return true end
    if InCombatLockdown() then return false end
    lf:SetPropagateMouseClicks(true)
    if lf.SetPropagateMouseMotion then lf:SetPropagateMouseMotion(true) end
    lf._passClicks = true
    return true
end

function ns.CompactLabel(pool, idx, owner)
    local lf = pool[idx]
    if lf then return lf end
    lf = CreateFrame("Frame", nil, owner)
    local fs = lf:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("LEFT", lf, "LEFT", 0, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    fs:SetMaxLines(1)
    fs:SetTextColor(0.7, 0.7, 0.7)
    lf._label = fs
    lf:SetScript("OnEnter", LabelOnEnter)
    lf:SetScript("OnLeave", LabelOnLeave)
    -- After the scripts, which can turn mouse input on: the label never takes
    -- clicks, and CompactShowLabel turns motion on per paint
    lf:SetMouseClickEnabled(false)
    lf:SetMouseMotionEnabled(false)
    PassClicks(lf)
    lf:Hide()
    pool[idx] = lf
    return lf
end

-- Sets the label's font and text and returns the text's full width in px.
function ns.CompactMeasureLabel(lf, text, size)
    local fs = lf._label
    SetBagFont(fs, size)
    fs:SetText(text)
    lf._text = text
    return fs:GetUnboundedStringWidth() or 0
end

-- Places a measured label at (x, y) in parent: room px wide, bandH tall; the
-- text keeps reserveRight px free on the right (Recent Items' Clear link).
function ns.CompactShowLabel(lf, parent, x, y, room, bandH, text, textW, hint, reserveRight)
    -- CompactMeasureLabel set the text this pass; only a caller showing other text re-sets it
    if lf._text ~= text then lf._label:SetText(text); lf._text = text end
    if room < 1 then room = 1 end
    local w = room - (reserveRight or 0)
    if w < 1 then w = 1 end
    if lf:GetParent() ~= parent then lf:SetParent(parent) end
    lf:ClearAllPoints()
    lf:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    lf:SetSize(room, bandH)
    lf._label:SetWidth(w)
    lf._cut = textW > w
    lf._hint = hint or nil
    -- Hover only for a cut-off name or a hint
    lf:SetMouseMotionEnabled((lf._cut or lf._hint ~= nil) and PassClicks(lf))
    lf:Show()
end

function ns.CompactHideLabels(pool, from)
    for i = from, #pool do pool[i]:Hide() end
end

-------------------------------------------------------------------------------
--  Bag window: group collector (fed by the grid pass) and placement
-------------------------------------------------------------------------------
local KIND_ITEM, KIND_PIN, KIND_ASSIGN = 0, 1, 2
-- Placeholder data for a "+" cell: an empty, non-interactive slot under its overlay
local PLUS_DATA = { bag = 0, slot = 0 }

-- One pass's groups and cells, reused across passes (entries past the counts are stale)
local gN, cN = 0, 0
local gLabel, gHint, gInter, gClear, gSize, gW, gLi = {}, {}, {}, {}, {}, {}, {}
local cData, cKind, cKey = {}, {}, {}
local bagLabels = {}
local bagOut

local function AddGroup(label, hint, interactive, clear)
    gN = gN + 1
    gLabel[gN] = (label and label ~= "") and label or false
    gHint[gN] = hint or false
    gInter[gN] = interactive and true or false
    gClear[gN] = clear and true or false
    gSize[gN] = 0
end

local function AddCell(data, kind, key)
    cN = cN + 1
    cData[cN], cKind[cN], cKey[cN] = data, kind, key or false
    gSize[gN] = gSize[gN] + 1
end

-- Starts a pass: called by ns.RenderGridView right after its per-pass reset
function ns.CompactBagsBegin()
    gN, cN = 0, 0
end

-- One grid section as compact groups. kind: "flat" | "slot" (armory slot
-- buckets) | "exp" (expansion buckets) | "pinned" | "recent". assignKey: the
-- category key of an assign "+" cell (after the items; after the first
-- bucket when nested). keepEmpty: show the name even with no cells. hint: a
-- flat group's label tooltip line (the single Pinned / Recent views).
-- A nested section becomes one group per bucket; the first is named
-- "<section>: <bucket>", the others by their bucket.
function ns.CompactBagsSection(name, items, kind, assignKey, keepEmpty, hint)
    local count = #items
    if (kind == "slot" or kind == "exp") and count > 0 then
        local buckets = (kind == "slot") and BuildSlotBuckets(items) or BuildExpansionBuckets(items)
        local first = true
        for b = 1, #buckets do
            local bucket = buckets[b]
            local bItems = bucket.items
            if #bItems > 0 then
                AddGroup(first and (name .. ": " .. bucket.label) or bucket.label, false, false, false)
                for j = 1, #bItems do AddCell(bItems[j], KIND_ITEM, false) end
                if first and assignKey then AddCell(PLUS_DATA, KIND_ASSIGN, assignKey) end
                first = false
            end
        end
        if not first then return end
    end
    local pin = kind == "pinned"
    local clear = false
    hint = hint or false
    if pin or kind == "recent" then
        if BP().bagShowPinRecentTips ~= false then
            hint = pin and EllesmereUI.L("(Middle Click to Add or Remove)")
                or EllesmereUI.L("(Extra quickview display, your items are also in their category)")
        end
        local recent = EUI_Bags._recentItems
        clear = not pin and BP().bagShowRecentClear == true and recent ~= nil and next(recent) ~= nil
    end
    if count == 0 and not pin and not assignKey and not keepEmpty then return end
    AddGroup(name, hint, false, clear)
    for j = 1, count do AddCell(items[j], KIND_ITEM, false) end
    if pin then AddCell(PLUS_DATA, KIND_PIN, false) end
    if assignKey then AddCell(PLUS_DATA, KIND_ASSIGN, assignKey) end
end

-- One OneBag / MultiBag / Reagent Bag section: slots in bag order, empty
-- slots included and mouse-enabled (drop targets)
function ns.CompactBagsSlots(label, slots)
    local count = #slots
    if count == 0 then return end
    AddGroup(label, false, true, false)
    for j = 1, count do AddCell(slots[j], KIND_ITEM, false) end
end

-- Packs and draws the pass's groups from startY down; returns the advanced
-- slotIdx and the content bottom (curY)
function ns.CompactBagsPlace(child, startX, startY, columns, slotIdx)
    local n = gN
    local size = GetCatTitleSize()
    local k = 0
    for g = 1, n do
        local text = gLabel[g]
        if text then
            k = k + 1
            gW[g] = ns.CompactMeasureLabel(ns.CompactLabel(bagLabels, k, EUI_Bags), text, size)
            gLi[g] = k
        else
            gW[g], gLi[g] = 0, false
        end
    end
    ns.CompactHideLabels(bagLabels, k + 1)
    if n == 0 then return slotIdx, startY end

    if not bagOut then bagOut = ns.CompactNewOut() end
    local out = bagOut
    local bandH = size + BAND_PAD
    local _, _, bottomY = ns.CompactPack(gSize, gW, n, columns, bandH, startY, out)
    local rowTop, rowIconY = out.rowTop, out.rowIconY

    for g = 1, n do
        local li = gLi[g]
        if li then
            local lf = bagLabels[li]
            local room = out.labelRoom[g]
            local clear = gClear[g] and room >= CLEAR_MIN_ROOM
            ns.CompactShowLabel(lf, child, startX + out.groupX[g], rowTop[out.groupRow[g]], room, bandH,
                gLabel[g], gW[g], gHint[g] or nil, clear and CLEAR_RESERVE or 0)
            if clear then
                ShowRecentClearButton(lf, nil)
                lf._clearBtn:SetHeight(bandH)  -- inside the band, never over the icons below
            elseif lf._clearBtn then
                lf._clearBtn:Hide()
            end
        end
    end

    local cellX, cellRow = out.cellX, out.cellRow
    local ci = 0
    for g = 1, n do
        local interactive = gInter[g]
        for _ = 1, gSize[g] do
            ci = ci + 1
            slotIdx = slotIdx + 1
            -- nil in combat past the pre-warmed pool: the cell stays empty
            -- until PLAYER_REGEN_ENABLED replays the refresh
            local btn = GetOrCreateSlot(slotIdx)
            if btn then
                btn:GetParent():SetParent(child)
                RenderButton(btn, cData[ci], slotIdx, 0, 0, startX + cellX[ci], rowIconY[cellRow[ci]], columns, interactive)
                local kind = cKind[ci]
                if kind ~= KIND_ITEM then
                    local ov
                    if kind == KIND_PIN then
                        ov = GetOrCreatePinOverlay()
                    else
                        ov = GetOrCreateAssignOverlay()
                        ov._assignCatKey = cKey[ci]
                    end
                    ov:SetParent(child)
                    ov:ClearAllPoints()
                    ov:SetAllPoints(btn)
                    ov:Show()
                end
            end
        end
    end
    return slotIdx, bottomY
end
