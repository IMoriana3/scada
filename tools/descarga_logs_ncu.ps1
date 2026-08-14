# Descarga de los logs diarios de las NCU (webserver Sunner) — SIN Python:
# PowerShell puro, el que trae Windows de serie (5.1) o superior.
#
# API (capturada con DevTools, 13/14-08-2026):
#   GET  http://<ip>/private_api/csv/<AAAA-MM-DD>            -> indice del dia (JSON)
#   GET  http://<ip>/private_api/csv/<AAAA-MM-DD>/download   -> ZIP con TODOS los CSV del dia
#   login: usuario admin, contraseña NCU<nn> (el numero de la NCU); la ruta del POST
#   se prueba entre las candidatas y la buena se reconoce por Set-Cookie sunner_auth.
#
# Uso (desde PowerShell, o con el .bat de al lado):
#   .\descarga_logs_ncu.ps1 -Ip 192.168.4.45 -Ncu 05 -Desde 2026-04-21 -Hasta 2026-08-13
#   .\descarga_logs_ncu.ps1 -Ncus ncus.json                  # ayer, todas las NCU
#   .\descarga_logs_ncu.ps1 -Ncus ncus.json -Fecha 2026-08-13
#   ncus.json: [{"ncu":"05","ip":"192.168.4.45"},{"ncu":"06","ip":"192.168.4.46"}]
#              (admite "usuario" y "pass" por NCU si alguna no sigue el esquema)
#
# Salida en -Destino (por defecto .\logs-ncu): NCU05_2026-08-13.zip + .indice.json
# + descargas.log. Los ZIP se arrastran tal cual a importar-logs.html.

