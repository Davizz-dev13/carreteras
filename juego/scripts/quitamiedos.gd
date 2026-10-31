## Quitamiedos (bionda de doble onda) REALES: solo donde OpenStreetMap tiene una barrera mapeada junto a la ruta
## (datos/<zona>/quitamiedos.json, generado por pipeline/quitamiedos.py). Sin datos no se dibuja ninguno.
## Barato para la gráfica: por cada trozo de ~200 m de streaming, 2 MultiMesh (vallas y postes) con una malla
## low-poly y un material compartidos, sin sombras y con distancia de dibujado corta.
class_name Quitamiedos
extends RefCounted

const PASO_POSTE := 4.0       # m entre postes (bionda normal)
const TROZO_M := 200.0        # m por pieza de streaming (como los trozos de carretera)
const DIST_VISIBLE := 400.0   # m: más allá no se dibujan
const ALTO := 0.75            # m: canto superior de la bionda sobre la calzada
const BAJO_SUELO := 0.7       # m que el poste baja por debajo de la calzada (talud)

static var _malla_valla: ArrayMesh
static var _malla_poste: ArrayMesh
static var _mat: StandardMaterial3D


## Tramos del archivo de la zona → piezas [{ruta, lado, s0, s1, margen, caja: Rect2}] de ≤ TROZO_M m
static func piezas(dir_datos: String, rutas: Array) -> Array:
	var out := []
	var camino := dir_datos + "quitamiedos.json"
	if not FileAccess.file_exists(camino):
		return out
	var d = JSON.parse_string(FileAccess.get_file_as_string(camino))
	if not (d is Dictionary):
		return out
	var margen := float(d.get("margen_borde", 0.7))
	for r in d.get("rutas", []):
		var ri := int(r.get("ruta", -1))
		if ri < 0 or ri >= rutas.size():
			continue
		var ru: Ruta = rutas[ri]
		for t in r.get("tramos", []):
			var s0 := clampf(float(t["s0"]), 0.0, ru.longitud())
			var s1 := clampf(float(t["s1"]), 0.0, ru.longitud())
			var a := s0
			while a < s1 - 0.5:
				var b := minf(a + TROZO_M, s1)
				var mn := Vector2(INF, INF)
				var mx := Vector2(-INF, -INF)
				var s := a
				while true:
					var p := ru.punto(s)
					mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.z))
					mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.z))
					if s >= b:
						break
					s = minf(s + 20.0, b)
				out.append({"ruta": ru, "lado": int(t["lado"]), "s0": a, "s1": b, "margen": margen,
						"caja": Rect2(mn - Vector2(12, 12), mx - mn + Vector2(24, 24))})
				a = b
	return out


