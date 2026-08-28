-- Emit the knob-sweep spec list for `cover_knobs.sh`, one `<tag>\t<spec>` per line.
--
--   luajit analysis/cover_specs.lua            (from area/map_helper/client)
--
-- For every entry of `elro.KNOBS` we want the configuration that flips its branch, which means
-- knowing the DEFAULT -- and the default lives in the READ, not in the registry:
--
--   elro.foo ~= false     -> default ON      -> flip with foo=false
--   if elro.foo then      -> default OFF     -> flip with foo=true
--   elro.foo or 8         -> a tunable, not a branch: no flip (listed under NUMERIC below)
--
-- ⚠ COMMENTS AND STRINGS FIRST, same lesson as `knob_audit.lua`: a knob is NAMED in prose an order
-- of magnitude more often than it is read, and every mention of `elro.foo` inside a comment reads
-- as a bare-truthy gate. Without the strip, nearly the whole registry classifies as default-OFF.
--
-- MIXED (read both ways at different sites) gets BOTH flips emitted. That is not defensive: today
-- `seamNoTight` is read `elro.seamNoTight and _inSeamWalk` at layout.lua:11762 and
-- `elro.seamNoTight ~= false and _inSeamWalk` at 12786, so neither single spec covers both sites.

local function strip(txt)
  local out = {}
  for line in (txt .. "\n"):gmatch("([^\n]*)\n") do
    local i = line:find("%-%-")
    out[#out + 1] = i and line:sub(1, i - 1) or line
  end
  return table.concat(out, "\n")
end
-- ⚠ AND THE CODE SCAN NEEDS THE STRING LITERALS GONE AS WELL (a trace string names `closeTight`),
-- but the REGISTRY must keep them -- its entries ARE string literals, so blanking them there leaves
-- an empty list and a sweep of nothing. Two steps, not one.
local function nostr(txt) return (txt:gsub('"[^"\n]*"', '""')) end
local function read(p) local f = assert(io.open(p)) local s = f:read("*a") f:close() return s end

local coreRaw = read("lua/core.lua")
local engine = {}
for _, m in ipairs(dofile("lua/modules.lua")) do
  if m ~= "core.lua" then engine[#engine + 1] = strip(read("lua/" .. m)) end
end
local code = nostr(table.concat(engine, "\n") .. "\n" .. strip(coreRaw))
-- ⚠ STRIP THE REGISTRY TOO, not just the code. Half the KNOBS block is prose, and that prose quotes
-- words -- "failed", "inert", "tune", "off", "always", "lca" -- which a raw scan for quoted
-- identifiers reports as knobs that are UNREFERENCED. Six phantom findings bury the one real one.
local list = strip(coreRaw:match("elro%.KNOBS%s*=%s*{(.-)\n}"))

-- A handful of knobs are numbers whose OFF state is a specific value rather than `false`, and one
-- (`cascadeGrowW`) has no `or N` fallback at all -- it reads `if GW == nil then GW = 2 end`, so the
-- `or %d` sniff misses it and a naive sweep would hand a growth WIDTH the value `true`.
local NUMERIC_OFF = { diagSkewCap = "0", crossCostTau = "0", cascadeGrowW = "0" }

print("base\t-")
local numeric = {}
for name in list:gmatch('"([%w_]+)"') do
  -- ⛔⛔ A DEFAULT CAN BE A NAME, NOT ONLY A LITERAL, and missing that produced a spec that CRASHES
  -- the engine: the five vertical caps read `elro.vertScale or TUNE.vertScaleCap` (also vertPistonL1,
  -- vertPistonTries, vertRoomTries, vertRoomWork), so a `%d`-only sniff called them booleans and
  -- emitted `vertScale=true` -> `for k = 1, true` -> "'for' limit must be a number".
  -- ⚠ AND THE DAMAGE WAS NOT THE CRASH, IT WAS WHAT THE CRASH LOOKED LIKE. In `cover_knobs.sh` each
  -- (tag, area) is its own process, so it showed up as five `!! vertScale_on / <area> FAILED` lines
  -- that read as known noise. In `knob_leave1.sh` every spec shares ONE process, so one bad spec
  -- killed all 87 for that area -- and the report said "every flip: 0 rooms differ", i.e. MISSING
  -- DATA RENDERED AS A CLEAN RESULT. That is why that harness now counts its own diff lines.
  -- Same bug lived in `knob_audit.lua` (fixed 2026-08-21); two copies of one sniff, one fixed.
  local isNum = (code:find("elro%." .. name .. "%s+or%s+[%d%.]")
              or code:find("elro%." .. name .. "%s+or%s+[A-Z][%w_%.]*")) ~= nil
  local on, off = false, false
  local n = 0
  for pre in code:gmatch("elro%." .. name .. "%s*([~=]=?%s*%a*)") do
    n = n + 1
    if pre:find("~=%s*false") or pre:find("==%s*false") then on = true else off = true end
  end
  local total = select(2, code:gsub("elro%." .. name .. "%f[^%w_]", ""))
  if total > n then off = true end
  if total == 0 then
    print(("# %s\tUNREFERENCED"):format(name))
  elseif isNum and not NUMERIC_OFF[name] then
    numeric[#numeric + 1] = name
  else
    if NUMERIC_OFF[name] then
      -- the listed value IS the flip, and it is the ONLY one: `diagSkewCap=true` reaches
      -- `(elro.diagSkewCap or 100) * s` and multiplies a boolean.
      print(("%s_off\t%s=%s"):format(name, name, NUMERIC_OFF[name]))
    else
      if on then print(("%s_off\t%s=false"):format(name, name)) end
      if off then print(("%s_on\t%s=true"):format(name, name)) end
    end
  end
end
print("# NUMERIC (tunables, no branch to flip): " .. table.concat(numeric, " "))

-- ⚠⚠ THE SWEEP'S BLIND SPOT, REPORTED RATHER THAN LEFT TO BE REDISCOVERED. A switch that is READ
-- from `elro.*` but appears in neither registry and is never assigned in the source can only be set
-- by hand from the Mudlet command line -- so `cover_knobs.sh` never flips it, its branch is
-- uncovered in every configuration, and `cover_report.lua` files it under "no configuration reaches
-- this". That is the tool arguing to delete code whose switch it simply cannot reach. Some of these
-- are deliberately unregistered (the KNOBS header names markOnEdge, maze_mut, szMemo, stitchUnblock,
-- cellContention, chainSites -- registering one changes what reset_knobs clears); the rest are just
-- undocumented. Either way: check this list before believing a dead-code verdict.
local assigned, read = {}, {}
for name in code:gmatch("function%s+elro%.([%a_][%w_]*)") do assigned[name] = true end
for name in code:gmatch("elro%.([%a_][%w_]*)%s*=") do assigned[name] = true end
for name in code:gmatch("elro%.([%a_][%w_]*)") do read[name] = true end
local reg = {}
for n in list:gmatch('"([%w_]+)"') do reg[n] = true end
local probes = strip(coreRaw:match("elro%.PROBES%s*=%s*{(.-)\n}") or "")
for n in probes:gmatch('"([%w_]+)"') do reg[n] = true end
-- ⚠ SKIP THE `_` PREFIX. `elro._foo` is this codebase's convention for internal state, and most of
-- it is written by MULTIPLE ASSIGNMENT (`elro._a, elro._b = 0, 0`) which the `elro%.name%s*=` sniff
-- cannot see -- so without this the list is 56 counters and 37 switches, and nobody reads it.
local orphan = {}
for name in pairs(read) do
  if not assigned[name] and not reg[name] and not name:find("^_") then orphan[#orphan + 1] = name end
end
table.sort(orphan)
print(("# UNREGISTERED FLAGS -- read, never assigned, in no registry (%d; the sweep cannot flip these): %s")
  :format(#orphan, table.concat(orphan, " ")))
