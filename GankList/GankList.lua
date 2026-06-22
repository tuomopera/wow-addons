-- GankList: remember who ganked you, sync to 1-2 trusted partners.
local PREFIX = "GankList"
local DEATH_WINDOW = 12 -- seconds: hostile player damage this recent at death = the ganker

local me = UnitName("player")
local playerGUID -- set on login

-- lastHit: most recent hostile-player damage taken { name=, t= }
local lastHit = nil
local refreshUI -- forward decl: used by event handler, defined in UI section below

local function ensureDB()
	GankListDB = GankListDB or {}
	GankListDB.gankers = GankListDB.gankers or {}   -- [name] = { count, last, zone, by }
	GankListDB.partners = GankListDB.partners or {}  -- list of character names
	GankListDB.pending = GankListDB.pending or {}    -- [name] = epoch of first kill (not yet a confirmed ganker)
	return GankListDB
end

-- Validate a player name. Returns the cleaned name, or nil if it can't be one.
-- Strips "|" (chat color/hyperlink/texture escapes - anti-injection), and rejects
-- digits/whitespace in the character-name part. Accented letters (ä, é, ...) pass.
local function cleanName(s)
	s = tostring(s or ""):gsub("|", ""):gsub('"', ""):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" or #s > 40 then return nil end
	local base = s:match("^([^-]+)") -- name part before an optional -Realm
	if not base or base:find("%d") or base:find("%s") then return nil end
	return s
end

local function record(name, zone, by, level)
	local db = ensureDB()
	local g = db.gankers[name]
	if not g then
		g = { count = 0, by = by }
		db.gankers[name] = g
	end
	g.count = g.count + 1
	g.last = time() -- epoch; formatted to each viewer's local time at display
	g.zone = zone or g.zone
	if level ~= nil then g.level = level end
	return g
end

-- Format a known level for display ("Lv60", "??" for skull, "" if unknown).
local function fmtLvl(lvl)
	if lvl == -1 then return "??" elseif type(lvl) == "number" and lvl > 0 then return "Lv" .. lvl end
	return ""
end

-- Format a stored timestamp in the viewer's local time (epoch number, or legacy string).
local function fmtTime(t)
	return type(t) == "number" and date("%Y-%m-%d %H:%M", t) or (t or "?")
end

-- ---- sync ----------------------------------------------------------------
local function send(name)
	local g = ensureDB().gankers[name]
	if not g then return end
	local payload = table.concat({ "G", name, g.count, g.zone or "", g.by or me, g.last or time() }, "\t")
	for _, partner in ipairs(ensureDB().partners) do
		C_ChatInfo.SendAddonMessage(PREFIX, payload, "WHISPER", partner)
	end
end

local function sendAll()
	for name in pairs(ensureDB().gankers) do send(name) end
end

-- Broadcast a forgive (removal) request to partners.
local function sendRemove(name)
	local payload = "R\t" .. name
	for _, partner in ipairs(ensureDB().partners) do
		C_ChatInfo.SendAddonMessage(PREFIX, payload, "WHISPER", partner)
	end
end

