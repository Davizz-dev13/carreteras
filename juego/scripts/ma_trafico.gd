## Tráfico del mapa abierto: coches que circulan por la red cargada alrededor del jugador (IDM, Treiber 2000), con
## la misma mezcla de conductores que el tráfico de las zonas (trafico.gd: el 44 % por encima del límite, ETSC PIN
## Flash 36; resto APROXIMACIÓN). En cada cruce cada coche elige salida (más probable seguir por la misma carretera).
## Memoria plana: un grupo FIJO de modelos (MAX) creado al empezar; los coches que salen de la ventana se reutilizan.
class_name MaTrafico
extends Node3D

const MAX := 40
const R_MIN := 220.0          # no aparecen más cerca (no "brotan" delante del jugador)
const R_MAX := 1500.0
const R_FUERA := 1900.0
const A_MAX := 1.4
const B_COMODA := 2.2
const T_SEG := 1.5
const S0 := 3.0
const LARGO := 4.9

var red: MaRed
var mundo: MaMundo
var factor := 0.3
var coches: Array = []        # {k, sd, d, v, f, alat, lat, nodo, sig: [k, sd] | [], vc, t_vc}
var libres: Array = []        # nodos del grupo sin usar
var rng := RandomNumberGenerator.new()
var _t_aparecer := 0.0
var choques := 0


## cuadros (coche × frame) en que algún coche estaba cediendo el paso a la entrada de una glorieta (pruebas)
var cuadros_cediendo := 0
var cuadros_ante_glorieta := 0   # cuadros (coche × frame) a menos de 30 m de entrar en un anillo (pruebas)


func iniciar(r: MaRed, m: MaMundo, f: float) -> void:
	red = r
	mundo = m
	factor = f
	rng.seed = 20261031
	var ficha := Catalogo.ficha_elegida()
	for i in MAX:
		var nodo := Node3D.new()
		nodo.add_child(Catalogo.crear_modelo(ficha, Catalogo.color_aleatorio(ficha, rng), 1))
		nodo.visible = false
		add_child(nodo)
		libres.append(nodo)


func objetivo() -> int:
	return int(round(MAX * clampf(factor, 0.0, 1.0)))


func idm(v: float, v0: float, hueco: float, dv: float) -> float:
	var s_est := S0 + maxf(0.0, v * T_SEG + v * dv / (2.0 * sqrt(A_MAX * B_COMODA)))
	return A_MAX * (1.0 - pow(v / maxf(v0, 0.1), 4.0) - pow(s_est / maxf(hueco, 0.1), 2.0))


func actualizar(dt: float, jug: Vector3, jug_paso: Array, jug_d: float, jug_v: float) -> void:
	# quitar los lejanos o en teselas descargadas
	for i in range(coches.size() - 1, -1, -1):
		var c: Dictionary = coches[i]
		var p: Vector3 = (c["nodo"] as Node3D).position
		if p.distance_to(jug) > R_FUERA or not mundo.activas.has(mundo.datos.clave_tesela(p)):
			_quitar(i)
	_t_aparecer -= dt
	if _t_aparecer <= 0.0 and coches.size() < objetivo():
		_t_aparecer = 0.15
		_aparecer(jug)
	for c in coches:
		_mover(c, dt, jug_paso, jug_d, jug_v)


func _quitar(i: int) -> void:
	var nodo: Node3D = coches[i]["nodo"]
	nodo.visible = false
	libres.append(nodo)
	coches.remove_at(i)


func _aparecer(jug: Vector3) -> void:
	if libres.is_empty():
		return
	# un tramo al azar de las teselas de detalle cargadas
	var claves := mundo.activas.keys()
	if claves.is_empty():
		return
	for intento in 6:
		var t: Vector2i = claves[rng.randi() % claves.size()]
		var a: Dictionary = mundo.activas[t]
		if int(a["lod"]) != 0 or not mundo.sup.teselas.has(t):
			continue
		var sk: PackedInt32Array = mundo.sup.teselas[t]["k"]
		if sk.is_empty():
			continue
		var k := sk[rng.randi() % sk.size()]
		var tr: Dictionary = red.datos.tramos[k]
		var sv := int(tr["s"])
		var sd := sv if sv != 0 else (1 if rng.randf() < 0.5 else -1)
		var L := red.longitud(k)
		var d := rng.randf() * L
		var pt: Array = red.punto(k, sd, d)
		var dist := (pt[0] as Vector3).distance_to(jug)
		if dist < R_MIN or dist > R_MAX or int(tr["tunel"]) == 1:
			continue
		var ocupado := false
		for c in coches:
			if c["k"] == k and c["sd"] == sd and absf(float(c["d"]) - d) < 40.0:
				ocupado = true
				break
		if ocupado:
			continue
		var cond := _conductor()
		var nodo: Node3D = libres.pop_back()
		var c := {"k": k, "sd": sd, "d": d, "f": cond[0], "alat": cond[1], "nodo": nodo, "sig": [], "vc": 1e9, "t_vc": 0.0,
				"lat": red.carril_derecho(k, 0)}
		c["v"] = minf(_v0(c), 25.0)
		coches.append(c)
		nodo.visible = true
		_colocar(c)
		nodo.reset_physics_interpolation()
		return


