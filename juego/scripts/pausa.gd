## Menú de pausa del mapa abierto de la Comunidad de Madrid (Esc / OPTIONS del mando): Continuar, las opciones que se
## pueden cambiar en marcha, Cambiar de carretera (mapa de viaje, mapa_viaje.gd), Menú principal y Salir del juego.
## Mismo aspecto y mismos botones que la pausa de las carreteras (juego.gd). Con la pausa abierta ma_juego.gd no
## simula (ni el coche ni el tráfico) y el motor calla; Esc u OPTIONS otra vez siguen.
class_name MenuPausa
extends CanvasLayer

signal cambio(abierto: bool)

var abierto := false
var panel := PanelContainer.new()
var b_continuar := Button.new()
var mapa_viaje: MapaViaje = null
var aqui := Vector2.INF            # dónde está el coche (UTM), para el mapa de viaje
var zona_actual := Ajustes.ZONA_MADRID

var _l_traf := Label.new()
var _sl_traf := HSlider.new()
var _l_vel := Label.new()
var _sl_vel := HSlider.new()
var _l_vol := Label.new()
var _sl_vol := HSlider.new()
var _ck_curvas := CheckButton.new()
var _ck_limites := CheckButton.new()
var _ob_camara := OptionButton.new()


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	var t := Label.new()
	t.text = "Pausa"
	t.add_theme_font_size_override("font_size", 28)
	v.add_child(t)
	b_continuar.text = "Continuar"
	b_continuar.pressed.connect(func(): abrir(false))
	v.add_child(b_continuar)
	var to := Label.new()
	to.text = "Opciones"
	to.add_theme_font_size_override("font_size", 20)
	to.modulate = Color(0.75, 0.85, 0.95)
	v.add_child(to)
	for par in [[_sl_traf, _l_traf, 0.0, 100.0, 5.0], [_sl_vel, _l_vel, 20.0, 200.0, 10.0], [_sl_vol, _l_vol, 0.0, 100.0, 5.0]]:
		var s: HSlider = par[0]
		s.min_value = par[2]
		s.max_value = par[3]
		s.step = par[4]
		s.custom_minimum_size.x = 380
		v.add_child(par[1])
		v.add_child(s)
	_sl_traf.value_changed.connect(func(x: float):
		Ajustes.trafico = x / 100.0
		_l_traf.text = "Tráfico: %d %%" % roundi(x))
	_sl_vel.value_changed.connect(func(x: float):
		Ajustes.velocidad = x
		_l_vel.text = "Velocidad del piloto: %d km/h" % roundi(x))
	_sl_vol.value_changed.connect(func(x: float):
		Ajustes.volumen_motor = x / 100.0
		Ajustes.silencio = x <= 0.0
		_l_vol.text = "Volumen del motor: %d %%" % roundi(x))
	_ck_curvas.text = "Piloto: frenar antes de las curvas"
	_ck_curvas.toggled.connect(func(on: bool): Ajustes.adaptar_curvas = on)
	v.add_child(_ck_curvas)
	_ck_limites.text = "Piloto: respetar los límites de velocidad"
	_ck_limites.toggled.connect(func(on: bool): Ajustes.piloto_limites = on)
	v.add_child(_ck_limites)
	_ob_camara.add_item("Cámara de persecución")
	_ob_camara.add_item("Cámara de cabina")
	_ob_camara.item_selected.connect(func(i: int): Ajustes.camara = i)
	v.add_child(_ob_camara)
	var b_cambiar := Button.new()
	b_cambiar.text = "Cambiar de carretera (mapa)"
	b_cambiar.pressed.connect(abrir_mapa)
	var b_menu := Button.new()
	b_menu.text = "Menú principal"
	b_menu.pressed.connect(func(): get_tree().change_scene_to_file("res://escenas/menu.tscn"))
	var b_salir := Button.new()
	b_salir.text = "Salir del juego"
	b_salir.pressed.connect(func(): get_tree().quit())
	for b in [b_cambiar, b_menu, b_salir]:
		v.add_child(b)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.09, 0.9)
	sb.set_content_margin_all(22)
	sb.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	panel.add_child(v)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)
	panel.visible = false


func abrir(on: bool) -> void:
	if mapa_viaje != null and mapa_viaje.visible:
		mapa_viaje.visible = false
	abierto = on
	panel.visible = on
	if on:
		_sl_traf.set_value_no_signal(Ajustes.trafico * 100.0)
		_l_traf.text = "Tráfico: %d %%" % roundi(Ajustes.trafico * 100.0)
		_sl_vel.set_value_no_signal(Ajustes.velocidad)
		_l_vel.text = "Velocidad del piloto: %d km/h" % roundi(Ajustes.velocidad)
		_sl_vol.set_value_no_signal(Ajustes.volumen_motor * 100.0)
		_l_vol.text = "Volumen del motor: %d %%%s" % [roundi(Ajustes.volumen_motor * 100.0), " (silenciado, N)" if Ajustes.silencio else ""]
		_ck_curvas.set_pressed_no_signal(Ajustes.adaptar_curvas)
		_ck_limites.set_pressed_no_signal(Ajustes.piloto_limites)
		_ob_camara.selected = Ajustes.camara
		if not Input.get_connected_joypads().is_empty():
			b_continuar.grab_focus.call_deferred()      # con el mando: cruceta para moverse, ✕ para elegir
	else:
		panel.get_viewport().gui_release_focus()
	cambio.emit(on)


func viendo_mapa() -> bool:
	return mapa_viaje != null and mapa_viaje.visible


func abrir_mapa() -> void:
	if mapa_viaje == null:
		mapa_viaje = MapaViaje.new()
		add_child(mapa_viaje)
		mapa_viaje.cerrado.connect(func() -> void:
			panel.visible = abierto
			if abierto: b_continuar.grab_focus.call_deferred())
	mapa_viaje.aqui = aqui
	mapa_viaje.visible = true
	mapa_viaje.centrar_en(zona_actual)
	panel.visible = false
	mapa_viaje.enfocar()
