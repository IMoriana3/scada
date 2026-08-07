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
$VERSION_AGENTE = '2.4'
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
# OJO: si en la toolbox se renombra o se borra una de estas funciones, el
# agente deja de arrancar. Paso por 'Anclas-Toolbox' para que el error diga
# CUAL falta en vez de un "no se pudieron extraer" que no lleva a ningun sitio,
# y la suite de la toolbox comprueba que las seis siguen estando.
function Ancla-Toolbox([string]$src, [string]$marca) {
    $i = $src.IndexOf($marca)
    if ($i -lt 0) {
        $v = '?'
        $m = [regex]::Match($src, "VERSION_TOOLBOX = '([0-9.]+)'")
        if ($m.Success) { $v = $m.Groups[1].Value }
        throw "La toolbox v$v ya no tiene '$marca'. El agente se ha quedado atras: las dos carpetas van juntas, baja la misma release."
    }
    return $i
}
$i3 = Ancla-Toolbox $src 'function Params-Conexion'; $f3 = Ancla-Toolbox $src 'function Refrescar-ComboPlantas'   # Plan-Segmentos, Trabajos-Planta, Parse-Seleccion
$i4 = Ancla-Toolbox $src 'function Fijar-Modo';      $f4 = Ancla-Toolbox $src 'function Guardia-Viento'           # cambio de modo verificado
$i5 = Ancla-Toolbox $src 'function Sat-Fichero';     $f5 = Ancla-Toolbox $src '$tmrSat = New-Object'                # los tres pases del SAT
$i6 = Ancla-Toolbox $src '$BAT = @{';                $f6 = Ancla-Toolbox $src 'function Sospechas-Lectura'           # umbrales y tabla de baterias
$i7 = Ancla-Toolbox $src 'function Cierre-DeJson';   $f7 = Ancla-Toolbox $src '$script:LogicaCache'                  # cierre y trabajos guardados
$i8 = Ancla-Toolbox $src 'function Ident-Leer';      $f8 = Ancla-Toolbox $src '$btnIdent.Add_Click'                  # identidad y numero de serie
$i9 = Ancla-Toolbox $src 'function Sospechas-Lectura'; $f9 = Ancla-Toolbox $src '$btnLeer.Add_Click'                  # presets y CSV por TCU
foreach ($p in @(@($i3,$f3), @($i4,$f4), @($i5,$f5), @($i6,$f6), @($i7,$f7), @($i8,$f8), @($i9,$f9))) {
    $logica += "`n" + $src.Substring($p[0], $p[1] - $p[0]).Replace('$PSScriptRoot', '$dirToolbox')
}
Invoke-Expression $logica
if ($cfg.puerto_ncu) { $PUERTO_NCU = [int]$cfg.puerto_ncu }   # solo para pruebas con simulador

$script:Cancelar = $false

# ---------------------------------------------------------------------------
#  Lo que la toolbox hace en local, aqui de solo lectura
# ---------------------------------------------------------------------------
# Ninguna de estas toca un seguidor: leen. Van en GET y no dependen de
# permitir_escritura. Todas devuelven el MISMO formato que exporta la toolbox,
# para que lo que se vea en la web y lo que se suba al Historico sea lo mismo.

# Baterias: se sacan del diagnostico, sin leer nada mas. Igual que la pestana.
function Baterias-Planta {
    $diag = @((Diag-Planta).tcus)
    $hall = @(Bat-Auditar $diag)
    return [ordered]@{tipo = 'baterias_tcu'; planta = $cfg.planta; toolbox = $VERSION_TOOLBOX
        fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        hallazgos = $hall
        tcus = @(Bat-Tabla $diag $hall)}
}

