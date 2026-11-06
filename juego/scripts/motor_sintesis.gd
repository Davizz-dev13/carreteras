## Motor v2: síntesis del sonido del motor en tiempo real por tablas de ciclo (pipeline/sonido_motor_v2.py).
## Cada tabla es UN ciclo de motor (720°) de un 4 en línea a unas rpm de la rejilla y a una carga (retención / plena),
## limitada en banda para esas rpm. Aquí se lee con un acumulador de fase: el tono sigue a las rpm de forma continua
## (sin clics ni escalones, sin bucles que se crucen), y el timbre se mezcla entre las tablas vecinas de rpm y carga.
## Los ruidos (flujo del escape, admisión, soplido y silbido del turbo, válvula de descarga) son bucles de ruido filtrado
## modulados por la envolvente de las explosiones. Cada explosión varía un poco (como en un motor de verdad).
## Coste: unas pocas lecturas de tabla por muestra a 22.050 Hz (≈1 % de un núcleo en este equipo).
class_name MotorSintesis
extends RefCounted

const RUTA := "res://datos/sonido/"
var fs := 22050.0
var n := 2048
var ne := 256
var rejilla := PackedFloat32Array()
var diesel := false
var ralenti := 800.0
var corte := 5000.0
var tablas := PackedFloat32Array()     # [rpm][carga][n]
var envs := PackedFloat32Array()       # [rpm][carga][ne]
var nz_flujo := PackedFloat32Array()
var nz_adm := PackedFloat32Array()
var nz_turbo := PackedFloat32Array()
var nz_soplo := PackedFloat32Array()
var seno := PackedFloat32Array()
var listo := false

# parámetros (los pone SonidoMotor cada fotograma; aquí van en rampa muestra a muestra)
var rpm := 800.0
var carga := 0.0
var turbo := 0.0
var ganancia := 1.0
var _p := PackedFloat32Array([800.0, 0.0, 0.0, 1.0])   # valores del bloque anterior: rpm, carga, turbo, ganancia

# estado
var _fase := 0.0
var _q := 0
var _gj := 1.0            # variación de la explosión en curso
var _gj_obj := 1.0
var _ji := 1.0            # pequeña variación de ritmo entre explosiones
var _in := 0              # posición en los bucles de ruido
var _wf := 0.0            # fase del silbido del turbo
var _soplo_i := -1        # muestra del soplo de la válvula (−1 = no suena)
var _soplo_g := 0.0
var _rng := RandomNumberGenerator.new()


func cargar(motor: String) -> bool:
	var f := FileAccess.open(RUTA + "motor_v2.json", FileAccess.READ)
	if f == null:
		return false
	var d = JSON.parse_string(f.get_as_text())
	if typeof(d) != TYPE_DICTIONARY or not d.get("motores", {}).has(motor):
		return false
	var m: Dictionary = d["motores"][motor]
	fs = float(d["fs"]); n = int(d["n"]); ne = int(d["ne"])
	rejilla = PackedFloat32Array(m["rejilla"])
	diesel = bool(m["diesel"]); ralenti = float(m["ralenti"]); corte = float(m["corte"])
	var b := FileAccess.get_file_as_bytes(RUTA + "motor_v2_%s.bin" % motor).to_float32_array()
	var nt := rejilla.size() * 2
	if b.size() != nt * (n + ne):
		push_warning("MotorSintesis: tabla %s de tamaño inesperado" % motor)
		return false
	tablas = b.slice(0, nt * n)
	envs = b.slice(nt * n)
	var r := FileAccess.get_file_as_bytes(RUTA + "ruidos_v2.bin").to_float32_array()
	var L := int(fs)
	var ri: Dictionary = d["ruidos"]
	nz_flujo = r.slice(int(ri["flujo_tdi" if diesel else "flujo_tsi"]) * L, (int(ri["flujo_tdi" if diesel else "flujo_tsi"]) + 1) * L)
	nz_adm = r.slice(int(ri["admision"]) * L, (int(ri["admision"]) + 1) * L)
	nz_turbo = r.slice(int(ri["turbo"]) * L, (int(ri["turbo"]) + 1) * L)
	nz_soplo = r.slice(int(ri["soplo"]) * L, (int(ri["soplo"]) + 1) * L)
	seno.resize(1024)
	for i in 1024:
		seno[i] = sin(TAU * i / 1024.0)
	_rng.seed = 12345
	_p[0] = ralenti; rpm = ralenti
	listo = true
	return true


## Dispara el soplido de la válvula de descarga (TSI al levantar el pie con presión de turbo)
func soplo(g: float) -> void:
	_soplo_i = 0
	_soplo_g = g


## Nivel (lineal) de la tabla a esas rpm y carga, igual que en el generador (para escalar los ruidos)
func _nivel(r: float, c: float) -> float:
	var x := clampf((r - ralenti) / (corte - ralenti), 0.0, 1.1)
	var db := -21.0 + 13.0 * pow(x, 0.8)
	var db0 := db - ((9.5 if diesel else 8.5) - 3.5 * x)
	return lerpf(db_to_linear(db0), db_to_linear(db), c)


