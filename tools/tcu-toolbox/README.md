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
| **SAT** | Los **ensayos de aceptación del Anexo 4** que se pueden automatizar (v6.6). **INICIAR REGISTRO** deja la toolbox registrando la planta entera durante los días que dure el ensayo, con dos cadencias sobre el bloque compacto de la NCU (puerto 502, sin tocar la Zigbee): un pase barato de **comunicaciones** cada 15 s (4 lecturas por NCU) y uno de **precisión y alarmas** cada minuto (18 por NCU). Escribe a disco en cada pase, en ficheros diarios y en modo añadir: si el PC se reinicia a los cuatro días, lo registrado sigue ahí y el ensayo continúa al volver a arrancar. Los **criterios de aceptación** (tolerancia de precisión, los umbrales de disponibilidad de TCU, RSU/NCU y comunicaciones, y la **ventana de la regla de los dos minutos** de D.4) y **todos los tiempos** (duración del ensayo **en minutos, horas o días** — 7 días para el ensayo del anexo, 20 minutos para comprobar el montaje antes de arrancarlo de verdad —, muestreo de TCU y de comunicaciones, ritmo del cronómetro y su tope) son **campos editables** y se recuerdan entre sesiones (v6.9 y v7.0): son de contrato, no del equipo, y cambian de una planta a otra. El registro **no depende de ellos**, así que ajustarlos y volver a analizar da el veredicto nuevo en segundos — sin repetir el ensayo. **ANALIZAR Y EMITIR** lee los CSV y emite el veredicto de los tres ensayos: **D.1.1** precisión de seguimiento (una muestra solo cuenta si el objetivo lleva dos muestras sin cambiar, que es como se descartan los transitorios y las activaciones de posición de seguridad que el anexo excluye), **D.3.4.1/2/3** disponibilidad de operación de TCUs (≥ 99 %), **RSU** (≥ 99,5 %) y **NCU** (≥ 99,5 %), por equipo y día, contando alarmas de motor, batería y comunicación; las meteorológicas no cuentan, como dice el anexo. Y **D.4** disponibilidad de comunicaciones, con la regla del anexo (un intento fallido suelto no computa salvo que se repita dentro de dos minutos, y entonces computan todos) y **umbrales distintos por tipo**: 98,5 % en TCU y 99,5 % en RSU. **RSU es lo que el mapa Sunner llama HSU**; los entregables del SAT usan RSU, que es como lo llama el contrato. Cada ensayo deja su `RESULTADO_*.csv` con el detalle por equipo y día, y la lista de los que incumplen. **CRONÓMETRO** (v6.7) para los **abanderamientos D.2.1–D.2.5** y la **posición objetivo manual D.3**: la condición la provoca el operario (bajar el umbral de viento, cortar la alimentación de la NCU…) y el cronómetro muestrea cada 3 s y apunta por TCU la hora UTC de recepción de la orden, la inclinación en ese momento, la hora de llegada a posición de seguridad, la inclinación allí, y lo mismo del desabanderamiento — las columnas exactas que pide el anexo, más los segundos de ida y vuelta. ⚠️ No hay un bit documentado de "posición de seguridad activa": la llegada de la orden se **infiere** del salto del objetivo y la llegada del seguidor de que el real alcanza ese objetivo. Queda dicho aquí porque en una recepción importa. Desde v11.55 el CSV trae además **`Lado_esperado` y `Lado_correcto`**: no basta con que el seguidor llegue a posición de seguridad, tiene que llegar **al lado que le toca** (ver «El límite de mediodía» más abajo) — y si está clavada en el límite **sin que nadie se lo haya mandado**, eso es una **suelta pasiva** y se marca como tal en vez de contarse como desobediencia. **HOJA D.1.2** genera la hoja de precisión con equipo externo (nomenclatura, hora UTC, posición del tracker, posición según algoritmo) con la columna de la lectura del instrumento en blanco, que es la única que no puede poner una máquina. |
| **Utilidades** | **Sincronizar reloj**: escribe la hora del PC en un rango de TCUs (40001–40006 + secuencia 40007 bit0→bit1) y verifica leyendo el reloj real (30079). **Identificación**: FW principal/fábrica, MCU secundario, BQ, HW, Xbee HW/FW, **MAC Xbee**, **número de serie**, fecha de fabricación y lote (bloque 30300+). |

En las operaciones de **planta completa**, cada línea de la consola lleva delante la **NCU** además del TCU (v5.8): los números de TCU se repiten en cada NCU, así que sin eso una línea no dice de qué equipo habla. El resumen de fallidas y el botón **Reintentar fallidas** también van por NCU — reintentar sobre la NCU equivocada sería escribir en el seguidor de al lado.

Consola común con colores, botón **CANCELAR** para abortar operaciones largas, y **log automático** a `logs/tcu_toolbox_AAAAMMDD.log`. La ventana es **redimensionable y maximizable** (v4.6): al agrandarla crecen las tablas y la consola, que es lo que interesa en una planta de cientos de TCUs.

**Un seguidor parado ya no sale verde (v11.60)** — el **modo** se leía, se
pintaba en su columna y **no se miraba para la salud**. Un TCU que no está en
AUTO no está siguiendo, tenga el ángulo que tenga, y el único que lo delataba
era la desviación (`dif > 5°`) — un vigilante *correlacionado*: solo se separa
cuando el sol se ha movido lo bastante. **Con el ángulo coincidiendo con el del
resto, un seguidor PARADO salía `OK`**, idéntico a uno operando.

Aquí eso no es un caso raro: esta herramienta se usa en barridos de **después de
tocar algo**, que es justo cuando un seguidor se queda en OFF *en la posición en
la que está el resto*. El técnico barre, ve verde, y se va del que ha dejado
parado — delante del equipo. Mismo fallo que se arregló en el SCADA (scada#210,
sobre la 14·14).

Ahora el modo entra en la salud, **en los dos caminos**: el compacto *vía NCU*
(el de por defecto y el del barrido de planta) y el directo por Zigbee. Es
**AVISO, no ALARMA**: parar uno en OFF o en MANUAL es mantenimiento legítimo; lo
que no es legítimo es que se vea igual que uno operando. Y lleva el motivo
pegado, `en OFF: no sigue`, porque «AVISO» a secas obliga a salir a mirar.

Tres cosas que quedan **fuera a propósito**:

- **la ausencia de dato no es un modo.** Si la NCU nunca ha hablado con un
  equipo, su hueco de la caché está a ceros y el modo sale `-`: eso ya se
  clasifica como `OFFLINE`, no por modo;
- **la desviación no interviene.** Sin nadie mandando, `dif` no mide
  seguimiento, así que la condición se evalúa aparte;
- **los repetidores.** Uno está atornillado a un poste: no sigue a nada, así que
  «no está en AUTO» no le dice nada a nadie. La nota se filtra en `Rep-Alarmas`
  como ya se filtran las de motor y posición — si no, esto ponía en AVISO a los
  cinco repetidores de Ayora, que es cambiar un punto ciego por ruido.

**Lo que se mueve en los números.** El KPI *Seguidores operativos* de la portada
del informe cuenta los que están en `OK`, así que **baja** con esto. Medido
sobre un barrido de 100 seguidores con 3 parados: **95 % → 92 %** (el semáforo
sigue en `medio`; los umbrales son 98 y 90). *Con alarma o sin comunicación* **no
se mueve** — un AVISO por modo no es una visita. Y en el historial,
`Cmp-Salud` marcará como **«peor»** un `OK → AVISO` de un equipo que alguien
acaba de poner en OFF: es correcto, dejó de seguir, pero cambia lo que el
comparador enseña entre dos barridos.

**Averías de la estación aparte de las alarmas meteo, y las HSU EXTERNAS (v11.65)** —
dos cambios que salen de la misma pregunta («¿qué leemos de las HSUs?»):

- **Averías ≠ meteo.** En el registro de alarmas de una estación conviven dos
  cosas que no piden lo mismo: la **AVERÍA** (un sensor sin comunicar, la
  batería desconectada — la estación está rota y la planta **ciega al viento**:
  visita) y la **ALARMA METEO** (viento, racha, nieve — la estación funcionando
  y midiendo lo que pasa: la planta debe estar abanderando). Hasta ahora salían
  revueltas en la misma cadena. Ahora LEER METEO las trae en **dos filas**
  («Averías de la estación» y «Alarmas meteo»), el diagnóstico las etiqueta
  (`AVERIA: … | meteo: …`) y todas las filas de HSU llevan además los campos
  `Averias` y `Alarmas_meteo` para no re-parsear texto. La salud ya iba en esa
  dirección (avería = ALARMA, meteo = AVISO); ahora las máscaras tienen nombre.
- **Las HSU externas.** El mapa de la NCU guarda estaciones en **dos
  direcciones distintas**: `30200` («HSU Data», la HSU propia por Zigbee — las
  `HSUn` de siempre) y `28000` («HSU Data extended», las **externas**: anemómetro
  y veleta RS485, piranómetros de tracking y difusa, contraste con Solcast,
  módulo de cómputo). La toolbox solo leía el primero: el segundo era
  **invisible**. Ahora todo lo que lee HSUs vía NCU (diagnóstico, pestaña HSU,
  agente, SAT) trae también las del 28000 como filas **`HSU EXT n`** — solo si
  el hueco está poblado, así que en plantas sin externas no cambia nada — con
  su **propio decodificador** (los dos `Alarms1` no comparten bits) y su
  `Alarms2` (28010). Una `HSU EXT` leída **no cubre** a una HSU declarada sin
  lectura, y **no entra** en el pase PEM (que cuenta el inventario declarado).
  Si una NCU con firmware viejo no implementa el bloque, la lectura falla en
  silencio y solo salen las propias.

**El desplegable: los tramos de un gateway son un gateway (v11.64)** — Ayora
NCU7 salía **tres veces**:

```
Ayora NCU7 (TCU 1-13)
Ayora NCU7 (TCU 15-23)
Ayora NCU7 (TCU 1 (auto)      ← el nombre, roto
```

El Excel da los esclavos de cada gateway **por tramos** y el generador escribía
una entrada por tramo. Ninguna de ellas es algo que se quiera elegir —nadie
opera «el bloque 22-31 del GW1»— y peor: elegir `Ayora NCU7 (TCU 1-13)` dejaba
fuera media NCU **sin decirlo**.

| Planta | Antes | Ahora |
|---|---|---|
| El Burgo | 5 | **4** |
| Ayora | 17 | **16** |
| **San José** | **82** | **38** |

Las TCUs son **exactamente las mismas**: 216, 751 y 2289 antes y después. Lo
único que cambia es que cada gateway sea una línea, con los saltos entre tramos
declarados como huecos.

Los gateways **distintos no se juntan** —elegir GW1 o GW2 significa algo, son
dos redes Zigbee— ni las NCUs distintas: la clave es **NCU + IP + puerto**.

**Y un salto no siempre significa lo mismo.** Se excluye del gateway igual, pero
decirlo mal manda a alguien a buscar donde no toca:

| | Ejemplo | Qué se dice |
|---|---|---|
| **hueco** | Ayora NCU7, la 14: no está instalada en ninguna parte | «la topología dice que estas TCUs no existen» |
| **ajena** | El Burgo NCU2, la 108: **es de la NCU1** | «TCUs fuera de los gateways de la NCU» |

Decirle a un técnico que la 108 «no existe» sería **falso**.

**Dos fallos que esto destapó:**

`Plan-Segmentos` emparejaba TCU con gateway mirando **solo `ini`–`fin`, ignorando
los huecos**. No mordía porque hasta ahora ninguna entrada de gateway los traía.
Y el **agente** dejaba los huecos fuera al construir su lista de gateways, así
que **escribía en TCUs que la topología declara inexistentes** — la prueba que lo
cubría esperaba justo ese comportamiento. Corregidos los dos (agente v4.0).

Y el nombre del `(auto)`: el patrón de limpieza era `(GW|TCU)\S*$`, que exige
que `GW` o `TCU` vayan **pegados al final**. Con dos tramos el prefijo común de
`(TCU 1-13)` y `(TCU 15-23)` es `Ayora NCU7 (TCU 1` —las dos empiezan por 1— y
ahí `TCU` no está pegado: no limpiaba nada.

**El `/leer` del agente no alcanzaba el bloque de estado (agente v3.9)** — el
SCADA pide variables al agente por `GET /leer?vars=...`, y `Resolver-Variable`
**solo buscaba en las 125 de configuración** (`4xxxx`). Las 43 de lectura
(`3xxxx`) no las encontraba, así que por ahí no se podía leer **ni SoC, ni SoH,
ni alarmas, ni tilt, ni el tiempo de motor** — ni, ahora, capacidad y ciclos.

Y `Leer-Planta` ya estaba escrito para admitirlas:

```powershell
$d.vdef = $(if ($d.nombre -like 'ESTADO *') { $ESTADO[...] } else { $VARIABLES[...] })
```

