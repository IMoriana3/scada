# CUANTO TARDA EN ARRANCAR, medido por tramos (v12.8). Lo que se prueba: que la
# hora del .bat se lee bien en los formatos de %TIME% que hay (castellano con
# coma, ingles con punto, hora de un digito), que la medianoche no da un numero
# absurdo, que lo que no se entiende da $null y no un invento, y que la ventana
# se construye con la disposicion suspendida y se reanuda ANTES de ensenarla.
$ErrorActionPreference = 'Stop'
$fuente = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores.Count) { throw "TCU_Toolbox.ps1 con errores de sintaxis: $($errores.Count)" }
foreach ($n in @('Arranque-DesdeBat','Arranque-Texto')) {
    $nodos = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    if ($nodos.Count -ne 1) { throw "Se esperaba una sola funcion $n (hay $($nodos.Count))" }
    . ([scriptblock]::Create($nodos[0].Extent.Text))
}
$src = Get-Content $fuente -Raw
function Igual($real, $esperado, [string]$que) { if ("$real" -ne "$esperado") { throw "$que : obtenido '$real', esperado '$esperado'" } }

$ahora = Get-Date -Year 2026 -Month 10 -Day 3 -Hour 12 -Minute 35 -Second 1 -Millisecond 500
Igual (Arranque-DesdeBat '12:34:56,78' $ahora) 4.72 'castellano, con coma: 4,72 s'
Igual (Arranque-DesdeBat '12:34:56.78' $ahora) 4.72 'ingles, con punto, lo mismo'
Igual (Arranque-DesdeBat '12:34:56' $ahora) 5.5 'sin centesimas tambien vale'
Igual (Arranque-DesdeBat ' 9:59:58,00' (Get-Date -Year 2026 -Month 10 -Day 3 -Hour 10 -Minute 0 -Second 1 -Millisecond 0)) 3 'hora de un digito con espacio delante, como la da cmd'
Igual (Arranque-DesdeBat '12:34:56,7' $ahora) 4.8 'una sola centesima se lee como decima'
# medianoche: el .bat a las 23:59:58 y el script a las 00:00:03
Igual (Arranque-DesdeBat '23:59:58,00' (Get-Date -Year 2026 -Month 10 -Day 4 -Hour 0 -Minute 0 -Second 3 -Millisecond 0)) 5 'cruzar la medianoche no da un numero negativo ni de un dia'
# lo que no se entiende no se inventa
Igual ($null -eq (Arranque-DesdeBat '' $ahora)) $true 'sin hora, null'
Igual ($null -eq (Arranque-DesdeBat 'ayer' $ahora)) $true 'basura, null'
Igual ($null -eq (Arranque-DesdeBat '12:34' $ahora)) $true 'a medias, null'
Igual ($null -eq (Arranque-DesdeBat '10:00:00,00' $ahora)) $true 'una hora y media de arranque no es un arranque: null'
Igual ($null -eq (Arranque-DesdeBat '12:35:30,00' $ahora)) $true 'un .bat del futuro tampoco'

$t = Arranque-Texto 4.72 0.8 0.6 0.5 2.1
Igual ($t -match 'antivirus 4\.72 s') $true 'el tramo del .bat se dice con lo que incluye'
Igual ($t -match 'plantas 0\.6 s') $true 'y las plantas'
Igual ($t -match 'construir la ventana 2\.1 s') $true 'y la ventana'
$t = Arranque-Texto $null 0.8 0.6 0.5 2.1
Igual ($t -match 'sin hora del \.bat') $true 'sin .bat se dice, no se inventa un cero'
Igual ($t -match '\$') $false 'sin variables sin expandir'

# ---- la ventana se construye con la disposicion suspendida ----
Igual ($src -match '\$form = New-Object System\.Windows\.Forms\.Form\r?\n(.*\r?\n){0,8}\$form\.SuspendLayout\(\)') $true 'SuspendLayout nada mas crear el formulario'
Igual ($src -match '\$tabs = New-Object System\.Windows\.Forms\.TabControl\r?\n\$tabs\.SuspendLayout\(\)') $true 'y el TabControl tambien'
$iResume = $src.IndexOf('$form.ResumeLayout($true)'); $iShow = $src.IndexOf('[void]$form.ShowDialog()')
Igual ($iResume -gt 0 -and $iShow -gt 0 -and $iResume -lt $iShow) $true 'se reanuda ANTES de ensenar la ventana'
Igual ($iShow - $iResume -lt 200) $true 'y justo antes, no en cualquier sitio'
Igual ([regex]::Matches($src, 'SuspendLayout\(\)').Count) ([regex]::Matches($src, 'ResumeLayout\(').Count) 'tantos Suspend como Resume'
# los hitos existen y la consola los dice
foreach ($h in @('$script:T_arranque = Get-Date','$script:T_winforms = Get-Date','$script:T_plantas = Get-Date','$script:T_logica = Get-Date','$script:T_consola = Get-Date')) {
    Igual ($src.Contains($h)) $true "hito $h"
}
Igual ($src -match 'Con \(Arranque-Texto') $true 'el reparto se dice en la consola'
Igual ($src -match 'Ventana lista a los') $true 'y el total al ensenar la ventana'
# el .bat deja la hora
$bat = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.bat') -Raw
Igual ($bat -match 'set "TOOLBOX_T0=%TIME%"') $true 'el .bat deja la hora del doble clic'
Igual ($bat.IndexOf('TOOLBOX_T0=%TIME%') -lt $bat.IndexOf('powershell.exe')) $true 'antes de lanzar powershell'

Write-Host 'test_arranque.ps1: OK'
