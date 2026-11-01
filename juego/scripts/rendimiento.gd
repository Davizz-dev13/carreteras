## Autoload "Rendimiento": que el juego arranque y vaya fluido en PCs distintos (solo escritorio; en la web no hace nada).
##  · Primera vez que se abre (sin user://paisaje.cfg): mira la gráfica, el driver, la RAM y los núcleos; si el PC es
##    flojo (gráfica integrada o por software, OpenGL de respaldo porque Vulkan/D3D12 no arrancó, < 8 GB de RAM o
##    < 4 núcleos) deja "Gráficos: bajo" de serie y lo guarda. Lo que el jugador elija después en el menú manda.
##  · Gráficos bajo (escritorio): sin sombras, sin MSAA, vista y árboles más cortos, materiales sencillos (eso último lo
##    hacen mundo.gd / ma_mundo.gd con Paisaje.graficos) y, si el PC se detectó flojo, resolución 3D al 80 %.
##  · Bajada automática (una sola vez): si en una partida con Gráficos alto la media de FPS se queda por debajo de 30
##    durante 10 s, pasa a "bajo", lo guarda y avisa en pantalla. Lo pesado (árboles, shaders) cambia al volver a cargar.
##  · Lo suyo (motivo, si ya bajó una vez) va en user://rendimiento.cfg; "Gráficos" en el de siempre (paisaje.cfg).
##  · Escribe user://diagnostico.txt (gráfica, driver, RAM…) para poder ver qué pasa en otro PC.
## Pruebas: -- --forzar_gpu_debil (como si fuera un PC flojo y la primera vez), -- --fps_falso=20 (FPS medidos de
## mentira), -- --cfg_graficos=user://prueba.cfg (otro archivo de opciones; no toca el de verdad).
## Con otros argumentos de prueba y sin estos, no decide nada solo ni guarda nada (las pruebas por software irían a
## pocos FPS y cambiarían las opciones de todos).
extends Node

const FPS_MINIMO := 30.0
const SEGUNDOS_MEDIDA := 10
const ESPERA_INICIO := 8.0     # s desde que empieza la partida antes de medir (carga de la ventana, shaders)
const LEJOS_BAJO := 8000.0     # m de vista con Gráficos bajo (zonas: 16 km; Madrid: 60 km)
const FACTOR_DIST_BAJO := 0.6  # árboles, señales, quitamiedos… se dejan de dibujar antes
const ESCALA_3D_DEBIL := 0.8
const PARTIDAS := ["res://escenas/juego.tscn", "res://escenas/madrid.tscn"]

var motivo_debil := ""         # por qué se puso "bajo" de serie (vacío = no se decidió solo)
var bajada_hecha := false      # la bajada automática por FPS ya ocurrió una vez
var _info := {}
var _escena: Node = null
var _t_escena := 0.0
var _muestras := PackedFloat32Array()
var _acum := 0.0
var _capa: CanvasLayer
var _aviso: Label
var _t_aviso := 0.0


func _ready() -> void:
	if OS.has_feature("web"):
		set_process(false)
		return
	_info = _datos_pc()
	var cf := ConfigFile.new()
	var hay := cf.load(archivo_opciones()) == OK and cf.has_section_key("paisaje", "graficos")
	if hay:
		Paisaje.graficos = str(cf.get_value("paisaje", "graficos", Paisaje.graficos))
	var cr := ConfigFile.new()
	if hay and cr.load(_archivo_propio()) == OK:
		motivo_debil = str(cr.get_value("rendimiento", "motivo", ""))
		bajada_hecha = bool(cr.get_value("rendimiento", "bajada_hecha", false))
	Paisaje.leer_opciones()
	if _decide_solo() and (not hay or Ajustes.args.has("forzar_gpu_debil")) and not Ajustes.args.has("graficos"):
		motivo_debil = _motivo_pc_flojo()
		bajada_hecha = false
		Paisaje.graficos = "bajo" if motivo_debil != "" else "alto"
		_guardar()
	print("Rendimiento: %s · %s (%s) · %s · RAM %.1f GB · %d núcleos → Gráficos %s%s" % [_info["driver"],
			_info["gpu"], _info["fabricante"], _info["tipo"], _info["ram_gb"], _info["nucleos"], Paisaje.graficos,
			(" (de serie: " + motivo_debil + ")") if motivo_debil != "" else ""])
	_escribir_diagnostico()
	get_tree().node_added.connect(_al_anadir)
	_aplicar_viewport()


