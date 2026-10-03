# Vista numerica de los CSV originales: sin promediar consignas ni inventar zonas.
function Tendencia-Serie($filas,[string]$campo){
    $p=New-Object 'System.Collections.Generic.List[object]';$omitidas=0;$horas=@{}
    foreach($f in $filas){$k="$($f.datetime)";if(-not $horas.ContainsKey($k)){$horas[$k]=0};$horas[$k]++}
    foreach($f in $filas){
        $t=[datetime]::MinValue;$v=0.0
        # Un timestamp ambiguo (dos muestras distintas) se deja como hueco.
        $ok=[datetime]::TryParse("$($f.datetime)",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$t)
        if(-not $ok -or $horas["$($f.datetime)"] -gt 1 -or -not [double]::TryParse("$($f.$campo)",[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$v) -or [double]::IsNaN($v) -or [double]::IsInfinity($v)){$omitidas++;$p.Add(@{corte=$true});continue}
        $p.Add(@{t=$t.Ticks;y=$v;hora="$($f.datetime)";corte=$false})
    }
    $pasos=New-Object 'System.Collections.Generic.List[long]';$anterior=$null
    foreach($x in $p){if(-not $x.corte){if($null -ne $anterior -and $x.t -gt $anterior){$pasos.Add(($x.t-$anterior))};$anterior=$x.t}}
    $limite=[double]::PositiveInfinity
    if($pasos.Count){$pasos=@($pasos|Sort-Object);$limite=3.0*$pasos[[int][math]::Floor($pasos.Count/2)]}
    $segmentos=New-Object 'System.Collections.Generic.List[object]';$seg=New-Object 'System.Collections.Generic.List[object]';$prev=$null
    foreach($x in $p){
        if($x.corte -or ($null -ne $prev -and $x.t-$prev -gt $limite)){
            if($seg.Count){$segmentos.Add(@($seg.ToArray()));$seg.Clear()};$prev=$null
        }
        if(-not $x.corte){$seg.Add($x);$prev=$x.t}
    }
    if($seg.Count){$segmentos.Add(@($seg.ToArray()))}
    # Envolvente min/max por bloque, preservando primero y ultimo. Solo visual.
    $reducidas=New-Object 'System.Collections.Generic.List[object]';$paso=[math]::Max(1,[int][math]::Ceiling($p.Count/1500.0))
    foreach($s in $segmentos){
        $lista=New-Object 'System.Collections.Generic.List[object]'
        for($i=0;$i -lt $s.Count;$i+=$paso){
            $fin=[math]::Min($s.Count-1,$i+$paso-1);$mi=$i;$ma=$i
            for($j=$i;$j -le $fin;$j++){if($s[$j].y -lt $s[$mi].y){$mi=$j};if($s[$j].y -gt $s[$ma].y){$ma=$j}}
            foreach($j in @(@($i,$mi,$ma,$fin)|Sort-Object -Unique)){$lista.Add($s[$j])}
        }
        $reducidas.Add(@($lista.ToArray()))
    }
    return @{campo=$campo;segmentos=@($reducidas.ToArray());omitidas=$omitidas;total=$p.Count;reducida=($paso -gt 1);escalon=($campo -match 'target|state|alarm|status|flags|level|online|enabled|backtracking')}
}
function Tendencia-Dibujar($g,$rect,$series){
    $g.Clear([Drawing.Color]::White)
    $fuente=New-Object Drawing.Font('Segoe UI',9);$pen=New-Object Drawing.Pen([Drawing.Color]::LightGray)
    try{
        $todos=@($series|ForEach-Object{$_.segmentos}|ForEach-Object{$_}|Where-Object{$null -ne $_.t})
        if($todos.Count -eq 0){$g.DrawString('Sin muestras numericas validas en el intervalo.',$fuente,[Drawing.Brushes]::DimGray,20,20);return}
        # Windows PowerShell 5.1 no resuelve claves de hashtable en Measure-Object.
        $xmin=$todos[0].t;$xmax=$xmin;$ymin=$todos[0].y;$ymax=$ymin
        foreach($v in $todos){
            if($v.t -lt $xmin){$xmin=$v.t};if($v.t -gt $xmax){$xmax=$v.t}
            if($v.y -lt $ymin){$ymin=$v.y};if($v.y -gt $ymax){$ymax=$v.y}
        }
        if($xmax -eq $xmin){$xmax=$xmin+[timespan]::TicksPerSecond};if($ymax -eq $ymin){$ymax++;$ymin--}
        $iz=65;$top=40;$w=[math]::Max(50,$rect.Width-90);$h=[math]::Max(40,$rect.Height-85)
        for($i=0;$i -le 4;$i++){$y=$top+$i*$h/4;$g.DrawLine($pen,[single]$iz,[single]$y,[single]($iz+$w),[single]$y);$g.DrawString(('{0:0.##}' -f ($ymax-$i*($ymax-$ymin)/4)),$fuente,[Drawing.Brushes]::DimGray,2,[single]($y-7))}
        $colores=@([Drawing.Color]::FromArgb(22,112,170),[Drawing.Color]::FromArgb(202,111,16))
        for($n=0;$n -lt $series.Count;$n++){
            $serie=$series[$n];$p=New-Object Drawing.Pen($colores[$n%2],1.7);$b=New-Object Drawing.SolidBrush($colores[$n%2])
            try{
                $g.DrawString($serie.campo,$fuente,$b,[single]($iz+$n*190),10)
                foreach($s in $serie.segmentos){$antes=$null
                    foreach($v in $s){
                        $x=[single]($iz+($v.t-$xmin)/($xmax-$xmin)*$w);$y=[single]($top+($ymax-$v.y)/($ymax-$ymin)*$h)
                        if($antes){if($serie.escalon){$g.DrawLine($p,$antes.x,$antes.y,$x,$antes.y);$g.DrawLine($p,$x,$antes.y,$x,$y)}else{$g.DrawLine($p,$antes.x,$antes.y,$x,$y)}}
                        else{$g.FillEllipse($b,$x-2,$y-2,4,4)};$antes=@{x=$x;y=$y}
                    }
                }
            }finally{$p.Dispose();$b.Dispose()}
        }
        $g.DrawString(([datetime][long]$xmin).ToString('dd/MM HH:mm:ss'),$fuente,[Drawing.Brushes]::DimGray,[single]$iz,[single]($top+$h+8))
        $g.DrawString(([datetime][long]$xmax).ToString('dd/MM HH:mm:ss'),$fuente,[Drawing.Brushes]::DimGray,[single]([math]::Max($iz,$iz+$w-130)),[single]($top+$h+8))
    }finally{$fuente.Dispose();$pen.Dispose()}
}
function Tendencia-Abrir($lectura,[string]$origen){
    $d=New-Object Windows.Forms.Form;$d.Name='clienteTendencia';$d.Text='Tendencias · '+$origen;$d.Size=New-Object Drawing.Size(950,630);$d.MinimumSize=New-Object Drawing.Size(750,500);$d.StartPosition='CenterParent';$d.Font=$form.Font
    $l=New-Object Windows.Forms.TableLayoutPanel;$l.Dock='Fill';$l.ColumnCount=1;$l.RowCount=3
    [void]$l.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',58)));[void]$l.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)));[void]$l.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',74)));$d.Controls.Add($l)
    $barra=Sec-Barra $l;$cam=New-Object Windows.Forms.ComboBox;$cam.Width=180;$cam.DropDownStyle='DropDownList';$barra.Controls.Add($cam)
    foreach($p in $lectura.filas[0].PSObject.Properties){if($p.Name -ne 'datetime'){[void]$cam.Items.Add($p.Name)}}
    $objetivo=New-Object Windows.Forms.CheckBox;$objetivo.Text='Comparar target_angle';$objetivo.Width=175;$objetivo.Checked=$true;$barra.Controls.Add($objetivo)
    $export=Sec-Boton $barra 'Guardar grafica PNG'
    $panel=New-Object Windows.Forms.Panel;$panel.Name='trendPanel';$panel.Dock='Fill';$panel.BackColor='White';$l.Controls.Add($panel)
    $nota=New-Object Windows.Forms.Label;$nota.Dock='Fill';$nota.Padding=New-Object Windows.Forms.Padding(8);$l.Controls.Add($nota)
    $st=@{series=@();error=''};$panel.Tag=$st
    $pintar={
        if($cam.SelectedIndex -lt 0){return};$campo="$($cam.SelectedItem)"
        $objetivo.Enabled=$campo -eq 'angle' -and $null -ne $lectura.filas[0].PSObject.Properties['target_angle']
        $st.series=@((Tendencia-Serie $lectura.filas $campo))
        if($objetivo.Enabled -and $objetivo.Checked){$st.series+=,(Tendencia-Serie $lectura.filas 'target_angle')}
        $unidad=@{angle='grados';target_angle='grados';soc='%';voltage='mV';current='mA';motor_current='mA';battery_temp='C';pcb_temp='C';wind_speed='m/s'}[$campo]
        if(-not $unidad){$unidad='unidad del CSV; sin conversion'}
        $nota.Text="HISTORICO · $origen · $unidad. Horas registradas por la NCU; no se infiere zona horaria.`r`nHuecos: valores invalidos, horas en conflicto o salto > 3 cadencias medianas observadas. No equivalen a disponibilidad RF.`r`nEnvolvente visual min/max si hay muchas muestras; consignas y estados a escalones. Los datos originales se conservan."
        $panel.Invalidate()
    }.GetNewClosure()
    $panel.Add_Paint({param($s,$e)
        try{Tendencia-Dibujar $e.Graphics $s.ClientRectangle $st.series;$st.error=''}
        catch{$st.error=($_|Out-String);$nota.Text='No se pudo representar la grafica. Los CSV originales siguen disponibles. '+$_.Exception.Message}
    }.GetNewClosure())
    $panel.Add_Resize({$panel.Invalidate()}.GetNewClosure());$cam.Add_SelectedIndexChanged($pintar);$objetivo.Add_CheckedChanged($pintar)
    $export.Add_Click({
        $dlg=New-Object Windows.Forms.SaveFileDialog;$dlg.Filter='Grafica PNG (*.png)|*.png';$dlg.FileName='tendencia.png'
        try{if($dlg.ShowDialog($d) -ne 'OK'){return};$bmp=New-Object Drawing.Bitmap(1200,600);$g=[Drawing.Graphics]::FromImage($bmp)
            try{Tendencia-Dibujar $g (New-Object Drawing.Rectangle(0,0,1200,560)) $st.series;$ft=New-Object Drawing.Font('Segoe UI',10);try{$g.DrawString('HISTORICO: '+$origen+' | Hora NCU, zona no inferida. Envolvente visual; consultar CSV original.',$ft,[Drawing.Brushes]::Black,10,568)}finally{$ft.Dispose()};$bmp.Save($dlg.FileName)}finally{$g.Dispose();$bmp.Dispose()}
        }catch{[void][Windows.Forms.MessageBox]::Show("$_",'Tendencias')}finally{$dlg.Dispose()}
    }.GetNewClosure())
    if($cam.Items.Contains('angle')){$cam.SelectedItem='angle'}elseif($cam.Items.Count){$cam.SelectedIndex=0}
    try{[void]$d.ShowDialog($form)}finally{$d.Dispose()}
}
