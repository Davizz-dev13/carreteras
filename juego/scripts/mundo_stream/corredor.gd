## Pasillo de las carreteras para graduar el terreno por teselas: el relieve real (LiDAR) se rebaja o se rellena bajo
## la calzada y se funde con el terreno natural con un talud de pendiente 2:3 (desmonte o terraplén), como una
## carretera de verdad. Así la calzada nunca flota ni queda enterrada, sea cual sea la resolución de la tesela.
## Se construye una vez con las vías ya cargadas (rutas, vías secundarias, glorietas); después es de solo lectura y
## se consulta desde los hilos que montan las teselas.
class_name EarthCorredor
extends RefCounted

const CELDA := 32.0
const W_MAX := 20.0        # anchura máxima del talud de transición (m más allá de la banda plana)
const RI_MAX := 12.0       # banda plana máxima junto al borde (teselas gruesas)
const BAJO_ASFALTO := 0.12 # el terreno queda 12 cm por debajo de la rasante (el asfalto se dibuja 5 cm por encima)
const PASO_DECIMADO := 4   # muestras de 2 m por segmento del pasillo (8 m; flecha < 0,25 m en curvas de R ≥ 30 m)

var ax := PackedFloat32Array()
var az := PackedFloat32Array()
var ay := PackedFloat32Array()
var bx := PackedFloat32Array()
var bz := PackedFloat32Array()
var by := PackedFloat32Array()
var hw := PackedFloat32Array()
var celdas := {}            # Vector2i -> PackedInt32Array (segmentos)
var tri := PackedFloat32Array()    # triángulos de las glorietas (9 floats cada uno)
var celdas_t := {}
var segmentos := 0


func construir(rutas: Array, vias: Array, glorietas: Array) -> void:
	var t0 := Time.get_ticks_msec()
	for r in rutas:
		var valido := PackedByteArray()
		valido.resize(r.n)
		for i in r.n:
			valido[i] = 1 if (r.tunel[i] == 0 and r.puente[i] == 0) else 0
		_polilinea(r.pts, r.ancho, valido, 0.0)
	for v in vias:
		if int(v.get("tunel", 0)) == 1 or int(v.get("puente", 0)) == 1:
			continue
		var p: PackedVector3Array = v["pts"]
		if v.get("gemela", false):
			if v.get("oculta_glorieta", false):
				continue
			p = v.get("pts_dib", p)
		var valido := PackedByteArray()
		valido.resize(p.size())
		valido.fill(1)
		_polilinea(p, PackedFloat32Array(), valido, float(v["ancho"]))
	for g in glorietas:
		var inf := GlorietaTipo.info(g)
		if not inf["ok"]:
			continue
		var xs: Array = g["x"]
		var m := xs.size()
		var h := float(inf["hw"]) + GlorietaTipo.BORDE_EXTRA
		for i in m:
			var j := (i + 1) % m
			_segmento(Vector3(float(xs[i]), float(g["y"][i]), float(g["z"][i])), Vector3(float(xs[j]), float(g["y"][j]), float(g["z"][j])), h)
	for sup in GlorietaMalla.tris_sup:
		var tv: PackedVector3Array = sup
		for t in range(0, tv.size() - 2, 3):
			_triangulo(tv[t], tv[t + 1], tv[t + 2])
	print("Mundo: pasillo de carreteras con %d segmentos y %d triángulos en %d ms" % [segmentos, tri.size() / 9, Time.get_ticks_msec() - t0])


func _polilinea(pts: PackedVector3Array, anchos: PackedFloat32Array, valido: PackedByteArray, ancho_fijo: float) -> void:
	var n := pts.size()
	var i := 0
	while i < n - 1:
		if valido[i] == 0:
			i += 1
			continue
		var j := i
		var h := 0.0
		while j < n - 1 and j - i < PASO_DECIMADO and valido[j + 1] == 1:
			j += 1
		if j == i:
			i += 1
			continue
		for k in range(i, j + 1):
			h = maxf(h, (anchos[k] if ancho_fijo <= 0.0 else ancho_fijo) * 0.5)
		_segmento(pts[i], pts[j], h)
		i = j


