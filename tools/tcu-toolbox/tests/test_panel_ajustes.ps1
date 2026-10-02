# LOS AJUSTES SUELTOS DE LA NCU, y el motivo de que esta prueba exista con su
# propio fichero: el camino Api-AjusteTexto -> Api-Ajuste es el unico de la
# herramienta donde el tecnico TECLEA un valor que acaba dentro de un PUT a una
# NCU en produccion. Todo lo demas que se escribe -grupos- se arma pulsando y
# eligiendo. Aqui no: aqui alguien escribe "no" a mano.
#
# Y "no" es exactamente el caso: [bool]'no' es $true en PowerShell. Sin el
# parser, escribir NO en "permitir escritura Modbus" la HABRIA ACTIVADO. Por eso
# la mitad de esta prueba es sobre un si/no.
$ErrorActionPreference = 'Stop'
$fuente = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores.Count) { throw "TCU_Toolbox.ps1 con errores de sintaxis: $($errores.Count)" }
foreach ($n in @('Api-Clonar','Api-Ajuste','Api-AjusteTexto')) {
    $nodos = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    if ($nodos.Count -ne 1) { throw "Se esperaba una sola funcion $n (hay $($nodos.Count))" }
    . ([scriptblock]::Create($nodos[0].Extent.Text))
}
foreach ($v in @('$API_AJUSTES','$API_AJUSTE_SI','$API_AJUSTE_NO','$API_COPIA_PROF')) {
    $nodo = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($x.Left)" -eq $v }, $true))
    if ($nodo.Count -lt 1) { throw "Se esperaba la asignacion de $v" }
    . ([scriptblock]::Create($nodo[0].Extent.Text))
}
$src = Get-Content $fuente -Raw
function Igual($real, $esperado, [string]$que) { if ("$real" -ne "$esperado") { throw "$que : obtenido '$real', esperado '$esperado'" } }

# La configuracion de verdad de la NCU2 de El Burgo, en lo que toca a esto:
# tcu_timeout 6000 y hsu_timeout 600 son los valores REALES vistos el 01/10/2026.
$cfg = '{"plant_id":"ElBurgo","tcu_timeout":6000,"hsu_timeout":600,"tcu_interval_ms":1000,"hsu_interval_ms":5000,"ncu_interval_ms":1000,"modbus_enable_writing":true}' | ConvertFrom-Json

# ---- EL SI/NO QUE NO SE ADIVINA ----
Igual (Api-AjusteTexto 'modbus_enable_writing' 'NO').valor $false 'NO es no'
Igual (Api-AjusteTexto 'modbus_enable_writing' 'no').valor $false 'y en minusculas tambien'
Igual (Api-AjusteTexto 'modbus_enable_writing' ' No ').valor $false 'con espacios alrededor, igual'
Igual (Api-AjusteTexto 'modbus_enable_writing' '0').valor $false 'un 0 es no'
Igual (Api-AjusteTexto 'modbus_enable_writing' 'false').valor $false 'y false es no'
Igual (Api-AjusteTexto 'modbus_enable_writing' 'SI').valor $true 'SI es si'
Igual (Api-AjusteTexto 'modbus_enable_writing' 'sí').valor $true 'con tilde tambien, que es como se escribe'
Igual (Api-AjusteTexto 'modbus_enable_writing' '1').valor $true 'y un 1'
# LA QUE IMPORTA: lo que no esta en la lista NO se interpreta
$x = Api-AjusteTexto 'modbus_enable_writing' 'quiza'
Igual $x.ok $false 'lo que no es ni si ni no se rechaza'
Igual ($x.nota -match 'escribe SI o NO') $true 'y se dice que escribir'
Igual (Api-AjusteTexto 'modbus_enable_writing' '').ok $false 'vacio no es no: es vacio'
# Y la prueba de la trampa: que el camino COMPLETO no convierta 'no' en si.
$r = Api-Ajuste $cfg 'modbus_enable_writing' (Api-AjusteTexto 'modbus_enable_writing' 'no').valor
Igual $r.ok $true 'cambiar de true a no es un cambio'
Igual $r.cfg.modbus_enable_writing $false 'ESCRIBIR "no" DEJA EL CAMPO EN FALSE, no en true'

