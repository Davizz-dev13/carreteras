## Mapa de viaje ("Cambiar de carretera"): España con las carreteras de cada zona del juego. Pinchando en una carretera
## (de esta zona o de otra) se carga esa zona y el coche sale en el punto de carretera más cercano, mirando a lo largo
## de ella (Ajustes.viaje → escenas/viaje.tscn → juego.tscn / madrid.tscn). Lo abren el menú de pausa (juego.gd,
## pausa.gd) y el menú principal.
## Ratón: rueda = zoom · arrastrar = mover · clic = elegir punto · doble clic o Intro = viajar · Esc = cerrar.
## Mando / teclado: los botones de zona (cruceta + ✕) acercan la vista y eligen el comienzo de su carretera principal.
## Datos (pipeline: los genera _viaje.py desde los datos de cada zona; UTM 30N en metros):
##   datos/viaje_espana.json   contorno de España y vecinos (Natural Earth 1:10m, dominio público)
##   datos/<zona>/viaje.json   rutas jugables y vías secundarias simplificadas
##   datos/madrid/viaje.json   red interurbana del mapa abierto (solo .exe: en la web no va datos/madrid)
class_name MapaViaje
extends Control

signal cerrado

const ORDEN := ["madrid", "navacerrada", "m406", "a308", "gr8101"]
const COLOR_ZONA := {"madrid": Color(0.98, 0.78, 0.3), "navacerrada": Color(0.35, 0.85, 1.0), "m406": Color(0.55, 1.0, 0.45),
	"a308": Color(1.0, 0.5, 0.42), "gr8101": Color(0.85, 0.55, 1.0)}
const ANCHO_PANEL := 380.0
const TOL_PX := 14.0        # píxeles: distancia máxima del clic a una carretera para elegirla

var zonas: Array = []       # [{clave, nombre, rutas: [{nombre, p}], vias: [p], madrid: [[clase, p]], caja: Rect2}]
var contorno: Array = []    # [{pais, p: PackedVector2Array}]
var ciudades: Array = []    # [[nombre, Vector2 UTM]] (capitales de provincia y alguna más, como referencia)
var centro := Vector2(440000.0, 4300000.0)   # UTM (E, N) del centro del lienzo
var escala := 1800.0        # metros por píxel
var elegido := {}           # {zona, e, n, texto}
var aqui := Vector2.INF     # dónde está el coche ahora (UTM), si se sabe
var desde_menu := false     # abierto desde el menú principal (sin partida)
var preferida := ""         # zona elegida con su botón: sus carreteras ganan a las de otra zona superpuesta

var _l_info := Label.new()
var _b_viajar := Button.new()
var _b_cerrar := Button.new()
var _botones: Array[Button] = []
var _arrastre := false
var _movido := 0.0
var _cargando := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_leer_datos()
	_crear_panel()
	_ver_todo()


## UTM → píxel del lienzo
## Tamaño del lienzo: el del control o, si aún no lo tiene (recién añadido a una CanvasLayer), el de la ventana
func _tam() -> Vector2:
	return size if size.x > ANCHO_PANEL + 100.0 and size.y > 200.0 else get_viewport_rect().size


func a_pantalla(u: Vector2) -> Vector2:
	var t := _tam()
	var c := Vector2(ANCHO_PANEL + (t.x - ANCHO_PANEL) * 0.5, t.y * 0.5)
	return c + Vector2(u.x - centro.x, centro.y - u.y) / escala


func a_utm(s: Vector2) -> Vector2:
	var t := _tam()
	var c := Vector2(ANCHO_PANEL + (t.x - ANCHO_PANEL) * 0.5, t.y * 0.5)
	var d := (s - c) * escala
	return Vector2(centro.x + d.x, centro.y - d.y)


static func _poli(a: Array) -> PackedVector2Array:
	var p := PackedVector2Array()
	p.resize(a.size() / 2)
	for i in p.size():
		p[i] = Vector2(float(a[2 * i]), float(a[2 * i + 1]))
	return p


static func _leer(camino: String):
	if not FileAccess.file_exists(camino):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(camino))


