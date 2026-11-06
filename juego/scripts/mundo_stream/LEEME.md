# Mundo por teselas (prototipo, fase 1: Puerto de Navacerrada)

Como BeamNG.Earth, pero en nuestro juego: el suelo se descarga y se monta por teselas alrededor del coche, con nivel de
detalle según la distancia hasta el horizonte. Se activa con `--mundo=stream` o con la casilla del menú
"Mundo real por teselas (beta)" (solo .exe y, por ahora, solo Navacerrada). Sin la casilla todo funciona como antes.

## Fuentes (probadas con curl el 6-nov-2026)
| Qué | URL | Formato | Resolución | Licencia |
|---|---|---|---|---|
| Ortofoto PNOA (IGN/CNIG) | `https://www.ign.es/wmts/pnoa-ma` (WMTS, TileMatrixSet `EPSG:25830`, capa `OI.OrthoimageCoverage`) | JPEG 256 px, ~15-20 KB, caché GeoWebCache (HIT), 0,3-0,5 s, `Access-Control-Allow-Origin: *` | nivel 18 = 0,30 m/px (las hojas usan esto) | CC BY 4.0 (scne.es) |
| Relieve | `https://tiles.mapterhorn.com/{z}/{x}/{y}.webp` | Terrarium WebP 512 px (h = R·256 + G + B/256 − 32768), CDN, ACAO `*` | z17 en el puerto (0,45 m/px); usamos z15 (1,8 m/px) de cerca | datos abiertos (en España coincide con el MDT05 del IGN, LiDAR PNOA, a ±0,4 m: mediana 0,41 m, p90 0,86 m en 529 puntos; supuesto: es el LiDAR del IGN remuestreado) |
| Alternativa probada, no usada | `https://servicios.idee.es/wcs-inspire/mdt` (WCS 2.0.1, `Elevacion25830_5`, SUBSET + SCALESIZE) | GeoTIFF sin comprimir, ACAO `*`, 0,7-0,9 s | 5 m | CC BY 4.0. Devuelve enteros de 16 bits (escalones de 1 m): por eso se usa Mapterhorn |
| WMS PNOA | `https://www.ign.es/wms-inspire/pnoa-ma` | JPEG a medida | — | 0,8-1 s por 256 m y 21 s por 16 km (se renderiza al vuelo): descartado |

## Archivos
- `geo.gd` — UTM 30N ↔ geográficas ↔ píxel Web Mercator; rejilla EPSG:25830 del WMTS (tabla de orígenes por nivel).
- `fuentes.gd` — cola de descargas con prioridad (10 a la vez), reintentos, caché en `user://mundo_cache/` con tope
  (`--cache_mb`, 600 MB por defecto; borra lo más antiguo).
- `corredor.gd` — pasillo de nuestras carreteras (rutas, vías, anillos y triángulos de glorietas; sin túneles ni
  puentes) para graduar el terreno: 12 cm bajo la rasante, banda plana junto al borde y talud 2:3 hasta el terreno.
- `terreno_stream.gd` + `terreno_stream.gdshader` — el árbol de teselas (niveles 9-17: 39 km → 153 m), selección por
  distancia (K = 1,1 × lado), sin agujeros (el padre se dibuja hasta que sus 4 hijos están listos), faldones contra
  grietas, montaje en hilos, subida a la GPU limitada por fotograma, DXT1 en escritorio, liberación de lo que deja de
  hacer falta (4 s) y tope de 600 nodos. Shader: foto con tono corregido, grano de cerca, berma de grava junto a la
  calzada, tierra/roca en laderas empinadas, curvatura de la Tierra desde 3 km.
- Cambios mínimos en `ajustes.gd` (altura del terreno descargado para el coche fuera del asfalto y los árboles),
  `mundo.gd`, `paisaje.gd`, `mapa_streaming.gd` (sin su terreno en este modo; árboles cuando hay alturas exactas),
  `juego.gd` (espera inicial con aviso), `menu.gd` (casilla y créditos).
- Prueba: `pruebas/earth_vistas.tscn` (`--modo=hoja|aereas|recorrido`).

## Pendiente / supuestos
- No probado en Windows real ni con Forward+ (las fotos son de OpenGL por software).
- La compresión DXT1 en tiempo de ejecución funciona en este binario de Linux; no comprobado en la plantilla de
  exportación de Windows. Si no está, se queda sin comprimir (≈ 4× más VRAM por textura).
- Carreteras, quitamiedos, señales y árboles siguen saliendo de los datos de la zona.

## Estado al cerrar la fase 1 (2026-11-06)
- Horizonte: raíces del quadtree hasta 80 km; la mitad inferior del cielo procedural se pinta del color de la bruma
  (con la curvatura, el terreno lejano baja del horizonte y antes asomaba una franja gris).
- Métricas (Xvfb + llvmpipe, NO representativo de una GTX 1650 Ti): vídeo 137–144 MB (texturas DXT1 98–102 MB,
  búferes 39–42 MB), 0 nodos huérfanos, ~310–330 nodos (~240 dibujados), montaje 19–24 ms de media por nodo en hilos,
  subida a GPU ≤ 2,3 ms por fotograma. Carga inicial: ~90 s con caché fría, 15–19 s con caché caliente.
- Pendiente: laderas muy empinadas cerca (foto estirada, falta textura triplanar de roca/tierra), árboles del sistema
  viejo (algunos pegados al arcén, duplican los de la foto), carreteras lejanas claras (LOD del asfalto),
  señalización vertical por norma (ver PLAN_FASE2.md), web.