# ---- LOS NUMEROS ----
Igual (Api-AjusteTexto 'tcu_timeout' ' 7000 ').valor '7000' 'un numero pasa tal cual, limpio'
Igual (Api-AjusteTexto 'tcu_timeout' '').ok $false 'un cuadro vacio no es un numero'
Igual (Api-AjusteTexto 'tcu_timeout' '   ').ok $false 'ni tres espacios'
$r = Api-Ajuste $cfg 'tcu_timeout' '7000'
Igual $r.ok $true '7000 entra'
Igual $r.cfg.tcu_timeout 7000 'y queda como numero, no como texto'
Igual $r.cfg.hsu_timeout 600 'sin tocar lo de al lado'
Igual (@($r.permitidas) -join ',') 'tcu_timeout' 'y solo se declara el campo tocado'
# el valor REAL de El Burgo tiene que entrar: un limite que rechaza lo que el
# aparato lleva puesto es un limite mal puesto
Igual (Api-Ajuste $cfg 'tcu_timeout' 6000).ok $false '6000 es lo que ya vale, asi que no se manda'
Igual ((Api-Ajuste $cfg 'tcu_timeout' 6000).nota -match 'ya vale') $true 'y se dice por que'
Igual (Api-Ajuste $cfg 'tcu_timeout' 0).ok $false 'un 0 no'
Igual (Api-Ajuste $cfg 'tcu_timeout' 999999).ok $false 'ni un disparate'
Igual (Api-Ajuste $cfg 'tcu_interval_ms' 10).ok $false '10 ms de sondeo no'
Igual (Api-Ajuste $cfg 'tcu_interval_ms' 2000).ok $true '2000 ms si'
Igual (Api-Ajuste $cfg 'tcu_timeout' 'hola').ok $false 'y lo que no es numero no se manda'

# ---- LO QUE NO SE SABE CAMBIAR NI SE TOCA NI SE INVENTA ----
Igual (Api-AjusteTexto 'ip_config' '10.0.0.1').ok $false 'la red no esta en la lista de ajustes'
Igual (Api-Ajuste $cfg 'ip_config' 'x').ok $false 'y Api-Ajuste tampoco la deja'
Igual (Api-Ajuste $cfg 'plant_id' 'otra').ok $false 'ni renombrar la planta'
# un campo que esta en la lista pero NO en esta NCU: no se crea
$flaco = '{"plant_id":"X","tcu_timeout":100}' | ConvertFrom-Json
$r = Api-Ajuste $flaco 'hsu_timeout' 300
Igual $r.ok $false 'un campo que esta NCU no tiene no se inventa'
Igual ($r.nota -match 'no se inventa') $true 'y se dice asi'

# ---- EL ORIGINAL NO SE TOCA ----
# Api-Ajuste clona: si mutara el objeto leido, la comparacion posterior contra
# "lo que habia" se haria contra lo nuevo y no veria nada raro nunca.
[void](Api-Ajuste $cfg 'tcu_timeout' 7000)
Igual $cfg.tcu_timeout 6000 'el cfg leido sigue intacto tras proponer un cambio'

# ---- Y QUE EL BOTON EXISTA DE VERDAD ----
# El motor estuvo desde la 11.99 sin boton ninguno, o sea inalcanzable: el
# tecnico tenia que seguir yendo a la pagina web. Un motor sin boton no cuenta.
Igual ($src -match '\$btnPANAjustar\s*=\s*New-Object') $true 'hay boton de aplicar ajuste'
Igual ($src -match '\$btnPANAjustar\.Add_Click') $true 'y hace algo al pulsarlo'
Igual ($src -match '\$btnPANAjustar\)\) \{ \$b\.Enabled = \$uno \}') $true 'y se habilita con una sola NCU leida, como los demas'
Igual ($src -match 'Api-AplicarCambio \$n \(Api-Ajuste') $true 'y pasa por el camino central: copia, diff, confirmar, relectura'
Igual ($src -match 'cbPANAjuste\.Add_SelectedIndexChanged') $true 'al elegir campo se ensena el valor actual'
# los seis campos salen en el desplegable por su nombre en castellano
Igual $API_AJUSTES.Count 6 'son seis ajustes'
foreach ($k in @($API_AJUSTES.Keys)) {
    Igual ("$($API_AJUSTES[$k].que)" -ne '') $true "el ajuste $k tiene rotulo en castellano"
}

Write-Host 'test_panel_ajustes.ps1: OK'
