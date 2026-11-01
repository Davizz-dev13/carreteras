## Paisaje real (SOLO versión de escritorio / .exe; en la web no se carga nada de esto): montañas lejanas con el relieve real del IGN (MDT25 a 100 m),
## color del suelo con la ortofoto real PNOA y, opcionalmente, nieve de invierno por encima de una cota SUPUESTA.
## Datos: res://datos/<zona>/paisaje/ (los genera pipeline/paisaje.py). Fuentes y qué es real / supuesto: paisaje.json.
##  · Relieve lejano: 1 sola malla (1 draw call) de la zona + 25 km alrededor, sin la parte interior que ya cubre el
##    terreno de la zona (hueco), a 200 m entre vértices (Gráficos alto). Sin sombras, sin colisión.
##  · Suelo: el mismo material (shader) para el terreno de la zona y el lejano: ortofoto de la zona (~5 m/px) y del
##    entorno (~35 m/px), texturas comprimidas en VRAM con mipmaps; de cerca, un ruido de detalle que solo varía el brillo.
##  · Invierno: nieve en el shader según altitud, pendiente y la propia ortofoto (en el bosque se ve menos).
##  · Gráficos "bajo": todo como antes (colores por altitud, sin relieve lejano ni texturas).
## Nada se reserva por fotograma: todo se construye una vez al cargar la zona.
class_name Paisaje
extends Node3D

const OPCIONES := "user://paisaje.cfg"
const PASO_MALLA := 2          # vértices del MDT (100 m) por vértice de la malla lejana → 200 m
const BAJADA_BORDE := 6.0      # m que se hunde la franja que se solapa con el terreno de la zona (sin grietas)

static var graficos := "alto"   # "alto" | "bajo"
static var estacion := "verano" # "verano" | "invierno"
static var _opciones_leidas := false

var meta := {}
var mat: ShaderMaterial
var _cam_lista := false


static func leer_opciones() -> void:
	if _opciones_leidas:
		return
	_opciones_leidas = true
	var cf := ConfigFile.new()
	if cf.load(OPCIONES) == OK:
		graficos = str(cf.get_value("paisaje", "graficos", graficos))
		estacion = str(cf.get_value("paisaje", "estacion", estacion))
	graficos = str(Ajustes.args.get("graficos", graficos))
	estacion = str(Ajustes.args.get("estacion", estacion))


static func guardar_opciones() -> void:
	var cf := ConfigFile.new()
	cf.set_value("paisaje", "graficos", graficos)
	cf.set_value("paisaje", "estacion", estacion)
	cf.save(OPCIONES)


## En la web (navegador) nunca: allí el juego queda exactamente como antes y las texturas ni se exportan
static func disponible() -> bool:
	return not OS.has_feature("web")


static func activo() -> bool:
	if not disponible():
		return false
	leer_opciones()
	return graficos == "alto" and FileAccess.file_exists(Ajustes.dir_datos() + "paisaje/paisaje.json")


## Fila para el menú: "Gráficos: alto/bajo   Estación: verano/invierno"
static func fila_menu() -> HBoxContainer:
	var f := HBoxContainer.new()
	if not disponible():
		f.visible = false
		return f
	leer_opciones()
	var l1 := Label.new()
	l1.text = "Gráficos:"
	l1.custom_minimum_size.x = 140
	f.add_child(l1)
	var g := OptionButton.new()
	g.add_item("alto (paisaje real)")
	g.add_item("bajo (como antes)")
	g.selected = 0 if graficos == "alto" else 1
	g.item_selected.connect(func(i: int) -> void:
		graficos = "alto" if i == 0 else "bajo"
		guardar_opciones())
	f.add_child(g)
	var l2 := Label.new()
	l2.text = "   Estación:"
	f.add_child(l2)
	var e := OptionButton.new()
	e.add_item("verano")
	e.add_item("invierno (nieve aprox.)")
	e.selected = 0 if estacion == "verano" else 1
	e.item_selected.connect(func(i: int) -> void:
		estacion = "verano" if i == 0 else "invierno"
		guardar_opciones())
	f.add_child(e)
	return f


## Llamar desde Mundo.construir() ANTES de crear el streaming: devuelve el material del terreno (el de siempre en "bajo")
static func material_terreno(previo: Material) -> Material:
	if not activo():
		return previo
	var m: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Ajustes.dir_datos() + "paisaje/paisaje.json"))
	var sm := ShaderMaterial.new()
	sm.shader = _shader()
	var d := Ajustes.dir_datos() + "paisaje/"
	sm.set_shader_parameter("orto_cerca", load(d + "orto_cerca.jpg"))
	sm.set_shader_parameter("orto_lejos", load(d + "orto_lejos.jpg"))
	var mz: Array = m["marco_zona"]
	var ml: Array = m["marco_lejos"]
	sm.set_shader_parameter("marco_zona", Vector4(mz[0], mz[1], mz[2], mz[3]))
	sm.set_shader_parameter("marco_lejos", Vector4(ml[0], ml[1], ml[2], ml[3]))
	sm.set_shader_parameter("detalle", _ruido())
	sm.set_shader_parameter("nieve", 1.0 if estacion == "invierno" else 0.0)
	sm.set_shader_parameter("cota_nieve", float(m.get("cota_nieve", 1800)))
	sm.set_shader_parameter("mix_orto", 0.0 if Ajustes.args.get("orto_cerca", "0") == "1" else 1.0)
	sm.set_shader_parameter("depurar", int(Ajustes.args.get("paisaje_depurar", "0")))
	if Ajustes.args.get("aspecto", "1") == "1":
		sm.set_shader_parameter("cerca_orto", 1.0)
	return sm


