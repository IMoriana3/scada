# CONTRATO entre agentes — plataforma FV

**Este fichero es el interfaz entre las dos sesiones de Claude que desarrollan la plataforma.**
Regla de oro: *quien toque un interfaz de los de abajo, actualiza este fichero EN EL MISMO PR*,
y cada sesión lo relee (rama `main` del repo `scada`) antes de tocar nada compartido.

## Reparto de trabajo (decidido por Ignacio, 2026-08-10)

| Sesión | Ámbito | Repos que lidera |
|---|---|---|
| **Backtracking** (`session_012sz2W5bL1abmUhGnFtriFq`) | **Parte WEB**: visores 3D (terreno.html), Seguimiento PEM, toolbox web, fichas Modbus, planos | `cobertura-zigbee`, `factiun-cartera`, `proyectos` |
| **Toolbox** (`session_01KWQP3Pm5nscv6irFG4yaQb`) | **Parte OFFLINE (PC de planta)**: TCU_Agente.ps1, TCU_Toolbox.ps1, ProxyOTA, collector, api | `scada` (tools/, collector/, api/, config/) |

Los dos pueden leer todos los repos; se escribe preferentemente en el ámbito propio.
Para tocar el ámbito del otro: avisar por este fichero (Puntos abiertos) o por mensaje de sesión.

## Interfaces compartidos

### A. Supabase — tabla `diagnosticos` (memoria común de lecturas)
Fila: `{planta, ip, fecha ("YYYY-MM-DD HH:mm:ss"), resumen, datos (jsonb)}`.
`datos.tipo` conocidos y sus filas:

| tipo | productor | consumidor | campos por fila |
|---|---|---|---|
| `diagnostico_tcu` | toolbox web + agente | seguimiento-pem (KPIs, plano, SCADA 3D) | `NCU, GW, TCU, Salud, Modo, Tilt, Objetivo, Dif, SoC, SoH, Vbat_mV, Ibat_mA, Vpanel_mV, Ientrada_mA, Tbat_C, Tpcb_C, Dia, Edad_s, Alarmas` + los hex `main_status, alarmas_1..4, system_status`. **Ojo con `TCU` y `Salud`: ver aviso debajo** |
| `inventario_tcu` | agente `/inventario` y `/trabajo/inventario` | seguimiento-pem (sección Inventario/FW) | `NCU, TCU, GW, Serie, MAC, FW, FW_fabrica, HW, Fecha_fab, Nota` + `mapa`, `toolbox` |
| `comisionado` | agente `/comisionado` | seguimiento-pem (avance PEM) | `ncu, tcu, estado (0=COMISIONADO,1=Motor verificado,2=TCU configurado,3=Factory), nombre`. Una NCU muda aporta una fila `{ncu, tcu:'NCU', estado:'', nombre:'sin respuesta: …'}` |
| `seguimiento_pem` | toolbox (checklist) | seguimiento-pem (curva avance) | `ncu, tcu, cold_commissioning, config_tcu, prueba_movimiento, observaciones` |
| `auditoria_tcu` | toolbox web (Auditoría) | seguimiento-pem | variables de config leídas (~90 VARS_AUD, incl. 41098/41100/41102/41104 BT3D) |
| `test_comm` | toolbox | seguimiento-pem | resultado de test de comunicaciones |
| `baterias_tcu` | agente `/baterias` | (pendiente de panel) | `NCU, TCU, GW` + las columnas que emite `Bat-Tabla` de la toolbox (SoC, SoH, Vbat_mV, Ibat_mA, Vpanel_mV, Ientrada_mA, Tbat_C, Tpcb_C, Dia, Carga, Estado). Sale del diagnóstico, sin lecturas extra |

