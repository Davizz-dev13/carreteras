"""Mundo abierto · paso 1: red de carreteras interurbanas de la Comunidad de Madrid desde OSM (extracto .osm.pbf).
Criterio (documentado en FUENTES): autopistas/autovías (motorway), vías rápidas (trunk) y sus enlaces, siempre;
primary/secondary/tertiary SOLO si tienen 'ref' (carreteras numeradas: M-xxx, N-xxx, A-x...) y sus enlaces;
enlaces sin ref de primary/secondary/tertiary solo si sus dos extremos tocan la red ya elegida;
glorietas (junction=roundabout/circular) primary/secondary/tertiary sin ref si el anillo toca la red en 2+ nodos
(sin ellas la carretera numerada se cortaba en la glorieta y el piloto la cruzaba por en medio).
huecos: tramos de primary/secondary/tertiary SIN ref de ≤ 1,5 km que unen un callejón sin salida de la red con otro nodo
de la red (la ref que OSM quita en una travesía o al cambiar de provincia).
Las calles (residential, unclassified, service...) y las primary/secondary/tertiary sin ref (avenidas urbanas) quedan
fuera por ahora (se podrán añadir por tesela más adelante).
Franja exterior: con un tercer argumento (polígono .poly en lon/lat, p. ej. la Comunidad + 10 km) se recortan las vías a
ese polígono. Así entran también las carreteras que salen de la Comunidad y vuelven a entrar (la A-4 y la R-4 por Seseña,
Toledo), leyendo un .pbf que une el extracto de Madrid con los de Castilla-La Mancha y Castilla y León.
Salida: grafo.pkl con nodos (id OSM -> lon, lat) y tramos partidos en cada cruce.
Uso: python m1_red.py red.osm.pbf red.pkl [recorte.poly]"""
import osmium, pickle, sys, collections, math, json
SIEMPRE = {"motorway", "trunk", "motorway_link", "trunk_link"}
CON_REF = {"primary", "secondary", "tertiary"}
ENLACES = {"primary_link", "secondary_link", "tertiary_link"}
pbf, salida = sys.argv[1], sys.argv[2]
recorte = None
if len(sys.argv) > 3:   # polígono .poly (formato osmosis, un anillo exterior)
    import shapely
    from shapely.geometry import Polygon
    pts = [tuple(map(float, l.split())) for l in open(sys.argv[3]).read().split("\n")[2:] if len(l.split()) == 2]
    recorte = Polygon(pts); shapely.prepare(recorte)
ways = []
fp = osmium.FileProcessor(pbf, osmium.osm.NODE | osmium.osm.WAY).with_locations()
for w in fp:
    if not w.is_way():
        continue
    t = dict(w.tags)
    hw = t.get("highway")
    if t.get("area") == "yes" or hw is None:
        continue
    if t.get("construction") or t.get("proposed") or hw in ("construction", "proposed"):
        continue
    cat = None
    if hw in SIEMPRE: cat = "si"
    elif hw in CON_REF and t.get("ref"): cat = "si"
    elif hw in ENLACES: cat = "enlace" if not t.get("ref") else "si"
    elif hw in CON_REF and t.get("junction") in ("roundabout", "circular"): cat = "anillo"
    elif hw in CON_REF: cat = "hueco"     # sin ref: solo para cerrar huecos (ver abajo)
    if cat is None:
        continue
    try:
        nodos = [(n.ref, n.location.lon, n.location.lat) for n in w.nodes]
    except osmium.InvalidLocationError:
        continue
    if recorte is None:
        ways.append({"id": w.id, "tags": t, "nodos": nodos, "cat": cat}); continue
    dentro = shapely.contains_xy(recorte, [n[1] for n in nodos], [n[2] for n in nodos])
    tramo = []
    for n, ok in zip(nodos, list(dentro) + [False]):
        if ok: tramo.append(n)
        elif tramo:
            if len(tramo) >= 2: ways.append({"id": w.id, "tags": t, "nodos": tramo, "cat": cat})
            tramo = []
    if len(tramo) >= 2: ways.append({"id": w.id, "tags": t, "nodos": tramo, "cat": cat})
# enlaces sin ref: solo si sus dos extremos tocan la red elegida
uso = collections.Counter()
for w in ways:
    if w["cat"] == "si":
        for n in w["nodos"]: uso[n[0]] += 1
# glorietas sin ref: cada anillo (unión de sus ways por nodos compartidos) entra si toca la red en 2+ nodos
anillos = [w for w in ways if w["cat"] == "anillo"]
padre = list(range(len(anillos)))
def raiz(i):
    while padre[i] != i:
        padre[i] = padre[padre[i]]; i = padre[i]
    return i
