## Choques reales entre coches (vista en planta, 2D): cajas orientadas a las medidas REALES de cada versión
## (largo × ancho de su ficha) y respuesta por impulsos que conserva el momento lineal y angular, con las
## masas reales de la ficha (coeficiente de restitución ≈ 0,15 y rozamiento chapa-chapa 0,35).
##  · jugador contra tráfico y tráfico "suelto" (ya golpeado) contra cualquier coche
##  · un coche del tráfico que recibe un golpe deja su carril y pasa a ser un cuerpo libre: sale despedido,
##    gira y se frena arrastrando las ruedas (μ·g) hasta pararse; el conductor se queda parado
##  · sin atravesar a alta velocidad: si el movimiento relativo en un paso es grande, se buscan los
##    instantes intermedios (sub-pasos) y se resuelve en el primer contacto
class_name Colisiones
extends RefCounted

const RESTITUCION := 0.15
const ROCE_CHAPA := 0.35
const MU_ARRASTRE := 0.75      # deceleración de un coche suelto con las ruedas bloqueadas/cruzadas (× g)
const FRENO_GIRO := 3.0        # rad/s² con que se frena el giro de un coche suelto
const SUBPASO_M := 0.25        # desplazamiento relativo máximo entre comprobaciones (m)

var juego: Node                # escena de conducción (coche, trafico, ruta)
var golpes := 0                # choques con el jugador (para el resumen)
var registro: Array = []       # últimos impactos (para la prueba automática)


## Caja orientada en planta: p centro (x, z), f vector unitario de avance, d (semi-largo, semi-ancho)
static func caja(p: Vector2, f: Vector2, largo: float, ancho: float) -> Dictionary:
	return {"p": p, "f": f, "r": Vector2(-f.y, f.x), "e": Vector2(largo * 0.5, ancho * 0.5)}


static func _esquinas(c: Dictionary) -> Array:
	var a: Vector2 = c["f"] * c["e"].x
	var b: Vector2 = c["r"] * c["e"].y
	var p: Vector2 = c["p"]
	return [p + a + b, p + a - b, p - a + b, p - a - b]


## Separación por ejes (SAT) entre dos cajas: normal (de B hacia A), profundidad y punto de contacto
static func sat(a: Dictionary, b: Dictionary) -> Dictionary:
	var ejes := [a["f"], a["r"], b["f"], b["r"]]
	var ea := _esquinas(a)
	var eb := _esquinas(b)
	var mejor := 1e9
	var n := Vector2.ZERO
	var de_a := true
	for i in 4:
		var eje: Vector2 = ejes[i]
		var amin := 1e9; var amax := -1e9; var bmin := 1e9; var bmax := -1e9
		for v in ea:
			var d: float = v.dot(eje); amin = minf(amin, d); amax = maxf(amax, d)
		for v in eb:
			var d: float = v.dot(eje); bmin = minf(bmin, d); bmax = maxf(bmax, d)
		var solape := minf(amax, bmax) - maxf(amin, bmin)
		if solape <= 0.0:
			return {"hay": false}
		if solape < mejor:
			mejor = solape
			n = eje
			de_a = i < 2
	if (a["p"] - b["p"]).dot(n) < 0.0:
		n = -n
	# punto de contacto: la esquina que más se mete en la otra caja
	var punto := Vector2.ZERO
	if de_a:
		var mx := -1e9
		for v in eb:
			var d: float = v.dot(n)
			if d > mx: mx = d; punto = v
	else:
		var mn := 1e9
		for v in ea:
			var d: float = v.dot(n)
			if d < mn: mn = d; punto = v
	return {"hay": true, "n": n, "prof": mejor, "punto": punto}


static func _cruz(r: Vector2, v: Vector2) -> float:
	# componente Y de r × v (giro alrededor del eje vertical de Godot; plano X-Z guardado como Vector2(x, z))
	return r.y * v.x - r.x * v.y


static func _vel_punto(v: Vector2, w: float, r: Vector2) -> Vector2:
	return v + Vector2(w * r.y, -w * r.x)


