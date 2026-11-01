## Cruces y terreno: deja limpias las intersecciones al cargar el mapa.
## 1) Una calzada secundaria (otra ruta posterior o una vía de OSM) que entra en otra ya dibujada se corta donde
##    queda entera bajo la principal; donde la pisa solo en parte (boca oblicua, cuña de un ramal) se pega 3 cm
##    por debajo de la principal, y su altura se funde con la de la principal (antes se pintaban dos asfaltos
##    casi a la misma altura uno encima del otro y parpadeaban, o la secundaria quedaba metros por encima).
##    Las calzadas terminan en borde recto: la vía que sigue a otra en el mismo nodo de OSM no se recorta.
## 2) El terreno (malla de 20 m) se hunde lo justo bajo cada calzada para que nunca asome por encima del asfalto.
## 3) Glorietas y nodos: donde se juntan los extremos de dos o más calzadas (los trozos del anillo de una glorieta,
##    una vía que OSM parte en dos, una entrada que llega a un nodo del anillo) cada calzada termina en borde recto
##    perpendicular a su propio eje, y si cambian de dirección queda una muesca sin asfalto en el lado de fuera.
##    En cada nodo así se pone un disco de asfalto (radio = el semiancho más estrecho de las que se juntan, así
##    nunca sale de la carretera), 3 cm por debajo de la calzada más baja en cada punto: solo se ve en la muesca.
## Todo en una sola pasada, en la carga (unas décimas de segundo); no cambia los ficheros de datos.
class_name Cruces
extends RefCounted

const CELDA := 40.0
const BAJO := 0.03            # el final de la secundaria queda 3 cm por debajo de la principal
const MAX_DESNIVEL := 6.0     # más desnivel que esto = otro nivel (paso elevado): no es un cruce
const HOLGURA := 0.15         # margen lateral extra al decidir si dos calzadas se solapan
const MARGEN_TERRENO := 0.25  # el terreno queda al menos 25 cm por debajo del asfalto
const ARCEN_TERRENO := 0.8    # ... también 80 cm más allá de cada borde (ahí empieza el talud)
const PARCHE_LADOS := 24      # disco de los nodos: polígono de 24 lados
const PARCHE_BAJO := 0.03     # ... 3 cm por debajo de la calzada más baja que lo pisa
const PARCHE_UNIR := 0.75     # extremos a menos de esto = el mismo nodo

## Discos de asfalto de los nodos (los dibuja MapaStreaming): [{"c": Vector3, "borde": PackedVector3Array, "ruta": bool}]
## y anillos de las glorietas: los mismos campos más "interior" (borde de dentro; se dibujan como banda, no abanico)
static var parches: Array = []

var sa := PackedVector3Array()
var sb := PackedVector3Array()
var shw := PackedFloat32Array()
var celdas := {}
var extremos := {}           # Vector2i (celda de 4 m) -> [Vector3]: extremos de las calzadas ya colocadas
var stats := {"cortes": 0, "trozos_ruta_ocultos": 0, "vias_partidas": 0, "extremos_pegados": 0, "parches": 0, "anillos": 0}


static func preparar(rutas: Array, vias: Array) -> Dictionary:
	var c := Cruces.new()
	var t0 := Time.get_ticks_msec()
	parches = []
	var nodos := c._nodos_originales(rutas, vias)
	for ri in rutas.size():
		c._procesar_ruta(rutas[ri])
	c.stats["ms_rutas"] = Time.get_ticks_msec() - t0
	var nuevas := c._procesar_vias(vias)
	vias.clear()
	vias.append_array(nuevas)
	c.stats["ms_vias"] = Time.get_ticks_msec() - t0
	c._parches(nodos)
	c._anillos(Ajustes.glorietas)
	c._excavar_terreno(rutas, vias)
	c.stats["ms"] = Time.get_ticks_msec() - t0
	return c.stats


# ---------------- rejilla de calzadas ya colocadas ----------------
func _anadir(p: Vector3, q: Vector3, hw: float) -> void:
	var k := sa.size()
	sa.append(p)
	sb.append(q)
	shw.append(hw)
	var m := hw + 6.0
	for cx in range(floori((minf(p.x, q.x) - m) / CELDA), floori((maxf(p.x, q.x) + m) / CELDA) + 1):
		for cz in range(floori((minf(p.z, q.z) - m) / CELDA), floori((maxf(p.z, q.z) + m) / CELDA) + 1):
			var cl := Vector2i(cx, cz)
			if not celdas.has(cl):
				celdas[cl] = PackedInt32Array()
			celdas[cl].append(k)


