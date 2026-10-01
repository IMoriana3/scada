# La configuracion de la NCU: copia, comparacion y cambio. Sin red y sin NCU.
# Lo que de verdad se prueba aqui es que NO SE PUEDE MANDAR lo que no se pidio
# mandar, porque una escritura de configuracion va con la red dentro.
$ErrorActionPreference = 'Stop'
$fuente = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores.Count) { throw "TCU_Toolbox.ps1 con errores de sintaxis: $($errores.Count)" }
foreach ($n in @('Api-Clonar','Api-Tipo','Api-ListaPlana','Api-Breve','Api-Diferencias','Api-CambioSeguro',
                 'Api-GrupoEditar','Api-GrupoBandera','Api-Ajuste','Api-TextoCambio','Api-Escribir','Api-GrupoDe',
                 'Api-Reinicio-Volvio','Api-TextoReinicio','Api-Reiniciar','Api-IdaYVuelta')) {
    $nodos = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    if ($nodos.Count -ne 1) { throw "Se esperaba una sola funcion $n (hay $($nodos.Count))" }
    . ([scriptblock]::Create($nodos[0].Extent.Text))
}
$src = Get-Content $fuente -Raw
foreach ($v in @('$API_INTOCABLE','$API_INTOCABLE_PATRON','$API_COPIA_PROF','$API_BANDERAS','$API_AJUSTES',
                 '$API_ESCRITURA_CONFIRMADA','$API_ESCRITURA_FALTA','$API_ESCRITURA_PANEL','$API_CONFIG','$API_PUERTO',
                 '$API_REINICIO','$API_REINICIO_ESPERA_S','$API_REINICIO_PASO_S')) {
    $nodo = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($x.Left)" -eq $v }, $true))
    if ($nodo.Count -ne 1) { throw "Se esperaba una sola asignacion de $v (hay $($nodo.Count))" }
    . ([scriptblock]::Create($nodo[0].Extent.Text))
}
function Igual($real, $esperado, [string]$que) { if ("$real" -ne "$esperado") { throw "$que : obtenido '$real', esperado '$esperado'" } }
$datos = Get-Content (Join-Path $PSScriptRoot 'fixture_panel_ncu.json') -Raw | ConvertFrom-Json
$cfg = $datos.config_data.config

# ---- la copia es INDEPENDIENTE: si no, se compara contra lo ya manoseado ----
$c = Api-Clonar $cfg
Igual (@($c.tracker_groups).Count) 3 'la copia trae los grupos'
$c.tracker_groups[0].trackers = @(99)
Igual ((@($cfg.tracker_groups[0].trackers) -join ',')) '1,2,3' 'tocar la copia NO toca lo que se leyo de la NCU'
Igual ($null -eq (Api-Clonar $null)) $true 'clonar nada no revienta'

# ---- las diferencias ----
Igual (@(Api-Diferencias $cfg (Api-Clonar $cfg)).Count) 0 'una copia identica no difiere en nada'
$d1 = Api-Clonar $cfg; $d1.tcu_timeout = 900
$difs = @(Api-Diferencias $cfg $d1)
Igual $difs.Count 1 'un campo cambiado es una diferencia'
Igual $difs[0].Ruta 'tcu_timeout' 'con su ruta'
Igual "$($difs[0].Antes) -> $($difs[0].Ahora)" '6000 -> 900' 'y el antes y el despues'

