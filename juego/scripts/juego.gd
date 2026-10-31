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
var colisiones := Colisiones.new()
# adelantamiento a petición (tecla O): 0 = no, 1 = esperando hueco, 2 = saliendo/pasando, 3 = volviendo a su carril
var adel_estado := 0
var adel_carril := 0.0          # 0 = carril propio … 1 = carril contrario (suavizado)
var adel_lider: Dictionary = {}
var adel_ultimo: Dictionary = {}  # último coche del grupo que se adelanta
var adel_msg := ""
var adel_msg_t := 0.0
var adel_revisar := 0.0
var adelantamientos := 0
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
var l_ayuda := Label.new()
var mini_perfil := Perfil.new()
var mini_mapa := MapaRuta.new()
var senal := SenalLimite.new()
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
	colisiones.juego = self
	_reiniciar()
	mundo.cargar_ventana(coche.position, ruta.tangente(s_ini) * dir)   # streaming: el mapa alrededor de la salida
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
	var fw0 := coche.adelante()
	var prev_jug := {"p": Vector2(coche.position.x, coche.position.z), "f": Vector2(fw0.x, fw0.z)}
	coche.paso_fisica(dt)
	var lado_jug := 1 if lat_coche > 0.0 else -1
	var en_ruta := absf(lat_coche) < ruta.valor(ruta.ancho, s_coche) * 0.5 + 1.5
	trafico.factor = Ajustes.trafico
	trafico.actualizar(dt, s_coche, lat_coche, coche.v * dir, lado_jug if en_ruta else 0)
	colisiones.mover_sueltos(dt)
	colisiones.resolver(dt, prev_jug)
	choques = colisiones.golpes
	_adelantamiento(dt)
	if not terminado:
		tiempo += dt
		v_max = maxf(v_max, absf(coche.v))
		if coche.derrapando and not derrapando_antes:
			derrapes += 1
		if (s_coche - s_fin) * dir >= 0.0 and absf(lat_coche) < 25.0:
			_fin()
	derrapando_antes = coche.derrapando


## Teclado o piloto automático
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
		_cancelar_adelantamiento("")
	if piloto:
		coche.giro_directo = true
		coche.volante = _volante_piloto()
		_control_velocidad(_velocidad_objetivo())
		return
	coche.giro_directo = false
	coche.volante = vol
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
	var obj := ruta.punto(s) + ruta.derecha(s) * dir * ruta.valor(ruta.ancho, s) * 0.25 * (1.0 - 2.0 * adel_carril)
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
	if adel_estado == 3 and adel_abortado and not adel_lider.is_empty():
		v0 = minf(v0, float(adel_lider["v"]) - 15.0 / 3.6)
	elif adel_estado == 2 and not adel_lider.is_empty():
		# para pasar hace falta ir claramente más rápido que el adelantado (+25 km/h como mínimo)
		v0 = maxf(v0, float(adel_lider["v"]) + 25.0 / 3.6)
	if Ajustes.adaptar_curvas:
		v0 = minf(v0, trafico.vel_curva(s_coche, dir, 4.0, 220.0))
	return v0


