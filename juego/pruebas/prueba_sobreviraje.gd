## Prueba sin escena: mantener A/D (digital) SIN gas ni freno, en llano y en bajada/subida, y ver si la trasera se va.
##   godot --headless res://pruebas/prueba_sobreviraje.tscn
extends Node

class Plano extends Superficie:
	var pend := 0.0      # pendiente (subida + hacia -Z)
	func consultar(_x: float, z: float, _y: float) -> Vector3:
		return Vector3(-z * pend, 1.0, 0.0)

var sup: Plano

func _caso(f: Ficha, kmh: float, lado: float, t_mant: float, gas: String) -> Dictionary:
	var c := Coche.new(f)
	c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
	c.v = kmh / 3.6
	var dt := 1.0 / 60.0
	for i in 90:      # crucero 1,5 s para que el DSG elija marcha
		c.acelerador = clampf(c.fuerza_resistente(c.v) / maxf(c.fuerza_motor(c.v), 1.0), 0.0, 1.0)
		c.volante = 0.0
		c.paso_fisica(dt)
	c.v = kmh / 3.6
	var r0 := c.rumbo
	var t := 0.0
	var max_r := 0.0
	var max_b := 0.0
	var max_ar := 0.0
	var max_af := 0.0
	var max_alat := 0.0
	var esc_t := 0.0
	var min_along := 0.0
	var traza := []
	var acel_c := clampf(c.fuerza_resistente(c.v) / maxf(c.fuerza_motor(c.v), 1.0), 0.0, 1.0)
	while t < t_mant + 2.0:
		c.giro_directo = false
		if "entrada_digital" in c: c.set("entrada_digital", Ajustes.args.get("digital", "1") == "1")
		c.volante = lado if t < t_mant else 0.0
		c.acelerador = acel_c if gas == "crucero" else 0.0
		c.freno = 0.0
		c.paso_fisica(dt)
		t += dt
		var b := atan2(c.vy, maxf(absf(c.v), 0.1))
		# deriva más allá de la geométrica del giro (lr·r/u): lo que de verdad desliza la trasera
		b -= atan2(f.batalla * c.reparto() * c.r_yaw, maxf(absf(c.v), 0.1))
		max_r = maxf(max_r, absf(c.r_yaw))
		if absf(c.v) > 6.0: max_b = maxf(max_b, absf(b))
		max_ar = maxf(max_ar, absf(c.alfa_tra))
		max_af = maxf(max_af, absf(c.alfa_del))
		max_alat = maxf(max_alat, absf(c.a_lat_actual))
		min_along = minf(min_along, c.a_long)
		if c.esc_activo: esc_t += dt
		if Ajustes.args.has("traza") and int(round(t * 60)) % 6 == 0:
			traza.append("  t=%.1f v=%.0f giro=%.3f/%.3f r=%.2f β=%.1f° αf=%.1f° αr=%.1f° alat=%.1f along=%.1f esc=%s marcha=%d ret=%.0f" % [t, c.v*3.6, c.giro, c.g_max_vel, c.r_yaw, rad_to_deg(b), rad_to_deg(c.alfa_del), rad_to_deg(c.alfa_tra), c.a_lat_actual, c.a_long, c.esc_activo, c.caja.marcha, c.caja.retencion])
	var trompo := max_b > deg_to_rad(15.0)
	var sobre := max_ar > max_af + deg_to_rad(0.5)   # la trasera deriva más que la delantera = sobreviraje
	return {"txt": "%s | pend %+3.0f%% | %3.0f km/h | %s %.0f s | %-7s | r máx %.2f rad/s | β-geo máx %5.1f° | αf máx %4.1f° αr máx %4.1f° | a_lat máx %.1f | a_long mín %.1f | ESC %.2f s | v fin %3.0f | giro total %4.0f° | %s" % [
		f.id, sup.pend * 100.0, kmh, "D" if lado > 0 else "A", t_mant, gas, max_r, rad_to_deg(max_b), rad_to_deg(max_af), rad_to_deg(max_ar), max_alat, min_along, esc_t, c.v * 3.6, rad_to_deg(absf(c.rumbo - r0)),
		"TROMPO" if trompo else ("SOBREVIRA" if sobre else "ok")], "traza": traza, "trompo": trompo, "sobre": sobre}

func _ready() -> void:
	call_deferred("_correr")

func _correr() -> void:
	sup = Plano.new()
	Ajustes.superficie = sup
	var ids: Array = Ajustes.args.get("coches", "arteon_tdi150_dsg,arteon_r_320_4motion").split(",")
	var n_tr := 0
	var n_so := 0
	var n := 0
	for id in ids:
		var f: Ficha = null
		for fi: Ficha in Catalogo.fichas:
			if fi.id == id: f = fi
		if f == null:
			print("SV falta ", id); continue
		for p in Ajustes.args.get("pends","0,-0.07,0.07").split(","):
			sup.pend = float(p)
			for kmh in Array(Ajustes.args.get("vels","40,70,100").split(",")).map(func(x): return float(x)):
				for lado in Array(Ajustes.args.get("lados","-1,1").split(",")).map(func(x): return float(x)):
					for gas in Ajustes.args.get("gases","suelta,crucero").split(","):
						for tm in Array(Ajustes.args.get("tiempos","3").split(",")).map(func(x): return float(x)):
							var r := _caso(f, kmh, lado, tm, gas)
							print("SV ", r["txt"])
							for l in r["traza"]: print(l)
							n += 1
							if r["trompo"]: n_tr += 1
							if r["sobre"]: n_so += 1
	print("SV RESUMEN casos %d · trompos %d · sobreviraje %d" % [n, n_tr, n_so])
	get_tree().quit()
