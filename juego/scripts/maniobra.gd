## Maniobra de recolocación a poca velocidad (compartida por el tráfico tras un choque y por el piloto automático):
## cuando un coche ha quedado cruzado, mirando al revés, encajado contra la bionda o fuera de su carril y no puede
## volver a él simplemente avanzando, maniobra como un conductor real: hacia delante con la dirección a tope hacia
## su carril hasta quedarse sin sitio, marcha atrás con la dirección al contrario hasta quedarse sin sitio, y otra vez
## hacia delante (cambio de sentido "en varios puntos"). Al quedar alineado con el carril (±10°) y cerca de él
## (< 0,8 m), termina y el coche sigue circulando con su lógica normal.
##
## Plano X-Z guardado como Vector2(x, z); f vector unitario de avance; derecha = Vector2(-f.y, f.x) (como colisiones.gd).
## Convenio del giro: + derecha (como coche.gd). Giro cinemático: df/dt = v·tan(δ)/batalla · derecha.
class_name Maniobra
extends RefCounted

const GIRO_MAX := 0.6          # rad (el tope de las ruedas, coche.gd GIRO_MAX)
const V_ADELANTE := 2.6        # m/s maniobrando hacia delante (≈ 9 km/h)
const V_ATRAS := 1.8           # m/s marcha atrás (≈ 6,5 km/h)
const MARGEN := 0.45           # m de sitio libre por delante/detrás con el que se cambia de sentido
const TRAMO_MAX_ATRAS := 7.0   # m como mucho en cada marcha atrás
const ALINEADO := 0.30         # rad (≈ 17°) para darla por terminada (el resto lo corrige conduciendo)
const CERCA := 1.4             # m de distancia lateral al carril para darla por terminada

var marcha := 1                # +1 adelante, -1 atrás
var sentido_giro := 1.0        # hacia qué lado va girando el coche (se conserva cuando va casi al revés)
var recorrido := 0.0           # m en la marcha actual
var t_marcha := 0.0
var t_atasco := 0.0            # s pidiendo moverse sin moverse (bionda, otro coche)
var cambios := 0               # cambios de sentido (para las pruebas)
var activa := false
var sin_avance := 0            # cambios de sentido seguidos sin moverse ni 30 cm (encajado entre dos cosas)
var forzar := false            # tras varios: el que llama deja de contar el borde de la calzada como obstáculo


func empezar() -> void:
	sin_avance = 0
	forzar = false
	marcha = 1
	recorrido = 0.0
	t_marcha = 0.0
	t_atasco = 0.0
	cambios = 0
	activa = true


static func derecha(f: Vector2) -> Vector2:
	return Vector2(-f.y, f.x)


## Ángulo con signo (+ = a la derecha) de la dirección d vista desde un coche que mira hacia f
static func angulo(f: Vector2, d: Vector2) -> float:
	return atan2(d.dot(derecha(f)), d.dot(f))


