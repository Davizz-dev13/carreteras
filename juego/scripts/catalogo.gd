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
	# versiones limitadas sin cifra publicada sin limitador: rendimiento de su hermana (ficha.gd, "rendimiento_como")
	for f in fichas:
		var como := str(f.datos.get("rendimiento_como", ""))
		if f.limitada and como != "":
			for h in fichas:
				if h.id == como and h != f:
					f.heredar_rendimiento(h.rendimiento)
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
		# pintura metalizada con barniz (clearcoat): base metálica algo rugosa + capa transparente brillante
		var mat := StandardMaterial3D.new()
		mat.resource_name = "pintura"
		mat.albedo_color = color
		mat.metallic = 0.62
		mat.roughness = 0.34
		mat.metallic_specular = 0.6
		mat.clearcoat_enabled = true
		mat.clearcoat = 1.0
		mat.clearcoat_roughness = 0.06
		_materiales[k] = mat
	return _materiales[k]


## Crea el nodo visual de un coche: raíz (en el suelo, centro de la batalla, mirando a -Z)
## con un hijo "carroceria" que puede inclinarse y, si el modelo las trae, 4 ruedas que giran y dirigen.
## lod = 0: modelo detallado (jugador); 1: versión ligera (tráfico).
func crear_modelo(f: Ficha, color: Color, lod := 0) -> Node3D:
	var m := modelo_de(f)
	var m3d: Dictionary = m.get("modelo_3d", {"tipo": "procedural"})
	var raiz := Node3D.new()
	var ruta: String = m3d.get("ruta_lod1", m3d.get("ruta", "")) if lod >= 1 else m3d.get("ruta", "")
	if m3d.get("tipo", "") == "gltf" and ResourceLoader.exists(ruta):
		raiz.set_meta("lod", lod)
		_montar_gltf(raiz, load(ruta), f, color, m3d)
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


