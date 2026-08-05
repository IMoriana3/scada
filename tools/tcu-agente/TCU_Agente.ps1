# ============================================================================
#  TCU Agente v1.0 - API de SOLO LECTURA para la Toolbox web (piloto)
#  Corre en el PC de planta y expone por HTTP el diagnostico via NCU (bloque
#  compacto, sin Zigbee), las HSUs y el comisionado de la planta configurada.
#  Reutiliza la logica de TCU_Toolbox.ps1 (misma carpeta o ruta en config):
#  un unico origen de verdad, sin duplicar el cliente Modbus ni los mapas.
#
#  Seguridad: solo lectura (FC03); token obligatorio en la cabecera X-Token;
#  escucha en localhost (expon con cloudflared, ver README). No hay ningun
#  endpoint de escritura: escribir se sigue haciendo con la toolbox en local.
# ============================================================================
$ErrorActionPreference = 'Stop'
$VERSION_AGENTE = '2.0'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$dirBase = Split-Path -Parent $MyInvocation.MyCommand.Path
$rutaCfg = Join-Path $dirBase 'agente_config.json'
if (-not (Test-Path $rutaCfg)) { throw "Falta agente_config.json (copia agente_config.ejemplo.json y rellenalo)" }
$cfg = Get-Content $rutaCfg -Raw | ConvertFrom-Json
if (-not $cfg.token) { throw 'agente_config.json debe llevar un token (cadena larga aleatoria)' }

# --- cargar la logica de la toolbox (misma tecnica que su suite de pruebas) ---
$rutaTb = if ($cfg.toolbox) { $cfg.toolbox } else { Join-Path $dirBase '..\tcu-toolbox\TCU_Toolbox.ps1' }
if (-not (Test-Path $rutaTb)) { throw "No encuentro TCU_Toolbox.ps1 en '$rutaTb' (ajusta 'toolbox' en la config)" }
$dirToolbox = if ($cfg.dir_datos) { $cfg.dir_datos } else { Split-Path -Parent (Resolve-Path $rutaTb) }
$src = Get-Content $rutaTb -Raw
$ini = $src.IndexOf('$VERSION_TOOLBOX')
$fin = $src.IndexOf('$form = New-Object System.Windows.Forms.Form')
if ($ini -lt 0 -or $fin -lt 0) { throw 'No se pudo extraer la logica de la toolbox (marcadores no encontrados)' }
function Con([string]$t, $color = $null) { Write-Host $t }   # shim de consola para funciones extraidas
$logica = $src.Substring($ini, $fin - $ini).Replace('$PSScriptRoot', '$dirToolbox')
# funciones de la seccion de handlers que tambien necesitamos (mismos
# marcadores que la suite de pruebas de la toolbox)
$i3 = $src.IndexOf('function Params-Conexion'); $f3 = $src.IndexOf('function Rango-Tcus')       # Plan-Segmentos, Trabajos-Planta
$i4 = $src.IndexOf('function Fijar-Modo');      $f4 = $src.IndexOf('function Guardia-Viento')   # cambio de modo verificado
if ($i3 -lt 0 -or $f3 -lt 0 -or $i4 -lt 0 -or $f4 -lt 0) { throw 'No se pudieron extraer las funciones de handlers de la toolbox' }
$logica += "`n" + $src.Substring($i3, $f3 - $i3) + "`n" + $src.Substring($i4, $f4 - $i4)
Invoke-Expression $logica
if ($cfg.puerto_ncu) { $PUERTO_NCU = [int]$cfg.puerto_ncu }   # solo para pruebas con simulador

$script:Cancelar = $false
$timeoutMs = if ($cfg.timeout_ms) { [int]$cfg.timeout_ms } else { 8000 }

