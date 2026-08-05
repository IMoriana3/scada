# Genera un informe HTML de muestra con datos inventados, para las pruebas de
# navegador (test_informe.js). No toca ninguna planta.
$src = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1') -Raw
$ini = $src.IndexOf('$VERSION_TOOLBOX'); $fin = $src.IndexOf('$form = New-Object System.Windows.Forms.Form')
Invoke-Expression $src.Substring($ini, $fin - $ini)
$diag = @()
$saludes = @('OK','AVISO','ALARMA','OFFLINE')
$modos = @('AUTO','MANUAL','OFF')
for ($i = 1; $i -le 40; $i++) {
    $diag += [pscustomobject]@{ NCU = "$((($i - 1) % 3) + 1)"; TCU = $i
        Salud = $saludes[$i % 4]; Modo = $modos[$i % 3]
        Tilt = "$([math]::Round(-12.5 + $i * 0.3, 1))"; Objetivo = '-12.5'
        Dif = "$([math]::Round($i * 0.1, 1))"; SoC = "$(60 + ($i % 40)) %"
        Alarmas = $(if ($i % 4 -eq 2) { 'eje bloqueado' } elseif ($i % 4 -eq 3) { 'sobrecorriente' } else { '' }) }
}
$h = Informe-Html @{planta='Ayora'; ip='192.168.4.100'; fecha='2026-08-05 20:00'; usuario='test'; version='5.5'; mapa='6.1'
                    diag=$diag; pem=@(); aud=@(); inv=@(); lectura=@(); horas=@{diag='20:00'}}
Set-Content (Join-Path $PSScriptRoot 'informe_muestra.html') $h -Encoding UTF8
Write-Host "informe_muestra.html generado ($($h.Length) bytes)"
