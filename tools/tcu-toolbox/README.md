# TCU Toolbox — configuración y diagnóstico de TCUs Sunner (offline)

> Herramienta de campo para O&M: escribe, lee, respalda y diagnostica los TCU de los seguidores a través del gateway Modbus TCP de la NCU. **100 % offline**: un `.ps1` + un `.bat`, sin instalar nada (PowerShell viene con Windows), sin red fuera de la LAN de planta.

Es el complemento de **escritura** del SCADA de este repo: el SCADA es solo-lectura a propósito; cuando hay que *cambiar* algo en un TCU (configuración, reloj, NVM) se usa esta toolbox desde el portátil conectado a la LAN de planta.

## Arranque

1. Copia la carpeta `tcu-toolbox/` al portátil de campo (los JSON de plantas van dentro, en `plantas/`).
2. Doble clic en `TCU_Toolbox.bat` (no requiere admin).
3. Elige planta (o rellena IP/puerto a mano) y usa las pestañas.

Mapas de registros: **SUNNER TCU v6.1 (FW v1.4.3)**, **NCU R7.1** (salud de la NCU: puerto 502, unit 1) y **HSU R23** (estación meteo). La NCU actúa de gateway: el *unit id* Modbus es el número de TCU; en El Burgo el passthrough escucha en los puertos 503 (GW1) y 504 (GW2) de cada NCU.

### Entradas "(auto)": adiós al error de puerto

Cuando una NCU tiene varios gateways, el desplegable ofrece además una entrada **"… (auto)"** que cubre la NCU completa: la toolbox resuelve sola el puerto de cada TCU según los rangos (p. ej. en El Burgo NCU1, la TCU 30 va al 503 y la 80 al 504) y recorre los gateways **en secuencia** en las operaciones por rango (Escribir, Leer, Diagnóstico, Reloj, NVM). Los TCU que no caen en ningún gateway (p. ej. el hueco 108 de NCU2) se saltan con aviso. Nota de campo: la **TCU 109 de NCU2** está declarada como fila suelta del GW2 — rangos sacados de los `.bat` de Sunner, pendiente de confirmar en planta.

## Pestañas

| Pestaña | Qué hace |
|---|---|
| **Escribir** | Tabla de variables (todo el mapa 4xxxx: carga, calefactor, comunicaciones, geometría, umbrales, deadbands, safe positions, rangos de tilt, motor, SoC) con verificación tras escribir, reintentos, "reintentar fallidas" y guardado en NVM (40007 bit 15). Campo **Filtro**: escribe `soc`, `tilt`, `zigbee`… y el desplegable de variables se reduce a lo que casa (las filas ya elegidas nunca se pierden). Presets JSON y carga de un **backup como preset** (excluye comandos, fecha/hora y, desde v7.1, la **identidad de red**: esclavo, PAN ID y clave, que son propios de cada TCU y no se clonan; escribirlos a más de una TCU a la vez está bloqueado). Botón **CSV por TCU...**: escribe valores distintos a cada TCU desde un CSV `TCU;variable;valor` (o `NCU;TCU;variable;valor` desde v7.2, que reparte las filas entre las NCUs de la planta en una pasada) (la variable admite nombre exacto o prefijo único, p. ej. `41010`). Acepta también la entrada **"(Planta completa)"** (v5.7): recorre todas las NCUs en secuencia con sus rangos automáticos, con la confirmación diciendo cuántas NCUs y cuántos TCUs se van a tocar. El rollback previo se hace por NCU; si fueran más de 400 valores a leer, avisa de que puede tardar más que la propia escritura y deja elegir entre crearlo, saltarlo o cancelar. Los registros de comando piden **doble confirmación**. Al escribir, el log muestra por TCU el **valor que había antes** de cada variable (`nombre: antes → después`), tanto en la escritura por rango como en el CSV por TCU. |
| **Leer variable** | **Varias variables a la vez** en una **tabla igual que la de Escribir** (v5.2: una fila por variable, con su registro y su tipo al lado; antes era combo + Añadir + lista, que no pegaba con la pestaña de al lado). Botón **Quitar** y tecla **Supr** para sacar de la lista las variables que ya no interesan, con las cabeceras de fila visibles para poder marcar varias a la vez (v6.4 — el botón existía con la lista anterior y se perdió al pasar a tabla). Lo mismo en Escribir. Admite además los registros de estado 3xxxx. Una columna por variable en el resultado en un rango de TCUs — o en la **Planta completa** (v4.1): recorre todas las NCUs en secuencia con sus rangos automáticos y añade la columna NCU a la vista y al CSV — con resumen de discrepancias por variable (cuántos TCU tienen cada valor, en toda la planta). Campo **Filtro** con contador de coincidencias (busca también en los registros `ESTADO …`), que reduce el desplegable sin perder nunca las filas ya elegidas. Si la **primera** variable de un TCU agota los reintentos sin respuesta, el TCU se da por mudo y no se prueban las demás (v5.2): con cinco variables, 8 s de timeout y 3 reintentos eso son ~24 s en vez de ~2 min por TCU muerto. Un fallo Modbus (dirección ilegal, etc.) no cuenta: ahí el equipo sí contesta y el resto se lee. Export CSV y, desde v4.8, la lectura entra también en el **INFORME HTML** con su resumen de discrepancias. |
| **Volcar TCU** | Todas las variables de un TCU (config + estado + identidad opcional). Export CSV y **backup JSON** con metadatos (planta, IP, TCU, fecha, versión de mapa). Botón **Comparar con backup JSON**: marca en naranja las diferencias con un volcado anterior — ideal para verificar una TCU recién sustituida. **BACKUP NCU**: vuelca todas las TCUs de un rango a una carpeta, un JSON por TCU, con marca de completitud — el seguro antes de tocar nada. |
| **Diagnóstico** | Por defecto en modo **"vía NCU" (rápido)**: lee el bloque compacto que la NCU cachea de sus TCUs (30500+, puerto 502) y sus HSUs (30200+) en lecturas TCP locales — segundos en vez de minutos, con `lastComm` como criterio de OFFLINE (igual que el SCADA) y **una fila por HSU** (viento, nieve, alarmas). Desmarcando "vía NCU" ataca los TCU en directo por Zigbee (más lento; añade las alarmas de hardware 30004/30005 que el bloque compacto no lleva). Escanea un rango de TCUs — o la **Planta completa**: al elegir la entrada "(Planta completa)" del desplegable recorre **todas sus NCUs en secuencia** (cada una con sus gateways y rangos propios; el campo **NCUs** filtra cuáles, p. ej. `1,3-5`) y añade la columna NCU a la vista y a los exports, incluyendo una **fila de salud por NCU** (GW1/GW2 desconectados, UPS, seta, reloj de la NCU — mapa R7.1, puerto 502) — y clasifica cada uno en `OK / AVISO / ALARMA / OFFLINE` con el **mismo criterio de salud que el SCADA** (eje bloqueado, sobrecorriente, batería crítica, seta, fuera de rango ⇒ alarma; resto de bits, `system_ok=0` o desviación >5° ⇒ aviso). El CSV exportado añade las **alarmas desglosadas en columnas 0/1** (filtrables en Excel). Botón **TEST COMM (rápido)** (v4.3): la prueba de campo más rápida — "¿quién habla y quién no?" de **todas las NCUs, TCUs y HSUs** de la selección (incluida la Planta completa). No lee el bloque compacto de cada TCU, solo los `lastComm` que la NCU cachea (2 registros por TCU, 50 TCUs por lectura) más la salud de la NCU: **4 lecturas Modbus por NCU de 75 TCUs en vez de 18**. Da OK / OFFLINE con la antigüedad del último dato, el listado de las mudas por NCU y el tiempo total; no da alarmas ni posiciones (para eso, DIAGNOSTICAR). Su export JSON se marca como `test_comm` para no confundirlo con un diagnóstico en el histórico. Tras el escaneo, la consola imprime el **resumen general por NCU** y la fila **Ver** permite **filtrar la vista del resultado** por NCU y por salud con **casillas que se pueden marcar a la vez** (p. ej. ALARMA + OFFLINE; ninguna marcada = todas) **sin relanzar lecturas** — los exports CSV/JSON llevan siempre el diagnóstico completo. La vista muestra lo esencial de campo: **modo (OFF/MANUAL/AUTO)**, **posición real/objetivo/desviación**, **SoC** y las **alarmas decodificadas bit a bit en texto** (registros 30002–30005). El resto (SoH, tensiones, temperaturas, registros hex) viaja igualmente en el export CSV/JSON. |
| **PEM** | La pestaña de puesta en marcha. **TEST DE MOTOR** por rango: cada TCU pasa a MANUAL, pulsa Oeste y Este midiendo Δángulo y corriente, vuelve a su modo, y da veredicto **PASA / FALLA (no se mueve, sin corriente, sentido invertido) / DUDOSO** — con **guardia de viento** (consulta las HSU vía NCU y se bloquea si hay nivel > 0), parada de motor garantizada y TCUs con alarma crítica saltados. **APLICAR MODO** (OFF/MANUAL/AUTO) y **LIMPIAR ALARMAS** (reset de las alarmas enclavadas, 40007 bit 13) masivos con verificación por efecto en 30001/30006. **STOW / QUITAR STOW** (42000) con verificación de la safe position activa. **Comisionado**: leer el estado (30001 bits 4:3: Factory → Configurado → Motor verificado → COMISIONADO) por rango — o de la **Planta completa vía NCU** (los bits van en el registro de estado que la NCU cachea en su bloque compacto: toda la planta en segundos, sin Zigbee, con columna NCU y los TCUs offline marcados) — y fijarlo (40000 bits 7:5). Todo exportable a CSV. |
| **HSU** | La estación meteo. Botón **BUSCAR HSUs** (v4.0): escanea las NCUs de la selección (Planta completa, (auto) o una entrada suelta) leyendo el bloque compacto que cada NCU cachea (30200+, puerto 502) y lista **qué HSUs hay y de qué NCU cuelga cada una**, con su salud y su viento/nieve; el desplegable permite elegir una — fija su IP y su esclavo si la topología lo trae — o "(todas)" para ver el resumen conjunto. **LEER METEO** y **LEER CONFIG** funcionan sobre **todas las HSUs de la planta de una pasada** (v5.3): con "(todas)" en el desplegable recorren cada una por la IP y el gateway de su NCU, con una cabecera por HSU en la tabla, las mudas marcadas y un resumen de cuántas respondieron y cuántas tienen alarma o viento; LEER CONFIG avisa además si alguna HSU lleva **umbrales distintos** de las demás. Las escrituras (umbrales, reloj, nieve, NVM) siguen pidiendo una HSU concreta a propósito. Las operaciones directas van por su esclavo Modbus (default 185, editable; se preselecciona desde la topología si el fichero de plantas trae `hsu_esclavo`): **meteo en vivo** (viento m/s y km/h, dirección, nieve, lluvia, T/HR, irradiancia) con **alarmas decodificadas**; **config y umbrales de viento** (leer y escribir, con confirmación de seguridad y verificación); **reloj UTC**; **calibración del cero de nieve**; **NVM**; y la **caja negra de 24 h** (viento medio/máx, nieve e irradiancia minuto a minuto) descargada a CSV — para investigar un stow después de que pase. |
| **Flota** | **Auditoría**: compara un rango de TCUs contra un *preset de referencia* (un preset o un backup completo) y lista **solo las desviaciones** (esperado vs leído), marcando en rojo las que además son **valores imposibles** para esa variable (v7.1), con export CSV — el "¿está toda la NCU igual?" en un clic. **Inventario**: FW principal/fábrica, nº de serie, MAC Xbee, HW y fecha de fabricación de todo el rango, con aviso si hay firmwares mezclados y export CSV. Ambas aceptan también la entrada **"(Planta completa)"**: recorren todas las NCUs en secuencia con sus rangos automáticos (los campos de TCU muestran NA) y añaden la columna NCU a la vista, al CSV y al informe HTML. |
| **Firmware** | Planifica la **campaña de actualización** (v4.4). La toolbox **no** actualiza firmware — eso lo hace el *TCU Updater* de Sunner — pero resuelve lo caro: a partir del último **Inventario** y de una **versión objetivo**, saca el plan por **ventanas del updater** (una por NCU + gateway, que se abren a la vez): cada una dice con qué IP y puerto abrirla, qué rangos pegarle (*Add from … to …*) y cuánto tarda, y al final el total de la campaña. Muestra la estimación en paralelo y en serie, marca las TCUs que no respondieron al inventario (no se puede actualizar lo que no comunica), exporta el plan a CSV y, al terminar, **VERIFICAR TRAS ACTUALIZAR** relee el FW de las TCUs del plan y dice cuáles subieron y cuáles siguen pendientes. |
| **SAT** | Los **ensayos de aceptación del Anexo 4** que se pueden automatizar (v6.6). **INICIAR REGISTRO** deja la toolbox registrando la planta entera durante los días que dure el ensayo, con dos cadencias sobre el bloque compacto de la NCU (puerto 502, sin tocar la Zigbee): un pase barato de **comunicaciones** cada 15 s (4 lecturas por NCU) y uno de **precisión y alarmas** cada minuto (18 por NCU). Escribe a disco en cada pase, en ficheros diarios y en modo añadir: si el PC se reinicia a los cuatro días, lo registrado sigue ahí y el ensayo continúa al volver a arrancar. Los **criterios de aceptación** (tolerancia de precisión, los umbrales de disponibilidad de TCU, RSU/NCU y comunicaciones, y la **ventana de la regla de los dos minutos** de D.4) y **todos los tiempos** (duración del ensayo **en minutos, horas o días** — 7 días para el ensayo del anexo, 20 minutos para comprobar el montaje antes de arrancarlo de verdad —, muestreo de TCU y de comunicaciones, ritmo del cronómetro y su tope) son **campos editables** y se recuerdan entre sesiones (v6.9 y v7.0): son de contrato, no del equipo, y cambian de una planta a otra. El registro **no depende de ellos**, así que ajustarlos y volver a analizar da el veredicto nuevo en segundos — sin repetir el ensayo. **ANALIZAR Y EMITIR** lee los CSV y emite el veredicto de los tres ensayos: **D.1.1** precisión de seguimiento (una muestra solo cuenta si el objetivo lleva dos muestras sin cambiar, que es como se descartan los transitorios y las activaciones de posición de seguridad que el anexo excluye), **D.3.4.1/2/3** disponibilidad de operación de TCUs (≥ 99 %), **RSU** (≥ 99,5 %) y **NCU** (≥ 99,5 %), por equipo y día, contando alarmas de motor, batería y comunicación; las meteorológicas no cuentan, como dice el anexo. Y **D.4** disponibilidad de comunicaciones, con la regla del anexo (un intento fallido suelto no computa salvo que se repita dentro de dos minutos, y entonces computan todos) y **umbrales distintos por tipo**: 98,5 % en TCU y 99,5 % en RSU. **RSU es lo que el mapa Sunner llama HSU**; los entregables del SAT usan RSU, que es como lo llama el contrato. Cada ensayo deja su `RESULTADO_*.csv` con el detalle por equipo y día, y la lista de los que incumplen. **CRONÓMETRO** (v6.7) para los **abanderamientos D.2.1–D.2.5** y la **posición objetivo manual D.3**: la condición la provoca el operario (bajar el umbral de viento, cortar la alimentación de la NCU…) y el cronómetro muestrea cada 3 s y apunta por TCU la hora UTC de recepción de la orden, la inclinación en ese momento, la hora de llegada a posición de seguridad, la inclinación allí, y lo mismo del desabanderamiento — las columnas exactas que pide el anexo, más los segundos de ida y vuelta. ⚠️ No hay un bit documentado de "posición de seguridad activa": la llegada de la orden se **infiere** del salto del objetivo y la llegada del seguidor de que el real alcanza ese objetivo. Queda dicho aquí porque en una recepción importa. **HOJA D.1.2** genera la hoja de precisión con equipo externo (nomenclatura, hora UTC, posición del tracker, posición según algoritmo) con la columna de la lectura del instrumento en blanco, que es la única que no puede poner una máquina. |
| **Utilidades** | **Sincronizar reloj**: escribe la hora del PC en un rango de TCUs (40001–40006 + secuencia 40007 bit0→bit1) y verifica leyendo el reloj real (30079). **Identificación**: FW principal/fábrica, MCU secundario, BQ, HW, Xbee HW/FW, **MAC Xbee**, **número de serie**, fecha de fabricación y lote (bloque 30300+). |

