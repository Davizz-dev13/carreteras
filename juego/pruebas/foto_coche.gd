extends Node
## Solo verificación: la foto de David (cámara de persecución detrás del coche, en la ruta) y una aérea, para comparar
## antes/ahora con el mismo encuadre. --zona=m406 --ruta=1 --km=1.32 --sentido=1 --dir=.. --pref=..
## [--aerea=x,z,h] [--alto=2.6] [--atras=7]
func _ready() -> void:
	var zona: String = Ajustes.args["zona"]
	Ajustes.rutas.clear()
	Ajustes.cambiar_zona("")
	Ajustes.cambiar_zona(zona)
	var j = load("res://escenas/juego.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	j.pausado = true
	j.hud.visible = false
	var cam := Camera3D.new()
	cam.far = 75000.0
	cam.near = 0.2
	add_child(cam)
	cam.current = true
	var r: Ruta = Ajustes.rutas[int(Ajustes.args.get("ruta", "0"))]
	var d := int(Ajustes.args.get("sentido", "1"))
	var dir: String = Ajustes.args["dir"]
	var pref: String = Ajustes.args.get("pref", "x")
	for km_t in str(Ajustes.args["km"]).split(","):
		var s := float(km_t) * 1000.0
		var p := r.punto_carril(s, d)
		p.y = Ajustes.superficie.consultar(p.x, p.z, p.y).x
		var fw := r.marcha_carril(s, d)
		fw.y = 0.0
		fw = fw.normalized()
		j.coche.position = p + Vector3.UP * 0.05
		j.coche.look_at(p + fw * 10.0 + Vector3.UP * 0.05, Vector3.UP)
		var cpos := p - fw * float(Ajustes.args.get("atras", "7")) + Vector3.UP * float(Ajustes.args.get("alto", "2.6"))
		var obj := p + fw * 14.0 + Vector3.UP * 0.6
		j.mundo.cargar_ventana(p, fw)
		cam.fov = 70.0
		cam.look_at_from_position(cpos, obj, Vector3.UP)
		for i in 30:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s_coche_%s.png" % [dir, pref, km_t])
		print("FOTO coche ", km_t)
	if Ajustes.args.has("aerea"):
		var a := str(Ajustes.args["aerea"]).split(",")
		var t := Vector3(float(a[0]), 0.0, float(a[1]))
		t.y = Ajustes.superficie.consultar(t.x, t.z, 600.0).x
		j.coche.position = t + Vector3(0, -40, 0)
		j.mundo.cargar_ventana(t, Vector3.FORWARD)
		cam.look_at_from_position(t + Vector3(0, float(a[2]), 3.0), t, Vector3.UP)
		for i in 30:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s_aerea.png" % [dir, pref])
		print("FOTO aerea")
	get_tree().quit()
