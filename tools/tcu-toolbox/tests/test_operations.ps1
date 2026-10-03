$ErrorActionPreference='Stop'
$raiz=Split-Path $PSScriptRoot -Parent
. (Join-Path $raiz 'Operacion.ps1')
$script:OpFichero=Join-Path ([IO.Path]::GetTempPath()) ('op-test-'+[guid]::NewGuid()+'.json')
$src=Get-Content (Join-Path $raiz 'TCU_Toolbox.ps1') -Raw
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($src,[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($name in @('Fila-Tipo','Diag-OrigenFila')){
 $f=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 . ([scriptblock]::Create($f[0].Extent.Text))
}
function Check($n,$a,$b){if("$a" -ne "$b"){throw "$n esperado=$b actual=$a"};Write-Host "OK $n"}
$ahora=Get-Date
$m=@{origen='lectura';fecha=$ahora.ToString('o');planta='Planta A';modo='diagnóstico'}
$f=[pscustomobject]@{NCU='2';GW='504';TCU='18';Salud='ALARMA';Alarmas='Motor';Edad_s='12'}
Check 'lectura reciente' (Op-Calidad $f $m $ahora) 'LECTURA RECIENTE'
Check 'no rejuvenece con el reloj' (Op-Calidad $f $m $ahora.AddMinutes(6)) 'LECTURA ANTIGUA'
$f.Edad_s='500';Check 'cache antigua aunque consulta reciente' (Op-Calidad $f $m $ahora) 'DATO ANTIGUO'
$f.Edad_s='';Check 'sin edad identificada' (Op-Calidad $f $m $ahora) 'EDAD DE ORIGEN DESCONOCIDA'
Check 'importado no es actual' (Op-Calidad $f @{origen='importado'} $ahora) 'IMPORTADO / SIN ORIGEN'
# La NCU y el gateway SON el origen: no tienen edad de origen que desconocer.
# Salian siempre como dudosos y toda la pestana parecia dudosa (El Burgo, 02/10/2026).
$fn=[pscustomobject]@{NCU='2';GW='';TCU='NCU';Salud='OK';Alarmas='';Edad_s=''}
Check 'la NCU es el origen: reciente' (Op-Calidad $fn $m $ahora) 'LECTURA RECIENTE'
Check 'pero una lectura vieja de la NCU sigue siendo vieja' (Op-Calidad $fn $m $ahora.AddMinutes(6)) 'LECTURA ANTIGUA'
$fg=[pscustomobject]@{NCU='2';GW='1';TCU='GW1';Salud='OK';Alarmas='';Edad_s=''}
Check 'el gateway tambien es origen' (Op-Calidad $fg $m $ahora) 'LECTURA RECIENTE'
Check 'y su tipo es GW' (Fila-Tipo $fg) 'GW'
$tr=@(@{ncu='2';ip='10.0.0.1';cx=@{puerto=504}})
$k=Op-Clave $f $m $tr
Check 'IP separa identidad' ((Op-Clave $f $m @(@{ncu='2';ip='10.0.0.2';cx=@{puerto=504}})) -ne $k) True
Check 'planta separa identidad' ((Op-Clave $f @{planta='Planta B'} $tr) -ne $k) True
$ep=Op-Episodio $null $f $m;$ep.reconocida='vista';$ep.usuario='operador';$ep.nota='Comprobar motor'
$m2=@{fecha=$ahora.AddMinutes(1).ToString('o')}
$ep2=Op-Episodio $ep $f $m2
Check 'misma alarma conserva reconocimiento' $ep2.reconocida 'vista'
Check 'primera detección no se pierde' $ep2.primera $m.fecha
$f.Alarmas='Motor y batería';$ep3=Op-Episodio $ep2 $f $m2
Check 'alarma nueva requiere reconocimiento' $ep3.reconocida ''
$f.Salud='OK';$ep4=Op-Episodio $ep3 $f $m2
Check 'OK observado cierra episodio' $ep4.activa False
$f.Salud='ALARMA';$ep5=Op-Episodio $ep4 $f $m2
Check 'reaparición abre episodio' $ep5.activa True
$script:OpIncidencias[$k]=$ep2
try{
 Check 'guarda registro' (Op-Guardar) True
 $script:OpIncidencias=@{};Op-Cargar
 Check 'reconocimiento persiste' $script:OpIncidencias[$k].reconocida 'vista'
 Check 'nota persiste' $script:OpIncidencias[$k].nota 'Comprobar motor'
 # Barrido parcial conserva la fecha y el origen del objeto anterior.
 $script:DiagOrigen=New-Object 'System.Collections.Generic.Dictionary[object,object]'
 $script:DiagPrevias=@();$script:Ctx=@{diagnostico=@{trabajos=$tr}}
 $script:UltimoEsComm=$false;$script:OpLectura=$m;$script:UltimoDiag=@($f)
 Op-Actualizar
 Check 'fecha capturada' $script:OpMeta[$f].fecha $m.fecha
 $h=[pscustomobject]@{NCU='2';GW='502';TCU='HSU1';Salud='OK';Alarmas='';Edad_s='1'}
 $script:DiagPrevias=@($f);$script:OpLectura=@{origen='lectura';fecha=$ahora.AddMinutes(2).ToString('o');planta='Planta B'};$script:UltimoDiag=@($f,$h)
 Op-Actualizar
 Check 'parcial no rejuvenece TCU' $script:OpMeta[$f].fecha $m.fecha
 Check 'parcial no reasigna planta' $script:OpMeta[$f].planta 'Planta A'
 Check 'fila nueva conserva su planta' $script:OpMeta[$h].planta 'Planta B'
 # Lectura de comunicaciones OK no cierra la alarma observada en diagnóstico.
 $c=[pscustomobject]@{NCU='2';GW='504';TCU='18';Salud='OK';Alarmas='';Edad_s='1'}
 $script:OpLectura=$m;$script:UltimoEsComm=$true;$script:UltimoDiag=@($c);$script:DiagPrevias=@();Op-Actualizar
 Check 'comunicaciones no resuelve alarma' $script:OpIncidencias[$k].activa True
 $vieja=[pscustomobject]@{NCU='2';GW='504';TCU='18';Salud='OK';Alarmas='';Edad_s='900'}
 $script:UltimoEsComm=$false;$script:UltimoDiag=@($vieja);Op-Actualizar
 Check 'dato antiguo OK no resuelve alarma' $script:OpIncidencias[$k].activa True
 Op-Importar @($c) 'Copia' '2020-01-01'
 Check 'importación conserva origen de disco' $script:OpMeta[$c].origen 'importado'
}finally{Remove-Item $script:OpFichero -Force -ErrorAction SilentlyContinue}
Write-Host 'Operación: procedencia, episodios y persistencia OK'
