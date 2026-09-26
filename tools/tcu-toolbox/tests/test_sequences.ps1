$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$src=Get-Content $source -Raw
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
$names=@('Sec-Tipo','Sec-Texto','Sec-Minutos','Sec-Mueve','Sec-Escribe','Sec-Def','Sec-Condicion','Sec-Coincide','Sec-Validar','Sec-AObjeto','Sec-DeObjeto',
 'Diag-OrigenFila','Sec-Plan','Sec-RecetaTcu','Sec-PrepararPaso','Sec-EjecutarPaso','Diag-Objetivo','Fila-Tipo','Plan-Segmentos',
 'Aud-Igual','Aud-Hex','Valor-A-Escritura','Dir-Trama','Entero-Estricto','Parse-RealFinito','Normalizar-Decimal','F32-A-Palabras','Comparar-Escritura')
foreach($name in $names){$f=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true); . ([scriptblock]::Create($f[0].Extent.Text))}
$a=$src.IndexOf('$SEC_TIPOS =');$b=$src.IndexOf('function Sec-Tipo',$a)
. ([scriptblock]::Create($src.Substring($a,$b-$a)))
$INV=[Globalization.CultureInfo]::InvariantCulture
$ADDR_IDENTIDAD=@(41004,41006,41070,41072,41074,41075)
$ADDR_COMANDO=@(40000,40007,40017,40018,42000);$ADDR_TIEMPO=@(40001,40002,40003,40004,40005,40006)
$VARIABLES=[ordered]@{'config'=@{addr=41020;tipo='u16';min=0;max=10};'identidad'=@{addr=41004;tipo='u16'};'comando'=@{addr=40000;tipo='u16'};'reloj'=@{addr=40001;tipo='u16'};'angulo'=@{addr=41010;tipo='f32deg'}}
$ESTADO=[ordered]@{'modo'=@{addr=30001;tipo='modo'}}
$PUERTO_NCU=502
function Check($name,$actual,$expected){if("$actual" -ne "$expected"){throw "$name esperado=$expected actual=$actual"};Write-Host "OK $name"}
foreach($v in @('identidad','comando','reloj')){Check "bloqueo $v" (@((Sec-Validar @(@{tipo='variable';valor="$v = 1"}) $VARIABLES).errores).Count) 1}
Check 'preflight invalido antes de escribir' (@((Sec-Validar @(@{tipo='variable';valor='config = 11'}) $VARIABLES).errores).Count) 1
Check 'estado solo lectura' (@((Sec-Validar @(@{tipo='variable';valor='ESTADO modo = 1'}) $VARIABLES).errores).Count) 1
Check 'comprobar estado' (@((Sec-Validar @(@{tipo='comprobar';valor='ESTADO modo = AUTO'}) $VARIABLES).errores).Count) 0
Check 'stow texto invalido' (@((Sec-Validar @(@{tipo='stow';valor='abc'}) $VARIABLES).errores).Count) 1
Check 'ultimo NVM' (@((Sec-Validar @(@{tipo='variable';valor='config = 2'},@{tipo='nvm';valor=''},@{tipo='variable';valor='config = 3'}) $VARIABLES).avisos).Count) 1
Check 'hex decimal equivalentes' (Sec-Coincide '0x000A' '10') True
Check 'tolerancia' (Sec-Coincide '2' '2.09' 0.1) True
Check 'fuera tolerancia' (Sec-Coincide '2' '2.11' 0.1) False
Check 'config comprueba viento' (Sec-Mueve @(@{tipo='variable';valor='config = 2'})) True
Check 'condicion no mueve' (Sec-Mueve @(@{tipo='hasta';valor='ESTADO modo = AUTO'})) False
$rec=@(@{tipo='hasta';valor='ESTADO modo = AUTO | 0 | 60'})
Check 'tiempo maximo en estimacion' (Sec-Minutos $rec 2) 2
Check 'receta ida vuelta' ((Sec-DeObjeto (Sec-AObjeto 'Prueba' $rec)).pasos[0].valor) $rec[0].valor
# Planes con el mismo esclavo en NCUs diferentes.
$trabajos=@(@{ncu='1';ip='10.0.0.1';cx=@{puerto=503;to=500};tcus=@(1,2)},@{ncu='2';ip='10.0.0.2';cx=@{puerto=504;to=500};tcus=@(1)})
$dest=Diag-Objetivo ([pscustomobject]@{NCU='2';TCU='1'}) $trabajos
Check 'diagnostico conserva IP' $dest.ip '10.0.0.2'
Check 'diagnostico conserva gateway' $dest.puerto 504
try{[void](Diag-Objetivo ([pscustomobject]@{NCU='9';TCU='1'}) $trabajos);throw 'acepto NCU ausente'}catch{if("$_" -notmatch 'destino unico'){throw}}
# Barridos parciales no reasignan el destino de filas anteriores.
$script:DiagOrigen=New-Object 'System.Collections.Generic.Dictionary[object,object]'
$script:DiagPrevias=@();$script:Ctx=@{diagnostico=@{trabajos=$trabajos}}
$vieja=[pscustomobject]@{NCU='2';TCU='1'}
[void](Diag-OrigenFila $vieja)
$script:DiagPrevias=@($vieja);$script:Ctx.diagnostico.trabajos=@(@{ncu='2';ip='10.99.99.99';cx=@{puerto=504};tcus=@(1)})
Check 'fila anterior conserva su alcance' ((Diag-Objetivo $vieja (Diag-OrigenFila $vieja)).ip) '10.0.0.2'
$script:DiagOrigen.Clear();[void]$script:Ctx.Remove('diagnostico')
Check 'copia de disco sin destino operativo' ($null -eq (Diag-OrigenFila $vieja)) True
# Comparacion real tras escribir: no depende del formateo del decimal.
$script:words=@();$script:writes=0
function FC16-Escribir($unit,$addr,$words){$script:words=@($words);$script:writes++}
function FC03-Leer($unit,$addr,$count){return ,$script:words}
function Leer-Decodificado($unit,$def){return '1.50'}
function Start-Sleep {param($Milliseconds,$Seconds)}
Check 'verificacion por palabras f32' (Sec-EjecutarPaso 1 @{tipo='variable';valor='angulo = 1.5'} $false).ok True
# NVM honesto, simulacion sin escritura.
function FC22-Mascara($a,$b,$c,$d){$script:writes++}
Check 'NVM solicitado' (Sec-EjecutarPaso 1 @{tipo='nvm';valor=''} $false).estado 'ENVIADO'
$w=$script:writes;[void](Sec-EjecutarPaso 1 @{tipo='nvm';valor=''} $true);Check 'simular no escribe' $script:writes $w
# Cancelacion durante espera y condicion fallida.
$script:Cancelar=$false
function Sec-Esperar($s){$script:Cancelar=$true;return $false}
Check 'espera cancelada' (Sec-EjecutarPaso 1 @{tipo='esperar';valor='60'} $false).estado 'CANCELADO'
$script:Cancelar=$false
Check 'condicion falla' (Sec-EjecutarPaso 1 @{tipo='comprobar';valor='config = 9'} $false).ok False
# Guardia restaura socket, y ausencia de meteo no autoriza movimiento.
$script:conexiones=@();$script:viento=@{nivel=0;alarma=$false}
function Viento-Seguro($ip,$to){return $script:viento}
function Modbus-Conectar($ip,$port,$to){$script:conexiones+=,"${ip}:$port"}
Sec-PrepararPaso $dest @{tipo='modo';valor='AUTO'} $false
Check 'restaura gateway despues de HSU' $script:conexiones[-1] '10.0.0.2:504'
$script:viento=$null
try{Sec-PrepararPaso $dest @{tipo='modo';valor='AUTO'} $false;throw 'permitio viento desconocido'}catch{if("$_" -notmatch 'bloqueado'){throw}}
# El ejecutor detiene los siguientes pasos y no declara completa una cancelacion.
$script:pasosHechos=@();$script:filas=@();$lblSECRes=$null
function Sec-Fila($ncu,$tcu,$paso,$estado,$nota){$script:filas+=,$estado}
function Sec-PrepararPaso($d,$p,$s){}
function Sec-EjecutarPaso($t,$p,$s){$script:pasosHechos+=,$p.tipo;return @{ok=$false;nota='fallo'}}
Check 'falla detiene receta' (Sec-RecetaTcu $dest @(@{tipo='variable';valor='config = 2'},@{tipo='nvm';valor=''}) $false) 'FALLA'
Check 'no NVM tras fallo' ($script:pasosHechos -join ',') 'variable'
$script:Cancelar=$true
Check 'cancelacion no completa' (Sec-RecetaTcu $dest @(@{tipo='nvm';valor=''}) $false) 'CANCELADO'
Write-Host 'Secuencias: pruebas de comportamiento OK'
# Windows CI: abrir la vista real, verificar sus limites y guardar capturas.
if ($env:OS -eq 'Windows_NT') {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=New-Object Windows.Forms.Form; $form.Font=New-Object Drawing.Font('Segoe UI',9)
    $tabs=New-Object Windows.Forms.TabControl; $tabs.Dock='Fill';$form.Controls.Add($tabs)
    $ttW=New-Object Windows.Forms.ToolTip; $AYUDA_TCUS='TCUs seleccionadas'
    $a=$src.IndexOf('# ============================ TAB ORDENES SECUENCIALES')
    $b=$src.IndexOf('# ======================= TAB LIMITES',$a)
    . ([scriptblock]::Create($src.Substring($a,$b-$a)))
    foreach($name in @('Sec-PintarPasos','Sec-FiltrarResultados')){
        $f=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($f[0].Extent.Text))
    }
    function Lv-Reiniciar($lv){}
    $script:SecPasos=@(@{tipo='variable';valor='angulo = 38.5'},@{tipo='nvm';valor=''},@{tipo='modo';valor='AUTO'},@{tipo='comprobar';valor='ESTADO modo = AUTO'})
    $script:UltimoSec=@([pscustomobject]@{NCU='2';TCU='18';Paso='1. Escribir longitud';Estado='VERIFICADO';Nota='38.4 -> 38.5'},[pscustomobject]@{NCU='2';TCU='18';Paso='2. Guardar NVM';Estado='ENVIADO';Nota='Persistencia tras reinicio pendiente'},[pscustomobject]@{NCU='2';TCU='19';Paso='1. Escribir longitud';Estado='FALLA';Nota='Equipo sin respuesta'})
    Sec-PintarPasos;Sec-FiltrarResultados
    $form.Show()
    foreach($ancho in @(920,1200)){
        $form.ClientSize=New-Object Drawing.Size($ancho,470)
        $form.PerformLayout();[Windows.Forms.Application]::DoEvents()
        foreach($c in @($lvSEC,$lvSECR,$secEdicion,$secAcciones,$lblSECRes,$lblSECNota)){
            if($c.Bottom -gt $secLayout.ClientSize.Height -or $c.Right -gt $secLayout.ClientSize.Width){throw "Control fuera de vista: $($c.Name) $ancho"}
        }
        if($lvSECR.Height -lt 80){throw "Tabla de resultados demasiado pequena: $($lvSECR.Height)"}
        $bmp=New-Object Drawing.Bitmap($form.Width,$form.Height)
        $form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
        $bmp.Save((Join-Path $PSScriptRoot "sequence-ui-$ancho.png"));$bmp.Dispose()
    }
    $form.Close();$form.Dispose()
}
