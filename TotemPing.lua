-- TotemPing
-- Warn when party members are out of range of your shaman totem buffs.
--
-- MVP (issue #2): totem tracking via PLAYER_TOTEM_UPDATE + GetTotemInfo,
-- per-party scan on a repeating timer, grace window + per-target notify
-- cooldown, configurable notify sinks, auto/manual modes, and Bindings.xml
-- exposure for master toggle + manual scan.

local addonName = ...

local PREFIX = "|cff33b3ffTotemPing|r"

-------------------------------------------------
-- Config defaults
-------------------------------------------------

local DEFAULTS = {
    enabled               = true,
    mode                  = "auto",   -- "auto" | "manual"
    sink                  = "off",    -- "party" | "whisper" | "self" | "off" (default off -- range icons replace chat)
    chatQuiet             = false,    -- master mute: silences all chat output (sink + OOR emits + status prints from options changes)
    graceSeconds          = 4,
    notifyCooldownSeconds = 30,
    scanIntervalSeconds   = 1,
    debug                 = false,
}

local VALID_MODES = { auto = true, manual = true }
local VALID_SINKS = { party = true, whisper = true, self = true, off = true }

-------------------------------------------------
-- Known TBC totem-name -> buff-name map
-- (buff aura name shown on party members)
-------------------------------------------------

local TOTEM_BUFF_MAP = {
    -- Earth
    ["Strength of Earth Totem"] = "Strength of Earth",
    ["Stoneskin Totem"]         = "Stoneskin",
    ["Earthbind Totem"]         = nil, -- debuff, not a party buff
    ["Tremor Totem"]            = nil, -- passive fear break, no aura
    ["Stoneclaw Totem"]         = nil,
    -- Fire
    ["Searing Totem"]           = nil,
    ["Magma Totem"]             = nil,
    ["Fire Nova Totem"]         = nil,
    ["Flametongue Totem"]       = "Flametongue Totem",
    ["Frost Resistance Totem"]  = "Frost Resistance",
    ["Totem of Wrath"]          = "Totem of Wrath",
    -- Water
    ["Healing Stream Totem"]    = "Healing Stream",
    ["Mana Spring Totem"]       = "Mana Spring",
    ["Mana Tide Totem"]         = "Mana Tide",
    ["Fire Resistance Totem"]   = "Fire Resistance",
    ["Poison Cleansing Totem"]  = nil,
    ["Disease Cleansing Totem"] = nil,
    -- Air
    ["Grace of Air Totem"]      = "Grace of Air",
    ["Wrath of Air Totem"]      = "Wrath of Air",
    ["Windfury Totem"]          = "Windfury Totem",
    ["Tranquil Air Totem"]      = "Tranquil Air",
    ["Nature Resistance Totem"] = "Nature Resistance",
    ["Windwall Totem"]          = "Windwall Totem",
    ["Grounding Totem"]         = nil,
}

-------------------------------------------------
-- Utilities
-------------------------------------------------

local function say(msg)
    print(PREFIX .. ": " .. msg)
end

local function dbg(msg)
    if TotemPingDB and TotemPingDB.debug then say("debug: " .. msg) end
end

local function buffNameFor(totemName)
    if not totemName or totemName == "" then return nil end
    if TOTEM_BUFF_MAP[totemName] ~= nil then
        return TOTEM_BUFF_MAP[totemName] -- may be nil intentionally (no aura totem)
    end
    -- Unknown totem: strip trailing " Totem" and use as buff name guess.
    local guess = totemName:gsub("%s+Totem$", "")
    return guess
end

-------------------------------------------------
-- State
-------------------------------------------------

local isShaman = false
local activeTotems = {}  -- [buffName] = { totemName, slot, expires }
local firstMissedAt = {} -- [unit][buffName] = timestamp
local lastNotifiedAt = {} -- [unit][buffName] = timestamp
local scanAccumulator = 0

-------------------------------------------------
-- Totem tracking
-------------------------------------------------

local function refreshActiveTotems()
    local next_active = {}
    for slot = 1, 4 do
        local haveTotem, totemName, startTime, duration = GetTotemInfo(slot)
        if haveTotem and totemName and totemName ~= "" then
            local buff = buffNameFor(totemName)
            if buff then
                next_active[buff] = {
                    totemName = totemName,
                    slot      = slot,
                    expires   = (startTime or 0) + (duration or 0),
                }
            end
        end
    end

    -- Clear miss state for any buff that dropped out of active set.
    for buff in pairs(activeTotems) do
        if not next_active[buff] then
            for unit, buffs in pairs(firstMissedAt) do
                buffs[buff] = nil
            end
            for unit, buffs in pairs(lastNotifiedAt) do
                buffs[buff] = nil
            end
        end
    end

    activeTotems = next_active
    if TotemPingDB and TotemPingDB.debug then
        local count = 0
        for _ in pairs(activeTotems) do count = count + 1 end
        dbg("active totem buffs: " .. count)
    end
end

-------------------------------------------------
-- Party enumeration
-------------------------------------------------

local function iterPartyUnits()
    local units = { "player" }
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then table.insert(units, unit) end
    end
    return units
end

local function unitIsScanCandidate(unit)
    if not UnitExists(unit) then return false end
    if not UnitIsPlayer(unit) then return false end
    if UnitIsDeadOrGhost(unit) then return false end
    if UnitIsConnected and not UnitIsConnected(unit) then return false end
    return true
end

-------------------------------------------------
-- Aura check
-------------------------------------------------

local function unitHasOurBuff(unit, buffName)
    -- Scan HELPFUL auras until we find one whose name matches AND caster == "player".
    -- UnitAura(unit, name) form matches on name but doesn't disambiguate caster;
    -- we iterate indices to reliably read the caster field.
    for i = 1, 40 do
        local name, _, _, _, _, _, source = UnitAura(unit, i, "HELPFUL")
        if not name then return false end
        if name == buffName and source == "player" then return true end
    end
    return false
end

-------------------------------------------------
-- Notify sinks
-------------------------------------------------

local function sendToSink(message, whisperTarget)
    if TotemPingDB and TotemPingDB.chatQuiet then return end
    local sink = (TotemPingDB and TotemPingDB.sink) or "self"
    if sink == "off" then return end
    if sink == "self" then
        say(message)
    elseif sink == "party" then
        if GetNumPartyMembers and GetNumPartyMembers() > 0 then
            SendChatMessage(message, "PARTY")
        else
            -- Solo fallback: local echo so the user still sees something.
            say(message)
        end
    elseif sink == "whisper" then
        if whisperTarget and whisperTarget ~= "" then
            SendChatMessage(message, "WHISPER", nil, whisperTarget)
        else
            say(message)
        end
    end
end

-------------------------------------------------
-- Scan pass
-------------------------------------------------

-- Returns list of miss records: { { unit, unitName, buff, reason }, ... }
local function collectCurrentMisses()
    local misses = {}
    if not next(activeTotems) then return misses end

    for _, unit in ipairs(iterPartyUnits()) do
        if unitIsScanCandidate(unit) then
            local unitName = UnitName(unit)
            local inRange = true
            if UnitInRange and unit ~= "player" then
                local ok = UnitInRange(unit)
                if ok == false then inRange = false end
            end
            for buff, _info in pairs(activeTotems) do
                if not unitHasOurBuff(unit, buff) then
                    table.insert(misses, {
                        unit     = unit,
                        unitName = unitName,
                        buff     = buff,
                        reason   = inRange and "buff missing" or "out of range",
                    })
                end
            end
        end
    end
    return misses
end

-- Apply grace + cooldown to a fresh miss list; returns those that should be notified now.
local function applyGraceAndCooldown(misses, now, ignoreGrace)
    local db = TotemPingDB
    local grace = (db and db.graceSeconds) or DEFAULTS.graceSeconds
    local cd    = (db and db.notifyCooldownSeconds) or DEFAULTS.notifyCooldownSeconds

    -- Build set of currently-missing (unit,buff) so we can clear stale ones.
    local stillMissing = {}
    for _, m in ipairs(misses) do
        stillMissing[m.unit] = stillMissing[m.unit] or {}
        stillMissing[m.unit][m.buff] = true
    end

    -- Clear recovered entries.
    for unit, buffs in pairs(firstMissedAt) do
        for buff in pairs(buffs) do
            if not (stillMissing[unit] and stillMissing[unit][buff]) then
                buffs[buff] = nil
                if lastNotifiedAt[unit] then lastNotifiedAt[unit][buff] = nil end
            end
        end
    end

    local ready = {}
    for _, m in ipairs(misses) do
        firstMissedAt[m.unit] = firstMissedAt[m.unit] or {}
        firstMissedAt[m.unit][m.buff] = firstMissedAt[m.unit][m.buff] or now

        local firstAt = firstMissedAt[m.unit][m.buff]
        local waited  = now - firstAt
        if ignoreGrace or grace <= 0 or waited >= grace then
            lastNotifiedAt[m.unit] = lastNotifiedAt[m.unit] or {}
            local lastAt = lastNotifiedAt[m.unit][m.buff] or 0
            if (now - lastAt) >= cd then
                table.insert(ready, m)
                lastNotifiedAt[m.unit][m.buff] = now
            end
        end
    end
    return ready
end

local function formatAndSend(ready)
    if #ready == 0 then return end

    -- Group by sink target: party/self is one broadcast per pass; whisper is per-unit.
    local sink = (TotemPingDB and TotemPingDB.sink) or "self"
    if sink == "off" then return end

    if sink == "whisper" then
        -- Per-unit grouped message.
        local perUnit = {}
        for _, m in ipairs(ready) do
            perUnit[m.unitName] = perUnit[m.unitName] or { unit = m.unit, buffs = {}, reason = m.reason }
            table.insert(perUnit[m.unitName].buffs, m.buff)
        end
        for unitName, info in pairs(perUnit) do
            local msg = "[TotemPing] you're missing " .. table.concat(info.buffs, ", ") .. " (" .. info.reason .. ")"
            sendToSink(msg, unitName)
        end
        return
    end

    -- party/self: one coalesced message.
    local parts = {}
    for _, m in ipairs(ready) do
        table.insert(parts, m.unitName .. ": " .. m.buff .. " (" .. m.reason .. ")")
    end
    sendToSink("[TotemPing] missing buffs -> " .. table.concat(parts, "; "))
end

-- Public scan entrypoint. If `forceNotify` is true, ignore auto/manual mode and grace window.
local function runScan(forceNotify)
    if not (TotemPingDB and TotemPingDB.enabled) and not forceNotify then return end
    if not isShaman then return end

    refreshActiveTotems()
    local misses = collectCurrentMisses()
    local mode = (TotemPingDB and TotemPingDB.mode) or DEFAULTS.mode

    -- Feed the range-indicator UI regardless of sink/mode.
    if TotemPing_RangeIndicator and TotemPing_RangeIndicator.Update then
        local activeBuffCount = 0
        for _ in pairs(activeTotems) do activeBuffCount = activeBuffCount + 1 end

        local unitStatus = {}
        -- Seed all candidate units as OK; misses will flip them.
        for _, unit in ipairs(iterPartyUnits()) do
            if unitIsScanCandidate(unit) then
                unitStatus[unit] = { ok = true, missing = {}, reason = nil }
            end
        end
        for _, m in ipairs(misses) do
            local s = unitStatus[m.unit]
            if s then
                s.ok = false
                table.insert(s.missing, m.buff)
                s.reason = s.reason or m.reason
            end
        end
        TotemPing_RangeIndicator.Update(activeBuffCount, unitStatus)
    end

    if forceNotify then
        -- /tp scan or keybind: notify pass ignoring mode + grace.
        local ready = applyGraceAndCooldown(misses, GetTime(), true)
        formatAndSend(ready)
        return
    end

    -- Always update grace/cooldown state so recovered entries clear even in manual mode.
    local ready = applyGraceAndCooldown(misses, GetTime(), false)
    if mode == "auto" then
        formatAndSend(ready)
    end
end

-------------------------------------------------
-- Bindings (exposed to Bindings.xml)
-------------------------------------------------

BINDING_HEADER_TOTEMPING = "TotemPing"
BINDING_NAME_TOTEMPING_TOGGLE = "Toggle TotemPing on/off"
BINDING_NAME_TOTEMPING_SCAN   = "Force TotemPing scan + notify"

function TotemPing_Toggle()
    if not TotemPingDB then return end
    TotemPingDB.enabled = not TotemPingDB.enabled
    say("enabled: " .. tostring(TotemPingDB.enabled))
end

function TotemPing_ForceScan()
    if not isShaman then
        say("not a shaman; nothing to scan.")
        return
    end
    runScan(true)
end

-------------------------------------------------
-- Ticker
-------------------------------------------------

local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function(self, elapsed)
    scanAccumulator = scanAccumulator + elapsed
    local interval = (TotemPingDB and TotemPingDB.scanIntervalSeconds) or DEFAULTS.scanIntervalSeconds
    if interval <= 0 then interval = DEFAULTS.scanIntervalSeconds end
    if scanAccumulator >= interval then
        scanAccumulator = 0
        runScan(false)
    end
end)

