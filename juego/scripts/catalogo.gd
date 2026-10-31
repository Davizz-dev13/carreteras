## Autoload "Catalogo": coches reales disponibles (datos/coches/coches.json) y sus modelos 3D.
## Para añadir un coche nuevo: añade un modelo con sus versiones al JSON (cifras con fuente) y, para el 3D,
## o bien "modelo_3d": {"tipo": "gltf", "ruta": "res://modelos/mi_coche.glb"} (se escala solo a su largo real)
## o bien un perfil procedural {"tipo": "procedural", "perfil": {...}} como el del Arteon.
extends Node

const RUTA_DATOS := "res://datos/coches/coches.json"

var modelos: Array = []                  # entradas de modelo del JSON
var fichas: Array[Ficha] = []            # todas las versiones de todos los modelos
var elegida := 0                         # índice en fichas
var color_elegido := 5                   # índice en los colores del modelo
var _mallas := {}                        # modelo_id -> {"malla": ArrayMesh, ...} (compartidas: ligero)
var _materiales := {}                    # color html -> material de carrocería


func _ready() -> void:
	_asegurar()


## Carga el catálogo la primera vez que se necesita (una escena puede pedirlo antes del _ready del autoload)
func _asegurar() -> void:
	if not fichas.is_empty():
		return
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(RUTA_DATOS))
	modelos = d["modelos"]
	for m in modelos:
		for v in m["versiones"]:
			fichas.append(Ficha.desde_json(m, v))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--coche="):
			elegir_id(a.split("=")[1])
		if a == "--listar_fichas":
			for f in fichas:
				print("FICHA %s | %d kg | Cx·A %.3f | rend %.2f | P rueda %.0f kW | F trac %.0f N | 0-100 oficial %.1f sim %.2f | vmax %d%s" % [
					f.id, f.masa, f.cx_a, f.rendimiento, f.potencia_rueda / 1000.0, f.f_traccion_max, f.t_0_100, f.t_0_100_sim,
					f.v_max_kmh, " lim" if f.limitada else ""])


func elegir_id(id: String) -> void:
	_asegurar()
	for i in fichas.size():
		if fichas[i].id == id:
			elegida = i


func ficha_elegida() -> Ficha:
	_asegurar()
	return fichas[clampi(elegida, 0, fichas.size() - 1)]


func modelo_de(f: Ficha) -> Dictionary:
	_asegurar()
	for m in modelos:
		if m["id"] == f.modelo_id:
			return m
	return modelos[0]


func colores(f: Ficha) -> Array:
	return modelo_de(f).get("colores", [{"nombre": "Blanco", "hex": "#eeeeee"}])


func color_jugador() -> Color:
	var c := colores(ficha_elegida())
	return Color.html(c[clampi(color_elegido, 0, c.size() - 1)]["hex"])


func color_aleatorio(f: Ficha, rng: RandomNumberGenerator) -> Color:
	var c := colores(f)
	return Color.html(c[rng.randi() % c.size()]["hex"])


func material_carroceria(color: Color) -> StandardMaterial3D:
	var k := color.to_html()
	if not _materiales.has(k):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.metallic = 0.55
		mat.roughness = 0.32
		mat.metallic_specular = 0.6
		_materiales[k] = mat
	return _materiales[k]


## Crea el nodo visual de un coche: raíz (en el suelo, centro de la batalla, mirando a -Z)
## con un hijo "carroceria" que puede inclinarse.
func crear_modelo(f: Ficha, color: Color) -> Node3D:
	var m := modelo_de(f)
	var m3d: Dictionary = m.get("modelo_3d", {"tipo": "procedural"})
	var raiz := Node3D.new()
	if m3d.get("tipo", "") == "gltf" and ResourceLoader.exists(m3d.get("ruta", "")):
		var escena: PackedScene = load(m3d["ruta"])
		var n := escena.instantiate() as Node3D
		n.name = "carroceria"
		raiz.add_child(n)
		# escala a su largo real
		var caja := _caja(n)
		if caja.size.z > 0.01:
			n.scale = Vector3.ONE * (f.largo / caja.size.z)
		return raiz
	if not _mallas.has(m["id"]):
		_mallas[m["id"]] = ModeloProcedural.construir(m3d.get("perfil", {}), f)
	var piezas: Dictionary = _mallas[m["id"]]
	var cuerpo := MeshInstance3D.new()
	cuerpo.name = "carroceria"
	cuerpo.mesh = piezas["carroceria"]
	cuerpo.set_surface_override_material(0, material_carroceria(color))
	raiz.add_child(cuerpo)
	for p in piezas["ruedas"]:
		var r := MeshInstance3D.new()
		r.mesh = piezas["rueda"]
		r.position = p
		r.rotation_degrees = Vector3(0, 0, 90)
		raiz.add_child(r)
	return raiz


func _caja(n: Node) -> AABB:
	var a := AABB()
	var primero := true
	for c in n.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		var b := mi.get_aabb()
		if primero: a = b
		else: a = a.merge(b)
		primero = false
	return a
