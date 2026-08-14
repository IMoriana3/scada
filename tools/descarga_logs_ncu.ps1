# Descarga de los logs diarios de las NCU (webserver Sunner) — SIN Python:
# PowerShell puro, el que trae Windows de serie (5.1) o superior.
#
# API (capturada con DevTools, 13/14-08-2026):
#   GET  http://<ip>/private_api/csv/<AAAA-MM-DD>            -> indice del dia (JSON)
#   GET  http://<ip>/private_api/csv/<AAAA-MM-DD>/download   -> ZIP con TODOS los CSV del dia
#   login: usuario admin, contraseña NCU<nn> (el numero de la NCU); la ruta del POST
#   se prueba entre las candidatas y la buena se reconoce por Set-Cookie sunner_auth.
#
# Uso:
#   SIN ARGUMENTOS (doble clic en el .bat): MENÚ con todas las opciones —
#   descargar ayer / backfill / un dia / una NCU suelta / programar la tarea
#   nocturna de las 00:30 / editar la lista de NCUs.
#
#   Con argumentos (para la tarea programada o scripts):
#   .\descarga_logs_ncu.ps1 -Ip 192.168.4.45 -Ncu 05 -Desde 2026-08-03 -Hasta 2026-08-13
#   .\descarga_logs_ncu.ps1 -Ncus ncus.json                  # ayer, todas las NCU
#   .\descarga_logs_ncu.ps1 -Ncus ncus.json -Fecha 2026-08-13
#   ncus.json: [{"ncu":"05","ip":"192.168.4.45"},{"ncu":"06","ip":"192.168.4.46"}]
#              (admite "usuario" y "pass" por NCU si alguna no sigue el esquema)
#
# Salida ORGANIZADA POR NCU: logs-ncu\NCU05\NCU05_2026-08-13.zip + .indice.json
# (+ descargas.log en la raiz). Lo bajado antes en plano se recoloca solo.
# Los ZIP se arrastran tal cual a importar-logs.html.

