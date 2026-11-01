"""Mundo abierto · paso 3: red con altitud (MDT05) + teselas de terreno (2 km) para el juego.
Uso: python m3_mundo.py red.pkl cache_mdt salida_dir
Salida (en salida_dir):
  red_N.bin.gz      geometría 3D de todos los tramos (remuestreada a 5 m), en varios archivos de ≤ ~2,5 MB
  red.json.gz       tramos (atributos, nodos, longitud, archivo/desplazamiento de su geometría) y nodos (posición, tramos)
  ter_I_J.bin       paquetes de 4×4 teselas de terreno: cabecera + cada tesela comprimida (gzip) por separado
  mundo.json        índice: origen, tamaño de tesela, paquetes, teselas, horizonte (relieve lejano)
  horizonte.bin.gz  relieve de toda la caja a 200 m (mínimo de cada celda, para que nunca asome sobre las teselas)
Coordenadas del juego: X = E - E0, Z = N0 - N, Y = altitud (m), EPSG:25830."""
import os, sys, math, json, gzip, pickle, struct, time, glob, collections
import numpy as np
import rasterio
from pyproj import Transformer
from scipy.ndimage import gaussian_filter1d, median_filter
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import rutas_base as RB

E0, N0 = 430000.0, 4488000.0
TES = 2000.0            # tesela (m)
PAQ = 4                 # teselas por lado en cada paquete (8 km)
PASO_RED = 5.0          # m entre muestras de la carretera
PASO_FINO = 10.0        # m del terreno en teselas con carretera (MDT05)
PASO_GRUESO = 25.0      # m del terreno en teselas sin carretera (MDT25)
MARGEN_TES = 6000.0     # teselas hasta 6 km de alguna carretera
PASO_HOR = 200.0
RELLENO_ANCHO = 20.0    # m más allá del borde de la calzada hasta donde se rellena el terreno (terraplén)
RELLENO_TALUD = 0.6     # m de bajada por m de distancia del terraplén
t00 = time.time()
def log(*a): print(f"[{time.time()-t00:6.0f} s]", *a, flush=True)

red_pkl, cache, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
d = pickle.load(open(red_pkl, "rb"))
T = Transformer.from_crs(4326, 25830, always_xy=True)
ids = list(d["coord"].keys())
lon = np.array([d["coord"][k][0] for k in ids]); lat = np.array([d["coord"][k][1] for k in ids])
E, N = T.transform(lon, lat)
nid = {k: i for i, k in enumerate(ids)}
NX = E - E0; NZ = N0 - N

# ---------------- MDT
class Mosaico:
    """Bloques GeoTIFF del IGN (caché) con muestreo bilineal en coordenadas UTM."""
    def __init__(self, patron, bloque, paso):
        self.bl = {}
        for f in glob.glob(os.path.join(cache, patron)):
            p = os.path.basename(f)[:-4].split("_")
            self.bl[(int(p[-2]), int(p[-1]))] = f
        self.bloque, self.paso, self.carg = bloque, paso, collections.OrderedDict()
    def _arr(self, k):
        if k in self.carg:
            self.carg.move_to_end(k); return self.carg[k]
        if k not in self.bl: return None
        with rasterio.open(self.bl[k]) as s:
            a = s.read(1).astype(np.float32); tr = s.transform
        a[a < -100] = np.nan
        self.carg[k] = (a, tr)
        if len(self.carg) > 24: self.carg.popitem(last=False)
        return self.carg[k]
    def muestrear(self, e, n):
        e = np.asarray(e, float); n = np.asarray(n, float); forma = e.shape
        e = e.ravel(); n = np.broadcast_to(n, forma).ravel()
        res = np.full(e.shape, np.nan)
        kx = (np.floor(e / self.bloque) * self.bloque).astype(np.int64); ky = (np.floor(n / self.bloque) * self.bloque).astype(np.int64)
        for k in set(zip(kx.tolist(), ky.tolist())):
            m = (kx == k[0]) & (ky == k[1])
            r = self._arr(k)
            if r is None: continue
            a, tr = r
            c = (e[m] - tr.c) / tr.a - 0.5; f = (n[m] - tr.f) / tr.e - 0.5
            c0 = np.clip(np.floor(c).astype(int), 0, a.shape[1] - 2); f0 = np.clip(np.floor(f).astype(int), 0, a.shape[0] - 2)
            fc = np.clip(c - c0, 0, 1); ff = np.clip(f - f0, 0, 1)
            res[m] = (a[f0, c0] * (1 - fc) * (1 - ff) + a[f0, c0 + 1] * fc * (1 - ff) + a[f0 + 1, c0] * (1 - fc) * ff + a[f0 + 1, c0 + 1] * fc * ff)
        return res.reshape(forma)