Esa rama era **código muerto**: el resolver nunca podía devolver un nombre
`ESTADO ...`.

`Resolver-Variable` gana un interruptor `-conEstado`, **apagado por defecto a
propósito**: la misma función la usan los caminos de **escritura** —uno en la
toolbox y dos en el agente—, y resolver ahí el nombre de un registro de solo
lectura sería abrir la puerta a escribir contra él. Solo lo enciende quien lee.
El banco lo fija: de los tres sitios que resuelven en el agente, exactamente
**uno** lleva el interruptor.

Desde el SCADA, y para lo que se lee de vez en cuando:

```
GET /leer?vars=30099,30100,30101,30102&ncu=13&tcus=1-72
```

Un registro con dos campos —`30096` es SoC y SoH— **no se resuelve a ciegas**:
dice que es ambiguo y se acota con `30096 SoC`.

⚠️ El `/leer` va **por Zigbee, una lectura por (TCU × variable)**: cuatro
variables en 72 TCUs son 288 lecturas. No es un endpoint de refresco.

**Analizador de baterías (v11.63)** — hoja nueva bajo **TCUs**, junto a
*Baterías*. La pestaña *Baterías* es una **foto**: el último barrido contra unos
umbrales y contra la mediana de la flota. Eso contesta *«cuál está mal ahora»*.
Lo que no contesta —y es lo que se pregunta uno delante del camión— son otras
cuatro cosas:

| | Cómo |
|---|---|
| **Cómo va** | La pendiente de SoH y SoC sobre los barridos ya guardados en `trabajos/` |
| **Por qué está mal** | Cruza Vpanel, corriente de entrada, día/noche y el estado del cargador y da una **causa**, no un síntoma |
| **A cuál voy** | La peor arriba, con el motivo al lado |
| **Cuánto le queda** | Meses hasta el SoH de fin de vida, **siempre con su confianza** |

**ANALIZAR** lee la planta y sitúa lo leído contra lo guardado. Con *«Leer la
planta ahora»* desmarcado usa el último diagnóstico, sin tocar la planta.

**Las causas**, en orden de precedencia — lo que dice el cargador manda sobre lo
deducido:

- `sin batería` — Vbat por debajo de 15 V: no hay batería útil conectada
- `cargador en fallo` — lo reporta él, si se ha pulsado *LEER CARGA*
- `panel sin dar` — de día y con el panel a cero: tapado, sucio, sombreado o cable suelto
- `no entra corriente` — de día, el panel da, pero no entran mA: cargador o cableado
- `batería no admite` — entra corriente y el SoC no sube
- `de noche` / `sin juzgar` — **no son averías**: sin sol no se puede juzgar la carga, y sin saber si era de día tampoco

Ese último punto es el falso positivo gordo que había que evitar: de noche
ninguna batería carga, y una lista de «no entra corriente» a las diez de la
noche manda a campo a mirar equipos sanos.

**Lo que el analizador NO dice**, a propósito:

- **Sin al menos 3 barridos separados 14 días no hay tendencia**, y se dice — no
  se rellena con un cero. Dos lecturas de la misma semana no son una pendiente.
- Una batería que **no baja** no tiene fecha de caducidad; se dice `no baja`.
- Una caída **más pequeña que el ruido de medida** (2 puntos de SoH en todo el
  recorrido) no cuenta como caída.
- Los meses restantes llevan **siempre** su confianza: `con recorrido` (≥6
  muestras y ≥90 días), `orientativa`, o `MUY provisional: menos de un mes de
  historia`. Un número de estos sin su margen es una invitación a creérselo.

⚠️ **La estimación de vida restante es lo más útil de decir y lo más fácil de
mentir.** Sale de una recta sobre barridos espaciados de forma irregular. Sirve
para ordenar y para planificar recambios, no para prometer una fecha.

**El envejecimiento, medido en vez de estimado.** La lectura directa de una TCU
se paraba en el registro 30098 — **un registro antes** de esto:

```
30099  capacidad_actual [mAh]
30100  capacidad_nominal [mAh]
30101  ciclos_carga
30102  dias_preservacion
```

Alargar **la misma trama** de 8 a 12 registros no cuesta una lectura Modbus más,
y con ellos el envejecimiento se **mide**:

- **SoH medido** = capacidad actual / nominal. Y si el BMS declara un SoH que se
  aparta 15 puntos de lo que dice la capacidad, **eso es un hallazgo por sí
  solo**: o el BMS está descalibrado o la medida no vale.
- **Ciclos de carga**: la edad real del elemento, no una pendiente sobre
  barridos irregulares.
- **Días en conservación** (`dias_preservacion`): es una **causa**, no un
  síntoma — la batería que lleva N días sin cargarse de verdad.

⚠️ **Los ciclos NO se convierten en meses de vida**, a propósito. Para eso haría
falta saber cuántos ciclos aguanta el elemento, y eso el mapa no lo dice y el
fabricante no lo ha dado. Poner «le quedan N meses» a partir de un número de
ciclos y una vida nominal inventada sería fabricar el dato. Los ciclos ordenan y
contrastan; la vida restante sigue saliendo de la capacidad.

**El bloque compacto de la NCU no trae nada de esto**: sus 22 registros por TCU
se acaban en el SoH declarado. Así que va en su propio botón, **LEER CICLOS Y
CAPACIDAD**, que recorre las TCUs **por Zigbee, una a una**, con su aviso de
coste delante. Los ciclos se mueven despacio: esto no hace falta a diario.

El análisis se guarda como trabajo y se puede volver a abrir desde *Trabajos*.

**«Cargar preset» se comía el backup del volcado (v11.62)** — el camino para
clonar una TCU en otra es *Volcar TCU → Backup JSON → Escribir*. Pero en
*Escribir* hay **dos** botones de carga, y el de arriba, `Cargar preset`, **no
comprobaba el formato**: le dabas el backup del volcado, se lo tragaba, soltaba
`AVISO: '' no existe en el mapa` por cada fila y **dejaba la tabla en blanco**
sin decir por qué. El de abajo sí comprobaba. Ni el fichero ni el usuario tenían
la culpa: había que adivinar cuál de los dos botones era.

Ahora `Cargar preset` **acepta también un backup** y lo carga como tal, con sus
exclusiones y diciéndolo en la consola. Los dos botones comparten la misma
lógica, así que no pueden divergir. Y un fichero que no es ninguna de las dos
cosas se dice claramente, en vez de vaciar la tabla.

Lo que **nunca** se clona al pasar un backup a otra TCU, y ahora se prueba
ejercitando la conversión en vez de buscando una línea en el fuente:

| Se excluye | Por qué |
|---|---|
| Registros de **comando** | Son órdenes, no configuración: escribirlos dispara acciones |
| **Fecha y hora** | Es la de cuando se volcó |
| **Identidad de red** — `zigbee_slave_id`, `rs485_slave_id`, PAN ID, cifrado | Son de la TCU origen. Clonarlas deja **dos equipos con el mismo esclavo** en la misma Zigbee |

De paso, el aviso de fila sin nombre se dice **una vez** y no una por fila.

**Inventario global: una tabla con todos los equipos (v11.61)** — hoja nueva en
**GLOBAL**, encima de *Diagnóstico*. Lo de cada tipo de equipo vivía en su
pestaña —la versión de la NCU en *Firmware NCU*, el `SoftwareId` de la HSU en
*Firmware HSU*, los repetidores en la suya— y para una ficha de entrega hace
falta **un solo fichero**. Una pasada: NCU, gateways, estaciones, repetidores y
TCUs, con CSV y JSON.

**Los huecos son reales, y llevan su motivo escrito.** No todos los equipos dan
lo mismo, y «vacío» y «no se puede leer» no son lo mismo:

| Equipo | Nº serie | MAC | FW | FW fábrica | HW | Fecha fab. |
|---|---|---|---|---|---|---|
| **TCU / repetidor** | ✅ | ✅ Xbee | ✅ | ✅ | ✅ PCBA | ✅ |
| **HSU** | ❌ | ✅ `30016/30018` | ✅ `SoftwareId` | ❌ | ⚠️ | ❌ |
| **NCU** | ❌ | ❌ | ✅ `VERSION_STRING` (reg 50) | ❌ | ⚠️ `NOT READY` | ❌ |
| **Gateway** | ❌ | (HTTP) | (HTTP) | ❌ | ❌ | ❌ |

El mapa R23 de la HSU **no tiene** número de serie ni fecha de fabricación; el
R7.1 de la NCU tampoco, y sus `HardwareId`/`SoftwareId` están marcados
**NOT READY**. Eso va en la columna *Nota* de cada fila, no en un comentario del
código.

**El gateway no habla Modbus, y esa es la parte nueva de verdad.** No es la NCU:
es un **Digi ConnectPort con su propia IP**, y los puertos 503/504 son el
*passthrough Modbus de la NCU*, no el gateway. Por Modbus solo se sabe de él lo
que la NCU cuenta: si está **conectado o caído** (bits 4 y 5 de 30101), qué
esclavos le cuelgan y cuántos repetidores lleva. Eso sale en el barrido.

Su identidad —MAC, firmware, PAN ID y canal— se le pregunta por **HTTP/RCI** al
puerto 80, con el botón **IDENTIFICAR GATEWAYS**, que va **aparte del barrido a
propósito**:

- necesita **`ip_gw`** en el fichero de planta. El generador ya lee las columnas
  `IP GW 1` / `IP GW 2` de la hoja *Direcciones IP*, pero esa pasada no se ha
  hecho aún con ellas: hasta entonces el inventario lo dice en la fila del
  gateway en vez de suponer la regla «IP de la NCU + n», que solo está
  comprobada en El Burgo;
- y **no está verificado contra un Digi real**. El transporte sí lo está —el
  recolector de cobertura hace `POST` a `/UE/rci` a diario—, pero *qué consulta
  devuelve la identidad del coordinador* no se ha visto nunca. Por eso, cuando
  no reconoce la respuesta, **vuelca el XML crudo a la consola**: la primera
  pasada delante de un gateway de verdad nos da el esquema en vez de adivinarlo
  dos veces. Y por eso el barrido de planta no depende de ello.

**Leer TODAS las variables, con el coste por delante (v11.61)** — la pestaña
*Leer variable* se llenaba a mano, una fila por variable. Para «a ver qué tiene
esta TCU» eso son **168 filas tecleadas**. Botón **TODAS**, que respeta el
filtro: sin filtro pone las 168; con `viento` puesto, solo esas.

Pero LEER cuesta **una lectura Modbus por (TCU × variable)**, y eso hay que
decirlo antes y no después:

| | Lecturas |
|---|---|
| 168 variables × 1 TCU | 168 — segundos |
| 168 × una NCU de 72 | **12.096** |
| 168 × Ayora entera | **126.168** |

Por encima de 2.000 lecturas se pregunta antes de abrir la primera conexión, con
el número delante. No lo impide —a veces se quiere— pero no se lanza a ciegas, y
se puede parar con CANCELAR quedándose lo leído.

**Regenerar desde el Excel ya no borra lo que el Excel no trae** — la pasada del
Excel de la #222 se llevó por delante, en silencio, los **cinco repetidores de
Ayora**. Sin ellos no se diagnostican, no entran en el inventario ni en la
campaña de firmware, y uno con la batería muerta se lleva por delante todo lo
que cuelga de él — que es exactamente el motivo por el que se declararon.

El mecanismo de conservación existía y estaba pensado, pero era una **lista
blanca de nombres**:

```python
for k in ("hsu_esclavos", "rsu", "hsus_gw", "ip_gw"):
```

y `repetidores` no estaba en ella. La regla ya no enumera nada: **regenerar solo
pisa lo que la hoja dice**. Si la entrada recién construida trae el campo, manda
la hoja; si no lo trae, es que la hoja no opina y lo que hubiera en el JSON se
queda, venga de donde venga. Un campo puesto a mano mañana se conserva solo.

Los cinco repetidores están repuestos en `plantas/24025-ayora.json`. `test_conservar.py`
cubre la regla, y de paso el primer intento de arreglo —que invertía la lista en
vez de quitarla— murió ahí: dejaba de conservar `hsu_esclavos`, que tampoco viene
de la hoja en casi ninguna planta.

**Los huecos de la NCU7 no hacían falta.** Lo parecían: también desaparecieron. Pero
el generador nuevo parte esa NCU en tramos (`1-13` y `15-23`) que dejan fuera el
14, el 24 y el 25 **por construcción**, y Ayora sigue siendo de 751 seguidores.
Eran dos mecanismos para lo mismo. La prueba que los exigía estaba escrita sobre
la *forma* y se puso roja sin que nada estuviera mal; ahora mide el **resultado**
—que esos tres números no caen en ningún tramo, y que la NCU7 deja 22 seguidores—,
que es lo que de verdad importa.

