## Pruebas y vistas previas de la interfaz (menú, pausa con Esc, mapa de viaje, viajes entre zonas, velocímetro > 250):
##   godot --rendering-driver opengl3 --resolution 1280x720 res://pruebas/prueba_ui.tscn -- --caso=viajes --dir=/tmp/ui
## Casos: menu (capturas del menú, normal y con Madrid elegida) · viajes (Madrid → Navacerrada → Madrid → Navacerrada por el
## mapa, Esc y OPTIONS en cada zona, capturas de pausa/mapa/carga, nodos huérfanos y memoria de vídeo tras cada salto) ·
## zonas (viaje por el mapa a M-406, A-308 y GR-8101, Esc en cada una) · velocimetro (Arteon R a 270 km/h en el HUD).
## Imprime UI_OK / UI_FALLO por comprobación y UI_FIN fallos=N.
extends Node


func _ready() -> void:
	var a := Ayudante.new()
	a.name = "AyudantePruebaUI"
	get_tree().root.add_child.call_deferred(a)


class Ayudante extends Node:
	var dir := "/tmp/ui"
	var fallos := 0
	var t0 := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		dir = str(Ajustes.args.get("dir", "/tmp/ui"))
		DirAccess.make_dir_recursive_absolute(dir)
		t0 = Time.get_ticks_msec()
		var caso := str(Ajustes.args.get("caso", "viajes"))
		Ajustes.trafico = 0.3
		match caso:
			"menu": await _menu()
			"viajes": await _viajes()
			"zonas": await _zonas()
			"velocimetro": await _velocimetro()
		print("UI_FIN caso=%s fallos=%d en %.0f s" % [caso, fallos, (Time.get_ticks_msec() - t0) / 1000.0])
		get_tree().quit()

	func ok(c: bool, que: String) -> void:
		print(("UI_OK " if c else "UI_FALLO ") + que)
		if not c:
			fallos += 1

	func foto(nombre: String, cuadros := 3) -> void:
		for i in cuadros:
			await get_tree().process_frame
		if DisplayServer.get_name() == "headless":
			return          # sin pantalla no llega frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(dir + "/" + nombre + ".png")
		print("FOTO %s %dx%d" % [nombre, img.get_width(), img.get_height()])

	func esperar(n: int) -> void:
		for i in n:
			await get_tree().process_frame

	func tecla(k: Key) -> void:
		var e := InputEventKey.new()
		e.keycode = k
		e.physical_keycode = k
		e.pressed = true
		Input.parse_input_event(e)
		await esperar(2)
		var r := e.duplicate()
		r.pressed = false
		Input.parse_input_event(r)
		await esperar(2)

	func boton(b: JoyButton) -> void:
		var e := InputEventJoypadButton.new()
		e.button_index = b
		e.pressed = true
		e.device = 0
		Input.parse_input_event(e)
		await esperar(2)
		var r := e.duplicate()
		r.pressed = false
		Input.parse_input_event(r)
		await esperar(2)

	## Espera a que la escena actual sea una partida cargada (juego.gd o ma_juego.gd)
	func esperar_partida(limite_s := 240.0) -> Node:
		var t := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t < limite_s * 1000.0:
			await get_tree().process_frame
			var s := get_tree().current_scene
			if s != null and s.get("cargado") == true and s.get("coche") != null:
				await esperar(10)
				return s
		var c := get_tree().current_scene
		print("UI_INFO sin partida tras %.0f s: escena=%s cargado=%s" % [limite_s, c.name if c else "ninguna", str(c.get("cargado")) if c else "-"])
		return null

	func memoria(etq: String) -> void:
		print("MEM %s huerfanos=%d video_MB=%.1f texturas_MB=%.1f objetos=%d nodos=%d recursos=%d" % [etq,
			Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
			Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
			Performance.get_monitor(Performance.OBJECT_COUNT), Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)])

	func utm_coche(s: Node) -> Vector2:
		var o: Array = (s.datos.info if s.get("datos") != null else Ajustes.info)["origen_utm"]
		return Vector2(float(o[0]) + s.coche.position.x, float(o[1]) - s.coche.position.z)

	## Esc y OPTIONS abren y cierran la pausa; la partida no avanza mientras está abierta
	func probar_pausa(s: Node, zona: String, con_foto: bool) -> void:
		var es_madrid: bool = s.get("pausa") != null
		var abierta := func() -> bool: return s.pausado and (s.pausa.panel.visible if es_madrid else s.panel_pausa.visible)
		await tecla(KEY_ESCAPE)
		ok(abierta.call(), "%s: Esc abre la pausa" % zona)
		ok(get_tree().current_scene == s, "%s: Esc no saca de la partida" % zona)
		var p0: Vector3 = s.coche.position
		var tt: float = s.tiempo
		await esperar(30)
		ok(s.coche.position.distance_to(p0) < 0.01 and is_equal_approx(s.tiempo, tt), "%s: en pausa el coche y el reloj están parados" % zona)
		if con_foto:
			await foto("pausa_" + zona)
		await tecla(KEY_ESCAPE)
		ok(not s.pausado, "%s: Esc otra vez sigue la partida" % zona)
		await boton(JOY_BUTTON_START)
		ok(abierta.call(), "%s: OPTIONS (Start) del mando abre la pausa" % zona)
		await boton(JOY_BUTTON_START)
		ok(not s.pausado, "%s: OPTIONS otra vez sigue" % zona)

	## Abre el mapa de viaje desde la pausa y viaja al punto de esa zona (el de en medio de su ruta / tramo dados)
	func viajar(s: Node, zona: String, frac := 0.5, foto_mapa := "", foto_carga := "") -> Dictionary:
		if s.get("pausa") != null:
			s.pausar(true)
			s.pausa.abrir_mapa()
		else:
			s._pausa(true)
			s._abrir_mapa_viaje()
		await esperar(3)
		var mv: MapaViaje = s.pausa.mapa_viaje if s.get("pausa") != null else s.mapa_viaje
		ok(mv != null and mv.visible, "mapa de viaje abierto desde la pausa")
		var z := {}
		for zz in mv.zonas:
			if zz["clave"] == zona:
				z = zz
		ok(not z.is_empty(), "el mapa tiene la zona " + zona)
		var p := Vector2.ZERO
		if not z["rutas"].is_empty():
			var pr: PackedVector2Array = z["rutas"][0]["p"]
			p = pr[int(pr.size() * frac)]
		else:
			var l: PackedVector2Array = (z["madrid"].filter(func(m): return int(m[0]) <= 1)[int(z["madrid"].size() * 0.0) + 40])[1]
			p = l[l.size() / 2]
		mv._ir_a_zona(z)
		mv.preferida = ""      # el clic decide solo por cercanía (con la zona propia por delante del mapa abierto)
		if zona == Ajustes.ZONA_MADRID:
			mv.preferida = zona
		mv.escala = 25.0
		mv.centro = p + Vector2(800.0, 300.0)
		mv.queue_redraw()
		await esperar(2)
		mv.clic(mv.a_pantalla(p) + Vector2(5, -4))   # un clic de verdad, unos píxeles al lado de la carretera
		ok(not mv.elegido.is_empty() and mv.elegido["zona"] == zona, "clic en el mapa elige un punto de " + zona)
		var destino := Vector2(mv.elegido["e"], mv.elegido["n"])
		if foto_mapa != "":
			await foto(foto_mapa)
		mv.viajar()
		if foto_carga != "":
			for i in 600:
				await get_tree().process_frame
				var c := get_tree().current_scene
				if c != null and c.name == "Viaje":
					break
			await foto(foto_carga, 0)
		var nueva := await esperar_partida()
		ok(nueva != null, "la partida de %s carga tras el viaje" % zona)
		if nueva == null:
			return {}
		var d := utm_coche(nueva).distance_to(destino)
		ok(d < 40.0, "%s: el coche sale en el punto elegido (a %.1f m)" % [zona, d])
		return {"escena": nueva, "destino": destino}

	func _menu() -> void:
		Ajustes.madrid_elegida = false
		get_tree().change_scene_to_file("res://escenas/menu.tscn")
		await esperar(40)
		var m := get_tree().current_scene
		await foto("menu_" + str(Ajustes.args.get("etq", "")))
		var vs := get_viewport().get_visible_rect().size
		var desborda := []
		for n in m.find_children("*", "Control", true, false):
			var c := n as Control
			if c.is_visible_in_tree() and not (c is ScrollContainer) and c.get_global_rect().end.x > vs.x + 1.0:
				desborda.append("%s(%s) %.0f" % [c.name, c.get_class(), c.get_global_rect().end.x])
		ok(desborda.is_empty(), "menú a %dx%d: nada se sale por la derecha %s" % [vs.x, vs.y, str(desborda.slice(0, 5))])
		var lz: OptionButton = m.lista_zonas
		var im := -1
		for i in lz.item_count:
			if lz.get_item_text(i) == Ajustes.NOMBRE_MADRID:
				im = i
		ok(im >= 0, "la Comunidad de Madrid está en la lista de zonas")
		lz.select(im)
		lz.item_selected.emit(im)
		await esperar(5)
		ok(Ajustes.madrid_elegida and not m.lista_rutas.is_visible_in_tree() and m.ck_stream.disabled, "con Madrid elegida se ocultan carretera y km y la casilla beta queda gris")
		await foto("menu_madrid_" + str(Ajustes.args.get("etq", "")))
		m._abrir_mapa_viaje()
		m.mapa_viaje._ver_todo()
		await foto("mapa_espana_" + str(Ajustes.args.get("etq", "")))
		Ajustes.madrid_elegida = false

	func _viajes() -> void:
		Ajustes.madrid_elegida = true
		get_tree().change_scene_to_file("res://escenas/madrid.tscn")
		var s := await esperar_partida()
		ok(s != null, "Madrid carga")
		if s == null:
			return
		memoria("madrid_inicio")
		await probar_pausa(s, "madrid", true)
		var r := await viajar(s, "navacerrada", 0.45, "mapa_desde_madrid", "carga_navacerrada")
		if r.is_empty():
			return
		memoria("salto1_navacerrada")
		await probar_pausa(r["escena"], "navacerrada", true)
		r = await viajar(r["escena"], "madrid", 0.5, "mapa_desde_navacerrada", "carga_madrid")
		if r.is_empty():
			return
		memoria("salto2_madrid")
		r = await viajar(r["escena"], "navacerrada", 0.2)
		if r.is_empty():
			return
		await esperar(60)
		memoria("salto3_navacerrada")

	func _zonas() -> void:
		Ajustes.madrid_elegida = false
		Ajustes.cambiar_zona("navacerrada")
		get_tree().change_scene_to_file("res://escenas/juego.tscn")
		var s := await esperar_partida()
		ok(s != null, "Navacerrada carga")
		if s == null:
			return
		for z in ["m406", "a308", "gr8101"]:
			var r := await viajar(s, z, 0.5)
			if r.is_empty():
				return
			s = r["escena"]
			await probar_pausa(s, z, z == "m406")
			memoria("zona_" + z)

	func _velocimetro() -> void:
		Catalogo.elegir_id("arteon_r_320_4motion")
		Ajustes.madrid_elegida = false
		Ajustes.cambiar_zona("navacerrada")
		Ajustes.piloto = false
		get_tree().change_scene_to_file("res://escenas/juego.tscn")
		var s := await esperar_partida()
		ok(s != null, "Navacerrada carga")
		if s == null:
			return
		# foto del HUD: velocidad puesta a mano (que la física llega a 270 km/h lo mide pruebas/prueba_vmax.gd)
		s.coche.v = 270.0 / 3.6
		s.coche.caja.marcha = 6
		await esperar(2)
		s.coche.v = 270.0 / 3.6
		s.pausado = true
		await esperar(4)
		ok(s.l_vel.text == "270 km/h", "el velocímetro muestra 270 km/h (texto: %s)" % s.l_vel.text)
		await foto("velocimetro_270")
