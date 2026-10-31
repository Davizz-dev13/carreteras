## Señal redonda de límite de velocidad (aro rojo, fondo blanco, número negro), junto al velocímetro.
## Lee res://datos/<zona>/limites_velocidad.json si existe; si no, no se muestra.
class_name SenalLimite
extends Control

var tramos: Array = []        # [{a, b, limite, sentido}] en metros de la ruta
var limite := 0
var por_defecto := false     # límite genérico por tipo de vía (no viene de una señal en OSM): se dibuja más tenue y con *


## Carga los tramos de la ruta indicada. Acepta {"rutas":[{"tramos":[…]}, …]} (por índice o por nombre),
## {"0": {"tramos": …}} o directamente una lista de tramos.
func cargar(ruta_idx: int, nombre_ruta: String) -> void:
	tramos.clear()
	var camino := Ajustes.dir_datos() + "limites_velocidad.json"
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


## Límite (km/h) que rige en el punto s de la ruta circulando en el sentido dir (0 = sin dato). v4
func limite_en(s: float, dir: int) -> int:
	for t in tramos:
		if s >= minf(t["a"], t["b"]) and s <= maxf(t["a"], t["b"]):
			var sen: String = t["sentido"]
			if sen == "ambos" or (sen == "ida" and dir > 0) or (sen == "vuelta" and dir < 0):
				return t["limite"]
	return 0


## Velocidad máxima (m/s) para el piloto automático: el límite de aquí y, si más adelante baja, la velocidad desde la
## que se llega a ese límite frenando suave (b m/s²) justo al pasar la señal. INF si no hay límites para esta ruta. v4
func tope_piloto(s: float, dir: int, b := 1.2, horizonte := 300.0) -> float:
	if tramos.is_empty():
		return INF
	var tope := INF
	var d := 0.0
	while d <= horizonte:
		var l := limite_en(s + dir * d, dir)
		if l > 0:
			var vl := l / 3.6
			tope = minf(tope, sqrt(vl * vl + 2.0 * b * d))
		d += 10.0
	return tope


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
