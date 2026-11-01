## Autoload "Ajustes": opciones elegidas en el menú + datos de la zona (se cargan una vez).
extends Node

const ZONA_POR_DEFECTO := "navacerrada"
## Zonas incluidas: carpeta en res://datos/ → nombre en el menú
const ZONAS := {"navacerrada": "Puerto de Navacerrada (Madrid/Segovia)", "a308": "A-308 Iznalloz – Darro (Granada)", "gr8101": "GR-8101 Sierra de Baza (Granada)", "m406": "M-406"}

# --- opciones de la partida (las rellena el menú) ---
var zona := ZONA_POR_DEFECTO
var ruta_idx := 0
var km_ini := 0.0
var km_fin := 0.0          # si km_fin < km_ini se recorre la carretera en sentido contrario
var velocidad := 80.0      # km/h de crucero / piloto automático
var piloto := true         # el coche se conduce solo por su carril
var adaptar_curvas := true # el piloto frena antes de las curvas
var piloto_limites := false   # el piloto no pasa del límite de cada tramo (apagado = va a la velocidad elegida, como en la v3)
var limite_adelantar := false  # al adelantar, no pasar del límite de velocidad del tramo (apagado = más agresivo)
var trafico := 0.3         # 0..1
var camara := 0            # 0 persecución, 1 cabina
var volumen_motor := 0.8   # 0..1, sonido del motor del coche (sonido_motor.gd)
var silencio := false      # N: silenciar el motor

# --- datos cargados ---
var info := {}
var rutas: Array[Ruta] = []
var vias: Array = []       # [{pts: PackedVector3Array, ancho, nombre}]
var glorietas: Array = []  # ejes cerrados de las glorietas [{x, y, z, hw}] (pipeline/glorietas_completas.py)
var terreno := {}          # Vector2i -> PackedFloat32Array
var ter_x0 := 0.0
var ter_z0 := 0.0
var ter_paso := 20.0
var ter_n := 101
var ter_tesela := 2000.0
var superficie: Superficie

# --- captura automática (verificación / vídeo) ---
var args := {}


func _ready() -> void:
	_fuente_de_respaldo()
	for a in OS.get_cmdline_user_args():
		var p := a.trim_prefix("--").split("=", true, 1)
		args[p[0]] = p[1] if p.size() > 1 else "1"


## La fuente por defecto de Godot no trae flechas (→ ↑ ↓ ← ). En escritorio las coge del sistema, pero en
## la versión web no hay fuentes del sistema: se añade DejaVu Sans como respaldo solo para los símbolos que falten.
func _fuente_de_respaldo() -> void:
	var respaldo: Font = load("res://fuentes/DejaVuSans.ttf")
	var f: Font = ThemeDB.fallback_font
	if respaldo and f and not f.fallbacks.has(respaldo):
		var lista := f.fallbacks.duplicate()
		lista.append(respaldo)
		f.fallbacks = lista


func dir_datos() -> String:
	return "res://datos/%s/" % zona


## Cambia de zona: vacía lo cargado (la escena que llame a esto se recarga después)
func cambiar_zona(z: String) -> void:
	if z == zona and not rutas.is_empty():
		return
	zona = z
	ruta_idx = 0
	km_ini = 0.0
	km_fin = 0.0
	info = {}
	rutas.clear()
	vias.clear()
	glorietas = []
	terreno.clear()
	superficie = null


