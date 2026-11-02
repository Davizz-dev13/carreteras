## Glorieta tipo: UNA plantilla de glorieta española (norma 3.1-IC / 8.2-IC) que se ajusta a cada anillo de OSM
## (posición, forma y ángulo de cada brazo). Casi todas las glorietas salen de aquí; solo los enlaces grandes de
## varios carriles conservan su anchura de OSM.
##   - anillo: una sola calzada de anchura constante, un solo sentido (antihorario), 1 carril (6 m) si el diámetro
##     exterior es < 40 m, 2 carriles (9 m) si es mayor; bordes continuos y separación discontinua (Cruces._marcas_anillo)
##   - cada brazo de doble sentido llega partido en carril de entrada (derecha) y de salida (izquierda) por una isleta
##     separadora pintada (cebreado) de 25 m que se abre hasta 2,4 m junto al anillo
##   - abocinamientos (radio ~9 m) que unen el borde de cada brazo con el borde del anillo, sin muescas
##   - línea de ceda el paso (discontinua, M-4.2) sobre el carril de entrada, en el borde exterior del anillo
##   - la calzada de la ruta y los trozos de OSM del anillo NO se dibujan encima: el anillo es la única superficie
class_name GlorietaTipo
extends RefCounted

const ANCHO_1C := 6.0        # anillo de un carril
const ANCHO_2C := 9.0        # anillo de dos carriles
const DIAM_2C := 40.0        # diámetro exterior a partir del cual el anillo lleva dos carriles
const ISLA_LARGO := 25.0     # isleta separadora: largo
const ISLA_ANCHO := 3.0      # isleta separadora: anchura junto al anillo
const ISLA_HUECO := 1.2      # la punta de la isleta queda a esta distancia del borde del anillo (paso de la línea de ceda)
const ABOCINADO := 9.0       # largo del abocinamiento de cada lado de un brazo
const BORDE_EXTRA := 0.3     # el asfalto del anillo sale 30 cm del borde de su carril (Cruces._anillos)
const SECTORES := 72
const MARCA_Y := 0.09        # las marcas, sobre el asfalto


## Anchura del anillo según la plantilla (se guarda la de OSM en "hw_osm"). Llamar una vez, antes de usar las glorietas.
static func normalizar(glorietas: Array) -> void:
	for g in glorietas:
		if g.has("hw_osm"):
			continue
		var inf := info(g)
		if not inf["ok"]:
			continue
		var r: float = inf["r"]
		var hw0 := float(g.get("hw", 3.2))
		g["hw_osm"] = hw0
		var hw := ANCHO_1C * 0.5 if 2.0 * (r + ANCHO_1C * 0.5) < DIAM_2C else ANCHO_2C * 0.5
		if hw0 > ANCHO_2C * 0.5 + 0.4 and r > 35.0:
			hw = hw0                         # enlaces grandes de varios carriles: los de OSM
		hw = minf(hw, maxf(2.6, r - 3.0))    # isleta central de 3 m de radio como mínimo
		g["hw"] = hw
		inf["hw"] = hw


## Centro, radio medio y radio del eje por sectores de 5° (ángulo antihorario en el mapa: atan2(-dz, dx)). En caché.
static func info(g: Dictionary) -> Dictionary:
	if g.has("_info"):
		var i0: Dictionary = g["_info"]
		i0["hw"] = float(g.get("hw", 3.2))
		return i0
	var xs: Array = g["x"]
	var ys: Array = g["y"]
	var zs: Array = g["z"]
	var n := xs.size()
	var inf := {"ok": false}
	g["_info"] = inf
	if n < 6:
		return inf
	var c := Vector3.ZERO
	for i in n:
		c += Vector3(float(xs[i]), float(ys[i]), float(zs[i]))
	c /= float(n)
	var r := 0.0
	for i in n:
		r += Vector2(float(xs[i]) - c.x, float(zs[i]) - c.z).length()
	r /= float(n)
	var rad := PackedFloat32Array()
	rad.resize(SECTORES)
	rad.fill(-1.0)
	for i in n:
		var a := Vector2(float(xs[i]) - c.x, float(zs[i]) - c.z)
		var b := Vector2(float(xs[(i + 1) % n]) - c.x, float(zs[(i + 1) % n]) - c.z)
		var ta := atan2(-a.y, a.x)
		var span := wrapf(atan2(-b.y, b.x) - ta, -PI, PI)
		var pasos := maxi(1, int(absf(span) / (TAU / SECTORES) * 2.0) + 1)
		for k in pasos + 1:
			var f := float(k) / float(pasos)
			var q := a.lerp(b, f)
			var s := posmod(int(floorf(wrapf(atan2(-q.y, q.x), 0.0, TAU) / TAU * SECTORES)), SECTORES)
			rad[s] = q.length() if rad[s] < 0.0 else maxf(rad[s], q.length())
	for s in SECTORES:
		if rad[s] < 0.0:
			rad[s] = r
	inf["ok"] = r > 4.0
	inf["c"] = c
	inf["r"] = r
	inf["rad"] = rad
	inf["hw"] = float(g.get("hw", 3.2))
	return inf


static func angulo(c: Vector3, p: Vector3) -> float:
	return atan2(-(p.z - c.z), p.x - c.x)


## Radio del eje del anillo en el ángulo th (interpolado entre sectores)
static func r_eje(inf: Dictionary, th: float) -> float:
	var rad: PackedFloat32Array = inf["rad"]
	var f := wrapf(th, 0.0, TAU) / TAU * SECTORES - 0.5
	var s0 := posmod(int(floorf(f)), SECTORES)
	var t := f - floorf(f)
	return lerpf(rad[s0], rad[(s0 + 1) % SECTORES], t)


## Radio del borde exterior del asfalto del anillo en el ángulo th
static func r_borde(inf: Dictionary, th: float) -> float:
	return r_eje(inf, th) + float(inf["hw"]) + BORDE_EXTRA


## Distancia (con signo, + fuera) del punto p al borde exterior del anillo
static func fuera_de_borde(inf: Dictionary, p: Vector3) -> float:
	var c: Vector3 = inf["c"]
	return Vector2(p.x - c.x, p.z - c.z).length() - r_borde(inf, angulo(c, p))