En las operaciones de **planta completa**, cada línea de la consola lleva delante la **NCU** además del TCU (v5.8): los números de TCU se repiten en cada NCU, así que sin eso una línea no dice de qué equipo habla. El resumen de fallidas y el botón **Reintentar fallidas** también van por NCU — reintentar sobre la NCU equivocada sería escribir en el seguidor de al lado.

Consola común con colores, botón **CANCELAR** para abortar operaciones largas, y **log automático** a `logs/tcu_toolbox_AAAAMMDD.log`. La ventana es **redimensionable y maximizable** (v4.6): al agrandarla crecen las tablas y la consola, que es lo que interesa en una planta de cientos de TCUs.

**Tabla de resultados de Leer variable (v5.4)** — al rehacer la pestaña en la v5.2 se borró sin querer la tabla de resultados: la lectura fallaba nada más empezar con `No se puede llamar a un método en una expresión con valor NULL`. Restaurada, con la tabla de elección de variables arriba y la de resultados debajo (solo la de abajo crece al agrandar la ventana). La suite gana un chequeo estático que recorre el árbol sintáctico y falla si alguna variable se usa sin haberse creado nunca — que es exactamente lo que se escapó aquí.

**La auditoría no se cree la primera lectura (v9.1)** — salía esto: *«Esperado
-10, Leído -10, DESVIACIÓN»*. Sin sentido, y con una explicación clara: la
comparación se hace **a nivel de registro** y falló por una respuesta
descolocada; el valor que se enseña viene de una **segunda** lectura, que ya dio
el bueno. La auditoría era el único sitio que se había quedado sin la doble
comprobación que *Leer variable* tiene desde la v7.2.

Ahora, cuando la comparación cruda falla, se relee y se compara el valor
decodificado: solo es desviación si **de verdad** difiere. Las que se caen por el
camino se cuentan aparte —*«N eran respuestas descolocadas, no desviaciones»*— que
además es un termómetro del enlace. La comparación normaliza lo que no es
diferencia real: mayúsculas del hexadecimal (`0x0A00` = `0x0a00`) y coma o punto
decimal (`6,5` = `6.5`).

**La topología del repo tenía las plantas sin nombre (v10.4)** — el Excel
maestro solo pone el nombre del proyecto en la **primera fila** de cada planta,
y `make_plantas.py --excel` usaba el de cada fila: salían `Ayora NCU1`,
` NCU2`, ` NCU3`… La entrada **(Planta completa)** se agrupa por el prefijo
`<Planta> NCU<n>`, así que con los nombres partidos salían dos grupos —uno con
la NCU 1 sola, que se descarta por tener menos de dos— y la planta completa se
quedaba con **15 de 16** NCUs. Solo afectaba a los ficheros generados desde el
Excel: los exportados desde la página **IPs** de la plataforma siempre han
llevado el nombre en cada fila y por eso allí salían las 16.

Regenerados los ficheros de `plantas/`, y una comprobación nueva rechaza
cualquier entrada cuyo nombre empiece por espacio o por `NCU`.

**El generador ya sabe leer la HSU (v10.4)** — si la hoja *Direcciones IP* llega
a tener una columna **HSU** (o *HSU esclavo*) con el número de esclavo Modbus por
fila de NCU, sale solo como `hsu_esclavo` en el JSON y la toolbox lo
preselecciona. Mientras no exista, avisa por consola y las entradas salen sin
él: la toolbox usa el 185 por defecto y **BUSCAR ESCLAVO**.

**El agente, probado de punta a punta (v11.12)** — `tests/test_agente.ps1`
monta una **instalación de campo en miniatura** (las dos carpetas, una planta de
dos NCUs contra el simulador), **arranca el agente de verdad** y le pide todas
las rutas: lecturas, auditoría con preset, las tres escrituras y el SAT completo,
comprobando que graba los tres CSV del anexo con su cabecera. 33 comprobaciones.

Nada más escribirlo encontró un fallo real: **el diagnóstico del agente no
llevaba la columna `GW`** que esta herramienta añadió en la v11.6. Y como
`Export-Csv` se queda con las columnas de la primera fila, faltaba en todo el
fichero.

El agente (v2.4) completa además la réplica de lo que se puede hacer sin mover
un seguidor: `/hsus/meteo`, `/hsus/config`, `/hsus/cajanegra`, `/auditoria`
(el preset viaja en el cuerpo), `/escribir-lote` y `/escribir-csv`. El lote
**bloquea la identidad de red**, igual que aquí.

**El agente, probado de punta a punta (v11.12)** — `tests/test_agente.ps1` monta
una **instalación de campo en miniatura** (las dos carpetas, una planta de dos
NCUs contra el simulador), **arranca el agente de verdad** y le pide todas las
rutas: lecturas, auditoría con preset, las tres escrituras y el SAT completo,
comprobando que graba los tres CSV del anexo con su cabecera. 33 comprobaciones.

Nada más escribirlo encontró un fallo real: **el diagnóstico del agente no
llevaba la columna `GW`** que esta herramienta añadió en la v11.6. Y como
`Export-Csv` se queda con las columnas de la primera fila, faltaba en todo el
fichero.

El agente (v2.4) completa además la réplica de lo que se puede hacer sin mover un
seguidor: `/hsus/meteo`, `/hsus/config`, `/hsus/cajanegra`, `/auditoria` (el
preset viaja en el cuerpo), `/escribir-lote` y `/escribir-csv`. El lote
**bloquea la identidad de red**, igual que aquí.

**Lo que solo lee, también en remoto (v11.11)** — el [agente](../tcu-agente/)
(v2.3) expone ahora `/baterias`, `/inventario`, `/plan-firmware`, `/leer`,
`/cierre` y `/trabajos`, **reutilizando estas mismas funciones** (`Bat-Tabla`,
`Bat-Auditar`, `Ident-Leer`, `Leer-Decodificado`, `Plan-Firmware`,
`Plan-Ventanas`, `Cierre-Estado`…). Ninguna toca un seguidor y ninguna depende
de `permitir_escritura`.

Devuelven el **mismo formato** que exporta esta herramienta, así que la web pinta
lo que venga sin una vista por pestaña. `/inventario` y `/plan-firmware` van TCU
a TCU por Zigbee y en una planta entera son **minutos**: se avisa antes de
arrancarlas.

Un fallo que salió al montarlo: `Ident-Leer` devuelve una lista `Campo`/`Valor`,
no un diccionario, así que indexarla por nombre daba **null en todas las
columnas** del inventario. Verificado contra el simulador, columna a columna.

**El SAT se arranca en remoto y se graba aquí (v11.10)** — el ensayo son días de
muestreo continuo. Mandarlo por HTTP no tiene sentido: si se cae el túnel, se
pierde. Ahora el [agente](../tcu-agente/) (v2.2) expone `/sat`, `/sat/iniciar`,
`/sat/parar` y `/sat/descargar`, y **reutiliza los tres pases de esta pestaña**
(`Sat-PaseComms`, `Sat-PaseTcu`, `Sat-PaseEquipos`), así que graba en
`informes/sat_<planta>/` con el **mismo formato** — y **ANALIZAR Y EMITIR** los
lee tal cual.

Desde la *Toolbox web* se arranca, se para y se descargan los CSV; el veredicto
(D.1.1, D.3.4, D.4) se sigue emitiendo aquí, en el PC de planta. El agente
**reanuda solo** el ensayo si se reinicia a mitad, igual que hace esta pestaña.

Arrancar un ensayo no toca los seguidores, así que no va detrás de
`permitir_escritura` ni pide doble confirmación — pero sí queda auditado con el
usuario que lo pidió.

**El agente del PC de planta se había quedado atrás (v11.9)** — el
[TCU Agente](../tcu-agente/) no tiene copia de esta lógica: **extrae trozos de
`TCU_Toolbox.ps1` por nombre de función**, para que haya un solo origen de
verdad. Una de sus marcas era `function Rango-Tcus`, que la v11.8 eliminó al
unificar los cuadros de TCUs — así que **el agente dejaba de arrancar** con esa
versión.

