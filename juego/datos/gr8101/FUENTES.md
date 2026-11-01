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

## Revisión de errores de mapeo (01-11-2026)
Revisado en el juego (capturas) y contra la ortofoto PNOA (0,1 m, WMS pnoa-ma del IGN) y el MDT05:
- Trazado: el eje del juego va sobre el asfalto de la foto en los 29,5 km (desvíos de ~1 m, dentro del error de OSM).
- Glorieta final (Caniles): la calzada de la GR-8101 y sus 3 líneas se dibujaban hasta el centro del anillo y lo
  partían. Ahora la ruta deja de dibujarse en el borde exterior de la glorieta (`dibujar` = 0 en los 2 últimos tramos
  de 2 m; el recorrido no cambia).
- Señales: OSM no tiene ninguna junto a la ruta. Se ponen 2 ceda el paso (R1) solo donde la marca vial pintada se ve
  en la ortofoto: entrada de la GR-8101 a la glorieta y boca de la Avenida Sierra de Caniles (km 27,3). En los otros
  cruces no se ve marca: no se pone nada.
- Quitamiedos: OSM no tiene ninguno en la zona; en la ortofoto hay líneas finas junto al borde en algunos tramos
  (km 1,5–2,9 izq., km 16,0–16,25 dcha.) que podrían ser biondas o el borde de la cuneta: sin foto a pie de carretera
  no se puede confirmar, así que no se dibuja ninguno (regla: solo donde existen de verdad).
- Puentes de las vías secundarias (5, enlace de la A-334 y caminos): tablero en recta entre las vías que llegan a sus
  estribos (pipeline/rasante_puentes.py), sin escalones; antes salía del MDT (hasta 1,5 m de escalón).
- Huecos de asfalto en los cruces oblicuos y en el enlace de la A-334: vienen del código común (scripts/cruces.gd),
  no de los datos de la zona; se arreglan allí para todas las zonas.
- Sin arreglar: el terreno es una malla de 20 m, así que las calles empinadas de Caniles y el tramo de las Trincheras
  (km 27,7–28,1, taludes casi verticales a los dos lados según la Diputación) no pueden tener el relieve fino real;
  las calles del pueblo quedan sobre un faldón de tierra. El tramo urbano de Caniles sigue a 90* (genérico): OSM no
  tiene límite y no hay foto de la señal.


## Árboles de Gráficos alto (solo escritorio)
- paisaje/arboles/: 143879 árboles donde ESA WorldCover 10 m 2021 v200 marca cubierta arbórea (49.3 % de la zona). © ESA WorldCover project / Contains modified Copernicus Sentinel data (2021), CC BY 4.0. Densidad APROXIMADA (35 % de los píxeles de 10 m con árboles a menos de 300 m de la ruta, 8 % más lejos; nunca a menos de 6 m de una calzada). Especie por altitud (aproximación). Generado con pipeline/arboles_worldcover.py. La web y Gráficos bajo siguen con arboles/ (bosques de OSM).
