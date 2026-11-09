if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUIChat_StampColumn.lua
--
--  Timestamp Column (opt-in, Chat > Timestamp Column). Stamps leave the
--  message text and are drawn in a column of their own to the left of it,
--  in their own font and size.
--
--  A chat line is ONE FontString, and WoW markup can recolor a run of text
--  but never switch its font, so a stamp inside the line always has the
--  line's font. Hence the column:
--    - Blizzard's formatter is parked (showTimestamps = "none", module root)
--      so no stamp is baked into either surface; the engine attaches each
--      line's server time to OUR SMF entry instead (4th extra arg) and
--      strips any stamp still baked into a plain line.
--    - One label per visible line of our ScrollingMessageFrame, anchored to
--      that line's own FontString and re-bound from the frame's display-
--      refreshed callback (scroll, new line, relayout). Nothing here reads
--      the message: secret lines get their stamp like any other.
--    - The column sits OUTSIDE the text area. Blizzard's invisible frame
--      must lay out exactly what we render or its hyperlink hit-zones drift
--      off our text (engine doctrine), and its line width is the chat
--      frame's -- which is never resized. So the text area stays put and the
--      panel, the input, and the first tab grow left by the column's width
--      (ECHAT.StampGutterWidth, read by ApplyInputPosition and the tabs).
--  Off = no column frames, no labels, the refresh callback costs one nil test.
-------------------------------------------------------------------------------
local _, ns = ...
local EUI = _G.EllesmereUI
if not EUI then return end

local ECHAT = ns.ECHAT
if not ECHAT then return end

local floor, ceil, max = math.floor, math.ceil, math.max

local GAP = 6          -- column to text, UI units
local widths = {}      -- [cf] = column width incl. GAP; absent = no column
local fmtGen = 0       -- bumped when the format changes (labels re-render)
local curFmt           -- resolved format while the column is on
local lastState, lastLook

local function DB() return ECHAT.DB() end

local function BlizzardFormat()
    local ok, f = pcall(function()
        return ChatFrameUtil and ChatFrameUtil.GetTimestampFormat and ChatFrameUtil.GetTimestampFormat()
    end)
    return ok and f or nil
end

-- The format the column draws with, nil = nothing to draw. Under "Use
-- Blizzard Setting" the CVar reads "none" while the column holds it, so the
-- value parked when it took over stands in for Blizzard's choice.
function ECHAT.StampFormat()
    local cfg = DB()
    local fmt = cfg.timestampFormat or "%I:%M "
    if fmt == "__blizzard" then
        fmt = cfg.timestampColumnParked or BlizzardFormat()
    end
    if type(fmt) ~= "string" or fmt == "" or fmt == "none" then return nil end
    return fmt
end

function ECHAT.StampColumnOn()
    return DB().timestampColumn == true and ECHAT.StampFormat() ~= nil
end

-- The combat log keeps Blizzard's renderer (and its own stamps).
local function Eligible(cf)
    return cf ~= _G.COMBATLOG
end

function ECHAT.StampGutterWidth(cf)
    return widths[cf] or 0
end

local function StampFont()
    local key = DB().timestampFont or "__chat"
    local chat = ECHAT.EngineFontProvider and ECHAT.EngineFontProvider() or STANDARD_TEXT_FONT
    if key == "__chat" then return chat end
    if key == "__global" then
        return (EUI.GetFontPath and EUI.GetFontPath("chat")) or STANDARD_TEXT_FONT
    end
    return (EUI.ResolveFontName and EUI.ResolveFontName(key)) or chat
end

local function WindowSize(cf)
    return ECHAT.EngineFontSizeProvider and ECHAT.EngineFontSizeProvider(cf:GetID()) or 12
end

local function StampSize(cf)
    return DB().timestampFontSize or WindowSize(cf)
end

local function Outline()
    return ECHAT.EngineOutlineProvider and ECHAT.EngineOutlineProvider() or ""
end

local function SetLabelFont(fs, font, size, flags)
    fs:SetFont(font, size, flags)
    -- A path that failed to load leaves the string fontless, and SetText on
    -- a fontless string is a hard error.
    if not fs:GetFont() then fs:SetFont(STANDARD_TEXT_FONT, size, flags) end
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.8)
end

local function FormatStamp(t)
    local ok, ts = pcall(date, curFmt, t)
    if not ok or type(ts) ~= "string" then return "" end
    return (ts:gsub("%s+$", ""))
end

-- Widest render of the format in this font: every hour against a spread of
-- minute/second digits, so proportional digits and AM/PM are covered.
-- Settings-change path only.
local SAMPLE_MS = { 0, 8, 48, 58 }
local function MeasureWidth(col)
    local fs = col.scratch
    local w = 0
    for h = 0, 23 do
        for i = 1, #SAMPLE_MS do
            local m = SAMPLE_MS[i]
            fs:SetText(FormatStamp(time({ year = 2026, month = 1, day = 1, hour = h, min = m, sec = m })))
            w = max(w, fs:GetStringWidth() or 0)
        end
    end
    return ceil(w)
end

-------------------------------------------------------------------------------
--  Per-window column
-------------------------------------------------------------------------------
local function EnsureColumn(win)
    local col = win.stampCol
    if col then return col end
    local smf = win.smf
    col = CreateFrame("Frame", nil, smf)
    col:SetClipsChildren(true)
    col:EnableMouse(false)
    col:SetFrameLevel(smf:GetFrameLevel())
    col.labels = {}
    col.scratch = col:CreateFontString(nil, "OVERLAY")
    col.scratch:Hide()
    win.stampCol = col
    return col
