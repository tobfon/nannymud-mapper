-- elro._score_cands must price shear for EVERY candidate carrying a set.
-- It used to price the table only when some candidate had kind == "diag-eq", so a table of
-- plain eq-plates was ranked shear-blind and a plate that tipped a settled 45 won on score.
-- Run: luajit analysis/test_shearall.lua      (from the client dir)
dofile("analysis/engine_load.lua")

local fail, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fail = fail + 1
    print(string.format("FAIL %-50s got %s want %s", what, tostring(got), tostring(want)))
  end
end

-- The reported geometry: 11183 -southeast-> 11184 is a truthful 45 at (0,1)->(1,0).
-- Moving 11183 west by one turns it into (2,-1) -- off 45.
local coord = { [11183] = { 0, 1 }, [11184] = { 1, 0 }, [11185] = { 1, 1 } }
local adj = {
  [11183] = { southeast = 11184 },
  [11184] = { northwest = 11183, north = 11185 },
  [11185] = { south = 11184 },
}

local function shearing()  return { kind = "eq-plate", set = { [11183] = true },
                                    deltas = { [11183] = { -1, 0 } }, dist = 1 } end
local function clean()     return { kind = "eq-plate", set = { [11185] = true },
                                    deltas = { [11185] = { 0, 1 } }, dist = 1 } end

-- no diag-eq anywhere in the table: this is the case that used to go unpriced
local cands = { shearing(), clean() }
elro._score_cands(coord, adj, 11186, 11183, nil, cands)
eq(cands[1].shear, 1, "a plate tipping a 45 is priced, with no diag-eq in the table")
eq(cands[2].shear, 0, "a plate that tips nothing prices 0")

-- and the ranking must then prefer the clean one at equal score
local a = elro._pref_key(2, cands[1].shear)
local b = elro._pref_key(2, cands[2].shear)
eq(b < a, true, "at equal score the shear-free plate sorts first")

-- diagSkewCap = 0 is the documented off switch and must still skip the work
local cands2 = { shearing() }
local capWas = elro.TUNE.diagSkewCap
elro.TUNE.diagSkewCap = 0
elro._score_cands(coord, adj, 11186, 11183, nil, cands2)
eq(cands2[1].shear, nil, "diagSkewCap = 0 leaves shear unpriced")
elro.TUNE.diagSkewCap = capWas

print(string.format("test_shearall: %d check(s), %d failure(s)", checks, fail))
os.exit(fail == 0 and 0 or 1)
