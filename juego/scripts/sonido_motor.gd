## Sonido del motor del coche del jugador, ligado a las rpm reales de la caja (transmision.gd).
## · v2: síntesis en tiempo real por tablas de ciclo (motor_sintesis.gd, tablas de pipeline/sonido_motor_v2.py) en un
##   AudioStreamGenerator: el tono sigue a las rpm sin escalones y el timbre (escape, admisión, golpe del diésel) se
##   mezcla entre tablas vecinas de rpm y de carga. Antes eran bucles a rpm fijas estirados con pitch_scale y fundidos de
##   dos en dos: al subir de vueltas el timbre se estiraba y los fundidos entre bucles desfasados "batían".
## · Corte de encendido (limitador) en marcha manual, bajón de par en los cambios del DSG, turbo y soplo de la válvula.
## · Cabina: paso bajo + refuerzo de graves en un bus propio ("MotorJugador"); exterior: escape abierto.
## Uso: snd.coche = coche; coche.add_child(snd). Cada fotograma: snd.cabina = cámara interior. 1 reproductor.
class_name SonidoMotor
extends Node3D

const RUTA := "res://datos/sonido/"
const BUS := "MotorJugador"
const DB_BASE := 0.0             # nivel general (el bus lleva limitador)
const DB_CABINA := -5.0          # dentro suena más bajo (y filtrado)
const CORTE_CABINA := 900.0      # Hz, paso bajo en cabina
const CORTE_EXTERIOR := 18000.0

var coche: Coche
var cabina := false
var volumen := 0.8               # 0…1
var silencio := false

# estado que se puede leer (pruebas / HUD)
var rpm_sonido := 0.0
var carga_sonido := 0.0
var limitador := false
var turbo := 0.0

var _motor := ""                 # "tsi" | "tdi" cargado
var _diesel := false
var _sint := MotorSintesis.new()
var _p: AudioStreamPlayer
var _gen: AudioStreamGenerator
var _pb: AudioStreamGeneratorPlayback
var _buf := PackedVector2Array()
const COLA := 0.05               # s de sonido por delante en el búfer (latencia baja sin cortes)
var _bus := -1
var _lpf: AudioEffectLowPassFilter
var _shelf: AudioEffectLowShelfFilter
var _cab := 0.0                  # 0 exterior … 1 cabina (suavizado)
var _fase_lim := 0.0
var _acel_ant := 0.0
var _pausado := false
var _ralenti := 800.0
var _corte := 5000.0


func _ready() -> void:
	_preparar_bus()
	_p = _nuevo_reproductor()
	_gen = AudioStreamGenerator.new()
	_gen.mix_rate = 22050.0
	_gen.buffer_length = 0.15
	_p.stream = _gen
	_p.playback_type = AudioServer.PLAYBACK_TYPE_STREAM     # en la web, el generador necesita el modo stream
	_p.volume_db = 0.0
	_cab = 1.0 if cabina else 0.0
	_cargar()


func _nuevo_reproductor() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = BUS if _bus >= 0 else &"Master"
	p.volume_db = -80.0
	add_child(p)
	return p


## Bus propio con paso bajo (cabina), refuerzo de graves (cabina) y limitador. Se reutiliza si ya existe.
func _preparar_bus() -> void:
	_bus = AudioServer.get_bus_index(BUS)
	if _bus == -1:
		AudioServer.add_bus()
		_bus = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_bus, BUS)
		AudioServer.set_bus_send(_bus, &"Master")
		var lpf := AudioEffectLowPassFilter.new()
		lpf.cutoff_hz = CORTE_EXTERIOR
		lpf.resonance = 0.6
		AudioServer.add_bus_effect(_bus, lpf)
		var sh := AudioEffectLowShelfFilter.new()
		sh.cutoff_hz = 160.0
		sh.gain = 1.0
		AudioServer.add_bus_effect(_bus, sh)
		var lim := AudioEffectHardLimiter.new()
		lim.ceiling_db = -0.5
		AudioServer.add_bus_effect(_bus, lim)
	_lpf = AudioServer.get_bus_effect(_bus, 0) as AudioEffectLowPassFilter
	_shelf = AudioServer.get_bus_effect(_bus, 1) as AudioEffectLowShelfFilter


## Carga las tablas del tipo de motor del coche (gasolina o diésel). Solo al empezar o si cambia el coche.
func _cargar() -> void:
	if coche == null or coche.caja == null:
		return
	_diesel = coche.caja.diesel
	var m := "tdi" if _diesel else "tsi"
	if m == _motor:
		return
	if not _sint.cargar(m):
		push_warning("SonidoMotor: faltan las tablas del motor " + m)
		return
	_ralenti = coche.caja.ralenti
	_corte = coche.caja.corte
	rpm_sonido = _ralenti
	_motor = m
	if is_inside_tree():
		_p.play()
		_pb = _p.get_stream_playback() as AudioStreamGeneratorPlayback


