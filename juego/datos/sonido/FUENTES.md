# Sonido del motor — fuentes y licencias

## v2 (6 nov 2026): síntesis en tiempo real por tablas de ciclo — la que usa el juego
**Sigue siendo síntesis propia** (sin grabaciones de terceros; licencia la del proyecto). Archivos: `motor_v2.json`,
`motor_v2_tsi.bin`, `motor_v2_tdi.bin`, `ruidos_v2.bin`, generados por `pipeline/sonido_motor_v2.py`; los lee
`scripts/motor_sintesis.gd` dentro de `scripts/sonido_motor.gd` (un AudioStreamGenerator a 22.050 Hz).
- Por cada rpm de una rejilla (TSI 550…6.900, 17 puntos; TDI 600…5.500, 15 puntos) y dos cargas (retención con corte de
  inyección / plena carga) hay UN ciclo de motor (720°, 2.048 muestras) de un 4 en línea 1-3-4-2, sumado armónico a armónico
  y limitado en banda para esas rpm (no hay aliasing al leerlo). El 2º orden del cigüeñal (la explosión) domina, con
  medios órdenes débiles por las pequeñas diferencias entre cilindros, más marcados a ralentí y en retención.
- Las resonancias del escape (colector, tubo, silenciosos; el diésel más apagado por el filtro de partículas), la
  admisión pulsante con carga y el golpe de combustión del diésel están en Hz reales a cada rpm: el timbre ya no se estira
  con el tono como al acelerar un bucle grabado a otras rpm.
- En el juego, un acumulador de fase recorre el ciclo a las rpm exactas (tono continuo, sin escalones ni clics) y se
  mezclan las tablas vecinas de rpm y de carga muestra a muestra. Cada explosión varía un poco de fuerza y de ritmo.
- Ruidos (bucles de 1 s de ruido filtrado, sin costura): flujo del escape y admisión (modulados por la envolvente de las
  explosiones), soplido y silbido del turbo (el silbido sube de tono con la presión), válvula de descarga del TSI al soltar.
- Los bucles `*_carga_*.ogg`, `*_retencion_*.ogg`, `turbo.ogg` y `soplo.ogg` (v1, más abajo) ya no se usan.
Supuestos (no publicados por VW): resonancias, niveles relativos y longitudes del escape; elegidos por la física típica
de un 2,0 l turbo, no medidos en un Arteon.

## v1 (1 nov 2026, ya no se usa)

**Todo el sonido del motor es síntesis procedural propia** (no hay grabaciones de terceros en esta carpeta).
Generado offline con `pipeline/sonido_motor.py` (Python + numpy), licencia la del proyecto.

## Qué se buscó antes de sintetizar (1 nov 2026)
Se buscaron grabaciones libres de un 4 cilindros VW (TSI/TDI) con bucles por bandas de rpm, con carga y en retención:
- OpenGameArt, "racing car engine sound loops" (domasx2, CC0): 6 bucles que son el mismo ralentí a distinto tono
  (https://opengameart.org/content/racing-car-engine-sound-loops). No sirven: no hay carga ni retención.
- OpenGameArt, "Car Engine Loop 96kHz, 4s" (qubodup, CC-BY 3.0 / GPL): un solo bucle
  (https://opengameart.org/content/car-engine-loop-96khz-4s).
- Freesound, búsquedas CC0 ("diesel engine loop", "tdi engine", "engine loop rpm"…): ralentís sueltos y pasadas,
  sin juegos de bandas con carga/retención del mismo motor (p. ej. https://freesound.org/people/Mihacappy/sounds/827862/ ,
  https://freesound.org/people/fastson/sounds/243783/).
Mezclar tomas de motores distintos suena a coches distintos al cruzar bandas, así que se sintetiza.

## Cómo se sintetiza (por bucle, ~2 s, 32 kHz mono, ciclos de motor enteros para que cierre sin clic)
- 4 cilindros, orden de encendido 1-3-4-2, una explosión cada 180° de cigüeñal (frecuencia = rpm/30 Hz).
- Pulso de escape por explosión (forma gamma) con variación fija por cilindro y aleatoria por ciclo (más irregular a
  ralentí y en retención), rebote en el colector distinto por cilindro.
- Escape: resonancias del tubo (peine con realimentación, ~3,2 m) y silencioso (paso bajo + resonancias);
  diésel más apagado (filtro de partículas).
- Ruido de flujo en el escape que crece con las rpm; rugido de admisión con carga.
- Diésel: golpe de combustión (traqueteo 1,3–4,5 kHz) a cada inyección, fuerte a bajas vueltas con carga, casi nulo en
  retención (corte de inyección).
- Ruido mecánico fino de la distribución.
- Bandas TSI (ralentí 700, corte 6.500): 700…6.800 rpm, 10 bandas. TDI (ralentí 800, corte 5.000): 800…5.200 rpm, 8 bandas.
  Las rpm exactas de cada bucle están en `motor.json`.
- `turbo.ogg`: silbido + soplido del turbo (bucle). `soplo.ogg`: válvula de descarga recirculada del TSI al levantar.

Supuestos (no publicados por VW): longitudes de escape, resonancias, niveles relativos; elegidos a oído/por física
típica de un 4 cilindros turbo de 2,0 l, no medidos en un Arteon.