# UNA LISTA DE SEGUIDORES SE COMPARA COMO CONJUNTO, no por posicion: quitar uno
# del medio corre todos los de detras y por posicion saldrian diez diferencias
# donde solo ha pasado una cosa.
$d2 = Api-Clonar $cfg; $d2.tracker_groups[0].trackers = @(1,3)
$difs2 = @(Api-Diferencias $cfg $d2)
Igual $difs2.Count 1 'quitar un seguidor es UNA diferencia, no una por posicion'
Igual $difs2[0].Antes 'quitado: 2' 'y dice cual se ha quitado'
$d3 = Api-Clonar $cfg; $d3.tracker_groups[0].trackers = @(1,2,3,9)
Igual ((@(Api-Diferencias $cfg $d3)[0]).Ahora) 'metido: 9' 'y cual se ha metido'
# en cambio una lista de OBJETOS si va por posicion, que es donde importa
$d4 = Api-Clonar $cfg; $d4.modbus_networks[1].hsus[1].modbus_id = 211
Igual ((@(Api-Diferencias $cfg $d4)[0]).Ruta) 'modbus_networks[1].hsus[1].modbus_id' 'una lista de objetos va por posicion'
# y un texto que solo cambia de mayusculas SI es un cambio
$d5 = Api-Clonar $cfg; $d5.plant_id = 'elburgo'
Igual (@(Api-Diferencias $cfg $d5).Count) 1 'un cambio de mayusculas cuenta'

# ================= LA GUARDA: lo que de verdad protege =================
$g = Api-GrupoEditar $cfg 1 @(2) $false
Igual $g.ok $true 'se puede sacar un seguidor de un grupo'
Igual ((@($g.cfg.tracker_groups[0].trackers) -join ',')) '1,3' 'y sale'
Igual ($g.permitidas -join ',') 'tracker_groups[0].trackers' 'el cambio declara que iba a tocar'
$s = Api-CambioSeguro $cfg $g.cfg $g.permitidas
Igual $s.ok $true 'un cambio que toca solo lo que declaro, pasa'
Igual $s.difs.Count 1 'con su unica diferencia'

# un cambio que toca algo MAS de lo que declaro, no pasa
$sucio = Api-Clonar $g.cfg
$sucio.tcu_timeout = 900
$s2 = Api-CambioSeguro $cfg $sucio $g.permitidas
Igual $s2.ok $false 'tocar algo que no se declaro NO pasa'
Igual ($s2.nota -match 'tcu_timeout') $true 'y se dice exactamente que'

# LA RED NO SE TOCA NUNCA, aunque alguien la meta en las permitidas
$red = Api-Clonar $cfg
$red.ip_config.ip = '10.100.1.99'
$s3 = Api-CambioSeguro $cfg $red @('ip_config')
Igual $s3.ok $false 'la IP de la NCU no se puede cambiar NI pidiendolo'
Igual ($s3.fuera[0].Ruta -match 'ip_config') $true 'y se nombra'
$red2 = Api-Clonar $cfg
$red2.modbus_networks[0].ip = '192.168.0.99'
Igual ((Api-CambioSeguro $cfg $red2 @('modbus_networks')).ok) $false 'ni la IP de una red Modbus'
$red3 = Api-Clonar $cfg
$red3.modbus_networks[0].port = 503
Igual ((Api-CambioSeguro $cfg $red3 @('modbus_networks')).ok) $false 'ni su puerto'
# pero los esclavos de dentro SI son configuracion normal
$esc = Api-Clonar $cfg
$esc.modbus_networks[0].hsus[0].modbus_id = 229
Igual ((Api-CambioSeguro $cfg $esc @('modbus_networks')).ok) $true 'un esclavo de dentro si se puede cambiar'

Igual ((Api-CambioSeguro $cfg (Api-Clonar $cfg) @('tcu_timeout')).ok) $false 'sin cambios no hay nada que mandar'
Igual ((Api-CambioSeguro $cfg (Api-Clonar $cfg) @('tcu_timeout')).nota -match 'ningun cambio') $true 'y se dice'