## Solape de una sección transversal (centro p, tangente horizontal t, semiancho hw) con lo ya colocado.
## Devuelve Vector2(solape en m (>0 = se pisan), altura de la principal en ese punto).
func _solape(p: Vector3, t: Vector3, hw: float) -> Vector2:
	var lista: PackedInt32Array = celdas.get(Vector2i(floori(p.x / CELDA), floori(p.z / CELDA)), PackedInt32Array())
	var mejor := -1e9
	var h := 0.0
	for k in lista:
		var a := sa[k]
		var b := sb[k]
		var abx := b.x - a.x
		var abz := b.z - a.z
		var l2 := abx * abx + abz * abz
		if l2 < 1e-6:
			continue
		var l := sqrt(l2)
		var paralelo := absf((t.x * abx + t.z * abz) / l)
		var ur := ((p.x - a.x) * abx + (p.z - a.z) * abz) / l2
		if ur < 0.0 or ur > 1.0:
			# más allá del extremo del tramo: la calzada termina en un borde recto (no redondo). Una que sigue
			# a continuación (otra vía de OSM partida en ese nodo) no la pisa: antes se cortaba hw + hw' ≈ 7 m
			# y quedaba un agujero en cada nodo donde OSM parte una vía.
			var e := (-ur if ur < 0.0 else ur - 1.0) * l
			if e >= hw * sqrt(maxf(0.0, 1.0 - paralelo * paralelo)) + HOLGURA:
				continue
		var u := clampf(ur, 0.0, 1.0)
		var d := absf((p.x - a.x) * abz - (p.z - a.z) * abx) / l   # distancia lateral al eje del tramo
		if d >= shw[k] + hw + HOLGURA:
			continue
		var hh := a.y + (b.y - a.y) * u
		if absf(hh - p.y) > MAX_DESNIVEL:
			continue
		var s := shw[k] + hw * paralelo + HOLGURA - d
		if s > mejor:
			mejor = s
			h = hh
	return Vector2(mejor, h)


## ¿Está el punto (x, z) dentro de alguna calzada ya colocada (al mismo nivel, ±MAX_DESNIVEL de y)?
func _dentro(x: float, z: float, y: float) -> bool:
	var lista: PackedInt32Array = celdas.get(Vector2i(floori(x / CELDA), floori(z / CELDA)), PackedInt32Array())
	for k in lista:
		var a := sa[k]
		var b := sb[k]
		var abx := b.x - a.x
		var abz := b.z - a.z
		var l2 := abx * abx + abz * abz
		if l2 < 1e-6:
			continue
		var ur := ((x - a.x) * abx + (z - a.z) * abz) / l2
		if ur < -0.02 or ur > 1.02:
			continue
		var u := clampf(ur, 0.0, 1.0)
		var ex := x - a.x - abx * u
		var ez := z - a.z - abz * u
		var r := shw[k] - 0.05
		if ex * ex + ez * ez <= r * r and absf(a.y + (b.y - a.y) * u - y) <= MAX_DESNIVEL:
			return true
	return false


## La sección transversal entera (eje y los dos bordes) queda bajo calzadas ya colocadas: ahí la vía sobra.
## Se mira la sección entera cada 30 cm (antes solo 3 puntos: eje y bordes): con 3, una sección cuyo eje cae en una
## calzada y los bordes en otra se daba por tapada aunque entre medias no hubiera asfalto (triángulos en cruces en Y,
## tiras sin asfalto entre dos calzadas paralelas que casi se tocan).
func _todo_dentro(p: Vector3, t: Vector3, hw: float) -> bool:
	var der := Vector3(-t.z, 0.0, t.x)
	if not _dentro(p.x, p.z, p.y) or not _dentro(p.x + der.x * hw, p.z + der.z * hw, p.y) \
			or not _dentro(p.x - der.x * hw, p.z - der.z * hw, p.y):
		return false
	var m := ceili(hw / 0.3)
	for k in range(1, m):
		var e := hw * k / m
		if not _dentro(p.x + der.x * e, p.z + der.z * e, p.y) or not _dentro(p.x - der.x * e, p.z - der.z * e, p.y):
			return false
	return true


static func _tan(pts: PackedVector3Array, i: int) -> Vector3:
	var t := pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]
	t.y = 0.0
	return t.normalized()


## Funde la altura de pts hacia atrás desde el índice i0 (en el sentido dir = -1/+1) para absorber 'delta'.
static func _fundir(pts: PackedVector3Array, i0: int, dir: int, delta: float) -> void:
	var largo := clampf(absf(delta) / 0.06, 16.0, 120.0)   # como mucho un 6 % de pendiente añadida
	var acum := 0.0
	var i := i0
	while i >= 0 and i < pts.size():
		if i != i0:
			acum += Vector2(pts[i].x - pts[i - dir].x, pts[i].z - pts[i - dir].z).length()
		if acum >= largo:
			break
		var f := 1.0 - acum / largo
		pts[i].y += delta * f * f * (3.0 - 2.0 * f)
		i += dir


