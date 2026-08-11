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
# anadir las funciones definidas en la seccion de handlers
# desde el bloque de paralelo hasta identificacion: ahi viven el historial, la
# simulacion de escritura, el parte de WhatsApp, el veredicto de motor y Ident-Leer
$i1 = $src.IndexOf('$script:Cierre = @{}'); $f1 = $src.IndexOf('$btnIdent.Add_Click')
$i2 = $src.IndexOf('function Diag-LeerTcu'); $f2 = $src.IndexOf('$btnDiag.Add_Click')
$i3 = $src.IndexOf('function Params-Conexion'); $f3 = $src.IndexOf('function Refrescar-ComboPlantas')
$i4 = $src.IndexOf('function Nombres-Legibles'); $f4 = $src.IndexOf('function Refrescar-FiltroLeer')
$i5 = $src.IndexOf('$script:HsuPuertoOk = @{}'); $f5 = $src.IndexOf('function Hsu-Mostrar')
$i6 = $src.IndexOf('function Anclaje-Para'); $f6 = $src.IndexOf('# Anclar contra un contenedor')
$i7 = $src.IndexOf('function Eti-Tcu'); $f7 = $src.IndexOf('# Divide una lista de TCUs')
$i8 = $src.IndexOf('function Nombres-Unicos'); $f8 = $src.IndexOf('function Vars-DeTablaLeer')
# el bloque 9 arranca en los umbrales de bateria porque Bat-Auditar los usa
$i9 = $src.IndexOf('$BAT = @{'); $f9 = $src.IndexOf('$btnLeer.Add_Click')
$i10 = $src.IndexOf('function Aband-Cronologia'); $f10 = $src.IndexOf('#  Usuarios, roles y registro')
$i11 = $src.IndexOf('$ROLES = @('); $f11 = $fin   # hasta el arranque de la interfaz
$i12 = $src.IndexOf('function Lv-Pasa'); $f12 = $src.IndexOf('function Lv-Filtrable')
$i16 = $src.IndexOf('function Prog-Texto'); $f16 = $src.IndexOf('$script:ProgTotal = 0;')
$i15 = $src.IndexOf('function Hsu-EsclavoDe'); $f15 = $src.IndexOf('#  Cierre post-actualizacion (interfaz)')
$i13 = $src.IndexOf('function Esclavos-Barrido'); $f13 = $src.IndexOf('function Params-Hsu')
$i14 = $src.IndexOf('function Buscar-Norm'); $f14 = $src.IndexOf('function Buscador-Abrir')
# el modo de una TCU: leerlo antes de escribirlo es lo que evita tocar las que ya estan
$i18 = $src.IndexOf('function Modo-Actual'); $f18 = $src.IndexOf('function Guardia-Viento')
$logica += "`n" + $src.Substring($i18, $f18 - $i18)
$logica += "`n" + $src.Substring($i1, $f1 - $i1) + "`n" + $src.Substring($i2, $f2 - $i2) + "`n" + $src.Substring($i3, $f3 - $i3) + "`n" + $src.Substring($i4, $f4 - $i4) + "`n" + $src.Substring($i5, $f5 - $i5) + "`n" + $src.Substring($i6, $f6 - $i6) + "`n" + $src.Substring($i7, $f7 - $i7) + "`n" + $src.Substring($i8, $f8 - $i8) + "`n" + $src.Substring($i9, $f9 - $i9) + "`n" + $src.Substring($i10, $f10 - $i10) + "`n" + $src.Substring($i11, $f11 - $i11) + "`n" + $src.Substring($i12, $f12 - $i12) + "`n" + $src.Substring($i13, $f13 - $i13) + "`n" + $src.Substring($i14, $f14 - $i14) + "`n" + $src.Substring($i15, $f15 - $i15) + "`n" + $src.Substring($i16, $f16 - $i16)
# los bloques anadidos tambien usan $PSScriptRoot (usuarios.json, registro/)
$logica = $logica.Replace('$PSScriptRoot', '$PSScriptRootFake')
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
# PowerShell no distingue mayusculas en los nombres de variable, asi que un
# $inv, $Inv o $iNv en cualquier sitio pisa $INV (la cultura invariante) y
# rompe el parseo de decimales de todo lo que se llame desde ese ambito. Paso
# de verdad con Portada-Bloques. Se prohibe el nombre entero.
$choques = @{}
foreach ($nom in @($definidas.Keys)) {
    if ($nom -ieq 'INV' -and $nom -cne 'INV') { $choques[$nom] = $true }
}
Check 'sin variables que pisen $INV' (@($choques.Keys | Sort-Object) -join ',') ''

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
# Las entradas de las plantas de verdad tienen que llevar el nombre completo:
# la agrupacion de "(Planta completa)" sale del prefijo "<Planta> NCU<n>", y con
# " NCU2", " NCU3"... salian dos grupos y Ayora se quedaba con 15 de 16 NCUs.
foreach ($fp in @(Get-ChildItem (Join-Path $raizTb 'plantas') -Filter *.json)) {
    $sinNombre = @()
    foreach ($e in (Get-Content $fp.FullName -Raw | ConvertFrom-Json).plantas) {
        if ("$($e.nombre)" -match '^\s' -or "$($e.nombre)" -match '^NCU\d') { $sinNombre += "$($e.nombre)" }
    }
    Check "topologia $($fp.Name): ninguna entrada sin planta" ($sinNombre -join ',') ''
}
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
# ---------- el GW que no existe no puede estar "desconectado" (v11.33) ----------
# El simulador tiene el bit 5 (GW2) puesto. Una NCU de un solo gateway lo tiene
# SIEMPRE puesto: en Ayora eran 15 ALARMAS falsas por barrido, una por NCU,
# tapando las de verdad.
$nsUno = Ncu-Salud @(@{puerto=503; ini=1; fin=44})
Check 'ncu gw: con un solo gateway no hay alarma' $nsUno.salud 'OK'
Check 'ncu gw: y el GW2 no se menciona' (($nsUno.alarmas -join ';') -like '*GW2*') 'False'
$nsDos = Ncu-Salud @(@{puerto=503; ini=1; fin=44}, @{puerto=504; ini=45; fin=90})
Check 'ncu gw: con los dos declarados sigue cantando' $nsDos.salud 'ALARMA'
Check 'ncu gw: y lo dice' (($nsDos.alarmas -join ';') -like '*GW2*') 'True'
# sin topologia no se inventa nada: se comporta como siempre
Check 'ncu gw: sin topologia, como antes' (Ncu-Salud $null).salud 'ALARMA'
Check 'ncu gw: lista vacia tampoco opina' (Ncu-Salud @()).salud 'ALARMA'
# el bit de bateria de la NCU no se toca al enmascarar los gateways
Check 'ncu gw: el enmascarado no borra otras alarmas' (@(Ncu-Salud @(@{puerto=504})).salud) 'ALARMA'
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
# De una TCU que no comunica no se sabe la bateria: su hueco de la cache de la
# NCU esta a ceros, y con eso el plan marcaba "SoC 0 % - BATERIA BAJA" en
# equipos que estan al 100 %.
$diagMuda = @(
  [pscustomobject]@{NCU='1'; TCU=1; Salud='OFFLINE'; SoC=0}
  [pscustomobject]@{NCU='1'; TCU=2; Salud='OK'; SoC=95}
  [pscustomobject]@{NCU='1'; TCU=4; Salud='OK'; SoC=12}
)
$pfM = Plan-Firmware $invFw 'v1.6.0' $gwsFw $diagMuda
$dM = @($pfM.detalle)
Check 'plan: la muda no trae SoC' ((@($dM | Where-Object { $_.TCU -eq 1 })[0]).SoC) ''
Check 'plan: y no cuenta como bateria baja' ((@($dM | Where-Object { $_.TCU -eq 1 })[0]).SoC_bajo) $false
Check 'plan: la que si comunica, con su SoC' ((@($dM | Where-Object { $_.TCU -eq 2 })[0]).SoC) '95'
Check 'plan: y la que esta baja de verdad se marca' ((@($dM | Where-Object { $_.TCU -eq 4 })[0]).SoC_bajo) $true
Check 'plan: solo cuenta una con bateria baja' ($pfM.con_soc_bajo) 1

# ---------- la seleccion de equipos: un cuadro para decir cuales ----------
# "TCU de [1] a [44]" no sabe decir "la 10, la 22 y de la 30 a la 40", ni
# mezclar NCUs. Ahora hay un solo cuadro que lo dice todo.
Check 'sel: vacio = todas' ((Parse-Seleccion '').todas) $true
Check 'sel: NA tambien' ((Parse-Seleccion 'NA').todas) $true
Check 'sel: y la palabra todas' ((Parse-Seleccion 'todas').todas) $true
Check 'sel: el rango de siempre' ((Parse-Seleccion '1-4').lista -join ',') '1,2,3,4'
Check 'sel: una sola' ((Parse-Seleccion '10').lista -join ',') '10'
Check 'sel: lista y tramos' ((Parse-Seleccion '10,22,30-32').lista -join ',') '10,22,30,31,32'
Check 'sel: ordena y quita repetidas' ((Parse-Seleccion '22,10,10').lista -join ',') '10,22'
Check 'sel: aguanta espacios' ((Parse-Seleccion ' 10 , 30 - 32 ').lista -join ',') '10,30,31,32'
Check 'sel: sin prefijo, porNcu vacio' ((Parse-Seleccion '10,22').porNcu.Count) 0
# con la NCU delante: cada tramo va a la suya
$sp = Parse-Seleccion '12/10, 12/22, 15/5-7'
Check 'sel: dos NCUs' ($sp.porNcu.Count) 2
Check 'sel: las de la 12' ($sp.porNcu['12'] -join ',') '10,22'
Check 'sel: las de la 15' ($sp.porNcu['15'] -join ',') '5,6,7'
Check 'sel: y la lista suelta queda vacia' ($sp.lista.Count) 0
Check 'sel: el asterisco es toda la NCU' ((Parse-Seleccion '12/*').porNcu['12'] -join ',') '*'
Check 'sel: el asterisco se come el resto de esa NCU' ((Parse-Seleccion '12/*,12/5').porNcu['12'] -join ',') '*'
# lo que no puede colar
try { $null = Parse-Seleccion '12/10,22'; Check 'sel: mezclar con y sin NCU lanza' 'no-lanzo' 'lanza' }
catch { Check 'sel: mezclar con y sin NCU lanza' 'lanza' 'lanza' }
try { $null = Parse-Seleccion '40-30'; Check 'sel: rango al reves lanza' 'no-lanzo' 'lanza' }
catch { Check 'sel: rango al reves lanza' 'lanza' 'lanza' }
try { $null = Parse-Seleccion '0'; Check 'sel: el 0 lanza' 'no-lanzo' 'lanza' }
catch { Check 'sel: el 0 lanza' 'lanza' 'lanza' }
try { $null = Parse-Seleccion '300'; Check 'sel: fuera de 247 lanza' 'no-lanzo' 'lanza' }
catch { Check 'sel: fuera de 247 lanza' 'lanza' 'lanza' }
try { $null = Parse-Seleccion 'x'; Check 'sel: basura lanza' 'no-lanzo' 'lanza' }
catch { Check 'sel: basura lanza' 'lanza' 'lanza' }
try { $null = Parse-Seleccion '*'; Check 'sel: asterisco suelto lanza' 'no-lanzo' 'lanza' }
catch { Check 'sel: asterisco suelto lanza' 'lanza' 'lanza' }

# el filtro de gateway: "todas las TCUs del GW2" sin saberse el rango
$gwsBurgo = @(@{puerto=503; ini=1; fin=56}, @{puerto=504; ini=57; fin=108})
Check 'gw: vacio deja los dos' ((@(Gws-Filtrados $gwsBurgo '')).Count) 2
Check 'gw: 504 deja uno' ((@(Gws-Filtrados $gwsBurgo '504'))[0].puerto) 504
Check 'gw: uno que no existe deja cero' ((@(Gws-Filtrados $gwsBurgo '505')).Count) 0
Check 'gw: de que gateway cuelga la 30' (Gw-DeTcu $gwsBurgo 30) '503'
Check 'gw: y la 80' (Gw-DeTcu $gwsBurgo 80) '504'
Check 'gw: una que no cae en ninguno' (Gw-DeTcu $gwsBurgo 200) ''
# las TCUs que le tocan a una NCU con esa seleccion y ese gateway
Check 'sel+gw: todas las del 504' ((Sel-TcusDe (Parse-Seleccion '') (Gws-Filtrados $gwsBurgo '504') '1') -join ',') (@(57..108) -join ',')
Check 'sel+gw: la lista recortada al 504' ((Sel-TcusDe (Parse-Seleccion '10,60,70') (Gws-Filtrados $gwsBurgo '504') '1') -join ',') '60,70'
Check 'sel+gw: sin filtro entran las dos' ((Sel-TcusDe (Parse-Seleccion '10,60') $gwsBurgo '1') -join ',') '10,60'
Check 'sel+gw: por NCU, la que toca' ((Sel-TcusDe (Parse-Seleccion '12/10,15/5-6') $gwsBurgo '15') -join ',') '5,6'
Check 'sel+gw: y a la NCU que no sale, nada' ((Sel-TcusDe (Parse-Seleccion '12/10') $gwsBurgo '15').Count) 0
Check 'sel+gw: el asterisco son todas las suyas' ((Sel-TcusDe (Parse-Seleccion '15/*') (Gws-Filtrados $gwsBurgo '503') '15') -join ',') (@(1..56) -join ',')
Check 'sel+gw: una fuera de los gateways se cae' ((Sel-TcusDe (Parse-Seleccion '10,200') $gwsBurgo '1') -join ',') '10'

# ---------- el plan de campana: una VENTANA del updater por NCU+gateway ----------
# Los tramos sueltos no eran un plan: con dos pendientes no consecutivas de la
# misma NCU salian dos filas CARRIL identicas a las dos de TCU. Lo que hace
# falta es "abre estas N ventanas, en cada una pega esto y tarda esto, total X".
$ipsFw = @{'1'='10.0.0.1'; '2'='10.0.0.2'}
$vv = @(Plan-Ventanas $pf.tramos $ipsFw 20)
Check 'ventanas: una por NCU+gateway' ($vv.Count) 3     # 1/503, 1/504, 2/503
Check 'ventanas: la mas cargada va primera' "$($vv[0].NCU)/$($vv[0].Puerto)" '1/503'
Check 'ventanas: y lleva sus TCUs juntas' ($vv[0].TCUs) 3           # 1,2 y 4
Check 'ventanas: con los dos rangos que pegar' ($vv[0].Rangos) '1-2 + 4'
Check 'ventanas: numeradas en orden' ((@($vv | ForEach-Object { $_.Orden }) -join ',')) '1,2,3'
Check 'ventanas: coge la IP de la NCU' ($vv[0].IP) '10.0.0.1'
Check 'ventanas: horas de la ventana' ($vv[0].Horas) 1               # 3 TCUs x 20 min
Check 'ventanas: una TCU sola tambien es ventana' ($vv[1].TCUs) 1
Check 'ventanas: y su rango va sin guion' ($vv[1].Rangos) '60'
Check 'ventanas: sin tramos no revienta' ((@(Plan-Ventanas @() $ipsFw 20)).Count) 0
Check 'ventanas: sin IPs no revienta' ((@(Plan-Ventanas $pf.tramos $null 20))[0].IP) ''
# el reloj de la campana lo marca la ventana mas cargada, no la suma
$txt = @(Plan-Texto $vv 20)
Check 'plan texto: abre 3 ventanas' ($txt[0].Contains('abre 3 ventanas')) $true
Check 'plan texto: y dice las TCUs' ($txt[0].Contains('5 TCUs pendientes')) $true
Check 'plan texto: una linea por ventana' ($txt.Count) 5             # cabecera + 3 + total
Check 'plan texto: con lo que hay que pegar' ($txt[1].Contains('Add from...to: 1-2 + 4')) $true
Check 'plan texto: y su IP y puerto' ($txt[1].Contains('10.0.0.1  puerto 503')) $true
Check 'plan texto: el total es el de la mayor' ($txt[-1].Contains('~1 h con las 3 ventanas')) $true
Check 'plan texto: y dice cuanto seria en serie' ($txt[-1].Contains('~1,7 h')) $true
Check 'plan texto: sin ventanas, sin texto' ((@(Plan-Texto @() 20)).Count) 0
# con una sola ventana no hay nada que comparar, y no debe decir "1 ventanas"
$vUna = @(Plan-Ventanas @([pscustomobject]@{NCU='12'; Puerto='503'; Desde=10; Hasta=10; TCUs=1},
                          [pscustomobject]@{NCU='12'; Puerto='503'; Desde=22; Hasta=22; TCUs=1}) @{'12'='192.168.4.80'} 20)
$tUna = @(Plan-Texto $vUna 20)
Check 'plan texto: en singular' ($tUna[0].Contains('abre 1 ventana del updater')) $true
Check 'plan texto: los dos rangos en la misma ventana' ($tUna[1].Contains('Add from...to: 10 + 22')) $true
# y la ventana y el total no pueden decir tiempos distintos de las mismas TCUs
Check 'plan texto: la ventana dice 40 min' ($tUna[1].Contains('~40 min')) $true
Check 'plan texto: y el total tambien' ($tUna[-1]) 'TOTAL: ~40 min en esa unica ventana.'
# las horas, legibles: minutos si es poco y jornadas si es mucho
Check 'horas: menos de una hora en minutos' (Horas-Texto 0.5) '30 min'
Check 'horas: una hora justa' (Horas-Texto 1) '1 h'
Check 'horas: con decimal y coma' (Horas-Texto 1.7) '1,7 h'
Check 'horas: a partir de 8 h, en jornadas' ((Horas-Texto 15.7).Contains('dias de 8 h')) $true
Check 'horas: y la jornada bien contada' (Horas-Texto 16) '16 h (2 dias de 8 h)'

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
Check 'informe tabla filtrable' ($html -like '*class="filtrable"><thead>*') 'True'
# cada tabla con su id, para poder enlazarla y para que las pruebas de navegador
# no dependan del orden en que salgan las secciones
Check 'informe tabla con id' ($html -like '*<table id="t-diag" class="filtrable"*') 'True'
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

# ---------- la HSU puede colgar del SEGUNDO gateway (v11.32) ----------
# Burgo I: cada NCU lleva una estacion en el GW1 y otra en el GW2. Antes se
# preguntaba siempre por el puerto mas bajo y la del GW2 salia muda. Aqui el
# 15021 no existe, asi que si no probara el segundo puerto no contestaria.
$script:HsuPuertoOk = @{}
$objDoble = @(@{etiqueta='NCU1 - HSU2'; ip='127.0.0.1'; puerto=15021; puertos=@(15021, 15020); unit=185})
$rD = Hsu-Recorrer $objDoble $cxH { param($u) Hsu-LeerMeteo $u } $null
Check 'hsu gw2: contesta por el segundo gateway' (@($rD.oks).Count) 1
Check 'hsu gw2: y se recuerda cual era' (Hsu-PuertoRecordado '127.0.0.1' 185) 15020
# con los dos gateways mudos lo dice, para no mandar a nadie a mirar un cable
$script:HsuPuertoOk = @{}
$objMuda = @(@{etiqueta='NCU9 - HSU9'; ip='127.0.0.1'; puerto=15020; puertos=@(15020, 15021); unit=7})
$rM = Hsu-Recorrer $objMuda $cxH { param($u) Hsu-LeerMeteo $u } $null
Check 'hsu gw2: la muda dice que probo los dos' (@($rM.filas | Where-Object { "$($_.Nota)" -like '*gateways 15020 y 15021*' }).Count) 1
Check 'hsu gw2: y no recuerda ningun puerto' (Hsu-PuertoRecordado '127.0.0.1' 7) 0
# sin lista de puertos sigue valiendo el de siempre
$script:HsuPuertoOk = @{}
$rU = Hsu-Recorrer @(@{etiqueta='NCU1 - HSU1'; ip='127.0.0.1'; puerto=15020; unit=185}) $cxH { param($u) Hsu-LeerMeteo $u } $null
Check 'hsu gw2: sin lista de puertos funciona igual' (@($rU.oks).Count) 1

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

Write-Host ''
Write-Host '== cargar un preset en la lectura =='
# el preset ya dice que variables importan: no hay que teclearlas otra vez
$presetL = @(
    [pscustomobject]@{variable='41111 max_tilt_west_r1 [deg]'; valor='55'}
    [pscustomobject]@{variable='41106 east_pitch [m]';         valor='6'}
)
$rp = Preset-Nombres $presetL
Check 'preset leer: saca los nombres' (@($rp.nombres).Count) 2
Check 'preset leer: en el orden del fichero' ($rp.nombres[0]) '41111 max_tilt_west_r1 [deg]'
Check 'preset leer: y ninguno fuera' (@($rp.fuera).Count) 0
# el otro formato que se guarda: el backup completo de una TCU
$bk = [pscustomobject]@{tipo='backup_tcu'; variables=$presetL}
Check 'preset leer: tambien un backup' (@((Preset-Nombres $bk).nombres).Count) 2
# lo que no esta en el mapa se dice, no se cuela como fila muerta
$rf = Preset-Nombres @(
    [pscustomobject]@{variable='41111 max_tilt_west_r1 [deg]'; valor='55'}
    [pscustomobject]@{variable='99999 inventada'; valor='1'})
Check 'preset leer: la que no existe se aparta' (@($rf.nombres).Count) 1
Check 'preset leer: y se nombra' ($rf.fuera[0]) '99999 inventada'
# repetida en el preset = una sola columna en la lectura
$rr = Preset-Nombres @(
    [pscustomobject]@{variable='41106 east_pitch [m]'; valor='6'}
    [pscustomobject]@{variable='41106 east_pitch [m]'; valor='6'})
Check 'preset leer: no duplica' (@($rr.nombres).Count) 1
Check 'preset leer: preset vacio no revienta' (@((Preset-Nombres @()).nombres).Count) 0
Check 'preset leer: nulo tampoco' (@((Preset-Nombres $null).nombres).Count) 0
# y el boton existe, esta enganchado y se bloquea mientras hay una operacion
Check 'preset leer: hay boton' ($src.Contains("btnLPreset.Text = 'Cargar preset...'")) $true
Check 'preset leer: con handler' ($src.Contains('$btnLPreset.Add_Click')) $true
Check 'preset leer: se bloquea si esta ocupada' ($src.Contains('$btnPresetLoad, $btnLPreset,')) $true
Check 'preset leer: avisa antes de borrar lo puesto' ($src.Contains('Ya hay variables')) $true

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

# ---------- ensayos SAT (Anexo 4) ----------
# D.1.1 precision: solo cuentan las muestras con el objetivo ya estable
$fp = @(
  # objetivo cambiando: las dos primeras no cuentan (aun va de camino)
  [pscustomobject]@{ncu='1'; tcu=1; obj=10.0; desv=6.0}
  [pscustomobject]@{ncu='1'; tcu=1; obj=12.0; desv=4.0}
  [pscustomobject]@{ncu='1'; tcu=1; obj=12.0; desv=2.0}
  [pscustomobject]@{ncu='1'; tcu=1; obj=12.0; desv=0.4}
  [pscustomobject]@{ncu='1'; tcu=1; obj=12.0; desv=0.3}
)
$pr = @(Sat-Precision $fp 1.0 2)
Check 'D.1.1 una TCU' $pr.Count 1
Check 'D.1.1 muestras validas' $pr[0].Validas 2          # solo las dos ultimas
Check 'D.1.1 dentro de tolerancia' $pr[0].Dentro 2
Check 'D.1.1 cumple' $pr[0].Cumple 'SI'
# una sola muestra fuera de 1 grado tumba el ensayo de esa TCU
$fp2 = @(
  [pscustomobject]@{ncu='1'; tcu=2; obj=12.0; desv=0.2}
  [pscustomobject]@{ncu='1'; tcu=2; obj=12.0; desv=0.2}
  [pscustomobject]@{ncu='1'; tcu=2; obj=12.0; desv=0.3}
  [pscustomobject]@{ncu='1'; tcu=2; obj=12.0; desv=1.8}
)
$pr2 = @(Sat-Precision $fp2 1.0 2)
Check 'D.1.1 una fuera = NO cumple' $pr2[0].Cumple 'NO'
Check 'D.1.1 peor desviacion' $pr2[0].Peor_deg 1.8

# D.3.4.1 disponibilidad de operacion: 99% por TCU y dia
$fo = @()
for ($i = 0; $i -lt 100; $i++) {
  $fo += [pscustomobject]@{dia='2026-08-06'; ncu='1'; tcu=1; al_motor=0; al_bat=0; al_com=0}
}
$do1 = @(Sat-DispOperacion $fo 99.0)
Check 'D.3.4.1 sin alarmas = 100' $do1[0].Disponibilidad_pct 100
Check 'D.3.4.1 equipo derivado del TCU' $do1[0].Equipo 'TCU1'
Check 'D.3.4.1 cumple' $do1[0].Cumple 'SI'
$fo[3].al_motor = 1; $fo[7].al_bat = 1
$do2 = @(Sat-DispOperacion $fo 99.0)
Check 'D.3.4.1 dos alarmas de 100' $do2[0].Disponibilidad_pct 98
Check 'D.3.4.1 no cumple' $do2[0].Cumple 'NO'
# las meteorologicas no entran: no hay columna para ellas, se ignoran por diseno

# D.4 comunicaciones: un fallo suelto no cuenta; repetido en 2 min, cuentan todos
$intentos = @{'2026-08-06' = 1000}
$sueltos = @(
  [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='TCU7'; ts=1000}
  [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='TCU7'; ts=5000}   # muy lejos
)
$dc1 = @(Sat-DispComms $sueltos $intentos 98.5 120)
Check 'D.4 fallos sueltos no cuentan' $dc1[0].Fallos_computados 0
Check 'D.4 disponibilidad 100 con sueltos' $dc1[0].Disponibilidad_pct 100
$rafaga = @(
  [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='TCU9'; ts=1000}
  [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='TCU9'; ts=1015}   # 15 s despues
  [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='TCU9'; ts=1030}
)
$dc2 = @(Sat-DispComms $rafaga $intentos 98.5 120)
Check 'D.4 rafaga: cuentan todos' $dc2[0].Fallos_computados 3
Check 'D.4 fallos brutos' $dc2[0].Fallos_brutos 3
Check 'D.4 disponibilidad con rafaga' $dc2[0].Disponibilidad_pct 99.7
Check 'D.4 cumple 98.5' $dc2[0].Cumple 'SI'
# justo en el limite de la ventana de 2 minutos
$limite = @(
  [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='TCU5'; ts=1000}
  [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='TCU5'; ts=1120}   # exactamente 120 s
)
Check 'D.4 a 120 s si cuenta' (@(Sat-DispComms $limite $intentos 98.5 120))[0].Fallos_computados 2
$fuera = @(
  [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='TCU5'; ts=1000}
  [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='TCU5'; ts=1121}   # 121 s: fuera
)
Check 'D.4 a 121 s no cuenta' (@(Sat-DispComms $fuera $intentos 98.5 120))[0].Fallos_computados 0
# el anexo pide 99,5% a las RSU y menos a las TCU: umbrales distintos
$intentos2 = @{'2026-08-06' = 1000}
$fallosRsu = @()
for ($i = 0; $i -lt 8; $i++) { $fallosRsu += [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='RSU1'; ts=(1000 + 15*$i)} }
$dr = @(Sat-DispComms $fallosRsu $intentos2 98.5 120 99.5)
Check 'D.4 RSU: 8 fallos de 1000' $dr[0].Disponibilidad_pct 99.2
Check 'D.4 RSU exige 99,5 y no llega' $dr[0].Cumple 'NO'
Check 'D.4 RSU umbral aplicado' $dr[0].Minimo_pct 99.5
$fallosTcu = @()
for ($i = 0; $i -lt 8; $i++) { $fallosTcu += [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='TCU1'; ts=(1000 + 15*$i)} }
$dt = @(Sat-DispComms $fallosTcu $intentos2 98.5 120 99.5)
Check 'D.4 TCU con los mismos fallos si cumple' $dt[0].Cumple 'SI'
Check 'D.4 TCU umbral aplicado' $dt[0].Minimo_pct 98.5

