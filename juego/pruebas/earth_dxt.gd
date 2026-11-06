extends Node
## Solo verificación: ¿se puede comprimir a DXT1 (S3TC) en tiempo de ejecución, en el hilo principal y en un hilo?
func _ready() -> void:
	var img := Image.create(512, 512, false, Image.FORMAT_RGB8)
	img.fill(Color(0.3, 0.5, 0.2))
	for i in 2000:
		img.set_pixel(randi() % 512, randi() % 512, Color(randf(), randf(), randf()))
	img.generate_mipmaps()
	var a := img.duplicate()
	var t0 := Time.get_ticks_usec()
	var e: int = a.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
	print("DXT principal err=%d comprimida=%s formato=%d us=%d bytes=%d" % [e, a.is_compressed(), a.get_format(), Time.get_ticks_usec() - t0, a.get_data().size()])
	var tex := ImageTexture.create_from_image(a)
	print("DXT textura ", tex.get_width())
	if Ajustes.args.get("hilo", "0") == "1":
		var b := img.duplicate()
		var res := [null]
		var id := WorkerThreadPool.add_task(_hilo.bind(b, res))
		WorkerThreadPool.wait_for_task_completion(id)
		print("DXT hilo ", res[0])
	get_tree().quit()


func _hilo(b: Image, res: Array) -> void:
	var t1 := Time.get_ticks_usec()
	var e2: int = b.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
	res[0] = [e2, b.is_compressed(), Time.get_ticks_usec() - t1]
