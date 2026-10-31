## Mapa abierto: carga del disco las teselas de 2 km alrededor del coche en hilos (WorkerThreadPool) y las descarga
## al alejarse, sin pantallas de carga. Memoria plana: solo existen las teselas de la ventana (5 × 5 como mucho).
##  · Anillo 0–1 (3 × 3 teselas, ≥ 2 km alrededor): terreno con todo su detalle (10 m junto a la red, 25 m lejos de ella),
##    calzadas con taludes y marcas viales.
##  · Anillo 2 (hasta 5 × 5, ≥ 4 km): terreno a la mitad de resolución y calzadas sin marcas.
##  · Más allá: el horizonte (relieve de toda la región a 200 m, siempre por debajo del terreno fino).
class_name MaMundo
extends Node3D

const RADIO := 2                 # anillos de teselas cargadas alrededor de la del coche
const RADIO_FUERA := 3           # se descargan al pasar de aquí (histéresis)
const HILOS := 2                 # teselas construyéndose a la vez
const DIST_MARCAS := 500.0
const FALDON := 8.0              # m de faldón vertical en el borde de cada tesela (tapa grietas entre resoluciones)

var datos: MaDatos
var sup := MaSuperficie.new()
var mat_terreno := StandardMaterial3D.new()
var mat_asfalto := StandardMaterial3D.new()
var mat_asfalto_v := StandardMaterial3D.new()   # autopistas y autovías: un poco más oscuro (aglomerado reciente)
var mat_marca := StandardMaterial3D.new()
var mat_talud := StandardMaterial3D.new()
var mat_tunel := StandardMaterial3D.new()
var mat_edificio := StandardMaterial3D.new()
var mat_bionda := StandardMaterial3D.new()
var entorno: Environment
var sh_terreno: Shader = preload("res://scripts/ma_terreno.gdshader")
var ruido: NoiseTexture2D
var con_orto := true
var malla_conifera: ArrayMesh
var malla_frondosa: ArrayMesh
const DIST_ARBOLES := 1300.0
var activas := {}                # Vector2i -> {nodo, lod}
var pendientes := {}             # Vector2i -> lod en construcción
var _tareas := {}                # id de tarea -> Vector2i
var _ultima := Vector2i(1 << 30, 0)
var est := {"cargadas": 0, "descargadas": 0, "ms_max": 0.0, "ms_total": 0.0}
var _cerrando := false


## Fila del menú (solo escritorio y si están los datos): botón para el mapa abierto de la Comunidad de Madrid.
## Usa la velocidad, el tráfico, el piloto y la cámara elegidos en el propio menú.
static func fila_menu(menu: Node) -> HBoxContainer:
	var f := HBoxContainer.new()
	if OS.has_feature("web") or not FileAccess.file_exists("res://datos/madrid/mundo.json"):
		f.visible = false
		return f
	var l := Label.new()
	l.text = "Mapa abierto:"
	l.custom_minimum_size.x = 140
	f.add_child(l)
	var b := Button.new()
	b.text = "  Comunidad de Madrid entera (todas las carreteras interurbanas)  "
	b.pressed.connect(func() -> void:
		Ajustes.velocidad = menu.vel.value
		Ajustes.trafico = menu.traf.value / 100.0
		Ajustes.piloto = menu.chk_piloto.button_pressed
		Ajustes.adaptar_curvas = menu.chk_curvas.button_pressed
		Ajustes.piloto_limites = menu.chk_piloto_lim.button_pressed
		Ajustes.camara = menu.camara.selected
		menu.get_tree().change_scene_to_file("res://escenas/madrid.tscn"))
	f.add_child(b)
	return f


func preparar(d: MaDatos) -> void:
	datos = d
	sup.tesela = d.tesela
	Ajustes.superficie = sup
	mat_terreno.vertex_color_use_as_albedo = true
	mat_terreno.roughness = 1.0
	mat_asfalto.albedo_color = Color(0.21, 0.21, 0.2)
	mat_asfalto.roughness = 0.95
	mat_asfalto.metallic_specular = 0.15
	mat_asfalto_v.albedo_color = Color(0.17, 0.17, 0.17)
	mat_asfalto_v.roughness = 0.92
	mat_asfalto_v.metallic_specular = 0.15
	mat_talud.albedo_color = Color(0.42, 0.38, 0.27)
	mat_talud.roughness = 1.0
	mat_marca.albedo_color = Color(0.92, 0.92, 0.9)
	mat_marca.roughness = 0.6
	mat_tunel.albedo_color = Color(0.32, 0.31, 0.29)
	mat_tunel.roughness = 1.0
	mat_tunel.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat_bionda.albedo_color = Color(0.26, 0.265, 0.27)
	mat_bionda.metallic_specular = 0.0
	mat_bionda.roughness = 1.0
	mat_bionda.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat_edificio.vertex_color_use_as_albedo = true
	mat_edificio.roughness = 0.9
	mat_edificio.metallic_specular = 0.2
	mat_edificio.cull_mode = BaseMaterial3D.CULL_DISABLED
	ruido = _ruido()
	malla_conifera = _malla_arbol(true)
	malla_frondosa = _malla_arbol(false)
	con_orto = Ajustes.args.get("orto", "1") == "1" and datos.info.has("ortofoto")
	_cielo()
	_horizonte()


