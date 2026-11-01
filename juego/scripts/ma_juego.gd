## Mapa abierto de una región entera (Comunidad de Madrid): conducción libre por toda la red interurbana, sin
## pantallas de carga (teselas de 2 km leídas del disco en hilos, ver ma_mundo.gd). Solo en la versión de escritorio.
## Teclas: W/S/A/D o flechas · Espacio freno de mano · P piloto automático · Q/E en el próximo cruce: izquierda/derecha
## (otra vez = seguir recto) · +/- velocidad del piloto · C cámara · R volver a la carretera · M mapa grande y GPS (ma_mapa.gd)
## · Z/X zoom del minimapa · F3 datos · Esc menú.
extends Node3D

var datos := MaDatos.new()
var mundo := MaMundo.new()
var red: MaRed
var trafico := MaTrafico.new()
var coche: Coche
var cam := Camera3D.new()
var piloto := true
var cargado := false
var tiempo := 0.0
var choques := 0
var toques_bionda := 0           # pasos de física tocando una bionda (pruebas)
var reenganches := 0             # veces que el piloto se ha recolocado en su camino (pruebas)
var traza_cruces := false        # --traza_cruces=1: escribe cada decisión del piloto en un cruce (pruebas)

# piloto automático: camino por delante [[tramo, sentido], ...]; d = metros recorridos del primero
var camino: Array = []
var d_camino := 0.0
var lat_camino := 0.0
var preferencia := 0          # próximo cruce: -1 izquierda, 0 seguir, +1 derecha
var pref_en: Array = []       # paso [tramo, sentido] a cuyo final se aplicó la preferencia ([] = aún no)
var t_perdido := 0.0          # s del piloto fuera del camino o parado sin motivo (para reengancharlo)
var tramo_actual := -1

var hud := CanvasLayer.new()
var l_vel := Label.new()
var l_via := Label.new()
var l_info := Label.new()
var l_cruce := Label.new()
var l_datos := Label.new()
var ver_datos := false
var _choque_t := 0.0
var en_prueba := false
var gps: MaGps                  # ruta al destino elegido en el mapa (ma_gps.gd)
var mapa: MaMapa                # minimapa, mapa grande con M y GPS (ma_mapa.gd)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cargando := Label.new()
	cargando.text = "Cargando la Comunidad de Madrid…"
	cargando.add_theme_font_size_override("font_size", 26)
	cargando.position = Vector2(60, 60)
	hud.add_child(cargando)
	add_child(hud)
	await get_tree().process_frame
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	_leer_args()
	traza_cruces = Ajustes.args.get("traza_cruces", "0") == "1"
	if not datos.cargar(str(Ajustes.args.get("region", "madrid"))):
		cargando.text = "Faltan los datos del mapa abierto (datos/madrid)."
		return
	red = MaRed.new(datos)
	add_child(mundo)
	mundo.preparar(datos)
	coche = Coche.new()
	add_child(coche)
	piloto = Ajustes.piloto
	var salida := _salida(str(Ajustes.args.get("inicio", "A-6")))
	_colocar_en(salida[0], salida[1], salida[2])
	mundo.actualizar(coche.position, true)
	trafico.iniciar(red, mundo, Ajustes.trafico)
	add_child(trafico)
	cam.near = 0.2
	cam.far = 60000.0
	cam.fov = 70.0
	add_child(cam)
	cam.current = true
	cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cargando.queue_free()
	_crear_hud()
	gps = MaGps.new(datos, red)
	mapa = MaMapa.new()
	add_child(mapa)
	mapa.iniciar(self)
	print("Mapa abierto: %d tramos, %d nodos, listo en %d ms (teselas iniciales %d)" % [datos.tramos.size(), datos.nodos.size(), Time.get_ticks_msec() - t0, mundo.listas()])
	cargado = true
	if Ajustes.args.has("captura"):
		_captura()


func _leer_args() -> void:
	var a := Ajustes.args
	if a.has("vel"): Ajustes.velocidad = float(a["vel"])
	if a.has("trafico"): Ajustes.trafico = float(a["trafico"]) / 100.0
	if a.has("piloto"): Ajustes.piloto = a["piloto"] == "1"
	if a.has("curvas"): Ajustes.adaptar_curvas = a["curvas"] == "1"
	if a.has("limites"): Ajustes.piloto_limites = a["limites"] == "1"


