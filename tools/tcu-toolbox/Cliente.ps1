# Herramientas de producto. Reutilizan el modelo de plantas y el diagnostico.
$script:ClienteRaiz=$PSScriptRoot
function Cliente-JsonAtomico([string]$ruta,$valor){
    $dir=Split-Path $ruta -Parent;[void][IO.Directory]::CreateDirectory($dir)
    $ruta=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ruta)
    $tmp=$ruta+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $valor | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmp -Encoding UTF8
        if(Test-Path -LiteralPath $ruta){[IO.File]::Replace($tmp,$ruta,[NullString]::Value)}else{[IO.File]::Move($tmp,$ruta)}
    }finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}
}
function Cliente-Topologia([string]$ruta){
    if((Get-Item -LiteralPath $ruta).Length -gt 5MB){throw 'Topologia mayor de 5 MB.'}
    if($ruta -match '\.csv$'){
        $filas=@(Import-Csv -LiteralPath $ruta -Delimiter ';')
        $obj=[pscustomobject]@{version=1;plantas=@($filas|ForEach-Object{
            [pscustomobject]@{nombre=("$($_.Planta) $(if("$($_.NCU)" -match '^\d+$'){"NCU$($_.NCU)"}else{$_.NCU}) GW$($_.Puerto)").Trim();ip=$_.IP;puerto=$_.Puerto;tcu_ini=$_.TCU_ini;tcu_fin=$_.TCU_fin}
        })}
    }else{$obj=Get-Content -LiteralPath $ruta -Raw|ConvertFrom-Json}
    $errores=New-Object 'System.Collections.Generic.List[string]';$resumen=New-Object 'System.Collections.Generic.List[object]'
    $nombres=@{};$ips=@{};$ncus=@{};$destinos=@{};$plantas=@{};$puertos=@{}
    foreach($p in @($obj.plantas)){
        if(-not $p){continue}
        $nom="$($p.nombre)".Trim();$ncu=Ncu-DeNombre $nom;$ip=[Net.IPAddress]::None
        if(-not $nom -or -not $ncu){$errores.Add("Nombre sin NCU explicita: $nom");continue}
        # El export v1 declara el locator en nombre. No crea asset_id.
        $prefijo=[regex]::Match($nom,'^(.*?)\s+NCU\d+(?:\s|$)')
        if(-not $prefijo.Success -or -not $prefijo.Groups[1].Value.Trim()){$errores.Add("Falta planta explicita en $nom");continue}
        $plantas[$prefijo.Groups[1].Value.Trim()]=$true
        if($nombres.ContainsKey($nom)){$errores.Add("Nombre repetido: $nom")};$nombres[$nom]=$true
        if(-not [Net.IPAddress]::TryParse("$($p.ip)",[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){$errores.Add("IP IPv4 no valida en $nom");continue}
        $ncu=[int]$ncu;$id="$ncu";$dir=$ip.ToString()
        if($ncu -lt 1){$errores.Add("NCU no valida en $nom")}
        if($ips.ContainsKey($dir) -and $ips[$dir] -ne $id){$errores.Add("IP $dir asignada a dos NCUs")};$ips[$dir]=$id
        if($ncus.ContainsKey($id) -and $ncus[$id] -ne $dir){$errores.Add("NCU$id tiene mas de una IP")};$ncus[$id]=$dir
        $puerto=0;$ini=0;$fin=0
        if(-not [int]::TryParse("$($p.puerto)",[ref]$puerto) -or $puerto -lt 1 -or $puerto -gt 65535){$errores.Add("Puerto invalido en $nom")}
        $rutaGw="$id/$puerto"
        if($puertos.ContainsKey($rutaGw)){$errores.Add("Gateway repetido: $rutaGw")};$puertos[$rutaGw]=$true
        if(-not [int]::TryParse("$($p.tcu_ini)",[ref]$ini) -or -not [int]::TryParse("$($p.tcu_fin)",[ref]$fin) -or $ini -lt 1 -or $fin -gt 247 -or $ini -gt $fin){$errores.Add("Rango TCU invalido en $nom");continue}
        $huecos=@{}
        foreach($h in @($p.huecos)){
            if($null -eq $h){continue};$numero=0
            if(-not [int]::TryParse("$h",[ref]$numero) -or $numero -lt $ini -or $numero -gt $fin -or $huecos.ContainsKey("$numero")){$errores.Add("Hueco invalido o duplicado en $nom");continue}
            $huecos["$numero"]=$true
        }
        foreach($tcu in @(Tcus-DeGw @{ini=$ini;fin=$fin;huecos=$p.huecos})){
            $k="$id/$tcu";if($destinos.ContainsKey($k)){$errores.Add("TCU $k repetida o presente en dos gateways")};$destinos[$k]=$true
        }
        $resumen.Add([pscustomobject]@{Nombre=$nom;NCU=$id;IP=$dir;Puerto=$puerto;TCU_desde=$ini;TCU_hasta=$fin})
    }
    if($resumen.Count -eq 0){$errores.Add('No hay entradas de planta validas.')}
    if($plantas.Count -ne 1){$errores.Add('Importa una sola planta por fichero; no se mezclan clientes.')}
    if($obj.plantas){foreach($a in @(Topologia-Avisos $obj.plantas)){$errores.Add("Topologia: $a")}}
    return @{objeto=$obj;filas=@($resumen.ToArray());errores=@($errores.ToArray());ncus=$ncus.Count;tcus=$destinos.Count}
}
function Cliente-GuardarTopologia($validada,[string]$destino){
    if(-not (Puede 'admin')){throw 'Se requiere administrador para cambiar la topologia.'}
    if($validada.errores.Count){throw 'Corrige los errores antes de guardar.'}
    Cliente-JsonAtomico $destino $validada.objeto
}
function Cliente-Alta {
    if(-not (Puede 'admin')){[void][Windows.Forms.MessageBox]::Show('Se requiere administrador.','Alta de planta');return}
    $d=New-Object Windows.Forms.Form;$d.Name='clienteAlta';$d.Text='Alta de planta: importar, validar y guardar';$d.Size=New-Object Drawing.Size(900,580);$d.MinimumSize=New-Object Drawing.Size(750,500);$d.StartPosition='CenterParent';$d.Font=$form.Font
    $l=New-Object Windows.Forms.TableLayoutPanel;$l.Dock='Fill';$l.ColumnCount=1;$l.RowCount=4
    foreach($h in @(62,42)){[void]$l.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$h)))}
    [void]$l.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)));[void]$l.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',100)));$d.Controls.Add($l)
    $txt=New-Object Windows.Forms.Label;$txt.Dock='Fill';$txt.Text='1. Importa el JSON de una planta o un CSV Planta;NCU;IP;Puerto;TCU_ini;TCU_fin.'+"`r`n"+'2. Revisa conexiones y solapes. 3. Guarda y selecciona la planta. Esta pantalla no envia ordenes.';$txt.Padding=New-Object Windows.Forms.Padding(8);$l.Controls.Add($txt)
    $barra=Sec-Barra $l;$imp=Sec-Boton $barra 'Importar JSON / CSV';$save=Sec-Boton $barra 'Guardar y cargar';$save.Enabled=$false
    $grid=New-Object Windows.Forms.DataGridView;$grid.Dock='Fill';$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AutoSizeColumnsMode='Fill';$l.Controls.Add($grid)
    $estado=New-Object Windows.Forms.TextBox;$estado.Multiline=$true;$estado.ReadOnly=$true;$estado.Dock='Fill';$estado.ScrollBars='Vertical';$l.Controls.Add($estado)
    $st=@{validada=$null;ruta=''};$raizCliente=$script:ClienteRaiz
    $imp.Add_Click({
        $dlg=New-Object Windows.Forms.OpenFileDialog;$dlg.Filter='Topologia (*.json;*.csv)|*.json;*.csv'
        try{
            if($dlg.ShowDialog($d) -ne 'OK'){return}
            $save.Enabled=$false;$st.validada=Cliente-Topologia $dlg.FileName;$st.ruta=$dlg.FileName
            $dt=New-Object Data.DataTable;foreach($c in @('Nombre','NCU','IP','Puerto','TCU_desde','TCU_hasta')){[void]$dt.Columns.Add($c)}
            foreach($f in $st.validada.filas){$r=$dt.NewRow();foreach($c in $dt.Columns){$r[$c.ColumnName]="$($f.($c.ColumnName))"};$dt.Rows.Add($r)};$grid.DataSource=$dt
            $estado.Text=if($st.validada.errores.Count){$st.validada.errores -join "`r`n"}else{"Validacion estructural correcta: $($st.validada.ncus) NCUs, $($st.validada.tcus) TCUs. La identidad y el cableado fisico deben comprobarse en planta."}
            $save.Enabled=$st.validada.errores.Count -eq 0
        }catch{$estado.Text="$_"}finally{$dlg.Dispose()}
    }.GetNewClosure())
    $save.Add_Click({
        try{
            $dest=Join-Path $raizCliente ('plantas/cliente-'+([IO.Path]::GetFileNameWithoutExtension($st.ruta) -replace '[^a-zA-Z0-9_-]','_')+'.json')
            if(Test-Path -LiteralPath $dest){if([Windows.Forms.MessageBox]::Show('Actualizar la topologia guardada con este nombre? Se conservara una copia previa.','Topologia','YesNo','Question') -ne 'Yes'){return};Copy-Item -LiteralPath $dest -Destination ($dest+'.'+(Get-Date -Format 'yyyyMMddHHmmss')+'.bak')}
            Cliente-GuardarTopologia $st.validada $dest
            foreach($k in @($PLANTAS.Keys)){if($k -ne '(manual)'){$PLANTAS.Remove($k)}}
            [void](Cargar-FicheroPlantas $dest);Construir-EntradasAuto;Refrescar-ComboPlantas
            if($cbPlanta.Items.Count -gt 1){$cbPlanta.SelectedIndex=1}
            Auditar 'ALTA_PLANTA' '' '' "Topologia validada: $($st.validada.ncus) NCUs / $($st.validada.tcus) TCUs"
            $estado.Text='Guardada y cargada. Utiliza Diagnostico para comprobar los equipos con la planta seleccionada.';$save.Enabled=$false
        }catch{$estado.Text="$_"}
    }.GetNewClosure())
    try{[void]$d.ShowDialog($form)}finally{$d.Dispose()}
}
function Cliente-Escape($valor){return [Net.WebUtility]::HtmlEncode("$valor")}
function Cliente-Informe([string]$ruta,$filas){
    $renglones=foreach($r in @($filas)){
        '<tr>'+((@($r.meta.planta,$r.fila.NCU,$r.fila.TCU,$r.fila.Salud,$r.fila.Alarmas,$r.calidad,$r.meta.fecha,$r.episodio.responsable,$r.episodio.estado,$r.episodio.nota)|ForEach-Object{'<td>'+(Cliente-Escape $_)+'</td>'}) -join '')+'</tr>'
    }
    $html='<!doctype html><html lang="es"><meta charset="utf-8"><title>Informe de operacion</title><style>body{font:14px Segoe UI,Arial;color:#172b3a;margin:32px}h1{font-size:25px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #cbd5e1;padding:7px;text-align:left;vertical-align:top}th{background:#eef3f7}footer{margin-top:20px;color:#536477}@media print{body{margin:12mm;font-size:10px}thead{display:table-header-group}tr{break-inside:avoid}}</style><h1>Informe de operacion · Toolbox '+(Cliente-Escape $VERSION_TOOLBOX)+'</h1><p>Emitido: '+(Cliente-Escape (Get-Date -Format o))+' · Operador: '+(Cliente-Escape $script:Usuario.nombre)+'</p><p>Alcance: '+@($filas).Count+' equipos cargados. Observaciones del ultimo diagnostico; no acredita vigilancia continua ni el estado actual de toda la planta.</p>'
    if($script:ModoDemo){$html+='<p><strong>DEMOSTRACION · DATOS SINTETICOS</strong></p>'}
    $html+='<table><thead><tr><th>Planta</th><th>NCU</th><th>Equipo</th><th>Estado observado</th><th>Motivo</th><th>Calidad</th><th>Adquisicion</th><th>Responsable</th><th>Gestion</th><th>Nota</th></tr></thead><tbody>'+($renglones -join '')+'</tbody></table><footer>Reconocer o cerrar una incidencia no envia ordenes al equipo. Una respuesta Modbus no demuestra por si sola un movimiento fisico.</footer></html>'
    Set-Content -LiteralPath $ruta -Value $html -Encoding UTF8
}
function Cliente-Soporte([string]$ruta){
    # Lista positiva: nunca copiar usuarios, claves DPAPI, topologias, CSV ni logs operativos.
    $tmp=Join-Path ([IO.Path]::GetTempPath()) ('toolbox-soporte-'+[guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($tmp)
    try{
        $datos=@{version=$VERSION_TOOLBOX;fecha=(Get-Date).ToString('o');powershell="$($PSVersionTable.PSVersion)";windows=[Environment]::OSVersion.VersionString;proceso64=[Environment]::Is64BitProcess;demo=[bool]$script:ModoDemo;archivos=@()}
        foreach($f in @(Get-ChildItem $script:ClienteRaiz -Filter '*.ps1' -File)){$datos.archivos+=@{nombre=$f.Name;sha256=(Get-FileHash $f.FullName -Algorithm SHA256).Hash}}
        $datos|ConvertTo-Json -Depth 5|Set-Content (Join-Path $tmp 'entorno.json') -Encoding UTF8
        'Paquete tecnico sin datos de planta, usuarios, contrasenas ni logs. Describe los pasos y adjunta evidencias solo tras revisarlas.'|Set-Content (Join-Path $tmp 'LEEME.txt') -Encoding UTF8
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($tmp,$ruta)
    }finally{Remove-Item $tmp -Recurse -Force}
}
function Cliente-Crear($pagina){
    $pagina.Text='Inicio, planta y soporte';$pagina.BackColor=[Drawing.Color]::FromArgb(244,246,249)
    $l=New-Object Windows.Forms.FlowLayoutPanel;$l.Dock='Fill';$l.FlowDirection='TopDown';$l.WrapContents=$false;$l.AutoScroll=$true;$l.Padding=New-Object Windows.Forms.Padding(20);$pagina.Controls.Add($l)
    $t=New-Object Windows.Forms.Label;$t.AutoSize=$true;$t.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold);$t.Text='Tu espacio de puesta en marcha y mantenimiento';$l.Controls.Add($t)
    $ayuda=New-Object Windows.Forms.Label;$ayuda.AutoSize=$true;$ayuda.MaximumSize=New-Object Drawing.Size(660,0);$ayuda.Margin=New-Object Windows.Forms.Padding(3,10,3,16)
    $ayuda.Text="1. Da de alta la planta y revisa la conexion.`r`n2. Ejecuta el diagnostico y abre la ficha del equipo.`r`n3. Consulta tendencias, prepara una accion y comprueba el resultado.`r`n4. Documenta la incidencia y entrega el informe.`r`n`r`nEdicion piloto: las funciones y firmware requieren aceptacion en planta. Los roles locales evitan errores operativos; el acceso al PC y a la red se gestiona en Windows y en planta.";$l.Controls.Add($ayuda)
    $alta=Sec-Boton $l 'Alta guiada de planta';$alta.Add_Click({if(-not $script:Ocupado){Cliente-Alta}})
    $inf=Sec-Boton $l 'Exportar informe de operacion';$inf.Add_Click({
        $dlg=New-Object Windows.Forms.SaveFileDialog;$dlg.Filter='Informe HTML (*.html)|*.html';$dlg.FileName='informe-operacion-'+(Get-Date -Format 'yyyyMMdd-HHmm')+'.html'
        try{if($dlg.ShowDialog($form) -eq 'OK'){Cliente-Informe $dlg.FileName @(Op-Filas);Start-Process $dlg.FileName}}catch{[void][Windows.Forms.MessageBox]::Show("$_",'Informe')}finally{$dlg.Dispose()}
    })
    $sup=Sec-Boton $l 'Crear paquete de soporte sin datos de planta';$sup.Add_Click({
        $dlg=New-Object Windows.Forms.SaveFileDialog;$dlg.Filter='Paquete ZIP (*.zip)|*.zip';$dlg.FileName='soporte-toolbox-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.zip'
        try{if($dlg.ShowDialog($form) -eq 'OK'){if(Test-Path -LiteralPath $dlg.FileName){throw 'Elige un nombre nuevo para conservar el paquete anterior.'};Cliente-Soporte $dlg.FileName;[void][Windows.Forms.MessageBox]::Show('Paquete creado. No se ha enviado a nadie.','Soporte')}}catch{[void][Windows.Forms.MessageBox]::Show("$_",'Soporte')}finally{$dlg.Dispose()}
    })
    $demo=Sec-Boton $l 'Abrir demostracion aislada';$demo.Enabled=-not $script:ModoDemo;$demo.Add_Click({Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $script:ClienteRaiz 'Demo.ps1')+'"'))})
    $inst=Sec-Boton $l 'Instalar / actualizar desde un paquete';$inst.Enabled=-not $script:ModoDemo;$inst.Add_Click({Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $script:ClienteRaiz 'Instalar.ps1')+'"'))})
    $doc=Sec-Boton $l 'Guia de inicio, compatibilidad y piloto';$doc.Add_Click({Start-Process (Join-Path $script:ClienteRaiz 'Guia-cliente.html')})
}
function Cliente-Demo {
    $script:OpIncidencias=@{};$script:OpMeta.Clear();$script:DiagOrigen.Clear();$script:DiagPrevias=@()
    $tr=@{ncu='1';ip='192.0.2.10';cx=@{puerto=503;to=1000};tcus=@(1,2,3)}
    $script:Ctx.diagnostico=@{trabajos=@($tr)}
    $script:UltimoEsComm=$false
    $script:UltimoDiag=@(
        [pscustomobject]@{NCU='1';GW='503';TCU='1';Salud='ALARMA';Alarmas='Ejemplo: desviacion de seguimiento';Edad_s='12';Tilt='12.5';Objetivo='18.0';SoC='86'},
        [pscustomobject]@{NCU='1';GW='503';TCU='2';Salud='OFFLINE';Alarmas='Ejemplo: sin respuesta';Edad_s='1800';Tilt='';Objetivo='';SoC=''},
        [pscustomobject]@{NCU='1';GW='503';TCU='3';Salud='OK';Alarmas='';Edad_s='8';Tilt='18';Objetivo='18';SoC='90'})
    foreach($f in $script:UltimoDiag){$script:DiagOrigen[$f]=@($tr);$script:OpMeta[$f]=@{origen='demo';modo='demostracion';fecha=(Get-Date).ToString('o');planta='Planta demostracion'}}
    Trabajos-ComboNcus;Diag-Refrescar;Op-Pintar;$tabs.SelectedTab=$tabOP
    $form.Text='DEMOSTRACION · DATOS SINTETICOS · CONEXIONES A EQUIPOS BLOQUEADAS · Toolbox '+$VERSION_TOOLBOX
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ctx=Hist-Contexto @{fila=$script:UltimoDiag[0];trabajos=@($tr)}
    $dir=Join-Path $ctx.carpeta 'NCU1';[void][IO.Directory]::CreateDirectory($dir)
    $dia=(Get-Date).AddDays(-1).ToString('yyyy-MM-dd');$ruta=Join-Path $dir "NCU1_$dia.zip"
    if(-not (Test-Path $ruta)){
        $z=[IO.Compression.ZipFile]::Open($ruta,'Create')
        try{
            $e=$z.CreateEntry("TCU_001_$dia.csv");$w=New-Object IO.StreamWriter($e.Open())
            try{$w.WriteLine('datetime;angle;target_angle;soc;motor_current;battery_temp');for($i=0;$i -lt 180;$i++){$h=([datetime]::ParseExact($dia,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)).AddHours(8).AddMinutes($i);$obj=[math]::Round(-25+$i/3,1);$real=$obj;if($i -ge 70 -and $i -lt 100){$real=$obj-6};$w.WriteLine(('{0};{1};{2};86;120;24' -f $h.ToString('yyyy-MM-dd HH:mm:ss'),$real.ToString([Globalization.CultureInfo]::InvariantCulture),$obj.ToString([Globalization.CultureInfo]::InvariantCulture)))}}finally{$w.Dispose()}
        }finally{$z.Dispose()}
    }
}

function Cliente-Bloqueo {
    try{
        $ruta=Join-Path $script:ClienteRaiz '.toolbox.lock'
        $script:BloqueoLocal=New-Object IO.FileStream($ruta,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        $form.Add_FormClosed({if($script:BloqueoLocal){$script:BloqueoLocal.Dispose()}})
        return $true
    }catch{[void][Windows.Forms.MessageBox]::Show('Esta carpeta esta abierta en otra Toolbox, en actualizacion o no permite escritura. Cierra la otra instancia o usa una carpeta escribible.','Carpeta en uso');return $false}
}