**El fichero exportado lleva la hora del DATO, no la de guardarlo (v11.59)** —
un barrido de Ayora son minutos. Si lo exportabas a media tarde, el fichero se
llamaba `diagnostico_20260821_1640.csv` con la hora de la tarde: **dos
diagnósticos de la misma mañana acababan con nombres que no dicen cuál es
cuál**, y el que abre el CSV una semana después no tiene forma de saber a qué
momento de la planta corresponde.

Ahora cada pantalla **sella el momento en que lanza su lectura**, y ese es el
sello que va al nombre del fichero. En todas: diagnóstico, auditoría,
inventario, PEM, baterías, comparación, lectura de señales, identificación,
volcado, plan de firmware, Comm esclavos, Diagnóstico NCU, estabilidad,
auditoría de NCU / HSU / repetidores y sus firmwares.

**Y el campo `fecha` de dentro del JSON igual** — ese es el que se queda en la
plataforma, así que era el que más daño hacía. La hora de exportar no se pierde:
va aparte, en `exportado`.

Dos excepciones, a propósito: el **cierre** se va acumulando a mano, no sale de
una lectura; y la **caja negra de la HSU** pide el nombre del fichero *antes* de
leer, así que ahí la hora de guardar ya era la de la lectura.

Para que no se cuele en la próxima pantalla, la regla es mecánica y la suite la
exige: **toda llamada a un exportador dice de qué bloque es** (`-bloque 'diag'`),
y todo bloque declarado tiene quien lo selle. Si alguien añade una pantalla y se
olvida, falla en la suite y no en campo tres meses después.

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

**La topología se revisa a sí misma (v11.28)** — un fichero de plantas mal
generado **no da error**: la herramienta simplemente lee menos planta y se queda
tan tranquila. En San José faltaban **cinco NCUs enteras — 603 TCUs** — porque su
campo de esclavos llevaba varios tramos y el exportador solo entendía uno. Nadie
se enteró.

Al arrancar se revisa cada `plantas/*.json` y se avisa en la consola de:

- **gateways solapados** — San José NCU3 tiene `1-46` y `46-120`: el esclavo 46
  cuelga de los dos y solo se lee por uno. Se comparan los esclavos **de verdad**,
  no los extremos del rango: en San José varias NCUs **alternan los dos gateways
  por bloques** (`1-19 22-31 38-47…` en GW1 y `20-21 32-37…` en GW2), y mirar los
  extremos cantaba un solape que no existe (v11.29);
- **el rango no cuadra con los trackers declarados** — si la topología dice que
  una NCU tiene 123 y su rango deja 103, lo canta con los dos números.

Lo segundo necesita que el export de la plataforma incluya `trackers` por
entrada; sin ese dato no opina, no se lo inventa.

**La NCU que no contesta perdía el motivo (agente v3.7, toolbox v11.42)** — en
`Diag-UnaNcu`, el `catch` construía la fila *«NCU sin respuesta en 502: …»* y
después hacía `continue`. En PowerShell, **`continue` dentro de una función pero
fuera de un bucle salta al siguiente giro del bucle DEL QUE LLAMA** y descarta lo
que la función devolvía. Esa fila se creaba y se tiraba.

El total seguía cuadrando —`Diag-Completar` reponía esa NCU y sus TCUs como
`SIN LECTURA`— así que no se notaba en los números. Lo que se perdía era **el
motivo**: en vez de *«NCU sin respuesta en 502: no se pudo conectar»* llegaba un
genérico *«declarado en la topología y no leído»*. Y distinguir «el switch está
caído» de «no he barrido esa NCU» es justo para lo que sirve esa fila.

Ahora es `return`, no `continue`. Y la suite recorre el **árbol sintáctico** de
la toolbox y del agente y falla si aparece un `continue` o un `break` dentro de
una función y fuera de un bucle: a ojo no se ve, y el síntoma no apunta al
sitio.

**LEER METEO y LEER CONFIG, en tabla (v11.57)** — con nueve estaciones, la
tabla de la pestaña HSU eran **9 × 13 = 117 filas en una sola columna**, con una
cabecera `--- NCU5 - HSU3 ---` cada trece. Para comparar el viento de dos
estaciones había que hacer scroll entre dos números que deberían estar uno al
lado del otro.

Con **más de una** HSU ahora es una **fila por estación** y una columna por
campo. Con una sola sigue siendo la lista vertical, que ahí es la forma
correcta — lo decide lo mismo que ya decidía si poner cabeceras: cuántas hay.

- las **columnas las pone la lectura**, no una lista escrita en el código: vale
  igual para METEO (viento, dirección, nieve, lluvia, T, HR, irradiancia,
  batería, tensiones) que para CONFIG (esclavo, umbrales ON/OFF, tiempos,
  altura del sensor de nieve) — y comparar umbrales entre estaciones es
  justo para lo que sirve una tabla;
- en **Alarmas** y **Sensores** va el texto decodificado, no el `0x0000`, y esas
  dos columnas se ponen **al final**: son las anchas y en medio partían en dos la
  fila de números;
- la estación **muda conserva su fila**, en su sitio y en rojo. Desaparecer no
  es información.

La tabla sigue siendo ordenable y filtrable por columna, como las demás.

**En la hoja de HSUs, DIAGNOSTICAR barre solo HSUs (v11.56)** — entrar por
*Diagnóstico → HSU* y pulsar DIAGNOSTICAR barría **la planta entera** —las 751
TCUs de Ayora, minutos— para acabar enseñando diez filas. El resultado estaba
bien; el camino no.

Las estaciones viven en un bloque aparte que la NCU cachea (30200+, diez
huecos), así que sacarlas cuesta **una lectura por NCU**: las diez de Ayora son
16 lecturas y unos segundos. Es el mismo trato que ya tenían los repetidores.

Lo que no se toca:

- **no tira el barrido anterior.** Sustituye las filas de HSU y deja como
  estaban las de NCU, TCU y repetidor — perder un barrido de 782 filas por
  pulsar aquí sería mal negocio —, y lo dice en la consola para que nadie lea
  esas filas como recién medidas;
- **la estación declarada que nunca ha comunicado sigue saliendo**, como
  `SIN LECTURA`, igual que en el barrido completo;
- **los avisos de HSU Id** (lo que falta en la topología, lo leído contra lo
  declarado) salen aquí también, que es donde más sentido tienen.

El barrido completo sigue en *GLOBAL → Diagnóstico de planta*, con sus vistas
por nivel intactas.

**Los dos filtros de la tabla ya se conocen (v11.56)** — el diagnóstico tiene
**dos** filtros sobre la misma tabla: el de **nivel/NCU/salud**, que repinta
desde el último resultado, y el de **columna** (pulsar la cabecera), que trabaja
sobre su propia copia. Que la tabla la hubiera repintado el otro se detectaba
**contando filas**, y dos vistas distintas pueden tener las mismas: entonces el
filtro de columna se creía vigente y al pulsar una cabecera **resucitaba las
filas de la vista anterior**, que ya no estaban en la tabla.

Ahora se mira también si la primera fila a la vista es una de las que se
guardaron: si no lo es, esto lo ha pintado otro. Y al cambiar de nivel, el
filtro de columna se limpia de verdad — antes el asterisco de la cabecera se
quedaba puesto diciendo que filtraba algo que ya no filtraba.

De paso, la columna **NCU** de la tabla pasa de 45 a 58 px: el encabezado salía
`NC…` y con diez HSUs de diez NCUs distintas, saber de cuál es cada una es justo
el dato. El número estaba ahí desde siempre; lo que no había era sitio para el
título.

**Lo que le falta a la topología de cada planta, dicho antes de tropezarse
(v11.55)** — Ayora es la única planta con los datos de sus estaciones. Las
demás declaran que las tienen pero no con qué esclavo:

| Planta | HSUs declaradas | Con esclavo | Con HSU Id |
|---|---|---|---|
| Ayora | 10 | 9 | 10 |
| San José | 9 | **0** | 0 |
| Fayón | 1 | **0** | 0 |
| Túnez | 1 | **0** | 0 |
| Bagnarelli | 2 | **0** | 0 |

Sin el esclavo, leer las HSUs con *Planta completa* no funciona — y eso no se
sabía hasta ir a leerlas y que la herramienta mandara a escanear sin explicar
por qué. Ahora el diagnóstico lo dice, en cualquier planta:

```
La topologia declara HSUs en 9 NCU(s) pero no dice con que esclavo (NCU 1, 2,
3, 6, 9, 12, 15, 17, 20). Sin eso no se pueden leer con Planta completa: usalas
con BUSCAR ESCLAVO (rango 225-235) y guarda lo que encuentre, o mira el Modbus
Id en la pagina de cada NCU.
```

Los dos datos que faltan **no se consiguen igual**, y por eso se dicen por
separado: el **HSU Id** lo aprende solo un diagnóstico (el hueco *es* el
número), pero el **esclavo no se puede aprender leyendo** — el bloque que la
NCU cachea (30200+) trae ProductId, estado, alarmas, viento y nieve, y no el
esclavo. Sale de un barrido o de la página web de la NCU.

**Y el barrido ya no cuesta minutos.** `BUSCAR ESCLAVO` iba del 1 al 247
*siempre*: 247 consultas por gateway, y cada esclavo que no existe cuesta lo
que tarde la NCU en rendirse con el Zigbee. Ahora lleva rango, por defecto
**225–235**: once números, donde están las estaciones. Los repetidores están por
el 200.

**El comisionado de planta completa ignoraba el cuadro de TCUs (v11.55)** —
escribías `1-72`, pulsabas ESTADO Y MODO con *Planta completa*, y recorría el
rango entero de cada NCU sin decir nada. Las demás acciones de PEM sí lo
respetaban. Ahora también.

**El HSU Id no hay que teclearlo: la NCU ya lo dice (v11.54)** — una estación
tiene **dos** números y no son lo mismo:

| | Qué es |
|---|---|
| **Modbus Id** | Su dirección en la Zigbee del gateway. En Ayora **las diez son la 230**, porque cada NCU tiene su propia red. No distingue nada |
| **HSU Id** | El hueco que ocupa en la caché de su NCU (bloque 30200). Es el nombre que sale en la página web de la NCU y en los planos, y el único nombre real que tienen |

De ahí venía el lío de llamar **HSU1** a la que la NCU16 llama **HSU10**: el
JSON de Ayora no traía el campo `rsu` en ninguna NCU, así que las declaradas se
numeraban 1..n dentro de cada una. Las que *sí* contestan ya salían bien —
`Ncu-HsuCompat` las etiqueta por el hueco —, y por eso lo leído y lo declarado
no casaban.

Casi no hay que teclear nada: **el hueco ES el HSU Id**, así que una estación
que contesta ya lo está diciendo. El diagnóstico lo compara con lo declarado y
avisa:

```
NCU15: HSU Id leido 8, 9. La topologia no lo declara: anade "rsu": [8, 9] a esa
NCU y las tablas la llamaran por su nombre.
NCU2: HSU Id leido 1, 2 pero la topologia declara 3, 4. Uno de los dos esta mal.
```

Sólo la que no ha comunicado nunca hay que ir a mirarla a la página de su NCU.
La de Ayora ya está: **NCU16, HSU Id 10, Modbus Id 230, Gateway 1** — anotado en
la topología.

**El esclavo NO identifica una estación en la planta (v11.53)** — revisando el
resto de pantallas por lo mismo que la v11.52, apareció algo peor que fricción.

Cada NCU tiene su **propia red Zigbee**, así que el número de esclavo solo es
único *dentro* de una NCU. En Ayora el **230 está en casi todas**: `hsu_esclavos:
[230]` en la NCU2, la NCU3, la NCU4… `INSTALAR FW` filtraba por número de
esclavo y se quedaba con **el primero de la lista**. Es decir: escribías 230,
pulsabas instalar, y podía reiniciar la estación de otra NCU. Lo mismo en las
escrituras de la pestaña HSU (umbrales de viento, reloj, nieve, NVM).

Ahora, o no hay duda, o no se hace. Si el esclavo existe en varias NCUs, el
error las nombra:

```
el esclavo 230 existe en 3 NCUs (2, 3, 16): cada NCU tiene su propia Zigbee y el
numero se repite. Pon la NCU en el cuadro de al lado para decir cual
```

Firmware HSU tiene un cuadro **NCU** al lado del de esclavo para resolverlo. Un
esclavo que solo existe en una NCU sigue sin pedir nada.

Esto ya estaba antes de la v11.52 — el desplegable de BUSCAR HSUs lo tapaba
porque se elegía una estación concreta — pero al poder trabajar sin escanear
quedaba a un clic. Va con test, incluido uno que falla si alguien vuelve a
escribir `$obj[0]`.

**Las HSUs salen de la topología, sin escanear (v11.52)** — con *Planta
completa* seleccionada, cualquier lectura de HSU se paraba con:

```
ERROR: pulsa BUSCAR HSUs primero: con Planta completa o (auto) hay que saber de
que NCU cuelga cada HSU
```

