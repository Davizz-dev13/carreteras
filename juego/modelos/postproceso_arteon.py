#!/usr/bin/env python3
"""Postproceso del LOD0 del Arteon (coche del jugador) para Carreteras. Se aplica al .gltf que sale de convertir_arteon.py.

  python3 postproceso_arteon.py arteon_lod0.gltf matricula_es.png      (necesita numpy, scipy, trimesh, embreex)

1. Volante: separa del nodo "carroceria" los triángulos del volante (aro, radios, centro, logo) y los pone en un nodo
   "volante" con el origen en el centro del aro y su Z local a lo largo de la columna de dirección (hacia el conductor),
   para que el juego lo gire con la dirección (catalogo.gd, animar_volante).
2. Oclusión ambiental por vértice (COLOR_0) en las piezas que no son chapa, cristal ni luces: rayos contra el propio coche
   (los cristales no tapan). El juego la usa en coche_ao.gdshader para que el interior no se ilumine con todo el cielo.
3. Retrovisor interior: su cristal va aparte (nodo "espejo_interior") con UV propias; el juego le pinta lo que ve una
   cámara hacia atrás (retrovisor.gd).
4. Matrículas españolas delante y detrás (520 x 110 mm) en sus huecos, con la textura matricula_es.png.
5. Parabrisas y ventanillas delanteras ("glass_dark") con tintado claro de fábrica en vez de ahumado.
Escribe arteon_lod0_2.bin (geometría nueva, < 3 MB) y reescribe el .gltf. Los .bin originales no cambian.
"""
import sys, json, copy, numpy as np
from scipy.spatial.transform import Rotation as Rot

# volante medido en el modelo (m, ejes del glTF: X derecha, Y arriba, -Z adelante)
VOL_CENTRO = np.array([-0.3821, 0.9366, -0.4584])
VOL_EJE = np.array([-0.0004, 0.3753, 0.9269])        # columna de dirección, hacia el conductor (22° sobre la horizontal)
VOL_RADIO, VOL_H0, VOL_H1 = 0.222, -0.10, 0.05        # cilindro que contiene el volante (radio, delante/detrás del aro)
MAT_AO = {'chrome','plasticblack','silver','reflect','plasticGlossy','alumimium','leather','interiorTex','interiorPlastic',
          'interiorB','interiorA','grey','black','metal_dark'}
ESPEJO_X, ESPEJO_Y0, ESPEJO_Z = 0.2, 1.15, (-0.8, -0.3)   # dónde buscar el cristal del retrovisor interior
MATRICULA_TRA = ([0.0, 0.4715, 2.49], [0, 0.162, 0.987])      # centro del hueco y normal hacia fuera
MATRICULA_DEL = ([0.0, 0.468, -2.318], [0, -0.036, -0.999])
CT = {5126: np.float32, 5123: np.uint16, 5125: np.uint32, 5121: np.uint8}
NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}


