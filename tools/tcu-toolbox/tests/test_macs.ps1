# El historico de MAC de la NCU, contra el fichero REAL de El Burgo NCU2.
# No es una maqueta inventada: son las filas que la NCU dio el 01/10/2026, con
# sus dos rarezas dentro -una estacion re-direccionada y una placa movida de
# seguidor-, que es justo lo que esta pantalla existe para ensenar.
$ErrorActionPreference = 'Stop'
$fuente = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores.Count) { throw "TCU_Toolbox.ps1 con errores de sintaxis: $($errores.Count)" }
foreach ($n in @('Api-MacsGw','Api-MacsFecha','Api-MacsParsear','Api-MacsResumen','Api-MacsPorMac','Api-MacsCareo')) {
    $nodos = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    if ($nodos.Count -ne 1) { throw "Se esperaba una sola funcion $n (hay $($nodos.Count))" }
    . ([scriptblock]::Create($nodos[0].Extent.Text))
}
$src = Get-Content $fuente -Raw
function Igual($real, $esperado, [string]$que) { if ("$real" -ne "$esperado") { throw "$que : obtenido '$real', esperado '$esperado'" } }
$csv = Get-Content (Join-Path $PSScriptRoot 'fixture_mac_history.csv') -Raw

# ---- LA FECHA, que es dd-MM-yyyy y NO se ordena como texto ----
Igual ((Api-MacsFecha '16-12-2025 10:53:08').ToString('yyyy-MM-dd HH:mm:ss')) '2025-12-16 10:53:08' 'la fecha se entiende'
Igual ((Api-MacsFecha '01-06-2026 12:51:24').ToString('yyyy-MM')) '2026-06' 'dia primero, no mes primero'
Igual ($null -eq (Api-MacsFecha 'lo que sea')) $true 'una fecha que no cuadra no se inventa'
# la trampa, con los datos de verdad: por texto, junio de 2026 va ANTES que
# diciembre de 2025
Igual ((Api-MacsFecha '01-06-2026 12:51:24') -gt (Api-MacsFecha '31-12-2025 10:22:47')) $true 'junio de 2026 es posterior a diciembre de 2025'
Igual ('01-06-2026 12:51:24' -lt '31-12-2025 10:22:47') $true 'y como texto saldria al reves: por eso hace falta parsearla'

# ---- el CSV ----
$f = @(Api-MacsParsear $csv)
Igual $f.Count 19 'se leen las 19 filas del fichero real'
Igual $f[0].TCU 185 'la primera es el esclavo 185'
Igual $f[0].MAC '0013A200426D8E6E' 'con su MAC'
Igual $f[0].Gateway 'GW2' 'y su gateway, dicho como se habla en la planta'
Igual $f[0].Gateway_id '1' 'guardando ademas el numero crudo de la NCU'

# LA NCU CUENTA DESDE 0 Y NOSOTROS DESDE 1. Ensenar el crudo saca un "GW0" que no
# existe en ninguna planta ni en ningun fichero nuestro.
Igual (Api-MacsGw '0') 'GW1' 'el gateway 0 de la NCU es nuestro GW1'
Igual (Api-MacsGw '1') 'GW2' 'y el 1 es el GW2'
Igual (Api-MacsGw '2') 'GW3' 'y vale si algun dia hay tres'
Igual (Api-MacsGw 'raro') 'raro' 'lo que no se entiende se deja crudo, no se inventa'
Igual (Api-MacsGw '-1') '-1' 'ni un negativo se convierte en GW0'
# la cabecera manda, no el orden: si la NCU mete una columna en medio, se sigue
# leyendo bien en vez de poner fechas en la columna de MAC
$revuelto = "zigbee_mac;modbus_id;gateway_id;discovered`n0013A200AAAA;7;0;16-12-2025 10:53:08"
Igual ((Api-MacsParsear $revuelto)[0].TCU) 7 'las columnas se buscan por la cabecera, no por su sitio'
Igual ((Api-MacsParsear $revuelto)[0].MAC) '0013A200AAAA' 'y la MAC va donde dice la cabecera'
Igual ((Api-MacsParsear $revuelto)[0].Descubierta) '16-12-2025 10:53:08' 'y la fecha tambien: sin esto, una columna fija pondria la MAC en la fecha'
Igual ((Api-MacsParsear $revuelto)[0].Gateway) 'GW1' 'y el gateway, traducido'
Igual (@(Api-MacsParsear "otra;cosa`n1;2").Count) 0 'un CSV que no es este no se interpreta a la fuerza'
Igual (@(Api-MacsParsear '').Count) 0 'ni uno vacio'

