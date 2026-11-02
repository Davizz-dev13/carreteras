#!/usr/bin/env python3
"""Comprueba cada STOP / ceda el paso de datos/<zona>/senales.json contra la geometría del juego (independiente de
cómo se generaron). Una señal está bien si:
  1. está a la derecha de una calzada (ruta, vía o anillo) que circula en el sentido al que mira (±30°), entre
     semiancho + 0,3 m y semiancho + 3,5 m del eje (en el arcén, no encima);
  2. siguiendo esa calzada en ese sentido hay un cruce entre 2 y 30 m: otra calzada que se cruza o en la que se entra
     (otra ruta, un anillo, una vía por su interior; no una vía que solo acaba en ella: ahí ella es la principal);
  3. el poste no está dentro de ninguna calzada;
  4. no hay otra señal mirando igual a < 15 m (duplicada);
  5. si OSM dice que esa calzada es de un solo sentido, el sentido es el de llegada (no es una salida).
Uso: python pipeline/senales_comprobar.py --zona m406 [--senales otro.json] [--osm_vias ...]
"""
import argparse, json, math, os, sys
import numpy as np
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from senales_cruces import Red, sentidos_osm, es_de_un_sentido, RAIZ


def polilineas(red):
    out = {}
    for ri, (xyz, an, dib) in enumerate(red.rutas):
        out[("r", ri)] = (xyz, an * 0.5)
    for vi, d in enumerate(red.vpts):
        if d is not None:
            out[("v", vi)] = (d, np.full(len(d), float(red.vias[vi]["ancho"]) * 0.5))
    for gi, g in enumerate(red.anillos):
        out[("g", gi)] = (g["d"], np.full(len(g["d"]), g["hw"]))
    return out


def comprobar(red, senales, ow):
    pol = polilineas(red)
    malas = []
    for si, s in enumerate(senales):
        r = float(s["rumbo"])
        f = np.array([math.sin(r), math.cos(r)])
        u = -f
        der = np.array([-u[1], u[0]])
        q = np.array([s["x"], s["z"]])
        # 1) calzada de la que es la señal
        cand = []
        for k in red.arbol.query_ball_point(q, 12.0):
            cand.append(red.dueno[k])
        mejor = None
        for du in set(cand):
            xyz, hw = pol[du]
            dd = np.hypot(xyz[:, 0] - q[0], xyz[:, 2] - q[1])
            i = int(np.argmin(dd))
            j0, j1 = max(i - 2, 0), min(i + 2, len(xyz) - 1)
            t = np.array([xyz[j1, 0] - xyz[j0, 0], xyz[j1, 2] - xyz[j0, 2]])
            t = t / (np.hypot(*t) + 1e-9)
            if abs(float(t @ u)) < math.cos(math.radians(30)):
                continue
            lat = float((q - xyz[i, [0, 2]]) @ der)
            if not (hw[i] + 0.3 <= lat <= hw[i] + 3.5):
                continue
            if mejor is None or dd[i] < mejor[0]:
                mejor = (dd[i], du, i, 1 if float(t @ u) > 0 else -1)
        if mejor is None:
            malas.append((si, "no está en el arcén derecho de ninguna calzada que circule hacia donde mira"))
            continue
        _, du, i, paso = mejor
        xyz, hw = pol[du]
        # 2) cruce delante
        rec, j, hallado = 0.0, i, None
        while rec <= 30.0:
            p = (xyz[j, 0], xyz[j, 2])
            for k in red.arbol.query_ball_point(p, 15.0):
                o = red.dueno[k]
                if o == du or (o[0] == "v" and abs(red.kidx[k]) < 6):
                    continue
                if o[0] == "r" and abs(float(red.T[k] @ u)) > 0.9:
                    continue      # otra ruta que va por la misma carretera
                # < 1,5 m: el remate del cruce (cruces.gd) cubre el hueco entre el final de la vía y la otra calzada
                if math.hypot(red.P[k, 0] - p[0], red.P[k, 2] - p[1]) - red.hw[k] < 1.5:
                    hallado = rec
                    break
            if hallado is not None or not (0 <= j + paso < len(xyz)):
                break
            rec += math.hypot(xyz[j + paso, 0] - xyz[j, 0], xyz[j + paso, 2] - xyz[j, 2])
            j += paso
        if hallado is None or not (2.0 <= hallado <= 30.0):
            malas.append((si, f"sin cruce delante a 2-30 m ({'ninguno' if hallado is None else round(hallado, 1)})"))
            continue
        # 3) fuera de la calzada
        b, quien = red.borde(q)
        if b < 0.0:
            malas.append((si, f"el poste está dentro de la calzada {quien}"))
            continue
        # 5) sentido único al revés
        if es_de_un_sentido(ow, xyz[i, [0, 2]], u) == -1:
            malas.append((si, "calzada de un solo sentido que sale del cruce"))
            continue
    # 4) duplicadas
    for a in range(len(senales)):
        for b_ in range(a + 1, len(senales)):
            sa, sb = senales[a], senales[b_]
            if math.hypot(sa["x"] - sb["x"], sa["z"] - sb["z"]) < 15.0 and math.cos(float(sa["rumbo"]) - float(sb["rumbo"])) > 0.7:
                malas.append((b_, "duplicada (< 15 m, misma orientación)"))
    return malas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zona", required=True)
    ap.add_argument("--senales")
    ap.add_argument("--osm_vias")
    ap.add_argument("--datos", default=os.path.join(RAIZ, "juego", "datos"))
    ap.add_argument("--ver", type=int, default=8)
    a = ap.parse_args()
    dz = os.path.join(a.datos, a.zona)
    zona = json.load(open(os.path.join(dz, "zona.json")))
    red = Red(dz)
    ow = sentidos_osm(a.osm_vias, *zona["origen_utm"])
    sen = json.load(open(a.senales or os.path.join(dz, "senales.json")))["senales"]
    malas = comprobar(red, sen, ow)
    motivos = Counter(m.split(" (")[0] if "cruce" not in m else m.split(" (")[0] for _, m in malas)
    print(f"{a.zona}: {len(sen)} señales · {len(malas)} incumplen · {dict(motivos)}")
    for si, m in malas[:a.ver]:
        s = sen[si]
        print(f"   {s['tipo']} x={s['x']} z={s['z']} rumbo={s['rumbo']}: {m}")


if __name__ == "__main__":
    main()
