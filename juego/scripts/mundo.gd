## Construye el mundo 1:1 a partir de los datos: terreno, carreteras con marcas viales, árboles, cielo y niebla.
class_name Mundo
extends Node3D

const DIST_TERRENO := 14000.0
const DIST_ARBOLES := 1600.0
const DIST_MARCAS := 450.0

var mat_terreno := StandardMaterial3D.new()
var mat_asfalto := StandardMaterial3D.new()
var mat_asfalto2 := StandardMaterial3D.new()
var mat_marca := StandardMaterial3D.new()
var mat_marca_amarilla := StandardMaterial3D.new()
var mat_copa := StandardMaterial3D.new()
var mat_tronco := StandardMaterial3D.new()
var entorno: Environment


func construir() -> void:
	mat_terreno.vertex_color_use_as_albedo = true
	mat_terreno.roughness = 1.0
	mat_asfalto.albedo_color = Color(0.15, 0.15, 0.15)
	mat_asfalto.roughness = 0.95
	mat_asfalto2.albedo_color = Color(0.2, 0.2, 0.19)
	mat_asfalto2.roughness = 0.9
	mat_marca.albedo_color = Color(0.92, 0.92, 0.9)
	mat_marca.roughness = 0.6
	mat_marca_amarilla.albedo_color = Color(0.95, 0.75, 0.1)
	mat_copa.albedo_color = Color(0.13, 0.27, 0.14)
	mat_copa.roughness = 1.0
	mat_tronco.albedo_color = Color(0.36, 0.25, 0.17)
	_cielo()
	_terreno()
	for r in Ajustes.rutas:
		_ruta(r)
	for v in Ajustes.vias:
		_via(v)
	_arboles()


func _cielo() -> void:
	var sol := DirectionalLight3D.new()
	sol.rotation_degrees = Vector3(-38, -35, 0)
	sol.light_energy = 1.15
	sol.shadow_enabled = true
	sol.directional_shadow_max_distance = 90.0
	sol.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	add_child(sol)
	var cielo_mat := ProceduralSkyMaterial.new()
	cielo_mat.sky_top_color = Color(0.32, 0.52, 0.80)
	cielo_mat.sky_horizon_color = Color(0.72, 0.80, 0.88)
	cielo_mat.ground_horizon_color = Color(0.62, 0.68, 0.72)
	cielo_mat.ground_bottom_color = Color(0.25, 0.27, 0.25)
	var cielo := Sky.new()
	cielo.sky_material = cielo_mat
	entorno = Environment.new()
	entorno.background_mode = Environment.BG_SKY
	entorno.sky = cielo
	entorno.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	entorno.ambient_light_energy = 0.45
	entorno.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	entorno.fog_enabled = true
	entorno.fog_mode = Environment.FOG_MODE_DEPTH
	entorno.fog_light_color = Color(0.70, 0.77, 0.85)
	entorno.fog_density = 1.0
	entorno.fog_depth_begin = 1500.0
	entorno.fog_depth_end = 13000.0
	entorno.fog_depth_curve = 1.2
	entorno.fog_sky_affect = 0.25
	var we := WorldEnvironment.new()
	we.environment = entorno
	add_child(we)


## Color del terreno según altitud y pendiente (prados, pinar, roca, cumbres)
func _color_terreno(h: float, inclinacion: float) -> Color:
	var prado := Color(0.36, 0.38, 0.22)
	var pinar := Color(0.16, 0.24, 0.13)
	var roca := Color(0.45, 0.43, 0.40)
	var cumbre := Color(0.50, 0.46, 0.36)
	var c := prado.lerp(pinar, clampf((h - 1150.0) / 250.0, 0.0, 1.0))
	c = c.lerp(cumbre, clampf((h - 1950.0) / 200.0, 0.0, 1.0))
	return c.lerp(roca, clampf((inclinacion - 0.12) / 0.25, 0.0, 1.0))


