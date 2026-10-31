#!/usr/bin/env python3
"""Datos extra de una zona a partir de OSM, emparejados con las rutas ya generadas por extraer.py:
  limites_velocidad.json  (maxspeed por sentido; genérico legal marcado fuente='por_defecto_legal' → '*' en el juego)
  adelantar.json          (prohibido adelantar por sentido + carriles reales por sentido: carriles adicionales 2+1)
Mismo formato que juego/datos/navacerrada/. Uso:
  python pipeline/extras_zona.py --zona a308 --ref A-308 --osm cache/osm/a308_todas_highway.json \
         --residencial cache/osm/a308_residencial_senales.json
"""
import argparse, json, os, re, sys
import numpy as np
from pyproj import Transformer
from scipy.spatial import cKDTree
from matplotlib.path import Path

sys.path.insert(0, os.path.dirname(__file__))
import osm as O

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASO = 2.0


def num(v):
    m = re.match(r"\s*(\d+)", v or "")
    return int(m.group(1)) if m else None


def carriles_way(t):
    """(carriles en el sentido de la vía, carriles en sentido contrario) según lanes / lanes:forward / lanes:backward."""
    if t.get("oneway") in ("yes", "1", "true"):
        return (num(t.get("lanes")) or 1, 0)
    f, b = num(t.get("lanes:forward")), num(t.get("lanes:backward"))
    if f and b: return (f, b)
    L = num(t.get("lanes"))
    if L == 2 or L is None or L == 1: return (1, 1)
    if f: return (f, max(L - f, 1))
    if b: return (max(L - b, 1), b)
    return (L // 2, L - L // 2)


def vel_way(t, adelante):
    k = "maxspeed:forward" if adelante else "maxspeed:backward"
    return num(t.get(k)) or num(t.get("maxspeed"))


def tramos_de(valores, s, minimo=0.0):
    """Agrupa una lista por muestra en tramos [(i0, i1, valor)] (i1 exclusivo)."""
    out, i0 = [], 0
    for i in range(1, len(valores) + 1):
        if i == len(valores) or valores[i] != valores[i0]:
            out.append([i0, i, valores[i0]]); i0 = i
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zona", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--osm", required=True, help="descarga way[highway] del bbox (json de Overpass con fecha/url)")
    ap.add_argument("--residencial", required=True, help="landuse=residential del bbox (para el genérico urbano)")
    ap.add_argument("--sentido", default="Iznalloz → Darro", help="texto del sentido 'ida' (km creciente) para las notas")
    ap.add_argument("--ancho_min", type=float, default=0.0,
                    help="m: anchura mínima de la ruta fuera de calzadas separadas (0 = no se toca). En m406: 7 m donde la "
                         "ruta sigue una calle de sentido único (hueco de la ref en OSM) por la que el juego hace circular los dos sentidos")
    ap.add_argument("--lineas", help="json de --captura=lineas_adelantar ({ruta: [[km_ini, km_fin], …]}): se guarda como "
                                     "linea_discontinua quitando los tramos de calzadas separadas (ahí la línea central es la mediana)")
    ap.add_argument("--absorber", type=float, default=60.0, help="m: tramos de límite más cortos se absorben")
    a = ap.parse_args()
    D = os.path.join(RAIZ, "juego", "datos", a.zona)
    zona = json.load(open(os.path.join(D, "zona.json")))
    car = json.load(open(os.path.join(D, "carreteras.json")))
    E0, N0 = zona["origen_utm"]
    utm = Transformer.from_crs(4326, 25830, always_xy=True)
    bruto = json.load(open(a.osm)); el = bruto["datos"]["elements"]
    todas = [w for w in el if w.get("type") == "way" and "geometry" in w]
    con_overtaking = [w for w in todas if any(k.startswith("overtaking") for k in w["tags"])]
    carreteras = [w for w in todas if O.es_carretera(w["tags"])]
    # puntos densos (cada 2 m) de las vías: misma ref y cualquier carretera (para rotondas sin ref)
    def densos(ws):
        P, I, T = [], [], []
        for k, w in enumerate(ws):
            xs, ys = utm.transform([p["lon"] for p in w["geometry"]], [p["lat"] for p in w["geometry"]])
            for j in range(len(xs) - 1):
                d = np.hypot(xs[j + 1] - xs[j], ys[j + 1] - ys[j])
                if d < 0.01: continue
                n = max(1, int(d / 2.0))
                u = (np.arange(n) + 0.5) / n
                P.append(np.column_stack([xs[j] + u * (xs[j + 1] - xs[j]), ys[j] + u * (ys[j + 1] - ys[j])]))
                I.append(np.full(n, k)); T.append(np.tile([(xs[j + 1] - xs[j]) / d, (ys[j + 1] - ys[j]) / d], (n, 1)))
        return np.vstack(P), np.concatenate(I), np.vstack(T)
    con_ref = [w for w in carreteras if a.ref in O_refs(w["tags"])]
    Pr, Ir, Tr = densos(con_ref); arb_r = cKDTree(Pr)
    Pa, Ia, Ta = densos(carreteras); arb_a = cKDTree(Pa)
    # polígonos residenciales (genérico urbano)
    res = json.load(open(a.residencial))["datos"]["elements"]
    polis = []
    for e in res:
        if e.get("type") == "way" and e["tags"].get("landuse") == "residential" and "geometry" in e:
            xs, ys = utm.transform([p["lon"] for p in e["geometry"]], [p["lat"] for p in e["geometry"]])
            polis.append(Path(np.column_stack([xs, ys])))
    sal_lim, sal_adel = [], []
    resumen = {}
    for ri, r in enumerate(car["rutas"]):
        X = np.array(r["x"]); Z = np.array(r["z"]); n = len(X); s = np.arange(n) * PASO
        Eu = X + E0; Nu = N0 - Z
        tg = np.column_stack([np.gradient(Eu), np.gradient(Nu)]); tg /= np.maximum(np.linalg.norm(tg, axis=1)[:, None], 1e-9)
        P = np.column_stack([Eu, Nu])
        urbano = np.zeros(n, bool)
        for pa in polis: urbano |= pa.contains_points(P)
        ida_c = np.ones(n, int); vue_c = np.ones(n, int)
        lim_i = [None] * n; lim_v = [None] * n; way_i = [None] * n; way_v = [None] * n
        sep = np.zeros(n, bool); dist = np.full(n, np.nan)
        for i in range(n):
            cand = arb_r.query_ball_point(P[i], 15.0)
            mejor = None
            for c in cand:
                cs = float(np.dot(Tr[c], tg[i]))
                if abs(cs) < 0.8: continue
                d = float(np.hypot(*(Pr[c] - P[i])))
                if mejor is None or d < mejor[0]: mejor = (d, c, cs)
            if mejor is None:
                # rotonda / enlace sin ref: cualquier carretera cercana
                cand = arb_a.query_ball_point(P[i], 12.0)
                for c in cand:
                    cs = float(np.dot(Ta[c], tg[i]))
                    d = float(np.hypot(*(Pa[c] - P[i])))
                    if mejor is None or d < mejor[0]: mejor = (d, -1 - c, cs)
                if mejor is None: continue
                d, c, cs = mejor; w = carreteras[Ia[-1 - c]]; t = w["tags"]
                dist[i] = d
                lim_i[i] = vel_way(t, cs > 0); lim_v[i] = vel_way(t, cs < 0) if t.get("oneway") != "yes" else lim_i[i]
                way_i[i] = way_v[i] = w["id"]
                continue
            d, c, cs = mejor; w = con_ref[Ir[c]]; t = w["tags"]; dist[i] = d
            if t.get("oneway") in ("yes", "1", "true"):
                # calzadas separadas: la otra calzada (misma ref, sentido opuesto respecto a la ruta) a ≤ 45 m
                sep[i] = True
                otra = None
                for c2 in arb_r.query_ball_point(P[i], 45.0):
                    w2 = con_ref[Ir[c2]]
                    if w2["tags"].get("oneway") not in ("yes", "1", "true"): continue
                    cs2 = float(np.dot(Tr[c2], tg[i]))
                    if cs2 * cs > -0.64: continue
                    d2 = float(np.hypot(*(Pr[c2] - P[i])))
                    if otra is None or d2 < otra[0]: otra = (d2, w2)
                pro, contra = (w, otra[1] if otra else None) if cs > 0 else (otra[1] if otra else None, w)
                ida_c[i] = num(pro["tags"].get("lanes")) or 1 if pro else 1
                vue_c[i] = num(contra["tags"].get("lanes")) or 1 if contra else 1
                lim_i[i] = vel_way(pro["tags"], True) if pro else None
                lim_v[i] = vel_way(contra["tags"], True) if contra else None
                way_i[i] = pro["id"] if pro else None; way_v[i] = contra["id"] if contra else None
            else:
                f, b = carriles_way(t)
                ida_c[i], vue_c[i] = (f, b) if cs > 0 else (b, f)
                lim_i[i] = vel_way(t, cs > 0); lim_v[i] = vel_way(t, cs < 0)
                way_i[i] = way_v[i] = w["id"]
        # ---------- límites ----------
        def con_fuente(lims, ways):
            out = []
            for i in range(n):
                if lims[i]: out.append((int(lims[i]), "osm", ways[i]))
                else: out.append((50 if urbano[i] else 90, "por_defecto_legal", None))
            return out
        Li, Lv = con_fuente(lim_i, way_i), con_fuente(lim_v, way_v)
        cobertura = {"ida": round(100 * np.mean([x[1] == "osm" for x in Li]), 1),
                     "vuelta": round(100 * np.mean([x[1] == "osm" for x in Lv]), 1)}
        def agrupar(L):
            tr = tramos_de([(x[0], x[1]) for x in L], s)
            absorbidos = []
            cambiado = True
            while cambiado and len(tr) > 1:
                cambiado = False
                for k, (i0, i1, v) in enumerate(tr):
                    if (i1 - i0) * PASO < a.absorber:
                        vec = tr[k - 1] if k > 0 else tr[k + 1]
                        absorbidos.append({"km_ini": round(i0 * PASO / 1000, 3), "km_fin": round(i1 * PASO / 1000, 3), "limite": v[0], "fuente": v[1]})
                        if k > 0: tr[k - 1][1] = i1
                        else: tr[k + 1][0] = i0
                        tr.pop(k); cambiado = True; break
                # unir vecinos iguales
                k = 1
                while k < len(tr):
                    if tr[k][2] == tr[k - 1][2]: tr[k - 1][1] = tr[k][1]; tr.pop(k)
                    else: k += 1
            return tr, absorbidos
        ti, abs_i = agrupar(Li); tv, abs_v = agrupar(Lv)
        def way_mayor(L, i0, i1):
            ws = [L[i][2] for i in range(i0, i1) if L[i][2]]
            return max(set(ws), key=ws.count) if ws else None
        tramos = []
        # tramos comunes "ambos" donde coinciden, si no ida/vuelta
        cortes = sorted({0, n} | {x[0] for x in ti} | {x[1] for x in ti} | {x[0] for x in tv} | {x[1] for x in tv})
        def val(trs, i):
            for i0, i1, v in trs:
                if i0 <= i < i1: return v
        for i0, i1 in zip(cortes[:-1], cortes[1:]):
            vi, vv = val(ti, i0), val(tv, i0)
            base = {"km_ini": round(i0 * PASO / 1000, 3), "km_fin": round(min(i1, n - 1) * PASO / 1000, 3)}
            if vi == vv:
                t = dict(base, limite=vi[0], sentido="ambos", fuente=vi[1])
                if vi[1] == "osm": t["osm_way"] = way_mayor(Li, i0, i1)
                tramos.append(t)
            else:
                for sen, v, L in (("ida", vi, Li), ("vuelta", vv, Lv)):
                    t = dict(base, limite=v[0], sentido=sen, fuente=v[1])
                    if v[1] == "osm": t["osm_way"] = way_mayor(L, i0, i1)
                    tramos.append(t)
        # unir tramos contiguos idénticos
        fus = []
        for t in tramos:
            u = next((f for f in reversed(fus) if f["sentido"] == t["sentido"]), None)
            if u and u["km_fin"] == t["km_ini"] and u["limite"] == t["limite"] and u["fuente"] == t["fuente"]:
                u["km_fin"] = t["km_fin"]
            else: fus.append(dict(t))
        fus.sort(key=lambda t: (t["km_ini"], t["sentido"]))
        sal_lim.append({"id": ri, "nombre": r["nombre"], "longitud_km": round(s[-1] / 1000, 3), "tramos": fus,
                        "cobertura_osm_pct": cobertura, "tramos_pequenos_absorbidos": abs_i + [dict(x, sentido="vuelta") for x in abs_v]})
        # ---------- carriles y adelantamiento ----------
        conf = [(int(ida_c[i]), int(vue_c[i]), bool(sep[i])) for i in range(n)]
        trc = tramos_de(conf, s)
        # absorber cambios de < 20 m (cruces) en el vecino
        k = 0
        while k < len(trc):
            i0, i1, v = trc[k]
            if (i1 - i0) * PASO < 20 and len(trc) > 1:
                if k > 0: trc[k - 1][1] = i1
                else: trc[k + 1][0] = i0
                trc.pop(k); k = max(k - 1, 0)
                j = 1
                while j < len(trc):
                    if trc[j][2] == trc[j - 1][2]: trc[j - 1][1] = trc[j][1]; trc.pop(j)
                    else: j += 1
                continue
            k += 1
        carriles, extra, prohibido = [], [], []
        for i0, i1, (ci, cv, sp) in trc:
            km0, km1 = round(i0 * PASO / 1000, 3), round(min(i1, n - 1) * PASO / 1000, 3)
            ws_i = sorted({way_i[i] for i in range(i0, i1) if way_i[i]}); ws_v = sorted({way_v[i] for i in range(i0, i1) if way_v[i]})
            carriles.append({"km_ini": km0, "km_fin": km1, "ida": ci, "vuelta": cv, "calzadas_separadas": sp})
            for sen, c_prop, c_otro, ws in (("ida", ci, cv, ws_i), ("vuelta", cv, ci, ws_v)):
                if c_prop >= 2 and (i1 - i0) * PASO >= 150:
                    extra.append({"km_ini": km0, "km_fin": km1, "sentido": sen, "carriles": c_prop,
                                  "longitud_m": round((i1 - i0) * PASO), "fuente": "osm", "osm_ways": ws[:12]})
                if sp:
                    prohibido.append({"km_ini": km0, "km_fin": km1, "sentido": sen, "fuente": "osm_calzadas_separadas",
                                      "motivo": "calzadas separadas en OSM: no hay carril contrario que invadir"})
                elif c_prop == 1 and c_otro >= 2:
                    prohibido.append({"km_ini": km0, "km_fin": km1, "sentido": sen, "fuente": "supuesto_2+1",
                                      "motivo": "el sentido contrario tiene 2 carriles (OSM); se supone línea continua en este lado, como es habitual en los 2+1 (OSM no tiene la marca vial)"})
        # unir prohibidos contiguos del mismo sentido
        prohibido.sort(key=lambda t: (t["sentido"], t["km_ini"]))
        pf = []
        for t in prohibido:
            if pf and pf[-1]["sentido"] == t["sentido"] and abs(pf[-1]["km_fin"] - t["km_ini"]) < 0.025 and pf[-1]["fuente"] == t["fuente"]:
                pf[-1]["km_fin"] = t["km_fin"]
            else: pf.append(dict(t))
        # calzadas separadas: la ruta sigue una sola calzada (vía OSM de sentido único, 4,5 m) pero en el juego por ella
        # circulan los dos sentidos → se ensancha a los carriles de las dos calzadas (3,5 m cada uno + 1 m), con transición
        from scipy.ndimage import gaussian_filter1d
        an = np.array(r["ancho"], float)
        objetivo = np.where(sep, (ida_c + vue_c) * 3.5 + 1.0, 0.0)
        objetivo = np.maximum(objetivo, gaussian_filter1d(objetivo, 10))
        nuevo = np.maximum(an, objetivo)
        if a.ancho_min > 0:
            minimo = np.where(sep, 0.0, a.ancho_min)
            minimo = np.maximum(minimo, gaussian_filter1d(minimo, 10))
            n_min = int(((nuevo < a.ancho_min - 0.01) & ~sep).sum())
            nuevo = np.maximum(nuevo, minimo)
        r["ancho"] = np.round(nuevo, 2).tolist()
        r["ancho_ajustado"] = ("en calzadas separadas (%.0f m de ruta) la anchura es la suma de los carriles de las dos calzadas "
                               "(OSM lanes) × 3,5 m + 1 m, porque el juego hace circular los dos sentidos por la calzada que sigue la ruta" % (sep.sum() * PASO))
        if a.ancho_min > 0:
            r["ancho_ajustado"] += ("; fuera de calzadas separadas la anchura mínima es %.1f m (%.0f m de ruta ensanchados: calles "
                                    "de sentido único o estrechas por las que el juego hace circular los dos sentidos; valor genérico, "
                                    "no medido)" % (a.ancho_min, n_min * PASO))
        L = s[-1]
        pct = {sen: round(100 * sum(e["km_fin"] - e["km_ini"] for e in extra if e["sentido"] == sen) * 1000 / L, 2) for sen in ("ida", "vuelta")}
        sal_adel.append({"id": ri, "nombre": r["nombre"], "prohibido": sorted(pf, key=lambda t: t["km_ini"]),
                         "carril_adelantamiento": extra, "carriles": carriles, "pct_con_carril_adelantamiento": pct,
                         "distancia_mediana_eje_osm_m": round(float(np.nanmedian(dist)), 2)})
        if a.lineas:
            ld = json.load(open(a.lineas)).get(str(ri), [])
            km_s = np.arange(len(sep)) * PASO / 1000.0
            m = np.zeros(len(sep), bool)
            for k0, k1 in ld: m |= (km_s >= k0) & (km_s <= k1)
            m &= ~sep
            ld2, i = [], 0
            while i < len(m):
                if m[i]:
                    j = i
                    while j + 1 < len(m) and m[j + 1]: j += 1
                    if (j - i) * PASO >= 20: ld2.append([round(km_s[i], 3), round(km_s[j], 3)])
                    i = j + 1
                else: i += 1
            sal_adel[-1]["linea_discontinua"] = ld2
        resumen[r["nombre"]] = {"cobertura_maxspeed": cobertura, "carril_extra_pct": pct, "n_carril_extra": len(extra)}
    fecha = bruto.get("fecha"); url = bruto.get("url")
    proy = f"WGS84 → ETRS89 / UTM 30N (EPSG:25830), origen E0={E0:.0f}, N0={N0:.0f}; X_juego = E − {E0:.0f}, Z_juego = {N0:.0f} − N"
    lim = {"rutas": sal_lim,
           "notas": ("Límites reales de OpenStreetMap (maxspeed, maxspeed:forward/backward) emparejados con cada muestra de la ruta "
                     "(cada 2 m: la vía OSM de la misma ref más cercana a ≤15 m con la misma orientación; en calzadas separadas, "
                     "la calzada contraria de la misma ref a ≤45 m da el límite de 'vuelta'; en rotondas sin ref, la carretera más cercana). "
                     "'ida' = km creciente (" + a.sentido + "). Donde OSM no tiene maxspeed: genérico legal, fuente='por_defecto_legal' "
                     "(NO es una señal real; el juego lo pinta tenue y con *): 90 km/h en carretera convencional fuera de poblado, "
                     "50 dentro de poblado (punto dentro de un polígono landuse=residential de OSM). Tramos de menos de "
                     f"{a.absorber:.0f} m se absorben en el contiguo (lista en 'tramos_pequenos_absorbidos'). No hay señales de velocidad "
                     "mapeadas como nodo en la zona. Datos © colaboradores de OpenStreetMap, ODbL."),
           "proyeccion": proy, "consulta_osm_fecha": fecha, "consulta_osm_url": url, "bbox_wgs84": zona["bbox_wgs84"]}
    json.dump(lim, open(os.path.join(D, "limites_velocidad.json"), "w"), ensure_ascii=False, indent=1)
    json.dump(car, open(os.path.join(D, "carreteras.json"), "w"), ensure_ascii=False, separators=(",", ":"))
    adel = {"notas": ("Adelantamiento según OpenStreetMap. 'prohibido' = [{km_ini, km_fin, sentido: ambos|ida|vuelta}] (mismo formato que "
                      f"navacerrada), ida = km creciente. Etiquetas overtaking* en el bbox: {len(con_overtaking)} vías de {len(todas)} highway, "
                      "así que no hay línea continua real en OSM. Lo que sí hay son carriles: 'carriles' = carriles por sentido (lanes, "
                      "lanes:forward/backward, y en calzadas separadas lanes de cada calzada) y 'carril_adelantamiento' = tramos de ≥150 m con "
                      "2 carriles en un sentido (carriles adicionales reales). 'prohibido' sale de dos reglas: (1) calzadas separadas en OSM "
                      "(real: no hay carril contrario) y (2) 'supuesto_2+1': en el sentido de 1 carril frente a 2 se supone línea continua "
                      "(habitual, no mapeado). Fuera de eso decide el juego: visibilidad real, curvas y coches de frente. "
                      + proy + ". Datos © colaboradores de OpenStreetMap, ODbL."),
            "consulta_osm_fecha": fecha, "consulta_osm_url": url, "vias_highway_en_bbox": len(todas),
            "vias_con_etiqueta_overtaking": len(con_overtaking), "rutas": sal_adel}
    json.dump(adel, open(os.path.join(D, "adelantar.json"), "w"), ensure_ascii=False, indent=1)
    print(json.dumps(resumen, ensure_ascii=False, indent=1))


def O_refs(t):
    return [r.strip() for r in re.split(r"[;,]", t.get("ref", "")) if r.strip()]


if __name__ == "__main__":
    main()
