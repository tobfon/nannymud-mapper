-- mapexport: one area as an SVG in a paper-friendly style (white, outlined rooms, pale tints,
-- line styles instead of line colours): an image for a screen, or with 'a4' one sheet to
-- print. Reads the map; changes nothing.

elro = elro or {}

local MARGIN, HEADER = 10, 13            -- mm
local LIST_FONT, LIST_LINE, LIST_COL = 2.4, 3.1, 60
local NUMBER_ALL = 80                    -- at most this many rooms: every room is numbered
local NOTABLE = { aid = true, travel = true, sacred = true }

local function esc(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- A terrain colour let down towards white: ink-cheap, and still a grey on a mono printer.
local function tint(c, keep)
  local function ch(v) return math.floor(255 - (255 - v) * keep + 0.5) end
  return string.format("#%02x%02x%02x", ch(c[1]), ch(c[2]), ch(c[3]))
end

-- Everything the drawing needs, read once. Edges are undirected and listed once; `oneway`
-- when only one of the two rooms has the exit.
function elro.export_collect(aid)
  local rooms, byId = {}, {}
  for _, id in ipairs(elro.cs_area_rooms(aid)) do
    if id ~= elro.OFF_ROOM and roomExists(id) then
      local x, y = getRoomCoordinates(id)
      if x then
        local cell, dot = elro.terrain_roles(getRoomUserData(id, "terr"))
        -- strip_ansi: names stored before the server stopped sending colour still carry
        -- its remains ("a lounge [38;40;0m") until the room is walked again
        local nm = elro.strip_ansi(getRoomName(id) or "")
        nm = (nm:gsub("^%s+", ""):gsub("%s+$", ""))
        local r = { id = id, x = x, y = y, name = nm ~= "" and nm or ("room " .. id),
                    cell = cell, dot = dot, stubs = {}, to = {} }
        if type(getRoomChar) == "function" then
          local ok, ch = pcall(getRoomChar, id)
          if ok and type(ch) == "string" and ch ~= "" then r.glyph = ch end
        end
        rooms[#rooms + 1] = r ; byId[id] = r
      end
    end
  end
  table.sort(rooms, function(a, b) return a.id < b.id end)
  local edges, seen = {}, {}
  for _, r in ipairs(rooms) do
    local rec = elro.cs_room(r.id)
    -- elro.exits walks the eight compass keys only; up and down are read directly
    r.up   = rec and rec.ex.up ~= nil or nil
    r.down = rec and rec.ex.down ~= nil or nil
    for d, x in elro.exits(rec and rec.ex) do
      local de = elro.delta[d]
      if de and x ~= r.id then
        local o = byId[x]
        if o then
          local key = math.min(r.id, x) .. ":" .. math.max(r.id, x)
          if not seen[key] then
            seen[key] = true
            local back = false
            local orec = elro.cs_room(x)
            for _, y in elro.exits(orec and orec.ex) do if y == r.id then back = true end end
            edges[#edges + 1] = { a = r, b = o, oneway = not back }
          end
        elseif roomExists(x) then                          -- leaves this map
          r.stubs[#r.stubs + 1] = de
          local an = elro.areaName(getRoomArea(x))
          if an and an ~= "" then r.to[an] = true end
        end
      end
    end
  end
  return rooms, edges
end

-- The up/down links the screen draws are custom lines the mapper stored on the rooms, in its
-- vertical colour; read back, so paper shows the same links, bends included. Returns a list
-- of point lists in map coordinates, each starting at its room.
function elro.export_verticals(rooms)
  local out = {}
  if type(getCustomLines) ~= "function" then return out end
  local want = (elro.classColours and elro.classColours.vertical) or { 0, 210, 190 }
  for _, r in ipairs(rooms) do
    local ok, lines = pcall(getCustomLines, r.id)
    for _, ln in pairs(ok and type(lines) == "table" and lines or {}) do
      local c = type(ln) == "table" and ln.attributes and ln.attributes.color
      local cr, cg, cb = c and (c.r or c[1]), c and (c.g or c[2]), c and (c.b or c[3])
      if cr == want[1] and cg == want[2] and cb == want[3] and type(ln.points) == "table" then
        local keys = {}
        for k in pairs(ln.points) do if type(k) == "number" then keys[#keys + 1] = k end end
        table.sort(keys)
        local pts = { { r.x, r.y } }
        for _, k in ipairs(keys) do
          local p = ln.points[k]
          local x, y = p.x or p[1], p.y or p[2]
          if x and y then pts[#pts + 1] = { x, y } end
        end
        if #pts > 1 then out[#out + 1] = pts end
      end
    end
  end
  return out
end

-- Which rooms get a number and a line in the list: all of a small area, else the ones worth
-- finding on paper (healers, shops, transport, holy ground, typed exits, ways off the map).
local function numbered(rooms, all)
  local out = {}
  for _, r in ipairs(rooms) do
    local notable = r.glyph or #r.stubs > 0 or (r.cell and NOTABLE[r.cell.group])
                    or (r.dot and NOTABLE[r.dot.group])
    if all or #rooms <= NUMBER_ALL or notable then out[#out + 1] = r end
  end
  -- numbered as the page is read, top row first and left to right, so a number from the
  -- list is found by where it must be and not by hunting
  table.sort(out, function(a, b)
    if a.y ~= b.y then return a.y > b.y end
    if a.x ~= b.x then return a.x < b.x end
    return a.id < b.id
  end)
  -- ...but 1 is the way in: the first room with an exit to the world map, or failing that
  -- the first with any way off this map. A reader starts from the door.
  local door
  for i, r in ipairs(out) do if r.to["world"] then door = i break end end
  if not door then
    for i, r in ipairs(out) do if #r.stubs > 0 then door = i break end end
  end
  if door and door > 1 then table.insert(out, 1, table.remove(out, door)) end
  return out
end

local function list_text(r)
  local s = r.name
  if #s > 30 then s = s:sub(1, 29) .. "." end
  local to = {}
  for an in pairs(r.to) do to[#to + 1] = an end
  table.sort(to)
  if #to > 0 then s = s .. " (to " .. table.concat(to, ", ") .. ")" end
  if #s > 44 then s = s:sub(1, 43) .. "." end
  return s
end

-- The SVG text for one area. `plain` leaves the terrain tints out. `free` is for a screen
-- (a wiki page), not paper: no A4 to fit, so the cell is a fixed comfortable size, the image
-- is as big as the map needs, every room is numbered and the list runs as long as it must.
-- A room takes BOX of its cell; the rest is the gap a connection is seen in. At 0.56 the gaps
-- were nearly as wide as the rooms and the map sprawled; 0.72 keeps a line readable. The free
-- cell is set so the ROOM stays the size it was (6.8 units, 27 pixels) while the gap halves.
local BOX = 0.72
local FREE_CELL = 9.5
function elro.export_svg(aid, plain, free)
  local rooms, edges = elro.export_collect(aid)
  if #rooms == 0 then return nil, "that map has no placed rooms" end
  local minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
  for _, r in ipairs(rooms) do
    minx, maxx = math.min(minx, r.x), math.max(maxx, r.x)
    miny, maxy = math.min(miny, r.y), math.max(maxy, r.y)
  end
  local nx, ny = maxx - minx + 1, maxy - miny + 1

  local list = numbered(rooms, free)
  local used, usedOrder = {}, {}
  for _, r in ipairs(rooms) do
    for _, t in ipairs({ r.cell, r.dot }) do
      if t and not used[t] then used[t] = true ; usedOrder[#usedOrder + 1] = t end
    end
  end
  table.sort(usedOrder, function(a, b) return a.rank < b.rank end)
  local tname = {}
  for name, t in pairs(elro.terrain) do tname[t] = name end

  local best
  if free then
    -- one cell more than the map each way: half a cell all round, where the stubs end
    local W = math.max((nx + 1) * FREE_CELL, 2 * LIST_COL)
    local cols = math.max(1, math.floor(W / LIST_COL))
    local legendRows = plain and 0 or math.ceil(#usedOrder / math.max(1, math.floor(W / 30)))
    local mapH = (ny + 1) * FREE_CELL
    local panel = math.ceil(#list / cols) * LIST_LINE + legendRows * 4.5 + 5
    best = { pw = W + 2 * MARGIN, ph = 2 * MARGIN + HEADER + mapH + panel + 4, W = W, mapH = mapH,
             cell = FREE_CELL, cols = cols, shown = #list, legendRows = legendRows }
  end
  -- A4: try both orientations; keep the one that gives the bigger cell.
  for _, page in ipairs(free and {} or { { 210, 297 }, { 297, 210 } }) do
    local W, H = page[1] - 2 * MARGIN, page[2] - 2 * MARGIN - HEADER
    local cols = math.max(1, math.floor(W / LIST_COL))
    local legendRows = plain and 0 or math.ceil(#usedOrder / math.max(1, math.floor(W / 30)))
    local shown = #list
    local function panel(n) return math.ceil(n / cols) * LIST_LINE + legendRows * 4.5 + 5 end
    while shown > 0 and panel(shown) > H * 0.4 do shown = shown - cols end
    shown = math.max(0, shown)
    local mapH = H - panel(shown)
    local cell = math.min(W / (nx + 1), mapH / (ny + 1), 11)
    if not best or cell > best.cell then
      best = { pw = page[1], ph = page[2], W = W, mapH = mapH, cell = cell, cols = cols,
               shown = shown, legendRows = legendRows }
    end
  end
  local cell, pw, ph = best.cell, best.pw, best.ph
  local box = cell * BOX
  local numbers = box >= 3                     -- below this a number cannot be read
  local ox = MARGIN + (best.W - nx * cell) / 2
  local oy = MARGIN + HEADER + (best.mapH - ny * cell) / 2
  local function px(r) return ox + (r.x - minx + 0.5) * cell end
  local function py(r) return oy + (maxy - r.y + 0.5) * cell end      -- Mudlet's y points up
  local thin = math.max(0.12, math.min(0.3, cell * 0.035))

  local o = {}
  local function w(fmt, ...) o[#o + 1] = string.format(fmt, ...) end
  w('<?xml version="1.0" encoding="UTF-8"?>\n')
  pw, ph = math.ceil(pw), math.ceil(ph)
  if free then                                   -- a screen: pixels, four to the drawing unit
    w('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">\n',
      pw * 4, ph * 4, pw, ph)
  else                                           -- paper: the page size in millimetres
    w('<svg xmlns="http://www.w3.org/2000/svg" width="%dmm" height="%dmm" viewBox="0 0 %d %d">\n',
      pw, ph, pw, ph)
  end
  w('<rect width="%d" height="%d" fill="#ffffff"/>\n', pw, ph)
  w('<g font-family="Helvetica, Arial, sans-serif" fill="#000000">\n')
  local area = elro.areaName(aid) or "map"
  w('<text x="%d" y="%.1f" font-size="6">%s</text>\n', MARGIN, MARGIN + 6, esc(area))
  w('<text x="%d" y="%.1f" font-size="2.6" fill="#444444">%d rooms, %s. ElrohirMapper %s</text>\n',
    MARGIN, MARGIN + 10.5, #rooms, os.date("%Y-%m-%d"), esc(elro.VERSION or ""))
  w('<text x="%.1f" y="%.1f" font-size="3" text-anchor="end">N</text>\n', pw - MARGIN - 1.2, MARGIN + 4)
  w('<path d="M %.1f %.1f l -1.6 3.4 h 3.2 z"/>\n', pw - MARGIN - 2.2, MARGIN + 5)

  w('<g stroke="#222222" stroke-width="%.2f" stroke-linecap="round" fill="none">\n', thin)
  for _, e in ipairs(edges) do
    w('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f"%s/>\n', px(e.a), py(e.a), px(e.b), py(e.b),
      e.oneway and string.format(' stroke-dasharray="%.2f %.2f"', thin * 4, thin * 3) or "")
  end
  for _, r in ipairs(rooms) do
    for _, de in ipairs(r.stubs) do
      local len = math.sqrt(de[1] * de[1] + de[2] * de[2])
      local ux, uy = de[1] / len, -de[2] / len
      w('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke-dasharray="%.2f %.2f"/>\n',
        px(r), py(r), px(r) + ux * cell * 0.7, py(r) + uy * cell * 0.7, thin, thin * 2.2)
    end
  end
  local verticals = elro.export_verticals(rooms)
  for _, pts in ipairs(verticals) do
    local s = {}
    for _, p in ipairs(pts) do
      s[#s + 1] = string.format("%.2f,%.2f", ox + (p[1] - minx + 0.5) * cell,
                                oy + (maxy - p[2] + 0.5) * cell)
    end
    w('<polyline points="%s" stroke-width="%.2f" stroke-dasharray="%.2f %.2f %.2f %.2f"/>\n',
      table.concat(s, " "), thin * 1.4, thin * 6, thin * 2.5, thin, thin * 2.5)
  end
  w('</g>\n')

  for _, r in ipairs(rooms) do
    local x, y = px(r) - box / 2, py(r) - box / 2
    local fill = (not plain and r.cell) and tint(r.cell.col, 0.38) or "#ffffff"
    w('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s" stroke="#222222" stroke-width="%.2f"/>\n',
      x, y, box, box, fill, thin * 1.3)
    -- in the corner, not the middle as on screen: the middle is where the number goes
    if r.dot and not plain then
      w('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s" stroke="#222222" stroke-width="%.2f"/>\n',
        x + box * 0.2, y + box * 0.8, box * 0.15, tint(r.dot.col, 0.75), thin * 0.6)
    end
    if r.up then
      w('<path d="M %.2f %.2f l %.2f %.2f h %.2f z"/>\n', x + box, y - box * 0.28,
        -box * 0.2, box * 0.26, box * 0.4)
    end
    if r.down then
      w('<path d="M %.2f %.2f l %.2f %.2f h %.2f z"/>\n', x + box, y + box * 1.28,
        -box * 0.2, -box * 0.26, box * 0.4)
    end
  end

  -- The number has the middle; the letter for a typed exit has the top left corner, in
  -- italics so the two are not read as one. With no numbers the letter takes the middle.
  local num = {}
  if numbers then for i = 1, best.shown do num[list[i]] = i end end
  for _, r in ipairs(rooms) do
    if num[r] then
      local label = tostring(num[r])
      local fs = box * (#label >= 3 and 0.36 or (#label == 2 and 0.46 or 0.56))
      w('<text x="%.2f" y="%.2f" font-size="%.2f" text-anchor="middle" font-weight="bold">%s</text>\n',
        px(r), py(r) + fs * 0.36, fs, label)
    end
    if r.glyph and box >= 1.6 then
      if num[r] then
        local fs = box * 0.34
        w('<text x="%.2f" y="%.2f" font-size="%.2f" font-style="italic">%s</text>\n',
          px(r) - box * 0.44, py(r) - box * 0.5 + fs * 0.9, fs, esc(r.glyph))
      else
        local fs = box * 0.56
        w('<text x="%.2f" y="%.2f" font-size="%.2f" text-anchor="middle" font-style="italic">%s</text>\n',
          px(r), py(r) + fs * 0.36, fs, esc(r.glyph))
      end
    end
  end

  local ty = MARGIN + HEADER + best.mapH + 4
  if not plain then
    local per = math.max(1, math.floor(best.W / 30))
    for i, t in ipairs(usedOrder) do
      local cx = MARGIN + ((i - 1) % per) * 30
      local cy = ty + math.floor((i - 1) / per) * 4.5
      w('<rect x="%.1f" y="%.1f" width="3" height="3" fill="%s" stroke="#222222" stroke-width="0.15"/>\n',
        cx, cy - 2.6, tint(t.col, 0.38))
      w('<text x="%.1f" y="%.1f" font-size="2.4">%s</text>\n', cx + 4, cy - 0.3, esc(tname[t] or "?"))
    end
    ty = ty + best.legendRows * 4.5
  end
  if numbers then
    local perCol = math.ceil(best.shown / best.cols)
    for i = 1, best.shown do
      local c, row = math.floor((i - 1) / perCol), (i - 1) % perCol
      w('<text x="%.1f" y="%.1f" font-size="%.1f"><tspan font-weight="bold">%d</tspan> %s</text>\n',
        MARGIN + c * LIST_COL, ty + row * LIST_LINE, LIST_FONT, i, esc(list_text(list[i])))
    end
  end
  local note
  if not numbers then note = "The rooms are too small on one sheet to carry numbers."
  elseif #list < #rooms then
    note = "Numbered: healers, shops, transport, holy ground, typed exits and ways off the map."
    if best.shown < #list then
      note = note .. " " .. (#list - best.shown) .. " more of those did not fit the list."
    end
  elseif best.shown < #list then
    note = (#list - best.shown) .. " more rooms did not fit the list."
  end
  -- two lines: together they are wider than a portrait page
  w('<text x="%d" y="%.1f" font-size="2.2" fill="#444444">%s</text>\n', MARGIN, ph - MARGIN + 0.5,
    esc("Dashed: a one-way exit. Dotted stub: leads to another map. Triangle and dash-dot line: "
        .. "up or down. Italic letter: an exit you type."))
  if note then
    w('<text x="%d" y="%.1f" font-size="2.2" fill="#444444">%s</text>\n', MARGIN, ph - MARGIN + 3.5,
      esc(note))
  end
  w('</g>\n</svg>\n')
  return table.concat(o), nil, { rooms = #rooms, edges = #edges, listed = numbers and best.shown or 0,
                                 cell = cell, landscape = pw > ph, width = pw, height = ph }
end

-- mapexport [area] [plain] [a4]: bare = the map you are standing on, as an image for a screen.
-- 'a4' is the page for paper. The option words are taken off the end, in any order, so an
-- area may still be called anything.
function elro.cmd_export(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local plain, free = false, true
  while true do
    local head, word = arg:match("^(.-)%s*(%w+)$")
    if word == "plain" then plain, arg = true, head
    elseif word == "a4" then free, arg = false, head
    else break end
  end
  local aid, name
  if arg == "" then
    if not elro.current or not roomExists(elro.current) then
      cecho("\n<red>[elro]: move once first, or name an area: mapexport <area>\n<reset>") return
    end
    aid = getRoomArea(elro.current) ; name = elro.areaName(aid)
  else
    local many
    aid, name, many = elro.find_area(arg)
    if not aid then
      cecho("\n<red>[elro]: " .. (many and ("several maps match: " .. table.concat(many, ", "))
            or ("no map called '" .. arg .. "'")) .. "\n<reset>") return
    end
  end
  local svg, err, info = elro.export_svg(aid, plain, free)
  if not svg then cecho("\n<red>[elro]: " .. tostring(err) .. ".\n<reset>") return end
  local dir = getMudletHomeDir() .. "/elro_export"
  if lfs and lfs.mkdir then pcall(lfs.mkdir, dir) end
  local path = dir .. "/" .. (tostring(name):gsub("[^%w%-_]+", "_")) .. (free and "" or "_a4") .. ".svg"
  local f, ferr = io.open(path, "w")
  if not f then cecho("\n<red>[elro]: cannot write " .. path .. ": " .. tostring(ferr) .. "\n<reset>") return end
  f:write(svg) ; f:close()
  cecho(string.format("\n<green>[elro]: '%s' exported: %d rooms, %d listed, %s.<reset>\n  %s\n",
        tostring(name), info.rooms, info.listed,
        free and string.format("%d x %d pixels, every room numbered", info.width * 4, info.height * 4)
              or ("A4 " .. (info.landscape and "landscape" or "portrait")), path))
  if free then
    cecho("  For paper: 'mapexport <area> a4' fits one sheet.\n")
  elseif info.listed < info.rooms then
    cecho("  Only rooms of note are numbered on one sheet; without 'a4' every room is.\n")
  end
  if not free and info.cell < 3 then
    cecho("<yellow>  This map is big for one sheet: the rooms come out under 2 mm. It prints, but "
          .. "a smaller area reads better.<reset>\n")
  end
  if type(cechoLink) == "function" and type(openUrl) == "function" then
    cechoLink("  <cyan>open it in your browser<reset>", function() openUrl("file:///" .. path) end,
              "Open the SVG in your browser", true)
    cecho(free and "\n" or "  (then print from there)\n")
  end
end
