#!/usr/bin/env python3
"""Señales de tráfico REALES junto a las rutas de una zona, sacadas de OpenStreetMap (nada inventado).

Entran los nodos highway=stop / highway=give_way y traffic_sign=ES:R2 (STOP) / ES:R1 (ceda el paso) a ≤ 30 m del
eje de una ruta. Casi todos están en la vía secundaria que llega al cruce (es donde OSM los pone): la señal se
coloca a la derecha de esa vía (ancho/2 + 0,8 m), mirando a quien llega al cruce por ella. Un nodo que ya es una
señal suelta (traffic_sign fuera del eje) conserva su posición real. Se quitan duplicados (el mismo STOP mapeado
como highway=stop y como traffic_sign=ES:R2, ≤ 20 m y mismo sentido). Un nodo del cruce (compartido con la vía que llega, ≤ 4 m)
cuenta como de la vía. Los nodos que están sobre la propia ruta no
dicen para qué sentido son sin la vía de OSM: no se ponen (se cuentan). Las demás señales (S800, paneles de
mensaje variable, …) se cuentan pero no se dibujan. Los límites de velocidad ya los muestra el juego en el panel
(limites_velocidad.json); OSM no tiene señales R301 sueltas en estas zonas.

Uso:  python pipeline/senales.py --zona navacerrada        (Overpass, con caché en cache/osm/<zona>_senales.json)
      python pipeline/senales.py --zona a308 --osm respuesta_overpass.json
      python pipeline/senales.py --zona navacerrada --atlas   (además redibuja juego/modelos/senales_es.png)
Salida: juego/datos/<zona>/senales.json  ·  [{tipo: "R1"|"R2", x, y, z, rumbo}] con rumbo = ángulo (rad, eje Y)
hacia el que mira la cara de la señal. Coordenadas del pipeline (EPSG:25830, X = E − E0, Z = N0 − N).
"""
import argparse, json, math, os, sys, time
from collections import Counter
import numpy as np
import requests
from pyproj import Transformer
from scipy.spatial import cKDTree

sys.path.insert(0, os.path.dirname(__file__))
import osm

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_RUTA = 30.0      # m del eje de una ruta
EN_EJE = 1.5         # m: un nodo a menos de esto del eje de su vía está "sobre la vía"
DUP = 20.0           # m entre dos señales iguales del mismo sentido → una


def consulta(bbox, timeout=50):
    s, o, n, e = bbox
    b = f"{s},{o},{n},{e}"
    return (f'[out:json][timeout:{timeout}];(node["traffic_sign"]({b});'
            f'node["highway"~"^(stop|give_way)$"]({b});)->.s;.s out body;way(bn.s)["highway"];out geom;')


def descargar(bbox, cache):
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    if os.path.exists(cache):
        return json.load(open(cache))
    ultimo = None
    for url in osm.OVERPASS + osm.OVERPASS[:1]:
        try:
            r = requests.post(url, data={"data": consulta(bbox)}, headers=osm.UA, timeout=60)
            r.raise_for_status()
            d = r.json()
            json.dump(d, open(cache, "w"))
            return d
        except Exception as ex:
            ultimo = ex
            print("  Overpass", url, "falló:", ex)
            time.sleep(3)
    raise SystemExit(f"Overpass no respondió: {ultimo}")


def tipo_de(tags):
    ts = tags.get("traffic_sign", "")
    for c in ts.replace(",", ";").split(";"):
        c = c.strip()
        if c in ("ES:R2", "ES:R-2"): return "R2", True
        if c in ("ES:R1", "ES:R-1"): return "R1", True
    if tags.get("highway") == "stop": return "R2", False
    if tags.get("highway") == "give_way": return "R1", False
    return None, False


