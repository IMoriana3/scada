# REINICIAR EL GATEWAY. Lo que se prueba aqui es sobre todo lo que NO se hace:
# no se reinician dos a la vez, no se manda nada a un Digi que no da su uptime
# de antes, no se da por reiniciado uno que contesta todo el rato con el mismo
# tiempo de marcha, y el viento de CUALQUIER NCU de la conexion lo para.
#
# El verbo <reboot/> se vio funcionar en El Burgo el 02/10/2026. La prueba de
# que funciono sigue siendo el uptime y no el XML, porque eso no depende del
# firmware que lleve el Digi ni de acertar el esquema de su respuesta.
$ErrorActionPreference = 'Stop'
$fuente = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores.Count) { throw "TCU_Toolbox.ps1 con errores de sintaxis: $($errores.Count)" }
foreach ($n in @('Gw-ObjetivoReinicio','Gw-NcusParaViento','Gw-VientoPeor','Gw-ReinicioAceptado','Gw-ReinicioVolvio','Gw-TextoReinicio')) {
    $nodos = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    if ($nodos.Count -ne 1) { throw "Se esperaba una sola funcion $n (hay $($nodos.Count))" }
    . ([scriptblock]::Create($nodos[0].Extent.Text))
}
foreach ($v in @('$RCI_REINICIO','$GW_REINICIO_ESPERA_S','$GW_REINICIO_CAIDA_S','$GW_REINICIO_PASO_S')) {
    $nodo = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($x.Left)" -eq $v }, $true))
    if ($nodo.Count -lt 1) { throw "Se esperaba la asignacion de $v" }
    . ([scriptblock]::Create($nodo[0].Extent.Text))
}
$src = Get-Content $fuente -Raw
function Igual($real, $esperado, [string]$que) { if ("$real" -ne "$esperado") { throw "$que : obtenido '$real', esperado '$esperado'" } }

# El Burgo NCU1 tal cual lo declara plants.yml: dos Digi con IP
$gws = @(
    @{ncu = '1'; nGw = 1; ip = '10.100.1.53'; tcus = 56}
    @{ncu = '1'; nGw = 2; ip = '10.100.1.54'; tcus = 52}
)

# ---- UNO CADA VEZ ----
$o = Gw-ObjetivoReinicio $gws ''
Igual $o.ok $false 'con dos gateways y sin IP a mano NO se reinicia'
Igual ($o.nota -match 'UNO cada vez') $true 'y se dice por que'
Igual ($o.nota -match '10\.100\.1\.53' -and $o.nota -match '10\.100\.1\.54') $true 'y cuales hay, para que elija'
$o = Gw-ObjetivoReinicio $gws '10.100.1.54'
Igual $o.ok $true 'con la IP a mano, si'
Igual $o.gw.nGw 2 'y se reconoce cual de los declarados es'
Igual $o.gw.tcus 52 'con lo que cuelga de el'
$o = Gw-ObjetivoReinicio $gws ' 10.100.1.54 '
Igual $o.ok $true 'con espacios alrededor, igual'
$o = Gw-ObjetivoReinicio $gws '10.100.1.99'
Igual $o.ok $true 'una IP que no esta declarada tambien vale (el tecnico sabe la IP)'
Igual $o.gw.ncu '?' 'pero sin inventarse de que NCU cuelga'
Igual ($null -eq $o.gw.tcus) $true 'ni cuantos seguidores'
$o = Gw-ObjetivoReinicio @($gws[0]) ''
Igual $o.ok $true 'con un solo gateway declarado, ese sin preguntar'
Igual $o.gw.ip '10.100.1.53' 'y es el'
$o = Gw-ObjetivoReinicio @(@{ncu='1'; nGw=1; ip=''; tcus=10}) ''
Igual $o.ok $false 'declarado sin ip_gw no es un objetivo'
Igual ($o.nota -match 'ip_gw') $true 'y se dice que falta'
Igual (Gw-ObjetivoReinicio @() '').ok $false 'sin gateways, nada'
# el mismo Digi declarado dos veces (la TCU suelta de El Burgo) sigue siendo UNO
$o = Gw-ObjetivoReinicio @($gws[0], @{ncu='1'; nGw=1; ip='10.100.1.53'; tcus=1}) ''
Igual $o.ok $true 'la misma IP dos veces es un solo gateway'

