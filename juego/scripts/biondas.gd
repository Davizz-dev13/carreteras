## Choque del coche del jugador contra los quitamiedos (bionda). El coche es un modelo propio (no un cuerpo de Godot),
## así que el choque se resuelve igual que el de coches (colisiones.gd): en planta (2D), con la caja real de la ficha
## (largo × ancho) contra la cara de la bionda que da a la calzada, como una pared de un solo lado y masa infinita.
##  · golpe en ángulo: impulso normal con restitución 0,1 y rozamiento chapa-acero 0,35 (el de colisiones.gd):
##    el coche rebota poco, roza, pierde velocidad y gira hasta quedar paralelo a la valla
##  · de frente: se para en seco (solo rebota el 10 % de la velocidad contra la valla)
##  · sin atravesarla: se mira hasta PROF_MAX m detrás de la cara (a 250 km/h el coche avanza 1,2 m por paso de
##    física de 1/60 s) y solo si el centro del coche está del lado de la calzada; sin salto: todo es en planta
##  · solo con biondas a la altura del coche (± ALTO_MAX): un puente por encima o una vía por debajo no cuentan
## APROXIMACIÓN (no hay datos publicados que encajen en este modelo): la bionda real se deforma (hasta ~1 m) y reparte el
## golpe por el costado; aquí es rígida, con poca restitución y medio brazo de palanca (BRAZO) para imitarlo. Sin daños.
## Coste: rejilla de CELDA m; por paso de física se miran solo los segmentos de las celdas de las 4 esquinas.
class_name Biondas
extends RefCounted

const CELDA := 16.0
const PROF_MAX := 1.6         # m detrás de la cara en los que aún se considera choque (no atravesar a alta velocidad)
const ALTO_MAX := 2.0         # m de diferencia de altura entre la bionda y el coche
const RESTITUCION := 0.1      # la bionda se deforma y se queda con casi toda la energía del golpe normal
const ROCE := 0.35            # chapa contra acero (el mismo rozamiento chapa-chapa de colisiones.gd)
const BRAZO := 0.75           # la valla cede y reparte el contacto por el costado: 3/4 del brazo de la esquina
                              # (ajustado a ojo: a 100 km/h y 20° sale a ~8°, como en los ensayos EN 1317 TB32)

var pa := PackedVector2Array()     # inicio de cada segmento (x, z) en la cara que da a la calzada
var pb := PackedVector2Array()     # final
var pn := PackedVector2Array()     # normal unitaria hacia la calzada
var py := PackedFloat32Array()     # altura media de la calzada en el segmento
var celdas := {}                   # Vector2i -> PackedInt32Array


func vacia() -> bool:
	return pa.is_empty()


## Añade un segmento de bionda (p → q, a la altura de la calzada) con su normal hacia la calzada
func anadir(p: Vector3, q: Vector3, hacia_calzada: Vector2) -> void:
	var k := pa.size()
	pa.append(Vector2(p.x, p.z))
	pb.append(Vector2(q.x, q.z))
	pn.append(hacia_calzada.normalized())
	py.append((p.y + q.y) * 0.5)
	var m := PROF_MAX + 0.5
	for cx in range(floori((minf(p.x, q.x) - m) / CELDA), floori((maxf(p.x, q.x) + m) / CELDA) + 1):
		for cz in range(floori((minf(p.z, q.z) - m) / CELDA), floori((maxf(p.z, q.z) + m) / CELDA) + 1):
			var c := Vector2i(cx, cz)
			if not celdas.has(c):
				celdas[c] = PackedInt32Array()
			celdas[c].append(k)


## Añade una polilínea (puntos de la cara de la valla) con la calzada a la derecha (lado > 0) o a la izquierda (lado < 0)
## del sentido en que se recorre
func anadir_linea(pts: PackedVector3Array, calzada_a_la_derecha: bool) -> void:
	for i in pts.size() - 1:
		var p := pts[i]
		var q := pts[i + 1]
		var t := Vector2(q.x - p.x, q.z - p.z)
		if t.length_squared() < 1e-6:
			continue
		var der := Vector2(-t.y, t.x)     # mismo convenio que Coche: derecha = (-z, x) del avance
		anadir(p, q, der if calzada_a_la_derecha else -der)


