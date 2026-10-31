"""Encadenado DIRIGIDO para autovías/desdobladas (calzadas separadas, oneway=yes): sigue UNA calzada en el sentido
legal de circulación de un extremo al otro (Dijkstra respetando oneway y el giro de las rotondas). Mismo formato de
salida que rutas.encadenar(): lista de (x, y, way_index) con la vía del tramo que SALE de cada punto."""
import heapq, math
from collections import defaultdict


def _sentidos(t):
    ow = t.get("oneway", "")
    if t.get("junction") in ("roundabout", "circular") and ow != "no": return (True, False)
    if ow in ("yes", "1", "true"): return (True, False)
    if ow == "-1": return (False, True)
    return (True, True)


def encadenar_dirigido(ways, utm, orden="oeste_este", n_extremos=12, refs=None, penal=4.0, penal_tipo=None):
    """refs: si se da, los extremos se buscan solo en vías con esa ref y las vías SIN ella cuestan penal× (solo se usan
    para cubrir un tramo donde OSM no puso la ref, p. ej. un tramo compartido con otra vía); penal_tipo: penalización por
    tipo de vía (p. ej. {"motorway": 1.2, "motorway_link": 1.2}) para preferir la autovía a las calles."""
    pos, ady = {}, defaultdict(list)
    con_ref = set()
    for wi, w in enumerate(ways):
        xs, ys = utm.transform([p[1] for p in w["geom"]], [p[0] for p in w["geom"]])
        for k, nid in enumerate(w["nodes"]): pos[nid] = (xs[k], ys[k])
        ade, atr = _sentidos(w["tags"])
        tiene = refs is None or bool(set(r.strip() for r in w["tags"].get("ref", "").replace(",", ";").split(";")) & set(refs))
        if tiene: con_ref.update(w["nodes"])
        for k in range(len(w["nodes"]) - 1):
            a, b = w["nodes"][k], w["nodes"][k + 1]
            d = math.dist(pos[a], pos[b]) * (1.0 if tiene else (penal_tipo or {}).get(w["tags"].get("highway"), penal))
            if ade: ady[a].append((b, d, wi))
            if atr: ady[b].append((a, d, wi))
    eje = 0 if orden == "oeste_este" else 1
    nodos = sorted(con_ref if refs else pos, key=lambda n: pos[n][eje])
    ini, fin = nodos[:n_extremos], set(nodos[-n_extremos:])
    mejor = None
    for s in ini:
        dist, prev = {s: 0.0}, {}
        h = [(0.0, s)]
        while h:
            d, u = heapq.heappop(h)
            if d > dist[u]: continue
            for v, l, wi in ady[u]:
                if d + l < dist.get(v, 1e18):
                    dist[v] = d + l; prev[v] = (u, wi); heapq.heappush(h, (d + l, v))
        alc = [n for n in fin if n in dist]
        if not alc: continue
        t = max(alc, key=lambda n: pos[n][eje] - pos[s][eje])
        cand = (pos[t][eje] - pos[s][eje], -dist[t], s, t, prev)
        if mejor is None or cand[:2] > mejor[:2]: mejor = cand
    if mejor is None: raise RuntimeError("sin camino dirigido entre los extremos")
    _, _, s, t, prev = mejor
    camino, segs = [t], []
    while camino[-1] != s:
        u, wi = prev[camino[-1]]; segs.append(wi); camino.append(u)
    camino.reverse(); segs.reverse()
    return [(pos[n][0], pos[n][1], segs[k] if k < len(segs) else segs[-1]) for k, n in enumerate(camino)]


def _componentes_ways(ways):
    padre = {}
    def raiz(a):
        while padre.setdefault(a, a) != a:
            padre[a] = padre[padre[a]]; a = padre[a]
        return a
    for w in ways:
        for k in range(len(w["nodes"]) - 1):
            ra, rb = raiz(w["nodes"][k]), raiz(w["nodes"][k + 1])
            if ra != rb: padre[ra] = rb
    grupos = {}
    for wi, w in enumerate(ways): grupos.setdefault(raiz(w["nodes"][0]), []).append(wi)
    return list(grupos.values())


def ruta(sel, utm, opc, orden="oeste_este"):
    """Ruta de una calzada para autovías/desdobladas. opc: {"tipos": ["trunk"], "componente": k (tramos de la ref sin
    conexión entre sí en OSM, ordenados de oeste a este), "rotondas": "recta"}. Devuelve (pts, info)."""
    ws = [w for w in sel if not opc.get("tipos") or w["tags"].get("highway") in opc["tipos"]]
    comps = _componentes_ways(ws)
    def xmin(c):
        return min(utm.transform([p[1] for wi in c for p in ws[wi]["geom"]], [p[0] for wi in c for p in ws[wi]["geom"]])[0])
    comps.sort(key=xmin)
    info = {"tramos_sin_conexion_en_osm": len(comps)}
    if "componente" in opc:
        ws = [ws[wi] for wi in comps[opc["componente"]]]
    pts = encadenar_dirigido(ws, utm, orden)
    # mapear índices de vía de ws → sel
    idx = {id(w): k for k, w in enumerate(sel)}
    pts = [(x, y, idx[id(ws[wi])]) for x, y, wi in pts]
    rot = [k for k in range(len(pts) - 1) if sel[pts[k][2]]["tags"].get("junction") in ("roundabout", "circular")]
    tramos = []
    for k in rot:
        if tramos and k == tramos[-1][-1] + 1: tramos[-1].append(k)
        else: tramos.append([k])
    info["rotondas_atravesadas"] = len(tramos)
    info["rotondas_arco_m"] = [round(sum(math.dist(pts[k][:2], pts[k + 1][:2]) for k in t)) for t in tramos]
    if opc.get("rotondas") == "recta" and tramos:
        # se atraviesa la rotonda en línea recta de la entrada a la salida (la ruta sigue de frente; el anillo se dibuja
        # aparte como vía secundaria). Puntos intermedios cada ~2 m sobre la cuerda, con la vía de la rotonda.
        fuera = set(k for t in tramos for k in t[1:])
        nuevo = []
        for k, p in enumerate(pts):
            if k in fuera: continue
            nuevo.append(p)
            t = next((t for t in tramos if t[0] == k), None)
            if t:
                a, b = pts[t[0]], pts[t[-1] + 1]
                n = max(1, int(math.dist(a[:2], b[:2]) / 2.0))
                for j in range(1, n):
                    u = j / n; nuevo.append((a[0] + u * (b[0] - a[0]), a[1] + u * (b[1] - a[1]), a[2]))
        info["rotondas_cuerda_m"] = [round(math.dist(pts[t[0]][:2], pts[t[-1] + 1][:2])) for t in tramos]
        pts = nuevo
    return pts, info
