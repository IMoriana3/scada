# Prueba del TCU Agente de punta a punta: lo arranca de verdad contra
# mb_server.py y le pide TODAS las rutas. Es la unica forma de saber que el
# agente sigue funcionando despues de tocar la toolbox, porque no tiene copia de
# la logica: la extrae de TCU_Toolbox.ps1 por nombre de funcion.
#
#   python3 mb_server.py &
#   pwsh -NoProfile -File test_agente.ps1
$ErrorActionPreference = 'Stop'
$raizTb  = Split-Path $PSScriptRoot -Parent
$raizAg  = Join-Path (Split-Path $raizTb -Parent) 'tcu-agente'
$tmp     = Join-Path ([System.IO.Path]::GetTempPath()) ('ag_' + [guid]::NewGuid().ToString('N').Substring(0,8))
$PUERTO  = 18586
$TOKEN   = 'token-de-prueba-largo-0123456789'
$fallos  = 0
function Check([string]$n, $v, $e) {
    if ("$v" -eq "$e") { Write-Host "OK   $n = $v" }
    else { Write-Host "FAIL $n : obtenido '$v', esperado '$e'" -ForegroundColor Red; $script:fallos++ }
}

# --- una instalacion de campo en miniatura: las dos carpetas, al lado ---
New-Item -ItemType Directory -Path (Join-Path $tmp 'tcu-toolbox/plantas') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'tcu-agente') -Force | Out-Null
Copy-Item (Join-Path $raizTb 'TCU_Toolbox.ps1') (Join-Path $tmp 'tcu-toolbox') -Force
Copy-Item (Join-Path $raizAg 'TCU_Agente.ps1')  (Join-Path $tmp 'tcu-agente')  -Force
@'
{"version":1,"plantas":[
 {"nombre":"Sim NCU1","ip":"127.0.0.1","puerto":15020,"tcu_ini":1,"tcu_fin":3,"hsu":185,
  "huecos":[2],
  "repetidores":[{"nombre":"Repetidor 1","esclavo":200}]},
 {"nombre":"Sim NCU2","ip":"127.0.0.1","puerto":15020,"tcu_ini":1,"tcu_fin":2,"hsu":185}
]}
'@ | Set-Content (Join-Path $tmp 'tcu-toolbox/plantas/sim.json') -Encoding UTF8
(@{planta='Sim'; token=$TOKEN; puerto=$PUERTO; puerto_ncu=15020; timeout_ms=3000
   permitir_escritura=$true; intervalo_vigilancia_min=0
   _comentario='config de pruebas'} | ConvertTo-Json) |
   Set-Content (Join-Path $tmp 'tcu-agente/agente_config.json') -Encoding UTF8

$pwshExe = (Get-Process -Id $PID).Path
# -WindowStyle no existe en pwsh de Linux; sin el vale en los dos
$proc = Start-Process -FilePath $pwshExe -PassThru `
    -ArgumentList '-NoProfile', '-File', (Join-Path $tmp 'tcu-agente/TCU_Agente.ps1') `
    -RedirectStandardOutput (Join-Path $tmp 'agente.log') -RedirectStandardError (Join-Path $tmp 'agente.err')

