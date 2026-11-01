#!/usr/bin/env python3
"""Quita de los árboles ya generados (paisaje/arboles/*.bin de arboles_worldcover.py) los que caen a menos de semiancho + 6 m
de cualquier calzada de la zona: rutas, glorietas y TODAS las vías (también las que van dentro de carreteras.json, que la
primera versión de arboles_worldcover.py no miraba). El resto de árboles queda igual (mismas posiciones).
Con --osm hace lo mismo con los árboles de OSM (arboles/*.bin, los de la web y Gráficos bajo; mismo formato).
Uso: python arboles_despejar.py juego/datos/<zona> [MARGEN=6] [--osm]"""
import os, sys, json, glob
import numpy as np
from scipy.spatial import cKDTree
OSM = "--osm" in sys.argv
args = [a for a in sys.argv[1:] if a != "--osm"]
d = args[0]
MARGEN = float(args[1]) if len(args) > 1 else 6.0
def _densa(x, z, hw):
    x = np.asarray(x, float); z = np.asarray(z, float); hw = np.broadcast_to(np.asarray(hw, float), x.shape)
    if len(x) < 2: return np.column_stack([x, z]), hw.copy()
    seg = np.hypot(np.diff(x), np.diff(z)); k = np.maximum(1, np.ceil(seg / 2).astype(int))
    t = np.concatenate([i + np.arange(k[i]) / k[i] for i in range(len(x) - 1)] + [[len(x) - 1.0]])
    ii = np.arange(len(x))
    return np.column_stack([np.interp(t, ii, x), np.interp(t, ii, z)]), np.interp(t, ii, hw)
C = json.load(open(os.path.join(d, "carreteras.json")))
pts, hw = [], []
def _anadir(x, z, h):
    p, w = _densa(x, z, h); pts.append(p); hw.append(w)
for r in C["rutas"]:
    _anadir(r["x"], r["z"], np.asarray(r["ancho"], float) / 2)
for g in C.get("glorietas", []):
    _anadir(g["x"], g["z"], float(g["hw"]))
vias = list(C.get("vias", []))
for f in C.get("vias_archivos", []):
    vias += json.load(open(os.path.join(d, f)))["vias"]
for v in vias:
    _anadir(v["x"], v["z"], float(v["ancho"]) / 2)
pts = np.vstack(pts); hw = np.concatenate(hw)
kd = cKDTree(pts)
sal = os.path.join(d, "arboles") if OSM else os.path.join(d, "paisaje", "arboles")
fp = os.path.join(sal, "fuente.json")
fu = {"teselas": {}} if OSM else json.load(open(fp))
antes = despues = 0
for f in sorted(glob.glob(os.path.join(sal, "*.bin"))):
    a = np.fromfile(f, "<f4").reshape(-1, 4)
    if not len(a): continue
    dd, k = kd.query(a[:, [0, 2]], k=8, distance_upper_bound=60)
    marg = np.where(np.isfinite(dd), dd - hw[np.minimum(k, len(hw) - 1)], np.inf).min(axis=1)
    b = a[marg > MARGEN]
    antes += len(a); despues += len(b)
    if len(b) != len(a):
        os.remove(f)                      # nunca escribir encima (puede ser un enlace duro a otra copia)
        b.astype("<f4").tofile(f)
        fu["teselas"][os.path.basename(f)[:-4]] = int(len(b))
if not OSM:
    fu["total"] = int(sum(fu["teselas"].values()))
    os.remove(fp)
    json.dump(fu, open(fp, "w"), ensure_ascii=False, indent=1)
print(f"{d}: {antes} -> {despues} árboles ({antes - despues} quitados)")
