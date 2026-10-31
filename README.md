# Carreteras de España · escala 1:1  (v2)

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

**Controles** (también salen en pantalla, H para la ayuda): W/↑ acelerar · S/↓ frenar y marcha atrás · A D / ← → girar ·
Espacio freno · P piloto automático · C crucero · + / − velocidad · K adaptar en curvas · 9 / 0 tráfico ·
V cámara · R volver a la carretera · Esc pausa.

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
- W/↑ acelerar · S/↓ frenar (parado: marcha atrás) · A D / ← → girar · Espacio freno
- P piloto automático · C control de crucero · + / − velocidad elegida · K adaptar velocidad en curvas
- 9 / 0 menos / más tráfico · V cámara (persecución / cabina) · R volver a la carretera · Esc pausa · H ayuda

**HUD**: velocidad (km/h), altitud (m), pendiente real (%) en tu sentido de marcha, carretera (M-601 / CL-601 y
su nombre), PK, km recorridos, km que faltan y minipefil con tu posición. Al llegar al km final: tiempo, velocidad
media y máxima, pendiente máxima, desnivel acumulado, derrapes y choques.

**Física**: la del coche elegido en el menú (masa, potencia, 0-100, velocidad máxima, batalla y vía reales, §7); la gravedad de la pendiente real frena o empuja; rozamiento de rodadura y
aerodinámico; límite de adherencia μ = 0,95 en asfalto (0,55 fuera). Si entras en una horquilla de 9 m de radio a
más de ~33 km/h, el coche se va de morro (es la física real: v = √(μ·g·R)).

**Piloto automático**: sigue el carril derecho (persecución pura), mantiene la velocidad elegida con la fuerza que
hace falta en cada pendiente y, si activas "adaptar en curvas", frena antes de cada curva según su radio real y hace
cola detrás del tráfico (IDM). Sin adaptar, si vas demasiado rápido verás el aviso y derraparás.

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
- Motor: [Godot Engine](https://godotengine.org) 4.7.2 (MIT).

## 9. Versión web y GitHub Pages

La web se publica sola: cada `push` a `main` lanza `.github/workflows/web.yml`, que descarga Godot 4.7.2 y sus
plantillas de exportación, exporta el preset *Web* (sin hilos, así funciona en GitHub Pages sin cabeceras COOP/COEP)
y lo publica en https://davizz-dev13.github.io/carreteras/. El progreso se ve en la pestaña *Actions* del repo.

Para actualizar el juego online: cambia lo que quieras, `git commit` y `git push`. En 3–4 minutos está publicado.
No hace falta subir la carpeta `build/` (está en `.gitignore`).