func _leer_datos() -> void:
	var esp = _leer("res://datos/viaje_espana.json")
	if esp is Dictionary:
		for pg in esp["poligonos"]:
			contorno.append({"pais": str(pg["pais"]), "p": _poli(pg["p"])})
		for c in esp.get("ciudades", []):
			ciudades.append([str(c["n"]), Vector2(float(c["e"]), float(c["nn"]))])
	for clave in ORDEN:
		var z := {"clave": clave, "rutas": [], "vias": [], "madrid": [], "caja": Rect2()}
		if clave == Ajustes.ZONA_MADRID:
			if not Ajustes.hay_madrid():
				continue
			z["nombre"] = Ajustes.NOMBRE_MADRID
			var d = _leer("res://datos/madrid/viaje.json")
			if not (d is Dictionary):
				continue
			for l in d["lineas"]:
				var c := int(l[0])
				z["madrid"].append([c, _poli(l.slice(1))])
		else:
			if not Ajustes.ZONAS.has(clave):
				continue
			z["nombre"] = Ajustes.ZONAS[clave]
			var d = _leer("res://datos/%s/viaje.json" % clave)
			if not (d is Dictionary):
				continue
			for r in d["rutas"]:
				z["rutas"].append({"nombre": str(r["nombre"]), "p": _poli(r["p"])})
			for v in d["vias"]:
				z["vias"].append(_poli(v))
		z["madrid_clase"] = [[], [], [], [], []]
		z["madrid_cajas"] = [[], [], [], [], []]
		for m in z["madrid"]:
			var cl := clampi(int(m[0]), 0, 4)
			z["madrid_clase"][cl].append(m[1])
			z["madrid_cajas"][cl].append(_caja(m[1]))
		z["cajas_vias"] = z["vias"].map(func(p): return _caja(p))
		var caja := Rect2()
		var primero := true
		for lista in [z["rutas"].map(func(r): return r["p"]), z["madrid"].map(func(m): return m[1])]:
			for p: PackedVector2Array in lista:
				for q in p:
					if primero:
						caja = Rect2(q, Vector2.ZERO)
						primero = false
					else:
						caja = caja.expand(q)
		z["caja"] = caja
		zonas.append(z)


func _crear_panel() -> void:
	var fondo := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.09, 0.94)
	fondo.add_theme_stylebox_override("panel", sb)
	fondo.position = Vector2.ZERO
	fondo.size = Vector2(ANCHO_PANEL, 4000)
	fondo.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(fondo)
	var v := VBoxContainer.new()
	v.position = Vector2(18, 18)
	v.custom_minimum_size.x = ANCHO_PANEL - 36
	v.size.x = ANCHO_PANEL - 36
	v.add_theme_constant_override("separation", 8)
	fondo.add_child(v)
	var t := Label.new()
	t.text = "Cambiar de carretera"
	t.add_theme_font_size_override("font_size", 24)
	v.add_child(t)
	var ayuda := Label.new()
	ayuda.text = "Pincha en cualquier carretera de color para ir allí: el coche sale en el punto más cercano. Rueda: zoom · arrastrar: mover · doble clic o Intro: viajar."
	ayuda.autowrap_mode = TextServer.AUTOWRAP_WORD
	ayuda.custom_minimum_size.x = ANCHO_PANEL - 36
	ayuda.modulate = Color(0.72, 0.78, 0.84)
	ayuda.add_theme_font_size_override("font_size", 14)
	v.add_child(ayuda)
	var sep := HSeparator.new()
	v.add_child(sep)
	for z in zonas:
		var b := Button.new()
		b.text = "  " + ("Comunidad de Madrid (mapa abierto)" if z["clave"] == Ajustes.ZONA_MADRID else str(z["nombre"]))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.clip_text = true
		b.custom_minimum_size = Vector2(ANCHO_PANEL - 36, 34)
		b.add_theme_color_override("font_color", COLOR_ZONA.get(z["clave"], Color.WHITE))
		b.add_theme_color_override("font_focus_color", COLOR_ZONA.get(z["clave"], Color.WHITE))
		b.tooltip_text = str(z["nombre"])
		var zz: Dictionary = z
		b.pressed.connect(func() -> void: _ir_a_zona(zz))
		v.add_child(b)
		_botones.append(b)
	var b_todo := Button.new()
	b_todo.text = "  Ver toda España"
	b_todo.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b_todo.pressed.connect(_ver_todo)
	v.add_child(b_todo)
	v.add_child(HSeparator.new())
	_l_info.autowrap_mode = TextServer.AUTOWRAP_WORD
	_l_info.custom_minimum_size.x = ANCHO_PANEL - 36
	_l_info.text = "Ningún punto elegido."
	_l_info.add_theme_font_size_override("font_size", 16)
	v.add_child(_l_info)
	_b_viajar.text = "Viajar aquí (Intro)"
	_b_viajar.add_theme_font_size_override("font_size", 20)
	_b_viajar.disabled = true
	_b_viajar.pressed.connect(viajar)
	v.add_child(_b_viajar)
	_b_cerrar.text = "Volver (Esc)" if not desde_menu else "Volver al menú (Esc)"
	_b_cerrar.pressed.connect(cerrar)
	v.add_child(_b_cerrar)


