"""Delete top-level function definitions from a lua file, with their leading comment block.

    python delfn.py lua/layout.lua elro.compose_adj "local function ns_rank" ...

A target is matched as a line that STARTS with `function <name>(` or is exactly the given
`local function <name>` prefix. The body runs to the first line that is exactly `end` (top-level
definitions are unindented, so this is unambiguous). The leading comment block is the run of
lines immediately above that start with `--`, plus any blank line separating it.

Refuses to run if a target is not found or is found more than once -- silence is how a sweep
deletes the wrong thing.
"""
import io, sys

path, targets = sys.argv[1], sys.argv[2:]
L = io.open(path, encoding='utf-8').read().split('\n')

def find(name):
    hits = []
    for i, ln in enumerate(L):
        if ln.startswith(name + '(') or ln.startswith(name + ' ') or ln == name:
            hits.append(i)
    return hits

cuts = []
for t in targets:
    hits = find(t)
    if len(hits) != 1:
        raise SystemExit("REFUSING: %r matched %d definition line(s)" % (t, len(hits)))
    start = hits[0]
    # body: to the first bare `end`
    stop = next(j for j in range(start + 1, len(L)) if L[j] == 'end')
    # swallow the leading comment block
    while start > 0 and L[start - 1].lstrip().startswith('--'):
        start -= 1
    while start > 0 and L[start - 1].strip() == '':
        start -= 1
    cuts.append((start, stop + 1, t))

# delete back to front so earlier indices stay valid
for start, stop, t in sorted(cuts, reverse=True):
    sys.stderr.write("  - %-34s lines %d..%d (%d)\n" % (t, start + 1, stop, stop - start))
    del L[start:stop]

io.open(path, 'w', encoding='utf-8').write('\n'.join(L))
print("deleted %d definition(s)" % len(cuts))
