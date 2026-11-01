"""Mundo abierto · paso 1b: glorietas completas en la red (después de m1_red.py, antes de m3_mundo.py).

m1_red.py mete en la red los trozos de glorieta que usa una carretera (o que cierran un hueco), pero si el resto del anillo
no cumple sus criterios (p. ej. la glorieta es de calles, o solo la toca la red en un punto) quedaba solo ese arco: la
carretera llegaba a la glorieta y acababa en el aire, el piloto no encontraba salida y daba vueltas fuera del asfalto
(Calle de Brasil en Torrejón, Avenida de Andalucía, Plaza de Castilla...). Aquí, para cada glorieta de OSM
(junction=roundabout/circular, vía para coches) de la que la red ya usa algún arco, se añaden los arcos que faltan para
cerrar el anillo, con las etiquetas de su vía de OSM.

Los tramos y nodos nuevos se AÑADEN AL FINAL (los números de tramo y de nodo existentes no cambian, así las teselas que
no tocan ninguna glorieta salen iguales en m3).

Conectores (1-11-2026): una glorieta completa cuyas salidas son todas calles que la red no lleva (o cuyas entradas lo
son) quedaba como un sumidero: se podía entrar pero no salir (el piloto daba vueltas sin fin; Calle de Brasil en
Torrejón, Avenida de Andalucía). Para cada glorieta de la red que no está en la componente fuertemente conexa principal
(respetando los sentidos únicos) se añade el camino más corto por vías de coches de OSM (cualquier clase, sentidos
respetados, ≤ 1,5 km) de la glorieta a la red principal y/o de la red principal a la glorieta. Solo esos trozos.

Uso: python m1b_glorietas.py red.pkl red_glorietas.pkl extracto1.osm.pbf [extracto2.osm.pbf ...]"""
import sys, pickle, collections, json
import osmium

COCHES = {"motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential", "living_street",
          "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link", "service", "road"}
ent, sal = sys.argv[1], sys.argv[2]
d = pickle.load(open(ent, "rb"))
aristas = set()
extremo = collections.Counter()     # nodo -> veces que es extremo de un tramo
interior = set()
for t in d["tramos"]:
    ns = t["nodos"]
    for a, b in zip(ns, ns[1:]):
        aristas.add((a, b)); aristas.add((b, a))
    extremo[ns[0]] += 1; extremo[ns[-1]] += 1
    interior.update(ns[1:-1])

anillos = {}
coord = {}
viales = {}      # todas las vías de coches (para los conectores)
for pbf in sys.argv[3:]:
    for w in osmium.FileProcessor(pbf, osmium.osm.NODE | osmium.osm.WAY).with_locations():
        if not w.is_way():
            continue
        t = dict(w.tags)
        if t.get("highway") not in COCHES or t.get("area") == "yes" or w.id in viales:
            continue
        if t.get("access") in ("no", "private") or t.get("motor_vehicle") in ("no", "private"):
            continue
        try:
            ns = [(n.ref, n.location.lon, n.location.lat) for n in w.nodes]
        except osmium.InvalidLocationError:
            continue
        viales[w.id] = {"tags": t, "nodos": [n[0] for n in ns]}
        for n in ns:
            coord[n[0]] = (n[1], n[2])
        if t.get("junction") in ("roundabout", "circular"):
            anillos[w.id] = viales[w.id]
# glorietas = vías de anillo unidas por nodos
padre = {}
def raiz(x):
    while padre.setdefault(x, x) != x:
        padre[x] = padre[padre[x]]; x = padre[x]
    return x
de_nodo = {}
for wid, w in anillos.items():
    for n in w["nodos"]:
        j = de_nodo.setdefault(n, wid)
        if raiz(j) != raiz(wid): padre[raiz(j)] = raiz(wid)
grupos = collections.defaultdict(list)
for wid in anillos: grupos[raiz(wid)].append(wid)

