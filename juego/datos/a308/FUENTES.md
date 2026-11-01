# Zona a308 · A-308 Iznalloz → Darro (Granada)

Generada con el mismo pipeline que Navacerrada:

    python pipeline/extraer.py --zona a308          # trazado, terreno, árboles (preset "a308")
    python pipeline/extras_zona.py --zona a308 --ref A-308 \
        --osm cache/osm/a308_todas_highway.json --residencial cache/osm/a308_residencial_senales.json

## Fuentes (todo real salvo lo marcado)
- Trazado: OpenStreetMap, vías con ref=A-308 (83 vías, Overpass, 31-10-2026). Encadenado continuo, sin huecos:
  0 uniones fuera de OSM. Distancia mediana del eje del juego al eje OSM: 0,5 m.
- Vías dibujadas: solo carreteras reales (motorway/trunk/primary/secondary/tertiary/unclassified/residential y _link),
  sin path/track/footway (en el bbox hay 1.255 track y 568 path que NO se dibujan) ni vías sin asfaltar.
- Relieve: IGN MDT05 (LiDAR PNOA, malla 5 m, WCS servicios.idee.es). En el juego, terreno a 20 m (media 5→20 m);
  la rasante de la carretera se muestrea del MDT05 cada 2 m. Teselas de 2 km (40 KB cada una).
- Árboles: solo dentro de los bosques de OSM (landuse=forest y natural=wood: 17,1 % de la zona), no por altitud.
- Límites de velocidad: maxspeed de OSM por sentido. Cobertura OSM: 12.7 % de la longitud (igual en los dos
  sentidos). El resto es el genérico legal (90 fuera de poblado, 50 en poblado según landuse=residential de OSM),
  marcado fuente="por_defecto_legal" → el juego lo pinta tenue y con *.
- Carriles: lanes, lanes:forward/backward de OSM. Un carril adicional real (2+1) de 2,16 km, km 6,55–8,71, sentido
  Darro (vías 674899523, 893649202, 895511340), en la subida más dura (5,9 % de media en 1 km). Sentido Iznalloz: ninguno.
- Adelantamiento: en OSM no hay ni una etiqueta overtaking en la zona. 'prohibido' sale de (1) calzadas separadas en OSM
  (cruces con isletas: real) y (2) SUPUESTO: en el sentido de 1 carril frente al 2+1 se supone línea continua.
- Calzadas separadas (11 tramos en cruces, 4,0 km): la ruta sigue una calzada; se ensancha a 8 m para que circulen los dos sentidos.

## Corrección del pipeline usada aquí
encadenar() guarda en cada punto la vía del tramo que sale de él y procesar() espera la del que llega (lo que pasa al
invertir la ruta). Sin invertir, las propiedades iban corridas un tramo: el puente de 292 m de Iznalloz se marcaba en el
tramo anterior y salía una "pendiente" falsa del 28 %. Corregido solo para presets con "orden" (Navacerrada no se ha
regenerado; sus rutas invertidas ya estaban bien, las no invertidas tienen el mismo desfase).

## Revisión de errores de mapeo (01-11-2026)
- Cruces y empalmes: los huecos en el asfalto (379 de 396 empalmes rectos con > 3 m de hueco, triángulos en los
  cruces oblicuos) venían del código común (scripts/cruces.gd) y se arreglan allí para todas las zonas.
- Puentes y túneles de las vías secundarias (23): el tablero salía del MDT y bajaba al fondo del barranco (hasta 5 m)
  con escalones de 1-2 m en los estribos; ahora es la recta entre las vías que llegan a cada extremo
  (pipeline/rasante_puentes.py). No cambia nada en planta.
- Señales STOP / ceda (10 de 38): estaban encima del asfalto de la vía principal o del ramal de al lado (OSM pone el
  nodo en el propio cruce). Se retrasan por su vía hasta quedar ≥ 0,5 m fuera de cualquier calzada
  (pipeline/senales_fuera_calzada.py).
- Quitamiedos: OSM no tiene ninguno etiquetado junto a la A-308 y no hay foto a pie de carretera para confirmarlos:
  no se dibuja ninguno (regla: solo donde existen de verdad).
