## Modelo 3D procedural de un coche a partir de un perfil (secciones transversales a lo largo del coche),
## construido a sus MEDIDAS REALES (largo, ancho, alto, batalla y vía de la ficha). Low-poly y con mallas
## compartidas entre todos los coches iguales, para que el tráfico no cargue la gráfica.
## Perfil (en el JSON): "voladizo_del" en m y "secciones": [t, bajo, cintura, techo, semiancho,
##   semiancho_cristal_abajo, semiancho_cristal_arriba, lateral_cristal(0/1), superior_cristal(0/1)]
##   t: 0 = paragolpes delantero … 1 = trasero; alturas en fracción del alto; anchos en fracción del semiancho.
class_name ModeloProcedural
extends RefCounted

const CARROCERIA := 0
const CRISTAL := 1
const NEGRO := 2
const LUZ := 3
const PILOTO := 4


static func construir(perfil: Dictionary, f: Ficha) -> Dictionary:
	var L := f.largo
	var H := f.alto
	var W := f.ancho * 0.5
	var vd: float = float(perfil.get("voladizo_del", (L - f.batalla) * 0.45))
	var z_del := -(f.batalla * 0.5 + vd)
	var secs: Array = perfil.get("secciones", [])
	var st := []
	for i in 5:
		var s := SurfaceTool.new()
		s.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.append(s)
	# anillos (mitad derecha) de cada sección
	var anillos := []
	for s in secs:
		var z := z_del + float(s[0]) * L
		var bajo := float(s[1]) * H
		var cint := float(s[2]) * H
		var techo := float(s[3]) * H
		var sw := float(s[4]) * W
		var pts := PackedVector3Array()
		pts.append(Vector3(0, bajo, z))
		pts.append(Vector3(sw * 0.9, bajo, z))
		pts.append(Vector3(sw, bajo + 0.35 * (cint - bajo), z))
		pts.append(Vector3(sw * 0.985, cint, z))
		if techo > cint + 0.01:
			pts.append(Vector3(float(s[5]) * W, cint + 0.012 * H, z))
			pts.append(Vector3(float(s[6]) * W, techo - 0.03 * H, z))
			pts.append(Vector3(0, techo, z))
		else:
			pts.append(Vector3(sw * 0.9, cint + 0.012, z))
			pts.append(Vector3(sw * 0.55, cint + 0.022, z))
			pts.append(Vector3(0, cint + 0.026, z))
		anillos.append(pts)
	# bandas entre secciones consecutivas
	for i in secs.size() - 1:
		var a: PackedVector3Array = anillos[i]
		var b: PackedVector3Array = anillos[i + 1]
		var s = secs[i]
		var tiene_cristal := float(s[3]) > float(s[2]) + 0.01 and float(secs[i + 1][3]) > float(secs[i + 1][2]) + 0.01
		for k in 6:
			var mat := CARROCERIA
			if k == 0: mat = NEGRO
			elif k == 4 and tiene_cristal and int(s[7]) == 1: mat = CRISTAL
			elif k == 5 and tiene_cristal and int(s[8]) == 1: mat = CRISTAL
			_quad_espejo(st[mat], a[k], a[k + 1], b[k + 1], b[k])
	# tapas delantera y trasera
	_tapa(st[CARROCERIA], anillos[0], true)
	_tapa(st[CARROCERIA], anillos[anillos.size() - 1], false)
	# detalles: parrilla, faros con la barra LED, pilotos, retrovisores
	for d in perfil.get("detalles", []):
		var mat: int = {"carroceria": CARROCERIA, "cristal": CRISTAL, "negro": NEGRO, "luz": LUZ, "piloto": PILOTO}.get(d[0], NEGRO)
		var lado: float = float(d[1])
		var y: float = float(d[2]) * H
		var z := z_del + float(d[3]) * L
		var tam := Vector3(float(d[4]), float(d[5]), float(d[6]))
		if lado == 0.0:
			_caja(st[mat], Vector3(0, y, z), tam)
		else:
			_caja(st[mat], Vector3(lado * W, y, z), tam)
			_caja(st[mat], Vector3(-lado * W, y, z), tam)
	var malla := ArrayMesh.new()
	var mats := _materiales()
	for i in 5:
		st[i].generate_normals()
		st[i].set_material(mats[i])
		st[i].commit(malla)
	# rueda (neumático + llanta)
	var r := float(perfil.get("radio_rueda", 0.34))
	var neum := CylinderMesh.new()
	neum.top_radius = r
	neum.bottom_radius = r
	neum.height = float(perfil.get("ancho_rueda", 0.245))
	neum.radial_segments = 14
	neum.rings = 1
	var mrueda := StandardMaterial3D.new()
	mrueda.albedo_color = Color(0.06, 0.06, 0.065)
	mrueda.roughness = 0.9
	neum.material = mrueda
	# las ruedas asoman un poco por fuera de la carrocería (si no, el lateral las taparía: no hay pasos de rueda)
	var x := maxf(f.via * 0.5, W - neum.height * 0.5 + 0.03)
	var zr := f.batalla * 0.5
	return {"carroceria": malla, "rueda": neum,
			"ruedas": [Vector3(-x, r, -zr), Vector3(x, r, -zr), Vector3(-x, r, zr), Vector3(x, r, zr)]}


