<#
.SINOPSIS
  Baja los CSV diarios que graban las NCUs y los deja listos para importar.

.POR QUE EXISTE
  Los logs viven en el disco de cada NCU y hoy se descargan A MANO desde su
  webserver. Eso significa que la prueba de lo que pasó un día de temporal
  depende de que alguien se acordara de bajarla — y no sabemos cuántos días
  guarda la NCU antes de reciclarlos. Con esto, una tarea programada baja todo
  cada noche y deja una carpeta que se arrastra entera al importador
  (factiun-cartera/importar-logs.html).

.QUE HACE
  1. Lee la topología de la planta (el mismo JSON/CSV que usa la TCU Toolbox)
     para saber la IP de cada NCU.
  2. DESCUBRE la ruta del webserver: no sabemos el patrón de URL exacto, así
     que prueba una lista de candidatos contra una NCU y se queda con el que
     conteste un CSV. Una vez descubierto, se guarda en el fichero de config y
     ya no vuelve a probar.
  3. Descarga los ficheros del día (o del rango que se le pida) de todas las
     NCUs, en paralelo controlado, con reintentos.
  4. Escribe un MANIFIESTO con el SHA-256 de cada fichero, la NCU de la que
     salió, su tamaño y la hora de descarga. Ese hash es el que luego enseña
     el SCADA en la ficha del equipo: si coinciden, nadie ha tocado nada.

.EJEMPLOS
  # Descubrir cómo sirve los logs una NCU concreta (una sola vez por planta)
  .\Descarga-Logs-NCU.ps1 -Topologia .\plantas\23003-el-burgo.json -Descubrir -Ncu 2

  # Descarga de ayer y hoy de toda la planta
  .\Descarga-Logs-NCU.ps1 -Topologia .\plantas\23003-el-burgo.json -Dias 2

  # Un día concreto (el del siniestro)
  .\Descarga-Logs-NCU.ps1 -Topologia .\plantas\23003-el-burgo.json -Fecha 2026-08-12

  # Dejarlo programado todas las noches a las 02:00
  .\Descarga-Logs-NCU.ps1 -Topologia C:\factiun\23003-el-burgo.json -Programar
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Topologia,
  [string]$Destino = "$env:USERPROFILE\Documents\logs-ncu",
  [int]$Dias = 1,
  [string]$Fecha,
  [switch]$Descubrir,
  [string]$Ncu,
  [switch]$Programar,
  [int]$TimeoutSeg = 25,
  [int]$Reintentos = 3,
  [switch]$Credencial,
  [string]$LoginRuta = '/'
)

$ErrorActionPreference = 'Stop'
$ConfigPath = Join-Path $Destino 'descarga.config.json'

# Patrones candidatos del webserver de la NCU. En cuanto uno conteste un CSV,
# se guarda y se deja de probar. {IP} {ARCH} {FECHA} {ANIO} {MES} {DIA}
$Patrones = @(
  'http://{IP}/logs/{ARCH}',
  'http://{IP}/log/{ARCH}',
  'http://{IP}/download/{ARCH}',
  'http://{IP}/files/logs/{ARCH}',
  'http://{IP}/api/logs/{ARCH}',
  'http://{IP}/api/v1/logs/{ARCH}',
  'http://{IP}/data/{FECHA}/{ARCH}',
  'http://{IP}/logs/{ANIO}/{MES}/{ARCH}',
  'http://{IP}/cgi-bin/download?file={ARCH}',
  'http://{IP}:8080/logs/{ARCH}',
  'http://{IP}:8000/logs/{ARCH}'
)

function Leer-Topologia([string]$ruta) {
  if (-not (Test-Path $ruta)) { throw "No encuentro la topología: $ruta" }
  $ext = [IO.Path]::GetExtension($ruta).ToLower()
  $ncus = @()
  if ($ext -eq '.json') {
    $j = Get-Content $ruta -Raw | ConvertFrom-Json
    # formato de la Toolbox: { planta, ncus:[{ncu, ip, tcu_ini, tcu_fin, hsus:[]}] }
    foreach ($n in $j.ncus) {
      $ncus += [pscustomobject]@{
        Ncu = [string]$n.ncu; Ip = [string]$n.ip
        TcuIni = [int]($n.tcu_ini); TcuFin = [int]($n.tcu_fin)
        Hsus = @($n.hsus)
      }
    }
    $planta = [string]$j.planta
  } else {
    # CSV: Planta;NCU;IP;Puerto;TCU_ini;TCU_fin
    $filas = Import-Csv $ruta -Delimiter ';'
    foreach ($f in $filas) {
      $ncus += [pscustomobject]@{
        Ncu = [string]$f.NCU; Ip = [string]$f.IP
        TcuIni = [int]$f.TCU_ini; TcuFin = [int]$f.TCU_fin; Hsus = @()
      }
    }
    $planta = ($filas | Select-Object -First 1).Planta
  }
  if (-not $ncus) { throw "La topología no trae ninguna NCU" }
  [pscustomobject]@{ Planta = $planta; Ncus = $ncus }
}

