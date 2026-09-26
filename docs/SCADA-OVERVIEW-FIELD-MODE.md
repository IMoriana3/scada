# SCADA Overview + Field Mode v1

## Objetivo

Unificar la operación en tres niveles sin crear pantallas con lógica distinta:

1. **Overview** — estado de planta.
2. **Planta** — el canvas existente, con la misma topología y colores.
3. **Activo** — la ficha existente de TCU, abierta por `asset_id`.

El modo campo es una superficie adicional de la ficha/Overview, no otro SCADA.

## Fuente de verdad

### Identidad

Siempre `IdentityRegistry` vía `ScadaHistory.assetForMotor(m)`.

No se resuelve un activo por:

- nombre parecido;
- posición;
- orden;
- índice;
- count;
- TCU de otra NCU;
- proximidad geométrica.

Un motor de escena sin binding explícito no se ofrece como activo operable en
Field Mode.

### Salud

Overview NO recalcula `health`.

La lista «requieren atención» consume exactamente `health` publicado por el
collector/API. Modo, delta de ángulo, SoC y alarmas se muestran como evidencia,
no como una segunda clasificación.

### Mapa

El Overview no mantiene otra geometría de planta. La tarjeta de mapa es una
captura del mismo canvas operativo que ya usa el SCADA.

## KPIs v1

Con datos disponibles hoy:

- TCU OK / total;
- alarm / warn / offline;
- porcentaje de modo AUTO cuando el firmware lo expone;
- delta medio encoder ↔ objetivo;
- número de TCU con delta >5° como métrica descriptiva;
- SoC medio;
- viento de HSU publicado por el SCADA.

No se publican todavía potencia AC, energía, PR ni pérdidas económicas porque
este repositorio no tiene una fuente contractual de inversor/contador. Añadir
un número estimado desde el navegador sería un segundo motor energético.

**Estado:** `UNKNOWN` hasta integrar 04_ENERGÍA / contador / inversor.

## Field Mode

Registro local versionado: `field-inspection/1`.

Cada inspección contiene:

- `inspection_id`;
- `asset_id`;
- locator visible NCU/GW/TCU, solo como contexto;
- timestamp;
- estado;
- mediciones;
- checklist;
- notas;
- ids de fotos;
- snapshot de telemetría live;
- `sync_status=LOCAL_ONLY`.

Fotos: IndexedDB del navegador.

Metadatos: localStorage.

Export: JSON.

### Sincronización

No se ha inventado un backend.

Hasta que 07_SCADA / 06_PLANT / Operations definan almacenamiento, autorización,
provenance y lifecycle:

`sync_status = LOCAL_ONLY`

La futura sincronización deberá conservar el mismo `inspection_id` y
`asset_id`; no deberá crear una identidad alternativa.

## Inclinómetro del móvil

v1 calcula la inclinación absoluta del plano a partir de gravedad cuando el
teléfono se apoya plano sobre el módulo.

Entrega:

`|tilt|`

No entrega signo E/O automáticamente.

**Clasificación:** `UNKNOWN` para el signo hasta fijar y probar una convención
de colocación del teléfono y orientación de pantalla frente al frame canónico
del tracker.

Esto impide convertir una comodidad de UX en una medida firmada falsa.

## PWA / offline

El service worker cachea el shell estático del SCADA. Las inspecciones y fotos
pueden capturarse sin red.

El live SCADA obviamente permanece sin dato cuando la API no es alcanzable. El
Field Mode conserva entonces el último contexto visible y no inventa
telemetría.

## Próximas integraciones aprobables

1. fuente contractual de potencia/energía real;
2. expected power consumiendo 04_ENERGÍA, nunca fórmula JS paralela;
3. almacenamiento Operations para inspecciones;
4. sincronización de fotos/evidencias;
5. QR/NFC que transporte un locator que resuelva a `asset_id`;
6. comparación física `encoder ↔ inclinómetro firmado` después de validar la
   convención móvil.