Arreglado (nueva marca, y el agente pasa a v2.1), pero lo que importa es que no
vuelva a pasar: ahora el error dice **qué marca falta y que las dos carpetas van
juntas**, y la suite de la toolbox comprueba que todas las marcas y las
funciones que el agente llama siguen existiendo. Si alguien renombra una,
**falla aquí antes de publicar**, no en el PC de planta.

Las dos carpetas viajan en la misma release y hay que copiar **las dos**.

**Una sola forma de hacer cada cosa (v11.8)** — repaso de duplicidades entre
pestañas. Lo que había:

- **Dos maneras de decir qué equipos.** Cuatro pestañas tenían el cuadro `TCUs`
  de la v11.6 y otras cuatro seguían con «TCU de \[ \] a \[ \]»: PEM, Inventario,
  Backup NCU y Sincronizar reloj. Ahora **las ocho** llevan el mismo cuadro, con
  la misma sintaxis y el mismo globo de ayuda, y `Rango-Tcus` desaparece. El
  botón *PREPARAR MODO AUTO* del Cierre también manda las TCUs exactas en vez de
  un rango.
- **Diecinueve diálogos de guardar copiados**, cada uno con su sello de fecha,
  su aviso en consola y su `try`. Ahora hay `Exportar-Csv` y `Exportar-Json`, y
  solo quedan sueltos los tres que de verdad son distintos (el preset, que lleva
  nombre fijo; el backup, que añade `_INCOMPLETO`; y el log en texto).
- **Y con eso, un fallo que se arrastraba**: siete de los CSV salían con **coma**
  en vez de punto y coma, así que en un Excel en español se abrían en una sola
  columna — lectura, identidad, volcado, auditoría, inventario, PEM y
  diagnóstico. Ahora todos van con `;`.
- El nombre de planta para ficheros estaba con su expresión regular copiada en
  cinco sitios: ahora es `Planta-Fichero`.

Son ~60 líneas menos y, sobre todo, un sitio donde tocar cuando algo cambie.

**Los trabajos ya no se pisan (v11.7)** — el diagnóstico, el inventario, la
auditoría, la lectura y la tabla de baterías vivían **solo en memoria**: lanzar
lo siguiente borraba lo anterior. Y eso es justo lo que pasa en una campaña —
auditas el firmware, y mientras el updater trabaja quieres diagnosticar—: al
volver, lo de antes ya no estaba.

Ahora **cada operación que termina se guarda sola** en `trabajos/`, con su
fecha, su planta, su técnico y una nota de lo que salió. La pestaña **Trabajos**
los lista (lo más reciente arriba) y **CARGAR** devuelve cualquiera a su pestaña
— sin leer nada de la planta, que es una copia de disco.

- Se guardan los **20 últimos de cada tipo y planta**; lo viejo se va solo, que
  una semana de campaña son muchos diagnósticos de 754 filas.
- **GUARDAR LO DE AHORA** deja una copia de todo lo que haya en memoria con una
  nota tuya, para marcar un momento (*«antes de tocar la NCU 12»*).
- La **lectura** cargada vuelve a valer para auditar con *«Usar la última
  lectura»* marcado, sin volver a recorrer la planta.
- La carpeta `trabajos/` no se sube al repo.

El **cierre** no entra aquí porque ya se guardaba por planta en `cierre/`: eso
sobrevivía a cerrar el programa desde la v9.

**Un cuadro para decir qué equipos (v11.6)** — «TCU de [1] a [44]» no sabe decir
*«la 10, la 22 y de la 30 a la 40»*, y menos aún mezclar NCUs. Había que ir tres
veces o pasar por un CSV. Ahora hay **un solo cuadro `TCUs`** en Escribir, Leer,
Diagnóstico y Auditoría:

| Se escribe | Qué hace |
|---|---|
| `1-44` | el rango de siempre |
| `10,22,30-40` | sueltas y tramos a la vez |
| `12/10, 15/5-12` | cada tramo con **su** NCU |
| `12/*` | todas las de la NCU 12 |
| vacío o `NA` | todas las de la selección |

Y en **Conexión**, un cuadro **`GW`**: con `504` se trabaja sobre **todas las
TCUs de ese gateway** de cada NCU, que antes obligaba a ir NCU por NCU con el
rango a mano. Vacío = todos.

Con eso, **la auditoría y el cierre mandan a Escribir las TCUs exactas**. Antes,
con TCUs de tres NCUs distintas (`NCU8/29`, `NCU13/14`, `NCU15/3`) el botón
*PREPARAR ESCRITURA* ponía «TCU de 3 a 29» — 27 seguidores, la mayoría buenos, y
todos de la NCU que estuviera seleccionada. Ahora pone `8/29,13/14,15/3` y toca
esos tres. El CSV de corrección desaparece: ya no hace falta.

El diagnóstico gana además una columna **GW**, que dice de qué gateway cuelga
cada TCU: en modo *vía NCU* todo se lee por el 502, pero el equipo sigue estando
en su red Zigbee y eso es lo que pide el updater.

**Los ceros de una TCU muda no son medidas (v11.6)** — si la NCU **nunca** ha
hablado con un seguidor, su hueco de la caché está a ceros, y la herramienta los
publicaba como si fueran lecturas: el plan de firmware decía **«SoC 0 % —
BATERÍA BAJA»** de equipos cuya batería está al 100 %, y el modo salía como
`OFF`. Ahora esas filas van **en blanco**, y el plan no mira el SoC de una TCU
que no comunica. Cuando la NCU **sí** la ha leído y el dato es viejo, los valores
se quedan —son los últimos de verdad— y la columna *Edad s* dice de cuándo son.

**El plan de firmware es ahora un plan (v11.5)** — decía *«cada tramo es un
CARRIL»* y soltaba los tramos sueltos. Con dos pendientes no consecutivas de la
misma NCU eso daba dos filas CARRIL idénticas a las dos filas TCU de debajo, y
una de ellas ponía «2 TCUs ~ 0,7 h» en una fila cuya columna TCUs decía **1**
(el 1 era del tramo y el 2 del carril: ciertos los dos, contradictorios en la
misma línea).

Ahora el plan sale por **ventanas del updater** — una por NCU + gateway, que es
lo que se puede abrir a la vez — y dice lo que hay que hacer:

```
PLAN: abre 3 ventanas del updater a la vez. 116 TCUs pendientes.
  Ventana 1: NCU1  192.168.4.10  puerto 503  ->  Add from...to: 1-56    (56 TCUs, ~18,7 h (2,3 dias de 8 h))
  Ventana 2: NCU1  192.168.4.10  puerto 504  ->  Add from...to: 57-108  (52 TCUs, ~17,3 h (2,2 dias de 8 h))
  Ventana 3: NCU2  192.168.4.20  puerto 503  ->  Add from...to: 5-12    (8 TCUs, ~2,7 h)
TOTAL: ~18,7 h (2,3 dias de 8 h) con las 3 ventanas abiertas a la vez, que lo marca
la ventana 1 (NCU1/GW503). Una detras de otra serian ~38,7 h (4,8 dias de 8 h).
```

Van ordenadas **de más a menos carga**: la primera es la que marca el reloj y es
la que hay que arrancar antes. En la tabla, cada ventana lleva debajo sus rangos
(solo si tiene más de uno — con uno solo la propia fila ya lo dice) y las TCUs de
esa ventana con su versión y su SoC. Y el CSV que te llevas es el de ventanas.

Con una sola ventana el texto va en singular y no compara nada: *«TOTAL: ~40 min
en esa única ventana»*. Antes la ventana decía 42 min y el total 40 para las
mismas dos TCUs, porque las horas se redondeaban dos veces.

**El equipo dice si está cargando (v11.4)** — hasta ahora había que deducirlo
de las corrientes: si entra corriente y la batería no la coge, aviso. El bloque
compacto de 22 registros por TCU no trae más, pero el mapa **R7.1** de la NCU
documenta otro bloque, largo, de 50 registros por TCU en
`50000 + (TCU-1)*50`, y sus offsets **29** y **31** son el estado del cargador y
sus alarmas.

El botón **LEER CARGA** de la pestaña Baterías pide esos registros —una petición
corta por TCU, solo cuando se pulsa— y rellena la columna **Carga** con lo que
contesta el equipo: `cargando`, `batería llena`, `cargador NO habilitado`,
`sin energía para cargar`, o la alarma si la hay (`SOBRECORRIENTE DE CARGA`,
`TIMEOUT DE CARGA`, `fallo de com con el BQ`…). Una alarma tapa el estado: es lo
que hay que mirar. En el JSON van además los registros crudos, por si hay que
discutirlos con fábrica.

**Aviso**: ese bloque está en el mapa, pero **no está comprobado contra una NCU
real**. Si ninguna contesta, la consola lo dice en vez de callarse.

**Pestaña Baterías (v11.3)** — las variables de batería estaban repartidas por
columnas del diagnóstico y por el CSV, sin un sitio donde verlas juntas. Ahora
tienen el suyo, igual que el inventario tiene el de FW, serie y MAC:

| NCU | TCU | SoC % | SoH % | Vbat mV | Ibat mA | Vpanel mV | Ient mA | Tbat C | Tpcb C | Día | Carga | Estado |
|---|---|---|---|---|---|---|---|---|---|---|---|---|

**VER BATERÍAS no lee nada**: son las mismas medidas del último diagnóstico,
puestas en tabla (la única lectura nueva de la pestaña es LEER CARGA). Con sus filtros por columna, su CSV y su JSON. La columna **Estado** sale
de la auditoría, para que no haya dos criterios distintos diciendo si una
batería está bien.

**Y el modo directo ya trae el panel (v11.3)** — dije que el mapa de la TCU no
documentaba esos registros y era falso: están en `30092 tension_panel` y
`30093 corriente_panel`. El diagnóstico directo lee ahora `30091..30098` de un
tirón —bus, panel (V e I), batería (V e I), SoC/SoH y las dos temperaturas— en
la misma petición que antes leía cinco. Las de motor sí se quedan vacías: esas
no están en el mapa de la TCU.

**Cuatro correcciones de campo (v11.2)**

- **La barra de avance se quedaba en 0** durante todo el barrido en paralelo.
  `EndInvoke` en orden bloqueaba hasta el final; ahora las NCUs se recogen según
  van acabando y cada una avisa, así que la barra sube de NCU en NCU.
- **De noche la auditoría de baterías marcaba media planta.** Con el sol puesto
  todos los paneles están a 0 V, y salían seis `PANEL SIN TENSIÓN` de TCUs
  sanas. El bit 7 del MSR dice si es de día; sin él —o si no se sabe— no se
  miran ni el panel ni la corriente de entrada ni el `NO CARGA`.
- **El resumen de baterías mezclaba unidades**: *«6 de 705 TCUs»* seguido de un
  reparto que sumaba 10. Son TCUs y avisos; una TCU puede tener tres cosas a la
  vez. Ahora lo dice: *«6 TCUs con algo que mirar, 10 avisos en total»*.
- **`Escribir…` de la auditoría ponía un rango** de la primera TCU a la última,
  y con TCUs sueltas eso escribe también sobre las buenas de en medio. Ahora el
  rango solo se usa si son un **tramo seguido de una NCU**; si hay huecos, o si
  son de varias NCUs, deja hecho un **CSV por TCU** en `correcciones/` con las
  TCUs exactas y te manda cargarlo.

**Las HSUs que faltan también salen en la tabla (v11.2)** — no aparecer no es
información. Si la topología dice que una NCU lleva una estación y la caché no
la trae, sale su fila en gris: *«la NCU no la tiene en su caché: nunca ha
comunicado con ella»*, o *«la NCU no contesta en el puerto 502»* si es eso. No
entran en el desplegable —no se puede operar con lo que no responde— ni cuentan
como encontradas.

**Panel y corriente de entrada (v11.1)** — el bloque compat de la NCU ya traía
cuatro registros que no se leían: **tensión de panel** (offset 5), **corriente de
entrada** (12, con signo) y las dos de **motor** (8 y 9). Salen gratis, en la
misma lectura.

Con ellos la auditoría de baterías separa dos cosas que antes eran un genérico
*«NO CARGA»* y mandan a mirar sitios distintos: **el panel no da** (`PANEL SIN
TENSIÓN`) y **el panel da pero no llega** (`NO ENTRA CORRIENTE`). Solo se miran
con la batería a medias: de noche, o con la batería llena, un panel a 0 V es lo
normal.

