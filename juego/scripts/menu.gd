## Menú inicial: carretera, tramo (km inicio → km fin) con su perfil real, velocidad, piloto automático y tráfico.
extends Control

var lista_zonas := OptionButton.new()
var lista_rutas := OptionButton.new()
var perfil := Perfil.new()
var km_ini := HSlider.new()
var km_fin := HSlider.new()
var vel := HSlider.new()
var traf := HSlider.new()
var chk_piloto := CheckBox.new()
var chk_curvas := CheckBox.new()
var chk_limite_adel := CheckBox.new()
var chk_piloto_lim := CheckBox.new()
var camara := OptionButton.new()
var info := Label.new()
var lbl_ini := Label.new()
var lbl_fin := Label.new()
var lbl_vel := Label.new()
var lbl_traf := Label.new()
var lista_coches := OptionButton.new()
var lista_colores := OptionButton.new()
var ficha_txt := Label.new()
var boton_empezar: Button


func _ready() -> void:
	Ajustes.cargar()
	var fondo := ColorRect.new()
	fondo.color = Color(0.09, 0.11, 0.13)
	fondo.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(fondo)
	var marco := MarginContainer.new()
	marco.set_anchors_preset(Control.PRESET_FULL_RECT)
	for lado in ["left", "right", "top", "bottom"]:
		marco.add_theme_constant_override("margin_" + lado, 28)
	add_child(marco)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	marco.add_child(col)
	var titulo := Label.new()
	titulo.text = "Carreteras de España · escala 1:1"
	titulo.add_theme_font_size_override("font_size", 30)
	col.add_child(titulo)
	var sub := Label.new()
	sub.text = "Trazado real de OpenStreetMap · altitud real del MDT del IGN · zona: %s" % Ajustes.zona
	sub.modulate = Color(0.75, 0.8, 0.85)
	col.add_child(sub)
	# zona (cada una con su terreno y sus carreteras; cambiarla recarga el menú)
	var fila_z := HBoxContainer.new()
	fila_z.add_child(_etq("Zona:", 140))
	var claves := Ajustes.ZONAS.keys()
	for k in claves:
		lista_zonas.add_item(Ajustes.ZONAS[k])
	lista_zonas.selected = maxi(claves.find(Ajustes.zona), 0)
	lista_zonas.custom_minimum_size.x = 520
	lista_zonas.item_selected.connect(func(i):
		Ajustes.cambiar_zona(claves[i])
		get_tree().reload_current_scene())
	fila_z.add_child(lista_zonas)
	col.add_child(fila_z)
	# carretera
	var fila := HBoxContainer.new()
	fila.add_child(_etq("Carretera:", 140))
	for r in Ajustes.rutas:
		lista_rutas.add_item(("%s  (%.1f km)" % [r.nombre, r.longitud() / 1000.0]).replace(".", ","))
	lista_rutas.custom_minimum_size.x = 520
	lista_rutas.item_selected.connect(_al_cambiar_ruta)
	fila.add_child(lista_rutas)
	col.add_child(fila)
	# coche (real, con su ficha técnica)
	var fila_c := HBoxContainer.new()
	fila_c.add_child(_etq("Coche:", 140))
	for f in Catalogo.fichas:
		lista_coches.add_item("%s %s" % [f.marca, f.nombre])
	lista_coches.custom_minimum_size.x = 420
	lista_coches.item_selected.connect(_al_cambiar_coche)
	fila_c.add_child(lista_coches)
	fila_c.add_child(_etq("   Color:", 70))
	lista_colores.custom_minimum_size.x = 250
	lista_colores.item_selected.connect(func(i): Catalogo.color_elegido = i)
	fila_c.add_child(lista_colores)
	col.add_child(fila_c)
	ficha_txt.add_theme_font_size_override("font_size", 14)
	ficha_txt.modulate = Color(0.7, 0.9, 1.0)
	ficha_txt.autowrap_mode = TextServer.AUTOWRAP_WORD
	col.add_child(ficha_txt)
	lista_coches.selected = Catalogo.elegida
	_al_cambiar_coche(Catalogo.elegida)
	perfil.custom_minimum_size = Vector2(0, 150)
	col.add_child(perfil)
	col.add_child(_fila_slider("Km inicio:", km_ini, lbl_ini))
	col.add_child(_fila_slider("Km fin:", km_fin, lbl_fin))
	info.add_theme_font_size_override("font_size", 16)
	info.modulate = Color(1, 0.85, 0.6)
	col.add_child(info)
	vel.min_value = 20
	vel.max_value = 150
	vel.step = 5
	vel.value = Ajustes.velocidad
	col.add_child(_fila_slider("Velocidad:", vel, lbl_vel))
	traf.min_value = 0
	traf.max_value = 100
	traf.step = 5
	traf.value = Ajustes.trafico * 100.0
	col.add_child(_fila_slider("Tráfico:", traf, lbl_traf))
	var opciones := HBoxContainer.new()
	opciones.add_theme_constant_override("separation", 24)
	chk_piloto.text = "Piloto automático (sigue su carril a la velocidad elegida)"
	chk_piloto.button_pressed = Ajustes.piloto
	chk_curvas.text = "Adaptar velocidad en curvas"
	chk_curvas.button_pressed = Ajustes.adaptar_curvas
	opciones.add_child(chk_piloto)
	opciones.add_child(chk_curvas)
	chk_limite_adel.text = "Respetar límite al adelantar"
	chk_limite_adel.tooltip_text = "Si está marcado, al adelantar no pasa del límite de velocidad del tramo (y si así no le da, no adelanta)"
	chk_limite_adel.button_pressed = Ajustes.limite_adelantar
	opciones.add_child(chk_limite_adel)
	chk_piloto_lim.text = "Piloto respeta límites de velocidad"
	chk_piloto_lim.tooltip_text = "Si está marcado, el piloto automático no pasa del límite de cada tramo; si no, va a la velocidad elegida (frenando igual en las curvas)"
	chk_piloto_lim.button_pressed = Ajustes.piloto_limites
	opciones.add_child(chk_piloto_lim)
	camara.add_item("Cámara de persecución")
	camara.add_item("Cámara de cabina")
	camara.selected = Ajustes.camara
	opciones.add_child(camara)
	col.add_child(opciones)
	var boton := Button.new()
	boton.text = "  ¡A conducir!  "
	boton.add_theme_font_size_override("font_size", 22)
	boton.pressed.connect(_empezar)
	boton_empezar = boton
	var fila_b := HBoxContainer.new()
	fila_b.add_child(boton)
	var ayuda := Label.new()
	ayuda.text = "   Si la velocidad es mayor de la que permite una curva y no adaptas, el coche se sale (física real)."
	ayuda.modulate = Color(0.7, 0.75, 0.8)
	fila_b.add_child(ayuda)
	col.add_child(fila_b)
	var mandos := Label.new()
	mandos.text = ("Mandos en carretera: W/↑ acelerar · S/↓ frenar (parado: marcha atrás) · " +
		"P piloto automático · O adelantar (con el piloto) · L respetar límite al adelantar · +/− velocidad · K adaptar en curvas · 9/0 menos/más tráfico · " +
		"V cámara · R volver a la carretera · Esc pausa (tráfico y velocidad) · H ayuda\n" +
		"Mando de PS4: R2 acelerar · L2 frenar (parado: marcha atrás) · joystick izquierdo girar · ✕ freno de mano · △ piloto · □ adelantar · " +
		"R1 límite al adelantar · L1 curvas · cruceta ↑↓ velocidad y ←→ tráfico · ○ cámara · L3/R3 volver a la carretera · OPTIONS pausa · SHARE ayuda. " +
		"En el navegador, pulsa un botón del mando para que lo detecte; en este menú, cruceta para moverte y ✕ para elegir.")
	mandos.autowrap_mode = TextServer.AUTOWRAP_WORD
	mandos.modulate = Color(0.65, 0.7, 0.75)
	col.add_child(mandos)
	var fuentes := Label.new()
	fuentes.text = "Datos: © colaboradores de OpenStreetMap (ODbL) · MDT05 © Instituto Geográfico Nacional (CC BY 4.0) · ETRS89 UTM 30N, 1 unidad = 1 metro · Modelo 3D del Arteon: MattDoesBlender (CC BY 4.0)"
	fuentes.modulate = Color(0.5, 0.55, 0.6)
	fuentes.add_theme_font_size_override("font_size", 12)
	col.add_child(fuentes)
	for s in [km_ini, km_fin, vel, traf]:
		s.value_changed.connect(func(_v): _refrescar())
	lista_rutas.selected = Ajustes.ruta_idx
	_al_cambiar_ruta(Ajustes.ruta_idx)
	# mando: con uno conectado, el foco empieza en "¡A conducir!" (cruceta para moverse, ✕ para pulsar)
	Input.joy_connection_changed.connect(_al_cambiar_mando)
	if not Input.get_connected_joypads().is_empty():
		_foco_mando()
	if Ajustes.args.has("captura") and Ajustes.args["captura"] == "menu":
		_captura_menu()


