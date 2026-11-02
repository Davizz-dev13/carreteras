## Dos mandos a la vez (como en Windows con DS4Windows / Steam Input / un DualSense, que crean un mando virtual al lado
## del real, o un casco/volante que se apunta como mando): el nº 0 no hace nada y el jugador usa el nº 1.
## Comprueba que R2 acelera, el joystick izquierdo gira y L2 frena con el mando nº 1, en los tramos y en Madrid,
## y que un temblor pequeño del nº 0 no le quita el control. Sin mando real: Input.parse_input_event.
##   godot --headless res://pruebas/prueba_mando_dos.tscn -- --ruta=0 --piloto=0 --trafico=0 --km_ini=2 --km_fin=12
##   godot --headless res://pruebas/prueba_mando_dos.tscn -- --madrid=1 --piloto=0 --trafico=0
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


func _eje(dev: int, a: JoyAxis, v: float) -> void:
	var e := InputEventJoypadMotion.new()
	e.device = dev
	e.axis = a
	e.axis_value = v
	Input.parse_input_event(e)


func _boton(dev: int, b: JoyButton, on: bool) -> void:
	var e := InputEventJoypadButton.new()
	e.device = dev
	e.button_index = b
	e.pressed = on
	e.pressure = 1.0 if on else 0.0
	Input.parse_input_event(e)


static func _curva(x: float) -> float:
	var u := (absf(x) - 0.08) / 0.92
	return signf(x) * (0.45 * u + 0.55 * u * u * u)


