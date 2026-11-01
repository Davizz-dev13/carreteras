## Una carretera extraída por el pipeline: centro de la calzada muestreado cada `paso` m,
## con altitud real suavizada, pendiente, curvatura, anchura y velocidad máxima.
class_name Ruta
extends RefCounted

var nombre := ""
var calle := ""
var refs := PackedStringArray()
var paso := 2.0
var pts := PackedVector3Array()        # X, altitud, Z (metros, 1:1)
var pendiente := PackedFloat32Array()  # % en el sentido de la ruta
var curvatura := PackedFloat32Array()  # 1/m (radio = 1/|k|)
var ancho := PackedFloat32Array()      # anchura de calzada (m)
var vmax := PackedInt32Array()         # km/h (OSM maxspeed o por tipo de vía)
var puente := PackedByteArray()
var tunel := PackedByteArray()
var dibujar := PackedByteArray()       # 0 si ese trozo ya lo dibuja otra ruta
var bajo := PackedByteArray()          # 1 donde pisa otra calzada ya dibujada (va 3 cm por debajo): sin líneas pintadas
var discontinua := PackedByteArray()   # 1 = línea central discontinua (se permite adelantar); de datos/…/adelantar.json
var estadisticas := {}
var etiquetas := PackedStringArray()   # "CL-601 · Carretera de …"
var etiqueta := PackedInt32Array()     # índice de etiqueta por muestra
var n := 0
var tang := PackedVector3Array()       # tangente unitaria en cada muestra (diferencias centradas)
# carriles por sentido (adelantar.json → "carriles"; vacío = 1 + 1, como siempre). ida = sentido de km creciente.
var car_ida := PackedByteArray()
var car_vuelta := PackedByteArray()
var lat_eje := PackedFloat32Array()      # desplazamiento lateral (+ = derecha) de la línea que separa los sentidos
var lat_ida := PackedFloat32Array()      # centro del carril derecho de ida / de vuelta
var lat_vuelta := PackedFloat32Array()
var lat_ida_adel := PackedFloat32Array() # carril por el que se adelanta (el adicional si lo hay; si no, el contrario)
var lat_vuelta_adel := PackedFloat32Array()


static func desde_json(d: Dictionary) -> Ruta:
	var r := Ruta.new()
	r.nombre = d.get("nombre", "")
	r.calle = d.get("calle", "")
	r.refs = PackedStringArray(d.get("refs", []))
	r.paso = float(d.get("paso", 2.0))
	r.estadisticas = d.get("estadisticas", {})
	var xs: Array = d["x"]
	var ys: Array = d["y"]
	var zs: Array = d["z"]
	r.n = xs.size()
	r.pts.resize(r.n)
	for i in r.n:
		r.pts[i] = Vector3(xs[i], ys[i], zs[i])
	r.pendiente = PackedFloat32Array(d["pendiente"])
	r.curvatura = PackedFloat32Array(d["curvatura"])
	r.ancho = PackedFloat32Array(d["ancho"])
	r.vmax = PackedInt32Array(d["vmax"])
	r.puente = PackedByteArray(d["puente"])
	r.tunel = PackedByteArray(d["tunel"])
	r.dibujar = PackedByteArray(d["dibujar"])
	r.etiquetas = PackedStringArray(d.get("etiquetas", []))
	r.etiqueta = PackedInt32Array(d.get("etiqueta", []))
	r.tang.resize(r.n)
	for i in r.n:
		r.tang[i] = (r.pts[mini(i + 1, r.n - 1)] - r.pts[maxi(i - 1, 0)]).normalized()
	return r


