## Escena de conducción: monta el mundo 1:1, el coche, el tráfico, las cámaras y el HUD.
extends Node3D

var mundo := Mundo.new()
var coche := Coche.new()
var trafico := Trafico.new()
var cam := Camera3D.new()
var ruta: Ruta
var dir := 1                 # sentido de marcha respecto a la ruta
var s_ini := 0.0
var s_fin := 0.0
var s_coche := 0.0
var lat_coche := 0.0
var piloto := true
var crucero := false
var tiempo := 0.0
var v_max := 0.0
var choques := 0
var derrapes := 0
var derrapando_antes := false
var terminado := false
var pausado := false
var cargado := false
var cuadros_video := 0

# HUD
var hud := CanvasLayer.new()
var l_via := Label.new()
var l_modo := Label.new()
var l_vel := Label.new()
var l_alt := Label.new()
var l_pend := Label.new()
var l_aviso := Label.new()
var l_ayuda := Label.new()
var mini_perfil := Perfil.new()
var panel_pausa := PanelContainer.new()
var panel_fin := PanelContainer.new()
var l_fin := Label.new()
var sl_traf := HSlider.new()
var sl_vel := HSlider.new()
var l_traf_p := Label.new()
var l_vel_p := Label.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_leer_args()
	Ajustes.cargar()
	var cargando := Label.new()
	cargando.text = "Cargando terreno y carreteras a escala 1:1…"
	cargando.add_theme_font_size_override("font_size", 26)
	cargando.position = Vector2(60, 60)
	hud.add_child(cargando)
	add_child(hud)
	await get_tree().process_frame
	await get_tree().process_frame
	mundo.construir()
	add_child(mundo)
	ruta = Ajustes.ruta()
	s_ini = clampf(Ajustes.km_ini * 1000.0, 0.0, ruta.longitud())
	s_fin = clampf(Ajustes.km_fin * 1000.0, 0.0, ruta.longitud())
	if is_equal_approx(s_ini, s_fin):
		s_fin = ruta.longitud()
	dir = 1 if s_fin > s_ini else -1
	piloto = Ajustes.piloto
	add_child(coche)
	trafico.iniciar(ruta, Ajustes.trafico)
	add_child(trafico)
	cam.near = 0.2
	cam.far = 16000.0
	cam.fov = 70.0
	add_child(cam)
	cam.current = true
	cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF   # la cámara se mueve en _process
	cargando.queue_free()
	_crear_hud()
	_reiniciar()
	cargado = true
	if Ajustes.args.has("captura"):
		_captura()


func _leer_args() -> void:
	var a := Ajustes.args
	if a.has("ruta"): Ajustes.ruta_idx = int(a["ruta"])
	if a.has("km_ini"): Ajustes.km_ini = float(a["km_ini"])
	if a.has("km_fin"): Ajustes.km_fin = float(a["km_fin"])
	if a.has("vel"): Ajustes.velocidad = float(a["vel"])
	if a.has("trafico"): Ajustes.trafico = float(a["trafico"]) / 100.0
	if a.has("piloto"): Ajustes.piloto = a["piloto"] == "1"
	if a.has("curvas"): Ajustes.adaptar_curvas = a["curvas"] == "1"
	if a.has("camara"): Ajustes.camara = int(a["camara"])


## Coloca el coche en el carril derecho del punto actual (o del inicio del tramo)
func _reiniciar(en_inicio := true) -> void:
	var s := s_ini if en_inicio else s_coche
	var lado := dir * ruta.valor(ruta.ancho, s) * 0.25
	coche.colocar(ruta.punto(s) + ruta.derecha(s) * lado, ruta.tangente(s) * dir)
	s_coche = s
	reiniciar_camara()
	if en_inicio:
		tiempo = 0.0
		coche.odometro = 0.0
		v_max = 0.0
		choques = 0
		derrapes = 0
		terminado = false
		panel_fin.visible = false
		coche.v = minf(Ajustes.velocidad, 40.0) / 3.6 if piloto else 0.0


func _physics_process(dt: float) -> void:
	if not cargado or pausado:
		return
	_simular(dt)


