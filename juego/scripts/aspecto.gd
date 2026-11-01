## Aspecto de carreteras y entorno (solo versión de escritorio, Gráficos alto): materiales compartidos por las zonas
## (mundo.gd) y el mapa abierto (ma_mundo.gd). Todo procedural en el shader con dos texturas de ruido de 256 px
## (≈ 0,2 MB de VRAM con mipmaps), creadas una vez: nada por fotograma.
class_name Aspecto
extends RefCounted

static var _ruido: NoiseTexture2D
static var _grano: NoiseTexture2D
static var _sh_asfalto: Shader
static var _sh_marca: Shader


static func ruido() -> NoiseTexture2D:
	if _ruido == null:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = 0.02
		n.fractal_octaves = 4
		n.seed = 7
		_ruido = NoiseTexture2D.new()
		_ruido.width = 256
		_ruido.height = 256
		_ruido.seamless = true
		_ruido.generate_mipmaps = true
		_ruido.noise = n
	return _ruido


static func grano() -> NoiseTexture2D:
	if _grano == null:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_VALUE
		n.frequency = 0.35
		n.fractal_octaves = 2
		n.seed = 3
		_grano = NoiseTexture2D.new()
		_grano.width = 256
		_grano.height = 256
		_grano.seamless = true
		_grano.generate_mipmaps = true
		_grano.noise = n
	return _grano


static func asfalto(base: Color) -> ShaderMaterial:
	if _sh_asfalto == null:
		_sh_asfalto = load("res://scripts/asfalto.gdshader")
	var m := ShaderMaterial.new()
	m.shader = _sh_asfalto
	m.set_shader_parameter("base", base)
	m.set_shader_parameter("ruido", ruido())
	m.set_shader_parameter("grano", grano())
	return m


static func marca() -> ShaderMaterial:
	if _sh_marca == null:
		_sh_marca = load("res://scripts/marca_vial.gdshader")
	var m := ShaderMaterial.new()
	m.shader = _sh_marca
	m.set_shader_parameter("ruido", ruido())
	m.set_shader_parameter("grano", grano())
	return m


## Talud y arcén de tierra: el mismo material del suelo (ortofoto real) con una franja de grava y tierra junto al
## asfalto (UV.y = 0 en el borde del asfalto, 1 abajo). Sin ortofoto: el color de siempre.
static func talud(mat_suelo: Material) -> Material:
	if mat_suelo is ShaderMaterial:
		var m := (mat_suelo as ShaderMaterial).duplicate() as ShaderMaterial
		m.set_shader_parameter("talud", 1.0)
		m.set_shader_parameter("grano", grano())
		return m
	var s := StandardMaterial3D.new()
	s.albedo_color = Color(0.30, 0.29, 0.21)
	s.roughness = 1.0
	return s


