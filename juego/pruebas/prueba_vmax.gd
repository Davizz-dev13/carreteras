## Velocidad máxima de cada versión en llano, a fondo, con la física del juego (coche.gd + transmision.gd):
##   godot --headless res://pruebas/prueba_vmax.tscn
## Para cada coche: velocidad estabilizada tras 240 s, la de su ficha, si viene sin limitador y la marcha/rpm.
extends Node

class Plano extends Superficie:
	func consultar(_x: float, _z: float, _y: float) -> Vector3:
		return Vector3(0.0, 1.0, 0.0)


func _ready() -> void:
	call_deferred("_correr")


func _correr() -> void:
	Ajustes.superficie = Plano.new()
	var dt := 1.0 / 60.0
	print("VMAX versión | vmax simulada km/h | ficha km/h | de fábrica km/h | limitador | rendimiento | marcha rpm | t a 200 s | t a 250 s")
	for fi: Ficha in Catalogo.fichas:
		var c := Coche.new(fi)
		c.position = Vector3.ZERO
		c.rumbo = 0.0
		c.acelerador = 1.0
		var vmax := 0.0
		var t200 := -1.0
		var t250 := -1.0
		for i in 14400:
			c.paso_fisica(dt)
			vmax = maxf(vmax, c.v)
			if t200 < 0.0 and c.v * 3.6 >= 200.0: t200 = i * dt
			if t250 < 0.0 and c.v * 3.6 >= 250.0: t250 = i * dt
		print("VMAX %s | %.1f | %.0f | %.0f | %s | %.3f | %s %d | %.1f | %.1f" % [fi.id, vmax * 3.6, fi.v_max_kmh, fi.v_max_fabrica_kmh,
			"sí" if fi.limitada else "no", fi.rendimiento, c.caja.texto_marcha(), roundi(c.caja.rpm), t200, t250])
		c.free()
	get_tree().quit()
