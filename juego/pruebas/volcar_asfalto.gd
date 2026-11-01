extends Node
## Solo verificación (no se sube): vuelca el asfalto que construye el juego (las mismas franjas que MapaStreaming,
## después de Cruces) para el comprobador de huecos. --zona=navacerrada --out=/ruta/base
func _ready() -> void:
	var zona: String = Ajustes.args.get("zona", "navacerrada")
	var base: String = Ajustes.args.get("out", "/tmp/asfalto")
	Ajustes.rutas.clear()
	Ajustes.cambiar_zona("")
	Ajustes.cambiar_zona(zona)
	Ajustes.cargar()
	var ms := MapaStreaming.new()
	var tri := PackedFloat32Array()
	var n_v := 0
	for v in Ajustes.vias:
		var pts: PackedVector3Array = v["pts"]
		if pts.size() < 2 or int(v["tunel"]) == 1:
			continue
		var anchos := PackedFloat32Array()
		anchos.resize(pts.size())
		anchos.fill(float(v["ancho"]))
		var vs := PackedVector3Array(); var ns := PackedVector3Array(); var ix := PackedInt32Array()
		ms._franja(pts, anchos, 0, pts.size() - 1, 0.0, 0.0, 0.04, vs, ns, ix)
		for k in ix:
			tri.append(vs[k].x); tri.append(vs[k].y); tri.append(vs[k].z)
		n_v += 1
	var n_p := 0
	for pc in Cruces.parches:
		var vs := PackedVector3Array(); var ns := PackedVector3Array(); var ix := PackedInt32Array()
		MapaStreaming.tri_parche(pc, vs, ns, ix)
		for k in ix:
			tri.append(vs[k].x); tri.append(vs[k].y); tri.append(vs[k].z)
		n_p += 1
	var rjs := []
	for rr in Ajustes.rutas:
		var r: Ruta = rr
		var i := 0
		while i < r.n - 1:
			if r.dibujar[i] == 0:
				i += 1
				continue
			var j := i
			while j < r.n - 1 and r.dibujar[j] == 1:
				j += 1
			var vs := PackedVector3Array(); var ns := PackedVector3Array(); var ix := PackedInt32Array()
			ms._franja(r.pts, r.ancho, i, j, 0.0, 0.0, 0.05, vs, ns, ix)
			for k in ix:
				tri.append(vs[k].x); tri.append(vs[k].y); tri.append(vs[k].z)
			i = j
		var xs := []; var ys := []; var zs := []
		for p in r.pts:
			xs.append(snappedf(p.x, 0.01)); ys.append(snappedf(p.y, 0.01)); zs.append(snappedf(p.z, 0.01))
		rjs.append({"x": xs, "y": ys, "z": zs, "ancho": Array(r.ancho), "dibujar": Array(r.dibujar), "puente": Array(r.puente), "tunel": Array(r.tunel), "nombre": r.nombre})
	var f := FileAccess.open(base + ".tri", FileAccess.WRITE)
	f.store_buffer(tri.to_byte_array())
	f.close()
	var vjs := []
	for v in Ajustes.vias:
		var xs := []; var ys := []; var zs := []
		for p in v["pts"]:
			xs.append(snappedf(p.x, 0.01)); ys.append(snappedf(p.y, 0.01)); zs.append(snappedf(p.z, 0.01))
		vjs.append({"x": xs, "y": ys, "z": zs, "ancho": v["ancho"], "tunel": v["tunel"], "puente": v["puente"], "nombre": v["nombre"]})
	var g := FileAccess.open(base + ".json", FileAccess.WRITE)
	g.store_string(JSON.stringify({"rutas": rjs, "vias_post": vjs}))
	g.close()
	print("VOLCADO ", zona, " vias=", n_v, " parches=", n_p, " tris=", tri.size() / 9)
	ms.free()
	get_tree().quit()