nuevos = []
n_glorietas = 0; n_cruce_interior = 0; ejemplos = []
for g in grupos.values():
    usa = any((a, b) in aristas for wid in g for a, b in zip(anillos[wid]["nodos"], anillos[wid]["nodos"][1:]))
    if not usa:
        continue
    falta = [(wid, i) for wid in g for i, (a, b) in enumerate(zip(anillos[wid]["nodos"], anillos[wid]["nodos"][1:])) if (a, b) not in aristas]
    if not falta:
        continue
    n_glorietas += 1
    # nodos donde cortar los arcos nuevos: los que ya son de la red y los extremos de cada tramo de arco que falta
    for wid in g:
        ns = anillos[wid]["nodos"]
        run = []
        for i, (a, b) in enumerate(zip(ns, ns[1:])):
            if (a, b) in aristas:
                if len(run) >= 2: nuevos.append({"way": wid, "tags": anillos[wid]["tags"], "nodos": run})
                run = []; continue
            if not run: run = [a]
            run.append(b)
            if b in extremo or b in interior:
                if b in interior and b not in extremo:
                    n_cruce_interior += 1
                nuevos.append({"way": wid, "tags": anillos[wid]["tags"], "nodos": run}); run = [b]
        if len(run) >= 2: nuevos.append({"way": wid, "tags": anillos[wid]["tags"], "nodos": run})
    if len(ejemplos) < 400:
        lon, lat = coord[anillos[g[0]]["nodos"][0]]
        ejemplos.append([g, round(lon, 5), round(lat, 5), anillos[g[0]]["tags"].get("name", "")])
# un arco cerrado entero (vía cerrada sin ningún nodo de la red en medio) se parte en dos para que tenga dos nodos
fin = []
for t in nuevos:
    if t["nodos"][0] == t["nodos"][-1] and len(t["nodos"]) > 3:
        m = len(t["nodos"]) // 2
        fin += [dict(t, nodos=t["nodos"][:m + 1]), dict(t, nodos=t["nodos"][m:])]
    else:
        fin.append(t)
# nodos de los arcos nuevos que eran interiores de un tramo: se quedan sin unir a ese tramo (cruce a nivel sin partir)
for t in fin:
    for n in t["nodos"]:
        if n not in d["coord"]:
            d["coord"][n] = coord[n]
d["tramos"] += fin

# ---------------- conectores: glorietas que son sumidero o fuente en la red dirigida
import math, heapq
def sentido(tg):      # igual que m3_mundo.py
    ow = tg.get("oneway", "")
    if ow in ("yes", "true", "1") or tg.get("highway") in ("motorway",) or tg.get("junction") in ("roundabout", "circular"):
        return 1
    if ow == "-1": return -1
    if tg.get("highway", "").endswith("_link") and ow not in ("no",): return 1
    return 0
def scc_principal(tramos):
    ady = collections.defaultdict(list); inv = collections.defaultdict(list); nodos = set()
    for t in tramos:
        a, b = t["nodos"][0], t["nodos"][-1]; s = sentido(t["tags"]); nodos.update((a, b))
        if s >= 0: ady[a].append(b); inv[b].append(a)
        if s <= 0: ady[b].append(a); inv[a].append(b)
    # Kosaraju iterativo
    orden = []; visto = set()
    for r in nodos:
        if r in visto: continue
        pila = [(r, iter(ady[r]))]; visto.add(r)
        while pila:
            v, it = pila[-1]
            for w in it:
                if w not in visto:
                    visto.add(w); pila.append((w, iter(ady[w]))); break
            else:
                pila.pop(); orden.append(v)
    comp = {}; n = 0; tam = collections.Counter()
    for r in reversed(orden):
        if r in comp: continue
        pila = [r]; comp[r] = n
        while pila:
            v = pila.pop(); tam[n] += 1
            for w in inv[v]:
                if w not in comp:
                    comp[w] = n; pila.append(w)
        n += 1
    g = tam.most_common(1)[0][0]
    return {v for v, c in comp.items() if c == g}
def metros(a, b):
    (x1, y1), (x2, y2) = coord[a], coord[b]
    return math.hypot((x2 - x1) * 111320 * math.cos(math.radians(y1)), (y2 - y1) * 110540)
