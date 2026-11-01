## Mapa abierto (solo versión de escritorio): datos de la red y del terreno de una región entera, leídos del disco
## por trozos. Los genera pipeline/mundo/m3_mundo.py en res://datos/<region>/ (ver FUENTES.md de esa carpeta):
##  · mundo.json       índice (origen UTM, tesela, paquetes, horizonte)
##  · red.json.gz      tramos (atributos y nodos de sus extremos) y nodos de cruce (posición, tramos que llegan)
##  · red_N.bin.gz     geometría 3D de cada tramo cada 5 m (1.er punto int32 en cm, después diferencias int16)
##  · ter_I_J.bin      paquetes de 4×4 teselas de 2 km: directorio + cada tesela comprimida (gzip) por separado
##  · horizonte.bin.gz relieve de toda la caja a 200 m (mínimo y real)
## Todo se puede leer desde hilos (WorkerThreadPool): la caché de geometría va con un Mutex.
class_name MaDatos
extends RefCounted

var dir := "res://datos/madrid/"
var info := {}
var tramos: Array = []          # Dictionary por tramo (c, enlace, ref, nombre, s, carriles, ancho, v, vf, vb, puente, tunel, rot, a, b, L, g)
var nodos := {}                 # id -> [x, y, z, [tramos]]
var partes: Array = []          # PackedByteArray descomprimidos (geometría)
var tesela := 2000.0
var paquete := 4
var _geo := {}                  # tramo -> PackedVector3Array (caché, se vacía si crece mucho)
var _paq := {}                  # Vector2i paquete -> {Vector2i tesela: Vector2i(desplazamiento, tamaño)}
var _mutex := Mutex.new()
const GEO_MAX := 6000           # tramos en caché como mucho (~ 15 MB)


func cargar(region := "madrid") -> bool:
	dir = "res://datos/%s/" % region
	if not FileAccess.file_exists(dir + "mundo.json"):
		return false
	info = JSON.parse_string(FileAccess.get_file_as_string(dir + "mundo.json"))
	tesela = float(info["tesela"])
	ajustar_ramales = str(Ajustes.args.get("ajuste_ramales", "1")) == "1"
	paquete = int(info["paquete"])
	var red: Dictionary = JSON.parse_string(gz(dir + "red.json.gz").get_string_from_utf8())
	tramos = red["tramos"]
	if ajustar_ramales:
		# los ramales salían todos con la anchura de un carril (4,5 m) aunque OSM diga que tienen 2, 3 o 4: en una salida
		# de 2 carriles el ramal quedaba como un pasillo y entre él y la principal se veía el final recto de la calzada
		# ancha. Misma regla que las principales: 3,5 m por carril + 1 m de arcenes.
		for t in tramos:
			if int(t["enlace"]) == 1 and int(t["s"]) == 1 and int(t["carriles"]) >= 2:
				t["ancho"] = maxf(float(t["ancho"]), 3.5 * int(t["carriles"]) + 1.0)
	for k in red["nodos"]:
		nodos[int(k)] = red["nodos"][k]
	for p in info["partes_red"]:
		partes.append(gz(dir + p))
	return true


static func gz(ruta: String) -> PackedByteArray:
	var b := FileAccess.get_file_as_bytes(ruta)
	return b.decompress_dynamic(256 * 1024 * 1024, FileAccess.COMPRESSION_GZIP)


## Geometría del tramo k (puntos cada ~5 m, de su nodo a a su nodo b)
func geometria(k: int) -> PackedVector3Array:
	_mutex.lock()
	var g = _geo.get(k)
	_mutex.unlock()
	if g != null:
		return g
	var pts := _cruda(k)
	if ajustar_ramales:
		pts = _ajustar(k, pts)
	_mutex.lock()
	if _geo.size() > GEO_MAX:
		_geo.clear()
	_geo[k] = pts
	_mutex.unlock()
	return pts


## Geometría tal como viene de OSM (eje de cada calzada cada 5 m)
func _cruda(k: int) -> PackedVector3Array:
	var t: Dictionary = tramos[k]
	var gi: Array = t["g"]
	var b: PackedByteArray = partes[int(gi[0])]
	var o := int(gi[1])
	var n := int(gi[2])
	var pts := PackedVector3Array()
	pts.resize(n)
	var x := b.decode_s32(o)
	var y := b.decode_s32(o + 4)
	var z := b.decode_s32(o + 8)
	pts[0] = Vector3(x, y, z) * 0.01
	o += 12
	for i in range(1, n):
		x += b.decode_s16(o)
		y += b.decode_s16(o + 2)
		z += b.decode_s16(o + 4)
		o += 6
		pts[i] = Vector3(x, y, z) * 0.01
	return pts


