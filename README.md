# Carreteras de España · escala 1:1  (v4)

**Novedades v2**: sin vibración (ver §6) y coches reales elegibles con su ficha técnica (§7). De momento, todos VW Arteon.

Juego de conducción por **carreteras reales** con su **trazado real** (curvas de OpenStreetMap) y su **altitud real**
(Modelo Digital del Terreno de 5 m del IGN, LiDAR). Nada de escalas: 1 unidad de Godot = 1 metro, la altitud del
juego es la altitud sobre el nivel del mar y las coordenadas son ETRS89 / UTM 30N (EPSG:25830).

Demo incluida: **Puerto de Navacerrada**: M-601 desde Navacerrada hasta el puerto y bajada por la CL-601 hacia
Valsaín (24,3 km), más las carreteras de alrededor (M-607, M-614, M-622, M-966, SG-615…).

## ▶ Jugar online

**[https://davizz-dev13.github.io/carreteras/](https://davizz-dev13.github.io/carreteras/)** — se juega en el navegador, sin instalar nada (Chrome, Edge o Firefox de escritorio
con WebGL 2; la primera carga baja unos 48 MB). Es la misma versión que el proyecto de Godot, exportada a web.

Cómo ejecutarlo en local:
- **Con Godot (recomendado, va más fluido)**: instala Godot 4.7 estándar, importa `juego/project.godot` y pulsa F5 (detalles en §3).
- **La versión web en tu PC**: exporta con el preset *Web* (`juego/export_presets.cfg`, sale en `build/web/`) y sírvela
  con un servidor local, por ejemplo `python -m http.server 8000 --directory build/web` y abre `http://localhost:8000`
  (abrir el `index.html` con doble clic no funciona: el navegador bloquea la carga del `.wasm` desde disco).

**Controles** (también salen en pantalla, H para la ayuda): W/↑ acelerar · S/↓ frenar y marcha atrás · ← → girar
(también A D) · P piloto automático · O adelantar · L límite al adelantar · + / − velocidad · K adaptar en curvas · 9 / 0 tráfico ·
V cámara · R volver a la carretera · Esc pausa. Pulsa el perfil de altitud o el mapa de abajo para ir a ese punto.

## 1. Estructura

```
pipeline/            Extracción en Python
  extraer.py         CLI: bbox -> datos del juego (OSM + MDT -> UTM 30N 1:1)
  osm.py             Overpass API (bbox) y lector de .osm.pbf (Geofabrik) para toda España
  dem.py             MDT05 del IGN (WCS) o Copernicus GLO-30 (AWS), muestreo bilineal
  rutas.py           Encadenar vías por ref, remuestreo cada 2 m, altitud suavizada, pendiente, curvatura
  graficos.py        Perfil de altitud y mapa de comprobación (PNG)
juego/               Proyecto Godot 4 (GDScript, renderer Compatibility)
  escenas/           menu.tscn (inicio) y juego.tscn (conducción)
  scripts/
    ajustes.gd       Autoload: opciones del menú + carga de datos + altura del terreno
    catalogo.gd      Autoload: coches reales (datos/coches/coches.json) y creación de sus modelos 3D
    ficha.gd         Ficha técnica de una versión + parámetros físicos derivados de ella (explicados)
    modelo_procedural.gd  Modelo 3D low-poly a partir de un perfil de secciones, a medidas reales
    ruta.gd          Una carretera: puntos, pendiente, curvatura, proyección de la posición sobre la ruta
    superficie.gd    Rejilla espacial con todas las calzadas: altura exacta del asfalto bajo cada rueda
    mundo.gd         Terreno, cinta de carretera con marcas viales, pinos, cielo y niebla
    coche.gd         Física del coche (potencia, frenos, aerodinámica, rodadura, gravedad, adherencia)
    trafico.gd       Tráfico en ambos sentidos con modelo IDM y velocidad de curva
    perfil.gd        Dibujo del perfil de altitud (menú y HUD)
    menu.gd          Menú: carretera, tramo, velocidad, piloto automático, tráfico
    juego.gd         Bucle de juego, piloto automático, cámaras, HUD, pausa, resumen final
  datos/coches/coches.json  Coches reales: versiones, cifras de fábrica con su fuente, colores, perfil 3D
  datos/navacerrada/ Datos ya procesados (zona.json, carreteras.json, terreno/*.bin, arboles/*.bin, estadisticas.json)
graficos/            perfil y mapa de la demo
requirements.txt
```

