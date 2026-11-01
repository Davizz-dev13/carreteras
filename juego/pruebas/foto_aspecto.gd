extends Node
## Solo verificación: fotos de aspecto (antes/después) en las zonas viejas.
## --spots=ruta.json  {"zona": [{"ruta":0,"km":5.5,"h":2.2,"d":9,"mira":45,"lat":0,"fov":70,"nombre":".."} ó {"x","z","y","yaw","h","d","fov","nombre"}], ...}  --dir=carpeta --pref=antes
func _ready() -> void:
	var todo: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Ajustes.args["spots"]))
	var pref: String = Ajustes.args.get("pref", "x")
	for zona in todo.keys():
		Ajustes.args["zona"] = zona
		Ajustes.rutas.clear()
		Ajustes.cambiar_zona("")
		Ajustes.cambiar_zona(zona)
		var t0 := Time.get_ticks_msec()
		var j = load("res://escenas/juego.tscn").instantiate()
		add_child(j)
		while not j.cargado:
			await get_tree().process_frame
		print("ZONA ", zona, " cargada en ", Time.get_ticks_msec() - t0, " ms")
		j.pausado = true
		j.hud.visible = false
		var cam := Camera3D.new()
		cam.far = 75000.0
		cam.near = 0.3
		add_child(cam)
		cam.current = true
		for s in todo[zona]:
			var pos: Vector3
			var obj: Vector3
			var fw: Vector3
			if s.has("km"):
				var r: Ruta = Ajustes.rutas[int(s["ruta"])]
				var sk := float(s["km"]) * 1000.0
				var sd := sk + float(s.get("mira", 40.0))
				var sc := sk - float(s.get("d", 9.0))
				var lat := float(s.get("lat", 0.0))
				var pc := r.punto(sc) + r.derecha(sc) * lat
				pc.y = Ajustes.superficie.consultar(pc.x, pc.z, pc.y).x
				pos = pc + Vector3.UP * float(s.get("h", 2.2))
				obj = r.punto(sd) + r.derecha(sd) * float(s.get("lat_mira", lat))
				obj.y = Ajustes.superficie.consultar(obj.x, obj.z, obj.y).x + float(s.get("h_mira", 0.5))
				fw = (obj - pos); fw.y = 0.0; fw = fw.normalized()
			else:
				var t := Vector3(float(s["x"]), 0.0, float(s["z"]))
				t.y = Ajustes.superficie.consultar(t.x, t.z, float(s.get("y", 900.0))).x
				var yaw := deg_to_rad(float(s.get("yaw", 0.0)))
				fw = Vector3(sin(yaw), 0.0, -cos(yaw))
				obj = t
				pos = t - fw * float(s.get("d", 60.0)) + Vector3.UP * float(s.get("h", 40.0))
			j.coche.position = obj + Vector3(0, -40, 0)
			j.mundo.cargar_ventana(obj, fw)
			cam.fov = float(s.get("fov", 70.0))
			cam.look_at_from_position(pos, obj, Vector3.UP)
			for i in int(s.get("frames", 40)):
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var out: String = Ajustes.args["dir"] + "/" + pref + "_" + s["nombre"] + ".png"
			get_viewport().get_texture().get_image().save_png(out)
			print("FOTO ", out)
		cam.queue_free()
		j.queue_free()
		for i in 3:
			await get_tree().process_frame
	get_tree().quit()
