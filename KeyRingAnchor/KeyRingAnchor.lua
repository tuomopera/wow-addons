local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    local k = KeyRingButton
    if not k then return end
    KeyRingAnchorDB = KeyRingAnchorDB or { "CENTER", "CENTER", 0, -100 }

    k:SetParent(UIParent)
    k:ClearAllPoints()
    k:SetPoint(KeyRingAnchorDB[1], UIParent, KeyRingAnchorDB[2], KeyRingAnchorDB[3], KeyRingAnchorDB[4])
    k:Show()
    k.Show = function() end  -- ponytail: stop Blizzard bag code re-hiding it

    -- shift-drag to move (secure frame: out of combat only)
    k:RegisterForDrag("LeftButton")
    k:SetMovable(true)
    k:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() and not InCombatLockdown() then self:StartMoving() end
    end)
    k:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        KeyRingAnchorDB = { p, rp, x, y }  -- ponytail: relativeTo is always UIParent
    end)
end)
