## Prueba del sonido del motor: carga el juego, mete SonidoMotor en el coche y hace una secuencia de 30 s:
## ralentí 2 s, a fondo subiendo marchas (DSG automático), pie levantado (retención), un acelerón y ralentí.
## Con --limitador=1 pone el cambio en manual y mantiene 2ª a fondo para oír el corte de encendido.
## Graba con Movie Maker (sonido del bus Master) y escribe las rpm de cada fotograma en --log=<csv>.
##   godot --write-movie /tmp/x.avi --fixed-fps 30 res://pruebas/prueba_sonido.tscn -- --ruta=0 --piloto=0 --trafico=0 --log=/tmp/rpm.csv
extends Node

var j
var snd: SonidoMotor
var log_f: FileAccess
var t := 0.0
var listo := false
var lim := false
var dur := 30.0


func _ready() -> void:
	call_deferred("_correr")


func _tecla(k: Key, on: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = k
	e.keycode = k
	e.pressed = on
	Input.parse_input_event(e)


func _correr() -> void:
	j = load("res://escenas/juego.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	for i in 10:
		await get_tree().physics_frame
	lim = str(Ajustes.args.get("limitador", "0")) == "1"
	dur = float(Ajustes.args.get("dur", "14" if lim else "30"))
	if "sonido" in j and j.sonido != null:
		snd = j.sonido                         # el juego ya lleva su SonidoMotor (juego.gd)
	else:
		snd = SonidoMotor.new()
		snd.coche = j.coche
		j.coche.add_child(snd)
	log_f = FileAccess.open(str(Ajustes.args.get("log", "/tmp/snd/rpm.csv")), FileAccess.WRITE)
	log_f.store_line("t,rpm_caja,rpm_sonido,carga,acel,marcha,kmh,cambio_t,limitador,turbo,diesel")
	print("PRUEBA_SONIDO coche=%s diesel=%s ralenti=%.0f corte=%.0f camara=%d" % [j.coche.ficha.id, j.coche.caja.diesel, j.coche.caja.ralenti, j.coche.caja.corte, Ajustes.camara])
	listo = true


## pedal pedido en el instante t de la secuencia
func _pedal(s: float) -> bool:
	if lim:
		return s >= 2.0 and s < 11.0
	if s < 2.0: return false
	if s < 16.0: return true
	if s >= 24.0 and s < 24.35: return true
	return false


func _physics_process(dt: float) -> void:
	if not listo:
		return
	t += dt
	if lim and t > 2.0 and t - dt <= 2.0 and "manual" in j.coche.caja:
		j.coche.caja.pedir_cambio(1)          # pasa a manual (parado se queda en M1: no sube sin vueltas)
	_tecla(KEY_W, _pedal(t))
	snd.cabina = Ajustes.camara == 1
	var c = j.coche
	log_f.store_line("%.4f,%.1f,%.1f,%.3f,%.2f,%d,%.1f,%.3f,%d,%.3f,%d" % [t, c.caja.rpm, snd.rpm_sonido, snd.carga_sonido, c.acelerador, c.caja.marcha, c.v * 3.6, c.caja.cambio_t, int(snd.limitador), snd.turbo, int(c.caja.diesel)])
	if t >= dur:
		listo = false
		log_f.close()
		print("PRUEBA_SONIDO fin t=%.2f" % t)
		get_tree().quit()
