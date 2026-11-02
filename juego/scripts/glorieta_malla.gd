## Glorieta en UNA sola superficie, sin solapes: el anillo, los primeros metros de cada brazo (con su isleta) y los
## abocinamientos redondeados que unen cada brazo con el anillo, triangulados juntos en una malla por glorieta.
## Sustituye, en esa zona, a la franja de la ruta, a las de las vías, a los parches de abocinado y a la banda del anillo:
## antes eran 4-6 mallas superpuestas a distinta altura y con distinto asfalto, y desde el coche se veían cintas que se
## cruzaban, líneas en diagonal y cuadrados más claros. La línea de borde exterior sale del contorno de la malla: sigue
## el borde de cada brazo, el abocinamiento y el anillo sin cruzar nunca un carril.
class_name GlorietaMalla
extends RefCounted

const LARGO := 31.0        # m de cada brazo, desde el borde del anillo, que forman parte de la malla de la glorieta
const ABOC := 6.0          # radio de los abocinamientos (cierre del contorno)
const ELEV := 0.05         # la calzada, 5 cm sobre el eje (como las franjas de la ruta)
const MARCA := 0.035       # las líneas, sobre la calzada
const SECT := 144
const PASO_BORDE := 1.2
const PASO_REJILLA := 6.0
const CELDA_H := 4.0

static var tris_sup: Array = []      # PackedVector3Array (a, b, c, a, b, c...) por glorieta, para Superficie
static var contornos: Array = []     # {gi, poli (PackedVector2Array), c} por glorieta (pruebas)
static var ms: Dictionary = {}           # tiempos acumulados por fase (µs)
static var brazos_info: Dictionary = {}   # gi -> [[x0, u, de la ruta, doble sentido, corte]] (pruebas)
static var gemelas: Array = []            # calzadas gemelas quitadas: {x0, ruta_x0, u, w, h} (SenalesOsm)


static func reiniciar() -> void:
	tris_sup = []
	contornos = []
	brazos_info = {}
	gemelas = []
	ms = {}


static func _t(clave: String, t0: int) -> int:
	var t1 := Time.get_ticks_usec()
	ms[clave] = int(ms.get(clave, 0)) + (t1 - t0)
	return t1


## Polígono 2D de un brazo: der (desde el corte hacia el anillo) + izq al revés
static func _poli_brazo(bm: Dictionary) -> PackedVector2Array:
	var izq: PackedVector3Array = bm["izq"]
	var der: PackedVector3Array = bm["der"]
	var p := PackedVector2Array()
	for q in der:
		p.append(Vector2(q.x, q.z))
	for k in range(izq.size() - 1, -1, -1):
		p.append(Vector2(izq[k].x, izq[k].z))
	return p


static func _area(p: PackedVector2Array) -> float:
	var a := 0.0
	var n := p.size()
	for k in n:
		a += p[k].x * p[(k + 1) % n].y - p[(k + 1) % n].x * p[k].y
	return a * 0.5


static func _mayor(lista: Array) -> PackedVector2Array:
	var mejor := PackedVector2Array()
	var am := -1.0
	for p in lista:
		var a := absf(_area(p))
		if a > am:
			am = a
			mejor = p
	return mejor


