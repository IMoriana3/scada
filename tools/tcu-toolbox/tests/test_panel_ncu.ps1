# Prueba del lector del panel web de la NCU, contra una maqueta con la
# ESTRUCTURA REAL de un initial_data de El Burgo: huecos vacios en
# tracker_status, una TCU muda, una recien caida, mas huecos de HSU con trafico
# que estaciones declaradas, y un grupo de un solo seguidor con difuso.
# Sin red: aqui no se prueba el transporte, se prueba lo que se dice del dato.
$ErrorActionPreference = 'Stop'
$fuente = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores.Count) { throw "TCU_Toolbox.ps1 con errores de sintaxis: $($errores.Count)" }

$puras = @('Api-DeNcu', 'Api-Gravedad', 'Gr-Alcance', 'Gr-AvisoEscritura', 'Api-Vista', 'Api-Filas', 'Api-Rango', 'Api-Pct', 'Api-Edad', 'Api-Grupos', 'Api-GrupoDe', 'Api-TcusDeGrupos',
           'Api-TrackersCfg', 'Api-Alineado', 'Api-Equipos', 'Api-Mudas', 'Api-Resumen',
           'Api-Topologia', 'Api-HsusExternas', 'Api-Hsus', 'Api-Avisos')
foreach ($n in $puras) {
    $nodos = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    if ($nodos.Count -ne 1) { throw "Se esperaba una sola funcion $n (hay $($nodos.Count))" }
    . ([scriptblock]::Create($nodos[0].Extent.Text))
}
$src = Get-Content $fuente -Raw
# la tabla de vistas es dato: se trae tal cual del fichero
$nodo = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                                   "$($x.Left)" -eq '$API_VISTAS' }, $true))
if ($nodo.Count -ne 1) { throw "Se esperaba una sola asignacion de API_VISTAS (hay $($nodo.Count))" }
. ([scriptblock]::Create($nodo[0].Extent.Text))
$API_HSU_ERR_AVISO = [double]([regex]::Match($src, '\$API_HSU_ERR_AVISO\s*=\s*([\d.]+)')).Groups[1].Value
$API_TCU_ERR_AVISO = [double]([regex]::Match($src, '\$API_TCU_ERR_AVISO\s*=\s*([\d.]+)')).Groups[1].Value

function Igual($real, $esperado, [string]$que) { if ("$real" -ne "$esperado") { throw "$que : obtenido '$real', esperado '$esperado'" } }
$maqueta = Join-Path $PSScriptRoot 'fixture_panel_ncu.json'
if (-not (Test-Path $maqueta)) { throw "falta la maqueta $maqueta" }
$datos = Get-Content $maqueta -Raw | ConvertFrom-Json
$cfg = $datos.config_data.config

# ---- tramos: la pestana de grupos ensena 108 seguidores en una celda ----
Igual (Api-Rango @(1,2,3,10)) '1-3, 10' 'tramos con un salto'
Igual (Api-Rango @(98,99,100,101,102,103,104,105,106,107,109)) '98-107, 109' 'el hueco del 108 de El Burgo se ve'
Igual (Api-Rango @(5)) '5' 'uno solo no se pinta como tramo'
Igual (Api-Rango @()) '' 'sin numeros, nada'
Igual (Api-Rango @(3,1,2)) '1-3' 'desordenados se ordenan'
Igual (Api-Rango @(4,4,5)) '4-5' 'repetidos no duplican'

# ---- un 0 % y un "no se ha preguntado" no pueden salir igual ----
Igual (Api-Pct 0 100) 0 'cero por ciento de cien peticiones es 0'
Igual ($null -eq (Api-Pct 0 0)) $true 'sin peticiones no hay porcentaje'
Igual (Api-Pct 1308 1308) 100 'todas fallidas son el 100 %'
Igual (Api-Pct 1 3) 33.3 'se redondea a un decimal'

# ---- la edad va contra el reloj de la NCU, no contra el del portatil ----
Igual (Api-Edad 1000000 940000) 60 'un minuto de edad'
Igual ($null -eq (Api-Edad 1000000 0)) $true 'si nunca contesto, no hay edad'

