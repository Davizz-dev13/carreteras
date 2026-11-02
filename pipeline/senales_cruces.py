#!/usr/bin/env python3
"""STOP y ceda el paso solo donde tienen sentido (sustituye a senales.py + senales_fuera_calzada.py).

Qué hacía mal lo anterior (senales.py): tomaba cada nodo highway=stop/give_way de OSM a ≤ 30 m de la ruta y lo
colocaba junto a la vía de OSM que pasaba por él, sin comprobar que esa vía fuese la que LLEGA a un cruce del juego
(ni que en el juego la vía exista y acabe en la ruta, en otra vía o en una glorieta). Resultado: señales a media
recta, en la propia ruta (nodos con direction=forward/backward), mirando a quien sale del cruce, y señales sueltas
reorientadas «al lado en que estaban». senales_fuera_calzada.py luego las arrastraba hasta 14 m por cualquier vía para
sacarlas del asfalto. Las glorietas no tenían ningún ceda el paso propio y no se pintaba ninguna línea.

Ahora una señal solo existe en un ACCESO del juego: el extremo de una vía secundaria que entra en la ruta, en otra vía
(por su interior) o en el anillo de una glorieta, o la entrada de la ruta al arco de una glorieta. Reglas:
  · entrada a glorieta (anillo de carreteras.json "glorietas"): ceda el paso (R1) siempre, solo en el sentido que
    entra (las vías de un solo sentido según OSM que salen del anillo no llevan nada);
  · cruce normal: solo si OSM tiene highway=stop/give_way (o traffic_sign=ES:R1/R2) en esa vía, a ≤ 40 m del extremo
    y, si el nodo lleva direction=forward/backward, para el sentido que llega al cruce;
  · nunca en la vía principal, nunca a media recta, nunca duplicadas (≤ 15 m en el mismo acceso).
Con cada señal se pinta su marca: línea de detención (STOP, continua, 40 cm) o línea de ceda el paso (M-4.2: trazos de
80 cm con huecos de 40 cm, 40 cm de ancho) en el borde de la calzada a la que se entra, solo en el carril que entra, y
el triángulo de ceda el paso (M-6.5) 5 m antes. La señal va 4 m antes de la línea, en el arcén derecho de quien llega
(fuera de cualquier calzada), mirándole.

Uso:  python pipeline/senales_cruces.py --zona m406 --osm cache/osm/m406_senales.json --osm_vias cache/osm/m406_todas_highway.json
Salida: juego/datos/<zona>/senales.json  {senales: [{tipo, x, y, z, rumbo, acceso}], marcas: [{tipo, p: [[x,y,z]×n]}], estadisticas}
  marcas: "linea" (cuadrilátero, 4 puntos) y "triangulo" (3 puntos), en coordenadas del juego, ya a la altura del asfalto.
"""
import argparse, json, math, os, sys, time
from collections import Counter, defaultdict
import numpy as np
from scipy.spatial import cKDTree

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_OSM = 40.0        # m del extremo de la vía a un nodo de OSM que la controla
DUP = 15.0
# glorieta tipo (juego/scripts/glorieta_tipo.gd): misma anchura de anillo y misma isleta separadora que el juego
ISLA_H = 1.5          # semiancho de la isleta junto al anillo (GlorietaTipo.ISLA_ANCHO / 2)


def hw_tipo(radio, hw0):
    hw = 3.0 if 2.0 * (radio + 3.0) < 40.0 else 4.5
    if hw0 > 4.9 and radio > 35.0:
        hw = hw0
    return min(hw, max(2.6, radio - 3.0))


RANGO = {"motorway": 0, "trunk": 1, "primary": 2, "secondary": 3, "tertiary": 4, "unclassified": 5, "residential": 6}


def tipo_de(tags):
    ts = tags.get("traffic_sign", "")
    for c in ts.replace(",", ";").split(";"):
        c = c.strip()
        if c in ("ES:R2", "ES:R-2"): return "R2"
        if c in ("ES:R1", "ES:R-1"): return "R1"
    if tags.get("highway") == "stop": return "R2"
    if tags.get("highway") == "give_way": return "R1"
    return None


