-- REVERSE OF `knob_audit.lua` / `cover_specs.lua`: those scan REGISTRY -> code and ask whether a
-- registered knob's documented default matches its read site. Nobody scanned COMMENT -> code, and
-- that is the direction the damage runs in: a knob NAMED in prose with no read site anywhere makes
-- every past and future A/B of it VACUOUS. `elro.seamRank GOVERNS BOTH HALVES OF THE SEAM` carries
-- three stars and nothing reads it.
--
--   luajit analysis/knob_prose.lua            (from area/map_helper/client)
--   luajit analysis/knob_prose.lua -v         (also print the first prose line for each)
--
-- METHOD, and it is the same machinery as the other two: split each file into CODE (comments and
-- string literals blanked) and PROSE (the comment tails). A name is "prose-only" when it appears as
-- `elro.NAME` in PROSE and NEVER in CODE. Then subtract the classes that are not findings:
--   * documented as retired/removed/gone on the same line or the two above it,
--   * moved into `TUNE` (the field still exists, under a different table),
--   * a case-variant of a name that IS read (`topoCross` vs `topo_cross`),
--   * a knob that is only ASSIGNED, never read (still a finding, but a different one).
-- ⚠ WHAT IS LEFT IS THE A/B INSTRUCTION SET. Each one is a documented switch that cannot be flipped.
local VERBOSE = (arg[1] == "-v")

