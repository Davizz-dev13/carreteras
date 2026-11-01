#!/usr/bin/env python3
"""Árboles donde de verdad hay bosque según ESA WorldCover 2021 (10 m, clase 10 «Tree cover»), para una zona vieja.
Escribe juego/datos/<zona>/paisaje/arboles/*.bin (mismo formato que arboles/: float32 x, y, z, escala por árbol; mismas
teselas de zona.json). Solo los usa la versión de escritorio con Gráficos alto (paisaje/ no se exporta a la web); la web y
Gráficos bajo siguen con arboles/ (bosques de OSM).
· Posiciones: cada píxel de 10 m con cubierta arbórea lleva un árbol con probabilidad P (a menos de 300 m de la ruta,
  lo que se ve conduciendo) o P_LEJOS (más lejos), desplazado al azar dentro del píxel (semilla fija). La DENSIDAD (≈ P · 100 árboles/ha) es una APROXIMACIÓN para que se lea como bosque sin hundir los FPS;
  no es un inventario forestal. La especie la decide el juego por altitud (aproximación).
· Nunca a menos de semiancho + 6 m de una calzada (rutas, vías y glorietas de la zona).
· Altura: la del terreno del juego (terreno/*.bin, 20 m), interpolada.
Datos: ESA WorldCover 10 m 2021 v200, © ESA WorldCover project / Contains modified Copernicus Sentinel data (2021),
CC BY 4.0, https://esa-worldcover.org  (lectura por ventana del COG público en S3).
Uso: python arboles_worldcover.py juego/datos/<zona> [P=0.35] [P_LEJOS=0.08]"""
import os, sys, json, math, glob
import numpy as np, rasterio
from rasterio.windows import from_bounds
from rasterio.warp import reproject, Resampling
from rasterio.transform import from_origin
from scipy.spatial import cKDTree
d = sys.argv[1]
P = float(sys.argv[2]) if len(sys.argv) > 2 else 0.35      # junto a la ruta (≤ BANDA m)
P_LEJOS = float(sys.argv[3]) if len(sys.argv) > 3 else 0.08
BANDA = 300.0
Z = json.load(open(os.path.join(d, "zona.json")))
E0, N0 = Z["origen_utm"]
lat0, lon0, lat1, lon1 = Z["bbox_wgs84"]
T = Z["terreno"]; PASO = T["paso"]; TES = T["tesela"]
xs0 = min(t["x0"] for t in T["teselas"]); zs0 = min(t["z0"] for t in T["teselas"])
xs1 = max(t["x0"] + (t["n"] - 1) * PASO for t in T["teselas"]); zs1 = max(t["z0"] + (t["m"] - 1) * PASO for t in T["teselas"])
R = 10.0
Emin, Emax, Nmin, Nmax = E0 + xs0, E0 + xs1, N0 - zs1, N0 - zs0
W = int(math.ceil((Emax - Emin) / R)); H = int(math.ceil((Nmax - Nmin) / R))
dst_tr = from_origin(Emin, Nmax, R, R)
clase = np.zeros((H, W), np.uint8)
m = 0.05
for la in range(int(math.floor((lat0 - m) / 3) * 3), int(math.floor((lat1 + m) / 3) * 3) + 1, 3):
    for lo in range(int(math.floor((lon0 - m) / 3) * 3), int(math.floor((lon1 + m) / 3) * 3) + 1, 3):
        nom = f"ESA_WorldCover_10m_2021_v200_{'N' if la >= 0 else 'S'}{abs(la):02d}{'E' if lo >= 0 else 'W'}{abs(lo):03d}_Map.tif"
        url = "/vsicurl/https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/" + nom
        with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif"):
            with rasterio.open(url) as src:
                w = from_bounds(max(lon0 - m, lo), max(lat0 - m, la), min(lon1 + m, lo + 3), min(lat1 + m, la + 3), src.transform)
                w = w.round_offsets().round_lengths()
                if w.width <= 0 or w.height <= 0: continue
                a = src.read(1, window=w)
                tmp = np.zeros_like(clase)
                reproject(a, tmp, src_transform=src.window_transform(w), src_crs=src.crs, dst_transform=dst_tr,
                          dst_crs="EPSG:25830", resampling=Resampling.nearest, src_nodata=0, dst_nodata=0)
                clase = np.where(tmp > 0, tmp, clase)
                print(nom, a.shape, flush=True)
arb = clase == 10
print(f"cubierta arbórea WorldCover: {100 * arb.mean():.1f} % de {W * H * R * R / 1e6:.0f} km²", flush=True)
rng = np.random.default_rng(11)
jj, ii = np.nonzero(arb & (rng.random(arb.shape) < P))   # candidatos a la densidad de cerca; se aclaran lejos de la ruta
E = Emin + (ii + rng.random(len(ii))) * R
N = Nmax - (jj + rng.random(len(jj))) * R
X = E - E0; Zc = N0 - N
# calzadas
C = json.load(open(os.path.join(d, "carreteras.json")))
pts, hw = [], []
for r in C["rutas"]:
    pts.append(np.column_stack([r["x"], r["z"]])); hw.append(np.asarray(r["ancho"], float) / 2)
