# Zona m406 · M-406 Alcorcón (A-5) → Leganés → A-4 (Comunidad de Madrid)

Generada con el pipeline de siempre, leyendo OSM de un extracto Geofabrik en vez de Overpass:

    osmium extract -b -3.84,40.28,-3.66,40.38 madrid-latest.osm.pbf -o m406_bbox.osm.pbf     # recorte al bbox (osmium-tool)
    python pipeline/osm_pbf.py --pbf m406_bbox.osm.pbf --bbox 40.28,-3.84,40.38,-3.66 --zona m406 --tipos-residential --parques
    MPLBACKEND=Agg python pipeline/extraer.py --zona m406        # trazado, terreno, árboles (preset "m406")
    python pipeline/extras_zona.py --zona m406 --ref M-406 --sentido 'Alcorcón (A-5) → A-4' \
        --osm cache/osm/m406_todas_highway.json --residencial cache/osm/m406_residencial_senales.json \
        --ancho_min 7 --lineas lineas_vacias.json     # lineas_vacias.json = {"0": [], "1": []} (ver 'Adelantamiento')

## La carretera
- M-406 entera tal como está en OSM: 206 vías ref=M-406 (178 trunk, 28 trunk_link), del enlace con la A-5 en
  Alcorcón (oeste) a la rotonda del enlace con la A-4 (este). Autovía urbana de calzadas separadas (oneway=yes),
  2 carriles por calzada (3 en incorporaciones), con rotondas.
- Extracto OSM: Geofabrik europe/spain/madrid, estado 2026-10-30T21:24:51Z (ODbL).

## Modelo de la carretera en el juego (simplificación, documentada)
- La ruta sigue UNA calzada, la de sentido Alcorcón → A-4, en su sentido legal (pipeline/dirigido.py: Dijkstra que
  respeta oneway y el giro de las rotondas). Por esa línea circulan los dos sentidos: donde OSM tiene calzadas
  separadas la anchura es la suma de los carriles de las dos calzadas (OSM lanes) × 3,5 m + 1 m, con 2 carriles por
  sentido (3 donde OSM los tiene) y la línea central continua (mediana: no hay carril contrario que invadir).
- Adelantar en los tramos de 2+ carriles por sentido = cambiar al carril izquierdo del propio sentido, sin mirar
  coches de frente (mecanismo del carril adicional de la A-308). 88,9 % de la ruta 0 y 68,3 % de la ruta 1, en cada sentido.
- Rotondas: 7 en total (3 + 4). La ruta las recorre por su arco real de OSM (sigue de frente por la M-406, no sale). En el anillo
  OSM tiene lanes=2 sin calzadas separadas, así que ahí el juego pone 1+1 carriles (calzada más estrecha).
- Hueco de OSM → dos rutas: en el casco urbano de Leganés OSM no tiene ninguna vía con ref=M-406 en ~1,7 km (entre
  el final de la calzada que viene de Alcorcón y la rotonda de inicio del Paseo de John Lennon). El camino legal más
  corto por las calles de OSM sería por calles de sentido único con giros de 90° (Calle Concepción, Calle Arboleda…),
  no comprobado como itinerario oficial; en la primera versión el tráfico del juego no podía con esos giros (cientos de
  golpes con coches de frente). Así que NO se inventa la unión: la zona tiene dos rutas, exactamente los dos tramos
  continuos que OSM tiene con ref=M-406:
    · ruta 0 "M-406 Alcorcón (A-5) → Leganés": 10,59 km, 3 rotondas
    · ruta 1 "M-406 Leganés → A-4": 3,16 km, 4 rotondas
  (además se quitan 153 m del principio que eran el anillo de la rotonda del enlace con la A-5, sin la ref).

## Fuentes (todo real salvo lo marcado)
- Trazado: OSM (arriba). 13,75 km de ruta en total (10,59 + 3,16). Eje del juego a 0,52 / 0,25 m (mediana) del eje
  OSM de la calzada seguida. Puentes según bridge=yes de OSM, 0 túneles.
- Relieve: IGN MDT05 (LiDAR PNOA, malla 5 m, WCS servicios.idee.es). Terreno a 20 m, 56 teselas de 2 km; rasante
  muestreada del MDT05 cada 2 m. Altitud: ruta 0 640–694 m, ruta 1 605–616 m.
- Vías dibujadas: solo carreteras reales (motorway…unclassified y _link; sin residential, path, track, footway…), y
  solo las que pasan a ≤ 2 km de la ruta: 1.931 vías. Las residential (miles de calles en esta zona urbana) no se
  dibujan. Las vías secundarias van sin nombre de calle.
- Árboles: solo dentro de bosques y parques de OSM (landuse=forest, natural=wood, leisure=park): 10,8 % de la zona,
  19.626 árboles. No se añaden por altitud.
- Límites de velocidad: maxspeed de OSM por sentido (en calzadas separadas, la calzada contraria da el de 'vuelta').
  Cobertura OSM (ida / vuelta): ruta 0 83,7 % / 82,1 %; ruta 1 83,2 % / 26,7 %. El resto es el
  genérico legal, fuente="por_defecto_legal" → el juego lo pinta tenue y con *: 50 dentro de un polígono
  landuse=residential de OSM, 90 fuera (genérico de carretera convencional; la M-406 no es autovía en OSM).
- Carriles: OSM lanes / lanes:forward / lanes:backward de cada calzada.
- Adelantamiento: no hay etiquetas overtaking reales en la M-406. 'prohibido' = calzadas separadas (sin carril
  contrario). 'linea_discontinua' vacía en las dos rutas: la línea central es continua (mediana en calzadas separadas,
  y en los anillos de las rotondas, que son de sentido único en la realidad). Se adelanta solo cambiando de carril
  dentro del propio sentido. 'ancho_ajustado' en carreteras.json: fuera de calzadas separadas (anillos) anchura mínima
  7 m (genérico, no medido) porque el juego hace circular por ahí los dos sentidos.

## Corrección del pipeline
Preset con "orden" ("oeste_este"), así que se aplica la corrección del desfase de un tramo de las propiedades por vía
(cada muestra toma la vía del tramo que llega a ella).

Datos © colaboradores de OpenStreetMap (ODbL) · MDT05 © IGN/CNIG (CC BY 4.0).
