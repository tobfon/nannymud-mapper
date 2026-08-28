"""Turn `knob_leave1.sh`'s per-area report into a per-KNOB verdict.

    analysis/knob_leave1.sh > analysis/leave1.txt
    python3 analysis/knob_verdict.py analysis/leave1.txt

WHY: leave1 answers "what moved on this area", and the decision is per KNOB across the whole corpus.
Reading 14 area blocks and holding 82 flags in your head is how a contested flag gets folded by
accident.

⛔ WHAT THIS CAN AND CANNOT DECIDE. Folding a DEFAULT-ON flag is identity-preserving whatever the
numbers say -- the default branch is what survives. So the question here is never "will this break",
it is "am I deleting a lever I would want back". Five verdicts follow from that:

  INERT      no area moved a single room -> the flag buys nothing today -> fold, nothing is lost.
             ⚠ NOT the same as "the code is dead", and ⚠⚠ NOT the same as "no area exercises it":
             `topoPlane` and `topoOuterSeed` read INERT over the 13-area regression corpus and cost
             `lie 0 -> 2` / `cross 2 -> 6` on gurk, which their own entries name as the only witness.
             A missing witness is indistinguishable from an inert flag. That is why the area list in
             `knob_leave1.sh` is wider than the regression corpus -- check a knob's entry for a named
             area before believing INERT.
  PROVEN     flipping it is worse on some area and better on none -> fold, behaviour kept.
  tie-only   rooms move; defects, shear, len and hole all identical. The flag reshuffles coordinates
             without changing any measured quality.
  TRADE      flipping improves ONE axis and worsens the other. See `key()`: this is the shape of
             every "accept a crossing to stay compact" rule, and it is not a verdict, it is a
             question for a person.
  CONTESTED  flipping is better on BOTH axes on some area -> the question is still open -> KEEP.

⛔⛔ THE CENSUS CANNOT SEE RING UNIFORMITY, AND THAT IS NOT FIXABLE BY CAPTURING ANOTHER NUMBER.
`len`/`hole` were a fixable gap (see `key()`); this one is not, because uniformity is not in the
census at all. Measured 2026-08-21: `dragTightFree=true` on dagoth reads `len 181->179, hole 12->6`
with no defect change -- a clean win by every number this script has -- and the user rejected it:
*"not a clear win on dagoth because it makes the big ring not uniform"*. Same for `ringNoRider` on
nib: *"end result on nib is census positive, but the route there is bad and the layout is
subjectively worse, again due to failing to keep rings uniform"*. Two of six open questions turned
on it. ⇒ For the ring/dilation family this table is ADVISORY ONLY -- it can say a flag still moves
something, it cannot say the move is good. Ask a person who has looked at the map.

SEVERITY, and it is the project's, not this script's ([[project_defect_severity]], user 2026-07-25):
untruthful exit ~= room collision  >  room-on-edge ~= edge-on-room  >  edge crossing. Shear is
NEITHER a defect nor a lie, so it is scored with len/hole rather than with the defects.
"""
import os
import re
import sys
from collections import defaultdict

CENSUS = re.compile(r"collide=(\d+) lie=(\d+) cross=(\d+) room-on-edge=(\d+) skew-diag=(\d+)")
SIZE = re.compile(r"len=(\d+) hole=(\d+)")


