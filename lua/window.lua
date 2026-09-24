-- mapwin: the map as a small resizable window pinned over the top right of the session's text.

elro = elro or {}

local BOX, MAPPER = "elroMinimap", "elroMinimapMapper"
local DEFAULT_W, DEFAULT_H = 380, 380

local function say(s) cecho("\n<green>[elro]: " .. s .. "\n<reset>") end

-- Mudlet's generic_mapper answers mapOpenEvent with a 'look' and its quick-start help. Its
-- handler is registered by NAME, so wrapping the global mutes that one event and leaves
-- the package installed and untouched.
local function quietly(fn)
  local orig = type(map) == "table" and map.eventHandler
  if type(orig) == "function" and type(tempTimer) == "function" then
    map.eventHandler = function(event, ...)
      if event == "mapOpenEvent" then return end
      return orig(event, ...)
    end
    tempTimer(0.5, function() map.eventHandler = orig end)
  end
  fn()
end

-- calcFontSize rounds to whole pixels; measured at ten times the size it keeps one decimal.
local function char_width()
  local ok, w = pcall(function()
    return (calcFontSize(getFontSize("main") * 10, getFont("main"))) / 10
  end)
  if ok and type(w) == "number" and w > 0 then return w end
  return (calcFontSize("main"))
end

-- Right edge of THIS session's text, left of the scrollbar, in Geyser's coordinates.
-- getMainWindowSize is exact when it is this pane, but a session that began in single view
-- keeps reporting the whole window under MultiView. It is believed only when it agrees with
-- the column count, and each time it is, it calibrates the cell width the fallback uses
-- (calcFontSize reads 11.3 where the real cell is 11.46).
local SCROLLBAR = 17
local function pane_width()
  local full = (getMainWindowSize())
  local ok, cols = pcall(getColumnCount, "main")
  if not ok or type(cols) ~= "number" or cols <= 0 then return full - SCROLLBAR end
  local l = type(getBorderLeft) == "function" and getBorderLeft() or 0
  local r = type(getBorderRight) == "function" and getBorderRight() or 0
  local base = char_width()
  if elro._winCwBase ~= base then elro._winCw, elro._winCwBase = nil, base end
  local est = l + cols * base
  local text = full - SCROLLBAR - r
  if text >= est and text <= est * 1.06 then
    local cw = (text - l) / cols
    if not elro._winCw or cw < elro._winCw then elro._winCw = cw end
    return math.floor(text)
  end
  return math.floor(l + cols * (elro._winCw or base))
end

-- Where the box's left edge belongs. elro.miniLeft is read back from the saved x at build.
local function want_x(box, pw)
  if elro.miniLeft then return type(getBorderLeft) == "function" and getBorderLeft() or 0 end
  return math.max(0, pw - box:get_width())
end

-- The embedded mapper is a widget Mudlet also resizes on its own (seen after focus changes:
-- it painted black over part of the text, outside its frame). Geyser's reposition is a
-- createMapper at the frame's geometry, which with the widget already made is a resize.
local function refit()
  if elro.miniMap and not (elro.miniMap.hidden or elro.miniMap.auto_hidden) then
    pcall(function() elro.miniMap:reposition() end)
  end
end

-- Keep the size the player chose, in pixels, and pin the corner.
local function anchor()
  local box = elro.miniBox
  if not box or box.hidden or box.auto_hidden or box.minimized then return end
  local pw = pane_width()
  box:resize(math.min(box:get_width(), pw), box:get_height())
  box:move(want_x(box, pw), 0)
  refit()
end

-- A session opening beside this one raises no resize event, so once a second while the
-- window is up, check that it is still in its corner. Ends when it is closed.
local function watch()
  if elro._winWatch or type(tempTimer) ~= "function" then return end
  local function tick()
    elro._winWatch = nil
    local box = elro.miniBox
    if not box or box.hidden or box.auto_hidden then return end
    local ok, off = pcall(function() return box:get_x() - want_x(box, pane_width()) end)
    if ok and not box.minimized and math.abs(off) > 1 then anchor() else refit() end
    elro._winWatch = tempTimer(1, tick)
  end
  tick()
end

local function save_path()
  return getMudletHomeDir() .. "/AdjustableContainer/" .. BOX .. ".lua"
end

-- The container's own save file is the record: no file means never opened.
local function was_open()
  if type(io.exists) ~= "function" or not io.exists(save_path()) then return false end
  local t = {}
  if not pcall(table.load, save_path(), t) then return false end
  return not t.hidden
end

-- The side is not stored separately: a box saved at the left edge is a left box.
local function saved_left()
  if type(io.exists) ~= "function" or not io.exists(save_path()) then return false end
  local t = {}
  if not pcall(table.load, save_path(), t) then return false end
  local x = tonumber((tostring(t.x):match("^(-?[%d%.]+)")))
  local l = type(getBorderLeft) == "function" and getBorderLeft() or 0
  return x ~= nil and x <= l
end