# ---- los grupos tal y como los tiene la NCU ----
$gr = @(Api-Grupos $cfg)
Igual $gr.Count 3 'tres grupos en la maqueta'
Igual $gr[0].TCUs '1-3' 'el grupo 1 son sus seguidores'
Igual $gr[0].Seguidores 3 'y se cuentan'
Igual $gr[0].HSU 'cualquiera' 'hsu 255 es cualquiera, no la estacion 255'
Igual $gr[2].Difuso 'SI' 'el grupo con difuso se marca'
Igual $gr[1].Difuso '-' 'y los demas no'
Igual $gr[0].Stow_limit 'si' 'el limite de stow se dice'

# ---- LA FUNCION POR LA QUE MERECE LA PENA: bitset de grupos -> seguidores ----
Igual ((Api-TcusDeGrupos $cfg 1) -join ',') '1,2,3' 'grupo 1'
Igual ((Api-TcusDeGrupos $cfg 5) -join ',') '1,2,3,7' 'grupos 1 y 3, sin pisarse'
Igual ((Api-TcusDeGrupos $cfg 0).Count) 0 'ningun grupo, ningun seguidor'
Igual ((Api-TcusDeGrupos $cfg 1023) -join ',') '1,2,3,4,5,7' 'todos los grupos dan todos los configurados'
Igual (Api-GrupoDe $cfg 5) 2 'el 5 esta en el grupo 2'
Igual (Api-GrupoDe $cfg 6) 0 'el 6 no esta en ninguno'

# ---- el hueco de tracker_status: alineado SI, y por comprobacion ----
$al = Api-Alineado $datos.tracker_status $cfg
Igual $al.ok $true 'con la maqueta real los huecos con trafico son los esclavos configurados'

# y si NO cuadra, las filas salen sin numerar en vez de con el numero equivocado
$sucio = [System.Management.Automation.PSSerializer]::Deserialize(
             [System.Management.Automation.PSSerializer]::Serialize($datos, 4))
$sucio.tracker_status[6].total_requests = 500      # el 6 no esta configurado
$mal = Api-Alineado $sucio.tracker_status $cfg
Igual $mal.ok $false 'trafico en un hueco no configurado rompe el alineamiento'
Igual ($mal.nota -match 'sin numerar') $true 'y lo dice'
$eq = @(Api-Equipos $sucio $cfg)
Igual (@($eq | Where-Object { "$($_.TCU)" -ne '' }).Count) 0 'mal alineado: ninguna fila lleva numero'
Igual (@($eq | Where-Object { "$($_.Grupo)" -ne '' }).Count) 0 'ni grupo, que saldria del numero'

# ---- los equipos ----
$eq = @(Api-Equipos $datos $cfg)
Igual $eq.Count 6 'seis equipos con trafico; los dos huecos vacios no son equipos'
Igual (@($eq | Where-Object { "$($_.TCU)" -eq '0' }).Count) 0 'el hueco 0 no sale como TCU 0'
$t3 = @($eq | Where-Object { "$($_.TCU)" -eq '3' })[0]
Igual $t3.Estado 'MUDA' 'la que nunca contesto es MUDA, no "va regular"'
Igual $t3.Error_pct 100 'y lleva su 100 %'
Igual $t3.Edad_s '' 'sin ultima lectura buena no se inventa una edad'
Igual $t3.Grupo '1' 'y se dice en que grupo esta, que es a quien afecta'
$t5 = @($eq | Where-Object { "$($_.TCU)" -eq '5' })[0]
Igual $t5.Estado 'SIN COMUNICACION' 'la caida ahora mismo se distingue de la muda'
Igual ($t5.Edad_s -gt 600) $true 'y se ve cuanto lleva caida'
$t4 = @($eq | Where-Object { "$($_.TCU)" -eq '4' })[0]
Igual $t4.Estado 'muchos errores' 'por encima del umbral se avisa aunque conteste'
Igual (@($eq | Where-Object { "$($_.TCU)" -eq '7' })[0].Estado) 'OK' 'la buena sale OK'
Igual (@(Api-Mudas $datos $cfg).Count) 1 'una sola muda'

