"""Exercise the shipped Lua module against a visibility-driven aura engine.

Engine button reads and post-initialization writes deliberately fail. Aura
changes only go through the mock engine, never through addon aura events.
"""
from pathlib import Path
import sys
from lupa import lua51

ROOT = Path(__file__).resolve().parents[2]
lua = lua51.LuaRuntime(unpack_returned_tuples=True)
lua.globals().EAGER = '--eager' in sys.argv
lua.execute(r'''
ns = { defaults = {
    debuffColorsEnabled = false, debuffColorsPlayerOnly = true,
    debuffColorSpell1 = "703", debuffColorSpell2 = "1943",
    debuffColorCustomSpell1 = 0, debuffColorCustomSpell2 = 0,
    debuffColor1 = { r=1, g=.43, b=.04 }, debuffColor2 = { r=.8, g=.2, b=.1 },
    debuffColorBothEnabled = true, debuffColorPriority = 2, debuffColorBoth = { r=.1, g=.88, b=.32 },
    healthBarTexture = "custom", }, plates = {}, healthBarTextures = {} }
profile = {}
ns.db = { profile = profile }
function ns.NP_GetProfile() return profile end
EllesmereUI = {
    IS_FOREVER = false,
    ResolveTexturePath = function(_, key) return "test-texture-" .. key end,
}
C_AddOns = { IsAddOnLoaded = function() return true end }
combat = false
function InCombatLockdown() return combat end
function forbidden() error("addon read restricted aura state") end
C_UnitAuras = setmetatable({}, { __index = forbidden })
UnitAura, UnitDebuff, UnitGUID = forbidden, forbidden, forbidden

frames, containers, textures = {}, {}, {}
local states = {} -- engine-private visibility state, unavailable to addon
local unitAuras = {}
local methods = {}
local UpdateEngine
local function Mutable(self)
    assert(not states[self].locked, "write to forbidden AuraButton/texture")
end
function methods:SetFrameLevel(level) Mutable(self); states[self].level = level end
function methods:GetFrameLevel() assert(not states[self].locked); return states[self].level or 10 end
function methods:SetAllPoints(anchor) Mutable(self); states[self].anchor = anchor end
function methods:SetPoint(...) Mutable(self); table.insert(states[self].points, {...}) end
function methods:SetSize(w, h) Mutable(self); states[self].size = { w, h } end
function methods:SetTexCoord(...) Mutable(self); states[self].coords = {...} end
function methods:SetAlpha(alpha) Mutable(self); states[self].alpha = alpha end
function methods:SetShown(shown) Mutable(self); states[self].shown = shown end
function UIState(obj) return states[obj] end
function methods:EnableMouse(value) Mutable(self); states[self].mouse = value end
function methods:SetTexture(value) Mutable(self); states[self].texture = value end
function methods:SetVertexColor(...) Mutable(self); states[self].color = {...} end
function methods:AddMaskTexture(mask) Mutable(self); states[self].mask = mask end
function methods:Hide() Mutable(self); states[self].shown = false end
function methods:Show() Mutable(self); states[self].shown = true end
function methods:IsShown() error("addon inspected engine-owned visibility") end
function methods:GetParent() error("addon inspected engine-owned parent") end
function methods:RegisterEvent(event) states[self].events[event] = true end
function methods:UnregisterEvent(event) states[self].events[event] = nil end
function methods:SetScript(event, callback) states[self].scripts[event] = callback end
function methods:SetEnabled(enabled) states[self].enabled = enabled end
function methods:SetUnit(unit) states[self].unit = unit end
function methods:UpdateAllAuras() end
function methods:GetStatusBarTexture() return states[self].fill end

local function New(kind, parent)
    local obj = setmetatable({}, { __index = methods })
    states[obj] = { kind=kind, parent=parent, shown=true, level=10,
        points={}, scripts={}, events={}, slots={}, regions={} }
    frames[#frames+1] = obj
    return obj
end
function CreateFrame(kind, _, parent, template)
    if kind == "AuraContainer" then
        assert(template == "CustomAuraContainerTemplate")
    end
    local obj = New(kind, parent)
    if kind == "AuraContainer" then containers[#containers+1] = obj end
    return obj
end
function methods:CreateTexture(_, layer, _, sublevel)
    Mutable(self)
    local tex = New("Texture", self)
    states[tex].layer, states[tex].sublevel = layer, sublevel
    table.insert(states[self].regions, tex)
    textures[#textures+1] = tex
    return tex
end
function methods:AddAuraSlot(key, filter, spec)
    assert(states[self].kind == "AuraContainer")
    assert(filter == "HARMFUL|PLAYER" or filter == "HARMFUL")
    assert(spec.candidateFilters.includeSpellIDs)
    local slot = { filter=filter, ids=spec.candidateFilters.includeSpellIDs,
        init=spec.initializeFrame }
    states[self].slots[key] = slot
    if EAGER then
        slot.button = New("AuraButton", self)
        slot.init(slot.button)
        states[slot.button].locked = true
        for _, tex in ipairs(textures) do
            if states[tex].parent == slot.button then states[tex].locked = true end
        end
    end
    -- Slots may be born only after the first matching aura. UpdateEngine below
    -- forces that timing to exercise lazy pair construction and later rebinds.
end

local function Matches(slot, unit)
    for _, aura in ipairs(unitAuras[unit] or {}) do
        if slot.ids[aura.id] and (slot.filter == "HARMFUL" or aura.mine) then return true end
    end
    return false
end
UpdateEngine = function()
    local i = 1
    while i <= #containers do
        local c = containers[i]
        local state = states[c]
        for _, slot in pairs(state.slots) do
            local active = state.enabled and Matches(slot, state.unit)
            if active and not slot.button then
                slot.button = New("AuraButton", c)
                slot.init(slot.button)
                states[slot.button].locked = true
                for _, tex in ipairs(textures) do
                    if states[tex].parent == slot.button then states[tex].locked = true end
                end
            end
            if slot.button then states[slot.button].shown = active end
        end
        i = i + 1
    end
end
function Auras(unit, auras) unitAuras[unit] = auras; UpdateEngine() end
local function Visible(obj)
    local state = states[obj]
    if not state.shown then return false end
    return not state.parent or Visible(state.parent)
end
function Paint(plate)
    UpdateEngine()
    local chosen, priority
    for _, tex in ipairs(textures) do
        local state = states[tex]
        if state.color and Visible(tex) then
            local parent = tex
            while parent and parent ~= plate.health do parent = states[parent].parent end
            if parent and (not priority or state.sublevel > priority) then
                chosen, priority = state, state.sublevel
            end
        end
    end
    return chosen, priority
end
function NewPlate(unit)
    local plate = { health=New("StatusBar"), _absorbMask={} }
    states[plate.health].fill = New("Texture", plate.health)
    states[plate.health].baseColor = { .2, .3, .4 }
    plate.unit = unit
    ns.plates[unit] = plate
    return plate
end
function AssertColor(plate, r, g, b, priority)
    local painted, actual = Paint(plate)
    if r == nil then assert(not painted, "stale debuff tint"); return end
    assert(painted, "missing active tint")
    assert(actual == priority, "wrong simultaneous-debuff priority")
    assert(painted.color[1] == r and painted.color[2] == g and painted.color[3] == b)
    assert(painted.texture == "test-texture-" .. (profile.healthBarTexture or "custom"))
    assert(painted.mask == plate._absorbMask)
    assert(painted.points[1][2] == states[plate.health].fill)
    assert(painted.points[2][2] == states[plate.health].fill)
    assert(states[plate.health].baseColor[1] == .2, "mutated base health color")
end
function RunWorker()
    for _, frame in ipairs(frames) do
        if states[frame].shown and states[frame].scripts.OnUpdate then
            states[frame].scripts.OnUpdate(frame, .2)
        end
    end
end
function Regen()
    combat = false
    for _, frame in ipairs(frames) do
        if states[frame].events.PLAYER_REGEN_ENABLED then states[frame].scripts.OnEvent(frame) end
    end
end
''')
load = lua.eval('function(src) return assert(loadstring(src)) end')