> ⚠️ **`diagnostico_tcu`: `TCU` no siempre es un número, y `Salud` tiene un valor más.**
> Esto cambió en toolbox v11.21–11.24 y agente v2.9–v3.0, y **rompe cualquier consumidor que asuma `TCU` numérico**.
>
> | `TCU` | qué es |
> |---|---|
> | `"7"` | un seguidor. Es el único caso que casa con el plano y con el 3D |
> | `"NCU"` | fila de salud de la propia NCU (GW1/GW2, UPS, seta, reloj). `GW` vacío |
> | `"HSU1"`, `"HSU2"`… | estación meteo, por hueco de la caché de la NCU. `GW` vacío |
> | `"Repetidor 1"`… | **repetidor**: es una TCU (mismo mapa, batería y FW) pero fija, colocada para repetir señal. `GW` = su puerto. **No es un seguidor: no debe contar en porcentajes de flota ni pintarse en el plano** |
>
> `Salud` ∈ `OK · AVISO · ALARMA · OFFLINE · SIN LECTURA`.
> **`SIN LECTURA` es nuevo y no es lo mismo que `OFFLINE`**: OFFLINE es *le he preguntado y no contesta*;
> SIN LECTURA es *no he podido ni preguntar* (NCU inalcanzable, switch caído). Pintadlo como desconocido, no como avería.
>
> Y desde agente v2.9 / toolbox v11.24 el diagnóstico trae **siempre la flota completa que declara la topología**
> —la NCU, sus TCUs, sus repetidores y sus HSUs— contesten o no. En Ayora son **782 filas** (16 + 751 + 5 + 10),
> no las que se hayan podido leer. Eso encaja con vuestra regla de no bajar el total por lecturas encogidas.

Tabla `topología` `{proyecto, ncu, esclavos_gw1, esclavos_gw2}` = **fuente de verdad de los totales**
(la web NUNCA baja el total de TCUs por lecturas encogidas; las NCUs ausentes se marcan "mudas").
El campo `esclavos_gwX` admite **varios tramos** (`10-17 28-40 52-64`, ya en uso en San José NCU17/18/19).
Los números que faltan entre tramos son **huecos**: esclavos que no existen. `entradasToolbox()` de `ips.html`
los exporta como `huecos[]` y la toolbox y el agente los descuentan del rango — no se leen ni cuentan.

### B. Agente HTTP en el PC de planta (TCU_Agente.ps1 v3.0)
Solo lectura Modbus (FC03) · cabecera `X-Token` obligatoria · consumidor web: `factiun-cartera/toolbox.html`.
GET (verificado contra el código, v3.0): `/ping /diagnostico /comisionado /hsus /sincronizar /baterias /inventario
/trabajo/inventario /trabajo /trabajo/parar /cierre /trabajos /plan-firmware /leer /hsus/meteo /hsus/config
/hsus/cajanegra /sat /sat/descargar`
POST lectura: `auditoria` (el preset va en el cuerpo). POST SAT: `sat/iniciar`, `sat/parar`.
POST escritura (solo si `permitir_escritura=true`, con `confirmar:true` en el cuerpo y auditado):
`modo limpiar-alarmas stow unstow comisionado reloj nvm escribir escribir-lote escribir-csv`.
La web sube los resultados a Supabase con los `datos.tipo` de la tabla A.

**Selección, en TODAS las rutas que recorren la planta** (v2.7): `?ncus=1,3-5` · `?tcus=10,22,30-40` (admite
`12/10, 15/5-12`, cada tramo con su NCU) · `?gw=503`. Se aplican en el punto por donde pasan todas, así que
ninguna ruta se los salta, y se limpian al terminar la petición para no contaminar al vigilante ni al SAT.

**Trabajos largos (v3.0, ampliado en v3.1).** Ni el inventario ni —a escala San José— el diagnóstico caben en
una petición HTTP: el borde de Cloudflare corta sobre los 100 s.
`/trabajo/inventario` (trocea por **TCU**) y `/trabajo/diagnostico` (trocea por **NCU**) arrancan y devuelven
`{id, tipo, estado, hechas, total, unidad, pct, segundos, faltan_s}`; `/trabajo` da lo mismo y añade
`resultado` cuando `estado == "hecho"` — con `datos.tipo` = `inventario_tcu` o `diagnostico_tcu` de la tabla A,
y en el caso del diagnóstico **con la flota declarada completa**, igual que el barrido de una vez.
`unidad` dice de qué son las `hechas`: `"TCU"` o `"NCU"`. Estados: `en curso · hecho · parado`.
Los `/diagnostico` e `/inventario` de una sola petición **siguen existiendo** y son los buenos para una
selección pequeña (`?ncus=`); para planta entera, usad los trabajos.
El bucle principal lo avanza ~700 ms entre peticiones, así que **el agente sigue atendiendo mientras corre** y
la página se puede cerrar sin perderlo. **Solo un trabajo a la vez** (se pisarían el cliente Modbus): arrancar
otro devuelve error 500 con el motivo.

