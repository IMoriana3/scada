$ErrorActionPreference='Stop'
$raiz=Split-Path $PSScriptRoot -Parent
$src=Get-Content (Join-Path $raiz 'TCU_Toolbox.ps1') -Raw
$ini=$src.IndexOf('$ROLES = @(');$fin=$src.IndexOf('$form = New-Object System.Windows.Forms.Form')
$dir=Join-Path ([IO.Path]::GetTempPath()) ('auth-tests-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($dir)
Invoke-Expression ($src.Substring($ini,$fin-$ini).Replace('$PSScriptRoot','$dir'))
function Check($ok,[string]$msg){if(-not $ok){throw $msg};Write-Host "OK $msg"}
function Rechaza([scriptblock]$code,[string]$msg){$visto=$false;try{& $code|Out-Null}catch{$visto=$true};Check $visto $msg}
$pass='Frase de prueba segura 2026';$nueva='Otra frase de prueba segura 2026'
try{
    $contract=Get-Content (Join-Path $raiz '../../contracts/access-v1.json') -Raw|ConvertFrom-Json
    foreach($v in $contract.password_cases){Check ((Pwd-Politica $v.value) -eq $v.allowed) "Politica comun $($v.id)"}
    $v=$contract.kdf_vector
    Check ((Pwd-Hash $v.password $v.salt_b64 $v.iterations 'PBKDF2-SHA256') -ceq $v.hash_b64) 'Vector KDF independiente de Python hashlib'
    Check (-not (Pwd-Politica 'corta')) 'Rechaza claves cortas'
    Check (-not (Pwd-Politica ('x'*129))) 'No trunca claves demasiado largas'
    Check (Pwd-Politica ('x'*15)) 'Acepta limite de 15 caracteres'
    Check (Pwd-Politica ('x'*128)) 'Acepta limite de 128 caracteres'
    Rechaza {Usuario-Nuevo 'ana' 'Ana' 'admin' 'corta'} 'La politica se aplica fuera de la ventana'
    $u=Usuario-Nuevo 'ana' 'Ana' 'admin' $pass
    Check ($u.algoritmo -ceq 'PBKDF2-SHA256' -and $u.iteraciones -eq 600000) 'KDF v2 explicita'
    Check (-not ($u|ConvertTo-Json).Contains($pass)) 'No se guarda contrasena en claro'
    Check ((Usuario-Validar @($u) 'ANA' $pass).usuario -eq 'ana') 'Usuario sin distincion de mayusculas'
    Check ($null -eq (Usuario-Validar @($u) 'ana' $pass.ToUpperInvariant())) 'Contrasena distingue mayusculas'
    $bytes=[Text.Encoding]::UTF8.GetBytes('AbCd');$otros=[Text.Encoding]::UTF8.GetBytes('abcd')
    Check (-not (Secreto-Igual $bytes $otros)) 'Comparacion de secretos exacta'
    Usuarios-Guardar @($u)
    Check ((Acceso-Iniciar 'ana' $pass).rol -eq 'admin') 'Inicio desde registros persistidos'
    for($j=0;$j -lt 5;$j++){Rechaza {Acceso-Iniciar 'ana' 'incorrecta'} 'Intento incorrecto rechazado'}
    Rechaza {Acceso-Iniciar 'ana' $pass} 'Bloqueo tambien impide acceso con clave correcta durante enfriamiento'
    # Reload the real code: a restart does not reset the persisted limiter.
    Invoke-Expression ($src.Substring($ini,$fin-$ini).Replace('$PSScriptRoot','$dir'))
    Rechaza {Acceso-Iniciar 'ana' $pass} 'El reinicio no borra el bloqueo'
    Acceso-GuardarJson ($FICH_USUARIOS+'.acceso.json') @{fallos=5;bloqueado_hasta=[datetime]::UtcNow.AddSeconds(-1).Ticks}
    Check ((Acceso-Iniciar 'ana' $pass).rol -eq 'admin') 'Reabre al vencer enfriamiento'
    Rechaza {Usuario-CambiarClave 'ana' 'incorrecta' $nueva} 'Cambio requiere contrasena actual'
    $null=Usuario-CambiarClave 'ana' $pass $nueva
    Rechaza {Acceso-Iniciar 'ana' $pass} 'La contrasena anterior ya no sirve'
    Check ((Acceso-Iniciar 'ana' $nueva).rol -eq 'admin') 'Cambio conserva identidad y rol'
    $legacy=@{usuario='legado';nombre='Legado';rol='admin';sal='AAECAwQFBgcICQoLDA0ODw==';iteraciones=100000;hash=(Pwd-Hash $pass 'AAECAwQFBgcICQoLDA0ODw==' 100000)}
    Usuarios-Guardar @($legacy)
    $login=Acceso-Iniciar 'legado' $pass
    Check ($login.algoritmo -ceq 'PBKDF2-SHA256') 'Migra SHA1 solo despues de validar'
    Check ((Usuarios-Cargar)[0].algoritmo -ceq 'PBKDF2-SHA256') 'La migracion queda persistida'
    Remove-Item -LiteralPath $FICH_USUARIOS
    Rechaza {Usuarios-Cargar} 'Borrar usuarios no inicia otro administrador'
    Usuarios-Guardar @($u)
    Set-Content -LiteralPath ($FICH_USUARIOS+'.acceso.json') -Value 'corrupto'
    Rechaza {Acceso-Iniciar 'ana' $pass} 'Limitador corrupto falla cerrado'
    $ag=Get-Content (Join-Path $raiz '../tcu-agente/TCU_Agente.ps1') -Raw
    $ast=[Management.Automation.Language.Parser]::ParseInput($ag,[ref]$null,[ref]$null)
    $fun=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Agente-TokenValido'},$true)
    . ([scriptblock]::Create($fun.Extent.Text))
    Check (Agente-TokenValido 'AbCd-token-prueba' 'AbCd-token-prueba') 'Token valido'
    Check (-not (Agente-TokenValido 'abcd-token-prueba' 'AbCd-token-prueba')) 'Token rechaza variante de mayusculas'
    Check (-not (Agente-TokenValido '' 'AbCd-token-prueba')) 'Token vacio rechazado'
    Write-Host 'SEGURIDAD LOCAL: OK'
}finally{Remove-Item -LiteralPath $dir -Recurse -Force}