de_nodo = {}
for i, w in enumerate(anillos):
    for n in w["nodos"]:
        j = de_nodo.setdefault(n[0], i)
        if raiz(j) != raiz(i): padre[raiz(j)] = raiz(i)
grupos = collections.defaultdict(list)
for i, w in enumerate(anillos): grupos[raiz(i)].append(w)
n_anillos = 0
for g in grupos.values():
    toca = {n[0] for w in g for n in w["nodos"] if uso[n[0]]}
    if len(toca) >= 2:
        n_anillos += 1
        for w in g:
            w["cat"] = "si"
            for n in w["nodos"]: uso[n[0]] += 1
cambio = True
while cambio:
    cambio = False
    for w in ways:
        if w["cat"] == "enlace" and uso[w["nodos"][0][0]] and uso[w["nodos"][-1][0]]:
            w["cat"] = "si"; cambio = True
            for n in w["nodos"]: uso[n[0]] += 1
# huecos: una carretera numerada que se corta porque OSM le quita la ref unos cientos de metros (la travesía de un pueblo,
# el cambio de provincia: la M-137 sigue en Segovia como tertiary sin ref) dejaba un callejón sin salida. Desde cada
# extremo sin salida se busca el camino más corto (≤ HUECO_MAX m) por primary/secondary/tertiary/enlaces SIN ref hasta
# otro nodo de la red, y se añade ese camino (solo esos trozos, no la vía entera).
HUECO_MAX = 1500.0
grado = collections.Counter()
for w in ways:
    if w["cat"] == "si":
        grado[w["nodos"][0][0]] += 1; grado[w["nodos"][-1][0]] += 1
        for n in w["nodos"][1:-1]: grado[n[0]] += 2
cand = [w for w in ways if w["cat"] in ("hueco", "enlace", "anillo")]
ady = collections.defaultdict(list)    # nodo -> [(vecino, metros, índice de way, índice de arista)]
for wi, w in enumerate(cand):
    ns = w["nodos"]
    for k in range(len(ns) - 1):
        a, b = ns[k], ns[k + 1]
        m = math.hypot((b[1] - a[1]) * 111320 * math.cos(math.radians(a[2])), (b[2] - a[2]) * 110540)
        ady[a[0]].append((b[0], m, wi, k)); ady[b[0]].append((a[0], m, wi, k))
import heapq
usadas = collections.defaultdict(set)
n_huecos = 0
for n0 in [n for n, c in grado.items() if c == 1]:
    if n0 not in ady: continue
    dist = {n0: 0.0}; prev = {}; h = [(0.0, n0)]; fin = None
    while h:
        dd, n = heapq.heappop(h)
        if dd > dist.get(n, 1e18): continue
        if n != n0 and uso[n]:
            fin = n; break
        for (m, l, wi, k) in ady[n]:
            nd = dd + l
            if nd <= HUECO_MAX and nd < dist.get(m, 1e18):
                dist[m] = nd; prev[m] = (n, wi, k); heapq.heappush(h, (nd, m))
    if fin is None: continue
    n_huecos += 1
    n = fin
    while n != n0:
        p, wi, k = prev[n]; usadas[wi].add(k); n = p
for wi, aristas in usadas.items():
    w = cand[wi]; ns = w["nodos"]; run = []
    for k in range(len(ns) - 1):
        if k in aristas:
            if not run: run = [ns[k]]
            run.append(ns[k + 1])
        elif run:
            ways.append({"id": w["id"], "tags": w["tags"], "nodos": run, "cat": "si"}); run = []
    if run: ways.append({"id": w["id"], "tags": w["tags"], "nodos": run, "cat": "si"})
    if len(aristas) == len(ns) - 1: w["cat"] = "hecho"   # ya entra entera como trozos
ways = [w for w in ways if w["cat"] == "si"]
# nodos de cruce: compartidos por 2+ ways o extremos
cuenta = collections.Counter()
for w in ways:
    for k, n in enumerate(w["nodos"]):
        cuenta[n[0]] += 1 if 0 < k < len(w["nodos"]) - 1 else 2
coord = {}
for w in ways:
    for n in w["nodos"]: coord[n[0]] = (n[1], n[2])
tramos = []
for w in ways:
    ids = [n[0] for n in w["nodos"]]
    a = 0
    for k in range(1, len(ids)):
        if cuenta[ids[k]] >= 2 or k == len(ids) - 1:
            if k > a:
                tramos.append({"way": w["id"], "tags": w["tags"], "nodos": ids[a:k + 1]})
            a = k
pickle.dump({"coord": coord, "tramos": tramos}, open(salida, "wb"))
cruces = sum(1 for n, c in cuenta.items() if c >= 3)
print(json.dumps({"ways": len(ways), "tramos": len(tramos), "nodos": len(coord), "nodos_cruce": cruces, "glorietas_sin_ref": n_anillos, "huecos_cerrados": n_huecos}))
