## Navegación del mapa abierto (solo escritorio): minimapa giratorio tipo GPS abajo a la derecha y mapa grande con M.
##  · La red sale de datos/<region>/mapa.bin.gz (pipeline/mundo/m7_mapa.py: los tramos de red.json.gz simplificados a 4 m) y
##    se dibuja como UNA malla 2D compartida por los dos mapas (anchos en píxeles con un shader: el zoom no rehace nada).
##    Colores por clase de vía como en los mapas de carreteras españoles (autopista/autovía roja, nacional/primaria naranja…).
##  · Nombres: matrícula de la vía (ref de OSM) y municipios de OSM (datos/<region>/lugares.json). Nada inventado.
##  · Mapa grande (M, Options o el panel táctil del mando): arrastrar o flechas = mover, rueda o +/- = zoom, clic o
##    Intro (en la cruz del centro) = destino, clic derecho o Supr = quitar destino, C = volver al coche, M / Esc = cerrar.
##    Con mando: stick izquierdo mueve, L2/R2 zoom, ✕ destino en la cruz del centro, ○ quitar.
##    El juego se para mientras está abierto. El destino se pega a la vía más cercana a la que se puede llegar.
##  · GPS (MaGps): ruta dibujada en los dos mapas, próxima maniobra con distancia, km y minutos que quedan; si el coche
##    se sale de la ruta se recalcula (tras ~1 s fuera). El piloto automático (P) sigue la ruta hasta el destino.
##  · Minimapa: Z/X acercar/alejar (radio 0,5–4 km). Sin asignaciones por fotograma: solo se mueve una transformada; los
##    rótulos se recolocan 4 veces por segundo con nodos reutilizados.
class_name MaMapa
extends CanvasLayer

const CLASES := 8                 # 0 autopista/autovía … 4 local, 7 ruta
const LADO_MINI := 300.0          # px del minimapa
const MITAD := Vector2(150.0, 150.0)
const RADIOS := [500.0, 1000.0, 1500.0, 2500.0, 4000.0]

var juego: Node                   # ma_juego.gd
var datos: MaDatos
var gps: MaGps
var malla: ArrayMesh              # red completa
var malla_ruta: ArrayMesh
var pts_tramo: Array = []         # PackedVector2Array por tramo (simplificado)
var celdas := {}                  # Vector2i (500 m) -> PackedInt32Array de tramos (para elegir destino con el ratón)
const CELDA := 500.0
var lugares: Array = []           # {n, t, pob, x, z}
var rot_x := PackedFloat32Array() # anclas de rótulos de vías (cada ~600 m de las vías con matrícula)
var rot_z := PackedFloat32Array()
var rot_ref := PackedStringArray()
var rot_clase := PackedInt32Array()
var rot_celdas := {}              # Vector2i (1 km) -> PackedInt32Array de anclas
var abierto := false
var listo := false

# minimapa
var mini := Control.new()
var mini_capa := Node2D.new()
var mini_red := MeshInstance2D.new()
var mini_ruta := MeshInstance2D.new()
var mini_mat := ShaderMaterial.new()
var mini_mat_ruta := ShaderMaterial.new()
var mini_destino := Polygon2D.new()
var panel_gps := PanelContainer.new()   # próxima maniobra (encima del minimapa)
var gps_flecha := Polygon2D.new()
var gps_aro := Line2D.new()
var gps_num := Label.new()
var gps_dist := Label.new()
var gps_texto := Label.new()
var gps_resto := Label.new()
var _t_seguir := 0.0
var _fuera := 0
var _fuera_sup := 0
var recalculos := 0                   # rutas recalculadas por salirse (pruebas)
var _llegada_t := 0.0
var _pendiente := ""                  # "nuevo" / "recalculo" mientras MaGps calcula en su hilo
var _alcance_desde := -1
var _alcance := PackedByteArray()     # tramos a los que se puede llegar desde el paso actual (para pegar el destino)
var mini_rotulos: Array = []
var radio_i := 2
var _t_rotulos := 0.0
var _m_mini := -1.0

# mapa grande
var grande := Control.new()
var g_capa := Node2D.new()
var g_red := MeshInstance2D.new()
var g_ruta := MeshInstance2D.new()
var g_mat := ShaderMaterial.new()
var g_mat_ruta := ShaderMaterial.new()
var g_coche := Polygon2D.new()
var g_destino := Polygon2D.new()
var g_cruz := Label.new()
var g_rotulos: Array = []
var g_info := Label.new()
var g_ayuda: Label
var g_fuente: Label
var centro := Vector2.ZERO        # centro de la vista (X, Z del juego)
var m_px := 40.0                  # metros por píxel
var _arrastre := false
var _arrastre_mov := 0.0

var SHADER: Shader


func iniciar(j: Node) -> void:
	juego = j
	datos = j.datos
	gps = j.gps
	layer = 5
	_shader()
	_leer()
	gps.construir(pts_tramo)
	_malla_red()
	_crear_minimapa()
	_crear_grande()
	listo = true
	if Ajustes.args.has("destino"):          # pruebas: --destino=X,Z
		var xz := str(Ajustes.args["destino"]).split(",")
		gps.esperar_grafo()
		poner_destino(Vector2(float(xz[0]), float(xz[1])))
	if Ajustes.args.get("mapa_abierto", "0") == "1":
		abrir(true)


