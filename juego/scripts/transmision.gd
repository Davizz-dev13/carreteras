## Cambio DSG de 7 marchas y mapa del motor de la versión elegida (v4).
## · Relaciones totales REALES por marcha (relación × grupo final I/II del DQ381) y circunferencia de rodadura:
##   datos/coches/cambios_consumo.json (cada cifra con su fuente; las del R y del TSI 280 son proxys marcados).
## · Lo que VW no publica (ralentí, corte, forma de la curva de par, rozamiento): datos/coches/motor_supuestos.json,
##   cada valor marcado como supuesto y con su razonamiento.
## Fuerza en rueda en una marcha = par(rpm) × relación total × rendimiento de transmisión / radio de rueda,
## sin pasar de la fuerza máxima de tracción. Esa fuerza máxima se RECALIBRA aquí (mismo método que ficha.gd, pero
## simulando marchas y cambios) para que el 0-100 siga siendo el oficial: las marchas redistribuyen la curva de
## fuerza que ya tenía el juego, no cambian las prestaciones.
## El pedal (0…1) pide una fracción de la fuerza máxima que el coche puede dar a esa velocidad (la mejor marcha);
## el DSG elige la marcha: sube pronto en conducción suave, reduce cuando hace falta más fuerza (cuestas, a fondo) y
## reduce para retener al frenar o bajando.
class_name Transmision
extends RefCounted

const RUTA_CAMBIOS := "res://datos/coches/cambios_consumo.json"
const RUTA_SUPUESTOS := "res://datos/coches/motor_supuestos.json"
const RHO := 1.2
const G := 9.81
const DT_CAL := 1.0 / 60.0              # mismo paso que la física del juego

static var _json := {}                  # ruta -> Dictionary (se lee una vez)
static var _f_trac_cache := {}          # id de versión -> fuerza de tracción calibrada (N)

var ficha: Ficha
var rel := PackedFloat64Array()         # relación total de cada marcha (1ª…7ª)
var rel_r := 13.0                       # relación total de la marcha atrás
var r_rueda := 2.06 / TAU               # radio de rodadura (m)
var ralenti := 800.0
var corte := 5000.0
var par_a := 1600.0                     # rpm: inicio y fin del par máximo
var par_b := 2750.0
var pot_c := 3000.0                     # rpm: inicio y fin de la potencia máxima
var pot_d := 4200.0
var diesel := true
var cilindrada_l := 2.0
var rpm_sube := 1800.0                  # cambio ascendente en conducción suave
var rpm_min := 1100.0                   # no circula por debajo de esto con carga (reduce)
var rpm_retener := 2800.0               # reducciones para retener (freno / bajada)
var f_trac := 6000.0                    # fuerza máxima de tracción (N), calibrada con el cambio
var proxy := false                      # relaciones de un coche hermano, no del Arteon
var _tabla := PackedFloat32Array()      # fuerza máxima (mejor marcha) cada 0,5 m/s
const PASO_TABLA := 0.5

# --- estado ---
var marcha := 1                         # 1…7 · -1 = R
var rpm := 800.0                        # rpm del motor (lo que marca el cuentarrevoluciones)
var cambio_t := 0.0                     # s que quedan del cambio en curso
var cambio_dur := 0.25
var cambio_caida := 0.4
var rpm_antes := 800.0                  # rpm al empezar el cambio (para la aguja)
var bloqueo := 0.0                      # s sin volver a cambiar tras un cambio
var fuerza := 0.0                       # fuerza motriz entregada en rueda (N, ≥ 0)
var retencion := 0.0                    # freno motor disponible en rueda (N, ≥ 0)
var potencia_motor := 0.0               # W en el cigüeñal (≥ 0)
var corte_inyeccion := false            # pie levantado con marcha metida: no entra gasóleo/gasolina
var cambios := 0
var neutro := false                     # punto muerto (solo pruebas: rueda libre sin freno motor)
# modo manual secuencial (tiptronic, levas L1/R1 del mando o Mayús/Ctrl): el conductor elige la marcha; el cambio
# solo reduce solo para no calar (casi parado → 1ª, por debajo de ~1.000 rpm → una menos) y rechaza una reducción
# que pasaría del corte. El piloto automático y el tráfico siguen en automático.
var manual := false
var rechazo_t := 0.0                    # s que el HUD marca en rojo un cambio rechazado
var _va := 0.0                          # última velocidad vista en paso() (para decidir un cambio pedido)