mdt05 = Mosaico("Elevacion25830_5_*.tif", 5000, 5.0)
mdt25 = Mosaico("Elevacion25830_25_*.tif", 20000, 25.0)
def altura(e, n):
    e = np.asarray(e, float); n = np.broadcast_to(np.asarray(n, float), e.shape)
    h = mdt05.muestrear(e, n)
    m = np.isnan(h)
    if m.any(): h[m] = mdt25.muestrear(e[m], n[m])
    return h
log(f"MDT05 {len(mdt05.bl)} bloques, MDT25 {len(mdt25.bl)} bloques")

# ---------------- tramos: geometría remuestreada
tramos = d["tramos"]
geo = []
for t in tramos:
    ii = np.array([nid[k] for k in t["nodos"]])
    xy = np.column_stack([NX[ii], NZ[ii]])
    seg = np.hypot(*np.diff(xy, axis=0).T)
    ok = np.concatenate([[True], seg > 0.01]); xy = xy[ok]
    if len(xy) < 2:
        xy = np.vstack([xy[0], xy[0] + [0.01, 0]])
    s = np.concatenate([[0], np.cumsum(np.hypot(*np.diff(xy, axis=0).T))])
    n = max(2, int(math.ceil(s[-1] / PASO_RED)) + 1)
    si = np.linspace(0, s[-1], n)
    x = np.interp(si, s, xy[:, 0]); z = np.interp(si, s, xy[:, 1])
    if n > 4:   # suavizado ligero en planta (como rutas.py), extremos fijos
        x2 = gaussian_filter1d(x, 3.0 / PASO_RED, mode="nearest"); z2 = gaussian_filter1d(z, 3.0 / PASO_RED, mode="nearest")
        x2[0], z2[0], x2[-1], z2[-1] = x[0], z[0], x[-1], z[-1]
        x, z = x2, z2
    geo.append([si, x, z])
log(f"{len(tramos)} tramos remuestreados a {PASO_RED} m, {sum(len(g[0]) for g in geo)} puntos")

# ---------------- altitud: MDT05 bajo cada punto (agrupado por bloque), nodos, puentes y túneles
todos_x = np.concatenate([g[1] for g in geo]); todos_z = np.concatenate([g[2] for g in geo])
h_all = altura(todos_x + E0, N0 - todos_z)
log(f"MDT05 muestreado en {len(h_all)} puntos (sin dato: {int(np.isnan(h_all).sum())})")
def sin_terreno(t):
    tg = t["tags"]
    return tg.get("bridge", "no") not in ("no", "") or tg.get("tunnel", "no") not in ("no", "") or tg.get("covered") == "yes"
H = np.full(len(ids), np.nan)          # altura de cada nodo de cruce
hn = altura(NX + E0, N0 - NZ)
inc = collections.defaultdict(list)
for k, t in enumerate(tramos):
    a, b = nid[t["nodos"][0]], nid[t["nodos"][-1]]
    inc[a].append((k, b)); inc[b].append((k, a))
    if not sin_terreno(t):
        H[a] = hn[a]; H[b] = hn[b]
