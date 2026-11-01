#!/usr/bin/env python3
"""Saca de la calzada las señales (STOP / ceda) que senales.py dejó encima del asfalto de otra vía.

senales.py pone cada señal en el nodo de OSM, a la derecha de su vía (ancho/2 + 0,8 m). Cuando OSM mapea el STOP en
el propio cruce, eso cae dentro de la calzada de la vía principal o del ramal de al lado: el coche pasaba a través
de la señal. Aquí, solo para esas señales, se busca la vía a la que mira la señal (la que llega al cruce en su
sentido), y se retrasa por ella, metro a metro y como mucho MAX_RETRASO, hasta que el poste queda a ≥ 0,5 m de
cualquier calzada; a la derecha de quien llega, y si no cabe, a su izquierda (ramales de un solo sentido pegados
a la principal). La cara se orienta a la vía en ese punto. Las que ya estaban fuera no se tocan.

Uso:  python pipeline/senales_fuera_calzada.py --zona a308     (reescribe juego/datos/<zona>/senales.json)
"""
import argparse, json, math, os
import numpy as np
from scipy.spatial import cKDTree

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARGEN = 0.5        # m mínimos entre el poste y el borde de cualquier calzada
EN_CALZADA = 0.3    # una señal a menos de esto del borde (o dentro) se recoloca
MAX_RETRASO = 14    # m como mucho hacia atrás por su vía


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zona", required=True)
    ap.add_argument("--datos", default=os.path.join(RAIZ, "juego", "datos"))
    a = ap.parse_args()
    d = os.path.join(a.datos, a.zona)
    car = json.load(open(os.path.join(d, "carreteras.json")))
    vias = list(car.get("vias", []))
    for f in car.get("vias_archivos", []):
        vias += json.load(open(os.path.join(d, f)))["vias"]
    lineas = []   # (X, Z, Y, semiancho por punto)
    for r in car["rutas"]:
        lineas.append((np.array(r["x"]), np.array(r["z"]), np.array(r["y"]), np.array(r["ancho"]) / 2))
    for v in vias:
        if not v.get("tunel", 0):
            lineas.append((np.array(v["x"]), np.array(v["z"]), np.array(v["y"]), np.full(len(v["x"]), v["ancho"] / 2)))
    segs, dueno = [], []
    for li, (X, Z, _, HW) in enumerate(lineas):
        for k in range(len(X) - 1):
            segs.append((X[k], Z[k], X[k + 1], Z[k + 1], max(HW[k], HW[k + 1])))
            dueno.append(li)
    segs = np.array(segs)
    dueno = np.array(dueno)
    arbol = cKDTree(np.column_stack([(segs[:, 0] + segs[:, 2]) / 2, (segs[:, 1] + segs[:, 3]) / 2]))

    def al_borde(px, pz):
        mejor = 1e9
        for j in arbol.query_ball_point((px, pz), 30):
            ax, az, bx, bz, hw = segs[j]
            abx, abz = bx - ax, bz - az
            l2 = abx * abx + abz * abz
            if l2 < 1e-9:
                continue
            u = min(1.0, max(0.0, ((px - ax) * abx + (pz - az) * abz) / l2))
            mejor = min(mejor, math.hypot(px - ax - abx * u, pz - az - abz * u) - hw)
        return mejor

    def tangente(X, Z, k):
        t = np.array([X[min(k + 1, len(X) - 1)] - X[max(k - 1, 0)], Z[min(k + 1, len(X) - 1)] - Z[max(k - 1, 0)]])
        return t / (np.linalg.norm(t) + 1e-9)

    sen = json.load(open(os.path.join(d, "senales.json")))
    movidas, sin_sitio = 0, []
    for s in sen["senales"]:
        if al_borde(s["x"], s["z"]) >= EN_CALZADA:
            continue
        cara = np.array([math.sin(s["rumbo"]), math.cos(s["rumbo"])])
        marcha = -cara                       # quien llega mira la cara: circula hacia -cara
        mejor = None
        for li in set(int(dueno[j]) for j in arbol.query_ball_point((s["x"], s["z"]), 20)):
            X, Z, Y, HW = lineas[li]
            dist = np.hypot(X - s["x"], Z - s["z"])
            k = int(dist.argmin())
            al = float(tangente(X, Z, k) @ marcha)
            if dist[k] > 15 or abs(al) < 0.8:
                continue
            if mejor is None or dist[k] - HW[k] < mejor[0]:
                mejor = (dist[k] - HW[k], li, k, 1 if al > 0 else -1)
        hecho = False
        if mejor is not None:
            _, li, k, sg = mejor
            X, Z, Y, HW = lineas[li]
            for lado in (1, -1):              # derecha de quien llega; si no cabe, izquierda
                s_acum, kk = 0.0, k
                while 0 <= kk < len(X) and s_acum <= MAX_RETRASO:
                    dt = tangente(X, Z, kk) * sg
                    der = np.array([-dt[1], dt[0]]) * lado
                    p = np.array([X[kk], Z[kk]]) + der * (HW[kk] + 0.8)
                    if al_borde(p[0], p[1]) >= MARGEN:
                        s.update({"x": round(float(p[0]), 2), "z": round(float(p[1]), 2), "y": round(float(Y[kk]), 2),
                                  "rumbo": round(math.atan2(-dt[0], -dt[1]), 3), "recolocada": "fuera de la calzada"})
                        hecho = True
                        break
                    kk2 = kk - sg
                    if 0 <= kk2 < len(X):
                        s_acum += math.hypot(X[kk2] - X[kk], Z[kk2] - Z[kk])
                    kk = kk2
                if hecho:
                    break
        if hecho:
            movidas += 1
        else:
            sin_sitio.append(s.get("osm"))
    sen["recolocadas_fuera_de_calzada"] = movidas
    json.dump(sen, open(os.path.join(d, "senales.json"), "w"), ensure_ascii=False, indent=0)
    print(f"{movidas} señales sacadas de la calzada; sin sitio (se dejan): {sin_sitio}")


if __name__ == "__main__":
    main()