func _init(f: Ficha) -> void:
	ficha = f
	var cc: Dictionary = _leer(RUTA_CAMBIOS)
	var sp: Dictionary = _leer(RUTA_SUPUESTOS)
	var dv: Dictionary = cc.get("versiones", {}).get(f.id, {})
	var sv: Dictionary = sp.get("versiones", {}).get(f.id, {})
	r_rueda = float(cc.get("circunferencia_rodadura_m", 2.06)) / TAU
	if dv.has("relacion_total"):
		for x in dv["relacion_total"]: rel.append(float(x))
		rel_r = float(dv.get("relacion_total_reversa", 13.0))
		proxy = bool(dv.get("relaciones_proxy", false))
	else:
		# versión sin datos de cambio: 7 marchas geométricas que cubren de 7,7 a 60 km/h por cada 1.000 rpm (supuesto)
		for i in 7: rel.append(16.0 * pow(1.854 / 16.0, i / 6.0))
		proxy = true
	diesel = f.combustible.to_lower().begins_with("di") if f.combustible != "" else str(sv.get("combustible", "")).begins_with("di")
	if sv.has("combustible"): diesel = str(sv["combustible"]).begins_with("di")
	ralenti = _valor(sv, "ralenti_rpm", 800.0 if diesel else 700.0)
	corte = _valor(sv, "corte_rpm", 5000.0 if diesel else 6500.0)
	var pr = _valor_lista(sv, "rpm_par_max", [1600, 2750])
	var pp = _valor_lista(sv, "rpm_potencia_max", [3000, 4200])
	par_a = float(pr[0]); par_b = float(pr[1]); pot_c = float(pp[0]); pot_d = float(pp[1])
	cilindrada_l = float(f.datos.get("cilindrada_cm3", _valor(sv, "cilindrada_cm3", 1968.0))) / 1000.0
	rpm_sube = 1800.0 if diesel else 2000.0
	rpm_min = 1100.0 if diesel else 1150.0
	rpm_retener = 2500.0 if diesel else 3200.0
	if _f_trac_cache.has(f.id):
		f_trac = _f_trac_cache[f.id]
		_hacer_tabla()
	else:
		_calibrar_traccion()
		_f_trac_cache[f.id] = f_trac


static func _leer(ruta: String) -> Dictionary:
	if not _json.has(ruta):
		var d = JSON.parse_string(FileAccess.get_file_as_string(ruta)) if FileAccess.file_exists(ruta) else null
		_json[ruta] = d if d is Dictionary else {}
	return _json[ruta]


static func _valor(d: Dictionary, k: String, defecto: float) -> float:
	var x = d.get(k, null)
	if x is Dictionary: x = x.get("valor", null)
	return float(x) if x != null else defecto


static func _valor_lista(d: Dictionary, k: String, defecto: Array) -> Array:
	var x = d.get(k, null)
	if x is Dictionary: x = x.get("valor", null)
	return x if x is Array and x.size() == 2 else defecto