# Nombres tal y como los sirve la NCU. Se generan las DOS formas vistas:
#   [NCU2]_TCU_001_2026-08-12.csv   <- la que sirve el webserver
#   NCU2_TCU_001_20260812.csv       <- sin corchetes y con fecha compacta
# Se piden ambas y la que no exista simplemente falla, que ya se cuenta aparte.
function Nombres-De([pscustomobject]$n, [string]$yyyymmdd) {
  $iso = '{0}-{1}-{2}' -f $yyyymmdd.Substring(0,4), $yyyymmdd.Substring(4,2), $yyyymmdd.Substring(6,2)
  $out = @()
  foreach ($fmt in @(@{P="[NCU$($n.Ncu)]"; F=$iso}, @{P="NCU$($n.Ncu)"; F=$yyyymmdd})) {
    $out += "$($fmt.P)_NCU_$($fmt.F).csv"
    $out += "$($fmt.P)_NCU_SENSORS_$($fmt.F).csv"
    if ($n.TcuFin -ge $n.TcuIni -and $n.TcuFin -gt 0) {
      $n.TcuIni..$n.TcuFin | ForEach-Object { $out += ('{0}_TCU_{1:D3}_{2}.csv' -f $fmt.P, $_, $fmt.F) }
    }
    foreach ($h in $n.Hsus) { if ($h) { $out += "$($fmt.P)_HSU_$($h)_$($fmt.F).csv" } }
  }
  $out
}

function Url-De([string]$patron, [string]$ip, [string]$arch, [string]$yyyymmdd) {
  $patron.Replace('{IP}', $ip).Replace('{ARCH}', $arch).
    Replace('{FECHA}', "$($yyyymmdd.Substring(0,4))-$($yyyymmdd.Substring(4,2))-$($yyyymmdd.Substring(6,2))").
    Replace('{ANIO}', $yyyymmdd.Substring(0,4)).Replace('{MES}', $yyyymmdd.Substring(4,2)).
    Replace('{DIA}', $yyyymmdd.Substring(6,2))
}

function Parece-CSV([string]$texto) {
  # la primera línea de estos logs SIEMPRE empieza por datetime;
  $texto -and $texto.Length -gt 40 -and $texto.Substring(0, [Math]::Min(120, $texto.Length)) -match 'datetime\s*;'
}

# ---------------------------------------------------------------- credenciales
# El webserver de la NCU pide usuario y contraseña, y son DISTINTOS por planta
# (los de San Jose no son los de Ayora). Se piden UNA vez por planta con entrada
# enmascarada y se guardan con DPAPI (Export-Clixml): cifradas para TU usuario de
# Windows, asi que copiadas a otro PC o a otro usuario no sirven. Viven junto al
# config, en $Destino, nunca en el repo. La tarea nocturna (-Programar) corre con
# el mismo usuario y las lee sola. Con -Credencial se vuelven a pedir.
function Obtener-Credencial([string]$planta) {
  $ruta = Join-Path $Destino ("credenciales.{0}.xml" -f ($planta -replace '[^\w-]','_'))
  if (-not $Credencial -and (Test-Path $ruta)) {
    try { return Import-Clixml $ruta } catch { Write-Host "Credenciales guardadas ilegibles, se vuelven a pedir." -ForegroundColor Yellow }
  }
  $c = Get-Credential -Message "Usuario y contraseña del webserver de las NCU de $planta"
  if (-not $c) { throw "Sin usuario y contraseña de las NCU no puedo bajar nada." }
  $c | Export-Clixml $ruta
  Write-Host "Credenciales de $planta guardadas en $ruta (cifradas para tu usuario de Windows)." -ForegroundColor Green
  return $c
}

