-- mapexport: what the SVG is built FROM (rooms, edges listed once, one-way, stubs off the map,
-- up/down) and that the page comes out as a well-formed A4.
-- Run: luajit analysis/test_export.lua      (from the client dir)
dofile("analysis/engine_load.lua")

local fail, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("FAIL %-56s got %s want %s", what, tostring(got), tostring(want)))
  end
end

reset_map()
local aid, other = addAreaName("gurk"), addAreaName("elsewhere")
local function room(id, x, y, a, terr, name)
  addRoom(id) ; setRoomArea(id, a or aid) ; setRoomCoordinates(id, x, y, 0)
  setRoomName(id, name or ("room " .. id))
  if terr then setRoomUserData(id, "terr", terr) end
end
room(1, 0, 0, nil, "forest,outdoors", "A <clearing> & a stream")
room(2, 1, 0, nil, "heal,urban,indoors", "a lounge [38;40;0m")
room(3, 1, 1, nil, "road,forest,outdoors")
room(4, 0, 1)
room(9, 5, 5, other)
setExit(1, 2, "east") ; setExit(2, 1, "west")
setExit(2, 3, "north") ; setExit(3, 2, "south")
setExit(3, 4, "west")                          -- one-way: 4 has no way back
setExit(4, 9, "north")                         -- leaves the map
setExit(1, 4, "up")
-- what Mudlet hands back: the letter the mapper set, and the teal line it drew for the link.
-- One line in another colour must be left out (a demoted corridor is already a plain edge).
getRoomChar = function(id) return id == 2 and "E" or "" end
local teal = elro.classColours.vertical
getCustomLines = function(id)
  if id ~= 1 then return {} end
  return {
    up = { attributes = { color = { r = teal[1], g = teal[2], b = teal[3] } },
           points = { [0] = { x = 0.5, y = 0.5, z = 0 }, [1] = { x = 0, y = 1, z = 0 } } },
    e  = { attributes = { color = { r = 255, g = 60, b = 220 } },
           points = { [0] = { x = 1, y = 0, z = 0 } } },
  }
end
elro.cs_reset()

