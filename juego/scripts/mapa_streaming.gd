## Streaming del mapa: solo se mantiene construida (en el árbol de escena y en memoria) una ventana alrededor del
## coche; lo que queda atrás se libera y lo de delante se construye poco a poco, unas piezas por fotograma con un
## presupuesto de tiempo (sin hilos: funciona igual en la versión web).
##  · Terreno lejano: una sola malla de baja resolución (100 m) de toda la zona, siempre cargada, para que el
##    horizonte y las montañas no desaparezcan. Cada vértice está a la altura MÍNIMA del terreno fino que lo rodea,
##    así queda siempre por debajo del terreno de 20 m y nunca asoma ni parpadea con él.
##  · Terreno fino (20 m) en piezas de 500 × 500 m, carreteras y vías en trozos de ~200 m, pinos en piezas de
##    500 m: se construyen al entrar en la ventana y se liberan (queue_free + sin referencias) al salir.
##  · La ventana es un círculo adelantado en la dirección de marcha: ~2 km por delante y ~0,5 km por detrás
##    (el terreno fino un poco más). Con histéresis para no construir y destruir lo mismo en el borde.
class_name MapaStreaming
extends Node3D

const PASO_LEJANO := 5          # muestras de 20 m por vértice del terreno lejano (= 100 m)
const SUB := 25                 # celdas de 20 m por pieza de terreno fino (= 500 m)
const TROZO := 100              # muestras de 2 m por trozo de carretera (= 200 m)
const DIST_ARBOLES := 1600.0
const DIST_ARBOLES_LOD := 450.0     # Gráficos alto: malla de árbol sencilla desde aquí (distancia al centro de la pieza de 500 m)
const DIST_MARCAS := 450.0
const DIST_CALZADA := 6000.0

# ventana (metros, plano XZ): centro = coche + adelante * ADELANTO; se construye lo que está a menos de R_DENTRO
# del centro y se libera lo que pasa de R_FUERA
const ADELANTO := 775.0
const R_DENTRO := [1225.0, 1450.0]   # [carreteras, terreno fino y pinos] → por delante 2,0 / 2,2 km
const R_FUERA := [1300.0, 1550.0]    # → se liberan a ~0,5 / ~0,8 km por detrás
const R_URGENTE := 400.0             # lo que esté a menos de esto del coche se construye aunque se pase el presupuesto
const PRESUPUESTO_US := 3000         # µs de construcción por fotograma
const REPASO := 30.0                 # m recorridos entre repasos de la ventana
const SALTO := 300.0                 # un salto mayor es un teletransporte (R, reiniciar): se reconstruye ya

enum { T_TERRENO, T_RUTA, T_VIA, T_ARBOLES, T_EXTRA }   # T_EXTRA: quitamiedos y señales de OSM (quitamiedos.gd, senales_osm.gd)

var mundo: Node3D
var piezas: Array = []          # [{t, c: Vector2, r, v (0|1), nodo, ...}]
var _c := PackedVector2Array()  # copia empaquetada de centro / radio / ventana / construida, para repasar rápido
var _r := PackedFloat32Array()
var _v := PackedByteArray()
var _hecha := PackedByteArray()
var cola: Array = []            # índices de piezas por construir, de la más cercana al coche a la más lejana
var malla_pino: ArrayMesh
var mallas_arbol: Array = []       # Gráficos alto: [pino, pino lejos, frondosa, frondosa lejos] (aspecto.gd)
var dir_arboles := "arboles/"     # Gráficos alto: "paisaje/arboles/" (WorldCover, aspecto)
var _arboles_tesela := {}       # Vector2i -> Array[PackedFloat32Array] (16 sub-piezas)
var _ultima := Vector3(INF, 0, INF)
var _adelante := Vector2(0, -1)
var _iniciado := false
# estadísticas para medir
var est := {"construidas": 0, "liberadas": 0, "us_max_pieza": 0, "us_max_fotograma": 0, "us_total": 0, "vivas": 0,
		"fotogramas": 0, "us_carga_ventana": 0, "us_piezas": 0, "us_max_repaso": 0, "fot_sobre_4ms": 0}


func preparar(m: Node3D) -> void:
	var t0 := Time.get_ticks_msec()
	mundo = m
	malla_pino = _malla_pino()
	_terreno_lejano()
	_piezas_terreno()
	for r in Ajustes.rutas:
		_piezas_ruta(r)
	for v in Ajustes.vias:
		_piezas_via(v)
	_piezas_parches()
	_piezas_extra()
	print("Streaming: %d piezas descritas, terreno lejano listo en %d ms" % [piezas.size(), Time.get_ticks_msec() - t0])


# ---------------------------------------------------------------- ventana
## Llamar cada fotograma con la posición del coche (y su dirección, si se conoce).
func actualizar(pos: Vector3, adelante := Vector3.ZERO) -> void:
	var t0 := Time.get_ticks_usec()
	var p2 := Vector2(pos.x, pos.z)
	var salto := not _iniciado or p2.distance_to(Vector2(_ultima.x, _ultima.z)) > SALTO
	if adelante != Vector3.ZERO and Vector2(adelante.x, adelante.z).length() > 0.01:
		_adelante = Vector2(adelante.x, adelante.z).normalized()
	elif not salto and p2.distance_to(Vector2(_ultima.x, _ultima.z)) > 5.0:
		_adelante = (p2 - Vector2(_ultima.x, _ultima.z)).normalized()
	if salto or p2.distance_to(Vector2(_ultima.x, _ultima.z)) > REPASO:
		var tr := Time.get_ticks_usec()
		_repasar(p2)
		est["us_max_repaso"] = maxi(est["us_max_repaso"], Time.get_ticks_usec() - tr)
		_ultima = pos
	if salto:
		_iniciado = true
		_construir_cola(p2, -1)          # todo lo de la ventana, ya (carga inicial o teletransporte)
	else:
		_construir_cola(p2, PRESUPUESTO_US)
	var us := Time.get_ticks_usec() - t0
	if salto:
		est["us_carga_ventana"] = us
	else:
		est["us_max_fotograma"] = maxi(est["us_max_fotograma"], us)
		if us > 4000:
			est["fot_sobre_4ms"] += 1
		est["us_total"] += us
		est["fotogramas"] += 1