## Archivo de opciones de gráficos (el de paisaje.gd; en pruebas, otro con --cfg_graficos)
func archivo_opciones() -> String:
	return str(Ajustes.args.get("cfg_graficos", Paisaje.OPCIONES))


func _archivo_propio() -> String:
	return archivo_opciones().get_basename() + "_rendimiento.cfg"


func graficos_altos() -> bool:
	Paisaje.leer_opciones()
	return OS.has_feature("web") or Paisaje.graficos != "bajo"


## Ligero = Gráficos bajo en el escritorio (la web se queda como siempre)
func ligero() -> bool:
	return not es_web() and not graficos_altos()


## Versión web (o, en pruebas de escritorio, -- --como_web: el mismo aspecto que la web, junto con --graficos=bajo)
func es_web() -> bool:
	return OS.has_feature("web") or Ajustes.args.has("como_web")


## Texto para el menú (debajo de la fila de Gráficos): por qué está en "bajo" si no lo eligió el jugador
func fila_nota() -> Label:
	var l := Label.new()
	l.modulate = Color(1, 0.85, 0.6)
	l.add_theme_font_size_override("font_size", 14)
	if not OS.has_feature("web") and Paisaje.graficos == "bajo":
		if bajada_hecha:
			l.text = "Gráficos en bajo porque el juego iba a menos de 30 FPS (puedes volver a alto)."
		elif motivo_debil != "":
			l.text = "Gráficos en bajo de serie: %s (puedes cambiarlo)." % motivo_debil
	l.visible = l.text != ""
	return l


func _decide_solo() -> bool:
	if DisplayServer.get_name() == "headless" or Engine.get_write_movie_path() != "":
		return false
	if OS.get_cmdline_user_args().is_empty():
		return true
	return Ajustes.args.has("forzar_gpu_debil") or Ajustes.args.has("fps_falso") or Ajustes.args.has("cfg_graficos")


func _guardar() -> void:
	# Gráficos y Estación: el mismo archivo y claves que paisaje.gd (lo que se elija luego en el menú lo pisa)
	var cf := ConfigFile.new()
	cf.load(archivo_opciones())
	cf.set_value("paisaje", "graficos", Paisaje.graficos)
	cf.set_value("paisaje", "estacion", Paisaje.estacion)
	cf.save(archivo_opciones())
	var cr := ConfigFile.new()
	cr.set_value("rendimiento", "motivo", motivo_debil)
	cr.set_value("rendimiento", "bajada_hecha", bajada_hecha)
	cr.save(_archivo_propio())


func _datos_pc() -> Dictionary:
	var mem := OS.get_memory_info()
	var ram := float(mem.get("physical", -1))
	var tipos := {RenderingDevice.DEVICE_TYPE_OTHER: "otra", RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU: "integrada",
			RenderingDevice.DEVICE_TYPE_DISCRETE_GPU: "dedicada", RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU: "virtual",
			RenderingDevice.DEVICE_TYPE_CPU: "por software"}
	return {"gpu": RenderingServer.get_video_adapter_name(), "fabricante": RenderingServer.get_video_adapter_vendor(),
			"tipo": tipos.get(RenderingServer.get_video_adapter_type(), "?"),
			"version_api": RenderingServer.get_video_adapter_api_version(),
			"driver": RenderingServer.get_current_rendering_driver_name(),
			"metodo": RenderingServer.get_current_rendering_method(),
			"ram_gb": ram / 1073741824.0 if ram > 0 else -1.0, "nucleos": OS.get_processor_count(),
			"cpu": OS.get_processor_name(), "so": OS.get_name() + " " + OS.get_version()}