# ---- EL RESUMEN POR TCU, con las fechas en su orden ----
$r = @(Api-MacsResumen $f)
$t30 = @($r | Where-Object { $_.TCU -eq 30 })[0]
Igual $t30.MACs 2 'la TCU 30 ha tenido dos MACs'
Igual $t30.Primera '31-12-2025 10:22:47' 'y la primera es la de diciembre'
Igual $t30.Ultima '01-06-2026 12:51:24' 'y la ultima la de junio: ordenado por FECHA, no por texto'
Igual $t30.MAC_actual '0013A20042605C09' 'la MAC actual es la de la ultima vez'
Igual ($t30.Nota -match 'SUSTITUIDA') $true 'y se dice que fue sustituida'
$t78 = @($r | Where-Object { $_.TCU -eq 78 })[0]
Igual $t78.MACs 2 'la TCU 78 tambien'
Igual ($t78.Nota -match 'SUSTITUIDA') $true 'y se dice'
Igual ((@($r | Where-Object { $_.TCU -eq 1 })[0]).Nota) '' 'una TCU normal no lleva nota'

# ---- LA VISTA POR MAC: el mismo aparato en varios esclavos ----
$pm = @(Api-MacsPorMac $f)
Igual $pm.Count 2 'dos aparatos han estado en mas de un esclavo'
$hsu = @($pm | Where-Object { $_.MAC -eq '0013A200426D8E6E' })[0]
Igual $hsu.Esclavos '185 -> 210' 'LA ESTACION: del 185 (el esclavo de fabrica) al 210'
$placa = @($pm | Where-Object { $_.MAC -eq '0013A20042605C09' })[0]
Igual $placa.Esclavos '78 -> 30' 'LA PLACA: la que era la TCU 78 acabo siendo la 30'
foreach ($x in $pm) { Igual ($x.Nota -match 'mas de un esclavo') $true 'cada caso dice que ha pasado' }
# y una MAC en un solo esclavo NO sale aqui: esta vista es solo para las rarezas
Igual (@($pm | Where-Object { $_.MAC -eq '0013A200426099B8' }).Count) 0 'lo normal no ensucia la lista'

# ---- EL CAREO CON EL INVENTARIO ----
$inv = @([pscustomobject]@{NCU='2'; TCU=30; MAC='0013A20042605C09'}
         [pscustomobject]@{NCU='2'; TCU=1;  MAC='0013A200426099B8'}
         [pscustomobject]@{NCU='2'; TCU=46; MAC='0013A200AAAAAAAA'})
$c = @(Api-MacsCareo $r $inv)
Igual $c.Count 1 'solo una TCU no cuadra'
Igual $c[0].TCU 46 'la 46: lleva una MAC que la NCU no vio nunca'
Igual $c[0].En_la_NCU '0013A200426058FC' 'con lo que la NCU cree'
Igual $c[0].En_el_equipo '0013A200AAAAAAAA' 'y lo que hay montado'
Igual (@(Api-MacsCareo $r @()).Count) 0 'sin inventario no se inventa un careo'
# una TCU sin inventario no se cuenta como discrepancia: es que no se ha leido
Igual (@(Api-MacsCareo $r @([pscustomobject]@{TCU=30; MAC='0013A20042605C09'})).Count) 0 'lo que cuadra no sale'

Write-Host 'test_macs.ps1: OK'
