## Mundo por teselas, al estilo de BeamNG.Earth pero en nuestro juego: el suelo alrededor del coche se descarga y se
## monta por teselas con nivel de detalle según la distancia, hasta el horizonte (~70 km), en vez de una zona fija.
##  · Árbol de teselas cuadradas en UTM 30N con los tamaños de la rejilla EPSG:25830 del WMTS del PNOA: raíces de
##    39,1 km (nivel 9) y hojas de 152,9 m (nivel 17). Un nodo se divide si la cámara está a menos de K_DIVIDIR × su
##    lado; mientras sus 4 hijos no están listos se sigue dibujando él (nunca hay agujeros, ni grietas: cada malla
##    lleva faldón).
##  · Suelo: ortofoto PNOA (IGN/CNIG, CC BY 4.0) — cada nodo, 512 × 512 px compuestos de 4-6 teselas WMTS del nivel
##    siguiente (hojas: 0,30 m/px). En escritorio se comprime a DXT1 con mipmaps (≈ 170 KB de VRAM por nodo).
##  · Relieve: teselas terrarium de Mapterhorn (en España coincide con el MDT05 del IGN, LiDAR PNOA, a ±0,4 m:
##    comprobado el 6-nov-2026 en el puerto), remuestreadas de Web Mercator a la malla UTM del nodo.
##  · Carreteras integradas: el relieve se gradúa bajo nuestras calzadas (EarthCorredor): plano 12 cm bajo la rasante
##    y talud 2:3 hasta el terreno natural; la foto junto a la calzada se cambia por berma (shader).
##  · Descargas asíncronas con caché en disco (EarthFuentes); el montaje de cada malla y su textura va en hilos
##    (WorkerThreadPool); en el hilo principal solo se sube a la GPU (≤ SUBIDAS_FOTOGRAMA por fotograma).
##  · Se libera lo que deja de hacer falta (nodos fuera del árbol durante LIBERAR_TRAS s) y hay un tope de nodos.
class_name TerrenoStream
extends Node3D

const NIVEL_RAIZ := 9
const NIVEL_MAX := 17
const K_DIVIDIR := 1.1
const R_RAICES := 80000.0       # horizonte: más allá la bruma ya lo tapa todo (fog_depth_end 70 km)
const LIBERAR_TRAS := 4.0
const MAX_NODOS := 600
const HILOS := 3
const SUBIDAS_FOTOGRAMA := 3
const NIVEL_TEX_FINA := 14     # desde aquí, textura de 512 px con teselas del nivel siguiente
const Z_PRECISO := 15           # zoom de Mapterhorn para alturas exactas (coche, árboles): 1,8 m/px en el puerto
const R_PRECISO := 1700.0       # radio alrededor de la cámara con esas teselas en memoria
const MAX_RELIEVE_MEM := 72     # teselas de relieve descomprimidas en memoria (768 KB cada una)

var e0 := 0.0                   # origen UTM de las coordenadas del juego
var n0 := 0.0
var x0g := 0.0                  # origen del árbol de teselas en coordenadas del juego
var z0g := 0.0
var lat_ref := 40.0
var fuentes: EarthFuentes
var corredor: EarthCorredor
var shader: Shader
var detalle: Texture2D
var comprimir := true
var subidas := SUBIDAS_FOTOGRAMA
var hilos := HILOS
var _volcar := ""               # --mundo_volcar=carpeta: guarda las texturas compuestas (depuración)
var nodos := {}                 # Vector3i(nivel, col, fila) -> Dictionary
var _montar: Array = []         # nodos con los datos listos, por montar (en hilos)
var _tareas: Array = []         # [{id, nodo, res: Array}]
var _tareas_relieve: Array[int] = []
var _subir: Array = []          # resultados por subir a la GPU
var _relieve := {}              # Vector3i(z, x, y) -> PackedByteArray RGB (512 × 512 × 3) | vacío = sin dato
var _relieve_uso := {}          # Vector3i -> Time ticks del último uso
var _mutex := Mutex.new()
var _preciso_pedido := {}       # Vector3i -> true (pedidas para alturas exactas)
var cam_pos := Vector3.ZERO
var foco: Variant = null        # si no es null, se usa en vez de la cámara (carga inicial, antes de colocar la cámara)
var _ultima_sel := Vector3(INF, 0, INF)
var _t_sel := 0.0
var _necesarios := {}
var _claves_vivas := {}
var est := {"montados": 0, "us_montaje_total": 0, "us_montaje_max": 0, "us_subida_max": 0, "liberados": 0,
		"dibujados": 0, "por_nivel": {}, "t_inicio": 0}