func _exit_tree() -> void:
	_cerrando = true
	for id in _tareas.keys():
		WorkerThreadPool.wait_for_task_completion(id)
	_tareas.clear()


# ------------------------------------------------------------------ ventana de teselas
## Llamar cada fotograma. bloquear = construir ya todo el anillo 0–1 (salida o teletransporte).
func actualizar(pos: Vector3, bloquear := false) -> void:
	_recoger()
	var ct := datos.clave_tesela(pos)
	if ct == _ultima and not bloquear:
		return
	_ultima = ct
	# descargar lo lejano
	for t in activas.keys():
		if maxi(absi(t.x - ct.x), absi(t.y - ct.y)) > RADIO_FUERA:
			_descargar(t)
	# pedir lo que falta (o cambiar su detalle), de dentro afuera
	var lista := []
	for dj in range(-RADIO, RADIO + 1):
		for di in range(-RADIO, RADIO + 1):
			var t := ct + Vector2i(di, dj)
			var anillo := maxi(absi(di), absi(dj))
			var lod := 0 if anillo <= 1 else 1
			lista.append([anillo, t, lod])
	lista.sort_custom(func(a, b): return a[0] < b[0])
	for e in lista:
		var t: Vector2i = e[1]
		var lod: int = e[2]
		if activas.has(t) and int(activas[t]["lod"]) == lod:
			continue
		if pendientes.get(t, -1) == lod:
			continue
		if bloquear and e[0] <= 1:
			var r := construir_tesela(t, lod)
			_instalar(t, lod, r)
		else:
			pendientes[t] = lod
	_lanzar()


func _lanzar() -> void:
	if _tareas.size() >= HILOS or pendientes.is_empty():
		return
	var ct := _ultima
	var orden := pendientes.keys()
	orden.sort_custom(func(a, b): return maxi(absi(a.x - ct.x), absi(a.y - ct.y)) < maxi(absi(b.x - ct.x), absi(b.y - ct.y)))
	for t in orden:
		if _tareas.size() >= HILOS:
			break
		if _tareas.values().has(t):
			continue
		var lod: int = pendientes[t]
		var id := WorkerThreadPool.add_task(_tarea.bind(t, lod))
		_tareas[id] = t


var _hechos := []                # [t, lod, resultado] de los hilos, para instalar en el principal
var _m_hechos := Mutex.new()


func _tarea(t: Vector2i, lod: int) -> void:
	if _cerrando:
		return
	var r := construir_tesela(t, lod)
	_m_hechos.lock()
	_hechos.append([t, lod, r])
	_m_hechos.unlock()


func _recoger() -> void:
	for id in _tareas.keys():
		if WorkerThreadPool.is_task_completed(id):
			WorkerThreadPool.wait_for_task_completion(id)
			_tareas.erase(id)
	_m_hechos.lock()
	var h := _hechos
	_hechos = []
	_m_hechos.unlock()
	for e in h:
		var t: Vector2i = e[0]
		var lod: int = e[1]
		if pendientes.get(t, -1) == lod:
			pendientes.erase(t)
			if maxi(absi(t.x - _ultima.x), absi(t.y - _ultima.y)) <= RADIO_FUERA:
				_instalar(t, lod, e[2])
	_lanzar()


func _instalar(t: Vector2i, lod: int, r: Dictionary) -> void:
	if activas.has(t):
		_descargar(t)
	pendientes.erase(t)
	var nodo: Node3D = r.get("nodo")
	if nodo == null:
		activas[t] = {"nodo": null, "lod": lod}
		return
	if r.get("orto") != null:
		var sm := ShaderMaterial.new()
		sm.shader = sh_terreno
		sm.set_shader_parameter("orto", ImageTexture.create_from_image(r["orto"]))
		sm.set_shader_parameter("detalle", ruido)
		sm.set_shader_parameter("marco", r["marco"])
		(r["ter_mi"] as MeshInstance3D).material_override = sm
	add_child(nodo)
	activas[t] = {"nodo": nodo, "lod": lod}
	sup.poner(t, r["sup"])
	est["cargadas"] += 1
	est["ms_max"] = maxf(est["ms_max"], r["ms"])
	est["ms_total"] += r["ms"]


