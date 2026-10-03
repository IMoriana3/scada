# La demostracion tiene su propia carpeta; no lee usuarios ni plantas reales.
$ErrorActionPreference='Stop'
$dest=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('FactiunToolbox/demo/'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dest)
foreach($nombre in @('TCU_Toolbox.ps1','Operacion.ps1','HistorialCsv.ps1','Cliente.ps1','Tendencias.ps1','Guia-cliente.html','COMPATIBILIDAD.md','PILOTO.md')){
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $nombre) -Destination $dest
}
& (Join-Path $dest 'TCU_Toolbox.ps1') -Demo