local function updateTicker()
    if isShaman and TotemPingDB and TotemPingDB.enabled then
        scanAccumulator = 0
        ticker:Show()
    else
        ticker:Hide()
    end
end

-------------------------------------------------
-- Event handling
-------------------------------------------------

local function applyDefaults()
    TotemPingDB = TotemPingDB or {}
    for k, v in pairs(DEFAULTS) do
        if TotemPingDB[k] == nil then TotemPingDB[k] = v end
    end
    if not VALID_MODES[TotemPingDB.mode] then TotemPingDB.mode = DEFAULTS.mode end
    if not VALID_SINKS[TotemPingDB.sink] then TotemPingDB.sink = DEFAULTS.sink end
    if TotemPing_DamageOOR and TotemPing_DamageOOR.ApplyDefaults then
        TotemPing_DamageOOR.ApplyDefaults()
    end
    if TotemPing_RangeIndicator and TotemPing_RangeIndicator.ApplyDefaults then
        TotemPing_RangeIndicator.ApplyDefaults()
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("PLAYER_TOTEM_UPDATE")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("GROUP_ROSTER_UPDATE")
loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        applyDefaults()
        self:UnregisterEvent("ADDON_LOADED")
        return
    end

    if event == "PLAYER_LOGIN" then
        local _, class = UnitClass("player")
        isShaman = (class == "SHAMAN")
        if not isShaman then
            say("not a shaman; standing down. (You'll only see this once per session.)")
            return
        end
        refreshActiveTotems()
        updateTicker()
        return
    end

    if not isShaman then return end

    if event == "PLAYER_TOTEM_UPDATE" then
        refreshActiveTotems()
    elseif event == "PLAYER_ENTERING_WORLD" then
        refreshActiveTotems()
        updateTicker()
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Party composition changed; drop stale miss state for anyone who left.
        for unit in pairs(firstMissedAt) do
            if unit ~= "player" and not UnitExists(unit) then
                firstMissedAt[unit] = nil
                if lastNotifiedAt[unit] then lastNotifiedAt[unit] = nil end
            end
        end
    end
