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

io.write("ALL FRIEND-REQUEST TESTS PASSED\n")