end

function ECHAT.StampColumnRefresh(win)
    local col = win.stampCol
    if not (col and col:IsShown()) then return end
    local lines = win.smf.visibleLines
    if type(lines) ~= "table" then return end
    local labels = col.labels
    for i = 1, #lines do
        local line = lines[i]
        local fs = labels[i]
        if not fs then
            fs = col:CreateFontString(nil, "OVERLAY")
            fs:SetWordWrap(false)
            fs:SetJustifyH("LEFT")
            SetLabelFont(fs, col.font, col.size, col.flags)
            fs:SetWidth(col.labelW)
            labels[i] = fs
        end
        local info = line:IsShown() and line.messageInfo
        local extra = info and info.extraData
        local t = extra and extra[4]
        if type(t) == "number" then
            if fs._line ~= line then
                fs:ClearAllPoints()
                fs:SetPoint("TOPLEFT", line, "TOPLEFT", col.offX, col.offY)
                fs._line = line
            end
            if fs._t ~= t or fs._gen ~= fmtGen then
                fs:SetText(FormatStamp(t))
                fs._t, fs._gen = t, fmtGen
            end
            fs:SetTextColor(info.r or 1, info.g or 1, info.b or 1)
            fs:Show()
        else
            fs:Hide()
        end
    end
    for i = #lines + 1, #labels do labels[i]:Hide() end
end

-- (Re)derive one window's column from the current settings. Returns true
-- when its width changed (the panel insets have to follow).
local function LayoutColumn(cf, win, on)
    local before = widths[cf]
    if not (on and Eligible(cf)) then
        widths[cf] = nil
        if win.stampCol then win.stampCol:Hide() end
        return before ~= nil
    end
    local col = EnsureColumn(win)
    col.font, col.size, col.flags = StampFont(), StampSize(cf), Outline()
    SetLabelFont(col.scratch, col.font, col.size, col.flags)
    local labelW = MeasureWidth(col)
    col.labelW = labelW
    -- First rows share a vertical center; line heights follow font sizes.
    col.offX = -(GAP + labelW)
    col.offY = -floor((WindowSize(cf) - col.size) / 2 + 0.5)
    col:ClearAllPoints()
    col:SetPoint("TOPRIGHT", win.smf, "TOPLEFT", -GAP, 0)
    col:SetPoint("BOTTOMRIGHT", win.smf, "BOTTOMLEFT", -GAP, 0)
    col:SetWidth(labelW)
    for _, fs in ipairs(col.labels) do
        SetLabelFont(fs, col.font, col.size, col.flags)
        fs:SetWidth(labelW)
        fs._line = nil
    end
    col:Show()
    widths[cf] = GAP + labelW
    ECHAT.StampColumnRefresh(win)
    return before ~= widths[cf]
end

local function Resolve()
    local cfg = DB()
    local on = ECHAT.StampColumnOn()
    local fmt = on and ECHAT.StampFormat() or nil
    return on, fmt, on and cfg.timestampAll == true
end

-- Engine switch only, before integration renders the login backfill.
function ECHAT.StampColumnSeed()
    local on, fmt, all = Resolve()
    curFmt = fmt
    if ECHAT.EngineSetStampColumn then ECHAT.EngineSetStampColumn(on, all, fmt) end
    lastState = tostring(on) .. "|" .. tostring(all)
end

-- Settings entry point (the module root's ApplyTimestampCVar and the
-- options page). Stamps are attached per line, so only turning the column
-- (or Timestamp All) on or off rebuilds the windows; look changes relayout.
function ECHAT.StampColumnApply()
    local on, fmt, all = Resolve()
    if fmt ~= curFmt then fmtGen = fmtGen + 1 end
    curFmt = fmt
    if ECHAT.EngineSetStampColumn then ECHAT.EngineSetStampColumn(on, all, fmt) end
    local state = tostring(on) .. "|" .. tostring(all)
    local cfg = DB()
    local look = on and table.concat({ tostring(fmt), tostring(cfg.timestampFont),
        tostring(cfg.timestampFontSize), tostring(cfg.font), Outline() }, "|") or "off"
    local rebuild = state ~= lastState
    if look == lastLook and not rebuild then return end
    lastState, lastLook = state, look
    local wins = ns._chatWins
    if wins then
        for cf, win in pairs(wins) do LayoutColumn(cf, win, on) end
    end
    if ECHAT.ApplyInputPosition then ECHAT.ApplyInputPosition() end
    if ECHAT.TabsRefresh then ECHAT.TabsRefresh() end
    if rebuild and ECHAT.EngineQueueRebuildAll then ECHAT.EngineQueueRebuildAll() end
end

-- One window's font was (re)applied: its size drives the default stamp size
-- and the label alignment. Called from EngineApplyFontTo, so new windows
-- (whisper tabs) get their column here too.
function ECHAT.StampColumnRelayout(cf)
    if not curFmt then return end
    local win = ns._chatWins and ns._chatWins[cf]
    if not win then return end
    if LayoutColumn(cf, win, true) and ECHAT.ApplyInputPosition then
        ECHAT.ApplyInputPosition()
    end
end