func _correr() -> void:
	var madrid: bool = Ajustes.args.get("madrid", "0") == "1"
	j = load("res://escenas/madrid.tscn" if madrid else "res://escenas/juego.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	await _frames(30)
	print("PRUEBA_MANDO_DOS %s" % ("Madrid" if madrid else "tramo ruta=%d" % Ajustes.ruta_idx))
	j.piloto = false
	if not madrid:
		# Godot ve primero el mando nº 0 (el virtual / el que nadie toca): es la suposición inicial
		j._al_cambiar_mando(0, true)
		await _frames(2)
		_ok(j.pad_id == 0, "al empezar se lee el primero conectado (nº 0)")
	# el nº 0 manda algo de deriva (no es uso de verdad)
	_eje(0, JOY_AXIS_LEFT_X, 0.06); _eje(0, JOY_AXIS_LEFT_X, 0.0)
	await _frames(3)
	var v0: float = j.coche.v
	# ---- R2 en el mando nº 1 ----
	_eje(1, JOY_AXIS_TRIGGER_RIGHT, 0.8); await _frames(3)
	var esp := (0.8 - 0.03) / 0.97
	_ok(absf(j.coche.acelerador - esp) < 1e-4, "R2 del mando nº 1 a 0,8 → acelerador %.3f (esperado %.3f)" % [j.coche.acelerador, esp])
	_ok(Mando.pad_actual() == 1, "el mando en uso pasa a ser el nº 1 (%d)" % Mando.pad_actual())
	if not madrid:
		_ok(j.pad_id == 1 and j.l_mando.visible and j.l_mando.text == "Mando conectado (mando 1)", "aviso con el mando en uso: \"%s\"" % j.l_mando.text)
	await _frames(120)
	_ok(j.coche.v > v0 + 3.0, "acelera: %.1f → %.1f km/h en 2 s" % [v0 * 3.6, j.coche.v * 3.6])
	# temblor del nº 0 mientras se pisa R2 en el nº 1: no le quita el control
	_eje(0, JOY_AXIS_LEFT_Y, 0.12); _eje(0, JOY_AXIS_TRIGGER_RIGHT, 0.01); await _frames(3)
	_ok(Mando.pad_actual() == 1 and absf(j.coche.acelerador - esp) < 1e-4, "deriva del nº 0 no cambia de mando (acelerador %.3f)" % j.coche.acelerador)
	_eje(0, JOY_AXIS_LEFT_Y, 0.0); _eje(0, JOY_AXIS_TRIGGER_RIGHT, 0.0)
	# ---- joystick izquierdo del nº 1 ----
	_eje(1, JOY_AXIS_LEFT_X, 0.7); await _frames(3)
	_ok(absf(j.coche.volante - _curva(0.7)) < 1e-4, "joystick izq. del nº 1 a 0,7 → volante %.3f (esperado %.3f)" % [j.coche.volante, _curva(0.7)])
	var r0: float = j.coche.rumbo
	await _frames(60)
	var giro := absf(wrapf(j.coche.rumbo - r0, -PI, PI))
	_ok(giro > deg_to_rad(3.0), "gira: %.1f° en 1 s" % rad_to_deg(giro))
	_eje(1, JOY_AXIS_LEFT_X, -0.7); await _frames(3)
	_ok(absf(j.coche.volante + _curva(0.7)) < 1e-4, "joystick izq. del nº 1 a −0,7 → volante %.3f" % j.coche.volante)
	_eje(1, JOY_AXIS_LEFT_X, 0.0); await _frames(3)
	_ok(j.coche.volante == 0.0 or absf(j.coche.volante) < 1e-4, "joystick suelto → volante 0")
	_eje(1, JOY_AXIS_TRIGGER_RIGHT, 0.0); await _frames(3)
	_ok(j.coche.acelerador == 0.0, "R2 suelto → acelerador 0")
	# ---- L2 del nº 1 ----
	var v1: float = j.coche.v
	_eje(1, JOY_AXIS_TRIGGER_LEFT, 0.6); await _frames(3)
	var espf := (0.6 - 0.03) / 0.97
	_ok(absf(j.coche.freno - espf) < 1e-4 and j.coche.acelerador == 0.0, "L2 del nº 1 a 0,6 → freno %.3f (esperado %.3f)" % [j.coche.freno, espf])
	await _frames(60)
	_ok(j.coche.v < v1 - 2.0, "frena: %.1f → %.1f km/h en 1 s" % [v1 * 3.6, j.coche.v * 3.6])
	_eje(1, JOY_AXIS_TRIGGER_LEFT, 0.0); await _frames(3)
	# ---- vuelve al nº 0 si es el que se toca de verdad ----
	_eje(0, JOY_AXIS_TRIGGER_RIGHT, 0.9); await _frames(3)
	_ok(Mando.pad_actual() == 0 and absf(j.coche.acelerador - (0.9 - 0.03) / 0.97) < 1e-4, "R2 de verdad en el nº 0 → se lee el nº 0 (acelerador %.3f)" % j.coche.acelerador)
	_eje(0, JOY_AXIS_TRIGGER_RIGHT, 0.0); await _frames(3)
	# un botón del nº 1 también lo hace el mando en uso
	_boton(1, JOY_BUTTON_DPAD_UP, true); await _frames(2); _boton(1, JOY_BUTTON_DPAD_UP, false); await _frames(2)
	_ok(Mando.pad_actual() == 1, "pulsar un botón del nº 1 → mando en uso nº 1")
	if madrid and j.mapa != null:
		# mapa grande: el joystick del nº 1 lo mueve
		j.mapa.abrir(true); await _frames(5)
		var c0: Vector2 = j.mapa.centro
		_eje(1, JOY_AXIS_LEFT_X, 0.9); await _frames(20)
		_eje(1, JOY_AXIS_LEFT_X, 0.0); await _frames(2)
		_ok(j.mapa.centro.x > c0.x + 1.0, "mapa grande: joystick izq. del nº 1 lo mueve (%.0f m)" % (j.mapa.centro.x - c0.x))
		j.mapa.abrir(false); await _frames(5)
	if not madrid:
		j._al_cambiar_mando(1, false); await _frames(2)
		_ok(j.pad_id == -1 and j.l_mando.text == "Mando desconectado", "desconectar el nº 1 → \"%s\"" % j.l_mando.text)
	print("PRUEBA_MANDO_DOS_FIN fallos=%d" % fallos)
	get_tree().quit(1 if fallos > 0 else 0)