## Cuando termina, el coche vuelve a conducir normal y se acerca al centro del carril y endereza los últimos grados
## poco a poco (trafico.gd: desf / dyaw; el piloto, con su persecución pura).
##
## Un paso de la maniobra.
##  p, f: posición y avance del coche · v: su velocidad real (m/s, negativa marcha atrás)
##  carril_p, carril_t: punto del carril más cercano y su dirección de marcha · mira_p: punto del carril unos metros
##  por delante · libre: Callable(sentido ±1, giro rad) -> metros libres moviéndose en ese sentido con ese giro (arco)
##  batalla: m · dt: s
## Devuelve {marcha: ±1, giro: rad (+ derecha), v: m/s pedida (≥ 0), hecho: bool}
func paso(p: Vector2, f: Vector2, v: float, carril_p: Vector2, carril_t: Vector2, mira_p: Vector2,
		libre: Callable, batalla: float, dt: float) -> Dictionary:
	var e := angulo(f, carril_t)                      # error de rumbo respecto al carril
	var d_lat := (p - carril_p).dot(derecha(carril_t))  # + = a la derecha del carril
	var hacia := mira_p - p
	var a := angulo(f, hacia)                          # dirección al punto de mira
	if absf(e) < 2.6:
		sentido_giro = 1.0 if a >= 0.0 else -1.0       # el lado hacia el que hay que girar (casi al revés: se conserva)
	# giro deseado en cada sentido y el sitio que queda siguiendo ese arco; si no cabe, el giro más parecido que quepa
	var g_del := GIRO_MAX * sentido_giro if absf(a) > PI * 0.5 else clampf(atan(2.0 * batalla * sin(a) / maxf(hacia.length(), 1.0)), -GIRO_MAX, GIRO_MAX)
	var g_tra := -GIRO_MAX * sentido_giro if absf(e) >= 0.5 else -clampf(e * 1.5, -GIRO_MAX, GIRO_MAX)
	# probar otros giros solo para corregir poco (una esquina contra la valla); en un giro grande (cambio de sentido en
	# varios puntos) se mantiene el lado y se cambia de marcha, si no podía ir y venir girando al revés sin acabar nunca
	var ad: Array = _mejor_arco(libre, 1, g_del) if absf(a) < 1.2 else [g_del, float(libre.call(1, g_del))]
	var at: Array = _mejor_arco(libre, -1, g_tra) if absf(e) < 0.5 else [g_tra, float(libre.call(-1, g_tra))]
	var libre_del: float = ad[1]
	var libre_tra: float = at[1]
	if absf(e) < ALINEADO and absf(d_lat) < CERCA and float(libre.call(1, 0.0)) > MARGEN + 0.5:
		activa = false
		return {"marcha": 1, "giro": clampf(a * 0.5, -GIRO_MAX, GIRO_MAX), "v": V_ADELANTE, "hecho": true}
	t_marcha += dt
	recorrido += absf(v) * dt
	# atasco: pide moverse y no se mueve (la bionda o un coche que no se ven en los huecos)
	if absf(v) < 0.15 and t_marcha > 0.6:
		t_atasco += dt
	else:
		t_atasco = 0.0
	var cambiar := false
	if marcha > 0:
		if libre_del < MARGEN or t_atasco > 0.8:
			cambiar = true
	else:
		# marcha atrás: hasta que el carril quede por delante a tiro, sin sitio detrás o tras TRAMO_MAX_ATRAS
		if libre_tra < MARGEN or t_atasco > 0.8 or recorrido > TRAMO_MAX_ATRAS:
			cambiar = true
		elif recorrido > 1.2 and absf(a) < 0.6 and absf(e) < 0.9 and libre_del > MARGEN + 1.0:
			cambiar = true
	if cambiar and t_marcha > 0.5:
		sin_avance = sin_avance + 1 if recorrido < 0.3 else 0
		if sin_avance >= 4:
			forzar = true
		marcha = -marcha
		recorrido = 0.0
		t_marcha = 0.0
		t_atasco = 0.0
		cambios += 1
	var giro: float
	var vel: float
	if marcha > 0:
		giro = ad[0]
		vel = clampf(0.4 + (libre_del - MARGEN) * 0.9, 0.0, V_ADELANTE)
	else:
		giro = at[0]
		vel = clampf(0.4 + (libre_tra - MARGEN) * 0.9, 0.0, V_ATRAS)
	return {"marcha": marcha, "giro": giro, "v": vel, "hecho": false}


## [giro, metros libres]: el giro deseado si deja sitio; si no, el de los topes o recto que más sitio deje (así un coche
## con una esquina contra la valla sale girando hacia el otro lado en vez de quedarse cambiando de marcha)
static func _mejor_arco(libre: Callable, sentido: int, deseado: float) -> Array:
	var l0: float = libre.call(sentido, deseado)
	if l0 >= MARGEN + 0.6:
		return [deseado, l0]
	var mejor := [deseado, l0]
	for g in [GIRO_MAX, -GIRO_MAX, 0.0]:
		var l: float = libre.call(sentido, g)
		if l > float(mejor[1]) + 0.3:
			mejor = [g, l]
	return mejor


## Avance cinemático (para el tráfico): mueve p y gira f con el giro y la velocidad con signo
static func mover(p: Vector2, f: Vector2, v_signo: float, giro: float, batalla: float, dt: float) -> Array:
	var w := v_signo * tan(giro) / maxf(batalla, 1.0)
	var f2 := (f + derecha(f) * w * dt).normalized()
	return [p + f2 * v_signo * dt, f2]


## Metros libres (como mucho `hasta`) moviéndose hacia delante (sentido = +1) o hacia atrás (−1) con el giro dado,
## siguiendo el arco: cada 0,3 m se prueban el centro y las dos esquinas del paragolpes de ese lado.
## bloqueado.call(q, q0) dice si el punto q está ocupado (q0: el mismo punto del paragolpes al empezar, para saber si un
## borde de la calzada se cruza hacia fuera).
static func libre(p: Vector2, f: Vector2, sentido: int, giro: float, largo: float, ancho: float, batalla: float,
		bloqueado: Callable, hasta := 3.0) -> float:
	var lados := [0.0, ancho * 0.5 - 0.1, -(ancho * 0.5 - 0.1)]
	var q0s := []
	for l in lados:
		q0s.append(p + f * (sentido * largo * 0.5) + derecha(f) * float(l))
	var pp := p
	var ff := f
	var d := 0.0
	while d <= hasta:
		var base := pp + ff * (sentido * largo * 0.5)
		var r := derecha(ff)
		for i in lados.size():
			if bloqueado.call(base + r * float(lados[i]), q0s[i]):
				return d
		var mv := mover(pp, ff, sentido * 0.3, giro, batalla, 1.0)
		pp = mv[0]
		ff = mv[1]
		d += 0.3
	return hasta + 0.5


## ¿Está q dentro de la caja (centro c, avance fc, largo × ancho) con un margen?
static func dentro(q: Vector2, c: Vector2, fc: Vector2, largo: float, ancho: float, margen := 0.15) -> bool:
	var dq := q - c
	return absf(dq.dot(fc)) < largo * 0.5 + margen and absf(dq.dot(derecha(fc))) < ancho * 0.5 + margen
