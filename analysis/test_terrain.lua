-- Terrain colouring: elro.terrain_pick + the ONE-HIGHLIGHT-SLOT arbitration.
--
-- Runs the SHIPPED functions behind engine_load's Mudlet stubs, so this exercises
-- the real table and the real priority ladder rather than a restatement of them.
--   cd .../map_helper/client && luajit analysis/test_terrain.lua
dofile("analysis/engine_load.lua")

local fails, checks = 0, 0
local function ok(cond, what)
  checks = checks + 1
  if not cond then fails = fails + 1 ; print("  FAIL  " .. what) end
end

-- ---- elro.terrain_pick -----------------------------------------------------
-- Priority order only. Which of the two ends up as the CELL and which as the DOT is
-- elro.terrain_roles' business, tested separately below -- and it is NOT the obvious
-- assignment, so the two must be checked apart.
local function pick(csv)
  local _, _, pn, sn = elro.terrain_pick(csv)
  return (pn or "-") .. "/" .. (sn or "-")
end

print("terrain_pick(csv) -> primary/secondary")
local cases = {
  -- the case the whole feature exists for: a way over a landform
  { "road,forest,outdoors",     "road/forest"        },
  { "track,mountain",           "track/mountain"     },
  -- SAME GROUP -> no second colour. A blue dot on a blue cell says nothing.
  { "sea,water",                "sea/-"              },
  { "lake,waterside",           "lake/-"             },
  { "road,track",               "road/-"             },
  -- fallbacks are never a secondary: "and it is outdoors" is noise everywhere
  { "forest,outdoors",          "forest/-"           },
  { "urban,indoors",            "urban/-"            },
  -- ...and a room that is ONLY a fallback has nothing to say twice
  { "indoors",                  "indoors/-"          },
  { "outdoors",                 "outdoors/-"         },
  -- water TOUCHING a landform is the other case worth having
  { "forest,waterside",         "forest/waterside"   },
  { "beach,sea",                "sea/beach"          },  -- the body outranks the shore
  -- surface underfoot is its own group, so a snowy forest keeps both facts
  { "forest,snow",              "forest/snow"        },
  { "mountain,ice,outdoors",    "mountain/ice"       },
  -- where you can heal outranks everything, and keeps its own group so a temple
  -- that also heals still says so with the circle
  { "heal,indoors",             "heal/-"             },
  { "heal,holy,square",         "heal/holy"          },
  { "heal,forest",              "heal/forest"        },
  -- a shop that buys is the other mark worth the trip, and shares healing's group:
  -- a pub that also buys loot is one errand, not two
  { "shop,urban",               "shop/urban"         },
  { "heal,shop",                "heal/-"             },
  -- the transport system is its own group, so a port keeps the ground it sits on
  { "port,waterside",           "port/waterside"     },
  { "transport,indoors",        "transport/-"        },
  { "shop,port",                "shop/port"          },
  -- sacred outranks everything below it, including a road through a temple square
  { "holy,road,square",         "holy/road"          },
  { "unholy,cave",              "unholy/cave"        },
  -- the secondary is the best of the OTHER groups, not merely the second listed
  { "forest,indoors,road",      "road/forest"        },
  { "plain,grass,river",        "river/plain"        },
  -- a room that REPORTED and had nothing we colour is plain, i.e. outdoors...
  { "cold,humid,no_teleport",   "outdoors/-"         },
  { "-",                        "outdoors/-"         },   -- elro.TERR_NONE
  -- ...but a room we have never heard from stays uncoloured
  { "",                         "-/-"                },
}
for _, c in ipairs(cases) do
  local got = pick(c[1])
  ok(got == c[2], string.format("%-26s -> %-20s (want %s)", c[1], got, c[2]))
end
ok(pick("outdoors,forest,road") == pick("road,forest,outdoors"),
   "csv order is irrelevant -- rank decides, not arrival")

