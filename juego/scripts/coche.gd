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
var g_max_vel := GIRO_MAX       # ángulo máximo de las ruedas a la velocidad actual (volante de la cabina)
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
const REPARTO_FRENO := 0.8      # frenada al eje delantero a ~1 g (reparto ideal con la transferencia de carga)
const EBD_TRA := 0.8            # EBD: el trasero trabaja a ≤80 % de lo que trabaja el delantero (nunca se bloquea antes)
const ABS_LAT_DEL := 0.35       # ABS: aun frenando a fondo, la rueda delantera no se bloquea y conserva este agarre lateral
const ABS_LAT_TRA := 0.9        # ABS + CBC: en curva, el trasero suelta presión de freno para conservar casi todo su agarre
const ASR_LAT := 0.35           # control de tracción: con la rueda patinando conserva este agarre lateral
const ESC_KP := 6.0             # ESC: ganancia del par de guiñada correctivo (1/s)
const C_DEL := 13.0             # rigidez de deriva / carga del eje delantero (1/rad)
const C_TRA := 20.0             # ídem trasero: el delantero más blando → coche subvirador, como de serie
const C_PAC := 1.45             # forma de la "fórmula mágica" de Pacejka: pico a ~9° y ~76 % de agarre deslizando
const IZ_FACTOR := 1.0          # inercia de guiñada = m · lf · lr · factor (índice dinámico ≈ 1)
const SENS_DEL := 0.20          # pérdida de agarre por transferencia lateral de carga (sensibilidad a la carga)
const SENS_TRA := 0.12
const SENS_CARGA := 0.12        # v5: sensibilidad del neumático a la carga vertical: un eje más cargado agarra algo
                                # menos por kilo (el trasero de un tracción delantera, ligero, agarra un poco más por kilo)