func _simular(dt: float) -> void:
	var p := ruta.proyectar(coche.position, s_coche)
	s_coche = p.x
	lat_coche = p.y
	_mandos(dt)
	coche.paso_fisica(dt)
	var lado_jug := 1 if lat_coche > 0.0 else -1
	var en_ruta := absf(lat_coche) < ruta.valor(ruta.ancho, s_coche) * 0.5 + 1.5
	trafico.factor = Ajustes.trafico
	trafico.actualizar(dt, s_coche, lat_coche, coche.v * dir, lado_jug if en_ruta else 0)
	_choques()
	if not terminado:
		tiempo += dt
		v_max = maxf(v_max, absf(coche.v))
		if coche.derrapando and not derrapando_antes:
			derrapes += 1
		if (s_coche - s_fin) * dir >= 0.0 and absf(lat_coche) < 25.0:
			_fin()
	derrapando_antes = coche.derrapando


## Teclado, crucero o piloto automático
func _mandos(_dt: float) -> void:
	var acel := Input.get_action_strength("ui_up") if Input.is_action_pressed("ui_up") else 0.0
	if Input.is_physical_key_pressed(KEY_W): acel = 1.0
	var fren := 1.0 if (Input.is_physical_key_pressed(KEY_S) or Input.is_action_pressed("ui_down")) else 0.0
	var vol := 0.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_action_pressed("ui_left"): vol -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_action_pressed("ui_right"): vol += 1.0
	if Input.is_physical_key_pressed(KEY_SPACE): fren = 1.0
	if terminado:
		coche.acelerador = 0.0
		coche.freno = 0.6
		coche.giro_directo = piloto
		if piloto: coche.volante = _volante_piloto()
		else: coche.volante = vol
		return
	if piloto and (acel > 0.0 or fren > 0.0 or vol != 0.0):
		piloto = false            # tocar los mandos desconecta el piloto (como en un coche real)
		crucero = false
	if piloto:
		coche.giro_directo = true
		coche.volante = _volante_piloto()
		_control_velocidad(_velocidad_objetivo())
		return
	coche.giro_directo = false
	coche.volante = vol
	if crucero and acel == 0.0 and fren == 0.0:
		_control_velocidad(Ajustes.velocidad / 3.6)
		return
	if fren > 0.0 and coche.v < 0.3 and not Input.is_physical_key_pressed(KEY_SPACE):
		coche.marcha_atras = true
		coche.acelerador = fren
		coche.freno = 0.0
		return
	if acel > 0.0:
		coche.marcha_atras = false
	coche.acelerador = acel if not coche.marcha_atras else 0.0
	coche.freno = fren if not coche.marcha_atras else (1.0 if acel > 0.0 else 0.0)
	if coche.marcha_atras and acel == 0.0 and fren == 0.0:
		coche.freno = 0.3


## Persecución pura ("pure pursuit") de un punto del carril derecho por delante
func _volante_piloto() -> float:
	var mira := clampf(absf(coche.v) * 0.75, 7.0, 26.0)
	var s := s_coche + dir * mira
	var obj := ruta.punto(s) + ruta.derecha(s) * dir * ruta.valor(ruta.ancho, s) * 0.25
	var fw := coche.adelante()
	var der := Vector3(-fw.z, 0.0, fw.x)
	var d := obj - coche.position
	var x := d.dot(der)
	var z := d.dot(fw)
	var ld := maxf(sqrt(x * x + z * z), 1.0)
	var alfa := atan2(x, z)
	return atan(2.0 * coche.ficha.batalla * sin(alfa) / ld)


## Velocidad del piloto: la elegida, limitada por curvas (si se adapta) y por el coche de delante (IDM)
func _velocidad_objetivo() -> float:
	var v0 := Ajustes.velocidad / 3.6
	if Ajustes.adaptar_curvas:
		v0 = minf(v0, trafico.vel_curva(s_coche, dir, 4.0, 220.0))
	return v0