# ---------------- rutas (en orden: la primera manda) ----------------
func _procesar_ruta(r: Ruta) -> void:
	var dentro := PackedByteArray()
	dentro.resize(r.n)
	var hprin := PackedFloat32Array()
	hprin.resize(r.n)
	var lleno := PackedByteArray()
	lleno.resize(r.n)
	var hay := false
	for i in r.n:
		if r.puente[i] == 1 or r.tunel[i] == 1:
			continue
		var usado := (i < r.n - 1 and r.dibujar[i] == 1) or (i > 0 and r.dibujar[i - 1] == 1)
		if not usado:
			continue
		var s := _solape(r.pts[i], r.tang[i], r.ancho[i] * 0.5)
		if s.x > 0.0:
			dentro[i] = 1
			hprin[i] = s.y
			hay = true
			if _todo_dentro(r.pts[i], r.tang[i], r.ancho[i] * 0.5):
				lleno[i] = 1
	r.bajo = dentro
	if hay:
		var pts := r.pts
		for i in r.n - 1:
			# solo se esconde el tramo que queda entero bajo otra calzada (antes bastaba con que la pisara: una ruta
			# que empieza en un cruce con otra perdía sus primeros metros y quedaba un hueco en la boca del cruce)
			if r.dibujar[i] == 1 and lleno[i] == 1 and lleno[i + 1] == 1 \
					and _todo_dentro(r.pts[i].lerp(r.pts[i + 1], 0.5), r.tang[i], r.ancho[i] * 0.5):
				r.dibujar[i] = 0
				stats["trozos_ruta_ocultos"] += 1
		# alturas: dentro de la principal, la de la principal; en la frontera, fundido suave
		for i in r.n:
			if dentro[i] == 1:
				var delta := hprin[i] - BAJO - pts[i].y
				var izq := i > 0 and dentro[i - 1] == 0
				var der := i < r.n - 1 and dentro[i + 1] == 0
				pts[i].y += delta
				if izq:
					_fundir(pts, i - 1, -1, delta)
					stats["cortes"] += 1
				if der:
					_fundir(pts, i + 1, 1, delta)
					stats["cortes"] += 1
		r.pts = pts
		for i in r.n:
			r.tang[i] = (r.pts[mini(i + 1, r.n - 1)] - r.pts[maxi(i - 1, 0)]).normalized()
	for i in r.n - 1:
		if r.dibujar[i] == 1 and r.tunel[i] == 0:
			_anadir(r.pts[i], r.pts[i + 1], r.ancho[i] * 0.5)
	if r.n >= 2:
		_registrar_extremos(r.pts)


# ---------------- vías de OSM (las más anchas mandan) ----------------
func _procesar_vias(vias: Array) -> Array:
	var orden := range(vias.size())
	orden.sort_custom(func(x, y): return float(vias[x]["ancho"]) > float(vias[y]["ancho"]) or (float(vias[x]["ancho"]) == float(vias[y]["ancho"]) and x < y))
	var salida := []
	for vi in orden:
		var v: Dictionary = vias[vi]
		var pts: PackedVector3Array = v["pts"]
		var hw := float(v["ancho"]) * 0.5
		if pts.size() < 2 or int(v.get("tunel", 0)) == 1 or int(v.get("puente", 0)) == 1:
			if pts.size() >= 2 and int(v.get("tunel", 0)) == 0:
				var pisa_p := PackedByteArray()
				pisa_p.resize(pts.size())
				_pegar_extremos(pts, pisa_p)
				v["pts"] = pts
				for i in pts.size() - 1:
					_anadir(pts[i], pts[i + 1], hw)
				_registrar_extremos(pts)
			salida.append(v)
			continue
		var n := pts.size()
		var sol := PackedFloat32Array()
		var hp := PackedFloat32Array()
		sol.resize(n)
		hp.resize(n)
		var algun := false
		for i in n:
			var s := _solape(pts[i], _tan(pts, i), hw)
			sol[i] = s.x
			hp[i] = s.y
			if s.x > 0.0:
				algun = true
		if not algun:
			var pisa0 := PackedByteArray()
			pisa0.resize(n)
			_pegar_extremos(pts, pisa0)
			v["pts"] = pts
			salida.append(v)
			for i in n - 1:
				_anadir(pts[i], pts[i + 1], hw)
			_registrar_extremos(pts)
			continue
		# La vía solo sobra donde su sección entera queda bajo calzadas ya colocadas. Donde las pisa solo en parte
		# (boca de un cruce oblicuo, cuña de un ramal de entrada/salida, calzadas que se solapan) se dibuja igual,
		# a la altura de la otra menos BAJO (queda justo debajo: ni parpadeo ni agujero), y se funde al salir.
		# Antes se cortaba en cuanto tocaba el borde: quedaban triángulos sin asfalto en las bocas y en los ramales.
		var lleno := PackedByteArray()
		lleno.resize(n)
		for i in n:
			if sol[i] > 0.0 and _todo_dentro(pts[i], _tan(pts, i), hw):
				lleno[i] = 1
		# un tramo entre dos secciones tapadas solo sobra si también está tapado por en medio
		var ll2 := lleno.duplicate()
		for i in n - 1:
			if lleno[i] == 1 and lleno[i + 1] == 1:
				var tm := Vector3(pts[i + 1].x - pts[i].x, 0.0, pts[i + 1].z - pts[i].z).normalized()
				for f in [0.25, 0.5, 0.75]:
					if not _todo_dentro(pts[i].lerp(pts[i + 1], f), tm, hw):
						ll2[i] = 0
						ll2[i + 1] = 0
						break
		lleno = ll2
		var piezas := 0
		var i := 0
		while i < n:
			if lleno[i] == 1:
				i += 1
				continue
			var j := i
			while j + 1 < n and lleno[j + 1] == 0:
				j += 1
			var trozo := PackedVector3Array()
			var orig := PackedFloat32Array()
			var pisa := PackedByteArray()
			if i > 0:
				var c := _borde_lleno(pts[i], pts[i - 1], hw)
				trozo.append(c)
				orig.append(_alt_original(pts, i, i - 1, c))
				pisa.append(1)
			for k in range(i, j + 1):
				var q := pts[k]
				orig.append(q.y)
				pisa.append(1 if sol[k] > 0.0 else 0)
				if sol[k] > 0.0:
					q.y = _altura_pegada(q, _tan(pts, k), hw, hp[k])
				trozo.append(q)
			if j < n - 1:
				var c2 := _borde_lleno(pts[j], pts[j + 1], hw)
				trozo.append(c2)
				orig.append(_alt_original(pts, j, j + 1, c2))
				pisa.append(1)
			# fundido de altura en cada paso de "pisa otra calzada" a "libre" (y al revés)
			for k in range(1, trozo.size()):
				if pisa[k - 1] == 1 and pisa[k] == 0:
					_fundir_libre(trozo, pisa, k, 1, trozo[k - 1].y - orig[k - 1])
					stats["cortes"] += 1
				elif pisa[k - 1] == 0 and pisa[k] == 1:
					_fundir_libre(trozo, pisa, k - 1, -1, trozo[k].y - orig[k])
					stats["cortes"] += 1
			if trozo.size() >= 2:
				_pegar_extremos(trozo, pisa)
				var nv := v.duplicate()
				nv["pts"] = trozo
				salida.append(nv)
				piezas += 1
				for k in trozo.size() - 1:
					_anadir(trozo[k], trozo[k + 1], hw)
				_registrar_extremos(trozo)
			i = j + 1
		if piezas > 1:
			stats["vias_partidas"] += 1
	return salida


