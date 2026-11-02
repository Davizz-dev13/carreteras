## Quitamiedos (bionda de doble onda, perfil W) a los dos lados de TODAS las carreteras de la zona (rutas y vías),
## como pidió David ("quitamiedos en todos los km"). Se cortan solo donde un coche tiene que pasar: bocas de cruce,
## glorietas (anillo y brazos), empalmes y caminos que salen de la carretera (cualquier otra calzada a menos de
## HUELGO_CRUCE m de la valla, o HUELGO_GLORIETA m del anillo), puentes por encima/debajo aparte (± 3 m de altura).
## Cada tramo acaba en un abatimiento (la bionda baja hasta enterrarse y se abre 0,5 m hacia fuera).
## Barato para la gráfica: por cada trozo de ~200 m de streaming, 3 MultiMesh (vallas, abatimientos y postes) con mallas
## low-poly y un material compartidos, sin sombras y con distancia de dibujado corta (los postes, más corta aún).
## El cálculo de huecos se hace al construir cada trozo (no al cargar la zona): la carga no se alarga.
## Choque: los mismos trozos, al construirse, añaden su cara de valla a un único Biondas (choque_vivo) del coche.
## Antes solo se ponían los reales de OSM (datos/<zona>/quitamiedos.json, pipeline/quitamiedos.py): ese archivo ya no
## se usa en el juego (los genéricos van por el mismo sitio, a ancho/2 + MARGEN, y no se duplican).
class_name Quitamiedos
extends RefCounted

const PASO_POSTE := 4.0       # m entre postes (bionda normal, separación 4 m)
const TROZO_M := 200.0        # m por pieza de streaming (como los trozos de carretera)
const DIST_VISIBLE := 400.0   # m: más allá no se dibujan las vallas
const DIST_POSTES := 220.0    # m: los postes (pequeños) se dejan antes
const ALTO := 0.75            # m: canto superior de la bionda sobre la calzada
const BAJO_SUELO := 0.7       # m que el poste baja por debajo de la calzada (talud)
const MARGEN := 0.7           # m del borde de la calzada a la línea de postes (la onda queda a 0,47 m del borde)
const HUELGO_CRUCE := 5.0     # m libres entre la valla y el borde de otra calzada (boca del cruce, con sus esquinas)
const HUELGO_GLORIETA := 10.0 # m libres alrededor del anillo de una glorieta (abocinamientos e isletas de los brazos)
const HUELGO_PARALELA := 0.6  # m libres con una calzada casi paralela (la otra calzada de una mediana, un ramal que se
                              # separa): la bionda sigue entre las dos mientras quepa, como en Madrid (ma_mundo.gd)
const HUECO_MIN := 1          # huecos de ≤ 1 muestra (4 m) entre dos tramos se cierran (no hay boca tan estrecha)
const TRAMO_MIN := 4          # tramos de < 4 muestras (16 m) se quitan (trocitos sueltos entre dos bocas)
const VENTANA := 8            # muestras de más que mira cada trozo a cada lado para decidir igual que sus vecinos
const ABRE := 0.5             # m que el abatimiento se abre hacia fuera de la calzada

static var _malla_valla: ArrayMesh
static var _malla_poste: ArrayMesh
static var _mat: StandardMaterial3D
static var choque_vivo: Biondas = null   # caras de valla de los trozos ya construidos (choque del coche del jugador)
static var _hechas := {}                 # id de trozo -> true (su choque ya está en choque_vivo)
static var _lineas: Array = []           # [{c: PackedVector3Array, hw, puente, id, sigue: {id: true}}]
static var _clave := ""
static var _cand_cache := {}            # "linea:i0" -> candidatos (los dos lados de un trozo comparten casi todo)
static var est := {"muestras": 0, "ocupadas": 0, "candidatos": 0, "trozos": 0}   # para las pruebas
static var _piezas: Array = []           # los trozos de la zona (los mismos diccionarios que recibe el streaming)
static var _rejilla := {}                # Vector2i (celdas de REJILLA m) -> Array de índices de _piezas
const REJILLA := 100.0


