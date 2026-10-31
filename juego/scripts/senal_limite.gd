## Señal redonda de límite de velocidad (aro rojo, fondo blanco, número negro), junto al velocímetro.
## Lee res://datos/navacerrada/limites_velocidad.json si existe; si no, no se muestra.
class_name SenalLimite
extends Control

var tramos: Array = []        # [{a, b, limite, sentido}] en metros de la ruta
var limite := 0
var por_defecto := false     # límite genérico por tipo de vía (no viene de una señal en OSM): se dibuja más tenue y con *


## Carga los tramos de la ruta indicada. Acepta {"rutas":[{"tramos":[…]}, …]} (por índice o por nombre),
## {"0": {"tramos": …}} o directamente una lista de tramos.
func cargar(ruta_idx: int, nombre_ruta: String) -> void:
	tramos.clear()
	var camino := "res://datos/navacerrada/limites_velocidad.json"
	if not FileAccess.file_exists(camino):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(camino))
	var lista = null
	if d is Dictionary:
		var rutas = d.get("rutas", null)
		if rutas is Array:
			for r in rutas:
				if r is Dictionary and (str(r.get("nombre", "")) == nombre_ruta and nombre_ruta != ""):
					lista = r.get("tramos", null)
			if lista == null and ruta_idx < rutas.size() and rutas[ruta_idx] is Dictionary:
				lista = rutas[ruta_idx].get("tramos", null)
		elif rutas is Dictionary:
			var r = rutas.get(str(ruta_idx), rutas.get(nombre_ruta, null))
			if r is Dictionary: lista = r.get("tramos", null)
			elif r is Array: lista = r
		elif d.has(str(ruta_idx)):
			var r = d[str(ruta_idx)]
			lista = r.get("tramos", null) if r is Dictionary else r
	elif d is Array:
		lista = d
	if not (lista is Array):
		return
	for t in lista:
		if t is Dictionary and t.has("limite"):
			tramos.append({"a": float(t.get("km_ini", 0.0)) * 1000.0, "b": float(t.get("km_fin", 0.0)) * 1000.0,
				"limite": int(t["limite"]), "sentido": str(t.get("sentido", "ambos")),
				"legal": str(t.get("fuente", "osm")) != "osm"})


func actualizar(s: float, dir: int) -> void:
	var nuevo := 0
	var legal := false
	for t in tramos:
		if s >= minf(t["a"], t["b"]) and s <= maxf(t["a"], t["b"]):
			var sen: String = t["sentido"]
			if sen == "ambos" or (sen == "ida" and dir > 0) or (sen == "vuelta" and dir < 0):
				nuevo = t["limite"]
				legal = t["legal"]
				break
	visible = nuevo > 0
	if nuevo != limite or legal != por_defecto:
		limite = nuevo
		por_defecto = legal
		modulate.a = 0.6 if legal else 1.0
		queue_redraw()


func _draw() -> void:
	if limite <= 0:
		return
	var r := minf(size.x, size.y) * 0.5
	var c := size * 0.5
	draw_circle(c, r, Color(0.8, 0.05, 0.05))
	draw_circle(c, r * 0.76, Color.WHITE)
	var f := get_theme_default_font()
	var txt := str(limite)
	var fs := int(r * (0.95 if txt.length() < 3 else 0.72))
	var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(f, c + Vector2(-w.x * 0.5, fs * 0.36), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.BLACK)
	if por_defecto:
		draw_string(f, Vector2(size.x - 4, 14), "*", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)
