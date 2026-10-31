
import sys, math
sys.path.append('/usr/lib/python3/dist-packages')
import numpy as np; np.bool=bool
import bpy, bmesh
src, out, ratio = sys.argv[-3], sys.argv[-2], float(sys.argv[-1])
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
def tri(o): return sum(len(p.vertices)-2 for p in o.data.polygons)
QUITAR = ("__nada__",)
INTER = ("interior", "leather", "grey")
for o in list(bpy.context.scene.objects):
    pass  # las pinzas se quedan (sin ellas la rueda se ve oscura)
def solo(o):
    bpy.ops.object.select_all(action='DESELECT'); o.select_set(True); bpy.context.view_layer.objects.active = o
for o in [o for o in bpy.context.scene.objects if o.type == 'MESH']:
    solo(o)
    # las normales personalizadas del glTF no sobreviven a la reducción: se quitan y se recalcula el sombreado
    if o.name.startswith("pinza"):
        continue
    if o.name.startswith("carroceria"):
        nombre = o.name; padre = o.parent
        bm = bmesh.new(); bm.from_mesh(o.data)
        malos = [i for i, m in enumerate(o.data.materials) if m and m.name.lower().startswith(QUITAR)]
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.material_index in malos], context='FACES')
        bm.to_mesh(o.data); bm.free()
        bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT'); bpy.ops.mesh.separate(type='MATERIAL'); bpy.ops.object.mode_set(mode='OBJECT')
        partes = list(bpy.context.selected_objects)
        for p in partes:
            solo(p)
            t0 = tri(p)
            nm = p.active_material.name.lower() if p.active_material else ""
            if t0 > 300:
                m = p.modifiers.new("d", 'DECIMATE'); m.ratio = (0.2 if nm.startswith(INTER) else ratio); m.use_collapse_triangulate = True
                bpy.ops.object.modifier_apply(modifier="d")
            print("DBG", p.active_material.name if p.active_material else "?", t0, "->", tri(p))
        bpy.ops.object.select_all(action='DESELECT')
        for p in partes:
            if len(p.data.polygons) > 0: p.select_set(True)
            else: bpy.data.objects.remove(p, do_unlink=True)
        partes = [p for p in partes if p.name in bpy.data.objects]
        bpy.context.view_layer.objects.active = partes[0]
        bpy.ops.object.join()
        partes[0].name = nombre
        bpy.ops.object.material_slot_remove_unused()
    else:
        t0 = tri(o)
        m = o.modifiers.new("d", 'DECIMATE'); m.ratio = 1500 / t0; m.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier="d")
        print("DBG rueda", t0, "->", tri(o))

for clave in ("del_der", "del_izq", "tra_der", "tra_izq"):
    ru = bpy.data.objects.get("rueda_" + clave); pz = bpy.data.objects.get("pinza_" + clave)
    if ru and pz:
        bpy.ops.object.select_all(action='DESELECT'); pz.select_set(True); ru.select_set(True)
        bpy.context.view_layer.objects.active = ru; bpy.ops.object.join()

GRUPOS = {"glass_dark": "glass_darkB", "glass_clear": "glass_led", "glass_lens": "glass_led",
    "silver": "chrome", "alumimium": "chrome", "reflect": "chrome", "led": "chrome",
    "glass_red_Illum": "glass_red", "black": "plasticblack", "plasticGlossy": "plasticblack", "metal_dark": "plasticblack",
    "interiorPlastic": "plasticblack", "interiorA": "plasticblack", "interiorB": "plasticblack", "interiorTex": "plasticblack",
    "leather": "plasticblack", "grey": "plasticblack"}
def agrupar(o, destino_fijo=None, conservar=()):
    mats = [m for m in o.data.materials]
    nuevos = []
    idx_nuevo = []
    for m in mats:
        base = m.name.split(".")[0] if m else ""
        if destino_fijo and base not in conservar:
            dest = destino_fijo
        else:
            dest = GRUPOS.get(base, base)
        dm = bpy.data.materials.get(dest) or m
        if dm not in nuevos: nuevos.append(dm)
        idx_nuevo.append(nuevos.index(dm))
    idx = np.empty(len(o.data.polygons), dtype=np.int32); o.data.polygons.foreach_get("material_index", idx)
    idx = np.array(idx_nuevo, dtype=np.int32)[idx] if len(idx) else idx
    o.data.materials.clear()
    for m in nuevos: o.data.materials.append(m)
    o.data.polygons.foreach_set("material_index", idx); o.data.update()
    print("DBG grupos", o.name, [m.name for m in nuevos])
for o in [o for o in bpy.context.scene.objects if o.type == 'MESH']:
    if o.name.startswith("carroceria"): agrupar(o)
    elif o.name.startswith("rueda"): agrupar(o, "rimDark", ("tire",))
    elif o.name.startswith("pinza"): agrupar(o, "rimDark")

tot = sum(tri(o) for o in bpy.context.scene.objects if o.type == 'MESH')
print("DBG total", tot)
bpy.ops.export_scene.gltf(filepath=out, export_format='GLB', export_yup=True, export_apply=True)
