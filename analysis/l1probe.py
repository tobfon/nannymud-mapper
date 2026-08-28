# Is a finished layout L1-LOCALLY-OPTIMAL over the equality classes?
# For each axis, weld rooms joined by edges that do NOT move on that axis (they force an equal
# coordinate), then try shifting each class by +-1 and report the change in TOTAL EDGE LENGTH and
# whether any edge stops being truthful. A negative delta with no new lie = slack the descent
# could have moved and did not -> SEARCH failure. None anywhere -> the objective is the problem.
import re,sys,collections
D={'north':(0,1),'south':(0,-1),'east':(1,0),'west':(-1,0),
   'northeast':(1,1),'northwest':(-1,1),'southeast':(1,-1),'southwest':(-1,-1)}
P={};EX=[]
for ln in open(sys.argv[1]):
    m=re.match(r'\s*(\d+) \((-?\d+),(-?\d+),-?\d+\) area=(\S+) \[(.*)\]\s*$',ln)
    if not m: continue
    a=int(m.group(1)); P[a]=[int(m.group(2)),int(m.group(3))]
    for d,t in re.findall(r'([a-z]+)->(\d+)',m.group(5)):
        if d in D: EX.append((a,int(t),D[d]))
E=[(a,b,v) for (a,b,v) in EX if b in P]
def total(pos):
    s=0; seen=set()
    for a,b,v in E:
        k=(min(a,b),max(a,b))
        if k in seen: continue
        seen.add(k)
        s+=max(abs(pos[b][0]-pos[a][0]),abs(pos[b][1]-pos[a][1]))
    return s
def lies(pos):
    n=0; seen=set()
    for a,b,v in E:
        k=(min(a,b),max(a,b))
        if k in seen: continue
        seen.add(k)
        dx,dy=pos[b][0]-pos[a][0],pos[b][1]-pos[a][1]
        if v[0]!=0 and v[1]!=0:
            if dx*v[0]<1 or dy*v[1]<1: n+=1      # diagonal: BOTH components >=1 the right way
        elif v[0]!=0:
            if dy!=0 or dx*v[0]<1: n+=1          # E/W: same row, >=1 the right way
        else:
            if dx!=0 or dy*v[1]<1: n+=1          # N/S: same column, >=1 the right way
    return n
base_t, base_l = total(P), lies(P)
print("total edge length=%d  lies=%d  rooms=%d"%(base_t,base_l,len(P)))
for axis in (0,1):
    par={r:r for r in P}
    def find(x):
        while par[x]!=x: par[x]=par[par[x]]; x=par[x]
        return x
    for a,b,v in E:
        if v[axis]==0:
            ra,rb=find(a),find(b)
            if ra!=rb: par[ra]=rb
    cls=collections.defaultdict(list)
    for r in P: cls[find(r)].append(r)
    wins=[]
    for c,mem in cls.items():
        for s in (-1,1):
            np={r:list(p) for r,p in P.items()}
            for r in mem: np[r][axis]+=s
            d=total(np)-base_t
            if d<0 and lies(np)<=base_l: wins.append((d,axis,c,s,len(mem)))
    wins.sort()
    nm="x" if axis==0 else "y"
    print("  axis %s: %d class(es), %d improving single shift(s)%s"%(nm,len(cls),len(wins),
        ("  best: "+", ".join("%+d by shifting class of %d (%dr) %+d"%(w[0],w[2],w[4],w[3]) for w in wins[:4])) if wins else ""))
