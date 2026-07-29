-- TotemPing
-- Warn when party members are out of range of your shaman totem buffs.
--
-- v0.1.0 scaffold: registers the addon, loads SavedVariables, prints hello.
-- Real behavior lands in the first feature PR.

local addonName = ...

local PREFIX = "|cff33b3ffTotemPing|r"

local function say(msg)
    print(PREFIX .. ": " .. msg)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        TotemPingDB = TotemPingDB or {}
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

SLASH_TOTEMPING1 = "/totemping"
SLASH_TOTEMPING2 = "/tp"
SlashCmdList["TOTEMPING"] = function(msg)
    say("hello — scaffold loaded. Real features coming soon.")
end