def densificar(x, y, z, paso=2.0):
    p = np.c_[x, y, z].astype(float)
    out = [p[0]]
    for a, b in zip(p[:-1], p[1:]):
        L = math.hypot(b[0] - a[0], b[2] - a[2])
        k = max(int(L // paso), 1)
        for j in range(1, k + 1):
            out.append(a + (b - a) * j / k)
    return np.array(out)


def dibujar_atlas(fp, lado=256):
    """Texturas de las señales (dibujadas aquí, sin imágenes de terceros): STOP (R2) y ceda el paso (R1), con sus
    traseras grises, en un atlas de 2 × 2 celdas. Colores y proporciones de la norma 8.1-IC simplificados."""
    from PIL import Image, ImageDraw, ImageFont
    S = 4                       # supermuestreo para bordes suaves
    c = lado // 2 * S
    im = Image.new("RGBA", (lado * S, lado * S), (0, 0, 0, 0))
    dr = ImageDraw.Draw(im)
    rojo, blanco, gris = (190, 22, 34, 255), (245, 245, 245, 255), (128, 131, 134, 255)

    def octogono(cx, cy, r):
        return [(cx + r * math.cos(math.radians(22.5 + 45 * i)), cy + r * math.sin(math.radians(22.5 + 45 * i))) for i in range(8)]

    def triangulo(cx, cy, r):          # con el vértice abajo (R1)
        return [(cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))) for a in (90, 210, 330)]

    m = c // 2
    dr.polygon(octogono(m, m, c * 0.47), fill=blanco)
    dr.polygon(octogono(m, m, c * 0.43), fill=rojo)
    fuente = None
    for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf"):
        if os.path.exists(f):
            fuente = ImageFont.truetype(f, int(c * 0.25)); break
    dr.text((m, m), "STOP", fill=blanco, font=fuente, anchor="mm")
    dr.polygon(octogono(c + m, m, c * 0.47), fill=gris)
    dr.polygon(triangulo(m, c + m * 0.86, c * 0.49), fill=rojo)
    dr.polygon(triangulo(m, c + m * 0.86, c * 0.30), fill=blanco)
    dr.polygon(triangulo(c + m, c + m * 0.86, c * 0.49), fill=gris)
    dr.rectangle([c + m - 8 * S, m - 8 * S, c + m + 8 * S, m + 8 * S], fill=gris)   # gris para el poste
    im.resize((lado, lado), Image.LANCZOS).save(fp)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zona", required=True)
    ap.add_argument("--osm", help="respuesta Overpass ya descargada (JSON)")
    ap.add_argument("--datos", default=os.path.join(RAIZ, "juego", "datos"))
    ap.add_argument("--cache", default=os.path.join(RAIZ, "cache"))
    ap.add_argument("--atlas", action="store_true", help="dibuja también juego/modelos/senales_es.png")
    a = ap.parse_args()
    if a.atlas:
        dibujar_atlas(os.path.join(RAIZ, "juego", "modelos", "senales_es.png"))
    dz = os.path.join(a.datos, a.zona)
    zona = json.load(open(os.path.join(dz, "zona.json")))
    car = json.load(open(os.path.join(dz, "carreteras.json")))
    vias = list(car.get("vias", []))
    for nombre in car.get("vias_archivos", []):
        vias += json.load(open(os.path.join(dz, nombre))).get("vias", [])
    E0, N0 = zona["origen_utm"]
    d = json.load(open(a.osm)) if a.osm else descargar(zona["bbox_wgs84"], os.path.join(a.cache, "osm", f"{a.zona}_senales.json"))
    nodos = [e for e in d.get("elements", []) if e.get("type") == "node"]

    # ejes: rutas (solo lo que se dibuja) y vías secundarias, muestreados cada ~2 m
    P, info = [], []      # info: (es_ruta, id, ancho)
    ruta_pts = []
    for ri, r in enumerate(car["rutas"]):
        dib = np.asarray(r["dibujar"])
        xyz = np.c_[r["x"], r["y"], r["z"]]
        ok = np.flatnonzero(dib == 1)
        ruta_pts.append(xyz[ok][:, [0, 2]])
        for i in ok:
            P.append(xyz[i]); info.append((1, ri, float(r["ancho"][i])))
    for vi, v in enumerate(vias):
        if v.get("tunel", 0) == 1 or len(v["x"]) < 2:
            continue
        for p in densificar(v["x"], v["y"], v["z"]):
            P.append(p); info.append((0, vi, float(v["ancho"])))
    P = np.array(P)
    arbol = cKDTree(P[:, [0, 2]])
    solo_vias = np.flatnonzero([i[0] == 0 for i in info])
    arbol_vias = cKDTree(P[solo_vias][:, [0, 2]]) if solo_vias.size else None
    arbol_ruta = cKDTree(np.vstack(ruta_pts))
    anchos_ruta = np.concatenate([np.asarray(r["ancho"])[np.asarray(r["dibujar"]) == 1] for r in car["rutas"]])

    utm = Transformer.from_crs(4326, 25830, always_xy=True)

    def a_juego(lon, lat):
        E, N = utm.transform(lon, lat)
        return np.c_[np.asarray(E) - E0, N0 - np.asarray(N)]

    # vías de OSM que contienen cada nodo de señal (la consulta las trae con su geometría)
    padres = {}
    for w in d.get("elements", []):
        if w.get("type") != "way" or "geometry" not in w:
            continue
        g = a_juego([p["lon"] for p in w["geometry"]], [p["lat"] for p in w["geometry"]])
        dr_w, kr_w = arbol_ruta.query(g)
        w["_g"] = g
        w["_es_ruta"] = bool(np.mean(dr_w < anchos_ruta[kr_w] * 0.5 + 2.0) > 0.7)   # la vía ES la ruta
        for i, nid in enumerate(w.get("nodes", [])):
            padres.setdefault(nid, []).append((w, i))

    def punto_a(g, i, dist):
        """Punto a `dist` m por la polilínea g desde el vértice i (dist < 0: hacia atrás)."""
        paso = 1 if dist > 0 else -1
        resto = abs(dist)
        p = g[i]
        j = i
        while 0 <= j + paso < len(g):
            q = g[j + paso]
            L = float(np.hypot(*(q - p)))
            if L >= resto:
                return p + (q - p) * (resto / max(L, 1e-9))
            resto -= L
            p = q
            j += paso
        return p

    todos_ruta = np.vstack(ruta_pts)
    tg_ruta = []
    for r in car["rutas"]:
        x = np.asarray(r["x"], float); z = np.asarray(r["z"], float)
        tx = np.gradient(x); tz = np.gradient(z); n_ = np.hypot(tx, tz) + 1e-9
        ok = np.asarray(r["dibujar"]) == 1
        tg_ruta.append(np.c_[tx / n_, tz / n_][ok])
    tg_ruta = np.vstack(tg_ruta)

    cuenta = Counter()
    cand = []
    for e in nodos:
        t = e.get("tags", {})
        tipo, suelta = tipo_de(t)
        q = a_juego(e["lon"], e["lat"])[0]
        dr, kr = arbol_ruta.query(q)
        if dr > MAX_RUTA:
            cuenta["lejos_de_las_rutas"] += 1
            continue
        if tipo is None:
            cuenta["otro_tipo:" + (t.get("traffic_sign") or t.get("highway", "?"))] += 1
            continue
        ps = padres.get(e["id"], [])
        lado_vias = [(w, i) for w, i in ps if not w["_es_ruta"]]
        sobre_ruta = [(w, i) for w, i in ps if w["_es_ruta"]]
        llega = None
        ancho = 6.0
        pos = None
        if lado_vias:
            # señal de la vía que llega al cruce: se circula hacia el extremo más cercano a la ruta
            w, i = lado_vias[0]
            g = w["_g"]
            a_, b_ = punto_a(g, i, 6.0), punto_a(g, i, -6.0)
            da, _ = arbol_ruta.query(a_)
            db, _ = arbol_ruta.query(b_)
            arriba = b_ if da < db else a_            # de donde viene quien llega al cruce
            v = g[i] - arriba if np.hypot(*(g[i] - arriba)) > 0.5 else (a_ if da < db else b_) - g[i]
            llega = v / (np.hypot(*v) + 1e-9)
            dv, kv = (arbol_vias.query(q) if arbol_vias is not None else (99.0, 0))
            ancho = info[int(solo_vias[kv])][2] if dv < 8.0 else 6.0
            base = q
            cuenta["en_via_que_llega"] += 1
        elif sobre_ruta:
            # nodo sobre la propia ruta: solo si OSM dice el sentido (direction=forward/backward de la vía)
            dirn = (t.get("direction") or "").lower()
            if dirn not in ("forward", "backward"):
                cuenta["sobre_la_ruta_sin_sentido"] += 1
                continue
            w, i = sobre_ruta[0]
            g = w["_g"]
            v = punto_a(g, i, 3.0) - punto_a(g, i, -3.0)
            llega = v / (np.hypot(*v) + 1e-9) * (1.0 if dirn == "forward" else -1.0)
            ancho = float(anchos_ruta[kr])
            base = todos_ruta[kr]
            cuenta["sobre_la_ruta_con_sentido"] += 1
        else:
            # señal suelta (sin vía): conserva su posición; mira al tráfico del lado en que está (se circula por la derecha)
            dist, k = arbol.query(q)
            es_r, vid, ancho = info[k]
            if dist > 15.0:
                cuenta["sin_via_cerca"] += 1
                continue
            idx = [j for j in arbol.query_ball_point(P[k, [0, 2]], 4.0) if info[j][:2] == (es_r, vid)]
            pts = P[idx][:, [0, 2]]
            if len(pts) < 2:
                cuenta["via_demasiado_corta"] += 1
                continue
            tg = np.linalg.svd(pts - pts.mean(0))[2][0]
            der_tg = np.array([-tg[1], tg[0]])
            llega = tg if float((q - P[k, [0, 2]]) @ der_tg) > 0 else -tg
            base = q
            pos = q
            cuenta["suelta"] += 1
        der = np.array([-llega[1], llega[0]])         # derecha de quien llega, en Godot (X, Z)
        if pos is None:
            pos = base + der * (ancho * 0.5 + 0.8) if not (suelta and dr > EN_EJE + ancho * 0.5) else q
        # no dentro de la calzada de una ruta: se retrasa hasta quedar fuera (máx. 15 m)
        ok = False
        for _ in range(16):
            dd, kk = arbol_ruta.query(pos)
            if dd > anchos_ruta[kk] * 0.5 + 0.8 or (sobre_ruta and not lado_vias):
                ok = True
                break
            pos = pos - llega * 1.0
        if not ok:
            cuenta["no_cabe_fuera_de_la_calzada"] += 1
            continue
        _, kp = arbol.query(pos)
        y = float(P[kp, 1])
        rumbo = math.atan2(-llega[0], -llega[1])        # la cara mira a quien llega
        cand.append({"tipo": tipo, "x": round(float(pos[0]), 2), "y": round(y, 2), "z": round(float(pos[1]), 2),
                     "rumbo": round(rumbo, 3), "suelta": suelta and not ps, "osm": e["id"], "_f": -llega})
    # duplicados: misma clase, ≤ DUP m, mismo sentido → se queda la señal suelta (posición real)
    cand.sort(key=lambda c: not c["suelta"])
    finales = []
    for c in cand:
        if any(f["tipo"] == c["tipo"] and math.hypot(f["x"] - c["x"], f["z"] - c["z"]) < DUP and float(np.dot(f["_f"], c["_f"])) > 0.7 for f in finales):
            cuenta["duplicada"] += 1
            continue
        finales.append(c)
    for f in finales:
        del f["_f"]
    finales.sort(key=lambda f: (f["x"], f["z"]))
    est = {"nodos_osm_zona": len(nodos), "puestas": len(finales), "por_tipo": dict(Counter(f["tipo"] for f in finales)),
           "descartes": dict(cuenta)}
    salida = {"zona": a.zona, "fuente": "© colaboradores de OpenStreetMap (ODbL), vía Overpass API: highway=stop/give_way y traffic_sign=ES:R1/ES:R2",
              "descargado": time.strftime("%Y-%m-%d %H:%M"),
              "rumbo": "ángulo en radianes alrededor de Y (Godot) hacia el que mira la cara de la señal",
              "senales": finales, "estadisticas": est}
    fp = os.path.join(dz, "senales.json")
    json.dump(salida, open(fp, "w"), ensure_ascii=False, indent=0)
    print(f"{a.zona}: {len(nodos)} nodos de señal en OSM · puestas {len(finales)} {est['por_tipo']} · descartes {dict(cuenta)}")
    print(f"escrito {fp} ({os.path.getsize(fp)} B)")


if __name__ == "__main__":
    main()