# ---- las HSUs van por HUECO y sin numerar, a proposito ----
$hs = @(Api-Hsus $datos)
Igual $hs.Count 6 'seis huecos de HSU con trafico'
Igual (@($hs | Where-Object { $_.PSObject.Properties.Name -contains 'HSU' }).Count) 0 'ninguna columna afirma el numero de HSU'
Igual $hs[1].Nota 'sin identidad local: probablemente prestada de otra NCU' 'la que no da producto se explica'
Igual (@($hs | Where-Object { "$($_.Nota)" -eq 'MUCHOS ERRORES' }).Count) 1 'una estacion por encima del umbral'
Igual ((Api-Pct 8638 32667) -ge $API_HSU_ERR_AVISO) $true 'el 26 % de El Burgo pasa el umbral'

# ---- la topologia, para carearla con plants.yml sin mirar capturas ----
$tp = @(Api-Topologia $cfg)
Igual $tp.Count 2 'dos redes Modbus = dos gateways'
Igual $tp[0].Modbus_en '192.168.0.36:502' 'y se dice en que IP habla cada una'
Igual $tp[1].HSUs 2 'el GW2 lleva DOS estaciones: el "una por gateway" no se cumple'
Igual ($tp[1].HSU_detalle -match 'esclavo 210') $true 'incluida la 210, que no esta en plants.yml'
Igual $tp[1].Rango '4-5, 7' 'con su rango de seguidores'
$ex = @(Api-HsusExternas $cfg)
Igual $ex.Count 2 'dos estaciones prestadas'
Igual $ex[0].De '10.100.1.52' 'de la otra NCU'

# ---- el resumen ----
$rs = Api-Resumen $datos
Igual $rs.Planta 'ElBurgo' 'la planta'
Igual $rs.FW 'v1.17.1' 'la version, que decide si tiene los registros del R8'
Igual $rs.Escritura_modbus 'PERMITIDA' 'y si deja escribir, ANTES de intentarlo'
Igual $rs.Uptime_h 45.4 'el uptime en horas'
$bloq = [System.Management.Automation.PSSerializer]::Deserialize(
            [System.Management.Automation.PSSerializer]::Serialize($datos, 4))
$bloq.config_data.config.modbus_enable_writing = $false
Igual ((Api-Resumen $bloq).Escritura_modbus) 'BLOQUEADA' 'desmarcado se ve'
Igual (@(@(Api-Avisos $bloq $cfg) | Where-Object { "$($_.Que)" -match 'BLOQUEADA' }).Count) 1 'y sale como aviso'

# ---- los avisos, cada uno con el numero que lo sostiene ----
$av = @(Api-Avisos $datos $cfg)
foreach ($a in $av) { Igual ("$($a.Detalle)".Length -gt 0) $true "el aviso '$($a.Que)' trae su dato" }
Igual (@($av | Where-Object { "$($_.Que)" -eq 'TCUs mudas' }).Count) 1 'avisa de las mudas'
Igual (@($av | Where-Object { "$($_.Que)" -match 'no cuadra' }).Count) 1 'y de que seis huecos no son cinco estaciones'
$ft = @($av | Where-Object { "$($_.Que)" -match 'Fulltracking' })
Igual $ft.Count 1 'y de las capacidades que no ve'
Igual ($ft[0].Detalle -match 'no se sabe') $true 'diciendo que es un no se sabe, no un no lo soporta'

