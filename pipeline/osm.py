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


def descargar_ways(bbox, cache_dir, timeout=120):
    """bbox = (sur, oeste, norte, este) en grados WGS84.
    Devuelve una lista de dicts {id, tags, nodes, geom:[(lat,lon),...]}"""
    s, o, n, e = bbox
    q = (f'[out:json][timeout:{timeout}];'
         f'way["highway"~"^({TIPOS})$"]({s},{o},{n},{e});out body geom;')
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