## Punto de salida: el tramo con esa referencia más cercano a (--x, --z) (por defecto, la A-6 a la salida de Madrid)
func _salida(ref: String) -> Array:
	var objetivo := Vector3(float(Ajustes.args.get("x", "-9000")), 0.0, float(Ajustes.args.get("z", "-2000")))
	var mejor := -1
	var dmin := 1e12
	for k in datos.tramos.size():
		var t: Dictionary = datos.tramos[k]
		if not (t["ref"] as String).split(";").has(ref) or int(t["tunel"]) == 1 or int(t["enlace"]) == 1:
			continue
		var p := datos.geometria(k)
		var dd := Vector2(p[0].x, p[0].z).distance_to(Vector2(objetivo.x, objetivo.z))
		if dd < dmin:
			dmin = dd
			mejor = k
	if mejor < 0:
		mejor = 0
	var sv := int(datos.tramos[mejor]["s"])
	return [mejor, sv if sv != 0 else 1, minf(20.0, red.longitud(mejor) * 0.5)]


func _colocar_en(k: int, sd: int, d: float) -> void:
	camino = [[k, sd]]
	d_camino = d
	_alargar_camino()
	var pt: Array = red.punto(k, sd, d)
	var t: Vector3 = pt[1]
	var der := Vector3(-t.z, 0.0, t.x).normalized()
	var p: Vector3 = (pt[0] as Vector3) + der * red.carril_derecho(k, 0)
	coche.colocar(p + Vector3.UP * 0.3, t)
	tramo_actual = k


# ------------------------------------------------------------------ simulación
func _physics_process(dt: float) -> void:
	if not cargado or en_prueba or (mapa != null and mapa.abierto):
		return
	_simular(dt)


func _simular(dt: float) -> void:
	tiempo += dt
	_seguir_camino()
	_mandos(dt)
	coche.paso_fisica(dt)
	if Biondas.resolver(coche, mundo.biondas_cerca(coche.position)) > 0.0:   # quitamiedos (biondas.gd)
		toques_bionda += 1
	var c := Ajustes.superficie.consultar(coche.position.x, coche.position.z, coche.position.y)
	if c.z >= 0:
		tramo_actual = int(c.z)
	var paso_j: Array = camino[0] if not camino.is_empty() else []
	trafico.factor = Ajustes.trafico
	trafico.actualizar(dt, coche.position, paso_j, d_camino, absf(coche.v))
	_choques(dt)


## Proyecta el coche sobre el camino: avanza al siguiente tramo al pasar el final y alarga el camino por delante
func _seguir_camino() -> void:
	if camino.is_empty():
		_reengancharse()
		if camino.is_empty():
			return
	var k: int = camino[0][0]
	var sd: int = camino[0][1]
	var pr := _proyectar(k, sd, coche.position, d_camino)
	d_camino = pr.x
	lat_camino = pr.y
	if piloto:
		# el piloto no suelta el camino: si se ha abierto (rampa o glorieta cerrada) vuelve a él; si tras 4 s sigue
		# lejos o parado, se le recoloca en el carril (como R). Antes se borraba el camino y, fuera del asfalto, no
		# encontraba vía y se quedaba parado para siempre.
		var perdido := absf(lat_camino) > 8.0 or (absf(coche.v) < 0.5 and coche.freno < 0.05)
		t_perdido = t_perdido + 1.0 / 60.0 if perdido else 0.0
		if t_perdido > 4.0 or absf(lat_camino) > 40.0:
			t_perdido = 0.0
			reenganches += 1
			if traza_cruces:
				print("REENGANCHE t=%.0f %s lat=%.1f v=%.1f km/h pos=%.0f,%.0f" % [tiempo, datos.rotulo(k), lat_camino, coche.v * 3.6, coche.position.x, coche.position.z])
			_colocar_en(k, sd, clampf(d_camino, 0.0, red.longitud(k)))
			return
	elif absf(lat_camino) > 25.0:
		# se ha salido del camino (conducción manual por otra vía): volver a calcularlo desde donde esté
		camino.clear()
		_reengancharse()
		return
	while camino.size() > 1 and d_camino >= red.longitud(camino[0][0]) - 0.05:
		d_camino -= red.longitud(camino[0][0])
		camino.pop_front()
		var p2 := _proyectar(camino[0][0], camino[0][1], coche.position, d_camino)
		d_camino = p2.x
		lat_camino = p2.y
		if not pref_en.is_empty() and camino.size() > 0 and _pasado(pref_en):
			preferencia = 0     # la preferencia se gasta en el cruce donde se aplicó (ver _alargar_camino)
			pref_en = []
	# giro muy cerrado al final del tramo (entrada o salida de glorieta): el coche gira antes de pasar el final y su
	# proyección se quedaba a unos centímetros de él para siempre; el piloto seguía apuntando a un punto fijo y daba
	# vueltas a su alrededor fuera del asfalto. Si ya está más cerca del tramo siguiente (y pasado su comienzo), sigue.
	if camino.size() > 1 and d_camino >= red.longitud(camino[0][0]) - 4.0:
		var p1 := _proyectar(camino[1][0], camino[1][1], coche.position, 0.0)
		if p1.x > 0.2 and absf(p1.y) < absf(lat_camino):
			camino.pop_front()
			d_camino = p1.x
			lat_camino = p1.y
			if not pref_en.is_empty() and _pasado(pref_en):
				preferencia = 0
				pref_en = []
	_alargar_camino()