# ---- EL VIENTO DE CUALQUIER NCU LO PARA ----
Igual (@(Gw-NcusParaViento @{ip='10.100.1.52'; multi=$null}).Count) 1 'conexion simple: su NCU'
Igual (@(Gw-NcusParaViento @{ip='10.100.1.52'; multi=$null})[0]) '10.100.1.52' 'y es la suya'
$multi = @{ip='NA'; multi=@(@{ncu=1; ip='10.100.1.52'}, @{ncu=2; ip='10.100.1.56'})}
Igual (@(Gw-NcusParaViento $multi).Count) 2 'planta completa: todas las NCU'
Igual (@(Gw-NcusParaViento @{ip='NA'; multi=$null}).Count) 0 'y NA no es una NCU'
$vp = Gw-VientoPeor @(@{nivel=0; alarma=$false}, @{nivel=2; alarma=$false})
Igual $vp.v.nivel 2 'de dos lecturas, el nivel mas alto'
Igual $vp.leidas 2 'las dos leidas'
$vp = Gw-VientoPeor @(@{nivel=0; alarma=$false}, $null, @{nivel=0; alarma=$true})
Igual $vp.v.alarma $true 'alarma en cualquiera es alarma'
Igual $vp.leidas 2 'y la que no contesto no cuenta como leida'
Igual $vp.total 3 'pero si en el total, para decirlo'
$vp = Gw-VientoPeor @($null, $null)
Igual ($null -eq $vp.v) $true 'si ninguna contesta, no hay viento que mirar: se avisa'
Igual $vp.leidas 0 'cero leidas'
$vp = Gw-VientoPeor @()
Igual ($null -eq $vp.v) $true 'sin NCUs, lo mismo'

# ---- LO QUE CONTESTA EL DIGI AL REBOOT ----
Igual (Gw-ReinicioAceptado '<rci_reply version="1.1"><reboot/></rci_reply>').estado 'aceptado' 'un <reboot/> en la respuesta es aceptado'
Igual (Gw-ReinicioAceptado '').estado 'silencio' 'no contestar no es un error: puede haberse ido ya'
$e = Gw-ReinicioAceptado '<rci_reply version="1.1"><error id="1"><desc>Not authorized</desc><hint>login</hint></error></rci_reply>'
Igual $e.estado 'error' 'un <error> es error'
Igual ($e.nota -match 'Not authorized') $true 'y se dice el texto del Digi'
Igual ($e.nota -match 'login') $true 'y su pista'
Igual (Gw-ReinicioAceptado '<rci_reply version="1.1"><reboot><error id="2"/></reboot></rci_reply>').estado 'error' 'un error dentro del reboot tambien es error'
Igual (Gw-ReinicioAceptado '<rci_reply version="1.1"><query_state/></rci_reply>').estado 'raro' 'otra cosa se vuelca, no se interpreta'

# ---- LA PRUEBA DE VERDAD ES EL UPTIME ----
$r = Gw-ReinicioVolvio 1365600 42 $true
Igual $r.ok $true 'cayo y volvio con menos marcha: reinicio'
Igual ($r.nota -match '42 s') $true 'y se dice cuanta lleva'
$r = Gw-ReinicioVolvio 1365600 1365700 $false
Igual $r.ok $false 'contesta todo el rato con mas uptime: NO reinicio'
Igual $r.tarda $false 'y no es cuestion de esperar mas'
Igual ($r.nota -match 'no ha reiniciado') $true 'se dice claro'
Igual ($r.nota -match 'ni dejo de contestar') $true 'y que nunca se fue abajo, que es la pista'
$r = Gw-ReinicioVolvio 1365600 1365600 $true
Igual $r.ok $false 'mismo uptime exacto tampoco es reinicio'
$r = Gw-ReinicioVolvio 1365600 $null $true
Igual $r.ok $false 'cayo y no ha vuelto: no se da por bueno'
Igual $r.tarda $true 'pero es "aun no", no "mal"'
Igual ($r.nota -match 'IDENTIFICAR GATEWAYS') $true 'y se dice que hacer antes de ir a la planta'
$r = Gw-ReinicioVolvio 1365600 $null $false
Igual $r.ok $false 'ni cayo ni contesta: raro'
Igual $r.tarda $false 'y no se le echa la culpa a la espera'