local rooms, edges = elro.export_collect(aid)
eq(#rooms, 4, "only this map's rooms are collected")
eq(#edges, 3, "an edge walked both ways is listed once")
local oneway = 0
for _, e in ipairs(edges) do if e.oneway then oneway = oneway + 1 end end
eq(oneway, 1, "an exit with no way back is marked one-way")
local byId = {}
for _, r in ipairs(rooms) do byId[r.id] = r end
eq(#byId[4].stubs, 1, "an exit into another map becomes a stub")
eq(byId[4].to["elsewhere"], true, "...and the list can say where it leads")
eq(byId[1].up, true, "an up exit is a mark on the room, not an edge")

local svg, err, info = elro.export_svg(aid, false)
eq(err, nil, "a placed map exports")
eq(svg:match('viewBox="0 0 (%d+ %d+)"') == "210 297" or svg:match('viewBox="0 0 (%d+ %d+)"') == "297 210",
   true, "the page is A4, one way up or the other")
eq(select(2, svg:gsub("<rect ", "")) >= 5, true, "a rect per room, the page, and the legend swatches")
eq(svg:find("A &lt;clearing&gt; &amp; a stream", 1, true) ~= nil, true, "a room name is escaped")
eq(svg:find("<clearing>", 1, true), nil, "...and never written raw")
eq(svg:find("38;40", 1, true), nil, "the remains of a colour code in an old name are left out")
eq(svg:find("> a lounge<", 1, true) ~= nil, true, "...and the name itself is kept, trimmed")
eq(info.listed, 4, "a small map numbers every room")
eq(svg:find("stroke%-dasharray") ~= nil, true, "one-way and stub lines carry a dash style")
local verts = elro.export_verticals(rooms)
eq(#verts, 1, "only the link in the vertical colour is read back")
eq(#verts[1], 3, "...from its room through every stored point, in order")
eq(select(2, svg:gsub("<polyline ", "")), 1, "the up/down link is drawn")
eq(svg:find('font%-style="italic">E<') ~= nil, true, "a typed exit's letter shows on a NUMBERED room too")

local plainSvg = elro.export_svg(aid, true)
eq(select(2, plainSvg:gsub('fill="#ffffff"', "")) >= 5, true, "'plain' leaves every room white")

eq((elro.export_svg(other + 99, false)), nil, "a map with no rooms is refused, not written")

-- 'wiki': no A4 to fit. A long corridor is past the 80 rooms that number everything on paper.
reset_map()
local big = addAreaName("corridor")
for i = 1, 120 do
  addRoom(i) ; setRoomArea(i, big) ; setRoomCoordinates(i, i, 0, 0) ; setRoomName(i, "room " .. i)
  if i > 1 then setExit(i - 1, i, "east") ; setExit(i, i - 1, "west") end
end
getRoomChar = function() return "" end
getCustomLines = function() return {} end
elro.cs_reset()
local _, _, a4 = elro.export_svg(big, false)
eq(a4.listed < 120, true, "on A4 a big map numbers only the rooms of note")
local wsvg, _, wiki = elro.export_svg(big, false, true)
eq(wiki.listed, 120, "'wiki' numbers every room")
eq(wiki.cell, 9.5, "...at a fixed cell, however many rooms across")
eq(wiki.width > 297, true, "...on an image wider than any A4")
eq(wsvg:find('mm"', 1, true), nil, "...measured in pixels, not millimetres")
-- numbers run as the page is read: the corridor's westmost room is 1, whatever its id
setRoomCoordinates(120, 0, 0, 0)
elro.cs_reset()
local rsvg = elro.export_svg(big, false, true)
eq(rsvg:find('<tspan font%-weight="bold">1</tspan> room 120') ~= nil, true,
   "rooms are numbered in reading order, not by id")

-- ...except that 1 is the door: the room with an exit to the world map, wherever it sits.
local world = addAreaName("world")
addRoom(900) ; setRoomArea(900, world) ; setRoomCoordinates(900, 0, 0, 0)
addRoom(901) ; setRoomArea(901, other or world) ; setRoomCoordinates(901, 0, 0, 0)
local elsewhere = addAreaName("elsewhere")
setRoomArea(901, elsewhere)
setExit(30, 901, "north")                      -- an earlier way off the map, but not to world
setExit(77, 900, "south")
elro.cs_reset()
local dsvg = elro.export_svg(big, false, true)
eq(dsvg:find('<tspan font%-weight="bold">1</tspan> room 77 %(to world%)') ~= nil, true,
   "number 1 is the room with the exit to world")
eq(dsvg:find('<tspan font%-weight="bold">2</tspan> room 120') ~= nil, true,
   "...and the rest keep their reading order behind it")
setExit(77, -1, "south")
elro.cs_reset()
local esvg = elro.export_svg(big, false, true)
eq(esvg:find('<tspan font%-weight="bold">1</tspan> room 30 %(to elsewhere%)') ~= nil, true,
   "with no exit to world, 1 is the first way off the map")

-- ---- the command: a screen image by default, 'a4' for the sheet, words in any order -------
local written = {}
local realOpen, realCecho = io.open, cecho
io.open = function(path, mode)
  if mode ~= "w" then return realOpen(path, mode) end
  local buf = {}
  written[#written + 1] = { path = path, buf = buf }
  return { write = function(_, s) buf[#buf + 1] = s end, close = function() end }
end
getMudletHomeDir = function() return "/home" end
cecho = function() end
elro.cmd_export("corridor")
elro.cmd_export("corridor plain a4")
elro.cmd_export("corridor a4 plain")
io.open, cecho = realOpen, realCecho
eq(#written, 3, "each call writes one file")
eq(written[1].path, "/home/elro_export/corridor.svg", "bare: the area's own name")
eq(table.concat(written[1].buf):find('mm"', 1, true), nil, "...and the screen image, in pixels")
eq(written[2].path, "/home/elro_export/corridor_a4.svg", "'a4' writes beside it, not over it")
eq(table.concat(written[2].buf):find('width="%d+mm"') ~= nil, true, "...the sheet, in millimetres")
eq(table.concat(written[2].buf) == table.concat(written[3].buf), true,
   "the option words work in either order")

print(string.format("test_export: %d check(s), %d failure(s)", checks, fail))
os.exit(fail == 0 and 0 or 1)
