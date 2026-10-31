#!/usr/bin/env python3
"""Extrae carreteras reales (OSM) + relieve real (MDT) y genera los datos del juego a escala 1:1.

Ejemplos:
  python pipeline/extraer.py --zona navacerrada                    # demo incluida
  python pipeline/extraer.py --zona mi_zona --bbox 40.30,-3.80,40.40,-3.65 --rutas "M-501" "M-501+M-600"
  python pipeline/extraer.py --zona cop --preset navacerrada --mdt copernicus

Salida: juego/datos/<zona>/  (zona.json, rutas.json, terreno/*.bin, arboles/*.bin, estadisticas.json)
Coordenadas: ETRS89 / UTM 30N (EPSG:25830) en metros, relativas a un origen (E0, N0):
  X_godot = E - E0 ;  Z_godot = N0 - N (el norte es -Z) ;  Y_godot = altitud real (m sobre el nivel del mar).
"""
import argparse, json, os, re, sys, time
from collections import defaultdict
import numpy as np
from pyproj import Transformer
from scipy.spatial import cKDTree

sys.path.insert(0, os.path.dirname(__file__))
import osm, dem, rutas as R

PRESETS = {
    "navacerrada": {
        "bbox": (40.715, -4.08, 40.88, -3.96),
        "rutas": [("Puerto de Navacerrada (M-601 → CL-601)", ["M-601", "CL-601"]),
                  ("M-601 Navacerrada → Puerto", ["M-601"]),
                  ("CL-601 Puerto → Valsaín", ["CL-601"])],
    }
}
PASO_TERRENO = 20.0     # m entre vértices del terreno
TESELA = 2000.0         # m de lado por tesela de terreno
RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def recortar_a_rect(pts, xmin, ymin, xmax, ymax):
    """Se queda con el tramo continuo más largo dentro del rectángulo."""
    dentro = [(xmin <= p[0] <= xmax and ymin <= p[1] <= ymax) for p in pts]
    mejor, actual = [], []
    for p, d in zip(pts, dentro):
        if d: actual.append(p)
        else:
            if len(actual) > len(mejor): mejor = actual
            actual = []
    return actual if len(actual) > len(mejor) else mejor