func _control_velocidad(v0: float) -> void:
	var hueco := 1e4
	var v_lider := v0
	for c in trafico.coches:
		if c["dir"] != dir: continue
		var d: float = (c["s"] - s_coche) * dir
		if d > 0.0 and d - trafico.largo < hueco:
			hueco = d - trafico.largo
			v_lider = c["v"]
	var v := absf(coche.v)
	var a := clampf(trafico.idm(v, v0, hueco, v - v_lider) * 1.6, -8.0, 3.0)
	# fuerza necesaria = inercia + aerodinámica + rodadura + gravedad de la pendiente real
	var fw := coche.adelante()
	var lb := coche.ficha.batalla * 0.5
	var seno := clampf((coche._altura(coche.position + fw * lb) - coche._altura(coche.position - fw * lb)) / (2.0 * lb), -0.5, 0.5)
	var fi := coche.ficha
	var f := fi.masa * a + coche.fuerza_resistente(v) + fi.masa * Coche.G * seno
	coche.marcha_atras = false
	if f >= 0.0:
		coche.acelerador = clampf(f / coche.fuerza_motor(v), 0.0, 1.0)
		coche.freno = 0.0
	else:
		coche.acelerador = 0.0
		coche.freno = clampf(-f / fi.f_freno_max, 0.0, 1.0)


func _choques() -> void:
	var fw := coche.adelante()
	var der := Vector3(-fw.z, 0.0, fw.x)
	for c in trafico.cerca_de(coche.position, 7.0):
		var d: Vector3 = (c["nodo"] as Node3D).position - coche.position
		if absf(d.dot(der)) < 1.8 and absf(d.dot(fw)) < 4.3 and coche.choque_t <= 0.0:
			choques += 1
			coche.choque_t = 2.0
			coche.v *= 0.15
			c["v"] = 0.0


func _fin() -> void:
	terminado = true
	var t := ruta.resumen_tramo(s_ini, s_fin)
	var dist := coche.odometro
	l_fin.text = ("¡Tramo completado!\n\n%s\nkm %s → km %s  (%s km)\n\nTiempo: %s\nVelocidad media: %s km/h\nVelocidad máxima: %s km/h\n" +
		"Pendiente máxima (100 m): %s %%\nDesnivel acumulado: +%d m / −%d m\nDe %d m a %d m de altitud\nDerrapes: %d · Choques: %d") % [
		ruta.nombre, _num(s_ini / 1000.0, 1), _num(s_fin / 1000.0, 1), _num(dist / 1000.0, 2), _reloj(tiempo),
		_num(dist / maxf(tiempo, 0.1) * 3.6, 1), _num(v_max * 3.6, 0), _num(t["pendiente_max"], 1),
		roundi(t["sube"]), roundi(t["baja"]), roundi(t["z_ini"]), roundi(t["z_fin"]), derrapes, choques]
	panel_fin.visible = true


func _unhandled_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo) or not cargado:
		return
	match ev.physical_keycode:
		KEY_ESCAPE:
			_pausa(not pausado)
		KEY_V:
			Ajustes.camara = 1 - Ajustes.camara
		KEY_P:
			piloto = not piloto
			crucero = false
		KEY_C:
			crucero = not crucero
			piloto = false
		KEY_R:
			_reiniciar(false)
		KEY_H:
			l_ayuda.visible = not l_ayuda.visible
		KEY_K:
			Ajustes.adaptar_curvas = not Ajustes.adaptar_curvas
		KEY_EQUAL, KEY_KP_ADD, KEY_PLUS:
			Ajustes.velocidad = minf(Ajustes.velocidad + 5.0, 200.0)
		KEY_MINUS, KEY_KP_SUBTRACT:
			Ajustes.velocidad = maxf(Ajustes.velocidad - 5.0, 10.0)
		KEY_0:
			Ajustes.trafico = minf(Ajustes.trafico + 0.1, 1.0)
		KEY_9:
			Ajustes.trafico = maxf(Ajustes.trafico - 0.1, 0.0)


func _process(dt: float) -> void:
	if not cargado:
		return
	_camara(dt)
	_hud()
	_telemetria()
	if Ajustes.args.get("captura", "") == "video":
		cuadros_video += 1
		if cuadros_video >= int(Ajustes.args.get("cuadros", "450")):
			get_tree().quit()