## Altura a la que se pega una sección que pisa otra calzada: la más baja de esa calzada bajo el eje y los dos
## bordes de la sección, menos BAJO. Con solo la del eje, en un cruce oblicuo sobre una carretera en pendiente un
## borde de la secundaria asomaba por encima del asfalto de la principal.
func _altura_pegada(p: Vector3, t: Vector3, hw: float, h_eje: float) -> float:
	var der := Vector3(-t.z, 0.0, t.x) * hw
	var h := h_eje
	for q in [p, p + der, p - der]:
		var lista: PackedInt32Array = celdas.get(Vector2i(floori(q.x / CELDA), floori(q.z / CELDA)), PackedInt32Array())
		for k in lista:
			var a := sa[k]
			var b := sb[k]
			var abx := b.x - a.x
			var abz := b.z - a.z
			var l2 := abx * abx + abz * abz
			if l2 < 1e-6:
				continue
			var u := clampf(((q.x - a.x) * abx + (q.z - a.z) * abz) / l2, 0.0, 1.0)
			var ex: float = q.x - a.x - abx * u
			var ez: float = q.z - a.z - abz * u
			var hh := a.y + (b.y - a.y) * u
			if ex * ex + ez * ez <= shw[k] * shw[k] and absf(hh - h_eje) <= 1.5:
				h = minf(h, hh)
	return h - BAJO


## Extremos de calzada: donde OSM parte una vía en dos, cada trozo trae su propia altura (cada uno se suaviza por
## separado) y en el nodo común quedaba un escalón de decenas de cm. El extremo de la vía que llega después se
## pega a la altura del extremo ya colocado y se funde hacia dentro.
func _registrar_extremos(pts: PackedVector3Array) -> void:
	for p in [pts[0], pts[pts.size() - 1]]:
		var c := Vector2i(floori(p.x / 4.0), floori(p.z / 4.0))
		if not extremos.has(c):
			extremos[c] = []
		extremos[c].append(p)


func _pegar_extremos(pts: PackedVector3Array, pisa: PackedByteArray) -> void:
	for lado in [0, 1]:
		var i0: int = 0 if lado == 0 else pts.size() - 1
		if pisa[i0] == 1:
			continue
		var p := pts[i0]
		var mejor := 0.75
		var y := 0.0
		var hay := false
		var c := Vector2i(floori(p.x / 4.0), floori(p.z / 4.0))
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				for e in extremos.get(c + Vector2i(dx, dz), []):
					var d := Vector2(e.x - p.x, e.z - p.z).length()
					if d < mejor and absf(e.y - p.y) <= MAX_DESNIVEL:
						mejor = d
						y = e.y
						hay = true
		if hay and absf(y - p.y) > 0.005:
			_fundir_libre(pts, pisa, i0, 1 if lado == 0 else -1, y - p.y)
			stats["extremos_pegados"] += 1


