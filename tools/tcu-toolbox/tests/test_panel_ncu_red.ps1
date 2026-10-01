# El TRANSPORTE del lector del panel, contra una maqueta de la API que exige la
# cookie. Esto es lo que no se puede comprobar leyendo el codigo: que la sesion
# del login viaje de verdad en la segunda llamada. Aparte, porque necesita un
# servidor levantado:
#     python3 api_server.py &
#     pwsh -NoProfile -File test_panel_ncu_red.ps1
$ErrorActionPreference = 'Stop'
$fuente = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores.Count) { throw "TCU_Toolbox.ps1 con errores de sintaxis: $($errores.Count)" }
foreach ($n in @('Api-Entrar', 'Api-Leer', 'Api-Grupos', 'Api-TcusDeGrupos', 'Api-Rango', 'Api-Resumen', 'Api-Pct', 'Api-Edad')) {
    $nodos = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    if ($nodos.Count -ne 1) { throw "Se esperaba una sola funcion $n" }
    . ([scriptblock]::Create($nodos[0].Extent.Text))
}
$src = Get-Content $fuente -Raw
$API_AUTH  = ([regex]::Match($src, "\`$API_AUTH\s*=\s*'([^']+)'")).Groups[1].Value
$API_DATOS = ([regex]::Match($src, "\`$API_DATOS\s*=\s*'([^']+)'")).Groups[1].Value
# el puerto de la maqueta no es el 80 de una NCU de verdad
$API_PUERTO = $(if ($env:API_MAQUETA_PUERTO) { [int]$env:API_MAQUETA_PUERTO } else { 15080 })
function Igual($real, $esperado, [string]$que) { if ("$real" -ne "$esperado") { throw "$que : obtenido '$real', esperado '$esperado'" } }

$ip = '127.0.0.1'
try { [void](Invoke-RestMethod -Uri "http://${ip}:$API_PUERTO$API_DATOS" -Method Get -TimeoutSec 3) } catch { }
Igual ($API_AUTH -ne '' -and $API_DATOS -ne '') $true 'los dos extremos salen del fuente'

# 1) credenciales malas: se dice QUE pasa, no "fallo la peticion"
$m = Api-Entrar $ip 'usuario-de-maqueta' 'la que no es' 5000
Igual $m.ok $false 'con la contrasena mala no se entra'
Igual $m.nota 'usuario o contrasena incorrectos' 'y se dice por que, que es lo que el tecnico necesita'
Igual ($null -eq $m.sesion) $true 'y no se devuelve una sesion de mentira'

# 2) EL VIAJE DE LA COOKIE. La maqueta devuelve 401 al volcado si no llega la
#    galleta del login, asi que si esto pasa es que la sesion viaja de verdad.
$e = Api-Entrar $ip 'usuario-de-maqueta' 'clave-de-maqueta' 5000
Igual $e.ok $true 'con las buenas se entra'
Igual ($null -ne $e.sesion) $true 'y se queda la sesion'
$l = Api-Leer $ip $e.sesion 5000
Igual $l.ok $true 'y el volcado llega: la cookie del login viaja en la segunda llamada'
Igual ($null -ne $l.datos.config_data.config) $true 'con su configuracion dentro'

# 3) sin sesion no se lee, y se dice que hay que volver a entrar
$sinSesion = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$l2 = Api-Leer $ip $sinSesion 5000
Igual $l2.ok $false 'sin la cookie el panel no deja leer'
Igual ($l2.nota -match 'volver a entrar') $true 'y se dice que hay que volver a entrar, no "error 401"'

# 4) un puerto donde no hay nada: no se cuelga ni revienta, devuelve nota
$l3 = Api-Entrar $ip 'usuario-de-maqueta' 'clave-de-maqueta' 2000
$viejo = $API_PUERTO; $API_PUERTO = 15099
$l4 = Api-Entrar $ip 'usuario-de-maqueta' 'clave-de-maqueta' 2000
Igual $l4.ok $false 'donde no hay panel, no se entra'
Igual ($l4.nota -ne '') $true 'y se dice algo'
$API_PUERTO = $viejo

# 5) la contrasena NO aparece en lo que se devuelve, ni cuando falla. Lo que
#    sale de aqui va al log de la consola y el log va a disco.
foreach ($r in @($m, $e, $l4)) { Igual ("$($r.nota)" -match 'clave-de-maqueta|la que no es') $false 'ninguna nota lleva la contrasena' }

# 6) y lo de verdad: del volcado leido por red sale el reparto de grupos
$cfg = $l.datos.config_data.config
Igual (@(Api-Grupos $cfg).Count) 3 'los grupos salen del volcado leido por red'
Igual (Api-Rango (Api-TcusDeGrupos $cfg 5)) '1-3, 7' 'y el alcance de una orden a dos grupos'
Igual ((Api-Resumen $l.datos).Escritura_modbus) 'PERMITIDA' 'y si la NCU deja escribir'

Write-Host 'test_panel_ncu_red.ps1: OK'
