# Prueba funcional de la logica no-GUI de TCU_Toolbox.ps1 contra mb_server.py
$ErrorActionPreference = 'Stop'
$raizTb = Split-Path $PSScriptRoot -Parent
$src = Get-Content (Join-Path $raizTb 'TCU_Toolbox.ps1') -Raw

# Extraer solo la parte de logica: desde $VERSION_TOOLBOX hasta antes de "#  Interfaz"
$ini = $src.IndexOf('$VERSION_TOOLBOX')
$fin = $src.IndexOf('$form = New-Object System.Windows.Forms.Form')
if ($ini -lt 0 -or $fin -lt 0) { throw 'No se pudo extraer la logica' }
$logica = $src.Substring($ini, $fin - $ini)
# quitar cabecera de seccion Interfaz si quedo colgando
$logica = $logica -replace '(?s)# -+\r?\n#  Interfaz.*$', ''
$tmp = [System.IO.Path]::GetTempPath()
$PSScriptRootFake = Join-Path $tmp 'tb_fake'
$null = New-Item -ItemType Directory -Path (Join-Path $PSScriptRootFake 'plantas') -Force
Get-ChildItem (Join-Path $PSScriptRootFake 'plantas') -File | Remove-Item -Force
Copy-Item (Join-Path $raizTb 'plantas/elburgo.json') (Join-Path $PSScriptRootFake 'plantas') -Force
$logica = $logica.Replace('$PSScriptRoot', '$PSScriptRootFake')
# anadir las funciones definidas en la seccion de handlers
$i1 = $src.IndexOf('function Ident-Leer'); $f1 = $src.IndexOf('$btnIdent.Add_Click')
$i2 = $src.IndexOf('function Diag-LeerTcu'); $f2 = $src.IndexOf('$btnDiag.Add_Click')
$i3 = $src.IndexOf('function Params-Conexion'); $f3 = $src.IndexOf('function Rango-Tcus')
$i4 = $src.IndexOf('function Nombres-Legibles'); $f4 = $src.IndexOf('function Refrescar-FiltroLeer')
$i5 = $src.IndexOf('function Hsu-Recorrer'); $f5 = $src.IndexOf('function Hsu-Mostrar')
$i6 = $src.IndexOf('function Anclaje-Para'); $f6 = $src.IndexOf('# Anclar contra un contenedor')
$i7 = $src.IndexOf('function Eti-Tcu'); $f7 = $src.IndexOf('# Divide una lista de TCUs')
$i8 = $src.IndexOf('function Nombres-Unicos'); $f8 = $src.IndexOf('function Vars-DeTablaLeer')
$i9 = $src.IndexOf('function Def-DeLectura'); $f9 = $src.IndexOf('$btnLeer.Add_Click')
$logica += "`n" + $src.Substring($i1, $f1 - $i1) + "`n" + $src.Substring($i2, $f2 - $i2) + "`n" + $src.Substring($i3, $f3 - $i3) + "`n" + $src.Substring($i4, $f4 - $i4) + "`n" + $src.Substring($i5, $f5 - $i5) + "`n" + $src.Substring($i6, $f6 - $i6) + "`n" + $src.Substring($i7, $f7 - $i7) + "`n" + $src.Substring($i8, $f8 - $i8) + "`n" + $src.Substring($i9, $f9 - $i9)
Invoke-Expression $logica

$fallos = 0
function Check([string]$nombre, $real, $esperado) {
    if ("$real" -eq "$esperado") { Write-Host "OK   $nombre = $real" }
    else { Write-Host "FAIL $nombre : obtenido '$real', esperado '$esperado'"; $script:fallos++ }
}