# ---- meter y sacar de grupos: lo que se rechaza y por que ----
Igual ((Api-GrupoEditar $cfg 9 @(1) $false).ok) $false 'un grupo que no existe se rechaza'
Igual ((Api-GrupoEditar $cfg 9 @(1) $false).nota -match 'tiene 3') $true 'diciendo cuantos hay'
Igual ((Api-GrupoEditar $cfg 1 @() $false).ok) $false 'sin seguidores no se hace nada'
Igual ((Api-GrupoEditar $cfg 1 @(7) $false).ok) $false 'sacar uno que no esta en ese grupo'
Igual ((Api-GrupoEditar $cfg 1 @(99) $true).ok) $false 'meter un seguidor que la NCU no tiene configurado'
Igual ((Api-GrupoEditar $cfg 1 @(99) $true).nota -match 'no existe') $true 'y se dice por que'
Igual ((Api-GrupoEditar $cfg 1 @(7) $true).ok) $false 'meter uno que ya esta en OTRO grupo'
Igual ((Api-GrupoEditar $cfg 1 @(7) $true).nota -match 'ya esta en el grupo 3') $true 'diciendo en cual'
Igual ((Api-GrupoEditar $cfg 1 @(7) $true).nota -match 'regla nuestra') $true 'y que esa regla es nuestra, no de la API'
Igual ((Api-GrupoEditar $cfg 1 @(1,2,3) $true).ok) $false 'meter los que ya estaban no es un cambio'
$m = Api-GrupoEditar $cfg 1 @(6) $true
Igual $m.ok $false 'el 6 no esta configurado en la maqueta tampoco'
# sacar varios, con uno que no estaba: se hace y se avisa
$q = Api-GrupoEditar $cfg 1 @(2,7) $false
Igual $q.ok $true 'sacar varios con uno que no estaba, se hace'
Igual ($q.nota -match 'no estaban: 7') $true 'y se avisa del que no estaba'

# ---- banderas y ajustes ----
Igual ((Api-GrupoBandera $cfg 3 'difuso' $true).ok) $false 'poner una bandera a lo que ya vale, no es cambio'
$b = Api-GrupoBandera $cfg 3 'difuso' $false
Igual $b.ok $true 'quitar el difuso del grupo 3'
Igual ($b.permitidas -join ',') 'tracker_groups[2].diffuse_tracking_enable' 'declarando su ruta'
Igual ((Api-CambioSeguro $cfg $b.cfg $b.permitidas).ok) $true 'y pasa la guarda'
Igual ((Api-GrupoBandera $cfg 1 'inventada' $true).ok) $false 'una bandera que no se sabe cambiar'

Igual ((Api-Ajuste $cfg 'tcu_interval_ms' 10).ok) $false 'un sondeo de 10 ms no se manda'
Igual ((Api-Ajuste $cfg 'tcu_interval_ms' 10).nota -match '250') $true 'y se dice el rango'
# OJO: esto comprobaba que un timeout de 5 se rechazaba, con el rango 30..3600
# que me invente. La captura del 01/10 enseno que El Burgo lleva 6000, o sea que
# ese rango rechazaba lo que la NCU tiene puesto. Ahora los limites solo cazan
# dedazos, asi que un 5 PASA -no sabemos que sea malo- y lo que no pasa es el 0,
# el negativo y lo absurdo.
Igual ((Api-Ajuste $cfg 'tcu_timeout' 0).ok) $false 'un timeout de 0 no se manda'
Igual ((Api-Ajuste $cfg 'tcu_timeout' -5).ok) $false 'ni uno negativo'
Igual ((Api-Ajuste $cfg 'tcu_timeout' 999999).ok) $false 'ni uno absurdo'
Igual ((Api-Ajuste $cfg 'tcu_timeout' 'ocho').ok) $false 'ni algo que no es un numero'
Igual ((Api-Ajuste $cfg 'tcu_timeout' 6000).ok) $false 'ni el valor que ya tiene'
Igual ((Api-Ajuste $cfg 'inventado' 1).ok) $false 'ni un campo que no se sabe cambiar'
$a = Api-Ajuste $cfg 'tcu_timeout' 900
Igual $a.ok $true 'un timeout razonable si'
Igual ((Api-CambioSeguro $cfg $a.cfg $a.permitidas).ok) $true 'y pasa la guarda'
$w = Api-Ajuste $cfg 'modbus_enable_writing' $false
Igual $w.ok $true 'la escritura Modbus se puede desmarcar desde aqui'