-- createMapper can refuse by returning nil and a message, without throwing, and Geyser does
-- not look. Asked at zero size before anything is built; returns Mudlet's reason on a refusal.
local function can_embed()
  local made, why = false, nil
  quietly(function()
    local ok, res, msg = pcall(createMapper, 0, 0, 0, 0)
    made = (ok and res == true) or (type(raiseWindow) == "function" and raiseWindow("mapper") == true)
    if not made then why = tostring((ok and msg) or res or "no reason given") end
  end)
  return made, why
end

local function build()
  if not can_embed() then return false end
  elro.miniLeft = saved_left()
  quietly(function()
    elro.miniBox = Adjustable.Container:new({
      name = BOX, titleText = "Map", padding = 4,
      x = 0, y = 0, width = DEFAULT_W, height = DEFAULT_H,
      autoSave = true, autoLoad = true,
    })
    elro.miniMap = Geyser.Mapper:new({
      name = MAPPER, x = 0, y = 0, width = "100%", height = "100%",
    }, elro.miniBox)
  end)
  return true
end

-- Mudlet's own banner (name / id (area)) fills a small map, and its font cannot be set.
-- Swap it for name / id; the map's right-click menu still switches either.
local INFO = "Room name"
local function compact_banner()
  if type(enableMapInfo) ~= "function" or type(disableMapInfo) ~= "function" then return end
  pcall(disableMapInfo, "Short")
  pcall(disableMapInfo, "Full")
  pcall(enableMapInfo, INFO)
end

if type(registerMapInfo) == "function" then
  pcall(registerMapInfo, INFO, function(room)
    -- the id too: it is what mapgoto and mapavoid take
    return room and (tostring(getRoomName(room) or "") .. " / " .. tostring(room)) or "",
           false, false, 255, 255, 255
  end)
end

local function show()
  elro.miniBox:show()
  anchor()
  watch()
  -- The container is a black label under the map; nothing guarantees the map stacks above it.
  if elro.miniMap and type(raiseWindow) == "function" then pcall(raiseWindow, "mapper") end
  -- view_room, not elro.current: off the map the view belongs on the placeholder. At load
  -- no room has arrived yet, and Mudlet's own last position is the next best thing.
  local at = elro.view_room() or (type(getPlayerRoom) == "function" and getPlayerRoom()) or nil
  if at and type(centerview) == "function" then pcall(centerview, at) end
end

-- Mudlet's own map widget, what the Map button opens: docked or floating as Mudlet last had
-- it, size and place remembered by Mudlet. The default since the embedded form lost
-- console paints (rows of text never drawn while it was up; see DESIGN.md).
local function dock_open()
  quietly(function() pcall(openMapWidget) end)
  elro._dockOpen = true
  local at = elro.view_room() or (type(getPlayerRoom) == "function" and getPlayerRoom()) or nil
  if at and type(centerview) == "function" then pcall(centerview, at) end
end
local function dock_close()
  pcall(closeMapWidget)
  elro._dockOpen = false
end
-- Whether the player closed the docked map with 'mapwin': the one state Mudlet does not
-- keep for us across restarts. The file exists while it is closed by choice.
local function dock_closed_marker() return getMudletHomeDir() .. "/elro_export/.mapwin_closed" end
local function dock_remember(closed)
  local dir = getMudletHomeDir() .. "/elro_export"
  if lfs and lfs.mkdir then pcall(lfs.mkdir, dir) end
  if closed then
    local f = io.open(dock_closed_marker(), "w")
    if f then f:write(os.date()) ; f:close() end
  else
    pcall(os.remove, dock_closed_marker())
  end
end

function elro.mapwin(arg)
  if type(openMapWidget) ~= "function" or type(closeMapWidget) ~= "function" then
    cecho("\n<red>[elro]: this Mudlet is too old for mapwin (needs 4.8).\n<reset>") return
  end
  local embedded = elro.miniBox and not (elro.miniBox.hidden or elro.miniBox.auto_hidden)
  if arg == "embed" then
    dock_close()
    return elro.mapwin_embed(nil)
  elseif arg ~= nil and not embedded then
    say("'mapwin " .. arg .. "' applies to the embedded window ('mapwin embed'). The map you "
      .. "have is Mudlet's own: drag its title bar to float it, resize it by its edges, the Map "
      .. "button or 'mapwin' closes it.")
    return
  elseif arg == nil and not embedded then
    -- one map widget per profile: once it has been inside our label it stays bound there
    if elro.miniBox then
      say("the map is still bound to the embedded window from earlier in this session, and "
        .. "Mudlet cannot dock it again until it restarts. Restart Mudlet and type 'mapwin', "
        .. "or 'mapwin embed' to use the small window now.")
      return
    end
    if elro._dockOpen then dock_close() ; dock_remember(true) else
      dock_open() ; dock_remember(false)
      say("map open. Drag its title bar to float it, or dock it to a side; 'mapwin' again "
        .. "closes it. 'mapwin embed' is the small window over the text instead.")
    end
    return
  end
  return elro.mapwin_embed(arg)
end

