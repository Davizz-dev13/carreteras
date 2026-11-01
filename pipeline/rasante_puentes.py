#!/usr/bin/env python3
"""Rasante de los puentes (y túneles) de las vías secundarias de una zona, sobre los datos ya generados.

extraer.py procesa cada vía de OSM por separado. Una vía que es entera un puente (bridge=yes) no tiene terreno a los
lados del que interpolar, así que su rasante salía del MDT: el tablero bajaba al fondo del barranco (hasta 5 m) y
dejaba un escalón de 1-2 m con la vía que llega a cada estribo; un paso elevado sobre la A-92 quedaba a 1,4 m de la
autovía. Aquí cada puente/túnel pasa a ser la recta entre las alturas de las vías que llegan a sus dos extremos
(si solo llega una por un lado, se desplaza para empalmar con ella). No cambia nada en planta.

Uso:  python pipeline/rasante_puentes.py --zona a308      (reescribe juego/datos/<zona>/vias_*.json o carreteras.json)
"""
import argparse, json, os
import numpy as np
from scipy.spatial import cKDTree

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zona", required=True)
    ap.add_argument("--datos", default=os.path.join(RAIZ, "juego", "datos"))
    a = ap.parse_args()
    d = os.path.join(a.datos, a.zona)
    car = json.load(open(os.path.join(d, "carreteras.json")))
    archivos = car.get("vias_archivos", [])
    partes = [json.load(open(os.path.join(d, f)))["vias"] for f in archivos]
    vias = [v for p in partes for v in p] + car.get("vias", [])
    ext = []
    for vi, v in enumerate(vias):
        ext.append((v["x"][0], v["z"][0], vi, 0))
        ext.append((v["x"][-1], v["z"][-1], vi, 1))
    arbol = cKDTree(np.array([(e[0], e[1]) for e in ext]))

    def altura_llegada(vi, lado):
        v = vias[vi]
        p = (v["x"][0], v["z"][0]) if lado == 0 else (v["x"][-1], v["z"][-1])
        hs = []
        for k in arbol.query_ball_point(p, 1.0):
            _, _, vj, ej = ext[k]
            w = vias[vj]
            if vj != vi and not w.get("puente", 0) and not w.get("tunel", 0):
                hs.append(w["y"][0] if ej == 0 else w["y"][-1])
        return float(np.mean(hs)) if hs else None

    n = 0
    for vi, v in enumerate(vias):
        if not (v.get("puente", 0) or v.get("tunel", 0)) or len(v["x"]) < 2:
            continue
        x, z, y = np.array(v["x"]), np.array(v["z"]), np.array(v["y"], float)
        s = np.concatenate([[0], np.cumsum(np.hypot(np.diff(x), np.diff(z)))])
        f = s / max(s[-1], 1e-6)
        ya, yb = altura_llegada(vi, 0), altura_llegada(vi, 1)
        if ya is not None and yb is not None:
            nuevo = ya + (yb - ya) * f
        elif ya is not None:
            nuevo = y + (ya - y[0]) * (1 - f)
        elif yb is not None:
            nuevo = y + (yb - y[-1]) * f
        else:
            continue
        print(f"  {'puente' if v.get('puente') else 'túnel'} {v.get('ref') or v.get('nombre') or v.get('tipo')} "
              f"({s[-1]:.0f} m): máx. cambio {np.abs(nuevo - y).max():.2f} m")
        v["y"] = np.round(nuevo, 2).tolist()
        n += 1
    for f, p in zip(archivos, partes):
        json.dump({"vias": p}, open(os.path.join(d, f), "w"), ensure_ascii=False, separators=(",", ":"))
    if car.get("vias"):
        json.dump(car, open(os.path.join(d, "carreteras.json"), "w"), ensure_ascii=False, separators=(",", ":"))
    print(f"{n} puentes/túneles de vías secundarias con rasante recta entre sus estribos")


if __name__ == "__main__":
    main()