# Inventario: FW, serie y MAC. Esta va por Zigbee TCU a TCU, asi que es LENTA
# (una planta entera son minutos, no segundos). Se avisa en la respuesta.
function Inventario-Planta {
    $filas = @()
    foreach ($n in (Ncus-DePlanta)) {
        $et = "$($n.ncu)"
        $cx = @{ip = $n.ip; puerto = $null; gws = $n.gws; multi = $null; etiqueta = 'auto'; to = $timeoutMs; reint = 2}
        foreach ($seg in @(Plan-Segmentos (Tcus-DeNcu $n) $cx)) {
            try { Modbus-Conectar $n.ip $seg.puerto $timeoutMs } catch { continue }
            foreach ($tcu in $seg.tcus) {
                # Ident-Leer devuelve una lista Campo/Valor, no un diccionario:
                # indexarla por nombre daba null en todas las columnas
                $h = $null
                try {
                    $campos = Ident-Leer ([byte]$tcu)
                    $h = @{}
                    foreach ($c in @($campos)) { $h[$c.Campo] = $c.Valor }
                } catch { $h = $null }
                if ($h) {
                    $filas += [pscustomobject]@{NCU = $et; TCU = [int]$tcu; Serie = $h['Numero de serie']; MAC = $h['MAC Xbee']
                        FW = $h['FW principal']; FW_fabrica = $h['FW de fabrica']; HW = $h['HW PCBA']
                        Fecha_fab = $h['Fecha de fabricacion']; Nota = 'OK'}
                } else {
                    $filas += [pscustomobject]@{NCU = $et; TCU = [int]$tcu; Serie = ''; MAC = ''; FW = ''
                        FW_fabrica = ''; HW = ''; Fecha_fab = ''; Nota = 'sin respuesta'}
                }
            }
            Modbus-Cerrar
        }
    }
    return [ordered]@{tipo = 'inventario_tcu'; mapa = $VERSION_MAPA; toolbox = $VERSION_TOOLBOX
        planta = $cfg.planta; fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); tcus = $filas}
}

# Plan de firmware: puro, a partir de un inventario. Si no se le pasa uno hecho,
# lo levanta el (y entonces tarda lo que tarde el inventario).
function Plan-Fw($objetivo, $inv = $null, $minTcu = 20) {
    if (-not $objetivo) { throw 'falta "objetivo" (p. ej. v1.6.0)' }
    $m = 0; if (-not [int]::TryParse("$minTcu", [ref]$m) -or $m -lt 1) { $m = 20 }
    $minTcu = $m
    if ($null -eq $inv) { $inv = @((Inventario-Planta).tcus) }
    $gws = @{}; $ips = @{}
    foreach ($n in (Ncus-DePlanta)) { $k = "$($n.ncu)"; $ips[$k] = $n.ip; $gws[$k] = $n.gws }
    $plan = Plan-Firmware $inv "$objetivo" $gws @()
    $vent = @(Plan-Ventanas $plan.tramos $ips ([int]$minTcu))
    return [ordered]@{planta = $cfg.planta; objetivo = "$objetivo"; fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        pendientes = $plan.pendientes; al_dia = $plan.al_dia; sin_respuesta = @($plan.sin_respuesta)
        ventanas = @($vent | ForEach-Object { @{ventana = $_.Orden; ncu = $_.NCU; ip = $_.IP; puerto = $_.Puerto
                                                rangos = $_.Rangos; tcus = $_.TCUs; horas = [math]::Round([double]$_.Horas, 2)} })
        texto = @(Plan-Texto $vent ([int]$minTcu))
        detalle = @($plan.detalle)}
}

# Cierre: lo que ya esta guardado en disco por planta, sin tocar la planta.
function Cierre-Planta {
    Cierre-Cargar $cfg.planta
    $filas = @($script:Cierre.Values | Sort-Object { [int]("0" + "$($_.ncu)") }, { [int]$_.tcu } | ForEach-Object {
        @{ncu = $_.ncu; tcu = $_.tcu; firmware = $_.fw; parametros = $_.params; nvm = $_.nvm
          modo = $_.modo; desde = $_.desde; estado = (Cierre-Estado $_)} })
    return [ordered]@{planta = $cfg.planta; total = $filas.Count
        pendientes = @($filas | Where-Object { $_.estado -ne 'CERRADA' }).Count; tcus = $filas}
}

# Trabajos guardados en este PC: los mismos que ve la pestana Trabajos.
function Trabajos-Lista {
    $r = @()
    try {
        foreach ($f in @(Get-ChildItem (Trabajos-Dir) -Filter '*.json' -File)) {
            try { $r += ,(Trabajo-Resumen (Get-Content $f.FullName -Raw | ConvertFrom-Json) $f.Name) } catch {}
        }
    } catch {}
    return @(Trabajos-Ordenar $r)
}

