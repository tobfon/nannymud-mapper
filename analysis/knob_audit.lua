-- Audit elro.KNOBS: does each knob's registry comment agree with how the code GATES it?
--
--   luajit analysis/knob_audit.lua        (from area/map_helper/client)
--
-- WHY IT EXISTS: `seamEq` shipped with its registry line saying "DEFAULT OFF" while the code read
-- `elro.seamEq ~= false`, i.e. default ON -- and the comment's justification (a titleist regression)
-- had stopped reproducing three commits earlier. A knob whose documented default is wrong is worse
-- than an undocumented one: it is the thing people A/B against.
-- ⇒ THIS TOOL SCANS REGISTRY -> CODE. `analysis/knob_prose.lua` scans the other direction, COMMENT
-- -> CODE, and that is where the damage runs: a knob NAMED in prose with no read site makes every
-- A/B of it vacuous. It found 68 such names on 2026-08-21; 45 were false live switches and were
-- rewritten in the same pass. Run both.
-- ⚠ STRIP COMMENTS FIRST. A knob is mentioned in prose far more often than it is tested, and a
-- naive scan reads every mention as a bare-truthy gate (= "default off") and reports the whole
-- registry as broken. It also has to skip TRACE STRINGS -- `closeTight` is named inside one.
--
-- ⛔ IT CRIED WOLF FOUR TIMES OUT OF 110 (2026-08-21) AND EVERY ONE WAS THE TOOL, NOT THE REGISTRY.
-- All four were the same mistake: assuming a knob is a BOOLEAN whose only off-switch is `false`.
--   * `elro.crossCostTau or CROSS_TAU`  -- a NAMED default. The numeric sniff only knew `or 8`, so a
--     cap read as a bare-truthy gate and "DEFAULT ON" looked stale against it.
--   * `local plz = elro.pistonLazy`     -- a TRI-STATE (false / "always" / "lca" / the quad test),
--     read into a local and branched on four lines later: there is no comparison to classify.
--   * `elro.eq2dProbeCap ~= false` AND `local pc = elro.eq2dProbeCap` -- number-OR-boolean, so the
--     two reads legitimately disagree and MIXED is the right answer, not a finding.
--   * `elro.dragPartDiag ~= true`       -- an INVERTED gate: the guard is ON by default and the knob
--     turns it OFF. `~= true` means default-ON of the guarded rule, the exact opposite of what a
--     `~= false`-only classifier concludes.
-- ⇒ classify the READ SHAPE first (BOOL / NUMERIC / MULTI / INVERTED) and judge only the shape a
-- boolean claim can be wrong about. 110 entries, 80 of them BOOL, and the stale count went 4 -> 0.
--
-- ⛔⛔ AND THE ONE REAL FINDING IS ONE THIS TOOL CANNOT MAKE -- said here so nobody builds it again.
-- `ringDummyArc` opens "⭐ DEFAULT **ON** 2026-08-20 (user's call, for live testing)" and closes,
-- six lines down in the SAME entry, "OFF because the layouts come out worse" -- the rationale from
-- before the user turned it on, left in place by `a814da5`. The code agrees with the opening, so
-- every ON-vs-OFF comparison passes; the entry still misinforms its next reader.
-- A `claims ON *and* OFF` check was written for exactly this and DELETED the same hour: it fired on
-- `ringDilate` and `seamNoTight` and MISSED `ringDummyArc`. Both false positives quote their own
-- history (*"This entry used to read \"DEFAULT OFF ... changes nothing yet\""*, *"IT WAS ONLY
-- THREE-QUARTERS ON UNTIL 2026-08-18 ... default OFF"*) -- which is the registry doing its job --
-- while the real one never writes the word "default" next to its stale OFF at all. Separating a
-- CURRENT claim from a QUOTED past one is a tense problem, not a pattern problem, and 2 wolves for
-- 0 findings is the ratio this header already forbids. ⇒ read the entry when you touch the knob.
local function strip(txt)
  local out = {}
  for line in (txt .. "\n"):gmatch("([^\n]*)\n") do
    local i = line:find("%-%-")
    out[#out + 1] = i and line:sub(1, i - 1) or line
  end
  return table.concat(out, "\n"):gsub('"[^"\n]*"', '""')   -- and blank out string literals
end
local function read(p) local f = assert(io.open(p)) ; local s = f:read("*a") ; f:close() ; return s end
local coreRaw = read("lua/core.lua")
local engine = {}
for _, m in ipairs(dofile("lua/modules.lua")) do
  if m ~= "core.lua" then engine[#engine + 1] = strip(read("lua/" .. m)) end
end
local code = table.concat(engine, "\n") .. "\n" .. strip(coreRaw)
local list = coreRaw:match("elro%.KNOBS%s*=%s*{(.-)\n}")
local bad = 0
for name in list:gmatch('"([%w_]+)"') do
  -- ⚠ THE KNOB'S OWN LINES ONLY. A greedy grab spills into the NEXT entry's comment and reports
  -- its default as this one's -- which made the first version flag `closeRing`, whose neighbour
  -- says "DEFAULT OFF". A tool that cries wolf costs more than the one real finding it makes.
  local from = list:find('"' .. name .. '"', 1, true)
  local nxt = list:find(string.char(10) .. '  "', from + 1, true) or #list
  local cmt = list:sub(from, nxt):lower()
  -- ⚠ AND SKIP NUMERIC KNOBS: "default 8" is not ON or OFF; a boolean verdict on a cap is noise.
  -- The fallback may be a NAME as well as a literal (`elro.crossCostTau or CROSS_TAU`).
  local numeric = code:find("elro%." .. name .. "%s+or%s+[%d%.]")
               or code:find("elro%." .. name .. "%s+or%s+[A-Z][%w_%.]*")
  -- ⛔ AND THE TWO OTHER SHAPES A BOOLEAN VERDICT CANNOT DESCRIBE:
  --   MULTI    read into a local and branched on elsewhere (`local plz = elro.pistonLazy`), or
  --            compared against a string -- the value space is not {true, false}.
  --   INVERTED `~= true`: the guarded rule is ON by default and the knob turns it OFF, so "DEFAULT
  --            ON" is a claim about the RULE and `~= false` is not what to look for.
  local multi    = code:find("=%s*elro%." .. name .. "%f[^%w_]")
  local inverted = code:find("elro%." .. name .. "%s*~=%s*true")
  local claim = (not numeric)
            and ((cmt:find("default%s*%**%s*on") and "ON")
              or (cmt:find("default%s*%**%s*off") and "OFF")) or nil
  local n, on, off = 0, false, false
  for pre in code:gmatch("elro%." .. name .. "%s*([~=]=?%s*%a*)") do
    n = n + 1
    if pre:find("~=%s*false") or pre:find("==%s*false") then on = true else off = true end
  end
  for _ in code:gmatch("elro%." .. name .. "%f[^%w_]") do end
  local total = select(2, code:gsub("elro%." .. name .. "%f[^%w_]", ""))
  if total > n then off = true end          -- a bare `if elro.x then` = default OFF
  local act = (on and not off) and "ON" or ((off and not on) and "OFF" or "MIXED")
  local shape = (numeric and "NUMERIC") or (inverted and "INVERTED")
             or (multi and "MULTI") or "BOOL"
  if total > 0 then
    -- only a plain boolean read can contradict a plain boolean claim
    local stale = (shape == "BOOL") and claim and claim ~= act
    local flag = stale and "  <-- STALE" or ""
    if flag ~= "" then bad = bad + 1 end
    print(string.format("%-20s claims=%-5s code=%-6s shape=%-8s uses=%d%s",
      name, tostring(claim), act, shape, total, flag))
  end
end
print(("\n%d bad label(s)."):format(bad))
print("NUMERIC / MULTI / INVERTED reads are not judged: a boolean claim cannot be wrong about them.")
