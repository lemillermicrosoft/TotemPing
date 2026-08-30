-- DamageTotemOOR
-- Notify when the player moves out of range of an active damage totem
-- (Searing / Magma / Fire Nova).
--
-- Two detection methods, selectable via TotemPingDB.damageTotemOOR.method:
--
--   "combat_log": watch COMBAT_LOG_EVENT_UNFILTERED for damage events whose
--                 sourceName matches an active player-owned damage totem.
--                 Stamp lastDamageTime[slot]. If a Searing/Magma totem has
--                 been up long enough for a tick but goes silent for longer
--                 than combatLogSilenceSeconds, flag OOR. (Fire Nova skipped
--                 for this method -- it's a single burst.)
--
--   "position":   snapshot (x, y, zone) when a damage totem becomes active,
--                 then poll GetPlayerMapPosition("player") and compare using
--                 a per-zone yards-per-map-unit table. Zone change or beyond
--                 effective radius (+ configurable slack) => OOR. Falls back
--                 to combat_log for that totem if the map API returns 0,0
--                 or the zone isn't in the scale table.
--
--   "both":       flag OOR if either method trips, deduped per totem
--                 per OOR transition.
--
-- Notifications use TalonTracker-style orange prefix via DEFAULT_CHAT_FRAME.
-- Multiple totems tripping within combineWindow are coalesced into one line.
-- A given totem only re-notifies after it returns in-range and leaves again,
-- or is re-summoned.

local addonName = ...

local ORANGE_PREFIX = "|cffff9933[TotemPing]|r"

-------------------------------------------------
-- Config defaults
-------------------------------------------------

local DEFAULTS = {
    enabled                 = false,  -- default off: noisy for solo play; opt in via /tp oor toggle or config panel
    method                  = "combat_log",  -- "combat_log" | "position" | "both"
    combineMessages         = true,
    combineWindow           = 0.75,
    combatLogSilenceSeconds = 4.0,
    positionSlackYards      = 5,
    debug                   = false,
}

local VALID_METHODS = { combat_log = true, position = true, both = true }

-- Damage totem name substrings (case-insensitive match on combat log sourceName
-- and GetTotemInfo name).
local DAMAGE_TOTEM_KEYS = {
    { key = "searing",   label = "Searing Totem",   radius = 20, tick = true  },
    { key = "magma",     label = "Magma Totem",     radius = 8,  tick = true  },
    { key = "fire nova", label = "Fire Nova Totem", radius = 10, tick = false },
}

-- Minimum time a totem must be up before combat-log silence counts (allow
-- first tick to actually land).
local MIN_UPTIME_BEFORE_SILENCE_CHECK = 3.0

-------------------------------------------------
-- Zone scale table (approximate yards per zone, width x height).
-- Source: publicly documented TBC-era zone dimensions. Values are used only
-- to convert normalized GetPlayerMapPosition() deltas into yard distances,
-- so approximate is fine.
-------------------------------------------------

local ZONE_YARDS = {
    -- Outland
    ["Hellfire Peninsula"]      = { 3444, 2298 },
    ["Zangarmarsh"]             = { 3521, 2349 },
    ["Terokkar Forest"]         = { 3814, 2543 },
    ["Nagrand"]                 = { 3521, 2349 },
    ["Blade's Edge Mountains"]  = { 3521, 2349 },
    ["Netherstorm"]             = { 3814, 2543 },
    ["Shadowmoon Valley"]       = { 3814, 2543 },
    ["Shattrath City"]          = {  777,  518 },
    -- Capitals
    ["Ironforge"]               = {  790,  527 },
    ["Stormwind City"]          = { 1052,  701 },
    ["Orgrimmar"]               = { 1052,  701 },
    ["Thunder Bluff"]           = { 1043,  695 },
    ["Undercity"]               = {  577,  384 },
    ["Silvermoon City"]         = {  874,  583 },
}

-------------------------------------------------
-- State
-------------------------------------------------

local M = {}
TotemPing_DamageOOR = M -- expose for slash dispatch from TotemPing.lua

local isShaman = false

-- Per-slot totem state. Cleared and re-populated whenever PLAYER_TOTEM_UPDATE
-- fires or refreshTotems() runs.
--
-- state[slot] = {
--   key, label, radius, tick,
--   spawnedAt, lastDamageTime,
--   snapX, snapY, snapZone,
--   oorFlagged,     -- true if we've already notified this OOR episode
--   fallbackToCL,   -- position method fell back to combat_log for this totem
-- }
local slotState = {}

-- Coalesce buffer for combined notifications.
local pendingOOR = {}      -- array of labels waiting to be flushed
local pendingSeen = {}     -- set of labels in pendingOOR (dedupe within window)
local pendingFlushAt = 0

local scanAccumulator = 0

-------------------------------------------------
-- Utilities
-------------------------------------------------

local function db()
    return TotemPingDB and TotemPingDB.damageTotemOOR
end

local function dbg(msg)
    local d = db()
    if d and d.debug then
        if TotemPingDB and TotemPingDB.chatQuiet then return end
        DEFAULT_CHAT_FRAME:AddMessage(ORANGE_PREFIX .. " debug: " .. msg)
    end
end

local function lowerContains(haystack, needle)
    if not haystack or not needle then return false end
    return string.find(string.lower(haystack), needle, 1, true) ~= nil
end

local function classifyTotemName(name)
    if not name or name == "" then return nil end
    local lower = string.lower(name)
    for _, entry in ipairs(DAMAGE_TOTEM_KEYS) do
        if string.find(lower, entry.key, 1, true) then
            return entry
        end
    end
    return nil
end

-------------------------------------------------
-- Notification
-------------------------------------------------

local function emit(message)
    if TotemPingDB and TotemPingDB.chatQuiet then return end
    DEFAULT_CHAT_FRAME:AddMessage(ORANGE_PREFIX .. " " .. message)
end

local function flushPending()
    if #pendingOOR == 0 then return end
    emit("Out of range: " .. table.concat(pendingOOR, ", "))
    pendingOOR = {}
    pendingSeen = {}
    pendingFlushAt = 0
end

local function queueOOR(label)
    local d = db()
    local combine = d and d.combineMessages
    local window = (d and d.combineWindow) or DEFAULTS.combineWindow

    if not combine then
        emit("Out of range: " .. label)
        return
    end

    if not pendingSeen[label] then
        table.insert(pendingOOR, label)
        pendingSeen[label] = true
    end
    pendingFlushAt = GetTime() + window
end

-------------------------------------------------
-- Totem tracking
-------------------------------------------------

local function refreshTotems()
    local now = GetTime()
    local next_state = {}
    for slot = 1, 4 do
        local haveTotem, totemName, startTime, duration = GetTotemInfo(slot)
        if haveTotem and totemName and totemName ~= "" then
            local entry = classifyTotemName(totemName)
            if entry then
                local prior = slotState[slot]
                -- Consider it the "same" totem if a prior state exists with
                -- matching label AND spawnedAt very close to startTime.
                local sameTotem = prior
                    and prior.label == entry.label
                    and math.abs((prior.spawnedAt or 0) - (startTime or 0)) < 0.5

                if sameTotem then
                    next_state[slot] = prior
                else
                    next_state[slot] = {
                        key            = entry.key,
                        label          = entry.label,
                        radius         = entry.radius,
                        tick           = entry.tick,
                        spawnedAt      = startTime or now,
                        lastDamageTime = startTime or now,
                        snapX          = nil,
                        snapY          = nil,
                        snapZone       = nil,
                        oorFlagged     = false,
                        fallbackToCL   = false,
                    }
                    dbg("tracking new " .. entry.label .. " in slot " .. slot)
                end
            end
        end
    end
    slotState = next_state
end

-------------------------------------------------
-- Combat log detection
-------------------------------------------------

local DAMAGE_SUBEVENTS = {
    SPELL_DAMAGE          = true,
    SPELL_PERIODIC_DAMAGE = true,
    SWING_DAMAGE          = true,
    RANGE_DAMAGE          = true,
}

local function onCombatLogEvent(...)
    -- Signature (TBC 2.5.x): timestamp, subevent, sourceGUID, sourceName,
    -- sourceFlags, destGUID, destName, destFlags, ...
    local timestamp, subevent, sourceGUID, sourceName = select(1, ...), select(2, ...), select(3, ...), select(4, ...)
    if not subevent or not DAMAGE_SUBEVENTS[subevent] then return end
    if not sourceName or sourceName == "" then return end

    -- Match against currently tracked slots.
    for slot, st in pairs(slotState) do
        if lowerContains(sourceName, st.key) then
            st.lastDamageTime = GetTime()
            -- If we'd flagged OOR, damage means we're back in range.
            if st.oorFlagged then
                dbg(st.label .. " back in range (combat log)")
                st.oorFlagged = false
            end
            return
        end
    end
end

local function combatLogSaysOOR(st, now)
    if not st.tick then return false end -- Fire Nova skipped
    -- Silence only carries OOR information while we're actually in combat.
    -- Out of combat there's no target for the totem to hit, so "silent" is the
    -- expected state and does not mean the player walked away.
    if not UnitAffectingCombat or not UnitAffectingCombat("player") then
        return false
    end
    local uptime = now - (st.spawnedAt or now)
    if uptime < MIN_UPTIME_BEFORE_SILENCE_CHECK then return false end
    local d = db()
    local silence = (d and d.combatLogSilenceSeconds) or DEFAULTS.combatLogSilenceSeconds
    return (now - (st.lastDamageTime or now)) > silence
end

-------------------------------------------------
-- Position detection
-------------------------------------------------

local function safeGetPosition()
    if SetMapToCurrentZone then
        pcall(SetMapToCurrentZone)
    end
    local x, y = 0, 0
    if GetPlayerMapPosition then
        x, y = GetPlayerMapPosition("player")
    end
    return x or 0, y or 0
end

local function ensureSnapshot(st)
    if st.snapX and st.snapY and st.snapZone then return true end
    if st.fallbackToCL then return false end
    local x, y = safeGetPosition()
    local zone = GetRealZoneText and GetRealZoneText() or nil
    if x == 0 and y == 0 then
        if not st.fallbackToCL then
            dbg(st.label .. ": map position unavailable; falling back to combat_log")
        end
        st.fallbackToCL = true
        return false
    end
    if not zone or zone == "" or not ZONE_YARDS[zone] then
        if not st.fallbackToCL then
            dbg((st.label or "?") .. ": zone '" .. tostring(zone) .. "' not in scale table; falling back to combat_log")
        end
        st.fallbackToCL = true
        return false
    end
    st.snapX = x
    st.snapY = y
    st.snapZone = zone
    dbg(st.label .. ": snapshot @ (" .. string.format("%.3f", x) .. "," .. string.format("%.3f", y) .. ") in " .. zone)
    return true
end

local function positionSaysOOR(st)
    if not ensureSnapshot(st) then return false end
    local zone = GetRealZoneText and GetRealZoneText() or nil
    if zone ~= st.snapZone then
        return true, "zone change"
    end
    local scale = ZONE_YARDS[st.snapZone]
    if not scale then return false end
    local x, y = safeGetPosition()
    if x == 0 and y == 0 then return false end
    local dx = (x - st.snapX) * scale[1]
    local dy = (y - st.snapY) * scale[2]
    local dist = math.sqrt(dx * dx + dy * dy)
    local d = db()
    local slack = (d and d.positionSlackYards) or DEFAULTS.positionSlackYards
    if dist > (st.radius + slack) then
        return true, string.format("%.1fy > %dy", dist, st.radius + slack)
    end
    return false
end

-------------------------------------------------
-- Scan pass
-------------------------------------------------

local function scan()
    local d = db()
    if not (d and d.enabled) then return end
    if not isShaman then return end
    if not next(slotState) then return end

    local method = d.method or DEFAULTS.method
    local now = GetTime()

    for slot, st in pairs(slotState) do
        local oor = false
        local reason = nil

        local useCombat = (method == "combat_log") or (method == "both") or st.fallbackToCL
        local usePosition = (method == "position" or method == "both") and not st.fallbackToCL

        if usePosition then
            local flag, why = positionSaysOOR(st)
            if flag then
                oor = true
                reason = "pos: " .. (why or "")
            end
        end

        if not oor and useCombat then
            if combatLogSaysOOR(st, now) then
                oor = true
                reason = "combat log silent"
            end
        end

        if oor and not st.oorFlagged then
            st.oorFlagged = true
            dbg(st.label .. " OOR (" .. tostring(reason) .. ")")
            queueOOR(st.label)
        elseif (not oor) and st.oorFlagged then
            -- Recovered (position came back in range). Combat-log recovery is
            -- handled in onCombatLogEvent when a damage event lands.
            if usePosition then
                dbg(st.label .. " back in range (position)")
                st.oorFlagged = false
            end
        end
    end

    if pendingFlushAt > 0 and now >= pendingFlushAt then
        flushPending()
    end
end

-------------------------------------------------
-- Ticker
-------------------------------------------------

local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function(self, elapsed)
    scanAccumulator = scanAccumulator + elapsed
    if scanAccumulator >= 0.5 then
        scanAccumulator = 0
        scan()
    end
    -- Also flush the pending buffer if the window elapsed without new adds.
    if pendingFlushAt > 0 and GetTime() >= pendingFlushAt then
        flushPending()
    end
end)

