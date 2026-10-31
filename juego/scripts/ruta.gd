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
	if car_ida.is_empty():
		return d * valor(ancho, s) * 0.25 * (1.0 - 2.0 * adel)
	if d > 0:
		return lerpf(valor(lat_ida, s), valor(lat_ida_adel, s), adel)
	return lerpf(valor(lat_vuelta, s), valor(lat_vuelta_adel, s), adel)


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