## ¿Ya no está el paso p en el camino por delante? (se ha pasado el cruce al final de p)
func _pasado(p: Array) -> bool:
	for e in camino:
		if e[0] == p[0] and e[1] == p[1]:
			return false
	return true


func _reengancharse() -> void:
	var c := Ajustes.superficie.consultar(coche.position.x, coche.position.z, coche.position.y)
	if c.z < 0:
		return
	var k := int(c.z)
	var t: Dictionary = datos.tramos[k]
	var pr1 := _proyectar(k, 1, coche.position, -1.0)
	var tg: Vector3 = red.punto(k, 1, pr1.x)[1]
	var sd := 1 if tg.dot(coche.adelante()) >= 0.0 else -1
	if int(t["s"]) != 0:
		sd = int(t["s"])
	camino = [[k, sd]]
	d_camino = _proyectar(k, sd, coche.position, -1.0).x
	_alargar_camino()


func _alargar_camino() -> void:
	var total := red.longitud(camino[0][0]) - d_camino
	var i := 1
	while i < camino.size():
		total += red.longitud(camino[i][0])
		i += 1
	while total < 600.0 and camino.size() < 40:
		var u: Array = camino[camino.size() - 1]
		var op := red.salidas(u[0], u[1])
		var a_glorieta := false
		if not red.es_glorieta(u[0]):
			for o in op:
				if red.es_glorieta(o[0]):
					a_glorieta = true
		# Q/E: solo en el próximo cruce de verdad (bifurcación o glorieta) y una sola vez: antes se volvía a aplicar
		# en cada cruce que se añadía al camino hasta pasar el primer tramo, y el piloto se iba por varias salidas
		var pref := 0
		if pref_en.is_empty() and preferencia != 0 and (op.size() >= 2 or a_glorieta):
			pref = preferencia
			pref_en = [u[0], u[1]]
		var nuevos: Array = []
		if gps != null and pref == 0 and gps.activo():
			var e0: Array = gps.siguiente(u[0], u[1])   # ruta del GPS (destino elegido en el mapa, M)
			if not e0.is_empty():
				nuevos = [e0]
		if nuevos.is_empty() and a_glorieta:
			nuevos = red.glorieta(u[0], u[1], pref)     # rodearla en su sentido hasta la salida
		if nuevos.is_empty():
			var e: Array = red.elegir(u[0], u[1], pref)
			if not e.is_empty():
				nuevos = [e]
		if nuevos.is_empty():
			break
		if traza_cruces and (op.size() >= 2 or a_glorieta):
			var alts: Array = []
			for o in op:
				alts.append("%s%s(%d°)" % [datos.rotulo(o[0]), "·enl" if int(datos.tramos[o[0]]["enlace"]) == 1 else "", roundi(rad_to_deg(o[2]))])
			var fin: Array = nuevos[nuevos.size() - 1]
			print("CRUCE t=%.0f %s%s → %s%s%s [%d pasos] pref=%d · opciones %s" % [tiempo, datos.rotulo(u[0]), "·enl" if int(datos.tramos[u[0]]["enlace"]) == 1 else "",
					datos.rotulo(fin[0]), "·enl" if int(datos.tramos[fin[0]]["enlace"]) == 1 else "", " (glorieta)" if a_glorieta else "", nuevos.size(), pref, ", ".join(alts)])
		for e in nuevos:
			camino.append([e[0], e[1]])
			total += red.longitud(e[0])