## Rellena el búfer del generador hasta COLA segundos por delante
func _rellenar() -> void:
	if _pb == null:
		if not _p.playing:
			_p.play()
		_pb = _p.get_stream_playback() as AudioStreamGeneratorPlayback
		if _pb == null:
			return
	var libre := _pb.get_frames_available()
	var cap := int(_gen.buffer_length * _gen.mix_rate)
	var en_cola := cap - libre
	var k := mini(libre, int(COLA * _gen.mix_rate) - en_cola + 256)
	if k <= 0:
		return
	if _buf.size() != k:
		_buf.resize(k)
	_sint.generar(k, _buf)
	_pb.push_buffer(_buf)


func _process(dt: float) -> void:
	if coche == null or coche.caja == null:
		return
	if _motor == "" or coche.caja.diesel != _diesel:
		_cargar()
		if _motor == "":
			return
	var mudo := silencio or volumen <= 0.001
	if mudo != _pausado:
		_pausado = mudo
		_p.stream_paused = mudo
	if mudo:
		return
	control(dt)
	_rellenar()


## Lógica del sonido en un fotograma (rpm con inercia, carga, limitador, cambios, turbo, cabina) → parámetros de la síntesis
func control(dt: float) -> void:
	if _motor == "" or coche.caja.diesel != _diesel:
		_cargar()
		if _motor == "":
			return
	dt = minf(dt, 0.1)
	var caja := coche.caja
	var acel := clampf(coche.acelerador, 0.0, 1.0)

	# --- rpm del sonido: las de la caja, con la inercia del motor (no salta de golpe al pisar) ---
	var rpm_obj := clampf(caja.rpm, _ralenti * 0.9, _corte + 50.0)
	var carga_obj := acel
	limitador = acel > 0.3 and caja.cambio_t <= 0.0 and caja.rpm >= _corte - 30.0
	if limitador:
		# corte de encendido: cae unas rpm sin inyección y vuelve a subir con carga, varias veces por segundo
		_fase_lim = fmod(_fase_lim + dt * (5.0 if _diesel else 11.0), 1.0)
		if _diesel:
			# el diésel tiene regulador: oscila suave, sin cortes secos
			rpm_obj = _corte - 60.0 - 60.0 * sin(_fase_lim * TAU)
			carga_obj = 0.75 + 0.25 * sin(_fase_lim * TAU)
		else:
			var corte_fase := _fase_lim < 0.35
			rpm_obj = _corte - 260.0 * (_fase_lim / 0.35 if corte_fase else (1.0 - _fase_lim) / 0.65)
			carga_obj = 0.08 if corte_fase else 1.0
	else:
		_fase_lim = 0.0
		if caja.corte_inyeccion:
			carga_obj = 0.0
		elif caja.rpm < _ralenti + 250.0:
			carga_obj = maxf(acel, 0.35)          # a ralentí el motor sigue quemando algo
		if caja.cambio_t > 0.0 and caja.rpm_antes > caja.rpm:
			carga_obj *= 0.3                      # cambio ascendente del DSG: corta par un instante
	var sube := 9000.0 if not _diesel else 6000.0
	var baja := 7000.0 if not _diesel else 5000.0
	if limitador:
		rpm_sonido = rpm_obj
	else:
		rpm_sonido = clampf(rpm_obj, rpm_sonido - baja * dt, rpm_sonido + sube * dt)
	carga_sonido += (carga_obj - carga_sonido) * (1.0 - exp(-dt / (0.03 if limitador else 0.06)))

	# --- turbo: soplado según carga y rpm; se vacía al levantar ---
	var t_obj := carga_sonido * clampf((rpm_sonido - (1300.0 if _diesel else 1500.0)) / 1000.0, 0.0, 1.0)
	turbo += (t_obj - turbo) * (1.0 - exp(-dt / (0.35 if t_obj > turbo else 0.25)))
	if not _diesel and acel < 0.1 and _acel_ant >= 0.5 and turbo > 0.45:
		_sint.soplo(0.9 * turbo)                 # válvula de descarga recirculada del TSI: soplido corto, suave
		turbo *= 0.4
	_acel_ant = acel

	# --- cabina / exterior ---
	_cab += ((1.0 if cabina else 0.0) - _cab) * (1.0 - exp(-dt / 0.15))
	if _lpf != null:
		_lpf.cutoff_hz = lerpf(CORTE_EXTERIOR, CORTE_CABINA, sqrt(_cab))
	if _shelf != null:
		_shelf.gain = lerpf(1.0, 1.8, _cab)
	var db_gen := _db(volumen) + DB_BASE + DB_CABINA * _cab

	# --- síntesis: rpm, carga y turbo al generador (van en rampa dentro de cada bloque) ---
	_sint.rpm = rpm_sonido
	_sint.carga = clampf(carga_sonido, 0.0, 1.0)
	_sint.turbo = clampf(turbo, 0.0, 1.0)
	_sint.ganancia = db_to_linear(db_gen) * 0.65


## Para las pruebas: genera k muestras con los parámetros actuales (sin reproductor)
func generar(k: int, out: PackedVector2Array) -> void:
	_sint.generar(k, out)


static func _db(lin: float) -> float:
	return linear_to_db(lin) if lin > 0.0001 else -80.0
