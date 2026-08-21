# RELEVO — el modo no entra en la salud de un TCU (mismo fallo que scada#210)

> ⚠️ **ESTE PARCHE NO SE HA EJECUTADO NUNCA.** Lo escribió una sesión sin `pwsh`.
> No se embarca desde aquí: se corre entero —parche, banco y medidas— en un
> entorno con PowerShell, y **de ahí sale el PR**. Esta casa ya se comió una vez
> un veredicto sobre PowerShell razonado-pero-no-corrido (el episodio de las
> «invisibles», corregido en público en scada#203); la lección está pagada.
>
> Si estás leyendo esto y el arreglo ya está dentro, **borra este fichero**: era
> un relevo, no documentación.

## El hallazgo (lectura estática, verificado)

`TCU_Toolbox.ps1`, dentro de `Diag-LeerTcu`, la **única** condición de aviso:

```powershell
$hayAviso = ($alarmas.Count -gt 0)              # alarmas
        -or ((($st -shr 15) -band 1) -eq 0)     # system OK = 0
        -or ($dif -gt 5)                        # desviacion > 5 deg
        -or ((($st -shr 11) -band 1) -eq 1)     # alarma de motor enclavada
```

**`$modo` no está.** Y se calcula **once líneas más abajo**, del registro que ya
se ha leído, para usarse **solo en la columna de la tabla**:

```powershell
$modo = @('OFF','MANUAL','AUTO','?')[(($r1[0] -shr 8) -band 0x3)]
```

Comprobado por grep: en toda la lógica de diagnóstico `$modo` aparece **dos
veces** —esas dos—. Las demás apariciones son de `Fijar-Modo`, que es escritura.

Y los bits son los mismos que el core: `($r1[0] -shr 8) -band 0x3` es
literalmente `main_state: [8,9]` de `config/modbus_map.yml`, mismo orden
`OFF/MANUAL/AUTO`. **Mismo dato, mismo criterio, misma omisión.**

## Por qué aquí es peor que en el SCADA

`$dif -gt 5` es un **vigilante correlacionado**: caza la parada en OFF solo
cuando el sol ha separado el ángulo del objetivo. Cubre hasta que llega la
coincidencia — y entonces calla.

En el SCADA esa coincidencia es *un caso*. En la Toolbox es **el caso típico**:
se usa en barridos de diagnóstico, muchas veces justo después de una
intervención, que es exactamente cuando un TCU se ha quedado en OFF **en la
posición en la que está el resto**. Un técnico barre, ve `OK`, y se va del
seguidor que ha dejado parado — delante del equipo.

## El parche

Sigue el patrón que la casa ya usa (`Rep-Salud`, `Cmp-Salud`): **la regla se
extrae a una función pura** y `Diag-LeerTcu` la llama. Así el banco puede
ejercitarla sin hierro, que es lo que hoy no se puede.

### 1 · función nueva, junto a `Rep-Salud`

```powershell
# La salud de un seguidor. Pura: se prueba sin hierro y sin ventana.
#
# El MODO entra, y no entraba: se leia, se pintaba en su columna y no se
# miraba. Un seguidor que no esta en AUTO no esta siguiendo, tenga el angulo
# que tenga -- y el unico que lo delataba era `$dif`, que solo se separa cuando
# el sol se ha movido lo bastante. Con el angulo coincidiendo, un TCU parado
# salia OK, identico a uno operando (scada#210, reportado sobre la 14-14).
#
# Es AVISO y no ALARMA a proposito: parar en OFF o MANUAL es una operacion
# legitima de mantenimiento. Lo que no es legitimo es que se vea igual que uno
# operando. Y '?' tampoco es AUTO: un modo que no se sabe no es seguimiento.
function Tcu-Salud([bool]$esAlarma, $alarmas, [int]$st, [double]$dif, [string]$modo) {
    if ($esAlarma) { return 'ALARMA' }
    $hayAviso = (@($alarmas).Count -gt 0) `
            -or ((($st -shr 15) -band 1) -eq 0) `
            -or ($dif -gt 5) `
            -or ((($st -shr 11) -band 1) -eq 1) `
            -or ("$modo" -ne 'AUTO')
    if ($hayAviso) { return 'AVISO' }
    return 'OK'
}
```

### 2 · en `Diag-LeerTcu`: subir `$modo` y llamar

```diff
     $esAlarma = (($al1 -band $CRIT_AL1) -ne 0) -or (($al2 -band $CRIT_AL2) -ne 0) -or ($al3 -ne 0) -or (($al4 -band 0x100) -ne 0)
-    $hayAviso = ($alarmas.Count -gt 0) -or ((($st -shr 15) -band 1) -eq 0) -or ($dif -gt 5) -or ((($st -shr 11) -band 1) -eq 1)
-
-    $salud = 'OK'
-    if ($esAlarma) { $salud = 'ALARMA' }
-    elseif ($hayAviso) { $salud = 'AVISO' }
+    # el modo se lee ANTES de clasificar: es una de las condiciones, no un adorno
+    $modo = @('OFF','MANUAL','AUTO','?')[(($r1[0] -shr 8) -band 0x3)]
+    $salud = Tcu-Salud $esAlarma $alarmas $st $dif $modo

     $notas = @()
     if ($dif -gt 5) { $notas += ("dif {0:0.0} deg" -f $dif) }
     if ((($st -shr 15) -band 1) -eq 0) { $notas += 'system OK = 0' }
     if ((($st -shr 11) -band 1) -eq 1) { $notas += 'alarma motor enclavada' }
+    # "AVISO" a secas obliga a salir a mirar para saber de que; el motivo va
+    # pegado al estado, igual que los otros tres.
+    if ("$modo" -ne 'AUTO') { $notas += "en $modo`: no sigue" }
-
-    $modo = @('OFF','MANUAL','AUTO','?')[(($r1[0] -shr 8) -band 0x3)]
```

⚠️ Al mover la línea de `$modo`, **comprobar que no queda duplicada** más abajo:
el bloque de retorno la usa.

## El banco — en `tests/test_toolbox.ps1`, junto a los `Check` de `Rep-Salud`

El caso de referencia es **el ángulo que COINCIDE** (`dif = 0`). En el ángulo
separado el criterio viejo ya daba `AVISO`, así que un test escrito ahí habría
salido verde **con el fallo dentro**.

```powershell
# --- el modo en la salud de un TCU (relevo de scada#210) ---
# $st con bit15=1 (system OK) y bit11=0 (sin alarma de motor enclavada)
$stOk = 0x8000
Check 'tcu salud: AUTO, sin alarmas y en su sitio' (Tcu-Salud $false @() $stOk 0.0 'AUTO') 'OK'
# EL CASO DE CAMPO: parada en OFF, angulo COINCIDIENDO con el resto
Check 'tcu salud: OFF con el angulo coincidiendo NO es OK' (Tcu-Salud $false @() $stOk 0.0 'OFF') 'AVISO'
Check 'tcu salud: MANUAL tampoco es seguir' (Tcu-Salud $false @() $stOk 0.0 'MANUAL') 'AVISO'
Check 'tcu salud: un modo desconocido no es AUTO' (Tcu-Salud $false @() $stOk 0.0 '?') 'AVISO'
# el regimen donde el fallo NO se podia ver: aqui ya avisaba antes
Check 'tcu salud: OFF y desviada seguia dando AVISO' (Tcu-Salud $false @() $stOk 12.0 'OFF') 'AVISO'
Check 'tcu salud: AUTO desviada, AVISO como siempre' (Tcu-Salud $false @() $stOk 12.0 'AUTO') 'AVISO'
# lo que manda sobre el modo
Check 'tcu salud: una alarma critica manda sobre el modo' (Tcu-Salud $true @() $stOk 0.0 'OFF') 'ALARMA'
Check 'tcu salud: system OK = 0 sigue avisando' (Tcu-Salud $false @() 0 0.0 'AUTO') 'AVISO'
Check 'tcu salud: alarma de motor enclavada' (Tcu-Salud $false @() 0x8800 0.0 'AUTO') 'AVISO'
```

**El mutante, obligatorio y a verificar en rojo**: quitar la cláusula
`-or ("$modo" -ne 'AUTO')` tiene que tumbar **3** comprobaciones (OFF, MANUAL y
`?` con el ángulo coincidiendo). Si tumba menos, el banco no está midiendo lo
que dice.

## Lo que hay que MEDIR y declarar en el cuerpo del PR

Esto es lo que no se puede hacer desde aquí, y es la mitad del encargo. Un
corrimiento de KPIs no puede llegar en silencio a quien consume el informe.

1. **`Portada-Bloques` → «Seguidores operativos»**, que es un **porcentaje** y
   tiene semáforo (`bien ≥98 · medio ≥90 · mal`). Los TCU en OFF salen de `$ok`,
   así que **el porcentaje baja y el semáforo puede cambiar de color**. Medir
   antes/después sobre un barrido real y ponerlo en el PR.
2. **«Con alarma o sin comunicación»** cuenta `ALARMA|OFFLINE`: **no debe
   moverse** — un `AVISO` por modo no es una visita. Confirmarlo, no suponerlo.
3. **`Cmp-Salud`** en el historial: un `OK → AVISO` por poner una TCU en OFF
   pasará a marcarse como **«peor»**. Es correcto —dejó de seguir— pero cambia
   lo que el comparador enseña entre dos barridos. Decirlo.
4. **El informe exportado** (`gen_informe.ps1` / `informe_muestra.html`): sale de
   los mismos conteos. Regenerar y **declarar la diferencia**.

## Cómo se corre

```powershell
pwsh tools/tcu-toolbox/tests/test_toolbox.ps1
```

Formato del PR: el de **scada#210** — el caso de campo reproducido, el mutante
con su cuenta, y los cuatro números de arriba antes y después.