# nodos rodeados solo de puentes/túneles: interpolación armónica por la red (en una cadena = lineal por distancia)
desconocidos = [n for n in inc if np.isnan(H[n])]
L = [g[0][-1] for g in geo]
Hs = H.copy()
for n in desconocidos: Hs[n] = hn[n]
for it in range(400):
    for n in desconocidos:
        num = den = 0.0
        for (k, m) in inc[n]:
            w = 1.0 / max(L[k], 1.0); num += w * Hs[m]; den += w
        Hs[n] = num / den
log(f"nodos: {len(inc)} con tramo, {len(desconocidos)} solo en puentes/túneles (interpolados)")
off = 0
alt = []
for k, (t, g) in enumerate(zip(tramos, geo)):
    s = g[0]; n = len(s)
    z = h_all[off:off + n].copy(); off += n
    a, b = nid[t["nodos"][0]], nid[t["nodos"][-1]]
    ha, hb = Hs[a], Hs[b]
    if sin_terreno(t) or np.isnan(z).all():
        y = ha + (hb - ha) * s / max(s[-1], 0.01)
    else:
        if np.isnan(z).any(): z = np.interp(s, s[~np.isnan(z)], z[~np.isnan(z)])
        if n >= 5:
            z = median_filter(z, size=5, mode="nearest")
            z = gaussian_filter1d(z, 12.0 / PASO_RED, mode="nearest")
        # extremos exactos en la altura del nodo (continuidad en los cruces)
        y = z + (ha - z[0]) * (1 - s / max(s[-1], 0.01)) + (hb - z[-1]) * (s / max(s[-1], 0.01))
    alt.append(y.astype(np.float32))

# ---------------- gálibo en los cruces a distinto nivel: el tablero del puente iba en línea recta entre sus dos
# extremos y la vía de abajo con el MDT, así que en 224 de 1207 cruces quedaban a < 3,5 m (alguno con la de abajo por
# encima). Se exige GALIBO m (5 m libres + canto) subiendo el de arriba con una joroba suave (extremos fijos, pendiente
# ≤ PEND_MAX) y, lo que falte, bajando la de abajo igual.
GALIBO = 6.0; PEND_MAX = 0.08; ALCANCE = 200.0
def nivel(t):
    tg = t["tags"]
    try: capa = float(tg.get("layer", "0").split(";")[0])
    except ValueError: capa = 0.0
    if tg.get("bridge", "no") not in ("no", ""): capa += 0.5
    if tg.get("tunnel", "no") not in ("no", "") or tg.get("covered") == "yes": capa -= 0.5
    return capa
def joroba(k, sc, cuanto):
    """Sube (cuanto > 0) o baja el tramo k alrededor de la abscisa sc; devuelve lo conseguido en sc."""
    s = geo[k][0]; L = s[-1]
    if L < 1.0: return 0.0
    w0 = min(sc, ALCANCE); w1 = min(L - sc, ALCANCE)
    tope = PEND_MAX * min(w0, w1) / 1.5          # smoothstep: pendiente máx. = 1,5 × media
    c = float(np.clip(cuanto, -tope, tope))
    if abs(c) < 0.01: return 0.0
    f = np.zeros_like(s)
    m0 = (s <= sc) & (s > sc - w0); u = (s[m0] - (sc - w0)) / max(w0, 1e-3); f[m0] = u * u * (3 - 2 * u)
    m1 = (s > sc) & (s < sc + w1); u = ((sc + w1) - s[m1]) / max(w1, 1e-3); f[m1] = u * u * (3 - 2 * u)
    alt[k] = (alt[k] + c * f).astype(np.float32)
    return c
