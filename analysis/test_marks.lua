-- mapmark / mapreturn: a named bookmark lives on the room, a name moves when re-marked, a
-- bare name is "here", return walks through gotoRoom, unmark forgets.
-- Run: luajit analysis/test_marks.lua      (from the client dir)
dofile("analysis/engine_load.lua")

local fail, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("FAIL %-56s got %s want %s", what, tostring(got), tostring(want)))
  end
end

reset_map()
local aid = addAreaName("town")
for id = 1, 3 do
  addRoom(id) ; setRoomArea(id, aid) ; setRoomCoordinates(id, id, 0, 0) ; setRoomName(id, "room " .. id)
end
setExit(1, 2, "east") ; setExit(2, 1, "west") ; setExit(2, 3, "east") ; setExit(3, 2, "west")
elro.cs_reset()

local said = {}
cecho = function(s) said[#said + 1] = s end
-- Mudlet's temp aliases, faked: what is registered, by pattern
local aliases, nextAlias = {}, 0
tempAlias = function(pat, fn) nextAlias = nextAlias + 1 ; aliases[nextAlias] = { pat, fn } ; return nextAlias end
killAlias = function(id) aliases[id] = nil ; return true end
local function alias_for(word)
  for _, a in pairs(aliases) do if a[1] == "^" .. word .. "$" then return a end end
end
local walked
local realGoto = elro.gotoRoom
elro.gotoRoom = function(id) walked = id end

elro.current = nil
elro.cmd_mark()
eq(said[#said]:find("move once first", 1, true) ~= nil, true, "no current room: refused")

elro.current = 1
elro.cmd_mark()
eq(getRoomUserData(1, "mark"), "here", "bare mapmark marks the room as 'here'")
elro.cmd_mark("Shop")
eq(getRoomUserData(1, "mark"), "shop", "a named mark, lower-cased, replaces the room's mark")
eq(elro.mark_find("here"), nil, "...so 'here' is gone from it")

elro.current = 3
elro.cmd_mark("shop")
eq(getRoomUserData(3, "mark"), "shop", "re-marking a name moves it to the new room")
eq(getRoomUserData(1, "mark"), "", "...and clears it from the old one")

elro.current = 1
elro.cmd_return("shop")
eq(walked, 3, "mapreturn walks to the mark")
walked = nil
elro.cmd_return()
eq(walked, nil, "no 'here' mark: no walk")
eq(said[#said]:find("no mark called 'here'", 1, true) ~= nil, true, "...and says so")

elro.current = 3
elro.cmd_return("shop")
eq(walked, nil, "already there: no walk")

elro.cmd_mark()
eq(getRoomUserData(3, "mark"), "here", "a room holds one mark: 'here' replaces 'shop' on it")
elro.current = 1
elro.cmd_mark("shop")
elro.cmd_marks()
eq(said[#said - 2]:find("2 mark", 1, true) ~= nil, true, "mapmarks counts both")
eq(alias_for("shop") ~= nil, true, "a named mark registers the word as an alias")
eq(alias_for("here"), nil, "...'here' does not")
elro.cmd_unmark("shop")
eq(elro.mark_find("shop"), nil, "mapunmark forgets")
eq(alias_for("shop"), nil, "...and gives the word back")
elro.cmd_unmark("shop")
eq(said[#said]:find("no mark called", 1, true) ~= nil, true, "forgetting twice is refused")
elro.cmd_mark("north")
eq(said[#said]:find("a word the game needs", 1, true) ~= nil, true, "a direction is refused as a name")
elro.cmd_mark("two words")
eq(said[#said]:find("one word", 1, true) ~= nil, true, "a name is one word")
-- a reload rebuilds the aliases from the marks in the map
elro.current = 2 ; elro.cmd_mark("bank")
aliases = {}
elro.mark_aliases_rebuild()
eq(alias_for("bank") ~= nil, true, "rebuild registers every named mark in the map")
walked = nil
elro.current = 1
alias_for("bank")[2]()
eq(walked, 2, "typing the word walks to the mark")

-- The one-line loop: 'mapmark;mapreturn shop;z;mapreturn'. No !NMP has come back when the
-- second walk is asked for, so it must plan from the first walk's destination.
elro.gotoRoom = realGoto
local sent = {}
send = function(s) sent[#sent + 1] = s end
getPath = function(a, b)                        -- the straight corridor 1-2-3
  if a == b then return false end
  local step = a < b and 1 or -1
  local dir = a < b and "east" or "west"
  speedWalkDir, speedWalkPath = {}, {}
  -- as Mudlet does: the ids come as STRINGS
  for r = a + step, b, step do speedWalkDir[#speedWalkDir + 1] = dir ; speedWalkPath[#speedWalkPath + 1] = tostring(r) end
  return true
end
elro.smap = {}
elro.current = 3 ; elro.cmd_mark("shop")
elro.current = 1 ; elro.cmd_mark()               -- 'here' = 1, 'shop' = 3
getRoomName = function(id) return "room " .. id end
-- the whole walk goes out at once; the !NMPs only say where it got to
elro.cmd_return("shop")
eq(table.concat(sent, " "), "east east", "first walk, 1 to 3: sent whole")
eq(elro.walkTarget, 3, "...and its destination is remembered")
-- 'mapmark here;shop;sell;mapreturn' on one line: the second walk is planned from
-- the first's end and goes out at once, so it keeps its place in the order typed
elro.cmd_return()                                -- back to 'here' = 1, planned from 3
eq(table.concat(sent, " "), "east east west west", "...the second walk follows on at once")
eq(elro.walkTarget, 1, "the new destination takes over")
eq(#elro.walkQueue, 4, "east east west west queued")
elro.current = 2 ; elro.walk_seen(2)
elro.current = 3 ; elro.walk_seen(3)
elro.current = 2 ; elro.walk_seen(2)
eq(elro.walkAt, 3, "each !NMP counts a step")
elro.current = 1 ; elro.walk_seen(1)
eq(elro.walkQueue, nil, "arrived: the walk is gone")
-- a mark that is the running walk's end: already on the way, nothing sent
sent = {} ; said = {}
elro.cmd_return("shop")
elro.cmd_return("shop")
eq(table.concat(sent, " "), "east east", "a walk to where the running one ends sends nothing more")
eq(said[#said]:find("you are at 'shop'", 1, true) ~= nil, true, "...and says so")
elro.current = 2 ; elro.walk_seen(2) ; elro.current = 3 ; elro.walk_seen(3)
-- a push off the path: the burst is already at the server; the map says what happened
elro.current = 1 ; sent = {} ; said = {}
elro.cmd_return("shop")
elro.current = 9 ; elro.walk_seen(9)             -- a !NMP for a room off the path
eq(elro.walkQueue, nil, "pushed off the path: the walk is over")
eq(said[#said]:find("stopped short", 1, true) ~= nil, true, "...and it says so")
-- a walk that halts (a closed door): no !NMP, no word; a second later it no longer counts
elro.current = 1 ; sent = {} ; said = {}
elro.cmd_return("shop")
elro.current = 2 ; elro.walk_seen(2)
eq(#said, 0, "halted: nothing is said")
eq(elro.walk_busy(), true, "...but it still counts as running")
elro.walkLast = elro.now_ms() - 1100
eq(elro.walk_busy(), false, "a second without a !NMP: it does not")
sent = {}
elro.cmd_return("shop")                          -- a new walk replaces the old
eq(table.concat(sent, " "), "east", "...planned from where we are, at once")
eq(elro.walkAt, 0, "...as a fresh walk")
elro.walkQueue, elro.walkTarget, elro.walkPath = nil, nil, nil
-- off the map: the last mapped room is not where we are
elro.current = 1 ; elro.offmap = 1 ; sent = {} ; said = {}
elro.cmd_mark("nowhere")
eq(said[#said]:find("off the map", 1, true) ~= nil, true, "a mark off the map is refused")
eq(elro.mark_find("nowhere"), nil, "...and not set")
elro.cmd_return("shop")
eq(#sent, 0, "a walk from off the map sends nothing")
eq(said[#said]:find("off the map", 1, true) ~= nil, true, "...and says why")
elro.offmap = nil
elro.current = 1                                 -- back at 'here' for the checks below
sent = {}
elro.cmd_return()
eq(#sent, 0, "at 'here' with no walk in flight: nothing sent")
eq(said[#said]:find("you are at 'here'", 1, true) ~= nil, true, "...and it says so")

print(string.format("test_marks: %d check(s), %d failure(s)", checks, fail))
os.exit(fail > 0 and 1 or 0)