## Carga inicial: construye toda la ventana alrededor de `pos` antes de mostrar el juego.
func cargar_ventana(pos: Vector3, adelante := Vector3.ZERO) -> void:
	_iniciado = false
	actualizar(pos, adelante)


func _repasar(p2: Vector2) -> void:
	# arrays empaquetados (centro, radio, ventana, construida): el repaso de ~2700 piezas cuesta < 1 ms
	var centro := p2 + _adelante * ADELANTO
	var r_dentro := PackedFloat32Array(R_DENTRO)
	var r_fuera := PackedFloat32Array(R_FUERA)
	cola.clear()
	_dist_cola.clear()
	var lista := []
	for k in _c.size():
		var d := centro.distance_to(_c[k]) - _r[k]
		if _hecha[k] == 1:
			if d > r_fuera[_v[k]]:
				_liberar(piezas[k])
				_hecha[k] = 0
		elif d < r_dentro[_v[k]]:
			lista.append(Vector2(maxf(p2.distance_to(_c[k]) - _r[k], 0.0), k))
	lista.sort()
	for e in lista:
		cola.append(int(e.y))
		_dist_cola[int(e.y)] = e.x


var _dist_cola := {}


func _construir_cola(_p2: Vector2, presupuesto: int) -> void:
	var t0 := Time.get_ticks_usec()
	var hechas := 0
	while not cola.is_empty():
		var k: int = cola[0]
		if presupuesto >= 0 and hechas > 0 and Time.get_ticks_usec() - t0 > presupuesto and _dist_cola.get(k, 0.0) > R_URGENTE:
			break
		cola.pop_front()
		var pz: Dictionary = piezas[k]
		if pz["nodo"] != null:
			continue
		var t1 := Time.get_ticks_usec()
		_construir(pz)
		_hecha[k] = 1
		var up := Time.get_ticks_usec() - t1
		est["us_max_pieza"] = maxi(est["us_max_pieza"], up)
		var tipo: String = ["max_terreno", "max_ruta", "max_via", "max_pinos", "max_extra"][int(pz["t"])]
		est[tipo] = maxi(est.get(tipo, 0), up)
		est["us_piezas"] += up
		est["construidas"] += 1
		est["vivas"] += 1
		hechas += 1


func _liberar(pz: Dictionary) -> void:
	var n: Node = pz["nodo"]
	pz["nodo"] = null
	remove_child(n)
	n.queue_free()          # al liberarse el nodo se sueltan su ArrayMesh/MultiMesh (no hay más referencias)
	est["liberadas"] += 1
	est["vivas"] -= 1


func _construir(pz: Dictionary) -> void:
	var n: Node3D
	match int(pz["t"]):
		T_TERRENO: n = _terreno_fino(pz)
		T_RUTA: n = _trozo_ruta(pz)
		T_VIA: n = _trozo_via(pz)
		T_ARBOLES: n = _pinos(pz)
		T_EXTRA: n = SenalesOsm.construir(pz) if pz.has("senal") else Quitamiedos.construir(pz)
	if n == null:
		n = Node3D.new()      # pieza vacía (p. ej. sin árboles): se marca como hecha igual
	pz["nodo"] = n
	add_child(n)


func piezas_vivas() -> int:
	return est["vivas"]


# ---------------------------------------------------------------- descripción de piezas (sin geometría)
func _pieza(t: int, v: int, xmin: float, zmin: float, xmax: float, zmax: float, extra := {}) -> void:
	var pz := {"t": t, "v": v, "c": Vector2((xmin + xmax) * 0.5, (zmin + zmax) * 0.5),
			"r": Vector2(xmax - xmin, zmax - zmin).length() * 0.5 + 3.0, "nodo": null}
	pz.merge(extra)
	piezas.append(pz)
	_c.append(pz["c"])
	_r.append(pz["r"])
	_v.append(v)
	_hecha.append(0)


func _piezas_terreno() -> void:
	# Gráficos alto (aspecto): árboles donde WorldCover dice que hay bosque (paisaje/arboles, solo escritorio)
	var wc := {}
	if mundo.marcas_norma and FileAccess.file_exists(Ajustes.dir_datos() + "paisaje/arboles/fuente.json"):
		var fj = JSON.parse_string(FileAccess.get_file_as_string(Ajustes.dir_datos() + "paisaje/arboles/fuente.json"))
		if fj is Dictionary and fj.has("teselas"):
			wc = fj["teselas"]
			dir_arboles = "paisaje/arboles/"
	var p := Ajustes.ter_paso
	var lado := SUB * p
	for t in Ajustes.info["terreno"]["teselas"]:
		var x0 := float(t["x0"])
		var z0 := float(t["z0"])
		var clave := Vector2i(roundi((x0 - Ajustes.ter_x0) / Ajustes.ter_tesela), roundi((z0 - Ajustes.ter_z0) / Ajustes.ter_tesela))
		var subs := int(t["n"] - 1) / SUB
		for sj in subs:
			for si in subs:
				var xa := x0 + si * lado
				var za := z0 + sj * lado
				_pieza(T_TERRENO, 1, xa, za, xa + lado, za + lado, {"clave": clave, "si": si, "sj": sj, "x0": x0, "z0": z0, "n": int(t["n"]), "m": int(t["m"])})
				if int(wc.get(t["nombre"], 0) if not wc.is_empty() else t["arboles"]) > 0:
					_pieza(T_ARBOLES, 1, xa, za, xa + lado, za + lado, {"clave": clave, "sub": sj * subs + si, "nombre": t["nombre"], "x0": x0, "z0": z0, "subs": subs})


func _caja(pts: PackedVector3Array, a: int, b: int) -> Rect2:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for i in range(a, b + 1):
		mn = Vector2(minf(mn.x, pts[i].x), minf(mn.y, pts[i].z))
		mx = Vector2(maxf(mx.x, pts[i].x), maxf(mx.y, pts[i].z))
	return Rect2(mn, mx - mn)


