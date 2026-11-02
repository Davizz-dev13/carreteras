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
var toques_bionda := 0           # pasos de física con el coche tocando una bionda (pruebas)
var biondas: Biondas             # choque contra los quitamiedos reales de la zona (quitamiedos.gd + biondas.gd)
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
var hud_motor := HudMotor.new()   # v4: marcha, rpm y consumo junto al velocímetro
var panel_pausa := PanelContainer.new()
var panel_fin := PanelContainer.new()
var l_fin := Label.new()
var sl_traf := HSlider.new()
var sl_vel := HSlider.new()
var l_traf_p := Label.new()
var l_vel_p := Label.new()
var b_continuar := Button.new()
var b_repetir := Button.new()
var ck_curvas := CheckButton.new()
var sl_vol := HSlider.new()
var l_vol_p := Label.new()
var ck_limite := CheckButton.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_leer_args()
	Ajustes.cargar()
	_ajustes_adelantamiento()
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
	biondas = Quitamiedos.choque(Ajustes.dir_datos(), Ajustes.rutas)
	ruta = Ajustes.ruta()
	s_ini = clampf(Ajustes.km_ini * 1000.0, 0.0, ruta.longitud())
	s_fin = clampf(Ajustes.km_fin * 1000.0, 0.0, ruta.longitud())
	if is_equal_approx(s_ini, s_fin):
		s_fin = ruta.longitud()
	dir = 1 if s_fin > s_ini else -1
	piloto = Ajustes.piloto
	add_child(coche)
	sonido.coche = coche
	coche.add_child(sonido)               # motor con las rpm reales de la caja (sonido_motor.gd)
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
	_mando_iniciar()
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
	coche.colocar(ruta.punto_carril(s, dir), ruta.marcha_carril(s, dir))
	s_coche = s
	reiniciar_camara()
	if en_inicio:
		tiempo = 0.0
		coche.odometro = 0.0
		coche.consumo.reiniciar()
		v_max = 0.0
		choques = 0
		derrapes = 0
		terminado = false
		panel_fin.visible = false
		get_viewport().gui_release_focus()
		coche.v = minf(Ajustes.velocidad, 40.0) / 3.6 if piloto else 0.0


func _physics_process(dt: float) -> void:
	if not cargado or pausado:
		return
	_simular(dt)


## Posición del jugador sobre la ruta (s_coche, lat_coche). En sentido contrario, en una glorieta se va por el resto
## del anillo (desvío, ruta.gd), lejos del arco que recorre la ruta: ahí s_coche sale de la distancia recorrida por
## el desvío y lat_coche es la de su carril.
var des_k := -1
var des_u := 0.0
func _proyectar_jugador() -> void:
	var kd := ruta.desvio_en(s_coche, dir)
	if kd >= 0:
		if kd != des_k:
			des_k = kd
			des_u = ruta.u_desvio(kd, s_coche)
		var u := ruta.proyectar_desvio(kd, coche.position, des_u)
		var q := ruta.punto_desvio(kd, u)
		if Vector2(q.x - coche.position.x, q.z - coche.position.z).length() < 12.0:
			des_u = u
			s_coche = ruta.s_desvio(kd, u)
			lat_coche = ruta.lateral_carril(s_coche, dir)
			return
	des_k = -1
	var p := ruta.proyectar(coche.position, s_coche)
	s_coche = p.x
	lat_coche = p.y


func _simular(dt: float) -> void:
	_proyectar_jugador()
	_mandos(dt)
	var fw0 := coche.adelante()
	var prev_jug := {"p": Vector2(coche.position.x, coche.position.z), "f": Vector2(fw0.x, fw0.z)}
	coche.paso_fisica(dt)
	var lado_jug := 1 if lat_coche > ruta.lateral_eje(s_coche) else -1
	var en_ruta := absf(lat_coche) < ruta.valor(ruta.ancho, s_coche) * 0.5 + 1.5
	trafico.factor = Ajustes.trafico
	trafico.pos_jug = coche.position      # el tráfico también le cede el paso en las glorietas
	trafico.actualizar(dt, s_coche, lat_coche, coche.v * dir, lado_jug if en_ruta else 0)
	colisiones.mover_sueltos(dt)
	colisiones.resolver(dt, prev_jug)
	if biondas != null and not biondas.vacia() and Biondas.resolver(coche, [biondas]) > 0.0:
		toques_bionda += 1
	choques = colisiones.golpes
	_adelantamiento(dt)
	_adelantar_auto(dt)
	if not terminado:
		tiempo += dt
		v_max = maxf(v_max, absf(coche.v))
		if coche.derrapando and not derrapando_antes:
			derrapes += 1
		if (s_coche - s_fin) * dir >= 0.0 and absf(lat_coche) < 25.0:
			_fin()
	derrapando_antes = coche.derrapando


## Teclado, mando o piloto automático
func _mandos(_dt: float) -> void:
	# teclado (igual que siempre; las flechas se leen como teclas para que el joystick no las active a saltos)
	var acel := 1.0 if (Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)) else 0.0
	var fren := 1.0 if (Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN)) else 0.0
	var vol := 0.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): vol -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): vol += 1.0
	var mano := Input.is_physical_key_pressed(KEY_SPACE)
	var tocado := acel > 0.0 or fren > 0.0 or vol != 0.0 or mano
	# mando: gatillos analógicos y joystick; se suma al teclado (gana el que pida más; el volante del teclado manda)
	if _leer_mando():
		acel = maxf(acel, pad_gas)
		fren = maxf(fren, pad_freno)
		if vol == 0.0: vol = pad_volante
		mano = mano or pad_mano
		# para desconectar el piloto hace falta pisar un gatillo o mover el joystick de verdad (no la deriva del stick)
		tocado = tocado or pad_gas > 0.05 or pad_freno > 0.05 or absf(pad_x) > 0.3 or pad_mano
	if mano: fren = 1.0
	if terminado:
		coche.acelerador = 0.0
		coche.freno = 0.6
		coche.giro_directo = piloto
		if piloto: coche.volante = _volante_piloto()
		else: coche.volante = vol
		return
	if piloto and tocado:
		piloto = false            # tocar los mandos desconecta el piloto (como en un coche real)
		_cancelar_adelantamiento("")
	if piloto:
		if coche.caja.manual: coche.caja.automatico()   # el piloto conduce siempre en automático
		coche.giro_directo = true
		coche.volante = _volante_piloto()
		_control_velocidad(_tope_limite(_velocidad_objetivo()))
		return
	coche.giro_directo = false
	coche.volante = vol
	if fren > 0.0 and coche.v < 0.3 and not mano:
		coche.marcha_atras = true
		coche.acelerador = fren
		coche.freno = 0.0
		return
	if acel > 0.0:
		coche.marcha_atras = false
	coche.acelerador = acel if not coche.marcha_atras else 0.0
	coche.freno = fren if not coche.marcha_atras else acel
	if coche.marcha_atras and acel == 0.0 and fren == 0.0:
		coche.freno = 0.3


## Persecución pura ("pure pursuit") de un punto del carril derecho por delante
func _volante_piloto() -> float:
	var mira := clampf(absf(coche.v) * 0.75, 7.0, 26.0)
	var s := s_coche + dir * mira * ruta.escala_carril(s_coche, dir)
	var obj := ruta.punto_carril(s, dir, adel_carril)    # en una glorieta, en sentido contrario: por el resto del anillo
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
	if adel_estado == 3 and adel_abortado and adel_abort_detras and not adel_lider.is_empty():
		v0 = minf(v0, float(adel_lider["v"]) - 15.0 / 3.6)
	elif adel_estado == 2 and not adel_lider.is_empty():
		# para pasar hace falta ir claramente más rápido que el adelantado (+ADEL_DELTA km/h como mínimo)
		v0 = maxf(v0, float(adel_lider["v"]) + ADEL_DELTA / 3.6)
		if adel_parcial:
			v0 = minf(v0, adel_v_parcial)
			if _existe(adel_ultimo) and (adel_ultimo["s"] - s_coche) * dir < -(trafico.largo + ADEL_MARGEN):
				v0 = minf(v0, float(adel_ultimo["v"]))   # ya pasados: iguala la velocidad de la cola para meterse
		if Ajustes.limite_adelantar:
			var lim := _limite(s_coche, dir)
			if lim > 0: v0 = minf(v0, lim / 3.6)
	if Ajustes.adaptar_curvas:
		v0 = minf(v0, trafico.vel_curva(s_coche, dir, 4.0, 220.0))
	return v0


