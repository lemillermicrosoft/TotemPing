-- Comms
-- Cross-client party comms so non-shaman party members can see whether they
-- have the shaman's active totem buffs and get an OOR indicator.
--
-- Wire protocol (versioned):
--
--   Prefix:  "TotemPing"  (registered via C_ChatInfo.RegisterAddonMessagePrefix)
--   Channel: "PARTY" (or "RAID" when in a raid)
--
--   Message formats:
--
--     "V1|STATE|<shamanName>|<buff1>,<buff2>,...|<timestamp>"
--         Broadcaster announcing current active totem buff set.
--         <buff1>,<buff2>,... may be empty when no totems are up.
--
--     "V1|HELLO|<myName>"
--         Anyone (usually a receiver) asking "who's shaman-ing?"; shamans
--         respond with a STATE message.
--
--   Anything not starting with "V1|" is ignored (forward compat).
--
-- Behavior:
--
--   Broadcaster side (a shaman running TotemPing):
--     * On activeTotems change, send STATE. Throttled to 1 msg / 2s max.
--     * On HELLO, send STATE immediately (throttle bypass).
--     * On PLAYER_ENTERING_WORLD / GROUP_ROSTER_UPDATE, send STATE once.
--
--   Receiver side (any TotemPing user, incl. shamans):
--     * On STATE, cache remoteActiveBuffs[shamanName] = { buffNames..., updated=t }.
--       Entries older than 30s are considered stale and dropped.
--     * On PLAYER_ENTERING_WORLD, broadcast HELLO once.
--     * Every 1s, run receiver scan: for each known shaman, check UnitAura on
--       "player" for each broadcasted buff; if missing, we're OOR of that shaman.
--     * Feed result to RangeIndicator via a new "receiver-mode" update that only
--       shows the player icon.
--
-- SavedVariables:
--   TotemPingDB.comms = { enabled = true, showAsReceiver = true, debug = false }

local addonName = ...
local Comms = {}
_G.TotemPing_Comms = Comms

local PREFIX = "|cff33b3ffTotemPing|r"
local ADDON_PREFIX = "TotemPing"
local PROTOCOL = "V1"

local DEFAULTS = {
    enabled        = true,
    showAsReceiver = true,
    debug          = false,
}

local BROADCAST_MIN_INTERVAL = 2.0   -- seconds between STATE broadcasts (throttle)
local REMOTE_STALE_AFTER     = 30.0  -- drop remote entries older than this
local RECEIVER_SCAN_INTERVAL = 1.0

-------------------------------------------------
-- State
-------------------------------------------------

local isShaman           = false
local lastBroadcastAt    = 0
local pendingBroadcast   = false
local remoteState        = {}  -- [shamanName] = { buffs = {name=true,...}, updated = time, rawList = {..} }
local receiverIconEntry  = nil -- lazy player-frame icon for receiver mode

-------------------------------------------------
-- Utilities
-------------------------------------------------

local function say(msg)
    print(PREFIX .. ": " .. msg)
end

local function dbg(msg)
    local d = TotemPingDB and TotemPingDB.comms and TotemPingDB.comms.debug
    if d then say("comms: " .. msg) end
end

local function db()
    TotemPingDB = TotemPingDB or {}
    TotemPingDB.comms = TotemPingDB.comms or {}
    return TotemPingDB.comms
end

local function currentChannel()
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    if GetNumPartyMembers and GetNumPartyMembers() > 0 then return "PARTY" end
    return nil
end

local function sendAddon(payload)
    local ch = currentChannel()
    if not ch then
        dbg("skip send: not in group; payload=" .. payload)
        return false
    end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(ADDON_PREFIX, payload, ch)
    elseif SendAddonMessage then
        SendAddonMessage(ADDON_PREFIX, payload, ch)
    else
        dbg("no addon-message API available")
        return false
    end
    dbg("sent [" .. ch .. "] " .. payload)
    return true
end

-------------------------------------------------
-- Broadcaster (shaman)
-------------------------------------------------

local function buildStateMessage(buffList)
    local myName = UnitName("player") or "?"
    local buffs  = table.concat(buffList or {}, ",")
    return PROTOCOL .. "|STATE|" .. myName .. "|" .. buffs .. "|" .. tostring(math.floor(GetTime()))