func _terreno() -> void:
	var tz: Dictionary = Ajustes.info["terreno"]
	var p := Ajustes.ter_paso
	for t in tz["teselas"]:
		var nn := int(t["n"])
		var mm := int(t["m"])
		var x0 := float(t["x0"])
		var z0 := float(t["z0"])
		var clave := Vector2i(roundi((x0 - Ajustes.ter_x0) / Ajustes.ter_tesela), roundi((z0 - Ajustes.ter_z0) / Ajustes.ter_tesela))
		var h: PackedFloat32Array = Ajustes.terreno[clave]
		var verts := PackedVector3Array()
		var normales := PackedVector3Array()
		var colores := PackedColorArray()
		verts.resize(nn * mm)
		normales.resize(nn * mm)
		colores.resize(nn * mm)
		for j in mm:
			for i in nn:
				var k := j * nn + i
				var hl := h[j * nn + maxi(i - 1, 0)]
				var hr := h[j * nn + mini(i + 1, nn - 1)]
				var hu := h[maxi(j - 1, 0) * nn + i]
				var hd := h[mini(j + 1, mm - 1) * nn + i]
				var nrm := Vector3(hl - hr, 2.0 * p, hu - hd).normalized()
				verts[k] = Vector3(x0 + i * p, h[k], z0 + j * p)
				normales[k] = nrm
				colores[k] = _color_terreno(h[k], 1.0 - nrm.y + 0.0)
		var idx := PackedInt32Array()
		idx.resize((nn - 1) * (mm - 1) * 6)
		var c := 0
		for j in mm - 1:
			for i in nn - 1:
				var k := j * nn + i
				idx[c] = k; idx[c + 1] = k + 1; idx[c + 2] = k + nn
				idx[c + 3] = k + 1; idx[c + 4] = k + nn + 1; idx[c + 5] = k + nn
				c += 6
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_NORMAL] = normales
		arr[Mesh.ARRAY_COLOR] = colores
		arr[Mesh.ARRAY_INDEX] = idx
		var malla := ArrayMesh.new()
		malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		malla.surface_set_material(0, mat_terreno)
		var mi := MeshInstance3D.new()
		mi.mesh = malla
		mi.visibility_range_end = DIST_TERRENO
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)


## Cinta de calzada a lo largo de una polilínea (trozos de ~400 m para que la cámara descarte lo que no ve)
func _cinta(pts: PackedVector3Array, anchos: PackedFloat32Array, desde: int, hasta: int, desplaz: float,
		semiancho_fijo: float, elev: float, mat: Material, visible_hasta: float, patron := PackedByteArray()) -> void:
	var trozo := 200
	var a := desde
	while a < hasta:
		var b := mini(a + trozo, hasta)
		var verts := PackedVector3Array()
		var nor := PackedVector3Array()
		var idx := PackedInt32Array()
		for i in range(a, b + 1):
			var t := pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]
			var der := Vector3(-t.z, 0.0, t.x).normalized()
			var hw := semiancho_fijo if semiancho_fijo > 0.0 else anchos[i] * 0.5
			# desplaz = -1/+1: línea de borde a 25 cm del borde izquierdo/derecho; 0: eje
			var centro := pts[i] + der * signf(desplaz) * (anchos[i] * 0.5 - 0.25)
			if not patron.is_empty() and patron[i] == 0:
				# hueco de línea discontinua: vértices degenerados
				verts.append(centro + Vector3.UP * elev)
				verts.append(centro + Vector3.UP * elev)
			else:
				verts.append(centro - der * hw + Vector3.UP * elev)
				verts.append(centro + der * hw + Vector3.UP * elev)
			nor.append(Vector3.UP)
			nor.append(Vector3.UP)
			if i > a:
				var k := verts.size() - 4
				idx.append_array([k, k + 2, k + 1, k + 1, k + 2, k + 3])
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_NORMAL] = nor
		arr[Mesh.ARRAY_INDEX] = idx
		var malla := ArrayMesh.new()
		malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		malla.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.mesh = malla
		mi.visibility_range_end = visible_hasta
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		a = b


func _ruta(r: Ruta) -> void:
	# tramos consecutivos que esta ruta debe dibujar
	var i := 0
	while i < r.n - 1:
		if r.dibujar[i] == 0:
			i += 1
			continue
		var j := i
		while j < r.n - 1 and r.dibujar[j] == 1:
			j += 1
		_tramo_ruta(r, i, j)
		i = j


func _tramo_ruta(r: Ruta, a: int, b: int) -> void:
	_cinta(r.pts, r.ancho, a, b, 0.0, 0.0, 0.05, mat_asfalto, DIST_TERRENO)
	# líneas de borde (continuas, 15 cm)
	_cinta(r.pts, r.ancho, a, b, -1.0, 0.075, 0.08, mat_marca, DIST_MARCAS)
	_cinta(r.pts, r.ancho, a, b, 1.0, 0.075, 0.08, mat_marca, DIST_MARCAS)
	# línea central: continua en curvas cerradas, discontinua (4,5 m de trazo cada 12 m) en rectas
	var patron := PackedByteArray()
	patron.resize(r.n)
	for i in r.n:
		var continua := absf(r.curvatura[i]) > 1.0 / 350.0
		patron[i] = 1 if (continua or fmod(i * r.paso, 12.0) < 4.5) else 0
	_cinta(r.pts, r.ancho, a, b, 0.0, 0.07, 0.085, mat_marca, DIST_MARCAS, patron)