func preparar(origen_utm: Array) -> void:
	name = "TerrenoStream"
	e0 = float(origen_utm[0])
	n0 = float(origen_utm[1])
	x0g = EarthGeo.WMTS_X0 - e0
	z0g = n0 - EarthGeo.ARBOL_Y0
	lat_ref = EarthGeo.utm_a_geo(e0, n0).y
	fuentes = EarthFuentes.new()
	add_child(fuentes)
	corredor = EarthCorredor.new()
	corredor.construir(Ajustes.rutas, Ajustes.vias, Ajustes.glorietas)
	shader = load("res://scripts/mundo_stream/terreno_stream.gdshader")
	if Ajustes.args.get("aniso", "1" if OS.has_feature("windows") else "0") == "1":
		var s := Shader.new()
		s.code = shader.code.replace("filter_linear_mipmap,", "filter_linear_mipmap_anisotropic,")
		shader = s
	detalle = Paisaje._ruido()
	comprimir = Ajustes.args.get("dxt", "1") == "1" and not OS.has_feature("web")
	_volcar = str(Ajustes.args.get("mundo_volcar", ""))
	subidas = int(Ajustes.args.get("mundo_subidas", str(SUBIDAS_FOTOGRAMA)))
	# tareas de baja prioridad y menos que núcleos: la compresión DXT reparte trabajo en el mismo grupo de hilos y espera
	# por él (con todos los hilos ocupados por teselas se quedaba bloqueado: visto con 4 hilos en 4 núcleos)
	hilos = clampi(int(Ajustes.args.get("mundo_hilos", str(HILOS))), 1, maxi(OS.get_processor_count() - 1, 1))
	if comprimir:
		# la primera compresión inicializa el compresor: en el hilo principal, una vez (varios hilos a la vez aquí
		# hacían caer el juego en las pruebas con OpenGL/llvmpipe)
		var prueba := Image.create(8, 8, true, Image.FORMAT_RGB8)
		var e: int = prueba.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
		comprimir = e == OK and prueba.is_compressed()
	est["t_inicio"] = Time.get_ticks_msec()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	# los hilos aún en marcha usan datos de este nodo: se espera a que acaben
	for t in _tareas:
		WorkerThreadPool.wait_for_task_completion(t["id"])
	for id in _tareas_relieve:
		WorkerThreadPool.wait_for_task_completion(id)
	_tareas.clear()
	_tareas_relieve.clear()


func _process(_d: float) -> void:
	if foco != null:
		actualizar(foco)
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	if cam.far < 75000.0:
		cam.far = 75000.0       # hasta el horizonte
	actualizar(cam.global_position)


# ---------------------------------------------------------------- geometría del árbol
func lado(nivel: int) -> float:
	return EarthGeo.lado(nivel)


func rect(k: Vector3i) -> Rect2:
	var t := lado(k.x)
	return Rect2(x0g + k.y * t, z0g + k.z * t, t, t)


func clave_en(nivel: int, x: float, z: float) -> Vector3i:
	var t := lado(nivel)
	return Vector3i(nivel, floori((x - x0g) / t), floori((z - z0g) / t))


func _dist(k: Vector3i, p: Vector3, nd: Dictionary) -> float:
	var r := rect(k)
	var dx := maxf(maxf(r.position.x - p.x, p.x - r.end.x), 0.0)
	var dz := maxf(maxf(r.position.y - p.z, p.z - r.end.y), 0.0)
	var dy := 0.0
	if nd.has("hmax"):
		dy = maxf(maxf(nd["hmin"] - p.y, p.y - nd["hmax"]), 0.0)
	return sqrt(dx * dx + dz * dz + dy * dy)


