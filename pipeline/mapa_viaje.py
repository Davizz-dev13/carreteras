"""Mapa de viaje (scripts/mapa_viaje.gd): genera, en UTM 30N (EPSG:25830, metros),
  juego/datos/viaje_espana.json   contorno de España y vecinos (Natural Earth 1:10m admin 0, dominio público) + ciudades de referencia
  juego/datos/<zona>/viaje.json   rutas jugables (carreteras.json) y vías secundarias simplificadas (Douglas-Peucker 10 / 25 m)
  juego/datos/madrid/viaje.json   red interurbana del mapa abierto (tramos sin ramales, de red.json.gz + red_*.bin.gz; solo .exe)
Uso: python pipeline/mapa_viaje.py ne_10m_admin_0_countries.geojson
"""
import glob, gzip, json, math, os, struct, sys
import numpy as np

J = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "juego")
CIUDADES = [("Madrid", 40.4168, -3.7038), ("Segovia", 40.9429, -4.1088), ("Granada", 37.1773, -3.5986), ("Guadix", 37.2994, -3.1386),
            ("Baza", 37.4906, -2.7728), ("Toledo", 39.8628, -4.0273), ("Guadalajara", 40.6329, -3.1669), ("Ávila", 40.6565, -4.6818),
            ("Jaén", 37.7796, -3.7849), ("Almería", 36.8381, -2.4597), ("Málaga", 36.7213, -4.4214), ("Córdoba", 37.8882, -4.7794),
            ("Valladolid", 41.6523, -4.7245), ("Cuenca", 40.0704, -2.1374), ("Ciudad Real", 38.9848, -3.9274), ("Murcia", 37.9922, -1.1307),
            ("Albacete", 38.9943, -1.8585), ("Sevilla", 37.3891, -5.9845), ("Valencia", 39.4699, -0.3763), ("Zaragoza", 41.6488, -0.8891),
            ("Salamanca", 40.9701, -5.6635), ("Cáceres", 39.4753, -6.3724), ("Badajoz", 38.8794, -6.9707), ("Burgos", 42.3439, -3.6969)]


def rdp(pts, eps):
    pts = np.asarray(pts, float)
    if len(pts) < 3:
        return pts
    keep = np.zeros(len(pts), bool); keep[0] = keep[-1] = True
    pila = [(0, len(pts) - 1)]
    while pila:
        a, b = pila.pop()
        if b <= a + 1:
            continue
        p0, p1 = pts[a], pts[b]; seg = p1 - p0; L = np.hypot(*seg); sub = pts[a + 1:b]
        d = np.hypot(*(sub - p0).T) if L < 1e-9 else np.abs(seg[0] * (sub[:, 1] - p0[1]) - seg[1] * (sub[:, 0] - p0[0])) / L
        i = int(np.argmax(d))
        if d[i] > eps:
            m = a + 1 + i; keep[m] = True; pila += [(a, m), (m, b)]
    return pts[keep]


def utm30(lat, lon):
    a = 6378137.0; f = 1 / 298.257222101; e2 = f * (2 - f); k0 = 0.9996; lon0 = math.radians(-3); ep2 = e2 / (1 - e2)
    la = math.radians(lat); lo = math.radians(lon)
    N = a / math.sqrt(1 - e2 * math.sin(la) ** 2); T = math.tan(la) ** 2; C = ep2 * math.cos(la) ** 2; A = math.cos(la) * (lo - lon0)
    M = a * ((1 - e2 / 4 - 3 * e2 ** 2 / 64 - 5 * e2 ** 3 / 256) * la - (3 * e2 / 8 + 3 * e2 ** 2 / 32 + 45 * e2 ** 3 / 1024) * math.sin(2 * la)
             + (15 * e2 ** 2 / 256 + 45 * e2 ** 3 / 1024) * math.sin(4 * la) - (35 * e2 ** 3 / 3072) * math.sin(6 * la))
    E = k0 * N * (A + (1 - T + C) * A ** 3 / 6 + (5 - 18 * T + T * T + 72 * C - 58 * ep2) * A ** 5 / 120) + 500000
    Nn = k0 * (M + N * math.tan(la) * (A * A / 2 + (5 - T + 9 * C + 4 * C * C) * A ** 4 / 24 + (61 - 58 * T + T * T + 600 * C - 330 * ep2) * A ** 6 / 720))
    return E, Nn


