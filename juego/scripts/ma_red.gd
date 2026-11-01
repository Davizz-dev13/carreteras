## Mapa abierto: cómo moverse por la red (lo usan el piloto automático y el tráfico).
## Un "paso" es [tramo, sentido]: sentido +1 = del nodo a al b de la geometría, -1 = al revés.
class_name MaRed
extends RefCounted

var datos: MaDatos
var _largos := {}        # tramo -> PackedFloat32Array con la distancia acumulada de cada punto
var _m := Mutex.new()


func _init(d: MaDatos) -> void:
	datos = d


func largos(k: int) -> PackedFloat32Array:
	_m.lock()
	var l = _largos.get(k)
	_m.unlock()
	if l != null:
		return l
	var p := datos.geometria(k)
	var s := PackedFloat32Array()
	s.resize(p.size())
	for i in range(1, p.size()):
		s[i] = s[i - 1] + p[i].distance_to(p[i - 1])
	_m.lock()
	if _largos.size() > 6000:
		_largos.clear()
	_largos[k] = s
	_m.unlock()
	return s


func longitud(k: int) -> float:
	var s := largos(k)
	return s[s.size() - 1]


## Punto y tangente (en el sentido de marcha) a una distancia d del comienzo del paso
func punto(k: int, sentido: int, d: float) -> Array:
	var p := datos.geometria(k)
	var s := largos(k)
	var L := s[s.size() - 1]
	var u := clampf(d if sentido > 0 else L - d, 0.0, L)
	var i := s.bsearch(u, true) - 1
	i = clampi(i, 0, p.size() - 2)
	var seg := maxf(s[i + 1] - s[i], 0.001)
	var f := clampf((u - s[i]) / seg, 0.0, 1.0)
	var pos := p[i].lerp(p[i + 1], f)
	var t := (p[i + 1] - p[i]).normalized() * sentido
	return [pos, t]


## Nodo al que se llega recorriendo el tramo k en ese sentido
func nodo_final(k: int, sentido: int) -> int:
	var t: Dictionary = datos.tramos[k]
	return int(t["b"]) if sentido > 0 else int(t["a"])


## Salidas posibles al llegar al final del paso [k, sentido]: [[tramo, sentido, giro (+ derecha, rad)], ...]
func salidas(k: int, sentido: int) -> Array:
	var n := nodo_final(k, sentido)
	var nodo = datos.nodos.get(n)
	if nodo == null:
		return []
	var llegada: Vector3 = punto(k, sentido, longitud(k) - 0.01)[1]
	var r := []
	for k2 in nodo[3]:
		var k2i := int(k2)
		if k2i == k:
			continue
		var t2: Dictionary = datos.tramos[k2i]
		var s2 := 1 if int(t2["a"]) == n else -1
		if int(t2["a"]) == n and int(t2["b"]) == n:
			continue
		var sv := int(t2["s"])
		if (s2 > 0 and sv == -1) or (s2 < 0 and sv == 1):
			continue
		if sv == 0 and prohibido(k2i, s2):
			continue
		var sal: Vector3 = punto(k2i, s2, minf(15.0, longitud(k2i)))[0] - punto(k2i, s2, 0.0)[0]
		sal.y = 0.0
		var f := Vector3(llegada.x, 0.0, llegada.z).normalized()
		var der := Vector3(-f.z, 0.0, f.x)
		var giro := atan2(sal.normalized().dot(der), sal.normalized().dot(f))
		r.append([k2i, s2, giro])
	return r


## ¿Es la misma carretera? (alguna matrícula en común; sin matrícula, mismo nombre)
func misma_via(k1: int, k2: int) -> bool:
	var t1: Dictionary = datos.tramos[k1]
	var t2: Dictionary = datos.tramos[k2]
	var r1 := str(t1["ref"])
	var r2 := str(t2["ref"])
	if r1 != "" and r2 != "":
		for r in r1.split(";"):
			if r.strip_edges() != "" and r2.split(";").has(r.strip_edges()):
				return true
		return false
	var n1 := str(t1["nombre"])
	return r1 == "" and r2 == "" and n1 != "" and n1 == str(t2["nombre"])