# ---------------------------------------------------------------- cada fotograma
func actualizar(camara: Vector3) -> void:
	cam_pos = camara
	_t_sel += get_process_delta_time()
	if fuentes == null:
		return
	if _t_sel > 0.25 or camara.distance_to(_ultima_sel) > 20.0:
		_seleccionar()
	_lanzar_montajes()
	_recoger_montajes()


func _seleccionar() -> void:
	_t_sel = 0.0
	_ultima_sel = cam_pos
	var dibujar := {}
	_necesarios = {}
	_claves_vivas = {}
	var t9 := lado(NIVEL_RAIZ)
	var c0 := floori((cam_pos.x - R_RAICES - x0g) / t9)
	var c1 := floori((cam_pos.x + R_RAICES - x0g) / t9)
	var f0 := floori((cam_pos.z - R_RAICES - z0g) / t9)
	var f1 := floori((cam_pos.z + R_RAICES - z0g) / t9)
	for c in range(c0, c1 + 1):
		for f in range(f0, f1 + 1):
			var k := Vector3i(NIVEL_RAIZ, c, f)
			var nd := _nodo(k)
			if _dist(k, cam_pos, nd) < R_RAICES:
				_visitar(k, dibujar, false)
	var ahora := Time.get_ticks_msec() * 0.001
	var dib := 0
	var por_nivel := {}
	var borrar: Array = []
	for k in nodos:
		var nd: Dictionary = nodos[k]
		var vis := dibujar.has(k)
		if nd.get("inst") != null:
			(nd["inst"] as MeshInstance3D).visible = vis
		if vis:
			dib += 1
			por_nivel[k.x] = por_nivel.get(k.x, 0) + 1
		if _necesarios.has(k):
			nd["visto"] = ahora
		elif ahora - float(nd.get("visto", ahora)) > LIBERAR_TRAS and int(nd["estado"]) != 2:
			borrar.append(k)
	# tope de nodos: si aun así hay demasiados, fuera los que llevan más tiempo sin hacer falta
	if nodos.size() - borrar.size() > MAX_NODOS:
		var resto: Array = []
		for k in nodos:
			if not _necesarios.has(k) and int(nodos[k]["estado"]) != 2 and not borrar.has(k):
				resto.append(k)
		resto.sort_custom(func(a, b): return float(nodos[a].get("visto", 0.0)) < float(nodos[b].get("visto", 0.0)))
		for k in resto.slice(0, nodos.size() - borrar.size() - MAX_NODOS):
			borrar.append(k)
	for k in borrar:
		_liberar(k)
	est["dibujados"] = dib
	est["por_nivel"] = por_nivel
	_pedir_precisas()
	if fuentes.en_cola() > 24:
		fuentes.podar_cola(func(clave: String) -> bool: return _claves_vivas.has(clave))


func _visitar(k: Vector3i, dibujar: Dictionary, solo_pedir: bool) -> void:
	_necesarios[k] = true
	var nd := _nodo(k)
	var d := _dist(k, cam_pos, nd)
	if int(nd["estado"]) == 0:
		_pedir(k, nd, d)
	elif int(nd["estado"]) == 1:
		for c in nd["claves"]:
			_claves_vivas[c] = true
	if k.x < NIVEL_MAX and d < K_DIVIDIR * lado(k.x):
		var hijos := [Vector3i(k.x + 1, 2 * k.y, 2 * k.z), Vector3i(k.x + 1, 2 * k.y + 1, 2 * k.z),
				Vector3i(k.x + 1, 2 * k.y, 2 * k.z + 1), Vector3i(k.x + 1, 2 * k.y + 1, 2 * k.z + 1)]
		var listos := true
		for h in hijos:
			var nh := _nodo(h)
			if int(nh["estado"]) != 3:
				listos = false
		var usar_hijos := listos or int(nd["estado"]) != 3
		for h in hijos:
			_visitar(h, dibujar, solo_pedir or not usar_hijos)
		if usar_hijos:
			return
	if not solo_pedir and int(nd["estado"]) == 3:
		dibujar[k] = true


func _nodo(k: Vector3i) -> Dictionary:
	if not nodos.has(k):
		nodos[k] = {"k": k, "estado": 0, "visto": Time.get_ticks_msec() * 0.001}
	return nodos[k]