## Conductor: [factor de velocidad respecto al límite, aceleración lateral en curva] (como trafico.gd)
func _conductor() -> Array:
	var u := rng.randf()
	var z := rng.randfn(0.0, 1.0)
	var f: float
	if u < 0.02:
		f = rng.randf_range(0.55, 0.65); z = -absf(z)
	elif u < 0.10:
		f = rng.randf_range(0.72, 0.86); z = -absf(z)
	else:
		f = clampf(0.995 + 0.12 * z, 0.72, 1.32)
	var za := 0.5 * z + 0.866 * rng.randfn(0.0, 1.0)
	return [f, clampf(2.8 * exp(0.19 * za), 1.8, 4.0)]


func _v0(c: Dictionary) -> float:
	var lim := red.limite(c["k"], c["sd"]) / 3.6
	var k := clampf((lim * 3.6 - 20.0) / 70.0, 0.45, 1.0)
	return minf(lim * (1.0 + (float(c["f"]) - 1.0) * k), float(c["vc"]))


func _mover(c: Dictionary, dt: float, jug_paso: Array, jug_d: float, jug_v: float) -> void:
	var k: int = c["k"]
	var sd: int = c["sd"]
	var L := red.longitud(k)
	if (c["sig"] as Array).is_empty() and L - float(c["d"]) < 250.0:
		var e := red.elegir(k, sd, 0, rng)
		c["sig"] = [e[0], e[1]] if not e.is_empty() else [-1, 0]
	c["t_vc"] = float(c["t_vc"]) - dt
	if float(c["t_vc"]) <= 0.0:
		c["t_vc"] = 0.5
		c["vc"] = _vel_curva(c)
	# líder: coche de delante en el mismo paso o en el siguiente; o el jugador
	var hueco := 1e4
	var v_lider := 0.0
	var sig: Array = c["sig"]
	for o in coches:
		if o == c:
			continue
		var g := 1e4
		if o["k"] == k and o["sd"] == sd and float(o["d"]) > float(c["d"]):
			g = float(o["d"]) - float(c["d"]) - LARGO
		elif not sig.is_empty() and o["k"] == sig[0] and o["sd"] == sig[1]:
			g = L - float(c["d"]) + float(o["d"]) - LARGO
		if g < hueco:
			hueco = g
			v_lider = o["v"]
	# glorieta: antes de entrar al anillo se cede el paso a quien ya circula por él
	var ce := _ceda_glorieta(c, k, sd, L, sig, jug_paso, jug_d)
	if ce < 1e4:
		cuadros_cediendo += 1
	if ce < hueco:
		hueco = ce
		v_lider = 0.0
	if not jug_paso.is_empty():
		var g := 1e4
		if jug_paso[0] == k and jug_paso[1] == sd and jug_d > float(c["d"]):
			g = jug_d - float(c["d"]) - LARGO
		elif not sig.is_empty() and jug_paso[0] == sig[0] and jug_paso[1] == sig[1]:
			g = L - float(c["d"]) + jug_d - LARGO
		if g < hueco:
			hueco = g
			v_lider = jug_v
	var v: float = c["v"]
	var a := clampf(idm(v, _v0(c), maxf(hueco, 0.1), v - v_lider), -9.0, A_MAX)
	v = maxf(v + a * dt, 0.0)
	c["v"] = v
	var d := float(c["d"]) + v * dt
	if d >= L:
		if sig.is_empty() or int(sig[0]) < 0:
			d = L
			c["v"] = 0.0
		else:
			d -= L
			c["k"] = sig[0]
			c["sd"] = sig[1]
			c["sig"] = []
			c["lat"] = red.carril_derecho(c["k"], 0)
	c["d"] = d
	_colocar(c)


