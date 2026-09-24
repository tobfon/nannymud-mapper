-- mapview: the map you stand on, drawn by the export renderer, in a window of its own. A
-- prototype beside mapwin: the picture, a mark where you are, click a room to walk there,
-- the wheel to zoom. Reads the map; changes nothing.

elro = elro or {}

local BOX, LABEL = "elroMapView", "elroMapViewLabel"
local DEFAULT_W, DEFAULT_H = 380, 380
local CELL = 10                              -- drawing units per map cell
local DEFAULT_PX = 26                        -- screen pixels per cell; 0 fits the whole map
local BOX_FRAC = 0.72                        -- as the export: a room takes this of its cell

local function say(s) cecho("\n<green>[elro]: " .. s .. "\n<reset>") end

local function dir()
  local d = getMudletHomeDir() .. "/elro_export"
  if lfs and lfs.mkdir then pcall(lfs.mkdir, d) end
  return d
end

-- The area's drawing without header or list, kept until the layout changes: a move only
-- rewrites the mark. Also the room under each cell, for a click.
local function body(aid)
  local rooms, edges = elro.export_collect(aid)
  if #rooms == 0 then return nil end
  local minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
  local byCell = {}
  for _, r in ipairs(rooms) do
    minx, maxx = math.min(minx, r.x), math.max(maxx, r.x)
    miny, maxy = math.min(miny, r.y), math.max(maxy, r.y)
    byCell[r.x .. ":" .. r.y] = r.id
  end
  local function map(x, y) return (x - minx + 0.5) * CELL, (maxy - y + 0.5) * CELL end
  local o = {}
  local function w(fmt, ...) o[#o + 1] = string.format(fmt, ...) end
  elro.export_draw(w, rooms, edges, { map = map, cell = CELL, box = CELL * BOX_FRAC,
                                      thin = 0.3, plain = elro.viewPlain })
  return { aid = aid, tok = elro.cs_token(aid), svg = table.concat(o), map = map, byCell = byCell,
           minx = minx, maxy = maxy,
           w = (maxx - minx + 1) * CELL, h = (maxy - miny + 1) * CELL }
end

-- The window the SVG shows, in drawing units: the whole map, or a zoom around the mark.
local function view_box(b, here, lw, lh)
  local px = elro.viewPx or DEFAULT_PX
  if px <= 0 then return 0, 0, b.w, b.h end
  local vw, vh = lw * CELL / px, lh * CELL / px
  local cx, cy = b.w / 2, b.h / 2
  if here then local x, y = getRoomCoordinates(here) ; if x then cx, cy = b.map(x, y) end end
  return cx - vw / 2, cy - vh / 2, vw, vh
end

-- Write the picture and hand it to the label. A fresh file name every time: Qt caches an
-- image by its path, and the file before last is removed once the new one is surely read.
local function render(full)
  local box, label = elro.viewBox, elro.viewLabel
  if not box or not label or box.hidden or box.auto_hidden then return end
  local here = (not elro.offmap) and elro.current or nil
  local aid = here and getRoomArea(here) or (elro._viewB and elro._viewB.aid)
  if not aid then return end
  local t0 = elro.now_ms()
  local b = elro._viewB
  if full or not b or b.aid ~= aid or b.tok ~= elro.cs_token(aid) then
    b = body(aid) ; elro._viewB = b
  end
  if not b then return end
  local lw, lh = label:get_width(), label:get_height()
  if lw < 10 or lh < 10 then return end
  local vx, vy, vw, vh = view_box(b, here, lw, lh)
  elro._viewGeo = { vx = vx, vy = vy, vw = vw, vh = vh, lw = lw, lh = lh }
  local o = {}
  -- drawn at twice the label: crisp on a high-DPI screen, and a downscale stays smooth
  o[#o + 1] = string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
    .. 'viewBox="%.2f %.2f %.2f %.2f" preserveAspectRatio="xMidYMid meet">\n',
    lw * 2, lh * 2, vx, vy, vw, vh)
  o[#o + 1] = string.format('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="#ffffff"/>\n',
    vx, vy, vw, vh)
  o[#o + 1] = '<g font-family="Helvetica, Arial, sans-serif" fill="#000000">\n'
  o[#o + 1] = b.svg
  if here then
    local x, y = b.map(getRoomCoordinates(here))
    o[#o + 1] = string.format('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="none" stroke="#d81e1e" '
      .. 'stroke-width="0.9"/>\n', x, y, CELL * BOX_FRAC * 0.8)
  end
  o[#o + 1] = '</g>\n</svg>\n'
  elro._viewN = (elro._viewN or 0) + 1
  local path = dir() .. "/view_" .. elro._viewN .. ".svg"
  local f = io.open(path, "w")
  if not f then return end
  f:write(table.concat(o)) ; f:close()
  label:setStyleSheet('background-color: #ffffff; border-image: url("' .. path .. '");')
  if elro._viewN > 2 then os.remove(dir() .. "/view_" .. (elro._viewN - 2) .. ".svg") end
  if here then
    box:setTitle((elro.strip_ansi(getRoomName(here) or "")) .. " / " .. here)
  end
  elro._viewMs = elro.now_ms() - t0
end

-- Called from recenter on every move and at the end of a relayout (`always`). Deferred out of
-- the !NMP trigger: a large label repaint while the console is still painting the room's text
-- lost whole rows of it (never drawn, scrolled up as blank lines). Several calls in one
-- moment collapse into one draw.
function elro.mapview_refresh(full)
  if not elro.viewBox then return end
  elro._viewFull = elro._viewFull or full or false
  if elro._viewPending then return end
  local function draw()
    elro._viewPending = nil
    local f = elro._viewFull ; elro._viewFull = nil
    local ok, err = pcall(render, f)
    if not ok then elro.tr("mapview: " .. tostring(err)) end
  end
  if type(tempTimer) ~= "function" then return draw() end
  elro._viewPending = tempTimer(0.05, draw)
end

-- A click, in label pixels, back through the viewBox to a cell and its room.
local function clicked(ev)
  local g, b = elro._viewGeo, elro._viewB
  if not g or not b or type(ev) ~= "table" or not ev.x then return end
  local s = math.min(g.lw / g.vw, g.lh / g.vh)
  local ux = g.vx + (ev.x - (g.lw - g.vw * s) / 2) / s
  local uy = g.vy + (ev.y - (g.lh - g.vh * s) / 2) / s
  local id = b.byCell[(b.minx + math.floor(ux / CELL)) .. ":" .. (b.maxy - math.floor(uy / CELL))]
  if id then elro.gotoRoom(id) end
end

local function wheeled(ev)
  local d = type(ev) == "table" and ev.angleDeltaY or 0
  if d == 0 then return end
  local px = elro.viewPx or DEFAULT_PX
  if px <= 0 then px = DEFAULT_PX / 2 end
  px = math.max(4, math.min(80, math.floor(px * (d > 0 and 1.25 or 0.8) + 0.5)))
  elro.viewPx = px
  elro.mapview_refresh()
end

local function build()
  local y = 0
  if elro.miniBox and not (elro.miniBox.hidden or elro.miniBox.auto_hidden) then
    y = elro.miniBox:get_height()             -- under the map window, not over it
  end
  elro.viewBox = Adjustable.Container:new({
    name = BOX, titleText = "Map view", padding = 4,
    x = math.max(0, (getMainWindowSize()) - DEFAULT_W - 17), y = y,
    width = DEFAULT_W, height = DEFAULT_H, autoSave = true, autoLoad = true,
  })
  elro.viewLabel = Geyser.Label:new({
    name = LABEL, x = 0, y = 0, width = "100%", height = "100%",
  }, elro.viewBox)
  elro.viewLabel:setClickCallback(clicked)
  elro.viewLabel:setWheelCallback(wheeled)
end

function elro.mapview(arg)
  if type(Adjustable) ~= "table" or type(Geyser) ~= "table" then
    cecho("\n<red>[elro]: this Mudlet is too old for mapview (needs 4.8).\n<reset>") return
  end
  arg = arg or ""
  local fresh = not elro.viewBox
  if fresh then build() end
  local box = elro.viewBox
  local n = tonumber(arg:match("^zoom%s+(%d+)$"))
  if arg == "fit" or n then
    elro.viewPx = n or 0
    box:show() ; elro.mapview_refresh()
    say(n and (n .. " pixels to a cell.") or "the whole map fitted to the window; the wheel zooms in again.")
  elseif arg == "plain" then
    elro.viewPlain = not elro.viewPlain
    box:show() ; elro.mapview_refresh(true)
    say(elro.viewPlain and "terrain tints off." or "terrain tints on.")
  elseif arg == "reset" then
    elro.viewPx, elro.viewPlain = nil, nil
    box:detach() ; box:unlockContainer()
    if box.minimized then box:restore() end
    box:resize(DEFAULT_W, DEFAULT_H)
    box:show() ; elro.mapview_refresh(true)
    say("map view back to its first size and zoom.")
  elseif fresh or box.hidden or box.auto_hidden then
    box:show() ; elro.mapview_refresh(true)
    say("map view open (a prototype). Click a room to walk there, the wheel zooms, 'mapview fit' "
      .. "shows the whole map, 'mapview' again closes it."
      .. (elro._viewMs and string.format(" Drawn in %d ms.", elro._viewMs) or ""))
  else
    box:hide()
  end
  box:save()
end

-- A reload keeps the window (elro survives) but not this module's callbacks.
if elro.viewLabel then
  elro.viewLabel:setClickCallback(clicked)
  elro.viewLabel:setWheelCallback(wheeled)
  elro.mapview_refresh(true)
end

if type(registerAnonymousEventHandler) == "function" then
  if elro._viewDrop and type(killAnonymousEventHandler) == "function" then
    pcall(killAnonymousEventHandler, elro._viewDrop)
  end
  -- a resize just ended: the picture is drawn for the label's size
  elro._viewDrop = registerAnonymousEventHandler("AdjustableContainerRepositionFinish",
    function(_, name) if name == BOX then elro.mapview_refresh() end end)
end