func _descargar(t: Vector2i) -> void:
	var a: Dictionary = activas[t]
	if a["nodo"] != null:
		(a["nodo"] as Node3D).queue_free()
	activas.erase(t)
	sup.quitar(t)
	est["descargadas"] += 1


func listas() -> int:
	return activas.size()


# ------------------------------------------------------------------ construcción de una tesela (en un hilo)
func construir_tesela(t: Vector2i, lod: int) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var d := datos.leer_tesela(t)
	if d.is_empty():
		return {"ms": 0.0}
	var raiz := Node3D.new()
	raiz.name = "T_%d_%d" % [t.x, t.y]
	# ortofoto: la imagen se decodifica aquí (hilo); el ShaderMaterial se crea en el hilo principal al instalar la
	# tesela (creado en un hilo, Godot no le pasa los parámetros al shader: medido, suelo blanco)
	var orto: Image = null
	if con_orto:
		var jpg := datos.leer_orto(t)
		if not jpg.is_empty():
			var img := Image.new()
			if img.load_jpg_from_buffer(jpg) == OK:
				img.generate_mipmaps()
				if Ajustes.args.get("orto_dxt", "1") == "1":
					img.compress(Image.COMPRESS_S3TC)
				orto = img
	var ter_mi := _terreno(d, 2 if (lod == 1 and d["fina"]) else 1, mat_terreno)
	raiz.add_child(ter_mi)
	# calzadas: superficie para el coche (siempre) y mallas
	var sa := PackedVector3Array()
	var sb := PackedVector3Array()
	var shw := PackedFloat32Array()
	var sk := PackedInt32Array()
	var v := PackedVector3Array(); var n := PackedVector3Array(); var ix := PackedInt32Array()
	var vv := PackedVector3Array(); var nv := PackedVector3Array(); var iv := PackedInt32Array()
	var tv := PackedVector3Array(); var tn := PackedVector3Array(); var ti := PackedInt32Array()
	var mv := PackedVector3Array(); var mn := PackedVector3Array(); var mi := PackedInt32Array()
	var uv := PackedVector3Array(); var un := PackedVector3Array(); var ui := PackedInt32Array()
	var bv := PackedVector3Array(); var bn := PackedVector3Array(); var bi := PackedInt32Array()
	for pz in d["piezas"]:
		var k: int = pz[0]
		var a: int = pz[1]
		var b: int = pz[2]
		var tr: Dictionary = datos.tramos[k]
		var pts := datos.geometria(k)
		b = mini(b, pts.size() - 1)
		if b <= a:
			continue
		var ancho := float(tr["ancho"])
		for i in range(a, b):
			sa.append(pts[i]); sb.append(pts[i + 1]); shw.append(ancho * 0.5); sk.append(k)
		var tunel := int(tr["tunel"]) == 1
		var puente := int(tr["puente"]) == 1
		var via_rapida := int(tr["c"]) <= 1
		if via_rapida:
			_franja(pts, a, b, ancho * 0.5, 0.0, 0.05, vv, nv, iv, not puente and not tunel, tv, tn, ti)
		else:
			_franja(pts, a, b, ancho * 0.5, 0.0, 0.05, v, n, ix, not puente and not tunel, tv, tn, ti)
		if tunel:
			_boveda(pts, a, b, ancho * 0.5 + 0.8, uv, un, ui)
		if lod == 0:
			_marcas(tr, pts, a, b, ancho, mv, mn, mi)
			# biondas (quitamiedos) en autopistas y autovías: arcén derecho y mediana (APROXIMACIÓN: OSM casi nunca
			# dice dónde hay; en las vías rápidas españolas van casi siempre en la mediana y en terraplenes/puentes)
			if via_rapida and not tunel and int(tr["enlace"]) == 0:
				_bionda(pts, a, b, ancho * 0.5 + 0.7, bv, bn, bi)
				if int(tr["s"]) != 0:
					_bionda(pts, a, b, -(ancho * 0.5 + 0.7), bv, bn, bi)
	var mallas := [[v, n, ix, mat_asfalto], [vv, nv, iv, mat_asfalto_v], [tv, tn, ti, mat_talud], [uv, un, ui, mat_tunel], [bv, bn, bi, mat_bionda]]
	var m := _malla(mallas)
	if m.get_surface_count() > 0:
		raiz.add_child(_instancia(m, 0.0))
	if not mi.is_empty():
		raiz.add_child(_instancia(_malla([[mv, mn, mi, mat_marca]]), 0.0))   # sin distancia: Godot la mide al centro de la tesela (medido: marcas invisibles)
	var ter := {"n": d["n"], "paso": d["paso"], "x0": d["x0"], "z0": d["z0"], "h": d["h"]}
	if lod == 0 and Ajustes.args.get("arboles", "1") == "1":
		_arboles(t, ter, raiz)
	if Ajustes.args.get("edificios", "1") == "1":
		_edificios(t, ter, raiz, 0.0 if lod == 0 else 25.0)
	var supd := {"a": sa, "b": sb, "hw": shw, "k": sk, "celdas": MaSuperficie.indice(sa, sb, shw), "ter": ter}
	return {"nodo": raiz, "sup": supd, "ms": (Time.get_ticks_usec() - t0) / 1000.0, "orto": orto, "ter_mi": ter_mi,
			"marco": Vector4(float(d["x0"]), float(d["z0"]), float(d["x0"]) + datos.tesela, float(d["z0"]) + datos.tesela)}