func _control_velocidad(v0: float) -> void:
	var hueco := 1e4
	var v_lider := v0
	for c in trafico.coches:
		if c["dir"] != dir: continue
		if adel_carril > 0.45 and (adel_estado == 2 or not ADEL_HUECO_VUELTA): continue     # adelantando por el carril contrario: los de nuestro sentido van al lado
		var d: float = (c["s"] - s_coche) * dir
		if d > 0.0 and d - trafico.largo < hueco:
			hueco = d - trafico.largo
			v_lider = c["v"]
	# obstáculos físicos delante (cualquier sentido): coches sueltos tras un golpe y, dentro del desvío de una
	# glorieta (donde la ruta no sirve para medir huecos), los que se cruzan en la trayectoria
	var en_desvio := ruta.desvio_en(s_coche, dir) >= 0
	var fw2 := Vector2(coche.adelante().x, coche.adelante().z).normalized()
	for c in trafico.coches:
		if not (c.get("suelto", false) or (en_desvio and c["dir"] != dir and not c.get("cede_jug", false))):
			continue
		var pq: Vector3 = (c["nodo"] as Node3D).position
		var rel := Vector2(pq.x - coche.position.x, pq.z - coche.position.z)
		var delante := rel.dot(fw2)
		if delante <= 0.0 or delante > 12.0:
			continue
		if absf(rel.cross(fw2)) > 1.7:
			continue
		var g_fis: float = delante - trafico.largo
		if g_fis < hueco:
			hueco = g_fis
			v_lider = 0.0
	# glorieta: el piloto cede el paso a quien ya va por el anillo antes de entrar
	var ceda := trafico.ceda_paso(s_coche, dir)
	if ceda < hueco:
		hueco = ceda
		v_lider = 0.0
	var v := absf(coche.v)
	var a := clampf(trafico.idm(v, v0, hueco, v - v_lider) * 1.6, -8.0, 3.0)
	# fuerza necesaria = inercia + aerodinámica + rodadura + gravedad de la pendiente real
	var fw := coche.adelante()
	var lb := coche.ficha.batalla * 0.5
	var seno := clampf((coche._altura(coche.position + fw * lb) - coche._altura(coche.position - fw * lb)) / (2.0 * lb), -0.5, 0.5)
	var fi := coche.ficha
	var retencion := coche.caja.f_retencion(v, coche.caja.marcha)
	if Ajustes.args.get("eco", "1") != "0":
		a = _acercamiento(a, v, v0, hueco, v_lider)
	var f := fi.masa * a + coche.fuerza_resistente(v) + fi.masa * Coche.G * seno
	coche.marcha_atras = false
	if adel_estado == 2 and adel_parcial and a < -2.5:
		a = -2.5                       # igualando la velocidad de la cola para meterse en el hueco: sin frenazo
		f = fi.masa * a + coche.fuerza_resistente(v) + fi.masa * Coche.G * seno
	if adel_estado == 2 and v < v0:
		f = coche.fuerza_motor(v)      # adelantando: a fondo (como en la comprobación de seguridad)
	if f < 0.0 and -f <= retencion and Ajustes.args.get("eco", "1") != "0":
		# basta con soltar el gas: retiene el motor (corte de inyección), sin tocar el freno
		coche.acelerador = 0.0
		coche.freno = 0.0
	elif f >= 0.0:
		coche.acelerador = clampf(f / coche.fuerza_motor(v), 0.0, 1.0)
		coche.freno = 0.0
	else:
		coche.acelerador = 0.0
		coche.freno = clampf(-f / fi.f_freno_max, 0.0, 1.0)


## v5: acercamiento a un coche más lento sin frenazos: el IDM de siempre anticipa desde lejos (suelta gas poco a
## poco), pero nunca frena más de lo que hace falta para quedarse a su velocidad a la distancia de seguimiento (con un
## 30 % de margen); y si basta con soltar el gas, rueda con el freno motor (corte de inyección) en vez de frenar.
## Si se ha echado encima (hace falta más de 3 m/s²) o el de delante frena fuerte, manda el IDM como siempre.
## Volviendo a la cola tras adelantar a los primeros, la distancia de referencia es la de meterse (S0 + 2 m).
func _acercamiento(a_idm: float, v: float, v0: float, hueco: float, v_lider: float) -> float:
	if a_idm >= 0.0 or hueco >= 5000.0:
		return a_idm
	var dv := maxf(v - v_lider, 0.0)
	# en un carril adicional real (2+1) el piloto lo adelantará: no frena antes de tiempo
	if hueco > _dist_lider() and adel_auto_espera <= 0.0 and Ajustes.args.get("auto_adel", "1") != "0" \
			and ruta.carril_extra_tramo(s_coche, s_coche + dir * (hueco + 30.0), dir):
		return minf(_a_libre(v, v0), 0.0)
	var s_des := Trafico.S0 + 2.0
	if not (adel_estado == 3 and adel_parcial):
		s_des += v_lider * Trafico.T_SEG
	var libre := hueco - s_des
	var b_req := 0.0
	var minimo := 0.3
	if libre > 3.0:
		b_req = dv * dv / (2.0 * libre)       # deceleración constante que lo deja a su velocidad a la distancia justa
	else:
		# más cerca de lo cómodo (p. ej. justo al meterse tras adelantar): abre el hueco poco a poco, sin frenazo
		var corto := hueco - Trafico.S0 - 1.0
		if corto <= 0.5:
			return a_idm
		b_req = dv * dv / (2.0 * corto)
		minimo = 1.0
	if b_req > 3.0 and libre > 3.0:
		# no le da para quedarse a la distancia de seguimiento sin frenar fuerte (p. ej. al volver de adelantar):
		# frena lo que haga falta para no acercarse a menos de S0 + 1 m (con margen) y luego abre el hueco poco a poco
		var corto2 := hueco - Trafico.S0 - 1.0
		b_req = dv * dv / (2.0 * corto2)
		if b_req <= 3.0:
			return minf(_a_libre(v, v0), maxf(a_idm, -maxf(b_req * 1.5, 1.0)))
	if b_req > 3.0:
		return a_idm                           # se ha echado encima o el de delante frena fuerte: como siempre
	return minf(_a_libre(v, v0), maxf(a_idm, -maxf(b_req * 1.3, minimo)))


## Término de carretera libre del IDM (lo que pide ir a v0 sin nadie delante), con el mismo factor que el piloto
func _a_libre(v: float, v0: float) -> float:
	return clampf(Trafico.A_MAX * 1.6 * (1.0 - pow(v / maxf(v0, 0.1), 4.0)), -8.0, 3.0)


## v4: el piloto no pasa del límite de la señal (y frena suave antes de una señal más baja), salvo adelantando
func _tope_limite(v0: float) -> float:
	if adel_estado >= 2 or not Ajustes.piloto_limites:
		return v0
	return minf(v0, senal.tope_piloto(s_coche, dir))


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
	if pad_id >= 0: b_repetir.grab_focus.call_deferred()      # con el mando: ✕ repite el tramo


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventJoypadButton and ev.pressed and cargado:
		_boton_mando(ev.button_index)
		return
	if not (ev is InputEventKey and ev.pressed and not ev.echo) or not cargado:
		return
	var leva := Mando.tecla_cambio(ev)          # G baja · T sube (T mantenida: automático)
	if leva != 0:
		if not pausado and not terminado: _leva(leva)
		return
	match ev.physical_keycode:
		KEY_ESCAPE:
			_pausa(not pausado)
		KEY_V:
			Ajustes.camara = 1 - Ajustes.camara
		KEY_P:
			piloto = not piloto
			if not piloto: _cancelar_adelantamiento("")
			else: coche.caja.automatico()
		KEY_O:
			_pedir_adelantamiento()
		KEY_R:
			_reiniciar(false)
		KEY_H:
			l_ayuda.visible = not l_ayuda.visible
		KEY_N:
			Ajustes.silencio = not Ajustes.silencio
		KEY_K:
			Ajustes.adaptar_curvas = not Ajustes.adaptar_curvas
		KEY_L:
			Ajustes.limite_adelantar = not Ajustes.limite_adelantar
		KEY_EQUAL, KEY_KP_ADD, KEY_PLUS:
			Ajustes.velocidad = minf(Ajustes.velocidad + 5.0, 200.0)
		KEY_MINUS, KEY_KP_SUBTRACT:
			Ajustes.velocidad = maxf(Ajustes.velocidad - 5.0, 10.0)
		KEY_0:
			Ajustes.trafico = minf(Ajustes.trafico + 0.1, 1.0)
		KEY_9:
			Ajustes.trafico = maxf(Ajustes.trafico - 0.1, 0.0)


# ---------------- mando (PS4 / DualShock 4 o cualquier mando "estándar" del navegador) ----------------
# En la web, Chrome/Edge/Firefox dan el DualShock 4 con el mapeo "standard" del Gamepad API y Godot convierte
# R2/L2 (botones analógicos 7/6 del navegador) en los ejes JOY_AXIS_TRIGGER_RIGHT/LEFT (0..1).
const AYUDA_TECLADO := ("W/↑ acelerar · S/↓ frenar (parado: marcha atrás) · G/T bajar/subir marcha (T mantenida: automático)\n" +
	"P piloto · O adelantar (L: límite) · +/− velocidad · K curvas · 9/0 tráfico\n" +
	"V cámara · R volver a la carretera · N silenciar motor · Esc pausa · H ocultar ayuda")
const AYUDA_MANDO := ("Mando: R2 acelerar · L2 frenar (parado: marcha atrás) · joystick izq. girar · joystick der. mirar\n" +
	"L1/R1 bajar/subir marcha (R1 mantenido: automático) · △ piloto · □ adelantar · ↑↓ velocidad · ←→ tráfico\n" +
	"✕ freno de mano · ○ cámara · L3 a la carretera · OPTIONS pausa (curvas y límite) · SHARE ayuda")
const PAD_ZONA_MUERTA := 0.08     # joystick: por debajo no gira (deriva del stick)
const PAD_ZONA_GATILLO := 0.03    # gatillos: holgura en reposo
var pad_id := -1                  # mando que se lee (-1 = ninguno)
var pad_nombre := ""
var pad_x := 0.0                  # joystick izquierdo X en bruto
var pad_volante := 0.0            # -1..1 tras zona muerta y curva
var pad_gas := 0.0                # 0..1 (R2)
var pad_freno := 0.0              # 0..1 (L2)
var pad_mano := false             # ✕ freno de mano
var pad_gatillo_neg := {}         # (mando, eje) -> true si ese gatillo da −1 en reposo (algunos mandos no estándar)
var pad_aviso_t := 0.0
var l_mando := Label.new()


func _mando_iniciar() -> void:
	Input.joy_connection_changed.connect(_al_cambiar_mando)
	var pad := Mando.pad_actual()          # el último que se tocó (p. ej. en otra zona); si no, el primero conectado
	if pad >= 0:
		_al_cambiar_mando(pad, true)


## Cada evento pasa por Mando.registrar: el mando que da una pulsación o un movimiento de verdad pasa a ser el que se
## lee (en Windows el nº 0 a menudo es un mando virtual de DS4Windows/Steam u otro aparato, no el del jugador).
func _input(ev: InputEvent) -> void:
	var d := Mando.registrar(ev)
	if d >= 0 and d != pad_id:
		_usar_mando(d)