# ------------------------------------------------------------------ datos
func _leer() -> void:
	var b := MaDatos.gz(datos.dir + "mapa.bin.gz")
	var n := b.decode_u32(6)
	var o := 10
	pts_tramo.resize(n)
	for k in n:
		var np := b.decode_u16(o)
		o += 2
		var p := PackedVector2Array()
		p.resize(np)
		for i in np:
			p[i] = Vector2(b.decode_float(o), b.decode_float(o + 4))
			o += 8
		pts_tramo[k] = p
		var vistas := {}
		for q in p:
			var c := Vector2i(floori(q.x / CELDA), floori(q.y / CELDA))
			if vistas.has(c):
				continue
			vistas[c] = true
			if not celdas.has(c):
				celdas[c] = PackedInt32Array()
			celdas[c].append(k)
	var lj = JSON.parse_string(FileAccess.get_file_as_string(datos.dir + "lugares.json"))
	if lj is Dictionary:
		lugares = lj.get("lugares", [])
	# anclas de rótulos: cada ~600 m de cada tramo con matrícula (sin enlaces)
	for k in n:
		var t: Dictionary = datos.tramos[k]
		var ref := str(t["ref"]).split(";")[0]
		if ref == "" or int(t["enlace"]) == 1:
			continue
		var p: PackedVector2Array = pts_tramo[k]
		var acum := 300.0
		for i in p.size() - 1:
			var seg := p[i].distance_to(p[i + 1])
			while acum < seg:
				var q := p[i].lerp(p[i + 1], acum / seg)
				var id := rot_x.size()
				rot_x.append(q.x)
				rot_z.append(q.y)
				rot_ref.append(ref)
				rot_clase.append(int(t["c"]))
				var c := Vector2i(floori(q.x / 1000.0), floori(q.y / 1000.0))
				if not rot_celdas.has(c):
					rot_celdas[c] = PackedInt32Array()
				rot_celdas[c].append(id)
				acum += 600.0
			acum -= seg


func _shader() -> void:
	if SHADER != null:
		return
	SHADER = Shader.new()
	SHADER.code = """
shader_type canvas_item;
// Líneas de ancho constante en píxeles: VERTEX es el eje de la vía (metros) y UV la normal (con inglete);
// COLOR.r = clase / 8, COLOR.g = 1 en enlaces
uniform float m_px = 10.0;
uniform vec4 colores[8];
uniform float anchos[8];
void vertex() {
	int c = clamp(int(COLOR.r * 8.0 + 0.5), 0, 7);
	float w = anchos[c] * (COLOR.g > 0.5 ? 0.6 : 1.0);
	VERTEX += UV * (0.5 * w * m_px);
	COLOR = colores[c];
}
"""


func _material(m: ShaderMaterial, escala_ancho: float) -> void:
	m.shader = SHADER
	# autopista/autovía, nacional/troncal, primaria (M- de 1.er orden), secundaria, local; 7 = ruta
	m.set_shader_parameter("colores", PackedColorArray([Color(0.86, 0.18, 0.16), Color(0.95, 0.45, 0.12), Color(0.98, 0.72, 0.18),
			Color(0.95, 0.9, 0.55), Color(0.82, 0.82, 0.82), Color.WHITE, Color.WHITE, Color(0.2, 0.62, 1.0)]))
	var anchos := PackedFloat32Array([4.0, 3.4, 2.8, 2.2, 1.6, 1.0, 1.0, 6.0])
	for i in anchos.size():
		anchos[i] *= escala_ancho
	m.set_shader_parameter("anchos", anchos)


## Una malla de cintas: 2 vértices por punto (eje ± normal), de las vías menores a las mayores para que estas queden encima
func _malla_red() -> void:
	var orden: Array = []
	for c in [4, 3, 2, 1, 0]:
		for k in pts_tramo.size():
			if int(datos.tramos[k]["c"]) == c:
				orden.append(k)
	malla = _cintas(orden, -1)


func _cintas(tramos: Array, clase_fija: int, sentidos: Array = []) -> ArrayMesh:
	var v := PackedVector2Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	var ix := PackedInt32Array()
	for j in tramos.size():
		var k: int = tramos[j]
		var p: PackedVector2Array = pts_tramo[k]
		var n := p.size()
		if n < 2:
			continue
		var t: Dictionary = datos.tramos[k]
		var cl := clase_fija if clase_fija >= 0 else int(t["c"])
		var c := Color(cl / 8.0, 1.0 if (int(t["enlace"]) == 1 and clase_fija < 0) else 0.0, 0.0, 1.0)
		var base := v.size()
		for i in n:
			var t0 := (p[i] - p[maxi(i - 1, 0)]).normalized()
			var t1 := (p[mini(i + 1, n - 1)] - p[i]).normalized()
			if i == 0: t0 = t1
			if i == n - 1: t1 = t0
			var tg := (t0 + t1).normalized()
			if tg == Vector2.ZERO: tg = t1
			var nr := Vector2(-tg.y, tg.x)
			var n0 := Vector2(-t0.y, t0.x)
			nr /= maxf(nr.dot(n0), 0.5)          # inglete (limitado)
			v.append(p[i]); v.append(p[i])
			uv.append(nr); uv.append(-nr)
			col.append(c); col.append(c)
			if i > 0:
				var q := base + (i - 1) * 2
				ix.append_array([q, q + 1, q + 2, q + 1, q + 3, q + 2])
	var m := ArrayMesh.new()
	if v.is_empty():
		return m
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = ix
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


