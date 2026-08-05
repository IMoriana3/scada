# Pruebas de la TCU Toolbox

254 comprobaciones de la lógica no-GUI de `TCU_Toolbox.ps1` contra un simulador
Modbus TCP, sin tocar una planta.

```bash
python3 mb_server.py &        # simulador en 127.0.0.1:15020
pwsh -NoProfile -File test_toolbox.ps1
```

Sale `TODAS LAS PRUEBAS OK` y código 0, o la lista de fallos y código 1.
Necesita **PowerShell 7** (`pwsh`) y Python 3; en Windows vale el `pwsh` normal.

## Prueba de navegador (opcional)

Los filtros y el orden del informe HTML son JavaScript, así que se comprueban
en un navegador de verdad:

```bash
pwsh -NoProfile -File gen_informe.ps1   # informe_muestra.html con datos inventados
npm i playwright && node test_informe.js
```

Cubre el filtro **multiopción** (marcar ALARMA y OFFLINE a la vez), el cruce de
filtros de dos columnas, "todas"/"ninguna", que abrir un panel cierre el
anterior, la caja de texto de las columnas con muchos valores y la ordenación.
Con `CHROMIUM_PATH` se le puede pasar un Chromium ya instalado.

## Qué cubre

Conversiones de valor (u16/s16/u32/f32/f32deg/bits/BCD, coma decimal española,
guardarraíles de rango y de no finitos), orden numérico de variables, carga de
plantas (entradas `(auto)`, planta completa, segmentado por gateway, CSV de
topología), filtro de variables, decodificación de alarmas y salud, bloque
compacto de la NCU, TEST COMM, planificador de campaña de firmware, seguimiento
PEM, informe HTML (filtros, orden, sección de lectura con su resumen de
discrepancias), la selección de variables de la pestaña Leer y la lectura de varias HSUs de una pasada.

## El simulador

`mb_server.py` responde FC03/FC16/FC22 sobre `127.0.0.1:15020` con datos de
prueba por esclavo:

| Esclavo | Para qué |
|---|---|
| 5 | TCU con alarmas, identidad completa (serie, MAC, fecha de fabricación) |
| 6, 8, 9 | TCU sin alarmas, con aviso y con alarma crítica |
| 7 | No existe: contesta `GatewayTargetNoResponse` (0x0B) |
| 1 | Bloque compacto de la NCU (TCUs, HSUs, `lastComm`, reloj) |
| 185 | HSU: meteo en vivo, config y caja negra de 24 h |
| **77** | **NCU que va una respuesta por detrás** (ver abajo) |

### El esclavo 77

Reproduce el fallo de campo de la v5.0. Falla una vez y a partir de ahí
contesta cada petición con el cuerpo de la **anterior**, sellándola con el
identificador de transacción de la petición en curso — así que comprobar el
identificador no lo detecta.

Sin la resincronización del cliente, leer tres variables devuelve los valores
corridos una columna (`0.95993` y `343.775` en vez de `6` y `30`), que es
exactamente lo que se vio en Ayora. Con ella, `55`, `6` y `30`.

Es la prueba de regresión de un fallo que no rompía nada de forma visible: solo
devolvía números plausibles y falsos. Si alguna vez vuelve a fallar, hay que
mirar `Modbus-Transaccion` antes que ninguna otra cosa.