## 2. Generar los datos de cualquier zona (pipeline)

```bash
python -m venv venv
venv\Scripts\activate            # Windows   (Linux/Mac: source venv/bin/activate)
pip install -r requirements.txt

# la demo (ya viene hecha, tarda ~1 min la primera vez)
python pipeline/extraer.py --zona navacerrada

# cualquier zona: --bbox sur,oeste,norte,este en grados  +  qué carreteras encadenar como rutas
python pipeline/extraer.py --zona morcuera --bbox 40.80,-3.88,40.88,-3.78 --rutas "M-611"
python pipeline/extraer.py --zona cotos --bbox 40.78,-4.03,40.84,-3.93 --rutas "M-601+CL-601" "M-604"
# sin --rutas: crea una ruta por cada referencia de carretera (M-…, CL-…, N-…) de más de 2 km
# --mdt copernicus: usa Copernicus GLO-30 en vez del IGN (fuera de España o si el IGN no responde)

python pipeline/graficos.py --zona morcuera     # perfil + mapa en graficos/
```

Luego, en el menú del juego, cambia `zona` en `scripts/ajustes.gd` (`ZONA_POR_DEFECTO`) por la nueva carpeta.

Qué hace, paso a paso:
1. **Trazado**: Overpass API descarga las vías `highway=motorway…unclassified` del bbox (con `ref`, `name`, `lanes`,
   `width`, `maxspeed`, `bridge`, `tunnel`). Las vías con la misma `ref` se unen en un grafo; los cortes de
   mapeo (rotondas sin ref) se puentean (< 80 m) y la ruta es el camino más largo del grafo.
2. **Planta**: remuestreo cada 2 m y suavizado gaussiano de 3 m (quita los picos de la poligonal de OSM sin cambiar
   las curvas: la horquilla más cerrada sale de 9 m de radio).
3. **Altitud**: MDT05 del IGN (LiDAR, terreno desnudo, sin árboles) por su WCS público, muestreo bilineal. Para quitar
   el ruido (±1 m y escalones de 1 m) sin tocar las pendientes reales: mediana de 25 m + gaussiana σ = 12 m.
   **Puentes y túneles** (tags OSM) no siguen el terreno: rasante interpolada entre sus extremos.
4. **Anchura**: `width` si existe; si no `lanes` × 3–3,5 m según tipo de vía + arcén.
5. **Terreno**: malla de 20 m en teselas de 2 × 2 km; junto a la carretera el terreno se ajusta a la rasante
   (desmonte/terraplén) para que el asfalto no quede enterrado ni flotando.
6. **Salida**: JSON + binarios float32 en metros locales: `X = E − E0`, `Z = N0 − N`, `Y = altitud`.

### Comprobación con datos publicados (demo)
| | Nuestro pipeline | Publicado |
|---|---|---|
| Altitud del puerto | 1.856 m | 1.858 m (cota oficial del puerto) |
| Navacerrada → puerto (desde la cota 1.280 m) | 7,77 km, +576 m, 7,4 % media | 7,8 km, +575 m, 7,3 % media (altimetrías de ciclismo) |
| Pendiente máxima | 10,7 % (media en 100 m) · 9,2 % (en 1 km) | máx. 10,1 % (myCols) |

Estadísticas completas por ruta en `juego/datos/navacerrada/estadisticas.json`.

## 3. Abrir y jugar en Godot

1. Descarga Godot 4 (4.4 o posterior; probado con 4.7.2 estable) desde godotengine.org — la versión estándar, no la .NET.
2. *Importar* → elige `juego/project.godot` → *Importar y editar*. La primera vez tarda unos segundos.
3. F5 para jugar.
4. Para exportar un .exe: *Proyecto → Exportar → Windows* y en *Recursos → Filtros para exportar archivos que no son recursos* pon `*.json, *.bin` (los datos van como archivos sueltos).

Usa el renderer **Compatibility** (OpenGL 3.3): va fluido en una GTX 1650 Ti y en gráficas integradas.

**Menú**: eliges carretera, tramo (km inicio → km fin, con su perfil real, longitud, desnivel y pendiente máxima;
si km fin < km inicio la recorres en sentido contrario, p. ej. bajando el puerto), velocidad, piloto automático,
adaptar en curvas, tráfico 0–100 %, cámara y **coche** (versión real del Arteon y color de VW, con su ficha).