func enfocar() -> void:
	if not _botones.is_empty():
		_botones[0].grab_focus.call_deferred()


func _lienzo() -> Vector2:
	var t := _tam()
	return Vector2(maxf(t.x - ANCHO_PANEL, 400.0), maxf(t.y, 300.0))


func _ver_todo() -> void:
	# península entera (y Baleares) en el lienzo
	var caja := Rect2(Vector2(-60000.0, 3980000.0), Vector2(1080000.0, 880000.0))
	centro = caja.get_center()
	var lienzo := _lienzo()
	escala = maxf(caja.size.x / lienzo.x, caja.size.y / lienzo.y) * 1.05
	queue_redraw()


## Vista centrada en una zona (la de la partida al abrir el mapa), sin elegir punto
func centrar_en(clave: String) -> void:
	for z in zonas:
		if z["clave"] == clave and (z["caja"] as Rect2).size != Vector2.ZERO:
			var caja: Rect2 = z["caja"]
			centro = caja.get_center() if aqui == Vector2.INF else aqui
			var lienzo := _lienzo()
			escala = maxf(maxf(caja.size.x / lienzo.x, caja.size.y / lienzo.y) * 1.15, 4.0)
			queue_redraw()
			return
	_ver_todo()


func _ir_a_zona(z: Dictionary) -> void:
	preferida = z["clave"]
	var caja: Rect2 = z["caja"]
	if caja.size == Vector2.ZERO:
		return
	centro = caja.get_center()
	var lienzo := _lienzo()
	escala = maxf(maxf(caja.size.x / lienzo.x, caja.size.y / lienzo.y) * 1.15, 4.0)
	# punto por defecto: comienzo de la carretera principal (en Madrid, el centro de la red)
	var p := Vector2.INF
	var nombre := ""
	if not z["rutas"].is_empty():
		p = (z["rutas"][0]["p"] as PackedVector2Array)[0]
		nombre = str(z["rutas"][0]["nombre"])
		_elegir(z, p, nombre)
	else:
		var r := _mas_cercano(caja.get_center(), 1e9, z)
		if not r.is_empty():
			_elegir(r["zona"], r["p"], r["nombre"])
	queue_redraw()


