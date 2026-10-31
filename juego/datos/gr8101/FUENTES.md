# Zona gr8101 · GR-8101 límite de Almería → Caniles (Sierra de Baza, Granada)

Generada con el mismo pipeline que a308:

    python pipeline/extraer.py --zona gr8101          # trazado, terreno, árboles (preset "gr8101")
    python pipeline/extras_zona.py --zona gr8101 --ref GR-8101 --sentido 'límite de Almería → Caniles' \
        --osm cache/osm/gr8101_todas_highway.json --residencial cache/osm/gr8101_residencial_senales.json

## La carretera (comprobada)
- GR-8101, Red Provincial de Carreteras de la Diputación de Granada. Catálogo de la Junta de Andalucía
  ("Actualización de la Red de Carreteras de Andalucía", provincia de Granada): "GR-8101. De Límite de Provincia de
  Almería a A-334 (Caniles). 28,90 km". Noticia de la Diputación (dipgra.es, "carretera de las Trincheras de Caniles"):
  origen en el límite Granada–Almería. En Almería continúa como AL-5405 hacia Escúllar (no incluida).
- OSM usa la misma ref: 15 vías ref=GR-8101 (tertiary, asfalto, lanes=2, oneway=no), nombre
  "Carretera de Límite de Provincia de Almería a Caniles" y, en Caniles, "Calle Antigua Carretera".
- Sentido 'ida' (km creciente) = el del PK oficial: del límite de Almería (km 0) a Caniles.

## Fuentes (todo real salvo lo marcado)
- Trazado: OpenStreetMap, vías ref=GR-8101 (Overpass, overpass-api.de, 31-10-2026 16:18 UTC). Encadenado continuo,
  sin huecos: 0 uniones fuera de OSM. 29,48 km (oficial 28,90 km: +2 %). En OSM la ref termina en una rotonda de
  Caniles a ~160 m de la A-334; ese último enlace no lleva ref y no se incluye. Eje del juego a 0,5 m (mediana) del eje OSM.
- Vías dibujadas: solo carreteras reales (motorway…tertiary, unclassified, residential y _link), sin path/track/footway
  ni sin asfaltar: en el bbox hay 975 track y 253 path que NO se dibujan.
- Relieve: IGN MDT05 (LiDAR PNOA, malla 5 m, WCS servicios.idee.es). Terreno del juego a 20 m (media 5→20 m);
  rasante de la carretera muestreada del MDT05 cada 2 m. 72 teselas de 2 km (40 KB cada una).
- Árboles: solo dentro de los bosques de OSM (landuse=forest / natural=wood): solo 13 polígonos, 1,8 % de la zona.
  OSM tiene la sierra muy poco mapeada como bosque, así que hay pocos árboles (4.403); no se añaden por altitud.
- Límites de velocidad: en OSM ninguna vía GR-8101 tiene maxspeed (cobertura 0 % en los dos sentidos) y no hay
  señales mapeadas. Todo es el genérico legal de 90 km/h (carretera convencional), fuente="por_defecto_legal" → el juego
  lo pinta tenue y con *. El tramo urbano de Caniles (Calle Antigua Carretera, último ~0,8 km) no cae dentro de
  ningún landuse=residential de OSM, así que también sale 90* (en la realidad seguramente es 50).
- Carriles: lanes=2 (1 por sentido) en las 15 vías. Ningún carril adicional / de adelantamiento. Sin calzadas separadas.
- Adelantamiento: 0 etiquetas overtaking en las 1.728 vías highway del bbox. adelantar.json no tiene tramos
  'prohibido' reales; decide el criterio del juego (visibilidad, curvas, coches de frente). 'linea_discontinua' (si está)
  es DERIVADA del criterio del juego (--captura=lineas_adelantar), no las marcas reales.
- Ancho: OSM no tiene width; 6,5 m es el valor por defecto del pipeline para tertiary de 2 carriles (genérico).
- Superficie: surface=asphalt en las 15 vías (OSM).

## Corrección del pipeline
Preset con "orden" ("sur_norte"), así que se aplica la corrección del desfase de un tramo de las propiedades por vía
(la misma de a308). Navacerrada no se ha regenerado.

## Pruebas (copia /tmp/carr_gr8101 = árbol real 16:14 UTC + a308.diff + gr8101.diff)
- Importación sin ventana: 0 errores.
- Piloto automático con O automática, 30 % de tráfico, ruta entera, TDI150 DSG, línea derivada activa:
  sentido límite→Caniles (bajada): 3.108 s, media 34 km/h, 0 choques, 0 adelantamientos (0 abortados);
  sentido Caniles→límite (subida): 2.659 s, media 40 km/h, 0 choques, 0 adelantamientos (0 abortados).
  Va casi todo el rato detrás de coches lentos: el juego no encuentra hueco (motivos: línea continua derivada,
  curva cerrada, sin visibilidad, el coche no da para pasar).
- Criterio de adelantamiento del juego sin tráfico: línea discontinua en el 32,8 % de la ruta (sobre todo km 20–29,
  la parte baja hacia Caniles). Derivado, no son marcas reales.
