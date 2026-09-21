-- onRoom: does a newly seen room get FULLY registered?
-- Written for the elro.cell_index collision (two modules, eqw's won), which threw inside
-- onRoom's new-room branch; Mudlet abandons a trigger on error, so the room got no
-- coordinates, no exits and no dirty bookkeeping.
-- ⚠ The parent is placed AWAY FROM THE ORIGIN: at (0,0) a broken and a correct child both
-- read as (0,0)+delta and the test proves nothing.
-- Run: luajit analysis/test_onroom.lua      (from the client dir)
dofile("analysis/engine_load.lua")

local fail, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("FAIL %-54s got %s want %s", what, tostring(got), tostring(want)))
  end
end

local realcecho = cecho
cecho = function() end
elro.flush_dirty = function() end
elro.flush = function() end
elro.bg_busy = function() return false end

-- ---- the two cell helpers core owns, called directly ----------------------
-- If another module redefines elro.cell_index these die rather than mislead.
reset_map()
local aid = addAreaName("cells")
addRoom(7) ; setRoomArea(7, aid) ; setRoomCoordinates(7, 3, 4, 0)
elro.cs_reset()
eq(elro.cell_at(aid, 3, 4), 7, "cell_at finds the room at its cell")
eq(elro.cell_at(aid, 9, 9), nil, "cell_at is nil on an empty cell")
elro.cell_put(aid, 9, 9, 7)
eq(elro.cell_at(aid, 9, 9), 7, "cell_put then cell_at round-trips")
elro.cell_drop(aid)
eq(elro.cell_at(aid, 3, 4), 7, "cell_drop rebuilds from the map, not from nothing")
elro.cell_drop()
eq(type(elro._cellIx), "table", "cell_drop() leaves a table, never nil")

-- ---- a new room arriving next to a parent that is NOT at the origin -------
reset_map()
local a2 = addAreaName("gurk")
addRoom(1) ; setRoomArea(1, a2)
setRoomUserData(1, "sarea", "gurk")
setRoomCoordinates(1, 10, 10, 0)
elro.cs_reset()
elro.dirty = {}

elro.onRoom(2, 1, "east", "the gate", "gurk", "east,west", "")

eq(roomExists(2), true, "the new room was created")
local x, y = getRoomCoordinates(2)
eq(x .. "," .. y, "11,10", "...placed one step EAST of its parent, not dumped at 0,0")
eq(getRoomExits(1)["east"], 2, "...the forward exit was written")
eq(getRoomExits(2)["west"], 1, "...and the advertised reverse exit too")
eq(getRoomUserData(2, "sarea"), "gurk", "...the server area was recorded")
eq(next(elro.dirty) ~= nil, true, "...and the area was marked dirty")

-- a second step keeps walking outward rather than collapsing to the origin
elro.onRoom(3, 2, "east", "the road", "gurk", "east,west", "")
local x3, y3 = getRoomCoordinates(3)
eq(x3 .. "," .. y3, "12,10", "a second new room steps on from the first")

-- ---- the anchor is a room we had to RESURRECT --------------------------------
-- After a scoped mapwipe the server still reports `from=<a room we deleted>`. onRoom
-- recreates it, and addRoom leaves it at Mudlet's default (0,0). Stepping off that would
-- put the new room at (1,0) -- a real-looking coordinate derived from a meaningless one,
-- which then anchors the NEXT room, walking the whole re-exploration back to the origin.
reset_map()
local a3 = addAreaName("gurk")
addRoom(50) ; setRoomArea(50, a3) ; setRoomCoordinates(50, 40, 40, 0)  -- an unrelated room
elro.cs_reset() ; elro.dirty = {}
elro.onRoom(61, 60, "east", "the gate", "gurk", "east,west", "")   -- 60 does not exist
eq(roomExists(60), true, "a missing fromId is still recreated (the edge is real)")
local rx, ry = getRoomCoordinates(61)
eq(rx .. "," .. ry ~= "1,0", true, "the new room is NOT stepped off the (0,0) phantom")
eq(getRoomExits(60)["east"], 61, "...the edge is still recorded")
eq(next(elro.dirty) ~= nil, true, "...and a relayout is queued to place them properly")

-- ---- the anchor has no coordinates at all ------------------------------------
-- getRoomCoordinates returning nil used to reach `fx + del[1]`, and an error inside onRoom
-- makes Mudlet abandon the trigger -- the half-registered room the cell_index collision
-- produced. It must fall through, not throw.
reset_map()
local a4 = addAreaName("gurk")
addRoom(70) ; setRoomArea(70, a4) ; setRoomCoordinates(70, 5, 5, 0)
elro.cs_reset() ; elro.dirty = {}
local realGRC = getRoomCoordinates
getRoomCoordinates = function(id) if id == 70 then return nil end return realGRC(id) end
local ok = pcall(elro.onRoom, 71, 70, "east", "the gate", "gurk", "east,west", "")
getRoomCoordinates = realGRC
eq(ok, true, "a coordinate-less anchor does not throw out of onRoom")
eq(roomExists(71), true, "...the room is still created")
eq(getRoomExits(70)["east"], 71, "...and its exit still written -- not half registered")