# D.3.4.2 / D.3.4.3: RSU y NCU con su propio 99,5%
$feq = @()
for ($i = 0; $i -lt 200; $i++) { $feq += [pscustomobject]@{dia='2026-08-06'; ncu='1'; equipo='RSU1'; al_motor=0; al_bat=0; al_com=0} }
$feq[5].al_com = 1; $feq[9].al_bat = 1
$dq = @(Sat-DispOperacion $feq 99.5)
Check 'D.3.4.2 dos de 200 = 99' $dq[0].Disponibilidad_pct 99
Check 'D.3.4.2 no cumple 99,5' $dq[0].Cumple 'NO'
Check 'D.3.4.2 equipo RSU' $dq[0].Equipo 'RSU1'

# ---------- D.2 abanderamiento: cronologia ----------
# El seguidor sigue al sol en 10 grados, llega la orden de abanderar a 0, va,
# se queda, y luego vuelve a seguimiento.
$ab = @(
  [pscustomobject]@{ts=100; real=10.0; obj=10.0}
  [pscustomobject]@{ts=110; real=10.0; obj=10.0}
  [pscustomobject]@{ts=120; real=10.0; obj=0.0}    # llega la orden
  [pscustomobject]@{ts=130; real=6.0;  obj=0.0}
  [pscustomobject]@{ts=140; real=0.5;  obj=0.0}    # llegado
  [pscustomobject]@{ts=150; real=0.4;  obj=0.0}
  [pscustomobject]@{ts=160; real=0.4;  obj=11.0}   # desabanderamiento
  [pscustomobject]@{ts=170; real=5.0;  obj=11.0}
  [pscustomobject]@{ts=180; real=10.8; obj=11.0}   # de vuelta en seguimiento
)
$cr = Aband-Cronologia $ab 1.0 2.0
Check 'D.2 hora de la orden' $cr.t_orden 120
Check 'D.2 inclinacion al recibir' $cr.tilt_orden 10
Check 'D.2 objetivo de seguridad' $cr.obj_seguridad 0
Check 'D.2 hora de llegada' $cr.t_llegada 140
Check 'D.2 inclinacion en seguridad' $cr.tilt_llegada 0.5
Check 'D.2 segundos de ida' $cr.segundos_ida 20
Check 'D.2 hora de desabanderamiento' $cr.t_vuelta 160
Check 'D.2 hora de vuelta a seguimiento' $cr.t_llegada_vuelta 180
Check 'D.2 segundos de vuelta' $cr.segundos_vuelta 20
# si nunca llega la orden, no se inventa nada
$abSin = @(
  [pscustomobject]@{ts=100; real=10.0; obj=10.0}
  [pscustomobject]@{ts=110; real=10.1; obj=10.0}
)
Check 'D.2 sin orden no inventa hora' (Aband-Cronologia $abSin 1.0 2.0).t_orden ''
# si abandera pero no vuelve, la ida si queda registrada
$abMedio = @(
  [pscustomobject]@{ts=100; real=10.0; obj=10.0}
  [pscustomobject]@{ts=110; real=10.0; obj=0.0}
  [pscustomobject]@{ts=120; real=0.2;  obj=0.0}
)
$crM = Aband-Cronologia $abMedio 1.0 2.0
Check 'D.2 ida sin vuelta: hay llegada' $crM.t_llegada 120
Check 'D.2 ida sin vuelta: no hay vuelta' $crM.t_vuelta ''

# --------------------------------------------------------------------------
#  Rangos plausibles e identidad de red
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '== rangos plausibles =='
Check 'rango: east_pitch bueno' (Rango-Sospechoso '41106 east_pitch [m]' '6') ''
Check 'rango: east_pitch en radianes' ((Rango-Sospechoso '41106 east_pitch [m]' '-0,7854').Contains('-45')) $true
Check 'rango: east_pitch en radianes avisa del rango' ((Rango-Sospechoso '41106 east_pitch [m]' '-0,7854').Contains('fuera de rango')) $true
Check 'rango: coma o punto dan igual' ((Rango-Sospechoso '41106 east_pitch [m]' '-0.7854') -ne '') $true
Check 'rango: max_tilt bueno' (Rango-Sospechoso '41111 max_tilt_west_r1 [deg]' '55') ''
# el limite este NO tiene por que ser negativo: en Ayora la config buena es +30
Check 'rango: min_tilt negativo vale' (Rango-Sospechoso '41125 min_tilt_east_r1 [deg]' '-45') ''
Check 'rango: min_tilt positivo tambien vale' (Rango-Sospechoso '41125 min_tilt_east_r1 [deg]' '30') ''
Check 'rango: max_tilt negativo vale' (Rango-Sospechoso '41111 max_tilt_west_r1 [deg]' '-45') ''
Check 'rango: tilt de 120 grados no' ((Rango-Sospechoso '41125 min_tilt_east_r1 [deg]' '120') -ne '') $true
Check 'rango: los 7 rangos de tilt estan' ($RANGOS.Contains('41137 min_tilt_east_r7 [deg]')) $true
Check 'rango: max_tilt_west_r7 esta' ($RANGOS.Contains('41123 max_tilt_west_r7 [deg]')) $true
Check 'rango: variable sin rango no molesta' (Rango-Sospechoso '40022 timeout_com_NCU [min]' '99999') ''
Check 'rango: vacio no molesta' (Rango-Sospechoso '41106 east_pitch [m]' '') ''
Check 'rango: guion no molesta' (Rango-Sospechoso '41106 east_pitch [m]' '-') ''
Check 'rango: hex no molesta' (Rango-Sospechoso '41068 safe_pos_options [hex]' '0x0000') ''
Check 'rango: latitud valida' (Rango-Sospechoso '41012 latitud [deg]' '39,05') ''
Check 'rango: latitud imposible' ((Rango-Sospechoso '41012 latitud [deg]' '139,05') -ne '') $true
# la pista de radianes solo aplica a metros: 45 grados en un campo [deg] es normal
Check 'radianes: 6 m no es un angulo' (Parece-Radianes 6.0) ''
Check 'radianes: -0,7854 es -45' ((Parece-Radianes -0.7854).Contains('-45')) $true
Check 'radianes: 0,5236 es 30' ((Parece-Radianes 0.5236).Contains('30')) $true
Check 'radianes: 0,9 no es angulo redondo' (Parece-Radianes 0.9) ''
Check 'radianes: cero no cuenta' (Parece-Radianes 0.0) ''

Write-Host ''
Write-Host '== sospechas sobre una lectura masiva =='
$filasSosp = @(
  [pscustomobject]@{NCU='9'; TCU=33; '41111 max_tilt_west_r1 [deg]'='55'; '41125 min_tilt_east_r1 [deg]'='-45'; '41106 east_pitch [m]'='6'; Estado='OK'}
  [pscustomobject]@{NCU='9'; TCU=34; '41111 max_tilt_west_r1 [deg]'='55'; '41125 min_tilt_east_r1 [deg]'='55'; '41106 east_pitch [m]'='-0,7854'; Estado='OK'}
  [pscustomobject]@{NCU='10'; TCU=19; '41111 max_tilt_west_r1 [deg]'='55'; '41125 min_tilt_east_r1 [deg]'='-45'; '41106 east_pitch [m]'='-0,7854'; Estado='OK'}
  [pscustomobject]@{NCU='10'; TCU=20; '41111 max_tilt_west_r1 [deg]'=''; '41125 min_tilt_east_r1 [deg]'=''; '41106 east_pitch [m]'=''; Estado='no responde'}
)
$sos = @(Sospechas-Lectura $filasSosp)
Check 'sospechas: tres celdas malas' $sos.Count 3
Check 'sospechas: la TCU 34 por el par de limites' ((@($sos | Where-Object { $_.TCU -eq 34 -and $_.Motivo.Contains('sin recorrido') }).Count)) 1
Check 'sospechas: la TCU muda no cuenta' (@($sos | Where-Object { $_.TCU -eq 20 }).Count) 0
Check 'sospechas: TCU 34 con dos' (@($sos | Where-Object { $_.TCU -eq 34 }).Count) 2
Check 'sospechas: TCU 19 con una' (@($sos | Where-Object { $_.TCU -eq 19 }).Count) 1
Check 'sospechas: lleva la NCU' (@($sos | Where-Object { $_.TCU -eq 19 })[0].NCU) '10'
Check 'sospechas: no toca las buenas' (@($sos | Where-Object { $_.TCU -eq 33 }).Count) 0
Check 'sospechas: lista vacia no revienta' (@(Sospechas-Lectura @()).Count) 0

Write-Host ''
Write-Host '== identidad de red =='
Check 'identidad: zigbee_slave_id dentro' ($ADDR_IDENTIDAD -contains $VARIABLES['41004 zigbee_slave_id (byte bajo)'].addr) $true
Check 'identidad: rs485_slave_id dentro' ($ADDR_IDENTIDAD -contains $VARIABLES['41006 rs485_slave_id (byte bajo)'].addr) $true
Check 'identidad: pan id bajo dentro' ($ADDR_IDENTIDAD -contains $VARIABLES['41070 zigbee_pan_id_bajo [u32]'].addr) $true
Check 'identidad: pan id alto dentro' ($ADDR_IDENTIDAD -contains $VARIABLES['41072 zigbee_pan_id_alto [u32]'].addr) $true
Check 'identidad: cifrado dentro' ($ADDR_IDENTIDAD -contains $VARIABLES['41074 zigbee_encryption [hex]'].addr) $true
Check 'identidad: clave dentro' ($ADDR_IDENTIDAD -contains $VARIABLES['41075 zigbee_user_key [u32]'].addr) $true
# lo que NO es identidad y debe seguir clonandose
Check 'identidad: east_pitch se clona' ($ADDR_IDENTIDAD -contains $VARIABLES['41106 east_pitch [m]'].addr) $false
Check 'identidad: latitud se clona' ($ADDR_IDENTIDAD -contains $VARIABLES['41012 latitud [deg]'].addr) $false
Check 'identidad: timeout NCU se clona' ($ADDR_IDENTIDAD -contains $VARIABLES['40022 timeout_com_NCU [min]'].addr) $false
# el codigo del boton no es invocable sin ventana: se comprueba en el texto
Check 'identidad: fuera del preset guardado' ($src.Contains('$vars  = @($vars | Where-Object { $ADDR_IDENTIDAD -notcontains $_.addr })')) $true
Check 'identidad: fuera del backup como preset' ($src.Contains('if ($ADDR_IDENTIDAD -contains $def.addr) { $nIdent++; continue }')) $true
Check 'identidad: fuera del preset de referencia' ($src.Contains('if ($ADDR_IDENTIDAD -contains $def.addr) { $nIdentRef++; continue }')) $true
Check 'identidad: escritura en bloque bloqueada' ($src.Contains('No se puede escribir IDENTIDAD DE RED en $nTcus TCUs a la vez')) $true

# --------------------------------------------------------------------------
#  Segunda lectura de valores anomalos, CSV con NCU y CSV de correccion
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '== a que valores merece la pena una segunda lectura =='
$repMuchos = @{'6'=300; '9'=2}
Check 'confirmar: valor imposible siempre' (Merece-Confirmar '41106 east_pitch [m]' '-0,7854' $repMuchos) $true
Check 'confirmar: valor mayoritario no' (Merece-Confirmar '41106 east_pitch [m]' '6' $repMuchos) $false
Check 'confirmar: minoritario ya visto no' (Merece-Confirmar '41106 east_pitch [m]' '9' $repMuchos) $false
Check 'confirmar: valor nunca visto si' (Merece-Confirmar '41106 east_pitch [m]' '7' $repMuchos) $true
Check 'confirmar: vacio no' (Merece-Confirmar '41106 east_pitch [m]' '' $repMuchos) $false
# con pocas TCUs leidas todavia no hay mayoria de la que fiarse
$repPocos = @{'6'=3}
Check 'confirmar: sin muestras suficientes no' (Merece-Confirmar '41106 east_pitch [m]' '7' $repPocos) $false
Check 'confirmar: imposible aunque haya pocas' (Merece-Confirmar '41106 east_pitch [m]' '-0,7854' $repPocos) $true
Check 'confirmar: sin reparto solo el rango' (Merece-Confirmar '41069 safe_pos_sign_threshold' '2560' $null) $false

Write-Host ''
Write-Host '== CSV de correccion a partir de una lectura =='
$filasCorr = @()
foreach ($t in 1..20) {
  $filasCorr += [pscustomobject]@{NCU='9'; TCU=$t
    '41111 max_tilt_west_r1 [deg]'='55'
    '41125 min_tilt_east_r1 [deg]'=$(if ($t -eq 4) { '55' } else { '-45' })
    '41106 east_pitch [m]'=$(if ($t -eq 4 -or $t -eq 9) { '-0,7854' } else { '6' })
    Estado='OK' }
}
$cc = Correccion-DeLectura $filasCorr
Check 'correccion: tres escrituras' (@($cc.filas).Count) 3
Check 'correccion: east_pitch a la mayoria' (@($cc.filas | Where-Object { $_.Variable -like '*east_pitch*' })[0].Valor) '6'
Check 'correccion: min_tilt a la mayoria' (@($cc.filas | Where-Object { $_.Variable -like '*min_tilt*' })[0].Valor) '-45'
Check 'correccion: lleva la NCU' (@($cc.filas)[0].NCU) '9'
Check 'correccion: solo las TCUs malas' (@(@($cc.filas | ForEach-Object { $_.TCU }) | Sort-Object -Unique) -join ',') '4,9'
Check 'correccion: hay avisos explicando' (@($cc.avisos).Count -gt 0) $true
# si NADIE tiene un valor plausible no se inventa una correccion
$todasMal = @(1..10 | ForEach-Object { [pscustomobject]@{NCU='9'; TCU=$_; '41106 east_pitch [m]'='-0,7854'; Estado='OK'} })
$cm = Correccion-DeLectura $todasMal
Check 'correccion: sin valor bueno no propone' (@($cm.filas).Count) 0
Check 'correccion: y lo dice' ((@($cm.avisos) -join ' ').Contains('ninguna TCU')) $true
# empate: tampoco se inventa nada
$empate = @()
foreach ($t in 1..4) { $empate += [pscustomobject]@{NCU='9'; TCU=$t; '41106 east_pitch [m]'=$(if ($t -le 2) { '6' } else { '9' }); Estado='OK'} }
$empate += [pscustomobject]@{NCU='9'; TCU=5; '41106 east_pitch [m]'='-0,7854'; Estado='OK'}
$ce = Correccion-DeLectura $empate
Check 'correccion: empate no propone' (@($ce.filas).Count) 0
Check 'correccion: y avisa del empate' ((@($ce.avisos) -join ' ').Contains('empate')) $true
Check 'correccion: lectura vacia no revienta' (@((Correccion-DeLectura @()).filas).Count) 0

Write-Host ''
Write-Host '== CSV por TCU con columna NCU =='
$csvNcu = @('NCU;TCU;variable;valor', '9;34;41106 east_pitch [m];6', '10;19;41106 east_pitch [m];6', '9;34;41125 min_tilt_east_r1 [deg];-45')
$pn = Parse-CsvPorTcu $csvNcu
Check 'csv NCU: tres filas' (@($pn.jobs).Count) 3
Check 'csv NCU: sin errores' (@($pn.errores).Count) 0
Check 'csv NCU: primera es de la 9' (@($pn.jobs)[0].ncu) '9'
Check 'csv NCU: segunda es de la 10' (@($pn.jobs)[1].ncu) '10'
Check 'csv NCU: la TCU se lee bien' (@($pn.jobs)[1].tcu) 19
# el formato de siempre sigue valiendo
$csvViejo = @('TCU;variable;valor', '34;41106 east_pitch [m];6')
$pv = Parse-CsvPorTcu $csvViejo
Check 'csv sin NCU: sigue valiendo' (@($pv.jobs).Count) 1
Check 'csv sin NCU: ncu vacia' (@($pv.jobs)[0].ncu) ''
Check 'csv sin NCU: valor con coma decimal' ((Parse-CsvPorTcu @('TCU;variable;valor','34;41106 east_pitch [m];6,5')).jobs[0].texto) '6,5'
Check 'csv NCU: valor con coma decimal' ((Parse-CsvPorTcu @('NCU;TCU;variable;valor','9;34;41106 east_pitch [m];6,5')).jobs[0].texto) '6,5'
Check 'csv NCU: fila corta da error' (@((Parse-CsvPorTcu @('NCU;TCU;variable;valor','9;34;6')).errores).Count) 1

Write-Host ''
Write-Host '== reparto del CSV entre las NCUs de la planta =='
$cxPlanta = @{ip='NA'; puerto=$null; gws=$null; etiqueta='PLANTA'; to=8000; reint=3
  multi=@(@{ncu=9; ip='192.168.4.109'; gws=@(@{puerto=503; ini=1; fin=40})}
          @{ncu=10; ip='192.168.4.110'; gws=@(@{puerto=503; ini=1; fin=40})})}
$g1 = Grupos-CsvPorNcu @($pn.jobs) $cxPlanta
Check 'grupos: dos NCUs' (@($g1.grupos).Count) 2
Check 'grupos: la 9 lleva dos filas' (@(@($g1.grupos | Where-Object { $_.ncu -eq 9 })[0].jobs).Count) 2
Check 'grupos: coge la IP de la NCU' (@($g1.grupos | Where-Object { $_.ncu -eq 10 })[0].cx.ip) '192.168.4.110'
Check 'grupos: sin avisos' (@($g1.avisos).Count) 0
# una NCU que no esta en la planta no se escribe a ciegas
$fuera = @(@{ncu='77'; tcu=1; nombre='41106 east_pitch [m]'; texto='6'; esc=@{}})
$g2 = Grupos-CsvPorNcu $fuera $cxPlanta
Check 'grupos: NCU desconocida fuera' (@($g2.grupos).Count) 0
Check 'grupos: y lo avisa' ((@($g2.avisos) -join ' ').Contains('no esta en la planta')) $true
# CSV con NCU pero conexion a una sola NCU: no se sabe si coinciden
$cxUna = @{ip='192.168.4.109'; puerto=503; gws=$null; etiqueta='503'; to=8000; reint=3}
$g3 = Grupos-CsvPorNcu @($pn.jobs) $cxUna
Check 'grupos: NCU en el CSV exige planta completa' (@($g3.grupos).Count) 0
# CSV sin NCU y conexion de planta completa: ambiguo, se rechaza
$g4 = Grupos-CsvPorNcu @($pv.jobs) $cxPlanta
Check 'grupos: sin NCU y planta completa se rechaza' (@($g4.grupos).Count) 0
# CSV sin NCU y una sola NCU: el caso de siempre
$g5 = Grupos-CsvPorNcu @($pv.jobs) $cxUna
Check 'grupos: sin NCU y una NCU vale' (@($g5.grupos).Count) 1
Check 'grupos: usa la conexion de la ventana' (@($g5.grupos)[0].cx.etiqueta) '503'

# --------------------------------------------------------------------------
#  Usuarios, roles y registro
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '== contrasenas =='
$uA = Usuario-Nuevo 'ana' 'Ana Perez' 'admin' 'clave1234'
Check 'usuario: no guarda la contrasena' ("$($uA | ConvertTo-Json)".Contains('clave1234')) $false
Check 'usuario: guarda hash' ("$($uA.hash)".Length -gt 20) $true
Check 'usuario: sal propia' ("$($uA.sal)".Length -gt 10) $true
Check 'usuario: el hash depende de la sal' ((Pwd-Hash 'clave1234' $uA.sal 100000) -eq $uA.hash) $true
$uB = Usuario-Nuevo 'bea' 'Bea Ruiz' 'lectura' 'clave1234'
Check 'usuario: misma clave, distinto hash' ($uA.hash -eq $uB.hash) $false
$lista = @($uA, $uB)
Check 'login: usuario y clave buenos' ((Usuario-Validar $lista 'ana' 'clave1234').rol) 'admin'
Check 'login: clave mala' (Usuario-Validar $lista 'ana' 'otra') $null
Check 'login: usuario que no existe' (Usuario-Validar $lista 'nadie' 'clave1234') $null
Check 'login: no distingue mayusculas en el usuario' ((Usuario-Validar $lista 'ANA' 'clave1234').usuario) 'ana'
Check 'login: la clave si distingue' (Usuario-Validar $lista 'ana' 'CLAVE1234') $null
Check 'login: lista vacia' (Usuario-Validar @() 'ana' 'clave1234') $null

Write-Host ''
Write-Host '== jerarquia de roles =='
$script:Usuario = $uB   # lectura
Check 'rol lectura: no escribe' (Puede 'tecnico') $false
Check 'rol lectura: si lee' (Puede 'lectura') $true
Check 'rol lectura: no es admin' (Puede 'admin') $false
$script:Usuario = @{usuario='t'; nombre='T'; rol='tecnico'}
Check 'rol tecnico: escribe' (Puede 'tecnico') $true
Check 'rol tecnico: no es admin' (Puede 'admin') $false
$script:Usuario = $uA
Check 'rol admin: puede todo' ((Puede 'lectura') -and (Puede 'tecnico') -and (Puede 'admin')) $true
$script:Usuario = $null
Check 'sin sesion: no puede nada' (Puede 'lectura') $false
$script:Usuario = $uA

Write-Host ''
Write-Host '== filtro de las tablas de resultados =='
Check 'filtro: sin filtros pasa todo' (Lv-Pasa @('9','34','55') @{}) $true
Check 'filtro: valor que casa' (Lv-Pasa @('9','34','55') @{'0'=@('9')}) $true
Check 'filtro: valor que no casa' (Lv-Pasa @('9','34','55') @{'0'=@('10')}) $false
Check 'filtro: varios valores en una columna' (Lv-Pasa @('9','34','55') @{'0'=@('9','10')}) $true
Check 'filtro: dos columnas a la vez' (Lv-Pasa @('9','34','55') @{'0'=@('9'); '2'=@('55')}) $true
Check 'filtro: dos columnas, una falla' (Lv-Pasa @('9','34','55') @{'0'=@('9'); '2'=@('30')}) $false
Check 'filtro: columna que no existe' (Lv-Pasa @('9') @{'5'=@('x')}) $false
Check 'filtro: celda vacia' (Lv-Pasa @('9','') @{'1'=@('')}) $true
Check 'orden: numero se ordena como numero' (Lv-Clave '10') 10
# el rotulo del menu tiene que decir "de menor a mayor" en columnas numericas
Check 'orden: rotulo numerico' ($src.Contains('de menor a mayor')) $true
Check 'orden: y alfabetico si no lo es' ($src.Contains("A-Z")) $true
Check 'orden: coma decimal' (Lv-Clave '-0,7854') -0.7854
Check 'orden: texto no es numero' ([double]::IsNaN((Lv-Clave 'ALARMA'))) $true
# El menu se cerraba al primer clic, asi que solo se podia tocar UNA casilla
# por apertura. Se cancela el cierre por clic y lo cierran a mano las opciones
# que terminan; el orden en que WinForms dispara Click y Closing no importa.
$iMen = $src.IndexOf('function Lv-Menu'); $fMen = $src.IndexOf('function Lv-Filtrable')
$menu = $src.Substring($iMen, $fMen - $iMen)
Check 'menu: cancela el cierre al pulsar' ($menu.Contains("CloseReason -eq 'ItemClicked') { `$e2.Cancel = `$true }")) $true
Check 'menu: ordenar cierra a mano' ($menu.Contains('Lv-Ordenar $lv $col $true; $m.Close()')) $true
Check 'menu: quitar filtros cierra a mano' ($menu.Contains('Lv-Aplicar $lv; $m.Close()')) $true
Check 'menu: y hay una salida explicita' ($menu.Contains("Items.Add('Cerrar')")) $true
# cada casilla aplica el filtro al vuelo, sin esperar a que se cierre el menu
Check 'menu: la casilla aplica al vuelo' ($menu.Contains('$it.Add_Click({ & $aplicar }')) $true
Check 'menu: ya no se aplica al cerrar' ($menu.Contains('Add_Closed')) $false
Check 'menu: marcar todos' ($menu.Contains("Items.Add('Marcar todos')")) $true
Check 'menu: desmarcar todos' ($menu.Contains("Items.Add('Desmarcar todos')")) $true

Write-Host ''
Write-Host '== el esclavo de cada HSU =='
# Todas las de Ayora son la 230, menos la SEGUNDA de la NCU15, que es la 231.
# La cache de la NCU numera los huecos HSU1, HSU2... y la lista va en ese orden.
# Va por ORDEN DE APARICION en la NCU, no por el numero del hueco: en Ayora la
# NCU15 tiene sus dos estaciones en los huecos 8 y 9 (la numeracion del hueco es
# de la planta entera), asi que usar el hueco como indice se salia de la lista y
# las dos acababan con el mismo esclavo.
$n15 = @{ncu='15'; hsu=230; hsuLista=@(230, 231)}
Check 'esclavo: la primera de la NCU15' (Hsu-EsclavoDe $n15 0) 230
Check 'esclavo: la segunda' (Hsu-EsclavoDe $n15 1) 231
$n2 = @{ncu='2'; hsu=230; hsuLista=@(230)}
Check 'esclavo: una sola' (Hsu-EsclavoDe $n2 0) 230
# mas HSUs de las que trae la lista: mejor el primero que nada
Check 'esclavo: fuera de la lista' (Hsu-EsclavoDe $n2 3) 230
# sin lista se usa el valor suelto de siempre (hsu_esclavo)
Check 'esclavo: sin lista, el de siempre' (Hsu-EsclavoDe @{hsu=185; hsuLista=@()} 0) 185
Check 'esclavo: sin nada, nada' ($null -eq (Hsu-EsclavoDe @{hsu=$null; hsuLista=@()} 0)) $true
# y el barrido tiene que pasarle el contador, no la etiqueta del hueco
$iBus = $src.IndexOf('$btnHBuscar.Add_Click'); $fBus = $src.IndexOf('# Barrido de esclavos')
$bus = $src.Substring($iBus, $fBus - $iBus)
Check 'esclavo: el barrido lleva contador' ($bus.Contains('Hsu-EsclavoDe $n $iEnNcu')) $true
Check 'esclavo: y lo incrementa' ($bus.Contains('$iEnNcu++')) $true
Check 'esclavo: uno por NCU' ($bus.Contains('$iEnNcu = 0')) $true

