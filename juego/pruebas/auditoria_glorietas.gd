extends Node
## Solo verificación: auditoría visual de TODAS las glorietas de una zona vieja. Por glorieta: vista aérea (con los
## caminos del piloto/tráfico de la ruta dibujados si --caminos=1) y, si la ruta pasa por ella, la vista del conductor en
## los dos sentidos (llegando a ~60 m, en la línea de ceda, en el anillo y saliendo); si no, la vista desde dos brazos.
## --zona=m406 --dir=carpeta --pref=x [--solo=3,96] [--caminos=1] [--frames=12] [--sin_aerea=1] [--sin_conductor=1]
var j: Node
var cam: Camera3D
var frames := 12
var frames_c := 8
var lineas: MeshInstance3D


func _ready() -> void:
	var zona: String = Ajustes.args["zona"]
	frames = int(Ajustes.args.get("frames", "12"))
	var solo := {}
	if Ajustes.args.has("solo"):
		for t in str(Ajustes.args["solo"]).split(","):
			solo[int(t)] = true
	Ajustes.rutas.clear()
	Ajustes.cambiar_zona("")
	Ajustes.cambiar_zona(zona)
	j = load("res://escenas/juego.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	j.pausado = true
	j.hud.visible = false
	cam = Camera3D.new()
	cam.far = 75000.0
	cam.near = 0.2
	add_child(cam)
	cam.current = true
	var dir: String = Ajustes.args["dir"]
	var pref: String = Ajustes.args.get("pref", "x")
	var caminos := str(Ajustes.args.get("caminos", "0")) == "1"
	if Ajustes.args.has("frames_conductor"):
		frames_c = int(Ajustes.args["frames_conductor"])
	if caminos:
		_dibujar_caminos()
	var gl: Array = Ajustes.glorietas
	var orden := []
	if Ajustes.args.has("solo"):
		for t in str(Ajustes.args["solo"]).split(","):
			orden.append(int(t))
	else:
		orden = range(gl.size())
	for gi in orden:
		var inf := GlorietaTipo.info(gl[gi])
		if not inf["ok"]:
			print("GL ", gi, " no_ok")
			continue
		var c: Vector3 = inf["c"]
		var ro := float(inf["r"]) + float(inf["hw"])
		var base := "%s/%s_%s_g%d" % [dir, pref, zona, gi]
		var tiene_ruta := false
		for r in Ajustes.rutas:
			for ar in r.arcos_glorieta:
				if int(ar["g"]) == gi:
					tiene_ruta = true
		print("GL ", gi, " c=", Vector2i(roundi(c.x), roundi(c.z)), " r=", snappedf(float(inf["r"]), 0.1), " hw=", inf["hw"], " ruta=", tiene_ruta, " brazos=", GlorietaMalla.brazos_info.get(gi, []).size())
		_comprobar_caminos(gi, inf)
		if str(Ajustes.args.get("sin_aerea", "0")) != "1":
			var h := (ro + 38.0) / 0.7
			var obj := Vector3(c.x, Ajustes.superficie.consultar(c.x, c.z, c.y).x, c.z)
			if lineas != null:
				lineas.visible = true
			await _foto(obj + Vector3(0, h, 2.0), obj, 70.0, base + "_aer.png")
			if lineas != null:
				lineas.visible = false
		if str(Ajustes.args.get("sin_conductor", "0")) == "1":
			continue
		if tiene_ruta:
			for ri in Ajustes.rutas.size():
				var r: Ruta = Ajustes.rutas[ri]
				for ar in r.arcos_glorieta:
					if int(ar["g"]) != gi:
						continue
					var sa := float(ar["a"]) * r.paso
					var sb := float(ar["b"]) * r.paso
					var b_a := sa
					var b_b := sb
					for bo in r.bocas_glorieta:
						if int(bo["g"]) == gi:
							var sbo := float(bo["i"]) * r.paso
							if int(bo["dir"]) < 0 and absf(sbo - sa) < 40.0:
								b_a = sbo
							elif int(bo["dir"]) > 0 and absf(sbo - sb) < 40.0:
								b_b = sbo
					for d in [1, -1]:
						var s_ent := b_a if d == 1 else b_b
						var s_sal := b_b if d == 1 else b_a
						var vistas := [["1aprox", s_ent - d * 60.0], ["2ceda", s_ent - d * 5.0], ["3anillo", (sa + sb) * 0.5],
								["4salida", s_sal + d * 12.0]]
						for vv in vistas:
							var s: float = clampf(vv[1], 1.0, r.longitud() - 1.0)
							await _foto_carril(r, s, d, "%s_r%d_%s_%s.png" % [base, ri, "ida" if d == 1 else "vuelta", vv[0]])
		else:
			var bi: Array = GlorietaMalla.brazos_info.get(gi, [])
			var nb := 0
			var max_b := int(Ajustes.args.get("brazos", "2"))
			for b in bi:
				if nb >= max_b:
					break
				var x0: Vector3 = b[0]
				var u: Vector3 = b[1]
				# en el corte del brazo (sobre la vía, a ~31 m del anillo), un poco a la derecha (carril de entrada)
				var pc0: Vector3 = b[4]
				var hacia := Vector3(x0.x - pc0.x, 0.0, x0.z - pc0.z).normalized()
				var p := pc0 + Vector3(-hacia.z, 0.0, hacia.x) * 1.8 - hacia * 4.0
				p.y = Ajustes.superficie.consultar(p.x, p.z, pc0.y).x + 1.25
				var o := x0 - u * 12.0
				o.y = Ajustes.superficie.consultar(o.x, o.z, x0.y).x + 0.6
				var f0 := frames
				frames = frames_c
				await _foto(p, o, 75.0, "%s_brazo%d.png" % [base, nb])
				frames = f0
				nb += 1
	get_tree().quit()


func _foto_carril(r: Ruta, s: float, d: int, out: String) -> void:
	var p := r.punto_carril(s, d)
	p.y = Ajustes.superficie.consultar(p.x, p.z, p.y).x + 1.2
	var o := r.punto_carril(clampf(s + d * 22.0, 0.0, r.longitud()), d)
	o.y = Ajustes.superficie.consultar(o.x, o.z, o.y).x + 0.7
	var f0 := frames
	frames = frames_c
	await _foto(p, o, 75.0, out)
	frames = f0


func _foto(pos: Vector3, obj: Vector3, fov: float, out: String) -> void:
	var fw := obj - pos
	fw.y = 0.0
	fw = fw.normalized() if fw.length() > 0.01 else Vector3.FORWARD
	j.coche.position = obj + Vector3(0, -40, 0)
	j.mundo.cargar_ventana(obj, fw)
	cam.fov = fov
	cam.look_at_from_position(pos, obj, Vector3.UP)
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("FOTO ", out)


## Caminos del piloto/tráfico por la ruta junto a cada glorieta: verde = sentido +1 (ida), magenta = -1 (vuelta)
func _dibujar_caminos() -> void:
	var mv := PackedVector3Array()
	var cols := PackedColorArray()
	for r in Ajustes.rutas:
		for ar in r.arcos_glorieta:
			var s0 := float(ar["a"]) * r.paso - 80.0
			var s1 := float(ar["b"]) * r.paso + 80.0
			for d in [1, -1]:
				var col := Color(0.1, 1.0, 0.2) if d == 1 else Color(1.0, 0.1, 0.9)
				var prev := Vector3.INF
				var s := maxf(s0, 0.0)
				while s < minf(s1, r.longitud()):
					var q := r.punto_carril(s, d)
					q.y = Ajustes.superficie.consultar(q.x, q.z, q.y).x + 0.25
					if prev != Vector3.INF:
						var t := q - prev
						var nrm := Vector3(-t.z, 0.0, t.x).normalized() * 0.18
						mv.append_array([prev - nrm, prev + nrm, q + nrm, prev - nrm, q + nrm, q - nrm])
						for k in 6:
							cols.append(col)
					prev = q
					s += 1.0
	if mv.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = mv
	arr[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.surface_set_material(0, mat)
	lineas = MeshInstance3D.new()
	lineas.mesh = m
	add_child(lineas)


## Caminos del piloto/tráfico por la ruta en la glorieta gi, los dos sentidos: metros con el coche (±0,9 m del centro del
## carril) fuera del asfalto y metros con el carril sobre la isla central. Línea "CAMINO" en el registro.
func _comprobar_caminos(gi: int, inf: Dictionary) -> void:
	var c: Vector3 = inf["c"]
	var hw: float = inf["hw"]
	for ri in Ajustes.rutas.size():
		var r: Ruta = Ajustes.rutas[ri]
		for ar in r.arcos_glorieta:
			if int(ar["g"]) != gi:
				continue
			for d in [1, -1]:
				var fuera := 0.0
				var isla := 0.0
				var s := maxf(float(ar["a"]) * r.paso - 60.0, 0.0)
				var s1 := minf(float(ar["b"]) * r.paso + 60.0, r.longitud())
				while s < s1:
					var q := r.punto_carril(s, d)
					var t := r.marcha_carril(s, d)
					var lado := Vector3(-t.z, 0.0, t.x).normalized() * 0.9
					var ok := true
					for qq in [q + lado, q - lado]:
						if Ajustes.superficie.consultar(qq.x, qq.z, q.y).y < 0.5:
							ok = false
					if not ok:
						fuera += 0.5
					var th := GlorietaTipo.angulo(c, q)
					if Vector2(q.x - c.x, q.z - c.z).length() < GlorietaTipo.r_eje(inf, th) - hw + 0.9:
						isla += 0.5
					s += 0.5
				print("CAMINO g%d r%d d%d fuera=%.1f isla=%.1f" % [gi, ri, d, fuera, isla])