def key(text):
    """(defects, size) -- TWO axes, deliberately not collapsed into one number.

    ⛔⛔ THE FIRST VERSION RANKED ON DEFECTS ALONE AND THAT INVERTED A WHOLE CLASS OF KNOB.
    `crossCostBox`, `attachLicensed` and `guardLicensed` exist to ACCEPT a crossing so the map does
    not grow a super-long edge (the user, 2026-08-21: *"they are THERE to force crossings to make the
    map understandable and not have super long edges"*). On soulfly, `crossCostBox=false` scores
    `cross 8 -> 7` -- an improvement on a defects-only key -- while paying `len 335 -> 361`,
    `hole 43 -> 146`, `box 57x26 -> 33x51`. A defects-only tool recommends deleting exactly the rule
    whose purpose it cannot see, and it did.
    ⇒ a flip that improves one axis and worsens the other is a TRADE, not a verdict. Report it as
    one and let a person price it; this script has no business inventing the exchange rate.
    """
    m, z = CENSUS.search(text), SIZE.search(text)
    if not m:
        return None
    collide, lie, cross, roe, skew = (int(g) for g in m.groups())
    # severity per [[project_defect_severity]]; shear is NEITHER a defect nor a lie, so it sits with
    # the size terms rather than with the defects
    return ((collide + lie, roe, cross), (skew,) + (tuple(int(g) for g in z.groups()) if z else ()))


def all_specs(path="analysis/cov_specs.txt"):
    """Every knob the sweep FLIPPED, not just the ones that moved something.

    ⛔ leave1 prints only movers, so a knob that changed nothing anywhere appears NOWHERE in its
    output -- and the first version of this script therefore reported INERT (0) while 38 of the 82
    flips were exactly that. The absent ones are the whole point of the exercise: reading "44 knobs
    reported" as "44 knobs exist" silently drops the largest bucket.
    """
    out = set()
    try:
        for ln in open(path, encoding="utf-8"):
            if ln.startswith("#") or ln.startswith("base"):
                continue
            spec = ln.strip().split("\t")[-1]
            if "=" in spec:
                out.add(spec.split("=")[0])
    except OSError:
        pass
    return out


# ⛔ AREAS THAT ARE STRESS CASES, NOT QUALITY BENCHMARKS -- swept, but not allowed to cast a verdict.
# `garric` lays out 79 rooms with 115 untruthful exits and 121 crossings. On a layout that broken
# almost any perturbation improves SOMETHING, so "better on garric" carries no information -- and it
# was the sole better-flipped witness for `closeSqAtClose`, `closeSquarify` and `ringDummyArc`, and a
# co-witness for six more. Counting it turned 6 of 24 CONTESTED verdicts, i.e. six flags kept alive
# by noise. User, 2026-08-21: *"garric is odd though, let's not draw too much conclusions from that.
# It's a funny example but it'll never be rendered perfectly."*
# ⚠ IT STAYS IN `knob_leave1.sh`. Sweeping it is still worth the time -- it exercises paths nothing
# else reaches and a crash there is a real finding. What it may not do is decide whether a rule is
# good. Stable (`f4bb490` made it process-stable) is not the same as meaningful.
# Set NOVERDICT="" to count every area.
NOVERDICT = set((os.getenv("NOVERDICT", "garric") or "").split())