param(
  [string]$Ncus, [string]$Ip, [string]$Ncu,
  [string]$Fecha, [string]$Desde, [string]$Hasta,
  [string]$Cookie = $env:SUNNER_AUTH,
  [string]$Usuario = "admin", [string]$Password,
  [string]$Destino = "logs-ncu"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Log($msg){
  if(-not (Test-Path $Destino)){ New-Item -ItemType Directory -Path $Destino | Out-Null }
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
  # organizado por NCU y luego por dia: logs-ncu\NCU05\NCU05_2026-08-13.zip
  # (el nombre conserva el prefijo NCU: el importador lee de ahi la etiqueta)
  $dir=Join-Path $Destino ("NCU{0}" -f $ncu)
  if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir | Out-Null }
  $zpath=Join-Path $dir "$etq.zip"
  foreach($suf in @(".zip",".indice.json")){    # lo bajado ANTES en plano se recoloca solo
    $viejo=Join-Path $Destino "$etq$suf"
    if((Test-Path $viejo) -and -not (Test-Path (Join-Path $dir "$etq$suf"))){
      Move-Item $viejo (Join-Path $dir "$etq$suf"); Log ("ORDENADO {0}{1} -> NCU{2}\" -f $etq,$suf,$ncu) }
  }
  if((Test-Path $zpath) -and ((Get-Item $zpath).Length -gt 0)){
    Log ("YA {0} (existe, {1} bytes) - no se re-descarga" -f $etq,(Get-Item $zpath).Length); return $true }
  $ses=SesionWeb $ip $tok
  $indice=$null
  try{ $indice=(Invoke-WebRequest -Uri $base -WebSession $ses -TimeoutSec 30 -UseBasicParsing).Content }
  catch{
    $cod=CodigoHttp $_
    if($cod -eq 401 -or $cod -eq 403){ return "auth" }
    if($cod -eq 404 -or $cod -eq 500){
      # medido en la NCU05 real (14-08): los dias que ya no guarda responden 500,
      # no 404 - reintentar seria perder minutos por cada dia vacio del rango
      Log ("NO ESTA {0}: la NCU no tiene ese dia (responde {1}) - lo que no se baja a tiempo, se pierde" -f $etq,$cod); return $false }
    Log ("AVISO {0}: indice no disponible ({1})" -f $etq,$_.Exception.Message)
  }
  for($intento=1;$intento -le 3;$intento++){
    $tmp="$zpath.parte"
    try{
      Invoke-WebRequest -Uri "$base/download" -WebSession $ses -TimeoutSec 600 -OutFile $tmp -UseBasicParsing
      $z=[System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $tmp)); $n=$z.Entries.Count; $z.Dispose()
      if($n -eq 0){ throw "ZIP vacio" }
      Move-Item -Force $tmp $zpath
      if($indice){ Set-Content -Path (Join-Path $dir "$etq.indice.json") -Value $indice -NoNewline }
      Log ("OK {0}: {1} ficheros, {2:N1} MB" -f $etq,$n,((Get-Item $zpath).Length/1MB))
      return $true
    } catch {
      if(Test-Path $tmp){ Remove-Item -Force $tmp }
      $cod=CodigoHttp $_
      if($cod -eq 401 -or $cod -eq 403){ return "auth" }
      if($cod -eq 404 -or $cod -eq 500){
        Log ("NO ESTA {0}: la NCU no tiene ese dia (responde {1}) - lo que no se baja a tiempo, se pierde" -f $etq,$cod); return $false }
      Log ("intento {0}/3 {1}: {2}" -f $intento,$etq,$_.Exception.Message)
      Start-Sleep -Seconds (5*$intento)
    }
  }
  Log ("FALLO {0} tras 3 intentos" -f $etq)
  return $false
}

function UsuarioDe($n){ if($n.PSObject.Properties["usuario"] -and $n.usuario){ $n.usuario } else { $Usuario } }
function ClaveDe($n){
  if($n.PSObject.Properties["pass"] -and $n.pass){ return $n.pass }
  if($Password){ return $Password }
  return "NCU" + ("{0}" -f $n.ncu).PadLeft(2,"0")
}

$script:galletas=@{}
function Sesion($n,[bool]$forzar){
  $ip=$n.ip
  if($forzar -or (-not $galletas.ContainsKey($ip))){
    if($Cookie -and -not $forzar){ $galletas[$ip]=$Cookie }
    else{ $galletas[$ip]=Login $ip (UsuarioDe $n) (ClaveDe $n) }
  }
  return $galletas[$ip]
}

function Rango($d,$h){
  try{ $d0=[datetime]::ParseExact($d,"yyyy-MM-dd",$null); $d1=[datetime]::ParseExact($h,"yyyy-MM-dd",$null) }
  catch{ Write-Host "Fecha mal escrita: tiene que ser AAAA-MM-DD (p.ej. 2026-08-03)"; return $null }
  if($d1 -lt $d0){ Write-Host "El 'hasta' es anterior al 'desde'"; return $null }
  $fs=@(); $dd=$d0; while($dd -le $d1){ $fs+=$dd.ToString("yyyy-MM-dd"); $dd=$dd.AddDays(1) }
  return ,$fs
}

function Ejecuta($lista,$fechas){
  $script:galletas=@{}
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
  return $mal
}

# ══════ MODO DIRECTO: con -Ncus o -Ip se ejecuta y sale (para la tarea nocturna) ══════
if($Ncus -or $Ip){
  if($Ncus){ $lista=Get-Content $Ncus -Raw | ConvertFrom-Json }
  else{ $lista=@([pscustomobject]@{ncu=$(if($Ncu){$Ncu}else{"?"}); ip=$Ip}) }
  if($Desde -or $Hasta){
    if(-not $Desde){ $Desde=$Hasta }; if(-not $Hasta){ $Hasta=$Desde }
    $fechas=Rango $Desde $Hasta; if(-not $fechas){ exit 2 }
  }elseif($Fecha){ $fechas=@($Fecha) }
  else{ $fechas=@((Get-Date).AddDays(-1).ToString("yyyy-MM-dd")) }   # por defecto: AYER
  $mal=Ejecuta $lista $fechas
  if($mal){ exit 1 } else { exit 0 }
}

# ══════ SIN ARGUMENTOS: MENÚ — doble clic en el .bat y a elegir ══════
$Destino=Join-Path $PSScriptRoot "logs-ncu"     # anclado a la carpeta del script
$rutaNcus=Join-Path $PSScriptRoot "ncus.json"
$TAREA="Factiun descarga logs NCU"
$PLANTILLA="[`r`n  {""ncu"":""05"",""ip"":""192.168.4.45""}`r`n]"

function CargaLista(){
  if(-not (Test-Path $rutaNcus)){
    Write-Host ""
    Write-Host "No existe ncus.json (la lista de NCUs de la planta). Lo creo con una plantilla"
    Write-Host "y te lo abro: pon una linea por NCU, con su numero y su IP, y guarda."
    Set-Content -Path $rutaNcus -Value $PLANTILLA
    if(Get-Command notepad -ErrorAction SilentlyContinue){ Start-Process notepad $rutaNcus -Wait }
  }
  try{ return ,(Get-Content $rutaNcus -Raw | ConvertFrom-Json) }
  catch{ Write-Host "ncus.json no se puede leer (¿json mal cerrado?): revisalo con la opcion 7"; return $null }
}

while($true){
  $AYER=(Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
  Write-Host ""
  Write-Host "════════ Descarga de logs de las NCU · $PSScriptRoot ════════"
  Write-Host "  1) Descargar AYER ($AYER) - todas las NCU de la planta"
  Write-Host "  2) Backfill: un rango de fechas - todas las NCU"
  Write-Host "  3) Un dia concreto - todas las NCU"
  Write-Host "  4) Una sola NCU, a mano (IP + numero)"
  Write-Host "  5) Programar la descarga de cada noche (00:30, automatica)"
  Write-Host "  6) Quitar la programacion nocturna"
  Write-Host "  7) Editar la lista de NCUs (ncus.json)"
  Write-Host "  0) Salir"
  $op=Read-Host "Opcion"
  switch($op){
    "1"{ $l=CargaLista; if($l){ Ejecuta $l @($AYER) | Out-Null } }
    "2"{ $d=Read-Host "Desde (AAAA-MM-DD)"
         $h=Read-Host ("Hasta (AAAA-MM-DD, Enter = ayer {0})" -f $AYER); if(-not $h){ $h=$AYER }
         $fs=Rango $d $h
         if($fs){ $l=CargaLista; if($l){ Ejecuta $l $fs | Out-Null } } }
    "3"{ $f=Read-Host "Dia (AAAA-MM-DD)"
         $fs=Rango $f $f
         if($fs){ $l=CargaLista; if($l){ Ejecuta $l $fs | Out-Null } } }
    "4"{ $ip9=Read-Host "IP de la NCU (p.ej. 192.168.4.45)"
         $n9=Read-Host "Numero de NCU (p.ej. 05)"
         $d=Read-Host ("Desde (AAAA-MM-DD, Enter = ayer {0})" -f $AYER); if(-not $d){ $d=$AYER }
         $h=Read-Host ("Hasta (AAAA-MM-DD, Enter = {0})" -f $d); if(-not $h){ $h=$d }
         $fs=Rango $d $h
         if($fs){ Ejecuta @([pscustomobject]@{ncu=$n9;ip=$ip9}) $fs | Out-Null } }
    "5"{ if(-not (Get-Command schtasks -ErrorAction SilentlyContinue)){ Write-Host "schtasks no disponible en este sistema"; break }
         $l=CargaLista; if(-not $l){ break }
         $tr='powershell -NoProfile -ExecutionPolicy Bypass -File \"{0}\" -Ncus \"{1}\" -Destino \"{2}\"' -f $PSCommandPath,$rutaNcus,$Destino
         schtasks /Create /F /TN $TAREA /TR $tr /SC DAILY /ST 00:30
         Write-Host "Programado: cada noche a las 00:30 baja AYER de todas las NCU de ncus.json."
         Write-Host "(la tarea corre con tu usuario: el PC tiene que estar encendido y con sesion iniciada, aunque este bloqueado)" }
    "6"{ if(Get-Command schtasks -ErrorAction SilentlyContinue){ schtasks /Delete /F /TN $TAREA } }
    "7"{ if(-not (Test-Path $rutaNcus)){ Set-Content -Path $rutaNcus -Value $PLANTILLA }
         if(Get-Command notepad -ErrorAction SilentlyContinue){ Start-Process notepad $rutaNcus -Wait }
         else{ Write-Host $rutaNcus } }
    "0"{ exit 0 }
    default{ Write-Host "Opcion no valida" }
  }
}