## Cámaras (v2, sin vibración):
##  · se usa la posición INTERPOLADA del coche (la física va a 60 Hz y la pantalla puede ir a 30, 60 o 144 Hz)
##  · persecución: posición y punto de mira siguen al coche con muelles de amortiguación crítica
##    (sin rebote ni tirones); el horizonte siempre recto (sin balanceo)
##  · cabina: va pegada al coche en rumbo, pero el cabeceo y el balanceo se filtran (como la cabeza del conductor)
var cam_vel := Vector3.ZERO
var mira := Vector3.ZERO
var mira_vel := Vector3.ZERO
var cab_cam := 0.0
var bal_cam := 0.0
var cam_iniciada := false


## Muelle con amortiguación crítica (SmoothDamp): sigue a `objetivo` sin sobrepasarlo. tiempo ≈ s de respuesta.
static func amortiguar(actual: Vector3, objetivo: Vector3, vel: Vector3, tiempo: float, dt: float) -> Array:
	var w := 2.0 / maxf(tiempo, 0.001)
	var x := w * dt
	var e := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var cambio := actual - objetivo
	var temp := (vel + cambio * w) * dt
	var vel_n := (vel - temp * w) * e
	return [objetivo + (cambio + temp) * e, vel_n]


func reiniciar_camara() -> void:
	cam_iniciada = false


func _camara(dt: float) -> void:
	var tc := coche.get_global_transform_interpolated()
	var pos := tc.origin
	var fw := -tc.basis.z
	fw.y = 0.0
	fw = fw.normalized() if fw.length() > 0.01 else coche.adelante()
	if Ajustes.camara == 1:
		# cabina: rumbo exacto del coche, cabeceo/balanceo filtrados
		var e := tc.basis.get_euler(EULER_ORDER_YXZ)
		var k := 1.0 - exp(-dt * 8.0) if cam_iniciada else 1.0
		cab_cam = lerp_angle(cab_cam, e.x, k)
		bal_cam = lerp_angle(bal_cam, e.z, k)
		var b := Basis.from_euler(Vector3(cab_cam, e.y, bal_cam), EULER_ORDER_YXZ)
		var asiento := _ojos()
		cam.global_transform = Transform3D(b, pos + b * asiento)
		cam.fov = 75.0
		cam_iniciada = true
		return
	cam.fov = 70.0
	if Ajustes.args.has("foto"):
		# foto del coche (verificación / README): cámara en órbita a `foto` grados del morro
		var ang := deg_to_rad(float(Ajustes.args["foto"]))
		var der := Vector3(-fw.z, 0.0, fw.x)
		cam.global_position = pos + (fw * cos(ang) + der * sin(ang)) * 6.5 + Vector3.UP * 1.6
		cam.look_at(pos + Vector3.UP * 0.7, Vector3.UP)
		cam.fov = 45.0
		return
	var objetivo := pos - fw * (6.0 + coche.ficha.largo) + Vector3.UP * 3.2
	var suelo := Ajustes.superficie.consultar(objetivo.x, objetivo.z, objetivo.y).x
	objetivo.y = maxf(objetivo.y, suelo + 1.5)
	var punto_mira := pos + fw * 5.0 + Vector3.UP * 1.2
	if not cam_iniciada or cam.global_position.distance_to(objetivo) > 60.0:
		cam.global_position = objetivo
		mira = punto_mira
		cam_vel = Vector3.ZERO
		mira_vel = Vector3.ZERO
		cam_iniciada = true
	else:
		var r := amortiguar(cam.global_position, objetivo, cam_vel, 0.28, dt)
		cam.global_position = r[0]
		cam_vel = r[1]
		var r2 := amortiguar(mira, punto_mira, mira_vel, 0.12, dt)
		mira = r2[0]
		mira_vel = r2[1]
	cam.look_at(mira, Vector3.UP)


func _ojos() -> Vector3:
	var o: Array = Catalogo.modelo_de(coche.ficha).get("ojos", [-0.37, 1.12, 0.25])
	return Vector3(float(o[0]), float(o[1]), float(o[2]))


# ---------------- HUD ----------------
func _num(x: float, dec: int) -> String:
	var s := ("%." + str(dec) + "f") % x
	s = s.replace(".", ",")
	return s


