## Choques reales entre coches (vista en planta, 2D): cajas orientadas a las medidas REALES de cada versión
## (largo × ancho de su ficha) y respuesta por impulsos que conserva el momento lineal y angular, con las
## masas reales de la ficha (coeficiente de restitución ≈ 0,15 y rozamiento chapa-chapa 0,35).
##  · jugador contra tráfico y tráfico "suelto" (ya golpeado) contra cualquier coche
##  · un coche del tráfico que recibe un golpe deja su carril y pasa a ser un cuerpo libre: sale despedido,
##    gira y se frena arrastrando las ruedas (μ·g) hasta pararse. Después (v6) el conductor espera unos segundos
##    y se recoloca solo (maniobra.gd: hacia delante y marcha atrás las veces que haga falta) hasta volver a su
##    carril y seguir. Si el golpe ha sido muy fuerte (cambio de velocidad > DV_AVERIA) queda averiado: se queda
##    como obstáculo y el tráfico lo rodea con cuidado; solo se retira lejos del jugador (trafico.gd)
##  · sin atravesar a alta velocidad: si el movimiento relativo en un paso es grande, se buscan los
##    instantes intermedios (sub-pasos) y se resuelve en el primer contacto
class_name Colisiones
extends RefCounted

const RESTITUCION := 0.15
const ROCE_CHAPA := 0.35
const MU_ARRASTRE := 0.75      # deceleración de un coche suelto con las ruedas bloqueadas/cruzadas (× g)
const FRENO_GIRO := 3.0        # rad/s² con que se frena el giro de un coche suelto
const SUBPASO_M := 0.25        # desplazamiento relativo máximo entre comprobaciones (m)
const DV_AVERIA := 17.0        # m/s (≈ 60 km/h) de cambio de velocidad en el golpe: coche inutilizado (averiado)
const T_ESPERA := 2.0          # s parado tras el golpe antes de empezar a recolocarse
const T_MANIOBRA_MAX := 45.0   # s de maniobra sin conseguirlo: se queda averiado (como obstáculo)
const GOLPE_MIN := 0.6         # m/s de cambio de velocidad: por debajo es un roce (no interrumpe una maniobra)
const ACEL_MANIOBRA := 2.0     # m/s² con que arranca y frena maniobrando

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
		var tg: Vector3 = tr.ruta.marcha_carril(t["s"], t["dir"])     # en una glorieta, la dirección del desvío
		var f := Vector2(tg.x, tg.z).normalized()
		t["f2"] = f
		t["v2"] = f * t["v"]
		t["w2"] = 0.0
		t["p2"] = Vector2(nodo.position.x, nodo.position.z)
	return {"p": t["p2"], "f": t["f2"], "v": t["v2"], "w": t["w2"], "m": fi.masa,
			"I": inercia(fi.masa, fi.largo, fi.ancho), "largo": fi.largo, "ancho": fi.ancho}


func _soltar(t: Dictionary, b: Dictionary) -> void:
	# cambio de velocidad del golpe (para saber si el coche queda inutilizado)
	var dv: float = (b["v"] - (t.get("v2", b["v"]) as Vector2)).length()
	if dv > DV_AVERIA:
		t["averiado"] = true
	t.erase("rodea")
	t["estado"] = "deslizando"       # tras cualquier golpe (también maniobrando) vuelve a deslizar y esperar
	t["t_estado"] = 0.0
	t["v_man"] = 0.0
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
			var jj := impulso(a, b, hit["n"], hit["punto"])
			# un roce sin golpe (maniobrando pegado a otro) solo los separa; un golpe de verdad los suelta otra vez
			if jj > GOLPE_MIN * minf(a["m"], b["m"]):
				_soltar(t, a)
				_soltar(o, b)
			else:
				_mover_cuerpo(t, a)
				if o.get("suelto", false):
					_mover_cuerpo(o, b)
				else:
					_soltar(o, b)


func _mover_cuerpo(t: Dictionary, b: Dictionary) -> void:
	t["p2"] = b["p"]
	if t.get("estado", "") == "maniobra":
		pass                 # maniobrando pegado a otro: solo se separan (si no, se frenaban el uno al otro para siempre)
	else:
		t["v2"] = b["v"]
		t["w2"] = b["w"]


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


