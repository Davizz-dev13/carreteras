## Pantalla de carga del viaje pinchando en el mapa (mapa_viaje.gd): pinta "Viajando a…", carga la zona y abre su escena
## con el coche en el punto elegido (Ajustes.aplicar_viaje para las carreteras; ma_juego.gd para el mapa abierto).
extends Control


func _ready() -> void:
	var z := str(Ajustes.viaje.get("zona", Ajustes.zona))
	var fondo := ColorRect.new()
	fondo.color = Color(0.09, 0.11, 0.13)
	fondo.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(fondo)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_CENTER)
	v.grow_horizontal = Control.GROW_DIRECTION_BOTH
	v.grow_vertical = Control.GROW_DIRECTION_BOTH
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	fondo.add_child(v)
	var t := Label.new()
	t.text = "Viajando a " + str(Ajustes.viaje.get("texto", Ajustes.NOMBRE_MADRID if z == Ajustes.ZONA_MADRID else Ajustes.ZONAS.get(z, z))).replace("\n", " · ")
	t.add_theme_font_size_override("font_size", 26)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var s := Label.new()
	s.text = "Cargando terreno y carreteras… puede tardar unos segundos."
	s.modulate = Color(0.7, 0.78, 0.85)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(s)
	for i in 3:
		await get_tree().process_frame
	if DisplayServer.get_name() != "headless":      # sin pantalla no se dibuja y frame_post_draw no llega
		await RenderingServer.frame_post_draw
	Ajustes.args.erase("zona")          # el viaje manda sobre --zona de la línea de órdenes
	if z == Ajustes.ZONA_MADRID:
		Ajustes.madrid_elegida = true
		get_tree().change_scene_to_file("res://escenas/madrid.tscn")
		return
	Ajustes.madrid_elegida = false
	Ajustes.cambiar_zona(z)
	Ajustes.cargar()
	Ajustes.aplicar_viaje()
	get_tree().change_scene_to_file("res://escenas/juego.tscn")