func _miles(x: int) -> String:
	var s := str(absi(x))
	var r := ""
	while s.length() > 3:
		r = "." + s.right(3) + r
		s = s.left(s.length() - 3)
	return ("-" if x < 0 else "") + s + r


func _reloj(t: float) -> String:
	return "%d:%02d,%d" % [int(t / 60.0), int(t) % 60, int(fmod(t, 1.0) * 10.0)]


func _caja(pos: Vector2, hijo: Control) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)
	sb.set_content_margin_all(10)
	sb.set_corner_radius_all(6)
	p.add_theme_stylebox_override("panel", sb)
	p.position = pos
	p.add_child(hijo)
	hud.add_child(p)
	return p


func _crear_hud() -> void:
	var izq := VBoxContainer.new()
	l_via.add_theme_font_size_override("font_size", 20)
	izq.add_child(l_via)
	_caja(Vector2(16, 14), izq)
	var abajo := VBoxContainer.new()
	l_vel.add_theme_font_size_override("font_size", 46)
	l_alt.add_theme_font_size_override("font_size", 22)
	l_pend.add_theme_font_size_override("font_size", 22)
	abajo.add_child(l_vel)
	abajo.add_child(l_alt)
	abajo.add_child(l_pend)
	var caja_v := _caja(Vector2(16, 0), abajo)
	caja_v.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	caja_v.position = Vector2(16, get_viewport().get_visible_rect().size.y - 170)
	l_modo.add_theme_font_size_override("font_size", 17)
	l_modo.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var caja_m := _caja(Vector2(get_viewport().get_visible_rect().size.x - 330, 14), l_modo)
	caja_m.custom_minimum_size.x = 314
	l_aviso.add_theme_font_size_override("font_size", 26)
	l_aviso.add_theme_color_override("font_color", Color(1, 0.3, 0.2))
	l_aviso.add_theme_color_override("font_outline_color", Color.BLACK)
	l_aviso.add_theme_constant_override("outline_size", 6)
	l_aviso.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l_aviso.size = Vector2(800, 40)
	l_aviso.position = Vector2(get_viewport().get_visible_rect().size.x / 2 - 400, 120)
	hud.add_child(l_aviso)
	mini_perfil.ruta = ruta
	mini_perfil.compacto = true
	mini_perfil.s0 = s_ini
	mini_perfil.s1 = s_fin
	var vs := get_viewport().get_visible_rect().size
	mini_perfil.size = Vector2(420, 78)
	mini_perfil.position = Vector2(290, vs.y - 92)
	hud.add_child(mini_perfil)
	l_ayuda.text = ("W/↑ acelerar · S/↓ frenar (parado: marcha atrás) · A D/← → girar · Espacio freno\n" +
		"P piloto automático · C crucero · +/− velocidad · K adaptar en curvas · 9/0 tráfico\n" +
		"V cámara · R volver a la carretera · Esc pausa · H ocultar ayuda")
	l_ayuda.add_theme_font_size_override("font_size", 13)
	var caja_a := _caja(Vector2(vs.x - 520, vs.y - 86), l_ayuda)
	caja_a.custom_minimum_size.x = 500
	_crear_pausa()
	_crear_fin()