# ---------------------------------------------------------------- descargas de un nodo
func _celdas(nivel: int) -> int:
	return 64 if nivel >= 16 else 32


func _zoom_relieve(nivel: int) -> int:
	var paso := lado(nivel) / _celdas(nivel)
	var z := clampi(ceili(log(EarthGeo.m_px_merc(0, lat_ref) / paso) / log(2.0)), 4, 17)
	if nivel >= 16:
		z = maxi(z, Z_PRECISO)
	return z


func _teselas_relieve(r: Rect2, z: int) -> Array:
	var lista: Array = []
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in [r.position, Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), r.end]:
		var m := EarthGeo.geo_a_merc(EarthGeo.utm_a_geo(p.x + e0, n0 - p.y), z)
		mn = mn.min(m)
		mx = mx.max(m)
	for tx in range(floori((mn.x - 2.0) / 512.0), floori((mx.x + 2.0) / 512.0) + 1):
		for ty in range(floori((mn.y - 2.0) / 512.0), floori((mx.y + 2.0) / 512.0) + 1):
			lista.append(Vector3i(z, tx, ty))
	return lista


func _pedir(k: Vector3i, nd: Dictionary, d: float) -> void:
	var r := rect(k)
	# de cerca (nivel ≥ 14) teselas WMTS del nivel siguiente: 2 × 2 por nodo (2-3 filas por el desfase en Y), 512 px;
	# más lejos, las del mismo nivel: 1 × 1-2 por nodo, 256 px (la mitad de descargas y de VRAM donde no se nota)
	var nw := k.x + 1 if k.x >= NIVEL_TEX_FINA else k.x
	var tw := lado(nw)
	var nt := roundi(r.size.x / tw)
	var y0w: float = EarthGeo.WMTS_Y0[nw]
	var e_min := r.position.x + e0
	var n_max := n0 - r.position.y
	var n_min := n0 - r.end.y
	var c0 := roundi((e_min - EarthGeo.WMTS_X0) / tw)
	var ff := (y0w - n_max) / tw
	var f0 := floori(ff + 1e-6)
	var f1 := floori((y0w - n_min) / tw - 1e-6)
	var orto: Array = []
	for c in range(c0, c0 + nt):
		for f in range(f0, f1 + 1):
			orto.append([nw, c, f, 0, roundi((f - ff) * 256.0)])
	for o in orto:
		o[3] = (int(o[1]) - c0) * 256
	var z := _zoom_relieve(k.x)
	var rel := _teselas_relieve(r, z)
	nd["estado"] = 1
	nd["tex"] = 256 * nt
	nd["orto"] = orto
	nd["rel"] = rel
	nd["bytes_orto"] = {}
	nd["bytes_rel"] = {}
	nd["pend"] = orto.size() + rel.size()
	nd["cancelado"] = false
	nd["prio"] = k.x * 20000.0 + minf(d, 19999.0)
	nd["claves"] = []
	for o in orto:
		var clave := "o:%d/%d/%d" % [o[0], o[1], o[2]]
		nd["claves"].append(clave)
		_claves_vivas[clave] = true
		fuentes.pedir(clave, EarthFuentes.URL_PNOA % [o[0], o[2], o[1]], EarthFuentes.ruta_pnoa(o[0], o[1], o[2]), nd["prio"],
				_llegada.bind(nd, "bytes_orto", Vector2i(o[1], o[2])))
	for t in rel:
		var clave := "r:%d/%d/%d" % [t.x, t.y, t.z]
		nd["claves"].append(clave)
		_claves_vivas[clave] = true
		fuentes.pedir(clave, EarthFuentes.URL_RELIEVE % [t.x, t.y, t.z], EarthFuentes.ruta_relieve(t.x, t.y, t.z), nd["prio"],
				_llegada.bind(nd, "bytes_rel", t))