## Punto del segmento fuera→dentro (bisección) a partir del cual la sección entera queda bajo otra calzada.
## La altura es la de esa calzada menos BAJO.
func _borde_lleno(fuera: Vector3, dentro: Vector3, hw: float) -> Vector3:
	var t := Vector3(dentro.x - fuera.x, 0.0, dentro.z - fuera.z).normalized()
	var lo := 0.0
	var hi := 1.0
	for _k in 10:
		var m := (lo + hi) * 0.5
		if _todo_dentro(fuera.lerp(dentro, m), t, hw):
			hi = m
		else:
			lo = m
	var p := fuera.lerp(dentro, hi)
	var s := _solape(p, t, hw)
	return Vector3(p.x, _altura_pegada(p, t, hw, s.y) if s.x > 0.0 else p.y, p.z)


## Como _fundir, pero sin tocar los vértices que ya van pegados a otra calzada (pisa = 1).
static func _fundir_libre(pts: PackedVector3Array, pisa: PackedByteArray, i0: int, dir: int, delta: float) -> void:
	var largo := clampf(absf(delta) / 0.06, 16.0, 120.0)
	var acum := 0.0
	var i := i0
	while i >= 0 and i < pts.size() and pisa[i] == 0:
		if i != i0:
			acum += Vector2(pts[i].x - pts[i - dir].x, pts[i].z - pts[i - dir].z).length()
		if acum >= largo:
			break
		var f := 1.0 - acum / largo
		pts[i].y += delta * f * f * (3.0 - 2.0 * f)
		i += dir


static func _alt_original(pts: PackedVector3Array, a: int, b: int, c: Vector3) -> float:
	var l := Vector2(pts[b].x - pts[a].x, pts[b].z - pts[a].z).length()
	if l < 1e-4:
		return pts[a].y
	var u := clampf(Vector2(c.x - pts[a].x, c.z - pts[a].z).length() / l, 0.0, 1.0)
	return lerpf(pts[a].y, pts[b].y, u)


# ---------------- nodos: discos que tapan las muescas ----------------
## Extremos de todas las calzadas tal como vienen (antes de cortar nada), agrupados por nodo.
func _nodos_originales(rutas: Array, vias: Array) -> Array:
	var ext := []
	for rr in rutas:
		var r: Ruta = rr
		if r.n < 2:
			continue
		for i in [0, r.n - 1]:
			if r.tunel[i] == 0:
				ext.append([r.pts[i], r.ancho[i] * 0.5, true, _dir_salida(r.pts, i == 0)])
	for v in vias:
		var pts: PackedVector3Array = v["pts"]
		if pts.size() < 2 or int(v.get("tunel", 0)) == 1:
			continue
		var hw := float(v["ancho"]) * 0.5
		ext.append([pts[0], hw, false, _dir_salida(pts, true)])
		ext.append([pts[pts.size() - 1], hw, false, _dir_salida(pts, false)])
	var rej := {}
	var nodos := []
	for e in ext:
		var p: Vector3 = e[0]
		var cl := Vector2i(floori(p.x / 2.0), floori(p.z / 2.0))
		var hit := -1
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				for ni in rej.get(cl + Vector2i(dx, dz), []):
					var q: Vector3 = nodos[ni]["p"]
					if hit < 0 and Vector2(q.x - p.x, q.z - p.z).length() < PARCHE_UNIR and absf(q.y - p.y) < MAX_DESNIVEL:
						hit = ni
		if hit < 0:
			hit = nodos.size()
			nodos.append({"p": p, "hw": float(e[1]), "n": 0, "ruta": false, "brazos": []})
			if not rej.has(cl):
				rej[cl] = []
			rej[cl].append(hit)
		var nd: Dictionary = nodos[hit]
		nd["n"] = int(nd["n"]) + 1
		nd["hw"] = minf(float(nd["hw"]), float(e[1]))
		nd["ruta"] = bool(nd["ruta"]) or bool(e[2])
		nd["brazos"].append([e[3], float(e[1])])
	# extremo suelto que cae sobre el eje de otra calzada sin partirla (boca en T, trozo de anillo que se apoya en una
	# ruta que recorre media glorieta): esa otra cuenta como dos brazos más, uno hacia cada lado
	var lineas := []     # [pts, semiancho (Array por punto)]
	for rr in rutas:
		var r: Ruta = rr
		if r.n >= 2:
			lineas.append([r.pts, r.ancho, 0.5, r.tunel])
	for v in vias:
		var pts: PackedVector3Array = v["pts"]
		if pts.size() >= 2 and int(v.get("tunel", 0)) == 0:
			lineas.append([pts, float(v["ancho"]), 0.5, null])
	var rej2 := {}
	for li in lineas.size():
		var pts: PackedVector3Array = lineas[li][0]
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			for cx in range(floori((minf(a.x, b.x) - 1.0) / 20.0), floori((maxf(a.x, b.x) + 1.0) / 20.0) + 1):
				for cz in range(floori((minf(a.z, b.z) - 1.0) / 20.0), floori((maxf(a.z, b.z) + 1.0) / 20.0) + 1):
					var k := Vector2i(cx, cz)
					if not rej2.has(k):
						rej2[k] = []
					rej2[k].append(Vector2i(li, i))
	for nd in nodos:
		if int(nd["n"]) != 1:
			continue
		var p: Vector3 = nd["p"]
		var mejor := 1.0
		var hit := Vector2i(-1, -1)
		var uh := 0.0
		for li_i in rej2.get(Vector2i(floori(p.x / 20.0), floori(p.z / 20.0)), []):
			var pts: PackedVector3Array = lineas[li_i.x][0]
			var a := pts[li_i.y]
			var b := pts[li_i.y + 1]
			var abx := b.x - a.x
			var abz := b.z - a.z
			var l2 := abx * abx + abz * abz
			if l2 < 1e-6:
				continue
			var u := clampf(((p.x - a.x) * abx + (p.z - a.z) * abz) / l2, 0.0, 1.0)
			var d := Vector2(p.x - a.x - abx * u, p.z - a.z - abz * u).length()
			# el propio extremo de esa línea no cuenta (sería su mismo nodo, ya agrupado)
			var s: float = li_i.y + u
			if s < 0.05 or s > pts.size() - 1.05:
				continue
			if d < mejor and absf(a.y + (b.y - a.y) * u - p.y) < MAX_DESNIVEL:
				mejor = d
				hit = li_i
				uh = u
		if hit.x < 0:
			continue
		var pts: PackedVector3Array = lineas[hit.x][0]
		var anc = lineas[hit.x][1]
		var tun = lineas[hit.x][3]
		if tun != null and (tun[hit.y] == 1 or tun[hit.y + 1] == 1):
			continue
		var hw2: float = (float(anc[hit.y]) if anc is PackedFloat32Array else float(anc)) * 0.5
		var dd := Vector2(pts[hit.y + 1].x - pts[hit.y].x, pts[hit.y + 1].z - pts[hit.y].z).normalized()
		nd["n"] = 2
		nd["hw"] = minf(float(nd["hw"]), hw2)
		nd["brazos"].append([dd, hw2])
		nd["brazos"].append([-dd, hw2])
		if tun != null:
			nd["ruta"] = true
	return nodos