const DIG_USO := 0.85           # v5 teclado: fracción del agarre delantero que puede pedir el teclado (por la deriva real)
const DIG_V0 := 20.0 / 3.6      # v5.1: por debajo, el teclado da todo el giro (horquillas, maniobras)
const DIG_V1 := 40.0 / 3.6      # v5.1: por encima, límite por deriva completo
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
var entrada_digital := false    # v5: el giro viene de teclas (todo o nada): la dirección la limita la deriva real
var teclas := false             # v6: la última dirección pedida vino de teclas (también al soltarlas, para la vuelta al centro)
var giro_vel := 0.0             # v6: velocidad de giro de las ruedas con teclas (rad/s), para la rampa en S
const T_RAMPA_TECLAS := 0.05    # v6: s en llegar a la velocidad de giro máxima (y en pararla) con teclas
var a_carga := 0.0              # v5: aceleración longitudinal que transfiere carga (sin la componente de la pendiente)
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
	giro_vel = 0.0
	vol_cab = 0.0
	vol_cab_v = 0.0
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
	if marcha_atras and v < -ficha_v_atras():
		f = maxf(f, 0.0)            # tope de la marcha atrás (ver ficha_v_atras)
	f -= 0.5 * RHO * ficha.cx_a * v * absf(v)
	f -= ficha.crr * m * G * signf(v) * (1.0 if en_carretera else 6.0)
	f -= m * G * seno                       # ¡la gravedad de la pendiente real!
	var a := f / m
	# frenada: el pedal pide una deceleración; el freno motor del DSG (retención en la marcha metida) es parte de
	# ella y los discos ponen el resto. Con los dos pies levantados solo retiene el motor.
	var a_freno := freno * ficha.f_freno_max / m * (mu / MU_ASFALTO)
	var a_pedal := a_freno          # deceleración pedida a los discos (el ABS puede soltar parte en curva)
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
	# tope de la dirección a esta velocidad (85 % del agarre lateral, ver abajo): el volante de la cabina enseña qué
	# parte de él se está usando (con el mando a fondo, el volante a fondo también a 100 km/h, como en los juegos de
	# conducción; si se dibujara el ángulo de las ruedas, a esa velocidad apenas se movería unos grados)
	var u_fr0 := clampf(a_pedal / maxf(mu * G, 0.1), 0.0, 1.0)
	var a850 := 0.85 * mu * G * maxf(sqrt(maxf(1.0 - u_fr0 * u_fr0, 0.0)), ABS_LAT_DEL + 0.1)
	g_max_vel = minf(GIRO_MAX, atan(a850 * lb / maxf(v * v, 0.01)) + gradiente_subviraje() * a850)
	if giro_directo:
		objetivo = clampf(volante, -GIRO_MAX, GIRO_MAX)
		giro = move_toward(giro, objetivo, 1.8 * dt)
	else:
		# teclado (v3): dirección progresiva y sensible a la velocidad. El ángulo máximo es el que da, como mucho,
		# el 85 % del agarre lateral: a 20 km/h casi todo el volante, a 100 km/h unos pocos grados, así que mantener
		# A/D a fondo traza la curva sin derrapar. v4: con el subviraje real del coche (gradiente K) sumado.
		# Frenando, el neumático tiene menos agarre lateral libre (círculo de adherencia), así que el ángulo máximo
		# baja con lo que se está frenando: con A/D a fondo y freno a fondo el coche gira lo que el ABS deja, sin
		# saturar las ruedas delanteras.
		var u_fr := clampf(a_pedal / maxf(mu * G, 0.1), 0.0, 1.0)
		var a85 := 0.85 * mu * G * maxf(sqrt(maxf(1.0 - u_fr * u_fr, 0.0)), ABS_LAT_DEL + 0.1)
		var g_max := minf(GIRO_MAX, atan(a85 * lb / maxf(v * v, 0.01)) + gradiente_subviraje() * a85)
		objetivo = volante * g_max
		# v5 (teclado, como los simuladores con ayuda de dirección para teclas): las teclas son todo o nada, así que
		# además del tope por velocidad el ángulo se limita para que la rueda delantera no derive más de lo que da el
		# 85 % de su agarre, medido sobre la marcha real (hacia dónde va de verdad el eje delantero). Si la trasera se
		# empieza a ir, el eje delantero apunta hacia dentro y este límite quita giro solo (contravolante natural).
		if entrada_digital and volante != 0.0 and v > V_DINAMICA:
			var lf_d := lb * (1.0 - reparto())
			var dir_del := atan2(vy + lf_d * r_yaw, v)
			var b_pac := C_DEL / (C_PAC * maxf(mu, 0.1))
			var alfa_t := tan(asin(DIG_USO) / C_PAC) / b_pac
			var limitado := clampf(objetivo, dir_del - alfa_t, dir_del + alfa_t)
			if signf(limitado) != signf(volante) and absf(limitado) > 0.0:
				# contravolante automático solo si la trasera de verdad se va (si no, como mucho recto)
				var beta := atan2(vy, v)
				if absf(beta) < deg_to_rad(3.0): limitado = 0.0
			# v5.1: en horquillas y maniobras (por debajo de ~20 km/h) las teclas dan todo el giro, como un coche real a
			# poca velocidad; el límite por deriva entra poco a poco hasta 40 km/h (antes, a 15-30 km/h en una horquilla
			# el coche no llegaba a girar lo que hacía falta y se iba contra la bionda)
			var w_dig := clampf((v - DIG_V0) / (DIG_V1 - DIG_V0), 0.0, 1.0)
			objetivo = lerpf(objetivo, limitado, w_dig)
		# ≈0,35 s hasta el tope al pulsar y ≈0,25 s para volver al centro al soltar
		var ritmo := g_max / (0.35 if absf(objetivo) > absf(giro) and signf(objetivo) == signf(giro) or giro == 0.0 else 0.25)
		if entrada_digital:
			teclas = true
		elif volante != 0.0:
			teclas = false              # mando o volante real: su eje manda tal cual (sin el suavizado de las teclas)
		if teclas:
			# v6 (teclas, como las ayudas de dirección de los simuladores): el giro sigue al objetivo con una rampa en S,
			# con la velocidad de giro limitada (la misma de antes, sensible a la velocidad) y también su aceleración: al
			# pulsar o soltar, la dirección arranca y se para poco a poco en vez de empezar y frenar de golpe, y sin pasarse
			# del objetivo (frena justo a tiempo). El límite por deriva de arriba sigue mandando sobre el objetivo.
			var r_max := maxf(ritmo, 0.05)
			var a_max := r_max / T_RAMPA_TECLAS
			var e := objetivo - giro
			var w_obj := signf(e) * minf(r_max, sqrt(2.0 * a_max * absf(e)))
			# al soltar o al cambiar de lado, la inercia de la dirección se frena el triple de rápido (no sigue girando)
			var frena := signf(giro_vel) != signf(w_obj) or absf(w_obj) < absf(giro_vel)
			giro_vel = move_toward(giro_vel, w_obj, a_max * (3.0 if frena else 1.0) * dt)
			var paso := giro_vel * dt
			if absf(e) < 1e-5 or (signf(paso) == signf(e) and absf(paso) >= absf(e)) or (signf(paso) != signf(e) and absf(e) < a_max * dt * dt):
				giro = objetivo           # llega sin pasarse
				giro_vel = 0.0
			else:
				giro += paso
		else:
			giro = move_toward(giro, objetivo, maxf(ritmo, 0.05) * dt)
			giro_vel = 0.0
	# el piloto pide la curvatura de su trayectoria (ángulo "geométrico"); se le suma lo que el coche subvira
	var delta := giro
	if giro_directo:
		delta = clampf(giro + gradiente_subviraje() * v * v * tan(giro) / lb, -GIRO_MAX, GIRO_MAX)
	# fuerzas del motor por eje (tracción o retención) y fracción de frenada pedida (1 = frenada máxima)
	var f_motor := empuje if acelerador > 0.0 else -caja.retencion
	var fx_del := f_motor * (REPARTO_4MOTION if ficha.es_4x4() else 1.0)
	var fx_tra := f_motor * ((1.0 - REPARTO_4MOTION) if ficha.es_4x4() else 0.0)
	var b_freno := clampf(a_pedal * m / maxf(ficha.f_freno_max, 1.0), 0.0, 1.0) if freno > 0.0 else 0.0
	var omega := _bicicleta(dt, delta, mu, fx_del, fx_tra, b_freno, a_pedal if freno > 0.0 else 0.0)
	w_rumbo = -omega

	# restos de un choque: los neumáticos frenan el deslizamiento lateral y el trompo
	if absf(giro_ext) > 0.0:
		rumbo += giro_ext * dt
		giro_ext = move_toward(giro_ext, 0.0, (2.5 + absf(giro_ext) * 1.5) * dt)
	if absf(v_lat) > 0.0:
		v_lat = move_toward(v_lat, 0.0, mu * G * dt)
	a_long = lerpf(a_long, (v - v_ant) / dt, 1.0 - exp(-dt * 6.0))
	a_carga = lerpf(a_carga, (v - v_ant) / dt + G * seno, 1.0 - exp(-dt * 6.0))
	a_lat_actual = lerpf(a_lat_actual, v * omega, 1.0 - exp(-dt * 6.0))
	# --- avance --- (v4: más la deriva lateral de los neumáticos, vy)
	var avance := adelante() * v * dt
	var fw2 := adelante()
	avance += Vector3(-fw2.z, 0.0, fw2.x) * (v_lat + vy) * dt
	position.x += avance.x
	position.z += avance.z
	Catalogo.animar_ruedas(modelo, v * dt, giro)
	Catalogo.poner_volante(modelo, angulo_volante_cabina(dt))
	Catalogo.luces_freno(modelo, freno > 0.05)
	odometro += absf(v) * dt
	choque_t = maxf(0.0, choque_t - dt)
	_apoyar(dt)


