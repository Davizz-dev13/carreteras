## Suavidad del giro del volante (teclado y mando), sin escena: mide el ángulo de las ruedas y el del volante de la
## cabina en cada paso de física (60 Hz) y saca tirón (jerk), sobrepaso, temblor (cambios de sentido) y retraso.
##   godot --headless res://pruebas/prueba_suavidad_volante.tscn -- [--csv=/tmp/x.csv]
extends Node

class Plano extends Superficie:
	func consultar(_x: float, _z: float, _y: float) -> Vector3:
		return Vector3(0.0, 1.0, 0.0)

var csv: FileAccess

## ángulo del volante que se dibuja (grados, + = derecha)
func _volante_deg(c: Coche, st: Dictionary, dt: float) -> float:
	if c.has_method("angulo_volante_cabina"):
		return rad_to_deg(c.angulo_volante_cabina(dt))
	# versión anterior: fracción del tope a esta velocidad × 225°, suavizado de 1er orden (33 ms)
	var obj := c.fraccion_volante() * 225.0
	st["a"] = lerpf(st.get("a", 0.0), obj, 1.0 - exp(-dt * 30.0))
	return st["a"]

func _caso(nombre: String, f: Ficha, kmh: float, guion: Callable, dur: float) -> Dictionary:
	var c := Coche.new(f)
	c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
	c.v = kmh / 3.6
	var dt := 1.0 / 60.0
	for i in 60:
		c.acelerador = clampf(c.fuerza_resistente(c.v) / maxf(c.fuerza_motor(c.v), 1.0), 0.0, 1.0)
		c.volante = 0.0
		c.paso_fisica(dt)
	c.v = kmh / 3.6
	var st := {}
	var acel_c := clampf(c.fuerza_resistente(c.v) / maxf(c.fuerza_motor(c.v), 1.0), 0.0, 1.0)
	var t := 0.0
	var vs := PackedFloat32Array()
	var gs := PackedFloat32Array()
	var objs := PackedFloat32Array()
	while t < dur:
		var e: Dictionary = guion.call(t)
		c.giro_directo = false
		c.entrada_digital = e.get("digital", true) and float(e["vol"]) != 0.0
		c.volante = float(e["vol"])
		c.acelerador = acel_c if not e.get("freno", false) else 0.0
		c.freno = 0.7 if e.get("freno", false) else 0.0
		c.paso_fisica(dt)
		t += dt
		var a := _volante_deg(c, st, dt)
		vs.append(a)
		gs.append(rad_to_deg(c.giro))
		if csv: csv.store_line("%s,%.4f,%.3f,%.4f,%.2f,%.3f" % [nombre, t, a, rad_to_deg(c.giro), c.v * 3.6, float(e["vol"])])
	# métricas: tirón del volante (°/s³), aceleración angular, cambios de sentido de la velocidad angular (temblor)
	var jmax := 0.0
	var jrms := 0.0
	var amax := 0.0
	var rev := 0
	var w_ant := 0.0
	for i in range(3, vs.size()):
		var w := (vs[i] - vs[i - 1]) / dt
		var w1 := (vs[i - 1] - vs[i - 2]) / dt
		var w2 := (vs[i - 2] - vs[i - 3]) / dt
		var acc := (w - w1) / dt
		var acc1 := (w1 - w2) / dt
		var j := (acc - acc1) / dt
		jmax = maxf(jmax, absf(j)); jrms += j * j
		amax = maxf(amax, absf(acc))
		if absf(w) > 5.0 and absf(w_ant) > 5.0 and signf(w) != signf(w_ant): rev += 1
		if absf(w) > 5.0: w_ant = w
	jrms = sqrt(jrms / maxf(vs.size() - 3, 1))
	# sobrepaso del volante respecto a su valor final al mantener la tecla (medio segundo antes de soltar)
	var vmax := 0.0
	for x in vs: vmax = maxf(vmax, absf(x))
	return {"txt": "%-28s %3.0f km/h | volante máx %6.1f° | ruedas máx %5.2f° | tirón máx %9.0f °/s³ rms %8.0f | acel. ang. máx %7.0f °/s² | temblores %d" % [nombre, kmh, vmax, _maxabs(gs), jmax, jrms, amax, rev], "vs": vs}

func _maxabs(a: PackedFloat32Array) -> float:
	var m := 0.0
	for x in a: m = maxf(m, absf(x))
	return m

func _ready() -> void:
	call_deferred("_correr")

func _correr() -> void:
	Ajustes.superficie = Plano.new()
	if Ajustes.args.has("csv"):
		csv = FileAccess.open(str(Ajustes.args["csv"]), FileAccess.WRITE)
		csv.store_line("caso,t,volante,ruedas,kmh,entrada")
	var f: Ficha = null
	for fi: Ficha in Catalogo.fichas:
		if fi.id == "arteon_tdi150_dsg": f = fi
	var golpe := func(t: float) -> Dictionary: return {"vol": 1.0 if t > 0.3 and t < 2.3 else 0.0}
	var toques := func(t: float) -> Dictionary: return {"vol": 1.0 if fmod(t, 0.5) < 0.15 and t < 3.0 else 0.0}
	var zigzag := func(t: float) -> Dictionary: return {"vol": (1.0 if fmod(t, 1.6) < 0.8 else -1.0) if t > 0.3 and t < 3.5 else 0.0}
	var freno := func(t: float) -> Dictionary: return {"vol": 1.0 if t > 0.3 and t < 3.0 else 0.0, "freno": t > 1.2 and t < 2.2}
	var stick := func(t: float) -> Dictionary: return {"vol": clampf((t - 0.3) * 4.0, 0.0, 0.7) if t < 2.3 else 0.0, "digital": false}
	for kmh in [10.0, 50.0, 90.0, 120.0]:
		print("SUAV " + _caso("teclado_mantener", f, kmh, golpe, 3.5)["txt"])
		print("SUAV " + _caso("teclado_toques", f, kmh, toques, 3.5)["txt"])
		print("SUAV " + _caso("teclado_zigzag", f, kmh, zigzag, 4.5)["txt"])
		print("SUAV " + _caso("teclado_girar_frenar", f, kmh, freno, 3.5)["txt"])
		print("SUAV " + _caso("mando_70pc", f, kmh, stick, 3.0)["txt"])
	if csv: csv.close()
	print("SUAV fin")
	get_tree().quit()
