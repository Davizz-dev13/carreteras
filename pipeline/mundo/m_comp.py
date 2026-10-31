
import pickle, math, collections, sys
from pyproj import Transformer
T=Transformer.from_crs(4326,25830,always_xy=True)
d=pickle.load(open(sys.argv[1],'rb')); coord=d['coord']; tr=d['tramos']
xy={k:T.transform(*v) for k,v in coord.items()}
par=list(range(len(xy))); idx={k:i for i,k in enumerate(xy)}
def f(a):
    while par[a]!=a: par[a]=par[par[a]]; a=par[a]
    return a
L=0
for t in tr:
    n=t['nodos']; a=f(idx[n[0]]); b=f(idx[n[-1]])
    if a!=b: par[a]=b
comp=collections.defaultdict(float)
for t in tr:
    n=t['nodos']; l=sum(math.dist(xy[n[i]],xy[n[i+1]]) for i in range(len(n)-1)); L+=l
    comp[f(idx[n[0]])]+=l
cs=sorted(comp.values(),reverse=True)
print('total km',round(L/1000),'componentes',len(cs),'mayor km',round(cs[0]/1000),'%',round(100*cs[0]/L,1),'siguientes',[round(c/1000,1) for c in cs[1:10]])
xs=[p[0] for p in xy.values()]; ys=[p[1] for p in xy.values()]
print('bbox',min(xs),max(xs),min(ys),max(ys))
