## Mando compartido por los tramos (juego.gd) y el mapa abierto (ma_juego.gd):
##  · joystick derecho = mirar alrededor: la desviación del stick es el ángulo de mirada (como en los juegos de
##    carreras de consola) y al soltarlo la cámara vuelve sola al centro. En persecución la cámara orbita alrededor
##    del coche; en cabina gira la cabeza del conductor.
##  · levas L1 (baja) / R1 (sube) o teclas G / T: cambio manual secuencial del DSG (Transmision.pedir_cambio).
##    R1 o T mantenidos 0,8 s vuelven al automático (D), como mantener la leva + en un DSG de VW.
##    (No Mayús/Ctrl: en la versión web Ctrl+W cerraría la pestaña del navegador.)
class_name Mando
extends RefCounted

const ZONA_MUERTA := 0.15
const GIRO_MAX := deg_to_rad(165.0)          # persecución: casi media vuelta alrededor del coche
const GIRO_MAX_CABINA := deg_to_rad(110.0)    # cabina: girar la cabeza hasta mirar por la ventanilla y algo más
const CABECEO_MAX := deg_to_rad(28.0)
const RAPIDEZ := 9.0                          # 1/s: el ángulo sigue al stick en ~0,1 s (sin saltos)
const MANTENER_AUTO := 0.8                    # s con R1/T mantenido para volver al automático

# lectura de pedales y volante (la usa el mapa abierto; los tramos tienen la suya en juego.gd, idéntica)
const ZONA_VOLANTE := 0.08
const ZONA_GATILLO := 0.03
var gas := 0.0
var freno := 0.0
var volante := 0.0
var x_bruto := 0.0
var mano := false
var _gatillo_neg := {}

var mira := Vector2.ZERO        # x = giro (rad, + = hacia la izquierda), y = cabeceo (rad, + = hacia arriba)
var _sube_t := 0.0              # s que lleva mantenida la leva de subir


# ---- qué mando se lee (compartido por los tramos, Madrid y el mapa grande) ----
# En Windows es muy normal que el mando nº 0 NO sea el que tiene el jugador en la mano: DS4Windows, Steam Input o el
# DualSense crean un mando Xbox virtual al lado del real, y cascos, volantes o teclados RGB se apuntan como mandos.
# Los botones llegan como eventos de cualquier mando, pero los ejes se leían solo del nº 0 → gatillos y joystick
# muertos. Ahora el mando en uso es el último que ha dado una pulsación o un movimiento de verdad (> UMBRAL_USO);
# el primero conectado solo es la suposición inicial. Se decide en _input (Mando.registrar) con cada evento.
const UMBRAL_USO := 0.3
static var activo := -1          # mando en uso (−1 = aún ninguno: se usa el primero conectado)
static var _ejes := {}           # dispositivo -> {eje: último valor visto}: para notar cuándo se mueve de verdad


## Llamar desde _input con cada evento. Si el evento es de verdad (botón pulsado, o eje que se mueve > UMBRAL_USO)
## y de otro mando, ese pasa a ser el mando en uso y lo devuelve; si no, devuelve −1.
static func registrar(ev: InputEvent) -> int:
	if ev is InputEventJoypadMotion:
		var d: int = ev.device
		if not _ejes.has(d):
			_ejes[d] = {}
		var eje: int = ev.axis
		var v: float = ev.axis_value
		var antes: float = _ejes[d].get(eje, 0.0)
		_ejes[d][eje] = v
		var de_verdad := absf(v) > UMBRAL_USO and absf(v - antes) > 0.2
		if eje == JOY_AXIS_TRIGGER_LEFT or eje == JOY_AXIS_TRIGGER_RIGHT:
			de_verdad = v > UMBRAL_USO and v - antes > 0.2      # un gatillo que da −1 en reposo no cuenta como uso
		if de_verdad:
			return _usar(d)
	elif ev is InputEventJoypadButton and ev.pressed:
		return _usar(ev.device)
	return -1


static func _usar(d: int) -> int:
	if d == activo:
		return -1
	activo = d
	return d


## El mando se ha desconectado: se olvida (si era el que estaba en uso, vuelve a la suposición inicial)
static func olvidar(d: int) -> void:
	_ejes.erase(d)
	if d == activo:
		activo = -1


## Mando en uso: el último que ha dado señales de vida; si aún no ha tocado ninguno, el primero conectado (−1 si no hay)
static func pad_actual() -> int:
	if activo >= 0:
		return activo
	var pads := Input.get_connected_joypads()
	return pads[0] if not pads.is_empty() else -1


## Valor de un eje del mando `pad`. Input guarda el estado de cada mando por separado (también el de los eventos de
## Input.parse_input_event), así que se lee de ahí: la tabla de eventos (_ejes) solo sirve para ver quién se mueve, y
## podría quedarse vieja si se suelta un gatillo mientras no hay partida (en el menú principal).
static func eje(pad: int, a: JoyAxis) -> float:
	if pad < 0:
		return 0.0
	return Input.get_joy_axis(pad, a)


## Nombre del mando para los avisos ("" si no hay)
static func nombre(pad: int) -> String:
	if pad < 0:
		return ""
	var n := Input.get_joy_name(pad)
	return n if n != "" else "mando %d" % pad