**Mandos**:
- W/↑ acelerar · S/↓ frenar (parado: marcha atrás) · ← → girar (A D también funcionan, y Espacio frena, aunque
  ya no salen en la ayuda de pantalla)
- P piloto automático · O adelantar (con el piloto puesto) · L respetar límite al adelantar · + / − velocidad elegida · K adaptar velocidad en curvas
- 9 / 0 menos / más tráfico · V cámara (persecución / cabina) · R volver a la carretera · Esc pausa · H ayuda

**HUD**: velocidad (km/h), altitud (m), pendiente real (%) en tu sentido de marcha, carretera (M-601 / CL-601 y
su nombre), PK, km recorridos, km que faltan y, abajo, el perfil de altitud (mitad izquierda) y el mapa de la ruta
visto desde arriba con el norte arriba (mitad derecha: salida en verde, llegada en rojo, lo recorrido en naranja y tu
coche como flecha). Al pasar el ratón por encima se ve "km 7,4 · 1.512 m"; al pulsar, el coche aparece parado en ese
km, en su carril, y se quitan los coches que hubiera a menos de 50 m. Al llegar al km final: tiempo, velocidad
media y máxima, pendiente máxima, desnivel acumulado, derrapes y choques.

**Física**: la del coche elegido en el menú (masa, potencia, 0-100, velocidad máxima, batalla y vía reales, §7); la gravedad de la pendiente real frena o empuja; rozamiento de rodadura y
aerodinámico; límite de adherencia μ = 0,95 en asfalto (0,55 fuera). Si entras en una horquilla de 9 m de radio a
más de ~33 km/h, el coche se va de morro (es la física real: v = √(μ·g·R)).

**Piloto automático**: sigue el carril derecho (persecución pura), mantiene la velocidad elegida con la fuerza que
hace falta en cada pendiente y, si activas "adaptar en curvas", frena antes de cada curva según su radio real y hace
cola detrás del tráfico (IDM). Sin adaptar, si vas demasiado rápido derraparás.

**Tráfico**: coches en los dos sentidos, cada uno en su carril, con el *Intelligent Driver Model* (Treiber, 2000)
y velocidad máxima de curva; un 12 % son vehículos lentos y se forman colas detrás. Solo existen a ±1,3 km del
jugador (máx. 44) para que el portátil vaya ligero.

## 4. Siguiente paso: toda España

- **Datos**: descargar `spain-latest.osm.pbf` de Geofabrik (~1,3 GB), recortar por teselas con
  `osmium extract -b oeste,sur,este,norte` y usar `osm.ways_desde_pbf()` (mismo formato que Overpass). El MDT05 del
  IGN también se puede descargar por hojas MTN50 en el Centro de Descargas del CNIG (más rápido que el WCS a lo
  grande). Canarias está en UTM 28N (EPSG:4083/32628): el pipeline tendría que cambiar el CRS por zona.
- **Teselas en streaming**: generar teselas fijas de 2 km para todo el país (≈ 130.000) con carretera + terreno
  + árboles; en Godot cargar solo las 3×3 o 5×5 alrededor del coche con `ResourceLoader.load_threaded_request` y
  liberar las lejanas.
- **Origen flotante**: con UTM, las coordenadas llegan a 1.000 km; hay que mover el origen del mundo cada pocos km
  (o compilar Godot con doble precisión) para que no tiemble nada.
- **LOD del terreno**: 20 m cerca, 80–200 m lejos (o un clipmap); impostores para los árboles.
- **Carreteras**: intersecciones y rotondas como mallas propias, autovías con dos calzadas (ahora el tráfico
  supone un carril por sentido), túneles con su boca, guardarraíles, señales verticales (OSM `traffic_sign`),
  límites de velocidad por tramo en el HUD.
- **Coche**: neumáticos con modelo de Pacejka, cambio de marchas, sonido de motor.

## 5. Limitaciones conocidas (v1)

- Solo la zona de la demo está procesada; las demás se generan con el pipeline.
- Tráfico solo en la ruta elegida y con un carril por sentido (en tramos de doble calzada no es realista).
- Las intersecciones se solapan (dos cintas de asfalto) y no hay túneles visibles (la zona no tiene).
- El terreno es de 20 m: los taludes junto a la carretera son aproximados.
- El coche sigue la superficie (no salta en cambios de rasante) y los choques son simples.

