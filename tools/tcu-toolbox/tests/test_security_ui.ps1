$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$raiz=Split-Path $PSScriptRoot -Parent
$src=Get-Content (Join-Path $raiz 'TCU_Toolbox.ps1') -Raw
$dir=Join-Path ([IO.Path]::GetTempPath()) ('auth-ui-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($dir)
$ini=$src.IndexOf('$ROLES = @(');$fin=$src.IndexOf('$form = New-Object System.Windows.Forms.Form')
Invoke-Expression ($src.Substring($ini,$fin-$ini).Replace('$PSScriptRoot','$dir'))
$VERSION_TOOLBOX='test'
$ast=[Management.Automation.Language.Parser]::ParseInput($src,[ref]$null,[ref]$null)
foreach($name in @('LG','TG','Dialogo-Clave','Dialogo-Login')){
    $fn=$ast.Find({param($x)$x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $name},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
$clave='Frase de prueba segura 2026';$nueva='Nueva frase de prueba segura 2026'
$estado=@{ticks=0;fallo='';fase='cambio';hecha=$false}
$timer=New-Object Windows.Forms.Timer;$timer.Interval=100
$timer.Add_Tick({
    try{
        $estado.ticks++
        $f=@([Windows.Forms.Application]::OpenForms)|Select-Object -Last 1
        if(-not $f){return}
        if($estado.ticks -gt 80){$estado.fallo='Dialogo no se cierra';$f.Close();return}
        if($estado.hecha){return}
        $textos=@($f.Controls|Where-Object{$_ -is [Windows.Forms.TextBox]}|Sort-Object Top)
        if($estado.fase -eq 'cambio'){
            if($textos.Count -ne 3){throw 'Faltan campos de contrasena'}
            foreach($t in $textos){if(-not $t.UseSystemPasswordChar){throw 'Contrasena visible'}}
            $textos[0].Text=$clave;$textos[1].Text=$nueva;$textos[2].Text=$nueva
            $bmp=New-Object Drawing.Bitmap($f.Width,$f.Height)
            try{$f.DrawToBitmap($bmp,(New-Object Drawing.Rectangle(0,0,$f.Width,$f.Height)));$bmp.Save((Join-Path $PSScriptRoot 'sequence-ui-security.png'))}finally{$bmp.Dispose()}
        }else{
            if($textos.Count -ne 2){throw 'Login sin sus dos campos'}
            $textos[0].Text='ana';$textos[1].Text=$nueva
        }
        $estado.hecha=$true;$f.AcceptButton.PerformClick()
    }catch{$estado.fallo=[string]$_;foreach($f in @([Windows.Forms.Application]::OpenForms)){$f.Close()}}
})
try{
    Usuarios-Guardar @((Usuario-Nuevo 'ana' 'Ana' 'admin' $clave))
    $timer.Start();$resultado=Dialogo-Clave 'ana';$timer.Stop()
    if($estado.fallo -or -not $resultado -or $resultado.usuario -ne 'ana'){throw "Cambio no completo: $($estado.fallo)"}
    Write-Host 'OK Cambio desde ventana con contrasena actual y campos ocultos'
    $estado.fase='login';$estado.ticks=0;$estado.hecha=$false
    $timer.Start();$resultado=Dialogo-Login @(Usuarios-Cargar);$timer.Stop()
    if($estado.fallo -or -not $resultado -or $resultado.usuario -ne 'ana'){throw "Login no completo: $($estado.fallo)"}
    Write-Host 'OK Login real con nueva contrasena'
}finally{$timer.Stop();$timer.Dispose();Remove-Item $dir -Recurse -Force}
