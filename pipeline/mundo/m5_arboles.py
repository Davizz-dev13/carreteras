"""Mundo abierto · paso 5: árboles reales donde OSM tiene bosque (landuse=forest, natural=wood), por tesela.
Posiciones: rejilla de PASO m con desplazamiento aleatorio (semilla fija) dentro de los polígonos de bosque de OSM y a más
de 4 m del borde de cualquier calzada. Especie: conífera si OSM dice leaf_type=needleleaved, frondosa si broadleaved;
si no lo dice, conífera por encima de 1.000 m y frondosa (encina/roble) por debajo (APROXIMACIÓN).
La densidad (un árbol cada PASO² m²) es una APROXIMACIÓN para que se lea como bosque sin hundir los FPS; no es un inventario.
Con salida_anterior y un polígono .poly (lon/lat) las teselas enteras dentro del polígono conservan los árboles de la
salida anterior byte a byte (al añadir la franja exterior no cambia nada dentro de la Comunidad).
Uso: python m5_arboles.py madrid.osm.pbf salida_dir [salida_anterior comunidad.poly]"""
import os, sys, json, gzip, struct, time, collections, math
import numpy as np, osmium, shapely
from shapely.geometry import shape, LineString
from shapely.ops import unary_union
from pyproj import Transformer
PASO = 16.0
pbf, out = sys.argv[1], sys.argv[2]
M = json.load(open(os.path.join(out, "mundo.json")))
E0, N0 = M["origen_utm"]; TES = M["tesela"]; PAQ = M["paquete"]
T = Transformer.from_crs(4326, 25830, always_xy=True)
t00 = time.time()
def log(*a): print(f"[{time.time()-t00:6.0f} s]", *a, flush=True)
# polígonos de bosque en coordenadas del juego
pols = []
fab = osmium.geom.WKBFactory()
import shapely.wkb
for a in osmium.FileProcessor(pbf).with_areas().with_filter(osmium.filter.KeyFilter("landuse", "natural")):
    if not a.is_area(): continue
    t = dict(a.tags)
    if not (t.get("landuse") == "forest" or t.get("natural") == "wood"): continue
    try:
        g = shapely.wkb.loads(fab.create_multipolygon(a), hex=True)
    except Exception:
        continue
    lt = t.get("leaf_type", "")
    g = shapely.ops.transform(lambda x, y, z=None: T.transform(x, y), g)
    g = shapely.affinity.affine_transform(g, [1, 0, 0, -1, -E0, N0])   # X = E - E0, Z = N0 - N
    if not g.is_valid: g = g.buffer(0)
    pols.append((g, 1 if lt == "needleleaved" else (2 if lt == "broadleaved" else 0)))
log(f"{len(pols)} polígonos de bosque, {sum(p[0].area for p in pols)/1e6:.0f} km²")
arbol = shapely.STRtree([p[0] for p in pols])
# calzadas por tesela (para no plantar en la carretera)
red = json.loads(gzip.decompress(open(os.path.join(out, "red.json.gz"), "rb").read()))
partes = [gzip.decompress(open(os.path.join(out, p), "rb").read()) for p in M["partes_red"]]
def geo(k):
    g = red["tramos"][k]["g"]; b = partes[g[0]]; o = g[1]; n = g[2]
    p0 = np.frombuffer(b, "<i4", 3, o).astype(np.int64)
    d = np.frombuffer(b, "<i2", (n - 1) * 3, o + 12).reshape(-1, 3).astype(np.int64)
    return np.vstack([p0, p0 + np.cumsum(d, axis=0)]) * 0.01
# piezas por tesela: del paquete de terreno
def piezas_de(nombre):
    b = open(os.path.join(out, nombre), "rb").read(); n = struct.unpack_from("<I", b, 4)[0]; r = {}
    for i in range(n):
        ti, tj, off, tam = struct.unpack_from("<iiII", b, 8 + i * 16)
        blob = gzip.decompress(b[off:off + tam]); np_ = struct.unpack_from("<I", blob, 22)[0]
        r[(ti, tj)] = (blob, [struct.unpack_from("<iii", blob, 26 + 12 * j) for j in range(np_)])
    return r
VIEJOS = None; dentro_de = None
if len(sys.argv) > 4:
    Mv = json.load(open(os.path.join(sys.argv[3], "mundo.json"))); VIEJOS = {}
    for nombre in Mv.get("arboles", {}).get("paquetes", {}).values():
        b = open(os.path.join(sys.argv[3], nombre), "rb").read(); n = struct.unpack_from("<I", b, 4)[0]
        for i in range(n):
            ti, tj, off, tam = struct.unpack_from("<iiII", b, 8 + i * 16); VIEJOS[(ti, tj)] = b[off:off + tam]
    pts = [tuple(map(float, l.split())) for l in open(sys.argv[4]).read().split("\n")[2:] if len(l.split()) == 2]
    pu = [T.transform(x, y) for x, y in pts]
    dentro_de = shapely.Polygon([(e - E0, N0 - n) for e, n in pu]); shapely.prepare(dentro_de)
    log(f"árboles anteriores: {len(VIEJOS)} teselas")