# ------------------------------------------------------------------ minimapa
func _crear_minimapa() -> void:
	mini.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	mini.offset_left = -LADO_MINI - 16.0
	mini.offset_right = -16.0
	mini.offset_top = -LADO_MINI - 110.0
	mini.offset_bottom = -110.0
	mini.clip_contents = true
	mini.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fondo := Panel.new()
	var est := StyleBoxFlat.new()
	est.bg_color = Color(0.07, 0.08, 0.09, 0.78)
	est.border_color = Color(1, 1, 1, 0.35)
	est.set_border_width_all(2)
	est.set_corner_radius_all(14)
	fondo.add_theme_stylebox_override("panel", est)
	fondo.set_anchors_preset(Control.PRESET_FULL_RECT)
	fondo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mini.add_child(fondo)
	_material(mini_mat, 1.0)
	_material(mini_mat_ruta, 1.0)
	mini_red.mesh = malla
	mini_red.material = mini_mat
	mini_ruta.material = mini_mat_ruta
	mini_capa.add_child(mini_red)
	mini_capa.add_child(mini_ruta)
	mini_destino.polygon = _rombo(1.0)
	mini_destino.color = Color(0.2, 0.62, 1.0)
	mini_destino.visible = false
	mini.add_child(mini_capa)
	mini.add_child(mini_destino)
	for i in 8:
		var l := _rotulo(13)
		mini.add_child(l)
		mini_rotulos.append(l)
	var flecha := Polygon2D.new()
	flecha.polygon = PackedVector2Array([Vector2(0, -13), Vector2(9, 10), Vector2(0, 5), Vector2(-9, 10)])
	flecha.color = Color(1, 1, 1)
	flecha.position = Vector2(LADO_MINI, LADO_MINI) * 0.5
	var borde := Line2D.new()
	borde.points = PackedVector2Array([Vector2(0, -13), Vector2(9, 10), Vector2(0, 5), Vector2(-9, 10), Vector2(0, -13)])
	borde.width = 2.0
	borde.default_color = Color(0, 0, 0, 0.8)
	flecha.add_child(borde)
	mini.add_child(flecha)
	add_child(mini)
	_crear_panel_gps()


## Panel del GPS encima del minimapa: flecha de la próxima maniobra, distancia, qué hacer, y lo que queda hasta el destino
func _crear_panel_gps() -> void:
	panel_gps.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	panel_gps.offset_left = -LADO_MINI - 16.0
	panel_gps.offset_right = -16.0
	panel_gps.offset_top = -LADO_MINI - 110.0 - 104.0
	panel_gps.offset_bottom = -LADO_MINI - 110.0 - 8.0
	panel_gps.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var est := StyleBoxFlat.new()
	est.bg_color = Color(0.05, 0.22, 0.42, 0.88)
	est.set_corner_radius_all(12)
	est.set_content_margin_all(8)
	panel_gps.add_theme_stylebox_override("panel", est)
	var fila := HBoxContainer.new()
	fila.add_theme_constant_override("separation", 10)
	fila.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel_gps.add_child(fila)
	var icono := Control.new()
	icono.custom_minimum_size = Vector2(64, 80)
	icono.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fila.add_child(icono)
	gps_flecha.polygon = PackedVector2Array([Vector2(0, -26), Vector2(16, -6), Vector2(6, -6), Vector2(6, 22), Vector2(-6, 22),
			Vector2(-6, -6), Vector2(-16, -6)])
	gps_flecha.color = Color.WHITE
	gps_flecha.position = Vector2(32, 40)
	icono.add_child(gps_flecha)
	var pts := PackedVector2Array()
	for i in 25:
		pts.append(Vector2(cos(TAU * i / 24.0), sin(TAU * i / 24.0)) * 17.0)
	gps_aro.points = pts
	gps_aro.width = 5.0
	gps_aro.default_color = Color.WHITE
	gps_aro.position = Vector2(32, 40)
	icono.add_child(gps_aro)
	gps_num.add_theme_font_size_override("font_size", 18)
	gps_num.position = Vector2(26, 27)
	icono.add_child(gps_num)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fila.add_child(col)
	gps_dist.add_theme_font_size_override("font_size", 26)
	gps_texto.add_theme_font_size_override("font_size", 14)
	gps_texto.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gps_texto.custom_minimum_size = Vector2(190, 0)
	gps_resto.add_theme_font_size_override("font_size", 13)
	gps_resto.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	gps_resto.clip_text = true
	gps_resto.custom_minimum_size = Vector2(190, 0)
	gps_resto.modulate = Color(0.85, 0.92, 1.0)
	for l in [gps_dist, gps_texto, gps_resto]:
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(l)
	panel_gps.visible = false
	add_child(panel_gps)


## Chincheta con la punta en (0, 0): círculo de radio 11 centrado 24 px por encima
static func _chincheta() -> PackedVector2Array:
	var p := PackedVector2Array([Vector2(0, 0)])
	for i in 21:
		var t := deg_to_rad(60.0 - 300.0 * i / 20.0)
		p.append(Vector2(cos(t), sin(t)) * 11.0 + Vector2(0, -24))
	return p


static func _rombo(s: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(0, -9) * s, Vector2(7, 0) * s, Vector2(0, 9) * s, Vector2(-7, 0) * s])


