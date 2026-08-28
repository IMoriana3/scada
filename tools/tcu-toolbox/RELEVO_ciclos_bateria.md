# RELEVO — el desgaste de batería está medido y no lo leemos

> ⚠️ **NO EJECUTADO.** Escrito por una sesión sin `pwsh`. El PR sale del entorno
> que lo corra entero. Si estás leyendo esto y ya está dentro, **borra el
> fichero**: era un relevo, no documentación.

## El hallazgo

Salió de una pregunta de Iñaki: *«¿los ciclos no leemos?»*. No.

| dato | dónde vive | ¿lo leemos? |
|---|---|---|
| `Number of charging cycles` | **TCU, 30101** (U16, *Computed*) | **no** |
| `Current battery capacity` | **TCU, 30099** (U16) | **no** |
| `Nominal battery capacity` | **TCU, 30100** (U16) | **no** |
| `CurrentBatteryCapacity_s1` | **NCU, 50028** (U16, mAh) | **no** — ver abajo |
| `Soc/Soh_s1` | NCU, 50025 | no (el compat ya trae SoC y SoH por separado) |

Verificado contra los mapas publicados (`cobertura-zigbee/tools/modbus_src/`,
`tcu_v6.json` y `ncu_r7_hsu_r23.json`), no de memoria.

**Por qué se escapó**: el colector lee el **bloque compat** de la NCU
(30500 + 22·i), y ahí están `soc`, `soh`, `battery_voltage`, `battery_current`
y `temp_battery` — y nada más. Los ciclos y las capacidades viven en el espacio
propio de la TCU, al que solo se llega por passthrough. Estaban **al otro lado
de la puerta por la que entra el SCADA**.

## Por qué importa

`SoH` es un porcentaje que calcula el BMS: se mueve poco y **tarde**. Ciclos +
capacidad actual contra nominal es la medida **directa** del desgaste, y llega
antes. Sobre todo, deja ver algo que hoy es invisible: **una TCU que cicla el
doble que sus vecinas tiene un problema de carga o de consumo** mucho antes de
que su SoC empiece a bajar.

Y es la familia de siempre en esta casa: dato medido, guardado en el equipo, y
tirado antes de llegar a quien decide.

## Decisión ya tomada: esto NO se polea

Preguntado y contestado por Iñaki: *«no es plan de andar haciendo
constantemente poleos a la TCU para leer esa variable sola»*. **De acuerdo, y
el motivo es cuantitativo**: el bloque compat existe precisamente para no
hablar TCU a TCU — 22 registros × N seguidores en una lectura contigua contra
**una conversación Zigbee con cada equipo**. En una NCU de 108, eso es la
diferencia entre segundos y minutos, sobre 250 kbps de aire compartido. Un dato
que se mueve en escala de **meses** no justifica ese coste jamás como telemetría.

**Los ciclos no son telemetría: son inventario.**

## El parche (toolbox) — coste: CERO conversaciones nuevas

`Diag-LeerTcu` ya hace esta lectura:

```powershell
$r2 = FC03-Leer $tcu (Dir-Trama 30091) 8     # 30091..30098
```

Los tres registros están en **30099-30101**, pegados al final de ese mismo
bloque. Es **estirar la trama de 8 a 11 registros**: la misma transacción, seis
bytes más de respuesta. No hay lectura nueva, no hay conversación nueva.

```diff
-    $r2 = FC03-Leer $tcu (Dir-Trama 30091) 8
+    # 30091..30101 de un tiron: a los ocho de siempre se les pegan las dos
+    # capacidades (30099 actual, 30100 nominal) y los ciclos de carga (30101).
+    # NO es una lectura mas: es la misma trama seis bytes mas larga, y por eso
+    # el desgaste de bateria no cuesta ni una conversacion Zigbee extra.
+    $r2 = FC03-Leer $tcu (Dir-Trama 30091) 11
```

y en el objeto que devuelve:

```powershell
    CapAct_mAh = $r2[8]; CapNom_mAh = $r2[9]; Ciclos = $r2[10]
```

**Dónde tienen que acabar: en el INVENTARIO, no en el diagnóstico.** El
inventario ya recorre TCU a TCU leyendo serie, MAC, FW, HW y fecha de
fabricación — es el sitio donde nadie tiene prisa y donde el dato viaja **con la
serie del equipo**. Que es exactamente lo que hace falta para la trazabilidad de
reemplazos: cuando una TCU se sustituye, lo que quieres saber es **con cuántos
ciclos se fue la vieja**.

Así que `UltimoInv` gana tres columnas (`Ciclos`, `CapAct_mAh`, `CapNom_mAh`) y
el parte `inventario_tcu` las sube con las demás.

## El otro lado: `CurrentBatteryCapacity_s1` (NCU 50028) — este SÍ es de aquí

**Este no necesita `pwsh` ni cuesta Zigbee**: está en el espacio de la **NCU**,
bloque base 50000, o sea al alcance del colector por Modbus TCP como cualquier
otro registro suyo.

Capacidad actual contra nominal es la medida de desgaste que hoy no tenemos, y
sería una lectura más de un bloque que ya se hace. **Pero no está hecho, y no se
hace a ciegas**: el colector mide su propio tráfico y `tools/test_trafico.py`
exige que **lo estimado coincida exactamente con lo que el driver contabiliza**,
así que añadir un bloque nuevo mueve el modelo de bytes y hay que medirlo, no
suponerlo. Queda apuntado con su registro y su motivo.

## Qué hay que declarar en el PR

1. **Los bytes**: cuánto crece la trama del diagnóstico (respuesta 9+2n → tres
   registros más son 6 B por TCU) y qué hace eso al total del barrido.
2. **Que el inventario no tarda más**: es la misma conversación. Si tarda más,
   es que el modelo estaba mal y eso es el hallazgo.
3. **Un valor de referencia real**: los ciclos de una TCU de El Burgo con su
   antigüedad, para que el número tenga escala. Un contador sin orden de
   magnitud no se puede juzgar.

## Cómo se corre

```powershell
pwsh tools/tcu-toolbox/tests/test_toolbox.ps1
```

Formato del PR: el de **scada#210**.
