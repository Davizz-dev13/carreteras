## Señales de tráfico REALES de OpenStreetMap (STOP y ceda el paso en los cruces junto a la ruta), de
## datos/<zona>/senales.json (pipeline/senales.py). Sin datos no se dibuja ninguna.
## Barato para la gráfica: piezas de streaming de 250 m; en cada una, un MultiMesh por tipo de señal con una malla
## low-poly (poste + placa + trasera) y un único material con un atlas de 256 px; sin sombras y visibles a ≤ 250 m.
class_name SenalesOsm
extends RefCounted

const CELDA := 250.0          # m de lado de cada pieza de streaming
const DIST_VISIBLE := 250.0
const TIPOS := ["R2", "R1"]   # fila del atlas: R2 (STOP) arriba, R1 (ceda el paso) abajo
const LADO := 0.9             # m (placa de carretera convencional)
const BAJO := 1.4             # m del suelo al borde inferior de la placa

static var _mallas: Array = []
static var _mat: StandardMaterial3D


## Señales del archivo de la zona → piezas [{senales: [[tipo_idx, Transform3D], …], caja: Rect2}]
static func piezas(dir_datos: String) -> Array:
	var camino := dir_datos + "senales.json"
	if not FileAccess.file_exists(camino):
		return []
	var d = JSON.parse_string(FileAccess.get_file_as_string(camino))
	if not (d is Dictionary):
		return []
	var celdas := {}
	for s in d.get("senales", []):
		var ti := TIPOS.find(str(s.get("tipo", "")))
		if ti < 0:
			continue
		var p := Vector3(float(s["x"]), float(s["y"]), float(s["z"]))
		if Ajustes.superficie != null:
			var suelo: float = Ajustes.superficie.consultar(p.x, p.z, p.y).x
			if is_finite(suelo) and absf(suelo - p.y) < 6.0:
				p.y = suelo
		var clave := Vector2i(floori(p.x / CELDA), floori(p.z / CELDA))
		if not celdas.has(clave):
			celdas[clave] = []
		celdas[clave].append([ti, Transform3D(Basis(Vector3.UP, float(s["rumbo"])), p)])
	var out := []
	for clave in celdas:
		var mn := Vector2(INF, INF)
		var mx := Vector2(-INF, -INF)
		for e in celdas[clave]:
			var o: Vector3 = e[1].origin
			mn = Vector2(minf(mn.x, o.x), minf(mn.y, o.z))
			mx = Vector2(maxf(mx.x, o.x), maxf(mx.y, o.z))
		out.append({"senales": celdas[clave], "caja": Rect2(mn - Vector2(2, 2), mx - mn + Vector2(4, 4))})
	return out


static func construir(pz: Dictionary) -> Node3D:
	_preparar()
	var raiz := Node3D.new()
	for ti in TIPOS.size():
		var lista := []
		for e in pz["senales"]:
			if e[0] == ti:
				lista.append(e[1])
		if lista.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _mallas[ti]
		mm.instance_count = lista.size()
		for k in lista.size():
			mm.set_instance_transform(k, lista[k])
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.material_override = _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = DIST_VISIBLE
		raiz.add_child(mi)
	return raiz


static func _preparar() -> void:
	if _mat != null:
		return
	_mat = StandardMaterial3D.new()
	_mat.albedo_texture = load("res://modelos/senales_es.png")
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	_mat.alpha_scissor_threshold = 0.5
	_mat.roughness = 0.6
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if not OS.has_feature("web"):
		# placas más nítidas vistas de lado (filtrado anisótropo: coste de GPU despreciable en escritorio)
		_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var gris := Vector2(0.75, 0.25)       # zona gris del atlas (trasera del STOP): poste
	for ti in TIPOS.size():
		var v0 := float(ti) * 0.5          # fila del atlas
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var y0 := BAJO
		var y1 := BAJO + LADO
		var h := LADO * 0.5
		# cara (mira a +Z) y trasera gris (mira a −Z), 1 cm por detrás
		var caras := [[0.02, 0.0, Vector3(0, 0, 1)], [0.0, 0.5, Vector3(0, 0, -1)]]
		for c in caras:
			var z: float = c[0]
			var u0: float = c[1]
			var nrm: Vector3 = c[2]
			var q := [[Vector3(-h, y0, z), Vector2(u0, v0 + 0.5)], [Vector3(h, y0, z), Vector2(u0 + 0.5, v0 + 0.5)],
					[Vector3(h, y1, z), Vector2(u0 + 0.5, v0)], [Vector3(-h, y1, z), Vector2(u0, v0)]]
			var orden := [0, 2, 1, 0, 3, 2] if nrm.z > 0.0 else [0, 1, 2, 0, 2, 3]
			if nrm.z < 0.0:
				# la trasera se ve desde atrás: se refleja en U para que coincida con la silueta de la cara
				for e in q:
					e[1].x = u0 + 0.5 - (e[1].x - u0)
			for j in orden:
				st.set_normal(nrm)
				st.set_uv(q[j][1])
				st.add_vertex(q[j][0])
		# poste: tubo cuadrado de 6 cm desde 0,8 m bajo el suelo (talud) hasta lo alto de la placa
		var a := -0.03
		var b := 0.03
		var zb := -0.05
		var zf := 0.01
		var ya := -0.8
		var yb := y1 - 0.05
		var lados := [
			[Vector3(a, ya, zf), Vector3(b, ya, zf), Vector3(b, yb, zf), Vector3(a, yb, zf), Vector3(0, 0, 1)],
			[Vector3(b, ya, zb), Vector3(a, ya, zb), Vector3(a, yb, zb), Vector3(b, yb, zb), Vector3(0, 0, -1)],
			[Vector3(b, ya, zf), Vector3(b, ya, zb), Vector3(b, yb, zb), Vector3(b, yb, zf), Vector3(1, 0, 0)],
			[Vector3(a, ya, zb), Vector3(a, ya, zf), Vector3(a, yb, zf), Vector3(a, yb, zb), Vector3(-1, 0, 0)]]
		for l in lados:
			for j in [0, 2, 1, 0, 3, 2]:
				st.set_normal(l[4])
				st.set_uv(gris)
				st.add_vertex(l[j])
		_mallas.append(st.commit())
