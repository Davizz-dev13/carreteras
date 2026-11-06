## Solo verificación: fotos del volante de la cabina mientras se gira con el teclado (antes/después).
##   godot --rendering-driver opengl3 --resolution 480x300 res://pruebas/captura_volante.tscn -- --dir=/tmp/x --kmh=50
extends Node

var j
var t := 0.0
var listo := false
var cam: Camera3D
var dir := "/tmp"
var tomas: Array = []
var hechas := 0

func _tecla(k: Key, on: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = k
	e.keycode = k
	e.pressed = on
	Input.parse_input_event(e)

func _ready() -> void:
	call_deferred("_correr")

func _correr() -> void:
	j = load("res://escenas/juego.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	dir = str(Ajustes.args.get("dir", "/tmp"))
	Engine.max_physics_steps_per_frame = 1     # un paso de física por fotograma: cada foto, en su instante exacto
	j.piloto = false
	j.hud.visible = false
	for i in 30:
		await get_tree().physics_frame
	j.coche.v = float(Ajustes.args.get("kmh", "50")) / 3.6
	for x in str(Ajustes.args.get("tomas", "0.30,0.36,0.42,0.48,0.56,0.70,1.00,1.60,1.66,1.72,1.80,1.95")).split(","):
		tomas.append(float(x))
	listo = true

func _physics_process(dt: float) -> void:
	if not listo:
		return
	t += dt
	_tecla(KEY_D, t >= 0.3 and t < 1.6)
	if hechas < tomas.size() and t >= tomas[hechas]:
		hechas += 1
		var m: Node3D = j.coche.modelo
		var piv: Node3D = m.get_meta("volante")
		var g := piv.global_transform
		var eje := g.basis.z.normalized()
		var arriba: Vector3 = (j.coche.global_transform.basis.y as Vector3).normalized()
		var txt := "TOMA %d t=%.2f ruedas=%.2f° volante=%.1f° v=%.0f" % [hechas, t, rad_to_deg(j.coche.giro), -rad_to_deg(float(m.get_meta("volante_ang"))), j.coche.v * 3.6]
		RenderingServer.frame_post_draw.connect(_guardar.bind(hechas, txt), CONNECT_ONE_SHOT)

func _guardar(n: int, txt: String) -> void:
	get_viewport().get_texture().get_image().save_png("%s/v_%02d.png" % [dir, n])
	print(txt)
	if n == tomas.size():
		get_tree().quit()
