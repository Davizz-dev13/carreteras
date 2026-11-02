extends Node
## Solo verificación: quitamiedos en todas las carreteras de las zonas viejas. Construye todos los trozos de bionda de
## cada zona y mide: metros de valla, abatimientos, postes, ms por trozo (máx/medio), segmentos de choque y vallas
## metidas en el asfalto de alguna calzada (debe ser 0).
## godot --headless --path . res://pruebas/prueba_quitamiedos.tscn -- --zonas=navacerrada,a308,gr8101,m406
func _ready() -> void:
	var zonas: PackedStringArray = str(Ajustes.args.get("zonas", "navacerrada,a308,gr8101,m406")).split(",")
	for zona in zonas:
		Ajustes.args["zona"] = zona
		Ajustes.rutas.clear()
		Ajustes.cambiar_zona("")
		Ajustes.cambiar_zona(zona)
		var t0 := Time.get_ticks_msec()
		var j = load("res://escenas/juego.tscn").instantiate()
		add_child(j)
		while not j.cargado:
			await get_tree().process_frame
		var t_carga := Time.get_ticks_msec() - t0
		j.pausado = true
		var tp := Time.get_ticks_usec()
		var pzs := Quitamiedos.piezas(Ajustes.dir_datos(), Ajustes.rutas)
		var ms_piezas := (Time.get_ticks_usec() - tp) / 1000.0
		var sup: Superficie = Ajustes.superficie
		var na := 0
		var nv := 0
		var np := 0
		for pz in pzs:
			var rr: Dictionary = Quitamiedos._calcular(pz)
			if not rr.is_empty():
				na += rr["abat"].size(); nv += rr["vallas"].size(); np += rr["postes"].size()
		print("QM_LISTAS vallas=%d terminales=%d postes=%d" % [nv, na, np])
		var largo := 0.0
		var n_abat := 0
		var n_post := 0
		var n_vallas := 0
		var us_max := 0
		var tiempos := []
		var us_tot := 0
		var metidas := 0
		var en_malla := 0
		var largo_carretera := 0.0
		var lin := {}
		for pz in pzs:
			var tc := Time.get_ticks_usec()
			var nodo := Quitamiedos.construir(pz)
			var us := Time.get_ticks_usec() - tc
			us_max = maxi(us_max, us)
			tiempos.append(us)
			us_tot += us
			if not lin.has(pz["linea"]):
				lin[pz["linea"]] = true
			for ch in nodo.get_children():
				var mm: MultiMesh = (ch as MultiMeshInstance3D).multimesh
				if mm.mesh == Quitamiedos.malla_poste():
					n_post += mm.instance_count
					continue
				var es_abat := ch.get_index() == 1 or (ch.get_index() == 0 and false)
				for k in mm.instance_count:
					var tr := mm.get_instance_transform(k)
					var zv := tr.basis.z
					var lg := Vector2(zv.x, zv.z).length()
					# punto medio de la onda (cara hacia la calzada)
					var m := tr.origin + zv * 0.5 + tr.basis.x.normalized() * 0.23
					largo += lg
					n_vallas += 1
					if absf(zv.y) < 0.5 and _metida(sup, m):
						metidas += 1
					if absf(zv.y) < 0.5 and _en_malla(sup, m):
						en_malla += 1
			nodo.free()
		tiempos.sort()
		print("QM_EST ", Quitamiedos.est, " us p50=%d p99=%d top5=%s" % [tiempos[tiempos.size() / 2], tiempos[int(tiempos.size() * 0.99)], str(tiempos.slice(tiempos.size() - 5))])
		print("QM zona=%s carga=%d ms piezas=%d (%.0f ms) vallas=%d largo=%.1f km terminales=%d postes=%d us_max=%d us_medio=%d choque=%d metidas=%d en_malla_glorieta=%d" % [
				zona, t_carga, pzs.size(), ms_piezas, n_vallas, largo / 1000.0, na, n_post, us_max, us_tot / maxi(pzs.size(), 1),
				Quitamiedos.choque_vivo.pa.size(), metidas, en_malla])
		j.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	print("QM_FIN")
	get_tree().quit()


## ¿La onda está dentro del asfalto de alguna calzada (a más de 0,2 m del borde)?
func _metida(sup: Superficie, p: Vector3) -> bool:
	var lista = sup.celdas.get(Vector2i(floori(p.x / Superficie.CELDA), floori(p.z / Superficie.CELDA)))
	if lista == null:
		return false
	for k in lista:
		var q0 := sup.a[k]
		var q1 := sup.b[k]
		var abx := q1.x - q0.x
		var abz := q1.z - q0.z
		var l2 := abx * abx + abz * abz
		var u := 0.0
		if l2 > 1e-6:
			u = clampf(((p.x - q0.x) * abx + (p.z - q0.z) * abz) / l2, 0.0, 1.0)
		var d := Vector2(p.x - q0.x - abx * u, p.z - q0.z - abz * u).length()
		if d < sup.semiancho[k] - 0.2 and absf(q0.y + (q1.y - q0.y) * u - p.y) < 2.0:
			return true
	return false


## ¿La onda cae sobre la malla de una glorieta (anillo, brazos, abocinamientos: GlorietaMalla) a más de 0,2 m del borde?
## (el punto y sus 4 vecinos a 0,2 m dentro de algún triángulo)
func _en_malla(sup: Superficie, p: Vector3) -> bool:
	var lista = sup.celdas_t.get(Vector2i(floori(p.x / Superficie.CELDA), floori(p.z / Superficie.CELDA)))
	if lista == null:
		return false
	for o in [Vector2.ZERO, Vector2(0.2, 0), Vector2(-0.2, 0), Vector2(0, 0.2), Vector2(0, -0.2)]:
		var q: Vector2 = Vector2(p.x, p.z) + (o as Vector2)
		var dentro := false
		for k in lista:
			if absf(sup.ta[k].y - p.y) > 2.0:
				continue
			if Geometry2D.point_is_inside_triangle(q, Vector2(sup.ta[k].x, sup.ta[k].z), Vector2(sup.tb[k].x, sup.tb[k].z), Vector2(sup.tc[k].x, sup.tc[k].z)):
				dentro = true
				break
		if not dentro:
			return false
	return true
