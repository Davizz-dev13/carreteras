## Coche del jugador: modelo "bicicleta" con física longitudinal real
## (motor limitado por potencia, tracción limitada por adherencia, frenos, rodadura, aerodinámica y la GRAVEDAD
## de la pendiente real) y límite de adherencia lateral (si pides más giro del que agarra el neumático, se va de morro).
## Las cifras (potencia, masa, batalla, velocidad máxima, 0-100…) salen de la ficha REAL de la versión elegida
## en el menú (datos/coches/coches.json, cada cifra con su fuente). Ver Ficha en catalogo.gd.
##
## Suavidad (v2): la física va a 60 Hz en _physics_process y Godot interpola la posición en cada fotograma
## (physics_interpolation en project.godot). La altura sale de la superficie real bajo las 4 ruedas, eligiendo
## siempre la calzada más cercana en planta, y el cabeceo/balanceo de la carrocería pasa por un muelle-amortiguador
## (como una suspensión) en vez de copiarse tal cual.
class_name Coche
extends Node3D

const G := 9.81
const MU_ASFALTO := 0.95
const MU_TIERRA := 0.55
const GIRO_MAX := 0.6           # rad en las ruedas
const RHO := 1.2                # densidad del aire (kg/m³)

var ficha: Ficha                # especificaciones reales de la versión elegida

var v := 0.0                    # m/s (negativa = marcha atrás)
var rumbo := 0.0                # rad (rotación en Y; avance = -Z local)
var giro := 0.0                 # ángulo actual de las ruedas
var en_carretera := true
var derrapando := false
var id_via := -1
var odometro := 0.0
var choque_t := 0.0
var a_long := 0.0               # aceleración longitudinal (m/s²) para la inclinación de la carrocería
var a_lat_actual := 0.0

# suspensión visual (muelle crítico): ángulos de la carrocería y sus velocidades
var cab := 0.0
var cab_v := 0.0
var bal := 0.0
var bal_v := 0.0
const OMEGA_SUSP := 9.0         # rad/s (≈1,4 Hz, típico de una berlina)

# mandos (los rellena juego.gd con teclado o piloto automático)
var acelerador := 0.0
var freno := 0.0
var volante := 0.0              # -1 izquierda … +1 derecha (ángulo pedido normalizado)
var giro_directo := false       # el piloto pide un ángulo exacto en vez de volante
var marcha_atras := false

var modelo: Node3D
var carroceria: Node3D          # hijo del modelo que se inclina con aceleraciones (cosmético)


func _init(f: Ficha = null) -> void:
	ficha = f if f != null else Catalogo.ficha_elegida()


func _ready() -> void:
	modelo = Catalogo.crear_modelo(ficha, Catalogo.color_jugador())
	add_child(modelo)


var batalla: float:
	get: return ficha.batalla


func adelante() -> Vector3:
	return Vector3(-sin(rumbo), 0.0, -cos(rumbo))


func colocar(p: Vector3, direccion: Vector3) -> void:
	rumbo = atan2(-direccion.x, -direccion.z)
	position = p
	v = 0.0
	giro = 0.0
	cab_v = 0.0
	bal_v = 0.0
	var obj := _objetivo_apoyo()
	cab = obj.x
	bal = obj.y
	_aplicar_base()
	reset_physics_interpolation()   # teletransporte: que no se interpole desde la posición anterior


## Fuerza de tracción disponible a la velocidad v (N): límite de adherencia/par a baja velocidad y
## potencia en rueda a partir de ahí.
func fuerza_motor(vel: float) -> float:
	return minf(ficha.f_traccion_max, ficha.potencia_rueda / maxf(absf(vel), 1.0))


func fuerza_resistente(vel: float) -> float:
	return 0.5 * RHO * ficha.cx_a * vel * absf(vel) + ficha.crr * ficha.masa * G * signf(vel)


