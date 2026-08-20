# Auditoria estatica de la maqueta: extrae la geometria de todos los controles
# del script, aplica las reglas de anclaje y simula agrandar la ventana, para
# ver si algo acaba encima de algo.
$raizTb = Split-Path $PSScriptRoot -Parent
$src = Get-Content (Join-Path $raizTb 'TCU_Toolbox.ps1') -Raw
$i6 = $src.IndexOf('function Anclaje-Para'); $f6 = $src.IndexOf('# Anclar contra un contenedor')
Invoke-Expression $src.Substring($i6, $f6 - $i6)

$ctrl = @{}   # nombre -> @{tipo; left; top; ancho; alto; padre}
foreach ($l in ($src -split "`r?`n")) {
    if ($l -match '^\s*\$(\w+)\s*=\s*New-Object System\.Windows\.Forms\.(\w+)') {
        if (-not $ctrl.ContainsKey($matches[1])) { $ctrl[$matches[1]] = @{tipo=$matches[2]; left=0; top=0; ancho=0; alto=0; padre=''} }
        else { $ctrl[$matches[1]].tipo = $matches[2] }
    }
    elseif ($l -match '^\s*\$(\w+)\.Location\s*=\s*New-Object System\.Drawing\.Point\((\d+),\s*(\d+)\)') {
        if ($ctrl.ContainsKey($matches[1])) { $ctrl[$matches[1]].left = [int]$matches[2]; $ctrl[$matches[1]].top = [int]$matches[3] }
    }
    elseif ($l -match '^\s*\$(\w+)\.Size\s*=\s*New-Object System\.Drawing\.Size\((\d+),\s*(\d+)\)') {
        if ($ctrl.ContainsKey($matches[1])) { $ctrl[$matches[1]].ancho = [int]$matches[2]; $ctrl[$matches[1]].alto = [int]$matches[3] }
    }
    elseif ($l -match '\$(\w+)\.Controls\.Add\(\$(\w+)\)') {
        if ($ctrl.ContainsKey($matches[2])) { $ctrl[$matches[2]].padre = $matches[1] }
    }
    # helpers: LG $tab 'txt' x w [y]  y  TG $tab 'txt' x y w
    elseif ($l -match "LG\s+\`$(\w+)\s+'[^']*'\s+(\d+)\s+(\d+)(?:\s+(\d+))?") {
        $y = if ($matches[4]) { [int]$matches[4] } else { 25 }
        $ctrl["_lg$($ctrl.Count)"] = @{tipo='Label'; left=[int]$matches[2]; top=$y; ancho=[int]$matches[3]; alto=20; padre=$matches[1]}
    }
    elseif ($l -match "=\s*TG\s+\`$(\w+)\s+'[^']*'\s+(\d+)\s+(\d+)\s+(\d+)") {
        $ctrl["_tg$($ctrl.Count)"] = @{tipo='TextBox'; left=[int]$matches[2]; top=[int]$matches[3]; ancho=[int]$matches[4]; alto=22; padre=$matches[1]}
    }
}

# Los dialogos modales (login, alta de usuario, gestion) son FixedDialog: no se
# redimensionan, asi que simular que la ventana crece no dice nada de ellos. Y
# como todos reutilizan la variable $d, el parser los mezclaria en un solo
# contenedor y cantaria solapes que no existen. Fuera: la auditoria es de la
# ventana principal, que es la unica que crece.
# Controles que nacen ocultos (la barra de avance comparte sitio con el aviso
# del log a proposito): no pueden solaparse con nada porque no estan a la vez.
foreach ($l in ($src -split "`r?`n")) {
    if ($l -match '^\s*\$(\w+)\.Visible\s*=\s*\$false') { if ($ctrl.ContainsKey($matches[1])) { $ctrl[$matches[1]].oculto = $true } }
}