def main(path):
    base, per = None, defaultdict(list)     # knob -> [(area, rooms, cmp)]
    areas, aborted, muted = [], [], []
    for ln in open(path, encoding="utf-8"):
        ln = ln.rstrip("\n")
        m = re.match(r"^== (\S+)\s+base: (.*)$", ln)
        if m:
            area, base = m.group(1), key(m.group(2))
            areas.append(area)
            continue
        if "ABORTED" in ln:
            aborted.append(areas[-1] if areas else "?")
            continue
        m = re.match(r"^\s+(\S+?)=(\S+)\s+(\d+) rooms\s+(.*)$", ln)
        if not m:
            continue
        knob, rooms, tail = m.group(1), int(m.group(3)), m.group(4)
        k = base if tail.startswith("SAME") else key(tail)
        if k is None or base is None:
            verdict = "?"
        else:
            dd = (k[0] > base[0]) - (k[0] < base[0])   # defects: +1 flip is worse
            dz = (k[1] > base[1]) - (k[1] < base[1])   # size/shear: +1 flip is worse
            # ⛔ THE TOP TIER IS NOT TRADEABLE. An untruthful exit is "perhaps even worse than a room
            # collision" ([[project_defect_severity]]) -- the map LIES about how to travel -- so no
            # amount of compactness buys one. Without this, `dragPartDiag` (edoras, `lie 2 -> 4` for
            # `len -1 hole -3`) and `topoPlane` (gurk, `lie 0 -> 2`) land in TRADE and go back on a
            # person's queue, when the severity order already refuses them outright -- which is what
            # dragPartDiag's own comment at its use site says in so many words.
            # ⚠ Everything BELOW the top tier stays tradeable, deliberately: `crossCostBox`,
            # `attachLicensed` and `guardLicensed` exist to accept a CROSSING to stay compact, and
            # that trade is the user's stated policy.
            dtop = (k[0][0] > base[0][0]) - (k[0][0] < base[0][0])
            if dtop != 0:
                verdict = "worse" if dtop > 0 else "BETTER"
            elif dd == 0 and dz == 0:
                verdict = "tie"
            elif dd >= 0 and dz >= 0:
                verdict = "worse"
            elif dd <= 0 and dz <= 0:
                verdict = "BETTER"
            else:
                verdict = "TRADE"
        if areas[-1] in NOVERDICT:
            # recorded, shown, but never allowed to make something CONTESTED
            if verdict in ("BETTER", "TRADE"):
                verdict = verdict.lower() + "(muted)"
                muted.append((knob, areas[-1]))
        per[knob].append((areas[-1], rooms, verdict, tail))

    if muted:
        print("⚠ MUTED (stress area, verdict not counted): %s\n"
              % " ".join(sorted({"%s@%s" % m for m in muted})))
    if aborted:
        print("⛔ ABORTED AREAS -- NOT MEASURED: %s\n" % " ".join(aborted))

    for knob in all_specs():
        per.setdefault(knob, [])            # never appeared == moved nothing anywhere
    rows = []
    for knob, hits in per.items():
        moved = [h for h in hits if h[1]]
        better = [h for h in moved if h[2] == "BETTER"]
        trade = [h for h in moved if h[2] == "TRADE"]
        worse = [h for h in moved if h[2] == "worse"]
        if not moved:
            v = "INERT"
        elif better:
            v = "CONTESTED"          # flipping is better on BOTH axes somewhere -> keep the flag
        elif trade:
            v = "TRADE"              # buys one axis with the other -> a person prices this
        elif worse:
            v = "PROVEN"             # flipping is worse where it moves anything -> fold
        else:
            v = "tie-only"           # rooms move, defects AND size identical
        rows.append((v, knob, moved, better, worse))

    ORDER = {"CONTESTED": 0, "TRADE": 1, "tie-only": 2, "PROVEN": 3, "INERT": 4}
    rows.sort(key=lambda r: (ORDER[r[0]], -len(r[2]), r[1]))
    seen = set(per)
    for v in ("CONTESTED", "TRADE", "tie-only", "PROVEN", "INERT"):
        group = [r for r in rows if r[0] == v]
        print("\n===== %s (%d)" % (v, len(group)))
        for _, knob, moved, better, worse in group:
            if v == "INERT":
                print("  %s" % knob)
                continue
            print("  %-22s %d area(s), %d rooms" % (knob, len(moved), sum(h[1] for h in moved)))
            for area, rooms, verdict, tail in sorted(moved, key=lambda h: -h[1]):
                mark = {"BETTER": "  <-- BETTER flipped", "TRADE": "  <-- TRADE"}.get(verdict, "")
                print("      %-13s %5d  %-8s %s%s"
                      % (area, rooms, verdict, tail.replace("census ", ""), mark))
    print("\n%d knob(s) reported over %d area(s)." % (len(seen), len(areas)))


if __name__ == "__main__":
    # ⚠ Windows stdout defaults to cp1252 and this file prints ⚠/⛔; without this a redirect dies with
    # UnicodeEncodeError while a bare terminal run succeeds -- i.e. it breaks exactly when scripted.
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    main(sys.argv[1] if len(sys.argv) > 1 else "analysis/leave1.txt")