# grafo dirigido de OSM: arista (a -> b, way, índice)
osm_ad = collections.defaultdict(list); osm_inv = collections.defaultdict(list)
for wid, w in viales.items():
    tg = w["tags"]
    # nada de puentes ni túneles en los conectores (cambiarían el gálibo de los túneles de la red: M-30)
    if tg.get("bridge", "no") not in ("no", "") or tg.get("tunnel", "no") not in ("no", "") or tg.get("covered") == "yes":
        continue
    if tg.get("layer", "0") not in ("0", ""):
        continue
    s = sentido(tg); ns = w["nodos"]
    for i, (a, b) in enumerate(zip(ns, ns[1:])):
        m = metros(a, b)
        if s >= 0: osm_ad[a].append((b, m, wid)); osm_inv[b].append((a, m, wid))
        if s <= 0: osm_ad[b].append((a, m, wid)); osm_inv[a].append((b, m, wid))
CON_MAX = 1500.0
def sin_terreno(tg):
    return tg.get("bridge", "no") not in ("no", "") or tg.get("tunnel", "no") not in ("no", "") or tg.get("covered") == "yes"
interior_de = {}     # nodo interior de un tramo de la red (sin puente ni túnel) -> índice del tramo
for i_t, t in enumerate(d["tramos"]):
    if sin_terreno(t["tags"]): continue
    for n in t["nodos"][1:-1]: interior_de[n] = i_t
principal = scc_principal(d["tramos"])
en_red = set(n for t in d["tramos"] for n in (t["nodos"][0], t["nodos"][-1]))
# glorietas de la red (tramos de anillo unidos por nodos)
padre2 = {}
def raiz2(x):
    while padre2.setdefault(x, x) != x:
        padre2[x] = padre2[padre2[x]]; x = padre2[x]
    return x
for t in d["tramos"]:
    if t["tags"].get("junction") in ("roundabout", "circular"):
        ns = t["nodos"]; padre2[raiz2(ns[0])] = raiz2(ns[-1])
gl = collections.defaultdict(set)
for t in d["tramos"]:
    if t["tags"].get("junction") in ("roundabout", "circular"):
        for n in (t["nodos"][0], t["nodos"][-1]): gl[raiz2(n)].add(n)
def camino(origen, grafo):
    """Dijkstra desde los nodos de origen hasta el primer nodo de la red principal; [(a, b, way)] en sentido de marcha"""
    dist = {n: 0.0 for n in origen}; prev = {}; h = [(0.0, n) for n in origen]; heapq.heapify(h); fin = None
    while h:
        dd, n = heapq.heappop(h)
        if dd > dist.get(n, 1e18): continue
        if n not in origen and ((n in principal and n in en_red) or (n in interior_de and
                all(x in principal for x in (d["tramos"][interior_de[n]]["nodos"][0], d["tramos"][interior_de[n]]["nodos"][-1])))):
            fin = n; break
        for (m, l, wid) in grafo.get(n, ()):
            if m in interior and m not in en_red and m not in interior_de:
                continue      # cruzaría un puente o túnel de la red por un nodo suyo
            nd = dd + l
            if nd <= CON_MAX and nd < dist.get(m, 1e18):
                dist[m] = nd; prev[m] = (n, wid); heapq.heappush(h, (nd, m))
    if fin is None: return None
    pasos = []; n = fin
    while n in prev:
        p, wid = prev[n]; pasos.append((p, n, wid)); n = p
    return pasos      # del fin hacia el origen
aristas2 = set(aristas)
for t in fin:
    for a, b in zip(t["nodos"], t["nodos"][1:]): aristas2.add((a, b)); aristas2.add((b, a))
nuevos_c = []; n_sal = n_ent = n_sin = 0; sin_conector = []
red_ad = collections.defaultdict(list); red_inv = collections.defaultdict(list)
for t in d["tramos"]:
    a, b = t["nodos"][0], t["nodos"][-1]; s = sentido(t["tags"])
    if s >= 0: red_ad[a].append(b); red_inv[b].append(a)
    if s <= 0: red_ad[b].append(a); red_inv[a].append(b)
