-- draw_special: a recorded typed exit between two rooms of one canvas becomes one dotted line.
-- Run: luajit analysis/test_special_draw.lua      (from the client dir)
dofile("analysis/engine_load.lua")

local fail, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("FAIL %-56s got %s want %s", what, tostring(got), tostring(want)))
  end
end

-- Mudlet's rule: the slot must be a direction, or the command of a special exit the room has.
local lines = {}
local specials = { [1] = { ["enter hut"] = true, ["climb rope"] = true }, [2] = { ["out"] = true } }
addCustomLine = function(id, to, slot, style, col, arrow)
  if not (specials[id] and specials[id][slot]) then return nil, "no such exit" end
  lines[#lines + 1] = { id = id, to = to, slot = slot, style = style, col = col }
  return true
end

reset_map()
local aid = addAreaName("gurk")
for id, c in pairs({ [1] = { 0, 0 }, [2] = { 3, 0 }, [3] = { 20, 0 }, [4] = { 5, 5 } }) do
  addRoom(id) ; setRoomArea(id, aid) ; setRoomCoordinates(id, c[1], c[2], 0)
end
elro.cs_reset()
elro.smap = { ["1:2"] = "enter hut", ["2:1"] = "out", ["1:3"] = "climb rope", ["1:9"] = "pray" }
elro.smap_index_dirty()
local coord = { [1] = true, [2] = true, [3] = true, [4] = true }

local n = elro.draw_special(coord)
eq(n, 1, "one line drawn: the pair within reach")
eq(#lines, 1, "...and only one addCustomLine")
eq(lines[1].id, 1, "drawn from the room that owns the exit (1:2 sorts before 2:1)")
eq(lines[1].slot, "enter hut", "under the recorded command, the one slot Mudlet accepts")
eq(lines[1].to, 2, "to the destination ROOM, so Mudlet ends the line on it")
eq(lines[1].style, "dot line", "dotted")
eq(lines[1].col, elro.classColours.special, "in the special colour")
eq(elro._specialStats.far, 1, "the pair 20 cells apart is counted, not drawn")
-- 1:9 names a room that does not exist: skipped without error (asserted by getting here)

-- both ends must be on THIS canvas
lines = {}
eq(elro.draw_special({ [1] = true }), 0, "a pair with one end off the canvas draws nothing")

print(string.format("test_special_draw: %d check(s), %d failure(s)", checks, fail))
os.exit(fail == 0 and 0 or 1)
