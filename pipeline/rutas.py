"""Geometría de carreteras: encadenar vías OSM, remuestrear, altitud suavizada, pendiente y curvatura."""
import heapq, math, re
from collections import defaultdict
import numpy as np
from scipy.ndimage import gaussian_filter1d, median_filter

PASO = 2.0  # m entre muestras a lo largo de la carretera

ANCHO_CARRIL = {"motorway": 3.5, "trunk": 3.5, "primary": 3.5, "secondary": 3.25, "tertiary": 3.0, "unclassified": 2.75}
VEL_DEFECTO = {"motorway": 120, "trunk": 90, "primary": 90, "secondary": 90, "tertiary": 70, "unclassified": 50}


def tipo_base(tags):
    return tags.get("highway", "unclassified").replace("_link", "")


def refs_de(tags):
    return [r.strip() for r in re.split(r"[;,]", tags.get("ref", "")) if r.strip()]


def ancho_de(tags):
    """Anchura de la calzada (m) a partir de width / lanes / tipo de vía."""
    try:
        return float(tags["width"].replace(",", ".").split()[0])
    except (KeyError, ValueError):
        pass
    t = tipo_base(tags)
    try:
        carriles = int(tags.get("lanes", ""))
    except ValueError:
        carriles = 1 if tags.get("oneway") == "yes" else 2
    if "_link" in tags.get("highway", ""):
        carriles = 1
    return carriles * ANCHO_CARRIL.get(t, 3.0) + (1.0 if t in ("motorway", "trunk", "primary") else 0.5)


def vel_max_de(tags):
    m = re.match(r"(\d+)", tags.get("maxspeed", ""))
    return int(m.group(1)) if m else VEL_DEFECTO.get(tipo_base(tags), 50)


def encadenar(ways, utm, union_huecos=80.0):
    """Une las vías (ya filtradas) en un único recorrido: el camino más largo del grafo.
    Devuelve lista de (x, y, way_index) en UTM."""
    pos = {}
    ady = defaultdict(list)
    for wi, w in enumerate(ways):
        xs, ys = utm.transform([p[1] for p in w["geom"]], [p[0] for p in w["geom"]])
        for k, nid in enumerate(w["nodes"]):
            pos[nid] = (xs[k], ys[k])
        for k in range(len(w["nodes"]) - 1):
            a, b = w["nodes"][k], w["nodes"][k + 1]
            d = math.dist(pos[a], pos[b])
            ady[a].append((b, d, wi)); ady[b].append((a, d, wi))
    # unir huecos (rotondas sin ref, cortes de mapeo): extremos de grado 1 cercanos a otro componente
    extremos = [n for n in ady if len(ady[n]) == 1]
    nodos = list(pos.keys()); P = np.array([pos[n] for n in nodos])
    comp = _componentes(ady)
    for n in extremos:
        d = np.hypot(P[:, 0] - pos[n][0], P[:, 1] - pos[n][1])
        for j in np.argsort(d)[:50]:
            m = nodos[j]
            if d[j] > union_huecos: break
            if comp[m] != comp[n]:
                ady[n].append((m, d[j], -1)); ady[m].append((n, d[j], -1)); break
    a = _mas_lejano(ady, nodos[0])[0]
    b, prev = _mas_lejano(ady, a)
    camino = [b]
    while camino[-1] != a:
        camino.append(prev[camino[-1]][0])
    camino.reverse()
    out = []
    for k, n in enumerate(camino):
        wi = prev[camino[k + 1]][1] if k + 1 < len(camino) else prev[n][1]
        out.append((pos[n][0], pos[n][1], wi))
    return out


def _componentes(ady):
    comp, c = {}, 0
    for s in ady:
        if s in comp: continue
        pila = [s]; comp[s] = c
        while pila:
            u = pila.pop()
            for v, _, _ in ady[u]:
                if v not in comp:
                    comp[v] = c; pila.append(v)
        c += 1
    return comp


def _mas_lejano(ady, origen):
    dist = {origen: 0.0}; prev = {origen: (origen, -1)}
    h = [(0.0, origen)]
    while h:
        d, u = heapq.heappop(h)
        if d > dist[u]: continue
        for v, w, wi in ady[u]:
            if d + w < dist.get(v, 1e18):
                dist[v] = d + w; prev[v] = (u, wi); heapq.heappush(h, (d + w, v))
    lejano = max(dist, key=dist.get)
    return lejano, prev


def remuestrear(xy, paso=PASO):
    xy = np.asarray(xy, float)
    seg = np.hypot(*np.diff(xy, axis=0).T)
    ok = np.concatenate([[True], seg > 0.01]); xy = xy[ok]
    s = np.concatenate([[0], np.cumsum(np.hypot(*np.diff(xy, axis=0).T))])
    n = max(2, int(s[-1] / paso) + 1)
    si = np.linspace(0, s[-1], n)
    return np.column_stack([np.interp(si, s, xy[:, 0]), np.interp(si, s, xy[:, 1])]), si, s


