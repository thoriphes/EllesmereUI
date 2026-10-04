if EUI_CLIENT_BLOCKED then return end
local _, ns = ...

-- EUI_DEBUFF_COLORS: declarative aura slots own visibility. Never read aura
-- payloads, inspect secure button visibility, or infer debuffs from casts.
local rigs = {} -- [pooled EUI plate] = rig; reused when its unit changes
local config
local worker
local generation = 0
local pendingRefresh = false
local WHITE = "Interface\\Buttons\\WHITE8x8"
local STYLE = "np:debuffColorPresence"

-- Spell IDs identify DEBUFFS (Rake's damage spell, for example, is 1822).
-- Curated for debuffs players maintain on individual enemies. Names and icons
-- come from the client; verified icon paths cover unavailable spell metadata.
ns.DebuffColorPresets = {
    { 703, "Garrote", "Rogue", "Interface\\Icons\\ability_rogue_garrote" },
    { 1943, "Rupture", "Rogue", "Interface\\Icons\\ability_rogue_rupture" },
    { 1079, "Rip", "Druid", "Interface\\Icons\\ability_ghoulfrenzy" },
    { 155722, "Rake", "Druid", "Interface\\Icons\\ability_druid_disembowel" },
    { 164812, "Moonfire", "Druid", "Interface\\Icons\\spell_nature_starfall" },
    { 164815, "Sunfire", "Druid", "Interface\\Icons\\ability_mage_firestarter" },
    { 589, "Shadow Word: Pain", "Priest", "Interface\\Icons\\spell_shadow_shadowwordpain" },
    { 34914, "Vampiric Touch", "Priest", "Interface\\Icons\\spell_holy_stoicism" },
    { 980, "Agony", "Warlock", "Interface\\Icons\\spell_shadow_curseofsargeras" },
    { 146739, "Corruption", "Warlock", "Interface\\Icons\\spell_shadow_abominationexplosion" },
    { 1259790, "Unstable Affliction", "Warlock", "Interface\\Icons\\spell_shadow_unstableaffliction_3" },
    { 445474, "Wither", "Warlock", "Interface\\Icons\\inv_ability_hellcallerwarlock_wither" },
    { 188389, "Flame Shock", "Shaman", "Interface\\Icons\\spell_fire_flameshock" },
}
ns.DebuffColorPresetByID = {}
for _, spell in ipairs(ns.DebuffColorPresets) do ns.DebuffColorPresetByID[spell[1]] = spell end

-- Normalize preset IDs while keeping explicit custom IDs exact.
function ns.DebuffColors_NormalizePreset(selection)
    if tonumber(selection) == 316099 then return "1259790" end
    return selection
end

local function Value(key)
    local p = ns.NP_GetProfile()
    if p and p[key] ~= nil then return p[key] end
    return ns.defaults[key]
end

local function Spell(slot)
    local selection = ns.DebuffColors_NormalizePreset(Value("debuffColorSpell" .. slot))
    if selection == "custom" then selection = Value("debuffColorCustomSpell" .. slot) end
    local id = tonumber(selection)
    if id and id > 0 and id == math.floor(id) then return id end
end

local function Color(key)
    local c = Value(key)
    local d = ns.defaults[key]
    return { r = c.r or d.r, g = c.g or d.g, b = c.b or d.b }
end

local function ReadConfig()
    local c = {
        enabled = Value("debuffColorsEnabled") == true,
        spell1 = Spell(1), spell2 = Spell(2),
        filter = Value("debuffColorsPlayerOnly") ~= false and "HARMFUL|PLAYER" or "HARMFUL",
        filterTokens = Value("debuffColorsPlayerOnly") ~= false and { "HARMFUL", "PLAYER" } or { "HARMFUL" },
        both = Value("debuffColorBothEnabled") ~= false,
        priority = tonumber(Value("debuffColorPriority")) == 1 and 1 or 2,
        color1 = Color("debuffColor1"), color2 = Color("debuffColor2"),
        colorBoth = Color("debuffColorBoth"),
        texture = EllesmereUI.ResolveTexturePath(ns.healthBarTextures,
            Value("healthBarTexture"), WHITE),
    }
    -- Identical choices mean one spell, never a fictitious two-debuff state.
    if c.spell1 == c.spell2 then c.spell2 = nil end
    c.fingerprint = table.concat({ tostring(c.enabled), tostring(c.spell1),
        tostring(c.spell2), c.filter, tostring(c.both), c.priority, tostring(c.texture),
        c.color1.r, c.color1.g, c.color1.b, c.color2.r, c.color2.g, c.color2.b,
        c.colorBoth.r, c.colorBoth.g, c.colorBoth.b }, "|")
    return c
end

local function DisableRig(rig)
    rig.unit = nil
    -- The ordinary holder hides immediately, including during a deferred parse.
    rig.holder:Hide()
    for _, container in ipairs(rig.containers) do
        container:SetEnabled(false)
        container:SetUnit("none")
    end
end

local function BindRig(rig, unit)
    if rig.unit == unit then return end
    rig.unit = unit
    -- Binding a slot may initialize its nested container; include new links.
    local i = 1
    while i <= #rig.containers do
        local container = rig.containers[i]
        container:SetUnit(unit)
        container:SetEnabled(true)
        i = i + 1
    end
    rig.holder:Show()
end

local function Container(rig, parent)
    local c = EllesmereUI.AuraKit.CreateContainerShell(parent, {})
    c:SetEnabled(false)
    c:SetAllPoints(rig.holder)
    c:SetFrameLevel(rig.level)
    rig.containers[#rig.containers + 1] = c
    return c
end

local function TintInitializer(rig, color, sublevel)
    local initialized = setmetatable({}, { __mode = "k" })
    return function(button)
        if initialized[button] then return end
        initialized[button] = true
        -- Only creation-window decoration. Once owned by the aura engine, these
        -- regions may become forbidden; never read or repaint them on rebind.
        button:SetFrameLevel(rig.level)
        button:EnableMouse(false)
        local tint = button:CreateTexture(nil, "ARTWORK", nil, sublevel)
        tint:SetTexture(rig.config.texture)
        tint:SetVertexColor(color.r, color.g, color.b, 1)
        tint:SetPoint("TOPLEFT", rig.fill, "TOPLEFT", 0, 0)
        tint:SetPoint("BOTTOMRIGHT", rig.fill, "BOTTOMRIGHT", 0, 0)
        if rig.mask then tint:AddMaskTexture(rig.mask) end
    end
end

local function AddSlot(rig, container, key, spell, initialize)
    EllesmereUI.AuraKit.AddSlotToContainer(container, {
        key = key, filter = rig.config.filterTokens, style = STYLE,
        candidateFilters = { includeSpellIDs = { [spell] = true } },
        extraInit = initialize,
    })
end

local function BuildRig(plate)
    local rig = {
        config = config, generation = generation,
        fill = plate.health:GetStatusBarTexture(), mask = plate._absorbMask,
        level = plate.health:GetFrameLevel(), containers = {},
    }
    -- Tint shares the fill's frame level; EUI's text, target/focus patterns,
    -- border and absorb effects keep their own higher layers.
    rig.holder = CreateFrame("Frame", nil, plate.health)
    rig.holder:SetAllPoints(plate.health)
    rig.holder:SetFrameLevel(rig.level)
    rig.holder:EnableMouse(false)
    rig.holder:Hide()
    local root = Container(rig, rig.holder)
    if config.spell1 then
        AddSlot(rig, root, "EUI_DEBUFF_COLOR_1", config.spell1,
            TintInitializer(rig, config.color1, config.priority == 1 and 5 or 4))
    end
    if config.spell2 then
        AddSlot(rig, root, "EUI_DEBUFF_COLOR_2", config.spell2,
            TintInitializer(rig, config.color2, config.priority == 2 and 5 or 4))
    end
    if config.both and config.spell1 and config.spell2 then
        local initialized = setmetatable({}, { __mode = "k" })
        AddSlot(rig, root, "EUI_DEBUFF_COLOR_PAIR", config.spell1, function(button)
            if initialized[button] then return end
            initialized[button] = true
            button:SetFrameLevel(rig.level)
            button:EnableMouse(false)
            -- The second slot is a child of the first spell's secure button.
            -- Its tint renders only while BOTH engine-owned buttons are visible.
            local nested = Container(rig, button)
            AddSlot(rig, nested, "EUI_DEBUFF_COLOR_BOTH", rig.config.spell2,
                TintInitializer(rig, rig.config.colorBoth, 7))
            if rig.unit then
                nested:SetUnit(rig.unit)
                nested:SetEnabled(true)
            end
        end)
    end
    rigs[plate] = rig
    return rig
end

local function Attach(plate, unit)
    local rig = rigs[plate]
    if not config.enabled or not (config.spell1 or config.spell2) then
        if rig and rig.unit then DisableRig(rig) end
        return
    end
    if rig and rig.generation ~= generation then
        DisableRig(rig)
        -- Drop the old engine configuration; its forbidden regions stay hidden.
        rig = nil
    end
    if not rig then rig = BuildRig(plate) end
    -- Parent level changes propagate to all descendants. Touch only the ordinary
    -- holder; a nested container inherits its secure AuraButton's restrictions.
    rig.level = plate.health:GetFrameLevel()
    rig.holder:SetFrameLevel(rig.level)
    BindRig(rig, unit)
end

local function Detach(plate)
    local rig = rigs[plate]
    if rig and rig.unit then DisableRig(rig) end
end

local function EnsureWorker()
    if worker then return worker end
    worker = CreateFrame("Frame")
    worker:Hide()
    worker:SetScript("OnEvent", function()
        if pendingRefresh then ns.DebuffColors_Refresh() end
    end)
    return worker
end

function ns.DebuffColors_Refresh()
    if not config and Value("debuffColorsEnabled") ~= true then return end
    -- Profile/spec swaps can arrive in combat. Rebuilding secure decoration is
    -- deferred; the new configuration is applied on PLAYER_REGEN_ENABLED.
    if InCombatLockdown() then
        pendingRefresh = true
        EnsureWorker():RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    pendingRefresh = false
    local nextConfig = ReadConfig()
    if config and config.fingerprint == nextConfig.fingerprint then return end
    config = nextConfig
    generation = generation + 1
    -- Clear active AND currently pooled rigs so a later plate reuse cannot bind
    -- a previous profile's spells or colors.
    for plate, rig in pairs(rigs) do
        DisableRig(rig)
        rigs[plate] = nil
    end
    if config.enabled then
        local AK = EllesmereUI.AuraKit
        AK.styles[STYLE] = AK.styles[STYLE] or { noRegions = true, noTooltips = true }
        ns.DebuffColors_Attach, ns.DebuffColors_Detach = Attach, Detach
        EnsureWorker():RegisterEvent("PLAYER_REGEN_ENABLED")
        for unit, plate in pairs(ns.plates) do Attach(plate, unit) end
    else
        ns.DebuffColors_Attach, ns.DebuffColors_Detach = nil, nil
        config = nil
        if worker then
            worker:UnregisterEvent("PLAYER_REGEN_ENABLED")
            worker:SetScript("OnUpdate", nil)
            worker:Hide()
        end
    end
end

-- Coalesce settings writes into one next-frame refresh; never poll aura state.
function ns.DebuffColors_RequestRefresh()
    if not config and Value("debuffColorsEnabled") ~= true then return end
    local w = EnsureWorker()
    w:SetScript("OnUpdate", function(self)
        self:Hide()
        self:SetScript("OnUpdate", nil)
        ns.DebuffColors_Refresh()
    end)
    w:Show()
end