func _control_velocidad(v0: float) -> void:
	var hueco := 1e4
	var v_lider := v0
	for c in trafico.coches:
		if c["dir"] != dir: continue
		if adel_carril > 0.45: continue     # en el carril contrario: los de nuestro sentido van al lado
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
	if adel_estado == 2 and v < v0:
		f = coche.fuerza_motor(v)      # adelantando: a fondo (como en la comprobación de seguridad)
	if f >= 0.0:
		coche.acelerador = clampf(f / coche.fuerza_motor(v), 0.0, 1.0)
		coche.freno = 0.0
	else:
		coche.acelerador = 0.0
		coche.freno = clampf(-f / fi.f_freno_max, 0.0, 1.0)


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
			if not piloto: _cancelar_adelantamiento("")
		KEY_O:
			_pedir_adelantamiento()
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
	mundo.actualizar_streaming(coche.position, coche.adelante())
	_camara(dt)
	_hud()
	_telemetria()
	_medir_fps()
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
	mini_perfil.ruta = ruta
	mini_perfil.compacto = true
	mini_perfil.s0 = s_ini
	mini_perfil.s1 = s_fin
	var vs := get_viewport().get_visible_rect().size
	# franja de abajo: mitad perfil de altitud, mitad mapa de la ruta
	mini_perfil.size = Vector2(210, 110)
	mini_perfil.position = Vector2(290, vs.y - 124)
	mini_perfil.interactivo = true
	mini_perfil.mouse_filter = Control.MOUSE_FILTER_STOP
	mini_perfil.tooltip_text = ""
	mini_perfil.salto.connect(_saltar_a)
	hud.add_child(mini_perfil)
	mini_mapa.ruta = ruta
	mini_mapa.s0 = s_ini
	mini_mapa.s1 = s_fin
	mini_mapa.sentido = dir
	mini_mapa.position = Vector2(506, vs.y - 124)
	mini_mapa.size = Vector2(204, 110)
	mini_mapa.mouse_filter = Control.MOUSE_FILTER_STOP
	mini_mapa.salto.connect(_saltar_a)
	hud.add_child(mini_mapa)
	mini_mapa.preparar()
	# límite de velocidad del tramo (si existe el fichero de límites)
	senal.size = Vector2(64, 64)
	senal.position = Vector2(262, vs.y - 214)
	senal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	senal.cargar(Ajustes.ruta_idx, ruta.nombre)
	senal.visible = false
	hud.add_child(senal)
	l_ayuda.text = ("W/↑ acelerar · S/↓ frenar (parado: marcha atrás)\n" +
		"P piloto automático · O adelantar · +/− velocidad · K curvas · 9/0 tráfico\n" +
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
	var modo := "PILOTO AUTOMÁTICO" if piloto else "MANUAL"
	if adel_estado == 1: modo += "\nAdelantamiento: esperando hueco"
	elif adel_estado == 2: modo += "\nAdelantando…"
	elif adel_estado == 3: modo += "\nAdelantamiento: volviendo al carril"
	elif adel_msg_t > 0.0: modo += "\n" + adel_msg
	l_modo.text = coche.ficha.nombre + " · %d CV\n" % roundi(coche.ficha.potencia_cv) + "%s\nVelocidad elegida: %d km/h\nAdaptar en curvas: %s\nTráfico: %d %%\nCámara: %s" % [
		modo, roundi(Ajustes.velocidad), "sí" if Ajustes.adaptar_curvas else "no", roundi(Ajustes.trafico * 100.0),
		"cabina" if Ajustes.camara == 1 else "persecución"]
	mini_perfil.marcador = s_coche
	mini_mapa.actualizar(s_coche)
	senal.actualizar(s_coche, dir)
	var pasado := senal.visible and senal.limite > 0 and absf(coche.v) * 3.6 > senal.limite + 5.0
	l_vel.add_theme_color_override("font_color", Color(1, 0.3, 0.25) if pasado else Color.WHITE)
	mini_perfil.queue_redraw()


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
	if Ajustes.args["captura"] == "giro":
		_prueba_giro()
		return
	if Ajustes.args["captura"] == "perfil":
		_prueba_perfil()
		return
	if Ajustes.args["captura"] in ["choque_alcance", "choque_frontal", "adelantar"]:
		_prueba(Ajustes.args["captura"])
		return
	if Ajustes.args.has("poner_trafico"):
		# para la foto del tráfico: uno delante en nuestro carril y dos de frente
		trafico.crear_prueba(s_coche + dir * 45.0, dir, 12.0, false)
		trafico.crear_prueba(s_coche + dir * 120.0, -dir, 14.0, false)
		trafico.crear_prueba(s_coche + dir * 170.0, -dir, 14.0, false)
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
	mundo.cargar_ventana(coche.position, coche.adelante())
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


## --medir_fps=N: mide los FPS medios en N fotogramas (tras 60 de calentamiento) y sale (verificación)
var _fps_n := 0
var _fps_t0 := 0
func _medir_fps() -> void:
	if not Ajustes.args.has("medir_fps"):
		return
	_fps_n += 1
	if _fps_n == 60:
		_fps_t0 = Time.get_ticks_usec()
	var n := int(Ajustes.args["medir_fps"])
	if _fps_n == 60 + n:
		var t := (Time.get_ticks_usec() - _fps_t0) / 1e6
		print("FPS_MEDIDO %.2f (%d fotogramas en %.2f s, %d coches de tráfico, %d draw calls, %d primitivas)" % [n / t, n, t, trafico.coches.size(),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
		get_tree().quit()


# ---------------- adelantamiento a petición (tecla O) ----------------
## Solo con el piloto automático y solo cuando el jugador lo pide. Antes de salir comprueba, con la aceleración
## REAL de esta versión (motor, aire, rodadura y la pendiente real del tramo), cuánto tiempo y cuántos metros
## necesita para pasar, y que en toda esa zona: no haya línea continua (el juego la pinta en curvas de radio
## < 350 m), se vea la carretera lo bastante lejos (curvas y cambios de rasante) para un coche que viniera de
## frente a la velocidad máxima de la vía, y ningún coche real de frente llegue antes de terminar.
const ADEL_MARGEN := 12.0        # m por delante del último adelantado antes de volver al carril
const ADEL_T_CAMBIO := 2.2       # s para cambiar de carril
const ADEL_HUECO_GRUPO := 30.0   # coches pegados al líder (< 30 m) se adelantan de una vez
var adel_motivo := ""
var adel_abortado := false


func _aviso_adel(msg: String) -> void:
	adel_msg = msg
	adel_msg_t = 3.0


func _pedir_adelantamiento() -> void:
	if adel_estado == 1:
		_cancelar_adelantamiento("Adelantamiento cancelado")
		return
	if adel_estado >= 2:
		return
	if not piloto:
		_aviso_adel("Activa el piloto (P) para adelantar")
		return
	var l := _lider_lento()
	if l.is_empty():
		_aviso_adel("No hay ningún coche lento delante")
		return
	adel_lider = l
	adel_estado = 1
	adel_revisar = 0.0
	adel_motivo = ""


func _cancelar_adelantamiento(msg: String) -> void:
	adel_estado = 3 if adel_carril > 0.0 else 0
	if msg != "":
		_aviso_adel(msg)


func _existe(c: Dictionary) -> bool:
	for o in trafico.coches:
		if is_same(o, c):
			return true
	return false


## El coche de nuestro sentido más cercano por delante (hasta 70 m) que va más lento de lo que queremos ir
func _lider_lento() -> Dictionary:
	var mejor := {}
	var dmin := 70.0
	for c in trafico.coches:
		if c["dir"] != dir or c.get("suelto", false):
			continue
		var d: float = (c["s"] - s_coche) * dir
		if d > 0.0 and d < dmin:
			dmin = d
			mejor = c
	if mejor.is_empty() or float(mejor["v"]) > (Ajustes.velocidad - 5.0) / 3.6:
		return {}
	return mejor


func _grupo(l: Dictionary) -> Array:
	var g := [l]
	var ultimo := l
	for _i in 3:
		var sig := {}
		var dmin := ADEL_HUECO_GRUPO + trafico.largo
		for c in trafico.coches:
			if c["dir"] != dir or is_same(c, ultimo):
				continue
			var d: float = (c["s"] - ultimo["s"]) * dir
			if d > 0.0 and d < dmin:
				dmin = d
				sig = c
		if sig.is_empty():
			break
		g.append(sig)
		ultimo = sig
	return g


## "" si se puede adelantar ya; si no, el motivo
func _hueco_seguro() -> String:
	var grupo := _grupo(adel_lider)
	var ultimo: Dictionary = grupo[grupo.size() - 1]
	var v_l: float = adel_lider["v"]
	var ganar: float = (ultimo["s"] - s_coche) * dir + trafico.largo + ADEL_MARGEN
	var v := absf(coche.v)
	var v_obj := maxf(Ajustes.velocidad / 3.6, v_l + 25.0 / 3.6)
	var t := 0.0
	var recorrido := 0.0
	var rel := 0.0
	var fi := coche.ficha
	while rel < ganar and t < 40.0:
		var seno := ruta.valor(ruta.pendiente, s_coche + dir * recorrido) * dir / 100.0
		var a := (coche.fuerza_motor(v) - coche.fuerza_resistente(v) - fi.masa * Coche.G * seno) / fi.masa
		if v >= v_obj:
			a = minf(a, 0.0)
		v = maxf(v + a * 0.1, 0.0)
		recorrido += v * 0.1
		rel += (v - v_l) * 0.1
		t += 0.1
	if rel < ganar:
		return "el coche no da para pasar aquí"
	t += ADEL_T_CAMBIO
	recorrido += v * ADEL_T_CAMBIO
	var d := 0.0
	while d <= recorrido + 15.0:
		if absf(ruta.valor(ruta.curvatura, s_coche + dir * d)) > 1.0 / 350.0:
			return "curva / línea continua"
		d += 4.0
	var v_frente := maxf(ruta.valor(ruta.vmax, s_coche + dir * recorrido), 50.0) / 3.6
	var necesaria := recorrido + v_frente * t + 30.0
	var vis := _visibilidad(necesaria)
	if vis < necesaria:
		return "sin visibilidad (%d de %d m)" % [roundi(vis), roundi(necesaria)]
	for c in trafico.coches:
		if c["dir"] == dir:
			continue
		var dc: float = (c["s"] - s_coche) * dir
		if dc > -10.0 and dc < recorrido + absf(float(c["v"])) * t + 30.0:
			return "viene un coche de frente"
	adel_ultimo = ultimo
	return ""


## Hasta dónde se ve la carretera desde el asiento (m): la visual a 1,1 m no puede salirse de la calzada
## en las curvas ni pasar por debajo del asfalto en un cambio de rasante
func _visibilidad(hasta: float) -> float:
	var ojo := ruta.punto(s_coche) + Vector3.UP * 1.1
	var d := 20.0
	while d <= hasta + 19.0:
		var obj := ruta.punto(s_coche + dir * d) + Vector3.UP * 1.1
		var n := maxi(2, int(d / 10.0))
		for i in range(1, n):
			var u := float(i) / n
			var p := ojo.lerp(obj, u)
			var sm := s_coche + dir * d * u
			var c := ruta.punto(sm)
			if Vector2(p.x - c.x, p.z - c.z).length() > ruta.valor(ruta.ancho, sm) * 0.5 + 4.0 or p.y < c.y + 0.3:
				return d - 20.0
		d += 20.0
	return hasta


func _adelantamiento(dt: float) -> void:
	adel_msg_t = maxf(0.0, adel_msg_t - dt)
	var paso := dt / ADEL_T_CAMBIO
	match adel_estado:
		0:
			adel_carril = move_toward(adel_carril, 0.0, paso)
		1:
			if not piloto or not _existe(adel_lider) or (adel_lider["s"] - s_coche) * dir < 0.0 or (adel_lider["s"] - s_coche) * dir > 90.0:
				_cancelar_adelantamiento("Ya no hay coche lento delante")
				return
			adel_revisar -= dt
			if adel_revisar <= 0.0:
				adel_revisar = 0.25
				adel_motivo = _hueco_seguro()
				if adel_motivo == "":
					adel_estado = 2
					adel_abortado = false
		2:
			adel_carril = move_toward(adel_carril, 1.0, paso)
			if not _existe(adel_ultimo) or not _existe(adel_lider):
				adel_estado = 3
				return
			var d_ult: float = (adel_ultimo["s"] - s_coche) * dir
			var d_lid: float = (adel_lider["s"] - s_coche) * dir
			# ¿aparece alguien de frente demasiado cerca? se aborta y se vuelve detrás
			for c in trafico.coches:
				if c["dir"] == dir:
					continue
				var dc: float = (c["s"] - s_coche) * dir
				var cierre := absf(coche.v) + absf(float(c["v"]))
				# solo se aborta si aún no ha llegado a la altura del adelantado (puede volver detrás de él);
				# si ya está a su lado, lo más seguro es terminar a fondo
				if dc > -3.0 and dc < cierre * 2.5 + 15.0 and d_lid > trafico.largo + 1.0:
					adel_abortado = true
					adel_estado = 3
					_aviso_adel("Adelantamiento abortado: viene un coche")
					return
			if d_ult < -(trafico.largo + ADEL_MARGEN):
				adel_estado = 3
		3:
			adel_carril = move_toward(adel_carril, 0.0, paso)
			if adel_carril <= 0.0:
				adel_estado = 0
				if not adel_abortado:
					adelantamientos += 1
					_aviso_adel("Adelantamiento completado")


# ---------------- pruebas automáticas (verificación) ----------------
## --captura=choque_alcance | choque_frontal | adelantar  (ver README §10)
func _prueba(modo: String) -> void:
	var dt := 1.0 / 60.0
	Ajustes.trafico = float(Ajustes.args.get("trafico", "0")) / 100.0
	if modo.begins_with("choque"):
		piloto = false
		var frontal := modo == "choque_frontal"
		var v_j := float(Ajustes.args.get("v_jug", "30" if frontal else "90")) / 3.6
		var v_t := float(Ajustes.args.get("v_traf", "30" if frontal else "40")) / 3.6
		var s0 := s_coche
		var lado := dir * ruta.valor(ruta.ancho, s0) * 0.25 * (-1.0 if frontal else 1.0)
		coche.colocar(ruta.punto(s0) + ruta.derecha(s0) * lado, ruta.tangente(s0) * dir)
		coche.v = v_j
		var t := trafico.crear_prueba(s0 + dir * 30.0, -dir if frontal else dir, v_t, true)
		var maxt := 0.0
		var cruzado := false
		for i in 360:
			# el jugador mantiene la velocidad (acelerador justo) hasta el golpe
			if colisiones.registro.is_empty():
				coche.v = v_j
			_simular(dt)
			# ¿lo atraviesa? el centro del jugador no puede pasar al otro lado del coche golpeado
			var dl: float = (t["s"] - s_coche) * dir
			if dl < -1.0 and absf(lat_coche - (ruta.proyectar(t["nodo"].position, t["s"]).y)) < 1.0:
				cruzado = true
		var r: Dictionary = colisiones.registro[0] if not colisiones.registro.is_empty() else {}
		if r.is_empty():
			print("PRUEBA %s: SIN CHOQUE" % modo)
			get_tree().quit()
			return
		var p0: Vector2 = r["va0"] * r["ma"] + r["vb0"] * r["mb"]
		var p1: Vector2 = r["va1"] * r["ma"] + r["vb1"] * r["mb"]
		var fw := Vector2(coche.adelante().x, coche.adelante().z)
		print("PRUEBA %s: masas %.0f / %.0f kg · antes: jugador %.1f km/h, otro %.1f km/h · justo después: jugador %.1f km/h, otro %.1f km/h · giro otro %.2f rad/s" % [
			modo, r["ma"], r["mb"], r["va0"].length() * 3.6, r["vb0"].length() * 3.6, r["va1"].length() * 3.6, r["vb1"].length() * 3.6, r["wb1"]])
		print("PRUEBA %s: momento antes (%.0f, %.0f) kg·m/s · después (%.0f, %.0f) · error %.4f %% · restitución medida %.3f · atraviesa: %s · choques contados %d · al final: jugador %.1f km/h, otro %.1f km/h, distancia entre centros %.2f m" % [
			modo, p0.x, p0.y, p1.x, p1.y, (p1 - p0).length() / maxf(p0.length(), 1.0) * 100.0,
			-((r["va1"] - r["vb1"]).dot((r["va0"] - r["vb0"]).normalized())) / maxf((r["va0"] - r["vb0"]).length(), 0.01),
			"SÍ" if cruzado else "no", colisiones.golpes, absf(coche.v) * 3.6, (t["v2"] as Vector2).length() * 3.6 if t.get("suelto", false) else float(t["v"]) * 3.6,
			Vector2(coche.position.x - t["nodo"].position.x, coche.position.z - t["nodo"].position.z).length()])
		get_tree().quit()
		return
	if modo == "adelantar":
		piloto = true
		Ajustes.velocidad = float(Ajustes.args.get("vel", "90"))
		var lento := trafico.crear_prueba(s_coche + dir * 45.0, dir, float(Ajustes.args.get("v_lento", "45")) / 3.6, false)
		lento["v0"] = float(Ajustes.args.get("v_lento", "45")) / 3.6
		coche.v = lento["v"]
		var pulsar := float(Ajustes.args.get("pulsar", "4"))
		var t := 0.0
		var espera := 0.0
		var max_carril := 0.0
		var motivos := {}
		var inicio := -1.0
		var fin := -1.0
		var s_pulsado := 0.0
		while t < float(Ajustes.args.get("duracion", "70")):
			if absf(t - pulsar) < dt * 0.5:
				_pedir_adelantamiento()
				s_pulsado = s_coche
			_simular(dt)
			t += dt
			if adel_estado == 1:
				espera += dt
				motivos[adel_motivo] = motivos.get(adel_motivo, 0) + 1
			if adel_estado == 2 and inicio < 0.0:
				inicio = t
				print("  sale a adelantar en t=%.1f s, PK %.3f km, radio de curva aquí %.0f m" % [t, s_coche / 1000.0, 1.0 / maxf(absf(ruta.valor(ruta.curvatura, s_coche)), 1e-5)])
			max_carril = maxf(max_carril, adel_carril)
			if Ajustes.args.has("traza") and int(t * 60.0) % 15 == 0 and t > pulsar:
				var dmin := 1e9
				for oc in trafico.coches:
					if oc["dir"] != dir:
						var dd: float = (oc["s"] - s_coche) * dir
						if dd > -5.0: dmin = minf(dmin, dd)
				print("  t=%.2f est=%d carril=%.2f lat=%.2f v=%.0f d_lento=%.1f frente=%.0f golpes=%d aborta=%s" % [t, adel_estado, adel_carril, lat_coche, coche.v * 3.6, (lento["s"] - s_coche) * dir, dmin, colisiones.golpes, adel_abortado])
			if inicio > 0.0 and adel_estado == 0 and fin < 0.0:
				fin = t
			if fin > 0.0 and t > fin + 3.0:
				break
		print("PRUEBA adelantar: pulsado en PK %.3f km · completados %d · esperó %.1f s · motivos de espera %s · salió %s · terminó %s · choques %d · coches de tráfico %d · velocidad final %.0f km/h · lento delante a %.0f m (detrás = negativo)" % [
			s_pulsado / 1000.0, adelantamientos, espera, str(motivos), "t=%.1f s" % inicio if inicio > 0 else "no", "t=%.1f s" % fin if fin > 0 else "no",
			colisiones.golpes, trafico.coches.size(), absf(coche.v) * 3.6, (lento["s"] - s_coche) * dir if _existe(lento) else 0.0])
		get_tree().quit()


## --captura=giro: a 80 km/h, mantener A (o D con --lado=1) 5 s con el acelerador fijo que mantiene 80 km/h en recta
func _prueba_giro() -> void:
	var dt := 1.0 / 60.0
	piloto = false
	coche.v = float(Ajustes.args.get("v0", "80")) / 3.6
	var v0 := coche.v
	var acel_fija := clampf(coche.fuerza_resistente(v0) / coche.fuerza_motor(v0), 0.0, 1.0)
	var lado := float(Ajustes.args.get("lado", "-1"))
	var t := 0.0
	var a_lat_max := 0.0
	while t < 5.0:
		coche.giro_directo = false
		coche.volante = lado
		coche.acelerador = acel_fija
		coche.freno = 0.0
		coche.marcha_atras = false
		coche.paso_fisica(dt)
		a_lat_max = maxf(a_lat_max, absf(coche.a_lat_actual))
		t += dt
	print("PRUEBA giro: tecla %s 5 s con acelerador fijo %.2f · velocidad %.1f → %.1f km/h (pierde %.1f km/h) · giro de ruedas final %.3f rad · a_lat máx %.1f m/s² · derrapando=%s" % [
		"D" if lado > 0 else "A", acel_fija, v0 * 3.6, coche.v * 3.6, (v0 - coche.v) * 3.6, coche.giro, a_lat_max, coche.derrapando])
	get_tree().quit()


## Pulsar el perfil de altitud del HUD: el coche aparece en ese km de la ruta (carril correcto, parado)
func _saltar_a(s: float) -> void:
	s = clampf(s, 1.0, ruta.longitud() - 1.0)
	_cancelar_adelantamiento("")
	adel_estado = 0
	adel_carril = 0.0
	var lado := dir * ruta.valor(ruta.ancho, s) * 0.25
	coche.colocar(ruta.punto(s) + ruta.derecha(s) * lado, ruta.tangente(s) * dir)
	coche.v = 0.0
	s_coche = s
	# fuera los coches que haya justo donde cae
	for i in range(trafico.coches.size() - 1, -1, -1):
		var c: Dictionary = trafico.coches[i]
		if absf(float(c["s"]) - s) < 50.0 or (c["nodo"] as Node3D).position.distance_to(coche.position) < 50.0:
			(c["nodo"] as Node3D).queue_free()
			trafico.coches.remove_at(i)
	mundo.cargar_ventana(coche.position, ruta.tangente(s) * dir)
	reiniciar_camara()
	if terminado and (s_fin - s) * dir > 0.0:
		terminado = false
		panel_fin.visible = false


## --captura=perfil: pulsa el perfil al 25 %, 50 % y 90 % y comprueba dónde aparece el coche
func _prueba_perfil() -> void:
	var area_x0 := 6.0
	var ancho := mini_perfil.size.x - 12.0
	for f in [0.25, 0.5, 0.9]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		ev.position = Vector2(area_x0 + f * ancho, mini_perfil.size.y * 0.5)
		var s_pedido := mini_perfil.s_en_x(ev.position.x)
		mini_perfil._gui_input(ev)
		for i in 30:
			_simular(1.0 / 60.0)
		print("PRUEBA perfil: pulsado al %d %% → km pedido %.2f · coche en km %.2f · lateral %.2f m · altitud %.0f m · coches a <50 m: %d" % [
			roundi(f * 100.0), s_pedido / 1000.0, s_coche / 1000.0, lat_coche, coche.position.y, trafico.cerca_de(coche.position, 50.0).size()])
	# mapa: pulsar el punto del trazado que corresponde al km 12
	var ev2 := InputEventMouseButton.new()
	ev2.button_index = MOUSE_BUTTON_LEFT
	ev2.pressed = true
	ev2.position = mini_mapa._pto(12000.0)
	var s_m := mini_mapa.s_en(ev2.position)
	mini_mapa._gui_input(ev2)
	for i in 30:
		_simular(1.0 / 60.0)
	print("PRUEBA mapa: pulsado el punto del km 12,0 → km pedido %.2f · coche en km %.2f · lateral %.2f m" % [s_m / 1000.0, s_coche / 1000.0, lat_coche])
	var mv := InputEventMouseMotion.new()
	mv.position = Vector2(area_x0 + 0.62 * ancho, mini_perfil.size.y * 0.5)
	mini_perfil._gui_input(mv)
	var mv2 := InputEventMouseMotion.new()
	mv2.position = mini_mapa._pto(18000.0)
	mini_mapa._gui_input(mv2)
	if Ajustes.args.has("salida"):
		for i in 20:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(Ajustes.args["salida"])
	get_tree().quit()
