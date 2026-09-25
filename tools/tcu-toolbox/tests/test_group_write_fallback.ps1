# Focused unit test for group writes. No plant configuration or device data.
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Toolbox PowerShell syntax errors: $($errors.Count)" }
$names = @('Gr-Mascara', 'FC06-Escribir', 'Gr-EscribirPalabra', 'Gr-EscribirBits')
foreach ($name in $names) {
    $nodes = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($nodes.Count -ne 1) { throw "Expected exactly one function $name" }
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}

$UNIT_NCU = 1
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
Write-Host 'Group write fallback: OK'