local function updateTicker()
    local d = db()
    if isShaman and d and d.enabled then
        scanAccumulator = 0
        ticker:Show()
    else
        ticker:Hide()
    end
end

-------------------------------------------------
-- Event handling
-------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_TOTEM_UPDATE")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        local _, class = UnitClass("player")
        isShaman = (class == "SHAMAN")
        refreshTotems()
        updateTicker()
        return
    end

    if not isShaman then return end

    if event == "PLAYER_TOTEM_UPDATE" then
        refreshTotems()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Zone change invalidates snapshots.
        for _, st in pairs(slotState) do
            st.snapX, st.snapY, st.snapZone = nil, nil, nil
            st.fallbackToCL = false
        end
        refreshTotems()
        updateTicker()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        onCombatLogEvent(...)
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat: reset the silence timer for every tracked totem so
        -- a totem that has been idle for a while doesn't trip instantly on the pull.
        local now = GetTime()
        for _, st in pairs(slotState) do
            st.lastDamageTime = now
            st.oorFlagged = false
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat: clear any active OOR flags; the silence-check is now
        -- gated on combat state anyway.
        for _, st in pairs(slotState) do
            st.oorFlagged = false
        end
        -- Flush any pending combined message that would otherwise arrive after combat.
        pendingOOR = {}
        pendingSeen = {}
        pendingFlushAt = 0
    end