# ---------- controles usados pero nunca creados ----------
# En la v5.2 se rehizo la pestana Leer variable y se borro sin querer $lvL, la
# tabla de resultados, que los manejadores seguian usando: la lectura reventaba
# con "No se puede llamar a un metodo en una expresion con valor NULL". Este
# chequeo estatico lo caza sin abrir la ventana.
$astT = $null; $errT = $null
$arbol = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$astT, [ref]$errT)
Check 'script sin errores de sintaxis' $errT.Count 0
# UnqualifiedPath viene vacio para las variables sin ambito: el nombre se saca
# de UserPath quitando el prefijo (script:, global:...) a mano
function NomVar($vp) {
    if ($null -eq $vp -or $vp.IsDriveQualified) { return '' }
    $n = "$($vp.UserPath)"
    $i = $n.LastIndexOf(':')
    if ($i -ge 0) { $n = $n.Substring($i + 1) }
    return $n
}
$definidas = @{}
foreach ($a in $arbol.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $izq = $a.Left
    if ($izq -is [System.Management.Automation.Language.ConvertExpressionAst]) { $izq = $izq.Child }
    if ($izq -is [System.Management.Automation.Language.VariableExpressionAst]) { $n = NomVar $izq.VariablePath; if ($n) { $definidas[$n] = $true } }
}
foreach ($pa in $arbol.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) { $n = NomVar $pa.Name.VariablePath; if ($n) { $definidas[$n] = $true } }
foreach ($fe in $arbol.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { $n = NomVar $fe.Variable.VariablePath; if ($n) { $definidas[$n] = $true } }
$automaticas = @('_','args','true','false','null','PSScriptRoot','PSItem','this','input','error','host','MyInvocation','PSCommandPath','LASTEXITCODE','matches','PSVersionTable','PID','HOME','PWD','StackTrace','foreach','switch','ExecutionContext','PSBoundParameters','OFS')
$huerfanas = @{}
foreach ($ve in $arbol.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
    $n = NomVar $ve.VariablePath
    if (-not $n -or ($automaticas -contains $n)) { continue }
    if (-not $definidas.ContainsKey($n)) { $huerfanas[$n] = $true }
}
Check 'sin variables usadas y nunca creadas' (@($huerfanas.Keys | Sort-Object) -join ',') ''

# ---------- conversiones puras ----------
$e = Valor-A-Escritura @{addr=40038; tipo='u16'} '1500'
Check 'u16 palabras' ($e.palabras -join ',') '1500'
$e = Valor-A-Escritura @{addr=41037; tipo='s16'} '-1910'
Check 's16 negativo' ($e.palabras[0]) (65536 - 1910)
$e = Valor-A-Escritura @{addr=41070; tipo='u32'} '0x12345678'
Check 'u32 lo,hi' ($e.palabras -join ',') ((0x5678, 0x1234) -join ',')
$e = Valor-A-Escritura @{addr=41042; tipo='f32deg'} '-5'
$f = Palabras-A-F32 $e.palabras
Check 'f32deg -5 -> rad' ([math]::Round($f, 5)) (-0.08727)
$e = Valor-A-Escritura @{addr=41010; tipo='f32deg'} '-1,685'   # coma decimal espanola
$f = Palabras-A-F32 $e.palabras
Check 'f32deg coma espanola' ([math]::Round($f * 180 / [math]::PI, 3)) (-1.685)
try { $null = Valor-A-Escritura @{addr=41042; tipo='f32deg'} '400'; Check 'f32deg guardarrail' 'no-lanzo' 'lanza' }
catch { Check 'f32deg guardarrail' 'lanza' 'lanza' }
# separador decimal: punto solo es de miles si tambien hay coma
$e = Valor-A-Escritura @{addr=41035; tipo='f32'} '1.234'
Check 'f32 punto decimal' ([math]::Round((Palabras-A-F32 $e.palabras), 3)) (1.234)
$e = Valor-A-Escritura @{addr=41035; tipo='f32'} '1.234,56'
Check 'f32 miles con coma' ([math]::Round((Palabras-A-F32 $e.palabras), 2)) (1234.56)
$e = Valor-A-Escritura @{addr=41042; tipo='f32deg'} '0.959'
Check 'f32deg punto decimal' ([math]::Round((Palabras-A-F32 $e.palabras) * 180 / [math]::PI, 3)) (0.959)
# no finitos: NaN e infinito rechazados
try { $null = Valor-A-Escritura @{addr=41042; tipo='f32deg'} 'NaN'; Check 'f32deg NaN' 'no-lanzo' 'lanza' }
catch { Check 'f32deg NaN' 'lanza' 'lanza' }
try { $null = Valor-A-Escritura @{addr=41035; tipo='f32'} 'Infinity'; Check 'f32 Inf' 'no-lanzo' 'lanza' }
catch { Check 'f32 Inf' 'lanza' 'lanza' }
try { $null = Valor-A-Escritura @{addr=41035; tipo='f32'} '1e39'; Check 'f32 desborda' 'no-lanzo' 'lanza' }
catch { Check 'f32 desborda' 'lanza' 'lanza' }
$e = Valor-A-Escritura @{addr=41004; tipo='u8lo'} '100'
Check 'u8lo mascara' ("{0:X4}/{1:X4}" -f $e.and, $e.or) 'FF00/0064'
$e = Valor-A-Escritura @{addr=41018; tipo='bit'; bit=11} '1'
Check 'bit11 set' ("{0:X4}/{1:X4}" -f $e.and, $e.or) 'F7FF/0800'
$e = Valor-A-Escritura @{addr=41018; tipo='bit'; bit=11} '0'
Check 'bit11 clear' ("{0:X4}/{1:X4}" -f $e.and, $e.or) 'F7FF/0000'
try { $null = Valor-A-Escritura @{addr=41018; tipo='bit'; bit=11} '2'; Check 'bit valida 0/1' 'no-lanzo' 'lanza' }
catch { Check 'bit valida 0/1' 'lanza' 'lanza' }
Check 'BCD 0x26' (BCD-Dec 0x26) 26

# ---------- orden numerico de variables ----------
$ordenados = @(Nombres-Ordenados @($VARIABLES.Keys))
$iMotor = [array]::IndexOf($ordenados, '41039 motor_velocity_eval [ms]')
$iTilt = [array]::IndexOf($ordenados, '41111 max_tilt_west_r1 [deg]')
Check 'orden: 41039 antes que 41111' ($iMotor -lt $iTilt -and $iMotor -ge 0) 'True'
Check 'orden: primero 40000' ($ordenados[0] -like '40000*') 'True'
Check 'orden: ultimo 42006' ($ordenados[-1] -like '42006*') 'True'

# ---------- plantas: entradas (auto), segmentos por gateway y CSV ----------
Check 'auto NCU1 existe' ($PLANTAS.Contains('El Burgo I NCU1 (auto)')) 'True'
Check 'auto NCU1 gws' (@($PLANTAS['El Burgo I NCU1 (auto)'].gws).Count) 2
Check 'auto NCU2 gws (con TCU109)' (@($PLANTAS['El Burgo I NCU2 (auto)'].gws).Count) 3
Check 'auto NCU2 rango' "$($PLANTAS['El Burgo I NCU2 (auto)'].ini)-$($PLANTAS['El Burgo I NCU2 (auto)'].fin)" '1-109'
$script:ConMsgs = @()
function Con([string]$t, $color) { $script:ConMsgs += $t }
$cxAuto = @{ip='10.100.1.56'; puerto=$null; gws=$PLANTAS['El Burgo I NCU2 (auto)'].gws; etiqueta='auto'; to=1000; reint=1}
$segs = @(Plan-Segmentos @(40..47) $cxAuto)
Check 'auto 40-47: 2 segmentos' ($segs.Count) 2
Check 'auto seg1 = 503' ($segs[0].puerto) 503
Check 'auto seg1 tcus' (@($segs[0].tcus) -join ',') '40,41,42,43,44,45'
Check 'auto seg2 = 504' ($segs[1].puerto) 504
$segs2 = @(Plan-Segmentos @(105..109) $cxAuto)
Check 'auto 109 va al 504' (@($segs2[-1].tcus) -join ',') '105,106,107,109'
Check 'auto avisa huerfano 108' (($script:ConMsgs -join ';') -like '*108*') 'True'
$cxFijo = @{ip='x'; puerto=503; gws=$null; etiqueta='503'; to=1000; reint=1}
Check 'puerto fijo: 1 segmento' (@(Plan-Segmentos @(1..5) $cxFijo).Count) 1

# ---------- planta completa ----------
Check 'planta completa existe' ($PLANTAS.Contains('El Burgo I (Planta completa)')) 'True'
$pc = $PLANTAS['El Burgo I (Planta completa)']
Check 'planta ncus = 2' (@($pc.ncus).Count) 2
Check 'planta ncu1 gws' (@($pc.ncus[0].gws).Count) 2
Check 'planta ncu2 gws' (@($pc.ncus[1].gws).Count) 3
Check 'planta ncu2 ip' ($pc.ncus[1].ip) '10.100.1.56'
$ltNcu2 = @(); foreach ($g in $pc.ncus[1].gws) { $ltNcu2 += @([int]$g.ini..[int]$g.fin) }
$ltNcu2 = @($ltNcu2 | Sort-Object -Unique)
Check 'planta ncu2 tcus (107+109, sin 108)' "$($ltNcu2.Count)/$($ltNcu2[-1])" '108/109'
try { $null = Plan-Segmentos @(1..3) @{multi=$pc.ncus; ip='(planta)'; to=1000; reint=1}; Check 'multi en Plan-Segmentos lanza' 'no-lanzo' 'lanza' }
catch { Check 'multi en Plan-Segmentos lanza' 'lanza' 'lanza' }
Check 'lista ncus 1,3-5' (@(Parse-ListaNums '1,3-5') -join ',') '1,3,4,5'
Check 'lista ncus vacia = null' ($null -eq (Parse-ListaNums '  ')) 'True'
try { $null = Parse-ListaNums '1,x'; Check 'lista ncus invalida lanza' 'no-lanzo' 'lanza' }
catch { Check 'lista ncus invalida lanza' 'lanza' 'lanza' }
# CSV de topologia tal cual sale de la plataforma (solo topologia: ni una
# credencial). La fila suelta de la TCU 109 es el caso raro que hay que cubrir.
$csvCampo = Join-Path $tmp 'test_plantas.csv'
@(
  'Planta;NCU;IP;Puerto;TCU_ini;TCU_fin'
  'El Burgo I;NCU1;10.100.1.52;503;1;56'
  'El Burgo I;NCU1;10.100.1.52;504;57;108'
  'El Burgo I;NCU2;10.100.1.56;503;1;45'
  'El Burgo I;NCU2;10.100.1.56;504;46;107'
  'El Burgo I;NCU2;10.100.1.56;504;109;109'
  'Planta 4.60;NCU1;192.168.4.60;503;1;44'
  'Planta 4.65;NCU1;192.168.4.65;503;1;41'
) | Set-Content $csvCampo -Encoding UTF8
$nCsv = Cargar-FicheroPlantas $csvCampo
Check 'csv de campo: 7 gateways' $nCsv 7
Check 'csv fila 109 con nombre unico' ($PLANTAS.Contains('El Burgo I NCU2 GW504 (109-109)')) 'True'

# ---------- filtro de variables ----------
$todos = @($VARIABLES.Keys) + @($ESTADO.Keys | ForEach-Object { 'ESTADO ' + $_ })
$r = @(Filtrar-Nombres $todos 'soc')
Check 'filtro soc >0' ($r.Count -gt 0) 'True'
Check 'filtro soc solo soc' ((@($r | Where-Object { $_ -notmatch '(?i)soc' })).Count) 0
$r2 = @(Filtrar-Nombres $todos 'SOC')
Check 'filtro sin mayusculas' ($r2.Count) ($r.Count)
$r3 = @(Filtrar-Nombres $todos 'tilt')
Check 'filtro tilt incluye estado' ((@($r3 | Where-Object { $_ -like 'ESTADO *tilt*' })).Count -gt 0) 'True'
$r4 = @(Filtrar-Nombres $todos '[K]')
Check 'filtro corchetes literal' ((@($r4 | Where-Object { $_ -notlike '*`[K`]*' })).Count) 0
Check 'filtro corchetes >0' ($r4.Count -gt 0) 'True'
$r5 = @(Filtrar-Nombres $todos '')
Check 'filtro vacio = todo' ($r5.Count) ($todos.Count)
$r6 = @(Filtrar-Nombres $todos 'zzzz_no_existe')
Check 'filtro sin coincidencias' ($r6.Count) 0
Check 'Bits-Texto al2 eje' ((Bits-Texto (1 -shl 8) $BITS_AL2) -join ';') 'eje bloqueado'

# ---------- resolver variable y CSV por TCU ----------
Check 'resolver exacto' (Resolver-Variable '41010 longitud [deg]') '41010 longitud [deg]'
Check 'resolver por prefijo' (Resolver-Variable '41010') '41010 longitud [deg]'
try { $null = Resolver-Variable '41004'; Check 'resolver ambiguo lanza' 'no-lanzo' 'lanza' }
catch { Check 'resolver ambiguo lanza' 'lanza' 'lanza' }
try { $null = Resolver-Variable 'zzzz'; Check 'resolver inexistente lanza' 'no-lanzo' 'lanza' }
catch { Check 'resolver inexistente lanza' 'lanza' 'lanza' }
$csv = @('TCU;variable;valor', '5;41035 panel_width [m];3,5', '6;41010;-1.685', '7;41004;1', 'x;41010;1', '9;41010')
$res = Parse-CsvPorTcu $csv
Check 'csv jobs validos' (@($res.jobs).Count) 2
Check 'csv errores' (@($res.errores).Count) 3
Check 'csv job coma decimal' ([math]::Round((Palabras-A-F32 $res.jobs[0].esc.palabras), 2)) (3.5)
Check 'csv job prefijo' ($res.jobs[1].nombre) '41010 longitud [deg]'

# ---------- cliente Modbus contra el servidor simulado ----------
Modbus-Conectar '127.0.0.1' 15020 3000

Check 'FC03 u16 vbat'      (Leer-Decodificado 5 @{addr=30094; tipo='u16'}) '25837'
Check 'FC03 s16 ibat'      (Leer-Decodificado 5 @{addr=30095; tipo='s16'}) '-500'
Check 'FC03 div10 tbat'    (Leer-Decodificado 5 @{addr=30097; tipo='s16'; div=10}) '21.5'
Check 'FC03 u8lo soc'      (Leer-Decodificado 5 @{addr=30096; tipo='u8lo'}) '87'
Check 'FC03 u8hi soh'      (Leer-Decodificado 5 @{addr=30096; tipo='u8hi'}) '95'
Check 'FC03 u32 energia'   (Leer-Decodificado 5 @{addr=30086; tipo='u32'}) '123456'
Check 'FC03 f32deg long'   (Leer-Decodificado 5 @{addr=41010; tipo='f32deg'}) '-1.685'
Check 'FC03 dt_bcd'        (Leer-Decodificado 5 @{addr=30079; tipo='dt_bcd'}) '2026-08-04 12:34:56'
Check 'FC03 charger'       (Leer-Decodificado 5 @{addr=30153; tipo='charger'}) '5 (carga CC)'
Check 'FC03 u16hex'        (Leer-Decodificado 5 @{addr=30001; tipo='u16hex'}) '0x0280'
Check 'FC03 bit'           (Leer-Decodificado 5 @{addr=30006; tipo='bit'; bit=11}) '1'

# excepcion gateway (unit 7)
try { $null = Leer-Decodificado 7 @{addr=30001; tipo='u16'}; Check 'exc gateway' 'no-lanzo' 'GatewayTargetNoResponse' }
catch { Check 'exc gateway' (("$_" -like '*GatewayTargetNoResponse*')) 'True' }
Check 'exc es modbus' (Es-ExcepcionModbus 'GatewayTargetNoResponse (0x0B)') 'True'
Check 'timeout no es modbus' (Es-ExcepcionModbus 'Unable to read data from the transport connection') 'False'

# FC16 + verificacion
FC16-Escribir 5 40038 @(2000)
Check 'FC16 escribe' ((FC03-Leer 5 40038 1)[0]) '2000'
# Comparar-Escritura (auditoria)
$escOk = Valor-A-Escritura @{addr=40038; tipo='u16'} '2000'
Check 'auditoria conforme' ((Comparar-Escritura 5 $escOk).ok) 'True'
$escKo = Valor-A-Escritura @{addr=40038; tipo='u16'} '1500'
$cmp = Comparar-Escritura 5 $escKo
Check 'auditoria desviacion' ($cmp.ok) 'False'
Check 'auditoria leidoRaw' ($cmp.leidoRaw) '07D0'
# FC22 byte bajo
FC22-Mascara 5 41004 0xFF00 0x0055
$v = (FC03-Leer 5 41004 1)[0]
Check 'FC22 u8lo' ($v -band 0xFF) '85'
# FC22 bit (secuencia reloj): set bit0, set bit1, clear ambos
FC16-Escribir 5 40007 @(0x8000)   # bit15 ya activo, debe conservarse
FC22-Mascara 5 40007 0xFFFE 0x0001
FC22-Mascara 5 40007 0xFFFD 0x0002
Check 'FC22 bits reloj set' ("0x{0:X4}" -f (FC03-Leer 5 40007 1)[0]) '0x8003'
FC22-Mascara 5 40007 0xFFFC 0x0000
Check 'FC22 bits reloj clear' ("0x{0:X4}" -f (FC03-Leer 5 40007 1)[0]) '0x8000'

# ---------- diagnostico ----------
$d = Diag-LeerTcu 5
Check 'diag salud TCU5' $d.Salud 'ALARMA'          # eje bloqueado + seta
Check 'diag tilt' $d.Tilt '15.5'
Check 'diag dif' $d.Dif '30.5'
Check 'diag soc' $d.SoC '87'
Check 'diag ibat' $d.Ibat_mA '-500'
Check 'diag alarmas contiene eje' ($d.Alarmas -like '*eje bloqueado*') 'True'
Check 'diag alarmas contiene seta' ($d.Alarmas -like '*seta*') 'True'
Check 'diag notas motor enclavado' ($d.Alarmas -like '*enclavada*') 'True'
$d6 = Diag-LeerTcu 6
Check 'diag salud TCU6' $d6.Salud 'OK'
Check 'diag modo TCU6' $d6.Modo 'AUTO'
Check 'diag sin cargador' ($null -eq $d6.PSObject.Properties['Cargador']) 'True'
Check 'leer modo decodificado' (Leer-Decodificado 5 @{addr=30001; tipo='modo'}) 'AUTO'
$d8 = Diag-LeerTcu 8
Check 'diag L3 (bit12) = AVISO' $d8.Salud 'AVISO'
$d9 = Diag-LeerTcu 9
Check 'diag batt_critical (bit14) = ALARMA' $d9.Salud 'ALARMA'
Check 'diag bit14 texto' ($d9.Alarmas -like '*SoC critico*') 'True'

# ---------- HSU (meteo) y NCU ----------
$met = Hsu-LeerMeteo 185
$h = @{}; foreach ($f in $met.filas) { $h[$f.Campo] = $f.Valor }
Check 'hsu nivel viento' $met.nivel 2
Check 'hsu viento m/s' $h['Viento [m/s]'] '12.5'
Check 'hsu direccion' $h['Direccion viento [deg]'] '270'
Check 'hsu nieve' $h['Nieve [m]'] '0.05'
Check 'hsu irradiancia' $h['Irradiancia [W/m2]'] '850'
Check 'hsu humedad' $h['Humedad rel [%]'] '45'
Check 'hsu temp rango' ([math]::Abs([double]::Parse($h['Temperatura ext [C]'], $INV) - 26.85) -lt 0.11) 'True'
Check 'hsu alarma viento' (($met.alarmas -join ';') -like '*ALARMA VIENTO*') 'True'
$cfg = Hsu-LeerConfig 185
Check 'hsu umbral ON' ($cfg.mid.ToString('0.##', $INV)) '18'
Check 'hsu umbral OFF' ($cfg.low.ToString('0.##', $INV)) '15'
Check 'hsu t ON/OFF' "$($cfg.tMid)/$($cfg.tLow)" '5/3'
$hc = @{}; foreach ($f in $cfg.filas) { $hc[$f.Campo] = $f.Nota }
Check 'hsu sensores' ($hc['Sensores config. (41008)'] -like '*nieve*anemometro*') 'True'
$cf = Hsu-CajaFila @(103, (10 -bor (23 -shl 8)), 3, 5005) 61
Check 'caja fila hora' $cf.Hora '01:01'
Check 'caja fila vmax' $cf.Vmax_kmh 23
Check 'caja fila irr' $cf.Irr_Wm2 '500.5'
$ns = Ncu-Salud
Check 'ncu salud ALARMA' $ns.salud 'ALARMA'
Check 'ncu gw2 caido' (($ns.alarmas -join ';') -like '*GW2*') 'True'
Check 'ncu fecha' ($ns.fecha -like '2026-08-05 08:00:00*') 'True'
Check 'runs consecutivos' ((@(Runs-Consecutivos @(1,2,3,7,9,10)) | ForEach-Object { "$($_.ini)-$($_.fin)" }) -join ',') '1-3,7-7,9-10'
$dm = Ncu-DiagCompat @(1,2,3)
Check 'via NCU t1 salud' $dm[1].Salud 'OK'
Check 'via NCU t1 modo' $dm[1].Modo 'AUTO'
Check 'via NCU t1 tilt' $dm[1].Tilt '-55'
Check 'via NCU t1 soc/soh' "$($dm[1].SoC)/$($dm[1].SoH)" '90/100'
Check 'via NCU t1 vbat' $dm[1].Vbat_mV 26600
Check 'via NCU t2 offline (lastComm 0)' $dm[2].Salud 'OFFLINE'
Check 'via NCU t3 alarma eje' (($dm[3].Salud -eq 'ALARMA') -and ($dm[3].Alarmas -like '*eje*')) 'True'
Check 'via NCU t3 modo manual' $dm[3].Modo 'MANUAL'
$hsus = @(Ncu-HsuCompat)
Check 'via NCU 1 HSU detectada' ($hsus.Count) 1
Check 'via NCU HSU aviso viento' (($hsus[0].Salud -eq 'AVISO') -and ($hsus[0].Alarmas -like '*ALARMA VIENTO*')) 'True'
Check 'via NCU HSU viento en texto' ($hsus[0].Alarmas -like '*12.5 m/s (nivel 2)*') 'True'
Check 'via NCU HSU etiqueta' ($hsus[0].TCU) 'HSU1'

# ---------- v3.0: rangos del mapa, desglose de alarmas, guardia de viento ----------
try { $null = Valor-A-Escritura $VARIABLES['40008 jeita_T1 [K]'] '100'; Check 'rango mapa jeita bajo lanza' 'no-lanzo' 'lanza' }
catch { Check 'rango mapa jeita bajo lanza' ("$_" -like '*minimo del mapa*') 'True' }
try { $null = Valor-A-Escritura $VARIABLES['41093 duty_max_manual (b.alto)'] '251'; Check 'rango mapa duty lanza' 'no-lanzo' 'lanza' }
catch { Check 'rango mapa duty lanza' ("$_" -like '*maximo del mapa*') 'True' }
$e = Valor-A-Escritura $VARIABLES['40008 jeita_T1 [K]'] '273'
Check 'rango mapa valor valido' ($e.palabras[0]) 273
$des = Alarmas-Desglose '0x0110' '0x0100'
Check 'desglose al1 seta' $des['al1_seta'] 1
Check 'desglose al1 xbee' $des['al1_xbee'] 1
Check 'desglose al1 rango 0' $des['al1_tilt_rango'] 0
Check 'desglose al2 eje' $des['al2_eje_bloq'] 1
$desV = Alarmas-Desglose '' ''
Check 'desglose vacio' ("$($desV['al1_seta'])") ''
Modbus-Cerrar
$vg = Viento-Seguro '127.0.0.1' 3000 15020
Check 'guardia viento nivel' $vg.nivel 2
Check 'guardia viento alarma' $vg.alarma 'True'
Modbus-Conectar '127.0.0.1' 15020 3000

# ---------- identidad ----------
$campos = Ident-Leer 5
$h = @{}
foreach ($c in $campos) { $h[$c.Campo] = $c.Valor }
Check 'ident fw' $h['FW principal'] 'v1.4.3 (map 7)'
Check 'ident serie' $h['Numero de serie'] 'SN2024FACTIUN00042'
Check 'ident mac' $h['MAC Xbee'] '00AABBBB12345678'
Check 'ident fw fabrica' $h['FW de fabrica'] 'v2.0.1 (map 5)'
Check 'ident fecha fab (dd/mm/aaaa)' $h['Fecha de fabricacion'] '15/08/2024'

Modbus-Cerrar

# ---------- rollback previo a escritura masiva ----------
$paresRb = @(
    @{tcu=5; nombre='40038 corriente_carga_nominal [mA]'},
    @{tcu=6; nombre='40038 corriente_carga_nominal [mA]'},
    @{tcu=7; nombre='40038 corriente_carga_nominal [mA]'}   # unit 7 = error gateway
)
$cxRb = @{ip='127.0.0.1'; puerto=15020; gws=$null; multi=$null; etiqueta='15020'; to=3000; reint=1}
$rb = Rollback-Crear $paresRb $cxRb
Check 'rollback filas' $rb.filas 2
Check 'rollback errores' $rb.errores 1
Check 'rollback fichero existe' (Test-Path $rb.fichero) 'True'
$lineasRb = Get-Content $rb.fichero
Check 'rollback cabecera' $lineasRb[0] 'TCU;variable;valor'
Check 'rollback valor tcu5' ($lineasRb -like '5;40038*').Count 1
# el fichero debe ser directamente restaurable con Parse-CsvPorTcu
$resRb = Parse-CsvPorTcu $lineasRb
Check 'rollback restaurable' (@($resRb.jobs).Count) 2
Check 'rollback sin errores parse' (@($resRb.errores).Count) 0
try { $null = Rollback-Crear @(@{tcu=7; nombre='40038 corriente_carga_nominal [mA]'}) $cxRb; Check 'rollback vacio lanza' 'no-lanzo' 'lanza' }
catch { Check 'rollback vacio lanza' 'lanza' 'lanza' }

# ---------- registros [hex]: se muestran en hex y se escriben en ambas notaciones ----------
Check 'tipo u16hex en tracker_options' $VARIABLES['41018 tracker_options [hex]'].tipo 'u16hex'
Check 'tipo u16hex en safe_pos_options' $VARIABLES['41068 safe_pos_options [hex]'].tipo 'u16hex'
$eh = Valor-A-Escritura $VARIABLES['41068 safe_pos_options [hex]'] '0x0A00'
Check 'u16hex escribe desde hex' ($eh.palabras[0]) 2560
$eh2 = Valor-A-Escritura $VARIABLES['41068 safe_pos_options [hex]'] '2560'
Check 'u16hex escribe desde decimal' ($eh2.palabras[0]) 2560
try { $null = Valor-A-Escritura $VARIABLES['41068 safe_pos_options [hex]'] '70000'; Check 'u16hex rango' 'no-lanzo' 'lanza' }
catch { Check 'u16hex rango' 'lanza' 'lanza' }
# los angulos siguen en grados y las distancias sin convertir
Check 'tilt oeste es angulo' $VARIABLES['41111 max_tilt_west_r1 [deg]'].tipo 'f32deg'
Check 'tilt este es angulo' $VARIABLES['41125 min_tilt_east_r1 [deg]'].tipo 'f32deg'
Check 'east_pitch es distancia' $VARIABLES['41106 east_pitch [m]'].tipo 'f32'
Check 'west_pitch es distancia' $VARIABLES['41033 west_pitch [m]'].tipo 'f32'
$ed = Valor-A-Escritura $VARIABLES['41125 min_tilt_east_r1 [deg]'] '-35'
Check 'grados -> radianes al escribir' ([math]::Round((Palabras-A-F32 $ed.palabras), 4)) ([math]::Round(-35 * [math]::PI / 180, 4))
$em = Valor-A-Escritura $VARIABLES['41106 east_pitch [m]'] '6'
Check 'metros sin convertir' ([math]::Round((Palabras-A-F32 $em.palabras), 3)) 6

# ---------- plan de campana de firmware ----------
$invFw = @(
  [pscustomobject]@{NCU='1'; TCU=1; FW='v1.4.3 (map 1)'; Nota='OK'},
  [pscustomobject]@{NCU='1'; TCU=2; FW='v1.4.3 (map 1)'; Nota='OK'},
  [pscustomobject]@{NCU='1'; TCU=3; FW='v1.6.0 (map 1)'; Nota='OK'},
  [pscustomobject]@{NCU='1'; TCU=4; FW='v1.4.3 (map 1)'; Nota='OK'},
  [pscustomobject]@{NCU='1'; TCU=60; FW='v1.4.3 (map 1)'; Nota='OK'},
  [pscustomobject]@{NCU='1'; TCU=61; FW=''; Nota='sin respuesta'},
  [pscustomobject]@{NCU='2'; TCU=1; FW='v1.5.0 (map 1)'; Nota='OK'}
)
$gwsFw = @{'1' = @(@{puerto=503; ini=1; fin=56}, @{puerto=504; ini=57; fin=108}); '2' = @(@{puerto=503; ini=1; fin=45})}
$pf = Plan-Firmware $invFw 'v1.6.0' $gwsFw
Check 'plan pendientes' $pf.pendientes 5   # 1,2,4,60 de NCU1 + la de NCU2 (v1.5.0)
Check 'plan al dia' $pf.al_dia 1
Check 'plan sin respuesta' (@($pf.sin_respuesta).Count) 1
Check 'plan tramos' (@($pf.tramos).Count) 4   # NCU1/503: 1-2 y 4-4 | NCU1/504: 60 | NCU2/503: 1
$t1 = @($pf.tramos)[0]
Check 'plan tramo1 ncu/gw' "$($t1.NCU)/$($t1.Puerto)" '1/503'
Check 'plan tramo1 rango' "$($t1.Desde)-$($t1.Hasta)" '1-2'
Check 'plan tramo1 tcus' $t1.TCUs 2
$t2 = @($pf.tramos)[1]
Check 'plan tramo2 (TCU 4 aparte)' "$($t2.Desde)-$($t2.Hasta)" '4-4'
$t3 = @($pf.tramos)[2]
Check 'plan tramo3 gw504' "$($t3.NCU)/$($t3.Puerto)/$($t3.Desde)" '1/504/60'
Check 'plan incluye ncu2 (v1.5.0)' (@($pf.tramos | Where-Object { $_.NCU -eq '2' }).Count) 1
try { $null = Plan-Firmware $invFw '' $gwsFw; Check 'plan sin objetivo lanza' 'no-lanzo' 'lanza' }
catch { Check 'plan sin objetivo lanza' 'lanza' 'lanza' }

# ---------- TEST COMM (solo lastComm via NCU) ----------
Modbus-Conectar '127.0.0.1' 15020 3000
$cm = Ncu-Comm @(1,2,3)
Check 'comm t1 comunica' $cm.tcus[1].comunica 'True'
Check 'comm t1 edad 30s' $cm.tcus[1].edad 30
Check 'comm t2 nunca leido' $cm.tcus[2].comunica 'False'
Check 'comm t2 lastcomm 0' $cm.tcus[2].lastcomm 0
Check 'comm t3 comunica' $cm.tcus[3].comunica 'True'
Check 'comm hsus n' (@($cm.hsus).Count) 1
Check 'comm hsu1 comunica' $cm.hsus[0].comunica 'True'
Check 'comm hsu1 etiqueta' $cm.hsus[0].hsu 'HSU1'
Check 'comm reloj ncu' $cm.reloj 1785916800
# el test comm debe pedir muchas menos lecturas que el diagnostico completo
$script:NLect = 0
$origFC03 = ${function:FC03-Leer}
function FC03-Leer { param($u,$a,$n) $script:NLect++; & $origFC03 $u $a $n }
$script:NLect = 0; $null = Ncu-Comm @(1..75);        $lecComm = $script:NLect
$script:NLect = 0; $null = Ncu-DiagCompat @(1..75);  $lecDiag = $script:NLect
${function:FC03-Leer} = $origFC03
# NCU de 75 TCUs: comm = reloj + 2 lastComm + HSUs = 4; diag = reloj + 2 + 15 = 18
Check 'comm lecturas (75 TCUs)' $lecComm 4
Check 'diag lecturas (75 TCUs)' $lecDiag 18
Check 'comm 4x mas rapido' (($lecDiag / $lecComm) -ge 4) 'True'
Modbus-Cerrar

# ---------- trabajos por planta (Diagnostico y Flota) ----------
$cxM = @{ip='NA'; puerto=$null; gws=$null; etiqueta='PLANTA'; to=3000; reint=1; multi=@(
    @{ncu=1; ip='10.0.0.1'; gws=@(@{puerto=503; ini=1; fin=3}, @{puerto=504; ini=4; fin=5})},
    @{ncu=2; ip='10.0.0.2'; gws=@(@{puerto=503; ini=1; fin=2})}
)}
$tj = @(Trabajos-Planta $cxM $null)
Check 'trabajos planta n' $tj.Count 2
Check 'trabajos planta tcus ncu1' (@($tj[0].tcus) -join ',') '1,2,3,4,5'
Check 'trabajos planta ip ncu2' $tj[1].ip '10.0.0.2'
Check 'trabajos planta cx auto' $tj[0].cx.etiqueta 'auto'
Check 'trabajos planta cx gws' (@($tj[0].cx.gws).Count) 2
$tjF = @(Trabajos-Planta $cxM $null '2')
Check 'trabajos filtro n' $tjF.Count 1
Check 'trabajos filtro ncu' $tjF[0].ncu 2
$tjN = @(Trabajos-Planta @{ip='1.2.3.4'; puerto=503; gws=$null; multi=$null; etiqueta='503'; to=3000; reint=1} @(7,8))
Check 'trabajos normal n' $tjN.Count 1
Check 'trabajos normal ncu nulo' ($null -eq $tjN[0].ncu) 'True'
Check 'trabajos normal tcus' (@($tjN[0].tcus) -join ',') '7,8'

# ---------- seguimiento PEM ----------
$script:SegComis = @{'|5'=@{ncu=''; tcu=5; estado='OK'; obs='0 - COMISIONADO'}; '|6'=@{ncu=''; tcu=6; estado=''; obs='2 - TCU configurado'}}
$script:SegAud   = @{'|5'=@{ncu=''; tcu=5; estado='NOK'; obs="2 desviaciones vs 'ref'"}; '|7'=@{ncu=''; tcu=7; estado='OK'; obs=''}}
$script:SegMotor = @{'|5'=@{ncu=''; tcu=5; estado='OK'; obs='PASA: dOeste=3.2'}}
$sg = @(Seguimiento-Filas)
Check 'seguimiento n filas' $sg.Count 3
$s5 = $sg | Where-Object { $_.tcu -eq 5 }
Check 'seg t5 cold' $s5.cold_commissioning 'OK'
Check 'seg t5 config' $s5.config_tcu 'NOK'
Check 'seg t5 motor' $s5.prueba_movimiento 'OK'
Check 'seg t5 obs' $s5.observaciones "config: 2 desviaciones vs 'ref'"
$s6 = $sg | Where-Object { $_.tcu -eq 6 }
Check 'seg t6 cold pendiente' $s6.cold_commissioning ''
Check 'seg t6 obs comis' $s6.observaciones 'comisionado: 2 - TCU configurado'
$s7 = $sg | Where-Object { $_.tcu -eq 7 }
Check 'seg t7 solo aud' ("$($s7.cold_commissioning)/$($s7.config_tcu)/$($s7.prueba_movimiento)") '/OK/'
$script:SegComis = @{}; $script:SegAud = @{}; $script:SegMotor = @{}
Check 'seguimiento vacio' (@(Seguimiento-Filas).Count) 0

# ---------- informe HTML ----------
$mInf = @{
    planta='El Burgo I'; ip='10.100.1.52'; fecha='2026-08-05 10:00'; usuario='tecnico'
    version=$VERSION_TOOLBOX; mapa=$VERSION_MAPA
    diag=@([pscustomobject]@{NCU='1'; TCU=1; Salud='OK'; Modo='AUTO'; Tilt=-55; Objetivo=-55; Dif=0; SoC=90; Alarmas=''},
           [pscustomobject]@{NCU='1'; TCU=2; Salud='ALARMA'; Modo='OFF'; Tilt=0; Objetivo=0; Dif=0; SoC=5; Alarmas='<bateria> & critica'})
    pem=@([pscustomobject]@{TCU=1; Resultado='PASA'; Detalle='motor OK'})
    aud=@(); inv=@()
}
$html = Informe-Html $mInf
Check 'informe es html' ($html -like '<!doctype html>*') 'True'
Check 'informe titulo planta' ($html -like '*Informe de puesta en marcha*El Burgo I*') 'True'
Check 'informe escapa html' ($html -like '*&lt;bateria&gt; &amp; critica*') 'True'
Check 'informe sin tag crudo' ($html -like '*<bateria>*') 'False'
Check 'informe fila alarma' ($html -like '*<tr class="alarma">*') 'True'
Check 'informe fila ok' ($html -like '*<tr class="ok">*') 'True'
Check 'informe seccion pem' ($html -like '*Puesta en marcha (PEM)*') 'True'
Check 'informe resumen grupos' ($html -like '*1 OK | 1 ALARMA*' -or $html -like '*1 ALARMA | 1 OK*') 'True'
Check 'informe tabla filtrable' ($html -like '*<table class="filtrable"><thead>*') 'True'
Check 'informe tbody' ($html -like '*</tbody></table>*') 'True'
Check 'informe js filtros' ($html -like '*tr.filtros*' -and $html -like '*function preparar(tb)*') 'True'
# el JS del informe debe funcionar en navegadores viejos: nada de NodeList.forEach ni arrow
Check 'informe js sin nodelist.forEach' ($html -like '*querySelectorAll*forEach*') 'False'
Check 'informe js con flechas orden' ($html -like '*&#9650;*' -and $html -like '*&#9660;*') 'True'
Check 'informe filtros multiopcion' ($html.Contains('function multi(celda, lista)')) 'True'
Check 'informe filtros sin select unico' ($html.Contains('new Option(')) 'False'
Check 'informe css del panel' ($html.Contains('.fmp{position:absolute')) 'True'
$mVacio = @{planta='X'; ip=''; fecha=''; usuario=''; version='3.1'; mapa='m'; diag=@(); pem=@(); aud=@(); inv=@()}
Check 'informe vacio aviso' ((Informe-Html $mVacio) -like '*Sin datos en esta sesion*') 'True'
Check 'html-esc' (Html-Esc 'a<b>&c') 'a&lt;b&gt;&amp;c'

# ---------- el informe incluye la lectura de variables y su resumen ----------
$lectInf = @(
  [pscustomobject][ordered]@{NCU='16'; TCU=1; '41106 east_pitch [m]'='9'; '41125 min_tilt_east_r1 [deg]'='-45'; Estado='OK'},
  [pscustomobject][ordered]@{NCU='16'; TCU=2; '41106 east_pitch [m]'='9'; '41125 min_tilt_east_r1 [deg]'='-45'; Estado='OK'},
  [pscustomobject][ordered]@{NCU='16'; TCU=3; '41106 east_pitch [m]'='6'; '41125 min_tilt_east_r1 [deg]'='30';  Estado='OK'}
)
$hInf = Informe-Html @{planta='X'; ip=''; fecha=''; usuario=''; version='4.8'; mapa='m'
                       diag=@(); pem=@(); aud=@(); inv=@(); lectura=$lectInf; horas=@{lectura='21:10'}}
Check 'informe seccion lectura' ($hInf -like '*Lectura de variables*') 'True'
Check 'informe hora de la lectura' ($hInf -like '*(21:10)*') 'True'
# los corchetes del nombre no deben tratarse como comodines al agrupar
# (ojo: aqui tampoco se puede usar -like, [m] y [deg] serian comodines)
Check 'informe discrepancia pitch' ($hInf.Contains('east_pitch [m]: 2 valores distintos &rarr; 9 en 2 TCUs &middot; 6 en 1 TCUs')) 'True'
Check 'informe discrepancia tilt' ($hInf.Contains('min_tilt_east_r1 [deg]: 2 valores distintos')) 'True'
Check 'informe filas de lectura' ([regex]::Matches($hInf, '<td>16</td>').Count) 3
$hVacio2 = Informe-Html @{planta='X'; ip=''; fecha=''; usuario=''; version='4.8'; mapa='m'; diag=@(); pem=@(); aud=@(); inv=@(); lectura=@()}
Check 'informe vacio con lectura vacia' ($hVacio2 -like '*Sin datos en esta sesion*') 'True'

# ---------- resincronizacion tras un fallo (unit 77 del simulador) ----------
# La NCU falla una vez y luego va una respuesta por detras, sellandola con el
# TID de la peticion en curso. Sin resincronizar, cada variable saldria con el
# valor de la anterior (el fallo de campo de la v4.9).
Modbus-Conectar '127.0.0.1' 15020 3000
$varsD = @('41111 max_tilt_west_r1 [deg]', '41106 east_pitch [m]', '41125 min_tilt_east_r1 [deg]')
$leidos = @()
foreach ($nv in $varsD) {
    $v = $null
    for ($i = 1; $i -le 3 -and $null -eq $v; $i++) {
        try { $v = Leer-Decodificado 77 $VARIABLES[$nv] } catch {}
    }
    $leidos += "$v"
}
Modbus-Cerrar
Check 'desfase max_tilt correcto'  $leidos[0] '55'
Check 'desfase east_pitch correcto' $leidos[1] '6'
Check 'desfase min_tilt correcto'  $leidos[2] '30'
# y lo que delataba el fallo: east_pitch NO puede traer los radianes de max_tilt
Check 'desfase east_pitch no son radianes' ($leidos[1] -eq '0.95993') 'False'

# una respuesta con otro numero de registros tiene que rechazarse
$origTr = ${function:Modbus-Transaccion}
function Modbus-Transaccion { param($u, $p) return ([byte[]](3, 8, 0,1, 0,2, 0,3, 0,4)) }
$script:Sucio = $false
try { $null = FC03-Leer 5 30111 2; Check 'desfase longitud rechazada' 'no-lanzo' 'lanza' }
catch { Check 'desfase longitud rechazada' 'lanza' 'lanza' }
Check 'desfase marca socket sucio' $script:Sucio 'True'
${function:Modbus-Transaccion} = $origTr

# ---------- seleccion de variables de la pestana Leer (tabla como Escribir) ----------
$nomsL = @(Nombres-Legibles)
Check 'leer nombres incluye variable' ($nomsL -contains '41111 max_tilt_west_r1 [deg]') 'True'
Check 'leer nombres incluye estado'   ($nomsL -contains 'ESTADO 30001 main_status [hex]') 'True'
Check 'leer nombres = vars + estados' $nomsL.Count ($VARIABLES.Count + $ESTADO.Count)
Check 'info variable f32deg' (Info-Lectura '41111 max_tilt_west_r1 [deg]') 'reg 41111  tipo f32deg'
Check 'info registro de estado' (Info-Lectura 'ESTADO 30001 main_status [hex]') 'reg 30001  tipo u16hex'
Check 'info nombre desconocido' (Info-Lectura 'no existe') ''
Check 'info bit' (Info-Lectura '40037 jeita_enable (bit 0)') 'reg 40037  bit 0'
# los corchetes del nombre no pueden tratarse como comodines al buscarlo
Check 'info nombre con corchetes' (Info-Lectura '41106 east_pitch [m]') 'reg 41106  tipo f32'

# ---------- lectura de varias HSUs de una pasada ----------
function Chequear-Cancelado { return $false }
$cxH = @{ip='127.0.0.1'; puerto=15020; gws=$null; multi=$null; etiqueta='15020'; to=2000; reint=1}
$objsH = @(
  @{etiqueta='NCU1 - HSU1'; ip='127.0.0.1'; puerto=15020; unit=185}
  @{etiqueta='NCU2 - HSU1'; ip='127.0.0.1'; puerto=15020; unit=185}
  @{etiqueta='NCU9 - HSU9'; ip='127.0.0.1'; puerto=15020; unit=7}   # 7 = GatewayTargetNoResponse
)
$rH = Hsu-Recorrer $objsH $cxH { param($u) Hsu-LeerMeteo $u } $null
Check 'hsus: responden 2 de 3' (@($rH.oks).Count) 2
Check 'hsus: cabecera por HSU' (@($rH.filas | Where-Object { "$($_.Campo)" -like '--- NCU*' }).Count) 3
Check 'hsus: la muda deja fila' (@($rH.filas | Where-Object { "$($_.Valor)" -eq 'sin respuesta' }).Count) 1
Check 'hsus: viento de la primera' (@($rH.filas | Where-Object { "$($_.Campo)" -like 'Viento*' }).Count -ge 2) 'True'
# una sola HSU no mete cabeceras
$rH1 = Hsu-Recorrer @($objsH[0]) $cxH { param($u) Hsu-LeerMeteo $u } $null
Check 'hsu unica sin cabecera' (@($rH1.filas | Where-Object { "$($_.Campo)" -like '--- *' }).Count) 0

# ---------- el informe empieza por lo ultimo que se hizo ----------
# El caso real: haces un inventario despues de un diagnostico, pides el informe
# y arriba sale el diagnostico, asi que parece que ha ignorado el inventario.
$dg = @([pscustomobject]@{NCU='1'; TCU=1; Salud='OK'; Modo='AUTO'; Tilt='0'; Objetivo='0'; Dif='0'; SoC='90'; Alarmas=''})
$iv = @([pscustomobject]@{NCU='1'; TCU=1; Serie='SN1'; MAC='AA'; FW='v1.6.0'; FW_fabrica='v1.4.3'; HW='6'; Fecha_fab='18/06/2025'; Nota='OK'})
$base = @{planta='X'; ip=''; fecha=''; usuario=''; version='5.6'; mapa='m'; pem=@(); aud=@(); lectura=@()}
$hOrd = Informe-Html ($base + @{diag=$dg; inv=$iv; horas=@{diag='10:00'; inv='11:00'}; orden=@{diag=1; inv=2}})
Check 'informe: inventario antes que diagnostico' ($hOrd.IndexOf('Inventario de flota') -lt $hOrd.IndexOf('Diagnostico de flota')) 'True'
$hOrd2 = Informe-Html ($base + @{diag=$dg; inv=$iv; horas=@{diag='11:00'; inv='10:00'}; orden=@{diag=2; inv=1}})
Check 'informe: al reves si el diag es posterior' ($hOrd2.IndexOf('Diagnostico de flota') -lt $hOrd2.IndexOf('Inventario de flota')) 'True'
Check 'informe: indice de secciones' ($hOrd.Contains('En esta sesion:') -and $hOrd.Contains('href="#s-inv"')) 'True'
Check 'informe: ancla en el titulo' ($hOrd.Contains('id="s-inv"')) 'True'
$hUna = Informe-Html ($base + @{diag=$dg; inv=@(); horas=@{diag='10:00'}; orden=@{diag=1}})
Check 'informe: sin indice con una sola seccion' ($hUna.Contains('En esta sesion:')) 'False'
# informes de versiones viejas, sin marca de orden: no deben romperse
$hSin = Informe-Html ($base + @{diag=$dg; inv=$iv})
Check 'informe: sin orden sigue saliendo' ($hSin.Contains('Inventario de flota') -and $hSin.Contains('Diagnostico de flota')) 'True'

# ---------- anclajes: lo que va debajo de la tabla no puede quedar tapado ----------
# Geometria real de la pestana Escribir: la tabla ocupa 55..283 y el boton
# ESCRIBIR esta en 292. Al maximizar, la tabla crece hacia abajo; si el boton
# sigue anclado arriba, la tabla se lo come y no hay forma de escribir.
$anchoRef = 901
$gTabla  = @{tipo='tabla'; top=55; left=10; ancho=898; alto=228; anchoRef=$anchoRef; crece=$true; abajoTabla=283}
$gBoton  = @{tipo='boton'; top=292; left=180; ancho=120; alto=30; anchoRef=$anchoRef; crece=$false; abajoTabla=283}
$gChk    = @{tipo='otro'; top=296; left=10; ancho=160; alto=22; anchoRef=$anchoRef; crece=$false; abajoTabla=283}
$gNvm    = @{tipo='boton'; top=292; left=760; ancho=148; alto=30; anchoRef=$anchoRef; crece=$false; abajoTabla=283}
$gPreset = @{tipo='boton'; top=18; left=766; ancho=140; alto=28; anchoRef=$anchoRef; crece=$false; abajoTabla=283}
Check 'ancla tabla que crece'        (Anclaje-Para $gTabla)  'Top,Left,Right,Bottom'
Check 'ancla ESCRIBIR baja'          (Anclaje-Para $gBoton)  'Bottom,Left'
Check 'ancla casilla baja'           (Anclaje-Para $gChk)    'Bottom,Left'
Check 'ancla NVM baja y a la derecha' (Anclaje-Para $gNvm)   'Bottom,Right'
Check 'ancla boton de arriba a la derecha' (Anclaje-Para $gPreset) 'Top,Right'
# tabla que NO es la mas baja (Leer variable: la de eleccion arriba)
$gTabla2 = @{tipo='tabla'; top=55; left=10; ancho=898; alto=118; anchoRef=$anchoRef; crece=$false; abajoTabla=360}
Check 'ancla tabla de arriba no crece' (Anclaje-Para $gTabla2) 'Top,Left,Right'
# etiqueta larga por debajo de la tabla
$gEtiq = @{tipo='etiqueta'; top=300; left=10; ancho=600; alto=20; anchoRef=$anchoRef; crece=$false; abajoTabla=283}
Check 'ancla nota larga baja y estira' (Anclaje-Para $gEtiq) 'Bottom,Left,Right'
# Una etiqueta larga CON algo a su derecha no puede estirarse: al maximizar se
# le echa encima. Geometria real de Diagnostico: la nota del registrador
# (328,57) mide 330 y TEST COMM esta en (668,51) en la misma fila.
$gNota = @{tipo='etiqueta'; top=57; left=328; ancho=330; alto=20; anchoRef=$anchoRef; crece=$false; abajoTabla=360; vecinoDerecha=$true}
Check 'nota larga con vecino no estira' (Anclaje-Para $gNota) ''
$gNotaSola = @{tipo='etiqueta'; top=57; left=328; ancho=330; alto=20; anchoRef=$anchoRef; crece=$false; abajoTabla=360; vecinoDerecha=$false}
Check 'nota larga sin vecino si estira' (Anclaje-Para $gNotaSola) 'Top,Left,Right'
$gEtiqV = @{tipo='etiqueta'; top=300; left=10; ancho=600; alto=20; anchoRef=$anchoRef; crece=$false; abajoTabla=283; vecinoDerecha=$true}
Check 'nota baja con vecino solo baja' (Anclaje-Para $gEtiqV) 'Bottom,Left'
# sin tablas en el contenedor, nada cambia
$gSin = @{tipo='boton'; top=292; left=180; ancho=120; alto=30; anchoRef=$anchoRef; crece=$false; abajoTabla=-1}
Check 'sin tabla, boton sin anclaje' (Anclaje-Para $gSin) ''

# ---------- la consola dice de que NCU es cada TCU ----------
# En Planta completa los numeros de TCU se repiten en cada NCU: sin la NCU
# delante, una linea de log no dice de que equipo habla.
$script:NcuLog = ''
Check 'eti sin ncu' (Eti-Tcu 7) 'TCU   7'
$script:NcuLog = '2'
Check 'eti con ncu' (Eti-Tcu 7) 'NCU2   TCU   7'
$script:NcuLog = '13'
Check 'eti ncu de dos cifras' (Eti-Tcu 105) 'NCU13  TCU 105'
$script:NcuLog = ''

# ---------- la escritura entra en el informe ----------
# Escribes una variable en toda la planta, pides el informe y sale "Sin datos
# en esta sesion": el informe nunca habia recogido las escrituras, que es
# justo lo que hay que documentar de una jornada de puesta en marcha.
$esc = @(
  [pscustomobject]@{NCU='2'; TCU=1; Variable='41111 max_tilt_west_r1 [deg]'; Antes='45'; Despues='55'; Estado='OK'}
  [pscustomobject]@{NCU='2'; TCU=6; Variable='41111 max_tilt_west_r1 [deg]'; Antes='55'; Despues='55'; Estado='FALLO: Respuesta descolocada'}
)
$baseE = @{planta='X'; ip=''; fecha=''; usuario=''; version='5.9'; mapa='m'; diag=@(); pem=@(); aud=@(); inv=@(); lectura=@()}
$hEsc = Informe-Html ($baseE + @{esc=$esc; horas=@{esc='23:42'}; orden=@{esc=1}})
Check 'informe seccion escritura' ($hEsc.Contains('Escritura de variables')) 'True'
Check 'informe escritura hora' ($hEsc.Contains('(23:42)')) 'True'
Check 'informe escritura antes/despues' ($hEsc.Contains('<td>45</td>') -and $hEsc.Contains('<td>55</td>')) 'True'
Check 'informe escritura fallo en rojo' ($hEsc.Contains('class="alarma"')) 'True'
Check 'informe escritura resumen' ($hEsc.Contains('1 OK')) 'True'
Check 'informe escritura no dice sin datos' ($hEsc.Contains('Sin datos en esta sesion')) 'False'
# y sigue avisando cuando de verdad no hay nada
$hNada = Informe-Html ($baseE + @{esc=@()})
Check 'informe sin nada avisa de la escritura' ($hNada.Contains('ejecuta una Escritura')) 'True'
# la escritura se ordena con el resto por lo ultimo que se hizo
$mixBase = @{planta='X'; ip=''; fecha=''; usuario=''; version='5.9'; mapa='m'; diag=@(); pem=@(); aud=@(); lectura=@()}
$hMix = Informe-Html ($mixBase + @{esc=$esc; inv=@([pscustomobject]@{NCU='1'; TCU=1; Serie='S'; MAC='M'; FW='v1'; FW_fabrica='v0'; HW='6'; Fecha_fab='18/06/2025'; Nota='OK'})
                                   horas=@{esc='23:42'; inv='22:00'}; orden=@{inv=1; esc=2}})
Check 'informe escritura antes que inventario' ($hMix.IndexOf('Escritura de variables') -lt $hMix.IndexOf('Inventario de flota')) 'True'

# ---------- auditoria de maqueta: nada puede solaparse al agrandar ----------
# Cierra la familia de fallos de esta tanda: en vez de esperar a que se vea un
# boton tapado, se comprueba la geometria de todas las pestanas.
$salidaMaq = & (Join-Path $PSScriptRoot 'maqueta.ps1')
Check 'maqueta sin solapes' (($salidaMaq -join ' ') -like '*SIN SOLAPES*') 'True'
Check 'maqueta analiza el script entero' (($salidaMaq -join ' ') -match 'controles analizados: (\d+)' -and [int]$matches[1] -gt 150) 'True'

# ---------- listas que el llamante despliega con @() ----------
# El fallo de la v5.2/v5.3: devolver ",$arrayList" hace que el "@(...)" de quien
# llama se quede con UN elemento. Las tres variables de la lectura llegaban
# pegadas en una sola cadena ("no responde: tipo desconocido") y las HSUs igual
# ("Leyendo meteo de 1 HSU(s)" con todas las etiquetas juntas).
$tres = @('41111 max_tilt_west_r1 [deg]', '41125 min_tilt_east_r1 [deg]', '41106 east_pitch [m]')
$nom = @(Nombres-Unicos $tres)
Check 'nombres: no se pegan al desplegar' $nom.Count 3
Check 'nombres: el primero es solo el primero' $nom[0] '41111 max_tilt_west_r1 [deg]'
Check 'nombres: una sola sigue siendo una' (@(Nombres-Unicos @('41106 east_pitch [m]'))).Count 1
Check 'nombres: sin repetidos' (@(Nombres-Unicos @('a','b','a'))).Count 2
Check 'nombres: se ignoran los vacios' (@(Nombres-Unicos @('a','',$null,'b'))).Count 2
# y la cadena completa: cada nombre tiene que resolver a su definicion
$defsL = @($nom | ForEach-Object { @{nombre=[string]$_; vdef=(Def-DeLectura $_)} })
Check 'cada variable resuelve su tipo' (@($defsL | Where-Object { $_.vdef }).Count) 3
Check 'tipo de la primera' ($defsL[0].vdef.tipo) 'f32deg'

# Guarda estatica: ninguna funcion que devuelva ",\$algo" puede consumirse con
# @(), porque no se despliega. Es lo que se me escapo dos veces.
$conComa = @()
foreach ($fn in $arbol.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($fn.Body.Extent.Text -match 'return\s*,\s*\$') { $conComa += $fn.Name }
}
$malUsadas = @()
foreach ($fn in $conComa) {
    if ($src -match ('@\(\s*' + [regex]::Escape($fn) + '[\s\)]')) { $malUsadas += $fn }
}
Check 'ninguna lista con coma se consume con @()' ($malUsadas -join ',') ''

Write-Host ''
if ($fallos -eq 0) { Write-Host 'TODAS LAS PRUEBAS OK'; exit 0 }
else { Write-Host "$fallos PRUEBAS FALLIDAS"; exit 1 }