Era pedir dos veces lo mismo. **La topología ya lo sabe**: dice cuántas
estaciones tiene cada NCU y con qué esclavo, y es exactamente lo que usa
`Flota-Declarada` para pintar la columna HSUs del diagnóstico. Obligar a un
barrido antes de poder leer lo que ya está declarado era fricción y un rato de
espera.

Ahora los objetivos se construyen de la topología, con el número que da la
columna RSU del Excel (la de la NCU16 sale como **HSU10**, no como HSU1) y con
los dos gateways de su NCU para probar por el que conteste. **BUSCAR HSUs sigue
haciendo falta** para encontrar las que *no* están declaradas — que es otra
pregunta —, y el error solo salta ahora si la planta no declara ninguna.

**El SAT, por NCU y por TCU (v11.51)** — el ensayo se montó pensando solo en la
planta entera, que es lo que pide el anexo. Pero en obra hace falta lo otro
constantemente: comprobar el montaje de una NCU antes de arrancar los siete
días, y sobre todo **reemitir el veredicto de la NCU que incumplió sin volver a
medir nada**.

Son dos cosas distintas y ahora están las dos:

- **Registrar acotado**: el cuadro de NCUs de arriba y un cuadro de TCUs nuevo
  en la pestaña. El alcance se **congela al arrancar** — si alguien toca el
  cuadro a mitad de una medida de siete días, el registro se partiría en dos —
  y el aviso de «esto no es el 100 % de la planta» dice exactamente qué se va a
  medir.
- **Analizar acotado**: el registro es el que es, pero el veredicto se reemite
  sobre un trozo. Los ficheros `RESULTADO_*` salen con el alcance en el nombre,
  así que reemitir por NCU no pisa el de la planta entera.

Dos detalles que importan para que el veredicto siga siendo correcto: las filas
de **equipo** (RSU y la propia NCU) no llevan número de TCU, así que un filtro
de TCUs no les aplica y entran si su NCU entra — si no, filtrar por TCU se
cargaba el D.3.4.2. Y los eventos **PASE** son el denominador de D.4 (cuántos
intentos hubo) y no llevan NCU: no se filtran, o la disponibilidad de
comunicaciones se quedaría sin contra qué dividir.

**El árbol, entero y bien escrito (v11.51)** — cabían 18 de las 31 líneas y los
bloques REPETIDORES y TCUs quedaban debajo de una barra de scroll, que es justo
lo que el árbol venía a evitar. Ahora llega hasta abajo del todo, a la altura de
la consola, que se corre a su derecha. Y las etiquetas van con tildes y con ñ:
*Diagnóstico*, *Auditoría*, *Baterías*, *Lectura de señales*. El `.ps1` está en
UTF-8 con BOM, así que PowerShell 5.1 las lee sin mezclarlas.

**Una NCU tiene DOS diagnósticos (v11.50)** — el suyo propio —sus alarmas, su
SAI, su seta, sus gateways, su reloj— y el de sus **esclavos** —cuántas TCUs y
HSUs le hablan—. Son preguntas distintas: la primera la contesta ella sola por
el puerto 502 sin tocar la Zigbee, y la segunda habla de otros equipos. Iban
mezcladas en una sola tabla llamada *Comm NCU*, que ni era solo comunicaciones
ni era solo de la NCU.

| Pestaña | Qué contesta |
|---|---|
| **Diagnóstico NCU** | Versión, estado, GW1/GW2, SAI, seta, reloj, los diez interruptores de limpieza y **el stow forzado por grupo** |
| **Comm esclavos** | Si la NCU contesta, y cuántas TCUs y HSUs le hablan, como `leídas/declaradas` |

Las alarmas propias de la NCU no son un invento nuestro: están en el mapa R7.1,
en `30100` (batería baja del SAI, fallo de alimentación, seta de emergencia,
interruptores de limpieza) y `30101` (alarma de batería, GW1 y GW2
desconectados).

El **stow forzado por grupo** (`40001`–`40007`) baja aquí desde Auditoría NCU.
Estaba comparándose entre NCUs como si fuera configuración, y no lo es: un grupo
abanderado a mano que alguien se dejó puesto es una condición **de esa NCU** —y
son seguidores parados—, no una discrepancia.

La tabla de esclavos colorea ahora por **lo que falta**, no por la salud de la
NCU: una NCU perfecta a la que no le habla una estación sale en rojo, que es lo
que interesa ver.

Y del árbol desaparece la hoja *NCU · Diagnóstico*, que llevaba a las filas NCU
del barrido de planta: era lo mismo que la pestaña propia, pero peor y de
rebote.

**Las HSUs declaradas no llegaban a Comm NCU (v11.49)** — la columna **HSUs**
dice `leídas/declaradas`, y en Ayora salía `1/0` en la NCU3, `2/0` en la NCU15…
**0 declaradas en las dieciséis**, cuando la topología declara 10 estaciones.
Justo la columna que existe para avisar de la que falta era la que no podía
hacerlo.

`Trabajos-Planta` construía cada trabajo con NCU, IP, TCUs y conexión, pero se
dejaba fuera `hsuLista` y `rsuLista`, así que quien contaba las declaradas
contaba sobre una lista vacía. Ahora viajan con el trabajo y con su conexión.

Se vio en una captura de campo, no en la suite — de ahí que ahora haya un test
con dos NCUs y sus estaciones declaradas.

**La auditoría compara valores, no bits (v11.48)** — al auditar salía esto, y
con razón no inspiraba confianza:

```
NCU15 TCU 39  41111 max_tilt_west_r1 [deg]: la primera lectura no cuadraba
pero al releer da 55, que es el valor del preset: descolocacion, no desviacion
```

**No había ninguna descolocación.** La comparación se hacía con
`Comparar-Escritura`, que compara los 16 bits crudos de cada palabra uno a uno.
En los registros `f32deg` la TCU guarda **radianes en coma flotante**: 55° son
0,9599310885968813 rad, y a 3 decimales de grado hay **~293 patrones de bits
distintos que se imprimen todos como `55`**. Cualquier valor que no hubiéramos
escrito nosotros —el de fábrica, el del instalador— difiere en los últimos bits
de la mantisa: la comparación cruda falla y la decodificada acierta.

Que los dos lados se impriman igual es la firma del **redondeo**, no la de una
trama mal alineada — una respuesta descolocada daría un valor *distinto*, no el
mismo. El apaño funcionaba por casualidad, y el precio era una lectura Modbus de
más por variable y por TCU, más un aviso naranja que no significaba nada y que
enterraba a los que sí.

Ahora la auditoría lee el valor decodificado y lo compara con tolerancia, que es
lo que ya hacía en la segunda pasada. Mismos veredictos, la mitad de lecturas en
las variables afectadas, y se acabó el mensaje. La comparación exacta se queda
donde tiene sentido: **verificar una escritura**, que ahí los bits los hemos
puesto nosotros.

**El relleno de flota solo cubre lo barrido (v11.48)** — pedir el diagnóstico de
la TCU 24 de la NCU11 devolvía una fila buena y **64 filas SIN LECTURA** de
equipos por los que nadie había preguntado. Con un filtro de salud puesto
encima, la tabla se quedaba en blanco y parecía que el diagnóstico no había
hecho nada.

Lo declarado y no leído solo se completa si **entraba en ese barrido**: las TCUs
que pediste, más las HSUs y repetidores de las NCUs recorridas (esos se leen por
NCU entera, no por rango de TCU, así que si la NCU estaba, ellos estaban).

**Una fila por equipo, y las ventanas aparte (v11.47)** — el plan de firmware
metía tres cosas en la misma tabla: la **ventana** del updater que hay que
abrir, los **rangos** que se le pegan dentro y las **TCUs pendientes** una a
una. Con una ventana de una sola TCU salían dos filas idénticas columna a
columna. En su día se añadió una columna *Fila* para distinguirlas, que es tapar
el problema en vez de resolverlo.

Ahora son dos tablas:

| | Qué lleva |
|---|---|
| **Arriba** | Una fila por ventana del updater: con qué IP y puerto abrirla, el `Add from…to` entero, cuántas TCUs y cuánto tarda |
| **Abajo** | Una fila por equipo pendiente: NCU, TCU, gateway, a qué ventana pertenece, versión actual, objetivo, SoC y estado |

Los rangos van **enteros** en su columna, tal como se pegan en el updater.
Antes se intentaban resumir en Desde/Hasta, y con huecos dibujaba un rango que
no existe: en la NCU10 con 10-16 y 18-22 salía «de 10 a 22», la TCU 17 parecía
estar dentro, y el 12 de la columna TCUs no cuadraba con las 13 que van del 10
al 22.

De paso, verificar tras actualizar se simplifica: en la tabla de abajo cada fila
**es** un equipo, así que basta con NCU + TCU. Antes había que mirar Desde y
Hasta para no repintar un tramo entero por culpa de una sola TCU.

La misma regla en **Firmware HSU**: una fila por estación en vez de una cabecera
y un dato por cada una —veinte filas para diez HSUs—, y la que no contesta
también tiene la suya, porque desaparecer no es información.

**El repetidor es el que lo zanja (v11.46)** — con lo medido hasta ahora, el
nibble del Product ID admite **dos lecturas que encajan igual de bien**:

| Equipo | Alimentación | Nibble |
|---|---|---|
| TCU de El Burgo / Ayora | string con batería | 1 |
| HSU de El Burgo / Ayora | self power con batería | 2 |

- **A)** el nibble es la **alimentación**, como dice el mapa de la TCU: `1 = AC`, `2 = BAT`
- **B)** el nibble es la **clase de equipo**: `1 = TCU`, `2 = HSU` — que es lo que asume hoy `Tipo-Producto`

Todo lo visto cuadra con las dos, porque en estas plantas «TCU» y «string» van
siempre juntos, y «HSU» y «self power» también. **El único equipo que rompe esa
correlación es el repetidor**: es una TCU por clase —misma placa, mismo mapa—
pero está atornillado a un poste, sin string del que comer.

Así que la pestaña *Rep. firmware* saca ahora ese nibble en su propia columna,
sin coste: el registro ya se leía para sacar la versión.

- si el repetidor contesta **2** → gana A, el nibble es la alimentación y queda cerrado
- si contesta **1** → gana B, y entonces la alimentación **no se puede leer** de la TCU: va como campo de proyecto en el inventario

**De qué se alimenta una TCU (v11.45)** — el SCADA quiere marcar en la ficha de
equipo si una TCU es *string power* o *self power*. **El dato existe y ya lo
leíamos sin darnos cuenta**: el mapa v6.1 dice que el nibble bajo del **Product
ID** (30300, y el mismo dato en el offset 0 del bloque compacto que cachea la
NCU) es *«TCU type (BAT/AC/Unknokn)»* — así, con la errata del fabricante. O
sea que no hay que deducirlo de la tensión de panel ni de la corriente de
entrada, que era la heurística que estaba a punto de inventarse alguien.

El nibble sale ahora en cada fila del diagnóstico, en dos campos: `Tipo_raw` (el
número) y `Tipo_alim` (la etiqueta). Sale **gratis** —el registro ya venía en el
bloque y lo tirábamos—, así que es toda la planta de una pasada y sin una
lectura Modbus de más. También en el Inventario, como *Tipo de alimentación*.

⚠️ **Lo que el mapa NO da es la codificación**: no dice qué número es BAT y cuál
es AC. Lo único medido es que en El Burgo las TCUs contestan 1 a ese nibble y
las HSUs 2 — con eso sabemos que el 1 es el tipo de las TCUs de allí, pero no
cuál de los dos. Así que `Tipo_alim` dice **`sin confirmar (tipo N)`** en vez de
inventarse la etiqueta. Para cerrarlo basta un diagnóstico en una planta que se
sepa de string y otro en una de self: se mira el número y se rellena la tabla
`$TCU_TIPO_ALIM`, que está vacía a propósito.

**La meteo de la HSU, también como campos (v11.44)** — la fila de HSU del
diagnóstico llevaba el viento solo dentro del texto (`viento 1,4 m/s (nivel 0),
dir 66 deg; nieve 0 m`), y el panel de meteo del SCADA lo sacaba **parseando esa
frase**. Una coma decimal o un cambio de redacción lo dejaba sin dato, y con
texto no se hacen curvas. Ahora la fila lleva además cuatro campos:
`Viento_ms`, `Dir_deg`, `Nieve_m` y `Nivel`, como números. El texto sigue igual:
es lo que se lee en la tabla.

Una HSU que no contesta va a **`null`**, no a 0: un cero en una curva de viento
es un dato, y ahí no lo hay.

Y de paso, una trampa que llevaba ahí desde siempre: **`Export-Csv` se queda con
las columnas del primer objeto** y tira sin avisar lo que las demás filas
traigan de más. La primera fila de un diagnóstico es una NCU o una TCU, así que
las columnas de meteo no habrían llegado nunca al CSV. Todos los exports pasan
ahora por un normalizador que pone en cada fila la unión de las columnas de
todas; si ya son iguales —el caso normal— devuelve lo mismo que le dieron y no
reconstruye 2289 objetos por gusto.

