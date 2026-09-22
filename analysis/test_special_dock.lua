-- special_assemble: two groups joined by a recorded typed exit are docked beside each other
-- when the smaller fits, and left alone when it does not.
-- Run: luajit analysis/test_special_dock.lua      (from the client dir)
dofile("analysis/engine_load.lua")

local fail, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("FAIL %-58s got %s want %s", what, tostring(got), tostring(want)))
  end
end

-- a 3x3 block of rooms 1..9 (the big group) and a 2-room hut 20,21 (the small one)
local adj = {}
local function link(a, b) adj[a] = adj[a] or {} ; adj[b] = adj[b] or {} ; adj[a].east = b ; adj[b].west = a end
local big = { coord = {} }
for i = 0, 2 do for j = 0, 2 do
  local id = i * 3 + j + 1
  big.coord[id] = { j, i } ; adj[id] = adj[id] or {}
  if j > 0 then link(id - 1, id) end
end end
local small = { coord = { [20] = { 0, 0 }, [21] = { 1, 0 } } }
link(20, 21)
elro.smap = { ["3:20"] = "enter hut", ["20:3"] = "out" }   -- room 3 is a corner: a run out of the centre (5) has no clear line
elro.smap_index_dirty()
elro.tr = function() end

local out = elro.special_assemble({ big, small }, adj)
eq(#out, 1, "the hut is docked: two groups become one")
eq(out[1].coord[20] ~= nil and out[1].coord[3] ~= nil, true, "...holding both ends of the exit")
local a, h = out[1].coord[3], out[1].coord[20]
local d = math.max(math.abs(a[1] - h[1]), math.abs(a[2] - h[2]))
eq(d >= 3 and d <= 6, true, "the hut door sits within the offset ring of room 3")
eq(math.abs(a[1] - h[1]) ~= math.abs(a[2] - h[2]), true, "...and not on a 45 (no direction claimed)")
eq(a[1] ~= h[1] and a[2] ~= h[2], true, "...nor on a compass line")
-- nothing overlaps
local cells, clash = {}, false
for _, p in pairs(out[1].coord) do
  local k = p[1] .. ":" .. p[2]
  if cells[k] then clash = true end ; cells[k] = true
end
eq(clash, false, "no two rooms share a cell after the dock")
eq(elro._specialDock.docked, 1, "the stats say one dock")

-- a pair whose rooms already share a group is not a candidate
local one = { coord = { [1] = { 0, 0 }, [2] = { 5, 5 } } }
elro.smap = { ["1:2"] = "enter" }
elro.smap_index_dirty()
local out2 = elro.special_assemble({ one, { coord = { [3] = { 0, 0 } } } }, adj)
eq(#out2, 2, "a same-group pair docks nothing")

-- decline: the anchor is boxed in by a solid 13x13 block, no ring offset is free
local wall = { coord = {} }
local id = 100
for i = -6, 6 do for j = -6, 6 do wall.coord[id] = { j, i } ; adj[id] = adj[id] or {} ; id = id + 1 end end
local centre
for r, p in pairs(wall.coord) do if p[1] == 0 and p[2] == 0 then centre = r end end
local hut = { coord = { [300] = { 0, 0 } } }
adj[300] = {}
elro.smap = { [centre .. ":300"] = "enter" }
elro.smap_index_dirty()
local out3 = elro.special_assemble({ wall, hut }, adj)
eq(#out3, 2, "with no free offset the pair is declined and both groups stay")
eq(elro._specialDock.declined, 1, "...and the stats say so")

-- the run must be clear: a column of rooms east of the anchor at x=2 blocks every slot beyond
-- it on that side, however well the slot itself fits; the hut goes west, where the run is open.
local col = { coord = { [500] = { 0, 0 } } }
adj[500] = {}
for i = 1, 9 do
  local id = 500 + i
  col.coord[id] = { 2, i - 5 } ; adj[id] = adj[id] or {}
  if i > 1 then adj[id].south = id - 1 ; adj[id - 1].north = id end
end
local hut2 = { coord = { [600] = { 0, 0 } } }
adj[600] = {}
elro.smap = { ["500:600"] = "enter" }
elro.smap_index_dirty()
local out4 = elro.special_assemble({ col, hut2 }, adj)
eq(#out4, 1, "the hut docks")
eq(out4[1].coord[600][1] < 0, true, "...on the open west side, not through the wall")

-- the knob
elro.specialDock = false
eq(#elro.special_assemble({ big, small }, adj), 2, "specialDock = false leaves the groups alone")
elro.specialDock = nil

print(string.format("test_special_dock: %d check(s), %d failure(s)", checks, fail))
os.exit(fail == 0 and 0 or 1)
