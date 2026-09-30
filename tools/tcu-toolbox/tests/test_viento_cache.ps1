# Prueba aislada de la cache de la guardia de viento. Sin planta, sin red y sin
# esperar 30 segundos: la caducidad se comprueba envejeciendo la marca de tiempo.
$ErrorActionPreference = 'Stop'
$fuente = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores.Count) { throw "TCU_Toolbox.ps1 con errores de sintaxis: $($errores.Count)" }
foreach ($n in @('Viento-Seguro', 'Viento-OlvidarCache')) {
    $nodos = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    if ($nodos.Count -ne 1) { throw "Se esperaba una sola funcion $n" }
    . ([scriptblock]::Create($nodos[0].Extent.Text))
}
$src = Get-Content $fuente -Raw
$PUERTO_NCU = 502
$VIENTO_CACHE_S = [int]([regex]::Match($src, '\$VIENTO_CACHE_S\s*=\s*(\d+)')).Groups[1].Value
$script:VientoCache = @{}
$script:lecturas = 0
$script:hsus = @([pscustomobject]@{Salud='OK'; main_status='0x0000'; alarmas_1='0x0000'})
function Modbus-Conectar([string]$ip, [int]$puerto, [int]$to) { }
function Modbus-Cerrar { }
function Ncu-HsuCompat { $script:lecturas++; if ($null -eq $script:hsus) { throw 'sin respuesta' }; return $script:hsus }
function Igual($real, $esperado, [string]$que) { if ("$real" -ne "$esperado") { throw "$que : obtenido '$real', esperado '$esperado'" } }

Igual ($VIENTO_CACHE_S -gt 0) $true 'la ventana de cache esta definida'

# 1) sin pedir cache se lee SIEMPRE: las guardias de boton no pueden heredar
#    una lectura, porque el tecnico acaba de pulsar y espera el dato de ahora
$script:lecturas = 0
$a = Viento-Seguro '10.0.0.1' 8000
$b = Viento-Seguro '10.0.0.1' 8000
Igual $script:lecturas 2 'sin cache, dos llamadas son dos lecturas'
Igual $a.nivel 0 'nivel leido'

# 2) pidiendola, la segunda no vuelve a la NCU y da lo mismo
$script:lecturas = 0
$c = Viento-Seguro '10.0.0.1' 8000 0 $VIENTO_CACHE_S
$d = Viento-Seguro '10.0.0.1' 8000 0 $VIENTO_CACHE_S
Igual $script:lecturas 1 'con cache, la segunda no lee'
Igual $d.nivel $c.nivel 'y devuelve el mismo dato'

# 3) cada NCU tiene su propia entrada: la de una no vale para otra
$script:lecturas = 0
[void](Viento-Seguro '10.0.0.2' 8000 0 $VIENTO_CACHE_S)
Igual $script:lecturas 1 'otra NCU se lee aparte'

# 4) caducidad: envejecer la marca obliga a leer otra vez
$script:VientoCache['10.0.0.1|502'].cuando = (Get-Date).AddSeconds(-($VIENTO_CACHE_S + 1))
$script:lecturas = 0
[void](Viento-Seguro '10.0.0.1' 8000 0 $VIENTO_CACHE_S)
Igual $script:lecturas 1 'pasada la ventana, se lee de nuevo'

# 5) olvidar la cache obliga a leer: es lo que hace cada tirada de receta
$script:lecturas = 0
Viento-OlvidarCache
[void](Viento-Seguro '10.0.0.1' 8000 0 $VIENTO_CACHE_S)
Igual $script:lecturas 1 'tras olvidar, se lee'
Igual $src.Contains('Viento-OlvidarCache') $true 'y alguien la olvida'

# 6) UN FALLO NO SE CACHEA. Cachear un $null bloquearia toda la ventana de TCUs
#    por un solo hipo de red, y un "no se sabe" detiene la receta.
Viento-OlvidarCache
$script:hsus = $null
$script:lecturas = 0
$e = Viento-Seguro '10.0.0.3' 8000 0 $VIENTO_CACHE_S
Igual ($null -eq $e) $true 'sin datos devuelve nulo'
[void](Viento-Seguro '10.0.0.3' 8000 0 $VIENTO_CACHE_S)
Igual $script:lecturas 2 'un fallo no se cachea: se reintenta'

# 7) una lectura de viento ACTIVO se devuelve tal cual (y cachearla es seguro:
#    el lado conservador es el que bloquea)
Viento-OlvidarCache
$script:hsus = @([pscustomobject]@{Salud='OK'; main_status='0x0003'; alarmas_1='0x0200'})
$f = Viento-Seguro '10.0.0.4' 8000 0 $VIENTO_CACHE_S
Igual $f.nivel 3 'nivel de viento leido'
Igual $f.alarma $true 'y la alarma de viento'

# 8) las guardias de boton siguen sin cache en el fuente
foreach ($g in @('function Guardia-Viento', 'function Gr-GuardiaViento')) {
    $i = $src.IndexOf($g)
    if ($i -lt 0) { throw "no se encuentra $g" }
    $trozo = $src.Substring($i, 600)
    $m = [regex]::Match($trozo, 'Viento-Seguro[^\r\n]*')
    if (-not $m.Success) { throw "$g no consulta el viento" }
    if ($m.Value -match 'CACHE') { throw "$g no puede heredar una lectura: el tecnico acaba de pulsar" }
}
# y el paso de receta SI la usa, que es donde estaba el trafico
Igual ($src -match 'Viento-Seguro \$destino\.ip \$destino\.to 0 \$VIENTO_CACHE_S') $true 'el paso de receta reutiliza la lectura'

Write-Host 'Guardia de viento: cache por ventana corta OK'