# Exercise the actual shared kit's shell/slot wrappers and bare initializer.
# Standard icon styling is not needed for a presence-only slot.
kit = (ROOT / 'EllesmereUI_AuraKit.lua').read_text()
kit_init = 'function AK.MakeInitializer' + kit.split('function AK.MakeInitializer', 1)[1].split(
    'function AK.CreateStyledCell', 1)[0]
kit_slots = 'function AK.CreateContainerShell' + kit.split('function AK.CreateContainerShell', 1)[1].split(
    '------------------------------------------------------------------------------\n-- Item enchantments', 1)[0]
lua.execute(r'''
EllesmereUI.AuraKit = {styles={}, ApplyContainerLayout=function() end}
function EllesmereUI.AuraKit.Filter(...) return table.concat({...}, "|") end
''')
load(r'''
local AK = ...
local bd, containerData, styleSets = {}, {}, {}
local function ApplyStyleToRegions(button, style)
    assert(style.noRegions, "presence slot allocated standard icon regions")
    button:SetSize(style.width or 32, style.height or style.width or 32)
end
local function GetStyleSet(key)
    styleSets[key] = styleSets[key] or {}
    return styleSets[key]
end
''' + kit_init + kit_slots)(lua.globals().EllesmereUI.AuraKit)
load((ROOT / 'EllesmereUINameplates/EllesmereUINameplates_DebuffColors.lua').read_text())('test', lua.globals().ns)
lua.execute(r'''
assert(#frames == 0 and not ns.DebuffColors_Attach and not ns.DebuffColors_Detach)
ns.DebuffColors_Refresh()
ns.DebuffColors_RequestRefresh()
assert(#frames == 0, "disabled feature built a frame or worker")
local p = NewPlate("nameplate1")
assert(not ns.DebuffColors_Attach)
assert(#containers == 0, "disabled feature created aura containers")
profile.debuffColorsEnabled = true
combat = true
ns.DebuffColors_Refresh()
assert(not ns.DebuffColors_Attach and #containers == 0, "first enable in combat was not deferred")
Regen()
AssertColor(p, nil)

-- Secret combat aura changes: engine visibility must be sufficient on its own.
combat = true
Auras("nameplate1", {{ id=703, mine=true }})
AssertColor(p, 1, .43, .04, 4)
Auras("nameplate1", {{ id=1943, mine=true }})
AssertColor(p, .8, .2, .1, 5)
Auras("nameplate1", {{ id=703, mine=true }, { id=1943, mine=true }})
AssertColor(p, .1, .88, .32, 7)
Auras("nameplate1", {{ id=1943, mine=true }})
AssertColor(p, .8, .2, .1, 5) -- nested Rupture must vanish with its Garrote parent
Auras("nameplate1", {})
AssertColor(p, nil)
Auras("nameplate1", {{ id=703, mine=false }, { id=1943, mine=false }})
AssertColor(p, nil)
local before = #containers
ns.DebuffColors_Detach(p)
ns.plates.nameplate1 = nil
AssertColor(p, nil)
ns.plates.nameplate2 = p
ns.DebuffColors_Attach(p, "nameplate2")
Auras("nameplate2", {{ id=1943, mine=true }})
AssertColor(p, .8, .2, .1, 5)
assert(#containers == before, "plate reuse rebuilt its aura containers")

-- Any-player filter and independent priority, after a settings refresh.
combat = false
profile.debuffColorsPlayerOnly = false
profile.debuffColorBothEnabled = false
ns.DebuffColors_Refresh()
Auras("nameplate2", {{ id=703, mine=false }, { id=1943, mine=false }})
AssertColor(p, .8, .2, .1, 5)
before = #containers
ns.DebuffColors_Refresh()
assert(#containers == before, "unchanged config rebuilt secure decoration")

-- Select either priority, in both cast orders and through expiry/reapplication.
profile.debuffColorPriority = 1
ns.DebuffColors_Refresh()
combat = true
Auras("nameplate2", {{ id=1943, mine=true }})
AssertColor(p, .8, .2, .1, 4)
Auras("nameplate2", {{ id=1943, mine=true }, { id=703, mine=true }})
AssertColor(p, 1, .43, .04, 5)
Auras("nameplate2", {{ id=703, mine=true }})
AssertColor(p, 1, .43, .04, 5)
Auras("nameplate2", {{ id=703, mine=true }, { id=1943, mine=true }})
AssertColor(p, 1, .43, .04, 5)
Auras("nameplate2", {{ id=1943, mine=true }})
AssertColor(p, .8, .2, .1, 4)
Auras("nameplate2", {{ id=1943, mine=true }, { id=703, mine=true }})
AssertColor(p, 1, .43, .04, 5)

-- Priority changes in combat apply after combat; Both Active always wins.
profile.debuffColorPriority = 2
ns.DebuffColors_Refresh()
AssertColor(p, 1, .43, .04, 5)
Regen()
AssertColor(p, .8, .2, .1, 5)
profile.debuffColorBothEnabled, profile.debuffColorPriority = true, 1
ns.DebuffColors_Refresh()
AssertColor(p, .1, .88, .32, 7)
profile.debuffColorBothEnabled, profile.debuffColorPriority = false, 2
ns.DebuffColors_Refresh()
AssertColor(p, .8, .2, .1, 5)

profile.debuffColorSpell1 = "custom"
profile.debuffColorCustomSpell1 = 155722
profile.debuffColorSpell2 = "none"
ns.DebuffColors_Refresh()
Auras("nameplate2", {{ id=703, mine=true }})
AssertColor(p, nil)
Auras("nameplate2", {{ id=155722, mine=true }})
AssertColor(p, 1, .43, .04, 4)

-- Debounce color drags and defer combat profile changes until combat ends.
before = #containers
for i=1,20 do
    profile.debuffColor1 = { r=.5, g=.5, b=i/100 }
    ns.DebuffColors_RequestRefresh()
end
assert(#containers == before)
RunWorker()
AssertColor(p, .5, .5, .2, 4)
assert(#containers == before + 1)
combat = true
profile.debuffColorsEnabled = false
ns.DebuffColors_Refresh()
AssertColor(p, .5, .5, .2, 4)
Regen()
AssertColor(p, nil)
assert(not ns.DebuffColors_Attach and not ns.DebuffColors_Detach)
for _, frame in ipairs(frames) do
    assert(not UIState(frame).events.PLAYER_REGEN_ENABLED, "disabled feature left an event registered")
    assert(not UIState(frame).scripts.OnUpdate, "disabled feature left an update callback armed")
end

-- No choices, empty custom IDs and duplicate choices cannot make a pair tint.
profile.debuffColorsEnabled = true
profile.debuffColorCustomSpell1 = 0
ns.DebuffColors_Refresh()
before = #containers
ns.DebuffColors_Attach(p, "nameplate2")
assert(#containers == before)
profile.debuffColorSpell1, profile.debuffColorSpell2 = "703", "703"
profile.debuffColorBothEnabled = true
ns.DebuffColors_Refresh()
Auras("nameplate2", {{ id=703, mine=true }})
AssertColor(p, .5, .5, .2, 4)

-- Profile swaps refresh active AND pooled rigs, including preserved textures.
local pooled = NewPlate("nameplate3")
ns.DebuffColors_Attach(pooled, "nameplate3")
ns.DebuffColors_Detach(pooled)
ns.plates.nameplate3 = nil
profile = { debuffColorsEnabled=true, debuffColorSpell1="1943", debuffColorSpell2="none",
    debuffColor1={ r=.3, g=.4, b=.5 }, healthBarTexture="other" }
ns.db.profile = profile
ns.DebuffColors_Refresh()
Auras("nameplate2", {{ id=703, mine=true }})
AssertColor(p, nil)
Auras("nameplate2", {{ id=1943, mine=true }})
AssertColor(p, .3, .4, .5, 4)
ns.plates.nameplate4 = pooled
ns.DebuffColors_Attach(pooled, "nameplate4")
Auras("nameplate4", {{ id=1943, mine=true }})
AssertColor(pooled, .3, .4, .5, 4)
ns.DebuffColors_Detach(pooled)
AssertColor(pooled, nil)

-- Old saved UA presets must track the current aura; custom IDs stay exact.
profile.debuffColorSpell1, profile.debuffColorSpell2 = "316099", "1259790"
ns.DebuffColors_Refresh()
Auras("nameplate2", {{ id=316099, mine=true }})
AssertColor(p, nil)
Auras("nameplate2", {{ id=1259790, mine=true }})
AssertColor(p, .3, .4, .5, 4)
assert(profile.debuffColorSpell1 == "316099", "normalization rewrote the saved profile")
profile.debuffColorSpell1, profile.debuffColorSpell2 = "custom", "none"
profile.debuffColorCustomSpell1 = 316099
ns.DebuffColors_Refresh()
Auras("nameplate2", {{ id=1259790, mine=true }})
AssertColor(p, nil)
Auras("nameplate2", {{ id=316099, mine=true }})
AssertColor(p, .3, .4, .5, 4)
profile.debuffColorSpell1, profile.debuffColorCustomSpell1 = "1943", nil

assert(#ns.DebuffColorPresets == 13)
assert(ns.DebuffColorPresetByID[1259790][2] == "Unstable Affliction")
assert(ns.DebuffColorPresetByID[445474][2] == "Wither")
for _, id in ipairs({121411, 2818, 259491, 106830, 335467, 55078, 55095, 191587, 217200, 12654, 316099}) do
    assert(not ns.DebuffColorPresetByID[id], "unwanted or obsolete preset remains")
end
''')
print('PASS: presence/removal, both-active priority, ownership, custom IDs, duplicate/empty selections,')
print('      combat changes, immutable secure regions, pooling, profiles, textures, and coalesced refreshes.')
print('PASS: lazy enable, inactive hooks/events while disabled, and actual AuraKit shell/slot/bare initializer.')