## Punto del borde exterior (radio + lat) en el ángulo th
static func punto_borde(inf: Dictionary, th: float, lat := 0.0) -> Vector3:
	var c: Vector3 = inf["c"]
	var r := r_borde(inf, th) + lat
	return Vector3(c.x + cos(th) * r, c.y, c.z - sin(th) * r)


## Semiancho de la isleta separadora a una distancia t (m, medida por la calzada) del borde del anillo
static func semiancho_isla(t: float) -> float:
	if t < 0.0 or t > ISLA_LARGO:
		return 0.0
	# triangular, como una isleta real: se abre de 0 (punta lejana) a ISLA_ANCHO junto al anillo
	return ISLA_ANCHO * 0.5 * (1.0 - t / ISLA_LARGO)


## Cuadrilátero de marca vial de a a b, ancho 2·hw (cara hacia arriba, como MapaStreaming._linea)
static func quad(a: Vector3, b: Vector3, hw: float, mv: PackedVector3Array, mi: PackedInt32Array) -> void:
	var t := b - a
	if Vector2(t.x, t.z).length() < 0.01:
		return
	var der := Vector3(-t.z, 0.0, t.x).normalized() * hw
	var k := mv.size()
	mv.append_array([a - der, a + der, b - der, b + der])
	mi.append_array([k, k + 2, k + 1, k + 1, k + 2, k + 3])