func _terreno(d: Dictionary, salto: int, material: Material) -> MeshInstance3D:
	var nn: int = d["n"]
	var paso: float = d["paso"]
	var h: PackedFloat32Array = d["h"]
	var x0: float = d["x0"]
	var z0: float = d["z0"]
	var lv := (nn - 1) / salto + 1
	var p := paso * salto
	var verts := PackedVector3Array()
	var nor := PackedVector3Array()
	var col := PackedColorArray()
	verts.resize(lv * lv + lv * 4)
	nor.resize(verts.size())
	col.resize(verts.size())
	for lj in lv:
		var j := lj * salto
		for li in lv:
			var i := li * salto
			var k := j * nn + i
			var hl := h[j * nn + maxi(i - salto, 0)]
			var hr := h[j * nn + mini(i + salto, nn - 1)]
			var hu := h[maxi(j - salto, 0) * nn + i]
			var hd := h[mini(j + salto, nn - 1) * nn + i]
			var nrm := Vector3(hl - hr, 2.0 * p, hu - hd).normalized()
			var q := lj * lv + li
			verts[q] = Vector3(x0 + i * paso, h[k], z0 + j * paso)
			nor[q] = nrm
			col[q] = color_terreno(h[k], 1.0 - nrm.y)
	var idx := PackedInt32Array()
	idx.resize((lv - 1) * (lv - 1) * 6 + (lv - 1) * 4 * 6)
	var c := 0
	for lj in lv - 1:
		for li in lv - 1:
			var k := lj * lv + li
			idx[c] = k; idx[c + 1] = k + 1; idx[c + 2] = k + lv
			idx[c + 3] = k + 1; idx[c + 4] = k + lv + 1; idx[c + 5] = k + lv
			c += 6
	# faldones en los 4 bordes (bajan FALDON m): sin grietas con teselas vecinas de otra resolución
	var base := lv * lv
	var bordes := [[0, 1], [lv * (lv - 1), 1], [0, lv], [lv - 1, lv]]
	for bi in 4:
		var ini: int = bordes[bi][0]
		var paso_i: int = bordes[bi][1]
		for e in lv:
			var src := ini + e * paso_i
			verts[base + bi * lv + e] = verts[src] - Vector3(0, FALDON, 0)
			nor[base + bi * lv + e] = nor[src]
			col[base + bi * lv + e] = col[src]
		for e in lv - 1:
			var a0 := ini + e * paso_i
			var a1 := ini + (e + 1) * paso_i
			var b0 := base + bi * lv + e
			var b1 := b0 + 1
			idx[c] = a0; idx[c + 1] = b0; idx[c + 2] = a1
			idx[c + 3] = a1; idx[c + 4] = b0; idx[c + 5] = b1
			c += 6
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = nor
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = idx
	var malla := ArrayMesh.new()
	malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	malla.surface_set_material(0, material)
	var mi := MeshInstance3D.new()
	mi.mesh = malla
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Árboles de la tesela en 4 bloques de 1 km (MultiMesh por bloque y especie), visibles hasta DIST_ARBOLES
func _arboles(t: Vector2i, ter: Dictionary, raiz: Node3D) -> void:
	var b := datos.leer_arboles(t)
	var n := b.size() / 6
	if n == 0:
		return
	var x0: float = ter["x0"]
	var z0: float = ter["z0"]
	var lado := datos.tesela
	var grupos := []         # 8 listas: bloque (4) × especie (2)
	for i in 8:
		grupos.append(PackedInt32Array())
	var xs := PackedFloat32Array(); xs.resize(n)
	var zs := PackedFloat32Array(); zs.resize(n)
	for i in n:
		var x := x0 + b.decode_u16(i * 6) / 65535.0 * lado
		var z := z0 + b.decode_u16(i * 6 + 2) / 65535.0 * lado
		xs[i] = x
		zs[i] = z
		var tipo := b[i * 6 + 4]
		var conifera := tipo == 1 or (tipo == 0 and MaSuperficie.terreno(ter, x, z) >= 1000.0)
		var blq := (1 if z - z0 >= lado * 0.5 else 0) * 2 + (1 if x - x0 >= lado * 0.5 else 0)
		grupos[blq * 2 + (0 if conifera else 1)].append(i)
	for g in 8:
		var lista: PackedInt32Array = grupos[g]
		if lista.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = malla_conifera if g % 2 == 0 else malla_frondosa
		mm.instance_count = lista.size()
		for j in lista.size():
			var i := lista[j]
			var e := 0.7 + b[i * 6 + 5] / 255.0 * 0.6
			var ang := float(b[i * 6 + 5] * 37 % 360)
			var y := MaSuperficie.terreno(ter, xs[i], zs[i]) - 0.3
			var bas := Basis(Vector3.UP, deg_to_rad(ang)).scaled(Vector3(e, e * (0.9 + (i % 7) * 0.05), e))
			mm.set_instance_transform(j, Transform3D(bas, Vector3(xs[i], y, zs[i])))
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.visibility_range_end = DIST_ARBOLES
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		raiz.add_child(mi)