function Ncus-DePlanta {
    $p = $PLANTAS["$($cfg.planta) (Planta completa)"]
    if ($p -and $p.ncus) { return @($p.ncus) }
    # planta de una sola NCU: usar su entrada (auto) o su unica entrada
    foreach ($k in @($PLANTAS.Keys)) {
        if ($k -notlike "$($cfg.planta)*") { continue }
        $e = $PLANTAS[$k]
        if ($e.gws) { return @(@{ncu = 1; ip = $e.ip; gws = $e.gws; hsu = $e.hsu}) }
    }
    foreach ($k in @($PLANTAS.Keys)) {
        if ($k -notlike "$($cfg.planta)*" -or $k -eq '(manual)') { continue }
        $e = $PLANTAS[$k]
        if ($e.ip) { return @(@{ncu = 1; ip = $e.ip; gws = @(@{puerto=$e.puerto; ini=$e.ini; fin=$e.fin}); hsu = $e.hsu}) }
    }
    throw "planta '$($cfg.planta)' no encontrada en $dirToolbox\plantas"
}

function Tcus-DeNcu($n) {
    $lt = @()
    foreach ($g in $n.gws) { $lt += @([int]$g.ini..[int]$g.fin) }
    return @($lt | Sort-Object -Unique)
}

function Fila-Vacia([string]$ncu, $tcu, [string]$salud, [string]$alarmas) {
    return [pscustomobject]@{
        NCU=$ncu; TCU=$tcu; Salud=$salud; Modo=''
        Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''; Vbat_mV=''; Ibat_mA=''; Tbat_C=''; Tpcb_C=''
        Alarmas=$alarmas
        main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''
    }
}

# Diagnostico de la planta completa via NCU: mismo formato que el JSON que
# exporta la toolbox (tipo diagnostico_tcu), directamente subible al Historico.
function Diag-Planta {
    $filas = @()
    foreach ($n in (Ncus-DePlanta)) {
        $et = "$($n.ncu)"
        $dm = $null; $hsus = @(); $ns = $null
        try {
            Modbus-Conectar $n.ip $PUERTO_NCU $timeoutMs
            try { $ns = Ncu-Salud } catch {}
            $dm = Ncu-DiagCompat (Tcus-DeNcu $n)
            try { $hsus = @(Ncu-HsuCompat) } catch {}
            Modbus-Cerrar
        } catch {
            Modbus-Cerrar
            $filas += Fila-Vacia $et 'NCU' 'AVISO' "NCU sin respuesta en ${PUERTO_NCU}: $_"
            continue
        }
        if ($ns) {
            $f = Fila-Vacia $et 'NCU' $ns.salud ((@($ns.alarmas) + $(if ($ns.fecha) { @("reloj NCU: $($ns.fecha)") } else { @() })) -join '; ')
            $f.Modo = '-'
            $filas += $f
        }
        foreach ($h in $hsus) { $h.NCU = $et; $filas += $h }
        foreach ($tcu in (Tcus-DeNcu $n)) {
            $d = $null
            if ($dm) { $d = $dm[[int]$tcu] }
            if ($null -eq $d) { $filas += Fila-Vacia $et $tcu 'OFFLINE' 'sin datos via NCU' }
            else { $d | Add-Member -NotePropertyName NCU -NotePropertyValue $et -Force; $filas += $d }
        }
    }
    return [ordered]@{
        tipo    = 'diagnostico_tcu'
        mapa    = $VERSION_MAPA
        toolbox = $VERSION_TOOLBOX
        agente  = $VERSION_AGENTE
        planta  = "$($cfg.planta) (Planta completa)"
        ip      = 'NA'
        fecha   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        tcus    = $filas
    }
}

# Comisionado (bits 4:3 del estado que cachea la NCU), toda la planta
function Comis-Planta {
    $filas = @()
    foreach ($n in (Ncus-DePlanta)) {
        $et = "$($n.ncu)"
        $dm = $null
        try { Modbus-Conectar $n.ip $PUERTO_NCU $timeoutMs; $dm = Ncu-DiagCompat (Tcus-DeNcu $n); Modbus-Cerrar }
        catch { Modbus-Cerrar; $filas += @{ncu=$et; tcu='NCU'; estado=''; nombre="sin respuesta: $_"}; continue }
        foreach ($tcu in (Tcus-DeNcu $n)) {
            $d = $null; if ($dm) { $d = $dm[[int]$tcu] }
            if ($null -eq $d -or $d.Salud -eq 'OFFLINE') {
                $filas += @{ncu=$et; tcu=[int]$tcu; estado=''; nombre='OFFLINE'}
                continue
            }
            $v = [Convert]::ToInt32($d.main_status, 16)
            $e = ($v -shr 3) -band 0x3
            $filas += @{ncu=$et; tcu=[int]$tcu; estado=[int]$e; nombre=$ESTADOS_COMIS[[int]$e]}
        }
    }
    return [ordered]@{tipo='comisionado'; planta=$cfg.planta; fecha=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); tcus=$filas}
}