# ---------------------------------------------------------------- brazos, abocinamientos, isletas y líneas de ceda
## Aplica la plantilla a calzadas ya colocadas (al final de Cruces.preparar, antes de excavar el terreno):
## oculta los trozos de OSM que forman cada anillo, recorta las vías en el borde del anillo, ensancha y pinta la isleta
## separadora de cada brazo de doble sentido, añade los abocinamientos (parches) y la línea de ceda de cada entrada.
static func aplicar(cr: Cruces, rutas: Array, vias: Array, glorietas: Array) -> Dictionary:
	var st := {"glorietas_tipo": 0, "trozos_anillo_ocultos": 0, "brazos": 0, "abocinados": 0, "isletas": 0, "cedas": 0}
	GlorietaMalla.reiniciar()
	var infos := []
	var rej := {}
	for gi in glorietas.size():
		var inf := info(glorietas[gi])
		infos.append(inf)
		if not inf["ok"]:
			continue
		st["glorietas_tipo"] += 1
		var c: Vector3 = inf["c"]
		var rr: float = float(inf["r"]) + float(inf["hw"]) + 30.0
		for cx in range(floori((c.x - rr) / 100.0), floori((c.x + rr) / 100.0) + 1):
			for cz in range(floori((c.z - rr) / 100.0), floori((c.z + rr) / 100.0) + 1):
				var k := Vector2i(cx, cz)
				if not rej.has(k):
					rej[k] = []
				rej[k].append(gi)
	var brazos := {}      # gi -> [brazo]
	# --- vías: trozos del anillo (ocultos) y brazos (recortados en el borde del anillo)
	for v in vias:
		if int(v.get("tunel", 0)) == 1:
			continue
		var pts: PackedVector3Array = v["pts"]
		if pts.size() < 2:
			continue
		var cand := {}
		for q in [pts[0], pts[pts.size() - 1], pts[pts.size() / 2]]:
			for gi in rej.get(Vector2i(floori(q.x / 100.0), floori(q.z / 100.0)), []):
				cand[gi] = true
		for gi in cand:
			var inf: Dictionary = infos[gi]
			if _es_trozo_anillo(inf, glorietas[gi], pts):
				v["oculta_glorieta"] = true
				st["trozos_anillo_ocultos"] += 1
				break
		if v.get("oculta_glorieta", false):
			continue
		var dib := pts
		var extremos := []      # [x0, doble] de cada extremo recortado
		var hay := false
		for gi in cand:
			var inf: Dictionary = infos[gi]
			for extremo in [0, 1]:
				if dib.size() < 2:
					break
				var p_ext: Vector3 = dib[0] if extremo == 0 else dib[dib.size() - 1]
				if absf(p_ext.y - (inf["c"] as Vector3).y) > 3.0:
					continue
				var poli := dib.duplicate()
				if extremo == 1:
					poli.reverse()
				var f_ext := fuera_de_borde(inf, p_ext)
				if f_ext >= 0.0:
					# vía cortada antes del anillo (Cruces la cortó en el borde de la calzada de la ruta, que dentro del
					# anillo ya no se dibuja): se alarga en su dirección hasta entrar en el anillo, si apunta a él
					if f_ext > 15.0 or poli.size() < 2:
						continue
					var dv := Vector3(poli[0].x - poli[1].x, 0.0, poli[0].z - poli[1].z).normalized()
					var hacia_c := Vector3((inf["c"] as Vector3).x - p_ext.x, 0.0, (inf["c"] as Vector3).z - p_ext.z).normalized()
					if dv.dot(hacia_c) < 0.05:
						continue
					# hasta 25 m en su dirección (los ramales que llegan casi tangentes recorren más hasta el anillo)
					var q_in := p_ext
					var dentro_ya := false
					for paso_m in range(1, 26):
						q_in = p_ext + dv * float(paso_m)
						if fuera_de_borde(inf, q_in) < -1.0:
							dentro_ya = true
							break
					if not dentro_ya:
						continue
					poli.insert(0, q_in)
					st["vias_alargadas"] = int(st.get("vias_alargadas", 0)) + 1
				var hw_v := float(v["ancho"]) * 0.5
				var tipo := str(v.get("tipo", ""))
				var doble := not (tipo.ends_with("_link") or tipo == "motorway" or tipo == "trunk") and hw_v >= 2.5     # autovías: calzadas de un solo sentido
				var br := _brazo(inf, poli, hw_v, doble)
				if br.is_empty():
					continue
				br["entra"] = 1 if extremo == 1 else -1     # sentido de dibujo de OSM: hacia el anillo = entrada
				br["ruta"] = false
				br["elev"] = 0.0
				br["via"] = v
				# la malla de la glorieta (GlorietaMalla) se queda con los primeros LARGO m del brazo; la vía se dibuja
				# desde el corte. Una vía entre dos glorietas se reparte a medias.
				var tt_b: PackedFloat32Array = br["tt"]
				var largo := minf(GlorietaMalla.LARGO, tt_b[tt_b.size() - 1] - 1.0)
				var otro: Vector3 = dib[dib.size() - 1] if extremo == 0 else dib[0]
				for gj in rej.get(Vector2i(floori(otro.x / 100.0), floori(otro.z / 100.0)), []):
					if infos[gj]["ok"] and absf(otro.y - (infos[gj]["c"] as Vector3).y) < 3.0 and fuera_de_borde(infos[gj], otro) < 15.0:
						largo = minf(largo, tt_b[tt_b.size() - 1] * 0.5 - 0.5)
				var resto := _partir(br, maxf(largo, 0.5))
				br["malla"] = _malla_via(br, resto)
				if extremo == 1:
					resto.reverse()
				dib = resto
				extremos.append([br["x0"], false])
				if dib.size() < 2:
					break
				hay = true
				if not brazos.has(gi):
					brazos[gi] = []
				brazos[gi].append(br)
		if hay and dib.size() < 2:
			v["oculta_glorieta"] = true      # la vía entera es brazo de glorieta: va en su malla
			continue
		if hay and dib.size() >= 2:
			# anchos con la isleta de cada extremo recortado (distancia por la vía desde su cruce con el borde)
			var hw_v := float(v["ancho"]) * 0.5
			var acum := PackedFloat32Array()
			acum.resize(dib.size())
			for k in range(1, dib.size()):
				acum[k] = acum[k - 1] + dib[k - 1].distance_to(dib[k])
			var anchos := PackedFloat32Array()
			anchos.resize(dib.size())
			anchos.fill(2.0 * hw_v)
			for ex in extremos:
				if not ex[1]:
					continue
				var x0: Vector3 = ex[0]
				var kx := 0
				for k in dib.size():
					if dib[k].distance_squared_to(x0) < dib[kx].distance_squared_to(x0):
						kx = k
				var hacia := 1 if kx <= dib.size() / 2 else -1     # hacia fuera del anillo por la vía
				for k in dib.size():
					var t := (acum[k] - acum[kx]) * hacia
					var h := semiancho_isla(t) if t >= 0.0 else ISLA_ANCHO * 0.5
					anchos[k] = maxf(anchos[k], 2.0 * (hw_v + h))
			# sin talud en la boca de cada brazo (abocinamiento)
			var st_dib := PackedByteArray()
			st_dib.resize(dib.size())
			for ex in extremos:
				var x0: Vector3 = ex[0]
				for k in dib.size():
					if dib[k].distance_to(x0) <= ABOCINADO + 3.0:
						st_dib[k] = 1
			v["pts_dib"] = dib
			v["anchos_dib"] = anchos
			v["sin_talud_dib"] = st_dib
	# --- la ruta: sus bocas (Ruta.bocas_glorieta; la calzada ya va ensanchada por la isleta y oculta dentro del anillo)
	var mv_ruta := {}     # gi -> [mv, mi]: eje de los brazos de la ruta entre el corte y la isleta
	for r in rutas:
		for bo in r.bocas_glorieta:
			var gi: int = bo["g"]
			var inf: Dictionary = infos[gi]
			var i0: int = bo["i"]
			var dr: int = bo["dir"]
			var ia := clampi(i0 - dr, 0, r.n - 1)
			var poli := PackedVector3Array()
			var hs := PackedFloat32Array()
			var centros := PackedVector3Array()
			var k := ia
			var t := 0.0
			while k >= 0 and k < r.n and t < ISLA_LARGO + 12.0:
				poli.append(r.pts[k])
				var der := Vector3(-r.tang[k].z, 0.0, r.tang[k].x).normalized()
				centros.append(r.pts[k] + der * r.lateral_eje(k * r.paso))
				hs.append(r.isla[k])
				if k + dr >= 0 and k + dr < r.n:
					t += r.pts[k].distance_to(r.pts[k + dr])
				k += dr
			var br := _brazo_ruta(inf, poli, centros, hs, r.ancho[i0] * 0.5)
			if br.is_empty():
				continue
			br["ruta"] = true
			br["malla"] = _malla_ruta(r, inf, i0, dr, mv_ruta)
			br["elev"] = 0.0
			br["entra"] = 0
			if not brazos.has(gi):
				brazos[gi] = []
			brazos[gi].append(br)
	# --- abocinamientos, isletas y líneas de ceda, glorieta a glorieta
	var pc_anillo := {}
	var quedan := []
	for pc in Cruces.parches:
		if pc.has("gi"):
			pc_anillo[int(pc["gi"])] = pc
			quedan.append(pc)
			continue
		# discos de nodo dentro de un anillo (uniones de sus trozos de OSM, bocas de brazos ya recortados): sobran,
		# el anillo y los abocinamientos son la calzada; asomaban por fuera del borde como un círculo
		var c0: Vector3 = pc["c"]
		var dentro := false
		for gi in rej.get(Vector2i(floori(c0.x / 100.0), floori(c0.z / 100.0)), []):
			var inf: Dictionary = infos[gi]
			if absf(c0.y - (inf["c"] as Vector3).y) < 3.0 and fuera_de_borde(inf, c0) < 0.0:
				dentro = true
				break
		if dentro:
			st["discos_quitados"] = int(st.get("discos_quitados", 0)) + 1
		else:
			quedan.append(pc)
	Cruces.parches.clear()
	Cruces.parches.append_array(quedan)
	var contornos_gi := []
	for gi in brazos:
		var inf: Dictionary = infos[gi]
		var lista: Array = brazos[gi]
		# calzada gemela: la otra calzada de una autovía que la ruta ya lleva en su anchura (la M-406) asoma junto al
		# anillo como otra vía; era otro brazo con su isleta encima del de la ruta (cintas cruzadas). Fuera.
		var lista2 := []
		for br in lista:
			if not br["ruta"]:
				var gemela := false
				var o_mejor := {}
				for o in lista:
					if o["ruta"] and (br["u"] as Vector3).dot(o["u"]) > cos(deg_to_rad(45.0)):
						if (br["x0"] as Vector3).distance_to(o["x0"]) < float(br["w"]) + float(o["w"]) + 8.0 \
								or _acaba_en_ruta(rutas, inf, br["via"]):
							if not gemela or (br["u"] as Vector3).dot(o["u"]) > (br["u"] as Vector3).dot(o_mejor["u"]):
								o_mejor = o
							gemela = true
				if gemela:
					# su señal de ceda y su triángulo (senales.json) pasan a la entrada del brazo de la ruta (SenalesOsm)
					GlorietaMalla.gemelas.append({"x0": br["x0"], "ruta_x0": o_mejor["x0"], "u": o_mejor["u"],
							"w": float(o_mejor["w"]), "h": float(o_mejor["h"])})
					_ocultar_gemela(inf, br["via"])
					st["gemelas"] = int(st.get("gemelas", 0)) + 1
					continue
			lista2.append(br)
		lista = lista2
		st["brazos"] += lista.size()
		var de_ruta := false
		for br in lista:
			de_ruta = de_ruta or br["ruta"]
		var pc: Dictionary = pc_anillo.get(gi, {})
		var mv := PackedVector3Array()
		var mi := PackedInt32Array()
		var bocas := []      # [ángulo de, ángulo hasta] de cada brazo en el borde exterior
		var mallas := []
		for br in lista:
			var th0 := angulo(inf["c"], br["x0"])
			var o_min := 0.0
			var o_max := 0.0
			for lado in [-1.0, 1.0]:
				var u: Vector3 = br["u"]
				var th_lado := angulo(inf["c"], (br["x0"] as Vector3) + Vector3(-u.z, 0.0, u.x) * lado * float(br["w"]))
				var off := wrapf(th_lado - th0, -PI, PI)
				o_min = minf(o_min, off)
				o_max = maxf(o_max, off)
			bocas.append([th0 + o_min, th0 + o_max])
			if br.has("malla") and not (br["malla"] as Dictionary).is_empty():
				mallas.append(br["malla"])
		# UNA malla para anillo + brazos + abocinamientos (GlorietaMalla), con su línea de borde exterior
		var gm := GlorietaMalla.construir(inf, glorietas[gi], mallas)
		if gm.is_empty():
			st["mallas_fallidas"] = int(st.get("mallas_fallidas", 0)) + 1
			continue
		st["mallas"] = int(st.get("mallas", 0)) + 1
		var bi := []
		for br in lista:
			var pcorte: Vector3 = br["x0"] + (br["u"] as Vector3) * 30.0
			if br.has("malla") and not (br["malla"] as Dictionary).is_empty():
				pcorte = ((br["malla"]["izq"][0] as Vector3) + (br["malla"]["der"][0] as Vector3)) * 0.5
			bi.append([br["x0"], br["u"], br["ruta"], br["doble"], pcorte])
		GlorietaMalla.brazos_info[gi] = bi
		if pc.is_empty():
			pc = {"c": inf["c"], "borde": PackedVector3Array(), "gi": gi}
			Cruces.parches.append(pc)
		var cont: PackedVector2Array = gm["contorno"]
		var caja := PackedVector3Array()
		for q in cont:
			caja.append(Vector3(q.x, (inf["c"] as Vector3).y, q.y))
		pc["caja"] = caja
		pc["tris"] = [gm["verts"], gm["idx"]]
		pc["bordillo"] = gm["bordillo"]
		pc["talud"] = gm["talud"]
		pc["muestras"] = gm["muestras"]
		pc["ruta"] = de_ruta
		pc["bocas"] = bocas          # (para las pruebas: ángulos de las bocas)
		contornos_gi.append([cont, inf["c"]])
		# líneas: borde interior y separación de carriles del anillo, borde exterior del contorno, isletas, cedas, ejes
		if pc.has("interior"):
			_marcas_anillo_tipo(inf, pc, bocas, mv, mi, false)
		_juntar(mv, mi, gm["mv"], gm["mi"])
		if mv_ruta.has(gi):
			_juntar(mv, mi, mv_ruta[gi][0], mv_ruta[gi][1])
		for br in lista:
			if br["doble"] and _isla_marcas(br, mv, mi):
				st["isletas"] += 1
			if _linea_ceda(inf, br, mv, mi):
				st["cedas"] += 1
		if not mv.is_empty():
			(gm["alt"] as GlorietaMalla.Alturas).ajustar_marcas(mv)
			pc["marcas"] = [mv, mi]
	# discos de nodo que caen dentro de la malla de una glorieta: sobran (asomaban como círculos más claros)
	var rej_c := {}
	for k in contornos_gi.size():
		var cg: Vector3 = contornos_gi[k][1]
		var kc := Vector2i(floori(cg.x / 100.0), floori(cg.z / 100.0))
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var kk := kc + Vector2i(dx, dz)
				if not rej_c.has(kk):
					rej_c[kk] = []
				rej_c[kk].append(k)
	var quedan2 := []
	for o in Cruces.parches:
		if not o.has("gi"):
			var oc: Vector3 = o["c"]
			var fuera := true
			for k in rej_c.get(Vector2i(floori(oc.x / 100.0), floori(oc.z / 100.0)), []):
				if absf(oc.y - (contornos_gi[k][1] as Vector3).y) < 4.0 and Geometry2D.is_point_in_polygon(Vector2(oc.x, oc.z), contornos_gi[k][0]):
					fuera = false
					break
			if not fuera:
				st["discos_quitados"] = int(st.get("discos_quitados", 0)) + 1
				continue
		quedan2.append(o)
	Cruces.parches.clear()
	Cruces.parches.append_array(quedan2)
	for k in GlorietaMalla.ms:
		st["us_" + k] = GlorietaMalla.ms[k]
	return st


