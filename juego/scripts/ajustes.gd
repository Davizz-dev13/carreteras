## Autoload "Ajustes": opciones elegidas en el menú + datos de la zona (se cargan una vez).
extends Node

const ZONA_POR_DEFECTO := "navacerrada"

# --- opciones de la partida (las rellena el menú) ---
var zona := ZONA_POR_DEFECTO
var ruta_idx := 0
var km_ini := 0.0
var km_fin := 0.0          # si km_fin < km_ini se recorre la carretera en sentido contrario
var velocidad := 80.0      # km/h de crucero / piloto automático
var piloto := true         # el coche se conduce solo por su carril
var adaptar_curvas := true # el piloto frena antes de las curvas
var trafico := 0.3         # 0..1
var camara := 0            # 0 persecución, 1 cabina

# --- datos cargados ---
var info := {}
var rutas: Array[Ruta] = []
var vias: Array = []       # [{pts: PackedVector3Array, ancho, nombre}]
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


func cargar() -> void:
	if not rutas.is_empty():
		return
	var t0 := Time.get_ticks_msec()
	info = JSON.parse_string(FileAccess.get_file_as_string(dir_datos() + "zona.json"))
	var car: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir_datos() + "carreteras.json"))
	for d in car["rutas"]:
		rutas.append(Ruta.desde_json(d))
	for v in car["vias"]:
		var pts := PackedVector3Array()
		var xs: Array = v["x"]
		for i in xs.size():
			pts.append(Vector3(xs[i], v["y"][i], v["z"][i]))
		vias.append({"pts": pts, "ancho": float(v["ancho"]), "nombre": v["ref"] if v["ref"] != "" else v["nombre"],
				"tunel": int(v["tunel"])})
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
	superficie = Superficie.new()
	superficie.construir(rutas, vias)
	print("Datos cargados en %d ms: %d rutas, %d vías, %d teselas" % [Time.get_ticks_msec() - t0, rutas.size(), vias.size(), terreno.size()])


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
