"""Unwrap `if <cond> then ... end` blocks in a Lua file, keeping the body.

    python unwrap.py lua/layout.lua "if elro.crossRoot ~= false then" ...

⛔ WHY NOT "DELETE THE if AND THE NEXT SAME-INDENT end": that is wrong twice over, and it
corrupted layout.lua once already.
  1. It cannot see an `else` arm. demoteEdges and chordRideBlocks both have one, so the
     else-body got orphaned and the file stopped parsing.
  2. The first same-indent `end` may close an INNER block (a `while` inside the body that
     happens to be indented the same), not the `if`.

So this walks the body counting real Lua block openers/closers, finds the matching `end`,
and REFUSES the site if an `else`/`elseif` belongs to this `if` -- those need a human
decision about which arm survives.
"""
import io, re, sys

CLOSE = re.compile(r'\bend\b')

def count_opens(s):
    """Lua block openers on one stripped line.

    ⚠ `for ... do` and `while ... do` are ONE block, not two -- counting `do` separately
    is what made the first version of this never find a matching `end`. A bare `do` block
    still counts, so only suppress `do` when a for/while owns it on the same line.
    """
    # ⛔ DO NOT "subtract elseif". `\bif\b` does NOT match inside `elseif` -- the preceding `e`
    # is a word char, so there is no boundary -- so subtracting made every `elseif` line count
    # as -1, the depth hit zero early, and the wrong `end` was matched. That corrupted
    # layout.lua a second time. See the self-test at the bottom of this file.
    n = len(re.findall(r'\b(if|for|while|function)\b', s))
    owned = len(re.findall(r'\b(for|while)\b', s))
    n += max(0, len(re.findall(r'\bdo\b', s)) - owned)
    return n

def strip_lua(line):
    """Remove comments and string literals so keywords inside them do not count."""
    line = re.sub(r'--.*', '', line)
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"'(?:[^'\\]|\\.)*'", "''", line)
    return line

def match_end(L, i):
    """Given the index of an `if ... then` line, return (end_index, else_indices)."""
    depth = 0
    elses = []
    for k in range(i, len(L)):
        s = strip_lua(L[k])
        if k == i:
            depth = 1                       # the `if` itself
            # `elseif`/`then ... end` on one line would need more care; refuse those
            if re.search(r'\bend\b', s):
                raise SystemExit("REFUSING single-line if at %d: %s" % (k + 1, L[k].strip()))
            continue
        opens = count_opens(s)
        closes = len(CLOSE.findall(s))
        if depth == 1 and re.match(r'\s*(else|elseif)\b', L[k]):
            elses.append(k)
        depth += opens - closes
        if depth == 0:
            return k, elses
    raise SystemExit("no matching end for line %d" % (i + 1))

path, targets = sys.argv[1], sys.argv[2:]
L = io.open(path, encoding='utf-8').read().split('\n')

for t in targets:
    while True:
        hits = [k for k, l in enumerate(L) if l.strip() == t]
        if not hits:
            break
        i = hits[0]
        j, elses = match_end(L, i)
        if elses:
            raise SystemExit("REFUSING %r at line %d: has else/elseif at %s -- needs a human"
                             % (t, i + 1, [e + 1 for e in elses]))
        ind = len(L[i]) - len(L[i].lstrip())
        body = [(b[2:] if b.startswith(' ' * (ind + 2)) else b) for b in L[i + 1:j]]
        L[i:j + 1] = body
        sys.stderr.write("  unwrapped %-46s lines %d..%d\n" % (t, i + 1, j + 1))

io.open(path, 'w', encoding='utf-8').write('\n'.join(L))
print("done")