def llega(origen, grafo):
    vis = set(origen); pila = list(origen)
    while pila:
        v = pila.pop()
        if v in principal: return True
        for w in grafo.get(v, ()):
            if w not in vis: vis.add(w); pila.append(w)
    return False
for raiz_, ns in gl.items():
    if all(n in principal for n in ns): continue
    for direc in ("salida", "entrada"):
        if llega(ns, red_ad if direc == "salida" else red_inv): continue
        # ¿hace falta? salida: desde la glorieta no se llega a la red principal (BFS dirigido por la red del juego)
        pasos = camino(set(ns), osm_ad if direc == "salida" else osm_inv)
        if pasos is None:
            n_sin += 1
            lon, lat = (coord.get(next(iter(ns))) or d['coord'][next(iter(ns))]); sin_conector.append([direc, round(lon, 5), round(lat, 5)]); continue
        if direc == "salida": pasos = pasos[::-1]                       # glorieta -> red
        else: pasos = [(b, a, w) for (a, b, w) in pasos]               # red -> glorieta (ya en orden)
        nuevas = [(a, b, w) for (a, b, w) in pasos if (a, b) not in aristas2]
        if not nuevas: continue
        if direc == "salida": n_sal += 1
        else: n_ent += 1
        run = []; wrun = None
        for (a, b, w) in nuevas:
            if run and (run[-1] != a or w != wrun or a in en_red):
                nuevos_c.append({"way": wrun, "tags": viales[wrun]["tags"], "nodos": run}); run = []
            if not run: run = [a]; wrun = w
            run.append(b)
            aristas2.add((a, b)); aristas2.add((b, a))
        if run: nuevos_c.append({"way": wrun, "tags": viales[wrun]["tags"], "nodos": run})
# un conector recorrido al revés de como está dibujada su vía de OSM: los nodos en el orden de la vía para que el
# sentido único (oneway=yes) siga valiendo
for t in nuevos_c:
    ns_way = viales[t["way"]]["nodos"]
    try:
        if ns_way.index(t["nodos"][0]) > ns_way.index(t["nodos"][-1]): t["nodos"] = t["nodos"][::-1]
    except ValueError:
        pass
# tramos de la red con un nodo interior donde llega un conector: se parten ahí (la primera parte conserva su número,
# la segunda va al final), así el conector queda unido y los demás números no cambian
cortes = collections.defaultdict(set)
for t in nuevos_c:
    for n in (t["nodos"][0], t["nodos"][-1]):
        if n in interior_de and n not in en_red: cortes[interior_de[n]].add(n)
partidos = []
for i_t, ns_c in cortes.items():
    t = d["tramos"][i_t]; ns = t["nodos"]
    trozos = []; ini = 0
    for j in range(1, len(ns) - 1):
        if ns[j] in ns_c:
            trozos.append(ns[ini:j + 1]); ini = j
    trozos.append(ns[ini:])
    d["tramos"][i_t] = dict(t, nodos=trozos[0])
    for tz in trozos[1:]:
        partidos.append(dict(t, nodos=tz))
for t in nuevos_c:
    for n in t["nodos"]:
        if n not in d["coord"]:
            d["coord"][n] = coord[n]
d["tramos"] += partidos + nuevos_c
principal2 = scc_principal(d["tramos"])
quedan = sum(1 for ns in gl.values() if not all(n in principal2 for n in ns))
pickle.dump(d, open(sal, "wb"))
print(json.dumps({"glorietas_completadas": n_glorietas, "tramos_nuevos": len(fin), "tramos_total": len(d["tramos"]),
                  "nodos_total": len(d["coord"]), "cortes_en_interior_de_tramo": n_cruce_interior,
                  "conectores_salida": n_sal, "conectores_entrada": n_ent, "tramos_conectores": len(nuevos_c), "tramos_partidos": len(cortes),
                  "sin_conector": n_sin, "glorietas_fuera_de_la_red_principal": [len([1 for ns in gl.values() if not all(n in principal for n in ns)]), quedan]}))
json.dump(sin_conector, open(sal + ".sin_conector.json", "w"))
json.dump(ejemplos, open(sal + ".glorietas.json", "w"))