## Clave de la zona cargada: al cambiar de zona se rehace todo
static func _zona(rutas: Array) -> void:
	var k := "%s|%d|%d|%d" % [Ajustes.zona, rutas.size(), Ajustes.vias.size(), rutas[0].get_instance_id() if not rutas.is_empty() else 0]
	if k == _clave:
		return
	_clave = k
	choque_vivo = Biondas.new()
	_hechas = {}
	_cand_cache = {}
	var t0 := Time.get_ticks_usec()
	_lineas = _construir_lineas(rutas, Ajustes.vias)
	_piezas = _describir()
	_rejilla = {}
	for ip in _piezas.size():
		var c: Rect2 = _piezas[ip]["caja"]
		for cx in range(floori(c.position.x / REJILLA), floori(c.end.x / REJILLA) + 1):
			for cz in range(floori(c.position.y / REJILLA), floori(c.end.y / REJILLA) + 1):
				var g := Vector2i(cx, cz)
				if not _rejilla.has(g):
					_rejilla[g] = []
				_rejilla[g].append(ip)
	est["ms_zona"] = (Time.get_ticks_usec() - t0) / 1000.0


## Ejes de todas las calzadas que llevan bionda, remuestreados cada ~PASO_POSTE m, con el id de su calzada en Superficie
static func _construir_lineas(rutas: Array, vias: Array) -> Array:
	var out := []
	for ri in rutas.size():
		var r: Ruta = rutas[ri]
		var paso := maxi(1, roundi(PASO_POSTE / maxf(r.paso, 0.5)))
		var c := PackedVector3Array()
		var hw := PackedFloat32Array()
		var pu := PackedByteArray()
		var i := 0
		while i < r.n:
			var dib := r.dibujar[i] == 1 and r.tunel[i] == 0 and not (r.oculto.size() == r.n and r.oculto[i] == 1)
			if dib:
				c.append(r.pts[i]); hw.append(r.ancho[i] * 0.5); pu.append(r.puente[i])
			if (not dib or i + paso >= r.n) and c.size() >= 2:
				out.append({"c": c, "hw": hw, "puente": pu, "id": ri, "sigue": {}})
			if not dib or i + paso >= r.n:
				c = PackedVector3Array(); hw = PackedFloat32Array(); pu = PackedByteArray()
			i += paso if dib else 1
	var id := rutas.size()
	for v in vias:
		if int(v.get("tunel", 0)) == 1:
			continue
		var mi_id := id
		id += 1
		if v.get("oculta_glorieta", false):
			continue
		var pts: PackedVector3Array = v.get("pts_dib", v["pts"])
		if pts.size() < 2:
			continue
		var anchos := PackedFloat32Array()
		if v.has("anchos_dib") and (v["anchos_dib"] as PackedFloat32Array).size() == pts.size():
			anchos = v["anchos_dib"]
		var c := PackedVector3Array()
		var hw := PackedFloat32Array()
		var pu := PackedByteArray()
		for k in pts.size() - 1:
			var a := pts[k]
			var b := pts[k + 1]
			var ha := (anchos[k] if not anchos.is_empty() else float(v["ancho"])) * 0.5
			var hb := (anchos[k + 1] if not anchos.is_empty() else float(v["ancho"])) * 0.5
			var m := maxi(1, ceili(Vector2(b.x - a.x, b.z - a.z).length() / PASO_POSTE))
			for j in m:
				var t := float(j) / m
				c.append(a.lerp(b, t)); hw.append(lerpf(ha, hb, t)); pu.append(int(v.get("puente", 0)))
		c.append(pts[pts.size() - 1])
		hw.append((anchos[pts.size() - 1] if not anchos.is_empty() else float(v["ancho"])) * 0.5)
		pu.append(int(v.get("puente", 0)))
		out.append({"c": c, "hw": hw, "puente": pu, "id": mi_id, "sigue": {}})
	# continuaciones: dos calzadas que se tocan por sus extremos y nada más llega ahí (una vía de OSM partida en dos,
	# o la ruta que sigue por una vía) no se cortan la bionda la una a la otra (sí si la valla se mete en su asfalto)
	var extremos := {}
	for li in out.size():
		var c: PackedVector3Array = out[li]["c"]
		for p in [c[0], c[c.size() - 1]]:
			var q := Vector2i(roundi(p.x / 2.0), roundi(p.z / 2.0))
			if not extremos.has(q):
				extremos[q] = []
			extremos[q].append(li)
	for li in out.size():
		var c: PackedVector3Array = out[li]["c"]
		for p in [c[0], c[c.size() - 1]]:
			var q := Vector2i(roundi(p.x / 2.0), roundi(p.z / 2.0))
			var junto := {}
			for dx in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					for o in extremos.get(q + Vector2i(dx, dz), []):
						var co: PackedVector3Array = out[o]["c"]
						if co[0].distance_to(p) < 1.5 or co[co.size() - 1].distance_to(p) < 1.5:
							junto[int(out[o]["id"])] = true
			junto.erase(int(out[li]["id"]))
			if junto.size() == 1:
				out[li]["sigue"][junto.keys()[0]] = true
	return out


