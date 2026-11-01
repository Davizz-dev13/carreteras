#!/usr/bin/env python3
"""Glorietas completas: añade a una zona ya generada los trozos de anillo que faltan.

extraer.py no saca como vía secundaria ninguna vía de OSM de la que una ruta haya usado algún tramo (ways_dibujadas).
Una glorieta que en OSM es una sola vía cerrada y que la ruta recorre en parte se quedaba solo con ese arco: el resto
del anillo no existía y las entradas acababan en el aire (p. ej. la de la M-607 con la M-617 en Navacerrada).
Aquí, para cada glorieta de OSM (junction=roundabout/circular) que toca la red del juego, los arcos que no pisa
ninguna calzada del juego se añaden como vías (con la anchura de OSM, extremos pegados al eje de la calzada a la que
llegan y altura interpolada entre los dos extremos). Reejecutable: primero quita lo que añadió la vez anterior.

Además guarda en carreteras.json ("glorietas") el eje cerrado de cada glorieta que toca la red, con su anchura y altura:
el juego dibuja con él un anillo continuo por debajo de los trozos (sin muescas donde se juntan).

Uso:  python pipeline/glorietas_completas.py --zona navacerrada
"""
import argparse, glob, json, os, sys
import numpy as np
from scipy.spatial import cKDTree

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rutas as R  # noqa: E402
import osm  # noqa: E402