func _piezas_ruta(r: Ruta) -> void:
	# línea central: continua donde el juego no deja adelantar, discontinua (4,5 m de trazo cada 12 m) donde sí
	var patron := PackedByteArray()
	patron.resize(r.n)
	for i in r.n:
		# línea derivada del criterio de adelantamiento del juego (adelantar.json); sin él, regla antigua de radio 350 m
		var continua := (r.discontinua[i] == 0) if r.discontinua.size() == r.n else absf(r.curvatura[i]) > 1.0 / 350.0
		patron[i] = 1 if (continua or fmod(i * r.paso, 12.0) < 4.5) else 0
	# donde la ruta va por debajo de otra calzada (boca de un cruce, tramo compartido) no se pintan sus líneas:
	# quedarían encima del asfalto de la otra
	var continua := PackedByteArray()
	continua.resize(r.n)
	for i in r.n:
		continua[i] = 1 if ((r.discontinua[i] == 0) if r.discontinua.size() == r.n else absf(r.curvatura[i]) > 1.0 / 350.0) else 0
	var borde := PackedByteArray()
	borde.resize(r.n)
	borde.fill(1)
	if r.bajo.size() == r.n:
		for i in r.n:
			if r.bajo[i] == 1:
				borde[i] = 0
				patron[i] = 0
	# dentro del borde exterior de una glorieta no se pintan las líneas de la ruta (ni eje de doble sentido en el
	# anillo, que es de un solo sentido): el anillo lleva las suyas (Cruces._marcas_anillo)
	if r.dentro_glorieta.size() == r.n:
		for i in r.n:
			if r.dentro_glorieta[i] == 1:
				borde[i] = 0
				patron[i] = 0
	var i := 0
	while i < r.n - 1:
		if r.dibujar[i] == 0:
			i += 1
			continue
		var j := i
		while j < r.n - 1 and r.dibujar[j] == 1:
			j += 1
		var a := i
		while a < j:
			var b := mini(a + TROZO, j)
			var c := _caja(r.pts, a, b)
			_pieza(T_RUTA, 0, c.position.x - 10, c.position.y - 10, c.end.x + 10, c.end.y + 10, {"ruta": r, "a": a, "b": b, "patron": patron, "borde": borde, "continua": continua})
			a = b
		i = j


## Objetos junto a la carretera sacados de OSM (quitamiedos y señales reales): cada módulo describe sus piezas con una caja
## y sabe construirlas; aquí solo entran en la ventana de streaming como un trozo de carretera más.
func _piezas_extra() -> void:
	for d in Quitamiedos.piezas(Ajustes.dir_datos(), Ajustes.rutas):
		var c: Rect2 = d["caja"]
		_pieza(T_EXTRA, 0, c.position.x, c.position.y, c.end.x, c.end.y, d)
	for d in SenalesOsm.piezas(Ajustes.dir_datos()):
		var c: Rect2 = d["caja"]
		d["senal"] = true
		_pieza(T_EXTRA, 0, c.position.x, c.position.y, c.end.x, c.end.y, d)


func _piezas_via(v: Dictionary) -> void:
	var pts: PackedVector3Array = v["pts"]
	if pts.size() < 2 or v["tunel"] == 1:
		return
	var anchos := PackedFloat32Array()
	anchos.resize(pts.size())
	anchos.fill(float(v["ancho"]))
	var sin_talud := PackedByteArray()
	if int(v.get("puente", 0)) == 1:
		sin_talud.resize(pts.size())
		sin_talud.fill(1)
	var a := 0
	while a < pts.size() - 1:
		var b := mini(a + TROZO, pts.size() - 1)
		var c := _caja(pts, a, b)
		_pieza(T_VIA, 0, c.position.x - 8, c.position.y - 8, c.end.x + 8, c.end.y + 8, {"pts": pts, "anchos": anchos, "sin_talud": sin_talud, "a": a, "b": b})
		a = b


## Discos de asfalto de los nodos (Cruces.parches: muescas entre los trozos de una glorieta, empalmes, bocas):
## agrupados en piezas de 250 m para no multiplicar las mallas.
func _piezas_parches() -> void:
	var grupos := {}
	for pc in Cruces.parches:
		var c0: Vector3 = pc["c"]
		var cl := Vector2i(floori(c0.x / 250.0), floori(c0.z / 250.0))
		if not grupos.has(cl):
			grupos[cl] = []
		grupos[cl].append(pc)
	for cl in grupos:
		var mn := Vector2(INF, INF)
		var mx := Vector2(-INF, -INF)
		for pc in grupos[cl]:
			for q in pc["borde"]:
				mn = Vector2(minf(mn.x, q.x), minf(mn.y, q.z))
				mx = Vector2(maxf(mx.x, q.x), maxf(mx.y, q.z))
		_pieza(T_VIA, 0, mn.x - 4, mn.y - 4, mx.x + 4, mx.y + 4, {"parches": grupos[cl]})


## Triángulos (abanico) de un disco de nodo, o banda cerrada de un anillo de glorieta.
static func tri_parche(pc: Dictionary, verts: PackedVector3Array, nor: PackedVector3Array, idx: PackedInt32Array) -> void:
	var borde: PackedVector3Array = pc["borde"]
	var k0 := verts.size()
	if pc.has("interior"):
		# anillo de glorieta: banda cerrada entre el borde de dentro y el de fuera
		var dentro: PackedVector3Array = pc["interior"]
		var m2 := borde.size()
		for k in m2:
			verts.append(dentro[k])
			verts.append(borde[k])
			nor.append(Vector3.UP)
			nor.append(Vector3.UP)
		for k in m2:
			var a := k0 + 2 * k
			var b := k0 + 2 * ((k + 1) % m2)
			for t3 in [[a, b + 1, a + 1], [a, b, b + 1]]:
				# cara de arriba hacia arriba (mismo sentido que las franjas de las calzadas; del revés no se ven)
				var p0: Vector3 = verts[t3[0]]
				var p1: Vector3 = verts[t3[1]]
				var p2: Vector3 = verts[t3[2]]
				if (p1.x - p0.x) * (p2.z - p0.z) - (p1.z - p0.z) * (p2.x - p0.x) < 0.0:
					idx.append_array([t3[0], t3[2], t3[1]])
				else:
					idx.append_array(t3)
		return
	verts.append(pc["c"])
	nor.append(Vector3.UP)
	for q in borde:
		verts.append(q)
		nor.append(Vector3.UP)
	var m := borde.size()
	for k in m:
		# mismo sentido de giro que las franjas de las calzadas: al revés la cara de arriba quedaba hacia abajo y el
		# disco no se veía (se descarta la cara de atrás)
		idx.append_array([k0, k0 + 1 + k, k0 + 1 + (k + 1) % m])


