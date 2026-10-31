## Prueba sin escena: frenar a fondo girando con teclado (entrada instantánea) y soltar / contravolantear.
##   godot --headless res://pruebas/prueba_frenar_girar.tscn
extends Node

class Plano extends Superficie:
	func consultar(_x: float, _z: float, _y: float) -> Vector3:
		return Vector3(0.0, 1.0, 0.0)

func _ready() -> void:
	call_deferred("_correr")

func _caso(f: Ficha, kmh: float, t_fren: float, despues: String, previo: float) -> String:
	var c := Coche.new(f)
	c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
	c.v = kmh / 3.6
	c.caja.marcha = 4
	var dt := 1.0 / 60.0
	# crucero 1 s para que el cambio se coloque
	for i in 60:
		c.acelerador = clampf(c.fuerza_resistente(c.v) / maxf(c.fuerza_motor(c.v), 1.0), 0.0, 1.0)
		c.paso_fisica(dt)
	c.v = kmh / 3.6
	var r0 := c.rumbo
	var t := 0.0
	var max_r := 0.0
	var max_b := 0.0
	var max_giro := 0.0
	var esc_t := 0.0
	var t_suelta := previo + t_fren
	var t_rec := -1.0
	var x0 := c.odometro
	var v_fin_fren := 0.0
	while t < t_suelta + 6.0:
		c.acelerador = 0.0
		if t < previo:
			c.volante = 1.0
			c.freno = 0.0
			c.acelerador = clampf(c.fuerza_resistente(c.v) / maxf(c.fuerza_motor(c.v), 1.0), 0.0, 1.0)
		elif t < t_suelta:
			c.volante = 1.0
			c.freno = 1.0
		else:
			c.freno = 0.0
			if despues == "contra" and t < t_suelta + 0.4: c.volante = -1.0
			elif despues == "sigue_frenando": c.volante = 0.0; c.freno = 1.0
			else: c.volante = 0.0
		c.giro_directo = false
		c.paso_fisica(dt)
		t += dt
		if absf(t - t_suelta) < dt * 0.5: v_fin_fren = c.v
		var b := atan2(c.vy, maxf(absf(c.v), 0.1))
		max_r = maxf(max_r, absf(c.r_yaw))
		if absf(c.v) > 8.0: max_b = maxf(max_b, absf(b))   # por debajo de ~30 km/h la deriva es la geométrica del giro cinemático
		max_giro = maxf(max_giro, absf(c.rumbo - r0))
		if c.esc_activo: esc_t += dt
		if t >= t_suelta and t_rec < 0.0:
			if (absf(b) < deg_to_rad(2.0) and absf(c.r_yaw) < 0.05) or absf(c.v) < 0.5:
				t_rec = t - t_suelta
	var trompo := max_b > deg_to_rad(30.0)
	return "%s | %3.0f | %.1f+%.1f s | %-14s | r máx %.2f rad/s | β máx %5.1f° | giro total %5.1f° | %s | recupera %s | ESC %.2f s | v al soltar %3.0f km/h | rumbo final %5.1f°" % [
		f.id, kmh, previo, t_fren, despues, max_r, rad_to_deg(max_b), rad_to_deg(max_giro),
		"TROMPO" if trompo else "ok    ", ("%.2f s" % t_rec) if t_rec >= 0.0 else "NUNCA", esc_t, v_fin_fren * 3.6, rad_to_deg(c.rumbo - r0)]

func _correr() -> void:
	Ajustes.superficie = Plano.new()
	for id in ["arteon_tdi150_dsg", "arteon_r_320_4motion"]:
		var f: Ficha = null
		for fi: Ficha in Catalogo.fichas:
			if fi.id == id: f = fi
		for kmh in [50.0, 80.0, 100.0, 130.0]:
			for tf in [0.5, 1.0, 2.0]:
				for d in ["suelta", "contra"]:
					print("FG ", _caso(f, kmh, tf, d, 0.0))
			print("FG ", _caso(f, kmh, 1.5, "suelta", 1.5))   # en curva y luego frena girando
			print("FG ", _caso(f, kmh, 1.0, "sigue_frenando", 0.0))
	get_tree().quit()