# HSUs de la planta (bloque compacto de cada NCU)
function Hsus-Planta {
    $filas = @()
    foreach ($n in (Ncus-DePlanta)) {
        $et = "$($n.ncu)"
        try { Modbus-Conectar $n.ip $PUERTO_NCU $timeoutMs; $hs = @(Ncu-HsuCompat); Modbus-Cerrar }
        catch { Modbus-Cerrar; $filas += @{ncu=$et; hsu='?'; salud='AVISO'; texto="NCU sin respuesta: $_"}; continue }
        foreach ($h in $hs) { $filas += @{ncu=$et; hsu=$h.TCU; salud=$h.Salud; texto=$h.Alarmas} }
    }
    return [ordered]@{tipo='hsus'; planta=$cfg.planta; fecha=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); hsus=$filas}
}

# ----------------- Supabase (alertas y sincronizacion) -----------------
# Requiere en la config: supabase_url, supabase_key (anon) y un usuario
# dedicado (supabase_email / supabase_pass). Sin ellos, las alertas solo
# se escriben en la consola y /sincronizar devuelve el diagnostico sin subirlo.
$script:SbJwt = $null
function Sb-Login {
    if (-not ($cfg.supabase_url -and $cfg.supabase_key -and $cfg.supabase_email -and $cfg.supabase_pass)) { return $false }
    $r = Invoke-RestMethod -Method Post -Uri "$($cfg.supabase_url)/auth/v1/token?grant_type=password" `
        -Headers @{apikey = $cfg.supabase_key} -ContentType 'application/json' `
        -Body (ConvertTo-Json @{email = $cfg.supabase_email; password = $cfg.supabase_pass})
    $script:SbJwt = $r.access_token
    return $true
}
function Sb-Insertar([string]$tabla, $obj) {
    if (-not $script:SbJwt) { if (-not (Sb-Login)) { return $false } }
    $cab = @{apikey = $cfg.supabase_key; Authorization = "Bearer $script:SbJwt"; Prefer = 'return=minimal'}
    try {
        Invoke-RestMethod -Method Post -Uri "$($cfg.supabase_url)/rest/v1/$tabla" -Headers $cab `
            -ContentType 'application/json' -Body (ConvertTo-Json $obj -Depth 7) | Out-Null
        return $true
    } catch {
        # token caducado: reintenta una vez con login fresco
        if (Sb-Login) {
            $cab.Authorization = "Bearer $script:SbJwt"
            Invoke-RestMethod -Method Post -Uri "$($cfg.supabase_url)/rest/v1/$tabla" -Headers $cab `
                -ContentType 'application/json' -Body (ConvertTo-Json $obj -Depth 7) | Out-Null
            return $true
        }
        throw
    }
}

function Resumen-Diag($d) {
    $c = @{OK=0; AVISO=0; ALARMA=0; OFFLINE=0; total=0}
    foreach ($t in $d.tcus) { $c.total++; $s = "$($t.Salud)".ToUpper(); if ($c.ContainsKey($s)) { $c[$s]++ } }
    return "$($c.total) filas: $($c.OK) OK, $($c.AVISO) aviso, $($c.ALARMA) alarma, $($c.OFFLINE) offline"
}

# /sincronizar: diagnostico completo + subida directa al Historico (tabla diagnosticos)
function Sincronizar {
    $d = Diag-Planta
    $subido = $false; $aviso = ''
    try {
        $subido = Sb-Insertar 'diagnosticos' @{
            planta = $d.planta; ip = $d.ip
            fecha = ([datetime]::ParseExact($d.fecha, 'yyyy-MM-dd HH:mm:ss', $null)).ToString('yyyy-MM-ddTHH:mm:ss')
            resumen = (Resumen-Diag $d); datos = $d
        }
        if (-not $subido) { $aviso = 'sin credenciales de Supabase en la config: no subido' }
    } catch { $aviso = "error subiendo: $_" }
    return [ordered]@{ok=$true; guardado=$subido; aviso=$aviso; resumen=(Resumen-Diag $d); fecha=$d.fecha; filas=@($d.tcus).Count}
}