-- ---- table integrity -------------------------------------------------------
print("table integrity")
local seen, envs, n = {}, {}, 0
local GROUPS = { aid = 1, travel = 1, sacred = 1, way = 1, water = 1,
                 land = 1, built = 1, surf = 1, fallback = 1, maze = 1 }
for name, t in pairs(elro.terrain) do
  n = n + 1
  ok(not seen[t.rank], "rank " .. t.rank .. " is unique (" .. name ..
                       (seen[t.rank] and " clashes with " .. seen[t.rank] or "") .. ")")
  seen[t.rank] = name
  -- ⚠ A DUPLICATE ENV ID IS THE SILENT ONE: Mudlet stores the id in the map
  -- file, so a collision paints already-painted rooms in the wrong terrain's
  -- colour with nothing to show for it. This is the check that keeps env ids
  -- disjoint now that they no longer derive from rank.
  ok(not envs[t.env], "env " .. tostring(t.env) .. " is unique (" .. name ..
                      (envs[t.env] and " clashes with " .. envs[t.env] or "") .. ")")
  envs[t.env] = name
  ok(type(t.env) == "number" and t.env > 16,
     name .. " env id is clear of Mudlet's built-in 1-16")
  ok(GROUPS[t.group], name .. " has a known group")
  ok(type(t.col) == "table" and #t.col == 3, name .. " has an rgb triple")
  for _, v in ipairs(t.col) do ok(v >= 0 and v <= 255, name .. " colour component in range") end
end
ok(n == 39, "39 terrains defined (got " .. n .. ")")

-- ranks are a dense 1..n ordering, so "lower wins" has no gaps to reason about
for i = 1, n do ok(seen[i], "rank " .. i .. " is used") end

-- ---- elro.terrain_roles ----------------------------------------------------
-- ⭐ THE MARK IS THE HIGHER-PRIORITY TERRAIN. The ladder ranks features
-- (heal, holy, road) above bodies (land, water, built), so the top entry
-- is the thing that should be a small dot and the one below it is the mass it
-- sits in: a road through a forest is a GREEN cell with a BROWN dot, not the
-- reverse. Getting this backwards is silent -- the map still colours, it just says
-- the wrong thing about where you are -- so it is asserted explicitly.
print("terrain_roles(csv) -> cell/dot")
local function roles(csv)
  local _, _, cn, dn = elro.terrain_roles(csv)
  return (cn or "-") .. "/" .. (dn or "-")
end
local rcases = {
  { "road,forest,outdoors",     "forest/road"        },  -- the case it exists for
  { "heal,forest",              "forest/heal"        },  -- a pub in the woods
  { "holy,road,square",         "road/holy"          },
  { "track,mountain",           "mountain/track"     },
  { "forest,waterside",         "waterside/forest"   },
  { "forest,snow",              "snow/forest"        },  -- snow is what you see
  -- one terrain -> it is the CELL. A lone dot on an uncoloured cell would read as
  -- "unmapped, with a speck on it".
  { "forest",                   "forest/-"           },
  { "sea,water",                "sea/-"              },  -- same group, no second
  { "forest,outdoors",          "forest/-"           },  -- fallback never a role
  { "indoors",                  "indoors/-"          },
  { "cold,humid",               "outdoors/-"         },
  { "",                         "-/-"                },
}
for _, c in ipairs(rcases) do
  local got = roles(c[1])
  ok(got == c[2], string.format("%-26s -> %-22s (want %s)", c[1], got, c[2]))
end

-- ---- the ONE highlight slot ------------------------------------------------
-- occluded > maze > terrain, every source read from PERSISTENT room state so the
-- paint is reproducible after a restart with no relayout.
print("highlight arbitration")
local captured
local realHi, realUn = highlightRoom, unHighlightRoom
-- ⛔ highlightRoom is (roomID, rim rgb, centre rgb, radius, RIM alpha, CENTRE
-- alpha) -- the first colour+alpha pair is Mudlet's 0.95 gradient stop, the second
-- its 0 stop. Verified live. Name them that way here so the assertions below cannot
-- be read the wrong way round.
function highlightRoom(_, r, g, b, _2, _3, _4, rad, aOut, aIn)
  captured = { r, g, b, rad = rad, out = aOut, inn = aIn }
end
function unHighlightRoom() captured = nil end

local function paint(ud)
  deleteRoom(1) ; addRoom(1)
  for k, v in pairs(ud) do setRoomUserData(1, k, v) end
  captured = nil
  elro.highlight_paint(1)
  return captured
end
local function is(c, want) return c and c[1] == want[1] and c[2] == want[2] and c[3] == want[3] end

local YEL = elro.classColours.occluded
local MAZ = elro.classColours.maze
local ROAD = elro.terrain.road.col

ok(is(paint({ occl = "1", fold = "maze-7", terr = "road,forest" }), YEL),
   "occluded beats maze AND terrain")
ok(is(paint({ fold = "maze-7", terr = "road,forest" }), MAZ), "maze beats terrain")
ok(is(paint({ terr = "road,forest" }), ROAD),
   "the dot is the HIGHER-priority terrain (the mark), not the cell it sits in")
ok(paint({ terr = "forest,outdoors" }) == nil,
   "one terrain only -> the slot is cleared, never left stale")
ok(is(paint({ fold = "sewers", terr = "road,forest" }), ROAD),
   "a non-maze fold does not claim the slot")

elro.terrainOn = false
ok(paint({ terr = "road,forest" }) == nil, "mapterrain off drops the dot...")
ok(is(paint({ fold = "maze-7", terr = "road,forest" }), MAZ),
   "...but never the maze warning")
elro.terrainOn = true

-- ⭐ SHAPE, NOT JUST COLOUR. Mudlet paints the highlight on top of the room and
-- gives no z-order control, so the only way to add a colour without hiding the room,
-- its glyph and its exits is to put the opacity at the RIM and leave the centre
-- transparent. A terrain highlight that ever comes back as a disc has lost the point
-- of the feature, so assert the gradient DIRECTION rather than trusting constants.
-- ⛔ EQUAL ALPHAS ARE THE POINT. Mudlet interpolates linearly between the two
-- gradient stops, so any difference is a soft wash rather than a shape -- a halo
-- with a transparent centre veils the room instead of ringing it (tried live, and
-- abandoned). Equal stops mean no gradient at all: a flat, hard-edged dot.
local t = paint({ terr = "road,forest" })
ok(t and t.out == t.inn, "the terrain dot is FLAT -- equal alphas, so no gradient wash")
ok(t and t.rad < (elro.onEdgeHiRadius or 0.6),
   "...and small, so the cell colour stays readable around it")
-- ⚠ THESE TWO RECORD WHAT IS RENDERED, NOT WHAT IS INTENDED. Both pre-date the
-- terrain work and both are the opposite of their own comments, because the knob
-- names (onEdgeHiFill / onEdgeHiEdge) assert the wrong argument order. Kept as-is on
-- purpose -- flipping a long-standing visual is the user's call. If they are ever
-- corrected, these two assertions flip with them and that is the intended signal.
local o = paint({ occl = "1" })
ok(o and o.out < o.inn,
   "occluded renders as a DISC today (its comment claims a see-through border)")
local m = paint({ fold = "maze-7" })
ok(m and m.out > m.inn,
   "maze renders as a RING today (its comment claims a blob)")

highlightRoom, unHighlightRoom = realHi, realUn

-- ---- the glyph carries the mark where they would collide --------------------
-- ⭐ The room char and the terrain dot are both CENTRED and Mudlet paints the
-- highlight last, so drawing both just hides the glyph. A room with both puts the
-- mark's colour on the GLYPH -- shape says which non-compass exit, colour says the
-- terrain mark -- and the dot is suppressed there.
print("glyph vs dot")
local hiCol, chCol
local realHi2, realUn2, realCC = highlightRoom, unHighlightRoom, setRoomCharColor
function highlightRoom(_, r, g, b) hiCol = { r, g, b } end
function unHighlightRoom() hiCol = nil end
function setRoomCharColor(_, r, g, b) chCol = { r, g, b } end

local ROADC = elro.terrain.road.col
local GOLD  = (elro.classColours and elro.classColours.glyph) or { 255, 210, 90 }
elro.glyphs = true
deleteRoom(6) ; addRoom(6)
setRoomUserData(6, "terr", "road,forest")

hiCol, chCol = nil, nil
elro.glyph_paint(6, "E")                  -- as note_nonstd does for an 'enter' exit
ok(getRoomChar(6) == "E", "the glyph character itself is untouched")
ok(is(chCol, ROADC), "the glyph is tinted with the MARK's colour, not the default gold")
elro.highlight_paint(6)
ok(hiCol == nil, "and no dot is drawn there -- it would land on the glyph")

hiCol, chCol = nil, nil
elro.glyph_paint(6, "")                   -- same room, glyph cleared
elro.highlight_paint(6)
ok(is(hiCol, ROADC), "with no glyph the dot comes back, in the mark's colour")

hiCol, chCol = nil, nil
setRoomUserData(6, "terr", "forest")      -- one terrain: cell only, no mark
elro.glyph_paint(6, "E")
ok(is(chCol, GOLD), "a room with no MARK keeps the default gold glyph")
elro.highlight_paint(6)
ok(hiCol == nil, "...and still has no dot")

hiCol = nil
elro.glyphs = false
setRoomUserData(6, "terr", "road,forest")
elro.highlight_paint(6)
ok(is(hiCol, ROADC), "mapglyphs off -> nothing to collide with, so the dot returns")
elro.glyphs = true
setRoomChar(6, "")

-- ---- a terrain that takes the DOT and gives up the glyph -------------------
-- ⭐ WHY: every port and every transport room has something you type to board it,
-- so it always had an exit letter, so its mark always degraded to a TINT of that
-- letter -- the one case the tint is not enough. These terrains drop the letter
-- and keep the flat dot, which needs no font.
print("terrain dot-only")
deleteRoom(8) ; addRoom(8)
setRoomUserData(8, "terr", "port,waterside")
ok(elro.terrain_dot_only("port,waterside"), "a dot-only terrain is recognised in the csv")
ok(elro.terrain_dot_only("road,forest") == false, "an ordinary terrain keeps its letter")
ok(elro.terrain_dot_only("") == false, "no terrain, no claim")
ok(elro.glyph_char(8) == "", "such a room shows no character at all")

setRoomChar(8, "E")                       -- as note_nonstd does for an 'enter' exit
hiCol, chCol = nil, nil
elro.terrain_paint(8)
ok(getRoomChar(8) == "", "terrain_paint clears the letter once the terrain is known")
ok(is(hiCol, elro.terrain.port.col), "...and the dot it was blocking is drawn, in port's colour")

setRoomUserData(8, "terr", "waterside")   -- the claim goes away
setRoomChar(8, "E") ; elro.terrain_paint(8)
ok(getRoomChar(8) == "E", "a room without the claim keeps its letter")

elro.glyphs = false
ok(elro.glyph_char(8) == "", "mapglyphs off silences every glyph, claim or not")
elro.glyphs = true
elro.terrainOn = false
ok(elro.terrain_dot_only("port") == false, "mapterrain off drops the claim too -- it is a terrain rule")
elro.terrainOn = true
setRoomChar(8, "")

-- ---- a folded maze: violet cell, gold "?" ---------------------------------
-- `terr=maze` arrives alone and with no exits, so the "?" is forced and the
-- gold falls out of there being no secondary terrain to tint it.
print("maze node")
deleteRoom(9) ; addRoom(9)
setRoomUserData(9, "terr", "maze")
ok(elro.is_maze_terr("maze"), "the maze token is recognised")
ok(elro.is_maze_terr("road,forest") == false, "an ordinary csv is not a maze")
ok(elro.glyph_char(9) == "?", "a maze node shows ? with no exits to derive it from")
local mcell, mdot = elro.terrain_roles("maze")
ok(is(mcell.col, elro.terrain.maze.col), "the cell is the maze violet")
ok(mdot == nil, "and nothing is drawn on top of it")
hiCol, chCol = nil, nil
elro.glyph_paint(9, elro.glyph_char(9))
ok(is(chCol, GOLD), "so the ? keeps the default gold, which reads on the violet")
-- The PAINT path too, not just glyph_char: asserting glyph_char alone passed
-- while the map showed no ? at all.
setRoomChar(9, "")
elro.terrain_paint(9)
ok(getRoomChar(9) == "?", "terrain_paint CREATES the ? on a room that had no glyph")
ok(getRoomEnv(9) == elro.terrain.maze.env, "...on the maze's own violet env")
elro.glyphs = false
ok(elro.glyph_char(9) == "", "mapglyphs off silences the maze ? like any other")
elro.glyphs = true

highlightRoom, unHighlightRoom, setRoomCharColor = realHi2, realUn2, realCC

-- ---- env colour ------------------------------------------------------------
print("env colour")
deleteRoom(2) ; addRoom(2)
setRoomUserData(2, "terr", "road,forest")
elro.terrain_paint(2)
ok(getRoomEnv(2) == elro.terrain.forest.env,
   "env comes from the CELL role -- the body, i.e. the LOWER-priority terrain")

setRoomUserData(2, "terr", "road")
elro.terrain_paint(2)
ok(getRoomEnv(2) == elro.terrain.road.env,
   "...but a lone terrain fills the cell whatever its rank")

setRoomUserData(2, "terr", "")
elro.terrain_paint(2)
ok(getRoomEnv(2) == 0, "a room never heard from keeps Mudlet's default env")

setRoomUserData(2, "terr", elro.TERR_NONE)
elro.terrain_paint(2)
ok(getRoomEnv(2) == elro.terrain.outdoors.env,
   "a room that reported NO terrain is painted outdoors, not left blank")

setRoomUserData(2, "terr", "forest")
elro.terrainOn = false
elro.terrain_paint(2)
ok(getRoomEnv(2) == 0, "mapterrain off restores the default env")
elro.terrainOn = true
elro.terrain_paint(2)
ok(getRoomEnv(2) == elro.terrain.forest.env, "...and back on repaints it")

-- ---- onRoom: store, and never wipe on a nil field --------------------------
print("onRoom plumbing")
deleteRoom(3) ; addRoom(3)
elro.onRoom(3, 0, "none", "A Clearing", "world", "north,south", "forest,outdoors")
ok(getRoomUserData(3, "terr") == "forest,outdoors", "onRoom stores the terr field")
elro.onRoom(3, 0, "none", "A Clearing", "world", "north,south")   -- older server
ok(getRoomUserData(3, "terr") == "forest,outdoors",
   "a NIL terr field means an old server, not 'no terrain' -- must not wipe")
elro.onRoom(3, 0, "none", "A Clearing", "world", "north,south", "")
ok(getRoomUserData(3, "terr") == elro.TERR_NONE,
   "an EMPTY terr field is a REPORT of no terrain -- stored as the sentinel")

-- ⚠ THE SILENT SKEW: an OLD package's regex ends `exits=(.*)$`, so the whole
-- terrain payload lands in `exits`. Unhandled that breaks elro.advertises -> no
-- assumed reverse edge -> cross-area edges quietly lose their blue stub.
deleteRoom(4) ; addRoom(4) ; deleteRoom(5) ; addRoom(5)
setRoomCoordinates(4, 0, 0)
elro.onRoom(5, 4, "east", "Hilltop", "world", "west,north|terr=hills,outdoors")
ok(getRoomExits(5)["west"] == 4,
   "a bled exits field still yields the assumed reverse (the stub-killer)")
ok(getRoomUserData(5, "terr") == "hills,outdoors",
   "...and the terrain is recovered out of it rather than lost")

print(string.format("\n%s  %d/%d checks passed",
      fails == 0 and "PASS" or "FAIL", checks - fails, checks))
os.exit(fails == 0 and 0 or 1)
