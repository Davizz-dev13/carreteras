## Proyecciones para el mundo por teselas (sin dependencias): UTM 30N (ETRS89, el sistema del juego) ↔ geográficas
## ↔ píxel Web Mercator (teselas de relieve de Mapterhorn) y la rejilla de teselas EPSG:25830 del WMTS del PNOA (IGN).
## Coordenadas del juego: X = E − E0, Z = N0 − N, Y = altitud (m), con (E0, N0) = origen_utm de la zona (zona.json).
## Fórmulas: UTM inversa de Snyder (USGS PP 1395, §8); comprobada contra pyproj (< 1 mm en toda España, 6-nov-2026).
class_name EarthGeo
extends RefCounted

const A := 6378137.0
const F := 1.0 / 298.257222101       # GRS80 (ETRS89)
const K0 := 0.9996
const LON0 := -3.0                   # meridiano central del huso 30

# WMTS PNOA (https://www.ign.es/wmts/pnoa-ma, TileMatrixSet EPSG:25830, leído de GetCapabilities el 6-nov-2026):
# tamaño de píxel del nivel 0 (ScaleDenominator × 0,00028 m) y esquina superior izquierda de cada nivel.
# La X es la misma en todos los niveles; la Y está redondeada al metro en cada nivel, así que las teselas de un
# nivel y las del siguiente no encajan exactamente (≤ 0,6 m): por eso el árbol de teselas del juego es propio
# (mismos tamaños, origen fijo) y cada nodo recorta su textura de las teselas WMTS con su desfase en píxeles.
const WMTS_PX0 := 78271.51698
const WMTS_X0 := -1968157.095
const WMTS_Y0 := {8: 7280055.0, 9: 7280055.0, 10: 7280055.0, 11: 7280055.0, 12: 7275163.0, 13: 7272717.0,
		14: 7271494.0, 15: 7272105.0, 16: 7271800.0, 17: 7271647.0, 18: 7271570.0, 19: 7271532.0}
const ARBOL_Y0 := 7280055.0          # origen (N) del árbol de teselas del juego (= el del nivel 9 del WMTS)


static func px_wmts(nivel: int) -> float:
	return WMTS_PX0 / float(1 << nivel)


static func lado(nivel: int) -> float:
	return 256.0 * px_wmts(nivel)


## UTM 30N → Vector2(lon, lat) en grados
static func utm_a_geo(e: float, n: float) -> Vector2:
	var e2 := F * (2.0 - F)
	var ep2 := e2 / (1.0 - e2)
	var x := e - 500000.0
	var m := n / K0
	var mu := m / (A * (1.0 - e2 / 4.0 - 3.0 * e2 * e2 / 64.0 - 5.0 * e2 * e2 * e2 / 256.0))
	var r := sqrt(1.0 - e2)
	var e1 := (1.0 - r) / (1.0 + r)
	var p1 := mu + (1.5 * e1 - 27.0 * pow(e1, 3) / 32.0) * sin(2.0 * mu) + (21.0 * e1 * e1 / 16.0 - 55.0 * pow(e1, 4) / 32.0) * sin(4.0 * mu) \
			+ (151.0 * pow(e1, 3) / 96.0) * sin(6.0 * mu) + (1097.0 * pow(e1, 4) / 512.0) * sin(8.0 * mu)
	var s := sin(p1)
	var c := cos(p1)
	var tn := tan(p1)
	var c1 := ep2 * c * c
	var t1 := tn * tn
	var n1 := A / sqrt(1.0 - e2 * s * s)
	var r1 := A * (1.0 - e2) / pow(1.0 - e2 * s * s, 1.5)
	var d := x / (n1 * K0)
	var lat := p1 - (n1 * tn / r1) * (d * d / 2.0 - (5.0 + 3.0 * t1 + 10.0 * c1 - 4.0 * c1 * c1 - 9.0 * ep2) * pow(d, 4) / 24.0 \
			+ (61.0 + 90.0 * t1 + 298.0 * c1 + 45.0 * t1 * t1 - 252.0 * ep2 - 3.0 * c1 * c1) * pow(d, 6) / 720.0)
	var lon := deg_to_rad(LON0) + (d - (1.0 + 2.0 * t1 + c1) * pow(d, 3) / 6.0 \
			+ (5.0 - 2.0 * c1 + 28.0 * t1 - 3.0 * c1 * c1 + 8.0 * ep2 + 24.0 * t1 * t1) * pow(d, 5) / 120.0) / c
	return Vector2(rad_to_deg(lon), rad_to_deg(lat))


## Geográficas → píxel global Web Mercator a zoom z con teselas de `tam` px
static func geo_a_merc(lonlat: Vector2, z: int, tam := 512) -> Vector2:
	var n := float(1 << z) * tam
	var la := deg_to_rad(lonlat.y)
	return Vector2((lonlat.x + 180.0) / 360.0 * n, (1.0 - log(tan(la) + 1.0 / cos(la)) / PI) * 0.5 * n)


## Metros por píxel de Mapterhorn (teselas de 512 px) a la latitud dada
static func m_px_merc(z: int, lat: float) -> float:
	return 78271.517 * cos(deg_to_rad(lat)) / float(1 << z)