def procesar(puntos, ways, mdt, suavizado_xy=3.0):
    """puntos: [(x, y, way_index)] encadenados. Devuelve dict con arrays a PASO m."""
    xy_raw = np.array([(p[0], p[1]) for p in puntos])
    wi_raw = np.array([p[2] for p in puntos])
    xy, s, s_raw = remuestrear(xy_raw)
    # suavizado ligero en planta (quita los "picos" de la poligonal OSM sin cambiar las curvas)
    sig = suavizado_xy / PASO
    xs = gaussian_filter1d(xy[:, 0], sig, mode="nearest"); ys = gaussian_filter1d(xy[:, 1], sig, mode="nearest")
    xs[0], ys[0], xs[-1], ys[-1] = xy[0, 0], xy[0, 1], xy[-1, 0], xy[-1, 1]
    # propiedades de la vía OSM en cada muestra
    idx = np.clip(np.searchsorted(s_raw, s, side="right") - 1, 0, len(wi_raw) - 1)
    wis = wi_raw[np.minimum(idx + 1, len(wi_raw) - 1)]
    wis = np.where(wis < 0, wi_raw[idx], wis)
    def prop(fn, defecto):
        return np.array([fn(ways[w]["tags"]) if w >= 0 else defecto for w in wis])
    puente = prop(lambda t: t.get("bridge", "no") not in ("no", ""), False)
    tunel = prop(lambda t: t.get("tunnel", "no") not in ("no", ""), False)
    ancho = prop(ancho_de, 7.0).astype(float)
    ancho = gaussian_filter1d(ancho, 10)   # transiciones suaves de anchura
    vmax = prop(vel_max_de, 90)
    nombre = [ways[w]["tags"].get("name", "") if w >= 0 else "" for w in wis]
    ref = [ways[w]["tags"].get("ref", "") if w >= 0 else "" for w in wis]
    z = suavizar_altitud(s, mdt.muestrear(xs, ys), puente | tunel)
    return {"s": s, "x": xs, "y": ys, "z": z, "puente": puente, "tunel": tunel,
            "ancho": ancho, "vmax": vmax, "nombre": nombre, "ref": ref, "way": wis,
            "pendiente": pendiente(s, z), "curvatura": curvatura(xs, ys)}


def suavizar_altitud(s, z_mdt, sin_terreno):
    """Altitud de la rasante: el MDT tiene ruido de ±1 m (y cuantización a metro entero en el IGN):
    1) puentes y túneles: interpolación lineal entre sus extremos (no siguen el terreno);
    2) mediana de 25 m (elimina picos: muros, taludes, pasos elevados);
    3) gaussiana sigma 12 m (rasante continua sin alterar pendientes reales de > 50 m)."""
    z = z_mdt.astype(float).copy()
    m = sin_terreno.copy()
    # ampliar 6 m a cada lado: los estribos del puente también salen mal en el MDT
    m = np.convolve(m.astype(int), np.ones(7, int), mode="same") > 0
    if m.any() and not m.all():
        z[m] = np.interp(s[m], s[~m], z[~m])
    z = median_filter(z, size=int(25 / PASO) | 1, mode="nearest")
    z = gaussian_filter1d(z, 12 / PASO, mode="nearest")
    return z


def pendiente(s, z):
    """Pendiente en % (positiva = subida en el sentido de la ruta)."""
    return np.gradient(z, s) * 100


def curvatura(x, y):
    """Curvatura con signo (1/m, + = izquierda). Radio = 1/|k|."""
    ang = np.unwrap(np.arctan2(np.gradient(y), np.gradient(x)))
    ang = gaussian_filter1d(ang, 2.0, mode="nearest")
    return np.gradient(ang) / PASO


def estadisticas(r):
    s, z, g = r["s"], r["z"], r["pendiente"]
    def media_tramo(L):
        n = int(L / PASO)
        if len(z) <= n: return float("nan"), 0.0
        gr = (z[n:] - z[:-n]) / L * 100
        i = int(np.argmax(np.abs(gr)))
        return float(gr[i]), float(s[i])
    dz = np.diff(z)
    g100, s100 = media_tramo(100); g1k, s1k = media_tramo(1000)
    radios = 1 / np.maximum(np.abs(r["curvatura"]), 1e-6)
    return {"longitud_km": round(float(s[-1]) / 1000, 3),
            "alt_min": round(float(z.min()), 1), "alt_max": round(float(z.max()), 1),
            "alt_inicio": round(float(z[0]), 1), "alt_fin": round(float(z[-1]), 1),
            "desnivel_subida": round(float(dz[dz > 0].sum()), 1),
            "desnivel_bajada": round(float(-dz[dz < 0].sum()), 1),
            "pendiente_max_puntual": round(float(np.abs(g).max()), 1),
            "pendiente_max_100m": round(g100, 1), "km_pendiente_max_100m": round(s100 / 1000, 2),
            "pendiente_max_1km": round(g1k, 1), "km_pendiente_max_1km": round(s1k / 1000, 2),
            "radio_min_m": round(float(radios.min()), 1),
            "curvas_radio_menor_30m": int(np.sum(np.diff((radios < 30).astype(int)) == 1)),
            "metros_puente": float(r["puente"].sum() * PASO), "metros_tunel": float(r["tunel"].sum() * PASO)}
