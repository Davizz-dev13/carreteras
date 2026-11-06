## v6: coches del tráfico tras un choque y piloto automático que maniobra marcha atrás (sin ventana).
##   godot --headless res://pruebas/prueba_choques.tscn -- --zona=navacerrada --modo=npc --trafico=30
##   godot --headless res://pruebas/prueba_choques.tscn -- --zona=navacerrada --modo=piloto --trafico=0
##   godot --headless res://pruebas/prueba_choques.tscn -- --madrid=1 --modo=piloto|npc
## npc: choques provocados (coche contra coche suelto por detrás y de lado, jugador contra coche, coche contra la bionda)
##   a 30/60/90 km/h en varios puntos; mide cuántos vuelven a su carril en 20 s, desapariciones a < 150 m del jugador
##   (la cámara) y colas (coches parados > 60 s). piloto: el coche del jugador empieza encajado contra la bionda en
##   varios ángulos (también mirando al revés) o cruzado en la calzada; éxito = sigue por su carril sin recolocarlo (R).
extends Node

const DT := 1.0 / 60.0
var j
var madrid = false
var args = {}
var vistos = {}            # id -> [posición, es_suelto]
var desap_cerca = 0
var desap_total = 0
var parado = {}            # id -> s parado (coches normales)
var cola_max = 0.0
var jug_pose = {}


func _ready() -> void:
	call_deferred("_correr")