end)

-------------------------------------------------
-- Defaults + slash dispatch (called from TotemPing.lua)
-------------------------------------------------

function M.ApplyDefaults()
    TotemPingDB = TotemPingDB or {}
    TotemPingDB.damageTotemOOR = TotemPingDB.damageTotemOOR or {}
    local cfg = TotemPingDB.damageTotemOOR
    for k, v in pairs(DEFAULTS) do
        if cfg[k] == nil then cfg[k] = v end
    end
    if not VALID_METHODS[cfg.method] then cfg.method = DEFAULTS.method end
    -- One-time migration: v0.8.x shipped enabled=true and generated a lot of
    -- solo-play noise. Force-flip to false once, then never again.
    if not TotemPingDB._oorMigrationV0_9_2 then
        cfg.enabled = false
        TotemPingDB._oorMigrationV0_9_2 = true
    end
end

function M.UpdateTicker()
    updateTicker()
end

local function status()
    local d = db()
    emit("oor: enabled=" .. tostring(d.enabled) ..
        " method=" .. d.method ..
        " combine=" .. tostring(d.combineMessages) ..
        " window=" .. d.combineWindow .. "s" ..
        " silence=" .. d.combatLogSilenceSeconds .. "s" ..
        " slack=" .. d.positionSlackYards .. "y" ..
        " debug=" .. tostring(d.debug))
    local n = 0
    for slot, st in pairs(slotState) do
        n = n + 1
        emit(string.format("  slot %d: %s  oor=%s  fallbackCL=%s",
            slot, st.label, tostring(st.oorFlagged), tostring(st.fallbackToCL)))
    end
    if n == 0 then emit("  (no damage totems active)") end