# Leer variables en un rango, como la pestana Leer variable.
function Leer-Planta($nombresTxt, $ncuPedida, $tcusTxt) {
    $nombres = @("$nombresTxt".Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($nombres.Count -eq 0) { throw 'falta "vars" (nombres separados por comas; vale el prefijo, p. ej. 41010)' }
    $defs = @($nombres | ForEach-Object { @{nombre = (Resolver-Variable $_); vdef = $null} })
    foreach ($d in $defs) { $d.vdef = $(if ($d.nombre -like 'ESTADO *') { $ESTADO[$d.nombre.Substring(7)] } else { $VARIABLES[$d.nombre] }) }
    $filas = @()
    foreach ($n in (Ncus-DePlanta)) {
        if ($ncuPedida -and "$($n.ncu)" -ne "$ncuPedida") { continue }
        $todas = Tcus-DeNcu $n
        $pedidas = $todas
        if ("$tcusTxt" -ne '') {
            $l = Parse-ListaNums "$tcusTxt"
            $pedidas = @($l | Where-Object { $todas -contains [int]$_ })
        }
        $cx = @{ip = $n.ip; puerto = $null; gws = $n.gws; multi = $null; etiqueta = 'auto'; to = $timeoutMs; reint = 2}
        foreach ($seg in @(Plan-Segmentos $pedidas $cx)) {
            try { Modbus-Conectar $n.ip $seg.puerto $timeoutMs } catch { continue }
            foreach ($tcu in $seg.tcus) {
                $o = [ordered]@{NCU = "$($n.ncu)"; TCU = [int]$tcu}
                $mudo = $true
                foreach ($d in $defs) {
                    $v = ''
                    try { $v = Leer-Decodificado ([byte]$tcu) $d.vdef; $mudo = $false } catch { $v = '' }
                    $o[$d.nombre] = "$v"
                    if ($mudo) { break }        # si la primera no contesta, el TCU esta mudo
                }
                $o['Estado'] = $(if ($mudo) { 'sin respuesta' } else { 'OK' })
                $filas += [pscustomobject]$o
            }
            Modbus-Cerrar
        }
    }
    return [ordered]@{planta = $cfg.planta; fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        variables = @($defs | ForEach-Object { $_.nombre }); tcus = $filas}
}

# --- HSUs: meteo, config y caja negra ---
# La HSU cuelga de un gateway concreto y responde a su propio esclavo Modbus.
function Hsu-Cx($n) {
    $esc = $(if ($n.hsu) { [byte]$n.hsu } else { [byte]185 })
    $pto = $(if ($n.gws -and @($n.gws).Count -gt 0) { [int]@($n.gws)[0].puerto } else { 503 })
    return @{ip = $n.ip; puerto = $pto; unit = $esc}
}
function Hsus-Detalle([string]$que) {
    $filas = @()
    foreach ($n in (Ncus-DePlanta)) {
        $c = Hsu-Cx $n
        try { Modbus-Conectar $c.ip $c.puerto $timeoutMs } catch { continue }
        try {
            $campos = $(if ($que -eq 'config') { Hsu-LeerConfig ([byte]$c.unit) } else { Hsu-LeerMeteo ([byte]$c.unit) })
            foreach ($f in @($campos)) { $filas += [pscustomobject]@{NCU = "$($n.ncu)"; Esclavo = $c.unit; Campo = "$($f.Campo)"; Valor = "$($f.Valor)"} }
        } catch { $filas += [pscustomobject]@{NCU = "$($n.ncu)"; Esclavo = $c.unit; Campo = 'ERROR'; Valor = "$_"} }
        Modbus-Cerrar
    }
    return [ordered]@{planta = $cfg.planta; que = $que; fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); filas = $filas}
}
# La caja negra son 24 h minuto a minuto: 5760 registros de una HSU concreta.
function Hsu-CajaNegra($ncuPedida) {
    $n = @(Ncus-DePlanta | Where-Object { -not $ncuPedida -or "$($_.ncu)" -eq "$ncuPedida" })[0]
    if (-not $n) { throw "no encuentro la NCU '$ncuPedida' en la planta" }
    $c = Hsu-Cx $n
    Modbus-Conectar $c.ip $c.puerto $timeoutMs
    $palabras = New-Object System.Collections.Generic.List[int]
    try {
        $regsTot = 1440 * 4; $off = 0
        while ($off -lt $regsTot) {
            $k = [math]::Min(100, $regsTot - $off)
            $trozo = FC03-Leer ([byte]$c.unit) (31000 + $off) $k
            if ($null -eq $trozo) { break }
            $palabras.AddRange([int[]]$trozo); $off += $k
        }
    } finally { Modbus-Cerrar }
    $min = [math]::Floor($palabras.Count / 4)
    $filas = @()
    for ($m = 0; $m -lt $min; $m++) { $filas += Hsu-CajaFila @($palabras[$m*4], $palabras[$m*4+1], $palabras[$m*4+2], $palabras[$m*4+3]) $m }
    return [ordered]@{planta = $cfg.planta; ncu = "$($n.ncu)"; esclavo = $c.unit; minutos = $min
        completa = ($min -ge 1440); fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); filas = $filas}
}

