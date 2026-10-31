#!/usr/bin/env python3
"""Quitamiedos (biondas / barreras de seguridad) REALES junto a las rutas de una zona, sacados de OpenStreetMap.

Solo se ponen donde OSM tiene una barrera mapeada (barrier=guard_rail / jersey_barrier / crash_barrier /
concrete_barrier, o una vía con etiquetas guard_rail:* / barrier:*=guard_rail). Nada inventado ni genérico:
si OSM no tiene ninguna junto a la ruta, el archivo sale vacío y el juego no dibuja ninguna.

Cada barrera (vía OSM) se remuestrea cada 1 m, se proyecta sobre el eje de la ruta más cercana (la que dibuja
ese trozo) y se queda si está a ≤ 15 m del eje, es casi paralela a la carretera (≤ 35°) y queda fuera de la
calzada. De ahí sale el tramo [s0, s1] en metros de ruta (PK) y el lado (+1 derecha / −1 izquierda en el
sentido de PK creciente). La posición lateral exacta de OSM tiene errores de metros, así que en el juego el
quitamiedos se coloca al borde de la calzada (ancho/2 + 0,7 m); la medida de OSM se guarda en "off_osm".

Uso:
  python pipeline/quitamiedos.py --zona navacerrada        # descarga (Overpass, con caché) y escribe
  python pipeline/quitamiedos.py --zona a308 --osm fichero.json   # usar una respuesta Overpass ya descargada
Salida: juego/datos/<zona>/quitamiedos.json
Coordenadas: las del pipeline (EPSG:25830, X = E − E0, Z = N0 − N, origen de zona.json).
"""
import argparse, json, os, sys, time
import numpy as np
import requests
from pyproj import Transformer
from scipy.spatial import cKDTree

sys.path.insert(0, os.path.dirname(__file__))
import osm

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TIPOS_BARRERA = "guard_rail|jersey_barrier|crash_barrier|concrete_barrier"
MAX_DIST = 15.0       # m del eje de la ruta
MAX_ANGULO = 35.0     # grados respecto a la carretera
HUECO_MAX = 6.0       # m: huecos menores se unen
TRAMO_MIN = 8.0       # m: tramos menores se descartan
MARGEN_BORDE = 0.7    # m más allá del borde de la calzada (donde se dibuja)


def consulta(bbox, timeout=50):
    s, o, n, e = bbox
    b = f"{s},{o},{n},{e}"
    return (f'[out:json][timeout:{timeout}];('
            f'way["barrier"~"^({TIPOS_BARRERA})$"]({b});'
            f'way[~"guard_?rail|crash_barrier"~"."]({b});'
            f'way[~"barrier"~"guard_rail|jersey|crash"]({b}););out tags geom;')


def descargar(bbox, cache):
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    if os.path.exists(cache):
        return json.load(open(cache))
    q = consulta(bbox)
    ultimo = None
    for url in osm.OVERPASS:
        try:
            r = requests.post(url, data={"data": q}, headers=osm.UA, timeout=60)
            r.raise_for_status()
            d = r.json()
            json.dump(d, open(cache, "w"))
            return d
        except Exception as ex:          # siguiente servidor
            ultimo = ex
            print("  Overpass", url, "falló:", ex)
            time.sleep(2)
    raise SystemExit(f"Overpass no respondió: {ultimo}")


def es_barrera(tags):
    if tags.get("barrier", "") in TIPOS_BARRERA.split("|"):
        return True
    for k, v in tags.items():
        if "guard_rail" in k or "guardrail" in k or "crash_barrier" in k:
            return v not in ("no", "none")
        if "barrier" in k and any(t in v for t in ("guard_rail", "jersey", "crash")):
            return True
    return False


def remuestrear(xy, paso=1.0):
    seg = np.hypot(*np.diff(xy, axis=0).T)
    s = np.concatenate([[0], np.cumsum(seg)])
    if s[-1] < paso:
        return xy, s[-1]
    t = np.arange(0, s[-1] + 1e-6, paso)
    return np.c_[np.interp(t, s, xy[:, 0]), np.interp(t, s, xy[:, 1])], s[-1]


