## Sonido del motor sin escena ni tarjeta de sonido: coche en llano, SonidoMotor (la misma lógica y la misma síntesis que
## en el juego) y las muestras a un WAV (22.050 Hz, mono). Guion de 34 s (ver prueba_sonido.gd --guion=completo).
##   godot --headless res://pruebas/prueba_sonido_wav.tscn -- --coche=arteon_tdi150_dsg --wav=/tmp/x.wav [--cabina=1]
extends Node

class Plano extends Superficie:
	func consultar(_x: float, _z: float, _y: float) -> Vector3:
		return Vector3(0.0, 1.0, 0.0)

func _ready() -> void:
	call_deferred("_correr")

func _correr() -> void:
	Ajustes.superficie = Plano.new()
	var id := str(Ajustes.args.get("coche", "arteon_tdi150_dsg"))
	var f: Ficha = null
	for fi: Ficha in Catalogo.fichas:
		if fi.id == id: f = fi
	var c := Coche.new(f)
	c.colocar(Vector3.ZERO, Vector3(0, 0, -1))
	var snd := SonidoMotor.new()
	snd.coche = c
	snd.cabina = Ajustes.args.get("cabina", "0") == "1"
	var dt := 1.0 / 60.0
	var k := int(22050 / 60) # 367 (22.050/60 = 367,5: se alterna 367/368)
	var buf := PackedVector2Array()
	var pcm := PackedByteArray()
	var t := 0.0
	var acum := 0.0
	var pico := 0.0
	var us_gen := 0
	var csv := FileAccess.open(str(Ajustes.args.get("csv", "/tmp/snd_wav.csv")), FileAccess.WRITE)
	csv.store_line("t,rpm_caja,rpm_sonido,carga,marcha,kmh,limitador,turbo")
	while t < 34.0:
		var pedal := 1.0 if t >= 13.0 and t < 27.0 else 0.0
		c.acelerador = pedal
		c.freno = 0.0
		c.volante = 0.0
		c.paso_fisica(dt)
		t += dt
		if t >= 3.0 and t < 11.0:
			var s := t - 3.0
			var r0 := c.caja.ralenti
			var r1 := c.caja.corte
			c.caja.rpm = lerpf(r0, r1, s / 6.0) if s < 6.0 else (r1 if s < 7.0 else lerpf(r1, r0, clampf(s - 7.0, 0.0, 1.0)))
			c.caja.corte_inyeccion = s >= 7.0
			c.caja.cambio_t = 0.0
			c.acelerador = 0.0 if s >= 7.0 else (0.35 + 0.4 * s / 6.0 if s < 6.0 else 1.0)
		snd.control(dt)
		acum += 22050.0 / 60.0
		var n := int(acum)
		acum -= n
		buf.resize(n)
		var t_us := Time.get_ticks_usec()
		snd.generar(n, buf)
		us_gen += Time.get_ticks_usec() - t_us
		for v in buf:
			pico = maxf(pico, absf(v.x))
			var q := clampi(int(v.x * 32767.0), -32768, 32767)
			pcm.append(q & 0xff); pcm.append((q >> 8) & 0xff)
		csv.store_line("%.3f,%.0f,%.0f,%.3f,%d,%.1f,%d,%.3f" % [t, c.caja.rpm, snd.rpm_sonido, snd.carga_sonido, c.caja.marcha, c.v * 3.6, int(snd.limitador), snd.turbo])
	csv.close()
	var w := FileAccess.open(str(Ajustes.args.get("wav", "/tmp/snd.wav")), FileAccess.WRITE)
	w.store_buffer("RIFF".to_ascii_buffer()); w.store_32(36 + pcm.size()); w.store_buffer("WAVEfmt ".to_ascii_buffer())
	w.store_32(16); w.store_16(1); w.store_16(1); w.store_32(22050); w.store_32(44100); w.store_16(2); w.store_16(16)
	w.store_buffer("data".to_ascii_buffer()); w.store_32(pcm.size()); w.store_buffer(pcm)
	w.close()
	print("SONIDO_WAV %s pico %.3f muestras %d · síntesis %.1f ms por segundo de sonido (%.2f %% de un núcleo)" % [id, pico, pcm.size() / 2, us_gen / 1000.0 / t, us_gen / 10000.0 / t])
	get_tree().quit()