func paso_fisica(dt: float) -> void:
	var fw := adelante()
	var lb := ficha.batalla
	# --- pendiente bajo el coche (alturas reales en los dos ejes) ---
	var h_del := _altura(position + fw * lb * 0.5)
	var h_tra := _altura(position - fw * lb * 0.5)
	var seno := clampf((h_del - h_tra) / lb, -0.5, 0.5)
	var mu := MU_ASFALTO if en_carretera else MU_TIERRA
	var m := ficha.masa
	# --- fuerzas longitudinales ---
	var f := 0.0
	if acelerador > 0.0:
		var sentido := -1.0 if marcha_atras else 1.0
		f += sentido * acelerador * fuerza_motor(v)
		# limitador electrónico de velocidad máxima (o la máxima real si no lo lleva)
		if v * sentido > ficha.v_max:
			f = 0.0
	if marcha_atras and v < -5.0:
		f = maxf(f, 0.0)
	f -= 0.5 * RHO * ficha.cx_a * v * absf(v)
	f -= ficha.crr * m * G * signf(v) * (1.0 if en_carretera else 6.0)
	f -= m * G * seno                       # ¡la gravedad de la pendiente real!
	var a := f / m
	var a_freno := freno * ficha.f_freno_max / m * (mu / MU_ASFALTO)
	var v_ant := v
	var v_nueva := v + a * dt
	if absf(v_nueva) <= a_freno * dt:
		v_nueva = 0.0
	else:
		v_nueva -= signf(v_nueva) * a_freno * dt
	if absf(v_nueva) < 0.05 and freno > 0.1 and acelerador == 0.0:
		v_nueva = 0.0
	v = v_nueva
	# --- dirección con límite de adherencia ---
	var objetivo := 0.0
	if giro_directo:
		objetivo = clampf(volante, -GIRO_MAX, GIRO_MAX)
	else:
		objetivo = volante * GIRO_MAX / (1.0 + absf(v) / 12.0)
	giro = move_toward(giro, objetivo, 1.8 * dt)
	var omega := v * tan(giro) / lb
	var a_lat := absf(v * omega)
	var a_max := mu * G
	derrapando = a_lat > a_max
	if derrapando:
		omega = signf(omega) * a_max / maxf(absf(v), 0.1)
		v -= signf(v) * minf(absf(v), (a_lat - a_max) * 0.25 * dt)
	rumbo -= omega * dt
	a_long = lerpf(a_long, (v - v_ant) / dt, 1.0 - exp(-dt * 6.0))
	a_lat_actual = lerpf(a_lat_actual, v * omega, 1.0 - exp(-dt * 6.0))
	# --- avance ---
	var avance := adelante() * v * dt
	position.x += avance.x
	position.z += avance.z
	odometro += absf(v) * dt
	choque_t = maxf(0.0, choque_t - dt)
	_apoyar(dt)


func _altura(p: Vector3) -> float:
	var r := Ajustes.superficie.consultar(p.x, p.z, position.y)
	return r.x + (0.05 if r.y > 0.5 else 0.0)


## Cabeceo y balanceo que pide la superficie bajo las 4 ruedas (rad) y altura media en z
func _objetivo_apoyo() -> Vector3:
	var fw := adelante()
	var der := Vector3(-fw.z, 0.0, fw.x)
	var c := Ajustes.superficie.consultar(position.x, position.z, position.y)
	en_carretera = c.y > 0.5
	id_via = int(c.z)
	var lb := ficha.batalla * 0.5
	var lv := ficha.via * 0.5
	var hd := _altura(position + fw * lb)
	var ht := _altura(position - fw * lb)
	var hi := _altura(position - der * lv)
	var hr := _altura(position + der * lv)
	return Vector3(atan2(hd - ht, 2.0 * lb), atan2(hr - hi, 2.0 * lv), (hd + ht + hi + hr) * 0.25)


## Apoya el coche: la altura sigue al asfalto (las ruedas no despegan) y la carrocería
## sigue el cabeceo/balanceo de la superficie a través de un muelle con amortiguación crítica.
func _apoyar(dt: float) -> void:
	var obj := _objetivo_apoyo()
	position.y = obj.z
	var k := OMEGA_SUSP * OMEGA_SUSP
	var c := 2.0 * OMEGA_SUSP
	cab_v += (k * (obj.x - cab) - c * cab_v) * dt
	cab += cab_v * dt
	bal_v += (k * (obj.y - bal) - c * bal_v) * dt
	bal += bal_v * dt
	_aplicar_base()


func _aplicar_base() -> void:
	transform.basis = Basis.from_euler(Vector3(cab, rumbo, bal), EULER_ORDER_YXZ)
	# inclinación cosmética de la carrocería: se agacha al frenar y se inclina hacia fuera en las curvas
	if modelo and modelo.has_node("carroceria"):
		var cuerpo: Node3D = modelo.get_node("carroceria")
		cuerpo.rotation = Vector3(clampf(a_long * 0.004, -0.035, 0.035), 0.0, clampf(-a_lat_actual * 0.005, -0.04, 0.04))