## Árboles low-poly algo más creíbles que un cono: tronco + copa de 2 masas irregulares (vértices desplazados con
## un ruido fijo), sombreado de la copa más oscuro abajo (color por vértice) y variación de tono por árbol (color de
## instancia del MultiMesh). conifera: pino (tronco alto y copa arriba, como los pinos silvestres y resineros de
## las sierras); frondosa: encina/roble (tronco corto y copa ancha). lod 1: copa de 1 masa y menos caras (lejos).
static func malla_arbol(conifera: bool, lod := 0) -> ArrayMesh:
	var malla := ArrayMesh.new()
	var m_copa := StandardMaterial3D.new()
	m_copa.vertex_color_use_as_albedo = true
	m_copa.albedo_color = Color(0.15, 0.24, 0.13) if conifera else Color(0.22, 0.27, 0.15)
	m_copa.roughness = 1.0
	m_copa.metallic_specular = 0.0
	m_copa.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
	var m_tronco := StandardMaterial3D.new()
	m_tronco.vertex_color_use_as_albedo = true
	m_tronco.albedo_color = Color(0.25, 0.20, 0.16) if conifera else Color(0.24, 0.21, 0.18)
	m_tronco.roughness = 1.0
	m_tronco.metallic_specular = 0.0
	var masas: Array   # [centro, radio horizontal, radio vertical]
	var alto_tronco: float
	if conifera:
		alto_tronco = 5.0
		masas = [[Vector3(0, 8.0, 0), 3.2, 3.3], [Vector3(0.9, 5.9, -0.7), 2.8, 2.3], [Vector3(-0.8, 10.6, 0.5), 2.2, 1.8]]
	else:
		alto_tronco = 2.4
		masas = [[Vector3(0, 4.1, 0), 3.4, 2.4], [Vector3(-1.2, 3.3, 0.9), 2.5, 1.8], [Vector3(1.1, 4.8, -0.7), 2.1, 1.6]]
	if lod == 1:
		masas = [Vector3(masas[0][0]), masas[0][1] * 1.08, masas[0][2] * 1.25]
		masas = [[masas[0], masas[1], masas[2]]]
	var rad := 7 if lod == 0 else 5
	var anillos := 4 if lod == 0 else 3
	var v := PackedVector3Array(); var n := PackedVector3Array(); var c := PackedColorArray(); var ix := PackedInt32Array()
	var y_min := 1e9
	var y_max := -1e9
	for ms in masas:
		y_min = minf(y_min, ms[0].y - ms[2])
		y_max = maxf(y_max, ms[0].y + ms[2])
	var semilla := 0
	for ms in masas:
		var base := v.size()
		for j in anillos + 1:
			var th := PI * j / anillos
			for i in rad + 1:
				var ph := TAU * i / rad
				var dir := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
				var k := (i % rad) * 31 + j * 17 + semilla * 7
				var ruido := 1.0 + 0.22 * sin(k * 12.9898) if (j > 0 and j < anillos) else 1.0
				var p: Vector3 = ms[0] + Vector3(dir.x * ms[1], dir.y * ms[2], dir.z * ms[1]) * ruido
				v.append(p)
				n.append((dir + Vector3.UP * 0.35).normalized())
				var f := clampf((p.y - y_min) / maxf(y_max - y_min, 0.1), 0.0, 1.0)
				var g := lerpf(0.55, 1.12, f)
				c.append(Color(g, g, g))
		for j in anillos:
			for i in rad:
				var a := base + j * (rad + 1) + i
				var b := a + rad + 1
				ix.append_array([a, b, a + 1, a + 1, b, b + 1])
		semilla += 1
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v; arr[Mesh.ARRAY_NORMAL] = n; arr[Mesh.ARRAY_COLOR] = c; arr[Mesh.ARRAY_INDEX] = ix
	malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	malla.surface_set_material(0, m_copa)
	if lod == 0:
		var tr := CylinderMesh.new()
		tr.top_radius = 0.2 if conifera else 0.24
		tr.bottom_radius = 0.36
		tr.height = alto_tronco + 0.6
		tr.radial_segments = 5
		tr.rings = 1
		tr.cap_top = false
		tr.cap_bottom = false
		var ta: Array = tr.get_mesh_arrays()
		var tv: PackedVector3Array = ta[Mesh.ARRAY_VERTEX]
		var tc := PackedColorArray()
		for i in tv.size():
			tv[i].y += tr.height * 0.5 - 0.3
			tc.append(Color(1, 1, 1))
		ta[Mesh.ARRAY_VERTEX] = tv
		ta[Mesh.ARRAY_COLOR] = tc
		malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ta)
		malla.surface_set_material(1, m_tronco)
	return malla


## Tono de un árbol (color de instancia): ±12 % de brillo y algo de variación de verde a oliva, fijo por posición
static func tono_arbol(x: float, z: float) -> Color:
	var h := absf(sin(x * 12.9898 + z * 78.233) * 43758.5453)
	h -= floorf(h)
	var h2 := absf(sin(x * 39.346 + z * 11.135) * 24634.6345)
	h2 -= floorf(h2)
	var b := 0.86 + 0.26 * h
	return Color(b * (0.96 + 0.1 * h2), b, b * (0.94 + 0.06 * h2))


## ¿Pino o frondosa? (APROXIMACIÓN por altitud: la fuente no dice la especie) — por encima de 1.300 m pinos; de 1.000 a
## 1.300 m mezcla; por debajo sobre todo encinas, quejigos y olivos (copa redonda)
static func es_conifera(x: float, z: float, y: float) -> bool:
	var h := absf(sin(x * 7.13 + z * 3.71) * 9631.77)
	h -= floorf(h)
	if y >= 1300.0:
		return h < 0.9
	if y >= 1000.0:
		return h < 0.55
	return h < 0.15


## Luz (aspecto): sol algo más cálido, bruma que toma el color del cielo a lo lejos (perspectiva aérea) y un poco de
## resplandor del sol en la niebla. Sin coste por fotograma (parámetros del entorno).
static func luz(sol: DirectionalLight3D, e: Environment) -> void:
	sol.light_color = Color(1.0, 0.955, 0.88)
	sol.light_energy = 1.22
	e.fog_aerial_perspective = 0.35
	e.fog_sun_scatter = 0.12
	e.ambient_light_energy = 0.42
