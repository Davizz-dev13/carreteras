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
	var k0: bool = Ajustes.adaptar_curvas
	await _pulsar(JOY_BUTTON_LEFT_SHOULDER)
	_ok(Ajustes.adaptar_curvas != k0, "L1 adaptar en curvas (K)")
	await _pulsar(JOY_BUTTON_LEFT_SHOULDER)
	var l0: bool = Ajustes.limite_adelantar
	await _pulsar(JOY_BUTTON_RIGHT_SHOULDER)
	_ok(Ajustes.limite_adelantar != l0, "R1 límite al adelantar (L)")
	await _pulsar(JOY_BUTTON_RIGHT_SHOULDER)
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
