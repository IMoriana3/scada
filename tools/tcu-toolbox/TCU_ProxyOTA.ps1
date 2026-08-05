# ============================================================================
#  TCU ProxyOTA v1.0 - graba la conversacion Modbus del TCU Updater de Sunner
#
#  Se pone EN MEDIO entre el updater y la NCU: el updater apunta a este PC
#  (127.0.0.1 + puerto de escucha) y el proxy reenvia todo a la NCU real,
#  registrando cada trama en un CSV. Sirve para documentar el protocolo OTA
#  (que no esta en los mapas Modbus) y para investigar por que una TCU falla
#  siempre al actualizar.
#
#  NO modifica nada: reenvia byte a byte en ambos sentidos, solo escucha.
#
#  Uso:
#     .\TCU_ProxyOTA.ps1 -Ncu 10.100.1.52 -Puerto 503 [-Escucha 5020]
#  y en el TCU Updater:  NCU IP = 127.0.0.1   Gateway port = 5020
# ============================================================================
param(
    [Parameter(Mandatory=$true)][string]$Ncu,
    [Parameter(Mandatory=$true)][int]$Puerto,
    [int]$Escucha = 5020,
    [string]$Salida = '',
    [int]$Sesiones = 0          # 0 = sin limite (Ctrl+C para parar); >0 para pruebas
)
$ErrorActionPreference = 'Stop'
$VERSION_PROXY = '1.0'

if (-not $Salida) {
    $dir = Join-Path $PSScriptRoot 'capturas'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $Salida = Join-Path $dir ('ota_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv')
}
Set-Content -Path $Salida -Value 'ms;sentido;unit;fc;dir;n;bytes;hex' -Encoding UTF8

function Nombre-FC([int]$fc) {
    switch ($fc) {
        1  { 'ReadCoils' }      2  { 'ReadDiscrete' }  3  { 'ReadHolding' }
        4  { 'ReadInput' }      5  { 'WriteCoil' }     6  { 'WriteReg' }
        15 { 'WriteCoils' }     16 { 'WriteRegs' }     22 { 'MaskWrite' }
        23 { 'ReadWriteRegs' }  43 { 'EncapIface' }
        default {
            if ($fc -band 0x80) { 'EXCEPCION-' + ('{0:X2}' -f $fc) } else { '0x{0:X2}' -f $fc }
        }
    }
}
$t0 = Get-Date
$script:NTramas = 0
$script:DirsEscritas = @{}
$script:UnitsVistas = @{}

