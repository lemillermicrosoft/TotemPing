-- RangeIndicator
-- Party-frame-anchored icons showing at-a-glance whether each party member
-- currently has all applicable player-cast totem buffs.
--
-- Design:
--   * One anchor Frame per party unit (player + party1..4), parented to
--     the corresponding party unit frame (Blizzard PartyMemberFrame1..4 or
--     ElvUI ElvUF_PartyGroup1UnitButton1..4 if present).
--   * The anchor holds a Texture (checkmark) and a FontString (buff-count).
--   * States:
--       "ok"      -> big green checkmark, tooltip "All totem buffs applied"
--       "miss"    -> red X, tooltip lists missing buff names + reason
--       "idle"    -> hidden (no player totems active OR player is not a shaman)
--   * Combat-safety: all :SetPoint / :SetParent calls are gated on
--     InCombatLockdown(). Any deferred re-anchor happens on PLAYER_REGEN_ENABLED.
--   * ElvUI-safety: we anchor to ElvUF frames if they exist; we never touch
--     ElvUI internals or restyle their frames.
--   * Cost: 5 frames (player + party1..4), textures/fontstrings; per-tick update
--     is O(5) state assignments.

local addonName = ...
local RI = {}
_G.TotemPing_RangeIndicator = RI

-------------------------------------------------
-- Textures (Blizzard-shipped, present in TBC 2.5.6)
-------------------------------------------------

local TEX_CHECK = "Interface\\RAIDFRAME\\ReadyCheck-Ready"
local TEX_CROSS = "Interface\\RAIDFRAME\\ReadyCheck-NotReady"
local TEX_IDLE  = "Interface\\RAIDFRAME\\ReadyCheck-Waiting"

-------------------------------------------------
-- Defaults (merged into TotemPingDB.frame on load)
-------------------------------------------------

local DEFAULTS = {
    enabled    = true,
    locked     = true,
    style      = "checkmark", -- "checkmark" | "icon" | "both"
    size       = 28,
    offsetX    = 6,           -- to the right of the party frame
    offsetY    = 0,
    alphaIdle  = 0.25,
    alphaOK    = 1.0,
    alphaMiss  = 1.0,
    showPlayer = true,
    showLabel  = false,       -- when true, shows small count of missing buffs
    showUnits  = nil,         -- optional per-unit visibility overrides; nil = show all
}

-------------------------------------------------
-- Unit -> anchor resolution
-------------------------------------------------

local UNITS = { "player", "party1", "party2", "party3", "party4" }

local function elvUIActive()
    return _G["ElvUI"] ~= nil or _G["ElvUF_Player"] ~= nil
end

local function frameChainVisible(f)
    while f do
        if f.IsShown and not f:IsShown() then return false end
        f = f.GetParent and f:GetParent() or nil
    end
    return true
end

local function findAnchorForUnit(unit)
    -- Prefer ElvUI's party unit buttons if the addon is loaded.
    -- ElvUI names its default party group buttons: ElvUF_PartyGroup1UnitButton1..5
    -- Some layouts use ElvUF_PartyGroup1UnitButton<N>, others just ElvUF_Party<N>.
    if unit == "player" then
        local candidates = { "ElvUF_Player", "PlayerFrame" }
        for _, name in ipairs(candidates) do
            local f = _G[name]
            if f and frameChainVisible(f) then return f, name end
        end
        return nil
    end
    local idx = tonumber(unit:match("party(%d+)"))
    if not idx then return nil end
    local candidates = {
        "ElvUF_PartyGroup1UnitButton" .. idx,
        "ElvUF_Party" .. idx,
        "ElvUF_PartyGroupUnitButton" .. idx,
    }
    for _, name in ipairs(candidates) do
        local f = _G[name]
        if f and frameChainVisible(f) then return f, name end
    end
    -- Blizzard fallback only if ElvUI isn't running (avoids anchoring to hidden default frames).
    if not elvUIActive() then
        local blizz = _G["PartyMemberFrame" .. idx]
        if blizz and frameChainVisible(blizz) then return blizz, "PartyMemberFrame" .. idx end
    end
    return nil
end

-------------------------------------------------
-- Icon widget factory
-------------------------------------------------

local icons = {}  -- [unit] = { frame=Frame, tex=Texture, label=FontString, state="ok|miss|idle", missing={...}, reason=string, anchoredTo=Frame }