func _hud() -> void:
	var nombre := ""
	if absf(lat_coche) < ruta.valor(ruta.ancho, s_coche) * 0.5 + 2.0:
		nombre = ruta.rotulo(s_coche)
	elif coche.id_via >= 0:
		nombre = Ajustes.superficie.nombres[coche.id_via]
	else:
		nombre = "Fuera de la carretera"
	var falta := absf(s_fin - s_coche) / 1000.0
	l_via.text = "%s\nPK %s km de la ruta · recorrido %s km · faltan %s km" % [
		nombre, _num(s_coche / 1000.0, 2), _num(coche.odometro / 1000.0, 2), _num(falta if not terminado else 0.0, 2)]
	l_vel.text = "%d km/h" % roundi(absf(coche.v) * 3.6)
	l_alt.text = "Altitud: %s m" % _miles(roundi(coche.position.y))
	# pendiente: la real de la ruta en el sentido de marcha (o la del terreno si estás fuera)
	var g := 0.0
	if absf(lat_coche) < 15.0:
		g = ruta.valor(ruta.pendiente, s_coche) * dir
	else:
		g = tan(coche.rotation.x) * 100.0
	var flecha := "↗" if g > 0.5 else ("↘" if g < -0.5 else "→")
	l_pend.text = "Pendiente: %s %s %%" % [flecha, ("+" if g > 0 else "") + _num(g, 1)]
	l_pend.add_theme_color_override("font_color", Color(1, 1, 1).lerp(Color(1, 0.35, 0.2), clampf(absf(g) / 10.0, 0.0, 1.0)))
	var modo := "PILOTO AUTOMÁTICO" if piloto else ("CRUCERO" if crucero else "MANUAL")
	l_modo.text = coche.ficha.nombre + " · %d CV\n" % roundi(coche.ficha.potencia_cv) + "%s\nVelocidad elegida: %d km/h\nAdaptar en curvas: %s\nTráfico: %d %% (%d coches)\nCámara: %s" % [
		modo, roundi(Ajustes.velocidad), "sí" if Ajustes.adaptar_curvas else "no", roundi(Ajustes.trafico * 100.0),
		trafico.coches.size(), "cabina" if Ajustes.camara == 1 else "persecución"]
	mini_perfil.marcador = s_coche
	mini_perfil.queue_redraw()
	# avisos
	var aviso := ""
	var v_lim_100 := 1e9
	var d := 0.0
	while d <= 100.0:
		var k := absf(ruta.valor(ruta.curvatura, s_coche + dir * d))
		v_lim_100 = minf(v_lim_100, sqrt(Coche.MU_ASFALTO * Coche.G / maxf(k, 1e-5)))
		d += 5.0
	if coche.derrapando:
		aviso = "¡DERRAPE! A %d km/h el neumático no da para este giro" % roundi(absf(coche.v) * 3.6)
	elif absf(coche.v) > v_lim_100 and v_lim_100 < 60.0:
		aviso = "¡Curva cerrada! Límite físico ≈ %d km/h" % roundi(v_lim_100 * 3.6)
	elif coche.choque_t > 0.0:
		aviso = "¡Choque!"
	elif not coche.en_carretera:
		aviso = "Fuera de la carretera · pulsa R"
	l_aviso.text = aviso


func _crear_pausa() -> void:
	panel_pausa.process_mode = Node.PROCESS_MODE_ALWAYS
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	var t := Label.new()
	t.text = "Pausa"
	t.add_theme_font_size_override("font_size", 28)
	v.add_child(t)
	for par in [[sl_traf, l_traf_p, 0.0, 100.0, 5.0], [sl_vel, l_vel_p, 10.0, 200.0, 5.0]]:
		var s: HSlider = par[0]
		s.min_value = par[2]
		s.max_value = par[3]
		s.step = par[4]
		s.custom_minimum_size.x = 380
		v.add_child(par[1])
		v.add_child(s)
	sl_traf.value_changed.connect(_al_cambiar_trafico)
	sl_vel.value_changed.connect(_al_cambiar_velocidad)
	var b1 := Button.new()
	b1.text = "Continuar"
	b1.pressed.connect(func(): _pausa(false))
	var b2 := Button.new()
	b2.text = "Volver al inicio del tramo"
	b2.pressed.connect(_volver_al_inicio)
	var b3 := Button.new()
	b3.text = "Menú principal"
	b3.pressed.connect(func(): get_tree().change_scene_to_file("res://escenas/menu.tscn"))
	for b in [b1, b2, b3]:
		v.add_child(b)
	_caja_centrada(panel_pausa, v)
	panel_pausa.visible = false


func _al_cambiar_trafico(x: float) -> void:
	Ajustes.trafico = x / 100.0
	l_traf_p.text = "Tráfico: %d %%" % roundi(x)


func _al_cambiar_velocidad(x: float) -> void:
	Ajustes.velocidad = x
	l_vel_p.text = "Velocidad elegida: %d km/h" % roundi(x)


func _volver_al_inicio() -> void:
	_pausa(false)
	_reiniciar(true)


