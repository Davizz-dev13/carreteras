"""Paisaje lejano real para cada zona (solo versión de escritorio / .exe, ver juego/scripts/paisaje.gd).

Descarga y prepara, por zona:
  · relieve del entorno: IGN MDT25 (WCS servicios.idee.es, Elevacion25830_25) remuestreado por el propio
    servicio a 100 m (SCALEFACTOR=0.25), en un marco de la zona + MARGEN km por cada lado → lejano.bin
    (uint16, decímetros, filas de norte a sur = z creciente del juego).
  · color real del suelo: IGN PNOA máxima actualidad (WMS www.ign.es/wms-inspire/pnoa-ma, capa
    OI.OrthoimageCoverage), una imagen de la zona (~5 m/píxel) y otra del entorno (~35 m/píxel) → JPEG.
  · paisaje.json con los marcos (en coordenadas del juego), fuentes y la cota de nieve SUPUESTA para invierno.
Uso: python pipeline/paisaje.py --zona navacerrada [--margen 25]
"""
import argparse, json, os, sys, io, math, time
import numpy as np
import requests, rasterio
from PIL import Image

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UA = {"User-Agent": "carreteras-espana/0.1"}
WCS = "https://servicios.idee.es/wcs-inspire/mdt"
WMS = "https://www.ign.es/wms-inspire/pnoa-ma"
# Cota de nieve típica de pleno invierno (APROXIMACIÓN, no dato del día): ver FUENTES en paisaje.json
NIEVE = {
    "navacerrada": [1550, "Aproximación: en pleno invierno la nieve suele cubrir el Guadarrama por encima de ~1.500-1.600 m (el puerto está a 1.858 m y la estación de esquí empieza a ~1.700 m). No es la nieve de un día concreto."],
    "gr8101": [1900, "Aproximación: en la Sierra de Baza la nieve de invierno suele quedarse por encima de ~1.800-2.000 m (Calar de Santa Bárbara 2.269 m). No es la nieve de un día concreto."],
    "a308": [1700, "Aproximación: por encima de ~1.600-1.800 m (Sierra Harana / Sierra Arana, más de 1.900 m). La A-308 va mucho más baja y casi nunca tiene nieve. No es la nieve de un día concreto."],
    "m406": [1550, "Aproximación: misma cota que el Guadarrama (~1.500-1.600 m en pleno invierno). La M-406 va a 600-700 m y en su entorno (25 km) no hay terreno tan alto, así que en invierno no se ve nieve aquí. No es la nieve de un día concreto."],
}


def get(url, params, timeout=90):
    for i in range(3):
        try:
            r = requests.get(url, params=params, headers=UA, timeout=timeout)
            if r.status_code == 200:
                return r.content
            err = f"HTTP {r.status_code} {r.content[:200]!r}"
        except requests.RequestException as ex:
            err = str(ex)
        time.sleep(2 + 3 * i)
    raise RuntimeError(err)


