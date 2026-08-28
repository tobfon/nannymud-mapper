-- elro.map_wipe deletes rooms in bulk, so the GUARD is what is under test: no `confirm`
-- deletes nothing, the scope is the SERVER area (`sarea`) rather than the canvas, and an
-- unknown area is refused.
-- Run: luajit analysis/test_mapwipe.lua      (from the client dir)
dofile("analysis/engine_load.lua")

local fail, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("FAIL %-52s got %s want %s", what, tostring(got), tostring(want)))
  end
end

-- Two server areas laid out onto ONE canvas area, which is the case the canvas cannot
-- distinguish and `sarea` can: a fold/steal/merge puts foreign rooms on the same tab.
local function build()
  reset_map()
  local aid = addAreaName("canvas")
  for id = 1, 6 do
    addRoom(id) ; setRoomArea(id, aid)
    setRoomUserData(id, "sarea", id <= 3 and "gurk" or "maelstorm")
  end
  setExit(1, 2, "east") ; setExit(2, 1, "west")
  setExit(3, 4, "east") ; setExit(4, 3, "west")   -- the edge ACROSS the two server areas
  setExit(5, 6, "east") ; setExit(6, 5, "west")
  elro.cs_reset()
  elro.dirty = {}
end

local function nrooms()
  local n = 0
  for _ in pairs(getRooms()) do n = n + 1 end
  return n
end

-- silence the command's own output, and capture it so the guard's wording can be asserted
local said = ""
local realcecho = cecho
cecho = function(s) said = said .. s end
elro.flush_dirty = function() end

-- 1. bare mapwipe reports and deletes nothing
build() ; said = ""
elro.map_wipe("")
eq(nrooms(), 6, "bare mapwipe deletes nothing")
eq(said:find("would delete 6") ~= nil, true, "...and says it would delete all 6")

-- 2. a scoped report counts only that SERVER area, and still deletes nothing
build() ; said = ""
elro.map_wipe("gurk")
eq(nrooms(), 6, "scoped report deletes nothing")
eq(said:find("would delete 3") ~= nil, true, "...and counts 3, not the 6 on the canvas")

-- 3. an unknown area is refused and names the ones that exist
build() ; said = ""
elro.map_wipe("nosucharea confirm")
eq(nrooms(), 6, "unknown area deletes nothing EVEN WITH confirm")
eq(said:find("gurk") ~= nil and said:find("maelstorm") ~= nil, true, "...and lists the known areas")

-- 4. a confirmed scoped wipe takes exactly that area
build() ; said = ""
elro.map_wipe("gurk confirm")
eq(nrooms(), 3, "scoped confirm deletes exactly the 3 gurk rooms")
eq(roomExists(1) or roomExists(2) or roomExists(3), false, "...the gurk rooms are gone")
eq(roomExists(4) and roomExists(5) and roomExists(6), true, "...maelstorm is untouched")
-- the cross-area edge 4 -> 3 must not survive as a dangling exit
eq(getRoomExits(4)["west"], nil, "the edge into the wiped area is unlinked")
eq(getRoomExits(5)["east"], 6, "an edge between two survivors is untouched")

-- 5. case-insensitive, matching detect_mazes
build() ; elro.map_wipe("GURK confirm")
eq(nrooms(), 3, "area match is case-insensitive")

-- 6. full confirm takes everything
build() ; elro.map_wipe("confirm")
eq(nrooms(), 0, "mapwipe confirm deletes the whole map")

-- 7. emptying an area must not leave a dirty flag naming it: there were two drop-empty
-- loops and only one cleared elro.dirty. One function now.
build()
local gone = getRoomArea(1)
elro.map_wipe("gurk confirm")
elro.recompute_areas()
eq(elro.dirty[gone], nil, "no dirty flag survives for an area that was deleted")
for aid in pairs(elro.dirty) do
  eq(next(elro.cs_area_rooms(aid)) ~= nil or elro.areaName(aid) ~= nil, true,
     "every remaining dirty area still exists")
end

cecho = realcecho
print(string.format("test_mapwipe: %d check(s), %d failure(s)", checks, fail))
os.exit(fail == 0 and 0 or 1)
