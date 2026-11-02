class_name Retrovisor
extends Node
## Retrovisor interior de la cabina: el cristal del espejo (nodo "espejo_interior" del modelo, ver
## modelos/postproceso_arteon.py) muestra lo que ve una cámara pequeña colocada en el espejo y mirando hacia atrás
## (asientos traseros, luneta y la carretera de detrás). Solo funciona en la cámara de cabina; se dibuja un fotograma de
## cada dos a 320 x 80 y con 400 m de alcance. En gráficos "bajo" y en la web no se crea (el espejo queda oscuro).
## Uso: retrovisor.preparar(coche); add_child(retrovisor); cada fotograma retrovisor.actualizar(Ajustes.camara == 1).
var vista: SubViewport = null
var camara: Camera3D = null
var espejo: MeshInstance3D = null
var activo := false
var _par := false


func preparar(c: Node3D) -> void:
	var modelo: Node3D = c.get("modelo")
	if modelo == null or not modelo.has_meta("espejo"):
		return
	espejo = modelo.get_meta("espejo")
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.05, 0.05)
	mat.metallic = 1.0
	mat.roughness = 0.12
	espejo.material_override = mat
	if OS.has_feature("web") or Paisaje.graficos == "bajo":
		return
	vista = SubViewport.new()
	camara = Camera3D.new()
	vista.size = Vector2i(320, 80)
	vista.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vista.positional_shadow_atlas_size = 0
	add_child(vista)
	camara.keep_aspect = Camera3D.KEEP_WIDTH
	camara.fov = 48.0
	camara.near = 0.05
	camara.far = 400.0
	vista.add_child(camara)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = vista.get_texture()
	m.albedo_color = Color(0.82, 0.82, 0.82)     # un espejo real devuelve algo menos de luz
	espejo.material_override = m
	activo = true


func actualizar(cabina: bool) -> void:
	if not activo:
		return
	if not cabina or not espejo.is_visible_in_tree():
		vista.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	_par = not _par
	vista.render_target_update_mode = SubViewport.UPDATE_ONCE if _par else SubViewport.UPDATE_DISABLED
	# en el centro del espejo, mirando hacia atrás del coche (+Z local) y un poco hacia abajo
	var t := espejo.get_global_transform_interpolated()
	var centro := t * espejo.get_aabb().get_center()
	var atras := t.basis.z.normalized()
	var arriba := t.basis.y.normalized()
	camara.global_transform = Transform3D(Basis.looking_at(atras - arriba * 0.05, arriba), centro + atras * 0.03)