func _trozo_parches(pz: Dictionary) -> Node3D:
	var v := PackedVector3Array(); var n := PackedVector3Array(); var ix := PackedInt32Array()
	var v2 := PackedVector3Array(); var n2 := PackedVector3Array(); var ix2 := PackedInt32Array()
	var mv := PackedVector3Array(); var mn := PackedVector3Array(); var mi := PackedInt32Array()
	for pc in pz["parches"]:
		if pc["ruta"]:
			tri_parche(pc, v, n, ix)
		else:
			tri_parche(pc, v2, n2, ix2)
		if pc.has("marcas"):
			# líneas del anillo de la glorieta (Cruces._marcas_anillo): bordes y separación de carriles, sin eje
			var b0 := mv.size()
			mv.append_array(pc["marcas"][0])
			for q in (pc["marcas"][0] as PackedVector3Array).size():
				mn.append(Vector3.UP)
			for t in (pc["marcas"][1] as PackedInt32Array):
				mi.append(b0 + t)
	var sup := [[v, n, ix, mundo.mat_asfalto], [v2, n2, ix2, mundo.mat_asfalto2]]
	if not mv.is_empty():
		sup.append([mv, mn, mi, mundo.mat_marca])
	return _instancia(_malla(sup), DIST_CALZADA)


