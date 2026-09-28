# Compatibilidad y evidencias

Edición piloto 11.94. No confundir mapa implementado con firmware certificado.

| Componente | Referencia implementada | Evidencia disponible | Aceptación pendiente |
|---|---|---|---|
| TCU | Sunner Modbus v6.1 / referencia FW v1.4.3 | Pruebas del protocolo y funciones contra simulador | Modelo/HW/FW instalado, valores y efectos físicos |
| NCU | Base R7.1 y adiciones R8 documentadas en README | Regresiones, pasarela y cache simuladas | Firmware real, compatibilidad de cada bloque |
| HSU | R23 | Decodificación y funciones probadas en banco | Modelo instalado; efectos de órdenes/actualización |
| CSV NCU | API HTTP del descargador y datetime con separador ; | ZIP y archivos de prueba; conservación ante fallos | Tamaño, retención, reloj/zona y firmware de la NCU del cliente |
| Windows PowerShell 5.1 / PowerShell 7 Windows | WinForms | CI en ambos runtimes antes de la release | Política corporativa, antivirus, DPI y hardware del cliente |

Las funciones de firmware mantienen sus advertencias existentes. No se afirma
que instalar firmware en HSU esté validado en campo. Una versión desconocida
no debe tratarse como compatible por el mero hecho de responder por Modbus.
Las operaciones de riesgo del piloto se acotan en el acta antes de habilitarlas.

El archivo `PILOTO.md` recoge la prueba de aceptación. Añadir nuevas evidencias
por combinación de modelo/HW/FW y versión de Toolbox, sin sobrescribir las previas.
