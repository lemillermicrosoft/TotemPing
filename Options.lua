-- Options
-- Blizzard-style Interface Options panel for TotemPing.
-- Uses the TBC 2.5.6 InterfaceOptions_AddCategory API (classic path, not Retail's
-- Settings.RegisterAddOnCategory).
--
-- Exposes:
--   * Master enable + chat mute + mode + sink
--   * Per-unit range indicator toggles (player + party1..4) + showLabel
--   * Damage-totem OOR: enabled, method, combine
--   * Debug
--
-- All controls read/write TotemPingDB directly so slash commands and the panel
-- stay in sync. Refresh() is called on Show and after any change to reflect
-- external mutations (e.g. slash command).

local addonName = ...
local Opt = {}
_G.TotemPing_Options = Opt

local PREFIX = "|cff33b3ffTotemPing|r"

-- Deferred build: we can't touch TotemPingDB / Interface API until ADDON_LOADED.
local panel                     -- root Frame
local ooPanel                   -- child "Damage Totem OOR" sub-panel
local controls = {}             -- { refresh = function() ... } entries

-------------------------------------------------
-- Widget helpers
-------------------------------------------------

local function makeHeader(parent, text, anchorTo, yOffset)
    local h = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    if anchorTo then
        h:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOffset or -16)
    else
        h:SetPoint("TOPLEFT", 16, -16)
    end
    h:SetText(text)
    return h
end

local function makeSubtext(parent, text, anchorTo)
    local s = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    s:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -8)
    s:SetWidth(560)
    s:SetJustifyH("LEFT")
    s:SetText(text)
    return s
end

local function makeCheckbox(parent, label, tooltip, getFn, setFn, anchorTo, xOff, yOff)
    local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", xOff or 0, yOff or -4)
    cb.Text:SetText(label)
    cb.tooltipText = label
    cb.tooltipRequirement = tooltip
    cb:SetScript("OnClick", function(self)
        setFn(self:GetChecked() and true or false)
    end)
    table.insert(controls, { refresh = function() cb:SetChecked(getFn() and true or false) end })
    return cb
end