Write-Host ''
Write-Host '== las HSUs que faltan tambien se pintan =='
# No aparecer no es informacion: igual que con las TCUs, la que no comunica
# tiene que salir en la tabla diciendolo.
$fN = @{ncu='11'; hsus=1}
$ff1 = @(Hsu-Faltantes $fN 0)
Check 'faltan: una fila por la que no sale' ($ff1.Count) 1
Check 'faltan: con su NCU' ($ff1[0].etiqueta) 'NCU11 - HSU?'
Check 'faltan: y como OFFLINE' ($ff1[0].salud) 'OFFLINE'
Check 'faltan: dice que nunca ha comunicado' ($ff1[0].texto.Contains('nunca ha comunicado')) $true
Check 'faltan: y cuantas deberia haber' ($ff1[0].texto.Contains('lleva 1')) $true
# si la NCU no contesta, el motivo es otro
$ff2 = @(Hsu-Faltantes $fN 0 'la NCU no contesta en el puerto 502')
Check 'faltan: distingue que la NCU no conteste' ($ff2[0].texto.Contains('no contesta en el puerto 502')) $true
# la NCU15 lleva dos: si sale una, falta una
Check 'faltan: dos esperadas y una hallada' ((@(Hsu-Faltantes @{ncu='15'; hsus=2} 1)).Count) 1
Check 'faltan: dos esperadas y dos halladas' ((@(Hsu-Faltantes @{ncu='15'; hsus=2} 2)).Count) 0
# sin dato de topologia no se inventa ninguna
# ---------- una NCU suelta tambien descuenta los huecos (v11.35) ----------
# Los huecos solo se aplicaban por la via de los gateways ((auto) y Planta
# completa). Con la entrada de UNA NCU se seguian leyendo: en Ayora NCU7 salian
# la 14, la 24 y la 25 -que no existen- como OFFLINE en cada barrido.
$cxSuelta = @{ip='1.2.3.4'; puerto=503; gws=$null; multi=$null; etiqueta='503'; to=1000; reint=1; huecos=@(14,24,25)}
$segSuelta = Plan-Segmentos @(12,13,14,15,24,25) $cxSuelta
Check 'huecos: la NCU suelta los descuenta' (($segSuelta.tcus) -join ',') '12,13,15'
Check 'huecos: y respeta el puerto' $segSuelta.puerto 503
$cxSinH = @{ip='1.2.3.4'; puerto=503; gws=$null; multi=$null; etiqueta='503'; to=1000; reint=1}
Check 'huecos: sin huecos, no toca nada' ((Plan-Segmentos @(1,2,3) $cxSinH).tcus -join ',') '1,2,3'
# el cuadro de TCUs al elegir la entrada: los huecos ya no entran
$rangoH = (Runs-Consecutivos (Tcus-DeGw @{ini=1; fin=25; huecos=@(14,24,25)}) |
           ForEach-Object { $(if ($_.ini -eq $_.fin) { "$($_.ini)" } else { "$($_.ini)-$($_.fin)" }) }) -join ','
Check 'huecos: el cuadro sale ya sin ellos' $rangoH '1-13,15-23'
Check 'huecos: y ese texto lo entiende la seleccion' ((Parse-Seleccion $rangoH 'x').lista -join ',') ((1..13 + 15..23) -join ',')

# ---------- la flota declarada de una NCU suelta tambien salta los huecos ----------
# Con la entrada Ayora NCU7 salian 24 filas en vez de 23: se leian las 22 que
# existen, pero Flota-Declarada rehacia el rango SIN huecos y metia la 14 como
# SIN LECTURA. Un equipo que no existe no puede faltar.
$cxN7 = @{ip='192.168.4.55'; puerto=503; gws=$null; multi=$null; etiqueta='503'; to=1000; reint=1
          nombre='Ayora NCU7'; ini=1; fin=23; huecos=@(14)}
$flN7 = @(Flota-Declarada $cxN7)
Check 'flota: la NCU suelta declara sus TCUs' (@($flN7 | Where-Object { $_.Tipo -eq 'TCU' }).Count) 22
Check 'flota: y no cuela el hueco' (@($flN7 | Where-Object { $_.Tipo -eq 'TCU' -and $_.TCU -eq '14' }).Count) 0
Check 'flota: con su fila de NCU' (@($flN7 | Where-Object { $_.Tipo -eq 'NCU' }).Count) 1
Check 'flota: total de filas' ($flN7.Count) 23
# el GW que no existe tampoco es alarma con una NCU suelta: su puerto ES su gateway
Check 'flota: el puerto de una NCU suelta vale como gateway' (
    ($src -match '(?s)elseif \(\$tr\.cx\.puerto\) \{ @\(@\{puerto=\[int\]\$tr\.cx\.puerto\}\) \}')) $true

# ---------- la fila de la NCU, y las HSUs por cuenta (v11.37) ----------
# El barrido EN PARALELO -que es el modo por defecto- no ponia la fila de salud
# de la NCU: el diagnostico de Ayora salio con 765 filas en vez de 782, sin una
# sola NCU y sin la HSU de la NCU16.
$fn = Diag-FilaNcu '7' @{salud='ALARMA'; alarmas=@('GW2 DESCONECTADO'); fecha=''; desvio=$null} ''
Check 'ncufila: es del tipo NCU' $fn.TCU 'NCU'
Check 'ncufila: con su salud' $fn.Salud 'ALARMA'
Check 'ncufila: y sus alarmas' $fn.Alarmas 'GW2 DESCONECTADO'
$fnMuda = Diag-FilaNcu '9' $null 'timeout'
Check 'ncufila: la NCU muda tambien sale' $fnMuda.Salud 'AVISO'
Check 'ncufila: diciendo que no contesta' ($fnMuda.Alarmas -like '*sin respuesta*timeout*') $true
# HSUs: el numero leido es el hueco de la cache y no casa con el orden declarado
$declH = @(@{NCU='3'; Tipo='HSU'; TCU='HSU1'}, @{NCU='15'; Tipo='HSU'; TCU='HSU1'}, @{NCU='15'; Tipo='HSU'; TCU='HSU2'}, @{NCU='16'; Tipo='HSU'; TCU='HSU1'})
$leidasH = @(
    [pscustomobject]@{NCU='3'; TCU='HSU2'; Salud='OK'; Alarmas=''}
    [pscustomobject]@{NCU='15'; TCU='HSU8'; Salud='OK'; Alarmas=''}
    [pscustomobject]@{NCU='15'; TCU='HSU9'; Salud='ALARMA'; Alarmas=''})
$compH = @(Diag-Completar $leidasH $declH)
Check 'hsucuenta: no inventa las que ya se leyeron con otro numero' (@($compH | Where-Object { $_.Salud -eq 'SIN LECTURA' }).Count) 1
Check 'hsucuenta: y la que falta es la de la NCU16' (@($compH | Where-Object { $_.Salud -eq 'SIN LECTURA' })[0].NCU) '16'
Check 'hsucuenta: con el nombre que declara la topologia' (@($compH | Where-Object { $_.Salud -eq 'SIN LECTURA' })[0].TCU) 'HSU1'
# si la NCU declara 2 y solo contesta 1 con otro numero, no se adivina cual es
$comp2 = @(Diag-Completar @([pscustomobject]@{NCU='15'; TCU='HSU8'; Salud='OK'; Alarmas=''}) @(@{NCU='15'; TCU='HSU1'}, @{NCU='15'; TCU='HSU2'}))
Check 'hsucuenta: si no cuadran los numeros, interrogante' (@($comp2 | Where-Object { $_.Salud -eq 'SIN LECTURA' })[0].TCU) 'HSU?'
# y con el campo rsu de la topologia, la declarada lleva ya su numero de planta
$flRsu = @(Flota-Declarada @{nombre='Ayora NCU16'; ip='1.2.3.4'; puerto=503; ini=1; fin=2; hsuLista=@(230); rsuLista=@(10)})
Check 'hsucuenta: con rsu, la HSU declarada es la 10' (@($flRsu | Where-Object { $_.Tipo -eq 'HSU' })[0].TCU) 'HSU10'

# ---------- APLICAR MODO no escribe en las que ya estan (v11.37) ----------
# El simulador tiene la TCU 1 en AUTO (bits 9:8 de 30001 = 2)
# el simulador tiene la TCU 5 en AUTO (30001 = 0x0280) y la 1 sin preset (OFF)
Modbus-Conectar '127.0.0.1' 15020 2000
Check 'modo: lee el modo actual' (Modo-Actual 5) 2
Check 'modo: y el de una que esta en OFF' (Modo-Actual 1) 0
Modbus-Cerrar
Check 'modo: el nombre sale de la tabla de siempre' (Modo-Nombre 2) 'AUTO'
Check 'modo: se comprueba antes de escribir' ($src.Contains('$md = Modo-Actual $tcu')) $true
Check 'modo: y si ya esta, no se escribe' ($src -match "if \(\`$md -eq \`$modo\) \{[\s\S]{0,200}no se ha escrito") $true
Check 'modo: el resumen dice cuantas ya estaban' ($src.Contains('{0} ya estaban, {1} cambiadas, {2} con fallo')) $true

# ---------- pestana Comm NCU (v11.40) ----------
# Lo que dice cada NCU de si misma, en una fila. Lo importante: distinguir
# "no lo tiene" de "lo tiene mal". Un gateway que la topologia no declara no
# puede estar CAIDO: en Ayora todas las NCUs llevan uno solo.
$nsOk = @{salud='OK'; alarmas=@(); fecha='2026-08-11 09:00:00 UTC'; desvio=3; din=0; principal=0}
$commOk = @{tcus=@{1=@{comunica=$true}; 2=@{comunica=$true}; 3=@{comunica=$false}}; hsus=@(@{comunica=$true})}
$f1 = Comm-FilaNcu '7' '192.168.4.55' $nsOk @(@{puerto=503}) $commOk 22 0 'v1.2.3'
Check 'comm: la version de la NCU' $f1.FW 'v1.2.3'
Check 'comm: la NCU que va bien' $f1.Estado 'OK'
Check 'comm: su unico gateway' $f1.GW1 'OK'
Check 'comm: y el que no tiene, ni OK ni CAIDO' $f1.GW2 '-'
Check 'comm: UPS sin novedad' $f1.UPS 'OK'
Check 'comm: seta sin pulsar' $f1.Seta '-'
Check 'comm: reloj en hora' $f1.Reloj 'en hora'
Check 'comm: cuenta las TCUs que hablan' $f1.TCUs '2/22'
# con los dos gateways declarados y el segundo caido
$nsMal = @{salud='ALARMA'; alarmas=@('GW2 DESCONECTADO'); fecha=''; desvio=$null; din=0x2001; principal=0x20}
$f2 = Comm-FilaNcu '16' '10.0.0.1' $nsMal @(@{puerto=503}, @{puerto=504}) $null 121 2
Check 'comm: el GW1 sigue bien' $f2.GW1 'OK'
Check 'comm: y el GW2 caido' $f2.GW2 'CAIDO'
Check 'comm: la seta pulsada se ve' $f2.Seta 'PULSADA'
Check 'comm: y el UPS con bateria baja' $f2.UPS 'bateria baja'
Check 'comm: sin hora de la NCU' $f2.Reloj 'sin hora'
Check 'comm: sin contar TCUs, la columna va vacia' $f2.TCUs ''
# la NCU que no contesta: fila igual, pero sin inventarse nada
$f3 = Comm-FilaNcu '9' '10.0.0.9' $null @(@{puerto=503}) $null 41 0
Check 'comm: la NCU muda tambien sale' $f3.Estado 'SIN RESPUESTA'
Check 'comm: y no dice que su gateway este caido' $f3.GW1 'OK'
Check 'comm: ni inventa el UPS' $f3.UPS ''
# reloj desviado
$nsRel = @{salud='OK'; alarmas=@(); fecha='2026-08-11 09:00:00 UTC'; desvio=4000; din=0; principal=0}
Check 'comm: el reloj desviado lo dice' ((Comm-FilaNcu '1' '1.1.1.1' $nsRel @(@{puerto=503}) $null 10 0).Reloj -like '*RELOJ NCU DESVIADO*') $true

# ---------- estabilidad de la Zigbee (v11.41) ----------
# No hay RSSI en el mapa: se infiere de cuanto tiempo esta fresca cada TCU.
$m = @{}
# TCU 1 siempre fresca, TCU 2 se cae una vez y vuelve, TCU 3 nunca
$m = Estab-Acumular $m '7' @{tcus=@{1=@{comunica=$true; edad=3}; 2=@{comunica=$true; edad=5}; 3=@{comunica=$false; edad=900}}}
$m = Estab-Acumular $m '7' @{tcus=@{1=@{comunica=$true; edad=4}; 2=@{comunica=$false; edad=400}; 3=@{comunica=$false; edad=1200}}}
$m = Estab-Acumular $m '7' @{tcus=@{1=@{comunica=$true; edad=2}; 2=@{comunica=$true; edad=9}; 3=@{comunica=$false; edad=1500}}}
$res = @(Estab-Resumen $m)
Check 'estab: una fila por TCU' $res.Count 3
$e1 = @($res | Where-Object { $_.TCU -eq 1 })[0]
$e2 = @($res | Where-Object { $_.TCU -eq 2 })[0]
$e3 = @($res | Where-Object { $_.TCU -eq 3 })[0]
Check 'estab: la que siempre habla es estable' $e1.Veredicto 'estable'
Check 'estab: y al 100 %' $e1.Frescas_pct 100
Check 'estab: la que se cae una vez, contada' $e2.Caidas 1
Check 'estab: con su porcentaje' $e2.Frescas_pct 66.7
Check 'estab: y con dos de cada tres, mala' $e2.Veredicto 'mala'
# el escalon de intermitente: 96 % es 24 de 25
$mi = @{}
for ($k=1; $k -le 24; $k++) { $mi = Estab-Acumular $mi '3' @{tcus=@{5=@{comunica=$true; edad=2}}} }
$mi = Estab-Acumular $mi '3' @{tcus=@{5=@{comunica=$false; edad=500}}}
Check 'estab: 96 por ciento es intermitente' (@(Estab-Resumen $mi)[0].Veredicto) 'intermitente'
Check 'estab: la que nunca habla' $e3.Veredicto 'sin comunicacion'
Check 'estab: caidas solo al pasar de fresca a muda' $e3.Caidas 0
Check 'estab: guarda la edad maxima' $e3.Edad_max_s 1500
# las peores primero: es lo que se mira
Check 'estab: la peor va arriba' $res[0].TCU 3
Check 'estab: y la mejor abajo' $res[-1].TCU 1
Check 'estab: sin datos no revienta' (@(Estab-Resumen @{}).Count) 0
Check 'estab: una NCU muda no aporta filas' (@(Estab-Resumen (Estab-Acumular @{} '9' $null)).Count) 0

Check 'faltan: sin topologia, ninguna' ((@(Hsu-Faltantes @{ncu='4'; hsus=0} 0)).Count) 0
Check 'faltan: y si hay mas de las dichas tampoco' ((@(Hsu-Faltantes @{ncu='4'; hsus=1} 3)).Count) 0
# ---------- la que falta tiene nombre si la topologia lo trae (v11.34) ----------
# El numero de una HSU es el hueco que ocupa en la cache de la NCU (= columna RSU
# del Excel). La que nunca ha comunicado tiene el hueco vacio, asi que salia
# "HSU?" aunque la topologia supiera que es la 10.
$n16 = @{ncu='16'; hsus=1; rsuLista=@(10)}
Check 'rsu: la que falta se llama por su numero' ((@(Hsu-Faltantes $n16 0 '' @()))[0].etiqueta) 'NCU16 - HSU10'
# la NCU15 lleva la 8 y la 9: si sale la 8, la que falta es la 9
$n15 = @{ncu='15'; hsus=2; rsuLista=@(8, 9)}
Check 'rsu: con una hallada, nombra la otra' ((@(Hsu-Faltantes $n15 1 '' @('HSU8')))[0].etiqueta) 'NCU15 - HSU9'
Check 'rsu: y al reves tambien' ((@(Hsu-Faltantes $n15 1 '' @('HSU9')))[0].etiqueta) 'NCU15 - HSU8'
# si lo hallado no encaja con lo declarado no se adivina
Check 'rsu: si no encaja, vuelve al interrogante' ((@(Hsu-Faltantes $n15 1 '' @('HSU3')))[0].etiqueta) 'NCU15 - HSU?'
# y sin el campo en el JSON, como antes
Check 'rsu: sin el dato, como antes' ((@(Hsu-Faltantes @{ncu='16'; hsus=1} 0 '' @()))[0].etiqueta) 'NCU16 - HSU?'
# la lista declarada tiene que cuadrar con el numero de estaciones
Check 'rsu: lista incoherente, interrogante' ((@(Hsu-Faltantes @{ncu='16'; hsus=2; rsuLista=@(10)} 0 '' @()))[0].etiqueta) 'NCU16 - HSU?'
# no entran en el desplegable ni en el cuadre: no se puede operar con ellas
$iBus2 = $src.IndexOf('$btnHBuscar.Add_Click'); $fBus2 = $src.IndexOf('# Barrido de esclavos')
$bus2 = $src.Substring($iBus2, $fBus2 - $iBus2)
Check 'faltan: no van a HsusPlanta' ($bus2.Contains('$script:HsusPlanta += ,@{etiqueta=$ff')) $false
Check 'faltan: pero si a la tabla' ($bus2.Contains('$lvH.Items.Add($itemF)')) $true

Write-Host ''
Write-Host '== la barra de avance en el barrido en paralelo =='
# EndInvoke en orden bloquea hasta el final: la barra se quedaba en 0/754 todo
# el barrido. Ahora se recogen segun acaban y cada una avisa.
Check 'avance: Paralelo-Ejecutar admite aviso' ($src.Contains('[scriptblock]$alTerminar = $null)')) $true
Check 'avance: recoge segun acaban' ($src.Contains('if (-not $e.ar.IsCompleted) { continue }')) $true
Check 'avance: y llama al aviso' ($src.Contains('if ($alTerminar) { & $alTerminar $e.tarea }')) $true
Check 'avance: el diagnostico lo usa' ($src.Contains('Prog-Paso @($t.tcus).Count; [System.Windows.Forms.Application]::DoEvents()')) $true
# lo de verdad: que el callback se llame una vez por tarea
$hechas = @{ n = 0; tcus = 0 }
$fake = @(@{ncu='1'; tcus=@(1,2,3)}, @{ncu='2'; tcus=@(1,2)})
$cb = { param($t) $hechas.n++; $hechas.tcus += @($t.tcus).Count }
foreach ($t in $fake) { & $cb $t }
Check 'avance: una llamada por NCU' ($hechas.n) 2
Check 'avance: y suma sus TCUs' ($hechas.tcus) 5

Write-Host ''
Write-Host '== cuadre de HSUs contra la topologia =='
# "he encontrado 9" no dice nada; "falta la de NCU15" si. La topologia sabe
# cuantas deberia haber (columna RSU del Excel); Ayora tiene 10 y la NCU15
# lleva DOS, en una fila de continuacion del Excel sin NCU ni IP.
$ncusT = @(@{ncu='2'; hsus=1}, @{ncu='15'; hsus=2}, @{ncu='16'; hsus=1}, @{ncu='7'; hsus=0})
$todas = @(@{ncu='2'}, @{ncu='15'}, @{ncu='15'}, @{ncu='16'})
$cOk = Hsu-Cuadre $ncusT $todas
Check 'hsu: con todas no se queja' (@($cOk.faltan).Count + @($cOk.sobran).Count) 0
Check 'hsu: dice cuantas esperaba' ($cOk.esperadas) 4
Check 'hsu: y lo dice' ($cOk.texto.Contains('Las 4 HSUs')) $true
# la de la NCU15 que no contesta: es el caso real
$cFalta = Hsu-Cuadre $ncusT @(@{ncu='2'}, @{ncu='15'}, @{ncu='16'})
Check 'hsu: detecta la que falta' (@($cFalta.faltan).Count) 1
Check 'hsu: y dice cual' ($cFalta.faltan[0]) 'NCU15 (1 de 2)'
Check 'hsu: con el total esperado' ($cFalta.texto.Contains('espera 4')) $true
Check 'hsu: y que puede pasar' ($cFalta.texto.Contains('no comunican')) $true
# y el rotulo de la pestana lo dice, que la consola se pierde de vista
Check 'hsu: el rotulo avisa de las que faltan' ($src.Contains('FALTAN: solo $($script:HsusPlanta.Count) de las')) $true
Check 'hsu: y lo pinta en rojo' ($src.Contains('$lblHSel.ForeColor')) $true
# al reves: la topologia se ha quedado corta
$cSobra = Hsu-Cuadre $ncusT (@($todas) + @(@{ncu='2'}))
Check 'hsu: tambien avisa si sobran' (@($cSobra.sobran).Count) 1
Check 'hsu: y manda actualizar el Excel' ($cSobra.texto.Contains('columna RSU')) $true
# sin topologia no se inventa nada: no puede decir si falta o no
Check 'hsu: sin dato de topologia calla' ((Hsu-Cuadre @(@{ncu='1'; hsus=0}) @(@{ncu='1'})).texto) ''
Check 'hsu: ni con la lista vacia' ((Hsu-Cuadre @() @()).texto) ''
# una NCU que no estaba en la topologia y aparece con HSU: sobra, no revienta
Check 'hsu: NCU desconocida no rompe' (@((Hsu-Cuadre $ncusT (@($todas) + @(@{ncu='99'}))).sobran).Count) 1

Write-Host ''
Write-Host '== barrido de esclavos =='
$bar = @(Esclavos-Barrido 185 1 247)
Check 'barrido: no repite' ($bar.Count) (@($bar | Sort-Object -Unique).Count)
Check 'barrido: cubre el rango' ($bar.Count) 247
Check 'barrido: empieza por el que hay puesto' ($bar[0]) 185
Check 'barrido: rango corto se respeta' (@(Esclavos-Barrido 185 1 10).Count) 10
Check 'barrido: no se cuela el actual fuera de rango' (@(Esclavos-Barrido 185 1 10) -contains 185) $false
Check 'tipo: 1 es TCU' ((Tipo-Producto 0x0011).nombre) 'TCU'
Check 'tipo: 2 es HSU' ((Tipo-Producto 0x0012).nombre) 'HSU'
Check 'tipo: HW del nibble alto' ((Tipo-Producto 0x0062).hw) 6

# --------------------------------------------------------------------------
#  Rotulos: una sola TCU no es "todas", y la NCU sale del nombre de la entrada
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '== rotulo de rango =='
Check 'rango: una sola TCU' (Eti-Rango @(16)) 'TCU 16'
Check 'rango: varias TCUs' (Eti-Rango @(16,17,18)) 'TCUs 16-18'
Check 'rango: dos TCUs' (Eti-Rango @(1,63)) 'TCUs 1-63'
Check 'rango: ninguna' (Eti-Rango @()) 'sin TCUs'

Write-Host ''
Write-Host '== NCU a partir del nombre de la entrada =='
Check 'ncu: entrada con NCU al final' (Ncu-DeNombre 'Ayora NCU3') '3'
Check 'ncu: con espacio' (Ncu-DeNombre 'Ayora NCU 15') '15'
Check 'ncu: en minusculas' (Ncu-DeNombre 'ayora ncu7') '7'
Check 'ncu: entrada (auto)' (Ncu-DeNombre 'Ayora NCU2 (auto)') '2'
Check 'ncu: planta completa no tiene numero' (Ncu-DeNombre 'Ayora (Planta completa)') ''
Check 'ncu: nombre sin NCU' (Ncu-DeNombre 'El Burgo') ''
Check 'ncu: vacio' (Ncu-DeNombre '') ''
# lo que de verdad importa: que Trabajos-Planta lo propague
$cxUnaNcu = @{ip='192.168.4.30'; puerto=503; gws=$null; multi=$null; etiqueta='503'; to=8000; reint=1; nombre='Ayora NCU3'}
$trab = Trabajos-Planta $cxUnaNcu @(16)
Check 'ncu: el trabajo la lleva' $trab.ncu 3
$cxSinNombre = @{ip='192.168.4.30'; puerto=503; gws=$null; multi=$null; etiqueta='503'; to=8000; reint=1; nombre='IP suelta'}
Check 'ncu: sin nombre reconocible, vacia' ((Trabajos-Planta $cxSinNombre @(16)).ncu) $null

# --------------------------------------------------------------------------
#  Relacion entre el limite este y el oeste
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '== limite este contra limite oeste =='
function FilaTilt($mx, $mn) { return ,@([pscustomobject]@{NCU='9'; TCU=1; '41111 max_tilt_west_r1 [deg]'=$mx; '41125 min_tilt_east_r1 [deg]'=$mn; Estado='OK'}) }
Check 'par: -45 por debajo de 55, bien' (@(Sospechas-Lectura (FilaTilt '55' '-45')).Count) 0
Check 'par: +30 por debajo de 55, tambien bien' (@(Sospechas-Lectura (FilaTilt '55' '30')).Count) 0
Check 'par: los dos a 55, sin recorrido' (@(Sospechas-Lectura (FilaTilt '55' '55')).Count) 1
Check 'par: este por encima del oeste' (@(Sospechas-Lectura (FilaTilt '30' '55')).Count) 1
Check 'par: dice cual es el otro valor' ((@(Sospechas-Lectura (FilaTilt '55' '55'))[0].Motivo).Contains('55')) $true
Check 'par: marca el limite este, que es el que se corrige' ((@(Sospechas-Lectura (FilaTilt '55' '55'))[0].Variable).Contains('min_tilt')) $true
# sin una de las dos columnas no se puede comparar y no se inventa nada
$soloUna = @([pscustomobject]@{NCU='9'; TCU=1; '41125 min_tilt_east_r1 [deg]'='55'; Estado='OK'})
Check 'par: con una sola columna no dice nada' (@(Sospechas-Lectura $soloUna).Count) 0
# y la correccion propone la mayoria para la que el par ha marcado
$mezcla = @()
foreach ($t in 1..10) { $mezcla += [pscustomobject]@{NCU='9'; TCU=$t
  '41111 max_tilt_west_r1 [deg]'='55'
  '41125 min_tilt_east_r1 [deg]'=$(if ($t -eq 3) { '55' } else { '30' }); Estado='OK'} }
$cp = Correccion-DeLectura $mezcla
Check 'par: la correccion la recoge' (@($cp.filas).Count) 1
Check 'par: y propone la mayoria' (@($cp.filas)[0].Valor) '30'
Check 'par: sobre la TCU marcada' (@($cp.filas)[0].TCU) 3

