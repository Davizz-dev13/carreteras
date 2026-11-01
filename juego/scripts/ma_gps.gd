## Navegador (GPS) del mapa abierto: ruta más rápida por la misma red que usa el piloto (red.json.gz, ma_red.gd).
##  · Búsqueda A* por PASOS ([tramo, sentido]), no por nodos: así cada giro de un paso al siguiente tiene su coste y se
##    pueden prohibir o penalizar giros. Mismas reglas que MaRed.salidas (lo que el piloto puede recorrer): respeta los
##    sentidos únicos, el sentido de giro de las glorietas, los ramales prohibidos (MaRed.prohibido) y nunca da media
##    vuelta en el mismo tramo. Cambios de sentido: gratis en glorietas (se rodea el anillo); media vuelta a la otra
##    calzada en un cruce (giro > 150°) solo si no queda otra (+4 min); en un fondo de saco de doble sentido +2 min;
##    horquilla sin otra salida (ramal en U) +1 min.
##  · Coste = tiempo (longitud / límite del sentido) + giros (izquierda 7 s, derecha 3 s, entrar en glorieta 3 s).
##  · El grafo de giros (CSR) se monta una vez en un hilo al cargar; cada ruta se calcula también en un hilo
##    (WorkerThreadPool) y se aplica en el hilo principal cuando está lista.
##  · Sin restricciones de giro de OSM (relaciones restriction): el pipeline no las extrae. APROXIMACIÓN.
class_name MaGps
extends RefCounted

var datos: MaDatos
var red: MaRed
var n_tramos := 0

# grafo de giros: para cada paso c (k*2+1 = a→b, k*2 = b→a), sus pasos siguientes en suc_c[suc_i[c] .. suc_i[c+1]-1]
var suc_i := PackedInt32Array()
var suc_c := PackedInt32Array()
var suc_s := PackedFloat32Array()     # segundos: recorrer el paso siguiente entero + coste del giro
var suc_g := PackedFloat32Array()     # giro (rad, + derecha)
var t_paso := PackedFloat32Array()    # segundos para recorrer cada paso
var fin_xz := PackedVector2Array()    # punto final de cada paso
var v_max := 33.0                     # m/s (heurística admisible)
var grafo_listo := false
var _hilo_grafo := -1

# ruta actual
var pasos := PackedInt32Array()       # códigos de paso desde el de partida hasta el de destino
var acum := PackedFloat32Array()      # m desde el comienzo del paso de partida hasta el final de cada paso (el último: hasta el destino)
var acum_t := PackedFloat32Array()    # lo mismo en segundos
var indice := {}                      # código -> Array de posiciones en `pasos`
var progreso := 0                     # posición del paso en el que va el coche
var maniobras: Array = []             # [posición del giro (tras el paso i), m desde el inicio, texto, giro rad, tipo]
var destino := Vector3.INF
var destino_k := -1
var destino_d := 0.0                  # m desde el comienzo del último paso hasta el punto
var nombre := ""
var ms_calculo := 0.0

# cálculo en curso (hilo)
var _tarea := -1
var _peticion: Array = []
var _resultado: Array = []

const PEN_IZQ := 7.0
const PEN_DER := 3.0
const PEN_GLORIETA := 3.0
const PEN_MEDIA_VUELTA := 240.0
const PEN_FONDO := 120.0
const PEN_HORQUILLA := 60.0
const MEDIA_VUELTA := 2.6             # rad (~150°)


func _init(d: MaDatos, r: MaRed) -> void:
	datos = d
	red = r
	n_tramos = datos.tramos.size()


static func paso(c: int) -> Array:
	return [c >> 1, 1 if (c & 1) == 1 else -1]


static func codigo(k: int, sd: int) -> int:
	return k * 2 + (1 if sd > 0 else 0)


# ------------------------------------------------------------------ grafo
## pts: PackedVector2Array por tramo (geometría simplificada de mapa.bin.gz, de a a b)
func construir(pts: Array) -> void:
	_hilo_grafo = WorkerThreadPool.add_task(_construir.bind(pts), false, "GPS: grafo de giros")


func comprobar_grafo() -> bool:
	if grafo_listo:
		return true
	if _hilo_grafo >= 0 and WorkerThreadPool.is_task_completed(_hilo_grafo):
		WorkerThreadPool.wait_for_task_completion(_hilo_grafo)
		_hilo_grafo = -1
		grafo_listo = true
	return grafo_listo