## Edificios de OSM como prismas (huella real, altura de OSM o aproximada por tipo), una sola malla por tesela.
## altura_min > 0: solo los altos (anillo lejano: el perfil de la ciudad)
func _edificios(t: Vector2i, ter: Dictionary, raiz: Node3D, altura_min: float) -> void:
	var b := datos.leer_edificios(t)
	if b.size() < 8:
		return
	var n := b.decode_u32(4)
	var x0: float = ter["x0"]
	var z0: float = ter["z0"]
	var lado := datos.tesela
	var v := PackedVector3Array()
	var nor := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	var paredes := [Color(0.86, 0.81, 0.70), Color(0.66, 0.45, 0.34), Color(0.90, 0.89, 0.85), Color(0.72, 0.66, 0.56), Color(0.58, 0.56, 0.53)]
	var o := 8
	for e in n:
		var h := b.decode_u16(o) / 10.0
		var nv := b.decode_u16(o + 2)
		o += 4
		if h < altura_min:
			o += nv * 4
			continue
		var pol := PackedVector2Array()
		pol.resize(nv)
		var c := Vector2.ZERO
		for i in nv:
			var p := Vector2(x0 + b.decode_u16(o + i * 4) / 65535.0 * lado, z0 + b.decode_u16(o + i * 4 + 2) / 65535.0 * lado)
			pol[i] = p
			c += p
		o += nv * 4
		c /= nv
		var y0 := MaSuperficie.terreno(ter, c.x, c.y)
		var base := y0 - 1.5
		var techo := y0 + h
		var area := 0.0
		for i in nv:
			var p := pol[i]
			var q := pol[(i + 1) % nv]
			area += p.x * q.y - q.x * p.y
		var signo := 1.0 if area > 0.0 else -1.0
		var semilla := int(absf(c.x * 7.0 + c.y * 13.0))
		var cp: Color = paredes[semilla % paredes.size()]
		if h >= 20.0 and semilla % 3 == 0:
			cp = Color(0.55, 0.6, 0.64)          # torres de cristal / chapa
		for i in nv:
			var p := pol[i]
			var q := pol[(i + 1) % nv]
			var d := q - p
			var nn := Vector3(d.y, 0.0, -d.x).normalized() * signo
			var k := v.size()
			v.append_array([Vector3(p.x, base, p.y), Vector3(q.x, base, q.y), Vector3(q.x, techo, q.y), Vector3(p.x, techo, p.y)])
			nor.append_array([nn, nn, nn, nn])
			col.append_array([cp * 0.8, cp * 0.8, cp, cp])
			idx.append_array([k, k + 1, k + 2, k, k + 2, k + 3])
		var tri := Geometry2D.triangulate_polygon(pol)
		if tri.size() >= 3:
			var cr := Color(0.56, 0.33, 0.25) if h < 9.0 else Color(0.47, 0.46, 0.44)
			var k0 := v.size()
			for i in nv:
				v.append(Vector3(pol[i].x, techo, pol[i].y))
				nor.append(Vector3.UP)
				col.append(cr)
			for i in tri:
				idx.append(k0 + i)
	if idx.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = nor
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	m.surface_set_material(0, mat_edificio)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	raiz.add_child(mi)


