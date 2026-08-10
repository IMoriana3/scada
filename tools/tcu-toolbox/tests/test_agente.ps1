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
 {"nombre":"Sim NCU1","ip":"127.0.0.1","puerto":15020,"tcu_ini":1,"tcu_fin":3,"hsu":185},
 {"nombre":"Sim NCU2","ip":"127.0.0.1","puerto":15020,"tcu_ini":1,"tcu_fin":2,"hsu":185}
]}
'@ | Set-Content (Join-Path $tmp 'tcu-toolbox/plantas/sim.json') -Encoding UTF8
(@{planta='Sim'; token=$TOKEN; puerto=$PUERTO; puerto_ncu=15020; timeout_ms=3000
   permitir_escritura=$true; intervalo_vigilante_min=0} | ConvertTo-Json) |
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

    $b = Pedir '/baterias'
    Check 'baterias: tipo correcto' $b.tipo 'baterias_tcu'
    Check 'baterias: una fila por TCU' (@($b.tcus).Count) 5
    Check 'baterias: lleva la columna Carga' ($null -ne @($b.tcus)[0].PSObject.Properties['Carga']) 'True'

    $inv = Pedir '/inventario'
    Check 'inventario: tipo correcto' $inv.tipo 'inventario_tcu'
    # Ident-Leer devuelve Campo/Valor: si se indexa mal, todo sale nulo
    Check 'inventario: las columnas no salen nulas' ($null -ne @($inv.tcus)[0].FW) 'True'

    $l = Pedir '/leer?vars=41010&tcus=1-2'
    Check 'leer: resuelve el prefijo' (@($l.variables)[0].StartsWith('41010')) 'True'
    Check 'leer: dos TCUs por NCU' (@($l.tcus).Count) 4

    # la misma gramatica que la toolbox, tambien al leer, y con filtro de gateway
    $l2 = Pedir '/leer?vars=41010&tcus=1/1,2/2'
    Check 'leer: la seleccion puede cruzar NCUs' (@($l2.tcus).Count) 2
    Check 'leer: y dice de que NCU es cada una' ((@($l2.tcus | ForEach-Object { $_.NCU } | Sort-Object -Unique)) -join ',') '1,2'
    Check 'leer: lleva la columna GW' ($null -ne @($l2.tcus)[0].PSObject.Properties['GW']) 'True'
    $l3 = Pedir '/leer?vars=41010&gw=15020'
    Check 'leer: el filtro de gateway deja pasar el suyo' (@($l3.tcus).Count -gt 0) 'True'
    $l4 = Pedir '/leer?vars=41010&gw=9999'
    Check 'leer: y con un gateway que no existe, nada' (@($l4.tcus).Count) 0
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
    Check 'escribir-lote: una fila por TCU' (@($e2.filas).Count) 2
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

    try { $null = Pedir '/no-existe'; Check 'ruta desconocida' 'pasa' '404' }
    catch { Check 'ruta desconocida da 404' '404' '404' }
}
finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($fallos -eq 0) { Write-Host 'AGENTE: TODAS LAS PRUEBAS OK'; exit 0 }
Write-Host "AGENTE: $fallos PRUEBAS FALLIDAS"; exit 1