## Dirección (horizontal, unitaria) en la que la calzada sale de su extremo: hacia el punto a ~4 m por el eje.
static func _dir_salida(pts: PackedVector3Array, desde_ini: bool) -> Vector2:
	var n := pts.size()
	var i0 := 0 if desde_ini else n - 1
	var paso := 1 if desde_ini else -1
	var p0 := pts[i0]
	var i := i0 + paso
	while i > 0 and i < n - 1 and Vector2(pts[i].x - p0.x, pts[i].z - p0.z).length() < 4.0:
		i += paso
	var d := Vector2(pts[i].x - p0.x, pts[i].z - p0.z)
	return d.normalized() if d.length() > 1e-4 else Vector2.ZERO


## Radio del disco del nodo en la dirección (unitaria) u: hasta donde llega la unión de las calzadas que salen del
## nodo (cada una, recta, con su semiancho), sin pasar del semiancho mayor; hacia atrás de cada una, solo el
## semiancho más estrecho (así no asoma por el otro lado de una calzada estrecha a la que llega otra ancha).
## Hacia atrás de una calzada que sigue en otra (casi opuesta: un empalme, el anillo de una glorieta) se usa su propio
## semiancho: si la que sigue es más estrecha, el escalón de anchura queda redondeado en vez de con una muesca.
static func _radio_parche(u: Vector2, brazos: Array, hw_min: float, hw_max: float) -> float:
	var s := hw_min
	for b in brazos:
		var d: Vector2 = b[0]
		if d == Vector2.ZERO:
			continue
		var c := u.dot(d)
		if c >= 0.0:
			var sn := absf(u.cross(d))
			s = maxf(s, float(b[1]) / sn if sn > 1e-3 else hw_max)
		else:
			for b2 in brazos:
				var d2: Vector2 = b2[0]
				if d2.dot(d) < -0.7:
					s = maxf(s, float(b[1]))
					break
	return minf(s, hw_max)


