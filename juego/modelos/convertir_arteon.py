
import sys
sys.path.append('/usr/lib/python3/dist-packages')
import bpy, bmesh, math, json
import numpy as np
np.bool = bool
np.int = int
np.float = float
from mathutils import Vector, Matrix
argv = sys.argv[sys.argv.index("--")+1:]
src, out0, out1, info_path = argv[:4]
L_REAL = float(argv[4]); BATALLA_REAL=float(argv[5])
info = {}
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
scn = bpy.context.scene
meshes = [o for o in scn.objects if o.type == 'MESH']
for o in meshes:
    mw = o.matrix_world.copy(); o.parent = None; o.matrix_world = mw
for o in list(scn.objects):
    if o.type != 'MESH': bpy.data.objects.remove(o, do_unlink=True)
def sel(objs, active=None):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs: o.select_set(True)
    bpy.context.view_layer.objects.active = active or objs[0]
sel(meshes)
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
def matname(o):
    n = o.material_slots[0].material.name if o.material_slots and o.material_slots[0].material else "none"
    return n.split(".")[0]
def verts(o):
    n = len(o.data.vertices); a = np.empty(n*3, dtype=np.float64); o.data.vertices.foreach_get("co", a); return a.reshape(-1,3)
def ntris(o):
    return sum(len(p.vertices)-2 for p in o.data.polygons)
allv = np.vstack([verts(o) for o in meshes])
mn, mx = allv.min(0), allv.max(0); info["bbox_import"] = [mn.tolist(), mx.tolist()]
# eje largo y morro (faros = material led)
ext = mx - mn
ax = 0 if ext[0] > ext[1] else 1
led = np.vstack([verts(o) for o in meshes if matname(o) in ("led", "glass_lens")])
mid = (mn + mx) / 2
front_sign = 1 if led[:, ax].mean() > mid[ax] else -1
info["len_axis"] = ax; info["front_sign"] = front_sign
# rotar para morro hacia +Y
if ax == 0:
    R = Matrix.Rotation(math.radians(90 if front_sign > 0 else -90), 4, 'Z')
else:
    R = Matrix.Identity(4) if front_sign > 0 else Matrix.Rotation(math.pi, 4, 'Z')
for o in meshes: o.data.transform(R)
allv = np.vstack([verts(o) for o in meshes]); mn, mx = allv.min(0), allv.max(0)
# ruedas a partir de los neumáticos
tires = [o for o in meshes if matname(o) == "tire"]
sel(tires); bpy.ops.object.join(); tire = bpy.context.view_layer.objects.active
tv = verts(tire)
cy = (tv[:,1].min() + tv[:,1].max())/2
wheels = {}
for kx, sx in (("izq", -1), ("der", 1)):
    for ky, sy in (("del", 1), ("tra", -1)):
        m = (np.sign(tv[:,0]) == sx) & (np.sign(tv[:,1]-cy) == sy)
        p = tv[m]; a, b = p.min(0), p.max(0)
        wheels[ky+"_"+kx] = {"c": ((a+b)/2).tolist(), "r": float((b[2]-a[2])/2), "x": [float(a[0]), float(b[0])]}
info["wheels_raw"] = wheels
# escala y origen: centro de batalla, suelo = parte baja del neumático
yf = (wheels["del_izq"]["c"][1] + wheels["del_der"]["c"][1]) / 2
yr = (wheels["tra_izq"]["c"][1] + wheels["tra_der"]["c"][1]) / 2
ground = float(tv[:,2].min())
s = L_REAL / float(mx[1] - mn[1])
info["scale"] = s
T = Matrix.Scale(s, 4) @ Matrix.Translation((0, -(yf+yr)/2, -ground))
for o in [o for o in scn.objects if o.type == 'MESH']:
    o.data.transform(T)
meshes = [o for o in scn.objects if o.type == 'MESH']
for k, w in wheels.items():
    c = Vector(w["c"]); c = T @ c
    w["c"] = list(c); w["r"] *= s; w["x"] = [ (x)*s for x in w["x"] ]
