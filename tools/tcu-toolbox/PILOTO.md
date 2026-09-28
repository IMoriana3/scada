# Piloto de cliente: aceptación y soporte

Estado: candidato de software. No es un acta de ensayo de planta ya realizada.

## Alcance a completar con el cliente

- Planta, responsable técnico y operador; versión del paquete y SHA-256.
- Modelos, HW, firmware y topología comprobados; funciones permitidas.
- Ventana de intervención, interlocutor y criterio de parada del ensayo.
- Ubicación y recuperación de copias; custodia de usuarios y credenciales.
- Horario/canal de soporte y plazo de respuesta acordado; no prometer SLA 24/7 sin servicio contratado.

## Casos de aceptación en equipos reales

| Caso | Resultado esperado | Evidencia a registrar |
|---|---|---|
| Operador nuevo | Alta, diagnóstico, interpretación y parte sin ayuda del desarrollador | Tiempo, dudas y fallos de uso |
| Origen | Cambio de selección no cambia el destino de una acción preparada | Planta/NCU/equipo y captura |
| Lectura y escritura | Lectura no escribe; técnico ejecuta solo la operación autorizada | Registro y verificación independiente |
| Corte de conexión | Error y resultado parcial visibles; ninguna confirmación ficticia | Logs revisados, equipos afectados |
| Cancelación | Se detiene el lote; equipos ejecutados y pendientes identificados | Registro y estado de campo |
| Reinicio del programa | Usuarios, configuración e incidencias conservados | Archivos antes y después |
| Histórico | Última muestra, hora de descarga y día abierto distinguidos | CSV/ZIP original y hash |
| Actualización/retorno | Datos conservados y anterior recuperable | Versión, backup y revisión de datos |
| Seguridad de movimiento | Interlocks y efectos comprobados según procedimiento aprobado de planta | Acta del responsable técnico |

Criterio de salida propuesto: ningún fallo crítico abierto, casos aplicables
aceptados por el responsable, procedimientos y compatibilidad documentados.
No sustituir esta aceptación por el resultado del simulador.

## Antes de vender como producto general

Pendiente de la empresa: certificado de firma del editor y custodia de su clave;
revisión de derechos/licencias y materiales del fabricante; condiciones de uso,
soporte y responsabilidad; revisión de requisitos regulatorios aplicables al
producto concreto y su mercado. No se otorga una licencia comercial nueva en
este documento ni se declara certificación o conformidad ya obtenida.

## Procedimiento de soporte

1. Registrar versión, función, alcance, hora, esperado y observado.
2. Crear paquete técnico; revisar cualquier evidencia de planta antes de compartir.
3. Clasificar impacto y reproducir en banco. No repetir órdenes físicas para obtener logs sin procedimiento de campo.
4. Corregir en rama, añadir regresión pertinente y revisar paridad SCADA/Toolbox.
5. Publicar versión trazable, documentar migración y verificar con el cliente.

Los registros locales no son inmutables frente a un administrador del PC. Un
SCADA continuo/multiusuario requiere su propia arquitectura y revisión de
seguridad; el piloto no promete esa capacidad.