# ----------------- vigilante de alarmas (segundo plano) -----------------
# Cada intervalo_vigilancia_min lee la planta; cuando una TCU/NCU/HSU ENTRA
# en ALARMA (o se recupera de una) inserta una fila en la tabla 'alertas'.
# En el primer barrido avisa de las alarmas ya activas (util tras un arranque).
$script:EstadoPrev = $null
function Vigilar {
    $d = $null
    try { $d = Diag-Planta } catch { Write-Host "vigilante: fallo leyendo la planta: $_"; return }
    $ahora = @{}
    foreach ($t in $d.tcus) { $ahora["$($t.NCU)|$($t.TCU)"] = "$($t.Salud)".ToUpper() }
    $alertas = @()
    foreach ($k in $ahora.Keys) {
        $s = $ahora[$k]
        $prev = if ($null -ne $script:EstadoPrev) { $script:EstadoPrev[$k] } else { $null }
        $fila = $d.tcus | Where-Object { "$($_.NCU)|$($_.TCU)" -eq $k } | Select-Object -First 1
        if ($s -eq 'ALARMA' -and $prev -ne 'ALARMA') {
            $alertas += @{planta=$cfg.planta; ncu="$($fila.NCU)"; tcu="$($fila.TCU)"; salud='ALARMA'; texto="$($fila.Alarmas)"}
        } elseif ($null -ne $script:EstadoPrev -and $prev -eq 'ALARMA' -and $s -ne 'ALARMA') {
            $alertas += @{planta=$cfg.planta; ncu="$($fila.NCU)"; tcu="$($fila.TCU)"; salud='RECUPERADA'; texto="vuelve a $s"}
        }
    }
    $script:EstadoPrev = $ahora
    foreach ($a in $alertas) {
        Write-Host ("ALERTA  NCU{0} {1}  {2}  {3}" -f $a.ncu, $a.tcu, $a.salud, $a.texto)
        try { if (-not (Sb-Insertar 'alertas' $a)) { Write-Host '  (sin credenciales Supabase: alerta solo en consola)' } }
        catch { Write-Host "  (error subiendo alerta: $_)" }
    }
    if ($alertas.Count) { Write-Host ("vigilante: {0} alertas nuevas" -f $alertas.Count) }
}

# ----------------- comandos de ESCRITURA (remoto, con candados) -----------------
# Solo activos con "permitir_escritura": true en la config. Cada peticion debe
# llevar "confirmar": true en el cuerpo. Todo queda en auditoria_agente.log (y
# en la tabla 'acciones' de Supabase si hay credenciales). El TEST DE MOTOR
# queda excluido a proposito: mover motores requiere a alguien mirando el
# seguidor - se hace con la toolbox en local.

function Auditar([string]$usuario, [string]$op, $params, $res) {
    $linea = [ordered]@{
        fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); usuario = $usuario; planta = $cfg.planta
        operacion = $op; parametros = $params
        ok = @($res | Where-Object { $_.ok }).Count; fallos = @($res | Where-Object { -not $_.ok }).Count
    }
    try { Add-Content -Path (Join-Path $dirBase 'auditoria_agente.log') -Value (ConvertTo-Json $linea -Compress -Depth 5) -Encoding UTF8 } catch {}
    try {
        [void](Sb-Insertar 'acciones' @{planta=$cfg.planta; usuario=$usuario; operacion=$op
            parametros=(ConvertTo-Json $params -Compress -Depth 5); resultado="$($linea.ok) OK, $($linea.fallos) fallos"})
    } catch { Write-Host "  (accion no subida a Supabase: $_)" }
    Write-Host ("ESCRITURA  {0}  {1}  {2}  -> {3} OK, {4} fallos" -f $usuario, $op, (ConvertTo-Json $params -Compress -Depth 5), $linea.ok, $linea.fallos)
}

