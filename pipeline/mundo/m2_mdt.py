"""Mundo abierto · paso 2: descarga del MDT del IGN (WCS servicios.idee.es), en caché.
 · MDT25 (malla 25 m) de toda la caja de la red + margen, en bloques de 20 km → relieve de las teselas y del horizonte.
 · MDT05 (malla 5 m, LiDAR PNOA) solo de los bloques de 5 km por los que pasa alguna carretera → altura de la calzada."""
import os, sys, math, pickle, time, requests, concurrent.futures as cf
from pyproj import Transformer
U = "https://servicios.idee.es/wcs-inspire/mdt"
CACHE = sys.argv[2]
os.makedirs(CACHE, exist_ok=True)
def bajar(cov, x, y, b):
    f = os.path.join(CACHE, f"{cov}_{x}_{y}.tif")
    if os.path.exists(f) and os.path.getsize(f) > 1000:
        return f, 0
    err = ""
    for i in range(4):
        try:
            r = requests.get(U, params={"SERVICE": "WCS", "VERSION": "2.0.1", "REQUEST": "GetCoverage", "COVERAGEID": cov,
                "FORMAT": "image/tiff", "SUBSET": [f"x({x},{x + b})", f"y({y},{y + b})"]}, timeout=180,
                headers={"User-Agent": "carreteras-espana/0.1"})
            if r.status_code == 200 and r.content[:2] in (b"II", b"MM"):
                open(f + ".tmp", "wb").write(r.content); os.replace(f + ".tmp", f)
                return f, len(r.content)
            err = f"HTTP {r.status_code} {r.content[:100]!r}"
        except Exception as ex:
            err = str(ex)
        time.sleep(3 + 5 * i)
    return None, err
d = pickle.load(open(sys.argv[1], "rb"))
T = Transformer.from_crs(4326, 25830, always_xy=True)
xy = [T.transform(*v) for v in d["coord"].values()]
xs = [p[0] for p in xy]; ys = [p[1] for p in xy]
M = 8000
B25 = 20000
x0 = math.floor((min(xs) - M) / B25) * B25; x1 = math.ceil((max(xs) + M) / B25) * B25
y0 = math.floor((min(ys) - M) / B25) * B25; y1 = math.ceil((max(ys) + M) / B25) * B25
trabajos = [("Elevacion25830_25", x, y, B25) for x in range(x0, x1, B25) for y in range(y0, y1, B25)]
B5 = 5000
bl = set()
for (x, y) in xy:   # bloques de 5 km con carretera (+ vecinos si está a < 150 m del borde)
    for dx in (-150, 0, 150):
        for dy in (-150, 0, 150):
            bl.add((math.floor((x + dx) / B5) * B5, math.floor((y + dy) / B5) * B5))
trabajos += [("Elevacion25830_5", x, y, B5) for (x, y) in sorted(bl)]
print(f"MDT25: {len(trabajos) - len(bl)} bloques de 20 km · MDT05: {len(bl)} bloques de 5 km", flush=True)
t0 = time.time(); hechos = 0; total = 0; fallos = []
with cf.ThreadPoolExecutor(4) as ex:
    for (f, n), tb in zip(ex.map(lambda t: bajar(*t), trabajos), trabajos):
        hechos += 1
        if f is None: fallos.append((tb, n))
        else: total += n
        if hechos % 20 == 0 or hechos == len(trabajos):
            print(f"{hechos}/{len(trabajos)} · {total/1e6:.0f} MB nuevos · {time.time()-t0:.0f} s · fallos {len(fallos)}", flush=True)
print("FALLOS", fallos[:10])
