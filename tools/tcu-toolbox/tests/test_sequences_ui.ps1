# Vista real WinForms, sin login ni llamadas a equipos. Incluye el layout final.
$ErrorActionPreference='Stop'
$raiz=Split-Path $PSScriptRoot -Parent
$source=Join-Path $raiz 'TCU_Toolbox.ps1'
$src=Get-Content $source -Raw
$fin=$src.IndexOf('#  Login (obligatorio)')
if($fin -lt 0){throw 'No se encontro el limite de inicio de la interfaz'}
$inicio=$src.Substring(0,$fin).Replace('$PSScriptRoot','$raiz')
Write-Host 'UI: construir'
Invoke-Expression $inicio
Write-Host 'UI: construida'
$script:FichConfigLocal=Join-Path ([IO.Path]::GetTempPath()) 'sequence-ui-config.json'
$script:Usuario=@{nombre='Prueba visual';usuario='test';rol='tecnico'}
$script:SecPasos=@(@{tipo='variable';valor='41010 longitud [deg] = -1.5'},@{tipo='nvm';valor=''},@{tipo='modo';valor='AUTO'},@{tipo='comprobar';valor='ESTADO 30001 modo (OFF/MANUAL/AUTO) = AUTO'})
$script:UltimoSec=@([pscustomobject]@{NCU='2';TCU='18';Paso='1. Escribir longitud';Estado='VERIFICADO';Nota='-1.4 -> -1.5'},[pscustomobject]@{NCU='2';TCU='18';Paso='2. Guardar NVM';Estado='ENVIADO';Nota='Persistencia tras reinicio pendiente'},[pscustomobject]@{NCU='2';TCU='19';Paso='1. Escribir longitud';Estado='FALLA';Nota='Equipo sin respuesta'})
Sec-PintarPasos;Sec-FiltrarResultados
$form.Show();[Windows.Forms.Application]::DoEvents()
$tabs.SelectedTab=$tabSEC
foreach($ancho in @(1024,1142,1450)){
    Write-Host "UI: tamaño $ancho"
    $form.Size=New-Object Drawing.Size($ancho,820)
    $form.PerformLayout();[Windows.Forms.Application]::DoEvents()
    if($nav.Right -gt $pnlCuerpo.Left -or $nav.Right -gt $rtb.Left){throw 'El contenido tapa el menu lateral'}
    if($btnVolverDiag.Right -gt $lblLog.Left){throw 'El pie tapa el boton de vuelta'}
    foreach($c in @($lvSEC,$lvSECR,$secEdicion,$secAcciones,$lblSECRes,$lblSECNota)){
        if($c.Bottom -gt $secLayout.ClientSize.Height -or $c.Right -gt $secLayout.ClientSize.Width){throw "Control fuera de vista: $($c.GetType().Name) $ancho"}
    }
    if($lvSECR.Height -lt 60){throw "Resultados demasiado pequenos: $($lvSECR.Height)"}
    $bmp=New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $bmp.Save((Join-Path $PSScriptRoot "sequence-ui-full-$ancho.png"));$bmp.Dispose()
}
Write-Host 'UI: diagnóstico'
$script:UltimoDiag=@([pscustomobject]@{NCU='2';GW='504';TCU='18';Salud='ALARMA';Modo='AUTO';Tilt='15.5';Objetivo='22.5';Dif='7';SoC='87';Edad_s='12';Alarmas='Alarma motor enclavada'})
Trabajos-ComboNcus;Diag-Refrescar;$tabs.SelectedTab=$tabG
$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
if($btnGAcciones.Parent -ne $diagBarras[3] -or $lvG.Parent -ne $diagSplit.Panel1){throw 'Diagnostico sin layout adaptable'}
[Windows.Forms.Application]::DoEvents();$lvG.Items[0].Selected=$true
if($null -eq $lvG.Items[0].Tag){throw 'La fila de diagnostico perdio su identidad'}
$bmp=New-Object Drawing.Bitmap($form.Width,$form.Height)
$form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
$bmp.Save((Join-Path $PSScriptRoot 'sequence-ui-diagnostico.png'));$bmp.Dispose()
# La consola conserva su texto al plegar y libera espacio real para trabajar.
$antes=$pnlCuerpo.Height;$rtb.Text='registro conservado';$btnConsola.PerformClick()
[Windows.Forms.Application]::DoEvents()
if(-not $rtb.Visible -or $pnlCuerpo.Height -ge $antes){throw 'Consola no se despliega'}
$btnConsola.PerformClick()
if($rtb.Text -ne 'registro conservado' -or $rtb.Visible){throw 'Consola pierde contenido'}
# Filtrar no ejecuta ni pierde pantallas; borrar recupera todas las hojas.
$hojas=@($NAV_ARBOL|ForEach-Object{$_.hojas}).Count
$txtNav.Text='firmware';[Windows.Forms.Application]::DoEvents()
$filtradas=@($nav.Nodes|ForEach-Object{$_.Nodes}).Count
if($filtradas -ne 4){throw "Filtro de navegación: $filtradas"}
$txtNav.Text='';[Windows.Forms.Application]::DoEvents()
if(@($nav.Nodes|ForEach-Object{$_.Nodes}).Count -ne $hojas){throw 'Se perdió una función'}
if($diagSplit.Panel2Collapsed -ne ($diagSplit.Width -lt 980)){throw 'Panel de equipo no responde al ancho real'}
# Windows limita la ventana al escritorio de CI. El panel nativo se prueba
# además en un contenedor fuera de pantalla, con ancho real de 1200 px.
$hostDiag=New-Object Windows.Forms.Panel
$hostDiag.Size=New-Object Drawing.Size(1200,650)
$hostDiag.Controls.Add($diagLayout);$hostDiag.CreateControl();$diagLayout.PerformLayout()
[Windows.Forms.Application]::DoEvents()
$lvG.Items[0].Selected=$true;Diag-Detalle
if($diagSplit.Width -lt 1100 -or $diagSplit.Panel2Collapsed){throw 'No se despliega el panel amplio'}
if($txtDetalle.Text -notmatch 'Alarma motor'){throw 'Detalle no sigue la fila seleccionada'}
if(@($script:BotonesDetalle|Where-Object{$_.Visible}).Count){throw 'Acciones habilitadas en datos sin conexión'}
# Un destino capturado habilita acciones que preparan la pantalla sin leer red.
$ipPrevia=$txtIp.Text;$puertoPrevio=$txtPort.Text
$lvG.SelectedItems[0].Tag.trabajos=@(@{ncu='2';ip='10.20.30.40';cx=@{puerto=504;to=1500};tcus=@(18)})
Diag-Detalle
$bmp=New-Object Drawing.Bitmap($hostDiag.Width,$hostDiag.Height)
$hostDiag.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$hostDiag.Width,$hostDiag.Height)))
$bmp.Save((Join-Path $PSScriptRoot 'sequence-ui-diagnostico-amplio.png'));$bmp.Dispose()
if(@($script:BotonesDetalle|Where-Object{$_.Visible}).Count -ne 5){throw 'Faltan acciones de TCU'}
($script:BotonesDetalle|Where-Object{$_.Tag -eq 'Leer variables'}).PerformClick()
if($tabs.SelectedTab -ne $tabL -or $txtIp.Text -ne '10.20.30.40' -or $txtLTcus.Text -ne '18' -or $txtPort.Text -ne '504'){throw 'La acción perdió el destino capturado'}
$btnVolverDiag.PerformClick()
if($tabs.SelectedTab -ne $tabG -or $txtIp.Text -ne $ipPrevia -or $txtPort.Text -ne $puertoPrevio){throw 'Volver no restaura el contexto'}
$tabG.Controls.Add($diagLayout);$hostDiag.Dispose()
# Espacio de operación con tres estados y procedencia capturada.
$script:OpFichero=Join-Path ([IO.Path]::GetTempPath()) ('op-ui-'+[guid]::NewGuid()+'.json')
$script:OpIncidencias=@{};$script:OpMeta.Clear();$script:DiagOrigen.Clear();$script:DiagPrevias=@()
$script:Ctx.diagnostico=@{trabajos=@(@{ncu='2';ip='10.20.30.40';cx=@{puerto=504;to=1500};tcus=@(18,19,20)})}
$script:OpLectura=@{fecha=(Get-Date).ToString('o');planta='Planta de prueba'};$script:UltimoEsComm=$false
$script:UltimoDiag=@(
 [pscustomobject]@{NCU='2';GW='504';TCU='18';Salud='ALARMA';Alarmas='Motor enclavado';Edad_s='12'},
 [pscustomobject]@{NCU='2';GW='504';TCU='19';Salud='OFFLINE';Alarmas='Sin respuesta';Edad_s='900'},
 [pscustomobject]@{NCU='2';GW='504';TCU='20';Salud='OK';Alarmas='';Edad_s='8'})
