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
		var sal: Vector3 = punto(k2i, s2, minf(15.0, longitud(k2i)))[0] - punto(k2i, s2, 0.0)[0]
		sal.y = 0.0
		var f := Vector3(llegada.x, 0.0, llegada.z).normalized()
		var der := Vector3(-f.z, 0.0, f.x)
		var giro := atan2(sal.normalized().dot(der), sal.normalized().dot(f))
		r.append([k2i, s2, giro])
	return r


## Elige la salida: preferencia -1 izquierda, +1 derecha, 0 seguir (misma carretera o la más recta)
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
	var ref: String = datos.tramos[k]["ref"]
	var mejor2 = null
	var nota := -1e9
	for o in op:
		var t2: Dictionary = datos.tramos[o[0]]
		var v := -absf(o[2]) * 2.0
		if ref != "" and t2["ref"] == ref:
			v += 3.0
		if int(t2["enlace"]) == 1 and int(datos.tramos[k]["enlace"]) == 0:
			v -= 1.0
		if v > nota:
			nota = v
			mejor2 = o
	return mejor2


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