-- ---- colour in the room name ---------------------------------------------
-- NannyMUD shorts carry ANSI. Only the ESC is a control character, so a filter that
-- drops it alone leaves "a lounge <ESC>[38;40;0m" as the visible name "a lounge [...]".
local E = string.char(27)
eq(elro.strip_ansi("a lounge" .. E .. "[38;40;0m"), "a lounge", "a colour tail is stripped")
eq(elro.strip_ansi(E .. "[1;32mgreen" .. E .. "[0m"), "green", "colour at both ends")
eq(elro.strip_ansi("bracket [north] kept"), "bracket [north] kept",
   "a real bracket is NOT stripped")
reset_map()
local a5 = addAreaName("gurk")
addRoom(80) ; setRoomArea(80, a5) ; setRoomCoordinates(80, 1, 1, 0)
elro.cs_reset() ; elro.dirty = {}
elro.onRoom(81, 80, "east", "a lounge" .. E .. "[38;40;0m", "gurk", "east,west", "")
eq(getRoomName(81), "a lounge", "onRoom stores the name without the escape")

-- ---- a room DELETED IN THE GUI, then walked into again -----------------------
-- The symptom is ONE-WAY EDGES: nothing hooks a GUI deletion, so the neighbour's
-- c-space record still names the deleted id and the "already have this edge"
-- test skips the write.
reset_map()
local a6 = addAreaName("gurk")
addRoom(90) ; setRoomArea(90, a6) ; setRoomCoordinates(90, 5, 5, 0)
elro.cs_reset() ; elro.dirty = {}
elro.onRoom(91, 90, "east", "the gate", "gurk", "east,west", "")
eq(getRoomExits(90)["east"], 91, "the edge is there to begin with")
elro.cs_room(90)                          -- materialize the NEIGHBOUR, as walking does
-- TWO CALLS: the stub's deleteRoom is a bare table removal, while Mudlet also
-- drops every exit INTO the room. Without the second the test is vacuous.
deleteRoom(91) ; setExit(90, -1, "east")
eq(getRoomExits(90)["east"], nil, "Mudlet took the neighbour's exit with it")
eq(elro.cs[90] ~= nil, true, "...but the neighbour's stale record survives")
elro.onRoom(91, 90, "east", "the gate", "gurk", "east,west", "")
eq(roomExists(91), true, "walking in again recreates the room")
eq(getRoomExits(90)["east"], 91, "...and the edge INTO it is written, not skipped")
eq(getRoomExits(91)["west"], 90, "...with the advertised reverse edge as well")

-- ---- a loop closed by WALKING between two placed rooms -----------------------
-- The closing edge is the one walked, so it is the edge the urgency check must judge; as
-- `skip` it used to be the one edge never looked at. Asserted through markDirty's argument.
local function closure(x4, y4)
  reset_map()
  local a = addAreaName("gurk")
  for id, c in pairs({ [1] = { 10, 10 }, [2] = { 11, 10 }, [3] = { 11, 11 }, [4] = { x4, y4 } }) do
    addRoom(id) ; setRoomArea(id, a) ; setRoomCoordinates(id, c[1], c[2], 0)
    setRoomUserData(id, "sarea", "gurk")
  end
  setExit(1, 2, "east") ; setExit(2, 1, "west") ; setExit(2, 3, "north") ; setExit(3, 2, "south")
  setExit(3, 4, "west") ; setExit(4, 3, "east")
  elro.cs_reset() ; elro.dirty = {}
  local urgent
  local realMD, realAF = elro.markDirty, elro.autoflush
  elro.markDirty = function(_, u) urgent = u and true or false end
  elro.autoflush = true
  elro.onRoom(1, 4, "south", "the start", "gurk", "east,north", "")
  elro.markDirty, elro.autoflush = realMD, realAF
  return urgent
end
eq(closure(10, 11), false, "a walked closure that is truthful is NOT urgent")
eq(closure(12, 11), true, "a walked closure that lies makes the relayout urgent")

-- ---- a new room with NO edge (login, teleport) --------------------------------
-- It gets no guess and stays at addRoom's (0,0), where a laid-out area has a room.
reset_map()
local a7 = addAreaName("gurk")
addRoom(1) ; setRoomArea(1, a7) ; setRoomCoordinates(1, 0, 0, 0) ; setRoomUserData(1, "sarea", "gurk")
elro.cs_reset() ; elro.dirty = {}
do
  local urgent
  local realMD, realAF = elro.markDirty, elro.autoflush
  elro.markDirty = function(_, u) urgent = u and true or false end
  elro.autoflush = true
  elro.onRoom(2, 0, "none", "somewhere else", "gurk", "east", "")
  elro.markDirty, elro.autoflush = realMD, realAF
  eq(urgent, true, "a new room that arrived with no edge makes the relayout urgent")
end

cecho = realcecho
print(string.format("test_onroom: %d check(s), %d failure(s)", checks, fail))
os.exit(fail == 0 and 0 or 1)