## Vacío si el PC parece capaz de Gráficos alto; si no, el motivo (para el menú y el diagnóstico)
func _motivo_pc_flojo() -> String:
	if Ajustes.args.has("forzar_gpu_debil"):
		return "prueba de PC flojo"
	var g := str(_info["gpu"]).to_lower()
	for s in ["llvmpipe", "softpipe", "swiftshader", "microsoft basic render", "gdi generic", "lavapipe"]:
		if g.contains(s):
			return "gráfica por software"
	# en Windows el juego usa Forward+ (Vulkan/D3D12): si ha arrancado con OpenGL es que esos no fueron
	if OS.has_feature("windows") and str(_info["metodo"]) == "gl_compatibility":
		return "la gráfica no arrancó con Vulkan/Direct3D 12 (va con OpenGL)"
	if _info["tipo"] == "integrada" or _integrada_por_nombre(g):
		return "gráfica integrada"
	if _info["ram_gb"] > 0.0 and _info["ram_gb"] < 7.0:
		return "menos de 8 GB de RAM"
	if int(_info["nucleos"]) < 4:
		return "menos de 4 núcleos"
	return ""


## Con OpenGL Godot no dice el tipo de gráfica: se mira el nombre (Intel HD/UHD/Iris, Radeon de los APU de AMD…)
func _integrada_por_nombre(g: String) -> bool:
	if g.contains("intel") and not g.contains("arc"):
		return true
	for s in ["radeon(tm) graphics", "radeon graphics", "vega 3", "vega 6", "vega 7", "vega 8", "vega 10", "vega 11",
			"radeon 610m", "radeon 660m", "radeon 680m", "radeon 740m", "radeon 760m", "radeon 780m", "radeon 880m",
			"radeon 890m", "mali", "adreno", "powervr", "apple m", "uhd graphics", "iris"]:
		if g.contains(s):
			return true
	return false


func _escribir_diagnostico() -> void:
	var f := FileAccess.open("user://diagnostico.txt", FileAccess.WRITE)
	if f == null:
		return
	f.store_line("Carreteras · diagnóstico del PC (se reescribe cada vez que se abre el juego)")
	f.store_line(Time.get_datetime_string_from_system())
	for k in ["so", "cpu", "nucleos", "ram_gb", "gpu", "fabricante", "tipo", "driver", "metodo", "version_api"]:
		f.store_line("%s: %s" % [k, str(_info[k])])
	f.store_line("graficos: %s · motivo de serie: %s · bajada por FPS: %s" % [Paisaje.graficos, motivo_debil, bajada_hecha])


# ------------------------------------------------------------------ Gráficos bajo en lo que se va creando
func _aplicar_viewport() -> void:
	var vp := get_viewport()
	if ligero():
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.scaling_3d_scale = ESCALA_3D_DEBIL if motivo_debil != "" else 1.0
	else:
		vp.msaa_3d = ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d", 0)
		vp.scaling_3d_scale = 1.0


## Cada nodo que entra en el árbol: con Gráficos bajo se abaratan sol, cámara, niebla y distancias de dibujo.
## Se aplica diferido para ir después del código que lo configura (suele poner sus valores tras add_child).
func _al_anadir(n: Node) -> void:
	if not ligero():
		return
	if n is DirectionalLight3D or n is Camera3D or n is WorldEnvironment:
		_abaratar.call_deferred(n)
	elif n is GeometryInstance3D:
		_acortar.call_deferred(n)


func _abaratar(n: Node) -> void:
	if not is_instance_valid(n):
		return
	if n is DirectionalLight3D:
		(n as DirectionalLight3D).shadow_enabled = false
	elif n is Camera3D:
		var c := n as Camera3D
		c.far = minf(c.far, LEJOS_BAJO)
	elif n is WorldEnvironment:
		var e: Environment = (n as WorldEnvironment).environment
		if e != null and e.fog_enabled and e.fog_mode == Environment.FOG_MODE_DEPTH:
			# que la niebla cierre antes del nuevo final de la vista (sin corte duro en el horizonte)
			e.fog_depth_end = minf(e.fog_depth_end, LEJOS_BAJO * 0.95)
			e.fog_depth_begin = minf(e.fog_depth_begin, e.fog_depth_end * 0.15)
			e.fog_depth_curve = minf(e.fog_depth_curve, 1.0)


## Solo lo pequeño (árboles, marcas, señales, quitamiedos: hasta 2 km); las calzadas y el terreno, igual
func _acortar(n: Node) -> void:
	if not is_instance_valid(n) or n.has_meta("_corto"):
		return
	var g := n as GeometryInstance3D
	if g.visibility_range_end <= 0.0 or g.visibility_range_end > 2000.0:
		return
	n.set_meta("_corto", true)
	g.visibility_range_end *= FACTOR_DIST_BAJO
	g.visibility_range_begin *= FACTOR_DIST_BAJO