end)

-------------------------------------------------
-- Slash commands
-------------------------------------------------

local function statusLines()
    say("enabled: " .. tostring(TotemPingDB.enabled) ..
        " | mode: " .. TotemPingDB.mode ..
        " | sink: " .. TotemPingDB.sink ..
        " | quiet: " .. tostring(TotemPingDB.chatQuiet))
    say("grace: " .. TotemPingDB.graceSeconds .. "s" ..
        " | cooldown: " .. TotemPingDB.notifyCooldownSeconds .. "s" ..
        " | interval: " .. TotemPingDB.scanIntervalSeconds .. "s")
    if not isShaman then
        say("not a shaman -> passive.")
        return
    end
    local n = 0
    for buff, info in pairs(activeTotems) do
        n = n + 1
        say("  active: " .. info.totemName .. " -> " .. buff)
    end
    if n == 0 then say("  active: (none)") end
    local misses = 0
    for _, buffs in pairs(firstMissedAt) do
        for _ in pairs(buffs) do misses = misses + 1 end
    end
    say("current miss set size: " .. misses)
end

local function help()
    say("commands:")
    print("  /tp on | off              - toggle master")
    print("  /tp mode auto|manual")
    print("  /tp sink party|whisper|self|off  (default: off; range icons replace chat)")
    print("  /tp quiet                 - toggle master chat mute (icons keep working)")
    print("  /tp config                - open Blizzard interface options panel")
    print("  /tp frame show|hide|player|label|offset x y|size <px>|reset|status")
    print("  /tp grace <seconds>       - 0 disables grace window")
    print("  /tp cooldown <seconds>    - per-target re-notify cooldown")
    print("  /tp interval <seconds>    - scan tick interval")
    print("  /tp scan                  - force immediate scan + notify")
    print("  /tp status                - show config + active totems + miss set")
    print("  /tp debug                 - toggle verbose logging")
