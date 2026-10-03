# EL GATEWAY COMO EQUIPO PROPIO DEL DIAGNOSTICO (v12.7). Lo pidio Inaki: en la
# columna de la izquierda, al lado de NCU, TCU, HSU y repetidor, y desde su fila
# ver firmware y estado y poder reiniciarlo. Hasta aqui sus datos colgaban de la
# fila de la NCU como campos GWn_* y el gateway no existia como equipo.
#
# Lo que se prueba: que la fila tiene la MISMA forma que la de la NCU (si no,
# Operacion, el CSV y el informe se enteran), que la salud sale de lo unico que
# se le puede preguntar a un Digi, que las vistas y las acciones lo conocen, y
# de paso que la fila de la NCU en conexion simple va alineada, que no iba.
$ErrorActionPreference = 'Stop'
$fuente = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores.Count) { throw "TCU_Toolbox.ps1 con errores de sintaxis: $($errores.Count)" }
foreach ($n in @('Fila-Tipo','Diag-NivelNombre','Diag-FilaGw','Diag-FilaNcu','Gw-Linea','Gw-CargaResumen','Gw-MemPct','Gw-Mb',
                 'Gw-CuantasTcus','Gw-Objetivos','Gws-Objetivos-Topologia','Gws-MasSinTcus','Gw-Numero','Reloj-Nota')) {
    $nodos = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    if ($nodos.Count -ne 1) { throw "Se esperaba una sola funcion $n (hay $($nodos.Count))" }
    . ([scriptblock]::Create($nodos[0].Extent.Text))
}
foreach ($v in @('$GW_CPU_ALTA','$PUERTO_GW1','$PUERTO_GW2','$PUERTO_NCU')) {
    $nodo = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($x.Left)" -eq $v }, $true))
    if ($nodo.Count -ge 1) { . ([scriptblock]::Create($nodo[0].Extent.Text)) }
}
$src = Get-Content $fuente -Raw
function Igual($real, $esperado, [string]$que) { if ("$real" -ne "$esperado") { throw "$que : obtenido '$real', esperado '$esperado'" } }

# ---- ES UN TIPO PROPIO ----
Igual (Fila-Tipo @{TCU='GW1'}) 'GW' 'GW1 es un gateway'
Igual (Fila-Tipo @{TCU='GW2'}) 'GW' 'y GW2 tambien'
Igual (Fila-Tipo @{TCU='NCU'}) 'NCU' 'la NCU sigue siendo NCU'
Igual (Fila-Tipo @{TCU='HSU1'}) 'HSU' 'la HSU sigue siendo HSU'
Igual (Fila-Tipo @{TCU='18'}) 'TCU' 'y la TCU, TCU'
Igual ((Fila-Tipo @{TCU='GW'}) -ne 'GW') $true 'GW sin numero no es un gateway: no se adivina'
Igual (Diag-NivelNombre 'GW') 'solo gateways' 'la vista tiene nombre'

# ---- LA FILA, con lo que contesto un Digi de verdad (El Burgo .53, 16/09) ----
$lect = @{ok = $true
          carga = @{ok = $true; cpu = 19; mem_total = 16384; mem_usada = 7870; mem_libre = 8514; uptime = 1365600}
          ident = @{producto = 'ConnectPort X2D'; mac = '00:40:9d:e4:f1:2e'; fw = '2.27.4'; boot = '1.1.3'; pan = ''; canal = ''}}
$f = Diag-FilaGw '1' 1 '10.100.1.53' $lect 56
Igual $f.TCU 'GW1' 'la etiqueta en la columna de equipo'
Igual $f.GW '1' 'y su numero en la columna GW'
Igual $f.NCU '1' 'de su NCU'
Igual $f.Salud 'OK' 'contesta y la CPU va bien: OK'
Igual $f.FW '2.27.4' 'el firmware como campo propio'
Igual $f.Modelo 'ConnectPort X2D' 'y el modelo'
Igual $f.MAC '00:40:9d:e4:f1:2e' 'y la MAC'
Igual $f.IP_gw '10.100.1.53' 'y la IP del Digi, que es lo que necesita el reinicio'
Igual $f.CPU_pct 19 'y la CPU'
Igual $f.Uptime_s 1365600 'y el uptime'
Igual $f.TCUs_gw 56 'y cuantas TCUs cuelgan, para el texto de confirmar'
Igual ($f.Alarmas -match 'CPU 19 %') $true 'la nota lleva la carga'
Igual ($f.Alarmas -match '2\.27\.4') $true 'y el firmware'
Igual ($f.Alarmas -match '^GW1 ') $false 'sin repetir "GW1 ip:" delante, que ya esta en sus columnas'
Igual $f.Edad_s '' 'sin edad de origen: el Digi ES el origen'
Igual $f.Modo '-' 'sin modo, como la NCU'

# la MISMA forma que la fila de la NCU: ni una propiedad menos
$fn = Diag-FilaNcu '1' $null 'x'
$faltan = @($fn.PSObject.Properties.Name | Where-Object { $null -eq $f.PSObject.Properties[$_] })
Igual ($faltan -join ',') '' 'la fila del gateway tiene todas las propiedades de la de la NCU'