func _via(v: Dictionary) -> void:
	var pts: PackedVector3Array = v["pts"]
	if pts.size() < 2 or v["tunel"] == 1:
		return
	var anchos := PackedFloat32Array()
	anchos.resize(pts.size())
	anchos.fill(float(v["ancho"]))
	_cinta(pts, anchos, 0, pts.size() - 1, 0.0, 0.0, 0.04, mat_asfalto2, 6000.0)


## Pinos (MultiMesh por tesela): tronco + copa cónica, 1 sola malla de 2 superficies
func _malla_pino() -> ArrayMesh:
	var malla := ArrayMesh.new()
	var copa := CylinderMesh.new()
	copa.top_radius = 0.0
	copa.bottom_radius = 2.6
	copa.height = 10.0
	copa.radial_segments = 7
	copa.rings = 1
	var tronco := CylinderMesh.new()
	tronco.top_radius = 0.25
	tronco.bottom_radius = 0.35
	tronco.height = 5.0
	tronco.radial_segments = 5
	tronco.rings = 1
	for par in [[copa, 9.0, mat_copa], [tronco, 2.5, mat_tronco]]:
		var arr: Array = par[0].get_mesh_arrays()
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in v.size():
			v[i].y += par[1]
		arr[Mesh.ARRAY_VERTEX] = v
		malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		malla.surface_set_material(malla.get_surface_count() - 1, par[2])
	return malla


func _arboles() -> void:
	var malla := _malla_pino()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for t in Ajustes.info["terreno"]["teselas"]:
		if int(t["arboles"]) == 0:
			continue
		var f := FileAccess.open(Ajustes.dir_datos() + "arboles/%s.bin" % t["nombre"], FileAccess.READ)
		if f == null:
			continue
		var d := f.get_buffer(f.get_length()).to_float32_array()
		var cuenta := d.size() / 4
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = malla
		mm.instance_count = cuenta
		var centro := Vector3.ZERO
		for i in cuenta:
			var x := d[i * 4]
			var z := d[i * 4 + 2]
			var esc := d[i * 4 + 3]
			var y := Ajustes.altura_terreno(x, z) - 0.3
			var bas := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(esc, esc * rng.randf_range(0.85, 1.25), esc))
			mm.set_instance_transform(i, Transform3D(bas, Vector3(x, y, z)))
			centro += Vector3(x, y, z)
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.visibility_range_end = DIST_ARBOLES
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)


## Coche low-poly (jugador y tráfico)
static func crear_coche(color: Color) -> Node3D:
	var raiz := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.3
	mat.roughness = 0.45
	var cristal := StandardMaterial3D.new()
	cristal.albedo_color = Color(0.08, 0.1, 0.13)
	cristal.roughness = 0.15
	var negro := StandardMaterial3D.new()
	negro.albedo_color = Color(0.05, 0.05, 0.05)
	var luz := StandardMaterial3D.new()
	luz.albedo_color = Color(1, 0.95, 0.8)
	luz.emission_enabled = true
	luz.emission = Color(1, 0.95, 0.8)
	var piloto_mat := StandardMaterial3D.new()
	piloto_mat.albedo_color = Color(0.7, 0.05, 0.05)
	piloto_mat.emission_enabled = true
	piloto_mat.emission = Color(0.6, 0.0, 0.0)
	var piezas := [
		[Vector3(1.78, 0.62, 4.25), Vector3(0, 0.62, 0), mat],
		[Vector3(1.55, 0.52, 2.1), Vector3(0, 1.18, 0.25), cristal],
		[Vector3(1.5, 0.08, 1.9), Vector3(0, 1.47, 0.25), mat],
		[Vector3(0.35, 0.12, 0.05), Vector3(-0.6, 0.72, -2.13), luz],
		[Vector3(0.35, 0.12, 0.05), Vector3(0.6, 0.72, -2.13), luz],
		[Vector3(0.4, 0.12, 0.05), Vector3(-0.6, 0.75, 2.13), piloto_mat],
		[Vector3(0.4, 0.12, 0.05), Vector3(0.6, 0.75, 2.13), piloto_mat],
	]
	for p in piezas:
		var mi := MeshInstance3D.new()
		var caja := BoxMesh.new()
		caja.size = p[0]
		mi.mesh = caja
		mi.position = p[1]
		mi.material_override = p[2]
		raiz.add_child(mi)
	var rueda := CylinderMesh.new()
	rueda.top_radius = 0.33
	rueda.bottom_radius = 0.33
	rueda.height = 0.22
	rueda.radial_segments = 10
	for pos in [Vector3(-0.82, 0.33, -1.35), Vector3(0.82, 0.33, -1.35), Vector3(-0.82, 0.33, 1.35), Vector3(0.82, 0.33, 1.35)]:
		var mi := MeshInstance3D.new()
		mi.mesh = rueda
		mi.material_override = negro
		mi.position = pos
		mi.rotation_degrees = Vector3(0, 0, 90)
		raiz.add_child(mi)
	return raiz
