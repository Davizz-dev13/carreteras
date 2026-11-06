## Construye el mundo 1:1 a partir de los datos: terreno, carreteras con marcas viales, árboles, cielo y niebla.
class_name Mundo
extends Node3D


var mat_terreno = StandardMaterial3D.new()   # en Gráficos alto (solo .exe) lo sustituye el shader del paisaje real (paisaje.gd)
var mat_asfalto: Variant = StandardMaterial3D.new()   # ShaderMaterial en Gráficos alto (aspecto.gd)
var mat_asfalto2: Variant = StandardMaterial3D.new()
var mat_marca: Variant = StandardMaterial3D.new()
var mat_talud: Variant = StandardMaterial3D.new()
var mat_marca_amarilla := StandardMaterial3D.new()
var mat_copa := StandardMaterial3D.new()
var mat_tronco := StandardMaterial3D.new()
var entorno: Environment
var streaming: MapaStreaming
var terreno_stream: TerrenoStream   # mundo por teselas (scripts/mundo_stream/), si Ajustes.usa_mundo_stream()
var marcas_norma := false     # Gráficos alto (solo .exe): marcas viales según la 8.2-IC y materiales con detalle (aspecto.gd)
var aspecto_web := false      # versión web: materiales del aspecto sin ortofoto (terreno_web.gdshader)


func construir() -> void:
	mat_terreno.vertex_color_use_as_albedo = true
	mat_terreno.roughness = 1.0
	mat_asfalto.albedo_color = Color(0.15, 0.15, 0.15)
	mat_asfalto.roughness = 0.95
	mat_asfalto2.albedo_color = Color(0.2, 0.2, 0.19)
	mat_asfalto2.roughness = 0.9
	mat_talud.albedo_color = Color(0.30, 0.29, 0.21)
	mat_talud.roughness = 1.0
	mat_marca.albedo_color = Color(0.92, 0.92, 0.9)
	mat_marca.roughness = 0.6
	mat_marca_amarilla.albedo_color = Color(0.95, 0.75, 0.1)
	mat_copa.albedo_color = Color(0.13, 0.27, 0.14)
	mat_copa.roughness = 1.0
	mat_tronco.albedo_color = Color(0.36, 0.25, 0.17)
	_cielo()
	mat_terreno = Paisaje.material_terreno(mat_terreno)
	if Paisaje.activo() and Ajustes.args.get("aspecto", "1") == "1":
		# asfalto, marcas y arcenes con detalle (shaders baratos: 2 ruidos de 256 px); el asfalto de las rutas es el
		# aglomerado algo más oscuro de siempre y el de las vías secundarias el gris algo más claro
		marcas_norma = true
		mat_asfalto = Aspecto.asfalto(Color(0.16, 0.16, 0.155))
		mat_asfalto2 = Aspecto.asfalto(Color(0.20, 0.20, 0.19))
		mat_marca = Aspecto.marca()
		mat_talud = Aspecto.talud(mat_terreno)
	elif Rendimiento.es_web() and Ajustes.args.get("aspecto", "1") == "1":
		# versión web: lo barato del aspecto (asfalto, marcas, arcenes y suelo con detalle, luz) sin ortofoto ni árboles
		# nuevos, que no se exportan por tamaño; las mismas mallas, marcas y pinos de siempre
		aspecto_web = true
		mat_asfalto = Aspecto.asfalto(Color(0.16, 0.16, 0.155))
		mat_asfalto2 = Aspecto.asfalto(Color(0.20, 0.20, 0.19))
		mat_marca = Aspecto.marca()
		mat_terreno = _suelo_web(false)
		mat_talud = _suelo_web(true)
	if Ajustes.usa_mundo_stream():
		# suelo y relieve por teselas descargadas (PNOA + LiDAR) hasta el horizonte; las carreteras, quitamiedos,
		# señales y árboles siguen saliendo de los datos de la zona (MapaStreaming, sin su terreno)
		terreno_stream = TerrenoStream.new()
		terreno_stream.preparar(Ajustes.info["origen_utm"])
		add_child(terreno_stream)
		Ajustes.terreno_stream = terreno_stream
		Paisaje.solo_bruma = true
	else:
		Ajustes.terreno_stream = null
		Paisaje.solo_bruma = false
	var paisaje := Paisaje.new()
	add_child(paisaje)
	paisaje.preparar(self, mat_terreno)
	if terreno_stream != null:
		# con la curvatura de la Tierra el terreno lejano baja del horizonte: la mitad de abajo del cielo se ve, así que
		# se pinta del color de la bruma (si no, sale una franja gris de "fin del mundo" en el horizonte)
		var cm := entorno.sky.sky_material as ProceduralSkyMaterial if entorno.sky else null
		if cm:
			cm.ground_horizon_color = entorno.fog_light_color
			cm.ground_bottom_color = entorno.fog_light_color.darkened(0.08)
			cm.ground_curve = 0.25
	# terreno, carreteras y pinos: por streaming (solo una ventana alrededor del coche, ver mapa_streaming.gd)
	streaming = MapaStreaming.new()
	streaming.name = "Streaming"
	streaming.sin_terreno = terreno_stream != null
	streaming.preparar(self)
	add_child(streaming)


