## Tráfico en los dos sentidos de la ruta elegida.
## Cada vehículo sigue su carril (a la derecha, como en España) con el modelo IDM
## (Intelligent Driver Model, Treiber 2000): mantiene distancia con el de delante, hace cola detrás de
## los lentos y no entra en una curva más rápido de lo que permite su radio real.
## Para no cargar el portátil: solo existen coches a ±RADIO m del jugador y como máximo MAX_COCHES.
class_name Trafico
extends Node3D

const RADIO := 1300.0
const MAX_COCHES := 44
const HUECO_100 := 55.0       # m medios entre coches por sentido con tráfico al 100 %
const A_MAX := 1.4            # IDM: aceleración máxima (m/s²)
const B_COMODA := 2.2         # IDM: frenada cómoda (m/s²)
const T_SEG := 1.5            # IDM: tiempo de seguridad (s)
const S0 := 3.0               # IDM: distancia mínima parado (m)
const A_LAT := 2.6            # aceleración lateral de referencia (m/s²); cada conductor lleva la suya (alat)

## --- Velocidad deseada de cada conductor (ver README, «Tráfico: velocidades») ---
## Dato real: en carreteras convencionales españolas de 90 km/h, el 44 % de los turismos y furgonetas en flujo libre
## va por encima del límite (ETSC, PIN Flash 36 «Reducing speeding in Europe», 2019, fig. 4.3, datos del Ministerio
## del Interior). La dispersión no la publica ese informe: se usa una desviación típica del 12 % del límite
## (≈ 11 km/h en una de 90; APROXIMACIÓN, del orden de las medidas en carreteras de dos carriles europeas) y la media
## se ajusta para que salga ese 44 %. Clase lenta (furgonetas, coches viejos, gente tranquila): el límite legal de
## 80 km/h para «resto de vehículos» en convencionales (RD 1514/2018) y las medias de 70–90 km/h en carreteras de dos
## carriles (Garrido, «Estudio de velocidades», 1999) → 8 % entre el 72 y el 86 % del límite. Muy lentos («los que
## van a 50 en una de 90»): 2 %, entre el 55 y el 65 % (APROXIMACIÓN, sin dato publicado). En vías de límite bajo
## (travesías, 50 km/h) la desviación se estrecha (APROXIMACIÓN): factor_efectivo = 1 + (factor − 1) · k(límite).
const P_MUY_LENTO := 0.02
const P_LENTO := 0.08
const SIGMA_F := 0.12         # desviación típica del factor (fracción del límite) de los conductores "normales"
const MEDIA_F := 0.995        # media: con el 10 % de lentos, el total por encima del límite queda en ≈ 44 %
## Curvas: cada conductor acepta una aceleración lateral distinta (APROXIMACIÓN): mediana ≈ 2,8 m/s², del 10 % al 90 %
## ≈ 2,2–3,6 m/s², límites 1,8–4,0 (valores del orden de los medidos con turismos en curvas de carreteras de dos
## carriles, p. ej. Xu et al. 2015, «An Experimental Study on Lateral Acceleration of Cars…», Math. Probl. Eng.;
## Reymond et al. 2001). Los rápidos suelen apurar más en curva (correlación 0,5 con su velocidad).
const ALAT_MIN := 1.8
const ALAT_MAX := 4.0
var largo := 4.9              # largo real del coche del tráfico (de su ficha)
var ficha_trafico: Ficha

var ruta: Ruta
var factor := 0.3
var coches: Array = []        # {s, dir, v, v0, nodo}
var rng := RandomNumberGenerator.new()


func iniciar(r: Ruta, f: float) -> void:
	ruta = r
	factor = f
	rng.seed = 2026
	# de momento todo el tráfico es del mismo modelo que el coche elegido (VW Arteon), en colores reales de VW
	ficha_trafico = Catalogo.ficha_elegida()
	largo = ficha_trafico.largo


## Velocidad máxima "cómoda" en la curva más cerrada de los próximos metros (frenando a tiempo)
func vel_curva(s: float, dir: int, a_lat: float, horizonte := 160.0) -> float:
	var vmin := 1e9
	var d := 0.0
	while d <= horizonte:
		var k := absf(ruta.valor(ruta.curvatura, s + dir * d))
		var vk := sqrt(a_lat / maxf(k, 1e-5))
		vmin = minf(vmin, sqrt(vk * vk + 2.0 * B_COMODA * d))
		d += 5.0
	return vmin