# ------------------------------------------------------------------ bifurcaciones y uniones de calzadas
## OSM dibuja cada calzada por su eje, y en una salida la calzada ancha (p. ej. 5 carriles) se parte en un nodo de su
## eje en dos más estrechas (la que sigue, 3 carriles, y el ramal, 2) que salen las dos de ese mismo punto central:
## en el juego se veía el final recto de la ancha con un escalón a cada lado y el ramal montado encima de los carriles.
## Aquí cada rama se desplaza hacia su lado para quedar a ras del borde de la calzada ancha (la izquierda con el borde
## izquierdo, la derecha con el derecho) y el desplazamiento se desvanece en los primeros 120 m (lo mismo, al revés, en
## las incorporaciones). Donde una calzada de un solo sentido cambia de anchura sin bifurcarse, la estrecha queda a ras
## del borde izquierdo (los carriles se ganan y se pierden por la derecha). La misma geometría la usan el dibujo, la
## superficie del coche, el piloto y el tráfico.
const AJ_DESVANECER := 120.0
var ajustar_ramales := true

func _ajustar(k: int, pts: PackedVector3Array) -> PackedVector3Array:
	var t: Dictionary = tramos[k]
	var n := pts.size()
	if int(t["s"]) != 1 or int(t["rot"]) == 1 or n < 2:
		return pts
	var d0 := _desvio(k, int(t["a"]), true, pts)
	var d1 := _desvio(k, int(t["b"]), false, pts)
	if absf(d0) < 0.05 and absf(d1) < 0.05:
		return pts
	var s := PackedFloat32Array()
	s.resize(n)
	for i in range(1, n):
		s[i] = s[i - 1] + Vector2(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z).length()
	var L := s[n - 1]
	var f := minf(AJ_DESVANECER, L * 0.7)
	var out := PackedVector3Array()
	out.resize(n)
	for i in n:
		var tg := pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]
		var der := Vector3(-tg.z, 0.0, tg.x).normalized()
		var w0 := 1.0 - smoothstep(0.0, f, s[i])
		var w1 := 1.0 - smoothstep(0.0, f, L - s[i])
		out[i] = pts[i] + der * (d0 * w0 + d1 * w1)
	return out


## Desplazamiento lateral (m, + a la derecha del tramo k) en su nodo `nodo` (inicio o final del tramo)
func _desvio(k: int, nodo: int, inicio: bool, pts: PackedVector3Array) -> float:
	var nd = nodos.get(nodo)
	if nd == null:
		return 0.0
	var ts: Array = nd[3]
	if ts.size() < 2 or ts.size() > 3:
		return 0.0
	var entran := []
	var salen := []
	for x in ts:
		var tx: Dictionary = tramos[int(x)]
		if int(tx["s"]) != 1 or int(tx["rot"]) == 1 or int(tx["tunel"]) == 1 or int(tx["a"]) == int(tx["b"]):
			return 0.0
		if int(tx["b"]) == nodo:
			entran.append(int(x))
		if int(tx["a"]) == nodo:
			salen.append(int(x))
	var w := float(tramos[k]["ancho"])
	if inicio:
		if entran.size() != 1 or not salen.has(k):
			return 0.0
		var ancho_ref := float(tramos[entran[0]]["ancho"])
		var dif := ancho_ref - w
		if salen.size() == 2:
			var otro: int = salen[0] if salen[1] == k else salen[1]
			return _lado(entran[0], true, pts, otro) * clampf(dif * 0.5, 0.0, 8.0)
		if salen.size() == 1 and dif > 0.5 and int(tramos[k]["c"]) <= 2:
			return -minf(dif * 0.5, 8.0)
		return 0.0
	if salen.size() != 1 or not entran.has(k):
		return 0.0
	var ancho_ref2 := float(tramos[salen[0]]["ancho"])
	var dif2 := ancho_ref2 - w
	if entran.size() == 2:
		var otro2: int = entran[0] if entran[1] == k else entran[1]
		return _lado(salen[0], false, pts, otro2) * clampf(dif2 * 0.5, 0.0, 8.0)
	if entran.size() == 1 and dif2 > 0.5 and int(tramos[k]["c"]) <= 2:
		return -minf(dif2 * 0.5, 8.0)
	return 0.0


