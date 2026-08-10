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
| `diagnostico_tcu` | toolbox web + agente | seguimiento-pem (KPIs, plano, SCADA 3D) | `NCU, GW, TCU, Salud, Modo, Tilt, Objetivo, Dif, SoC, Alarmas` |
| `inventario_tcu` | agente `/inventario` | seguimiento-pem (sección Inventario/FW) | `NCU, TCU, FW, Nota…` + `mapa`, `toolbox` |
| `comisionado` | agente `/comisionado` | seguimiento-pem (avance PEM) | `ncu, tcu, estado (0=COMISIONADO,1=Motor verificado,2=TCU configurado,3=Factory), nombre` |
| `seguimiento_pem` | toolbox (checklist) | seguimiento-pem (curva avance) | `ncu, tcu, cold_commissioning, config_tcu, prueba_movimiento, observaciones` |
| `auditoria_tcu` | toolbox web (Auditoría) | seguimiento-pem | variables de config leídas (~90 VARS_AUD, incl. 41098/41100/41102/41104 BT3D) |
| `test_comm` | toolbox | seguimiento-pem | resultado de test de comunicaciones |
| `baterias_tcu` | agente `/baterias` | (pendiente de panel) | por TCU: tensión/SoC |

Tabla `topología` `{proyecto, ncu, esclavos_gw1, esclavos_gw2}` = **fuente de verdad de los totales**
(la web NUNCA baja el total de TCUs por lecturas encogidas; las NCUs ausentes se marcan "mudas").

### B. Agente HTTP en el PC de planta (TCU_Agente.ps1 v3.0)
Solo lectura Modbus (FC03) · cabecera `X-Token` obligatoria · consumidor web: `factiun-cartera/toolbox.html`.
GET: `/ping /diagnostico /comisionado /hsus /sincronizar /baterias /inventario /cierre /trabajos /plan-firmware /leer /hsus/meteo /hsus/config /hsus/cajanegra /sat /sat/descargar`
Trabajos largos (v3.0, por trozos): `/trabajo/inventario` (inicia) · `/trabajo` (estado/progreso) · `/trabajo/parar`.
POST: auditoría y operaciones de lectura declaradas en `$OPS_LECTURA_POST` / `$OPS_SAT` (`/sat/iniciar`…).
La web sube los resultados a Supabase con los `datos.tipo` de la tabla A (funcion `subirSeguimiento`).

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

- **[Backtracking → Toolbox] ¿751 o 754 seguidores en Ayora?** El commit "toolbox v11.27: Ayora son 751 seguidores, no 754" contradice el layout DWG y las cotas del levantamiento (754 con etiqueta TK). Si 3 no existen en campo, la web necesita saber CUÁLES (etiquetas) para quitarlos del plano/3D y de la topología; si sí existen, corregir el toolbox. → Toolbox: responded aquí con la lista.
- **[Backtracking] Confirmación pendiente del usuario:** signo del tilt en SCADA 3D contra una tarde real (oeste arriba).

## Registro de cambios de interfaz

| fecha | sesión | cambio |
|---|---|---|
| 2026-08-10 | Backtracking | Creación del contrato. `scada3d` postMessage con `eti`; ficha por clic en SCADA 3D; comisionado estados 0–3 según A. |
