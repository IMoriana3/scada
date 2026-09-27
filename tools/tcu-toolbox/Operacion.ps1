# Operación local: consume el diagnóstico existente, nunca consulta Modbus.
# La identidad operativa incluye planta, conexión capturada, NCU, gateway y equipo.
$script:OpMeta=New-Object 'System.Collections.Generic.Dictionary[object,object]'
$script:OpIncidencias=@{}
$script:OpFichero=Join-Path $PSScriptRoot 'registro/operacion.json'
$script:OpUmbral=300 # antigüedad visual, no umbral de seguridad ni periodo de lectura
$script:OpLectura=$null
$script:OpError=''
function Op-Clave($fila,$meta,$trabajos) {
    $ip='';$puerto="$($fila.GW)"
    $tr=@($trabajos|Where-Object{"$($_.ncu)" -eq "$($fila.NCU)"})
    if($tr.Count -eq 1){$ip="$($tr[0].ip)";if(-not $puerto){$puerto="$($tr[0].cx.puerto)"}}
    return (@("$($meta.planta)",$ip,"$($fila.NCU)",$puerto,(Fila-Tipo $fila),"$($fila.TCU)")|ForEach-Object{[uri]::EscapeDataString($_)}) -join '|'
}
function Op-Calidad($fila,$meta,[datetime]$ahora,[int]$umbral=300) {
    if(-not $meta -or $meta.origen -ne 'lectura'){return 'IMPORTADO / SIN ORIGEN'}
    $edadLectura=[math]::Max(0,($ahora-[datetime]$meta.fecha).TotalSeconds)
    if($edadLectura -gt $umbral){return 'LECTURA ANTIGUA'}
    $edad=0.0
    if([double]::TryParse("$($fila.Edad_s)",[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$edad) -and $edad -ge 0){
        if(($edad+$edadLectura) -gt $umbral){return 'DATO ANTIGUO'}
    }else{return 'EDAD DE ORIGEN DESCONOCIDA'}
    return 'LECTURA RECIENTE'
}
function Op-Prioridad($fila,[string]$calidad) {
    if("$($fila.Salud)" -eq 'ALARMA'){return 1}
    if("$($fila.Salud)" -in @('OFFLINE','SIN LECTURA')){return 2}
    if("$($fila.Salud)" -eq 'AVISO'){return 3}
    if("$($fila.Salud)" -ne 'OK' -or $calidad -ne 'LECTURA RECIENTE'){return 4}
    return 5
}
function Op-Episodio($anterior,$fila,$meta) {
    # Reconocer una alarma no modifica Salud ni manda CLEAR al equipo.
    $firma="$($fila.Salud)|$($fila.Alarmas)"
    $activo="$($fila.Salud)" -ne 'OK'
    if(-not $activo){
        if($anterior){$anterior.activa=$false;$anterior.ultima="$($meta.fecha)"}
        return $anterior
    }
    if(-not $anterior -or -not $anterior.activa -or $anterior.firma -ne $firma){
        return @{firma=$firma;activa=$true;primera="$($meta.fecha)";ultima="$($meta.fecha)";reconocida='';usuario='';nota=''}
    }
    $anterior.ultima="$($meta.fecha)"
    return $anterior
}
function Op-Cargar {
    if(-not (Test-Path $script:OpFichero)){return}
    try{
        $o=Get-Content $script:OpFichero -Raw|ConvertFrom-Json
        foreach($p in $o.PSObject.Properties){
            $d=@{};foreach($v in $p.Value.PSObject.Properties){$d[$v.Name]=$v.Value}
            $script:OpIncidencias[$p.Name]=$d
        }
    }catch{$script:OpError="No se pudo cargar el registro de incidencias: $_"}
}
function Op-Guardar {
    try{
        $dir=Split-Path $script:OpFichero -Parent
        if(-not (Test-Path $dir)){[void](New-Item -ItemType Directory -Path $dir -Force)}
        $temporal=$script:OpFichero+'.tmp'
        ConvertTo-Json -InputObject $script:OpIncidencias -Depth 6|Set-Content $temporal -Encoding UTF8
        Move-Item $temporal $script:OpFichero -Force
        $script:OpError='';return $true
    }catch{$script:OpError="No se guardaron las incidencias: $_";return $false}
}
function Op-IniciarLectura {
    $script:OpLectura=@{origen='lectura';fecha=(Get-Date).ToString('o');planta=(Nombre-Planta)}
}
function Op-Importar($filas,[string]$planta,[string]$fecha) {
    $script:OpMeta.Clear()
    foreach($f in $filas){$script:OpMeta[$f]=@{origen='importado';fecha=$fecha;planta=$planta;modo='copia'}}
}
function Op-Actualizar {
    if($null -eq $script:OpMeta){return}
    $cambios=$false
    foreach($f in $script:UltimoDiag){
        if($null -eq $f -or $script:OpMeta.ContainsKey($f)){continue}
        $tr=Diag-OrigenFila $f
        if($tr -and $script:OpLectura){
            $m=@{origen='lectura';fecha=$script:OpLectura.fecha;planta=$script:OpLectura.planta;modo=$(if($script:UltimoEsComm){'comunicaciones'}else{'diagnóstico'})}
            $script:OpMeta[$f]=$m
            # Un test de comunicaciones no confirma la desaparición de una alarma de equipo.
            if($m.modo -eq 'diagnóstico'){
                $clave=Op-Clave $f $m $tr
                $ep=Op-Episodio $script:OpIncidencias[$clave] $f $m
                if($ep){$script:OpIncidencias[$clave]=$ep;$cambios=$true}
            }
        }else{$script:OpMeta[$f]=@{origen='importado';fecha='';planta='Origen no identificado';modo='copia'}}
    }
    # Solo se conservan objetos de las filas presentes; los reconocimientos van por identidad.
    $vivas=New-Object 'System.Collections.Generic.HashSet[object]'
    foreach($f in $script:UltimoDiag){if($null -ne $f){[void]$vivas.Add($f)}}
    foreach($f in @($script:OpMeta.Keys)){if(-not $vivas.Contains($f)){[void]$script:OpMeta.Remove($f)}}
    if($cambios){[void](Op-Guardar)}
    if($script:OpLista){Op-Pintar}
}
function Op-Filas {
    $ahora=Get-Date
    foreach($f in $script:UltimoDiag){
        if($null -eq $f){continue}
        $m=$script:OpMeta[$f];$tr=Diag-OrigenFila $f
        if(-not $m){$m=@{origen='importado';planta='Origen no identificado';fecha='';modo='copia'}}
        $clave=Op-Clave $f $m $tr;$calidad=Op-Calidad $f $m $ahora $script:OpUmbral
        $ep=$null;if($m.origen -eq 'lectura' -and $m.modo -eq 'diagnóstico'){$ep=$script:OpIncidencias[$clave]}
        [pscustomobject]@{clave=$clave;fila=$f;meta=$m;trabajos=$tr;calidad=$calidad;prioridad=(Op-Prioridad $f $calidad);episodio=$ep}
    }
}
function Op-Pintar {
    if($script:OpPintando -or -not $script:OpLista){return}
    $script:OpPintando=$true
    try{
        $todas=@(Op-Filas)
        $planta="$($script:OpPlanta.SelectedItem)"
        $plantas=@($todas|ForEach-Object{$_.meta.planta}|Sort-Object -Unique)
        $script:OpPlanta.Items.Clear();[void]$script:OpPlanta.Items.Add('Todos los orígenes')
        foreach($p in $plantas){[void]$script:OpPlanta.Items.Add($p)}
        if($script:OpPlanta.Items.Contains($planta)){$script:OpPlanta.SelectedItem=$planta}else{$script:OpPlanta.SelectedIndex=0}
        $filas=@($todas|Where-Object{$script:OpPlanta.SelectedIndex -eq 0 -or $_.meta.planta -eq "$($script:OpPlanta.SelectedItem)"})
        $alarmas=@($filas|Where-Object{$_.fila.Salud -eq 'ALARMA'}).Count
        $sin=@($filas|Where-Object{$_.fila.Salud -in @('OFFLINE','SIN LECTURA')}).Count
        $actuales=@($filas|Where-Object{$_.calidad -eq 'LECTURA RECIENTE'}).Count
        $script:OpResumen.Text="ALCANCE CARGADO: $($filas.Count) equipos     |     ALARMAS OBSERVADAS: $alarmas     |     SIN RESPUESTA / LECTURA: $sin     |     LECTURAS RECIENTES: $actuales"
        $script:OpContexto.Text='Prioridad: 1 alarma · 2 sin respuesta · 3 aviso · 4 calidad del dato. Datos del último barrido, sin vigilancia continua. Reciente = lectura y edad disponible ≤ 5 min; una edad de origen desconocida no acredita telemetría actual. El alcance puede ser parcial. Un test de comunicaciones no evalúa alarmas ni movimiento.'
        if($script:OpError){$script:OpContexto.Text=$script:OpError}
        $seleccion='';if($script:OpLista.SelectedItems.Count){$seleccion=$script:OpLista.SelectedItems[0].Tag.clave}
        $script:OpLista.BeginUpdate();$script:OpLista.Items.Clear()
        foreach($r in @($filas|Sort-Object prioridad,@{Expression={$_.fila.NCU}},@{Expression={$_.fila.TCU}})){
            if($script:OpFiltro.SelectedIndex -eq 0 -and $r.prioridad -eq 5){continue}
            if($script:OpFiltro.SelectedIndex -eq 2 -and ($r.prioridad -eq 5 -or $r.episodio.reconocida)){continue}
            $it=New-Object Windows.Forms.ListViewItem("$($r.prioridad)")
            $ack='';if($r.episodio.reconocida){$ack='Vista por '+$r.episodio.usuario}
            $edad="$($r.fila.Edad_s)";if(-not $edad){$edad='No disponible'}
            foreach($v in @($r.meta.planta,$r.fila.NCU,$r.fila.TCU,$r.fila.Salud,$r.calidad,$r.meta.modo,$edad,$r.fila.Alarmas,$ack)){[void]$it.SubItems.Add("$v")}
            $it.Tag=$r
            if($r.prioridad -eq 1){$it.ForeColor=[Drawing.Color]::Firebrick}
            elseif($r.prioridad -le 3){$it.ForeColor=[Drawing.Color]::FromArgb(142,73,0)}
            elseif($r.prioridad -eq 4){$it.ForeColor=[Drawing.Color]::DimGray}
            [void]$script:OpLista.Items.Add($it)
            if($r.clave -eq $seleccion){$it.Selected=$true}
        }
        $script:OpLista.EndUpdate();Op-Seleccion
    }finally{$script:OpPintando=$false}
}
function Op-Seleccion {
    $script:OpDetalle.Text='Selecciona una incidencia para consultar su origen y abrir el equipo. Reconocerla no borra la alarma ni ejecuta órdenes.'
    $script:OpVer.Enabled=$false;$script:OpReconocer.Enabled=$false;$script:OpNota.Enabled=$false
    if($script:OpLista.SelectedItems.Count -ne 1){return}
    $r=$script:OpLista.SelectedItems[0].Tag
    $script:OpDetalle.Text="NCU$($r.fila.NCU) / $($r.fila.TCU) | $($r.meta.planta) | $($r.calidad)`r`nAdquisición: $($r.meta.fecha) | $($r.meta.modo)`r`nPrimera detección: $($r.episodio.primera) | Última detección: $($r.episodio.ultima)`r`nReconocimiento: $($r.episodio.reconocida) $($r.episodio.usuario)`r`nNota: $($r.episodio.nota)"
    $script:OpVer.Enabled=-not $script:Ocupado
    $editable=$r.episodio -and $r.episodio.activa -and $r.meta.origen -eq 'lectura' -and -not $script:Ocupado
    $script:OpReconocer.Enabled=$editable -and -not $r.episodio.reconocida
    $script:OpNota.Enabled=[bool]$editable
}
function Op-VerEquipo {
    if($script:Ocupado -or $script:OpLista.SelectedItems.Count -ne 1){return}
    $r=$script:OpLista.SelectedItems[0].Tag
    Diag-Acciones @{fila=$r.fila;trabajos=$r.trabajos}
}
function Op-Anotar([bool]$reconocer) {
    if($script:Ocupado -or $script:OpLista.SelectedItems.Count -ne 1){return}
    $r=$script:OpLista.SelectedItems[0].Tag
    if(-not $r.episodio -or -not $r.episodio.activa -or $r.meta.origen -ne 'lectura'){return}
    $previo=@{};foreach($k in $r.episodio.Keys){$previo[$k]=$r.episodio[$k]}
    if($reconocer){$r.episodio.reconocida=(Get-Date).ToString('o');$r.episodio.usuario="$($script:Usuario.nombre)"}
    else{
        $d=New-Object Windows.Forms.Form;$d.Text='Nota de la incidencia';$d.Size=New-Object Drawing.Size(520,280);$d.StartPosition='CenterParent'
        $t=New-Object Windows.Forms.TextBox;$t.Multiline=$true;$t.Dock='Fill';$t.Text=$r.episodio.nota;$t.MaxLength=2000
        $b=New-Object Windows.Forms.Button;$b.Dock='Bottom';$b.Height=32;$b.Text='Guardar nota';$b.DialogResult='OK'
        $d.Controls.Add($t);$d.Controls.Add($b)
        try{if($d.ShowDialog($form) -ne 'OK'){return};$r.episodio.nota=$t.Text}finally{$d.Dispose()}
    }
    if(-not (Op-Guardar)){$script:OpIncidencias[$r.clave]=$previo}
    else{Auditar $(if($reconocer){'INCIDENCIA_VISTA'}else{'INCIDENCIA_NOTA'}) "$($r.fila.NCU)" "$($r.fila.TCU)" "$($r.clave) | $($r.episodio.nota)"}
    Op-Pintar
}
function Op-Crear($pagina) {
    $pagina.Text='Operación';$pagina.BackColor=[Drawing.Color]::FromArgb(244,246,249)
    $layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(10);$layout.ColumnCount=1;$layout.RowCount=6
    foreach($h in @(48,64,44)){[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$h)))}
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',102)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',36)))
    $pagina.Controls.Add($layout)
    $script:OpResumen=New-Object Windows.Forms.Label;$script:OpResumen.Dock='Fill';$script:OpResumen.Font=$script:FuenteNeg;$script:OpResumen.TextAlign='MiddleLeft';$layout.Controls.Add($script:OpResumen)
    $script:OpContexto=New-Object Windows.Forms.Label;$script:OpContexto.Dock='Fill';$layout.Controls.Add($script:OpContexto)
    $barra=New-Object Windows.Forms.FlowLayoutPanel;$barra.Dock='Fill';$layout.Controls.Add($barra)
    $script:OpPlanta=New-Object Windows.Forms.ComboBox;$script:OpPlanta.Width=190;$script:OpPlanta.DropDownStyle='DropDownList';$barra.Controls.Add($script:OpPlanta)
    $script:OpFiltro=New-Object Windows.Forms.ComboBox;$script:OpFiltro.Width=190;$script:OpFiltro.DropDownStyle='DropDownList'
    [void]$script:OpFiltro.Items.AddRange(@('Incidencias y datos dudosos','Todos los equipos','Pendientes de reconocer'));$script:OpFiltro.SelectedIndex=0;$barra.Controls.Add($script:OpFiltro)
    $b=Sec-Boton $barra 'Preparar diagnóstico';$b.Add_Click({if($script:Ocupado){return};$script:DiagNivel='todo';$tabs.SelectedTab=$tabG;Diag-Refrescar})
    $script:OpLista=New-Object Windows.Forms.ListView;$script:OpLista.Dock='Fill';$script:OpLista.View='Details';$script:OpLista.FullRowSelect=$true;$script:OpLista.MultiSelect=$false;$script:OpLista.HideSelection=$false
    foreach($c in @(@('P',30),@('Origen / planta',150),@('NCU',48),@('Equipo',62),@('Estado',90),@('Calidad del dato',158),@('Lectura',100),@('Edad origen s',95),@('Alarma / motivo',250),@('Reconocimiento',150))){[void]$script:OpLista.Columns.Add($c[0],[int]$c[1])}
    $layout.Controls.Add($script:OpLista)
    $script:OpDetalle=New-Object Windows.Forms.TextBox;$script:OpDetalle.Dock='Fill';$script:OpDetalle.Multiline=$true;$script:OpDetalle.ReadOnly=$true;$script:OpDetalle.ScrollBars='Vertical';$layout.Controls.Add($script:OpDetalle)
    $acciones=New-Object Windows.Forms.FlowLayoutPanel;$acciones.Dock='Fill';$layout.Controls.Add($acciones)
    $script:OpVer=Sec-Boton $acciones 'Equipo y acciones';$script:OpReconocer=Sec-Boton $acciones 'Reconocer incidencia';$script:OpNota=Sec-Boton $acciones 'Añadir / editar nota'
    $script:OpVer.Add_Click({Op-VerEquipo});$script:OpReconocer.Add_Click({Op-Anotar $true});$script:OpNota.Add_Click({Op-Anotar $false})
    $script:OpLista.Add_DoubleClick({Op-VerEquipo});$script:OpLista.Add_SelectedIndexChanged({if(-not $script:OpPintando){Op-Seleccion}})
    $script:OpPlanta.Add_SelectedIndexChanged({if(-not $script:OpPintando){Op-Pintar}});$script:OpFiltro.Add_SelectedIndexChanged({Op-Pintar})
    # Solo recalcula antigüedad visible; no crea lecturas ni procesos de adquisición.
    $script:OpReloj=New-Object Windows.Forms.Timer;$script:OpReloj.Interval=30000
    $script:OpReloj.Add_Tick({if($tabs.SelectedTab -eq $tabOP -and -not $script:Ocupado){Op-Pintar}});$script:OpReloj.Start()
    $form.Add_FormClosed({$script:OpReloj.Stop();$script:OpReloj.Dispose()})
    $tabs.Add_SelectedIndexChanged({if($tabs.SelectedTab -eq $tabOP -and -not $script:Ocupado){Op-Actualizar}})
    Op-Cargar;Op-Pintar
}
