## Marcha atrás a fondo en llano (y en una subida del 8 % marcha atrás): velocidad máxima y tiempo hasta 20 km/h.
##   godot --headless res://pruebas/prueba_marcha_atras.tscn
extends Node

class Plano extends Superficie:
	var pend := 0.0
	func consultar(_x: float, z: float, _y: float) -> Vector3:
		return Vector3(-z * pend, 1.0, 0.0)

func _ready() -> void:
	call_deferred("_correr")

func _correr() -> void:
	var sup := Plano.new()
	Ajustes.superficie = sup
	for fi: Ficha in Catalogo.fichas:
		for p in [0.0, -0.08]:
			sup.pend = p
			var c := Coche.new(fi)
			c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
			var t := 0.0
			var t20 := -1.0
			var vmin := 0.0
			var rpm_max := 0.0
			while t < 20.0:
				c.marcha_atras = true
				c.acelerador = 1.0
				c.freno = 0.0
				c.volante = 0.0
				c.paso_fisica(1.0 / 60.0)
				t += 1.0 / 60.0
				vmin = minf(vmin, c.v)
				rpm_max = maxf(rpm_max, c.caja.rpm)
				if t20 < 0.0 and c.v <= -20.0 / 3.6: t20 = t
			print("ATRAS %-28s pend %+3.0f%% | máx %5.1f km/h | 0-20 km/h %4.1f s | rpm máx %4.0f | marcha %s" % [fi.id, -p * 100.0, -vmin * 3.6, t20, rpm_max, c.caja.texto_marcha()])
	get_tree().quit()
