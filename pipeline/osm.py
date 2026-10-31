"""Descarga de la red de carreteras desde OpenStreetMap.

v1: Overpass API por bbox (rápido para una zona).
Para toda España: ver README (Geofabrik spain-latest.osm.pbf + osmium/pyosmium);
la función `ways_desde_pbf` muestra el mismo formato de salida.
"""
import json, os, time, hashlib
import requests

OVERPASS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
TIPOS = ("motorway|trunk|primary|secondary|tertiary|unclassified|"
         "motorway_link|trunk_link|primary_link|secondary_link|tertiary_link")
UA = {"User-Agent": "carreteras-espana/0.1 (prototipo de juego educativo)"}


CARRETERAS = set(TIPOS.split("|")) | {"residential"}
SIN_ASFALTO = {"unpaved", "gravel", "dirt", "ground", "earth", "grass", "sand", "compacted", "fine_gravel", "mud", "pebblestone"}


def es_carretera(tags):
    """Carretera real por la que circulan coches: nunca path/track/footway/cycleway (sendas GR, pistas),
    ni vías marcadas sin asfaltar, ni las cerradas al tráfico."""
    if tags.get("highway") not in CARRETERAS:
        return False
    if tags.get("surface", "") in SIN_ASFALTO:
        return False
    return tags.get("access", "") not in ("no", "private") and tags.get("motor_vehicle", "") not in ("no", "private")