info["wheels"] = wheels
allv = np.vstack([verts(o) for o in meshes]); mn, mx = allv.min(0), allv.max(0)
info["dims_m"] = (mx-mn).tolist(); info["bbox"] = [mn.tolist(), mx.tolist()]
info["batalla_m"] = wheels["del_izq"]["c"][1] - wheels["tra_izq"]["c"][1]
info["via_del_m"] = wheels["del_der"]["c"][0] - wheels["del_izq"]["c"][0]
info["via_tra_m"] = wheels["tra_der"]["c"][0] - wheels["tra_izq"]["c"][0]
# body width without mirrors: carpaint verts below mirror height? use widest carpaint at z < 0.9 m
cp = np.vstack([verts(o) for o in meshes if matname(o) == "carpaint"])
low = cp[cp[:,2] < 0.85]
info["ancho_carroceria_m"] = float(low[:,0].max() - low[:,0].min())
info["alto_m"] = float(mx[2])
# ---- separar piezas de rueda
cand = {"tire","rimDark","chrome_brushed_brakedisc","metal_def","metal_dark","chrome","black","plasticblack","silver","alumimium","grey"}
parts_rot = {k: [] for k in wheels}; parts_static = {k: [] for k in wheels}
for o in [o for o in meshes if matname(o) in cand]:
    sel([o]); bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.separate(type='LOOSE'); bpy.ops.object.mode_set(mode='OBJECT')
    pieces = list(bpy.context.selected_objects)
    for pc in pieces:
        v = verts(pc); a, b = v.min(0), v.max(0); cc = (a+b)/2
        for k, w in wheels.items():
            c = np.array(w["c"]); r = w["r"]
            x0, x1 = w["x"]; inner_out = 0.45*r
            if c[0] < 0: xa, xb = x0 - 0.03, x1 + inner_out
            else: xa, xb = x0 - inner_out, x1 + 0.03
            if a[0] < xa or b[0] > xb: continue
            rad = np.sqrt((v[:,1]-c[1])**2 + (v[:,2]-c[2])**2)
            if rad.max() > r*1.03: continue
            off = math.hypot(cc[1]-c[1], cc[2]-c[2]); ey, ez = b[1]-a[1], b[2]-a[2]
            size = max(ey, ez)
            sym = off < 0.12*r and abs(ey-ez) < 0.2*max(size,1e-6)
            small = size < 0.25*r and off < 0.95*r
            (parts_rot if (sym or small) else parts_static)[k].append(pc)
            pc["wheel"] = 1
            break
meshes = [o for o in scn.objects if o.type == 'MESH']
info["wheel_parts"] = {k: [len(parts_rot[k]), len(parts_static[k])] for k in wheels}
def join(objs, name):
    objs = [o for o in objs if o.name in bpy.data.objects]
    if not objs: return None
    sel(objs); 
    if len(objs) > 1: bpy.ops.object.join()
    o = bpy.context.view_layer.objects.active; o.name = name; o.data.name = name
    return o
wheel_objs = {}
for k, w in wheels.items():
    for kind, lst in (("rueda", parts_rot[k]), ("pinza", parts_static[k])):
        o = join(lst, kind + "_" + k)
        if o is None: continue
        c = Vector(w["c"]); o.data.transform(Matrix.Translation(-c)); o.location = c
        wheel_objs[o.name] = o
body = [o for o in scn.objects if o.type == 'MESH' and o.name not in wheel_objs]
# volver a unir por material las piezas sueltas que no son de rueda (miles de objetos si no)
bym = {}
for o in body:
    bym.setdefault(o.material_slots[0].material.name if o.material_slots and o.material_slots[0].material else "none", []).append(o)
for mname, lst in bym.items():
    if len(lst) > 1: join(lst, "c_" + mname)