## Carga los carriles reales por sentido: tramos [{km_ini, km_fin, ida, vuelta}] (de adelantar.json).
## Precalcula la posición lateral de cada carril, suavizada (~60 m) para que los cambios sean una cuña, no un salto.
func cargar_carriles(tramos: Array) -> void:
	if tramos.is_empty():
		return
	car_ida.resize(n); car_ida.fill(1)
	car_vuelta.resize(n); car_vuelta.fill(1)
	for t in tramos:
		var a := clampi(int(float(t["km_ini"]) * 1000.0 / paso), 0, n - 1)
		var b := clampi(int(float(t["km_fin"]) * 1000.0 / paso), 0, n - 1)
		for i in range(a, b + 1):
			car_ida[i] = clampi(int(t["ida"]), 1, 3)
			car_vuelta[i] = clampi(int(t["vuelta"]), 1, 3)
	var crudo := [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
	for arr in crudo:
		arr.resize(n)
	for i in n:
		var ci := car_ida[i]
		var cv := car_vuelta[i]
		if ci == 1 and cv == 1:
			# exactamente lo de siempre (ancho/4)
			crudo[0][i] = 0.0
			crudo[1][i] = ancho[i] * 0.25
			crudo[2][i] = -ancho[i] * 0.25
			crudo[3][i] = -ancho[i] * 0.25
			crudo[4][i] = ancho[i] * 0.25
			continue
		var w := (ancho[i] - 1.0) / float(ci + cv)
		var e := (cv - ci) * w * 0.5
		crudo[0][i] = e
		crudo[1][i] = e + (ci - 0.5) * w
		crudo[2][i] = e - (cv - 0.5) * w
		crudo[3][i] = e + 0.5 * w if ci >= 2 else e - 0.5 * w
		crudo[4][i] = e - 0.5 * w if cv >= 2 else e + 0.5 * w
	var salida := []
	var k := 15   # ±30 m
	for arr in crudo:
		var o := PackedFloat32Array()
		o.resize(n)
		var acum := 0.0
		for i in range(-k, n + k + 1):
			acum += arr[clampi(i, 0, n - 1)]
			if i - 2 * k - 1 >= -k:
				acum -= arr[clampi(i - 2 * k - 1, 0, n - 1)]
			var c := i - k
			if c >= 0 and c < n:
				o[c] = acum / float(2 * k + 1)
		salida.append(o)
	lat_eje = salida[0]
	lat_ida = salida[1]
	lat_vuelta = salida[2]
	lat_ida_adel = salida[3]
	lat_vuelta_adel = salida[4]


func tiene_carriles() -> bool:
	return not car_ida.is_empty()


## Posición lateral (+ = derecha de la ruta) del carril del sentido d; adel = 0 su carril, 1 el carril de adelantar
func lateral_carril(s: float, d: int, adel: float = 0.0) -> float:
	var lat := 0.0
	if car_ida.is_empty():
		lat = d * valor(ancho, s) * 0.25 * (1.0 - 2.0 * adel)
	elif d > 0:
		lat = lerpf(valor(lat_ida, s), valor(lat_ida_adel, s), adel)
	else:
		lat = lerpf(valor(lat_vuelta, s), valor(lat_vuelta_adel, s), adel)
	# en el arco de una glorieta (un solo sentido) el carril va centrado en el anillo
	if not peso_anillo.is_empty():
		lat *= 1.0 - valor(peso_anillo, s)
	return lat


## Línea que separa los dos sentidos (lateral, + = derecha)
func lateral_eje(s: float) -> float:
	return 0.0 if lat_eje.is_empty() else valor(lat_eje, s)


## ¿Tiene el sentido d un carril adicional (2 o más carriles) en s?
func carril_extra(s: float, d: int) -> bool:
	if car_ida.is_empty():
		return false
	var i := clampi(int(roundf(s / paso)), 0, n - 1)
	return (car_ida[i] if d > 0 else car_vuelta[i]) >= 2


## ¿Hay carril adicional para el sentido d en todo el tramo de s0 a s1? (comprueba cada 4 m)
func carril_extra_tramo(s0: float, s1: float, d: int) -> bool:
	if car_ida.is_empty():
		return false
	var x := minf(s0, s1)
	while x <= maxf(s0, s1):
		if not carril_extra(x, d):
			return false
		x += 4.0
	return true


## Nombre de la carretera en el punto s (cambia de M-601 a CL-601 en el puerto)
func rotulo(s: float) -> String:
	if etiqueta.is_empty():
		return nombre
	return etiquetas[etiqueta[clampi(int(s / paso), 0, n - 1)]]


func longitud() -> float:
	return (n - 1) * paso


func _idx(s: float) -> int:
	return clampi(int(s / paso), 0, n - 2)


## Valor interpolado de un array por muestra en la distancia s (m)
func valor(arr, s: float) -> float:
	var i := _idx(s)
	var f := clampf(s / paso - i, 0.0, 1.0)
	return lerpf(float(arr[i]), float(arr[i + 1]), f)


## Punto del centro de la calzada en s: interpolación cúbica de Hermite (posición Y tangente continuas),
## así nada que siga la ruta (tráfico, piloto, cámara) da tirones al pasar de una muestra a la siguiente.
func punto(s: float) -> Vector3:
	var i := _idx(s)
	var f := clampf(s / paso - i, 0.0, 1.0)
	var p0 := pts[i]
	var p1 := pts[i + 1]
	var m0 := tang[i] * paso
	var m1 := tang[i + 1] * paso
	var f2 := f * f
	var f3 := f2 * f
	return p0 * (2.0 * f3 - 3.0 * f2 + 1.0) + m0 * (f3 - 2.0 * f2 + f) + p1 * (-2.0 * f3 + 3.0 * f2) + m1 * (f3 - f2)


## Dirección de avance (3D, unitaria), interpolada entre muestras (sin escalones cada 2 m)
func tangente(s: float) -> Vector3:
	var i := _idx(s)
	var f := clampf(s / paso - i, 0.0, 1.0)
	return tang[i].lerp(tang[i + 1], f).normalized()


## Vector horizontal a la derecha del sentido de la ruta
func derecha(s: float) -> Vector3:
	var t := tangente(s)
	return Vector3(-t.z, 0.0, t.x).normalized()


## Proyecta una posición sobre la ruta: devuelve Vector2(s, desplazamiento lateral; + = derecha).
## Busca cerca de s_pista; si está lejos, hace una búsqueda global.
func proyectar(p: Vector3, s_pista: float = -1.0, ventana: float = 80.0, refinando := false) -> Vector2:
	var i0 := 0
	var i1 := n - 1
	var salto := 1
	if s_pista >= 0.0:
		i0 = maxi(0, int((s_pista - ventana) / paso))
		i1 = mini(n - 1, int((s_pista + ventana) / paso))
	else:
		salto = 4
	var mejor := 1e20
	var im := i0
	var i := i0
	while i <= i1:
		var q := pts[i]
		var d := (q.x - p.x) * (q.x - p.x) + (q.z - p.z) * (q.z - p.z)
		if d < mejor:
			mejor = d
			im = i
		i += salto
	if s_pista >= 0.0 and mejor > 900.0 and not refinando:
		return proyectar(p, -1.0)
	if salto > 1:
		return proyectar(p, im * paso, 12.0, true)
	# refinar en los dos segmentos vecinos
	var res := Vector2(im * paso, 0.0)
	var dmin := 1e20
	for k in [im - 1, im]:
		if k < 0 or k >= n - 1:
			continue
		var a := Vector2(pts[k].x, pts[k].z)
		var b := Vector2(pts[k + 1].x, pts[k + 1].z)
		var ab := b - a
		var t := clampf((Vector2(p.x, p.z) - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		var c := a + ab * t
		var d2 := c.distance_squared_to(Vector2(p.x, p.z))
		if d2 < dmin:
			dmin = d2
			var dirv := ab.normalized()
			var der := Vector2(-dirv.y, dirv.x)
			res = Vector2((k + t) * paso, (Vector2(p.x, p.z) - c).dot(der))
	return res


## Datos de un tramo [s0, s1] (en metros): longitud, desnivel, pendiente máxima…
func resumen_tramo(s0: float, s1: float) -> Dictionary:
	var a := clampi(int(minf(s0, s1) / paso), 0, n - 1)
	var b := clampi(int(maxf(s0, s1) / paso), 0, n - 1)
	var sube := 0.0
	var baja := 0.0
	var zmin := 1e9
	var zmax := -1e9
	for i in range(a, b + 1):
		zmin = minf(zmin, pts[i].y)
		zmax = maxf(zmax, pts[i].y)
		if i > a:
			var dz := pts[i].y - pts[i - 1].y
			if dz > 0: sube += dz
			else: baja -= dz
	var sentido := 1.0 if s1 >= s0 else -1.0
	var gmax := 0.0
	var ventana := int(100.0 / paso)
	for i in range(a, b - ventana + 1):
		var g := (pts[i + ventana].y - pts[i].y) / 100.0 * 100.0 * sentido
		if absf(g) > absf(gmax): gmax = g
	if sentido < 0:
		var t := sube
		sube = baja
		baja = t
	return {"longitud": (b - a) * paso, "sube": sube, "baja": baja, "zmin": zmin, "zmax": zmax,
			"pendiente_max": gmax, "z_ini": punto(s0).y, "z_fin": punto(s1).y}


# ---------------------------------------------------------------- glorietas (anillo de un solo sentido)
## En España el anillo de una glorieta es de un solo sentido y se recorre en sentido antihorario (visto desde arriba),
## cediendo el paso a quien ya circula por él. La ruta es una sola calzada de doble sentido y, donde pasa por una
## glorieta, sigue un arco del anillo en el sentido en que lo recorre OSM (antihorario para el sentido de la ruta):
## antes el juego hacía circular por ese arco también el sentido contrario (dos carriles opuestos, con línea central),
## es decir, coches girando al revés por la glorieta. Ahora:
##  · el arco es de un solo sentido: sin línea central y con el carril centrado en el anillo (anillo, peso_anillo);
##  · el sentido contrario no pasa por el arco: sale de la ruta unos metros antes, entra al anillo un poco después de
##    donde la ruta lo deja, lo rodea por el resto (antihorario) y vuelve a la ruta un poco antes de donde la ruta
##    entra (desvios: polilínea cada ~1 m con su longitud acumulada).
## dentro_glorieta = 1 en las muestras de la ruta dentro del borde exterior de un anillo (ahí no se pintan las líneas
## de la ruta: el anillo lleva las suyas, Cruces/mapa_streaming).
var anillo := PackedByteArray()          # 1 = la ruta va por el anillo de una glorieta
var peso_anillo := PackedFloat32Array()  # 0..1 suavizado (±10 m): el carril pasa de su lado al centro del anillo
var dentro_glorieta := PackedByteArray()
var desvios: Array = []                  # {d, s_lo, s_hi, pts, acum, L, u_ent, u_sal, g}
var desvio_idx := PackedInt32Array()     # índice en desvios para el sentido que se desvía, por muestra (-1 = ninguno)
var s_trafico_min := 0.0                 # el tráfico aparece/desaparece entre estos s (fuera de una glorieta en los extremos)
var s_trafico_max := 1e12
var arcos_glorieta: Array = []           # {g, a, b, sentido (+1: la ruta lo recorre antihorario)} (verificación)

const DESVIO_MARGEN := 18.0              # m fuera del borde exterior del anillo donde el sentido contrario deja la ruta


func cargar_glorietas(glorietas: Array) -> void:
	anillo.resize(n); anillo.fill(0)
	dentro_glorieta.resize(n); dentro_glorieta.fill(0)
	desvio_idx.resize(n); desvio_idx.fill(-1)
	peso_anillo.resize(n); peso_anillo.fill(0.0)
	desvios.clear()
	arcos_glorieta.clear()
	for gi in glorietas.size():
		var g: Dictionary = glorietas[gi]
		var xs: Array = g["x"]
		var ys: Array = g["y"]
		var zs: Array = g["z"]
		var m := xs.size()
		if m < 6:
			continue
		var hw := float(g.get("hw", 4.0))
		var anill := PackedVector3Array()
		var c := Vector3.ZERO
		for j in m:
			anill.append(Vector3(float(xs[j]), float(ys[j]), float(zs[j])))
			c += anill[j]
		c /= float(m)
		# orden antihorario en el mapa (x este, -z norte): área con signo > 0 en (x, -z)
		var area := 0.0
		for j in m:
			var p0 := anill[j]
			var p1 := anill[(j + 1) % m]
			area += p0.x * (-p1.z) - p1.x * (-p0.z)
		if area < 0.0:
			anill.reverse()
		if anill[0].distance_to(anill[m - 1]) < 0.05:
			anill.remove_at(m - 1)
			m -= 1
		var radio := 0.0
		for j in m:
			radio += Vector2(anill[j].x - c.x, anill[j].z - c.z).length()
		radio /= float(m)
		var exterior := radio + hw + 0.5
		var umbral := maxf(2.5, hw * 0.6)
		# muestras de la ruta sobre el anillo (y dentro de su borde exterior)
		var i0 := -1
		var run := []
		var i := 0
		while i < n:
			var q := pts[i]
			var dc := Vector2(q.x - c.x, q.z - c.z).length()
			if dc < exterior and absf(q.y - c.y) < 8.0:
				dentro_glorieta[i] = 1
			if absf(dc - radio) < umbral and absf(q.y - c.y) < 8.0 and _dist_poli(q, anill) < umbral:
				if i0 < 0:
					i0 = i
			elif i0 >= 0:
				run.append(Vector2i(i0, i - 1))
				i0 = -1
			i += 1
		if i0 >= 0:
			run.append(Vector2i(i0, n - 1))
		# juntar trozos separados por huecos de 1-3 muestras
		var arcos := []
		for r in run:
			if not arcos.is_empty() and r.x - (arcos[arcos.size() - 1] as Vector2i).y <= 4:
				arcos[arcos.size() - 1] = Vector2i((arcos[arcos.size() - 1] as Vector2i).x, r.y)
			else:
				arcos.append(r)
		for ar in arcos:
			var a: int = ar.x
			var b: int = ar.y
			if b - a < 3:
				continue
			var giro := _angulo(pts[b], c) - _angulo(pts[a], c)
			giro = wrapf(giro, -PI, PI) if b - a < 6 else _giro_acumulado(a, b, c)
			if absf(giro) < deg_to_rad(20.0):
				continue      # la ruta solo roza el anillo
			var sentido := 1 if giro > 0.0 else -1
			arcos_glorieta.append({"g": gi, "a": a, "b": b, "sentido": sentido})
			for k in range(a, b + 1):
				anillo[k] = 1
			_crear_desvio(gi, anill, c, radio, hw, exterior, a, b, sentido)
	# peso suavizado para el lateral del carril
	# el carril se centra en el anillo DENTRO del arco (rampa de ~20 m desde donde la ruta entra en el anillo y hasta
	# donde lo deja): antes de entrar sigue en su carril, sin acercarse a la salida del sentido contrario
	var k := 5
	var nucleo := PackedFloat32Array()
	nucleo.resize(n)
	for i in n:
		var todo := 1.0
		for j in range(i - k, i + k + 1):
			if anillo[clampi(j, 0, n - 1)] == 0:
				todo = 0.0
				break
		nucleo[i] = todo
	for i in n:
		var acum := 0.0
		for j in range(i - k, i + k + 1):
			acum += nucleo[clampi(j, 0, n - 1)]
		peso_anillo[i] = acum / float(2 * k + 1)
	# la ruta empieza o acaba dentro de una glorieta (p. ej. la M-617 de Navacerrada nace en el borde de un anillo):
	# el tráfico aparece y desaparece fuera de ella, sin recorrer unos metros de anillo en el sentido que toque
	s_trafico_min = 0.0
	s_trafico_max = longitud()
	var j0 := 0
	while j0 < mini(n, 40) and dentro_glorieta[j0] == 1:
		j0 += 1
	if j0 > 0 and j0 < mini(n, 40):
		s_trafico_min = (j0 + 4) * paso
	var j1 := n - 1
	while j1 > maxi(0, n - 40) and dentro_glorieta[j1] == 1:
		j1 -= 1
	if j1 < n - 1 and j1 > maxi(0, n - 40):
		s_trafico_max = (j1 - 4) * paso


func _angulo(p: Vector3, c: Vector3) -> float:
	return atan2(-(p.z - c.z), p.x - c.x)


func _giro_acumulado(a: int, b: int, c: Vector3) -> float:
	var t := 0.0
	for i in range(a, b):
		t += wrapf(_angulo(pts[i + 1], c) - _angulo(pts[i], c), -PI, PI)
	return t


static func _dist_poli(q: Vector3, poli: PackedVector3Array) -> float:
	var mejor := 1e9
	var m := poli.size()
	for j in m:
		var p0 := Vector2(poli[j].x, poli[j].z)
		var p1 := Vector2(poli[(j + 1) % m].x, poli[(j + 1) % m].z)
		var ab := p1 - p0
		var t := clampf((Vector2(q.x, q.z) - p0).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		mejor = minf(mejor, (p0 + ab * t).distance_to(Vector2(q.x, q.z)))
	return mejor


## Punto del anillo (orden antihorario) en el ángulo th, desplazado `lat` m hacia fuera
static func _punto_anillo(anill: PackedVector3Array, c: Vector3, th: float, lat: float) -> Vector3:
	var m := anill.size()
	var mejor := 1e9
	var jm := 0
	for j in m:
		var a0 := atan2(-(anill[j].z - c.z), anill[j].x - c.x)
		var a1 := atan2(-(anill[(j + 1) % m].z - c.z), anill[(j + 1) % m].x - c.x)
		var span := wrapf(a1 - a0, -PI, PI)
		var rel := wrapf(th - a0, -PI, PI)
		if span > 1e-5 and rel >= 0.0 and rel <= span:
			var q := anill[j].lerp(anill[(j + 1) % m], rel / span)
			return q + _fuera(q, c) * lat
		if absf(rel) < mejor:
			mejor = absf(rel)
			jm = j
	return anill[jm] + _fuera(anill[jm], c) * lat


static func _fuera(p: Vector3, c: Vector3) -> Vector3:
	return Vector3(p.x - c.x, 0.0, p.z - c.z).normalized()


## Índice de la primera muestra (desde i, avanzando paso_i) fuera del borde exterior + margen
func _fuera_de(i: int, paso_i: int, c: Vector3, lim: float) -> int:
	var j := i
	var cuenta := 0
	while j + paso_i >= 0 and j + paso_i < n and cuenta < 90:
		j += paso_i
		cuenta += 1
		if Vector2(pts[j].x - c.x, pts[j].z - c.z).length() > lim:
			break
	return j


func _crear_desvio(gi: int, anill: PackedVector3Array, c: Vector3, radio: float, hw: float, exterior: float,
		a: int, b: int, sentido: int) -> void:
	# d = sentido de la ruta que se desvía (el que recorrería el arco al revés)
	var d := -sentido
	# el desviado llega por el lado de b si d = -1 (va hacia s decreciente) y por el de a si d = +1
	var i_lleg := b if d < 0 else a
	var i_sale := a if d < 0 else b
	var i_ini := _fuera_de(i_lleg, -d, c, exterior + DESVIO_MARGEN)
	var i_fin := _fuera_de(i_sale, d, c, exterior + DESVIO_MARGEN)
	# la ruta empieza o acaba en la glorieta: el desvío empieza o acaba en el propio anillo (el coche aparece o
	# desaparece ahí) en vez de enlazar con la ruta
	var ini_en_anillo := i_ini == i_lleg
	var fin_en_anillo := i_fin == i_sale
	if (ini_en_anillo and not (i_lleg == 0 or i_lleg == n - 1)) or (fin_en_anillo and not (i_sale == 0 or i_sale == n - 1)):
		return
	if ini_en_anillo and fin_en_anillo:
		return
	for o in desvios:
		# otro desvío que se solapa (dos glorietas muy juntas): no se crea este
		if mini(i_ini, i_fin) <= maxi(int(o["i_ini"]), int(o["i_fin"])) and maxi(i_ini, i_fin) >= mini(int(o["i_ini"]), int(o["i_fin"])):
			return
	var lat_anillo := hw * 0.25          # en el anillo, algo hacia fuera del eje (a la derecha del que circula)
	var delta := (hw + 5.0) / maxf(radio, 5.0)
	var th_lleg := _angulo(pts[i_lleg], c)
	var th_sale := _angulo(pts[i_sale], c)
	# para el desviado (antihorario): entra un poco después de donde la ruta deja el anillo y sale un poco antes de
	# donde la ruta entra; el sentido de la ruta (si fuera horario en OSM, sentido = -1) se trata igual con los papeles
	# cambiados: siempre se rodea antihorario
	var th_ent := th_lleg + delta
	var th_sal := th_sale - delta
	var barrido := wrapf(th_sal - th_ent, 0.0, TAU)
	if barrido < 0.3:
		return
	var p0 := pts[i_ini] + _der_i(i_ini) * lateral_carril(i_ini * paso, d)
	var t0 := tang[i_ini] * d
	var p3 := pts[i_fin] + _der_i(i_fin) * lateral_carril(i_fin * paso, d)
	var t3 := tang[i_fin] * d
	var poli := PackedVector3Array()
	var q_ent := _punto_anillo(anill, c, th_ent, lat_anillo)
	var tg_ent := _tangente_ccw(q_ent, c)
	if ini_en_anillo:
		th_ent = th_lleg            # empieza en el anillo, donde está el extremo de la ruta
		barrido = wrapf(th_sal - th_ent, 0.0, TAU)
		q_ent = _punto_anillo(anill, c, th_ent, lat_anillo)
	else:
		_bezier(poli, p0, t0, q_ent, tg_ent, 0.42, 0.2)
	var u_ent_n := poli.size()
	var pasos := maxi(4, int(barrido * radio / 1.0))
	for k in range(0 if ini_en_anillo else 1, pasos):
		poli.append(_punto_anillo(anill, c, th_ent + barrido * k / float(pasos), lat_anillo))
	if fin_en_anillo:
		th_sal = th_sale
		barrido = wrapf(th_sal - th_ent, 0.0, TAU)
	var q_sal := _punto_anillo(anill, c, th_sal, lat_anillo)
	var u_sal_n := poli.size()
	if fin_en_anillo:
		poli.append(q_sal)
	else:
		_bezier(poli, q_sal, _tangente_ccw(q_sal, c), p3, t3, 0.2, 0.42)
	if not fin_en_anillo:
		poli.append(p3)
	var acum := PackedFloat32Array()
	acum.resize(poli.size())
	var L := 0.0
	for k in poli.size():
		if k > 0:
			L += poli[k].distance_to(poli[k - 1])
		acum[k] = L
	var s_lo := minf(i_ini, i_fin) * paso
	var s_hi := maxf(i_ini, i_fin) * paso
	var idx := desvios.size()
	desvios.append({"d": d, "s_lo": s_lo, "s_hi": s_hi, "i_ini": i_ini, "i_fin": i_fin, "pts": poli, "acum": acum, "L": L,
			"u_ent": acum[mini(u_ent_n, poli.size() - 1)], "u_sal": acum[mini(u_sal_n, poli.size() - 1)], "g": gi,
			"a": a, "b": b, "radio": radio, "c": c})
	for k in range(mini(i_ini, i_fin) + 1, maxi(i_ini, i_fin)):
		desvio_idx[k] = idx


func _der_i(i: int) -> Vector3:
	return Vector3(-tang[i].z, 0.0, tang[i].x).normalized()


static func _tangente_ccw(p: Vector3, c: Vector3) -> Vector3:
	# antihorario en el mapa (x este, -z norte): perpendicular a la izquierda del radio
	var r := Vector3(p.x - c.x, 0.0, p.z - c.z).normalized()
	return Vector3(r.z, 0.0, -r.x)


## Curva de Bézier cúbica de p0 (dirección t0) a p3 (dirección t3), cada ~1 m (sin repetir p3)
static func _bezier(poli: PackedVector3Array, p0: Vector3, t0: Vector3, p3: Vector3, t3: Vector3, f0 := 0.42, f3 := 0.42) -> void:
	var dist := p0.distance_to(p3)
	var t0h := Vector3(t0.x, 0.0, t0.z).normalized() * dist * f0
	var t3h := Vector3(t3.x, 0.0, t3.z).normalized() * dist * f3
	var p1 := p0 + t0h
	var p2 := p3 - t3h
	var pasos := maxi(4, int(dist * 1.3))
	for k in pasos:
		var f := k / float(pasos)
		var g := 1.0 - f
		poli.append(p0 * g * g * g + p1 * 3.0 * g * g * f + p2 * 3.0 * g * f * f + p3 * f * f * f)


## ¿En s, el sentido d circula por un desvío de glorieta? Devuelve el índice en desvios o -1
func desvio_en(s: float, d: int) -> int:
	if desvio_idx.is_empty():
		return -1
	var i := clampi(int(roundf(s / paso)), 0, n - 1)
	var k := desvio_idx[i]
	if k < 0 or int(desvios[k]["d"]) != d:
		return -1
	var dv: Dictionary = desvios[k]
	if s <= float(dv["s_lo"]) or s >= float(dv["s_hi"]):
		return -1
	return k


## Distancia recorrida por el desvío k que corresponde a s (el desviado recorre s de i_ini a i_fin)
func u_desvio(k: int, s: float) -> float:
	var dv: Dictionary = desvios[k]
	var s_ini := float(dv["i_ini"]) * paso
	var s_fin := float(dv["i_fin"]) * paso
	return clampf((s - s_ini) / (s_fin - s_ini), 0.0, 1.0) * float(dv["L"])


func s_desvio(k: int, u: float) -> float:
	var dv: Dictionary = desvios[k]
	var s_ini := float(dv["i_ini"]) * paso
	var s_fin := float(dv["i_fin"]) * paso
	return s_ini + (s_fin - s_ini) * clampf(u / float(dv["L"]), 0.0, 1.0)


## Punto y tangente (de marcha) del desvío k a la distancia u
func punto_desvio(k: int, u: float) -> Vector3:
	var dv: Dictionary = desvios[k]
	var p: PackedVector3Array = dv["pts"]
	var ac: PackedFloat32Array = dv["acum"]
	var j := clampi(ac.bsearch(u) - 1, 0, p.size() - 2)
	var f := clampf((u - ac[j]) / maxf(ac[j + 1] - ac[j], 1e-4), 0.0, 1.0)
	return p[j].lerp(p[j + 1], f)


func tangente_desvio(k: int, u: float) -> Vector3:
	var dv: Dictionary = desvios[k]
	var p: PackedVector3Array = dv["pts"]
	var ac: PackedFloat32Array = dv["acum"]
	var j := clampi(ac.bsearch(u) - 1, 0, p.size() - 2)
	var j0 := maxi(j - 1, 0)
	var j1 := mini(j + 2, p.size() - 1)
	return (p[j1] - p[j0]).normalized()


## Proyección de p sobre el desvío k cerca de u_pista: devuelve u
func proyectar_desvio(k: int, p: Vector3, u_pista: float) -> float:
	var dv: Dictionary = desvios[k]
	var poli: PackedVector3Array = dv["pts"]
	var ac: PackedFloat32Array = dv["acum"]
	var j0 := clampi(ac.bsearch(u_pista - 25.0) - 1, 0, poli.size() - 2)
	var j1 := clampi(ac.bsearch(u_pista + 25.0), 1, poli.size() - 1)
	var mejor := 1e20
	var res := u_pista
	for j in range(j0, j1):
		var a := Vector2(poli[j].x, poli[j].z)
		var b := Vector2(poli[j + 1].x, poli[j + 1].z)
		var ab := b - a
		var t := clampf((Vector2(p.x, p.z) - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		var d2 := (a + ab * t).distance_squared_to(Vector2(p.x, p.z))
		if d2 < mejor:
			mejor = d2
			res = ac[j] + (ac[j + 1] - ac[j]) * t
	return res


## Para el tráfico y el piloto: punto del carril del sentido d en s (en un desvío, sobre el desvío)
func punto_carril(s: float, d: int, adel := 0.0) -> Vector3:
	var k := desvio_en(s, d)
	if k >= 0:
		return punto_desvio(k, u_desvio(k, s))
	return punto(s) + derecha(s) * lateral_carril(s, d, adel)


## Dirección de marcha del sentido d en s
func marcha_carril(s: float, d: int) -> Vector3:
	var k := desvio_en(s, d)
	if k >= 0:
		return tangente_desvio(k, u_desvio(k, s))
	return tangente(s) * d


## m recorridos por metro de s en el sentido d (en un desvío el camino es más largo que el arco de la ruta)
func escala_carril(s: float, d: int) -> float:
	var k := desvio_en(s, d)
	if k < 0:
		return 1.0
	var dv: Dictionary = desvios[k]
	return absf(float(dv["i_fin"]) - float(dv["i_ini"])) * paso / maxf(float(dv["L"]), 1.0)


## Curvatura (1/m) del camino del desvío en s para el sentido d, o -1 si no hay desvío (para la velocidad en curva)
func curv_desvio(s: float, d: int) -> float:
	var k := desvio_en(s, d)
	if k < 0:
		return -1.0
	return 1.0 / clampf(float(desvios[k]["radio"]) * 0.75, 9.0, 40.0)