# Execute the actual Colors-page helper and exercise the controls' callbacks.
options = (ROOT / 'EllesmereUIOptions/Nameplates_Options/ColorsPage_Options.lua').read_text()
helper = options.split('-- EUI_DEBUFF_COLORS: uses', 1)[1].split(
    '-- Mini preview bar builder', 1)[0]
lua.execute(r'''
uiRows, uiMessages, uiRefreshers, uiPreviews = {}, {}, {}, {}
uiInlineButtons, uiCogOptions = {}, {}
EllesmereUI.Widgets = {
    SectionHeader=function() return {}, 30 end,
    Spacer=function() return {}, 20 end,
    DualRow=function(_, _, _, left, right)
        local row = CreateFrame("Frame")
        row._leftRegion = CreateFrame("Frame", nil, row)
        row._rightRegion = CreateFrame("Frame", nil, row)
        row._leftRegion._control = CreateFrame("Button", nil, row._leftRegion)
        row._leftRegion._control._invalidateMenu = function()
            row.invalidations = (row.invalidations or 0) + 1
        end
        row._leftRegion._control._refreshLabel = function()
            row.label = left.getValue and left.getValue()
        end
        uiRows[#uiRows+1] = {left, right, frame=row}
        return row, 40
    end,
}
EllesmereUI.PanelPP = {
    Size=function(frame, w, h) frame:SetSize(w, h) end,
    Point=function(frame, ...) frame:SetPoint(...) end,
    CreateBorder=function() end,
}
function EllesmereUI.RegisterWidgetRefresh(fn) uiRefreshers[#uiRefreshers+1] = fn end
function EllesmereUI:RefreshPage() for _, fn in ipairs(uiRefreshers) do fn() end end
function EllesmereUI:ShowInputPopup(opts) uiPopup = opts end
function EllesmereUI.ShowWidgetTooltip(_, text) uiTooltip = text end
function EllesmereUI.HideWidgetTooltip() uiTooltip = nil end
function EllesmereUI.BuildCogPopup(opts)
    uiCogOptions[#uiCogOptions+1] = opts
    local show = setmetatable({}, { __call=function(self, owner)
        assert(owner, "native inline buttons do not pass a self argument")
        if not self._popupFrame then self._popupFrame = CreateFrame("Frame") end
        self._popupFrame:Show()
        self.owner = owner
    end })
    opts.show = show
    return nil, show
end
function EllesmereUI.BuildInlineButton(region, text, onClick, opts)
    assert(not EllesmereUI._prebuilding)
    local btn = CreateFrame("Button", nil, region)
    btn:SetSize(opts.width, opts.height)
    btn:SetScript("OnClick", function() onClick() end)
    region._lastInline = btn
    local function Refresh()
        btn:SetEnabled(not opts.disabled())
        btn:SetAlpha(opts.disabled() and .35 or 1)
    end
    Refresh()
    EllesmereUI.RegisterWidgetRefresh(Refresh)
    uiInlineButtons[#uiInlineButtons+1] = {button=btn, text=text, options=opts}
    return btn
end
function UnitClass() return "Druid", "DRUID" end
function FakePreview(row, kind, key, region)
    assert(kind == "health" and region == row._rightRegion)
    local frame = CreateFrame("Frame", nil, row)
    local preview = { key=key }
    function preview.GetFrame() return frame end
    function preview.SetDisabled(off) preview.disabled = off end
    function preview.UpdateColor()
        preview.color = profile[key] or ns.defaults[key]
    end
    uiPreviews[#uiPreviews+1] = preview
    return preview
end
DEFAULT_CHAT_FRAME = { AddMessage=function(_, msg) uiMessages[#uiMessages+1] = msg end }
C_Spell = {
    GetSpellName=function(id) return "Client Spell " .. id end,
    GetSpellTexture=function(id) return id + 100000 end,
    GetSpellInfo=function(id) if id == 155722 then return { name="Rake" } end end,
}
''')
load('local ns = ...\n-- EUI_DEBUFF_COLORS: uses' + helper)(lua.globals().ns)
lua.execute(r'''
local y = ns.NP_BuildDebuffColorsOptions({}, 0, FakePreview)
assert(y == -210 and #uiRows == 4 and #uiPreviews == 3)
assert(#uiInlineButtons == 1 and uiInlineButtons[1].text == "Priority Color")
local priorityButton = uiInlineButtons[1].button
local priorityRegion = uiRows[4].frame._leftRegion
local priorityOptions = uiCogOptions[1]
local priority = priorityOptions.rows[1]
assert(priorityOptions.captureRegion == priorityRegion)
assert(priority.get() == "2" and not UIState(priorityButton).shown)
assert(priorityRegion._lastInline == nil)
local first, second = uiRows[2][1], uiRows[3][1]
assert(#first.order == 15 and first.values["703"] == "Client Spell 703")
assert(first.order[3] == "1079", "player-class presets were not prioritized")
assert(first.values._menuOpts.searchable and first.values._noLoc)
assert(first.values._menuOpts.icon("703") == 100703)
first.values._menuOpts.onItemHover("703", {})
assert(uiTooltip == "Rogue | Spell ID: 703")
first.values._menuOpts.onItemLeave()
assert(uiTooltip == nil)
assert(uiRows[2].frame._rightRegion._lastInline == uiPreviews[1].GetFrame(),
    "preview was not reserved when labels are clamped")
first.setValue("703")
second.setValue("1943")
assert(profile.debuffColorSpell1 == "703" and profile.debuffColorSpell2 == "1943",
    "slot callbacks captured the wrong loop variable")
uiRows[4][1].setValue(false)
assert(UIState(priorityButton).shown and UIState(priorityButton).enabled)
assert(priorityRegion._lastInline == priorityButton)
UIState(priorityButton).scripts.OnClick()
assert(priorityOptions.show.owner == priorityButton and UIState(priorityOptions.show._popupFrame).shown)
priority.set("1")
assert(profile.debuffColorPriority == 1 and priority.get() == "1")
assert(not priority.disabled())
uiRows[4][1].setValue(true)
assert(not UIState(priorityButton).shown and priorityRegion._lastInline == nil)
assert(not UIState(priorityOptions.show._popupFrame).shown, "enabling Both Active left priority popup open")
assert(profile.debuffColorPriority == 1, "hiding priority reset the preference")
uiRows[4][1].setValue(false)
assert(priority.get() == "1" and UIState(priorityButton).shown)
uiRows[4][1].setValue(true)
uiRows[2][2].setValue(.7, .8, .9)
assert(profile.debuffColor1.r == .7 and profile.debuffColor2 == nil)
assert(uiPreviews[1].color.r == .7, "color picker did not update its live preview")
local custom = first.values.custom
custom.action()
assert(uiPopup.allowEmpty and uiPopup.initialText == "")
assert(profile.debuffColorSpell1 == "703", "opening/canceling custom editor changed selection")
uiPopup.onConfirm("garbage")
uiPopup.onConfirm("-1")
uiPopup.onConfirm("99999999")
assert(#uiMessages == 3 and profile.debuffColorCustomSpell1 == nil)
uiPopup.onConfirm(" 155722 ")
assert(profile.debuffColorCustomSpell1 == 155722 and first.getValue() == "custom")
assert(custom.text == "Client Spell 155722 (Custom)")
assert(uiRows[2].frame.invalidations == 1, "edited custom spell left a stale menu label")
local iconFrame = uiRows[2].frame._leftRegion._lastInline
assert(UIState(iconFrame).shown and UIState(iconFrame).alpha == 1)
uiPopup.onConfirm("")
assert(profile.debuffColorCustomSpell1 == 0 and first.getValue() == "none")
assert(not UIState(iconFrame).shown and uiPreviews[1].disabled)
uiRows[1][1].setValue(false)
assert(first.disabled() and second.disabled() and uiRows[1][2].disabled())
assert(uiPreviews[2].disabled)
uiRows[1][1].setValue(true)
first.setValue("1943")
assert(uiRows[4][1].disabled() and uiRows[4][2].disabled(), "duplicate selection enabled pair color")
uiRows[4][1].setValue(false)
assert(priority.disabled() and not UIState(priorityButton).enabled)
second.setValue("none")
assert(uiRows[4][1].disabled() and uiRows[4][2].disabled())
profile = { debuffColorsEnabled=true, debuffColorSpell1="custom", debuffColorCustomSpell1=155722,
    debuffColorSpell2="none", debuffColor1={ r=.2, g=.3, b=.4 } }
ns.db.profile = profile
EllesmereUI:RefreshPage()
assert(not UIState(priorityButton).shown and priority.get() == "2", "profile priority did not refresh")
assert(first.getValue() == "custom" and custom.text == "Client Spell 155722 (Custom)")
assert(uiPreviews[1].color.r == .2 and not uiPreviews[1].disabled)
assert(UIState(iconFrame).shown and UIState(iconFrame).alpha == 1)

-- Spell metadata may be absent: every preset still has its actual icon, in
-- the menu and beside the selected value. Custom spells can use info.iconID.
local originalTexture, originalInfo = C_Spell.GetSpellTexture, C_Spell.GetSpellInfo
C_Spell.GetSpellTexture = function() end
C_Spell.GetSpellInfo = function(id) if id == 12345 then return {iconID=98765} end end
for _, spell in ipairs(ns.DebuffColorPresets) do
    local texture = first.values._menuOpts.icon(tostring(spell[1]))
    assert(type(texture) == "string" and texture:find("Interface\\Icons\\", 1, true) == 1)
    assert(not texture:find("QuestionMark", 1, true), "preset fell back to a generic icon")
end
assert(first.values._menuOpts.icon("1259790") == "Interface\\Icons\\spell_shadow_unstableaffliction_3")
assert(first.values._menuOpts.icon("12345") == 98765)
assert(first.values._menuOpts.icon("none") == nil)
profile.debuffColorSpell1 = "316099"
EllesmereUI:RefreshPage()
assert(first.getValue() == "1259790" and first.values[first.getValue()] == "Client Spell 1259790")
local selectedIcon = UIState(iconFrame).regions[1]
assert(UIState(selectedIcon).texture == "Interface\\Icons\\spell_shadow_unstableaffliction_3")
assert(profile.debuffColorSpell1 == "316099")
C_Spell.GetSpellTexture, C_Spell.GetSpellInfo = originalTexture, originalInfo

-- Removing a preset must not erase a user's existing selection. Switching
-- profiles adds/removes the saved choice without leaving stale dropdown text.
profile.debuffColorSpell1 = "2818"
EllesmereUI:RefreshPage()
assert(first.getValue() == "2818" and first.values["2818"] == "Client Spell 2818 (Saved)")
assert(#first.order == 16 and first.order[16] == "2818")
first.setValue("703")
assert(first.values["2818"] == nil and #first.order == 15)
EllesmereUI._prebuilding = true
local previewsBefore = #uiPreviews
local inlineBefore, captureBefore = #uiInlineButtons, #uiCogOptions
ns.NP_BuildDebuffColorsOptions({}, 0, FakePreview)
assert(#uiPreviews == previewsBefore, "prebuild created live previews")
assert(#uiInlineButtons == inlineBefore and #uiCogOptions == captureBefore + 1,
    "prebuild did not capture priority without creating its inline button")
''')
print('PASS: curated presets, current/legacy UA tracking, icon fallbacks, preserved saved selections,')
print('      native menus, class ordering, custom popup/labels, live previews, callbacks and gating.')
print('PASS: selectable priority, both cast orders, reapplication, combat deferral, inline visibility and capture.')
