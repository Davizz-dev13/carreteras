extends Node
## Solo verificación (no se sube): vuelca el asfalto que construye el mapa abierto (MaMundo.construir_tesela) en las
## teselas con más glorietas (más la de la N-320 y unas cuantas al azar) para el comprobador de huecos.
## --out=/ruta/base --n=40 --azar=20 --extra=x,z;x,z
func _ready() -> void:
	var base: String = Ajustes.args.get("out", "/tmp/madrid")
	var d := MaDatos.new()
	if not d.cargar("madrid"):
		print("SIN DATOS"); get_tree().quit(); return
	var m := MaMundo.new()
	add_child(m)
	m.preparar(d)
	m.con_orto = false
	var cuenta := {}
	for k in d.tramos.size():
		if int(d.tramos[k]["rot"]) == 1:
			var g := d.geometria(k)
			if g.size() > 0:
				var t := d.clave_tesela(g[0])
				cuenta[t] = int(cuenta.get(t, 0)) + 1
	var claves: Array = cuenta.keys()
	claves.sort_custom(func(x, y): return cuenta[x] > cuenta[y])
	var elegidas := []
	for t in claves.slice(0, int(Ajustes.args.get("n", "40"))):
		elegidas.append(t)
	var rng := RandomNumberGenerator.new()
	rng.seed = 13
	var resto := claves.slice(int(Ajustes.args.get("n", "40")))
	for i in int(Ajustes.args.get("azar", "20")):
		if resto.is_empty(): break
		elegidas.append(resto.pop_at(rng.randi_range(0, resto.size() - 1)))
	for e in str(Ajustes.args.get("extra", "")).split(";", false):
		var xz := e.split(",")
		var t2 := d.clave_tesela(Vector3(float(xz[0]), 0.0, float(xz[1])))
		if not elegidas.has(t2): elegidas.append(t2)
	var tri := PackedFloat32Array()
	var usados := {}
	var tes := []
	var t0 := Time.get_ticks_msec()
	for t in elegidas:
		var r: Dictionary = m.construir_tesela(t, 0)
		if not r.has("nodo"):
			continue
		var raiz: Node3D = r["nodo"]
		for ch in raiz.get_children():
			if ch is MeshInstance3D and ch != r.get("ter_mi"):
				var malla: Mesh = ch.mesh
				for s in malla.get_surface_count():
					var mat := malla.surface_get_material(s)
					if mat == m.mat_asfalto or mat == m.mat_asfalto_v:
						var arr := malla.surface_get_arrays(s)
						var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
						var ix: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
						for k in ix:
							tri.append(vs[k].x); tri.append(vs[k].y); tri.append(vs[k].z)
		var dd := d.leer_tesela(t)
		for pz in dd["piezas"]:
			usados[int(pz[0])] = true
		tes.append([t.x, t.y, cuenta.get(t, 0)])
		raiz.free()
	var tr_js := []
	for k in usados.keys():
		var tr: Dictionary = d.tramos[k]
		var g := d.geometria(k)
		var xs := []; var ys := []; var zs := []
		for p in g:
			xs.append(snappedf(p.x, 0.01)); ys.append(snappedf(p.y, 0.01)); zs.append(snappedf(p.z, 0.01))
		var bor := d.bordes(k)
		tr_js.append({"k": k, "x": xs, "y": ys, "z": zs, "ancho": float(tr["ancho"]), "rot": int(tr["rot"]), "enlace": int(tr["enlace"]),
				"tunel": int(tr["tunel"]), "puente": int(tr["puente"]), "c": int(tr["c"]), "a": int(tr["a"]), "b": int(tr["b"]),
				"s": int(tr["s"]), "nombre": d.rotulo(k),
				"bi": Array(bor[0]) if not bor.is_empty() else [], "bd": Array(bor[1]) if not bor.is_empty() else []})
	var f := FileAccess.open(base + ".tri", FileAccess.WRITE)
	f.store_buffer(tri.to_byte_array())
	f.close()
	var g2 := FileAccess.open(base + ".json", FileAccess.WRITE)
	g2.store_string(JSON.stringify({"tramos": tr_js, "teselas": tes, "tesela": d.tesela}))
	g2.close()
	print("VOLCADO madrid teselas=", tes.size(), " tramos=", tr_js.size(), " tris=", tri.size() / 9, " ms=", Time.get_ticks_msec() - t0)
	get_tree().quit()