## Trozos de streaming [{linea, lado, i0, i1, id, caja: Rect2}] de ≤ TROZO_M m por lado de cada calzada
static func piezas(_dir_datos: String, rutas: Array) -> Array:
	if rutas.is_empty() or Ajustes.superficie == null:
		return []
	_zona(rutas)
	return _piezas


static func _describir() -> Array:
	var out := []
	var n_paso := maxi(2, roundi(TROZO_M / PASO_POSTE))
	for li in _lineas.size():
		var c: PackedVector3Array = _lineas[li]["c"]
		var i0 := 0
		while i0 < c.size() - 1:
			var i1 := mini(i0 + n_paso, c.size() - 1)
			var mn := Vector2(INF, INF)
			var mx := Vector2(-INF, -INF)
			for i in range(i0, i1 + 1):
				mn = Vector2(minf(mn.x, c[i].x), minf(mn.y, c[i].z))
				mx = Vector2(maxf(mx.x, c[i].x), maxf(mx.y, c[i].z))
			for lado in [1, -1]:
				out.append({"linea": li, "lado": lado, "i0": i0, "i1": i1, "id": out.size(),
						"caja": Rect2(mn - Vector2(16, 16), mx - mn + Vector2(32, 32))})
			i0 = i1
	return out


## El choque de los trozos alrededor de p (± 40 m) ya calculado (aunque el streaming aún no los haya construido, o
## en pruebas que simulan sin dibujar). Coste: una consulta a la rejilla por paso; cada trozo se calcula una vez.
static func asegurar_choque(p: Vector3) -> void:
	if _piezas.is_empty():
		return
	for dx in [-40.0, 40.0]:
		for dz in [-40.0, 40.0]:
			var lista = _rejilla.get(Vector2i(floori((p.x + dx) / REJILLA), floori((p.z + dz) / REJILLA)))
			if lista == null:
				continue
			for k in lista:
				if not _hechas.has(k):
					_calcular(_piezas[k])