# --- Auditoria contra un preset que llega en el cuerpo ---
# No escribe nada: lee las variables del preset y lista SOLO las desviaciones,
# igual que la pestana Flota. El preset viaja en la peticion, asi que se puede
# auditar con el mismo fichero que se usa en local.
function Auditar-Preset($body) {
    $pares = @()
    foreach ($e in @($body.preset)) {
        if ($null -eq $e) { continue }
        $nom = "$($e.variable)"
        if ($nom -eq '' -or -not $VARIABLES.Contains($nom)) { continue }
        $pares += @{nombre = $nom; texto = "$($e.valor)"}
    }
    if ($pares.Count -eq 0) { throw 'el preset no trae ninguna variable conocida (formato: [{"variable":"41010 longitud [deg]","valor":"-1.685"}])' }
    $lec = Leer-Planta (($pares | ForEach-Object { $_.nombre }) -join ',') "$($body.ncu)" "$($body.tcus)"
    $desv = @(); $ok = 0; $mudas = 0
    foreach ($f in @($lec.tcus)) {
        if ("$($f.Estado)" -ne 'OK') { $mudas++; continue }
        $malas = 0
        foreach ($p in $pares) {
            $leido = "$($f.($p.nombre))"
            if ($leido -eq $p.texto) { continue }
            $malas++
            $sosp = Rango-Sospechoso $p.nombre $leido
            $desv += [pscustomobject]@{NCU = $f.NCU; TCU = $f.TCU; Variable = $p.nombre
                Esperado = $p.texto; Leido = $leido
                Nota = $(if ($sosp) { "DESVIACION - $sosp" } else { 'DESVIACION' })}
        }
        if ($malas -eq 0) { $ok++ }
    }
    return [ordered]@{tipo = 'auditoria_tcu'; planta = $cfg.planta; toolbox = $VERSION_TOOLBOX
        fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        variables = @($pares | ForEach-Object { $_.nombre })
        tcus_auditadas = @($lec.tcus).Count; conformes = $ok; sin_respuesta = $mudas
        desviaciones = $desv}
}

# ---------------------------------------------------------------------------
#  SAT: se activa en remoto, se graba en ESTE PC
# ---------------------------------------------------------------------------
# El ensayo son dias de registro continuo. Mandarlo por HTTP no tiene sentido -si
# se cae el tunel se pierde el ensayo-, asi que aqui solo se arranca y se para: los
# CSV se escriben en la misma carpeta y con el mismo formato que los de la toolbox,
# para que ANALIZAR Y EMITIR los lea tal cual.
$script:SatOn = $false
$script:SatHasta = $null
$script:SatProxTcu = [datetime]::MinValue
$script:SatProxCom = [datetime]::MinValue
$script:SatIntTcu = 60; $script:SatIntCom = 15
$script:SatPasesT = 0; $script:SatPasesC = 0; $script:SatFallos = 0
$script:SatError = ''
$script:SatDir = Join-Path (Join-Path $dirToolbox 'informes') ('sat_' + ("$($cfg.planta)" -replace '[^\w\-]', '_'))
$satEstado = Join-Path $script:SatDir 'sat_estado.json'