end

-- Called by TotemPing.lua whenever activeTotems changes.
function Comms.NotifyActiveBuffs(buffList)
    local cfg = db()
    if not cfg.enabled then return end
    if not isShaman then return end
    local now = GetTime()
    if now - lastBroadcastAt < BROADCAST_MIN_INTERVAL then
        pendingBroadcast = true
        return
    end
    lastBroadcastAt = now
    pendingBroadcast = false
    sendAddon(buildStateMessage(buffList or {}))
end

-- Called on HELLO or explicit force; bypasses throttle.
local function forceBroadcastFromActive()
    local buffList = {}
    if _G.TotemPing_GetActiveBuffList then
        buffList = _G.TotemPing_GetActiveBuffList() or {}
    end
    lastBroadcastAt = GetTime()
    pendingBroadcast = false
    sendAddon(buildStateMessage(buffList))
end

-------------------------------------------------
-- Receiver
-------------------------------------------------

local function parseStateMessage(msg)
    -- V1|STATE|<name>|<b1,b2,...>|<ts>
    local proto, kind, name, buffs, ts = strsplit("|", msg)
    if proto ~= PROTOCOL or kind ~= "STATE" or not name then return nil end
    local list = {}
    if buffs and buffs ~= "" then
        for b in string.gmatch(buffs, "([^,]+)") do
            table.insert(list, b)
        end
    end
    return name, list, tonumber(ts) or GetTime()
end

local function unitHasBuffNamed(unit, buffName)
    for i = 1, 40 do
        local n = UnitAura(unit, i, "HELPFUL")
        if not n then return false end
        if n == buffName then return true end
    end
    return false
end

