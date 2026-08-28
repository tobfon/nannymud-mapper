-- RENDER `mapfacefit` OFFLINE, against a dump.
--
--   luajit analysis/test_facefit_report.lua analysis/soulfly.txt 100
--   luajit analysis/test_facefit_report.lua analysis/world_live.txt      -- tau defaults to 0
--
-- Calls the REAL `elro.facefit_report` with a stubbed `sel_or_area` and a plain-text `cecho`, so what
-- prints here is exactly what prints in game. That matters: the cost census is the thing being
-- reasoned about, and a harness that re-formats it is a second place for the numbers to drift.
-- ⚠ `crossCost` is forced ON (there is nothing to look at otherwise); tau comes from arg[2].
dofile("analysis/engine_load.lua")

local DELTA = { east = {1,0}, northeast = {1,1}, north = {0,1}, northwest = {-1,1},
                west = {-1,0}, southwest = {-1,-1}, south = {0,-1}, southeast = {1,-1} }
local ADJ, ORDER = {}, {}
local path = arg[1] or error("usage: test_facefit_report.lua <dump> [tau]")
local f = assert(io.open(path))
for ln in f:lines() do
  local id, _, _, ex = ln:match("^%s*(%d+) %((-?%d+),(-?%d+),%-?%d+%) area=%S+ %[(.*)%]%s*$")
  if id then
    id = tonumber(id) ; ORDER[#ORDER + 1] = id ; ADJ[id] = {}
    for d, t in ex:gmatch("(%a+)%->(%d+)") do if DELTA[d] then ADJ[id][d] = tonumber(t) end end
  end
end
f:close()

function cecho(s) io.write((tostring(s):gsub("<[^>]->", ""))) end
-- ⚠ hand back the RAW adj: `facefit_report` runs `walk_adj` itself, and doing it here too would
-- demote twice.
elro.sel_or_area = function() return ORDER, ADJ, path end
elro.crossCost = true
elro.TUNE.crossCostTau = tonumber(arg[2] or "0")
elro.facefit_report()
print()
