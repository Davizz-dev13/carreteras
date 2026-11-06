## Ficha técnica de una versión real de un coche (se lee de datos/coches/coches.json).
## Las cifras de fábrica (potencia, par, masa, medidas, velocidad máxima, 0-100) vienen con su fuente en el JSON.
## A partir de ellas se DERIVAN los parámetros de la física, y cada derivación queda explicada aquí:
##   · cx_a (Cx · área frontal): Cx publicado × área frontal publicada; si no hay área publicada,
##     área ≈ 0,84 × ancho × alto (aproximación estándar en turismos).
##   · potencia en rueda = potencia × rendimiento de transmisión. El rendimiento se obtiene de la velocidad
##     máxima oficial cuando NO está limitada electrónicamente (potencia en rueda = resistencia a esa velocidad).
##   · SIN LIMITADOR (petición de David, nov. 2026): las versiones limitadas de fábrica a 250 km/h corren hasta su
##     velocidad máxima real. Si la marca publica la cifra sin limitador ("vel_max_sin_limitador_kmh" en el JSON,
##     con su fuente; p. ej. el Arteon R con el paquete R-Performance: 270 km/h) el rendimiento sale de ella como
##     en las no limitadas. Si no la publica, se usa el rendimiento de la versión hermana que se indique
##     ("rendimiento_como": mismo motor/cambio/tracción) y la velocidad máxima es la que da la física
##     (potencia en rueda = resistencia): es una ESTIMACIÓN y el menú lo dice. v_max_fabrica_kmh guarda la oficial.
##   · fuerza de tracción máxima: se calibra para que el 0-100 simulado en llano dé el 0-100 oficial,
##     sin pasar del límite de adherencia de las ruedas motrices (≈60 % del peso en tracción delantera, 100 % en 4Motion).
class_name Ficha
extends RefCounted

const G := 9.81
const RHO := 1.2

var id := ""
var nombre := ""
var marca := ""
var modelo := ""
var modelo_id := ""
var potencia_cv := 0.0
var potencia_kw := 0.0
var par := 0.0
var masa := 1500.0
var largo := 4.5
var ancho := 1.8
var alto := 1.45
var batalla := 2.7
var via := 1.58
var traccion := "delantera"
var cambio := ""
var v_max := 60.0            # m/s
var v_max_kmh := 216.0
var limitada := false        # de fábrica, velocidad máxima limitada electrónicamente (en el juego ya no: ver arriba)
var v_max_fabrica_kmh := 216.0   # velocidad máxima oficial de catálogo (250 en las limitadas)
var v_max_estimada := false      # sin cifra publicada sin limitador: la da la física con el rendimiento de la hermana
var rendimiento_fijo := -1.0     # rendimiento heredado de la versión hermana (Catalogo lo rellena), −1 = calcularlo
var t_0_100 := 9.0           # s (oficial)
var cx := 0.30
var area := 2.2
var crr := 0.011             # rodadura de un neumático de turismo en asfalto (valor típico, no es de la ficha)
var combustible := ""
var datos := {}              # la entrada completa del JSON (fuentes incluidas)

# --- derivados ---
var cx_a := 0.66
var rendimiento := 0.85
var potencia_rueda := 100000.0
var f_traccion_max := 9000.0
var f_freno_max := 14000.0
var t_0_100_sim := 0.0


static func desde_json(m: Dictionary, d: Dictionary) -> Ficha:
	var f := Ficha.new()
	f.datos = d
	f.modelo_id = m.get("id", "")
	f.marca = m.get("marca", "")
	f.modelo = m.get("modelo", "")
	f.id = d["id"]
	f.nombre = d.get("nombre", f.id)
	f.potencia_cv = float(d["potencia_cv"])
	f.potencia_kw = float(d.get("potencia_kw", f.potencia_cv * 0.7355))
	f.par = float(d.get("par_nm", 0.0))
	f.masa = float(d["masa_kg"])
	var dim: Dictionary = m.get("dimensiones", {})
	f.largo = float(d.get("largo_mm", dim.get("largo_mm", 4500))) / 1000.0
	f.ancho = float(d.get("ancho_mm", dim.get("ancho_mm", 1800))) / 1000.0
	f.alto = float(d.get("alto_mm", dim.get("alto_mm", 1450))) / 1000.0
	f.batalla = float(d.get("batalla_mm", dim.get("batalla_mm", 2700))) / 1000.0
	var vd = d.get("via_del_mm", dim.get("via_del_mm", null))
	f.via = float(vd) / 1000.0 if vd != null else f.ancho * 0.85
	f.traccion = d.get("traccion", "delantera")
	f.cambio = d.get("cambio", "")
	f.combustible = d.get("combustible", "")
	f.v_max_kmh = float(d["vel_max_kmh"])
	f.v_max_fabrica_kmh = f.v_max_kmh
	f.limitada = bool(d.get("vel_max_limitada", f.v_max_kmh >= 249.0))
	if f.limitada and d.has("vel_max_sin_limitador_kmh"):
		f.v_max_kmh = float(d["vel_max_sin_limitador_kmh"])     # cifra de la marca sin limitador
	f.v_max = f.v_max_kmh / 3.6
	f.t_0_100 = float(d["aceleracion_0_100_s"])
	var cxv = d.get("cx", null)
	if cxv == null: cxv = m.get("cx", null)       # misma carrocería: Cx del modelo
	f.cx = float(cxv) if cxv != null else 0.30
	var av = d.get("area_frontal_m2", null)
	if av == null: av = m.get("area_frontal_m2", null)
	f.area = float(av) if av != null else 0.84 * f.ancho * f.alto
	f._derivar()
	return f


