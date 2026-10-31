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
# tras un choque: velocidad lateral (m/s, + derecha) y giro extra (rad/s alrededor del eje vertical) que los
# neumáticos van frenando por rozamiento (μ·g); w_rumbo es el giro que pide la dirección en este paso
var v_lat := 0.0
var giro_ext := 0.0
var w_rumbo := 0.0

# suspensión visual (muelle crítico): ángulos de la carrocería y sus velocidades
var cab := 0.0
var cab_v := 0.0
var bal := 0.0
var bal_v := 0.0
const OMEGA_SUSP := 9.0         # rad/s (≈1,4 Hz, típico de una berlina)

# --- v4: dinámica lateral con neumáticos (modelo de bicicleta dinámico) ---
# Supuestos (valores típicos de una berlina media, no publicados por VW), ver datos/coches/motor_supuestos.json:
const H_CDG := 0.55             # m, altura del centro de gravedad
const REPARTO_FWD := 0.60       # fracción del peso sobre el eje delantero (tracción delantera)
const REPARTO_4M := 0.58        # ídem 4Motion (algo más de peso detrás por el diferencial trasero)
const REPARTO_4MOTION := 0.5    # par al eje delantero a plena tracción (Haldex, hasta 50/50)
const REPARTO_FRENO := 0.7      # frenada al eje delantero
const C_DEL := 13.0             # rigidez de deriva / carga del eje delantero (1/rad)
const C_TRA := 20.0             # ídem trasero: el delantero más blando → coche subvirador, como de serie
const C_PAC := 1.45             # forma de la "fórmula mágica" de Pacejka: pico a ~9° y ~76 % de agarre deslizando
const IZ_FACTOR := 1.0          # inercia de guiñada = m · lf · lr · factor (índice dinámico ≈ 1)
const SENS_DEL := 0.20          # pérdida de agarre por transferencia lateral de carga (sensibilidad a la carga)
const SENS_TRA := 0.12
const V_DINAMICA := 4.0         # m/s: por debajo, giro cinemático (sin deriva), como un coche maniobrando
var vy := 0.0                   # m/s, velocidad lateral del coche por la deriva de los neumáticos (+ derecha)
var r_yaw := 0.0                # rad/s, velocidad de guiñada (+ giro a la derecha)
var alfa_del := 0.0             # rad, ángulos de deriva (para el HUD/pruebas)
var alfa_tra := 0.0
var esc_activo := false         # el control de estabilidad está corrigiendo

# mandos (los rellena juego.gd con teclado o piloto automático)
var acelerador := 0.0
var freno := 0.0
var volante := 0.0              # -1 izquierda … +1 derecha (ángulo pedido normalizado)
var giro_directo := false       # el piloto pide un ángulo exacto en vez de volante
var marcha_atras := false

var modelo: Node3D
var carroceria: Node3D          # hijo del modelo que se inclina con aceleraciones (cosmético)

# v4: cambio DSG + mapa del motor (transmision.gd) y consumo calibrado con dueños reales (consumo.gd)
var caja: Transmision
var consumo: Consumo


func _init(f: Ficha = null) -> void:
	ficha = f if f != null else Catalogo.ficha_elegida()
	caja = Transmision.new(ficha)
	consumo = Consumo.new(caja)


func _ready() -> void:
	modelo = Catalogo.crear_modelo(ficha, Catalogo.color_jugador(), int(Ajustes.args.get("lod_jugador", "0")))
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
	caja.reiniciar()
	vy = 0.0
	r_yaw = 0.0
	v_lat = 0.0
	giro_ext = 0.0
	cab_v = 0.0
	bal_v = 0.0
	var obj := _objetivo_apoyo()
	cab = obj.x
	bal = obj.y
	_aplicar_base()
	reset_physics_interpolation()   # teletransporte: que no se interpole desde la posición anterior


