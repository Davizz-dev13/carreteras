## Un "jugador de teclado" baja/sube el puerto entero con las teclas (todo o nada), como David: A/D a toques para
## seguir el carril (persecución pura) y W/S para la velocidad de cada curva; en las curvas suele ir SIN gas (inercia).
## Mide trompos, deriva de la trasera, segundos fuera del asfalto, toques de bionda y tiempo.
##   godot --headless --fixed-fps 60 res://pruebas/prueba_teclado_puerto.tscn -- --ruta=0 --km_ini=0 --km_fin=24.3 --trafico=0 --vel=90
extends Node

var j

func _tecla(k: Key, on: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = k
	e.keycode = k
	e.pressed = on
	Input.parse_input_event(e)

func _ready() -> void:
	call_deferred("_correr")

func _correr() -> void:
	j = load("res://escenas/juego.tscn").instantiate()
	add_child(j)
	for i in 30: await get_tree().physics_frame
	j.piloto = false
	var dt := 1.0 / 60.0
	var t := 0.0
	var fuera := 0.0
	var bmax := 0.0
	var trompos := 0
	var en_trompo := false
	var s_max_b := 0.0
	var pulsado_d := false
	var pulsado_a := false
	var t_sin_gas_girando := 0.0
	var lr: float = j.coche.ficha.batalla * j.coche.reparto()
	var margen := float(Ajustes.args.get("margen_vel", "0"))
	while not j.terminado and t < 2400.0:
		var dd: float = j._volante_piloto()
		var g: float = j.coche.giro
		var d := dd > g + 0.004
		var a := dd < g - 0.004
		if d != pulsado_d: _tecla(KEY_D, d); pulsado_d = d
		if a != pulsado_a: _tecla(KEY_A, a); pulsado_a = a
		var vt: float = j._velocidad_objetivo() + margen / 3.6
		var w: bool = j.coche.v < vt - 0.5
		var s: bool = j.coche.v > vt + 3.0
		_tecla(KEY_W, w)
		_tecla(KEY_S, s)
		if not w and not s and (d or a): t_sin_gas_girando += dt
		await get_tree().physics_frame
		t += dt
		var c: Coche = j.coche
		if not c.en_carretera: fuera += dt
		if absf(c.v) > 6.0:
			var b := absf(atan2(c.vy, absf(c.v)) - atan2(lr * c.r_yaw, absf(c.v)))
			if b > bmax: bmax = b; s_max_b = j.s_coche
			if b > deg_to_rad(20.0) and not en_trompo: trompos += 1
			en_trompo = b > deg_to_rad(20.0)
	for k in [KEY_A, KEY_D, KEY_W, KEY_S]: _tecla(k, false)
	print("TECLADO_PUERTO km %.1f→%.1f | terminado %s | tiempo %.0f s | trompos %d | deriva trasera máx %.1f° (km %.2f) | fuera del asfalto %.1f s | toques de bionda %d | choques %d | %.0f s sin gas girando | v máx %.0f km/h" % [
		j.s_ini / 1000.0, j.s_fin / 1000.0, j.terminado, t, trompos, rad_to_deg(bmax), s_max_b / 1000.0, fuera, j.toques_bionda, j.choques, t_sin_gas_girando, j.v_max * 3.6])
	get_tree().quit()
