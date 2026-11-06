## Descargas del mundo por teselas: ortofoto PNOA (IGN/CNIG, WMTS) y relieve (Mapterhorn, teselas terrarium WebP).
## Cola con prioridad (lo más grueso y cercano primero), varias descargas a la vez (HTTPRequest, sin bloquear el juego)
## y caché en disco en user://mundo_cache/ con tope de tamaño (se borra lo más antiguo). Lo mismo funciona en la web
## (los dos servidores responden con Access-Control-Allow-Origin: *, comprobado el 6-nov-2026), pero ahí no hay disco
## persistente grande: la caché del navegador hace ese papel.
class_name EarthFuentes
extends Node

const DIR_CACHE := "user://mundo_cache/"
const DESCARGAS := 10                 # peticiones simultáneas
const REINTENTOS := 4

const URL_PNOA := "https://www.ign.es/wmts/pnoa-ma?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=OI.OrthoimageCoverage&STYLE=default&TILEMATRIXSET=EPSG:25830&TILEMATRIX=%d&TILEROW=%d&TILECOL=%d&FORMAT=image/jpeg"
const URL_RELIEVE := "https://tiles.mapterhorn.com/%d/%d/%d.webp"

var limite_bytes := 600 * 1024 * 1024
var _libres: Array[HTTPRequest] = []
var _cola: Array = []           # [{clave, url, ruta, prio, intentos}]
var _cola_sucia := false
var _esperando := {}            # clave -> Array[Callable]
var _activos := {}              # HTTPRequest -> pedido
var _bytes_cache := 0
var est := {"pedidas": 0, "de_cache": 0, "descargadas": 0, "bytes_red": 0, "fallos": 0, "vacias": 0, "canceladas": 0}


func _ready() -> void:
	name = "Fuentes"
	if Ajustes.args.has("cache_mb"):
		limite_bytes = int(float(Ajustes.args["cache_mb"]) * 1024 * 1024)
	DirAccess.make_dir_recursive_absolute(DIR_CACHE)
	for i in DESCARGAS:
		var h := HTTPRequest.new()
		h.use_threads = not OS.has_feature("web")
		h.timeout = 25.0
		h.request_completed.connect(_hecho.bind(h))
		add_child(h)
		_libres.append(h)
	_podar_cache(false)


static func ruta_pnoa(nivel: int, col: int, fila: int) -> String:
	return "pnoa/%d/%d/%d.jpg" % [nivel, col, fila]


static func ruta_relieve(z: int, x: int, y: int) -> String:
	return "relieve/%d/%d/%d.webp" % [z, x, y]


## Pide un recurso; `cb` recibe los bytes (vacío = no existe / falló, null = cancelado). Si ya está en la caché de
## disco se entrega en el siguiente fotograma.
func pedir(clave: String, url: String, ruta: String, prio: float, cb: Callable) -> void:
	est["pedidas"] += 1
	if _esperando.has(clave):
		(_esperando[clave] as Array).append(cb)
		return
	_esperando[clave] = [cb]
	var f := DIR_CACHE + ruta
	if FileAccess.file_exists(f):
		est["de_cache"] += 1
		_entregar.call_deferred(clave, FileAccess.get_file_as_bytes(f))
		return
	_cola.append({"clave": clave, "url": url, "ruta": ruta, "prio": prio, "intentos": 0})
	_cola_sucia = true


## Quita de la cola lo que ya no hace falta (sigue_haciendo_falta(clave) -> bool); sus esperas reciben null
func podar_cola(sigue_haciendo_falta: Callable) -> void:
	var quedan: Array = []
	for p in _cola:
		if sigue_haciendo_falta.call(p["clave"]):
			quedan.append(p)
		else:
			est["canceladas"] += 1
			_entregar(p["clave"], null)
	_cola = quedan


func cambiar_prioridad(clave: String, prio: float) -> void:
	for p in _cola:
		if p["clave"] == clave:
			p["prio"] = prio
			_cola_sucia = true
			return


func en_cola() -> int:
	return _cola.size() + _activos.size()