## Líneas del anillo (15 cm): borde exterior (a 30 cm del borde del carril) salvo en las bocas, borde interior y, con
## dos carriles, separación discontinua (3,5 m de trazo cada 12,5 m). Alturas: las del parche del anillo.
static func _marcas_anillo_tipo(inf: Dictionary, pc: Dictionary, bocas: Array, mv: PackedVector3Array, mi: PackedInt32Array, exterior := true) -> void:
	var fuera: PackedVector3Array = pc["borde"]
	var dentro: PackedVector3Array = pc["interior"]
	var n := fuera.size()
	if n < 6 or dentro.size() != n:
		return
	var hw: float = inf["hw"]
	var c: Vector3 = inf["c"]
	var lineas := [[hw - 0.3, 0.0, true], [-(hw - 0.3), 0.0, false]] if exterior else [[-(hw - 0.3), 0.0, false]]
	if hw >= 4.0:
		lineas.append([0.0, 12.5, false])
	for ln in lineas:
		var lat: float = ln[0]
		var periodo: float = ln[1]
		var con_bocas: bool = ln[2]
		var f := (lat + hw) / (2.0 * hw + BORDE_EXTRA)
		var s_acum := 0.0
		var prev := Vector3.ZERO
		var prev_ok := false
		for k in n + 1:
			var i := k % n
			var q := dentro[i].lerp(fuera[i], f)
			q.y += Cruces.PARCHE_BAJO + MARCA_Y
			if k > 0:
				s_acum += Vector2(q.x - prev.x, q.z - prev.z).length()
			var ok := true
			if periodo > 0.0 and fmod(s_acum, periodo) > 3.5:
				ok = false
			if con_bocas and ok:
				var th := angulo(c, q)
				for b in bocas:
					var a0: float = b[0]
					var a1: float = b[1]
					if wrapf(th - a0, 0.0, TAU) <= wrapf(a1 - a0, 0.0, TAU):
						ok = false
						break
			if ok and prev_ok:
				quad(prev, q, 0.075, mv, mi)
			prev = q
			prev_ok = ok