func _al_cambiar_mando(_id: int, conectado: bool) -> void:
	if conectado:
		_foco_mando()


func _foco_mando() -> void:
	if get_viewport().gui_get_focus_owner() == null and boton_empezar:
		boton_empezar.grab_focus.call_deferred()


## Con el mando aún no detectado (el navegador lo da al pulsar un botón), cualquier botón o la cruceta lo despierta
func _input(ev: InputEvent) -> void:
	if (ev is InputEventJoypadButton and ev.pressed) or (ev is InputEventJoypadMotion and absf(ev.axis_value) > 0.5):
		_foco_mando()


func _etq(t: String, ancho: float) -> Label:
	var l := Label.new()
	l.text = t
	l.custom_minimum_size.x = ancho
	return l


func _fila_slider(t: String, s: HSlider, lbl: Label) -> HBoxContainer:
	var f := HBoxContainer.new()
	f.add_child(_etq(t, 140))
	s.custom_minimum_size.x = 640
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	f.add_child(s)
	lbl.custom_minimum_size.x = 200
	f.add_child(lbl)
	return f


func _al_cambiar_coche(i: int) -> void:
	Catalogo.elegida = i
	var f := Catalogo.ficha_elegida()
	lista_colores.clear()
	for c in Catalogo.colores(f):
		var img := Image.create(16, 16, false, Image.FORMAT_RGB8)
		img.fill(Color.html(c["hex"]))
		lista_colores.add_icon_item(ImageTexture.create_from_image(img), c["nombre"])
	lista_colores.selected = clampi(Catalogo.color_elegido, 0, lista_colores.item_count - 1)
	var fuente := ""
	var fu: Array = f.datos.get("fuentes", [])
	if not fu.is_empty():
		fuente = String(fu[0]["url"]).replace("https://", "").replace("www.", "").get_slice("/", 0)
	ficha_txt.text = ("%d CV (%d kW) · %d Nm · %d kg · %s · %s · 0-100 km/h en %s s · vel. máx. %d km/h%s\n" +
		"%d × %d × %d mm · batalla %d mm · Cx %s   |   ficha real: %s (fuentes en datos/coches/coches.json) · 0-100 simulado en llano: %s s") % [
		roundi(f.potencia_cv), roundi(f.potencia_kw), roundi(f.par), roundi(f.masa), f.traccion, f.cambio,
		("%.1f" % f.t_0_100).replace(".", ","), roundi(f.v_max_kmh), " (limitada)" if f.limitada else "",
		roundi(f.largo * 1000), roundi(f.ancho * 1000), roundi(f.alto * 1000), roundi(f.batalla * 1000),
		("%.3f" % f.cx).replace(".", ","), fuente, ("%.1f" % f.t_0_100_sim).replace(".", ",")]


