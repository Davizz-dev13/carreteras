## Consumo de combustible (v4): recta de Willans calibrada con el consumo REAL de los dueños.
##   l/h = k · (P_motor + P_rozamiento(rpm) + P_accesorios)      (kW)
##   0 l/h con el pie levantado y marcha metida por encima de ralentí+200 rpm (corte de inyección en retención).
## P_motor sale del cambio (fuerza en rueda × velocidad / rendimiento), P_rozamiento de la presión media de rozamiento
## (supuesto, motor_supuestos.json) y P_accesorios es un supuesto (0,6 kW).
## k (l/kWh) se CALIBRA por versión: se simula el ciclo WLTC clase 3b (datos/coches/wltc_3b.json) con este mismo
## cambio y este mismo modelo, y se elige k para que la media salga igual a la de los dueños en Spritmonitor
## (datos/coches/cambios_consumo.json). El WLTP oficial se muestra solo como referencia.
class_name Consumo
extends RefCounted

const RUTA_WLTC := "res://datos/coches/wltc_3b.json"
static var _k_cache := {}               # id -> [k, media simulada antes de calibrar con k=1]

var caja: Transmision
var k := 0.25                           # l/kWh (calibrado)
var p_accesorios := 600.0               # W (supuesto)
var objetivo := 0.0                     # l/100 km reales (Spritmonitor) usados para calibrar
var wltp := 0.0                         # l/100 km homologación (referencia)
var ref_texto := "WLTP"                 # "WLTP" o "NEDC" si solo hay NEDC

var litros_h := 0.0                     # consumo instantáneo (l/h)
var l100_inst := 0.0                    # instantáneo suavizado (l/100 km); -1 = corte de inyección
var litros := 0.0                       # gastados en el tramo
var metros := 0.0                       # recorridos en el tramo


func _init(t: Transmision) -> void:
	caja = t
	var cc: Dictionary = Transmision._leer(Transmision.RUTA_CAMBIOS)
	var sp: Dictionary = Transmision._leer(Transmision.RUTA_SUPUESTOS)
	var dv: Dictionary = cc.get("versiones", {}).get(t.ficha.id, {})
	p_accesorios = Transmision._valor(sp.get("comunes", {}), "potencia_accesorios_kw", 0.6) * 1000.0
	objetivo = float(dv.get("consumo_objetivo_l100", dv.get("consumo_real_l100", 0.0)) if dv.get("consumo_objetivo_l100", dv.get("consumo_real_l100", null)) != null else 0.0)
	if dv.get("wltp_comb_l100", null) != null:
		wltp = float(dv["wltp_comb_l100"])
	elif dv.get("nedc_l100", null) != null:
		wltp = float(dv["nedc_l100"])
		ref_texto = "NEDC"
	if _k_cache.has(t.ficha.id):
		k = _k_cache[t.ficha.id][0]
	else:
		var r := calibrar()
		_k_cache[t.ficha.id] = r


## Potencia "de combustible" del motor en este instante (W): lo que multiplica k
func _potencia_willans(n: float) -> float:
	return caja.potencia_motor + caja.potencia_rozamiento(n) + p_accesorios


## Un paso de física: integra litros y metros del tramo y actualiza el instantáneo
func paso(dt: float, v: float) -> void:
	var va := absf(v)
	if caja.corte_inyeccion:
		litros_h = 0.0
	else:
		litros_h = k * _potencia_willans(caja.rpm) / 1000.0
	litros += litros_h / 3600.0 * dt
	metros += va * dt
	var inst := 99.9
	if caja.corte_inyeccion:
		inst = -1.0
	elif va > 0.5:
		inst = minf(litros_h / (va * 3.6) * 100.0, 99.9)
	if inst < 0.0 or l100_inst < 0.0:
		l100_inst = inst
	else:
		l100_inst = lerpf(l100_inst, inst, 1.0 - exp(-dt / 0.6))   # ≈0,6 s de filtro, como un ordenador de a bordo


func media() -> float:
	return litros / (metros / 1000.0) * 100.0 if metros > 50.0 else 0.0


func reiniciar() -> void:
	litros = 0.0
	metros = 0.0
	l100_inst = 0.0


## Simula el WLTC 3b siguiendo su perfil de velocidad en llano y devuelve [k calibrado, l/100 km con k = 1, km, s en corte]
func calibrar() -> Array:
	var d = JSON.parse_string(FileAccess.get_file_as_string(RUTA_WLTC)) if FileAccess.file_exists(RUTA_WLTC) else null
	if not (d is Dictionary) or objetivo <= 0.0:
		return [k, 0.0, 0.0, 0.0]
	var perfil: Array = d["kmh"]
	var fi := caja.ficha
	var dt := 0.1                        # el ciclo va por segundos: 10 pasos por segundo bastan (la prueba lo repite a 60 Hz)
	var e := 0.0                         # kWh "Willans" (lo que multiplica k)
	var dist := 0.0
	var t_corte := 0.0
	caja.reiniciar()
	for i in perfil.size() - 1:
		var v0 := float(perfil[i]) / 3.6
		var v1 := float(perfil[i + 1]) / 3.6
		var a := v1 - v0
		var pasos := int(round(1.0 / dt))
		for j in pasos:
			var v := lerpf(v0, v1, float(j) / pasos)
			var f := fi.masa * a + 0.5 * Transmision.RHO * fi.cx_a * v * v + (fi.crr * fi.masa * Transmision.G if v > 0.01 else 0.0)
			var fmax := caja.fuerza_max(v)
			var pedal := clampf(f / fmax, 0.0, 1.0) if f > 0.0 else 0.0
			var freno := clampf(-f / fi.f_freno_max, 0.0, 1.0) if f < 0.0 else 0.0
			caja.paso(dt, v, pedal, freno, 0.0)
			if f > 0.0:
				caja.potencia_motor = f * v / fi.rendimiento   # el ciclo manda: la potencia es la que pide el perfil
			if caja.corte_inyeccion:
				t_corte += dt
			else:
				e += _potencia_willans(caja.rpm) / 1000.0 * dt / 3600.0
			dist += v * dt
	caja.reiniciar()
	var l100_k1 := e / (dist / 1000.0) * 100.0
	k = objetivo / l100_k1
	return [k, l100_k1, dist / 1000.0, t_corte]