## v4: reparto de peso estático delante
func reparto() -> float:
	return REPARTO_4M if ficha.es_4x4() else REPARTO_FWD


## Gradiente de subviraje (rad por m/s² de aceleración lateral) que sale de las rigideces de los dos ejes
func gradiente_subviraje() -> float:
	return (1.0 / C_DEL - 1.0 / C_TRA) / G


## Fuerza lateral de un eje (N): Pacejka simplificado. d = agarre lateral que le queda al eje después de lo que
## usa en sentido longitudinal (círculo de adherencia, con el ABS/ASR que no dejan bloquear ni patinar del todo)
## y pendiente inicial c·Fz.
static func _fy(alfa: float, fz: float, d: float, c: float) -> float:
	var b := c * fz / (C_PAC * maxf(d, 1.0))
	return d * sin(C_PAC * atan(b * alfa))


## Agarre lateral disponible (N) de un eje con agarre total dmax que usa la fracción lon en sentido longitudinal;
## piso = lo que conserva gracias al ABS/ASR (la rueda sigue rodando).
static func _d_lateral(dmax: float, lon: float, piso: float) -> float:
	return dmax * maxf(sqrt(maxf(1.0 - lon * lon, 0.0)), piso)


## Modelo de bicicleta dinámico: deriva de los neumáticos, inercia de guiñada y transferencias de carga.
## Integra vy, r_yaw, el rumbo y la velocidad (resistencia en curva) en 4 subpasos. Devuelve la guiñada (rad/s).
## Arreglo v4.1 (frenar girando): la frenada se reparte con EBD (el trasero nunca trabaja más que el delantero),
## el ABS no deja bloquear (el delantero conserva agarre lateral y el trasero suelta presión en curva), y el ESC
## aplica un par de guiñada real (frenando una rueda delantera) para que la trasera no se vaya.
func _bicicleta(dt: float, delta: float, mu: float, fx_del: float, fx_tra: float, b_freno: float = 0.0, a_pedal: float = 0.0) -> float:
	var lb := ficha.batalla
	var m := ficha.masa
	var rep := reparto()
	var lf := lb * (1.0 - rep)
	var lr := lb * rep
	esc_activo = false
	if v < V_DINAMICA:
		# maniobra y marcha atrás: las ruedas ruedan sin deriva (como antes); la deriva que quede se apaga suave
		r_yaw = v * tan(delta) / lb
		vy = move_toward(vy, r_yaw * lr if v > 0.0 else 0.0, mu * G * dt)
		alfa_del = 0.0
		alfa_tra = 0.0
		rumbo -= r_yaw * dt
		derrapando = false
		return r_yaw
	# cargas por eje con la transferencia longitudinal (acelerar descarga el delantero, frenar lo carga)
	# v5: la transferencia sale de la aceleración que dan neumáticos y aire (a_carga), no de la que da la pendiente:
	# subiendo, la gravedad frena el coche pero no carga el morro (antes, en una subida al levantar el pie, el trasero
	# perdía de más agarre y el coche hacía un trompo)
	var dfz := m * a_carga * H_CDG / lb
	var fzf := maxf(m * G * rep - dfz, 0.25 * m * G * rep)
	var fzr := maxf(m * G * (1.0 - rep) + dfz, 0.25 * m * G * (1.0 - rep))
	# transferencia lateral: el neumático exterior no gana lo que pierde el interior → el eje agarra algo menos
	var q := absf(a_lat_actual) / G * 2.0 * H_CDG / ficha.via
	var mu_f := mu * (1.0 - SENS_DEL * q * q)
	var mu_r := mu * (1.0 - SENS_TRA * q * q)
	# v5: sensibilidad a la carga vertical (por kilo, un neumático más cargado agarra algo menos): el delantero de un
	# tracción delantera, con el 60 % del peso, agarra algo menos por kilo que el trasero, y si al levantar el pie
	# el trasero se descarga, por kilo agarra algo más. Por eso un tracción delantera tiende a subvirar.
	var fz0 := 0.5 * m * G
	mu_f *= 1.0 - SENS_CARGA * (fzf / fz0 - 1.0)
	mu_r *= 1.0 - SENS_CARGA * (fzr / fz0 - 1.0)
	var dmax_f := mu_f * fzf
	var dmax_r := mu_r * fzr
	# fracción del agarre de cada eje que se usa en sentido longitudinal (frenos con EBD + motor)
	var bf := b_freno
	var br := b_freno * EBD_TRA
	var lon_f := minf(absf(bf - fx_del / maxf(dmax_f, 1.0)), 1.0)
	var lon_r := minf(absf(br - fx_tra / maxf(dmax_r, 1.0)), 1.0)
	var d_f := _d_lateral(dmax_f, lon_f, ABS_LAT_DEL if b_freno > 0.0 else ASR_LAT)
	var d_r := _d_lateral(dmax_r, lon_r, ABS_LAT_TRA if b_freno > 0.0 else ASR_LAT)
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
	# par máximo del ESC: una rueda delantera frenada a tope, con el brazo de media vía
	var m_esc_max := 0.5 * dmax_f * ficha.via * 0.5
	for i in n:
		var af := delta - atan2(vy + lf * r_yaw, u)
		var ar := -atan2(vy - lr * r_yaw, u)
		var fyf := _fy(af, fzf, d_f, C_DEL)
		var fyr := _fy(ar, fzr, d_r, C_TRA)
		vy += ((fyf * cd + fyr) / m - u * r_yaw) * h
		r_yaw += (lf * fyf * cd - lr * fyr) / iz * h
		u += (vy * r_yaw - fyf * sd / m) * h
		# ABS: lo que el eje usa de lado ya no lo puede usar frenando; los discos sueltan esa parte de la frenada
		if a_pedal > 0.0 and b_freno > 0.0:
			var s_f := clampf(absf(fyf) / maxf(dmax_f, 1.0), 0.0, 1.0)
			var s_r := clampf(absf(fyr) / maxf(dmax_r, 1.0), 0.0, 1.0)
			var kb_f := clampf(sqrt(1.0 - s_f * s_f) / maxf(bf, 0.01), 0.0, 1.0)
			var kb_r := clampf(sqrt(1.0 - s_r * s_r) / maxf(br, 0.01), 0.0, 1.0)
			var entrega := REPARTO_FRENO * kb_f + (1.0 - REPARTO_FRENO) * kb_r
			u += a_pedal * (1.0 - entrega) * h
		# ESC (de serie en el Arteon): compara la guiñada con la que pide el volante (limitada a lo que da el agarre)
		# y, si el coche gira de más (sobreviraje) o la deriva crece, frena una rueda delantera: par de guiñada real
		var a_pico_r := pico / (C_TRA / (C_PAC * maxf(mu_r, 0.1)))
		var r_lim := 0.9 * mu * G / maxf(u, 1.0)
		var r_ref := clampf(u * tan(delta) / (lb + k * u * u), -r_lim, r_lim)
		var beta := atan2(vy, maxf(u, 1.0))
		var sobre := (absf(r_yaw) > absf(r_ref) + 0.02 and absf(ar) > 0.5 * a_pico_r) or signf(r_yaw) != signf(r_ref) and absf(r_yaw) > 0.05
		# v5: la deriva que vigila es la que va más allá de la geométrica del giro (lr·r/u): a 40 km/h en una curva
		# cerrada el coche tiene 5-10° de deriva sin que la trasera deslice, y antes eso disparaba el ESC, que añadía
		# guiñada justo cuando el coche ya subviraba (la trasera parecía irse sola)
		var beta_geo := atan2(lr * r_yaw, maxf(u, 1.0))
		if sobre or absf(beta - beta_geo) > deg_to_rad(4.0):
			var m_esc := clampf(ESC_KP * (r_ref - r_yaw) * iz, -m_esc_max, m_esc_max)
			r_yaw += m_esc / iz * h
			u -= absf(m_esc) / (ficha.via * 0.5) / m * h      # esa rueda frenada también decelera el coche
			esc_activo = absf(m_esc) > 0.05 * m_esc_max
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