## Recalcular el camino por delante del tramo actual (al cambiar la preferencia de cruce)
func _replanificar() -> void:
	if camino.is_empty():
		return
	camino = [camino[0]]
	pref_en = []
	_alargar_camino()


## (distancia recorrida en el paso, desvío lateral + derecha) del punto p respecto al paso [k, sd]
func _proyectar(k: int, sd: int, p: Vector3, d0: float) -> Vector2:
	var pts := datos.geometria(k)
	var s := red.largos(k)
	var L := s[s.size() - 1]
	var n := pts.size()
	var i0 := 0
	var i1 := n - 2
	if d0 >= 0.0:
		var u0 := d0 if sd > 0 else L - d0
		var c := clampi(s.bsearch(u0, true) - 1, 0, n - 2)
		i0 = maxi(c - 25, 0)
		i1 = mini(c + 25, n - 2)
	var mejor := 1e12
	var u := 0.0
	var lat := 0.0
	for i in range(i0, i1 + 1):
		var a := pts[i]
		var b := pts[i + 1]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ap := Vector2(p.x - a.x, p.z - a.z)
		var l2 := ab.length_squared()
		var f := clampf(ap.dot(ab) / l2, 0.0, 1.0) if l2 > 1e-6 else 0.0
		var q := Vector2(a.x, a.z) + ab * f
		var dd := Vector2(p.x, p.z).distance_squared_to(q)
		if dd < mejor:
			mejor = dd
			u = s[i] + (s[i + 1] - s[i]) * f
			var der := Vector2(-ab.y, ab.x).normalized()
			lat = (Vector2(p.x, p.z) - q).dot(der)
	if sd < 0:
		return Vector2(L - u, -lat)
	return Vector2(u, lat)


## Punto y tangente a `ade` m por delante en el camino
func _punto_camino(ade: float) -> Array:
	var d := d_camino + ade
	for e in camino:
		var L := red.longitud(e[0])
		if d <= L or e == camino[camino.size() - 1]:
			var pt: Array = red.punto(e[0], e[1], minf(d, L))
			return [pt[0], pt[1], e[0]]
		d -= L
	return [coche.position, coche.adelante(), -1]


# ------------------------------------------------------------------ mandos y piloto
func _mandos(_dt: float) -> void:
	var acel := 1.0 if (Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)) else 0.0
	var fren := 1.0 if (Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN)) else 0.0
	var vol := 0.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): vol -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): vol += 1.0
	var mano := Input.is_physical_key_pressed(KEY_SPACE)
	if piloto and (acel > 0.0 or fren > 0.0 or vol != 0.0 or mano):
		piloto = false
	if mano: fren = 1.0
	if piloto and not camino.is_empty():
		coche.giro_directo = true
		coche.volante = _volante_piloto()
		_control_velocidad(_velocidad_objetivo())
		return
	coche.giro_directo = false
	coche.volante = vol
	if fren > 0.0 and coche.v < 0.3 and not mano:
		coche.marcha_atras = true
		coche.acelerador = fren
		coche.freno = 0.0
		return
	if acel > 0.0:
		coche.marcha_atras = false
	coche.acelerador = acel if not coche.marcha_atras else 0.0
	coche.freno = fren if not coche.marcha_atras else acel


func _volante_piloto() -> float:
	var mira := clampf(absf(coche.v) * 0.75, 7.0, 30.0)
	var pt := _punto_camino(mira)
	var t: Vector3 = pt[1]
	var der := Vector3(-t.z, 0.0, t.x).normalized()
	var k: int = pt[2] if pt[2] >= 0 else camino[0][0]
	var obj: Vector3 = (pt[0] as Vector3) + der * red.carril_derecho(k, 0)
	var fw := coche.adelante()
	var dr := Vector3(-fw.z, 0.0, fw.x)
	var dd := obj - coche.position
	var x := dd.dot(dr)
	var z := dd.dot(fw)
	var ld := maxf(sqrt(x * x + z * z), 1.0)
	return atan(2.0 * coche.ficha.batalla * sin(_angulo_mira(x, z)) / ld)


