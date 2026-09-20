if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
local addon, ns = ...

if not ns then return end

-------------------------------------------------------------------------------
--  Force Nameplate on Current Target (forceTargetPlate, default off).
--
--  The client only spawns a nameplate for a unit whose visibility category is
--  on (nameplateShowEnemies, nameplateShowFriendlyNPCs, enemy pets...), so a
--  target in a hidden category has no plate frame at all -- nothing an addon
--  can draw on. With the setting on, targeting such a unit flips the category
--  CVar(s) its plate depends on to 1, the client spawns the plates, and every
--  plate in a flipped category that is not the target is hidden (root alpha 0,
--  or the Blizzard UnitFrame parked on a hidden frame) so the screen looks as
--  before plus the one plate. Losing or changing the target hands the CVars
--  back.
--
--  Baseline tracking: what gets handed back is what the rest of the UI wants
--  NOW, not a snapshot. Every other writer of these CVars (Hide Enemy
--  Nameplates out of Combat, the friendly NPC / enemy pet toggles, Blizzard's
--  panel, the keybinds) broadcasts CVAR_UPDATE. While a category is held on,
--  an external 1 adopts that as the baseline (nothing left to hand back, the
--  hidden plates come back), an external 0 is re-asserted for the target.
--
--  Cost off: nothing (no events registered, one nil test in NT_Apply).
--  Cost on: PLAYER_TARGET_CHANGED + plate add/remove + CVAR_UPDATE (one table
--  lookup); a handful of Unit* calls per plate on a target change. No
--  OnUpdate, no timers beyond a 0-delay coalesce.
--
--  Instances: friendly nameplate frames are forbidden to addons there, so a
--  forced friendly category could never be hidden again. Friendly categories
--  are therefore not forced inside instances; enemy categories always are.
-------------------------------------------------------------------------------

local CVAR_NAMES = {
    -- Newer clients register nameplateShowFriendlyPlayers, older ones
    -- nameplateShowFriends (a master that also gates NPC / minion plates).
    friendPlayers   = { "nameplateShowFriendlyPlayers", "nameplateShowFriends" },
    friendNPC       = { "nameplateShowFriendlyNPCs", "nameplateShowFriendlyNpcs" },
    friendMinions   = { "nameplateShowFriendlyMinions" },
    friendPets      = { "nameplateShowFriendlyPets" },
    friendGuardians = { "nameplateShowFriendlyGuardians" },
    friendTotems    = { "nameplateShowFriendlyTotems" },
    enemies         = { "nameplateShowEnemies" },
    enemyMinus      = { "nameplateShowEnemyMinus" },
    enemyMinions    = { "nameplateShowEnemyMinions" },
    enemyPets       = { "nameplateShowEnemyPets" },
    enemyGuardians  = { "nameplateShowEnemyGuardians" },
    enemyTotems     = { "nameplateShowEnemyTotems" },
}
local FRIEND_KEYS = {
    friendPlayers = true, friendNPC = true, friendMinions = true,
    friendPets = true, friendGuardians = true, friendTotems = true,
}

local liveName  = {}   -- key -> registered CVar name (false = none on this client)
local keyByName = {}   -- lower-cased live CVar name -> key

-- The CVar name this client registers for a category, resolved on first read
-- and cached; nil when the client has none.
local function LiveCVar(key)
    local name = liveName[key]
    if name ~= nil then return name or nil end
    local cands = CVAR_NAMES[key]
    for i = 1, #cands do
        local ok, v = pcall(GetCVar, cands[i])
        if ok and v ~= nil then
            liveName[key] = cands[i]
            keyByName[string.lower(cands[i])] = key
            return cands[i]
        end
    end
    liveName[key] = false
    return nil
end

local function CVarOn(name)
    local v = GetCVar(name)
    return v == "1" or v == 1
end