## Movimiento de los coches sueltos: deslizan frenando con las ruedas (μ·g) hasta pararse; luego esperan T_ESPERA s y
## se recolocan en su carril maniobrando (maniobra.gd); al conseguirlo vuelven al tráfico normal (trafico.gd)
func mover_sueltos(dt: float) -> void:
	var tr: Trafico = juego.trafico
	var reincorporar: Array = []
	for t in tr.coches:
		if not t.get("suelto", false):
			continue
		var estado: String = t.get("estado", "deslizando")
		t["t_estado"] = float(t.get("t_estado", 0.0)) + dt
		var vq: Vector2 = t["v2"]
		t["t_quieto"] = float(t.get("t_quieto", 0.0)) + dt if vq.length() < 0.3 else 0.0
		if estado == "maniobra":
			if _maniobrar(t, dt):
				reincorporar.append(t)
				continue
		elif estado == "espera" or estado == "averiado":
			t["v2"] = Vector2.ZERO
			t["w2"] = 0.0
			if estado == "espera" and float(t["t_estado"]) > T_ESPERA:
				t["estado"] = "maniobra"
				t["t_estado"] = 0.0
				t["v_man"] = 0.0
				var m := Maniobra.new()
				m.empezar()
				t["man"] = m
		else:
			_deslizar(t, dt)
			_contra_bionda(t, tr)
			if (t["v2"] as Vector2).length() < 0.3 and absf(float(t["w2"])) < 0.15:
				t["v2"] = Vector2.ZERO
				t["w2"] = 0.0
				t["estado"] = "averiado" if t.get("averiado", false) else "espera"
				t["t_estado"] = 0.0
		_situar(t, tr)
	for t in reincorporar:
		tr.reincorporar(t)


func _deslizar(t: Dictionary, dt: float) -> void:
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


## v6: un coche suelto tampoco atraviesa los quitamiedos (antes solo chocaba el del jugador): se le saca de la valla y
## pierde la velocidad contra ella (restitución 0,1 y roce 0,35, como biondas.gd)
func _contra_bionda(t: Dictionary, tr: Trafico) -> void:
	var bi = juego.get("biondas")
	if bi == null or (bi as Biondas).vacia():
		return
	var fi: Ficha = tr.ficha_trafico
	for it in 3:
		var p: Vector2 = t["p2"]
		var f: Vector2 = t["f2"]
		var a := f * fi.largo * 0.5
		var b := Maniobra.derecha(f) * fi.ancho * 0.5
		var mejor: Dictionary = (bi as Biondas).contacto(p, [p + a + b, p + a - b, p - a + b, p - a - b], (t["nodo"] as Node3D).position.y, {})
		if mejor.is_empty():
			return
		var n: Vector2 = mejor["n"]
		t["p2"] = p + n * (float(mejor["prof"]) + 0.005)
		var v: Vector2 = t["v2"]
		var vn := v.dot(n)
		if vn < 0.0:
			var vt := v - n * vn
			var red := minf(vt.length(), Biondas.ROCE * (1.0 + Biondas.RESTITUCION) * -vn)
			vt = vt - vt.normalized() * red if vt.length() > 1e-4 else vt
			t["v2"] = vt - n * vn * Biondas.RESTITUCION
			t["w2"] = float(t["w2"]) * 0.7


## Posición en la ruta (para que el resto del tráfico lo vea como obstáculo), altura y orientación del modelo
func _situar(t: Dictionary, tr: Trafico) -> void:
	var p3 := Vector3(t["p2"].x, t["nodo"].position.y, t["p2"].y)
	var pr: Vector2 = tr.ruta.proyectar(p3, t["s"])
	t["s"] = pr.x
	t["lat"] = pr.y
	var tg := tr.ruta.tangente(pr.x)
	t["v"] = 0.0 if t["v2"].length() < 0.5 else t["v2"].dot(Vector2(tg.x, tg.z)) * t["dir"]
	var h := Ajustes.superficie.consultar(p3.x, p3.z, p3.y).x
	var nodo: Node3D = t["nodo"]
	nodo.position = Vector3(p3.x, h + 0.05, p3.z)
	nodo.basis = Basis.looking_at(Vector3(t["f2"].x, 0.0, t["f2"].y), Vector3.UP)