# Ejecuta un scriptblock por TCU sobre los gateways de una NCU concreta
function Ejecutar-PorRango([int]$ncu, [int[]]$tcus, [scriptblock]$porTcu) {
    $n = @(Ncus-DePlanta) | Where-Object { [int]$_.ncu -eq $ncu } | Select-Object -First 1
    if (-not $n) { throw "NCU $ncu no existe en la planta '$($cfg.planta)'" }
    $cx = @{ip = $n.ip; puerto = $null; gws = $n.gws; multi = $null; etiqueta = 'auto'; to = $timeoutMs; reint = 2}
    $res = @()
    foreach ($seg in @(Plan-Segmentos $tcus $cx)) {
        try { Modbus-Conectar $n.ip $seg.puerto $timeoutMs }
        catch {
            foreach ($t in $seg.tcus) { $res += @{tcu = [int]$t; ok = $false; detalle = "sin conexion ($($n.ip):$($seg.puerto))"} }
            continue
        }
        foreach ($t in $seg.tcus) {
            try { $res += & $porTcu ([byte]$t) }
            catch {
                $res += @{tcu = [int]$t; ok = $false; detalle = "$_"}
                if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
            }
        }
    }
    Modbus-Cerrar
    return @($res)
}

function Tcus-DeCuerpo($body) {
    $lista = Parse-ListaNums "$($body.tcus)"
    if (-not $lista) { throw 'falta "tcus" (p. ej. "1-75" o "3,5,9")' }
    return [int[]]$lista
}