Los cuatro van también al CSV del registrador. En el diagnóstico **directo**
salen vacíos: el mapa de la TCU no los documenta donde el de la NCU sí, y antes
que inventar direcciones se dejan en blanco.

**Cada bloque con su tabla de bits (v11.0)** — el bloque compat de la NCU
(30500+) lleva **su propio mapa**, no el de la TCU. Coinciden en casi todos los
bits, pero no en todos, y se estaba decodificando con la tabla de la TCU: donde
la NCU dice `Reserved`, salía una alarma inventada.

| registro | bit | mapa TCU | mapa NCU compat |
|---|---|---|---|
| Alarms1 | 6 | sensor T batería desconectado | *no existe* |
| Alarms1 | 9 | params com por defecto | *no existe* |
| Alarms1 | 10 | batería desconectada | `Reserved` |
| Alarms2 | 12 | com con NCU perdida | `Reserved` |
| Alarms2 | 15 | fallo en driver de motor | *no existe* |

Así aparecía **«com con NCU perdida»** en TCUs que estaban comunicando en ese
mismo momento, con su edad en 10 s. Ahora el modo *via NCU* usa
`$BITS_AL1_NCU`/`$BITS_AL2_NCU` —sacadas de `NCU_Modbus_Map_R7_1`, hoja *TCU
Compat*— y el modo directo sigue con las de la TCU. La máscara de alarma crítica
también se separa: el bit 15 (driver de motor) no existe en el mapa de la NCU.

**Efecto en la auditoría de baterías:** el texto *«la TCU declara batería
desconectada»* solo puede salir del diagnóstico **directo**. En *via NCU* la
detección recae en la tensión (`< 15 000 mV`), que la caché sí trae.

**Corregido en v10.7: el número del hueco no es un índice de la NCU.** La caché
numera los huecos con la numeración de **la planta entera** — en Ayora la NCU 15
tiene sus dos estaciones en los huecos **8 y 9**, y la NCU 16 la suya en el
**10**—, así que usar ese número como índice de la lista de esclavos se salía
del rango y las dos de la NCU 15 acababan con el mismo. Ahora va por **orden de
aparición** dentro de la NCU: la primera que sale, el primer esclavo.

Y el aviso de las que faltan sube al **rótulo de la pestaña**, en rojo: *«8 HSUs
encontradas»* a secas no deja ver que faltan dos, y la consola se pierde de
vista.

**Cada HSU con su esclavo (v10.6)** — una NCU puede llevar **más de una**
estación, y cada una tiene su número de esclavo Modbus. En Ayora son todas la
**230** menos la segunda de la **NCU 15**, que es la **231**. La topología lo
lleva como lista, en el orden de los huecos `HSU1`, `HSU2`… de la caché de la
NCU:

```json
{ "nombre": "Ayora NCU15", "hsus": 2, "hsu_esclavos": [230, 231] }
```

Al elegir una HSU en el desplegable se fija **su** esclavo, no el de la NCU. El
campo antiguo `hsu_esclavo` (un solo número) se sigue leyendo.

Como el Excel maestro todavía no trae esa columna, **regenerar no los borra**:
`make_plantas.py` conserva los que ya tenga el JSON y lo dice por consola. En
cuanto la hoja tenga una columna **HSU esclavo** —admite `230` o `230,231`—
manda la hoja.

**BUSCAR HSUs dice si falta alguna (v10.5)** — encontrar nueve no significa nada
si no sabes que hay diez. La columna **RSU** del Excel maestro (una por gateway)
ya dice cuántas estaciones lleva cada NCU, así que ahora se cuenta y viaja al
JSON como `hsus`. Al terminar el barrido, la toolbox compara:

```
FALTAN HSUs: la topologia espera 10 y no salen todas en NCU15 (1 de 2).
O no estan dadas de alta en esa NCU, o no comunican.
```

Y al revés, si aparecen más de las declaradas, dice que hay que actualizar la
columna RSU. Sin dato de topología no se inventa nada: se calla.

**Ojo con las filas de continuación**: una NCU con **dos** estaciones ocupa dos
filas en el Excel, y la segunda solo lleva el número de RSU, sin NCU ni IP. En
Ayora es el caso de la **NCU 15** (RSU 8 y 9). El generador las suma a la NCU de
arriba; antes se saltaba esa fila entera y se perdía una de las diez.

**Y las TCUs que fallan por los dos lados (v10.9)** — una TCU puede tener
desviaciones **y** variables sin respuesta a la vez. Contaba solo como *sin
respuesta*, su línea de «N desviaciones» no se imprimía… pero sus filas
`DESVIACION` sí estaban en la tabla. De ahí salía un resumen que no cuadraba
consigo mismo: *«3 TCUs con desviaciones»* con **6** desviaciones listadas.

Ahora su línea sale igual —`TCU 43  2 desviaciones (y 3 variables sin
respuesta)`— y el resumen lo dice sin romper la suma:

```
8 TCUs sin respuesta (de esas, 2 con desviaciones ademas)
```

**El resumen de la auditoría mezclaba unidades (v10.3)** — decía
`0 con desviaciones. 5 filas listadas.` y parecía contradecirse. No lo era: lo
primero son **TCUs** y lo segundo **variables**, y esas cinco filas eran de
*sin respuesta*, no desviaciones. Ahora dice de qué son:

```
Auditoria: 62 TCUs conformes | 0 TCUs con desviaciones | 1 TCU sin respuesta.
En la tabla: 5 filas (5 sin respuesta), una por variable.
```

Y la línea de **descolocación** —la comparación que falla pero al releer da el
valor del preset— dice ahora explícitamente que **no está en la tabla ni cuenta
como desviación**, porque salía justo encima de las desviaciones de otra TCU y
se leía como si se estuviera desdiciendo de ellas.

**De la auditoría a escribir (v10.8)** — la auditoría deja una lista de TCUs con
desviaciones, que son **exactamente** las que hay que reescribir; pero había que
apuntarlas a mano y teclear el rango en *Escribir*. El botón **Escribir…** lo
prepara: el preset de referencia en la tabla y el rango de las que fallaron, y
te lleva allí. Como el resto, **prepara y no escribe**: pulsas tú.

Dos avisos que da al preparar, porque el rango va de la primera a la última:

- si dentro caen TCUs que estaban bien, lo dice — reescribirles el mismo preset
  no las rompe, pero conviene saberlo; para tocar solo las malas está
  **CSV por TCU…**
- si son de **varias NCUs**, el rango no vale para todas: una NCU cada vez, o
  CSV con columna NCU

**Ojo, no confundir con *Cierre*:** ahí solo entran las TCUs que se han
**actualizado de firmware**, y la auditoría lo único que hace es marcarles los
parámetros como OK o NOK. Una TCU con desviaciones que no se ha actualizado no
tiene por qué estar en esa lista.

**Auditar sin volver a leer (v9.1)** — la auditoría hacía **siempre** su propia
pasada, así que venir de un barrido y auditar era recorrer la planta dos veces
para los mismos datos. Con la casilla **Usar la última lectura**, lo que ya se
leyó en la sesión no se vuelve a pedir; lo que falte, se lee. Al terminar dice
cuántos valores salieron de la lectura sin tocar la planta.

**Y la pestaña *Flota* pasa a llamarse *Auditoría*** — que es lo que se hace ahí.
El inventario sigue dentro, y Ctrl+K lo encuentra por su nombre.

**Cargar preset en *Leer variable* (v10.0)** — el preset ya dice qué variables
importan; teclearlas otra vez para leerlas sobraba. **Cargar preset…** las mete
en la tabla de lectura, sin valores: para leer solo importa **qué** se lee.
Acepta los dos formatos que ya se guardan —la lista suelta y el backup completo
de una TCU—, avisa de las que no están en el mapa en vez de dejarlas como filas
muertas, y no duplica una variable repetida en el preset. Si la tabla ya tenía
variables puestas a mano, pregunta antes de reemplazarlas.

Hasta ahora esto solo se podía hacer desde *Auditoría* → **Leer variables**, que
sigue estando: aquel además trae el rango de la auditoría y te lleva de vuelta.

**Auditoría de baterías (v9.7)** — botón **BATERÍAS** en *Diagnóstico*. No lee
nada: la tensión, la corriente, el SoC, el SoH y las temperaturas ya vienen del
diagnóstico, así que la auditoría es instantánea y se puede repetir sobre el
mismo barrido. Saca una fila por problema, con su gravedad:

| Tipo | Qué significa |
|---|---|
| `SIN BATERÍA` (ALARMA) | la TCU declara batería desconectada, o la tensión está por debajo de 15 V: no hay batería útil. Es la que deja el bootloader esperando y el firmware a medio instalar |
| `SOBRETENSIÓN` (ALARMA) | por encima de 30 V en un sistema de 24 V: cargador o medida mal |
| `TENSIÓN BAJA` (AVISO) | por debajo de 22 V: descargada de verdad |
| `SALUD BAJA` (AVISO) | SoH por debajo del 60 %: la batería ya no aguanta |
| `CARGA BAJA` (AVISO) | SoC por debajo del 40 % — por debajo del mínimo del bootloader no se puede actualizar |
| `NO CARGA` (AVISO) | corriente casi nula con la batería a medias: panel, fusible o cargador |
| `TEMPERATURA` (AVISO) | por encima de 55 °C o por debajo de −20 °C |
| `PANEL SIN TENSIÓN` (AVISO) | el panel está por debajo de 2 V con la batería a medias: panel, cableado o fusible |
| `NO ENTRA CORRIENTE` (AVISO) | el panel da tensión pero entran menos de 30 mA: da y no llega |
| `FUERA DE LA FLOTA` (AVISO) | está *dentro* de rango pero se sale de lo que tienen las demás (más de 3 V o 30 puntos de SoC por debajo de la mediana) |

La última es la que encuentra lo que ningún umbral fijo ve: con 754 medidas del
mismo día y el mismo sol, la mediana de la flota es mejor referencia que
cualquier número puesto a mano, y aguanta que haya unas cuantas TCUs mal sin
moverse. Las OFFLINE y la fila de la propia NCU no entran, porque no tienen
medida que valga. El resultado sale también en el informe HTML, con sus filtros.

**El modo también se lee (v9.6)** — en PEM se podía **aplicar** un modo pero no
**ver** en cuál estaban, que es justo lo que hace falta antes de aplicarlo a un
rango. Y no costaba nada: el modo (bits 9:8) y el estado de comisionado (bits
4:3) viven en el **mismo registro 30001** que ya leía *LEER ESTADO*. Ahora ese
botón —**ESTADO Y MODO**— saca los dos, con su reparto en el resumen
(`40 COMISIONADO | 40 modo AUTO | 2 modo MANUAL`), sin una sola lectura de más.

El diagnóstico pasa a usar la misma función para decodificarlo, para que no haya
dos sitios distintos diciendo qué modo tiene una TCU.

**La auditoría prepara la lectura (v9.5)** — botón **Leer variables**: carga en
*Leer variable* las variables del preset de referencia y el rango de la
auditoría, y te lleva allí. Luego se vuelve con **Usar la última lectura**
marcado y la auditoría compara contra esos datos sin tocar la planta otra vez.

No es un atajo: leer por *Leer variable* trae tres cosas que la auditoría no
tiene por su cuenta — la **segunda lectura de los valores anómalos**, el
**resumen de discrepancias** (qué valores hay y en cuántas TCUs) y el **historial
local**. Misma idea que la pestaña Cierre: las pestañas se pasan el trabajo, no
se copian la lógica.

**La edad del dato, a la vista (v9.4)** — en modo *via NCU* no se lee al
seguidor: se lee **lo último que la NCU le oyó**, y cada TCU tiene su propio
retardo según cómo le haya ido en la malla. Eso solo se veía como una nota
cuando pasaba de 90 segundos, así que el resto del tiempo no había forma de
saber de cuándo era lo que se estaba mirando.

Ahora es una **columna, `Edad s`**: los segundos que hace que la NCU habló con
esa TCU. Se puede ordenar por ella y sale en el CSV y en el JSON. Sigue habiendo
aviso de `dato viejo` por encima de 90 s y `OFFLINE` por encima de 5 minutos,
pero ya no hace falta llegar ahí para saber cuánto retardo llevas.

