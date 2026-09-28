$ErrorActionPreference='Stop'
$raiz=Split-Path $PSScriptRoot -Parent
$dir=Join-Path ([IO.Path]::GetTempPath()) ('client-tests-'+[guid]::NewGuid());[void][IO.Directory]::CreateDirectory($dir)
$PSScriptRootFake=$dir
$src=Get-Content (Join-Path $raiz 'TCU_Toolbox.ps1') -Raw
$ini=$src.IndexOf('$VERSION_TOOLBOX');$fin=$src.IndexOf('$form = New-Object System.Windows.Forms.Form')
Invoke-Expression ($src.Substring($ini,$fin-$ini).Replace('$PSScriptRoot','$PSScriptRootFake'))
$ast=[Management.Automation.Language.Parser]::ParseInput($src,[ref]$null,[ref]$null)
foreach($n in @('Ncu-DeNombre','Topologia-Avisos','Tcus-DeGw')){$f=$ast.Find({param($x)$x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n},$true);. ([scriptblock]::Create($f.Extent.Text))}
. (Join-Path $raiz 'Cliente.ps1')
. (Join-Path $raiz 'Operacion.ps1')
. (Join-Path $raiz 'Tendencias.ps1')
. (Join-Path $raiz 'Instalar.ps1')
function Check($ok,$msg){if(-not $ok){throw $msg};Write-Host "OK $msg"}
function Rechaza([scriptblock]$s,[string]$patron){$errorVisto='';try{& $s}catch{$errorVisto="$_"};Check ($errorVisto -match $patron) "Rechazo $patron"}
try{
    $vectores=Get-Content (Join-Path $raiz 'contracts/operations-v1.json') -Raw|ConvertFrom-Json
    foreach($c in $vectores.close_cases){Check ((Op-PuedeCerrar $c.input) -eq $c.allowed) "Contrato compartido $($c.id)"}
    $script:Usuario=@{usuario='prueba';nombre='Tecnico';rol='lectura'}
    Rechaza {Modbus-Transaccion 1 ([byte[]](16,0,1,0,1,2,0,0))} 'se requiere una sesion'
    $script:Usuario.rol='inventado';Check (-not (Puede 'lectura')) 'Rol desconocido denegado'
    $script:Usuario.rol='admin';Check (-not (Puede 'inventado')) 'Permiso desconocido denegado'
    $script:ModoDemo=$true;Rechaza {Modbus-Conectar '127.0.0.1' 502 1} 'DEMOSTRACION';Check (-not (Puede 'tecnico')) 'Demo no permite escrituras';$script:ModoDemo=$false
    $FICH_USUARIOS=Join-Path $dir 'usuarios.json';Set-Content $FICH_USUARIOS 'no json';Rechaza {Usuarios-Cargar} 'no es valido'
    Remove-Item $FICH_USUARIOS
    $script:Stream=New-Object IO.MemoryStream
    $orig=${function:Registro-Comando};function Registro-Comando{throw 'registro bloqueado'}
    Rechaza {Modbus-Transaccion 1 ([byte[]](16,0,1,0,1,2,0,0))} 'registro bloqueado'
    Check ($script:Stream.Length -eq 0) 'Fallo de registro impide enviar bytes';${function:Registro-Comando}=$orig;$script:Stream.Dispose();$script:Stream=$null
    $f=Join-Path $dir 'planta.json'
    @{plantas=@(@{nombre='Prueba NCU1 GW1';ip='192.0.2.1';puerto=503;tcu_ini=1;tcu_fin=10},@{nombre='Prueba NCU1 GW2';ip='192.0.2.1';puerto=504;tcu_ini=11;tcu_fin=20})}|ConvertTo-Json -Depth 4|Set-Content $f
    $v=Cliente-Topologia $f;Check ($v.errores.Count -eq 0 -and $v.tcus -eq 20) 'Topologia valida reutiliza modelo'
    $valida=Get-Content $f -Raw
    $v.objeto.plantas[1].nombre='Otro cliente NCU1 GW2';$v.objeto|ConvertTo-Json -Depth 5|Set-Content $f
    Check ([bool]((Cliente-Topologia $f).errores -match 'una sola planta')) 'Topologia rechaza mezcla de clientes'
    $valida|Set-Content $f;$v=Cliente-Topologia $f
    foreach($p in $v.objeto.plantas){$p|Add-Member -NotePropertyName trackers -NotePropertyValue 20}
    $v.objeto|ConvertTo-Json -Depth 5|Set-Content $f
    Check ((Cliente-Topologia $f).errores.Count -eq 0) 'Total NCU repetido por gateway no se suma'
    $v.objeto.plantas[1].trackers=21;$v.objeto|ConvertTo-Json -Depth 5|Set-Content $f
    Check ((Cliente-Topologia $f).errores.Count -gt 0) 'Totales NCU contradictorios rechazados'
    $valida|Set-Content $f;$v=Cliente-Topologia $f
    $v.objeto.plantas[1].tcu_ini=10;$v.objeto|ConvertTo-Json -Depth 5|Set-Content $f
    Check ((Cliente-Topologia $f).errores -match 'repetida') 'Topologia rechaza solapes entre gateways'
    $script:OpFichero=Join-Path $dir 'operacion.json'
    $m=@{origen='lectura';modo='diagnóstico';fecha=(Get-Date).ToString('o');planta='Prueba'}
    $fila=[pscustomobject]@{Salud='ALARMA';Alarmas='Motor';NCU='1';TCU='2';Edad_s='1'}
    $ep=Op-Episodio $null $fila $m;$script:OpIncidencias=@{equipo=$ep}
    $r=[pscustomobject]@{clave='equipo';fila=$fila;meta=$m;episodio=$ep;calidad='LECTURA RECIENTE'}
    function Auditar{}
    Op-Gestionar $r 'Tecnico A' 'en curso' 'Inspeccion'
    Check ($ep.estado -eq 'en curso' -and $fila.Salud -eq 'ALARMA') 'Gestion no altera alarma'
    Rechaza {Op-Gestionar $r 'Tecnico A' 'cerrado' 'Motor revisado'} 'repite el diagnostico'
    $fila.Salud='OK';$fila.Edad_s='900';Rechaza {Op-Gestionar $r 'A' 'cerrado' 'Revisado'} 'repite el diagnostico'
    $fila.Edad_s='1';Rechaza {Op-Gestionar $r 'A' 'cerrado' ''} 'Describe'
    Op-Gestionar $r 'A' 'cerrado' 'Verificado en lectura actual';Check ($ep.estado -eq 'cerrado') 'Cierre con evidencia reciente'
    $persistida=Get-Content $script:OpFichero -Raw|ConvertFrom-Json
    Check ((Get-Content $script:OpFichero -Raw) -match 'verificacion' -and $ep.verificacion.clave -eq 'equipo') 'Cierre guarda evidencia de origen'
    $antes=Get-Content $script:OpFichero -Raw;$guardar=${function:Op-Guardar}
    function Op-Guardar{$script:OpError='disco bloqueado';return $false}
    Rechaza {Op-Gestionar $r 'B' 'en curso' 'No debe guardarse'} 'disco bloqueado'
    Check ($r.episodio.estado -eq 'cerrado' -and (Get-Content $script:OpFichero -Raw) -eq $antes) 'Error al guardar conserva incidencia previa'
    ${function:Op-Guardar}=$guardar
    $html=Join-Path $dir 'informe.html';$fila.Alarmas='<script>alert(1)</script>';Cliente-Informe $html @($r)
    $h=Get-Content $html -Raw;Check ($h -match '&lt;script&gt;' -and $h -notmatch '<script>') 'Informe escapa datos y conserva contenido'
    $muestras=1..10000|ForEach-Object{[pscustomobject]@{datetime=([datetime]'2026-09-20').AddSeconds($_*10).ToString('yyyy-MM-dd HH:mm:ss');angle=$(if($_ -eq 5555){999}else{5});target_angle=8}}
    $serie=Tendencia-Serie $muestras 'angle';$puntos=@($serie.segmentos|ForEach-Object{$_})
    Check ($serie.reducida -and @($puntos|Where-Object{$_.y -eq 999}).Count -eq 1) 'Grafica conserva pico al reducir'
    Check ((Tendencia-Serie $muestras 'target_angle').escalon) 'Consigna a escalones'
    $muestras=@([pscustomobject]@{datetime='2026-09-20 00:00:00';angle=1},[pscustomobject]@{datetime='2026-09-20 00:00:10';angle=2},[pscustomobject]@{datetime='2026-09-20 00:00:10';angle=3},[pscustomobject]@{datetime='2026-09-20 00:00:20';angle=4})
    $serie=Tendencia-Serie $muestras 'angle';Check ($serie.omitidas -eq 2 -and $serie.segmentos.Count -eq 2) 'Conflictos no forman una curva inventada'
    $soporte=Join-Path $dir 'soporte.zip';Cliente-Soporte $soporte
    $z=[IO.Compression.ZipFile]::OpenRead($soporte);try{Check ($z.Entries.Count -eq 2 -and 'usuarios.json' -notin $z.Entries.Name) 'Soporte con lista positiva sin datos privados'}finally{$z.Dispose()}
    # Paquetes de prueba pequenos: rutas, hash, conservacion y vuelta.
    $escape=Join-Path $dir 'escape.zip';$z=[IO.Compression.ZipFile]::Open($escape,'Create')
    try{$e=$z.CreateEntry('tcu-toolbox\..\escape.txt');$w=New-Object IO.StreamWriter($e.Open());try{$w.Write('no salir')}finally{$w.Dispose()}}finally{$z.Dispose()}
    Rechaza {Instalacion-Extraer $escape (Join-Path $dir 'extraida')} 'rutas no permitidas'
    Check (-not (Test-Path (Join-Path $dir 'escape.txt'))) 'Separadores Windows no permiten salir del paquete'
    $raizInst=Join-Path $dir 'instalado'
    foreach($ver in @('1.0','1.1')){
        $base=Join-Path $dir "paquete$ver";$carpeta=Join-Path $base 'tcu-toolbox';[void][IO.Directory]::CreateDirectory($carpeta)
        Set-Content (Join-Path $carpeta 'TCU_Toolbox.ps1') '# ejemplo'
        @{producto='Factiun Toolbox';version=$ver;archivos=@(@{ruta='TCU_Toolbox.ps1';sha256=(Get-FileHash (Join-Path $carpeta 'TCU_Toolbox.ps1')).Hash})}|ConvertTo-Json -Depth 4|Set-Content (Join-Path $carpeta 'paquete.json')
        $zip=Join-Path $dir "$ver.zip";[IO.Compression.ZipFile]::CreateFromDirectory($base,$zip)
        $inst=Instalacion-Aplicar $zip $raizInst ''
        $datos=Join-Path $inst 'registro';[void][IO.Directory]::CreateDirectory($datos)
        if($ver -eq '1.0'){Set-Content (Join-Path $datos 'nota.txt') 'antes'}else{Check ((Get-Content (Join-Path $datos 'nota.txt')) -eq 'antes') 'Actualizacion conserva datos';Set-Content (Join-Path $datos 'nota.txt') 'despues'}
    }
    $antesEstado=Get-Content (Join-Path $raizInst 'instalacion.json') -Raw
    $anterior=($antesEstado|ConvertFrom-Json).anterior
    $copiar=${function:Instalacion-CopiarDatos}
    function Instalacion-CopiarDatos{param($origen,$destino);Set-Content (Join-Path $destino 'registro/nota.txt') 'copia incompleta';throw 'fallo durante copia'}
    Rechaza {Instalacion-Volver $raizInst} 'fallo durante copia'
    Check ((Get-Content (Join-Path $raizInst 'instalacion.json') -Raw) -eq $antesEstado -and (Get-Content (Join-Path $anterior 'registro/nota.txt')) -eq 'antes' -and (Get-Content (Join-Path $inst 'registro/nota.txt')) -eq 'despues') 'Retorno fallido no modifica versiones ni activacion'
    Check (@(Get-ChildItem (Join-Path $raizInst 'versiones') -Directory -Filter 'retorno-*').Count -eq 0) 'Retorno fallido limpia preparacion'
    ${function:Instalacion-CopiarDatos}=$copiar
    $lock=Instalacion-Bloquear $inst
    try{Rechaza {Instalacion-Volver $raizInst} 'en uso'}finally{$lock.Dispose()}
    Check ((Get-Content (Join-Path $raizInst 'instalacion.json') -Raw) -eq $antesEstado) 'Toolbox abierta impide cambio de version'
    $ret=Instalacion-Volver $raizInst;Check ((Get-Content (Join-Path $ret 'registro/nota.txt')) -eq 'despues') 'Retorno conserva datos recientes'
    Check ((Get-Content (Join-Path $anterior 'registro/nota.txt')) -eq 'antes') 'Retorno exitoso conserva copia anterior intacta'
    $FICH_USUARIOS=Join-Path $ret 'usuarios.json'
    Usuarios-Guardar @((Usuario-Nuevo 'admin' 'Prueba' 'admin' 'Frase segura para prueba'))
    Acceso-GuardarJson ($FICH_USUARIOS+'.acceso.json') @{fallos=3;bloqueado_hasta=0}
    $estadoSeguro=Get-Content (Join-Path $raizInst 'instalacion.json') -Raw
    Rechaza {Instalacion-Volver $raizInst} 'no admite las contrasenas v2'
    Check ((Get-Content (Join-Path $raizInst 'instalacion.json') -Raw) -eq $estadoSeguro) 'Retorno incompatible no cambia activacion'
    $copiaSegura=Join-Path $dir 'copia-segura';[void][IO.Directory]::CreateDirectory($copiaSegura)
    Instalacion-CopiarDatos $ret $copiaSegura
    Check ((Test-Path (Join-Path $copiaSegura 'usuarios.json.inicializados')) -and (Get-Content (Join-Path $copiaSegura 'usuarios.json.acceso.json') -Raw|ConvertFrom-Json).fallos -eq 3) 'Actualizacion conserva marca y limite de acceso'
    $mal=Join-Path $dir 'paquete1.1/tcu-toolbox';Add-Content (Join-Path $mal 'TCU_Toolbox.ps1') 'alterado';Rechaza {Instalacion-Verificar $mal} 'Integridad incorrecta'
}finally{Remove-Item $dir -Recurse -Force}
Write-Host 'Cliente: permisos, topologia, gestion, graficas, informe, soporte e instalacion OK'