# ------------------------------------------------------------------ bajada automática por FPS (una vez)
func _process(dt: float) -> void:
	if _aviso != null and _t_aviso > 0.0:
		_t_aviso -= dt
		_aviso.modulate.a = clampf(_t_aviso, 0.0, 1.0)
		if _t_aviso <= 0.0:
			_capa.visible = false
	if OS.has_feature("web"):
		return
	# en "bajo", el plano lejano se queda en 8 km aunque otro script lo alargue después de crear la cámara
	if not graficos_altos():
		var cam := get_viewport().get_camera_3d()
		if cam != null and cam.far > LEJOS_BAJO and Ajustes.args.get("captura", "") != "menu":
			cam.far = LEJOS_BAJO
	var esc := get_tree().current_scene
	if esc != _escena:
		# escena nueva (menú → partida): la opción de Gráficos puede haber cambiado en el menú
		_escena = esc
		_t_escena = 0.0
		_muestras.clear()
		_acum = 0.0
		_aplicar_viewport()
	if bajada_hecha or Paisaje.graficos != "alto" or not _decide_solo():
		return
	if not _en_partida(esc):
		_muestras.clear()
		return
	# en pausa o con la ventana en segundo plano no se mide (en las pruebas con --fps_falso, bajo Xvfb sin gestor de
	# ventanas, la ventana nunca tiene el foco)
	if get_tree().paused or (not DisplayServer.window_is_focused() and not Ajustes.args.has("fps_falso")):
		_muestras.clear()
		return
	_t_escena += dt
	if _t_escena < ESPERA_INICIO:
		return
	_acum += dt
	if _acum < 1.0:
		return
	_acum = 0.0
	var fps := float(Ajustes.args.get("fps_falso", Engine.get_frames_per_second()))
	_muestras.append(fps)
	if _muestras.size() > SEGUNDOS_MEDIDA:
		_muestras.remove_at(0)
	if _muestras.size() < SEGUNDOS_MEDIDA:
		return
	var suma := 0.0
	for f in _muestras:
		suma += f
	if suma / SEGUNDOS_MEDIDA < FPS_MINIMO:
		_bajar(suma / SEGUNDOS_MEDIDA)


## La partida es la escena actual (o, en las pruebas, una hija suya): zonas o mapa abierto de Madrid
func _en_partida(esc: Node) -> bool:
	if esc == null:
		return false
	if esc.scene_file_path in PARTIDAS:
		return true
	for h in esc.get_children():
		if h.scene_file_path in PARTIDAS:
			return true
	return false


func _bajar(media: float) -> void:
	bajada_hecha = true
	Paisaje.graficos = "bajo"
	_guardar()
	print("Rendimiento: media de %.1f FPS en %d s con Gráficos alto → bajo (guardado)" % [media, SEGUNDOS_MEDIDA])
	# lo que se puede cambiar en marcha: MSAA, sombras, vista y niebla; árboles y shaders, al volver a cargar
	_aplicar_viewport()
	for n in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
		_abaratar(n)
	for n in get_tree().root.find_children("*", "Camera3D", true, false):
		_abaratar(n)
	for n in get_tree().root.find_children("*", "WorldEnvironment", true, false):
		_abaratar(n)
	_avisar("Gráficos bajados a bajo por rendimiento")
	_escribir_diagnostico()


func _avisar(texto: String) -> void:
	if _capa == null:
		_capa = CanvasLayer.new()
		_capa.layer = 100
		add_child(_capa)
		_aviso = Label.new()
		_aviso.add_theme_font_size_override("font_size", 22)
		_aviso.add_theme_color_override("font_outline_color", Color.BLACK)
		_aviso.add_theme_constant_override("outline_size", 6)
		_aviso.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_aviso.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_aviso.position.y = 90
		_capa.add_child(_aviso)
	_aviso.text = texto
	_aviso.reset_size()
	_aviso.position.x = (get_viewport().get_visible_rect().size.x - _aviso.size.x) * 0.5
	_capa.visible = true
	_t_aviso = 6.0
