## Prueba del mando (PS4 / mando "estándar") sin mando real: inyecta eventos de joystick, gatillos y botones
## con Input.parse_input_event y comprueba que llegan al coche. También comprueba que el teclado sigue igual.
##   godot --headless res://pruebas/prueba_mando.tscn -- --ruta=0 --piloto=0 --trafico=0 --km_ini=2 --km_fin=12
extends Node

var j
var fallos := 0


func _ready() -> void:
	call_deferred("_correr")


func _ok(cond: bool, txt: String) -> void:
	print(("OK    " if cond else "FALLO ") + txt)
	if not cond: fallos += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _tecla(k: Key, on: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = k
	e.keycode = k
	e.pressed = on
	Input.parse_input_event(e)


func _eje(a: JoyAxis, v: float) -> void:
	var e := InputEventJoypadMotion.new()
	e.device = 0
	e.axis = a
	e.axis_value = v
	Input.parse_input_event(e)


func _boton(b: JoyButton, on: bool) -> void:
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = b
	e.pressed = on
	e.pressure = 1.0 if on else 0.0
	Input.parse_input_event(e)


func _pulsar(b: JoyButton) -> void:
	_boton(b, true)
	await _frames(2)
	_boton(b, false)
	await _frames(2)


func _parar() -> void:
	j.coche.v = 0.0
	j.s_coche = j.s_ini + 300.0 * j.dir      # siempre en el mismo punto (misma pendiente)
	j._reiniciar(false)
	j.coche.v = 0.0
	await _frames(5)


## tiempo de 0 a 100 km/h con lo que haya pulsado (en el tramo real, con su pendiente)
func _cero_cien() -> float:
	var t := 0.0
	while j.coche.v < 100.0 / 3.6 and t < 40.0:
		await get_tree().physics_frame
		t += 1.0 / Engine.physics_ticks_per_second
	return t


## ---- levas L1/R1 y teclas Z/X: cambio manual secuencial (compartida con prueba_mando_madrid.gd) ----
## `p` es la prueba (con j, _ok, _frames, _pulsar, _eje, _tecla, _boton)
static func prueba_levas(p) -> void:
	var j = p.j
	var caja: Transmision = j.coche.caja
	await p._parar()
	j.piloto = false
	p._eje(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	var t := 0.0
	while j.coche.v < 60.0 / 3.6 and t < 20.0:
		await p._frames(1)
		t += 1.0 / Engine.physics_ticks_per_second
	p._eje(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	var g0: int = caja.marcha
	p._ok(not caja.manual and caja.texto_marcha() == "D%d" % g0, "a 60 km/h en automático: %s" % caja.texto_marcha())
	await p._pulsar(JOY_BUTTON_RIGHT_SHOULDER)
	p._ok(caja.manual and caja.marcha == g0 + 1 and caja.texto_marcha() == "M%d" % (g0 + 1), "R1 → manual y una marcha más: %s (rpm %d)" % [caja.texto_marcha(), caja.rpm])
	await p._frames(20)
	p._ok(j.hud_motor.l_marcha.text.begins_with("M%d" % (g0 + 1)), "HUD: \"%s\"" % j.hud_motor.l_marcha.text)
	await p._pulsar(JOY_BUTTON_LEFT_SHOULDER)
	p._ok(caja.manual and caja.marcha == g0, "L1 → una marcha menos: %s" % caja.texto_marcha())
	# en manual no sube sola: R2 a fondo 6 s en 2ª → se queda en 2ª, en el corte
	await p._pulsar(JOY_BUTTON_LEFT_SHOULDER)
	while caja.marcha > 2:
		await p._pulsar(JOY_BUTTON_LEFT_SHOULDER)
		if caja.rechazo_t > 0.0:
			j.coche.v *= 0.9      # aún pasaría del corte: frena un poco y vuelve a intentarlo
	var rpm_max := 0.0
	p._eje(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	for i in 360:
		await p._frames(1)
		rpm_max = maxf(rpm_max, caja.rpm)
	p._eje(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	p._ok(caja.marcha == 2 and caja.manual, "manual: R2 a fondo 6 s en 2ª → sigue en %s (no sube sola)" % caja.texto_marcha())
	p._ok(rpm_max <= caja.corte + 1.0 and rpm_max > caja.corte - 400.0, "manual: llega al corte y no lo pasa (máx %d rpm, corte %d) a %d km/h" % [rpm_max, caja.corte, j.coche.v * 3.6])
	# reducción que pasaría del corte: rechazada, marca roja en el HUD
	p._ok(not caja.pedir_cambio(-1) and caja.marcha == 2 and caja.rechazo_t > 0.0, "L1 en el corte → reducción a 1ª rechazada (pasaría del corte)")
	await p._frames(3)
	p._ok(j.hud_motor.l_marcha.modulate.g < 0.5, "HUD: cambio rechazado en rojo")
	# subir a 7ª y frenar hasta parar: reduce solo para no calar y acaba en 1ª, sigue en manual
	for i in 6:
		await p._pulsar(JOY_BUTTON_RIGHT_SHOULDER)
	var g_alta: int = caja.marcha
	p._eje(JOY_AXIS_TRIGGER_LEFT, 0.6)
	var rpm_min := 99999.0
	t = 0.0
	while j.coche.v > 1.0 and t < 30.0:
		await p._frames(1)
		t += 1.0 / Engine.physics_ticks_per_second
		if j.coche.v > 3.0: rpm_min = minf(rpm_min, caja.rpm)
	p._ok(caja.manual and caja.marcha == 1, "subiendo hasta %d.ª y frenando hasta casi parar → reduce solo hasta M1 (%s a %.1f km/h)" % [g_alta, caja.texto_marcha(), j.coche.v * 3.6])
	p._eje(JOY_AXIS_TRIGGER_LEFT, 0.0)
	j.coche.v = 0.0
	await p._frames(5)
	p._ok(rpm_min >= caja.ralenti - 1.0, "en la frenada el motor no baja del ralentí (mín %d rpm)" % rpm_min)
	# desde parado en M1: arranca y sube con R1
	p._eje(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	t = 0.0
	while j.coche.v < 30.0 / 3.6 and t < 10.0:
		await p._frames(1)
		t += 1.0 / Engine.physics_ticks_per_second
	await p._pulsar(JOY_BUTTON_RIGHT_SHOULDER)
	p._ok(caja.marcha == 2, "arrancar en M1 y R1 → M2 (%s, %d km/h)" % [caja.texto_marcha(), j.coche.v * 3.6])
	p._eje(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	# R1 mantenido 0,8 s → vuelve al automático
	p._boton(JOY_BUTTON_RIGHT_SHOULDER, true)
	await p._frames(60)
	p._boton(JOY_BUTTON_RIGHT_SHOULDER, false)
	await p._frames(3)
	p._ok(not caja.manual and caja.texto_marcha().begins_with("D"), "R1 mantenido 1 s → automático (%s)" % caja.texto_marcha())
	# teclado: G baja (y pasa a manual), T sube, T mantenida → automático
	# (desde el punto fijo: acelerando 20 s en línea recta desde donde quedara el coche llegaba a una bionda)
	var toques0: int = j.toques_bionda
	await p._parar()
	p._eje(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	t = 0.0
	while j.coche.v < 75.0 / 3.6 and t < 20.0:
		await p._frames(1)
		t += 1.0 / Engine.physics_ticks_per_second
	p._eje(JOY_AXIS_TRIGGER_RIGHT, 0.15)      # crucero suave: el DSG sube a una marcha larga
	await p._frames(180)
	p._eje(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	await p._frames(2)
	var g1: int = caja.marcha
	p._tecla(KEY_G, true); await p._frames(2); p._tecla(KEY_G, false); await p._frames(2)
	p._ok(caja.manual and caja.marcha == g1 - 1, "tecla G → manual, %s (antes D%d, %d km/h, %d toques de bionda)" % [caja.texto_marcha(), g1, j.coche.v * 3.6, j.toques_bionda - toques0])
	p._tecla(KEY_T, true); await p._frames(2); p._tecla(KEY_T, false); await p._frames(2)
	p._ok(caja.manual and caja.marcha == g1, "tecla T → %s" % caja.texto_marcha())
	p._tecla(KEY_T, true); await p._frames(60); p._tecla(KEY_T, false); await p._frames(2)
	p._ok(not caja.manual, "tecla T mantenida 1 s → automático")
	# leva con el piloto puesto: lo desconecta; poner el piloto vuelve al automático
	j.piloto = true
	await p._pulsar(JOY_BUTTON_LEFT_SHOULDER)
	p._ok(not j.piloto and caja.manual, "L1 con el piloto → desconecta el piloto y pasa a manual")
	await p._pulsar(JOY_BUTTON_Y)
	await p._frames(2)
	p._ok(j.piloto and not caja.manual, "△ piloto → vuelve al automático")
	await p._pulsar(JOY_BUTTON_Y)
	j.piloto = false


## ---- joystick derecho: mirar alrededor (persecución = órbita; cabina = cabeza) ----
static func prueba_mirar(p) -> void:
	var j = p.j
	var cam_ant: int = Ajustes.camara
	Ajustes.camara = 0
	await p._parar()
	j.coche.v = 15.0
	await p._frames(60)
	var fw: Vector3 = j.coche.adelante()
	var detras: float = (j.cam.global_position - j.coche.position).normalized().dot(fw)
	p._ok(detras < -0.5, "persecución sin tocar: cámara detrás del coche (%.2f)" % detras)
	p._eje(JOY_AXIS_RIGHT_X, 0.1); await p._frames(30)
	p._ok(j.mando.mira == Vector2.ZERO, "joystick der. 0,10 (zona muerta) → no mira")
	p._eje(JOY_AXIS_RIGHT_X, 1.0); await p._frames(60)
	fw = j.coche.adelante()
	var rel: Vector3 = j.cam.global_position - j.coche.position
	var delante: float = rel.normalized().dot(fw)
	var dist := Vector2(rel.x, rel.z).length()
	var mira_f: Vector3 = -j.cam.global_transform.basis.z
	p._ok(delante > 0.5 and dist > 5.0 and mira_f.dot(fw) < -0.5, "joystick der. a la derecha 1 s → la cámara da la vuelta y mira el coche de frente (%.2f, %.1f m)" % [delante, dist])
	p._eje(JOY_AXIS_RIGHT_X, 0.5); await p._frames(60)
	p._ok(absf(rad_to_deg(j.mando.mira.x) + 165.0 * (0.5 - 0.15) / 0.85) < 3.0, "joystick der. a 0,5 → ángulo proporcional (%.0f°)" % rad_to_deg(j.mando.mira.x))
	p._eje(JOY_AXIS_RIGHT_X, 0.0); await p._frames(45)
	fw = j.coche.adelante()
	detras = (j.cam.global_position - j.coche.position).normalized().dot(fw)
	p._ok(absf(j.mando.mira.x) < 0.02 and detras < -0.5, "soltar → vuelve sola detrás en 0,75 s (%.2f)" % detras)
	p._eje(JOY_AXIS_RIGHT_Y, -1.0); await p._frames(60)
	var alto_arriba: float = j.cam.global_position.y
	p._eje(JOY_AXIS_RIGHT_Y, 1.0); await p._frames(60)
	var alto_abajo: float = j.cam.global_position.y
	p._ok(alto_abajo > alto_arriba + 1.0, "joystick der. ↑/↓ → la cámara baja/sube alrededor del coche (%.1f / %.1f m)" % [alto_arriba, alto_abajo])
	p._eje(JOY_AXIS_RIGHT_Y, 0.0)
	# cabina: girar la cabeza
	Ajustes.camara = 1
	await p._frames(30)
	p._eje(JOY_AXIS_RIGHT_X, -1.0); await p._frames(60)
	fw = j.coche.adelante()
	var izq := Vector3(fw.z, 0.0, -fw.x)
	var m: Vector3 = -j.cam.global_transform.basis.z
	var ang := rad_to_deg(atan2(m.dot(izq), m.dot(fw)))
	p._ok(ang > 95.0 and ang < 125.0, "cabina: joystick der. a la izquierda → mira %.0f° a la izquierda" % ang)
	p._eje(JOY_AXIS_RIGHT_X, 0.0); await p._frames(45)
	m = -j.cam.global_transform.basis.z
	fw = j.coche.adelante()
	p._ok(m.dot(fw) > 0.97, "cabina: soltar → vuelve a mirar al frente")
	Ajustes.camara = cam_ant
	await p._frames(5)


func _correr() -> void:
	j = load("res://escenas/juego.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	await _frames(10)
	print("PRUEBA_MANDO ruta=%d piloto=%s pad_id=%d mandos conectados=%s" % [Ajustes.ruta_idx, j.piloto, j.pad_id, Input.get_connected_joypads()])
	_ok(j.pad_id == -1 and not j.l_mando.visible, "sin mando: no hay aviso y se lee solo el teclado")
	# ---- teclado (debe ser exactamente igual que antes) ----
	_tecla(KEY_W, true); await _frames(3)
	_ok(j.coche.acelerador == 1.0 and j.coche.freno == 0.0, "teclado W → acelerador 1,0 (%.3f) freno 0" % j.coche.acelerador)
	_tecla(KEY_W, false); _tecla(KEY_UP, true); await _frames(3)
	_ok(j.coche.acelerador == 1.0, "teclado ↑ → acelerador 1,0")
	_tecla(KEY_UP, false); await _frames(2)
	j.coche.v = 20.0
	_tecla(KEY_S, true); await _frames(3)
	_ok(j.coche.freno == 1.0 and j.coche.acelerador == 0.0, "teclado S (en marcha) → freno 1,0")
	_tecla(KEY_S, false); _tecla(KEY_A, true); await _frames(2)
	_ok(j.coche.volante == -1.0, "teclado A → volante −1")
	_tecla(KEY_A, false); _tecla(KEY_RIGHT, true); await _frames(2)
	_ok(j.coche.volante == 1.0, "teclado → → volante +1")
	_tecla(KEY_RIGHT, false)
	j.coche.v = 20.0
	_tecla(KEY_SPACE, true); await _frames(2)
	_ok(j.coche.freno == 1.0, "teclado Espacio → freno 1,0")
	_tecla(KEY_SPACE, false); await _frames(2)
	await _parar()
	_tecla(KEY_S, true); await _frames(3)
	_ok(j.coche.marcha_atras and j.coche.acelerador == 1.0, "teclado S parado → marcha atrás")
	_tecla(KEY_S, false); await _frames(2)
	await _parar()
	_tecla(KEY_W, true)
	var t_tecl := await _cero_cien()
	_tecla(KEY_W, false)
	print("      0-100 con W en el tramo: %.2f s" % t_tecl)
	# ---- conexión del mando (lo que hace Godot al detectarlo el navegador) ----
	j._al_cambiar_mando(0, true)
	await _frames(2)
	_ok(j.pad_id == 0 and j.l_mando.visible and j.l_mando.text.begins_with("Mando conectado"), "aviso: \"%s\"" % j.l_mando.text)
	_ok(j.l_ayuda.text == j.AYUDA_MANDO, "la ayuda en pantalla pasa a los mandos del PS4")
	if Ajustes.args.has("captura_mando"):        # con pantalla (no headless): imagen del aviso y de la ayuda
		j.piloto = true
		for i in 8:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(Ajustes.args["captura_mando"])
		print("      captura: ", Ajustes.args["captura_mando"])
		j.piloto = false
	# ---- gatillos analógicos ----
	await _parar()
	j.piloto = true
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.02); await _frames(3)
	_ok(j.piloto, "R2 casi suelto (0,02, holgura) no desconecta el piloto")
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.5); await _frames(3)
	var esp := (0.5 - 0.03) / 0.97
	_ok(not j.piloto and absf(j.coche.acelerador - esp) < 1e-4, "R2 a 0,50 → desconecta el piloto y acelerador %.3f (esperado %.3f)" % [j.coche.acelerador, esp])
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.25); await _frames(2)
	_ok(absf(j.coche.acelerador - (0.25 - 0.03) / 0.97) < 1e-4, "R2 a 0,25 → acelerador %.3f (progresivo)" % j.coche.acelerador)
	_eje(JOY_AXIS_TRIGGER_RIGHT, 1.0); await _frames(2)
	_ok(j.coche.acelerador == 1.0, "R2 a fondo → acelerador 1,0")
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.0); await _frames(2)
	_ok(j.coche.acelerador == 0.0, "R2 suelto → acelerador 0")
	j.coche.v = 25.0
	_eje(JOY_AXIS_TRIGGER_LEFT, 0.3); await _frames(2)
	_ok(absf(j.coche.freno - (0.3 - 0.03) / 0.97) < 1e-4 and j.coche.acelerador == 0.0, "L2 a 0,30 en marcha → freno %.3f" % j.coche.freno)
	_eje(JOY_AXIS_TRIGGER_LEFT, 1.0); await _frames(2)
	_ok(j.coche.freno == 1.0, "L2 a fondo → freno 1,0")
	_eje(JOY_AXIS_TRIGGER_LEFT, 0.0)
	await _parar()
	_eje(JOY_AXIS_TRIGGER_LEFT, 0.6); await _frames(3)
	_ok(j.coche.marcha_atras and absf(j.coche.acelerador - (0.6 - 0.03) / 0.97) < 1e-4, "L2 parado → marcha atrás con gas %.3f" % j.coche.acelerador)
	_eje(JOY_AXIS_TRIGGER_LEFT, 0.0); await _frames(2)
	# mezcla: teclado W + R2 suave = el máximo
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.3); _tecla(KEY_W, true); await _frames(2)
	_ok(j.coche.acelerador == 1.0 and not j.coche.marcha_atras, "W + R2 a 0,3 a la vez → acelerador 1,0 (gana el que pide más)")
	_tecla(KEY_W, false); _eje(JOY_AXIS_TRIGGER_RIGHT, 0.0); await _frames(2)
	# 0-100 con R2 a fondo (igual que W) y a medias (más lento)
	await _parar()
	_eje(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	var t_r2 := await _cero_cien()
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	await _parar()
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.5)
	var t_r2m := await _cero_cien()
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	print("      0-100 en el tramo: W %.2f s · R2 a fondo %.2f s · R2 a 0,5 %.2f s" % [t_tecl, t_r2, t_r2m])
	_ok(absf(t_r2 - t_tecl) < 0.05, "R2 a fondo acelera igual que W")
	_ok(t_r2m > t_tecl + 1.0, "R2 a medias acelera menos que a fondo")
	# ---- joystick ----
	await _parar()
	j.coche.v = 15.0
	_eje(JOY_AXIS_LEFT_X, 0.05); await _frames(2)
	_ok(j.coche.volante == 0.0, "joystick 0,05 (zona muerta) → volante 0")
	_eje(JOY_AXIS_LEFT_X, 0.5); await _frames(2)
	var u := (0.5 - 0.08) / 0.92
	_ok(absf(j.coche.volante - (0.45 * u + 0.55 * u * u * u)) < 1e-4, "joystick 0,50 → volante %.3f (curva suave)" % j.coche.volante)
	_eje(JOY_AXIS_LEFT_X, -1.0); await _frames(2)
	_ok(j.coche.volante == -1.0, "joystick a tope a la izquierda → volante −1")
	_tecla(KEY_D, true); await _frames(2)
	_ok(j.coche.volante == 1.0, "con D pulsada manda el teclado → volante +1")
	_tecla(KEY_D, false); _eje(JOY_AXIS_LEFT_X, 0.0); await _frames(2)
	_ok(j.coche.volante == 0.0, "joystick suelto → volante 0")
	# ---- botones ----
	var p0: bool = j.piloto
	await _pulsar(JOY_BUTTON_Y)
	_ok(j.piloto != p0, "△ cambia el piloto automático (P)")
	if j.piloto: await _pulsar(JOY_BUTTON_Y)
	var v0: float = Ajustes.velocidad
	await _pulsar(JOY_BUTTON_DPAD_UP)
	_ok(Ajustes.velocidad == v0 + 5.0, "cruceta ↑ → velocidad elegida +5 (%d)" % roundi(Ajustes.velocidad))
	await _pulsar(JOY_BUTTON_DPAD_DOWN)
	_ok(Ajustes.velocidad == v0, "cruceta ↓ → velocidad elegida −5")
	var tr0: float = Ajustes.trafico
	await _pulsar(JOY_BUTTON_DPAD_RIGHT)
	_ok(absf(Ajustes.trafico - minf(tr0 + 0.1, 1.0)) < 1e-4, "cruceta → → tráfico +10 %")
	await _pulsar(JOY_BUTTON_DPAD_LEFT)
	var c0: int = Ajustes.camara
	await _pulsar(JOY_BUTTON_B)
	_ok(Ajustes.camara != c0, "○ cambia la cámara (V)")
	await _pulsar(JOY_BUTTON_B)
	var h0: bool = j.l_ayuda.visible
	await _pulsar(JOY_BUTTON_BACK)
	_ok(j.l_ayuda.visible != h0, "SHARE oculta/muestra la ayuda (H)")
	await _pulsar(JOY_BUTTON_BACK)
	await _pulsar(JOY_BUTTON_X)
	_ok(true, "□ pide adelantar (O) sin errores: \"%s\"" % j.adel_msg)
	j.coche.v = 20.0
	_boton(JOY_BUTTON_A, true); await _frames(3)
	_ok(j.coche.freno == 1.0 and not j.coche.marcha_atras, "✕ mantenido → freno de mano (freno 1,0)")
	_boton(JOY_BUTTON_A, false); await _frames(2)
	await _pulsar(JOY_BUTTON_START)
	_ok(j.pausado and j.panel_pausa.visible, "OPTIONS → pausa")
	await get_tree().process_frame
	await get_tree().process_frame
	_ok(get_viewport().gui_get_focus_owner() == j.b_continuar, "en la pausa el foco está en \"Continuar\" (cruceta + ✕)")
	var tr1: float = Ajustes.trafico
	await _pulsar(JOY_BUTTON_DPAD_RIGHT)
	_ok(Ajustes.trafico == tr1, "en la pausa la cruceta no toca el tráfico (mueve el foco)")
	await _pulsar(JOY_BUTTON_START)
	_ok(not j.pausado and get_viewport().gui_get_focus_owner() == null, "OPTIONS otra vez → sigue conduciendo, sin foco en botones")
	# ---- opciones del piloto (antes L1/R1): ahora en la pausa ----
	await _pulsar(JOY_BUTTON_START)
	var k0: bool = Ajustes.adaptar_curvas
	j.ck_curvas.button_pressed = not k0
	_ok(Ajustes.adaptar_curvas != k0 and j.ck_curvas.visible, "pausa: casilla \"frenar antes de las curvas\" (antes L1)")
	j.ck_curvas.button_pressed = k0
	var l0: bool = Ajustes.limite_adelantar
	j.ck_limite.button_pressed = not l0
	_ok(Ajustes.limite_adelantar != l0, "pausa: casilla \"respetar el límite al adelantar\" (antes R1)")
	j.ck_limite.button_pressed = l0
	await _pulsar(JOY_BUTTON_START)
	await prueba_levas(self)
	await prueba_mirar(self)
	# ---- gatillo que da −1 en reposo (mapeos no estándar) ----
	await _parar()
	_eje(JOY_AXIS_TRIGGER_RIGHT, -1.0); await _frames(2)
	_ok(j.coche.acelerador == 0.0, "gatillo de −1..1: suelto (−1) → acelerador 0")
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.0); await _frames(2)
	_ok(absf(j.coche.acelerador - (0.5 - 0.03) / 0.97) < 1e-4, "gatillo de −1..1: a medias (0) → acelerador %.3f" % j.coche.acelerador)
	_eje(JOY_AXIS_TRIGGER_RIGHT, -1.0); await _frames(2)
	# ---- desconexión ----
	j._al_cambiar_mando(0, false)
	await _frames(2)
	_ok(j.pad_id == -1 and j.l_mando.text == "Mando desconectado" and j.l_ayuda.text == j.AYUDA_TECLADO, "desconectar: aviso y la ayuda vuelve al teclado")
	print("PRUEBA_MANDO_FIN fallos=%d" % fallos)
	get_tree().quit(1 if fallos > 0 else 0)