func _usar_mando(d: int) -> void:
	pad_id = d
	pad_nombre = Mando.nombre(d)
	l_mando.text = "Mando conectado (%s)" % pad_nombre
	l_ayuda.text = AYUDA_MANDO
	l_mando.visible = true
	pad_aviso_t = 5.0
	print("Mando en uso: %d %s" % [d, pad_nombre])


func _al_cambiar_mando(id: int, conectado: bool) -> void:
	if conectado:
		if pad_id < 0 or not Input.get_connected_joypads().has(pad_id):
			pad_id = id
		pad_nombre = Mando.nombre(pad_id)
		l_mando.text = "Mando conectado (%s)" % pad_nombre
	elif id == pad_id or id == Mando.activo:
		Mando.olvidar(id)
		pad_id = Mando.pad_actual()
		pad_nombre = Mando.nombre(pad_id)
		l_mando.text = "Mando desconectado" if pad_id < 0 else "Mando conectado (%s)" % pad_nombre
		pad_gas = 0.0
		pad_freno = 0.0
		pad_volante = 0.0
		pad_mano = false
	else:
		Mando.olvidar(id)              # se desconecta otro (no el que se lee)
		return
	l_ayuda.text = AYUDA_MANDO if pad_id >= 0 else AYUDA_TECLADO
	l_mando.visible = true
	pad_aviso_t = 5.0


func _aviso_mando(dt: float) -> void:
	if pad_aviso_t <= 0.0:
		return
	pad_aviso_t -= dt
	l_mando.modulate.a = clampf(pad_aviso_t, 0.0, 1.0)
	if pad_aviso_t <= 0.0:
		l_mando.visible = false


## Lee el mando; devuelve false si no hay ninguno
func _leer_mando() -> bool:
	if pad_id < 0:
		return false
	pad_x = Mando.eje(pad_id, JOY_AXIS_LEFT_X)
	pad_volante = curva_joystick(pad_x)
	pad_gas = _gatillo(JOY_AXIS_TRIGGER_RIGHT)
	pad_freno = _gatillo(JOY_AXIS_TRIGGER_LEFT)
	pad_mano = Input.is_joy_button_pressed(pad_id, JOY_BUTTON_A)
	return true


## Joystick → volante: zona muerta y curva suave (en el centro, poco ángulo para corregir fino; al fondo, todo)
static func curva_joystick(x: float) -> float:
	var m := absf(x)
	if m <= PAD_ZONA_MUERTA:
		return 0.0
	var u := clampf((m - PAD_ZONA_MUERTA) / (1.0 - PAD_ZONA_MUERTA), 0.0, 1.0)
	return signf(x) * (0.45 * u + 0.55 * u * u * u)


func _gatillo(eje: JoyAxis) -> float:
	var g := Mando.eje(pad_id, eje)
	var clave := Vector2i(pad_id, eje)
	if g < -0.2:
		pad_gatillo_neg[clave] = true    # este mando da el gatillo de −1 (suelto) a +1 (a fondo)
	if pad_gatillo_neg.get(clave, false):
		g = (g + 1.0) * 0.5
	g = clampf(g, 0.0, 1.0)
	if g <= PAD_ZONA_GATILLO:
		return 0.0
	return (g - PAD_ZONA_GATILLO) / (1.0 - PAD_ZONA_GATILLO)


## Botones del mando → las mismas acciones que las teclas
var mando := Mando.new()          # joystick derecho (mirar) y levas L1/R1 (mando.gd)
var sonido := SonidoMotor.new()   # sonido del motor (sonido_motor.gd)


## Leva o tecla de cambio: pasa el DSG a manual con la marcha pedida. Cambiar de marcha es conducir: desconecta el
## piloto (como pisar un pedal).
func _leva(d: int) -> void:
	if piloto:
		piloto = false
		_cancelar_adelantamiento("")
	Mando.leva(coche.caja, d)


func _boton_mando(b: int) -> void:
	if pad_id < 0:
		var pads := Input.get_connected_joypads()
		_al_cambiar_mando(pads[0] if not pads.is_empty() else 0, true)
	if b == JOY_BUTTON_START:                 # OPTIONS: pausa (Esc)
		_pausa(not pausado)
		return
	if pausado or terminado:
		return          # en los menús la cruceta y ✕ mueven el foco y pulsan los botones (Godot ui_*)
	match b:
		JOY_BUTTON_Y:                         # △ piloto automático (P)
			piloto = not piloto
			if not piloto: _cancelar_adelantamiento("")
			else: coche.caja.automatico()
		JOY_BUTTON_X:                         # □ adelantar (O)
			_pedir_adelantamiento()
		JOY_BUTTON_B:                         # ○ cámara (V)
			Ajustes.camara = 1 - Ajustes.camara
		JOY_BUTTON_LEFT_STICK, JOY_BUTTON_RIGHT_STICK:   # L3/R3 volver a la carretera (R)
			_reiniciar(false)
		JOY_BUTTON_BACK:                      # SHARE ocultar/mostrar ayuda (H)
			l_ayuda.visible = not l_ayuda.visible
		JOY_BUTTON_LEFT_SHOULDER:             # L1 baja marcha (G) — "curvas" y "límite" pasan al menú de pausa
			_leva(-1)
		JOY_BUTTON_RIGHT_SHOULDER:            # R1 sube marcha (T); mantenido 0,8 s vuelve al automático
			_leva(1)
		JOY_BUTTON_DPAD_UP:                   # cruceta ↑↓ velocidad elegida (+/−)
			Ajustes.velocidad = minf(Ajustes.velocidad + 5.0, 200.0)
		JOY_BUTTON_DPAD_DOWN:
			Ajustes.velocidad = maxf(Ajustes.velocidad - 5.0, 10.0)
		JOY_BUTTON_DPAD_RIGHT:                # cruceta ←→ tráfico (9/0)
			Ajustes.trafico = minf(Ajustes.trafico + 0.1, 1.0)
		JOY_BUTTON_DPAD_LEFT:
			Ajustes.trafico = maxf(Ajustes.trafico - 0.1, 0.0)


func _process(dt: float) -> void:
	if not cargado:
		return
	mundo.actualizar_streaming(coche.position, coche.adelante())
	if not pausado:
		mando.actualizar_mira(pad_id, dt, Ajustes.camara == 1)
		mando.vigilar_vuelta_auto(coche.caja, pad_id, dt)
	sonido.cabina = Ajustes.camara == 1
	sonido.volumen = Ajustes.volumen_motor
	sonido.silencio = Ajustes.silencio or pausado
	_camara(dt)
	_hud()
	_aviso_mando(dt)
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
var cam_base := Vector3.ZERO     # posición de persecución con su muelle (antes de la órbita del joystick derecho)


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
		mando.girar_cabeza(cam)                 # joystick derecho: mirar alrededor
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
	if not cam_iniciada or cam_base.distance_to(objetivo) > 60.0:
		cam_base = objetivo
		mira = punto_mira
		cam_vel = Vector3.ZERO
		mira_vel = Vector3.ZERO
		cam_iniciada = true
	else:
		var r := amortiguar(cam_base, objetivo, cam_vel, 0.28, dt)
		cam_base = r[0]
		cam_vel = r[1]
		var r2 := amortiguar(mira, punto_mira, mira_vel, 0.12, dt)
		mira = r2[0]
		mira_vel = r2[1]
	# joystick derecho: órbita alrededor del coche (vuelve sola al soltarlo); sin mirar = la cámara de siempre
	var pivote := pos + Vector3.UP * 1.2
	mando.orbitar(cam, cam_base, mira, pivote)


func _ojos() -> Vector3:
	var o: Array = Catalogo.modelo_de(coche.ficha).get("ojos", [-0.37, 1.24, 0.25])
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