**Una NCU que no comunica no son 24 TCUs caídas (v11.43)** — el resumen por NCU
decía `NCU14: OK 0 | AVISO 0 | ALARMA 0 | OFFLINE 24`. Y eso se lee como *«las
24 TCUs de la NCU14 han perdido la Zigbee»*, cuando lo que pasaba es que **la
NCU14 no contestaba por la LAN**. Son dos averías distintas y dos cuadrillas
distintas: una es un switch y la otra son veinticuatro equipos en el campo.

Ahora, cuando la fila de la propia NCU sale OFFLINE, su línea dice lo que pasa
y el total de planta separa esos OFFLINE del resto:

```
NCU14: NO COMUNICA POR LA LAN - 24 TCUs sin leer.  NCU SIN RESPUESTA en 192.168.4.14:502 - timeout
Diagnostico: OK 715 | AVISO 5 | ALARMA 1 | OFFLINE 30 (24 por NCUs sin LAN)
```

**La herramienta se ordena por nivel de equipo (v11.43)** — la toolbox creció
por **operaciones** —escribir, leer, diagnosticar, auditar— y las pestañas
acabaron siendo una fila de quince sin más orden que el de haberse ido
añadiendo. En planta no se piensa así: se piensa por **nivel de equipo**.
Primero si la NCU habla, luego sus estaciones meteo, luego los repetidores de
los que cuelga media planta, y al final los seguidores.

La fila de pestañas se sustituye por una **columna de navegación a la
izquierda** con cinco bloques:

| Bloque | Qué lleva |
|---|---|
| **GLOBAL** | Diagnóstico de planta · SAT |
| **NCU** | Diagnóstico · Comm NCU · Estabilidad · Auditoría · Firmware |
| **HSU** | Diagnóstico · Auditoría · Firmware · Lectura de señales |
| **REPETIDORES** | Diagnóstico y batería · Auditoría · Firmware · Buscar repetidor |
| **TCUs** | Diagnóstico · Auditoría · Batería · Firmware · Leer variable · Volcar TCU · Escribir · Trabajos · PEM · Cierre · Utilidades |

Detalles que importan:

- **El diagnóstico sigue siendo UN barrido.** Sus cinco hojas —global, NCU, HSU,
  repetidores, TCUs— son **vistas** del mismo resultado, no cinco lecturas. Una
  pasada ya saca las filas de los cuatro niveles; correrla cinco veces sería
  cinco veces el mismo trabajo contra los mismos equipos, y en San José eso son
  horas. Los exports CSV/JSON siguen llevando siempre el diagnóstico completo.
- **Ya no se abre en «Escribir»**, que es la única pestaña capaz de dejar una
  TCU peor de como estaba. Abre en el diagnóstico de planta.
- Por dentro **las pestañas siguen existiendo**: todo el código que salta de una
  a otra (la auditoría que manda a Escribir, el cierre que manda a PEM, Ctrl+K)
  funciona igual, y el árbol se mueve solo cuando eso pasa. Lo que no se ve es
  su cabecera.
- La ventana pasa de 960 a 1142 px de ancho: los 182 de más son la columna. El
  interior de las pestañas no se ha movido ni un píxel.

**Auditoría y firmware de NCU (v11.43)** — dos pestañas nuevas, y conviene
decir qué se puede y qué no:

- **Firmware NCU es de solo lectura, y no por pereza**: el mapa **R7.1 no expone
  ninguna vía de actualización de la NCU**. Lo único que hay es la versión como
  texto en el registro 50. Se leen además **HardwareId (registro 0)** y
  **SoftwareId (registro 1, bits 15..8)**, que el propio mapa marca *NOT READY*
  y hoy contestan 0: se pintan como `-` en vez de 0, porque un cero en una
  columna de versión parece un dato bueno y no lo es. El día que Sunner los
  rellene, la columna ya está hecha.
- **Auditoría NCU** compara las NCUs **entre sí**: no hay valor de fábrica con
  el que contrastar en ningún sitio, así que el criterio es que en una planta
  bien puesta las 16 llevan lo mismo, manda la mayoría y se marca la minoría.
  Lleva **toda** la hoja *NCU RW registers* del mapa R7.1, que es corta:

  | Registro | Qué es |
  |---|---|
  | **40001–40007** `force_sp_1..7` | RW, un bit por **grupo** de TCUs (bit 0 = grupo 1 … bit 9 = grupo 10). Son **peticiones** de posición segura: la 1 es viento, la 3 nieve, la 4 limpieza. En operación normal valen `ninguno`; un bit puesto es un grupo abanderado a mano que alguien se dejó, y la consola lo canta aparte. |
  | **40070 / 40071** `auto_mode` / `manual_mode` | **Solo escritura.** No es que falte la dirección: el mapa no deja leerlos, así que **el auto/manual por grupo no es auditable**. Se dice en la consola en vez de callarlo. |
  | **40080** `custom_position_timeout` | RW, U16, en **segundos**. |

  Los bitsets se pintan como lista de grupos (`1,3,4`) y no en hexadecimal: un
  `0x000D` no se lee en campo.

**Auditoría y firmware de HSU (v11.43)** — la auditoría es el `LEER CONFIG` de
siempre pero de toda la planta a la vez y puesto como auditoría: lo que importa
no es el umbral de una estación, es que las diez lleven el mismo. Un umbral de
viento distinto en una zona es una zona que se pone a bandera cuando las demás
no. El número de esclavo se excluye de la comparación: es distinto en cada una
**por diseño**, y compararlo sacaría una discrepancia en todas tapando las de
verdad.

El firmware de HSU **sí tiene vía de actualización**, al contrario que el de la
NCU: el mapa **R23** dice literalmente *«Master must write 0x55AA to install the
new FW»* en **`flagUpdateFW` (51019)**. La pestaña lo hace, con todas las
cautelas: una estación cada vez, con el esclavo escrito a mano, comprobando
antes que **no haya alarma de viento** (la orden reinicia la estación y esa zona
se queda sin guarda mientras arranca), con **confirmación escrita** —hay que
teclear el nombre de la estación, un Sí/No se pulsa sin leerlo—, dejando
constancia en el registro de acciones y **releyendo la versión** después. ⚠️ **No
se ha probado nunca en campo**, y no sube ningún binario: ordena instalar el que
la estación ya tenga cargado con el updater de Sunner.

**Bloque de repetidores (v11.43)** — un repetidor es una TCU de verdad —mismo
mapa, misma batería, mismo firmware— pero atornillada a un poste, y hasta ahora
solo salía como una fila más del diagnóstico. Ahora tiene bloque propio:

- **Auditoría** con su propio juego de parámetros. Auditarlos contra la
  referencia de un seguidor sacaba media tabla en rojo por posiciones seguras,
  límites de eje y viento que en ellos no significan nada. Se comparan solo
  entre repetidores y solo lo que aplica a un equipo fijo: carga, batería,
  calefactor y comunicaciones. Fuera también el **número de esclavo** (200, 201,
  202: distinto en cada uno por diseño) y los bits de *apply*, que son órdenes.
- **Firmware**. El plan de actualización va por **tramos de TCU** de cada
  gateway, y el esclavo de un repetidor cae **fuera** de ese tramo: hasta ahora
  no entraban en ningún plan y se quedaban con el firmware viejo. Cada uno sale
  con su **ventana propia del updater**, y con su SoC al lado (no se actualiza
  un equipo por debajo del 50 %).
- **Buscar repetidor**: barre los esclavos 200–210 por cada gateway de las NCUs
  seleccionadas y dice cuál contesta y si está o no en la topología. Es lo que
  hace falta para la **RSU 10 de la NCU16 de Ayora**, que no ha comunicado
  nunca.

**Pestaña Estabilidad, y la versión de la NCU (v11.41)** — pedimos «calidad de
enlace por TCU» y el mapa Modbus de Sunner **no expone RSSI ni LQI**: revisados
el NCU R7.1 y el TCU v6.1, de la Zigbee solo hay bits de sí/no
(`AlarmZigbee`, `XbeeDefective`, `CommLostNCU`). No hay potencia de señal que
leer, y no la vamos a inventar.

Lo que sí se puede es medir la calidad **por su efecto**. Muestreando el
`lastComm` de cada TCU sale qué porcentaje del tiempo está fresca, cuántas veces
se cae y cuánto tarda en volver. Una TCU al límite de cobertura no aparece con un
RSSI bajo: aparece con caídas frecuentes y edades altas.

**MEDIR ESTABILIDAD** durante N minutos con una muestra cada N segundos, y una
tabla con las **peores primero**: `% fresca`, `caídas`, `edad máxima` y un
veredicto (`estable` ≥ 99,5 % sin caídas · `intermitente` ≥ 95 % · `mala` ·
`sin comunicacion`). Solo lee el bloque 502: no toca la Zigbee ni mueve nada, y
CANCELAR para y se queda con lo medido hasta ese momento.

En el rótulo y en la confirmación se dice que es **calidad inferida, no potencia
de señal**. Un dato con una etiqueta honesta vale; uno que aparenta ser lo que no
es, no.

De la **configuración de red de la NCU** (IP, máscara, PAN ID) no hay nada en el
mapa: no está expuesta por Modbus y se toca desde el propio interfaz de la NCU.
Lo que sí publica y no leíamos es su **versión de firmware** (registro 50, texto),
ahora en la columna `FW` de *Comm NCU*: sabíamos el firmware de cada TCU y no el
de la NCU que las gobierna.

**Pestaña Comm NCU (v11.40)** — lo que cada NCU dice **de sí misma**, una fila
por NCU: si contesta, sus **gateways**, el **UPS** (batería y alimentación), la
**seta**, el **reloj** y su desvío, cuántas de sus **TCUs** le hablan y cuántas
**HSUs**. Sale del bloque 502: unas cinco lecturas por NCU, la planta entera en
segundos y sin tocar la Zigbee.

Todo eso ya existía, pero repartido entre el diagnóstico, las alertas del
vigilante y la consola — y una NCU se mira entera o no se mira. El día que
saltaron las protecciones de los switches en Ayora, esta pestaña habría dicho en
diez segundos lo que costó media mañana.

Dos cosas que hace bien a propósito:

- **distingue «no lo tiene» de «lo tiene mal»**: un gateway que la topología no
  declara sale `-`, no `CAIDO`. En Ayora todas las NCUs llevan uno solo;
- **la NCU que no contesta sale igual**, con `SIN RESPUESTA`, y sin inventarse
  el estado de su UPS ni de sus gateways.

El contador de TCUs se puede desmarcar: es barato (2 registros por TCU, de 50 en
50) pero en San José son 21 NCUs de 120 seguidores.

**Los estados de batería, en minúsculas (v11.39)** — `NO ENTRA CORRIENTE`,
`FUERA DE LA FLOTA`, `PANEL SIN TENSION`… salían **en mayúsculas** en la columna
*Estado*. Gritan sin necesidad y ensucian la tabla. Ahora van como `No entra
corriente`, `Fuera de la flota`, `Panel sin tension`.

Las mayúsculas se quedan donde sí significan algo: `OK`, `AVISO`, `ALARMA`,
`OFFLINE` y `SIN LECTURA` son vocabulario cerrado, compartido con la plataforma
y con el CONTRATO, y ahí la forma es parte del dato.

Sin acentos, como el resto de textos de la herramienta.

**La auditoría compara el VALOR del hexadecimal, no el texto (v11.38)** — la
comparación pasaba a minúsculas *«si alguno empieza por `0x`»*, y
`"0X0A00".StartsWith("0x")` es **falso** en PowerShell: distingue mayúsculas.
Con la `X` mayúscula en los dos lados se caía a comparación de texto. Funcionaba
—porque el valor leído sale siempre del formateo interno, en minúscula— pero por
casualidad, no por diseño.

Ahora se convierte a número y se comparan valores: `0X0A00`, `0x0a00`, `0xA00` y
`2560` son **el mismo registro** y ninguno cuenta como desviación. Lo que no es
un número sigue sin colarse como cero: `0x0A00` contra `AUTO` o contra vacío es
desviación, como debe ser.

**APLICAR MODO ya no escribe en las que ya están (v11.37)** — antes escribía en
todas y luego verificaba, y la verificación son hasta **3 s por TCU**. Ahora lee
primero el modo actual (30001, un registro) y las que ya están en el modo pedido
se saltan: salen como `ya estaba en modo AUTO (no se ha escrito)`. Las que
cambian dicen de dónde vienen — `MANUAL -> AUTO`— y al final hay un recuento:
*«X ya estaban, Y cambiadas, Z con fallo»*.

En una planta donde casi todo está ya en AUTO, eso es la diferencia entre
minutos y una hora — y, sobre todo, es no escribir en 700 equipos para no
cambiar nada.

