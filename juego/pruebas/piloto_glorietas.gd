extends Node
## Solo verificación (no se sube): pone el coche con piloto ~120 m antes de cada glorieta (por un tramo que entra en
## ella), simula hasta que sale y cuenta segundos fuera del asfalto, recolocaciones, choques y vueltas.
var j

func _ready() -> void:
	var a := Ajustes.args
	var lista: Array = JSON.parse_string(FileAccess.get_file_as_string(a["lista"]))
	Ajustes.args["piloto"] = "1"
	Ajustes.args["trafico"] = a.get("trafico", "0")
	j = load("res://escenas/madrid.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	j.en_prueba = true
	j.piloto = true
	var res := []
	for g in lista:
		res.append(await _probar(g))
		var f := FileAccess.open(a["salida"], FileAccess.WRITE)
		f.store_string(JSON.stringify(res))
		f.close()
	print("GLORIETAS_FIN ", res.size())
	get_tree().quit()


func _probar(g: Dictionary) -> Dictionary:
	var c := Vector2(float(g["x"]), float(g["z"]))
	var R := float(g["r"])
	var datos = j.datos
	var red = j.red
	# nodos del anillo
	var nodos_anillo := {}
	for k in datos.tramos.size():
		var t: Dictionary = datos.tramos[k]
		if int(t["rot"]) != 1:
			continue
		var p: PackedVector3Array = datos.geometria(k)
		if Vector2(p[0].x, p[0].z).distance_to(c) < R + 15.0 and Vector2(p[p.size() - 1].x, p[p.size() - 1].z).distance_to(c) < R + 15.0:
			nodos_anillo[int(t["a"])] = true
			nodos_anillo[int(t["b"])] = true
	var out := {"x": c.x, "z": c.y, "r": R, "nombre": g.get("nombre", "")}
	if nodos_anillo.is_empty():
		out["error"] = "sin anillo"
		return out
	# tramo de entrada: el más largo que llega a un nodo del anillo en su sentido permitido
	var mejor := -1
	var msd := 1
	var mlen := 0.0
	var usados: Array = g.get("evitar", [])
	for id in nodos_anillo:
		var nd = datos.nodos.get(id)
		if nd == null:
			continue
		for x in nd[3]:
			var k := int(x)
			var t: Dictionary = datos.tramos[k]
			if int(t["rot"]) == 1 or int(t["tunel"]) == 1 or int(t["a"]) == int(t["b"]):
				continue
			var sd := 1 if int(t["b"]) == id else -1
			var sv := int(t["s"])
			if (sd > 0 and sv == -1) or (sd < 0 and sv == 1):
				continue
			if sv == 0 and red.has_method("prohibido") and red.prohibido(k, sd):
				continue     # ramal de salida que OSM deja como de doble sentido (ver MaRed.prohibido)
			if nodos_anillo.has(int(t["a"])) and nodos_anillo.has(int(t["b"])):
				continue
			var entra := false
			for o in red.salidas(k, sd):
				if int(datos.tramos[o[0]]["rot"]) == 1:
					entra = true
			if not entra:
				continue
			var L: float = red.longitud(k)
			if L > mlen:
				mlen = L
				mejor = k
				msd = sd
	if mejor < 0:
		out["error"] = "sin entrada"
		return out
	var d0 := maxf(0.0, mlen - 120.0)
	var ch0: int = j.choques
	var re0: int = j.reenganches
	j._colocar_en(mejor, msd, d0)
	j.coche.v = 8.0
	for i in 300:
		j.mundo.actualizar(j.coche.position)
		if j.mundo.pendientes.is_empty():
			break
		await get_tree().process_frame
	var fuera := 0.0
	var t := 0.0
	var dentro := false
	var salio := false
	var t_anillo := 0.0
	var ang_total := 0.0
	var ang_prev := NAN
	var fuera_anillo := 0.0
	var puntos := []
	while t < 120.0:
		for i in 10:
			j._simular(1.0 / 60.0)
			t += 1.0 / 60.0
			var p: Vector3 = j.coche.position
			var dc := Vector2(p.x, p.z).distance_to(c)
			if not j.coche.en_carretera:
				fuera += 1.0 / 60.0
				if puntos.size() < 12 and int(t * 60.0) % 15 == 0:
					puntos.append([snappedf(p.x, 0.1), snappedf(p.z, 0.1), snappedf(dc, 0.1), snappedf(j.coche.v * 3.6, 1), j.datos.rotulo(j.tramo_actual), snappedf(j.lat_camino, 0.1)])
				if dc < R + 30.0:
					fuera_anillo += 1.0 / 60.0
			if dc < R + 4.0:
				dentro = true
				t_anillo += 1.0 / 60.0
				var ang := atan2(p.z - c.y, p.x - c.x)
				if not is_nan(ang_prev):
					ang_total += absf(wrapf(ang - ang_prev, -PI, PI))
				ang_prev = ang
			elif dentro and dc > R + 50.0:
				salio = true
		if g.has("traza"):
			var p2: Vector3 = j.coche.position
			var c0 = j.camino[0] if not j.camino.is_empty() else [-1, 0]
			var cam := []
			for e in j.camino.slice(0, 5):
				cam.append("%d%s%s" % [e[0], "R" if int(j.datos.tramos[e[0]]["rot"]) == 1 else "", "+" if e[1] > 0 else "-"])
			print("TR t=%.2f p=%.1f,%.1f dc=%.1f v=%.0f v0=%.0f lat=%.1f d=%.1f/%.1f cam=%s ster=%.2f en=%s" % [t, p2.x, p2.z, Vector2(p2.x, p2.z).distance_to(c), j.coche.v * 3.6, j._velocidad_objetivo() * 3.6, j.lat_camino, j.d_camino, j.red.longitud(c0[0]) if c0[0] >= 0 else 0.0, " ".join(cam), j.coche.volante if "volante" in j.coche else 0.0, j.coche.en_carretera])
		j.mundo.actualizar(j.coche.position)
		await get_tree().process_frame
		if salio:
			break
	out.merge({"tramo": datos.rotulo(mejor), "entrada_m": mlen - d0, "entro": dentro, "salio": salio, "t": snappedf(t, 0.1),
		"fuera_s": snappedf(fuera, 0.01), "fuera_cerca_s": snappedf(fuera_anillo, 0.01), "reenganches": j.reenganches - re0,
		"choques": j.choques - ch0, "vueltas": snappedf(ang_total / TAU, 0.01), "t_anillo": snappedf(t_anillo, 0.1), "puntos": puntos})
	print("GLORIETA ", JSON.stringify(out))
	return out
