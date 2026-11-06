## Superficie por la que se circula: calzadas (rutas y vías) indexadas en una rejilla espacial.
## Devuelve la altura exacta de la carretera bajo un punto (o la del terreno si no hay carretera).
class_name Superficie
extends RefCounted

const CELDA := 40.0
const SUBIDA_MAX := 0.6      # m por encima de y_ref que puede estar la calzada "de arriba" de un solape (v7)
var a := PackedVector3Array()
var b := PackedVector3Array()
var semiancho := PackedFloat32Array()
var via := PackedInt32Array()           # índice de nombre
var nombres := PackedStringArray()
var celdas := {}                        # Vector2i -> PackedInt32Array
var ta := PackedVector3Array()          # triángulos de las glorietas (GlorietaMalla)
var tb := PackedVector3Array()
var tc := PackedVector3Array()
var tid := PackedInt32Array()
var celdas_t := {}


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
		if v.get("gemela", false):
			# calzada gemela de la ruta junto a una glorieta (GlorietaTipo): solo el trozo que se dibuja
			if v.get("oculta_glorieta", false):
				continue
			p = v.get("pts_dib", p)
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


	# glorietas en una sola malla (GlorietaMalla): sus triángulos (brazos ensanchados y abocinamientos, fuera del anillo)
	for sup in GlorietaMalla.tris_sup:
		var id := nombres.size()
		nombres.append("Glorieta")
		var tv: PackedVector3Array = sup
		for t in range(0, tv.size(), 3):
			var k := ta.size()
			ta.append(tv[t])
			tb.append(tv[t + 1])
			tc.append(tv[t + 2])
			tid.append(id)
			var mn := Vector2(minf(tv[t].x, minf(tv[t + 1].x, tv[t + 2].x)), minf(tv[t].z, minf(tv[t + 1].z, tv[t + 2].z)))
			var mx := Vector2(maxf(tv[t].x, maxf(tv[t + 1].x, tv[t + 2].x)), maxf(tv[t].z, maxf(tv[t + 1].z, tv[t + 2].z)))
			for cx in range(floori(mn.x / CELDA), floori(mx.x / CELDA) + 1):
				for cz in range(floori(mn.y / CELDA), floori(mx.y / CELDA) + 1):
					var c := Vector2i(cx, cz)
					if not celdas_t.has(c):
						celdas_t[c] = PackedInt32Array()
					celdas_t[c].append(k)


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
	# v7: donde dos calzadas se solapan (calzada gemela de una autovía, boca de un cruce, ramal que se funde) y el
	# punto está DENTRO de las dos, manda la de arriba, que es la que se ve: la más cercana en planta podía ser la de
	# debajo (hasta 1 m por debajo del asfalto visible en la M-406) y el coche se hundía o daba un escalón al pasar
	# de una a otra. El máximo de alturas continuas es continuo, así que no vuelve la vibración de la v1.
	var h_dentro := -INF
	var id_dentro := -1
	var por_via := {}      # via -> Vector2(distancia del tramo más cercano de esa calzada, su altura)
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
			var otro_nivel := absf(hh - y_ref) > 2.5
			# de cada calzada solo cuenta su tramo más cercano (si no, en pendiente un tramo 3 m más adelante de la
			# misma carretera también "contiene" el punto por su extremo y daría su altura, más alta)
			# (un tablero más de SUBIDA_MAX por encima del coche no es "la de arriba" sino otro nivel mal medido: puente
			# de OSM demasiado bajo; el coche no se sube a él de golpe)
			if d <= semiancho[k] and not otro_nivel and hh - y_ref <= SUBIDA_MAX:
				var pv: Vector2 = por_via.get(via[k], Vector2(1e9, 0.0))
				if d < pv.x:
					por_via[via[k]] = Vector2(d, hh)
			var puntos := d + (1000.0 if otro_nivel else 0.0)
			if puntos < mejor:
				mejor = puntos
				h = hh
				id = via[k]
	for v in por_via:
		var pv: Vector2 = por_via[v]
		if pv.y > h_dentro:
			h_dentro = pv.y
			id_dentro = v
	# dentro de un triángulo de la malla de una glorieta (abocinamientos, isleta): altura por baricéntricas; también
	# compite con las calzadas que lo contienen (la malla se dibuja ELEV por encima: es la que se ve)
	var h_tri := -INF
	var id_tri := -1
	var h_tri_lejos := 0.0
	var id_tri_lejos := -1
	for k in celdas_t.get(Vector2i(floori(x / CELDA), floori(z / CELDA)), PackedInt32Array()):
		var a3 := ta[k]
		var b3 := tb[k]
		var c3 := tc[k]
		var det := (b3.z - c3.z) * (a3.x - c3.x) + (c3.x - b3.x) * (a3.z - c3.z)
		if absf(det) < 1e-6:
			continue
		var l1 := ((b3.z - c3.z) * (x - c3.x) + (c3.x - b3.x) * (z - c3.z)) / det
		var l2 := ((c3.z - a3.z) * (x - c3.x) + (a3.x - c3.x) * (z - c3.z)) / det
		var l3 := 1.0 - l1 - l2
		if l1 >= -0.01 and l2 >= -0.01 and l3 >= -0.01:
			var hh := a3.y * l1 + b3.y * l2 + c3.y * l3 - GlorietaMalla.ELEV
			if absf(hh - y_ref) < 2.5:
				if hh - y_ref <= SUBIDA_MAX and hh > h_tri:
					h_tri = hh
					id_tri = tid[k]
				elif id_tri_lejos < 0:
					h_tri_lejos = hh
					id_tri_lejos = tid[k]
	if id_dentro >= 0 or id_tri >= 0:
		if h_tri > h_dentro:
			return Vector3(h_tri, 1.0, id_tri)
		return Vector3(h_dentro, 1.0, id_dentro)
	if id >= 0:
		return Vector3(h, 1.0, id)
	if id_tri_lejos >= 0:
		return Vector3(h_tri_lejos, 1.0, id_tri_lejos)
	return Vector3(Ajustes.altura_terreno(x, z), 0.0, -1)