Datos: © colaboradores de OpenStreetMap (ODbL). MDT05 © Instituto Geográfico Nacional (CC BY 4.0, scne.es).
Copernicus DEM © DLR/Airbus, ESA (opcional).


## 6. La vibración de la v1: causa y arreglo

**Causa**: para apoyar el coche se mide la altura del asfalto bajo las 4 ruedas. La carretera está guardada como
tramos rectos de 2 m, y para cada rueda se cogía, de entre todos los tramos cercanos (hasta ~5 m), **el que tenía la
altura más parecida a la del propio coche**, no el que estaba realmente debajo. En una pendiente del 6 % eso daba
alturas que saltaban entre tramos vecinos: cada pocos fotogramas una rueda "caía" 15 cm, y el coche pegaba un salto
de 4–7 cm, de 3° de cabeceo y de 5° de balanceo durante un fotograma. Eso era la vibración.

**Arreglo** (`superficie.gd`, `coche.gd`, `ruta.gd`, `juego.gd`, `project.godot`):
1. Cada rueda usa la calzada **más cercana en planta**; la altura solo sirve para distinguir un puente de la carretera de debajo (> 2,5 m).
2. La carrocería sigue la inclinación del asfalto con un **muelle con amortiguación crítica** (≈1,4 Hz, como una suspensión), y se inclina un poco al frenar y en las curvas.
3. **Interpolación de la física** activada: la física va a 60 Hz y Godot interpola cada fotograma (va suave a 30, 60 o 144 Hz).
4. **Cámaras**: la de persecución sigue al coche con muelles críticos (posición y punto de mira por separado, horizonte siempre recto);
   la de cabina va fija al coche en rumbo pero filtra cabeceo y balanceo.
5. La ruta se interpola con curvas de Hermite (posición y tangente continuas): el tráfico ya no da tirones cada 2 m.

**Medido** en el mismo tramo y vídeo (CL-601, km 13,75 → 20, 30 fps; variación de un fotograma al siguiente, RMS):

| | v1 | v2 |
|---|---|---|
| Altura del coche | 3,6 cm | 0,11 cm |
| Cabeceo del coche | 2,85° | 0,005° |
| Balanceo del coche | 6,8° | 0,003° |
| Altura de la cámara | 0,42 cm | 0,04 cm |
| Cabeceo de la cámara | 0,10° | 0,001° |

Y en el propio vídeo (posición del coche en pantalla, 640 px de ancho): saltos de más de 2 px entre fotogramas
en 105 de 480 fotogramas en la v1 y en 2 de 480 en la v2; tirón medio de 2,5 px a 0,4 px.

(«variación» = segunda diferencia por fotograma: lo que cambia el movimiento de un fotograma al siguiente, es decir, los tirones.)

## 7. Coches reales

Elige en el menú la versión y el color. Todo el tráfico es del mismo modelo, en colores reales de Volkswagen.
Versiones del **VW Arteon**: las del lavado de cara (2020–2024) vendidas en España, más el TSI 280 4Motion (pre-restyling 2017–2018, España) y el TDI 200 4Motion (lavado de cara, otros mercados europeos):

| Versión | CV / kW | Par | Masa* | Tracción | Cambio | 0-100 | Vel. máx. | Fuente |
|---|---|---|---|---|---|---|---|---|
| Arteon 2.0 TDI 150 CV DSG | 150 / 110 | 360 Nm | 1650 kg | delantera | DSG 7 | 9,5 s | 220 km/h | km77 |
| Arteon 2.0 TDI 200 CV DSG | 200 / 147 | 400 Nm | 1639 kg | delantera | DSG 7 | 7,9 s | 237 km/h | km77 |
| Arteon 2.0 TDI 200 CV 4Motion DSG | 200 / 147 | 400 Nm | 1724 kg | 4Motion | DSG 7 | 7,4 s | 234 km/h | auto-data |
| Arteon 2.0 TSI 190 CV DSG | 190 / 140 | 320 Nm | 1608 kg | delantera | DSG 7 | 7,7 s | 237 km/h | km77 |
| Arteon 2.0 TSI 280 CV 4Motion DSG (pre-restyling) | 280 / 206 | 350 Nm | 1716 kg | 4Motion | DSG 7 | 5,6 s | 250 km/h | km77 |
| Arteon R 2.0 TSI 320 CV 4Motion DSG | 320 / 235 | 420 Nm | 1778 kg | 4Motion | DSG 7 | 4,9 s | 250 km/h | km77 |