## Un paso de la maniobra de un coche del tráfico. Devuelve true cuando ya está en su carril y alineado.
func _maniobrar(t: Dictionary, dt: float) -> bool:
	var tr: Trafico = juego.trafico
	var ruta: Ruta = tr.ruta
	var m: Maniobra = t["man"]
	var dir: int = t["dir"]
	var fi: Ficha = tr.ficha_trafico
	var p: Vector2 = t["p2"]
	var f: Vector2 = t["f2"]
	var s: float = t["s"]
	var cp3 := ruta.punto_carril(s, dir)
	var ct3 := ruta.marcha_carril(s, dir)
	var mira := 7.0 * ruta.escala_carril(s, dir)
	var mp3 := ruta.punto_carril(s + dir * mira, dir)
	var bloq := func(q: Vector2, q0: Vector2) -> bool: return _ocupado(q, q0, t, s, m.forzar)
	var libre := func(sentido: int, giro: float) -> float: return Maniobra.libre(p, f, sentido, giro, fi.largo, fi.ancho, fi.batalla, bloq)
	var v_man: float = t.get("v_man", 0.0)
	var r := m.paso(p, f, v_man, Vector2(cp3.x, cp3.z), Vector2(ct3.x, ct3.z).normalized(), Vector2(mp3.x, mp3.z),
			libre, fi.batalla, dt)
	if r["hecho"]:
		return true
	if float(t["t_estado"]) > T_MANIOBRA_MAX:
		# no hay forma (encajado): se queda como obstáculo averiado
		t["estado"] = "averiado"
		t["averiado"] = true
		t["v2"] = Vector2.ZERO
		return false
	var objetivo: float = float(r["v"]) * int(r["marcha"])
	# para cambiar de sentido primero se para; se arranca y se frena con suavidad
	if signf(objetivo) != signf(v_man) and absf(v_man) > 0.05:
		objetivo = 0.0
	v_man = move_toward(v_man, objetivo, ACEL_MANIOBRA * dt)
	var mv := Maniobra.mover(p, f, v_man, float(r["giro"]), fi.batalla, dt)
	t["p2"] = mv[0]
	t["f2"] = mv[1]
	t["v2"] = (mv[1] as Vector2) * v_man
	t["w2"] = 0.0
	_contra_bionda(t, tr)
	if (t["v2"] as Vector2).length() < absf(v_man) * 0.5:
		v_man = 0.0          # ha tocado la valla: se para (la maniobra lo verá como atasco y cambiará de sentido)
	t["v_man"] = v_man
	Catalogo.animar_ruedas(t["modelo"], v_man * dt, float(r["giro"]))
	return false


## ¿Está ocupado el punto q para un coche que maniobra? Fuera de la calzada (+ arcén) hacia fuera, otro coche o el jugador
func _ocupado(q: Vector2, q0: Vector2, yo: Dictionary, s_pista: float, forzar := false) -> bool:
	var tr: Trafico = juego.trafico
	var ruta: Ruta = tr.ruta
	var pr := ruta.proyectar(Vector3(q.x, 0.0, q.y), s_pista, 14.0)
	var lim := ruta.valor(ruta.ancho, pr.x) * 0.5 + (2.5 if forzar else 0.6)
	if absf(pr.y) > lim:
		var pr0 := ruta.proyectar(Vector3(q0.x, 0.0, q0.y), s_pista, 14.0)
		if absf(pr.y) > absf(pr0.y) + 0.02:
			return true
	var bi = juego.get("biondas")
	if bi != null and not (bi as Biondas).vacia() and (bi as Biondas).bloquea(q, q0, (yo["nodo"] as Node3D).position.y):
		return true
	var fi: Ficha = tr.ficha_trafico
	for o in tr.cerca_de(Vector3(q.x, (yo["nodo"] as Node3D).position.y, q.y), 6.0):
		if o == yo:
			continue
		var on: Node3D = o["nodo"]
		var fo := -on.basis.z
		if Maniobra.dentro(q, Vector2(on.position.x, on.position.z), Vector2(fo.x, fo.z).normalized(), fi.largo, fi.ancho):
			return true
	var c: Coche = juego.coche
	if c != null:
		var fc := c.adelante()
		if Maniobra.dentro(q, Vector2(c.position.x, c.position.z), Vector2(fc.x, fc.z).normalized(), c.ficha.largo, c.ficha.ancho):
			return true
	return false