# ---- el texto de confirmar ensena TODO lo que cambia ----
$t = Api-TextoCambio '2' 'Sacar el seguidor 2 del grupo 1' $s.difs 'C:\x\copia.json'
Igual ($t -match 'tracker_groups\[0\]\.trackers') $true 'la ventana nombra lo que cambia'
Igual ($t -match 'quitado: 2') $true 'y que se quita'
Igual ($t -match 'ENTERA') $true 'avisa de que se manda la configuracion entera'
Igual ($t -match 'copia\.json') $true 'y dice donde quedo la copia'
Igual ($t -match 'se relee y se compara') $true 'y que se verifica despues'

# ============ LA ESCRITURA, YA ARMADA: QUE SIGUE ENTRE MEDIAS ============
# Armarla no quita frenos, deja que exista el ultimo tramo. Lo que se comprueba
# aqui es que ese tramo sigue teniendo delante todo lo demas, y sobre todo que
# NO SALE NADA que la ida y vuelta no haya aprobado.
Igual $API_ESCRITURA_CONFIRMADA $true 'la escritura esta armada'
Igual $API_ESCRITURA_PANEL 'v1.17.1' 'con el panel contra el que se capturo anotado'

# lo que se manda es EXACTAMENTE lo que aprobo la ida y vuelta, no otra cosa
$script:cuerpo = $null; $script:tipo = $null; $script:verbo = $null; $script:uri = $null
function Invoke-RestMethod {
    param([string]$Uri, [string]$Method, [string]$ContentType, $Body, $WebSession, [int]$TimeoutSec)
    $script:uri = $Uri; $script:verbo = $Method; $script:tipo = $ContentType; $script:cuerpo = $Body
    return @{ok = $true}
}
$w = Api-Escribir '10.100.1.56' $null $cfg 5000
Igual $w.ok $true 'armada, escribe'
Igual $script:verbo 'Put' 'con PUT, como la captura'
Igual $script:tipo 'text/plain' 'y con text/plain, como la captura'
Igual $script:uri 'http://10.100.1.56:80/private_api/config' 'contra el extremo de configuracion'
Igual ($script:cuerpo -eq (Api-IdaYVuelta $cfg).texto) $true 'y manda EXACTAMENTE el texto que aprobo la ida y vuelta'
Igual (($script:cuerpo | ConvertFrom-Json).plant_id) 'ElBurgo' 'que es JSON y es la configuracion'
Igual (($script:cuerpo | ConvertFrom-Json).ip_config.ip) '10.100.1.56' 'con la red intacta: va el objeto entero'

# Y SI LA IDA Y VUELTA NO APRUEBA, NO SALE NADA. Esta es la que de verdad
# protege ahora que esta armada: antes bastaba con que el seguro estuviera
# puesto, ahora hay que comprobar que el ultimo freno frena.
$script:cuerpo = $null; $script:salidas = 0
function Invoke-RestMethod { $script:salidas++; return @{ok = $true} }
$hondoW = [pscustomobject]@{v = 1}
for ($i = 0; $i -lt ($API_COPIA_PROF + 10); $i++) { $hondoW = [pscustomobject]@{dentro = $hondoW} }
$wMal = Api-Escribir '10.100.1.56' $null $hondoW 5000
Igual $wMal.ok $false 'una configuracion que no sobrevive al JSON no se manda'
Igual $script:salidas 0 'y NO llega a llamar al cliente HTTP'
Igual ($wMal.nota -match 'no sobrevive') $true 'diciendo por que'