func es_4x4() -> bool:
	return traccion.to_lower().contains("4motion") or traccion.to_lower().contains("4x4") or traccion.to_lower().contains("total")


func _derivar() -> void:
	cx_a = cx * area
	var p := potencia_kw * 1000.0
	v_max_estimada = false
	if limitada and not datos.has("vel_max_sin_limitador_kmh"):
		# sin cifra publicada: rendimiento de la hermana (o 0,85) y la velocidad máxima que da la física sin limitador
		rendimiento = rendimiento_fijo if rendimiento_fijo > 0.0 else 0.85
		v_max = _v_equilibrio(p * rendimiento)
		v_max_kmh = v_max * 3.6
		v_max_estimada = true
	else:
		var v := v_max
		rendimiento = clampf((0.5 * RHO * cx_a * v * v * v + crr * masa * G * v) / p, 0.70, 0.95)
	potencia_rueda = p * rendimiento
	var reparto := 1.0 if es_4x4() else 0.6
	var f_adh := 1.05 * masa * G * reparto      # μ ≈ 1,05 en arrancada con neumático de verano
	f_freno_max = 1.0 * masa * G               # frenada máxima ≈ 1 g en asfalto seco
	# calibración del 0-100: búsqueda binaria de la fuerza de tracción máxima
	var lo := 1000.0
	var hi := f_adh
	if _simular_0_100(hi) > t_0_100:
		f_traccion_max = hi                      # ni con toda la adherencia llega: nos quedamos en el límite
	else:
		for i in 30:
			var mid := (lo + hi) * 0.5
			if _simular_0_100(mid) > t_0_100: lo = mid
			else: hi = mid
		f_traccion_max = hi
	t_0_100_sim = _simular_0_100(f_traccion_max)


## Velocidad (m/s) a la que la potencia en rueda iguala la resistencia aerodinámica y de rodadura en llano
func _v_equilibrio(p_rueda: float) -> float:
	var lo := 10.0
	var hi := 150.0
	for i in 60:
		var v := (lo + hi) * 0.5
		if 0.5 * RHO * cx_a * v * v * v + crr * masa * G * v < p_rueda: lo = v
		else: hi = v
	return lo


## Rehace las derivadas con el rendimiento de la versión hermana (Catalogo, tras leer todas las fichas)
func heredar_rendimiento(r: float) -> void:
	rendimiento_fijo = r
	_derivar()


## Texto de la velocidad máxima para el menú: "270 km/h (sin limitador; de fábrica 250)"
func texto_v_max() -> String:
	if not limitada:
		return "%d km/h" % roundi(v_max_kmh)
	return "%d km/h%s (sin limitador; de fábrica limitada a %d)" % [roundi(v_max_kmh), " estimada" if v_max_estimada else "", roundi(v_max_fabrica_kmh)]


func _simular_0_100(f_max: float) -> float:
	var v := 0.0
	var t := 0.0
	var dt := 1.0 / 240.0
	while v < 100.0 / 3.6 and t < 60.0:
		var f := minf(f_max, potencia_rueda / maxf(v, 1.0)) - 0.5 * RHO * cx_a * v * v - crr * masa * G
		v += f / masa * dt
		t += dt
	return t


## Resumen en una línea para el menú y el HUD
func resumen() -> String:
	return ("%s · %d CV · %d Nm · %d kg · %s · 0-100 en %s s · %d km/h" % [nombre, roundi(potencia_cv), roundi(par), roundi(masa),
		traccion, ("%.1f" % t_0_100).replace(".", ","), roundi(v_max_kmh)])