func esperar_grafo() -> void:
	if _hilo_grafo >= 0:
		WorkerThreadPool.wait_for_task_completion(_hilo_grafo)
		_hilo_grafo = -1
		grafo_listo = true


static func _rumbo(p: PackedVector2Array, desde_inicio: bool) -> Vector2:
	# dirección media de los primeros (o últimos) ~15 m, en el sentido a→b
	var n := p.size()
	if n < 2:
		return Vector2.ZERO
	var acu := 0.0
	if desde_inicio:
		var i := 1
		while i < n - 1 and acu + p[i - 1].distance_to(p[i]) < 15.0:
			acu += p[i - 1].distance_to(p[i])
			i += 1
		return (p[i] - p[0]).normalized()
	var j := n - 2
	while j > 0 and acu + p[j].distance_to(p[j + 1]) < 15.0:
		acu += p[j].distance_to(p[j + 1])
		j -= 1
	return (p[n - 1] - p[j]).normalized()


func _construir(pts: Array) -> void:
	var t0 := Time.get_ticks_msec()
	var n2 := n_tramos * 2
	var ini := PackedVector2Array()
	var fin := PackedVector2Array()
	ini.resize(n_tramos)
	fin.resize(n_tramos)
	t_paso.resize(n2)
	fin_xz.resize(n2)
	var vm := 0.0
	for k in n_tramos:
		var p: PackedVector2Array = pts[k] if k < pts.size() else PackedVector2Array()
		ini[k] = _rumbo(p, true)
		fin[k] = _rumbo(p, false)
		var t: Dictionary = datos.tramos[k]
		var L := float(t["L"])
		for sd in [1, -1]:
			var v := red.limite(k, sd)
			if v <= 0.0:
				v = 50.0
			vm = maxf(vm, v)
			var c := codigo(k, sd)
			t_paso[c] = L / (v / 3.6)
			if p.size() > 0:
				fin_xz[c] = p[p.size() - 1] if sd > 0 else p[0]
	v_max = maxf(vm, 50.0) / 3.6
	suc_i.resize(n2 + 1)
	var lista_c := PackedInt32Array()
	var lista_s := PackedFloat32Array()
	var lista_g := PackedFloat32Array()
	for c in n2:
		suc_i[c] = lista_c.size()
		var k := c >> 1
		var sd := 1 if (c & 1) == 1 else -1
		var t: Dictionary = datos.tramos[k]
		var sv := int(t["s"])
		if (sd > 0 and sv == -1) or (sd < 0 and sv == 1):
			continue            # paso imposible (contra dirección única): sin salidas
		var n := int(t["b"]) if sd > 0 else int(t["a"])
		var nodo = datos.nodos.get(n)
		if nodo == null:
			continue
		var llegada: Vector2 = fin[k] if sd > 0 else -ini[k]
		var der := Vector2(-llegada.y, llegada.x)
		var rot := int(t["rot"]) == 1
		var desde := lista_c.size()
		for x in nodo[3]:
			var k2 := int(x)
			if k2 == k:
				continue
			var t2: Dictionary = datos.tramos[k2]
			var a2 := int(t2["a"])
			var b2 := int(t2["b"])
			if a2 == n and b2 == n:
				continue
			var s2 := 1 if a2 == n else -1
			var sv2 := int(t2["s"])
			if (s2 > 0 and sv2 == -1) or (s2 < 0 and sv2 == 1):
				continue
			if sv2 == 0 and red.prohibido(k2, s2):
				continue
			var sal: Vector2 = ini[k2] if s2 > 0 else -fin[k2]
			var giro := atan2(sal.dot(der), sal.dot(llegada)) if sal != Vector2.ZERO and llegada != Vector2.ZERO else 0.0
			lista_c.append(codigo(k2, s2))
			lista_g.append(giro)
			var rot2 := int(t2["rot"]) == 1
			var pen := 0.0
			if rot and rot2:
				pen = 0.0
			elif rot2:
				pen = PEN_GLORIETA
			elif not rot and absf(giro) > MEDIA_VUELTA:
				pen = -1.0            # se decide abajo (depende de si hay otras salidas)
			elif absf(giro) > 0.6:
				pen = PEN_DER if giro > 0.0 else PEN_IZQ
			lista_s.append(pen)
		var cuantos := lista_c.size() - desde
		for i in range(desde, lista_c.size()):
			if lista_s[i] < 0.0:
				# con una sola salida es una horquilla (curva de herradura o ramal en U): se puede, pero mejor otro camino
				lista_s[i] = PEN_MEDIA_VUELTA if cuantos >= 2 else PEN_HORQUILLA
			lista_s[i] += t_paso[lista_c[i]]
		if cuantos == 0 and sv == 0:
			# fondo de saco de doble sentido: media vuelta (lo que hace MaRed.elegir)
			lista_c.append(codigo(k, -sd))
			lista_g.append(PI)
			lista_s.append(PEN_FONDO + t_paso[codigo(k, -sd)])
	suc_i[n2] = lista_c.size()
	suc_c = lista_c
	suc_s = lista_s
	suc_g = lista_g
	print("GPS_GRAFO %d pasos, %d giros, %d ms" % [n2, lista_c.size(), Time.get_ticks_msec() - t0])


