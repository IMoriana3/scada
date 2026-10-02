# Los huecos de HSU que no son estaciones. Regresion de un fallo visto en campo
# el 02/10/2026: El Burgo NCU1 tiene DOS estaciones y el diagnostico pintaba
# DIEZ filas, cinco de ellas en ALARMA -"AVERIA: fallo com. HSU | solo contesta
# el bloque ampliado"- para estaciones que no existen.
#
# La causa es un error de criterio, no de codigo: un hueco VACIO contesta con el
# bit 15 de al1 puesto, que es la NCU diciendo "no puedo hablar con la estacion
# de este hueco". De una estacion que no esta, eso es justo lo que se espera. Se
# estaba tomando la prueba de AUSENCIA como prueba de que habia algo roto.
$ErrorActionPreference = 'Stop'
$fuente = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores.Count) { throw "TCU_Toolbox.ps1 con errores de sintaxis: $($errores.Count)" }
foreach ($v in @('$NCU_HSUEXT_AL1_SOLO_AUSENCIA','$NCU_HSUEXT_AL1_PROPIAS','$NCU_HSUEXT_AL1_METEO')) {
    $nodo = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($x.Left)" -eq $v }, $true))
    if ($nodo.Count -ne 1) { throw "Se esperaba una sola asignacion de $v (hay $($nodo.Count))" }
    . ([scriptblock]::Create($nodo[0].Extent.Text))
}
$nodos = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Hsu-ExtPoblado' }, $true))
if ($nodos.Count -ne 1) { throw 'Se esperaba una sola funcion Hsu-ExtPoblado' }
. ([scriptblock]::Create($nodos[0].Extent.Text))
$src = Get-Content $fuente -Raw
function Igual($real, $esperado, [string]$que) { if ("$real" -ne "$esperado") { throw "$que : obtenido '$real', esperado '$esperado'" } }

# EL CASO DE CAMPO: el hueco solo dice "fallo com. HSU" (bit 15) y nada mas
Igual (Hsu-ExtPoblado 0 0 0 0x8000) $false 'un hueco que solo dice "fallo com. HSU" NO es una estacion'
Igual (Hsu-ExtPoblado 0 0 0 0) $false 'y uno del todo vacio, tampoco'

# lo que SI es una estacion: cualquier contenido de verdad
Igual (Hsu-ExtPoblado 1 0 0 0x8000) $true 'con dato en la primera palabra, si'
Igual (Hsu-ExtPoblado 0 1 0 0x8000) $true 'o en la segunda'
Igual (Hsu-ExtPoblado 0 0 7 0x8000) $true 'o un main_status con nivel de viento'
# y una averia DE VERDAD cuenta, aunque venga junto al bit de ausencia
Igual (Hsu-ExtPoblado 0 0 0 0x8001) $true 'una averia real (com. anemometro) si la hace estacion'
Igual (Hsu-ExtPoblado 0 0 0 0x0200) $true 'y una ALARMA VIENTO tambien'
Igual (Hsu-ExtPoblado 0 0 0 0x0040) $true 'y una ALARMA NIEVE'

# el bit que se ignora es SOLO el 15, ni uno mas
for ($b = 0; $b -lt 15; $b++) {
    Igual (Hsu-ExtPoblado 0 0 0 (1 -shl $b)) $true "el bit $b si cuenta como contenido"
}
Igual $NCU_HSUEXT_AL1_SOLO_AUSENCIA 32768 'el bit que no cuenta es el 15 y solo el 15'

# El Burgo NCU1 reproducido: dos estaciones con dato y ocho huecos que solo
# se quejan de no poder comunicar
$huecos = @(
    @{w0=1; w1=0; w2=0; al1=0x0000}      # HSU1, con dato
    @{w0=1; w1=0; w2=0; al1=0x0000}      # HSU2, con dato
    @{w0=0; w1=0; w2=0; al1=0x8000}      # hueco
    @{w0=0; w1=0; w2=0; al1=0x8000}      # hueco
    @{w0=0; w1=0; w2=0; al1=0x8000}      # hueco
    @{w0=0; w1=0; w2=0; al1=0x8000}      # hueco
    @{w0=0; w1=0; w2=0; al1=0x8000}      # hueco
)
$reales = @($huecos | Where-Object { Hsu-ExtPoblado $_.w0 $_.w1 $_.w2 $_.al1 })
Igual $reales.Count 2 'de siete huecos, dos son estaciones: las que tienen dato'

# y el aviso de verdad no se pierde: lo da el careo con la topologia
Igual ($src -match 'function Hsu-Cuadre') $true 'sigue existiendo el careo declaradas/halladas'
Igual ($src -match 'Ese es el sitio bueno para ese aviso') $true 'y queda dicho por que ese es su sitio y no este'

# ---- Y LA EDAD DE ORIGEN, QUE SE CALCULABA Y SE TIRABA ----
# Ncu-HsuCompat saca $edad -cuanto hace que la NCU oyo a esa estacion-, la usa
# para la salud y para el texto, y no la ponia en la fila. Operacion la necesita
# para decir si el dato es de ahora, asi que toda HSU salia como "EDAD DE ORIGEN
# DESCONOCIDA" teniendo el dato delante.
Igual ($src -match 'Edad_s=\$\(if \(\$edad -ge 0\)') $true 'la fila de HSU lleva la edad de origen'
Igual ($src -match 'se calculaba y se tiraba') $true 'y queda dicho por que faltaba'
# Op-Calidad es quien la lee: si no parsea, canta desconocida
$opSrc = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'Operacion.ps1') -Raw
Igual ($opSrc -match 'EDAD DE ORIGEN DESCONOCIDA') $true 'Operacion sigue teniendo ese veredicto'
Igual ($opSrc -match '\$fila\.Edad_s') $true 'y lo decide mirando Edad_s, que es lo que ahora se rellena'

Write-Host 'test_hsu_fantasma.ps1: OK'