end

SLASH_TOTEMPING1 = "/totemping"
SLASH_TOTEMPING2 = "/tp"
SlashCmdList["TOTEMPING"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$") or ""
    if msg == "" or msg == "help" then
        statusLines()
        help()
        return
    end
    if msg == "on"  then TotemPingDB.enabled = true;  updateTicker(); say("enabled"); return end
    if msg == "off" then TotemPingDB.enabled = false; updateTicker(); say("disabled"); return end
    if msg == "scan" then TotemPing_ForceScan(); return end
    if msg == "quiet" then
        TotemPingDB.chatQuiet = not TotemPingDB.chatQuiet
        say("chatQuiet: " .. tostring(TotemPingDB.chatQuiet))
        return
    end
    if msg == "config" or msg == "options" then
        if TotemPing_Options and TotemPing_Options.Open then
            TotemPing_Options.Open()
        else
            say("options panel not loaded")
        end
        return
    end
    if msg == "status" then statusLines(); return end
    if msg == "debug" then
        TotemPingDB.debug = not TotemPingDB.debug
        say("debug: " .. tostring(TotemPingDB.debug))
        return
    end

    local oorRest = msg:match("^oor%s*(.-)$")
    if oorRest ~= nil then
        if TotemPing_DamageOOR and TotemPing_DamageOOR.HandleSlash then
            TotemPing_DamageOOR.HandleSlash(oorRest)
        else
            say("damage-totem OOR module not loaded")
        end
        return
    end

    local frameRest = msg:match("^frame%s*(.-)$")
    if frameRest ~= nil then
        if TotemPing_RangeIndicator and TotemPing_RangeIndicator.HandleSlash then
            TotemPing_RangeIndicator.HandleSlash(frameRest)
        else
            say("range-indicator module not loaded")
        end
        return
    end

    local mode = msg:match("^mode%s+(%S+)$")
    if mode then
        if VALID_MODES[mode] then
            TotemPingDB.mode = mode
            say("mode: " .. mode)
        else
            say("invalid mode; use auto or manual")
        end
        return
    end

    local sink = msg:match("^sink%s+(%S+)$")
    if sink then
        if VALID_SINKS[sink] then
            TotemPingDB.sink = sink
            say("sink: " .. sink)
        else
            say("invalid sink; use party, whisper, self, or off")
        end
        return
    end

    local grace = msg:match("^grace%s+(%d+%.?%d*)$")
    if grace then
        TotemPingDB.graceSeconds = tonumber(grace) or DEFAULTS.graceSeconds
        say("grace: " .. TotemPingDB.graceSeconds .. "s")
        return
    end

    local cd = msg:match("^cooldown%s+(%d+%.?%d*)$")
    if cd then
        TotemPingDB.notifyCooldownSeconds = tonumber(cd) or DEFAULTS.notifyCooldownSeconds
        say("cooldown: " .. TotemPingDB.notifyCooldownSeconds .. "s")
        return
    end

    local iv = msg:match("^interval%s+(%d+%.?%d*)$")
    if iv then
        local n = tonumber(iv) or DEFAULTS.scanIntervalSeconds
        if n <= 0 then n = DEFAULTS.scanIntervalSeconds end
        TotemPingDB.scanIntervalSeconds = n
        say("interval: " .. TotemPingDB.scanIntervalSeconds .. "s")
        return
    end

    say("unknown command: " .. msg)
    help()
end