## Fuerza de tracción máxima a la velocidad v (N) con la mejor marcha (lo que da el DSG a fondo / kickdown).
## v4: sale del par del motor a través de las relaciones reales del cambio (transmision.gd), con la misma
## envolvente de prestaciones (0-100 oficial) que antes.
func fuerza_motor(vel: float) -> float:
	return caja.fuerza_max(vel)


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
	# v4: el pedal pide una fracción de la fuerza máxima; el DSG elige marcha y entrega la fuerza de esa marcha
	var empuje := caja.paso(dt, v, acelerador, freno, seno, marcha_atras)
	if acelerador > 0.0:
		var sentido := -1.0 if marcha_atras else 1.0
		f += sentido * empuje
		# limitador electrónico de velocidad máxima (o la máxima real si no lo lleva)
		if v * sentido > ficha.v_max:
			f = 0.0
	if marcha_atras and v < -5.0:
		f = maxf(f, 0.0)
	f -= 0.5 * RHO * ficha.cx_a * v * absf(v)
	f -= ficha.crr * m * G * signf(v) * (1.0 if en_carretera else 6.0)
	f -= m * G * seno                       # ¡la gravedad de la pendiente real!
	var a := f / m
	# frenada: el pedal pide una deceleración; el freno motor del DSG (retención en la marcha metida) es parte de
	# ella y los discos ponen el resto. Con los dos pies levantados solo retiene el motor.
	var a_freno := freno * ficha.f_freno_max / m * (mu / MU_ASFALTO)
	if freno <= 0.0 and acelerador <= 0.0 and v > 1.0 and not marcha_atras:
		a_freno = caja.retencion / m
	consumo.paso(dt, v)
	var v_ant := v
	var v_nueva := v + a * dt
	if absf(v_nueva) <= a_freno * dt:
		v_nueva = 0.0
	else:
		v_nueva -= signf(v_nueva) * a_freno * dt
	if absf(v_nueva) < 0.05 and freno > 0.1 and acelerador == 0.0:
		v_nueva = 0.0
	v = v_nueva
	# --- dirección ---
	var objetivo := 0.0
	if giro_directo:
		objetivo = clampf(volante, -GIRO_MAX, GIRO_MAX)
		giro = move_toward(giro, objetivo, 1.8 * dt)
	else:
		# teclado (v3): dirección progresiva y sensible a la velocidad. El ángulo máximo es el que da, como mucho,
		# el 85 % del agarre lateral: a 20 km/h casi todo el volante, a 100 km/h unos pocos grados, así que mantener
		# A/D a fondo traza la curva sin derrapar. v4: con el subviraje real del coche (gradiente K) sumado.
		var a85 := 0.85 * mu * G
		var g_max := minf(GIRO_MAX, atan(a85 * lb / maxf(v * v, 0.01)) + gradiente_subviraje() * a85)
		objetivo = volante * g_max
		# ≈0,35 s hasta el tope al pulsar y ≈0,25 s para volver al centro al soltar
		var ritmo := g_max / (0.35 if absf(objetivo) > absf(giro) and signf(objetivo) == signf(giro) or giro == 0.0 else 0.25)
		giro = move_toward(giro, objetivo, maxf(ritmo, 0.05) * dt)
	# el piloto pide la curvatura de su trayectoria (ángulo "geométrico"); se le suma lo que el coche subvira
	var delta := giro
	if giro_directo:
		delta = clampf(giro + gradiente_subviraje() * v * v * tan(giro) / lb, -GIRO_MAX, GIRO_MAX)
	# reparto de fuerzas longitudinales entre ejes (para el círculo de adherencia de cada eje)
	var f_frenos := a_freno * m
	var f_motor := empuje if acelerador > 0.0 else -caja.retencion
	var fx_del := f_motor * (REPARTO_4MOTION if ficha.es_4x4() else 1.0) + f_frenos * REPARTO_FRENO
	var fx_tra := f_motor * ((1.0 - REPARTO_4MOTION) if ficha.es_4x4() else 0.0) + f_frenos * (1.0 - REPARTO_FRENO)
	var omega := _bicicleta(dt, delta, mu, fx_del, fx_tra)
	w_rumbo = -omega

	# restos de un choque: los neumáticos frenan el deslizamiento lateral y el trompo
	if absf(giro_ext) > 0.0:
		rumbo += giro_ext * dt
		giro_ext = move_toward(giro_ext, 0.0, (2.5 + absf(giro_ext) * 1.5) * dt)
	if absf(v_lat) > 0.0:
		v_lat = move_toward(v_lat, 0.0, mu * G * dt)
	a_long = lerpf(a_long, (v - v_ant) / dt, 1.0 - exp(-dt * 6.0))
	a_lat_actual = lerpf(a_lat_actual, v * omega, 1.0 - exp(-dt * 6.0))
	# --- avance --- (v4: más la deriva lateral de los neumáticos, vy)
	var avance := adelante() * v * dt
	var fw2 := adelante()
	avance += Vector3(-fw2.z, 0.0, fw2.x) * (v_lat + vy) * dt
	position.x += avance.x
	position.z += avance.z
	Catalogo.animar_ruedas(modelo, v * dt, giro)
	odometro += absf(v) * dt
	choque_t = maxf(0.0, choque_t - dt)
	_apoyar(dt)