## Elige la salida: preferencia -1 izquierda, +1 derecha, 0 seguir por la misma carretera.
## Seguir = misma matrícula/nombre, luego misma clase y sin pasar de la vía principal a un enlace, luego lo más recto
## (antes bastaba con que el ramal fuera algo más recto para que el piloto se saliera de la autovía).
func elegir(k: int, sentido: int, preferencia := 0, rng: RandomNumberGenerator = null) -> Array:
	var op := salidas(k, sentido)
	if op.is_empty():
		var t: Dictionary = datos.tramos[k]
		if int(t["s"]) == 0:
			return [k, -sentido, PI]     # sin salida: media vuelta en una de doble sentido
		return []
	if op.size() == 1:
		return op[0]
	if preferencia != 0:
		var mejor = null
		for o in op:
			if signf(o[2]) == signf(preferencia) and absf(o[2]) > 0.12:
				if mejor == null or absf(o[2]) < absf(mejor[2]):
					mejor = o
		if mejor != null:
			return mejor
	if rng != null and rng.randf() < 0.35:
		return op[rng.randi() % op.size()]
	var t1: Dictionary = datos.tramos[k]
	var mejor2 = null
	var nota := -1e9
	for o in op:
		var t2: Dictionary = datos.tramos[o[0]]
		var v := -absf(o[2]) * 2.0
		if misma_via(k, o[0]):
			v += 4.0
		if int(t2["c"]) == int(t1["c"]):
			v += 1.0
		v -= 0.4 * maxf(float(int(t2["c"]) - int(t1["c"])), 0.0)
		if int(t2["enlace"]) == 1 and int(t1["enlace"]) == 0:
			v -= 2.0
		if absf(o[2]) > 2.6:
			v -= 6.0                  # media vuelta (p. ej. a la otra calzada)
		if es_glorieta(k) and not es_glorieta(o[0]):
			v += 1.5                  # ya dentro de una glorieta sin plan (al reengancharse): salir en la primera
		if v > nota:
			nota = v
			mejor2 = o
	return mejor2


func es_glorieta(k: int) -> bool:
	return int(datos.tramos[k]["rot"]) == 1