-- Category keys a unit's plate depends on (every one must be 1 for the client
-- to spawn it). The lists must be EXACT per category: a non-target plate is
-- hidden when any key it depends on is held, so an over-wide list would hide
-- plates the user's own rules show. nil = never forced: the player's own
-- plate, widget-only plates.
local DEPS_ENEMY, DEPS_ENEMY_MINUS, DEPS_ENEMY_PET, DEPS_ENEMY_GUARDIAN
local DEPS_FRIEND_PLAYER, DEPS_FRIEND_NPC, DEPS_FRIEND_PET, DEPS_FRIEND_GUARDIAN
local function EnsureDeps()
    if DEPS_ENEMY then return end
    DEPS_ENEMY          = { "enemies" }
    DEPS_ENEMY_MINUS    = { "enemies", "enemyMinus" }
    DEPS_ENEMY_PET      = { "enemies", "enemyMinions", "enemyPets" }
    -- Guardians and totems share a list: both are player-controlled Creature
    -- GUIDs and nothing cheap tells them apart.
    DEPS_ENEMY_GUARDIAN = { "enemies", "enemyMinions", "enemyGuardians", "enemyTotems" }
    DEPS_FRIEND_PLAYER   = { "friendPlayers" }
    DEPS_FRIEND_NPC      = { "friendNPC" }
    DEPS_FRIEND_PET      = { "friendMinions", "friendPets" }
    DEPS_FRIEND_GUARDIAN = { "friendMinions", "friendGuardians", "friendTotems" }
    if LiveCVar("friendPlayers") == "nameplateShowFriends" then
        -- Legacy hierarchy: nameplateShowFriends masters every friendly plate.
        DEPS_FRIEND_NPC[#DEPS_FRIEND_NPC + 1] = "friendPlayers"
        DEPS_FRIEND_PET[#DEPS_FRIEND_PET + 1] = "friendPlayers"
        DEPS_FRIEND_GUARDIAN[#DEPS_FRIEND_GUARDIAN + 1] = "friendPlayers"
    end
end

local function IsPetGUID(unit)
    local guid = UnitGUID(unit)
    return guid ~= nil and string.sub(guid, 1, 4) == "Pet-"
end

local function Deps(unit)
    if UnitIsUnit(unit, "player") then return nil end
    if UnitNameplateShowsWidgetsOnly and UnitNameplateShowsWidgetsOnly(unit) then return nil end
    local isPlayer = UnitIsPlayer(unit)
    if UnitCanAttack("player", unit) then
        if isPlayer then return DEPS_ENEMY end
        if UnitPlayerControlled(unit) then
            return IsPetGUID(unit) and DEPS_ENEMY_PET or DEPS_ENEMY_GUARDIAN
        end
        if UnitClassification(unit) == "minus" then return DEPS_ENEMY_MINUS end
        return DEPS_ENEMY
    end
    if isPlayer then return DEPS_FRIEND_PLAYER end
    if UnitPlayerControlled(unit) then
        return IsPetGUID(unit) and DEPS_FRIEND_PET or DEPS_FRIEND_GUARDIAN
    end
    return DEPS_FRIEND_NPC
end

-------------------------------------------------------------------------------
--  State
-------------------------------------------------------------------------------
local active = false      -- setting on, events registered
local forced = {}         -- key -> true while we hold that category on
local releasing = {}      -- key -> GetTime() of our last hand-back (client despawn pending)
local ownWrites = {}      -- lower-cased CVar name -> pending count of our own SetCVar calls
local parkedUF = {}       -- unit -> { uf, np }: Blizzard UnitFrames we parked (no EUI plate on them)
local parkFrame = CreateFrame("Frame")
parkFrame:Hide()
local ctl = CreateFrame("Frame")
local evalPending = false

local function WriteCVar(name, value)
    local lname = string.lower(name)
    ownWrites[lname] = (ownWrites[lname] or 0) + 1
    SetCVar(name, value)
end

local function ForceKey(key)
    local name = LiveCVar(key)
    if not name then return end
    if forced[key] then
        -- Held, but someone wrote 0 under us (CVAR_UPDATE brought us here): re-assert.
        if not CVarOn(name) then WriteCVar(name, "1") end
        return
    end
    if CVarOn(name) then return end   -- the rule already shows it: nothing to force
    forced[key] = true
    if key == "friendNPC" then ns._tfFriendlyNPCForced = true end   -- friendly module styles NPC plates while held
    WriteCVar(name, "1")
end

local function ReleaseKey(key)
    if not forced[key] then return end
    forced[key] = nil
    if key == "friendNPC" then ns._tfFriendlyNPCForced = nil end
    local name = LiveCVar(key)
    if name then
        releasing[key] = GetTime()
        -- Already 0 = someone else turned it off under us; nothing to hand back.
        if CVarOn(name) then WriteCVar(name, "0") end
    end
end

-------------------------------------------------------------------------------
--  Per-plate hide / show
-------------------------------------------------------------------------------
-- A non-target plate is hidden when any category it depends on is held by us,
-- or was handed back within the last second (the client is despawning those
-- plates; keeping them hidden avoids a one-frame flash of the whole category).
local RELEASE_GRACE = 1
local function ShouldHide(unit)
    if UnitIsUnit(unit, "target") then return false end
    EnsureDeps()
    local deps = Deps(unit)
    if not deps then return false end
    local now = GetTime()
    for i = 1, #deps do
        local key = deps[i]
        if forced[key] then return true end
        local t = releasing[key]
        if t and now - t < RELEASE_GRACE then return true end
    end
    return false
end

local function ApplyUnit(unit, nameplate, hide)
    -- Enemy plate: root alpha rides NT_Apply (reads ns._tfHidden).
    local ep = ns.plates[unit]
    if hide then
        if not ns._tfHidden then ns._tfHidden = {} end
        ns._tfHidden[unit] = true
    elseif ns._tfHidden then
        ns._tfHidden[unit] = nil
    end
    if ep then ns.NT_Apply(ep) end

    -- EUI friendly plate (health-bar mode). The flag is reset in ClearUnit so a
    -- pooled frame never comes back at alpha 0.
    local fpl = ns.friendlyPlates and ns.friendlyPlates[unit]
    if fpl then
        if hide then
            if not fpl._tfHidden then fpl._tfHidden = true; fpl:SetAlpha(0) end
        elseif fpl._tfHidden then
            fpl._tfHidden = nil; fpl:SetAlpha(1)
        end
    end

    -- Name-only NPC overlay (friendly module owns the table).
    if nameplate and ns.TF_SetNPCOverlayHidden then ns.TF_SetNPCOverlayHidden(nameplate, hide) end

    -- Blizzard UnitFrame still rendering on the plate (name-only players, or
    -- friendly plates handed to Blizzard): park it. A plate EUI skins (enemy or
    -- friendly) already has its UnitFrame blanked, and anything EUI parked
    -- (parent ~= nameplate) is invisible: both left alone.
    local uf = (not ep and not fpl and nameplate) and nameplate.UnitFrame
    if uf and not uf:IsForbidden() then
        local entry = parkedUF[unit]
        if hide then
            if not entry and uf:GetParent() == nameplate then
                uf:SetParent(parkFrame)
                parkedUF[unit] = { uf = uf, np = nameplate }
            end
        elseif entry then
            parkedUF[unit] = nil
            if entry.uf:GetParent() == parkFrame then entry.uf:SetParent(entry.np) end
        end
    end
end

local function ForgetUnit(unit)
    if ns._tfHidden then ns._tfHidden[unit] = nil end
    local entry = parkedUF[unit]
    if entry then
        parkedUF[unit] = nil
        if entry.uf:GetParent() == parkFrame then entry.uf:SetParent(entry.np) end
    end
end

local function ApplyAll(unhideAll)
    local plates = C_NamePlate.GetNamePlates()
    if plates then
        for i = 1, #plates do
            local np = plates[i]
            local unit = np.namePlateUnitToken
            if unit then
                ApplyUnit(unit, np, (not unhideAll) and ShouldHide(unit))
            end
        end
    end
end

-------------------------------------------------------------------------------
--  Evaluate: the single source of truth. Holds exactly the categories the
--  current target needs that the rules have off, releases the rest, then
--  re-applies hide/show to every plate.
-------------------------------------------------------------------------------
local function Evaluate()
    if not active then return end
    EnsureDeps()
    local want
    if UnitExists("target") then
        local deps = Deps("target")
        if deps then
            local inInstance = IsInInstance()
            for i = 1, #deps do
                local key = deps[i]
                if not (inInstance and FRIEND_KEYS[key]) then
                    want = want or {}
                    want[key] = true
                end
            end
        end
    end
    for key in pairs(forced) do
        if not (want and want[key]) then ReleaseKey(key) end
    end
    if want then
        for key in pairs(want) do ForceKey(key) end
    end
    ApplyAll()
end

-- Coalesced, next-frame Evaluate: PLAYER_ENTERING_WORLD reaches us before
-- EUI's own CVar writers (instance rules) have run.
local function RequestEvaluate()
    if evalPending then return end
    evalPending = true
    C_Timer.After(0, function()
        evalPending = false
        Evaluate()
    end)
end

ctl:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "PLAYER_TARGET_CHANGED" then
        Evaluate()
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        if next(forced) then
            ApplyUnit(arg1, C_NamePlate.GetNamePlateForUnit(arg1), ShouldHide(arg1))
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        ForgetUnit(arg1)
    elseif event == "CVAR_UPDATE" then
        if type(arg1) ~= "string" then return end
        local lname = string.lower(arg1)
        local key = keyByName[lname]
        if not key then return end
        local n = ownWrites[lname]
        if n and n > 0 then
            ownWrites[lname] = n - 1
            return
        end
        -- Someone else wrote a category we care about: their value supersedes
        -- any hand-back of ours still despawning. A 1 while held means the rules
        -- want it on now: adopt, so nothing is handed back later and the hidden
        -- plates return. A 0 is re-asserted right here, in the same frame, so
        -- the client never sees the 0 and the target's plate does not blink
        -- (e.g. Hide Enemy Nameplates out of Combat writing 0 at combat end).
        releasing[key] = nil
        if forced[key] and (arg2 == "1" or arg2 == 1 or arg2 == true) then
            forced[key] = nil
            if key == "friendNPC" then ns._tfFriendlyNPCForced = nil end
        end
        Evaluate()
    elseif event == "PLAYER_ENTERING_WORLD" then
        RequestEvaluate()
    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        ns.TF_Refresh()
    end
end)
ctl:RegisterEvent("PLAYER_LOGIN")

-------------------------------------------------------------------------------
--  Setting on/off. Called from the options toggle, PLAYER_LOGIN and
--  RefreshAllSettings (profile switch / preset apply).
-------------------------------------------------------------------------------
function ns.TF_Refresh()
    local prof = ns.db and ns.db.profile
    local on = prof ~= nil and prof.forceTargetPlate == true
    if on and not active then
        active = true
        ctl:RegisterEvent("PLAYER_TARGET_CHANGED")
        ctl:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        ctl:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        ctl:RegisterEvent("CVAR_UPDATE")
        ctl:RegisterEvent("PLAYER_ENTERING_WORLD")
        Evaluate()
    elseif not on and active then
        active = false
        ctl:UnregisterEvent("PLAYER_TARGET_CHANGED")
        ctl:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
        ctl:UnregisterEvent("NAME_PLATE_UNIT_REMOVED")
        ctl:UnregisterEvent("CVAR_UPDATE")
        ctl:UnregisterEvent("PLAYER_ENTERING_WORLD")
        for key in pairs(forced) do ReleaseKey(key) end
        -- Released plates stay hidden until the client despawns them; a short
        -- sweep then clears whatever is left so no stale hide can outlive the
        -- setting (NT_Apply reads ns._tfHidden with the feature off too).
        ApplyAll()
        C_Timer.After(0.5, function()
            if active then return end
            ApplyAll(true)
            for unit in pairs(parkedUF) do ForgetUnit(unit) end
            ns._tfHidden = nil
            ns._tfFriendlyNPCForced = nil
        end)
    elseif on then
        Evaluate()
    end
end
