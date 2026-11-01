## Cruces y terreno: deja limpias las intersecciones al cargar el mapa.
## 1) Una calzada secundaria (otra ruta posterior o una vía de OSM) que entra en otra ya dibujada se corta donde
##    queda entera bajo la principal; donde la pisa solo en parte (boca oblicua, cuña de un ramal) se pega 3 cm
##    por debajo de la principal, y su altura se funde con la de la principal (antes se pintaban dos asfaltos
##    casi a la misma altura uno encima del otro y parpadeaban, o la secundaria quedaba metros por encima).
##    Las calzadas terminan en borde recto: la vía que sigue a otra en el mismo nodo de OSM no se recorta.
## 2) El terreno (malla de 20 m) se hunde lo justo bajo cada calzada para que nunca asome por encima del asfalto.
## Todo en una sola pasada, en la carga (unas décimas de segundo); no cambia los ficheros de datos.
class_name Cruces
extends RefCounted

const CELDA := 40.0
const BAJO := 0.03            # el final de la secundaria queda 3 cm por debajo de la principal
const MAX_DESNIVEL := 6.0     # más desnivel que esto = otro nivel (paso elevado): no es un cruce
const HOLGURA := 0.15         # margen lateral extra al decidir si dos calzadas se solapan
const MARGEN_TERRENO := 0.25  # el terreno queda al menos 25 cm por debajo del asfalto
const ARCEN_TERRENO := 0.8    # ... también 80 cm más allá de cada borde (ahí empieza el talud)

var sa := PackedVector3Array()
var sb := PackedVector3Array()
var shw := PackedFloat32Array()
var celdas := {}
var extremos := {}           # Vector2i (celda de 4 m) -> [Vector3]: extremos de las calzadas ya colocadas
var stats := {"cortes": 0, "trozos_ruta_ocultos": 0, "vias_partidas": 0, "extremos_pegados": 0}


static func preparar(rutas: Array, vias: Array) -> Dictionary:
	var c := Cruces.new()
	var t0 := Time.get_ticks_msec()
	for ri in rutas.size():
		c._procesar_ruta(rutas[ri])
	c.stats["ms_rutas"] = Time.get_ticks_msec() - t0
	var nuevas := c._procesar_vias(vias)
	vias.clear()
	vias.append_array(nuevas)
	c.stats["ms_vias"] = Time.get_ticks_msec() - t0
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
func _todo_dentro(p: Vector3, t: Vector3, hw: float) -> bool:
	var der := Vector3(-t.z, 0.0, t.x) * hw
	return _dentro(p.x, p.z, p.y) and _dentro(p.x + der.x, p.z + der.z, p.y) and _dentro(p.x - der.x, p.z - der.z, p.y)


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
	if hay:
		var pts := r.pts
		for i in r.n - 1:
			if r.dibujar[i] == 1 and dentro[i] == 1 and dentro[i + 1] == 1:
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