## Carretera más cercana a u (UTM) dentro de tol metros: {zona, p, nombre, d}; solo en la zona dada si se pasa
func _mas_cercano(u: Vector2, tol: float, solo: Dictionary = {}) -> Dictionary:
	var mejor := {}
	var dmin := tol
	for z in zonas:
		if not solo.is_empty() and z["clave"] != solo["clave"]:
			continue
		var caja: Rect2 = z["caja"]
		if not solo.is_empty() or caja.grow(dmin).has_point(u):
			var lineas: Array = []
			for r in z["rutas"]:
				lineas.append([r["p"], str(r["nombre"])])
			for m in z["madrid"]:
				lineas.append([m[1], ""])
			# M-406 y el puerto también están en la red del mapa abierto: gana la zona propia salvo que se haya elegido
			# la Comunidad de Madrid con su botón (o la zona dada)
			var castigo := 0.0
			if solo.is_empty() and z["clave"] != preferida and (z["clave"] == Ajustes.ZONA_MADRID or preferida == Ajustes.ZONA_MADRID):
				castigo = tol * 0.6 if tol < 1e8 else 0.0
			for l in lineas:
				var p: PackedVector2Array = l[0]
				for i in p.size() - 1:
					var a := p[i]
					var ab := p[i + 1] - a
					var t := clampf((u - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
					var q := a + ab * t
					var d := q.distance_to(u) + castigo
					if d < dmin:
						dmin = d
						mejor = {"zona": z, "p": q, "nombre": l[1], "d": d}
	return mejor


func _elegir(z: Dictionary, p: Vector2, nombre: String) -> void:
	elegido = {"zona": z["clave"], "e": p.x, "n": p.y, "texto": str(z["nombre"]) + ("\n" + nombre if nombre != "" else "")}
	_l_info.text = "Destino:\n" + elegido["texto"]
	_b_viajar.disabled = false
	queue_redraw()


func viajar() -> void:
	if elegido.is_empty() or _cargando:
		return
	_cargando = true
	Ajustes.viaje = {"zona": elegido["zona"], "e": elegido["e"], "n": elegido["n"], "texto": elegido["texto"]}
	get_tree().paused = false
	get_tree().change_scene_to_file("res://escenas/viaje.tscn")


func cerrar() -> void:
	visible = false
	cerrado.emit()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.position.x < ANCHO_PANEL:
			return
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var f := 0.8 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.25
			var antes := a_utm(mb.position)
			escala = clampf(escala * f, 2.0, 4000.0)
			centro += antes - a_utm(mb.position)
			queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_arrastre = true
				_movido = 0.0
				if mb.double_click and not elegido.is_empty():
					viajar()
			else:
				_arrastre = false
				if _movido < 6.0:
					clic(mb.position)
			accept_event()
	elif ev is InputEventMouseMotion and _arrastre:
		var mm := ev as InputEventMouseMotion
		_movido += mm.relative.length()
		if _movido >= 6.0:
			centro += Vector2(-mm.relative.x, mm.relative.y) * escala
			queue_redraw()
		accept_event()


## Clic en el lienzo (píxel s): elige la carretera más cercana; si no hay ninguna cerca, acerca la vista a la zona
func clic(s: Vector2) -> void:
	var u := a_utm(s)
	var r := _mas_cercano(u, TOL_PX * escala)
	if not r.is_empty():
		_elegir(r["zona"], r["p"], r["nombre"])
		return
	for z in zonas:
		if (z["caja"] as Rect2).grow(30.0 * escala).has_point(u):
			_ir_a_zona(z)
			return


func _unhandled_input(ev: InputEvent) -> void:
	if not visible:
		return
	if ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.physical_keycode:
			KEY_ESCAPE:
				cerrar()
				get_viewport().set_input_as_handled()
			KEY_ENTER, KEY_KP_ENTER:
				viajar()
				get_viewport().set_input_as_handled()
	elif ev is InputEventJoypadButton and ev.pressed and (ev.button_index == JOY_BUTTON_B or ev.button_index == JOY_BUTTON_START):
		cerrar()
		get_viewport().set_input_as_handled()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, _tam()), Color(0.1, 0.17, 0.24))     # mar
	var vista := Rect2(a_utm(Vector2(ANCHO_PANEL, _tam().y)), Vector2.ZERO).expand(a_utm(Vector2(_tam().x, 0.0)))
	for c in contorno:
		var p: PackedVector2Array = c["p"]
		var s := PackedVector2Array()
		s.resize(p.size())
		for i in p.size():
			s[i] = a_pantalla(p[i])
		if s.size() >= 3:
			var col := Color(0.2, 0.22, 0.2) if c["pais"] == "Spain" else Color(0.15, 0.16, 0.15)
			var tri := Geometry2D.triangulate_polygon(s)
			if not tri.is_empty():
				draw_polygon(s, PackedColorArray([col]))
			s.append(s[0])
			draw_polyline(s, Color(0.42, 0.45, 0.42), 1.0)
	if escala > 40.0:
		for c in ciudades:
			var cp := a_pantalla(c[1])
			draw_circle(cp, 3.0, Color(0.8, 0.8, 0.75))
			draw_string(ThemeDB.fallback_font, cp + Vector2(6, -4), c[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.75, 0.75, 0.7))
	for z in zonas:
		var caja: Rect2 = z["caja"]
		if not vista.grow(2000.0).intersects(caja.grow(1.0)):
			continue
		var col: Color = COLOR_ZONA.get(z["clave"], Color.WHITE)
		var pequena := maxf(caja.size.x, caja.size.y) / escala < 30.0
		if pequena:
			# muy lejos: un punto con su nombre
			var c := a_pantalla(caja.get_center())
			draw_circle(c, 7.0, col)
			var fuente := ThemeDB.fallback_font
			var txt := str(z["nombre"])
			if z["clave"] == "a308":     # A-308 y GR-8101 quedan muy cerca: una a cada lado del punto
				draw_string(fuente, c + Vector2(-12.0 - fuente.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x, -8), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
			else:
				draw_string(fuente, c + Vector2(10, 5 if z["clave"] != "gr8101" else 14), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
			continue
		# todo en unas pocas órdenes de dibujo (con miles de draw_polyline, en el renderizador de compatibilidad no se
		# pintaba nada): segmentos visibles agrupados por color
		if escala < 60.0:
			draw_multiline(_segmentos(z["vias"], z["cajas_vias"], vista, 1.5), col.darkened(0.55), 1.0)
		if not z["madrid"].is_empty():
			var min_px := 1.5 if escala < 60.0 else 3.0
			for cl in range(4, -1, -1):
				if (escala > 150.0 and cl >= 3) or (escala > 400.0 and cl >= 2):
					continue
				var lin: Array = z["madrid_clase"][cl]
				var cajas: Array = z["madrid_cajas"][cl]
				var cc := col if cl <= 1 else col.lerp(Color(0.62, 0.6, 0.52), 0.35 + 0.15 * (cl - 2))
				draw_multiline(_segmentos(lin, cajas, vista, min_px), cc, (2.4 if cl == 0 else 1.8) if cl <= 1 else 1.0)
		for r in z["rutas"]:
			_trazo(r["p"], col, 3.0)
		var et := a_pantalla(Vector2(caja.position.x, caja.end.y))
		draw_string(ThemeDB.fallback_font, et + Vector2(0, -6), str(z["nombre"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col)
	if aqui != Vector2.INF:
		var a := a_pantalla(aqui)
		draw_circle(a, 7.0, Color.WHITE)
		draw_circle(a, 4.5, Color(0.1, 0.5, 1.0))
		draw_string(ThemeDB.fallback_font, a + Vector2(10, -8), "Estás aquí", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
	if not elegido.is_empty():
		var e := a_pantalla(Vector2(elegido["e"], elegido["n"]))
		draw_circle(e, 9.0, Color(1, 1, 1, 0.9))
		draw_circle(e, 6.0, Color(0.9, 0.15, 0.15))
		draw_line(e, e + Vector2(0, -26), Color(0.9, 0.15, 0.15), 3.0)
	# escala gráfica
	var km := [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0]
	var elegido_km := 1.0
	for k in km:
		if k * 1000.0 / escala <= 160.0:
			elegido_km = k
	var x0 := _tam().x - 200.0
	var y0 := _tam().y - 24.0
	draw_line(Vector2(x0, y0), Vector2(x0 + elegido_km * 1000.0 / escala, y0), Color.WHITE, 3.0)
	draw_string(ThemeDB.fallback_font, Vector2(x0, y0 - 8), "%d km" % roundi(elegido_km), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
	draw_string(ThemeDB.fallback_font, Vector2(ANCHO_PANEL + 10, _tam().y - 10), "Contorno: Natural Earth · carreteras: © OpenStreetMap", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.65, 0.7))


## Pares de puntos en pantalla de las líneas cuya caja se ve; tramos más cortos que min_px se juntan
func _segmentos(lineas: Array, cajas: Array, vista: Rect2, min_px: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var marco := Rect2(Vector2(ANCHO_PANEL - 20.0, -20.0), _tam() - Vector2(ANCHO_PANEL - 40.0, -40.0))
	for i in lineas.size():
		if not vista.intersects(cajas[i]):
			continue
		var p: PackedVector2Array = lineas[i]
		var ant := a_pantalla(p[0])
		for k in range(1, p.size()):
			var q := a_pantalla(p[k])
			if k < p.size() - 1 and ant.distance_squared_to(q) < min_px * min_px:
				continue
			if marco.has_point(ant) or marco.has_point(q):
				out.append(ant)
				out.append(q)
			ant = q
	if out.is_empty():
		out.append_array([Vector2(-10, -10), Vector2(-10, -10)])
	return out


static func _caja(p: PackedVector2Array) -> Rect2:
	var r := Rect2(p[0], Vector2.ZERO)
	for q in p:
		r = r.expand(q)
	return r


func _trazo(p: PackedVector2Array, col: Color, ancho: float) -> void:
	if p.size() < 2:
		return
	var s := PackedVector2Array()
	s.resize(p.size())
	for i in p.size():
		s[i] = a_pantalla(p[i])
	draw_polyline(s, col, ancho)