\* Masa en orden de marcha con conductor (75 kg). Medidas: 4.866 × 1.871 × 1.457 mm, batalla 2.836 mm (R: 1.460 mm de alto, 2.838 de batalla).

**Fuentes** (cada cifra lleva su URL en `datos/coches/coches.json`): fichas técnicas de **km77.com** de cada versión
española; el TDI 200 4Motion, de **auto-data.net** (en España no se vendió con 4Motion; su masa es la de auto-data,
1.649 kg en vacío, + 75 kg de conductor, para compararla igual que las de km77); Cx 0,265 de **auto-data.net**
(km77 da 0,27); la gama española, según la **lista de precios de VW España MY22**. Los colores son nombres y códigos oficiales de VW; el tono RGB es aproximado.

**De la ficha a la física** (`ficha.gd`), sin inventar cifras:
- Cx · área: Cx publicado × área frontal. El área no está publicada, así que se estima como 0,84 × ancho × alto ≈ 2,29 m².
- Potencia en rueda: se ajusta el rendimiento de la transmisión para que la velocidad máxima oficial salga sola
  (sale entre 0,76 y 0,85). Si la velocidad está limitada (TSI 280 y R, 250 km/h), se usa 0,85.
- Fuerza de tracción máxima: se calibra para que el **0-100 simulado en llano dé el oficial** (el menú enseña los dos),
  sin pasar de la adherencia de las ruedas motrices (60 % del peso en tracción delantera, 100 % en 4Motion).
- Frenada máxima ≈ 1 g; rodadura 0,011 (valor típico de neumático, no viene en la ficha).

**Modelo 3D**: hecho para este juego de forma procedural, low-poly, a las **medidas reales** del Arteon
(largo, ancho, alto, batalla y vía): silueta fastback, capó largo, barra LED delantera de lado a lado, pilotos
traseros. Las proporciones de la silueta están puestas a ojo sobre fotos, no son planos de fábrica. Es todo código
del proyecto (sin licencias de terceros) y una sola malla compartida por todos los coches iguales, ligera para la 1650 Ti.
No se ha usado ningún modelo descargado.

**Añadir otro coche**: añade un objeto a `"modelos"` en `datos/coches/coches.json` con sus `"versiones"`
(potencia_cv, potencia_kw, par_nm, masa_kg, medidas en mm, traccion, cambio, vel_max_kmh, aceleracion_0_100_s, cx y `"fuentes"`).
Para el 3D, o bien un `"perfil"` procedural como el del Arteon, o bien
`"modelo_3d": {"tipo": "gltf", "ruta": "res://modelos/mi_coche.glb"}` (se escala solo a su largo real; pon la licencia
y la atribución aquí). Aparece solo en el menú.


## 8. Fuentes de datos y licencias