## Filtro anisótropo (más nitidez del suelo a lo lejos) en el .exe de Windows; en las pruebas por software se quedaba
## colgado, así que fuera de Windows solo con --aniso=1
static func _shader() -> Shader:
	var base: Shader = load("res://scripts/paisaje_terreno.gdshader")
	if Ajustes.args.get("aniso", "1" if OS.has_feature("windows") else "0") != "1":
		return base
	var s := Shader.new()
	s.code = base.code.replace("filter_linear_mipmap,", "filter_linear_mipmap_anisotropic,")
	return s


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


## Llamar desde Mundo.construir() después de _cielo(): relieve lejano + bruma
func preparar(mundo: Node3D, material: Material) -> void:
	if not activo():
		queue_free()
		return
	name = "Paisaje"
	meta = JSON.parse_string(FileAccess.get_file_as_string(Ajustes.dir_datos() + "paisaje/paisaje.json"))
	mat = material as ShaderMaterial
	var t0 := Time.get_ticks_msec()
	_relieve_lejano()
	if Ajustes.args.get("paisaje_bruma", "1") == "1":
		_bruma(mundo.entorno)
	print("Paisaje: relieve lejano en %d ms (%s, %s)" % [Time.get_ticks_msec() - t0, graficos, estacion])


func _relieve_lejano() -> void:
	var ni: int = meta["ni"]
	var nj: int = meta["nj"]
	var p: float = meta["paso"]
	var x0: float = meta["x0"]
	var z0: float = meta["z0"]
	var mz: Array = meta["marco_zona"]
	var f := FileAccess.open(Ajustes.dir_datos() + "paisaje/lejano.bin", FileAccess.READ)
	var raw := f.get_buffer(f.get_length())
	var s := PASO_MALLA
	var ci := (ni - 1) / s
	var cj := (nj - 1) / s
	var pl := p * s
	var nv := (ci + 1) * (cj + 1)
	var h := PackedFloat32Array()
	h.resize(nv)
	for vz in cj + 1:
		var fila := vz * s * ni
		for vx in ci + 1:
			h[vz * (ci + 1) + vx] = raw.decode_u16((fila + vx * s) * 2) * 0.1
	# celdas dentro de la zona (con 1 celda de solape): hueco; vértices del solape, un poco hundidos
	var ix0 := int(round((float(mz[0]) - x0) / pl))
	var ix1 := int(round((float(mz[2]) - x0) / pl))
	var iz0 := int(round((float(mz[1]) - z0) / pl))
	var iz1 := int(round((float(mz[3]) - z0) / pl))
	var verts := PackedVector3Array()
	var nor := PackedVector3Array()
	verts.resize(nv)
	nor.resize(nv)
	for vz in cj + 1:
		for vx in ci + 1:
			var k := vz * (ci + 1) + vx
			var hl := h[vz * (ci + 1) + maxi(vx - 1, 0)]
			var hr := h[vz * (ci + 1) + mini(vx + 1, ci)]
			var hu := h[maxi(vz - 1, 0) * (ci + 1) + vx]
			var hd := h[mini(vz + 1, cj) * (ci + 1) + vx]
			var y := h[k]
			if vx >= ix0 and vx <= ix1 and vz >= iz0 and vz <= iz1:
				y -= BAJADA_BORDE
			verts[k] = Vector3(x0 + vx * pl, y, z0 + vz * pl)
			nor[k] = Vector3(hl - hr, 2.0 * pl, hu - hd).normalized()
	var idx := PackedInt32Array()
	idx.resize(ci * cj * 6)
	var c := 0
	for vz in cj:
		var dentro_z := vz > iz0 and vz < iz1 - 1
		for vx in ci:
			if dentro_z and vx > ix0 and vx < ix1 - 1:
				continue
			var k := vz * (ci + 1) + vx
			idx[c] = k; idx[c + 1] = k + 1; idx[c + 2] = k + ci + 1
			idx[c + 3] = k + 1; idx[c + 4] = k + ci + 2; idx[c + 5] = k + ci + 1
			c += 6
	idx.resize(c)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = nor
	arr[Mesh.ARRAY_INDEX] = idx
	var malla := ArrayMesh.new()
	malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	malla.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "RelieveLejano"
	mi.mesh = malla
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)


## Bruma por distancia (perspectiva aérea) para que las sierras a 10–40 km se vean azuladas, no recortadas
func _bruma(e: Environment) -> void:
	if e == null:
		return
	e.fog_mode = Environment.FOG_MODE_DEPTH
	e.fog_depth_begin = 400.0
	e.fog_depth_end = 70000.0
	e.fog_depth_curve = 0.55
	e.fog_density = 0.80
	e.fog_light_color = Color(0.66, 0.74, 0.84)
	e.fog_sky_affect = 0.0
	var cm := e.sky.sky_material as ProceduralSkyMaterial if e.sky else null
	if cm:
		cm.sky_top_color = Color(0.30, 0.50, 0.80)
		cm.sky_horizon_color = Color(0.68, 0.76, 0.86)


func _process(_d: float) -> void:
	# la cámara la crea el juego después del mundo: alargar su plano lejano una vez (16 km → 75 km)
	if _cam_lista:
		return
	var cam := get_viewport().get_camera_3d()
	if cam:
		if Ajustes.args.get("paisaje_far", "1") == "1":
			cam.far = maxf(cam.far, 75000.0)
		_cam_lista = true
		set_process(false)