## Modelo glTF (ver modelos/LEEME.md): nodos "carroceria", "rueda_del_izq|del_der|tra_izq|tra_der" (la parte que gira:
## neumático, llanta, disco) y "pinza_…" (pinza de freno: gira con la dirección pero no con la rueda), con su origen en
## el centro de cada rueda. Se escala al largo real de la versión.
func _montar_gltf(raiz: Node3D, escena: PackedScene, f: Ficha, color: Color, m3d: Dictionary) -> void:
	var n := escena.instantiate() as Node3D
	var esc := f.largo / float(m3d.get("largo_modelo_m", f.largo))
	var cuerpo := Node3D.new()
	cuerpo.name = "carroceria"
	raiz.add_child(cuerpo)
	var ruedas := []
	var pivotes := {}
	for hijo in n.find_children("*", "MeshInstance3D", true, false):
		var mi := hijo as MeshInstance3D
		var t := mi.global_transform if mi.is_inside_tree() else _transform_en(n, mi)
		var nombre := String(mi.name)
		mi.get_parent().remove_child(mi)
		mi.owner = null
		if nombre.begins_with("rueda_") or nombre.begins_with("pinza_"):
			var clave := nombre.substr(6)
			if not pivotes.has(clave):
				var piv := Node3D.new()
				piv.name = "eje_" + clave
				piv.position = t.origin * esc
				raiz.add_child(piv)
				pivotes[clave] = piv
				ruedas.append({"pivote": piv, "rueda": null, "delantera": clave.begins_with("del")})
			var pv: Node3D = pivotes[clave]
			mi.transform = Transform3D(t.basis.scaled(Vector3.ONE * esc), Vector3.ZERO)
			# rueda y "pinza" giran juntas dentro de su propio nodo (en este modelo la cara de la llanta va en la pieza
			# "pinza"); así tampoco se pisa la orientación que trae la malla
			var rodar: Node3D = pv.get_node_or_null("rodar")
			if rodar == null:
				rodar = Node3D.new()
				rodar.name = "rodar"
				pv.add_child(rodar)
			rodar.add_child(mi)
			for r in ruedas:
				if r["pivote"] == pv:
					r["rueda"] = rodar
					if nombre.begins_with("rueda_"):
						r["malla"] = mi
		elif nombre == "volante":
			# volante (solo LOD0): pivote en el centro del aro con su Z local a lo largo de la columna de dirección
			# (hacia el conductor); animar_volante lo gira sobre ese eje. Va dentro de la carrocería para inclinarse con ella.
			var pv_vol := Node3D.new()
			pv_vol.name = "volante"
			pv_vol.transform = Transform3D(t.basis.orthonormalized(), t.origin * esc)
			mi.transform = Transform3D(Basis.from_scale(t.basis.get_scale() * esc), Vector3.ZERO)
			pv_vol.add_child(mi)
			cuerpo.add_child(pv_vol)
			raiz.set_meta("volante", pv_vol)
			raiz.set_meta("volante_base", pv_vol.transform)
			raiz.set_meta("volante_ang", 0.0)
		else:
			mi.transform = Transform3D(t.basis.scaled(Vector3.ONE * esc), t.origin * esc)
			cuerpo.add_child(mi)
			if nombre == "espejo_interior":
				raiz.set_meta("espejo", mi)           # retrovisor.gd le pone la imagen de la cámara trasera
			# la pintura de la carrocería: el color elegido con barniz
			for i in mi.mesh.get_surface_count():
				var mat := mi.mesh.surface_get_material(i)
				if mat and mat.resource_name.begins_with("pintura"):
					mi.set_surface_override_material(i, material_carroceria(color))
	n.free()
	if raiz.get_meta("lod", 0) == 0:
		_materiales_jugador(raiz)
	# el tráfico lejano no se dibuja (a más de 600 m un coche ocupa unos pocos píxeles)
	if m3d.get("ruta_lod1", "") != "" and esc > 0.0:
		for gi in raiz.find_children("*", "GeometryInstance3D", true, false):
			if raiz.get_meta("lod", 0) >= 1:
				(gi as GeometryInstance3D).visibility_range_end = 600.0
				if String(gi.name).begins_with("rueda") or String(gi.get_parent().name) == "rodar":
					(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var radio := 0.33
	for r in ruedas:
		if r.get("malla"):
			var mm := r["malla"] as MeshInstance3D
			var caja := mm.transform * mm.get_aabb()
			radio = maxf(0.2, maxf(caja.size.y, caja.size.z) * 0.5)
	raiz.set_meta("ruedas", ruedas)
	raiz.set_meta("radio_rueda", radio)
	raiz.set_meta("giro_rueda", 0.0)


func _transform_en(raiz: Node3D, nodo: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var x: Node = nodo
	while x != null and x != raiz:
		if x is Node3D:
			t = (x as Node3D).transform * t
		x = x.get_parent()
	return t


## Hace girar las ruedas según lo avanzado (m) y orienta las delanteras con el ángulo de dirección (rad, + derecha)
func animar_ruedas(modelo: Node3D, avance: float, giro: float) -> void:
	if modelo == null or not modelo.has_meta("ruedas"):
		return
	var ang: float = fmod(float(modelo.get_meta("giro_rueda")) - avance / float(modelo.get_meta("radio_rueda")), TAU)
	modelo.set_meta("giro_rueda", ang)
	for r in modelo.get_meta("ruedas"):
		var piv: Node3D = r["pivote"]
		if r["delantera"]:
			piv.rotation.y = -giro
		if r["rueda"]:
			(r["rueda"] as Node3D).rotation.x = ang


## Coche del jugador (LOD0): las piezas que no son chapa ni cristal pasan al material con oclusión por vértice
## (coche_ao.gdshader; el modelo trae la oclusión en COLOR_0) y los pilotos traseros reciben un material propio que se
## enciende al frenar (luces_freno).
const MATERIALES_AO := ["chrome", "plasticblack", "silver", "reflect", "plasticGlossy", "alumimium", "leather",
	"interiorTex", "interiorPlastic", "interiorB", "interiorA", "grey", "black", "metal_dark"]
const PILOTO_ENCENDIDO := 1.2     # energía de los pilotos de posición (la del modelo)
const PILOTO_FRENO := 8.0         # al frenar: se ven de día
const TULIPA_FRENO := 22.0        # emisión de la tulipa roja al frenar (la del modelo es 0,1 de rojo: queda 2,2)
var _materiales_ao := {}
var _shader_ao: Shader = null

func _materiales_jugador(raiz: Node3D) -> void:
	var pilotos := []
	for gi in raiz.find_children("*", "MeshInstance3D", true, false):
		var mi := gi as MeshInstance3D
		if mi.mesh == null or not mi.mesh is ArrayMesh:
			continue
		var arr := mi.mesh as ArrayMesh
		for i in arr.get_surface_count():
			if mi.get_surface_override_material(i) != null:
				continue
			var mat := arr.surface_get_material(i) as BaseMaterial3D
			if mat == null:
				continue
			var nombre := mat.resource_name
			if nombre in MATERIALES_AO and arr.surface_get_format(i) & Mesh.ARRAY_FORMAT_COLOR:
				mi.set_surface_override_material(i, _material_ao(mat))
			elif nombre.begins_with("glass_red_Illum"):
				var luz := mat.duplicate() as BaseMaterial3D
				luz.emission_energy_multiplier = PILOTO_ENCENDIDO
				mi.set_surface_override_material(i, luz)
				pilotos.append([luz, PILOTO_ENCENDIDO, PILOTO_FRENO])
			elif nombre == "glass_red":
				# la tulipa roja que cubre los pilotos: casi apagada; al frenar brilla entera (y la tercera luz de freno)
				var tulipa := mat.duplicate() as BaseMaterial3D
				tulipa.emission_enabled = true
				tulipa.emission_energy_multiplier = 1.0
				mi.set_surface_override_material(i, tulipa)
				pilotos.append([tulipa, 1.0, TULIPA_FRENO])
	raiz.set_meta("luces_freno", pilotos)
	raiz.set_meta("frenando", false)


func _material_ao(base: BaseMaterial3D) -> Material:
	if _materiales_ao.has(base):
		return _materiales_ao[base]
	if _shader_ao == null:
		_shader_ao = load("res://scripts/coche_ao.gdshader")
	var m := ShaderMaterial.new()
	m.shader = _shader_ao
	m.resource_name = base.resource_name + "_ao"
	m.set_shader_parameter("albedo", base.albedo_color)
	if base.albedo_texture:
		m.set_shader_parameter("textura", base.albedo_texture)
	m.set_shader_parameter("metallic", base.metallic)
	m.set_shader_parameter("roughness", base.roughness)
	m.set_shader_parameter("specular", base.metallic_specular)
	_materiales_ao[base] = m
	return m


## Pilotos traseros del coche del jugador: más intensos mientras se frena
func luces_freno(modelo: Node3D, frenando: bool) -> void:
	if modelo == null or not modelo.has_meta("luces_freno") or bool(modelo.get_meta("frenando")) == frenando:
		return
	modelo.set_meta("frenando", frenando)
	for l in modelo.get_meta("luces_freno"):
		(l[0] as BaseMaterial3D).emission_energy_multiplier = l[2] if frenando else l[1]


## Volante de la cabina: gira sobre el eje de la columna con la dirección. frac = ángulo de las ruedas / máximo
## (-1 izquierda … +1 derecha). Desmultiplicación real: 450° de tope a tope (±225°), suavizado ligero.
## (v6: el coche del jugador usa poner_volante con el ángulo real que sale de las ruedas, coche.gd)
const VOLANTE_TOPE := deg_to_rad(225.0)
func animar_volante(modelo: Node3D, frac: float, dt: float) -> void:
	if modelo == null or not modelo.has_meta("volante"):
		return
	var objetivo := -clampf(frac, -1.0, 1.0) * VOLANTE_TOPE      # a la derecha = horario visto desde el asiento
	var k := 1.0 - exp(-maxf(dt, 0.0) * 30.0)      # suavizado corto (≈33 ms): sigue al mando sin retraso visible
	var ang := lerpf(float(modelo.get_meta("volante_ang")), objetivo, k)
	_girar_volante(modelo, ang)


## v6: pone el volante de la cabina en el ángulo dado (rad, + = a la derecha, horario visto desde el asiento)
func poner_volante(modelo: Node3D, ang_derecha: float) -> void:
	if modelo == null or not modelo.has_meta("volante"):
		return
	_girar_volante(modelo, -ang_derecha)


func _girar_volante(modelo: Node3D, ang: float) -> void:
	modelo.set_meta("volante_ang", ang)
	var base: Transform3D = modelo.get_meta("volante_base")
	(modelo.get_meta("volante") as Node3D).transform = Transform3D(base.basis * Basis(Vector3.BACK, ang), base.origin)


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