info["objetos_tras_unir"] = sorted(o.name for o in scn.objects if o.type == 'MESH')
print("DBG2", len(info["objetos_tras_unir"]), info["objetos_tras_unir"][:60])
# ---- materiales limpios (PBR opacos salvo cristales)
P = {  # base rgb, metallic, roughness, alpha, emission rgb, emission strength
 "carpaint": ((0.55,0.56,0.58),0.6,0.3,1,None,0),
 "chrome": ((0.92,0.92,0.92),1.0,0.1,1,None,0),
 "silver": ((0.78,0.78,0.8),1.0,0.22,1,None,0),
 "alumimium": ((0.8,0.8,0.82),1.0,0.3,1,None,0),
 "rimDark": ((0.62,0.63,0.65),1.0,0.28,1,None,0),
 "chrome_brushed_brakedisc": ((0.42,0.42,0.42),1.0,0.45,1,None,0),
 "metal_dark": ((0.1,0.1,0.1),0.8,0.55,1,None,0),
 "metal_def": ((0.3,0.3,0.32),0.8,0.5,1,None,0),
 "plasticblack": ((0.025,0.025,0.025),0.0,0.6,1,None,0),
 "black": ((0.01,0.01,0.01),0.0,0.5,1,None,0),
 "plasticGlossy": ((0.008,0.008,0.008),0.0,0.12,1,None,0),
 "tire": ((0.035,0.035,0.035),0.0,0.85,1,None,0),
 "reflect": ((0.85,0.85,0.87),1.0,0.12,1,None,0),
 "led": ((1,1,1),0.0,0.3,1,(1.0,0.98,0.92),2.0),
 "leather": ((0.06,0.06,0.06),0.0,0.6,1,None,0),
 "interiorPlastic": ((0.05,0.05,0.05),0.0,0.6,1,None,0),
 "interiorB": ((0.07,0.07,0.07),0.0,0.7,1,None,0),
 "interiorA": ((0.45,0.44,0.42),0.0,0.8,1,None,0),
 "interiorTex": ((1,1,1),0.0,0.6,1,None,0),
 "grey": ((0.3,0.3,0.3),0.0,0.6,1,None,0),
 "glass_red_Illum": ((0.7,0.02,0.02),0.0,0.2,1,(1.0,0.02,0.01),1.2),
 "glass_red": ((0.45,0.01,0.01),0.0,0.08,0.85,(0.25,0.0,0.0),0.4),
 "glass_lens": ((0.85,0.88,0.92),0.0,0.05,0.3,None,0),
 "glass_led": ((0.9,0.9,0.92),0.0,0.05,0.22,None,0),
 "glass_clear": ((0.95,0.95,0.97),0.0,0.03,0.12,None,0),
 "glass_dark": ((0.03,0.035,0.04),0.0,0.04,0.6,None,0),
 "glass_darkB": ((0.01,0.012,0.014),0.0,0.04,0.82,None,0),
}
def rebuild(mat, base):
    p = P.get(base)
    if p is None: return
    nt = mat.node_tree
    imgs = [n for n in nt.nodes if n.type == 'TEX_IMAGE']
    bsdf = [n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED']
    links_img = {}
    if bsdf:
        for l in nt.links:
            if l.to_node == bsdf[0] and l.from_node.type == 'TEX_IMAGE': links_img[l.to_socket.name] = l.from_node.image
            if l.to_node.type == 'NORMAL_MAP' and l.from_node.type == 'TEX_IMAGE': links_img["__normal"] = l.from_node.image
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial'); b = nt.nodes.new('ShaderNodeBsdfPrincipled')
    nt.links.new(b.outputs[0], out.inputs[0])
    rgb, met, rough, alpha, em, ems = p
    b.inputs["Base Color"].default_value = (*rgb, 1); b.inputs["Metallic"].default_value = met
    b.inputs["Roughness"].default_value = rough; b.inputs["Alpha"].default_value = alpha
    if em: b.inputs["Emission"].default_value = (*em, 1); b.inputs["Emission Strength"].default_value = ems
    if "Base Color" in links_img:
        t = nt.nodes.new('ShaderNodeTexImage'); t.image = links_img["Base Color"]; nt.links.new(t.outputs[0], b.inputs["Base Color"])
    if "__normal" in links_img:
        t = nt.nodes.new('ShaderNodeTexImage'); t.image = links_img["__normal"]; t.image.colorspace_settings.name = 'Non-Color'
        nm = nt.nodes.new('ShaderNodeNormalMap'); nt.links.new(t.outputs[0], nm.inputs["Color"]); nt.links.new(nm.outputs[0], b.inputs["Normal"])
    mat.blend_method = 'BLEND' if alpha < 1 else 'OPAQUE'
    mat.use_backface_culling = False
    mat.name = {"carpaint": "pintura"}.get(base, base)
for m in list(bpy.data.materials):
    rebuild(m, m.name.split(".")[0])
info["materials"] = sorted(m.name for m in bpy.data.materials)
# ---- presupuesto de triángulos y diezmado
def cat(base):
    if base == "pintura": return "pintura"
    if base.startswith("glass") or base in ("led","reflect"): return "luces_cristal"
    if base in ("chrome","silver","alumimium"): return "cromo"
    if base in ("leather","interiorPlastic","interiorB","interiorA","interiorTex","grey"): return "interior"
    return "negro"
BUD0 = {"pintura": 19000, "luces_cristal": 10000, "cromo": 3500, "negro": 6500, "interior": 8000, "rueda": 3200, "pinza": 300}
BUD1 = {"pintura": 4800, "luces_cristal": 1900, "cromo": 600, "negro": 1300, "interior": 0, "rueda": 650, "pinza": 60}
def prepare(o):
    sel([o]); bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.remove_doubles(threshold=0.0004); bpy.ops.object.mode_set(mode='OBJECT')
    if o.data.has_custom_normals: bpy.ops.mesh.customdata_custom_splitnormals_clear()
for o in list(scn.objects):
    if o.type == 'MESH': prepare(o)
# separar cuerpo por material en objetos (ya lo está: un material por objeto) y sumar por categoría
def decimate_set(objs, budget_fn):
    groups = {}
    for o in objs:
        groups.setdefault(budget_fn(o)[0], []).append(o)
    for g, lst in groups.items():
        tot = sum(ntris(o) for o in lst); bud = budget_fn(lst[0])[1]
        for o in lst:
            if bud <= 0: bpy.data.objects.remove(o, do_unlink=True); continue
            ratio = min(1.0, bud / max(tot, 1))
            if ratio < 0.999:
                m = o.modifiers.new("dec", 'DECIMATE'); m.ratio = ratio; m.use_collapse_triangulate = True
                sel([o]); bpy.ops.object.modifier_apply(modifier="dec")
def finish(objs):
    for o in objs:
        o.data.use_auto_smooth = True; o.data.auto_smooth_angle = math.radians(40)
        for p in o.data.polygons: p.use_smooth = True

def quitar_piezas_pequenas(o, diag_min):
    me = o.data
    nv = len(me.vertices)
    if nv == 0: return
    co = np.empty(nv*3); me.vertices.foreach_get("co", co); co = co.reshape(-1,3)
    ne = len(me.edges); ev = np.empty(ne*2, dtype=np.int64); me.edges.foreach_get("vertices", ev); ev = ev.reshape(-1,2)
    par = np.arange(nv)
    def find(x):
        r = x
        while par[r] != r: r = par[r]
        while par[x] != r:
            nx = par[x]; par[x] = r; x = nx
        return r
    # unión vectorizada por pasadas (label propagation)
    lab = np.arange(nv)
    for _ in range(200):
        a = lab[ev[:,0]]; b = lab[ev[:,1]]; m = np.minimum(a, b)
        np.minimum.at(lab, ev[:,0], m); np.minimum.at(lab, ev[:,1], m)
        lab = lab[lab]
        if np.array_equal(lab[ev[:,0]], lab[ev[:,1]]): break
    uniq, inv = np.unique(lab, return_inverse=True)
    mn = np.full((len(uniq),3), 1e9); mx = np.full((len(uniq),3), -1e9)
    np.minimum.at(mn, inv, co); np.maximum.at(mx, inv, co)
    diag = np.linalg.norm(mx-mn, axis=1)
    small_v = diag[inv] < diag_min
    if not small_v.any(): return
    bm = bmesh.new(); bm.from_mesh(me); bm.verts.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[bm.verts[i] for i in np.nonzero(small_v)[0]], context='VERTS')
    bm.to_mesh(me); bm.free()