# Trocea el flujo por cabecera MBAP (bytes 4-5 = longitud del resto) y anota
# una linea por trama completa.
function Procesar([System.Collections.Generic.List[byte]]$acc, [string]$sentido) {
    while ($acc.Count -ge 6) {
        $len = ([int]$acc[4] -shl 8) -bor $acc[5]
        if ($len -le 0 -or $acc.Count -lt 6 + $len) { break }
        $b = $acc.GetRange(0, 6 + $len).ToArray()
        $acc.RemoveRange(0, 6 + $len)
        if ($b.Length -lt 8) { continue }
        $unit = $b[6]; $fc = [int]$b[7]
        $dir = ''; $n = ''
        # las respuestas de lectura no llevan direccion (solo byte count); las
        # de escritura hacen eco de direccion y cantidad
        $conDir = ($sentido -eq '>') -or (@(5,6,15,16,22) -contains $fc)
        if ($conDir -and ($fc -band 0x80) -eq 0) {
            if ($b.Length -ge 12 -and @(3,4,15,16,23) -contains $fc) {
                $dir = ([int]$b[8] -shl 8) -bor $b[9]
                $n   = ([int]$b[10] -shl 8) -bor $b[11]
            } elseif ($b.Length -ge 10 -and @(5,6,22) -contains $fc) {
                $dir = ([int]$b[8] -shl 8) -bor $b[9]
            }
        }
        if ($sentido -eq '>') {
            $script:UnitsVistas["$unit"] = 1
            if ($fc -eq 16 -and $dir -ne '') { $script:DirsEscritas["$dir"] = 1 + [int]$script:DirsEscritas["$dir"] }
        }
        $fin = [math]::Min($b.Length, 40)
        $hex = (($b[7..($fin - 1)]) | ForEach-Object { '{0:X2}' -f $_ }) -join ''
        $nom = Nombre-FC $fc
        $script:NTramas++
        Add-Content -Path $Salida -Encoding UTF8 -Value ("{0};{1};{2};{3};{4};{5};{6};{7}" -f `
            [int]((Get-Date) - $t0).TotalMilliseconds, $sentido, $unit, $nom, $dir, $n, $b.Length, $hex)
        if ($script:NTramas % 100 -eq 0) { Write-Host ("  {0} tramas...  ultima: {1} {2} unit {3} dir {4}" -f $script:NTramas, $sentido, $nom, $unit, $dir) }
    }
}

function Resumen {
    Write-Host ("-- {0} tramas registradas en {1}" -f $script:NTramas, $Salida)
    if ($script:UnitsVistas.Count) {
        Write-Host ("   unit ids (numeros de TCU) vistos: {0}" -f ((@($script:UnitsVistas.Keys) | Sort-Object { [int]$_ }) -join ', '))
    }
    if ($script:DirsEscritas.Count) {
        $dirs = @($script:DirsEscritas.Keys | ForEach-Object { [int]$_ } | Sort-Object)
        $tot = 0; foreach ($k in $script:DirsEscritas.Keys) { $tot += [int]$script:DirsEscritas[$k] }
        Write-Host ("   escrituras FC16: {0} en {1} direcciones distintas, de {2} a {3} (candidatas al bloque OTA)" -f $tot, $dirs.Count, $dirs[0], $dirs[-1])
    }
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Escucha)
$listener.Start()
Write-Host "TCU ProxyOTA v$VERSION_PROXY  |  127.0.0.1:$Escucha  ->  ${Ncu}:${Puerto}"
Write-Host "En el TCU Updater:  NCU IP = 127.0.0.1   Gateway port = $Escucha"
Write-Host "Captura: $Salida   (Ctrl+C para terminar)"

$nSes = 0
while ($Sesiones -le 0 -or $nSes -lt $Sesiones) {
    $cliente = $listener.AcceptTcpClient()
    $nSes++
    Write-Host '-- cliente conectado --'
    $destino = $null
    try {
        $destino = New-Object System.Net.Sockets.TcpClient
        $destino.Connect($Ncu, $Puerto)
        $sc = $cliente.GetStream(); $sd = $destino.GetStream()
        $accC = New-Object System.Collections.Generic.List[byte]
        $accD = New-Object System.Collections.Generic.List[byte]
        $buf = New-Object byte[] 8192
        # Modbus TCP es peticion-respuesta: un solo hilo con sondeo basta y
        # evita los problemas de hilos/runspaces en PowerShell.
        while ($true) {
            $movido = $false
            if ($sc.DataAvailable) {
                $n = $sc.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $sd.Write($buf, 0, $n); $sd.Flush()
                for ($i = 0; $i -lt $n; $i++) { $accC.Add($buf[$i]) }
                Procesar $accC '>'
                $movido = $true
            }
            if ($sd.DataAvailable) {
                $n = $sd.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $sc.Write($buf, 0, $n); $sc.Flush()
                for ($i = 0; $i -lt $n; $i++) { $accD.Add($buf[$i]) }
                Procesar $accD '<'
                $movido = $true
            }
            if (-not $movido) {
                if ($cliente.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and -not $sc.DataAvailable) { break }
                Start-Sleep -Milliseconds 2
            }
        }
    } catch { Write-Host "sesion terminada: $_" }
    finally {
        if ($destino) { try { $destino.Close() } catch {} }
        try { $cliente.Close() } catch {}
        Resumen
    }
}
$listener.Stop()