**El diagnóstico de planta salía sin una sola fila de NCU (v11.37)** — el JSON
del barrido de Ayora del 11/08 trae **765 filas**: 751 TCUs, 9 HSUs y 5
repetidores. Faltan **17**: las **16 NCUs** y la **HSU de la NCU16**.

Dos causas distintas, las dos por el mismo descuido — dar por hecho que lo que
hace un camino lo hace el otro:

- **El barrido *en paralelo* no ponía la fila de salud de la NCU.** El de serie
  sí, pero el paralelo es el **modo por defecto**, así que en la práctica nunca
  salía: la planta entera se quedaba sin GW, sin UPS, sin seta y sin reloj de
  ninguna de sus 16 NCUs. Ahora el hilo lee `Ncu-Salud` como el de serie —
  ambos por la misma función, `Diag-FilaNcu`— y la fila se pone **aunque la NCU
  no conteste**, que es justo cuando más falta hace.
- **La flota declarada solo se completaba en el INFORME HTML.** La tabla y el
  JSON que sube a la plataforma se quedaban con lo leído, así que la HSU de la
  NCU16 —que no ha comunicado nunca— desaparecía. Ahora `Diag-Completar` corre
  también al terminar el diagnóstico.

Y con eso salió un tercero: **las HSUs no se pueden comparar por etiqueta.** El
número de una HSU leída es el hueco que ocupa en la caché de su NCU (`HSU8`,
`HSU10`…) y no tiene por qué coincidir con el orden en que la topología las
lista. Compararlas por nombre habría metido **una HSU fantasma por cada una que
sí se lee**. Se comparan por **cuenta** dentro de cada NCU: si la topología dice
dos y contesta una, falta una; y solo se le pone nombre si no hay ambigüedad.

**Tres restos del mismo agujero (v11.36)** — la v11.35 arregló la lectura con una
NCU suelta, pero quedaban tres sitios que seguían sin enterarse:

- **la flota declarada rehacía el rango sin los huecos**, así que la TCU 14 de la
  NCU7 volvía por la puerta de atrás como `SIN LECTURA`: 24 filas donde debía
  haber 23. Un equipo que no existe no puede faltar;
- **`GW2 DESCONECTADO` seguía saliendo** con una entrada de NCU suelta: el
  enmascarado de la v11.33 pedía lista de gateways y ahí solo hay un puerto —
  que **es** su gateway;
- y una NCU **sin estaciones declaraba una `HSU1` fantasma**, otra vez por
  `@($null).Count`, que en PowerShell 5.1 vale **1**. Van tres veces con ésta.

**Con UNA NCU suelta, los huecos se ignoraban (v11.35)** — en Ayora NCU7 seguían
saliendo la 14, la 24 y la 25 como OFFLINE en cada barrido, con la v11.32 ya
puesta. El motivo: **todo lo que la topología sabe de una entrada viajaba solo
por la vía de los gateways** —las entradas *(auto)* y *(Planta completa)*—, y
`Params-Conexion` con un puerto fijo devolvía IP y puerto y tiraba el resto. Con
la entrada de una sola NCU se perdían los **huecos**, los **repetidores**, las
**HSUs** y la flota declarada.

Tres cosas cambian:

- la entrada de una NCU **lleva consigo** sus huecos, repetidores y HSUs;
- `Plan-Segmentos` descuenta los huecos **también sin lista de gateways**, y
  dice cuáles ha saltado en vez de hacerlo en silencio;
- al elegir la entrada, el cuadro de TCUs se rellena ya **sin los huecos**:
  `1-13,15-23` en vez de `1-25`. Antes ese `1-25` era una selección explícita
  que volvía a pedir los tres equipos inexistentes.

**El gateway que no existe no puede estar «desconectado» (v11.33)** ✅ *verificado
en Ayora el 11/08/2026: el vigilante pasó de 19 alertas a 4, y las 4 son reales.*
— el primer
arranque del vigilante en Ayora soltó **19 alertas, y 15 eran falsas**: una
`GW2 DESCONECTADO` por cada NCU. En Ayora **todas las NCUs llevan un solo
gateway**, así que el bit del segundo está permanentemente a 1 — no hay nada
conectado ahí porque no existe ese gateway.

Ahora `Ncu-Salud` recibe los gateways que **declara la topología** y apaga el bit
de los que no están, tanto para el texto como para la salud. Si la topología dice
que la NCU tiene los dos, sigue cantando igual. Y **sin topología no se inventa
nada**: se comporta como antes, porque callar una alarma real es peor que dar una
falsa.

Un falso positivo repetido 15 veces no es un detalle estético: las tres alarmas
de verdad de ese arranque —dos cortocircuitos de motor y una seta pulsada—
estaban enterradas entre el ruido.

De paso, el agente ya solo menciona el reloj de la NCU **cuando está desviado**
(`Reloj-Nota`, como la toolbox). Colgado de cada alerta parecía parte del
problema, y era solo la hora.

**La HSU puede colgar del SEGUNDO gateway (v11.32)** — la topología dice cuántas
estaciones tiene cada NCU y con qué esclavos, pero **no de qué gateway cuelga
cada una**. Hasta ahora las lecturas directas (LEER METEO, LEER CONFIG,
umbrales, reloj, caja negra) preguntaban siempre por el **puerto más bajo**, así
que una estación en el GW2 salía muda y parecía averiada. En **Burgo I** cada NCU
lleva justo eso: una en el GW1 y otra en el GW2 — dos de sus cuatro HSUs no se
podían leer.

Ahora se **prueban los gateways de esa NCU hasta que uno contesta**, y no hay
ambigüedad posible porque **el número de esclavo no se repite dentro de una NCU
aunque sean gateways distintos** (Burgo I: 230 en el GW1, 231 en el GW2). El que
responda es el suyo. La consola dice por cuál contestó, el gateway bueno se
recuerda para el resto de la sesión —así no se pagan dos intentos cada vez— y las
**escrituras usan ese mismo**, que es donde equivocarse dolía de verdad.

Si no contesta por ninguno, la fila lo dice (*«probados los gateways 503 y
504»*) en vez de dejar caer un «sin respuesta» a secas: no es lo mismo una
estación muerta que una buscada donde no estaba.

Lo que ya funcionaba y no cambia: **BUSCAR HSUs y el diagnóstico** ven todas las
estaciones igual, porque van por la caché de la NCU (puerto 502), que no
distingue gateways.

**El export decía de dónde venía mirando los cuadros, no lo que había leído
(v11.31)** — un diagnóstico de **planta completa** (724 TCUs) seguido de un
cambio de modo en la **NCU3** salía exportado como *«Ayora · NCU3 ·
192.168.4.30 · 724 TCUs»*. Los datos eran correctos; la cabecera, mentira.

La causa: los exports leían `planta`, `ip` y `puerto` **de los cuadros de la
pestaña Conexión en el momento de pulsar el botón**, no de lo que se barrió.
Entre el barrido y el export puede pasar cualquier cosa — y en campo pasa
siempre, porque después de diagnosticar se va a arreglar lo que ha salido.

Ahora cada operación **congela su procedencia** al lanzarse (`Ctx-Sello`) y el
export usa ese sello. Afecta a diagnóstico, test comm, baterías, lectura de
variables, auditoría, inventario, seguimiento PEM, el informe HTML y el parte de
WhatsApp. Los JSON llevan además dos campos nuevos que antes había que adivinar
del nombre: **`alcance`** (`Planta completa (16 NCUs)` / `NCU3` / `ip:puerto`) y
**`ncus`** con los números realmente recorridos.

Si se cargan datos de la pestaña **Trabajos** (de otra sesión) no hay sello que
valga y se cae a los cuadros, como antes.

**Escribir en la planta entera y no poder guardarlo (v11.30)** ✅ *verificado en
Ayora el 11/08/2026: escritura en TCUs de las NCU12, 13 y 14 y `GUARDAR EN NVM`
seguido, 3 de 3 guardadas.* — *ESCRIBIR*
aceptaba la entrada **(Planta completa)** desde la v5.7, pero **GUARDAR EN NVM**
no: se plantaba con *«la entrada (Planta completa) solo está soportada en
Diagnóstico y Flota; elige una NCU concreta»*. Es decir, se podía escribir en
media planta y después **no** poder fijar los valores en memoria no volátil, con
lo que **se perdían al reiniciar la TCU**. Lo mismo pasaba en *Sincronizar
reloj*, *Backup NCU* y en las cuatro acciones de PEM (**modo**, **limpiar
alarmas**, **stow** y **fijar comisionado**), que es donde más duele: un cierre
de puesta en marcha necesita parámetros + NVM + modo AUTO, y si el trabajo
tocaba varias NCUs había que repetirlo NCU por NCU.

Ahora todas recorren la planta NCU a NCU igual que *ESCRIBIR*, con barra de
progreso y la NCU delante en cada línea de la consola. Detalles que van con ello:

- el **test de motor** también, con el tiempo estimado en la confirmación (son
  ~2 pulsos por seguidor: en una planta entera son horas) y con la **guardia de
  viento por NCU** — cada una tiene su HSU, así que se consulta la de la NCU que
  toca y, si hay viento, se salta esa NCU entera y sigue con las demás;
- el **backup masivo** guarda los ficheros como `backup_ncuX_tcuY_…json`: sin la
  NCU delante, la TCU 12 de la NCU3 pisaba a la TCU 12 de la NCU4. Y avisa antes
  de empezar si el backup pasa de 20 000 lecturas, que se cuenta en horas;
- contar las TCUs de un trabajo es ahora una sola función (`Cuantas-Tcus`) que
  filtra nulos: `@($null).Count` vale **1** en PowerShell 5.1, así que una NCU
  sin TCUs sumaba una de mentira.

**Ayora son 751 seguidores, no 754 (v11.27)** — la **NCU7** declara tres números
que no están instalados (**14, 24 y 25**): salían OFFLINE en todos los barridos y
engordaban el recuento de la planta. Con ellos fuera, Ayora son **751**
seguidores. Los porcentajes de los diagnósticos anteriores estaban calculados
sobre 754, así que salían **algo mejores de lo real** — tres equipos inexistentes
contados como caídos, sobre un total inflado.

**TCUs que no existen (v11.26)** — el rango de un gateway es `1..N` y **no sabe
de huecos**: si dentro del rango hay un número que no está instalado, se lee en
cada barrido, no contesta nunca y sale **OFFLINE para siempre**, ensuciando el
recuento de la planta y el parte de averías.

La topología admite ahora `huecos` por entrada:

```json
{ "nombre": "Ayora NCU7", "ip": "…", "puerto": 503, "tcu_ini": 1, "tcu_fin": 25,
  "huecos": [14, 24, 25] }
```

Esos números **no se leen, no se pueden pedir** (ni escribiendo el rango entero)
y **no cuentan como flota declarada**: no son equipos sin leer, es que no
existen. Es la forma limpia de lo que en El Burgo se resolvía partiendo la NCU en
dos entradas.

**Salir de OFFLINE es mejorar, y el diff dice de qué es el aviso (v11.25)** —
recuperar un equipo **siempre** mejora, aunque vuelva con un aviso: antes no se
sabía nada de él y ahora **comunica**. Un equipo que habla con una pega es mejor
noticia que un equipo mudo. Hasta ahora `OFFLINE → AVISO` y `OFFLINE → ALARMA`
salían como *neutro*.

Y `OK → AVISO` a secas obliga a salir a mirar para saber de qué: la comparación
pega ahora **la nota del equipo** al estado nuevo — `AVISO (dif 6,2 deg)` — en la
tabla y en el CSV. Mismo cambio en el Seguimiento PEM de la plataforma, para que
las dos digan lo mismo.

**El informe lleva TODOS los equipos, comuniquen o no (v11.24)** — el informe se
armaba **solo con lo leído**, así que una NCU a la que no se llega desaparecía
con todas sus TCUs: en un Ayora con la NCU4 y la NCU5 caídas, el informe hablaba
de **681** equipos en vez de 754, y las cuentas no cuadraban con la planta.

Ahora se completa con lo que la **topología dice que hay** —NCUs, TCUs, HSUs y
repetidores— y lo que no ha contestado sale como **`SIN LECTURA`**, que es lo
que de verdad se sabe de ese equipo: no es un OK, pero tampoco un OFFLINE
comprobado. Además, un **repetidor ya no cuenta como seguidor** en el porcentaje
de *Seguidores operativos* (se colaba en el filtro, que solo excluía `NCU` y
`HSU*`), y la tabla del diagnóstico gana la columna **GW**.

**Tres cosas que decían lo que no era (v11.23)**

- **Los repetidores seguían saliendo con alarmas de posición.** La desviación no
  llega como bit de alarma sino como **nota de texto** (`dif 63,7 deg`), así que
  la lista de la v11.22 no la cazaba y los cinco salían en AVISO por una posición
  que en un equipo fijo no significa nada. Ahora va por patrón.