## Genera k muestras (mono) en out (a partir de la posición o).
func generar(k: int, out: PackedVector2Array) -> void:
	if not listo or k <= 0:
		return
	var nr := rejilla.size()
	var r_f := clampf(rpm, rejilla[0], rejilla[nr - 1])
	# par de tablas de rpm para este bloque (las de la rpm final; el peso va en rampa)
	var i := 0
	while i < nr - 2 and r_f >= rejilla[i + 1]:
		i += 1
	var r0 := rejilla[i]
	var r1 := rejilla[i + 1]
	var w_a := clampf((clampf(_p[0], rejilla[0], rejilla[nr - 1]) - r0) / (r1 - r0), 0.0, 1.0)
	var w_b := clampf((r_f - r0) / (r1 - r0), 0.0, 1.0)
	var o00 := (i * 2) * n
	var o01 := (i * 2 + 1) * n
	var o10 := ((i + 1) * 2) * n
	var o11 := ((i + 1) * 2 + 1) * n
	var e0 := (i * 2) * ne
	var e1 := (i * 2 + 1) * ne
	var inv := 1.0 / float(k)
	var rpm_a := _p[0]
	var d_rpm := (rpm - rpm_a) * inv
	var c_a := _p[1]
	var d_c := (carga - c_a) * inv
	var t_a := _p[2]
	var d_t := (turbo - t_a) * inv
	var g_a := _p[3] * _nivel(_p[0], _p[1])
	var g_b := ganancia * _nivel(rpm, carga)
	var d_g := (g_b - g_a) * inv
	var d_w := (w_b - w_a) * inv
	var x_b := clampf((rpm - ralenti) / (corte - ralenti), 0.0, 1.0)
	var x_a := clampf((rpm_a - ralenti) / (corte - ralenti), 0.0, 1.0)
	# ganancias relativas de los ruidos (al principio y al final del bloque)
	var fl_a := (0.10 + 0.40 * pow(x_a, 1.5)) * (0.6 + 0.4 * c_a)
	var fl_b := (0.10 + 0.40 * pow(x_b, 1.5)) * (0.6 + 0.4 * carga)
	var ad_k := 1.0 if not diesel else 0.5
	var ad_a := c_a * (0.04 + 0.30 * pow(x_a, 1.3)) * ad_k
	var ad_b := carga * (0.04 + 0.30 * pow(x_b, 1.3)) * ad_k
	var d_fl := (fl_b - fl_a) * inv
	var d_ad := (ad_b - ad_a) * inv
	var sig := 0.035 if carga > 0.5 else 0.08
	sig *= 1.0 + 2.0 * maxf(0.0, 0.2 - x_b)
	var nf := float(n)
	var nmask := n - 1
	var nef := float(ne)
	var L := nz_flujo.size()
	var tw_k := 0.035 if diesel else 0.022
	var tw_f0 := 1800.0 if diesel else 2400.0
	var tw_f1 := 4800.0 if diesel else 5600.0
	var th_k := 0.10 if diesel else 0.13
	var r := rpm_a
	var c := c_a
	var tb := t_a
	var g := g_a
	var w := w_a
	var fl := fl_a
	var ad := ad_a
	var ph := _fase
	for s in k:
		r += d_rpm; c += d_c; tb += d_t; g += d_g; w += d_w; fl += d_fl; ad += d_ad
		ph += r / 120.0 / fs * _ji
		if ph >= 1.0:
			ph -= 1.0
		var q := int(ph * 4.0)
		if q != _q:
			_q = q
			_gj_obj = 1.0 + sig * _rng.randfn()
			_ji = 1.0 + 0.004 * sig / 0.035 * _rng.randfn()
		_gj += (_gj_obj - _gj) * 0.02
		var pos := ph * nf
		var a0 := int(pos)
		var fr := pos - a0
		var a1 := (a0 + 1) & nmask
		var t00 := tablas[o00 + a0] + (tablas[o00 + a1] - tablas[o00 + a0]) * fr
		var t01 := tablas[o01 + a0] + (tablas[o01 + a1] - tablas[o01 + a0]) * fr
		var t10 := tablas[o10 + a0] + (tablas[o10 + a1] - tablas[o10 + a0]) * fr
		var t11 := tablas[o11 + a0] + (tablas[o11 + a1] - tablas[o11 + a0]) * fr
		var lo := t00 + (t01 - t00) * c
		var hi := t10 + (t11 - t10) * c
		var harm := lo + (hi - lo) * w
		var ei := int(ph * nef)
		var env := envs[e0 + ei] + (envs[e1 + ei] - envs[e0 + ei]) * c
		_in += 1
		if _in >= L: _in = 0
		var y := harm * _gj + (nz_flujo[_in] * env * fl + nz_adm[_in] * (0.5 + 0.5 * env) * ad) * 1.0
		var y_n := 0.0
		if tb > 0.02:
			var tb2 := tb * tb
			_wf += (tw_f0 + (tw_f1 - tw_f0) * tb) / fs
			if _wf >= 1.0: _wf -= 1.0
			y_n = nz_turbo[_in] * th_k * tb2 * tb + seno[int(_wf * 1024.0)] * tw_k * tb2
		if _soplo_i >= 0:
			var ts := _soplo_i / fs
			y_n += nz_soplo[_soplo_i % L] * _soplo_g * (1.0 - exp(-ts / 0.012)) * exp(-ts / 0.16)
			_soplo_i += 1
			if _soplo_i > int(fs * 0.9): _soplo_i = -1
		var v := (y + y_n * 0.25) * g
		out[s] = Vector2(v, v)
	_fase = ph
	_p[0] = rpm; _p[1] = carga; _p[2] = turbo; _p[3] = ganancia