Cuando hace falta la posición real al segundo —comprobar si un seguidor está
llegando o está atascado— hay que desmarcar *via NCU*: eso pregunta a la TCU,
sin caché de por medio.

**Barra de avance (v9.3)** — las operaciones largas no decían por dónde iban.
Ahora, abajo, una barra con **cuántas van, el porcentaje y lo que queda**
(`1240/3770 33% ~4 min`), en *Leer variable*, *Escribir*, *CSV por TCU*,
*Diagnóstico*, *Inventario* y *Auditoría*. La estimación no aparece hasta tener
ritmo suficiente para no mentir, y la barra comparte sitio con el aviso del log,
así que la ventana no crece. Se apaga sola aunque la operación falle o se cancele.

**El reloj de la NCU solo se menciona si está mal (v9.3)** — salía **siempre** en
la columna de alarmas (`reloj NCU: 2026-08-06 12:04:37 UTC`) al lado de las
alarmas de verdad, y parecía un problema cuando no lo era. Ahora solo aparece si
se desvía más de 2 minutos de la hora del PC, y entonces dice cuánto:
`RELOJ NCU DESVIADO 10 min`. Importa porque la caja negra de las HSU y el
registrador del SAT se fechan con ese reloj.

**Y el menú de ordenar dice lo que hace (v9.3)** — ofrecía «A-Z» hasta en
columnas de números. Ahora mira lo que hay en la columna: «de menor a mayor» si
son números, «A-Z» si son texto.

## Pestaña Cierre (v9.2)

Una TCU **actualizada no está terminada**: le faltan los parámetros (la
actualización puede llevárselos), guardarlos en NVM y volver a AUTO. Nada llevaba
la cuenta, y por eso se olvidaban.

La pestaña **Cierre** es esa cuenta. Cada TCU que `VERIFICAR TRAS ACTUALIZAR`
confirma en la versión objetivo entra en la lista, y se va marcando sola con lo
que ya se hace:

| Marca | La pone |
|---|---|
| Parámetros | la **auditoría** contra el preset (OK si esa TCU no tiene desviaciones) |
| NVM | **GUARDAR EN NVM** |
| Modo | el **diagnóstico**, si la TCU está en AUTO |

Mientras quede alguna sin cerrar, el nombre de la pestaña lo dice —`Cierre (3)`—,
sale un aviso en consola al arrancar y un recuadro en la portada del informe.

**La pestaña no escribe nada.** Sus dos botones **preparan**: dejan *Escribir*
cargado con el preset y el rango de las que faltan, o *PEM* con el rango y el modo
AUTO puestos, y te llevan allí para que pulses tú. La misma idea que el buscador:
te lleva, no dispara. Así no hay lógica de escritura duplicada en dos pestañas.

La lista **sobrevive a cerrar el programa** (`cierre/<planta>.json`) y es una por
planta, que es lo que hace falta cuando la campaña dura días.

**Corregido en v10.2: la TCU 0 fantasma.** Una lista guardada **vacía** volvía
al arrancar como una entrada de nada —NCU en blanco, TCU 0, *«falta parámetros,
NVM, modo AUTO»*— que además no había forma de cerrar, y hacía saltar el aviso de
pendientes todos los días. En PowerShell 5.1 (el del PC de planta)
`ConvertFrom-Json '[]'` devuelve `$null`, y **`@($null)` tiene un elemento, no
cero**: el bucle de carga se creaba una fila con todo vacío. Es la misma trampa
que ya se llevó por delante un recuadro de la portada del informe. Ahora la carga
descarta lo que no traiga una TCU de verdad, y el alta no admite la TCU 0 venga
de donde venga. Si ya tienes la fila fantasma, sale sola al actualizar; y si no,
se quita con **Quitar de la lista**.

**Añadir a mano (v10.1)** — el firmware se instala con el **updater del
fabricante**, fuera de esta herramienta. Si ese día no se pasa por *Firmware* a
pulsar `VERIFICAR`, lo actualizado no entra en ninguna lista y se pierde igual
que antes. **Añadir TCUs…** las apunta a mano: NCU y una lista de TCUs (`26`,
`26,39`, `11-14,20` — el mismo formato que el filtro de NCUs del diagnóstico).
Entran con lo mismo que les faltaba a las otras (parámetros, NVM, modo AUTO) y
se van marcando solas igual.

**Corregido en v9.8:** el alta nunca llegaba a ejecutarse. `VERIFICAR TRAS
ACTUALIZAR` marcaba la TCU en verde en su tabla, pero no la metía en la lista de
cierre, así que la pestaña salía siempre vacía y no avisaba de nada. Las pruebas
no lo cogieron porque ejercitaban la **función** de alta, no el **camino** que
tenía que llamarla. Ahora hay comprobaciones estáticas de que `VERIFICAR` llama
al alta, y solo en la rama de «ACTUALIZADA».

## v9.0 — seis cosas de golpe

**Buscador de acciones (Ctrl+K, o el botón *Buscar*)** — hay 80 acciones en 10
pestañas y la herramienta tiene más capacidad que superficie: se preguntaba por
botones que ya existían. Escribe dos palabras («csv flota», «nvm», «caja negra»),
sin acentos si quieres, y te lleva a la pestaña con el botón marcado. **No lo
pulsa**: la mitad escriben en equipos, y un buscador que dispara acciones por
accidente es peor que no tenerlo.

**Barridos de planta en paralelo** — un diagnóstico de 754 TCUs por el bloque
compacto tardaba cerca de una hora, y sin embargo cada NCU es una conexión TCP
independiente que no compite con las demás. Ahora van **hasta 8 a la vez** y esa
hora son minutos. Cada hilo se lleva una copia de la lógica del script y con ella
**su propio estado de conexión** — compartirlo sería volver a mezclar respuestas,
que es justo el fallo que costó una noche entera. Se desmarca *en paralelo* y
vuelve al modo de siempre.

**SIMULAR antes de escribir** — cruza lo que vas a escribir con la última lectura
y dice, sin tocar nada, cuántas TCUs cambiarían de verdad y **qué valores hay
ahora mismo**: `min_tilt = 30 -> cambian 4, ya lo tienen 6 · ahora mismo: 30 en 6 |
-45 en 4`. Es lo que saca a la luz que media planta tiene otra configuración *a
propósito* antes de escribir 342 seguidores, no después.

**Historial local** — cada *Leer variable* deja constancia en `historial/`, un
fichero por planta y mes. El botón **HISTORIAL LOCAL** de Utilidades enseña solo
los **cambios**: `2026-08-03 NCU9 TCU 34 east_pitch: 6 -> -0,7854`. Contesta
«¿desde cuándo?» sin depender de nada online.

**La topología aprende** — cuando BUSCAR ESCLAVO encuentra las HSUs, ofrece
guardar el número de esclavo en el JSON de la planta y deja puestos el esclavo y
el gateway. No hay que volver a barrer ni editar ficheros a mano.

**Portada del informe** — recuadros de estado arriba del todo: seguidores
operativos, cuántos con alarma o sin comunicación, versiones de firmware en la
flota, TCUs con configuración desviada y valores imposibles. Se calcula con lo
que haya en la sesión; lo que no se haya hecho no sale, en vez de salir en blanco.

**VERIFICAR TRAS ACTUALIZAR dice cuál, y no se calla lo que no mira (v8.4)** —
tenía dos problemas, y el segundo era el grave:

- Decía «1 TCUs ya en v1.6.0» sin decir **cuál**, y la tabla se quedaba igual.
  Ahora cada TCU verificada se nombra en consola y **su fila cambia en la tabla**:
  verde `ACTUALIZADA: ya en v1.6.0`, roja `SIGUE PENDIENTE: en v1.4.3`, gris si no
  respondió. La marca llega también a las filas escondidas por un filtro de
  columna, y solo a la TCU exacta: en un tramo de varias no se puede saber cuál se
  actualizó.
- Con una entrada de **una sola NCU**, los tramos de las demás **se saltaban en
  silencio** y el resumen decía «0 siguen pendientes» como si estuvieran bien,
  cuando ni se habían mirado. Ahora avisa antes de empezar de cuántos tramos y de
  qué NCUs se va a dejar fuera, los cuenta como *sin comprobar* —no como buenos— y
  dice que hay que pasar a *(Planta completa)* para verlas todas.

**El plan de firmware mira la batería (v8.3)** — con el SoC bajo **no se puede
actualizar**: el updater manda el firmware, la TCU lo recibe, y el bootloader se
niega a instalarlo porque no llega a sus umbrales (`42005 soc_min_bootloader` y
`42006 vbat_min_bootloader`). El resultado es que gastas la ventana y no te
enteras hasta que verificas.

Ahora el plan cruza las pendientes con el **último diagnóstico de la sesión** —sin
leer nada más— y enseña el SoC de cada una: `pendiente: tiene v1.4.3, objetivo
v1.6.0, SoC 31 % - BATERIA BAJA`. Las que están por debajo del 50 % salen en rojo,
cada carril dice cuántas de las suyas no van a instalar, y el resumen lo repite en
una línea. Si no hay diagnóstico en la sesión, lo dice en vez de dar por buenas
las baterías que no ha visto.

El 50 % es un aviso conservador: el umbral de verdad es el de cada TCU, que está
en su `42005`.

**Las cabeceras se ven pulsables (v8.2)** — el filtro por columna está desde la
v7.4, pero nadie lo encontraba: nada decía que la cabecera se pulsara. Ahora
todas llevan una **▾**, y un **▾\*** cuando esa columna está filtrando. Una prueba
comprueba además que **ninguna** de las tablas se queda sin enganchar, para que
una tabla nueva no nazca sin filtro.

**Parte de averías para WhatsApp (v8.2)** — los técnicos de campo no leen un CSV
en el móvil. El botón **COPIAR NO-OK** del diagnóstico deja en el portapapeles un
listado en texto plano, agrupado por NCU y con solo lo que no está OK:

```
Ayora - 06/08/2026 04:15
NO OK: 5 de 754 equipos revisados.

*NCU 1* (3)
- La NCU: AVISO - reloj NCU: 2026-08-06 04:10
- TCU 14: ALARMA - eje bloqueado
- TCU 22: AVISO - SoC bajo (L1)

*NCU 3* (2)
- TCU 9: OFFLINE
- HSU2: ALARMA - ALARMA VIENTO
```

Respeta el filtro **Ver NCU** de al lado, así que con el mismo botón sacas el
parte general o el de una NCU concreta para mandárselo a quien está en ella. Sin
tablas, que en el móvil se descuadran. Además del portapapeles se vuelca en la
consola, por si el portapapeles falla.

**Qué TCUs faltan por actualizar (v8.1)** — el plan de firmware agrupaba las
pendientes en **tramos** (`NCU + gateway + desde-hasta`), que es lo que se pega en
el updater, pero no decía qué equipos concretos faltaban ni en qué versión
estaban. Ahora, además de los tramos, lista **una fila por TCU pendiente** con su
versión actual (`pendiente: tiene v1.4.3, objetivo v1.6.0`) y en consola sale el
reparto por versión (`42 en v1.4.3 | 3 en v1.5.1`). El CSV saca un segundo
fichero `_pendientes.csv` con esa lista, que es la que sirve para el seguimiento.

**Corregido en v9.9:** esas dos clases de fila convivían en la misma tabla sin
decir cuál era cuál, y cuando un carril tiene **una sola TCU** salían idénticas
columna a columna (misma NCU, mismo gateway, mismo desde-hasta, mismo 1) —
parecía la misma TCU repetida. Ahora una columna **Fila** dice qué es cada una
(`CARRIL`, `TCU`, `SIN RESPUESTA` — en la v11.5 pasaron a `VENTANA`, `PEGAR`,
`TCU` y `SIN RESPUESTA`), y sirve además de filtro para quedarse solo
con las pendientes. `VERIFICAR TRAS ACTUALIZAR` tampoco repinta ya la fila del
carril: con un carril de una TCU le borraba su reparto de horas.

**«No contesta» no es lo mismo que «rechaza» (v8.1)** — un fallo de conexión TCP
decía solo `Sin conexion TCP a 192.168.4.10:502`. Ahora distingue los dos casos,
que llevan a sitios opuestos: **no contesta en 5 s** es equipo apagado, IP mal o
puerto filtrado; **conexión rechazada** es un equipo vivo que no tiene nada
escuchando en ese puerto, o que ya tiene la única conexión cogida por otro
programa (el updater, típicamente).

