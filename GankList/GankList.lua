-- GankList: remember who ganked you, sync to 1-2 trusted partners.
local PREFIX = "GankList"
local DEATH_WINDOW = 12 -- seconds: hostile player damage this recent at death = the ganker

local me = UnitName("player")
local playerGUID -- set on login

-- lastHit: most recent hostile-player damage taken { name=, t= }
local lastHit = nil
local refreshUI -- forward decl: used by event handler, defined in UI section below
local UI -- forward decl: event handler updates the Add Target button; built lazily below

local function ensureDB()
	GankListDB = GankListDB or {}
	GankListDB.gankers = GankListDB.gankers or {}   -- [name] = { count, last, zone, by }
	GankListDB.partners = GankListDB.partners or {}  -- confirmed two-way sync friends (accepted)
	GankListDB.outReq = GankListDB.outReq or {}      -- friend requests we sent, awaiting their accept
	GankListDB.blacklist = GankListDB.blacklist or {} -- [name] = { note, by, t } same-faction jerks
	GankListDB.whitelist = GankListDB.whitelist or {} -- [name] = { note, by, t } same-faction friendlies
	return GankListDB
end

-- Battlegrounds and arenas are one long gank; alerts and kill counts there are pure
-- noise, so GankList always stays quiet inside them.
local function mutedHere()
	local _, t = IsInInstance()
	return t == "pvp" or t == "arena"
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
-- All outgoing whispers go through a throttled queue (~5/sec) so a big list can
-- never burst-spam and get you (or the friend answering a handshake) disconnected.
local outq, outTicker = {}, nil
local function tx(payload, to)
	outq[#outq + 1] = { payload, to }
	if not outTicker then
		outTicker = C_Timer.NewTicker(0.2, function()
			local m = table.remove(outq, 1)
			if m then C_ChatInfo.SendAddonMessage(PREFIX, m[1], "WHISPER", m[2]) end
			if #outq == 0 and outTicker then outTicker:Cancel(); outTicker = nil end
		end)
	end
end

-- send(name[, only]) - push one ganker to all friends, or just `only` if given.
local function send(name, only)
	local g = ensureDB().gankers[name]
	if not g then return end
	local payload = table.concat({ "G", name, g.count, g.zone or "", g.by or me, g.last or time(), g.note or "" }, "\t")
	if only then
		tx(payload, only)
	else
		for _, partner in ipairs(ensureDB().partners) do tx(payload, partner) end
	end
end

-- sendBlack(name[, only]) - push one blacklisted same-faction player to friends.
local function sendBlack(name, only)
	local b = ensureDB().blacklist[name]
	if not b then return end
	local payload = table.concat({ "B", name, b.note or "", b.by or me, b.t or time() }, "\t")
	if only then
		tx(payload, only)
	else
		for _, partner in ipairs(ensureDB().partners) do tx(payload, partner) end
	end
end

-- sendWhite(name[, only]) - push one whitelisted same-faction friendly to friends.
local function sendWhite(name, only)
	local w = ensureDB().whitelist[name]
	if not w then return end
	local payload = table.concat({ "W", name, w.note or "", w.by or me, w.t or time() }, "\t")
	if only then
		tx(payload, only)
	else
		for _, partner in ipairs(ensureDB().partners) do tx(payload, partner) end
	end
end

local function sendAll(only) -- push the whole shared list (gankers + blacklist + whitelist) to friends
	for name in pairs(ensureDB().gankers) do send(name, only) end
	for name in pairs(ensureDB().blacklist) do sendBlack(name, only) end
	for name in pairs(ensureDB().whitelist) do sendWhite(name, only) end
end

-- Set/clear a note on a Wanted ganker, then push it to friends.
local function setGankNote(name, note)
	local g = ensureDB().gankers[name]
	if not g then return end
	g.note = tostring(note or ""):gsub("|", ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 120)
	send(name)
	if refreshUI then refreshUI() end
end

-- Silent catch-up handshake: on login we greet each friend with "HI"; whoever is
-- already online answers by pushing their whole list back. This closes the gap
-- where you add a ganker while a friend is offline - they get it when they log in.
local helloReply = {} -- friend -> last time we answered their HI (throttle)
-- isOnline(name): true/false from the in-game friends list, or nil if they're
-- not on it (Classic can't query arbitrary players, so nil = "send anyway").
local function isOnline(name)
	local info = C_FriendList.GetFriendInfoByName(name)
	if info then return info.connected end
	return nil
end
local function greetFriends()
	C_FriendList.ShowFriends() -- nudge the roster to refresh so .connected is current
	for _, p in ipairs(ensureDB().partners) do
		if isOnline(p) ~= false then -- online, or not on friends list (can't tell)
			tx("HI", p)
			sendAll(p) -- push our list to this friend (covers them being already online)
		end
	end
end

-- Broadcast a forgive (removal) request to partners.
local function sendRemove(name)
	local payload = "R\t" .. name
	for _, partner in ipairs(ensureDB().partners) do tx(payload, partner) end
end

-- Blacklist: same-faction players you can't gank but want flagged, with a note.
local function addBlacklist(name, note)
	name = cleanName(name)
	if not name then return end
	note = tostring(note or ""):gsub("|", ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 120)
	ensureDB().blacklist[name] = { note = note, by = me, t = time() }
	sendBlack(name)
	if refreshUI then refreshUI() end
	print("|cffff4040GankList:|r blacklisted " .. name .. (note ~= "" and " (" .. note .. ")" or ""))
end

local function removeBlacklist(name)
	ensureDB().blacklist[name] = nil
	local payload = "BR\t" .. name
	for _, partner in ipairs(ensureDB().partners) do tx(payload, partner) end -- ask partners to drop it too
	if refreshUI then refreshUI() end
end

-- Whitelist: same-faction players you vouch for, with a note. Mirror of blacklist.
local function addWhitelist(name, note)
	name = cleanName(name)
	if not name then return end
	note = tostring(note or ""):gsub("|", ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 120)
	ensureDB().whitelist[name] = { note = note, by = me, t = time() }
	sendWhite(name)
	if refreshUI then refreshUI() end
	print("|cff40ff40GankList:|r whitelisted " .. name .. (note ~= "" and " (" .. note .. ")" or ""))
end

local function removeWhitelist(name)
	ensureDB().whitelist[name] = nil
	local payload = "WR\t" .. name
	for _, partner in ipairs(ensureDB().partners) do tx(payload, partner) end -- ask partners to drop it too
	if refreshUI then refreshUI() end
end

-- ---- friend requests -----------------------------------------------------
-- Syncing now needs consent: requestFriend sends FREQ; the recipient gets a
-- popup and, on accept, adds you back and replies FACC. Until then they're
-- "pending" (in db.outReq) - we never push them our list before they accept.
local function isPartner(db, name)
	for _, p in ipairs(db.partners) do if p == name then return true end end
	return false
end

local function requestFriend(name)
	name = cleanName(name)
	if not name then print("|cffff4040GankList:|r who? /gank friend <name>") return end
	local db = ensureDB()
	if isPartner(db, name) then print("|cffff4040GankList:|r already friends with " .. name) return end
	for _, p in ipairs(db.outReq) do if p == name then print("|cffff8040GankList:|r request to " .. name .. " already pending") return end end
	table.insert(db.outReq, name)
	tx("FREQ", name)
	if refreshUI then refreshUI() end
	print("|cffff8040GankList:|r friend request sent to " .. name .. " - waiting for them to accept")
end

-- We accept an incoming request from `name`: add as partner, confirm, share list.
local function acceptFriend(name)
	name = cleanName(name)
	if not name then return end
	local db = ensureDB()
	for i, p in ipairs(db.outReq) do if p == name then table.remove(db.outReq, i) break end end
	if not isPartner(db, name) then table.insert(db.partners, name) end
	tx("FACC", name)
	sendAll(name) -- share our list with the new friend now they've opted in
	if refreshUI then refreshUI() end
	print("|cff40ff40GankList:|r now syncing with " .. name)
end

local function removeFriend(name)
	local db = ensureDB()
	for i, p in ipairs(db.partners) do if p == name then table.remove(db.partners, i) break end end
	for i, p in ipairs(db.outReq) do if p == name then table.remove(db.outReq, i) break end end
	if refreshUI then refreshUI() end
end

-- Handle FREQ/FACC. These bypass the partner gate (you can't sync before you're
-- friends), so they're consent-gated: FREQ only ever shows a popup, and FACC is
-- honored only if we actually have an outgoing request to that sender.
local function onFriendMsg(kind, sender)
	sender = cleanName(sender)
	if not sender then return end
	local db = ensureDB()
	if kind == "FREQ" then
		if isPartner(db, sender) then tx("FACC", sender) return end -- already friends: re-confirm silently
		StaticPopup_Show("GANKLIST_FRIENDREQ", sender, nil, { name = sender })
	elseif kind == "FACC" then
		local idx
		for i, p in ipairs(db.outReq) do if p == sender then idx = i break end end
		if not idx then return end -- unsolicited accept (or already friends) - ignore
		table.remove(db.outReq, idx)
		if not isPartner(db, sender) then table.insert(db.partners, sender) end
		sendAll(sender)
		if refreshUI then refreshUI() end
		print("|cff40ff40GankList:|r " .. sender .. " accepted - now syncing")
	end
end

local function onReceive(payload, sender)
	local kind, name, count, zone, by, last, note = strsplit("\t", payload)

	if kind == "HI" then -- a friend just logged in: silently push our list back to them
		if sender and (not helloReply[sender] or time() - helloReply[sender] > 30) then
			helloReply[sender] = time()
			sendAll(sender)
		end
		return
	elseif kind == "PING" then -- connectivity test: reply so the sender knows it round-tripped
		print("|cff40ff40GankList:|r ping from " .. (sender or "?") .. " - you two are synced")
		for _, p in ipairs(ensureDB().partners) do tx("PONG", p) end
		return
	elseif kind == "PONG" then
		print("|cff40ff40GankList:|r " .. (sender or "a friend") .. " got your ping - sync works")
		return
	elseif kind == "B" then -- a friend blacklisted a same-faction player
		local _, bname, bnote, bby, bt = strsplit("\t", payload)
		bname = cleanName(bname)
		if not bname then return end
		bnote = (bnote or ""):gsub("|", ""):sub(1, 120) -- strip injection, cap length
		bby = bby and bby:gsub("|", ""):sub(1, 40) or nil
		bt = math.min(tonumber(bt) or time(), time() + 86400)
		local db = ensureDB()
		local b = db.blacklist[bname]
		if not b or bt > (b.t or 0) then db.blacklist[bname] = { note = bnote, by = bby, t = bt } end
		if refreshUI then refreshUI() end
		return
	elseif kind == "BR" then -- a friend removed someone from their blacklist
		local _, bname = strsplit("\t", payload)
		bname = cleanName(bname)
		if bname and ensureDB().blacklist[bname] then
			ensureDB().blacklist[bname] = nil
			if refreshUI then refreshUI() end
		end
		return
	elseif kind == "W" then -- a friend whitelisted a same-faction friendly
		local _, wname, wnote, wby, wt = strsplit("\t", payload)
		wname = cleanName(wname)
		if not wname then return end
		wnote = (wnote or ""):gsub("|", ""):sub(1, 120) -- strip injection, cap length
		wby = wby and wby:gsub("|", ""):sub(1, 40) or nil
		wt = math.min(tonumber(wt) or time(), time() + 86400)
		local db = ensureDB()
		local w = db.whitelist[wname]
		if not w or wt > (w.t or 0) then db.whitelist[wname] = { note = wnote, by = wby, t = wt } end
		if refreshUI then refreshUI() end
		return
	elseif kind == "WR" then -- a friend removed someone from their whitelist
		local _, wname = strsplit("\t", payload)
		wname = cleanName(wname)
		if wname and ensureDB().whitelist[wname] then
			ensureDB().whitelist[wname] = nil
			if refreshUI then refreshUI() end
		end
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
	note = note and note:gsub("|", ""):sub(1, 120) or nil -- strip injection, cap length
	local db = ensureDB()
	local g = db.gankers[name]
	if not g then
		db.gankers[name] = { count = count, last = last, zone = zone, by = by, note = note }
	else
		g.count = math.max(g.count, count) -- avoid double-counting on re-sync
		g.zone = g.zone or zone
		if note and note ~= "" then g.note = note end -- adopt a partner's note
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

-- Big center-screen alert (raid-warning style), with a small-text fallback.
local function bigAlert(msg, r, g, b)
	if RaidNotice_AddMessage and RaidWarningFrame then
		RaidNotice_AddMessage(RaidWarningFrame, msg, { r = r, g = g, b = b }, 5)
	else
		UIErrorsFrame:AddMessage(msg, r, g, b, 1, 5)
	end
end

-- Alert when a listed ganker comes into range, and stamp where/when we last saw them.
local alertSeen = {} -- name -> last alert time, throttled to 1/60s
local function alertIfGanker(unit)
	if mutedHere() then return end
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
	bigAlert("Ganker nearby: " .. name .. " (x" .. g.count .. ")", 1, 0.2, 0.2)
end

-- Revenge: you landed a killing blow on a Wanted player.
local function noteRevenge(name)
	if mutedHere() then return end
	local g = findGanker(ensureDB(), name)
	if not g then return end
	g.revenge = (g.revenge or 0) + 1
	if refreshUI then refreshUI() end
	UIErrorsFrame:AddMessage("Got even with " .. name .. "! (" .. g.revenge .. ")", 0.3, 1, 0.3, 1, 5)
end

-- A kill bumps an already-Wanted player's count; nothing is auto-added to Wanted.
-- You add real gankers yourself via /gank add (or the Add Target button).
local function handleKill(name)
	if mutedHere() then return end
	name = cleanName(name)
	if not name then return end
	local db = ensureDB()
	local g = db.gankers[name]
	if g then -- already on Wanted: bump their count
		g.count = g.count + 1
		g.last = time()
		send(name) -- push the higher count to partners
		print("|cffff4040GankList:|r " .. name .. " (Wanted) killed you again (x" .. g.count .. ")")
		if refreshUI then refreshUI() end
	else
		print("|cffff8040GankList:|r " .. name .. " killed you - /gank add " .. name .. " to list them")
	end
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
		if UI and UI.updateAddBtn then UI.updateAddBtn() end

	elseif event == "CHAT_MSG_ADDON" then
		local prefix, msg, _, sender = ...
		if prefix ~= PREFIX then return end
		local short = sender and sender:match("^([^-]+)")
		local kind = strsplit("\t", msg)
		if kind == "FREQ" or kind == "FACC" then -- friendship handshake: allowed from non-partners (consent-gated)
			onFriendMsg(kind, short or sender)
			return
		end
		for _, p in ipairs(ensureDB().partners) do -- everything else: configured partners only
			if sender == p or short == p:match("^([^-]+)") then onReceive(msg, short or sender) return end
		end

	elseif event == "PLAYER_LOGIN" then
		ensureDB()
		playerGUID = UnitGUID("player")
		C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
		C_Timer.After(8, greetFriends) -- greet friends + push our list once chat is connected
	end
end)

-- ---- UI ------------------------------------------------------------------
local rowPool = {}

StaticPopupDialogs["GANKLIST_FORGIVE"] = {
	text = "%s wants to forgive %s.\nRemove them from your list too?",
	button1 = YES, button2 = NO, timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
	OnAccept = function(self, data)
		ensureDB().gankers[data.name] = nil
		if refreshUI then refreshUI() end
		print("|cffff4040GankList:|r forgave " .. data.name)
	end,
}

StaticPopupDialogs["GANKLIST_FRIENDREQ"] = {
	text = "%s wants to sync gank lists with you.\nAccept and share your list?",
	button1 = YES, button2 = NO, timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
	OnAccept = function(self, data) acceptFriend(data.name) end,
}

-- Note editor, shared by blacklist + whitelist. Caller passes the full prompt as
-- the text arg and an add(name, note) function + current note in data.
StaticPopupDialogs["GANKLIST_NOTE"] = {
	text = "%s",
	button1 = SAVE or "Save", button2 = CANCEL, hasEditBox = true, maxLetters = 120,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
	OnShow = function(self, data) self.editBox:SetText((data and data.note) or "") end,
	OnAccept = function(self, data) data.add(data.name, self.editBox:GetText()) end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		parent.data.add(parent.data.name, self:GetText())
		parent:Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

function refreshUI()
	if not UI or not UI:IsShown() then return end
	local db = ensureDB()
	if UI.auto then UI.auto:SetChecked(db.autoAccept and true or false) end

	-- Split into the four tabs.
	local gks, frs, bl, wl = {}, {}, {}, {}
	for name, g in pairs(db.gankers) do gks[#gks + 1] = { name = name, g = g } end
	for _, p in ipairs(db.partners) do frs[#frs + 1] = { name = p, pending = false } end
	for _, p in ipairs(db.outReq) do frs[#frs + 1] = { name = p, pending = true } end
	for name, b in pairs(db.blacklist) do bl[#bl + 1] = { name = name, b = b } end
	for name, w in pairs(db.whitelist) do wl[#wl + 1] = { name = name, b = w } end
	table.sort(gks, function(a, b) return a.g.count > b.g.count end)
	table.sort(bl, function(a, b) return a.name < b.name end)
	table.sort(wl, function(a, b) return a.name < b.name end)

	-- Reflect tab counts + which one is selected.
	local tab = UI.tab or "wanted"
	UI.tabWanted:SetText("Wanted (" .. #gks .. ")")
	UI.tabBlack:SetText("Blacklist (" .. #bl .. ")")
	UI.tabFriends:SetText("Friends (" .. #frs .. ")")
	UI.tabWhite:SetText("Whitelist (" .. #wl .. ")")
	UI.tabWanted:SetButtonState(tab == "wanted" and "PUSHED" or "NORMAL")
	UI.tabBlack:SetButtonState(tab == "blacklist" and "PUSHED" or "NORMAL")
	UI.tabFriends:SetButtonState(tab == "friends" and "PUSHED" or "NORMAL")
	UI.tabWhite:SetButtonState(tab == "whitelist" and "PUSHED" or "NORMAL")
	UI.setTitle(tab == "wanted" and "Wanted" or tab == "blacklist" and "Blacklist" or tab == "friends" and "Friends" or "Whitelist")

	-- Friends/Blacklist/Whitelist tabs swap their own add-box into the bottom bar.
	local onF, onB, onW = tab == "friends", tab == "blacklist", tab == "whitelist"
	UI.friendAdd:SetShown(onF); UI.friendBox:SetShown(onF)
	UI.blackAdd:SetShown(onB); UI.blackBox:SetShown(onB)
	UI.whiteAdd:SetShown(onW); UI.whiteBox:SetShown(onW)
	UI.addTgt:SetShown(tab == "wanted")
	UI.sync:SetShown(tab == "wanted")

	local entries = {}
	if tab == "wanted" then
		for _, r in ipairs(gks) do entries[#entries + 1] = { kind = "ganker", r = r } end
	elseif tab == "blacklist" then
		for _, r in ipairs(bl) do entries[#entries + 1] = { kind = "black", r = r } end
	elseif tab == "friends" then
		for _, r in ipairs(frs) do entries[#entries + 1] = { kind = "friend", r = r } end
	else
		for _, r in ipairs(wl) do entries[#entries + 1] = { kind = "white", r = r } end
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
			row.info:SetWidth(280); row.info:SetJustifyH("LEFT"); row.info:SetWordWrap(false) -- truncate long notes
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
			row:SetScript("OnEnter", function(self) -- hover shows the full note (inline preview truncates)
				if not self.fullNote or self.fullNote == "" then return end
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText(self.ttName or "", 1, 0.82, 0)
				GameTooltip:AddLine(self.fullNote, 0.9, 0.9, 0.9, true) -- true = wrap
				GameTooltip:Show()
			end)
			row:SetScript("OnLeave", function() GameTooltip:Hide() end)
			rowPool[i] = row
		end
		row.fullNote = nil -- reset; note-bearing branches set it below
		row:SetPoint("TOPLEFT", 4, -(i - 1) * 36 - 2)

		if e.kind == "ganker" then
			local r = e.r
			local lvl = fmtLvl(r.g.level or levelSeen[r.name])
			row.name:SetText("|cffff6060" .. r.name .. "|r" .. (lvl ~= "" and "  |cff9090ff" .. lvl .. "|r" or ""))
			local base
			if r.g.seenAt then -- once spotted, the row becomes a tracker
				base = "|cff80c0fflast seen " .. (r.g.seenZone or "?") .. "  ·  " .. fmtAgo(r.g.seenAt) .. "|r"
			else
				base = (r.g.zone or "?") .. "  ·  " .. fmtTime(r.g.last)
			end
			if r.g.note and r.g.note ~= "" then base = base .. "  |cffcccccc" .. r.g.note .. "|r" end
			row.info:SetText(base)
			row.fullNote, row.ttName = r.g.note, r.name
			local rev = r.g.revenge or 0
			row.count:SetText("x" .. r.g.count .. (rev > 0 and "  |cff60ff60+" .. rev .. "|r" or ""))
			row.del:Show(); row.promote:Show()
			row.promote:SetText("Note")
			row.del:SetScript("OnClick", function()
				db.gankers[r.name] = nil
				sendRemove(r.name) -- ask partners to forgive too
				refreshUI()
			end)
			row.promote:SetScript("OnClick", function() -- add/edit a note
				StaticPopup_Show("GANKLIST_NOTE", "Note for " .. r.name .. ":", nil,
					{ name = r.name, note = r.g.note, add = setGankNote })
			end)
		elseif e.kind == "white" then -- whitelisted same-faction friendly
			local r = e.r
			row.name:SetText("|cff80ff80" .. r.name .. "|r")
			row.info:SetText(r.b.note ~= "" and "|cffcccccc" .. r.b.note .. "|r" or "|cff808080(no note - click Note to add)|r")
			row.fullNote, row.ttName = r.b.note, r.name
			row.count:SetText("")
			row.del:Show(); row.promote:Show()
			row.promote:SetText("Note")
			row.del:SetScript("OnClick", function()
				removeWhitelist(r.name)
			end)
			row.promote:SetScript("OnClick", function() -- edit the note
				StaticPopup_Show("GANKLIST_NOTE", "Why is " .. r.name .. " whitelisted?", nil,
					{ name = r.name, note = r.b.note, add = addWhitelist })
			end)
		elseif e.kind == "friend" then
			local r = e.r
			row.name:SetText((r.pending and "|cffffd100" or "|cff40ff40") .. r.name .. "|r")
			row.info:SetText(r.pending and "|cffaaaaaarequest sent - waiting for accept|r" or "|cff80c0ffsynced|r")
			row.count:SetText("")
			row.del:Show(); row.promote:SetShown(not r.pending)
			row.promote:SetText("Ping")
			row.del:SetScript("OnClick", function()
				removeFriend(r.name)
			end)
			row.promote:SetScript("OnClick", function() -- test the sync link to this friend
				tx("PING", r.name)
				print("|cffff8040GankList:|r pinged " .. r.name .. " - waiting for reply...")
			end)
		else -- blacklisted same-faction player
			local r = e.r
			row.name:SetText("|cffffd000" .. r.name .. "|r")
			row.info:SetText(r.b.note ~= "" and "|cffcccccc" .. r.b.note .. "|r" or "|cff808080(no note - click Note to add)|r")
			row.fullNote, row.ttName = r.b.note, r.name
			row.count:SetText("")
			row.del:Show(); row.promote:Show()
			row.promote:SetText("Note")
			row.del:SetScript("OnClick", function()
				removeBlacklist(r.name)
			end)
			row.promote:SetScript("OnClick", function() -- edit the reason
				StaticPopup_Show("GANKLIST_NOTE", "Why is " .. r.name .. " on the blacklist?", nil,
					{ name = r.name, note = r.b.note, add = addBlacklist })
			end)
		end
		row:Show()
	end
	content:SetHeight(math.max(#entries * 36 + 4, 1))
	UI.empty:SetText(tab == "wanted" and "No wanted enemies yet." or tab == "blacklist" and "No blacklisted players. Add one below." or tab == "friends" and "No sync friends yet. Add one below." or "No whitelisted players. Add one below.")
	UI.empty:SetShown(#entries == 0)
end

local function buildUI()
	-- PortraitFrameTemplate gives the skull portrait but isn't on every Classic flavor;
	-- fall back to BasicFrameTemplateWithInset, which exists everywhere.
	local ok, frame = pcall(CreateFrame, "Frame", "GankListFrame", UIParent, "PortraitFrameTemplate")
	if not ok or not frame then
		frame = CreateFrame("Frame", "GankListFrame", UIParent, "BasicFrameTemplateWithInset")
	end
	frame:SetSize(470, 420) -- wide enough for four tabs
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

	-- Wanted / Blacklist / Friends / Whitelist tabs (plain buttons styled as tabs; works on every flavor).
	frame.tab = "wanted"
	local function makeTab(label, x)
		local t = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		t:SetSize(110, 22)
		t:SetPoint("TOPLEFT", x, -56)
		t:SetText(label)
		return t
	end
	frame.tabWanted = makeTab("Wanted", 8)
	frame.tabBlack = makeTab("Blacklist", 122)
	frame.tabFriends = makeTab("Friends", 236)
	frame.tabWhite = makeTab("Whitelist", 350)
	frame.tabWanted:SetScript("OnClick", function() frame.tab = "wanted"; refreshUI() end)
	frame.tabBlack:SetScript("OnClick", function() frame.tab = "blacklist"; refreshUI() end)
	frame.tabFriends:SetScript("OnClick", function() frame.tab = "friends"; refreshUI() end)
	frame.tabWhite:SetScript("OnClick", function() frame.tab = "whitelist"; refreshUI() end)

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -84) -- below the tab row
	scroll:SetPoint("BOTTOMRIGHT", -30, 60) -- leave room for the auto-accept checkbox + buttons
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(420, 1)
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

	-- Add current target to Wanted (same as /gank add with no name).
	local addTgt = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	addTgt:SetSize(150, 22)
	addTgt:SetPoint("BOTTOMLEFT", 28, 8)
	addTgt:SetText("Add Target")
	addTgt:SetScript("OnClick", function()
		local name = UnitExists("target") and UnitIsPlayer("target") and cleanName(UnitName("target"))
		if not name then return end
		record(name, GetRealZoneText(), me, levelSeen[name])
		send(name)
		refreshUI()
		print("|cffff4040GankList:|r added " .. name)
	end)
	frame.addTgt = addTgt
	function frame.updateAddBtn()
		addTgt:SetEnabled(UnitExists("target") and UnitIsPlayer("target") and true or false)
	end
	frame:HookScript("OnShow", frame.updateAddBtn) -- refresh clickable state every time the window opens

	local sync = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	sync:SetSize(150, 22)
	sync:SetPoint("BOTTOMRIGHT", -28, 8)
	sync:SetText("Sync Partners")
	sync:SetScript("OnClick", function() sendAll(); print("|cffff4040GankList:|r pushed list to friends") end)
	frame.sync = sync

	-- Friends tab: type a name + Add to send a friend request (shown only on that tab).
	local addF = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	addF:SetSize(90, 22)
	addF:SetPoint("BOTTOMRIGHT", -28, 8)
	addF:SetText("Add Friend")
	local box = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	box:SetSize(170, 20)
	box:SetPoint("BOTTOMLEFT", 36, 9)
	box:SetAutoFocus(false)
	local function submitFriend()
		local n = box:GetText():gsub('"', ""):gsub("^%s+", ""):gsub("%s+$", "")
		if n ~= "" then requestFriend(n); box:SetText("") end
		box:ClearFocus()
	end
	addF:SetScript("OnClick", submitFriend)
	box:SetScript("OnEnterPressed", submitFriend)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	frame.friendAdd, frame.friendBox = addF, box
	addF:Hide(); box:Hide() -- shown only on the Friends tab (refreshUI toggles)

	-- Blacklist tab: type a name (or target one) + Add, then a popup asks for the reason.
	local addB = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	addB:SetSize(90, 22)
	addB:SetPoint("BOTTOMRIGHT", -28, 8)
	addB:SetText("Blacklist")
	local bbox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	bbox:SetSize(170, 20)
	bbox:SetPoint("BOTTOMLEFT", 36, 9)
	bbox:SetAutoFocus(false)
	local function submitBlack()
		local n = bbox:GetText():gsub('"', ""):gsub("^%s+", ""):gsub("%s+$", "")
		if n == "" and UnitExists("target") and UnitIsPlayer("target") then n = UnitName("target") end
		n = n and cleanName(n)
		if n then bbox:SetText(""); bbox:ClearFocus()
			StaticPopup_Show("GANKLIST_NOTE", "Why is " .. n .. " on the blacklist?", nil, { name = n, add = addBlacklist }) end
	end
	addB:SetScript("OnClick", submitBlack)
	bbox:SetScript("OnEnterPressed", submitBlack)
	bbox:SetScript("OnEscapePressed", bbox.ClearFocus)
	frame.blackAdd, frame.blackBox = addB, bbox
	addB:Hide(); bbox:Hide() -- shown only on the Blacklist tab

	-- Whitelist tab: type a name (or target one) + Add, then a popup asks for the note.
	local addW = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	addW:SetSize(90, 22)
	addW:SetPoint("BOTTOMRIGHT", -28, 8)
	addW:SetText("Whitelist")
	local wbox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	wbox:SetSize(170, 20)
	wbox:SetPoint("BOTTOMLEFT", 36, 9)
	wbox:SetAutoFocus(false)
	local function submitWhite()
		local n = wbox:GetText():gsub('"', ""):gsub("^%s+", ""):gsub("%s+$", "")
		if n == "" and UnitExists("target") and UnitIsPlayer("target") then n = UnitName("target") end
		n = n and cleanName(n)
		if n then wbox:SetText(""); wbox:ClearFocus()
			StaticPopup_Show("GANKLIST_NOTE", "Why is " .. n .. " whitelisted?", nil, { name = n, add = addWhitelist }) end
	end
	addW:SetScript("OnClick", submitWhite)
	wbox:SetScript("OnEnterPressed", submitWhite)
	wbox:SetScript("OnEscapePressed", wbox.ClearFocus)
	frame.whiteAdd, frame.whiteBox = addW, wbox
	addW:Hide(); wbox:Hide() -- shown only on the Whitelist tab

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
		print("|cffff4040GankList|r |cff808080(add the gankers you want listed yourself)|r")
		line("/gank", "open the window")
		line("/gank add Name", "manually add a ganker")
		line("/gank del Name", "remove a ganker")
		line("/gank note Name text", "add/edit a note on a wanted ganker (empty = clear)")
		line("/gank black Name reason", "blacklist a same-faction jerk (or target them)")
		line("/gank white Name note", "whitelist a same-faction friendly (or target them)")
		line("/gank friend Name", "send a sync request  (no name = list, 'reset' = clear)")
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
			if #db.outReq > 0 then print("|cffff8040GankList:|r pending: " .. table.concat(db.outReq, ", ")) end
		elseif name:lower() == "reset" then
			wipe(db.partners); wipe(db.outReq)
			print("|cffff4040GankList:|r cleared all sync friends")
			if refreshUI then refreshUI() end
		else
			requestFriend(name) -- consent flow: they must accept before syncing
		end

	elseif cmd == "unfriend" then
		if arg == "" then print("|cffff4040GankList:|r /gank unfriend <name>") return end
		removeFriend(arg)
		print("|cffff4040GankList:|r stopped syncing with " .. arg)

	elseif cmd == "black" or cmd == "blacklist" or cmd == "bl" then
		local name, note = arg:match("^(%S+)%s*(.-)$")
		name = (name ~= "" and name) or (UnitExists("target") and UnitIsPlayer("target") and UnitName("target"))
		if not name then print("|cffff4040GankList:|r /gank black <name> [reason]  (or target them first)") return end
		addBlacklist(name, note)

	elseif cmd == "white" or cmd == "whitelist" or cmd == "wl" then
		local name, note = arg:match("^(%S+)%s*(.-)$")
		name = (name ~= "" and name) or (UnitExists("target") and UnitIsPlayer("target") and UnitName("target"))
		if not name then print("|cffff4040GankList:|r /gank white <name> [note]  (or target them first)") return end
		addWhitelist(name, note)

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
		for _, p in ipairs(db.partners) do tx("PING", p) end
		print("|cffff8040GankList:|r pinged " .. table.concat(db.partners, ", ") .. " - waiting for reply...")

	elseif cmd == "sync" then
		sendAll()
		print("|cffff4040GankList:|r pushed list to friends")

	elseif cmd == "lfgdebug" then -- dump LFG browse rows so we can see what text/leader each exposes
		print("|cffff8040GankList:|r LFG update hooked: " .. tostring(GankListLFGHooked))
		local sb = LFGBrowseFrameScrollBox
		if not (sb and sb.GetFrames) then
			print("|cffff4040no LFGBrowseFrameScrollBox - open the LFG 'Browse' tab first|r")
		else
			local frames = sb:GetFrames()
			print("rows: " .. #frames)
			for _, entry in ipairs(frames) do
				local parts = {}
				for _, r in ipairs({ entry:GetRegions() }) do
					if r.GetObjectType and r:GetObjectType() == "FontString" then
						local t = r:GetText(); if t and t ~= "" then parts[#parts + 1] = t end
					end
				end
				local id = entry.resultID
				local leader
				if id and C_LFGList and C_LFGList.GetSearchResultInfo then
					local ok, info = pcall(C_LFGList.GetSearchResultInfo, id)
					if ok and type(info) == "table" then leader = info.leaderName end
				end
				print((id and ("#" .. id .. " ") or "") .. "leader=" .. tostring(leader)
					.. " | " .. table.concat(parts, " / "))
			end
		end

	elseif cmd == "add" then
		local name = arg ~= "" and arg or (UnitExists("target") and UnitIsPlayer("target") and UnitName("target"))
		name = name and cleanName(name)
		if not name then print("|cffff4040GankList:|r /gank add <name>  (or target a player first)") return end
		record(name, GetRealZoneText(), me)
		send(name)
		if refreshUI then refreshUI() end
		print("|cffff4040GankList:|r added " .. name)

	elseif cmd == "note" then
		local name, note = arg:match("^(%S+)%s*(.-)$")
		name = (name ~= "" and name) or (UnitExists("target") and UnitIsPlayer("target") and UnitName("target"))
		name = name and cleanName(name)
		if not name then print("|cffff4040GankList:|r /gank note <name> <text>  (or target them first)") return end
		if not db.gankers[name] then print("|cffff4040GankList:|r " .. name .. " isn't on the Wanted list") return end
		setGankNote(name, note)
		print("|cffff4040GankList:|r note " .. (note ~= "" and "set" or "cleared") .. " for " .. name)

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
		for i, r in ipairs(rows) do
			if i > 10 then SendChatMessage(("...and %d more"):format(#rows - 10), chan) break end -- cap: avoid chat-spam disconnect
			SendChatMessage(("%s x%d (%s)"):format(r.name, r.g.count, r.g.zone or "?"), chan)
		end

	elseif msg:gsub('["%s]', "") ~= "" then -- unknown input: gankers can't be added by hand
		print("|cffff4040GankList:|r unknown command. /gank help")

	else -- bare /gank - open the window
		toggleUI()
	end
end

-- ---- LFG browse highlighting --------------------------------------------
-- The TBC Anniversary LFG tool is a bulletin-board browser, not a unit list,
-- so the unit/tooltip alerts never fire on it. Instead we post-hook the browse
-- refresh and stamp a red ⚠ onto any result row whose name is on the blacklist
-- (or Wanted). Row frame/fontstring names differ between client builds, so we
-- scan each row's FontStrings rather than hardcode a name region.
-- ponytail: covers the LFG browser only (Who panel uses the same trick if needed).

local function lfgListed(text) -- returns "blacklist" / "gank" / nil for a row's text
	local name = cleanName(text)
	if not name then return nil end
	local db = ensureDB()
	local base = name:match("^[^-]+")
	if db.blacklist[name] then return "blacklist" end
	if db.gankers[name] then return "gank" end
	for k in pairs(db.blacklist) do if k:match("^[^-]+") == base then return "blacklist" end end
	for k in pairs(db.gankers) do if k:match("^[^-]+") == base then return "gank" end end
	return nil
end

-- Inline skull texture (raid-target icon 8: texcoords 0.75-1.0, 0.25-0.5 of the 256x256 atlas).
local LFG_MARK = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcons:16:16:0:0:256:256:192:256:64:128|t "

-- Prepend the skull to any FontString in `frame` (and its children) whose text is a
-- listed player. Reused for LFG result rows and the result-member tooltip - the latter
-- keeps each member's name in a child frame, so we recurse. MARK guard = idempotent.
local function markListedText(frame, depth)
	if not frame then return end
	if frame.GetRegions then
		for _, r in ipairs({ frame:GetRegions() }) do
			if r.GetObjectType and r:GetObjectType() == "FontString" then
				local txt = r:GetText()
				if txt and txt ~= "" and txt:sub(1, #LFG_MARK) ~= LFG_MARK and lfgListed(txt) then
					r:SetText(LFG_MARK .. txt)
					-- fixed-width fields (tooltip member names) truncate to "Ny..."; widen to fit
					if r.IsTruncated and r:IsTruncated() and r.GetUnboundedStringWidth then
						r:SetWidth(r:GetUnboundedStringWidth() + 2)
					end
				end
			end
		end
	end
	depth = depth or 0
	if depth < 4 and frame.GetChildren then
		for _, c in ipairs({ frame:GetChildren() }) do markListedText(c, depth + 1) end
	end
end

local function lfgScan()
	local sb = LFGBrowseFrameScrollBox
	if not sb or not sb.GetFrames then return end
	for _, entry in ipairs(sb:GetFrames()) do markListedText(entry) end
end

-- Real player unit tooltips (party frames, world mouseover): add a skull line.
GameTooltip:HookScript("OnTooltipSetUnit", function(tt)
	local _, unit = tt:GetUnit()
	if unit and UnitIsPlayer(unit) then
		local n = UnitName(unit)
		if n and lfgListed(n) then tt:AddLine(LFG_MARK .. "GankList", 1, 0.2, 0.2); tt:Show() end
	end
end)

-- The LFG UI is a load-on-demand Blizzard addon, so its ScrollBox may not exist
-- when we load. Retry the hook on each ADDON_LOADED until the ScrollBox appears.
GankListLFGHooked = false -- exposed for /gank lfgdebug
local function lfgTryHook()
	if GankListLFGHooked then return end
	local sb = LFGBrowseFrameScrollBox
	if sb and sb.Update and sb.GetFrames then
		hooksecurefunc(sb, "Update", lfgScan)
		-- The result-member tooltip lists each group member by name; skull the listed ones.
		local tip = LFGBrowseSearchEntryTooltip
		if tip then tip:HookScript("OnShow", markListedText) end
		GankListLFGHooked = true
	end
end
local lfgEv = CreateFrame("Frame")
lfgEv:RegisterEvent("ADDON_LOADED")
lfgEv:RegisterEvent("PLAYER_LOGIN")
lfgEv:SetScript("OnEvent", lfgTryHook)
lfgTryHook()