# ---------------- motor ----------------
## Par máximo a plena carga (N·m) a unas rpm dadas
func par_max(n: float) -> float:
	var p := ficha.potencia_kw * 1000.0
	var t := ficha.par
	n = clampf(n, ralenti, corte)
	if n < par_a:
		return lerpf(0.55 * t, t, (n - ralenti) / maxf(par_a - ralenti, 1.0))
	if n <= par_b:
		return minf(t, p / (n * TAU / 60.0))
	if n < pot_c:
		return lerpf(minf(t, p / (par_b * TAU / 60.0)), p / (pot_c * TAU / 60.0), (n - par_b) / maxf(pot_c - par_b, 1.0))
	if n <= pot_d:
		return p / (n * TAU / 60.0)
	return p * (1.0 - 0.12 * (n - pot_d) / maxf(corte - pot_d, 1.0)) / (n * TAU / 60.0)


## Presión media de rozamiento (bar), supuesto (motor_supuestos.json)
static func fmep(n: float) -> float:
	var k := n / 1000.0
	return 0.97 + 0.15 * k + 0.05 * k * k


## Potencia que se come el rozamiento interno del motor a esas rpm (W)
func potencia_rozamiento(n: float) -> float:
	return fmep(n) * 1e5 * cilindrada_l * 1e-3 * n / 120.0


func rpm_rueda(v: float, g: int) -> float:
	var i := rel_r if g < 0 else rel[clampi(g, 1, 7) - 1]
	return absf(v) / r_rueda * i * 60.0 / TAU


## Fuerza máxima en rueda en la marcha g a la velocidad v (N). En 1ª a poca velocidad el embrague patina y el
## motor sube de vueltas (salida).
func f_marcha(v: float, g: int, pedal := 1.0) -> float:
	var nw := rpm_rueda(v, g)
	if nw >= corte:
		return 0.0
	var n := nw
	if g == 1 or g < 0:
		n = maxf(nw, ralenti + (1800.0 if diesel else 2500.0) * clampf(pedal, 0.0, 1.0))
	var i := rel_r if g < 0 else rel[g - 1]
	return minf(f_trac, par_max(n) * i * ficha.rendimiento / r_rueda)


## Freno motor en rueda con el pie levantado en la marcha g (N): rozamiento + bombeo (más en gasolina, mariposa cerrada)
func f_retencion(v: float, g: int) -> float:
	var nw := rpm_rueda(v, g)
	if g < 1 or nw < ralenti + 100.0:
		return 0.0                        # embrague abierto
	var t := fmep(nw) * 1e5 * cilindrada_l * 1e-3 / (4.0 * PI) * (1.0 if diesel else 1.5)
	return t * rel[g - 1] / r_rueda


## Mejor marcha a fondo para esa velocidad
func mejor_marcha(v: float) -> int:
	var mejor := 1
	var fm := -1.0
	for g in range(1, 8):
		if rpm_rueda(v, g) > corte * 0.98 and g < 7:
			continue
		var fg := f_marcha(v, g)
		if fg > fm * 1.0001:
			fm = fg
			mejor = g
	return mejor


## Fuerza máxima que puede dar el coche a esa velocidad con la mejor marcha (N). Es la base del pedal.
func fuerza_max(v: float) -> float:
	var x := absf(v) / PASO_TABLA
	var i := int(x)
	if i >= _tabla.size() - 1:
		return _tabla[_tabla.size() - 1]
	return lerpf(_tabla[i], _tabla[i + 1], x - i)


func _hacer_tabla() -> void:
	_tabla.clear()
	var v := 0.0
	while v < ficha.v_max + 10.0:
		_tabla.append(f_marcha(v, mejor_marcha(v)))
		v += PASO_TABLA


# ---------------- DSG ----------------
func reiniciar() -> void:
	marcha = 1
	rechazo_t = 0.0
	cambio_t = 0.0
	bloqueo = 0.0
	rpm = ralenti
	fuerza = 0.0
	retencion = 0.0
	potencia_motor = 0.0