## Ángulo al punto de mira, como mucho de lado: si el punto queda detrás (salida de glorieta casi en U, coche abierto)
## el seno de atan2 vuelve a 0 y el piloto soltaba el volante y se iba recto campo a través
func _angulo_mira(x: float, z: float) -> float:
	var a := atan2(x, z)
	if absf(a) > PI * 0.5:
		a = PI * 0.5 * (1.0 if x >= 0.0 else -1.0)
	return a


func _velocidad_objetivo() -> float:
	var v0 := Ajustes.velocidad / 3.6
	if Ajustes.piloto_limites:
		v0 = minf(v0, red.limite(camino[0][0], camino[0][1]) / 3.6)
	if Ajustes.adaptar_curvas:
		# curvatura por cuerdas de 20 m (la poligonal de OSM tiene ruido de nodos: la tangente local exagera las curvas)
		var pa: Vector3 = _punto_camino(0.0)[0]
		var pb: Vector3 = _punto_camino(20.0)[0]
		var dd := 20.0
		while dd <= 260.0:
			var pc: Vector3 = _punto_camino(dd + 20.0)[0]
			var u := Vector2(pb.x - pa.x, pb.z - pa.z)
			var w := Vector2(pc.x - pb.x, pc.z - pb.z)
			if u.length() > 5.0 and w.length() > 5.0:
				var kap := absf(u.angle_to(w)) / 20.0
				if kap > 1e-4:
					var vc := sqrt(2.6 / kap)
					v0 = minf(v0, sqrt(vc * vc + 2.0 * 2.0 * maxf(dd - 20.0, 0.0)))
			pa = pb
			pb = pc
			dd += 20.0
		# la curva que hay que trazar ya (arco del piloto hasta su punto de mira): al salir de una glorieta por una
		# salida muy cerrada la curva queda dentro de la primera cuerda y no se veía; el piloto aceleraba a 60 km/h,
		# no podía girar y se iba recto (N-320)
		var kp := absf(_curvatura_piloto())
		if kp > 1e-3:
			v0 = minf(v0, sqrt(2.6 / kp))
		# fuera de su carril (se ha abierto): despacio hasta volver. Se mide desde el carril que sigue (en una calzada de
		# 3 carriles el carril derecho va a 3,5 m del eje: medido desde el eje, el piloto iba siempre a 25 km/h)
		if absf(lat_camino - red.carril_derecho(camino[0][0], 0)) > 2.5:
			v0 = minf(v0, 25.0 / 3.6)
	return v0


## Curvatura (1/m) del arco que sigue el piloto hasta su punto de mira
func _curvatura_piloto() -> float:
	var mira := clampf(absf(coche.v) * 0.75, 7.0, 30.0)
	var pt := _punto_camino(mira)
	var t: Vector3 = pt[1]
	var der := Vector3(-t.z, 0.0, t.x).normalized()
	var k: int = pt[2] if pt[2] >= 0 else camino[0][0]
	var obj: Vector3 = (pt[0] as Vector3) + der * red.carril_derecho(k, 0)
	var fw := coche.adelante()
	var dd := obj - coche.position
	var x := dd.dot(Vector3(-fw.z, 0.0, fw.x))
	var z := dd.dot(fw)
	var ld := maxf(sqrt(x * x + z * z), 1.0)
	return 2.0 * sin(_angulo_mira(x, z)) / ld


func _control_velocidad(v0: float) -> void:
	var hueco := 1e4
	var v_lider := v0
	if not camino.is_empty():
		for c in trafico.coches:
			var acum := -d_camino
			for e in camino:
				if c["k"] == e[0] and c["sd"] == e[1]:
					var g: float = acum + float(c["d"]) - trafico.LARGO
					if g > -1.0 and g < hueco:
						hueco = maxf(g, 0.1)
						v_lider = c["v"]
					break
				acum += red.longitud(e[0])
				if acum > 400.0:
					break
	var v := absf(coche.v)
	var a := clampf(trafico.idm(v, v0, hueco, v - v_lider) * 1.6, -8.0, 3.0)
	coche.marcha_atras = false
	if a < -0.4 or v > v0 + 3.0:
		coche.acelerador = 0.0
		coche.freno = clampf(maxf(-a, (v - v0 - 3.0) * 0.5) / 8.0, 0.0, 1.0)
	else:
		# mantener: un término fijo de crucero (cuestas, rozamiento) + proporcional al error de velocidad
		coche.acelerador = clampf(0.3 + 0.3 * (v0 - v) + 0.2 * minf(a, 0.0), 0.0, 1.0)
		coche.freno = 0.0


