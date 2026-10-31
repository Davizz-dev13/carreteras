# Modelos 3D

## arteon_lod0.gltf (+ arteon_lod0_0.bin, arteon_lod0_1.bin) / arteon_lod1.glb

- Obra original: "Volkswagen Arteon" de MattDoesBlender — https://sketchfab.com/3d-models/volkswagen-arteon-be4640e14cd24a39860216944c133048
- Autor: MattDoesBlender (https://sketchfab.com/MattDoesBlender)
- Licencia: Creative Commons Atribución 4.0 (CC BY 4.0) — https://creativecommons.org/licenses/by/4.0/
- Es un Arteon R-Line de 2018, de antes del restyling de 2020.
- Cambios hechos para Carreteras de España (Blender 3.4, script `convertir_arteon.py` en esta carpeta):
  - orientado y escalado a 4,866 m de largo, con el origen en el centro de la batalla, a ras de suelo;
  - las 4 ruedas y las pinzas separadas, cada una con su centro en el eje;
  - piezas unidas por material y materiales PBR rehechos (la pintura se llama `pintura` y el juego la pinta del color elegido);
  - reducido de triángulos: 1.624.643 → 113.518 (LOD0, jugador; v3.1) y 28.620 (LOD1, tráfico: cada material reducido aparte y materiales agrupados en 6 + 2 por rueda);
  - LOD0 (v3.1): las normales se copian del modelo original (suavizado a 35°, modificador Data Transfer) sobre la malla reducida, para que la chapa no salga abollada; llantas en grafito oscuro como en el original;
  - el `.gltf` del LOD0 lleva la geometría partida en dos `.bin` de menos de 3 MB (GitHub) y las texturas aparte (`arteon_lod0_tire.png`, `arteon_lod0_interiorTex.png`).

Uso: `SOLO_LOD0=1 blender -b --factory-startup --python convertir_arteon.py -- scene.gltf arteon_lod0.glb lod1_no_usado.glb info.json 4.866 2.836` y después se pasa el `.glb` a `.gltf` con la geometría en `.bin` de < 3 MB
(el `.gltf` original se descarga de Sketchfab). El LOD1 final se hace a partir del LOD0 con `simplificar_lod1.py`:
`blender -b --python simplificar_lod1.py -- arteon_lod0.gltf (+ arteon_lod0_0.bin, arteon_lod0_1.bin) arteon_lod1.glb 0.36`.

### Texto de atribución original

Model Information:
* title:	Volkswagen Arteon
* source:	https://sketchfab.com/3d-models/volkswagen-arteon-be4640e14cd24a39860216944c133048
* author:	MattDoesBlender (https://sketchfab.com/MattDoesBlender)

Model License:
* license type:	CC-BY-4.0 (http://creativecommons.org/licenses/by/4.0/)
* requirements:	Author must be credited. Commercial use is allowed.

If you use this 3D model in your project be sure to copy paste this credit wherever you share it:
This work is based on "Volkswagen Arteon" (https://sketchfab.com/3d-models/volkswagen-arteon-be4640e14cd24a39860216944c133048) by MattDoesBlender (https://sketchfab.com/MattDoesBlender) licensed under CC-BY-4.0 (http://creativecommons.org/licenses/by/4.0/)
