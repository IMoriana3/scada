# Focused unit test for group writes. No plant configuration or device data.
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Toolbox PowerShell syntax errors: $($errors.Count)" }
$names = @('Gr-Mascara', 'FC06-Escribir', 'Gr-EscribirPalabra', 'Gr-EscribirBits',
    'Ang-Palabra', 'Ang-Grados', 'Ang-Texto', 'Ang-Veredicto',
    'Lim-Dir', 'Lim-LeerTcu', 'Lim-EscribirTcu')
foreach ($name in $names) {
    $nodes = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($nodes.Count -ne 1) { throw "Expected exactly one function $name" }
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}

$UNIT_NCU = 1
$INV = [Globalization.CultureInfo]::InvariantCulture
$ANG_NADA = 0x7FFF
$LIM_BASE = 50000; $LIM_PASO = 50; $LIM_ESTE = 47; $LIM_OESTE = 48; $LIM_TCU_MAX = 256
$script:value = 4
$script:fc16Calls = 0
$script:fc06Calls = 0
$script:fc22Calls = 0
$script:fc16Error = 'IllegalFunction (0x01)'
$script:fc22Error = 'IllegalFunction (0x01)'
function Dir-Trama([int]$address) { return $address }
function FC03-Leer([byte]$unit, [int]$address, [int]$count) { return ,@($script:value) }
function FC16-Escribir([byte]$unit, [int]$address, [int[]]$words) {
    $script:fc16Calls++
    if ($script:fc16Error) { throw $script:fc16Error }
    $script:value = $words[0]
}
function FC22-Mascara([byte]$unit, [int]$address, [int]$and, [int]$or) {
    $script:fc22Calls++
    if ($script:fc22Error) { throw $script:fc22Error }
    $script:value = ($script:value -band $and) -bor ($or -band (-bnot $and))
}
function Modbus-Transaccion([byte]$unit, [byte[]]$pdu) {
    if ($pdu[0] -ne 6) { throw 'Unexpected function' }
    $script:fc06Calls++
    $script:value = ([int]$pdu[3] -shl 8) -bor [int]$pdu[4]
    return $pdu
}
function Assert-Equal($actual, $expected, [string]$label) {
    if ($actual -ne $expected) { throw "$label expected $expected; got $actual" }
}

$route = Gr-EscribirBits 40001 1 $true $false
Assert-Equal $script:value 5 'Preserve unrelated group bit'
Assert-Equal $script:fc22Calls 1 'FC22 attempt'
Assert-Equal $script:fc16Calls 1 'FC16 attempt'
Assert-Equal $script:fc06Calls 1 'FC06 fallback'
if ($route -notlike 'FC06*') { throw 'Expected FC06 route' }

$route = Gr-EscribirBits 40070 2 $true $true
Assert-Equal $script:value 2 'Write-only command value'
Assert-Equal $script:fc22Calls 1 'Do not read or mask write-only register'
Assert-Equal $script:fc06Calls 2 'Write-only FC06 fallback'

$script:fc22Error = 'IllegalDataAddress (0x02)'
$before = $script:fc16Calls
try { [void](Gr-EscribirBits 40001 1 $true $false); throw 'Expected address error' }
catch { if ("$_" -notmatch 'IllegalDataAddress') { throw } }
Assert-Equal $script:fc16Calls $before 'No fallback on wrong address'

$script:fc22Error = ''
$script:fc16Error = 'Timeout'
$before = $script:fc06Calls
try { [void](Gr-EscribirBits 40070 1 $true $true); throw 'Expected timeout' }
catch { if ("$_" -notmatch 'Timeout') { throw } }
Assert-Equal $script:fc06Calls $before 'No retry after ambiguous timeout'

$script:fc22Error = ''
$script:value = 4
$before = $script:fc16Calls
Assert-Equal (Gr-EscribirBits 40001 1 $true $false) 'FC22' 'FC22 route'
Assert-Equal $script:value 5 'FC22 set one bit and preserve another'
Assert-Equal (Gr-EscribirBits 40001 1 $false $false) 'FC22' 'FC22 clear route'
Assert-Equal $script:value 4 'FC22 clear one bit and preserve another'
Assert-Equal $script:fc16Calls $before 'No fallback when FC22 succeeds'

