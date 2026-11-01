"""Mundo abierto: quita de los paquetes de árboles (arb_*.bin de m5_arboles.py) los que caen a menos de semiancho + 4 m
de CUALQUIER calzada de la red actual (red.json.gz). Hace falta cuando la red cambia después de plantar los árboles
(p. ej. m1b_glorietas.py: anillos completados y conectores nuevos) y m5 no se vuelve a pasar: si no, quedan árboles en
mitad del asfalto nuevo. Mira todas las calzadas (también las de la tesela vecina, que m5 no miraba) menos los túneles.
Los demás árboles quedan byte a byte igual.  Uso: python m5b_arboles_despejar.py juego/datos/madrid [MARGEN=4]"""
import os, sys, json, gzip, struct, time, collections
import numpy as np
from scipy.spatial import cKDTree
out = sys.argv[1]; MARGEN = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
t00 = time.time()
def log(*a): print(f"[{time.time()-t00:6.0f} s]", *a, flush=True)
M = json.load(open(os.path.join(out, "mundo.json"))); TES = M["tesela"]
red = json.loads(gzip.decompress(open(os.path.join(out, "red.json.gz"), "rb").read()))
partes = [gzip.decompress(open(os.path.join(out, p), "rb").read()) for p in M["partes_red"]]
def geo(k):
    g = red["tramos"][k]["g"]; b = partes[g[0]]; o = g[1]; n = g[2]
    p0 = np.frombuffer(b, "<i4", 3, o).astype(np.int64)
    d = np.frombuffer(b, "<i2", (n - 1) * 3, o + 12).reshape(-1, 3).astype(np.int64)
    return np.vstack([p0, p0 + np.cumsum(d, axis=0)]) * 0.01
# puntos de calzada (≤ 3 m entre sí) con su semiancho, repartidos por tesela de 2 km
cubo = collections.defaultdict(list)
npt = 0
for k, t in enumerate(red["tramos"]):
    if t.get("tunel"): continue
    p = geo(k)[:, [0, 2]]
    if len(p) >= 2:
        seg = np.hypot(*np.diff(p, axis=0).T); n = np.maximum(1, np.ceil(seg / 3.0).astype(int))
        u = np.concatenate([i + np.arange(n[i]) / n[i] for i in range(len(seg))] + [[len(p) - 1.0]])
        ii = np.arange(len(p)); p = np.column_stack([np.interp(u, ii, p[:, 0]), np.interp(u, ii, p[:, 1])])
    hw = float(t["ancho"]) * 0.5
    ti = np.floor(p[:, 0] / TES).astype(int); tj = np.floor(p[:, 1] / TES).astype(int)
    for a, b in set(zip(ti.tolist(), tj.tolist())):
        s = (ti == a) & (tj == b)
        cubo[(a, b)].append(np.column_stack([p[s], np.full(s.sum(), hw)]).astype(np.float32))
    npt += len(p)
cubo = {c: np.vstack(v) for c, v in cubo.items()}
log(f"{len(red['tramos'])} tramos, {npt} puntos de calzada en {len(cubo)} teselas")
antes = despues = 0; cambiados = 0; por_paquete = {}
for clave, nombre in sorted(M["arboles"]["paquetes"].items()):
    f = os.path.join(out, nombre); b = open(f, "rb").read(); n = struct.unpack_from("<I", b, 4)[0]
    blobs = []; cambio = False
    for i in range(n):
        ti, tj, off, tam = struct.unpack_from("<iiII", b, 8 + i * 16)
        blob = b[off:off + tam]
        raw = gzip.decompress(blob); nv = struct.unpack_from("<I", raw, 4)[0]
        rec = np.frombuffer(raw, dtype=[("x", "<u2"), ("z", "<u2"), ("t", "u1"), ("e", "u1")], count=nv, offset=8)
        x = ti * TES + rec["x"] / 65535.0 * TES; z = tj * TES + rec["z"] / 65535.0 * TES
        vec = [cubo[c] for c in ((ti + a, tj + c2) for a in (-1, 0, 1) for c2 in (-1, 0, 1)) if c in cubo]
        antes += nv
        if vec:
            P = np.vstack(vec); kd = cKDTree(P[:, :2])
            dd, kk = kd.query(np.column_stack([x, z]), k=min(8, len(P)), distance_upper_bound=40)
            dd = np.atleast_2d(dd); kk = np.atleast_2d(kk)
            if dd.shape[0] != nv: dd = dd.T; kk = kk.T
            marg = np.where(np.isfinite(dd), dd - P[np.minimum(kk, len(P) - 1), 2], np.inf).min(axis=1)
            fuera = marg > MARGEN
            if not fuera.all():
                rec = rec[fuera]; cambio = True
                blob = gzip.compress(struct.pack("<4sI", b"ARBO", len(rec)) + rec.tobytes(), 6)
        despues += len(rec)
        if len(rec): blobs.append(((ti, tj), blob))
    por_paquete[clave] = (n, len(blobs))
    if cambio:
        cambiados += 1
        cab = struct.pack("<4sI", b"PAQA", len(blobs)); pos = len(cab) + len(blobs) * 16; dirx = b""; datos = b""
        for (ti, tj), bb in blobs:
            dirx += struct.pack("<iiII", ti, tj, pos + len(datos), len(bb)); datos += bb
        os.remove(f)                      # nunca escribir encima (enlace duro)
        open(f, "wb").write(cab + dirx + datos)
log(f"LISTO: {antes} -> {despues} árboles ({antes - despues} quitados), {cambiados} paquetes reescritos")
