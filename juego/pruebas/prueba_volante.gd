## Volante de la cabina: gira con la dirección (teclado, mando y piloto automático), en los tramos y en Madrid, sobre el
## eje de la columna, a la derecha en sentido horario visto desde el asiento y (v6) con el ángulo REAL que corresponde a las
## ruedas (dirección progresiva: 13,2:1 en el centro, 2,1 vueltas = ±378° de tope a tope); y los pilotos
## traseros se encienden más al frenar. Sin mando real ni teclado real: Input.parse_input_event.
##   godot --headless res://pruebas/prueba_volante.tscn -- --ruta=0 --trafico=0
##   godot --headless res://pruebas/prueba_volante.tscn -- --madrid=1 --trafico=0
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


func _tecla(k: Key, on: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.physical_keycode = k
	e.pressed = on
	Input.parse_input_event(e)


## ángulo del volante respecto a su posición recta (rad, + = antihorario visto desde el asiento) y cuánto se ha ido a la
## derecha del coche (m) el punto de arriba del aro
func _volante() -> Array:
	var m: Node3D = j.coche.modelo
	var piv: Node3D = m.get_meta("volante")
	var base: Transform3D = m.get_meta("volante_base")
	var ang: float = m.get_meta("volante_ang")
	# el nodo está de verdad girado ese ángulo sobre su eje Z (la columna)
	if not (base.basis * Basis(Vector3.BACK, ang)).is_equal_approx(piv.transform.basis):
		_ok(false, "el giro del nodo no coincide con el ángulo guardado")
	var cuerpo := piv.get_parent() as Node3D
	var arriba_ahora := cuerpo.transform * (piv.transform * Vector3(0, 0.18, 0))
	var arriba_recto := cuerpo.transform * (base * Vector3(0, 0.18, 0))
	return [ang, arriba_ahora.x - arriba_recto.x]


func _esperado() -> float:
	return -Coche.volante_de_ruedas(j.coche.giro)


func _correr() -> void:
	var madrid: bool = Ajustes.args.get("madrid", "0") == "1"
	j = load("res://escenas/madrid.tscn" if madrid else "res://escenas/juego.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	await _frames(30)
	print("PRUEBA_VOLANTE %s" % ("Madrid" if madrid else "tramo ruta=%d" % Ajustes.ruta_idx))
	var m: Node3D = j.coche.modelo
	_ok(m.has_meta("volante") and m.get_meta("volante") is Node3D, "el modelo del jugador trae el volante como pieza aparte")
	if not m.has_meta("volante"):
		print("FALLOS ", fallos); get_tree().quit(1); return
	var piv: Node3D = m.get_meta("volante")
	_ok(piv.get_parent().name == "carroceria", "el volante va dentro de la carrocería (se inclina con ella)")
	_ok(piv.get_child_count() == 1 and piv.get_child(0) is MeshInstance3D and (piv.get_child(0) as MeshInstance3D).mesh.get_surface_count() == 3, "malla del volante: aro, radios y centro (3 materiales)")
	# el eje de giro es la columna (Z local del pivote), inclinada unos 22° sobre la horizontal y hacia el conductor
	var eje := (piv.transform.basis.z).normalized()
	var incl := rad_to_deg(asin(eje.y))
	_ok(incl > 15.0 and incl < 30.0 and eje.z > 0.8, "eje de la columna: %.0f° sobre la horizontal, hacia el asiento" % incl)
	j.piloto = false
	await _frames(90)
	_ok(absf(_volante()[0]) < deg_to_rad(1.0), "recto al empezar (%.1f°)" % rad_to_deg(_volante()[0]))
	# ---- teclado: D (derecha) ----
	# parado: a 38 km/h, girando 1 s a la derecha, el coche llega a la bionda (quitamiedos) y el golpe cambia el giro
	j.coche.v = 0.0
	_eje(0, JOY_AXIS_TRIGGER_RIGHT, 0.0)
	_tecla(KEY_D, true); await _frames(60)
	var v: Array = _volante()
	_ok(j.coche.giro > 0.0 and v[0] < -deg_to_rad(5.0) and (v[1] > 0.02 or v[0] < -deg_to_rad(150.0)), "teclado D: ruedas %.1f° → volante %.0f° horario, arriba del aro %.0f cm a la derecha" % [rad_to_deg(j.coche.giro), -rad_to_deg(v[0]), v[1] * 100.0])
	_ok(absf(v[0] - _esperado()) < deg_to_rad(4.0), "teclado: volante %.0f° para %.1f° de ruedas (esperado %.0f°)" % [-rad_to_deg(v[0]), rad_to_deg(j.coche.giro), -rad_to_deg(_esperado())])
	_tecla(KEY_D, false); _tecla(KEY_A, true); await _frames(60)
	v = _volante()
	_ok(j.coche.giro < 0.0 and v[0] > deg_to_rad(5.0) and (v[1] < -0.02 or v[0] > deg_to_rad(150.0)), "teclado A: volante %.0f° antihorario" % rad_to_deg(v[0]))
	_tecla(KEY_A, false); await _frames(90)
	_ok(absf(_volante()[0]) < deg_to_rad(3.0), "teclado suelto: vuelve al centro (%.1f°)" % rad_to_deg(_volante()[0]))
	# ---- mando: joystick izquierdo, parado (todo el ángulo) ----
	j.coche.v = 0.0
	_eje(0, JOY_AXIS_LEFT_X, 1.0); await _frames(90)
	v = _volante()
	_ok(absf(j.coche.giro - Coche.GIRO_MAX) < 0.02 and absf(rad_to_deg(v[0]) + 378.0) < 4.0, "mando a tope a la derecha (parado): ruedas %.1f° → volante %.0f° (tope 378°)" % [rad_to_deg(j.coche.giro), -rad_to_deg(v[0])])
	_eje(0, JOY_AXIS_LEFT_X, -0.5); await _frames(90)
	v = _volante()
	_ok(v[0] > 0.0 and absf(v[0] - _esperado()) < deg_to_rad(4.0), "mando a la izquierda: volante %.0f° antihorario (esperado %.0f°)" % [rad_to_deg(v[0]), rad_to_deg(_esperado())])
	_eje(0, JOY_AXIS_LEFT_X, 0.0); await _frames(90)
	# ---- mando a fondo a 90 km/h: las ruedas giran pocos grados y el volante lo que les corresponde (v6: ángulo real) ----
	j.coche.v = 25.0
	_eje(0, JOY_AXIS_LEFT_X, 1.0); await _frames(30)
	v = _volante()
	_ok(-rad_to_deg(v[0]) > 15.0 and absf(v[0] - _esperado()) < deg_to_rad(4.0), "mando a tope a 90 km/h: ruedas %.1f° → volante %.0f° (esperado %.0f°)" % [rad_to_deg(j.coche.giro), -rad_to_deg(v[0]), -rad_to_deg(_esperado())])
	_eje(0, JOY_AXIS_LEFT_X, 0.5); await _frames(30)
	v = _volante()
	_ok(-rad_to_deg(v[0]) > 5.0 and absf(v[0] - _esperado()) < deg_to_rad(4.0), "mando a medias a 90 km/h: volante %.0f° (esperado %.0f°; el joystick tiene curva de respuesta)" % [-rad_to_deg(v[0]), -rad_to_deg(_esperado())])
	_eje(0, JOY_AXIS_LEFT_X, 0.0); j.coche.v = 0.0; await _frames(90)
	# ---- frenos: pilotos ----
	var luces: Array = m.get_meta("luces_freno")
	_ok(luces.size() >= 1, "pilotos traseros con material propio (%d)" % luces.size())
	j.coche.v = 15.0            # en marcha (parado, L2 es marcha atrás)
	_eje(0, JOY_AXIS_TRIGGER_LEFT, 0.8); await _frames(5)
	print("  freno %.2f" % j.coche.freno)
	_ok(luces.size() >= 1 and absf((luces[0][0] as BaseMaterial3D).emission_energy_multiplier - float(luces[0][2])) < 0.01, "L2: luces de freno encendidas")
	_eje(0, JOY_AXIS_TRIGGER_LEFT, 0.0); await _frames(5)
	print("  freno %.2f acelerador %.2f" % [j.coche.freno, j.coche.acelerador])
	_ok(luces.size() >= 1 and absf((luces[0][0] as BaseMaterial3D).emission_energy_multiplier - float(luces[0][1])) < 0.01, "sin freno: solo luces de posición")
	# ---- piloto automático: el volante sigue a la dirección que pide ----
	j.piloto = true
	var peor := 0.0
	var max_ang := 0.0
	for i in 600:
		await get_tree().physics_frame
		if i > 30:
			peor = maxf(peor, absf(_volante()[0] - _esperado()))
			max_ang = maxf(max_ang, absf(_volante()[0]))
	_ok(peor < deg_to_rad(12.0) and max_ang > deg_to_rad(2.0), "piloto 10 s: volante sigue a la dirección (desfase máx. %.1f°, giro máx. %.0f°)" % [rad_to_deg(peor), rad_to_deg(max_ang)])
	print("FALLOS ", fallos)
	get_tree().quit(1 if fallos > 0 else 0)