celdas_g = collections.defaultdict(list)
for k, g in enumerate(geo):
    for i in range(len(g[0]) - 1):
        celdas_g[(int(g[1][i] // 50), int(g[2][i] // 50))].append((k, i))
def _corta(a, b, c, d):
    r = (b - a); q = (d - c); den = r[0] * q[1] - r[1] * q[0]
    if abs(den) < 1e-9: return None
    t = ((c[0] - a[0]) * q[1] - (c[1] - a[1]) * q[0]) / den; u = ((c[0] - a[0]) * r[1] - (c[1] - a[1]) * r[0]) / den
    return (t, u) if 0 <= t <= 1 and 0 <= u <= 1 else None
cruces_n = []
vistos = set()
for cel, lista in celdas_g.items():
    for x1 in range(len(lista)):
        k1, i1 = lista[x1]
        for x2 in range(x1 + 1, len(lista)):
            k2, i2 = lista[x2]
            if k1 == k2: continue
            n1, n2 = nivel(tramos[k1]), nivel(tramos[k2])
            if n1 == n2: continue
            t1, t2 = tramos[k1], tramos[k2]
            if {t1["nodos"][0], t1["nodos"][-1]} & {t2["nodos"][0], t2["nodos"][-1]}: continue
            g1, g2 = geo[k1], geo[k2]
            r = _corta(np.array([g1[1][i1], g1[2][i1]]), np.array([g1[1][i1 + 1], g1[2][i1 + 1]]),
                       np.array([g2[1][i2], g2[2][i2]]), np.array([g2[1][i2 + 1], g2[2][i2 + 1]]))
            if r is None: continue
            arriba, abajo, ia, ib, ta, tb = (k1, k2, i1, i2, r[0], r[1]) if n1 > n2 else (k2, k1, i2, i1, r[1], r[0])
            if (arriba, abajo) in vistos: continue
            vistos.add((arriba, abajo))
            sa = geo[arriba][0][ia] + ta * (geo[arriba][0][ia + 1] - geo[arriba][0][ia])
            sb = geo[abajo][0][ib] + tb * (geo[abajo][0][ib + 1] - geo[abajo][0][ib])
            cruces_n.append((arriba, sa, abajo, sb))
def alt_en(k, sc): return float(np.interp(sc, geo[k][0], alt[k]))
antes = [alt_en(a, sa) - alt_en(b, sb) for (a, sa, b, sb) in cruces_n]
for it in range(3):
    for (a, sa, b, sb) in cruces_n:
        falta = GALIBO - (alt_en(a, sa) - alt_en(b, sb))
        if falta <= 0.05: continue
        falta -= joroba(a, sa, falta)
        if falta > 0.05: joroba(b, sb, -falta)
despues = [alt_en(a, sa) - alt_en(b, sb) for (a, sa, b, sb) in cruces_n]
log(f"cruces a distinto nivel: {len(cruces_n)}; con gálibo < 3,5 m antes {sum(1 for v in antes if v < 3.5)}, después {sum(1 for v in despues if v < 3.5)} (< {GALIBO - 0.1:.1f} m: {sum(1 for v in despues if v < GALIBO - 0.1)})")

# ---------------- atributos de cada tramo
CLASES = ["motorway", "trunk", "primary", "secondary", "tertiary"]
def carriles(tg, base):
    try: return max(1, int(tg.get("lanes", "").split(";")[0]))
    except ValueError: pass
    if "_link" in tg.get("highway", ""): return 1
    return 2 if tg.get("oneway") == "yes" or base in ("motorway",) else 2
def sentido(tg):
    ow = tg.get("oneway", "")
    if ow in ("yes", "true", "1") or tg.get("highway") in ("motorway",) or tg.get("junction") in ("roundabout", "circular"):
        return 1
    if ow == "-1": return -1
    if tg.get("highway", "").endswith("_link") and ow not in ("no",): return 1   # en España los enlaces son de un sentido
    return 0
info_tramos = []
for k, t in enumerate(tramos):
    tg = t["tags"]; base = tg.get("highway", "").replace("_link", "")
    ow = sentido(tg)
    lanes = carriles(tg, base)
    ancho = RB.ancho_de(tg)
    # Norma 3.1-IC (valores típicos, no medidos): arcén exterior 2,5 m en autopista/autovía, 1,5 m en las demás; en el juego se pinta la calzada
    info_tramos.append({
        "c": CLASES.index(base) if base in CLASES else 4, "enlace": 1 if "_link" in tg.get("highway", "") else 0,
        "ref": tg.get("ref", ""), "nombre": tg.get("name", ""), "s": ow, "carriles": lanes, "ancho": round(float(ancho), 2),
        "v": RB.vel_max_de(tg), "vf": RB.vel_de(tg, "forward"), "vb": RB.vel_de(tg, "backward"),
        "puente": 1 if tg.get("bridge", "no") not in ("no", "") else 0, "tunel": 1 if tg.get("tunnel", "no") not in ("no", "") else 0,
        "rot": 1 if tg.get("junction") in ("roundabout", "circular") else 0, "capa": tg.get("layer", "0"),
        "a": nid[t["nodos"][0]], "b": nid[t["nodos"][-1]], "L": round(float(geo[k][0][-1]), 1), "way": t["way"]})

# ---------------- geometría 3D de la red en archivos de ≤ ~2,5 MB comprimidos
# por tramo: primer punto en int32 (cm) y luego diferencias en int16 (cm) → ~6 bytes/punto antes de comprimir
partes = []; buf = bytearray(); parte = 0; MAXC = 5_000_000
def cerrar():
    global buf, parte
    if not buf: return
    nombre = f"red_{parte}.bin.gz"
    open(os.path.join(out, nombre), "wb").write(gzip.compress(bytes(buf), 9))
    partes.append(nombre); parte += 1; buf = bytearray()
for k in range(len(tramos)):
    cm = np.round(np.column_stack([geo[k][1], alt[k], geo[k][2]]) * 100).astype(np.int64)
    dif = np.diff(cm, axis=0)
    assert np.abs(dif).max(initial=0) < 32000, k
    blob = cm[0].astype("<i4").tobytes() + dif.astype("<i2").tobytes()
    if len(buf) + len(blob) > MAXC:
        cerrar()
    info_tramos[k]["g"] = [parte, len(buf), len(cm)]
    buf += blob
cerrar()
log(f"geometría en {len(partes)} archivos")

# ---------------- teselas: cuáles existen (≤ MARGEN_TES de una carretera) y cuáles llevan carretera
todos_x = np.concatenate([g[1] for g in geo]); todos_z = np.concatenate([g[2] for g in geo])
con_red = collections.defaultdict(list)    # (i, j) -> [(tramo, i0, i1)]
for k, g in enumerate(geo):
    x, z = g[1], g[2]
    hw = info_tramos[k]["ancho"] * 0.5 + 6.0
    for (ti, tj) in set(zip(np.floor((x - hw) / TES).astype(int).tolist() + np.floor((x + hw) / TES).astype(int).tolist(),
                             np.floor((z - hw) / TES).astype(int).tolist() + np.floor((z + hw) / TES).astype(int).tolist())):
        x0, z0 = ti * TES, tj * TES
        dentro = np.nonzero((x > x0 - hw - PASO_RED) & (x < x0 + TES + hw + PASO_RED) & (z > z0 - hw - PASO_RED) & (z < z0 + TES + hw + PASO_RED))[0]
        if len(dentro):
            con_red[(ti, tj)].append((k, int(max(dentro.min() - 1, 0)), int(min(dentro.max() + 1, len(x) - 1))))
cel = set()
r = int(MARGEN_TES / TES)
for (ti, tj) in con_red:
    for di in range(-r, r + 1):
        for dj in range(-r, r + 1):
            cel.add((ti + di, tj + dj))
log(f"teselas: {len(cel)} en total, {len(con_red)} con carretera")

def tesela(ti, tj):
    fina = (ti, tj) in con_red
    paso = PASO_FINO if fina else PASO_GRUESO
    nn = int(TES / paso) + 1
    xs = ti * TES + np.arange(nn) * paso; zs = tj * TES + np.arange(nn) * paso
    gx, gz = np.meshgrid(xs, zs)
    h = (altura(gx + E0, N0 - gz) if fina else mdt25.muestrear(gx + E0, N0 - gz)).reshape(nn, nn)
    if np.isnan(h).any():
        h = np.where(np.isnan(h), np.nanmin(h) if not np.isnan(h).all() else 600.0, h)
    if fina:
        # bajar el terreno bajo la calzada: a ≤ semiancho + 1,5 celdas, como mucho a 30 cm bajo la rasante
        relleno = np.full_like(h, -np.inf); tajo = np.full_like(h, np.inf)
        for (k, i0, i1) in con_red[(ti, tj)]:
            it = info_tramos[k]
            if it["puente"] or it["tunel"]: continue
            x = geo[k][1][i0:i1 + 1]; z = geo[k][2][i0:i1 + 1]; y = alt[k][i0:i1 + 1]
            hw = it["ancho"] * 0.5
            rad = hw + 1.5 * paso
            radr = hw + RELLENO_ANCHO
            for (px, pz, py) in zip(x, z, y):
                a0 = max(int((px - radr - xs[0]) / paso), 0); a1 = min(int((px + radr - xs[0]) / paso) + 1, nn - 1)
                b0 = max(int((pz - radr - zs[0]) / paso), 0); b1 = min(int((pz + radr - zs[0]) / paso) + 1, nn - 1)
                if a1 < a0 or b1 < b0: continue
                sub = h[b0:b1 + 1, a0:a1 + 1]
                dd = np.hypot(xs[a0:a1 + 1][None, :] - px, zs[b0:b1 + 1][:, None] - pz)
                np.minimum(sub, np.where(dd <= rad, py - 0.3, np.inf), out=sub)
                # terraplén: el terreno no queda más de 30 cm bajo la calzada (talud 1:1,6 hacia fuera); sin esto, el
                # desmonte de una vía que pasa por debajo (o un hueco del MDT: obras de drenaje) dejaba la de arriba
                # en el aire, con sus taludes colgando
                rs = relleno[b0:b1 + 1, a0:a1 + 1]
                np.maximum(rs, np.where(dd <= radr, py - 0.3 - RELLENO_TALUD * np.maximum(dd - hw - 1.0, 0.0), -np.inf), out=rs)
                ts = tajo[b0:b1 + 1, a0:a1 + 1]
                np.minimum(ts, np.where(dd <= hw + 0.75 * paso, py - 0.3, np.inf), out=ts)
        # el relleno manda salvo justo bajo otra calzada (la de abajo en un paso a distinto nivel sin puente en OSM)
        h = np.minimum(np.maximum(h, relleno), tajo)
    dm = np.clip(np.round(h * 10), 0, 32000).astype(np.int32)
    dm[:, 1:] = np.diff(dm, axis=1)     # por filas: 1.ª columna absoluta (dm), resto diferencias → comprime ~2×
    dm = dm.astype("<i2")
    piezas = con_red.get((ti, tj), [])
    cab = struct.pack("<4sHHiiHfI", b"TESL", 2, 1 if fina else 0, ti, tj, nn, paso, len(piezas))
    pz = b"".join(struct.pack("<iii", k, a, b) for (k, a, b) in piezas)
    return gzip.compress(cab + pz + dm.tobytes(), 6), fina

paquetes = collections.defaultdict(list)
for (ti, tj) in cel:
    paquetes[(ti // PAQ, tj // PAQ)].append((ti, tj))
indice_paq = {}
t1 = time.time(); hechas = 0; bytes_tot = 0; finas = 0
for (pi, pj), lista in sorted(paquetes.items()):
    lista.sort()
    blobs = []
    for (ti, tj) in lista:
        b, fina = tesela(ti, tj); blobs.append(((ti, tj), b)); finas += fina
        hechas += 1
    nombre = f"ter_{pi}_{pj}.bin"
    cab = struct.pack("<4sI", b"PAQT", len(blobs))
    pos = len(cab) + len(blobs) * 16
    dirx = b""; datos = b""
    for (ti, tj), b in blobs:
        dirx += struct.pack("<iiII", ti, tj, pos + len(datos), len(b)); datos += b
    open(os.path.join(out, nombre), "wb").write(cab + dirx + datos)
    bytes_tot += len(cab) + len(dirx) + len(datos)
    indice_paq[f"{pi},{pj}"] = nombre
    if len(indice_paq) % 20 == 0:
        log(f"paquetes {len(indice_paq)}/{len(paquetes)} · teselas {hechas}/{len(cel)} · {bytes_tot/1e6:.0f} MB")
log(f"terreno: {hechas} teselas ({finas} a {PASO_FINO:.0f} m), {bytes_tot/1e6:.1f} MB en {len(indice_paq)} paquetes")

# ---------------- horizonte (relieve lejano): MDT25 a PASO_HOR, mínimo de la celda
ii = [c[0] for c in cel]; jj = [c[1] for c in cel]
hx0, hz0 = min(ii) * TES, min(jj) * TES; hx1, hz1 = (max(ii) + 1) * TES, (max(jj) + 1) * TES
nx = int((hx1 - hx0) / PASO_HOR) + 1; nz = int((hz1 - hz0) / PASO_HOR) + 1
sub = 8   # submuestras de 25 m por celda
gx = hx0 + np.arange((nx - 1) * sub + 1) * (PASO_HOR / sub); gz = hz0 + np.arange((nz - 1) * sub + 1) * (PASO_HOR / sub)
filas = []
for j in range(len(gz)):
    filas.append(mdt25.muestrear(gx + E0, np.full(len(gx), N0 - gz[j])))
HH = np.array(filas)
HH = np.where(np.isnan(HH), np.nanmin(HH), HH)
from scipy.ndimage import minimum_filter
mn = minimum_filter(HH, size=2 * sub + 1, mode="nearest")[::sub, ::sub]
real = HH[::sub, ::sub]
hor = np.stack([np.round(mn * 10), np.round(real * 10)]).clip(0, 65535).astype("<u2")
open(os.path.join(out, "horizonte.bin.gz"), "wb").write(gzip.compress(hor.tobytes(), 9))
log(f"horizonte {nx}x{nz} a {PASO_HOR:.0f} m")

# ---------------- índice + red
nodos_usados = sorted(inc.keys())
red = {"tramos": info_tramos, "nodos": {str(n): [round(float(NX[n]), 2), round(float(Hs[n]), 2), round(float(NZ[n]), 2), [k for (k, m) in inc[n]]] for n in nodos_usados}}
open(os.path.join(out, "red.json.gz"), "wb").write(gzip.compress(json.dumps(red, ensure_ascii=False, separators=(",", ":")).encode(), 9))
mundo = {"version": 1, "nombre": "Comunidad de Madrid", "crs": "EPSG:25830", "origen_utm": [E0, N0],
         "convenio": "X=E-E0, Z=N0-N, Y=altitud (m)", "tesela": TES, "paquete": PAQ, "paso_red": PASO_RED,
         "partes_red": partes, "paquetes": indice_paq, "teselas": len(cel), "teselas_con_red": len(con_red),
         "horizonte": {"x0": hx0, "z0": hz0, "nx": nx, "nz": nz, "paso": PASO_HOR},
         "fuentes": {"osm": "© colaboradores de OpenStreetMap (ODbL), extracto Geofabrik madrid 2026-10-30",
                     "mdt05": "IGN MDT05 (CNIG, LiDAR PNOA, WCS servicios.idee.es) — CC BY 4.0 scne.es: altura de la calzada y terreno junto a ella (10 m)",
                     "mdt25": "IGN MDT25 (WCS servicios.idee.es) — CC BY 4.0 scne.es: terreno lejos de la red (25 m) y horizonte (200 m)"}}
json.dump(mundo, open(os.path.join(out, "mundo.json"), "w"), ensure_ascii=False, indent=1)
tam = sum(os.path.getsize(os.path.join(out, f)) for f in os.listdir(out))
log(f"LISTO: {tam/1e6:.1f} MB en {len(os.listdir(out))} archivos")