## +1 si el tramo (puntos `pts`) queda a la derecha del otro tramo `otro` vista desde la calzada única `ref`
## (bifurcación: ref entra en el nodo; unión: ref sale de él); -1 si queda a la izquierda
func _lado(ref: int, bifurcacion: bool, pts: PackedVector3Array, otro: int) -> float:
	var pr := _cruda(ref)
	var po := _cruda(otro)
	var dir: Vector3
	var nodo_p: Vector3
	if bifurcacion:
		nodo_p = pr[pr.size() - 1]
		dir = pr[pr.size() - 1] - pr[maxi(pr.size() - 4, 0)]
	else:
		nodo_p = pr[0]
		dir = pr[mini(3, pr.size() - 1)] - pr[0]
	var der := Vector2(-dir.z, dir.x).normalized()
	var a := _punto_a(pts, 40.0, bifurcacion)
	var b := _punto_a(po, 40.0, bifurcacion)
	var la := der.dot(Vector2(a.x - nodo_p.x, a.z - nodo_p.z))
	var lb := der.dot(Vector2(b.x - nodo_p.x, b.z - nodo_p.z))
	return 1.0 if la > lb else -1.0


## Bordes que se mueven cerca de un nodo (m por punto de la geometría, + = el borde se abre hacia fuera, - = se mete):
## - calzadas de un sentido que ganan o pierden anchura en un nodo sin bifurcación (carril que se añade o se quita): la
##   ancha se dibuja con el borde derecho metido hasta el de la estrecha en el nodo y abriéndose en los primeros (o
##   últimos) metros, como un carril de aceleración/deceleración, en vez de acabar en un escalón recto;
## - bifurcaciones (y uniones) donde la calzada ancha es más ancha que las dos ramas juntas: cada rama se abre por su
##   lado interior hasta cubrir el hueco y se cierra en los primeros metros (una cuña de asfalto, como la zona de
##   separación pintada), en vez de dejar el final recto de la ancha con hierba en medio.
## Devuelve [izquierdo, derecho] (PackedFloat32Array) o [] si no hace falta.
func bordes(k: int) -> Array:
	var t: Dictionary = tramos[k]
	if not ajustar_ramales or int(t["s"]) != 1 or int(t["rot"]) == 1:
		return []
	var w := float(t["ancho"])
	var i0 := 0.0
	var d0 := 0.0
	var i1 := 0.0
	var d1 := 0.0
	if int(t["c"]) <= 2:
		var p := _vecino_unico(int(t["a"]), k, true)
		if p >= 0:
			d0 = -clampf(w - float(tramos[p]["ancho"]), 0.0, w - 1.0)
		var q := _vecino_unico(int(t["b"]), k, false)
		if q >= 0:
			d1 = -clampf(w - float(tramos[q]["ancho"]), 0.0, w - 1.0)
	var h0 := _hueco(k, int(t["a"]), true)
	if h0.x > 0.5:
		if h0.y > 0.0:
			i0 = h0.x
		else:
			d0 = h0.x
	var h1 := _hueco(k, int(t["b"]), false)
	if h1.x > 0.5:
		if h1.y > 0.0:
			i1 = h1.x
		else:
			d1 = h1.x
	if absf(i0) < 0.5 and absf(d0) < 0.5 and absf(i1) < 0.5 and absf(d1) < 0.5:
		return []
	var pts := geometria(k)
	var n := pts.size()
	var s := PackedFloat32Array()
	s.resize(n)
	for i in range(1, n):
		s[i] = s[i - 1] + Vector2(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z).length()
	var L := s[n - 1]
	var f := minf(150.0, L * 0.5)
	var bi := PackedFloat32Array()
	var bd := PackedFloat32Array()
	bi.resize(n)
	bd.resize(n)
	for i in n:
		var a0 := 1.0 - smoothstep(0.0, f, s[i])
		var a1 := 1.0 - smoothstep(0.0, f, L - s[i])
		bi[i] = i0 * a0 + i1 * a1
		bd[i] = d0 * a0 + d1 * a1
	return [bi, bd]