## Conífera (pino silvestre / resinero: copa cónica) o frondosa (encina / roble: copa redondeada), low-poly
static func _malla_arbol(conifera: bool) -> ArrayMesh:
	var malla := ArrayMesh.new()
	var m_copa := StandardMaterial3D.new()
	m_copa.albedo_color = Color(0.12, 0.24, 0.12) if conifera else Color(0.20, 0.27, 0.13)
	m_copa.roughness = 1.0
	var m_tronco := StandardMaterial3D.new()
	m_tronco.albedo_color = Color(0.36, 0.25, 0.17)
	m_tronco.roughness = 1.0
	var copa: PrimitiveMesh
	var alto_copa := 9.0
	if conifera:
		var c := CylinderMesh.new()
		c.top_radius = 0.0
		c.bottom_radius = 2.6
		c.height = 10.0
		c.radial_segments = 7
		c.rings = 1
		copa = c
	else:
		var s := SphereMesh.new()
		s.radius = 3.0
		s.height = 4.6
		s.radial_segments = 8
		s.rings = 4
		copa = s
		alto_copa = 4.6
	var tronco := CylinderMesh.new()
	tronco.top_radius = 0.22
	tronco.bottom_radius = 0.32
	tronco.height = 5.0 if conifera else 2.8
	tronco.radial_segments = 5
	tronco.rings = 1
	for par in [[copa, alto_copa, m_copa], [tronco, tronco.height * 0.5, m_tronco]]:
		var arr: Array = par[0].get_mesh_arrays()
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in v.size():
			v[i].y += par[1]
		arr[Mesh.ARRAY_VERTEX] = v
		malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		malla.surface_set_material(malla.get_surface_count() - 1, par[2])
	return malla


static func _ruido() -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.02
	n.fractal_octaves = 4
	var t := NoiseTexture2D.new()
	t.width = 256
	t.height = 256
	t.seamless = true
	t.generate_mipmaps = true
	t.noise = n
	return t


## Color del suelo por altitud y pendiente (APROXIMACIÓN, sin ortofoto todavía): campiña seca del sur y este
## (400–750 m), dehesa y pasto (750–1150 m), pinar del Guadarrama (1150–1900 m), cumbres y roca.
static func color_terreno(h: float, inclinacion: float) -> Color:
	var campo := Color(0.52, 0.47, 0.30)
	var dehesa := Color(0.40, 0.41, 0.25)
	var pinar := Color(0.17, 0.25, 0.14)
	var cumbre := Color(0.50, 0.46, 0.36)
	var roca := Color(0.46, 0.44, 0.40)
	var c := campo.lerp(dehesa, clampf((h - 700.0) / 300.0, 0.0, 1.0))
	c = c.lerp(pinar, clampf((h - 1150.0) / 250.0, 0.0, 1.0))
	c = c.lerp(cumbre, clampf((h - 1950.0) / 200.0, 0.0, 1.0))
	return c.lerp(roca, clampf((inclinacion - 0.15) / 0.25, 0.0, 1.0))


# ------------------------------------------------------------------ calzadas
## Franja a lo largo de la polilínea entre a y b (centro desplazado `desplaz` m a la derecha), con talud opcional
static func _franja(pts: PackedVector3Array, a: int, b: int, hw: float, desplaz: float, elev: float,
		verts: PackedVector3Array, nor: PackedVector3Array, idx: PackedInt32Array, talud := false,
		tv := PackedVector3Array(), tn := PackedVector3Array(), ti := PackedInt32Array(), patron := 0.0) -> void:
	var n := pts.size()
	var s := 0.0
	for i in range(a, b + 1):
		var t := pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]
		var der := Vector3(-t.z, 0.0, t.x).normalized()
		var centro := pts[i] + der * desplaz
		if i > a:
			s += pts[i].distance_to(pts[i - 1])
		var hueco := patron > 0.0 and fmod(s, patron) > patron * 0.4
		if hueco:
			verts.append(centro + Vector3.UP * elev)
			verts.append(centro + Vector3.UP * elev)
		else:
			verts.append(centro - der * hw + Vector3.UP * elev)
			verts.append(centro + der * hw + Vector3.UP * elev)
		nor.append(Vector3.UP)
		nor.append(Vector3.UP)
		if i > a:
			var k := verts.size() - 4
			idx.append_array([k, k + 2, k + 1, k + 1, k + 2, k + 3])
		if talud:
			var bl := verts[verts.size() - 2]
			var br := verts[verts.size() - 1]
			var caida := Vector3(0.0, -2.4, 0.0)
			var fuera := der * 2.0
			tv.append_array([bl - fuera + caida, bl, br, br + fuera + caida])
			tn.append_array([(Vector3.UP - der).normalized(), (Vector3.UP - der).normalized(),
					(Vector3.UP + der).normalized(), (Vector3.UP + der).normalized()])
			if i > a:
				var q := tv.size() - 8
				ti.append_array([q, q + 4, q + 1, q + 1, q + 4, q + 5, q + 2, q + 6, q + 3, q + 3, q + 6, q + 7])