func _vel_curva(c: Dictionary) -> float:
	# curvatura máxima en los próximos ~160 m por cuerdas de 20 m, con margen de frenada
	var k: int = c["k"]
	var sd: int = c["sd"]
	var L := red.longitud(k)
	var d0 := float(c["d"])
	var vmin := 1e9
	var pa: Vector3 = red.punto(k, sd, d0)[0]
	var pb: Vector3 = red.punto(k, sd, minf(d0 + 20.0, L))[0]
	var dd := 20.0
	while dd <= 160.0 and d0 + dd + 20.0 < L:
		var pc: Vector3 = red.punto(k, sd, d0 + dd + 20.0)[0]
		var u := Vector2(pb.x - pa.x, pb.z - pa.z)
		var w := Vector2(pc.x - pb.x, pc.z - pb.z)
		if u.length() > 5.0 and w.length() > 5.0:
			var kap := absf(u.angle_to(w)) / 20.0
			if kap > 1e-4:
				var vcu := sqrt(float(c["alat"]) / kap)
				vmin = minf(vmin, sqrt(vcu * vcu + 2.0 * B_COMODA * maxf(dd - 20.0, 0.0)))
		pa = pb
		pb = pc
		dd += 20.0
	return vmin


func _colocar(c: Dictionary) -> void:
	var pt: Array = red.punto(c["k"], c["sd"], c["d"])
	var t: Vector3 = pt[1]
	var der := Vector3(-t.z, 0.0, t.x).normalized()
	var nodo: Node3D = c["nodo"]
	nodo.position = (pt[0] as Vector3) + der * float(c["lat"]) + Vector3.UP * 0.05
	if t.length() > 0.01:
		nodo.basis = Basis.looking_at(t, Vector3.UP)


## Coches a menos de `radio` m de p (para choques)
func cerca_de(p: Vector3, radio: float) -> Array:
	var r := []
	for c in coches:
		if (c["nodo"] as Node3D).position.distance_to(p) < radio:
			r.append(c)
	return r


## Ceda el paso en las glorietas (en España, quien entra cede al que ya va por el anillo): si el coche c va a pasar de
## un tramo normal a un tramo de anillo (rot) en los próximos 30 m y por el anillo viene alguien (otro coche o el
## jugador) a menos de 24 m del punto de entrada y acercándose, se para 5 m antes. Quien va por el anillo no para.
## Devuelve el hueco hasta el punto de parada (m) o 1e4.
func _ceda_glorieta(c: Dictionary, k: int, sd: int, L: float, sig: Array, jug_paso: Array, jug_d: float) -> float:
	if sig.is_empty() or int(sig[0]) < 0:
		return 1e4
	var dist := L - float(c["d"])
	if dist > 30.0 or dist < 0.5:
		return 1e4
	var tramos: Array = red.datos.tramos
	if int(tramos[k]["rot"]) == 1 or int(tramos[int(sig[0])]["rot"]) != 1:
		return 1e4
	cuadros_ante_glorieta += 1
	var pn: Vector3 = red.punto(k, sd, L)[0]
	for o in coches:
		if o == c or int(tramos[int(o["k"])]["rot"]) != 1:
			continue
		if _viene_por_anillo((o["nodo"] as Node3D).position, red.punto(o["k"], o["sd"], o["d"])[1], pn):
			return maxf(dist - 5.0, 0.3)
	if not jug_paso.is_empty() and int(jug_paso[0]) >= 0 and int(tramos[int(jug_paso[0])]["rot"]) == 1:
		var pj: Array = red.punto(jug_paso[0], jug_paso[1], jug_d)
		if _viene_por_anillo(pj[0], pj[1], pn):
			return maxf(dist - 5.0, 0.3)
	return 1e4


static func _viene_por_anillo(q: Vector3, t: Vector3, pn: Vector3) -> bool:
	var dq := pn - q
	if absf(dq.y) > 4.0:
		return false
	var dh := Vector2(dq.x, dq.z).length()
	return dh > 1.0 and dh < 24.0 and Vector2(t.x, t.z).dot(Vector2(dq.x, dq.z)) > 0.0