def tramos_de(mask, paso):
    """Índices de muestra [a, b] de los tramos marcados, uniendo huecos < HUECO_MAX y quitando los < TRAMO_MIN."""
    idx = np.flatnonzero(mask)
    if idx.size == 0:
        return []
    out, a, b = [], idx[0], idx[0]
    for i in idx[1:]:
        if (i - b) * paso <= HUECO_MAX:
            b = i
        else:
            out.append([a, b]); a = b = i
    out.append([a, b])
    return [t for t in out if (t[1] - t[0]) * paso >= TRAMO_MIN]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zona", required=True)
    ap.add_argument("--osm", help="respuesta Overpass ya descargada (JSON)")
    ap.add_argument("--datos", default=os.path.join(RAIZ, "juego", "datos"))
    ap.add_argument("--cache", default=os.path.join(RAIZ, "cache"))
    a = ap.parse_args()
    dz = os.path.join(a.datos, a.zona)
    zona = json.load(open(os.path.join(dz, "zona.json")))
    car = json.load(open(os.path.join(dz, "carreteras.json")))
    E0, N0 = zona["origen_utm"]
    bbox = zona["bbox_wgs84"]
    d = json.load(open(a.osm)) if a.osm else descargar(bbox, os.path.join(a.cache, "osm", f"{a.zona}_quitamiedos.json"))
    ways = [w for w in d.get("elements", []) if w.get("type") == "way" and es_barrera(w.get("tags", {})) and len(w.get("geometry", [])) >= 2]
    print(f"[1/3] {a.zona}: {len(ways)} barreras en OSM dentro de la zona")

    # muestras de ruta que se dibujan (cada trozo lo dibuja una sola ruta: así no se duplican)
    utm = Transformer.from_crs(4326, 25830, always_xy=True)
    rutas = car["rutas"]
    R = []
    for ri, r in enumerate(rutas):
        x = np.asarray(r["x"], float); z = np.asarray(r["z"], float)
        tx = np.gradient(x); tz = np.gradient(z); nn = np.hypot(tx, tz) + 1e-9
        R.append({"x": x, "z": z, "tx": tx / nn, "tz": tz / nn, "ancho": np.asarray(r["ancho"], float),
                  "dib": np.asarray(r["dibujar"], int), "paso": float(r.get("paso", 2.0)),
                  "tunel": np.asarray(r.get("tunel", [0] * len(x)), int),
                  "cub": {1: np.zeros(len(x), bool), -1: np.zeros(len(x), bool)}, "off": {1: [], -1: []},
                  "ids": {1: set(), -1: set()}})
    pts, own = [], []
    for ri, q in enumerate(R):
        ok = np.flatnonzero((q["dib"] == 1) & (q["tunel"] == 0))
        pts.append(np.c_[q["x"][ok], q["z"][ok]]); own.append(np.c_[np.full(ok.size, ri), ok])
    pts = np.vstack(pts); own = np.vstack(own)
    arbol = cKDTree(pts)

    cos_max = np.cos(np.radians(MAX_ANGULO))
    usadas, metros_osm, dentro, lejos = 0, 0.0, 0, 0
    for w in ways:
        g = w["geometry"]
        E, N = utm.transform([p["lon"] for p in g], [p["lat"] for p in g])
        xy = np.c_[np.asarray(E) - E0, N0 - np.asarray(N)]
        m, largo = remuestrear(xy)
        metros_osm += largo
        if len(m) < 2:
            continue
        dirs = np.gradient(m, axis=0); dirs /= (np.hypot(*dirs.T)[:, None] + 1e-9)
        dist, k = arbol.query(m, distance_upper_bound=MAX_DIST)
        sirve = False
        for j in range(len(m)):
            if not np.isfinite(dist[j]):
                lejos += 1; continue
            ri, i = own[k[j]]
            q = R[ri]
            t = np.array([q["tx"][i], q["tz"][i]])
            if abs(t @ dirs[j]) < cos_max:
                continue
            der = np.array([-t[1], t[0]])          # derecha en Godot (X, Z) con Y hacia arriba
            lat = (m[j] - [q["x"][i], q["z"][i]]) @ der
            if abs(lat) < q["ancho"][i] * 0.5 - 1.0:   # dentro de la calzada: error de mapeo o mediana
                dentro += 1; continue
            lado = 1 if lat > 0 else -1
            q["cub"][lado][i] = True
            q["off"][lado].append(abs(lat)); q["ids"][lado].add(w["id"])
            sirve = True
        usadas += sirve

    salida = {"zona": a.zona,
              "fuente": "© colaboradores de OpenStreetMap (ODbL), vía Overpass API: barrier=" + TIPOS_BARRERA.replace("|", "/") +
                        " y etiquetas guard_rail:* / barrier:*",
              "descargado": time.strftime("%Y-%m-%d %H:%M"),
              "criterio": f"≤ {MAX_DIST:.0f} m del eje, ≤ {MAX_ANGULO:.0f}° respecto a la carretera, fuera de la calzada; huecos < {HUECO_MAX:.0f} m unidos, tramos < {TRAMO_MIN:.0f} m quitados",
              "margen_borde": MARGEN_BORDE,
              "lado": "+1 = derecha, -1 = izquierda, en el sentido de PK creciente de la ruta",
              "rutas": [], "estadisticas": {}}
    est = {"barreras_osm_zona": len(ways), "metros_osm_zona": round(metros_osm), "barreras_junto_a_rutas": usadas,
           "muestras_descartadas_dentro_calzada": dentro, "por_ruta": []}
    for ri, q in enumerate(R):
        tramos = []
        for lado in (1, -1):
            # rellena entre muestras marcadas (las de OSM caen cada ~1 m, la ruta va cada 2 m)
            for a0, b0 in tramos_de(q["cub"][lado], q["paso"]):
                tramos.append({"lado": lado, "s0": round(a0 * q["paso"], 1), "s1": round(b0 * q["paso"], 1),
                               "off_osm": round(float(np.median(q["off"][lado])), 1)})
        tramos.sort(key=lambda t: t["s0"])
        largo = (len(q["x"]) - 1) * q["paso"]
        mdr = sum(t["s1"] - t["s0"] for t in tramos if t["lado"] == 1)
        miz = sum(t["s1"] - t["s0"] for t in tramos if t["lado"] == -1)
        if tramos:
            salida["rutas"].append({"ruta": ri, "nombre": rutas[ri]["nombre"], "tramos": tramos,
                                    "osm_ids": sorted(q["ids"][1] | q["ids"][-1])})
        est["por_ruta"].append({"ruta": ri, "nombre": rutas[ri]["nombre"], "longitud_m": round(largo),
                                "tramos": len(tramos), "m_derecha": round(mdr), "m_izquierda": round(miz),
                                "pct_derecha": round(100 * mdr / max(largo, 1), 2), "pct_izquierda": round(100 * miz / max(largo, 1), 2)})
    salida["estadisticas"] = est
    fp = os.path.join(dz, "quitamiedos.json")
    json.dump(salida, open(fp, "w"), ensure_ascii=False, indent=1)
    print(f"[2/3] {usadas} barreras junto a rutas; descartadas {dentro} muestras dentro de la calzada")
    for e in est["por_ruta"]:
        if e["tramos"]:
            print(f"   ruta {e['ruta']} {e['nombre']}: {e['tramos']} tramos, dcha {e['m_derecha']} m ({e['pct_derecha']} %), izda {e['m_izquierda']} m ({e['pct_izquierda']} %)")
    print(f"[3/3] escrito {fp} ({os.path.getsize(fp)} B)")


if __name__ == "__main__":
    main()