func cargar() -> void:
	if args.has("zona") and args["zona"] != zona and rutas.is_empty():
		zona = args["zona"]
	if not rutas.is_empty():
		return
	var t0 := Time.get_ticks_msec()
	info = JSON.parse_string(FileAccess.get_file_as_string(dir_datos() + "zona.json"))
	var car: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir_datos() + "carreteras.json"))
	for d in car["rutas"]:
		rutas.append(Ruta.desde_json(d))
	glorietas = car.get("glorietas", [])
	_lineas_adelantar()
	_cargar_carriles()
	# zonas grandes: las vías secundarias van repartidas en varios archivos (≤ 3 MB cada uno)
	var lista_vias: Array = car["vias"].duplicate()
	for nombre in car.get("vias_archivos", []):
		var parte = JSON.parse_string(FileAccess.get_file_as_string(dir_datos() + str(nombre)))
		if parte is Dictionary:
			lista_vias.append_array(parte.get("vias", []))
	for v in lista_vias:
		var pts := PackedVector3Array()
		var xs: Array = v["x"]
		for i in xs.size():
			pts.append(Vector3(xs[i], v["y"][i], v["z"][i]))
		vias.append({"pts": pts, "ancho": float(v["ancho"]), "nombre": v["ref"] if v["ref"] != "" else v["nombre"],
				"tunel": int(v["tunel"]), "puente": int(v.get("puente", 0))})
	var ter: Dictionary = info["terreno"]
	ter_paso = float(ter["paso"])
	ter_tesela = float(ter["tesela"])
	ter_x0 = 1e9
	ter_z0 = 1e9
	for t in ter["teselas"]:
		ter_x0 = minf(ter_x0, float(t["x0"]))
		ter_z0 = minf(ter_z0, float(t["z0"]))
	for t in ter["teselas"]:
		var f := FileAccess.open(dir_datos() + "terreno/%s.bin" % t["nombre"], FileAccess.READ)
		var h := f.get_buffer(f.get_length()).to_float32_array()
		ter_n = int(t["n"])
		var clave := Vector2i(roundi((float(t["x0"]) - ter_x0) / ter_tesela), roundi((float(t["z0"]) - ter_z0) / ter_tesela))
		terreno[clave] = h
	# cruces limpios (secundarias cortadas en el borde de la principal) y terreno por debajo del asfalto
	var cr := Cruces.preparar(rutas, vias)
	print("Cruces: ", cr)
	superficie = Superficie.new()
	superficie.construir(rutas, vias)
	print("Datos cargados en %d ms: %d rutas, %d vías, %d teselas" % [Time.get_ticks_msec() - t0, rutas.size(), vias.size(), terreno.size()])


## Carriles reales por sentido (carriles adicionales 2+1), de adelantar.json → "carriles", si existen
func _cargar_carriles() -> void:
	var camino := dir_datos() + "adelantar.json"
	if not FileAccess.file_exists(camino):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(camino))
	if not (d is Dictionary) or not (d.get("rutas", null) is Array):
		return
	for r in d["rutas"]:
		if r is Dictionary and r.has("carriles"):
			var i := int(r.get("id", -1))
			if i >= 0 and i < rutas.size():
				rutas[i].cargar_carriles(r["carriles"])


## Altura del terreno (bilineal) en X, Z
func altura_terreno(x: float, z: float) -> float:
	var gx := (x - ter_x0) / ter_paso
	var gz := (z - ter_z0) / ter_paso
	var celdas := int(ter_tesela / ter_paso)
	var ti := floori(gx / celdas)
	var tj := floori(gz / celdas)
	var h: PackedFloat32Array = terreno.get(Vector2i(ti, tj), PackedFloat32Array())
	if h.is_empty():
		return 0.0
	var lx := clampf(gx - ti * celdas, 0.0, celdas - 0.001)
	var lz := clampf(gz - tj * celdas, 0.0, celdas - 0.001)
	var i := int(lx)
	var j := int(lz)
	var fx := lx - i
	var fz := lz - j
	var a := h[j * ter_n + i]
	var b := h[j * ter_n + i + 1]
	var c := h[(j + 1) * ter_n + i]
	var d := h[(j + 1) * ter_n + i + 1]
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fz)


func ruta() -> Ruta:
	return rutas[clampi(ruta_idx, 0, rutas.size() - 1)]


## Línea central derivada (no son las marcas reales): tramos de línea discontinua de datos/…/adelantar.json,
## calculados con el mismo criterio de adelantamiento del juego (--captura=lineas_adelantar). Sin el archivo,
## cada ruta se queda sin máscara y se pinta con la regla antigua (continua en curvas de radio < 350 m).
func _lineas_adelantar() -> void:
	var camino := dir_datos() + "adelantar.json"
	if not FileAccess.file_exists(camino):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(camino))
	if not (d is Dictionary) or not (d.get("rutas", null) is Array):
		return
	for r in d["rutas"]:
		if not (r is Dictionary) or not r.has("linea_discontinua"):
			continue
		var i := int(r.get("id", -1))
		if i < 0 or i >= rutas.size():
			continue
		var ru: Ruta = rutas[i]
		var m := PackedByteArray()
		m.resize(ru.n)
		m.fill(0)
		for t in r["linea_discontinua"]:
			var a := clampi(int(float(t[0]) * 1000.0 / ru.paso), 0, ru.n - 1)
			var b := clampi(int(float(t[1]) * 1000.0 / ru.paso), 0, ru.n - 1)
			for k in range(a, b + 1):
				m[k] = 1
		ru.discontinua = m