$porPadre = @{}
foreach ($k in $ctrl.Keys) {
    $p = $ctrl[$k].padre
    if (-not $p) { continue }
    if ($p -ne 'form' -and $ctrl.ContainsKey($p) -and $ctrl[$p].tipo -eq 'Form') { continue }
    if ($ctrl[$k].oculto) { continue }
    if (-not $porPadre.ContainsKey($p)) { $porPadre[$p] = @() }
    $porPadre[$p] += ,@{nombre=$k; g=$ctrl[$k]}
}

function TipoDe($t) {
    if ($t -in @('ListView','DataGridView','RichTextBox')) { return 'tabla' }
    if ($t -eq 'GroupBox') { return 'grupo' }
    if ($t -eq 'Button') { return 'boton' }
    if ($t -eq 'Label') { return 'etiqueta' }
    return 'otro'
}

$CREC_W = 1000; $CREC_H = 600     # cuanto crece la ventana al maximizar
$solapes = @()
foreach ($padre in ($porPadre.Keys | Sort-Object)) {
    $hijos = @($porPadre[$padre])
    if ($hijos.Count -lt 2) { continue }
    $anchoRef = 901
    $tablas = @($hijos | Where-Object { (TipoDe $_.g.tipo) -eq 'tabla' })
    $topeAbajo = -1
    foreach ($t in $tablas) { if ($t.g.top -gt $topeAbajo) { $topeAbajo = $t.g.top } }
    $abajoTabla = -1
    foreach ($t in $tablas) { if ($t.g.top -eq $topeAbajo) { $abajoTabla = $t.g.top + $t.g.alto } }
    $fin = @()
    foreach ($h in $hijos) {
        $tipo = TipoDe $h.g.tipo
        $vec = $false
        foreach ($o in $hijos) {
            if ($o.nombre -eq $h.nombre -or $o.g.left -le $h.g.left) { continue }
            if (($o.g.top -ge ($h.g.top + $h.g.alto)) -or (($o.g.top + $o.g.alto) -le $h.g.top)) { continue }
            $vec = $true; break
        }
        $a = Anclaje-Para @{tipo=$tipo; top=$h.g.top; left=$h.g.left; ancho=$h.g.ancho; alto=$h.g.alto
                            anchoRef=$anchoRef; crece=($h.g.top -eq $topeAbajo -and $tipo -eq 'tabla'); abajoTabla=$abajoTabla
                            vecinoDerecha=$vec}
        $L = $h.g.left; $T = $h.g.top; $W = $h.g.ancho; $H = $h.g.alto
        if ($a -like '*Right*' -and $a -like '*Left*') { $W += $CREC_W } elseif ($a -like '*Right*') { $L += $CREC_W }
        if ($a -like '*Bottom*' -and $a -like '*Top*') { $H += $CREC_H } elseif ($a -like '*Bottom*') { $T += $CREC_H }
        $fin += ,@{nombre=$h.nombre; tipo=$tipo; L=$L; T=$T; W=$W; H=$H; a=$a}
    }
    for ($i = 0; $i -lt $fin.Count; $i++) {
        for ($j = $i + 1; $j -lt $fin.Count; $j++) {
            $x = $fin[$i]; $y = $fin[$j]
            if ($x.L -lt ($y.L + $y.W) -and $y.L -lt ($x.L + $x.W) -and $x.T -lt ($y.T + $y.H) -and $y.T -lt ($x.T + $x.H)) {
                $solapes += ("{0} : {1} {2}x{3}@{4},{5} [{6}]  vs  {7} {8}x{9}@{10},{11} [{12}]" -f $padre, $x.nombre, $x.W, $x.H, $x.L, $x.T, $x.a, $y.nombre, $y.W, $y.H, $y.L, $y.T, $y.a)
            }
        }
    }
}
if ($solapes.Count -eq 0) { Write-Output 'SIN SOLAPES al agrandar la ventana' }
else { $solapes | ForEach-Object { Write-Output "SOLAPE  $_" } }