func salidas_de(c: int) -> int:
	return suc_i[c + 1] - suc_i[c]


# ------------------------------------------------------------------ ruta
func activo() -> bool:
	return not pasos.is_empty()


func calculando() -> bool:
	return _tarea >= 0


func borrar() -> void:
	pasos = PackedInt32Array()
	acum = PackedFloat32Array()
	acum_t = PackedFloat32Array()
	indice = {}
	maniobras = []
	progreso = 0
	destino = Vector3.INF
	destino_k = -1
	nombre = ""


## Pide la ruta desde el paso [k0, sd0] (con d0 m ya recorridos) hasta el punto p del tramo kd. Se calcula en un hilo;
## terminado() dice cuándo está y si hay ruta.
func pedir(k0: int, sd0: int, d0: float, kd: int, p: Vector3, nombre_destino: String) -> void:
	if not grafo_listo:
		esperar_grafo()
	if _tarea >= 0:
		WorkerThreadPool.wait_for_task_completion(_tarea)
		_tarea = -1
	_peticion = [k0, sd0, d0, kd, p, nombre_destino]
	_resultado = []
	_tarea = WorkerThreadPool.add_task(_calcular_hilo, false, "GPS: ruta")


## Síncrono (pruebas)
func calcular(k0: int, sd0: int, d0: float, kd: int, p: Vector3, nombre_destino: String) -> bool:
	pedir(k0, sd0, d0, kd, p, nombre_destino)
	WorkerThreadPool.wait_for_task_completion(_tarea)
	_tarea = -1
	return _aplicar()


## -1 sigue calculando; 0 no hay ruta; 1 ruta nueva aplicada
func terminado() -> int:
	if _tarea < 0:
		return -1
	if not WorkerThreadPool.is_task_completed(_tarea):
		return -1
	WorkerThreadPool.wait_for_task_completion(_tarea)
	_tarea = -1
	return 1 if _aplicar() else 0