func _llegada(bytes: Variant, nd: Dictionary, campo: String, clave: Variant) -> void:
	if nd.get("borrado", false) or int(nd["estado"]) != 1:
		return
	if bytes == null:
		nd["cancelado"] = true
	else:
		nd[campo][clave] = bytes
	nd["pend"] -= 1
	if nd["pend"] <= 0:
		if nd["cancelado"]:
			nd["estado"] = 0       # se volverá a pedir si vuelve a hacer falta
		else:
			nd["estado"] = 2
			_montar.append(nd)


# ---------------------------------------------------------------- montaje en hilos
func _lanzar_montajes() -> void:
	if _montar.size() > 1:
		_montar.sort_custom(func(a, b): return a["prio"] < b["prio"])
	while _tareas.size() < hilos and not _montar.is_empty():
		var nd: Dictionary = _montar.pop_front()
		if nd.get("borrado", false):
			continue
		var res := [null]
		var datos := {"k": nd["k"], "rect": rect(nd["k"]), "orto": nd["orto"], "bytes_orto": nd["bytes_orto"],
				"rel": nd["rel"], "bytes_rel": nd["bytes_rel"], "celdas": _celdas(nd["k"].x), "tex": nd["tex"]}
		var id := WorkerThreadPool.add_task(_montar_nodo.bind(datos, res), false, "tesela")
		_tareas.append({"id": id, "nodo": nd, "res": res})


func _recoger_montajes() -> void:
	var qr: Array[int] = []
	for id in _tareas_relieve:
		if WorkerThreadPool.is_task_completed(id):
			WorkerThreadPool.wait_for_task_completion(id)
		else:
			qr.append(id)
	_tareas_relieve = qr
	var quedan: Array = []
	for t in _tareas:
		if WorkerThreadPool.is_task_completed(t["id"]):
			WorkerThreadPool.wait_for_task_completion(t["id"])
			_subir.append([t["nodo"], t["res"][0]])
		else:
			quedan.append(t)
	_tareas = quedan
	var n := 0
	while not _subir.is_empty() and n < subidas:
		var e: Array = _subir.pop_front()
		var nd: Dictionary = e[0]
		var r: Variant = e[1]
		if nd.get("borrado", false):
			continue
		if r == null:
			nd["estado"] = 0
			continue
		var t0 := Time.get_ticks_usec()
		_crear_instancia(nd, r)
		est["us_subida_max"] = maxi(est["us_subida_max"], Time.get_ticks_usec() - t0)
		n += 1
	if not _subir.is_empty() or not _tareas.is_empty():
		_t_sel = maxf(_t_sel, 0.2)    # lo recién montado se tiene en cuenta enseguida


func _crear_instancia(nd: Dictionary, r: Dictionary) -> void:
	var malla := ArrayMesh.new()
	malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, r["arrays"])
	var tex := ImageTexture.create_from_image(r["img"])
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("orto", tex)
	mat.set_shader_parameter("detalle", detalle)
	if Ajustes.args.get("mundo_arcen", "1") == "0":
		mat.set_shader_parameter("arcen", 0.0)
	if Ajustes.args.has("mundo_depurar"):
		mat.set_shader_parameter("depurar", int(Ajustes.args["mundo_depurar"]))
	malla.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = malla
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	nd["inst"] = mi
	nd["alturas"] = r["alturas"]
	nd["hmin"] = r["hmin"]
	nd["hmax"] = r["hmax"]
	nd["estado"] = 3
	nd.erase("bytes_orto")
	nd.erase("bytes_rel")
	est["montados"] += 1
	est["us_montaje_total"] += int(r["us"])
	est["us_montaje_max"] = maxi(est["us_montaje_max"], int(r["us"]))


func _liberar(k: Vector3i) -> void:
	var nd: Dictionary = nodos[k]
	nd["borrado"] = true
	if nd.get("inst") != null:
		(nd["inst"] as Node).queue_free()
		nd["inst"] = null
	nodos.erase(k)
	est["liberados"] += 1


