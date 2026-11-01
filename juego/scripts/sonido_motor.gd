## Sonido del motor del coche del jugador, ligado a las rpm reales de la caja (transmision.gd).
## · Bucles sintetizados offline (pipeline/sonido_motor.py) a rpm fijas, con carga (acelerando) y en retención
##   (pie levantado / corte de inyección), para gasolina TSI y diésel TDI 4 cilindros. Ver datos/sonido/FUENTES.md.
## · En juego: se mezclan las dos bandas más cercanas a las rpm (fundido de igual potencia) y cada una se acelera o
##   frena con pitch_scale para clavar las rpm exactas; carga/retención según el pedal y el corte de inyección.
## · Corte de encendido (limitador) en marcha manual, bajón de par en los cambios del DSG, turbo y soplo de la válvula.
## · Cabina: paso bajo + refuerzo de graves en un bus propio ("MotorJugador"); exterior: escape abierto.
## Uso: snd.coche = coche; coche.add_child(snd). Cada fotograma: snd.cabina = cámara interior. 6 reproductores.
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
var _bandas := PackedFloat32Array()
var _s_carga: Array[AudioStream] = []
var _s_ret: Array[AudioStream] = []
var _p_carga: Array[AudioStreamPlayer] = []   # [par, impar]
var _p_ret: Array[AudioStreamPlayer] = []
var _banda_en := PackedInt32Array([-1, -1])   # banda cargada en el reproductor par / impar
var _p_turbo: AudioStreamPlayer
var _p_soplo: AudioStreamPlayer
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
	for i in 2:
		_p_carga.append(_nuevo_reproductor())
		_p_ret.append(_nuevo_reproductor())
	_p_turbo = _nuevo_reproductor()
	_p_soplo = _nuevo_reproductor()
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


## Carga los bucles del tipo de motor del coche (gasolina o diésel). Solo al empezar o si cambia el coche.
func _cargar() -> void:
	if coche == null or coche.caja == null:
		return
	_diesel = coche.caja.diesel
	var m := "tdi" if _diesel else "tsi"
	if m == _motor:
		return
	var f := FileAccess.open(RUTA + "motor.json", FileAccess.READ)
	if f == null:
		push_warning("SonidoMotor: no está %smotor.json" % RUTA)
		return
	var d = JSON.parse_string(f.get_as_text())
	if typeof(d) != TYPE_DICTIONARY or not d.get("motores", {}).has(m):
		push_warning("SonidoMotor: motor.json sin el motor " + m)
		return
	var lista: Array = d["motores"][m]["rpm"]
	_bandas.resize(lista.size())
	_s_carga.clear()
	_s_ret.clear()
	for i in lista.size():
		_bandas[i] = float(lista[i])
		_s_carga.append(_bucle("%s_carga_%02d.ogg" % [m, i]))
		_s_ret.append(_bucle("%s_retencion_%02d.ogg" % [m, i]))
	_ralenti = coche.caja.ralenti
	_corte = coche.caja.corte
	rpm_sonido = _ralenti
	_banda_en[0] = -1
	_banda_en[1] = -1
	_p_turbo.stream = _bucle("turbo.ogg")
	_p_soplo.stream = load(RUTA + "soplo.ogg")
	_p_turbo.play()
	_motor = m


func _bucle(nombre: String) -> AudioStream:
	var s = load(RUTA + nombre)
	if s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true
	return s


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
		for i in 2:
			_p_carga[i].stream_paused = mudo
			_p_ret[i].stream_paused = mudo
		_p_turbo.stream_paused = mudo
	if mudo:
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
		_p_soplo.volume_db = _db(0.5 * turbo) - 6.0
		_p_soplo.play()
		turbo *= 0.4
	_acel_ant = acel

	# --- cabina / exterior ---
	_cab += ((1.0 if cabina else 0.0) - _cab) * (1.0 - exp(-dt / 0.15))
	if _lpf != null:
		_lpf.cutoff_hz = lerpf(CORTE_EXTERIOR, CORTE_CABINA, sqrt(_cab))
	if _shelf != null:
		_shelf.gain = lerpf(1.0, 1.8, _cab)
	var db_gen := _db(volumen) + DB_BASE + DB_CABINA * _cab

	# --- bandas: las dos más cercanas, fundido de igual potencia, pitch para clavar las rpm ---
	var n := _bandas.size()
	var i := 0
	while i < n - 2 and rpm_sonido >= _bandas[i + 1]:
		i += 1
	var x := clampf((rpm_sonido - _bandas[i]) / (_bandas[i + 1] - _bandas[i]), 0.0, 1.0)
	var g_on := sqrt(carga_sonido)
	var g_off := sqrt(1.0 - carga_sonido)
	for k in 2:
		var b := i + k                         # banda i en el reproductor i%2, la i+1 en el otro
		var p := b % 2
		var w := cos(x * PI * 0.5) if k == 0 else sin(x * PI * 0.5)
		if _banda_en[p] != b:
			_banda_en[p] = b
			_p_carga[p].stream = _s_carga[b]
			_p_ret[p].stream = _s_ret[b]
			var desde := randf() * 1.5
			_p_carga[p].play(desde)
			_p_ret[p].play(desde)
		var tono := clampf(rpm_sonido / _bandas[b], 0.5, 2.0)
		_p_carga[p].pitch_scale = tono
		_p_ret[p].pitch_scale = tono
		_p_carga[p].volume_db = _db(w * g_on) + db_gen
		_p_ret[p].volume_db = _db(w * g_off) + db_gen
	_p_turbo.pitch_scale = 0.55 + 0.6 * turbo
	_p_turbo.volume_db = _db(0.03 + 0.6 * turbo) + db_gen - (2.0 if _diesel else 0.0)


static func _db(lin: float) -> float:
	return linear_to_db(lin) if lin > 0.0001 else -80.0