# ---- LAS COLUMNAS DECLARADAS CONTRA LAS PROPIEDADES DE VERDAD ----
# Esto es lo que impide que un renombrado deje una columna vacia sin que nadie
# se entere: para cada vista, las columnas que se pintan tienen que ser
# exactamente los campos que la funcion devuelve, en el mismo orden.
Igual ($API_VISTAS.Count -ge 7) $true 'estan las siete vistas'
foreach ($v in $API_VISTAS) {
    $filas = @(Api-Filas $v $datos $cfg)
    Igual ($filas.Count -ge 1) $true "la vista $($v.txt) da al menos una fila con la maqueta"
    if ($v.uno) { Igual $filas.Count 1 "la vista $($v.txt) da una sola fila por NCU" }
    $props = @($filas[0].PSObject.Properties.Name)
    $cols  = @($v.cols | ForEach-Object { "$($_.t)" })
    Igual ($props -join '|') ($cols -join '|') "la vista $($v.txt): columnas declaradas = campos devueltos"
    foreach ($c in $v.cols) { Igual ([int]$c.w -gt 0) $true "la columna $($c.t) de $($v.txt) tiene ancho" }
}
Igual ((Api-Vista 'Grupos').fn) 'Api-Grupos' 'las vistas se buscan por su nombre'
Igual ($null -eq (Api-Vista 'no existe')) $true 'y una que no existe no devuelve otra'
Igual (@(Api-Filas $null $datos $cfg).Count) 0 'sin vista, ninguna fila'

# cada vista pide lo que necesita y nada mas: una que diga 'cfg' no puede estar
# usando el estado por detras, o fallaria con una lectura a medias
foreach ($v in $API_VISTAS) {
    if ("$($v.arg)" -eq 'cfg') { Igual (@(Api-Filas $v $null $cfg).Count -ge 1) $true "la vista $($v.txt) se pinta solo con la configuracion" }
}

# ---- el color va por palabras, para poder probar la REGLA sin ventana ----
$vEq = Api-Vista 'Equipos'
$eq = @(Api-Equipos $datos $cfg)
Igual (Api-Gravedad $vEq (@($eq | Where-Object { "$($_.TCU)" -eq '3' })[0])) 'mal' 'una muda sale en rojo'
Igual (Api-Gravedad $vEq (@($eq | Where-Object { "$($_.TCU)" -eq '5' })[0])) 'mal' 'una caida tambien'
Igual (Api-Gravedad $vEq (@($eq | Where-Object { "$($_.TCU)" -eq '4' })[0])) 'aviso' 'muchos errores, en naranja'
Igual (Api-Gravedad $vEq (@($eq | Where-Object { "$($_.TCU)" -eq '7' })[0])) 'bien' 'y la buena en verde'
$vHs = Api-Vista 'HSUs'
Igual (Api-Gravedad $vHs (@(Api-Hsus $datos)[5])) 'mal' 'la estacion con el 26 % de error, en rojo'
Igual (Api-Gravedad $vHs (@(Api-Hsus $datos)[1])) 'gris' 'la prestada en gris: no es un fallo, es que no es suya'
Igual (Api-Gravedad (Api-Vista 'Resumen') (Api-Resumen $datos)) 'normal' 'un resumen sin nada que mirar no se pinta'
Igual (Api-Gravedad (Api-Vista 'Resumen') (Api-Resumen $bloq)) 'aviso' 'con la escritura bloqueada, si'
Igual (Api-Gravedad (Api-Vista 'Topología') ([pscustomobject]@{})) 'normal' 'una vista sin regla no revienta'

# ---- EL ENGANCHE CON LA PESTANA DE GRUPOS: el alcance de la orden ----
# Esto es lo que justifica todo el lector: antes de mandar nada, decir a
# CUANTOS seguidores va y cuales.
$cache = @(@{ncu='2'; ip='10.100.1.56'; cuando=(Get-Date '2026-10-01 11:22:33'); datos=$datos; cfg=$cfg})
Igual ((Api-DeNcu $cache '2').ip) '10.100.1.56' 'la lectura se encuentra por su NCU'
Igual ($null -eq (Api-DeNcu $cache '3')) $true 'y de otra NCU no se devuelve la de al lado'
Igual ($null -eq (Api-DeNcu @() '2')) $true 'sin cache, nada'

