extends Node
## Solo verificación del mundo por teselas (scripts/mundo_stream/): fotos a vista de conductor a lo largo de una ruta,
## vistas aéreas y recorrido en piloto automático con métricas.
## Uso: -- --zona=navacerrada --dir=carpeta --modo=hoja|aereas|recorrido [--ruta=0] [--paso=500] [--sentido=1|-1]
##        [--mundo=stream|zona] [--poses="x,y,z,tx,ty,tz;…"] [--duracion=600]
var j: Node


func _ready() -> void:
	var zona := str(Ajustes.args.get("zona", "navacerrada"))
	Ajustes.args["zona"] = zona
	Ajustes.cambiar_zona(zona)
	Ajustes.ruta_idx = int(Ajustes.args.get("ruta", "0"))
	var modo := str(Ajustes.args.get("modo", "hoja"))
	if modo == "recorrido":
		Ajustes.piloto = true
		Ajustes.velocidad = float(Ajustes.args.get("vel", "80"))
		Ajustes.trafico = 0.0
	j = load("res://escenas/juego.tscn").instantiate()
	add_child(j)
	var t0 := Time.get_ticks_msec()
	while not j.cargado:
		await get_tree().process_frame
	print("CARGA_INICIAL_MS ", Time.get_ticks_msec() - t0)
	match modo:
		"hoja": await _hoja()
		"aereas": await _aereas()
		"recorrido": await _recorrido()
	print("FIN_VISTAS")
	get_tree().quit()


func _esperar_terreno(max_ms := 40000) -> int:
	var ts = j.mundo.terreno_stream
	var t0 := Time.get_ticks_msec()
	if ts == null:
		for i in 3:
			await get_tree().process_frame
		return 0
	var listos := 0
	while Time.get_ticks_msec() - t0 < max_ms:
		await get_tree().process_frame
		if (Time.get_ticks_msec() - t0) % 5000 < 20:
			print("ESPERA ", JSON.stringify(ts.resumen()))
		if ts.pendientes() == 0:
			listos += 1
			if listos >= 3:
				break
		else:
			listos = 0
	return Time.get_ticks_msec() - t0


func _hoja() -> void:
	var dir: String = Ajustes.args["dir"]
	var paso := float(Ajustes.args.get("paso", "500"))
	var sen := int(Ajustes.args.get("sentido", "1"))
	var h := float(Ajustes.args.get("h", "1.2"))
	var mira := 40.0
	j.pausado = true
	j.hud.visible = false
	var cam := Camera3D.new()
	cam.far = 75000.0
	cam.near = 0.2
	cam.fov = 70.0
	add_child(cam)
	cam.current = true
	var r: Ruta = Ajustes.ruta()
	var largo := r.longitud()
	var desde := float(Ajustes.args.get("desde", "0"))
	var hasta := minf(float(Ajustes.args.get("hasta", "1e9")), largo - 2.0 - mira)
	var s := maxf(desde, 2.0 + mira)
	var lista: Array = []
	while s < hasta:
		lista.append(s)
		s += paso
	if Ajustes.args.has("lista"):
		lista = Array(str(Ajustes.args["lista"]).split_floats(","))
	if sen < 0:
		lista.reverse()
	var idx := FileAccess.open(dir + "/indice.jsonl", FileAccess.WRITE)
	for sp in lista:
		var lat := r.lateral_carril(sp, sen)
		var pc := r.punto(sp) + r.derecha(sp) * lat
		pc.y = Ajustes.superficie.consultar(pc.x, pc.z, pc.y).x
		var pos := pc + Vector3.UP * h
		var sd: float = sp + mira * sen
		var obj := r.punto(sd) + r.derecha(sd) * r.lateral_carril(sd, sen)
		obj.y = Ajustes.superficie.consultar(obj.x, obj.z, obj.y).x + 0.6
		var fw := obj - pos
		fw.y = 0.0
		fw = fw.normalized()
		j.coche.position = pc + Vector3(0, -40, 0)
		cam.look_at_from_position(pos, obj, Vector3.UP)
		var espera := await _esperar_terreno()
		j.mundo.cargar_ventana(pc, fw)
		for i in 4:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var nombre := "%s_r%d%s_%05d.png" % [Ajustes.zona, Ajustes.ruta_idx, "" if sen > 0 else "v", roundi(sp)]
		get_viewport().get_texture().get_image().save_png(dir + "/" + nombre)
		var linea := {"foto": nombre, "s": sp, "km": snappedf(sp / 1000.0, 0.01), "espera_ms": espera}
		if j.mundo.terreno_stream != null:
			linea["terreno"] = j.mundo.terreno_stream.resumen()
		idx.store_line(JSON.stringify(linea))
		idx.flush()
		print("FOTO ", nombre, " espera ", espera, " ms")


