## Dibuja el perfil de altitud real de una ruta, con el tramo elegido resaltado y (en juego) la posición del coche.
class_name Perfil
extends Control

var ruta: Ruta
var s0 := 0.0
var s1 := 0.0
var marcador := -1.0
var compacto := false


func _draw() -> void:
	if ruta == null:
		return
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.45))
	var L := ruta.longitud()
	var zmin := 1e9
	var zmax := -1e9
	var paso := maxi(1, ruta.n / 600)
	for i in range(0, ruta.n, paso):
		zmin = minf(zmin, ruta.pts[i].y)
		zmax = maxf(zmax, ruta.pts[i].y)
	zmin -= 20.0
	zmax += 20.0
	var m := 6.0 if compacto else 30.0
	var area := Rect2(m, 6.0, w - m - 6.0, h - (14.0 if compacto else 26.0))
	var aqui := func(s: float, z: float) -> Vector2:
		return Vector2(area.position.x + s / L * area.size.x, area.position.y + (1.0 - (z - zmin) / (zmax - zmin)) * area.size.y)
	var a := minf(s0, s1)
	var b := maxf(s0, s1)
	var linea := PackedVector2Array()
	for i in range(0, ruta.n, paso):
		var s := i * ruta.paso
		var p: Vector2 = aqui.call(s, ruta.pts[i].y)
		var dentro := s >= a and s <= b
		var col := Color(0.95, 0.35, 0.2, 0.85) if dentro else Color(0.6, 0.6, 0.6, 0.5)
		draw_line(Vector2(p.x, area.end.y), p, col, maxf(1.0, area.size.x / (ruta.n / float(paso))) + 0.6)
		linea.append(p)
	draw_polyline(linea, Color.WHITE, 1.5, true)
	if not compacto:
		var fuente := get_theme_default_font()
		for km in range(0, int(L / 1000.0 - 0.6) + 1, 2 if L > 12000 else 1):
			var p: Vector2 = aqui.call(km * 1000.0, zmin)
			draw_string(fuente, Vector2(p.x - 6, area.end.y + 16), str(km), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.85, 0.85))
		for z in range(int(ceil(zmin / 200.0)) * 200, int(zmax), 200):
			var p: Vector2 = aqui.call(0.0, float(z))
			draw_string(fuente, Vector2(0, p.y + 4), str(z), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.8, 0.8, 0.8))
			draw_line(Vector2(area.position.x, p.y), Vector2(area.end.x, p.y), Color(1, 1, 1, 0.12))
		draw_string(fuente, Vector2(area.end.x - 26, area.end.y + 16), "km", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.85, 0.85))
	if marcador >= 0.0:
		var p: Vector2 = aqui.call(marcador, ruta.punto(marcador).y)
		draw_circle(p, 5.0, Color(1, 0.9, 0.1))
	for s in [s0, s1]:
		var p: Vector2 = aqui.call(s, ruta.punto(s).y)
		draw_line(Vector2(p.x, area.position.y), Vector2(p.x, area.end.y), Color(1, 1, 1, 0.6), 1.0)