func _process(_d: float) -> void:
	if _cola.is_empty() or _libres.is_empty():
		return
	if _cola_sucia:
		_cola.sort_custom(func(a, b): return a["prio"] < b["prio"])
		_cola_sucia = false
	while not _libres.is_empty() and not _cola.is_empty():
		var p: Dictionary = _cola.pop_front()
		var h: HTTPRequest = _libres.pop_back()
		var err := h.request(p["url"], PackedStringArray(["User-Agent: Carreteras/0.1 (Godot; juego de conduccion)"]))
		if err != OK:
			_libres.append(h)
			est["fallos"] += 1
			_entregar(p["clave"], PackedByteArray())
			continue
		_activos[h] = p


func _hecho(resultado: int, codigo: int, cabeceras: PackedStringArray, cuerpo: PackedByteArray, h: HTTPRequest) -> void:
	var p: Dictionary = _activos.get(h, {})
	_activos.erase(h)
	_libres.append(h)
	if p.is_empty():
		return
	var es_imagen := false
	for c in cabeceras:
		if c.to_lower().begins_with("content-type:") and c.to_lower().contains("image/"):
			es_imagen = true
	if resultado == HTTPRequest.RESULT_SUCCESS and codigo == 200 and es_imagen and cuerpo.size() > 0:
		est["descargadas"] += 1
		est["bytes_red"] += cuerpo.size()
		_guardar(p["ruta"], cuerpo)
		_entregar(p["clave"], cuerpo)
	elif resultado == HTTPRequest.RESULT_SUCCESS and (codigo == 404 or codigo == 204 or (codigo == 200 and not es_imagen)):
		est["vacias"] += 1     # no hay dato ahí (fuera de cobertura): se recuerda con un archivo vacío
		_guardar(p["ruta"], PackedByteArray())
		_entregar(p["clave"], PackedByteArray())
	else:
		p["intentos"] += 1
		if p["intentos"] <= REINTENTOS:
			_cola.append(p)
			_cola_sucia = true
		else:
			est["fallos"] += 1
			push_warning("Mundo: no se pudo descargar %s (resultado %d, HTTP %d)" % [p["url"], resultado, codigo])
			_entregar(p["clave"], PackedByteArray())


func _entregar(clave: String, bytes: Variant) -> void:
	var lista: Array = _esperando.get(clave, [])
	_esperando.erase(clave)
	for cb in lista:
		(cb as Callable).call(bytes)


func _guardar(ruta: String, bytes: PackedByteArray) -> void:
	var f := DIR_CACHE + ruta
	DirAccess.make_dir_recursive_absolute(f.get_base_dir())
	var fa := FileAccess.open(f, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_buffer(bytes)
	fa.close()
	_bytes_cache += bytes.size()
	if _bytes_cache > limite_bytes:
		_podar_cache(true)


## Si la caché pasa del tope, borra los archivos más antiguos hasta quedarse en el 80 %
func _podar_cache(forzar: bool) -> void:
	var lista: Array = []
	var total := [0]
	_recorrer(DIR_CACHE, lista, total)
	_bytes_cache = total[0]
	if _bytes_cache <= limite_bytes and not forzar:
		return
	if _bytes_cache <= limite_bytes:
		return
	lista.sort_custom(func(a, b): return a[0] < b[0])
	for e in lista:
		if _bytes_cache <= limite_bytes * 0.8:
			break
		DirAccess.remove_absolute(e[1])
		_bytes_cache -= int(e[2])
	print("Mundo: caché podada a %.0f MB" % (_bytes_cache / 1048576.0))


func _recorrer(dir: String, lista: Array, total: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_recorrer(dir.path_join(sub), lista, total)
	for f in d.get_files():
		var ruta := dir.path_join(f)
		var fa := FileAccess.open(ruta, FileAccess.READ)
		var tam := fa.get_length() if fa else 0
		total[0] += tam
		lista.append([FileAccess.get_modified_time(ruta), ruta, tam])


func megas_cache() -> float:
	return _bytes_cache / 1048576.0