## Segmentos de otras calzadas (Superficie) que pueden tocar la valla de este trozo, con su huelgo, en una rejilla
## local de CELDA_LOCAL m (cada segmento en las celdas que alcanza con su semiancho + huelgo): por muestra se mira solo
## su celda. Las celdas de Superficie se recorren solo alrededor de las muestras (no la caja entera del trozo, que en
## una carretera en diagonal es casi toda vacía).
const CELDA_LOCAL := 16.0
static func _candidatos(sup: Superficie, ln: Dictionary, a: int, b: int) -> Dictionary:
	var c: PackedVector3Array = ln["c"]
	var hw: PackedFloat32Array = ln["hw"]
	var celdas_sup := {}
	var m := 6.0 + HUELGO_GLORIETA
	# una muestra de cada 2 (8 m) basta: las celdas de Superficie miden 40 m y el margen cubre el resto
	for i in range(a, b + 1, 2):
		var p := c[i]
		var mm := m + hw[i] + MARGEN      # los dos lados
		for dx in [-mm, mm]:
			for dz in [-mm, mm]:
				celdas_sup[Vector2i(floori((p.x + dx) / Superficie.CELDA), floori((p.z + dz) / Superficie.CELDA))] = true
	var vistos := {}
	var segs := []
	var rejilla := {}
	var propio := int(ln["id"])
	var sigue: Dictionary = ln["sigue"]
	for cs in celdas_sup:
		var lista = sup.celdas.get(cs)
		if lista == null:
			continue
		for k in lista:
			if vistos.has(k):
				continue
			vistos[k] = true
			var idk := sup.via[k]
			if idk == propio:
				continue
			var huelgo := HUELGO_CRUCE
			var huelgo_par := HUELGO_PARALELA
			if sigue.has(idk):
				huelgo = -0.3
				huelgo_par = -0.3
			elif sup.nombres[idk] == "Glorieta":
				huelgo = HUELGO_GLORIETA
				huelgo_par = HUELGO_GLORIETA
			var p := sup.a[k]
			var q := sup.b[k]
			var r := sup.semiancho[k] + huelgo
			if r <= 0.0:
				continue
			var dirs := Vector2(q.x - p.x, q.z - p.z)
			dirs = dirs.normalized() if dirs.length_squared() > 1e-6 else Vector2.ZERO
			var si := segs.size()
			segs.append([p, q, r, sup.semiancho[k] + huelgo_par, dirs])
			for gx in range(floori((minf(p.x, q.x) - r) / CELDA_LOCAL), floori((maxf(p.x, q.x) + r) / CELDA_LOCAL) + 1):
				for gz in range(floori((minf(p.z, q.z) - r) / CELDA_LOCAL), floori((maxf(p.z, q.z) + r) / CELDA_LOCAL) + 1):
					var g := Vector2i(gx, gz)
					if not rejilla.has(g):
						rejilla[g] = PackedInt32Array()
					rejilla[g].append(si)
	return {"segs": segs, "rejilla": rejilla}


static func _libre(p: Vector3, cand: Dictionary, t: Vector2) -> bool:
	var lista = cand["rejilla"].get(Vector2i(floori(p.x / CELDA_LOCAL), floori(p.z / CELDA_LOCAL)))
	if lista == null:
		return true
	var segs: Array = cand["segs"]
	for si in lista:
		var s: Array = segs[si]
		var q0: Vector3 = s[0]
		var q1: Vector3 = s[1]
		var abx := q1.x - q0.x
		var abz := q1.z - q0.z
		var l2 := abx * abx + abz * abz
		var u := 0.0
		if l2 > 1e-6:
			u = clampf(((p.x - q0.x) * abx + (p.z - q0.z) * abz) / l2, 0.0, 1.0)
		var dx := p.x - (q0.x + abx * u)
		var dz := p.z - (q0.z + abz * u)
		var r: float = s[2]
		if absf((s[4] as Vector2).dot(t)) >= 0.9:    # casi paralela: solo si la valla se mete en su asfalto
			r = s[3]
		if dx * dx + dz * dz < r * r and absf(q0.y + (q1.y - q0.y) * u - p.y) < 3.0:
			return false
	return true


## Derecha (horizontal, unitaria) del eje en la muestra i
static func _der(c: PackedVector3Array, i: int) -> Vector3:
	var t := c[mini(i + 1, c.size() - 1)] - c[maxi(i - 1, 0)]
	return Vector3(-t.z, 0.0, t.x).normalized()


