-- mapmazefit: the door survey and the single-vertex feasibility test.
--
-- Step 0 of PLAN-maze.md. What is pinned here is the VERDICT, because the verdict
-- decides whether the plan gets built.
--
-- ⛔ AND THE VERDICT IS POSITION-FREE ON PURPOSE. An earlier cut asked whether the
-- door rays met at the rooms' CURRENT coordinates. That measured nothing:
-- area_adjacency drops a boundary room's exit into a folded maze, so nothing has
-- ever tied those rooms together and where they sit records the absence of the
-- constraint. The real question is how many cells the maze must occupy, which
-- depends only on how many ways one room faces it.
--   cd .../map_helper/client && luajit analysis/test_mazefit.lua
dofile("analysis/engine_load.lua")

local fails, checks = 0, 0
local function ok(cond, what)
  checks = checks + 1
  if not cond then fails = fails + 1 ; print("  FAIL  " .. what) end
end

-- the report's own trimmed, ANSI-free read of a room name
local function clean(id)
  local nm = elro.strip_ansi(getRoomName(id) or "")
  return (nm:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- `maze` is a list of member ids, `doors` a list of {id, dir} outside it.
-- Returns the member set.
local function fixture(maze, doors, mazeName)
  reset_map() ; elro.cs_reset()
  local members = {}
  for _, m in ipairs(maze) do
    addRoom(m) ; setRoomUserData(m, "fold", "maze-" .. maze[1])
    setRoomName(m, mazeName or "a twisty passage")
    members[m] = true
  end
  for _, d in ipairs(doors) do
    if not roomExists(d[1]) then addRoom(d[1]) ; setRoomName(d[1], "Outside " .. d[1]) end
    setExit(d[1], maze[1], d[2])
  end
  return members
end

print("maze_doors")
local members = fixture({ 100, 101 }, { { 1, "north" }, { 2, "west" } })
addRoom(3) ; setExit(3, 1, "east")             -- neighbours a door room, not the maze
local doors, special = elro.maze_doors(members)
ok(#doors == 2, "finds both doors and only those (got " .. #doors .. ")")
ok(special == 0, "no non-compass doors here")
ok(doors[1].room == 1 and doors[1].dir == "north", "doors are sorted by room")
setExit(1, 101, "up")
doors, special = elro.maze_doors(members)
ok(#doors == 2 and special == 1, "an up/down door is counted apart -- it fixes no x,y")

print("maze_cells")
-- one door each: a single cell serves them all, wherever the solver puts them
members = fixture({ 100 }, { { 1, "north" }, { 2, "west" }, { 3, "southeast" } })
ok(elro.maze_cells(elro.maze_doors(members)) == 1, "one door per room -> ONE cell")

members = fixture({ 100 }, { { 1, "north" } })
ok(elro.maze_cells(elro.maze_doors(members)) == 1, "a lone door -> one cell")
ok(elro.maze_cells({}) == 1, "no doors at all is not a region requirement")

-- ⭐ THE CONSTRAINT THE PLAN TURNS ON: one room facing the maze twice needs the
-- maze to BE in two places, i.e. to occupy two cells. It is a size, not a refusal.
members = fixture({ 100 }, { { 1, "north" }, { 1, "east" } })
local cells, who, why = elro.maze_cells(elro.maze_doors(members))
ok(cells == 2, "a room with two doors -> a 2-cell region (got " .. cells .. ")")
ok(who == 1, "...and names the room that forces it")
ok(why:find("east, north", 1, true) ~= nil, "...with its directions (got " .. tostring(why) .. ")")

-- ⛔ THE SECOND BOUND, which the first cut missed entirely and leowon and lyr both
-- paid for: two rooms entering the maze from the SAME direction are both in the
-- vertex's column, so the second sits behind the first and its spoke would cross
-- rooms. That needs two maze cells just as much as one room with two doors does.
members = fixture({ 100 }, { { 1, "south" }, { 2, "south" } })
cells, who, why = elro.maze_cells(elro.maze_doors(members))
ok(cells == 2, "two rooms entering going south -> a 2-cell region (got " .. cells .. ")")
ok(why:find("enter going south", 1, true) ~= nil, "...and says so (got " .. tostring(why) .. ")")
members = fixture({ 100 }, { { 1, "south" }, { 2, "south" }, { 3, "south" }, { 4, "north" } })
cells = elro.maze_cells(elro.maze_doors(members))
ok(cells == 3, "three sharing a direction -> 3 cells, and the odd one out does not add (got " .. cells .. ")")
-- distinct directions stay at one cell, which is why andra and qqqq look right
members = fixture({ 100 }, { { 1, "north" }, { 2, "south" }, { 3, "east" }, { 4, "west" } })
ok(elro.maze_cells(elro.maze_doors(members)) == 1, "four doors, four directions -> still ONE cell")

members = fixture({ 100 }, { { 1, "north" }, { 1, "east" }, { 1, "south" }, { 2, "west" } })
cells, who = elro.maze_cells(elro.maze_doors(members))
ok(cells == 3 and who == 1, "three doors on one room -> 3 cells, mishra's shape")

-- the WORST room decides, not the last one seen
members = fixture({ 100 }, { { 5, "north" }, { 5, "east" }, { 9, "west" } })
cells, who = elro.maze_cells(elro.maze_doors(members))
ok(cells == 2 and who == 5, "the region is set by the worst room, whichever it is")

print("maze_name -- the detection signal")
-- ⭐ On the first live run, every multi-cell cluster turned out to have door rooms
-- carrying the maze's OWN name: undetected members, not real boundary. The report
-- leans on this, so the name test is pinned.
members = fixture({ 100, 101, 102 }, { { 1, "north" }, { 2, "east" } }, "swamp")
local mn, cnt = elro.maze_name(members)
ok(mn == "swamp" and cnt == 3, "the cluster's own name is the one most members share")
setRoomName(1, "swamp")
ok(elro.strip_ansi(getRoomName(1)) == mn, "a door room sharing it is the flag the report raises")
setRoomName(2, "A Forest Path")
ok(elro.strip_ansi(getRoomName(2)) ~= mn, "...and an ordinary boundary room does not")

-- ANSI in stored names must not defeat the comparison: names written before the
-- strip-on-the-way-in fix still carry it.
setRoomName(102, "swamp\27[38;40;0m")
mn = elro.maze_name(members)
ok(mn == "swamp", "ANSI in a stored name does not split the vote (got '" .. tostring(mn) .. "')")

-- ⛔ AND THE ESC-LESS RESIDUE, which is what is actually on the map: mapreg_d once
-- stripped the ESC byte alone and left the rest as literal text. A name carrying it
-- must still compare equal, or the signal silently under-reports -- it missed a real
-- "a paved road" door room on the first live run for precisely this.
ok(elro.strip_ansi("a paved road [38;40;0m") == "a paved road ",
   "an ESC-less CSI residue is stripped too (got '" .. elro.strip_ansi("a paved road [38;40;0m") .. "')")
setRoomName(101, "swamp [38;40;0m")
setRoomName(1, "swamp [38;40;0m")
ok(clean(1) == clean(101), "a dirty name and a dirty name compare equal")
setRoomName(101, "swamp")
ok(clean(1) == clean(101), "...and a dirty name compares equal to a CLEAN one -- the missed case")
-- but a bracket that is not colour has to survive, or room names get mangled
ok(elro.strip_ansi("bracket [north] kept") == "bracket [north] kept", "a non-colour bracket survives")
ok(elro.strip_ansi("Room [2 of 3]") == "Room [2 of 3]", "...including one with digits in it")

print("mapunmaze -- one room, or the whole submap")
-- ⭐ Detection takes a room too many often enough that releasing the WHOLE cluster
-- to fix one of them is the wrong tool. maze=0 is what makes a single release
-- stick: it is a hard exclude in detect_mazes, so the reconcile pass cannot pull
-- the room back in on the next `mapmaze auto`.
reset_map() ; elro.cs_reset()
local ta = addAreaName("t")
local ma = addAreaName("maze-10")
for i = 10, 13 do addRoom(i) ; setRoomArea(i, ma) ; setRoomUserData(i, "fold", "maze-10") end
elro.current = 10 ; elro.cs_reset()
local function folded()
  local n = 0
  for i = 10, 13 do if getRoomUserData(i, "fold") ~= "" then n = n + 1 end end
  return n
end
ok(folded() == 4, "four rooms folded to start")
elro.cmd_unmaze("12")
ok(folded() == 3, "one room released, the rest stay folded (" .. folded() .. ")")
ok(getRoomUserData(12, "maze") == "0", "and it is marked maze=0 so detection cannot retake it")
ok(getRoomUserData(12, "fold") == "", "...with its fold cleared, so it returns to its own area")
elro.cmd_unmaze("13,11")
ok(folded() == 1, "a list releases several at once (" .. folded() .. ")")
elro.cmd_unmaze("here")
ok(folded() == 0, "'here' releases the room you are standing in (" .. folded() .. ")")

-- ⛔ AND THE AREA LISTS MUST BE INVALIDATED. Clearing the fold moves the room to
-- another canvas, so cs_arooms is wrong for both the maze it left and the area it
-- joins; without that the target area solves against a list missing the room.
reset_map() ; elro.cs_reset()
local ha = addAreaName("home")
for i = 1, 3 do addRoom(i) ; setRoomArea(i, ha) end
setExit(2, 3, "east") ; setExit(3, 2, "west")
local hm = addAreaName("maze-40")
for i = 40, 41 do addRoom(i) ; setRoomArea(i, hm) ; setRoomUserData(i, "fold", "maze-40") end
setExit(3, 40, "east") ; setExit(40, 3, "west") ; setExit(40, 41, "east")
setRoomUserData(40, "sarea", "home") ; setRoomUserData(41, "sarea", "home")
elro.current = 1 ; elro.cs_reset()
elro.dirty = {}
elro.cmd_unmaze("40")
elro.recompute_areas()
ok(getRoomArea(40) == ha, "a released room really moves to its own area (" .. getRoomArea(40) .. ")")
ok(getRoomArea(41) == hm, "...and the rest of the cluster stays put")

-- ⚠ and only the touched canvases relayout, not every map
local nd = 0 ; for _ in pairs(elro.dirty or {}) do nd = nd + 1 end
ok(nd == 2, "exactly the two canvases are dirtied: the submap and the one it joins (" .. nd .. ")")
ok(elro.dirty[ha] and elro.dirty[hm], "...and they are the right two")

-- bare still means the whole submap
reset_map() ; elro.cs_reset()
ta = addAreaName("t") ; ma = addAreaName("maze-20")
for i = 20, 24 do addRoom(i) ; setRoomArea(i, ma) ; setRoomUserData(i, "fold", "maze-20") end
elro.current = 20 ; elro.cs_reset()
elro.cmd_unmaze("")
local left = 0
for i = 20, 24 do if getRoomUserData(i, "fold") ~= "" then left = left + 1 end end
ok(left == 0, "bare mapunmaze still releases the WHOLE submap (" .. left .. " left)")

print("")
if fails == 0 then print("PASS  " .. checks .. "/" .. checks .. " checks passed")
else print("FAIL  " .. fails .. "/" .. checks .. " checks failed") ; os.exit(1) end