## ¿Es la vía (todos sus puntos) un trozo del propio anillo de OSM?
static func _es_trozo_anillo(inf: Dictionary, g: Dictionary, pts: PackedVector3Array) -> bool:
	var c: Vector3 = inf["c"]
	var umbral := maxf(2.5, float(g.get("hw_osm", g.get("hw", 3.2))) * 0.6)
	for q in pts:
		if absf(q.y - c.y) > 4.0:
			return false
		var dc := Vector2(q.x - c.x, q.z - c.z).length()
		if absf(dc - r_eje(inf, angulo(c, q))) > umbral:
			return false
	return true


## Corte de un brazo: poli va de dentro del anillo hacia fuera. Devuelve el brazo con la polilínea recortada (empieza
## donde la calzada queda entera sobre el anillo) remuestreada cada 2 m en los primeros metros, y sus anchos con isleta.
static func _brazo(inf: Dictionary, poli: PackedVector3Array, hw: float, doble: bool) -> Dictionary:
	# primer tramo que cruza el borde exterior
	var j := 0
	while j < poli.size() - 1 and fuera_de_borde(inf, poli[j + 1]) < 0.0:
		j += 1
	if j >= poli.size() - 1:
		return {}
	var x0 := _cruce(inf, poli[j], poli[j + 1], 0.0)
	# el brazo debe seguir fuera al menos 8 m (si no, solo roza el anillo)
	var largo_fuera := x0.distance_to(poli[j + 1])
	for k in range(j + 1, poli.size() - 1):
		largo_fuera += poli[k].distance_to(poli[k + 1])
	if largo_fuera < 8.0:
		return {}
	# remuestreo: desde dentro (corte) hasta ISLA_LARGO + 6 m fuera, cada 2 m; luego los puntos originales
	var u := _dir_fuera(poli, j, x0)
	var ro := r_borde(inf, angulo(inf["c"], x0))
	var hmax := hw + (ISLA_ANCHO * 0.5 if doble else 0.0)
	var sag := ro - sqrt(maxf(ro * ro - hmax * hmax, 0.0)) + 0.5
	var corte := x0 - u * minf(sag + 0.6, 6.0)
	corte.y = x0.y
	var nuevo := PackedVector3Array([corte, x0])
	var tt := PackedFloat32Array([-corte.distance_to(x0), 0.0])
	var t := 0.0
	var prev := x0
	var k := j + 1
	var objetivo := 2.0
	while k < poli.size():
		var seg := prev.distance_to(poli[k])
		if t + seg >= objetivo and objetivo <= ISLA_LARGO + 6.0:
			var q := prev.lerp(poli[k], (objetivo - t) / maxf(seg, 1e-4))
			nuevo.append(q)
			tt.append(objetivo)
			t = objetivo
			prev = q
			objetivo += 2.0
			continue
		t += seg
		prev = poli[k]
		if t > ISLA_LARGO + 6.0 or k == poli.size() - 1:
			if nuevo[nuevo.size() - 1].distance_to(poli[k]) > 0.3:
				nuevo.append(poli[k])
				tt.append(t)
		k += 1
	var anchos := PackedFloat32Array()
	var hs := PackedFloat32Array()
	for q in tt.size():
		var h := semiancho_isla(maxf(tt[q], 0.0)) if doble else 0.0
		hs.append(h)
		anchos.append(2.0 * (hw + h))
	return {"x0": x0, "u": u, "w": hmax, "h": hs[1], "doble": doble, "poli": nuevo, "anchos": anchos,
			"centros": nuevo, "hs": hs, "tt": tt}


## Brazo de la ruta (ya ensanchada y oculta dentro del anillo por Ruta): solo su geometría para abocinados y marcas
static func _brazo_ruta(inf: Dictionary, poli: PackedVector3Array, centros: PackedVector3Array, hs: PackedFloat32Array, hw: float) -> Dictionary:
	if poli.size() < 3:
		return {}
	var x0 := _cruce(inf, poli[0], poli[1], 0.0)
	var u := _dir_fuera(poli, 0, x0)
	var tt := PackedFloat32Array([-x0.distance_to(poli[0]), poli[1].distance_to(x0)])
	for k in range(2, poli.size()):
		tt.append(tt[k - 1] + poli[k - 1].distance_to(poli[k]))
	return {"x0": x0, "u": u, "w": hw, "h": hs[1] if hs.size() > 1 else 0.0, "doble": hs.size() > 1 and hs[1] > 0.1,
			"poli": poli, "centros": centros, "hs": hs, "tt": tt}