# la toolbox lo pinta en su lista; aqui va a un fichero al lado de los CSV
function Sat-Log([string]$ensayo, [string]$detalle) {
    try {
        if (-not (Test-Path $script:SatDir)) { New-Item -ItemType Directory -Path $script:SatDir -Force | Out-Null }
        Add-Content -Path (Join-Path $script:SatDir 'sat_agente.log') -Encoding UTF8 `
            -Value ("{0};{1};{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $ensayo, ($detalle -replace '[\r\n]', ' '))
    } catch {}
    Write-Host "SAT $ensayo : $detalle"
}

function Sat-Estado {
    return [ordered]@{
        activo    = $script:SatOn
        planta    = $cfg.planta
        hasta     = $(if ($script:SatHasta) { $script:SatHasta.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
        int_tcu   = $script:SatIntTcu
        int_comms = $script:SatIntCom
        pases_tcu = $script:SatPasesT
        pases_comm= $script:SatPasesC
        fallos    = $script:SatFallos
        carpeta   = $script:SatDir
        error     = $script:SatError
        ficheros  = @(Sat-Ficheros)
    }
}
function Sat-Ficheros {
    if (-not (Test-Path $script:SatDir)) { return @() }
    return @(Get-ChildItem $script:SatDir -File | Sort-Object Name | ForEach-Object {
        @{nombre = $_.Name; bytes = $_.Length; fecha = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')} })
}
# el estado va a disco en cada pase: si el agente se reinicia a los cuatro dias,
# el ensayo continua solo
function Sat-Guardar {
    try {
        if (-not (Test-Path $script:SatDir)) { New-Item -ItemType Directory -Path $script:SatDir -Force | Out-Null }
        $e = Sat-Estado; $e.Remove('ficheros')
        ConvertTo-Json $e -Depth 4 | Set-Content $satEstado -Encoding UTF8
    } catch {}
}
function Sat-Restaurar {
    if (-not (Test-Path $satEstado)) { return }
    try {
        $e = Get-Content $satEstado -Raw | ConvertFrom-Json
        if (-not $e.activo -or -not $e.hasta) { return }
        $h = [datetime]::ParseExact("$($e.hasta)", 'yyyy-MM-dd HH:mm:ss', $null)
        if ($h -le (Get-Date)) { return }        # el plazo ya paso: nada que reanudar
        $script:SatOn = $true; $script:SatHasta = $h
        $script:SatIntTcu = [int]$e.int_tcu; $script:SatIntCom = [int]$e.int_comms
        $script:SatPasesT = [int]$e.pases_tcu; $script:SatPasesC = [int]$e.pases_comm
        $script:SatFallos = [int]$e.fallos
        Sat-Log 'REANUDA' "el agente se ha reiniciado y el ensayo sigue hasta $($e.hasta)"
    } catch {}
}

function Sat-Trabajos {
    return @(Ncus-DePlanta | ForEach-Object {
        @{ncu = $_.ncu; ip = $_.ip; tcus = (Tcus-DeNcu $_); cx = @{to = $timeoutMs; gws = $_.gws}} })
}

# Un tick: lo llama el bucle principal, que ya se despierta cada segundo. Un pase
# tarda unos segundos y durante ese rato el agente no atiende peticiones, igual
# que la toolbox no deja hacer otra cosa mientras registra.
function Sat-Tick {
    if (-not $script:SatOn) { return }
    $ahora = Get-Date
    if ($script:SatHasta -and $ahora -gt $script:SatHasta) {
        $script:SatOn = $false; Sat-Guardar
        Sat-Log 'FIN' 'plazo cumplido. Analiza con ANALIZAR Y EMITIR en la toolbox del PC.'
        return
    }
    if ($ahora -lt $script:SatProxCom -and $ahora -lt $script:SatProxTcu) { return }
    try {
        $trabajos = Sat-Trabajos
        if ($ahora -ge $script:SatProxCom) {
            $script:SatProxCom = $ahora.AddSeconds([double]$script:SatIntCom)
            $r = Sat-PaseComms $trabajos
            if ($r.fallos -gt 0) { Sat-Log 'D.4 comms' "$($r.equipos) equipos, $($r.fallos) sin responder" }
        }
        if ($ahora -ge $script:SatProxTcu) {
            $script:SatProxTcu = $ahora.AddSeconds([double]$script:SatIntTcu)
            $n = Sat-PaseTcu $trabajos
            Sat-PaseEquipos $trabajos
            Sat-Log 'D.1.1 / D.3.4' "$n TCUs + RSUs y NCUs (pase $($script:SatPasesT))"
        }
        $script:SatError = ''
    } catch {
        $script:SatError = "$_"
        Sat-Log 'ERROR' "$_"
    } finally {
        Modbus-Cerrar
        Sat-Guardar
    }
}

function Sat-Iniciar($body) {
    if ($script:SatOn) { throw 'ya hay un ensayo en marcha: paralo antes de empezar otro' }
    $dur = [int]$body.duracion; if ($dur -le 0) { $dur = 7 }
    $unid = "$($body.unidad)"; if (-not $unid) { $unid = 'dias' }
    $script:SatIntTcu = $(if ($body.int_tcu) { [int]$body.int_tcu } else { 60 })
    $script:SatIntCom = $(if ($body.int_comms) { [int]$body.int_comms } else { 15 })
    if ($script:SatIntTcu -lt 15 -or $script:SatIntTcu -gt 3600) { throw 'int_tcu fuera de 15..3600 s' }
    if ($script:SatIntCom -lt 5  -or $script:SatIntCom -gt 3600) { throw 'int_comms fuera de 5..3600 s' }
    $ahora = Get-Date
    $script:SatHasta = switch ($unid) {
        'minutos' { $ahora.AddMinutes($dur) }
        'horas'   { $ahora.AddHours($dur) }
        default   { $ahora.AddDays($dur) }
    }
    if (-not (Test-Path $script:SatDir)) { New-Item -ItemType Directory -Path $script:SatDir -Force | Out-Null }
    $script:SatPasesT = 0; $script:SatPasesC = 0; $script:SatFallos = 0; $script:SatError = ''
    $script:SatProxTcu = $ahora; $script:SatProxCom = $ahora
    $script:SatOn = $true
    Sat-Guardar
    Sat-Log 'INICIO' "$dur $unid, cada $($script:SatIntTcu)s (TCU) y $($script:SatIntCom)s (comms), hasta $($script:SatHasta.ToString('yyyy-MM-dd HH:mm')). Carpeta: $script:SatDir"
    return Sat-Estado
}
function Sat-Parar {
    if (-not $script:SatOn) { throw 'no hay ningun ensayo en marcha' }
    $script:SatOn = $false; Sat-Guardar
    Sat-Log 'PARADA' "parado a mano desde la web tras $($script:SatPasesT) pases de TCU y $($script:SatPasesC) de comms"
    return Sat-Estado
}
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
        # GW va aqui tambien: la toolbox lo anadio en la v11.6 y sin el la web
        # no puede decir de que gateway cuelga cada TCU. Ademas Export-Csv se
        # queda con las columnas de la PRIMERA fila: si falta en esta, falta en
        # todo el fichero.
        NCU=$ncu; TCU=$tcu; GW=''; Salud=$salud; Modo=''
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
        foreach ($h in $hsus) {
            $h | Add-Member -NotePropertyName NCU -NotePropertyValue $et -Force
            $h | Add-Member -NotePropertyName GW -NotePropertyValue '' -Force
            $filas += $h
        }
        foreach ($tcu in (Tcus-DeNcu $n)) {
            $d = $null
            if ($dm) { $d = $dm[[int]$tcu] }
            if ($null -eq $d) { $filas += Fila-Vacia $et $tcu 'OFFLINE' 'sin datos via NCU' }
            else {
                $d | Add-Member -NotePropertyName NCU -NotePropertyValue $et -Force
                $d | Add-Member -NotePropertyName GW -NotePropertyValue (Gw-DeTcu $n.gws ([int]$tcu)) -Force
                $filas += $d
            }
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

# CSV por TCU: "NCU;TCU;variable;valor" (o sin NCU). Cada TCU lleva lo suyo y
# puede cruzar NCUs, que es justo lo que un rango no sabe hacer.
function Escribir-Csv($body) {
    $lineas = @("$($body.csv)" -split "`r?`n")
    $r = Parse-CsvPorTcu $lineas
    if (@($r.jobs).Count -eq 0) { throw ("el CSV no trae ninguna linea valida" + $(if (@($r.errores).Count) { ": " + (@($r.errores) -join '; ') } else { '' })) }
    $porNcu = @{}
    foreach ($j in @($r.jobs)) {
        $k = "$($j.ncu)"
        if (-not $porNcu.ContainsKey($k)) { $porNcu[$k] = @() }
        $porNcu[$k] += ,$j
    }
    $filas = @()
    foreach ($n in (Ncus-DePlanta)) {
        $k = "$($n.ncu)"
        $mios = @()
        if ($porNcu.ContainsKey($k)) { $mios = @($porNcu[$k]) }
        elseif ($porNcu.ContainsKey('') -and @(Ncus-DePlanta).Count -eq 1) { $mios = @($porNcu['']) }
        if ($mios.Count -eq 0) { continue }
        $cx = @{ip = $n.ip; puerto = $null; gws = $n.gws; multi = $null; etiqueta = 'auto'; to = $timeoutMs; reint = 2}
        foreach ($seg in @(Plan-Segmentos @($mios | ForEach-Object { [int]$_.tcu } | Sort-Object -Unique) $cx)) {
            try { Modbus-Conectar $n.ip $seg.puerto $timeoutMs } catch { continue }
            foreach ($tcu in $seg.tcus) {
                foreach ($j in @($mios | Where-Object { [int]$_.tcu -eq [int]$tcu })) {
                    try {
                        if ($j.esc.modo -eq 'fc16') { FC16-Escribir ([byte]$tcu) $j.esc.addr $j.esc.palabras }
                        else { FC22-Mascara ([byte]$tcu) $j.esc.addr $j.esc.and $j.esc.or }
                        $cmp = Comparar-Escritura ([byte]$tcu) $j.esc
                        $filas += @{ncu = $k; tcu = [int]$tcu; ok = $cmp.ok; detalle = $(if ($cmp.ok) { "$($j.nombre) = $($j.texto)" } else { "$($j.nombre): verificacion, leido $($cmp.leidoRaw)" })}
                    } catch { $filas += @{ncu = $k; tcu = [int]$tcu; ok = $false; detalle = "$($j.nombre): $_"} }
                }
            }
            Modbus-Cerrar
        }
    }
    return $filas
}

function Op-Escritura([string]$op, $body) {
    if ($op -eq 'escribir-csv') { return Escribir-Csv $body }
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
        'escribir-lote' {
            # varias variables de una pasada, como la tabla de Escribir. La
            # identidad de red no entra: dos TCUs con el mismo esclavo hacen
            # desaparecer a una de las dos de la Zigbee.
            $vars = @()
            foreach ($v in @($body.valores)) {
                $nom = Resolver-Variable "$($v.variable)"
                $vd = $VARIABLES[$nom]
                if ($ADDR_COMANDO -contains $vd.addr) { throw "'$nom' es un registro de COMANDO: usa su endpoint (modo/stow/reloj/nvm/comisionado)" }
                if ($ADDR_IDENTIDAD -contains $vd.addr) { throw "'$nom' es identidad de red (esclavo/PAN ID/clave): no se escribe en remoto ni en lote" }
                $vars += @{nombre = $nom; vdef = $vd; texto = "$($v.valor)"; esc = (Valor-A-Escritura $vd "$($v.valor)")}
            }
            if ($vars.Count -eq 0) { throw 'falta "valores": [{"variable":"41010","valor":"-1.685"}, ...]' }
            return Ejecutar-PorRango $ncu (Tcus-DeCuerpo $body) {
                param($t)
                $hechas = @(); $fallo = ''
                foreach ($v in $vars) {
                    try {
                        $previo = '?'
                        try { $previo = Leer-Decodificado $t $v.vdef } catch {}
                        if ($v.esc.modo -eq 'fc16') { FC16-Escribir $t $v.esc.addr $v.esc.palabras }
                        else { FC22-Mascara $t $v.esc.addr $v.esc.and $v.esc.or }
                        $cmp = Comparar-Escritura $t $v.esc
                        if (-not $cmp.ok) { $fallo = "$($v.nombre): verificacion, leido $($cmp.leidoRaw)"; break }
                        $hechas += "$($v.nombre) : $previo -> $($v.texto)"
                    } catch { $fallo = "$($v.nombre): $_"; break }
                }
                if ($fallo -ne '') { @{tcu = [int]$t; ok = $false; detalle = $fallo} }
                else { @{tcu = [int]$t; ok = $true; detalle = ($hechas -join ' | ')} }
            }.GetNewClosure()
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
$OPS_POST = @('modo', 'limpiar-alarmas', 'stow', 'unstow', 'comisionado', 'reloj', 'nvm', 'escribir', 'escribir-lote', 'escribir-csv')
# El SAT no toca los seguidores: arranca y para un registro que se graba aqui.
# Por eso no va detras de 'permitir_escritura' ni pide doble confirmacion.
$OPS_SAT = @('sat/iniciar', 'sat/parar')
# La auditoria va en POST solo porque el preset viaja en el cuerpo: no escribe
# nada, asi que no depende de permitir_escritura ni pide doble confirmacion.
$OPS_LECTURA_POST = @('auditoria')
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$puerto/")
$listener.Start()
Write-Host "TCU Agente v$VERSION_AGENTE - planta '$($cfg.planta)' - http://localhost:$puerto  (toolbox v$VERSION_TOOLBOX)"
Write-Host "Lectura (GET, X-Token): /ping /diagnostico /comisionado /hsus /hsus/meteo /hsus/config /hsus/cajanegra /baterias /inventario /cierre /trabajos /plan-firmware /leer /sincronizar /sat /sat/descargar"
Write-Host ("Lectura (POST, el preset va en el cuerpo): {0}" -f ($OPS_LECTURA_POST -join ' '))
Write-Host ("SAT (POST): {0}  - se graba en {1}" -f ($OPS_SAT -join ' '), $script:SatDir)
Write-Host ("Escritura (POST, X-Token + confirmar): {0}  [{1}]" -f ($OPS_POST -join ' '), $(if ($escritura) { 'HABILITADA' } else { 'DESHABILITADA (permitir_escritura=false)' }))
Write-Host ("Vigilante de alarmas: {0}" -f $(if ($intervaloVig -gt 0) { "cada $intervaloVig min" } else { 'apagado' }))
Write-Host "Expon el puerto con: cloudflared tunnel --url http://localhost:$puerto"

Sat-Restaurar
$proxVig = Get-Date
$tarea = $listener.GetContextAsync()
while ($true) {
    if ($intervaloVig -gt 0 -and (Get-Date) -ge $proxVig) {
        try { Vigilar } catch { Write-Host "vigilante: $_" }
        $proxVig = (Get-Date).AddMinutes($intervaloVig)
    }
    try { Sat-Tick } catch { Write-Host "SAT: $_" }
    if (-not $tarea.Wait(1000)) { continue }
    $ctx = $tarea.Result
    $tarea = $listener.GetContextAsync()
    $req = $ctx.Request; $res = $ctx.Response
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Headers', 'X-Token,X-Usuario,Content-Type')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
    if ($req.HttpMethod -eq 'OPTIONS') { $res.StatusCode = 204; $res.Close(); continue }
    $out = $null; $code = 200; $descarga = ''
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
                '/baterias'     { $out = Baterias-Planta }
                '/inventario'   { $out = Inventario-Planta }
                '/cierre'       { $out = Cierre-Planta }
                '/trabajos'     { $out = @{planta = $cfg.planta; trabajos = @(Trabajos-Lista)} }
                '/plan-firmware' { $out = Plan-Fw "$($req.QueryString['objetivo'])" $null "$($req.QueryString['min_tcu'])" }
                '/leer'         { $out = Leer-Planta "$($req.QueryString['vars'])" "$($req.QueryString['ncu'])" "$($req.QueryString['tcus'])" }
                '/hsus/meteo'   { $out = Hsus-Detalle 'meteo' }
                '/hsus/config'  { $out = Hsus-Detalle 'config' }
                '/hsus/cajanegra' { $out = Hsu-CajaNegra "$($req.QueryString['ncu'])" }
                '/sat'          { $out = Sat-Estado }
                '/sat/descargar' {
                    $nom = "$($req.QueryString['f'])"
                    # solo un nombre de fichero de ESA carpeta: nada de rutas
                    if ($nom -ne [System.IO.Path]::GetFileName($nom) -or $nom -eq '') { $code = 400; $out = @{error = 'nombre de fichero invalido'} }
                    else {
                        $ruta = Join-Path $script:SatDir $nom
                        if (-not (Test-Path $ruta)) { $code = 404; $out = @{error = "no existe '$nom'"} }
                        else { $descarga = $ruta }
                    }
                }
                default         { $code = 404; $out = @{error = 'ruta desconocida'} }
            }
        }
        elseif ($req.HttpMethod -eq 'POST' -and $OPS_LECTURA_POST -contains $req.Url.AbsolutePath.TrimStart('/')) {
            $body = $null
            if ($req.HasEntityBody) {
                $sr = New-Object IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body = $sr.ReadToEnd() | ConvertFrom-Json
            }
            $out = Auditar-Preset $body
        }
        elseif ($req.HttpMethod -eq 'POST' -and $OPS_SAT -contains $req.Url.AbsolutePath.TrimStart('/')) {
            $body = $null
            if ($req.HasEntityBody) {
                $sr = New-Object IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body = $sr.ReadToEnd() | ConvertFrom-Json
            }
            $usuario = "$($req.Headers['X-Usuario'])"; if (-not $usuario) { $usuario = '(desconocido)' }
            if ($req.Url.AbsolutePath -eq '/sat/iniciar') { $out = Sat-Iniciar $body; Auditar $usuario 'sat/iniciar' @{duracion = "$($body.duracion) $($body.unidad)"} @() }
            else { $out = Sat-Parar; Auditar $usuario 'sat/parar' @{} @() }
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
    } catch { $code = 500; $out = @{error = "$_"}; $descarga = '' }
    if ($descarga -ne '') {
        # un CSV del ensayo: se manda tal cual, para que el navegador lo guarde
        $buf = [IO.File]::ReadAllBytes($descarga)
        $res.StatusCode = 200
        $res.ContentType = 'text/csv; charset=utf-8'
        $res.Headers.Add('Content-Disposition', 'attachment; filename="' + [IO.Path]::GetFileName($descarga) + '"')
        $res.OutputStream.Write($buf, 0, $buf.Length)
        $res.Close()
    } else {
        $json = ConvertTo-Json $out -Depth 7
        $buf = [Text.Encoding]::UTF8.GetBytes($json)
        $res.StatusCode = $code
        $res.ContentType = 'application/json; charset=utf-8'
        $res.OutputStream.Write($buf, 0, $buf.Length)
        $res.Close()
    }
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    Write-Host ("{0}  {1} {2} -> {3}  ({4} ms)" -f (Get-Date -Format 'HH:mm:ss'), $req.HttpMethod, $req.Url.AbsolutePath, $code, $ms)
}
