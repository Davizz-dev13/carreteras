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
var pos_jug := Vector3(INF, INF, INF)   # posición del jugador (la pone juego.gd): también se le cede el paso
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
		var kd := ruta.curv_desvio(s + dir * d, dir)
		var al := a_lat
		if kd > 0.0:
			k = kd             # por el resto del anillo de una glorieta (desvío del sentido contrario)
			al = a_lat * 0.7   # entrada y salida de la glorieta: más suave (sin derrapes del piloto)
		var vk := sqrt(al / maxf(k, 1e-5))
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
		# coche suelto tras un golpe y ya parado: se retira a los 10 s (si no, el piloto se quedaba atascado detrás)
		if c.get("suelto", false):
			var vs: Vector2 = c.get("v2", Vector2.ZERO)
			c["t_parado"] = float(c.get("t_parado", 0.0)) + dt if vs.length() < 0.3 else 0.0
			if float(c["t_parado"]) > 10.0:
				c["nodo"].queue_free()
				coches.remove_at(i)
				continue
		if absf(c["s"] - s_jug) > RADIO + 250.0 or c["s"] < maxf(0.0, ruta.s_trafico_min - 1.0) or c["s"] > minf(ruta.longitud(), ruta.s_trafico_max + 1.0):
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
			if s < maxf(5.0, ruta.s_trafico_min) or s > minf(ruta.longitud() - 5.0, ruta.s_trafico_max): continue
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
		# cerca de una glorieta (zona de desvíos) el jugador puede cruzarse por delante al salir del anillo por el
		# desvío: si está físicamente en la trayectoria (12 m por delante, ±1,7 m), se frena en vez de embestirlo
		c["cede_jug"] = false
		if pos_jug.x != INF and _cerca_de_desvio(s):
			var nodo_c: Node3D = c["nodo"]
			var tg := ruta.marcha_carril(s, dir)
			var fw := Vector2(tg.x, tg.z).normalized()
			var rel := Vector2(pos_jug.x - nodo_c.position.x, pos_jug.z - nodo_c.position.z)
			var delante := rel.dot(fw)
			if delante > 0.0 and delante < 12.0 and absf(rel.cross(fw)) < 1.7 and delante - largo < hueco:
				hueco = delante - largo
				v_lider = 0.0
				c["cede_jug"] = true     # el piloto no le espera a él (sin bloqueos mutuos)
		# glorietas: ceder el paso a quien ya circula por el anillo (parada antes de la entrada)
		var ceda := _ceda(c)
		if ceda < hueco:
			hueco = ceda
			v_lider = 0.0
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
		c["s"] += c["v"] * c["dir"] * dt * ruta.escala_carril(c["s"], c["dir"])
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
	# punto_carril: el carril de su sentido; en una glorieta, el sentido contrario va por el resto del anillo
	var p := ruta.punto_carril(s, dir) + Vector3.UP * 0.05
	var t := ruta.marcha_carril(s, dir)
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


# ---------------------------------------------------------------- glorietas: ceda el paso
const CEDA_MIRA := 26.0       # m de anillo, antes del punto de entrada, que mira el que va a entrar
const CEDA_ANTES := 30.0      # a partir de esta distancia a la entrada se empieza a mirar

## Distancia (en m de la ruta, hacia delante) hasta donde tiene que parar el coche c para ceder el paso al entrar a
## un anillo, o 1e4 si puede pasar. Dos casos: (1) va por la ruta y entra al arco de la glorieta que recorre la ruta;
## (2) va por un desvío (sentido contrario) y se incorpora al anillo. Quien ya va por el anillo nunca para.
func _ceda(c: Dictionary) -> float:
	return _ceda_en(c["s"], c["dir"], c, true)


## Lo mismo para el piloto del jugador (en s, sentido dir): cede a los coches del tráfico que ya van por el anillo
func ceda_paso(s: float, dir: int) -> float:
	return _ceda_en(s, dir, {}, false)


func _ceda_en(s: float, dir: int, c: Dictionary, mirar_jugador: bool) -> float:
	if ruta.arcos_glorieta.is_empty():
		return 1e4
	var kd := ruta.desvio_en(s, dir)
	if kd >= 0:
		var dv: Dictionary = ruta.desvios[kd]
		var u := ruta.u_desvio(kd, s)
		var u_ent: float = dv["u_ent"]
		if u > u_ent - 1.0 or u < u_ent - CEDA_ANTES:
			return 1e4
		var p_ent := ruta.punto_desvio(kd, u_ent)
		if _anillo_ocupado(p_ent, dv["c"], dv["radio"], c, mirar_jugador):
			return (u_ent - 3.0 - u) * ruta.escala_carril(s, dir)
		return 1e4
	for ar in ruta.arcos_glorieta:
		if int(ar["sentido"]) != dir:
			continue
		var s_e: float = (float(ar["a"]) if dir > 0 else float(ar["b"])) * ruta.paso
		var dd := (s_e - s) * dir
		if dd <= 2.0 or dd > CEDA_ANTES:
			continue
		var p_e := ruta.punto(s_e)
		var cc := Vector3.ZERO
		var rr := 0.0
		for dv in ruta.desvios:
			if int(dv["g"]) == int(ar["g"]):
				cc = dv["c"]
				rr = dv["radio"]
		if rr <= 0.0:
			continue
		if _anillo_ocupado(p_e, cc, rr, c, mirar_jugador):
			return maxf(dd - 6.0, 0.5)
	return 1e4


## ¿Viene alguien por el anillo (centro cc, radio rr) en los CEDA_MIRA m antes del punto p (aguas arriba en sentido
## antihorario)? Mira los demás coches del tráfico y al jugador.
func _anillo_ocupado(p: Vector3, cc: Vector3, rr: float, yo: Dictionary, mirar_jugador := true) -> bool:
	var th_p := atan2(-(p.z - cc.z), p.x - cc.x)
	var dth := CEDA_MIRA / maxf(rr, 5.0)
	for o in coches:
		if o == yo:
			continue
		if _en_anillo_antes(o["nodo"].position, cc, rr, th_p, dth):
			return true
	return mirar_jugador and pos_jug.x != INF and _en_anillo_antes(pos_jug, cc, rr, th_p, dth)


static func _en_anillo_antes(q: Vector3, cc: Vector3, rr: float, th_p: float, dth: float) -> bool:
	var d := Vector2(q.x - cc.x, q.z - cc.z).length()
	if absf(d - rr) > 5.5 or absf(q.y - cc.y) > 6.0:
		return false
	var th := atan2(-(q.z - cc.z), q.x - cc.x)
	var atras := wrapf(th_p - th, -PI, PI)      # > 0: q está antes que p en sentido antihorario
	return atras > 0.05 and atras < dth


## ¿Está s dentro de la zona de algún desvío de glorieta (de cualquier sentido)?
func _cerca_de_desvio(s: float) -> bool:
	for dv in ruta.desvios:
		if s >= float(dv["s_lo"]) - 15.0 and s <= float(dv["s_hi"]) + 15.0:
			return true
	return false
