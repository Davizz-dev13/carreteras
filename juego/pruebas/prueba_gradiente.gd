## Prueba sin escena: gradiente de subviraje y aceleración lateral máxima en estado casi estacionario (rampa lenta de
## dirección a velocidad constante, en llano). Mide K = (δ - L·r/u) / a_lat y qué eje llega antes al límite.
##   godot --headless res://pruebas/prueba_gradiente.tscn
extends Node

class Plano extends Superficie:
	func consultar(_x: float, _z: float, _y: float) -> Vector3:
		return Vector3(0.0, 1.0, 0.0)

func _ready() -> void:
	call_deferred("_correr")

func _caso(f: Ficha, kmh: float) -> String:
	var c := Coche.new(f)
	c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
	var v0 := kmh / 3.6
	c.v = v0
	var dt := 1.0 / 60.0
	var lb := f.batalla
	var lf := lb * (1.0 - c.reparto())
	var t := 0.0
	var T := 30.0
	var d_fin := 0.16 if kmh < 60.0 else 0.10
	var ks := {}       # a_lat redondeada → K
	var a_max := 0.0
	var lim := ""
	while t < T:
		c.giro_directo = true
		c.volante = d_fin * t / T
		var crucero := clampf(c.fuerza_resistente(c.v) / maxf(c.fuerza_motor(c.v), 1.0), 0.0, 1.0)
		c.acelerador = clampf(crucero + 0.8 * (v0 - c.v), 0.0, 1.0)
		c.freno = 0.0
		c.paso_fisica(dt)
		t += dt
		var u := maxf(c.v, 1.0)
		var delta := c.alfa_del + atan2(c.vy + lf * c.r_yaw, u)
		var al := u * c.r_yaw
		if al > a_max + 0.01:
			a_max = al
		for obj in [2.0, 4.0, 6.0, 8.0]:
			if not ks.has(obj) and al >= obj:
				ks[obj] = (delta - lb * c.r_yaw / u) / al
		if lim == "" and (absf(c.alfa_del) > deg_to_rad(9.0) or absf(c.alfa_tra) > deg_to_rad(6.5)):
			lim = "a_lat %.1f: αf %.1f° αr %.1f° (%s)" % [al, rad_to_deg(c.alfa_del), rad_to_deg(c.alfa_tra), "sube αf → SUBVIRA" if rad_to_deg(c.alfa_del) / 11.2 > rad_to_deg(c.alfa_tra) / 7.3 else "sube αr → SOBREVIRA"]
	var txt := ""
	for obj in [2.0, 4.0, 6.0, 8.0]:
		txt += " K@%.0f=%s" % [obj, ("%.2f°/g" % rad_to_deg(ks[obj] * 9.81)) if ks.has(obj) else "—"]
	return "%s | %3.0f km/h |%s | a_lat máx %.2f m/s² (%.2f g) | límite: %s" % [f.id, kmh, txt, a_max, a_max / 9.81, lim if lim != "" else "no llega"]

## Teclado: tecla de giro mantenida a velocidad constante → radio de giro estable (las horquillas del puerto: R 12-25 m)
func _radio_teclado(f: Ficha, kmh: float) -> String:
	var c := Coche.new(f)
	c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
	var v0 := kmh / 3.6
	c.v = v0
	var dt := 1.0 / 60.0
	var t := 0.0
	var r_acc := 0.0
	var n := 0
	var bmax := 0.0
	while t < 8.0:
		c.giro_directo = false
		if "entrada_digital" in c: c.set("entrada_digital", true)
		c.volante = 1.0
		var crucero := clampf(c.fuerza_resistente(c.v) / maxf(c.fuerza_motor(c.v), 1.0), 0.0, 1.0)
		c.acelerador = clampf(crucero + 0.8 * (v0 - c.v), 0.0, 1.0)
		c.freno = 0.0
		c.paso_fisica(dt)
		t += dt
		if t > 5.0:
			r_acc += c.v / maxf(absf(c.r_yaw), 0.001); n += 1
		bmax = maxf(bmax, absf(c.alfa_tra))
	return "%s | teclado %2.0f km/h | radio estable %.1f m | a_lat %.2f g | v %2.0f km/h | αr máx %.1f° | αf %.1f°" % [f.id, kmh, r_acc / n, c.v * absf(c.r_yaw) / 9.81, c.v * 3.6, rad_to_deg(bmax), rad_to_deg(absf(c.alfa_del))]

func _correr() -> void:
	Ajustes.superficie = Plano.new()
	for id in ["arteon_tdi150_dsg", "arteon_r_320_4motion"]:
		var f: Ficha = null
		for fi: Ficha in Catalogo.fichas:
			if fi.id == id: f = fi
		for kmh in [50.0, 80.0, 110.0]:
			print("GR ", _caso(f, kmh))
		for kmh in [25.0, 30.0, 40.0, 50.0, 60.0]:
			print("GR ", _radio_teclado(f, kmh))
	get_tree().quit()