## R2/L2 analógicos (0..1 con holgura), joystick izquierdo con zona muerta y curva suave, ✕ freno de mano.
## Devuelve true si el jugador está tocando el mando de verdad (para desconectar el piloto).
func leer(pad: int) -> bool:
	if pad < 0:
		gas = 0.0
		freno = 0.0
		volante = 0.0
		x_bruto = 0.0
		mano = false
		return false
	x_bruto = eje(pad, JOY_AXIS_LEFT_X)
	var m := absf(x_bruto)
	var u := clampf((m - ZONA_VOLANTE) / (1.0 - ZONA_VOLANTE), 0.0, 1.0) if m > ZONA_VOLANTE else 0.0
	volante = signf(x_bruto) * (0.45 * u + 0.55 * u * u * u)
	gas = _gatillo(pad, JOY_AXIS_TRIGGER_RIGHT)
	freno = _gatillo(pad, JOY_AXIS_TRIGGER_LEFT)
	mano = Input.is_joy_button_pressed(pad, JOY_BUTTON_A)
	return gas > 0.05 or freno > 0.05 or absf(x_bruto) > 0.3 or mano


func _gatillo(pad: int, a: JoyAxis) -> float:
	var g := eje(pad, a)
	var clave := Vector2i(pad, a)
	if g < -0.2:
		_gatillo_neg[clave] = true        # este mando da el gatillo de −1 (suelto) a +1 (a fondo)
	if _gatillo_neg.get(clave, false):
		g = (g + 1.0) * 0.5
	g = clampf(g, 0.0, 1.0)
	if g <= ZONA_GATILLO:
		return 0.0
	return (g - ZONA_GATILLO) / (1.0 - ZONA_GATILLO)


static func zona(x: float, dz: float = ZONA_MUERTA) -> float:
	var a := absf(x)
	if a <= dz:
		return 0.0
	return signf(x) * minf((a - dz) / (1.0 - dz), 1.0)


## Ángulo de mirada pedido por el joystick derecho, suavizado. Sin mando (pad < 0) vuelve al centro.
func actualizar_mira(pad: int, dt: float, cabina: bool) -> void:
	var x := 0.0
	var y := 0.0
	if pad >= 0:
		x = zona(eje(pad, JOY_AXIS_RIGHT_X))
		y = zona(eje(pad, JOY_AXIS_RIGHT_Y))
	var gmax := GIRO_MAX_CABINA if cabina else GIRO_MAX
	var obj := Vector2(-x * gmax, -y * CABECEO_MAX)
	mira = mira.lerp(obj, 1.0 - exp(-RAPIDEZ * dt))
	if mira.length_squared() < 1e-8:
		mira = Vector2.ZERO


func mirando() -> bool:
	return mira != Vector2.ZERO


## Cabina: gira la cabeza (rumbo y luego cabeceo, en ejes locales de la cámara)
func girar_cabeza(cam: Camera3D) -> void:
	if not mirando():
		return
	cam.rotate_object_local(Vector3.UP, mira.x)
	cam.rotate_object_local(Vector3.RIGHT, mira.y)


## Persecución: órbita alrededor de `pivote` partiendo de la posición/mira normales (que siguen con sus muelles).
## La cámara no baja del terreno (Ajustes.superficie) en el punto de la órbita.
func orbitar(cam: Camera3D, base: Vector3, punto_mira: Vector3, pivote: Vector3) -> void:
	if not mirando():
		cam.global_position = base
		cam.look_at(punto_mira, Vector3.UP)
		return
	var rel := (base - pivote).rotated(Vector3.UP, mira.x)
	var lado := Vector3(-rel.z, 0.0, rel.x)
	if lado.length_squared() > 1e-6:
		rel = rel.rotated(lado.normalized(), -mira.y)  # mirar hacia arriba = la cámara baja (y al revés)
	var p := pivote + rel
	if Ajustes.superficie != null:
		p.y = maxf(p.y, Ajustes.superficie.consultar(p.x, p.z, p.y).x + 0.6)
	cam.global_position = p
	# el punto de mira gira con la cámara (con 165° se mira de frente al coche)
	var m := pivote + (punto_mira - pivote).rotated(Vector3.UP, mira.x)
	cam.look_at(m if m.distance_squared_to(p) > 0.01 else pivote, Vector3.UP)


## Una pulsación de leva: −1 baja, +1 sube. Devuelve true si la caja cambió de marcha.
static func leva(caja: Transmision, d: int) -> bool:
	if caja == null:
		return false
	return caja.pedir_cambio(d)


## Mantener R1 o T 0,8 s → vuelta al automático. Llamar cada cuadro.
func vigilar_vuelta_auto(caja: Transmision, pad: int, dt: float) -> void:
	var mantiene := Input.is_physical_key_pressed(KEY_T) or (pad >= 0 and Input.is_joy_button_pressed(pad, JOY_BUTTON_RIGHT_SHOULDER))
	if not mantiene:
		_sube_t = 0.0
		return
	_sube_t += dt
	if _sube_t >= MANTENER_AUTO and caja != null and caja.manual:
		caja.automatico()


## Teclas de cambio (en _unhandled_input): T sube, G baja. Devuelve -1/+1 o 0 si no es una de ellas.
static func tecla_cambio(ev: InputEvent) -> int:
	if not (ev is InputEventKey and ev.pressed and not ev.echo):
		return 0
	match ev.physical_keycode:
		KEY_T:
			return 1
		KEY_G:
			return -1
	return 0
