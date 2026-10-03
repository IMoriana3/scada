# El desgaste de batería: qué se mide hoy y qué falta

> Rescatado el **3-oct-2026** de `claude/relevo-bateria-desgaste` (28-ago, nunca
> fusionada, sin PR). Aquella era una **nota de relevo** que pedía su propio borrado
> en cuanto su contenido estuviera dentro —«si estás leyendo esto y ya está dentro,
> borra el fichero: era un relevo, no documentación»—. Su parte principal **ya está
> dentro, y mejor de lo que proponía**. Esto recoge lo que sigue abierto, que es lo
> único que merecía sobrevivir, convertido en documentación.

## Lo que SÍ se mide hoy (y no se medía en agosto)

`Diag-LeerTcu` de la toolbox lee **12 registros de un tirón** desde 30091, no 8:

| Registro | Qué | Campo |
|---|---|---|
| 30099 | capacidad actual (mAh) | `Cap_mAh` |
| 30100 | capacidad nominal (mAh) | `CapNom_mAh` |
| 30101 | ciclos de carga | `Ciclos` |
| 30102 | días en conservación | `DiasPreserv` |

No cuesta **ni una conversación Zigbee extra**: es la misma trama cuatro registros
más larga. La nota de agosto pedía tres (hasta 30101) y hoy entran cuatro.

Y con eso hay `Bat-SohMedido`, que calcula el SoH **a partir de la capacidad real**
(actual contra nominal) en vez de creerse el porcentaje que publica el BMS. Ese era
el argumento de fondo de la nota y sigue valiendo: **el SoH del BMS se mueve poco y
tarde**; ciclos más capacidad es la medida directa del desgaste y llega antes.

Lo que destapa, y hoy es visible: **una TCU que cicla el doble que sus vecinas tiene
un problema de carga o de consumo** mucho antes de que su SoC empiece a bajar.

## Por qué los ciclos NO son telemetría

Decisión tomada por Iñaki en su momento y el motivo es cuantitativo: el bloque
compat de la NCU (22 registros por TCU desde 30500) existe **precisamente para no
hablar TCU a TCU**. Leer una variable suelta por passthrough es una conversación
Zigbee con cada equipo: en una NCU de 108 seguidores, eso es la diferencia entre
segundos y minutos sobre 250 kbps de aire compartido.

**Un dato que se mueve en escala de meses no justifica ese coste como telemetría.**
Los ciclos son **inventario**, no telemetría, y por eso viajan con la serie del
equipo en el barrido de inventario, donde nadie tiene prisa — que es además lo que
hace falta para la trazabilidad de reemplazos: cuando una TCU se sustituye, lo que
quieres saber es **con cuántos ciclos se fue la vieja**.

## Lo que sigue ABIERTO

### 1 · `CurrentBatteryCapacity_s1` — NCU 50028 — este sí es del colector

Comprobado el 3-oct-2026: **el colector no lo lee** (cero menciones de `50028` o de
capacidades en `collector/`). Y este no necesita `pwsh` ni cuesta Zigbee: está en el
espacio de la **NCU**, bloque base 50000, al alcance del colector por Modbus TCP
como cualquier otro registro suyo. Capacidad actual contra nominal es la medida de
desgaste que la telemetría hoy no tiene.

**Pero no se añade a ciegas, y el motivo es del repo:** el colector mide su propio
tráfico y `tools/test_trafico.py` exige que **lo estimado coincida exactamente con
lo que el driver contabiliza**. Un bloque nuevo mueve el modelo de bytes, así que
hay que **medirlo, no suponerlo** — y si al añadirlo el tráfico no cuadra, eso no es
un fallo del arnés: es el hallazgo.

### 2 · Falta un valor de referencia real

Un contador sin orden de magnitud no se puede juzgar. Hacen falta los ciclos de una
TCU de El Burgo con su antigüedad conocida, para saber si 400 ciclos en ese parque
son normales o son una alarma. **Esto no se puede sacar de ningún repo: necesita
planta.**

## Si alguien toca esto

Lo que hay que declarar al añadir el bloque de la NCU, heredado de la nota original:
cuánto crece la trama (respuesta 9+2n bytes), qué le hace eso al total del barrido,
y que el inventario **no tarda más** porque es la misma conversación. Si tarda más,
el modelo estaba mal, y eso es lo que hay que contar.
