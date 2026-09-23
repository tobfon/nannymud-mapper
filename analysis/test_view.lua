-- mapview: the picture is written for the label's size, the mark follows the player, a click
-- lands on the room under it, the wheel zooms. Geyser is faked to a box that remembers its
-- size and stylesheet.
-- Run: luajit analysis/test_view.lua      (from the client dir)
dofile("analysis/engine_load.lua")

local fail, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("FAIL %-56s got %s want %s", what, tostring(got), tostring(want)))
  end
end

-- enough Geyser for view.lua: a container and a label of a fixed size
local Fake = {}
Fake.__index = Fake
function Fake:new(c) return setmetatable({ name = c.name, w = 400, h = 300, hidden = true, title = "" }, Fake) end
function Fake:get_width() return self.w end
function Fake:get_height() return self.h end
function Fake:show() self.hidden = false end
function Fake:hide() self.hidden = true end
function Fake:save() end
function Fake:setTitle(t) self.title = t end
function Fake:setStyleSheet(css) self.css = css end
function Fake:setClickCallback(f) self.click = f end
function Fake:setWheelCallback(f) self.wheel = f end
function Fake:detach() end
function Fake:unlockContainer() end
function Fake:resize(w, h) self.w, self.h = w, h end
Adjustable = { Container = Fake }
Geyser = Geyser or {} ; Geyser.Label = Fake
getMainWindowSize = function() return 1200, 800 end
-- no lfs here: the export folder is made by hand
local HOME = (os.getenv("TEMP") or ".") .. "/elro_test_view"
os.execute('mkdir "' .. HOME:gsub("/", "\\") .. '\\elro_export" 2>nul')
getMudletHomeDir = function() return HOME end
getRoomChar = function() return "" end
getCustomLines = function() return {} end

reset_map()
local aid = addAreaName("gurk")
local function room(id, x, y)
  addRoom(id) ; setRoomArea(id, aid) ; setRoomCoordinates(id, x, y, 0) ; setRoomName(id, "room " .. id)
end
room(1, 0, 0) ; room(2, 1, 0) ; room(3, 1, 1) ; room(4, 0, 1)
setExit(1, 2, "east") ; setExit(2, 1, "west") ; setExit(2, 3, "north") ; setExit(3, 2, "south")
elro.cs_reset()
elro.current = 1

local said = {}
local realTr = elro.tr ; elro.tr = function(m) print("TR", m) end
cecho = function(s) said[#said + 1] = s end
elro.mapview() ; run_timers()
eq(elro.viewBox ~= nil and not elro.viewBox.hidden, true, "mapview opens the window")
local css = elro.viewLabel.css or ""
local path = css:match('url%("(.-)"%)')
eq(path ~= nil, true, "the label is given a file")
local function read(p) local f = io.open(p) ; local s = f and f:read("*a") ; if f then f:close() end ; return s end
local svg = read(path) or ""
eq(svg:find('width="800" height="600"', 1, true) ~= nil, true, "drawn at twice the label")
eq(select(2, svg:gsub("<rect ", "")), 5, "four rooms and the background")
eq(select(2, svg:gsub("<circle", "")), 1, "one mark")
eq(elro.viewBox.title, "room 1 / 1", "the title is the room")

-- a move rewrites the mark only, the previous file is kept for one more round
elro.current = 3
elro.mapview_refresh() ; run_timers()
local path2 = elro.viewLabel.css:match('url%("(.-)"%)')
eq(path2 ~= path, true, "a fresh file name every draw")
eq(read(path) ~= nil, true, "...the one before stays until the next")
eq(elro.viewBox.title, "room 3 / 3", "the title follows")
elro.current = 1
elro.mapview_refresh() ; run_timers()
eq(read(path), nil, "...and is then removed")

-- click-to-walk: the whole map fitted, the label 400x300, the map 2x2 cells of 10 units
-- (viewBox 20x20 units, so 300 px tall: 15 px a unit, letterboxed 50 px each side)
elro.viewPx = 0
elro.mapview_refresh() ; run_timers()
local walked
elro.gotoRoom = function(id) walked = id end
elro.viewLabel.click({ x = 50 + 15 * 15, y = 5 * 15 })          -- cell (1, top row) = room 3
eq(walked, 3, "a click on the top right room walks there")
walked = nil
elro.viewLabel.click({ x = 50 + 5 * 15, y = 15 * 15 })          -- cell (0, bottom row) = room 1
eq(walked, 1, "...and the bottom left one")
walked = nil
elro.viewLabel.click({ x = 10, y = 10 })                        -- in the letterbox
eq(walked, nil, "a click beside the map does nothing")

-- the wheel zooms in and out within bounds
elro.viewLabel.wheel({ angleDeltaY = 120 }) ; run_timers()
eq(elro.viewPx, 16, "a wheel step from 'fit' zooms in from half the default")
for _ = 1, 30 do elro.viewLabel.wheel({ angleDeltaY = -120 }) end
eq(elro.viewPx, 4, "zooming out stops at 4 px a cell")

-- off the map: the picture stays, the mark goes
elro.offmap = 5
elro.mapview_refresh() ; run_timers()
eq(select(2, (read(elro.viewLabel.css:match('url%("(.-)"%)')) or ""):gsub("<circle", "")), 0,
   "off the map there is no mark")
elro.offmap = nil

-- fit vs zoom: zoomed, the viewBox is the label in cells around the player
elro.viewPx = 20
elro.mapview_refresh() ; run_timers()
svg = read(elro.viewLabel.css:match('url%("(.-)"%)')) or ""
eq(svg:match('viewBox="(%S+) (%S+) (%S+) (%S+)"') ~= nil, true, "a viewBox is written")
local vx, vy, vw, vh = svg:match('viewBox="(%S+) (%S+) (%S+) (%S+)"')
eq(tonumber(vw), 200, "20 px a cell over 400 px: 20 cells = 200 units wide")
eq(tonumber(vx), 5 - 100, "...centred on room 1 at (5, 15)")
eq(tonumber(vy), 15 - 75, "...centred on room 1 at (5, 15)")

elro.mapview() ; run_timers()
eq(elro.viewBox.hidden, true, "mapview again closes it")

print(string.format("test_view: %d check(s), %d failure(s)", checks, fail))
os.exit(fail > 0 and 1 or 0)