CUBIERTO = 1.2     # una muestra del anillo a menos de esto del eje de una calzada del juego ya está
MIN_ARCO = 1.0     # arcos que faltan más cortos que esto no se añaden


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zona", required=True)
    ap.add_argument("--datos", default=os.path.join(RAIZ, "juego", "datos"))
    ap.add_argument("--cache", default=os.path.join(RAIZ, "cache", "osm"))
    a = ap.parse_args()
    d = os.path.join(a.datos, a.zona)
    zona = json.load(open(os.path.join(d, "zona.json")))
    s_, o_, n_, e_ = zona["bbox_wgs84"]
    E0, N0 = zona["origen_utm"]
    car = json.load(open(os.path.join(d, "carreteras.json")))
    car["vias"] = [v for v in car["vias"] if v.get("anadida") != "glorieta"]
    vias = list(car["vias"])
    for f in car.get("vias_archivos", []):
        vias += json.load(open(os.path.join(d, f)))["vias"]
    # puntos de eje de todas las calzadas del juego (cada ~2 m) con su altura
    lineas = [(np.array(r["x"]), np.array(r["z"]), np.array(r["y"])) for r in car["rutas"]]
    lineas += [(np.array(v["x"]), np.array(v["z"]), np.array(v["y"])) for v in vias if not int(v.get("tunel", 0))]
    anchos = [np.full(len(r["x"]), 0.0) + (np.array(r["ancho"]) if isinstance(r.get("ancho"), list) else float(r.get("ancho", 7.0))) for r in car["rutas"]]
    anchos += [np.full(len(v["x"]), float(v["ancho"])) for v in vias if not int(v.get("tunel", 0))]
    seg_a, seg_b, seg_y, seg_w = [], [], [], []
    for (x, z, y), w in zip(lineas, anchos):
        if len(x) < 2: continue
        seg_a.append(np.column_stack([x[:-1], z[:-1]])); seg_b.append(np.column_stack([x[1:], z[1:]]))
        seg_y.append(np.column_stack([y[:-1], y[1:]])); seg_w.append(w[:-1])
    seg_a = np.vstack(seg_a); seg_b = np.vstack(seg_b); seg_y = np.vstack(seg_y); seg_w = np.concatenate(seg_w)
    arbol = cKDTree((seg_a + seg_b) * 0.5)

    def mas_cercano(p):
        """punto más cercano sobre el eje de alguna calzada: (distancia, punto, altura)"""
        idx = arbol.query_ball_point(p, 25.0)
        if not idx: return 1e9, None, None, None
        A = seg_a[idx]; B = seg_b[idx]; ab = B - A; l2 = (ab ** 2).sum(1); l2[l2 < 1e-9] = 1e-9
        u = np.clip(((p - A) * ab).sum(1) / l2, 0, 1)
        q = A + ab * u[:, None]; dd = np.hypot(*(q - p).T); k = int(np.argmin(dd))
        return float(dd[k]), q[k], float(seg_y[idx[k], 0] + (seg_y[idx[k], 1] - seg_y[idx[k], 0]) * u[k]), float(seg_w[idx[k]])

    from pyproj import Transformer
    utm = Transformer.from_crs(4326, 25830, always_xy=True)
    glorietas = {}
    for f in sorted(glob.glob(os.path.join(a.cache, "*.json"))):
        try: datos = json.load(open(f))
        except Exception: continue
        if not isinstance(datos, dict): continue
        for el in datos.get("elements", []):
            t = el.get("tags", {})
            if el.get("type") != "way" or t.get("junction") not in ("roundabout", "circular") or "geometry" not in el:
                continue
            if not osm.es_carretera(t): continue
            g = el["geometry"]
            if not all(s_ <= p["lat"] <= n_ and o_ <= p["lon"] <= e_ for p in g): continue
            glorietas[el["id"]] = el
    # anillos: vías de glorieta que comparten nodos (una glorieta suele ser varias vías de OSM)
    ids = sorted(glorietas)
    padre = {w: w for w in ids}
    def raiz(w):
        while padre[w] != w:
            padre[w] = padre[padre[w]]; w = padre[w]
        return w
    por_nodo = {}
    for w in ids:
        for nd in glorietas[w]["nodes"]:
            if nd in por_nodo: padre[raiz(w)] = raiz(por_nodo[nd])
            else: por_nodo[nd] = w
    anillos = {}
    for w in ids: anillos.setdefault(raiz(w), []).append(w)
    nuevas = []
    n_anillos = 0
    anillos_juego = []

    def anillo_cerrado(ways):
        """Eje cerrado de la glorieta (sus vías de OSM encadenadas por nodos), cada 1,5 m, con la altura y la anchura de
        la calzada del juego más cercana. None si las vías no cierran un anillo."""
        resto = list(ways)
        cad = resto.pop(0)
        nodos = list(cad["nodes"]); geo = list(cad["geometry"])
        while resto and nodos[0] != nodos[-1]:
            for i, w in enumerate(resto):
                if w["nodes"][0] == nodos[-1]:
                    nodos += w["nodes"][1:]; geo += w["geometry"][1:]; resto.pop(i); break
                if w["nodes"][-1] == nodos[-1]:
                    nodos += w["nodes"][-2::-1]; geo += w["geometry"][-2::-1]; resto.pop(i); break
            else:
                return None
        if nodos[0] != nodos[-1] or len(geo) < 4:
            return None
        xs, ys = utm.transform([p["lon"] for p in geo], [p["lat"] for p in geo])
        xy = np.column_stack([np.array(xs) - E0, N0 - np.array(ys)])
        pts, _, _ = R.remuestrear(xy, 1.5)
        if np.hypot(*(pts[0] - pts[-1])) < 0.3:
            pts = pts[:-1]
        info = [mas_cercano(p) for p in pts]
        ok = [i for i in info if i[1] is not None and i[0] <= 3.0]
        if len(ok) < 0.5 * len(pts):
            return None
        hw = max(i[3] for i in ok) * 0.5
        ys_ok = np.array([i[2] if i[2] is not None else np.nan for i in info])
        malos = np.isnan(ys_ok)
        if malos.all():
            return None
        if malos.any():
            ys_ok[malos] = np.interp(np.nonzero(malos)[0], np.nonzero(~malos)[0], ys_ok[~malos])
        return {"x": np.round(pts[:, 0], 2).tolist(), "z": np.round(pts[:, 1], 2).tolist(), "y": np.round(ys_ok, 2).tolist(), "hw": round(hw, 2)}
    for grupo in anillos.values():
        muestras = []
        for wid in grupo:
            el = glorietas[wid]; g = el["geometry"]
            xs, ys = utm.transform([p["lon"] for p in g], [p["lat"] for p in g])
            xy = np.column_stack([np.array(xs) - E0, N0 - np.array(ys)])
            pts, _, _ = R.remuestrear(xy, 1.0)
            info = [mas_cercano(p) for p in pts]
            muestras.append((wid, el, pts, info))
        dist = np.concatenate([[i[0] for i in m[3]] for m in muestras])
        falta_todo = dist > CUBIERTO
        if not falta_todo.all():
            an = anillo_cerrado([glorietas[w] for w in grupo])
            if an is not None:
                anillos_juego.append(an)
        if not falta_todo.any() or falta_todo.all():
            continue        # entera en el juego, o ninguna parte toca la red del juego: no es nuestra
        n_anillos += 1
        for wid, el, pts, info in muestras:
            t = el["tags"]
            cerrada = el["nodes"][0] == el["nodes"][-1]
            dist = np.array([i[0] for i in info])
            falta = dist > CUBIERTO
            if not falta.any():
                continue
            n = len(pts)
            idx = np.arange(n)
            if cerrada and falta[0] and falta[-1] and not falta.all():
                idx = np.roll(idx, -int(np.argmin(falta)))
            f2 = falta[idx]
            k = 0
            while k < n:
                if not f2[k]: k += 1; continue
                j = k
                while j + 1 < n and f2[j + 1]: j += 1
                a0, a1 = max(k - 1, 0), min(j + 1, n - 1)       # una muestra cubierta a cada lado: llega a la calzada
                tramo = [idx[q] for q in range(a0, a1 + 1)]
                k = j + 1
                if len(tramo) < 2: continue
                P = pts[tramo].copy()
                L = float(np.hypot(*np.diff(P, axis=0).T).sum())
                if L < MIN_ARCO: continue
                ini, fin = info[tramo[0]], info[tramo[-1]]
                if ini[1] is not None and ini[0] <= CUBIERTO: P[0] = ini[1]
                if fin[1] is not None and fin[0] <= CUBIERTO: P[-1] = fin[1]
                # altura: la de la calzada a la que llega cada extremo (o la más cercana, a menos de 25 m)
                y0 = ini[2]; y1 = fin[2]
                if y0 is None and y1 is None:
                    # ningún extremo a menos de 25 m de una calzada del juego (un trozo de anillo que falta entero, lejos
                    # de las demás): la altura de la calzada más cercana, esté donde esté
                    _, kk = arbol.query(P.mean(0))
                    y0 = y1 = float(seg_y[kk].mean())
                if y0 is None: y0 = y1
                if y1 is None: y1 = y0
                P2, si, _ = R.remuestrear(P, 2.0)
                Y = y0 + (y1 - y0) * si / max(si[-1], 1e-6)
                nuevas.append({"x": np.round(P2[:, 0], 2).tolist(), "y": np.round(Y, 2).tolist(), "z": np.round(P2[:, 1], 2).tolist(),
                               "ancho": round(R.ancho_de(t), 2), "ref": t.get("ref", ""), "nombre": t.get("name", ""),
                               "tipo": R.tipo_base(t), "puente": 0, "tunel": 0, "anadida": "glorieta", "osm_id": wid})
                print(f"  glorieta {wid} ({t.get('name', '') or t.get('ref', '') or t.get('highway')}): arco de {L:.0f} m añadido")
    car["vias"] += nuevas
    # ejes cerrados de las glorietas: el juego (Cruces) pone debajo de los trozos de cada una un anillo continuo de
    # asfalto, sin muescas donde se juntan los trozos ni bordes en polígono
    car["glorietas"] = anillos_juego
    txt = json.dumps(car, separators=(",", ":"), ensure_ascii=False)
    assert len(txt.encode()) <= 3_000_000, f"carreteras.json pasaría de 3 MB ({len(txt.encode())} B)"
    open(os.path.join(d, "carreteras.json"), "w").write(txt)
    print(f"{a.zona}: {len(glorietas)} vías de glorieta de OSM en la zona ({len(anillos)} glorietas), {n_anillos} incompletas en el juego, {len(nuevas)} arcos añadidos, {len(anillos_juego)} anillos continuos")


if __name__ == "__main__":
    main()
