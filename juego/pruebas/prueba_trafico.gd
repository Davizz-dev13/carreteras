## Estadística del tráfico (sin ventana): velocidades deseadas y reales frente al límite y colas.
##   godot --headless --fixed-fps 60 res://pruebas/prueba_trafico.tscn -- --zona=a308 --ruta=0 --trafico=30 --segundos=600
extends Node

var tr: Trafico
var ruta: Ruta
var s_jug := 0.0
var sentido := 1
var frames := 0
var total := 0
var vistos := {}
var deseada_90: Array = []     # km/h de los que aparecen en tramos de 90 (escalado a 90)
var real_90: Array = []        # km/h reales cada segundo en tramos de 90
var colas: Array = []          # longitudes de cola (≥ 2 coches) muestreadas cada segundo
var en_cola := 0
var muestras := 0
var frenados := 0              # coches > 15 km/h por debajo de lo que quieren por ir detrás de otro


func _ready() -> void:
	Ajustes.cargar()
	var a := Ajustes.args
	if a.has("ruta"): Ajustes.ruta_idx = int(a["ruta"])
	ruta = Ajustes.ruta()
	total = int(float(a.get("segundos", "600")) * 60.0)
	tr = Trafico.new()
	tr.iniciar(ruta, float(a.get("trafico", "30")) / 100.0)
	add_child(tr)
	s_jug = minf(1400.0, ruta.longitud() * 0.5)
	var n90 := 0
	for v in ruta.vmax:
		if v == 90: n90 += 1
	print("RUTA %s  %.1f km  tramos de 90: %.0f %%" % [Ajustes.zona, ruta.longitud() / 1000.0, 100.0 * n90 / maxf(1, ruta.vmax.size())])


func _lim(s: float) -> int:
	return ruta.vmax[clampi(int(s / ruta.paso), 0, ruta.n - 1)]


func _physics_process(dt: float) -> void:
	# "jugador" fantasma: recorre la ruta a 80 km/h sin ocupar carril (no hace de líder de nadie)
	s_jug += sentido * 22.0 * dt
	if s_jug > ruta.longitud() - 300.0: sentido = -1
	if s_jug < 300.0: sentido = 1
	tr.actualizar(dt, s_jug, 0.0, 22.0, 0)
	frames += 1
	for c in tr.coches:
		var id: int = c["nodo"].get_instance_id()
		if not vistos.has(id):
			vistos[id] = true
			if _lim(c["s"]) == 90 and frames > 1:
				var f: float = c["f"] if c.has("f") else c["v0"] * 3.6 / 90.0
				deseada_90.append(f * 90.0)
	if frames % 60 == 0 and frames > 600:
		_muestrear()
	if frames % 3600 == 0:
		print("-- %d s simulados" % (frames / 60))
		_informe()
	if frames >= total:
		_informe()
		get_tree().quit()


func _muestrear() -> void:
	for d in [1, -1]:
		var l: Array = []
		for c in tr.coches:
			if c["dir"] == d: l.append(c)
		l.sort_custom(func(x, y): return x["s"] * d > y["s"] * d)   # de delante a atrás
		var cola := 1
		for i in l.size():
			var c: Dictionary = l[i]
			muestras += 1
			if _lim(c["s"]) == 90:
				real_90.append(c["v"] * 3.6)
			var siguiendo := false
			if i > 0:
				var hueco: float = absf(l[i - 1]["s"] - c["s"]) - tr.largo
				siguiendo = hueco < maxf(20.0, 3.0 * c["v"]) and c["v"] < minf(c["v0"], c["vc"]) - 2.0
			if siguiendo:
				cola += 1
				en_cola += 1
				if c["v"] < minf(c["v0"], c["vc"]) - 15.0 / 3.6: frenados += 1
			else:
				if cola >= 2: colas.append(cola)
				cola = 1
		if cola >= 2: colas.append(cola)


func _pct(a: Array, p: float) -> float:
	if a.is_empty(): return 0.0
	var b := a.duplicate()
	b.sort()
	return b[clampi(int(p * (b.size() - 1)), 0, b.size() - 1)]


func _informe() -> void:
	var sobre := 0
	for v in deseada_90:
		if v > 90.5: sobre += 1
	var hist := ""
	for lo in range(40, 130, 10):
		var n := 0
		for v in deseada_90:
			if v >= lo and v < lo + 10: n += 1
		hist += " %d-%d:%d" % [lo, lo + 10, n]
	var m := 0.0
	for x in colas: m += x
	print("DESEADA_90 n=%d p10=%.0f p50=%.0f p90=%.0f km/h | >90: %.0f %% | hist%s" % [deseada_90.size(),
		_pct(deseada_90, 0.1), _pct(deseada_90, 0.5), _pct(deseada_90, 0.9), 100.0 * sobre / maxf(1, deseada_90.size()), hist])
	print("REAL_90 n=%d p10=%.0f p50=%.0f p90=%.0f km/h" % [real_90.size(), _pct(real_90, 0.1), _pct(real_90, 0.5), _pct(real_90, 0.9)])
	print("COLAS: coches siguiendo a otro %.0f %% | colas medias %.2f coches (máx %d) | frenados >15 km/h %.0f %%" % [
		100.0 * en_cola / maxf(1, muestras), m / maxf(1, colas.size()), int(_pct(colas, 1.0)), 100.0 * frenados / maxf(1, muestras)])