def main(ruta, png):
    base = ruta.rsplit('/', 1)[0] + '/' if '/' in ruta else ''
    g = json.load(open(ruta))
    if any(n.get('name') == 'volante' for n in g['nodes']):
        print('ya postprocesado'); return
    bufs = [open(base + b['uri'], 'rb').read() for b in g['buffers']]

    def acc(i):
        a = g['accessors'][i]; bv = g['bufferViews'][a['bufferView']]; dt = CT[a['componentType']]; n = NC[a['type']]
        off = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
        x = np.frombuffer(bufs[bv['buffer']], dtype=dt, count=a['count'] * n, offset=off)
        return x.reshape(a['count'], n) if n > 1 else x
    car = next(n for n in g['nodes'] if n['name'] == 'carroceria')
    mesh = g['meshes'][car['mesh']]
    prims = {}
    for pi, p in enumerate(mesh['primitives']):
        prims[pi] = (g['materials'][p['material']]['name'], acc(p['attributes']['POSITION']).astype(np.float64),
                     acc(p['indices']).astype(np.int64).reshape(-1, 3), acc(p['attributes']['NORMAL']).astype(np.float64))
    # --- orientación de los triángulos: el modelo reducido trae triángulos con el orden de vértices al revés que su
    # normal (un 3,5 % de la chapa, un 20 % del plástico negro). Con materiales de dos caras el motor los toma por caras
    # traseras y les da la vuelta a la normal: manchas oscuras en la chapa. Se reordenan para que casen con la normal. ---
    def enderezar(pos, tri, nrm):
        gn = np.cross(pos[tri[:, 1]] - pos[tri[:, 0]], pos[tri[:, 2]] - pos[tri[:, 0]])
        mal = (gn * nrm[tri].sum(1)).sum(1) < 0
        t = tri.copy(); t[mal] = t[mal][:, [0, 2, 1]]
        return t, int(mal.sum())
    girados = 0
    for pi, (mn, pos, tri, nrm) in list(prims.items()):
        t, k = enderezar(pos, tri, nrm); girados += k
        prims[pi] = (mn, pos, t, nrm)
    # --- oclusión ---
    import trimesh
    from trimesh.ray.ray_pyembree import RayMeshIntersector
    V, F, o = [], [], 0
    for mn, pos, tri, _ in prims.values():
        if not mn.startswith('glass'):
            V.append(pos); F.append(tri + o); o += len(pos)
    inter = RayMeshIntersector(trimesh.Trimesh(np.vstack(V), np.vstack(F), process=False))
    rng = np.random.default_rng(1); NR = 64
    u1, u2 = rng.random(NR), rng.random(NR); r = np.sqrt(u1); th = 2 * np.pi * u2
    loc = np.c_[r * np.cos(th), r * np.sin(th), np.sqrt(1 - u1)]
    ao = {}
    for pi, (mn, pos, tri, nrm) in prims.items():
        if mn not in MAT_AO: continue
        n = nrm / np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
        a = np.where(np.abs(n[:, 0:1]) < 0.9, np.array([[1, 0, 0]]), np.array([[0, 1, 0]]))
        t = np.cross(n, a); t /= np.linalg.norm(t, axis=1, keepdims=True); b = np.cross(n, t)
        res = None
        for lado in (1, -1):        # caras de dos lados: vale el lado más abierto
            hits = np.zeros(len(pos)); cerca = np.zeros(len(pos)); org = pos + n * lado * 0.003
            for k in range(NR):
                d = loc[k, 0] * t + loc[k, 1] * b + loc[k, 2] * n * lado
                l, ir, _ = inter.intersects_location(org, d, multiple_hits=False)
                if len(ir):
                    dist = np.linalg.norm(l - org[ir], axis=1)
                    np.add.at(hits, ir[dist < 2.5], 1)
                    np.add.at(cerca, ir, np.clip(1 - dist / 0.45, 0, 1))
            val = np.clip(0.3 + 0.7 * (1 - hits / NR), 0, 1) * (1 - 0.6 * cerca / NR)
            res = val if res is None else np.maximum(res, val)
        ao[pi] = res
    # --- geometría nueva ---
    N = VOL_EJE / np.linalg.norm(VOL_EJE); e1 = np.cross([0, 1, 0], N); e1 /= np.linalg.norm(e1); e2 = np.cross(N, e1)
    R = np.c_[e1, e2, N]
    blob = bytearray(); bi = len(g['buffers'])

    def add(arr, ctype, typ, target, minmax=False):
        nonlocal blob
        while len(blob) % 4: blob += b'\0'
        data = np.ascontiguousarray(arr).tobytes(); g['bufferViews'].append({'buffer': bi, 'byteOffset': len(blob), 'byteLength': len(data), 'target': target}); blob += data
        a = {'bufferView': len(g['bufferViews']) - 1, 'componentType': ctype, 'count': int(len(arr)), 'type': typ}
        if minmax: a['min'] = [float(x) for x in arr.min(0)]; a['max'] = [float(x) for x in arr.max(0)]
        g['accessors'].append(a); return len(g['accessors']) - 1
    for pi, (mn, pos, tri, nrm) in prims.items():
        mesh['primitives'][pi]['indices'] = add(tri.astype(np.uint16).ravel(), 5123, 'SCALAR', 34963)
    for mi_, m_ in enumerate(list(g['meshes'])):
        if mi_ == car['mesh']: continue
        for p in m_['primitives']:
            t, k = enderezar(acc(p['attributes']['POSITION']).astype(np.float64), acc(p['indices']).astype(np.int64).reshape(-1, 3),
                             acc(p['attributes']['NORMAL']).astype(np.float64))
            if k:
                girados += k
                p['indices'] = add(t.astype(np.uint32).ravel(), 5125, 'SCALAR', 34963)
    print('triángulos reordenados:', girados)
    for pi, v in ao.items():
        mesh['primitives'][pi]['attributes']['COLOR_0'] = add(np.repeat(v[:, None], 3, 1).astype(np.float32), 5126, 'VEC3', 34962)
    vprims = []
    for pi, (mn, pos, tri, nrm) in prims.items():
        dd = pos - VOL_CENTRO; h = dd @ N; rr = np.linalg.norm(dd - np.outer(h, N), axis=1)
        ok = (h > VOL_H0) & (h < VOL_H1) & (rr < VOL_RADIO); tm = ok[tri].all(1)
        if not tm.any(): continue
        p = mesh['primitives'][pi]
        p['indices'] = add(tri[~tm].astype(np.uint16).ravel(), 5123, 'SCALAR', 34963)
        w = tri[tm]; used = np.unique(w); remap = -np.ones(len(pos), np.int64); remap[used] = np.arange(len(used))
        at = {'POSITION': add(((pos[used] - VOL_CENTRO) @ R).astype(np.float32), 5126, 'VEC3', 34962, True),
              'NORMAL': add((nrm[used] @ R).astype(np.float32), 5126, 'VEC3', 34962),
              'TEXCOORD_0': add(acc(p['attributes']['TEXCOORD_0'])[used].astype(np.float32), 5126, 'VEC2', 34962)}
        if pi in ao: at['COLOR_0'] = add(np.repeat(ao[pi][used][:, None], 3, 1).astype(np.float32), 5126, 'VEC3', 34962)
        vprims.append({'attributes': at, 'indices': add(remap[w].astype(np.uint16).ravel(), 5123, 'SCALAR', 34963), 'material': p['material']})
    g['meshes'].append({'name': 'volante', 'primitives': vprims})
    q = Rot.from_matrix(R).as_quat()
    g['nodes'].append({'name': 'volante', 'mesh': len(g['meshes']) - 1, 'translation': [float(x) for x in VOL_CENTRO], 'rotation': [float(x) for x in q]})
    g['scenes'][0]['nodes'].append(len(g['nodes']) - 1)
    # --- retrovisor interior: el cristal (10 triángulos de "reflect") va aparte, con UV planas del propio espejo (u al revés,
    # como un espejo) para que el juego le ponga la imagen de una cámara que mira hacia atrás (retrovisor.gd) ---
    pi_r = next(pi for pi, v in prims.items() if v[0] == 'reflect')
    mn, pos, tri, nrm = prims[pi_r]
    p = mesh['primitives'][pi_r]
    cen = pos[tri].mean(1); fn = nrm[tri].mean(1)
    tm = (np.abs(cen[:, 0]) < ESPEJO_X) & (cen[:, 1] > ESPEJO_Y0) & (cen[:, 2] > ESPEJO_Z[0]) & (cen[:, 2] < ESPEJO_Z[1]) & (fn[:, 2] > 0.8)
    p['indices'] = add(tri[~tm].astype(np.uint16).ravel(), 5123, 'SCALAR', 34963)
    w = tri[tm]; used = np.unique(w); remap = -np.ones(len(pos), np.int64); remap[used] = np.arange(len(used))
    q = pos[used]; x0, x1, y0, y1 = q[:, 0].min(), q[:, 0].max(), q[:, 1].min(), q[:, 1].max()
    uv = np.c_[(x1 - q[:, 0]) / (x1 - x0), (y1 - q[:, 1]) / (y1 - y0)].astype(np.float32)
    g['materials'].append({'name': 'espejo_interior', 'pbrMetallicRoughness': {'baseColorFactor': [0.1, 0.1, 0.1, 1], 'metallicFactor': 1.0, 'roughnessFactor': 0.1}})
    g['meshes'].append({'name': 'espejo_interior', 'primitives': [{'attributes': {
        'POSITION': add(q.astype(np.float32), 5126, 'VEC3', 34962, True), 'NORMAL': add(nrm[used].astype(np.float32), 5126, 'VEC3', 34962),
        'TEXCOORD_0': add(uv, 5126, 'VEC2', 34962)}, 'indices': add(remap[w].astype(np.uint16).ravel(), 5123, 'SCALAR', 34963),
        'material': len(g['materials']) - 1}]})
    g['nodes'].append({'name': 'espejo_interior', 'mesh': len(g['meshes']) - 1})
    g['scenes'][0]['nodes'].append(len(g['nodes']) - 1)
    hw, hh = 0.26, 0.055
    qp = np.array([[-hw, -hh, 0], [hw, -hh, 0], [hw, hh, 0], [-hw, hh, 0]], np.float32)
    g.setdefault('images', []).append({'name': 'matricula_es', 'uri': png})
    g.setdefault('samplers', []).append({'magFilter': 9729, 'minFilter': 9987})
    g.setdefault('textures', []).append({'source': len(g['images']) - 1, 'sampler': len(g['samplers']) - 1})
    g['materials'].append({'name': 'matricula', 'pbrMetallicRoughness': {'baseColorTexture': {'index': len(g['textures']) - 1}, 'metallicFactor': 0.0, 'roughnessFactor': 0.45}})
    g['meshes'].append({'name': 'matricula', 'primitives': [{'attributes': {
        'POSITION': add(qp, 5126, 'VEC3', 34962, True), 'NORMAL': add(np.tile([0, 0, 1], (4, 1)).astype(np.float32), 5126, 'VEC3', 34962),
        'TEXCOORD_0': add(np.array([[0, 1], [1, 1], [1, 0], [0, 0]], np.float32), 5126, 'VEC2', 34962)},
        'indices': add(np.array([0, 1, 2, 0, 2, 3], np.uint16), 5123, 'SCALAR', 34963), 'material': len(g['materials']) - 1}]})
    for nombre, (c, nn) in (('matricula_tra', MATRICULA_TRA), ('matricula_del', MATRICULA_DEL)):
        nn = np.array(nn, float); nn /= np.linalg.norm(nn)
        rq = Rot.align_vectors([nn, [0, 1, 0]], [[0, 0, 1], [0, 1, 0]], weights=[1e6, 1])[0].as_quat()
        g['nodes'].append({'name': nombre, 'mesh': len(g['meshes']) - 1, 'translation': [float(x) for x in np.array(c) + nn * 0.015], 'rotation': [float(x) for x in rq]})
        g['scenes'][0]['nodes'].append(len(g['nodes']) - 1)
    for m in g['materials']:
        if m['name'] == 'glass_dark': m['pbrMetallicRoughness']['baseColorFactor'] = [0.03, 0.04, 0.04, 0.28]
    nombre_bin = ruta.rsplit('/', 1)[-1].replace('.gltf', '_2.bin')
    g['buffers'].append({'uri': nombre_bin, 'byteLength': len(blob)})
    open(base + nombre_bin, 'wb').write(blob)
    json.dump(g, open(ruta, 'w'), separators=(',', ':'))
    print('volante:', len(vprims), 'superficies;', len(blob), 'bytes nuevos')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'matricula_es.png')
