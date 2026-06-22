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
-- Strips "|" (chat color/hyperlink/texture escapes — anti-injection), and rejects
-- digits/whitespace in the character-name part. Accented letters (ä, é, ...) pass.
local function cleanName(s)
	s = tostring(s or ""):gsub("|", ""):gsub('"', ""):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" or #s > 40 then return nil end
	local base = s:match("^([^-]+)") -- name part before an optional -Realm
	if not base or base:find("%d") or base:find("%s") then return nil end
	return s
end

local function record(name, zone, by)
	local db = ensureDB()
	local g = db.gankers[name]
	if not g then
		g = { count = 0, by = by }
		db.gankers[name] = g
	end
	g.count = g.count + 1
	g.last = time() -- epoch; formatted to each viewer's local time at display
	g.zone = zone or g.zone
	return g
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
	name = cleanName(name) -- reject junk / strip injection from untrusted partner data
	if not name then return end

	if kind == "R" then -- partner forgave someone
		local db = ensureDB()
		if not db.gankers[name] then return end -- not on our list, nothing to do
		if db.autoAccept then
			db.gankers[name] = nil
			if refreshUI then refreshUI() end
			print("|cffff4040GankList:|r " .. (sender or "a partner") .. " forgave " .. name .. " (auto-accepted)")
		else
			StaticPopup_Show("GANKLIST_FORGIVE", sender or "A partner", name, { name = name })
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

-- Alert when a listed ganker comes into range (nameplate/target/mouseover).
local alertSeen = {} -- name -> last alert time, throttled to 1/60s
local function alertIfGanker(unit)
	if not UnitExists(unit) or not UnitIsPlayer(unit) then return end
	local name = UnitName(unit)
	if not name then return end
	local db = ensureDB()
	local g = db.gankers[name]
	if not g then -- match base name too (stored key may include -Realm)
		local base = name:match("^[^-]+")
		for k, v in pairs(db.gankers) do if k:match("^[^-]+") == base then g = v break end end
	end
	if not g then return end
	local now = GetTime()
	if alertSeen[name] and now - alertSeen[name] < 60 then return end
	alertSeen[name] = now
	UIErrorsFrame:AddMessage("Ganker nearby: " .. name .. " (x" .. g.count .. ")", 1, 0.2, 0.2, 1, 5)
end

