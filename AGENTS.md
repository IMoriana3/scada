# Requisito de producto: paridad online / Toolbox

Cada mejora de SCADA online se revisa para Toolbox y viceversa. Leer
`PARIDAD_PRODUCTO.md` antes de modificar funcionalidades compartidas.
No dar por terminada una mejora común sin implementación y pruebas de la
contraparte, o una diferencia explícita y justificada registrada en la matriz.
No atribuir paridad completa al mero hecho de compartir un contrato.

Mantener la identidad declarada y la procedencia: no fabricar asset_id ni
relaciones entre equipos por posición, recuento o nombre visible. Los datos
históricos y desconocidos no son telemetría actual.

Publicar cambios comunes con referencias cruzadas de PR/commit. No activar
servicios, adquirir datos de planta ni emitir órdenes físicas como parte de QA.