$al = Gr-Alcance $cache @('2') 1
Igual ($al -match 'SON 3 SEGUIDOR') $true 'el grupo 1 son tres seguidores y lo dice'
Igual ($al -match '1-3') $true 'y los nombra'
Igual ($al -match '11:22:33') $true 'con la hora del volcado: un recuento sin fecha parece permanente'
Igual ($al -match 'lo dice la NCU') $true 'y diciendo que lo dice la NCU, no nosotros'
Igual ((Gr-Alcance $cache @('2') 5) -match 'SON 4 SEGUIDOR') $true 'dos grupos suman sin contar dos veces'

# un grupo VACIO: mandar una orden ahi no da error en ningun sitio y el tecnico
# se iria al campo a ver por que no se ha movido nada
$vacio = [System.Management.Automation.PSSerializer]::Deserialize(
             [System.Management.Automation.PSSerializer]::Serialize($cfg, 6))
$vacio.tracker_groups[0].trackers = @()
$cv = @(@{ncu='2'; ip='10.100.1.56'; cuando=(Get-Date); datos=$datos; cfg=$vacio})
Igual ((Gr-Alcance $cv @('2') 1) -match 'NINGUN seguidor') $true 'un grupo vacio se dice: la orden no movera nada'

# sin panel leido no se inventa un recuento
Igual ((Gr-Alcance @() @('2') 1) -match 'no se sabe') $true 'sin leer el panel, se admite que no se sabe'
Igual ((Gr-Alcance @() @('2') 1) -match 'Panel NCU') $true 'y se dice donde leerlo'

# un total A MEDIAS es peor que ninguno: si falta una NCU, se dice cual
$parcial = Gr-Alcance $cache @('2','3') 1
Igual ($parcial -match 'SON 3 SEGUIDOR') $true 'cuenta lo que sabe'
Igual ($parcial -match 'NCU 3 NO se sabe') $true 'y nombra la NCU que falta'
Igual ($parcial -match 'NO estan contadas') $true 'avisando de que no estan en el total'

# ---- "Allow writing" ANTES de escribir, no despues de fallar ----
Igual (Gr-AvisoEscritura $cache @('2')) '' 'con la escritura permitida no se avisa de nada'
$cb = @(@{ncu='2'; ip='10.100.1.56'; cuando=(Get-Date); datos=$bloq; cfg=$bloq.config_data.config})
$avE = Gr-AvisoEscritura $cb @('2')
Igual ($avE -match 'DESMARCADA') $true 'desmarcada se avisa'
Igual ($avE -match 'NO la va a aplicar') $true 'diciendo lo que va a pasar de verdad: la acepta y no la aplica'
Igual (Gr-AvisoEscritura @() @('2')) '' 'sin panel leido no se avisa de lo que no se sabe'

# y la ventana de confirmar lo lleva de verdad
$nodoC = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Gr-TextoConfirmar' }, $true))
. ([scriptblock]::Create($nodoC[0].Extent.Text))
foreach ($n in @('Gr-Accion', 'Ncu-Grupos')) {
    $nd = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true))
    . ([scriptblock]::Create($nd[0].Extent.Text))
}
$GR_SP7 = [int]([regex]::Match($src, '\$GR_SP7\s*=\s*(\d+)')).Groups[1].Value
$txt = Gr-TextoConfirmar (Gr-Accion 'Pasar a AUTO') 1 1 '' $null $al
Igual ($txt -match 'SON 3 SEGUIDOR') $true 'la ventana de confirmar ensena el alcance'
Igual ($txt -match 'no se sabe') $false 'y ya no dice que no se sabe'
$txtSin = Gr-TextoConfirmar (Gr-Accion 'Pasar a AUTO') 1 1
Igual ($txtSin -match 'no se sabe') $true 'sin alcance sigue admitiendolo, que es lo honesto'
Igual ($src.Contains('Gr-Alcance $script:ApiUltimo $script:GrNcus $bits')) $true 'y el boton de grupos lo pasa'
Igual ($src.Contains('Gr-AvisoEscritura $script:ApiUltimo $script:GrNcus')) $true 'junto con el aviso de escritura'