def densificar(p, paso=1.0):
    out = [p[0]]
    for a, b in zip(p[:-1], p[1:]):
        L = math.hypot(b[0] - a[0], b[2] - a[2])
        k = max(int(L // paso), 1)
        for j in range(1, k + 1):
            out.append(a + (b - a) * j / k)
    return np.array(out)


class Red:
    """Ejes de la zona (ruta, vías, anillos) densificados cada 1 m, con su semiancho, para medir distancias a calzada."""

    def __init__(self, dz):
        self.car = json.load(open(os.path.join(dz, "carreteras.json")))
        vias = list(self.car.get("vias", []))
        for nombre in self.car.get("vias_archivos", []):
            vias += json.load(open(os.path.join(dz, nombre))).get("vias", [])
        self.vias = vias
        P, hw, dueno, kidx = [], [], [], []      # dueno: ("r", i) ruta, ("v", i) vía, ("g", i) anillo; kidx: índice en él
        # anillos de la glorieta tipo, antes que nada: la calzada de la ruta y los trozos de OSM que caen dentro del
        # anillo no se dibujan en el juego (el anillo es la calzada), así que no cuentan como borde
        anis = []
        for g in self.car.get("glorietas", []):
            a = np.c_[g["x"], g["y"], g["z"]].astype(float)
            c = a.mean(0)
            radio = float(np.mean(np.hypot(a[:, 0] - c[0], a[:, 2] - c[2])))
            h0 = float(g.get("hw", 3.2))
            anis.append((c, radio, hw_tipo(radio, h0), h0))

        def dentro_anillo(q, semi):
            for c, radio, hwt, _ in anis:
                if abs(q[1] - c[1]) < 4.0 and math.hypot(q[0] - c[0], q[2] - c[2]) < radio + hwt + 0.3 - semi:
                    return True
            return False

        def trozo_anillo(p):
            for c, radio, hwt, h0 in anis:
                dc = np.hypot(p[:, 0] - c[0], p[:, 2] - c[2])
                if np.all(np.abs(dc - radio) < max(2.5, h0 * 0.6)) and np.all(np.abs(p[:, 1] - c[1]) < 4.0):
                    return True
            return False
        self.rutas = []
        for ri, r in enumerate(self.car["rutas"]):
            xyz = np.c_[r["x"], r["y"], r["z"]].astype(float)
            an = np.asarray(r["ancho"], float)
            dib = np.asarray(r["dibujar"])
            self.rutas.append((xyz, an, dib))
            for i in np.flatnonzero(dib == 1):
                if dentro_anillo(xyz[i], an[i] * 0.5):
                    continue
                P.append(xyz[i]); hw.append(an[i] * 0.5); dueno.append(("r", ri)); kidx.append(int(i))
        self.vpts = []
        for vi, v in enumerate(vias):
            p = np.c_[v["x"], v["y"], v["z"]].astype(float)
            if len(p) < 2 or v.get("tunel", 0) == 1:
                self.vpts.append(None); continue
            d = densificar(p)
            self.vpts.append(d)
            if trozo_anillo(p):
                continue
            for k, q in enumerate(d):
                if dentro_anillo(q, float(v["ancho"]) * 0.5):
                    continue
                P.append(q); hw.append(float(v["ancho"]) * 0.5); dueno.append(("v", vi)); kidx.append(k - len(d) if k > len(d) // 2 else k)
        self.anillos = []
        for gi, g in enumerate(self.car.get("glorietas", [])):
            a = np.c_[g["x"], g["y"], g["z"]].astype(float)
            # orden antihorario en el mapa (x este, -z norte)
            area = float(np.sum(a[:, 0] * -np.roll(a[:, 2], -1) - np.roll(a[:, 0], -1) * -a[:, 2]))
            if area < 0: a = a[::-1]
            c = a.mean(0)
            radio = float(np.mean(np.hypot(a[:, 0] - c[0], a[:, 2] - c[2])))
            hwg = hw_tipo(radio, float(g.get("hw", 4.0)))
            d = densificar(np.vstack([a, a[:1]]))
            self.anillos.append({"pts": a, "c": c, "radio": radio, "hw": hwg, "d": d})
            for q in d:
                P.append(q); hw.append(hwg); dueno.append(("g", gi)); kidx.append(0)
        self.P = np.array(P); self.hw = np.array(hw); self.dueno = dueno; self.kidx = kidx
        # tangente de cada punto (para no tomar por cruce dos rutas que comparten la misma carretera)
        T = np.zeros((len(P), 2))
        for k in range(len(P)):
            j = k + 1 if k + 1 < len(P) and dueno[k + 1] == dueno[k] else k
            i = k - 1 if k > 0 and dueno[k - 1] == dueno[k] else k
            t = self.P[j, [0, 2]] - self.P[i, [0, 2]]
            T[k] = t / (np.hypot(*t) + 1e-9)
        self.T = T
        self.arbol = cKDTree(self.P[:, [0, 2]])

    def borde(self, q, excluir=None, radio=25.0):
        """m desde q (x, z) al borde de la calzada más cercana (< 0: dentro), sin contar el dueño `excluir`."""
        idx = self.arbol.query_ball_point(q, radio)
        mejor, quien = 99.0, None
        for j in idx:
            if excluir is not None and self.dueno[j] == excluir:
                continue
            d = math.hypot(self.P[j, 0] - q[0], self.P[j, 2] - q[1]) - self.hw[j]
            if d < mejor:
                mejor, quien = d, self.dueno[j]
        return mejor, quien


def punto_atras(d, k_fin, sentido, dist):
    """Recorre la polilínea densificada d desde el índice k_fin, alejándose del extremo (sentido = -1 si el extremo es
    el último punto), `dist` m. Devuelve (punto 3D, índice)."""
    k = k_fin
    resto = dist
    while 0 <= k + sentido < len(d):
        q = d[k + sentido]
        L = math.hypot(q[0] - d[k][0], q[2] - d[k][2])
        if L >= resto:
            return d[k] + (q - d[k]) * (resto / max(L, 1e-9)), k
        resto -= L
        k += sentido
    return d[k], k


def sentidos_osm(osm_vias, E0, N0):
    """Tramos de OSM de un solo sentido (oneway / autopistas y enlaces / junction=roundabout), densificados, con su
    dirección: para saber si una vía del juego entra o sale de una glorieta."""
    from pyproj import Transformer
    utm = Transformer.from_crs(4326, 25830, always_xy=True)
    if osm_vias is None or not os.path.exists(osm_vias):
        return None
    d = json.load(open(osm_vias))
    els = d.get("datos", d).get("elements", [])
    P, T = [], []
    for w in els:
        if w.get("type") != "way" or "geometry" not in w:
            continue
        t = w.get("tags", {})
        ow = t.get("oneway", "")
        un = ow in ("yes", "1", "true", "-1") or t.get("highway") in ("motorway", "motorway_link") or t.get("junction") in ("roundabout", "circular")
        if not un or ow == "no":
            continue
        lon = [p["lon"] for p in w["geometry"]]; lat = [p["lat"] for p in w["geometry"]]
        E, N = utm.transform(lon, lat)
        g = np.c_[np.asarray(E) - E0, N0 - np.asarray(N)]
        if ow == "-1":
            g = g[::-1]
        for a, b in zip(g[:-1], g[1:]):
            L = float(np.hypot(*(b - a)))
            if L < 0.1: continue
            u = (b - a) / L
            for s in np.arange(0, L, 2.0):
                P.append(a + u * s); T.append(u)
    if not P:
        return None
    return cKDTree(np.array(P)), np.array(T)


def es_de_un_sentido(ow, q, u):
    """+1: OSM dice que la vía es de un solo sentido en el sentido u en q; -1: al revés; 0: de doble sentido / no se sabe."""
    if ow is None:
        return 0
    arbol, T = ow
    dd, k = arbol.query(q)
    if dd > 4.0:
        return 0
    c = float(T[k] @ u)
    return 1 if c > 0.8 else (-1 if c < -0.8 else 0)


def accesos(red, ow):
    """Extremos de vía que entran en la ruta, en otra vía (por su interior) o en un anillo."""
    out = []
    cuenta = Counter()
    for vi, d in enumerate(red.vpts):
        if d is None or len(d) < 4:
            continue
        hwv = float(red.vias[vi]["ancho"]) * 0.5
        # ¿la vía es parte de un anillo? (recorre el eje del anillo)
        en_anillo = False
        for g in red.anillos:
            if np.hypot(d[len(d) // 2, 0] - g["c"][0], d[len(d) // 2, 2] - g["c"][2]) < g["radio"] + 2 and \
                    abs(np.hypot(d[len(d) // 2, 0] - g["c"][0], d[len(d) // 2, 2] - g["c"][2]) - g["radio"]) < g["hw"]:
                en_anillo = True
        if en_anillo:
            cuenta["via_del_propio_anillo"] += 1
            continue
        for fin, k_fin, sent in ((0, 0, 1), (1, len(d) - 1, -1)):
            e = d[k_fin]
            atras, _ = punto_atras(d, k_fin, sent, 6.0)
            u = np.array([e[0] - atras[0], e[2] - atras[2]])
            if np.hypot(*u) < 1.0:
                continue
            u = u / np.hypot(*u)
            # ¿a qué calzada llega? (la más cercana al extremo que no es ella misma)
            b, quien = red.borde((e[0], e[2]), excluir=("v", vi), radio=20.0)
            if quien is None or b > 1.5:
                continue
            tipo = None
            if quien[0] == "g":
                g = red.anillos[quien[1]]
                rad = np.array([g["c"][0] - e[0], g["c"][2] - e[2]])
                if float(rad @ u) / (np.hypot(*rad) + 1e-9) < 0.15:
                    cuenta["no_apunta_al_anillo"] += 1
                    continue
                tipo = "glorieta"
            elif quien[0] == "r":
                tipo = "ruta"
            else:
                ov = red.vpts[quien[1]]
                # solo si llega al INTERIOR de la otra vía (no es la continuación de la misma carretera)
                dd = np.hypot(ov[:, 0] - e[0], ov[:, 2] - e[2])
                k = int(np.argmin(dd))
                if k < 8 or k > len(ov) - 9:
                    continue
                tipo = "via"
            dentro, _ = punto_atras(d, k_fin, sent, 5.0)
            sentido = es_de_un_sentido(ow, np.array([dentro[0], dentro[2]]), u)
            if sentido == -1:
                cuenta["salida_de_un_sentido:" + tipo] += 1
                continue
            out.append({"via": vi, "k": k_fin, "sent": sent, "e": e, "u": u, "hw": hwv, "contra": quien,
                        "tipo": tipo, "un_sentido": sentido == 1})
    return out, cuenta


def arcos_ruta(red):
    """Entradas de la ruta al arco de una glorieta (como ruta.gd: arco de ≥ 20° sobre el anillo). El sentido que recorre
    el arco (antihorario) entra por un extremo; el contrario se desvía (ruta.gd) y no se señaliza aquí."""
    out = []
    for ri, (xyz, an, dib) in enumerate(red.rutas):
        n = len(xyz)
        tg = np.c_[np.gradient(xyz[:, 0]), np.gradient(xyz[:, 2])]
        tg /= (np.hypot(tg[:, 0], tg[:, 1])[:, None] + 1e-9)
        for gi, g in enumerate(red.anillos):
            c, radio, hw = g["c"], g["radio"], g["hw"]
            dc = np.hypot(xyz[:, 0] - c[0], xyz[:, 2] - c[2])
            if dc.min() > radio + hw + 2:
                continue
            umbral = max(2.5, hw * 0.6)
            ar = cKDTree(g["d"][:, [0, 2]])
            dp, _ = ar.query(xyz[:, [0, 2]])
            sobre = (np.abs(dc - radio) < umbral) & (np.abs(xyz[:, 1] - c[1]) < 8.0) & (dp < umbral)
            runs = []
            i0 = -1
            for i in range(n):
                if sobre[i]:
                    if i0 < 0: i0 = i
                elif i0 >= 0:
                    runs.append([i0, i - 1]); i0 = -1
            if i0 >= 0: runs.append([i0, n - 1])
            arcos = []
            for r in runs:
                if arcos and r[0] - arcos[-1][1] <= 4: arcos[-1][1] = r[1]
                else: arcos.append(r)
            for a, b in arcos:
                if b - a < 3: continue
                th = np.unwrap(np.arctan2(-(xyz[a:b + 1, 2] - c[2]), xyz[a:b + 1, 0] - c[0]))   # ángulo en (x, -z)
                giro = th[-1] - th[0]
                if abs(giro) < math.radians(20): continue
                sentido = 1 if giro > 0 else -1
                ie = a if sentido > 0 else b       # por aquí entra quien recorre el arco
                # hacia atrás (contra su marcha) hasta salir del borde exterior del anillo
                i = ie
                while 0 <= i - sentido < n and dc[i] < radio + hw + 0.3:
                    i -= sentido
                if not (0 <= i - sentido < n) or dc[i] < radio + hw + 0.3:
                    continue          # la ruta empieza en la glorieta
                out.append({"ruta": ri, "g": gi, "i": i, "sentido": sentido, "u": tg[i] * sentido,
                            "e": xyz[i], "hw": float(an[i]) * 0.5})
    return out


def cruce_delante_en_ruta(red, q, u):
    """Nodo de OSM sobre una ruta, para quien circula en el sentido u: ¿hay delante (≤ 30 m) otra calzada que la ruta
    cruza o en la que acaba (otra ruta, un anillo o una vía que la atraviesa, no una que solo acaba en ella)? Devuelve
    (ruta, índice de la línea, u en la línea) o None."""
    mejor = None
    for ri, (xyz, an, dib) in enumerate(red.rutas):
        dd = np.hypot(xyz[:, 0] - q[0], xyz[:, 2] - q[1])
        i = int(np.argmin(dd))
        if dd[i] < 8.0 and (mejor is None or dd[i] < mejor[0]):
            mejor = (dd[i], ri, i)
    if mejor is None:
        return None
    _, ri, i = mejor
    xyz, an, dib = red.rutas[ri]
    n = len(xyz)
    j0, j1 = max(i - 1, 0), min(i + 1, n - 1)
    tg = np.array([xyz[j1, 0] - xyz[j0, 0], xyz[j1, 2] - xyz[j0, 2]])
    s = 1 if float(tg @ u) > 0 else -1
    recorrido = 0.0
    j = i
    ultimo_fuera = i
    while 0 <= j + s < n and recorrido < 30.0:
        recorrido += math.hypot(xyz[j + s, 0] - xyz[j, 0], xyz[j + s, 2] - xyz[j, 2])
        j += s
        p = (xyz[j, 0], xyz[j, 2])
        otro = False
        for k in red.arbol.query_ball_point(p, 15.0):
            du = red.dueno[k]
            if du == ("r", ri):
                continue
            if du[0] == "v" and abs(red.kidx[k]) < 6:
                continue       # vía que acaba en la ruta: ahí la ruta es la principal
            if du[0] == "r" and abs(float(red.T[k] @ u)) > 0.9:
                continue       # otra ruta por la misma carretera (rutas que se solapan), no un cruce
            if math.hypot(red.P[k, 0] - p[0], red.P[k, 2] - p[1]) - red.hw[k] < 0.0:
                otro = True
                break
        if otro:
            jl = ultimo_fuera
            t2 = np.array([xyz[min(jl + 1, n - 1), 0] - xyz[max(jl - 1, 0), 0], xyz[min(jl + 1, n - 1), 2] - xyz[max(jl - 1, 0), 2]]) * s
            return ri, jl, t2 / (np.hypot(*t2) + 1e-9)
        ultimo_fuera = j
    return None


def rumbo_de(u):
    return math.atan2(-u[0], -u[1])     # la cara (+Z del modelo) mira a quien llega


def marcas_de(red, tipo, L, u, hw, y):
    """Línea en L (centro de la calzada), sobre el carril derecho de quien llega (u), y triángulo 5 m antes (ceda)."""
    der = np.array([-u[1], u[0]])       # derecha de quien llega (Godot X, Z)
    out = []
    a0, a1 = 0.1, max(hw - 0.25, 1.0)
    ya = y + 0.0
    if tipo == "R2":
        segs = [(a0, a1)]
    else:
        segs = []
        s = a0
        while s < a1 - 0.2:
            segs.append((s, min(s + 0.8, a1))); s += 1.2
    for s0, s1 in segs:
        p = [L + der * s0 - u * 0.4, L + der * s1 - u * 0.4, L + der * s1, L + der * s0]
        out.append({"tipo": "linea", "p": [[round(float(q[0]), 2), round(ya, 2), round(float(q[1]), 2)] for q in p]})
    return out


def triangulo(L, u, hw, y, atras=None):
    """Triángulo de ceda el paso (M-6.5) entre 5 y 8 m antes de la línea, en el carril de quien llega. Con `atras`
    (función distancia → punto 2D del eje del acceso, hacia atrás desde la línea) sigue la curva del acceso: posición y
    orientación del carril en su propio sitio, no las de la línea (en accesos curvos salía girado y fuera del carril)."""
    if atras is not None:
        p5 = np.asarray(atras(5.0), dtype=float)
        p8 = np.asarray(atras(8.0), dtype=float)
        d = p5 - p8
        if np.hypot(*d) > 1.0:
            d = d / np.hypot(*d)
            der = np.array([-d[1], d[0]])
            base = p5 + der * (hw * 0.5)
            pico = p8 + der * (hw * 0.5)          # el vértice apunta a quien llega
            p = [base + der * 0.6, base - der * 0.6, pico]
            return {"tipo": "triangulo", "p": [[round(float(q[0]), 2), round(y, 2), round(float(q[1]), 2)] for q in p]}
    der = np.array([-u[1], u[0]])
    cen = L + der * (hw * 0.5) - u * 5.0       # base a 5 m de la línea, centrado en el carril
    base = cen
    pico = cen - u * 3.0                        # el vértice apunta a quien llega (M-6.5)
    p = [base + der * 0.6, base - der * 0.6, pico]
    return {"tipo": "triangulo", "p": [[round(float(q[0]), 2), round(y, 2), round(float(q[1]), 2)] for q in p]}


def colocar(red, tipo, L, u, hw, y, excluir, valida=None):
    """Poste 4 m antes de la línea, a la derecha (semiancho + 0,8 m), fuera de cualquier calzada (se retrasa ≤ 10 m)."""
    der = np.array([-u[1], u[0]])
    for atras in np.arange(4.0, 14.0, 0.5):
        pos = L - u * atras + der * (hw + 0.8)
        b, _ = red.borde(pos, excluir=excluir, radio=20.0)
        b_propio = math.hypot(*(pos - L + u * atras)) - hw
        if b > 0.4 and b_propio > 0.4 and (valida is None or valida(pos)):
            return pos, atras
    return None, None


def main():
    from senales_comprobar import comprobar
    ap = argparse.ArgumentParser()
    ap.add_argument("--zona", required=True)
    ap.add_argument("--osm", required=True, help="Overpass: nodos de señal + vías que los contienen (geom)")
    ap.add_argument("--osm_vias", help="vías de OSM de la zona con etiquetas y geometría (para saber los sentidos únicos)")
    ap.add_argument("--datos", default=os.path.join(RAIZ, "juego", "datos"))
    ap.add_argument("--salida")
    a = ap.parse_args()
    dz = os.path.join(a.datos, a.zona)
    zona = json.load(open(os.path.join(dz, "zona.json")))
    E0, N0 = zona["origen_utm"]
    t0 = time.time()
    red = Red(dz)
    ow = sentidos_osm(a.osm_vias, E0, N0)
    print(f"red: {len(red.P)} puntos, {len(red.anillos)} anillos, sentidos únicos OSM: {'sí' if ow else 'no'} ({time.time()-t0:.1f}s)", flush=True)
    acc, cuenta = accesos(red, ow)
    arcs = arcos_ruta(red)
    print(f"accesos de vía: {len(acc)} {dict(Counter(x['tipo'] for x in acc))} · entradas de la ruta a glorietas: {len(arcs)}", flush=True)

    # nodos de OSM → acceso que controlan
    from pyproj import Transformer
    utm = Transformer.from_crs(4326, 25830, always_xy=True)
    d = json.load(open(a.osm))
    d = d.get("datos", d)
    ways = {w["id"]: w for w in d.get("elements", []) if w.get("type") == "way" and "geometry" in w}
    padres = defaultdict(list)
    for w in ways.values():
        for i, nid in enumerate(w.get("nodes", [])):
            padres[nid].append((w, i))
    asignado = defaultdict(list)       # índice de acceso → [(tipo, osm)]
    en_ruta = []                       # señales de OSM sobre la ruta con cruce delante: (tipo, osm, (ruta, i, u))
    for e in d.get("elements", []):
        if e.get("type") != "node":
            continue
        t = e.get("tags", {})
        tipo = tipo_de(t)
        if tipo is None:
            continue
        E, N = utm.transform(e["lon"], e["lat"])
        q = np.array([E - E0, N0 - N])
        mejor, mk = MAX_OSM, None
        for k, x in enumerate(acc):
            de = math.hypot(q[0] - x["e"][0], q[1] - x["e"][2])
            if de > mejor:
                continue
            dv = red.vpts[x["via"]]
            if np.min(np.hypot(dv[:, 0] - q[0], dv[:, 2] - q[1])) > 6.0 and de > 6.0:
                continue      # el nodo no está en esa vía
            # direction=forward/backward: sentido de la vía de OSM que lo contiene, comparado con el de llegada
            dirn = (t.get("direction") or "").lower()
            if dirn in ("forward", "backward") and padres.get(e["id"]):
                w, i = padres[e["id"]][0]
                g = w["geometry"]
                j0, j1 = max(i - 1, 0), min(i + 1, len(g) - 1)
                E1, N1 = utm.transform([g[j0]["lon"], g[j1]["lon"]], [g[j0]["lat"], g[j1]["lat"]])
                vw = np.array([E1[1] - E1[0], -(N1[1] - N1[0])])
                if dirn == "backward": vw = -vw
                if float(vw @ x["u"]) < 0:
                    continue  # es para quien sale del cruce por esa vía
            mejor, mk = de, k
        if mk is None and (t.get("direction") or "").lower() in ("forward", "backward") and padres.get(e["id"]):
            w, i = padres[e["id"]][0]
            g = w["geometry"]
            j0, j1 = max(i - 1, 0), min(i + 1, len(g) - 1)
            E1, N1 = utm.transform([g[j0]["lon"], g[j1]["lon"]], [g[j0]["lat"], g[j1]["lat"]])
            vw = np.array([E1[1] - E1[0], -(N1[1] - N1[0])])
            if t["direction"].lower() == "backward": vw = -vw
            vw = vw / (np.hypot(*vw) + 1e-9)
            r = cruce_delante_en_ruta(red, q, vw)
            if r is None:
                cuenta["osm_en_ruta_sin_cruce_delante"] += 1
            else:
                en_ruta.append((tipo, e["id"], r))
            continue
        if mk is None:
            cuenta["osm_sin_acceso_en_el_juego"] += 1
        else:
            asignado[mk].append((tipo, e["id"]))

    senales, marcas = [], []
    hechos = []    # (L, u) de cada acceso señalizado, para no duplicar

    def poner(tipo, L, u, hw, y, excluir, acceso, osm=None, atras_fn=None, doble=True):
        # entrada a glorieta (glorieta tipo): la línea de ceda la pinta el juego (GlorietaTipo); aquí la señal, fuera
        # de la calzada ensanchada por la isleta, y el triángulo centrado en el carril de entrada (junto a la isleta)
        en_glorieta = acceso.startswith("glorieta")
        h_isla = ISLA_H if (en_glorieta and doble) else 0.0
        for (L2, u2) in hechos:
            if math.hypot(*(L - L2)) < DUP and float(u @ u2) > 0.7:
                cuenta["duplicada"] += 1
                return
        # cada posición candidata pasa por el mismo comprobador que el resultado final (senales_comprobar.py)
        def valida(pos):
            s = {"tipo": tipo, "x": float(pos[0]), "z": float(pos[1]), "rumbo": rumbo_de(u)}
            return not comprobar(red, [s], ow)
        pos, atras = colocar(red, tipo, L, u, hw + h_isla, y, excluir, valida)
        if pos is None:
            cuenta["sin_sitio_valido(" + acceso + ")"] += 1
            return
        hechos.append((L, u))
        s = {"tipo": tipo, "x": round(float(pos[0]), 2), "y": round(y, 2), "z": round(float(pos[1]), 2),
             "rumbo": round(rumbo_de(u), 3), "acceso": acceso}
        if osm: s["osm"] = osm
        senales.append(s)
        if not en_glorieta:
            marcas.extend(marcas_de(red, tipo, L, u, hw, y))
        if tipo == "R1":
            marcas.append(triangulo(L, u, hw + 2.0 * h_isla * 0.85, y, atras_fn))
        cuenta["puesta:" + acceso] += 1

    # 1) entradas de la ruta a glorietas (antes que las vías: la ruta manda si coinciden)
    for x in arcs:
        L = np.array([x["e"][0], x["e"][2]])
        xyz_r = red.rutas[x["ruta"]][0]
        poner("R1", L, x["u"], x["hw"], float(x["e"][1]), ("r", x["ruta"]), "glorieta_ruta",
              atras_fn=lambda dd, xr=xyz_r, i0=x["i"], sg=-x["sentido"]: punto_atras(xr, i0, sg, dd)[0][[0, 2]])
    # 1b) la ruta cede en un cruce (OSM con direction y otra calzada delante)
    for tipo, osm_id, (ri, jl, u) in en_ruta:
        xyz, an, _ = red.rutas[ri]
        jn = min(jl + 1, len(xyz) - 1)
        sg = -1 if float((xyz[jn, 0] - xyz[max(jn - 1, 0), 0]) * u[0] + (xyz[jn, 2] - xyz[max(jn - 1, 0), 2]) * u[1]) > 0 else 1
        poner(tipo, np.array([xyz[jl, 0], xyz[jl, 2]]), u, float(an[jl]) * 0.5, float(xyz[jl, 1]), ("r", ri), "cruce_osm_ruta", [osm_id],
              atras_fn=lambda dd, xr=xyz, i0=jl, s0=sg: punto_atras(xr, i0, s0, dd)[0][[0, 2]])
    # 2) vías que entran en glorietas; 3) cruces con señal en OSM
    for k, x in enumerate(acc):
        if x["tipo"] != "glorieta" and k not in asignado:
            continue
        tipos = [t for t, _ in asignado.get(k, [])]
        tipo = "R2" if "R2" in tipos else "R1"
        dv = red.vpts[x["via"]]
        # línea en el borde de la calzada a la que se entra: se retrocede por la vía hasta quedar 0,3 m fuera
        L3 = None
        for atras in np.arange(0.0, 30.0, 0.5):
            p3, _ = punto_atras(dv, x["k"], x["sent"], atras)
            b, quien = red.borde((p3[0], p3[2]), excluir=("v", x["via"]), radio=20.0)
            if b >= 0.3:
                L3 = p3; a3 = float(atras); break
        if L3 is None:
            cuenta["acceso_sin_hueco"] += 1
            continue
        L = np.array([L3[0], L3[2]])
        # dirección de llegada en la línea
        p_a, _ = punto_atras(dv, x["k"], x["sent"], float(np.hypot(L3[0] - x["e"][0], L3[2] - x["e"][2])) + 4.0)
        u = L - np.array([p_a[0], p_a[2]])
        u = u / (np.hypot(*u) + 1e-9)
        acceso = "glorieta_via" if x["tipo"] == "glorieta" else "cruce_osm"
        poner(tipo, L, u, x["hw"], float(L3[1]), ("v", x["via"]), acceso, [o for _, o in asignado.get(k, [])] or None, doble=not x.get("un_sentido", False),
              atras_fn=lambda dd, dv=dv, k0=x["k"], s0=x["sent"], a0=a3: punto_atras(dv, k0, s0, a0 + dd)[0][[0, 2]])

    senales.sort(key=lambda s: (s["x"], s["z"]))
    est = {"puestas": len(senales), "por_tipo": dict(Counter(s["tipo"] for s in senales)),
           "por_acceso": dict(Counter(s["acceso"] for s in senales)), "marcas": dict(Counter(m["tipo"] for m in marcas)),
           "detalle": dict(cuenta)}
    salida = {"zona": a.zona,
              "fuente": "© colaboradores de OpenStreetMap (ODbL): highway=stop/give_way y traffic_sign=ES:R1/ES:R2; entradas a glorietas del propio juego",
              "generado": time.strftime("%Y-%m-%d %H:%M"), "programa": "pipeline/senales_cruces.py",
              "rumbo": "ángulo en radianes alrededor de Y (Godot) hacia el que mira la cara de la señal",
              "senales": senales, "marcas": marcas, "estadisticas": est}
    fp = a.salida or os.path.join(dz, "senales.json")
    if os.path.exists(fp):
        os.remove(fp)       # puede ser un enlace duro al árbol vivo: se escribe un archivo nuevo
    json.dump(salida, open(fp, "w"), ensure_ascii=False, separators=(",", ":"))
    print(f"{a.zona}: {est}", flush=True)
    print(f"escrito {fp} ({os.path.getsize(fp)} B) en {time.time()-t0:.1f}s", flush=True)


if __name__ == "__main__":
    main()