func _correr() -> void:
	args = Ajustes.args
	madrid = args.get("madrid", "0") == "1"
	j = load("res://escenas/madrid.tscn" if madrid else "res://escenas/juego.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	for i in 10:
		await get_tree().physics_frame
	if madrid:
		j.en_prueba = true
	else:
		j.pausado = true
	Ajustes.trafico = float(args.get("trafico", "30")) / 100.0
	var modo = args.get("modo", "npc")
	var h0 = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var n0 = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	print("PRUEBA_CHOQUES %s modo=%s trafico=%.0f %%" % ["Madrid" if madrid else Ajustes.zona, modo, Ajustes.trafico * 100.0])
	if madrid:
		if modo == "piloto": await _madrid_piloto()
		else: await _madrid_npc()
	else:
		if modo == "piloto": await _zona_piloto()
		else: await _zona_npc()
	for i in 3:
		await get_tree().process_frame      # que se liberen los queue_free
	print("MEMORIA nodos huérfanos %d → %d · nodos %d → %d · coches del tráfico %d" % [h0, Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		n0, Performance.get_monitor(Performance.OBJECT_NODE_COUNT), j.trafico.coches.size()])
	get_tree().quit()


func _sim(n: int) -> void:
	for i in n:
		j._simular(DT)
		_vigilar()
		if not jug_pose.is_empty():
			var c: Coche = j.coche
			c.position = jug_pose["p"]
			c.rumbo = jug_pose["r"]
			c.v = 0.0


## desapariciones y colas en todo el tráfico
func _vigilar() -> void:
	var tr = j.trafico
	var pj: Vector3 = j.coche.position
	var ahora = {}
	for c in tr.coches:
		var n: Node3D = c["nodo"]
		var id = n.get_instance_id()
		ahora[id] = true
		vistos[id] = n.position
		if not madrid and not c.get("suelto", false) and not c.get("fijo", false):
			if float(c["v"]) < 1.0:
				parado[id] = float(parado.get(id, 0.0)) + DT
				cola_max = maxf(cola_max, parado[id])
			else:
				parado[id] = 0.0
		elif madrid:
			if float(c["v"]) < 1.0:
				parado[id] = float(parado.get(id, 0.0)) + DT
				cola_max = maxf(cola_max, parado[id])
			else:
				parado[id] = 0.0
	for id in vistos.keys():
		if not ahora.has(id):
			desap_total += 1
			if (vistos[id] as Vector3).distance_to(pj) < 150.0:
				desap_cerca += 1
			vistos.erase(id)
			parado.erase(id)


func _existe(c: Dictionary) -> bool:
	var id = (c["nodo"] as Node3D).get_instance_id() if is_instance_valid(c["nodo"]) else -1
	for o in j.trafico.coches:
		if (o["nodo"] as Node3D).get_instance_id() == id:
			return true
	return false


# ======================================================================== zonas: tráfico
func _sitios(n: int) -> Array:
	var ruta: Ruta = j.ruta
	var lo = maxf(ruta.s_trafico_min + 300.0, 300.0)
	var hi = minf(ruta.s_trafico_max - 300.0, ruta.longitud() - 300.0)
	var out = []
	for i in n:
		var s = lerpf(lo, hi, (i + 0.5) / n)
		# lejos de las glorietas
		var k = 0
		while k < 40 and (ruta.desvio_en(s, 1) >= 0 or ruta.desvio_en(s, -1) >= 0 or _en_glorieta(s)):
			s += 25.0
			k += 1
		out.append(s)
	return out


func _en_glorieta(s: float) -> bool:
	for ar in j.ruta.arcos_glorieta:
		if s > float(ar["a"]) * j.ruta.paso - 80.0 and s < float(ar["b"]) * j.ruta.paso + 80.0:
			return true
	for dv in j.ruta.desvios:
		if s > float(dv["s_lo"]) - 80.0 and s < float(dv["s_hi"]) + 80.0:
			return true
	return false


func _soltar_quieto(t: Dictionary, giro: float) -> void:
	var b: Dictionary = j.colisiones._cuerpo_trafico(t)
	b["v"] = Vector2.ZERO
	var f: Vector2 = b["f"]
	b["f"] = f.rotated(giro)
	j.colisiones._soltar(t, b)
	t["v2"] = Vector2.ZERO
	t["f2"] = b["f"]
	(t["nodo"] as Node3D).basis = Basis.looking_at(Vector3(t["f2"].x, 0.0, t["f2"].y), Vector3.UP)


## bionda más cercana a s (punto de la cara y normal hacia la calzada) dentro de 400 m, o {}
func _bionda_cerca(s0: float) -> Dictionary:
	var ruta: Ruta = j.ruta
	var dd = -400.0
	while dd <= 400.0:
		Quitamiedos.asegurar_choque(ruta.punto(clampf(s0 + dd, 0.0, ruta.longitud())))   # vallas de alrededor (se calculan al acercarse)
		dd += 30.0
	var bi: Biondas = j.biondas
	if bi == null or bi.vacia():
		return {}
	var mejor = {}
	var md = 1e9
	var n_cerca = 0
	for k in bi.pa.size():
		var a: Vector2 = (bi.pa[k] + bi.pb[k]) * 0.5
		var pr = ruta.proyectar(Vector3(a.x, 0.0, a.y), s0, 400.0)
		if absf(pr.x - s0) > 400.0 or _en_glorieta(pr.x):
			continue
		var lim = ruta.valor(ruta.ancho, pr.x) * 0.5
		n_cerca += 1
		if absf(pr.y) < lim - 0.5 or absf(pr.y) > lim + 5.0 or (bi.pb[k] - bi.pa[k]).length() < 1.0:
			continue
		if absf(bi.py[k] - ruta.punto(pr.x).y) > 3.0:
			continue
		# la normal tiene que mirar hacia la calzada
		if (bi.pn[k] as Vector2).dot(Vector2(ruta.punto(pr.x).x - a.x, ruta.punto(pr.x).z - a.y)) <= 0.0:
			continue
		var d = absf(pr.x - s0)
		if d < md:
			md = d
			mejor = {"s": pr.x, "lat": pr.y, "p": a, "n": bi.pn[k]}
	if mejor.is_empty():
		print("  (sin bionda útil cerca de s=%.0f: %d segmentos a < 400 m de %d)" % [s0, n_cerca, bi.pa.size()])
	return mejor


func _zona_npc() -> void:
	var ruta: Ruta = j.ruta
	var tr = j.trafico
	var vels: Array = Array(String(args.get("vels", "30,60,90")).split(",")).map(func(x): return float(x))
	var tipos: Array = Array(String(args.get("tipos", "alcance,lateral,jugador,bionda")).split(","))
	var sitios = _sitios(int(args.get("sitios", "3")))
	var total = 0
	var en_20 = 0
	var averiados = 0
	var t_vuelta: Array = []
	var caso = 0
	for tipo in tipos:
		for v in vels:
			for si in sitios.size():
				var s0: float = sitios[si]
				caso += 1
				if args.has("solo_sitio") and int(args["solo_sitio"]) != si:
					continue
				var dir = 1 if caso % 2 == 0 else -1
				j.dir = dir
				j.piloto = false
				var invol: Array = []
				var s_c: float = s0
				if tipo == "bionda":
					var b = _bionda_cerca(s0)
					if b.is_empty():
						print("CASO %s %.0f s=%.0f: sin bionda cerca" % [tipo, v, s0])
						continue
					s_c = b["s"]
					dir = 1 if (b["lat"] > 0.0) else -1     # la bionda a la derecha de su sentido
					j.dir = dir
				# el jugador (la cámara) se queda quieto fuera de la calzada, 45 m antes
				j._saltar_a(s_c - dir * 45.0)
				var sj: float = s_c - dir * 45.0
				var lado = ruta.valor(ruta.ancho, sj) * 0.5 + 3.0
				var pj = ruta.punto(sj) + ruta.derecha(sj) * (lado * (1.0 if dir > 0 else -1.0))
				pj.y = Ajustes.superficie.consultar(pj.x, pj.z, pj.y).x
				j.coche.colocar(pj, ruta.marcha_carril(sj, dir))
				jug_pose = {"p": j.coche.position, "r": j.coche.rumbo}
				# limpiar alrededor
				for i in range(tr.coches.size() - 1, -1, -1):
					var c: Dictionary = tr.coches[i]
					if absf(float(c["s"]) - s_c) < 120.0:
						(c["nodo"] as Node3D).queue_free()
						tr.coches.remove_at(i)
				if tipo == "alcance" or tipo == "lateral":
					var B: Dictionary = tr.crear_prueba(s_c, dir, 0.0, true)
					_soltar_quieto(B, 0.0 if tipo == "alcance" else PI * 0.5)
					var A: Dictionary = tr.crear_prueba(s_c - dir * maxf(10.0, v / 3.6 * 1.2), dir, v / 3.6, true)
					invol = [A, B]
				elif tipo == "averiado":
					# un coche averiado (golpe muy fuerte) cruzado en el carril y 4 coches que vienen detrás
					var B: Dictionary = tr.crear_prueba(s_c, dir, 0.0, true)
					_soltar_quieto(B, 0.35)
					B["averiado"] = true
					B["estado"] = "averiado"
					B.erase("fijo")
					var detras = []
					for kk in 4:
						var F: Dictionary = tr.crear_prueba(s_c - dir * (70.0 + 35.0 * kk), dir, 18.0, false)
						F["f"] = 1.0
						detras.append(F)
					var t_av = 0.0
					var pasan = 0
					var idB = (B["nodo"] as Node3D).get_instance_id()
					vistos.clear()
					while t_av < 75.0:
						_sim(1)
						t_av += DT
					for F in detras:
						if _existe(F) and (float(F["s"]) - s_c) * dir > 8.0:
							pasan += 1
					var sigue = false
					for o in tr.coches:
						if (o["nodo"] as Node3D).get_instance_id() == idB:
							sigue = true
					print("CASO averiado s=%.0f dir=%d: %d/4 de los de detrás lo han rodeado en 75 s · el averiado %s · cola_max=%.1f s · desaparecen_<150m=%d" % [
						s_c, dir, pasan, "sigue ahí (obstáculo)" if sigue else "HA DESAPARECIDO", cola_max, desap_cerca])
					jug_pose = {}
					continue
				elif tipo == "jugador":
					jug_pose = {}
					j.coche.colocar(ruta.punto_carril(s_c - dir * 30.0, dir), ruta.marcha_carril(s_c - dir * 30.0, dir))
					j.colisiones.registro.clear()
					var N: Dictionary = tr.crear_prueba(s_c, dir, v * 0.4 / 3.6, true)
					invol = [N]
				else:
					var N: Dictionary = tr.crear_prueba(s_c - dir * 14.0, dir, v / 3.6, true)
					var b2: Dictionary = j.colisiones._cuerpo_trafico(N)
					# derrapa hacia la valla (a su derecha) con 25°
					b2["v"] = (b2["f"] as Vector2).rotated(0.44) * (v / 3.6)
					b2["f"] = (b2["f"] as Vector2).rotated(0.30)
					j.colisiones._soltar(N, b2)
					N["v2"] = b2["v"]
					N["f2"] = b2["f"]
					invol = [N]
				vistos.clear()      # lo que ha quitado la propia prueba al preparar el caso no cuenta como desaparición
				var info = []
				for c in invol:
					info.append({"c": c, "t0": -1.0, "tv": -1.0, "id": (c["nodo"] as Node3D).get_instance_id()})
				var t = 0.0
				var lim_t = float(args.get("t_caso", "45"))
				while t < lim_t:
					if tipo == "jugador" and j.colisiones.registro.is_empty() and t < 8.0:
						j.coche.v = v / 3.6
					elif tipo == "jugador" and not j.piloto:
						j.piloto = true      # tras el golpe el piloto sigue (y se recoloca si hace falta)
					_sim(1)
					t += DT
					if args.get("traza", "0") == "1" and int(t * 60.0) % 30 == 0:
						var lin = "  t=%.1f" % t
						for e in info:
							var c: Dictionary = e["c"]
							if not _existe(c):
								lin += " | (no existe)"
								continue
							var m = c.get("man")
							var nd: Node3D = c["nodo"]
							var fo: Vector3 = -nd.basis.z
							var tt: Vector3 = j.ruta.marcha_carril(c["s"], c["dir"])
							lin += " | %s s=%.1f lat=%.2f carril=%.2f e=%.0f° v=%.1f vm=%.1f marcha=%s cambios=%s" % [c.get("estado", "normal") if c.get("suelto", false) else "normal",
								float(c["s"]), j.ruta.proyectar(nd.position, c["s"]).y, j.ruta.lateral_carril(c["s"], c["dir"]),
								rad_to_deg(_ang(Vector2(fo.x, fo.z).normalized(), Vector2(tt.x, tt.z).normalized())), float(c["v"]), float(c.get("v_man", 0.0)),
								str(m.marcha) if m != null else "-", str(m.cambios) if m != null else "-"]
							if m != null:
								var fi = j.trafico.ficha_trafico
								var cc = c
								var bl = func(q, q0): return j.colisiones._ocupado(q, q0, cc, float(cc["s"]), m.forzar)
								lin += " lib=%.2f/%.2f" % [Maniobra.libre(c["p2"], c["f2"], 1, 0.0, fi.largo, fi.ancho, fi.batalla, bl), Maniobra.libre(c["p2"], c["f2"], -1, 0.0, fi.largo, fi.ancho, fi.batalla, bl)]
						lin += " | jug s=%.1f lat=%.2f v=%.1f piloto=%s recol=%s" % [j.s_coche, j.lat_coche, j.coche.v, str(j.piloto), str(j.get("recol") != null)]
						print(lin)
					var todos = true
					for e in info:
						var c: Dictionary = e["c"]
						if not _existe(c):
							continue
						if c.get("suelto", false):
							if float(e["t0"]) < 0.0:
								e["t0"] = t
								c.erase("fijo")
								c["f"] = 1.0
								c["v0"] = tr.vel_deseada(c["s"], c["dir"], 1.0)
							todos = false
						elif float(e["t0"]) >= 0.0 and float(e["tv"]) < 0.0:
							e["tv"] = t
						elif float(e["t0"]) < 0.0:
							todos = false
					if todos and t > 3.0:
						break
				_sim(60 * 5)       # 5 s más para ver que siguen
				var txt = ""
				for e in info:
					var c: Dictionary = e["c"]
					if float(e["t0"]) < 0.0:
						txt += " [sin golpe]"
						continue
					total += 1
					var av: bool = c.get("averiado", false) and _existe(c) and c.get("suelto", false)
					var dt_v = float(e["tv"]) - float(e["t0"]) if float(e["tv"]) >= 0.0 else -1.0
					if av:
						averiados += 1
					if dt_v >= 0.0:
						t_vuelta.append(dt_v)
						if dt_v <= 20.0:
							en_20 += 1
					var est = "averiado" if av else ("vuelve en %.1f s" % dt_v if dt_v >= 0.0 else ("DESAPARECE" if not _existe(c) else "sigue suelto (%s)" % c.get("estado", "-")))
					var mov = ""
					if _existe(c) and not c.get("suelto", false):
						mov = " v=%.0f km/h lat_err=%.2f" % [float(c["v"]) * 3.6, absf(j.ruta.proyectar((c["nodo"] as Node3D).position, c["s"]).y - j.ruta.lateral_carril(c["s"], c["dir"]))]
					txt += " [%s%s]" % [est, mov]
				print("CASO %s %.0f km/h s=%.0f dir=%d:%s" % [tipo, v, s_c, dir, txt])
				jug_pose = {}
	t_vuelta.sort()
	var med: float = t_vuelta[t_vuelta.size() / 2] if not t_vuelta.is_empty() else -1.0
	var mx: float = t_vuelta[t_vuelta.size() - 1] if not t_vuelta.is_empty() else -1.0
	var nav = total - averiados
	print("RESUMEN_NPC coches_golpeados=%d en_carril_20s=%d (%.0f %% de todos, %.0f %% de los no averiados) averiados=%d vuelta_mediana=%.1f s max=%.1f s desaparecen_<150m=%d desaparecen_total=%d cola_max=%.1f s reincorporados=%s rodeos=%s" % [
		total, en_20, 100.0 * en_20 / maxf(total, 1), 100.0 * en_20 / maxf(nav, 1), averiados, med, mx, desap_cerca, desap_total, cola_max,
		str(tr.get("reincorporados")), str(tr.get("rodeos"))])


# ======================================================================== zonas: piloto
func _zona_piloto() -> void:
	var ruta: Ruta = j.ruta
	var tr = j.trafico
	var angs: Array = Array(String(args.get("angulos", "20,45,70,90,120,150,180")).split(",")).map(func(x): return float(x))
	var sitios = _sitios(int(args.get("sitios", "6")))
	var ok = 0
	var total = 0
	var tiempos: Array = []
	for s0 in sitios:
		var b = _bionda_cerca(s0)
		var casos = []
		if not b.is_empty():
			for a in angs:
				casos.append(["bionda", a])
		casos.append(["averiado", 0.0])
		casos.append(["reves", 180.0])
		casos.append(["cruzado", 90.0])
		for cs in casos:
			var tipo: String = cs[0]
			var ang: float = deg_to_rad(cs[1])
			var s_c: float = b["s"] if tipo == "bionda" else s0
			var dir: int = (1 if b.get("lat", 1.0) > 0.0 else -1) if tipo == "bionda" else 1
			j.dir = dir
			j._saltar_a(s_c)
			for i in range(tr.coches.size() - 1, -1, -1):
				var c: Dictionary = tr.coches[i]
				if absf(float(c["s"]) - s_c) < 80.0:
					(c["nodo"] as Node3D).queue_free()
					tr.coches.remove_at(i)
			if tipo == "averiado":
				# el piloto viene a 60 km/h por su carril y hay un coche averiado cruzado en él 120 m más adelante
				j._saltar_a(s_c - 120.0)
				var W: Dictionary = tr.crear_prueba(s_c, 1, 0.0, true)
				_soltar_quieto(W, 0.35)
				W["averiado"] = true
				W["estado"] = "averiado"
				W.erase("fijo")
				j.piloto = true
				Ajustes.velocidad = 60.0
				j.coche.v = 60.0 / 3.6
				j.terminado = false
				j.s_fin = ruta.longitud()
				var ta = 0.0
				var paso = false
				while ta < 60.0:
					_sim(1)
					ta += DT
					if j.s_coche > s_c + 20.0:
						paso = true
						break
				total += 1
				if paso:
					ok += 1
					tiempos.append(ta)
				print("PILOTO averiado delante s=%.0f: %s en %.1f s" % [s_c, "LO RODEA" if paso else "SE QUEDA DETRÁS", ta])
				continue
			var t3 = ruta.marcha_carril(s_c, dir)
			var t2 = Vector2(t3.x, t3.z).normalized()
			var f2: Vector2
			var p2: Vector2
			if tipo == "bionda":
				# hacia la valla (a la derecha de su sentido): girado ang hacia ella y pegado a ella
				f2 = t2.rotated(ang) if ang < PI - 0.01 else -t2
				var n: Vector2 = b["n"]
				p2 = (b["p"] as Vector2) + n * 3.0
				var fi = j.coche.ficha
				for it in 200:
					var a2 = f2 * fi.largo * 0.5
					var r2 = _der(f2) * fi.ancho * 0.5
					var esq = [p2 + a2 + r2, p2 + a2 - r2, p2 - a2 + r2, p2 - a2 - r2]
					var hay = false
					for e in esq:
						if (e - (b["p"] as Vector2)).dot(n) < 0.03:
							hay = true
					if hay:
						p2 += n * 0.03
						break
					p2 -= n * 0.03
			elif tipo == "reves":
				f2 = -t2
				var cp = ruta.punto_carril(s_c, dir)
				p2 = Vector2(cp.x, cp.z)
			else:
				f2 = t2.rotated(ang)
				var cp = ruta.punto(s_c)
				p2 = Vector2(cp.x, cp.z)
			var y = Ajustes.superficie.consultar(p2.x, p2.y, ruta.punto(s_c).y).x
			j.coche.colocar(Vector3(p2.x, y, p2.y), Vector3(f2.x, 0.0, f2.y))
			j.s_coche = s_c
			j.piloto = true
			j.coche.v = 0.0
			j.terminado = false
			j.s_fin = ruta.longitud() if dir > 0 else 0.0
			var fallidas0 = j.get("recol_fallidas")
			var s_ini: float = s_c
			var t = 0.0
			var t_ok = -1.0
			var hecho = false
			while t < 60.0:
				_sim(1)
				t += DT
				var fw: Vector3 = j.coche.adelante()
				var tt = ruta.marcha_carril(j.s_coche, dir)
				var e = absf(_ang(Vector2(fw.x, fw.z).normalized(), Vector2(tt.x, tt.z).normalized()))
				var lat_err = absf(j.lat_coche - ruta.lateral_carril(j.s_coche, dir))
				var avance = (j.s_coche - s_ini) * dir
				if e < 0.26 and lat_err < 1.2 and avance > 40.0 and j.coche.v > 3.0:
					t_ok = t
					hecho = true
					break
			var reset = fallidas0 != null and int(j.get("recol_fallidas")) > int(fallidas0)
			total += 1
			if hecho and not reset:
				ok += 1
				tiempos.append(t_ok)
			print("PILOTO %s %3.0f° s=%.0f dir=%d: %s en %.1f s (maniobras=%s cambios=%s)" % [tipo, cs[1], s_c, dir,
				"OK" if hecho and not reset else ("RESET(R)" if reset else "FALLO"), t, str(j.get("recolocaciones")),
				str(j.recol.cambios) if j.get("recol") != null else "-"])
	tiempos.sort()
	print("RESUMEN_PILOTO ok=%d/%d (%.0f %%) tiempo_mediano=%.1f s max=%.1f s fallidas_R=%s" % [ok, total, 100.0 * ok / maxf(total, 1),
		tiempos[tiempos.size() / 2] if not tiempos.is_empty() else -1.0, tiempos[tiempos.size() - 1] if not tiempos.is_empty() else -1.0, str(j.get("recol_fallidas"))])


# ======================================================================== Madrid
func _madrid_piloto() -> void:
	var angs: Array = Array(String(args.get("angulos", "45,90,135,180")).split(",")).map(func(x): return float(x))
	var n = int(args.get("sitios", "6"))
	var ok = 0
	var total = 0
	var tiempos: Array = []
	j.piloto = true
	for si in n:
		for a in angs:
			for borde in [false, true]:
				_sim(60 * 12)          # el piloto circula un rato: otro sitio
				if j.camino.is_empty():
					continue
				var pt: Array = j._punto_camino(0.0)
				var t3: Vector3 = pt[1]
				var t2 = Vector2(t3.x, t3.z).normalized()
				var k: int = pt[2] if pt[2] >= 0 else j.camino[0][0]
				var der = _der(t2)
				var lado = float(j.red.carril_derecho(k, 0))
				if borde:
					lado = float(j.datos.tramos[k]["ancho"]) * 0.5 - 1.0
				var p0 = Vector2((pt[0] as Vector3).x, (pt[0] as Vector3).z) + der * lado
				var f2 = t2.rotated(deg_to_rad(a)) if a < 179.0 else -t2
				j.coche.colocar(Vector3(p0.x, (pt[0] as Vector3).y + 0.3, p0.y), Vector3(f2.x, 0.0, f2.y))
				var re0: int = j.reenganches
				var t = 0.0
				var hecho = false
				while t < 60.0:
					_sim(1)
					t += DT
					if j.camino.is_empty():
						continue
					var q: Array = j._punto_camino(0.0)
					var tq: Vector3 = q[1]
					var fw: Vector3 = j.coche.adelante()
					var e = absf(_ang(Vector2(fw.x, fw.z).normalized(), Vector2(tq.x, tq.z).normalized()))
					var kq: int = q[2] if q[2] >= 0 else j.camino[0][0]
					if e < 0.26 and absf(j.lat_camino - float(j.red.carril_derecho(kq, 0))) < 1.5 and j.coche.v > 3.0 and t > 2.0:
						hecho = true
						break
				var tele: bool = j.reenganches > re0
				total += 1
				if hecho and not tele:
					ok += 1
					tiempos.append(t)
				print("PILOTO_MADRID %3.0f° %s: %s en %.1f s" % [a, "borde" if borde else "carril", "OK" if hecho and not tele else ("TELETRANSPORTE" if tele else "FALLO"), t])
	tiempos.sort()
	print("RESUMEN_PILOTO_MADRID ok=%d/%d (%.0f %%) tiempo_mediano=%.1f s teletransportes=%d" % [ok, total, 100.0 * ok / maxf(total, 1),
		tiempos[tiempos.size() / 2] if not tiempos.is_empty() else -1.0, j.reenganches])


func _madrid_npc() -> void:
	var vels: Array = Array(String(args.get("vels", "30,60,90")).split(",")).map(func(x): return float(x))
	var n = int(args.get("sitios", "4"))
	var total = 0
	var siguen = 0
	j.piloto = true
	for v in vels:
		for si in n:
			_sim(60 * 15)
			# un coche del tráfico delante, en el mismo paso que el jugador
			var obj = {}
			for c in j.trafico.coches:
				var dd = (c["nodo"] as Node3D).position.distance_to(j.coche.position)
				if dd > 60.0 and dd < 400.0 and float(c["d"]) > 35.0 and float(c["v"]) > 3.0:
					obj = c
					break
			if obj.is_empty():
				continue
			var k: int = obj["k"]
			var sd: int = obj["sd"]
			var d = maxf(float(obj["d"]) - 30.0, 0.0)
			j._colocar_en(k, sd, d)
			j.piloto = false
			var ch0: int = j.choques
			var t = 0.0
			var v_obj0 = float(obj["v"])
			while t < 10.0 and j.choques == ch0:
				j.coche.v = v_obj0 + v / 3.6      # se le echa encima a v km/h más que él
				_sim(1)
				t += DT
			if j.choques == ch0:
				print("MADRID_NPC %.0f km/h: sin golpe (coches=%d)" % [v, j.trafico.coches.size()])
				j.piloto = true
				continue
			j.piloto = true
			total += 1
			var t2 = 0.0
			var movio = false
			while t2 < 20.0:
				_sim(1)
				t2 += DT
				if _existe(obj) and float(obj["v"]) > 2.0 and (obj["nodo"] as Node3D).position.distance_to(j.coche.position) > 6.0:
					movio = true
					break
			if movio: siguen += 1
			print("MADRID_NPC %.0f km/h: %s en %.1f s" % [v, "sigue" if movio else ("DESAPARECE" if not _existe(obj) else "PARADO"), t2])
	var pmax = ""
	for c in j.trafico.coches:
		var id = (c["nodo"] as Node3D).get_instance_id()
		if float(parado.get(id, 0.0)) > 60.0:
			pmax += " [parado %.0f s a %.0f m del jugador, d=%.0f de %.0f m, sig=%s]" % [parado[id], (c["nodo"] as Node3D).position.distance_to(j.coche.position), float(c["d"]), j.red.longitud(c["k"]), str(c["sig"])]
	print("PARADOS_MADRID" + pmax)
	print("RESUMEN_NPC_MADRID golpeados=%d siguen_20s=%d desaparecen_<150m=%d cola_max=%.1f s" % [total, siguen, desap_cerca, cola_max])


static func _der(f: Vector2) -> Vector2:
	return Vector2(-f.y, f.x)


static func _ang(f: Vector2, d: Vector2) -> float:
	return atan2(d.dot(_der(f)), d.dot(f))
