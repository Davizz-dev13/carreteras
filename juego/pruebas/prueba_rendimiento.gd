## Prueba de rendimiento.gd (PC flojo, Gráficos bajo ligero, bajada automática por FPS):
##  godot --path . --rendering-driver opengl3 res://pruebas/prueba_rendimiento.tscn -- --cfg_graficos=user://prueba_rend.cfg
##      [--modo=menu|partida] [--forzar_gpu_debil] [--fps_falso=20] [--graficos=alto|bajo] [--zona=…] --salida=foto.png
## Usa su propio archivo de opciones (--cfg_graficos): no toca el de verdad.
extends Node

var juego: Node
var t := 0.0
var t_bajada := -1.0
var mem := []
var _hecho := false


func _ready() -> void:
	var r := get_node("/root/Rendimiento")
	print("PRUEBA inicio: graficos=%s motivo='%s' bajada_hecha=%s ligero=%s msaa=%d escala=%.2f" % [Paisaje.graficos,
			r.motivo_debil, r.bajada_hecha, r.ligero(), get_viewport().msaa_3d, get_viewport().scaling_3d_scale])
	_cfg("al empezar")
	if Ajustes.args.get("modo", "partida") == "menu":
		var m = load("res://escenas/menu.tscn").instantiate()
		add_child(m)
		for i in 30:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(Ajustes.args.get("salida", "user://prueba_rend.png"))
		print("PRUEBA menu guardado")
		get_tree().quit()
		return
	juego = load("res://escenas/juego.tscn").instantiate()
	add_child(juego)


func _cfg(cuando: String) -> void:
	var r := get_node("/root/Rendimiento")
	for camino in [r.archivo_opciones(), r._archivo_propio()]:
		print("PRUEBA cfg %s (%s): %s" % [camino, cuando, FileAccess.get_file_as_string(camino).replace("\n", " | ")])


func _process(dt: float) -> void:
	if juego == null or not juego.cargado or _hecho:
		return
	t += dt
	var r := get_node("/root/Rendimiento")
	if int((t - dt) / 2.0) != int(t / 2.0):
		mem.append("t=%.0f fps=%.0f vram=%.1fMB tex=%.1fMB estatica=%.1fMB objetos=%d huerfanos=%d draws=%d" % [t,
				Engine.get_frames_per_second(), Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
				Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
				Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, Performance.get_monitor(Performance.OBJECT_COUNT),
				Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
	if r.bajada_hecha and t_bajada < 0.0:
		t_bajada = t
		print("PRUEBA bajada a los %.1f s de partida" % t)
	var fin := float(Ajustes.args.get("segundos", "45"))
	if (t_bajada >= 0.0 and t - t_bajada > 1.5) or t > fin:
		_hecho = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(Ajustes.args.get("salida", "user://prueba_rend.png"))
		var sol: Array = get_tree().root.find_children("*", "DirectionalLight3D", true, false)
		var cams: Array = get_tree().root.find_children("*", "Camera3D", true, false)
		var we: Array = get_tree().root.find_children("*", "WorldEnvironment", true, false)
		var vis := []
		for g in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
			if (g as GeometryInstance3D).visibility_range_end > 0.0 and vis.size() < 6:
				vis.append(snappedf((g as GeometryInstance3D).visibility_range_end, 1.0))
		print("PRUEBA fin t=%.1f graficos=%s bajada=%s msaa=%d escala=%.2f sombras=%s far=%s niebla=%s vis_end=%s" % [t,
				Paisaje.graficos, r.bajada_hecha, get_viewport().msaa_3d, get_viewport().scaling_3d_scale,
				str(sol.map(func(s): return s.shadow_enabled)), str(cams.map(func(c): return c.far)),
				str(we.map(func(w): return [w.environment.fog_depth_begin, w.environment.fog_depth_end])), str(vis)])
		for l in mem:
			print("PRUEBA mem ", l)
		_cfg("al acabar")
		get_tree().quit()
