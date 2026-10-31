## Minimapa de la ruta (vista cenital, norte arriba): trazado, salida/llegada, parte ya recorrida y el coche.
## El trazado se calcula una vez; cada fotograma solo se redibuja si el coche se ha movido.
## Pulsar un punto del mapa lleva el coche al km de la ruta más cercano (igual que el perfil).
class_name MapaRuta
extends Control

var ruta: Ruta
var s0 := 0.0
var s1 := 0.0
var marcador := -1.0
var sentido := 1.0
var hover_s := -1.0
var _pts := PackedVector2Array()     # trazado en coordenadas del control
var _ss := PackedFloat32Array()      # km (en m) de cada punto
var _esc := 1.0
var _org := Vector2.ZERO
var _min := Vector2.ZERO
var _ultimo := -1e9

signal salto(s: float)


func preparar() -> void:
	if ruta == null:
		return
	var paso := maxi(1, ruta.n / 700)
	var mn := Vector2(1e12, 1e12)
	var mx := Vector2(-1e12, -1e12)
	for i in range(0, ruta.n, paso):
		var p := Vector2(ruta.pts[i].x, ruta.pts[i].z)
		mn = mn.min(p)
		mx = mx.max(p)
	var m := 8.0
	var tam := mx - mn
	_esc = minf((size.x - 2 * m) / maxf(tam.x, 1.0), (size.y - 2 * m) / maxf(tam.y, 1.0))
	_min = mn
	_org = Vector2(m, m) + (size - Vector2(2 * m, 2 * m) - tam * _esc) * 0.5
	_pts.clear()
	_ss.clear()
	for i in range(0, ruta.n, paso):
		_pts.append(_a_pantalla(Vector2(ruta.pts[i].x, ruta.pts[i].z)))
		_ss.append(i * ruta.paso)
	if (ruta.n - 1) % paso != 0:
		_pts.append(_a_pantalla(Vector2(ruta.pts[ruta.n - 1].x, ruta.pts[ruta.n - 1].z)))
		_ss.append((ruta.n - 1) * ruta.paso)
	queue_redraw()


func _a_pantalla(p: Vector2) -> Vector2:
	return _org + (p - _min) * _esc


## km de la ruta (en m) más cercano a un punto del control
func s_en(pos: Vector2) -> float:
	var mejor := 1e18
	var s := 0.0
	for i in _pts.size() - 1:
		var a := _pts[i]
		var b := _pts[i + 1]
		var ab := b - a
		var t := clampf((pos - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		var d := pos.distance_squared_to(a + ab * t)
		if d < mejor:
			mejor = d
			s = lerpf(_ss[i], _ss[i + 1], t)
	return s


func actualizar(s: float) -> void:
	marcador = s
	if absf(s - _ultimo) > 4.0:
		_ultimo = s
		queue_redraw()


func _gui_input(ev: InputEvent) -> void:
	if ruta == null or _pts.is_empty():
		return
	if ev is InputEventMouseMotion:
		hover_s = s_en(ev.position)
		queue_redraw()
	elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		salto.emit(s_en(ev.position))
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		hover_s = -1.0
		queue_redraw()
	elif what == NOTIFICATION_RESIZED:
		preparar()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.45))
	if _pts.size() < 2:
		return
	draw_polyline(_pts, Color(0.75, 0.75, 0.75, 0.55), 2.0, true)
	# tramo elegido y parte ya recorrida
	var a := minf(s0, s1)
	var b := maxf(s0, s1)
	var tramo := PackedVector2Array()
	var hecho := PackedVector2Array()
	var desde := minf(s0, marcador) if marcador >= 0.0 else 0.0
	var hasta := maxf(s0, marcador) if marcador >= 0.0 else 0.0
	for i in _pts.size():
		if _ss[i] >= a and _ss[i] <= b:
			tramo.append(_pts[i])
		if marcador >= 0.0 and _ss[i] >= desde and _ss[i] <= hasta:
			hecho.append(_pts[i])
	if tramo.size() >= 2:
		draw_polyline(tramo, Color(1, 1, 1, 0.9), 2.0, true)
	if hecho.size() >= 2:
		draw_polyline(hecho, Color(0.95, 0.45, 0.15), 3.0, true)
	draw_circle(_pto(s0), 4.0, Color(0.2, 0.85, 0.3))
	draw_circle(_pto(s1), 4.0, Color(0.95, 0.2, 0.2))
	draw_string(get_theme_default_font(), Vector2(size.x - 14, 14), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.8))
	if marcador >= 0.0:
		var p := _pto(marcador)
		var t3 := ruta.tangente(marcador) * sentido
		var t := Vector2(t3.x, t3.z).normalized()
		var nrm := Vector2(-t.y, t.x)
		draw_colored_polygon(PackedVector2Array([p + t * 8.0, p - t * 5.0 + nrm * 5.0, p - t * 5.0 - nrm * 5.0]), Color(1, 0.9, 0.1))
		draw_polyline(PackedVector2Array([p + t * 8.0, p - t * 5.0 + nrm * 5.0, p - t * 5.0 - nrm * 5.0, p + t * 8.0]), Color.BLACK, 1.0)
	if hover_s >= 0.0:
		var ph := _pto(hover_s)
		draw_circle(ph, 4.0, Color(0.3, 0.9, 1.0))
		var z := roundi(ruta.punto(hover_s).y)
		var etiqueta := "km " + ("%.1f" % (hover_s / 1000.0)).replace(".", ",") + " · " + ((str(z / 1000) + "." + ("%03d" % (z % 1000))) if z >= 1000 else str(z)) + " m"
		var fuente := get_theme_default_font()
		var w := fuente.get_string_size(etiqueta, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var x := clampf(ph.x - w * 0.5, 0.0, size.x - w)
		draw_rect(Rect2(x - 4, -20, w + 8, 18), Color(0, 0, 0, 0.7))
		draw_string(fuente, Vector2(x, -6), etiqueta, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.6, 0.95, 1.0))


func _pto(s: float) -> Vector2:
	var q := ruta.punto(s)
	return _a_pantalla(Vector2(q.x, q.z))
