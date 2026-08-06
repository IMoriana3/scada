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
Write-Output "controles analizados: $($ctrl.Count)"