# ---- EL TEXTO DE CONFIRMAR DICE LO QUE DEJA A CIEGAS ----
$t = Gw-TextoReinicio $gws[1] @{nivel=0; alarma=$false} 2 2
Igual ($t -match 'GW2') $true 'dice que gateway'
Igual ($t -match 'NCU1') $true 'y de que NCU'
Igual ($t -match '10\.100\.1\.54') $true 'y su IP'
Igual ($t -match '52 seguidores') $true 'y cuantos seguidores se quedan sin posicion segura'
Igual ($t -match 'POSICION SEGURA') $true 'y que eso es lo que se para'
Igual ($t -match 'El resto de la planta sigue') $true 'y que el resto no'
Igual ($t -match 'nivel 0') $true 'y el viento'
Igual ($t -match 'peor de 2 NCU') $true 'y de cuantas NCU sale'
Igual ($t -match 'tiempo de marcha') $true 'y como se va a comprobar'
$t = Gw-TextoReinicio @{ncu='?'; nGw=0; ip='10.100.1.99'; tcus=$null} $null 0 2
Igual ($t -match 'IP a mano') $true 'con IP a mano se dice'
Igual ($t -match 'no se cuantos') $true 'y que no se sabe cuantos cuelgan'
Igual ($t -match 'no se ha podido leer el viento') $true 'y sin viento se avisa'
Igual ($t -match '2 consultadas') $true 'y cuantas se intentaron'
$t = Gw-TextoReinicio $gws[0] @{nivel=1; alarma=$true} 1 1
Igual ($t -match 'CON ALARMA') $true 'la alarma de viento sale en el texto'

# ---- Y EL MANEJADOR PASA POR DONDE TIENE QUE PASAR ----
$h = [regex]::Match($src, '(?s)\$btnIGGwReinicio\.Add_Click\(\{(.*?)\n\} \}\)').Groups[1].Value
Igual ($h.Length -gt 100) $true 'hay manejador'
Igual ($h -match 'Gw-ObjetivoReinicio') $true 'elige UN gateway'
Igual ($h -match 'Gw-Carga-Leer \$gw\.ip') $true 'lee el uptime ANTES'
Igual ($h -match 'NO se reinicia \$\{clave\}: no contesta') $true 'y sin uptime de antes no manda nada'
# la CONDICION, no solo el aviso: una mutacion dejo el texto y quito el if
Igual ($h -match 'if \(-not \$k0\.ok -or \$null -eq \$k0\.carga\.uptime\) \{') $true 'y la guarda mira que haya contestado Y que de uptime'
Igual ($h -match 'Viento-Seguro') $true 'mira el viento'
Igual ($h -match 'Gw-VientoPeor') $true 'de todas las NCU'
Igual ($h -match 'MessageBox') $true 'pregunta'
Igual ($h -match 'Rci-Post \$gw\.ip \$to \$RCI_REINICIO') $true 'manda el reboot por RCI'
Igual ($h -match 'Gw-ReinicioVolvio \$antes \$vuelta \$cayo') $true 'y juzga por el uptime, con si cayo o no'
# el orden: viento ANTES de preguntar, y preguntar ANTES de mandar
Igual ($h.IndexOf('Gw-Carga-Leer') -lt $h.IndexOf('Viento-Seguro')) $true 'primero el uptime, luego el viento'
Igual ($h.IndexOf('Viento-Seguro') -lt $h.IndexOf('MessageBox')) $true 'el viento antes de preguntar'
Igual ($h.IndexOf('MessageBox') -lt $h.IndexOf('$RCI_REINICIO')) $true 'y preguntar antes de mandar'
Igual ($src -match "RCI_REINICIO = '<rci_request version=`"1.1`"><reboot/></rci_request>'") $true 'el verbo es reboot'
Igual ($src -match 'VERIFICADO EN PLANTA el 02/10/2026') $true 'y queda dicho cuando se vio funcionar de verdad'
Igual ($src -match 'no se ha visto todavia contra un ConnectPort') $false 'y ya no dice que no se ha visto'

Write-Host 'test_gw_reinicio.ps1: OK'
