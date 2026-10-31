## Superficie del mapa abierto: las calzadas de cada tesela cargada, en una rejilla de 40 m por tesela, y el terreno de
## la tesela si no hay calzada. Misma consulta que Superficie (coche.gd la usa a través de Ajustes.superficie).
class_name MaSuperficie
extends Superficie

const CELDA_MA := 40.0
var tesela := 2000.0
var teselas := {}        # Vector2i -> {a, b, hw, k, celdas, ter: {n, paso, x0, z0, h}}


## Índice de calzadas de una tesela (se construye en un hilo y se instala en el principal)
static func indice(segs_a: PackedVector3Array, segs_b: PackedVector3Array, hw: PackedFloat32Array) -> Dictionary:
	var celdas := {}
	for k in segs_a.size():
		var p := segs_a[k]
		var q := segs_b[k]
		var m := hw[k] + 1.5
		for cx in range(floori((minf(p.x, q.x) - m) / CELDA_MA), floori((maxf(p.x, q.x) + m) / CELDA_MA) + 1):
			for cz in range(floori((minf(p.z, q.z) - m) / CELDA_MA), floori((maxf(p.z, q.z) + m) / CELDA_MA) + 1):
				var c := Vector2i(cx, cz)
				if not celdas.has(c):
					celdas[c] = PackedInt32Array()
				celdas[c].append(k)
	return celdas


func poner(t: Vector2i, d: Dictionary) -> void:
	teselas[t] = d


func quitar(t: Vector2i) -> void:
	teselas.erase(t)


## Vector3(altura, en_carretera 0/1, tramo o -1)
func consultar(x: float, z: float, y_ref: float) -> Vector3:
	var t := Vector2i(floori(x / tesela), floori(z / tesela))
	var d = teselas.get(t)
	if d == null:
		return Vector3(y_ref, 0.0, -1.0)
	var lista: PackedInt32Array = d["celdas"].get(Vector2i(floori(x / CELDA_MA), floori(z / CELDA_MA)), PackedInt32Array())
	var sa: PackedVector3Array = d["a"]
	var sb: PackedVector3Array = d["b"]
	var shw: PackedFloat32Array = d["hw"]
	var sk: PackedInt32Array = d["k"]
	var mejor := 1e9
	var mejor_otro := 1e9
	var h := 0.0
	var h_otro := 0.0
	var id := -1
	var id_otro := -1
	for k in lista:
		var p := sa[k]
		var q := sb[k]
		var abx := q.x - p.x
		var abz := q.z - p.z
		var l2 := abx * abx + abz * abz
		var u := 0.0
		if l2 > 1e-6:
			u = clampf(((x - p.x) * abx + (z - p.z) * abz) / l2, 0.0, 1.0)
		var cx := p.x + abx * u
		var cz := p.z + abz * u
		var dist := sqrt((x - cx) * (x - cx) + (z - cz) * (z - cz))
		if dist > shw[k] + 0.6:
			continue
		var hy := p.y + (q.y - p.y) * u
		if absf(hy - y_ref) <= 2.5:
			if dist < mejor:
				mejor = dist
				h = hy
				id = sk[k]
		elif dist < mejor_otro or absf(hy - y_ref) < absf(h_otro - y_ref):
			mejor_otro = dist
			h_otro = hy
			id_otro = sk[k]
	if id >= 0:
		return Vector3(h, 1.0, id)
	var ht := terreno(d["ter"], x, z)
	if id_otro >= 0 and (absf(h_otro - y_ref) < absf(ht - y_ref)):
		return Vector3(h_otro, 1.0, id_otro)
	return Vector3(ht, 0.0, -1.0)


## Altura del terreno (misma triangulación que la malla de la tesela)
static func terreno(te: Dictionary, x: float, z: float) -> float:
	var n: int = te["n"]
	var paso: float = te["paso"]
	var h: PackedFloat32Array = te["h"]
	var fx := clampf((x - float(te["x0"])) / paso, 0.0, n - 1.001)
	var fz := clampf((z - float(te["z0"])) / paso, 0.0, n - 1.001)
	var i := int(fx)
	var j := int(fz)
	var u := fx - i
	var v := fz - j
	var h00 := h[j * n + i]
	var h10 := h[j * n + i + 1]
	var h01 := h[(j + 1) * n + i]
	var h11 := h[(j + 1) * n + i + 1]
	# triángulos (k, k+1, k+n) y (k+1, k+n+1, k+n)
	if u + v <= 1.0:
		return h00 + (h10 - h00) * u + (h01 - h00) * v
	return h11 + (h01 - h11) * (1.0 - u) + (h10 - h11) * (1.0 - v)