def orto(e0, n0, e1, n1, ancho, alto, destino, calidad, cache):
    src = os.path.join(cache, os.path.basename(os.path.dirname(os.path.dirname(destino))) + "_" + os.path.basename(destino) + f"_{ancho}x{alto}.png")
    if os.path.exists(src):
        img = Image.open(src)
    else:
        # el WMS del IGN da hasta 4096 px por lado
        img = Image.new("RGB", (ancho, alto))
        bloque = 2048
        for py in range(0, alto, bloque):
            for px in range(0, ancho, bloque):
                w = min(bloque, ancho - px); h = min(bloque, alto - py)
                ex0 = e0 + (e1 - e0) * px / ancho; ex1 = e0 + (e1 - e0) * (px + w) / ancho
                ny1 = n1 - (n1 - n0) * py / alto; ny0 = n1 - (n1 - n0) * (py + h) / alto
                b = get(WMS, {"SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetMap", "LAYERS": "OI.OrthoimageCoverage",
                              "STYLES": "", "CRS": "EPSG:25830", "BBOX": f"{ex0},{ny0},{ex1},{ny1}", "WIDTH": w, "HEIGHT": h,
                              "FORMAT": "image/jpeg"})
                if b[:2] != b"\xff\xd8":
                    raise RuntimeError(f"WMS no devolvió JPEG: {b[:200]!r}")
                img.paste(Image.open(io.BytesIO(b)).convert("RGB"), (px, py))
                print(f"  orto {destino.split('/')[-1]} {px},{py} ok", flush=True)
        img.save(src)
    img.save(destino, "JPEG", quality=calidad, optimize=True)
    # cada archivo del repo ≤ 3 MB: si la zona es grande o muy urbana (M-406), bajar la calidad JPEG (no la resolución)
    while os.path.getsize(destino) > 2_900_000 and calidad > 70:
        calidad -= 4
        img.save(destino, "JPEG", quality=calidad, optimize=True)
    print(f"  {destino.split('/')[-1]}: calidad JPEG {calidad}", flush=True)
    return os.path.getsize(destino)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zona", required=True)
    ap.add_argument("--margen", type=float, default=25.0)
    ap.add_argument("--cerca_px", type=int, default=4096)
    ap.add_argument("--lejos_px", type=int, default=2048)
    ap.add_argument("--cerca_m_px", type=float, default=4.9, help="m/píxel mínimos de la ortofoto de la zona (zonas grandes: menos px, archivo ≤ 3 MB)")
    ap.add_argument("--juego", default=os.path.join(BASE, "juego"))
    ap.add_argument("--cache", default=os.path.join(BASE, "cache", "paisaje"))
    a = ap.parse_args()
    dz = os.path.join(a.juego, "datos", a.zona)
    info = json.load(open(os.path.join(dz, "zona.json")))
    E0, N0 = info["origen_utm"]
    tz = info["terreno"]
    tes = tz["tesela"]
    xs = [t["x0"] for t in tz["teselas"]]; zs = [t["z0"] for t in tz["teselas"]]
    zx0, zx1, zz0, zz1 = min(xs), max(xs) + tes, min(zs), max(zs) + tes
    m = a.margen * 1000.0
    paso = 100.0
    rx0, rx1, rz0, rz1 = zx0 - m, zx1 + m, zz0 - m, zz1 + m
    os.makedirs(a.cache, exist_ok=True)
    out = os.path.join(dz, "paisaje"); os.makedirs(out, exist_ok=True)
    # --- relieve: vértices en múltiplos de 100 m → píxeles centrados en ellos
    e_a, e_b = E0 + rx0 - paso / 2, E0 + rx1 + paso / 2
    n_a, n_b = N0 - rz1 - paso / 2, N0 - rz0 + paso / 2
    tif = os.path.join(a.cache, f"{a.zona}_mdt25_100m_{int(a.margen)}.tif")
    if not os.path.exists(tif):
        b = get(WCS, {"SERVICE": "WCS", "VERSION": "2.0.1", "REQUEST": "GetCoverage", "COVERAGEID": "Elevacion25830_25",
                      "FORMAT": "image/tiff", "SUBSET": [f"x({e_a},{e_b})", f"y({n_a},{n_b})"], "SCALEFACTOR": "0.25"}, timeout=120)
        if b[:2] not in (b"II", b"MM"):
            raise RuntimeError(f"WCS: {b[:200]!r}")
        open(tif, "wb").write(b)
    with rasterio.open(tif) as s:
        h = s.read(1).astype(np.float32); tr = s.transform
    ni = int(round((rx1 - rx0) / paso)) + 1; nj = int(round((rz1 - rz0) / paso)) + 1
    # remuestreo a la malla exacta de vértices (bilineal sobre los centros de píxel)
    ee = E0 + rx0 + np.arange(ni) * paso; nn = N0 - (rz0 + np.arange(nj) * paso)
    cx = (ee - tr.c) / tr.a - 0.5; cy = (nn - tr.f) / tr.e - 0.5
    h[h < -100] = np.nan
    if np.isnan(h).any():   # mar / fuera de España: rellenar con el vecino válido (no debería pasar aquí)
        h = np.where(np.isnan(h), np.nanmin(h), h)
    x0i = np.clip(np.floor(cx).astype(int), 0, h.shape[1] - 2); fx = np.clip(cx - x0i, 0, 1)
    y0i = np.clip(np.floor(cy).astype(int), 0, h.shape[0] - 2); fy = np.clip(cy - y0i, 0, 1)
    H = (h[np.ix_(y0i, x0i)] * np.outer(1 - fy, 1 - fx) + h[np.ix_(y0i, x0i + 1)] * np.outer(1 - fy, fx)
         + h[np.ix_(y0i + 1, x0i)] * np.outer(fy, 1 - fx) + h[np.ix_(y0i + 1, x0i + 1)] * np.outer(fy, fx))
    dm = np.clip(np.round(H * 10.0), 0, 65535).astype("<u2")
    dm.tofile(os.path.join(out, "lejano.bin"))
    print(f"relieve {ni}x{nj} vértices a {paso:.0f} m, {H.min():.0f}–{H.max():.0f} m", flush=True)
    # --- ortofotos
    wz, hz = zx1 - zx0, zz1 - zz0
    cpx = min(a.cerca_px, int(max(wz, hz) / a.cerca_m_px / 4) * 4)
    if wz >= hz: cw, ch = cpx, int(round(cpx * hz / wz / 4) * 4)
    else: ch, cw = cpx, int(round(cpx * wz / hz / 4) * 4)
    s1 = orto(E0 + zx0, N0 - zz1, E0 + zx1, N0 - zz0, cw, ch, os.path.join(out, "orto_cerca.jpg"), 82, a.cache)
    wr, hr = rx1 - rx0, rz1 - rz0
    if wr >= hr: lw, lh = a.lejos_px, int(round(a.lejos_px * hr / wr / 4) * 4)
    else: lh, lw = a.lejos_px, int(round(a.lejos_px * wr / hr / 4) * 4)
    s2 = orto(E0 + rx0, N0 - rz1, E0 + rx1, N0 - rz0, lw, lh, os.path.join(out, "orto_lejos.jpg"), 85, a.cache)
    nieve = NIEVE.get(a.zona, [1800, "Aproximación genérica."])
    meta = {"zona": a.zona, "paso": paso, "ni": ni, "nj": nj, "x0": rx0, "z0": rz0,
            "marco_zona": [zx0, zz0, zx1, zz1], "marco_lejos": [rx0, rz0, rx1, rz1],
            "orto_cerca_px": [cw, ch], "orto_lejos_px": [lw, lh],
            "m_por_px_cerca": round(wz / cw, 2), "m_por_px_lejos": round(wr / lw, 1),
            "cota_nieve": nieve[0],
            "fuentes": {
                "relieve": "REAL: IGN MDT25 (CNIG, WCS servicios.idee.es Elevacion25830_25) remuestreado a 100 m por el servicio — CC BY 4.0 scne.es",
                "suelo": "REAL: IGN PNOA máxima actualidad (WMS www.ign.es/wms-inspire/pnoa-ma) — CC BY 4.0 scne.es; ~%.1f m/px en la zona, ~%.0f m/px en el entorno" % (wz / cw, wr / lw),
                "nieve": "SUPUESTO: " + nieve[1],
                "detalle_suelo": "SUPUESTO: textura de ruido procedural que solo varía el brillo de cerca (no añade información)",
                "cielo_niebla": "SUPUESTO: cielo y bruma genéricos de Godot (no es el tiempo real)"}}
    json.dump(meta, open(os.path.join(out, "paisaje.json"), "w"), ensure_ascii=False, indent=1)
    for f in sorted(os.listdir(out)):
        print(f"  {f}: {os.path.getsize(os.path.join(out, f)) / 1e6:.2f} MB")


if __name__ == "__main__":
    main()