def plano(q):
    return [int(round(v)) for xy in q for v in xy]


def zonas():
    for z in ["navacerrada", "a308", "gr8101", "m406"]:
        zi = json.load(open(f"{J}/datos/{z}/zona.json")); e0, n0 = zi["origen_utm"]
        cj = json.load(open(f"{J}/datos/{z}/carreteras.json"))
        rutas = []
        for r in cj["rutas"]:
            q = rdp(np.c_[r["x"], r["z"]], 10.0)
            rutas.append({"nombre": r["nombre"], "p": plano(np.c_[q[:, 0] + e0, n0 - q[:, 1]])})
        vias = list(cj.get("vias", []))
        for f in sorted(glob.glob(f"{J}/datos/{z}/vias_*.json")):
            vv = json.load(open(f)); vias += vv if isinstance(vv, list) else vv.get("vias", [])
        sal = []
        for v in vias:
            if len(v.get("x", [])) >= 2:
                q = rdp(np.c_[v["x"], v["z"]], 25.0); sal.append(plano(np.c_[q[:, 0] + e0, n0 - q[:, 1]]))
        json.dump({"rutas": rutas, "vias": sal}, open(f"{J}/datos/{z}/viaje.json", "w"), separators=(",", ":"))


def madrid():
    d = f"{J}/datos/madrid"
    mi = json.load(open(f"{d}/mundo.json")); E0, N0 = mi["origen_utm"]
    red = json.loads(gzip.open(f"{d}/red.json.gz").read())
    partes = [gzip.open(f"{d}/{p}").read() for p in mi["partes_red"]]
    lineas = []
    for t in red["tramos"]:
        if int(t["enlace"]) == 1:
            continue
        pi, o, n = t["g"]; b = partes[pi]
        x, y, z = struct.unpack_from("<iii", b, o); o += 12; pts = [(x, z)]
        for i in range(1, n):
            dx, dy, dz = struct.unpack_from("<hhh", b, o); o += 6; x += dx; z += dz; pts.append((x, z))
        q = rdp(np.array(pts) * 0.01, 25.0)
        lineas.append([int(t["c"])] + plano(np.c_[q[:, 0] + E0, N0 - q[:, 1]]))
    json.dump({"lineas": lineas}, open(f"{d}/viaje.json", "w"), separators=(",", ":"))


def espana(geojson):
    g = json.load(open(geojson)); polys = []
    for f in g["features"]:
        pais = f["properties"].get("ADMIN")
        if pais not in ("Spain", "Portugal", "France", "Andorra", "Morocco", "Gibraltar"):
            continue
        geom = f["geometry"]; cs = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
        for poly in cs:
            ring = poly[0]
            if not any(-10.5 < lo < 4.5 and 35 < la < 44.5 for lo, la in ring):
                continue
            pts = np.array([utm30(la, lo) for lo, la in ring if -12 < lo < 6 and 34 < la < 46])
            if len(pts) < 4:
                continue
            q = rdp(pts, 800.0)
            if len(q) >= 4:
                polys.append({"pais": pais, "p": [int(round(v / 10) * 10) for xy in q for v in xy]})
    ciudades = [{"n": n, "e": round(utm30(la, lo)[0]), "nn": round(utm30(la, lo)[1])} for n, la, lo in CIUDADES]
    json.dump({"_leeme": "Contorno: Natural Earth 1:10m (dominio público). UTM 30N (EPSG:25830), metros.", "poligonos": polys, "ciudades": ciudades},
              open(f"{J}/datos/viaje_espana.json", "w"), separators=(",", ":"), ensure_ascii=False)


if __name__ == "__main__":
    zonas()
    if os.path.exists(f"{J}/datos/madrid/mundo.json"):
        madrid()
    if len(sys.argv) > 1:
        espana(sys.argv[1])
