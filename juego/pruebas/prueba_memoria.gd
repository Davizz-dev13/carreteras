## Prueba de memoria (partida larga con piloto): godot --path . res://pruebas/prueba_memoria.tscn -- --zona=… --minutos=25
## Simula varios pasos de física por fotograma (dibujando de verdad) y escribe cada 30 s simulados los monitores de memoria.
extends Node

var juego: Node
var t_sim := 0.0
var t_log := -1.0
var minutos := 25.0
var pasos := 15
var vueltas := 0
var f: FileAccess

func _ready() -> void:
	minutos = float(Ajustes.args.get("minutos", "25"))
	pasos = int(Ajustes.args.get("pasos", "15"))
	f = FileAccess.open(Ajustes.args.get("log", "user://memoria.tsv"), FileAccess.WRITE)
	f.store_line("t_min\tpk_km\tvueltas\tvideo_MB\ttex_MB\tbuf_MB\tobjetos\trecursos\tnodos\thuerfanos\tdraws\tprims_k\tcoches\tpiezas\tfps")
	juego = load("res://escenas/juego.tscn").instantiate()
	add_child(juego)

func _mon(m) -> float:
	return Performance.get_monitor(m)

func _process(_dt: float) -> void:
	if juego == null or not juego.cargado:
		return
	if Ajustes.args.has("salto"):
		_salto()
		return
	for i in pasos:
		if juego.piloto and juego.adel_estado == 0 and not juego._lider_lento().is_empty():
			juego._pedir_adelantamiento()
		juego._simular(1.0 / 60.0)
		t_sim += 1.0 / 60.0
		if juego.terminado:
			# vuelta en sentido contrario (teletransporte: la ventana del mapa se reconstruye)
			var a: float = juego.s_ini
			juego.s_ini = juego.s_fin
			juego.s_fin = a
			juego.dir = -juego.dir
			juego._reiniciar(true)
			juego.trafico.reiniciar_interpolacion()
			vueltas += 1
			break
	if t_sim - t_log >= 30.0 or t_log < 0.0:
		t_log = t_sim
		var linea := "%.1f\t%.2f\t%d\t%.1f\t%.1f\t%.1f\t%d\t%d\t%d\t%d\t%d\t%.0f\t%d\t%d\t%.1f" % [t_sim / 60.0, juego.s_coche / 1000.0, vueltas,
			_mon(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, _mon(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
			_mon(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0, _mon(Performance.OBJECT_COUNT), _mon(Performance.OBJECT_RESOURCE_COUNT),
			_mon(Performance.OBJECT_NODE_COUNT), _mon(Performance.OBJECT_ORPHAN_NODE_COUNT), _mon(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			_mon(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0, juego.trafico.coches.size(), juego.mundo.streaming.piezas_vivas(), Engine.get_frames_per_second()]
		print(linea)
		f.store_line(linea)
		f.flush()
	if t_sim >= minutos * 60.0:
		Node.print_orphan_nodes()
		f.close()
		get_tree().quit()


## --salto=M: recorre la ruta a saltos de M m por fotograma (ida y vuelta), con el tráfico y el streaming al día,
## para ver en pocos minutos si algo crece con los km recorridos (cada km es como ~30 s de conducción a 120 km/h)
var s_salto := -1.0
var dir_salto := 1
var km_hechos := 0.0
func _salto() -> void:
	var ruta = juego.ruta
	var m := float(Ajustes.args["salto"])
	if s_salto < 0.0: s_salto = juego.s_coche
	s_salto += m * dir_salto
	if s_salto > ruta.longitud() - 50.0 or s_salto < 50.0:
		dir_salto = -dir_salto
		vueltas += 1
		s_salto = clampf(s_salto, 50.0, ruta.longitud() - 50.0)
	km_hechos += m / 1000.0
	juego.dir = dir_salto
	var lado: float = ruta.lateral_carril(s_salto, dir_salto)
	juego.coche.colocar(ruta.punto(s_salto) + ruta.derecha(s_salto) * lado, ruta.tangente(s_salto) * dir_salto)
	juego.coche.v = 25.0
	juego.s_coche = s_salto
	for i in 6:
		juego.trafico.actualizar(1.0 / 60.0, s_salto, 0.0, 25.0 * dir_salto, dir_salto)
	var st = juego.mundo.streaming
	st.actualizar(juego.coche.position, ruta.tangente(s_salto) * dir_salto)
	st._construir_cola(Vector2(juego.coche.position.x, juego.coche.position.z), -1)
	t_sim = km_hechos * 30.0   # equivalente: 1 km = 30 s a 120 km/h
	if t_sim - t_log >= 30.0 or t_log < 0.0:
		t_log = t_sim
		var linea := "%.1f\t%.2f\t%d\t%.1f\t%.1f\t%.1f\t%d\t%d\t%d\t%d\t%d\t%.0f\t%d\t%d\t%.1f" % [t_sim / 60.0, s_salto / 1000.0, vueltas,
			_mon(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, _mon(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
			_mon(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0, _mon(Performance.OBJECT_COUNT), _mon(Performance.OBJECT_RESOURCE_COUNT),
			_mon(Performance.OBJECT_NODE_COUNT), _mon(Performance.OBJECT_ORPHAN_NODE_COUNT), _mon(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			_mon(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0, juego.trafico.coches.size(), st.piezas_vivas(), Engine.get_frames_per_second()]
		print(linea)
		f.store_line(linea)
		f.flush()
	if t_sim >= minutos * 60.0:
		Node.print_orphan_nodes()
		f.close()
		get_tree().quit()