## Contacto más profundo de la caja del coche contra los segmentos de estas biondas (o {} si no toca)
func contacto(centro: Vector2, esquinas: Array, y: float, mejor: Dictionary) -> Dictionary:
	var vistos := {}
	for e in esquinas:
		var lista = celdas.get(Vector2i(floori(e.x / CELDA), floori(e.y / CELDA)))
		if lista == null:
			continue
		for k in lista:
			if vistos.has(k):
				continue
			vistos[k] = true
			if absf(py[k] - y) > ALTO_MAX:
				continue
			var a := pa[k]
			var n := pn[k]
			if (centro - a).dot(n) <= 0.0:      # el coche está detrás de la valla (fuera de la calzada): no cuenta
				continue
			var t := pb[k] - a
			var largo := t.length()
			if largo < 1e-4:
				continue
			t /= largo
			for c in esquinas:
				var u: float = (c - a).dot(t)
				if u < -0.05 or u > largo + 0.05:
					continue
				var prof: float = -(c - a).dot(n)
				if prof > 0.0 and prof < PROF_MAX and prof > float(mejor.get("prof", 0.0)):
					mejor = {"prof": prof, "n": n, "punto": c}
	return mejor


## ¿Choca con la valla un punto q del paragolpes que se mueve desde q0? (maniobras a poca velocidad, maniobra.gd):
## q queda a menos de 12 cm de la cara o detrás de ella, con q0 del lado de la calzada
func bloquea(q: Vector2, q0: Vector2, y: float) -> bool:
	var lista = celdas.get(Vector2i(floori(q.x / CELDA), floori(q.y / CELDA)))
	if lista == null:
		return false
	for k in lista:
		if absf(py[k] - y) > ALTO_MAX:
			continue
		var a := pa[k]
		var t := pb[k] - a
		var largo := t.length()
		if largo < 1e-4:
			continue
		var u := (q - a).dot(t / largo)
		if u < -0.05 or u > largo + 0.05:
			continue
		var n := pn[k]
		var dq := (q - a).dot(n)
		if (q0 - a).dot(n) > -0.05 and dq < 0.12 and dq > -PROF_MAX:
			return true
	return false


## Resuelve el choque del coche del jugador contra las biondas dadas (un paso de física). Devuelve la velocidad
## (m/s) con que el coche iba contra la valla en el golpe más fuerte de este paso (0 si no ha tocado).
static func resolver(c: Coche, listas: Array) -> float:
	var golpe := 0.0
	var fi := c.ficha
	for iter in 3:
		var fw3 := c.adelante()
		var f := Vector2(fw3.x, fw3.z)
		var r := Vector2(-f.y, f.x)
		var p := Vector2(c.position.x, c.position.z)
		var a := f * fi.largo * 0.5
		var b := r * fi.ancho * 0.5
		var esquinas := [p + a + b, p + a - b, p - a + b, p - a - b]
		var mejor := {}
		for l in listas:
			if l != null:
				mejor = (l as Biondas).contacto(p, esquinas, c.position.y, mejor)
		if mejor.is_empty():
			break
		var n: Vector2 = mejor["n"]
		p += n * (float(mejor["prof"]) + 0.005)
		c.position.x = p.x
		c.position.z = p.y
		var I := Colisiones.inercia(fi.masa, fi.largo, fi.ancho)
		var vel := f * c.v + r * (c.v_lat + c.vy)
		var w := c.giro_ext + c.w_rumbo
		var ra: Vector2 = (mejor["punto"] as Vector2) + n * float(mejor["prof"]) - p
		ra = f * ra.dot(f) * BRAZO + r * ra.dot(r)
		var vrel := Colisiones._vel_punto(vel, w, ra)
		var vn := -vrel.dot(n)
		if vn <= 0.0:
			continue
		var rn := Colisiones._cruz(ra, n)
		var j := (1.0 + RESTITUCION) * vn / (1.0 / fi.masa + rn * rn / I)
		var J := n * j
		var tg := vrel + n * vn
		if tg.length() > 1e-4:
			tg = tg.normalized()
			var rt := Colisiones._cruz(ra, tg)
			J += tg * clampf(-vrel.dot(tg) / (1.0 / fi.masa + rt * rt / I), -ROCE * j, ROCE * j)
		vel += J / fi.masa
		w += Colisiones._cruz(ra, J) / I
		golpe = maxf(golpe, vn)
		c.v = vel.dot(f)
		c.v_lat = vel.dot(r)
		c.vy = 0.0
		c.giro_ext = w - c.w_rumbo
		if vn > 2.0:
			c.choque_t = 1.0
	return golpe