for g in C.get("glorietas", []):
    pts.append(np.column_stack([g["x"], g["z"]])); hw.append(np.full(len(g["x"]), float(g["hw"])))
for f in C.get("vias_archivos", []):
    for v in json.load(open(os.path.join(d, f)))["vias"]:
        x = np.asarray(v["x"]); z = np.asarray(v["z"])
        # densificar a ≤ 4 m
        seg = np.hypot(np.diff(x), np.diff(z)); k = np.maximum(1, np.ceil(seg / 4).astype(int))
        xx = np.concatenate([np.linspace(x[i], x[i + 1], k[i], endpoint=False) for i in range(len(x) - 1)] + [x[-1:]])
        zz = np.concatenate([np.linspace(z[i], z[i + 1], k[i], endpoint=False) for i in range(len(z) - 1)] + [z[-1:]])
        pts.append(np.column_stack([xx, zz])); hw.append(np.full(len(xx), float(v["ancho"]) / 2))
pts = np.vstack(pts); hw = np.concatenate(hw)
kd = cKDTree(pts)
dd, k = kd.query(np.column_stack([X, Zc]), distance_upper_bound=40)
ok = ~np.isfinite(dd) | (dd > np.where(np.isfinite(dd), hw[np.minimum(k, len(hw) - 1)], 0) + 6.0)
X, Zc = X[ok], Zc[ok]
# densidad: P junto a la ruta (lo que se ve conduciendo), P_LEJOS más allá de BANDA m (se ve de lejos y en LOD)
rp = np.vstack([np.column_stack([r["x"], r["z"]]) for r in C["rutas"]])
dr, _ = cKDTree(rp).query(np.column_stack([X, Zc]), distance_upper_bound=BANDA + 200)
pk = np.where(dr <= BANDA, 1.0, np.where(dr <= BANDA + 200, 1.0 - (dr - BANDA) / 200 * (1 - P_LEJOS / P), P_LEJOS / P))
pk = np.where(np.isfinite(dr), pk, P_LEJOS / P)
keep = rng.random(len(X)) < pk
X, Zc = X[keep], Zc[keep]
esc = rng.uniform(0.7, 1.3, len(X))
total = 0
sal = os.path.join(d, "paisaje", "arboles")
os.makedirs(sal, exist_ok=True)
cuentas = {}
for t in T["teselas"]:
    sel = (X >= t["x0"]) & (X < t["x0"] + TES) & (Zc >= t["z0"]) & (Zc < t["z0"] + TES)
    x, z = X[sel], Zc[sel]
    b = np.fromfile(os.path.join(d, "terreno", t["nombre"] + ".bin"), "<f4").reshape(t["m"], t["n"])
    fi = np.clip((x - t["x0"]) / PASO, 0, t["n"] - 1.001); fj = np.clip((z - t["z0"]) / PASO, 0, t["m"] - 1.001)
    i0 = fi.astype(int); j0 = fj.astype(int); u = fi - i0; w = fj - j0
    y = (b[j0, i0] * (1 - u) * (1 - w) + b[j0, i0 + 1] * u * (1 - w) + b[j0 + 1, i0] * (1 - u) * w + b[j0 + 1, i0 + 1] * u * w)
    out = os.path.join(sal, t["nombre"] + ".bin")
    if os.path.exists(out): os.remove(out)      # nunca escribir encima (puede ser un enlace duro a otra copia)
    np.column_stack([x, y, z, esc[sel]]).astype("<f4").tofile(out)
    cuentas[t["nombre"]] = int(sel.sum()); total += int(sel.sum())
print(f"{total} árboles", flush=True)
fu = {"fuente": "ESA WorldCover 10 m 2021 v200 (clase 10, cubierta arbórea), © ESA WorldCover project / Contains modified "
                "Copernicus Sentinel data (2021), CC BY 4.0, https://esa-worldcover.org",
      "cubierta_arborea_pct": round(100 * float(arb.mean()), 1),
      "densidad": f"APROXIMADA: un árbol en el {round(P * 100)} % de los píxeles de 10 m con árboles a menos de {BANDA:.0f} m de la ruta "
                  f"y en el {round(P_LEJOS * 100)} % más lejos, siempre a más de 6 m de las calzadas; no es un inventario forestal",
      "especie": "la decide el juego por altitud (aproximación: pinos arriba, encinas/quejigos/olivos abajo)",
      "uso": "solo escritorio con Gráficos alto; la web y Gráficos bajo usan arboles/ (bosques de OSM)",
      "total": total, "teselas": cuentas}
fp = os.path.join(sal, "fuente.json")
if os.path.exists(fp): os.remove(fp)
json.dump(fu, open(fp, "w"), ensure_ascii=False, indent=1)