# ---- EL CAMINO DE LECTURA SIGUE SIENDO DOS LLAMADAS ----
# Esto decia "solo lee" y dejo de ser verdad cuando entro la escritura de
# configuracion (v11.96), asi que se ha reescrito en vez de aflojarse: lo que se
# exige ahora es que la LECTURA no haya crecido -el login y el volcado, y nada
# mas- y que lo unico que escribe sea el bloque de configuracion, que va
# desarmado y tiene sus propias guardas en test_panel_cfg.ps1.
$llamadas = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) |
              Where-Object { "$($_.GetCommandName())" -match '^Invoke-(RestMethod|WebRequest)$' })
$dePanel = @($llamadas | Where-Object { "$($_.Extent.Text)" -match 'API_AUTH|API_DATOS|API_CONFIG|API_REINICIO|private_api' })
$deLectura = @($dePanel | Where-Object { "$($_.Extent.Text)" -match 'API_AUTH|API_DATOS' })
Igual $deLectura.Count 2 'leer el panel siguen siendo dos llamadas: el login y el volcado'
Igual (@($deLectura | Where-Object { "$($_.Extent.Text)" -match "Method Post" }).Count) 1 'una sola POST, la del login'
Igual (@($deLectura | Where-Object { "$($_.Extent.Text)" -match "Method (Put|Patch|Delete)" }).Count) 0 'y ninguna escritura en el camino de lectura'
Igual $dePanel.Count 4 'contra el panel hay CUATRO llamadas: login, volcado, configuracion (desarmada) y reinicio'
# El reinicio SI esta y la escritura de configuracion no, y la diferencia no es
# capricho: un POST sin cuerpo contra una ruta equivocada da 404 y no pasa nada;
# un PUT con el objeto entero contra una forma equivocada se aplica a medias.
# Falla seguro frente a falla peligroso.
Igual ($src -match 'private_api/commands/soft_restart') $true 'el reinicio esta, y va armado'
# EL FIRMWARE DE LA NCU SE QUEDA FUERA, Y ES UNA DECISION TOMADA (01/10/2026),
# no una tarea a medias: que nadie lo retome creyendo que se quedo colgado.
#
# Ojo con el motivo, que la v11.96 lo puso FALSO: decia que lo hace el TCU
# Updater, y el TCU Updater actualiza las TCUs, no la NCU. El firmware de la NCU
# se sube por su pagina web y seguira siendo asi.
#
# El motivo de verdad: todo lo demas de esta pestana se apoya en escribir y
# RELEER para comprobarlo. Con una imagen de firmware no hay nada que releer, y
# si sube a medias la NCU se queda inservible y fuera de alcance -ni web, ni
# Modbus, ni desde aqui-, lo que se arregla yendo a la planta con un cable. Es la
# unica operacion que no se podria deshacer desde esta herramienta.
Igual ($src -match 'private_api/ota') $false 'el extremo de firmware no aparece ni escrito'
# La escritura de configuracion ya va ARMADA (01/10/2026, decision de Inaki tras
# capturar la peticion real). Lo que se exige ahora no es que este desarmada,
# sino que no pueda salir por descuido: que pase por la ida y vuelta por JSON
# -el ultimo freno- y que lo que se mande sea lo que esa guarda aprobo. Eso se
# comprueba ejecutandolo en test_panel_cfg.ps1; aqui basta con que el freno siga
# estando en el camino.
Igual ($src -match '\$iv = Api-IdaYVuelta \$cfg') $true 'la escritura pasa por la ida y vuelta por JSON'
Igual ($src -match '-Body \$iv\.texto') $true 'y manda lo que esa guarda aprobo, no otra cosa'

# la contrasena no se guarda en ningun sitio que sobreviva a cerrar la ventana
Igual ($src -match 'txtPANPass[^
]*config_local') $false 'la contrasena del panel no va a config_local.json'
Igual ($src.Contains('$txtPANPass.UseSystemPasswordChar = $true')) $true 'y la caja no la ensena'

Write-Host 'test_panel_ncu.ps1: OK'
