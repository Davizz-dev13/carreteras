"""Mundo abierto · paso 1: red de carreteras interurbanas de la Comunidad de Madrid desde OSM (extracto .osm.pbf).
Criterio (documentado en FUENTES): autopistas/autovías (motorway), vías rápidas (trunk) y sus enlaces, siempre;
primary/secondary/tertiary SOLO si tienen 'ref' (carreteras numeradas: M-xxx, N-xxx, A-x...) y sus enlaces;
enlaces sin ref de primary/secondary/tertiary solo si sus dos extremos tocan la red ya elegida;
glorietas (junction=roundabout/circular) primary/secondary/tertiary sin ref si el anillo toca la red en 2+ nodos
(sin ellas la carretera numerada se cortaba en la glorieta y el piloto la cruzaba por en medio).
Las calles (residential, unclassified, service...) y las primary/secondary/tertiary sin ref (avenidas urbanas) quedan
fuera por ahora (se podrán añadir por tesela más adelante).
Salida: grafo.pkl con nodos (id OSM -> lon, lat) y tramos partidos en cada cruce."""
import osmium, pickle, sys, collections, math, json
SIEMPRE = {"motorway", "trunk", "motorway_link", "trunk_link"}
CON_REF = {"primary", "secondary", "tertiary"}
ENLACES = {"primary_link", "secondary_link", "tertiary_link"}
pbf, salida = sys.argv[1], sys.argv[2]
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
    if cat is None:
        continue
    try:
        nodos = [(n.ref, n.location.lon, n.location.lat) for n in w.nodes]
    except osmium.InvalidLocationError:
        continue
    ways.append({"id": w.id, "tags": t, "nodos": nodos, "cat": cat})
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
print(json.dumps({"ways": len(ways), "tramos": len(tramos), "nodos": len(coord), "nodos_cruce": cruces, "glorietas_sin_ref": n_anillos}))
