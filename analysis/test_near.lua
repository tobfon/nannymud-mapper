-- mapnear: the BFS sweep (elro.near_scan) and the name match (elro.near_match).
--
-- Runs the SHIPPED functions behind engine_load's Mudlet stubs. The WALK is not
-- covered: getPath is Mudlet's own router and the harness has no stub for it.
--   cd .../map_helper/client && luajit analysis/test_near.lua
dofile("analysis/engine_load.lua")

local fails, checks = 0, 0
local function ok(cond, what)
  checks = checks + 1
  if not cond then fails = fails + 1 ; print("  FAIL  " .. what) end
end

-- A corridor 1-2-3-4-5 with a branch 2-6, so "nearest" has something to choose
-- between and one room sits behind a longer way round.
--   1(you) - 2 - 3 - 4 - 5(healing)
--            |
--            6(shop, port)
reset_map() ; elro.cs_reset()
for id = 1, 6 do addRoom(id) end
local function link(a, b, d, r)
  setExit(a, b, d) ; setExit(b, a, r)
end
link(1, 2, "east", "west")
link(2, 3, "east", "west")
link(3, 4, "east", "west")
link(4, 5, "east", "west")
link(2, 6, "south", "north")
setRoomUserData(1, "terr", "road,outdoors")
setRoomUserData(2, "terr", "urban")
setRoomUserData(3, "terr", "urban,indoors")
setRoomUserData(4, "terr", "forest")
setRoomUserData(5, "terr", "heal,indoors")
setRoomUserData(6, "terr", "shop,port,waterside")

print("near_scan")
local hit, swept = elro.near_scan(1)
ok(swept == 6, "reports how many rooms the sweep reached (got " .. tostring(swept) .. ")")
local function nearest(name) return hit[name] and hit[name][1] end
ok(nearest("heal") and nearest("heal").id == 5, "finds the healing room")
ok(nearest("heal").dist == 4, "distance is hops (got " ..
   tostring(nearest("heal") and nearest("heal").dist) .. ")")
ok(nearest("shop").id == 6 and nearest("shop").dist == 2,
   "finds the shop down the branch, 2 hops")
ok(nearest("port").id == 6, "a room carrying two marks answers for both")
ok(nearest("road").dist == 0, "the room you are standing in counts, at distance 0")
ok(nearest("urban").id == 2, "the NEARER of two urban rooms wins, not the first seen")
ok(hit["swamp"] == nil, "a terrain nothing reported is absent, not an empty list")

