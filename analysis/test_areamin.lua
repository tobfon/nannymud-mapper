-- onRoom must agree with recompute_areas about AREA MEMBERSHIP.
--
-- recompute_areas is the authority: it is the only pass that can measure a
-- cluster, because area_min asks a question about the whole map ("is the largest
-- connected run of this server area at least N rooms?") while onRoom knows about
-- exactly two. When the two disagreed, walking into a small area yanked the room
-- out of `world` into a tab of its own -- it left the canvas it was drawn on and
-- the edge you arrived by turned cross-area, so Mudlet's default stub replaced
-- the blue one until the next relayout put it all back.
--   cd .../map_helper/client && luajit analysis/test_areamin.lua
dofile("analysis/engine_load.lua")

local fails, checks = 0, 0
local function ok(cond, what)
  checks = checks + 1
  if not cond then fails = fails + 1 ; print("  FAIL  " .. what) end
end
local function areaOf(id) return elro.areaName(getRoomArea(id)) end

-- Build a map from a spec and settle it through recompute_areas.
--   rooms: { {id, sarea, ud} , ... }   edges: { {a, b, dir}, ... }
local function build(rooms, edges)
  elro.cs_reset()
  for id in pairs(getRooms() or {}) do deleteRoom(id) end
  for n, a in pairs(getAreaTable() or {}) do deleteArea(a) end
  local world = addAreaName("world")
  for _, r in ipairs(rooms) do
    addRoom(r[1]) ; setRoomUserData(r[1], "sarea", r[2]) ; setRoomArea(r[1], world)
    for k, v in pairs(r[3] or {}) do setRoomUserData(r[1], k, v) end
  end
  for _, e in ipairs(edges) do
    setExit(e[1], e[2], e[3]) ; setExit(e[2], e[1], elro.reverse[e[3]])
  end
  elro.cs_reset()
  elro.recompute_areas()
end

elro.areamin_loaded = true
elro.merge = {}

-- ---- the reported bug ------------------------------------------------------
-- "tiny" has 2 rooms, area_min is 3 -> recompute folds it into world.
print("area_min: a folded area stays folded when you walk into it")
elro.area_min = 3
build({ {1, "world"}, {2, "tiny"}, {3, "tiny"} },
      { {1, 2, "east"}, {2, 3, "east"} })
ok(areaOf(2) == "world", "recompute_areas folds a below-min area into world")
elro.onRoom(2, 1, "east", "A Small Place", "tiny", "west,east", "outdoors")
ok(areaOf(2) == "world",
   "...and onRoom leaves it there (was: yanked into its own tab, room vanished)")
ok(areaOf(3) == "world", "its neighbour is untouched")

-- ---- the case that must NOT change -----------------------------------------
print("area_min: an area at or above the threshold keeps its own tab")
elro.area_min = 3
build({ {1, "world"}, {10, "big"}, {11, "big"}, {12, "big"}, {13, "big"} },
      { {1, 10, "north"}, {10, 11, "east"}, {11, 12, "east"}, {12, 13, "east"} })
ok(areaOf(10) == "big", "recompute_areas keeps an at-or-above-min area")
elro.onRoom(10, 1, "north", "Big Place", "big", "south,east", "outdoors")
ok(areaOf(10) == "big", "...and onRoom keeps it there")

-- default area_min is 2, so a 2-room area IS kept
elro.area_min = 2
build({ {1, "world"}, {2, "pair"}, {3, "pair"} },
      { {1, 2, "east"}, {2, 3, "east"} })
ok(areaOf(2) == "pair", "at the default min of 2, a 2-room area keeps its tab")
elro.onRoom(2, 1, "east", "One Of Two", "pair", "west,east", "outdoors")
ok(areaOf(2) == "pair", "...and onRoom agrees")

-- ---- the forced-keep exemptions --------------------------------------------
-- adopt / fold / a merge redirect are DELIBERATE per-room decisions and
-- recompute_areas forces them to keep a tab, so area_min must have no say.
print("area_min never overrides a deliberate placement")
elro.area_min = 9
build({ {1, "world"}, {2, "tiny", { fold = "maze-2" }} }, { {1, 2, "east"} })
ok(areaOf(2) == "maze-2", "a fold keeps its own tab however small")
elro.onRoom(2, 1, "east", "Maze Bit", "tiny", "west", "indoors")
ok(areaOf(2) == "maze-2", "...and onRoom does not fold it into world")

build({ {1, "world"}, {2, "tiny", { adopt = "host" }} }, { {1, 2, "east"} })
ok(areaOf(2) == "host", "an adopted (stolen) room keeps its host area")
elro.onRoom(2, 1, "east", "Stolen", "tiny", "west", "indoors")
ok(areaOf(2) == "host", "...and onRoom does not fold it into world")

elro.merge = { tiny = "host" }
build({ {1, "world"}, {2, "tiny"}, {20, "host"} }, { {1, 2, "east"} })
ok(areaOf(2) == "host", "a merge redirect keeps the target tab")
elro.onRoom(2, 1, "east", "Merged", "tiny", "west", "indoors")
ok(areaOf(2) == "host", "...and onRoom does not fold it into world")
elro.merge = {}

-- ---- promotion -------------------------------------------------------------
-- A growing area is promoted by recompute_areas, not by onRoom -- one transition
-- at flush time instead of a flip on every step.
print("growth promotes at the next flush, not per step")
elro.area_min = 3
build({ {1, "world"}, {2, "grow"}, {3, "grow"} }, { {1, 2, "east"}, {2, 3, "east"} })
ok(areaOf(2) == "world", "two rooms: below min, in world")
addRoom(4) ; setRoomUserData(4, "sarea", "grow") ; setRoomArea(4, getAreaTable()["world"])
setExit(3, 4, "east") ; setExit(4, 3, "west")
elro.cs_reset()
elro.onRoom(4, 3, "east", "Third", "grow", "west", "outdoors")
ok(areaOf(4) == "world", "the third room lands in world -- onRoom does not promote")
elro.recompute_areas()
ok(areaOf(2) == "grow" and areaOf(4) == "grow",
   "...and recompute_areas promotes the whole cluster in one move")

-- ---- the dirty target ------------------------------------------------------
-- A room folded into world must schedule a relayout of WORLD, not of the empty
-- tab named after its server area, or the canvas that gained a room is never
-- re-laid-out and the room sits at its unit-step guess.
print("the relayout is scheduled for the canvas the room is actually on")
elro.area_min = 9
build({ {1, "world"} }, {})
elro.dirty = {}
elro.onRoom(2, 1, "east", "Fresh", "brandnew", "west", "outdoors")
local world = getAreaTable()["world"]
ok(elro.dirty[world], "world is marked dirty (the room landed there)")
local raw = getAreaTable()["brandnew"]
ok(not (raw and elro.dirty[raw]), "the empty server-area tab is not")

print(string.format("\n%s  %d/%d checks passed",
      fails == 0 and "PASS" or "FAIL", checks - fails, checks))
os.exit(fails == 0 and 0 or 1)