## v4: reparto de peso estático delante
func reparto() -> float:
	return REPARTO_4M if ficha.es_4x4() else REPARTO_FWD


## Gradiente de subviraje (rad por m/s² de aceleración lateral) que sale de las rigideces de los dos ejes
func gradiente_subviraje() -> float:
	return (1.0 / C_DEL - 1.0 / C_TRA) / G


## Fuerza lateral de un eje (N): Pacejka simplificado con círculo de adherencia (la fuerza longitudinal fx que
## ya usa el eje le quita agarre lateral) y pendiente inicial c·Fz.
static func _fy(alfa: float, fz: float, mu_eje: float, c: float, fx: float) -> float:
	var dmax := mu_eje * fz
	var d := sqrt(maxf(dmax * dmax - fx * fx, 0.0225 * dmax * dmax))
	var b := c * fz / (C_PAC * d)
	return d * sin(C_PAC * atan(b * alfa))


## Modelo de bicicleta dinámico: deriva de los neumáticos, inercia de guiñada y transferencias de carga.
## Integra vy, r_yaw, el rumbo y la velocidad (resistencia en curva) en 4 subpasos. Devuelve la guiñada (rad/s).
func _bicicleta(dt: float, delta: float, mu: float, fx_del: float, fx_tra: float) -> float:
	var lb := ficha.batalla
	var m := ficha.masa
	var rep := reparto()
	var lf := lb * (1.0 - rep)
	var lr := lb * rep
	esc_activo = false
	if v < V_DINAMICA:
		# maniobra y marcha atrás: las ruedas ruedan sin deriva (como antes)
		r_yaw = v * tan(delta) / lb
		vy = r_yaw * lr if v > 0.0 else 0.0
		alfa_del = 0.0
		alfa_tra = 0.0
		rumbo -= r_yaw * dt
		derrapando = false
		return r_yaw
	# cargas por eje con la transferencia longitudinal (acelerar descarga el delantero, frenar lo carga)
	var dfz := m * a_long * H_CDG / lb
	var fzf := maxf(m * G * rep - dfz, 0.25 * m * G * rep)
	var fzr := maxf(m * G * (1.0 - rep) + dfz, 0.25 * m * G * (1.0 - rep))
	# transferencia lateral: el neumático exterior no gana lo que pierde el interior → el eje agarra algo menos
	var q := absf(a_lat_actual) / G * 2.0 * H_CDG / ficha.via
	var mu_f := mu * (1.0 - SENS_DEL * q * q)
	var mu_r := mu * (1.0 - SENS_TRA * q * q)
	var iz := m * lf * lr * IZ_FACTOR
	var pico := tan(PI / (2.0 * C_PAC))           # B·α en el pico de la curva
	var k := gradiente_subviraje()
	var n := 4
	var h := dt / n
	var cd := cos(delta)
	var sd := sin(delta)
	var u := v
	var w_media := 0.0
	var desliza := false
	for i in n:
		var af := delta - atan2(vy + lf * r_yaw, u)
		var ar := -atan2(vy - lr * r_yaw, u)
		var fyf := _fy(af, fzf, mu_f, C_DEL, fx_del)
		var fyr := _fy(ar, fzr, mu_r, C_TRA, fx_tra)
		vy += ((fyf * cd + fyr) / m - u * r_yaw) * h
		r_yaw += (lf * fyf * cd - lr * fyr) / iz * h
		u += (vy * r_yaw - fyf * sd / m) * h
		# ESC (de serie en el Arteon): si el eje trasero se va y el coche gira más de lo que pide el volante,
		# frena una rueda para devolver la guiñada a la de referencia
		var a_pico_r := pico / (C_TRA / (C_PAC * maxf(mu_r, 0.1)))
		var r_ref := clampf(u * tan(delta) / (lb + k * u * u), -mu * G / u, mu * G / u)
		if absf(ar) > 0.75 * a_pico_r and absf(r_yaw) > absf(r_ref) + 0.03:
			r_yaw = move_toward(r_yaw, r_ref, 2.5 * h)
			vy = move_toward(vy, r_yaw * lr, 2.0 * h)
			u -= 1.5 * h
			esc_activo = true
		rumbo -= r_yaw * h
		w_media += r_yaw / n
		alfa_del = af
		alfa_tra = ar
		var a_pico_f := pico / (C_DEL / (C_PAC * maxf(mu_f, 0.1)))
		desliza = desliza or absf(af) > a_pico_f or absf(ar) > a_pico_r
	v = u
	derrapando = desliza
	return w_media


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
