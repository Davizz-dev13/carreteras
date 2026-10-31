## Pruebas del cambio, el consumo y la física longitudinal (v4), en llano y sin escena:
##   godot --headless res://pruebas/prueba_v4.tscn
## Usa el coche del juego (coche.gd: paso_fisica) sobre una superficie plana.
extends Node

class Plano extends Superficie:
	func consultar(_x: float, _z: float, _y: float) -> Vector3:
		return Vector3(0.0, 1.0, 0.0)


func _ready() -> void:
	call_deferred("_correr")


func _coche(f: Ficha) -> Coche:
	var c := Coche.new(f)
	c.position = Vector3.ZERO
	c.rumbo = 0.0
	return c


func _correr() -> void:
	var cat = Catalogo
	Ajustes.superficie = Plano.new()
	var dt := 1.0 / 60.0
	print("PRUEBA_V4 versión | 0-100 antes (envolvente) | 0-100 v4 (coche.gd con DSG) | oficial | F trac antes→v4 | cambios en el 0-100 | 100→0 m | inercia 100→50 D s | N s")
	for fi: Ficha in cat.fichas:
		var t0 := Time.get_ticks_msec()
		var c := _coche(fi)
		var t_cal := Time.get_ticks_msec() - t0
		# 0-100 a fondo
		c.acelerador = 1.0
		var t := 0.0
		var log := ""
		var m_ant := 1
		while c.v < 100.0 / 3.6 and t < 60.0:
			c.paso_fisica(dt)
			t += dt
			if c.caja.marcha != m_ant:
				log += " %d@%.0fkm/h/%.1fs" % [c.caja.marcha, c.v * 3.6, t]
				m_ant = c.caja.marcha
		# 100→0 frenando a fondo
		c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
		c.v = 100.0 / 3.6
		c.acelerador = 0.0
		c.freno = 1.0
		var x0 := c.odometro
		var n := 0
		while c.v > 0.01 and n < 2000:
			c.paso_fisica(dt)
			n += 1
		var d_freno := c.odometro - x0
		# inercia: 100→50 sin tocar pedales (D: freno motor con corte de inyección; N: punto muerto)
		var inercia := []
		for neutro in [false, true]:
			c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
			c.caja.neutro = neutro
			c.freno = 0.0
			c.acelerador = 0.0
			c.v = 100.0 / 3.6
			c.caja.marcha = 7
			var tt := 0.0
			while c.v > 50.0 / 3.6 and tt < 300.0:
				c.paso_fisica(dt)
				tt += dt
			inercia.append(tt)
			c.caja.neutro = false
		print("PRUEBA_V4 %s | %.2f | %.2f | %.1f | %.0f→%.0f N | %s | %.1f | %.1f | %.1f   (calibración %d ms)" % [fi.id, fi.t_0_100_sim, t, fi.t_0_100,
			fi.f_traccion_max, c.caja.f_trac, log, d_freno, inercia[0], inercia[1], t_cal])
	print("")
	print("CRUCERO versión | km/h: marcha rpm l/100 (llano, velocidad constante)")
	for fi: Ficha in cat.fichas:
		var c := _coche(fi)
		var fila: String = fi.id + " |"
		for kmh in [30.0, 50.0, 70.0, 90.0, 120.0, 140.0]:
			c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
			c.v = kmh / 3.6
			c.caja.marcha = 1
			c.consumo.reiniciar()
			var lit0 := 0.0
			for i in 1500:
				var v := c.v
				var f: float = c.fuerza_resistente(v) + fi.masa * (kmh / 3.6 - v) * 2.0
				c.acelerador = clampf(f / c.fuerza_motor(v), 0.0, 1.0)
				c.freno = 0.0
				if i == 900:
					c.consumo.reiniciar()
				c.paso_fisica(dt)
			fila += " %d: %s %d %.1f |" % [kmh, c.caja.texto_marcha(), roundi(c.caja.rpm), c.consumo.media()]
		print("CRUCERO " + fila)
	print("")
	print("SKIDPAD versión | a 60 km/h constantes, volante subiendo despacio: aceleración lateral máx. sostenida (g) | ángulo de rueda en el máx. (°) | a 100 km/h (g) | guiñada: tiempo al 90 % tras un golpe de volante a 80 km/h (s)")
	for fi: Ficha in cat.fichas:
		var fila: String = fi.id + " |"
		for kmh in [60.0, 100.0]:
			var c := _coche(fi)
			c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
			c.v = kmh / 3.6
			c.giro_directo = true
			var amax := 0.0
			var dmax := 0.0
			var tt := 0.0
			while tt < 40.0:
				c.volante = minf(0.0015 + tt * 0.004, Coche.GIRO_MAX)
				var v: float = c.v
				var f: float = c.fuerza_resistente(v) + fi.masa * (kmh / 3.6 - v) * 1.5 + c.ficha.masa * c.vy * c.r_yaw * -1.0
				c.acelerador = clampf(f / c.fuerza_motor(v), 0.0, 1.0)
				c.freno = 0.0
				c.paso_fisica(dt)
				tt += dt
				# lateral sostenida: con la velocidad dentro de ±3 km/h del objetivo
				if absf(c.v * 3.6 - kmh) < 3.0 and c.a_lat_actual > amax:
					amax = c.a_lat_actual
					dmax = rad_to_deg(c.giro)
			fila += " %.0f: %.3f g (rueda %.1f°) |" % [kmh, amax / 9.81, dmax]
		# respuesta de guiñada a 80 km/h
		var c2 := _coche(fi)
		c2.colocar(Vector3.ZERO, Vector3(0, 0, -1))
		c2.v = 80.0 / 3.6
		c2.giro_directo = true
		c2.volante = 0.03
		c2.giro = 0.03
		var t90 := -1.0
		var r_fin := 0.0
		var rs := []
		for i in 240:
			c2.acelerador = clampf(c2.fuerza_resistente(c2.v) / c2.fuerza_motor(c2.v), 0.0, 1.0)
			c2.paso_fisica(dt)
			rs.append(c2.r_yaw)
		r_fin = rs[rs.size() - 1]
		for i in rs.size():
			if absf(rs[i]) >= 0.9 * absf(r_fin):
				t90 = i * dt
				break
		fila += " guiñada 90 %% en %.2f s (r final %.3f rad/s, cinemática %.3f)" % [t90, r_fin, c2.v * tan(0.03) / fi.batalla]
		print("SKIDPAD " + fila)
	print("")
	print("VMAX versión | velocidad máxima en llano a fondo (km/h) tras 150 s | oficial | marcha")
	for fi: Ficha in cat.fichas:
		var c := _coche(fi)
		c.acelerador = 1.0
		var vmax := 0.0
		for i in 9000:
			c.paso_fisica(dt)
			vmax = maxf(vmax, c.v)
		print("VMAX %s | %.1f | %.0f | %s %d rpm" % [fi.id, vmax * 3.6, fi.v_max_kmh, c.caja.texto_marcha(), roundi(c.caja.rpm)])
	print("")
	print("CALIBRACION versión | Spritmonitor objetivo | k l/kWh | g/kWh equiv. | WLTC sim. con k (coche.gd en bucle cerrado) | WLTP/NEDC ref | km ciclo")
	var wl = JSON.parse_string(FileAccess.get_file_as_string("res://datos/coches/wltc_3b.json"))["kmh"]
	var sup = JSON.parse_string(FileAccess.get_file_as_string("res://datos/coches/motor_supuestos.json"))
	for fi: Ficha in cat.fichas:
		var c := _coche(fi)
		var dens := float(sup["versiones"][fi.id]["densidad_combustible_kg_l"]["valor"])
		# WLTC en bucle cerrado con el coche del juego (control de velocidad como el piloto)
		c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
		c.consumo.reiniciar()
		var tt := 0.0
		var err := 0.0
		while tt < float(wl.size() - 1):
			var i := int(tt)
			var vo := lerpf(float(wl[i]), float(wl[mini(i + 1, wl.size() - 1)]), tt - i) / 3.6
			var a_obj := (float(wl[mini(i + 1, wl.size() - 1)]) - float(wl[i])) / 3.6
			var v := c.v
			var f: float = fi.masa * (a_obj + (vo - v) * 3.0) + c.fuerza_resistente(v)
			if f >= 0.0:
				c.acelerador = clampf(f / c.fuerza_motor(v), 0.0, 1.0)
				c.freno = 0.0
			else:
				c.acelerador = 0.0
				c.freno = clampf(-f / fi.f_freno_max, 0.0, 1.0)
			if vo < 0.05 and v < 0.3:
				c.acelerador = 0.0
				c.freno = 0.3
			c.paso_fisica(dt)
			err = maxf(err, absf(c.v - vo) * 3.6)
			tt += dt
		print("CALIBRACION %s | %.2f | %.4f | %.0f | %.2f | %s %.1f | %.2f (error máx. de velocidad %.1f km/h)" % [fi.id, c.consumo.objetivo, c.consumo.k, c.consumo.k * dens * 1000.0,
			c.consumo.media(), c.consumo.ref_texto, c.consumo.wltp, c.consumo.metros / 1000.0, err])
	get_tree().quit()
