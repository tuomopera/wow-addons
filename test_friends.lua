-- Headless harness: stub just enough WoW API to drive the friend-request protocol.
local sent = {}                       -- outgoing {payload,to}
local eventFrame, popup, active

local function stubFrame()
  local t = { scripts = {}, events = {} }
  setmetatable(t, { __index = function() return function() end end }) -- any unknown method = no-op
  t.RegisterEvent = function(s, e) s.events[e] = true end
  t.IsEventRegistered = function(s, e) return s.events[e] end
  t.SetScript = function(s, n, fn) s.scripts[n] = fn end
  t.HookScript = function() end
  return t
end
function CreateFrame(kind) local f = stubFrame(); if kind == "Frame" and not eventFrame then eventFrame = f end; return f end

-- Model the throttled ticker faithfully: NewTicker returns a handle; pump() drains
-- it AFTER the addon assigned outTicker (so its self-cancel branch fires correctly).
C_Timer = { After = function() end,
  NewTicker = function(_, fn) local h = {}; h.Cancel = function() h.cancelled = true end; active = { fn = fn, h = h }; return h end }
local function pump() local n = 0; while active and not active.h.cancelled and n < 5000 do active.fn(); n = n + 1 end; active = nil end

C_ChatInfo = { SendAddonMessage = function(_, p, _, to) sent[#sent+1]={p,to} end,
  RegisterAddonMessagePrefix = function() end, IsAddonMessagePrefixRegistered = function() return true end }
C_NamePlate = { GetNamePlates = function() return {} end }
function strsplit(sep, s) local r={}; for p in (s..sep):gmatch("(.-)"..sep) do r[#r+1]=p end; return unpack(r) end
time=function() return 1000 end; date=function() return "now" end; print=function() end
GetTime=function() return 0 end; wipe=function(t) for k in pairs(t) do t[k]=nil end end
tinsert=table.insert
UnitName=function() return "Me" end; UnitGUID=function() return "G" end; UnitExists=function() return false end
UnitIsPlayer=function() return false end; UnitCanAttack=function() return false end; UnitLevel=function() return 1 end
GetRealZoneText=function() return "Z" end
StaticPopupDialogs={}; function StaticPopup_Show(w,a,b,d) popup={which=w,data=d} end
SLASH_GANK1=""; SlashCmdList={}
bit={band=function() return 0 end}; COMBATLOG_OBJECT_TYPE_PLAYER=1; COMBATLOG_OBJECT_REACTION_HOSTILE=1
UISpecialFrames={}
GameTooltip=stubFrame()
local instanceType = "none"
IsInInstance=function() return instanceType ~= "none", instanceType end

assert(loadfile("GankList/GankList.lua"))()
local onEvent = eventFrame.scripts.OnEvent
local gank = SlashCmdList.GANK
local function rx(payload, sender) onEvent(eventFrame, "CHAT_MSG_ADDON", "GankList", payload, nil, sender); pump() end
local function slash(s) gank(s); pump() end
local function clear() sent = {} end
local function sentTo(kind, to)
  for _,m in ipairs(sent) do local k=strsplit("\t", m[1]); if k==kind and m[2]==to then return true end end
  return false
end

-- 1. We request Alice -> FREQ sent, Alice pending, not yet a partner.
clear(); slash("friend Alice")
assert(sentTo("FREQ","Alice"), "FREQ not sent")
assert(GankListDB.outReq[1]=="Alice" and #GankListDB.partners==0, "Alice should be pending only")

-- 2. Alice accepts (FACC) -> Alice becomes a partner, request cleared.
clear(); rx("FACC", "Alice")
assert(#GankListDB.outReq==0 and GankListDB.partners[1]=="Alice", "FACC should promote Alice to partner")

-- 3. SECURITY: unsolicited FACC from a stranger is ignored (no partner added).
clear(); rx("FACC", "Stranger")
for _,p in ipairs(GankListDB.partners) do assert(p~="Stranger","unsolicited FACC must NOT add a partner") end

-- 4. Incoming FREQ shows a consent popup (never auto-adds).
popup=nil; rx("FREQ", "Carol")
assert(popup and popup.which=="GANKLIST_FRIENDREQ" and popup.data.name=="Carol", "FREQ should show consent popup")
for _,p in ipairs(GankListDB.partners) do assert(p~="Carol","FREQ must not auto-add before accept") end

-- 5. Already-partner FREQ re-confirms silently with FACC (no popup spam).
popup=nil; clear(); rx("FREQ", "Alice")
assert(popup==nil and sentTo("FACC","Alice"), "FREQ from existing partner should re-confirm silently")

-- ---- blacklist (Alice is a partner from the steps above) -----------------
-- 6. Add a same-faction jerk with a note via slash -> stored + pushed to partner.
clear(); slash("black Ninja stole my tag")
assert(GankListDB.blacklist["Ninja"], "blacklist add failed")
assert(GankListDB.blacklist["Ninja"].note == "stole my tag", "note not stored: "..tostring(GankListDB.blacklist["Ninja"].note))
assert(sentTo("B","Alice"), "blacklist entry not synced to partner")

-- 7. SECURITY: a received note is stripped of | injection and length-capped.
rx("B\tJerk\tbad|cffff0000guy|Hitem\tAlice\t1000", "Alice")
assert(GankListDB.blacklist["Jerk"], "received blacklist entry missing")
assert(not GankListDB.blacklist["Jerk"].note:find("|"), "note must not contain pipe escapes")

-- 8. SECURITY: blacklist data from a non-partner is dropped at the gate.
rx("B\tFromStranger\twhatever\tStranger\t1000", "Stranger")
assert(not GankListDB.blacklist["FromStranger"], "non-partner blacklist must be ignored")

-- 9. Older timestamp does not overwrite a newer note; newer one does.
GankListDB.blacklist["Jerk"] = { note = "newer", by = "me", t = 5000 }
rx("B\tJerk\tolder\tAlice\t1000", "Alice")  -- older t
assert(GankListDB.blacklist["Jerk"].note == "newer", "older sync must not overwrite")
rx("B\tJerk\tfreshest\tAlice\t9000", "Alice") -- newer t
assert(GankListDB.blacklist["Jerk"].note == "freshest", "newer sync should update")

-- 10. BR removes a blacklisted player.
rx("BR\tJerk", "Alice")
assert(not GankListDB.blacklist["Jerk"], "BR should remove the entry")

-- ---- whitelist (mirror of blacklist) -------------------------------------
-- 10a. Add a same-faction friendly with a note -> stored + pushed to partner.
clear(); slash("white Pal good healer")
assert(GankListDB.whitelist["Pal"], "whitelist add failed")
assert(GankListDB.whitelist["Pal"].note == "good healer", "white note not stored")
assert(sentTo("W","Alice"), "whitelist entry not synced to partner")

-- 10b. SECURITY: received note stripped of | injection; non-partner dropped.
rx("W\tBuddy\tnice|cffff0000guy\tAlice\t1000", "Alice")
assert(GankListDB.whitelist["Buddy"] and not GankListDB.whitelist["Buddy"].note:find("|"), "white note must strip pipes")
rx("W\tNope\twhatever\tStranger\t1000", "Stranger")
assert(not GankListDB.whitelist["Nope"], "non-partner whitelist must be ignored")

-- 10c. WR removes a whitelisted player.
rx("WR\tPal", "Alice")
assert(not GankListDB.whitelist["Pal"], "WR should remove the entry")

-- ---- kill handling: Wanted player gets a count bump; nothing auto-logged --
onEvent(eventFrame, "PLAYER_LOGIN") -- sets playerGUID = "G"
-- real-ish combat-log flags so the addon's bit.band sees player + hostile
COMBATLOG_OBJECT_TYPE_PLAYER = 0x400; COMBATLOG_OBJECT_REACTION_HOSTILE = 0x40
bit = { band = function(a, m) return (math.floor(a / m) % 2 == 1) and m or 0 end }
local cl
CombatLogGetCurrentEventInfo = function() return unpack(cl) end
local function gankedBy(srcName) -- simulate: hostile player damages me, then I die
  cl = { 0, "SWING_DAMAGE", false, "E", srcName, 0x400 + 0x40, 0, "G", "Me" }
  onEvent(eventFrame, "COMBAT_LOG_EVENT_UNFILTERED")
  onEvent(eventFrame, "PLAYER_DEAD"); pump()
end

-- 11. Killer already on Wanted -> bump that count.
GankListDB.gankers["Hunter"] = { count = 2, by = "me", last = 0 }
gankedBy("Hunter")
assert(GankListDB.gankers["Hunter"].count == 3, "Wanted count should bump on repeat gank")

-- 12. Killer not on Wanted -> not auto-added anywhere (you add gankers yourself).
gankedBy("Random")
assert(not GankListDB.gankers["Random"], "unknown killer must NOT be auto-added to Wanted")
assert(GankListDB.pending == nil, "suspects/pending list should no longer exist")

-- ---- wanted notes --------------------------------------------------------
-- 13. /gank note sets a note on a Wanted ganker and pushes it to partners.
clear(); slash("note Hunter camps the flightpath")
assert(GankListDB.gankers["Hunter"].note == "camps the flightpath", "wanted note not stored")
assert(sentTo("G","Alice"), "note change not synced to partner")

-- 14. SECURITY: a received G note is stripped of | injection.
rx("G\tCamper\t5\tZ\tAlice\t1000\tbad|cffff0000guy", "Alice")
assert(GankListDB.gankers["Camper"] and not GankListDB.gankers["Camper"].note:find("|"), "G note must strip pipes")

-- 15. A partner's non-empty note is adopted onto an existing ganker.
rx("G\tHunter\t3\tZ\tAlice\t2000\tfresh note", "Alice")
assert(GankListDB.gankers["Hunter"].note == "fresh note", "partner note should be adopted")

-- ---- battleground/arena mute --------------------------------------------
-- 16. In a BG, a repeat gank by a Wanted player is ignored (muted by default).
assert(GankListDB.mutePvP == true, "mutePvP should default on")
local before = GankListDB.gankers["Hunter"].count
instanceType = "pvp"; gankedBy("Hunter")
assert(GankListDB.gankers["Hunter"].count == before, "BG deaths must not count while muted")
instanceType = "arena"; gankedBy("Hunter")
assert(GankListDB.gankers["Hunter"].count == before, "arena deaths must not count while muted")

-- 17. Toggling the option off restores counting inside a BG.
slash("pvp off")
gankedBy("Hunter")
assert(GankListDB.gankers["Hunter"].count == before + 1, "BG deaths should count once unmuted")
slash("pvp on"); instanceType = "none"

io.write("ALL TESTS PASSED (friend requests + blacklist + whitelist + kill handling + notes)\n")