def a_godot(r, E0, N0):
    return np.asarray(r["x"]) - E0, N0 - np.asarray(r["y"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zona", required=True, help="nombre de la carpeta de salida")
    ap.add_argument("--preset", help="zona predefinida (" + ", ".join(PRESETS) + ")")
    ap.add_argument("--bbox", help="sur,oeste,norte,este en grados (WGS84)")
    ap.add_argument("--rutas", nargs="*", default=None,
                    help='rutas a encadenar por ref; "A+B" une varias (p.ej. "M-601+CL-601")')
    ap.add_argument("--mdt", choices=["ign", "copernicus"], default="ign")
    ap.add_argument("--salida", default=os.path.join(RAIZ, "juego", "datos"))
    ap.add_argument("--cache", default=os.path.join(RAIZ, "cache"))
    a = ap.parse_args()
    preset = PRESETS.get(a.preset or a.zona, {})
    if a.bbox:
        bbox = tuple(float(v) for v in a.bbox.split(","))
    elif preset:
        bbox = preset["bbox"]
    else:
        ap.error("falta --bbox (o un --preset)")
    defs = list(preset.get("rutas", [])) if not a.rutas else [(r.replace("+", " + "), r.split("+")) for r in a.rutas]
    t0 = time.time()
    utm = Transformer.from_crs(4326, 25830, always_xy=True)
    s, o, n, e = bbox
    xs, ys = utm.transform([o, e, o, e], [s, s, n, n])
    xmin, xmax = min(xs), max(xs); ymin, ymax = min(ys), max(ys)
    # rejilla de terreno alineada a teselas de 2 km
    gx0 = np.floor(xmin / TESELA) * TESELA; gx1 = np.ceil(xmax / TESELA) * TESELA
    gy0 = np.floor(ymin / TESELA) * TESELA; gy1 = np.ceil(ymax / TESELA) * TESELA
    E0 = float(np.round((gx0 + gx1) / 2 / 1000) * 1000); N0 = float(np.round((gy0 + gy1) / 2 / 1000) * 1000)
    print(f"[1/6] Zona {a.zona}: {(xmax-xmin)/1000:.1f} x {(ymax-ymin)/1000:.1f} km, origen UTM30N E={E0:.0f} N={N0:.0f}")

    print(f"[2/6] MDT ({a.mdt}) …", flush=True)
    if a.mdt == "ign":
        arr, tr = dem.mdt_ign(gx0 - 100, gy0 - 100, gx1 + 100, gy1 + 100, os.path.join(a.cache, "mdt"))
        fuente_mdt = "IGN MDT05 (CNIG/IGN, LiDAR PNOA, malla 5 m, WCS servicios.idee.es) — CC BY 4.0 scne.es"
    else:
        arr, tr = dem.mdt_copernicus(gx0 - 100, gy0 - 100, gx1 + 100, gy1 + 100, os.path.join(a.cache, "mdt"))
        fuente_mdt = "Copernicus GLO-30 DSM (ESA/Airbus, AWS open data), reproyectado a 10 m"
    mdt = dem.Mdt(arr, tr)
    print(f"      rejilla {arr.shape[1]}x{arr.shape[0]} a {tr.a:.0f} m, altitud {np.nanmin(arr):.0f}–{np.nanmax(arr):.0f} m")

    print("[3/6] OpenStreetMap (Overpass) …", flush=True)
    ways = osm.descargar_ways(bbox, os.path.join(a.cache, "osm"))
    print(f"      {len(ways)} vías")
    # rutas automáticas: cada ref de carretera (M-601, CL-601, N-VI …) con > 2 km en la zona
    por_ref = defaultdict(list)
    for w in ways:
        for r in R.refs_de(w["tags"]):
            if re.match(r"^[A-Z]{1,3}-\d", r) and not r.startswith("GR"): por_ref[r].append(w)
    usados = {tuple(sorted(d[1])) for d in defs}
    if not a.rutas:
        for ref in sorted(por_ref):
            if (ref,) not in usados: defs.append((ref, [ref]))

    print("[4/6] Rutas …", flush=True)
    salida = os.path.join(a.salida, a.zona); os.makedirs(os.path.join(salida, "terreno"), exist_ok=True)
    os.makedirs(os.path.join(salida, "arboles"), exist_ok=True)
    rutas_out, stats, ways_dibujadas, procesadas = [], {}, set(), []
    for nombre, refs in defs:
        sel = [w for w in ways if set(R.refs_de(w["tags"])) & set(refs)]
        if not sel: print(f"      {nombre}: sin vías"); continue
        pts = R.encadenar(sel, utm)
        pts = recortar_a_rect(pts, xmin + 50, ymin + 50, xmax - 50, ymax - 50)
        if len(pts) < 5: continue
        if pts[0][1] > pts[-1][1]: pts = pts[::-1]          # de sur a norte (lado de Madrid primero)
        r = R.procesar(pts, sel, mdt)
        if r["s"][-1] < 2000 and len(refs) == 1 and nombre == refs[0]:
            continue
        ids = np.array([sel[w]["id"] if w >= 0 else -1 for w in r["way"]])
        dib = np.array([i not in ways_dibujadas for i in ids])
        ways_dibujadas |= set(ids.tolist())
        st = R.estadisticas(r); stats[nombre] = st
        X, Z = a_godot(r, E0, N0)
        nom = [x for x in r["nombre"] if x]
        # rótulo por muestra ("CL-601 · Carretera de …"), arrastrando el último conocido en rotondas sin ref
        rot, ult = [], ""
        for rf, nm in zip(r["ref"], r["nombre"]):
            if rf or nm: ult = " · ".join(x for x in (rf, nm) if x)
            rot.append(ult)
        etiquetas = sorted(set(rot)); pos_et = {e: k for k, e in enumerate(etiquetas)}
        rutas_out.append({"nombre": nombre, "refs": refs, "calle": max(set(nom), key=nom.count) if nom else "",
                          "estadisticas": st, "paso": R.PASO,
                          "x": np.round(X, 2).tolist(), "y": np.round(r["z"], 2).tolist(), "z": np.round(Z, 2).tolist(),
                          "pendiente": np.round(r["pendiente"], 2).tolist(),
                          "curvatura": np.round(r["curvatura"], 5).tolist(),
                          "ancho": np.round(r["ancho"], 2).tolist(), "vmax": r["vmax"].tolist(),
                          "puente": r["puente"].astype(int).tolist(), "tunel": r["tunel"].astype(int).tolist(),
                          "dibujar": dib.astype(int).tolist(),
                          "etiquetas": etiquetas, "etiqueta": [pos_et[e] for e in rot]})
        procesadas.append(r)
        print(f"      {nombre}: {st['longitud_km']} km, {st['alt_min']}–{st['alt_max']} m, "
              f"pendiente máx 100 m {st['pendiente_max_100m']} %, radio mín {st['radio_min_m']} m")

    # resto de vías (sin ruta): solo para ver y circular por ellas
    vias_out = []
    for w in ways:
        if w["id"] in ways_dibujadas: continue
        if "_link" in w["tags"].get("highway", "") and len(w["geom"]) < 3: pass
        xs_, ys_ = utm.transform([p[1] for p in w["geom"]], [p[0] for p in w["geom"]])
        pts = recortar_a_rect([(x, y, 0) for x, y in zip(xs_, ys_)], xmin + 50, ymin + 50, xmax - 50, ymax - 50)
        if len(pts) < 2: continue
        L = sum(np.hypot(pts[k + 1][0] - pts[k][0], pts[k + 1][1] - pts[k][1]) for k in range(len(pts) - 1))
        if L < 20: continue
        r = R.procesar(pts, [w], mdt, suavizado_xy=2.0)
        X, Z = a_godot(r, E0, N0)
        vias_out.append({"x": np.round(X, 2).tolist(), "y": np.round(r["z"], 2).tolist(), "z": np.round(Z, 2).tolist(),
                         "ancho": round(float(np.mean(r["ancho"])), 2), "ref": w["tags"].get("ref", ""),
                         "nombre": w["tags"].get("name", ""), "tipo": R.tipo_base(w["tags"]),
                         "puente": int(r["puente"].any()), "tunel": int(r["tunel"].any())})
        procesadas.append(r)
    print(f"      {len(vias_out)} vías secundarias")

    print("[5/6] Terreno 1:1 (malla de 20 m, con la explanación de la carretera) …", flush=True)
    nxv = int((gx1 - gx0) / PASO_TERRENO) + 1; nyv = int((gy1 - gy0) / PASO_TERRENO) + 1
    gxs = gx0 + np.arange(nxv) * PASO_TERRENO; gys = gy1 - np.arange(nyv) * PASO_TERRENO  # filas de norte a sur
    GX, GY = np.meshgrid(gxs, gys)
    # media de 5 m -> 20 m (evita aliasing) y muestreo
    from scipy.ndimage import uniform_filter
    mdt20 = dem.Mdt(uniform_filter(mdt.a, size=max(1, int(PASO_TERRENO / tr.a))), tr)
    H = mdt20.muestrear(GX, GY).astype(np.float32)
    # explanación: el terreno baja/sube a la rasante junto a la carretera (desmonte/terraplén)
    pr, pz, phw = [], [], []
    for r in procesadas:
        m = ~(r["puente"] | r["tunel"])
        pr.append(np.column_stack([r["x"][m], r["y"][m]])); pz.append(r["z"][m]); phw.append(r["ancho"][m] / 2)
    pr = np.vstack(pr); pz = np.concatenate(pz); phw = np.concatenate(phw)
    arbol = cKDTree(pr)
    d, idx = arbol.query(np.column_stack([GX.ravel(), GY.ravel()]), distance_upper_bound=80)
    ok = np.isfinite(d)
    wgt = np.zeros_like(d)
    wgt[ok] = np.clip((phw[idx[ok]] + 45 - d[ok]) / 30, 0, 1)
    Hf = H.ravel()
    Hf[ok] = Hf[ok] * (1 - wgt[ok]) + (pz[idx[ok]] - 0.4) * wgt[ok]
    H = Hf.reshape(H.shape)
    teselas = []
    nt = int(TESELA / PASO_TERRENO)
    rng = np.random.default_rng(7)
    total_arboles = 0
    for tj in range(0, nyv - 1, nt):
        for ti in range(0, nxv - 1, nt):
            bloque = H[tj:tj + nt + 1, ti:ti + nt + 1]
            nombre = f"t_{ti // nt}_{tj // nt}"
            bloque.astype("<f4").tofile(os.path.join(salida, "terreno", nombre + ".bin"))
            X0 = float(gxs[ti] - E0); Z0 = float(N0 - gys[tj])
            # árboles (pinar): entre 1000 y 2050 m, fuera de la carretera y de pendientes muy fuertes
            gyy, gxx = np.gradient(bloque, PASO_TERRENO)
            cand = rng.random(bloque.shape) < 0.32
            cand &= (bloque > 1000) & (bloque < 2050 + rng.normal(0, 40, bloque.shape))
            cand &= np.hypot(gxx, gyy) < 0.9
            jj, ii = np.nonzero(cand)
            px = gxs[ti] + ii * PASO_TERRENO + rng.uniform(-9, 9, len(ii))
            py = gys[tj] - jj * PASO_TERRENO + rng.uniform(-9, 9, len(ii))
            dd, k = arbol.query(np.column_stack([px, py]), distance_upper_bound=60)
            lejos = ~np.isfinite(dd) | (dd > np.where(np.isfinite(dd), phw[np.minimum(k, len(phw) - 1)], 0) + 9)
            px, py = px[lejos], py[lejos]
            pzs = mdt20.muestrear(px, py)
            esc = rng.uniform(0.7, 1.35, len(px))
            arr_t = np.column_stack([px - E0, pzs, N0 - py, esc]).astype("<f4")
            arr_t.tofile(os.path.join(salida, "arboles", nombre + ".bin"))
            total_arboles += len(arr_t)
            teselas.append({"nombre": nombre, "x0": X0, "z0": Z0, "n": int(bloque.shape[1]), "m": int(bloque.shape[0]),
                            "arboles": int(len(arr_t))})
    print(f"      {len(teselas)} teselas de {TESELA/1000:.0f} km, {total_arboles} árboles")

    print("[6/6] Escribiendo …", flush=True)
    json.dump({"rutas": rutas_out, "vias": vias_out}, open(os.path.join(salida, "carreteras.json"), "w"),
              ensure_ascii=False, separators=(",", ":"))
    zona = {"zona": a.zona, "bbox_wgs84": bbox, "crs": "EPSG:25830 (ETRS89 / UTM 30N)", "origen_utm": [E0, N0],
            "convenio": "X=E-E0, Z=N0-N, Y=altitud (m). Escala 1:1.",
            "mdt": fuente_mdt, "osm": "© colaboradores de OpenStreetMap (ODbL), vía Overpass API",
            "terreno": {"paso": PASO_TERRENO, "tesela": TESELA, "teselas": teselas,
                        "alt_min": float(H.min()), "alt_max": float(H.max())},
            "generado": time.strftime("%Y-%m-%d %H:%M")}
    json.dump(zona, open(os.path.join(salida, "zona.json"), "w"), ensure_ascii=False, indent=1)
    json.dump(stats, open(os.path.join(salida, "estadisticas.json"), "w"), ensure_ascii=False, indent=1)
    np.save(os.path.join(a.cache, f"{a.zona}_terreno.npy"), H)
    print(f"Hecho en {time.time()-t0:.0f} s → {salida}")


if __name__ == "__main__":
    main()