## Impulso entre dos cuerpos A y B: {p, v (Vector2), w, m, I}. Modifica v y w en los diccionarios.
static func impulso(a: Dictionary, b: Dictionary, n: Vector2, punto: Vector2) -> float:
	var ra: Vector2 = punto - a["p"]
	var rb: Vector2 = punto - b["p"]
	var vrel := _vel_punto(a["v"], a["w"], ra) - _vel_punto(b["v"], b["w"], rb)
	var vn := vrel.dot(n)
	if vn >= 0.0:
		return 0.0
	var ran := _cruz(ra, n)
	var rbn := _cruz(rb, n)
	var k: float = 1.0 / a["m"] + 1.0 / b["m"] + ran * ran / a["I"] + rbn * rbn / b["I"]
	var j: float = -(1.0 + RESTITUCION) * vn / k
	var J: Vector2 = n * j
	# rozamiento chapa contra chapa (tangencial, limitado por Coulomb)
	var t := vrel - n * vn
	if t.length() > 1e-4:
		t = t.normalized()
		var rat := _cruz(ra, t)
		var rbt := _cruz(rb, t)
		var kt: float = 1.0 / a["m"] + 1.0 / b["m"] + rat * rat / a["I"] + rbt * rbt / b["I"]
		var jt := clampf(-vrel.dot(t) / kt, -ROCE_CHAPA * j, ROCE_CHAPA * j)
		J += t * jt
	a["v"] = a["v"] + J / a["m"]
	a["w"] = a["w"] + _cruz(ra, J) / a["I"]
	b["v"] = b["v"] - J / b["m"]
	b["w"] = b["w"] - _cruz(rb, J) / b["I"]
	return j


static func inercia(m: float, largo: float, ancho: float) -> float:
	return m * (largo * largo + ancho * ancho) / 12.0


# ---------------------------------------------------------------- cuerpos del juego
func _cuerpo_jugador() -> Dictionary:
	var c: Coche = juego.coche
	var fw3 := c.adelante()
	var f := Vector2(fw3.x, fw3.z)
	var r := Vector2(-f.y, f.x)
	var fi := c.ficha
	return {"p": Vector2(c.position.x, c.position.z), "f": f, "v": f * c.v + r * c.v_lat,
			"w": c.giro_ext + c.w_rumbo, "m": fi.masa, "I": inercia(fi.masa, fi.largo, fi.ancho), "largo": fi.largo, "ancho": fi.ancho}


func _aplicar_jugador(b: Dictionary) -> void:
	var c: Coche = juego.coche
	var f: Vector2 = b["f"]
	var r := Vector2(-f.y, f.x)
	c.v = b["v"].dot(f)
	c.v_lat = b["v"].dot(r)
	c.giro_ext = b["w"] - c.w_rumbo
	c.position.x = b["p"].x
	c.position.y = c.position.y
	c.position.z = b["p"].y


func _cuerpo_trafico(t: Dictionary) -> Dictionary:
	var tr: Trafico = juego.trafico
	var fi: Ficha = tr.ficha_trafico
	var nodo: Node3D = t["nodo"]
	if not t.get("suelto", false):
		var tg: Vector3 = tr.ruta.tangente(t["s"]) * t["dir"]
		var f := Vector2(tg.x, tg.z).normalized()
		t["f2"] = f
		t["v2"] = f * t["v"]
		t["w2"] = 0.0
		t["p2"] = Vector2(nodo.position.x, nodo.position.z)
	return {"p": t["p2"], "f": t["f2"], "v": t["v2"], "w": t["w2"], "m": fi.masa,
			"I": inercia(fi.masa, fi.largo, fi.ancho), "largo": fi.largo, "ancho": fi.ancho}


func _soltar(t: Dictionary, b: Dictionary) -> void:
	t["suelto"] = true
	t["v2"] = b["v"]
	t["w2"] = b["w"]
	t["p2"] = b["p"]
	t["f2"] = b["f"]


## Llamar una vez por paso de física, después de mover el coche y el tráfico.
## prev_jug: pose del jugador antes del paso {p, f}
func resolver(dt: float, prev_jug: Dictionary) -> void:
	var tr: Trafico = juego.trafico
	var jug := _cuerpo_jugador()
	var cerca: Array = tr.cerca_de(juego.coche.position, 12.0)
	for t in cerca:
		var b := _cuerpo_trafico(t)
		_par(jug, b, prev_jug, t, dt, true)
	_aplicar_jugador(jug)
	# tráfico suelto contra el resto del tráfico
	for t in tr.coches:
		if not t.get("suelto", false):
			continue
		for o in tr.cerca_de(t["nodo"].position, 12.0):
			if o == t:
				continue
			var a := _cuerpo_trafico(t)
			var b := _cuerpo_trafico(o)
			var hit := sat(caja(a["p"], a["f"], a["largo"], a["ancho"]), caja(b["p"], b["f"], b["largo"], b["ancho"]))
			if not hit["hay"]:
				continue
			_separar(a, b, hit)
			impulso(a, b, hit["n"], hit["punto"])
			_soltar(t, a)
			_soltar(o, b)