GRUPO_LOD1 = {"pintura": "pintura", "glass_dark": "cristal", "glass_darkB": "cristal", "glass_clear": "cristal", "glass_lens": "cristal",
    "glass_led": "faro", "led": "faro", "reflect": "faro", "glass_red": "piloto", "glass_red_Illum": "piloto",
    "chrome": "cromo", "silver": "cromo", "alumimium": "cromo"}
def mat_lod1(nombre):
    base = nombre.split(".")[0]
    g = GRUPO_LOD1.get(base, "negro")
    if g + "_lod1" in bpy.data.materials: return bpy.data.materials[g + "_lod1"]
    m = bpy.data.materials.new(g + "_lod1"); m.use_nodes = True
    nt = m.node_tree; b = [n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED'][0]
    cfg = {"pintura": ((0.55,0.56,0.58),0.6,0.3,1,None,0), "cristal": ((0.02,0.025,0.03),0.0,0.05,0.75,None,0),
           "faro": ((0.85,0.86,0.88),1.0,0.1,1,(1.0,0.98,0.92),0.6), "piloto": ((0.6,0.02,0.02),0.0,0.1,1,(0.9,0.02,0.01),0.8),
           "cromo": ((0.85,0.85,0.87),1.0,0.15,1,None,0), "negro": ((0.02,0.02,0.02),0.0,0.45,1,None,0),
           "neumatico": ((0.035,0.035,0.035),0.0,0.85,1,None,0), "llanta": ((0.6,0.61,0.63),1.0,0.3,1,None,0)}[g]
    rgb, met, rough, alpha, em, ems = cfg
    b.inputs["Base Color"].default_value = (*rgb, 1); b.inputs["Metallic"].default_value = met
    b.inputs["Roughness"].default_value = rough; b.inputs["Alpha"].default_value = alpha
    if em: b.inputs["Emission"].default_value = (*em, 1); b.inputs["Emission Strength"].default_value = ems
    m.blend_method = 'BLEND' if alpha < 1 else 'OPAQUE'
    if g == "pintura": m.name = "pintura_lod1"
    return m
def asignar_lod1(o, forzar=None):
    for slot in o.material_slots:
        if slot.material:
            nm = slot.material.name.split(".")[0]
            if forzar: 
                GRUPO_LOD1[nm] = GRUPO_LOD1.get(nm, forzar(nm))
            slot.material = mat_lod1(slot.material.name)

def alive(o):
    try:
        o.name; return True
    except ReferenceError:
        return False

def build(BUD, tag, out):
    names = [o.name for o in scn.objects if o.type == 'MESH']
    # copia de trabajo
    copies = []
    for n in names:
        src_o = bpy.data.objects[n]
        c = src_o.copy(); c.data = src_o.data.copy(); scn.collection.objects.link(c); c.name = n + "#" + tag; copies.append(c)
    body = [c for c in copies if not (c.name.startswith("rueda_") or c.name.startswith("pinza_"))]
    whl = [c for c in copies if c not in body]
    if tag == "lod1":
        GRUPO_LOD1.update({"tire": "neumatico", "rimDark": "llanta", "chrome_brushed_brakedisc": "llanta", "metal_dark": "negro", "metal_def": "llanta"})
        for w in whl:
            if w.name.startswith("pinza_"):
                bpy.data.objects.remove(w, do_unlink=True)
        whl = [w for w in whl if alive(w)]
        for w in whl:
            asignar_lod1(w)
            # un solo material por superficie repetida: unir ranuras iguales
            sel([w]); bpy.ops.object.material_slot_remove_unused()
        for o in body:
            asignar_lod1(o)
        for o in body:
            quitar_piezas_pequenas(o, 0.06)
            while o.data.uv_layers:
                o.data.uv_layers.remove(o.data.uv_layers[0])

        body = [o for o in body if len(o.data.polygons) > 0]
    decimate_set(body, lambda o: (cat(o.material_slots[0].material.name), BUD[cat(o.material_slots[0].material.name)]))
    for w in whl:
        kind = w.name.split("_")[0]; bud = BUD[kind]; t = ntris(w)
        if bud < t:
            m = w.modifiers.new("dec", 'DECIMATE'); m.ratio = bud / t; m.use_collapse_triangulate = True
            sel([w]); bpy.ops.object.modifier_apply(modifier="dec")
    body = [o for o in body if alive(o)]
    finish(body + whl)
    carro = join(body, "carroceria")
    if tag == "lod1":
        # unir ranuras de material repetidas (tras agrupar quedan ~6 materiales)
        mats_u = []
        for sl in carro.material_slots:
            if sl.material not in mats_u: mats_u.append(sl.material)
        remap = [mats_u.index(sl.material) for sl in carro.material_slots]
        idx = np.empty(len(carro.data.polygons), dtype=np.int32); carro.data.polygons.foreach_get("material_index", idx)
        idx = np.array(remap, dtype=np.int32)[idx]
        carro.data.materials.clear()
        for mm in mats_u: carro.data.materials.append(mm)
        carro.data.polygons.foreach_set("material_index", idx); carro.data.update()
    if tag == "lod1" and ntris(carro) > 9000:
        m = carro.modifiers.new("dec2", 'DECIMATE'); m.ratio = 8500 / ntris(carro); m.use_collapse_triangulate = True
        sel([carro]); bpy.ops.object.modifier_apply(modifier="dec2")
        carro.data.use_auto_smooth = True; carro.data.auto_smooth_angle = math.radians(40)
    res = {"carroceria": ntris(carro), "superficies": len(carro.material_slots)}
    exp = [carro]
    for w in whl:
        w.name = w.name.split("#")[0]; w.data.name = w.name; res[w.name] = ntris(w); exp.append(w)
    res["total"] = sum(ntris(o) for o in exp)
    sel(exp)
    bpy.ops.export_scene.gltf(filepath=out, export_format='GLB', use_selection=True, export_apply=True,
        export_texcoords=True, export_normals=True, export_materials='EXPORT', export_colors=False,
        export_image_format='JPEG' if tag == "lod1" else 'AUTO', export_yup=True)
    for o in exp: bpy.data.objects.remove(o, do_unlink=True)
    return res
info["tris_original"] = sum(ntris(o) for o in scn.objects if o.type == 'MESH')
info["lod0"] = build(BUD0, "lod0", out0)
info["lod1"] = build(BUD1, "lod1", out1)
json.dump(info, open(info_path, "w"), indent=1, default=float)
print("OK", json.dumps(info, default=float)[:3000])
