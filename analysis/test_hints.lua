-- Server merge hints: `mha=` (the whole server area) and `mh=` (this room only).
--
-- ⛔ WHAT THIS PINS: a hint is DATA, never an action. The canvas is computed from
-- the stored hint plus the player's say, by ONE resolver that onRoom and
-- recompute_areas both call. If arriving in a room APPLIED the hint, re-walking
-- would undo an unmerge; if the two callers disagreed, a room would flip tabs on
-- every entry; and without the pin, area_min folds a half-explored unmerged area
-- straight back, which looks exactly like the unmerge failing.
--   cd .../map_helper/client && luajit analysis/test_hints.lua
dofile("analysis/engine_load.lua")

local fails, checks = 0, 0
local function ok(cond, what)
  checks = checks + 1
  if not cond then fails = fails + 1 ; print("  FAIL  " .. what) end
end

local MAPUD = {}
_G.setMapUserData = function(k, v) MAPUD[k] = v end
_G.getMapUserData = function(k) return MAPUD[k] or "" end
cecho = function() end
elro.flush_dirty = function() elro.recompute_areas() return 0 end
elro.flush = elro.flush_dirty

local function fresh()
  reset_map() ; elro.cs_reset() ; MAPUD = {}
  elro.hints_loaded = nil ; elro.merge = nil ; elro.dirty = {}
  elro.area_min = 5
end
local function canvas(id) return elro.areaName(getRoomArea(id)) end
local function all_on(ids, name)
  for _, id in ipairs(ids) do if canvas(id) ~= name then return false end end
  return true
end

print("an area-wide hint: walk, unmerge, walk on, relayout, merge back")
fresh()
elro.onRoom(1, 0, "none", "Square", "world", "east", "outdoors")
elro.onRoom(11, 1,  "east", "Harbour 1", "harbour", "east,west", "outdoors", "world")
elro.onRoom(12, 11, "east", "Harbour 2", "harbour", "east,west", "outdoors", "world")
elro.onRoom(13, 12, "east", "Harbour 3", "harbour", "east,west", "outdoors", "world")
elro.recompute_areas()
ok(all_on({ 11, 12, 13 }, "world"), "three hinted rooms are drawn on world")
ok(getRoomUserData(11, "sarea") == "harbour", "...while the room still knows its real area")
elro.cmd_unmerge("harbour")
ok(all_on({ 11, 12, 13 }, "harbour"), "unmerge moves all three, though three is below area_min")
elro.onRoom(14, 13, "east", "Harbour 4", "harbour", "west", "outdoors", "world")
ok(canvas(14) == "harbour", "a room explored AFTER the unmerge follows it")
elro.onRoom(11, 12, "west", "Harbour 1", "harbour", "east,west", "outdoors", "world")
ok(canvas(11) == "harbour", "re-walking a room does not merge it back")
elro.recompute_areas()
ok(all_on({ 11, 12, 13, 14 }, "harbour"), "...and neither does a relayout")
elro.cmd_hints("on harbour")
ok(all_on({ 11, 12, 13, 14 }, "world"), "following the hint again moves all four, no walking")

print("a hint added AFTER the area was explored")
fresh()
elro.onRoom(1, 0, "none", "Square", "world", "east", "outdoors")
for i = 1, 6 do
  elro.onRoom(20 + i, i == 1 and 1 or 19 + i, "east", "Mill " .. i, "mill", "east,west", "outdoors")
end
elro.recompute_areas()
ok(all_on({ 21, 22, 23, 24, 25, 26 }, "mill"), "six rooms, no hint: their own map")
elro.onRoom(23, 22, "east", "Mill 3", "mill", "east,west", "outdoors", "world")
elro.recompute_areas()
ok(all_on({ 21, 22, 23, 24, 25, 26 }, "world"), "ONE room arriving with mha= moves the whole area")
elro.onRoom(24, 23, "east", "Mill 4", "mill", "east,west", "outdoors")
elro.recompute_areas()
ok(all_on({ 21, 22, 23, 24, 25, 26 }, "mill"), "and one arriving without it takes the hint back")

print("a path-scoped hint touches only the rooms that carry it")
fresh()
elro.onRoom(1, 0, "none", "Square", "world", "north,east", "outdoors")
elro.onRoom(31, 1, "north", "The smithy", "forge", "south", "shop", nil, "world")
for i = 1, 6 do
  elro.onRoom(40 + i, i == 1 and 1 or 39 + i, "east", "Forge " .. i, "forge", "east,west", "outdoors")
end
elro.recompute_areas()
ok(canvas(31) == "world", "the shop follows its own hint into world")
ok(all_on({ 41, 42, 43, 44, 45, 46 }, "forge"), "...and the wizard's area stays where it is")
ok((MAPUD["elro.hintArea"] or "") == "", "...because nothing was recorded for the whole area")

print("the player's own merge outranks the server")
fresh()
elro.onRoom(1, 0, "none", "Square", "world", "east,south", "outdoors")
for i = 1, 6 do
  elro.onRoom(50 + i, i == 1 and 1 or 49 + i, "south", "Hill " .. i, "hills", "north,south", "outdoors")
end
elro.onRoom(61, 1, "east", "Harbour 1", "harbour", "west", "outdoors", "world")
elro.load_merge() ; elro.merge["harbour"] = "hills"
elro.recompute_areas()
ok(canvas(61) == "hills", "harbour merged into hills by the player goes to hills, not world")

print("maphints off: no hint is followed")
fresh()
elro.onRoom(1, 0, "none", "Square", "world", "east", "outdoors")
for i = 1, 6 do
  elro.onRoom(70 + i, i == 1 and 1 or 69 + i, "east", "Harbour " .. i, "harbour", "east,west", "outdoors", "world")
end
elro.recompute_areas()
ok(canvas(71) == "world", "followed by default")
elro.cmd_hints("off")
ok(all_on({ 71, 72, 73, 74, 75, 76 }, "harbour"), "off: the area has its own map again")
ok(MAPUD["elro.hintsOff"] == "1", "...and the choice is saved with the map")
elro.cmd_hints("on")
ok(all_on({ 71, 72, 73, 74, 75, 76 }, "world"), "on: followed again")

print("")
if fails == 0 then print("PASS  " .. checks .. "/" .. checks .. " checks passed")
else print("FAIL  " .. fails .. "/" .. checks .. " checks failed") ; os.exit(1) end