## En un hilo: alturas (relieve remuestreado + graduado bajo las carreteras), normales, malla con faldón y textura.
func _montar_nodo(d: Dictionary, res: Array) -> void:
	var t0 := Time.get_ticks_usec()
	var k: Vector3i = d["k"]
	var r: Rect2 = d["rect"]
	var nc: int = d["celdas"]
	var nv := nc + 1
	var paso := r.size.x / nc
	# relieve: teselas descomprimidas (compartidas entre nodos)
	var tiles := {}
	for t in d["rel"]:
		tiles[Vector2i(t.y, t.z)] = _rgb_relieve(t, d["bytes_rel"].get(t, PackedByteArray()))
	var z: int = (d["rel"][0] as Vector3i).x if not d["rel"].is_empty() else 12
	# rejilla de control 5 × 5 de la proyección UTM → píxel Mercator (interpolada; error < 1 cm en un nodo)
	var ctrl := PackedVector2Array()
	ctrl.resize(25)
	for j in 5:
		for i in 5:
			var x := r.position.x + r.size.x * i / 4.0
			var zz := r.position.y + r.size.y * j / 4.0
			ctrl[j * 5 + i] = EarthGeo.geo_a_merc(EarthGeo.utm_a_geo(x + e0, n0 - zz), z)
	var h := PackedFloat32Array()
	h.resize(nv * nv)
	var arcen := PackedFloat32Array()
	arcen.resize(nv * nv)
	var hmin := INF
	var hmax := -INF
	var sin_dato := 0
	var con_corredor := k.x >= 12
	for j in nv:
		var fj := float(j) / nc * 4.0
		var cj := mini(int(fj), 3)
		var tj := fj - cj
		for i in nv:
			var fi := float(i) / nc * 4.0
			var ci := mini(int(fi), 3)
			var ti := fi - ci
			var m := ctrl[cj * 5 + ci].lerp(ctrl[cj * 5 + ci + 1], ti).lerp(ctrl[(cj + 1) * 5 + ci].lerp(ctrl[(cj + 1) * 5 + ci + 1], ti), tj)
			var hv := _muestra(tiles, m)
			if is_nan(hv):
				hv = 0.0
				sin_dato += 1
			var x := r.position.x + i * paso
			var zz := r.position.y + j * paso
			var q := j * nv + i
			if con_corredor:
				var g := corredor.graduar(hv, x, zz, paso)
				hv = g.x
				arcen[q] = g.y
			h[q] = hv
			hmin = minf(hmin, hv)
			hmax = maxf(hmax, hv)
	# malla: vértices + faldón (borde repetido más abajo) para tapar cualquier grieta con el vecino de otro nivel
	var falda := 2.0 + paso * 0.5
	var nb := nc * 4
	var verts := PackedVector3Array()
	var nor := PackedVector3Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	verts.resize(nv * nv + nb)
	nor.resize(nv * nv + nb)
	uv.resize(nv * nv + nb)
	col.resize(nv * nv + nb)
	for j in nv:
		for i in nv:
			var q := j * nv + i
			var hl := h[j * nv + maxi(i - 1, 0)]
			var hr := h[j * nv + mini(i + 1, nc)]
			var hu := h[maxi(j - 1, 0) * nv + i]
			var hd := h[mini(j + 1, nc) * nv + i]
			var dx := paso * float(mini(i + 1, nc) - maxi(i - 1, 0))
			var dz := paso * float(mini(j + 1, nc) - maxi(j - 1, 0))
			verts[q] = Vector3(r.position.x + i * paso, h[q], r.position.y + j * paso)
			nor[q] = Vector3((hl - hr) / dx, 1.0, (hu - hd) / dz).normalized()
			uv[q] = Vector2(float(i) / nc, float(j) / nc)
			col[q] = Color(arcen[q], 0.0, 0.0, 1.0)
	# borde en orden (perímetro): índices de los vértices del borde
	var borde := PackedInt32Array()
	for i in nc: borde.append(i)                       # arriba
	for j in nc: borde.append(j * nv + nc)             # derecha
	for i in nc: borde.append(nc * nv + nc - i)        # abajo
	for j in nc: borde.append((nc - j) * nv)           # izquierda
	for b in nb:
		var q := nv * nv + b
		var s := borde[b]
		verts[q] = verts[s] - Vector3(0.0, falda, 0.0)
		nor[q] = nor[s]
		uv[q] = uv[s]
		col[q] = col[s]
	var idx := PackedInt32Array()
	idx.resize(nc * nc * 6 + nb * 6)
	var c := 0
	for j in nc:
		for i in nc:
			var q := j * nv + i
			idx[c] = q; idx[c + 1] = q + 1; idx[c + 2] = q + nv
			idx[c + 3] = q + 1; idx[c + 4] = q + nv + 1; idx[c + 5] = q + nv
			c += 6
	for b in nb:
		var a1 := borde[b]
		var a2 := borde[(b + 1) % nb]
		var b1 := nv * nv + b
		var b2 := nv * nv + (b + 1) % nb
		idx[c] = a1; idx[c + 1] = b1; idx[c + 2] = a2
		idx[c + 3] = a2; idx[c + 4] = b1; idx[c + 5] = b2
		c += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = idx
	# textura: las teselas WMTS pegadas con su desfase (el nodo mide exactamente 512 píxeles del nivel siguiente)
	var img := Image.create(d["tex"], d["tex"], false, Image.FORMAT_RGB8)
	img.fill(Color(0.42, 0.42, 0.36))
	for o in d["orto"]:
		var b: PackedByteArray = d["bytes_orto"].get(Vector2i(o[1], o[2]), PackedByteArray())
		if b.is_empty():
			continue
		var ti := Image.new()
		if ti.load_jpg_from_buffer(b) != OK:
			continue
		if ti.get_format() != Image.FORMAT_RGB8:
			ti.convert(Image.FORMAT_RGB8)
		var ox: int = o[3]
		var oy: int = o[4]
		var src := Rect2i(0, 0, ti.get_width(), ti.get_height())
		if oy < 0:
			src.position.y = -oy
			src.size.y += oy
			oy = 0
		if src.size.y > 0:
			img.blit_rect(ti, src, Vector2i(ox, oy))
	if _volcar != "" and k.x >= 16:
		img.save_jpg(_volcar + "/tex_%d_%d_%d.jpg" % [k.x, k.y, k.z])
	img.generate_mipmaps()
	if comprimir:
		img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
	res[0] = {"arrays": arrays, "img": img, "alturas": h, "hmin": hmin, "hmax": hmax, "us": Time.get_ticks_usec() - t0,
			"sin_dato": sin_dato}