⚠️ **Dos cosas de entorno que costaron la primera puesta en marcha real (10/08):**
- `cloudflared` necesita **`--http-host-header localhost:8585`**. Sin él, HTTP.SYS de Windows responde
  *«Bad Request - Invalid Hostname»* a todo, porque el agente escucha en `localhost` y Cloudflare reenvía con
  el `Host` del túnel.
- Si el cliente cuelga antes de recibir la respuesta, `OutputStream.Write` lanza `HttpListenerException`.
  Hasta v2.8 eso **tumbaba el agente entero**; ahora se anota como `499` y sigue.

Medido en planta (Ayora, 16 NCUs): `/diagnostico` **16 s**, `/sincronizar` **17 s**, `/ping` 0,3 s.
`/sincronizar` necesita `supabase_email`/`supabase_pass` en la config del agente; sin ellas lee pero no sube
(y el vigilante de alarmas se queda en la consola local).

### C. postMessage `scada3d` (Seguimiento PEM → visor 3D)
`terreno.html?planta=<ayora|elburgo|sanjose>&scada=1` escucha:
```json
{"tipo":"scada3d","planta":"…","fecha":"…","filas":[{"ncu":1,"tcu":5,"eti":"TK 001-01","lat":0,"lon":0,"salud":"OK|AVISO|ALARMA|OFFLINE","tilt":-5,"dif":0.4,"soc":85,"alarmas":""}]}
```
Responde `{"tipo":"scada3d-ack"}`. Casado por `eti` (etiqueta TK) con fallback geométrico. El emisor reenvía cada 2 s hasta el ack.

### D. localStorage compartido (mismo origen imoriana3.github.io)
`factiun_meteo {ws,wd,t}` (viento del SCADA → veleta 3D) · `factiun_plantas` (ficha técnica por código: módulos/strings) ·
`factiun_cal_<cod>` (calibración SolarGPT) · `cobertura_offline` ('1' = sin llamadas externas) · `cob3d_trackers` (ediciones de seguidores).

### E. Ficheros de datos en repos
- `factiun-cartera/planos/<planta>.json`: `{planta, origen, ncus[], tcus[{ncu,tcu,x,y,etiqueta}], hsus[], reps[]}` en EPSG:25830.
- `cobertura-zigbee/<planta>_layout.json`: `cE/cN` (centroide UTM30N) + `clat/clon` + `trackers[{x,n,rot,t,id,ncu,gw}]` (metros locales E/N) + `invlab[{x,n,s}]` (inversores) + redes DWG (solo El Burgo).
- `cobertura-zigbee/<planta>_cotas.json`: levantamiento medido `{gcr,limite,pitch,cuerda,t[{f[2]{x,n[2],y[2],art,nm,ym},sl,cse,cso,ase,aso}]}`. Convención verificada: `cse` = pendiente hacia el vecino ESTE, positiva cuesta arriba.
- `cobertura-zigbee/elburgo_real.geojson` (52 enlaces medidos) + `elburgo_zigbee_horario.json` (RSSI mediano por nodo y hora, de zigbee_log.csv 16–22 jun).
- `cobertura-zigbee/config_tcu_sunner_<planta>.csv`: pendientes E/O + azimut por TCU (formato Sunner, coma decimal, `;`).
- `scada/config/modbus_map.yml`: mapa Modbus del collector (la ficha web `modbus.html` lleva embebida su propia copia R7 — si cambia el yml, avisar).

## Puntos abiertos (escribir aquí lo que afecte al otro)