func _choques(dt: float) -> void:
	_choque_t -= dt
	for c in trafico.cerca_de(coche.position, 5.0):
		var n: Node3D = c["nodo"]
		var rel := coche.position - n.position
		var fw := -n.basis.z
		var lon := rel.dot(fw)
		var lat := rel.dot(n.basis.x)
		if absf(lon) < 4.4 and absf(lat) < 1.85:
			if _choque_t <= 0.0:
				choques += 1
				_choque_t = 1.0
			# separación simple: el coche del jugador queda detrás/al lado y pierde velocidad
			coche.v *= 0.6
			c["v"] = float(c["v"]) * 0.8
			coche.position += Vector3(rel.x, 0.0, rel.z).normalized() * 0.15


# ------------------------------------------------------------------ teclas
func _unhandled_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo):
		return
	match ev.physical_keycode:
		KEY_P:
			piloto = not piloto
			if piloto:
				camino.clear()
				_reengancharse()
		KEY_Q:
			preferencia = 0 if preferencia == -1 else -1
			_replanificar()
		KEY_E:
			preferencia = 0 if preferencia == 1 else 1
			_replanificar()
		KEY_EQUAL, KEY_KP_ADD:
			Ajustes.velocidad = minf(Ajustes.velocidad + 10.0, 200.0)
		KEY_MINUS, KEY_KP_SUBTRACT:
			Ajustes.velocidad = maxf(Ajustes.velocidad - 10.0, 20.0)
		KEY_C:
			Ajustes.camara = 1 - Ajustes.camara
		KEY_R:
			_volver_a_carretera()
		KEY_F3:
			ver_datos = not ver_datos
		KEY_ESCAPE:
			get_tree().change_scene_to_file("res://escenas/menu.tscn")


func _volver_a_carretera() -> void:
	if camino.is_empty():
		_reengancharse()
	if camino.is_empty():
		return
	var e: Array = camino[0]
	_colocar_en(e[0], e[1], clampf(d_camino, 0.0, red.longitud(e[0])))
	mundo.actualizar(coche.position, true)


# ------------------------------------------------------------------ cámara y HUD
var cam_vel := Vector3.ZERO
var mira := Vector3.ZERO
var mira_vel := Vector3.ZERO
var cam_iniciada := false


func _process(dt: float) -> void:
	if not cargado:
		return
	mundo.actualizar(coche.position)
	_camara(dt)
	_hud()


func _camara(dt: float) -> void:
	var tc := coche.get_global_transform_interpolated()
	var pos := tc.origin
	var fw := -tc.basis.z
	fw.y = 0.0
	fw = fw.normalized() if fw.length() > 0.01 else coche.adelante()
	if Ajustes.camara == 1:
		var o: Array = Catalogo.modelo_de(coche.ficha).get("ojos", [-0.37, 1.12, 0.25])
		cam.global_transform = Transform3D(tc.basis, pos + tc.basis * Vector3(float(o[0]), float(o[1]), float(o[2])))
		cam.fov = 75.0
		return
	cam.fov = 70.0
	var objetivo := pos - fw * (6.0 + coche.ficha.largo) + Vector3.UP * 3.2
	var suelo := Ajustes.superficie.consultar(objetivo.x, objetivo.z, objetivo.y).x
	objetivo.y = maxf(objetivo.y, suelo + 1.5)
	var punto_mira := pos + fw * 5.0 + Vector3.UP * 1.2
	if not cam_iniciada or cam.global_position.distance_to(objetivo) > 60.0:
		cam.global_position = objetivo
		mira = punto_mira
		cam_vel = Vector3.ZERO
		mira_vel = Vector3.ZERO
		cam_iniciada = true
	else:
		var r: Array = _amortiguar(cam.global_position, objetivo, cam_vel, 0.28, dt)
		cam.global_position = r[0]
		cam_vel = r[1]
		var r2: Array = _amortiguar(mira, punto_mira, mira_vel, 0.12, dt)
		mira = r2[0]
		mira_vel = r2[1]
	cam.look_at(mira, Vector3.UP)