# el extremo peligroso existe en UN solo sitio, y es el bloque desarmado
# Esto contaba apariciones del texto y se quedo corto en cuanto la evidencia de
# la captura entro en un comentario y en un mensaje: el texto aparece 4 veces y
# solo UNA es una peticion. Lo que importa no es cuantas veces se escribe, es
# cuantas veces se USA, asi que se cuenta sobre el AST y no sobre el fuente.
$usaCfg = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Where-Object { "$($_.GetCommandName())" -match '^Invoke-(RestMethod|WebRequest)$' -and
                           "$($_.Extent.Text)" -match 'API_CONFIG' })
Igual $usaCfg.Count 1 'el extremo de configuracion se USA en una sola llamada'
$ponPut = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Where-Object { "$($_.GetCommandName())" -match '^Invoke-(RestMethod|WebRequest)$' -and "$($_.Extent.Text)" -match 'Method Put' })
Igual $ponPut.Count 1 'y hay exactamente una escritura, la suya'
Igual (@($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) |
         Where-Object { "$($_.Extent.Text)" -match 'private_api/(ota|commands)' }).Count) 0 'ni firmware ni reinicio'

# ================= EL REINICIO =================
# Va armado y la escritura no, y la diferencia esta en COMO FALLA cada uno si
# nos hemos equivocado de ruta: un POST sin cuerpo contra una ruta mala da 404 y
# no pasa nada; un PUT con el objeto entero contra una forma mala se aplica a
# medias. Falla seguro frente a falla peligroso.

# QUE CONTESTE NO ES QUE HAYA REINICIADO. Si la NCU no hizo caso y sigue como
# estaba, contesta igual de bien: lo unico que lo distingue es que su tiempo de
# marcha haya ido hacia atras.
Igual ((Api-Reinicio-Volvio 163441033 4200).ok) $true 'el tiempo de marcha ha bajado: ha reiniciado de verdad'
Igual ((Api-Reinicio-Volvio 163441033 163460000).ok) $false 'contesta pero lleva MAS tiempo en marcha: no ha reiniciado'
Igual ((Api-Reinicio-Volvio 163441033 163460000).nota -match 'NO ha reiniciado') $true 'y se dice, no se da por bueno'
Igual ((Api-Reinicio-Volvio 163441033 163441033).ok) $false 'ni el mismo tiempo de marcha vale'
Igual ((Api-Reinicio-Volvio 163441033 $null).ok) $false 'si no vuelve a contestar, tampoco'
# QUE NO CONTESTE EN NUESTRA VENTANA NO ES QUE ESTE MAL. La espera es un numero
# que pusimos nosotros sin saber cuanto tarda una NCU en arrancar, asi que
# cantarlo como fallo manda a alguien a la planta por nada.
$aun = Api-Reinicio-Volvio 163441033 $null
Igual ($aun.nota -match 'no ha contestado todavia') $true 'un "aun no" no se canta como "no ha vuelto"'
Igual ($aun.nota -match 'vuelve a LEER PANEL') $true 'y se dice que hacer antes de alarmarse'
Igual $aun.tarda $true 'se marca como "tarda", para pintarlo distinto de un fallo'
Igual ((Api-Reinicio-Volvio 163441033 163460000).tarda) $false 'en cambio no reiniciar SI es un fallo'
Igual ((Api-Reinicio-Volvio 163441033 4200).tarda) $false 'y el caso bueno tampoco es "tarda"'

# la ventana dice lo que se para Y lo que no: el seguimiento no se para, la
# posicion segura si, y eso es lo que decide si se pulsa o no
$tr = Api-TextoReinicio '2' 108 @{nivel = 0; alarma = $false}
Igual ($tr -match '108 seguidor') $true 'dice a cuantos afecta'
Igual ($tr -match 'siguen al sol por su cuenta') $true 'y que el seguimiento NO se para'
Igual ($tr -match 'NO HAY QUIEN MANDE UNA POSICION SEGURA') $true 'y que la posicion segura SI'
Igual ($tr -match 'el SCADA deja de ver la planta') $true 'y que el SCADA se queda ciego'
Igual ($tr -match 'nivel 0') $true 'con el viento de ahora delante'
Igual ((Api-TextoReinicio '2' 108 $null) -match 'no se ha podido leer el viento') $true 'y si no se pudo leer, lo admite'
Igual ((Api-TextoReinicio '2' 108 @{nivel=2; alarma=$true}) -match 'CON ALARMA') $true 'la alarma de viento se canta'