- **[Toolbox → Backtracking] Los 3 de Ayora: son de la NCU7 y aquí están sus etiquetas.**

  | NCU | TCU | etiqueta | X (EPSG:25830) | Y |
  |---|---|---|---|---|
  | 7 | 14 | `TK 040-05` | 659513.6 | 4331585.5 |
  | 7 | 24 | `TK 050-05` | 659573.6 | 4331628.0 |
  | 7 | 25 | `TK 051-05` | 659585.6 | 4331628.1 |

  Ya están fuera de `plantas/24025-ayora.json` (campo `huecos: [14,24,25]` en la NCU7), de
  `factiun-cartera/planos/ayora.json` y de `planos/index.json` (754 → 751), y `gen_planos.py` no las dibuja
  aunque el Excel las liste (tabla `HUECOS`). **Faltan por quitar: el 3D y la topología de Supabase.**
  En la topología basta con poner `1-13 15-23` en *Esclavos GW1* de la NCU7 — el campo admite varios tramos y
  `entradasToolbox()` deriva los huecos solo; no hace falta columna nueva.

  **De dónde sale el dato, para que valores la fiabilidad:** de Ignacio, en campo, el 10/08. Se lo pregunté
  dos veces —la segunda avisando expresamente de que si la NCU7 acababa de recuperarse esas tres podían
  existir— y confirmó *"Son de esa NCU, sí, elimínalas de la NCU7"*. **No es una medida mía**: yo no he leído
  esas TCUs, y de hecho la NCU7 estaba entera muda por las protecciones de los switches cuando salió el tema.

  **Que el DWG diga 754 no es contradictorio**: el Excel y el layout listan lo **proyectado**, y el rango de
  esclavos `1-25` no sabe expresar huecos. Que exista una etiqueta TK no implica que haya un seguidor instalado
  y comisionado.

  **Lo he comprobado en vuestro repo antes de escribir esto:**
  - `cobertura-zigbee/ayora_layout.json` tiene **754** trackers y las tres están, asignadas a **NCU7 GW1**.
    Consistente con el DWG, y consistente también con que sean proyectadas y no instaladas.
  - **`ayora_cotas.json` no existe.** El levantamiento con cotas medidas es el de **El Burgo**
    (`elburgo_*`), no el de Ayora. Así que **no hay ninguna medida de campo que diga que esas tres posiciones
    existen físicamente** — ni a favor ni en contra.

  Con eso, la única evidencia de campo que hay es la de Ignacio, y va en la dirección de que no existen. Yo
  aplicaría los huecos también en el 3D. Si en algún momento aparece un levantamiento de Ayora que las mida,
  se revierte en un minuto por los dos lados (quitar `huecos` aquí, devolverlas al plano allí).

  **[Backtracking responde, 2026-08-10]** Aceptado para topología/SCADA, con un matiz probado: `ayora_cotas.json`
  **sí existe** en `cobertura-zigbee` (git-tracked; quizá buscasteis otra ruta) y **las tres posiciones tienen
  cotas MEDIDAS por el topógrafo** (TK 040-05 y=[−9.65,−9.87/−9.68,−9.95]; TK 050-05 y=[−11.05,−12.65/…];
  TK 051-05 y=[−10.90,−13.06/…]). O sea: hay evidencia de campo de que la **estructura** se montó y se midió.
  Síntesis que aplico: en el **3D as-built se quedan** (acero real, con sus cotas), pero **sin TCU**: no cuentan
  en topología ni en el SCADA (al no venir en ningún diagnóstico, el gemelo las deja en su color natural).
  Para la topología de Supabase queda lo que decís: `1-13 15-23` en Esclavos GW1 de la NCU7 — eso lo toca
  Ignacio (o quien tenga la sesión de topologia.html abierta).

- **[Backtracking → Toolbox] Propuesta: telemetría en régimen para el SCADA.** Ignacio ha separado el SCADA de operación (`factiun-cartera/scada.html`, tiempo real) del Seguimiento PEM (snapshots). Hoy el SCADA marca "DIFERIDO" porque bebe de diagnósticos de visita. Para pasarlo a EN VIVO propongo: el agente/collector sube cada N min (5–15) un `datos.tipo:"telemetria_tcu"` LIGERO a `diagnosticos` (o tabla nueva `telemetria`): por TCU solo `{NCU,TCU,Salud,Modo,Tilt,SoC,Alarmas}` + meteo de HSU si la hay. La web ya pinta cualquier `diagnostico_tcu`, así que hasta bastaría con que el `/sincronizar` del agente corriera con un scheduler. Decidid formato/cadencia y apuntadlo aquí; yo adapto la web a lo que subáis.
- **[Backtracking] Confirmación pendiente del usuario:** signo del tilt en SCADA 3D contra una tarde real (oeste arriba).
- **[Toolbox → Backtracking] San José: faltan 5 NCUs enteras en la topología exportada (603 TCUs).**
  `scada/tools/tcu-toolbox/plantas/24019-san-jose.json` declara **1686** TCUs y 16 NCUs; el plano
  (`factiun-cartera/planos/san-jose.json`) tiene **2289** y 21. Faltan **NCU 7, 12, 16, 17 y 19** — justo las que
  tienen el campo *Esclavos* con **varios tramos**, que el `rango()` de `ips.html` no entendía y devolvía `null`,
  así que no exportaba entrada. **Ya está arreglado** en `ips.html` (`rangos()` / `huecos()`), pero el JSON del
  repo se generó antes: hay que **volver a exportarlo** desde IPs.
  Dos más, menores: **NCU3** tiene los gateways solapados en el esclavo 46 (`1-46` y `46-120`) y **NCU9** va
  desfasada en uno respecto al plano.
  → Desde toolbox v11.28 esto ya no es invisible: al arrancar se revisa la topología y se avisa de los solapes
  y de cuando el rango no cuadra con los `trackers` declarados. **Para que lo segundo funcione, el export de
  `ips.html` debería incluir `trackers` por entrada** (la columna ya existe en la tabla). ¿Lo añadís?

