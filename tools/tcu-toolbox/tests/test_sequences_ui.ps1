# Vista real WinForms, sin login ni llamadas a equipos. Incluye el layout final.
$ErrorActionPreference='Stop'
$raiz=Split-Path $PSScriptRoot -Parent
$source=Join-Path $raiz 'TCU_Toolbox.ps1'
$src=Get-Content $source -Raw
$fin=$src.IndexOf('#  Login (obligatorio)')
if($fin -lt 0){throw 'No se encontro el limite de inicio de la interfaz'}
$inicio=$src.Substring(0,$fin).Replace('$PSScriptRoot','$raiz')
Invoke-Expression $inicio
$script:FichConfigLocal=Join-Path ([IO.Path]::GetTempPath()) 'sequence-ui-config.json'
$script:Usuario=@{nombre='Prueba visual';usuario='test';rol='tecnico'}
$script:SecPasos=@(@{tipo='variable';valor='41010 longitud [deg] = -1.5'},@{tipo='nvm';valor=''},@{tipo='modo';valor='AUTO'},@{tipo='comprobar';valor='ESTADO 30001 modo (OFF/MANUAL/AUTO) = AUTO'})
$script:UltimoSec=@([pscustomobject]@{NCU='2';TCU='18';Paso='1. Escribir longitud';Estado='VERIFICADO';Nota='-1.4 -> -1.5'},[pscustomobject]@{NCU='2';TCU='18';Paso='2. Guardar NVM';Estado='ENVIADO';Nota='Persistencia tras reinicio pendiente'},[pscustomobject]@{NCU='2';TCU='19';Paso='1. Escribir longitud';Estado='FALLA';Nota='Equipo sin respuesta'})
Sec-PintarPasos;Sec-FiltrarResultados
$form.Show();[Windows.Forms.Application]::DoEvents()
$tabs.SelectedTab=$tabSEC
foreach($ancho in @(1024,1142,1450)){
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
$script:UltimoDiag=@([pscustomobject]@{NCU='2';GW='504';TCU='18';Salud='ALARMA';Modo='AUTO';Tilt='15.5';Objetivo='22.5';Dif='7';SoC='87';Edad_s='12';Alarmas='Alarma motor enclavada'})
Trabajos-ComboNcus;Diag-Refrescar;$tabs.SelectedTab=$tabG
$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
if($btnGAcciones.Parent -ne $diagBarras[3] -or $lvG.Parent -ne $diagLayout){throw 'Diagnostico sin layout adaptable'}
[Windows.Forms.Application]::DoEvents();$lvG.Items[0].Selected=$true
if($null -eq $lvG.Items[0].Tag){throw 'La fila de diagnostico perdio su identidad'}
$bmp=New-Object Drawing.Bitmap($form.Width,$form.Height)
$form.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
$bmp.Save((Join-Path $PSScriptRoot 'sequence-ui-diagnostico.png'));$bmp.Dispose()
$form.Close();$form.Dispose()
Write-Host 'Interfaz completa: arranque, geometria y contexto de diagnostico OK'