function Pedir([string]$ruta, [string]$metodo = 'GET', $cuerpo = $null) {
    # -NoProxy: en un portatil con proxy de empresa, localhost tambien se iria
    # por el y la peticion nunca llega al agente
    $p = @{Uri = "http://localhost:$PUERTO$ruta"; Method = $metodo; NoProxy = $true
           Headers = @{'X-Token' = $TOKEN; 'X-Usuario' = 'pruebas'}; TimeoutSec = 120}
    if ($null -ne $cuerpo) { $p.Body = (ConvertTo-Json $cuerpo -Depth 6); $p.ContentType = 'application/json' }
    return Invoke-RestMethod @p
}
try {
    # el agente tarda unos segundos en cargar la logica de la toolbox
    $vivo = $false
    for ($i = 0; $i -lt 40 -and -not $vivo; $i++) {
        Start-Sleep -Milliseconds 500
        try { $null = Pedir '/ping'; $vivo = $true } catch {}
    }
    if (-not $vivo) { throw "el agente no arranca. Log:`r`n" + (Get-Content (Join-Path $tmp 'agente.log') -Raw) + (Get-Content (Join-Path $tmp 'agente.err') -Raw) }

    $ping = Pedir '/ping'
    Check 'ping: responde' $ping.ok 'True'
    Check 'ping: dice la planta' $ping.planta 'Sim'
    Check 'ping: y las dos NCUs' (@($ping.ncus).Count) 2
    Check 'ping: carga la toolbox de al lado' ($ping.toolbox.Length -gt 0) 'True'

    # sin token no se entra
    try { Invoke-RestMethod -Uri "http://localhost:$PUERTO/ping" -TimeoutSec 10 -NoProxy; Check 'seguridad: sin token' 'entra' 'no entra' }
    catch { Check 'seguridad: sin token no entra' 'no entra' 'no entra' }

    $d = Pedir '/diagnostico'
    Check 'diagnostico: tipo correcto' $d.tipo 'diagnostico_tcu'
    Check 'diagnostico: trae filas' (@($d.tcus).Count -gt 0) 'True'
    Check 'diagnostico: con la columna GW' ($null -ne @($d.tcus)[0].PSObject.Properties['GW']) 'True'

    # --- NCUs, TCUs y GW: la web los manda en la query y valen para TODA ruta
    # que recorra la planta, no solo para /leer y /inventario ---
    Check 'ping: dice los gateways que hay' (@($ping.gws) -contains '15020') 'True'
    $d1 = Pedir '/diagnostico?ncus=1'
    Check 'sel: ncus=1 deja solo esa NCU' (@($d1.tcus | ForEach-Object { "$($_.NCU)" } | Sort-Object -Unique) -join ',') '1'
    $d2 = Pedir '/diagnostico?tcus=2-3'
    Check 'sel: tcus=2-3 acota tambien el diagnostico' (@($d2.tcus | Where-Object { "$($_.TCU)" -eq '1' }).Count) 0
    # ojo: el diagnostico lleva ademas la fila de salud de la NCU y la de su HSU
    $d3 = Pedir '/diagnostico?ncus=2&tcus=2'
    $d3t = @($d3.tcus | Where-Object { "$($_.TCU)" -match '^\d+$' })
    Check 'sel: y se combinan' ($d3t.Count) 1
    Check 'sel: con la NCU pedida' "$($d3t[0].NCU)" '2'
    Check 'sel: y la TCU pedida' "$($d3t[0].TCU)" '2'
    $d4 = Pedir "/diagnostico?gw=15020"
    Check 'sel: el gateway tambien filtra aqui' (@($d4.tcus).Count -gt 0) 'True'
    # una NCU que no existe no puede pasar por "todas": eso seria leer de mas
    try { $null = Pedir '/diagnostico?ncus=99'; Check 'sel: NCU inexistente avisa' 'pasa' 'no pasa' }
    catch { Check 'sel: NCU inexistente avisa' 'no pasa' 'no pasa' }
    # y el filtro no se queda pegado para la siguiente peticion ni para el SAT
    $d5 = Pedir '/diagnostico'
    Check 'sel: el filtro no se queda pegado' (@($d5.tcus | ForEach-Object { "$($_.NCU)" } | Sort-Object -Unique).Count) 2

    # un cliente que cuelga NO puede tumbar el agente: pasaba de verdad en planta
    # -un inventario largo, el navegador se cansa, y Write lanzaba
    # HttpListenerException que se llevaba por delante el servicio entero-
    try {
        $c = [System.Net.Sockets.TcpClient]::new('localhost', $PUERTO)
        $st = $c.GetStream()
        $pet = [Text.Encoding]::ASCII.GetBytes("GET /diagnostico HTTP/1.1`r`nHost: localhost`r`nX-Token: $TOKEN`r`n`r`n")
        $st.Write($pet, 0, $pet.Length); $st.Flush()
        Start-Sleep -Milliseconds 150
        $c.Close()                      # colgamos sin leer la respuesta
    } catch {}
    Start-Sleep -Seconds 2
    $vivo2 = $false
    try { $null = Pedir '/ping'; $vivo2 = $true } catch {}
    Check 'el agente sobrevive a un cliente que cuelga' $vivo2 'True'

    # el diagnostico lista TODOS los equipos declarados, contesten o no: la NCU,
    # sus TCUs (sin los huecos), sus repetidores y sus HSUs. Antes, una NCU a la
    # que no se llega aportaba UNA fila en vez de las suyas y el total bailaba.
    $dF = Pedir '/diagnostico'
    $porTipo = @{}
    foreach ($f in @($dF.tcus)) {
        $t = "$($f.TCU)"
        $k = $(if ($t -eq 'NCU') { 'NCU' } elseif ($t -like 'HSU*') { 'HSU' } elseif ($t -match '^\d+$') { 'TCU' } else { 'REP' })
        $porTipo[$k] = 1 + [int]$porTipo[$k]
    }
    Check 'flota: una fila por NCU' ([int]$porTipo['NCU']) 2
    Check 'flota: y los repetidores tambien salen' (([int]$porTipo['REP']) -ge 1) 'True'
    # NCU1 declara 1-3 con el 2 de hueco (2 TCUs) y NCU2 1-2: cuatro en total
    Check 'flota: ninguna TCU se queda sin fila' ([int]$porTipo['TCU']) 4
    Check 'hueco: el 2 de la NCU1 no existe' (@($dF.tcus | Where-Object { "$($_.NCU)" -eq '1' -and "$($_.TCU)" -eq '2' }).Count) 0
    $rep1 = @($dF.tcus | Where-Object { "$($_.TCU)" -eq 'Repetidor 1' })[0]
    Check 'rep: sale con su nombre' ($null -ne $rep1) 'True'
    Check 'rep: y con su gateway' "$($rep1.GW)" '15020'

    # --- trabajos largos por trozos ---
    # el inventario de una planta entera no cabe en una peticion HTTP: se arranca,
    # se devuelve un id y el agente lo avanza entre peticiones, sirviendo mientras
    $j0 = Pedir '/trabajo'
    Check 'trabajo: al principio no hay ninguno' "$($j0.hay)" 'False'
    $j1 = Pedir '/trabajo/inventario'
    Check 'trabajo: arranca y da id' ($j1.id.Length) 8
    Check 'trabajo: dice cuantas TCUs' $j1.total 4
    Check 'trabajo: y que esta en curso' $j1.estado 'en curso'
    # y MIENTRAS corre, el agente sigue atendiendo: eso es todo el objetivo
    $pMientras = Pedir '/ping'
    Check 'trabajo: el agente sigue vivo mientras corre' "$($pMientras.ok)" 'True'
    $fin = $null
    for ($k = 0; $k -lt 60 -and $null -eq $fin; $k++) {
        Start-Sleep -Milliseconds 500
        $e = Pedir '/trabajo'
        if ("$($e.estado)" -eq 'hecho') { $fin = $e }
    }
    Check 'trabajo: termina' ($null -ne $fin) 'True'
    if ($fin) {
        Check 'trabajo: al 100%' $fin.pct 100
        Check 'trabajo: con el resultado dentro' $fin.resultado.tipo 'inventario_tcu'
        Check 'trabajo: y una fila por TCU' (@($fin.resultado.tcus).Count) 4
        Check 'trabajo: mismas columnas que el inventario de una vez' ($null -ne @($fin.resultado.tcus)[0].PSObject.Properties['Serie']) 'True'
    }

    # el diagnostico tambien por trozos: con 21 NCUs (San Jose) en serie se pasa
    # del corte de ~100 s del tunel. Se trocea por NCU, no por TCU.
    $jd = Pedir '/trabajo/diagnostico'
    Check 'trabajo diag: cuenta por NCUs' $jd.total 2
    Check 'trabajo diag: y lo dice' $jd.unidad 'NCU'
    $finD = $null
    for ($k = 0; $k -lt 60 -and $null -eq $finD; $k++) {
        Start-Sleep -Milliseconds 500
        $e = Pedir '/trabajo'
        if ("$($e.estado)" -eq 'hecho') { $finD = $e }
    }
    Check 'trabajo diag: termina' ($null -ne $finD) 'True'
    if ($finD) {
        Check 'trabajo diag: es un diagnostico' $finD.resultado.tipo 'diagnostico_tcu'
        # y sale la MISMA flota que el de una vez: mismo numero de filas
        $dUnaVez = Pedir '/diagnostico'
        Check 'trabajo diag: mismas filas que el de una vez' (@($finD.resultado.tcus).Count) (@($dUnaVez.tcus).Count)
        Check 'trabajo diag: con los repetidores' (@($finD.resultado.tcus | Where-Object { "$($_.TCU)" -like 'Repetidor*' }).Count) 1
    }

    $b = Pedir '/baterias'
    Check 'baterias: tipo correcto' $b.tipo 'baterias_tcu'
    # 4, no 5: la NCU1 declara el 2 como hueco y ese seguidor no existe
    Check 'baterias: una fila por TCU' (@($b.tcus).Count) 4
    Check 'baterias: lleva la columna Carga' ($null -ne @($b.tcus)[0].PSObject.Properties['Carga']) 'True'

    $inv = Pedir '/inventario'
    Check 'inventario: tipo correcto' $inv.tipo 'inventario_tcu'
    # Ident-Leer devuelve Campo/Valor: si se indexa mal, todo sale nulo
    Check 'inventario: las columnas no salen nulas' ($null -ne @($inv.tcus)[0].FW) 'True'

    $l = Pedir '/leer?vars=41010&tcus=1-2'
    Check 'leer: resuelve el prefijo' (@($l.variables)[0].StartsWith('41010')) 'True'
    # de la NCU1 solo la 1 (la 2 es hueco) y de la NCU2 las dos
    Check 'leer: las TCUs que existen del rango' (@($l.tcus).Count) 3

    # la misma gramatica que la toolbox, tambien al leer, y con filtro de gateway
    $l2 = Pedir '/leer?vars=41010&tcus=1/1,2/2'
    Check 'leer: la seleccion puede cruzar NCUs' (@($l2.tcus).Count) 2
    Check 'leer: y dice de que NCU es cada una' ((@($l2.tcus | ForEach-Object { $_.NCU } | Sort-Object -Unique)) -join ',') '1,2'
    Check 'leer: lleva la columna GW' ($null -ne @($l2.tcus)[0].PSObject.Properties['GW']) 'True'
    $l3 = Pedir '/leer?vars=41010&gw=15020'
    Check 'leer: el filtro de gateway deja pasar el suyo' (@($l3.tcus).Count -gt 0) 'True'
    $l4 = Pedir '/leer?vars=41010&gw=9999'
    Check 'leer: y con un gateway que no existe, nada' (@($l4.tcus).Count) 0


    # ---- el bloque de ESTADO (3xxxx), que el /leer no alcanzaba ----
    # Resolver-Variable solo miraba en las 125 de configuracion, asi que por el
    # agente el SCADA no podia leer ni SoC, ni SoH, ni alarmas, ni tilt, ni los
    # ciclos. Y Leer-Planta ya estaba escrito para admitirlas: era codigo muerto.
    $lc = Pedir '/leer?vars=30101&tcus=1-1'
    Check 'estado: los ciclos se pueden pedir por su registro' (@($lc.variables) -join ',') 'ESTADO 30101 ciclos_carga'
    Check 'estado: y llega un valor' (@($lc.tcus).Count -ge 1) $true
    $lcap = Pedir '/leer?vars=30099,30100,30101,30102&tcus=1-1'
    Check 'estado: capacidad, ciclos y conservacion de un tiron' (@($lcap.variables).Count) 4
    # y se puede mezclar con configuracion en la misma peticion
    $lmix = Pedir '/leer?vars=41010,30101&tcus=1-1'
    Check 'estado: mezclado con configuracion' (@($lmix.variables).Count) 2
    # un registro con dos campos no se resuelve a ciegas
    $amb = $null
    try { $amb = Pedir '/leer?vars=30096&tcus=1-1' } catch { $amb = 'error' }
    Check 'estado: 30096 es SoC y SoH, y no se elige por nosotros' ($amb -eq 'error') $true
    $lsoc = Pedir '/leer?vars=30096 SoC&tcus=1-1'
    Check 'estado: acotando, sale' ((@($lsoc.variables) -join ',') -like '*SoC*') $true
    Check 'baterias: tambien lleva GW' ($null -ne @($b.tcus)[0].PSObject.Properties['GW']) 'True'
    Check 'inventario: tambien lleva GW' ($null -ne @($inv.tcus)[0].PSObject.Properties['GW']) 'True'

    $c = Pedir '/cierre'
    Check 'cierre: responde aunque este vacio' ($null -ne $c.total) 'True'
    $t = Pedir '/trabajos'
    Check 'trabajos: responde' ($null -ne $t.trabajos) 'True'
    $h = Pedir '/hsus'
    Check 'hsus: responde' ($null -ne $h) 'True'
    $hm = Pedir '/hsus/meteo'
    Check 'hsus meteo: trae campos' (@($hm.filas).Count -gt 0) 'True'

    # auditoria: el preset viaja en el cuerpo y NO escribe
    $aud = Pedir '/auditoria' 'POST' @{preset = @(@{variable = '41010 longitud [deg]'; valor = '999'}); tcus = '1-2'}
    Check 'auditoria: tipo correcto' $aud.tipo 'auditoria_tcu'
    Check 'auditoria: lista las desviaciones' (@($aud.desviaciones).Count -gt 0) 'True'
    Check 'auditoria: dice lo esperado y lo leido' (@($aud.desviaciones)[0].Esperado) '999'

    # escrituras
    $e1 = Pedir '/escribir' 'POST' @{confirmar = $true; ncu = 1; tcus = '1'; variable = '41010'; valor = '-1.685'}
    Check 'escribir: una variable' $e1.ok 'True'
    $e2 = Pedir '/escribir-lote' 'POST' @{confirmar = $true; ncu = 1; tcus = '1-2'
        valores = @(@{variable = '41010'; valor = '-1.685'}, @{variable = '41111'; valor = '55'})}
    Check 'escribir-lote: varias variables' $e2.ok 'True'
    # La planta de prueba declara huecos:[2] en la Sim NCU1, o sea que la TCU 2
    # NO EXISTE ahi. Esta comprobacion esperaba 2 filas, o sea que el agente
    # escribia en un equipo que la topologia dice que no esta instalado: el
    # emparejamiento TCU->gateway miraba solo ini..fin e ignoraba los huecos.
    # Ahora son 1: la 1. Que es lo que hay.
    Check 'escribir-lote: no escribe en la TCU que no existe' (@($e2.filas).Count) 1
    Check 'escribir-lote: y la que escribe es la 1' ("$(@($e2.filas)[0].TCU)") '1'
    # la identidad de red no se escribe en remoto
    try { $null = Pedir '/escribir-lote' 'POST' @{confirmar = $true; ncu = 1; tcus = '1'; valores = @(@{variable = '41004'; valor = '5'})}
          Check 'escribir-lote: bloquea la identidad de red' 'paso' 'no pasa' }
    catch { Check 'escribir-lote: bloquea la identidad de red' 'no pasa' 'no pasa' }
    # el mismo cuadro que la toolbox offline: "12/10, 15/5-12" cruza NCUs sin
    # tener que decir cual, que es lo que el desplegable de la web no dejaba
    $e2b = Pedir '/escribir-lote' 'POST' @{confirmar = $true; tcus = '1/1, 2/2'
        valores = @(@{variable = '41010'; valor = '-1.685'})}
    Check 'escribir-lote: la seleccion puede cruzar NCUs' (@($e2b.filas | ForEach-Object { $_.ncu } | Sort-Object -Unique).Count) 2
    Check 'escribir-lote: y cada fila dice su NCU' (@($e2b.filas)[0].ncu.Length -gt 0) 'True'
    $mod = Pedir '/modo' 'POST' @{confirmar = $true; tcus = '1/1, 2/2'; modo = 'AUTO'}
    Check 'modo: tambien acepta la seleccion con NCU' (@($mod.filas).Count) 2

    $e3 = Pedir '/escribir-csv' 'POST' @{confirmar = $true
        csv = "NCU;TCU;variable;valor`n1;1;41010;-1.685`n2;2;41111;55"}
    Check 'escribir-csv: cruza NCUs' (@($e3.filas | ForEach-Object { $_.ncu } | Sort-Object -Unique).Count) 2
    # sin confirmar no se escribe nada
    try { $null = Pedir '/escribir' 'POST' @{ncu = 1; tcus = '1'; variable = '41010'; valor = '0'}
          Check 'escritura: exige confirmar' 'paso' 'no pasa' }
    catch { Check 'escritura: exige confirmar' 'no pasa' 'no pasa' }

    # SAT: se arranca aqui y graba en el disco de este PC
    $s0 = Pedir '/sat'
    Check 'sat: empieza parado' $s0.activo 'False'
    $s1 = Pedir '/sat/iniciar' 'POST' @{duracion = 1; unidad = 'minutos'; int_tcu = 15; int_comms = 5}
    Check 'sat: arranca' $s1.activo 'True'
    Start-Sleep -Seconds 8
    $s2 = Pedir '/sat'
    Check 'sat: va grabando' ($s2.pases_comm -gt 0) 'True'
    $csvs = @($s2.ficheros | Where-Object { $_.nombre -like '*.csv' })
    Check 'sat: escribe los tres CSV del anexo' ($csvs.Count) 3
    $s3 = Pedir '/sat/parar' 'POST' @{}
    Check 'sat: para' $s3.activo 'False'
    # y lo que graba lo entiende la toolbox
    $fComm = (Join-Path $tmp ('tcu-toolbox/informes/sat_Sim/comm_' + (Get-Date -Format 'yyyy-MM-dd') + '.csv'))
    Check 'sat: el CSV esta donde dice' (Test-Path $fComm) 'True'
    Check 'sat: con la cabecera del anexo' ((Get-Content $fComm -First 1)) 'ts;fecha;ncu;equipo;evento'
    # la descarga no puede salirse de su carpeta
    try { $null = Pedir '/sat/descargar?f=../../TCU_Toolbox.ps1'; Check 'sat: la descarga no sale de su carpeta' 'sale' 'no sale' }
    catch { Check 'sat: la descarga no sale de su carpeta' 'no sale' 'no sale' }

    $srcAg2Cfg = Get-Content (Join-Path $raizAg 'TCU_Agente.ps1') -Raw
    # ---- configuracion en remoto ----
    # VA AL FINAL A PROPOSITO: apaga la escritura y cierra el cerrojo, y el
    # cerrojo NO se puede reabrir en remoto. Cualquier prueba puesta detras se
    # quedaria sin poder hacer nada, que es justo lo que paso al escribirlas.
    # El agente leia la config AL ARRANCAR y nada mas: cambiar cada cuanto
    # vigila obligaba a entrar al PC de planta y reiniciar.
    $c0 = Pedir '/config'
    Check 'config: se puede consultar' ($null -ne $c0.planta) $true
    Check 'config: dice lo que esta corriendo AHORA' ($null -ne $c0._en_curso.intervalo_vigilancia_min) $true
    Check 'config: y su version' ($c0._en_curso.version_agente) '4.1'
    # LOS SECRETOS NO SE DEVUELVEN: quien pregunta ya tiene el token, y
    # devolverlo solo lo deja en el historial del navegador y en el tunel
    Check 'config: el token no se devuelve' ($c0.token) '(puesto)'
    # la config de pruebas no trae credenciales de Supabase: lo que se
    # comprueba es que NINGUN secreto salga en claro, no que existan
    Check 'config: ningun secreto sale en claro' (
        @(@('token','supabase_key','supabase_pass','supabase_email') | Where-Object {
            $v = "$($c0.$_)"; $v -ne '' -and $v -ne '(puesto)' -and $v -ne '(vacio)' }).Count) 0
    # cambiar y que se aplique EN CALIENTE
    $c1 = Pedir '/config' 'POST' @{intervalo_vigilancia_min = 17}
    Check 'config: acepta el cambio' $c1.ok $true
    Check 'config: y lo aplica al vuelo' ((Pedir '/config')._en_curso.intervalo_vigilancia_min) 17
    Check 'config: dice que cambio y desde que' ((@($c1.cambiados)[0].campo)) 'intervalo_vigilancia_min'
    Check 'config: con el valor de antes' ((@($c1.cambiados)[0].antes)) '0'
    # lo que NO se aplica hasta reiniciar se DICE, no se calla
    $c2 = Pedir '/config' 'POST' @{planta = 'Otra'}
    Check 'config: avisa de lo que pide reinicio' (@($c2.requieren_reinicio) -contains 'planta') $true
    [void](Pedir '/config' 'POST' @{planta = 'Sim'})
    # un campo inventado no se traga en silencio
    $c3 = Pedir '/config' 'POST' @{intervalo_vigilancia_min = 5; loquesea = 1}
    Check 'config: ignora lo que no existe' (@($c3.ignorados) -contains 'loquesea') $true
    Check 'config: pero aplica lo que si' ((Pedir '/config')._en_curso.intervalo_vigilancia_min) 5
    # y si NADA es reconocible, es un error, no un exito vacio
    $malo = $null
    try { $malo = Pedir '/config' 'POST' @{soloBasura = 1} } catch { $malo = 'error' }
    Check 'config: solo campos desconocidos es error' ($malo -eq 'error') $true
    # la escritura tambien se gobierna en remoto: es lo que se pidio
    $c4 = Pedir '/config' 'POST' @{permitir_escritura = $true}
    Check 'config: la escritura se puede encender en remoto' ((Pedir '/config')._en_curso.permitir_escritura) $true
    [void](Pedir '/config' 'POST' @{permitir_escritura = $false})
    Check 'config: y apagar' ((Pedir '/config')._en_curso.permitir_escritura) $false
    # el cambio se PERSISTE: un reinicio no lo deshace
    $cfgDisco = Get-Content (Join-Path $tmp 'tcu-agente/agente_config.json') -Raw | ConvertFrom-Json
    Check 'config: se guarda en el fichero' ($cfgDisco.intervalo_vigilancia_min) 5
    Check 'config: y no se pierde lo que no se toca' ($cfgDisco._comentario) 'config de pruebas'
    # y queda AUDITADO como cualquier escritura
    Check 'config: el cambio queda auditado' ($srcAg2Cfg -like '*Auditar $usuario ''config''*') $true
    # EL CERROJO: va abierto por decision del dueno -hoy lo usa una sola
    # persona- pero tiene que poder cerrarse sin tocar codigo, porque con la
    # config abierta el token es lo unico que separa a alguien de mover
    # seguidores. Se cierra en remoto y a partir de ahi NO se puede reabrir en
    # remoto: hay que ir al PC. Eso es lo que lo hace un cerrojo y no un aviso.
    [void](Pedir '/config' 'POST' @{config_remota_bloqueada = $true})
    Check 'cerrojo: queda cerrado' ((Pedir '/config')._bloqueada) $true
    $tras = $null
    try { $tras = Pedir '/config' 'POST' @{intervalo_vigilancia_min = 99} } catch { $tras = 'rechazado' }
    Check 'cerrojo: ya no acepta cambios' ($tras -eq 'rechazado') $true
    Check 'cerrojo: y no ha cambiado nada' ((Pedir '/config')._en_curso.intervalo_vigilancia_min) 5
    $reabrir = $null
    try { $reabrir = Pedir '/config' 'POST' @{config_remota_bloqueada = $false} } catch { $reabrir = 'rechazado' }
    Check 'cerrojo: NI SIQUIERA para reabrirse' ($reabrir -eq 'rechazado') $true
    Check 'cerrojo: sigue cerrado' ((Pedir '/config')._bloqueada) $true
    # leer sigue funcionando: el cerrojo es de escritura de config, no una mordaza
    Check 'cerrojo: consultar sigue valiendo' ($null -ne (Pedir '/config').planta) $true

    try { $null = Pedir '/no-existe'; Check 'ruta desconocida' 'pasa' '404' }
    catch { Check 'ruta desconocida da 404' '404' '404' }
}
finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
# ---------- Arrancar.ps1: tunel + agente en una sola ventana ----------
$fArr = Join-Path (Split-Path $PSScriptRoot -Parent) '../tcu-agente/Arrancar.ps1'
Check 'arrancar: existe el lanzador' (Test-Path $fArr) $true
$srcArr = Get-Content $fArr -Raw
$eArr = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($srcArr, [ref]$null, [ref]$eArr)
Check 'arrancar: parsea' (@($eArr).Count) 0
# la URL sale dentro de un recuadro, no en una linea suelta
$i = $srcArr.IndexOf('function Url-DeLog'); $f = $srcArr.IndexOf('# ---- 1.')
Invoke-Expression $srcArr.Substring($i, $f - $i)
$logReal = @'
2026-08-11T15:04:07Z INF Requesting new quick Tunnel on trycloudflare.com...
2026-08-11T15:04:09Z INF +--------------------------------------------------------------------------------------------+
2026-08-11T15:04:09Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):   |
2026-08-11T15:04:09Z INF |  https://held-convinced-site-workshops.trycloudflare.com                                    |
2026-08-11T15:04:09Z INF +--------------------------------------------------------------------------------------------+
'@
Check 'arrancar: saca la URL del recuadro' (Url-DeLog $logReal) 'https://held-convinced-site-workshops.trycloudflare.com'
Check 'arrancar: sin URL todavia, cadena vacia' (Url-DeLog 'INF Requesting new quick Tunnel...') ''
Check 'arrancar: no se cuela un dominio parecido' (Url-DeLog 'https://malo.trycloudflare.com.example.org/x') 'https://malo.trycloudflare.com'
Check 'arrancar: log vacio' (Url-DeLog '') ''
# el --http-host-header no es opcional: sin el, Windows responde 400
Check 'arrancar: pasa el http-host-header' ($srcArr.Contains("'--http-host-header'")) $true
# cerrar el agente anterior es lo que evita el 'puerto ya en uso'
Check 'arrancar: cierra el agente anterior' ($srcArr.Contains('TCU_Agente.ps1*') -and $srcArr.Contains('Stop-Process')) $true
Check 'arrancar: y no se mata a si mismo' ($srcArr.Contains('$_.ProcessId -ne $PID')) $true
# el .bat tiene que llamar al lanzador, no al agente a pelo
$srcBat = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) '../tcu-agente/TCU_Agente.bat') -Raw
Check 'arrancar: el .bat llama al lanzador' ($srcBat.Contains('Arrancar.ps1')) $true
# la URL se guarda: sin esto hay que ir a buscarla scrolleando
Check 'arrancar: deja la URL en un fichero' ($srcArr.Contains('ultima_url.txt')) $true
Check 'arrancar: y en el portapapeles' ($srcArr.Contains('Set-Clipboard')) $true
# ese fichero no puede acabar en el repo
Check 'arrancar: ultima_url.txt esta ignorado' ((Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) '../tcu-agente/.gitignore') -Raw).Contains('ultima_url.txt')) $true

Write-Host ''


Write-Host ''
Write-Host '== y solo el /leer abre el bloque de estado =='
# Resolver-Variable la usan tambien los caminos de ESCRITURA. Resolver ahi el
# nombre de un registro de solo lectura seria abrir la puerta a escribir en el,
# asi que el interruptor va apagado por defecto y solo lo enciende quien lee.
$srcAg2 = Get-Content (Join-Path $raizAg 'TCU_Agente.ps1') -Raw
$resuelven = @([regex]::Matches($srcAg2, 'Resolver-Variable [^\r\n]*') | ForEach-Object { $_.Value })
Check 'estado: hay tres sitios que resuelven' $resuelven.Count 3
Check 'estado: y solo UNO abre el estado' (@($resuelven | Where-Object { $_ -like '*-conEstado*' }).Count) 1
Check 'estado: los otros dos escriben, y van sin el' (@($resuelven | Where-Object { $_ -notlike '*-conEstado*' }).Count) 2

if ($fallos -eq 0) { Write-Host 'AGENTE: TODAS LAS PRUEBAS OK'; exit 0 }
Write-Host "AGENTE: $fallos PRUEBAS FALLIDAS"; exit 1
