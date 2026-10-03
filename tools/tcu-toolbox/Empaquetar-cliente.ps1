param([string]$Destino,[string]$Certificado)
$ErrorActionPreference='Stop'
if(-not $Destino){$Destino=Join-Path (Split-Path $PSScriptRoot -Parent) 'paquete-cliente'}
if(Test-Path $Destino){throw 'Usa un directorio nuevo para empaquetar.'}
$dir=Join-Path $Destino 'tcu-toolbox';[void][IO.Directory]::CreateDirectory($dir)
$fuente=Get-Content (Join-Path $PSScriptRoot 'TCU_Toolbox.ps1') -Raw
$version=[regex]::Match($fuente,"VERSION_TOOLBOX = '([0-9.]+)'").Groups[1].Value
foreach($n in @('TCU_Toolbox.ps1','TCU_Toolbox.bat','TCU_ProxyOTA.ps1','Operacion.ps1','HistorialCsv.ps1','Tendencias.ps1','Cliente.ps1','Demo.ps1','Instalar.ps1','Guia-cliente.html','COMPATIBILIDAD.md','PILOTO.md')){Copy-Item (Join-Path $PSScriptRoot $n) $dir}
[void][IO.Directory]::CreateDirectory((Join-Path $dir 'contracts'))
Copy-Item (Join-Path $PSScriptRoot 'contracts/operations-v1.json') (Join-Path $dir 'contracts/operations-v1.json')
$logs=Join-Path $PSScriptRoot 'descarga-logs'
if(-not (Test-Path $logs)){$logs=Join-Path (Split-Path $PSScriptRoot -Parent) 'descarga-logs'}
[void][IO.Directory]::CreateDirectory((Join-Path $dir 'descarga-logs'))
foreach($n in @('descarga_logs_ncu.ps1','Descarga-Logs.bat','README.md')){Copy-Item (Join-Path $logs $n) (Join-Path $dir 'descarga-logs')}
if($Certificado){
    $cert=Get-Item "Cert:\CurrentUser\My\$Certificado"
    foreach($f in @(Get-ChildItem $dir -Recurse -Filter '*.ps1')){$r=Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert -HashAlgorithm SHA256;if($r.Status -ne 'Valid'){throw "No se pudo firmar $($f.Name)"}}
}
$archivos=@(Get-ChildItem $dir -Recurse -File|ForEach-Object{@{ruta=$_.FullName.Substring($dir.Length).TrimStart([char[]]'\/').Replace('\','/');sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash}})
@{producto='Factiun Toolbox';version=$version;edicion='piloto';firmado=[bool]$Certificado;archivos=$archivos}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $dir 'paquete.json') -Encoding UTF8
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=Join-Path $Destino "Factiun_Toolbox_Cliente_v$version.zip"
[IO.Compression.ZipFile]::CreateFromDirectory($dir,$zip,[IO.Compression.CompressionLevel]::Optimal,$true)
Write-Host $zip