## Un paso: elige marcha y devuelve la fuerza motriz en rueda (N, ≥ 0). Deja en `retencion` el freno motor
## disponible y en `rpm`/`potencia_motor`/`corte_inyeccion` el estado del motor (para el consumo y el HUD).
## seno: pendiente en el sentido de la marcha (− = bajada).
func paso(dt: float, v: float, pedal: float, freno: float, seno: float, atras := false) -> float:
	var va := absf(v)
	if atras:
		marcha = -1
		cambio_t = 0.0
		# v6: la fuerza de la marcha atrás real (relación total de R del DQ381 hasta el corte), no la de la mejor marcha
		# hacia delante; el tope de velocidad en R lo pone coche.gd (ficha_v_atras)
		fuerza = pedal * f_marcha(va, -1, pedal)
		retencion = 0.0
		rpm = minf(maxf(rpm_rueda(va, -1), ralenti + (900.0 * pedal)), corte)
		potencia_motor = fuerza * va / ficha.rendimiento
		corte_inyeccion = false
		return fuerza
	if marcha < 1:
		marcha = 1
	_va = va
	bloqueo -= dt
	rechazo_t -= dt
	var demanda := clampf(pedal, 0.0, 1.0) * fuerza_max(va)
	if manual:
		# el pedal pide una fracción del par de la marcha metida (sin kickdown); solo reduce para no calar
		demanda = clampf(pedal, 0.0, 1.0) * f_marcha(va, marcha, 1.0)
		if marcha > 1 and (va < 1.5 or (cambio_t <= 0.0 and rpm_rueda(va, marcha) < ralenti + 200.0)):
			_meter(1 if va < 1.5 else marcha - 1, pedal)
	elif cambio_t <= 0.0:
		var g := _elegir(va, pedal, demanda, freno, seno)
		if g != marcha:
			rpm_antes = rpm
			cambio_dur = 0.15 if pedal > 0.8 else 0.25
			cambio_caida = 0.5 if pedal > 0.8 else 0.4
			cambio_t = cambio_dur
			bloqueo = 0.6 if g > marcha else 0.35
			marcha = g
			cambios += 1
	var fg := f_marcha(va, marcha, pedal)
	var factor := 1.0
	var nw := rpm_rueda(va, marcha)
	var n_obj := nw
	if marcha == 1:
		n_obj = maxf(nw, ralenti + (1800.0 if diesel else 2500.0) * pedal) if pedal > 0.0 else maxf(nw, ralenti)
	n_obj = clampf(n_obj, ralenti, corte)
	if cambio_t > 0.0:
		var x := 1.0 - cambio_t / cambio_dur
		factor = 1.0 - cambio_caida * sin(PI * x)
		rpm = lerpf(rpm_antes, n_obj, x)
		cambio_t -= dt
	else:
		rpm = n_obj
	fuerza = minf(demanda, fg) * factor if pedal > 0.0 else 0.0
	retencion = f_retencion(va, marcha) if pedal <= 0.0 and not neutro else 0.0
	potencia_motor = fuerza * va / ficha.rendimiento
	corte_inyeccion = pedal <= 0.0 and nw > ralenti + 200.0 and not neutro
	if neutro: rpm = ralenti
	return fuerza


