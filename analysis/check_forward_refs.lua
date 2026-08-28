-- Find calls to a `local function` that happen ABOVE its definition.
--
-- ⛔ WHY THIS EXISTS. layout.lua is one 7000-line function holding ~100 nested
-- closures, and Lua resolves an unknown name as a GLOBAL. So calling a local
-- function before its `local function` line is not a syntax error -- it compiles
-- clean, `luajit -bl` reports nothing, and it dies at runtime as
-- "attempt to call global 'X' (a nil value)" only when that path first executes,
-- i.e. on whichever area happens to reach it. It has bitten at least four times:
-- query_class_levers, query_eq_levers, cmpEq, pull_makes_lie.
-- The established fix is a forward declaration (`local X` early, `X = function`
-- later), which this script understands and accepts.
--
--     luajit analysis/check_forward_refs.lua [file ...]
local files = { ... }
if #files == 0 then
  for _, m in ipairs(dofile("lua/modules.lua")) do files[#files + 1] = "lua/" .. m end
end

local bad, scanned = 0, 0
for _, path in ipairs(files) do
  local lines = {}
  for l in io.lines(path) do lines[#lines + 1] = l end
  scanned = scanned + 1

  -- ⚠⚠ SIGNAL-TO-NOISE IS THE WHOLE PROBLEM HERE, and a loose version of this
  -- script reported 20 findings of which ZERO were real. Two sources of garbage,
  -- both fixed below, and do not relax either:
  --   (a) the name inside a STRING -- `"pull %s far="`, `"%d area(s)"`,
  --       `"shift(%d,%d)"` all looked like calls;
  --   (b) short generic names (p, t, cc, at, sig, read, build) that legitimately
  --       exist as separate locals in a dozen unrelated scopes. Without real
  --       scope analysis those can never be judged from line numbers alone.
  -- So this only checks what actually bites: functions declared at the SAME
  -- indent as each other -- i.e. direct children of one big enclosing function,
  -- which is exactly the layout.lua/walk_branches shape where all four real bugs
  -- happened. It is a heuristic, and it is deliberately narrow.
  local MINLEN = 4
  -- ⭐ SCOPE = THE ENCLOSING TOP-LEVEL FUNCTION. Indent alone is not enough:
  -- every `function elro.X` in this file has its own 2-space locals, so an
  -- unrelated `shift` in one and a `shift` in another looked like a forward
  -- reference. Only a call and a definition inside the SAME column-0 function
  -- can possibly be the same local.
  local blockOf, blk = {}, 0
  for i, l in ipairs(lines) do
    if l:match("^function%s") or l:match("^local function%s") then blk = blk + 1 end
    blockOf[i] = blk
  end
  local function strip(l)
    return (l:gsub("%-%-.*$", ""):gsub('"[^"]*"', '""'):gsub("'[^']*'", "''"))
  end
  -- definitions: `local function NAME(`  and forward decls: `local NAME` / `local A, B`
  local defLine, fwdLine, defIndent = {}, {}, {}
  for i, l in ipairs(lines) do
    local ind, n = l:match("^(%s*)local function%s+([%w_]+)%s*%(")
    if n and not defLine[n] then defLine[n] = i ; defIndent[n] = #ind end
    -- a bare `local X` (no `function`, no `=` on the same name list) is a forward decl
    local names = l:match("^%s*local%s+([%w_%s,]+)%s*$")
    if names then
      for n2 in names:gmatch("[%w_]+") do
        if not fwdLine[n2] then fwdLine[n2] = i end
      end
    end
  end

  for name, dl in pairs(defLine) do
    -- earliest call site, ignoring comment lines and the definition itself
    local firstCall
    for i, l in ipairs(lines) do
      -- ⛔⛔ DO NOT FILTER THE CALL LINE BY INDENT. An earlier version required
      -- the call to sit at the DEFINITION's indent, which silently excluded every
      -- real call -- a call lives inside some function body and is therefore
      -- always deeper. The script then reported 0 problems on a file with a known
      -- forward reference: tuned until silent, and useless. Block scope is the
      -- only filter that is both sound and sufficient.
      if #name >= MINLEN and i ~= dl and not l:match("^%s*%-%-")
         and blockOf[i] == blockOf[dl] then
        local body = strip(l)
        -- ⚠ EXCLUDE FIELD CALLS. `elro.count_defects(` is a different function
        -- from a local `count_defects`, and counting it produced a false report.
        -- Same for `:method(`. Only a bare identifier call can hit a local.
        -- ⚠ THE PREFIX CHAR IS REQUIRED, NOT OPTIONAL. With `[^%w_]?` the
        -- pattern matches mid-identifier, so `apply_pull(` read as a call to
        -- `pull` -- which is how this script reported itself as a bug.
        local hit
        for pre in body:gmatch("([^%w_])" .. name .. "%s*%(") do
          if pre ~= "." and pre ~= ":" then hit = true ; break end
        end
        if hit or body:find("^" .. name .. "%s*%(") then firstCall = i ; break end
      end
    end
    if firstCall and firstCall < dl then
      local fwd = fwdLine[name]
      if not (fwd and fwd < firstCall) then
        bad = bad + 1
        print(string.format("%s:%d  calls %s() but `local function %s` is at line %d%s",
          path, firstCall, name, name, dl,
          fwd and ("  (forward decl at " .. fwd .. ", too late)") or "  (no forward declaration)"))
      end
    end
  end
end

print(string.format("\n%d file(s) scanned, %d forward-reference problem(s)", scanned, bad))
os.exit(bad == 0 and 0 or 1)