func _aereas() -> void:
	var dir: String = Ajustes.args["dir"]
	j.pausado = true
	j.hud.visible = false
	var cam := Camera3D.new()
	cam.far = 75000.0
	cam.near = 0.5
	cam.fov = float(Ajustes.args.get("fov", "60"))
	add_child(cam)
	cam.current = true
	var n := 0
	for p in str(Ajustes.args["poses"]).split(";"):
		var v := p.split_floats(",")
		var pos := Vector3(v[0], v[1], v[2])
		var obj := Vector3(v[3], v[4], v[5])
		if v.size() > 6 and v[6] > 0.5:
			# alturas relativas al terreno (y = m sobre el suelo)
			pos.y += Ajustes.altura_terreno_zona(pos.x, pos.z)
			obj.y += Ajustes.altura_terreno_zona(obj.x, obj.z)
		j.coche.position = obj + Vector3(0, -60, 0)
		cam.look_at_from_position(pos, obj, Vector3.UP)
		await _esperar_terreno(60000)
		j.mundo.cargar_ventana(obj, (obj - pos).normalized())
		await _esperar_terreno(20000)
		for i in 4:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var nombre := "aerea_%d.png" % n
		get_viewport().get_texture().get_image().save_png(dir + "/" + nombre)
		print("FOTO ", nombre)
		n += 1


## Piloto automático por la ruta con métricas cada 30 s (memoria de vídeo, texturas, nodos huérfanos, teselas/s)
func _recorrido() -> void:
	var dir: String = Ajustes.args["dir"]
	var dur := float(Ajustes.args.get("duracion", "600"))
	var f := FileAccess.open(dir + "/metricas.jsonl", FileAccess.WRITE)
	var t0 := Time.get_ticks_msec()
	var ultimo := -30.0
	var montados0 := 0
	var fotos := 0
	var fps_acum := 0.0
	var fps_n := 0
	while (Time.get_ticks_msec() - t0) / 1000.0 < dur and not j.terminado:
		await get_tree().process_frame
		fps_acum += Engine.get_frames_per_second()
		fps_n += 1
		var t := (Time.get_ticks_msec() - t0) / 1000.0
		if t - ultimo >= 30.0:
			ultimo = t
			var ts = j.mundo.terreno_stream
			var res: Dictionary = ts.resumen() if ts != null else {}
			var m := {"t": roundi(t), "km": snappedf(j.s_coche / 1000.0, 0.01), "v_kmh": roundi(j.coche.v * 3.6),
					"video_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
					"texturas_mb": snappedf(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, 0.1),
					"buffers_mb": snappedf(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0, 0.1),
					"huerfanos": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
					"objetos": Performance.get_monitor(Performance.OBJECT_COUNT),
					"ram_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
					"fps_medio": snappedf(fps_acum / maxf(fps_n, 1), 0.1),
					"teselas_s": snappedf((int(res.get("montados", 0)) - montados0) / 30.0, 0.01),
					"pendientes": res.get("pendientes", 0), "nodos": res.get("nodos", 0), "dibujados": res.get("dibujados", 0),
					"cache_mb": res.get("cache_mb", 0), "descargas": res.get("descargas", {}), "us_montaje_medio": res.get("us_montaje_medio", 0),
					"us_subida_max": res.get("us_subida_max", 0), "por_nivel": res.get("por_nivel", {})}
			montados0 = int(res.get("montados", 0))
			fps_acum = 0.0
			fps_n = 0
			f.store_line(JSON.stringify(m))
			f.flush()
			print("METRICA ", JSON.stringify(m))
			if Ajustes.args.has("fotos"):
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(dir + "/recorrido_%02d.png" % fotos)
				fotos += 1