**Y `via NCU` deja de inventarse OFFLINEs (v8.1)** — si la NCU no contesta en el
puerto 502, no sabemos nada de sus TCUs; pintarlas todas como OFFLINE es mentira
y llena la tabla de ruido. Ahora se dice una vez, con el número de TCUs afectadas
y qué hacer (desmarcar *via NCU* para preguntarles una a una por el gateway).

**El alta de usuarios no guardaba nada (v8.0)** — fallo de la v7.4, y de los
buenos: creabas el administrador, la ventana se cerraba y no pasaba nada; al
volver a abrir, te lo pedía otra vez.

La causa es una trampa de PowerShell: **`.GetNewClosure()` mete el bloque en un
módulo propio**, así que el `$script:UsrNuevo = ...` que escribía el botón *Crear*
no era el mismo que leía la función. Devolvía `$null`, el arranque hacía `return`
sin decir nada y nunca se llegaba a guardar. Lo mismo le pasaba al diálogo de
gestión: cada botón tenía **su propia copia** de la lista de usuarios, así que dar
de alta y luego dar de baja no veía lo anterior.

Ahora el resultado viaja en una hashtable capturada — un objeto, y mutarlo
funciona en cualquier ámbito. Y por si acaso, tras crear el administrador se
**vuelve a leer el fichero del disco**: si la carpeta no deja escribir (Archivos
de programa, unidad de red de solo lectura) lo dice con la ruta y qué hacer, en
vez de fallar en silencio.

Hay pruebas del viaje completo (crear → guardar → releer del disco → entrar con
esa contraseña) y del propio comportamiento de `GetNewClosure`, para que la
trampa no vuelva a colarse.

Y las contraseñas se escriben con **ñ**.

**Una tabla vacía tiene que decir por qué (v7.9)** — la auditoría de Flota lista
solo las desviaciones, así que cuando todo está bien la tabla se queda vacía y
parece que no ha hecho nada. Ahora deja una fila diciéndolo: *«Sin desviaciones:
3 TCUs conformes — las 5 variables de preset_tcu.json coinciden en todas»*, y si
se canceló antes de leer nada, lo dice también en vez de fingir conformidad. La
fila es informativa: no entra en el CSV ni en el JSON de la auditoría.

**Botón Limpiar en la consola (v7.8)** — vaciar la consola estaba solo en el menú
del botón derecho, que no se ve, así que en la práctica no existía. Ahora hay un
botón al lado de *Guardar log*. **No toca el log de fichero**: ahí sigue todo, que
es lo que vale para reconstruir una jornada, y al limpiar lo recuerda con la ruta.

**El límite de recorrido no es una avería (v7.7)** — el TEST DE MOTOR daba
`DUDOSO: movimiento asimétrico` en las TCUs que estaban pegadas a su límite. Es
lo esperable: un seguidor a 0,1° del tope este no puede moverse más al este, así
que el pulso hacia ese lado no produce nada.

La clave para distinguirlo estaba ya en el dato y no se usaba: **la corriente de
motor**. Si no hay movimiento y **tampoco corriente**, el controlador ni siquiera
activó el motor, que es justo lo que hace al llegar al límite. Si hay corriente y
no se mueve, ahí sí hay algo atascado.

Ahora una TCU que se mueve bien en un sentido y en el otro se queda a 0 mA
**PASA**, con la nota de que solo se pudo probar un sentido, y el resumen dice
cuántas fueron así. Un fallo mecánico de verdad —corriente sin movimiento— sigue
siendo FALLA, y ahora lo dice con esas palabras en vez de «asimétrico». El
detalle incluye además la inclinación de partida, que es lo que da contexto.

**Los límites de inclinación no tienen signo fijo (v7.6)** — el rango de cordura
de `min_tilt_east` estaba puesto como -90..0 dando por hecho que el límite este
tenía que ser negativo. No es así: en Ayora la configuración buena lleva
`min_tilt_east = +30`, o sea que el seguidor trabaja entre +30 y +55. Con aquel
rango, una planta entera salía como «valor imposible». Ahora los dos límites
admiten -90..90.

Lo que sí es una regla de verdad es la **relación entre los dos**: el límite este
tiene que quedar **por debajo** del oeste, o el seguidor no tiene recorrido. Eso
es lo que caza ahora el corrimiento de registros — una TCU con `min_tilt = 55`
pasa cualquier rango por separado, pero tener el mismo valor en los dos límites
no se sostiene. El CSV de corrección recoge también estas, proponiendo el valor
mayoritario de la planta.

**Rótulos que dicen la verdad (v7.5)** — tres cosas que despistaban al trabajar
contra una sola NCU o una sola TCU:

- La **columna NCU** salía vacía, y la consola tampoco decía de qué NCU era cada
  TCU, porque el número solo se conocía recorriendo la planta. Ahora se saca del
  nombre de la entrada de conexión: *Ayora NCU3* → NCU 3.
- Pedir una TCU y leer «**todas coinciden = 55**» cuando solo hay una. Con un
  único equipo el resumen dice `41111 max_tilt_west_r1 [deg] = 55` y ya está, y
  los rótulos de rango ponen `TCU 16` en vez de `TCUs 16-16`.
- El recuento del diagnóstico **sumaba las HSUs con las TCUs**: pedías un
  seguidor y salía `OK: 2` porque la meteo de esa NCU va en la misma tabla (a
  propósito: es lo que decide si la NCU abandera entera). Ahora van separados,
  `TCUs -> OK: 1 ... | HSUs: 1 (1 OK)`.

## Usuarios y roles (v7.4)

El arranque pide **usuario y contraseña**, siempre. El primer arranque no tiene
usuarios, así que obliga a crear el **administrador** antes de dejar entrar a
nadie; a partir de ahí las altas se hacen desde el botón **Usuarios...** de la
barra de abajo.

Las contraseñas no se guardan: en `usuarios.json` va un **PBKDF2 con sal propia
por usuario** (100.000 iteraciones). Tres roles:

| Rol | Puede |
|---|---|
| **lectura** | Diagnóstico, lecturas, informes y SAT. No escribe nada. |
| **técnico** | Todo lo anterior + escribir variables, presets, NVM, movimientos del seguidor y firmware. |
| **admin** | Todo + identidad de red, topología y gestión de usuarios. |

Y lo que le da sentido: **el registro de acciones**. Cada escritura deja una
línea en `registro/acciones_AAAAMM.csv` con fecha, usuario, rol, planta, NCU,
TCU, y el valor **antes y después**. Es lo que contesta el día que alguien
pregunta quién cambió el `min_tilt` de la NCU 11. El campo «Técnico» de los
informes HTML pasa también a ser el usuario de la sesión, no el de Windows.

**Lo que esto NO es: protección.** Un `.ps1` es texto plano y quien sepa abrirlo
se pone administrador en treinta segundos. Es una barrera contra el **error** —el
ayudante que le da a «escribir planta completa» sin saber qué hace— y, sobre
todo, **trazabilidad**. Para lo otro hace falta licencia y marca de agua, que es
otra conversación.

**Filtros en las tablas de resultados (v7.4)** — pulsando la **cabecera de una
columna** se abre un menú con los valores distintos de esa columna y sus
recuentos, para marcar varios a la vez, más ordenar A-Z / Z-A (con orden
numérico cuando la columna son números, así que la TCU 10 ya no va delante de la
9) y copiar al portapapeles lo que se ve. Las columnas filtradas se marcan con
`*`. Funciona en las diez tablas de la herramienta y sin mover un píxel del
diseño: en estas pestañas no sobra sitio para una fila de filtros como la del
informe HTML.

**Corregido en v9.9:** un menú de Windows se cierra al primer clic, así que solo
se podía marcar o desmarcar **una** casilla por apertura — para dejar un valor de
cinco había que abrir el menú cuatro veces, y desde fuera parece que no deja
quitar las casillas. Ahora el menú **se queda abierto** mientras se marca y se
desmarca, el filtro se aplica al vuelo (la tabla se actualiza debajo) y hay
**Marcar todos** / **Desmarcar todos** para no ir una a una. Lo cierran las
opciones que terminan —ordenar, quitar filtros, copiar—, un clic fuera, `Esc` o
la entrada **Cerrar**.

**BUSCAR ESCLAVO (v7.4)** — la caché de la NCU dice **cuántas** HSUs hay y cómo
están, pero no su número de esclavo Modbus, que es lo que hace falta para
hablar con ellas directamente. Este botón lo busca: por cada gateway de la NCU
pide el `Product ID` (30300) a cada esclavo y apunta los que contestan, con su
tipo (TCU/HSU). Empieza por los sospechosos —el que haya puesto, 185, 200,
247…— para que un barrido interrumpido ya suela haber encontrado algo. Además,
elegir una HSU en el desplegable **fija ya su puerto de gateway**: antes dejaba
`auto` y la siguiente operación moría con *«puerto 'auto' requiere una entrada
(auto) seleccionada»*.

**Aviso cuando el navegador bloquea el JavaScript (v7.3)** — la fila de filtros de las tablas del informe la monta el JavaScript al abrir la página: tiene que ser así, porque el filtrado y la ordenación también son JavaScript. En el PC de planta el navegador bloquea por defecto los scripts de los ficheros locales (la barra de *«Internet Explorer ha restringido la ejecución de scripts»*), y entonces las tablas salen sin filtros y el informe parece roto. Ahora el HTML lleva un aviso arriba explicando qué pasa y qué pulsar; **el propio JavaScript lo borra nada más arrancar**, así que solo lo ve quien tiene el problema.

**Segunda lectura de los valores anómalos (v7.2)** — el guardarraíl de la v5.0 tiene un hueco que se ha visto en campo: comprueba que el código de función y el número de registros de la respuesta son los que se pidieron, y eso caza casi todo, pero **no dos lecturas de la misma forma seguidas**. Dos `FC03` de un registro (`41068` y `41069`, por ejemplo) son peticiones idénticas en tamaño, así que si la NCU contesta con el cuerpo de la anterior sellado con el identificador de la petición en curso, cuadra todo y se cuela. En Ayora salió así un `safe_pos_sign_threshold = 2560`, que es exactamente el `0x0A00` del registro de al lado — y al releer esa misma TCU, el valor era el correcto.

Ahora, en **Leer variable**, todo valor que sea **imposible para su variable** o que **no lo tenga ninguna de las TCUs leídas hasta ese momento** se lee una segunda vez **con la conexión rehecha**: una respuesta descolocada no puede repetirse en un socket limpio, así que si el valor se confirma es real. Si las dos lecturas no coinciden hay una tercera para desempatar, y si las tres discrepan la celda se marca como fallo en vez de enseñar un número en el que no se puede confiar. Al final sale el recuento: cuántos se comprobaron, cuántos se confirmaron y **cuántos eran falsos**. Cuesta unas pocas lecturas de más por planta (en un barrido de 3.500 lecturas fueron 15) y es lo que hace que la lista de anomalías se pueda usar para escribir sin volver a comprobarla a mano.

**CSV de corrección y CSV con columna NCU (v7.2)** — cuando una lectura masiva encuentra valores imposibles, se genera solo un **CSV de corrección** en `correcciones/`, con una fila por celda mala y el **valor mayoritario de la planta** para esa variable. No se inventa nada: si ninguna TCU tiene un valor plausible, o si hay empate entre dos valores, lo dice en consola y no propone. Para aplicarlo, **`CSV por TCU...` admite ahora una columna `NCU`** delante (`NCU;TCU;variable;valor`) y reparte las filas entre las NCUs de la planta, cada una con su IP y sus gateways, en una sola pasada — que es lo que hace falta para corregir equipos sueltos repartidos por varias NCUs, donde los números de TCU se repiten y un CSV sin NCU es ambiguo. El formato de siempre (`TCU;variable;valor`) sigue valiendo contra una NCU concreta; las combinaciones ambiguas (CSV con NCU contra una sola NCU, o CSV sin NCU contra *Planta completa*) se rechazan explicando por qué.