## Marcas viales (APROXIMACIÓN: OSM no dice dónde es continua la línea): bordes continuos; eje discontinuo en las de
## doble sentido (continuo en enlaces y glorietas); separación de carriles discontinua en las de un sentido.
static func _marcas(tr: Dictionary, pts: PackedVector3Array, a: int, b: int, ancho: float,
		mv: PackedVector3Array, mn: PackedVector3Array, mi: PackedInt32Array) -> void:
	var hw := ancho * 0.5
	_franja(pts, a, b, 0.075, -(hw - 0.3), 0.08, mv, mn, mi)
	_franja(pts, a, b, 0.075, hw - 0.3, 0.08, mv, mn, mi)
	var sentido := int(tr["s"])
	var carriles := int(tr["carriles"])
	if sentido == 0:
		var lento := int(tr["c"]) >= 3 or int(tr["rot"]) == 1
		_franja(pts, a, b, 0.07, 0.0, 0.085, mv, mn, mi, false, PackedVector3Array(), PackedVector3Array(), PackedInt32Array(), 0.0 if lento else 12.0)
		return
	if carriles >= 2:
		var util := ancho - 1.0
		for c in range(1, carriles):
			var lat := -util * 0.5 + util * c / carriles
			_franja(pts, a, b, 0.07, lat, 0.085, mv, mn, mi, false, PackedVector3Array(), PackedVector3Array(), PackedInt32Array(), 12.0)


## Bionda: banda vertical de 0,45 a 0,8 m sobre la calzada a `lat` m del eje (+ derecha), sin postes
static func _bionda(pts: PackedVector3Array, a: int, b: int, lat: float, v: PackedVector3Array, n: PackedVector3Array, ix: PackedInt32Array) -> void:
	var np := pts.size()
	for i in range(a, b + 1):
		var t := pts[mini(i + 1, np - 1)] - pts[maxi(i - 1, 0)]
		var der := Vector3(-t.z, 0.0, t.x).normalized()
		var p := pts[i] + der * lat
		v.append_array([p + Vector3.UP * 0.45, p + Vector3.UP * 0.8])
		n.append_array([-der * signf(lat), -der * signf(lat)])
		if i > a:
			var k := v.size() - 4
			ix.append_array([k, k + 2, k + 1, k + 1, k + 2, k + 3])


## Bóveda de túnel (paredes y techo a 5,5 m) para que el túnel se vea por dentro
static func _boveda(pts: PackedVector3Array, a: int, b: int, hw: float, v: PackedVector3Array, n: PackedVector3Array, ix: PackedInt32Array) -> void:
	var np := pts.size()
	for i in range(a, b + 1):
		var t := pts[mini(i + 1, np - 1)] - pts[maxi(i - 1, 0)]
		var der := Vector3(-t.z, 0.0, t.x).normalized()
		var p := pts[i]
		v.append_array([p - der * hw, p - der * hw + Vector3.UP * 5.5, p + der * hw + Vector3.UP * 5.5, p + der * hw])
		n.append_array([der, -Vector3.UP, -Vector3.UP, -der])
		if i > a:
			var k := v.size() - 8
			for s in 3:
				ix.append_array([k + s, k + s + 4, k + s + 1, k + s + 1, k + s + 4, k + s + 5])


static func _malla(superficies: Array) -> ArrayMesh:
	var malla := ArrayMesh.new()
	for s in superficies:
		if (s[2] as PackedInt32Array).is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = s[0]
		arr[Mesh.ARRAY_NORMAL] = s[1]
		arr[Mesh.ARRAY_INDEX] = s[2]
		malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		malla.surface_set_material(malla.get_surface_count() - 1, s[3])
	return malla


