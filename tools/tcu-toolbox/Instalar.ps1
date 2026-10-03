param([string]$Paquete,[string]$Destino,[string]$OrigenDatos,[switch]$Volver)
$ErrorActionPreference='Stop'
function Instalacion-Verificar([string]$carpeta){
    $m=Get-Content -LiteralPath (Join-Path $carpeta 'paquete.json') -Raw|ConvertFrom-Json
    if($m.version -notmatch '^\d+\.\d+$' -or $m.producto -ne 'Factiun Toolbox' -or -not $m.archivos){throw 'Manifiesto de paquete no valido.'}
    $permitidos=@{}
    foreach($a in $m.archivos){
        if($a.ruta -match '(^|[/\\])\.\.([/\\]|$)|[:\\]' -or [IO.Path]::IsPathRooted($a.ruta)){throw 'Ruta de paquete no valida.'}
        $f=Join-Path $carpeta $a.ruta
        if(-not (Test-Path -LiteralPath $f -PathType Leaf) -or (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -ne $a.sha256){throw "Integridad incorrecta: $($a.ruta)"}
        if($permitidos.ContainsKey($a.ruta.ToLowerInvariant())){throw 'Ruta duplicada en manifiesto.'}
        $permitidos[$a.ruta.ToLowerInvariant()]=$true
    }
    foreach($f in @(Get-ChildItem $carpeta -Recurse -File)){
        $rel=$f.FullName.Substring($carpeta.Length).TrimStart([char[]]'\/').Replace('\','/')
        if($rel -ne 'paquete.json' -and -not $permitidos.ContainsKey($rel.ToLowerInvariant())){throw "Fichero no declarado: $rel"}
    }
    return $m
}
function Instalacion-Extraer([string]$zip,[string]$destino){
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z=[IO.Compression.ZipFile]::OpenRead($zip)
    try{
        $total=0L;$rutas=@{}
        foreach($e in $z.Entries){
            # .NET Framework puede generar ZIP con separadores Windows.
            $nombre=$e.FullName.Replace('\','/')
            if($nombre -notmatch '^tcu-toolbox/' -or $nombre -match '(^|/)\.\.(/|$)|:'){throw 'El ZIP contiene rutas no permitidas.'}
            if($rutas.ContainsKey($nombre)){throw 'El ZIP contiene rutas duplicadas.'};$rutas[$nombre]=$true
            $total+=$e.Length;if($total -gt 100MB){throw 'Paquete descomprimido mayor de 100 MB.'}
        }
        foreach($e in $z.Entries){
            $nombre=$e.FullName.Replace('\','/');$ruta=Join-Path $destino $nombre
            if($nombre.EndsWith('/')){[void][IO.Directory]::CreateDirectory($ruta);continue}
            [void][IO.Directory]::CreateDirectory((Split-Path $ruta -Parent))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e,$ruta,$false)
        }
    }finally{$z.Dispose()}
    return Join-Path $destino 'tcu-toolbox'
}
function Instalacion-CopiarDatos([string]$origen,[string]$destino){
    # Lista positiva; nunca sobrescribir scripts ni descargar datos de otro cliente.
    foreach($n in @('usuarios.json','config_local.json','plantas.json','plantas.csv','plantas','registro','logs','backups','informes','logs-ncu','historial','trabajos','cierre','correcciones')){
        $f=Join-Path $origen $n
        if(Test-Path -LiteralPath $f){
            $d=Join-Path $destino $n
            if(Test-Path -LiteralPath $f -PathType Container){[void][IO.Directory]::CreateDirectory($d);foreach($h in @(Get-ChildItem -LiteralPath $f -Force)){Copy-Item -LiteralPath $h.FullName -Destination $d -Recurse -Force}}
            else{Copy-Item -LiteralPath $f -Destination $d -Force}
        }
    }
    $cred=Join-Path $origen 'descarga-logs'
    if(Test-Path -LiteralPath $cred){[void][IO.Directory]::CreateDirectory((Join-Path $destino 'descarga-logs'));foreach($f in @(Get-ChildItem $cred -Filter 'credenciales.*.xml' -File)){Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $destino 'descarga-logs') -Force}}
}
function Instalacion-GuardarEstado([string]$raiz,$estado){
    $ruta=Join-Path $raiz 'instalacion.json';$tmp=$ruta+'.tmp'
    $estado|ConvertTo-Json|Set-Content -LiteralPath $tmp -Encoding UTF8
    if(Test-Path -LiteralPath $ruta){[IO.File]::Replace($tmp,$ruta,[NullString]::Value)}else{[IO.File]::Move($tmp,$ruta)}
}
function Instalacion-Bloquear([string]$carpeta){
    if(-not $carpeta){return $null}
    try{return New-Object IO.FileStream((Join-Path $carpeta '.toolbox.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'Cierra la Toolbox: la carpeta de datos esta en uso o no permite escritura.'}
}
function Instalacion-Aplicar([string]$zip,[string]$raiz,[string]$origen){
    $raiz=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($raiz)
    [void][IO.Directory]::CreateDirectory($raiz)
    $tmp=Join-Path $raiz ('preparacion-'+[guid]::NewGuid())
    $bloqueo=$null;$bloqueoInstalacion=$null
    try{
        $bloqueoInstalacion=Instalacion-Bloquear $raiz
        $extraida=Instalacion-Extraer $zip $tmp;$m=Instalacion-Verificar $extraida
        $nueva=Join-Path $raiz ('versiones/'+$m.version)
        if(Test-Path -LiteralPath $nueva){throw 'Esta version ya esta instalada. No se sobrescribe.'}
        $previa='';$estadoRuta=Join-Path $raiz 'instalacion.json'
        if(Test-Path -LiteralPath $estadoRuta){$estado=Get-Content $estadoRuta -Raw|ConvertFrom-Json;$previa="$($estado.actual)";if(-not $origen){$origen=$previa}}
        $bloqueo=Instalacion-Bloquear $origen
        [void][IO.Directory]::CreateDirectory((Split-Path $nueva -Parent))
        Move-Item -LiteralPath $extraida -Destination $nueva
        try{
            if($origen){Instalacion-CopiarDatos $origen $nueva}
            $lanzador=@'
$ErrorActionPreference='Stop'
$e=Get-Content (Join-Path $PSScriptRoot 'instalacion.json') -Raw|ConvertFrom-Json
& (Join-Path $e.actual 'TCU_Toolbox.ps1')
'@
            Set-Content -LiteralPath (Join-Path $raiz 'Abrir.ps1') -Value $lanzador -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $raiz 'Abrir.bat') -Value '@powershell.exe -NoProfile -STA -File "%~dp0Abrir.ps1"' -Encoding ASCII
            # Activar es el ultimo paso, incluidos los lanzadores.
            Instalacion-GuardarEstado $raiz @{actual=$nueva;anterior=$previa;version=$m.version;fecha=(Get-Date).ToString('o')}
        }catch{Remove-Item -LiteralPath $nueva -Recurse -Force;throw}
        return $nueva
    }finally{if($bloqueo){$bloqueo.Dispose()};if($bloqueoInstalacion){$bloqueoInstalacion.Dispose()};if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Recurse -Force}}
}
function Instalacion-Volver([string]$raiz){
    $uno=$null;$dos=$null;$bloqueoInstalacion=$null;$nueva=$null;$activada=$false
    try{
        $bloqueoInstalacion=Instalacion-Bloquear $raiz
        $e=Get-Content (Join-Path $raiz 'instalacion.json') -Raw|ConvertFrom-Json
        if(-not $e.anterior -or -not (Test-Path (Join-Path $e.anterior 'TCU_Toolbox.ps1'))){throw 'No hay version anterior disponible.'}
        $uno=Instalacion-Bloquear $e.actual;$dos=Instalacion-Bloquear $e.anterior
        # Preparar otra carpeta: ni la activa ni la anterior se modifican.
        $nueva=Join-Path $raiz ('versiones/retorno-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($nueva)
        foreach($f in @(Get-ChildItem -LiteralPath $e.anterior -Force)){
            if($f.Name -ne '.toolbox.lock'){Copy-Item -LiteralPath $f.FullName -Destination $nueva -Recurse -Force}
        }
        Instalacion-CopiarDatos $e.actual $nueva
        Instalacion-GuardarEstado $raiz @{actual=$nueva;anterior=$e.actual;fecha=(Get-Date).ToString('o')}
        $activada=$true
        return $nueva
    }finally{
        if($dos){$dos.Dispose()};if($uno){$uno.Dispose()};if($bloqueoInstalacion){$bloqueoInstalacion.Dispose()}
        if(-not $activada -and $nueva -and (Test-Path -LiteralPath $nueva)){Remove-Item -LiteralPath $nueva -Recurse -Force}
    }
}
if($MyInvocation.InvocationName -ne '.'){
    Add-Type -AssemblyName System.Windows.Forms
    try{
        if(-not $Destino){$Destino=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'FactiunToolbox'}
        if(-not $Volver -and -not $Paquete){
            $op=[Windows.Forms.MessageBox]::Show('Cierra la Toolbox antes de continuar. SI: instalar/actualizar un ZIP. NO: volver a la version anterior. CANCELAR: salir.','Instalacion','YesNoCancel','Question')
            if($op -eq 'Cancel'){return};if($op -eq 'No'){$Volver=$true}else{
                $d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='Paquete Toolbox (*.zip)|*.zip'
                try{if($d.ShowDialog() -ne 'OK'){return};$Paquete=$d.FileName}finally{$d.Dispose()}
            }
        }
        $msg="Destino: $Destino`r`nCierra todas las ventanas de Toolbox. Se conservaran version anterior y datos.`r`nEl hash comprueba integridad, no identidad del editor: utiliza un paquete obtenido de la release oficial. Esta edicion piloto no tiene firma corporativa."
        if([Windows.Forms.MessageBox]::Show($msg,'Confirmar instalacion','OKCancel','Information') -ne 'OK'){return}
        if($Volver){$r=Instalacion-Volver $Destino}else{$r=Instalacion-Aplicar $Paquete $Destino $OrigenDatos}
        [void][Windows.Forms.MessageBox]::Show("Preparada: $r`r`nAbre Abrir.bat en $Destino.",'Instalacion completada')
        Start-Process explorer.exe -ArgumentList ('"'+$Destino+'"')
    }catch{[void][Windows.Forms.MessageBox]::Show("$_",'No se pudo instalar')}
}