static func _materiales() -> Array:
	var carr := StandardMaterial3D.new()        # se sustituye por el color de cada coche
	carr.albedo_color = Color(0.8, 0.8, 0.8)
	var cristal := StandardMaterial3D.new()
	cristal.albedo_color = Color(0.035, 0.045, 0.06)
	cristal.metallic = 0.0
	cristal.roughness = 0.25
	cristal.metallic_specular = 0.35
	var negro := StandardMaterial3D.new()
	negro.albedo_color = Color(0.04, 0.04, 0.045)
	negro.roughness = 0.7
	var luz := StandardMaterial3D.new()
	luz.albedo_color = Color(1, 0.97, 0.9)
	luz.emission_enabled = true
	luz.emission = Color(1, 0.97, 0.88)
	luz.emission_energy_multiplier = 1.5
	var piloto := StandardMaterial3D.new()
	piloto.albedo_color = Color(0.75, 0.03, 0.03)
	piloto.emission_enabled = true
	piloto.emission = Color(0.7, 0.0, 0.0)
	return [carr, cristal, negro, luz, piloto]


## Cara (a, b, c, d) en el lado derecho y su simétrica en el izquierdo (orden de vértices invertido)
static func _quad_espejo(s: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_quad(s, a, b, c, d)
	var m := Vector3(-1, 1, 1)
	_quad(s, d * m, c * m, b * m, a * m)


static func _quad(s: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	if a.distance_squared_to(b) + a.distance_squared_to(d) < 1e-8:
		return
	for p in [a, c, b, a, d, c]:
		s.add_vertex(p)


static func _tapa(s: SurfaceTool, anillo: PackedVector3Array, delantera: bool) -> void:
	var c := Vector3.ZERO
	for p in anillo: c += p
	c /= anillo.size()
	var m := Vector3(-1, 1, 1)
	for k in anillo.size() - 1:
		var p := anillo[k]
		var q := anillo[k + 1]
		if delantera:
			for v in [c, p, q, c, q * m, p * m]: s.add_vertex(v)
			continue
		for v in [c, q, p, c, p * m, q * m]: s.add_vertex(v)


static func _caja(s: SurfaceTool, c: Vector3, t: Vector3) -> void:
	var h := t * 0.5
	var v := [c + Vector3(-h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, -h.z), c + Vector3(h.x, h.y, -h.z), c + Vector3(-h.x, h.y, -h.z),
			c + Vector3(-h.x, -h.y, h.z), c + Vector3(h.x, -h.y, h.z), c + Vector3(h.x, h.y, h.z), c + Vector3(-h.x, h.y, h.z)]
	for q in [[0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4]]:
		_quad(s, v[q[0]], v[q[1]], v[q[2]], v[q[3]])