static func _amortiguar(actual: Vector3, objetivo: Vector3, vel: Vector3, t: float, dt: float) -> Array:
	var w := 2.0 / maxf(t, 0.001)
	var x := w * dt
	var e := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var cambio := actual - objetivo
	var temp := (vel + cambio * w) * dt
	return [objetivo + (cambio + temp) * e, (vel - temp * w) * e]


func _crear_hud() -> void:
	var caja := PanelContainer.new()
	var est := StyleBoxFlat.new()
	est.bg_color = Color(0, 0, 0, 0.45)
	est.set_content_margin_all(10)
	caja.add_theme_stylebox_override("panel", est)
	caja.position = Vector2(16, 16)
	var col := VBoxContainer.new()
	caja.add_child(col)
	l_via.add_theme_font_size_override("font_size", 22)
	col.add_child(l_via)
	l_info.add_theme_font_size_override("font_size", 16)
	col.add_child(l_info)
	l_cruce.add_theme_font_size_override("font_size", 16)
	l_cruce.modulate = Color(1.0, 0.9, 0.6)
	col.add_child(l_cruce)
	hud.add_child(caja)
	l_vel.add_theme_font_size_override("font_size", 44)
	l_vel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	l_vel.position = Vector2(-260, -90)
	hud.add_child(l_vel)
	l_datos.position = Vector2(16, 200)
	l_datos.add_theme_font_size_override("font_size", 14)
	hud.add_child(l_datos)
	var ayuda := Label.new()
	ayuda.text = "W/S/A/D · Espacio freno de mano · P piloto · Q/E próximo cruce izq./der. · +/- velocidad · C cámara · R carretera · M mapa y GPS · Z/X zoom minimapa · F3 datos · Esc menú"
	ayuda.add_theme_font_size_override("font_size", 13)
	ayuda.modulate = Color(1, 1, 1, 0.7)
	ayuda.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	ayuda.position = Vector2(16, -28)
	hud.add_child(ayuda)


func _hud() -> void:
	l_vel.text = "%d km/h" % roundi(absf(coche.v) * 3.6)
	var via := datos.rotulo(tramo_actual)
	l_via.text = via if via != "" else "Comunidad de Madrid · mapa abierto"
	var lim := ""
	if tramo_actual >= 0:
		var t: Dictionary = datos.tramos[tramo_actual]
		lim = "   límite %d km/h" % int(t["v"])
	l_info.text = ("Piloto %d km/h" % roundi(Ajustes.velocidad) if piloto else "Conducción manual") + lim + "   alt. %d m" % roundi(coche.position.y)
	var pref: String = ["← izquierda", "seguir", "derecha →"][preferencia + 1]
	l_cruce.text = "Próximo cruce: %s%s" % [pref, _siguiente_desvio()]
	if ver_datos:
		l_datos.text = "FPS %d · teselas %d (cargadas %d, descargadas %d, máx %.0f ms) · tráfico %d · choques %d\nVRAM %.0f MB · texturas %.0f MB · nodos %d · huérfanos %d" % [
			Engine.get_frames_per_second(), mundo.listas(), mundo.est["cargadas"], mundo.est["descargadas"], mundo.est["ms_max"], trafico.coches.size(), choques,
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)]
	else:
		l_datos.text = ""


## "  ·  hacia M-50 en 350 m": la primera bifurcación del camino planificado
func _siguiente_desvio() -> String:
	if camino.size() < 2:
		return ""
	var acum := red.longitud(camino[0][0]) - d_camino
	for i in range(0, camino.size() - 1):
		var op := red.salidas(camino[i][0], camino[i][1])
		if op.size() >= 2:
			var r := datos.rotulo(camino[i + 1][0])
			return "  ·  en %d m → %s" % [roundi(acum / 10.0) * 10, r if r != "" else "enlace"]
		acum += red.longitud(camino[i + 1][0])
	return ""


