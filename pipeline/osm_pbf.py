"""OSM desde un extracto .osm.pbf de Geofabrik (cuando Overpass está saturado).
Escribe JSON con el MISMO formato que Overpass ('out body geom') en las rutas de caché que usan
osm.descargar_ways / osm.mascara_bosque, así extraer.py y extras_zona.py funcionan sin cambios.
Uso (venv con `pip install osmium`):
  python pipeline/osm_pbf.py --pbf madrid-261030.osm.pbf --bbox 40.27,-3.86,40.36,-3.66 --zona m406 --tipos-residential
"""
import argparse, hashlib, json, os, sys, time
import osmium

sys.path.insert(0, os.path.dirname(__file__))
import osm as O

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AREAS = {("landuse", "forest"), ("natural", "wood"), ("landuse", "residential"), ("leisure", "park")}


def leer(pbf, bbox):
    s, o, n, e = bbox
    rels, miembros = {}, set()
    for r in osmium.FileProcessor(pbf, osmium.osm.RELATION):
        t = dict(r.tags)
        if t.get("type") == "multipolygon" and any((k, t.get(k)) in AREAS for k in ("landuse", "natural", "leisure")):
            rels[r.id] = (t, [(m.ref, m.role) for m in r.members if m.type == "w"])
            miembros.update(m.ref for m in r.members if m.type == "w")
    ways, geom_m, nodos = [], {}, []
    fp = osmium.FileProcessor(pbf, osmium.osm.NODE | osmium.osm.WAY).with_locations()
    for obj in fp:
        if obj.is_node():
            t = dict(obj.tags)
            if t and s <= obj.location.lat <= n and o <= obj.location.lon <= e and \
                    (t.get("highway") == "traffic_signals" or "traffic_sign" in t or t.get("place") in ("village", "town", "hamlet", "city", "suburb")):
                nodos.append({"type": "node", "id": obj.id, "lat": obj.location.lat, "lon": obj.location.lon, "tags": t})
            continue
        t = dict(obj.tags)
        es_area = any((k, t.get(k)) in AREAS for k in ("landuse", "natural", "leisure"))
        if "highway" not in t and not es_area and obj.id not in miembros:
            continue
        try:
            g = [{"lat": nd.lat, "lon": nd.lon} for nd in obj.nodes]
        except osmium.InvalidLocationError:
            continue
        if obj.id in miembros: geom_m[obj.id] = g
        if "highway" not in t and not es_area: continue
        if not any(s <= p["lat"] <= n and o <= p["lon"] <= e for p in g): continue
        ways.append({"type": "way", "id": obj.id, "nodes": [nd.ref for nd in obj.nodes], "tags": t, "geometry": g})
    relaciones = []
    for rid, (t, mm) in rels.items():
        mem = [{"type": "way", "ref": wid, "role": rol, "geometry": geom_m[wid]} for wid, rol in mm if wid in geom_m]
        if any(s <= p["lat"] <= n and o <= p["lon"] <= e for m in mem for p in m["geometry"]):
            relaciones.append({"type": "relation", "id": rid, "tags": t, "members": mem})
    return ways, relaciones, nodos


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pbf", required=True); ap.add_argument("--bbox", required=True); ap.add_argument("--zona", required=True)
    ap.add_argument("--tipos-residential", action="store_true", help="tipos = osm.TIPOS + |residential (como el preset a308)")
    ap.add_argument("--parques", action="store_true", help="la máscara de árboles incluye leisure=park")
    a = ap.parse_args()
    bbox = tuple(float(v) for v in a.bbox.split(",")); s, o, n, e = bbox
    cache = os.path.join(RAIZ, "cache", "osm"); os.makedirs(cache, exist_ok=True)
    t0 = time.time(); ways, rels, nodos = leer(a.pbf, bbox)
    fuente = {"url": "https://download.geofabrik.de/europe/spain/" + os.path.basename(a.pbf), "fecha": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(os.path.getmtime(a.pbf))),
              "nota": "extracto Geofabrik (OSM ODbL) convertido a formato Overpass por pipeline/osm_pbf.py"}
    def env(els): return {"version": 0.6, "generator": "osm_pbf.py", "elements": els, "_fuente": fuente}
    hw = [w for w in ways if "highway" in w["tags"]]
    # 1) caché de osm.descargar_ways (mismo texto de consulta → misma clave)
    tipos = O.TIPOS + "|residential" if a.tipos_residential else O.TIPOS
    import re
    pat = re.compile(f"^({tipos})$")
    q = f'[out:json][timeout:120];way["highway"~"^({tipos})$"]({s},{o},{n},{e});out body geom;'
    json.dump(env([w for w in hw if pat.match(w["tags"]["highway"])]), open(os.path.join(cache, f"osm_{hashlib.md5(q.encode()).hexdigest()[:12]}.json"), "w"))
    # 2) caché de bosques (osm.mascara_bosque)
    q = O.consulta_bosque(bbox, parques=a.parques)
    def bos(t): return t.get("landuse") == "forest" or t.get("natural") == "wood" or (a.parques and t.get("leisure") == "park")
    json.dump(env([w for w in ways if bos(w["tags"])] + [r for r in rels if bos(r["tags"])]),
              open(os.path.join(cache, f"osm_{hashlib.md5(q.encode()).hexdigest()[:12]}.json"), "w"))
    # 3) para extras_zona.py: todas las highway + residencial/señales/semáforos
    json.dump({"fecha": fuente["fecha"], "url": fuente["url"], "query": f"way[highway]({s},{o},{n},{e}) desde pbf", "datos": env(hw)},
              open(os.path.join(cache, f"{a.zona}_todas_highway.json"), "w"))
    json.dump({"fecha": fuente["fecha"], "url": fuente["url"], "query": f"landuse=residential + place + traffic_sign + traffic_signals ({s},{o},{n},{e}) desde pbf",
               "datos": env([w for w in ways if w["tags"].get("landuse") == "residential"] + [r for r in rels if r["tags"].get("landuse") == "residential"] + nodos)},
              open(os.path.join(cache, f"{a.zona}_residencial_senales.json"), "w"))
    print(f"{len(hw)} vías highway, {len(rels)} relaciones de área, {len(nodos)} nodos en {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()