# ---- LA SALUD SALE DE LO QUE SE LE PUEDE PREGUNTAR ----
$f = Diag-FilaGw '1' 2 '10.100.1.54' @{ok = $false; carga = $null; ident = $null} 52
Igual $f.Salud 'ALARMA' 'no contestar es ALARMA: deja a sus TCUs fuera del alcance'
Igual ($f.Alarmas -match 'sin respuesta') $true 'y se dice'
Igual $f.FW '' 'sin inventarse firmware'
Igual ($null -eq $f.CPU_pct) $true 'ni CPU'
$f = Diag-FilaGw '1' 1 '10.100.1.53' @{ok = $true; carga = @{ok = $true; cpu = 85; mem_total = 16384; mem_usada = 15000; mem_libre = 1384; uptime = 10}; ident = $lect.ident} 56
Igual $f.Salud 'AVISO' 'CPU alta es AVISO'
Igual ($f.Alarmas -match '^CPU alta') $true 'y se dice por que'
$f = Diag-FilaGw '1' 1 '10.100.1.53' @{ok = $true; carga = @{ok = $false}; ident = @{producto = ''; fw = ''; mac = ''}} 56
Igual $f.Salud 'AVISO' 'contesta pero no se reconoce nada: no se puede decir que este bien'
Igual (@('OK','AVISO','ALARMA') -contains (Diag-FilaGw '1' 1 'x' $null $null).Salud) $true 'nunca OFFLINE, que es de las TCUs'
Igual ($null -eq (Diag-FilaGw '1' 1 'x' $null $null).TCUs_gw) $true 'sin tramo conocido, sin numero inventado'

# ---- CUANTAS TCUs CUELGAN ----
Igual (Gw-CuantasTcus 1 63) 63 'Ayora NCU1: 1..63'
Igual (Gw-CuantasTcus 57 108) 52 'El Burgo GW2: 57..108'
Igual ($null -eq (Gw-CuantasTcus '' '')) $true 'sin tramo, null'
Igual ($null -eq (Gw-CuantasTcus 10 5)) $true 'un tramo al reves no es un tramo'
$gws = @(@{puerto = 503; ini = 1; fin = 56; ip_gw = '10.100.1.53'}, @{puerto = 504; ini = 57; fin = 108; ip_gw = '10.100.1.54'})
$obj = @(Gws-Objetivos-Topologia $gws)
Igual $obj.Count 2 'dos objetivos'
Igual $obj[0].tcus 56 'el primero con sus 56'
Igual $obj[1].tcus 52 'y el segundo con sus 52'
Igual $obj[1].nGw 2 'y es el GW2'

# ---- LAS VISTAS Y LAS ACCIONES LO CONOCEN ----
Igual ($src -match "bloque = 'GATEWAYS'") $true 'hay bloque GATEWAYS en el arbol de la izquierda'
Igual ($src -match "tab=\`$tabG; vista='GW'") $true 'con su hoja de diagnostico'
Igual ($src -match "'Identificar gateway','Reiniciar gateway'\)\)\{") $true 'los botones del panel lateral existen'
Igual ([regex]::Matches($src, 'Diag-AccionGw ').Count -ge 2) $true 'y las dos ventanas de acciones despachan por Diag-AccionGw'
Igual ($src -match "if\(\`$destino\.tipo -eq 'GW'\)\{\`$acciones=@\('Identificar gateway','Reiniciar gateway'\)\}") $true 'a un gateway se le ofrece identificar y reiniciar'
Igual ([regex]::Matches($src, "if\(\`$destino\.tipo -eq 'GW'\)").Count) 2 'en el dialogo Y en el panel lateral'
Igual ($src -match 'Gateways: \$\(\$nGwOk \+ \$nGwMal\)') $true 'el resumen cuenta los gateways aparte'
Igual ($src -match 'function Diag-ItemGw') $true 'y se pintan con su propia fila'
Igual ($src -match 'return @\(\$filas\)\s*\n\}') $true 'Diag-AnotarGws devuelve las filas'
Igual ($src -match 'GW1_CPU_pct') $true 'y los campos GWn_ de la NCU se mantienen para el SCADA'

# ---- LA FILA DE LA NCU EN CONEXION SIMPLE, ALINEADA ----
# Tenia nueve subelementos para diez columnas: la salud salia bajo TCU y la nota
# bajo 'Edad s' hasta que un filtro repintaba. El barrido de planta ya iba bien.
Igual ($src -match "@\('', \`$dn\.TCU, \`$dn\.Salud, \`$dn\.Modo, '', '', '', '', '', \(Diag-NotaNcu \`$dn\)\)") $true 'la fila NCU de conexion simple lleva diez subelementos'
Igual ($src -match "@\(\`$dn\.TCU, \`$dn\.Salud, \`$dn\.Modo, \`$dn\.Tilt, \`$dn\.Objetivo, \`$dn\.Dif, \`$dn\.SoC, '', \(Diag-NotaNcu \`$dn\)\)") $false 'y la de nueve ya no esta'
$itemGw = [regex]::Match($src, "foreach \(\`$c in @\(\`$fg\.GW, (.*?)\)\) \{ \[void\]\`$item\.SubItems\.Add").Groups[1].Value
Igual (@($itemGw -split ',').Count + 1) 10 'la fila del gateway tambien lleva diez'

Write-Host 'test_gw_filas.ps1: OK'
