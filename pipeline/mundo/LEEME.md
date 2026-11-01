# Mapa abierto (Comunidad de Madrid) — pipeline

Genera `juego/datos/madrid/` (teselas de 2 km en paquetes de 8 km). En orden:

1. `m1_red.py` — red interurbana de OSM (autopistas/autovías y enlaces siempre; primary/secondary/tertiary con `ref`; glorietas sin `ref` que unen la red) → red.pkl
2. `m2_mdt.py` — descarga IGN MDT05 / MDT25 (WCS) a cache_mdt
3. `m3_mundo.py` — rasante de cada tramo (cada 5 m; gálibo de 6 m en los cruces a distinto nivel), terreno por tesela (con terraplén bajo cada calzada) (10 m con carretera / 25 m sin ella), horizonte (200 m) → red.json.gz, red_N.bin.gz, ter_I_J.bin, horizonte.bin.gz, mundo.json
4. `m4_orto.py` — ortofoto IGN PNOA por tesela + horizonte → ort_I_J.bin, horizonte_orto.jpg
5. `m5_arboles.py` — árboles en los bosques de OSM → arb_I_J.bin (ejecutar DESPUÉS de m4: los dos tocan mundo.json)
6. `m6_edificios.py` — huellas de edificios de OSM con su altura → edi_I_J.bin

Fuentes: © OpenStreetMap contributors (ODbL); IGN MDT05/MDT25 y PNOA (CC BY 4.0 scne.es).

Franja exterior (1-11-2026): para que no se corten las vías que salen de la Comunidad y vuelven a entrar (A-4/R-4 por
Seseña, etc.) la red, el terreno, la ortofoto, los árboles y los edificios incluyen también una franja de 10 km fuera de la
Comunidad (`comunidad_madrid_10km.poly`), sacada de los extractos de Geofabrik de Castilla-La Mancha y Castilla y León
unidos al de Madrid y recortados con ese polígono (`m1_red.py red.osm.pbf red.pkl comunidad_madrid_10km.poly`).