func _elegir(va: float, pedal: float, demanda: float, freno: float, seno: float) -> int:
	var g := marcha
	var nw := rpm_rueda(va, g)
	if pedal > 0.0:
		var fg := f_marcha(va, g, pedal)
		var falta := fg < demanda * 0.97
		# con carga (cuestas, aceleraciones) el DSG no deja caer tanto las vueltas
		var n_min := rpm_min + 800.0 * clampf(pedal * 2.0, 0.0, 1.0)
		var arrastra := g > 1 and nw < n_min * 0.88
		if (falta or arrastra) and (bloqueo <= 0.0 or fg < demanda * 0.8 or nw < ralenti + 150.0):
			# kickdown: la marcha más larga que da la fuerza pedida con margen y sin pasar de vueltas
			for k in range(7, 0, -1):
				var nk := rpm_rueda(va, k)
				if nk < corte * 0.95 and (nk >= n_min * 0.95 or k == 1) and f_marcha(va, k, pedal) >= demanda * 1.08:
					return k
			return mejor_marcha(va)
		if bloqueo > 0.0 or g >= 7:
			return g
		# a fondo: sube cuando la siguiente da más fuerza o al llegar al corte
		var f2 := f_marcha(va, g + 1, pedal)
		if pedal > 0.85 and (f2 > fg * 1.001 or nw >= corte * 0.97):
			return g + 1
		# conducción normal: el punto de cambio sube con el pedal
		var umbral := lerpf(rpm_sube, corte * 0.95, pow(clampf((pedal - 0.25) / 0.6, 0.0, 1.0), 1.5))
		if nw >= umbral and rpm_rueda(va, g + 1) >= n_min and f2 >= demanda * 1.12:
			return g + 1
		return g
	# pie levantado
	if bloqueo > 0.0:
		return g
	var retener := freno > 0.05 or seno < -0.03
	if retener and g > 1:
		var n_ret := rpm_retener * clampf(maxf(freno * 1.5, -seno * 12.0), 0.6, 1.0)
		if rpm_rueda(va, g - 1) <= n_ret:
			return g - 1
	if g > 1 and nw < ralenti + 250.0:
		return g - 1
	if not retener and g < 7 and nw > rpm_sube + 900.0:
		return g + 1
	return g


func _meter(g: int, pedal: float) -> void:
	rpm_antes = rpm
	cambio_dur = 0.15 if pedal > 0.8 or manual else 0.25
	cambio_caida = 0.5 if pedal > 0.8 else 0.4
	cambio_t = cambio_dur
	bloqueo = 0.6 if g > marcha else 0.35
	marcha = g
	cambios += 1


## Leva: +1 sube, −1 baja. Pasa a modo manual con la marcha pedida. Devuelve false si se rechaza (la reducción
## pasaría del corte, no hay marcha más larga/corta, o la subida dejaría el motor por debajo del ralentí).
func pedir_cambio(d: int) -> bool:
	manual = true
	if marcha < 1:
		return false                      # en marcha atrás las levas no hacen nada (el modo manual queda puesto)
	var g := clampi(marcha + d, 1, 7)
	var nw := rpm_rueda(_va, g)
	if g == marcha or (d < 0 and nw > corte * 0.97) or (d > 0 and nw < ralenti + 200.0):
		rechazo_t = 0.6
		return false
	_meter(g, 1.0)
	return true


## Vuelve al cambio automático (D)
func automatico() -> void:
	manual = false
	bloqueo = 0.0


## "D4", "M4", "R" para el HUD
func texto_marcha() -> String:
	if marcha < 0: return "R"
	return ("M%d" if manual else "D%d") % marcha


# ---------------- calibración del 0-100 ----------------
## 0-100 en llano a fondo con este cambio, con el mismo paso de 60 Hz y las mismas cuentas que coche.gd
func simular_0_100(f_max: float) -> float:
	f_trac = f_max
	_hacer_tabla()
	reiniciar()
	var v := 0.0
	var t := 0.0
	while v < 100.0 / 3.6 and t < 60.0:
		var f := paso(DT_CAL, v, 1.0, 0.0, 0.0)
		f -= 0.5 * RHO * ficha.cx_a * v * v + ficha.crr * ficha.masa * G
		v += f / ficha.masa * DT_CAL
		t += DT_CAL
	reiniciar()
	return t


func _calibrar_traccion() -> void:
	var lo := ficha.f_traccion_max * 0.98   # con marchas nunca acelera más que la envolvente ideal: no hace falta menos
	var hi := 1.05 * ficha.masa * G * (1.0 if ficha.es_4x4() else 0.6)   # límite de adherencia (como ficha.gd)
	if simular_0_100(hi) > ficha.t_0_100:
		f_trac = hi
	else:
		for i in 14:
			var mid := (lo + hi) * 0.5
			if simular_0_100(mid) > ficha.t_0_100: lo = mid
			else: hi = mid
		f_trac = hi
	_hacer_tabla()
	reiniciar()
