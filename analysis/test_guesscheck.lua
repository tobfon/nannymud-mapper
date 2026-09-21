-- elro.guess_inconsistent: the incremental relayout trigger for loop closures.
-- Detecting a lie and detecting a loop closure are the same check -- the closing edge is the
-- one whose geometry we did not choose.
-- ⚠ The negative cases matter most: a trigger that fires on a CLEAN closure makes every
-- step an urgent relayout. Both directions are asserted.
-- Run: luajit analysis/test_guesscheck.lua      (from the client dir)
dofile("analysis/engine_load.lua")

local fail, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("FAIL %-52s got %s want %s", what, tostring(got), tostring(want)))
  end
end

local aid
local function room(id, x, y)
  addRoom(id) ; setRoomArea(id, aid) ; setRoomCoordinates(id, x, y, 0)
  setRoomUserData(id, "sarea", "gurk")
end
local function link(a, b, d, rev)
  setExit(a, b, d) ; if rev then setExit(b, a, rev) end
end
local function fresh()
  reset_map() ; aid = addAreaName("gurk") ; elro.cs_reset()
end

-- 1. a unit square: room 4 arrives from 3 and closes to 1. Both its edges are truthful.
fresh()
room(1, 0, 0) ; room(2, 1, 0) ; room(3, 1, 1) ; room(4, 0, 1)
link(1, 2, "east", "west") ; link(2, 3, "north", "south")
link(3, 4, "west", "east") ; link(4, 1, "south", "north")
elro.cs_reset()
eq(elro.guess_inconsistent(4, aid, 3), nil, "a truthful loop closure does NOT trigger")

-- 2. same square, but the closing edge claims north while 1 is south of 4.
fresh()
room(1, 0, 0) ; room(2, 1, 0) ; room(3, 1, 1) ; room(4, 0, 1)
link(1, 2, "east", "west") ; link(2, 3, "north", "south")
link(3, 4, "west", "east")
link(4, 1, "north", "south")            -- 1 is SOUTH of 4: the closing edge lies
elro.cs_reset()
local why = elro.guess_inconsistent(4, aid, 3)
eq(why, "lie", "a closure whose direction contradicts the geometry triggers")

-- 3. 3 closes west to 1 and the edge's raster runs straight through room 2 at (2,0).
fresh()
room(1, 0, 0) ; room(2, 2, 0) ; room(3, 4, 0) ; room(9, 4, 1)
link(9, 3, "south", "north")            -- the edge we "arrived" on
link(3, 1, "west", "east")              -- the closure, straight through room 2
elro.cs_reset()
eq(elro.guess_inconsistent(3, aid, 9), "over-room", "a closure running over a room triggers")

-- 4. `skip` must exclude the placement edge, or every step would relayout.
fresh()
room(1, 0, 0) ; room(2, 1, 0)
link(1, 2, "east", "west")
elro.cs_reset()
eq(elro.guess_inconsistent(2, aid, 1), nil, "a room with only its placement edge never fires")

-- 5. coordinates are per-area, so a neighbour on another canvas cannot be compared.
fresh()
local other = addAreaName("elsewhere")
room(1, 0, 0) ; room(2, 1, 0)
link(1, 2, "east", "west")
addRoom(3) ; setRoomArea(3, other) ; setRoomCoordinates(3, 77, 77, 0)
link(2, 3, "north", "south")            -- would read as a wild lie if judged
elro.cs_reset()
eq(elro.guess_inconsistent(2, aid, 1), nil, "a neighbour on another canvas is ignored")

-- 6. the knob
fresh()
room(1, 0, 0) ; room(2, 1, 0) ; room(3, 1, 1) ; room(4, 0, 1)
link(1, 2, "east", "west") ; link(2, 3, "north", "south")
link(3, 4, "west", "east") ; link(4, 1, "north", "south")
elro.cs_reset()
eq(elro.guess_inconsistent(4, aid, 3), "lie", "sanity: it fires with the knob at default")
elro.guessCheck = false
eq(elro.guess_inconsistent(4, aid, 3), nil, "guessCheck = false disables it")
elro.guessCheck = nil
eq(elro.guess_inconsistent(4, aid, 3), "lie", "...and nil restores the default (ON)")

-- 7. the dual of case 3: the new room lands ON an existing edge between two other rooms.
fresh()
room(1, 0, 0) ; room(2, 4, 0)           -- a long edge from (0,0) to (4,0)
link(1, 2, "east", "west")
room(3, 2, 1) ; room(4, 2, 0)           -- 4 arrives from 3 going south, onto the edge 1-2
link(3, 4, "south", "north")
elro.cs_reset()
eq(elro.guess_inconsistent(4, aid, 3), "on-edge", "a room landing on someone else's edge triggers")

-- 8. ...and a room merely NEAR that edge does not.
fresh()
room(1, 0, 0) ; room(2, 4, 0)
link(1, 2, "east", "west")
room(3, 2, 2) ; room(4, 2, 1)           -- one cell clear of the edge
link(3, 4, "south", "north")
elro.cs_reset()
eq(elro.guess_inconsistent(4, aid, 3), nil, "a room beside the edge does not trigger")

-- 9. THE WALKED CLOSURE. A room placed by onRoom has only its placement edge, so live a loop
-- closes when you WALK between two rooms that are both already placed. That edge is the
-- closure, and as `skip` it was the one edge never judged. `only` judges it, from its source.
fresh()
room(1, 0, 0) ; room(2, 1, 0) ; room(3, 1, 1) ; room(4, 2, 1)   -- 4 drifted: it is not above 1
link(1, 2, "east", "west") ; link(2, 3, "north", "south") ; link(3, 4, "west", "east")
link(4, 1, "south")                     -- walked 4 -south-> 1, but 1 is not south of 4
elro.cs_reset()
eq(elro.guess_inconsistent(4, aid, nil, 1), "lie", "a walked closure that lies triggers")

-- 10. ...a truthful walked closure does not,
fresh()
room(1, 0, 0) ; room(2, 1, 0) ; room(3, 1, 1) ; room(4, 0, 1)
link(1, 2, "east", "west") ; link(2, 3, "north", "south") ; link(3, 4, "west", "east")
link(4, 1, "south")
elro.cs_reset()
eq(elro.guess_inconsistent(4, aid, nil, 1), nil, "a truthful walked closure does NOT trigger")

-- 11. ...and an old lie on ANOTHER edge of the same room is not re-reported by a clean walk:
-- an accepted lie would otherwise make every new edge at that room an urgent relayout.
fresh()
room(1, 0, 0) ; room(2, 1, 0) ; room(3, 5, 5)
link(1, 3, "north")                     -- 3 is nowhere near north of 1: a standing lie
link(1, 2, "east")                      -- the edge just walked, truthful
elro.cs_reset()
eq(elro.guess_inconsistent(1, aid, nil, 2), nil, "`only` ignores the room's other edges")

print(string.format("test_guesscheck: %d check(s), %d failure(s)", checks, fail))
os.exit(fail == 0 and 0 or 1)