func _al_cambiar_ruta(i: int) -> void:
	Ajustes.ruta_idx = i
	var r := Ajustes.ruta()
	var L := r.longitud() / 1000.0
	for s in [km_ini, km_fin]:
		s.min_value = 0.0
		s.max_value = snappedf(L, 0.1)
		s.step = 0.1
	km_ini.value = 0.0
	km_fin.value = snappedf(L, 0.1)
	perfil.ruta = r
	_refrescar()


func _refrescar() -> void:
	var r := Ajustes.ruta()
	perfil.s0 = km_ini.value * 1000.0
	perfil.s1 = km_fin.value * 1000.0
	perfil.queue_redraw()
	lbl_ini.text = ("km %.1f · %d m" % [km_ini.value, roundi(r.punto(perfil.s0).y)]).replace(".", ",")
	lbl_fin.text = ("km %.1f · %d m" % [km_fin.value, roundi(r.punto(perfil.s1).y)]).replace(".", ",")
	lbl_vel.text = "%d km/h" % roundi(vel.value)
	lbl_traf.text = "%d %%" % roundi(traf.value) + ("  (sin tráfico)" if traf.value == 0 else "")
	var t := r.resumen_tramo(perfil.s0, perfil.s1)
	var sentido := "subiendo" if t["z_fin"] > t["z_ini"] else "bajando"
	info.text = "Tramo: %.2f km (%s) · de %d a %d m · desnivel +%d / −%d m · pendiente máx (100 m): %.1f %%%s" % [
		t["longitud"] / 1000.0, sentido, roundi(t["z_ini"]), roundi(t["z_fin"]), roundi(t["sube"]), roundi(t["baja"]),
		t["pendiente_max"], "  · sentido contrario a la ruta" if perfil.s1 < perfil.s0 else ""]
	info.text = info.text.replace(".", ",")


func _empezar() -> void:
	if absf(km_fin.value - km_ini.value) < 0.2:
		info.text = "Elige un tramo de al menos 200 m."
		return
	Ajustes.km_ini = km_ini.value
	Ajustes.km_fin = km_fin.value
	Ajustes.velocidad = vel.value
	Ajustes.trafico = traf.value / 100.0
	Ajustes.piloto = chk_piloto.button_pressed
	Ajustes.adaptar_curvas = chk_curvas.button_pressed
	Ajustes.limite_adelantar = chk_limite_adel.button_pressed
	Ajustes.piloto_limites = chk_piloto_lim.button_pressed
	Ajustes.camara = camara.selected
	get_tree().change_scene_to_file("res://escenas/juego.tscn")


## Verificación automática: captura del menú con un tramo elegido
func _captura_menu() -> void:
	km_ini.value = float(Ajustes.args.get("km_ini", "1.5"))
	km_fin.value = float(Ajustes.args.get("km_fin", "10.3"))
	vel.value = float(Ajustes.args.get("vel", "70"))
	traf.value = float(Ajustes.args.get("trafico", "40"))
	for i in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(Ajustes.args.get("salida", "user://menu.png"))
	get_tree().quit()