func _calcular_hilo() -> void:
	var t0 := Time.get_ticks_usec()
	var k0: int = _peticion[0]
	var sd0: int = _peticion[1]
	var d0: float = _peticion[2]
	var kd: int = _peticion[3]
	var p: Vector3 = _peticion[4]
	var td: Dictionary = datos.tramos[kd]
	var u := _a_lo_largo(kd, p)
	var Ld := red.longitud(kd)
	var c0 := codigo(k0, sd0)
	var ruta := PackedInt32Array()
	var svd := int(td["s"])
	if kd == k0 and (sd0 > 0 and u >= d0 + 5.0 or sd0 < 0 and Ld - u >= d0 + 5.0):
		ruta.append(c0)              # ya en el tramo de destino, con el destino por delante
	else:
		var n2 := n_tramos * 2
		var g := PackedFloat32Array()
		g.resize(n2)
		g.fill(INF)
		var prev := PackedInt32Array()
		prev.resize(n2)
		prev.fill(-1)
		var cerrado := PackedByteArray()
		cerrado.resize(n2)
		var meta := Vector2(p.x, p.z)
		var hc := PackedFloat32Array()
		var hn := PackedInt32Array()
		g[c0] = 0.0
		hc.append(0.0)
		hn.append(c0)
		var mejor := INF
		var fin := -1               # paso de destino (código) con el que se llega
		var prev_fin := -1
		var expandidos := 0
		while not hn.is_empty():
			var f := hc[0]
			var c := hn[0]
			# sacar del montículo
			var ult := hc.size() - 1
			hc[0] = hc[ult]
			hn[0] = hn[ult]
			hc.resize(ult)
			hn.resize(ult)
			var i := 0
			while true:
				var l := i * 2 + 1
				var r := l + 1
				var m := i
				if l < ult and hc[l] < hc[m]: m = l
				if r < ult and hc[r] < hc[m]: m = r
				if m == i:
					break
				var tc := hc[m]; hc[m] = hc[i]; hc[i] = tc
				var tn := hn[m]; hn[m] = hn[i]; hn[i] = tn
				i = m
			if f >= mejor:
				break
			if cerrado[c] == 1:
				continue
			cerrado[c] = 1
			expandidos += 1
			var gc := g[c]
			for j in range(suc_i[c], suc_i[c + 1]):
				var c2 := suc_c[j]
				var k2 := c2 >> 1
				if k2 == kd:
					# llegar al destino: solo la parte del paso hasta el punto
					var s2 := 1 if (c2 & 1) == 1 else -1
					var parte := u if s2 > 0 else Ld - u
					var coste := gc + (suc_s[j] - t_paso[c2]) + t_paso[c2] * clampf(parte / maxf(Ld, 0.1), 0.0, 1.0)
					if coste < mejor:
						mejor = coste
						fin = c2
						prev_fin = c
				var ng := gc + suc_s[j]
				if ng < g[c2] and cerrado[c2] == 0:
					g[c2] = ng
					prev[c2] = c
					var nf := ng + fin_xz[c2].distance_to(meta) / v_max
					# meter en el montículo
					hc.append(nf)
					hn.append(c2)
					var q := hc.size() - 1
					while q > 0:
						var pq := (q - 1) >> 1
						if hc[pq] <= hc[q]:
							break
						var tc2 := hc[pq]; hc[pq] = hc[q]; hc[q] = tc2
						var tn2 := hn[pq]; hn[pq] = hn[q]; hn[q] = tn2
						q = pq
		if fin < 0:
			_resultado = [false, 0, (Time.get_ticks_usec() - t0) / 1000.0, expandidos]
			return
		var inv := PackedInt32Array([fin])
		var x := prev_fin
		while x != -1 and x != c0:
			inv.append(x)
			x = prev[x]
		inv.append(c0)
		for i2 in range(inv.size() - 1, -1, -1):
			ruta.append(inv[i2])
		_resultado = [true, _preparar(ruta, u, Ld, kd), (Time.get_ticks_usec() - t0) / 1000.0, expandidos]
		return
	_resultado = [true, _preparar(ruta, u, Ld, kd), (Time.get_ticks_usec() - t0) / 1000.0, 0]


## (en el hilo) todo lo que la ruta necesita: distancias y tiempos acumulados, punto de destino, maniobras
func _preparar(ruta: PackedInt32Array, u: float, Ld: float, kd: int) -> Dictionary:
	var ult: Array = paso(ruta[ruta.size() - 1])
	var dd := u if int(ult[1]) > 0 else Ld - u
	var ac := PackedFloat32Array()
	var act := PackedFloat32Array()
	ac.resize(ruta.size())
	act.resize(ruta.size())
	var a := 0.0
	var at := 0.0
	for i in ruta.size():
		var k := ruta[i] >> 1
		var L := red.longitud(k)
		var tp := t_paso[ruta[i]]
		if i == ruta.size() - 1:
			tp *= clampf(dd / maxf(L, 0.1), 0.0, 1.0)
			L = dd
		a += L
		at += tp
		ac[i] = a
		act[i] = at
	return {"pasos": ruta, "acum": ac, "acum_t": act, "destino_d": dd, "destino": red.punto(kd, int(ult[1]), dd)[0],
			"maniobras": _maniobras(ruta, ac)}


func _aplicar() -> bool:
	if _resultado.is_empty() or not _resultado[0]:
		ms_calculo = 0.0 if _resultado.is_empty() else float(_resultado[2])
		return false
	var r: Dictionary = _resultado[1]
	ms_calculo = float(_resultado[2])
	pasos = r["pasos"]
	acum = r["acum"]
	acum_t = r["acum_t"]
	destino_d = r["destino_d"]
	destino = r["destino"]
	maniobras = r["maniobras"]
	indice = {}
	for i in pasos.size():
		if not indice.has(pasos[i]):
			indice[pasos[i]] = []
		indice[pasos[i]].append(i)
	progreso = 0
	destino_k = int(_peticion[3])
	nombre = str(_peticion[5])
	return true