# ---------------------------------------------------------------- terreno
## Terreno lejano: toda la zona a 100 m en UNA malla (1 draw call). Vértice = mínimo del terreno fino en las 4
## celdas de 100 m que lo rodean (menos 0,5 m): cualquier punto del terreno fino queda por encima.
func _terreno_lejano() -> void:
	var tz: Dictionary = Ajustes.info["terreno"]
	var p := Ajustes.ter_paso
	var celd := int(Ajustes.ter_tesela / p) / PASO_LEJANO     # celdas lejanas por tesela (20)
	var nti := 0
	var ntj := 0
	for cl in Ajustes.terreno.keys():
		nti = maxi(nti, cl.x + 1)
		ntj = maxi(ntj, cl.y + 1)
	var ci := nti * celd           # celdas lejanas en X
	var cj := ntj * celd
	# mínimo y altura real por celda lejana / vértice lejano
	var minimo := PackedFloat32Array()
	minimo.resize(ci * cj)
	minimo.fill(INF)
	var real := PackedFloat32Array()   # altura real en cada vértice lejano (para color y normal)
	real.resize((ci + 1) * (cj + 1))
	real.fill(0.0)
	for t in tz["teselas"]:
		var nn := int(t["n"])
		var cl := Vector2i(roundi((float(t["x0"]) - Ajustes.ter_x0) / Ajustes.ter_tesela), roundi((float(t["z0"]) - Ajustes.ter_z0) / Ajustes.ter_tesela))
		var h: PackedFloat32Array = Ajustes.terreno[cl]
		# mínimo por fila dentro de cada tramo de 6 muestras, luego por columnas de 6 filas
		var filas := PackedFloat32Array()
		filas.resize(nn * celd)
		for j in nn:
			var base := j * nn
			for c in celd:
				var i0 := base + c * PASO_LEJANO
				var mn := h[i0]
				for d in range(1, PASO_LEJANO + 1):
					mn = minf(mn, h[i0 + d])
				filas[j * celd + c] = mn
		for cz in celd:
			for cx in celd:
				var mn := INF
				for d in PASO_LEJANO + 1:
					mn = minf(mn, filas[(cz * PASO_LEJANO + d) * celd + cx])
				minimo[(cl.y * celd + cz) * ci + cl.x * celd + cx] = mn
		for vz in celd + 1:
			for vx in celd + 1:
				real[(cl.y * celd + vz) * (ci + 1) + cl.x * celd + vx] = h[vz * PASO_LEJANO * nn + vx * PASO_LEJANO]
	var pl := p * PASO_LEJANO
	var nv := (ci + 1) * (cj + 1)
	var verts := PackedVector3Array()
	var nor := PackedVector3Array()
	var col := PackedColorArray()
	verts.resize(nv)
	nor.resize(nv)
	col.resize(nv)
	for vz in cj + 1:
		for vx in ci + 1:
			var mn := INF
			for dz in [-1, 0]:
				for dx in [-1, 0]:
					var cx: int = vx + dx
					var cz: int = vz + dz
					if cx >= 0 and cx < ci and cz >= 0 and cz < cj:
						mn = minf(mn, minimo[cz * ci + cx])
			var k := vz * (ci + 1) + vx
			var hl := real[vz * (ci + 1) + maxi(vx - 1, 0)]
			var hr := real[vz * (ci + 1) + mini(vx + 1, ci)]
			var hu := real[maxi(vz - 1, 0) * (ci + 1) + vx]
			var hd := real[mini(vz + 1, cj) * (ci + 1) + vx]
			var nrm := Vector3(hl - hr, 2.0 * pl, hu - hd).normalized()
			verts[k] = Vector3(Ajustes.ter_x0 + vx * pl, (mn if mn < INF else real[k]) - 0.5, Ajustes.ter_z0 + vz * pl)
			nor[k] = nrm
			col[k] = mundo._color_terreno(real[k], 1.0 - nrm.y)
	var idx := PackedInt32Array()
	idx.resize(ci * cj * 6)
	var c := 0
	for vz in cj:
		for vx in ci:
			var k := vz * (ci + 1) + vx
			idx[c] = k; idx[c + 1] = k + 1; idx[c + 2] = k + ci + 1
			idx[c + 3] = k + 1; idx[c + 4] = k + ci + 2; idx[c + 5] = k + ci + 1
			c += 6
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = nor
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = idx
	var malla := ArrayMesh.new()
	malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	malla.surface_set_material(0, mundo.mat_terreno)
	var mi := MeshInstance3D.new()
	mi.name = "TerrenoLejano"
	mi.mesh = malla
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## Terreno fino: pieza de 500 m (26 × 26 vértices) de una tesela de 2 km, mismas normales y triángulos que antes
func _terreno_fino(pz: Dictionary) -> Node3D:
	var p := Ajustes.ter_paso
	var nn: int = pz["n"]
	var mm: int = pz["m"]
	var h: PackedFloat32Array = Ajustes.terreno[pz["clave"]]
	var i0: int = pz["si"] * SUB
	var j0: int = pz["sj"] * SUB
	var x0: float = pz["x0"]
	var z0: float = pz["z0"]
	var lv := SUB + 1
	var verts := PackedVector3Array()
	var normales := PackedVector3Array()
	var colores := PackedColorArray()
	verts.resize(lv * lv)
	normales.resize(lv * lv)
	colores.resize(lv * lv)
	for lj in lv:
		var j := j0 + lj
		for li in lv:
			var i := i0 + li
			var k := j * nn + i
			var hl := h[j * nn + maxi(i - 1, 0)]
			var hr := h[j * nn + mini(i + 1, nn - 1)]
			var hu := h[maxi(j - 1, 0) * nn + i]
			var hd := h[mini(j + 1, mm - 1) * nn + i]
			var nrm := Vector3(hl - hr, 2.0 * p, hu - hd).normalized()
			var q := lj * lv + li
			verts[q] = Vector3(x0 + i * p, h[k], z0 + j * p)
			normales[q] = nrm
			colores[q] = mundo._color_terreno(h[k], 1.0 - nrm.y)
	var idx := PackedInt32Array()
	idx.resize(SUB * SUB * 6)
	var c := 0
	for lj in SUB:
		for li in SUB:
			var k := lj * lv + li
			idx[c] = k; idx[c + 1] = k + 1; idx[c + 2] = k + lv
			idx[c + 3] = k + 1; idx[c + 4] = k + lv + 1; idx[c + 5] = k + lv
			c += 6
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normales
	arr[Mesh.ARRAY_COLOR] = colores
	arr[Mesh.ARRAY_INDEX] = idx
	var malla := ArrayMesh.new()
	malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	malla.surface_set_material(0, mundo.mat_terreno)
	var mi := MeshInstance3D.new()
	mi.mesh = malla
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# ---------------------------------------------------------------- carreteras
## Franja a lo largo de una polilínea entre las muestras a y b; añade a los arrays dados (para juntar varias en 1 malla)
func _franja(pts: PackedVector3Array, anchos: PackedFloat32Array, a: int, b: int, desplaz: float, semiancho_fijo: float,
		elev: float, verts: PackedVector3Array, nor: PackedVector3Array, idx: PackedInt32Array, patron := PackedByteArray(),
		talud := false, sin_talud := PackedByteArray(), tv := PackedVector3Array(), tn := PackedVector3Array(), ti := PackedInt32Array(),
		uvs: Variant = null, tuv: Variant = null) -> void:
	# uvs (asfalto): x = m al eje (+ derecha), y = semiancho, para las rodadas y el borde del shader del asfalto;
	# tuv (talud): y = 0 junto al asfalto, 1 abajo (la franja de grava del arcén en el shader del terreno)
	for i in range(a, b + 1):
		var t := pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]
		var der := Vector3(-t.z, 0.0, t.x).normalized()
		var hw := semiancho_fijo if semiancho_fijo > 0.0 else anchos[i] * 0.5
		# desplaz = -1/+1: línea de borde a 25 cm del borde izquierdo/derecho; 0: eje
		var centro := pts[i] + der * signf(desplaz) * (anchos[i] * 0.5 - 0.25)
		if not patron.is_empty() and patron[i] == 0:
			# hueco de línea discontinua: vértices degenerados
			verts.append(centro + Vector3.UP * elev)
			verts.append(centro + Vector3.UP * elev)
		else:
			verts.append(centro - der * hw + Vector3.UP * elev)
			verts.append(centro + der * hw + Vector3.UP * elev)
		nor.append(Vector3.UP)
		nor.append(Vector3.UP)
		if uvs != null:
			(uvs as PackedVector2Array).append(Vector2(-hw, hw))
			(uvs as PackedVector2Array).append(Vector2(hw, hw))
		if i > a:
			var k := verts.size() - 4
			idx.append_array([k, k + 2, k + 1, k + 1, k + 2, k + 3])
		if talud:
			# talud: faldón de tierra desde cada borde hacia abajo y afuera (tapa el hueco con el terreno hundido)
			var bl := verts[verts.size() - 2]
			var br := verts[verts.size() - 1]
			var caida := Vector3.ZERO if (not sin_talud.is_empty() and sin_talud[i] == 1) else Vector3(0.0, -2.4, 0.0)
			var fuera := der * (2.0 if caida != Vector3.ZERO else 0.0)
			tv.append_array([bl - fuera + caida, bl, br, br + fuera + caida])
			if tuv != null:
				(tuv as PackedVector2Array).append_array([Vector2(0, 1), Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)])
			tn.append_array([(Vector3.UP - der).normalized(), (Vector3.UP - der).normalized(),
					(Vector3.UP + der).normalized(), (Vector3.UP + der).normalized()])
			if i > a:
				var q := tv.size() - 8
				ti.append_array([q, q + 4, q + 1, q + 1, q + 4, q + 5, q + 2, q + 6, q + 3, q + 3, q + 6, q + 7])


