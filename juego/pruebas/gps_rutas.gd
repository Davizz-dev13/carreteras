extends Node
## Solo verificación (no se sube): GPS del mapa abierto. Para cada caso de --casos (JSON): coloca el coche con piloto
## en la vía `ref` más cercana a (x, z), pone el destino en el mapa en `dest` (como un clic), espera la ruta del hilo y
## la recorre con el piloto hasta "Has llegado": segundos fuera del asfalto, choques, recolocaciones, recálculos,
## cambios de sentido en la ruta. Con "equivocar": el piloto toma a propósito otra salida en un cruce de la ruta.
## Con --foto=ruta.png (y --foto_mapa=mapa.png): captura del juego con el minimapa y del mapa grande en el primer caso.
var j
var log_f: FileAccess

func _ready() -> void:
	var a := Ajustes.args
	var casos: Array = JSON.parse_string(FileAccess.get_file_as_string(a["casos"]))
	Ajustes.args["piloto"] = "1"
	Ajustes.args["trafico"] = a.get("trafico", "0")
	j = load("res://escenas/madrid.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	j.en_prueba = true
	j.piloto = true
	var t0 := Time.get_ticks_msec()
	j.gps.esperar_grafo()
	print("GPS_GRAFO_ESPERA %d ms" % (Time.get_ticks_msec() - t0))
	var res := []
	for c in casos:
		res.append(await _probar(c))
		var f := FileAccess.open(a["salida"], FileAccess.WRITE)
		f.store_string(JSON.stringify(res, " "))
		f.close()
	print("GPS_FIN ", res.size())
	get_tree().quit()


func _esperar_teselas() -> void:
	for i in 600:
		j.mundo.actualizar(j.coche.position)
		if j.mundo.pendientes.is_empty():
			break
		await get_tree().process_frame


func _probar(c: Dictionary) -> Dictionary:
	var out := {"caso": c["nombre"]}
	Ajustes.args["x"] = str(c["x"])
	Ajustes.args["z"] = str(c["z"])
	var s: Array = [int(c["k"]), int(c["sd"]), 20.0] if c.has("k") else j._salida(str(c["ref"]))
	j.mapa.quitar_destino()
	j._colocar_en(s[0], s[1], s[2])
	j.coche.v = 0.0
	await _esperar_teselas()
	if c.get("dest") == null:
		c["dest"] = _otra_calzada(s[0], s[1], s[2] + 150.0)
		out["dest_calc"] = c["dest"]
	var ch0: int = j.choques
	var re0: int = j.reenganches
	var rc0: int = j.mapa.recalculos
	j.mapa.poner_destino(Vector2(float(c["dest"][0]), float(c["dest"][1])))
	var tw := Time.get_ticks_msec()
	while j.mapa._pendiente != "":
		await get_tree().process_frame
	out["espera_ms"] = Time.get_ticks_msec() - tw
	out["ms_hilo"] = snappedf(j.gps.ms_calculo, 0.1)
	if not j.gps.activo():
		out["error"] = "sin ruta"
		print("GPS_CASO ", JSON.stringify(out))
		return out
	var e0: Array = j.camino[0]
	out["inicio"] = j.datos.rotulo(s[0])
	out["destino"] = j.gps.nombre
	out["ruta_m"] = roundi(j.gps.restante(e0[0], e0[1], j.d_camino))
	out["ruta_min"] = snappedf(j.gps.segundos(e0[0], e0[1], j.d_camino) / 60.0, 0.1)
	out["pasos"] = j.gps.pasos.size()
	out["destino_xz"] = [roundi(j.gps.destino.x), roundi(j.gps.destino.z)]
	var vueltas := 0
	var glorietas := 0
	var man := []
	for m in j.gps.maniobras:
		if str(m[4]) == "vuelta":
			vueltas += 1
		if str(m[4]).begins_with("glorieta"):
			glorietas += 1
		if man.size() < 14:
			man.append("%.0f m: %s" % [m[1], m[2]])
	out["cambios_sentido_fuera_glorieta"] = vueltas
	out["glorietas"] = glorietas
	out["maniobras"] = man
	# comprobar que cada paso de la ruta es una salida legal de MaRed (lo que el piloto puede recorrer)
	var ilegales := 0
	for i in j.gps.pasos.size() - 1:
		var p1: Array = MaGps.paso(j.gps.pasos[i])
		var p2: Array = MaGps.paso(j.gps.pasos[i + 1])
		var ok := false
		for o in j.red.salidas(p1[0], p1[1]):
			if int(o[0]) == int(p2[0]) and int(o[1]) == int(p2[1]):
				ok = true
		if not ok and not (p1[0] == p2[0] and j.red.salidas(p1[0], p1[1]).is_empty()):
			ilegales += 1
	out["giros_no_legales"] = ilegales
	print("GPS_RUTA ", JSON.stringify(out))
	if Ajustes.args.has("foto") and not Ajustes.args.has("_foto_hecha"):
		await _fotos()
		Ajustes.args["_foto_hecha"] = "1"
		if Ajustes.args.has("solo_foto"):
			get_tree().quit()
			return out
	# recorrerla con el piloto
	var fuera := 0.0
	var t := 0.0
	var km := 0.0
	var limite := float(out["ruta_min"]) * 60.0 * 3.0 + 400.0
	var t_traza := 0.0
	var equivocado := false
	var fuera_ev: Array = []
	var llego := false
	while t < limite:
		for i in 20:
			var p0: Vector3 = j.coche.position
			j._simular(1.0 / 60.0)
			t += 1.0 / 60.0
			km += Vector2(j.coche.position.x - p0.x, j.coche.position.z - p0.z).length() / 1000.0
			if not j.coche.en_carretera:
				if fuera_ev.size() < 30 and int(t * 60.0) % 10 == 0:
					fuera_ev.append("t=%.1f %.0f,%.0f %s v=%.0f lat=%.1f" % [t, j.coche.position.x, j.coche.position.z, j.datos.rotulo(j.tramo_actual), j.coche.v * 3.6, j.lat_camino])
				fuera += 1.0 / 60.0
		j.mapa._process(20.0 / 60.0)
		if t - t_traza >= 30.0:
			t_traza = t
			var ec: Array = j.camino[0] if not j.camino.is_empty() else [-1, 0]
			print("  TR t=%.0f v=%.0f v0=%.0f pos=%.0f,%.0f %s falta=%.0f camino=%d lat=%.1f piloto=%s" % [t, j.coche.v * 3.6, j._velocidad_objetivo() * 3.6 if not j.camino.is_empty() else -1.0,
					j.coche.position.x, j.coche.position.z, j.datos.rotulo(j.tramo_actual), j.gps.restante(ec[0], ec[1], j.d_camino) if ec[0] >= 0 else -2.0, j.camino.size(), j.lat_camino, j.piloto])
		j.mundo.actualizar(j.coche.position)
		if not j.gps.activo() and j.mapa._pendiente == "":
			llego = j.mapa._llegada_t > 0.0
			break
		if c.get("equivocar", false) and not equivocado and t > 15.0 and not j.camino.is_empty():
			var e: Array = j.camino[0]
			var px: Array = j.gps.proxima(e[0], e[1], j.d_camino)
			if not px.is_empty() and float(px[0]) < 250.0 and str(px[3]) != "destino":
				# en esa maniobra, hacer lo contrario (o girar a la derecha si la ruta sigue recto)
				var g := float(px[2])
				j.preferencia = -1 if g > 0.2 else 1
				if str(px[3]).begins_with("glorieta"):
					j.preferencia = 1
				j._replanificar()
				equivocado = true
				out["equivocacion"] = "en %s: ruta '%s', piloto preferencia %d" % [j.datos.rotulo(e[0]), px[1], j.preferencia]
				print("GPS_EQUIVOCAR ", out["equivocacion"])
		await get_tree().process_frame
	out["llego"] = llego
	out["t_s"] = roundi(t)
	out["km"] = snappedf(km, 0.01)
	out["fuera_s"] = snappedf(fuera, 0.01)
	out["choques"] = j.choques - ch0
	out["reenganches"] = j.reenganches - re0
	out["recalculos"] = j.mapa.recalculos - rc0
	out["fuera_donde"] = fuera_ev
	out["fin_xz"] = [roundi(j.coche.position.x), roundi(j.coche.position.z)]
	print("GPS_CASO ", JSON.stringify(out))
	return out


## Un punto de la otra calzada (misma vía, sentido contrario) frente al punto d del paso [k, sd]
func _otra_calzada(k: int, sd: int, d: float) -> Array:
	var pt: Array = j.red.punto(k, sd, minf(d, j.red.longitud(k)))
	var p: Vector3 = pt[0]
	var tg: Vector3 = pt[1]
	var mejor := INF
	var q := [p.x, p.z]
	for k2 in j.datos.tramos.size():
		if k2 == k or not j.red.misma_via(k, k2) or int(j.datos.tramos[k2]["s"]) == 0:
			continue
		var g: PackedVector3Array = j.datos.geometria(k2)
		for i in g.size() - 1:
			var a := Vector2(g[i].x, g[i].z)
			var b := Vector2(g[i + 1].x, g[i + 1].z)
			var dir := (b - a).normalized() * float(j.datos.tramos[k2]["s"])
			if dir.dot(Vector2(tg.x, tg.z)) > -0.7:
				continue
			var cq := Geometry2D.get_closest_point_to_segment(Vector2(p.x, p.z), a, b)
			var dd := cq.distance_to(Vector2(p.x, p.z))
			if dd < mejor:
				mejor = dd
				q = [cq.x, cq.y]
	print("OTRA_CALZADA a %.0f m: %s" % [mejor, str(q)])
	return q


func _fotos() -> void:
	# unos segundos de conducción para que el minimapa y el panel tengan algo delante
	for i in int(float(Ajustes.args.get("presim", "6")) * 60.0):
		j._simular(1.0 / 60.0)
		if i % 30 == 0:
			j.mundo.actualizar(j.coche.position)
			j.mapa._process(0.5)
	await _esperar_teselas()
	j.en_prueba = true
	j.coche.reset_physics_interpolation()
	j.cam_iniciada = false
	j._camara(0.016)
	j._hud()
	j.mapa._t_rotulos = 0.0
	j.mapa._process(0.016)
	for i in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(Ajustes.args["foto"])
	print("GPS_FOTO ", Ajustes.args["foto"])
	if Ajustes.args.has("foto_mapa"):
		j.mapa.abrir(true)
		# encuadrar coche y destino
		var a := Vector2(j.coche.position.x, j.coche.position.z)
		var b := Vector2(j.gps.destino.x, j.gps.destino.z)
		j.mapa.centro = (a + b) * 0.5
		var tam: Vector2 = get_viewport().get_visible_rect().size
		j.mapa.m_px = clampf(maxf(absf(a.x - b.x) / (tam.x * 0.75), absf(a.y - b.y) / (tam.y * 0.7)), 4.0, 200.0)
		j.mapa._vista()
		for i in 12:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(Ajustes.args["foto_mapa"])
		print("GPS_FOTO ", Ajustes.args["foto_mapa"])
		j.mapa.abrir(false)