## Parte del volante girada (-1..1): el ángulo de las ruedas respecto al tope de dirección a esta velocidad
func fraccion_volante() -> float:
	return clampf(giro / maxf(g_max_vel, 0.02), -1.0, 1.0)


## v6: ángulo del volante de la cabina (rad, + = a la derecha) que corresponde al ángulo real de las ruedas, con la
## desmultiplicación de la dirección progresiva de VW (de serie en el Arteon): 2,1 vueltas de tope a tope (±378°), más
## directa hacia los topes. Antes se dibujaba la parte usada del tope a esta velocidad, así que a 90 km/h unos pocos
## grados de ruedas eran media vuelta de volante y el aro iba a golpes (y saltaba al frenar, porque el tope cambia).
const VOLANTE_RAD_CENTRO := 13.2       # desmultiplicación cerca del centro (como la dirección normal del MQB, supuesto)
static func volante_de_ruedas(delta: float) -> float:
	var d := clampf(delta, -GIRO_MAX, GIRO_MAX)
	var tope := deg_to_rad(378.0)
	var b := (tope - VOLANTE_RAD_CENTRO * GIRO_MAX) / pow(GIRO_MAX, 3.0)
	return VOLANTE_RAD_CENTRO * d + b * d * d * d


## v6: el aro sigue a ese ángulo con un muelle de amortiguación crítica (sin rebote, ≈60 ms), solo en el dibujo: la
## dirección de verdad (giro) no se retrasa nada. Devuelve el ángulo a dibujar (rad).
var vol_cab := 0.0
var vol_cab_v := 0.0
const OMEGA_VOLANTE := 34.0
func angulo_volante_cabina(dt: float) -> float:
	var obj := volante_de_ruedas(giro)
	if dt <= 0.0:
		vol_cab = obj; vol_cab_v = 0.0
		return vol_cab
	# integración exacta del muelle crítico en este paso (estable a cualquier dt)
	var x0 := vol_cab - obj
	var w := OMEGA_VOLANTE
	var ex := exp(-w * dt)
	var c := vol_cab_v + w * x0
	vol_cab = obj + (x0 + c * dt) * ex
	vol_cab_v = (c - w * (x0 + c * dt)) * ex
	return vol_cab


## v6: velocidad máxima en marcha atrás (m/s). La da la marcha atrás real del DSG7 (relación total 12,97–13,96) hasta
## el corte, pero sin pasar de 45 km/h (supuesto: el control del motor limita las vueltas en R; es lo que da de verdad
## un DSG con R a ~4.700 rpm). Antes se cortaba la fuerza a 18 km/h (5 m/s).
const V_ATRAS_MAX := 45.0 / 3.6
func ficha_v_atras() -> float:
	return minf(V_ATRAS_MAX, caja.corte / 60.0 * TAU * caja.r_rueda / caja.rel_r)
