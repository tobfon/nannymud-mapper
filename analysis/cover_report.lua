-- COVERAGE REPORT -- turn the `.cov` unions from `cover_knobs.sh` into a dead-code shortlist.
--
--   luajit analysis/cover_report.lua analysis/cov/base.cov              # one configuration
--   luajit analysis/cover_report.lua analysis/cov/*.cov                 # under ANY knob we ship
--   ONLY=layout MINBLOCK=12 luajit analysis/cover_report.lua ...
--
-- Every .cov given is UNIONED, so the second form answers the real question: which lines does no
-- configuration in the sweep ever reach.
--
-- ⭐ THE DENOMINATOR IS EXACT, NOT GUESSED. "Which lines could have run" is not a regex question --
-- `end`, `else`, a bare `)` and a multi-line call's continuation rows carry no line event, and a
-- heuristic that counts them reports a third of the file as dead. Instead we load the real chunk and
-- walk EVERY prototype's bytecode with `jit.util.funcinfo(proto, pc).currentline`, which is the VM's
-- own answer. Child prototypes are reached through the GC constants (`funck(f, -k)`), recursively.
--
-- ⭐⭐ AND THE UNIT IS THE FUNCTION, NOT THE LINE. A ranked list of uncovered LINE RUNS puts a 467-line
-- diagnostic dump at the top and buries the finding that matters, which is a whole function nothing
-- reached. So section A is functions with ZERO covered lines, annotated with **whether their own
-- call sites ran**: a function whose every reference is itself on an uncovered line is the root of a
-- dead subtree, while one called from live code is a branch that simply never took. Section B is
-- what is left -- uncovered runs inside functions that DID run, i.e. untaken branches.
--
-- ⚠ UNCOVERED IS NOT DEAD. This harness runs the OFFLINE layout path only: no Mudlet, no drawing, no
-- aliases, no background coroutine. Anything reachable solely from a typed command is uncovered here
-- and perfectly alive -- `map_helper.xml` is read so those can be marked `[alias]`, but the mark only
-- catches direct bindings, not the file-scope local helpers they call. Judge, do not delete.
local u = require("jit.util")

local FILES, ORDER = {}, {}
for _, m in ipairs(dofile("lua/modules.lua")) do
  if m ~= "geom.lua" and m ~= "keys.lua" then
    local tag = m:gsub("%.lua$", "")
    FILES[tag] = "lua/" .. m ; ORDER[#ORDER + 1] = tag
  end
end
local MINBLOCK = tonumber(os.getenv("MINBLOCK") or "3")
local MINFN = tonumber(os.getenv("MINFN") or "4")
local ONLY = os.getenv("ONLY")

-- ---------------------------------------------------------------- executable lines, per file
-- ⛔⛔ A LINE THE PARENT PROTO ALSO OWNS IS NOT THE CHILD'S. For `local function f() ... end`
-- LuaJIT attributes the enclosing chunk's FNEW -- the closure creation, which runs at LOAD time --
-- to the `end` line, which is inside f's own span. So every cold `local function` in the file came
-- back with exactly one covered line and was dropped from section A: `write_canvas`, whose body
-- never runs offline, was invisible. Subtracting the parent's line set is what makes "no covered
-- line at all" mean the BODY, not the definition.
local function protowalk(p, exec, protos, parentOwn)
  local i = u.funcinfo(p)
  local lines = {}
  for pc = 1, i.bytecodes or 0 do
    local fi = u.funcinfo(p, pc)
    if fi and fi.currentline then exec[fi.currentline] = true ; lines[fi.currentline] = true end
  end
  if parentOwn then for l in pairs(lines) do if parentOwn[l] then lines[l] = nil end end end
  protos[#protos + 1] = { from = i.linedefined, to = i.lastlinedefined, own = lines }
  local k = 0
  while true do
    k = k + 1
    local ok, c = pcall(u.funck, p, -k)
    if not ok or c == nil then break end
    if type(c) == "proto" then protowalk(c, exec, protos, lines) end
  end
end

local SRC, EXEC, PROTOS = {}, {}, {}
for tag, path in pairs(FILES) do
  local fh = assert(io.open(path), "run me from area/map_helper/client")
  local src = fh:read("*a") ; fh:close()
  local lines = {}
  for l in (src .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
  SRC[tag] = lines
  EXEC[tag], PROTOS[tag] = {}, {}
  protowalk(assert(loadstring(src, "@" .. tag)), EXEC[tag], PROTOS[tag])
end

-- ---------------------------------------------------------------- the covered union
local COV = {}
for _, tag in ipairs(ORDER) do COV[tag] = {} end
if #arg == 0 then error("usage: cover_report.lua <cov file> [...]") end
for _, path in ipairs(arg) do
  local fh = assert(io.open(path), "no such .cov: " .. path)
  for line in fh:lines() do
    local tag, n = line:match("^(%a+) (%d+)$")
    if tag and COV[tag] then COV[tag][tonumber(n)] = true end
  end
  fh:close()
end

-- ---------------------------------------------------------------- names and alias bindings
local ALIAS = {}
do
  local fh = io.open("map_helper.xml")
  if fh then
    for name in fh:read("*a"):gmatch("elro%.([%a_][%w_]*)") do ALIAS[name] = true end
    fh:close()
  end
end
-- The definition line tells us the name; there are four shapes in this codebase and all four are
-- load-bearing (`eqw_close_core_1 = function(...)` is a forward-declared local assigned later).
local NAMEPAT = {
  "^%s*function%s+([%w_%.:]+)%s*%(",
  "^%s*local%s+function%s+([%w_]+)%s*%(",
  "^%s*local%s+([%w_]+)%s*=%s*function%s*%(",
  "^%s*([%w_%.]+)%s*=%s*function%s*%(",
}
local function namefor(tag, line)
  local s = SRC[tag][line] or ""
  for _, p in ipairs(NAMEPAT) do
    local n = s:match(p)
    if n then return n end
  end
end

-- ---------------------------------------------------------------- reference sites of a name
-- "Is this function called from anywhere that RUNS?" A textual scan is enough: these are unique
-- identifiers in a single file, and the only alternative (a real call graph through upvalues and
-- table fields) is a much larger tool for a question this answers.
-- ⛔ SCAN BOTH FILES, NOT THE DEFINING ONE. `elro.layout_area` is defined in layout.lua and called
-- only from core.lua:1564, so a same-file scan reported it as having no caller at all -- which is
-- the strongest possible "delete me" signal, on the flood engine that is still the live fallback
-- for maze areas and for anything over `ns_cap`. A cross-file miss here is not a rough edge, it is
-- the tool actively arguing for the wrong deletion.
local REFS = {}
local function refs(tag, name, defline)
  local key = tag .. "\1" .. name
  if REFS[key] then return REFS[key] end
  local short = name:match("([%w_]+)$")
  local live, dead = 0, 0
  local scan = {}
  for _, t in ipairs(ORDER) do scan[#scan + 1] = { tag = t, lines = SRC[t] } end
  for _, s in ipairs(scan) do
  for i, l in ipairs(s.lines) do
    if not (s.tag == tag and i == defline) and l:find(short, 1, true) then
      local code = l:gsub("%-%-.*", "")
      -- ⚠ ALLOW A DOT BEFORE THE NAME. Excluding `.` from the leading class (to avoid matching a
      -- field of the same name) silently zeroed the caller count of every `elro.X` in the file --
      -- `elro.sel_or_area()` reported "0 live / 0 cold", which reads as unreferenced.
      if code:find("[^%w_]" .. short .. "%s*[%(%)%,%}]") or code:find("^%s*" .. short .. "%s*%(") then
        if COV[s.tag][i] then live = live + 1 else dead = dead + 1 end
      end
    end
  end
  end
  REFS[key] = { live = live, dead = dead }
  return REFS[key]
end

-- ---------------------------------------------------------------- report
local function report(tag)
  local exec, cov, src, protos = EXEC[tag], COV[tag], SRC[tag], PROTOS[tag]
  local nExec, nCov = 0, 0
  local miss = {}
  for l = 1, #src do
    if exec[l] then
      nExec = nExec + 1
      if cov[l] then nCov = nCov + 1 else miss[#miss + 1] = l end
    end
  end
  print(("\n================ %s -- %d/%d executable lines covered (%.1f%%), %d uncovered")
    :format(FILES[tag], nCov, nExec, 100 * nCov / math.max(nExec, 1), #miss))

  -- --- section A: functions with ZERO covered lines of their own
  local cold, coldLines = {}, {}
  for _, p in ipairs(protos) do
    if p.from > 0 then
      local own, hit = 0, 0
      for l in pairs(p.own) do own = own + 1 ; if cov[l] then hit = hit + 1 end end
      if own >= MINFN and hit == 0 then
        cold[#cold + 1] = { p = p, own = own, name = namefor(tag, p.from) }
      end
    end
  end
  -- Drop a cold function that is merely nested inside a bigger cold one: reporting the closure and
  -- its four inner helpers as five findings is the same finding, counted five times.
  table.sort(cold, function(a, b) return (a.p.to - a.p.from) > (b.p.to - b.p.from) end)
  local top = {}
  for _, c in ipairs(cold) do
    local inside = false
    for _, t in ipairs(top) do
      if t.p.from <= c.p.from and t.p.to >= c.p.to then inside = true break end
    end
    if not inside then top[#top + 1] = c end
  end
  table.sort(top, function(a, b) return a.own > b.own end)
  print(("\n-- A. FUNCTIONS WITH NO COVERED LINE AT ALL (%d, >= %d executable lines each)")
    :format(#top, MINFN))
  print("   'callers' counts textual reference sites: live = the referring line itself ran.")
  for _, c in ipairs(top) do
    local nm = c.name or ("(anonymous @" .. c.p.from .. ")")
    local r = c.name and refs(tag, nm, c.p.from) or { live = 0, dead = 0 }
    for l in pairs(c.p.own) do coldLines[l] = true end
    print(("  %5d-%-5d %4d  %s%-40s  callers: %d live / %d cold")
      :format(c.p.from, c.p.to, c.own,
              ALIAS[nm:match("([%w_]+)$")] and "[alias] " or "", nm, r.live, r.dead))
  end

  -- --- section B: uncovered runs inside functions that DID run
  local blocks, i = {}, 1
  while i <= #miss do
    local j = i
    while j < #miss do
      local gap = false
      for l = miss[j] + 1, miss[j + 1] - 1 do if exec[l] and cov[l] then gap = true break end end
      if gap then break end
      j = j + 1
    end
    -- a block wholly inside a section-A function is that function, already reported
    local whole = true
    for k = i, j do if not coldLines[miss[k]] then whole = false break end end
    if not whole then blocks[#blocks + 1] = { from = miss[i], to = miss[j], n = j - i + 1 } end
    i = j + 1
  end
  table.sort(blocks, function(a, b) return a.n > b.n end)
  print(("\n-- B. UNTAKEN BRANCHES inside functions that ran (%d run(s), showing >= %d line(s))")
    :format(#blocks, MINBLOCK))
  for _, b in ipairs(blocks) do
    if b.n >= MINBLOCK then
      -- innermost enclosing proto, for the "which function is this in" column
      local best
      for _, p in ipairs(protos) do
        if p.from <= b.from and p.to >= b.to and p.from > 0
           and (not best or (p.to - p.from) < (best.to - best.from)) then best = p end
      end
      local head = (src[b.from] or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if #head > 92 then head = head:sub(1, 89) .. "..." end
      print(("  %5d-%-5d %4d  in %s\n           | %s")
        :format(b.from, b.to, b.n, best and ((best.from) .. " " .. (namefor(tag, best.from) or "?")) or "(chunk)", head))
    end
  end
end

for _, tag in ipairs(ORDER) do
  if not ONLY or ONLY == tag then report(tag) end
end
