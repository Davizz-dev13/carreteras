## Cruces y terreno: deja limpias las intersecciones al cargar el mapa.
## 1) Una calzada secundaria (otra ruta posterior o una vía de OSM) que entra en otra ya dibujada se corta justo
##    en el borde de la principal y su altura se funde con la de la principal (antes se pintaban dos asfaltos
##    casi a la misma altura uno encima del otro y parpadeaban, o la secundaria quedaba metros por encima).
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
var stats := {"cortes": 0, "trozos_ruta_ocultos": 0, "vias_partidas": 0}


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
		var u := clampf(((p.x - a.x) * abx + (p.z - a.z) * abz) / l2, 0.0, 1.0)
		var ex := p.x - a.x - abx * u
		var ez := p.z - a.z - abz * u
		var d2 := ex * ex + ez * ez
		var tope := shw[k] + hw + HOLGURA
		if d2 >= tope * tope:
			continue
		var hh := a.y + (b.y - a.y) * u
		if absf(hh - p.y) > MAX_DESNIVEL:
			continue
		var d := sqrt(d2)
		var l := sqrt(l2)
		var paralelo := absf((t.x * abx + t.z * abz) / l)
		var s := shw[k] + hw * paralelo + HOLGURA - d
		if s > mejor:
			mejor = s
			h = hh
	return Vector2(mejor, h)


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
			salida.append(v)
			if pts.size() >= 2 and int(v.get("tunel", 0)) == 0:
				for i in pts.size() - 1:
					_anadir(pts[i], pts[i + 1], hw)
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
			salida.append(v)
			for i in n - 1:
				_anadir(pts[i], pts[i + 1], hw)
			continue
		# trozos de vértices fuera de cualquier calzada principal, cortados en el borde exacto
		var piezas := 0
		var i := 0
		while i < n:
			if sol[i] > 0.0:
				i += 1
				continue
			var j := i
			while j + 1 < n and sol[j + 1] <= 0.0:
				j += 1
			var trozo := pts.slice(i, j + 1)
			if i > 0:
				var c := _corte(pts[i], pts[i - 1], hw)
				trozo.insert(0, Vector3(c.x, c.y, c.z))
				var d0: float = c.y - _alt_original(pts, i, i - 1, c)
				trozo[0].y = _alt_original(pts, i, i - 1, c)
				_fundir(trozo, 0, 1, d0)
				stats["cortes"] += 1
			if j < n - 1:
				var c2 := _corte(pts[j], pts[j + 1], hw)
				var ya := _alt_original(pts, j, j + 1, c2)
				trozo.append(Vector3(c2.x, ya, c2.z))
				_fundir(trozo, trozo.size() - 1, -1, c2.y - ya)
				stats["cortes"] += 1
			if trozo.size() >= 2:
				var nv := v.duplicate()
				nv["pts"] = trozo
				salida.append(nv)
				piezas += 1
				for k in trozo.size() - 1:
					_anadir(trozo[k], trozo[k + 1], hw)
			i = j + 1
		if piezas > 1:
			stats["vias_partidas"] += 1
	return salida


## Punto del segmento fuera→dentro donde el solape pasa a ser 0 (bisección).
## Devuelve Vector3(x, altura final = principal - BAJO, z).
func _corte(fuera: Vector3, dentro: Vector3, hw: float) -> Vector3:
	var t := Vector3(dentro.x - fuera.x, 0.0, dentro.z - fuera.z).normalized()
	var lo := 0.0
	var hi := 1.0
	var h := dentro.y
	for _k in 12:
		var m := (lo + hi) * 0.5
		var s := _solape(fuera.lerp(dentro, m), t, hw)
		if s.x > 0.0:
			hi = m
			h = s.y
		else:
			lo = m
	var p := fuera.lerp(dentro, lo)
	var s2 := _solape(fuera.lerp(dentro, hi), t, hw)
	if s2.x > 0.0:
		h = s2.y
	return Vector3(p.x, h - BAJO, p.z)


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