func _separar(a: Dictionary, b: Dictionary, hit: Dictionary) -> void:
	var inv_a: float = 1.0 / a["m"]
	var inv_b: float = 1.0 / b["m"]
	var corr: Vector2 = hit["n"] * (hit["prof"] + 0.01) / (inv_a + inv_b)
	a["p"] = a["p"] + corr * inv_a
	b["p"] = b["p"] - corr * inv_b


func _par(a: Dictionary, b: Dictionary, prev_a: Dictionary, t: Dictionary, dt: float, es_jugador: bool) -> void:
	# sub-pasos si el movimiento relativo del paso es grande (sin atravesar a alta velocidad)
	var vrel: Vector2 = a["v"] - b["v"]
	var n := maxi(1, ceili(vrel.length() * dt / SUBPASO_M))
	var hit := {"hay": false}
	var pa: Vector2 = a["p"]
	var fa: Vector2 = a["f"]
	var pb: Vector2 = b["p"]
	for k in range(1, n + 1):
		var u := float(k) / n
		var pa_k: Vector2 = prev_a["p"].lerp(a["p"], u)
		var fa_k: Vector2 = prev_a["f"].slerp(a["f"], u).normalized()
		var pb_k: Vector2 = pb - b["v"] * dt * (1.0 - u)
		hit = sat(caja(pa_k, fa_k, a["largo"], a["ancho"]), caja(pb_k, b["f"], b["largo"], b["ancho"]))
		if hit["hay"]:
			pa = pa_k
			fa = fa_k
			b["p"] = pb_k
			break
	if not hit["hay"]:
		return
	a["p"] = pa
	a["f"] = fa
	if es_jugador:
		var c: Coche = juego.coche
		c.rumbo = atan2(-fa.x, -fa.y)
	_separar(a, b, hit)
	var v_a0: Vector2 = a["v"]
	var v_b0: Vector2 = b["v"]
	var j := impulso(a, b, hit["n"], hit["punto"])
	if j <= 0.0:
		return
	_soltar(t, b)
	if es_jugador:
		golpes += 1
		juego.coche.choque_t = 1.0
		registro.append({"j": j, "va0": v_a0, "vb0": v_b0, "va1": a["v"], "vb1": b["v"], "ma": a["m"], "mb": b["m"],
				"wa1": a["w"], "wb1": b["w"]})


## Movimiento de los coches sueltos: deslizan frenando con las ruedas (μ·g) hasta pararse
func mover_sueltos(dt: float) -> void:
	var tr: Trafico = juego.trafico
	for t in tr.coches:
		if not t.get("suelto", false):
			continue
		var v: Vector2 = t["v2"]
		var sp := v.length()
		var dec := MU_ARRASTRE * Coche.G * dt
		t["v2"] = Vector2.ZERO if sp <= dec else v - v / sp * dec
		var w: float = t["w2"]
		t["w2"] = 0.0 if absf(w) <= FRENO_GIRO * dt else w - signf(w) * FRENO_GIRO * dt
		t["p2"] = t["p2"] + t["v2"] * dt
		var f: Vector2 = t["f2"]
		var ang: float = t["w2"] * dt
		# giro alrededor del eje vertical (mismo convenio que _vel_punto)
		f = Vector2(f.x * cos(ang) + f.y * sin(ang), -f.x * sin(ang) + f.y * cos(ang))
		t["f2"] = f.normalized()
		# su posición en la ruta (para que el resto del tráfico lo vea como obstáculo)
		var p3 := Vector3(t["p2"].x, t["nodo"].position.y, t["p2"].y)
		var pr: Vector2 = tr.ruta.proyectar(p3, t["s"])
		t["s"] = pr.x
		t["v"] = 0.0 if t["v2"].length() < 0.5 else t["v2"].dot(Vector2(tr.ruta.tangente(pr.x).x, tr.ruta.tangente(pr.x).z)) * t["dir"]
		var h := Ajustes.superficie.consultar(p3.x, p3.z, p3.y).x
		var nodo: Node3D = t["nodo"]
		nodo.position = Vector3(p3.x, h + 0.05, p3.z)
		nodo.basis = Basis.looking_at(Vector3(t["f2"].x, 0.0, t["f2"].y), Vector3.UP)
