## Señales de tráfico REALES de OpenStreetMap (STOP y ceda el paso en los cruces junto a la ruta) y ceda el paso en
## cada entrada a glorieta, de datos/<zona>/senales.json (pipeline/senales_cruces.py). Sin datos no se dibuja ninguna.
## Con cada señal van sus marcas viales ("marcas"): línea de detención o de ceda el paso en el carril que entra y el
## triángulo de ceda el paso; una malla por pieza de streaming, a ras de la calzada.
## Barato para la gráfica: piezas de streaming de 250 m; en cada una, un MultiMesh por tipo de señal con una malla
## low-poly (poste + placa + trasera) y un único material con un atlas de 256 px; sin sombras y visibles a ≤ 250 m.
class_name SenalesOsm
extends RefCounted

const CELDA := 250.0          # m de lado de cada pieza de streaming
const DIST_VISIBLE := 250.0
const TIPOS := ["R2", "R1"]   # fila del atlas: R2 (STOP) arriba, R1 (ceda el paso) abajo
const LADO := 0.9             # m (placa de carretera convencional)
const BAJO := 1.4             # m del suelo al borde inferior de la placa

const ALTO_MARCA := 0.06      # m sobre la calzada (como las demás marcas: sin parpadeo contra el asfalto)

static var _mallas: Array = []
static var _mat: StandardMaterial3D
static var _mat_marca: StandardMaterial3D


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
		var rumbo := float(s["rumbo"])
		# ceda de la otra calzada de una autovía que la ruta ya lleva (GlorietaTipo la quita): a la entrada del brazo
		# de la ruta, en el arcén derecho del que entra, 2 m antes de la línea, mirando a quien llega
		var ge := _gemela_cerca(p, 25.0) if str(s.get("acceso", "")).begins_with("glorieta") else {}
		if not ge.is_empty():
			var u: Vector3 = ge["u"]
			var nrm := Vector3(-u.z, 0.0, u.x)
			# 6 m antes del anillo, se busca el borde del asfalto (el abocinamiento lo ensancha) y se planta 1,2 m fuera
			var base: Vector3 = (ge["ruta_x0"] as Vector3) + u * 6.0
			var lat := float(ge["w"])
			if Ajustes.superficie != null:
				lat = float(ge["h"]) + 0.5
				while lat < float(ge["w"]) + 25.0:
					var qq := base - nrm * (lat + 0.5)
					if Ajustes.superficie.consultar(qq.x, qq.z, base.y).y < 0.5:
						break
					lat += 0.5
			p = base - nrm * (lat + 1.2)
			p.y = base.y
			rumbo = atan2(u.x, u.z)
		if Ajustes.superficie != null:
			var suelo: float = Ajustes.superficie.consultar(p.x, p.z, p.y).x
			if is_finite(suelo) and absf(suelo - p.y) < 6.0:
				p.y = suelo
		var clave := Vector2i(floori(p.x / CELDA), floori(p.z / CELDA))
		if not celdas.has(clave):
			celdas[clave] = []
		celdas[clave].append([ti, Transform3D(Basis(Vector3.UP, rumbo), p)])
	# marcas viales: polígonos (línea = 4 puntos, triángulo = 3) a la altura de la calzada
	var marcas := {}
	for m in d.get("marcas", []):
		var poli := PackedVector3Array()
		var pts_m: Array = m.get("p", [])
		if str(m.get("tipo", "")) == "triangulo" and pts_m.size() == 3:
			var cm := Vector3.ZERO
			for q in pts_m:
				cm += Vector3(float(q[0]), float(q[1]), float(q[2])) / 3.0
			var ge := {}
			if Ajustes.superficie != null and Ajustes.superficie.consultar(cm.x, cm.z, cm.y).y < 0.5:
				ge = _gemela_cerca(cm, 30.0)   # solo si se ha quedado fuera del asfalto
			if not ge.is_empty():
				# triángulo de ceda en el centro del carril de entrada del brazo de la ruta, 7 m antes de la línea,
				# con la punta hacia quien llega
				var u: Vector3 = ge["u"]
				var nrm := Vector3(-u.z, 0.0, u.x)
				var mc: Vector3 = (ge["ruta_x0"] as Vector3) - nrm * ((float(ge["w"]) + float(ge["h"])) * 0.5) + u * 7.0
				mc.y = cm.y
				pts_m = [[(mc + u * 1.6).x, mc.y, (mc + u * 1.6).z], [(mc - u * 1.6 + nrm * 0.6).x, mc.y, (mc - u * 1.6 + nrm * 0.6).z],
						[(mc - u * 1.6 - nrm * 0.6).x, mc.y, (mc - u * 1.6 - nrm * 0.6).z]]
		for q in pts_m:
			var v := Vector3(float(q[0]), float(q[1]), float(q[2]))
			if Ajustes.superficie != null:
				var h: float = Ajustes.superficie.consultar(v.x, v.z, v.y).x
				if is_finite(h) and absf(h - v.y) < 2.0:
					v.y = h
			v.y += ALTO_MARCA
			poli.append(v)
		if poli.size() < 3:
			continue
		var clave := Vector2i(floori(poli[0].x / CELDA), floori(poli[0].z / CELDA))
		if not marcas.has(clave):
			marcas[clave] = []
		marcas[clave].append(poli)
		if not celdas.has(clave):
			celdas[clave] = []
	var out := []
	for clave in celdas:
		var mn := Vector2(INF, INF)
		var mx := Vector2(-INF, -INF)
		for e in celdas[clave]:
			var o: Vector3 = e[1].origin
			mn = Vector2(minf(mn.x, o.x), minf(mn.y, o.z))
			mx = Vector2(maxf(mx.x, o.x), maxf(mx.y, o.z))
		for poli in marcas.get(clave, []):
			for o in poli:
				mn = Vector2(minf(mn.x, o.x), minf(mn.y, o.z))
				mx = Vector2(maxf(mx.x, o.x), maxf(mx.y, o.z))
		out.append({"senales": celdas[clave], "marcas": marcas.get(clave, []),
				"caja": Rect2(mn - Vector2(2, 2), mx - mn + Vector2(4, 4))})
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
	var marcas: Array = pz.get("marcas", [])
	if not marcas.is_empty():
		# líneas y triángulos de la pieza en una sola malla (abanico desde el primer punto; normales hacia arriba)
		var v := PackedVector3Array()
		var nr := PackedVector3Array()
		for poli in marcas:
			for k in range(1, poli.size() - 1):
				for q in [poli[0], poli[k + 1], poli[k]]:
					v.append(q)
					nr.append(Vector3.UP)
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = nr
		var malla := ArrayMesh.new()
		malla.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mi := MeshInstance3D.new()
		mi.mesh = malla
		mi.material_override = _mat_marca
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = DIST_VISIBLE
		raiz.add_child(mi)
	return raiz


static func _preparar() -> void:
	if _mat != null:
		return
	_mat_marca = StandardMaterial3D.new()
	_mat_marca.albedo_color = Color(0.92, 0.92, 0.9)
	_mat_marca.roughness = 0.6
	_mat_marca.metallic_specular = 0.1
	_mat_marca.cull_mode = BaseMaterial3D.CULL_DISABLED
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


## Calzada gemela quitada junto a una glorieta (GlorietaMalla.gemelas) cuya boca está a menos de 25 m de p
static func _gemela_cerca(p: Vector3, radio: float) -> Dictionary:
	for ge in GlorietaMalla.gemelas:
		var x0: Vector3 = ge["x0"]
		if Vector2(p.x - x0.x, p.z - x0.z).length() < radio and absf(p.y - x0.y) < 6.0:
			return ge
	return {}