function elro.mapwin_embed(arg)
  if type(Adjustable) ~= "table" or type(Geyser) ~= "table" or not Geyser.Mapper then
    cecho("\n<red>[elro]: this Mudlet is too old for the embedded window (needs 4.8).\n<reset>") return
  end
  local can, why = can_embed()
  if not can then
    if elro.miniBox then elro.miniBox:hide() end
    cecho("\n<red>[elro]: Mudlet would not put the map in a window (" .. why .. "). Its own Map "
      .. "button still works. To change over: close that Map, restart Mudlet, type 'mapwin'.\n<reset>")
    return
  end
  local fresh = not elro.miniBox
  local first = type(io.exists) == "function" and not io.exists(save_path())
  if fresh then build() end
  local box = elro.miniBox
  if first or arg == "reset" then compact_banner() end
  if arg == "reset" then
    elro.miniLeft = false
    box:detach()
    box:unlockContainer()
    if box.minimized then box:restore() end
    box:resize(DEFAULT_W, DEFAULT_H)
    quietly(show)
    say("map window back to its first size in the top right corner, unlocked.")
  elseif arg == "lock" then
    quietly(show)
    box:lockContainer("full")
    say("map window locked: no frame, and it cannot be resized. 'mapwin unlock' undoes it.")
  elseif arg == "unlock" then
    box:unlockContainer()
    quietly(show)
    say("map window unlocked: drag its inner or bottom edge to resize it.")
  elseif arg == "left" or arg == "right" then
    elro.miniLeft = (arg == "left")
    quietly(show)
    say("map window in the top " .. arg .. " corner.")
  elseif fresh then
    show()
    say("map window open. Drag its inner or bottom edge to resize it, 'mapwin left' moves it "
      .. "to the other corner, 'mapwin lock' removes the frame, 'mapwin' again closes it.")
  elseif box.hidden or box.auto_hidden then
    quietly(show)
  else
    box:hide()
  end
  box:save()
end

-- Open on a first install, afterwards only what the player left open. Type-guarded for the
-- offline harness.
function elro.mapwin_boot()
  if elro.miniBox or type(Adjustable) ~= "table" or type(getMudletHomeDir) ~= "function" then return end
  if type(io.exists) ~= "function" then return end
  -- a player who chose the embedded window keeps it
  if io.exists(save_path()) and was_open() then
    if not build() then return end
    show()
    return
  end
  -- otherwise Mudlet's own map, at every start unless the player closed it with 'mapwin'
  -- (Mudlet does not restore the dock's open state itself; a close by the Map button
  -- leaves no event and is reopened, one keystroke)
  if io.exists(dock_closed_marker()) or type(openMapWidget) ~= "function" then return end
  local first = not io.exists(getMudletHomeDir() .. "/elro_export/.mapwin_seen")
  if first then
    local dir = getMudletHomeDir() .. "/elro_export"
    if lfs and lfs.mkdir then pcall(lfs.mkdir, dir) end
    local f = io.open(dir .. "/.mapwin_seen", "w")
    if f then f:write(os.date()) ; f:close() end
  end
  dock_open()
  if first then
    say("this is the map. Drag its title bar to float it or dock it to a side; the Map button "
      .. "or 'mapwin' closes it, 'maphelp' has the rest.")
  end
end

-- A reload or reinstall keeps the window (elro survives) but not this module's timer chain.
if elro._winWatch and type(killTimer) == "function" then pcall(killTimer, elro._winWatch) end
elro._winWatch = nil
-- 1.2.0 could leave an empty frame behind; the zero-size probe also needs the map put back.
if elro.miniBox and type(createMapper) == "function" then
  if not can_embed() then elro.miniBox:hide()
  elseif not (elro.miniBox.hidden or elro.miniBox.auto_hidden) then show() end
end
-- An install in mid-session gets no sysLoadEvent; boot does nothing the second time.
if type(tempTimer) == "function" then tempTimer(1, function() elro.mapwin_boot() end) end

if type(registerAnonymousEventHandler) == "function" then
  for _, k in ipairs({ "_winLoad", "_winResize", "_winDrop", "_winMapOpen" }) do
    if elro[k] and type(killAnonymousEventHandler) == "function" then
      pcall(killAnonymousEventHandler, elro[k])
    end
  end
  elro._winLoad = registerAnonymousEventHandler("sysLoadEvent",
    function() elro.mapwin_boot() end)
  -- The Map button opens the same widget behind our back; there is no close event, so a
  -- 'mapwin' after a button close opens rather than closes. One extra keystroke, no harm.
  elro._winMapOpen = registerAnonymousEventHandler("mapOpenEvent", function()
    if not (elro.miniBox and not (elro.miniBox.hidden or elro.miniBox.auto_hidden)) then
      elro._dockOpen = true
    end
  end)
  elro._winResize = registerAnonymousEventHandler("sysWindowResizeEvent", anchor)
  -- A drag or resize just ended: keep the new size, snap back to the corner.
  elro._winDrop = registerAnonymousEventHandler("AdjustableContainerRepositionFinish",
    function(_, name)
      if name ~= BOX or not elro.miniBox then return end
      anchor()
      elro.miniBox:save()
    end)
end