static func _rotulo(tam: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", tam)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.visible = false
	return l


func _process(dt: float) -> void:
	if not listo:
		return
	_resultado_gps()
	_t_seguir += dt
	if _t_seguir > 0.5:
		_t_seguir = 0.0
		_seguir_ruta()
	if _llegada_t > 0.0:
		_llegada_t -= dt
		if _llegada_t <= 0.0:
			panel_gps.visible = false
	if abierto:
		_mover_con_mando(dt)
		_t_rotulos -= dt
		if _t_rotulos <= 0.0:
			_t_rotulos = 0.5
			_vista()
		return
	var c: Coche = juego.coche
	var f := c.adelante()
	var rot := -PI * 0.5 - atan2(f.z, f.x)
	var radio: float = RADIOS[radio_i]
	var m := radio / (LADO_MINI * 0.5)
	if m != _m_mini:
		_m_mini = m
		mini_mat.set_shader_parameter("m_px", m)
		mini_mat_ruta.set_shader_parameter("m_px", m)
	var xf := Transform2D(rot, Vector2(1.0 / m, 1.0 / m), 0.0, Vector2.ZERO)
	xf.origin = MITAD - xf.basis_xform(Vector2(c.position.x, c.position.z))
	mini_capa.transform = xf
	if gps.activo():
		var q := xf * Vector2(gps.destino.x, gps.destino.z)
		var dentro := Rect2(Vector2.ZERO, Vector2(LADO_MINI, LADO_MINI)).grow(-10.0)
		if not dentro.has_point(q):      # fuera de la vista: en el borde, en su dirección
			q = MITAD + (q - MITAD).normalized() * (LADO_MINI * 0.5 - 14.0)
		mini_destino.position = q
	_t_rotulos -= dt
	if _t_rotulos <= 0.0:
		_t_rotulos = 0.25
		_rotulos_mini(xf, radio)
		_texto_destino()


func _rotulos_mini(xf: Transform2D, radio: float) -> void:
	var c: Coche = juego.coche
	var p := Vector2(c.position.x, c.position.z)
	var usados := 0
	var refs := {}
	var caja := Rect2(Vector2.ZERO, Vector2(LADO_MINI, LADO_MINI)).grow(-14.0)
	# vías: el ancla más cercana de cada matrícula a la vista (las vías grandes primero)
	var cand: Array = []
	var r := int(ceil(radio / 1000.0))
	var c0 := Vector2i(floori(p.x / 1000.0), floori(p.y / 1000.0))
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var lista = rot_celdas.get(c0 + Vector2i(dx, dz))
			if lista == null:
				continue
			for id in lista:
				var q := Vector2(rot_x[id], rot_z[id])
				var d := q.distance_to(p)
				if d < radio * 1.3:
					cand.append([rot_clase[id] * 100000.0 + d, id])
	cand.sort_custom(func(a, b): return a[0] < b[0])
	var ocupado: Array = []
	for e in cand:
		if usados >= 5:
			break
		var id: int = e[1]
		var ref := rot_ref[id]
		if refs.has(ref):
			continue
		var s := xf * Vector2(rot_x[id], rot_z[id])
		if not caja.has_point(s):
			continue
		var l: Label = mini_rotulos[usados]
		if _poner(l, ref, s, ocupado, Color(1, 1, 1)):
			refs[ref] = true
			usados += 1
	# municipios cercanos
	var lug: Array = []
	for i in lugares.size():
		var lu: Dictionary = lugares[i]
		if lu["t"] == "village" and radio > 1600.0:
			continue
		var d := Vector2(float(lu["x"]), float(lu["z"])).distance_to(p)
		if d < radio * 1.4:
			lug.append([d, i])
	lug.sort_custom(func(a, b): return a[0] < b[0])
	for e in lug:
		if usados >= mini_rotulos.size():
			break
		var lu: Dictionary = lugares[e[1]]
		var s := xf * Vector2(float(lu["x"]), float(lu["z"]))
		if not caja.has_point(s):
			continue
		var l: Label = mini_rotulos[usados]
		if _poner(l, str(lu["n"]), s, ocupado, Color(0.85, 0.95, 1.0)):
			usados += 1
	for i in range(usados, mini_rotulos.size()):
		mini_rotulos[i].visible = false


## Coloca un rótulo centrado en s si no pisa otro; devuelve si lo ha puesto
static func _poner(l: Label, texto: String, s: Vector2, ocupado: Array, color: Color) -> bool:
	if l.text != texto:
		l.text = texto
	var tam := l.get_minimum_size()
	var r := Rect2(s - tam * 0.5, tam)
	for o in ocupado:
		if (o as Rect2).intersects(r):
			return false
	ocupado.append(r)
	l.position = r.position
	l.modulate = color
	l.visible = true
	return true


func _texto_destino() -> void:
	if not gps.activo():
		mini_destino.visible = false
		g_destino.visible = false
		if _llegada_t <= 0.0:
			panel_gps.visible = _pendiente != ""
			if _pendiente != "":
				_panel("…", "Calculando ruta", "", 0.0, "")
		return
	var e: Array = juego.camino[0] if not juego.camino.is_empty() else []
	var falta := -1.0
	if not e.is_empty():
		falta = gps.restante(e[0], e[1], juego.d_camino)
	if falta >= 0.0 and falta < 30.0:
		print("MAPA_LLEGADA %s (t=%.0f s, recalculos %d)" % [gps.nombre, juego.tiempo, recalculos])
		_panel("", "Has llegado", gps.nombre, 0.0, "destino")
		_llegada_t = 6.0
		quitar_destino()
		return
	mini_destino.visible = true
	panel_gps.visible = true
	if falta < 0.0:
		_panel("…", "Recalculando ruta" if _pendiente != "" else "Vuelve a la ruta", "", 0.0, "")
		return
	var seg := gps.segundos(e[0], e[1], juego.d_camino)
	var resto := "%s  ·  %s  ·  %s" % [_km(falta), _minutos(seg), gps.nombre]
	var px := gps.proxima(e[0], e[1], juego.d_camino)
	if px.is_empty() or str(px[3]) == "destino":
		_panel(_metros(falta), "Destino" + ("" if px.is_empty() else ""), resto, 0.0, "destino")
	else:
		_panel(_metros(float(px[0])), str(px[1]), resto, float(px[2]), str(px[3]))


func _panel(dist: String, texto: String, resto: String, giro: float, tipo: String) -> void:
	gps_dist.text = dist
	gps_texto.text = texto
	gps_resto.text = resto
	gps_resto.visible = resto != ""
	gps_aro.visible = tipo.begins_with("glorieta")
	gps_num.visible = gps_aro.visible
	gps_flecha.visible = not gps_aro.visible and tipo != ""
	if gps_aro.visible:
		gps_num.text = tipo.substr(8)
	elif tipo == "destino":
		gps_flecha.rotation = 0.0
		gps_flecha.color = Color(0.45, 1.0, 0.55)
	else:
		gps_flecha.color = Color.WHITE
		gps_flecha.rotation = PI if tipo == "vuelta" else clampf(giro, -PI * 0.6, PI * 0.6)


static func _metros(m: float) -> String:
	if m >= 1000.0:
		return "%s km" % String.num(m / 1000.0, 1).replace(".", ",")
	return "%d m" % (roundi(m / 50.0) * 50 if m >= 300.0 else roundi(m / 10.0) * 10)


static func _km(m: float) -> String:
	return "%s km" % String.num(m / 1000.0, 1).replace(".", ",")


static func _minutos(s: float) -> String:
	var mi := maxi(roundi(s / 60.0), 1)
	return "%d min" % mi if mi < 60 else "%d h %02d min" % [mi / 60, mi % 60]


## Ruta calculada en el hilo de MaGps: dibujarla y que el piloto la siga
func _resultado_gps() -> void:
	if _pendiente == "":
		return
	var r := gps.terminado()
	if r < 0:
		return
	var tipo := _pendiente
	_pendiente = ""
	var e: Array = juego.camino[0] if not juego.camino.is_empty() else [-1, 0]
	print("GPS_%s %s · %s · %d pasos · %.0f m · %.0f s · %.1f ms en hilo" % ["RUTA" if tipo == "nuevo" else "RECALCULO", gps.nombre if r == 1 else "-",
			"ruta" if r == 1 else "SIN RUTA", gps.pasos.size(), gps.restante(e[0], e[1], juego.d_camino) if r == 1 else -1.0,
			gps.segundos(e[0], e[1], juego.d_camino) if r == 1 else -1.0, gps.ms_calculo])
	if r == 1:
		_fuera = 0
		_dibujar_ruta()
		juego._replanificar()
		if abierto:
			_vista()
	elif tipo == "nuevo" and abierto:
		g_info.text = "No hay ruta hasta ese punto"


## Si el coche se ha salido de la ruta (giro equivocado conduciendo o con Q/E), la recalcula desde donde esté (tras
## dos comprobaciones seguidas, ~1 s). Conduciendo a mano, el camino del juego sigue la ruta hasta que el coche se
## separa 25 m; aquí además se mira en qué vía está de verdad (superficie) para darse cuenta antes.
func _seguir_ruta() -> void:
	if not gps.activo() or juego.camino.is_empty() or _pendiente != "":
		return
	var e: Array = juego.camino[0]
	var i := gps.posicion(e[0], e[1])
	if i >= 0 and not juego.piloto:
		var c: Coche = juego.coche
		var q := Ajustes.superficie.consultar(c.position.x, c.position.z, c.position.y)
		var kq := int(q.z)
		if kq >= 0 and kq != int(e[0]) and absf(juego.lat_camino) > 6.0:
			var cerca := false
			for j in range(maxi(i - 1, 0), mini(i + 4, gps.pasos.size())):
				if (gps.pasos[j] >> 1) == kq:
					cerca = true
			_fuera_sup = 0 if cerca else _fuera_sup + 1
			if _fuera_sup >= 2:
				_fuera_sup = 0
				juego.camino.clear()
				juego._reengancharse()
				if juego.camino.is_empty():
					return
				e = juego.camino[0]
				i = gps.posicion(e[0], e[1])
		else:
			_fuera_sup = 0
	if i >= 0:
		gps.progreso = i
		_fuera = 0
		return
	_fuera += 1
	if _fuera < 2:
		return
	_fuera = 0
	recalculos += 1
	_pendiente = "recalculo"
	gps.pedir(e[0], e[1], juego.d_camino, gps.destino_k, gps.destino, gps.nombre)


# ------------------------------------------------------------------ mapa grande
func _crear_grande() -> void:
	grande.set_anchors_preset(Control.PRESET_FULL_RECT)
	grande.visible = false
	grande.mouse_filter = Control.MOUSE_FILTER_STOP
	var fondo := ColorRect.new()
	fondo.color = Color(0.06, 0.07, 0.08, 1.0)
	fondo.set_anchors_preset(Control.PRESET_FULL_RECT)
	fondo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grande.add_child(fondo)
	_material(g_mat, 1.0)
	_material(g_mat_ruta, 1.0)
	g_red.mesh = malla
	g_red.material = g_mat
	g_ruta.material = g_mat_ruta
	g_capa.add_child(g_red)
	g_capa.add_child(g_ruta)
	grande.add_child(g_capa)
	for i in 90:
		var l := _rotulo(14)
		grande.add_child(l)
		g_rotulos.append(l)
	g_destino.polygon = _chincheta()
	g_destino.color = Color(0.93, 0.2, 0.25)
	var borde_d := Line2D.new()
	var pc := _chincheta()
	pc.append(pc[0])
	borde_d.points = pc
	borde_d.width = 2.0
	borde_d.default_color = Color(0, 0, 0, 0.9)
	g_destino.add_child(borde_d)
	var centro_d := Polygon2D.new()
	var pcd := PackedVector2Array()
	for i in 12:
		pcd.append(Vector2(cos(TAU * i / 12.0), sin(TAU * i / 12.0)) * 4.5 + Vector2(0, -24))
	centro_d.polygon = pcd
	centro_d.color = Color.WHITE
	g_destino.add_child(centro_d)
	g_destino.visible = false
	grande.add_child(g_destino)
	g_coche.polygon = PackedVector2Array([Vector2(0, -14), Vector2(10, 11), Vector2(0, 5), Vector2(-10, 11)])
	g_coche.color = Color(1, 1, 1)
	var borde := Line2D.new()
	borde.points = PackedVector2Array([Vector2(0, -14), Vector2(10, 11), Vector2(0, 5), Vector2(-10, 11), Vector2(0, -14)])
	borde.width = 2.5
	borde.default_color = Color(0, 0, 0)
	g_coche.add_child(borde)
	grande.add_child(g_coche)
	g_cruz.text = "+"
	g_cruz.add_theme_font_size_override("font_size", 28)
	g_cruz.modulate = Color(1, 1, 1, 0.6)
	g_cruz.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grande.add_child(g_cruz)
	g_info.add_theme_font_size_override("font_size", 16)
	g_info.add_theme_color_override("font_outline_color", Color.BLACK)
	g_info.add_theme_constant_override("outline_size", 5)
	g_info.position = Vector2(20, 16)
	grande.add_child(g_info)
	var ayuda := Label.new()
	ayuda.text = "Arrastrar o flechas: mover · Rueda o +/-: zoom · Clic o Intro: destino · Clic derecho o Supr: quitar · C: coche · M / Esc: cerrar    (mando: stick, L2/R2, ✕ destino, ○ quitar, Options cerrar)"
	ayuda.add_theme_font_size_override("font_size", 14)
	ayuda.modulate = Color(1, 1, 1, 0.75)
	g_ayuda = ayuda
	grande.add_child(ayuda)
	var fuente := Label.new()
	fuente.text = "© colaboradores de OpenStreetMap"
	fuente.add_theme_font_size_override("font_size", 12)
	fuente.modulate = Color(1, 1, 1, 0.5)
	g_fuente = fuente
	grande.add_child(fuente)
	grande.gui_input.connect(_entrada_grande)
	add_child(grande)


func abrir(si: bool) -> void:
	abierto = si
	grande.visible = si
	mini.visible = not si
	panel_gps.modulate.a = 0.0 if si else 1.0
	if si:
		var c: Coche = juego.coche
		centro = Vector2(c.position.x, c.position.z)
		m_px = 25.0
		_vista()


func _vista() -> void:
	var tam := grande.get_viewport_rect().size
	g_mat.set_shader_parameter("m_px", m_px)
	g_mat_ruta.set_shader_parameter("m_px", m_px)
	var xf := Transform2D(0.0, Vector2(1.0 / m_px, 1.0 / m_px), 0.0, Vector2.ZERO)
	xf.origin = tam * 0.5 - centro / m_px
	g_capa.transform = xf
	var c: Coche = juego.coche
	g_coche.position = xf * Vector2(c.position.x, c.position.z)
	var f := c.adelante()
	g_coche.rotation = atan2(f.z, f.x) + PI * 0.5
	g_destino.visible = gps.activo()
	if gps.activo():
		g_destino.position = xf * Vector2(gps.destino.x, gps.destino.z)
	g_cruz.position = tam * 0.5 - g_cruz.get_minimum_size() * 0.5
	g_ayuda.position = Vector2(20, tam.y - 34)
	g_fuente.position = Vector2(tam.x - 230, 18)
	var escala := "%d km" % roundi(m_px * 200.0 / 1000.0) if m_px * 200.0 >= 1000.0 else "%d m" % roundi(m_px * 200.0)
	var txt := "Elige un destino: clic (o Intro en la cruz)"
	if _pendiente != "":
		txt = "Calculando ruta…"
	elif gps.activo() and not juego.camino.is_empty():
		var e: Array = juego.camino[0]
		var falta := gps.restante(e[0], e[1], juego.d_camino)
		txt = "Destino: %s" % gps.nombre
		if falta >= 0.0:
			txt += "  ·  %s  ·  %s" % [_km(falta), _minutos(gps.segundos(e[0], e[1], juego.d_camino))]
	g_info.text = txt + "    ·    200 px = " + escala
	_rotulos_grande(xf, tam)


func _rotulos_grande(xf: Transform2D, tam: Vector2) -> void:
	var ocupado: Array = []
	var usados := 0
	var caja := Rect2(Vector2.ZERO, tam).grow(-10.0)
	# municipios por población (los pequeños solo de cerca)
	for lu in lugares:
		if usados >= 55:
			break
		var t: String = lu["t"]
		if t == "village" and m_px > 18.0:
			continue
		if t == "town" and m_px > 70.0:
			continue
		var s := xf * Vector2(float(lu["x"]), float(lu["z"]))
		if not caja.has_point(s):
			continue
		var l: Label = g_rotulos[usados]
		l.add_theme_font_size_override("font_size", 17 if t == "city" else (14 if t == "town" else 12))
		if _poner(l, str(lu["n"]), s, ocupado, Color(0.85, 0.95, 1.0)):
			usados += 1
	# matrículas: anclas separadas al menos 180 px de otra de la misma vía, las vías grandes primero
	var por_clase := [[], [], [], []]
	for id in rot_x.size():
		var cl := rot_clase[id]
		if cl > 3:
			continue
		var s := xf * Vector2(rot_x[id], rot_z[id])
		if caja.has_point(s):
			por_clase[cl].append([id, s])
	var por_ref := {}
	for lista_c in por_clase:
		for e in lista_c:
			if usados >= g_rotulos.size():
				break
			var s: Vector2 = e[1]
			var ref := rot_ref[int(e[0])]
			var lista: Array = por_ref.get(ref, [])
			var cerca := false
			for o in lista:
				if (o as Vector2).distance_to(s) < 180.0:
					cerca = true
					break
			if cerca:
				continue
			var l: Label = g_rotulos[usados]
			l.add_theme_font_size_override("font_size", 13)
			if _poner(l, ref, s, ocupado, Color(1.0, 0.92, 0.75)):
				usados += 1
				lista.append(s)
				por_ref[ref] = lista
	for i in range(usados, g_rotulos.size()):
		g_rotulos[i].visible = false


func _entrada_grande(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				_zoom(0.8 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.25, mb.position)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			quitar_destino()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_arrastre = true
				_arrastre_mov = 0.0
			else:
				_arrastre = false
				if _arrastre_mov < 6.0:
					poner_destino(_a_mapa(mb.position))
	elif ev is InputEventMouseMotion and _arrastre:
		var mm := ev as InputEventMouseMotion
		_arrastre_mov += mm.relative.length()
		centro -= mm.relative * m_px
		_vista()


func _a_mapa(s: Vector2) -> Vector2:
	var tam := grande.get_viewport_rect().size
	return centro + (s - tam * 0.5) * m_px


func _zoom(f: float, en: Vector2) -> void:
	var antes := _a_mapa(en)
	m_px = clampf(m_px * f, 2.0, 220.0)
	var tam := grande.get_viewport_rect().size
	centro = antes - (en - tam * 0.5) * m_px
	_vista()


func _mover_con_mando(dt: float) -> void:
	var mov := Vector2(Input.get_joy_axis(0, JOY_AXIS_LEFT_X), Input.get_joy_axis(0, JOY_AXIS_LEFT_Y))
	var tec := Vector2(float(Input.is_physical_key_pressed(KEY_RIGHT) or Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_LEFT) or Input.is_physical_key_pressed(KEY_A)),
			float(Input.is_physical_key_pressed(KEY_DOWN) or Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_UP) or Input.is_physical_key_pressed(KEY_W)))
	if tec != Vector2.ZERO:
		mov = tec.normalized()
	if Input.is_physical_key_pressed(KEY_EQUAL) or Input.is_physical_key_pressed(KEY_KP_ADD) or Input.is_physical_key_pressed(KEY_PAGEUP):
		m_px = clampf(m_px * pow(2.0, -1.5 * dt), 2.0, 220.0)
		_vista()
	if Input.is_physical_key_pressed(KEY_MINUS) or Input.is_physical_key_pressed(KEY_KP_SUBTRACT) or Input.is_physical_key_pressed(KEY_PAGEDOWN):
		m_px = clampf(m_px * pow(2.0, 1.5 * dt), 2.0, 220.0)
		_vista()
	var z := Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) - Input.get_joy_axis(0, JOY_AXIS_TRIGGER_LEFT)
	var cambio := false
	if mov.length() > 0.2:
		centro += mov * m_px * 700.0 * dt
		cambio = true
	if absf(z) > 0.2:
		m_px = clampf(m_px * pow(2.0, -z * 1.5 * dt), 2.0, 220.0)
		cambio = true
	if cambio:
		_vista()


