extends Node
## Solo verificación: en el mapa abierto, tráfico al 100 % durante `minutos` simulados alrededor de (x, z); cuenta
## los avances en sentido horario por los anillos de las glorietas (debe ser 0), los coches en un tramo de anillo
## contra su sentido (debe ser 0), las pasadas por anillos y las paradas para ceder el paso al entrar.
##   godot --headless --fixed-fps 60 res://pruebas/madrid_glorietas_trafico.tscn -- --x=47250 --z=-3750 --minutos=10 --salida=/tmp/m.json
var j
var centros := {}   # tramo de anillo -> centro del anillo (centroide del ciclo)

func _ready() -> void:
	var a := Ajustes.args
	Ajustes.args["piloto"] = "0"
	Ajustes.args["trafico"] = "100"
	Ajustes.trafico = 1.0
	j = load("res://escenas/madrid.tscn").instantiate()
	add_child(j)
	while not j.cargado:
		await get_tree().process_frame
	j.en_prueba = true
	j.piloto = false
	j.coche.v = 0.0
	var frames := int(float(a.get("minutos", "10")) * 3600.0)
	var tramos: Array = j.datos.tramos
	var prev := {}
	var horario := 0
	var horario_coches := {}
	var contrario := 0
	var muestras_anillo := 0
	var pasadas := {}
	var ceden := 0
	var max_coches := 0
	for fr in frames:
		j.coche.v = 0.0
		j._simular(1.0 / 60.0)
		max_coches = maxi(max_coches, j.trafico.coches.size())
		for c in j.trafico.coches:
			var id: int = c["nodo"].get_instance_id()
			var k: int = c["k"]
			var t: Dictionary = tramos[k]
			if int(t["rot"]) != 1:
				prev.erase(id)
				var sig: Array = c["sig"]
				if fr % 30 == 0 and float(c["v"]) < 0.3 and not sig.is_empty() and int(sig[0]) >= 0 and int(tramos[int(sig[0])]["rot"]) == 1 and j.red.longitud(k) - float(c["d"]) < 32.0:
					ceden += 1
				continue
			muestras_anillo += 1
			if int(t["s"]) != 0 and int(c["sd"]) != int(t["s"]):
				contrario += 1
			var cc: Vector3 = _centro(k)
			var q: Vector3 = c["nodo"].position
			var th := atan2(-(q.z - cc.z), q.x - cc.x)
			if prev.has(id):
				var d := wrapf(th - float(prev[id][0]), -PI, PI)
				var q0: Vector3 = prev[id][1]
				if d < -0.0005 and q.distance_to(q0) > 0.01:
					horario += 1
					horario_coches[id] = true
				pasadas[id] = true
			prev[id] = [th, q]
		if fr % 600 == 0:
			await get_tree().process_frame
	var res := {"x": a.get("x"), "z": a.get("z"), "sim_min": frames / 3600.0, "coches_max": max_coches,
		"muestras_en_anillo": muestras_anillo, "coches_por_anillos": pasadas.size(), "avances_horarios": horario,
		"coches_horarios": horario_coches.size(), "contra_sentido_en_anillo": contrario, "muestras_parado_cediendo": ceden, "cuadros_cediendo_el_paso": j.trafico.cuadros_cediendo, "cuadros_ante_glorieta": j.trafico.cuadros_ante_glorieta}
	var f := FileAccess.open(a.get("salida", "user://madrid_glorietas.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, " "))
	f.close()
	print("MADRID_GLORIETAS ", JSON.stringify(res))
	get_tree().quit()


## Centroide del anillo que contiene el tramo k (siguiendo los tramos de anillo en su sentido hasta cerrar)
func _centro(k0: int) -> Vector3:
	if centros.has(k0):
		return centros[k0]
	var tramos: Array = j.datos.tramos
	var suma := Vector3.ZERO
	var n := 0
	var k := k0
	var vistos := []
	for paso in 80:
		vistos.append(k)
		var g: PackedVector3Array = j.datos.geometria(k)
		for p in g:
			suma += p
			n += 1
		var t: Dictionary = tramos[k]
		var fin := int(t["b"]) if int(t["s"]) >= 0 else int(t["a"])
		var sig := -1
		for k2 in j.datos.nodos[fin][3]:
			var t2: Dictionary = tramos[int(k2)]
			if int(k2) != k and int(t2["rot"]) == 1 and (int(t2["a"]) if int(t2["s"]) >= 0 else int(t2["b"])) == fin:
				sig = int(k2)
				break
		if sig < 0 or sig == k0:
			break
		k = sig
	var c := suma / maxf(n, 1)
	for x in vistos:
		centros[x] = c
	return c