local function ensureIcon(unit)
    if icons[unit] then return icons[unit] end
    local db = TotemPingDB and TotemPingDB.frame or DEFAULTS
    local size = db.size or DEFAULTS.size

    local f = CreateFrame("Frame", "TotemPingRangeIcon_" .. unit, UIParent)
    f:SetSize(size, size)
    f:SetFrameStrata("MEDIUM")
    f:Hide()
    f:EnableMouse(true)

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(f)
    tex:SetTexture(TEX_IDLE)

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, -2)
    label:SetText("")

    f:SetScript("OnEnter", function(self)
        local ent = icons[unit]
        if not ent then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("TotemPing")
        if ent.state == "ok" then
            GameTooltip:AddLine("|cff00ff00In range of all totem buffs|r", 1, 1, 1)
        elseif ent.state == "miss" then
            GameTooltip:AddLine("|cffff5555Missing:|r", 1, 1, 1)
            for _, buff in ipairs(ent.missing or {}) do
                GameTooltip:AddLine("  " .. buff, 1, 0.82, 0)
            end
            if ent.reason then
                GameTooltip:AddLine("(" .. ent.reason .. ")", 0.7, 0.7, 0.7)
            end
        else
            GameTooltip:AddLine("Idle (no player totems active)", 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    icons[unit] = {
        frame      = f,
        tex        = tex,
        label      = label,
        state      = "idle",
        missing    = {},
        reason     = nil,
        anchoredTo = nil,
    }
    return icons[unit]
end

-------------------------------------------------
-- Anchoring (combat-safe)
-------------------------------------------------

local pendingReanchor = false

local function applyAnchor(entry, unit)
    local db = TotemPingDB and TotemPingDB.frame or DEFAULTS
    if InCombatLockdown() then
        pendingReanchor = true
        return
    end
    local target, name = findAnchorForUnit(unit)
    entry.anchorName = name
    local f = entry.frame
    f:ClearAllPoints()
    if target then
        f:SetPoint("LEFT", target, "RIGHT", db.offsetX or DEFAULTS.offsetX, db.offsetY or DEFAULTS.offsetY)
        entry.anchoredTo = target
    else
        -- No party frame yet; park off-screen and hide.
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        entry.anchoredTo = nil
        f:Hide()
    end
end

local function reanchorAll()
    for _, unit in ipairs(UNITS) do
        local entry = icons[unit]
        if entry then applyAnchor(entry, unit) end
    end
    pendingReanchor = false
end

-------------------------------------------------
-- State application
-------------------------------------------------

local function setState(unit, newState, missing, reason)
    local entry = ensureIcon(unit)
    local db = TotemPingDB and TotemPingDB.frame or DEFAULTS
    entry.state   = newState
    entry.missing = missing or {}
    entry.reason  = reason

    if newState == "ok" then
        entry.tex:SetTexture(TEX_CHECK)
        entry.tex:SetVertexColor(0.3, 1.0, 0.3)
        entry.frame:SetAlpha(db.alphaOK or DEFAULTS.alphaOK)
        entry.label:SetText("")
    elseif newState == "miss" then
        entry.tex:SetTexture(TEX_CROSS)
        entry.tex:SetVertexColor(1.0, 0.3, 0.3)
        entry.frame:SetAlpha(db.alphaMiss or DEFAULTS.alphaMiss)
        if db.showLabel and #entry.missing > 0 then
            entry.label:SetText(tostring(#entry.missing))
        else
            entry.label:SetText("")
        end
    else -- idle
        entry.tex:SetTexture(TEX_IDLE)
        entry.tex:SetVertexColor(1, 1, 1)
        entry.frame:SetAlpha(db.alphaIdle or DEFAULTS.alphaIdle)
        entry.label:SetText("")
    end
end

local function showOrHide(unit, shouldShow)
    local entry = ensureIcon(unit)
    if not entry.anchoredTo then
        applyAnchor(entry, unit)
    end
    if shouldShow and entry.anchoredTo then
        entry.frame:Show()
    else
        entry.frame:Hide()
    end
end

-------------------------------------------------
-- Receiver-mode state (issue #27)
--
-- Non-shaman party members don't drive RI.Update (TotemPing.lua's scan loop
-- early-returns for non-shamans). Instead, Comms.lua computes which of the
-- party shaman's broadcast buffs are missing from the local player and pushes
-- that here. We show the "player" icon anchored to the player frame with the
-- same ok/miss/idle visual language so hunters/etc. get parity with shamans.
--
-- receiverActive is true whenever we have at least one known remote shaman;
-- when it's true and Update() is NOT driving state (i.e. we're not a shaman),
-- SetReceiverStatus owns the player icon.
-------------------------------------------------

local receiverActive = false
local receiverMissing = {}
local localUpdateActive = false  -- true once RI.Update has driven state (i.e., we're the local shaman)

local function applyReceiverPlayerIcon()
    -- If the local shaman scan is driving Update(), let it own the player icon.
    if localUpdateActive then return end
    local db = TotemPingDB and TotemPingDB.frame or DEFAULTS
    if not db.enabled then
        if icons.player then icons.player.frame:Hide() end
        return
    end
    if not db.showPlayer then
        if icons.player then icons.player.frame:Hide() end
        return
    end
    local perUnitHidden = db.showUnits and db.showUnits.player == false
    if perUnitHidden then
        if icons.player then icons.player.frame:Hide() end
        return
    end
    if not receiverActive then
        setState("player", "idle")
        showOrHide("player", false)
        return
    end
    if #receiverMissing == 0 then
        setState("player", "ok")
        showOrHide("player", true)
    else
        setState("player", "miss", receiverMissing, "out of range")
        showOrHide("player", true)
    end
end

-- Called by Comms.lua receiver scan.
--   missing == nil  -> no known remote shamans; hide player icon (idle).
--   missing == {}   -> in range of all remote-shaman buffs; show ok.
--   missing == {..} -> list of "<buff> (<shaman>)" strings; show miss.
function RI.SetReceiverStatus(missing)
    if missing == nil then
        receiverActive = false
        receiverMissing = {}
    else
        receiverActive = true
        receiverMissing = missing
    end
    applyReceiverPlayerIcon()
end

-------------------------------------------------
-- Public: called from TotemPing.lua on each scan
--
-- activeBuffCount : number of active player totem buffs (0 = idle mode)
-- unitStatus      : table [unit] = { ok=bool, missing={buffName,...}, reason=string }
--                   where `unit` is one of UNITS. Missing entries -> hidden.
-------------------------------------------------

function RI.Update(activeBuffCount, unitStatus)
    localUpdateActive = true
    local db = TotemPingDB and TotemPingDB.frame or DEFAULTS
    if not db.enabled then
        for _, unit in ipairs(UNITS) do
            if icons[unit] then icons[unit].frame:Hide() end
        end
        return
    end

    -- No active totems -> idle everywhere.
    if not activeBuffCount or activeBuffCount == 0 then
        for _, unit in ipairs(UNITS) do
            setState(unit, "idle")
            showOrHide(unit, false)
        end
        return
    end

    for _, unit in ipairs(UNITS) do
        local perUnitHidden = db.showUnits and db.showUnits[unit] == false
        if (unit == "player" and not db.showPlayer) or perUnitHidden then
            if icons[unit] then icons[unit].frame:Hide() end
        else
            local s = unitStatus and unitStatus[unit]
            if not s then
                setState(unit, "idle")
                showOrHide(unit, false)
            elseif s.ok then
                setState(unit, "ok")
                showOrHide(unit, true)
            else
                setState(unit, "miss", s.missing, s.reason)
                showOrHide(unit, true)
            end
        end
    end
end

-------------------------------------------------
-- Defaults + slash handling (called from TotemPing.lua)
-------------------------------------------------

function RI.ApplyDefaults()
    TotemPingDB = TotemPingDB or {}
    TotemPingDB.frame = TotemPingDB.frame or {}
    for k, v in pairs(DEFAULTS) do
        if TotemPingDB.frame[k] == nil then TotemPingDB.frame[k] = v end
    end
    TotemPingDB.frame.showUnits = TotemPingDB.frame.showUnits or {
        player = true, party1 = true, party2 = true, party3 = true, party4 = true,
    }
    for _, u in ipairs(UNITS) do
        if TotemPingDB.frame.showUnits[u] == nil then
            TotemPingDB.frame.showUnits[u] = true
        end
    end
end

-- Expose refresh so the options panel can re-anchor / re-show after changes.
function RI.Refresh()
    reanchorAll()
end

local function say(msg)
    print("|cff33b3ffTotemPing|r: " .. msg)
end

function RI.HandleSlash(rest)
    RI.ApplyDefaults()
    local db = TotemPingDB.frame
    rest = (rest or ""):match("^%s*(.-)%s*$") or ""

    if rest == "" or rest == "status" then
        say("frame: enabled=" .. tostring(db.enabled) ..
            " locked=" .. tostring(db.locked) ..
            " size=" .. db.size ..
            " offset=(" .. db.offsetX .. "," .. db.offsetY .. ")" ..
            " showPlayer=" .. tostring(db.showPlayer) ..
            " showLabel=" .. tostring(db.showLabel))
        return
    end

    if rest == "show" or rest == "on" then
        db.enabled = true
        say("frame enabled")
        reanchorAll()
        -- If we're in receiver mode (non-shaman party member), re-drive the
        -- player icon so /tp frame show actually surfaces something instead of
        -- waiting for the next Comms tick. See issue #27.
        applyReceiverPlayerIcon()
        return
    end
    if rest == "hide" or rest == "off" then
        db.enabled = false
        say("frame disabled (icons hidden)")
        for _, unit in ipairs(UNITS) do
            if icons[unit] then icons[unit].frame:Hide() end
        end
        return
    end
    if rest == "reset" then
        for k, v in pairs(DEFAULTS) do db[k] = v end
        say("frame settings reset to defaults")
        reanchorAll()
        applyReceiverPlayerIcon()
        return
    end
    if rest == "player" then
        db.showPlayer = not db.showPlayer
        say("frame showPlayer=" .. tostring(db.showPlayer))
        return
    end
    if rest == "label" then
        db.showLabel = not db.showLabel
        say("frame showLabel=" .. tostring(db.showLabel))
        return
    end

    local ox, oy = rest:match("^offset%s+(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)$")
    if ox and oy then
        db.offsetX = tonumber(ox) or DEFAULTS.offsetX
        db.offsetY = tonumber(oy) or DEFAULTS.offsetY
        say("frame offset=(" .. db.offsetX .. "," .. db.offsetY .. ")")
        reanchorAll()
        return
    end

    local sz = rest:match("^size%s+(%d+%.?%d*)$")
    if sz then
        local n = tonumber(sz) or DEFAULTS.size
        if n < 8 then n = 8 end
        if n > 128 then n = 128 end
        db.size = n
        for _, unit in ipairs(UNITS) do
            if icons[unit] then icons[unit].frame:SetSize(n, n) end
        end
        say("frame size=" .. db.size)
        return
    end

    if rest == "debug" then
        say("anchor debug:")
        say("  ElvUI detected: " .. tostring(elvUIActive()))
        say("  receiverActive=" .. tostring(receiverActive) ..
            " receiverMissing=" .. tostring(#receiverMissing))
        for _, unit in ipairs(UNITS) do
            local target, name = findAnchorForUnit(unit)
            local entry = icons[unit]
            local iconShown = entry and entry.frame:IsShown() or false
            local iconAnchor = entry and entry.anchorName or "none"
            say(string.format("  %s: resolved=%s (%s) iconShown=%s cachedAnchor=%s",
                unit,
                tostring(name or "<none>"),
                target and (target:IsShown() and "visible" or "hidden") or "<nil>",
                tostring(iconShown),
                tostring(iconAnchor)))
        end
        return
    end

    if rest == "rescan" then
        reanchorAll()
        say("re-anchored all units")
        return
    end

    say("frame commands: show | hide | player | label | offset x y | size <px> | reset | status | debug | rescan")
end

-------------------------------------------------
-- Event wiring: re-anchor on party changes and combat exit
-------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("UNIT_PORTRAIT_UPDATE")
events:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if pendingReanchor then reanchorAll() end
        return
    end
    -- Any roster / world-load / portrait change: re-resolve anchors.
    if InCombatLockdown() then
        pendingReanchor = true
        return
    end
    reanchorAll()
end)

-- Low-frequency re-anchor sweep: if any icon's anchor is nil or invisible,
-- try to resolve again. Handles ElvUI's lazy frame creation on party join.
local sweepTicker = C_Timer and C_Timer.NewTicker and C_Timer.NewTicker(2, function()
    if InCombatLockdown() then return end
    local db = TotemPingDB and TotemPingDB.frame
    if not db or not db.enabled then return end
    for _, unit in ipairs(UNITS) do
        local entry = icons[unit]
        if entry then
            local needs = (not entry.anchoredTo) or (entry.anchoredTo.IsShown and not entry.anchoredTo:IsShown())
            if needs then
                applyAnchor(entry, unit)
            end
        end
    end
end) or nil
