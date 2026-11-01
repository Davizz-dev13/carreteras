extends Node
## Solo verificación: glorietas de las zonas viejas de un solo sentido y antihorarias.
##   godot --headless --fixed-fps 60 res://pruebas/glorietas_sentido.tscn -- --zona=m406 --trafico=100 --segundos=600 --salida=/tmp/x.json
## 1) estático: cada anillo antihorario; cada arco de la ruta recorrido antihorario por su sentido; cada desvío del
##    sentido contrario gira antihorario por el anillo;  2) tráfico (cargado, sin jugador) en cada ruta que pasa por
##    glorietas durante `segundos`: cuenta los avances en sentido horario por cualquier anillo (debe ser 0), las
##    pasadas antihorarias y las paradas de ceda el paso.
var rings: Array = []   # [c, radio, hw]
var celdas := {}        # Vector2i (celda de 100 m) -> [índices de anillo]
var res := {}

func _ready() -> void:
	Ajustes.cargar()
	var a := Ajustes.args
	for g in Ajustes.glorietas:
		var c := Vector3.ZERO
		var xs: Array = g["x"]
		for i in xs.size():
			c += Vector3(float(g["x"][i]), float(g["y"][i]), float(g["z"][i]))
		c /= float(xs.size())
		var r := 0.0
		var area := 0.0
		for i in xs.size():
			var x0 := float(g["x"][i]); var z0 := float(g["z"][i])
			var x1 := float(g["x"][(i + 1) % xs.size()]); var z1 := float(g["z"][(i + 1) % xs.size()])
			r += Vector2(x0 - c.x, z0 - c.z).length()
			area += x0 * (-z1) - x1 * (-z0)
		rings.append([c, r / xs.size(), float(g["hw"])])
		var rad: float = r / xs.size() + float(g["hw"]) + 2.0
		for cx in range(floori((c.x - rad) / 100.0), floori((c.x + rad) / 100.0) + 1):
			for cz in range(floori((c.z - rad) / 100.0), floori((c.z + rad) / 100.0) + 1):
				var k := Vector2i(cx, cz)
				if not celdas.has(k): celdas[k] = []
				celdas[k].append(rings.size() - 1)
	res["zona"] = Ajustes.zona
	res["glorietas"] = rings.size()
	var est := []
	var rutas_con := []
	for ri in Ajustes.rutas.size():
		var ru: Ruta = Ajustes.rutas[ri]
		if not ("arcos_glorieta" in ru):
			# versión anterior (sin glorietas de un solo sentido): rutas que pasan por algún anillo
			for k in range(0, ru.n, 3):
				if _anillo_de(ru.pts[k]) >= 0:
					rutas_con.append(ri)
					break
			continue
		if not ru.arcos_glorieta.is_empty():
			rutas_con.append(ri)
		else:
			# misma regla que la versión anterior: también las rutas que solo rozan o cruzan un anillo
			for k in range(0, ru.n, 3):
				if _anillo_de(ru.pts[k]) >= 0:
					rutas_con.append(ri)
					break
		for ar in ru.arcos_glorieta:
			est.append({"ruta": ri, "glorieta": ar["g"], "km": ar["a"] * ru.paso / 1000.0, "sentido_ruta": ar["sentido"]})
		for dv in ru.desvios:
			var p: PackedVector3Array = dv["pts"]
			var ac: PackedFloat32Array = dv["acum"]
			var c: Vector3 = dv["c"]
			var neg := 0.0
			var pos := 0.0
			for k in range(1, p.size()):
				if ac[k] < float(dv["u_ent"]) or ac[k] > float(dv["u_sal"]):
					continue
				var d := wrapf(atan2(-(p[k].z - c.z), p[k].x - c.x) - atan2(-(p[k - 1].z - c.z), p[k - 1].x - c.x), -PI, PI)
				if d < 0.0: neg += d
				else: pos += d
			est.append({"ruta": ri, "desvio_glorieta": dv["g"], "sentido_desviado": dv["d"], "giro_antihorario_grados": rad_to_deg(pos),
				"giro_horario_grados": rad_to_deg(-neg), "L": dv["L"]})
	res["estatico"] = est
	res["rutas_con_glorieta"] = rutas_con
	var din := []
	for ri in rutas_con:
		din.append(await _trafico(ri, float(a.get("trafico", "100")) / 100.0, int(float(a.get("segundos", "600")) * 60.0)))
	res["trafico"] = din
	var f := FileAccess.open(a.get("salida", "user://glorietas_sentido.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, " "))
	f.close()
	print("GLORIETAS_SENTIDO ", JSON.stringify(res))
	get_tree().quit()


func _anillo_de(q: Vector3) -> int:
	for i in celdas.get(Vector2i(floori(q.x / 100.0), floori(q.z / 100.0)), []):
		var c: Vector3 = rings[i][0]
		if absf(Vector2(q.x - c.x, q.z - c.z).length() - float(rings[i][1])) < float(rings[i][2]) + 0.8 and absf(q.y - c.y) < 6.0:
			return i
	return -1


func _trafico(ri: int, factor: float, frames: int) -> Dictionary:
	var ru: Ruta = Ajustes.rutas[ri]
	# fantasma quieto junto a las glorietas de la ruta (centro de las que toca)
	var ss := []
	for k in range(0, ru.n, 2):
		if _anillo_de(ru.pts[k]) >= 0:
			ss.append(k * ru.paso)
	var s_jug: float = ss[ss.size() / 2]
	var tr := Trafico.new()
	tr.iniciar(ru, factor)
	add_child(tr)
	var prev := {}
	var acum := {}
	var horario := 0
	var horario_coches := {}
	var pasadas := 0
	var paradas_ceda := 0
	var ejemplos := []
	var ejemplos_ids := {}
	var contra := 0
	var contra_coches := {}
	for fr in frames:
		tr.actualizar(1.0 / 60.0, s_jug, 0.0, 0.0, 0)
		for c in tr.coches:
			var id: int = c["nodo"].get_instance_id()
			var q: Vector3 = c["nodo"].position
			var gi := _anillo_de(q)
			if gi >= 0 and prev.has(id) and int(prev[id][1]) == gi:
				var cc: Vector3 = rings[gi][0]
				var q0: Vector3 = prev[id][0]
				var d := wrapf(atan2(-(q.z - cc.z), q.x - cc.x) - atan2(-(q0.z - cc.z), q0.x - cc.x), -PI, PI)
				# contra el sentido del anillo, sobre su calzada (entre el borde interior y el exterior): la dirección de
				# marcha apunta claramente al revés que la tangente antihoraria (más de 120°). Las salidas que se
				# alejan del anillo hacia fuera no cuentan (ahí el ángulo alrededor del centro puede bajar sin ir al revés).
				var dq := Vector2(q.x - q0.x, q.z - q0.z)
				var rad := Vector2(q.x - cc.x, q.z - cc.z)
				var tccw := Vector2(rad.y, -rad.x).normalized()     # antihorario visto desde arriba (x este, -z norte)
				if absf(rad.length() - float(rings[gi][1])) < float(rings[gi][2]) and dq.length() > 0.01 and dq.normalized().dot(tccw) < -0.5:
					contra += 1
					contra_coches[str(id) + "_" + str(gi)] = true
				if d < -0.0005 and q.distance_to(q0) > 0.01:
					horario += 1
					horario_coches[str(id) + "_" + str(gi)] = true
					if ejemplos.size() < 8 and not ejemplos_ids.has(str(id) + "_" + str(gi)):
						ejemplos_ids[str(id) + "_" + str(gi)] = true
						var kd := -1
						if ru.has_method("desvio_en"): kd = ru.desvio_en(c["s"], c["dir"])
						ejemplos.append({"dir": c["dir"], "km": snappedf(float(c["s"]) / 1000.0, 0.001), "glorieta": gi, "desvio": kd,
							"d_anillo": snappedf(Vector2(q.x - cc.x, q.z - cc.z).length() - float(rings[gi][1]), 0.1)})
				acum[id] = float(acum.get(id, 0.0)) + d
				if float(acum[id]) > deg_to_rad(30.0) and not acum.has(str(id) + "p" + str(gi)):
					acum[str(id) + "p" + str(gi)] = true
					pasadas += 1
			elif gi < 0:
				acum[id] = 0.0
			if fr % 30 == 0 and float(c["v"]) < 0.3 and tr.has_method("_ceda") and tr.call("_ceda", c) < 1e3:
				paradas_ceda += 1
			prev[id] = [q, gi]
		if fr % 3600 == 0:
			await get_tree().process_frame
	tr.queue_free()
	return {"ruta": ri, "s_fantasma_km": s_jug / 1000.0, "sim_s": frames / 60.0, "avances_horarios": horario,
		"coches_horarios": horario_coches.size(), "pasadas_antihorarias_30grados": pasadas, "muestras_parado_cediendo": paradas_ceda, "ejemplos_horarios": ejemplos,
		"muestras_contra_sentido_en_anillo": contra, "coches_contra_sentido_en_anillo": contra_coches.size()}
