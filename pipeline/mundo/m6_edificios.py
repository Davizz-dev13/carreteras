"""Mundo abierto · paso 6: edificios de OSM (huella real) por tesela, para levantarlos en el juego como prismas.
Altura: height= si lo hay; si no building:levels × 3 m + 1; si no, por tipo (APROXIMACIÓN: casa/adosado 6,5 m,
pisos 15 m, nave/industrial 8 m, resto 7 m). Huellas simplificadas a 0,6 m; fuera las de < 12 m².
Formato por tesela (gzip): "EDIF" u32 n; por edificio: u16 altura dm, u16 nvert, nvert × (u16 x, u16 z) locales (2000 m / 65535).
Uso: python m6_edificios.py madrid.osm.pbf salida_dir"""
import os, sys, json, gzip, struct, time, collections
import numpy as np, osmium, shapely, shapely.wkb
from pyproj import Transformer
pbf, out = sys.argv[1], sys.argv[2]
M = json.load(open(os.path.join(out, "mundo.json")))
E0, N0 = M["origen_utm"]; TES = M["tesela"]; PAQ = M["paquete"]
T = Transformer.from_crs(4326, 25830, always_xy=True)
# solo las teselas que existen (las de los paquetes de terreno): con la franja exterior el .pbf trae edificios más allá
teselas = set()
for nombre in M["paquetes"].values():
    b = open(os.path.join(out, nombre), "rb").read()
    for i in range(struct.unpack_from("<I", b, 4)[0]):
        teselas.add(struct.unpack_from("<ii", b, 8 + i * 16))
t00 = time.time()
def log(*a): print(f"[{time.time()-t00:6.0f} s]", *a, flush=True)
TIPO = {"house": 65, "detached": 65, "semidetached_house": 65, "terrace": 70, "residential": 120, "apartments": 150,
        "industrial": 80, "warehouse": 80, "retail": 70, "commercial": 100, "garage": 30, "garages": 30, "shed": 30,
        "roof": 40, "church": 140, "school": 90, "hangar": 100, "farm_auxiliary": 50, "barn": 60, "office": 150}
fab = osmium.geom.WKBFactory()
porteselas = collections.defaultdict(list)
n = 0; desc = 0; fuera = 0
for a in osmium.FileProcessor(pbf).with_areas().with_filter(osmium.filter.KeyFilter("building")):
    if not a.is_area(): continue
    t = dict(a.tags)
    b = t.get("building", "no")
    if b == "no": continue
    try:
        g = shapely.wkb.loads(fab.create_multipolygon(a), hex=True)
    except Exception:
        desc += 1; continue
    h = None
    try:
        if "height" in t: h = float(t["height"].replace("m", "").replace(",", ".").strip())
    except Exception: h = None
    if h is None:
        try:
            if "building:levels" in t: h = float(t["building:levels"].split(";")[0].replace(",", ".")) * 3.0 + 1.0
        except Exception: h = None
    if h is None: h = TIPO.get(b, 70) / 10.0
    h = float(min(max(h, 2.5), 250.0))
    for p in getattr(g, "geoms", [g]):
        ext = np.array(p.exterior.coords)
        x, y = T.transform(ext[:, 0], ext[:, 1])
        X = np.asarray(x) - E0; Z = N0 - np.asarray(y)
        poly = shapely.Polygon(np.column_stack([X, Z])).simplify(0.6)
        if poly.is_empty or poly.area < 12 or poly.geom_type != "Polygon": continue
        c = poly.exterior.coords
        pts = np.array(c)[:-1]
        if len(pts) < 3 or len(pts) > 200: continue
        cx, cz = pts.mean(axis=0)
        ti, tj = int(np.floor(cx / TES)), int(np.floor(cz / TES))
        if (ti, tj) not in teselas: fuera += 1; continue
        porteselas[(ti, tj)].append((h, pts))
        n += 1
    if n and n % 200000 == 0: log(f"{n} edificios")
log(f"{n} edificios en {len(porteselas)} teselas ({desc} descartados, {fuera} fuera de las teselas)")
paqs = collections.defaultdict(list)
for (ti, tj), lista in porteselas.items():
    x0, z0 = ti * TES, tj * TES
    buf = bytearray(struct.pack("<4sI", b"EDIF", len(lista)))
    for h, pts in lista:
        q = np.clip(np.round((pts - [x0, z0]) / TES * 65535), 0, 65535).astype("<u2")
        # el centroide está dentro de la tesela pero los vértices pueden salirse un poco: se recortan al borde (APROX.)
        buf += struct.pack("<HH", int(round(h * 10)), len(pts)) + q.tobytes()
    paqs[(ti // PAQ, tj // PAQ)].append(((ti, tj), gzip.compress(bytes(buf), 6)))
edi = {}; total = 0
for (pi, pj), blobs in paqs.items():
    cab = struct.pack("<4sI", b"PAQE", len(blobs)); pos = len(cab) + len(blobs) * 16; dirx = b""; datos = b""
    for (ti, tj), b in sorted(blobs):
        dirx += struct.pack("<iiII", ti, tj, pos + len(datos), len(b)); datos += b
    nombre = f"edi_{pi}_{pj}.bin"
    open(os.path.join(out, nombre), "wb").write(cab + dirx + datos)
    edi[f"{pi},{pj}"] = nombre; total += len(cab) + len(dirx) + len(datos)
M2 = json.load(open(os.path.join(out, "mundo.json")))
M2["edificios"] = {"paquetes": edi, "fuente": "Huellas de edificios de OpenStreetMap (ODbL). Altura: height / building:levels de OSM; si no hay, APROXIMACIÓN por tipo de edificio."}
json.dump(M2, open(os.path.join(out, "mundo.json"), "w"), ensure_ascii=False, indent=1)
mx = max(os.path.getsize(os.path.join(out, f)) for f in edi.values())
log(f"LISTO: {n} edificios, {total/1e6:.1f} MB en {len(edi)} paquetes (mayor {mx/1e6:.2f} MB)")