# --- Travel limits (50047/50048) take the same fallback as group commands ---
# The v11.87 fix reached Gr-EscribirBits and left these two writes calling FC16
# directly, so an NCU that answers IllegalFunction to FC16 recovered for group
# commands and not for travel limits. A source grep cannot catch that: the words
# were all still there. This drives the real function.
$script:regs = @{}
function FC03-Leer([byte]$unit, [int]$address, [int]$count) {
    $out = @()
    for ($i = 0; $i -lt $count; $i++) {
        $a = $address + $i
        $out += $(if ($script:regs.ContainsKey($a)) { [int]$script:regs[$a] } else { 0x7FFF })
    }
    return ,$out
}
function FC16-Escribir([byte]$unit, [int]$address, [int[]]$words) {
    $script:fc16Calls++
    if ($script:fc16Error) { throw $script:fc16Error }
    for ($i = 0; $i -lt $words.Count; $i++) { $script:regs[$address + $i] = [int]$words[$i] }
}
function Modbus-Transaccion([byte]$unit, [byte[]]$pdu) {
    if ($pdu[0] -ne 6) { throw 'Unexpected function' }
    $script:fc06Calls++
    $script:regs[(([int]$pdu[1] -shl 8) -bor [int]$pdu[2])] = ([int]$pdu[3] -shl 8) -bor [int]$pdu[4]
    return $pdu
}

Assert-Equal (Lim-Dir 1 $LIM_ESTE) 50047 'TCU 1 east limit address'
Assert-Equal (Lim-Dir 3 $LIM_OESTE) 50148 'TCU 3 west limit address'

# FC16 available: the pair goes in one request
$script:fc16Error = ''; $script:fc16Calls = 0; $script:fc06Calls = 0; $script:regs = @{}
$r = Lim-EscribirTcu 2 (Ang-Palabra -20) (Ang-Palabra 20)
Assert-Equal $r.ok $true 'Pair accepted over FC16'
Assert-Equal $script:fc16Calls 1 'One FC16 request for the pair'
Assert-Equal $script:fc06Calls 0 'No FC06 needed'
Assert-Equal $script:regs[(Lim-Dir 2 $LIM_OESTE)] 2000 'West limit stored'

# FC16 rejected: the limits still land, one register at a time, over FC06
$script:fc16Error = 'IllegalFunction (0x01)'; $script:fc16Calls = 0; $script:fc06Calls = 0; $script:regs = @{}
$r = Lim-EscribirTcu 2 (Ang-Palabra -20) (Ang-Palabra 20)
Assert-Equal $r.ok $true 'Pair accepted over FC06 fallback'
Assert-Equal $script:fc06Calls 2 'One FC06 per register'
Assert-Equal $script:regs[(Lim-Dir 2 $LIM_ESTE)] 63536 'East limit stored as two-complement'
Assert-Equal $script:regs[(Lim-Dir 2 $LIM_OESTE)] 2000 'West limit stored over FC06'

# a single limit still leaves the other register untouched
$script:fc16Calls = 0; $script:fc06Calls = 0; $script:regs = @{}
$r = Lim-EscribirTcu 5 $null (Ang-Palabra 15)
Assert-Equal $r.ok $true 'Single limit accepted'
Assert-Equal $script:fc06Calls 1 'Only the register asked for'
if ($script:regs.ContainsKey((Lim-Dir 5 $LIM_ESTE))) { throw 'East limit must not be written' }

# an ambiguous timeout is never retried with another function code
$script:fc16Error = 'Timeout'; $script:fc06Calls = 0
try { [void](Lim-EscribirTcu 7 (Ang-Palabra -10) (Ang-Palabra 10)); throw 'Expected timeout' }
catch { if ("$_" -notmatch 'Timeout') { throw } }
Assert-Equal $script:fc06Calls 0 'No retry after ambiguous timeout on limits'

# the NCU clamping the value is reported, not taken as success
$script:fc16Error = ''; $script:regs = @{}
$script:regs[(Lim-Dir 9 $LIM_ESTE)] = (Ang-Palabra -5)
function FC16-Escribir([byte]$unit, [int]$address, [int[]]$words) { $script:fc16Calls++ }  # accepts and ignores
$r = Lim-EscribirTcu 9 (Ang-Palabra -40) $null
Assert-Equal $r.ok $false 'Clamped value is not a success'
if (-not (@($r.notas) -join ' ' -match 'RECORTADO') ) { throw 'Expected a clamping note' }

Write-Host 'Group and limit write fallback: OK'