def descargar_ways(bbox, cache_dir, timeout=120, tipos=TIPOS):
    """bbox = (sur, oeste, norte, este) en grados WGS84.
    Devuelve una lista de dicts {id, tags, nodes, geom:[(lat,lon),...]}"""
    s, o, n, e = bbox
    q = (f'[out:json][timeout:{timeout}];'
         f'way["highway"~"^({tipos})$"]({s},{o},{n},{e});out body geom;')
    os.makedirs(cache_dir, exist_ok=True)
    clave = hashlib.md5(q.encode()).hexdigest()[:12]
    ruta_cache = os.path.join(cache_dir, f"osm_{clave}.json")
    if os.path.exists(ruta_cache):
        datos = json.load(open(ruta_cache))
    else:
        datos, ultimo_error = None, None
        for url in OVERPASS:
            for intento in range(2):
                try:
                    r = requests.post(url, data={"data": q}, headers=UA, timeout=timeout + 30)
                    if r.status_code == 200:
                        datos = r.json(); break
                    ultimo_error = f"{url}: HTTP {r.status_code}"
                except requests.RequestException as ex:
                    ultimo_error = f"{url}: {ex}"
                time.sleep(3)
            if datos: break
        if datos is not None:
            datos["_fuente"] = {"url": url, "fecha": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        if datos is None:
            raise RuntimeError(f"Overpass no respondió: {ultimo_error}")
        json.dump(datos, open(ruta_cache, "w"))
    ways = []
    for el in datos["elements"]:
        if el.get("type") != "way" or "geometry" not in el:
            continue
        ways.append({"id": el["id"], "tags": el.get("tags", {}), "nodes": el["nodes"],
                     "geom": [(p["lat"], p["lon"]) for p in el["geometry"]]})
    return ways


def ways_desde_pbf(ruta_pbf, bbox=None):
    """Igual que descargar_ways pero leyendo un .osm.pbf local (p.ej. Geofabrik España).
    Requiere `pip install osmium`. Para toda España conviene recortar antes por
    teselas con `osmium extract -b oeste,sur,este,norte spain-latest.osm.pbf -o tesela.pbf`."""
    import osmium
    import re
    patron = re.compile(f"^({TIPOS})$")
    ways = []

    class H(osmium.SimpleHandler):
        def way(self, w):
            if not patron.match(w.tags.get("highway", "")):
                return
            try:
                geom = [(n.lat, n.lon) for n in w.nodes]
            except osmium.InvalidLocationError:
                return
            if bbox:
                s, o, n_, e = bbox
                if not any(s <= la <= n_ and o <= lo <= e for la, lo in geom):
                    return
            ways.append({"id": w.id, "tags": dict(w.tags), "nodes": [n.ref for n in w.nodes], "geom": geom})
    H().apply_file(ruta_pbf, locations=True)
    return ways


def consulta_bosque(bbox, timeout=150, parques=False):
    """Consulta Overpass de bosques reales (landuse=forest, natural=wood; con parques=True también leisure=park)."""
    s, o, n, e = bbox
    extra = (f'way["leisure"="park"]({s},{o},{n},{e});relation["leisure"="park"]({s},{o},{n},{e});') if parques else ''
    return (f'[out:json][timeout:{timeout}];(way["landuse"="forest"]({s},{o},{n},{e});way["natural"="wood"]({s},{o},{n},{e});'
            f'relation["landuse"="forest"]({s},{o},{n},{e});relation["natural"="wood"]({s},{o},{n},{e});{extra});out body geom;')


def mascara_bosque(bbox, cache_dir, utm, gxs, gys, timeout=150, parques=False):
    """Máscara booleana (filas = gys, columnas = gxs, UTM) de bosque real según OSM:
    landuse=forest y natural=wood (vías cerradas y multipolígonos)."""
    from matplotlib.path import Path
    import numpy as np
    q = consulta_bosque(bbox, timeout, parques)
    clave = hashlib.md5(q.encode()).hexdigest()[:12]
    ruta_cache = os.path.join(cache_dir, f"osm_{clave}.json")
    if os.path.exists(ruta_cache):
        datos = json.load(open(ruta_cache))
    else:
        datos = None
        for url in OVERPASS:
            try:
                r = requests.post(url, data={"data": q}, headers=UA, timeout=timeout + 30)
                if r.status_code == 200 and r.text.lstrip().startswith("{"):
                    datos = r.json(); break
            except requests.RequestException:
                pass
            time.sleep(3)
        if datos is None:
            raise RuntimeError("Overpass no respondió (bosques)")
        json.dump(datos, open(ruta_cache, "w"))
    GX, GY = np.meshgrid(gxs, gys)
    P = np.column_stack([GX.ravel(), GY.ravel()])
    dentro = np.zeros(len(P), bool)
    def anillo(geom, signo):
        nonlocal dentro
        if len(geom) < 4: return
        xs, ys = utm.transform([p["lon"] for p in geom], [p["lat"] for p in geom])
        m = Path(np.column_stack([xs, ys])).contains_points(P)
        dentro = (dentro | m) if signo > 0 else (dentro & ~m)
    for el in datos["elements"]:
        if el["type"] == "way" and "geometry" in el:
            anillo(el["geometry"], 1)
        elif el["type"] == "relation":
            # outers primero, luego se quitan los inners (claros)
            outers = [m for m in el.get("members", []) if m.get("role") != "inner" and "geometry" in m]
            inners = [m for m in el.get("members", []) if m.get("role") == "inner" and "geometry" in m]
            for m in _unir_anillos(outers): anillo(m, 1)
            for m in _unir_anillos(inners): anillo(m, -1)
    return dentro.reshape(GX.shape)


def _unir_anillos(miembros):
    """Une los trozos de un multipolígono en anillos cerrados (por coincidencia de extremos)."""
    trozos = [[(p["lat"], p["lon"]) for p in m["geometry"]] for m in miembros]
    anillos = []
    while trozos:
        a = trozos.pop(0)
        cambio = True
        while a[0] != a[-1] and cambio:
            cambio = False
            for k, b in enumerate(trozos):
                if b[0] == a[-1]: a = a + b[1:]
                elif b[-1] == a[-1]: a = a + b[::-1][1:]
                elif b[-1] == a[0]: a = b + a[1:]
                elif b[0] == a[0]: a = b[::-1] + a[1:]
                else: continue
                trozos.pop(k); cambio = True; break
        anillos.append([{"lat": la, "lon": lo} for la, lo in a])
    return anillos