# ---------------------------------------------------------------- login por formulario
# El webserver de la NCU NO usa el cuadro nativo del navegador (HTTP Basic): tiene
# un FORMULARIO en la pagina, con su cookie de sesion. Asi que se entra como lo
# haria una persona: se pide la pagina, se rellena el formulario y se guarda la
# cookie. Y como CADA NCU es un webserver distinto, la sesion es POR NCU (por IP).
#
# Los nombres de los campos no se dan por supuestos: se LEEN del formulario. El
# de contraseña es el input type=password; el de usuario, el primer text/email;
# los hidden (tokens CSRF y similares) van tal cual. Pura: se prueba sin red.
function Formulario-Login([string]$html) {
  $form = $null
  foreach ($f in [regex]::Matches("$html", '(?is)<form\b[^>]*>.*?</form>')) {
    if ($f.Value -match '(?i)\btype\s*=\s*["'']?password') { $form = $f.Value; break }
  }
  if (-not $form) { return $null }
  $action = ''
  if ($form -match '(?is)<form\b[^>]*\baction\s*=\s*["'']?([^"''\s>]*)') { $action = $Matches[1] }
  $hidden = [ordered]@{}; $user = $null; $pass = $null
  foreach ($m in [regex]::Matches($form, '(?is)<input\b[^>]*>')) {
    $tag = $m.Value
    if ($tag -notmatch '(?i)\bname\s*=\s*["'']?([^"''\s>]+)') { continue }
    $name = $Matches[1]
    $type = 'text'; if ($tag -match '(?i)\btype\s*=\s*["'']?([^"''\s>]+)') { $type = $Matches[1].ToLower() }
    $val = '';     if ($tag -match '(?i)\bvalue\s*=\s*["'']?([^"''>]*)')    { $val = $Matches[1] }
    if ($type -eq 'password') { if (-not $pass) { $pass = $name } }
    elseif ($type -eq 'hidden') { $hidden[$name] = $val }
    elseif ($type -in 'text','email') { if (-not $user) { $user = $name } }
  }
  if (-not $pass) { return $null }
  return @{ action = $action; user = $user; pass = $pass; hidden = $hidden }
}

# La pagina de login, otra vez, en vez del CSV: las credenciales no han entrado.
function Parece-Login([string]$texto) { return ("$texto" -match '(?i)\btype\s*=\s*["'']?password') }

# La URL final tras redirecciones, sea PowerShell 5.1 (HttpWebResponse) o 7 (HttpResponseMessage)
function Uri-Final($r, [string]$pedida) {
  try { if ($r.BaseResponse.ResponseUri) { return $r.BaseResponse.ResponseUri } } catch {}
  try { if ($r.BaseResponse.RequestMessage.RequestUri) { return $r.BaseResponse.RequestMessage.RequestUri } } catch {}
  return [Uri]$pedida
}

# Entra en el webserver de UNA NCU y devuelve la sesion (con su cookie), o $null
# si esa NCU no presenta formulario (entonces se tira de Basic, por si acaso).
function Login-Formulario([string]$ip, [pscredential]$c) {
  $ruta = $(if ($LoginRuta.StartsWith('/')) { $LoginRuta } else { "/$LoginRuta" })
  $pedida = "http://$ip$ruta"
  $s = $null
  try { $r = Invoke-WebRequest -Uri $pedida -SessionVariable s -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop }
  catch { return $null }
  $f = Formulario-Login "$($r.Content)"
  if (-not $f) { return $null }
  $base = Uri-Final $r $pedida
  $destino = $(if ($f.action) { ([Uri]::new([Uri]$base, $f.action)).AbsoluteUri } else { ([Uri]$base).AbsoluteUri })
  $body = @{}
  foreach ($k in $f.hidden.Keys) { $body[$k] = $f.hidden[$k] }
  if ($f.user) { $body[$f.user] = $c.UserName }
  $body[$f.pass] = $c.GetNetworkCredential().Password
  try { [void](Invoke-WebRequest -Uri $destino -Method Post -Body $body -WebSession $s -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop) }
  catch { Write-Host "  login en $ip no ha respondido bien: $($_.Exception.Message)" -ForegroundColor Yellow; return $null }
  Write-Host "  login por formulario en $ip (campos: $($f.user) / $($f.pass))" -ForegroundColor DarkGray
  return $s
}