## Tramos a los que se puede llegar desde el paso c respetando los giros de MaGps (recorrido del grafo de giros)
func _preparar_alcance(c: int) -> void:
	if c == _alcance_desde:
		return
	_alcance_desde = c
	_alcance = PackedByteArray()
	_alcance.resize(datos.tramos.size())
	var visto := PackedByteArray()
	visto.resize(datos.tramos.size() * 2)
	var pila := PackedInt32Array([c])
	visto[c] = 1
	while not pila.is_empty():
		var x := pila[pila.size() - 1]
		pila.resize(pila.size() - 1)
		_alcance[x >> 1] = 1
		for j in range(gps.suc_i[x], gps.suc_i[x + 1]):
			var y := gps.suc_c[j]
			if visto[y] == 0:
				visto[y] = 1
				pila.append(y)


## Destino en el punto p (X, Z): la vía más cercana (a menos de 3 km) a la que se puede llegar, y la ruta hasta ella
func poner_destino(p: Vector2) -> void:
	if juego.camino.is_empty() or not gps.comprobar_grafo():
		return
	var e: Array = juego.camino[0]
	var t_a := Time.get_ticks_usec()
	_preparar_alcance(MaGps.codigo(e[0], e[1]))
	var ms_alc := (Time.get_ticks_usec() - t_a) / 1000.0
	var mejor := INF
	var kd := -1
	var pq := Vector2.ZERO
	var c0 := Vector2i(floori(p.x / CELDA), floori(p.y / CELDA))
	for r in 7:
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var lista = celdas.get(c0 + Vector2i(dx, dz))
				if lista == null:
					continue
				for k in lista:
					if _alcance[k] == 0 or int(datos.tramos[k]["tunel"]) == 1:
						continue
					var pts: PackedVector2Array = pts_tramo[k]
					for i in pts.size() - 1:
						var q := Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])
						var d := q.distance_to(p)
						if d < mejor:
							mejor = d
							kd = k
							pq = q
		if kd >= 0 and mejor < r * CELDA:
			break
	if kd < 0 or mejor > 3000.0:
		if abierto:
			g_info.text = "Ahí no hay ninguna carretera del juego a la que se pueda llegar"
		return
	var ref := MaGps.nombre_visible(str(datos.tramos[kd]["ref"]).split(";")[0])
	var calle := MaGps.nombre_visible(str(datos.tramos[kd]["nombre"]))
	var nombre := ref if ref != "" else calle
	var cerca := INF
	for lu in lugares:
		var d := Vector2(float(lu["x"]), float(lu["z"])).distance_to(pq)
		if d < 2500.0 and d < cerca:
			cerca = d
			nombre = str(lu["n"]) + ("  (" + ref + ")" if ref != "" else "")
	if nombre == "":
		nombre = "punto elegido"
	var y := float(datos.geometria(kd)[0].y)
	print("MAPA_DESTINO %s · tramo %d (%s) a %.0f m del clic · desde %s · alcance %.1f ms" % [nombre, kd, datos.rotulo(kd), mejor, str(e), ms_alc])
	_pendiente = "nuevo"
	gps.borrar()
	_dibujar_ruta()
	gps.pedir(e[0], e[1], juego.d_camino, kd, Vector3(pq.x, y, pq.y), nombre)
	g_destino.visible = true
	g_destino.position = g_capa.transform * pq
	if abierto:
		_vista()