end

-- Called from TotemPing.lua when user types "/tp oor ..."
function M.HandleSlash(rest)
    rest = (rest or ""):lower():match("^%s*(.-)%s*$") or ""
    local d = db()
    if not d then
        emit("oor: config not initialized")
        return
    end

    if rest == "" or rest == "status" then
        status()
        return
    end

    if rest == "toggle" then
        d.enabled = not d.enabled
        updateTicker()
        emit("oor: enabled=" .. tostring(d.enabled))
        return
    end

    local method = rest:match("^method%s+(%S+)$")
    if method then
        if VALID_METHODS[method] then
            d.method = method
            -- Reset snapshots + fallbacks so the new method starts clean.
            for _, st in pairs(slotState) do
                st.snapX, st.snapY, st.snapZone = nil, nil, nil
                st.fallbackToCL = false
                st.oorFlagged = false
            end
            emit("oor: method=" .. method)
        else
            emit("oor: invalid method (use combat_log | position | both)")
        end
        return
    end

    local combine = rest:match("^combine%s+(%S+)$")
    if combine then
        if combine == "on" or combine == "true" then
            d.combineMessages = true
        elseif combine == "off" or combine == "false" then
            d.combineMessages = false
        else
            emit("oor: combine on|off")
            return
        end
        emit("oor: combine=" .. tostring(d.combineMessages))
        return
    end

    local debug = rest:match("^debug%s+(%S+)$")
    if debug then
        if debug == "on" or debug == "true" then
            d.debug = true
        elseif debug == "off" or debug == "false" then
            d.debug = false
        else
            emit("oor: debug on|off")
            return
        end
        emit("oor: debug=" .. tostring(d.debug))
        return
    end

    emit("oor commands:")
    emit("  /tp oor                       - show status")
    emit("  /tp oor toggle                - enable/disable")
    emit("  /tp oor method combat_log|position|both")
    emit("  /tp oor combine on|off")
    emit("  /tp oor debug on|off")
end