func _malla(superficies: Array) -> ArrayMesh:
	# superficies: [[verts, nor, idx, material], ...]
	var malla := ArrayMesh.new()
	for s in superficies:
		if (s[2] as PackedInt32Array).is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = s[0]
		arr[Mesh.ARRAY_NORMAL] = s[1]
		arr[Mesh.ARRAY_INDEX] = s[2]
		if s.size() > 4 and (s[4] as PackedVector2Array).size() == (s[0] as PackedVector3Array).size():
			arr[Mesh.ARRAY_TEX_UV] = s[4]
		malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		malla.surface_set_material(malla.get_surface_count() - 1, s[3])
	return malla


func _instancia(malla: ArrayMesh, visible_hasta: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = malla
	mi.visibility_range_end = visible_hasta
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Trozo de ruta: calzada + taludes (1 malla, 2 superficies) y las 3 líneas blancas juntas (1 malla)
func _trozo_ruta(pz: Dictionary) -> Node3D:
	var r: Ruta = pz["ruta"]
	var a: int = pz["a"]
	var b: int = pz["b"]
	var v := PackedVector3Array(); var n := PackedVector3Array(); var ix := PackedInt32Array()
	var tv := PackedVector3Array(); var tn := PackedVector3Array(); var ti := PackedInt32Array()
	var uv := PackedVector2Array(); var tuv := PackedVector2Array()
	_franja(r.pts, r.ancho, a, b, 0.0, 0.0, 0.05, v, n, ix, PackedByteArray(), true, r.puente, tv, tn, ti, uv, tuv)
	var raiz := Node3D.new()
	raiz.add_child(_instancia(_malla([[v, n, ix, mundo.mat_asfalto, uv], [tv, tn, ti, mundo.mat_talud, tuv]]), DIST_CALZADA))
	var mv := PackedVector3Array(); var mn := PackedVector3Array(); var mi := PackedInt32Array()
	if not mundo.marcas_norma:
		_marcas_antiguas(pz, mv, mn, mi)
	else:
		_marcas_norma(pz, mv, mn, mi)
	raiz.add_child(_instancia(_malla([[mv, mn, mi, mundo.mat_marca]]), DIST_MARCAS))
	return raiz


## Marcas viales según la norma 8.2-IC (Gráficos alto): trazos con sus extremos exactos (antes cada trazo acababa
## en punta, cortado en las muestras de la ruta cada 2 m) y con la medida de la norma para carreteras convencionales:
## eje y separación de carriles M-1.2 (3,5 m de trazo y 9 m de vano), 15 cm; bordes continuos M-2.6 de 15 cm.
## Dónde es continua o discontinua no cambia (el mismo criterio de adelantamiento del juego, adelantar.json).
func _marcas_norma(pz: Dictionary, mv: PackedVector3Array, mn: PackedVector3Array, mi: PackedInt32Array) -> void:
	var r: Ruta = pz["ruta"]
	var a: int = pz["a"]
	var b: int = pz["b"]
	var borde: PackedByteArray = pz["borde"]
	var cont: PackedByteArray = pz["continua"]
	var todo := PackedByteArray(); todo.resize(r.n); todo.fill(1)
	_linea(r.pts, r.ancho, a, b, -1.0, 0.075, 0.08, mv, mn, mi, borde, todo, r.paso)
	_linea(r.pts, r.ancho, a, b, 1.0, 0.075, 0.08, mv, mn, mi, borde, todo, r.paso)
	if not r.tiene_carriles():
		_linea(r.pts, r.ancho, a, b, 0.0, 0.075, 0.085, mv, mn, mi, borde, cont, r.paso)
		return
	var eje := PackedVector3Array(); eje.resize(r.n)
	var sep_i := PackedVector3Array(); sep_i.resize(r.n)
	var sep_v := PackedVector3Array(); sep_v.resize(r.n)
	var cont_eje := cont.duplicate()
	var perm_i := PackedByteArray(); perm_i.resize(r.n)
	var perm_v := PackedByteArray(); perm_v.resize(r.n)
	var nada := PackedByteArray(); nada.resize(r.n)
	var hay_i := false
	var hay_v := false
	for i in range(maxi(a - 1, 0), mini(b + 1, r.n - 1) + 1):
		var t := r.pts[mini(i + 1, r.n - 1)] - r.pts[maxi(i - 1, 0)]
		var der := Vector3(-t.z, 0.0, t.x).normalized()
		eje[i] = r.pts[i] + der * r.lat_eje[i]
		sep_i[i] = r.pts[i] + der * (r.lat_ida[i] + r.lat_ida_adel[i]) * 0.5
		sep_v[i] = r.pts[i] + der * (r.lat_vuelta[i] + r.lat_vuelta_adel[i]) * 0.5
		if r.car_ida[i] != r.car_vuelta[i]:
			cont_eje[i] = 1     # 2+1: línea continua en el eje (ver adelantar.json, supuesto_2+1)
		perm_i[i] = 1 if (r.car_ida[i] >= 2 and borde[i] == 1) else 0
		perm_v[i] = 1 if (r.car_vuelta[i] >= 2 and borde[i] == 1) else 0
		hay_i = hay_i or r.car_ida[i] >= 2
		hay_v = hay_v or r.car_vuelta[i] >= 2
	_linea(eje, r.ancho, a, b, 0.0, 0.075, 0.085, mv, mn, mi, borde, cont_eje, r.paso)
	if hay_i: _linea(sep_i, r.ancho, a, b, 0.0, 0.075, 0.085, mv, mn, mi, perm_i, nada, r.paso)
	if hay_v: _linea(sep_v, r.ancho, a, b, 0.0, 0.075, 0.085, mv, mn, mi, perm_v, nada, r.paso)


## Una línea a lo largo de pts (lado -1/+1: a 25 cm del borde izquierdo/derecho; 0: sobre pts), solo donde `permitido`;
## continua donde `continua`, si no a trazos de `trazo` m cada `trazo + vano` m medidos sobre la ruta (s = i · paso,
## así el ritmo sigue igual entre piezas). Cada trozo pintado lleva sus extremos exactos (cuadriláteros por segmento).
func _linea(pts: PackedVector3Array, anchos: PackedFloat32Array, a: int, b: int, lado: float, hw: float, elev: float,
		mv: PackedVector3Array, mn: PackedVector3Array, mi: PackedInt32Array, permitido: PackedByteArray,
		continua: PackedByteArray, paso: float, trazo := 3.5, vano := 9.0) -> void:
	var periodo := trazo + vano
	var np := pts.size()
	for i in range(a, mini(b, np - 1)):
		if permitido[i] == 0 or permitido[i + 1] == 0:
			continue
		var s0 := i * paso
		var s1 := s0 + paso
		var trozos: Array = []
		if continua[i] == 1:
			trozos.append(Vector2(0.0, 1.0))
		else:
			var k := floorf(s0 / periodo)
			while k * periodo < s1:
				var d0 := maxf(s0, k * periodo)
				var d1 := minf(s1, k * periodo + trazo)
				if d1 > d0 + 0.01:
					trozos.append(Vector2((d0 - s0) / paso, (d1 - s0) / paso))
				k += 1.0
		if trozos.is_empty():
			continue
		var t0 := pts[mini(i + 1, np - 1)] - pts[maxi(i - 1, 0)]
		var t1 := pts[mini(i + 2, np - 1)] - pts[i]
		var der0 := Vector3(-t0.z, 0.0, t0.x).normalized()
		var der1 := Vector3(-t1.z, 0.0, t1.x).normalized()
		for tr in trozos:
			var q := mv.size()
			for f in [tr.x, tr.y]:
				var der := der0.lerp(der1, f).normalized()
				var p := pts[i].lerp(pts[i + 1], f)
				var an := lerpf(anchos[i], anchos[i + 1], f)
				var c := p + der * signf(lado) * (an * 0.5 - 0.25) + Vector3.UP * elev
				mv.append(c - der * hw)
				mv.append(c + der * hw)
				mn.append(Vector3.UP)
				mn.append(Vector3.UP)
			mi.append_array([q, q + 2, q + 1, q + 1, q + 2, q + 3])


func _marcas_antiguas(pz: Dictionary, mv: PackedVector3Array, mn: PackedVector3Array, mi: PackedInt32Array) -> void:
	var r: Ruta = pz["ruta"]
	var a: int = pz["a"]
	var b: int = pz["b"]
	# líneas de borde (continuas, 15 cm) y central (continua en curvas cerradas, discontinua en rectas)
	_franja(r.pts, r.ancho, a, b, -1.0, 0.075, 0.08, mv, mn, mi, pz["borde"])
	_franja(r.pts, r.ancho, a, b, 1.0, 0.075, 0.08, mv, mn, mi, pz["borde"])
	if not r.tiene_carriles():
		_franja(r.pts, r.ancho, a, b, 0.0, 0.07, 0.085, mv, mn, mi, pz["patron"])
	else:
		# carriles reales (2+1): eje desplazado y línea discontinua entre los dos carriles del mismo sentido
		var eje := PackedVector3Array(); eje.resize(r.n)
		var sep_i := PackedVector3Array(); sep_i.resize(r.n)
		var sep_v := PackedVector3Array(); sep_v.resize(r.n)
		var pat_eje: PackedByteArray = pz["patron"].duplicate()
		var pat_i := PackedByteArray(); pat_i.resize(r.n)
		var pat_v := PackedByteArray(); pat_v.resize(r.n)
		var hay_i := false
		var hay_v := false
		for i in range(maxi(a - 1, 0), mini(b + 1, r.n - 1) + 1):
			var t := r.pts[mini(i + 1, r.n - 1)] - r.pts[maxi(i - 1, 0)]
			var der := Vector3(-t.z, 0.0, t.x).normalized()
			eje[i] = r.pts[i] + der * r.lat_eje[i]
			sep_i[i] = r.pts[i] + der * (r.lat_ida[i] + r.lat_ida_adel[i]) * 0.5
			sep_v[i] = r.pts[i] + der * (r.lat_vuelta[i] + r.lat_vuelta_adel[i]) * 0.5
			var discontinua := fmod(i * r.paso, 12.0) < 4.5
			if r.car_ida[i] != r.car_vuelta[i] and pz["borde"][i] == 1:
				pat_eje[i] = 1     # 2+1: línea continua en el eje (ver adelantar.json, supuesto_2+1)
			pat_i[i] = 1 if (r.car_ida[i] >= 2 and discontinua and pz["borde"][i] == 1) else 0
			pat_v[i] = 1 if (r.car_vuelta[i] >= 2 and discontinua and pz["borde"][i] == 1) else 0
			hay_i = hay_i or r.car_ida[i] >= 2
			hay_v = hay_v or r.car_vuelta[i] >= 2
		_franja(eje, r.ancho, a, b, 0.0, 0.07, 0.085, mv, mn, mi, pat_eje)
		if hay_i: _franja(sep_i, r.ancho, a, b, 0.0, 0.07, 0.085, mv, mn, mi, pat_i)
		if hay_v: _franja(sep_v, r.ancho, a, b, 0.0, 0.07, 0.085, mv, mn, mi, pat_v)


func _trozo_via(pz: Dictionary) -> Node3D:
	if pz.has("parches"):
		return _trozo_parches(pz)
	var v := PackedVector3Array(); var n := PackedVector3Array(); var ix := PackedInt32Array()
	var tv := PackedVector3Array(); var tn := PackedVector3Array(); var ti := PackedInt32Array()
	var uv := PackedVector2Array(); var tuv := PackedVector2Array()
	_franja(pz["pts"], pz["anchos"], pz["a"], pz["b"], 0.0, 0.0, 0.04, v, n, ix, PackedByteArray(), true, pz["sin_talud"], tv, tn, ti, uv, tuv)
	return _instancia(_malla([[v, n, ix, mundo.mat_asfalto2, uv], [tv, tn, ti, mundo.mat_talud, tuv]]), DIST_CALZADA)


# ---------------------------------------------------------------- pinos
## Pinos (MultiMesh por pieza de 500 m): tronco + copa cónica, 1 sola malla de 2 superficies
func _malla_pino() -> ArrayMesh:
	var malla := ArrayMesh.new()
	var copa := CylinderMesh.new()
	copa.top_radius = 0.0
	copa.bottom_radius = 2.6
	copa.height = 10.0
	copa.radial_segments = 7
	copa.rings = 1
	var tronco := CylinderMesh.new()
	tronco.top_radius = 0.25
	tronco.bottom_radius = 0.35
	tronco.height = 5.0
	tronco.radial_segments = 5
	tronco.rings = 1
	for par in [[copa, 9.0, mundo.mat_copa], [tronco, 2.5, mundo.mat_tronco]]:
		var arr: Array = par[0].get_mesh_arrays()
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in v.size():
			v[i].y += par[1]
		arr[Mesh.ARRAY_VERTEX] = v
		malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		malla.surface_set_material(malla.get_surface_count() - 1, par[2])
	return malla


## Árboles de una tesela de 2 km ordenados por pieza de 500 m (ordenación por cuentas, 2 pasadas): se lee el fichero
## una vez y se guarda en CPU (datos ligeros). Devuelve [datos (x, z, escala), inicio por pieza (17 valores)].
func _arboles_de(pz: Dictionary) -> Array:
	var clave: Vector2i = pz["clave"]
	if _arboles_tesela.has(clave):
		return _arboles_tesela[clave]
	var subs: int = pz["subs"]
	var datos := PackedFloat32Array()
	var inicio := PackedInt32Array()
	inicio.resize(subs * subs + 1)
	inicio.fill(0)
	var f := FileAccess.open(Ajustes.dir_datos() + dir_arboles + "%s.bin" % pz["nombre"], FileAccess.READ)
	if f != null:
		var d := f.get_buffer(f.get_length()).to_float32_array()
		var n := d.size() / 4
		var lado := SUB * Ajustes.ter_paso
		var x0: float = pz["x0"]
		var z0: float = pz["z0"]
		var grupo := PackedInt32Array()
		grupo.resize(n)
		for i in n:
			var g := clampi(int((d[i * 4 + 2] - z0) / lado), 0, subs - 1) * subs + clampi(int((d[i * 4] - x0) / lado), 0, subs - 1)
			grupo[i] = g
			inicio[g + 1] += 1
		for g in subs * subs:
			inicio[g + 1] += inicio[g]
		var pos := inicio.duplicate()
		datos.resize(n * 3)
		for i in n:
			var q := pos[grupo[i]] * 3
			pos[grupo[i]] += 1
			datos[q] = d[i * 4]
			datos[q + 1] = d[i * 4 + 2]
			datos[q + 2] = d[i * 4 + 3]
	_arboles_tesela[clave] = [datos, inicio]
	return _arboles_tesela[clave]


func _pinos(pz: Dictionary) -> Node3D:
	var t: Array = _arboles_de(pz)
	var d: PackedFloat32Array = t[0]
	var i0: int = t[1][pz["sub"]]
	var cuenta: int = t[1][pz["sub"] + 1] - i0
	if cuenta == 0:
		return null
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(pz["clave"].x, pz["clave"].y, pz["sub"]))   # mismo bosque cada vez que se reconstruye
	if mundo.marcas_norma:
		return _arboles_aspecto(d, i0, cuenta, rng)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = malla_pino
	mm.instance_count = cuenta
	for i in cuenta:
		var x := d[(i0 + i) * 3]
		var z := d[(i0 + i) * 3 + 1]
		var esc := d[(i0 + i) * 3 + 2]
		var y := Ajustes.altura_terreno(x, z) - 0.3
		var bas := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(esc, esc * rng.randf_range(0.85, 1.25), esc))
		mm.set_instance_transform(i, Transform3D(bas, Vector3(x, y, z)))
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.visibility_range_end = DIST_ARBOLES
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Gráficos alto (aspecto.gd): pinos y frondosas (por altitud), con tono por árbol y 2 niveles de detalle por pieza
## de 500 m: de cerca la malla con tronco y copa de 2 masas, desde DIST_ARBOLES_LOD una copa sencilla.
func _arboles_aspecto(d: PackedFloat32Array, i0: int, cuenta: int, rng: RandomNumberGenerator) -> Node3D:
	if mallas_arbol.is_empty():
		mallas_arbol = [Aspecto.malla_arbol(true, 0), Aspecto.malla_arbol(true, 1), Aspecto.malla_arbol(false, 0), Aspecto.malla_arbol(false, 1)]
	var xf := [[], []]       # transformaciones por especie (0 pino, 1 frondosa)
	var cols := [[], []]
	for i in cuenta:
		var x := d[(i0 + i) * 3]
		var z := d[(i0 + i) * 3 + 1]
		var esc := d[(i0 + i) * 3 + 2]
		var y := Ajustes.altura_terreno(x, z) - 0.3
		var e := 0 if Aspecto.es_conifera(x, z, y) else 1
		var bas := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(esc, esc * rng.randf_range(0.85, 1.2), esc))
		xf[e].append(Transform3D(bas, Vector3(x, y, z)))
		cols[e].append(Aspecto.tono_arbol(x, z))
	var raiz := Node3D.new()
	for e in 2:
		if xf[e].is_empty():
			continue
		for lod in 2:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = mallas_arbol[e * 2 + lod]
			mm.instance_count = xf[e].size()
			for k in xf[e].size():
				mm.set_instance_transform(k, xf[e][k])
				mm.set_instance_color(k, cols[e][k])
			var mi := MultiMeshInstance3D.new()
			mi.multimesh = mm
			if lod == 0:
				mi.visibility_range_end = DIST_ARBOLES_LOD
			else:
				mi.visibility_range_begin = DIST_ARBOLES_LOD
				mi.visibility_range_end = DIST_ARBOLES
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			raiz.add_child(mi)
	return raiz