#!/usr/bin/env python3
"""Gráficos de comprobación: perfil de altitud y mapa (relieve + carreteras) de una zona extraída.
  python pipeline/graficos.py --zona navacerrada --salida ../files
"""
import argparse, json, os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LightSource
from matplotlib.collections import LineCollection

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zona", required=True); ap.add_argument("--ruta", type=int, default=0)
    ap.add_argument("--salida", default=os.path.join(RAIZ, "graficos"))
    a = ap.parse_args()
    d = os.path.join(RAIZ, "juego", "datos", a.zona)
    zona = json.load(open(os.path.join(d, "zona.json")))
    car = json.load(open(os.path.join(d, "carreteras.json")))
    r = car["rutas"][a.ruta]; st = r["estadisticas"]
    os.makedirs(a.salida, exist_ok=True)
    s = np.arange(len(r["y"])) * r["paso"] / 1000; z = np.array(r["y"]); g = np.array(r["pendiente"])

    # --- perfil ---
    fig, ax = plt.subplots(figsize=(13, 5.2), dpi=110)
    pts = np.column_stack([s, z]); seg = np.stack([pts[:-1], pts[1:]], axis=1)
    gs = np.convolve(g, np.ones(50) / 50, mode="same")  # pendiente media en 100 m para colorear
    lc = LineCollection(seg, cmap="RdYlGn_r", norm=plt.Normalize(-11, 11), linewidths=3)
    lc.set_array(gs[:-1]); ax.add_collection(lc)
    ax.fill_between(s, z.min() - 60, z, color="#d9d4c7", zorder=0)
    ax.set_xlim(0, s[-1]); ax.set_ylim(z.min() - 60, z.max() + 80)
    cb = fig.colorbar(lc, ax=ax, pad=0.01); cb.set_label("pendiente media 100 m (%)")
    i = int(np.argmax(z))
    ax.annotate(f"Puerto {z[i]:.0f} m (km {s[i]:.1f})", (s[i], z[i]), (s[i] - 4, z[i] + 40),
                arrowprops=dict(arrowstyle="->"), fontsize=10)
    for km in range(0, int(s[-1]) + 1, 2):
        k = min(int(km * 1000 / r["paso"]), len(z) - 1)
        ax.text(km, z.min() - 50, f"{z[k]:.0f}", fontsize=7, ha="center", color="#555")
    ax.set_xlabel("km"); ax.set_ylabel("altitud (m)")
    ax.set_title(f"{r['nombre']} — perfil real (OSM + {zona['mdt'].split(' (')[0]}), escala 1:1\n"
                 f"{st['longitud_km']:.1f} km · {st['alt_min']:.0f}–{st['alt_max']:.0f} m · +{st['desnivel_subida']:.0f} m / "
                 f"−{st['desnivel_bajada']:.0f} m · pendiente máx (100 m) {abs(st['pendiente_max_100m']):.1f} % · "
                 f"(1 km) {abs(st['pendiente_max_1km']):.1f} %", fontsize=11)
    ax.grid(alpha=0.3); fig.tight_layout()
    fig.savefig(os.path.join(a.salida, "carreteras_perfil.png")); plt.close(fig)

    # --- mapa: relieve sombreado + red + ruta ---
    H = np.load(os.path.join(RAIZ, "cache", f"{a.zona}_terreno.npy"))
    ter = zona["terreno"]; t0 = ter["teselas"][0]
    x0, z0 = t0["x0"], t0["z0"]; p = ter["paso"]
    ext = [x0 / 1000, (x0 + (H.shape[1] - 1) * p) / 1000, -(z0 + (H.shape[0] - 1) * p) / 1000, -z0 / 1000]
    ls = LightSource(azdeg=315, altdeg=40)
    rgb = ls.shade(H, cmap=plt.cm.gist_earth, vert_exag=2, blend_mode="soft", dx=p, dy=p,
                   vmin=H.min() - 300, vmax=H.max() + 200)
    fig, ax = plt.subplots(figsize=(8, 12), dpi=110)
    ax.imshow(rgb, extent=ext, origin="upper")
    for v in car["vias"]:
        ax.plot(np.array(v["x"]) / 1000, -np.array(v["z"]) / 1000, color="#ffffff", lw=0.7, alpha=0.8)
    for k, rr in enumerate(car["rutas"]):
        if k == a.ruta: continue
        ax.plot(np.array(rr["x"]) / 1000, -np.array(rr["z"]) / 1000, color="#f4d03f", lw=1.3)
    ax.plot(np.array(r["x"]) / 1000, -np.array(r["z"]) / 1000, color="#e8202a", lw=2.4, label=r["nombre"])
    ax.plot(r["x"][0] / 1000, -r["z"][0] / 1000, "o", color="w", mec="k"); ax.text(r["x"][0] / 1000 + .2, -r["z"][0] / 1000, "salida", color="w")
    cs = ax.contour(np.linspace(ext[0], ext[1], H.shape[1]), np.linspace(ext[3], ext[2], H.shape[0]), H,
                    levels=np.arange(1000, 2500, 100), colors="k", linewidths=0.3, alpha=0.4)
    ax.clabel(cs, fontsize=6, fmt="%d")
    ax.set_xlabel(f"km Este (origen UTM30N {zona['origen_utm'][0]:.0f})")
    ax.set_ylabel(f"km Norte (origen {zona['origen_utm'][1]:.0f})")
    ax.set_title(f"Zona {zona['zona']}: red OSM sobre MDT 1:1\nrojo: {r['nombre']} · amarillo: otras rutas · blanco: resto de vías", fontsize=10)
    ax.legend(loc="lower left", fontsize=8); fig.tight_layout()
    fig.savefig(os.path.join(a.salida, "carreteras_mapa.png")); plt.close(fig)
    print("ok", a.salida)


if __name__ == "__main__":
    main()
