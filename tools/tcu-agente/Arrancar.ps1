# =============================================================================
#  Arrancar.ps1 - lanza el TUNEL y el AGENTE en una sola ventana
# =============================================================================
#  Antes hacian falta dos consolas y copiar la URL a mano de una a otra. Y
#  cada arranque tropezaba en lo mismo: un agente anterior sin cerrar ocupando
#  el puerto, cloudflared que no esta en el PATH, o la URL que se pierde
#  scrolleando. Esto lo hace de una vez:
#
#    1. cierra el agente anterior si quedo abierto
#    2. busca cloudflared donde suele estar
#    3. levanta el tunel y ESPERA a que de la URL
#    4. la deja en el portapapeles y en 'ultima_url.txt'
#    5. arranca el agente en esta misma ventana
#    6. al salir, cierra el tunel
#
#  Si no encuentra cloudflared arranca solo el agente y lo dice: en un PC de
#  planta sin acceso remoto el tunel no siempre hace falta.
# =============================================================================
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

function Di([string]$t, [string]$color = 'Gray') { Write-Host $t -ForegroundColor $color }

# La URL que imprime cloudflared, sacada de su log. Sale dentro de un recuadro
# de guiones y barras, asi que no vale con leer una linea: se busca el patron.
# Pura, para poder probarla sin Windows ni tunel.
function Url-DeLog([string]$txt) {
    $m = [regex]::Match("$txt", 'https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com')
    if ($m.Success) { return $m.Value }
    return ''
}

# ---- 1. el agente anterior ---------------------------------------------------
# El puerto lo abre HTTP.SYS, asi que netstat siempre dice PID 4 (System) y no
# sirve para encontrar al culpable: hay que buscar por linea de comandos.
$viejos = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*TCU_Agente.ps1*' -and $_.ProcessId -ne $PID })
if ($viejos.Count -gt 0) {
    Di "Habia $($viejos.Count) agente(s) abiertos de antes. Los cierro." 'Yellow'
    foreach ($v in $viejos) { try { Stop-Process -Id $v.ProcessId -Force } catch {} }
    Start-Sleep -Milliseconds 800
}

# ---- 2. cloudflared ----------------------------------------------------------
$cfg = $null
$fCfg = Join-Path $dir 'agente_config.json'
if (Test-Path $fCfg) { try { $cfg = Get-Content $fCfg -Raw | ConvertFrom-Json } catch {} }
$puerto = $(if ($cfg -and $cfg.puerto) { [int]$cfg.puerto } else { 8585 })

$cf = $null
$candidatos = @()
if ($cfg -and $cfg.cloudflared) { $candidatos += "$($cfg.cloudflared)" }
$candidatos += @(
    (Join-Path $dir 'cloudflared.exe'),
    (Join-Path $dir 'cloudflared-windows-amd64.exe'),
    (Join-Path $env:USERPROFILE 'Downloads\cloudflared.exe'),
    (Join-Path $env:USERPROFILE 'Downloads\cloudflared-windows-amd64.exe'))
foreach ($c in $candidatos) { if ($c -and (Test-Path $c)) { $cf = $c; break } }
if (-not $cf) {
    $enPath = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($enPath) { $cf = $enPath.Source }
}

$proc = $null
$url = ''
if ($cf) {
    $log = Join-Path $env:TEMP ('cloudflared_{0}.log' -f $PID)
    if (Test-Path $log) { Remove-Item $log -Force -ErrorAction SilentlyContinue }
    Di "Tunel: $cf" 'DarkGray'
    # --http-host-header NO es opcional: el agente escucha en localhost y
    # Windows (HTTP.SYS) rechaza con "Bad Request - Invalid Hostname" cualquier
    # peticion cuyo Host sea otro, que es justo lo que reenvia Cloudflare.
    $proc = Start-Process -FilePath $cf -PassThru -WindowStyle Hidden `
        -ArgumentList @('tunnel', '--url', "http://localhost:$puerto",
                        '--http-host-header', "localhost:$puerto") `
        -RedirectStandardError $log -RedirectStandardOutput "$log.out"
    Di 'Esperando a que Cloudflare de la URL...' 'DarkGray'
    $hasta = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $hasta -and $url -eq '') {
        Start-Sleep -Milliseconds 500
        foreach ($f in @($log, "$log.out")) {
            if (-not (Test-Path $f)) { continue }
            $txt = ''
            try { $txt = Get-Content $f -Raw -ErrorAction SilentlyContinue } catch {}
            $u = Url-DeLog "$txt"
            if ($u) { $url = $u; break }
        }
    }
    if ($url) {
        try { $url | Set-Clipboard } catch {}
        try { Set-Content -Path (Join-Path $dir 'ultima_url.txt') -Value $url -Encoding UTF8 } catch {}
        Write-Host ''
        Di ('  ' + $url) 'Green'
        Di '  (copiada al portapapeles y guardada en ultima_url.txt)' 'DarkGray'
        Write-Host ''
    } else {
        Di 'El tunel no ha dado URL en 40 s. Mira si cloudflared sigue vivo; el agente arranca igual.' 'Yellow'
    }
} else {
    Di 'No encuentro cloudflared: arranco solo el agente (sin acceso desde fuera).' 'Yellow'
    Di 'Se baja de https://github.com/cloudflare/cloudflared/releases/latest y se deja en esta carpeta.' 'DarkGray'
}

# ---- 3. el agente, en esta ventana ------------------------------------------
try {
    & (Join-Path $dir 'TCU_Agente.ps1')
} finally {
    if ($proc -and -not $proc.HasExited) {
        Di 'Cerrando el tunel...' 'DarkGray'
        try { Stop-Process -Id $proc.Id -Force } catch {}
    }
}
