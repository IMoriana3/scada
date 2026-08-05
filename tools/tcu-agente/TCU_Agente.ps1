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
$VERSION_AGENTE = '1.0'

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
Invoke-Expression ($src.Substring($ini, $fin - $ini).Replace('$PSScriptRoot', '$dirToolbox'))
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

# --------------------------- servidor HTTP ---------------------------
$puerto = if ($cfg.puerto) { [int]$cfg.puerto } else { 8585 }
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$puerto/")
$listener.Start()
Write-Host "TCU Agente v$VERSION_AGENTE - planta '$($cfg.planta)' - http://localhost:$puerto  (toolbox v$VERSION_TOOLBOX)"
Write-Host "Endpoints (solo lectura, cabecera X-Token obligatoria): /ping /diagnostico /comisionado /hsus"
Write-Host "Expon el puerto con: cloudflared tunnel --url http://localhost:$puerto"

while ($true) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request; $res = $ctx.Response
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Headers', 'X-Token,Content-Type')
    if ($req.HttpMethod -eq 'OPTIONS') { $res.StatusCode = 204; $res.Close(); continue }
    $out = $null; $code = 200
    $t0 = Get-Date
    try {
        if ($req.Headers['X-Token'] -ne $cfg.token) { $code = 401; $out = @{error = 'token invalido'} }
        elseif ($req.HttpMethod -ne 'GET') { $code = 405; $out = @{error = 'solo GET: el agente es de solo lectura'} }
        else {
            switch ($req.Url.AbsolutePath) {
                '/ping'         { $out = @{ok=$true; planta=$cfg.planta; agente=$VERSION_AGENTE; toolbox=$VERSION_TOOLBOX; mapa=$VERSION_MAPA; hora=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')} }
                '/diagnostico'  { $out = Diag-Planta }
                '/comisionado'  { $out = Comis-Planta }
                '/hsus'         { $out = Hsus-Planta }
                default         { $code = 404; $out = @{error = 'ruta desconocida (usa /ping /diagnostico /comisionado /hsus)'} }
            }
        }
    } catch { $code = 500; $out = @{error = "$_"} }
    $json = ConvertTo-Json $out -Depth 6
    $buf = [Text.Encoding]::UTF8.GetBytes($json)
    $res.StatusCode = $code
    $res.ContentType = 'application/json; charset=utf-8'
    $res.OutputStream.Write($buf, 0, $buf.Length)
    $res.Close()
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    Write-Host ("{0}  {1} {2} -> {3}  ({4} ms)" -f (Get-Date -Format 'HH:mm:ss'), $req.HttpMethod, $req.Url.AbsolutePath, $code, $ms)
}
