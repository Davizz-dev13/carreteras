extends Node
## Solo verificación: piloto por cada glorieta de la ruta de las zonas viejas, en los dos sentidos.
##   godot --headless res://pruebas/rr_piloto.tscn -- --zona=m406 --trafico=0 --salida=/tmp/x.json
## Por caso: segundos fuera del asfalto (Superficie), choques, derrapes, si llega 150 m después de la glorieta.
func _ready() -> void:
	var a := Ajustes.args
	var zona: String = a.get("zona", "m406")
	a["zona"] = zona
	a["piloto"] = "1"
	Ajustes.zona = zona
	Ajustes.rutas.clear()
	Ajustes.cargar()
	var res := []
	for ri in Ajustes.rutas.size():
		if (Ajustes.rutas[ri] as Ruta).arcos_glorieta.is_empty():
			continue
		a["ruta"] = str(ri)
		var j = load("res://escenas/juego.tscn").instantiate()
		add_child(j)
		while not j.cargado:
			await get_tree().process_frame
		j.pausado = true
		var r: Ruta = j.ruta
		for ar in r.arcos_glorieta:
			for d in [1, -1]:
				var sa: float = ar["a"] * r.paso
				var sb: float = ar["b"] * r.paso
				var s0 := (sa - 160.0) if d > 0 else (sb + 160.0)
				var s1 := (sb + 160.0) if d > 0 else (sa - 160.0)
				s0 = clampf(s0, r.s_trafico_min, r.s_trafico_max)
				s1 = clampf(s1, r.s_trafico_min, r.s_trafico_max)
				j.dir = d
				j.s_ini = s0
				j.s_fin = s1
				j._reiniciar(true)
				var fuera := 0.0
				var t := 0.0
				var donde := ""
				while t < 90.0 and (j.s_coche - s1) * d < 0.0:
					j._simular(1.0 / 60.0)
					t += 1.0 / 60.0
					if not j.coche.en_carretera:
						if fuera == 0.0:
							donde = "s=%.0f lat=%.1f desv=%d pos=(%.0f, %.0f)" % [j.s_coche, j.lat_coche, r.desvio_en(j.s_coche, d), j.coche.position.x, j.coche.position.z]
						fuera += 1.0 / 60.0
				var caso := {"ruta": ri, "g": ar["g"], "dir": d, "fuera_s": snappedf(fuera, 0.1), "choques": j.choques,
						"derrapes": j.derrapes, "donde": donde, "llega": (j.s_coche - s1) * d >= 0.0, "t": snappedf(t, 0.1)}
				res.append(caso)
				print("CASO ", JSON.stringify(caso))
		j.queue_free()
		for i in 3:
			await get_tree().process_frame
	var f := FileAccess.open(a.get("salida", "/tmp/rr_piloto.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(res))
	f.close()
	print("RR_PILOTO_FIN ", res.size())
	get_tree().quit()