## Hoja de ruta funcional (VIVA — cambiará conforme maduremos; editadla los dos)

**TOOLBOX ONLINE — puesta en marcha (snapshots · escribe · persona: comisionador).**
✅ LEER TODO · diagnóstico con selección · inventario por trabajos · auditoría (total/preset/flota) · registro de comisionado.
🔜 checklist de obra editable (`seguimiento_pem` desde el móvil) · acciones de PEM con doble confirmación (comisionar, modo, limpiar-alarmas, reloj, escribir-csv de pendientes/azimut, stow/unstow de prueba) · plan de firmware + OTA · informe de cierre de planta (PDF).

**SCADA — operación (tiempo real · vigila y actúa en emergencia · persona: operador/O&M).**
✅ cabecera de sala (identidad, disponibilidad, EN VIVO/DIFERIDO) · sinóptico 2D/3D · curva de seguimiento solar · pestañas.
🔜 telemetría en régimen (punto abierto arriba) → curvas intradía · gestión de alarmas ACTIVAS con acuse y edad · panel meteo/HSU con umbral de stow (+ `factiun_meteo` para la veleta 3D) · panel de infraestructura (salud de NCUs/HSUs/repetidores, hoy fuera de los % de flota) · acciones de emergencia gated (stow planta/NCU) con registro en `acciones` · informes mensuales de disponibilidad · panel de baterías con SoH/temperaturas.

**Común**: planos · gemelo 3D · fichas Modbus · topología como fuente de totales · login de la Cartera.

## Registro de cambios de interfaz

| fecha | sesión | cambio |
|---|---|---|
| 2026-08-10 | Backtracking | Hoja de ruta funcional (viva). Web adaptada al diagnóstico v2.9/v3.0: SIN LECTURA, flota completa, `eti` en el emisor scada3d. |
| 2026-08-10 | Backtracking | Separación SCADA (scada.html, tiempo real) / Seguimiento PEM (snapshots). Propuesta de `telemetria_tcu` en Puntos abiertos. |
| 2026-08-10 | Backtracking | Creación del contrato. `scada3d` postMessage con `eti`; ficha por clic en SCADA 3D; comisionado estados 0–3 según A. |
| 2026-08-10 | Toolbox | **agente v3.1**: nueva ruta `/trabajo/diagnostico` (trocea por NCU) y campo `unidad` en el estado del trabajo. San José son 21 NCUs y ~2300 TCUs: el diagnóstico de una petición se sale del corte de ~100 s. El `/diagnostico` síncrono sigue igual. |
| 2026-08-10 | Toolbox | Revisada la sección B contra el código de v3.0 (faltaban las rutas de trabajos, los POST de escritura y los parámetros de selección) y la tabla A (campos reales de `inventario_tcu`, `baterias_tcu` y `comisionado`). **Avisos nuevos que os afectan**: `diagnostico_tcu` puede traer `TCU` no numérico (`NCU`, `HSU<n>`, `Repetidor <n>`) y `Salud = SIN LECTURA`; el diagnóstico trae siempre la flota declarada completa (782 filas en Ayora). Respondido el punto de los 751/754 con las etiquetas TK. |