func idm(v: float, v0: float, hueco: float, dv: float) -> float:
	var s_estrella := S0 + maxf(0.0, v * T_SEG + v * dv / (2.0 * sqrt(A_MAX * B_COMODA)))
	return A_MAX * (1.0 - pow(v / maxf(v0, 0.1), 4.0) - pow(s_estrella / maxf(hueco, 0.1), 2.0))


## carril: dir = +1 circula en el sentido de la ruta (carril derecho), -1 en sentido contrario
func carril_lateral(s: float, dir: int) -> float:
	return ruta.lateral_carril(s, dir)


func actualizar(dt: float, s_jug: float, lat_jug: float, v_jug: float, dir_jug_carril: int) -> void:
	if ruta == null:
		return
	_actualizar(dt, s_jug, lat_jug, v_jug, dir_jug_carril)
	_llenado_inicial = false


## Solo en la primera actualización se reparte el tráfico por todo el radio; después los coches nuevos aparecen lejos
## (antes se miraba Engine.get_process_frames() < 5, que en las pruebas sin ventana no avanza y hacía aparecer coches
## a 60 m del jugador durante toda la prueba)
var _llenado_inicial := true
func _actualizar(dt: float, s_jug: float, lat_jug: float, v_jug: float, dir_jug_carril: int) -> void:
	# --- aparecer / desaparecer ---
	for i in range(coches.size() - 1, -1, -1):
		var c: Dictionary = coches[i]
		if absf(c["s"] - s_jug) > RADIO + 250.0 or c["s"] < 0.0 or c["s"] > ruta.longitud():
			c["nodo"].queue_free()
			coches.remove_at(i)
	var objetivo := int(clampf(factor, 0.0, 1.0) * 2.0 * RADIO / HUECO_100)
	objetivo = mini(objetivo, MAX_COCHES / 2)
	for dir in [1, -1]:
		var n_dir := 0
		for c in coches:
			if c["dir"] == dir: n_dir += 1
		var intentos := 0
		while n_dir < objetivo and intentos < 6 and coches.size() < MAX_COCHES:
			intentos += 1
			# aparecen lejos (fuera de la vista) salvo al empezar la partida
			var s: float
			if _llenado_inicial:
				s = s_jug + rng.randf_range(-RADIO, RADIO)
				if absf(s - s_jug) < 60.0: continue
			else:
				s = s_jug + (rng.randf_range(RADIO * 0.7, RADIO) * (1 if rng.randf() < 0.5 else -1))
			if s < 5.0 or s > ruta.longitud() - 5.0: continue
			var libre := true
			for c in coches:
				if c["dir"] == dir and absf(c["s"] - s) < 35.0: libre = false
			if not libre: continue
			_crear(s, dir)
			n_dir += 1
	# --- IDM ---
	var cuadro := Engine.get_physics_frames()
	for k in coches.size():
		var c: Dictionary = coches[k]
		if (cuadro + k) % 12 == 0:
			c["vc"] = vel_curva(c["s"], c["dir"], c.get("alat", A_LAT))
			if c.has("f"):
				c["v0"] = vel_deseada(c["s"], c["dir"], c["f"])
		var dir: int = c["dir"]
		var s: float = c["s"]
		var hueco := 1e4
		var v_lider: float = c["v0"]
		for o in coches:
			if o == c or o["dir"] != dir: continue
			var d: float = (o["s"] - s) * dir
			if d > 0.0 and d - largo < hueco:
				hueco = d - largo
				v_lider = o["v"]
		# el jugador también es un "líder" si va por este carril
		if dir_jug_carril == dir:
			var d: float = (s_jug - s) * dir
			if d > 0.0 and d - largo < hueco:
				hueco = d - largo
				v_lider = v_jug
		if c.get("fijo", false):
			continue          # coche de prueba (verificación): mantiene su velocidad
		var v0: float = minf(c["v0"], c["vc"])
		var v: float = c["v"]
		var a := idm(v, v0, hueco, v - v_lider)
		a = maxf(a, -9.0)
		c["v"] = maxf(0.0, v + a * dt)
	for c in coches:
		if c.get("suelto", false):
			continue          # tras un choque se mueve como cuerpo libre (Colisiones.mover_sueltos)
		c["s"] += c["v"] * c["dir"] * dt
		_colocar(c)
		Catalogo.animar_ruedas(c["modelo"], c["v"] * dt, 0.0)