**Valores imposibles y clonado seguro (v7.1)** — dos cosas que salieron de un caso real en Ayora: TCUs con `41106 east_pitch [m]` = **-0,7854**, que es exactamente **-45° en radianes**, o sea el crudo de `min_tilt` metido en el registro de al lado. No es un fallo de lectura (los guardarraíles de la v5.0 lo habrían cazado): esos registros están **escritos así** en el equipo. Ahora la herramienta lo detecta sola:

- **Comprobación de rango por variable.** Cada variable de geometría y de límites de tilt tiene su intervalo físico plausible. Al acabar una **Leer variable**, además del reparto de valores, sale una lista de **VALORES IMPOSIBLES** con la NCU, la TCU, la variable, el valor y el motivo — y si el valor es un ángulo redondo en radianes dentro de un registro en metros, lo dice: *"parece un ángulo en radianes (-0,7854 rad = -45 grados)"*. Va también al **informe HTML** y a la **auditoría de Flota**, donde una desviación que además es imposible se pinta en rojo en vez de en naranja. Esto caza lo que el resumen de discrepancias no ve: un valor puede coincidir en toda la planta y aun así estar mal, y al revés, un valor distinto puede ser legítimo.
- **La identidad de red no se clona.** Un preset es para copiar una configuración de una TCU a otra, pero el **número de esclavo** (`41004`/`41006`), el **PAN ID** (`41070`/`41072`) y la **clave de cifrado** (`41074`/`41075`) son propios de cada equipo: clonarlos deja dos TCUs con el mismo esclavo (una de las dos desaparece de la red) o mete a la TCU en la PAN de otra NCU. Ahora esos registros quedan **fuera de "Guardar preset"**, fuera de **"Backup JSON como preset"** y fuera del **preset de referencia** de la auditoría (donde además darían desviación en todas las TCUs menos en una), siempre diciendo en consola cuáles se han excluido y por qué. Escribirlos sigue siendo posible **de una en una** —hace falta al sustituir una TCU— con confirmación aparte, pero la escritura a un rango o a la planta completa se **bloquea**. Al cargar un preset de referencia también se avisa si el propio preset lleva un valor fuera de rango, porque si el patrón está mal la auditoría da por buenas las TCUs malas.

**Lectura de variables y HSUs rotas (v6.3)** — corregido un fallo que dejaba inservibles dos funciones desde la v5.2 y la v5.3. Las funciones que devuelven una lista lo hacían con `return ,$lista`, y eso hace que el `@(...)` de quien llama se quede con **un solo elemento**: las tres variables elegidas llegaban pegadas en una sola cadena (`no responde: tipo desconocido`) y las HSUs igual (`Leyendo meteo de 1 HSU(s)` con todas las etiquetas juntas). La suite gana una **guarda estática** que falla si alguna función que devuelve con coma se consume con `@()` — comprobado que marca las dos en la v6.2 y ninguna ahora.

**Consola copiable (v6.1)** — el texto de la consola siempre se pudo seleccionar con el ratón y copiar con Ctrl+C, pero cada línea nueva **te robaba la selección**: en una operación larga era imposible copiar nada. Ahora, si hay algo seleccionado, la consola escribe sin tocar la selección ni mover la vista. Y con el **botón derecho** hay menú: Copiar, Seleccionar todo, **Copiar toda la consola** (para pegar un resultado en un correo), Guardar log y Limpiar.

**Etiquetas que tapaban botones (v6.0)** — al maximizar, **TEST COMM** desaparecía: la nota del registrador, que está a su izquierda en la misma fila, es una etiqueta larga y se anclaba a izquierda y derecha, así que se estiraba por encima del botón (y va antes en el z-order, así que lo tapaba). Ahora una etiqueta larga solo se estira si **no tiene nada a su derecha** en la misma franja horizontal.

**Botones tapados al maximizar (v5.7)** — con la ventana maximizada, la tabla de cada pestaña se estiraba hacia abajo y **se comía los controles que van debajo**: el botón **ESCRIBIR**, la casilla de verificación, NVM… La tabla crecía pero los botones seguían anclados arriba. Ahora todo lo que está por debajo de la tabla que crece se ancla al borde inferior y baja con la ventana. La regla de anclaje se ha separado en una función pura (`Anclaje-Para`) que la suite comprueba con la geometría real de cada pestaña, sin abrir una ventana.

**Maquetación de la ventana (v5.1)** — corregida una regresión del tema de la v5.0: los botones pegados al borde derecho (**Añadir** en Leer variable, **LEER**, **Exportar CSV**, **SINCRONIZAR**, **Cargar preset…**) desaparecían, y las tablas quedaban más largas que su pestaña con la barra de desplazamiento por debajo del borde. Los anclajes se calculaban antes de que la ventana estuviera visible, cuando las pestañas que no están seleccionadas todavía no tienen su tamaño definitivo. Ahora se aplican con la ventana ya mostrada, con una guarda que no ancla nada contra un contenedor que no mide lo que debería, y una pasada final que devuelve a su sitio cualquier control que hubiera quedado fuera.

**HSU en Planta completa (v5.1)** — las operaciones directas de HSU (meteo, config, umbrales, reloj, nieve, NVM, caja negra) ya no exigen cambiar la entrada de conexión: si has elegido una HSU en el desplegable de **BUSCAR HSUs**, el programa ya sabe de qué NCU cuelga y usa su IP y el primer gateway de esa NCU, avisando en consola de cuál ha cogido (si cuelga del otro, se pone el puerto a mano).

**Fechas en dd/mm/aaaa (v5.1)** — la fecha de fabricación se pintaba `aa-mm-dd` (`25-06-18`), que se lee como fecha americana. Ahora va como `18/06/2025` en la vista, el CSV, el JSON y el informe.

**Respuestas descolocadas de la NCU (v5.0)** — corregido un fallo de datos serio. Cuando un TCU no contestaba a tiempo, la NCU respondía `GatewayTargetNoResponse` y **después** podía soltar la respuesta tardía del TCU, sellada con el identificador de transacción de la petición que estuviera en curso. Como el identificador cuadraba, la toolbox la daba por buena: a partir de ahí iba **una respuesta por detrás** y cada variable mostraba el valor de la anterior — `41106 east_pitch [m]` con los 0,95993 radianes de `41111 max_tilt` en vez de 6, `min_tilt [deg]` con 343,775 (los 6 m leídos como radianes)… valores plausibles pero falsos, y sin ningún aviso. Ahora, tras cualquier fallo que pueda dejar una trama en camino (timeout, socket roto, o las excepciones de gateway 0x0A/0x0B), la conexión se marca sucia y **se rehace antes de la siguiente petición**, que es la única forma de garantizar que respuesta y petición vuelven a cuadrar. Además, antes de cada petición se vacía lo que hubiera esperando en el socket (con aviso en consola), se comprueba que el código de función de la respuesta es el que se pidió y que trae **exactamente** el número de registros solicitado. Hay prueba de regresión: el simulador reproduce una NCU que va una respuesta por detrás, y sin el arreglo la lectura sale con los valores corridos.

**Aspecto (v5.0)**: la ventana lleva un tema propio — tipografía Segoe UI, fondo claro con los grupos como tarjetas blancas de filete fino, pestañas planas con subrayado azul en la activa, tablas sin cuadrícula con cabecera en versalitas y filas alternas, botones planos (los de acción conservan su color: verde escribir, azul leer, naranja NVM/stow, rojo cancelar) y la consola con la misma paleta oscura que la plataforma web. El tema **solo cambia colores, fuentes y bordes**: no mueve ni un control, así que cada pestaña está donde siempre. Es un tema claro a propósito, porque las filas de las listas se colorean por salud (verde/ámbar/rojo) sobre fondo blanco. Si en algún PC no convence, se vuelve al aspecto anterior añadiendo `"tema": "clasico"` a `config_local.json` — sin tocar el script.

Además, transversales a las pestañas (v3.1):

- **INFORME HTML** (barra inferior): vuelca a un informe HTML autocontenido todo lo hecho en la sesión — **escritura de variables** (v5.9: una fila por TCU y variable con el valor de antes, el de después y el resultado, así que el informe documenta *qué se cambió* y no solo qué se midió), diagnóstico de flota, resultados de PEM, auditoría, inventario y, desde v4.8, la **lectura de variables** de la pestaña *Leer variable* (una columna por variable leída, con el mismo **resumen de discrepancias** que la pestaña: qué variables coinciden en todas las TCUs y cuáles tienen valores distintos y en cuántas TCUs cada uno). Si en la sesión hay **más de una operación**, al pulsar el botón se pregunta si quieres el informe **solo de la última** (un TEST COMM y una verificación de FW seguidos no deberían acabar en el mismo documento) o de toda la sesión (v6.5). El **nombre del fichero dice de qué es** — `informe_Diagnostico_Ayora_…`, `informe_Inventario_…`, `informe_sesion_…` — para que no se líen en la carpeta. Las secciones se pintan **empezando por la última que se ejecutó** (v5.6): si acabas de hacer un inventario, el inventario va arriba aunque en la sesión hubiera un diagnóstico anterior — antes salía siempre el diagnóstico primero y el informe parecía ser de otra cosa. Cuando hay más de una sección, arriba va un **índice** con cada una, su hora y su número de filas. Cada sección lleva además la **hora en que se hizo**, así que se ve de un vistazo qué es de esta sesión y qué venía de antes — antes, si solo se había leído una variable, el informe sacaba el diagnóstico anterior y parecía que ignoraba la lectura. Con metadatos (planta, IP, fecha, técnico, versiones) y filas coloreadas por estado. Cada tabla lleva una **fila de filtros por columna**: donde hay pocos valores distintos, un botón que abre un **panel de casillas para elegir varias opciones a la vez** (v5.5 — p. ej. ALARMA **y** OFFLINE, o dos versiones de FW; ninguna marcada = todas, con atajos "todas"/"ninguna" y el botón resaltado cuando el filtro está activo); donde hay muchos, una caja "contiene". Los filtros de varias columnas se cruzan entre sí, con contador de filas visibles, y **orden con un clic en la cabecera** (numérico o alfabético, con flecha ▲/▼ indicando por qué columna va). Todo en JS embebido: sigue funcionando sin red, y desde v4.2 también en navegadores antiguos (Internet Explorer / Edge en modo compatibilidad), donde antes el script no llegaba a ejecutarse y por eso la ordenación no respondía. Se guarda en `informes/` y se abre solo: el entregable de la jornada de puesta en marcha.
- **Rollback** en escrituras masivas (>3 TCUs, tanto en Escribir como en CSV por TCU), con la casilla **"Copia de seguridad antes de escribir"** marcada por defecto (v6.2): desmarcarla arranca la escritura al instante, porque la copia lee valor a valor antes de tocar nada y en un rango grande eso es lo que hace esperar. La elección se recuerda entre sesiones, pero cuando está desmarcada la **confirmación lo dice cada vez** (`SIN copia de seguridad previa: no se podrá deshacer`) y queda un aviso en la consola, para que no se olvide. Con la casilla marcada, antes de tocar nada se leen los valores actuales y se guardan en `backups/rollback_<fecha>.csv` con formato `TCU;variable;valor` — restaurable tal cual con el botón **CSV por TCU...**. Los registros de comando se excluyen del rollback (reescribirlos relanzaría órdenes). Si el rollback no se puede crear, la toolbox pregunta antes de seguir sin él.
- **Mini-registrador** (Diagnóstico → **BUCLE CSV**): repite el diagnóstico cada X minutos y acumula cada pase (con fecha/hora y las alarmas desglosadas en columnas) en `informes/registro_<fecha>.csv`. Se para con CANCELAR. Para vigilar una TCU intermitente o una tarde de viento sin quedarse mirando.
- **Recordar sesión**: al cerrar se guarda `config_local.json` (planta, IP, puerto, timeout, reintentos, esclavo HSU) y al arrancar se restaura — el PC de planta arranca ya apuntando a su planta.

## Pruebas

`tests/` lleva un simulador Modbus TCP y **325 comprobaciones** de toda la lógica no-GUI, para poder tocar el script sin planta delante:

```bash
cd tests && python3 mb_server.py &
pwsh -NoProfile -File test_toolbox.ps1
```

Entre ellas, la regresión del fallo de las **respuestas descolocadas**: el esclavo 77 del simulador imita una NCU que va una respuesta por detrás, y sin la resincronización la lectura sale con los valores corridos. Detalle en `tests/README.md`.

## Seguimiento PEM (v3.4)

