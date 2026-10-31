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
	paquete = int(info["paquete"])
	var red: Dictionary = JSON.parse_string(gz(dir + "red.json.gz").get_string_from_utf8())
	tramos = red["tramos"]
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
	_mutex.lock()
	if _geo.size() > GEO_MAX:
		_geo.clear()
	_geo[k] = pts
	_mutex.unlock()
	return pts


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
