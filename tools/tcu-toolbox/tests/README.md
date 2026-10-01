# Pruebas de la TCU Toolbox

1192 comprobaciones de la lógica no-GUI de `TCU_Toolbox.ps1` contra un simulador
Modbus TCP, sin tocar una planta. Incluye las marcas que el **agente del PC de
planta** extrae de este fichero: si se renombra una, falla aquí y no en planta.

```bash
python3 mb_server.py &        # simulador en 127.0.0.1:15020
pwsh -NoProfile -File test_toolbox.ps1
pwsh -NoProfile -File test_agente.ps1     # 43 comprobaciones del TCU Agente
```

`test_agente.ps1` monta una **instalación de campo en miniatura** en una carpeta
temporal (las dos carpetas al lado, con una planta de dos NCUs apuntando al
simulador), **arranca el agente de verdad** y le pide todas las rutas: lecturas,
auditoría con preset, las tres escrituras, y el SAT de principio a fin
—comprobando que graba los tres CSV del anexo con su cabecera—. Es la única forma
de saber que el agente sigue vivo después de tocar la toolbox, porque no tiene
copia de la lógica: la extrae del `.ps1` por nombre de función.

Sale `TODAS LAS PRUEBAS OK` y código 0, o la lista de fallos y código 1.
Necesita **PowerShell 7** (`pwsh`) y Python 3; en Windows vale el `pwsh` normal.

## El panel web de la NCU

Dos bancos, porque son dos cosas distintas y una necesita un servidor levantado.

```bash
pwsh -NoProfile -File test_panel_ncu.ps1        # la lógica, sin red

python3 api_server.py &                         # maqueta de la API en 127.0.0.1:15080
pwsh -NoProfile -File test_panel_ncu_red.ps1    # el transporte
```

`test_panel_ncu.ps1` corre contra `fixture_panel_ncu.json`, una maqueta con la
**estructura real** de un `initial_data` de El Burgo: huecos vacíos en
`tracker_status`, una TCU muda (todas sus peticiones fallidas), otra recién
caída, más huecos de HSU con tráfico que estaciones declaradas, un gateway con
dos estaciones y un grupo de un solo seguidor con difuso. Comprueba lo que se
**dice** del dato: que un 0 % y un "no se ha preguntado" no salgan iguales, que
una muda se distinga de una caída, que las filas salgan **sin numerar** si el
alineamiento de `tracker_status` no cuadra con los esclavos configurados, y que
la ventana de confirmar una orden de grupo diga a cuántos seguidores va, de
cuándo es el dato, qué NCU falta si falta, y si el grupo está vacío.

Lleva además dos guardas estáticas sobre el AST: que las columnas declaradas de
cada vista sean **exactamente** los campos que la función devuelve —un renombrado
dejaría una columna vacía sin que nadie se enterase— y que contra esa API no haya
más que **dos llamadas**, una sola `POST`, ningún `PUT`/`PATCH`/`DELETE`, y que
los extremos que reescriben la configuración, lanzan firmware o reinician la NCU
no aparezcan ni escritos. Por esa API se puede rehacer la NCU entera de un solo
`PUT`: que no esté no se deja a la vista.

`api_server.py` imita lo justo de la API —`/private_api/auth` con `Set-Cookie`,
`/private_api/initial_data` que devuelve 401 **sin** la cookie— porque hay una
cosa que no se puede comprobar leyendo el código: que la sesión del login viaje
de verdad en la segunda llamada. También responde 405 a cualquier escritura.

Cada guarda de estos dos bancos está comprobada **al revés**: revirtiendo el
arreglo y exigiendo que el banco se caiga. Una prueba que pasa igual con el fallo
puesto no prueba nada.

## Prueba de navegador (opcional)

Los filtros y el orden del informe HTML son JavaScript, así que se comprueban
en un navegador de verdad:

```bash
pwsh -NoProfile -File gen_informe.ps1   # informe_muestra.html con datos inventados
npm i playwright && node test_informe.js
```

Cubre el filtro **multiopción** (marcar ALARMA y OFFLINE a la vez), el cruce de
filtros de dos columnas, "todas"/"ninguna", que abrir un panel cierre el
anterior, la caja de texto de las columnas con muchos valores, la ordenación,
el bloque de **valores imposibles** de la sección de lectura y la **auditoría
de baterías** (que separe alarma de aviso, y sus filtros).

⚠️ "Opcional" es por lo que necesita, no por lo que vale: al no ir en el mismo
comando que el banco de PowerShell, tres comprobaciones de la auditoría de
baterías llevaban rojas desde la v11.39 —la que pasó los rótulos a
minúsculas— sin que nadie lo viese. Si se toca el informe HTML, esto se
ejecuta.
Con `CHROMIUM_PATH` se le puede pasar un Chromium ya instalado.

## Auditoría de maqueta

`maqueta.ps1` extrae la geometría de los ~200 controles del script, les aplica
las reglas de anclaje y **simula agrandar la ventana**, avisando de cualquier
par de controles que acabe solapándose. Es lo que cierra la familia de fallos
"al maximizar no se ve tal botón", que de otro modo solo aparece abriendo la
ventana en Windows. Se ejecuta sola dentro de `test_toolbox.ps1`.

Es una aproximación: lee posiciones y tamaños literales del código, así que un
control colocado con una expresión calculada se le escapa.

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