function Op-Escritura([string]$op, $body) {
    $ncu = [int]$body.ncu
    switch ($op) {
        'modo' {
            $m = @{'OFF' = 0; 'MANUAL' = 1; 'AUTO' = 2}["$($body.modo)".ToUpper()]
            if ($null -eq $m) { throw "modo invalido (OFF/MANUAL/AUTO)" }
            return Ejecutar-PorRango $ncu (Tcus-DeCuerpo $body) {
                param($t)
                if (Fijar-Modo $t $m) { @{tcu = [int]$t; ok = $true; detalle = "en modo $($body.modo)"} }
                else { @{tcu = [int]$t; ok = $false; detalle = 'no confirma el modo (30001)'} }
            }.GetNewClosure()
        }
        'limpiar-alarmas' {
            return Ejecutar-PorRango $ncu (Tcus-DeCuerpo $body) {
                param($t)
                FC22-Mascara $t 40007 0xDFFF 0x2000
                Start-Sleep -Milliseconds 400
                $st = (FC03-Leer $t (Dir-Trama 30006) 1)[0]
                if (($st -shr 11) -band 1) { @{tcu = [int]$t; ok = $true; detalle = 'enviado; la alarma sigue enclavada (revisar causa)'} }
                else { @{tcu = [int]$t; ok = $true; detalle = 'sin alarmas de motor enclavadas'} }
            }
        }
        'stow' {
            $n = [int]$body.safe_pos
            if ($n -lt 1 -or $n -gt 7) { throw 'safe_pos debe ser 1..7' }
            return Ejecutar-PorRango $ncu (Tcus-DeCuerpo $body) {
                param($t)
                FC22-Mascara $t 42000 0xFFF8 $n
                Start-Sleep -Milliseconds 500
                $v = (FC03-Leer $t (Dir-Trama 30001) 1)[0]
                $activo = ($v -shr 13) -band 0x7
                if ($activo -eq $n) { @{tcu = [int]$t; ok = $true; detalle = "safe position $n activa"} }
                else { @{tcu = [int]$t; ok = $false; detalle = "solicitada $n pero 30001 marca $activo"} }
            }.GetNewClosure()
        }
        'unstow' {
            return Ejecutar-PorRango $ncu (Tcus-DeCuerpo $body) {
                param($t)
                FC22-Mascara $t 42000 0xFFF8 0
                Start-Sleep -Milliseconds 500
                $v = (FC03-Leer $t (Dir-Trama 30001) 1)[0]
                $activo = ($v -shr 13) -band 0x7
                if ($activo -eq 0) { @{tcu = [int]$t; ok = $true; detalle = 'stow retirado'} }
                else { @{tcu = [int]$t; ok = $false; detalle = "sigue en safe position $activo (otra fuente: NCU/viento?)"} }
            }
        }
        'comisionado' {
            $e = [int]$body.estado
            if ($e -lt 0 -or $e -gt 3) { throw 'estado debe ser 0..3' }
            return Ejecutar-PorRango $ncu (Tcus-DeCuerpo $body) {
                param($t)
                FC22-Mascara $t 40000 0xFF1F ($e -shl 5)
                Start-Sleep -Milliseconds 500
                $v = (FC03-Leer $t (Dir-Trama 30001) 1)[0]
                $leido = ($v -shr 3) -band 0x3
                if ($leido -eq $e) { @{tcu = [int]$t; ok = $true; detalle = "comisionado = $e ($($ESTADOS_COMIS[[int]$e]))"} }
                else { @{tcu = [int]$t; ok = $false; detalle = "30001 marca $leido"} }
            }.GetNewClosure()
        }
        'reloj' {
            return Ejecutar-PorRango $ncu (Tcus-DeCuerpo $body) {
                param($t)
                FC22-Mascara $t 40007 0xFFFE 0x0001
                $ahora = Get-Date
                FC16-Escribir $t 40001 @($ahora.Second, $ahora.Minute, $ahora.Hour, $ahora.Day, $ahora.Month, $ahora.Year)
                FC22-Mascara $t 40007 0xFFFD 0x0002
                FC22-Mascara $t 40007 0xFFFC 0x0000
                $reloj = ''
                try { $reloj = Leer-Decodificado $t @{addr = 30079; tipo = 'dt_bcd'} } catch {}
                @{tcu = [int]$t; ok = $true; detalle = "reloj = $reloj"}
            }
        }
        'nvm' {
            return Ejecutar-PorRango $ncu (Tcus-DeCuerpo $body) {
                param($t)
                FC22-Mascara $t 40007 0x7FFF 0x8000
                @{tcu = [int]$t; ok = $true; detalle = 'NVM guardado'}
            }
        }
        'escribir' {
            $nombre = Resolver-Variable "$($body.variable)"
            $vdef = $VARIABLES[$nombre]
            if ($ADDR_COMANDO -contains $vdef.addr) { throw "el registro $($vdef.addr) es de COMANDO: usa el endpoint dedicado (modo/stow/reloj/nvm/comisionado)" }
            $esc = Valor-A-Escritura $vdef "$($body.valor)"
            return Ejecutar-PorRango $ncu (Tcus-DeCuerpo $body) {
                param($t)
                $previo = '?'
                try { $previo = Leer-Decodificado $t $vdef } catch {}
                if ($esc.modo -eq 'fc16') { FC16-Escribir $t $esc.addr $esc.palabras }
                else { FC22-Mascara $t $esc.addr $esc.and $esc.or }
                $cmp = Comparar-Escritura $t $esc
                if (-not $cmp.ok) { @{tcu = [int]$t; ok = $false; detalle = "verificacion: leido $($cmp.leidoRaw)"} }
                else { @{tcu = [int]$t; ok = $true; detalle = "$nombre : $previo -> $($body.valor)"} }
            }.GetNewClosure()
        }
        default { throw "operacion desconocida '$op'" }
    }
}

# --------------------------- servidor HTTP ---------------------------
$puerto = if ($cfg.puerto) { [int]$cfg.puerto } else { 8585 }
$escritura = [bool]$cfg.permitir_escritura
$intervaloVig = if ($null -ne $cfg.intervalo_vigilancia_min) { [int]$cfg.intervalo_vigilancia_min } else { 5 }
$OPS_POST = @('modo', 'limpiar-alarmas', 'stow', 'unstow', 'comisionado', 'reloj', 'nvm', 'escribir')
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$puerto/")
$listener.Start()
Write-Host "TCU Agente v$VERSION_AGENTE - planta '$($cfg.planta)' - http://localhost:$puerto  (toolbox v$VERSION_TOOLBOX)"
Write-Host "Lectura (GET, X-Token): /ping /diagnostico /comisionado /hsus /sincronizar"
Write-Host ("Escritura (POST, X-Token + confirmar): {0}  [{1}]" -f ($OPS_POST -join ' '), $(if ($escritura) { 'HABILITADA' } else { 'DESHABILITADA (permitir_escritura=false)' }))
Write-Host ("Vigilante de alarmas: {0}" -f $(if ($intervaloVig -gt 0) { "cada $intervaloVig min" } else { 'apagado' }))
Write-Host "Expon el puerto con: cloudflared tunnel --url http://localhost:$puerto"

