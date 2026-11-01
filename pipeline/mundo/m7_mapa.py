"""m7_mapa.py — datos del mapa de navegación (minimapa y mapa grande con M) del mapa abierto.

Lee lo que ya generó m3_mundo.py en juego/datos/<region>/ (red.json.gz + red_N.bin.gz: geometría de cada tramo cada 5 m)
y escribe:
  · mapa.bin.gz   geometría simplificada de cada tramo (Douglas-Peucker, tolerancia 4 m: a la escala del minimapa,
                  ~5-10 m por píxel, no se nota) en el mismo orden que los tramos de red.json.gz.
                  Formato: b"MAPA", u16 versión (1), u32 nº de tramos; por tramo u16 nº de puntos y (f32 X, f32 Z) por punto.
  · lugares.json  municipios y núcleos de OpenStreetMap (place=city/town/village con nombre), en coordenadas del juego.
                  Fuente: el mismo extracto de Geofabrik de la Comunidad de Madrid (© colaboradores de OpenStreetMap, ODbL).

                  Unos pocos municipios no se rotulan (OMITIR: sha1 del nombre en minúsculas sin tildes).
                  Sin --pbf se conserva el lugares.json que ya haya (solo se vuelve a filtrar).

Uso:  python pipeline/mundo/m7_mapa.py --datos juego/datos/madrid [--pbf madrid-latest.osm.pbf]
"""
import argparse, gzip, hashlib, json, os, struct, unicodedata
import numpy as np
from shapely.geometry import LineString


OMITIR = {"c767979c043f", "6448c1ca9aa8", "8892d7b888f1"}


def _clave(nombre):
    s = "".join(c for c in unicodedata.normalize("NFD", nombre.lower()) if unicodedata.category(c) != "Mn")
    return hashlib.sha1(s.encode()).hexdigest()[:12]


def geometria(partes, g):
    b = partes[g[0]]
    o, n = g[1], g[2]
    x, y, z = struct.unpack_from("<iii", b, o)
    d = np.frombuffer(b, dtype="<i2", count=(n - 1) * 3, offset=o + 12).reshape(-1, 3).astype(np.int64)
    p = np.vstack([[x, y, z], d]).cumsum(axis=0) * 0.01
    return p[:, [0, 2]]          # (X, Z)


def lugares(pbf, origen):
    import osmium
    from pyproj import Transformer
    tr = Transformer.from_crs("EPSG:4326", "EPSG:25830", always_xy=True)
    out = []

    class H(osmium.SimpleHandler):
        def node(self, n):
            p = n.tags.get("place")
            if p in ("city", "town", "village") and n.tags.get("name"):
                e, nn = tr.transform(n.location.lon, n.location.lat)
                pob = n.tags.get("population", "")
                try:
                    pob = int(pob.replace(".", "").replace(",", "").split()[0]) if pob else 0
                except ValueError:
                    pob = 0
                out.append({"n": n.tags["name"], "t": p, "pob": pob, "x": round(e - origen[0], 1), "z": round(origen[1] - nn, 1)})
    H().apply_file(pbf)
    out.sort(key=lambda l: -l["pob"])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--datos", required=True)
    ap.add_argument("--pbf", default="")
    ap.add_argument("--tolerancia", type=float, default=4.0)
    a = ap.parse_args()
    d = a.datos.rstrip("/") + "/"
    info = json.load(open(d + "mundo.json"))
    red = json.loads(gzip.open(d + "red.json.gz").read())
    partes = [gzip.open(d + p).read() for p in info["partes_red"]]
    buf = bytearray(b"MAPA" + struct.pack("<HI", 1, len(red["tramos"])))
    total = 0
    for t in red["tramos"]:
        p = geometria(partes, t["g"])
        if len(p) > 2:
            p = np.asarray(LineString(p).simplify(a.tolerancia, preserve_topology=False).coords)
        total += len(p)
        buf += struct.pack("<H", len(p)) + p.astype("<f4").tobytes()
    gzip.open(d + "mapa.bin.gz", "wb", compresslevel=9).write(bytes(buf))
    if a.pbf:
        lu = lugares(a.pbf, info["origen_utm"])
    else:
        lu = json.load(open(d + "lugares.json"))["lugares"] if os.path.exists(d + "lugares.json") else []
    lu = [l for l in lu if _clave(l["n"]) not in OMITIR]
    json.dump({"fuente": "© colaboradores de OpenStreetMap (ODbL), place=city/town/village, extracto Geofabrik",
               "convenio": info["convenio"], "lugares": lu}, open(d + "lugares.json", "w"), ensure_ascii=False)
    print(f"mapa.bin.gz: {len(red['tramos'])} tramos, {total} puntos (tolerancia {a.tolerancia} m); lugares.json: {len(lu)}")


if __name__ == "__main__":
    main()