## Altura terrarium (bilineal) en el píxel Mercator global m; NAN si falta la tesela
func _muestra(tiles: Dictionary, m: Vector2) -> float:
	var px := m.x - 0.5
	var py := m.y - 0.5
	var x0 := floori(px)
	var y0 := floori(py)
	var fx := px - x0
	var fy := py - y0
	var a := _px(tiles, x0, y0)
	var b := _px(tiles, x0 + 1, y0)
	var c := _px(tiles, x0, y0 + 1)
	var e := _px(tiles, x0 + 1, y0 + 1)
	return lerpf(lerpf(a, b, fx), lerpf(c, e, fx), fy)


func _px(tiles: Dictionary, x: int, y: int) -> float:
	var t: PackedByteArray = tiles.get(Vector2i(x >> 9, y >> 9), PackedByteArray())
	if t.is_empty():
		return NAN
	var o := (((y & 511) << 9) + (x & 511)) * 3
	return t[o] * 256.0 + t[o + 1] + t[o + 2] / 256.0 - 32768.0


## Tesela de relieve descomprimida a RGB8 (compartida; se descomprime una vez)
func _rgb_relieve(t: Vector3i, webp: PackedByteArray) -> PackedByteArray:
	_mutex.lock()
	var ya: Variant = _relieve.get(t)
	_relieve_uso[t] = Time.get_ticks_msec()
	_mutex.unlock()
	if ya != null:
		return ya
	var rgb := PackedByteArray()
	if not webp.is_empty():
		var im := Image.new()
		if im.load_webp_from_buffer(webp) == OK:
			if im.get_format() != Image.FORMAT_RGB8:
				im.convert(Image.FORMAT_RGB8)
			if im.get_width() == 512 and im.get_height() == 512:
				rgb = im.get_data()
	_mutex.lock()
	_relieve[t] = rgb
	_relieve_uso[t] = Time.get_ticks_msec()
	if _relieve.size() > MAX_RELIEVE_MEM:
		var viejo := t
		var tv := INF
		for kk in _relieve_uso:
			if _relieve_uso[kk] < tv:
				tv = _relieve_uso[kk]
				viejo = kk
		_relieve.erase(viejo)
		_relieve_uso.erase(viejo)
	_mutex.unlock()
	return rgb