# ------------------------------------------------------------------ verificación automática
## --captura=conduccion: simula con piloto `presim` s y guarda una imagen (--salida); --captura=prueba: solo simula
## --captura=memoria: recorre la red con piloto `minutos` (simulados) y escribe los monitores cada 30 s en --log
func _captura() -> void:
	var modo: String = Ajustes.args["captura"]
	en_prueba = true
	piloto = true
	var pasos := int(Ajustes.args.get("pasos", "10"))
	if modo == "memoria" or modo == "prueba":
		var minutos := float(Ajustes.args.get("minutos", "5"))
		var f: FileAccess = FileAccess.open(Ajustes.args.get("log", "user://ma_memoria.tsv"), FileAccess.WRITE)
		f.store_line("t_min\tfuera_s\tkm\ttramo\tvideo_MB\ttex_MB\tbuf_MB\tobjetos\trecursos\tnodos\thuerfanos\tteselas\tcargadas\tdescargadas\tms_max\ttrafico\tchoques\tfps\tvia\tdraws\tprims_k")
		var t_log := -1.0
		var km := 0.0
		var fuera := 0.0
		var t0 := Time.get_ticks_msec()
		while tiempo < minutos * 60.0:
			for i in pasos:
				var p0 := coche.position
				_simular(1.0 / 60.0)
				km += Vector2(coche.position.x - p0.x, coche.position.z - p0.z).length() / 1000.0
				if not coche.en_carretera:
					fuera += 1.0 / 60.0
			mundo.actualizar(coche.position)
			if Ajustes.args.has("traza") and int(tiempo * 60.0) % 300 < pasos:
				print("  t=%.0f v=%.0f v0=%.0f fren=%.2f acel=%.2f tramo=%s lat=%.1f piloto=%s camino=%d" % [tiempo, coche.v * 3.6, _velocidad_objetivo() * 3.6, coche.freno, coche.acelerador, datos.rotulo(tramo_actual), lat_camino, piloto, camino.size()])
			if tiempo - t_log >= 30.0 or t_log < 0.0:
				t_log = tiempo
				var linea := "%.1f\t%.1f\t%.2f\t%d\t%.1f\t%.1f\t%.1f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%.0f\t%d\t%d\t%.1f\t%s\t%d\t%.0f" % [tiempo / 60.0, fuera, km, tramo_actual,
					Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
					Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0, Performance.get_monitor(Performance.OBJECT_COUNT),
					Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT), Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
					Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), mundo.listas(), mundo.est["cargadas"], mundo.est["descargadas"],
					mundo.est["ms_max"], trafico.coches.size(), choques, Engine.get_frames_per_second(), datos.rotulo(tramo_actual),
					Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0]
				print(linea)
				f.store_line(linea)
				f.flush()
			await get_tree().process_frame
		f.close()
		print("MA_FIN km=%.1f tiempo=%.0f s fuera=%.1f s choques=%d biondas=%d reenganches=%d real=%d s" % [km, tiempo, fuera, choques, toques_bionda, reenganches, (Time.get_ticks_msec() - t0) / 1000])
		get_tree().quit()
		return
	var presim := float(Ajustes.args.get("presim", "5"))
	for i in int(presim * 60.0):
		_simular(1.0 / 60.0)
		if i % 30 == 0:
			mundo.actualizar(coche.position)
	# esperar a que terminen las teselas pendientes
	for i in 600:
		mundo.actualizar(coche.position)
		if mundo.pendientes.is_empty():
			break
		await get_tree().process_frame
	coche.reset_physics_interpolation()
	cam_iniciada = false
	_camara(0.016)
	_hud()
	for i in 10:
		await get_tree().process_frame
	if Ajustes.args.has("cam_alto"):
		cargado = false     # que _process no vuelva a colocar la cámara
		cam.global_position = coche.position - coche.adelante() * 40.0 + Vector3.UP * float(Ajustes.args["cam_alto"])
		cam.look_at(coche.position + coche.adelante() * float(Ajustes.args.get("cam_mira", "200")), Vector3.UP)
		for i in 3:
			await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(Ajustes.args.get("salida", "user://ma_captura.png"))
	for c in trafico.coches:
		var pn: Vector3 = (c["nodo"] as Node3D).position
		var q := Ajustes.superficie.consultar(pn.x, pn.z, pn.y)
		print("  coche tramo %d %s enlace=%d s=%d d=%.0f · sup y=%.1f carretera=%d tramo=%d · pos y=%.1f · dist %.0f m" % [c["k"], datos.rotulo(c["k"]), int(datos.tramos[c["k"]]["enlace"]), int(datos.tramos[c["k"]]["s"]), c["d"], q.x, int(q.y), int(q.z), pn.y, pn.distance_to(coche.position)])
	print("MA_CAPTURA %s · %s · %d km/h · teselas %d · tráfico %d" % [Ajustes.args.get("salida", ""), datos.rotulo(tramo_actual), roundi(coche.v * 3.6), mundo.listas(), trafico.coches.size()])
	get_tree().quit()