# ---------------------------------------------------------------------------
#  DESBORDES: lo que cae fuera de la ventana en su tamano MINIMO
# ---------------------------------------------------------------------------
# La auditoria de arriba comprueba que nada se monte encima de nada al AGRANDAR
# la ventana. No comprobaba lo contrario, y es el hueco por el que se colo un
# defecto real (v11.55): cinco campos de la pestana SAT se colocaron de x=892 a
# x=1222 y la pestana tiene ~919 px utiles.
#
# Lo que le pasa a un control que se sale NO es desaparecer: Layout-Rescatar lo
# MUEVE al borde de su contenedor al arrancar. Asi que esos cinco campos no
# habrian estado invisibles -eso se dijo mal en el PR #201-, habrian aparecido
# amontonados contra el borde derecho, unos encima de otros y encima de la fila
# del cronometro. Peor, no mejor: un control invisible se echa en falta; uno
# que aparece donde no toca se rellena creyendo que es otro.
#
# Y no es estetica. Esos cinco campos existen para no dar por supuesto el
# criterio de una planta (si abandera cara al sol o cara al viento, el limite
# de mediodia, el lado de la suelta pasiva); fuera de sitio, daban por supuesto
# el criterio de una planta. Un control que no esta donde se le puso es un
# default silencioso con otro disfraz.
#
# La ventana no se puede encoger por debajo de su MinimumSize, asi que este
# tamano es el PEOR CASO real y la comprobacion es exacta, no una estimacion.
#
# El tamano sale de $pnlCuerpo, que es lo que de verdad recorta: el TabControl
# se sale de su panel A PROPOSITO -Nav-OcultarCabecera le pone Top = -hCab y le
# suma esa misma altura- para dejar la fila de solapas fuera y que el panel se
# la coma. O sea que la fila de solapas NO le quita alto a la pestana: restarla
# daba 368 px y la pestana tiene ~394, y con esa cuenta salian diez controles
# marcados que caben de sobra. Lo unico que se descuenta es el borde interior.
$m = [regex]::Match($src, '\$pnlCuerpo\.Size\s*=\s*New-Object System\.Drawing\.Size\((\d+),\s*(\d+)\)')
if (-not $m.Success) { Write-Output 'NO SE ENCUENTRA $pnlCuerpo.Size'; exit 1 }
$MARGEN = 6                              # borde interior de una pestana
$ANCHO_UTIL = [int]$m.Groups[1].Value - $MARGEN
$ALTO_UTIL  = [int]$m.Groups[2].Value - $MARGEN

$desbordes = @()
foreach ($k in ($ctrl.Keys | Sort-Object)) {
    $g = $ctrl[$k]
    if (-not $g.padre -or $g.oculto) { continue }
    if ($g.padre -notmatch '^tab') { continue }       # solo pestanas
    if ($g.ancho -le 0 -and $g.alto -le 0) { continue }
    $der = $g.left + $g.ancho
    $aba = $g.top + $g.alto
    if ($der -gt $ANCHO_UTIL) {
        $desbordes += ("{0} : {1} llega a x={2} y la pestana tiene {3} px utiles ({4} px fuera)" -f
                       $g.padre, $k, $der, $ANCHO_UTIL, ($der - $ANCHO_UTIL))
    }
    if ($aba -gt $ALTO_UTIL) {
        $desbordes += ("{0} : {1} llega a y={2} y la pestana tiene {3} px utiles ({4} px fuera)" -f
                       $g.padre, $k, $aba, $ALTO_UTIL, ($aba - $ALTO_UTIL))
    }
}
if ($desbordes.Count -eq 0) { Write-Output 'SIN DESBORDES en la ventana minima' }
else { $desbordes | ForEach-Object { Write-Output "DESBORDE  $_" } }

Write-Output "controles analizados: $($ctrl.Count)"
if ($solapes.Count -gt 0 -or $desbordes.Count -gt 0) { exit 1 }