# ---------------------------------------------------------------- alturas exactas (coche fuera del asfalto, árboles)
func _pedir_precisas() -> void:
	var r := Rect2(cam_pos.x - R_PRECISO, cam_pos.z - R_PRECISO, 2.0 * R_PRECISO, 2.0 * R_PRECISO)
	for t in _teselas_relieve(r, Z_PRECISO):
		var clave := "r:%d/%d/%d" % [t.x, t.y, t.z]
		_mutex.lock()
		var hay := _relieve.has(t)
		if hay:
			_relieve_uso[t] = Time.get_ticks_msec()
		_mutex.unlock()
		if hay:
			continue
		_claves_vivas[clave] = true
		if _preciso_pedido.has(t):
			continue
		_preciso_pedido[t] = true
		var tt: Vector3i = t
		fuentes.pedir(clave, EarthFuentes.URL_RELIEVE % [t.x, t.y, t.z], EarthFuentes.ruta_relieve(t.x, t.y, t.z), 15000.0,
				func(b: Variant) -> void:
					_preciso_pedido.erase(tt)
					if b != null:
						_tareas_relieve.append(WorkerThreadPool.add_task(func() -> void: _rgb_relieve(tt, b), false, "relieve")))


## Altura del terreno (con la graduación bajo las carreteras) en x, z; NAN si aún no está en memoria
func altura(x: float, z: float) -> float:
	var m := EarthGeo.geo_a_merc(EarthGeo.utm_a_geo(x + e0, n0 - z), Z_PRECISO)
	var tiles := {}
	var tx := floori((m.x - 0.5) / 512.0)
	var ty := floori((m.y - 0.5) / 512.0)
	_mutex.lock()
	for dx in 2:
		for dy in 2:
			var t := Vector3i(Z_PRECISO, tx + dx, ty + dy)
			if _relieve.has(t):
				tiles[Vector2i(tx + dx, ty + dy)] = _relieve[t]
	_mutex.unlock()
	var h := _muestra(tiles, m)
	if is_nan(h):
		return NAN
	return corredor.graduar(h, x, z, 1.0).x


## ¿Están en memoria las alturas exactas de todo el rectángulo?
func alturas_listas(r: Rect2) -> bool:
	for t in _teselas_relieve(r, Z_PRECISO):
		_mutex.lock()
		var hay := _relieve.has(t) and not (_relieve[t] as PackedByteArray).is_empty()
		_mutex.unlock()
		if not hay:
			return false
	return true


## Nodos que hacen falta y aún no están montados (0 = todo lo que se ve desde aquí está listo)
func pendientes() -> int:
	var n := 0
	for k in _necesarios:
		if nodos.has(k) and int(nodos[k]["estado"]) != 3:
			n += 1
	return n + _subir.size()


func resumen() -> Dictionary:
	var vivos := 0
	for k in nodos:
		if int(nodos[k]["estado"]) == 3:
			vivos += 1
	var e := est.duplicate()
	e["nodos"] = nodos.size()
	var pe := {}
	for k in nodos:
		var cl := "%d_%d" % [k.x, int(nodos[k]["estado"])]
		pe[cl] = pe.get(cl, 0) + 1
	e["nivel_estado"] = pe
	e["cam"] = [roundi(cam_pos.x), roundi(cam_pos.y), roundi(cam_pos.z)]
	e["tareas"] = _tareas.size()
	e["por_montar"] = _montar.size()
	e["por_subir"] = _subir.size()
	e["en_cola_red"] = fuentes.en_cola()
	e["montados_vivos"] = vivos
	e["pendientes"] = pendientes()
	e["descargas"] = fuentes.est.duplicate()
	e["cache_mb"] = snappedf(fuentes.megas_cache(), 0.1)
	e["relieve_mem"] = _relieve.size()
	e["us_montaje_medio"] = int(est["us_montaje_total"] / maxi(est["montados"], 1))
	return e