## Posición en la ruta del paso [k, sd] a partir del progreso actual (-1 si no está por delante)
func posicion(k: int, sd: int) -> int:
	var l = indice.get(codigo(k, sd))
	if l == null:
		return -1
	for i in l:
		if int(i) >= progreso:
			return int(i)
	return -1


## El paso que sigue a [k, sd] en la ruta, o [] si [k, sd] no está en ella (o es el último)
func siguiente(k: int, sd: int) -> Array:
	var i := posicion(k, sd)
	if i < 0 or i + 1 >= pasos.size():
		return []
	return paso(pasos[i + 1])


func en_ruta(k: int, sd: int) -> bool:
	return posicion(k, sd) >= 0


## Metros desde el comienzo de la ruta del coche en el paso de la posición i con d m recorridos
func recorrido(i: int, d: float) -> float:
	return (acum[i - 1] if i > 0 else 0.0) + d


## Metros que faltan desde [k, sd] con d m ya recorridos en ese paso (-1 si no está en la ruta)
func restante(k: int, sd: int, d: float) -> float:
	var i := posicion(k, sd)
	if i < 0:
		return -1.0
	return maxf(acum[acum.size() - 1] - recorrido(i, d), 0.0)


## Segundos que faltan (al límite de cada vía, sin tráfico)
func segundos(k: int, sd: int, d: float) -> float:
	var i := posicion(k, sd)
	if i < 0:
		return -1.0
	var L := red.longitud(k)
	var f := clampf(d / maxf(L, 0.1), 0.0, 1.0)
	var t_ini := acum_t[i - 1] if i > 0 else 0.0
	var t_aqui := t_ini + (acum_t[i] - t_ini) * f
	return maxf(acum_t[acum_t.size() - 1] - t_aqui, 0.0)


## Próxima maniobra por delante de la posición: [m hasta ella, texto, giro rad, tipo] o [] si no queda ninguna
func proxima(k: int, sd: int, d: float) -> Array:
	var i := posicion(k, sd)
	if i < 0:
		return []
	var aqui := recorrido(i, d)
	for m in maniobras:
		if int(m[0]) >= i and float(m[1]) > aqui - 2.0:
			return [float(m[1]) - aqui, m[2], m[3], m[4]]
	return []