local function onReceive(payload, sender)
	local kind, name, count, zone, by, last = strsplit("\t", payload)

	if kind == "PING" then -- connectivity test: reply so the sender knows it round-tripped
		print("|cff40ff40GankList:|r ping from " .. (sender or "?") .. " - you two are synced \226\156\147")
		for _, p in ipairs(ensureDB().partners) do C_ChatInfo.SendAddonMessage(PREFIX, "PONG", "WHISPER", p) end
		return
	elseif kind == "PONG" then
		print("|cff40ff40GankList:|r " .. (sender or "a friend") .. " got your ping - sync works \226\156\147")
		return
	end

	name = cleanName(name) -- reject junk / strip injection from untrusted partner data
	if not name then return end

	if kind == "R" then -- partner forgave someone
		local db = ensureDB()
		if not db.gankers[name] then return end -- not on our list, nothing to do
		if db.autoAccept then
			db.gankers[name] = nil
			if refreshUI then refreshUI() end
			print("|cffff4040GankList:|r " .. (sender or "a friend") .. " forgave " .. name .. " (auto-accepted)")
		else
			StaticPopup_Show("GANKLIST_FORGIVE", sender or "A friend", name, { name = name })
		end
		return
	end

	if kind ~= "G" then return end
	count = math.min(tonumber(count) or 1, 100000) -- clamp absurd values
	zone = zone and zone:gsub("|", ""):sub(1, 60) or nil
	by = by and by:gsub("|", ""):sub(1, 40) or nil
	last = math.min(tonumber(last) or time(), time() + 86400) -- epoch; reject far-future stamps
	local db = ensureDB()
	local g = db.gankers[name]
	if not g then
		db.gankers[name] = { count = count, last = last, zone = zone, by = by }
	else
		g.count = math.max(g.count, count) -- avoid double-counting on re-sync
		g.zone = g.zone or zone
		if type(g.last) ~= "number" or last > g.last then g.last = last end
	end
	if refreshUI then refreshUI() end
end