param(
  [string]$Ncus, [string]$Ip, [string]$Ncu,
  [string]$Fecha, [string]$Desde, [string]$Hasta,
  [string]$Cookie = $env:SUNNER_AUTH,
  [string]$Usuario = "admin", [string]$Password,
  [string]$Destino = "logs-ncu"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

if(-not (Test-Path $Destino)){ New-Item -ItemType Directory -Path $Destino | Out-Null }
function Log($msg){
  $l = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
  Write-Host $l
  Add-Content -Path (Join-Path $Destino "descargas.log") -Value $l
}

# ---- login: rutas candidatas; la buena responde con la cookie ----
$CANDIDATOS = @(
  @{ruta="/private_api/login"; forma="json"},
  @{ruta="/private_api/auth";  forma="json"},
  @{ruta="/api/login";         forma="json"},
  @{ruta="/login";             forma="form"})
$CLAVES = @(,@("username","password")) + @(,@("user","password"))

function Login($ip,$usuario,$clave){
  foreach($c in $CANDIDATOS){ foreach($k in $CLAVES){
    try{
      $h=@{}; $h[$k[0]]=$usuario; $h[$k[1]]=$clave
      if($c.forma -eq "json"){ $body=($h|ConvertTo-Json -Compress); $ct="application/json" }
      else{ $body="{0}={1}&{2}={3}" -f $k[0],[uri]::EscapeDataString($usuario),$k[1],[uri]::EscapeDataString($clave)
            $ct="application/x-www-form-urlencoded" }
      $r=Invoke-WebRequest -Uri ("http://{0}{1}" -f $ip,$c.ruta) -Method Post -Body $body `
           -ContentType $ct -TimeoutSec 15 -UseBasicParsing
      $sc=@($r.Headers["Set-Cookie"]) -join "; "
      if($sc -match "sunner_auth=([^;,\s]+)"){
        Log ("login OK en {0}{1} como {2}" -f $ip,$c.ruta,$usuario)
        return $Matches[1]
      }
    } catch { }
  }}
  Log ("FALLO login en {0} como {1}: ninguna ruta candidata devolvio sunner_auth - captura el cURL del login del panel (o usa -Cookie)" -f $ip,$usuario)
  return $null
}

function CodigoHttp($err){ try{ return [int]$err.Exception.Response.StatusCode }catch{ return 0 } }

function SesionWeb($ip,$tok){
  # WebSession con la cookie: funciona igual en PowerShell 5.1 y 7 (el header
  # Cookie a mano lo descarta el 5.1)
  $ses=New-Object Microsoft.PowerShell.Commands.WebRequestSession
  $host9=($ip -split ":")[0]
  $ses.Cookies.Add((New-Object System.Net.Cookie("sunner_auth",$tok,"/",$host9)))
  return $ses
}

function DescargaDia($ip,$ncu,$fecha,$tok){
  $base="http://{0}/private_api/csv/{1}" -f $ip,$fecha
  $etq="NCU{0}_{1}" -f $ncu,$fecha
  $zpath=Join-Path $Destino "$etq.zip"
  if((Test-Path $zpath) -and ((Get-Item $zpath).Length -gt 0)){
    Log ("YA {0} (existe, {1} bytes) - no se re-descarga" -f $etq,(Get-Item $zpath).Length); return $true }
  $ses=SesionWeb $ip $tok
  $indice=$null
  try{ $indice=(Invoke-WebRequest -Uri $base -WebSession $ses -TimeoutSec 30 -UseBasicParsing).Content }
  catch{
    $cod=CodigoHttp $_
    if($cod -eq 401 -or $cod -eq 403){ return "auth" }
    if($cod -eq 404){ Log ("NO ESTA {0}: la NCU ya no guarda ese dia (404) - lo que no se baja a tiempo, se pierde" -f $etq); return $false }
    Log ("AVISO {0}: indice no disponible ({1})" -f $etq,$_.Exception.Message)
  }
  for($intento=1;$intento -le 3;$intento++){
    $tmp="$zpath.parte"
    try{
      Invoke-WebRequest -Uri "$base/download" -WebSession $ses -TimeoutSec 600 -OutFile $tmp -UseBasicParsing
      $z=[System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $tmp)); $n=$z.Entries.Count; $z.Dispose()
      if($n -eq 0){ throw "ZIP vacio" }
      Move-Item -Force $tmp $zpath
      if($indice){ Set-Content -Path (Join-Path $Destino "$etq.indice.json") -Value $indice -NoNewline }
      Log ("OK {0}: {1} ficheros, {2:N1} MB" -f $etq,$n,((Get-Item $zpath).Length/1MB))
      return $true
    } catch {
      if(Test-Path $tmp){ Remove-Item -Force $tmp }
      $cod=CodigoHttp $_
      if($cod -eq 401 -or $cod -eq 403){ return "auth" }
      if($cod -eq 404){ Log ("NO ESTA {0}: la NCU ya no guarda ese dia (404) - lo que no se baja a tiempo, se pierde" -f $etq); return $false }
      Log ("intento {0}/3 {1}: {2}" -f $intento,$etq,$_.Exception.Message)
      Start-Sleep -Seconds (5*$intento)
    }
  }
  Log ("FALLO {0} tras 3 intentos" -f $etq)
  return $false
}

# ---- NCUs y fechas ----
if($Ncus){ $lista=Get-Content $Ncus -Raw | ConvertFrom-Json }
elseif($Ip){ $lista=@([pscustomobject]@{ncu=$(if($Ncu){$Ncu}else{"?"}); ip=$Ip}) }
else{ Write-Host "Di las NCUs: -Ncus fichero.json  o  -Ip ... -Ncu ..."; exit 2 }

if($Desde -or $Hasta){
  if(-not $Desde){ $Desde=$Hasta }; if(-not $Hasta){ $Hasta=$Desde }
  $d0=[datetime]::ParseExact($Desde,"yyyy-MM-dd",$null)
  $d1=[datetime]::ParseExact($Hasta,"yyyy-MM-dd",$null)
  $fechas=@(); $d=$d0; while($d -le $d1){ $fechas+=$d.ToString("yyyy-MM-dd"); $d=$d.AddDays(1) }
}elseif($Fecha){ $fechas=@($Fecha) }
else{ $fechas=@((Get-Date).AddDays(-1).ToString("yyyy-MM-dd")) }   # por defecto: AYER

function UsuarioDe($n){ if($n.PSObject.Properties["usuario"] -and $n.usuario){ $n.usuario } else { $Usuario } }
function ClaveDe($n){
  if($n.PSObject.Properties["pass"] -and $n.pass){ return $n.pass }
  if($Password){ return $Password }
  return "NCU" + ("{0}" -f $n.ncu).PadLeft(2,"0")
}

$galletas=@{}
function Sesion($n,[bool]$forzar){
  $ip=$n.ip
  if($forzar -or (-not $galletas.ContainsKey($ip))){
    if($Cookie -and -not $forzar){ $galletas[$ip]=$Cookie }
    else{ $galletas[$ip]=Login $ip (UsuarioDe $n) (ClaveDe $n) }
  }
  return $galletas[$ip]
}

$bien=0; $mal=0
foreach($f in $fechas){ foreach($n in $lista){
  $tok=Sesion $n $false
  $res=$false
  if($tok){ $res=DescargaDia $n.ip ("{0}" -f $n.ncu) $f $tok }
  if("auth" -eq $res){
    $tok=Sesion $n $true
    if($tok){ $res=DescargaDia $n.ip ("{0}" -f $n.ncu) $f $tok }
    if("auth" -eq $res){ Log ("FALLO NCU{0}_{1}: la NCU rechaza la sesion incluso recien logueada" -f $n.ncu,$f); $res=$false }
  }
  if($res -eq $true){ $bien++ } else { $mal++ }
}}
Log ("fin: {0} bien, {1} mal" -f $bien,$mal)
if($mal){ exit 1 } else { exit 0 }
