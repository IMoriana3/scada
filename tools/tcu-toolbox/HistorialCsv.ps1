# Historico local de logs NCU. Sin subida automatica ni lectura de control.
$script:HistRaiz=$PSScriptRoot
function Hist-Contexto($tag){
    if(-not $tag.trabajos){throw 'Repite el diagnostico para recuperar el origen de conexion.'}
    $d=Diag-Objetivo $tag.fila $tag.trabajos
    $m=$script:OpMeta[$tag.fila]
    if(-not $m -or -not $m.planta -or $m.origen -ne 'lectura'){throw 'No hay una planta de origen verificada para esta fila.'}
    $identidad="$($m.planta)|$($d.ip)|$($d.ncu)"
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identidad))).Replace('-','').Substring(0,24)}finally{$sha.Dispose()}
    return @{planta="$($m.planta)";ip="$($d.ip)";ncu="$($d.ncu)";equipo="$($tag.fila.TCU)";tipo="$($d.tipo)";
        carpeta=(Join-Path $script:HistRaiz "logs-ncu\$hash")}
}
function Hist-Entradas([string]$ruta){
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z=[IO.Compression.ZipFile]::OpenRead($ruta)
    try{return @($z.Entries | Where-Object {$_.FullName -match '\.csv$'} | ForEach-Object {$_.FullName} | Sort-Object)}finally{$z.Dispose()}
}
function Hist-Leer([string]$ruta,[string]$entrada){
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z=[IO.Compression.ZipFile]::OpenRead($ruta)
    try{
        $e=$z.GetEntry($entrada)
        if(-not $e){throw 'El CSV ya no existe en el ZIP; actualiza la lista.'}
        if($e.Length -gt 32MB){throw 'CSV mayor de 32 MB: abre el ZIP con el importador web para analizarlo.'}
        $lector=New-Object IO.StreamReader($e.Open())
        try{$texto=$lector.ReadToEnd()}finally{$lector.Dispose()}
    }finally{$z.Dispose()}
    $filas=@($texto | ConvertFrom-Csv -Delimiter ';')
    if($filas.Count -eq 0 -or -not $filas[0].PSObject.Properties['datetime']){throw 'CSV sin muestras o sin columna datetime.'}
    $vistas=New-Object 'System.Collections.Generic.HashSet[string]'
    $horas=@{};$salida=New-Object 'System.Collections.Generic.List[object]';$duplicadas=0;$conflictos=0
    foreach($f in $filas){
        # Clave de toda la fila, no solo de la hora: conservar conflictos.
        $clave=ConvertTo-Json -InputObject @($f.PSObject.Properties | ForEach-Object {$_.Value}) -Compress
        if(-not $vistas.Add($clave)){$duplicadas++;continue}
        $hora="$($f.datetime)"
        if($horas.ContainsKey($hora)){$conflictos++}else{$horas[$hora]=$true}
        $salida.Add($f)
    }
    return @{filas=@($salida | Sort-Object datetime);duplicadas=$duplicadas;conflictos=$conflictos}
}
function Hist-Descargar($ctx,[string]$fecha){
    $ruta=Join-Path $script:HistRaiz 'descarga-logs\descarga_logs_ncu.ps1'
    if(-not (Test-Path -LiteralPath $ruta)){$ruta=Join-Path (Split-Path $script:HistRaiz) 'descarga-logs\descarga_logs_ncu.ps1'}
    if(-not (Test-Path -LiteralPath $ruta)){throw 'No se encuentra el descargador de logs.'}
    [void][IO.Directory]::CreateDirectory($ctx.carpeta)
    $ctx | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ctx.carpeta 'origen.json') -Encoding UTF8
    # Solo datos serializados. Ningun campo de la planta se evalua como codigo.
    $datos=@{ruta=$ruta;ip=$ctx.ip;ncu=$ctx.ncu;planta=$ctx.planta;fecha=$fecha;destino=$ctx.carpeta} | ConvertTo-Json -Compress
    $b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($datos))
    $codigo='$d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('''+$b64+''')) | ConvertFrom-Json; & $d.ruta -Ip $d.ip -Ncu $d.ncu -Planta $d.planta -Fecha $d.fecha -Destino $d.destino -Actualizar'
    $enc=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($codigo))
    return Start-Process powershell.exe -ArgumentList @('-NoProfile','-NoExit','-ExecutionPolicy','Bypass','-EncodedCommand',$enc) -PassThru
}
function Hist-Abrir($tag){
    try{$ctx=Hist-Contexto $tag}catch{[void][Windows.Forms.MessageBox]::Show("$_",'Historico CSV');return}
    $d=New-Object Windows.Forms.Form;$d.Name='histCSV';$d.Text="Historico CSV - $($ctx.planta) / NCU$($ctx.ncu) / $($ctx.equipo)"
    $d.Size=New-Object Drawing.Size(950,700);$d.MinimumSize=New-Object Drawing.Size(750,550);$d.StartPosition='CenterParent';$d.Font=$form.Font
    $l=New-Object Windows.Forms.TableLayoutPanel;$l.Dock='Fill';$l.ColumnCount=1;$l.RowCount=5
    foreach($h in @(58,42,38)){[void]$l.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$h)))}
    [void]$l.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)));[void]$l.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',56)));$d.Controls.Add($l)
    $aviso=New-Object Windows.Forms.Label;$aviso.Dock='Fill';$aviso.Padding=New-Object Windows.Forms.Padding(8)
    $aviso.Text="HISTORICO: no representa el estado actual. Origen: $($ctx.planta) / $($ctx.ip) / NCU$($ctx.ncu).`r`nHoras tal como las registra la NCU; si el CSV no indica zona horaria, no se presupone ninguna.";$l.Controls.Add($aviso)
    $barra=Sec-Barra $l
    $dia=New-Object Windows.Forms.DateTimePicker;$dia.Format='Custom';$dia.CustomFormat='yyyy-MM-dd';$dia.Width=120;$dia.Value=(Get-Date).AddDays(-1);$dia.MaxDate=(Get-Date).Date;$barra.Controls.Add($dia)
    $desc=Sec-Boton $barra 'Descargar / actualizar'
    $ref=Sec-Boton $barra 'Leer copia local';$ref.Name='histLeer'
    $abrir=Sec-Boton $barra 'Abrir carpeta'
    $web=Sec-Boton $barra 'Importador web'
    $csv=New-Object Windows.Forms.ComboBox;$csv.Dock='Fill';$csv.DropDownStyle='DropDownList';$l.Controls.Add($csv)
    $grid=New-Object Windows.Forms.DataGridView;$grid.Name='histTabla';$grid.Dock='Fill';$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.AutoSizeColumnsMode='DisplayedCells';$grid.RowHeadersVisible=$false;$l.Controls.Add($grid)
    $estado=New-Object Windows.Forms.Label;$estado.Dock='Fill';$estado.Padding=New-Object Windows.Forms.Padding(8);$estado.Text='Elige un dia y descarga los logs, o lee una copia local ya descargada.';$l.Controls.Add($estado)
    $st=@{ruta='';proceso=$null}
    $cargar={
        $csv.Items.Clear();$grid.DataSource=$null
        $fecha=$dia.Value.ToString('yyyy-MM-dd')
        $st.ruta=Join-Path $ctx.carpeta "NCU$($ctx.ncu)\NCU$($ctx.ncu)_$fecha.zip"
        try{
            if(-not (Test-Path -LiteralPath $st.ruta)){throw 'No hay copia local de este dia. Pulsa Descargar / actualizar.'}
            $entradas=@(Hist-Entradas $st.ruta)
            foreach($e in $entradas){[void]$csv.Items.Add($e)}
            $estado.Text="ZIP local: $((Get-Item -LiteralPath $st.ruta).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')). Elige un CSV; la lista incluye toda la NCU."
            # Seleccion exacta por tipo e ID; no confundir TCU 1 y TCU 10.
            $patron='(?i)(?:^|[/\\_\]])'+[regex]::Escape($ctx.tipo)+'[_-]0*'+[regex]::Escape(($ctx.equipo -replace '\D',''))+'[_-]'
            if($ctx.tipo -eq 'NCU'){$patron='(?i)(?:^|[/\\_\]])NCU[_-]\d{4}'}
            for($i=0;$i -lt $csv.Items.Count;$i++){if("$($csv.Items[$i])" -match $patron){$csv.SelectedIndex=$i;break}}
        }catch{$estado.Text="$_"}
    }.GetNewClosure()
    $csv.Add_SelectedIndexChanged({
        if($csv.SelectedIndex -lt 0){return}
        try{
            $d.UseWaitCursor=$true;$r=Hist-Leer $st.ruta "$($csv.SelectedItem)"
            $tabla=New-Object Data.DataTable
            foreach($p in $r.filas[0].PSObject.Properties){[void]$tabla.Columns.Add($p.Name,[string])}
            # Limite de representacion: original completo conservado en el ZIP.
            foreach($f in @($r.filas | Select-Object -Last 2000)){
                $row=$tabla.NewRow();foreach($p in $f.PSObject.Properties){$row[$p.Name]="$($p.Value)"};$tabla.Rows.Add($row)
            }
            $grid.DataSource=$tabla
            $estado.Text="$($csv.SelectedItem) | $($r.filas.Count) muestras unicas; se muestran las ultimas $($tabla.Rows.Count).`r`nDuplicados exactos omitidos: $($r.duplicadas). Filas distintas con la misma hora: $($r.conflictos), conservadas. ZIP original intacto."
        }catch{$grid.DataSource=$null;$estado.Text="$_"}finally{$d.UseWaitCursor=$false}
    }.GetNewClosure())
    $ref.Add_Click($cargar)
    $dia.Add_ValueChanged({$csv.Items.Clear();$grid.DataSource=$null;$estado.Text='Dia cambiado: descarga o lee su copia local.'}.GetNewClosure())
    $desc.Add_Click({
        try{
            if($st.proceso -and -not $st.proceso.HasExited){$estado.Text='La consola de descarga sigue abierta. Finalizala antes de iniciar otra.';return}
            $st.proceso=Hist-Descargar $ctx $dia.Value.ToString('yyyy-MM-dd')
            $estado.Text='Descarga en consola independiente. Cuando termine, pulsa Leer copia local. Si falla, se conserva el ZIP anterior.'
        }catch{$estado.Text="$_"}
    }.GetNewClosure())
    $abrir.Add_Click({[void][IO.Directory]::CreateDirectory($ctx.carpeta);Start-Process explorer.exe -ArgumentList ('"'+$ctx.carpeta+'"')}.GetNewClosure())
    $web.Add_Click({Start-Process ('https://factiun-cartera.imoriana3.workers.dev/importar-logs.html?planta='+[Uri]::EscapeDataString($ctx.planta))}.GetNewClosure())
    try{[void]$d.ShowDialog($form)}finally{$d.Dispose()}
}
