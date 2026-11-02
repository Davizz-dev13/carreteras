## Superficie por la que se circula: calzadas (rutas y vías) indexadas en una rejilla espacial.
## Devuelve la altura exacta de la carretera bajo un punto (o la del terreno si no hay carretera).
class_name Superficie
extends RefCounted

const CELDA := 40.0
var a := PackedVector3Array()
var b := PackedVector3Array()
var semiancho := PackedFloat32Array()
var via := PackedInt32Array()           # índice de nombre
var nombres := PackedStringArray()
var celdas := {}                        # Vector2i -> PackedInt32Array


func construir(rutas: Array[Ruta], vias: Array) -> void:
	for r in rutas:
		var id := nombres.size()
		nombres.append(" / ".join(r.refs) + ("  ·  " + r.calle if r.calle != "" else ""))
		for i in r.n - 1:
			if r.dibujar[i] == 1 and r.tunel[i] == 0:
				_anadir(r.pts[i], r.pts[i + 1], r.ancho[i] * 0.5, id)
	for v in vias:
		if v["tunel"] == 1:
			continue
		var id := nombres.size()
		nombres.append(v["nombre"])
		var p: PackedVector3Array = v["pts"]
		for i in p.size() - 1:
			_anadir(p[i], p[i + 1], v["ancho"] * 0.5, id)
	# glorietas: el anillo entero, con la anchura de la glorieta tipo (sus trozos de OSM ya no se dibujan)
	for g in Ajustes.glorietas:
		var inf := GlorietaTipo.info(g)
		if not inf["ok"]:
			continue
		var id := nombres.size()
		nombres.append("Glorieta")
		var xs: Array = g["x"]
		var m := xs.size()
		for i in m:
			var j := (i + 1) % m
			_anadir(Vector3(float(xs[i]), float(g["y"][i]), float(g["z"][i])), Vector3(float(xs[j]), float(g["y"][j]), float(g["z"][j])),
					float(inf["hw"]) + GlorietaTipo.BORDE_EXTRA, id)


func _anadir(p: Vector3, q: Vector3, hw: float, id: int) -> void:
	var k := a.size()
	a.append(p)
	b.append(q)
	semiancho.append(hw)
	via.append(id)
	var m := hw + 1.5
	for cx in range(floori((minf(p.x, q.x) - m) / CELDA), floori((maxf(p.x, q.x) + m) / CELDA) + 1):
		for cz in range(floori((minf(p.z, q.z) - m) / CELDA), floori((maxf(p.z, q.z) + m) / CELDA) + 1):
			var c := Vector2i(cx, cz)
			if not celdas.has(c):
				celdas[c] = PackedInt32Array()
			celdas[c].append(k)


## Devuelve Vector3(altura, en_carretera (0/1), índice de nombre o -1).
## Se elige la calzada MÁS CERCANA EN PLANTA (no la de altura más parecida: eso hacía saltar la altura
## entre tramos vecinos y era la causa de la vibración de la v1). y_ref solo sirve para distinguir
## niveles distintos (paso elevado / puente sobre otra carretera): un tramo a más de 2,5 m de altura
## de y_ref se considera otro nivel y solo se usa si no hay ninguno en el nivel actual.
func consultar(x: float, z: float, y_ref: float) -> Vector3:
	var lista: PackedInt32Array = celdas.get(Vector2i(floori(x / CELDA), floori(z / CELDA)), PackedInt32Array())
	var mejor := 1e9
	var h := 0.0
	var id := -1
	for k in lista:
		var p := a[k]
		var q := b[k]
		var abx := q.x - p.x
		var abz := q.z - p.z
		var l2 := abx * abx + abz * abz
		if l2 < 1e-6:
			continue
		var t := clampf(((x - p.x) * abx + (z - p.z) * abz) / l2, 0.0, 1.0)
		var cx := p.x + abx * t
		var cz := p.z + abz * t
		var d := sqrt((x - cx) * (x - cx) + (z - cz) * (z - cz))
		if d <= semiancho[k] + 1.2:
			var hh := lerpf(p.y, q.y, t)
			var puntos := d + (1000.0 if absf(hh - y_ref) > 2.5 else 0.0)
			if puntos < mejor:
				mejor = puntos
				h = hh
				id = via[k]
	if id >= 0:
		return Vector3(h, 1.0, id)
	return Vector3(Ajustes.altura_terreno(x, z), 0.0, -1)
