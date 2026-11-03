# Motor de sincronización

Sincroniza clips de varias cámaras, teléfonos y grabadores comparando el audio.
Lee un XML de Premiere (Final Cut Pro 7 XML) y escribe otro con cada clip en su
lugar. Escrito desde cero en Swift, con las librerías de audio de macOS; no hay
nada que instalar.

## App

```bash
./make_app.sh          # arma ../Synco.app (sin Xcode; usa el SDK 26.5 si está el 27)
./make_dmg.sh          # arma la app y ../dist/Synco-<versión>.dmg para instalar
open ../Synco.app
../e2e/run.sh          # 12 pruebas de punta a punta sobre el proyecto real
```

## Uso por línea de comandos

```bash
cd engine && swift build -c release
.build/release/synccli sync entrada.xml salida.xml informe.md
```

En Premiere: Archivo › Importar el XML de salida. Los clips que no se pudieron
sincronizar por audio quedan con etiqueta rosa y ubicados por la hora de su
archivo (precisión de un segundo, aproximadamente).

La primera vez lee el audio de todos los archivos y lo guarda en caché;
las siguientes tardan segundos en leer.

## Cómo sincroniza

0. **Hora de grabación de cada archivo.** Del WAV del grabador, la referencia de tiempo
   interna (muestras desde la medianoche, exacta). De cámaras y teléfonos, la fecha de
   creación que escriben adentro del MOV/MP4; si la fecha del archivo coincide con ella
   (±2 s) se usa la del archivo, que trae fracciones de segundo. La "hora de origen" del
   WAV no se usa: muchos grabadores la escriben al cerrar el archivo. Ver `synccli times`.

1. **Audio de análisis.** Cada archivo se decodifica a su frecuencia original,
   se mezcla a mono y se filtra y baja a 4 kHz con un filtro propio (el
   conversor de macOS estira el tiempo unos 50 ppm).
2. **Referencia.** El dispositivo con más audio (el grabador) se arma de
   corrido. Un archivo creado justo cuando se cerró el anterior es la misma
   toma partida a los 2 GB y va pegado, sin hueco, digan lo que digan las fechas.
3. **Búsqueda global.** Cada clip se compara contra toda la referencia con
   correlación cruzada generalizada (GCC-PHAT, β 0,75, banda 100–1900 Hz):
   cuenta *cuándo* pasan los sonidos y no *cómo* los colorea cada micrófono.
   Se acepta un pico que se destaque mucho del ruido (z ≥ 9) y del segundo
   mejor (relación ≥ 1,3).
4. **Relojes.** Con los clips encontrados se calcula el desfase del reloj de
   cada dispositivo. Un resultado que no cuadra con su reloj se vuelve a mirar.
5. **Búsqueda cerca del reloj.** Los que faltan se buscan ±20 s alrededor de
   donde los pone su reloj, contra el grabador y contra los clips de otros
   dispositivos ya ubicados. Hace falta menos (z ≥ 7). Si hay dos picos
   parecidos, gana el que cae donde dice el reloj. Una coincidencia débil lejos
   del reloj se descarta.
   Si el grabador casi no escucha un clip, se prueba contra cada clip de otra cámara ya
   ubicado (no otra vez contra el grabador), con la misma exigencia de la búsqueda global
   (relación ≥ 1,3) y solo si cae a menos de 4 s de donde dice su reloj.
6. **Por reloj.** Lo que no tiene audio en común con nada se ubica por la hora
   de su archivo y el desfase de su dispositivo, sin pisar sus propios clips.
7. **Verificación.** Los pares de clips de dispositivos distintos que quedaron
   superpuestos se comparan entre sí directamente. Como cada uno se ubicó por
   separado, que coincidan confirma a los dos.

## Drones (paso extra, después de sincronizar)

Botón **Agregar dron** en la app, o `synccli dron entrada.xml salida.xml carpeta-del-dron`.
Las tomas sin sonido van en una pista de video propia, arriba de las cámaras:

1. **Su hora.** El `.SRT` del dron (DJI) trae la hora de cada cuadro al milisegundo; si no hay,
   la fecha del archivo. El dron toma la hora del teléfono que lo maneja: es la hora real.
2. **Su reloj contra la línea de tiempo.** Los teléfonos del proyecto también tienen la hora real,
   y la sincronización ya sabe dónde van sus clips: dicen dónde cae la hora del dron (±10 s). Sin
   teléfonos, los relojes de las cámaras dan una idea más gruesa y se busca más amplio.
3. **Las luces.** Donde el dron y una cámara filmaron a la vez, un flash, una luz de escenario o
   una nube cambian la luz que ven los dos en el mismo instante. Se compara cuánto cambia el
   brillo de cada cuadro (en escala logarítmica, así no importa la exposición ni el perfil log).
   Todas las tomas del dron comparten reloj: se buscan juntas para esa única corrección, y
   después cada una de cerca. La copia liviana (`.LRF`) se lee en lugar del 4K cuando está.

Azul: ubicada por sus luces. Amarillo: por su hora, con el reloj corregido por las luces de sus
otras tomas. Rosa: solo por su hora. Una hora de otro día va al final, con sus distancias.

## Verificar cualquier resultado

```bash
.build/release/synccli check sincronizado.xml
```

Juzga un XML ya sincronizado (de Synco, de otra app o hecho a mano): compara por audio cada par
de clips superpuestos de dispositivos distintos y dice cuántos quedaron a 1 cuadro o menos.

## Límites conocidos

- Las cámaras a distinta distancia del sonido difieren 1 cuadro cada ~14 m.
- Un clip muy corto (menos de ~2 s) casi nunca tiene audio suficiente.
- Por ahora solo lee y escribe FCP 7 XML (Premiere, Resolve, Vegas). FCPXML y
  AAF todavía no.
