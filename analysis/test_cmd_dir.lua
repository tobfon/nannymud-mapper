-- cmd_dir + the layout hint: a recorded command that ends in a direction ("tread n") gives the
-- layout graph a compass edge; nothing is written to the map.
-- Run: luajit analysis/test_cmd_dir.lua      (from the client dir)
dofile("analysis/engine_load.lua")

local fail, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("FAIL %-58s got %s want %s", what, tostring(got), tostring(want)))
  end
end

eq(elro.cmd_dir("tread n"), "north", "a short direction at the end")
eq(elro.cmd_dir("swim east"), "east", "a long one")
eq(elro.cmd_dir("tread NE"), "northeast", "case does not matter")
eq(elro.cmd_dir("enter hut"), nil, "no direction: nil")
eq(elro.cmd_dir("climb up"), nil, "up is the vertical packer's, not the planar graph's")
eq(elro.cmd_dir("north tunnel"), nil, "only the LAST word counts")
eq(elro.cmd_dir("open door;;tread w"), "west", "a multi-step record is judged by its last step")

reset_map()
local aid = addAreaName("gurk")
local function room(id, x, y)
  addRoom(id) ; setRoomArea(id, aid) ; setRoomCoordinates(id, x, y, 0) ; setRoomUserData(id, "sarea", "gurk")
end
room(1, 0, 0) ; room(2, 0, 5) ; room(3, 9, 9) ; room(4, 1, 0)
setExit(1, 4, "east") ; setExit(4, 1, "west")
elro.smap = { ["1:2"] = "tread n", ["1:3"] = "enter hut", ["4:2"] = "tread e" }
elro.smap_index_dirty()
elro.cs_reset()
local rooms, adj = elro.area_adjacency(aid)
eq(adj[1].north, 2, "'tread n' is a north edge in the layout graph")
eq(adj[2].south, 1, "...with its reverse dart")
eq(adj[1].east, 4, "a real compass exit is untouched")
eq(adj[4].east, 2, "'tread e' from a room whose east is free takes the slot")
eq(adj[3].north == nil and adj[3].south == nil, true, "'enter hut' adds no edge")
eq(getRoomExits(1).north, nil, "nothing was written to the map: no north exit on room 1")

-- a real exit in that slot wins: the hint is skipped, not overwritten
setExit(1, 3, "north")
elro.cs_reset()
local _, adj2 = elro.area_adjacency(aid)
eq(adj2[1].north, 3, "a real exit in the slot is kept")

-- the knob
elro.cmdDirHint = false
elro.cs_reset()
local _, adj3 = elro.area_adjacency(aid)
eq(adj3[4].east, nil, "cmdDirHint = false adds nothing")
elro.cmdDirHint = nil

-- up/down: the vertical packer's side of the same rule
eq(elro.cmd_vert("climb up"), "up", "'climb up' is an up link")
eq(elro.cmd_vert("crawl d"), "down", "...short form too")
eq(elro.cmd_vert("tread n"), nil, "a planar direction is not a vertical")
eq(elro.cmd_dir("climb up"), nil, "...and a vertical is not planar: the two never overlap")
room(10, 20, 20) ; room(11, 30, 30)
elro.smap = { ["10:11"] = "climb up" }
elro.smap_index_dirty()
elro.cs_reset()
local rs = { 10, 11 }
local comp = { [10] = 1, [11] = 2 }
local links = elro.vert_classify(rs, comp, comp)
eq(#links, 1, "'climb up' between two components is one vertical link")
eq(links[1].dir, "up", "...in the up direction")
eq(links[1].typed, true, "...marked typed, so draw_vertical leaves it to the grey dotted line")
eq(getRoomExits(10).up, nil, "nothing was written to the map")
setExit(10, 11, "up")
elro.cs_reset()
local links2 = elro.vert_classify(rs, comp, comp)
eq(#links2, 1, "a real up exit in the slot: still one link")
eq(links2[1].typed, false, "...and it is a real one, drawn teal")

print(string.format("test_cmd_dir: %d check(s), %d failure(s)", checks, fail))
os.exit(fail == 0 and 0 or 1)