## Huecos y tramos de una línea de valla: libre[i] para i en [a, b] (con los mismos criterios que los trozos vecinos)
static func huecos(libres: PackedByteArray, al_principio: bool, al_final: bool) -> PackedByteArray:
	var n := libres.size()
	var l := libres.duplicate()
	# cerrar huecos cortos entre dos tramos
	var i := 0
	while i < n:
		if l[i] == 0:
			var j := i
			while j < n and l[j] == 0:
				j += 1
			if i > 0 and j < n and j - i <= HUECO_MIN:
				for k in range(i, j):
					l[k] = 1
			i = j
		else:
			i += 1
	# quitar tramos cortos (solo los que se ven enteros en la ventana o tocan un extremo de verdad)
	i = 0
	while i < n:
		if l[i] == 1:
			var j := i
			while j < n and l[j] == 1:
				j += 1
			var entero := (i > 0 or al_principio) and (j < n or al_final)
			if entero and j - i < TRAMO_MIN:
				for k in range(i, j):
					l[k] = 0
			i = j
		else:
			i += 1
	return l


## Construye un trozo: postes cada ~PASO_POSTE m al borde de la calzada (ancho/2 + MARGEN), vallas entre ellos y
## abatimientos en los extremos de cada tramo
static func construir(pz: Dictionary) -> Node3D:
	_preparar()
	var raiz := Node3D.new()
	var r := _calcular(pz)
	if not r.is_empty():
		instanciar(raiz, r["vallas"], r["abat"], r["postes"])
	return raiz


## Huecos, vanos, abatimientos y postes de un trozo; la primera vez añade su cara de valla al choque
static func _calcular(pz: Dictionary) -> Dictionary:
	if _lineas.is_empty() or int(pz["linea"]) >= _lineas.size():
		return {}
	var ln: Dictionary = _lineas[int(pz["linea"])]
	var c: PackedVector3Array = ln["c"]
	var hw: PackedFloat32Array = ln["hw"]
	var pu: PackedByteArray = ln["puente"]
	var lado := float(pz["lado"])
	var i0: int = pz["i0"]
	var i1: int = pz["i1"]
	var ult := c.size() - 1
	var a := maxi(0, i0 - VENTANA)
	var b := mini(ult, i1 + VENTANA)
	# candidatos de los dos lados juntos (un trozo y su gemelo del otro lado se construyen casi siempre seguidos)
	var ck := "%d:%d" % [int(pz["linea"]), i0]
	var cand: Dictionary = _cand_cache.get(ck, {})
	if cand.is_empty():
		cand = _candidatos(Ajustes.superficie, ln, a, b)
		_cand_cache[ck] = cand
		if _cand_cache.size() > 64:
			_cand_cache.erase(_cand_cache.keys()[0])
	else:
		_cand_cache.erase(ck)
	var pos := PackedVector3Array()
	var hacia := PackedVector3Array()     # hacia la calzada (horizontal)
	var lib := PackedByteArray()
	for i in range(a, b + 1):
		var der := _der(c, i)
		var p := c[i] + der * lado * (hw[i] + MARGEN)
		pos.append(p)
		hacia.append(-der * lado)
		lib.append(1 if _libre(p, cand, Vector2(-der.z, der.x)) else 0)
	est["trozos"] += 1
	est["candidatos"] += (cand["segs"] as Array).size()
	est["muestras"] += lib.size()
	est["ocupadas"] += lib.count(0)
	lib = huecos(lib, a == 0, b == ult)
	var vallas := []
	var abat := []
	var postes := []
	var choque_nuevo := not _hechas.has(int(pz["id"]))
	_hechas[int(pz["id"])] = true
	var hasta := i1 if i1 < ult else ult + 1
	for i in range(i0, hasta):
		var k := i - a
		if lib[k] == 0:
			continue
		var empieza := k == 0 and a == 0 or (k > 0 and lib[k - 1] == 0)
		var acaba := (i == ult) or (k + 1 < lib.size() and lib[k + 1] == 0)
		var enterrado_ini := empieza and i > 0     # extremo de verdad (no el final de la calzada): abatimiento
		var enterrado_fin := acaba and i < ult
		if not enterrado_ini and not enterrado_fin:
			postes.append([pos[k], hacia[k], pu[i] == 1])
		if i < ult and lib[k + 1] == 1:
			var p := pos[k]
			var q := pos[k + 1]
			var sig_fin := (i + 1 == ult) or (k + 2 < lib.size() and lib[k + 2] == 0)
			if enterrado_ini:
				abat.append([p + hacia[k] * -ABRE - Vector3.UP * ALTO, q, hacia[k + 1]])
			elif sig_fin and i + 1 < ult:
				abat.append([p, q + hacia[k + 1] * -ABRE - Vector3.UP * ALTO, hacia[k]])
			else:
				vallas.append([p, q, hacia[k]])
				if choque_nuevo:
					var h := (hacia[k] + hacia[k + 1]).normalized()
					choque_vivo.anadir(p + hacia[k] * 0.23, q + hacia[k + 1] * 0.23, Vector2(h.x, h.z))
	return {"vallas": vallas, "abat": abat, "postes": postes}