El seguimiento de puesta en marcha de una planta tiene tres piezas:

- **Ficha Excel automática**: `python make_seguimiento.py plantas/<planta>.json` genera `Seguimiento_PEM_<planta>.xlsx` — hoja Resumen con el % de avance por NCU (se calcula sola) y una pestaña por NCU con sus TCUs reales (número y **gateway como GW1/GW2**, no como número de puerto — en campo se habla de gateways; la equivalencia con el puerto TCP queda en la nota de la hoja), las tres tareas por TCU (*Cold commissioning / Configuración TCU / Prueba movimiento*, desplegable OK/NOK/N.A. con colores), HSUs, fecha, técnico y observaciones. La release de GitHub **adjunta una ficha por planta ya generada** (se regeneran solas en cada release).
- **Exportar desde la toolbox**: botón **SEGUIMIENTO JSON** (pestaña PEM). Combina lo medido en la sesión — **LEER ESTADO** de comisionado → *Cold commissioning*, **Auditoría** de Flota → *Configuración TCU*, **TEST DE MOTOR** → *Prueba movimiento* — en un `seguimiento_pem_<planta>_<fecha>.json` con una fila por TCU (OK / NOK / pendiente + observaciones).
- **Subirlo a la plataforma**: ese JSON se sube en la página **Histórico** de factiun-cartera (mismo botón que los diagnósticos): queda guardado por planta con su % de TCUs al 100 % y **diff contra el seguimiento anterior** (qué tareas se completaron o se rompieron entre visitas).

## Vínculo con la plataforma (sin dejar de ser offline)

- **Mismo programa para todas las plantas, un fichero por planta**: el desplegable muestra **solo** las plantas de los ficheros cargados (no hay lista integrada en el script). Al arrancar se cargan todos los JSON/CSV de la subcarpeta `plantas/`, más un `plantas.json`/`plantas.csv` clásicos si existen; el botón **Cargar...** **reemplaza** la lista por las NCUs del fichero que elijas (y ofrece guardarlo en `plantas/` para próximas sesiones) — quita de `plantas/` los ficheros de plantas que no quieras ver. Así el programa nunca cambia por añadir plantas: solo se descargan ficheros. El CSV (separado por `;`, editable desde Excel sin necesitar Office en el PC de campo) usa una fila por gateway:

  ```
  Planta;NCU;IP;Puerto;TCU_ini;TCU_fin
  El Burgo I;NCU1;10.100.1.52;503;1;56
  El Burgo I;NCU1;10.100.1.52;504;57;108
  ```

  La fuente de verdad es el mismo `config/plants.yml` que usa el collector del SCADA: cada NCU declara ahí sus gateways passthrough (clave `gateways`, que el collector ignora):

  ```yaml
  gateways:
    - { puerto: 503, tcu_ini: 1,  tcu_fin: 56 }
    - { puerto: 504, tcu_ini: 57, tcu_fin: 108 }
  ```

  Un workflow de GitHub Actions (`.github/workflows/plantas-toolbox.yml`) regenera y commitea `plantas/<id_planta>.json` automáticamente en cada cambio de `plants.yml`. **No edites esos JSON a mano**: cambia `plants.yml` y deja que se regeneren (o lanza `python make_plantas.py` en local). Cada despliegue del SCADA (una planta) aporta su fichero; en el portátil de campo se pueden acumular los de varias plantas en `plantas/`.

- **Tabla de topología editable (recomendado para el resto de plantas)**: la hoja "Direcciones IP" del Excel maestro vive como tabla web editable en **factiun-cartera** (`ips.html`, "IPs de plantas", mismo login que la cartera). Sus botones **⬇ JSON toolbox** / **⬇ CSV toolbox** descargan los ficheros de plantas en el formato exacto de esta herramienta — solo topología, nunca credenciales. Alternativa offline: `python make_plantas.py --excel <Excel> [--excluir 23003]` lee esa misma hoja y genera `plantas/<nº>-<planta>.json` (⚠️ el Excel lleva contraseñas: **no subirlo nunca a este repo**, que es público; solo los JSON generados).

- **Exportes canónicos**: los backups (`{"tipo":"backup_tcu", ...}`) y diagnósticos (`{"tipo":"diagnostico_tcu", ...}`) llevan planta, IP, TCU, fecha y versión de mapa, de modo que cualquier pieza de la plataforma (SCADA, gemelo, informes) puede ingerirlos sin ambigüedad.

- **Mismo modelo de salud**: la clasificación `ok/warn/alarm/offline` replica la del collector (`collector/decode.py`), así lo que ves en campo con la toolbox coincide con lo que pinta el SCADA en el plano.

Nada de esto requiere conexión: los ficheros viajan en el propio portátil o en un USB.

## Formatos

`plantas.json`:

```json
{ "version": 1, "plantas": [
  { "nombre": "El Burgo I NCU1 GW1", "ip": "10.100.1.52", "puerto": 503, "tcu_ini": 1, "tcu_fin": 56 }
] }
```

Backup (`Volcar TCU → Backup JSON`):

```json
{ "tipo": "backup_tcu", "mapa": "SUNNER v6.1 (FW 1.4.3)", "planta": "El Burgo I NCU1 GW1",
  "ip": "10.100.1.52", "puerto": 503, "tcu": 12, "fecha": "2026-08-04 10:31:00",
  "variables": [ { "variable": "41010 longitud [deg]", "valor": "-1.685", "grupo": "config" } ] }
```

Diagnóstico (`Diagnóstico → JSON`): igual, con `"tipo": "diagnostico_tcu"` y una lista `tcus` con salud, ángulos, batería y alarmas en texto por TCU.

**Todos los JSON de la toolbox se suben al Histórico de la plataforma** (`historico.html` en factiun-cartera), que guarda la evolución por planta en Supabase y calcula el diff contra el registro anterior del mismo tipo (v3.6):

| Tipo | Botón | Diff en la plataforma |
|---|---|---|
| `diagnostico_tcu` | Diagnóstico → JSON | qué TCUs empeoran/mejoran de salud |
| `seguimiento_pem` | PEM → SEGUIMIENTO JSON | qué tareas se completan o se rompen |
| `inventario_tcu` | Flota → Inventario → JSON | cambios de FW y TCUs sustituidas (cambio de nº de serie) |
| `auditoria_tcu` | Flota → Auditoría → JSON | desviaciones nuevas, resueltas y cambiadas (avisa si el preset difiere) |

## Campaña de firmware y captura del protocolo OTA

El firmware de las TCUs lo actualiza el **TCU Updater de Sunner** (Rust + Modbus TCP, GUI sin línea de comandos): pide *NCU IP* y *Gateway port*, reinicia la TCU a bootloader y sube el binario por bloques con CRC32, con reanudación desde dirección. Tarda **~20 min por TCU y va de una en una**, así que una planta grande es inviable en serie (754 TCUs ≈ 250 h).

Lo que aporta la toolbox, sin tocar el firmware:

1. **A quién hay que actualizar**: Inventario → pestaña **Firmware** → plan por NCU y gateway.
2. **Cuántas ventanas lanzar y qué pegar en cada una**: cada NCU + gateway es una red Zigbee distinta, y el updater no tiene bloqueo de instancia única, así que se pueden abrir varias a la vez. El plan da una **ventana** por NCU+gateway, con sus rangos, su tiempo y el total de la campaña.
3. **Qué subió de verdad**: VERIFICAR TRAS ACTUALIZAR + un Inventario nuevo, cuyo **diff** en el Histórico de la plataforma deja constancia de qué TCUs pasaron de una versión a otra.

### Actualizar (o capturar) en una planta en producción

⚠️ Durante la actualización la TCU se reinicia **en modo bootloader**: unos 20 minutos en los que **no sigue al sol ni obedece un stow**. Si entra viento en ese rato, ese seguidor no se pone en seguridad. Por eso el botón **PREPARAR 1 TCU (captura OTA)** de la pestaña Firmware, que antes de tocar nada:

1. Consulta las **HSU vía NCU** y avisa si hay viento (nivel > 0 o alarma) — el momento equivocado para dejar una TCU sorda.
2. Comprueba **vía NCU** que esa TCU comunica, que no tiene alarma crítica y que el **SoC no es bajo** (si la batería cae a mitad del OTA, se queda a medias).
3. Hace un **backup completo previo** (`backups/pre_ota_ncu<n>_tcu<n>_<fecha>.json`) anotando el firmware actual.
4. Imprime los datos exactos para el updater (IP de NCU, puerto de gateway, nº de TCU) y el comando listo del proxy de captura.

Recomendación para la primera vez: una TCU **que ya toque actualizar**, que comunique bien, con SoC alto, con viento en calma y con alguien pudiendo ir al seguidor. Si el proxy o el updater se cortan a mitad, el updater soporta reanudar desde la última dirección (*Continuing OTA from address*), pero mejor no estrenarlo con viento.

**`TCU_ProxyOTA.ps1`** — capturador del protocolo OTA, paso previo a cualquier actualizador propio:

```powershell
.\TCU_ProxyOTA.ps1 -Ncu 10.100.1.52 -Puerto 503     # y en el updater: NCU IP 127.0.0.1, port 5020
```

Se coloca entre el updater y la NCU, **reenvía byte a byte sin modificar nada** y registra cada trama Modbus (sentido, unit = nº de TCU, función, dirección, nº de registros y hex) en `capturas/ota_<fecha>.csv`, con un resumen de las direcciones escritas (candidatas al bloque OTA). Con una TCU en banco y una actualización completa capturada queda documentado un protocolo que no está en ningún mapa — imprescindible para diagnosticar por qué una TCU falla siempre al actualizar, y requisito previo para un OTA nativo (que además necesitaría el visto bueno de Sunner sobre los binarios de firmware).

## Seguridad

- Los registros de **comando** (40000, 40007, 40017, 40018, 42000) pueden mover el seguidor o cambiar su modo: la toolbox los marca `[COMANDO]`, pide una **segunda confirmación** y los **excluye** al restaurar un backup.
- "Verificar tras escribir" relee cada registro y compara (en escrituras por máscara compara solo el byte/bit escrito). Además se validan los **rangos min/max documentados en el mapa** (jeita 233–398 K, duties 0–250, rampas 4–82…): un valor fuera de rango ni se envía.
- El guardado en **NVM** es una operación aparte, con su propia confirmación.
- Los ángulos `f32` viajan en **radianes** por Modbus; la toolbox trabaja **siempre en grados** (tipo `f32deg`) y convierte en ambos sentidos, con guardarraíl (±360°). Lo que **no** es un ángulo no se convierte: `west_pitch`/`east_pitch` (separación entre ejes) y `panel_width` son metros (`f32`), y los pulsos, mV o Kelvin van tal cual. La unidad que ves entre corchetes en el nombre es siempre la unidad **mostrada**.
- ⚠️ Errata del manual v6.1: la fila de **41106 east_pitch** dice "Radians 0..π/4", heredado de la fila de arriba; es una distancia como su gemela 41033 (Meters). Confirmado en campo — Ayora lee 6, que en radianes serían 344°, imposible en un campo cuyo máximo declarado es 45°.
- Los registros de configuración con nombre `[hex]` (máscaras de bits: `tracker_options`, `safe_pos_options`, `zigbee_config`…) se **muestran en hexadecimal** como los de estado, y al escribir admiten tanto `0x0A00` como `2560`.

## Notas técnicas

- Las variables de los desplegables van en **orden ascendente por número de registro**; el filtro busca por subcadena sin distinguir mayúsculas y sin interpretar `[ ] * ?` como comodines.
- Modbus TCP con framing MBAP propio (sin dependencias): FC03 lectura, FC16 escritura múltiple, FC22 mask-write para bytes y bits sueltos.
- Tipos soportados: `u16, s16, u16hex, u32, u32hex, f32, f32deg, u8lo, u8hi, bit, dt_bcd (fecha BCD 3 regs), charger, serial`.
- F32/U32 en orden *little-endian word swap* (2-1-4-3) según el mapa: registro N = palabra baja.
- Ante un timeout o socket roto reconecta y reintenta; ante una excepción Modbus (dirección ilegal, gateway sin respuesta…) reintenta sin reconectar.
- Si alguna planta necesitara offset Modicon en las direcciones, se cambia en un solo sitio (`Dir-Trama`).