- **Trazado de las carreteras**: © colaboradores de [OpenStreetMap](https://www.openstreetmap.org/copyright),
  licencia ODbL. Se descarga con la Overpass API (`pipeline/osm.py`).
- **Altitud**: Modelo Digital del Terreno **MDT05** (paso de 5 m, obtenido por LiDAR) del
  [Instituto Geográfico Nacional](https://centrodedescargas.cnig.es/) — © Instituto Geográfico Nacional, CC BY 4.0
  ([scne.es](https://www.scne.es/)). Alternativa fuera de España: Copernicus GLO-30 (© DLR/Airbus, ESA).
- **Fichas de los coches**: [km77.com](https://www.km77.com/) para las versiones vendidas en España y
  [auto-data.net](https://www.auto-data.net/) cuando km77 no las tiene. Dos avisos:
  - el **Arteon 2.0 TDI 200 CV 4Motion** no se vendió en España: sus datos son de otros mercados europeos (auto-data.net);
  - el **Arteon 2.0 TSI 280 CV 4Motion** es el anterior al lavado de cara (2017–2018).
  Cada cifra lleva su URL en `juego/datos/coches/coches.json` (§7).
- **Fuente de texto de respaldo** para las flechas en la versión web: DejaVu Sans (`juego/fuentes/`, licencia libre de DejaVu/Bitstream Vera).
- **Modelo 3D del Arteon**: "Volkswagen Arteon" de [MattDoesBlender](https://sketchfab.com/MattDoesBlender),
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), <https://sketchfab.com/3d-models/volkswagen-arteon-be4640e14cd24a39860216944c133048>.
  Modificado: reducido de triángulos, escalado a medidas reales, ruedas separadas y materiales rehechos (`juego/modelos/LEEME.md`).
- Motor: [Godot Engine](https://godotengine.org) 4.7.2 (MIT).

## 9. Versión web y GitHub Pages

La web se publica sola: cada `push` a `main` lanza `.github/workflows/web.yml`, que descarga Godot 4.7.2 y sus
plantillas de exportación, exporta el preset *Web* (sin hilos, así funciona en GitHub Pages sin cabeceras COOP/COEP)
y lo publica en https://davizz-dev13.github.io/carreteras/. El progreso se ve en la pestaña *Actions* del repo.

Para actualizar el juego online: cambia lo que quieras, `git commit` y `git push`. En 3–4 minutos está publicado.
No hace falta subir la carpeta `build/` (está en `.gitignore`).

## 10. Novedades de la v3

**Arteon con modelo 3D real.** El coche del jugador es un modelo 3D real del Volkswagen Arteon:
*"Volkswagen Arteon"* de **MattDoesBlender**, licencia **CC BY 4.0**
(<https://sketchfab.com/3d-models/volkswagen-arteon-be4640e14cd24a39860216944c133048>). Es un Arteon R-Line de
2018 (antes del restyling de 2020: faros y paragolpes algo distintos del actual). El original tiene 1,62 millones de
triángulos; se ha convertido a `.glb` con Blender (script en `modelos/LEEME.md`):
- `modelos/arteon_lod0.gltf (+ arteon_lod0_0.bin, arteon_lod0_1.bin)` (jugador): ~75.800 triángulos, 4,7 MB, una textura de 2048 px como máximo.
- `modelos/arteon_lod1.glb` (tráfico): 28.620 triángulos, 1,7 MB. Sale del LOD0 reduciendo cada material por
  separado (interior al 20 %, el resto al 36 %) y agrupando los materiales en 6 + 2 por rueda, para que cada coche
  de tráfico cueste pocas llamadas de dibujo.
- Escalado a 4,866 m de largo; batalla 2,837 m (real 2,836); vías 1,576 m (reales 1,587 / 1,577); alto 1,444 m (real
  1,457). Cada rueda es una pieza aparte con su centro en el eje: giran según la velocidad y las delanteras giran con
  la dirección (las pinzas de freno giran con la dirección pero no ruedan).
- La pintura usa el color elegido en el menú con aspecto metalizado y barniz (clearcoat).
- El tráfico usa el LOD1 y deja de dibujarse a más de 600 m; sus ruedas no proyectan sombra.
- Sombras: 2 cascadas (los primeros 30 m con mucha resolución, hasta 100 m) y filtro suave, también en WebGL2.

**Choques reales** (`scripts/colisiones.gd`): cada coche es una caja con sus medidas reales y su masa de la ficha.
Cuando dos cajas se tocan se aplica un impulso que conserva el momento (coeficiente de restitución 0,15, rozamiento
entre chapas 0,35), con sub-pasos para que no se atraviesen a velocidad alta. Los coches de tráfico golpeados se
sueltan de su carril, derrapan, giran y se paran por rozamiento. Se han quitado los avisos rojos de la pantalla.

**Adelantar con O** (con el piloto puesto; v3.1, más agresivo): pulsas O con un coche más lento delante (hasta
90 m) y espera hueco. Sale solo si, con la aceleración real de tu versión (motor, aire, pendiente y lo que dejan ir
las curvas), en toda la distancia del adelantamiento:
- no hay curvas de radio menor de 150 m (`ADEL_RADIO_MIN` en `scripts/juego.gd`; 0 = sin esta regla),
- no es un tramo con prohibición de adelantar en OSM (`datos/navacerrada/adelantar.json`; hoy OSM no tiene ninguna
  etiqueta `overtaking` en esta zona, así que está vacío),
- hay visibilidad (curvas y cambios de rasante del trazado real) con el criterio del punto de compromiso: desde la
  salida se ve lo justo para abortar, y desde que se pone a la altura del coche, lo que le queda más lo que haría
  un coche de frente al límite de la vía,
- no viene ningún coche de frente que llegue antes de terminar (+15 m de margen),
- no cruza la línea continua pintada y hay hueco para volver delante del grupo (pasa hasta 12 coches pegados).
Va al menos 15 km/h más rápido que el adelantado, cambia de carril en 1,6 s y vuelve 8 m por delante. Durante el
adelantamiento recalcula cada 0,2 s lo que le queda; si un coche de frente llegaría antes, aborta (detrás del primero,
o metiéndose en el hueco de la fila).
**La línea central es derivada**, no son las marcas reales (OSM no las tiene): discontinua donde el juego deja
adelantar en algún sentido y continua donde no (`linea_discontinua` en `adelantar.json`, `--captura=lineas_adelantar`).
**Respetar límite al adelantar** (menú o tecla L, apagado por defecto): si está activo no pasa del límite del tramo
y, si así no le da, no adelanta. `--preset=antes` repite el comportamiento de la v3 para comparar.

**Dirección con teclado**: el volante se mueve de forma progresiva (unos 0,35 s hasta el tope y 0,25 s para volver
al centro). El ángulo máximo depende de la velocidad: es el que pide, como mucho, el 85 % del agarre (todo el volante a
20 km/h, pocos grados a 100 km/h). Así, mantener ← o → no hace derrapar ni frena el coche. El piloto automático no
cambia.

**Cámara de cabina** (V): ojos del conductor en el asiento izquierdo, con el salpicadero y el volante del modelo.

**Fallo del km 2,8** (`scripts/cruces.gd`): el terreno (malla de 20 m) tapaba el asfalto en el pueblo y 9 caminos de
OpenStreetMap se montaban sobre la carretera. Ahora:
- los cruces se cortan en el borde de la carretera y empalman a su altura,
- el terreno se baja bajo cada carretera para que quede al menos 25 cm por debajo del asfalto,
- el asfalto tiene un talud de tierra a los lados.
Revisado en los 40 cruces de la ruta 0.

**Mapa por trozos (streaming)** (`scripts/mapa_streaming.gd`): solo existe en memoria el mapa alrededor del coche.
- Carreteras: ~2 km por delante y 0,5 km por detrás.
- Terreno fino y árboles: ~2,2 km por delante y 0,8 km por detrás.
- Lo que queda atrás se libera. Lo de delante se construye poco a poco, como mucho 3 ms por fotograma y sin hilos,
  así que funciona igual en la web.
- Un terreno de 100 m de malla, siempre cargado, mantiene las montañas en el horizonte.
- Al saltar (R, o pulsar el perfil o el mapa) se reconstruye la zona de golpe.

Medido recorriendo la ruta 0 entera con un 30 % de tráfico:

| | Antes | Ahora |
|---|---|---|
| Carga de la escena | 2,6 s | 0,8 s |
| Memoria de vídeo | 103 MB | 63 MB |
| Nodos | 1.568 | ~650 |
| Primitivas por fotograma | 1,38 M | 0,82 M |

**Límites de velocidad**: señal redonda junto al velocímetro con el límite del tramo y del sentido en que vas
(`datos/navacerrada/limites_velocidad.json`, sacado de `maxspeed` de OpenStreetMap). Si OSM no tiene el dato, se
usa el límite genérico de ese tipo de vía y la señal sale más tenue y con `*`. Si superas el límite en más de
5 km/h, la velocidad se pone en rojo. Si falta el fichero, no sale la señal.

**Pruebas automáticas** (sin ventana, `--headless`):
```
godot --headless res://escenas/juego.tscn -- --captura=choque_alcance --ruta=0 --km_ini=19.6 --km_fin=24 --trafico=0
godot --headless res://escenas/juego.tscn -- --captura=choque_frontal --ruta=0 --km_ini=19.6 --km_fin=24 --trafico=0
godot --headless res://escenas/juego.tscn -- --captura=adelantar --ruta=0 --km_ini=19.45 --km_fin=24 --trafico=30 --vel=90 --v_lento=45 --pulsar=3 --duracion=60
godot --headless res://escenas/juego.tscn -- --captura=prueba --auto_o=1 --ruta=0 --km_ini=0 --km_fin=24.3 --trafico=30 --vel=90 --presim=4000   (--preset=antes = v3)
godot --headless res://escenas/juego.tscn -- --captura=mapa_adelantar --ruta=0 --radios=350,250,200,150,100,0
godot --headless res://escenas/juego.tscn -- --captura=lineas_adelantar --coche=arteon_tdi150_dsg --salida_json=/tmp/l.json
godot --headless res://escenas/juego.tscn -- --captura=giro --ruta=0 --km_ini=19.6 --km_fin=24 --trafico=0   (--lado=1 para la derecha)
godot --headless res://escenas/juego.tscn -- --captura=perfil --ruta=0 --km_ini=0 --km_fin=24.3 --trafico=40
godot res://escenas/juego.tscn -- --captura=video --cuadros=999999 --medir_fps=300 --ruta=0 --km_ini=13.75 --km_fin=20 --trafico=60
```
Resultados en esta versión:
- **Alcance** (90 contra 40 km/h): el momento se conserva (error 0,0000 %) y no se atraviesan.
- **Frontal** (30 + 30 km/h): no se atraviesan; los dos quedan a ~5 km/h.
- **Adelantamiento (v3.1)**, ruta de Navacerrada entera con piloto a 90 y O pulsada siempre que hay un lento delante
  (`--captura=prueba --auto_o=1`, TDI 150): 0 choques en los 6 recorridos (20/30/50 % de tráfico, los dos sentidos);
  3 adelantamientos en total (la v3 hizo 5, pero con 58 golpes: volvía al carril encima del coche de delante de la
  fila). En este puerto casi siempre lo impiden las curvas y la visibilidad; `--captura=mapa_adelantar` da el % de
  ruta donde se puede salir sin tráfico: 8 % con radio mínimo 150 m (v3: 0,8 %).
- **Giro a 80 km/h con ← mantenido 5 s** (acelerador fijo): antes perdía 46,5 km/h; ahora 3 km/h respecto a ir recto
  (en esa bajada, recto gana 3,6 km/h).
- **Pulsar el perfil** al 25 / 50 / 90 %: el coche aparece en el km pedido (6,08 / 12,15 / 21,87) y en su carril.
  Pulsar el punto del km 12 en el mapa lo lleva al km 12,00.
- **Ruta 0 entera con el piloto** (km 0 → 24,3, 30 % de tráfico): llega al final con 0 choques y 0 derrapes.
- **Rendimiento** (mismo punto, km 13,75, 60 % de tráfico, 44 coches):
  - v2: 343 llamadas de dibujo y 0,88 M primitivas;
  - v3: 646 llamadas de dibujo y 1,01 M primitivas.
  En esta máquina de pruebas no hay tarjeta gráfica y todo se dibuja por software, así que los FPS medidos aquí
  (2,0 → 1,65) no dicen cómo irá en una GTX 1650 Ti. Lo que cuenta son las llamadas de dibujo y las primitivas.

## 11. Novedades de la v4

- **Cambio DSG de 7** con los desarrollos reales de cada versión (`datos/coches/cambios_consumo.json`): marcha y rpm
  junto al velocímetro, reducción en cuestas y al adelantar, retención en las bajadas. El 0-100 y la punta siguen
  siendo los oficiales (`godot --headless res://pruebas/prueba_v4.tscn`).
- **Consumo**: dos cifras grandes junto al velocímetro: `inst.` (instantáneo, l/100 km; "—" con la inyección cortada)
  y `global` (media desde que empieza el recorrido). Debajo, en pequeño, los litros gastados y la cifra WLTP en gris
  solo como referencia. El modelo está calibrado para que un ciclo mixto dé la media real de Spritmonitor de cada
  versión; lo que marca en un puerto concreto es lo que da el modelo, no una medición. Supuestos en
  `datos/coches/motor_supuestos.json`.
- **Física**: dirección con inercia y peso real (modelo de bicicleta dinámico). El piloto respeta las señales de
  límite salvo al adelantar.
- **Zonas**: Puerto de Navacerrada y **A-308 Iznalloz–Darro** (Granada, 36,5 km, carril de adelantamiento real de
  2,2 km en sentido Darro, km 6,5–8,7). Se elige en el menú (Zona) o con `--zona=a308`. Fuentes en
  `juego/datos/a308/FUENTES.md`.
- **Coche del jugador**: modelo rehecho desde el original (113k triángulos, sin abolladuras en la chapa) y
  antialiasing MSAA 4x.
