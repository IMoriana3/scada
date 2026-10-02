# La configuracion de la HSU interna de la NCU. Lo que se prueba aqui es sobre
# todo que NO SE AFIRMA lo que no se sabe: del bundle de la pagina salen los
# nombres de campo, pero no la forma del objeto, asi que esto aplana lo que
# venga y solo dice de un sensor lo que la propia respuesta sostenga.
$ErrorActionPreference = 'Stop'
$fuente = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores.Count) { throw "TCU_Toolbox.ps1 con errores de sintaxis: $($errores.Count)" }
foreach ($n in @('Api-Tipo','Api-Breve','Api-Aplanar','Api-HsuSensores','Api-LeerHsuCfg')) {
    $nodos = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    if ($nodos.Count -ne 1) { throw "Se esperaba una sola funcion $n (hay $($nodos.Count))" }
    . ([scriptblock]::Create($nodos[0].Extent.Text))
}
$nodo = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($x.Left)" -eq '$API_HSU_SENSORES' }, $true))
if ($nodo.Count -ne 1) { throw 'Se esperaba una sola asignacion de API_HSU_SENSORES' }
. ([scriptblock]::Create($nodo[0].Extent.Text))
$src = Get-Content $fuente -Raw
function Igual($real, $esperado, [string]$que) { if ("$real" -ne "$esperado") { throw "$que : obtenido '$real', esperado '$esperado'" } }

# ---- aplanar funciona con CUALQUIER forma, que es justo el punto ----
$o = '{"anemometer":true,"pyranometer":false,"wind":{"activation_speed":15,"deactivation_speed":10},"zonas":[1,2]}' | ConvertFrom-Json
$f = @(Api-Aplanar $o)
Igual (@($f | Where-Object { $_.Ruta -eq 'anemometer' })[0].Valor) 'True' 'un booleano suelto'
Igual (@($f | Where-Object { $_.Ruta -eq 'wind.activation_speed' })[0].Valor) '15' 'un campo anidado, con su ruta entera'
Igual (@($f | Where-Object { $_.Ruta -eq 'zonas[1]' })[0].Valor) '2' 'y un elemento de una lista, por su indice'
Igual (@(Api-Aplanar ('{"a":[]}' | ConvertFrom-Json))[0].Valor) '(lista vacia)' 'una lista vacia se dice, no se calla'
Igual (@(Api-Aplanar ('{}' | ConvertFrom-Json)).Count) 0 'un objeto vacio no inventa filas'
# el orden es estable: si no, comparar dos NCUs seria imposible
Igual ((@(Api-Aplanar $o) | ForEach-Object { $_.Ruta }) -join ',') ((@(Api-Aplanar $o) | ForEach-Object { $_.Ruta }) -join ',') 'el orden es estable'
Igual (@(Api-Aplanar $o)[0].Ruta) 'anemometer' 'y alfabetico, para que dos volcados se puedan carear'

# ---- LO QUE NO APARECE NO SE DA POR AUSENTE ----
# Esta es la que importa: no sabemos la forma del objeto, asi que un sensor que
# no se encuentre puede ser que no este... o que se llame de otra manera.
$s = @(Api-HsuSensores $f)
$an = @($s | Where-Object { $_.Campo -eq 'anemometer' })[0]
Igual $an.Estado 'SI' 'un sensor puesto se dice'
$pi = @($s | Where-Object { $_.Campo -eq 'pyranometer' })[0]
Igual $pi.Estado 'no' 'y uno que esta a false tambien'
$so = @($s | Where-Object { $_.Campo -eq 'sonic_anemometer' })[0]
Igual $so.Estado 'no aparece' 'uno que no esta en la respuesta NO se da por ausente'
Igual ($so.Nota -match 'no es lo mismo que decir que no lo tiene') $true 'y se explica la diferencia'
Igual $s.Count $API_HSU_SENSORES.Count 'se mira cada sensor conocido'

# un sensor que solo trae parametros, sin campo suelto de si/no
$o2 = '{"snow_sensor":{"activation_time":5,"activation_threshold":0.3}}' | ConvertFrom-Json
$s2 = @(Api-HsuSensores (Api-Aplanar $o2))
$sn = @($s2 | Where-Object { $_.Campo -eq 'snow_sensor' })[0]
Igual $sn.Estado 'con parametros' 'si solo trae parametros, se dice eso y no un si/no inventado'
Igual ($sn.Nota -match '2 campos') $true 'contando cuantos cuelgan'

# y no se confunde un campo con otro que lo contenga
$o3 = '{"snow_sensor_check":true}' | ConvertFrom-Json
Igual ((@(Api-HsuSensores (Api-Aplanar $o3)) | Where-Object { $_.Campo -eq 'snow_sensor' })[0].Estado) 'no aparece' 'snow_sensor_check no es snow_sensor'

# ---- SOLO LEE ----
Igual ($src -match "Invoke-RestMethod[^\r\n]*API_HSU_CFG[^\r\n]*Method Put") $false 'no hay PUT contra la configuracion de HSU'
$usa = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) |
         Where-Object { "$($_.Extent.Text)" -match 'API_HSU_CFG' })
Igual $usa.Count 1 'se usa en una sola llamada'
Igual ("$($usa[0].Extent.Text)" -match 'Method Get') $true 'y es un GET'

# una NCU sin HSU interna detectada contesta vacio, y eso NO es un fallo nuestro
Igual ($src -match 'todavia no haya detectado ninguna') $true 'el caso de NCU sin HSU interna esta contemplado'

Write-Host 'test_hsu_cfg.ps1: OK'