-- Every hit list is in BFS order, which is what lets near_walk retry down it.
for name, l in pairs(hit) do
  for i = 2, #l do
    ok(l[i].dist >= l[i - 1].dist, name .. " candidates are nearest-first")
  end
  ok(#l <= elro.nearKeep, name .. " keeps at most nearKeep candidates")
end

-- ⚠ REACHABILITY IS DIRECTED: an exit you cannot walk back through must not make
-- the room behind it look near. Room 7 is only reachable FROM 5, never TO it.
addRoom(7) ; setRoomUserData(7, "terr", "heal") ; setExit(7, 1, "west")
elro.cs_reset()
hit = elro.near_scan(1)
ok(#hit["heal"] == 1 and nearest("heal").id == 5,
   "a room that only points AT you is not reachable from you")

print("special exits")
-- ⛔ THE BUG THAT MADE `mapnear shop` PRINT NOTHING AT ALL. getSpecialExits has
-- three shapes across Mudlet builds; the sweep assumed {cmd -> id}, so on a build
-- returning {id -> cmd} it handed a command STRING to roomExists and threw --
-- invisibly, because an alias that dies prints to Mudlet's error console. Every
-- shape is exercised here, and roomExists is made hostile to a non-number the way
-- the real one is.
local realRE = roomExists
_G.roomExists = function(rid)
  if type(rid) ~= "number" then error("roomExists: bad argument (number expected)") end
  return realRE(rid)
end
addRoom(9) ; setRoomUserData(9, "terr", "heal")   -- only reachable via 3's special exit
local SHAPES = {
  { name = "{cmd -> id}",          t = { ["enter portal"] = 9 } },
  { name = "{id -> cmd}",          t = { [9] = "enter portal" } },
  { name = "{id(string) -> cmd}",  t = { ["9"] = "enter portal" } },
  { name = "{id -> {cmd -> ...}}", t = { [9] = { ["enter portal"] = 1 } } },
}
for _, sh in ipairs(SHAPES) do
  _G.getSpecialExits = function(rid) if rid == 3 then return sh.t end return {} end
  elro.cs_reset()
  local got, h = pcall(elro.near_scan, 1)
  ok(got, "the sweep survives " .. sh.name .. (got and "" or (": " .. tostring(h))))
  ok(got and h["heal"] ~= nil, sh.name .. " -- and routes through the special exit")
end
_G.getSpecialExits = function() return {} end
_G.roomExists = realRE
deleteRoom(9) ; elro.cs_reset()

print("near_match")
local function m(pat) return table.concat(elro.near_match(pat), ",") end
ok(m("heal") == "heal", "an exact name resolves to itself")
ok(m("port") == "port", "an exact name wins outright even though 'port' is inside 'transport'")
ok(m("unhol") == "unholy", "a unique substring resolves")
ok(m("ansport") == "transport", "a substring need not be a prefix")
ok(m("zzz") == "", "no match is an empty list, not a nil")
local several = elro.near_match("a")
ok(#several > 1, "an ambiguous pattern returns them all (" .. #several .. ")")
local sorted = true
for i = 2, #several do if several[i] < several[i - 1] then sorted = false end end
ok(sorted, "the ambiguity list is sorted, so it reads the same every time")

print("the walk")
-- ⭐ THE END-TO-END PATH, which is what a user actually reports as broken: name ->
-- match -> sweep -> getPath -> walk_steps -> send. Mudlet's router is stubbed here
-- (the harness has no getPath), so what this pins is everything AROUND it.
local sent, target = {}, nil
_G.send = function(c) sent[#sent + 1] = c end
_G.getPath = function(a, b)   -- one step per hop is enough; the TARGET is the claim
  target = b
  _G.speedWalkDir, _G.speedWalkPath = { "east" }, { b }
  return a ~= b
end
elro.current = 1
sent = {} ; target = nil ; elro.map_near("shop")
ok(target == 6 and #sent == 1, "a unique match walks, to the room the sweep chose (room " ..
   tostring(target) .. ", " .. #sent .. " command(s))")
sent = {} ; target = nil ; elro.map_near("heal")
ok(target == 5 and #sent == 1, "an exact name walks to its own nearest, not the last one asked for")
sent = {} ; elro.map_near("wat")
ok(#sent == 0, "an ambiguous pattern lists instead of walking")
sent = {} ; elro.map_near("")
ok(#sent == 0, "the bare form is a catalogue, never a walk")
sent = {} ; elro.map_near("swamp")
ok(#sent == 0, "a terrain nothing reported does not walk")
_G.getPath = function() return false end
sent = {} ; elro.map_near("shop")
ok(#sent == 0, "a target the router refuses is reported, not walked to blindly")

print("near_catalog")
-- The bare `mapnear` listing: every searchable name exactly once, in the palette's
-- ladder. It is the only place a user learns the names, so a terrain missing from
-- it is unsearchable in practice.
local cat, seen, total = elro.near_catalog(), {}, 0
for _, g in ipairs(cat) do
  for _, name in ipairs(g.names) do
    ok(not seen[name], name .. " is listed once")
    ok(elro.terrain[name] ~= nil, name .. " is a real terrain")
    seen[name] = true ; total = total + 1
  end
end
local n = 0 ; for _ in pairs(elro.terrain) do n = n + 1 end
ok(total == n, "the catalogue lists every terrain (" .. total .. " of " .. n .. ")")
ok(cat[1].group == "aid" and cat[1].names[1] == "heal",
   "groups come in rank order, best first")
ok(cat[#cat].group == "fallback", "the fallbacks come last")

print("")
if fails == 0 then print("PASS  " .. checks .. "/" .. checks .. " checks passed")
else print("FAIL  " .. fails .. "/" .. checks .. " checks failed") ; os.exit(1) end