local function ensureReceiverIcon()
    if receiverIconEntry then return receiverIconEntry end
    -- Reuse the RangeIndicator's icon slot for "player" by delegating; but we
    -- want a distinct icon that reflects RECEIVER state (buffs missing from us
    -- due to being OOR of remote shaman's totems). If TotemPing_RangeIndicator
    -- exposes an entry for "player" we piggyback via its Update path. Otherwise
    -- we build a lightweight icon here.
    local RI = _G.TotemPing_RangeIndicator
    if RI and RI.SetReceiverStatus then
        receiverIconEntry = { via = "rangeIndicator" }
    else
        -- Minimal fallback icon anchored to player frame.
        local f = CreateFrame("Frame", "TotemPingReceiverIcon", UIParent)
        f:SetSize(24, 24)
        local tex = f:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(f)
        f:Hide()
        local anchor = _G["ElvUF_Player"] or _G["PlayerFrame"]
        if anchor then
            f:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
        else
            f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
        receiverIconEntry = { via = "self", frame = f, tex = tex }
    end
    return receiverIconEntry
end

local function updateReceiverIcon(missing)
    local ent = ensureReceiverIcon()
    if ent.via == "rangeIndicator" then
        _G.TotemPing_RangeIndicator.SetReceiverStatus(missing)
        return
    end
    local f = ent.frame
    if #missing > 0 then
        ent.tex:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
        ent.tex:SetVertexColor(1, 0.3, 0.3)
        f:Show()
    else
        ent.tex:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
        ent.tex:SetVertexColor(0.3, 1, 0.3)
        f:Show()
    end
end

local function hideReceiverIcon()
    local ent = receiverIconEntry
    if not ent then return end
    if ent.via == "rangeIndicator" and _G.TotemPing_RangeIndicator and _G.TotemPing_RangeIndicator.SetReceiverStatus then
        _G.TotemPing_RangeIndicator.SetReceiverStatus(nil)
    elseif ent.frame then
        ent.frame:Hide()
    end
end

local function receiverScan()
    local cfg = db()
    if not cfg.enabled or not cfg.showAsReceiver then
        hideReceiverIcon()
        return
    end
    -- Drop stale entries.
    local now = GetTime()
    for name, entry in pairs(remoteState) do
        if now - (entry.updated or 0) > REMOTE_STALE_AFTER then
            remoteState[name] = nil
        end
    end
    -- If no known shamans, hide.
    local anyKnown = false
    local unionMissing = {}
    for name, entry in pairs(remoteState) do
        anyKnown = true
        for _, buff in ipairs(entry.rawList) do
            if not unitHasBuffNamed("player", buff) then
                table.insert(unionMissing, buff .. " (" .. name .. ")")
            end
        end
    end
    if not anyKnown then
        hideReceiverIcon()
        return
    end
    updateReceiverIcon(unionMissing)
end

-------------------------------------------------
-- Event wiring
-------------------------------------------------

local function onAddonMessage(prefix, msg, channel, sender)
    if prefix ~= ADDON_PREFIX then return end
    if not msg or msg == "" then return end
    local proto = strsplit("|", msg)
    if proto ~= PROTOCOL then return end
    local _, kind = strsplit("|", msg)
    if kind == "STATE" then
        local name, list, ts = parseStateMessage(msg)
        if not name then return end
        -- Ignore our own broadcasts.
        if name == UnitName("player") then return end
        remoteState[name] = { rawList = list, updated = GetTime() }
        dbg("rx STATE from " .. name .. " buffs=" .. #list)
    elseif kind == "HELLO" then
        if isShaman then forceBroadcastFromActive() end
    end
end

local function refreshIsShaman()
    local _, class = UnitClass("player")
    isShaman = (class == "SHAMAN")
    dbg("class detected: " .. tostring(class) .. " isShaman=" .. tostring(isShaman))
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        onAddonMessage(...)
        return
    end
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        refreshIsShaman()
        -- Register prefix (idempotent).
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
        end
        -- Send HELLO so any shamans in party immediately respond with STATE.
        C_Timer.After(1.5, function()
            local cfg = db()
            if not cfg.enabled then return end
            sendAddon(PROTOCOL .. "|HELLO|" .. (UnitName("player") or "?"))
            if isShaman then forceBroadcastFromActive() end
        end)
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        if isShaman then
            -- New party member -> re-announce state.
            forceBroadcastFromActive()
        end
    end
end)

-- Receiver scan ticker.
local scanTicker = C_Timer and C_Timer.NewTicker and C_Timer.NewTicker(RECEIVER_SCAN_INTERVAL, function()
    if not db().enabled then return end
    receiverScan()
    -- Flush pending broadcast if throttle window elapsed.
    if isShaman and pendingBroadcast and (GetTime() - lastBroadcastAt >= BROADCAST_MIN_INTERVAL) then
        forceBroadcastFromActive()
    end
end) or nil

-------------------------------------------------
-- Defaults + slash
-------------------------------------------------

function Comms.ApplyDefaults()
    TotemPingDB = TotemPingDB or {}
    TotemPingDB.comms = TotemPingDB.comms or {}
    for k, v in pairs(DEFAULTS) do
        if TotemPingDB.comms[k] == nil then TotemPingDB.comms[k] = v end
    end
end

function Comms.HandleSlash(rest)
    Comms.ApplyDefaults()
    local cfg = db()
    rest = (rest or ""):match("^%s*(.-)%s*$") or ""
    if rest == "" or rest == "status" then
        say(string.format("comms: enabled=%s showAsReceiver=%s isShaman=%s knownShamans=%d",
            tostring(cfg.enabled), tostring(cfg.showAsReceiver), tostring(isShaman),
            (function() local n=0 for _ in pairs(remoteState) do n=n+1 end return n end)()))
        for name, entry in pairs(remoteState) do
            say("  " .. name .. ": " .. table.concat(entry.rawList, ", "))
        end
        return
    end
    if rest == "on" then cfg.enabled = true;  say("comms enabled");  return end
    if rest == "off" then cfg.enabled = false; say("comms disabled"); return end
    if rest == "debug" then cfg.debug = not cfg.debug; say("comms debug=" .. tostring(cfg.debug)); return end
    if rest == "hello" then sendAddon(PROTOCOL .. "|HELLO|" .. (UnitName("player") or "?")); say("sent HELLO"); return end
    if rest == "receiver" then cfg.showAsReceiver = not cfg.showAsReceiver; say("comms showAsReceiver=" .. tostring(cfg.showAsReceiver)); return end
    say("comms commands: status | on | off | debug | hello | receiver")
end