# Lo que lleva cada llamada HTTP a una NCU: su sesion (si hubo formulario) y,
# por si ese firmware fuera Basic, las credenciales tambien. Una sesion por IP,
# cacheada: se entra una vez por NCU y ya.
$Sesiones = @{}
function Http-Para([string]$ip) {
  $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($Cred.UserName):$($Cred.GetNetworkCredential().Password)"))
  $h = @{ Credential = $Cred; Headers = @{ Authorization = "Basic $b" } }
  if (-not $Sesiones.ContainsKey($ip)) { $Sesiones[$ip] = Login-Formulario $ip $Cred }
  if ($Sesiones[$ip]) { $h.WebSession = $Sesiones[$ip] }
  return $h
}

# Un 401 con credenciales puestas no es "esta TCU no existe": es que la NCU las
# rechaza. Seguir probando URLs, o pedir 2000 ficheros, es perder el tiempo.
function Es-401($err) {
  try { return ([int]$err.Exception.Response.StatusCode -eq 401) } catch { return $false }
}

function Descubrir-Patron([pscustomobject]$n, [string]$yyyymmdd) {
  Write-Host "Buscando cómo sirve los logs la NCU $($n.Ncu) ($($n.Ip))..." -ForegroundColor Cyan
  $arch = (Nombres-De $n $yyyymmdd)[0]     # el log de la propia NCU, que existe siempre
  foreach ($p in $Patrones) {
    $u = Url-De $p $n.Ip $arch $yyyymmdd
    try {
      $h = Http-Para $n.Ip
      $r = Invoke-WebRequest -Uri $u @h -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
      if ($r.StatusCode -eq 200 -and (Parece-CSV $r.Content)) {
        Write-Host "  ENCONTRADO: $p" -ForegroundColor Green
        return $p
      }
      if (Parece-Login $r.Content) { throw "La NCU $($n.Ncu) ($($n.Ip)) devuelve la pagina de login en vez del CSV: el usuario/contraseña de esta planta no han entrado. Relanza con -Credencial." }
      Write-Host "  $($r.StatusCode) pero no parece un CSV: $u" -ForegroundColor DarkGray
    } catch {
      if (Es-401 $_) { throw "La NCU $($n.Ncu) ($($n.Ip)) rechaza el usuario/contraseña. Vuelve a lanzar con -Credencial para meter los de esta planta." }
      Write-Host "  no: $u" -ForegroundColor DarkGray
    }
  }
  Write-Host @"

  Ninguno de los patrones conocidos ha funcionado.
  Abre el webserver de la NCU en el navegador, entra donde se descargan los
  logs, haz clic derecho sobre el enlace de un CSV -> Copiar dirección, y
  pásamela: se añade a la lista `$Patrones y esto queda resuelto para siempre.
"@ -ForegroundColor Yellow
  return $null
}

function Descargar([string]$url, [string]$destino, [string]$ip) {
  for ($i = 1; $i -le $Reintentos; $i++) {
    try {
      $h = Http-Para $ip
      Invoke-WebRequest -Uri $url @h -OutFile $destino -TimeoutSec $TimeoutSeg -UseBasicParsing -ErrorAction Stop
      # un 200 con HTML dentro no es un log: o es la pagina de login (credenciales
      # malas: se para aqui) o es otra cosa (no es este fichero: se cuenta aparte)
      $cab = ''
      try { $cab = [IO.File]::ReadAllText($destino).Substring(0, [Math]::Min(4096, (Get-Item $destino).Length)) } catch {}
      if (Parece-Login $cab) { Remove-Item $destino -ErrorAction SilentlyContinue; throw "La NCU devuelve la pagina de login en vez del CSV ($url): el usuario/contraseña de esta planta no han entrado. Relanza con -Credencial." }
      if (-not (Parece-CSV $cab)) { Remove-Item $destino -ErrorAction SilentlyContinue; return $false }
      return $true
    } catch {
      if ("$($_.Exception.Message)" -like '*pagina de login*') { throw }
      if (Es-401 $_) { throw "La NCU rechaza el usuario/contraseña ($url). Vuelve a lanzar con -Credencial para meter los de esta planta." }
      if ($i -eq $Reintentos) { return $false }
      Start-Sleep -Seconds ([Math]::Pow(2, $i))
    }
  }
  $false
}

# ---------------------------------------------------------------- topologia y credenciales
# Van antes de -Programar a proposito: la tarea nocturna no puede preguntar nada,
# asi que las credenciales de la planta tienen que estar guardadas ya.
$topo = Leer-Topologia $Topologia
New-Item -ItemType Directory -Force -Path $Destino | Out-Null
$Cred = Obtener-Credencial $topo.Planta

# ---------------------------------------------------------------- programar
if ($Programar) {
  $ps = (Get-Command powershell).Source
  $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Topologia `"$Topologia`" -Destino `"$Destino`" -Dias 2"
  $accion = New-ScheduledTaskAction -Execute $ps -Argument $args
  $disp = New-ScheduledTaskTrigger -Daily -At 02:00
  Register-ScheduledTask -TaskName 'Factiun - descarga de logs de NCU' -Action $accion -Trigger $disp `
    -Description 'Baja cada noche los CSV diarios de las NCUs (dos días, por si alguna noche falla)' -Force | Out-Null
  Write-Host "Programado: todas las noches a las 02:00, dos días de margen." -ForegroundColor Green
  return
}

# ---------------------------------------------------------------- descarga

$cfg = @{}
if (Test-Path $ConfigPath) { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable }

$fechas = @()
if ($Fecha) { $fechas = @(([datetime]$Fecha).ToString('yyyyMMdd')) }
else { 0..([Math]::Max(1,$Dias) - 1) | ForEach-Object { $fechas += (Get-Date).AddDays(-$_).ToString('yyyyMMdd') } }

if ($Descubrir) {
  $n = if ($Ncu) { $topo.Ncus | Where-Object { $_.Ncu -eq $Ncu } | Select-Object -First 1 } else { $topo.Ncus[0] }
  if (-not $n) { throw "No encuentro la NCU $Ncu en la topología" }
  $p = Descubrir-Patron $n $fechas[0]
  if ($p) {
    $cfg['patron'] = $p
    $cfg | ConvertTo-Json | Set-Content $ConfigPath -Encoding UTF8
    Write-Host "Guardado en $ConfigPath. Ya puedes lanzar la descarga normal." -ForegroundColor Green
  }
  return
}

$patron = $cfg['patron']
if (-not $patron) {
  $patron = Descubrir-Patron $topo.Ncus[0] $fechas[0]
  if (-not $patron) { throw "Sin saber la URL del webserver no puedo bajar nada. Lanza -Descubrir o pásame un enlace de ejemplo." }
  $cfg['patron'] = $patron
  $cfg | ConvertTo-Json | Set-Content $ConfigPath -Encoding UTF8
}

$manifiesto = @()
$ok = 0; $fallo = 0; $saltados = 0
foreach ($f in $fechas) {
  $carpeta = Join-Path $Destino "$($topo.Planta -replace '[^\w-]','_')\$f"
  New-Item -ItemType Directory -Force -Path $carpeta | Out-Null
  foreach ($n in $topo.Ncus) {
    foreach ($arch in (Nombres-De $n $f)) {
      $dest = Join-Path $carpeta $arch     # se conserva el nombre ORIGINAL: el importador lo entiende con y sin corchetes
      if (Test-Path $dest) { $saltados++; continue }        # ya lo tenemos: no se vuelve a pedir
      $u = Url-De $patron $n.Ip $arch $f
      if (Descargar $u $dest $n.Ip) {
        $h = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
        $manifiesto += [pscustomobject]@{
          fichero = $arch; ncu = $n.Ncu; ip = $n.Ip; dia = $f
          bytes = (Get-Item $dest).Length; sha256 = $h
          descargado = (Get-Date).ToString('o'); url = $u
        }
        $ok++
      } else {
        # Que falte una TCU es normal: no todas las posiciones existen.
        $fallo++
        Remove-Item $dest -ErrorAction SilentlyContinue
      }
    }
  }
  if ($manifiesto.Count) {
    $mf = Join-Path $carpeta 'manifiesto.json'
    $manifiesto | Where-Object { $_.dia -eq $f } |
      ConvertTo-Json -Depth 4 | Set-Content $mf -Encoding UTF8
  }
}

Write-Host ""
Write-Host "Descargados $ok ficheros · $saltados ya estaban · $fallo sin respuesta (normal: posiciones que no existen)" -ForegroundColor Green
Write-Host "Carpeta: $Destino" -ForegroundColor Green
Write-Host "Arrastra la carpeta del día a importar-logs.html y sube. El SHA-256 del manifiesto" -ForegroundColor Gray
Write-Host "tiene que coincidir con el que enseña el SCADA en la ficha de cada equipo." -ForegroundColor Gray