## Altura del asfalto ya colocado en (x, z) al nivel de y_ref: la de la calzada más baja que pisa el punto;
## si ninguna lo pisa (la muesca), la de la más cercana. NAN si no hay ninguna a menos de 6 m.
func _h_asfalto(x: float, z: float, y_ref: float) -> float:
	var lista: PackedInt32Array = celdas.get(Vector2i(floori(x / CELDA), floori(z / CELDA)), PackedInt32Array())
	var h_dentro := INF
	var h_cerca := NAN
	var d_cerca := 6.0
	for k in lista:
		var a := sa[k]
		var b := sb[k]
		var abx := b.x - a.x
		var abz := b.z - a.z
		var l2 := abx * abx + abz * abz
		if l2 < 1e-6:
			continue
		var u := clampf(((x - a.x) * abx + (z - a.z) * abz) / l2, 0.0, 1.0)
		var hh := a.y + (b.y - a.y) * u
		if absf(hh - y_ref) > 1.5:
			continue
		var d := Vector2(x - a.x - abx * u, z - a.z - abz * u).length() - shw[k]
		if d <= 0.0:
			h_dentro = minf(h_dentro, hh)
		elif d < d_cerca:
			d_cerca = d
			h_cerca = hh
	return h_dentro if h_dentro < INF else h_cerca


func _parches(nodos: Array) -> void:
	for nd in nodos:
		if int(nd["n"]) < 2:
			continue
		var p: Vector3 = nd["p"]
		var r: float = nd["hw"]
		if r < 0.5:
			continue
		var hw_max := 0.0
		for b in nd["brazos"]:
			hw_max = maxf(hw_max, float(b[1]))
		var y0 := _h_asfalto(p.x, p.z, p.y)
		if is_nan(y0):
			continue
		var borde := PackedVector3Array()
		for k in PARCHE_LADOS:
			var ang := TAU * k / PARCHE_LADOS
			var rr := _radio_parche(Vector2(cos(ang), sin(ang)), nd["brazos"], r, hw_max)
			var x := p.x + cos(ang) * rr
			var z := p.z + sin(ang) * rr
			var h := _h_asfalto(x, z, y0)
			borde.append(Vector3(x, (y0 if is_nan(h) else h) - PARCHE_BAJO, z))
		parches.append({"c": Vector3(p.x, y0 - PARCHE_BAJO, p.z), "borde": borde, "ruta": nd["ruta"]})
		stats["parches"] += 1


## Glorietas: un anillo continuo de asfalto por cada eje cerrado de glorieta (pipeline/glorietas_completas.py), 3 cm
## por debajo de los trozos que la forman. Los trozos son tiras rectas que acaban en borde recto: donde se juntan con
## ángulo quedaba una muesca en V por fuera y el borde exterior salía en polígono; el anillo, liso, tapa las dos cosas.
func _anillos(lista: Array) -> void:
	for g in lista:
		var xs: Array = g["x"]
		var ys: Array = g["y"]
		var zs: Array = g["z"]
		var n := xs.size()
		if n < 6:
			continue
		var hw := float(g["hw"])
		if hw < 1.0:
			continue
		var p := PackedVector3Array()
		for i in n:
			p.append(Vector3(float(xs[i]), float(ys[i]), float(zs[i])))
		# sentido antihorario en (x, z), como los discos (abanico con ángulo creciente)
		var area := 0.0
		for i in n:
			var a := p[i]
			var b := p[(i + 1) % n]
			area += a.x * b.z - b.x * a.z
		if area < 0.0:
			p.reverse()
		var c := Vector3.ZERO
		for q in p:
			c += q
		c /= float(n)
		var fuera := PackedVector3Array()
		var dentro := PackedVector3Array()
		for i in n:
			var t := p[(i + 1) % n] - p[(i - 1 + n) % n]
			var nrm := Vector2(t.z, -t.x).normalized()      # a la derecha del sentido antihorario = hacia fuera
			if nrm.dot(Vector2(p[i].x - c.x, p[i].z - c.z)) < 0.0:
				nrm = -nrm
			for lado: float in [1.0, -1.0]:
				var r: float = (hw + 0.3) if lado > 0.0 else hw
				var x: float = p[i].x + nrm.x * r * lado
				var z: float = p[i].z + nrm.y * r * lado
				var h := _h_asfalto(x, z, p[i].y)
				var q := Vector3(x, (p[i].y if is_nan(h) else h) - PARCHE_BAJO, z)
				if lado > 0.0:
					fuera.append(q)
				else:
					dentro.append(q)
		parches.append({"c": Vector3(c.x, c.y - PARCHE_BAJO, c.z), "borde": fuera, "interior": dentro, "ruta": false})
		stats["anillos"] += 1