## Glorieta: al llegar al final de [k, sentido] (fuera del anillo) con el anillo delante, recorre el anillo en su
## sentido (el de OSM: antihorario en España) y devuelve los pasos hasta la salida elegida (la última es la salida):
## preferencia 0 = la que sigue la misma carretera o, si no hay, la más recta; +1 la de la derecha (la primera
## que gira a la derecha); -1 la de la izquierda. Nunca la media vuelta salvo que no haya otra. [] si no hay anillo.
func glorieta(k: int, sentido: int, preferencia := 0) -> Array:
	var entrada = null
	for o in salidas(k, sentido):
		if es_glorieta(o[0]):
			entrada = o
			break
	if entrada == null:
		return []
	var nodo0 := nodo_final(k, sentido)
	var nodo_previo := nodo_final(k, -sentido)   # de donde viene el tramo de entrada
	var pasos: Array = [[entrada[0], entrada[1]]]
	var opciones: Array = []          # [pasos hasta la salida incluida, nodo de la salida, misma vía]
	var centro := Vector3.ZERO
	var n_pts := 0
	var actual: Array = [entrada[0], entrada[1]]
	var nodos_anillo := {}
	for vuelta in 40:
		nodos_anillo[nodo_final(actual[0], actual[1])] = true
		for q in datos.geometria(actual[0]):
			centro += q
			n_pts += 1
		var siguiente = null
		for o in salidas(actual[0], actual[1]):
			if es_glorieta(o[0]):
				if siguiente == null:
					siguiente = o
				continue
			var p2: Array = pasos.duplicate()
			p2.append([o[0], o[1]])
			opciones.append([p2, nodo_final(actual[0], actual[1]), misma_via(k, o[0])])
		if siguiente == null or nodo_final(actual[0], actual[1]) == nodo0:
			break
		actual = [siguiente[0], siguiente[1]]
		pasos.append(actual)
	if opciones.is_empty():
		return [[entrada[0], entrada[1]]]
	# barrido: ángulo recorrido alrededor del centro del anillo desde la entrada hasta cada salida (≈90° la primera a
	# la derecha, ≈180° seguir recto, ≈270° a la izquierda, ≈360° media vuelta). Más fiable que el rumbo de tramos de
	# 10-20 m pegados al anillo, y distingue la media vuelta aunque la vía de vuelta tenga el mismo nombre.
	centro /= maxf(float(n_pts), 1.0)
	var mejor = null
	var nota := -1e9
	for op in opciones:
		var barrido := 0.0
		var prev := _vec_nodo(nodo0) - centro
		var ps: Array = op[0]
		for j in range(0, ps.size() - 1):
			var cur := _vec_nodo(nodo_final(ps[j][0], ps[j][1])) - centro
			barrido += absf(Vector2(prev.x, prev.z).angle_to(Vector2(cur.x, cur.z)))
			prev = cur
		var v := 0.0
		if preferencia > 0:
			v = -absf(barrido - PI * 0.5)
		elif preferencia < 0:
			v = -absf(barrido - PI * 1.5)
		else:
			v = -absf(barrido - PI) + (1.5 if op[2] else 0.0)
		if barrido > deg_to_rad(310.0):
			v -= 10.0                 # media vuelta
		# salida que vuelve al nodo del que venía la entrada (glorieta con dos accesos paralelos desde el mismo punto,
		# p. ej. un ramal y la vía de doble sentido de la N-320): también es media vuelta. Antes el piloto salía por ahí,
		# volvía a entrar por el ramal y daba vueltas sin fin
		# ... y la que vuelve al propio anillo (una vía que cruza la glorieta por dentro, como la N-320 en su enlace
		# con la M-113: salía por ella, volvía al nodo de entrada y repetía la glorieta)
		var ult: Array = (op[0] as Array)[(op[0] as Array).size() - 1]
		var fin_salida := nodo_final(ult[0], ult[1])
		if fin_salida == nodo_previo or fin_salida == nodo0 or nodos_anillo.has(fin_salida):
			v -= 10.0
		# salida a un tramo sin continuación (calle cortada de pocos metros): el piloto tenía que dar media vuelta en
		# ella y se salía del asfalto
		if salidas(ult[0], ult[1]).is_empty():
			v -= 8.0
		if v > nota:
			nota = v
			mejor = op
	return mejor[0]


func _vec_nodo(n: int) -> Vector3:
	var nd = datos.nodos.get(n)
	if nd == null:
		return Vector3.ZERO
	return Vector3(float(nd[0]), float(nd[1]), float(nd[2]))


## Desplazamiento lateral (m, + derecha) del centro del carril derecho de un tramo recorrido en ese sentido
func carril_derecho(k: int, carril := 0) -> float:
	var t: Dictionary = datos.tramos[k]
	var ancho := float(t["ancho"])
	if int(t["s"]) == 0:
		return ancho * 0.25
	var n := maxi(int(t["carriles"]), 1)
	var w := (ancho - 1.0) / n
	return (ancho - 1.0) * 0.5 - w * (0.5 + carril)


## Límite de velocidad (km/h) del tramo en ese sentido
func limite(k: int, sentido: int) -> float:
	var t: Dictionary = datos.tramos[k]
	var v := float(t["vf"] if sentido > 0 else t["vb"])
	return v if v > 0.0 else float(t["v"])