$proxVig = Get-Date
$tarea = $listener.GetContextAsync()
while ($true) {
    if ($intervaloVig -gt 0 -and (Get-Date) -ge $proxVig) {
        try { Vigilar } catch { Write-Host "vigilante: $_" }
        $proxVig = (Get-Date).AddMinutes($intervaloVig)
    }
    if (-not $tarea.Wait(1000)) { continue }
    $ctx = $tarea.Result
    $tarea = $listener.GetContextAsync()
    $req = $ctx.Request; $res = $ctx.Response
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Headers', 'X-Token,X-Usuario,Content-Type')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
    if ($req.HttpMethod -eq 'OPTIONS') { $res.StatusCode = 204; $res.Close(); continue }
    $out = $null; $code = 200
    $t0 = Get-Date
    try {
        if ($req.Headers['X-Token'] -ne $cfg.token) { $code = 401; $out = @{error = 'token invalido'} }
        elseif ($req.HttpMethod -eq 'GET') {
            switch ($req.Url.AbsolutePath) {
                '/ping' {
                    $ncusInfo = @(Ncus-DePlanta | ForEach-Object { @{ncu = [int]$_.ncu; tcus = "$(@(Tcus-DeNcu $_)[0])-$(@(Tcus-DeNcu $_)[-1])"} })
                    $out = @{ok=$true; planta=$cfg.planta; agente=$VERSION_AGENTE; toolbox=$VERSION_TOOLBOX; mapa=$VERSION_MAPA
                             hora=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); escritura=$escritura; ncus=$ncusInfo}
                }
                '/diagnostico'  { $out = Diag-Planta }
                '/comisionado'  { $out = Comis-Planta }
                '/hsus'         { $out = Hsus-Planta }
                '/sincronizar'  { $out = Sincronizar }
                default         { $code = 404; $out = @{error = 'ruta desconocida'} }
            }
        }
        elseif ($req.HttpMethod -eq 'POST') {
            $op = $req.Url.AbsolutePath.TrimStart('/')
            if ($OPS_POST -notcontains $op) { $code = 404; $out = @{error = "operacion desconocida '$op'"} }
            elseif (-not $escritura) { $code = 403; $out = @{error = 'escritura deshabilitada en este agente (permitir_escritura=false)'} }
            else {
                $body = $null
                if ($req.HasEntityBody) {
                    $sr = New-Object IO.StreamReader($req.InputStream, $req.ContentEncoding)
                    $body = $sr.ReadToEnd() | ConvertFrom-Json
                }
                if (-not $body -or $body.confirmar -ne $true) { $code = 400; $out = @{error = "falta 'confirmar': true en el cuerpo"} }
                else {
                    $usuario = "$($req.Headers['X-Usuario'])"; if (-not $usuario) { $usuario = '(desconocido)' }
                    $filas = @(Op-Escritura $op $body)
                    Auditar $usuario $op @{ncu = $body.ncu; tcus = "$($body.tcus)"; modo = "$($body.modo)"; safe_pos = "$($body.safe_pos)"; estado = "$($body.estado)"; variable = "$($body.variable)"; valor = "$($body.valor)"} $filas
                    $out = [ordered]@{ok = $true; operacion = $op
                        correctas = @($filas | Where-Object { $_.ok }).Count
                        fallos    = @($filas | Where-Object { -not $_.ok }).Count
                        filas = $filas}
                }
            }
        }
        else { $code = 405; $out = @{error = 'metodo no soportado'} }
    } catch { $code = 500; $out = @{error = "$_"} }
    $json = ConvertTo-Json $out -Depth 7
    $buf = [Text.Encoding]::UTF8.GetBytes($json)
    $res.StatusCode = $code
    $res.ContentType = 'application/json; charset=utf-8'
    $res.OutputStream.Write($buf, 0, $buf.Length)
    $res.Close()
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    Write-Host ("{0}  {1} {2} -> {3}  ({4} ms)" -f (Get-Date -Format 'HH:mm:ss'), $req.HttpMethod, $req.Url.AbsolutePath, $code, $ms)
}
