"""Mundo abierto: baja el terreno que asoma por encima del tablero de los puentes (tramos bridge=* de OSM cuya rasante
queda por debajo del MDT, p. ej. la M-406), en los paquetes de terreno ya generados por m3_mundo.py, con la misma regla que
ahora aplica m3 al generar: dentro de semiancho + 1,5 celdas, el terreno como mucho 30 cm bajo el tablero; nada más
(ni terraplén ni tajo). Solo teselas finas (las que llevan red). Las celdas que no cambian quedan igual.
Uso: python m3b_puentes_terreno.py juego/datos/madrid"""
import json, gzip, os, struct, sys, time, collections
import numpy as np
out = sys.argv[1]
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
CAB = "<4sHHiiHfI"; NC = struct.calcsize(CAB)
# puntos de tablero por tesela
por_tesela = collections.defaultdict(list)
npu = 0
for k, t in enumerate(red["tramos"]):
    if not t.get("puente") or t.get("tunel"): continue
    npu += 1
    p = geo(k); hw = float(t["ancho"]) * 0.5
    for q in p:
        for ti in range(int(np.floor((q[0] - hw - 60) / TES)), int(np.floor((q[0] + hw + 60) / TES)) + 1):
            for tj in range(int(np.floor((q[2] - hw - 60) / TES)), int(np.floor((q[2] + hw + 60) / TES)) + 1):
                por_tesela[(ti, tj)].append((q[0], q[2], q[1], hw))
log(f"{npu} tramos en puente, {len(por_tesela)} teselas tocadas")
celdas = 0; maximo = 0.0; teselas_cambiadas = 0; paquetes = 0
for clave, nombre in sorted(M["paquetes"].items()):
    f = os.path.join(out, nombre); b = open(f, "rb").read(); n = struct.unpack_from("<I", b, 4)[0]
    entradas = []; cambio = False
    for i in range(n):
        ti, tj, off, tam = struct.unpack_from("<iiII", b, 8 + i * 16)
        blob = b[off:off + tam]
        if (ti, tj) in por_tesela:
            raw = gzip.decompress(blob)
            mag, ver, fina, a_, b_, nn, paso, npz = struct.unpack_from(CAB, raw, 0)
            o = NC + 12 * npz
            if fina:
                dm = np.frombuffer(raw, "<i2", nn * nn, o).reshape(nn, nn).astype(np.int32)
                h = np.cumsum(dm, axis=1).astype(np.float64) / 10.0
                xs = ti * TES + np.arange(nn) * paso; zs = tj * TES + np.arange(nn) * paso
                tope = np.full_like(h, np.inf)
                for (px, pz, py, hw) in por_tesela[(ti, tj)]:
                    rad = hw + 1.5 * paso
                    a0 = max(int((px - rad - xs[0]) / paso), 0); a1 = min(int((px + rad - xs[0]) / paso) + 1, nn - 1)
                    b0 = max(int((pz - rad - zs[0]) / paso), 0); b1 = min(int((pz + rad - zs[0]) / paso) + 1, nn - 1)
                    if a1 < a0 or b1 < b0: continue
                    dd = np.hypot(xs[a0:a1 + 1][None, :] - px, zs[b0:b1 + 1][:, None] - pz)
                    sub = tope[b0:b1 + 1, a0:a1 + 1]
                    np.minimum(sub, np.where(dd <= rad, py - 0.3, np.inf), out=sub)
                h2 = np.minimum(h, tope)
                mask = h2 < h - 0.05
                if mask.any():
                    celdas += int(mask.sum()); maximo = max(maximo, float((h - h2)[mask].max()))
                    nd = np.clip(np.round(h2 * 10), 0, 32000).astype(np.int32)
                    nd[:, 1:] = np.diff(nd, axis=1)
                    raw2 = raw[:o] + nd.astype("<i2").tobytes() + raw[o + nn * nn * 2:]
                    blob = gzip.compress(raw2, 6); cambio = True; teselas_cambiadas += 1
        entradas.append((ti, tj, blob))
    if cambio:
        paquetes += 1
        cab = b[:8]; pos = 8 + len(entradas) * 16; dirx = b""; datos = b""
        for ti, tj, bb in entradas:
            dirx += struct.pack("<iiII", ti, tj, pos + len(datos), len(bb)); datos += bb
        os.remove(f)                      # nunca escribir encima (enlace duro)
        open(f, "wb").write(cab + dirx + datos)
log(f"LISTO: {celdas} celdas bajadas (máx. {maximo:.2f} m) en {teselas_cambiadas} teselas, {paquetes} paquetes reescritos")
