extends Node
## Solo verificación: fotos a vista de conductor a lo largo de todas las rutas de las zonas, cada --paso m (por defecto 25),
## carril derecho, cámara a --h m (1,2) sobre la calzada mirando --mira m (40) por delante, fov 70.
## Por cada foto escribe una línea JSON en --dir/indice.jsonl con el polígono (en píxeles) del carril que tiene delante.
## Uso: -- --zonas=m406,a308 --dir=carpeta [--paso=25] [--rutas=0,1] [--desde=0] [--hasta=1e9] [--sentido=-1 (carril contrario, mirando hacia atrás)] [--graficos=bajo]
func _ready() -> void:
	var zonas: PackedStringArray = str(Ajustes.args.get("zonas", "m406")).split(",")
	var paso := float(Ajustes.args.get("paso", "25"))
	var h := float(Ajustes.args.get("h", "1.2"))
	var mira := float(Ajustes.args.get("mira", "40"))
	var dir: String = Ajustes.args["dir"]
	var sen := int(Ajustes.args.get("sentido", "1"))
	if Ajustes.args.has("graficos"):
		Paisaje.graficos = str(Ajustes.args["graficos"])   # "bajo": como la web y Gráficos bajo (árboles OSM, sin aspecto)
	var idx := FileAccess.open(dir + "/indice.jsonl", FileAccess.WRITE)
	for zona in zonas:
		Ajustes.args["zona"] = zona
		Ajustes.rutas.clear()
		Ajustes.cambiar_zona("")
		Ajustes.cambiar_zona(zona)
		var j = load("res://escenas/juego.tscn").instantiate()
		add_child(j)
		while not j.cargado:
			await get_tree().process_frame
		print("ZONA ", zona, " marcas_norma=", j.mundo.marcas_norma)
		j.pausado = true
		j.hud.visible = false
		var cam := Camera3D.new()
		cam.far = 75000.0
		cam.near = 0.2
		cam.fov = 70.0
		add_child(cam)
		cam.current = true
		var lista_rutas: Array = []
		if Ajustes.args.has("rutas"):
			for t in str(Ajustes.args["rutas"]).split(","):
				lista_rutas.append(int(t))
		else:
			lista_rutas = range(Ajustes.rutas.size())
		for ri in lista_rutas:
			var r: Ruta = Ajustes.rutas[ri]
			var largo := r.longitud()
			var s := maxf(float(Ajustes.args.get("desde", "0")), 2.0 + (mira if sen < 0 else 0.0))
			var hasta := minf(float(Ajustes.args.get("hasta", "1e9")), largo - 2.0 - (mira if sen > 0 else 0.0))
			var k := 0
			while s < hasta:
				var lat := r.lateral_carril(s, sen)
				var pc := r.punto(s) + r.derecha(s) * lat
				pc.y = Ajustes.superficie.consultar(pc.x, pc.z, pc.y).x
				var pos := pc + Vector3.UP * h
				var sd := s + mira * sen
				var obj := r.punto(sd) + r.derecha(sd) * r.lateral_carril(sd, sen)
				obj.y = Ajustes.superficie.consultar(obj.x, obj.z, obj.y).x + 0.6
				var fw := obj - pos
				fw.y = 0.0
				fw = fw.normalized()
				j.coche.position = pc + Vector3(0, -40, 0)
				j.mundo.cargar_ventana(pc, fw)
				cam.look_at_from_position(pos, obj, Vector3.UP)
				for i in 3:
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				# polígono del carril de delante (6..mira m), semiancho 1,6 m alrededor del centro del carril
				var izq := []
				var der := []
				var e := 6.0
				while e <= mira + 0.1:
					var se := s + e * sen
					var c := r.punto(se) + r.derecha(se) * r.lateral_carril(se, sen)
					c.y = Ajustes.superficie.consultar(c.x, c.z, c.y).x + 0.05
					var dd := r.derecha(se)
					for lado in [-1.0, 1.0]:
						var p3: Vector3 = c + dd * 1.6 * lado
						if cam.is_position_behind(p3):
							continue
						var p2 := cam.unproject_position(p3)
						(izq if lado < 0 else der).append([roundi(p2.x), roundi(p2.y)])
					e += 2.0
				der.reverse()
				var nombre := "%s_r%d%s_%05d" % [zona, ri, "" if sen > 0 else "v", roundi(s)]
				get_viewport().get_texture().get_image().save_jpg(dir + "/" + nombre + ".jpg", 0.85)
				idx.store_line(JSON.stringify({"f": nombre + ".jpg", "zona": zona, "ruta": ri, "s": s, "x": pc.x, "y": pc.y, "z": pc.z, "poli": izq + der, "k": k}))
				idx.flush()
				k += 1
				s += paso
			print("RUTA ", zona, " ", ri, " fotos ", k)
		cam.queue_free()
		j.queue_free()
		for i in 3:
			await get_tree().process_frame
	idx.close()
	print("FIN")
	get_tree().quit()
