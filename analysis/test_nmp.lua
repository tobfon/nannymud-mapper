-- The !NMP line parser: key=value pairs in any order, unknown keys ignored, the
-- off-map marker dispatched to onOff, everything else to onRoom.
dofile("analysis/engine_load.lua")

local fails, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fails = fails + 1
    print("FAIL " .. what .. "  got " .. tostring(got) .. " want " .. tostring(want))
  end
end

local room, off
elro.onRoom = function(...) room = { ... } end
elro.onOff = function(...) off = { ... } end

-- the everyday line
room, off = nil, nil
elro.nmp_line("id=137|from=136|dir=west|name=a mountain side|area=world|exits=east,west,south|terr=mountain,outdoors")
eq(off, nil, "a room line is not the marker")
eq(room[1], 137, "id")
eq(room[2], 136, "from")
eq(room[3], "west", "dir")
eq(room[4], "a mountain side", "name")
eq(room[5], "world", "area")
eq(room[6], "east,west,south", "exits")
eq(room[7], "mountain,outdoors", "terr")
eq(room[8], nil, "no mha")
eq(room[9], nil, "no mh")

-- the hints, and a field the client does not know
room = nil
elro.nmp_line("id=5|from=4|dir=n|name=x|area=a|exits=|terr=|mha=town|mh=shop|later=whatever")
eq(room[8], "town", "mha")
eq(room[9], "shop", "mh")
eq(room[6], "", "an empty exits field is the empty string")
eq(room[1], 5, "...and an unknown key changes nothing")

-- any order
room = nil
elro.nmp_line("name=y|exits=up|id=9|area=b|from=0|dir=none")
eq(room[1], 9, "keys in any order: id")
eq(room[4], "y", "...name")
eq(room[2], 0, "...from")

-- a trailing line ending survives no field
room = nil
elro.nmp_line("id=3|from=2|dir=east|name=z|area=c|exits=west\r\n")
eq(room[6], "west", "a trailing CR LF is not part of the last value")

-- the markers
room, off = nil, nil
elro.nmp_line("id=0|from=136|dir=west")
eq(room, nil, "the off-map marker is not a room")
eq(off[1], 136, "...it carries from")
eq(off[2], "west", "...and dir")
off = nil
elro.nmp_line("id=0|from=0")
eq(off[1], 0, "the bare marker: from 0")
eq(off[2], nil, "...no dir")

-- rubbish
room, off = nil, nil
elro.nmp_line("garbage")
eq(room, nil, "no id: nothing")
eq(off, nil, "...at all")
elro.nmp_line(nil)
eq(room, nil, "nil: nothing")

print(string.format("test_nmp: %d check(s), %d failure(s)", checks, fails))
os.exit(fails == 0 and 0 or 1)