# ------------------------------------------------------------------ indicaciones
## Lista de maniobras: en cada nodo de la ruta con más de una salida posible, si lo que hace la ruta no es "seguir"
func _maniobras(ru: PackedInt32Array, ac: PackedFloat32Array) -> Array:
	var lista: Array = []
	var i := 0
	while i < ru.size() - 1:
		var c := ru[i]
		var c2 := ru[i + 1]
		var k := c >> 1
		var k2 := c2 >> 1
		var rot := int(datos.tramos[k]["rot"]) == 1
		var rot2 := int(datos.tramos[k2]["rot"]) == 1
		var j_giro := _indice_giro(c, c2)
		var giro := suc_g[j_giro] if j_giro >= 0 else 0.0
		var n_sal := salidas_de(c)
		if not rot and rot2:
			# glorieta: contar salidas hasta la que toma la ruta
			var j := i + 1
			var n := 0
			while j < ru.size() - 1 and int(datos.tramos[ru[j] >> 1]["rot"]) == 1:
				var hay := false
				for q in range(suc_i[ru[j]], suc_i[ru[j] + 1]):
					if int(datos.tramos[suc_c[q] >> 1]["rot"]) == 0:
						hay = true
						break
				if hay:
					n += 1
				if int(datos.tramos[ru[j + 1] >> 1]["rot"]) == 0:
					break
				j += 1
			var hacia := _hacia(ru, j + 1)
			var txt := "En la glorieta, toma la %d.ª salida" % maxi(n, 1)
			if j >= ru.size() - 1:
				txt = "Entra en la glorieta"
			lista.append([i, ac[i], txt + hacia, 0.0, "glorieta%d" % maxi(n, 1)])
			i = j
			continue
		if ru[i + 1] == codigo(k, -((c & 1) * 2 - 1)) and k2 == k:
			lista.append([i, ac[i], "Da la vuelta" + _hacia(ru, i + 1), PI, "vuelta"])
		elif n_sal >= 2 and not rot:
			var recto := true
			var otro_recto := false
			for q in range(suc_i[c], suc_i[c + 1]):
				if suc_c[q] == c2:
					continue
				if absf(suc_g[q]) < absf(giro):
					recto = false
				if absf(suc_g[q]) < 0.35:
					otro_recto = true
			var t1: Dictionary = datos.tramos[k]
			var t2: Dictionary = datos.tramos[k2]
			var a_enlace := int(t2["enlace"]) == 1 and int(t1["enlace"]) == 0
			var sigue := red.misma_via(k, k2) and int(t2["enlace"]) == int(t1["enlace"])
			var txt := ""
			var tipo := ""
			if absf(giro) > MEDIA_VUELTA:
				txt = "Cambia de sentido"
				tipo = "vuelta"
			elif absf(giro) >= 0.35 and not (sigue and recto):
				if a_enlace and absf(giro) < 1.0:
					txt = "Toma la salida a la " + ("derecha" if giro > 0.0 else "izquierda")
					tipo = "salida"
				else:
					txt = ("Gira a la " if absf(giro) >= 0.9 else "Gira ligeramente a la ") + ("derecha" if giro > 0.0 else "izquierda")
					tipo = "giro"
			elif a_enlace:
				txt = "Toma la salida"
				tipo = "salida"
			elif not sigue and (otro_recto or not recto):
				# bifurcación: dos caminos casi rectos (o el que se toma no es el más recto) y se cambia de vía
				txt = "Mantente a la " + ("derecha" if giro >= 0.0 else "izquierda")
				tipo = "carril"
			if txt != "":
				lista.append([i, ac[i], txt + _hacia(ru, i + 1), giro, tipo])
		i += 1
	lista.append([ru.size() - 1, ac[ac.size() - 1], "Destino", 0.0, "destino"])
	return lista


func _indice_giro(c: int, c2: int) -> int:
	for q in range(suc_i[c], suc_i[c + 1]):
		if suc_c[q] == c2:
			return q
	return -1


## " hacia M-40": la vía (matrícula o nombre) del primer paso que no es enlace ni glorieta desde la posición i
func _hacia(ru: PackedInt32Array, i: int) -> String:
	for j in range(i, mini(i + 12, ru.size())):
		var t: Dictionary = datos.tramos[ru[j] >> 1]
		if int(t["enlace"]) == 1 or int(t["rot"]) == 1:
			continue
		var r := str(t["ref"]).split(";")[0]
		if r == "":
			r = str(t["nombre"])
		r = nombre_visible(r)
		return "" if r == "" else "  ·  " + r
	return ""


## Nombres que no se rotulan en el juego (mismo criterio que m7_mapa.py: sha1 del nombre en minúsculas sin tildes)
const OMITIR := ["c767979c043f", "6448c1ca9aa8", "8892d7b888f1"]

static func nombre_visible(s: String) -> String:
	var limpio := s.to_lower()
	for par in [["á", "a"], ["é", "e"], ["í", "i"], ["ó", "o"], ["ú", "u"], ["ü", "u"], ["ñ", "n"]]:
		limpio = limpio.replace(par[0], par[1])
	for palabra in limpio.replace("-", " ").replace(",", " ").replace(".", " ").replace("(", " ").replace(")", " ").split(" ", false):
		if OMITIR.has(palabra.sha1_text().substr(0, 12)):
			return ""
	return s


func _a_lo_largo(k: int, p: Vector3) -> float:
	var pts := datos.geometria(k)
	var s := red.largos(k)
	var mejor := INF
	var u := 0.0
	for i in pts.size() - 1:
		var a := Vector2(pts[i].x, pts[i].z)
		var b := Vector2(pts[i + 1].x, pts[i + 1].z)
		var ab := b - a
		var l2 := ab.length_squared()
		var f := clampf((Vector2(p.x, p.z) - a).dot(ab) / l2, 0.0, 1.0) if l2 > 1e-6 else 0.0
		var dd := (a + ab * f).distance_squared_to(Vector2(p.x, p.z))
		if dd < mejor:
			mejor = dd
			u = s[i] + (s[i + 1] - s[i]) * f
	return u