Op-Actualizar;$tabs.SelectedTab=$tabOP;[Windows.Forms.Application]::DoEvents()
if($script:OpLista.Items.Count -ne 2){throw 'Operación no prioriza las incidencias'}
$script:OpLista.Items[0].Selected=$true;Op-Seleccion
$script:OpReconocer.PerformClick()
if(-not $script:OpLista.Items[0].Tag.episodio.reconocida){throw 'No persiste el reconocimiento'}
if($script:UltimoDiag[0].Salud -ne 'ALARMA'){throw 'Reconocer borró la alarma'}
$script:OpFiltro.SelectedIndex=1
if($script:OpLista.Items.Count -ne 3){throw 'Falta un equipo en la vista completa'}
foreach($anchoOp in @(1024,1142)){
 $form.Size=New-Object Drawing.Size($anchoOp,820);Layout-Principal;[Windows.Forms.Application]::DoEvents()
 if($script:OpLista.Height -lt 80){throw 'Operación sin espacio para la tabla'}
 foreach($controlOp in @($script:OpVer,$script:OpReconocer,$script:OpNota)){if($controlOp.Bottom -gt $controlOp.Parent.ClientSize.Height){throw 'Botón de operación recortado'}}
 $bmp=New-Object Drawing.Bitmap($form.Width,$form.Height)
 $form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
 $bmp.Save((Join-Path $PSScriptRoot "sequence-ui-operacion-$anchoOp.png"));$bmp.Dispose()
}
$destinoOp=Diag-Objetivo $script:UltimoDiag[0] $script:Ctx.diagnostico.trabajos
Diag-PrepararAccion $destinoOp 'Leer variables'
$btnVolverDiag.PerformClick()
if($tabs.SelectedTab -ne $tabOP){throw 'La vuelta pierde el espacio de operación'}
Remove-Item $script:OpFichero -Force -ErrorAction SilentlyContinue
$form.Close();$form.Dispose()
Write-Host 'Interfaz completa: arranque, geometria y contexto de diagnostico OK'