## nombre corto para el panel de la derecha: "Arteon 2.0 TDI 150 CV DSG" -> "Arteon TDI"
func _nombre_corto(n: String) -> String:
	var re := RegEx.new()
	re.compile("\\s*\\(.*?\\)|\\s+\\d+[.,]\\d+(?=\\s)|\\s+\\d+\\s*CV|\\s+DSG")
	return re.sub(n, "", true).strip_edges()


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
	abajo.add_child(hud_motor)
	abajo.add_child(l_alt)
	abajo.add_child(l_pend)
	var caja_v := _caja(Vector2(16, 0), abajo)
	caja_v.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	caja_v.position = Vector2(16, get_viewport().get_visible_rect().size.y - 308)
	l_modo.add_theme_font_size_override("font_size", 17)
	l_modo.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l_modo.autowrap_mode = TextServer.AUTOWRAP_OFF
	var caja_m := _caja(Vector2.ZERO, l_modo)
	# anclado arriba a la derecha (16 px del borde): si el texto crece, el panel crece hacia la izquierda
	caja_m.anchor_left = 1.0
	caja_m.anchor_right = 1.0
	caja_m.anchor_top = 0.0
	caja_m.anchor_bottom = 0.0
	caja_m.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	caja_m.offset_right = -16.0
	caja_m.offset_left = -16.0 - 250.0
	caja_m.offset_top = 14.0
	caja_m.offset_bottom = 14.0
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
	senal.position = Vector2(278, vs.y - 214)
	senal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	senal.cargar(Ajustes.ruta_idx, ruta.nombre)
	senal.visible = false
	hud.add_child(senal)
	l_ayuda.text = AYUDA_TECLADO
	l_ayuda.add_theme_font_size_override("font_size", 13)
	var caja_a := _caja(Vector2(vs.x - 520, vs.y - 86), l_ayuda)
	caja_a.custom_minimum_size.x = 500
	# aviso de mando conectado (arriba, en el centro)
	l_mando.add_theme_font_size_override("font_size", 18)
	l_mando.add_theme_color_override("font_color", Color(0.75, 1.0, 0.8))
	l_mando.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l_mando.add_theme_constant_override("outline_size", 5)
	l_mando.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l_mando.anchor_left = 0.5
	l_mando.anchor_right = 0.5
	l_mando.offset_left = -320.0
	l_mando.offset_right = 320.0
	l_mando.offset_top = 92.0
	l_mando.offset_bottom = 120.0
	l_mando.visible = false
	hud.add_child(l_mando)
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
	hud_motor.actualizar(coche)
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
	l_modo.text = _nombre_corto(coche.ficha.nombre) + " · %d CV\n" % roundi(coche.ficha.potencia_cv) + "%s\nVelocidad elegida: %d km/h\nAdaptar en curvas: %s\nLímites (piloto): %s\nAdelantar: automático (O)\nLímite al adelantar: %s\nTráfico: %d %%\nCámara: %s" % [
		modo, roundi(Ajustes.velocidad), "sí" if Ajustes.adaptar_curvas else "no", "sí" if Ajustes.piloto_limites else "no", "respetar" if Ajustes.limite_adelantar else "no",
		roundi(Ajustes.trafico * 100.0),
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
	# opciones del piloto que antes iban en L1/R1 (ahora son las levas del cambio); con teclado siguen en K y L
	ck_curvas.text = "Piloto: frenar antes de las curvas (K)"
	ck_curvas.toggled.connect(func(on: bool): Ajustes.adaptar_curvas = on)
	ck_limite.text = "Al adelantar, respetar el límite (L)"
	ck_limite.toggled.connect(func(on: bool): Ajustes.limite_adelantar = on)
	v.add_child(ck_curvas)
	v.add_child(ck_limite)
	l_vol_p.text = "Volumen del motor"
	v.add_child(l_vol_p)
	sl_vol.min_value = 0.0
	sl_vol.max_value = 100.0
	sl_vol.step = 5.0
	sl_vol.custom_minimum_size.x = 380
	sl_vol.value_changed.connect(func(x: float):
		Ajustes.volumen_motor = x / 100.0
		Ajustes.silencio = false
		l_vol_p.text = "Volumen del motor: %d %%" % roundi(x))
	v.add_child(sl_vol)
	var b1 := b_continuar
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
	var b1 := b_repetir
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
		ck_curvas.set_pressed_no_signal(Ajustes.adaptar_curvas)
		sl_vol.set_value_no_signal(Ajustes.volumen_motor * 100.0)
		l_vol_p.text = "Volumen del motor: %d %%%s" % [roundi(Ajustes.volumen_motor * 100.0), " (silenciado, N)" if Ajustes.silencio else ""]
		ck_limite.set_pressed_no_signal(Ajustes.limite_adelantar)
		if pad_id >= 0: b_continuar.grab_focus.call_deferred()   # con el mando: cruceta para moverse, ✕ para elegir
	else:
		get_viewport().gui_release_focus()   # que Espacio / ✕ no pulsen un botón del menú mientras conduces


# ---------------- verificación automática ----------------
## --captura=conduccion|video: simula unos segundos de conducción y guarda una imagen (o deja grabar el vídeo)
func _captura() -> void:
	if Ajustes.args["captura"] == "giro":
		_prueba_giro()
		return
	if Ajustes.args["captura"] == "perfil":
		_prueba_perfil()
		return
	if Ajustes.args["captura"] == "lineas_adelantar":
		_generar_lineas()
		return
	if Ajustes.args["captura"] == "mapa_adelantar":
		_prueba_mapa_adelantar()
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
	var auto_o: bool = Ajustes.args.get("auto_o", "") == "1"
	var motivos_auto := {}
	for i in n:
		if auto_o and piloto and adel_estado == 0 and not _lider_lento().is_empty():
			_pedir_adelantamiento()
		var est0 := adel_estado
		var ch0 := choques
		_simular(1.0 / 60.0)
		if Ajustes.args.has("traza_choque") and choques != ch0 and choques < ch0 + 2 and (choques < 6 or choques % 200 == 0):
			var txt_c := ""
			for oc in trafico.coches:
				var pq: Vector3 = (oc["nodo"] as Node3D).position
				if pq.distance_to(coche.position) < 8.0:
					txt_c += " [dir=%d s=%.1f v=%.1f suelto=%s desv=%d]" % [oc["dir"], oc["s"], oc["v"], str(oc.get("suelto", false)), ruta.desvio_en(oc["s"], oc["dir"])]
			print("  CHOQUE_DBG t=%.1f s=%.1f lat=%.2f v=%.1f desv_jug=%d ceda=%.1f cerca:%s" % [tiempo, s_coche, lat_coche, coche.v, ruta.desvio_en(s_coche, dir), trafico.ceda_paso(s_coche, dir), txt_c])
		if auto_o and adel_estado == 1 and adel_motivo != "":
			var km: String = adel_motivo.split(" (")[0]
			motivos_auto[km] = motivos_auto.get(km, 0.0) + 1.0 / 60.0
		if auto_o and Ajustes.args.has("traza_adel"):
			if adel_estado != est0 and adel_estado >= 2:
				print("  t=%.1f PK %.3f estado %d→%d v=%.0f km/h carril=%.2f grupo=%d motivo=%s" % [tiempo, s_coche / 1000.0, est0, adel_estado, coche.v * 3.6, adel_carril, adel_grupo_n, adel_motivo])
			if choques != ch0:
				var txt := ""
				for oc in trafico.coches:
					var dd: float = (oc["s"] - s_coche) * dir
					if absf(dd) < 12.0: txt += " [%s d=%.1f v=%.0f suelto=%s]" % ["mismo" if oc["dir"] == dir else "frente", dd, float(oc["v"]) * 3.6, str(oc.get("suelto", false))]
				print("  CHOQUE t=%.1f PK %.3f estado=%d carril=%.2f lat=%.2f v=%.0f km/h abortado=%s cerca:%s" % [tiempo, s_coche / 1000.0, adel_estado, adel_carril, lat_coche, coche.v * 3.6, str(adel_abortado), txt])
		if Ajustes.args.get("traza", "") == "1" and i % 1800 == 0:
			print("  t=%4.0f s  PK %.2f km  lat %+.2f m  %3.0f km/h  alt %.0f  coches %d  derrapes %d choques %d fin=%s" % [
				tiempo, s_coche / 1000.0, lat_coche, coche.v * 3.6, coche.position.y, trafico.coches.size(), derrapes, choques, terminado])
		if Ajustes.args.has("traza_motor"):
			_traza_motor()
		if terminado and Ajustes.args["captura"] == "prueba":
			break
	coche.reset_physics_interpolation()
	trafico.reiniciar_interpolacion()
	mundo.cargar_ventana(coche.position, coche.adelante())
	reiniciar_camara()
	if auto_o:
		print("ADELANTAR_AUTO coche=%s preset=%s radio_min=%s trafico=%d dir=%d limite=%s: completados %d (coches pasados %d) · abortados %d · choques %d · terminado=%s tiempo=%.0f s v_media=%.1f km/h · segundos esperando por motivo %s" % [
			coche.ficha.id, Ajustes.args.get("preset", "v3.1"), str(ADEL_RADIO_MIN), roundi(Ajustes.trafico * 100.0), dir, str(Ajustes.limite_adelantar),
			adelantamientos, adel_coches_pasados, adel_abortos, choques, terminado, tiempo, coche.odometro / maxf(tiempo, 0.1) * 3.6, str(motivos_auto)])
	print("CAPTURA terminado=%s tiempo=%.0f s choques=%d biondas=%d s=%.1f km lat=%.2f v=%.1f km/h alt=%.1f via=%d coches=%d derrapes=%d" % [terminado, tiempo, choques, toques_bionda, s_coche / 1000.0, lat_coche,
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

## v4 --traza_motor=1: una línea por km con marcha, rpm y consumo (verificación)
var _traza_km := -1
var _traza_l := 0.0
func _traza_motor() -> void:
	var km := int(floor(s_coche / 1000.0)) if dir > 0 else int(ceil(s_coche / 1000.0))
	if _traza_km == -1:
		_traza_km = km
		_traza_l = coche.consumo.litros
		return
	if km == _traza_km and not terminado:
		return
	var cs := coche.consumo
	print("TRAZA_MOTOR km %.2f | %3.0f km/h | límite %d | %s %4.0f rpm | inst %s | media %.2f l/100 | %.3f l total | %.3f l este km | alt %.0f m | pend %+.1f %% | choques %d | adel %d" % [
		s_coche / 1000.0, absf(coche.v) * 3.6, senal.limite_en(s_coche, dir), coche.caja.texto_marcha(), coche.caja.rpm,
		"corte" if cs.l100_inst < 0.0 else "%.1f" % cs.l100_inst, cs.media(), cs.litros, cs.litros - _traza_l,
		coche.position.y, ruta.valor(ruta.pendiente, s_coche) * dir, choques, adelantamientos])
	_traza_km = km
	_traza_l = cs.litros


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
## REAL de esta versión (motor, aire, rodadura, la pendiente real del tramo y la velocidad a la que dejan ir las
## curvas), cuánto tiempo y cuántos metros necesita para pasar, y que en toda esa zona: no sea un tramo con
## prohibición de adelantar en OSM (datos/navacerrada/adelantar.json), no haya curvas de radio < ADEL_RADIO_MIN,
## se vea la carretera lo bastante lejos (curvas y cambios de rasante) para un coche que viniera de frente a la
## velocidad máxima de la vía, y ningún coche real de frente llegue antes de terminar.
## v3.1 (más agresivo): +15 km/h sobre el adelantado (antes 25), vuelve al carril 8 m por delante (antes 12),
## cambio de carril en 1,6 s (antes 2,2), 15 m de margen con los coches de frente (antes 30), sale con el lento
## hasta a 90 m (antes 70) y la regla de curvas baja de radio 350 m a 150 m. --preset=antes repite la v3.
var ADEL_MARGEN := 8.0          # m por delante del último adelantado antes de volver al carril
var ADEL_T_CAMBIO := 1.6        # s para cambiar de carril
const ADEL_HUECO_GRUPO := 30.0  # coches pegados al líder (< 30 m) se adelantan de una vez
var ADEL_DELTA := 15.0          # km/h mínimos por encima del adelantado
var ADEL_RADIO_MIN := 150.0     # m: no se adelanta si en la zona del adelantamiento hay curvas más cerradas (0 = sin regla)
var ADEL_MARGEN_FRENTE := 15.0  # m de margen con un coche de frente al terminar
var ADEL_DIST_LIDER := 90.0     # m: hasta dónde se busca el coche lento por delante
var ADEL_USAR_OSM := true       # respetar overtaking=no de OSM
var ADEL_SIM_CURVAS := true
var ADEL_USAR_LINEA := true     # no adelantar cruzando la línea continua pintada (derivada, ver Ajustes._lineas_adelantar)
var ADEL_VIS_COMPROMISO := true # visibilidad por punto de compromiso (v3.1) o desde la salida para todo el pase (v3)     # la simulación del adelantamiento frena para las curvas como el piloto
var adel_prohibido: Array = []  # [{a, b, sentido}] en metros de la ruta (overtaking=no de OSM)
var adel_motivo := ""
var adel_abortado := false
var adel_abort_detras := true   # abortado antes de llegar al primero de la fila (vuelve detrás de él)
var adel_abortos := 0
var adel_coches_pasados := 0
var adel_grupo_n := 1


func _ajustes_adelantamiento() -> void:
	var a := Ajustes.args
	if a.get("preset", "") == "antes":
		ADEL_MARGEN = 12.0
		ADEL_T_CAMBIO = 2.2
		ADEL_DELTA = 25.0
		ADEL_RADIO_MIN = 350.0
		ADEL_MARGEN_FRENTE = 30.0
		ADEL_DIST_LIDER = 70.0
		ADEL_USAR_OSM = false
		ADEL_SIM_CURVAS = false
		ADEL_VIS_COMPROMISO = false
		ADEL_GRUPO_MAX = 4
		ADEL_USAR_LINEA = false
		ADEL_HUECO_VUELTA = false
	if a.has("radio_min"): ADEL_RADIO_MIN = float(a["radio_min"])
	if a.has("usar_linea"): ADEL_USAR_LINEA = a["usar_linea"] == "1"
	if a.has("vis_compromiso"): ADEL_VIS_COMPROMISO = a["vis_compromiso"] == "1"
	if a.has("limite_adel"): Ajustes.limite_adelantar = a["limite_adel"] == "1"
	if a.has("piloto_limites"): Ajustes.piloto_limites = a["piloto_limites"] == "1"
	adel_prohibido.clear()
	var camino := Ajustes.dir_datos() + "adelantar.json"
	if not ADEL_USAR_OSM or not FileAccess.file_exists(camino):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(camino))
	if not (d is Dictionary) or not (d.get("rutas", null) is Array):
		return
	for r in d["rutas"]:
		if r is Dictionary and int(r.get("id", -1)) == Ajustes.ruta_idx:
			for t in r.get("prohibido", []):
				adel_prohibido.append({"a": float(t["km_ini"]) * 1000.0, "b": float(t["km_fin"]) * 1000.0, "sentido": str(t.get("sentido", "ambos"))})


func _prohibido_osm(s: float, d: int) -> bool:
	for t in adel_prohibido:
		if s >= t["a"] and s <= t["b"]:
			var sen: String = t["sentido"]
			if sen == "ambos" or (sen == "ida" and d > 0) or (sen == "vuelta" and d < 0):
				return true
	return false


## Límite de velocidad (km/h, de limites_velocidad.json) en s para el sentido d; 0 si no hay dato
func _limite(s: float, d: int) -> int:
	for t in senal.tramos:
		if s >= minf(t["a"], t["b"]) and s <= maxf(t["a"], t["b"]):
			var sen: String = t["sentido"]
			if sen == "ambos" or (sen == "ida" and d > 0) or (sen == "vuelta" and d < 0):
				return t["limite"]
	return 0


func _aviso_adel(msg: String) -> void:
	adel_msg = msg
	adel_msg_t = 3.0


## v5: con el piloto puesto el adelantamiento es automático: si hay un coche lento delante lo pide solo (con las
## mismas comprobaciones de seguridad que la tecla O). La O / □ sigue funcionando: pide el adelantamiento o, si está
## esperando hueco, lo cancela y el piloto no vuelve a pedirlo solo durante ADEL_AUTO_PAUSA s. --auto_adel=0 lo apaga.
const ADEL_AUTO_PAUSA := 15.0
const ADEL_DIST_LIDER_2MAS1 := 300.0   # m: en un carril adicional real (2+1) se busca el lento antes y se pasa de lejos
var adel_auto := false                 # el adelantamiento en curso lo pidió el piloto (avisos más discretos)
var adel_auto_espera := 0.0


func _adelantar_auto(dt: float) -> void:
	adel_auto_espera = maxf(0.0, adel_auto_espera - dt)
	if not piloto or terminado or adel_estado != 0 or adel_auto_espera > 0.0 or Ajustes.args.get("auto_adel", "1") == "0":
		return
	if _lider_lento().is_empty():
		return
	_pedir_adelantamiento()
	adel_auto = adel_estado == 1


## Hasta dónde se busca el coche lento: más lejos si nuestro sentido tiene carril adicional real (2+1) desde aquí
func _dist_lider() -> float:
	if ruta.carril_extra(s_coche, dir) and ruta.carril_extra(s_coche + dir * 150.0, dir):
		return ADEL_DIST_LIDER_2MAS1
	return ADEL_DIST_LIDER


func _pedir_adelantamiento() -> void:
	if adel_estado == 1:
		_cancelar_adelantamiento("Adelantamiento cancelado")
		adel_auto_espera = ADEL_AUTO_PAUSA
		return
	adel_auto = false
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


## El coche de nuestro sentido más cercano por delante (hasta ADEL_DIST_LIDER) que va más lento de lo que queremos ir
func _lider_lento() -> Dictionary:
	var mejor := {}
	var dmin := _dist_lider()
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


## El líder y los coches que van detrás de él sin hueco para volver a meterse entre ellos (hasta 4 en total).
## Hueco para volver: el margen de vuelta + lo que hace falta para frenar de la velocidad de adelantamiento a la del
## siguiente a 4 m/s² (si no, se meterá encima del de delante del grupo al volver).
var adel_sin_hueco := false
var ADEL_GRUPO_MAX := 12         # coches como mucho de una vez (v3: 4)
var ADEL_HUECO_VUELTA := true    # exigir hueco para volver delante del grupo (v3: no)
func _grupo(l: Dictionary) -> Array:
	var g := [l]
	var ultimo := l
	var v_obj := maxf(Ajustes.velocidad / 3.6, float(l["v"]) + ADEL_DELTA / 3.6)
	adel_sin_hueco = false
	for _i in ADEL_GRUPO_MAX:
		var sig := {}
		var hueco := ADEL_HUECO_GRUPO
		if ADEL_HUECO_VUELTA:
			var cierre := maxf(v_obj - float(ultimo["v"]), 0.0)
			hueco = maxf(hueco, ADEL_MARGEN + trafico.largo + cierre * cierre / (2.0 * ADEL_FRENADA_VUELTA) + 3.0)
		var dmin := hueco + trafico.largo
		for c in trafico.coches:
			if c["dir"] != dir or is_same(c, ultimo):
				continue
			var d: float = (c["s"] - ultimo["s"]) * dir
			if d > 0.0 and d < dmin:
				dmin = d
				sig = c
		if sig.is_empty():
			break
		if g.size() >= ADEL_GRUPO_MAX:
			adel_sin_hueco = ADEL_HUECO_VUELTA
			break
		g.append(sig)
		ultimo = sig
	return g


const ADEL_FRENADA_VUELTA := 2.5  # m/s²: frenada que se admite al volver al carril delante de otro (v3.1: 5, se notaba el frenazo)
const ADEL_HUECO_CORTO := 16.0   # m libres que hacen falta entre dos coches de la cola para meterse (además del coche)
var adel_parcial := false        # adelantando solo a los primeros de la cola
var adel_v_parcial := 0.0        # m/s: velocidad de ese adelantamiento (para poder meterse en el hueco)


## En un carril adicional real (2+1): el siguiente coche más lento por delante al que se alcanzaría pronto (si el
## carril sigue hasta pasarlo), para no volver a la derecha y tener que frenar detrás de él
func _siguiente_en_2mas1() -> Dictionary:
	if not ruta.carril_extra(s_coche, dir):
		return {}
	var v := absf(coche.v)
	var mejor := {}
	var dmin := 1e9
	for c in trafico.coches:
		if c["dir"] != dir: continue
		var d: float = (c["s"] - s_coche) * dir
		var dv: float = v - float(c["v"])
		if d <= 0.0 or dv < 2.0 or d > dv * dv / (2.0 * 2.0) + 40.0 or d >= dmin: continue
		if ruta.carril_extra_tramo(s_coche, s_coche + dir * (d + trafico.largo + ADEL_MARGEN + 30.0), dir):
			dmin = d
			mejor = c
	return mejor


## Tras adelantar a parte de la cola: ¿cabe ya en el hueco frenando como mucho 2 m/s²?
func _vuelta_suave() -> bool:
	var v := absf(coche.v)
	for c in trafico.coches:
		if c["dir"] != dir: continue
		var g: float = (c["s"] - s_coche) * dir - trafico.largo
		if g < -trafico.largo or g > 60.0: continue
		var dv: float = v - float(c["v"])
		if dv > 0.5 and g - 4.0 < dv * dv / (2.0 * 2.0):
			return false
	return true


func _frente_cerca() -> bool:
	if ruta.carril_extra(s_coche, dir):
		return false
	for c in trafico.coches:
		if c["dir"] == dir: continue
		var dc: float = (c["s"] - s_coche) * dir
		if dc > -3.0 and dc < (absf(coche.v) + absf(float(c["v"]))) * 3.0 + 20.0:
			return true
	return false


## "" si se puede adelantar ya; si no, el motivo
func _hueco_seguro() -> String:
	var grupo := _grupo(adel_lider)
	# en un carril adicional real (2+1) no hace falta hueco para volver delante de toda la fila: se va por el carril
	# de la izquierda de nuestro sentido y se puede volver a la derecha en cualquier hueco o donde acabe el carril
	if adel_sin_hueco and not ruta.carril_extra(s_coche, dir):
		return "fila larga: no hay hueco para volver"
	var ultimo: Dictionary = grupo[grupo.size() - 1]
	var ganar: float = (ultimo["s"] - s_coche) * dir + trafico.largo + ADEL_MARGEN
	# la fila va a la velocidad que quiere su coche más lento, que puede ser más de lo que va ahora (p. ej. saliendo
	# de una curva): se calcula con la mayor de las dos para no quedarse corto
	var v_fila := 1e9
	for c in grupo:
		v_fila = minf(v_fila, float(c.get("v0", c["v"])))
	var v_l := maxf(float(adel_lider["v"]), v_fila) if ADEL_HUECO_VUELTA else float(adel_lider["v"])
	adel_parcial = false
	var r := _evaluar_pase(s_coche, dir, absf(coche.v), v_l, ganar, true, (adel_lider["s"] - s_coche) * dir, float(adel_lider["v"]))
	if r["motivo"] == "" and not adel_sin_hueco:
		adel_ultimo = ultimo
		adel_grupo_n = grupo.size()
		return ""
	# v5: con cola, si no da para pasarlos a todos se prueba con menos (de más a menos): adelantar a los n primeros y
	# meterse en el hueco entre el n y el n+1 (≥ ADEL_HUECO_CORTO libres), sin pasar de +ADEL_DELTA sobre ellos para
	# poder meterse sin frenazo. Mismas comprobaciones de seguridad (coches de frente, visibilidad, curvas, OSM).
	for n in range(grupo.size() - 1, 0, -1):
		var cn: Dictionary = grupo[n - 1]
		var sig: Dictionary = grupo[n]
		if (sig["s"] - cn["s"]) * dir - trafico.largo < trafico.largo + ADEL_HUECO_CORTO:
			continue
		var v_n := 0.0
		for k in n:
			v_n = maxf(v_n, maxf(float(grupo[k]["v"]), float(grupo[k].get("v0", grupo[k]["v"]))))
		var ganar_n: float = (cn["s"] - s_coche) * dir + trafico.largo + ADEL_MARGEN
		var rn := _evaluar_pase(s_coche, dir, absf(coche.v), v_n, ganar_n, true, (adel_lider["s"] - s_coche) * dir, float(adel_lider["v"]), v_n + ADEL_DELTA / 3.6)
		if rn["motivo"] == "":
			adel_ultimo = cn
			adel_grupo_n = n
			adel_parcial = true
			adel_v_parcial = v_n + ADEL_DELTA / 3.6
			return ""
	if r["motivo"] == "":
		return "fila larga: no hay hueco para volver"
	return r["motivo"]


## Comprueba un adelantamiento que empieza en s0 (sentido d) a v0 m/s, detrás de un coche a v_l m/s,
## con 'ganar' metros que sacarle. Devuelve {motivo ("" = se puede), recorrido (m), t (s), v_obj (m/s)}.
func _evaluar_pase(s0: float, d: int, v0: float, v_l: float, ganar: float, con_trafico: bool, gap_lider: float = -1.0, v_l0: float = -1.0, v_max_pase: float = -1.0) -> Dictionary:
	var res := {"motivo": "", "recorrido": 0.0, "t": 0.0, "v_obj": 0.0}
	var v_obj := maxf(Ajustes.velocidad / 3.6, v_l + ADEL_DELTA / 3.6)
	# v5: con carril adicional real de nuestro sentido (2+1) basta con poder ir más rápido que el de delante
	# (no se exige sacarle +ADEL_DELTA: cuesta arriba puede no haber margen y no se invade el carril contrario)
	var extra := ruta.carril_extra(s0, d)
	if extra:
		v_obj = Ajustes.velocidad / 3.6
		if v_obj < v_l + 5.0 / 3.6:
			res["motivo"] = "no va más rápido que el de delante"
			return res
	if v_max_pase > 0.0:
		v_obj = minf(v_obj, v_max_pase)
	if Ajustes.limite_adelantar:
		var lim := 1000
		var dd := 0.0
		while dd <= 400.0:
			var l := _limite(s0 + d * dd, d)
			if l > 0: lim = mini(lim, l)
			dd += 20.0
		v_obj = minf(v_obj, lim / 3.6)
		if v_obj < v_l + 8.0 / 3.6:
			res["motivo"] = "límite de velocidad (%d km/h)" % lim
			return res
	res["v_obj"] = v_obj
	var v := v0
	var t := 0.0
	var recorrido := 0.0
	var rel := 0.0
	var fi := coche.ficha
	# punto de compromiso: cuando ya está a la altura del líder (antes de eso puede abortar y volver detrás)
	var rel_altura := (gap_lider if gap_lider >= 0.0 else ganar - ADEL_MARGEN - trafico.largo) - trafico.largo - 1.0
	var t_c := -1.0
	var x_c := 0.0
	var v_c := v0
	var vl := v_l0 if v_l0 >= 0.0 else v_l      # velocidad actual del adelantado
	var vl_obj := v_l
	var n_paso := 0
	while rel < ganar and t < 40.0:
		# el adelantado también frena en las curvas (con la aceleración lateral del tráfico) y acelera al salir
		if ADEL_HUECO_VUELTA:
			if n_paso % 5 == 0:
				vl_obj = minf(v_l, trafico.vel_curva(s0 + d * (rel_altura + trafico.largo + 1.0 + recorrido - rel), d, Trafico.A_LAT, 100.0))
			vl = clampf(vl_obj, vl - Trafico.B_COMODA * 0.1, vl + Trafico.A_MAX * 0.1)
		else:
			vl = v_l
		n_paso += 1
		if t_c < 0.0 and rel >= rel_altura:
			t_c = t
			x_c = recorrido
			v_c = v
		var sp := s0 + d * recorrido
		var seno := ruta.valor(ruta.pendiente, sp) * d / 100.0
		var a := (coche.fuerza_motor(v) - coche.fuerza_resistente(v) - fi.masa * Coche.G * seno) / fi.masa
		# el piloto no pasa de lo que dejan las curvas (si se adapta), igual que al conducir
		var v_tope := minf(v_obj, trafico.vel_curva(sp, d, 4.0, 220.0)) if (Ajustes.adaptar_curvas and ADEL_SIM_CURVAS) else v_obj
		if v >= v_tope:
			a = minf(a, (v_tope - v) / 0.5)
		v = maxf(v + a * 0.1, 0.0)
		recorrido += v * 0.1
		rel += (v - vl) * 0.1
		t += 0.1
	if rel < ganar:
		res["motivo"] = "el coche no da para pasar aquí"
		return res
	t += ADEL_T_CAMBIO
	recorrido += v * ADEL_T_CAMBIO
	res["recorrido"] = recorrido
	res["t"] = t
	# carril adicional real (OSM, 2+1) en todo el pase: se adelanta por él sin invadir el sentido contrario
	if ruta.carril_extra_tramo(s0, s0 + d * (recorrido + 15.0), d):
		return res
	var x := 0.0
	while x <= recorrido + 15.0:
		var sx := s0 + d * x
		if ADEL_RADIO_MIN > 0.0 and absf(ruta.valor(ruta.curvatura, sx)) > 1.0 / ADEL_RADIO_MIN:
			res["motivo"] = "curva cerrada (radio < %d m)" % roundi(ADEL_RADIO_MIN)
			return res
		if ADEL_USAR_LINEA and ruta.discontinua.size() == ruta.n and ruta.discontinua[clampi(int(sx / ruta.paso), 0, ruta.n - 1)] == 0:
			res["motivo"] = "línea continua"
			return res
		if not adel_prohibido.is_empty() and _prohibido_osm(sx, d):
			res["motivo"] = "prohibido adelantar (OSM)"
			return res
		x += 4.0
	var v_frente := maxf(ruta.valor(ruta.vmax, s0 + d * recorrido), 50.0) / 3.6
	if not ADEL_VIS_COMPROMISO:
		# v3: desde la salida tiene que verse todo lo que recorre más lo que recorre un coche de frente en todo el tiempo
		var necesaria := recorrido + v_frente * t + ADEL_MARGEN_FRENTE
		var vis := _visibilidad(necesaria, s0, d)
		if vis < necesaria:
			res["motivo"] = "sin visibilidad (%d de %d m)" % [roundi(vis), roundi(necesaria)]
			return res
	else:
		# v3.1 (criterio del "punto crítico" de los manuales de trazado): mientras no está a la altura del líder puede
		# abortar, así que desde la salida basta con ver lo que hace falta para abortar si aparece alguien
		# (la misma regla que usa el aborto: 2,5 s de cierre + 15 m); y desde el punto de compromiso tiene que verse
		# lo que le queda por recorrer más lo que recorre en ese tiempo un coche de frente al límite de la vía.
		if t_c < 0.0:
			t_c = 0.0
		var nec_salida := minf((v_obj + v_frente) * 2.5 + 15.0, recorrido + v_frente * t + ADEL_MARGEN_FRENTE)
		var vis0 := _visibilidad(nec_salida, s0, d)
		if vis0 < nec_salida:
			res["motivo"] = "sin visibilidad (%d de %d m)" % [roundi(vis0), roundi(nec_salida)]
			return res
		var nec_c := (recorrido - x_c) + v_frente * (t - t_c) + ADEL_MARGEN_FRENTE
		var vis_c := _visibilidad(nec_c, s0 + d * x_c, d)
		if vis_c < nec_c:
			res["motivo"] = "sin visibilidad (%d de %d m)" % [roundi(vis_c), roundi(nec_c)]
			return res
	if con_trafico:
		for c in trafico.coches:
			if c["dir"] == d:
				continue
			var dc: float = (c["s"] - s0) * d
			if dc > -10.0 and dc < recorrido + _v_coche_frente(c) * t + ADEL_MARGEN_FRENTE:
				res["motivo"] = "viene un coche de frente"
				return res
	return res


## Hasta dónde se ve la carretera desde el asiento (m): la visual a 1,1 m no puede salirse de la calzada
## en las curvas ni pasar por debajo del asfalto en un cambio de rasante
func _visibilidad(hasta: float, s0: float = NAN, d0: int = 0) -> float:
	if is_nan(s0): s0 = s_coche
	if d0 == 0: d0 = dir
	var ojo := ruta.punto(s0) + Vector3.UP * 1.1
	var d := 20.0
	while d <= hasta + 19.0:
		var obj := ruta.punto(s0 + d0 * d) + Vector3.UP * 1.1
		var n := maxi(2, int(d / 10.0))
		for i in range(1, n):
			var u := float(i) / n
			var p := ojo.lerp(obj, u)
			var sm := s0 + d0 * d * u
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
			if not piloto or not _existe(adel_lider) or (adel_lider["s"] - s_coche) * dir < 0.0 or (adel_lider["s"] - s_coche) * dir > _dist_lider() + 20.0:
				_cancelar_adelantamiento("" if adel_auto else "Ya no hay coche lento delante")
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
			# v3.1: se vuelve a comprobar en cada paso si algún coche de frente llega antes de terminar (por si la fila
			# acelera o el pase se alarga). Si pasa: antes de llegar al primero, aborta detrás de él; si va por la
			# mitad de la fila, frena y se mete en el hueco de la fila; ya pasado el último, termina.
			if ADEL_HUECO_VUELTA and d_ult > -(trafico.largo + ADEL_MARGEN):
				adel_revisar -= dt
				var conflicto := false
				if adel_revisar <= 0.0:
					adel_revisar = 0.2
					var resto := _sim_resto(absf(coche.v), maxf(float(adel_ultimo["v"]), float(adel_ultimo.get("v0", adel_ultimo["v"]))), d_ult + trafico.largo + ADEL_MARGEN, float(adel_ultimo["v"]), float(adel_ultimo["s"]))
					var t_rest: float = resto.y
					var x_rest: float = resto.x
					# A-308 (2+1): si el carril adicional real cubre todo lo que queda de pase, los de frente van por su
					# carril y no hay conflicto (evita el bucle empezar/abortar donde termina el carril adicional)
					var cubre_extra := ruta.carril_extra_tramo(s_coche, s_coche + dir * x_rest, dir)
					for c in trafico.coches:
						if not cubre_extra and c["dir"] != dir and (c["s"] - s_coche) * dir > -3.0 and (c["s"] - s_coche) * dir < x_rest + _v_coche_frente(c) * t_rest + 5.0:
							conflicto = true
				if Ajustes.args.has("traza_pase") and adel_revisar >= 0.19:
					var dmin_f := 1e9
					var vf := 0.0
					for c in trafico.coches:
						if c["dir"] != dir and (c["s"] - s_coche) * dir > -3.0 and (c["s"] - s_coche) * dir < dmin_f:
							dmin_f = (c["s"] - s_coche) * dir
							vf = _v_coche_frente(c)
					print("    pase t=%.1f PK %.3f v=%.0f d_ult=%.1f d_lid=%.1f frente a %.0f m (%.0f km/h) conflicto=%s" % [tiempo, s_coche / 1000.0, coche.v * 3.6, d_ult, d_lid, dmin_f, vf * 3.6, str(conflicto)])
					for c in trafico.coches:
						if c["dir"] != dir and absf((c["s"] - s_coche) * dir) < 250.0:
							print("      frente s=%.1f d=%.1f v=%.1f v0=%.1f suelto=%s lat_nodo=%.1f" % [c["s"], (c["s"] - s_coche) * dir, c["v"] * 3.6, c["v0"] * 3.6, str(c.get("suelto", false)), ruta.proyectar(c["nodo"].position, c["s"]).y])
				if conflicto:
					adel_abortado = true
					adel_abort_detras = d_lid > trafico.largo + 1.0
					adel_abortos += 1
					adel_estado = 3
					_aviso_adel("Adelantamiento abortado: viene un coche")
					return
			# ¿aparece alguien de frente demasiado cerca? se aborta y se vuelve detrás
			for c in trafico.coches:
				if c["dir"] == dir:
					continue
				var dc: float = (c["s"] - s_coche) * dir
				var cierre := absf(coche.v) + absf(float(c["v"]))
				# solo se aborta si aún no ha llegado a la altura del adelantado (puede volver detrás de él);
				# si ya está a su lado, lo más seguro es terminar a fondo
				if dc > -3.0 and dc < cierre * 2.5 + 15.0 and d_lid > trafico.largo + 1.0 and not ruta.carril_extra_tramo(s_coche, s_coche + dir * maxf(dc, 0.0), dir):
					adel_abort_detras = true
					adel_abortado = true
					adel_abortos += 1
					adel_estado = 3
					_aviso_adel("Adelantamiento abortado: viene un coche")
					return
			if d_ult < -(trafico.largo + ADEL_MARGEN):
				# v5: pasados los primeros de la cola, se mete en el hueco solo cuando puede hacerlo sin frenazo
				# (si aún va muy rápido para el hueco, frena un poco en el carril de adelantar); con alguien de frente, ya
				var sig_lento := _siguiente_en_2mas1()
				if not sig_lento.is_empty():
					adel_ultimo = sig_lento          # 2+1: hay otro más lento justo delante, sigue por el carril de la izquierda
					adel_grupo_n += 1
				elif not adel_parcial or _vuelta_suave() or _frente_cerca():
					adel_estado = 3
		3:
			var al_lado := false
			if ADEL_HUECO_VUELTA and adel_abortado:
				# abortado en mitad de la fila: si el coche de al lado va por delante, espera (frenando) a quedar detrás
				# de él; si ya lo lleva por detrás, se mete delante. Vuelve al carril el doble de rápido.
				for c in trafico.coches:
					var dl: float = (c["s"] - s_coche) * dir
					if c["dir"] == dir and dl > 0.0 and dl < trafico.largo + 1.5:
						al_lado = true
				paso *= 2.0
			if not al_lado:
				adel_carril = move_toward(adel_carril, 0.0, paso)
			if adel_carril <= 0.0:
				adel_estado = 0
				if not adel_abortado:
					adelantamientos += 1
					adel_coches_pasados += adel_grupo_n
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
		var lento := trafico.crear_prueba(s_coche + dir * float(Ajustes.args.get("d_lento", "45")), dir, float(Ajustes.args.get("v_lento", "45")) / 3.6, false)
		lento["v0"] = float(Ajustes.args.get("v_lento", "45")) / 3.6
		coche.v = lento["v"]
		if Ajustes.args.has("v_ini"): coche.v = float(Ajustes.args["v_ini"]) / 3.6
		# --n_cola=N: N coches más detrás del lento, cada --cola_d m (cola), a la misma velocidad
		for k in int(Ajustes.args.get("n_cola", "0")):
			var cc := trafico.crear_prueba(s_coche + dir * (float(Ajustes.args.get("d_lento", "45")) - float(Ajustes.args.get("cola_d", "28")) * (k + 1)), dir, lento["v"], false)
			cc["v0"] = lento["v0"]
		var a_min := 0.0
		var v_prev := coche.v
		var t_freno := 0.0
		var t_corte := 0.0
		coche.consumo.reiniciar()
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
			if t > 0.5 and (coche.v - v_prev) / dt < a_min:
				a_min = (coche.v - v_prev) / dt
				if a_min < -3.0:
					var txt := ""
					for oc in trafico.coches:
						var dd: float = (oc["s"] - s_coche) * dir
						if oc["dir"] == dir and dd > -10.0 and dd < 60.0: txt += " [d=%.1f v=%.0f]" % [dd, float(oc["v"]) * 3.6]
					print("  frenazo t=%.1f a=%.1f v=%.0f estado=%d carril=%.2f parcial=%s gas=%.2f freno=%.2f golpes=%d%s" % [t, a_min, coche.v * 3.6, adel_estado, adel_carril, str(adel_parcial), coche.acelerador, coche.freno, colisiones.golpes, txt])
			v_prev = coche.v
			if coche.freno > 0.0: t_freno += dt
			if Ajustes.args.has("traza_acerc") and int(t * 60.0) % 60 == 0:
				print("  t=%.0f v=%.0f d=%.0f gas=%.2f freno=%.2f pend=%+.1f%%" % [t, coche.v * 3.6, (lento["s"] - s_coche) * dir, coche.acelerador, coche.freno, ruta.valor(ruta.pendiente, s_coche) * dir])
			if coche.acelerador <= 0.0 and coche.freno <= 0.0: t_corte += dt
			if adel_estado == 1:
				espera += dt
				motivos[adel_motivo] = motivos.get(adel_motivo, 0) + 1
			if adel_estado == 2 and inicio < 0.0:
				inicio = t
				print("  sale a adelantar en t=%.1f s, PK %.3f km, radio de curva aquí %.0f m" % [t, s_coche / 1000.0, 1.0 / maxf(absf(ruta.valor(ruta.curvatura, s_coche)), 1e-5)])
			max_carril = maxf(max_carril, adel_carril)
			if Ajustes.args.has("salida") and adel_estado == 2 and adel_carril >= 0.95 and _existe(lento) and (lento["s"] - s_coche) * dir < float(Ajustes.args.get("foto_d", "4")):
				print("  FOTO t=%.1f PK %.3f v=%.0f km/h radio aquí %.0f m" % [t, s_coche / 1000.0, coche.v * 3.6, 1.0 / maxf(absf(ruta.valor(ruta.curvatura, s_coche)), 1e-5)])
				coche.reset_physics_interpolation()
				trafico.reiniciar_interpolacion()
				mundo.cargar_ventana(coche.position, coche.adelante())
				reiniciar_camara()
				for _k in 4:
					_camara(1.0 / 60.0)
				_hud()
				pausado = true
				for _k in 12:
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(Ajustes.args["salida"])
				get_tree().quit()
				return
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
		print("PRUEBA cola: adelantamientos %d · coches pasados %d · abortos %d" % [adelantamientos, adel_coches_pasados, adel_abortos])
		print("PRUEBA acercamiento: deceleración máx %.2f m/s² · %.1f s con freno · %.1f s sin gas ni freno · %.3f l en %.0f m (%.2f l/100 km)" % [
			-a_min, t_freno, t_corte, coche.consumo.litros, coche.consumo.metros, coche.consumo.litros / maxf(coche.consumo.metros, 1.0) * 1e5])
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
	coche.colocar(ruta.punto_carril(s, dir), ruta.marcha_carril(s, dir))
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
		get_viewport().gui_release_focus()


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


## --captura=mapa_adelantar: recorre la ruta cada 10 m en los dos sentidos y dice en qué % se permitiría salir a
## adelantar a un coche a --v_lento km/h (60) que va 25 m por delante, sin tráfico (solo trazado, visibilidad, OSM).
## --radios=350,250,200,150,100,0 repite la cuenta con cada radio mínimo.
func _prueba_mapa_adelantar() -> void:
	var v_l := float(Ajustes.args.get("v_lento", "60")) / 3.6
	Ajustes.velocidad = float(Ajustes.args.get("vel", "90"))
	var radios: Array = []
	for x in str(Ajustes.args.get("radios", str(ADEL_RADIO_MIN))).split(","):
		radios.append(float(x))
	var largo := ruta.longitud()
	for rm in radios:
		ADEL_RADIO_MIN = rm
		var linea := "MAPA radio_min=%s" % ("no" if rm <= 0.0 else str(roundi(rm)))
		for d in [1, -1]:
			var si := 0
			var tot := 0
			var motivos := {}
			var zonas := 0
			var antes := false
			var dist_med := 0.0
			var s := 0.0 if d > 0 else largo
			while (s < largo - 300.0) if d > 0 else (s > 300.0):
				var r := _evaluar_pase(s, d, v_l, v_l, 25.0 + trafico.largo + ADEL_MARGEN, false, 25.0)
				tot += 1
				var ok: bool = r["motivo"] == ""
				if ok:
					si += 1
					dist_med += r["recorrido"]
					if not antes: zonas += 1
					if Ajustes.args.has("listar") and not antes:
						var kmin := 0.0
						var xx := 0.0
						while xx < r["recorrido"]:
							kmin = maxf(kmin, absf(ruta.valor(ruta.curvatura, s + d * xx)))
							xx += 4.0
						print("  zona %s km %.2f radio mín en el pase %.0f m" % ["ida" if d > 0 else "vuelta", s / 1000.0, 1.0 / maxf(kmin, 1e-5)])
				else:
					var k: String = r["motivo"].split(" (")[0]
					motivos[k] = motivos.get(k, 0) + 1
				antes = ok
				s += 10.0 * d
			linea += " | %s: %.1f %% (%d zonas, recorrido medio %.0f m) motivos %s" % ["ida" if d > 0 else "vuelta", 100.0 * si / maxf(tot, 1), zonas, dist_med / maxf(si, 1), str(motivos)]
		print(linea)
	# distancia y tiempo de un adelantamiento en llano y recto (coche de --v_lento a su misma velocidad)
	print("PASE_LLANO %s v_lento=%.0f km/h: %s" % [coche.ficha.id, v_l * 3.6, str(_pase_llano(v_l))])
	get_tree().quit()


## Simula el mismo cálculo de _evaluar_pase pero en una recta llana ideal
func _pase_llano(v_l: float) -> Dictionary:
	var v_obj := maxf(Ajustes.velocidad / 3.6, v_l + ADEL_DELTA / 3.6)
	var ganar := 25.0 + trafico.largo + ADEL_MARGEN
	var v := v_l
	var t := 0.0
	var recorrido := 0.0
	var rel := 0.0
	var fi := coche.ficha
	while rel < ganar and t < 40.0:
		var a := (coche.fuerza_motor(v) - coche.fuerza_resistente(v)) / fi.masa
		if v >= v_obj: a = minf(a, 0.0)
		v = maxf(v + a * 0.1, 0.0)
		recorrido += v * 0.1
		rel += (v - v_l) * 0.1
		t += 0.1
	return {"recorrido_m": roundi(recorrido + v * ADEL_T_CAMBIO), "tiempo_s": snappedf(t + ADEL_T_CAMBIO, 0.1), "v_final_kmh": roundi(v * 3.6), "ganar_m": roundi(ganar)}

## --captura=lineas_adelantar --salida_json=…: para cada ruta, tramos donde la línea central se pinta discontinua:
## la unión de todas las zonas que recorrería un adelantamiento permitido (sin tráfico) en cualquiera de los dos
## sentidos, con un lento a 40 y a 60 km/h y el piloto a 90. Se ejecuta con cada versión y se juntan (pipeline).
func _generar_lineas() -> void:
	ADEL_USAR_LINEA = false
	Ajustes.velocidad = 90.0
	var salida := {}
	for ri in Ajustes.rutas.size():
		ruta = Ajustes.rutas[ri]
		trafico.ruta = ruta
		var m := PackedByteArray()
		m.resize(ruta.n)
		m.fill(0)
		var largo := ruta.longitud()
		for vl in [40.0, 60.0]:
			var v_l: float = vl / 3.6
			for d in [1, -1]:
				var s := 0.0 if d > 0 else largo
				while (s < largo) if d > 0 else (s > 0.0):
					var r := _evaluar_pase(s, d, v_l, v_l, 25.0 + trafico.largo + ADEL_MARGEN, false, 25.0)
					if r["motivo"] == "":
						var x := 0.0
						while x <= float(r["recorrido"]):
							m[clampi(int((s + d * x) / ruta.paso), 0, ruta.n - 1)] = 1
							x += ruta.paso
					s += 10.0 * d
		var tramos := []
		var i := 0
		while i < ruta.n:
			if m[i] == 1:
				var j := i
				while j + 1 < ruta.n and m[j + 1] == 1:
					j += 1
				tramos.append([snappedf(i * ruta.paso / 1000.0, 0.001), snappedf(j * ruta.paso / 1000.0, 0.001)])
				i = j + 1
			else:
				i += 1
		salida[str(ri)] = tramos
		print("LINEAS ruta %d: %d tramos discontinuos" % [ri, tramos.size()])
	var f := FileAccess.open(Ajustes.args["salida_json"], FileAccess.WRITE)
	f.store_string(JSON.stringify(salida))
	f.close()
	get_tree().quit()

## Lo que le queda a un adelantamiento en marcha: (metros, segundos) hasta volver al carril, con la misma física que
## _evaluar_pase, desde la velocidad actual y con 'falta' metros que ganar al último de la fila
func _sim_resto(v0: float, v_ult: float, falta: float, v_ult0: float = -1.0, s_ult: float = -1.0) -> Vector2:
	var v := v0
	var t := 0.0
	var x := 0.0
	var rel := 0.0
	var v_obj := maxf(Ajustes.velocidad / 3.6, v_ult + ADEL_DELTA / 3.6)
	var fi := coche.ficha
	var vl := v_ult0 if v_ult0 >= 0.0 else v_ult
	var vl_obj := v_ult
	var n_paso := 0
	while rel < falta and t < 40.0:
		if s_ult >= 0.0:
			if n_paso % 5 == 0:
				vl_obj = minf(v_ult, trafico.vel_curva(s_ult + dir * (x - rel), dir, Trafico.A_LAT, 100.0))
			vl = clampf(vl_obj, vl - Trafico.B_COMODA * 0.1, vl + Trafico.A_MAX * 0.1)
		n_paso += 1
		var sp := s_coche + dir * x
		var seno := ruta.valor(ruta.pendiente, sp) * dir / 100.0
		var a := (coche.fuerza_motor(v) - coche.fuerza_resistente(v) - fi.masa * Coche.G * seno) / fi.masa
		var v_tope := minf(v_obj, trafico.vel_curva(sp, dir, 4.0, 220.0)) if Ajustes.adaptar_curvas else v_obj
		if v >= v_tope:
			a = minf(a, (v_tope - v) / 0.5)
		v = maxf(v + a * 0.1, 0.0)
		x += v * 0.1
		rel += (v - vl) * 0.1
		t += 0.1
	return Vector2(x + v * ADEL_T_CAMBIO, t + ADEL_T_CAMBIO)

## Velocidad con la que hay que contar para un coche de frente: la que lleva o la que quiere llevar (sale de una curva
## despacio y acelera), la mayor; si no, un pase largo se queda corto (v3.1, fallo visto en el A-308 y en el km 8,5)
func _v_coche_frente(c: Dictionary) -> float:
	if not ADEL_HUECO_VUELTA:
		return absf(float(c["v"]))
	return maxf(absf(float(c["v"])), float(c.get("v0", c["v"])))
