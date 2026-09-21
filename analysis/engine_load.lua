-- Load the REAL engine (core.lua + layout.lua) into a bare luajit, behind minimal Mudlet stubs, so a
-- harness can call shipped module functions -- `elro.faces`, `elro.pick_outer_face`, ... -- instead
-- of re-implementing them.
--
-- ⭐ WHY THIS EXISTS: `test_facefit.lua` hand-rolled a rotation-system face tracer and a 2-core peel
-- that `elro.faces` and `elro.classify_spine` already ship, and rediscovered the asymmetric-exit
-- bail by CRASHING on rand -- a bail `elro.faces` has carried all along. Re-implementation drifts;
-- the extract-and-go-stale tax is exactly what the roadmap's detector-extraction item is about.
--
-- ⚠ These stubs are enough to LOAD the engine and call pure graph helpers. They are NOT enough to
-- run a layout -- use `test_dump_layout.lua` (which carries a full fake Mudlet) for that.
local M, TIMERS, TID = nil, {}, 0
local function reset_map() M = { rooms = {}, areas = {}, nextArea = 1 } end
reset_map()
-- ⭐ EXPORTED so a harness with SEVERAL independent fixtures can start each one from an
-- empty map instead of hand-picking disjoint room ids forever (test_vertpack.lua builds
-- eleven). Pair it with elro.cs_reset() -- the c-space snapshot caches per room, and a
-- fresh map with a recycled id would otherwise be read out of the old one's cache.
_G.reset_map = reset_map

function roomExists(id) return M.rooms[id] ~= nil end
function getRooms() local t = {} for id in pairs(M.rooms) do t[id] = "room " .. id end return t end
function getRoomExits(id) local r = M.rooms[id] ; return r and r.exits or {} end
function getRoomUserData(id, k) local r = M.rooms[id] ; return r and r.ud[k] or "" end
function setRoomUserData(id, k, v) local r = M.rooms[id] ; if r then r.ud[k] = v end end
function getRoomArea(id) local r = M.rooms[id] ; return r and r.area or -1 end
function setRoomArea(id, a) local r = M.rooms[id] ; if r then r.area = a end end
function getAreaRooms(a) local t = {} for id, r in pairs(M.rooms) do if r.area == a then t[#t+1] = id end end table.sort(t) return t end
function getAreaTable() local t = {} for n, a in pairs(M.areas) do t[n] = a end return t end
function getAreaTableSwap() local t = {} for n, a in pairs(M.areas) do t[a] = n end return t end
function addAreaName(n) M.areas[n] = M.nextArea ; M.nextArea = M.nextArea + 1 ; return M.areas[n] end
function deleteArea(a) for n, id in pairs(M.areas) do if id == a then M.areas[n] = nil end end end
function addRoom(id) M.rooms[id] = { area = 1, exits = {}, ud = {}, x = 0, y = 0 } end
function deleteRoom(id) M.rooms[id] = nil end
function deleteMap() reset_map() end            -- rooms AND areas, as Mudlet's does
function setRoomName(id, n) local r = M.rooms[id] ; if r then r.name = n end end
function getRoomName(id) local r = M.rooms[id] ; return (r and r.name) or ("room " .. id) end
function setExit(a, b, d) local r = M.rooms[a] ; if r then if b == -1 then r.exits[d] = nil else r.exits[d] = b end end end
function setExitStub() end
function addSpecialExit() end
function getSpecialExits() return {} end
function getRoomCoordinates(id) local r = M.rooms[id] ; if not r then return 0, 0, 0 end return r.x, r.y, 0 end
function setRoomCoordinates(id, x, y) local r = M.rooms[id] ; if r then r.x, r.y = x, y end end
function getCustomLines() return {} end
function removeCustomLine() end
function addCustomLine() end
function highlightRoom(id, ...) local r = M.rooms[id] ; if r then r.hi = { ... } end end
function unHighlightRoom(id) local r = M.rooms[id] ; if r then r.hi = nil end end
function setRoomEnv(id, e) local r = M.rooms[id] ; if r then r.env = e end end
function getRoomEnv(id) local r = M.rooms[id] ; return r and r.env or nil end
function setCustomEnvColor() end
function setRoomChar(id, c) local r = M.rooms[id] ; if r then r.ch = c end end
function getRoomChar(id) local r = M.rooms[id] ; return r and r.ch or "" end
function setRoomCharColor(id, r_, g, b) local r = M.rooms[id] ; if r then r.chcol = { r_, g, b } end end
function createMapLabel() end
function deleteMapLabel() end
function getMapSelection() return {} end
function centerview() end
function updateMap() end
function cecho(s) if os.getenv("VERBOSE") then io.write((tostring(s):gsub("<[^>]->", ""))) end end
decho = cecho
function getMapUserData() return "" end
function setMapUserData() end
function saveMap() end
function getEpoch() return os.clock() end
function tempTimer(_, fn) TID = TID + 1 ; TIMERS[TID] = fn ; return TID end
function killTimer(id) TIMERS[id] = nil end

for _, m in ipairs(dofile("lua/modules.lua")) do dofile("lua/" .. m) end

