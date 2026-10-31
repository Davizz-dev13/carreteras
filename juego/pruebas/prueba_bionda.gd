## Prueba del choque contra los quitamiedos: coloca el coche a --kmh km/h con --angulo grados contra una bionda y
## registra velocidad, distancia de la esquina más metida a la cara de la valla y rumbo respecto a la valla.
## godot --headless --path . res://pruebas/prueba_bionda.tscn -- --modo=zona|madrid --zona=navacerrada --angulo=30 --kmh=60
extends Node

var juego: Node
var listo := false
var t := 0.0
var a := Vector2.ZERO
var n := Vector2.ZERO
var tg := Vector2.ZERO
var min_prof := 1e9
var v0 := 0.0

func _ready() -> void:
	process_physics_priority = 100
	var madrid: bool = Ajustes.args.get("modo", "zona") == "madrid"
	juego = load("res://escenas/madrid.tscn" if madrid else "res://escenas/juego.tscn").instantiate()
	add_child(juego)

func _elegir() -> void:
	var bi: Biondas
	var c: Coche = juego.coche
	if Ajustes.args.get("modo", "zona") == "madrid":
		var lista: Array = juego.mundo.biondas_cerca(c.position)
		var mejor := 1e9
		var cp := Vector2(c.position.x, c.position.z)
		for b in lista:
			for k in b.pa.size():
				var d: float = (b.pa[k] - cp).length()
				if d < mejor and d > 150.0 and (b.pb[k] - b.pa[k]).length() > 3.0:
					var k2: int = k + 1
					if k2 < b.pa.size() and b.pa[k2].distance_to(b.pb[k]) < 0.01 and k + 3 < b.pa.size() and b.pa[k + 3].distance_to(b.pb[k + 2]) < 0.01:
						mejor = d; bi = b; _fijar(b, k)
	else:
		bi = juego.biondas
		_fijar(bi, int(Ajustes.args.get("seg", str(bi.pa.size() / 2))))
	juego.piloto = false
	var ang := deg_to_rad(float(Ajustes.args.get("angulo", "30")))
	v0 = float(Ajustes.args.get("kmh", "60")) / 3.6
	var dirv := tg * cos(ang) - n * sin(ang)
	var antes := 0.8   # s hasta tocar
	var p2 := a + n * (v0 * antes * sin(ang) + c.ficha.ancho) - tg * (v0 * antes * cos(ang) + 4.0)
	var h: float = Ajustes.superficie.consultar(p2.x, p2.y, c.position.y).x
	c.colocar(Vector3(p2.x, h + 0.3, p2.y), Vector3(dirv.x, 0.0, dirv.y))
	c.v = v0
	print("BIONDA segmento a=%s n=%s angulo=%s v0=%.0f km/h" % [a, n, Ajustes.args.get("angulo", "30"), v0 * 3.6])

func _fijar(b, k: int) -> void:
	a = b.pa[k]; n = b.pn[k]; tg = (b.pb[k] - b.pa[k]).normalized()

func _physics_process(dt: float) -> void:
	if Time.get_ticks_msec() > 150000:
		print("BIONDA_TIEMPO_AGOTADO")
		get_tree().quit()
	if juego == null or not juego.cargado:
		return
	if not listo:
		listo = true
		_elegir()
		return
	t += dt
	var c: Coche = juego.coche
	var f3 := c.adelante()
	var f := Vector2(f3.x, f3.z)
	var r := Vector2(-f.y, f.x)
	var p := Vector2(c.position.x, c.position.z)
	var pr := 1e9
	for e in [p + f * c.ficha.largo * 0.5 + r * c.ficha.ancho * 0.5, p + f * c.ficha.largo * 0.5 - r * c.ficha.ancho * 0.5, p - f * c.ficha.largo * 0.5 + r * c.ficha.ancho * 0.5, p - f * c.ficha.largo * 0.5 - r * c.ficha.ancho * 0.5]:
		pr = minf(pr, (e - a).dot(n))
	min_prof = minf(min_prof, pr)
	var vel := (f * c.v + r * (c.v_lat + c.vy)).length()
	var ang_valla := rad_to_deg(f.angle_to(tg))
	if int(round(t * 60.0)) % 6 == 0:
		print("t=%.2f v=%.1f km/h (avance %.1f, lateral %.1f) esquina_a_valla=%.2f m centro_a_valla=%.2f m rumbo_vs_valla=%.1f° toques=%d altura=%.2f" % [t, vel * 3.6, c.v * 3.6, (c.v_lat + c.vy) * 3.6, pr, (p - a).dot(n), ang_valla, juego.toques_bionda, c.position.y])
	if t >= float(Ajustes.args.get("seg_prueba", "3.0")):
		print("BIONDA_RESUMEN v0=%.0f v_final=%.1f km/h min_esquina_a_valla=%.2f m (negativo = atravesó) toques=%d" % [v0 * 3.6, vel * 3.6, min_prof, juego.toques_bionda])
		get_tree().quit()