static func _cruce(inf: Dictionary, a: Vector3, b: Vector3, nivel: float) -> Vector3:
	var lo := 0.0
	var hi := 1.0
	for _it in 22:
		var m := (lo + hi) * 0.5
		if fuera_de_borde(inf, a.lerp(b, m)) < nivel:
			lo = m
		else:
			hi = m
	return a.lerp(b, (lo + hi) * 0.5)


## Dirección hacia fuera del brazo: de x0 al punto que está ~8 m más allá por la polilínea
static func _dir_fuera(poli: PackedVector3Array, j: int, x0: Vector3) -> Vector3:
	var t := 0.0
	var prev := x0
	var q := poli[mini(j + 1, poli.size() - 1)]
	for k in range(j + 1, poli.size()):
		t += prev.distance_to(poli[k])
		prev = poli[k]
		q = poli[k]
		if t >= 8.0:
			break
	var u := Vector3(q.x - x0.x, 0.0, q.z - x0.z)
	return u.normalized() if u.length() > 0.1 else Vector3.RIGHT


## Abocinamiento de un lado del brazo (lado +1: a la derecha mirando hacia fuera): une el borde del brazo con el borde
## exterior del anillo con una curva (Bézier cuadrática con control en la esquina), como el bordillo de una glorieta real.
static func _abocinado(cr: Cruces, inf: Dictionary, br: Dictionary, lado: float, lista: Array) -> Dictionary:
	var c: Vector3 = inf["c"]
	var u: Vector3 = br["u"]
	var x0: Vector3 = br["x0"]
	var nrm := Vector3(-u.z, 0.0, u.x) * lado
	var w: float = br["w"]
	var e0 := x0 + nrm * w
	# esquina: el borde del brazo corta el borde exterior del anillo
	var a := e0 - u * (w + 6.0)
	var b := e0 + u * (w + 6.0)
	if fuera_de_borde(inf, a) >= 0.0 or fuera_de_borde(inf, b) <= 0.0:
		return {}
	var x := _cruce(inf, a, b, 0.0)
	var ro := r_borde(inf, angulo(c, x))
	var th_x := angulo(c, x)
	var sgn := signf(wrapf(angulo(c, x0 + nrm) - angulo(c, x0), -PI, PI))
	if sgn == 0.0:
		return {}
	# hueco hasta el brazo vecino por ese lado
	var hueco := 1e9
	for o in lista:
		if is_same(o, br):
			continue
		var d_th := wrapf((angulo(c, o["x0"]) - th_x) * sgn, 0.0, TAU)
		hueco = minf(hueco, d_th * ro - float(o["w"]))
	var lf := clampf(hueco * 0.45, 0.0, ABOCINADO)
	if lf < 1.5:
		return {}
	var e := x + u * lf
	var th_r := th_x + sgn * lf / ro
	var rp := punto_borde(inf, th_r)
	var borde := PackedVector3Array()
	var y_ref := x0.y
	for k in 9:
		var f := float(k) / 8.0
		var q := e.lerp(x, f).lerp(x.lerp(rp, f), f)
		borde.append(q)
	var pasos := maxi(2, int(lf / 1.0))
	for k in range(1, pasos):
		borde.append(punto_borde(inf, th_r - sgn * lf / ro * float(k) / float(pasos)))
	for k in borde.size():
		var q := borde[k]
		var h := cr._h_asfalto(q.x, q.z, y_ref)
		borde[k] = Vector3(q.x, (y_ref if is_nan(h) else h) - Cruces.PARCHE_BAJO, q.z)
	var hx := cr._h_asfalto(x.x, x.z, y_ref)
	var centro := Vector3(x.x, (y_ref if is_nan(hx) else hx) - Cruces.PARCHE_BAJO, x.z)
	# mismo sentido de giro que los discos (área > 0 en x, z)
	var area := 0.0
	var m := borde.size()
	for k in m:
		area += borde[k].x * borde[(k + 1) % m].z - borde[(k + 1) % m].x * borde[k].z
	area += 0.0
	var area_c := 0.0
	for k in m:
		var p0 := borde[k] - centro
		var p1 := borde[(k + 1) % m] - centro
		area_c += p0.x * p1.z - p1.x * p0.z
	if area_c < 0.0:
		borde.reverse()
	return {"c": centro, "borde": borde, "ruta": false, "abocinado": true, "th_fin": th_r}


## Isleta separadora pintada: contorno (15 cm), punta cerrada junto al anillo y cebreado oblicuo cada 2 m
static func _isla_marcas(br: Dictionary, mv: PackedVector3Array, mi: PackedInt32Array) -> bool:
	var cen: PackedVector3Array = br["centros"]
	var hs: PackedFloat32Array = br["hs"]
	var tt: PackedFloat32Array = br["tt"]
	var elev: float = br["elev"] + MARCA_Y
	var izq := PackedVector3Array()
	var der := PackedVector3Array()
	var tl := PackedFloat32Array()
	for k in cen.size():
		if tt[k] < ISLA_HUECO or hs[k] < 0.05:
			continue
		var k1 := mini(k + 1, cen.size() - 1)
		var k0 := maxi(k - 1, 0)
		var t := cen[k1] - cen[k0]
		var nrm := Vector3(-t.z, 0.0, t.x).normalized()
		var up := Vector3(0.0, elev, 0.0)
		izq.append(cen[k] - nrm * hs[k] + up)
		der.append(cen[k] + nrm * hs[k] + up)
		tl.append(tt[k])
	if izq.size() < 3:
		return false
	for k in izq.size() - 1:
		quad(izq[k], izq[k + 1], 0.075, mv, mi)
		quad(der[k], der[k + 1], 0.075, mv, mi)
	quad(izq[0], der[0], 0.075, mv, mi)           # punta junto al anillo
	# cebreado: franjas oblicuas de 30 cm, una cada 2 m, donde la isleta tiene anchura
	for k in izq.size() - 1:
		if izq[k].distance_to(der[k]) < 0.5:
			continue
		var a := izq[k].lerp(der[k], 0.1)
		var b := izq[k + 1].lerp(der[k + 1], 0.9)
		quad(a, b, 0.15, mv, mi)
	return true