func _exit_tree() -> void:
	if Ajustes.terreno_stream == terreno_stream:
		Ajustes.terreno_stream = null


## Suelo de la web: color de siempre (por vértice) con manchas y grano; talud = arcén de grava y tierra
func _suelo_web(talud: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://scripts/terreno_web.gdshader")
	m.set_shader_parameter("detalle", Aspecto.ruido())
	m.set_shader_parameter("grano", Aspecto.grano())
	m.set_shader_parameter("talud", 1.0 if talud else 0.0)
	return m


## Llamar cada fotograma con la posición del coche: libera lo que queda atrás y construye lo de delante
## (unas piezas por fotograma, ≤ 3 ms). Un salto grande (R, reiniciar) reconstruye la ventana de golpe.
func actualizar_streaming(posicion_coche: Vector3, adelante := Vector3.ZERO) -> void:
	streaming.actualizar(posicion_coche, adelante)


## Carga inicial: toda la ventana alrededor de la salida, antes de mostrar el juego.
func cargar_ventana(posicion_coche: Vector3, adelante := Vector3.ZERO) -> void:
	streaming.cargar_ventana(posicion_coche, adelante)


func _cielo() -> void:
	var sol := DirectionalLight3D.new()
	sol.rotation_degrees = Vector3(-38, -35, 0)
	sol.light_energy = 1.15
	sol.shadow_enabled = true
	sol.directional_shadow_max_distance = float(Ajustes.args.get("sombra_dist", "100"))
	# 2 cascadas: los primeros 30 m (el coche) con mucha resolución y hasta 100 m más barata; filtro suave (PCF)
	sol.directional_shadow_mode = int(Ajustes.args.get("sombra_modo", "1"))
	sol.directional_shadow_split_1 = float(Ajustes.args.get("sombra_split", "0.3"))
	sol.directional_shadow_blend_splits = true
	sol.shadow_blur = float(Ajustes.args.get("sombra_blur", "1.0"))
	if Ajustes.args.has("sombra_filtro"):
		RenderingServer.directional_soft_shadow_filter_set_quality(int(Ajustes.args["sombra_filtro"]))
	if Ajustes.args.has("sombra_atlas"):
		RenderingServer.directional_shadow_atlas_set_size(int(Ajustes.args["sombra_atlas"]), true)
	add_child(sol)
	var cielo_mat := ProceduralSkyMaterial.new()
	cielo_mat.sky_top_color = Color(0.32, 0.52, 0.80)
	cielo_mat.sky_horizon_color = Color(0.72, 0.80, 0.88)
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
	entorno.fog_light_color = Color(0.70, 0.77, 0.85)
	entorno.fog_density = 1.0
	entorno.fog_depth_begin = 1500.0
	entorno.fog_depth_end = 13000.0
	entorno.fog_depth_curve = 1.2
	entorno.fog_sky_affect = 0.25
	if (Paisaje.activo() or Rendimiento.es_web()) and Ajustes.args.get("aspecto", "1") == "1":
		Aspecto.luz(sol, entorno)
	var we := WorldEnvironment.new()
	we.environment = entorno
	add_child(we)


## Color del terreno según altitud y pendiente (prados, pinar, roca, cumbres)
func _color_terreno(h: float, inclinacion: float) -> Color:
	var prado := Color(0.36, 0.38, 0.22)
	var pinar := Color(0.16, 0.24, 0.13)
	var roca := Color(0.45, 0.43, 0.40)
	var cumbre := Color(0.50, 0.46, 0.36)
	var c := prado.lerp(pinar, clampf((h - 1150.0) / 250.0, 0.0, 1.0))
	c = c.lerp(cumbre, clampf((h - 1950.0) / 200.0, 0.0, 1.0))
	return c.lerp(roca, clampf((inclinacion - 0.12) / 0.25, 0.0, 1.0))


## Coche low-poly (jugador y tráfico)
static func crear_coche(color: Color) -> Node3D:
	var raiz := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.3
	mat.roughness = 0.45
	var cristal := StandardMaterial3D.new()
	cristal.albedo_color = Color(0.08, 0.1, 0.13)
	cristal.roughness = 0.15
	var negro := StandardMaterial3D.new()
	negro.albedo_color = Color(0.05, 0.05, 0.05)
	var luz := StandardMaterial3D.new()
	luz.albedo_color = Color(1, 0.95, 0.8)
	luz.emission_enabled = true
	luz.emission = Color(1, 0.95, 0.8)
	var piloto_mat := StandardMaterial3D.new()
	piloto_mat.albedo_color = Color(0.7, 0.05, 0.05)
	piloto_mat.emission_enabled = true
	piloto_mat.emission = Color(0.6, 0.0, 0.0)
	var piezas := [
		[Vector3(1.78, 0.62, 4.25), Vector3(0, 0.62, 0), mat],
		[Vector3(1.55, 0.52, 2.1), Vector3(0, 1.18, 0.25), cristal],
		[Vector3(1.5, 0.08, 1.9), Vector3(0, 1.47, 0.25), mat],
		[Vector3(0.35, 0.12, 0.05), Vector3(-0.6, 0.72, -2.13), luz],
		[Vector3(0.35, 0.12, 0.05), Vector3(0.6, 0.72, -2.13), luz],
		[Vector3(0.4, 0.12, 0.05), Vector3(-0.6, 0.75, 2.13), piloto_mat],
		[Vector3(0.4, 0.12, 0.05), Vector3(0.6, 0.75, 2.13), piloto_mat],
	]
	for p in piezas:
		var mi := MeshInstance3D.new()
		var caja := BoxMesh.new()
		caja.size = p[0]
		mi.mesh = caja
		mi.position = p[1]
		mi.material_override = p[2]
		raiz.add_child(mi)
	var rueda := CylinderMesh.new()
	rueda.top_radius = 0.33
	rueda.bottom_radius = 0.33
	rueda.height = 0.22
	rueda.radial_segments = 10
	for pos in [Vector3(-0.82, 0.33, -1.35), Vector3(0.82, 0.33, -1.35), Vector3(-0.82, 0.33, 1.35), Vector3(0.82, 0.33, 1.35)]:
		var mi := MeshInstance3D.new()
		mi.mesh = rueda
		mi.material_override = negro
		mi.position = pos
		mi.rotation_degrees = Vector3(0, 0, 90)
		raiz.add_child(mi)
	return raiz
