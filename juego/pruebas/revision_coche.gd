extends Node
## Solo verificación: revisión visual del coche del jugador (exterior, interior, volante) en una zona vieja.
## -- --dir=carpeta --pref=antes [--zona=navacerrada] [--frames=8]
var j
var cam: Camera3D
var dir_out := ""
var pref := ""
var frames := 8

func _ready() -> void:
	dir_out = Ajustes.args.get("dir", "/tmp")
	pref = Ajustes.args.get("pref", "x")
	frames = int(Ajustes.args.get("frames", "8"))
	var zona: String = Ajustes.args.get("zona", "navacerrada")
	Ajustes.args["zona"] = zona
	Ajustes.rutas.clear()
	Ajustes.cambiar_zona("")
	Ajustes.cambiar_zona(zona)
	j = load("res://escenas/juego.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	print("CARGADA")
	j.pausado = true
	j.hud.visible = false
	cam = Camera3D.new()
	cam.far = 16000.0
	add_child(cam)
	cam.current = true
	var c: Node3D = j.coche
	if Ajustes.args.has("sombras"):
		# variantes del sesgo de sombra del sol (acné en la chapa)
		var sol: DirectionalLight3D = j.find_children("*", "DirectionalLight3D", true, false)[0]
		print("SOL bias %.2f normal_bias %.2f" % [sol.shadow_bias, sol.shadow_normal_bias])
		for v in [[sol.shadow_bias, sol.shadow_normal_bias], [0.1, 2.5], [0.05, 4.0], [0.2, 2.0]]:
			sol.shadow_bias = v[0]
			sol.shadow_normal_bias = v[1]
			var nom := "b%.2f_nb%.1f" % [v[0], v[1]]
			await _foto("sombra_" + nom + "_pilotos", Vector3(1.2, 1.0, 4.8), Vector3(0, 0.85, 2.2), 45.0, 0.05)
			await _foto("sombra_" + nom + "_lado", Vector3(-2.3, 0.9, -1.2), Vector3(-0.8, 0.7, 0.6), 45.0, 0.05)
		get_tree().quit()
		return
	var ojos: Vector3 = j._ojos()
	var partes: String = Ajustes.args.get("partes", "ext,cerca,mov,cab,vol")
	var bajo := ojos - Vector3(0, 0.09, 0)
	# exterior: 8 ángulos
	for a in ([] if not "ext" in partes else [0, 45, 90, 135, 180, 225, 270, 315]):
		var ang := deg_to_rad(float(a))
		await _foto("ext_%03d" % a, Vector3(sin(ang) * 6.5, 1.6, -cos(ang) * 6.5), Vector3(0, 0.7, 0), 45.0, 0.1)
	# primeros planos
	if "cerca" in partes:
		await _foto("rueda_del_izq", Vector3(-2.3, 0.55, -2.6), Vector3(-0.8, 0.35, -1.4), 40.0, 0.05)
		await _foto("rueda_tra_der", Vector3(2.3, 0.55, 2.6), Vector3(0.8, 0.35, 1.4), 40.0, 0.05)
		await _foto("faros", Vector3(-1.2, 0.9, -4.6), Vector3(0, 0.65, -2.1), 45.0, 0.05)
		await _foto("pilotos", Vector3(1.2, 1.0, 4.8), Vector3(0, 0.85, 2.2), 45.0, 0.05)
		await _foto("retrovisor", Vector3(-2.0, 1.35, -1.9), Vector3(-0.95, 1.05, -0.65), 40.0, 0.05)
		await _foto("ventanilla", Vector3(-2.4, 1.3, 0.3), Vector3(0.0, 1.0, -0.2), 50.0, 0.05)
		await _foto("bajos", Vector3(-3.6, 0.12, 0.0), Vector3(0, 0.25, 0), 50.0, 0.05)
		await _foto("techo", Vector3(0.0, 4.5, 2.5), Vector3(0, 0.8, 0), 50.0, 0.1)
	# en marcha: ruedas giradas y freno
	if "mov" in partes:
		_giro(0.5); c.freno = 1.0
		if Catalogo.has_method("luces_freno"): Catalogo.luces_freno(c.modelo, true)
		await _foto("dir_izq_freno", Vector3(-4.0, 1.3, -4.5), Vector3(0, 0.5, -0.5), 45.0, 0.1)
		await _foto("freno_tras", Vector3(0.0, 1.2, 6.5), Vector3(0, 0.8, 0), 45.0, 0.1)
		_giro(0.0); c.freno = 0.0
		if Catalogo.has_method("luces_freno"): Catalogo.luces_freno(c.modelo, false)
	# interior desde el asiento, dos alturas (con la cámara del juego en cabina: el retrovisor se dibuja)
	if "cab" in partes:
		Ajustes.camara = 1
		var vistas := [["frente", 0.0, -3.0, 75.0], ["izq", 70.0, -5.0, 75.0], ["der", -70.0, -5.0, 75.0], ["atras", 165.0, -5.0, 75.0],
			["salpicadero", 0.0, -28.0, 55.0], ["techo", 0.0, 45.0, 75.0], ["espejo_izq", 38.0, -6.0, 45.0], ["espejo_int", -16.0, 12.0, 45.0]]
		for v in vistas:
			await _cabina("cab_%s" % v[0], ojos, v[1], v[2], v[3])
		for v in [vistas[0], vistas[1], vistas[4]]:
			await _cabina("cabbajo_%s" % v[0], bajo, v[1], v[2], v[3])
	# volante: centro, medio izquierda, izquierda a tope, derecha a tope (giro de ruedas en fracción del máximo)
	if "vol" in partes:
		Ajustes.camara = 1
		for g in [["v_centro", 0.0], ["v_medio_izq", -0.5], ["v_tope_izq", -1.0], ["v_tope_der", 1.0]]:
			_giro(g[1])
			await _cabina(g[0], ojos, 0.0, -14.0, 60.0)
		_giro(0.0)
	print("FIN")
	get_tree().quit()

func _giro(frac: float) -> void:
	var c = j.coche
	c.giro = frac * Coche.GIRO_MAX
	Catalogo.animar_ruedas(c.modelo, 0.0, c.giro)
	if Catalogo.has_method("animar_volante"):
		Catalogo.animar_volante(c.modelo, c.giro / Coche.GIRO_MAX, 1.0)

func _foto(nombre: String, desde: Vector3, hacia: Vector3, fov: float, near: float) -> void:
	var t: Transform3D = j.coche.global_transform
	cam.fov = fov
	cam.near = near
	cam.look_at_from_position(t * desde, t * hacia, Vector3.UP)
	await _guardar(nombre)

func _cabina(nombre: String, ojos: Vector3, yaw: float, pitch: float, fov: float) -> void:
	var t: Transform3D = j.coche.global_transform
	cam.fov = fov
	cam.near = float(j.get_script().get_script_constant_map().get("NEAR_CABINA", 0.2))
	var b := t.basis.orthonormalized() * Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0), EULER_ORDER_YXZ)
	cam.global_transform = Transform3D(b, t * ojos)
	if "retrovisor" in j:
		for i in 4:
			j.retrovisor.actualizar(true)
			await get_tree().process_frame
	await _guardar(nombre)

func _guardar(nombre: String) -> void:
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.resize(img.get_width() / 2, img.get_height() / 2, Image.INTERPOLATE_BILINEAR)
	img.save_jpg(dir_out + "/" + pref + "_" + nombre + ".jpg", 0.9)
	print("FOTO ", nombre)