static func _instancia(malla: ArrayMesh, visible_hasta: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = malla
	if visible_hasta > 0.0:
		mi.visibility_range_end = visible_hasta
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# ------------------------------------------------------------------ horizonte y cielo
## Relieve de toda la región a 200 m en bloques de 16 km (se recortan solos fuera de cámara). Cada vértice está en
## el MÍNIMO del terreno de alrededor (pipeline), así nunca asoma por encima de las teselas de detalle.
func _horizonte() -> void:
	var hz := datos.leer_horizonte()
	var nx: int = hz["nx"]
	var nz: int = hz["nz"]
	var paso: float = hz["paso"]
	var x0: float = hz["x0"]
	var z0: float = hz["z0"]
	var mnm: PackedFloat32Array = hz["minimo"]
	var re: PackedFloat32Array = hz["real"]
	const B := 80
	var mat_h: Material = mat_terreno
	var o: Dictionary = datos.info.get("ortofoto", {})
	if con_orto and o.has("horizonte") and ResourceLoader.exists(datos.dir + str(o["horizonte"])):
		var sm := ShaderMaterial.new()
		sm.shader = sh_terreno
		sm.set_shader_parameter("orto", load(datos.dir + str(o["horizonte"])))
		var mh: Array = o["marco_horizonte"]
		sm.set_shader_parameter("marco", Vector4(mh[0], mh[1], mh[2], mh[3]))
		sm.set_shader_parameter("lejos", 1.0)
		mat_h = sm
	var raiz := Node3D.new()
	raiz.name = "Horizonte"
	add_child(raiz)
	for bj in range(0, nz - 1, B):
		for bi in range(0, nx - 1, B):
			var ci := mini(B, nx - 1 - bi)
			var cj := mini(B, nz - 1 - bj)
			var verts := PackedVector3Array()
			var nor := PackedVector3Array()
			var col := PackedColorArray()
			for vj in cj + 1:
				for vi in ci + 1:
					var i := bi + vi
					var j := bj + vj
					var k := j * nx + i
					var hl := re[j * nx + maxi(i - 1, 0)]
					var hr := re[j * nx + mini(i + 1, nx - 1)]
					var hu := re[maxi(j - 1, 0) * nx + i]
					var hd := re[mini(j + 1, nz - 1) * nx + i]
					var nrm := Vector3(hl - hr, 2.0 * paso, hu - hd).normalized()
					verts.append(Vector3(x0 + i * paso, mnm[k] - 3.0, z0 + j * paso))
					nor.append(nrm)
					col.append(color_terreno(re[k], 1.0 - nrm.y))
			var idx := PackedInt32Array()
			for vj in cj:
				for vi in ci:
					var k := vj * (ci + 1) + vi
					idx.append_array([k, k + 1, k + ci + 1, k + 1, k + ci + 2, k + ci + 1])
			var arr := []
			arr.resize(Mesh.ARRAY_MAX)
			arr[Mesh.ARRAY_VERTEX] = verts
			arr[Mesh.ARRAY_NORMAL] = nor
			arr[Mesh.ARRAY_COLOR] = col
			arr[Mesh.ARRAY_INDEX] = idx
			var m := ArrayMesh.new()
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			m.surface_set_material(0, mat_h)
			var mi := MeshInstance3D.new()
			mi.mesh = m
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			raiz.add_child(mi)


func _cielo() -> void:
	var sol := DirectionalLight3D.new()
	sol.rotation_degrees = Vector3(-38, -35, 0)
	sol.light_energy = 1.15
	sol.shadow_enabled = true
	sol.directional_shadow_max_distance = 100.0
	sol.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sol.directional_shadow_split_1 = 0.3
	sol.directional_shadow_blend_splits = true
	add_child(sol)
	var cielo_mat := ProceduralSkyMaterial.new()
	cielo_mat.sky_top_color = Color(0.30, 0.50, 0.80)
	cielo_mat.sky_horizon_color = Color(0.68, 0.76, 0.86)
	cielo_mat.ground_horizon_color = Color(0.62, 0.68, 0.72)
	cielo_mat.ground_bottom_color = Color(0.25, 0.27, 0.25)
	var cielo := Sky.new()
	cielo.sky_material = cielo_mat
	entorno = Environment.new()
	entorno.background_mode = Environment.BG_SKY
	entorno.sky = cielo
	entorno.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	entorno.ambient_light_energy = 0.45
	entorno.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	entorno.fog_enabled = true
	entorno.fog_mode = Environment.FOG_MODE_DEPTH
	entorno.fog_light_color = Color(0.66, 0.74, 0.84)
	entorno.fog_density = 0.85
	entorno.fog_depth_begin = 1500.0
	entorno.fog_depth_end = 45000.0
	entorno.fog_depth_curve = 0.6
	entorno.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = entorno
	add_child(we)