local function makeDropdown(parent, label, tooltip, options, getFn, setFn, anchorTo, xOff, yOff)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(200, 40)
    container:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", xOff or 0, yOff or -12)

    local lbl = container:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", 20, 0)
    lbl:SetText(label)

    local dd = CreateFrame("Frame", "TotemPingOptDD_" .. label:gsub("%s", "_"), container, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", -20, -4)
    UIDropDownMenu_SetWidth(dd, 140)

    local function setSelected(value)
        setFn(value)
        UIDropDownMenu_SetSelectedValue(dd, value)
        local displayText = value
        for _, opt in ipairs(options) do
            if opt.value == value then displayText = opt.text; break end
        end
        UIDropDownMenu_SetText(dd, displayText)
    end

    UIDropDownMenu_Initialize(dd, function(self, level)
        for _, opt in ipairs(options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.text
            info.value = opt.value
            info.func = function() setSelected(opt.value) end
            info.checked = (getFn() == opt.value)
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    dd.tooltipText = label
    dd.tooltipRequirement = tooltip

    table.insert(controls, {
        refresh = function()
            local v = getFn()
            UIDropDownMenu_SetSelectedValue(dd, v)
            local displayText = v
            for _, opt in ipairs(options) do
                if opt.value == v then displayText = opt.text; break end
            end
            UIDropDownMenu_SetText(dd, displayText)
        end,
    })
    return container
end

-------------------------------------------------
-- Panel builders
-------------------------------------------------

local function refreshAll()
    for _, c in ipairs(controls) do c.refresh() end
end

local function buildMainPanel()
    panel = CreateFrame("Frame", "TotemPingOptionsPanel", UIParent)
    panel.name = "TotemPing"

    local title = makeHeader(panel, "TotemPing")
    local sub = makeSubtext(panel, "Warn when party members are out of range of your shaman totem buffs. Icons appear next to party frames. Chat output can be muted while keeping icons visible.", title)

    -- Master toggles
    local secGeneral = makeHeader(panel, "General", sub, -20)
    local cbEnabled = makeCheckbox(panel, "Enable TotemPing",
        "Master switch. Disables scanning entirely.",
        function() return TotemPingDB.enabled end,
        function(v) TotemPingDB.enabled = v end,
        secGeneral, 0, -8)

    local cbQuiet = makeCheckbox(panel, "Mute chat output (icons stay on)",
        "Silences all chat messages from TotemPing (party/whisper/self sink and damage-totem OOR notifications). Range indicator icons continue to work.",
        function() return TotemPingDB.chatQuiet end,
        function(v) TotemPingDB.chatQuiet = v end,
        cbEnabled, 0, -4)

    local ddMode = makeDropdown(panel, "Mode",
        "Auto: notify automatically after the grace window. Manual: only notify when you use /tp scan or a keybind.",
        {
            { text = "Auto", value = "auto" },
            { text = "Manual", value = "manual" },
        },
        function() return TotemPingDB.mode end,
        function(v) TotemPingDB.mode = v end,
        cbQuiet, -4, -12)

    local ddSink = makeDropdown(panel, "Chat sink",
        "Where TotemPing announces missing buffs. 'Off' = icons only, no chat. Ignored when Mute chat is on.",
        {
            { text = "Off (icons only)", value = "off" },
            { text = "Self", value = "self" },
            { text = "Party", value = "party" },
            { text = "Whisper", value = "whisper" },
        },
        function() return TotemPingDB.sink end,
        function(v) TotemPingDB.sink = v end,
        ddMode, 0, -8)

    -- Range indicator per-unit
    local secFrame = makeHeader(panel, "Range indicator icons", ddSink, -32)
    local sfSub = makeSubtext(panel, "Toggle the checkmark/X icons per party slot. Useful when a specific player is out of your party (e.g. off-tank you don't buff).", secFrame)

    TotemPingDB.frame = TotemPingDB.frame or {}
    TotemPingDB.frame.showUnits = TotemPingDB.frame.showUnits or {}

    local cbFrameEnabled = makeCheckbox(panel, "Show range indicator icons",
        "Turns the entire icon overlay on/off.",
        function() return TotemPingDB.frame.enabled end,
        function(v)
            TotemPingDB.frame.enabled = v
            if TotemPing_RangeIndicator and TotemPing_RangeIndicator.Refresh then
                TotemPing_RangeIndicator.Refresh()
            end
        end,
        sfSub, 0, -8)

    local cbShowLabel = makeCheckbox(panel, "Show missing-buff count on icon",
        "Draws the number of missing buffs in the bottom-right of the X icon.",
        function() return TotemPingDB.frame.showLabel end,
        function(v) TotemPingDB.frame.showLabel = v end,
        cbFrameEnabled, 0, -4)

    local perUnitHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    perUnitHeader:SetPoint("TOPLEFT", cbShowLabel, "BOTTOMLEFT", 0, -12)
    perUnitHeader:SetText("Per-slot visibility:")

    local prev = perUnitHeader
    local unitDefs = {
        { unit = "player",  label = "You (player)" },
        { unit = "party1",  label = "Party slot 1" },
        { unit = "party2",  label = "Party slot 2" },
        { unit = "party3",  label = "Party slot 3" },
        { unit = "party4",  label = "Party slot 4" },
    }
    for _, u in ipairs(unitDefs) do
        local cb = makeCheckbox(panel, u.label,
            "Hide the icon for " .. u.label .. " even when the frame is enabled.",
            function()
                if u.unit == "player" then
                    -- player has legacy showPlayer flag; treat both as "off" when either is false
                    if TotemPingDB.frame.showPlayer == false then return false end
                end
                return TotemPingDB.frame.showUnits[u.unit] ~= false
            end,
            function(v)
                TotemPingDB.frame.showUnits[u.unit] = v
                if u.unit == "player" then
                    TotemPingDB.frame.showPlayer = v
                end
            end,
            prev, 0, -2)
        prev = cb
    end

    -- Debug
    local cbDebug = makeCheckbox(panel, "Debug output",
        "Verbose logging for troubleshooting. Chat mute overrides this.",
        function() return TotemPingDB.debug end,
        function(v) TotemPingDB.debug = v end,
        prev, 0, -16)

    -- Panel hooks
    panel.refresh = refreshAll
    panel.okay = function() end
    panel.cancel = function() end
    panel.default = function() end

    panel:SetScript("OnShow", refreshAll)

    InterfaceOptions_AddCategory(panel)
end

local function buildOORPanel()
    ooPanel = CreateFrame("Frame", "TotemPingOptionsOORPanel", UIParent)
    ooPanel.name = "Damage Totem OOR"
    ooPanel.parent = "TotemPing"

    local title = makeHeader(ooPanel, "Damage Totem OOR")
    local sub = makeSubtext(ooPanel, "Warn when YOU move out of range of your own damage totems (Searing / Magma / Fire Nova). Chat mute silences these too.", title)

    TotemPingDB.damageTotemOOR = TotemPingDB.damageTotemOOR or {}

    local cbEnabled = makeCheckbox(ooPanel, "Enable damage-totem OOR notifications",
        nil,
        function() return TotemPingDB.damageTotemOOR.enabled end,
        function(v)
            TotemPingDB.damageTotemOOR.enabled = v
            if TotemPing_DamageOOR and TotemPing_DamageOOR.UpdateTicker then
                TotemPing_DamageOOR.UpdateTicker()
            end
        end,
        sub, 0, -8)

    local ddMethod = makeDropdown(ooPanel, "Detection method",
        "combat_log: silent damage log for N seconds. position: player moves outside totem radius. both: either trip fires.",
        {
            { text = "Combat log (default)", value = "combat_log" },
            { text = "Position",             value = "position" },
            { text = "Both",                 value = "both" },
        },
        function() return TotemPingDB.damageTotemOOR.method end,
        function(v) TotemPingDB.damageTotemOOR.method = v end,
        cbEnabled, -4, -12)

    local cbCombine = makeCheckbox(ooPanel, "Combine simultaneous notifications",
        "Merge multiple totems tripping within the combine window into one line.",
        function() return TotemPingDB.damageTotemOOR.combineMessages end,
        function(v) TotemPingDB.damageTotemOOR.combineMessages = v end,
        ddMethod, 4, -12)

    local cbDebug = makeCheckbox(ooPanel, "Debug output",
        nil,
        function() return TotemPingDB.damageTotemOOR.debug end,
        function(v) TotemPingDB.damageTotemOOR.debug = v end,
        cbCombine, 0, -4)

    ooPanel.refresh = refreshAll
    ooPanel.okay = function() end
    ooPanel.cancel = function() end
    ooPanel.default = function() end

    ooPanel:SetScript("OnShow", refreshAll)

    InterfaceOptions_AddCategory(ooPanel)
end

-------------------------------------------------
-- Public API
-------------------------------------------------

function Opt.Open()
    if not panel then return end
    -- InterfaceOptionsFrame_OpenToCategory has a known quirk in Classic where
    -- the first call doesn't select the category. Call twice.
    if InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

-------------------------------------------------
-- Bootstrap
-------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        -- TotemPing.lua's own ADDON_LOADED handler runs applyDefaults(); order
        -- of ADDON_LOADED handlers for the same addon is deterministic (registration
        -- order). This file loads after TotemPing.lua per the TOC, so DB defaults
        -- are already populated. Still guard for safety.
        TotemPingDB = TotemPingDB or {}
        if InterfaceOptions_AddCategory then
            buildMainPanel()
            buildOORPanel()
        end
        self:UnregisterEvent("ADDON_LOADED")
    end
end)
