-- ⛔⛔⛔ THE LUA 5.1 C-CALL BOUNDARY RULE, CHECKED AGAINST THE **REAL** ENGINE.
--
--   luajit analysis/test_noyield.lua [dump ...]        (from client/; defaults to a spread of dumps)
--
-- Mudlet is stock Lua 5.1, which cannot yield a coroutine across a pcall. A background relayout
-- therefore dies -- ONLY in background mode, ONLY in game -- if any `elro.bg_tick` is reachable
-- while a pcall sits on the stack. LuaJIT happily permits it, so no ordinary offline run and no
-- foreground test can catch the bug; it has to be turned into an assertion this interpreter CAN
-- enforce, which is what this does.
--
-- ⚠ WHY THIS EXISTS BESIDE test_bgcs.lua's test 7. That test proves the DRIVER's shape and is worth
-- having -- but it stubs `elro.layout_one` out entirely, so it never enters compose_spqr and cannot
-- see layout.lua's real call graph. Measured: disabling the `elro._noYield` guard altogether leaves
-- test 7 passing. It is not a check on the engine.
--
-- ⭐ WHAT THIS DOES INSTEAD: shadow `pcall` with a depth counter, shadow `elro.bg_tick` to record
-- every call made while depth > 0, and run the REAL relayout on real dumps. No coroutine is needed:
-- the violation is "a tick is REACHABLE under a pcall", a property of the call graph rather than of
-- whether a yield happened to fall due on this run -- so the check is deterministic instead of
-- timing-dependent.
--
-- A tick under a pcall is legal exactly when the caller has raised `elro._noYield`, which makes
-- bg_tick decline to yield (core.lua). So the failure condition is
--     depth > 0  AND  not elro._noYield
-- and the report names the tick SITE, which is what you need in order to fix it.
--
-- ⛔⛔ AND IT MUST FOLLOW THE **BACKGROUND** BRANCH. `elro.layout_eqw` pcalls the whole solve on the
-- FOREGROUND path only (`if elro.bg_inside() then ... else pcall(compose_spqr) end`), so an
-- unstubbed offline run sits inside one pcall frame for its entire length and every tick site in
-- the engine reads as a violation -- 35 of them, including `place-room`, which plainly works in
-- game today. `bg_inside` has exactly ONE caller, that branch, so stubbing it true buys the real
-- in-game call graph and nothing else.

local dumps = {}
for i = 1, #arg do dumps[#dumps + 1] = arg[i] end
if #dumps == 0 then
  -- one planar area, one with a real 2-core, one with a forced crossing, one curled, one big --
  -- between them they reach elro.faces / blocks_adj / pick_outer_face and both crossing provers.
  dumps = { "analysis/lyr.txt", "analysis/rand.txt", "analysis/mael_live.txt",
            "analysis/soulfly.txt", "analysis/world_block.txt" }
end

local realpcall, realdofile = pcall, dofile
local depth, bad = 0, {}

_G.pcall = function(f, ...)
  depth = depth + 1
  local a, b, c, d = realpcall(f, ...)
  depth = depth - 1
  return a, b, c, d
end

-- the fake Mudlet API and the dump loader live in test_dump_layout.lua; drive that rather than
-- keeping a second copy of ~60 stubs in sync with it.
_G.dofile = function(path)
  realdofile(path)
  if path:find("core%.lua") and elro and elro.bg_tick then
    elro.bg_inside = function() return true end      -- see the note above
    local real = elro.bg_tick
    elro.bg_tick = function(site)
      if depth > 0 and not elro._noYield then bad[tostring(site)] = (bad[tostring(site)] or 0) + 1 end
      return real(site)
    end
  end
end

local quiet = { write = function() end, close = function() end }
for _, dump in ipairs(dumps) do
  local before = 0 ; for _ in pairs(bad) do before = before + 1 end
  local prevArg, prevOut = arg, io.write
  arg = { dump, "-" }
  io.write = function() end                          -- the layout census is noise here
  local ok, err = realpcall(assert(loadfile("analysis/test_dump_layout.lua")))
  arg, io.write = prevArg, prevOut
  local after = 0 ; for _ in pairs(bad) do after = after + 1 end
  if not ok then
    print(string.format("  ERROR  %s -- %s", dump, tostring(err)))
    bad["<error:" .. dump .. ">"] = 1
  elseif after > before then
    print(string.format("  FAIL   %s -- %d new site(s) reached under a pcall", dump, after - before))
  else
    print(string.format("  ok     %s", dump))
  end
end

local n = 0
for site, hits in pairs(bad) do
  n = n + 1
  print(string.format("    VIOLATION  bg_tick(%q) x%d under a pcall with no elro._noYield window",
    site, hits))
end
print("")
if n == 0 then
  print("PASS -- no elro.bg_tick is reachable under a pcall without a no-yield window.")
else
  print(n .. " VIOLATION(S) -- background relayout WILL die in game (stock Lua 5.1).")
end
os.exit(n == 0 and 0 or 1)