# --------------------------------------------------------------------------
#  Test de motor: el limite de recorrido no es una averia
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '== veredicto del test de motor =='
# los dos sentidos bien
Check 'motor: los dos sentidos' (Motor-Veredicto 0.5 1810 -0.5 1750 0.5 -20.0).estado 'PASA'
Check 'motor: los dos sentidos no es limite' (Motor-Veredicto 0.6 1810 -0.6 1750 0.5 -20.0).limite $false
# el caso de Ayora: pegada al limite este, al este 0 mA
$vLim = Motor-Veredicto 0.6 1810 0.1 0 0.5 -54.9
Check 'motor: pegada al limite pasa' $vLim.estado 'PASA'
Check 'motor: y se marca como limite' $vLim.limite $true
Check 'motor: lo explica' ($vLim.detalle.Contains('limite')) $true
Check 'motor: dice desde donde' ($vLim.detalle.Contains('-54,9') -or $vLim.detalle.Contains('-54.9')) $true
# lo mismo al reves
$vLimW = Motor-Veredicto 0.1 0 -0.6 1750 0.5 54.9
Check 'motor: limite oeste tambien pasa' $vLimW.estado 'PASA'
Check 'motor: limite oeste marcado' $vLimW.limite $true
# atasco de verdad: hay corriente y no se mueve
$vAtasco = Motor-Veredicto 0.6 1810 0.0 1900 0.5 0.0
Check 'motor: corriente sin movimiento es fallo' $vAtasco.estado 'FALLA'
Check 'motor: y lo dice' ($vAtasco.detalle.Contains('mecanica')) $true
Check 'motor: el atasco no es limite' $vAtasco.limite $false
# nada de nada
Check 'motor: quieto y sin corriente' (Motor-Veredicto 0.0 0 0.0 0 0.5 0.0).estado 'FALLA'
Check 'motor: quieto con corriente' ((Motor-Veredicto 0.0 1800 0.0 1900 0.5 0.0).detalle.Contains('hay corriente')) $true
# polaridad al reves
$vInv = Motor-Veredicto -0.6 1810 0.6 1750 0.5 0.0
Check 'motor: sentido invertido' $vInv.estado 'FALLA'
Check 'motor: nombra la polaridad' ($vInv.detalle.Contains('INVERTIDO')) $true