- **«la NCU nunca ha leído este TCU»** afirmaba más de lo que dice el dato. Un
  `lastComm` a 0 significa *no tengo lectura*; una NCU recién reiniciada tiene
  toda su caché a cero, y eso no es «nunca».
- **El resumen por NCU salía desordenado y se callaba lo peor.** Agrupaba en el
  orden en que se añadían las filas, así que una NCU cuyas únicas filas eran las
  de su repetidor —que se leen al final— aparecía la última. Y una NCU a la que
  **no se ha podido llegar** desaparecía del resumen sin más: ahora sale como
  `SIN LECTURA` con cuántas TCUs se han quedado sin leer. Las HSU y los
  repetidores dejan además de contar dentro de la NCU: van aparte, como en el
  total.

**Los repetidores dejan de ser invisibles (v11.21)** — un repetidor **es una
TCU**: mismo mapa, misma batería, mismo firmware. Lo único distinto es que está
colocado para repetir la señal, no para mover un seguidor. Su esclavo cae
**fuera** del rango `1..N`, así que hasta ahora **no se leía nunca**: no entraba
en el inventario, ni en la campaña de firmware, ni en la auditoría de baterías.
Y es el único equipo de la planta cuyo fallo es multiplicativo — con la batería
muerta se lleva por delante todo lo que cuelga de él.

Ahora la topología los declara (`repetidores` por gateway, con su nombre y su
esclavo; la plataforma los exporta desde las columnas *Repetidores GW1/GW2*) y el
**Diagnóstico los lee**, uno a uno por su esclavo a través de la NCU. Salen en la
tabla con su nombre — **Repetidor 1**, *Repetidor 2*… — y **cuentan aparte**,
como las HSU: Ayora sigue siendo **754 seguidores**, y los repetidores llevan su
propia línea. Así los porcentajes siguen cuadrando con el SCADA y con todos los
diagnósticos anteriores.

Su **salud no es la de un seguidor**, y sus **alarmas tampoco**: está fijo, no
mueve nada. Las de posición y motor —*tilt fuera de rango*, *eje bloqueado*,
*sobrecorriente de motor*, *motor más lento de lo esperado*, *fallo en driver de
motor*, *V motor alta/baja*, *límite Este/Oeste*, *alarma de motor enclavada*—
**no se muestran ni cuentan para su salud** (v11.22): sacarlas solo serviría
para que alguien salga a mirar un eje que no existe. Lo que sí cuenta: **si
comunica y su batería**.

En Ayora son cinco: uno en la NCU4 (esclavo 200), dos en la NCU12 (200 y 201),
uno en la NCU14 (200) y uno en la NCU15 (200). El mismo número se repite entre
NCUs y es correcto: cada NCU es su propia red Zigbee.

**Comparar dos trabajos guardados (v11.20)** — lo que en la plataforma hace el
Histórico, ahora sin salir de la herramienta y sin subir nada: en campo la
pregunta es *"¿qué ha cambiado desde la última visita?"*, y hasta ahora había que
abrir los dos CSV en Excel.

En **Trabajos**, botón **COMPARAR**. Marcando **dos** trabajos compara esos dos
(el más antiguo hace de "antes", se marquen en el orden que se marquen);
marcando **uno**, contra el anterior del **mismo tipo y planta**, que es lo que
hace sola la web. Dos tipos distintos no se comparan.

El resultado sale **en la consola** (rojo lo que empeora, verde lo que mejora,
gris lo neutro — se copia y se pega como el parte de averías) **y en una ventana
aparte** con su tabla filtrable y su **CSV**.

Qué se mira en cada tipo — el resto de columnas es ruido; en un diagnóstico de
754 TCUs el tilt cambia en todas y no dice nada:

| Tipo | Qué se compara |
|---|---|
| Diagnóstico / Test comm | el cambio de **Salud** |
| Inventario | el cambio de **FW** |
| Auditoría | **desviación nueva** (a peor), **resuelta** (a mejor) o cambio del valor leído |
| Baterías | **SoH** y **Estado** (cualquier cambio) y el **SoC** solo si salta ≥ 10 puntos |

Dos reglas heredadas del Histórico, y por las mismas razones: **OFFLINE no es un
punto más de la escala** —pasar de ALARMA a OFFLINE no es una mejora, es dejar de
saber— y se comparan **solo las NCUs comunes** a los dos trabajos, diciéndolo
cuando el alcance es parcial. Comparar una planta completa contra una sola NCU
tiene sentido para esa NCU; decir que las otras quince "ya no aparecen", no.

En la plataforma esto **no** se añade: la web no recibe registros de baterías
—solo diagnósticos, comisionado, inventarios y auditorías—, así que un diff de
baterías allí sería código muerto.

**El GW también en las entradas de una sola NCU (v11.19)** — con una entrada de
puerto fijo no hay lista de gateways, así que la columna **GW** salía **vacía**
en todas ellas. Y no solo en la ventana: esos mismos JSON son los que se suben
al Histórico y los que lee la web, así que allí tampoco se veía. Pero el puerto
de esa entrada **es** el gateway, y ahora se usa. (En el barrido en paralelo se
pasa solo la lista de gateways: su puerto es el 502 de la NCU, que no es
ninguno.) En el Histórico, además, lo que falte se saca de la **topología** —
la misma tabla que pinta la columna GW en la página de IPs.

**Las NCUs se eligen una vez, el GW baja a cada pestaña (v11.18 / agente v2.7)**

Faltaba lo más básico: **no había dónde decir "estas NCUs"** salvo en
Diagnóstico. Para leer, escribir, auditar o inventariar varias NCUs había que ir
una a una por el desplegable de Conexión, que solo admite **una** entrada.

Ahora, en **Conexión**, junto al desplegable de planta, un cuadro **`NCUs`**:

| se escribe | qué hace |
|---|---|
| vacío | todas las de la entrada elegida |
| `1,3-5` | solo la 1, la 3, la 4 y la 5 |
| `12` | solo la 12 |

Se elige **una vez** y vale para **todas las pestañas** — Escribir, Leer,
Diagnóstico, Auditoría, Inventario, Sincronizar reloj, PEM, NVM, Backup NCU,
Cierre, Baterías y Trabajos. Con una entrada de **una sola NCU** el cuadro se
apaga: esa es la única que se toca y el filtro no pinta nada. Y si en el cuadro
**TCUs** se escribe `12/10, 15/5-12`, mandan esas: la selección ya dice sus NCUs.

El cuadro **`GW`** hace el camino contrario: **sale de Conexión y baja a cada
pestaña**, al lado de su cuadro TCUs — que es donde se mira cuando se está
eligiendo sobre qué se actúa. Está en las ocho: Escribir, Leer variable,
Diagnóstico, Auditoría, Inventario, Sincronizar, PEM y Backup NCU.

Y el diagnóstico ordena las columnas **NCU · GW · TCU**, que es el orden en que
se llega a un seguidor en planta.

En **remoto** va lo mismo: el agente v2.7 acepta `ncus`, `tcus` y `gw` en la
query y los aplica **en el punto por donde pasan todas sus rutas**, no solo en
`/leer` y `/inventario` como hasta ahora — antes esos cuadros de la web no
hacían nada en el diagnóstico, las baterías ni el comisionado. `/ping` dice
además qué gateways existen, para que la web los ofrezca en un desplegable en
vez de hacer teclear el número de puerto.

**Dos cosas mal en la tabla de Leer variable (v11.17)**

**Las cabeceras salían las de la lectura anterior.** Se guardan en memoria para
poder marcarlas con la flechita del filtro, y esa copia solo se hacía **una vez**.
*Leer variable* rehace las columnas en cada lectura —una por variable—, así que
la copia vieja se escribía encima: con cinco variables, los tres primeros
nombres salían `TCU`, `Valor` y `Estado` en vez de `NCU`, `TCU` y la primera
variable. Es decir, **la columna rotulada `Valor` era en realidad el número de
TCU**. Ahora se recachean cuando cambia el número de columnas, y los filtros
guardados —que van por número de columna— se tiran con ellas.

**Y `Estado` no quería decir lo que parecía.** Con un preset cargado, un `OK` en
esa columna se lee como *«coincide»*, y no lo es: esta pestaña **lee, no
compara**. `OK` significa que la TCU contestó. Quien compara contra el preset es
la **Auditoría**. La columna pasa a llamarse **`Respuesta`**, y al terminar una
lectura se dice en la consola. El nombre de la propiedad no cambia (`Estado`),
porque el CSV y la auditoría van por él.

**El gateway, también en remoto (v11.16 / agente v2.6)** — la web enseñaba el
diagnóstico sin la columna `GW` aunque el agente ya la mandaba, y no tenía el
cuadro **GW** que aquí existe desde la v11.6.

Ahora `/leer` e `/inventario` aceptan `gw=504` y la gramática completa de `tcus`
(`12/10, 15/5-12`), y `/leer`, `/inventario` y `/baterias` traen la columna `GW`.
El filtro se resuelve **en el agente**, así que además no se lee lo que no
interesa — que en un inventario de 754 TCUs es la diferencia entre usable y no.

**En la web, las NCUs se escriben (v11.15 / agente v2.5)** — el campo de NCU de
la *Toolbox web* era un **desplegable**, así que no se podía escribir en él, y
solo dejaba **una** NCU. Aquí, desde la v11.6, se puede decir
`12/10, 15/5-12` y cruzarlas.

El agente acepta ahora esa misma gramática en todas las escrituras: con la NCU
delante de cada tramo, el campo `ncu` sobra y cada fila de la respuesta dice de
cuál es. El desplegable de la web se queda, pero solo **rellena** el cuadro.

**Las que no contestan, con su NCU (v11.14)** — las filas `SIN RESPUESTA` del
plan de firmware se pintaban **todas juntas al final** de la tabla. Una TCU que
estaba reiniciándose con el firmware nuevo sale muda —lo cual es normal—, pero su
fila caía cincuenta líneas más abajo, detrás de las otras quince NCUs. Buscarla
allí es no verla.

Ahora van **debajo de su propia ventana**, junto a las TCUs pendientes de esa
misma NCU, y la fila de la ventana avisa de cuántas hay. Las de NCUs que no
tienen ninguna ventana —todo lo suyo al día, o mudo— siguen al final, que es
donde les toca.

**La ventana con huecos dibujaba un rango que no existe (v11.13)** — en el plan
de firmware, la fila **VENTANA** ponía en `Desde` y `Hasta` el primero y el
último de sus tramos. Con la NCU10 pendiente de la `10-16` y la `18-22` salía
**«de 10 a 22»**, y entonces:

- la **TCU 17** parecía estar dentro del rango de arriba y **no tenía fila
  abajo**, porque no está pendiente;
- y la columna `TCUs` decía **12** cuando del 10 al 22 hay **13**.

Quien leyera las columnas en vez de la nota pegaría `Add from 10 to 22` en el
updater y flashearía una TCU que ya estaba al día. Ahora, cuando la ventana tiene
más de un tramo, esas dos columnas dicen `(varios)` y los rangos de verdad están
donde deben: en las filas **PEGAR**, que con más de un tramo siempre salen.

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

Y en **cada pestaña**, al lado de su cuadro TCUs, un cuadro **`GW`**: con `504`
se trabaja sobre **todas las TCUs de ese gateway** de cada NCU, que antes
obligaba a ir NCU por NCU con el rango a mano. Vacío = todos. (Hasta la v11.17
vivía en Conexión; desde la v11.18 está en las ocho pestañas que seleccionan
TCUs.)

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
  todos los paneles están a 0 V, y salían seis `Panel sin tension` de TCUs
  sanas. El bit 7 del MSR dice si es de día; sin él —o si no se sabe— no se
  miran ni el panel ni la corriente de entrada ni el `No carga`.
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
*«No carga»* y mandan a mirar sitios distintos: **el panel no da** (`Panel sin
tension`) y **el panel da pero no llega** (`No entra corriente`). Solo se miran
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
> ⚠️ **Una celda de «Esclavos» que no se sabe leer tira la NCU entera del fichero.** No es un rango mal puesto: es una NCU que la toolbox no lee jamás —ni inventario, ni firmware, ni baterías, ni cobertura— y solo se descubre cuando alguien va a la planta y le faltan seguidores. Pasó dos veces con el mismo fallo y separadores distintos: San José perdió cinco NCUs con las celdas de varias **líneas**, y Ayora la NCU7 con `1-13 15-23`, separada por un **espacio**. Ahora se parte por líneas, comas, puntos y coma y espacios (`1 - 13` sigue siendo un tramo, no los TCU 1 y 13), y una celda con texto que no da ningún tramo se **canta por consola** con la NCU y la celda. Comprobado en `test_tramos.py` (21 comprobaciones, 5 mutaciones).

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
| `Salud baja` (AVISO) | SoH por debajo del 60 %: la batería ya no aguanta |
| `Carga baja` (AVISO) | SoC por debajo del 40 % — por debajo del mínimo del bootloader no se puede actualizar |
| `No carga` (AVISO) | corriente casi nula con la batería a medias: panel, fusible o cargador |
| `Temperatura` (AVISO) | por encima de 55 °C o por debajo de −20 °C |
| `Panel sin tension` (AVISO) | el panel está por debajo de 2 V con la batería a medias: panel, cableado o fusible |
| `No entra corriente` (AVISO) | el panel da tensión pero entran menos de 30 mA: da y no llega |
| `Fuera de la flota` (AVISO) | está *dentro* de rango pero se sale de lo que tienen las demás (más de 3 V o 30 puntos de SoC por debajo de la mediana) |

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