## Ramal de doble sentido (según OSM) que en realidad solo sirve en un sentido: en las glorietas con isleta partida
## OSM a veces deja los dos ramales de un brazo como de doble sentido. El que sale de la glorieta llega a ella en
## horquilla (giro de más de 120° para seguir el anillo) y el que entra sale de ella igual: el piloto entraba por el
## ramal de salida, no podía girar tanto y daba vueltas fuera del asfalto (M-203). Prohibido recorrerlo en el sentido
## de la horquilla si en el otro sentido el empalme con el anillo es suave y el otro extremo es un cruce (hay otro ramal).
var _prohibidos := {}

func prohibido(k: int, sentido: int) -> bool:
	var clave := k * 2 + (1 if sentido > 0 else 0)
	_m.lock()
	var c = _prohibidos.get(clave)
	_m.unlock()
	if c != null:
		return c
	var r := false
	var t: Dictionary = datos.tramos[k]
	if int(t["rot"]) == 0 and int(t["s"]) == 0 and int(t["a"]) != int(t["b"]):
		# entrar al anillo por el final en horquilla
		var nf := nodo_final(k, sentido)
		var ni := nodo_final(k, -sentido)
		var e1 := _giro_anillo(k, sentido, nf)
		if e1.x > deg_to_rad(120.0) and e1.y < deg_to_rad(75.0) and _grado(ni) >= 3:
			r = true
		# salir del anillo por el comienzo en horquilla
		var e2 := _giro_anillo(k, -sentido, ni)
		if e2.y > deg_to_rad(120.0) and e2.x < deg_to_rad(75.0) and _grado(nf) >= 3:
			r = true
	_m.lock()
	_prohibidos[clave] = r
	_m.unlock()
	return r


func _grado(n: int) -> int:
	var nd = datos.nodos.get(n)
	return 0 if nd == null else (nd[3] as Array).size()


## (giro al entrar al anillo llegando por [k, sentido] a n, giro al salir del anillo en n por [k, -sentido]) en rad;
## (0, 0) si en n no hay anillo que entre y salga
func _giro_anillo(k: int, sentido: int, n: int) -> Vector2:
	var nd = datos.nodos.get(n)
	if nd == null:
		return Vector2.ZERO
	var t_sale := Vector2.ZERO
	var t_llega := Vector2.ZERO
	for x in nd[3]:
		var k2 := int(x)
		if k2 == k or not es_glorieta(k2):
			continue
		var t2: Dictionary = datos.tramos[k2]
		var sv := int(t2["s"])
		var L2 := longitud(k2)
		var dd := minf(8.0, L2)
		if int(t2["a"]) == n and sv >= 0:
			var v: Vector3 = punto(k2, 1, dd)[0] - punto(k2, 1, 0.0)[0]
			t_sale = Vector2(v.x, v.z)
		elif int(t2["b"]) == n and sv <= 0:
			var v: Vector3 = punto(k2, -1, dd)[0] - punto(k2, -1, 0.0)[0]
			t_sale = Vector2(v.x, v.z)
		if int(t2["b"]) == n and sv >= 0:
			var v: Vector3 = punto(k2, 1, L2)[0] - punto(k2, 1, L2 - dd)[0]
			t_llega = Vector2(v.x, v.z)
		elif int(t2["a"]) == n and sv <= 0:
			var v: Vector3 = punto(k2, -1, L2)[0] - punto(k2, -1, L2 - dd)[0]
			t_llega = Vector2(v.x, v.z)
	if t_sale == Vector2.ZERO or t_llega == Vector2.ZERO:
		return Vector2.ZERO
	var L := longitud(k)
	var d := minf(8.0, L)
	var w: Vector3 = punto(k, sentido, L)[0] - punto(k, sentido, L - d)[0]
	var llegada := Vector2(w.x, w.z)
	return Vector2(absf(llegada.angle_to(t_sale)), absf(t_llega.angle_to(-llegada)))
