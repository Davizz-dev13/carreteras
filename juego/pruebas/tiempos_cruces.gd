## Solo medida: cuánto tarda cada paso de Cruces.preparar() (la carga de datos de una zona; en la web es lo que
## congela la página al elegir zona). godot --headless --path . res://pruebas/tiempos_cruces.tscn -- --zona=m406
extends Node

func _ready() -> void:
	var zona: String = Ajustes.args.get("zona", "m406")
	Ajustes.zona = zona
	var t := Time.get_ticks_msec()
	var d := Ajustes.dir_datos()
	Ajustes.info = JSON.parse_string(FileAccess.get_file_as_string(d + "zona.json"))
	var car: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(d + "carreteras.json"))
	var rutas: Array = []
	for r in car["rutas"]:
		rutas.append(Ruta.desde_json(r))
	Ajustes.glorietas = car.get("glorietas", [])
	var lista: Array = car["vias"].duplicate()
	for nombre in car.get("vias_archivos", []):
		var parte = JSON.parse_string(FileAccess.get_file_as_string(d + str(nombre)))
		if parte is Dictionary:
			lista.append_array(parte.get("vias", []))
	var vias: Array = []
	for v in lista:
		var pts := PackedVector3Array()
		var xs: Array = v["x"]
		for i in xs.size():
			pts.append(Vector3(xs[i], v["y"][i], v["z"][i]))
		vias.append({"pts": pts, "ancho": float(v["ancho"]), "nombre": v["ref"], "tunel": int(v["tunel"]), "puente": int(v.get("puente", 0))})
	var t_json := Time.get_ticks_msec() - t
	# terreno (lo necesita _excavar_terreno): igual que Ajustes.cargar()
	Ajustes.rutas.assign(rutas)
	Ajustes.vias = vias
	var ter: Dictionary = Ajustes.info["terreno"]
	Ajustes.ter_paso = float(ter["paso"]); Ajustes.ter_tesela = float(ter["tesela"])
	Ajustes.ter_x0 = 1e9; Ajustes.ter_z0 = 1e9
	for tt in ter["teselas"]:
		Ajustes.ter_x0 = minf(Ajustes.ter_x0, float(tt["x0"])); Ajustes.ter_z0 = minf(Ajustes.ter_z0, float(tt["z0"]))
	for tt in ter["teselas"]:
		var f := FileAccess.open(d + "terreno/%s.bin" % tt["nombre"], FileAccess.READ)
		Ajustes.ter_n = int(tt["n"])
		Ajustes.terreno[Vector2i(roundi((float(tt["x0"]) - Ajustes.ter_x0) / Ajustes.ter_tesela), roundi((float(tt["z0"]) - Ajustes.ter_z0) / Ajustes.ter_tesela))] = f.get_buffer(f.get_length()).to_float32_array()
	var c := Cruces.new()
	Cruces.parches = []
	var m := {}
	t = Time.get_ticks_msec()
	var nodos: Array = c._nodos_originales(rutas, vias)
	m["nodos"] = Time.get_ticks_msec() - t; t = Time.get_ticks_msec()
	for r in rutas:
		c._procesar_ruta(r)
	m["rutas"] = Time.get_ticks_msec() - t; t = Time.get_ticks_msec()
	var nuevas: Array = c._procesar_vias(vias)
	vias.clear(); vias.append_array(nuevas)
	m["vias"] = Time.get_ticks_msec() - t; t = Time.get_ticks_msec()
	c._parches(nodos)
	m["parches"] = Time.get_ticks_msec() - t; t = Time.get_ticks_msec()
	c._anillos(Ajustes.glorietas)
	m["anillos"] = Time.get_ticks_msec() - t; t = Time.get_ticks_msec()
	c._excavar_terreno(rutas, vias)
	m["excavar"] = Time.get_ticks_msec() - t; t = Time.get_ticks_msec()
	print("TIEMPOS %s json=%d ms %s nodos=%d parches=%d" % [zona, t_json, str(m), nodos.size(), Cruces.parches.size()])
	var s := Superficie.new()
	s.construir(Ajustes.rutas, vias)
	m["superficie"] = Time.get_ticks_msec() - t
	print("TIEMPOS %s json=%d ms %s nodos=%d parches=%d" % [zona, t_json, str(m), nodos.size(), Cruces.parches.size()])
	get_tree().quit()