**El CSV de meteo del cronómetro guardaba el texto y tiraba los números** — el
cronómetro de D.2 ya leía la caché de HSUs de la NCU en cada ciclo (bloque
30200, una `FC03`, sin Zigbee) y ya dejaba un CSV de meteo aparte, en el **mismo
eje de tiempos** que las posiciones. Pero de cada HSU guardaba solo `Salud` y la
frase (`"viento 12,4 m/s (nivel 2), dir 288 deg"`). `Ncu-HsuCompat` devuelve
esos mismos valores como **campos numéricos** justamente para no tener que
volver a parsear la frase — su propio comentario lo dice—, y el único consumidor
donde la meteo acompaña a una medida **contractual** era el que los tiraba.

Ahora la fila lleva `Viento_ms`, `Dir_deg`, `Nivel` y `Nieve_m`, con hueco
(`$null`) y no cero cuando la HSU no contesta. La fila sale a `Cron-FilaMeteo`,
pura y con banco, por el mismo motivo que `Aband-FilaCsv`: se construía dentro
del temporizador, fuera del alcance de las pruebas.

**Qué NO es esto.** No hay veredicto, ni marca, ni nota en el informe. Es una
columna. La razón de registrarla es que **no se recupera**: una suelta pasiva
cae al tope del lado del que sopla y un motor agarrotado cae siempre al mismo,
así que con las dos series esa diferencia se podrá llegar a mirar algún día —
pero un ensayo hecho sin la columna es un ensayo perdido para esa pregunta, para
siempre. Y con un solo ensayo no se contesta: en un sitio con rumbo dominante,
la suelta pasiva perfecta y la mecánica agarrotada dan la misma tabla durante
meses. Hasta que no haya episodios con rumbos distintos, esto **no es un
discriminante**.

**La maqueta audita también DESBORDES** (del banco, no del producto: no lleva
número de versión porque no cambia la herramienta) — auditaba que nada se montase
encima de nada al *agrandar* la ventana, y no lo contrario. Por ese hueco se
coló un defecto real: cinco campos de la pestaña SAT se colocaron de x=892 a
x=1222, con ~919 px útiles de pestaña.

Lo que le pasa a un control que se sale **no es desaparecer**: `Layout-Rescatar`
lo **mueve** al borde de su contenedor al arrancar. Aquellos cinco campos no
habrían estado invisibles —eso se dijo mal en el PR #201—, habrían aparecido
amontonados contra el borde derecho, unos encima de otros y encima de la fila
del cronómetro. Peor, no mejor: un control invisible se echa en falta; uno que
aparece donde no toca **se rellena creyendo que es otro**.

Y no es estética. Esos cinco campos existen **para no dar por supuesto el
criterio de una planta** (si abandera cara al sol o cara al viento, el límite de
mediodía, el lado de la suelta pasiva); fuera de sitio, daban por supuesto el
criterio de una planta. Un control que no está donde se le puso es un default
silencioso con otro disfraz.

La ventana no puede encogerse por debajo de su `MinimumSize`, así que ese tamaño
es el **peor caso real** y la comprobación es exacta, no una estimación. El alto
útil sale de `$pnlCuerpo`, que es lo que de verdad recorta, y **no** se le
descuenta la fila de solapas: `Nav-OcultarCabecera` la saca fuera del panel a
propósito. Descontarla daba 368 px donde hay ~394 y marcaba diez notas al pie
que caben de sobra. Y la maqueta pasa a **salir con código 1** si encuentra
algo: antes informaba de los solapes por pantalla y salía con 0, así que en una
tubería no lo veía nadie.

⚠️ **Pendiente de comprobar en Windows.** `Layout-Rescatar` se ejecuta **antes**
que `Nav-OcultarCabecera`, así que mide la pestaña con la fila de solapas todavía
dentro: ~368 px en vez de los ~394 finales. Con esa medida, las notas al pie de
diez pestañas (`Diagnóstico NCU`, `Nodos`, `Enlace`, `NCU RW`, `FW NCU`, `HSU
config`, `FW HSU`, `Repetidor…`) le sobresalen y las **sube ~20 px al arrancar**,
donde se meten debajo de la tabla. Está deducido del código, no visto: aquí no
hay GUI que abrir. La comprobación es de cinco segundos —abrir la toolbox y
mirar si se lee la nota gris del pie en *Diagnóstico NCU*—. Si está tapada, el
arreglo es ejecutar el rescate **después** de ocultar la cabecera; la guarda de
`cuerpoTabs` ya impide que el rescate deshaga el truco.

**El límite de mediodía, y por qué el cronómetro ahora juzga el LADO (v11.55)** —
el cronómetro de D.2 apuntaba cuándo llegó la orden, cuándo llegó el seguidor y
a qué ángulo, pero no decía si el ángulo era **el correcto**. Y la posición de
seguridad tiene lado: en las plantas que abanderan **hacia el sol**, el seguidor
se tumba al este por la mañana y al oeste por la tarde.

Con una excepción que es fácil leer como avería y no lo es. Si el seguidor viene
**siguiendo hacia el este** y ya está pegado a la horizontal —inclinación entre
`-límite` y 0, con el este por debajo del oeste como en toda la toolbox— tumbarlo
«hacia el sol» lo mandaría a cruzar por el cero justo en el paso por el
meridiano. En esa franja el abanderamiento va al **OESTE**. El límite es
configurable (10° por defecto) porque es de proyecto, no del equipo.

Dos columnas nuevas en `RESULTADO_D.2.*.csv`:

| columna | qué dice |
|---|---|
| `Lado_esperado` | `este` / `oeste` según la inclinación de partida y la regla |
| `Lado_correcto` | `SI` / `NO` / vacío |

El **vacío no es un aprobado**: es que no hay con qué juzgar — no llegó la orden,
la posición de seguridad es 0 (que no tiene lado), o la planta abandera **cara al
viento** y entonces el lado lo decide el viento, que el cronómetro no lee. Se
declara con `$script:CronHaciaElSol`; no se adivina.

La regla es la misma que aplica el motor de SolarGPT en las estrategias B1/B2
(`wind_stow_strategies._noon_flip`), y se carea contra él en las 44
combinaciones de límite × inclinación **haciendo el cambio de convenio**: el
core usa el de pvlib (este positivo) y la planta el contrario, y una regla
espejada pasa cualquier test que se mire a sí mismo.

**La suelta PASIVA no es un fallo de obediencia (v11.55)** — en bifila, la fila
exterior a barlovento se desembraga **por carga de viento**. No la manda la TCU,
así que el **objetivo no salta**: sigue calculando seguimiento como si nada
mientras el seguidor real está clavado en su límite. Para el cronómetro de D.2
eso era indistinguible de «no recibió la orden», y salía como fallo cuando es el
comportamiento correcto de la planta.

La firma que las separa:

| | objetivo | real | divergencia |
|---|---|---|---|
| abanderamiento **ordenado** | se va al límite | llega al límite | ~0 una vez llegado |
| suelta **pasiva** | sigue al sol | clavado en el límite | grande y sostenida |

Cuatro columnas nuevas en `RESULTADO_D.2.*.csv`: `Suelta_pasiva` (SI/vacío), el
tramo `desde`/`hasta` en UTC y la inclinación a la que se quedó. El lado se
declara en `$script:CronPasivoLado` (55° = oeste en el convenio de la toolbox):
es de **montaje**, no depende del rumbo del viento.

**El falso positivo del desabanderamiento (medido y corregido, v11.55)** — al
desabanderar, el objetivo vuelve al sol de golpe y el seguidor real sigue en el
tope mientras arranca la bajada. Eso da **exactamente** la firma de una suelta
pasiva durante `tol/velocidad` = 2/0,17 = **12 s**. Con el umbral original —3
*muestras*, y el cronómetro a 3 s— cada desabanderamiento se marcaba como
suelta. Y el desabanderamiento **es parte del ensayo D.2**: no era un caso raro,
era el de todos los días. La función que existe para no llamar fallo a lo
correcto habría llamado anomalía a lo correcto.

Dos defensas, y van las dos:

1. el mínimo es una **duración en segundos** (120 por defecto), no un número de
   muestras. El intervalo del cronómetro es configurable de 1 a 60 s, así que
   «3 muestras» significaba 3 segundos o 3 minutos según lo que pusiera el
   operario — el mismo código con dos significados. Una suelta por carga dura
   minutos u horas; el arranque de la vuelta, segundos;
2. las muestras **desde la orden de desabanderamiento** (`t_vuelta`, que la
   cronología ya conoce) no se miran.

⚠️ Lo que **no** se puede saber con lo que el cronómetro muestrea hoy: si se
soltó por carga o si el motor se quedó atascado en el tope. Las dos dan la misma
serie de `ts/real/obj`. **Sí se podría separar** añadiendo al muestreo
`motor_state` y `motor_current`, que el diagnóstico ya lee: con orden de mover y
corriente pero sin movimiento es **atasco**; sin orden ni corriente y en el tope
es **suelta**. Mientras no se añadan, el cronómetro dice «clavada en el límite
sin orden», que es lo que ve — igual que la cronología, una **inferencia de dos
registros**, no la lectura de un flag.

**Nada queda en blanco en una columna de veredicto.** `Lado_correcto` sale
`SI`/`NO`/`NO EVALUABLE: <motivo>` (`SIN ORDEN`, `SIN LADO (objetivo 0)`,
`CARA AL VIENTO`), y `Suelta_pasiva` sale `SI`/`NO`. Una celda vacía entre
síes se lee como «nada que objetar», y quien abre el CSV en una recepción no
tiene este README delante. La traducción vive en el **borde del CSV**
(`Aband-LadoTexto`): las funciones puras conservan su contrato —`''` = no
evaluable— porque eso es lo correcto en código.

**Todo lo que era de proyecto pasa a la pestaña SAT**, donde ya viven los demás
criterios de aceptación: si la planta abandera **cara al sol o cara al viento**
(con «cara al viento» el veredicto del lado se abstiene, que es lo que el diseño
quiere), el **límite de mediodía**, y del pasivo el **lado**, la **duración
mínima** y si están expuestos **los dos perímetros**. Estaban fijos en el
código: con `cara al sol` clavado, una planta de las otras habría recibido
veredictos SI/NO donde debía callarse.

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

- **Tabla de topología editable (recomendado para el resto de plantas)**: la hoja "Direcciones IP" del Excel maestro vive como tabla web editable en **factiun-cartera** (`ips.html`, "IPs de plantas", mismo login que la cartera). Sus botones **⬇ JSON toolbox** / **⬇ CSV toolbox** descargan los ficheros de plantas con esta misma forma — solo topología, nunca credenciales. **No son un reemplazo de `plantas/`, sino un complemento**: la tarjeta sabe la IP del ConnectPort de cada gateway (`ip_gw`) y aquí no se puede deducir, pero `plantas/` sabe cosas que la tabla no tiene (los `rsu`, y filas como el TCU 109 suelto de El Burgo, que sale de los `.bat` de Sunner y de ninguna hoja). Copiar el export encima borraría eso, y además la tabla llama a la planta «Burgo I» donde aquí es «El Burgo I», con lo que El Burgo aparecería **duplicado**. Para meterlo bien:

  ```bash
  python make_plantas.py --tarjeta IPs.zip     # el .zip tal cual sale del navegador
  ```

  Ese modo **solo escribe `ip_gw`**. Empareja por (NCU, puerto) —no por nombre—, respeta el fichero distinto de El Burgo, pone la misma IP en todos los tramos de un mismo puerto, y **se niega a escribir una IP que sea igual a la del Modbus** o que no sea una IPv4: confundirlas no da error, da una jornada de campo midiendo contra el aparato que no es. Los rangos de TCU no los toca nunca; si no cuadran con los de la tabla lo dice por consola, porque eso lo decide una persona mirando la planta. Comprobado en `test_tarjeta.py` (27 comprobaciones, 11 mutaciones). Alternativa offline: `python make_plantas.py --excel <Excel> [--excluir 23003]` lee esa misma hoja y genera `plantas/<nº>-<planta>.json` (⚠️ el Excel lleva contraseñas: **no subirlo nunca a este repo**, que es público; solo los JSON generados).

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
