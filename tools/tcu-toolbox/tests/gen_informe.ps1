# Genera un informe HTML de muestra con datos inventados, para las pruebas de
# navegador (test_informe.js). No toca ninguna planta.
$src = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'TCU_Toolbox.ps1') -Raw
$ini = $src.IndexOf('$VERSION_TOOLBOX'); $fin = $src.IndexOf('$form = New-Object System.Windows.Forms.Form')
Invoke-Expression $src.Substring($ini, $fin - $ini)
# Sospechas-Lectura vive en la seccion de handlers y el informe la usa
$iS = $src.IndexOf('function Sospechas-Lectura'); $fS = $src.IndexOf('function Def-DeLectura')
Invoke-Expression $src.Substring($iS, $fS - $iS)
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
# lectura masiva: dos TCUs con el este_pitch en radianes, como en Ayora
$lect = @()
for ($i = 1; $i -le 12; $i++) {
    $lect += [pscustomobject]@{ NCU = '9'; TCU = $i
        '41111 max_tilt_west_r1 [deg]' = '55'
        '41125 min_tilt_east_r1 [deg]' = $(if ($i -eq 4) { '55' } else { '-45' })
        '41106 east_pitch [m]'         = $(if ($i -eq 4 -or $i -eq 9) { '-0,7854' } else { '6' })
        Estado = 'OK' }
}
$h = Informe-Html @{planta='Ayora'; ip='192.168.4.100'; fecha='2026-08-05 20:00'; usuario='test'; version='5.5'; mapa='6.1'
                    diag=$diag; pem=@(); aud=@(); inv=@(); lectura=$lect
                    horas=@{diag='20:00'; lectura='19:40'}; orden=@{diag=2; lectura=1}}
Set-Content (Join-Path $PSScriptRoot 'informe_muestra.html') $h -Encoding UTF8
Write-Host "informe_muestra.html generado ($($h.Length) bytes)"