reusadas = 0; quitados = 0
rng = np.random.default_rng(31102026)
arb = {}; total = 0; tot_bytes = 0
for clave, nombre in sorted(M["paquetes"].items()):
    pi, pj = map(int, clave.split(","))
    blobs = []
    for (ti, tj), (blob, piezas) in sorted(piezas_de(nombre).items()):
        x0, z0 = ti * TES, tj * TES
        caja = shapely.box(x0, z0, x0 + TES, z0 + TES)
        if dentro_de is not None and dentro_de.contains(caja):
            if (ti, tj) in VIEJOS:
                # mismos árboles que antes, quitando los que caigan sobre una calzada nueva (huecos cerrados)
                raw = gzip.decompress(VIEJOS[(ti, tj)]); nv = struct.unpack_from("<I", raw, 4)[0]
                rec = np.frombuffer(raw, dtype=[("x", "<u2"), ("z", "<u2"), ("t", "u1"), ("e", "u1")], count=nv, offset=8)
                lineas = [LineString(geo(k)[a:b + 1][:, [0, 2]]).buffer(red["tramos"][k]["ancho"] * 0.5 + 4.0, 4)
                          for (k, a, b) in piezas if b > a]
                if lineas:
                    fuera = ~shapely.contains_xy(unary_union(lineas), x0 + rec["x"] / 65535.0 * TES, z0 + rec["z"] / 65535.0 * TES)
                    if not fuera.all():
                        rec = rec[fuera]; quitados += nv - len(rec)
                        if len(rec) == 0: continue
                        VIEJOS[(ti, tj)] = gzip.compress(struct.pack("<4sI", b"ARBO", len(rec)) + rec.tobytes(), 6)
                blobs.append(((ti, tj), VIEJOS[(ti, tj)])); reusadas += 1
                total += struct.unpack_from("<I", gzip.decompress(VIEJOS[(ti, tj)]), 4)[0]
            continue
        idx = arbol.query(caja, predicate="intersects")
        if len(idx) == 0: continue
        ng = int(TES / PASO)
        gx, gz = np.meshgrid((np.arange(ng) + 0.5) * PASO, (np.arange(ng) + 0.5) * PASO)
        px = (gx.ravel() + rng.uniform(-0.45, 0.45, ng * ng) * PASO) + x0
        pz = (gz.ravel() + rng.uniform(-0.45, 0.45, ng * ng) * PASO) + z0
        tipo = np.full(px.shape, -1, np.int8)
        for i in idx:
            g, lt = pols[i]
            m = shapely.contains_xy(g, px, pz) & (tipo < 0)
            tipo[m] = lt
        sel = tipo >= 0
        if not sel.any(): continue
        if piezas:
            lineas = []
            for (k, a, b) in piezas:
                pts = geo(k)[a:b + 1]
                if len(pts) >= 2:
                    lineas.append(LineString(pts[:, [0, 2]]).buffer(red["tramos"][k]["ancho"] * 0.5 + 4.0, 4))
            if lineas:
                zona_red = unary_union(lineas)
                sel &= ~shapely.contains_xy(zona_red, px, pz)
        px, pz, tipo = px[sel], pz[sel], tipo[sel]
        if len(px) == 0: continue
        esc = rng.integers(0, 256, len(px)).astype(np.uint8)
        qx = np.clip(np.round((px - x0) / TES * 65535), 0, 65535).astype("<u2")
        qz = np.clip(np.round((pz - z0) / TES * 65535), 0, 65535).astype("<u2")
        rec = np.zeros(len(px), dtype=[("x", "<u2"), ("z", "<u2"), ("t", "u1"), ("e", "u1")])
        rec["x"], rec["z"], rec["t"], rec["e"] = qx, qz, tipo.astype(np.uint8), esc
        blobs.append(((ti, tj), gzip.compress(struct.pack("<4sI", b"ARBO", len(px)) + rec.tobytes(), 6)))
        total += len(px)
    if not blobs: continue
    cab = struct.pack("<4sI", b"PAQA", len(blobs)); pos = len(cab) + len(blobs) * 16; dirx = b""; datos = b""
    for (ti, tj), b in blobs:
        dirx += struct.pack("<iiII", ti, tj, pos + len(datos), len(b)); datos += b
    nombre_a = f"arb_{pi}_{pj}.bin"
    open(os.path.join(out, nombre_a), "wb").write(cab + dirx + datos)
    arb[clave] = nombre_a; tot_bytes += len(cab) + len(dirx) + len(datos)
    if len(arb) % 20 == 0: log(f"{len(arb)} paquetes con árboles, {total} árboles, {tot_bytes/1e6:.1f} MB")
M["arboles"] = {"paquetes": arb, "paso": PASO, "fuente": "Polígonos de bosque de OpenStreetMap (landuse=forest, natural=wood; leaf_type si lo hay). Posición y densidad: APROXIMACIÓN (rejilla de %.0f m con desplazamiento aleatorio), no inventario forestal." % PASO}
M2 = json.load(open(os.path.join(out, "mundo.json"))); M2["arboles"] = M["arboles"]
json.dump(M2, open(os.path.join(out, "mundo.json"), "w"), ensure_ascii=False, indent=1)
log(f"LISTO: {total} árboles en {len(arb)} paquetes, {tot_bytes/1e6:.1f} MB ({reusadas} teselas reutilizadas, {quitados} árboles quitados de calzadas nuevas)")