## Hueco entre las dos ramas en una bifurcación (inicio=true, k sale del nodo) o unión (k entra): Vector2(mitad del
## hueco en m, +1 si k es la rama derecha -> se abre su borde izquierdo / -1 si es la izquierda -> su borde derecho)
func _hueco(k: int, nodo: int, inicio: bool) -> Vector2:
	var nd = nodos.get(nodo)
	if nd == null or (nd[3] as Array).size() != 3:
		return Vector2.ZERO
	var entran := []
	var salen := []
	for x in nd[3]:
		var tx: Dictionary = tramos[int(x)]
		if int(tx["s"]) != 1 or int(tx["rot"]) == 1 or int(tx["tunel"]) == 1 or int(tx["a"]) == int(tx["b"]):
			return Vector2.ZERO
		if int(tx["b"]) == nodo:
			entran.append(int(x))
		if int(tx["a"]) == nodo:
			salen.append(int(x))
	var unica: int
	var otro: int
	if inicio:
		if entran.size() != 1 or salen.size() != 2 or not salen.has(k):
			return Vector2.ZERO
		unica = entran[0]
		otro = salen[0] if salen[1] == k else salen[1]
	else:
		if salen.size() != 1 or entran.size() != 2 or not entran.has(k):
			return Vector2.ZERO
		unica = salen[0]
		otro = entran[0] if entran[1] == k else entran[1]
	var hueco := float(tramos[unica]["ancho"]) - float(tramos[k]["ancho"]) - float(tramos[otro]["ancho"])
	if hueco <= 0.5:
		return Vector2.ZERO
	return Vector2(minf(hueco * 0.5, 8.0), _lado(unica, inicio, _cruda(k), otro))


## En el nodo, el único tramo que llega (antes=true) o sale (antes=false) además de k, si el nodo es un simple paso
## de una calzada de un sentido a otra (2 tramos, mismo sentido); -1 si no
func _vecino_unico(nodo: int, k: int, antes: bool) -> int:
	var nd = nodos.get(nodo)
	if nd == null or (nd[3] as Array).size() != 2:
		return -1
	for x in nd[3]:
		var o := int(x)
		if o == k:
			continue
		var to: Dictionary = tramos[o]
		if int(to["s"]) != 1 or int(to["rot"]) == 1 or int(to["tunel"]) == 1:
			return -1
		if antes and int(to["b"]) == nodo:
			return o
		if not antes and int(to["a"]) == nodo:
			return o
	return -1


## Punto a `d` m del principio (o del final) de la polilínea
static func _punto_a(pts: PackedVector3Array, d: float, desde_inicio: bool) -> Vector3:
	var n := pts.size()
	var acc := 0.0
	for j in range(1, n):
		var i := j if desde_inicio else n - 1 - j
		var ant := i - 1 if desde_inicio else i + 1
		acc += pts[i].distance_to(pts[ant])
		if acc >= d:
			return pts[i]
	return pts[n - 1] if desde_inicio else pts[0]


func clave_tesela(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / tesela), floori(p.z / tesela))


## Datos de una tesela: {n, paso, x0, z0, h: PackedFloat32Array (n×n), piezas: [[tramo, i0, i1], ...]} o {} si no existe
func leer_tesela(t: Vector2i) -> Dictionary:
	var pk := Vector2i(floori(t.x / float(paquete)), floori(t.y / float(paquete)))
	_mutex.lock()
	var d = _paq.get(pk)
	_mutex.unlock()
	var nombre: String = info["paquetes"].get("%d,%d" % [pk.x, pk.y], "")
	if nombre == "":
		return {}
	var f := FileAccess.open(dir + nombre, FileAccess.READ)
	if f == null:
		return {}
	if d == null:
		d = {}
		f.seek(4)
		var nt := f.get_32()
		for i in nt:
			var ti := _s32(f.get_32())
			var tj := _s32(f.get_32())
			var off := f.get_32()
			var tam := f.get_32()
			d[Vector2i(ti, tj)] = Vector2i(off, tam)
		_mutex.lock()
		_paq[pk] = d
		_mutex.unlock()
	if not d.has(t):
		return {}
	var e: Vector2i = d[t]
	f.seek(e.x)
	var b := f.get_buffer(e.y).decompress_dynamic(16 * 1024 * 1024, FileAccess.COMPRESSION_GZIP)
	# cabecera "<4sHHiiHfI": TESL, versión, fina, ti, tj, n, paso, nº de piezas
	var nn := b.decode_u16(16)
	var paso := b.decode_float(18)
	var np := b.decode_u32(22)
	var o := 26
	var piezas := []
	for i in np:
		piezas.append([b.decode_s32(o), b.decode_s32(o + 4), b.decode_s32(o + 8)])
		o += 12
	var h := PackedFloat32Array()
	h.resize(nn * nn)
	for j in nn:
		var acc := 0
		for i in nn:
			acc += b.decode_s16(o)
			o += 2
			h[j * nn + i] = acc * 0.1
	return {"n": nn, "paso": paso, "x0": t.x * tesela, "z0": t.y * tesela, "h": h, "piezas": piezas, "fina": b.decode_u16(6) == 1}