## Para las pruebas automáticas: pone un coche en s, en el carril del sentido dir, a v m/s
func crear_prueba(s: float, dir: int, v: float, fijo: bool) -> Dictionary:
	_crear(s, dir)
	var c: Dictionary = coches[coches.size() - 1]
	c.erase("f")              # velocidad fija dada por la prueba, no la de su conductor
	c["alat"] = A_LAT
	c["v"] = v
	c["v0"] = v
	c["vc"] = 1e9 if fijo else c["vc"]
	c["fijo"] = fijo
	return c


func _crear(s: float, dir: int) -> void:
	var nodo := Node3D.new()
	var modelo := Catalogo.crear_modelo(ficha_trafico, Catalogo.color_aleatorio(ficha_trafico, rng), 1)
	nodo.add_child(modelo)
	add_child(nodo)
	var cond := conductor()
	var v0 := vel_deseada(s, dir, cond["f"])
	var vc := vel_curva(s, dir, cond["alat"])
	var c := {"s": s, "dir": dir, "v": minf(v0, vc), "v0": v0, "vc": vc, "nodo": nodo, "modelo": modelo,
			"f": cond["f"], "alat": cond["alat"]}
	coches.append(c)
	_colocar(c)
	nodo.reset_physics_interpolation()     # recién aparecido: sin interpolar desde el origen


## Sortea un conductor: f = su velocidad deseada como fracción del límite (en una vía de 90 km/h) y alat = la
## aceleración lateral que acepta en curva (m/s²). Usa el rng con semilla fija: el reparto es siempre el mismo.
func conductor() -> Dictionary:
	var u := rng.randf()
	var z := rng.randfn(0.0, 1.0)
	var f: float
	if u < P_MUY_LENTO:
		f = rng.randf_range(0.55, 0.65)
		z = -absf(z)
	elif u < P_MUY_LENTO + P_LENTO:
		f = rng.randf_range(0.72, 0.86)
		z = -absf(z)
	else:
		f = clampf(MEDIA_F + SIGMA_F * z, 0.72, 1.32)
	var za := 0.5 * z + 0.866 * rng.randfn(0.0, 1.0)
	var alat := clampf(2.8 * exp(0.19 * za), ALAT_MIN, ALAT_MAX)
	return {"f": f, "alat": alat}


## Límite de la vía (m/s) en s
func limite(s: float) -> float:
	return float(ruta.vmax[clampi(int(s / ruta.paso), 0, ruta.n - 1)]) / 3.6


## Velocidad a la que quiere ir un conductor de factor f en s: límite × factor, con la desviación más estrecha en
## vías lentas, y mirando los próximos 200 m para frenar con calma antes de un límite más bajo.
func vel_deseada(s: float, dir: int, f: float) -> float:
	var vmin := 1e9
	var d := 0.0
	while d <= 200.0:
		var lim := limite(s + dir * d)
		var k := clampf((lim * 3.6 - 20.0) / 70.0, 0.45, 1.0)
		var vd := lim * (1.0 + (f - 1.0) * k)
		vmin = minf(vmin, sqrt(vd * vd + 2.0 * B_COMODA * d))
		d += 20.0
	return vmin


func _colocar(c: Dictionary) -> void:
	var s: float = c["s"]
	var dir: int = c["dir"]
	var p := ruta.punto(s) + ruta.derecha(s) * carril_lateral(s, dir) + Vector3.UP * 0.05
	var t := ruta.tangente(s) * dir
	var nodo: Node3D = c["nodo"]
	nodo.position = p
	nodo.basis = Basis.looking_at(t, Vector3.UP)


func reiniciar_interpolacion() -> void:
	for c in coches:
		(c["nodo"] as Node3D).reset_physics_interpolation()


## Coches cerca de una posición (para choques)
func cerca_de(p: Vector3, radio: float) -> Array:
	var r := []
	for c in coches:
		if (c["nodo"].position as Vector3).distance_to(p) < radio:
			r.append(c)
	return r
