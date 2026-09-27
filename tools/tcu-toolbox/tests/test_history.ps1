$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../HistorialCsv.ps1')
function Check($ok,$msg){if(-not $ok){throw $msg};Write-Host "OK $msg"}
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hist-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($dir)
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=Join-Path $dir 'test.zip'
    $z=[IO.Compression.ZipFile]::Open($zip,'Create')
    $e=$z.CreateEntry('TCU_001_2026-09-20.csv');$w=New-Object IO.StreamWriter($e.Open())
    $w.Write("datetime;angle;target_angle;note`n2026-09-20 01:02:03;1;2;`"a;b`"`n2026-09-20 01:02:03;1;2;`"a;b`"`n2026-09-20 01:02:03;3;2;different`n2026-09-20 01:01:00;0;2;earlier`n");$w.Dispose();$z.Dispose()
    Check (@(Hist-Entradas $zip).Count -eq 1) 'Lista entradas CSV'
    $r=Hist-Leer $zip 'TCU_001_2026-09-20.csv'
    Check ($r.filas.Count -eq 3 -and $r.duplicadas -eq 1 -and $r.conflictos -eq 1) 'Deduplicacion exacta conserva conflictos'
    Check ($r.filas[0].angle -eq '0' -and 'a;b' -in $r.filas.note) 'Orden cronologico y comillas CSV'
    $antes=(Get-FileHash $zip).Hash
    try{Hist-Leer $zip '../ausente.csv';throw 'No rechazo entrada ausente'}catch{Check ($_ -match 'ya no existe') 'Entrada ausente controlada'}
    Check ((Get-FileHash $zip).Hash -eq $antes) 'ZIP intacto tras lectura'
    function Diag-Objetivo($f,$tr){return @{ip=$tr.ip;ncu=$f.NCU;tipo='TCU'}}
    $f=[pscustomobject]@{NCU='01';TCU='1'};$tag=@{fila=$f;trabajos=@{ip='10.0.0.1'}}
    $script:OpMeta=New-Object 'System.Collections.Generic.Dictionary[object,object]'
    $script:OpMeta[$f]=@{planta='Planta A';origen='lectura'}
    $a=Hist-Contexto $tag;$script:OpMeta[$f].planta='Planta B';$b=Hist-Contexto $tag
    Check ($a.carpeta -ne $b.carpeta -and $a.ip -eq '10.0.0.1') 'Aislamiento por planta y conexion capturada'
    $script:OpMeta[$f].origen='importado'
    try{Hist-Contexto $tag;throw 'Acepto importado'}catch{Check ($_ -match 'verificada') 'No inferir origen de archivos importados'}
    # Extraer solo las funciones del descargador: nunca ejecutar menu ni autenticar.
    $src=Get-Content (Join-Path $PSScriptRoot '../../descarga-logs/descarga_logs_ncu.ps1') -Raw
    $ast=[Management.Automation.Language.Parser]::ParseInput($src,[ref]$null,[ref]$null)
    foreach($name in @('DescargaDia')){
        $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        Invoke-Expression $fn.Extent.Text
    }
    function Log($msg){Write-Host $msg};function SesionWeb($ip,$tok){return $null};function CodigoHttp($err){return 0};function Start-Sleep{}
    $script:peticiones=0;$script:fallar=$false
    function Invoke-WebRequest{
        param($Uri,$WebSession,$TimeoutSec,$OutFile,[switch]$UseBasicParsing)
        $script:peticiones++
        if($script:fallar){throw 'Fallo simulado'}
        if($OutFile){Copy-Item $zip $OutFile}else{return @{Content='{}'}}
    }
    $Destino=Join-Path $dir 'dest';$Actualizar=$false;$fecha=(Get-Date).AddDays(-5).ToString('yyyy-MM-dd')
    Check ((DescargaDia '127.0.0.1' '01' $fecha 'dummy') -eq $true) 'Descarga inicial validada'
    $n=$script:peticiones
    Check ((DescargaDia '127.0.0.1' '01' $fecha 'dummy') -eq $true -and $script:peticiones -eq $n) 'Dia cerrado verificado reutilizado'
    $marca=Join-Path $Destino "NCU01/NCU01_$fecha.zip.descarga.json"
    $m=Get-Content $marca -Raw|ConvertFrom-Json;$m.cerrado=$false;$m|ConvertTo-Json|Set-Content $marca
    Check ((DescargaDia '127.0.0.1' '01' $fecha 'dummy') -eq $true -and $script:peticiones -gt $n) 'Copia parcial antigua se renueva tras cambio de dia'
    $hoy=(Get-Date).ToString('yyyy-MM-dd');[void](DescargaDia '127.0.0.1' '01' $hoy 'dummy');$n=$script:peticiones
    Check ((DescargaDia '127.0.0.1' '01' $hoy 'dummy') -eq $true -and $script:peticiones -gt $n) 'Dia abierto siempre actualizado'
    $actual=Join-Path $Destino "NCU01/NCU01_$hoy.zip";$hash=(Get-FileHash $actual).Hash
    $script:fallar=$true
    Check ((DescargaDia '127.0.0.1' '01' $hoy 'dummy') -eq $false) 'Fallo de red comunicado'
    Check ((Get-FileHash $actual).Hash -eq $hash) 'Fallo conserva copia anterior'
    $script:fallar=$false;$Actualizar=$true;$n=$script:peticiones
    Check ((DescargaDia '127.0.0.1' '01' $fecha 'dummy') -eq $true -and $script:peticiones -gt $n) 'Actualizacion explicita de dia cerrado'
}finally{Remove-Item $dir -Recurse -Force}