## JPEG de la ortofoto de una tesela (o vacío si no hay)
func leer_orto(t: Vector2i) -> PackedByteArray:
	return _leer_blob("ortofoto", 100000, t)


## Árboles de una tesela: [{x, z (locales, m), tipo (0 sin dato, 1 conífera, 2 frondosa), escala 0–1}] empaquetados:
## PackedByteArray con registros de 6 bytes (u16 x, u16 z, u8 tipo, u8 escala); vacío si no hay
func leer_arboles(t: Vector2i) -> PackedByteArray:
	var b := _leer_blob("arboles", 200000, t)
	if b.is_empty():
		return b
	b = b.decompress_dynamic(32 * 1024 * 1024, FileAccess.COMPRESSION_GZIP)
	return b.slice(8)


## Edificios de una tesela: PackedByteArray tras la cabecera (u16 altura dm, u16 n, n × (u16 x, u16 z)), o vacío
func leer_edificios(t: Vector2i) -> PackedByteArray:
	var b := _leer_blob("edificios", 300000, t)
	if b.is_empty():
		return b
	return b.decompress_dynamic(64 * 1024 * 1024, FileAccess.COMPRESSION_GZIP)


func _leer_blob(capa: String, desplazamiento: int, t: Vector2i) -> PackedByteArray:
	var o: Dictionary = info.get(capa, {})
	if o.is_empty():
		return PackedByteArray()
	var pk := Vector2i(floori(t.x / float(paquete)), floori(t.y / float(paquete)))
	var nombre: String = o["paquetes"].get("%d,%d" % [pk.x, pk.y], "")
	if nombre == "":
		return PackedByteArray()
	var clave := Vector2i(pk.x + desplazamiento, pk.y)       # directorio en la misma caché que el terreno
	_mutex.lock()
	var d = _paq.get(clave)
	_mutex.unlock()
	var f := FileAccess.open(dir + nombre, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	if d == null:
		d = {}
		f.seek(4)
		var nt := f.get_32()
		for i in nt:
			var ti := _s32(f.get_32())
			var tj := _s32(f.get_32())
			var off := f.get_32()
			var tam := f.get_32()
			d[Vector2i(ti, tj)] = Vector2i(off, tam)
		_mutex.lock()
		_paq[clave] = d
		_mutex.unlock()
	if not d.has(t):
		return PackedByteArray()
	var e: Vector2i = d[t]
	f.seek(e.x)
	return f.get_buffer(e.y)


static func _s32(u: int) -> int:
	return u - 4294967296 if u >= 2147483648 else u


## Horizonte: {nx, nz, paso, x0, z0, minimo: PackedFloat32Array, real: PackedFloat32Array}
func leer_horizonte() -> Dictionary:
	var hz: Dictionary = info["horizonte"]
	var nx := int(hz["nx"])
	var nz := int(hz["nz"])
	var b := gz(dir + "horizonte.bin.gz")
	var mn := PackedFloat32Array()
	var re := PackedFloat32Array()
	mn.resize(nx * nz)
	re.resize(nx * nz)
	var n := nx * nz
	for i in n:
		mn[i] = b.decode_u16(i * 2) * 0.1
		re[i] = b.decode_u16((n + i) * 2) * 0.1
	return {"nx": nx, "nz": nz, "paso": float(hz["paso"]), "x0": float(hz["x0"]), "z0": float(hz["z0"]), "minimo": mn, "real": re}


## Nombre visible de un tramo: "A-6 · Autovía del Noroeste"
func rotulo(k: int) -> String:
	if k < 0 or k >= tramos.size():
		return ""
	var t: Dictionary = tramos[k]
	var r: String = t["ref"]
	var n: String = t["nombre"]
	if r != "" and n != "":
		return r.replace(";", " / ") + "  ·  " + n
	return r.replace(";", " / ") if r != "" else n