local function read(p) local f = assert(io.open(p)) local s = f:read("*a") f:close() return s end
local FILES = {}
for _, m in ipairs(dofile("lua/modules.lua")) do FILES[#FILES + 1] = "lua/" .. m end

local code, prose, proseLine = {}, {}, {}
for _, path in ipairs(FILES) do
  local ln = 0
  for line in (read(path) .. "\n"):gmatch("([^\n]*)\n") do
    ln = ln + 1
    local i = line:find("%-%-")
    local c = (i and line:sub(1, i - 1) or line):gsub('"[^"\n]*"', '""')
    local p = i and line:sub(i) or ""
    for n in c:gmatch("elro%.([%w_]+)") do code[n] = (code[n] or 0) + 1 end
    for n in p:gmatch("elro%.([%w_]+)") do
      prose[n] = (prose[n] or 0) + 1
      if not proseLine[n] then proseLine[n] = ("%s:%d %s"):format(path:match("([^/]+)$"), ln, line:match("^%s*(.-)%s*$")) end
    end
  end
end

-- the two tables a surviving name may have moved into
local allsrc = ""
for _, path in ipairs(FILES) do allsrc = allsrc .. read(path) end
local function inTUNE(n) return allsrc:find("TUNE%.\n?%s*" .. n .. "%s*=") or allsrc:find("TUNE%." .. n .. "%f[^%w_]") end
local function caseVariant(n)
  -- topoCross <-> topo_cross, wireCross <-> wire_cross
  local snake = n:gsub("(%l)(%u)", "%1_%2"):lower()
  if snake ~= n and code[snake] then return snake end
  local camel = n:gsub("_(%l)", function(c) return c:upper() end)
  if camel ~= n and code[camel] then return camel end
end
-- retired? look for a disposal verb near the name in prose.
-- ⛔⛔ THE WINDOW WAS "THIS LINE AND THE TWO ABOVE", WHICH IS FAR TOO NARROW FOR THIS CODEBASE.
-- The comment blocks here run 10-40 lines and the disposal verdict is usually written at the TOP of
-- the block, or in a trailing note BELOW the name -- so `closeRigidSkip`, `enclVoidProof`,
-- `enclVoidCheck`, `diagEq` and friends each carry an explicit "RETIRED 2026-08-21" and were still
-- reported as live switches. Scan the whole CONTIGUOUS COMMENT BLOCK the mention sits in: that is
-- the unit the prose is written in, and it is what a human reads to decide.
local RETIRED = { "retired", "removed", "deleted", "gone", "no longer", "went with", "gone with",
                  "gone %-%-", "gone,", "folded", "gone;", "stripped", "used to", "delet",
                  "flag gone", "flags gone", "knob gone", "went in", "knob review", "retirement" }
local function isComment(line) return line:match("^%s*%-%-") ~= nil end
local function lines_of(path)
  local buf = {}
  for line in (read(path) .. "\n"):gmatch("([^\n]*)\n") do buf[#buf + 1] = line end
  return buf
end
local function retiredWord(n)
  for _, path in ipairs(FILES) do
    local buf = lines_of(path)
    for ln = 1, #buf do
      if buf[ln]:find("elro%." .. n .. "%f[^%w_]") then
        local a, b = ln, ln
        while a > 1 and isComment(buf[a - 1]) do a = a - 1 end
        while b < #buf and isComment(buf[b + 1]) do b = b + 1 end
        -- ⭐ ...AND ONE LINE PAST THE RUN WHEN IT CARRIES A TRAILING COMMENT. This file pins a
        -- verdict on the first CODE line after the block -- `local triggered = false  -- ⛔ PART B
        -- RETIRED 2026-08-21` is exactly that -- and a pure comment-run walk stops just short of it.
        if b < #buf and buf[b + 1]:find("%-%-") then b = b + 1 end
        local ctx = table.concat(buf, " ", a, b):lower()
        for _, w in ipairs(RETIRED) do if ctx:find(w) then return true end end
      end
    end
  end
end
-- ⭐⭐⭐ ...AND "PROSE-ONLY" IS NOT THE SAME CLAIM AS "DOCUMENTED AS A SWITCH".
-- `elro.branch_walk`, `elro.pack_branches`, `elro.compose_adj`, `elro.layout_defects` are
-- FUNCTIONS named in prose, and `elro.foo` is the metasyntactic placeholder in core.lua's own
-- explanation of the knob convention ("every knob is read as `elro.foo or <default>`"). None of
-- them is a switch that cannot be flipped -- which is the ONLY thing this tool exists to find --
-- so reporting them inflates the count and buries the real ones. A name is a SWITCH CLAIM only if
-- some prose mention says so: an assignment/comparison form, a stated default, or the words
-- knob / flag / switch / turns-off / restores.
local SWITCHY = { "NAME%s*=", "NAME%s*==%s*false", "NAME%s*~=%s*false",
                  "default on", "default off", "default %*%*", "knob", "flag", "switch",
                  "turns it off", "turns off", "restores", "re%-arms", "enables", "disables",
                  "opt%-in", "set it" }
local function switchClaim(n)
  for _, path in ipairs(FILES) do
    local buf = lines_of(path)
    for ln = 1, #buf do
      local i = buf[ln]:find("%-%-")
      local tail = i and buf[ln]:sub(i) or ""
      if tail:find("elro%." .. n .. "%f[^%w_]") then
        -- the SENTENCE, not the block: one block often discusses several knobs and names only
        -- one of them as settable. The mention's own line plus the next (a claim often wraps).
        local ctx = (buf[ln] .. " " .. (buf[ln + 1] or "")):lower()
        for _, w in ipairs(SWITCHY) do
          if ctx:find((w:gsub("NAME", n:lower()))) then return true end
        end
      end
    end
  end
end

-- ⚠ `elro.foo` IS THE CONVENTION'S OWN PLACEHOLDER, not a knob: core.lua explains the engine's
-- read protocol with it ("every knob is read as `elro.foo or <default>` or `elro.foo ~= false`"),
-- which is switch-shaped by construction and can never have a read site. Excluded by name; if a
-- second metasyntactic name is ever introduced, add it here rather than widening a heuristic.
local PLACEHOLDER = { foo = true }
local names = {}
for n in pairs(prose) do if not code[n] and not PLACEHOLDER[n] then names[#names + 1] = n end end
table.sort(names)

local groups = { RETIRED = {}, TUNE = {}, CASE = {}, LIVE = {}, REF = {} }
for _, n in ipairs(names) do
  local cv = caseVariant(n)
  if inTUNE(n) then groups.TUNE[#groups.TUNE + 1] = n
  elseif cv then groups.CASE[#groups.CASE + 1] = n .. " -> elro." .. cv
  elseif retiredWord(n) then groups.RETIRED[#groups.RETIRED + 1] = n
  elseif not switchClaim(n) then groups.REF[#groups.REF + 1] = n
  else groups.LIVE[#groups.LIVE + 1] = n end
end

local TITLE = {
  RETIRED = "documented as retired/removed -- prose is a HISTORY note, fine",
  TUNE    = "moved into TUNE; the prose still says `elro.` -- stale text, live field",
  CASE    = "case-variant of a name that IS read -- typo in the prose",
  REF     = "named in prose, never CLAIMED settable (function/field/placeholder) -- fine",
  LIVE    = "*** PROSE-ONLY: DOCUMENTED AS A SETTABLE SWITCH, NO read site anywhere ***",
}
for _, g in ipairs { "LIVE", "REF", "TUNE", "CASE", "RETIRED" } do
  print(("\n== %s (%d) -- %s"):format(g, #groups[g], TITLE[g]))
  for _, n in ipairs(groups[g]) do
    print(("  %-24s prose x%d"):format(n, prose[n:match("^[%w_]+")] or 0))
    if VERBOSE and g == "LIVE" then print("      " .. (proseLine[n] or "")) end
  end
end
print(("\n%d names appear as elro.X in prose only; %d of them are documented SETTABLE switches nothing reads.")
  :format(#names, #groups.LIVE))
if #groups.LIVE > 0 then
  print("Each LIVE entry is an A/B instruction that cannot be carried out: either wire the knob,")
  print("or rewrite the prose to name the FACT -- the 45 phantoms of 5713085 were fixed that way.")
end