func _segmento(p: Vector3, q: Vector3, h: float) -> void:
	var k := ax.size()
	ax.append(p.x); az.append(p.z); ay.append(p.y)
	bx.append(q.x); bz.append(q.z); by.append(q.y)
	hw.append(h)
	segmentos += 1
	var m := h + RI_MAX + W_MAX
	for cx in range(floori((minf(p.x, q.x) - m) / CELDA), floori((maxf(p.x, q.x) + m) / CELDA) + 1):
		for cz in range(floori((minf(p.z, q.z) - m) / CELDA), floori((maxf(p.z, q.z) + m) / CELDA) + 1):
			var c := Vector2i(cx, cz)
			if not celdas.has(c):
				celdas[c] = PackedInt32Array()
			celdas[c].append(k)


func _triangulo(a: Vector3, b: Vector3, c: Vector3) -> void:
	var k := tri.size() / 9
	tri.append_array(PackedFloat32Array([a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z]))
	for cx in range(floori(minf(a.x, minf(b.x, c.x)) / CELDA), floori(maxf(a.x, maxf(b.x, c.x)) / CELDA) + 1):
		for cz in range(floori(minf(a.z, minf(b.z, c.z)) / CELDA), floori(maxf(a.z, maxf(b.z, c.z)) / CELDA) + 1):
			var cc := Vector2i(cx, cz)
			if not celdas_t.has(cc):
				celdas_t[cc] = PackedInt32Array()
			celdas_t[cc].append(k)


## Vector2(e, rasante): e = distancia (m) más allá del borde de la calzada más cercana (negativa dentro), INF si no
## hay ninguna cerca
func consultar(x: float, z: float) -> Vector2:
	var c := Vector2i(floori(x / CELDA), floori(z / CELDA))
	var mejor := INF
	var hr := 0.0
	var lt: PackedInt32Array = celdas_t.get(c, PackedInt32Array())
	for k in lt:
		var q := k * 9
		var v0x := tri[q + 3] - tri[q]; var v0z := tri[q + 5] - tri[q + 2]
		var v1x := tri[q + 6] - tri[q]; var v1z := tri[q + 8] - tri[q + 2]
		var v2x := x - tri[q]; var v2z := z - tri[q + 2]
		var den := v0x * v1z - v1x * v0z
		if absf(den) < 1e-6:
			continue
		var u := (v2x * v1z - v1x * v2z) / den
		var v := (v0x * v2z - v2x * v0z) / den
		if u >= 0.0 and v >= 0.0 and u + v <= 1.0:
			return Vector2(-1.0, tri[q + 1] + u * (tri[q + 4] - tri[q + 1]) + v * (tri[q + 7] - tri[q + 1]))
	var lista: PackedInt32Array = celdas.get(c, PackedInt32Array())
	for k in lista:
		var dx := bx[k] - ax[k]
		var dz := bz[k] - az[k]
		var l2 := dx * dx + dz * dz
		var t := 0.0
		if l2 > 1e-6:
			t = clampf(((x - ax[k]) * dx + (z - az[k]) * dz) / l2, 0.0, 1.0)
		var px := ax[k] + dx * t - x
		var pz := az[k] + dz * t - z
		var e := sqrt(px * px + pz * pz) - hw[k]
		if e < mejor:
			mejor = e
			hr = ay[k] + (by[k] - ay[k]) * t
	return Vector2(mejor, hr)


## Altura graduada de un punto con altura natural h0, para una malla con vértices cada `paso` m.
## Devuelve Vector2(altura, arcen) con arcen = 1 junto a la calzada (el shader pone ahí tierra/grava en vez de la
## foto, que trae la carretera real pintada y no siempre coincide al metro con la nuestra), 0 lejos.
func graduar(h0: float, x: float, z: float, paso: float) -> Vector2:
	var q := consultar(x, z)
	if q.x == INF:
		return Vector2(h0, 0.0)
	var e := q.x
	var hb := q.y - BAJO_ASFALTO
	var ri := clampf(paso * 0.6, 0.6, RI_MAX)
	var w := clampf(absf(h0 - hb) * 1.5 + 2.0, 3.0, W_MAX)
	var h := h0
	if e <= ri:
		h = hb
	elif e < ri + w:
		var t := (e - ri) / w
		h = lerpf(hb, h0, t * t * (3.0 - 2.0 * t))
	return Vector2(h, 1.0 - smoothstep(1.0, 3.2, e))
