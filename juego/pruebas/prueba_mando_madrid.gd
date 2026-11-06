## Prueba del mando en el mapa abierto de Madrid (sin mando real: Input.parse_input_event).
##   godot --headless res://pruebas/prueba_mando_madrid.tscn -- --piloto=0 --trafico=0
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


func _tecla(k: Key, on: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = k
	e.keycode = k
	e.pressed = on
	Input.parse_input_event(e)


func _correr() -> void:
	j = load("res://escenas/madrid.tscn").instantiate()
	add_child(j)
	if not ("cargado" in j):
		print("PRUEBA_MANDO_MADRID_FIN fallos=1 (no carga ma_juego.gd)")
		get_tree().quit(1)
		return
	while not j.cargado:
		await get_tree().process_frame
	await _frames(30)
	var caja: Transmision = j.coche.caja
	print("PRUEBA_MANDO_MADRID piloto=%s" % j.piloto)
	# piloto puesto: un gatillo casi suelto no lo quita; R2 de verdad sí
	j.piloto = true
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.02); await _frames(3)
	_ok(j.piloto, "R2 casi suelto (0,02) no desconecta el piloto")
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.5); await _frames(3)
	_ok(not j.piloto and absf(j.coche.acelerador - (0.5 - 0.03) / 0.97) < 1e-4, "R2 a 0,50 → desconecta el piloto, acelerador %.3f" % j.coche.acelerador)
	_eje(JOY_AXIS_TRIGGER_RIGHT, 1.0); await _frames(2)
	_ok(j.coche.acelerador == 1.0, "R2 a fondo → acelerador 1,0")
	var t := 0.0
	while j.coche.v < 50.0 / 3.6 and t < 20.0:
		await _frames(1)
		t += 1.0 / Engine.physics_ticks_per_second
	_eje(JOY_AXIS_TRIGGER_RIGHT, 0.0); await _frames(2)
	_ok(j.coche.v > 45.0 / 3.6, "R2 a fondo: 0-50 en %.1f s" % t)
	_eje(JOY_AXIS_TRIGGER_LEFT, 0.4); await _frames(2)
	_ok(absf(j.coche.freno - (0.4 - 0.03) / 0.97) < 1e-4 and j.coche.acelerador == 0.0, "L2 a 0,40 en marcha → freno %.3f" % j.coche.freno)
	_eje(JOY_AXIS_TRIGGER_LEFT, 0.0); await _frames(2)
	_eje(JOY_AXIS_LEFT_X, 0.05); await _frames(2)
	_ok(j.coche.volante == 0.0, "joystick izq. 0,05 (zona muerta) → volante 0")
	_eje(JOY_AXIS_LEFT_X, 0.5); await _frames(2)
	var u := (0.5 - 0.08) / 0.92
	_ok(absf(j.coche.volante - (0.45 * u + 0.55 * u * u * u)) < 1e-4, "joystick izq. 0,50 → volante %.3f (misma curva que en los tramos)" % j.coche.volante)
	_eje(JOY_AXIS_LEFT_X, 0.0); await _frames(2)
	_ok(j.coche.volante == 0.0, "joystick izq. suelto → volante 0")
	# levas
	var g0: int = caja.marcha
	await _pulsar(JOY_BUTTON_RIGHT_SHOULDER)
	_ok(caja.manual and (caja.marcha == g0 + 1 or caja.rechazo_t > 0.0), "R1 → manual: %s (antes D%d)" % [caja.texto_marcha(), g0])
	await _frames(5)
	_ok(j.l_marcha.text.begins_with(caja.texto_marcha()), "HUD de Madrid: \"%s\"" % j.l_marcha.text)
	var g1: int = caja.marcha
	await _pulsar(JOY_BUTTON_LEFT_SHOULDER)
	_ok(caja.marcha == g1 - 1, "L1 → %s" % caja.texto_marcha())
	_tecla(KEY_T, true); await _frames(2); _tecla(KEY_T, false); await _frames(2)
	_ok(caja.marcha == g1, "tecla T → %s" % caja.texto_marcha())
	_boton(JOY_BUTTON_RIGHT_SHOULDER, true); await _frames(60); _boton(JOY_BUTTON_RIGHT_SHOULDER, false); await _frames(3)
	_ok(not caja.manual, "R1 mantenido 1 s → automático (%s)" % caja.texto_marcha())
	# frenar hasta parar en manual → M1, y L2 parado = marcha atrás
	await _pulsar(JOY_BUTTON_LEFT_SHOULDER)
	_eje(JOY_AXIS_TRIGGER_LEFT, 0.7)
	t = 0.0
	while absf(j.coche.v) > 0.05 and t < 20.0:
		await _frames(1)
		t += 1.0 / Engine.physics_ticks_per_second
	await _frames(20)
	_ok(j.coche.marcha_atras or caja.marcha == 1, "frenando hasta parar en manual → M1 / marcha atrás con L2 (%s)" % caja.texto_marcha())
	_eje(JOY_AXIS_TRIGGER_LEFT, 0.0); await _frames(5)
	# botones
	await _pulsar(JOY_BUTTON_Y)
	_ok(j.piloto and not caja.manual, "△ → piloto (y automático)")
	await _pulsar(JOY_BUTTON_Y)
	_ok(not j.piloto, "△ otra vez → sin piloto")
	var c0: int = Ajustes.camara
	await _pulsar(JOY_BUTTON_B)
	_ok(Ajustes.camara != c0, "○ cambia la cámara")
	await _pulsar(JOY_BUTTON_B)
	await _pulsar(JOY_BUTTON_DPAD_RIGHT)
	_ok(j.preferencia == 1, "cruceta → → próximo cruce a la derecha")
	await _pulsar(JOY_BUTTON_DPAD_RIGHT)
	_ok(j.preferencia == 0, "cruceta → otra vez → seguir")
	var v0: float = Ajustes.velocidad
	await _pulsar(JOY_BUTTON_DPAD_UP)
	_ok(Ajustes.velocidad == minf(v0 + 10.0, 200.0), "cruceta ↑ → velocidad del piloto +10")
	await _pulsar(JOY_BUTTON_DPAD_DOWN)
	await _pulsar(JOY_BUTTON_BACK)
	_ok(j.ver_datos, "SHARE → datos (F3)")
	await _pulsar(JOY_BUTTON_BACK)
	await _pulsar(JOY_BUTTON_START)
	await get_tree().process_frame
	_ok(j.pausado and j.pausa.panel.visible and is_instance_valid(j) and j.is_inside_tree(), "OPTIONS → menú de pausa (no sale al menú principal)")
	await _pulsar(JOY_BUTTON_START)
	await get_tree().process_frame
	_ok(not j.pausado and not j.pausa.panel.visible, "OPTIONS otra vez → sigue conduciendo")
	# joystick derecho
	Ajustes.camara = 0
	j.coche.v = 12.0
	await _frames(60)
	_eje(JOY_AXIS_RIGHT_X, 1.0); await _frames(60)
	var fw: Vector3 = j.coche.adelante()
	var delante: float = (j.cam.global_position - j.coche.position).normalized().dot(fw)
	_ok(delante > 0.5, "joystick der. a la derecha → la cámara orbita hasta delante del coche (%.2f)" % delante)
	_eje(JOY_AXIS_RIGHT_X, 0.0); await _frames(45)
	fw = j.coche.adelante()
	var detras: float = (j.cam.global_position - j.coche.position).normalized().dot(fw)
	_ok(detras < -0.5, "soltar → vuelve detrás (%.2f)" % detras)
	Ajustes.camara = 1
	_eje(JOY_AXIS_RIGHT_X, 1.0); await _frames(60)
	fw = j.coche.adelante()
	var m: Vector3 = -j.cam.global_transform.basis.z
	var der := Vector3(-fw.z, 0.0, fw.x)
	var ang := rad_to_deg(atan2(m.dot(der), m.dot(fw)))
	_ok(ang > 95.0 and ang < 125.0, "cabina: joystick der. a la derecha → mira %.0f° a la derecha" % ang)
	_eje(JOY_AXIS_RIGHT_X, 0.0); await _frames(45)
	Ajustes.camara = 0
	print("PRUEBA_MANDO_MADRID_FIN fallos=%d" % fallos)
	get_tree().quit(1 if fallos > 0 else 0)