## Contorno remuestreado cada 'paso' m (cerrado)
static func _remuestrear(p: PackedVector2Array, paso: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := p.size()
	for k in n:
		var a := p[k]
		var b := p[(k + 1) % n]
		var l := a.distance_to(b)
		var m := maxi(1, ceili(l / paso))
		for j in m:
			out.append(a.lerp(b, float(j) / float(m)))
	return out


## Distancia de q al segmento ab
static func _dist_seg(q: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((q - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
	return q.distance_to(a + ab * t)


## Construye la malla de la glorieta. brazos: [{izq, der (PackedVector3Array, del corte hacia el anillo, alturas de
## calzada), ruta (bool), corte (Vector2 a, Vector2 b)}]. Devuelve {} si no se pudo.
static func construir(inf: Dictionary, g: Dictionary, brazos: Array) -> Dictionary:
	var c: Vector3 = inf["c"]
	var hw: float = inf["hw"]
	# alturas (rápidas): anillo por sectores de 5° (eje de OSM) y, fuera del anillo, el eje del brazo de ese sector;
	# los vértices de los brazos conservan su altura exacta (empalme con la franja de la ruta o de la vía)
	var alt := Alturas.new()
	alt.preparar(inf, g, brazos)
	var t0 := Time.get_ticks_usec()
	# disco exterior del anillo e isla central
	var disco := PackedVector2Array()
	var isla := PackedVector2Array()
	for k in SECT:
		var th := TAU * float(k) / float(SECT)
		var pb := GlorietaTipo.punto_borde(inf, th)
		disco.append(Vector2(pb.x, pb.z))
		var ri := GlorietaTipo.r_eje(inf, th) - hw
		isla.append(Vector2(c.x + cos(th) * ri, c.z - sin(th) * ri))
	var ro_max := 0.0
	for p in disco:
		ro_max = maxf(ro_max, p.distance_to(Vector2(c.x, c.z)))
	# unión: disco + brazos
	var cont := disco
	var usados := []
	for bm in brazos:
		var pb := _poli_brazo(bm)
		if pb.size() < 4:
			continue
		var res: Array = Geometry2D.merge_polygons(cont, pb)
		var m := _mayor(res)
		if absf(_area(m)) < absf(_area(cont)) + 1.0:
			continue
		cont = m
		usados.append(bm)
	# abocinamientos: cierre (dilatar y erosionar ABOC m) de anillo + cada brazo por separado, solo junto al anillo:
	# así no se rellena el hueco entre dos brazos vecinos (las dos calzadas de una autovía que llegan separadas)
	var lim := PackedVector2Array()
	var r_lim := ro_max + ABOC * 2.2
	for k in 72:
		var th := TAU * float(k) / 72.0
		lim.append(Vector2(c.x + cos(th) * r_lim, c.z + sin(th) * r_lim))
	for bm in usados:
		# solo la zona de la boca (polígonos pequeños: el cierre es mucho más barato)
		var izq: PackedVector3Array = bm["izq"]
		var der: PackedVector3Array = bm["der"]
		var x0 := Vector2((izq[izq.size() - 1].x + der[der.size() - 1].x) * 0.5, (izq[izq.size() - 1].z + der[der.size() - 1].z) * 0.5)
		var rb := Vector2(izq[izq.size() - 1].x - der[der.size() - 1].x, izq[izq.size() - 1].z - der[der.size() - 1].z).length() * 0.5 + ABOC * 3.0 + 2.0
		var zona := PackedVector2Array()
		for k in 32:
			zona.append(x0 + Vector2(cos(TAU * k / 32.0), sin(TAU * k / 32.0)) * rb)
		var loc := _mayor(Geometry2D.intersect_polygons(disco, zona))
		var uno := _mayor(Geometry2D.merge_polygons(loc, _mayor(Geometry2D.intersect_polygons(_poli_brazo(bm), zona))))
		var dil := _mayor(Geometry2D.offset_polygon(uno, ABOC, Geometry2D.JOIN_ROUND))
		var cer := _mayor(Geometry2D.offset_polygon(dil, -ABOC, Geometry2D.JOIN_ROUND))
		for pz in Geometry2D.intersect_polygons(cer, lim):
			if absf(_area(pz)) < 1.0:
				continue
			var m2 := _mayor(Geometry2D.merge_polygons(cont, pz))
			if absf(_area(m2)) >= absf(_area(cont)):
				cont = m2
	t0 = _t("union", t0)
	# triangulación: el contorno menos la isla central, partido en dos mitades por una recta que pasa por el centro
	# (cada mitad queda sin agujero) y triangulado por orejas; solo vértices de los bordes (como la banda del anillo)
	var cc := Vector2(c.x, c.z)
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var sup := PackedVector3Array()
	var grande := (ro_max + LARGO + 60.0) * 2.0
	var mitades := [
		PackedVector2Array([cc + Vector2(-grande, 0.0), cc + Vector2(grande, 0.0), cc + Vector2(grande, grande), cc + Vector2(-grande, grande)]),
		PackedVector2Array([cc + Vector2(-grande, 0.0), cc + Vector2(-grande, -grande), cc + Vector2(grande, -grande), cc + Vector2(grande, 0.0)])]
	for mitad in mitades:
		for pza in Geometry2D.intersect_polygons(cont, mitad):
			if Geometry2D.is_polygon_clockwise(pza) != Geometry2D.is_polygon_clockwise(cont) and absf(_area(pza)) < 0.5:
				continue
			for pz2 in Geometry2D.clip_polygons(pza, isla):
				if absf(_area(pz2)) < 0.05:
					continue
				var tri := Geometry2D.triangulate_polygon(pz2)
				if tri.is_empty():
					tri = _delaunay_filtrado(pz2)
					ms["piezas_delaunay"] = int(ms.get("piezas_delaunay", 0)) + 1
				var b0 := verts.size()
				for q in pz2:
					verts.append(Vector3(q.x, alt.h(q.x, q.y, c.y + ELEV), q.y))
				for t in range(0, tri.size(), 3):
					var a := pz2[tri[t]]
					var b := pz2[tri[t + 1]]
					var d := pz2[tri[t + 2]]
					var cr := (b.x - a.x) * (d.y - a.y) - (b.y - a.y) * (d.x - a.x)
					if absf(cr) < 1e-6:
						continue
					var i0t := b0 + tri[t]
					var i1t := b0 + tri[t + 1]
					var i2t := b0 + tri[t + 2]
					# cara de arriba hacia arriba (como Cruces/MapaStreaming.tri_parche)
					if cr < 0.0:
						idx.append_array([i0t, i2t, i1t])
					else:
						idx.append_array([i0t, i1t, i2t])
					sup.append_array([verts[i0t], verts[i1t], verts[i2t]])
	t0 = _t("triangulos", t0)
	if idx.is_empty():
		return {}
	# muestras para bajar el terreno: los vértices y el contorno 80 cm hacia fuera
	var muestras := PackedVector3Array()
	for q in verts:
		# el borde de la isla central no: el bordillo tapa la junta (bajar ahí el terreno dejaba dientes)
		var th := atan2(-(q.z - c.z), q.x - c.x)
		if absf(Vector2(q.x - c.x, q.z - c.z).length() - (GlorietaTipo.r_eje(inf, th) - hw)) < 0.4:
			continue
		muestras.append(q - Vector3(0.0, ELEV + Cruces.MARGEN_TERRENO, 0.0))
	# bordillo de la isla central: cara vertical de 13 cm junto al asfalto, 30 cm de ancho, y otra cara hacia la isla
	var bv := PackedVector3Array()
	var bn := PackedVector3Array()
	var bi := PackedInt32Array()
	for k in 97:
		var th := TAU * float(k % 96) / 96.0
		var ri := GlorietaTipo.r_eje(inf, th) - hw
		var u := Vector2(cos(th), -sin(th))
		var x1 := Vector2(c.x, c.z) + u * ri
		var x2 := Vector2(c.x, c.z) + u * (ri - 0.3)
		var h := alt._anillo(th)
		var n3 := Vector3(u.x, 0.0, u.y)
		bv.append_array([Vector3(x1.x, h - 0.05, x1.y), Vector3(x1.x, h + 0.13, x1.y), Vector3(x2.x, h + 0.13, x2.y), Vector3(x2.x, h - 0.4, x2.y)])
		bn.append_array([n3, (n3 + Vector3.UP).normalized(), Vector3.UP, -n3])
		if k > 0:
			var a0 := (k - 1) * 4
			var b0 := k * 4
			for f in 3:
				bi.append_array([a0 + f, b0 + f, a0 + f + 1, a0 + f + 1, b0 + f, b0 + f + 1])
	# rejilla interior (abocinamientos y brazos anchos: ahí no hay ninguna vía de OSM que baje el terreno)
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for q in cont:
		mn = Vector2(minf(mn.x, q.x), minf(mn.y, q.y))
		mx = Vector2(maxf(mx.x, q.x), maxf(mx.y, q.y))
	var gx := mn.x + PASO_REJILLA * 0.5
	while gx < mx.x:
		var gz := mn.y + PASO_REJILLA * 0.5
		while gz < mx.y:
			var q := Vector2(gx, gz)
			# dentro del anillo ya bajan el terreno sus trozos de OSM (Cruces._excavar_terreno recorre todas las vías)
			if q.distance_to(cc) > ro_max - 0.5 and Geometry2D.is_point_in_polygon(q, cont):
				muestras.append(Vector3(q.x, alt.h(q.x, q.y, c.y + ELEV) - ELEV - Cruces.MARGEN_TERRENO, q.y))
			gz += PASO_REJILLA
		gx += PASO_REJILLA
	var fuera := _mayor(Geometry2D.offset_polygon(cont, Cruces.ARCEN_TERRENO, Geometry2D.JOIN_ROUND))
	for q in _remuestrear(fuera, 4.0):
		muestras.append(Vector3(q.x, alt.h(q.x, q.y, c.y + ELEV) - ELEV - Cruces.MARGEN_TERRENO, q.y))
	# línea de borde exterior: el contorno 25 cm hacia dentro, salvo en el corte de cada brazo (sigue la franja) y,
	# en los brazos de las vías (sin líneas), lejos del anillo
	t0 = _t("muestras_bordillo", t0)
	var mv := PackedVector3Array()
	var mi := PackedInt32Array()
	var lin := _mayor(Geometry2D.offset_polygon(cont, -0.25, Geometry2D.JOIN_ROUND))
	var lr := _remuestrear(lin, 2.0)
	var nl := lr.size()
	var okl := PackedByteArray()
	okl.resize(nl)
	var pol_ruta := []
	for bm in usados:
		if bm["ruta"]:
			pol_ruta.append(_mayor(Geometry2D.offset_polygon(_poli_brazo(bm), 1.0)))
	for k in nl:
		var q := lr[k]
		var ok := true
		for bm in usados:
			var ct: Array = bm["corte"]
			if _dist_seg(q, ct[0], ct[1]) < 1.0:
				ok = false
				break
		if ok and q.distance_to(cc) > ro_max + ABOC * 2.0 + 2.0:
			var en_ruta := false
			for pr in pol_ruta:
				if Geometry2D.is_point_in_polygon(q, pr):
					en_ruta = true
					break
			ok = en_ruta
		okl[k] = 1 if ok else 0
	for k in nl:
		var k1 := (k + 1) % nl
		if okl[k] == 1 and okl[k1] == 1:
			var a := lr[k]
			var b := lr[k1]
			GlorietaTipo.quad(Vector3(a.x, c.y, a.y), Vector3(b.x, c.y, b.y), 0.075, mv, mi)     # altura: Alturas.ajustar_marcas
	# talud alrededor del contorno (como las franjas de las vías: faldón de grava 2 m hacia fuera y 2,4 m hacia abajo,
	# que tapa el escalón con el terreno), salvo en el corte de cada brazo, donde sigue la franja con el suyo
	var tv := PackedVector3Array()
	var tn := PackedVector3Array()
	var tuv := PackedVector2Array()
	var ti := PackedInt32Array()
	var cr2 := _remuestrear(cont, 2.0)
	var ncr := cr2.size()
	var prev_ok := false
	for k in ncr + 1:
		var q := cr2[k % ncr]
		var t := cr2[(k + 1) % ncr] - cr2[(k - 1 + ncr) % ncr]
		var nrm := Vector2(t.y, -t.x).normalized()
		if Geometry2D.is_point_in_polygon(q + nrm * 0.3, cont):
			nrm = -nrm
		var ok := true
		for bm in usados:
			var ct: Array = bm["corte"]
			if _dist_seg(q, ct[0], ct[1]) < 0.5:
				ok = false
				break
		var hq := alt.h(q.x, q.y, c.y + ELEV) - 0.02
		var b0 := tv.size()
		tv.append_array([Vector3(q.x, hq, q.y), Vector3(q.x + nrm.x * 2.0, hq - 2.4, q.y + nrm.y * 2.0)])
		var n3 := (Vector3.UP + Vector3(nrm.x, 0.0, nrm.y)).normalized()
		tn.append_array([n3, n3])
		tuv.append_array([Vector2(0.0, 0.0), Vector2(0.0, 1.0)])
		if k > 0 and ok and prev_ok:
			# cara hacia arriba y hacia fuera (Godot: cara delantera en sentido horario visto de frente)
			var gn := (tv[b0] - tv[b0 - 2]).cross(tv[b0 - 1] - tv[b0 - 2])
			if gn.dot(n3) > 0.0:
				ti.append_array([b0 - 2, b0 - 1, b0, b0 - 1, b0 + 1, b0])
			else:
				ti.append_array([b0 - 2, b0, b0 - 1, b0 - 1, b0, b0 + 1])
		prev_ok = ok
	t0 = _t("lineas", t0)
	contornos.append({"poli": cont, "c": c})
	tris_sup.append(sup)
	return {"verts": verts, "idx": idx, "muestras": muestras, "contorno": cont, "mv": mv, "mi": mi, "usados": usados.size(),
			"bordillo": [bv, bn, bi], "alt": alt, "talud": [tv, tn, ti, tuv]}


## Por si la triangulación por orejas falla en una pieza: Delaunay de sus vértices y se quedan los triángulos de dentro
static func _delaunay_filtrado(pz: PackedVector2Array) -> PackedInt32Array:
	var tri := Geometry2D.triangulate_delaunay(pz)
	var out := PackedInt32Array()
	var holg := _mayor(Geometry2D.offset_polygon(pz, 0.05))
	for t in range(0, tri.size(), 3):
		var cen := (pz[tri[t]] + pz[tri[t + 1]] + pz[tri[t + 2]]) / 3.0
		if Geometry2D.is_point_in_polygon(cen, holg):
			out.append_array([tri[t], tri[t + 1], tri[t + 2]])
	return out


## Alturas de la superficie de una glorieta (con ELEV): exactas en los vértices de los brazos, el eje del anillo por
## sectores y, fuera del anillo, el eje del brazo que llega por ese sector.
class Alturas:
	var c := Vector3.ZERO
	var inf := {}
	var anillo := PackedFloat32Array()      # altura por sector de 5°
	var exactas := {}                       # Vector2i(x*20, z*20) -> altura
	var ejes := []                          # PackedVector3Array por brazo (del corte hacia el anillo)
	var sector_brazo := PackedInt32Array()  # brazo de cada sector (-1 = ninguno)

	func preparar(inf_: Dictionary, g: Dictionary, brazos: Array) -> void:
		inf = inf_
		c = inf["c"]
		anillo.resize(72)
		var suma := PackedFloat32Array(); suma.resize(72)
		var cuenta := PackedInt32Array(); cuenta.resize(72)
		var xs: Array = g["x"]
		var ys: Array = g["y"]
		var zs: Array = g["z"]
		for i in xs.size():
			var th := wrapf(atan2(-(float(zs[i]) - c.z), float(xs[i]) - c.x), 0.0, TAU)
			var s := clampi(int(th / TAU * 72.0), 0, 71)
			suma[s] += float(ys[i]) + GlorietaMalla.ELEV
			cuenta[s] += 1
		var y_med := c.y + GlorietaMalla.ELEV
		for s in 72:
			anillo[s] = suma[s] / cuenta[s] if cuenta[s] > 0 else NAN
		for s in 72:
			if is_nan(anillo[s]):
				# el sector con dato más cercano a cada lado
				var a := -1
				var b := -1
				for k in range(1, 37):
					if a < 0 and cuenta[posmod(s - k, 72)] > 0:
						a = k
					if b < 0 and cuenta[posmod(s + k, 72)] > 0:
						b = k
				if a < 0 or b < 0:
					anillo[s] = y_med
				else:
					anillo[s] = lerpf(suma[posmod(s - a, 72)] / cuenta[posmod(s - a, 72)], suma[posmod(s + b, 72)] / cuenta[posmod(s + b, 72)], float(a) / float(a + b))
		sector_brazo.resize(72)
		sector_brazo.fill(-1)
		var mejor := PackedFloat32Array(); mejor.resize(72); mejor.fill(1e9)
		for bi in brazos.size():
			var bm: Dictionary = brazos[bi]
			var izq: PackedVector3Array = bm["izq"]
			var der: PackedVector3Array = bm["der"]
			var eje := PackedVector3Array()
			for k in izq.size():
				eje.append((izq[k] + der[k]) * 0.5)
				exactas[Vector2i(roundi(izq[k].x * 20.0), roundi(izq[k].z * 20.0))] = izq[k].y
				exactas[Vector2i(roundi(der[k].x * 20.0), roundi(der[k].z * 20.0))] = der[k].y
			ejes.append(eje)
			# sectores que cubre el brazo (con sus abocinamientos): los de todos sus puntos, ±15°
			for q in izq + der:
				var th := wrapf(atan2(-(q.z - c.z), q.x - c.x), 0.0, TAU)
				var s0 := clampi(int(th / TAU * 72.0), 0, 71)
				var dist := Vector2(q.x - c.x, q.z - c.z).length()
				for ds in range(-3, 4):
					var s := posmod(s0 + ds, 72)
					var coste := dist * 0.01 + absf(ds)
					if coste < mejor[s]:
						mejor[s] = coste
						sector_brazo[s] = bi

	## Todas las marcas de la glorieta (isletas, cedas, bordes, ejes) a MARCA sobre esta superficie
	## (las marcas son cuadriláteros: 2 vértices en a y 2 en b; la altura se calcula en a y en b, y se reutiliza
	## la de b del anterior cuando es el mismo punto)
	func ajustar_marcas(mv: PackedVector3Array) -> void:
		var prev := Vector2(INF, INF)
		var h_prev := 0.0
		for k in range(0, mv.size() - 3, 4):
			var a := Vector2(mv[k].x + mv[k + 1].x, mv[k].z + mv[k + 1].z) * 0.5
			var b := Vector2(mv[k + 2].x + mv[k + 3].x, mv[k + 2].z + mv[k + 3].z) * 0.5
			var ha := h_prev if a.distance_squared_to(prev) < 1e-4 else h(a.x, a.y, 0.0) + GlorietaMalla.MARCA
			var hb := h(b.x, b.y, 0.0) + GlorietaMalla.MARCA
			for j in 4:
				var q := mv[k + j]
				q.y = ha if j < 2 else hb
				mv[k + j] = q
			prev = b
			h_prev = hb

	func _anillo(th: float) -> float:
		var f := wrapf(th, 0.0, TAU) / TAU * 72.0 - 0.5
		var s0 := posmod(int(floorf(f)), 72)
		return lerpf(anillo[s0], anillo[(s0 + 1) % 72], f - floorf(f))

	func h(x: float, z: float, _y_def: float) -> float:
		var ex: Variant = exactas.get(Vector2i(roundi(x * 20.0), roundi(z * 20.0)))
		if ex != null:
			return ex
		var th := atan2(-(z - c.z), x - c.x)
		var ha := _anillo(th)
		var d := Vector2(x - c.x, z - c.z).length() - GlorietaTipo.r_borde(inf, th)
		if d <= 0.0:
			return ha
		var bi := sector_brazo[clampi(int(wrapf(th, 0.0, TAU) / TAU * 72.0), 0, 71)]
		if bi < 0:
			return ha
		# proyección sobre la cuerda del brazo (corte -> anillo): los brazos son casi rectos en estos 31 m
		var eje: PackedVector3Array = ejes[bi]
		var a := eje[0]
		var b := eje[eje.size() - 1]
		var abx := b.x - a.x
		var abz := b.z - a.z
		var t := clampf(((x - a.x) * abx + (z - a.z) * abz) / maxf(abx * abx + abz * abz, 1e-6), 0.0, 1.0)
		var f := t * float(eje.size() - 1)
		var k0 := mini(int(f), eje.size() - 2)
		var hb := lerpf(eje[k0].y, eje[k0 + 1].y, f - float(k0))
		return lerpf(ha, hb, clampf(d / 4.0, 0.0, 1.0))