# el boton existe, pide viento fresco y se niega con viento
Igual ($src.Contains('$btnPANReiniciar.Add_Click')) $true 'hay boton de reinicio'
Igual ($src -match 'Viento-Seguro "\$\(\$n\.ip\)" \$cx\.to\r?\n') $true 'que lee el viento SIN cache: el tecnico acaba de pulsar'
Igual ($src.Contains('NO se reinicia: hay viento')) $true 'y se niega si lo hay'
Igual ($src.Contains("Api-GuardarCopia `$n 'antes de reiniciar'")) $true 'y guarda copia antes, que es cuando se quiere tener'

# un 404 no se confunde con un reinicio: si la ruta no existe, no ha pasado nada
$script:llamadas = 0
function Invoke-RestMethod { $script:llamadas++; throw [System.Exception]::new('Response status code does not indicate success: 404 (Not Found).') }
$r404 = Api-Reiniciar '10.100.1.56' $null 5000
Igual $r404.ok $false 'un 404 no se da por reiniciado'
Igual ($r404.nota -match 'panel de otra version') $true 'y se dice que esa NCU no tiene esa ruta'
# pero que se CORTE la conexion si es lo normal: esta reiniciando mientras contesta
function Invoke-RestMethod { throw [System.Exception]::new('The underlying connection was closed') }
$rCorte = Api-Reiniciar '10.100.1.56' $null 5000
Igual $rCorte.ok $true 'que se corte la conexion no es un fallo: esta reiniciando'
Igual ($rCorte.nota -match 'se comprueba abajo') $true 'y se verifica despues en vez de darlo por hecho'

# y el reinicio es un POST sin cuerpo util: nada que adivinar
Igual (@([regex]::Matches($src, [regex]::Escape('/private_api/commands/soft_restart'))).Count) 1 'el extremo de reinicio aparece una sola vez'
Igual ($src -match 'private_api/ota') $false 'y el de firmware sigue sin aparecer ni escrito'

# ===== LO QUE DESTAPO LA CAPTURA DE UNA ESCRITURA REAL (01/10/2026) =====
# Mirando el cuerpo del PUT con el DevTools salieron dos fallos de aqui.

# 1) EL CUERPO TRAE http_port Y modbus_port al mismo nivel que todo lo demas, y
#    los bloques gw1_config/gw2_config con la red de los Digi. No estaban en los
#    intocables, y son el mismo desastre que la IP: cambiar http_port deja la
#    pagina inalcanzable en el :80 y modbus_port deja al SCADA sin ver la planta.
foreach ($campo in @('http_port', 'modbus_port')) {
    $x = Api-Clonar $cfg
    $x.$campo = 8080
    Igual ((Api-CambioSeguro $cfg $x @($campo)).ok) $false "$campo no se puede cambiar NI pidiendolo"
}
$gw2 = Api-Clonar $cfg
$gw2.gw1_config.network.ip = '10.100.1.99'
Igual ((Api-CambioSeguro $cfg $gw2 @('gw1_config')).ok) $false 'ni la red de un Digi'
$gw3 = Api-Clonar $cfg
$gw3.gw2_config.network.gateway = '10.100.1.1'
Igual ((Api-CambioSeguro $cfg $gw3 @('gw2_config')).ok) $false 'ni la puerta de enlace del otro'

# y un campo que esta NCU no tenga no revienta: se dice
$sinCampo = Api-Clonar $cfg
$sinCampo.PSObject.Properties.Remove('ncu_interval_ms')
Igual ((Api-Ajuste $sinCampo 'ncu_interval_ms' 2000).ok) $false 'un campo que la NCU no trae no se inventa'
Igual ((Api-Ajuste $sinCampo 'ncu_interval_ms' 2000).nota -match 'no tiene el campo') $true 'y se dice, en vez de reventar'