# ---------------- terreno: hundirlo bajo las calzadas ----------------
## Malla de 20 m dividida en triángulos (k, k+1, k+n) y (k+1, k+n+1, k+n), igual que Mundo._terreno().
## Para cada muestra de calzada (5 por sección cada 2 m), si el triángulo que la contiene queda por encima
## del asfalto se bajan sus 3 vértices lo mínimo posible (reparto por coordenadas baricéntricas).
## Bajar un vértice nunca sube otro punto, así que basta una pasada.
func _excavar_terreno(rutas: Array, vias: Array) -> void:
	var paso: float = Ajustes.ter_paso
	var celd := int(Ajustes.ter_tesela / paso)
	var nn: int = Ajustes.ter_n
	var claves: Array = Ajustes.terreno.keys()
	var offs := {}
	var alt := PackedFloat32Array()
	for cl in claves:
		offs[cl] = alt.size()
		alt.append_array(Ajustes.terreno[cl])
	var mm: int = int(alt.size() / float(claves.size() * nn))
	# muestras (x, altura objetivo, z): 3 por sección (los dos bordes + 80 cm y el eje) cada 2 m
	var muestras := PackedVector3Array()
	for rr in rutas:
		var r: Ruta = rr
		for i in r.n:
			var usado: bool = (i < r.n - 1 and r.dibujar[i] == 1) or (i > 0 and r.dibujar[i - 1] == 1)
			if usado and r.puente[i] == 0 and r.tunel[i] == 0:
				_secciones(muestras, r.pts[i], _tan(r.pts, i), r.ancho[i] * 0.5)
	for v in vias:
		if int(v.get("tunel", 0)) == 1 or int(v.get("puente", 0)) == 1:
			continue
		var pts: PackedVector3Array = v["pts"]
		var hw := float(v["ancho"]) * 0.5
		for i in pts.size():
			_secciones(muestras, pts[i], _tan(pts, i), hw)
	for pc in parches:
		var c0: Vector3 = pc["c"]
		if pc.has("interior"):
			for q in pc["interior"]:
				muestras.append(q - Vector3(0.0, MARGEN_TERRENO, 0.0))
		else:
			muestras.append(c0 - Vector3(0.0, MARGEN_TERRENO, 0.0))
		for q in pc["borde"]:
			var fuera := Vector3(q.x - c0.x, 0.0, q.z - c0.z).normalized() * ARCEN_TERRENO
			muestras.append(q + fuera - Vector3(0.0, MARGEN_TERRENO, 0.0))
	var x0: float = Ajustes.ter_x0
	var z0: float = Ajustes.ter_z0
	var maximo := 0.0
	var veces := 0
	var cl_prev := Vector2i(-99999, -99999)
	var o := -1
	for m in muestras:
		var gx := (m.x - x0) / paso
		var gz := (m.z - z0) / paso
		var ti := floori(gx / celd)
		var tj := floori(gz / celd)
		if ti != cl_prev.x or tj != cl_prev.y:
			cl_prev = Vector2i(ti, tj)
			o = offs.get(cl_prev, -1)
		if o < 0:
			continue
		var lx := clampf(gx - ti * celd, 0.0, celd - 0.001)
		var lz := clampf(gz - tj * celd, 0.0, celd - 0.001)
		var i := int(lx)
		var j := int(lz)
		var fx := lx - i
		var fz := lz - j
		var k := o + j * nn + i
		var k0 := k
		var k1 := k + 1
		var k2 := k + nn
		var w0 := 1.0 - fx - fz
		var w1 := fx
		var w2 := fz
		if w0 < 0.0:
			k0 = k + nn + 1; k1 = k + nn; k2 = k + 1
			w0 = -w0; w1 = 1.0 - fx; w2 = 1.0 - fz
		var e := alt[k0] * w0 + alt[k1] * w1 + alt[k2] * w2 - m.y
		if e > 0.0:
			var q := e / (w0 * w0 + w1 * w1 + w2 * w2)
			alt[k0] -= q * w0
			alt[k1] -= q * w1
			alt[k2] -= q * w2
			veces += 1
			if q > maximo:
				maximo = q
				stats["max_hundido_en"] = Vector2i(roundi(m.x), roundi(m.z))
	# costuras: el borde de una tesela está repetido en la vecina; se quedan con la altura más baja
	for _rep in 2:
		for cl in claves:
			var oa: int = offs[cl]
			var ob: int = offs.get(cl + Vector2i(1, 0), -1)
			if ob >= 0:
				for j in mm:
					var a := oa + j * nn + nn - 1
					var b := ob + j * nn
					var h := minf(alt[a], alt[b])
					alt[a] = h
					alt[b] = h
			ob = offs.get(cl + Vector2i(0, 1), -1)
			if ob >= 0:
				for i in nn:
					var a := oa + (mm - 1) * nn + i
					var b := ob + i
					var h := minf(alt[a], alt[b])
					alt[a] = h
					alt[b] = h
	stats["muestras_terreno_bajadas"] = veces
	stats["max_hundido"] = snappedf(maximo, 0.01)
	var tam := nn * mm
	for cl in claves:
		var oc: int = offs[cl]
		Ajustes.terreno[cl] = alt.slice(oc, oc + tam)


static func _secciones(muestras: PackedVector3Array, p: Vector3, t: Vector3, hw: float) -> void:
	var der := Vector3(-t.z, 0.0, t.x)
	var y := p.y - MARGEN_TERRENO
	var e := der * (hw + ARCEN_TERRENO)
	muestras.append(Vector3(p.x - e.x, y, p.z - e.z))
	muestras.append(Vector3(p.x, y, p.z))
	muestras.append(Vector3(p.x + e.x, y, p.z + e.z))