## Construye una pieza: postes cada PASO_POSTE m al borde de la calzada (ancho/2 + margen), a la altura de la calzada
static func construir(pz: Dictionary) -> Node3D:
	_preparar()
	var ru: Ruta = pz["ruta"]
	var lado := float(pz["lado"])
	var s0: float = pz["s0"]
	var s1: float = pz["s1"]
	var n := maxi(int(ceil((s1 - s0) / PASO_POSTE)), 1)
	var pts := PackedVector3Array()
	pts.resize(n + 1)
	for k in n + 1:
		var s := lerpf(s0, s1, float(k) / n)
		pts[k] = ru.punto(s) + ru.derecha(s) * lado * (ru.valor(ru.ancho, s) * 0.5 + float(pz["margen"]))
	var mm_v := MultiMesh.new()
	mm_v.transform_format = MultiMesh.TRANSFORM_3D
	mm_v.mesh = _malla_valla
	mm_v.instance_count = n
	var mm_p := MultiMesh.new()
	mm_p.transform_format = MultiMesh.TRANSFORM_3D
	mm_p.mesh = _malla_poste
	mm_p.instance_count = n + 1
	for k in n:
		# la valla mira a la calzada: se recorre en el sentido que deja la carretera a la izquierda (+X local)
		var a := pts[k] if lado > 0.0 else pts[k + 1]
		var b := pts[k + 1] if lado > 0.0 else pts[k]
		var z := b - a
		var largo := z.length()
		if largo < 0.01:
			z = Vector3.FORWARD
			largo = 0.01
		var zn := z / largo
		var x := Vector3.UP.cross(zn).normalized()
		var y := zn.cross(x)
		mm_v.set_instance_transform(k, Transform3D(Basis(x, y, zn * largo), a))
		mm_p.set_instance_transform(k, Transform3D(Basis(x, Vector3.UP, x.cross(Vector3.UP)), pts[k]))
	var ult := pts[n] - pts[n - 1] if n >= 1 else Vector3.FORWARD
	var xu := Vector3.UP.cross(ult.normalized() * (1.0 if lado > 0.0 else -1.0)).normalized()
	mm_p.set_instance_transform(n, Transform3D(Basis(xu, Vector3.UP, xu.cross(Vector3.UP)), pts[n]))
	var raiz := Node3D.new()
	for mm in [mm_v, mm_p]:
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
	_mat.albedo_color = Color(0.66, 0.68, 0.70)      # acero galvanizado
	_mat.metallic = 0.55
	_mat.roughness = 0.42
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED      # chapa fina: se ve por las dos caras
	# bionda de doble onda (perfil W, 31 cm de alto, ~8 cm de fondo), extruida 1 m en Z (la instancia la estira);
	# las ondas miran a la calzada (+X local) y van 15 cm por delante del poste (separador)
	var perfil := [Vector2(0.15, ALTO), Vector2(0.23, ALTO - 0.055), Vector2(0.23, ALTO - 0.10), Vector2(0.17, ALTO - 0.155),
			Vector2(0.23, ALTO - 0.21), Vector2(0.23, ALTO - 0.255), Vector2(0.15, ALTO - 0.31)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in perfil.size() - 1:
		var p0: Vector2 = perfil[i]
		var p1: Vector2 = perfil[i + 1]
		var t := (p1 - p0).normalized()
		var nrm := Vector3(-t.y, t.x, 0.0)    # normal hacia +X (hacia la calzada)
		if nrm.x < 0.0:
			nrm = -nrm
		var v := [Vector3(p0.x, p0.y, 0.0), Vector3(p1.x, p1.y, 0.0), Vector3(p1.x, p1.y, 1.0), Vector3(p0.x, p0.y, 1.0)]
		for j in [0, 1, 2, 0, 2, 3]:
			st.set_normal(nrm)
			st.add_vertex(v[j])
	_malla_valla = st.commit()
	# poste: perfil en C aproximado por una caja de 10 × 6 cm, desde BAJO_SUELO bajo la calzada hasta el canto
	var caja := BoxMesh.new()
	caja.size = Vector3(0.10, ALTO + BAJO_SUELO - 0.02, 0.06)
	var arr := caja.get_mesh_arrays()
	var desp := Vector3(0.05, (ALTO - 0.02 - BAJO_SUELO) * 0.5, 0.0)
	var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in vs.size():
		vs[i] += desp
	arr[Mesh.ARRAY_VERTEX] = vs
	_malla_poste = ArrayMesh.new()
	_malla_poste.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)


## Choque: los mismos tramos como paredes para el coche del jugador (biondas.gd). La cara que da a la calzada está
## a ancho/2 + margen − 0,23 m del eje (la onda va 15–23 cm por delante del poste, ver _preparar).
static func choque(dir_datos: String, rutas: Array) -> Biondas:
	var bi := Biondas.new()
	for pz in piezas(dir_datos, rutas):
		var ru: Ruta = pz["ruta"]
		var lado := float(pz["lado"])
		var s0: float = pz["s0"]
		var s1: float = pz["s1"]
		var n := maxi(int(ceil((s1 - s0) / PASO_POSTE)), 1)
		var ant := Vector3.ZERO
		for k in n + 1:
			var s := lerpf(s0, s1, float(k) / n)
			var der := ru.derecha(s)
			var p := ru.punto(s) + der * lado * (ru.valor(ru.ancho, s) * 0.5 + float(pz["margen"]) - 0.23)
			if k > 0:
				bi.anadir(ant, p, -Vector2(der.x, der.z) * lado)
			ant = p
	return bi