## Transformación de un vano de bionda de p a q con la onda mirando a `hacia` (horizontal, hacia la calzada)
static func vano(p: Vector3, q: Vector3, hacia: Vector3) -> Transform3D:
	var x := hacia.normalized()
	var z := q - p
	# la malla se extruye en +Z con la onda en +X: si +X no cae hacia la calzada al recorrer p→q, se recorre q→p
	var zh := Vector3(z.x, 0.0, z.z)
	if Vector3.UP.cross(zh).dot(x) < 0.0:
		return Transform3D(Basis(x, Vector3.UP, p - q), q)
	return Transform3D(Basis(x, Vector3.UP, z), p)


## Nodos de un trozo: [vallas [p, q, hacia]], [abatimientos [p, q, hacia]], [postes [p, hacia, puente]]
static func instanciar(raiz: Node3D, vallas: Array, abat: Array, postes: Array) -> void:
	_preparar()
	var grupos := [[vallas, _malla_valla, DIST_VISIBLE], [abat, _malla_valla, DIST_VISIBLE], [postes, _malla_poste, DIST_POSTES]]
	for gi in grupos.size():
		var lista: Array = grupos[gi][0]
		if lista.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = grupos[gi][1]
		mm.instance_count = lista.size()
		# todas las transformaciones de una vez (buffer de 12 floats por instancia: las 3 filas de la matriz 3×4)
		var buf := PackedFloat32Array()
		buf.resize(lista.size() * 12)
		for k in lista.size():
			var e: Array = lista[k]
			var tr: Transform3D
			if gi < 2:
				tr = vano(e[0], e[1], e[2])
			else:
				var x: Vector3 = e[1]
				var bas := Basis(x, Vector3.UP, x.cross(Vector3.UP))
				var o: Vector3 = e[0]
				if e[2]:     # en un puente el poste no baja por debajo del tablero
					bas.y *= 0.58
					o += Vector3.UP * 0.306
				tr = Transform3D(bas, o)
			var j := k * 12
			var bx := tr.basis.x
			var by := tr.basis.y
			var bz := tr.basis.z
			buf[j] = bx.x; buf[j + 1] = by.x; buf[j + 2] = bz.x; buf[j + 3] = tr.origin.x
			buf[j + 4] = bx.y; buf[j + 5] = by.y; buf[j + 6] = bz.y; buf[j + 7] = tr.origin.y
			buf[j + 8] = bx.z; buf[j + 9] = by.z; buf[j + 10] = bz.z; buf[j + 11] = tr.origin.z
		mm.buffer = buf
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.material_override = _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = grupos[gi][2]
		raiz.add_child(mi)


static func material() -> StandardMaterial3D:
	_preparar()
	return _mat


static func malla_valla() -> ArrayMesh:
	_preparar()
	return _malla_valla


static func malla_poste() -> ArrayMesh:
	_preparar()
	return _malla_poste