func quitar_destino() -> void:
	gps.borrar()
	mini_ruta.mesh = null
	g_ruta.mesh = null
	if _llegada_t <= 0.0:
		panel_gps.visible = false
	juego._replanificar()
	if abierto:
		_vista()


func _dibujar_ruta() -> void:
	if not gps.activo():
		malla_ruta = null
		mini_ruta.mesh = null
		g_ruta.mesh = null
		return
	var ks: Array = []
	for c in gps.pasos:
		ks.append(c >> 1)
	malla_ruta = _cintas(ks, 7)
	mini_ruta.mesh = malla_ruta
	g_ruta.mesh = malla_ruta


# ------------------------------------------------------------------ teclas
func _unhandled_input(ev: InputEvent) -> void:
	if not listo:
		return
	if ev is InputEventKey and ev.pressed and not ev.echo:
		var k: int = (ev as InputEventKey).physical_keycode
		if k == KEY_M:
			abrir(not abierto)
			get_viewport().set_input_as_handled()
		elif abierto and k == KEY_ESCAPE:
			abrir(false)
			get_viewport().set_input_as_handled()
		elif abierto and (k == KEY_DELETE or k == KEY_BACKSPACE):
			quitar_destino()
			get_viewport().set_input_as_handled()
		elif abierto and (k == KEY_ENTER or k == KEY_KP_ENTER or k == KEY_SPACE):
			poner_destino(centro)
			get_viewport().set_input_as_handled()
		elif abierto and k == KEY_C:
			centro = Vector2(juego.coche.position.x, juego.coche.position.z)
			_vista()
			get_viewport().set_input_as_handled()
		elif not abierto and k == KEY_Z:
			radio_i = maxi(radio_i - 1, 0)
			get_viewport().set_input_as_handled()
		elif not abierto and k == KEY_X:
			radio_i = mini(radio_i + 1, RADIOS.size() - 1)
			get_viewport().set_input_as_handled()
		elif abierto:
			get_viewport().set_input_as_handled()     # con el mapa abierto, las teclas del juego no cuentan
	elif ev is InputEventJoypadButton and ev.pressed:
		var b: int = (ev as InputEventJoypadButton).button_index
		if b == JOY_BUTTON_TOUCHPAD or (b == JOY_BUTTON_START and abierto):
			abrir(not abierto)
			get_viewport().set_input_as_handled()
		elif abierto and b == JOY_BUTTON_A:
			poner_destino(centro)
			get_viewport().set_input_as_handled()
		elif abierto and b == JOY_BUTTON_B:
			quitar_destino()
			get_viewport().set_input_as_handled()