Write-Host ''
Write-Host '== las cabeceras se ven pulsables =='
# El filtro esta desde la v7.4 pero nadie lo encontraba: no habia nada que
# dijera que la cabecera se pulsa. Ahora todas llevan una flechita.
Check 'cabecera: marca de pulsable' ($src.Contains("[char]0x25BE")) $true
Check 'cabecera: el asterisco marca el filtro activo' ($src.Contains('esta columna filtra')) $true
Check 'cabecera: se marcan al enganchar la tabla' ($src.Contains('# marca las cabeceras desde el principio')) $true
# las diez tablas de resultados tienen que estar enganchadas
$engancha = [regex]::Match($src, 'foreach \(\$tabla in @\(([^)]*)\)\) \{ Lv-Filtrable')
Check 'cabecera: hay linea que engancha las tablas' $engancha.Success $true
foreach ($t in @('lvL','lvD','lvG','lvA','lvV','lvP','lvFW','lvSat','lvH','lvN','lvE','lvI')) {
    Check "cabecera: ${t} filtrable" ($engancha.Groups[1].Value.Contains("`$$t")) $true
}
# y no puede quedarse ninguna fuera: si se crea una tabla nueva hay que anadirla
# a esa linea, O llamar a Lv-Filtrable con ella (las tablas de los dialogos no
# existen al arrancar, se crean al abrirse y se enganchan alli mismo)
$todas = @([regex]::Matches($src, '\$(lv\w+) = New-Object System\.Windows\.Forms\.ListView') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$sueltas = @($todas | Where-Object { -not $engancha.Groups[1].Value.Contains("`$$_") -and -not $src.Contains("Lv-Filtrable `$$_") })
Check 'cabecera: ninguna tabla sin filtro' ($sueltas -join ',') ''
Check 'cabecera: la tabla de la comparacion tambien filtra' ($src.Contains('Lv-Filtrable $lvX')) $true

Write-Host ''
Write-Host '== parte de averias para WhatsApp =='
$diagWa = @(
  [pscustomobject]@{NCU='1'; TCU='NCU'; Salud='AVISO';   Alarmas='reloj NCU: 2026-08-06 04:10'}
  [pscustomobject]@{NCU='1'; TCU=14;    Salud='ALARMA';  Alarmas='eje bloqueado'}
  [pscustomobject]@{NCU='1'; TCU=2;     Salud='OK';      Alarmas=''}
  [pscustomobject]@{NCU='1'; TCU=22;    Salud='AVISO';   Alarmas='SoC bajo (L1)'}
  [pscustomobject]@{NCU='3'; TCU=9;     Salud='OFFLINE'; Alarmas=''}
  [pscustomobject]@{NCU='3'; TCU=5;     Salud='OK';      Alarmas=''}
  [pscustomobject]@{NCU='3'; TCU='HSU2'; Salud='ALARMA'; Alarmas='ALARMA VIENTO'}
)
$wa = Texto-NoOk $diagWa 'Ayora' '06/08/2026 04:15' ''
$lin = @($wa -split "`r`n")
Check 'wa: la planta en la primera linea' ($lin[0]) 'Ayora - 06/08/2026 04:15'
Check 'wa: cuenta los no OK' ($lin[1]) 'NO OK: 5 de 7 equipos revisados.'
Check 'wa: agrupa por NCU' ($wa.Contains('*NCU 1* (3)')) $true
Check 'wa: y la otra NCU' ($wa.Contains('*NCU 3* (2)')) $true
Check 'wa: las OK no salen' ($wa.Contains('TCU 2:') -or $wa.Contains('TCU 5:')) $false
Check 'wa: la TCU con su alarma' ($wa.Contains('- TCU 14: ALARMA - eje bloqueado')) $true
Check 'wa: sin alarma no deja guion suelto' ($wa.Contains('- TCU 9: OFFLINE')) $true
Check 'wa: la fila de la NCU se lee' ($wa.Contains('- La NCU: AVISO')) $true
Check 'wa: la HSU conserva su nombre' ($wa.Contains('- HSU2: ALARMA - ALARMA VIENTO')) $true
Check 'wa: ordena las TCUs' ($wa.IndexOf('TCU 14') -lt $wa.IndexOf('TCU 22')) $true
# filtrado por una NCU: es lo que se le manda a un tecnico concreto
$wa1 = Texto-NoOk $diagWa 'Ayora' '06/08/2026 04:15' '1'
Check 'wa: por NCU lo dice en la cabecera' (@($wa1 -split "`r`n")[0]) 'Ayora - NCU 1 - 06/08/2026 04:15'
Check 'wa: por NCU cuenta solo la suya' (@($wa1 -split "`r`n")[1]) 'NO OK: 3 de 4 equipos revisados.'
Check 'wa: por NCU no cuela la otra' ($wa1.Contains('NCU 3')) $false
# planta sana
$waOk = Texto-NoOk @([pscustomobject]@{NCU='1'; TCU=1; Salud='OK'; Alarmas=''}) 'Ayora' '' ''
Check 'wa: todo OK lo dice' ($waOk.Contains('Todo OK: 1 equipos revisados')) $true
Check 'wa: sin fecha no deja guion colgando' (@($waOk -split "`r`n")[0]) 'Ayora'
Check 'wa: diagnostico vacio no revienta' ((Texto-NoOk @() 'Ayora' '' '').Contains('Todo OK')) $true

Write-Host ''
Write-Host '== plan de firmware: que TCUs faltan y en que version estan =='
$invFw = @(
  [pscustomobject]@{NCU='1'; TCU=1; FW='v1.6.0 (map 1)'; Nota='OK'}
  [pscustomobject]@{NCU='1'; TCU=2; FW='v1.4.3 (map 1)'; Nota='OK'}
  [pscustomobject]@{NCU='1'; TCU=3; FW='v1.4.3 (map 1)'; Nota='OK'}
  [pscustomobject]@{NCU='1'; TCU=7; FW='v1.5.1 (map 1)'; Nota='OK'}
  [pscustomobject]@{NCU='2'; TCU=4; FW=''; Nota='GatewayTargetNoResponse (0x0B)'}
)
$gwFw = @{ '1' = @(@{puerto=503; ini=1; fin=40}); '2' = @(@{puerto=503; ini=1; fin=40}) }
$pf = Plan-Firmware $invFw 'v1.6.0' $gwFw @()
Check 'fw: tres pendientes' $pf.pendientes 3
Check 'fw: una al dia' $pf.al_dia 1
Check 'fw: una sin respuesta' (@($pf.sin_respuesta).Count) 1
Check 'fw: hay detalle por TCU' (@($pf.detalle).Count) 3
Check 'fw: el detalle dice que version tiene' (@($pf.detalle | Where-Object { $_.TCU -eq 2 })[0].FW) 'v1.4.3 (map 1)'
Check 'fw: y a cual va' (@($pf.detalle | Where-Object { $_.TCU -eq 2 })[0].Objetivo) 'v1.6.0'
Check 'fw: lleva el gateway' (@($pf.detalle | Where-Object { $_.TCU -eq 7 })[0].Puerto) '503'
Check 'fw: la que ya esta al dia no sale' (@($pf.detalle | Where-Object { $_.TCU -eq 1 }).Count) 0
Check 'fw: la muda tampoco' (@($pf.detalle | Where-Object { $_.TCU -eq 4 }).Count) 0
Check 'fw: el detalle viene ordenado' ((@($pf.detalle | ForEach-Object { $_.TCU }) -join ',')) '2,3,7'
# los tramos siguen siendo los del updater: 2-3 juntos y 7 aparte
Check 'fw: dos tramos' (@($pf.tramos).Count) 2
Check 'fw: el primero agrupa 2-3' (@($pf.tramos)[0].Hasta) 3
# toda la flota al dia: sin detalle y sin tramos
$pfOk = Plan-Firmware @([pscustomobject]@{NCU='1'; TCU=1; FW='v1.6.0'; Nota='OK'}) 'v1.6.0' $gwFw @()
Check 'fw: nada pendiente, sin detalle' (@($pfOk.detalle).Count) 0

# --- SoC: con bateria baja el bootloader no instala, hay que verlo ANTES ---
Write-Host ''
Write-Host '== bateria de las pendientes de firmware =='
$diagFw = @(
  [pscustomobject]@{NCU='1'; TCU=2; SoC='88'}
  [pscustomobject]@{NCU='1'; TCU=3; SoC='31'}
  [pscustomobject]@{NCU='1'; TCU=7; SoC='62 %'}
)
$pfS = Plan-Firmware $invFw 'v1.6.0' $gwFw $diagFw
Check 'soc: se cruza con el diagnostico' (@($pfS.detalle | Where-Object { $_.TCU -eq 2 })[0].SoC) '88'
Check 'soc: admite el simbolo de porcentaje' (@($pfS.detalle | Where-Object { $_.TCU -eq 7 })[0].SoC) '62'
Check 'soc: 88 no es bajo' (@($pfS.detalle | Where-Object { $_.TCU -eq 2 })[0].SoC_bajo) $false
Check 'soc: 31 si es bajo' (@($pfS.detalle | Where-Object { $_.TCU -eq 3 })[0].SoC_bajo) $true
Check 'soc: cuenta las de bateria baja' $pfS.con_soc_bajo 1
Check 'soc: ninguna sin SoC' $pfS.sin_soc 0
# sin diagnostico no se inventa una bateria
Check 'soc: sin diagnostico queda vacio' (@($pf.detalle)[0].SoC) ''
Check 'soc: y no las da por buenas' (@($pf.detalle)[0].SoC_bajo) $false
Check 'soc: cuenta las que no se saben' $pf.sin_soc 3
Check 'soc: ninguna marcada como baja' $pf.con_soc_bajo 0
# el umbral esta a la vista y es el mismo que se enseña en el aviso
Check 'soc: umbral definido' ($SOC_MIN_OTA -gt 0) $true

Write-Host ''
Write-Host '== la auditoria no se cree la primera lectura =='
# El caso real: "esperado -10, leido -10, DESVIACION". La comparacion cruda
# fallo por una respuesta descolocada y al releer daba el valor bueno.
Check 'aud: igual es igual' (Aud-Igual '-10' '-10') $true
Check 'aud: distinto es distinto' (Aud-Igual '-10' '0') $false
Check 'aud: el hexadecimal no distingue mayusculas' (Aud-Igual '0x0A00' '0x0a00') $true
Check 'aud: hexadecimales distintos' (Aud-Igual '0x0A00' '0x0000') $false
# la X mayuscula: ".StartsWith('0x')" la distingue, asi que con 0X a los DOS
# lados se caia a comparacion de texto. Funcionaba de milagro.
Check 'aud: la X mayuscula en los dos lados' (Aud-Igual '0X0A00' '0X0a00') $true
Check 'aud: X mayuscula contra minuscula' (Aud-Igual '0X0A00' '0x0a00') $true
Check 'aud: y sigue cazando la diferencia con X mayuscula' (Aud-Igual '0X0A00' '0X0000') $false
# ceros a la izquierda: mismo registro, distinto texto
Check 'aud: ceros a la izquierda' (Aud-Igual '0xA00' '0x0A00') $true
Check 'aud: 0x0 y 0x0000' (Aud-Igual '0x0' '0x0000') $true
# el mismo valor escrito en decimal
Check 'aud: decimal contra hexadecimal' (Aud-Igual '2560' '0x0A00') $true
Check 'aud: y al reves' (Aud-Igual '0x0A00' '2560') $true
Check 'aud: decimal distinto del hexadecimal' (Aud-Igual '2561' '0x0A00') $false
# lo que no es numero no se cuela como cero
Check 'aud: hexadecimal contra texto' (Aud-Igual '0x0A00' 'AUTO') $false
Check 'aud: hexadecimal contra vacio' (Aud-Igual '0x0A00' '') $false
Check 'aud: 0x sin digitos no es hexadecimal' (Aud-Hex '0x') $null
Check 'aud: coma o punto decimal' (Aud-Igual '6,5' '6.5') $true
Check 'aud: decimales distintos' (Aud-Igual '6,5' '6,6') $false
Check 'aud: 30 y 30,0 son lo mismo' (Aud-Igual '30' '30,0') $true
Check 'aud: negativos' (Aud-Igual '-45' '-45,000') $true
Check 'aud: texto que no es numero' (Aud-Igual 'AUTO' 'AUTO') $true
Check 'aud: vacio contra valor' (Aud-Igual '30' '') $false

Write-Host ''
Write-Host '== auditar sin volver a leer =='
$lecAud = @(
  [pscustomobject]@{NCU='9'; TCU=34; '41069 safe_pos_sign_threshold'='-10'; '41125 min_tilt_east_r1 [deg]'='30'; Estado='OK'}
  [pscustomobject]@{NCU='9'; TCU=35; '41069 safe_pos_sign_threshold'='0';  '41125 min_tilt_east_r1 [deg]'='30'; Estado='OK'}
  [pscustomobject]@{NCU='9'; TCU=36; '41069 safe_pos_sign_threshold'='';   '41125 min_tilt_east_r1 [deg]'='-';  Estado='no responde'}
)
$idx = Aud-Indice $lecAud
Check 'indice: coge los valores' ($idx['9|34|41069 safe_pos_sign_threshold']) '-10'
Check 'indice: y los de la otra TCU' ($idx['9|35|41069 safe_pos_sign_threshold']) '0'
Check 'indice: las celdas vacias no entran' ($idx.ContainsKey('9|36|41069 safe_pos_sign_threshold')) $false
Check 'indice: ni los guiones' ($idx.ContainsKey('9|36|41125 min_tilt_east_r1 [deg]')) $false
Check 'indice: Estado no es una variable' ($idx.ContainsKey('9|34|Estado')) $false
Check 'indice: lectura vacia' ((Aud-Indice @()).Count) 0
# con el indice, auditar "-10" contra la 34 es conforme y contra la 35 no
Check 'indice: la 34 cuadra con el preset' (Aud-Igual '-10' $idx['9|34|41069 safe_pos_sign_threshold']) $true
Check 'indice: la 35 no' (Aud-Igual '-10' $idx['9|35|41069 safe_pos_sign_threshold']) $false

Write-Host ''
Write-Host '== cada bloque con su tabla de bits =='
# El bloque compat de la NCU (30500+) es SU mapa, no el de la TCU. Coinciden en
# casi todo, pero donde la NCU dice Reserved la tabla de la TCU se inventaba una
# alarma: el bit 12 de Alarms2 salia como "com con NCU perdida" en TCUs que
# estaban comunicando.
Check 'bits: el 12 de Alarms2 no existe en la NCU' ($BITS_AL2_NCU.ContainsKey(12)) $false
Check 'bits: pero si en la TCU' ($BITS_AL2.ContainsKey(12)) $true
Check 'bits: el 10 de Alarms1 tampoco (bateria desconectada)' ($BITS_AL1_NCU.ContainsKey(10)) $false
Check 'bits: ni el 6 ni el 9' (($BITS_AL1_NCU.ContainsKey(6)) -or ($BITS_AL1_NCU.ContainsKey(9))) $false
Check 'bits: ni el 15 de Alarms2' ($BITS_AL2_NCU.ContainsKey(15)) $false
# y los que si coinciden tienen que estar en las dos
foreach ($b in @(2,4,7,8,11,12,13,14,15)) { Check "bits: Alarms1 NCU tiene el $b" ($BITS_AL1_NCU.ContainsKey($b)) $true }
foreach ($b in @(2,4,5,8,14)) { Check "bits: Alarms2 NCU tiene el $b" ($BITS_AL2_NCU.ContainsKey($b)) $true }
# el driver de motor no esta en el mapa de la NCU: fuera de su mascara critica
Check 'bits: la mascara de la NCU no lleva el driver' (($CRIT_AL2_NCU -band (1 -shl 15)) -eq 0) $true
Check 'bits: pero si corto, sobrecorriente y eje' (($CRIT_AL2_NCU -band ((1 -shl 4) -bor (1 -shl 5) -bor (1 -shl 8))) -eq $CRIT_AL2_NCU) $true
# y el bloque compat tiene que decodificar con la tabla de la NCU, no con la otra
$iCom = $src.IndexOf('function Ncu-DiagCompat'); $fCom = $src.IndexOf('function Ncu-HsuCompat')
$com = $src.Substring($iCom, $fCom - $iCom)
Check 'bits: el compat usa la tabla de la NCU' ($com.Contains('$BITS_AL1_NCU) + @(Bits-Texto $al2 $BITS_AL2_NCU)')) $true
Check 'bits: y no la de la TCU' ($com.Contains('$BITS_AL1)')) $false
Check 'bits: con su mascara critica' ($com.Contains('$CRIT_AL2_NCU')) $true
# una TCU con el bit 12 puesto ya no inventa la alarma
Check 'bits: el 12 solo no da texto' ((@(Bits-Texto 0x1000 $BITS_AL2_NCU)).Count) 0
Check 'bits: pero el eje bloqueado si' ((@(Bits-Texto 0x0100 $BITS_AL2_NCU))[0]) 'eje bloqueado'

Write-Host ''
Write-Host '== auditoria de baterias =='
Check 'mediana: impar' (Mediana @(1,5,3)) 3
Check 'mediana: par' (Mediana @(1,3,5,7)) 4
Check 'mediana: uno solo' (Mediana @(9)) 9
Check 'mediana: vacia' (Mediana @()) $null
Check 'mediana: aguanta que haya rotos' (Mediana @(26000,26100,25900,12000,26050)) 26000
function BatFila($ncu,$tcu,$v,$i,$soc,$soh,$tb,$al='',$salud='OK',$dia=1) {
  return [pscustomobject]@{NCU=$ncu; TCU=$tcu; Salud=$salud; Vbat_mV=$v; Ibat_mA=$i; SoC=$soc; SoH=$soh; Tbat_C=$tb; Alarmas=$al; Dia=$dia}
}
# flota sana: 20 TCUs a 26 V, 90 %
$flota = @()
foreach ($t in 1..20) { $flota += BatFila '9' $t 26000 500 90 95 25 }
Check 'bat: flota sana no da nada' (@(Bat-Auditar $flota).Count) 0
# la del log de anoche: sin bateria
$conMala = @($flota) + @(BatFila '9' 21 0 0 0 0 20 'bateria desconectada; SoC critico')
$rB = @(Bat-Auditar $conMala)
Check 'bat: detecta la sin bateria' (@($rB | Where-Object { $_.Tipo -eq 'Sin bateria' }).Count) 1
Check 'bat: y es alarma' (@($rB | Where-Object { $_.Tipo -eq 'Sin bateria' })[0].Gravedad) 'ALARMA'
Check 'bat: sin bateria no repite mas hallazgos de esa TCU' (@($rB | Where-Object { $_.TCU -eq 21 }).Count) 1
# no carga: corriente cero con la bateria a medias
$rC = @(Bat-Auditar (@($flota) + @(BatFila '9' 22 25000 5 60 95 25)))
Check 'bat: detecta que no carga' (@($rC | Where-Object { $_.Tipo -eq 'No carga' }).Count) 1
# pero con la bateria llena, corriente cero es normal
$rD = @(Bat-Auditar (@($flota) + @(BatFila '9' 23 26000 5 100 95 25)))
Check 'bat: llena y sin corriente no es problema' (@($rD | Where-Object { $_.Tipo -eq 'No carga' }).Count) 0
# salud degradada
Check 'bat: SoH bajo' (@(Bat-Auditar (@($flota) + @(BatFila '9' 24 26000 500 90 45 25))) | Where-Object { $_.Tipo -eq 'Salud baja' }).Count 1
# temperatura
Check 'bat: temperatura alta' (@(Bat-Auditar (@($flota) + @(BatFila '9' 25 26000 500 90 95 61))) | Where-Object { $_.Tipo -eq 'Temperatura' }).Count 1
# fuera de la flota: 22,5 V esta dentro de rango pero la flota va a 26
$rE = @(Bat-Auditar (@($flota) + @(BatFila '9' 26 22500 300 88 95 25)))
Check 'bat: la que se sale de la flota' (@($rE | Where-Object { $_.Tipo -eq 'Fuera de la flota' }).Count) 1
Check 'bat: y no la llama fuera de rango' (@($rE | Where-Object { $_.TCU -eq 26 -and $_.Tipo -eq 'Tension baja' }).Count) 0
# las OFFLINE no cuentan: sus datos son de hace horas
$rF = @(Bat-Auditar (@($flota) + @(BatFila '9' 27 0 0 0 0 0 '' 'OFFLINE')))
Check 'bat: las OFFLINE no entran' (@($rF | Where-Object { $_.TCU -eq 27 }).Count) 0
# la fila de la NCU tampoco
$rG = @(Bat-Auditar (@($flota) + @([pscustomobject]@{NCU='9'; TCU='NCU'; Salud='ALARMA'; Vbat_mV=0; Ibat_mA=0; SoC=0; SoH=0; Tbat_C=0; Alarmas=''})))
Check 'bat: la fila de la NCU no entra' (@($rG | Where-Object { "$($_.TCU)" -eq 'NCU' }).Count) 0
Check 'bat: diagnostico vacio no revienta' (@(Bat-Auditar @()).Count) 0
# La tabla de baterias: una fila por TCU con lo que ya trae el diagnostico
$diagB = @(
    [pscustomobject]@{NCU='9'; TCU=1; Salud='OK'; SoC=90; SoH=95; Vbat_mV=26000; Ibat_mA=500
                      Vpanel_mV=18000; Ientrada_mA=700; Tbat_C='22,0'; Tpcb_C='25,0'; Dia=1; Alarmas=''}
    [pscustomobject]@{NCU='9'; TCU=2; Salud='OFFLINE'; SoC=''; SoH=''; Vbat_mV=''; Ibat_mA=''
                      Vpanel_mV=''; Ientrada_mA=''; Tbat_C=''; Tpcb_C=''; Dia=''; Alarmas='sin datos'}
    [pscustomobject]@{NCU='9'; TCU='NCU'; Salud='OK'; Alarmas='NCU responde'}
)
$tb = @(Bat-Tabla $diagB @([pscustomobject]@{NCU='9'; TCU=1; Tipo='Carga baja'}))
Check 'tabla: una fila por TCU, sin la de la NCU' ($tb.Count) 2
Check 'tabla: lleva el panel' ($tb[0].Vpanel_mV) '18000'
Check 'tabla: y la corriente de entrada' ($tb[0].Ientrada_mA) '700'
Check 'tabla: el dia en claro' ($tb[0].Dia) 'si'
Check 'tabla: el estado sale de la auditoria' ($tb[0].Estado) 'Carga baja'
Check 'tabla: la muda dice sin datos' ($tb[1].Estado) 'sin datos'
Check 'tabla: sin hallazgos, OK' ((Bat-Tabla $diagB)[0].Estado) 'OK'
Check 'tabla: varios hallazgos en la misma TCU' ((Bat-Tabla $diagB @(
    [pscustomobject]@{NCU='9'; TCU=1; Tipo='Carga baja'}
    [pscustomobject]@{NCU='9'; TCU=1; Tipo='No carga'}))[0].Estado) 'Carga baja; No carga'
Check 'tabla: diagnostico vacio' ((@(Bat-Tabla @())).Count) 0
# la pestana existe y no vuelve a leer nada
Check 'tabla: hay pestana' ($src.Contains("tabB.Text = 'Baterias'")) $true
Check 'tabla: con su tabla' ($src.Contains('$lvB = New-Object System.Windows.Forms.ListView')) $true
Check 'tabla: y sus botones' (($src.Contains('$btnBVer.Add_Click')) -and ($src.Contains('$btnBCsv.Add_Click'))) $true
# Las cabeceras se cachean para poder marcarlas con la flechita. 'Leer variable'
# rehace las columnas en cada lectura -una por variable- y la copia vieja se
# escribia encima: los tres primeros nombres salian 'TCU', 'Valor' y 'Estado'.
$flecha = [char]0x25BE
Check 'cabeceras: si no cambian, se respeta la copia' ((Cab-Vigentes @('NCU','TCU','Estado') @("NCU$flecha", "TCU$flecha", "Estado$flecha")) -join ',') 'NCU,TCU,Estado'
# el caso del fallo: 3 columnas guardadas y 8 en la tabla
Check 'cabeceras: si cambian, mandan las de ahora' ((Cab-Vigentes @('TCU','Valor','Estado') @('NCU','TCU','41111 max_tilt_west_r1 [deg]','Estado')) -join ',') 'NCU,TCU,41111 max_tilt_west_r1 [deg],Estado'
Check 'cabeceras: sin copia, las de ahora' ((Cab-Vigentes @() @('NCU','TCU')) -join ',') 'NCU,TCU'
# y al recachear se quita la flechita y el asterisco de filtro, que no son nombre
Check 'cabeceras: se limpia la flechita' ((Cab-Vigentes @() @("NCU $flecha", "TCU$flecha*")) -join ',') 'NCU,TCU'
Check 'cabeceras: nunca se indexa fuera de la copia' (([regex]::Matches($src, '-lt @\(\$e\.cab\)\.Count')).Count -ge 3) $true
# 'Estado' en la tabla de Leer variable se leia como "coincide con el preset".
# No lo es: esa pestana lee, no compara. Quien compara es la Auditoria.
Check 'leer: la columna se llama Respuesta' ($src.Contains("lvL.Columns.Add('Respuesta'")) $true
Check 'leer: y lo dice al terminar' ($src.Contains('NO si el valor es el que toca')) $true
Check 'leer: y manda a Auditoria' ($src.Contains("pestana Auditoria con 'Usar la ultima lectura' marcado")) $true
# pero la propiedad sigue siendo Estado: el CSV y la auditoria van por ella
Check 'leer: la propiedad no cambia' ($src.Contains("@('NCU','TCU','Estado') -contains `$pr.Name")) $true
Check 'cabeceras: y los filtros viejos se tiran' ($src.Contains('if (@($e.cab).Count -ne $lv.Columns.Count) { $e.filtros = @{} }')) $true
Check 'tabla: filtrable como las demas' ($src.Contains('$lvC, $lvB, $lvT)) { Lv-Filtrable')) $true
Check 'tabla: sale del ultimo diagnostico' ($src.Contains('Bat-Tabla $script:UltimoDiag $script:UltimaBat')) $true
# y el modo directo ya trae panel y corriente de panel, que estan en el mapa
Check 'directo: lee desde el 30091' ($src.Contains('$r2 = FC03-Leer $tcu (Dir-Trama 30091) 8')) $true
Check 'directo: panel del 30092' ($src.Contains('Vpanel_mV = $r2[1]; Ientrada_mA = $r2[2]')) $true
Check 'directo: la bateria se corre al 3' ($src.Contains('Vbat_mV = $r2[3]; Ibat_mA = $ibat')) $true
Check 'directo: y el SoC al 5' ($src.Contains('SoC = ($r2[5] -band 0xFF)')) $true
# El bloque de la NCU trae tension de panel y corriente de entrada: con ellas se
# separa "el panel no da" de "da pero no llega", que mandan a sitios distintos.
function BatPanel($tcu, $vp, $ie, $soc, $ibat = 5, $dia = 1) {
    return [pscustomobject]@{NCU='9'; TCU=$tcu; Salud='OK'; Alarmas=''; SoC=$soc; SoH=95
        Vbat_mV=24000; Ibat_mA=$ibat; Tbat_C='22,0'; Vpanel_mV=$vp; Ientrada_mA=$ie; Dia=$dia}
}
$rP = @(Bat-Auditar (@($flota) + @(BatPanel 30 0 0 60)))
Check 'bat: panel sin tension' (@($rP | Where-Object { $_.Tipo -eq 'Panel sin tension' }).Count) 1
Check 'bat: y manda mirar el fusible' ((@($rP | Where-Object { $_.Tipo -eq 'Panel sin tension' })[0]).Detalle.Contains('fusible')) $true
$rE = @(Bat-Auditar (@($flota) + @(BatPanel 31 18000 0 60)))
Check 'bat: el panel da pero no llega' (@($rE | Where-Object { $_.Tipo -eq 'No entra corriente' }).Count) 1
# panel dando, corriente entrando y bateria cargando: no hay nada que decir
$rB = @(Bat-Auditar (@($flota) + @(BatPanel 32 18000 800 60 700)))
Check 'bat: cargando de verdad no da ningun aviso' (@($rB | Where-Object { $_.TCU -eq 32 }).Count) 0
# pero si entra corriente y la bateria no la coge, eso si es raro
$rN = @(Bat-Auditar (@($flota) + @(BatPanel 35 18000 800 60 5)))
Check 'bat: entra corriente pero la bateria no carga' ((@($rN | Where-Object { $_.TCU -eq 35 })[0]).Tipo) 'No carga'
# con la bateria llena no mira el panel: de noche o a plena carga es normal
$rL = @(Bat-Auditar (@($flota) + @(BatPanel 33 0 0 100)))
Check 'bat: con la bateria llena el panel a 0 es normal' (@($rL | Where-Object { $_.TCU -eq 33 }).Count) 0
# sin esos datos (modo directo) sigue el aviso generico de siempre
$rG = @(Bat-Auditar (@($flota) + @([pscustomobject]@{NCU='9'; TCU=34; Salud='OK'; Alarmas=''; SoC=60; SoH=95
    Vbat_mV=24000; Ibat_mA=5; Tbat_C='22,0'; Vpanel_mV=''; Ientrada_mA=''; Dia=1})))
Check 'bat: sin panel ni entrada, el aviso de antes' (@($rG | Where-Object { $_.Tipo -eq 'No carga' }).Count) 1
# DE NOCHE no se mira nada de eso: todos los paneles estan a 0 V y marcaba media
# planta. Es lo que se vio en el primer barrido nocturno.
$rNoche = @(Bat-Auditar (@($flota) + @(BatPanel 40 0 0 64 5 0)))
Check 'bat: de noche el panel a 0 no dice nada' (@($rNoche | Where-Object { $_.TCU -eq 40 -and $_.Tipo -like '*PANEL*' }).Count) 0
Check 'bat: ni el no carga' (@($rNoche | Where-Object { $_.TCU -eq 40 -and $_.Tipo -eq 'No carga' }).Count) 0
# de dia el mismo caso si avisa
Check 'bat: de dia el mismo caso si' (@(Bat-Auditar (@($flota) + @(BatPanel 41 0 0 64 5 1)) | Where-Object { $_.Tipo -eq 'Panel sin tension' }).Count) 1
# sin saber si es de dia, se calla: mejor eso que un aviso falso
$rSin = @(Bat-Auditar (@($flota) + @([pscustomobject]@{NCU='9'; TCU=42; Salud='OK'; Alarmas=''; SoC=64; SoH=95
    Vbat_mV=24000; Ibat_mA=5; Tbat_C='22,0'; Vpanel_mV=0; Ientrada_mA=0})))
Check 'bat: sin saber si es de dia, calla' (@($rSin | Where-Object { $_.TCU -eq 42 -and ($_.Tipo -like '*PANEL*' -or $_.Tipo -eq 'No carga') }).Count) 0
# el bit 7 del MSR es el que lo dice, en los dos caminos
Check 'bat: el dia sale del bit 7 del MSR' ($src.Contains('(($msr -shr 7) -band 1)')) $true
Check 'bat: y tambien en el modo directo' ($src.Contains('Dia = (($r1[0] -shr 7) -band 1)')) $true
# y el resumen no mezcla TCUs con avisos
Check 'bat: el resumen dice cuantos avisos' ($src.Contains('TCUs con algo que mirar, $nAv')) $true
# y los cuatro registros salen del bloque compat, no de direcciones inventadas
$iC2 = $src.IndexOf('function Ncu-DiagCompat'); $fC2 = $src.IndexOf('function Ncu-HsuCompat')
$com2 = $src.Substring($iC2, $fC2 - $iC2)
Check 'bat: panel del offset 5' ($com2.Contains('$w[$b+5]')) $true
Check 'bat: entrada del offset 12 con signo' ($com2.Contains('$ient = $w[$b+12]; if ($ient -gt 32767)')) $true
Check 'bat: motor de los offsets 8 y 9' (($com2.Contains('$w[$b+8]')) -and ($com2.Contains('$w[$b+9]'))) $true
# las de motor si se quedan vacias en directo: no estan en el mapa de la TCU
Check 'bat: en directo las de motor van vacias' ($src.Contains("Imotor_mA = ''; ImotorPico_mA = ''")) $true
Check 'bat: y van al CSV del registrador' ($src.Contains("'Vpanel_mV','Ientrada_mA','Imotor_mA','ImotorPico_mA'")) $true

Write-Host ''
Write-Host '== seccion de carga: el equipo dice si esta cargando =='
# El bloque compacto de 22 registros no trae el estado del cargador. Vive en el
# bloque largo (50000 + (TCU-1)*50), offsets 21..31 del mapa R7.1.
Check 'carga: sin alarmas y con energia = cargando' (Carga-Texto 0x000F 0) 'cargando'
Check 'carga: bit 5 = bateria llena' (Carga-Texto 0x002F 0) 'bateria llena'
Check 'carga: sin el bit 3 el cargador no esta habilitado' (Carga-Texto 0x0007 0) 'cargador NO habilitado'
Check 'carga: sin el bit 1 no hay energia' (Carga-Texto 0x000D 0) 'sin energia para cargar'
Check 'carga: se juntan los dos motivos' (Carga-Texto 0x0005 0) 'cargador NO habilitado; sin energia para cargar'
# una alarma manda sobre cualquier estado: es lo que hay que mirar
Check 'carga: la alarma tapa el estado' (Carga-Texto 0x000F (1 -shl 8)) 'SOBRECORRIENTE DE CARGA'
Check 'carga: timeout' (Carga-Texto 0x000F (1 -shl 9)) 'TIMEOUT DE CARGA'
Check 'carga: varias alarmas a la vez' (Carga-Texto 0x000F ((1 -shl 3) -bor (1 -shl 8))) 'fallo de com con el BQ; SOBRECORRIENTE DE CARGA'
Check 'carga: bits sin uso no inventan texto' (Carga-Texto 0x000F (1 -shl 14)) 'cargando'
# a quien hay que pedirselo: exactamente las TCUs de la tabla, agrupadas por NCU
$pedT = @(
    [pscustomobject]@{NCU='9'; TCU=3}, [pscustomobject]@{NCU='9'; TCU=1}
    [pscustomobject]@{NCU='12'; TCU=7}, [pscustomobject]@{NCU='9'; TCU=1}
    [pscustomobject]@{NCU='9'; TCU='NCU'}
)
$ped = Carga-Pedidos $pedT
Check 'carga: dos NCUs' ($ped.Keys.Count) 2
Check 'carga: ordenadas y sin repetir' ((@($ped['9']) -join ',')) '1,3'
Check 'carga: la otra NCU va aparte' ((@($ped['12']) -join ',')) '7'
Check 'carga: la fila de la NCU no se pide' ((@($ped['9']) -contains 0)) $false
Check 'carga: tabla vacia no pide nada' ((Carga-Pedidos @()).Keys.Count) 0
# y la columna solo se rellena cuando se ha leido
$tbC = @(Bat-Tabla $diagB $null @{'9|1' = [pscustomobject]@{Carga='cargando'}})
Check 'carga: la columna se rellena' ($tbC[0].Carga) 'cargando'
Check 'carga: y la que no se leyo va vacia' ($tbC[1].Carga) ''
Check 'carga: sin lectura, toda la columna vacia' ((Bat-Tabla $diagB)[0].Carga) ''
# la direccion, del mapa: 50000 + (TCU-1)*50 + 21, 11 registros
Check 'carga: la direccion sale del mapa' ($src.Contains('(50000 + ($tcu - 1) * 50 + 21)) 11')) $true
Check 'carga: corriente de panel con signo' ($src.Contains('$ip = $w[1]; if ($ip -gt 32767) { $ip -= 65536 }')) $true
Check 'carga: estado y alarmas de los offsets 29 y 31' ($src.Contains('EstadoCarga = $w[8]; ChargerState = $w[9]; AlarmasCarga = $w[10]')) $true
# es una lectura APARTE: el diagnostico no la hace, va por su boton
Check 'carga: tiene su boton' ($src.Contains("`$btnBCar.Text = 'LEER CARGA'")) $true
Check 'carga: con handler' ($src.Contains('$btnBCar.Add_Click(')) $true
$blqCar = $src.Substring($src.IndexOf('$btnBCar.Add_Click'), 2600)
Check 'carga: el handler la pide de verdad' ($blqCar.Contains('$c = Ncu-CargaCompat @($tcu)')) $true
Check 'carga: por el puerto de la NCU' ($blqCar.Contains('Modbus-Conectar $tr.ip $PUERTO_NCU')) $true
Check 'carga: con barra de avance' ($blqCar.Contains('Prog-Iniciar $tot')) $true
Check 'carga: y se puede cancelar' ($blqCar.Contains('if ($script:Cancelar) { break }')) $true
Check 'carga: repinta la tabla al acabar' ($blqCar.Contains('[void](Bat-Pintar)')) $true
Check 'carga: el diagnostico no la lee' ($src.Substring($src.IndexOf('function Ncu-DiagCompat'), 3000).Contains('Ncu-CargaCompat')) $false
Check 'carga: se olvida al diagnosticar de nuevo' ($src.Contains('$script:UltimaCarga = @{}   # lo leido de carga era de la lectura anterior')) $true
Check 'carga: y va cruda al JSON' ($src.Contains('carga=$script:UltimaCarga')) $true
Check 'carga: llave que no existe no se pide' ($src.Contains('if (-not $ped.ContainsKey($et)) { continue }')) $true

Write-Host ''
Write-Host '== modo y comisionado salen del mismo registro =='
# Los dos viven en 30001: leer uno y no ensenar el otro era tirar informacion,
# y antes de aplicar un modo a un rango hace falta saber en cual estan.
Check 'modo: bits 9:8 = 0 es OFF' (Modo-De 0x0000) 'OFF'
Check 'modo: 1 es MANUAL' (Modo-De 0x0100) 'MANUAL'
Check 'modo: 2 es AUTO' (Modo-De 0x0200) 'AUTO'
Check 'modo: 3 no deberia darse' (Modo-De 0x0300) '?'
Check 'modo: ignora los demas bits' (Modo-De 0xFDFF) 'MANUAL'
Check 'comis: bits 4:3 = 0 es comisionado' (Comis-De 0x0000) 0
Check 'comis: 3 es factory' (Comis-De 0x0018) 3
Check 'comis: ignora el modo' (Comis-De 0x0200) 0
# los dos a la vez, que es el caso real
$reg = 0x0210    # modo AUTO (2) + comisionado 2 (TCU configurado)
Check 'los dos del mismo registro: modo' (Modo-De $reg) 'AUTO'
Check 'los dos del mismo registro: comisionado' (Comis-De $reg) 2
# el diagnostico usa el MISMO helper, para que no haya dos verdades
Check 'diagnostico usa el helper' ($src.Contains('Modo-De $msr')) $true
Check 'el boton lo dice' ($src.Contains("btnPComis.Text = 'ESTADO Y MODO'")) $true

Write-Host ''
Write-Host '== la auditoria prepara la lectura, no la duplica =='
# Misma idea que en Cierre: las pestanas se pasan el trabajo, no se copian la
# logica. Leer en 'Leer variable' da ademas la segunda lectura de anomalos, el
# resumen de discrepancias y el historial, que la auditoria no tiene.
Check 'aud->leer: boton creado' ($src.Contains("`$btnAudLeer = New-Object System.Windows.Forms.Button")) $true
Check 'aud->leer: con handler' ($src.Contains('$btnAudLeer.Add_Click(')) $true
Check 'aud->leer: exige preset' ($src.Contains('es el que dice que variables hay que leer')) $true
Check 'aud->leer: carga las variables del preset' ($src.Contains('foreach ($v in @($script:PresetRef)) {')) $true
Check 'aud->leer: se lleva la seleccion' ($src.Contains('$txtLTcus.Text = $txtATcus.Text')) $true
Check 'aud->leer: salta a la pestana' ($src.Contains('$tabs.SelectedTab = $tabL')) $true
Check 'aud->leer: dice como volver' ($src.Contains("Usar la ultima lectura' marcado")) $true
# y no escribe ni lee nada por su cuenta: solo prepara
$blqAudLeer = $src.Substring($src.IndexOf('$btnAudLeer.Add_Click'), 1200)
Check 'aud->leer: no toca la planta' ($blqAudLeer.Contains('Modbus-Conectar')) $false

Write-Host ''
Write-Host '== la edad del dato es una columna, no una nota =='
# En modo via NCU no se lee al seguidor: se lee lo ultimo que la NCU le oyo, y
# cada uno tiene su propio retardo. Sin verlo no hay forma de saber de cuando
# es lo que se ve.
Check 'edad: columna en la tabla' ($src.Contains("lvG.Columns.Add('Edad s'")) $true
Check 'edad: la calcula el bloque compacto' ($src.Contains('Edad_s = $(if ($edad -ge 0)')) $true
Check 'edad: en blanco si no se sabe' ([regex]::IsMatch($src, 'Edad_s = \$\(if \(\$edad -ge 0\) \{ \$edad \} else \{ '''' \}\)')) $true
Check 'edad: la fila de la NCU no lleva' ($src.Contains("`$dn.SoC, '', `$dn.Alarmas")) $true
# el bloque de TCUs ya no repite la edad en la nota (el de HSUs es otro sitio)
$blqTcu = $src.Substring($src.IndexOf('function Ncu-DiagCompat'), 3000)
Check 'edad: ya no se repite en la nota' ($blqTcu.Contains('datos de hace')) $false
Check 'edad: pero avisa si es mucha' ($src.Contains('dato viejo')) $true
Check 'edad: por encima de 5 min es OFFLINE' ($src.Contains('$edad -gt 300')) $true

Write-Host ''
Write-Host '== el reloj de la NCU solo se menciona si esta mal =='
# Salia SIEMPRE en la columna de alarmas y parecia un problema.
Check 'reloj: en hora no dice nada' (@(Reloj-Nota @{fecha='2026-08-06 12:04:37 UTC'; desvio=3}).Count) 0
Check 'reloj: justo en el limite tampoco' (@(Reloj-Nota @{fecha='x'; desvio=$RELOJ_TOL_S}).Count) 0
Check 'reloj: pasado el limite avisa' (@(Reloj-Nota @{fecha='x'; desvio=600}).Count) 1
Check 'reloj: dice cuanto en minutos' ((@(Reloj-Nota @{fecha='x'; desvio=600})[0]).Contains('10 min')) $true
Check 'reloj: en horas si es mucho' ((@(Reloj-Nota @{fecha='x'; desvio=7200})[0]).Contains('2 h')) $true
Check 'reloj: en dias si es muchisimo' ((@(Reloj-Nota @{fecha='x'; desvio=259200})[0]).Contains('3 dias')) $true
Check 'reloj: lleva la marca que trae la NCU' ((@(Reloj-Nota @{fecha='2020-01-01 00:00:00 UTC'; desvio=999999})[0]).Contains('2020-01-01')) $true
Check 'reloj: sin fecha no dice nada' (@(Reloj-Nota @{fecha=''; desvio=999}).Count) 0
Check 'reloj: sin desvio medido tampoco' (@(Reloj-Nota @{fecha='x'; desvio=$null}).Count) 0
Check 'reloj: NCU muda no revienta' (@(Reloj-Nota $null).Count) 0

Write-Host ''
Write-Host '== barra de avance =='
Check 'avance: porcentaje' (Prog-Texto 50 200 0) '50/200  25%'
Check 'avance: al empezar no estima' (Prog-Texto 1 100 5) '1/100  1%'
Check 'avance: con ritmo estima' (Prog-Texto 10 100 20) '10/100  10%  ~3 min'
Check 'avance: en minutos si es largo' (Prog-Texto 100 1000 100) '100/1000  10%  ~15 min'
Check 'avance: en horas si es larguisimo' (Prog-Texto 10 1000 60) '10/1000  1%  ~1,7 h'
Check 'avance: al acabar no queda nada' (Prog-Texto 200 200 100) '200/200  100%'
Check 'avance: total 0 no revienta' (Prog-Texto 5 0 10) ''
Check 'avance: no pasa del 100' (Prog-Texto 210 200 10) '210/200  100%'
Check 'avance: sin tiempo medido, solo cuenta' (Prog-Texto 50 200 0) '50/200  25%'

Write-Host ''
Write-Host '== cierre post-actualizacion =='
$script:Cierre = @{}
Cierre-Marcar '9' 34 '' '' 'v1.6.0 (map 1)'
Check 'cierre: entra al verificar' ($script:Cierre.Count) 1
# La lista estuvo vacia siempre porque el alta no tenia quien la llamara: las
# pruebas ejercitaban la funcion, no el camino. Estas miran el codigo de
# VERIFICAR TRAS ACTUALIZAR, que es el unico sitio que da de alta.
$iVer = $src.IndexOf('$btnFwVerif.Add_Click'); $fVer = $src.IndexOf('# Preparar una TCU concreta antes')
$verif = $src.Substring($iVer, $fVer - $iVer)
Check 'cierre: verificar da de alta' ($verif.Contains('Cierre-Marcar')) $true
Check 'cierre: y solo en la rama de ACTUALIZADA' ($verif.IndexOf('Cierre-Marcar') -gt $verif.IndexOf('ACTUALIZADA ->')) $true
Check 'cierre: verificar guarda la lista' ($verif.Contains('Cierre-Guardar')) $true
Check 'cierre: verificar repinta la pestana' ($verif.Contains('Cierre-Pintar')) $true
# El firmware se instala con el updater del fabricante, fuera de aqui: si ese
# dia no se pasa por Firmware, lo actualizado no entra en ningun sitio. De ahi
# el alta a mano, que usa el mismo parser que el filtro de NCUs.
Check 'cierre: se pueden anadir a mano' ($src.Contains("btnCAdd.Text = 'Anadir TCUs...'")) $true
Check 'cierre: con handler' ($src.Contains('$btnCAdd.Add_Click')) $true
Check 'cierre: el alta a mano guarda' ($src.Contains('Cierre-Guardar (Nombre-Planta); Cierre-Pintar')) $true
Check 'alta: una sola TCU' ((Parse-ListaNums '26') -join ',') '26'
Check 'alta: varias sueltas' ((Parse-ListaNums '26,39') -join ',') '26,39'
Check 'alta: un rango' ((Parse-ListaNums '11-14') -join ',') '11,12,13,14'
Check 'alta: mezcla' ((Parse-ListaNums '11-13,20') -join ',') '11,12,13,20'
Check 'alta: repetidas una vez' ((Parse-ListaNums '26,26') -join ',') '26'
Check 'alta: vacio no da lista' ($null -eq (Parse-ListaNums '   ')) $true
# La lista guardada vacia volvia como una fila fantasma: NCU en blanco, TCU 0 y
# "falta parametros, NVM, modo AUTO", que ademas no se podia cerrar nunca. En
# PowerShell 5.1 -el del PC de planta- ConvertFrom-Json '[]' devuelve $null, y
# @($null) tiene UN elemento. Es la misma trampa del recuadro de la portada.
Check 'cierre: una lista vacia no inventa filas' ((Cierre-DeJson $null).Count) 0
Check 'cierre: ni una lista con nulos' ((Cierre-DeJson @($null, $null)).Count) 0
Check 'cierre: la TCU 0 no entra' ((Cierre-DeJson @([pscustomobject]@{ncu='9'; tcu=0})).Count) 0
Check 'cierre: ni una TCU que no es numero' ((Cierre-DeJson @([pscustomobject]@{ncu='9'; tcu='NCU'})).Count) 0
$cj = Cierre-DeJson @([pscustomobject]@{ncu='9'; tcu=34; fw='v1.6.0'; params='OK'; nvm=''; modo=''; desde='2026-08-06 10:00'})
Check 'cierre: la buena si entra' ($cj.Count) 1
Check 'cierre: con su clave' ($cj.ContainsKey('9|34')) $true
Check 'cierre: y sus marcas' ($cj['9|34'].params) 'OK'
Check 'cierre: la TCU como numero' ($cj['9|34'].tcu -is [int]) $true
# y el alta tampoco deja crear la TCU 0 desde ningun sitio
$antes = $script:Cierre.Count
Cierre-Marcar '9' 0 '' '' 'v1.6.0'
Check 'cierre: marcar la 0 no hace nada' ($script:Cierre.Count) $antes
Check 'cierre: guarda el FW' ($script:Cierre['9|34'].fw) 'v1.6.0 (map 1)'
Check 'cierre: recien actualizada no esta cerrada' (Cierre-Estado $script:Cierre['9|34']) 'falta parametros, NVM, modo AUTO'
Cierre-Marcar '9' 34 'params' 'OK'
Check 'cierre: con parametros, faltan dos' (Cierre-Estado $script:Cierre['9|34']) 'falta NVM, modo AUTO'
Cierre-Marcar '9' 34 'nvm' 'OK'
Cierre-Marcar '9' 34 'modo' 'OK'
Check 'cierre: con las tres, cerrada' (Cierre-Estado $script:Cierre['9|34']) 'CERRADA'
Check 'cierre: ya no esta pendiente' (@(Cierre-Pendientes).Count) 0
# parametros NOK no es lo mismo que sin comprobar: sigue sin cerrar
Cierre-Marcar '9' 34 'params' 'NOK'
Check 'cierre: parametros NOK no cierra' (Cierre-Estado $script:Cierre['9|34']) 'falta parametros'
# lo importante: auditar o diagnosticar la planta NO puede meter 754 TCUs
Cierre-MarcarSiEsta '10' 19 'modo' 'OK'
Check 'cierre: no da de alta a quien no esta' ($script:Cierre.Count) 1
Cierre-MarcarSiEsta '9' 34 'modo' 'MANUAL'
Check 'cierre: pero si actualiza a la que esta' ($script:Cierre['9|34'].modo) 'MANUAL'
Check 'cierre: y vuelve a faltar el modo' ((Cierre-Estado $script:Cierre['9|34']).Contains('modo AUTO')) $true
# varias TCUs
Cierre-Marcar '9' 35 '' '' 'v1.6.0'
Cierre-Marcar '11' 58 '' '' 'v1.6.0'
Check 'cierre: tres en la lista' ($script:Cierre.Count) 3
Check 'cierre: tres pendientes' (@(Cierre-Pendientes).Count) 3
# la lista sobrevive a cerrar el programa
Cierre-Guardar 'PruebaCierre'
$script:Cierre = @{}
Check 'cierre: vaciada' ($script:Cierre.Count) 0
Cierre-Cargar 'PruebaCierre'
Check 'cierre: se relee del disco' ($script:Cierre.Count) 3
Check 'cierre: con su estado' ($script:Cierre['9|34'].params) 'NOK'
Check 'cierre: y su FW' ($script:Cierre['11|58'].fw) 'v1.6.0'
Remove-Item (Cierre-Fichero 'PruebaCierre') -Force -ErrorAction SilentlyContinue
$script:Cierre = @{}
Check 'cierre: planta sin fichero empieza vacia' (@(Cierre-Pendientes).Count) 0

Write-Host ''
Write-Host '== buscador de acciones =='
Check 'buscar: sin acentos' (Buscar-Norm 'Diagnóstico Rápido') 'diagnostico rapido'
Check 'buscar: la ñ tambien' (Buscar-Norm 'Año') 'ano'
Check 'buscar: filtro vacio pasa todo' (Buscar-Casa 'lo que sea' '') $true
Check 'buscar: una palabra' (Buscar-Casa 'Flota / INVENTARIO -> CSV' 'csv') $true
Check 'buscar: varias palabras en cualquier orden' (Buscar-Casa 'Flota / INVENTARIO -> CSV' 'csv flota') $true
Check 'buscar: una palabra que no esta' (Buscar-Casa 'Flota / INVENTARIO -> CSV' 'csv pem') $false
Check 'buscar: encuentra con acento escrito sin el' (Buscar-Casa 'Diagnóstico' 'diagnostico') $true
Check 'buscar: no distingue mayusculas' (Buscar-Casa 'GUARDAR EN NVM' 'nvm') $true

Write-Host ''
Write-Host '== simular una escritura =='
$lecSim = @()
foreach ($t in 1..10) {
  $lecSim += [pscustomobject]@{NCU='1'; TCU=$t
    '41125 min_tilt_east_r1 [deg]'=$(if ($t -le 6) { '30' } else { '-45' })
    '41106 east_pitch [m]'='6'; Estado='OK'}
}
$sim = @(Simular-Escritura @(@{nombre='41125 min_tilt_east_r1 [deg]'; texto='30'}, @{nombre='41106 east_pitch [m]'; texto='6'}) $lecSim $null)
Check 'simular: dos variables' $sim.Count 2
Check 'simular: cambian las que no lo tienen' (@($sim | Where-Object { $_.Variable -like '*min_tilt*' })[0].Cambian) 4
Check 'simular: y las que ya lo tienen' (@($sim | Where-Object { $_.Variable -like '*min_tilt*' })[0].Iguales) 6
Check 'simular: la que no cambia nada' (@($sim | Where-Object { $_.Variable -like '*east_pitch*' })[0].Cambian) 0
# el reparto es lo que destapa que hay dos configuraciones a proposito
Check 'simular: enseña el reparto' ((@($sim | Where-Object { $_.Variable -like '*min_tilt*' })[0].Reparto).Contains('30 en 6')) $true
Check 'simular: y el otro valor' ((@($sim | Where-Object { $_.Variable -like '*min_tilt*' })[0].Reparto).Contains('-45 en 4')) $true
# una variable que no se leyo no se puede simular, y se dice
$simX = @(Simular-Escritura @(@{nombre='41111 max_tilt_west_r1 [deg]'; texto='55'}) $lecSim $null)
Check 'simular: variable no leida se marca' ($simX[0].Cambian) -1
# limitar a unas TCUs concretas
$simT = @(Simular-Escritura @(@{nombre='41125 min_tilt_east_r1 [deg]'; texto='30'}) $lecSim @(7,8))
Check 'simular: solo las TCUs pedidas' ($simT[0].Cambian) 2
Check 'simular: sin lectura no revienta' (@(Simular-Escritura @(@{nombre='x'; texto='1'}) @() $null)[0].Cambian) -1

Write-Host ''
Write-Host '== historial local =='
$hl = @(
  'fecha;ncu;tcu;variable;valor'
  '2026-08-01 10:00:00;9;34;41106 east_pitch [m];6'
  '2026-08-02 10:00:00;9;34;41106 east_pitch [m];6'
  '2026-08-03 10:00:00;9;34;41106 east_pitch [m];-0,7854'
  '2026-08-04 10:00:00;9;34;41106 east_pitch [m];-0,7854'
  '2026-08-05 10:00:00;9;35;41106 east_pitch [m];6'
)
$cb = @(Historial-Cambios $hl '' '' '')
Check 'historial: solo los cambios' $cb.Count 3
Check 'historial: el primero es la primera lectura' ($cb[0].Antes) ''
Check 'historial: el cambio dice de que a que' ($cb[1].Antes) '6'
Check 'historial: y el valor nuevo' ($cb[1].Valor) '-0,7854'
Check 'historial: la fecha del cambio' ($cb[1].Fecha) '2026-08-03 10:00:00'
Check 'historial: filtrar por TCU' (@(Historial-Cambios $hl '' '35' '').Count) 1
Check 'historial: filtrar por variable' (@(Historial-Cambios $hl '' '34' 'east_pitch').Count) 2
Check 'historial: variable que no esta' (@(Historial-Cambios $hl '' '' 'min_tilt').Count) 0
Check 'historial: la cabecera no cuenta' (@(Historial-Cambios @('fecha;ncu;tcu;variable;valor') '' '' '').Count) 0
Check 'historial: vacio no revienta' (@(Historial-Cambios @() '' '' '').Count) 0

Write-Host ''
Write-Host '== portada del informe =='
$mP = @{diag=@(
    [pscustomobject]@{NCU='1'; TCU=1; Salud='OK'}
    [pscustomobject]@{NCU='1'; TCU=2; Salud='ALARMA'}
    [pscustomobject]@{NCU='1'; TCU='NCU'; Salud='AVISO'}
    [pscustomobject]@{NCU='1'; TCU='HSU2'; Salud='OK'})
  inv=@([pscustomobject]@{FW='v1.6.0'}, [pscustomobject]@{FW='v1.4.3'}, [pscustomobject]@{FW='v1.6.0'})
  aud=@([pscustomobject]@{NCU='1'; TCU=2; Variable='x'})
  lectura=@([pscustomobject]@{NCU='1'; TCU=1; '41106 east_pitch [m]'='6'; Estado='OK'})}
$bl = @(Portada-Bloques $mP)
Check 'portada: hay recuadros' ($bl.Count -ge 4) $true
$op = @($bl | Where-Object { $_.titulo -like '*operativos*' })[0]
Check 'portada: no cuenta la NCU ni la HSU como seguidores' ($op.nota) '1 de 2 sin aviso ni alarma'
Check 'portada: el porcentaje' ($op.valor) '50 %'
Check 'portada: y va en rojo' ($op.clase) 'mal'
Check 'portada: cuenta las versiones de FW' (@($bl | Where-Object { $_.titulo -like '*firmware*' })[0].valor) '2'
Check 'portada: TCUs con desviacion' (@($bl | Where-Object { $_.titulo -like '*desviada*' })[0].valor) '1'
Check 'portada: sin datos no inventa recuadros' (@(Portada-Bloques @{diag=@(); inv=@(); aud=@(); lectura=@()}).Count) 0

Write-Host ''
Write-Host '== barrido en paralelo (contra el simulador) =='
# Lo que de verdad importa: que cada hilo se lleva SU conexion y devuelve lo
# mismo que en serie. Se usan tres esclavos del simulador con datos distintos.
$tareasPar = @(
  @{ncu=1; ip='127.0.0.1'; puerto=15020; to=4000; tcus=@(5)}
  @{ncu=2; ip='127.0.0.1'; puerto=15020; to=4000; tcus=@(6)}
  @{ncu=3; ip='127.0.0.1'; puerto=15020; to=4000; tcus=@(8)}
)
$cuerpoPrueba = {
    param($logica, $RaizTb, $t)
    Invoke-Expression $logica
    $r = @{ncu=$t.ncu; alarmas=''; error=''}
    try {
        Modbus-Conectar $t.ip $t.puerto $t.to
        $w = FC03-Leer ([byte]@($t.tcus)[0]) (Dir-Trama 30002) 1
        $r.alarmas = "0x{0:X4}" -f $w[0]
    } catch { $r.error = "$_" } finally { Modbus-Cerrar }
    return $r
}
$resPar = $null
$rutaTb = Join-Path $raizTb 'TCU_Toolbox.ps1'
try { $resPar = @(Paralelo-Ejecutar $tareasPar $cuerpoPrueba 3 $rutaTb) } catch { Write-Host "FAIL paralelo: $_"; $script:fallos++ }
if ($null -ne $resPar) {
    Check 'paralelo: vuelven las tres tareas' $resPar.Count 3
    Check 'paralelo: ninguna con error' (@($resPar | Where-Object { "$(@($_.salida)[0].error)" -ne '' }).Count) 0
    Check 'paralelo: cada hilo lee lo suyo' (@(@($resPar | ForEach-Object { @($_.salida)[0].alarmas }) | Sort-Object -Unique).Count -ge 2) $true
    # el mismo dato leido en serie tiene que coincidir
    Modbus-Conectar '127.0.0.1' 15020 4000
    $serie = "0x{0:X4}" -f (FC03-Leer 5 (Dir-Trama 30002) 1)[0]
    Modbus-Cerrar
    Check 'paralelo: coincide con el modo serie' (@($resPar | Where-Object { $_.tarea.ncu -eq 1 })[0].salida[0].alarmas) $serie
}
Check 'paralelo: lista vacia devuelve vacio' (@(Paralelo-Ejecutar @() $cuerpoPrueba 2 $rutaTb).Count) 0
Check 'paralelo: la logica se extrae del propio script' ((Logica-Propia $rutaTb).Contains('function Modbus-Transaccion')) $true
Check 'paralelo: y sin la ventana' ((Logica-Propia $rutaTb).Contains('New-Object System.Windows.Forms.Form')) $false
Check 'paralelo: PSScriptRoot cambiado por variable' ((Logica-Propia $rutaTb).Contains('$RaizTb')) $true

Write-Host ''
Write-Host '== verificar tras actualizar =='
# Se saltaba en silencio los tramos de otras NCUs y el resumen decia
# "0 pendientes" como si estuvieran bien, cuando ni se habian mirado.
Check 'verif: avisa de los tramos que no toca' ($src.Contains('NO se van a verificar')) $true
Check 'verif: los cuenta aparte' ($src.Contains('$saltados += [int]$t.TCUs')) $true
Check 'verif: no los da por buenos' ($src.Contains('no cuentan como buenas')) $true
Check 'verif: y sale en el rotulo' ($src.Contains('sin comprobar')) $true
# ademas de decirlo, marca la fila en la tabla
Check 'verif: dice cual se ha actualizado' ($src.Contains('ACTUALIZADA ->')) $true
Check 'verif: la pinta en la tabla' ($src.Contains('ACTUALIZADA: ya en $fw')) $true
Check 'verif: y la que sigue pendiente' ($src.Contains('SIGUE PENDIENTE: en $fw')) $true
Check 'verif: tambien las que no responden' ($src.Contains('sin respuesta al verificar')) $true
# la marca tiene que llegar a las filas escondidas por un filtro de columna
Check 'verif: marca tambien lo filtrado' ($src.Contains('$lvFW.Tag.orig')) $true
# y solo a la TCU exacta, no a un tramo que la contenga
Check 'verif: no marca tramos de varias' ($src.Contains('if ($de -ne $tcu -or $a -ne $tcu) { continue }')) $true
# La tabla del plan lleva VENTANAS, los rangos que se PEGAN en cada una y las
# TCUs sueltas. Con una ventana de una sola TCU las dos filas salian identicas
# columna a columna y parecian repetidas: la columna Fila dice que es cada una.
Check 'plan: columna que separa las filas' ($src.Contains("lvFW.Columns.Add('Fila'")) $true
Check 'plan: fila de ventana etiquetada' ($src.Contains("@('VENTANA', `$v.IP, `$v.Puerto")) $true
Check 'plan: fila de rango que pegar' ($src.Contains("@('PEGAR', `$v.IP, `$v.Puerto")) $true
Check 'plan: fila de TCU etiquetada' ($src.Contains("@('TCU', `$ips[`"`$(`$d.NCU)`"]")) $true
Check 'plan: y las que no responden' ($src.Contains("@('SIN RESPUESTA', `$ips[`"`$(`$m.ncu)`"]")) $true
# con un solo rango la fila de la ventana YA lo lleva: repetirlo era el ruido
Check 'plan: los rangos solo si hay mas de uno' ($src.Contains('if (@($v.Tramos).Count -gt 1) {')) $true
# Desde-Hasta con huecos dibujaba un rango que no existe: con 10-16 y 18-22
# ponia "de 10 a 22", la TCU 17 parecia estar dentro y abajo no tenia fila
# porque no esta pendiente. Y el 12 de la columna TCUs no cuadraba con 13.
Check 'plan: con huecos no inventa un rango seguido' ($src.Contains("`$unTramo = (@(`$v.Tramos).Count -eq 1)")) $true
Check 'plan: y lo dice en las columnas' ($src.Contains("`$(if (`$unTramo) { `$v.Tramos[0].Desde } else { '(varios)' })")) $true
# la ventana con hueco sigue diciendo los rangos de verdad en su nota
$vHueco = @(Plan-Ventanas @([pscustomobject]@{NCU='10'; Puerto='503'; Desde=10; Hasta=16; TCUs=7},
                            [pscustomobject]@{NCU='10'; Puerto='503'; Desde=18; Hasta=22; TCUs=5}) $ipsFw 20)[0]
Check 'plan: los dos tramos, sin el hueco' ($vHueco.Rangos) '10-16 + 18-22'
Check 'plan: y cuenta 12, no 13' ($vHueco.TCUs) 12
Check 'plan: con dos tramos hay filas PEGAR' (@($vHueco.Tramos).Count) 2
# y las TCUs van debajo de SU ventana, no en un bloque suelto al final
Check 'plan: cada TCU bajo su ventana' ($src.Contains('foreach ($d in @($detPorV[$k] | Sort-Object { [int]$_.TCU })) {')) $true
# y las mudas tambien: una TCU reiniciandose con el FW nuevo salia muda y su
# fila caia al final de la tabla, detras de las otras quince NCUs
Check 'plan: las mudas van por NCU' ($src.Contains('$mudasPorNcu = @{}')) $true
Check 'plan: y se pintan con su ventana' ($src.Contains('foreach ($m in @($mudasPorNcu["$($v.NCU)"])) { $lvFW.Items.Add((Fw-FilaMuda $m $ips)) | Out-Null }')) $true
Check 'plan: una sola vez por NCU' ($src.Contains('$mudasPuestas["$($v.NCU)"] = 1')) $true
Check 'plan: las de NCUs sin ventana, al final' ($src.Contains('if ($mudasPuestas.ContainsKey($k)) { continue }')) $true
Check 'plan: la fila muda sale de un solo sitio' ($src.Contains('function Fw-FilaMuda')) $true
Check 'plan: la ventana avisa de cuantas hay' ($src.Contains('sin respuesta, debajo')) $true
# el plan tambien en texto, para leerlo mientras se teclea en el updater
Check 'plan: lo escribe en la consola' ($src.Contains('foreach ($linea in @(Plan-Texto $ventanas $minTcu))')) $true
# y el CSV que te llevas es el de ventanas, no los tramos sueltos
Check 'plan: el CSV exporta las ventanas' ($src.Contains("Exportar-Csv `$(if (`$vv.Count -gt 0) { `$vv } else { `$script:PlanFw }) 'plan_firmware'")) $true
# verificar solo puede repintar filas de TCU: la del carril habla del tramo
Check 'verif: no toca la fila del carril' ($src.Contains("if (`"`$(`$it.SubItems[1].Text)`" -ne 'TCU') { continue }")) $true
Check 'verif: nota en la columna nueva' ($src.Contains('$it.SubItems[7].Text = $nota')) $true

Write-Host ''
Write-Host '== via NCU sin respuesta no inventa OFFLINEs =='
Check 'diag: se salta las TCUs si la NCU no contesta' ($src.Contains('no se sabe nada de sus $(@($tr.tcus).Count) TCUs')) $true
Check 'diag: y dice que desmarcar' ($src.Contains("Desmarca 'via NCU' para preguntarles una a una por el gateway")) $true
# "no contesta" y "rechaza" son diagnosticos distintos y hay que decir cual es
Check 'conexion: distingue el rechazo' ($src.Contains('conexion RECHAZADA')) $true
Check 'conexion: y el silencio' ($src.Contains('no contesta en 5 s')) $true
try { Modbus-Conectar '127.0.0.1' 15099 2000; Check 'conexion: puerto cerrado avisa' 'sin excepcion' 'rechazada' }
catch { Check 'conexion: puerto cerrado avisa' ("$_".Contains('RECHAZADA') -or "$_".Contains('no contesta')) $true }

Write-Host ''
Write-Host '== los usuarios se guardan de verdad =='
# El fallo de la v7.4: el alta creaba el usuario, no lo guardaba, y al reabrir
# lo volvia a pedir. Aqui se hace el viaje entero: crear, guardar, releer del
# disco y entrar con esa contrasena.
if (Test-Path $FICH_USUARIOS) { Remove-Item $FICH_USUARIOS -Force }
Check 'usuarios: se parte sin fichero' (@(Usuarios-Cargar).Count) 0
$admin = Usuario-Nuevo 'jefe' 'Jefe de planta' 'admin' 'clave-larga-1'
Usuarios-Guardar @($admin)
Check 'usuarios: el fichero existe' (Test-Path $FICH_USUARIOS) $true
$releidos = @(Usuarios-Cargar)
Check 'usuarios: se relee uno' $releidos.Count 1
Check 'usuarios: con su rol' $releidos[0].rol 'admin'
Check 'usuarios: entra con su clave tras releer' ((Usuario-Validar $releidos 'jefe' 'clave-larga-1').nombre) 'Jefe de planta'
Check 'usuarios: y no con otra' (Usuario-Validar $releidos 'jefe' 'clave-larga-2') $null
Check 'usuarios: el fichero no lleva la clave en claro' ((Get-Content $FICH_USUARIOS -Raw).Contains('clave-larga-1')) $false
# alta de un segundo usuario sobre la lista releida
Usuarios-Guardar (@($releidos) + (Usuario-Nuevo 'tec' 'Tecnico' 'tecnico' 'otra-clave'))
$dos = @(Usuarios-Cargar)
Check 'usuarios: ahora hay dos' $dos.Count 2
Check 'usuarios: el primero sigue entrando' ((Usuario-Validar $dos 'jefe' 'clave-larga-1') -ne $null) $true
Check 'usuarios: y el segundo tambien' ((Usuario-Validar $dos 'tec' 'otra-clave').rol) 'tecnico'
Remove-Item $FICH_USUARIOS -Force

Write-Host ''
Write-Host '== la trampa de GetNewClosure =='
# Por que fallaba: dentro de un .GetNewClosure() el ambito "script:" es el del
# modulo que crea el propio closure, no el del script. Escribir ahi no se ve
# desde fuera. Mutar un objeto capturado si funciona, y es lo que se usa ahora.
function Prueba-Closure {
    $caja = @{ v = $null }
    $sb = { $script:NoSeVe = 'perdido'; $caja.v = 'llega' }.GetNewClosure()
    & $sb
    return @{ porObjeto = $caja.v; porScript = $script:NoSeVe }
}
$pc = Prueba-Closure
Check 'closure: por objeto capturado llega' $pc.porObjeto 'llega'
Check 'closure: por $script: se pierde' $pc.porScript $null
Check 'closure: el codigo ya no usa $script:UsrNuevo' ($src.Contains('$script:UsrNuevo')) $false
Check 'closure: ni $script:UsrLogin' ($src.Contains('$script:UsrLogin')) $false
Check 'closure: el alta devuelve la hashtable' ($src.Contains('return $sal.usuario')) $true
Check 'arranque: comprueba que se guardo' ($src.Contains('no se ha podido guardar')) $true

Write-Host ''
Write-Host '== una tabla vacia tiene que decir por que =='
# La auditoria solo lista desviaciones: sin ninguna, la tabla se queda vacia y
# parece que no ha hecho nada. Tiene que dejar dicho ahi mismo que fue bien.
Check 'auditoria: fila cuando no hay desviaciones' ($src.Contains('Sin desviaciones: $nTcusOk TCUs conformes')) $true
Check 'auditoria: y se anade a la tabla' ($src.Contains('$lvA.Items.Add($vacio)')) $true
Check 'auditoria: distingue cancelado de conforme' ($src.Contains('cancelado antes de leer nada')) $true
# la fila informativa no puede colarse en las exportaciones
# "0 con desviaciones. 5 filas listadas" parecia una contradiccion: lo primero
# son TCUs y lo segundo variables, y esas 5 filas eran de "sin respuesta".
$fSin = @(1..5 | ForEach-Object { [pscustomobject]@{NCU='1'; TCU=7; Variable="v$_"; Nota='sin respuesta'} })
$rSin = Aud-Resumen $fSin 62 0 1
Check 'resumen: dice que las filas no son desviaciones' ($rSin.Contains('5 filas (5 sin respuesta)')) $true
Check 'resumen: y que las TCUs son TCUs' ($rSin.Contains('0 TCUs con desviaciones')) $true
$fDes = @(1..5 | ForEach-Object { [pscustomobject]@{NCU='2'; TCU=24; Variable="v$_"; Nota='DESVIACION'} })
Check 'resumen: cinco desviaciones de una TCU' ((Aud-Resumen $fDes 68 1 0).Contains('5 filas (5 desviaciones)')) $true
Check 'resumen: una sola fila en singular' ((Aud-Resumen @($fDes[0]) 1 1 0).Contains('1 fila (1 desviacion)')) $true
Check 'resumen: singular de TCU' ((Aud-Resumen $fDes 68 1 0).Contains('1 TCU con desviaciones')) $true
$fMix = @($fDes) + @($fSin)
Check 'resumen: mezcla las dos clases' ((Aud-Resumen $fMix 60 1 1).Contains('10 filas (5 desviaciones y 5 sin respuesta)')) $true

Check 'resumen: la nota con motivo tambien cuenta' ((Aud-Resumen @([pscustomobject]@{Nota='DESVIACION - fuera de rango'}) 1 1 0).Contains('1 desviacion')) $true
Check 'resumen: sin filas no habla de la tabla' ((Aud-Resumen @() 70 0 0).Contains('En la tabla')) $false
# Una TCU puede tener desviaciones Y variables mudas: contaba solo como "sin
# respuesta" y su linea no salia, pero sus filas SI estaban en la tabla. De ahi
# "3 TCUs con desviaciones" con 6 desviaciones listadas.
$fMix2 = @(1..6 | ForEach-Object { [pscustomobject]@{Nota='DESVIACION'} }) + @(1..28 | ForEach-Object { [pscustomobject]@{Nota='sin respuesta'} })
$rMix = Aud-Resumen $fMix2 42 3 8 2
Check 'resumen: dice cuantas mudas tienen ademas desviaciones' ($rMix.Contains('(de esas, 2 con desviaciones ademas)')) $true
Check 'resumen: y las cuentas siguen sumando el total' ($rMix.Contains('42 TCUs conformes | 3 TCUs con desviaciones | 8 TCUs sin respuesta')) $true
Check 'resumen: con la tabla completa' ($rMix.Contains('34 filas (6 desviaciones y 28 sin respuesta)')) $true
Check 'resumen: sin mixtas no lo menciona' ((Aud-Resumen $fMix2 42 5 6 0).Contains('ademas')) $false
# y la linea por TCU tiene que salir aunque la TCU ademas tenga variables mudas
Check 'auditoria: la linea sale aunque haya mudas' ($src.Contains('y $errTcu variables sin respuesta')) $true
Check 'auditoria: cuenta las mixtas' ($src.Contains('if ($desvTcu -gt 0) { $nMixtas++ }')) $true
# y la linea de descolocacion tiene que decir que NO esta en la tabla
Check 'resumen: la descolocacion se explica' ($src.Contains('NO estan en la tabla ni cuentan como desviacion')) $true

Write-Host ''
Write-Host '== de la auditoria a escribir =='
# Las TCUs con desviaciones son las que hay que reescribir: hasta ahora habia
# que apuntarlas a mano y teclear el rango en Escribir.
$audF = @(
    [pscustomobject]@{NCU='12'; TCU=39; Variable='a'; Nota='DESVIACION'}
    [pscustomobject]@{NCU='12'; TCU=39; Variable='b'; Nota='DESVIACION'}   # misma TCU, dos variables
    [pscustomobject]@{NCU='12'; TCU=41; Variable='a'; Nota='DESVIACION - fuera de rango'}
    [pscustomobject]@{NCU='12'; TCU=44; Variable='a'; Nota='sin respuesta'}
    [pscustomobject]@{NCU='';   TCU='';  Variable='';  Nota='Sin desviaciones: 40 TCUs conformes'}
)
$mal = @(Aud-ConDesviacion $audF)
Check 'escribir: una fila por TCU, no por variable' ($mal.Count) 2
Check 'escribir: la primera' ("$($mal[0].ncu)/$($mal[0].tcu)") '12/39'
Check 'escribir: la de nota con motivo tambien entra' ("$($mal[1].ncu)/$($mal[1].tcu)") '12/41'
Check 'escribir: las mudas no' (@($mal | Where-Object { $_.tcu -eq 44 }).Count) 0
Check 'escribir: la fila de "sin desviaciones" tampoco' (@($mal | Where-Object { "$($_.tcu)" -eq '' }).Count) 0
Check 'escribir: sin auditoria, nada' (@(Aud-ConDesviacion @()).Count) 0
# ordenadas por NCU y TCU, que el rango sale de ahi
$mix = @(Aud-ConDesviacion @(
    [pscustomobject]@{NCU='2'; TCU=9; Nota='DESVIACION'}
    [pscustomobject]@{NCU='12'; TCU=3; Nota='DESVIACION'}
    [pscustomobject]@{NCU='2'; TCU=4; Nota='DESVIACION'}))
Check 'escribir: ordenadas por NCU y TCU' (@($mix | ForEach-Object { "$($_.ncu)/$($_.tcu)" }) -join ' ') '2/4 2/9 12/3'
# el boton existe, esta enganchado y avisa de lo que el rango se lleva por delante
Check 'escribir: hay boton' ($src.Contains("btnAudEscr.Text = 'Escribir...'")) $true
Check 'escribir: con handler' ($src.Contains('$btnAudEscr.Add_Click')) $true
Check 'escribir: se habilita al auditar' ($src.Contains('$btnAudEscr.Enabled = (@(Aud-ConDesviacion')) $true
# Un rango va de la primera a la ultima: con TCUs sueltas escribiria sobre las
# buenas de en medio. Solo se usa si son un tramo seguido de UNA NCU.
# de la lista de TCUs malas al texto del cuadro TCUs: ya no hay que elegir
# entre un rango que arrasa las buenas de en medio y generar un CSV
Check 'escribir: seguidas van como rango' (Sel-Texto @(@{ncu='12'; tcu=39}, @{ncu='12'; tcu=40}, @{ncu='12'; tcu=41})) '39-41'
Check 'escribir: una sola va suelta' (Sel-Texto @(@{ncu='12'; tcu=39})) '39'
Check 'escribir: con hueco, dos tramos' (Sel-Texto @(@{ncu='12'; tcu=39}, @{ncu='12'; tcu=41})) '39,41'
Check 'escribir: de dos NCUs, con prefijo' (Sel-Texto @(@{ncu='12'; tcu=39}, @{ncu='13'; tcu=40})) '12/39,13/40'
Check 'escribir: mezcla de tramos y sueltas' (Sel-Texto @(@{ncu='12'; tcu=39}, @{ncu='12'; tcu=40}, @{ncu='15'; tcu=5}, @{ncu='15'; tcu=6}, @{ncu='15'; tcu=9})) '12/39-40,15/5-6,15/9'
Check 'escribir: sin nada, vacio' (Sel-Texto @()) ''
Check 'escribir: desordenadas y repetidas' (Sel-Texto @(@{ncu='12'; tcu=41}, @{ncu='12'; tcu=39}, @{ncu='12'; tcu=40}, @{ncu='12'; tcu=40})) '39-41'
# y lo que escribe se tiene que poder volver a leer
Check 'escribir: ida y vuelta' ((Parse-Seleccion (Sel-Texto @(@{ncu='12'; tcu=39}, @{ncu='15'; tcu=5}))).porNcu['15'] -join ',') '5'
# la auditoria manda a Escribir las TCUs EXACTAS, sin pasar por un CSV
Check 'escribir: la auditoria pone la seleccion' ($src.Contains('$txtWTcus.Text = (Sel-Texto $malas)')) $true
Check 'escribir: y el cierre tambien' ($src.Contains('$txtWTcus.Text = (Sel-Texto $falta)')) $true
Check 'escribir: ya no hay CSV de correccion' ($src.Contains('Aud-CsvCorreccion')) $false

Write-Host ''
Write-Host '== trabajos guardados: lo hecho no se pierde al lanzar lo siguiente =='
# El diagnostico, el inventario, la auditoria, la lectura y las baterias vivian
# solo en memoria: auditar el firmware y luego diagnosticar borraba lo primero.
Check 'trab: el fichero lleva tipo, planta y sello' (Trabajo-Fichero 'diag' 'Ayora (Planta completa)' '20260807_1200') 'diag__Ayora__Planta_completa___20260807_1200.json'
Check 'trab: sin planta no deja un hueco' (Trabajo-Fichero 'diag' '' '20260807_1200') 'diag__sin_planta__20260807_1200.json'
Check 'trab: la planta con barras no rompe la ruta' ((Trabajo-Fichero 'diag' 'a/b\c' '1').Contains('/')) $false
# el resumen que se ve en la lista
$objT = [pscustomobject]@{tipo='auditoria'; planta='Ayora'; fecha='2026-08-07 12:51'; tecnico='ivan'; nota='3 desviaciones'
                          filas=@([pscustomobject]@{NCU='12'}, [pscustomobject]@{NCU='15'})}
$rT = Trabajo-Resumen $objT 'C:\x\y.json'
Check 'trab: pone el titulo en claro' ($rT.Tipo) 'Auditoria'
Check 'trab: cuenta las filas' ($rT.Filas) 2
Check 'trab: guarda el fichero' ($rT.fichero) 'C:\x\y.json'
Check 'trab: y el tipo crudo, para cargarlo' ($rT.tipoRaw) 'auditoria'
Check 'trab: un tipo raro no revienta' ((Trabajo-Resumen ([pscustomobject]@{tipo='zzz'; filas=@()})).Tipo) 'zzz'
Check 'trab: sin filas, cero' ((Trabajo-Resumen ([pscustomobject]@{tipo='diag'})).Filas) 0
# lo mas reciente primero: en campo interesa lo de hace un rato
$ordT = @(Trabajos-Ordenar @(
    [pscustomobject]@{Fecha='2026-08-07 09:00'; Tipo='Diagnostico'}
    [pscustomobject]@{Fecha='2026-08-07 12:00'; Tipo='Auditoria'}
    [pscustomobject]@{Fecha='2026-08-06 23:00'; Tipo='Inventario'}))
Check 'trab: el mas nuevo arriba' ($ordT[0].Fecha) '2026-08-07 12:00'
Check 'trab: y el mas viejo abajo' ($ordT[-1].Fecha) '2026-08-06 23:00'
Check 'trab: lista vacia no revienta' ((@(Trabajos-Ordenar @())).Count) 0

# ============================================================================
#  Comparar dos trabajos guardados (lo que en la web hace el Historico)
# ============================================================================
# OFFLINE no es un punto mas de la escala: perder un seguidor nunca es mejora
Check 'cmp: OK a ALARMA es peor'      (Cmp-Salud 'OK' 'ALARMA') 'peor'
Check 'cmp: ALARMA a OK es mejor'     (Cmp-Salud 'ALARMA' 'OK') 'mejor'
Check 'cmp: OK a AVISO es peor'       (Cmp-Salud 'OK' 'AVISO') 'peor'
Check 'cmp: ALARMA a OFFLINE es peor' (Cmp-Salud 'ALARMA' 'OFFLINE') 'peor'
Check 'cmp: OFFLINE a OK es mejor'    (Cmp-Salud 'OFFLINE' 'OK') 'mejor'
# salir de OFFLINE es recuperar comunicacion: un equipo que habla con una pega
# es mejor noticia que un equipo mudo, del que no se sabe nada
Check 'cmp: OFFLINE a AVISO tambien es mejor'  (Cmp-Salud 'OFFLINE' 'AVISO') 'mejor'
Check 'cmp: y OFFLINE a ALARMA, igual'         (Cmp-Salud 'OFFLINE' 'ALARMA') 'mejor'
Check 'cmp: sin cambio, nada'         (Cmp-Salud 'OK' 'OK') ''
Check 'cmp: una salud rara no revienta' (Cmp-Salud 'OK' 'ZZZ') 'neutro'

# la clave lleva la variable solo en la auditoria: una TCU puede tener varias
Check 'cmp: clave de una TCU' (Cmp-Clave ([pscustomobject]@{NCU='12'; TCU=7})) '12|7'
Check 'cmp: clave de una desviacion' (Cmp-Clave ([pscustomobject]@{NCU='12'; TCU=7; Variable='41010'})) '12|7|41010'
Check 'cmp: nombre del equipo' (Cmp-Equipo ([pscustomobject]@{NCU='12'; TCU=7})) 'NCU12/TCU 7'
Check 'cmp: y de una HSU'      (Cmp-Equipo ([pscustomobject]@{NCU='15'; TCU='HSU9'})) 'NCU15/HSU9'

# comparar planta completa contra una sola NCU: solo esa NCU, no "las otras 15
# ya no aparecen"
$cmpA = @(
  [pscustomobject]@{NCU='1';  TCU=1; Salud='OK'}
  [pscustomobject]@{NCU='1';  TCU=2; Salud='OK'}
  [pscustomobject]@{NCU='12'; TCU=5; Salud='OK'}
)
$cmpB = @(
  [pscustomobject]@{NCU='1'; TCU=1; Salud='ALARMA'}
  [pscustomobject]@{NCU='1'; TCU=3; Salud='OK'}
)
Check 'cmp: NCUs comunes' ((@(Cmp-Comunes $cmpA $cmpB)) -join ',') '1'
$dif = @(Cmp-Trabajos 'diag' $cmpA $cmpB)
Check 'cmp: la NCU que no esta en los dos no cuenta' (@($dif | Where-Object { "$($_.Equipo)" -like '*NCU12*' }).Count) 0
Check 'cmp: el cambio de salud sale' (@($dif | Where-Object { "$($_.Equipo)" -eq 'NCU1/TCU 1' })[0].Cambio) 'peor'
# "AVISO" a secas obliga a salir a mirar: la nota va pegada al estado
Check 'cmp nota: OK no lleva nota'   (Cmp-ConNota 'OK' 'lo que sea') 'OK'
Check 'cmp nota: sin nota, el estado solo' (Cmp-ConNota 'AVISO' '') 'AVISO'
Check 'cmp nota: el aviso dice de que es' (Cmp-ConNota 'AVISO' 'dif 6,2 deg') 'AVISO (dif 6,2 deg)'
Check 'cmp nota: una nota larga se recorta' ((Cmp-ConNota 'ALARMA' ('x' * 200)).Length) 79
$difN = @(Cmp-Trabajos 'diag' @([pscustomobject]@{NCU='1'; TCU=9; Salud='OK'; Alarmas=''}) `
                              @([pscustomobject]@{NCU='1'; TCU=9; Salud='AVISO'; Alarmas='dif 6,2 deg'}))
Check 'cmp: el diff lleva el motivo del aviso' (@($difN)[0].Ahora) 'AVISO (dif 6,2 deg)'
Check 'cmp: y el estado anterior sin adornos' (@($difN)[0].Antes) 'OK'
Check 'cmp: la TCU nueva sale' (@($dif | Where-Object { "$($_.Que)" -eq 'nuevo' })[0].Equipo) 'NCU1/TCU 3'
Check 'cmp: la que ya no esta, tambien' (@($dif | Where-Object { "$($_.Que)" -eq 'ya no aparece' })[0].Equipo) 'NCU1/TCU 2'
Check 'cmp: y el alcance lo dice' ((Cmp-Alcance $cmpA $cmpB) -like '*solo las NCUs comunes*') $true
Check 'cmp: sin nada en comun lo dice' ((Cmp-Alcance @([pscustomobject]@{NCU='1'; TCU=1}) @([pscustomobject]@{NCU='9'; TCU=1})) -like '*no hay nada que comparar*') $true
Check 'cmp: dos iguales, sin cambios' ((@(Cmp-Trabajos 'diag' $cmpA $cmpA)).Count) 0

# la auditoria solo lista desviaciones: que aparezca una fila ES la noticia
$audA = @([pscustomobject]@{NCU='12'; TCU=7; Variable='41010'; Leido='-1.6'})
$audB = @([pscustomobject]@{NCU='12'; TCU=8; Variable='41111'; Leido='55'})
$difA = @(Cmp-Trabajos 'auditoria' $audA $audB)
Check 'cmp aud: una desviacion nueva es peor' (@($difA | Where-Object { "$($_.Que)" -eq 'desviacion nueva' })[0].Cambio) 'peor'
Check 'cmp aud: y la que desaparece, mejor' (@($difA | Where-Object { "$($_.Equipo)" -eq 'NCU12/TCU 7' })[0].Cambio) 'mejor'
$difA2 = @(Cmp-Trabajos 'auditoria' $audA @([pscustomobject]@{NCU='12'; TCU=7; Variable='41010'; Leido='-9.9'}))
Check 'cmp aud: si sigue pero cambia el leido, se dice' (@($difA2)[0].Ahora) '-9.9'

# inventario: lo que importa entre dos visitas es el firmware
$invA = @([pscustomobject]@{NCU='1'; TCU=1; FW='v1.4.3'; Serie='A1'})
$invB = @([pscustomobject]@{NCU='1'; TCU=1; FW='v1.6.0'; Serie='A1'})
$difI = @(Cmp-Trabajos 'inventario' $invA $invB)
Check 'cmp inv: el FW cambia' (@($difI)[0].Que) 'FW'
Check 'cmp inv: de una a otra' ("$(@($difI)[0].Antes) -> $(@($difI)[0].Ahora)") 'v1.4.3 -> v1.6.0'
Check 'cmp inv: la serie no es noticia' (@($difI | Where-Object { "$($_.Que)" -eq 'Serie' }).Count) 0

# baterias: el SoC sube y baja solo, solo un salto grande es noticia
$batA = @([pscustomobject]@{NCU='1'; TCU=1; SoC='85'; SoH='100'; Estado='OK'})
Check 'cmp bat: 2 puntos de SoC no son noticia' ((@(Cmp-Trabajos 'baterias' $batA @([pscustomobject]@{NCU='1'; TCU=1; SoC='87'; SoH='100'; Estado='OK'}))).Count) 0
$difB = @(Cmp-Trabajos 'baterias' $batA @([pscustomobject]@{NCU='1'; TCU=1; SoC='60'; SoH='100'; Estado='OK'}))
Check 'cmp bat: 25 si' (@($difB)[0].Que) 'SoC'
Check 'cmp bat: y bajar es a peor' (@($difB)[0].Cambio) 'peor'
$difB2 = @(Cmp-Trabajos 'baterias' $batA @([pscustomobject]@{NCU='1'; TCU=1; SoC='85'; SoH='92'; Estado='OK'}))
Check 'cmp bat: el SoH si, cualquier cambio' (@($difB2)[0].Que) 'SoH'
Check 'cmp bat: el umbral no esta a null' ($CMP_TIPOS['baterias'].soc) 10

# un tipo que no se compara no revienta: devuelve vacio
Check 'cmp: un tipo sin diff da vacio' ((@(Cmp-Trabajos 'lectura' $cmpA $cmpB)).Count) 0

# que dos trabajos se comparan: dos marcados, o uno contra el anterior suyo
$lstT = @(
  [pscustomobject]@{Fecha='2026-08-08 10:00'; Tipo='Diagnostico'; Planta='Ayora'; fichero='c'}
  [pscustomobject]@{Fecha='2026-08-07 10:00'; Tipo='Diagnostico'; Planta='Ayora'; fichero='b'}
  [pscustomobject]@{Fecha='2026-08-06 10:00'; Tipo='Inventario';  Planta='Ayora'; fichero='a'}
)
$parJ = Cmp-Pareja $lstT @(1, 0)
Check 'cmp par: el mas antiguo va de "antes"' $parJ.antes.fichero 'b'
Check 'cmp par: y el nuevo de "ahora"'        $parJ.ahora.fichero 'c'
$parJ2 = Cmp-Pareja $lstT @(0, 1)      # marcados al reves: da igual
Check 'cmp par: el orden en que se marcan da igual' $parJ2.antes.fichero 'b'
$parU = Cmp-Pareja $lstT @(0)
Check 'cmp par: con uno solo, contra el anterior de su tipo' $parU.antes.fichero 'b'
$eP = ''
try { $null = Cmp-Pareja $lstT @(0, 2) } catch { $eP = "$_" }
Check 'cmp par: dos tipos distintos no se comparan' ($eP -like '*tipos distintos*') $true
$eP2 = ''
try { $null = Cmp-Pareja $lstT @(2) } catch { $eP2 = "$_" }
Check 'cmp par: sin anterior del mismo tipo, lo dice' ($eP2 -like '*no hay ningun*') $true
$eP3 = ''
try { $null = Cmp-Pareja $lstT @() } catch { $eP3 = "$_" }
Check 'cmp par: sin marcar nada, lo dice' ($eP3 -like '*marca un trabajo*') $true
Check 'cmp: el titulo de la lista vuelve a su clave' (Cmp-TipoDe 'Test comm') 'comm'

# ============================================================================
#  Repetidores: son TCUs, pero su esclavo cae fuera del rango 1..N
# ============================================================================
# hasta la v11.21 no se leian NUNCA: ni inventario, ni campana de firmware, ni
# auditoria de bateria. Y un repetidor con la bateria muerta se lleva por
# delante todo lo que cuelga de el.
$cxRep = @{multi=@(
  @{ncu=4;  ip='10.0.0.4';  gws=@(@{puerto=503; ini=1; fin=30; reps=@(@{nombre='Repetidor 1'; esclavo=200})})}
  @{ncu=12; ip='10.0.0.12'; gws=@(@{puerto=503; ini=1; fin=53; reps=@(@{nombre='Repetidor 2'; esclavo=200}, @{nombre='Repetidor 3'; esclavo=201})})}
  @{ncu=13; ip='10.0.0.13'; gws=@(@{puerto=503; ini=1; fin=72; reps=@()})}
)}
$rr = @(Reps-DeCx $cxRep)
Check 'rep: los saca de toda la planta' ($rr.Count) 3
Check 'rep: con su NCU' ((@($rr | ForEach-Object { $_.ncu }) -join ',')) '4,12,12'
Check 'rep: con su esclavo' ((@($rr | ForEach-Object { "$($_.esclavo)" }) -join ',')) '200,200,201'
Check 'rep: y con su puerto, que su esclavo no cae en ningun rango' ((@($rr | ForEach-Object { "$($_.puerto)" } | Sort-Object -Unique) -join ',')) '503'
# el 200 se repite entre NCUs y es correcto: cada NCU es su propia red Zigbee
Check 'rep: el mismo esclavo en dos NCUs no es un error' (@($rr | Where-Object { $_.esclavo -eq 200 }).Count) 2
# una NCU sin repetidores no aporta ninguno
Check 'rep: la NCU sin repetidores no cuela ninguno' (@($rr | Where-Object { "$($_.ncu)" -eq '13' }).Count) 0
# el filtro de gateway tambien vale aqui
Check 'rep: con un GW que no existe, ninguno' ((@(Reps-DeCx $cxRep '504')).Count) 0
Check 'rep: sin conexion, lista vacia' ((@(Reps-DeCx $null)).Count) 0

# el nombre lo pone la topologia; si no lo trae, se numeran por orden
$rn = @(Reps-Nombrar @(@{ncu='4'; puerto=503; nombre=''; esclavo=200}, @{ncu='12'; puerto=503; nombre=''; esclavo=201}))
Check 'rep: sin nombre se numeran' ((@($rn | ForEach-Object { $_.nombre }) -join '|')) 'Repetidor 1|Repetidor 2'
Check 'rep: y si la topologia lo trae, manda' ((@(Reps-Nombrar @(@{ncu='4'; puerto=503; nombre='Repetidor 5'; esclavo=200})))[0].nombre) 'Repetidor 5'

# esta FIJO: nada de posicion ni de motor, ni en la columna ni en su salud
Check 'rep alarmas: fuera el tilt fuera de rango' (Rep-Alarmas 'tilt fuera de rango') ''
Check 'rep alarmas: fuera el eje bloqueado'       (Rep-Alarmas 'eje bloqueado') ''
Check 'rep alarmas: fuera la sobrecorriente de motor' (Rep-Alarmas 'sobrecorriente de motor') ''
Check 'rep alarmas: fuera los limites Este/Oeste' (Rep-Alarmas 'limite Oeste alcanzado; limite Este alcanzado') ''
Check 'rep alarmas: fuera el driver de motor'     (Rep-Alarmas 'fallo en driver de motor') ''
# lo de comunicacion y bateria SI se queda: es lo unico que importa de un repetidor
Check 'rep alarmas: se queda el fallo de Xbee'    (Rep-Alarmas 'fallo com con Xbee') 'fallo com con Xbee'
Check 'rep alarmas: y el SoC critico'             (Rep-Alarmas 'SoC critico (<10%)') 'SoC critico (<10%)'
Check 'rep alarmas: mezcla, se queda solo lo suyo' (Rep-Alarmas 'eje bloqueado; SoC bajo (L1); motor mas lento de lo esperado') 'SoC bajo (L1)'
Check 'rep alarmas: sin alarmas, vacio'           (Rep-Alarmas '') ''
# la desviacion no llega como bit sino como NOTA de texto: en la v11.22 se colaba
# y los repetidores salian en AVISO por una posicion que en ellos no significa nada
Check 'rep alarmas: fuera la nota de desviacion'  (Rep-Alarmas 'dif 63,7 deg') ''
Check 'rep alarmas: y con el punto decimal ingles' (Rep-Alarmas 'dif 60.2 deg') ''
Check 'rep alarmas: mezclada con una suya'        (Rep-Alarmas 'dif 63,7 deg; SoC bajo (L1)') 'SoC bajo (L1)'
Check 'rep salud: una desviacion no lo saca de OK' (Rep-Salud ([pscustomobject]@{SoC=90}) (Rep-Alarmas 'dif 63,7 deg')) 'OK'
# el mensaje no puede afirmar mas de lo que dice el dato: lastComm a 0 es "no
# tengo lectura", no "nunca la he leido" (una NCU recien reiniciada esta a cero)
Check 'muda: el mensaje no dice "nunca"' ($src.Contains('nunca ha leido')) $false
Check 'muda: dice lo que de verdad sabe' ($src.Contains('si acaba de reiniciarse, su cache esta a cero')) $true
# el resumen por NCU: por numero, sin mezclar repetidores y diciendo las mudas
Check 'resumen: ordena por numero de NCU' ($src.Contains('Sort-Object { [int]("0" + $_) }')) $true
Check 'resumen: las HSU y los repetidores van aparte' ($src.Contains('(+{0} HSU/repetidor{1})')) $true
Check 'resumen: una NCU sin lectura se dice' ($src.Contains('SIN LECTURA - no se ha podido leer ninguna de sus')) $true

# --- la topologia se revisa a si misma al arrancar ---
# En San Jose faltaban CINCO NCUs enteras -603 TCUs- porque su campo de esclavos
# llevaba varios tramos y el exportador solo entendia uno. No dio ningun error:
# la herramienta simplemente leia menos planta.
$avSolapa = @(Topologia-Avisos @(
  [pscustomobject]@{nombre='San Jose NCU3 GW1'; puerto=503; tcu_ini=1;  tcu_fin=46}
  [pscustomobject]@{nombre='San Jose NCU3 GW2'; puerto=504; tcu_ini=46; tcu_fin=120}))
Check 'topo: canta el solape entre gateways' ($avSolapa.Count) 1
Check 'topo: y dice en que esclavo' (@($avSolapa)[0] -like '*esclavo 46*') $true
# En San Jose varias NCUs alternan los dos gateways por bloques: los rangos se
# cruzan pero NINGUN esclavo esta repetido. Mirar los extremos daba un falso
# positivo; hay que comparar los esclavos de verdad.
$avEntre = @(Topologia-Avisos @(
  [pscustomobject]@{nombre='San Jose NCU7 GW1'; puerto=503; tcu_ini=1;  tcu_fin=10; huecos=@(4,5,6)}
  [pscustomobject]@{nombre='San Jose NCU7 GW2'; puerto=504; tcu_ini=4;  tcu_fin=12; huecos=@(7,8,9,10)}))
Check 'topo: los gateways entrelazados NO son un solape' ($avEntre.Count) 0
$avOk = @(Topologia-Avisos @(
  [pscustomobject]@{nombre='Ayora NCU1'; tcu_ini=1; tcu_fin=63; trackers=63}))
Check 'topo: si cuadra, no molesta' ($avOk.Count) 0
$avFalta = @(Topologia-Avisos @(
  [pscustomobject]@{nombre='San Jose NCU19'; tcu_ini=10; tcu_fin=112; trackers=123}))
Check 'topo: canta si el rango no da los trackers' ($avFalta.Count) 1
Check 'topo: con los dos numeros' ((@($avFalta)[0] -like '*declara 123*') -and (@($avFalta)[0] -like '*deja 103*')) $true
# los huecos cuentan: 1-25 con tres huecos son 22, no 25
$avHue = @(Topologia-Avisos @(
  [pscustomobject]@{nombre='Ayora NCU7'; tcu_ini=1; tcu_fin=25; trackers=22; huecos=@(14,24,25)}))
Check 'topo: los huecos cuentan para el total' ($avHue.Count) 0
# sin 'trackers' no se inventa nada: solo avisa de lo que puede saber
$avSin = @(Topologia-Avisos @([pscustomobject]@{nombre='X NCU1'; tcu_ini=1; tcu_fin=10}))
Check 'topo: sin trackers declarados, no opina' ($avSin.Count) 0
Check 'topo: se revisa al arrancar' ($src.Contains('AVISO topologia: $a')) $true

# --- TCUs que no existen: el rango 1..N no sabe de huecos ---
# sin esto, un numero que no esta instalado se lee en cada barrido, no contesta
# nunca y sale OFFLINE para siempre, ensuciando el recuento de la planta
$gwH = @{puerto=503; ini=1; fin=6; huecos=@(3,5)}
Check 'hueco: fuera del rango efectivo' ((@(Tcus-DeGw $gwH)) -join ',') '1,2,4,6'
Check 'hueco: sin huecos, el rango entero' ((@(Tcus-DeGw @{puerto=503; ini=1; fin=4})) -join ',') '1,2,3,4'
# @($null) tiene UN elemento en PS 5.1: una entrada sin huecos llega aqui como
# @($null) desde Construir-EntradasAuto y no puede comerse ninguna TCU
Check 'hueco: @($null) no se come una TCU' ((@(Tcus-DeGw @{puerto=503; ini=1; fin=4; huecos=@($null)})) -join ',') '1,2,3,4'
Check 'hueco: no se puede pedir una que no existe' ((@(Sel-TcusDe (Parse-Seleccion '3' 'x') @($gwH) '1')).Count) 0
Check 'hueco: pedir el rango entero tampoco la trae' ((@(Sel-TcusDe (Parse-Seleccion '1-6' 'x') @($gwH) '1')) -join ',') '1,2,4,6'
Check 'hueco: y sin seleccion, igual' ((@(Sel-TcusDe $null @($gwH) '1')) -join ',') '1,2,4,6'
# y tampoco cuentan como flota declarada: no existen, no son equipos sin leer
$flH = @(Flota-Declarada @{multi=@(@{ncu=1; ip='10.0.0.1'; gws=@($gwH); hsuLista=@()})})
Check 'hueco: no entran en la flota declarada' (@($flH | Where-Object { $_.Tipo -eq 'TCU' }).Count) 4
Check 'hueco: y la que falta no esta' (@($flH | Where-Object { $_.TCU -eq '3' }).Count) 0

# --- el informe tiene que llevar TODOS los equipos, comuniquen o no ---
$cxF = @{multi=@(
  @{ncu=1; ip='10.0.0.1'; gws=@(@{puerto=503; ini=1; fin=3; reps=@(@{nombre='Repetidor 1'; esclavo=200})}); hsuLista=@(230)}
  @{ncu=2; ip='10.0.0.2'; gws=@(@{puerto=503; ini=1; fin=2; reps=@()}); hsuLista=@()}
)}
$fl = @(Flota-Declarada $cxF)
# NCU1: la NCU + 3 TCUs + 1 repetidor + 1 HSU = 6 ; NCU2: la NCU + 2 TCUs = 3
Check 'flota: declara todos los equipos' ($fl.Count) 9
Check 'flota: la propia NCU cuenta' (@($fl | Where-Object { $_.Tipo -eq 'NCU' }).Count) 2
Check 'flota: las TCUs del rango' (@($fl | Where-Object { $_.Tipo -eq 'TCU' }).Count) 5
Check 'flota: el repetidor' (@($fl | Where-Object { $_.Tipo -eq 'REP' })[0].TCU) 'Repetidor 1'
Check 'flota: y la HSU' (@($fl | Where-Object { $_.Tipo -eq 'HSU' })[0].TCU) 'HSU1'

# lo leido + lo declarado que no contesto
$leido = @([pscustomobject]@{NCU='1'; TCU='1'; Salud='OK'; Alarmas=''})
$comp = @(Diag-Completar $leido $fl)
Check 'flota: completa lo que falta' ($comp.Count) 9
Check 'flota: lo leido se respeta' (@($comp | Where-Object { "$($_.NCU)" -eq '1' -and "$($_.TCU)" -eq '1' })[0].Salud) 'OK'
Check 'flota: lo no leido sale SIN LECTURA' (@($comp | Where-Object { "$($_.NCU)" -eq '2' -and "$($_.TCU)" -eq '1' })[0].Salud) 'SIN LECTURA'
# la de una HSU va en femenino ("no leida"), asi que se comprueba el rabo comun
Check 'flota: y dice por que' ((@($comp | Where-Object { "$($_.Salud)" -eq 'SIN LECTURA' } | Where-Object { "$($_.Alarmas)" -notlike '*en este barrido*' })).Count) 0
Check 'flota: no duplica lo ya leido' (@($comp | Where-Object { "$($_.NCU)" -eq '1' -and "$($_.TCU)" -eq '1' }).Count) 1

# un repetidor NO es un seguidor: contarlo en el porcentaje lo falseaba
Check 'tipo: una TCU es TCU'        (Fila-Tipo ([pscustomobject]@{TCU='7'})) 'TCU'
Check 'tipo: la fila de la NCU'     (Fila-Tipo ([pscustomobject]@{TCU='NCU'})) 'NCU'
Check 'tipo: una HSU'               (Fila-Tipo ([pscustomobject]@{TCU='HSU9'})) 'HSU'
Check 'tipo: un repetidor no es TCU' (Fila-Tipo ([pscustomobject]@{TCU='Repetidor 1'})) 'REP'
Check 'informe: el KPI cuenta solo seguidores' ($src.Contains("(Fila-Tipo `$_) -eq 'TCU'")) $true
Check 'informe: completa la flota declarada' ($src.Contains('Diag-Completar $script:UltimoDiag (Flota-Declarada (Params-Conexion))')) $true

Check 'rep salud: si no contesta, OFFLINE' (Rep-Salud $null 'no contesta') 'OFFLINE'
Check 'rep salud: sin alarmas y con bateria, OK' (Rep-Salud ([pscustomobject]@{SoC=90}) '') 'OK'
Check 'rep salud: SoC critico es ALARMA' (Rep-Salud ([pscustomobject]@{SoC=5}) 'SoC critico (<10%)') 'ALARMA'
Check 'rep salud: bateria baja es AVISO' (Rep-Salud ([pscustomobject]@{SoC=12}) '') 'AVISO'
Check 'rep salud: un fallo de comunicacion, AVISO' (Rep-Salud ([pscustomobject]@{SoC=90}) 'fallo com con Xbee') 'AVISO'
# lo importante: nada de posicion ni de motor puede ensuciar su salud
Check 'rep salud: el eje bloqueado no le afecta' (Rep-Salud ([pscustomobject]@{SoC=90}) (Rep-Alarmas 'eje bloqueado')) 'OK'
Check 'rep salud: ni el tilt fuera de rango'     (Rep-Salud ([pscustomobject]@{SoC=90}) (Rep-Alarmas 'tilt fuera de rango')) 'OK'
Check 'rep salud: ni la desviacion de posicion'  (Rep-Salud ([pscustomobject]@{SoC=90; Dif=45; Tilt=-5; Objetivo=40}) '') 'OK'
# y el diagnostico lo filtra ANTES de pintarlo, no solo para el veredicto
Check 'rep: la columna Alarmas sale filtrada' ($src.Contains('$alR = $(if ($d) { Rep-Alarmas "$($d.Alarmas)" }')) $true

# el diagnostico los lee y los cuenta APARTE, como las HSU
Check 'rep: el diagnostico los recorre' ($src.Contains('$reps = @(Reps-Nombrar (Reps-DeCx $cx $txtGGw.Text))')) $true
Check 'rep: por Zigbee directo, no por la cache de la NCU' ($src.Contains('$d = Diag-LeerTcu ([byte]$rp.esclavo)')) $true
Check 'rep: no suman al total de la flota' ($src.Contains('$nROk = 0; $nRMal = 0')) $true
Check 'rep: y se dicen aparte en el resumen' ($src.Contains('Repetidores: $($reps.Count) ($nROk OK)')) $true
# la topologia de Ayora ya los declara
$jAyora = Get-Content (Join-Path $raizTb 'plantas/24025-ayora.json') -Raw | ConvertFrom-Json
$repsAy = @($jAyora.plantas | Where-Object { $_.PSObject.Properties['repetidores'] })
Check 'rep: Ayora declara repetidores' ($repsAy.Count) 4
Check 'rep: y son cinco en total' ((@($repsAy | ForEach-Object { @($_.repetidores).Count } | Measure-Object -Sum).Sum)) 5

# Ayora: la NCU7 declara tres numeros que no estan instalados (14, 24 y 25).
# Sin ellos la planta son 751 seguidores, no 754: los tres salian OFFLINE en
# todos los barridos y engordaban el recuento.
$ncu7 = @($jAyora.plantas | Where-Object { "$($_.nombre)" -eq 'Ayora NCU7' })[0]
Check 'hueco Ayora: la NCU7 los declara' ((@($ncu7.huecos)) -join ',') '14,24,25'
$totAy = 0
foreach ($e in $jAyora.plantas) {
    # ojo: @($null) tiene UN elemento en PS 5.1, no cero
    $totAy += ([int]$e.tcu_fin - [int]$e.tcu_ini + 1) - @($e.huecos | Where-Object { $null -ne $_ }).Count
}
Check 'hueco Ayora: la planta son 751 seguidores' $totAy 751

# el boton y su handler existen de verdad
Check 'cmp: hay boton COMPARAR' ($src.Contains("`$btnTCmp.Text = 'COMPARAR'")) $true
Check 'cmp: y esta enganchado' ($src.Contains('$btnTCmp.Add_Click({ Comparar-Trabajos })')) $true
Check 'cmp: saca tabla aparte con su CSV' ($src.Contains('function Cmp-Ventana')) $true
Check 'cmp: el CSV sale del mismo sitio que el resto' ($src.Contains('Exportar-Csv $script:UltimaCmp')) $true
# y la carpeta no se llena: se quedan los N mas nuevos de cada tipo
$fT = @('diag__A__20260801_100000.json','diag__A__20260802_100000.json','diag__A__20260803_100000.json','diag__A__20260804_100000.json')
Check 'trab: con tope 2, sobran 2' ((@(Trabajos-Podar $fT 2)).Count) 2
Check 'trab: y sobran los viejos' ((@(Trabajos-Podar $fT 2)) -contains 'diag__A__20260801_100000.json') $true
Check 'trab: los nuevos se quedan' ((@(Trabajos-Podar $fT 2)) -contains 'diag__A__20260804_100000.json') $false
Check 'trab: si caben todos, no sobra ninguno' ((@(Trabajos-Podar $fT 20)).Count) 0
Check 'trab: justo en el tope, tampoco' ((@(Trabajos-Podar $fT 4)).Count) 0
# los tipos declaran donde va cada cosa
foreach ($tp in @('diag','comm','inventario','auditoria','lectura','baterias')) {
    Check "trab: tipo $tp declarado" ($TRABAJO_TIPOS.ContainsKey($tp)) $true
    Check "trab: tipo $tp con su variable" (("$($TRABAJO_TIPOS[$tp].var)").Length -gt 0) $true
}
Check 'trab: el diag pinta la columna GW' ($TRABAJO_TIPOS['diag'].cols -contains 'GW') $true
Check 'trab: las baterias pintan la carga' ($TRABAJO_TIPOS['baterias'].cols -contains 'Carga') $true
Check 'trab: las columnas del diag son las de su tabla' ($TRABAJO_TIPOS['diag'].cols.Count) 11
# --- enganchado ---
Check 'trab: hay pestana' ($src.Contains("tabT.Text = 'Trabajos'")) $true
Check 'trab: con su tabla' ($src.Contains('$lvT = New-Object System.Windows.Forms.ListView')) $true
foreach ($b in @('btnTRef','btnTCargar','btnTGuardar','btnTBorrar','btnTCarpeta')) {
    Check "trab: boton ${b}" ($src.Contains("`$$b = New-Object System.Windows.Forms.Button")) $true
    Check "trab: ${b} con handler" ($src.Contains("`$$b.Add_Click(")) $true
}
Check 'trab: doble clic tambien carga' ($src.Contains('$lvT.Add_DoubleClick({ Trabajo-Cargar })')) $true
Check 'trab: la lista se pinta al arrancar' ($src.Contains("Cierre-Avisar`r`nTrabajos-Pintar") -or $src.Contains("Cierre-Avisar`nTrabajos-Pintar")) $true
# cada operacion que termina deja su copia: si falta una, esa se pierde
foreach ($t in @('diag','comm','lectura','auditoria','inventario','baterias')) {
    Check "trab: se guarda solo el $t" ($src.Contains("Trabajo-Guardar '$t'")) $true
}
# y cargar no toca la planta
$blqCarga = $src.Substring($src.IndexOf('function Trabajo-Cargar'), 2000)
Check 'trab: cargar no lee la planta' ($blqCarga.Contains('Modbus-Conectar')) $false
Check 'trab: y lo dice' ($blqCarga.Contains('no se ha leido nada de la planta')) $true
Check 'trab: la carpeta esta ignorada por git' ((Get-Content (Join-Path $raizTb '.gitignore') -Raw).Contains('trabajos/')) $true

# --- la seleccion, enganchada en las cuatro pestanas ---
# Un cuadro por pestana, y los de/a fuera: si quedara uno suelto seguiria
# mandando un rango a alguna operacion.
# las OCHO: tener la mitad con "de/a" y la otra mitad con el cuadro nuevo era
# dos formas de decir lo mismo segun la pestana
foreach ($t in @('W', 'L', 'G', 'A', 'S', 'V', 'B', 'P')) {
    Check "sel: cuadro TCUs en $t" ($src.Contains("`$txt${t}Tcus = TG ")) $true
    Check "sel: sin de/a en $t" (($src.Contains("`$txt${t}Ini")) -or ($src.Contains("`$txt${t}Fin"))) $false
}
Check 'sel: ya no queda Rango-Tcus' ($src.Contains('function Rango-Tcus')) $false

# --- un solo exportador ---
# El mismo dialogo, el mismo sello de fecha y el mismo aviso estaban copiados en
# diecinueve sitios, y siete CSV salian con coma: en un Excel en espanol se
# abren en una sola columna.
Check 'exp: hay un exportador de CSV' ($src.Contains('function Exportar-Csv')) $true
Check 'exp: y uno de JSON' ($src.Contains('function Exportar-Json')) $true
Check 'exp: siempre con punto y coma' ($src.Contains("Export-Csv `$f -NoTypeInformation -Encoding UTF8 -Delimiter ';'")) $true
Check 'exp: ningun CSV se escapa con coma' ($src -match "Export-Csv \`$dlg\.FileName") $false
# quedan solo los tres que de verdad son distintos: el propio Guardar-Como, el
# backup (lleva sufijo INCOMPLETO), el preset (nombre fijo) y el log en txt
Check 'exp: casi no quedan dialogos sueltos' (([regex]::Matches($src, 'New-Object System\.Windows\.Forms\.SaveFileDialog')).Count -le 4) $true
Check 'exp: el nombre de planta sale de un sitio' ($src.Contains('function Planta-Fichero')) $true
Check 'exp: y los exportadores lo usan' (([regex]::Matches($src, 'Planta-Fichero')).Count -ge 5) $true

Write-Host ''
Write-Host '== el agente del PC de planta no se puede quedar atras =='
# El agente NO tiene copia de la logica: extrae trozos de este mismo fichero por
# nombre de funcion. Al quitar Rango-Tcus en la v11.8 dejo de arrancar y no nos
# enteramos hasta que alguien pregunto. Estas comprobaciones fallan aqui, en la
# suite de la toolbox, antes de publicar.
$fAg = Join-Path (Split-Path $raizTb -Parent) 'tcu-agente/TCU_Agente.ps1'
Check 'agente: el fichero esta donde dice' (Test-Path $fAg) $true
$srcAg = Get-Content $fAg -Raw
# las marcas que el agente busca en la toolbox tienen que existir
$anclas = @([regex]::Matches($srcAg, "Ancla-Toolbox \`$src '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
Check 'agente: declara sus anclas' ($anclas.Count -ge 4) $true
foreach ($a in $anclas) { Check "agente: la toolbox tiene '$a'" ($src.Contains($a)) $true }
# y las dos marcas del bloque grande, que van aparte
foreach ($a in @('$VERSION_TOOLBOX', '$form = New-Object System.Windows.Forms.Form')) {
    Check "agente: y la marca $a" ($src.Contains($a)) $true
}
# las funciones de la toolbox que el agente llama por su nombre
foreach ($f in @('Ncu-DiagCompat', 'Ncu-HsuCompat', 'Plan-Segmentos', 'Modo-De', 'Comis-De', 'Fijar-Modo')) {
    if (-not $srcAg.Contains($f)) { continue }
    Check "agente: la toolbox sigue teniendo $f" ($src.Contains("function $f")) $true
}
# si falta una marca, el error tiene que decir cual
Check 'agente: el error dice que falta' ($srcAg.Contains('ya no tiene')) $true
Check 'agente: y que van juntas' ($srcAg.Contains('baja la misma release')) $true
# el SAT se activa en remoto pero graba aqui: el agente reutiliza los tres pases
# de esta misma pestana, asi que si se renombran se queda sin ensayo
foreach ($f in @('Sat-Fichero', 'Sat-Cabecera', 'Sat-PaseComms', 'Sat-PaseTcu', 'Sat-PaseEquipos')) {
    Check "agente SAT: la toolbox tiene $f" ($src.Contains("function $f")) $true
}
Check 'agente SAT: y la marca de fin del bloque' ($src.Contains('$tmrSat = New-Object')) $true
Check 'agente SAT: el agente lo extrae' ($srcAg.Contains("Ancla-Toolbox `$src 'function Sat-Fichero'")) $true
Check 'agente SAT: graba en la carpeta de la toolbox' ($srcAg.Contains("'sat_' + (`"`$(`$cfg.planta)`" -replace")) $true
Check 'agente SAT: y reanuda si se reinicia' ($srcAg.Contains('function Sat-Restaurar')) $true
Check 'agente SAT: se llama al arrancar' ($srcAg.Contains("Sat-Restaurar`r`n`$proxVig") -or $srcAg.Contains("Sat-Restaurar`n`$proxVig")) $true
# la descarga no puede salirse de su carpeta
Check 'agente SAT: la descarga no admite rutas' ($srcAg.Contains('[System.IO.Path]::GetFileName($nom)')) $true
# arrancar un ensayo NO es escribir en los seguidores: va por su lista aparte
# trabajos largos por trozos: el inventario de planta entera no cabe en una
# peticion HTTP, asi que se arranca y se pregunta
Check 'agente trabajo: se arranca y se pregunta' ($srcAg.Contains("'/trabajo/inventario'") -and $srcAg.Contains("'/trabajo'")) $true
Check 'agente trabajo: avanza entre peticiones' ($srcAg.Contains('try { Trabajo-Tick } catch')) $true
# dos a la vez se pisarian el cliente Modbus: se avisa en vez de arrancar
Check 'agente trabajo: no deja arrancar dos' ($srcAg.Contains("ya hay un trabajo en curso")) $true
# el trozo cierra su conexion: entre vueltas entra cualquier otra peticion y
# usa el MISMO cliente Modbus
Check 'agente trabajo: cada trozo cierra la conexion' ($srcAg.Contains('if ($abierta) { try { Modbus-Cerrar } catch {} }')) $true
# una NCU muda no puede tumbar el trabajo entero
Check 'agente trabajo: un fallo no lo tumba' ($srcAg.Contains("Nota = `"sin respuesta (`$_)`"")) $true
Check 'agente SAT: no va con las de escritura' ($srcAg.Contains("`$OPS_SAT = @('sat/iniciar', 'sat/parar')")) $true
# lo que la web lee: el agente reutiliza estas funciones, no las copia
foreach ($f in @('Bat-Tabla', 'Bat-Auditar', 'Cierre-Estado', 'Cierre-Cargar', 'Ident-Leer',
                 'Leer-Decodificado', 'Resolver-Variable', 'Plan-Firmware', 'Plan-Ventanas', 'Plan-Texto',
                 'Trabajo-Resumen', 'Trabajos-Ordenar', 'Trabajos-Dir')) {
    Check "agente web: la toolbox tiene $f" ($src.Contains("function $f")) $true
}
# Ident-Leer devuelve una lista Campo/Valor: indexarla por nombre da null en todo
Check 'agente web: el inventario la convierte a diccionario' ($srcAg.Contains('foreach ($c in @($campos)) { $h[$c.Campo] = $c.Valor }')) $true
Check 'sel: con su ayuda al pasar el raton' ($src.Contains('$ttW.SetToolTip($txtWTcus, $AYUDA_TCUS)')) $true
# el GW ya no vive en Conexion: cada pestana tiene el suyo, al lado de sus TCUs
Check 'gw: fuera de Conexion' ($src.Contains("`$txtGw = TG `$gbCon")) $false
foreach ($t in @('W','L','G','A','V','S','P','B')) {
    Check "gw: la pestana $t tiene su cuadro" ($src -match "\`$txt${t}Gw = TG ") $true
    Check "gw: la pestana $t lo explica" ($src.Contains("`$ttW.SetToolTip(`$txt${t}Gw, `$AYUDA_GW)")) $true
}
# y las cuatro operaciones la usan, con el filtro de gateway de SU pestana
foreach ($e in @(@{n='Escribir'; t='W'}, @{n='Leer'; t='L'}, @{n='Diagnostico'; t='G'}, @{n='Auditoria'; t='A'})) {
    Check "sel: $($e.n) la usa" ($src.Contains("(Parse-Seleccion `$txt$($e.t)Tcus.Text '$($e.n)') `$txt$($e.t)Gw.Text")) $true
}
Check 'sel: y el test comm tambien' ($src.Contains("(Parse-Seleccion `$txtGTcus.Text 'Test comm') `$txtGGw.Text")) $true
Check 'sel: el NVM tambien, que escribe' ($src.Contains("(Parse-Seleccion `$txtWTcus.Text 'NVM') `$txtWGw.Text")) $true
# el cuadro de NCUs: uno solo, en Conexion, y lo miran TODAS las operaciones
Check 'ncus: el cuadro vive en Conexion' ($src.Contains("`$txtNcus = TG `$gbCon")) $true
Check 'ncus: con su ayuda al pasar el raton' ($src.Contains('$ttW.SetToolTip($txtNcus, $AYUDA_NCUS)')) $true
Check 'ncus: no lo lee Trabajos-Planta, que reusa el agente' ($src -match '(?s)function Trabajos-Planta.*?\n\}' -and $Matches[0].Contains('$txtNcus')) $false
Check 'ncus: Diagnostico ya no tiene el suyo aparte' ($src.Contains('$txtGNcus')) $false
Check 'ncus: con una sola NCU se apaga' ($src.Contains('$txtNcus.Enabled = $false')) $true
# ninguna llamada se queda sin el filtro: si una lo olvida, esa pestana ignora las NCUs
Check 'ncus: todas las llamadas lo pasan' (([regex]::Matches($src, [regex]::Escape('Trabajos-Planta $cx')).Count) -eq ([regex]::Matches($src, [regex]::Escape('(Ncus-Filtro)')).Count)) $true
# la planta completa ya no ignora el cuadro: antes solo miraba el filtro de NCUs
Check 'sel: planta completa mira la seleccion' ($src.Contains("Trabajos-Planta `$cx `$null (Ncus-Filtro) (Parse-Seleccion `$txtGTcus.Text 'Diagnostico')")) $true
# de que gateway cuelga cada TCU, en la tabla y en los exports
Check 'gw: columna en el diagnostico' ($src.Contains("lvG.Columns.Add('GW'")) $true
# NCU - GW - TCU: como se llega a un seguidor en planta
Check 'gw: y va delante de la TCU' ($src.IndexOf("lvG.Columns.Add('GW'") -lt $src.IndexOf("lvG.Columns.Add('TCU'")) $true
Check 'gw: las filas siguen ese orden' ([regex]::Matches($src, [regex]::Escape('$d.GW, $d.TCU, $d.Salud')).Count) 5
Check 'gw: y ninguna se quedo al reves' ($src.Contains('$d.TCU, $d.GW, $d.Salud')) $false
Check 'gw: se calcula por fila' ($src.Contains('Add-Member -NotePropertyName GW -NotePropertyValue (Gw-DeTcuCx')) $true
# una entrada de puerto fijo no tiene lista de gateways, pero el puerto ES el
# gateway: sin esto la columna GW salia vacia en todas las de una sola NCU
Check 'gw: con puerto fijo tambien' ($src.Contains('function Gw-DeTcuCx')) $true
Check 'gw: y el 502 de la NCU no cuela como gateway' ($src.Contains('-and $p -ne "$PUERTO_NCU"')) $true
Check 'gw: al barrido en paralelo solo se le pasan los gateways' ($src.Contains('Gw-DeTcuCx @{gws=$r.tarea.gws}')) $true
Check 'gw: ninguna fila usa ya la version sin conexion' ($src.Contains('Gw-DeTcu $tr.cx.gws')) $false
Check 'gw: y las filas de NCU/HSU lo llevan vacio' ($src.Contains("GW=''; TCU='NCU'")) $true
# los ceros de una TCU que la NCU nunca ha leido no son medidas
Check 'muda: no publica sus ceros' ($src.Contains('$vacio = ($lastc[$tcu] -eq 0)')) $true
Check 'muda: ni su SoC' ($src.Contains("SoC = `$(if (`$vacio) { '' }")) $true
Check 'muda: ni su modo' ($src.Contains("Modo = `$(if (`$vacio) { '-' }")) $true
Check 'muda: el plan la salta' ($src.Contains("if (`"`$(`$d.Salud)`" -eq 'OFFLINE') { continue }")) $true

Check 'auditoria: no ensucia el CSV'($src.Contains('$script:UltimaAud += [pscustomobject]@{NCU=$etNcu; TCU=[int]$tcu; Variable=$vacio')) $false

Write-Host ''
Write-Host '== botones que existen y estan enganchados =='
# la familia de fallos "ese boton estaba y ha desaparecido" / "existe pero no
# hace nada": se comprueba en el texto, porque sin ventana no son invocables
foreach ($b in @('btnLimpiar', 'btnUsuarios', 'btnHEsclavo', 'btnInforme', 'btnLog')) {
    Check "boton ${b}: creado" ($src.Contains("`$$b = New-Object System.Windows.Forms.Button")) $true
    Check "boton ${b}: con handler" ($src.Contains("`$$b.Add_Click(")) $true
}
Check 'limpiar: no borra el log de fichero' ($src.Contains('$rtb.Clear()') -and -not $src.Contains('Remove-Item $script:LogFile')) $true

# ---- planta completa en las acciones que escriben (v11.30) ----
# ESCRIBIR siempre aceptaba (Planta completa) y NVM no: se podia escribir en
# media planta y no poder guardarlo, con lo que se perdia al reiniciar la TCU.
# Ninguna de estas acciones puede volver a rechazar la conexion de planta.
foreach ($g in @(
    'el cambio de modo va por NCU: elige una entrada (auto)/GW',
    'el stow va por NCU: elige una entrada (auto)/GW',
    'el test de motor va por NCU: elige una entrada (auto)/GW, no Planta completa')) {
    Check "planta: ya no se rechaza ($($g.Split(':')[0]))" ($src.Contains($g)) $false
}
# el sintoma tenia una firma clara: coger .tcus de golpe y pasarselo a
# Plan-Segmentos con la conexion de planta, que la rechaza
foreach ($op in @('NVM', 'Sincronizar', 'Backup NCU', 'Modo', 'Clear', 'Stow', 'Test motor')) {
    Check "planta: '$op' ya no aplana .tcus" ($src -match ("Parse-Seleccion \`$txt\w+\.Text '" + [regex]::Escape($op) + "'\) \`$txt\w+Gw\.Text\)\.tcus")) $false
}
# el bucle comun de PEM
Check 'pem: Pem-PorTcu existe' ($src.Contains('function Pem-PorTcu(')) $true
Check 'pem: y lo usan las cuatro acciones' ([regex]::Matches($src, [regex]::Escape('Pem-PorTcu $trabajos')).Count) 5
Check 'pem: la guardia de viento va por NCU' ($src.Contains('Guardia-Viento $tr.cx')) $true
Check 'pem: los contadores del test viven en un hashtable' ($src.Contains('$c = @{pasa=0; falla=0; salta=0; lim=0}')) $true
# los backups de planta llevan la NCU en el nombre: si no, la TCU 12 de la NCU3
# pisaria la TCU 12 de la NCU4
Check 'backup: el fichero lleva la NCU delante' ($src.Contains('backup_ncu{0}_tcu{1}')) $true
Check 'backup: avisa antes de un backup de horas' ($src.Contains("'Backup largo'")) $true

# ---- el export dice de donde salieron los datos, no que hay en los cuadros ----
# hacer un diagnostico de planta y luego tocar la NCU3 exportaba el diagnostico
# entero como si fuera de la NCU3
$cxPl = @{ip='NA'; puerto=$null; gws=$null; multi=@(1,2,3); etiqueta='PLANTA'; to=3000; reint=1}
$trPl = @(@{ncu=1; tcus=@(1,2)}, @{ncu=3; tcus=@(1)}, @{ncu=7; tcus=@(1)})
$selloPl = Ctx-Sello 'Ayora (Planta completa)' $cxPl $trPl
Check 'ctx: planta completa se declara como tal' $selloPl.alcance 'Planta completa (3 NCUs)'
Check 'ctx: y lleva las NCUs de verdad' (($selloPl.ncus) -join ',') '1,3,7'
Check 'ctx: la IP de planta no miente' $selloPl.ip 'NA'
$cxNcu = @{ip='192.168.4.30'; puerto=$null; gws=@(@{puerto=503; ini=1; fin=60}); multi=$null; etiqueta='auto'; to=3000; reint=1}
$selloN = Ctx-Sello 'Ayora NCU3 (auto)' $cxNcu @(@{ncu=3; tcus=@(1,2,3)})
Check 'ctx: una NCU suelta se nombra' $selloN.alcance 'NCU3'
Check 'ctx: con su IP' $selloN.ip '192.168.4.30'
# entrada manual: sin NCU reconocible, al menos ip:puerto
$selloM = Ctx-Sello '(manual)' @{ip='10.0.0.9'; puerto=503; gws=$null; multi=$null; etiqueta='503'; to=3000; reint=1} @(@{ncu=$null; tcus=@(1)})
Check 'ctx: sin NCU, ip y puerto' $selloM.alcance '10.0.0.9:503'
Check 'ctx: y ninguna NCU inventada' (@($selloM.ncus).Count) 0
# los exports leen el sello, no los cuadros
foreach ($b in @('diagnostico', 'auditoria', 'inventario', 'pem')) {
    Check "ctx: el export de $b usa el sello" ($src.Contains("Ctx-Leer '$b'")) $true
}
Check 'ctx: y ya no hay export que lea el cuadro de IP' ($src -match "(?m)^\s+ip\s+= \`$txtIp\.Text\.Trim\(\)") $false
Check 'ctx: el JSON lleva el alcance' ([regex]::Matches($src, [regex]::Escape('alcance = $ctx.alcance')).Count) 4
Check 'ctx: y las NCUs del barrido' ([regex]::Matches($src, [regex]::Escape('ncus    = @($ctx.ncus)')).Count) 4

$trabPem = @(@{ncu=3; tcus=@(1,2,3)}, @{ncu=4; tcus=@(7)}, @{ncu=5; tcus=@()})
Check 'trab: contar TCUs de varias NCUs' (Cuantas-Tcus $trabPem) 4
Check 'trab: sin trabajos, cero' (Cuantas-Tcus @()) 0
# @($null).Count vale 1 en PS 5.1: una NCU sin TCUs no puede sumar
Check 'trab: una NCU sin TCUs no suma' (Cuantas-Tcus @(@{ncu=9; tcus=$null})) 0

# ---- ningun fichero publicado lleva marcas de conflicto de git ----
# El README de la release se paso ONCE versiones (v11.22 -> v11.32) con un
# "<<<<<<< HEAD" dentro, y nadie lo vio porque nada lo miraba.
$conMarcas = @()
foreach ($f in @(Get-ChildItem $raizTb -File -Recurse -Include *.ps1, *.md, *.json, *.bat |
                 Where-Object { $_.FullName -notmatch '[\\/](plantas|informes|logs|registro)[\\/]' })) {
    $t = Get-Content $f.FullName -Raw
    if ($t -match '(?m)^(<<<<<<< |>>>>>>> |=======$)') { $conMarcas += $f.Name }
}
Check 'release: sin marcas de conflicto de git' ($conMarcas -join ',') ''

Write-Host ''
if ($fallos -eq 0) { Write-Host 'TODAS LAS PRUEBAS OK'; exit 0 }
else { Write-Host "$fallos PRUEBAS FALLIDAS"; exit 1 }