## Línea de ceda el paso (M-4.2: trazos de 0,8 m cada 1,2 m, 40 cm de ancho) sobre el carril de entrada, en el borde
## exterior del anillo. Doble sentido: entre la isleta y el borde derecho del que entra; un solo sentido: si entra, toda.
static func _linea_ceda(inf: Dictionary, br: Dictionary, mv: PackedVector3Array, mi: PackedInt32Array) -> bool:
	var c: Vector3 = inf["c"]
	var u: Vector3 = br["u"]
	var x0: Vector3 = br["x0"]
	var nrm := Vector3(-u.z, 0.0, u.x)      # derecha mirando hacia fuera = izquierda del que entra
	var w: float = br["w"]
	var o0 := 0.0
	var o1 := 0.0
	if br["doble"]:
		o0 = float(br["h"]) + 0.15
		o1 = w - 0.3
	elif int(br.get("entra", 0)) == 1:
		o0 = -w + 0.3
		o1 = w - 0.3
	else:
		return false
	if o1 - o0 < 1.0:
		return false
	# el carril de entrada queda a la izquierda de "hacia fuera" (derecha del que entra)
	var p0 := x0 - nrm * o0
	var p1 := x0 - nrm * o1
	var th0 := angulo(c, p0)
	var th1 := angulo(c, p1)
	var span := wrapf(th1 - th0, -PI, PI)
	var ro := r_borde(inf, th0)
	var largo := absf(span) * ro
	var y := x0.y + float(br["elev"]) + MARCA_Y + 0.005
	var s := 0.0
	while s < largo - 0.2:
		var s1 := minf(s + 0.8, largo)
		var qa := punto_borde(inf, th0 + span * s / largo, 0.45)
		var qb := punto_borde(inf, th0 + span * s1 / largo, 0.45)
		qa.y = y
		qb.y = y
		quad(qa, qb, 0.2, mv, mi)
		s += 1.2
	return true


## Junta marcas (vértices e índices) en mv/mi
static func _juntar(mv: PackedVector3Array, mi: PackedInt32Array, v2: PackedVector3Array, i2: PackedInt32Array) -> void:
	var b0 := mv.size()
	mv.append_array(v2)
	for t in i2:
		mi.append(b0 + t)


## Parte un brazo de vía a 'largo' m del borde del anillo: el brazo se queda con lo de dentro (para la malla de la
## glorieta) y devuelve lo de fuera, que empieza en el punto de corte (la vía se sigue dibujando desde ahí)
static func _partir(br: Dictionary, largo: float) -> PackedVector3Array:
	var poli: PackedVector3Array = br["poli"]
	var tt: PackedFloat32Array = br["tt"]
	var anchos: PackedFloat32Array = br["anchos"]
	var hs: PackedFloat32Array = br["hs"]
	var p2 := PackedVector3Array()
	var a2 := PackedFloat32Array()
	var h2 := PackedFloat32Array()
	var t2 := PackedFloat32Array()
	var resto := PackedVector3Array()
	for k in poli.size():
		if resto.is_empty() and (tt[k] < largo - 0.05 or k == 0):
			p2.append(poli[k])
			a2.append(anchos[k])
			h2.append(hs[k])
			t2.append(tt[k])
		elif resto.is_empty():
			var f := clampf((largo - tt[k - 1]) / maxf(tt[k] - tt[k - 1], 1e-4), 0.0, 1.0)
			var q := poli[k - 1].lerp(poli[k], f)
			p2.append(q)
			a2.append(lerpf(anchos[k - 1], anchos[k], f))
			h2.append(semiancho_isla(largo) if br["doble"] else 0.0)
			t2.append(largo)
			resto.append(q)
			if poli[k].distance_to(q) > 0.05:
				resto.append(poli[k])
		else:
			resto.append(poli[k])
	br["poli"] = p2
	br["centros"] = p2
	br["anchos"] = a2
	br["hs"] = h2
	br["tt"] = t2
	return resto


## Bordes del trozo de vía que va en la malla (del corte hacia el anillo), con la altura de la franja de la vía
static func _malla_via(br: Dictionary, resto: PackedVector3Array) -> Dictionary:
	var poli: PackedVector3Array = br["poli"]
	var anchos: PackedFloat32Array = br["anchos"]
	var izq := PackedVector3Array()
	var der := PackedVector3Array()
	var n := poli.size()
	if n < 2:
		return {}
	for kk in n:
		var k := n - 1 - kk
		var t: Vector3
		if k == n - 1 and resto.size() >= 2:
			t = resto[1] - resto[0]          # como la franja de la vía en su primer punto
		else:
			t = poli[mini(k + 1, n - 1)] - poli[maxi(k - 1, 0)]
		var nrm := Vector3(-t.z, 0.0, t.x).normalized()
		var h := anchos[k] * 0.5
		var up := Vector3(0.0, 0.04, 0.0)
		izq.append(poli[k] - nrm * h + up)
		der.append(poli[k] + nrm * h + up)
	return {"izq": izq, "der": der, "ruta": false, "corte": [Vector2(izq[0].x, izq[0].z), Vector2(der[0].x, der[0].z)]}


