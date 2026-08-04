# TCU Toolbox v2 — configuración y diagnóstico de TCUs Sunner (offline)

> Herramienta de campo para O&M: escribe, lee, respalda y diagnostica los TCU de los seguidores a través del gateway Modbus TCP de la NCU. **100 % offline**: un `.ps1` + un `.bat`, sin instalar nada (PowerShell viene con Windows), sin red fuera de la LAN de planta.

Es el complemento de **escritura** del SCADA de este repo: el SCADA es solo-lectura a propósito; cuando hay que *cambiar* algo en un TCU (configuración, reloj, NVM) se usa esta toolbox desde el portátil conectado a la LAN de planta.

## Arranque

1. Copia la carpeta `tcu-toolbox/` al portátil de campo.
2. Doble clic en `TCU_Toolbox.bat` (no requiere admin).
3. Elige planta (o rellena IP/puerto a mano) y usa las pestañas.

Mapa de registros: **SUNNER TCU Modbus Map v6.1 (FW v1.4.3)**. La NCU actúa de gateway: el *unit id* Modbus es el número de TCU; en El Burgo el passthrough escucha en los puertos 503 (GW1) y 504 (GW2) de cada NCU.

## Pestañas

| Pestaña | Qué hace |
|---|---|
| **Escribir** | Tabla de variables (todo el mapa 4xxxx: carga, calefactor, comunicaciones, geometría, umbrales, deadbands, safe positions, rangos de tilt, motor, SoC) con verificación tras escribir, reintentos, "reintentar fallidas" y guardado en NVM (40007 bit 15). Campo **Filtro**: escribe `soc`, `tilt`, `zigbee`… y el desplegable de variables se reduce a lo que casa (las filas ya elegidas nunca se pierden). Presets JSON y carga de un **backup como preset** (excluye comandos y fecha/hora). Los registros de comando piden **doble confirmación**. |
| **Leer variable** | Una variable en un rango de TCUs con resumen de discrepancias (cuántos TCU tienen cada valor). Campo **Filtro** con contador de coincidencias (busca también en los registros de estado `ESTADO …`; si solo queda una, se autoselecciona). Export CSV. |
| **Volcar TCU** | Todas las variables de un TCU (config + estado + identidad opcional). Export CSV y **backup JSON** con metadatos (planta, IP, TCU, fecha, versión de mapa). Botón **Comparar con backup JSON**: marca en naranja las diferencias con un volcado anterior — ideal para verificar una TCU recién sustituida. |
| **Diagnóstico** | Escanea un rango de TCUs y clasifica cada uno en `OK / AVISO / ALARMA / OFFLINE` con el **mismo criterio de salud que el SCADA** (eje bloqueado, sobrecorriente, batería crítica, seta, fuera de rango ⇒ alarma; resto de bits, `system_ok=0` o desviación >5° ⇒ aviso). Las alarmas se muestran **decodificadas bit a bit en texto** (registros 30002–30005), más SoC/SoH, tensiones, temperaturas y estado del cargador. Export CSV y JSON. |
| **Utilidades** | **Sincronizar reloj**: escribe la hora del PC en un rango de TCUs (40001–40006 + secuencia 40007 bit0→bit1) y verifica leyendo el reloj real (30079). **Identificación**: FW principal/fábrica, MCU secundario, BQ, HW, Xbee HW/FW, **MAC Xbee**, **número de serie**, fecha de fabricación y lote (bloque 30300+). |

Consola común con colores, botón **CANCELAR** para abortar operaciones largas, y **log automático** a `logs/tcu_toolbox_AAAAMMDD.log`.

## Vínculo con la plataforma (sin dejar de ser offline)

- **Plantas compartidas**: la toolbox carga `plantas.json` (junto al script) al arrancar. Se puede editar a mano o generar desde el mismo `config/plants.yml` que usa el collector del SCADA:

  ```bash
  cd tools/tcu-toolbox
  python make_plantas.py                 # lee ../../config/plants.yml
  python make_plantas.py --puertos 503 504
  ```

  Después ajusta los rangos `tcu_ini`/`tcu_fin` por gateway si cada GW atiende un subrango (como en El Burgo).

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

## Seguridad

- Los registros de **comando** (40000, 40007, 40017, 40018, 42000) pueden mover el seguidor o cambiar su modo: la toolbox los marca `[COMANDO]`, pide una **segunda confirmación** y los **excluye** al restaurar un backup.
- "Verificar tras escribir" relee cada registro y compara (en escrituras por máscara compara solo el byte/bit escrito).
- El guardado en **NVM** es una operación aparte, con su propia confirmación.
- Los ángulos `f32` viajan en radianes por Modbus; la toolbox trabaja **siempre en grados** y convierte en ambos sentidos, con guardarraíl (±360°).

## Notas técnicas

- Las variables de los desplegables siguen el orden del mapa, agrupadas por categoría como en el PDF (comandos → fecha/hora → carga → calefactor → comunicaciones → geometría → umbrales → límites → safe positions → rangos de tilt → motor → SoC); el filtro busca por subcadena sin distinguir mayúsculas y sin interpretar `[ ] * ?` como comodines.
- Modbus TCP con framing MBAP propio (sin dependencias): FC03 lectura, FC16 escritura múltiple, FC22 mask-write para bytes y bits sueltos.
- Tipos soportados: `u16, s16, u16hex, u32, u32hex, f32, f32deg, u8lo, u8hi, bit, dt_bcd (fecha BCD 3 regs), charger, serial`.
- F32/U32 en orden *little-endian word swap* (2-1-4-3) según el mapa: registro N = palabra baja.
- Ante un timeout o socket roto reconecta y reintenta; ante una excepción Modbus (dirección ilegal, gateway sin respuesta…) reintenta sin reconectar.
- Si alguna planta necesitara offset Modicon en las direcciones, se cambia en un solo sitio (`Dir-Trama`).
