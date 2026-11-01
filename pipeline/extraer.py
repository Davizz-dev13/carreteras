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
import dirigido as D

PRESETS = {
    "navacerrada": {
        "bbox": (40.715, -4.08, 40.88, -3.96),
        "rutas": [("Puerto de Navacerrada (M-601 → CL-601)", ["M-601", "CL-601"]),
                  ("M-601 Navacerrada → Puerto", ["M-601"]),
                  ("CL-601 Puerto → Valsaín", ["CL-601"])],
        # revisión 01-11-2026: solo carreteras reales asfaltadas (fuera pistas y caminos sin asfaltar o cerrados) y
        # los trozos cortos (< 20 m) que unen dos vías dibujadas o forman parte de una glorieta (antes faltaban
        # glorietas enteras de los pueblos y los ramales cortos de los cruces)
        "tipos": osm.TIPOS,
        "vias_cortas_conectadas": True,
    },
    # A-308 Iznalloz – Darro (Granada). Solo la A-308 como ruta (las demás vías se dibujan pero no son rutas);
    # de oeste (Iznalloz) a este (Darro); vías OSM filtradas a carreteras reales asfaltadas (sin caminos/sendas);
    # árboles solo dentro de los bosques de OSM (landuse=forest / natural=wood), no por franja de altitud.
    "a308": {
        "bbox": (37.30, -3.58, 37.43, -3.24),
        "rutas": [("A-308 Iznalloz → Darro", ["A-308"])],
        "solo_rutas": True,
        "orden": "oeste_este",
        "tipos": osm.TIPOS + "|residential",
        "arboles_osm": True,
        "max_mb_archivo": 3.0,
    },
    # GR-8101 Caniles – límite de provincia de Almería (Sierra de Baza, Granada). Carretera de la Diputación de
    # Granada; en Almería sigue como AL-5405 hacia Escúllar (no incluida). Misma receta que a308. Sentido del PK
    # oficial (catálogo Junta de Andalucía: "De Límite de Provincia de Almería a A-334 (Caniles)", 28,90 km): de sur a norte.
    "gr8101": {
        "bbox": (37.25, -2.81, 37.455, -2.69),
        "rutas": [("GR-8101 límite de Almería → Caniles", ["GR-8101"])],
        "solo_rutas": True,
        "orden": "sur_norte",
        "tipos": osm.TIPOS + "|residential",
        "arboles_osm": True,
        "max_mb_archivo": 3.0,
    },
    # M-406 (Comunidad de Madrid), de Alcorcón (enlace con la A-5) a la A-4. Autovía urbana de calzadas
    # separadas (oneway=yes) con rotondas: la ruta sigue UNA calzada en su sentido legal (pipeline/dirigido.py, Dijkstra
    # respetando oneway y el giro de las rotondas). OSM no tiene ref=M-406 en ~1,7 km del casco de Leganés: la ruta
    # se parte ahí en dos rutas del juego (no se inventa la unión). Por la ruta circulan los dos sentidos (extras_zona.py ensancha a los carriles de las dos calzadas).
    # Vías secundarias: sin las residential (zona urbana densa: miles de calles), solo a ≤ 2 km de la ruta y sin nombre.
    "m406": {
        "bbox": (40.28, -3.84, 40.38, -3.66),
        "rutas": [("M-406", ["M-406"])],
        "nombres_trozos": ["M-406 Alcorcón (A-5) → Leganés", "M-406 Leganés → A-4"],
        "hueco_max_m": 300,
        "solo_rutas": True,
        "orden": "oeste_este",
        "tipos": osm.TIPOS + "|residential",
        "arboles_osm": True,
        "parques": True,
        "max_mb_archivo": 3.0,
        "dirigido": True,
        "vias_excluir": ["residential"],
        "vias_sin_nombre": True,
        "vias_radio_m": 2000,
        # OSM leído de un extracto Geofabrik recortado al bbox (pipeline/osm_pbf.py escribe la caché con el formato de Overpass)
        "fuente_osm": "© colaboradores de OpenStreetMap (ODbL), extracto Geofabrik europe/spain/madrid (2026-10-30T21:24:51Z) vía pipeline/osm_pbf.py",
    },
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
    ways = osm.descargar_ways(bbox, os.path.join(a.cache, "osm"), tipos=preset.get("tipos", osm.TIPOS))
    if preset.get("tipos"):   # filtro explícito: solo carreteras reales asfaltadas (nunca path/track/footway, p. ej. sendas GR)
        n0 = len(ways); ways = [w for w in ways if osm.es_carretera(w["tags"])]
        print(f"      filtro carreteras: {n0} → {len(ways)}")
    print(f"      {len(ways)} vías")
    # rutas automáticas: cada ref de carretera (M-601, CL-601, N-VI …) con > 2 km en la zona
    por_ref = defaultdict(list)
    for w in ways:
        for r in R.refs_de(w["tags"]):
            if re.match(r"^[A-Z]{1,3}-\d", r) and not r.startswith("GR"): por_ref[r].append(w)
    usados = {tuple(sorted(d[1])) for d in defs}
    if not a.rutas and not preset.get("solo_rutas"):
        for ref in sorted(por_ref):
            if (ref,) not in usados: defs.append((ref, [ref]))

    print("[4/6] Rutas …", flush=True)
    salida = os.path.join(a.salida, a.zona); os.makedirs(os.path.join(salida, "terreno"), exist_ok=True)
    os.makedirs(os.path.join(salida, "arboles"), exist_ok=True)
    rutas_out, stats, ways_dibujadas, procesadas = [], {}, set(), []
    items = []
    for nombre, refs in defs:
        if not preset.get("dirigido"):
            items.append((nombre, refs, None, None)); continue
        # una calzada en su sentido legal (dirigido.py); las vías sin la ref solo cubren huecos de OSM (coste ×4).
        # Un hueco de la ref de más de "hueco_max_m" parte la ruta en trozos (cada uno es una ruta del juego).
        pa = D.encadenar_dirigido(ways, utm, preset.get("orden", "oeste_este"), refs=refs, penal=4.0)
        con_ref = [bool(set(R.refs_de(ways[pa[k][2]]["tags"])) & set(refs)) for k in range(len(pa) - 1)]
        trozos, k = [], 0
        while k < len(con_ref):
            if not con_ref[k]:
                j = k
                while j < len(con_ref) and not con_ref[j]: j += 1
                lh = sum(np.hypot(pa[q + 1][0] - pa[q][0], pa[q + 1][1] - pa[q][1]) for q in range(k, j))
                if lh > preset.get("hueco_max_m", 1e9) or k == 0 or j == len(con_ref):
                    print(f"      {nombre}: hueco de la ref en OSM de {lh:.0f} m (puntos {k}–{j})" + (" → se parte la ruta" if 0 < k and j < len(con_ref) else " (extremo, se quita)"))
                    trozos.append((k, j))
                k = j
            else: k += 1
        cortes = [0] + [x for t in trozos for x in t] + [len(pa) - 1]
        piezas = [(cortes[q], cortes[q + 1]) for q in range(0, len(cortes) - 1, 2) if cortes[q + 1] > cortes[q] + 1]
        nombres = preset.get("nombres_trozos") or [nombre]
        for q, (a0, a1) in enumerate(piezas):
            sub = pa[a0:a1 + 1]
            usadas = sorted(set(p_[2] for p_ in sub)); m_ = {w: kk for kk, w in enumerate(usadas)}
            sel_ = [ways[w] for w in usadas]; pts_ = [(x, y, m_[w]) for x, y, w in sub]
            rot, ant = 0, False
            for kk in range(len(pts_) - 1):
                es = sel_[pts_[kk][2]]["tags"].get("junction") in ("roundabout", "circular")
                rot += es and not ant; ant = es
            nm = nombres[q] if q < len(nombres) else f"{nombre} ({q + 1})"
            print(f"      {nm}: calzada dirigida, {rot} rotondas atravesadas")
            items.append((nm, refs, sel_, pts_))
    for nombre, refs, sel0, pts0 in items:
        if sel0 is not None:
            sel, pts = sel0, pts0
        else:
            sel = [w for w in ways if set(R.refs_de(w["tags"])) & set(refs)]
            if not sel: print(f"      {nombre}: sin vías"); continue
            pts = R.encadenar(sel, utm)
        pts = recortar_a_rect(pts, xmin + 50, ymin + 50, xmax - 50, ymax - 50)
        if len(pts) < 5: continue
        orden = preset.get("orden")
        if orden == "oeste_este": invertir = pts[0][0] > pts[-1][0]
        elif orden == "norte_sur": invertir = pts[0][1] < pts[-1][1]
        else: invertir = pts[0][1] > pts[-1][1]      # "sur_norte" o sin orden (Navacerrada)
        if invertir:   # de sur a norte (lado de Madrid primero) o de oeste a este según el preset
            pts = pts[::-1]
        elif preset.get("orden"):
            # encadenar() deja en cada punto la vía del tramo que SALE de él; R.procesar() espera la del tramo que
            # LLEGA (lo que ocurre tras invertir). Sin invertir hay que correrla un tramo o un puente de un solo
            # segmento (p. ej. el de la A-308 en Iznalloz, 292 m) se marca en el segmento siguiente.
            # Solo en zonas nuevas con "orden": Navacerrada no se ha regenerado con esta corrección.
            pts = [(pts[k][0], pts[k][1], pts[max(k - 1, 0)][2]) for k in range(len(pts))]
        huecos = [k for k in range(len(pts) - 1) if pts[k + 1][2] < 0]
        if huecos: print(f"      {nombre}: {len(huecos)} uniones fuera de OSM (huecos/rotondas sin ref)")
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
    grado_nodo = defaultdict(int)   # nº de vías de OSM que pasan por cada nodo (para los trozos cortos que unen dos vías)
    if preset.get("vias_cortas_conectadas"):
        for w in ways:
            for nd in set(w["nodes"]):
                grado_nodo[nd] += 1

    def corta_util(w):
        """Trozo corto que no sobra: parte de una glorieta, o une otras vías por sus dos extremos."""
        if w["tags"].get("junction") in ("roundabout", "circular"):
            return True
        return grado_nodo[w["nodes"][0]] >= 2 and grado_nodo[w["nodes"][-1]] >= 2

    arbol_rutas = cKDTree(np.vstack([np.column_stack([r["x"], r["y"]]) for r in procesadas])) if procesadas else None
    for w in ways:
        if w["id"] in ways_dibujadas: continue
        if w["tags"].get("highway") in preset.get("vias_excluir", ()): continue
        if "_link" in w["tags"].get("highway", "") and len(w["geom"]) < 3: pass
        xs_, ys_ = utm.transform([p[1] for p in w["geom"]], [p[0] for p in w["geom"]])
        if preset.get("vias_radio_m") and arbol_rutas is not None and \
                arbol_rutas.query(np.column_stack([xs_, ys_]))[0].min() > preset["vias_radio_m"]:
            continue   # vía lejos de la ruta (zona urbana densa: solo las vías a ≤ vias_radio_m de la ruta)
        pts = recortar_a_rect([(x, y, 0) for x, y in zip(xs_, ys_)], xmin + 50, ymin + 50, xmax - 50, ymax - 50)
        if len(pts) < 2: continue
        L = sum(np.hypot(pts[k + 1][0] - pts[k][0], pts[k + 1][1] - pts[k][1]) for k in range(len(pts) - 1))
        if L < 20 and not (preset.get("vias_cortas_conectadas") and L >= 2 and corta_util(w)): continue
        r = R.procesar(pts, [w], mdt, suavizado_xy=2.0)
        X, Z = a_godot(r, E0, N0)
        vias_out.append({"x": np.round(X, 2).tolist(), "y": np.round(r["z"], 2).tolist(), "z": np.round(Z, 2).tolist(),
                         "ancho": round(float(np.mean(r["ancho"])), 2), "ref": w["tags"].get("ref", ""),
                         "nombre": "" if preset.get("vias_sin_nombre") else w["tags"].get("name", ""), "tipo": R.tipo_base(w["tags"]),
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
    bosque = None
    if preset.get("arboles_osm"):
        bosque = osm.mascara_bosque(bbox, os.path.join(a.cache, "osm"), utm, gxs, gys, parques=preset.get("parques", False))
        print(f"      bosque OSM: {100 * bosque.mean():.1f} % de la zona")
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
            if bosque is not None:   # bosques reales de OSM
                cand &= bosque[tj:tj + nt + 1, ti:ti + nt + 1]
            else:
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
    max_mb = preset.get("max_mb_archivo")
    if max_mb:
        # archivos ≤ max_mb (límite de subida a GitHub): las vías secundarias van en vias_1.json, vias_2.json…
        partes, actual, tam = [], [], 0
        for v in vias_out:
            actual.append(v); tam += len(json.dumps(v, ensure_ascii=False, separators=(",", ":"))) + 1
            if tam > max_mb * 0.9e6:
                partes.append(actual); actual, tam = [], 0
        if actual: partes.append(actual)
        nombres = []
        for k, parte in enumerate(partes):
            nombres.append(f"vias_{k + 1}.json")
            json.dump({"vias": parte}, open(os.path.join(salida, nombres[-1]), "w"), ensure_ascii=False, separators=(",", ":"))
        json.dump({"rutas": rutas_out, "vias": [], "vias_archivos": nombres}, open(os.path.join(salida, "carreteras.json"), "w"),
                  ensure_ascii=False, separators=(",", ":"))
    else:
        json.dump({"rutas": rutas_out, "vias": vias_out}, open(os.path.join(salida, "carreteras.json"), "w"),
                  ensure_ascii=False, separators=(",", ":"))
    zona = {"zona": a.zona, "bbox_wgs84": bbox, "crs": "EPSG:25830 (ETRS89 / UTM 30N)", "origen_utm": [E0, N0],
            "convenio": "X=E-E0, Z=N0-N, Y=altitud (m). Escala 1:1.",
            "mdt": fuente_mdt, "osm": preset.get("fuente_osm", "© colaboradores de OpenStreetMap (ODbL), vía Overpass API"),
            "terreno": {"paso": PASO_TERRENO, "tesela": TESELA, "teselas": teselas,
                        "alt_min": float(H.min()), "alt_max": float(H.max())},
            "generado": time.strftime("%Y-%m-%d %H:%M")}
    json.dump(zona, open(os.path.join(salida, "zona.json"), "w"), ensure_ascii=False, indent=1)
    json.dump(stats, open(os.path.join(salida, "estadisticas.json"), "w"), ensure_ascii=False, indent=1)
    np.save(os.path.join(a.cache, f"{a.zona}_terreno.npy"), H)
    print(f"Hecho en {time.time()-t0:.0f} s → {salida}")


if __name__ == "__main__":
    main()