## Brazo de la ruta en la malla: de la muestra a GlorietaMalla.LARGO m del borde (o la mitad del camino a la siguiente
## glorieta / el final de la ruta) hasta dentro del anillo. La franja de la ruta se oculta en ese trozo (Ruta.oculto).
## mv_ruta[gi] recibe el eje entre el corte y la punta de la isleta.
static func _malla_ruta(r: Ruta, inf: Dictionary, i0: int, dr: int, mv_ruta: Dictionary) -> Dictionary:
	var largo := GlorietaMalla.LARGO
	var kk := i0
	var tl := 0.0
	while tl < largo + 0.5:
		if kk + dr < 0 or kk + dr >= r.n:
			largo = minf(largo, tl)
			break
		if r.dentro_glorieta[kk + dr] == 1 and fuera_de_borde(inf, r.pts[kk + dr]) > 3.0:
			largo = minf(largo, tl * 0.5)       # otra glorieta: a medias
			break
		tl += r.pts[kk].distance_to(r.pts[kk + dr])
		kk += dr
	var ic := i0
	var tc := 0.0
	while tc < largo - 0.01 and ic + dr >= 0 and ic + dr < r.n:
		tc += r.pts[ic].distance_to(r.pts[ic + dr])
		ic += dr
	# hacia dentro: la franja se oculta hasta el arco (ya estaba oculta dentro del anillo)
	var iin := i0
	var cuenta := 0
	while iin - dr >= 0 and iin - dr < r.n and cuenta < 25 and r.anillo[iin] == 0:
		iin -= dr
		cuenta += 1
	if ic == i0:
		return {}
	for k in range(mini(ic, iin), maxi(ic, iin)):
		r.oculto[k] = 1
	var izq := PackedVector3Array()
	var der := PackedVector3Array()
	var k := ic
	var up := Vector3(0.0, GlorietaMalla.ELEV, 0.0)
	while true:
		var dq := _der_ruta(r, k) * (r.ancho[k] * 0.5)
		izq.append(r.pts[k] - dq + up)
		der.append(r.pts[k] + dq + up)
		if k == i0:
			break
		k -= dr
	# y desde la boca, recto hacia dentro hasta que la sección entera esté sobre el anillo (la ruta, que sobre el arco
	# es más ancha que el anillo, no se usa: asomaba por fuera del anillo como una cuña)
	var u := Vector3(r.pts[i0].x - r.pts[i0 - dr].x, 0.0, r.pts[i0].z - r.pts[i0 - dr].z).normalized() if i0 - dr >= 0 and i0 - dr < r.n else Vector3.ZERO
	if u != Vector3.ZERO:
		var hw0 := r.ancho[i0] * 0.5
		var ro := r_borde(inf, angulo(inf["c"], r.pts[i0]))
		var sag := ro - sqrt(maxf(ro * ro - hw0 * hw0, 0.0)) + 1.5
		var dq := _der_ruta(r, i0) * hw0
		var cen := r.pts[i0] + up
		var paso := maxf(fuera_de_borde(inf, cen), 0.0) + sag
		izq.append(cen - u * paso - dq)
		der.append(cen - u * paso + dq)
	# eje continuo desde el corte hasta la punta de la isleta (la franja de la ruta lo lleva hasta el corte)
	var gi := -1
	for bo in r.bocas_glorieta:
		if int(bo["i"]) == i0 and int(bo["dir"]) == dr:
			gi = int(bo["g"])
	if gi >= 0:
		if not mv_ruta.has(gi):
			mv_ruta[gi] = [PackedVector3Array(), PackedInt32Array()]
		k = ic
		while k != i0 and r.isla[k - dr] < 0.05:
			var a := r.pts[k] + _der_ruta(r, k) * r.lateral_eje(k * r.paso) + Vector3(0.0, GlorietaMalla.ELEV + GlorietaMalla.MARCA, 0.0)
			var b := r.pts[k - dr] + _der_ruta(r, k - dr) * r.lateral_eje((k - dr) * r.paso) + Vector3(0.0, GlorietaMalla.ELEV + GlorietaMalla.MARCA, 0.0)
			quad(a, b, 0.075, mv_ruta[gi][0], mv_ruta[gi][1])
			k -= dr
	return {"izq": izq, "der": der, "ruta": true, "corte": [Vector2(izq[0].x, izq[0].z), Vector2(der[0].x, der[0].z)]}


## Derecha horizontal de la ruta en la muestra i (como la franja: diferencia centrada)
static func _der_ruta(r: Ruta, i: int) -> Vector3:
	var t := r.pts[mini(i + 1, r.n - 1)] - r.pts[maxi(i - 1, 0)]
	return Vector3(-t.z, 0.0, t.x).normalized()


## Calzada gemela de la ruta junto a una glorieta: no se dibuja junto al anillo (corta, entera fuera)
static func _ocultar_gemela(inf: Dictionary, v: Dictionary) -> void:
	v["gemela"] = true   # Superficie: lo que no se dibuja no es calzada
	var pts: PackedVector3Array = v.get("pts_dib", v["pts"])
	var largo := 0.0
	for k in range(1, pts.size()):
		largo += pts[k - 1].distance_to(pts[k])
	if largo < 300.0:
		v["oculta_glorieta"] = true
		return
	var lim := GlorietaMalla.LARGO + 15.0
	var a := 0
	while a < pts.size() and fuera_de_borde(inf, pts[a]) < lim:
		a += 1
	var b := pts.size() - 1
	while b > a and fuera_de_borde(inf, pts[b]) < lim:
		b -= 1
	if b - a < 1:
		v["oculta_glorieta"] = true
		return
	v["pts_dib"] = pts.slice(a, b + 1)
	if v.has("anchos_dib"):
		v["anchos_dib"] = (v["anchos_dib"] as PackedFloat32Array).slice(a, b + 1)
	if v.has("sin_talud_dib"):
		v["sin_talud_dib"] = (v["sin_talud_dib"] as PackedByteArray).slice(a, b + 1)


## ¿Acaba la vía (por el extremo lejos del anillo) dentro de la calzada de una ruta? (la otra calzada de la autovía,
## que Cruces ya cortó donde la ruta la tapa)
static func _acaba_en_ruta(rutas: Array, inf: Dictionary, v: Dictionary) -> bool:
	var pts: PackedVector3Array = v.get("pts_dib", v["pts"])
	if pts.size() < 2:
		return true
	var q := pts[0] if fuera_de_borde(inf, pts[0]) > fuera_de_borde(inf, pts[pts.size() - 1]) else pts[pts.size() - 1]
	var c: Vector3 = inf["c"]
	for rr in rutas:
		var r: Ruta = rr
		for i in r.n:
			var p := r.pts[i]
			if absf(p.x - c.x) > 300.0 or absf(p.z - c.z) > 300.0:
				continue
			if Vector2(p.x - q.x, p.z - q.z).length() < r.ancho[i] * 0.5 + 2.5 and absf(p.y - q.y) < 3.0:
				return true
	return false
