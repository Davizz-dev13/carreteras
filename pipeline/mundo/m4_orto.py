"""Mundo abierto · paso 4: ortofoto real IGN PNOA (máxima actualidad) para el suelo de cada tesela y del horizonte.
WMS www.ign.es/wms-inspire/pnoa-ma (OI.OrthoimageCoverage), CC BY 4.0 scne.es.
 · teselas con carretera: 384 px por tesela de 2 km (5,2 m/píxel); sin carretera: 192 px (10,4 m/píxel)
 · horizonte: toda la caja en una imagen de ~4096 px (≈ 36 m/píxel)
Uso: python m4_orto.py salida_dir cache_dir"""
import os, sys, io, json, gzip, struct, time, concurrent.futures as cf
import requests
from PIL import Image, ImageEnhance
WMS = "https://www.ign.es/wms-inspire/pnoa-ma"
UA = {"User-Agent": "carreteras-espana/0.1"}
out, cache = sys.argv[1], sys.argv[2]
os.makedirs(cache, exist_ok=True)
M = json.load(open(os.path.join(out, "mundo.json")))
E0, N0 = M["origen_utm"]; TES = M["tesela"]; PAQ = M["paquete"]
FINA, GRUESA = 384, 192
t00 = time.time()
def log(*a): print(f"[{time.time()-t00:6.0f} s]", *a, flush=True)

def wms(x0, z0, x1, z1, w, h):
    """Imagen del PNOA de la caja del juego [x0,x1]×[z0,z1] (z hacia el sur) a w×h px (bloques de ≤ 2048 px)."""
    img = Image.new("RGB", (w, h))
    B = 2048
    for py in range(0, h, B):
        for px in range(0, w, B):
            bw = min(B, w - px); bh = min(B, h - py)
            ex0 = E0 + x0 + (x1 - x0) * px / w; ex1 = E0 + x0 + (x1 - x0) * (px + bw) / w
            ny1 = N0 - (z0 + (z1 - z0) * py / h); ny0 = N0 - (z0 + (z1 - z0) * (py + bh) / h)
            err = ""
            for i in range(8):
                try:
                    r = requests.get(WMS, params={"SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetMap", "LAYERS": "OI.OrthoimageCoverage",
                        "STYLES": "", "CRS": "EPSG:25830", "BBOX": f"{ex0},{ny0},{ex1},{ny1}", "WIDTH": bw, "HEIGHT": bh, "FORMAT": "image/jpeg"},
                        headers=UA, timeout=180)
                    if r.status_code == 200 and r.content[:2] == b"\xff\xd8":
                        img.paste(Image.open(io.BytesIO(r.content)).convert("RGB"), (px, py)); break
                    err = f"HTTP {r.status_code} {r.content[:120]!r}"
                except Exception as ex:
                    err = str(ex)
                time.sleep(4 + 6 * i)
            else:
                raise RuntimeError(err)
    return img

def teselas_del_paquete(nombre):
    b = open(os.path.join(out, nombre), "rb").read()
    n = struct.unpack_from("<I", b, 4)[0]
    r = []
    for i in range(n):
        ti, tj, off, tam = struct.unpack_from("<iiII", b, 8 + i * 16)
        blob = gzip.decompress(b[off:off + tam])
        fina = struct.unpack_from("<H", blob, 6)[0] == 1
        r.append((ti, tj, fina))
    return r

def paquete(clave, nombre):
    pi, pj = map(int, clave.split(","))
    lista = teselas_del_paquete(nombre)
    f = os.path.join(cache, f"orto_{pi}_{pj}.jpg")
    if os.path.exists(f):
        img = Image.open(f).convert("RGB")
    else:
        lado = PAQ * FINA
        img = wms(pi * PAQ * TES, pj * PAQ * TES, (pi + 1) * PAQ * TES, (pj + 1) * PAQ * TES, lado, lado)
        img.save(f, quality=92)
    blobs = []
    for (ti, tj, fina) in lista:
        li, lj = ti - pi * PAQ, tj - pj * PAQ
        t = img.crop((li * FINA, lj * FINA, (li + 1) * FINA, (lj + 1) * FINA))
        if not fina:
            t = t.resize((GRUESA, GRUESA), Image.LANCZOS)
        bb = io.BytesIO(); t.save(bb, "JPEG", quality=74, optimize=True)
        blobs.append(((ti, tj), bb.getvalue()))
    cab = struct.pack("<4sI", b"PAQO", len(blobs))
    pos = len(cab) + len(blobs) * 16
    dirx = b""; datos = b""
    for (ti, tj), b in blobs:
        dirx += struct.pack("<iiII", ti, tj, pos + len(datos), len(b)); datos += b
    nombre_o = f"ort_{pi}_{pj}.bin"
    open(os.path.join(out, nombre_o), "wb").write(cab + dirx + datos)
    return clave, nombre_o, len(cab) + len(dirx) + len(datos)

paq = M["paquetes"]
ort = {}; total = 0; hechos = 0
with cf.ThreadPoolExecutor(2) as ex:
    for clave, nombre_o, tam in ex.map(lambda kv: paquete(*kv), paq.items()):
        ort[clave] = nombre_o; total += tam; hechos += 1
        if hechos % 20 == 0 or hechos == len(paq):
            log(f"ortofoto: {hechos}/{len(paq)} paquetes, {total/1e6:.1f} MB")
# horizonte
hz = M["horizonte"]
x0, z0 = hz["x0"], hz["z0"]; x1 = x0 + (hz["nx"] - 1) * hz["paso"]; z1 = z0 + (hz["nz"] - 1) * hz["paso"]
f = os.path.join(cache, "orto_horizonte.png")
if os.path.exists(f):
    img = Image.open(f).convert("RGB")
else:
    w = 4096; h = int(round(w * (z1 - z0) / (x1 - x0) / 4) * 4)
    img = wms(x0, z0, x1, z1, w, h); img.save(f)
q = 85
while True:
    img.save(os.path.join(out, "horizonte_orto.jpg"), "JPEG", quality=q, optimize=True)
    if os.path.getsize(os.path.join(out, "horizonte_orto.jpg")) <= 2_900_000 or q <= 60: break
    q -= 5
log(f"horizonte {img.size} calidad {q}: {os.path.getsize(os.path.join(out, 'horizonte_orto.jpg'))/1e6:.2f} MB")
M["ortofoto"] = {"paquetes": ort, "px_fina": FINA, "px_gruesa": GRUESA, "horizonte": "horizonte_orto.jpg", "marco_horizonte": [x0, z0, x1, z1],
                 "fuente": "IGN PNOA máxima actualidad (WMS www.ign.es/wms-inspire/pnoa-ma, OI.OrthoimageCoverage) — CC BY 4.0 scne.es"}
json.dump(M, open(os.path.join(out, "mundo.json"), "w"), ensure_ascii=False, indent=1)
log(f"LISTO: {total/1e6:.1f} MB de ortofoto en {len(ort)} paquetes")
