## Bloque del motor junto al velocímetro (v4): marcha del DSG, rpm con una barra fina y dos cifras grandes de consumo:
## instantáneo y global (media desde el inicio del recorrido); debajo, en pequeño, los litros gastados y la cifra de
## homologación en gris solo como referencia.
class_name HudMotor
extends VBoxContainer

var l_marcha := Label.new()
var barra := Barra.new()
var l_inst := Label.new()
var l_media := Label.new()
var l_litros := Label.new()
var l_ref := Label.new()


class Barra extends Control:
	var fraccion := 0.0
	var roja := 0.9
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.15))
		var w := size.x * clampf(fraccion, 0.0, 1.0)
		draw_rect(Rect2(Vector2.ZERO, Vector2(w, size.y)), Color(1, 0.35, 0.25) if fraccion >= roja else Color(1, 1, 1, 0.85))
		draw_rect(Rect2(Vector2(size.x * roja, 0), Vector2(1, size.y)), Color(1, 0.35, 0.25, 0.8))


func _ready() -> void:
	add_theme_constant_override("separation", 2)
	l_marcha.add_theme_font_size_override("font_size", 22)
	barra.custom_minimum_size = Vector2(190, 5)
	barra.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l_inst.add_theme_font_size_override("font_size", 24)
	l_media.add_theme_font_size_override("font_size", 24)
	var fila := HBoxContainer.new()
	fila.add_theme_constant_override("separation", 10)
	l_litros.add_theme_font_size_override("font_size", 14)
	l_ref.add_theme_font_size_override("font_size", 14)
	l_ref.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	fila.add_child(l_litros)
	fila.add_child(l_ref)
	add_child(l_marcha)
	add_child(barra)
	add_child(l_inst)
	add_child(l_media)
	add_child(fila)


static func _n(x: float, dec: int) -> String:
	return (("%." + str(dec) + "f") % x).replace(".", ",")


static func _miles(x: int) -> String:
	var s := str(x)
	return s.left(s.length() - 3) + "." + s.right(3) if s.length() > 3 else s


func actualizar(c: Coche) -> void:
	var t := c.caja
	var cs := c.consumo
	l_marcha.text = "%s   %s rpm" % [t.texto_marcha(), _miles(int(round(t.rpm / 50.0)) * 50)]
	# cambio manual: la marcha en ámbar; un cambio rechazado (pasaría del corte) parpadea en rojo
	l_marcha.modulate = Color(1, 0.35, 0.25) if t.rechazo_t > 0.0 else (Color(1, 0.85, 0.4) if t.manual else Color.WHITE)
	barra.fraccion = t.rpm / t.corte
	barra.roja = (t.corte - (500.0 if t.diesel else 600.0)) / t.corte
	barra.queue_redraw()
	# cifra 1: instantáneo ("—" en corte de inyección; parado, en l/h; tope de pantalla 99,9)
	if cs.l100_inst < 0.0:
		l_inst.text = "inst. —"
	elif absf(c.v) < 0.6:
		l_inst.text = "inst. %s l/h" % _n(minf(cs.litros_h, 99.9), 1)
	else:
		l_inst.text = "inst. %s l/100 km" % _n(minf(cs.l100_inst, 99.9), 1)
	# cifra 2: global = media desde el inicio del recorrido (solo se pone a cero al empezar la ruta)
	l_media.text = "global %s l/100 km" % (_n(minf(cs.media(), 99.9), 1) if cs.metros > 50.0 else "—")
	l_litros.text = "%s l gastados" % _n(cs.litros, 2)
	l_ref.text = "%s %s" % [cs.ref_texto, _n(cs.wltp, 1)] if cs.wltp > 0.0 else ""
