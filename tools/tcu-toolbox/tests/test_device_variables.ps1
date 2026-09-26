# Contrato de las nuevas tablas de variables NCU y HSU; no requiere hardware.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count) { throw ($parseErrors | ForEach-Object { "Linea $($_.Extent.StartLineNumber): $($_.Message)" } | Out-String) }
$src = Get-Content $source -Raw
$defs = [regex]::Matches($src, '\$DISP_MAP\[''(NCU|HSU)''\]\[''([^'']+)''\] = @\{addr=(\d+); tipo=''([^'']+)''; acc=''([^'']+)''\}')
$map = @{NCU=@{}; HSU=@{}}
foreach ($m in $defs) {
    $equipo = $m.Groups[1].Value; $nombre = $m.Groups[2].Value
    if ($map[$equipo].ContainsKey($nombre)) { throw "Duplicada: $equipo $nombre" }
    $map[$equipo][$nombre] = @{addr=[int]$m.Groups[3].Value; tipo=$m.Groups[4].Value; acc=$m.Groups[5].Value}
}
if ($map.NCU.Count -lt 12 -or $map.HSU.Count -lt 80) { throw 'Mapa NCU/HSU incompleto' }
if ($map.NCU['40004 force_sp_4'].acc -ne 'R' -or $map.NCU.ContainsKey('40070 auto_mode') -or $map.NCU.ContainsKey('40071 manual_mode') -or $map.NCU['40080 custom_position_timeout'].acc -ne 'R') { throw 'Comandos NCU expuestos fuera de Grupos NCU' }
if ($map.HSU['41013 WindSpeedMid_mps'].tipo -ne 'f32' -or $map.HSU['30003 WindSpeed_mps'].acc -ne 'R') { throw 'Mapa HSU incorrecto' }
if (@($map.HSU.Values | Where-Object { $_.addr -ge 50000 -and $_.acc -match 'W' }).Count) { throw 'Firmware HSU en tabla de escritura' }
$fn = @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Disp-Filas'}, $true))
if ($fn.Count -ne 1) { throw 'Falta Disp-Filas' }
function Valor-A-Escritura($def, $valor) { return @{palabras=@([int]$valor)} }
. ([scriptblock]::Create($fn[0].Extent.Text))
function Fila($nombre, $valor) { return [pscustomobject]@{IsNewRow=$false; Cells=@([pscustomobject]@{Value=$nombre},[pscustomobject]@{Value=$valor})} }
$grid = [pscustomobject]@{Rows=@((Fila '30101 MainStatus' '1'))}
if (@(Disp-Filas $grid $map.NCU $false).Count -ne 1) { throw 'La lectura no selecciona variables' }
try { [void](Disp-Filas $grid $map.NCU $true); throw 'Permitio escribir solo lectura' }
catch { if ("$_" -notmatch 'solo lectura') { throw } }
$grid.Rows = @((Fila '41017 WindLowTime_s' '60'),(Fila '41017 WindLowTime_s' '60'))
try { [void](Disp-Filas $grid $map.HSU $true); throw 'Permitio duplicados' }
catch { if ("$_" -notmatch 'repetida') { throw } }
$grid.Rows = @((Fila '40004 force_sp_4' '1'))
try { [void](Disp-Filas $grid $map.NCU $true); throw 'Permitio escribir un grupo por palabra completa' }
catch { if ("$_" -notmatch 'solo lectura') { throw } }
$ej = @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Disp-Ejecutar'}, $true))
if ($ej.Count -ne 1) { throw 'Falta Disp-Ejecutar' }
function Puede($rol) { return $false }
. ([scriptblock]::Create($ej[0].Extent.Text))
try { Disp-Ejecutar 'HSU' $true $null $null; throw 'El rol lectura alcanzo la escritura' }
catch { if ("$_" -notmatch 'requiere rol tecnico') { throw } }
if ($src -notmatch '\$script:BotonesDispEscribir \+= \$accion' -or $src -notmatch '\$BOTONES_TECNICO = @\(\$script:BotonesDispEscribir\)') { throw 'Los botones de escritura no siguen el rol' }
if ($src -notmatch 'VARIABLE_DISPOSITIVO_FALLO' -or $src -notmatch 'VARIABLE_DISPOSITIVO') { throw 'Falta auditoria de las nuevas escrituras' }
Write-Host 'Variables NCU/HSU: parser, mapa, permisos y filas OK'