static func _preparar() -> void:
	if _mat != null:
		return
	_mat = StandardMaterial3D.new()
	# acero galvanizado: gris medio, sin metal (con metal reflejaba el cielo y se veía blanco azulado, medido en las fotos)
	_mat.albedo_color = Color(0.38, 0.39, 0.395)
	_mat.metallic = 0.0
	_mat.metallic_specular = 0.25
	_mat.roughness = 0.7
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED      # chapa fina: se ve por las dos caras
	# bionda de doble onda (perfil W, 31 cm de alto, ~8 cm de fondo), extruida 1 m en Z (la instancia la estira);
	# las ondas miran a la calzada (+X local) y van 15 cm por delante del poste (separador)
	var perfil := [Vector2(0.15, ALTO), Vector2(0.20, ALTO - 0.02), Vector2(0.23, ALTO - 0.055), Vector2(0.23, ALTO - 0.10),
			Vector2(0.17, ALTO - 0.155), Vector2(0.23, ALTO - 0.21), Vector2(0.23, ALTO - 0.255), Vector2(0.20, ALTO - 0.29),
			Vector2(0.15, ALTO - 0.31)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in perfil.size() - 1:
		var p0: Vector2 = perfil[i]
		var p1: Vector2 = perfil[i + 1]
		var t := (p1 - p0).normalized()
		var nrm := Vector3(-t.y, t.x, 0.0)    # normal hacia +X (hacia la calzada)
		if nrm.x < 0.0:
			nrm = -nrm
		var v := [Vector3(p0.x, p0.y, 0.0), Vector3(p1.x, p1.y, 0.0), Vector3(p1.x, p1.y, 1.0), Vector3(p0.x, p0.y, 1.0)]
		for j in [0, 1, 2, 0, 2, 3]:
			st.set_normal(nrm)
			st.add_vertex(v[j])
	_malla_valla = st.commit()
	# poste: perfil en C (caja de 10 × 6 cm) desde BAJO_SUELO bajo la calzada hasta el canto, con su separador
	# (taco de 6 × 14 cm entre el poste y la onda, a la altura de la bionda)
	_malla_poste = ArrayMesh.new()
	var stp := SurfaceTool.new()
	stp.begin(Mesh.PRIMITIVE_TRIANGLES)
	_caja(stp, Vector3(0.0, -BAJO_SUELO, -0.03), Vector3(0.10, ALTO - 0.02, 0.03))
	_caja(stp, Vector3(0.10, ALTO - 0.24, -0.035), Vector3(0.16, ALTO - 0.07, 0.035))
	_malla_poste = stp.commit()


static func _caja(st: SurfaceTool, mn: Vector3, mx: Vector3) -> void:
	var caras := [[Vector3.RIGHT, 0, 1, 2], [Vector3.LEFT, 0, 1, 2], [Vector3.UP, 1, 0, 2], [Vector3.DOWN, 1, 0, 2],
			[Vector3.BACK, 2, 0, 1], [Vector3.FORWARD, 2, 0, 1]]
	var c := (mn + mx) * 0.5
	var h := (mx - mn) * 0.5
	for cara in caras:
		var nrm: Vector3 = cara[0]
		var ej: int = cara[1]
		var u: int = cara[2]
		var w: int = cara[3]
		var q := []
		for s in [[-1, -1], [1, -1], [1, 1], [-1, 1]]:
			var p := c
			p[ej] += h[ej] * nrm[ej]
			p[u] += h[u] * s[0]
			p[w] += h[w] * s[1]
			q.append(p)
		for j in [0, 1, 2, 0, 2, 3]:
			st.set_normal(nrm)
			st.add_vertex(q[j])


## Choque: el Biondas que se va llenando con los trozos construidos (ver construir). Se llama al cargar la zona.
static func choque(_dir_datos: String, rutas: Array) -> Biondas:
	if rutas.is_empty() or Ajustes.superficie == null:
		return Biondas.new()
	_zona(rutas)
	return choque_vivo