# 2) EL RANGO INVENTADO RECHAZABA UN VALOR REAL. El Burgo NCU2 lleva el
#    tcu_timeout en 6000 y el limite estaba en 3600: la herramienta habria
#    rechazado el valor que el aparato tiene puesto.
$real = Api-Clonar $cfg
$real.tcu_timeout = 6000
Igual ((Api-Ajuste $real 'tcu_timeout' 7000).ok) $true 'el rango ya no rechaza valores del orden del que lleva la NCU de verdad'
Igual ((Api-Ajuste $cfg 'tcu_timeout' 6500).ok) $true 'ni valores del orden del 6000 que lleva El Burgo'
Igual ((Api-Ajuste $cfg 'tcu_interval_ms' 10).ok) $false 'pero un dedazo de 10 ms sigue sin pasar'
Igual ($src -match 'limites de DEDAZO') $true 'y se dice que son limites nuestros, no documentacion'
Igual ((Api-Ajuste $cfg 'ncu_interval_ms' 2000).ok) $true 'el sondeo de NCU, que la captura enseno, tambien se sabe cambiar'

# 3) LA IDA Y VUELTA POR JSON. Lo que sale por el cable no es el objeto que la
#    NCU nos dio, es lo que PowerShell escribe al reserializarlo. Y como el PUT
#    va con el objeto ENTERO, una perdida ahi se la queda la NCU.
$iv = Api-IdaYVuelta $cfg
Igual $iv.ok $true 'la configuracion de la maqueta sobrevive a la ida y vuelta'
Igual ($iv.texto.Length -gt 100) $true 'y devuelve el texto que se mandaria'
Igual (($iv.texto | ConvertFrom-Json).plant_id) 'ElBurgo' 'texto que es JSON de verdad'
Igual ((Api-IdaYVuelta ($iv.texto | ConvertFrom-Json)).ok) $true 'y es estable: la vuelta de la vuelta tambien'
# Y LA GUARDA TIENE QUE CAZAR UNA PERDIDA DE VERDAD. ConvertTo-Json corta al
# pasar de su profundidad y lo que hay debajo sale como texto, sin avisar: es
# exactamente la clase de perdida silenciosa que se llevaria el PUT. Una
# configuracion mas honda que $API_COPIA_PROF lo reproduce.
$hondo = [pscustomobject]@{v = 1}
for ($i = 0; $i -lt ($API_COPIA_PROF + 10); $i++) { $hondo = [pscustomobject]@{dentro = $hondo} }
$ivMal = Api-IdaYVuelta $hondo
Igual $ivMal.ok $false 'una configuracion que NO sobrevive a la ida y vuelta se caza'
Igual ($ivMal.nota -match 'no sobrevive a la ida y vuelta') $true 'y se dice que ha pasado'
Igual ($ivMal.nota -match 'el objeto entero') $true 'y por que importa: el PUT se llevaria la perdida'
Igual $ivMal.texto '' 'y no se devuelve texto que mandar'
# y el Content-Type raro de la NCU queda escrito donde se manda
Igual ($src -match "ContentType 'text/plain'") $true 'se manda con text/plain, que es lo que la NCU usa para su JSON'
Igual ($src -match 'Method Put') $true 'y con PUT'
Igual ($src -match 'Content-Length: 10203') $true 'la evidencia de la captura queda escrita al lado'
Igual ($src -match 'panel v1\.17\.1') $true 'con el panel contra el que se comprobo'

# la evidencia de la captura sigue escrita al lado del codigo que la usa
Igual ($API_ESCRITURA_PANEL -ne '') $true 'queda anotado el panel contra el que se capturo'

Write-Host 'test_panel_cfg.ps1: OK'