-- Two-strike kill handling: not every PvP death is a gank. A first kill marks the
-- player as a "suspect" (pending); a repeat kill promotes them to the gank list.
local PENDING_TTL = 3 * 86400 -- forget a one-off killer after 3 days
local lastKiller -- most recent player to kill you, for /gank addlast
local function handleKill(name)
	name = cleanName(name)
	if not name then return end
	lastKiller = name
	local db = ensureDB()
	for n, t in pairs(db.pending) do -- prune stale suspects
		if (tonumber(t) or 0) < time() - PENDING_TTL then db.pending[n] = nil end
	end
	if db.gankers[name] then -- already a known ganker: just tally
		record(name, GetRealZoneText(), me)
		send(name)
		print("|cffff4040GankList:|r " .. name .. " ganked you again (x" .. db.gankers[name].count .. ")")
	elseif db.pending[name] then -- second strike: promote to the list
		db.pending[name] = nil
		record(name, GetRealZoneText(), me)
		send(name)
		print("|cffff4040GankList:|r " .. name .. " killed you again — added to the gank list. /gank forgive " .. name .. " to undo")
	else -- first strike: remember as a suspect only
		db.pending[name] = time()
		print("|cffff8040GankList:|r " .. name .. " killed you. Added if it happens again — or /gank addlast to list them now")
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
		local _, sub, _, _, srcName, srcFlags, _, destGUID = CombatLogGetCurrentEventInfo()
		if destGUID ~= playerGUID then return end
		if not sub:find("_DAMAGE") then return end
		local isPlayer = bit.band(srcFlags or 0, COMBATLOG_OBJECT_TYPE_PLAYER) > 0
		local isHostile = bit.band(srcFlags or 0, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0
		if isPlayer and isHostile and srcName then
			lastHit = { name = srcName, t = GetTime() }
		end

	elseif event == "PLAYER_DEAD" then
		if lastHit and (GetTime() - lastHit.t) <= DEATH_WINDOW then
			handleKill(lastHit.name)
			lastHit = nil
		end

	elseif event == "NAME_PLATE_UNIT_ADDED" then
		alertIfGanker(...) -- unitToken of the new nameplate

	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		alertIfGanker("mouseover")

	elseif event == "PLAYER_TARGET_CHANGED" then
		alertIfGanker("target")

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

local function addByName(name)
	name = cleanName(name)
	if not name then print("|cffff4040GankList:|r that's not a valid player name") return end
	record(name, GetRealZoneText(), me)
	send(name)
	if refreshUI then refreshUI() end
	print("|cffff4040GankList:|r added " .. name)
end

StaticPopupDialogs["GANKLIST_ADD"] = {
	text = "Add a player to the gank list:",
	button1 = ADD or "Add", button2 = CANCEL,
	hasEditBox = true, timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
	OnAccept = function(self) addByName(self.editBox:GetText()) end,
	EditBoxOnEnterPressed = function(self) addByName(self:GetText()); self:GetParent():Hide() end,
}

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
	local rows = {}
	for name, g in pairs(db.gankers) do rows[#rows + 1] = { name = name, g = g } end
	table.sort(rows, function(a, b) return a.g.count > b.g.count end)

	for _, r in ipairs(rowPool) do r:Hide() end
	local content = UI.content
	for i, r in ipairs(rows) do
		local row = rowPool[i]
		if not row then
			row = CreateFrame("Button", nil, content)
			row:SetHeight(34)
			row:SetPoint("TOPLEFT", 4, -(i - 1) * 36 - 2)
			row:SetPoint("TOPRIGHT", -4, 0)
			local hl = row:CreateTexture(nil, "HIGHLIGHT")
			hl:SetAllPoints()
			hl:SetColorTexture(0.8, 0.2, 0.2, 0.18)
			row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			row.name:SetPoint("LEFT", 6, 7)
			row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
			row.info:SetPoint("LEFT", 6, -8)
			row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
			row.count:SetPoint("RIGHT", -34, 0)
			row.del = CreateFrame("Button", nil, row, "UIPanelCloseButton")
			row.del:SetSize(24, 24)
			row.del:SetPoint("RIGHT", 2, 0)
			local sep = row:CreateTexture(nil, "ARTWORK")
			sep:SetColorTexture(1, 1, 1, 0.10) -- thin divider under each entry
			sep:SetHeight(1)
			sep:SetPoint("BOTTOMLEFT", 2, -1)
			sep:SetPoint("BOTTOMRIGHT", -2, -1)
			rowPool[i] = row
		end
		row:SetPoint("TOPLEFT", 4, -(i - 1) * 36 - 2)
		row.name:SetText("|cffff6060" .. r.name .. "|r")
		row.info:SetText((r.g.zone or "?") .. "  ·  " .. fmtTime(r.g.last))
		row.count:SetText("x" .. r.g.count)
		row.del:SetScript("OnClick", function()
			db.gankers[r.name] = nil
			sendRemove(r.name) -- ask partners to forgive too
			refreshUI()
		end)
		row:Show()
	end
	content:SetHeight(math.max(#rows * 36 + 4, 1))
	UI.empty:SetShown(#rows == 0)
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

	if frame.SetTitle then
		frame:SetTitle("GankList — Wanted")
	elseif frame.TitleText then
		frame.TitleText:SetText("GankList — Wanted")
	end
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

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -58) -- clear the portrait circle that overhangs the title bar
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
	autoLabel:SetText("Auto-accept partners' forgive requests")
	auto:SetScript("OnClick", function(self) ensureDB().autoAccept = self:GetChecked() and true or false end)
	frame.auto = auto

	local add = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	add:SetSize(150, 22)
	add:SetPoint("BOTTOMLEFT", 12, 8)
	add:SetText("Add Player")
	add:SetScript("OnClick", function()
		if UnitExists("target") and UnitIsPlayer("target") then
			addByName(UnitName("target"))
		else
			StaticPopup_Show("GANKLIST_ADD") -- no target: ask for a name
		end
	end)

	local sync = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	sync:SetSize(150, 22)
	sync:SetPoint("BOTTOMRIGHT", -28, 8)
	sync:SetText("Sync Partners")
	sync:SetScript("OnClick", function() sendAll(); print("|cffff4040GankList:|r pushed list to partners") end)

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
			print("  |cffffd100" .. c .. "|r  |cff808080—|r  " .. desc)
		end
		print("|cffff4040GankList — commands|r")
		line("/gank", "open the window")
		line('/gank "Name"', "add a player to the list")
		line("/gank add [Name]", "add (or target a player and omit the name)")
		line("/gank addlast", "add the player who most recently killed you")
		line("/gank pending", "show suspects (killed you once, not yet listed)")
		line("/gank forgive Name", "remove a player (made amends)")
		line("/gank list", "print the list to chat")
		line("/gank party", "announce the list to party/raid chat")
		line("/gank partner add Name-Realm", "sync with a friend")
		line("/gank partner remove Name", "stop syncing with them")
		line("/gank partner", "show your sync partners")
		line("/gank sync", "push your list to partners now")
		line("/gank autoaccept on|off", "auto-accept partners' forgive requests")
		line("/gank check", "reload-safe diagnostic")
		return
	end

	if cmd == "add" then
		local name = arg ~= "" and arg or (UnitExists("target") and UnitIsPlayer("target") and UnitName("target"))
		if not name then print("|cffff4040GankList:|r /gank add <name>  (or target a player first)") return end
		addByName(name)

	elseif cmd == "partner" then
		local sub, who = arg:match("^(%S*)%s*(.-)$")
		if sub == "add" and who ~= "" then
			table.insert(db.partners, who)
			print("|cffff4040GankList:|r syncing with " .. who)
		elseif sub == "remove" and who ~= "" then
			for i, p in ipairs(db.partners) do if p == who then table.remove(db.partners, i) break end end
			print("|cffff4040GankList:|r removed partner " .. who)
		else
			print("|cffff4040GankList:|r partners: " .. (#db.partners > 0 and table.concat(db.partners, ", ") or "(none)"))
		end

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
		print("  partners configured .... " .. ok(#db.partners > 0) .. "  (" .. (#db.partners > 0 and table.concat(db.partners, ", ") or "none") .. ")")
		print("  combat-log tracking .... " .. ok(f:IsEventRegistered("COMBAT_LOG_EVENT_UNFILTERED")))

	elseif cmd == "addlast" then
		if lastKiller then
			db.pending[lastKiller] = nil
			addByName(lastKiller)
		else
			print("|cffff4040GankList:|r no recent killer recorded")
		end

	elseif cmd == "pending" then
		print("|cffff8040GankList — suspects (one kill so far):|r")
		local any = false
		for n in pairs(db.pending) do print("  " .. n); any = true end
		if not any then print("  (none)") end

	elseif cmd == "autoaccept" then
		if arg == "on" then db.autoAccept = true elseif arg == "off" then db.autoAccept = false
		else db.autoAccept = not db.autoAccept end
		if refreshUI then refreshUI() end
		print("|cffff4040GankList:|r auto-accept forgive requests " .. (db.autoAccept and "ON" or "OFF"))

	elseif cmd == "sync" then
		sendAll()
		print("|cffff4040GankList:|r pushed list to partners")

	elseif cmd == "remove" or cmd == "forgive" then
		local name = arg ~= "" and arg or (UnitExists("target") and UnitIsPlayer("target") and UnitName("target"))
		if not name then print("|cffff4040GankList:|r /gank forgive <name>  (or target them first)") return end
		db.gankers[name] = nil
		sendRemove(name) -- ask partners to forgive too
		if refreshUI then refreshUI() end
		print("|cffff4040GankList:|r forgave " .. name)

	elseif cmd == "list" then
		local rows = {}
		for name, g in pairs(db.gankers) do
			table.insert(rows, { name = name, g = g })
		end
		table.sort(rows, function(a, b) return a.g.count > b.g.count end)
		print("|cffff4040GankList — your enemies:|r")
		for _, r in ipairs(rows) do
			print(("  %s  x%d  (%s, %s)"):format(r.name, r.g.count, r.g.zone or "?", fmtTime(r.g.last)))
		end
		if #rows == 0 then print("  (clean record so far)") end

	elseif cmd == "party" then
		local rows = {}
		for name, g in pairs(db.gankers) do rows[#rows + 1] = { name = name, g = g } end
		table.sort(rows, function(a, b) return a.g.count > b.g.count end)
		local chan = IsInRaid() and "RAID" or "PARTY"
		SendChatMessage("Gank list:" .. (#rows == 0 and " (clean record)" or ""), chan)
		for _, r in ipairs(rows) do
			SendChatMessage(("%s x%d (%s)"):format(r.name, r.g.count, r.g.zone or "?"), chan)
		end

	elseif msg:gsub('["%s]', "") ~= "" then -- /gank "Name" — treat any leftover input as a player to add
		addByName(msg)

	else -- bare /gank — open the window
		toggleUI()
	end
end