func _crear_fin() -> void:
	var v := VBoxContainer.new()
	l_fin.add_theme_font_size_override("font_size", 19)
	v.add_child(l_fin)
	var b1 := Button.new()
	b1.text = "Repetir tramo"
	b1.pressed.connect(func(): _reiniciar(true))
	var b2 := Button.new()
	b2.text = "Menú principal"
	b2.pressed.connect(func(): get_tree().change_scene_to_file("res://escenas/menu.tscn"))
	v.add_child(b1)
	v.add_child(b2)
	_caja_centrada(panel_fin, v)
	panel_fin.visible = false


func _caja_centrada(p: PanelContainer, hijo: Control) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.09, 0.9)
	sb.set_content_margin_all(22)
	sb.set_corner_radius_all(8)
	p.add_theme_stylebox_override("panel", sb)
	p.add_child(hijo)
	hud.add_child(p)
	var vs := get_viewport().get_visible_rect().size
	p.position = Vector2(vs.x / 2 - 220, vs.y / 2 - 230)


func _pausa(on: bool) -> void:
	pausado = on
	panel_pausa.visible = on
	if on:
		sl_traf.value = Ajustes.trafico * 100.0
		sl_vel.value = Ajustes.velocidad
		l_traf_p.text = "Tráfico: %d %%" % roundi(sl_traf.value)
		l_vel_p.text = "Velocidad elegida: %d km/h" % roundi(sl_vel.value)


# ---------------- verificación automática ----------------
## --captura=conduccion|video: simula unos segundos de conducción y guarda una imagen (o deja grabar el vídeo)
func _captura() -> void:
	var presim := float(Ajustes.args.get("presim", "6"))
	var n := int(presim * 60.0)
	for i in n:
		_simular(1.0 / 60.0)
		if Ajustes.args.get("traza", "") == "1" and i % 1800 == 0:
			print("  t=%4.0f s  PK %.2f km  lat %+.2f m  %3.0f km/h  alt %.0f  coches %d  derrapes %d choques %d fin=%s" % [
				tiempo, s_coche / 1000.0, lat_coche, coche.v * 3.6, coche.position.y, trafico.coches.size(), derrapes, choques, terminado])
		if terminado and Ajustes.args["captura"] == "prueba":
			break
	coche.reset_physics_interpolation()
	trafico.reiniciar_interpolacion()
	reiniciar_camara()
	print("CAPTURA terminado=%s tiempo=%.0f s choques=%d s=%.1f km lat=%.2f v=%.1f km/h alt=%.1f via=%d coches=%d derrapes=%d" % [terminado, tiempo, choques, s_coche / 1000.0, lat_coche,
		coche.v * 3.6, coche.position.y, coche.id_via, trafico.coches.size(), derrapes])
	if Ajustes.args["captura"] == "video":
		return
	if Ajustes.args["captura"] == "prueba":
		get_tree().quit()
		return
	pausado = true
	for i in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(Ajustes.args.get("salida", "user://captura.png"))
	get_tree().quit()

var _tele := PackedStringArray()
func _telemetria() -> void:
	if not Ajustes.args.has("telemetria"):
		return
	var cb := cam.global_transform.basis.get_euler(EULER_ORDER_YXZ)
	var vb := coche.global_transform.basis.get_euler(EULER_ORDER_YXZ)
	var mp := coche.get_global_transform_interpolated().origin
	vb = coche.get_global_transform_interpolated().basis.get_euler(EULER_ORDER_YXZ)
	_tele.append("%d,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.3f" % [Engine.get_process_frames(), mp.x, mp.y, mp.z,
		vb.x, vb.y, vb.z, cam.global_position.x, cam.global_position.y, cam.global_position.z, cb.x, cb.y, cb.z, coche.v])
	if cuadros_video + 1 >= int(Ajustes.args.get("cuadros", "450")):
		var f := FileAccess.open(Ajustes.args["telemetria"], FileAccess.WRITE)
		f.store_string("frame,cx,cy,cz,cpitch,cyaw,croll,kx,ky,kz,kpitch,kyaw,kroll,v\n" + "\n".join(_tele))
		f.close()