-- Cache the level of any hostile player we see, so we can judge a kill as a gank
-- (UnitLevel isn't in the combat log, so we grab it from units we can inspect).
local levelSeen = {} -- name -> level (-1 = skull/"??", far above you)
local function noteUnit(unit)
	if UnitExists(unit) and UnitIsPlayer(unit) and UnitCanAttack("player", unit) then
		local n = UnitName(unit)
		if n then levelSeen[n] = UnitLevel(unit) end
	end
end

-- At death, grab levels of everyone currently nameplated/targeted - catches the
-- ganker still standing on your corpse even if you never saw them before.
local function captureNearbyLevels()
	if C_NamePlate and C_NamePlate.GetNamePlates then
		for _, p in ipairs(C_NamePlate.GetNamePlates()) do
			if p.namePlateUnitToken then noteUnit(p.namePlateUnitToken) end
		end
	end
	noteUnit("target"); noteUnit("mouseover")
end

-- Find a Wanted entry by name, matching the base name too (stored key may have -Realm).
local function findGanker(db, name)
	if db.gankers[name] then return db.gankers[name] end
	local base = name:match("^[^-]+")
	for k, v in pairs(db.gankers) do if k:match("^[^-]+") == base then return v end end
end

-- Relative "time ago" for the last-seen stamp.
local function fmtAgo(t)
	if type(t) ~= "number" then return "?" end
	local s = time() - t
	if s < 60 then return "just now"
	elseif s < 3600 then return math.floor(s / 60) .. "m ago"
	elseif s < 86400 then return math.floor(s / 3600) .. "h ago"
	else return math.floor(s / 86400) .. "d ago" end
end

-- Alert when a listed ganker comes into range, and stamp where/when we last saw them.
local alertSeen = {} -- name -> last alert time, throttled to 1/60s
local function alertIfGanker(unit)
	if not UnitExists(unit) or not UnitIsPlayer(unit) then return end
	local name = UnitName(unit)
	if not name then return end
	local g = findGanker(ensureDB(), name)
	if not g then return end
	g.seenZone = GetRealZoneText() -- last-seen tracker (every sighting, not throttled)
	g.seenAt = time()
	if refreshUI then refreshUI() end
	local now = GetTime()
	if alertSeen[name] and now - alertSeen[name] < 60 then return end
	alertSeen[name] = now
	UIErrorsFrame:AddMessage("Ganker nearby: " .. name .. " (x" .. g.count .. ")", 1, 0.2, 0.2, 1, 5)
end

-- Revenge: you landed a killing blow on a Wanted player.
local function noteRevenge(name)
	local g = findGanker(ensureDB(), name)
	if not g then return end
	g.revenge = (g.revenge or 0) + 1
	if refreshUI then refreshUI() end
	UIErrorsFrame:AddMessage("Got even with " .. name .. "! (" .. g.revenge .. ")", 0.3, 1, 0.3, 1, 5)
end

-- A player kill is only ever logged to the Suspects list (a kill log you review).
-- Nothing is auto-added to Wanted; you promote real gankers yourself via /gank add.
local SUSPECT_TTL = 7 * 86400 -- self-clean suspects after a week
local function handleKill(name)
	name = cleanName(name)
	if not name then return end
	local db = ensureDB()
	for n, p in pairs(db.pending) do -- drop week-old suspects
		local t = type(p) == "table" and p.t or tonumber(p) or 0
		if t < time() - SUSPECT_TTL then db.pending[n] = nil end
	end

	local p = db.pending[name]
	if type(p) ~= "table" then p = { t = 0, count = tonumber(p) and 1 or 0 }; db.pending[name] = p end
	p.t = time()
	p.count = (p.count or 0) + 1
	if db.gankers[name] then -- already on Wanted: just note the repeat in chat
		print("|cffff4040GankList:|r " .. name .. " (Wanted) killed you again")
	else
		print("|cffff8040GankList:|r " .. name .. " killed you - logged as a suspect. /gank add " .. name .. " to list them")
	end
	if refreshUI then refreshUI() end
end

-- ---- events --------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_DEAD")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
f:RegisterEvent("PLAYER_TARGET_CHANGED")

f:SetScript("OnEvent", function(_, event, ...)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		local _, sub, _, srcGUID, srcName, srcFlags, _, destGUID, destName = CombatLogGetCurrentEventInfo()
		if sub == "PARTY_KILL" and srcGUID == playerGUID and destName then
			noteRevenge(destName) -- you landed the killing blow on someone
			return
		end
		if destGUID ~= playerGUID then return end
		if not sub:find("_DAMAGE") then return end
		local isPlayer = bit.band(srcFlags or 0, COMBATLOG_OBJECT_TYPE_PLAYER) > 0
		local isHostile = bit.band(srcFlags or 0, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0
		if isPlayer and isHostile and srcName then
			lastHit = { name = srcName, t = GetTime() }
		end

	elseif event == "PLAYER_DEAD" then
		if lastHit and (GetTime() - lastHit.t) <= DEATH_WINDOW then
			captureNearbyLevels() -- read the killer's level off their corpse-camping nameplate
			handleKill(lastHit.name)
			lastHit = nil
		end

	elseif event == "NAME_PLATE_UNIT_ADDED" then
		noteUnit(...); alertIfGanker(...) -- unitToken of the new nameplate

	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		noteUnit("mouseover"); alertIfGanker("mouseover")

	elseif event == "PLAYER_TARGET_CHANGED" then
		noteUnit("target"); alertIfGanker("target")

	elseif event == "CHAT_MSG_ADDON" then
		local prefix, msg, _, sender = ...
		if prefix ~= PREFIX then return end
		local short = sender and sender:match("^([^-]+)") -- accept only configured partners
		for _, p in ipairs(ensureDB().partners) do
			if sender == p or short == p:match("^([^-]+)") then onReceive(msg, short or sender) return end
		end

	elseif event == "PLAYER_LOGIN" then
		ensureDB()
		playerGUID = UnitGUID("player")
		C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
		C_Timer.After(8, sendAll) -- push our list to partners once chat is connected
	end
end)

-- ---- UI ------------------------------------------------------------------
local UI, rowPool = nil, {}

StaticPopupDialogs["GANKLIST_FORGIVE"] = {
	text = "%s wants to forgive %s.\nRemove them from your list too?",
	button1 = YES, button2 = NO, timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
	OnAccept = function(self, data)
		ensureDB().gankers[data.name] = nil
		if refreshUI then refreshUI() end
		print("|cffff4040GankList:|r forgave " .. data.name)
	end,
}

function refreshUI()
	if not UI or not UI:IsShown() then return end
	local db = ensureDB()
	if UI.auto then UI.auto:SetChecked(db.autoAccept and true or false) end

	-- Split into the two tabs.
	local gks, sus = {}, {}
	for name, g in pairs(db.gankers) do gks[#gks + 1] = { name = name, g = g } end
	for name, p in pairs(db.pending) do
		local t = type(p) == "table" and p.t or tonumber(p) or 0
		sus[#sus + 1] = { name = name, t = t, count = type(p) == "table" and p.count or 1 }
	end
	table.sort(gks, function(a, b) return a.g.count > b.g.count end)
	table.sort(sus, function(a, b) return a.t > b.t end)

	-- Reflect tab counts + which one is selected.
	UI.tabWanted:SetText("Wanted (" .. #gks .. ")")
	UI.tabSuspect:SetText("Suspects (" .. #sus .. ")")
	local wanted = UI.tab ~= "suspects"
	UI.tabWanted:SetButtonState(wanted and "PUSHED" or "NORMAL")
	UI.tabSuspect:SetButtonState(wanted and "NORMAL" or "PUSHED")
	UI.setTitle(wanted and "Wanted" or "Suspects")

	local entries = {}
	if wanted then
		for _, r in ipairs(gks) do entries[#entries + 1] = { kind = "ganker", r = r } end
	else
		for _, r in ipairs(sus) do entries[#entries + 1] = { kind = "suspect", r = r } end
	end

	for _, row in ipairs(rowPool) do row:Hide() end
	local content = UI.content
	for i, e in ipairs(entries) do
		local row = rowPool[i]
		if not row then
			row = CreateFrame("Button", nil, content)
			row:SetHeight(34)
			row:SetPoint("TOPRIGHT", -4, 0)
			row.hl = row:CreateTexture(nil, "HIGHLIGHT")
			row.hl:SetAllPoints()
			row.hl:SetColorTexture(0.8, 0.2, 0.2, 0.18)
			row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			row.name:SetPoint("LEFT", 6, 7)
			row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
			row.info:SetPoint("LEFT", 6, -8)
			row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
			row.count:SetPoint("RIGHT", -34, 0)
			row.del = CreateFrame("Button", nil, row, "UIPanelCloseButton")
			row.del:SetSize(24, 24)
			row.del:SetPoint("RIGHT", 2, 0)
			row.promote = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
			row.promote:SetSize(78, 20)
			row.promote:SetPoint("RIGHT", row.del, "LEFT", -2, 0)
			row.promote:SetText("\226\134\146 Wanted") -- "→ Wanted"
			local sep = row:CreateTexture(nil, "ARTWORK")
			sep:SetColorTexture(1, 1, 1, 0.10)
			sep:SetHeight(1)
			sep:SetPoint("BOTTOMLEFT", 2, -1)
			sep:SetPoint("BOTTOMRIGHT", -2, -1)
			rowPool[i] = row
		end
		row:SetPoint("TOPLEFT", 4, -(i - 1) * 36 - 2)

		if e.kind == "ganker" then
			local r = e.r
			local lvl = fmtLvl(r.g.level or levelSeen[r.name])
			row.name:SetText("|cffff6060" .. r.name .. "|r" .. (lvl ~= "" and "  |cff9090ff" .. lvl .. "|r" or ""))
			if r.g.seenAt then -- once spotted, the row becomes a tracker
				row.info:SetText("|cff80c0fflast seen " .. (r.g.seenZone or "?") .. "  ·  " .. fmtAgo(r.g.seenAt) .. "|r")
			else
				row.info:SetText((r.g.zone or "?") .. "  ·  " .. fmtTime(r.g.last))
			end
			local rev = r.g.revenge or 0
			row.count:SetText("x" .. r.g.count .. (rev > 0 and "  |cff60ff60\226\154\148" .. rev .. "|r" or ""))
			row.del:Show(); row.promote:Hide()
			row.del:SetScript("OnClick", function()
				db.gankers[r.name] = nil
				sendRemove(r.name) -- ask partners to forgive too
				refreshUI()
			end)
		else -- suspect
			local r = e.r
			local lvl = fmtLvl(levelSeen[r.name])
			row.name:SetText("|cffffa050" .. r.name .. "|r" .. (lvl ~= "" and "  |cff9090ff" .. lvl .. "|r" or ""))
			row.info:SetText("killed you " .. (r.count > 1 and r.count .. "x" or "once") .. "  ·  " .. fmtTime(r.t))
			row.count:SetText("")
			row.del:Show(); row.promote:Show()
			row.del:SetScript("OnClick", function()
				db.pending[r.name] = nil -- dismiss the suspect (local only, not synced)
				refreshUI()
			end)
			row.promote:SetScript("OnClick", function() -- upgrade suspect -> Wanted
				record(r.name, GetRealZoneText(), me, levelSeen[r.name])
				send(r.name)
				db.pending[r.name] = nil
				refreshUI()
				print("|cffff4040GankList:|r " .. r.name .. " moved to Wanted")
			end)
		end
		row:Show()
	end
	content:SetHeight(math.max(#entries * 36 + 4, 1))
	UI.empty:SetText(wanted and "No wanted enemies yet." or "No suspects right now.")
	UI.empty:SetShown(#entries == 0)
end

local function buildUI()
	-- PortraitFrameTemplate gives the skull portrait but isn't on every Classic flavor;
	-- fall back to BasicFrameTemplateWithInset, which exists everywhere.
	local ok, frame = pcall(CreateFrame, "Frame", "GankListFrame", UIParent, "PortraitFrameTemplate")
	if not ok or not frame then
		frame = CreateFrame("Frame", "GankListFrame", UIParent, "BasicFrameTemplateWithInset")
	end
	frame:SetSize(360, 420)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("HIGH")

	-- ESC closes the window. Propagate every other key so chat/movement still work.
	frame:EnableKeyboard(true)
	frame:SetPropagateKeyboardInput(true)
	frame:SetScript("OnKeyDown", function(self, key)
		if key == "ESCAPE" then
			self:SetPropagateKeyboardInput(false) -- consume so the game menu doesn't open
			self:Hide()
		else
			self:SetPropagateKeyboardInput(true)
		end
	end)

	-- Title shows just the active tab name (set per-tab in refreshUI).
	function frame.setTitle(text)
		if frame.SetTitle then frame:SetTitle(text)
		elseif frame.TitleText then frame.TitleText:SetText(text) end
	end
	frame.setTitle("Wanted")
	-- Top-left "captured enemy" icon (rogue Sap = a bound/shackled humanoid).
	-- Use the template's portrait when present, else add an explicit icon.
	local ENEMY_ICON = "Interface\\Icons\\Ability_Sap"
	local title = frame.TitleText or (frame.TitleContainer and frame.TitleContainer.TitleText)
	local portrait = frame.PortraitContainer and frame.PortraitContainer.portrait or frame.portrait
	if portrait then
		SetPortraitToTexture(portrait, ENEMY_ICON)
		if title then -- center it in the title bar (this client left-anchors it under the portrait)
			title:ClearAllPoints()
			title:SetJustifyH("CENTER")
			if frame.TitleContainer then
				title:SetPoint("CENTER", frame.TitleContainer, "CENTER", 0, 0)
			else
				title:SetPoint("TOP", frame, "TOP", 0, -4)
			end
		end
	else
		local icon = frame:CreateTexture(nil, "OVERLAY")
		icon:SetSize(22, 22)
		icon:SetPoint("TOPLEFT", 8, -4)
		icon:SetTexture(ENEMY_ICON)
		if frame.TitleText then frame.TitleText:SetPoint("LEFT", icon, "RIGHT", 4, 0) end
	end

	-- Wanted / Suspects tabs (plain buttons styled as tabs; works on every flavor).
	frame.tab = "wanted"
	local function makeTab(label, x)
		local t = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		t:SetSize(110, 22)
		t:SetPoint("TOPLEFT", x, -56)
		t:SetText(label)
		return t
	end
	frame.tabWanted = makeTab("Wanted", 12)
	frame.tabSuspect = makeTab("Suspects", 126)
	frame.tabWanted:SetScript("OnClick", function() frame.tab = "wanted"; refreshUI() end)
	frame.tabSuspect:SetScript("OnClick", function() frame.tab = "suspects"; refreshUI() end)

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -84) -- below the tab row
	scroll:SetPoint("BOTTOMRIGHT", -30, 60) -- leave room for the auto-accept checkbox + buttons
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(310, 1)
	scroll:SetScrollChild(content)
	frame.content = content

	frame.empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
	frame.empty:SetPoint("TOP", 0, -20)
	frame.empty:SetText("Clean record so far.")

	-- Auto-accept forgive requests from partners.
	local auto = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	auto:SetSize(22, 22)
	auto:SetPoint("BOTTOMLEFT", 12, 34)
	local autoLabel = auto:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	autoLabel:SetPoint("LEFT", auto, "RIGHT", 2, 0)
	autoLabel:SetText("Auto-accept friends' forgive requests")
	auto:SetScript("OnClick", function(self) ensureDB().autoAccept = self:GetChecked() and true or false end)
	frame.auto = auto

	-- No manual add: gankers only get on the list by killing you. Just a sync button.
	local sync = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	sync:SetSize(150, 22)
	sync:SetPoint("BOTTOM", 0, 8)
	sync:SetText("Sync Partners")
	sync:SetScript("OnClick", function() sendAll(); print("|cffff4040GankList:|r pushed list to friends") end)

	tinsert(UISpecialFrames, "GankListFrame") -- close with Escape
	frame:Hide() -- templates start shown; hide so the first /gank toggles it open
	return frame
end

local function toggleUI()
	if not UI then UI = buildUI() end
	if UI:IsShown() then UI:Hide() else UI:Show(); refreshUI() end
end

-- ---- slash ---------------------------------------------------------------
SLASH_GANK1 = "/gank"
SlashCmdList.GANK = function(msg)
	local rawCmd, arg = msg:match("^(%S*)%s*(.-)$")
	local cmd = rawCmd:lower()
	local db = ensureDB()

	if cmd == "help" then
		local function line(c, desc)
			print("  |cffffd100" .. c .. "|r  |cff808080-|r  " .. desc)
		end
		print("|cffff4040GankList|r |cff808080(killers are logged as Suspects; add the real gankers yourself)|r")
		line("/gank", "open the window")
		line("/gank add Name", "manually add a ganker")
		line("/gank del Name", "remove a ganker")
		line("/gank friend Name", "sync with a friend  (no name = list, 'reset' = clear)")
		line("/gank unfriend Name", "stop syncing with a friend")
		line("/gank ping", "test the sync link")
		line("/gank sync", "push your list to friends now")
		line("/gank party", "announce the list to party/raid")
		line("/gank autoaccept", "toggle auto-accept of forgives")
		line("/gank check", "reload-safe diagnostic")
		return
	end

	if cmd == "friend" or cmd == "partner" then -- "partner" kept as a silent alias
		local name = arg:gsub('"', ""):gsub("^%s+", ""):gsub("%s+$", "")
		if name == "" then
			print("|cffff4040GankList:|r friends: " .. (#db.partners > 0 and table.concat(db.partners, ", ") or "(none)"))
		elseif name:lower() == "reset" then
			wipe(db.partners)
			print("|cffff4040GankList:|r cleared all sync friends")
		else
			for _, p in ipairs(db.partners) do if p == name then print("|cffff4040GankList:|r already syncing with " .. name) return end end
			table.insert(db.partners, name)
			print("|cffff4040GankList:|r syncing with " .. name)
		end

	elseif cmd == "unfriend" then
		if arg == "" then print("|cffff4040GankList:|r /gank unfriend <name>") return end
		for i, p in ipairs(db.partners) do if p == arg then table.remove(db.partners, i) break end end
		print("|cffff4040GankList:|r stopped syncing with " .. arg)

	elseif cmd == "check" then
		local function ok(b) return b and "|cff40ff40OK|r" or "|cffff4040FAIL|r" end
		local n = 0
		for _ in pairs(db.gankers) do n = n + 1 end
		local registered = C_ChatInfo.IsAddonMessagePrefixRegistered
			and C_ChatInfo.IsAddonMessagePrefixRegistered(PREFIX)
		if not registered then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end -- self-heal
		print("|cffff4040GankList reload-safe check:|r")
		print("  saved DB loaded ........ " .. ok(GankListDB ~= nil) .. "  (" .. n .. " gankers)")
		print("  player GUID set ........ " .. ok(playerGUID ~= nil))
		print("  addon prefix ready ..... " .. ok(registered) .. (registered and "" or " (re-registered now)"))
		print("  friends configured .... " .. ok(#db.partners > 0) .. "  (" .. (#db.partners > 0 and table.concat(db.partners, ", ") or "none") .. ")")
		print("  combat-log tracking .... " .. ok(f:IsEventRegistered("COMBAT_LOG_EVENT_UNFILTERED")))

	elseif cmd == "autoaccept" then
		if arg == "on" then db.autoAccept = true elseif arg == "off" then db.autoAccept = false
		else db.autoAccept = not db.autoAccept end
		if refreshUI then refreshUI() end
		print("|cffff4040GankList:|r auto-accept forgive requests " .. (db.autoAccept and "ON" or "OFF"))

	elseif cmd == "ping" then
		if #db.partners == 0 then print("|cffff4040GankList:|r no friends yet - /gank friend add <name>") return end
		for _, p in ipairs(db.partners) do C_ChatInfo.SendAddonMessage(PREFIX, "PING", "WHISPER", p) end
		print("|cffff8040GankList:|r pinged " .. table.concat(db.partners, ", ") .. " - waiting for reply...")

	elseif cmd == "sync" then
		sendAll()
		print("|cffff4040GankList:|r pushed list to friends")

	elseif cmd == "add" then
		local name = arg ~= "" and arg or (UnitExists("target") and UnitIsPlayer("target") and UnitName("target"))
		name = name and cleanName(name)
		if not name then print("|cffff4040GankList:|r /gank add <name>  (or target a player first)") return end
		record(name, GetRealZoneText(), me)
		send(name)
		if refreshUI then refreshUI() end
		print("|cffff4040GankList:|r added " .. name)

	elseif cmd == "del" or cmd == "remove" or cmd == "forgive" then -- forgive/remove kept as silent aliases
		local name = arg ~= "" and arg or (UnitExists("target") and UnitIsPlayer("target") and UnitName("target"))
		if not name then print("|cffff4040GankList:|r /gank del <name>  (or target them first)") return end
		db.gankers[name] = nil
		sendRemove(name) -- ask partners to forgive too
		if refreshUI then refreshUI() end
		print("|cffff4040GankList:|r removed " .. name)

	elseif cmd == "party" then
		local rows = {}
		for name, g in pairs(db.gankers) do rows[#rows + 1] = { name = name, g = g } end
		table.sort(rows, function(a, b) return a.g.count > b.g.count end)
		local chan = IsInRaid() and "RAID" or "PARTY"
		SendChatMessage("Gank list:" .. (#rows == 0 and " (clean record)" or ""), chan)
		for _, r in ipairs(rows) do
			SendChatMessage(("%s x%d (%s)"):format(r.name, r.g.count, r.g.zone or "?"), chan)
		end

	elseif msg:gsub('["%s]', "") ~= "" then -- unknown input: gankers can't be added by hand
		print("|cffff4040GankList:|r unknown command. /gank help")

	else -- bare /gank - open the window
		toggleUI()
	end
end
