# =============================================================================
#  TCU Toolbox v2 - Configuracion y diagnostico de TCUs Sunner (offline)
#
#  Pestanas:
#    Escribir      - tabla de variables + presets JSON + backup como preset + NVM
#    Leer variable - una variable en un rango de TCUs, resumen de discrepancias
#    Volcar TCU    - todas las variables de una TCU; backup JSON; comparar
#    Diagnostico   - salud de un rango de TCUs (OK/AVISO/ALARMA/OFFLINE) con
#                    alarmas decodificadas bit a bit; export CSV/JSON
#    Utilidades    - sincronizar fecha/hora con el PC; identificacion (FW,
#                    numero de serie, MAC Xbee, fecha de fabricacion)
#
#  Mapa de registros: SUNNER TCU Modbus Map v6.1 (FW v1.4.3).
#  Cliente Modbus TCP integrado (FC03 lectura, FC16 escritura, FC22 mascara).
#  La NCU actua de gateway: unit id = numero de TCU.
#
#  Plantas: se cargan de plantas.json (junto al script) si existe; se puede
#  generar desde el config del SCADA con make_plantas.py. Sin red ni nube:
#  todo funciona offline contra la LAN de planta.
#
#  Lanzar con TCU_Toolbox.bat (PowerShell 5.1+, sin instalar nada).
# =============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic   # InputBox: la nota de un trabajo guardado
[System.Windows.Forms.Application]::EnableVisualStyles()

$VERSION_TOOLBOX = '11.17'
$VERSION_MAPA    = 'SUNNER TCU v6.1 (FW 1.4.3) + NCU R7.1 + HSU R23'

# La propia NCU expone sus registros en el puerto 502, unit id 1 (mapa R7.1)
$PUERTO_NCU = 502
$UNIT_NCU   = 1
$RELOJ_TOL_S = 120

# ---------------------------------------------------------------------------
#  Plantas: SOLO las de los ficheros cargados (plantas/ + plantas.json/csv +
#  boton Cargar..., que REEMPLAZA la lista). Sin lista integrada: el programa
#  es el mismo para todas las plantas y la configuracion viaja en ficheros.
# ---------------------------------------------------------------------------
$PLANTAS = [ordered]@{
  '(manual)' = $null
}

$script:MsgsInicio = @()

# Fusiona un fichero de plantas en $PLANTAS. Devuelve cuantas entradas cargo;
# lanza si el fichero es ilegible. Dos formatos:
#  - JSON: {version, plantas:[{nombre,ip,puerto,tcu_ini,tcu_fin}]}
#  - CSV con punto y coma (editable desde Excel, sin Office en el PC de campo):
#      Planta;NCU;IP;Puerto;TCU_ini;TCU_fin
function Cargar-FicheroPlantas([string]$ruta) {
    $n = 0
    if ($ruta -match '\.csv$') {
        $filas = @(Import-Csv -Path $ruta -Delimiter ';')
        if ($filas.Count -eq 0) { throw "CSV vacio o sin cabecera Planta;NCU;IP;Puerto;TCU_ini;TCU_fin" }
        foreach ($r in $filas) {
            if (-not $r.Planta -or -not $r.IP -or -not $r.Puerto) { continue }
            $nombre = ("$($r.Planta) $($r.NCU) GW$($r.Puerto)").Trim()
            # varias filas del mismo gateway (p.ej. TCU suelta 109): nombre unico
            if ($PLANTAS.Contains($nombre)) { $nombre = "$nombre ($($r.TCU_ini)-$($r.TCU_fin))" }
            $PLANTAS[$nombre] = @{
                ip     = [string]$r.IP
                puerto = [int]$r.Puerto
                ini    = [int]$r.TCU_ini
                fin    = [int]$r.TCU_fin
            }
            $n++
        }
        return $n
    }
    $jp = Get-Content $ruta -Raw | ConvertFrom-Json
    if (-not $jp.plantas) { throw "sin lista 'plantas'" }
    foreach ($p in $jp.plantas) {
        if (-not $p.nombre -or -not $p.ip) { continue }
        $e = @{
            ip     = [string]$p.ip
            puerto = [int]$p.puerto
            ini    = [int]$p.tcu_ini
            fin    = [int]$p.tcu_fin
        }
        if ($p.PSObject.Properties['hsu_esclavo'] -and "$($p.hsu_esclavo)" -match '^\d+$') { $e.hsu = [int]$p.hsu_esclavo }
        # cuantas estaciones lleva esa NCU segun la topologia (columna RSU del
        # Excel). Sirve para saber si BUSCAR HSUs las ha encontrado todas.
        if ($p.PSObject.Properties['hsus'] -and "$($p.hsus)" -match '^\d+$') { $e.hsus = [int]$p.hsus }
        # una NCU puede llevar mas de una estacion, cada una con su esclavo, en
        # el orden de los huecos HSU1, HSU2... de la cache (Ayora NCU15: 230 y 231)
        if ($p.PSObject.Properties['hsu_esclavos']) {
            $lstE = @(@($p.hsu_esclavos) | Where-Object { "$_" -match '^\d+$' } | ForEach-Object { [int]$_ })
            if ($lstE.Count -gt 0) { $e.hsuLista = $lstE; if (-not $e.hsu) { $e.hsu = $lstE[0] } }
        }
        $PLANTAS[[string]$p.nombre] = $e
        $n++
    }
    return $n
}

# Entradas "(auto)": si varias entradas comparten IP (una por gateway de la
# misma NCU), se anade una entrada agregada que cubre el rango completo y
# resuelve sola el puerto de cada TCU (adios al error de puerto).
# Entradas "(Planta completa)": si los nombres siguen el patron
# "<Planta> NCU<n> ...", se anade ademas una entrada por planta con la lista
# de sus NCUs, para operaciones de planta entera (Diagnostico).
function Construir-EntradasAuto {
    $porIp = @{}
    foreach ($k in @($PLANTAS.Keys)) {
        $p = $PLANTAS[$k]
        if (-not $p -or $p.gws -or $p.ncus) { continue }
        if (-not $porIp.ContainsKey($p.ip)) { $porIp[$p.ip] = @() }
        $porIp[$p.ip] += ,@{nombre=$k; p=$p}
    }
    foreach ($ip in $porIp.Keys) {
        $grupo = $porIp[$ip]
        if ($grupo.Count -lt 2) { continue }
        $prefijo = $grupo[0].nombre
        foreach ($g in $grupo) {
            while ($prefijo -and -not $g.nombre.StartsWith($prefijo)) { $prefijo = $prefijo.Substring(0, $prefijo.Length - 1) }
        }
        $prefijo = ($prefijo -replace '(GW|TCU)\S*$', '').Trim()
        if (-not $prefijo) { $prefijo = "NCU $ip" }
        $gws = @($grupo | ForEach-Object { @{puerto=$_.p.puerto; ini=$_.p.ini; fin=$_.p.fin} } | Sort-Object { $_.ini })
        $ini = @($gws | ForEach-Object { $_.ini } | Measure-Object -Minimum).Minimum
        $fin = @($gws | ForEach-Object { $_.fin } | Measure-Object -Maximum).Maximum
        $auto = @{ip=$ip; puerto=$null; ini=[int]$ini; fin=[int]$fin; gws=$gws}
        foreach ($g in $grupo) { if ($g.p.hsu) { $auto.hsu = $g.p.hsu; break } }
        $PLANTAS["$prefijo (auto)"] = $auto
    }
    # agrupar por planta a partir del patron de nombre "<Planta> NCU<n>"
    $porPlanta = [ordered]@{}
    foreach ($k in @($PLANTAS.Keys)) {
        $p = $PLANTAS[$k]
        if (-not $p -or $p.gws -or $p.ncus) { continue }
        $m = [regex]::Match($k, '^(.*?)\s+NCU(\d+)')
        if (-not $m.Success) { continue }
        $planta = $m.Groups[1].Value.Trim(); $ncu = [int]$m.Groups[2].Value
        # ojo: hashtable normal, no [ordered] (con clave int lo trataria como indice)
        if (-not $porPlanta.Contains($planta)) { $porPlanta[$planta] = @{} }
        if (-not $porPlanta[$planta].Contains($ncu)) { $porPlanta[$planta][$ncu] = @{ip=$p.ip; gws=@(); hsu=$null; hsus=0; hsuLista=@()} }
        if ($porPlanta[$planta][$ncu].ip -ne $p.ip) { continue }   # inconsistencia: ignorar
        $porPlanta[$planta][$ncu].gws += ,@{puerto=$p.puerto; ini=$p.ini; fin=$p.fin}
        if ($p.hsu -and -not $porPlanta[$planta][$ncu].hsu) { $porPlanta[$planta][$ncu].hsu = $p.hsu }
        # el mismo numero viene repetido en las entradas de los dos gateways de
        # la NCU: se queda el mayor, no se suman
        if ($p.hsus -and [int]$p.hsus -gt [int]$porPlanta[$planta][$ncu].hsus) { $porPlanta[$planta][$ncu].hsus = [int]$p.hsus }
        if (@($p.hsuLista).Count -gt @($porPlanta[$planta][$ncu].hsuLista).Count) { $porPlanta[$planta][$ncu].hsuLista = @($p.hsuLista) }
    }
    foreach ($planta in $porPlanta.Keys) {
        $ncus = $porPlanta[$planta]
        if ($ncus.Count -lt 2) { continue }
        $lista = @()
        foreach ($n in ($ncus.Keys | Sort-Object)) {
            $lista += ,@{ncu=[int]$n; ip=$ncus[$n].ip; gws=@($ncus[$n].gws | Sort-Object { $_.ini }); hsu=$ncus[$n].hsu; hsus=[int]$ncus[$n].hsus; hsuLista=@($ncus[$n].hsuLista)}
        }
        $PLANTAS["$planta (Planta completa)"] = @{ip=$null; puerto=$null; ini=$null; fin=$null; ncus=$lista}
    }
}

# '1,3-5' -> @(1,3,4,5); vacio -> $null (= todas)
function Parse-ListaNums([string]$texto) {
    $t = "$texto".Trim()
    if (-not $t) { return $null }
    $nums = @()
    foreach ($parte in $t.Split(',')) {
        $p = $parte.Trim()
        if ($p -match '^(\d+)\s*-\s*(\d+)$') { $nums += @([int]$Matches[1]..[int]$Matches[2]) }
        elseif ($p -match '^\d+$') { $nums += [int]$p }
        else { throw "lista de NCUs invalida: '$p' (usa p.ej. 1,3-5)" }
    }
    return @($nums | Sort-Object -Unique)
}

# El programa es el mismo para todas las plantas; la configuracion viaja en
# JSON: la carpeta plantas/ lleva un fichero por planta (generados por la
# plataforma) y plantas.json unico se mantiene por compatibilidad.
$rutaPlantas = Join-Path $PSScriptRoot 'plantas.json'
if (Test-Path $rutaPlantas) {
    try { $script:MsgsInicio += "plantas.json: $(Cargar-FicheroPlantas $rutaPlantas) plantas" }
    catch { $script:MsgsInicio += "AVISO: plantas.json ilegible ($_) - ignorado" }
}
$rutaCsv = Join-Path $PSScriptRoot 'plantas.csv'
if (Test-Path $rutaCsv) {
    try { $script:MsgsInicio += "plantas.csv: $(Cargar-FicheroPlantas $rutaCsv) gateways" }
    catch { $script:MsgsInicio += "AVISO: plantas.csv ilegible ($_) - ignorado" }
}
$dirPlantas = Join-Path $PSScriptRoot 'plantas'
if (Test-Path $dirPlantas) {
    foreach ($f in @(Get-ChildItem $dirPlantas | Where-Object { $_.Extension -in '.json', '.csv' } | Sort-Object Name)) {
        try { $script:MsgsInicio += "plantas/$($f.Name): $(Cargar-FicheroPlantas $f.FullName) entradas" }
        catch { $script:MsgsInicio += "AVISO: plantas/$($f.Name) ilegible ($_) - ignorado" }
    }
}
Construir-EntradasAuto

# ---------------------------------------------------------------------------
#  Mapa de registros de ESTADO (solo lectura, 30xxx)
#  div = divisor para mostrar el valor en su unidad natural
# ---------------------------------------------------------------------------
$ESTADO = [ordered]@{
  '30000 product_id [hex]'         = @{addr=30000; tipo='u16hex'}
  '30001 main_status [hex]'        = @{addr=30001; tipo='u16hex'}
  '30001 modo (OFF/MANUAL/AUTO)'   = @{addr=30001; tipo='modo'}
  '30002 alarmas_1 [hex]'          = @{addr=30002; tipo='u16hex'}
  '30003 alarmas_2 [hex]'          = @{addr=30003; tipo='u16hex'}
  '30004 alarmas_3_HW [hex]'       = @{addr=30004; tipo='u16hex'}
  '30005 alarmas_4 [hex]'          = @{addr=30005; tipo='u16hex'}
  '30006 system_status [hex]'      = @{addr=30006; tipo='u16hex'}
  '30010 velocidad_rot [mdeg/s]'   = @{addr=30010; tipo='s16'}
  '30011 corriente_motor [mA]'     = @{addr=30011; tipo='u16'}
  '30030 zigbee_short_addr [hex]'  = @{addr=30030; tipo='u16hex'}
  '30031 zigbee_canal (b.bajo)'    = @{addr=30031; tipo='u8lo'}
  '30031 zigbee_assoc_AI (b.alto)' = @{addr=30031; tipo='u8hi'}
  '30076 fecha_primer_arranque'    = @{addr=30076; tipo='dt_bcd'}
  '30079 fecha_hora_actual'        = @{addr=30079; tipo='dt_bcd'}
  '30082 motor_estado [hex]'       = @{addr=30082; tipo='u16hex'}
  '30083 tension_motor [mV]'       = @{addr=30083; tipo='u16'}
  '30086 energia_motor_hoy [J]'    = @{addr=30086; tipo='u32'}
  '30088 energia_motor_total [J]'  = @{addr=30088; tipo='u32'}
  '30091 tension_bus [mV]'         = @{addr=30091; tipo='u16'}
  '30092 tension_panel [mV]'       = @{addr=30092; tipo='u16'}
  '30093 corriente_panel [mA]'     = @{addr=30093; tipo='u16'}
  '30094 tension_bateria [mV]'     = @{addr=30094; tipo='u16'}
  '30095 corriente_bateria [mA]'   = @{addr=30095; tipo='s16'}
  '30096 SoC [%] (b.bajo)'         = @{addr=30096; tipo='u8lo'}
  '30096 SoH [%] (b.alto)'         = @{addr=30096; tipo='u8hi'}
  '30097 temp_bateria [C]'         = @{addr=30097; tipo='s16'; div=10}
  '30098 temp_PCB [C]'             = @{addr=30098; tipo='s16'; div=10}
  '30099 capacidad_actual [mAh]'   = @{addr=30099; tipo='u16'}
  '30100 capacidad_nominal [mAh]'  = @{addr=30100; tipo='u16'}
  '30101 ciclos_carga'             = @{addr=30101; tipo='u16'}
  '30102 dias_preservacion'        = @{addr=30102; tipo='u16'}
  '30110 dif_objetivo_real [deg]'  = @{addr=30110; tipo='s16'; div=10}
  '30111 tilt_angle [deg]'         = @{addr=30111; tipo='s16'; div=10}
  '30112 target_angle [deg]'       = @{addr=30112; tipo='s16'; div=10}
  '30113 criterio_angulo [hex]'    = @{addr=30113; tipo='u16hex'}
  '30114 fuente_safe_pos'          = @{addr=30114; tipo='u16'}
  '30115 zenit_solar [deg]'        = @{addr=30115; tipo='s16'; div=100}
  '30116 azimut_solar [deg]'       = @{addr=30116; tipo='u16'; div=100}
  '30117 tilt_true_tracking [deg]' = @{addr=30117; tipo='s16'; div=100}
  '30118 tilt_backtracking [deg]'  = @{addr=30118; tipo='s16'; div=100}
  '30153 charger_state'            = @{addr=30153; tipo='charger'}
  '30155 system_status_2 [hex]'    = @{addr=30155; tipo='u16hex'}
}

# ---------------------------------------------------------------------------
#  Mapa de registros ESCRIBIBLES (holding, 4xxxx)
# ---------------------------------------------------------------------------
$VARIABLES = [ordered]@{
  # ---- COMANDOS (registros de orden; escribir con cuidado) ----
  '40000 CMD main_change_request [hex]'   = @{addr=40000; tipo='u16hex'}
  '40007 CMD extended_control [hex]'      = @{addr=40007; tipo='u16hex'}
  '40017 CMD manual_motor [hex] PELIGRO'  = @{addr=40017; tipo='u16hex'}
  '40018 CMD config_control [hex] PELIGRO'= @{addr=40018; tipo='u16hex'}
  '42000 CMD remote_change_request [hex]' = @{addr=42000; tipo='u16hex'}
  # ---- FECHA / HORA DE ENTRADA ----
  '40001 input_time_segundos'             = @{addr=40001; tipo='u16'}
  '40002 input_time_minutos'              = @{addr=40002; tipo='u16'}
  '40003 input_time_horas'                = @{addr=40003; tipo='u16'}
  '40004 input_date_dia'                  = @{addr=40004; tipo='u16'}
  '40005 input_date_mes'                  = @{addr=40005; tipo='u16'}
  '40006 input_date_ano'                  = @{addr=40006; tipo='u16'}
  # ---- CARGA / BATERIA ----
  '40008 jeita_T1 [K]'                    = @{addr=40008; tipo='u16'; min=233; max=398}
  '40009 jeita_T2 [K]'                    = @{addr=40009; tipo='u16'; min=233; max=398}
  '40010 jeita_T3 [K]'                    = @{addr=40010; tipo='u16'; min=233; max=398}
  '40011 jeita_T4 [K]'                    = @{addr=40011; tipo='u16'; min=233; max=398}
  '40012 carga_bajo_T1 [mA]'              = @{addr=40012; tipo='u16'; max=20000}
  '40013 carga_T1_T2 [mA]'                = @{addr=40013; tipo='u16'; max=20000}
  '40014 carga_T2_T3 [mA]'                = @{addr=40014; tipo='u16'; max=20000}
  '40015 carga_T3_T4 [mA]'                = @{addr=40015; tipo='u16'; max=20000}
  '40016 carga_sobre_T4 [mA]'             = @{addr=40016; tipo='u16'}
  '40037 charge_parameters [hex]'         = @{addr=40037; tipo='u16hex'}
  '40037 jeita_enable (bit 0)'            = @{addr=40037; tipo='bit'; bit=0}
  '40038 corriente_carga_nominal [mA]'    = @{addr=40038; tipo='u16'}
  '40039 tension_carga_nominal [mV]'      = @{addr=40039; tipo='u16'}
  '40040 corriente_fin_carga [mA]'        = @{addr=40040; tipo='u16'}
  '40041 limite_tiempo_carga [s]'         = @{addr=40041; tipo='u16'}
  '40042 limite_tiempo_CV [s]'            = @{addr=40042; tipo='u16'}
  '40043 tension_panel_MPP [mV]'          = @{addr=40043; tipo='u16'; max=50000}
  # ---- CALEFACTOR ----
  '40034 heater_umbral_cargando [K]'      = @{addr=40034; tipo='u16'; max=300}
  '40035 heater_umbral_descargando [K]'   = @{addr=40035; tipo='u16'; max=300}
  '40036 heater_options [hex]'            = @{addr=40036; tipo='u16hex'}
  '40036 heater_histeresis [K] (byte bajo)'= @{addr=40036; tipo='u8lo'; max=20}
  '40036 heater_enable (bit 8)'           = @{addr=40036; tipo='bit'; bit=8}
  # ---- COMUNICACIONES ----
  '40022 timeout_com_NCU [min]'           = @{addr=40022; tipo='u16'; max=1092}
  '40029 watchdog_zigbee [min]'           = @{addr=40029; tipo='u16'}
  '41004 zigbee_config [hex]'             = @{addr=41004; tipo='u16hex'}
  '41004 zigbee_slave_id (byte bajo)'     = @{addr=41004; tipo='u8lo'}
  '41004 zigbee_apply (bit 8)'            = @{addr=41004; tipo='bit'; bit=8}
  '41006 rs485_config [hex]'              = @{addr=41006; tipo='u16hex'}
  '41006 rs485_slave_id (byte bajo)'      = @{addr=41006; tipo='u8lo'}
  '41006 rs485_apply (bit 8)'             = @{addr=41006; tipo='bit'; bit=8}
  '41070 zigbee_pan_id_bajo [u32]'        = @{addr=41070; tipo='u32'}
  '41072 zigbee_pan_id_alto [u32]'        = @{addr=41072; tipo='u32'}
  '41074 zigbee_encryption [hex]'         = @{addr=41074; tipo='u16hex'}
  '41074 zigbee_encr_enable (bit 0)'      = @{addr=41074; tipo='bit'; bit=0}
  '41075 zigbee_user_key [u32]'           = @{addr=41075; tipo='u32'}
  # ---- POSICION / GEOMETRIA ----
  '41010 longitud [deg]'                  = @{addr=41010; tipo='f32deg'}
  '41012 latitud [deg]'                   = @{addr=41012; tipo='f32deg'}
  '41014 azimuth_offset [deg]'            = @{addr=41014; tipo='f32deg'}
  '41033 west_pitch [m]'                  = @{addr=41033; tipo='f32'}
  '41035 panel_width [m]'                 = @{addr=41035; tipo='f32'}
  '41058 inclinometer_offset [deg]'       = @{addr=41058; tipo='f32deg'}
  '41098 west_grade_slope [deg]'          = @{addr=41098; tipo='f32deg'}
  '41100 west_grade_azimuth [deg]'        = @{addr=41100; tipo='f32deg'}
  '41102 east_grade_slope [deg]'          = @{addr=41102; tipo='f32deg'}
  '41104 east_grade_azimuth [deg]'        = @{addr=41104; tipo='f32deg'}
  # OJO: el manual v6.1 pone 'Radians 0..pi/4' en 41106, pero es una errata
  # heredada de la fila de arriba: es la separacion entre ejes, como 41033
  # (Meters). Confirmado en campo: Ayora lee 6, que como radianes (344 deg)
  # seria imposible en un campo cuyo maximo declarado es pi/4 (45 deg).
  '41106 east_pitch [m]'                  = @{addr=41106; tipo='f32'}
  '41018 tracker_options [hex]'           = @{addr=41018; tipo='u16hex'}
  '41018 inclinometro_invertido (bit 9)'  = @{addr=41018; tipo='bit'; bit=9}
  '41018 motor_invertido (bit 11)'        = @{addr=41018; tipo='bit'; bit=11}
  # ---- UMBRALES DE ALARMA ----
  '41027 umbral_Vmotor_baja [mV]'         = @{addr=41027; tipo='u16'}
  '41028 umbral_Vmotor_alta [mV]'         = @{addr=41028; tipo='u16'}
  '41029 umbral_Vbus_baja [mV]'           = @{addr=41029; tipo='u16'}
  '41030 umbral_Vbus_alta [mV]'           = @{addr=41030; tipo='u16'}
  '41031 umbral_Tpcb_baja [K]'            = @{addr=41031; tipo='u16'}
  '41032 umbral_Tpcb_alta [K]'            = @{addr=41032; tipo='u16'}
  # ---- LIMITES Y DEADBANDS ----
  '41037 max_west_tilt [pulsos]'          = @{addr=41037; tipo='s16'}
  '41038 max_east_tilt [pulsos]'          = @{addr=41038; tipo='s16'}
  '41060 deadband_noBT_noLC [pulsos]'     = @{addr=41060; tipo='u16'}
  '41061 deadband_BT_noLC [pulsos]'       = @{addr=41061; tipo='u16'}
  '41062 deadband_noBT_LC [pulsos]'       = @{addr=41062; tipo='u16'}
  '41063 deadband_BT_LC [pulsos]'         = @{addr=41063; tipo='u16'}
  # ---- ANGULOS: NOCHE Y SAFE POSITIONS ----
  '41042 nighttime_tilt [deg]'            = @{addr=41042; tipo='f32deg'}
  '41044 safe_pos_1 [deg]'                = @{addr=41044; tipo='f32deg'}
  '41046 safe_pos_2 [deg]'                = @{addr=41046; tipo='f32deg'}
  '41048 safe_pos_3 [deg]'                = @{addr=41048; tipo='f32deg'}
  '41050 safe_pos_4 [deg]'                = @{addr=41050; tipo='f32deg'}
  '41052 safe_pos_5 [deg]'                = @{addr=41052; tipo='f32deg'}
  '41054 safe_pos_6 [deg]'                = @{addr=41054; tipo='f32deg'}
  '41056 safe_pos_7 [deg]'                = @{addr=41056; tipo='f32deg'}
  '41068 safe_pos_options [hex]'          = @{addr=41068; tipo='u16hex'}
  '41069 safe_pos_sign_threshold'         = @{addr=41069; tipo='s16'}
  # ---- RANGOS DE TILT (limite oeste = maximo) ----
  '41111 max_tilt_west_r1 [deg]'          = @{addr=41111; tipo='f32deg'}
  '41113 max_tilt_west_r2 [deg]'          = @{addr=41113; tipo='f32deg'}
  '41115 max_tilt_west_r3 [deg]'          = @{addr=41115; tipo='f32deg'}
  '41117 max_tilt_west_r4 [deg]'          = @{addr=41117; tipo='f32deg'}
  '41119 max_tilt_west_r5 [deg]'          = @{addr=41119; tipo='f32deg'}
  '41121 max_tilt_west_r6 [deg]'          = @{addr=41121; tipo='f32deg'}
  '41123 max_tilt_west_r7 [deg]'          = @{addr=41123; tipo='f32deg'}
  # ---- RANGOS DE TILT (limite este = minimo) ----
  '41125 min_tilt_east_r1 [deg]'          = @{addr=41125; tipo='f32deg'}
  '41127 min_tilt_east_r2 [deg]'          = @{addr=41127; tipo='f32deg'}
  '41129 min_tilt_east_r3 [deg]'          = @{addr=41129; tipo='f32deg'}
  '41131 min_tilt_east_r4 [deg]'          = @{addr=41131; tipo='f32deg'}
  '41133 min_tilt_east_r5 [deg]'          = @{addr=41133; tipo='f32deg'}
  '41135 min_tilt_east_r6 [deg]'          = @{addr=41135; tipo='f32deg'}
  '41137 min_tilt_east_r7 [deg]'          = @{addr=41137; tipo='f32deg'}
  # ---- MOTOR ----
  '41039 motor_velocity_eval [ms]'        = @{addr=41039; tipo='u16'}
  '41040 motor_overcurrent_limit [mA]'    = @{addr=41040; tipo='u16'; max=30000}
  '41041 mask_time_overcurrent [ms]'      = @{addr=41041; tipo='u16'}
  '41064 axis_block_det_time [s] (b.bajo)'= @{addr=41064; tipo='u8lo'}
  '41064 axis_block_retry [x0.1s] (b.alto)'= @{addr=41064; tipo='u8hi'}
  '41065 motor_fault_retries'             = @{addr=41065; tipo='u16'; min=1; max=10}
  '41066 lowspeed_det_time [s] (b.bajo)'  = @{addr=41066; tipo='u8lo'}
  '41066 lowspeed_umbral [%] (b.alto)'    = @{addr=41066; tipo='u8hi'}
  '41067 motor_speed_no_load [mdeg/s]'    = @{addr=41067; tipo='u16'; min=170; max=200}
  '41079 min_motor_off_time [ms]'         = @{addr=41079; tipo='u16'}
  '41080 pulse_resolution [pulsos]'       = @{addr=41080; tipo='u16'; min=1; max=64}
  '41093 duty_approach (b.bajo)'          = @{addr=41093; tipo='u8lo'; max=250}
  '41093 duty_max_manual (b.alto)'        = @{addr=41093; tipo='u8hi'; max=250}
  '41094 duty_max_auto (b.bajo)'          = @{addr=41094; tipo='u8lo'; max=250}
  '41094 duty_startup (b.alto)'           = @{addr=41094; tipo='u8hi'; max=250}
  '41095 ramp_acel (b.bajo)'              = @{addr=41095; tipo='u8lo'; min=4; max=82}
  '41095 ramp_decel (b.alto)'             = @{addr=41095; tipo='u8hi'; min=4; max=82}
  # ---- NIVELES DE SoC ----
  '41081 soc_critico_enter [%] (b.bajo)'  = @{addr=41081; tipo='u8lo'}
  '41081 soc_critico_exit [%] (b.alto)'   = @{addr=41081; tipo='u8hi'}
  '41082 soc_muy_bajo_enter [%] (b.bajo)' = @{addr=41082; tipo='u8lo'}
  '41082 soc_muy_bajo_exit [%] (b.alto)'  = @{addr=41082; tipo='u8hi'}
  '41083 soc_bajo_enter [%] (b.bajo)'     = @{addr=41083; tipo='u8lo'}
  '41083 soc_bajo_exit [%] (b.alto)'      = @{addr=41083; tipo='u8hi'}
  '41084 preservacion_high [%] (b.bajo)'  = @{addr=41084; tipo='u8lo'; min=75; max=100}
  '41084 preservacion_low [%] (b.alto)'   = @{addr=41084; tipo='u8hi'; min=50; max=75}
  '42001 dias_sin_carga_completa'         = @{addr=42001; tipo='u16'; min=1; max=30}
  '42005 soc_min_auto [%] (b.bajo)'       = @{addr=42005; tipo='u8lo'; max=25}
  '42005 soc_min_bootloader [%] (b.alto)' = @{addr=42005; tipo='u8hi'; max=50}
  '42006 vbat_min_bootloader [mV]'        = @{addr=42006; tipo='u16'; max=28000}
}

# Registros de comando: exigen doble confirmacion y no entran en backups
$ADDR_COMANDO = @(40000, 40007, 40017, 40018, 42000)
$ADDR_TIEMPO  = @(40001, 40002, 40003, 40004, 40005, 40006)

# Registros de IDENTIDAD DE RED: el numero de esclavo, el PAN ID y la clave de
# cifrado son propios de CADA TCU. Clonarlos de un equipo a otro deja dos TCUs
# con el mismo esclavo (una de las dos desaparece de la red) o mete a la TCU en
# la PAN de otra NCU. Por eso no entran en los presets ni se dejan escribir a
# mas de una TCU a la vez.
$ADDR_IDENTIDAD = @(41004, 41006, 41070, 41072, 41074, 41075)

# ---------------------------------------------------------------------------
#  Rangos plausibles por variable (comprobacion de cordura)
# ---------------------------------------------------------------------------
# No son limites de escritura (esos van en el mapa, con min/max), sino el
# intervalo en el que un valor tiene sentido fisico. Sirven para cazar valores
# que ya estan escritos y son imposibles, como el east_pitch = -0,7854 m que
# aparecio en Ayora: -0,7854 es exactamente -45 grados en radianes, o sea el
# crudo de min_tilt metido en el registro de al lado.
$RANGOS = @{
  '41033 west_pitch [m]'            = @{min=0.5;    max=30}
  '41035 panel_width [m]'           = @{min=0.5;    max=30}
  '41106 east_pitch [m]'            = @{min=0.5;    max=30}
  '41010 longitud [deg]'            = @{min=-180;   max=180}
  '41012 latitud [deg]'             = @{min=-90;    max=90}
  '41014 azimuth_offset [deg]'      = @{min=-180;   max=180}
  '41058 inclinometer_offset [deg]' = @{min=-30;    max=30}
  '41098 west_grade_slope [deg]'    = @{min=-45;    max=45}
  '41102 east_grade_slope [deg]'    = @{min=-45;    max=45}
  '41100 west_grade_azimuth [deg]'  = @{min=-180;   max=180}
  '41104 east_grade_azimuth [deg]'  = @{min=-180;   max=180}
  '41042 nighttime_tilt [deg]'      = @{min=-90;    max=90}
}
# Los siete rangos de max_tilt/min_tilt comparten limites, y son -90..90 en los
# DOS: el limite "este" no tiene por que ser negativo. En Ayora la configuracion
# buena lleva min_tilt_east = +30, o sea que el seguidor trabaja entre +30 y
# +55. Poner aqui -90..0 daba por imposible una planta entera.
foreach ($r in 1..7) {
  $RANGOS["4$(1109 + 2 * $r) max_tilt_west_r$r [deg]"] = @{min=-90; max=90}
  $RANGOS["4$(1123 + 2 * $r) min_tilt_east_r$r [deg]"] = @{min=-90; max=90}
}

# Pares (max_tilt_west_rN, min_tilt_east_rN): el limite este siempre tiene que
# quedar POR DEBAJO del oeste. Esto no es un rango, es una relacion entre dos
# variables, y es lo que caza el corrimiento de registros que se vio en Ayora:
# una TCU con min_tilt = 55 pasa cualquier rango, pero tener el mismo valor en
# los dos limites no deja sitio para moverse.
$PARES_TILT = @()
foreach ($r in 1..7) {
  $PARES_TILT += ,@{max="4$(1109 + 2 * $r) max_tilt_west_r$r [deg]"; min="4$(1123 + 2 * $r) min_tilt_east_r$r [deg]"; rango=$r}
}

# Un valor en un registro de metros que resulta ser un angulo redondo en
# radianes casi nunca es casualidad: es el crudo de la variable de al lado.
function Parece-Radianes([double]$v) {
    if ([double]::IsNaN($v) -or $v -eq 0) { return '' }
    if ([Math]::Abs($v) -ge 1.6) { return '' }          # > pi/2: ya no cuela
    $g = $v * 180.0 / [Math]::PI
    if ([Math]::Abs($g - [Math]::Round($g / 5.0) * 5.0) -gt 0.05) { return '' }
    return ('parece un angulo en radianes ({0} rad = {1} grados)' -f $v.ToString('0.####', $INV), ([Math]::Round($g / 5.0) * 5.0).ToString('0.#', $INV))
}

# Devuelve '' si el valor es plausible, o el motivo por el que no lo es.
# $texto es el valor ya decodificado tal y como lo pinta la herramienta.
function Rango-Sospechoso([string]$nombre, [string]$texto) {
    $t = "$texto".Trim()
    if ($t -eq '' -or $t -eq '-') { return '' }
    if ($t.StartsWith('0x')) { return '' }              # hex: sin rango util
    $v = 0.0
    if (-not [double]::TryParse($t.Replace(',', '.'), [Globalization.NumberStyles]::Float, $INV, [ref]$v)) { return '' }
    if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return "valor no finito" }
    $r = $null
    if ($RANGOS.Contains($nombre)) { $r = $RANGOS[$nombre] }
    if ($null -eq $r) { return '' }
    if ($v -lt $r.min -or $v -gt $r.max) {
        $pista = ''
        if ($nombre.Contains('[m]')) { $pista = Parece-Radianes $v }
        $motivo = ('fuera de rango: {0} no esta entre {1} y {2}' -f $t, $r.min, $r.max)
        if ($pista) { $motivo += " - $pista" }
        return $motivo
    }
    return ''
}

# ---------------------------------------------------------------------------
#  Decodificacion de alarmas y estados (mapa v6.1)
# ---------------------------------------------------------------------------
$BITS_AL1 = @{   # 30002
  2='tilt fuera de rango'; 4='seta de emergencia pulsada'; 6='sensor T bateria desconectado'
  7='config por defecto (fallo NVM)'; 8='fallo com con Xbee'; 9='params com por defecto (fallo NVM)'
  10='bateria desconectada'; 11='SoC muy bajo (L2)'; 12='SoC bajo L3'; 13='SoC bajo (L1)'
  14='SoC critico (<10%)'   # bit del mapa R7 de la NCU (batt_critical), no documentado en el PDF v6.1
  15='FW de test / no oficial'
}
$BITS_AL2 = @{   # 30003
  2='fecha/hora sin ajustar'; 4='cortocircuito de motor'; 5='sobrecorriente de motor'
  8='eje bloqueado'; 12='com con NCU perdida'; 14='motor mas lento de lo esperado'
  15='fallo en driver de motor'
}
$BITS_AL3 = @{   # 30004 (IC defectuoso)
  2='flash defectuosa'; 3='ESP32 defectuoso'; 4='Xbee defectuoso'
  5='acelerometro defectuoso'; 6='RTC defectuoso'; 7='com con MCU secundario rota'
}
$BITS_AL4 = @{   # 30005
  0='V motor baja'; 1='V motor alta'; 2='V bus baja'; 3='V bus alta'
  4='T PCB baja'; 5='T PCB alta'; 8='IC defectuoso (ver alarmas_3)'
}
$BITS_STATUS = @{ # 30006 (informativo)
  0='limite Oeste alcanzado'; 1='limite Este alcanzado'; 5='preservacion de bateria activa'
  6='SoC insuficiente para modo auto'; 9='calefactor ON'; 10='relajacion de bateria'
  11='alarma de motor enclavada'; 15='sistema OK'
}
$CHARGER_STATES = @{
  1='inicial'; 2='bateria aislada'; 3='bateria conectada'; 4='inicializando BQ'
  5='carga CC'; 6='carga CV'; 7='carga completa'; 8='bateria no detectada'
}
# Bits criticos -> estado ALARMA en el diagnostico. Mismo criterio que
# collector/decode.py (tracker_health): out_of_range, stop_button,
# batt_critical (bit 14, no el L3 del bit 12), eje y motor.
# El bloque compat de la NCU (30500+) lleva SU propio mapa, no el de la TCU.
# Casi todos los bits coinciden, pero no todos: donde el mapa de la NCU dice
# Reserved, decodificar con la tabla de la TCU se inventaba una alarma. Los que
# no existen alli son el 6, 9 y 10 de Alarms1 y el 12 y 15 de Alarms2 - entre
# ellos 'bateria desconectada' y 'com con NCU perdida', que es como se vio.
# Cada bloque con su tabla: esta es la de NCU_Modbus_Map_R7_1, hoja TCU Compat.
$BITS_AL1_NCU = @{   # 30502 Alarms1_s1
  2='tilt fuera de rango'; 4='seta de emergencia pulsada'; 7='config por defecto (fallo NVM)'
  8='fallo com con Xbee'; 11='SoC muy bajo (L2)'; 12='SoC insuficiente (L3)'
  13='SoC bajo (L1)'; 14='SoC critico (<10%)'; 15='FW de test / no oficial'
}
$BITS_AL2_NCU = @{   # 30503 Alarms2_s1 (memorizadas)
  2='fecha/hora sin ajustar'; 4='cortocircuito de motor'; 5='sobrecorriente de motor'
  8='eje bloqueado'; 14='motor mas lento de lo esperado'
}
$CRIT_AL1 = (1 -shl 2) -bor (1 -shl 4) -bor (1 -shl 14)                    # rango, seta, SoC critico <10%
$CRIT_AL2 = (1 -shl 4) -bor (1 -shl 5) -bor (1 -shl 8) -bor (1 -shl 15)   # corto, sobrecorriente, eje, driver
# el 15 (driver de motor) no existe en el mapa de la NCU: fuera de su mascara
$CRIT_AL2_NCU = (1 -shl 4) -bor (1 -shl 5) -bor (1 -shl 8)

function Bits-Texto([int]$valor, [hashtable]$tabla) {
    $lista = @()
    foreach ($b in ($tabla.Keys | Sort-Object)) {
        if ($valor -band (1 -shl $b)) { $lista += $tabla[$b] }
    }
    return $lista
}

# ---- HSU (estacion meteo, mapa R23; esclavo Modbus tras el gateway) ----
$HSU_AL1 = @{
  0='com. anemometro'; 1='com. sensor nieve'; 2='com. piranometro'; 3='com. sensor T ext'
  4='bateria desconectada'; 5='com. sensor granizo'; 6='ALARMA NIEVE'; 7='ALARMA LLUVIA'
  9='ALARMA VIENTO'; 10='ALARMA RACHA'; 12='ALARMA VIENTO N2'; 13='ALARMA VIENTO N3'
  14='com. dual irradiancia'; 15='com. pluviometro'
}

# ---- NCU (registros propios, mapa R7.1; puerto 502, unit 1) ----
$NCU_DIN = @{
  0='bateria UPS baja'; 1='fallo alimentacion UPS'; 13='SETA DE EMERGENCIA'
}
$NCU_MAIN = @{
  0='alarma bateria baja'; 4='GW1 DESCONECTADO'; 5='GW2 DESCONECTADO'
}

# Lee la meteo en vivo de una HSU (bloques 30000-30013 y 30021-30028).
# Devuelve @{filas=[pscustomobject Campo/Valor/Nota]; alarmas=@(); nivel=int}.
function Hsu-LeerMeteo([byte]$unit) {
    $w  = FC03-Leer $unit (Dir-Trama 30000) 14
    $w2 = FC03-Leer $unit (Dir-Trama 30021) 8
    $nivel = $w[1] -band 0x7
    $al1 = $w[2]
    $alarmas = @(Bits-Texto $al1 $HSU_AL1)
    $viento = Palabras-A-F32 @($w[3], $w[4])
    $dir    = Palabras-A-F32 @($w[5], $w[6])
    $nieve  = Palabras-A-F32 @($w[7], $w[8])
    $tempC  = ($w[10] / 10.0) - 273.15
    $irrRaw = ([int]$w[13] -shl 16) -bor [int]$w[12]
    $filas = @(
        [pscustomobject]@{Campo='Nivel de viento (0-7)';   Valor="$nivel";                                              Nota=$(if ($nivel -gt 0) { 'ALARMA DE VIENTO ACTIVA' } else { '' })}
        [pscustomobject]@{Campo='Viento [m/s]';            Valor=$viento.ToString('0.##', $INV);                        Nota=("{0:0.#} km/h" -f ($viento * 3.6))}
        [pscustomobject]@{Campo='Direccion viento [deg]';  Valor=$dir.ToString('0.#', $INV);                            Nota="sector $((($w[1] -shr 12) -band 0xF))"}
        [pscustomobject]@{Campo='Nieve [m]';               Valor=$nieve.ToString('0.###', $INV);                        Nota=''}
        [pscustomobject]@{Campo='Lluvia [mm/h]';           Valor="$($w[9])";                                            Nota=''}
        [pscustomobject]@{Campo='Temperatura ext [C]';     Valor=$tempC.ToString('0.#', $INV);                          Nota=''}
        [pscustomobject]@{Campo='Humedad rel [%]';         Valor=(($w[11] / 10.0)).ToString('0.#', $INV);               Nota=''}
        [pscustomobject]@{Campo='Irradiancia [W/m2]';      Valor=(($irrRaw / 100.0)).ToString('0.#', $INV);             Nota=''}
        [pscustomobject]@{Campo='Alarmas (30002)';         Valor=("0x{0:X4}" -f $al1);                                  Nota=$(if ($alarmas.Count) { $alarmas -join '; ' } else { 'sin alarmas' })}
        [pscustomobject]@{Campo='Bateria litio [mV]';      Valor="$($w2[0])";                                           Nota=''}
        [pscustomobject]@{Campo='T interna [C]';           Valor=(($w2[5] - 273)).ToString('0', $INV);                  Nota=''}
        [pscustomobject]@{Campo='V bateria int [mV]';      Valor="$($w2[6])";                                           Nota=''}
        [pscustomobject]@{Campo='V panel/aliment [mV]';    Valor="$($w2[7])";                                           Nota=''}
    )
    return @{filas=$filas; alarmas=$alarmas; nivel=$nivel}
}

# Lee la configuracion relevante de la HSU. Devuelve filas Campo/Valor/Nota y
# los valores de umbrales para rellenar los cuadros de edicion.
function Hsu-LeerConfig([byte]$unit) {
    $wCfg = FC03-Leer $unit (Dir-Trama 41002) 7      # 41002..41008
    $wAlt = FC03-Leer $unit (Dir-Trama 40008) 1      # altura sensor nieve
    $wUmb = FC03-Leer $unit (Dir-Trama 41011) 8      # 41011..41018
    $low  = Palabras-A-F32 @($wUmb[0], $wUmb[1])     # 41011 desactivacion
    $mid  = Palabras-A-F32 @($wUmb[2], $wUmb[3])     # 41013 activacion
    $tLow = $wUmb[6]; $tMid = $wUmb[7]               # 41017 / 41018
    $sens = $wCfg[6]
    $nombresSens = @{0='pluviometro'; 1='T-HR ext'; 2='piranometro 3STP'; 3='granizo RK400'; 4='lluvia'; 5='nieve'; 6='anemometro sonico'; 7='piranometro Kipp'; 8='inundacion'; 9='T ext'; 10='dual irradiancia'}
    $lista = @(Bits-Texto $sens $nombresSens)
    $filas = @(
        [pscustomobject]@{Campo='Esclavo Modbus (41002)';        Valor="$($wCfg[0] -band 0xFF)";               Nota=''}
        [pscustomobject]@{Campo='Sensores config. (41008)';      Valor=("0x{0:X4}" -f $sens);                  Nota=$(if ($lista.Count) { $lista -join ', ' } else { 'ninguno declarado' })}
        [pscustomobject]@{Campo='Altura sensor nieve [cm]';      Valor="$($wAlt[0])";                          Nota='40008'}
        [pscustomobject]@{Campo='Umbral viento ON [m/s]';        Valor=$mid.ToString('0.##', $INV);            Nota='41013 (activacion)'}
        [pscustomobject]@{Campo='Umbral viento OFF [m/s]';       Valor=$low.ToString('0.##', $INV);            Nota='41011 (desactivacion)'}
        [pscustomobject]@{Campo='Tiempo activacion [s]';         Valor="$tMid";                                Nota='41018'}
        [pscustomobject]@{Campo='Tiempo desactivacion [s]';      Valor="$tLow";                                Nota='41017'}
    )
    return @{filas=$filas; low=$low; mid=$mid; tLow=$tLow; tMid=$tMid}
}

# Una fila de la caja negra de 24 h de la HSU (4 registros por minuto desde 31000)
function Hsu-CajaFila([int[]]$w, [int]$minuto) {
    return [pscustomobject]@{
        Hora        = ('{0:00}:{1:00}' -f [math]::Floor($minuto / 60), ($minuto % 60))
        Dir_deg     = $w[0]
        Vmedia_kmh  = ($w[1] -band 0xFF)
        Vmax_kmh    = (($w[1] -shr 8) -band 0xFF)
        NieveMax_cm = $w[2]
        Irr_Wm2     = [math]::Round($w[3] / 10.0, 1)
    }
}

# Desglose de alarmas en columnas 0/1 para el CSV (filtrables en Excel).
# Recibe los hex '0x....' de alarmas_1/2; si vienen vacios, columnas vacias.
$DESGLOSE_AL1 = @(@(2,'al1_tilt_rango'),@(4,'al1_seta'),@(6,'al1_sensor_Tbat'),@(7,'al1_config_nvm'),
    @(8,'al1_xbee'),@(9,'al1_com_nvm'),@(10,'al1_bat_descon'),@(11,'al1_soc_L2'),@(12,'al1_soc_L3'),
    @(13,'al1_soc_L1'),@(14,'al1_soc_critico'),@(15,'al1_fw_test'))
$DESGLOSE_AL2 = @(@(2,'al2_reloj'),@(4,'al2_cortocircuito'),@(5,'al2_sobrecorriente'),@(8,'al2_eje_bloq'),
    @(12,'al2_com_ncu'),@(14,'al2_motor_lento'),@(15,'al2_driver'))
function Alarmas-Desglose([string]$hex1, [string]$hex2) {
    $cols = [ordered]@{}
    $a1 = -1; $a2 = -1
    if ($hex1 -match '^0x([0-9A-Fa-f]+)$') { $a1 = [Convert]::ToInt32($Matches[1], 16) }
    if ($hex2 -match '^0x([0-9A-Fa-f]+)$') { $a2 = [Convert]::ToInt32($Matches[1], 16) }
    foreach ($d in $DESGLOSE_AL1) { $cols[$d[1]] = $(if ($a1 -lt 0) { '' } elseif ($a1 -band (1 -shl $d[0])) { 1 } else { 0 }) }
    foreach ($d in $DESGLOSE_AL2) { $cols[$d[1]] = $(if ($a2 -lt 0) { '' } elseif ($a2 -band (1 -shl $d[0])) { 1 } else { 0 }) }
    return $cols
}

# Guardia de viento para tests de movimiento: consulta las HSU cacheadas por
# la NCU. Devuelve @{nivel;alarma} o $null si no hay datos de HSU.
function Viento-Seguro([string]$ipNcu, [int]$to, [int]$puerto = 0) {
    if ($puerto -eq 0) { $puerto = $PUERTO_NCU }
    try {
        Modbus-Conectar $ipNcu $puerto $to
        $hs = @(Ncu-HsuCompat)
        Modbus-Cerrar
        $nivel = -1; $alarma = $false
        foreach ($h in $hs) {
            if ($h.Salud -eq 'OFFLINE') { continue }
            if ($h.main_status -match '^0x([0-9A-Fa-f]+)$') {
                $n = [Convert]::ToInt32($Matches[1], 16) -band 0x7
                if ($n -gt $nivel) { $nivel = $n }
            }
            if ($h.alarmas_1 -match '^0x([0-9A-Fa-f]+)$') {
                if ([Convert]::ToInt32($Matches[1], 16) -band 0x200) { $alarma = $true }
            }
        }
        if ($nivel -lt 0) { return $null }
        return @{nivel=$nivel; alarma=$alarma}
    } catch { Modbus-Cerrar; return $null }
}

# El modo (bits 9:8) y el estado de comisionado (bits 4:3) viven en el MISMO
# registro 30001, asi que leer uno y no ensenar el otro era tirar informacion.
# Antes de aplicar un modo a un rango hace falta saber en cual estan. Pura.
$MODOS_TCU = @('OFF','MANUAL','AUTO','?')
function Modo-De([int]$mainStatus) { return $MODOS_TCU[(($mainStatus -shr 8) -band 0x3)] }
function Comis-De([int]$mainStatus) { return (($mainStatus -shr 3) -band 0x3) }

$ESTADOS_COMIS = @{3='Factory'; 2='TCU configurado'; 1='Motor verificado'; 0='COMISIONADO'}

function Html-Esc([string]$s) {
    return "$s".Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

# Informe PEM autocontenido en HTML. $m: planta, ip, fecha, usuario, version,
# mapa + listas opcionales diag/inv/aud/pem (objetos de la sesion).
# Los recuadros de la portada, a partir de lo que haya en la sesion. Devuelve
# una lista de @{titulo; valor; nota; clase}. Pura: se prueba sin ventana.
function Portada-Bloques($m) {
    $r = New-Object System.Collections.ArrayList
    $diag = @($m.diag)
    if ($diag.Count -gt 0) {
        $tcus = @($diag | Where-Object { "$($_.TCU)" -ne 'NCU' -and "$($_.TCU)" -notlike 'HSU*' })
        $ok = @($tcus | Where-Object { "$($_.Salud)" -eq 'OK' }).Count
        $pc = $(if ($tcus.Count -gt 0) { [math]::Round(100.0 * $ok / $tcus.Count, 1) } else { 0 })
        [void]$r.Add(@{titulo='Seguidores operativos'; valor="$pc %"; nota="$ok de $($tcus.Count) sin aviso ni alarma"
                       clase=$(if ($pc -ge 98) { 'bien' } elseif ($pc -ge 90) { 'medio' } else { 'mal' })})
        $mal = @($tcus | Where-Object { @('ALARMA','OFFLINE') -contains "$($_.Salud)" }).Count
        if ($mal -gt 0) { [void]$r.Add(@{titulo='Con alarma o sin comunicacion'; valor="$mal"; nota='requieren visita'; clase='mal'}) }
    }
    # OJO: no llamar a nada "inv" aqui. PowerShell no distingue mayusculas, asi
    # que $inv pisa $INV (la cultura invariante) y revienta el parseo de
    # decimales de cualquier funcion que se llame desde este ambito.
    $inventario = @($m.inv)
    if ($inventario.Count -gt 0) {
        $ver = @{}
        foreach ($i in $inventario) { $v = "$($i.FW)".Trim(); if ($v -ne '') { $ver[$v] = 1 + [int]$ver[$v] } }
        $orden = @($ver.Keys | Sort-Object { - [int]$ver[$_] })
        if ($orden.Count -gt 0) {
            $nota = $(if ($orden.Count -eq 1) { 'toda la flota igual' } else { (@($orden | ForEach-Object { "$($ver[$_]) en $_" }) -join ' | ') })
            [void]$r.Add(@{titulo='Versiones de firmware'; valor="$($orden.Count)"; nota=$nota
                           clase=$(if ($orden.Count -eq 1) { 'bien' } else { 'medio' })})
        }
    }
    $aud = @($m.aud)
    if ($aud.Count -gt 0) {
        $tcusMal = @(@($aud | ForEach-Object { "$($_.NCU)/$($_.TCU)" }) | Sort-Object -Unique).Count
        [void]$r.Add(@{titulo='Configuracion desviada'; valor="$tcusMal"; nota="$($aud.Count) desviaciones contra el preset"; clase='mal'})
    }
    # @($null) tiene UN elemento, asi que hay que preguntar por el nulo aparte
    $cie = @($(if ($null -ne $m.cierre) { $m.cierre } else { @() }))
    if ($cie.Count -gt 0) {
        [void]$r.Add(@{titulo='Actualizadas sin cerrar'; valor="$($cie.Count)"; nota='les falta parametros, NVM o modo AUTO'; clase='mal'})
    }
    $lec = @($m.lectura)
    if ($lec.Count -gt 0) {
        $imp = @(Sospechas-Lectura $lec).Count
        [void]$r.Add(@{titulo='Valores imposibles'; valor="$imp"; nota=$(if ($imp -eq 0) { 'ninguno en la ultima lectura' } else { 'revisar: fuera del rango fisico' })
                       clase=$(if ($imp -eq 0) { 'bien' } else { 'mal' })})
    }
    return $r.ToArray()
}

function Informe-Html([hashtable]$m) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Informe PEM - ' + (Html-Esc $m.planta) + '</title><style>')
    [void]$sb.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;font-size:13px;margin:24px;color:#222}h1{font-size:20px}h2{font-size:15px;margin-top:26px;border-bottom:2px solid #345;padding-bottom:4px}table{border-collapse:collapse;width:100%;margin-top:8px}th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;font-size:12px}th{background:#eef2f6;cursor:pointer;user-select:none}tr.ok td{background:#eaf7ee}tr.aviso td{background:#fff6e0}tr.alarma td{background:#fdeaea}tr.off td{background:#f0f0f0;color:#777}.meta{color:#555}.res{font-weight:600;margin:6px 0}.ok2{color:#137333;font-weight:400}.ko2{color:#a50e0e;font-weight:400}')
    [void]$sb.AppendLine('tr.filtros td{background:#f7f9fb;padding:2px 4px}tr.filtros input[type=text],tr.filtros input:not([type]){width:100%;box-sizing:border-box;font-size:11px;padding:2px;border:1px solid #bbb;border-radius:3px}.vis{color:#555;font-weight:400;font-size:12px}th:hover{background:#dde6ef}th .fl{color:#06c}')
    [void]$sb.AppendLine('.fm{position:relative;display:block}.fmb{width:100%;box-sizing:border-box;font:inherit;font-size:11px;padding:2px 4px;border:1px solid #bbb;border-radius:3px;background:#fff;cursor:pointer;text-align:left;overflow:hidden;white-space:nowrap}.fmb.act{border-color:#06c;color:#06c;font-weight:700}')
    [void]$sb.AppendLine('.fmp{position:absolute;z-index:30;top:100%;left:0;min-width:100%;max-height:250px;overflow:auto;background:#fff;border:1px solid #bbb;border-radius:3px;box-shadow:0 6px 18px rgba(20,30,45,.2);padding:5px 7px;display:none;white-space:nowrap;text-align:left}')
    [void]$sb.AppendLine('.fmp label{display:block;font-weight:400;font-size:12px;padding:1px 0;cursor:pointer}.fmp .fmt{border-bottom:1px solid #e6ebf0;margin-bottom:4px;padding-bottom:4px}.fmp .fmt a{color:#06c;cursor:pointer;text-decoration:underline;margin-right:10px;font-size:11px}')
    [void]$sb.AppendLine('#avisojs{background:#fff4d6;border:1px solid #e0b64a;border-radius:4px;padding:9px 12px;margin:12px 0;font-size:13px;color:#6b4b00}#avisojs b{color:#8a5a00}')
    [void]$sb.AppendLine('.portada{margin:16px 0 20px}.portada h2{margin-bottom:10px}')
    [void]$sb.AppendLine('.tiles{display:flex;flex-wrap:wrap;gap:12px}')
    [void]$sb.AppendLine('.tile{flex:1 1 190px;min-width:170px;border:1px solid #cfd9e4;border-left-width:6px;border-radius:6px;padding:12px 14px;background:#fbfdff}')
    [void]$sb.AppendLine('.tile .big{font-size:30px;font-weight:700;line-height:1.1}.tile .lab{font-size:13px;color:#33475b;margin-top:3px}.tile .sub{font-size:11.5px;color:#6b7c8f;margin-top:5px}')
    [void]$sb.AppendLine('.tile.bien{border-left-color:#2e9e5b}.tile.bien .big{color:#2e9e5b}')
    [void]$sb.AppendLine('.tile.medio{border-left-color:#d08600}.tile.medio .big{color:#d08600}')
    [void]$sb.AppendLine('.tile.mal{border-left-color:#c0392b}.tile.mal .big{color:#c0392b}')
    [void]$sb.AppendLine('.indice{background:#eef4fb;border:1px solid #cfe0f2;border-radius:4px;padding:7px 10px;margin:14px 0;font-size:13px}.indice a{color:#06c;text-decoration:none;font-weight:700}.indice a:hover{text-decoration:underline}')
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine('<h1>Informe de puesta en marcha &mdash; ' + (Html-Esc $m.planta) + '</h1>')
    [void]$sb.AppendLine('<p class="meta">Fecha: ' + (Html-Esc $m.fecha) + ' &middot; IP/conexion: ' + (Html-Esc $m.ip) + ' &middot; Tecnico: ' + (Html-Esc $m.usuario) + '<br>TCU Toolbox v' + (Html-Esc $m.version) + ' &middot; Mapa: ' + (Html-Esc $m.mapa) + '</p>')
    # Los filtros los monta el JavaScript al abrir la pagina. En el PC de planta
    # el navegador bloquea por defecto los scripts de los ficheros locales, y
    # entonces las tablas salen sin la fila de filtros y parece que el informe
    # esta roto. Este aviso se queda visible en ese caso, y el propio JS lo
    # borra nada mas arrancar, asi que solo lo ve quien tiene el problema.
    [void]$sb.AppendLine('<div id="avisojs"><b>Los filtros de las tablas no estan activos.</b> Los monta JavaScript al abrir la pagina, y tu navegador lo tiene bloqueado. Si abajo sale la barra <i>&laquo;Internet Explorer ha restringido la ejecucion de scripts&raquo;</i>, pulsa <b>Permitir contenido bloqueado</b>. Si no, abre este fichero con Chrome o con Edge. El informe se lee igual sin filtros: solo pierdes poder filtrar y ordenar.</div>')
    $clase = { param($s) switch -Wildcard ("$s") { 'OK*'{'ok'} 'PASA*'{'ok'} 'ALARMA*'{'alarma'} 'FALLA*'{'alarma'} 'FALLO*'{'alarma'} 'AVISO*'{'aviso'} 'DUDOSO*'{'aviso'} 'PENDIENTE*'{'aviso'} 'OFFLINE*'{'off'} 'SALTADO*'{'off'} default{''} } }
    $tabla = {
        param($titulo, $filas, $cols, $colEstado, $clave)
        if (-not $filas -or @($filas).Count -eq 0) { return }
        $hh = ''
        if ($m.horas -and $m.horas[$clave]) { $hh = ' <span class="meta">(' + (Html-Esc $m.horas[$clave]) + ')</span>' }
        [void]$sb.AppendLine('<h2 id="s-' + $clave + '">' + (Html-Esc $titulo) + $hh + ' <span class="meta">(' + @($filas).Count + ' filas)</span></h2>')
        $grupos = @($filas) | Group-Object $colEstado | ForEach-Object { "$($_.Count) $($_.Name)" }
        [void]$sb.AppendLine('<div class="res">' + (Html-Esc ($grupos -join ' | ')) + ' <span class="vis"></span></div>')
        [void]$sb.AppendLine('<table id="t-' + $clave + '" class="filtrable"><thead><tr>' + (($cols | ForEach-Object { '<th title="clic para ordenar">' + (Html-Esc $_) + '<span class="fl"></span></th>' }) -join '') + '</tr></thead><tbody>')
        foreach ($f in @($filas)) {
            $cl = & $clase $f.$colEstado
            [void]$sb.AppendLine('<tr' + $(if ($cl) { ' class="' + $cl + '"' } else { '' }) + '>' + (($cols | ForEach-Object { '<td>' + (Html-Esc "$($f.$_)") + '</td>' }) -join '') + '</tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    # Lectura de variables: columnas dinamicas (una por variable leida) y
    # resumen de discrepancias, que es lo que interesa de una lectura masiva:
    # que TCUs se salen del valor mayoritario.
    $tablaLectura = {
        $filasL = @($m.lectura)
        $colsL = @($filasL[0].PSObject.Properties.Name)
        [void]$sb.AppendLine('<h2 id="s-lectura">Lectura de variables' + $(if ($m.horas -and $m.horas['lectura']) { ' <span class="meta">(' + (Html-Esc $m.horas['lectura']) + ')</span>' } else { '' }) + ' <span class="meta">(' + $filasL.Count + ' TCUs)</span></h2>')
        $disc = @()
        foreach ($c in $colsL) {
            if (@('NCU','TCU','Estado') -contains $c) { continue }
            # a mano, no con Group-Object: los nombres llevan corchetes ([m],
            # [deg]) y Group-Object los tomaria como comodines
            $cuenta = @{}
            foreach ($f in $filasL) { $v = "$($f.$c)"; if ($v -ne '') { $cuenta[$v] = 1 + [int]$cuenta[$v] } }
            $claves = @($cuenta.Keys | Sort-Object { - [int]$cuenta[$_] }, { "$_" })
            if ($claves.Count -eq 1 -and $filasL.Count -le 1) {
                $disc += '<span class="ok2">' + (Html-Esc $c) + ' = ' + (Html-Esc $claves[0]) + '</span>'
            } elseif ($claves.Count -eq 1) {
                $disc += '<span class="ok2">' + (Html-Esc $c) + ': todas coinciden = ' + (Html-Esc $claves[0]) + '</span>'
            } elseif ($claves.Count -gt 1) {
                $det = ($claves | ForEach-Object { (Html-Esc $_) + ' en ' + $cuenta[$_] + ' TCUs' }) -join ' &middot; '
                $disc += '<span class="ko2">' + (Html-Esc $c) + ': ' + $claves.Count + ' valores distintos &rarr; ' + $det + '</span>'
            }
        }
        if ($disc.Count) { [void]$sb.AppendLine('<div class="res">' + ($disc -join '<br>') + '</div>') }
        # valores imposibles: van aparte del reparto de valores porque un valor
        # puede coincidir en toda la planta y aun asi estar mal
        $sosp = @(Sospechas-Lectura $filasL)
        if ($sosp.Count) {
            $lin = @($sosp | ForEach-Object {
                '<span class="ko2">' + (Html-Esc $(if ($_.NCU) { "NCU$($_.NCU) TCU $($_.TCU)" } else { "TCU $($_.TCU)" })) + ': ' + (Html-Esc $_.Variable) + ' = ' + (Html-Esc $_.Valor) + ' &rarr; ' + (Html-Esc $_.Motivo) + '</span>' })
            [void]$sb.AppendLine('<div class="res"><b>Valores imposibles (' + $sosp.Count + ')</b><br>' + ($lin -join '<br>') + '</div>')
        }
        [void]$sb.AppendLine('<table id="t-lectura" class="filtrable"><thead><tr>' + (($colsL | ForEach-Object { '<th title="clic para ordenar">' + (Html-Esc $_) + '<span class="fl"></span></th>' }) -join '') + '</tr></thead><tbody>')
        foreach ($f in $filasL) {
            $cl = $(if ("$($f.Estado)" -and "$($f.Estado)" -ne 'OK') { ' class="alarma"' } else { '' })
            [void]$sb.AppendLine('<tr' + $cl + '>' + (($colsL | ForEach-Object { '<td>' + (Html-Esc "$($f.$_)") + '</td>' }) -join '') + '</tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    # Las secciones se pintan EMPEZANDO POR LA ULTIMA QUE SE EJECUTO. Si acabas
    # de hacer un inventario, el inventario va arriba aunque en la sesion
    # hubiera un diagnostico anterior: si no, el informe parece de otra cosa.
    # Portada: lo que se manda al cliente. Se calcula con lo que haya en la
    # sesion; lo que no se haya hecho no sale, en vez de salir en blanco.
    $port = @(Portada-Bloques $m)
    if ($port.Count -gt 0) {
        [void]$sb.AppendLine('<div class="portada"><h2>Estado de la planta</h2><div class="tiles">')
        foreach ($b in $port) {
            [void]$sb.AppendLine('<div class="tile ' + $b.clase + '"><div class="big">' + (Html-Esc $b.valor) + '</div><div class="lab">' +
                (Html-Esc $b.titulo) + '</div>' + $(if ($b.nota) { '<div class="sub">' + (Html-Esc $b.nota) + '</div>' } else { '' }) + '</div>')
        }
        [void]$sb.AppendLine('</div></div>')
    }
    $secciones = @(
        @{clave='lectura'; titulo='Lectura de variables'; filas=$m.lectura; pinta=$tablaLectura}
        @{clave='bat'; titulo='Auditoria de baterias'; filas=$m.bat
          cols=@('NCU','TCU','Tipo','Detalle','Gravedad'); estado='Gravedad'}
        @{clave='diag'; titulo='Diagnostico de flota'; filas=$m.diag
          cols=@('NCU','TCU','Salud','Modo','Tilt','Objetivo','Dif','SoC','Alarmas'); estado='Salud'}
        @{clave='pem'; titulo='Puesta en marcha (PEM)'; filas=$m.pem
          cols=@('NCU','TCU','Resultado','Detalle'); estado='Resultado'}
        @{clave='aud'; titulo='Auditoria contra preset de referencia'; filas=$m.aud
          cols=@('NCU','TCU','Variable','Esperado','Leido','Nota'); estado='Nota'}
        @{clave='inv'; titulo='Inventario de flota'; filas=$m.inv
          cols=@('NCU','TCU','Serie','MAC','FW','FW_fabrica','HW','Fecha_fab','Nota'); estado='Nota'}
        @{clave='esc'; titulo='Escritura de variables'; filas=$m.esc
          cols=@('NCU','TCU','Variable','Antes','Despues','Estado'); estado='Estado'}
    )
    $conDatos = @($secciones | Where-Object { $_.filas -and @($_.filas).Count -gt 0 })
    # sin marca de orden (informes de versiones viejas) van al final
    $conDatos = @($conDatos | Sort-Object { $(if ($m.orden -and $m.orden[$_.clave]) { - [int]$m.orden[$_.clave] } else { 999 }) })
    if ($conDatos.Count -gt 1) {
        $idx = $conDatos | ForEach-Object {
            $hh = $(if ($m.horas -and $m.horas[$_.clave]) { ' ' + (Html-Esc $m.horas[$_.clave]) } else { '' })
            '<a href="#s-' + $_.clave + '">' + (Html-Esc $_.titulo) + '</a><span class="meta">' + $hh + ' &middot; ' + @($_.filas).Count + ' filas</span>'
        }
        [void]$sb.AppendLine('<div class="indice">En esta sesion: ' + ($idx -join ' &nbsp;|&nbsp; ') + '</div>')
    }
    foreach ($sec in $conDatos) {
        if ($sec.pinta) { & $sec.pinta }
        else { & $tabla $sec.titulo $sec.filas $sec.cols $sec.estado $sec.clave }
    }
    if ($conDatos.Count -eq 0) {
        [void]$sb.AppendLine('<p>Sin datos en esta sesion: ejecuta una Escritura, una Lectura de variables, un Diagnostico, PEM, Auditoria o Inventario antes de generar el informe.</p>')
    }
    [void]$sb.AppendLine('<p class="meta">Generado por TCU Toolbox &mdash; Factiun. Filtra con la fila bajo la cabecera (desplegable = valor exacto; caja de texto = contiene) y ordena con un clic en la cabecera.</p>')
    # Filtros por columna y orden al clicar la cabecera. JS embebido, sin red y
    # sin sintaxis moderna a proposito (bucles for clasicos, nada de NodeList
    # .forEach ni arrow functions): asi funciona tambien si el PC de planta
    # abre el informe con Internet Explorer o un Edge en modo compatibilidad.
    [void]$sb.AppendLine(@'
<script>
(function(){
  // Sin librerias y a la antigua (bucles for, attachEvent): estos informes se
  // abren a veces en el IE del PC de planta.
  // Si esto se ejecuta, los filtros van a montarse: fuera el aviso.
  var av = document.getElementById("avisojs");
  if (av && av.parentNode) { av.parentNode.removeChild(av); }
  var paneles = [];
  function cerrarPaneles() { for (var i = 0; i < paneles.length; i++) { paneles[i].style.display = "none"; } }
  if (document.addEventListener) { document.addEventListener("click", cerrarPaneles, false); }
  else if (document.attachEvent) { document.attachEvent("onclick", cerrarPaneles); }
  function parar(e) {
    e = e || window.event;
    if (e.stopPropagation) { e.stopPropagation(); } else { e.cancelBubble = true; }
  }
  var tablas = document.getElementsByTagName("table");
  for (var i = 0; i < tablas.length; i++) {
    if (tablas[i].className.indexOf("filtrable") < 0) continue;
    try { preparar(tablas[i]); } catch (e) { if (window.console) console.log("tabla no preparada: " + e.message); }
  }
  function texto(celda) { return (celda.textContent || celda.innerText || "").replace(/^\s+|\s+$/g, ""); }
  function preparar(tb) {
    var cabecera = tb.tHead ? tb.tHead.rows[0] : tb.rows[0];
    var cuerpo = tb.tBodies[0];
    if (!cabecera || !cuerpo) return;
    var filas = [];
    for (var k = 0; k < cuerpo.rows.length; k++) { filas.push(cuerpo.rows[k]); }
    if (!filas.length) return;
    var nCols = cabecera.cells.length;
    var visor = null;
    var prev = tb.previousSibling;
    while (prev && !visor) {
      if (prev.nodeType === 1 && prev.getElementsByClassName) {
        var vs = prev.getElementsByClassName("vis");
        if (vs.length) visor = vs[0];
      }
      prev = prev.previousSibling;
    }
    var tf = (tb.tHead || tb).insertRow(tb.tHead ? -1 : 1);
    tf.className = "filtros";
    var filtros = [];
    for (var c = 0; c < nCols; c++) {
      var celda = tf.insertCell(-1);
      var vals = {}, lista = [];
      for (var f = 0; f < filas.length; f++) {
        var t = texto(filas[f].cells[c]);
        if (t && !vals[t]) { vals[t] = 1; lista.push(t); }
      }
      lista.sort();
      filtros.push((lista.length > 0 && lista.length <= 30) ? multi(celda, lista) : caja(celda));
    }
    function enganchar(el, fn) {
      if (el.addEventListener) { el.addEventListener("change", fn, false); el.addEventListener("input", fn, false); }
      else if (el.attachEvent) { el.attachEvent("onchange", fn); el.attachEvent("onkeyup", fn); }
    }
    // Caja "contiene" cuando la columna tiene demasiados valores distintos
    function caja(celda) {
      var inp = document.createElement("input");
      inp.setAttribute("placeholder", "filtrar...");
      enganchar(inp, aplicar);
      celda.appendChild(inp);
      return { pasa: function (t) {
        var v = (inp.value || "").replace(/^\s+|\s+$/g, "");
        if (!v) return true;
        return t.toLowerCase().indexOf(v.toLowerCase()) >= 0;
      } };
    }
    // Varias opciones a la vez: boton + panel de casillas. Ninguna marcada =
    // todas, que es lo que se espera de un filtro recien abierto.
    function multi(celda, lista) {
      var env = document.createElement("div"); env.className = "fm";
      var bot = document.createElement("button");
      bot.type = "button"; bot.className = "fmb";
      var pan = document.createElement("div"); pan.className = "fmp";
      paneles.push(pan);
      var cab = document.createElement("div"); cab.className = "fmt";
      var aT = document.createElement("a"); aT.appendChild(document.createTextNode("todas"));
      var aN = document.createElement("a"); aN.appendChild(document.createTextNode("ninguna"));
      cab.appendChild(aT); cab.appendChild(aN); pan.appendChild(cab);
      var cajas = [];
      for (var v = 0; v < lista.length; v++) { cajas.push(anadir(lista[v])); }
      function anadir(valor) {
        var lab = document.createElement("label");
        var ch = document.createElement("input");
        ch.type = "checkbox"; ch.value = valor;
        lab.appendChild(ch);
        lab.appendChild(document.createTextNode(" " + valor));
        pan.appendChild(lab);
        enganchar(ch, refrescar);
        return ch;
      }
      function marcarTodas(v) {
        return function (e) {
          for (var i = 0; i < cajas.length; i++) { cajas[i].checked = v; }
          refrescar(); parar(e);
        };
      }
      if (aT.addEventListener) { aT.addEventListener("click", marcarTodas(true), false); aN.addEventListener("click", marcarTodas(false), false); }
      else if (aT.attachEvent) { aT.attachEvent("onclick", marcarTodas(true)); aN.attachEvent("onclick", marcarTodas(false)); }
      function rotulo(txt) {
        while (bot.firstChild) { bot.removeChild(bot.firstChild); }
        bot.appendChild(document.createTextNode(txt));
      }
      function refrescar() {
        var n = 0, ultimo = "";
        for (var i = 0; i < cajas.length; i++) { if (cajas[i].checked) { n++; ultimo = cajas[i].value; } }
        rotulo(n === 0 ? "(todas)" : (n === 1 ? ultimo : (n + " opciones")));
        bot.className = n === 0 ? "fmb" : "fmb act";
        aplicar();
      }
      function alternar(e) {
        var abierto = (pan.style.display === "block");
        cerrarPaneles();
        pan.style.display = abierto ? "none" : "block";
        parar(e);
      }
      if (bot.addEventListener) { bot.addEventListener("click", alternar, false); pan.addEventListener("click", parar, false); }
      else if (bot.attachEvent) { bot.attachEvent("onclick", alternar); pan.attachEvent("onclick", parar); }
      env.appendChild(bot); env.appendChild(pan); celda.appendChild(env);
      rotulo("(todas)");
      return { pasa: function (t) {
        var alguna = false;
        for (var i = 0; i < cajas.length; i++) {
          if (!cajas[i].checked) continue;
          alguna = true;
          if (cajas[i].value === t) return true;
        }
        return !alguna;
      } };
    }
    function aplicar() {
      var n = 0;
      for (var f = 0; f < filas.length; f++) {
        var ok = true;
        for (var c = 0; c < filtros.length && ok; c++) { ok = filtros[c].pasa(texto(filas[f].cells[c])); }
        filas[f].style.display = ok ? "" : "none";
        if (ok) n++;
      }
      if (visor) visor.innerHTML = (n === filas.length) ? "" : ("- filtro: " + n + " de " + filas.length + " visibles");
    }
    var dir = {};
    for (var h = 0; h < cabecera.cells.length; h++) { engancharOrden(cabecera.cells[h], h); }
    function engancharOrden(th, c) {
      function ordenar() {
        dir[c] = (dir[c] === 1) ? -1 : 1;
        var d = dir[c];
        filas.sort(function(a, b) {
          var x = texto(a.cells[c]), y = texto(b.cells[c]);
          var nx = parseFloat(x.replace(",", ".")), ny = parseFloat(y.replace(",", "."));
          if (!isNaN(nx) && !isNaN(ny) && /^[-+0-9.,]+$/.test(x) && /^[-+0-9.,]+$/.test(y)) return (nx - ny) * d;
          return (x < y ? -1 : (x > y ? 1 : 0)) * d;
        });
        for (var f = 0; f < filas.length; f++) { cuerpo.appendChild(filas[f]); }
        for (var h2 = 0; h2 < cabecera.cells.length; h2++) {
          var m = cabecera.cells[h2].getElementsByTagName("span");
          if (m.length) m[0].innerHTML = (h2 === c) ? (d > 0 ? " &#9650;" : " &#9660;") : "";
        }
      }
      if (th.addEventListener) { th.addEventListener("click", ordenar, false); }
      else if (th.attachEvent) { th.attachEvent("onclick", ordenar); }
    }
  }
})();
</script>
'@)
    [void]$sb.AppendLine('</body></html>')
    return $sb.ToString()
}

# Copia de seguridad previa (rollback) de los registros que se van a tocar:
# lee el valor actual de cada (tcu, variable) y lo guarda como CSV por TCU
# (TCU;variable;valor), restaurable con el boton "CSV por TCU...".
function Rollback-Crear([array]$pares, [hashtable]$cx) {
    $dir = Join-Path $PSScriptRoot 'backups'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $fich = Join-Path $dir ('rollback_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv')
    $lineas = @('TCU;variable;valor')
    $errs = 0
    $tcus = @($pares | ForEach-Object { [int]$_.tcu } | Sort-Object -Unique)
    $porTcu = @{}
    foreach ($p in $pares) { if (-not $porTcu.ContainsKey([int]$p.tcu)) { $porTcu[[int]$p.tcu] = @() }; $porTcu[[int]$p.tcu] += [string]$p.nombre }
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to } catch { $errs += @($seg.tcus).Count; continue }
        foreach ($tcu in $seg.tcus) {
            if ($script:Cancelar) { break }
            foreach ($nombre in ($porTcu[[int]$tcu] | Sort-Object -Unique)) {
                try {
                    $val = Leer-Decodificado $tcu $VARIABLES[$nombre]
                    $lineas += "$tcu;$nombre;$val"
                } catch { $errs++ }
            }
        }
    }
    Modbus-Cerrar
    if ($lineas.Count -le 1) { throw "no se pudo leer ningun valor actual ($errs errores)" }
    Set-Content -Path $fich -Value $lineas -Encoding UTF8
    return @{fichero=$fich; filas=($lineas.Count - 1); errores=$errs}
}

# Combina lo medido en la sesion (comisionado, auditoria, test de motor) en
# las filas de la ficha de Seguimiento PEM: una por TCU con sus tres tareas
# (OK / NOK / '' = pendiente) y observaciones. Lee $script:SegComis /
# $script:SegAud / $script:SegMotor (clave "ncu|tcu" -> @{ncu;tcu;estado;obs}).
function Seguimiento-Filas {
    $claves = @(@($script:SegComis.Keys) + @($script:SegAud.Keys) + @($script:SegMotor.Keys) | Sort-Object -Unique)
    $filas = foreach ($k in $claves) {
        $par = $k -split '\|', 2
        $obs = @()
        $cold = ''; $conf = ''; $mov = ''
        if ($script:SegComis.ContainsKey($k)) {
            $e = $script:SegComis[$k]
            $cold = $e.estado
            if ($e.estado -ne 'OK' -and $e.obs) { $obs += "comisionado: $($e.obs)" }
        }
        if ($script:SegAud.ContainsKey($k)) {
            $e = $script:SegAud[$k]
            $conf = $e.estado
            if ($e.estado -ne 'OK' -and $e.obs) { $obs += "config: $($e.obs)" }
        }
        if ($script:SegMotor.ContainsKey($k)) {
            $e = $script:SegMotor[$k]
            $mov = $e.estado
            if ($e.estado -ne 'OK' -and $e.obs) { $obs += "motor: $($e.obs)" }
        }
        [pscustomobject]@{ncu = $par[0]; tcu = [int]$par[1]; cold_commissioning = $cold
            config_tcu = $conf; prueba_movimiento = $mov; observaciones = ($obs -join ' | ')}
    }
    return @($filas | Sort-Object ncu, tcu)
}

# Plan de campana de firmware: a partir de un inventario (filas con NCU, TCU y
# FW) y una version objetivo, agrupa las TCUs pendientes por NCU y gateway y
# las expresa como tramos "desde-hasta", que es justo lo que pide el TCU
# Updater de Sunner ("Add from ... to ..."). Las TCUs sin respuesta en el
# inventario salen aparte: no se puede planificar lo que no comunica.
# SoC por debajo del cual el bootloader puede negarse a instalar. El umbral de
# verdad es el de cada TCU (42005 byte alto, soc_min_bootloader), que no se lee
# aqui; esto es el aviso conservador para no gastar la ventana en balde.
$SOC_MIN_OTA = 50

function Plan-Firmware([array]$inventario, [string]$objetivo, [hashtable]$gwsPorNcu, [array]$diag = @()) {
    $obj = "$objetivo".Trim()
    if (-not $obj) { throw 'indica la version de firmware objetivo (p. ej. v1.6.0)' }
    # SoC del ultimo diagnostico, indexado por NCU|TCU. Sin diagnostico, vacio.
    $soc = @{}
    foreach ($d in @($diag)) {
        # de una TCU que no comunica no se sabe la bateria: lo que trae la cache
        # de la NCU o son ceros o es de vete a saber cuando, y con eso se marcaba
        # "BATERIA BAJA" en equipos al 100 %
        if ("$($d.Salud)" -eq 'OFFLINE') { continue }
        $v = "$($d.SoC)".Trim() -replace '\s*%$', ''
        if ($v -eq '') { continue }
        $soc["$($d.NCU)|$($d.TCU)"] = $v
    }
    $pend = @{}; $mudas = @(); $alDia = 0; $detalle = @()
    foreach ($f in $inventario) {
        $tcu = 0
        if (-not [int]::TryParse("$($f.TCU)", [ref]$tcu)) { continue }
        $ncu = "$($f.NCU)"
        $fw = "$($f.FW)".Trim()
        if (-not $fw) { $mudas += ,@{ncu=$ncu; tcu=$tcu; nota="$($f.Nota)"}; continue }
        if ($fw -like "*$obj*") { $alDia++; continue }
        $puerto = ''
        foreach ($g in @($gwsPorNcu[$ncu])) {
            if ($tcu -ge [int]$g.ini -and $tcu -le [int]$g.fin) { $puerto = "$($g.puerto)"; break }
        }
        $k = "$ncu|$puerto"
        if (-not $pend.ContainsKey($k)) { $pend[$k] = @() }
        $pend[$k] += $tcu
        # el tramo sirve para pegarlo en el updater, pero para saber QUE equipos
        # faltan y en que version estan hace falta la lista TCU a TCU
        $sc = ''
        if ($soc.ContainsKey("$ncu|$tcu")) { $sc = $soc["$ncu|$tcu"] }
        $bajo = $false
        $nsc = 0
        if ($sc -ne '' -and [int]::TryParse($sc, [ref]$nsc)) { $bajo = ($nsc -lt $SOC_MIN_OTA) }
        $detalle += [pscustomobject]@{NCU=$ncu; TCU=$tcu; Puerto=$puerto; FW=$fw; Objetivo=$obj; SoC=$sc; SoC_bajo=$bajo}
    }
    $filas = @()
    foreach ($k in @($pend.Keys | Sort-Object { [int]("0" + ($_ -split '\|')[0]) }, { $_ })) {
        $p = $k -split '\|', 2
        foreach ($run in @(Runs-Consecutivos @($pend[$k] | Sort-Object -Unique))) {
            $filas += [pscustomobject]@{
                NCU = $p[0]; Puerto = $p[1]; Desde = [int]$run.ini; Hasta = [int]$run.fin
                TCUs = ([int]$run.fin - [int]$run.ini + 1)
            }
        }
    }
    $totalPend = 0; foreach ($k in $pend.Keys) { $totalPend += @($pend[$k]).Count }
    $detalle = @($detalle | Sort-Object { [int]("0" + "$($_.NCU)") }, { [int]$_.TCU })
    $sinSoc = @($detalle | Where-Object { "$($_.SoC)" -eq '' }).Count
    return @{tramos=$filas; pendientes=$totalPend; al_dia=$alDia; sin_respuesta=$mudas; detalle=$detalle
             con_soc_bajo=@($detalle | Where-Object { $_.SoC_bajo }).Count; sin_soc=$sinSoc}
}

# Tramos consecutivos de una lista ordenada de TCUs: @(1,2,3,5) -> (1-3),(5-5)
function Runs-Consecutivos([int[]]$tcus) {
    $runs = New-Object System.Collections.ArrayList
    $ini = $null; $prev = $null
    foreach ($t in $tcus) {
        if ($null -eq $ini) { $ini = $t; $prev = $t; continue }
        if ($t -eq $prev + 1) { $prev = $t; continue }
        [void]$runs.Add(@{ini=$ini; fin=$prev}); $ini = $t; $prev = $t
    }
    if ($null -ne $ini) { [void]$runs.Add(@{ini=$ini; fin=$prev}) }
    return $runs
}

# El camino de vuelta: de una lista de @{ncu;tcu} al texto del cuadro TCUs.
# "10,22,30-40" si son todas de la misma NCU, y "12/10,15/5-12" si no. Con esto
# la auditoria puede mandar a Escribir las TCUs EXACTAS que fallaron, que antes
# habia que sacar por un CSV porque un rango se llevaba por delante las buenas
# de en medio. Pura.
function Sel-Texto($equipos) {
    $porNcu = @{}; $orden = @()
    foreach ($e in @($equipos)) {
        $k = "$($e.ncu)"
        if (-not $porNcu.ContainsKey($k)) { $porNcu[$k] = @(); $orden += $k }
        $porNcu[$k] += [int]$e.tcu
    }
    if ($orden.Count -eq 0) { return '' }
    $varias = ($orden.Count -gt 1)
    $partes = @()
    foreach ($k in @($orden | Sort-Object { [int]("0" + "$_") })) {
        $pre = $(if ($varias -and $k -ne '') { "$k/" } else { '' })
        foreach ($r in @(Runs-Consecutivos @($porNcu[$k] | Sort-Object -Unique))) {
            $partes += $pre + $(if ($r.ini -eq $r.fin) { "$($r.ini)" } else { "$($r.ini)-$($r.fin)" })
        }
    }
    return ($partes -join ',')
}

# Horas en algo que se lee de un vistazo: minutos si es poco, y los dias de 8 h
# si es tanto que ya no cabe en una jornada. Pura.
function Horas-Texto([double]$h) {
    if ($h -lt 1) { return ("{0:0} min" -f ($h * 60)) }
    $t = ("{0:0.#} h" -f $h) -replace '\.', ','
    if ($h -ge 8) { $t += (" ({0:0.#} dias de 8 h)" -f ($h / 8.0)) -replace '\.', ',' }
    return $t
}

# El plan de campana: una VENTANA del updater por NCU+gateway, con los rangos
# que hay que pegarle y lo que va a tardar.
#
# El updater admite varias ventanas abiertas a la vez, una por NCU+gateway, asi
# que la campana no dura la suma: dura lo que tarde la ventana mas cargada. Lo
# que faltaba era decirlo asi -"abre estas N ventanas, en cada una pega esto y
# tarda esto, y el total es este"- en vez de soltar los tramos sueltos.
#
# Van ordenadas de mas a menos carga: la primera es la que marca el reloj, y es
# la que hay que arrancar antes. Pura: se prueba sin planta.
function Plan-Ventanas($tramos, $ips = $null, [int]$minTcu = 20) {
    $por = @{}; $orden = @()
    foreach ($t in @($tramos)) {
        $k = "$($t.NCU)|$($t.Puerto)"
        if (-not $por.ContainsKey($k)) { $por[$k] = @(); $orden += $k }
        $por[$k] += ,$t
    }
    $vs = @()
    foreach ($k in $orden) {
        $ts = @($por[$k] | Sort-Object { [int]$_.Desde })
        $n = 0; foreach ($t in $ts) { $n += [int]$t.TCUs }
        $ip = ''
        if ($null -ne $ips -and $ips["$($ts[0].NCU)"]) { $ip = "$($ips["$($ts[0].NCU)"])" }
        $vs += ,[pscustomobject]@{
            Orden = 0; NCU = "$($ts[0].NCU)"; Puerto = "$($ts[0].Puerto)"; IP = $ip
            # sin redondear: redondear aqui hacia que la ventana dijera "42 min"
            # y el total "40 min" para las mismas dos TCUs
            Tramos = $ts; TCUs = $n; Horas = (($n * $minTcu) / 60.0)
            Rangos = (@($ts | ForEach-Object { $(if ([int]$_.Desde -eq [int]$_.Hasta) { "$($_.Desde)" } else { "$($_.Desde)-$($_.Hasta)" }) }) -join ' + ')
        }
    }
    $vs = @($vs | Sort-Object -Property @{Expression={[int]$_.TCUs}; Descending=$true},
                                        @{Expression={[int]("0" + "$($_.NCU)")}},
                                        @{Expression={"$($_.Puerto)"}})
    for ($i = 0; $i -lt $vs.Count; $i++) { $vs[$i].Orden = $i + 1 }
    return $vs
}

# El mismo plan en texto, para la consola y para leerlo mientras se teclea en el
# updater. Pura.
function Plan-Texto($ventanas, [int]$minTcu = 20) {
    $vs = @($ventanas)
    if ($vs.Count -eq 0) { return @() }
    $tot = 0; $max = 0.0
    foreach ($v in $vs) { $tot += [int]$v.TCUs; if ([double]$v.Horas -gt $max) { $max = [double]$v.Horas } }
    $l = @("PLAN: abre $($vs.Count) $(if ($vs.Count -eq 1) { 'ventana' } else { 'ventanas' }) del updater a la vez. $tot TCUs pendientes.")
    foreach ($v in $vs) {
        $l += ("  Ventana {0}: NCU{1}  {2}  puerto {3}   ->  Add from...to: {4}   ({5} TCUs, ~{6})" -f `
               $v.Orden, $v.NCU, $(if ($v.IP) { $v.IP } else { '(ip)' }), $v.Puerto, $v.Rangos, $v.TCUs, (Horas-Texto ([double]$v.Horas)))
    }
    # con una sola ventana no hay nada que comparar: el total es lo que tarda
    if ($vs.Count -eq 1) { $l += ("TOTAL: ~{0} en esa unica ventana." -f (Horas-Texto $max)) }
    else {
        $l += ("TOTAL: ~{0} con las {1} ventanas abiertas a la vez, que lo marca la ventana 1 (NCU{2}/GW{3}). Una detras de otra serian ~{4}." -f `
               (Horas-Texto $max), $vs.Count, $vs[0].NCU, $vs[0].Puerto, (Horas-Texto (($tot * $minTcu) / 60.0)))
    }
    return $l
}

# TEST COMM: la prueba mas rapida posible de "quien habla y quien no". No lee
# el bloque compacto de cada TCU (22 regs), solo los lastComm que la NCU
# cachea: 2 regs por TCU y hasta 50 TCUs por lectura, mas los 20 regs de las
# HSUs. Una NCU de 75 TCUs se resuelve en ~4 lecturas en vez de ~17.
# Requiere conexion abierta al puerto 502. Devuelve @{reloj; tcus; hsus}.
function Ncu-Comm([int[]]$tcus) {
    $wclk = FC03-Leer $UNIT_NCU (Dir-Trama 30104) 2
    $reloj = ([long]$wclk[1] -shl 16) -bor [long]$wclk[0]
    $edadDe = {
        param($lc)
        if ($reloj -gt 1000000000 -and $lc -gt 1000000000) { return [int]($reloj - $lc) }
        return -1
    }
    $res = @{}
    foreach ($run in @(Runs-Consecutivos $tcus)) {
        $t0 = [int]$run.ini
        while ($t0 -le [int]$run.fin) {
            $n = [math]::Min(50, [int]$run.fin - $t0 + 1)
            $w = FC03-Leer $UNIT_NCU (Dir-Trama (29500 + ($t0 - 1) * 2)) (2 * $n)
            for ($k = 0; $k -lt $n; $k++) {
                $lc = ([long]$w[2*$k + 1] -shl 16) -bor [long]$w[2*$k]
                $edad = & $edadDe $lc
                $res[$t0 + $k] = @{lastcomm=$lc; edad=$edad; comunica=(($lc -ne 0) -and ($edad -ge 0) -and ($edad -le 300))}
            }
            $t0 += $n
        }
    }
    $hsus = @()
    try {
        $wh = FC03-Leer $UNIT_NCU (Dir-Trama 29440) 20
        for ($h = 0; $h -lt 10; $h++) {
            $lc = ([long]$wh[2*$h + 1] -shl 16) -bor [long]$wh[2*$h]
            if ($lc -eq 0) { continue }        # ranura sin HSU declarada
            $edad = & $edadDe $lc
            $hsus += ,@{hsu=("HSU{0}" -f ($h + 1)); lastcomm=$lc; edad=$edad; comunica=(($edad -ge 0) -and ($edad -le 300))}
        }
    } catch {}
    return @{reloj=$reloj; tcus=$res; hsus=$hsus}
}

# Diagnostico VIA NCU: lee el bloque compacto (30500+, 22 regs/TCU) y los
# lastComm (29500+) que la NCU cachea de sus TCUs - lecturas TCP locales, sin
# pasar por Zigbee. Mismo criterio de salud que el SCADA; OFFLINE = lastComm
# a 0 o con mas de 300 s de antiguedad respecto al reloj de la NCU (30104).
# Requiere conexion abierta al puerto 502. Devuelve hashtable tcu -> objeto.
function Ncu-DiagCompat([int[]]$tcus) {
    $wclk = FC03-Leer $UNIT_NCU (Dir-Trama 30104) 2
    $reloj = ([long]$wclk[1] -shl 16) -bor [long]$wclk[0]
    $res = @{}
    $lastc = @{}
    foreach ($run in @(Runs-Consecutivos $tcus)) {
        # lastComm: 2 regs por TCU, hasta 50 TCUs por lectura
        $t0 = [int]$run.ini
        while ($t0 -le [int]$run.fin) {
            $n = [math]::Min(50, [int]$run.fin - $t0 + 1)
            $w = FC03-Leer $UNIT_NCU (Dir-Trama (29500 + ($t0 - 1) * 2)) (2 * $n)
            for ($k = 0; $k -lt $n; $k++) {
                $lastc[$t0 + $k] = ([long]$w[2*$k + 1] -shl 16) -bor [long]$w[2*$k]
            }
            $t0 += $n
        }
        # datos: 22 regs por TCU, hasta 5 TCUs por lectura (110 regs)
        $t0 = [int]$run.ini
        while ($t0 -le [int]$run.fin) {
            $n = [math]::Min(5, [int]$run.fin - $t0 + 1)
            $w = FC03-Leer $UNIT_NCU (Dir-Trama (30500 + ($t0 - 1) * 22)) (22 * $n)
            for ($k = 0; $k -lt $n; $k++) {
                $tcu = $t0 + $k; $b = 22 * $k
                $msr = $w[$b+1]; $al1 = $w[$b+2]; $al2 = $w[$b+3]; $fl = $w[$b+4]
                $tilt = (Palabras-A-F32 @($w[$b+6], $w[$b+7])) * 180.0 / [math]::PI
                $targ = (Palabras-A-F32 @($w[$b+10], $w[$b+11])) * 180.0 / [math]::PI
                $ibat = $w[$b+18]; if ($ibat -gt 32767) { $ibat -= 65536 }
                # ya vienen en el mismo bloque, sin una lectura de mas: tension
                # de panel (5), corriente de entrada (12, con signo) y las dos
                # de motor (8 y 9). Con ellas se distingue "no le entra nada"
                # de "la bateria esta baja".
                $ient = $w[$b+12]; if ($ient -gt 32767) { $ient -= 65536 }
                $dif = [math]::Abs($tilt - $targ)
                $edad = -1
                if ($reloj -gt 1000000000 -and $lastc[$tcu] -gt 1000000000) { $edad = $reloj - $lastc[$tcu] }
                $alarmas = @(Bits-Texto $al1 $BITS_AL1_NCU) + @(Bits-Texto $al2 $BITS_AL2_NCU)
                $notas = @()
                if ($dif -gt 5) { $notas += ("dif {0:0.0} deg" -f $dif) }
                if ((($fl -shr 15) -band 1) -eq 0) { $notas += 'system OK = 0' }
                if ((($fl -shr 11) -band 1) -eq 1) { $notas += 'alarma motor enclavada' }
                # la edad va en su columna; aqui solo si es tanta que el dato
                # ya no vale para decidir nada
                if ($edad -gt 90) { $notas += "dato viejo" }
                $salud = 'OK'
                if ($lastc[$tcu] -eq 0 -or ($edad -ge 0 -and $edad -gt 300)) {
                    $salud = 'OFFLINE'
                    $notas = @($(if ($lastc[$tcu] -eq 0) { 'la NCU nunca ha leido este TCU' } else { "sin datos en la NCU desde hace $edad s" }))
                }
                elseif ((($al1 -band $CRIT_AL1) -ne 0) -or (($al2 -band $CRIT_AL2_NCU) -ne 0)) { $salud = 'ALARMA' }
                elseif ($alarmas.Count -gt 0 -or $notas.Count -gt 0) { $salud = 'AVISO' }
                # Si la NCU NUNCA ha hablado con este TCU, su hueco de la cache
                # esta a ceros. Publicar esos ceros como medidas es inventarse
                # datos: salia "SoC 0 % - BATERIA BAJA" en el plan de firmware de
                # equipos cuya bateria esta al 100 %, y "OFF" como modo. Cuando
                # SI la ha leido y el dato es viejo, los valores son los ultimos
                # de verdad y se quedan: la columna Edad s dice de cuando son.
                $vacio = ($lastc[$tcu] -eq 0)
                $res[$tcu] = [pscustomobject]@{
                    TCU = $tcu; Salud = $salud
                    Modo = $(if ($vacio) { '-' } else { Modo-De $msr })
                    Tilt = $(if ($vacio) { '' } else { [math]::Round($tilt, 1) })
                    Objetivo = $(if ($vacio) { '' } else { [math]::Round($targ, 1) })
                    Dif = $(if ($vacio) { '' } else { [math]::Round($dif, 1) })
                    # Cuantos segundos hace que la NCU hablo con esta TCU. En
                    # modo via NCU no se lee al seguidor: se lee lo ultimo que
                    # la NCU le oyo, y cada uno tiene su propio retardo. Sin
                    # esto no hay forma de saber de cuando es lo que se ve.
                    Edad_s = $(if ($edad -ge 0) { $edad } else { '' })
                    # bit 7 del MSR: 1 = de dia. De noche todos los paneles
                    # estan a 0 V y sin esto la auditoria marcaba media planta.
                    Dia = $(if ($vacio) { '' } else { (($msr -shr 7) -band 1) })
                    SoC = $(if ($vacio) { '' } else { ($w[$b+13] -band 0xFF) })
                    SoH = $(if ($vacio) { '' } else { ($w[$b+21] -band 0xFF) })
                    Vbat_mV = $(if ($vacio) { '' } else { $w[$b+16] }); Ibat_mA = $(if ($vacio) { '' } else { $ibat })
                    Vpanel_mV = $(if ($vacio) { '' } else { $w[$b+5] }); Ientrada_mA = $(if ($vacio) { '' } else { $ient })
                    Imotor_mA = $(if ($vacio) { '' } else { $w[$b+8] }); ImotorPico_mA = $(if ($vacio) { '' } else { $w[$b+9] })
                    Tbat_C = $(if ($vacio) { '' } else { [math]::Round(($w[$b+20] / 10.0) - 273.15, 1) })
                    Tpcb_C = $(if ($vacio) { '' } else { [math]::Round(($w[$b+19] / 10.0) - 273.15, 1) })
                    Alarmas = (($alarmas + $notas) -join '; ')
                    main_status = ("0x{0:X4}" -f $msr); alarmas_1 = ("0x{0:X4}" -f $al1); alarmas_2 = ("0x{0:X4}" -f $al2)
                    alarmas_3 = ''; alarmas_4 = ''; system_status = ("0x{0:X4}" -f $fl)
                }
            }
            $t0 += $n
        }
    }
    return $res
}

# HSUs cacheadas por la NCU (bloque 30200, 10 regs/HSU, max 10; lastComm en
# 29440). Requiere conexion abierta al puerto 502. Devuelve lista de objetos
# solo para las HSU que existen (product o lastComm distintos de 0).
$NCU_HSU_AL1 = @{
  0='fallo sensor viento'; 1='fallo sensor nieve'; 6='ALARMA NIEVE'; 7='ALARMA INUNDACION'
  9='ALARMA VIENTO'; 15='fallo com. HSU'
}
# Nota del reloj de una NCU: vacia si va en hora, y con el desvio si no. Pura.
function Reloj-Nota($ns) {
    if (-not $ns -or "$($ns.fecha)" -eq '') { return @() }
    if ($null -eq $ns.desvio) { return @() }
    if ($ns.desvio -le $RELOJ_TOL_S) { return @() }
    $d = [double]$ns.desvio
    $txt = $(if ($d -lt 3600) { "{0:0} min" -f ($d / 60) } elseif ($d -lt 172800) { "{0:0.#} h" -f ($d / 3600) } else { "{0:0} dias" -f ($d / 86400) })
    return @("RELOJ NCU DESVIADO $txt (marca $($ns.fecha))")
}

# Offsets 21..31 del bloque de 50 por TCU: 11 registros por lectura, una TCU
# por peticion. Solo se usa cuando se pide, no en cada diagnostico.
function Ncu-CargaCompat([int[]]$tcus) {
    $res = @{}
    foreach ($tcu in $tcus) {
        $w = $null
        try { $w = FC03-Leer $UNIT_NCU (Dir-Trama (50000 + ($tcu - 1) * 50 + 21)) 11 } catch { continue }
        if ($null -eq $w -or @($w).Count -lt 11) { continue }
        $ip = $w[1]; if ($ip -gt 32767) { $ip -= 65536 }
        $ib = $w[3]; if ($ib -gt 32767) { $ib -= 65536 }
        $res[$tcu] = [pscustomobject]@{
            Vpanel_mV = $w[0]; Ipanel_mA = $ip
            Vbat_mV = $w[2]; Ibat_mA = $ib
            SoC = ($w[4] -band 0xFF); SoH = (($w[4] -shr 8) -band 0xFF)
            EstadoCarga = $w[8]; ChargerState = $w[9]; AlarmasCarga = $w[10]
            Carga = (Carga-Texto ([int]$w[8]) ([int]$w[10]))
        }
    }
    return $res
}

function Ncu-HsuCompat {
    $wclk = FC03-Leer $UNIT_NCU (Dir-Trama 30104) 2
    $reloj = ([long]$wclk[1] -shl 16) -bor [long]$wclk[0]
    $wlc = FC03-Leer $UNIT_NCU (Dir-Trama 29440) 20
    $wd  = FC03-Leer $UNIT_NCU (Dir-Trama 30200) 100
    $lista = @()
    for ($h = 0; $h -lt 10; $h++) {
        $b = $h * 10
        $lastc = ([long]$wlc[2*$h + 1] -shl 16) -bor [long]$wlc[2*$h]
        if ($wd[$b] -eq 0 -and $lastc -eq 0) { continue }
        $msr = $wd[$b+1]; $al1 = $wd[$b+2]
        $nivel = $msr -band 0x7
        $viento = Palabras-A-F32 @($wd[$b+3], $wd[$b+4])
        $dir    = Palabras-A-F32 @($wd[$b+5], $wd[$b+6])
        $nieve  = Palabras-A-F32 @($wd[$b+7], $wd[$b+8])
        $edad = -1
        if ($reloj -gt 1000000000 -and $lastc -gt 1000000000) { $edad = $reloj - $lastc }
        $alarmas = @(Bits-Texto $al1 $NCU_HSU_AL1)
        $salud = 'OK'
        if ($lastc -eq 0 -or ($edad -ge 0 -and $edad -gt 300)) { $salud = 'OFFLINE' }
        elseif ($al1 -band 0x8003) { $salud = 'ALARMA' }                      # sensores caidos o com rota
        elseif (($al1 -band 0x02C0) -or $nivel -gt 0) { $salud = 'AVISO' }    # viento/nieve/inundacion activos
        $texto = ("viento {0:0.#} m/s (nivel {1}), dir {2:0} deg; nieve {3:0.###} m" -f $viento, $nivel, $dir, $nieve)
        if ($alarmas.Count) { $texto = ($alarmas -join '; ') + ' | ' + $texto }
        if ($edad -gt 90) { $texto += " | datos de hace $edad s" }
        if ($salud -eq 'OFFLINE') { $texto = $(if ($lastc -eq 0) { 'la NCU nunca ha leido esta HSU' } else { "sin datos en la NCU desde hace $edad s" }) }
        $lista += [pscustomobject]@{
            NCU=''; TCU=("HSU{0}" -f ($h + 1)); Salud=$salud; Modo='-'
            Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''; Vbat_mV=''; Ibat_mA=''; Vpanel_mV=''; Ientrada_mA=''; Imotor_mA=''; ImotorPico_mA=''; Dia=''; Tbat_C=''; Tpcb_C=''
            Alarmas=$texto
            main_status=("0x{0:X4}" -f $msr); alarmas_1=("0x{0:X4}" -f $al1); alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''
        }
    }
    return $lista
}

# Salud de la propia NCU (30100-30105, unit 1 en el puerto 502). Requiere
# conexion ya abierta. Devuelve @{salud; alarmas; fecha; din; principal}.
function Ncu-Salud {
    $w = FC03-Leer $UNIT_NCU (Dir-Trama 30100) 6
    $din = $w[0]; $principal = $w[1]
    $alarmas = @(Bits-Texto $din $NCU_DIN) + @(Bits-Texto $principal $NCU_MAIN)
    for ($b = 3; $b -le 12; $b++) {
        if ($din -band (1 -shl $b)) { $alarmas += "interruptor limpieza $($b-2) activo" }
    }
    $salud = 'OK'
    if (($principal -band 0x30) -or ($din -band 0x2000)) { $salud = 'ALARMA' }       # GW1/GW2 caidos o seta
    elseif (($din -band 0x3) -or ($principal -band 0x1)) { $salud = 'AVISO' }        # UPS/bateria
    $fecha = ''; $desvio = $null
    try {
        $epoch = ([long]$w[5] -shl 16) -bor [long]$w[4]
        if ($epoch -gt 1000000000) {
            $utc = [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime
            $fecha = $utc.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
            $desvio = [Math]::Abs(((Get-Date).ToUniversalTime() - $utc).TotalSeconds)
        }
    } catch {}
    return @{salud=$salud; alarmas=$alarmas; fecha=$fecha; desvio=$desvio; din=$din; principal=$principal}
}

# Direccion: se envia el numero del PDF tal cual (asi funciona modbus-utils).
# Si alguna planta necesitara offset Modicon (-1 o -40001), cambiar aqui:
function Dir-Trama([int]$addrDoc) { return $addrDoc }

# ---------------------------------------------------------------------------
#  Cliente Modbus TCP
# ---------------------------------------------------------------------------
$script:Tcp = $null; $script:Stream = $null; $script:Tid = 0
$script:ConIp = ''; $script:ConPuerto = 0; $script:ConTimeout = 8000
# El socket queda "sucio" cuando una peticion no ha terminado limpia: la NCU
# puede soltar despues la respuesta tardia del TCU que no contesto a tiempo.
$script:Sucio = $false
$script:Desfases = 0        # respuestas atrasadas descartadas (se avisa en consola)
$script:AvisosDesfase = 0

function Modbus-Conectar([string]$ip, [int]$puerto, [int]$timeoutMs) {
    Modbus-Cerrar
    $c = New-Object System.Net.Sockets.TcpClient
    $ar = $c.BeginConnect($ip, $puerto, $null, $null)
    # Distinguir "no contesta" de "rechaza" ahorra media hora de diagnostico: lo
    # primero es un equipo apagado o un puerto filtrado; lo segundo es un equipo
    # vivo que no tiene nada escuchando ahi (o que ya tiene la conexion cogida).
    if (-not $ar.AsyncWaitHandle.WaitOne(5000)) {
        $c.Close(); throw "Sin conexion TCP a ${ip}:${puerto}: no contesta en 5 s (equipo apagado, IP mal o puerto filtrado)"
    }
    try { $c.EndConnect($ar) }
    catch [System.Net.Sockets.SocketException] {
        $c.Close()
        if ($_.Exception.SocketErrorCode -eq 'ConnectionRefused') {
            throw "Sin conexion TCP a ${ip}:${puerto}: conexion RECHAZADA. El equipo esta vivo pero no tiene nada escuchando en ese puerto, o ya tiene la unica conexion cogida por otro programa (el updater)"
        }
        throw "Sin conexion TCP a ${ip}:${puerto}: $($_.Exception.Message)"
    }
    $c.NoDelay = $true
    $script:Tcp = $c
    $script:Stream = $c.GetStream()
    $script:Stream.ReadTimeout = $timeoutMs
    $script:ConIp = $ip; $script:ConPuerto = $puerto; $script:ConTimeout = $timeoutMs
    $script:Sucio = $false      # socket nuevo: no puede arrastrar respuestas viejas
}

function Modbus-Reconectar {
    if ($script:ConIp) { try { Modbus-Conectar $script:ConIp $script:ConPuerto $script:ConTimeout } catch {} }
}

function Modbus-Cerrar {
    if ($script:Stream) { try { $script:Stream.Close() } catch {} ; $script:Stream = $null }
    if ($script:Tcp)    { try { $script:Tcp.Close() }    catch {} ; $script:Tcp = $null }
}

function Leer-Exacto([int]$n) {
    $buf = New-Object byte[] $n
    $leido = 0
    while ($leido -lt $n) {
        $k = $script:Stream.Read($buf, $leido, $n - $leido)
        if ($k -le 0) { throw "Conexion cerrada por la NCU" }
        $leido += $k
    }
    return $buf
}

$EXC_MODBUS = @{
  1='IllegalFunction'; 2='IllegalDataAddress'; 3='IllegalDataValue'; 4='SlaveDeviceFailure'
  5='Acknowledge'; 6='SlaveDeviceBusy'; 8='MemoryParityError'
  10='GatewayPathUnavailable'; 11='GatewayTargetNoResponse'
}

# Descarta lo que hubiera esperando en el socket antes de pedir nada: si hay
# bytes, son de una peticion anterior y desplazarian todas las respuestas.
function Modbus-Vaciar {
    try {
        while ($script:Stream -and $script:Stream.DataAvailable) {
            $b = New-Object byte[] 2048
            if ($script:Stream.Read($b, 0, 2048) -le 0) { break }
            $script:Desfases++
        }
    } catch {}
}

function Modbus-Transaccion([byte]$unit, [byte[]]$pdu) {
    if (-not $script:Stream) { throw "Sin conexion" }
    # Resincronizacion tras un fallo. La NCU sella la respuesta tardia de un TCU
    # con el ID de transaccion de la peticion que tenga en curso, asi que
    # comprobar el ID no la detecta: se colaria como respuesta de la siguiente
    # variable y a partir de ahi toda la fila saldria corrida una columna
    # (east_pitch mostrando los radianes de max_tilt, etc.). La unica forma
    # segura de volver a cuadrar peticion y respuesta es un socket limpio.
    if ($script:Sucio) {
        $script:Sucio = $false
        Modbus-Reconectar
        if (-not $script:Stream) { throw "Sin conexion" }
    }
    $antes = $script:Desfases
    Modbus-Vaciar
    if ($script:Desfases -gt $antes -and $script:AvisosDesfase -lt 5) {
        $script:AvisosDesfase++
        if (Get-Command Con -ErrorAction SilentlyContinue) {
            Con 'AVISO: la NCU habia dejado una respuesta atrasada en la conexion; descartada y resincronizado.' ([System.Drawing.Color]::Orange)
        }
    }
    $script:Tid = ($script:Tid + 1) % 65535
    if ($script:Tid -eq 0) { $script:Tid = 1 }
    $len = $pdu.Length + 1
    $adu = New-Object byte[] (7 + $pdu.Length)
    $adu[0] = [byte](($script:Tid -shr 8) -band 0xFF); $adu[1] = [byte]($script:Tid -band 0xFF)
    $adu[2] = 0; $adu[3] = 0
    $adu[4] = [byte](($len -shr 8) -band 0xFF); $adu[5] = [byte]($len -band 0xFF)
    $adu[6] = $unit
    [Array]::Copy($pdu, 0, $adu, 7, $pdu.Length)

    # Del equipo = ha contestado el propio TCU/HSU, asi que no quedan tramas
    # tardias en camino y el socket sigue siendo de fiar. Las de gateway
    # (0x0A/0x0B) las da la NCU porque el TCU no ha llegado a tiempo: puede
    # contestar despues, y esa trama hay que darla por perdida reconectando.
    $delEquipo = $false
    try {
        $script:Stream.Write($adu, 0, $adu.Length)
        while ($true) {
            $cab = Leer-Exacto 7
            $rtid = ([int]$cab[0] -shl 8) -bor [int]$cab[1]
            $rlen = ([int]$cab[4] -shl 8) -bor [int]$cab[5]
            $cuerpo = Leer-Exacto ($rlen - 1)
            if ($rtid -eq $script:Tid) {
                if ($cuerpo[0] -band 0x80) {
                    $exc = [int]$cuerpo[1]
                    $nom = $EXC_MODBUS[$exc]
                    if (-not $nom) { $nom = 'Excepcion' }
                    $delEquipo = ($exc -ne 10 -and $exc -ne 11)
                    throw ("{0} (0x{1:X2})" -f $nom, $exc)
                }
                if ([int]$cuerpo[0] -ne [int]$pdu[0]) {
                    throw ("Respuesta descolocada: se pidio FC{0} y llego FC{1}" -f [int]$pdu[0], [int]$cuerpo[0])
                }
                return $cuerpo
            }
        }
    } catch {
        if (-not $delEquipo) { $script:Sucio = $true }
        throw
    }
}

# Un error de excepcion Modbus no invalida el socket; cualquier otro (timeout,
# socket roto) si, y conviene reconectar antes de reintentar.
function Es-ExcepcionModbus([string]$msg) {
    return ($msg -match 'IllegalFunction|IllegalDataAddress|IllegalDataValue|SlaveDeviceFailure|Acknowledge|SlaveDeviceBusy|MemoryParityError|GatewayPathUnavailable|GatewayTargetNoResponse|Excepcion \(0x')
}

function FC03-Leer([byte]$unit, [int]$addr, [int]$n) {
    $pdu = [byte[]](3, (($addr -shr 8) -band 0xFF), ($addr -band 0xFF), (($n -shr 8) -band 0xFF), ($n -band 0xFF))
    $r = Modbus-Transaccion $unit $pdu
    # una respuesta de otra peticion casi siempre trae otro numero de registros
    if ([int]$r[1] -ne (2 * $n)) {
        $script:Sucio = $true
        throw ("Respuesta descolocada: se pidieron {0} registros y llegaron {1}" -f $n, ([int]$r[1] / 2))
    }
    $vals = New-Object int[] $n
    for ($i = 0; $i -lt $n; $i++) { $vals[$i] = (([int]$r[2 + 2*$i] -shl 8) -bor [int]$r[3 + 2*$i]) }
    return ,$vals
}

function FC16-Escribir([byte]$unit, [int]$addr, [int[]]$palabras) {
    $n = $palabras.Count
    $pdu = New-Object byte[] (6 + 2*$n)
    $pdu[0] = 16
    $pdu[1] = ($addr -shr 8) -band 0xFF; $pdu[2] = $addr -band 0xFF
    $pdu[3] = 0; $pdu[4] = $n; $pdu[5] = 2*$n
    for ($i = 0; $i -lt $n; $i++) {
        $pdu[6 + 2*$i] = ($palabras[$i] -shr 8) -band 0xFF
        $pdu[7 + 2*$i] = $palabras[$i] -band 0xFF
    }
    [void](Modbus-Transaccion $unit $pdu)
}

function FC22-Mascara([byte]$unit, [int]$addr, [int]$and, [int]$or) {
    $pdu = [byte[]](22,
        (($addr -shr 8) -band 0xFF), ($addr -band 0xFF),
        (($and  -shr 8) -band 0xFF), ($and  -band 0xFF),
        (($or   -shr 8) -band 0xFF), ($or   -band 0xFF))
    [void](Modbus-Transaccion $unit $pdu)
}

# ---------------------------------------------------------------------------
#  Conversion de valores segun tipo
# ---------------------------------------------------------------------------
$INV = [Globalization.CultureInfo]::InvariantCulture

function Normalizar-Decimal([string]$t) {
    $t = $t.Trim()
    # El punto solo se trata como separador de miles si tambien hay coma
    # decimal (1.234,56). Un "1.234" a secas es un decimal con punto, no 1234.
    if ($t -match '^-?\d{1,3}(\.\d{3})+,\d+$') {
        return ($t -replace '\.', '') -replace ',', '.'
    }
    if ($t.Contains(',') -and -not $t.Contains('.')) {
        # coma decimal espanola: 0,9599
        return $t -replace ',', '.'
    }
    return $t
}

function Parse-RealFinito([string]$texto) {
    $d = [double]::Parse((Normalizar-Decimal $texto), $INV)
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { throw "'$texto' no es un numero finito" }
    return $d
}

function Entero-Estricto([string]$t) {
    $t = $t.Trim()
    if ($t -match '^0x[0-9A-Fa-f]+$') { return [Convert]::ToInt32($t, 16) }
    if ($t -match '^-?\d+$') { return [int]$t }
    throw "'$t' no es un entero valido (sin puntos ni comas; hex con 0x)"
}

function Val-Int([string]$texto, [string]$nombre, [int]$min, [int]$max) {
    $t = "$texto".Trim()
    if ($t -notmatch '^-?\d+$') { throw "$nombre invalido: '$texto'" }
    $v = [int]$t
    if ($v -lt $min -or $v -gt $max) { throw "$nombre fuera de rango ($min..$max)" }
    return $v
}

function F32-A-Palabras([float]$f) {
    $b = [BitConverter]::GetBytes($f)
    $lo = ([int]$b[1] -shl 8) -bor [int]$b[0]
    $hi = ([int]$b[3] -shl 8) -bor [int]$b[2]
    return @($lo, $hi)
}

function Palabras-A-F32([int[]]$w) {
    return [BitConverter]::ToSingle([BitConverter]::GetBytes(([int]$w[1] -shl 16) -bor [int]$w[0]), 0)
}

function Valor-A-Escritura([hashtable]$vdef, [string]$texto) {
    $a = Dir-Trama $vdef.addr
    switch ($vdef.tipo) {
        # u16hex es un u16 que se MUESTRA en hexadecimal (mascaras de bits);
        # a la hora de escribir admite igual "0x0A00" que "2560"
        { $_ -eq 'u16' -or $_ -eq 'u16hex' } {
            $v = Entero-Estricto $texto
            if ($v -lt 0 -or $v -gt 65535) { throw "fuera de rango U16" }
            if ($null -ne $vdef.min -and $v -lt $vdef.min) { throw "por debajo del minimo del mapa ($($vdef.min))" }
            if ($null -ne $vdef.max -and $v -gt $vdef.max) { throw "por encima del maximo del mapa ($($vdef.max))" }
            return @{modo='fc16'; addr=$a; palabras=@($v); esperado=@($v)}
        }
        's16' {
            $v = Entero-Estricto $texto
            if ($v -lt -32768 -or $v -gt 32767) { throw "fuera de rango S16" }
            if ($null -ne $vdef.min -and $v -lt $vdef.min) { throw "por debajo del minimo del mapa ($($vdef.min))" }
            if ($null -ne $vdef.max -and $v -gt $vdef.max) { throw "por encima del maximo del mapa ($($vdef.max))" }
            $w = $v -band 0xFFFF
            return @{modo='fc16'; addr=$a; palabras=@($w); esperado=@($w)}
        }
        'u32' {
            if ($texto -match '^0x') { $v = [Convert]::ToInt64($texto, 16) } else { $v = [long]$texto }
            if ($v -lt 0 -or $v -gt 4294967295) { throw "fuera de rango U32" }
            $lo = [int]($v -band 0xFFFF); $hi = [int](($v -shr 16) -band 0xFFFF)
            return @{modo='fc16'; addr=$a; palabras=@($lo, $hi); esperado=@($lo, $hi)}
        }
        'f32' {
            $f = [float](Parse-RealFinito $texto)
            if ([float]::IsInfinity($f)) { throw "fuera de rango F32" }
            $w = F32-A-Palabras $f
            return @{modo='fc16'; addr=$a; palabras=$w; esperado=$w}
        }
        'f32deg' {
            $g = Parse-RealFinito $texto
            if ([math]::Abs($g) -gt 360) { throw "$g grados no es un angulo razonable: este campo espera GRADOS" }
            $f = [float]($g * [math]::PI / 180.0)
            $w = F32-A-Palabras $f
            return @{modo='fc16'; addr=$a; palabras=$w; esperado=$w}
        }
        'u8lo' {
            $v = Entero-Estricto $texto
            if ($v -lt 0 -or $v -gt 255) { throw "fuera de rango U8" }
            if ($null -ne $vdef.min -and $v -lt $vdef.min) { throw "por debajo del minimo del mapa ($($vdef.min))" }
            if ($null -ne $vdef.max -and $v -gt $vdef.max) { throw "por encima del maximo del mapa ($($vdef.max))" }
            return @{modo='fc22'; addr=$a; and=0xFF00; or=$v; mascara=0x00FF; esperadoByte=$v}
        }
        'u8hi' {
            $v = Entero-Estricto $texto
            if ($v -lt 0 -or $v -gt 255) { throw "fuera de rango U8" }
            if ($null -ne $vdef.min -and $v -lt $vdef.min) { throw "por debajo del minimo del mapa ($($vdef.min))" }
            if ($null -ne $vdef.max -and $v -gt $vdef.max) { throw "por encima del maximo del mapa ($($vdef.max))" }
            return @{modo='fc22'; addr=$a; and=0x00FF; or=($v -shl 8); mascara=0xFF00; esperadoByte=($v -shl 8)}
        }
        'bit' {
            $v = Entero-Estricto $texto
            if ($v -ne 0 -and $v -ne 1) { throw "un bit solo admite 0 o 1" }
            $m = 1 -shl $vdef.bit
            return @{modo='fc22'; addr=$a; and=((-bnot $m) -band 0xFFFF); or=($v * $m); mascara=$m; esperadoByte=($v * $m)}
        }
        default { throw "tipo no escribible $($vdef.tipo)" }
    }
}

function BCD-Dec([int]$b) { return ((($b -shr 4) -band 0xF) * 10 + ($b -band 0xF)) }

# Filtro de nombres por subcadena, sin distinguir mayusculas y sin tratar
# [ ] * ? como comodines (los nombres llevan corchetes de unidades).
function Filtrar-Nombres([string[]]$nombres, [string]$filtro) {
    # retorno plano: los llamadores recogen con @(...); no proteger con ','
    $f = "$filtro".Trim()
    if (-not $f) { return $nombres }
    return ($nombres | Where-Object { $_.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

# Orden natural para los desplegables: ascendente por numero de registro
# (los nombres empiezan por el; el mapa interno se define por grupos).
function Nombres-Ordenados([string[]]$nombres) {
    return ($nombres | Sort-Object @{Expression={ [int](($_ -split ' ')[0]) }}, @{Expression={ $_ }})
}

# Resuelve el nombre de una variable de forma tolerante: clave exacta, o una
# unica coincidencia por subcadena ("41010" -> '41010 longitud [deg]').
function Resolver-Variable([string]$texto) {
    $t = "$texto".Trim()
    if ($VARIABLES.Contains($t)) { return $t }
    $m = @(Filtrar-Nombres @($VARIABLES.Keys) $t)
    if ($m.Count -eq 1) { return $m[0] }
    if ($m.Count -eq 0) { throw "'$t' no coincide con ninguna variable del mapa" }
    throw "'$t' es ambiguo ($($m.Count) coincidencias: $($m[0]), $($m[1])...)"
}

# Compara el valor actual de un registro con una escritura esperada (misma
# semantica que 'verificar tras escribir'). Devuelve @{ok; leidoRaw}.
function Comparar-Escritura([byte]$tcu, [hashtable]$esc) {
    if ($esc.modo -eq 'fc16') {
        $leido = FC03-Leer $tcu $esc.addr $esc.palabras.Count
        for ($k = 0; $k -lt $esc.palabras.Count; $k++) {
            if ($leido[$k] -ne $esc.esperado[$k]) {
                return @{ok=$false; leidoRaw=(($leido | ForEach-Object { '{0:X4}' -f $_ }) -join ' ')}
            }
        }
        return @{ok=$true}
    }
    $v = (FC03-Leer $tcu $esc.addr 1)[0]
    return @{ok=(($v -band $esc.mascara) -eq $esc.esperadoByte); leidoRaw=('{0:X4}' -f $v)}
}

# Parsea un CSV de escritura por TCU: cabecera TCU;variable;valor (admite ,).
# Devuelve @{jobs=@(@{tcu;nombre;texto;esc});errores=@('...')}.
# Reparte las filas de un CSV entre las NCUs de la planta. Devuelve un grupo por
# NCU con su conexion, y los avisos de las filas que se quedan fuera. Pura.
function Grupos-CsvPorNcu($jobs, [hashtable]$cx) {
    $avisos = @()
    $conNcu = @($jobs | Where-Object { "$($_.ncu)" -ne '' }).Count
    if ($conNcu -eq 0) {
        if ($cx.multi) { return @{grupos=@(); avisos=@('el CSV no lleva columna NCU y la conexion es (Planta completa): no se sabe a que NCU va cada TCU')} }
        return @{grupos=@(,@{ncu=$null; cx=$cx; jobs=@($jobs)}); avisos=@()}
    }
    if ($conNcu -ne @($jobs).Count) { return @{grupos=@(); avisos=@('el CSV mezcla filas con NCU y sin NCU')} }
    if (-not $cx.multi) { return @{grupos=@(); avisos=@('el CSV lleva columna NCU: selecciona la entrada (Planta completa) para que cada fila vaya a su NCU')} }
    $por = @{}
    foreach ($j in $jobs) { $k = [int]$j.ncu; if (-not $por.ContainsKey($k)) { $por[$k] = @() }; $por[$k] += ,$j }
    $grupos = @()
    foreach ($k in @($por.Keys | Sort-Object)) {
        $n = @($cx.multi | Where-Object { [int]$_.ncu -eq [int]$k })
        if ($n.Count -eq 0) { $avisos += "la NCU $k no esta en la planta seleccionada: $(@($por[$k]).Count) filas saltadas"; continue }
        $grupos += ,@{ncu=[int]$k; jobs=@($por[$k])
            cx=@{ip=$n[0].ip; puerto=$null; gws=$n[0].gws; multi=$null; etiqueta='auto'; to=$cx.to; reint=$cx.reint}}
    }
    return @{grupos=$grupos; avisos=$avisos}
}

function Parse-CsvPorTcu([string[]]$lineas) {
    $jobs = @(); $errores = @()
    $datos = @($lineas | Where-Object { "$_".Trim() -ne '' })
    if ($datos.Count -lt 2) { return @{jobs=@(); errores=@('CSV vacio (cabecera TCU;variable;valor + filas)')} }
    $sep = ';'
    if (-not $datos[0].Contains(';')) { $sep = ',' }
    # Cabecera NCU;TCU;variable;valor: en una planta con varias NCUs los numeros
    # de TCU se repiten, asi que sin la NCU no se sabe a que equipo se escribe.
    $conNcu = ($datos[0].Split($sep)[0].Trim().Trim('"').ToUpper() -eq 'NCU')
    $nMin = $(if ($conNcu) { 4 } else { 3 })
    $cabecera = $(if ($conNcu) { "NCU${sep}TCU${sep}variable${sep}valor" } else { "TCU${sep}variable${sep}valor" })
    for ($i = 1; $i -lt $datos.Count; $i++) {
        $c = $datos[$i].Split($sep)
        if ($c.Count -lt $nMin) { $errores += "linea $($i+1): faltan columnas ($cabecera)"; continue }
        try {
            $ncu = ''
            $k = 0
            if ($conNcu) { $ncu = "$(Val-Int $c[0] "linea $($i+1) NCU" 1 999)"; $k = 1 }
            $tcu = Val-Int $c[$k] "linea $($i+1) TCU" 1 247
            $nombre = Resolver-Variable $c[$k + 1]
            # el valor puede llevar el separador decimal: reunir el resto de columnas
            $texto = (($c | Select-Object -Skip ($k + 2)) -join $sep).Trim()
            if ($texto -eq '') { throw 'valor vacio' }
            $esc = Valor-A-Escritura $VARIABLES[$nombre] $texto
            $jobs += @{ncu=$ncu; tcu=$tcu; nombre=$nombre; texto=$texto; esc=$esc}
        } catch { $errores += "linea $($i+1): $_" }
    }
    return @{jobs=$jobs; errores=$errores}
}

function Leer-Decodificado([byte]$unit, [hashtable]$vdef) {
    $a = Dir-Trama $vdef.addr
    switch ($vdef.tipo) {
        'u16'    {
            $v = (FC03-Leer $unit $a 1)[0]
            if ($vdef.div) { return ($v / $vdef.div).ToString('0.###', $INV) }
            return "$v"
        }
        'u16hex' { return "0x{0:X4}" -f (FC03-Leer $unit $a 1)[0] }
        's16'    {
            $v = (FC03-Leer $unit $a 1)[0]; if ($v -gt 32767) { $v -= 65536 }
            if ($vdef.div) { return ($v / $vdef.div).ToString('0.###', $INV) }
            return "$v"
        }
        'u8lo'   { return "{0}" -f ((FC03-Leer $unit $a 1)[0] -band 0xFF) }
        'u8hi'   { return "{0}" -f (((FC03-Leer $unit $a 1)[0] -shr 8) -band 0xFF) }
        'bit'    { $v = (FC03-Leer $unit $a 1)[0]; if ($v -band (1 -shl $vdef.bit)) { return '1' } else { return '0' } }
        'u32'    { $w = FC03-Leer $unit $a 2; return "{0}" -f (([long]$w[1] -shl 16) -bor [long]$w[0]) }
        'u32hex' { $w = FC03-Leer $unit $a 2; return "0x{0:X8}" -f (([long]$w[1] -shl 16) -bor [long]$w[0]) }
        'f32'    {
            $w = FC03-Leer $unit $a 2
            return (Palabras-A-F32 $w).ToString("0.#####", $INV)
        }
        'f32deg' {
            $w = FC03-Leer $unit $a 2
            return ((Palabras-A-F32 $w) * 180.0 / [math]::PI).ToString("0.###", $INV)
        }
        'dt_bcd' {
            $w = FC03-Leer $unit $a 3
            $mes = BCD-Dec ($w[0] -band 0xFF); $ano = BCD-Dec (($w[0] -shr 8) -band 0xFF)
            $hor = BCD-Dec ($w[1] -band 0xFF); $dia = BCD-Dec (($w[1] -shr 8) -band 0xFF)
            $seg = BCD-Dec ($w[2] -band 0xFF); $min = BCD-Dec (($w[2] -shr 8) -band 0xFF)
            return ("20{0:00}-{1:00}-{2:00} {3:00}:{4:00}:{5:00}" -f $ano, $mes, $dia, $hor, $min, $seg)
        }
        'charger' {
            $v = (FC03-Leer $unit $a 1)[0]
            $nom = $CHARGER_STATES[[int]$v]
            if ($nom) { return "$v ($nom)" }
            return "$v"
        }
        'modo' {
            # 30001 bits 9:8 - modo de operacion del TCU
            $v = ((FC03-Leer $unit $a 1)[0] -shr 8) -band 0x3
            return @('OFF','MANUAL','AUTO','?')[$v]
        }
        default { throw "tipo desconocido $($vdef.tipo)" }
    }
}

# ---------------------------------------------------------------------------
#  Ensayos SAT (Anexo 4): analisis de los registros de 7 dias
#  Funciones puras: reciben las filas ya leidas y devuelven el veredicto. Van
#  aparte del registrador para poder probarlas, que en un ensayo contractual
#  el numero que sale de aqui es el que se firma.
# ---------------------------------------------------------------------------

# D.1.1 Precision de seguimiento. Una muestra solo cuenta si el objetivo lleva
# $estables muestras sin cambiar: asi se descartan los transitorios en los que
# el seguidor aun va de camino, y las activaciones de posicion de seguridad,
# que es justo lo que pide el anexo.
function Sat-Precision($filas, [double]$tol = 1.0, [int]$estables = 2) {
    $porTcu = @{}
    foreach ($f in $filas) {
        $k = "$($f.ncu)|$($f.tcu)"
        if (-not $porTcu.ContainsKey($k)) { $porTcu[$k] = New-Object System.Collections.ArrayList }
        [void]$porTcu[$k].Add($f)
    }
    $res = @()
    foreach ($k in @($porTcu.Keys | Sort-Object)) {
        $ms = @($porTcu[$k])
        $objPrev = $null; $seguidas = 0
        $val = 0; $dentro = 0; $peor = 0.0
        foreach ($m in $ms) {
            $o = [double]$m.obj
            if ($null -ne $objPrev -and [math]::Abs($o - $objPrev) -lt 0.05) { $seguidas++ } else { $seguidas = 0 }
            $objPrev = $o
            if ($seguidas -lt $estables) { continue }      # aun llegando: no cuenta
            $val++
            $d = [math]::Abs([double]$m.desv)
            if ($d -gt $peor) { $peor = $d }
            if ($d -le $tol) { $dentro++ }
        }
        $pct = $(if ($val -gt 0) { [math]::Round(100.0 * $dentro / $val, 2) } else { 0 })
        $p = $k -split '\|'
        $res += [pscustomobject]@{NCU=$p[0]; TCU=[int]$p[1]; Muestras=@($ms).Count; Validas=$val
            Dentro=$dentro; Fuera=($val - $dentro); Peor_deg=[math]::Round($peor,2)
            Precision_pct=$pct; Cumple=$(if ($val -gt 0 -and $dentro -eq $val) { 'SI' } else { 'NO' })}
    }
    return $res
}

# D.3.4.1 Disponibilidad de operacion: se cuenta indisponible cada registro con
# alarma de motor, bateria o comunicacion. Las meteorologicas no cuentan (lo
# dice el anexo). Umbral 99% por TCU y dia.
function Sat-DispOperacion($filas, [double]$minimo = 99.0) {
    $porEq = @{}
    foreach ($f in $filas) {
        $eq = $(if ("$($f.equipo)") { "$($f.equipo)" } else { "TCU$($f.tcu)" })
        $k = "$($f.dia)|$($f.ncu)|$eq"
        if (-not $porEq.ContainsKey($k)) { $porEq[$k] = @{n=0; mal=0} }
        $porEq[$k].n++
        if ([int]$f.al_motor -or [int]$f.al_bat -or [int]$f.al_com) { $porEq[$k].mal++ }
    }
    $res = @()
    foreach ($k in @($porEq.Keys | Sort-Object)) {
        $v = $porEq[$k]; $p = $k -split '\|'
        $pct = $(if ($v.n -gt 0) { [math]::Round(100.0 * ($v.n - $v.mal) / $v.n, 2) } else { 0 })
        $res += [pscustomobject]@{Dia=$p[0]; NCU=$p[1]; Equipo=$p[2]; Registros=$v.n
            Indisponibles=$v.mal; Disponibilidad_pct=$pct
            Cumple=$(if ($pct -ge $minimo) { 'SI' } else { 'NO' })}
    }
    return $res
}

# D.4 Disponibilidad de comunicaciones. Regla del anexo: un intento fallido
# suelto NO cuenta si el siguiente se restablece, salvo que se repita dentro de
# dos minutos; en ese caso cuentan todos los fallos.
function Sat-DispComms($fallos, $intentosPorClave, [double]$minimo = 98.5, [int]$ventana = 120, [double]$minimoRsu = 99.5) {
    $porClave = @{}
    foreach ($f in $fallos) {
        $k = "$($f.dia)|$($f.ncu)|$($f.equipo)"
        if (-not $porClave.ContainsKey($k)) { $porClave[$k] = New-Object System.Collections.ArrayList }
        [void]$porClave[$k].Add([long]$f.ts)
    }
    $res = @()
    foreach ($k in @($porClave.Keys | Sort-Object)) {
        $ts = @($porClave[$k] | Sort-Object)
        $cuenta = 0
        for ($i = 0; $i -lt $ts.Count; $i++) {
            $acompanado = $false
            if ($i -gt 0 -and ($ts[$i] - $ts[$i-1]) -le $ventana) { $acompanado = $true }
            if (-not $acompanado -and $i -lt ($ts.Count - 1) -and ($ts[$i+1] - $ts[$i]) -le $ventana) { $acompanado = $true }
            if ($acompanado) { $cuenta++ }
        }
        $p = $k -split '\|'
        $n = [int]$intentosPorClave["$($p[0])"]
        $pct = $(if ($n -gt 0) { [math]::Round(100.0 * ($n - $cuenta) / $n, 2) } else { 0 })
        # el anexo pide 99,5% a las RSU y menos a las TCU
        $lim = $(if ("$($p[2])" -like 'RSU*') { $minimoRsu } else { $minimo })
        $res += [pscustomobject]@{Dia=$p[0]; NCU=$p[1]; Equipo=$p[2]; Intentos=$n
            Fallos_brutos=$ts.Count; Fallos_computados=$cuenta; Disponibilidad_pct=$pct
            Minimo_pct=$lim; Cumple=$(if ($pct -ge $lim) { 'SI' } else { 'NO' })}
    }
    return $res
}

# D.2 / D.3: cronologia de un abanderamiento a partir de las muestras de un
# TCU (ts, real, obj, ordenadas por ts). No hay un bit documentado de "posicion
# de seguridad activa", asi que la llegada de la orden se detecta por el salto
# del OBJETIVO, y la llegada del seguidor por que el real alcanza ese objetivo.
# Queda dicho en el informe: es una inferencia, no la lectura de un flag.
function Aband-Cronologia($muestras, [double]$tolLlegada = 1.0, [double]$tolCambio = 2.0) {
    $ms = @($muestras)
    if ($ms.Count -lt 2) { return $null }
    $obj0 = [double]$ms[0].obj
    $r = @{obj_inicial=[math]::Round($obj0,2); tilt_inicial=[math]::Round([double]$ms[0].real,2)
           t_orden=''; tilt_orden=''; obj_seguridad=''; t_llegada=''; tilt_llegada=''
           t_vuelta=''; t_llegada_vuelta=''; tilt_final=''; segundos_ida=''; segundos_vuelta=''}
    $i = 1
    while ($i -lt $ms.Count -and [math]::Abs([double]$ms[$i].obj - $obj0) -le $tolCambio) { $i++ }
    if ($i -ge $ms.Count) { return $r }              # nunca llego la orden
    $r.t_orden = $ms[$i].ts; $r.tilt_orden = [math]::Round([double]$ms[$i].real,2)
    $objSeg = [double]$ms[$i].obj
    $r.obj_seguridad = [math]::Round($objSeg,2)
    $j = $i
    while ($j -lt $ms.Count -and [math]::Abs([double]$ms[$j].real - [double]$ms[$j].obj) -gt $tolLlegada) { $j++ }
    if ($j -lt $ms.Count) {
        $r.t_llegada = $ms[$j].ts; $r.tilt_llegada = [math]::Round([double]$ms[$j].real,2)
        $r.segundos_ida = [int]($ms[$j].ts - $ms[$i].ts)
    } else { $j = $ms.Count - 1 }
    $k = $j
    while ($k -lt $ms.Count -and [math]::Abs([double]$ms[$k].obj - $objSeg) -le $tolCambio) { $k++ }
    if ($k -ge $ms.Count) { return $r }              # no hubo desabanderamiento
    $r.t_vuelta = $ms[$k].ts
    $l = $k
    while ($l -lt $ms.Count -and [math]::Abs([double]$ms[$l].real - [double]$ms[$l].obj) -gt $tolLlegada) { $l++ }
    if ($l -lt $ms.Count) {
        $r.t_llegada_vuelta = $ms[$l].ts; $r.tilt_final = [math]::Round([double]$ms[$l].real,2)
        $r.segundos_vuelta = [int]($ms[$l].ts - $ms[$k].ts)
    }
    return $r
}

# ---------------------------------------------------------------------------
#  Usuarios, roles y registro de acciones
# ---------------------------------------------------------------------------
# Que esto NO es: proteccion. Un .ps1 es texto plano, y quien sepa abrirlo se
# pone administrador en treinta segundos. Es una barrera contra el ERROR (que
# el ayudante no le de a "escribir planta completa" sin saber lo que hace) y,
# sobre todo, TRAZABILIDAD: quien escribio que, cuando y en que TCU.
$ROLES = @('lectura', 'tecnico', 'admin')
$ROL_DESC = @{
  lectura = 'Diagnostico, lecturas, informes y SAT. No escribe nada.'
  tecnico = 'Todo lo anterior + escribir variables, presets, NVM y firmware.'
  admin   = 'Todo + identidad de red, topologia y gestion de usuarios.'
}
$script:Usuario = $null
$FICH_USUARIOS = Join-Path $PSScriptRoot 'usuarios.json'

# PBKDF2 con sal por usuario: la contraseña nunca se guarda, ni en claro ni en
# un hash pelado que se rompa con una tabla.
function Pwd-Hash([string]$pass, [string]$salB64, [int]$iter) {
    $sal = [Convert]::FromBase64String($salB64)
    $k = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pass, $sal, $iter)
    try { return [Convert]::ToBase64String($k.GetBytes(32)) } finally { $k.Dispose() }
}
function Pwd-Sal {
    $b = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($b)
}
function Usuario-Nuevo([string]$usuario, [string]$nombre, [string]$rol, [string]$pass) {
    $sal = Pwd-Sal
    $iter = 100000
    return [ordered]@{usuario=$usuario; nombre=$nombre; rol=$rol; sal=$sal; iteraciones=$iter; hash=(Pwd-Hash $pass $sal $iter)}
}
# Comprueba usuario+contraseña contra la lista. Pura: se prueba sin ventana.
function Usuario-Validar($usuarios, [string]$usuario, [string]$pass) {
    foreach ($u in @($usuarios)) {
        if ("$($u.usuario)".ToLower() -ne "$usuario".ToLower()) { continue }
        $h = Pwd-Hash $pass "$($u.sal)" ([int]$u.iteraciones)
        if ($h -eq "$($u.hash)") { return $u }
        return $null
    }
    return $null
}
function Usuarios-Cargar {
    if (-not (Test-Path $FICH_USUARIOS)) { return @() }
    try { return @(Get-Content $FICH_USUARIOS -Raw | ConvertFrom-Json) } catch { return @() }
}
function Usuarios-Guardar($lista) {
    ConvertTo-Json @($lista) -Depth 4 | Set-Content $FICH_USUARIOS -Encoding UTF8
}
# Jerarquia de permisos: admin >= tecnico >= lectura.
function Puede([string]$minimo) {
    if (-not $script:Usuario) { return $false }
    $orden = @{lectura=0; tecnico=1; admin=2}
    return ([int]$orden["$($script:Usuario.rol)"] -ge [int]$orden[$minimo])
}

# Registro de acciones: una linea por escritura, se acumula en el PC de planta.
# Es lo que contesta el dia que alguien pregunta quien cambio tal cosa.
function Auditar([string]$accion, [string]$ncu, $tcu, [string]$detalle) {
    try {
        $dir = Join-Path $PSScriptRoot 'registro'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $f = Join-Path $dir ('acciones_' + (Get-Date -Format 'yyyyMM') + '.csv')
        if (-not (Test-Path $f)) { Set-Content -Path $f -Value 'fecha;usuario;rol;planta;accion;ncu;tcu;detalle' -Encoding UTF8 }
        $lin = ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), "$($script:Usuario.usuario)", "$($script:Usuario.rol)",
                (Nombre-Planta), $accion, $ncu, "$tcu", ("$detalle" -replace '[;\r\n]', ' ')) -join ';'
        Add-Content -Path $f -Value $lin -Encoding UTF8
    } catch {}
}

# ---------------------------------------------------------------------------
#  Interfaz
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "TCU Toolbox v$VERSION_TOOLBOX - Sunner  (mapa $VERSION_MAPA)"
$form.Size = New-Object System.Drawing.Size(960, 820)
$form.StartPosition = 'CenterScreen'
# Ventana redimensionable y maximizable: los anclajes del final del script
# hacen que crezcan las listas y la consola. MinimumSize = el diseno original,
# asi que nunca puede quedar mas pequena de lo que cabe.
$form.FormBorderStyle = 'Sizable'; $form.MaximizeBox = $true
$form.MinimumSize = New-Object System.Drawing.Size(960, 820)

$gbCon = New-Object System.Windows.Forms.GroupBox
$gbCon.Text = ' Conexion '
$gbCon.Location = New-Object System.Drawing.Point(10, 8)
$gbCon.Size = New-Object System.Drawing.Size(925, 58)
$form.Controls.Add($gbCon)

function LG($p, [string]$t, [int]$x, [int]$w, [int]$y = 25) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $t; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, 20); $p.Controls.Add($l); return $l
}
# Un solo globo para toda la ventana: la sintaxis del cuadro TCUs no cabe en el
# rotulo y sin esto hay que acordarse.
$ttW = New-Object System.Windows.Forms.ToolTip
$ttW.AutoPopDelay = 20000; $ttW.InitialDelay = 400; $ttW.ReshowDelay = 200
$AYUDA_TCUS = @"
1-44                que rango (lo de siempre)
10,22,30-40         sueltas y tramos a la vez
12/10, 15/5-12      cada tramo con SU NCU
12/*                todas las de la NCU 12
vacio o NA          todas las de la seleccion
"@

function TG($p, [string]$t, [int]$x, [int]$y, [int]$w) {
    $c = New-Object System.Windows.Forms.TextBox
    $c.Text = $t; $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, 22); $p.Controls.Add($c); return $c
}

$cbPlanta = New-Object System.Windows.Forms.ComboBox
$cbPlanta.Location = New-Object System.Drawing.Point(10, 21)
$cbPlanta.Size = New-Object System.Drawing.Size(175, 22)
$cbPlanta.DropDownStyle = 'DropDownList'
foreach ($k in $PLANTAS.Keys) { [void]$cbPlanta.Items.Add($k) }
$cbPlanta.SelectedIndex = 0
$gbCon.Controls.Add($cbPlanta)

$btnPlantas = New-Object System.Windows.Forms.Button
$btnPlantas.Text = 'Cargar...'
$btnPlantas.Location = New-Object System.Drawing.Point(190, 19)
$btnPlantas.Size = New-Object System.Drawing.Size(62, 26)
$gbCon.Controls.Add($btnPlantas)

[void](LG $gbCon 'IP' 262 20)
$txtIp = TG $gbCon '192.168.4.60' 284 22 105
[void](LG $gbCon 'Puerto' 398 46)
$txtPort = TG $gbCon '503' 446 22 45
[void](LG $gbCon 'T/O ms' 502 48)
$txtTo = TG $gbCon '8000' 552 22 46
[void](LG $gbCon 'Reint.' 606 42)
$txtRet = TG $gbCon '3' 650 22 28
# Filtro de gateway: vacio = todos. Con "(Planta completa)" y 504 aqui se
# trabaja sobre TODAS las TCUs del GW2 de cada NCU, que antes obligaba a ir
# NCU por NCU con su rango a mano.
[void](LG $gbCon 'GW' 688 24)
$txtGw = TG $gbCon '' 714 22 46

$btnCancelar = New-Object System.Windows.Forms.Button
$btnCancelar.Text = 'CANCELAR'
$btnCancelar.Location = New-Object System.Drawing.Point(800, 18)
$btnCancelar.Size = New-Object System.Drawing.Size(110, 30)
$btnCancelar.Enabled = $false
$btnCancelar.BackColor = [System.Drawing.Color]::FromArgb(150,30,30)
$btnCancelar.ForeColor = [System.Drawing.Color]::White
$gbCon.Controls.Add($btnCancelar)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, 72)
$tabs.Size = New-Object System.Drawing.Size(925, 400)
$form.Controls.Add($tabs)

# ============================ TAB ESCRIBIR ============================
$tabW = New-Object System.Windows.Forms.TabPage
$tabW.Text = 'Escribir'
$tabs.TabPages.Add($tabW)

# Un solo cuadro: "1-44" de siempre, "10,22,30-40" para las sueltas y
# "12/10, 15/5-12" cuando son de NCUs distintas. Con dos cuadros de/a habia que
# ir tres veces o pasar por un CSV.
[void](LG $tabW 'TCUs' 10 40)
$txtWTcus = TG $tabW '1-44' 52 22 150
$txtWTcus.Add_MouseHover({ $ttW.SetToolTip($txtWTcus, $AYUDA_TCUS) })

[void](LG $tabW 'Filtro' 212 42)
$txtWFiltro = TG $tabW '' 256 22 150
$lblWFiltro = LG $tabW '' 412 104
$lblWFiltro.ForeColor = [System.Drawing.Color]::Gray

$btnWQuitar = New-Object System.Windows.Forms.Button
$btnWQuitar.Text = 'Quitar'
$btnWQuitar.Location = New-Object System.Drawing.Point(524, 18)
$btnWQuitar.Size = New-Object System.Drawing.Size(78, 28)
$tabW.Controls.Add($btnWQuitar)

$btnPresetSave = New-Object System.Windows.Forms.Button
$btnPresetSave.Text = 'Guardar preset'
$btnPresetSave.Location = New-Object System.Drawing.Point(610, 18)
$btnPresetSave.Size = New-Object System.Drawing.Size(140, 28)
$tabW.Controls.Add($btnPresetSave)

$btnPresetLoad = New-Object System.Windows.Forms.Button
$btnPresetLoad.Text = 'Cargar preset'
$btnPresetLoad.Location = New-Object System.Drawing.Point(756, 18)
$btnPresetLoad.Size = New-Object System.Drawing.Size(140, 28)
$tabW.Controls.Add($btnPresetLoad)

$dgv = New-Object System.Windows.Forms.DataGridView
$dgv.Location = New-Object System.Drawing.Point(10, 55)
$dgv.Size = New-Object System.Drawing.Size(898, 228)
$dgv.AllowUserToAddRows = $true
$dgv.RowHeadersVisible = $true
$dgv.RowHeadersWidth = 24
$dgv.BackgroundColor = [System.Drawing.Color]::White
$colVar = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colVar.HeaderText = 'Variable'; $colVar.Width = 340
foreach ($k in $VARIABLES.Keys) { [void]$colVar.Items.Add($k) }
$colVal = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colVal.HeaderText = 'Nuevo valor'; $colVal.Width = 150
$colInfo = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colInfo.HeaderText = 'Registro / tipo'; $colInfo.Width = 358; $colInfo.ReadOnly = $true
[void]$dgv.Columns.Add($colVar); [void]$dgv.Columns.Add($colVal); [void]$dgv.Columns.Add($colInfo)
$tabW.Controls.Add($dgv)

function Info-Variable([string]$nombre) {
    $v = $VARIABLES[$nombre]
    $extra = ''
    if ($ADDR_COMANDO -contains $v.addr) { $extra = '  [COMANDO]' }
    if ($v.tipo -eq 'bit') { return "reg $($v.addr)  bit $($v.bit)$extra" }
    return "reg $($v.addr)  tipo $($v.tipo)$extra"
}

$dgv.Add_CellValueChanged({
    param($s, $e)
    if ($e.ColumnIndex -eq 0 -and $e.RowIndex -ge 0) {
        $nombre = $dgv.Rows[$e.RowIndex].Cells[0].Value
        if ($nombre -and $VARIABLES.Contains($nombre)) {
            $dgv.Rows[$e.RowIndex].Cells[2].Value = Info-Variable $nombre
        }
    }
})

# Una celda con un valor que no este en la lista del combo (p.ej. cargada con
# el filtro activo) no debe reventar el grid.
$dgv.Add_DataError({ param($s, $e) $e.ThrowException = $false })
$btnWQuitar.Add_Click({ Quitar-Filas $dgv; Refrescar-FiltroEscribir })
$dgv.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Delete') { Quitar-Filas $dgv; Refrescar-FiltroEscribir; $e.Handled = $true } })

# Filtro del combo de variables: reduce la lista a lo que casa con el texto,
# conservando siempre los nombres ya usados en filas existentes.
function Refrescar-FiltroEscribir {
    $usados = @{}
    foreach ($fila in $dgv.Rows) {
        if (-not $fila.IsNewRow -and $fila.Cells[0].Value) { $usados[[string]$fila.Cells[0].Value] = $true }
    }
    $coinciden = @(Nombres-Ordenados @(Filtrar-Nombres @($VARIABLES.Keys) $txtWFiltro.Text))
    $colVar.Items.Clear()
    foreach ($k in $coinciden) { [void]$colVar.Items.Add($k) }
    foreach ($k in $VARIABLES.Keys) {
        if ($usados.ContainsKey($k) -and -not $colVar.Items.Contains($k)) { [void]$colVar.Items.Add($k) }
    }
    if ("$($txtWFiltro.Text)".Trim()) { $lblWFiltro.Text = "$($coinciden.Count) de $($VARIABLES.Count) variables" }
    else { $lblWFiltro.Text = "$($VARIABLES.Count) variables" }
}

$txtWFiltro.Add_TextChanged({ Refrescar-FiltroEscribir })
Refrescar-FiltroEscribir

$chkVerif = New-Object System.Windows.Forms.CheckBox
$chkVerif.Text = 'Verificar tras escribir'
$chkVerif.Location = New-Object System.Drawing.Point(10, 296)
$chkVerif.Size = New-Object System.Drawing.Size(160, 22); $chkVerif.Checked = $true
$tabW.Controls.Add($chkVerif)

# La copia previa lee valor a valor antes de escribir nada, asi que en un rango
# grande la escritura tarda en arrancar. Se puede quitar, pero la confirmacion
# lo dice cada vez para que no se olvide.
$chkRoll = New-Object System.Windows.Forms.CheckBox
$chkRoll.Text = 'Copia de seguridad antes de escribir (rollback)'
$chkRoll.Location = New-Object System.Drawing.Point(10, 326)
$chkRoll.Size = New-Object System.Drawing.Size(300, 22); $chkRoll.Checked = $true
$tabW.Controls.Add($chkRoll)

# Simular no toca nada: cruza lo que se va a escribir con la ultima lectura y
# dice cuantas TCUs cambiarian de verdad. Es donde se ve, ANTES de escribir 342
# seguidores, que media planta tiene otra configuracion a proposito.
$btnSimular = New-Object System.Windows.Forms.Button
$btnSimular.Text = 'SIMULAR'
$btnSimular.Location = New-Object System.Drawing.Point(180, 292)
$btnSimular.Size = New-Object System.Drawing.Size(96, 30)
$tabW.Controls.Add($btnSimular)

$btnEscribir = New-Object System.Windows.Forms.Button
$btnEscribir.Text = 'ESCRIBIR'
$btnEscribir.Location = New-Object System.Drawing.Point(284, 292)
$btnEscribir.Size = New-Object System.Drawing.Size(110, 30)
$btnEscribir.BackColor = [System.Drawing.Color]::FromArgb(0,120,60)
$btnEscribir.ForeColor = [System.Drawing.Color]::White
$tabW.Controls.Add($btnEscribir)

$btnFallidas = New-Object System.Windows.Forms.Button
$btnFallidas.Text = 'Reintentar fallidas'
$btnFallidas.Location = New-Object System.Drawing.Point(402, 292)
$btnFallidas.Size = New-Object System.Drawing.Size(126, 30)
$btnFallidas.Enabled = $false
$tabW.Controls.Add($btnFallidas)

$btnCargarBackup = New-Object System.Windows.Forms.Button
$btnCargarBackup.Text = 'Backup JSON como preset'
$btnCargarBackup.Location = New-Object System.Drawing.Point(536, 292)
$btnCargarBackup.Size = New-Object System.Drawing.Size(158, 30)
$tabW.Controls.Add($btnCargarBackup)

$btnCsvTcu = New-Object System.Windows.Forms.Button
$btnCsvTcu.Text = 'CSV por TCU...'
$btnCsvTcu.Location = New-Object System.Drawing.Point(700, 292)
$btnCsvTcu.Size = New-Object System.Drawing.Size(106, 30)
$tabW.Controls.Add($btnCsvTcu)

$btnNvm = New-Object System.Windows.Forms.Button
$btnNvm.Text = 'GUARDAR EN NVM'
$btnNvm.Location = New-Object System.Drawing.Point(812, 292)
$btnNvm.Size = New-Object System.Drawing.Size(96, 30)
$btnNvm.BackColor = [System.Drawing.Color]::FromArgb(160,80,0)
$btnNvm.ForeColor = [System.Drawing.Color]::White
$tabW.Controls.Add($btnNvm)

# ============================ TAB LEER VARIABLE ============================
# Misma maqueta que Escribir: una tabla con una fila por variable, en vez del
# combo + Anadir + lista que habia antes. Las dos pestanas se usan seguidas y
# no tenia sentido que se eligieran las variables de dos maneras distintas.
$tabL = New-Object System.Windows.Forms.TabPage
$tabL.Text = 'Leer variable'
$tabs.TabPages.Add($tabL)

[void](LG $tabL 'TCUs' 10 40)
$txtLTcus = TG $tabL '1-44' 52 22 150
$txtLTcus.Add_MouseHover({ $ttW.SetToolTip($txtLTcus, $AYUDA_TCUS) })

[void](LG $tabL 'Filtro' 212 42)
$txtLFiltro = TG $tabL '' 256 22 150
$lblLFiltro = LG $tabL '' 412 86
$lblLFiltro.ForeColor = [System.Drawing.Color]::Gray

# El preset ya dice que variables importan: teclearlas otra vez aqui sobra. Con
# esto se puede leer lo mismo que se audita (o que se escribe) sin pasar por la
# pestana Auditoria, que era el unico sitio desde donde se podia traer.
$btnLPreset = New-Object System.Windows.Forms.Button
$btnLPreset.Text = 'Cargar preset...'
$btnLPreset.Location = New-Object System.Drawing.Point(514, 18)
$btnLPreset.Size = New-Object System.Drawing.Size(112, 28)
$tabL.Controls.Add($btnLPreset)

# Quitar la variable seleccionada. Existia con la lista de la v5.1 y se perdio
# al pasar a tabla; sin cabeceras de fila no hay forma evidente de borrar una.
$btnLQuitar = New-Object System.Windows.Forms.Button
$btnLQuitar.Text = 'Quitar'
$btnLQuitar.Location = New-Object System.Drawing.Point(632, 18)
$btnLQuitar.Size = New-Object System.Drawing.Size(66, 28)
$tabL.Controls.Add($btnLQuitar)

$btnLeer = New-Object System.Windows.Forms.Button
$btnLeer.Text = 'LEER'
$btnLeer.Location = New-Object System.Drawing.Point(704, 18)
$btnLeer.Size = New-Object System.Drawing.Size(100, 28)
$btnLeer.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnLeer.ForeColor = [System.Drawing.Color]::White
$tabL.Controls.Add($btnLeer)

$btnLCsv = New-Object System.Windows.Forms.Button
$btnLCsv.Text = 'Exportar CSV'
$btnLCsv.Location = New-Object System.Drawing.Point(810, 18)
$btnLCsv.Size = New-Object System.Drawing.Size(96, 28)
$btnLCsv.Enabled = $false
$tabL.Controls.Add($btnLCsv)

# La lista de lectura admite tambien los registros de estado (3xxxx), que en
# Escribir no existen: por eso el combo de esta tabla no es el mismo.
$dgvL = New-Object System.Windows.Forms.DataGridView
$dgvL.Location = New-Object System.Drawing.Point(10, 55)
$dgvL.Size = New-Object System.Drawing.Size(898, 118)
$dgvL.AllowUserToAddRows = $true
$dgvL.RowHeadersVisible = $true          # el selector de fila: con el se marca y se borra con Supr
$dgvL.RowHeadersWidth = 24
$dgvL.BackgroundColor = [System.Drawing.Color]::White
$colLVar = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colLVar.HeaderText = 'Variable'; $colLVar.Width = 420
$colLInfo = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colLInfo.HeaderText = 'Registro / tipo'; $colLInfo.Width = 428; $colLInfo.ReadOnly = $true
[void]$dgvL.Columns.Add($colLVar); [void]$dgvL.Columns.Add($colLInfo)
$tabL.Controls.Add($dgvL)

$dgvL.Add_CellValueChanged({
    param($s, $e)
    if ($e.ColumnIndex -eq 0 -and $e.RowIndex -ge 0) {
        $nombre = "$($dgvL.Rows[$e.RowIndex].Cells[0].Value)"
        if ($nombre) { $dgvL.Rows[$e.RowIndex].Cells[1].Value = Info-Lectura $nombre }
    }
})
$dgvL.Add_DataError({ param($s, $e) $e.ThrowException = $false })

# Quitar filas: por boton, y con Supr sobre la fila marcada. Se quitan todas
# las seleccionadas, para pasar de tres variables a dos de un tiron.
function Quitar-Filas($grid) {
    $borrar = @()
    foreach ($c in $grid.SelectedCells) { if (-not $grid.Rows[$c.RowIndex].IsNewRow) { $borrar += $c.RowIndex } }
    foreach ($f in $grid.SelectedRows) { if (-not $f.IsNewRow) { $borrar += $f.Index } }
    foreach ($i in @($borrar | Sort-Object -Unique -Descending)) { $grid.Rows.RemoveAt($i) }
}
$btnLQuitar.Add_Click({ Quitar-Filas $dgvL; Refrescar-FiltroLeer })

$btnLPreset.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Preset o backup (*.json)|*.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    try { $obj = Get-Content $dlg.FileName -Raw | ConvertFrom-Json }
    catch { [void][System.Windows.Forms.MessageBox]::Show("No se pudo leer: $_",'Error'); return }
    $r = Preset-Nombres $obj
    if (@($r.nombres).Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('El fichero no tiene ninguna variable de las del mapa.','Error'); return
    }
    # las que ya estuvieran puestas a mano se pierden: avisar antes de borrarlas
    if ($dgvL.Rows.Count -gt 1) {
        $rr = [System.Windows.Forms.MessageBox]::Show(
            "La tabla tiene $($dgvL.Rows.Count - 1) variables puestas. Reemplazarlas por las $(@($r.nombres).Count) del preset?",
            'Ya hay variables', 'YesNo', 'Question')
        if ($rr -ne 'Yes') { return }
    }
    $dgvL.Rows.Clear()
    foreach ($n in @($r.nombres)) {
        if (-not $colLVar.Items.Contains($n)) { [void]$colLVar.Items.Add($n) }
        [void]$dgvL.Rows.Add($n, (Info-Lectura $n))
    }
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Preset cargado en la lectura: $(@($r.nombres).Count) variables de $([System.IO.Path]::GetFileName($dlg.FileName)). Pulsa LEER." ([System.Drawing.Color]::SteelBlue)
    if (@($r.fuera).Count -gt 0) {
        Con "  fuera $(@($r.fuera).Count) que no estan en el mapa v$($VERSION_MAPA): $((@($r.fuera) | Select-Object -First 6) -join ', ')" ([System.Drawing.Color]::Orange)
    }
})
$dgvL.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Delete') { Quitar-Filas $dgvL; Refrescar-FiltroLeer; $e.Handled = $true } })

function Nombres-Legibles { return @(Nombres-Ordenados @($VARIABLES.Keys)) + @(Nombres-Ordenados @($ESTADO.Keys) | ForEach-Object { 'ESTADO ' + $_ }) }

function Info-Lectura([string]$nombre) {
    $v = $null
    if ($nombre -like 'ESTADO *') { $v = $ESTADO[$nombre.Substring(7)] } else { $v = $VARIABLES[$nombre] }
    if (-not $v) { return '' }
    if ($v.tipo -eq 'bit') { return "reg $($v.addr)  bit $($v.bit)" }
    return "reg $($v.addr)  tipo $($v.tipo)"
}

# Filtro del combo: reduce la lista a lo que casa, conservando siempre los
# nombres ya usados en filas existentes (igual que en Escribir).
function Refrescar-FiltroLeer {
    $usados = @{}
    foreach ($fila in $dgvL.Rows) {
        if (-not $fila.IsNewRow -and $fila.Cells[0].Value) { $usados["$($fila.Cells[0].Value)"] = $true }
    }
    $todos = @(Nombres-Legibles)
    $coinciden = @(Filtrar-Nombres $todos $txtLFiltro.Text)
    $colLVar.Items.Clear()
    foreach ($k in $coinciden) { [void]$colLVar.Items.Add($k) }
    foreach ($k in $todos) {
        if ($usados.ContainsKey($k) -and -not $colLVar.Items.Contains($k)) { [void]$colLVar.Items.Add($k) }
    }
    if ("$($txtLFiltro.Text)".Trim()) { $lblLFiltro.Text = "$($coinciden.Count) de $($todos.Count) variables" }
    else { $lblLFiltro.Text = "$($todos.Count) variables" }
}

$txtLFiltro.Add_TextChanged({ Refrescar-FiltroLeer })
Refrescar-FiltroLeer

$lvL = New-Object System.Windows.Forms.ListView
$lvL.Location = New-Object System.Drawing.Point(10, 180)
$lvL.Size = New-Object System.Drawing.Size(898, 180)
$lvL.View = 'Details'; $lvL.FullRowSelect = $true; $lvL.GridLines = $true
[void]$lvL.Columns.Add('TCU', 70)
[void]$lvL.Columns.Add('Valor', 200)
[void]$lvL.Columns.Add('Estado', 600)
$tabL.Controls.Add($lvL)

# Nombres elegidos en la tabla, sin repetidos y en el orden en que estan
# Nombres unicos, en el orden en que estan. Aparte de la tabla para poder
# probarlo: aqui se colo el fallo de la v5.2. Devolvia ",$r" (un ArrayList sin
# desplegar) y el "@(...)" de quien llamaba se quedaba con UN solo elemento: las
# tres variables llegaban pegadas en una sola cadena.
function Nombres-Unicos($valores) {
    $r = New-Object System.Collections.ArrayList
    foreach ($v in $valores) {
        $n = "$v"
        if ($n -and -not $r.Contains($n)) { [void]$r.Add($n) }
    }
    return $r.ToArray()
}

function Vars-DeTablaLeer {
    $vals = @()
    foreach ($fila in $dgvL.Rows) {
        if ($fila.IsNewRow) { continue }
        $vals += "$($fila.Cells[0].Value)"
    }
    return (Nombres-Unicos $vals)
}

# ============================ TAB VOLCAR TCU ============================
$tabD = New-Object System.Windows.Forms.TabPage
$tabD.Text = 'Volcar TCU'
$tabs.TabPages.Add($tabD)

[void](LG $tabD 'TCU' 10 35)
$txtDTcu = TG $tabD '1' 48 22 50

$chkDEstado = New-Object System.Windows.Forms.CheckBox
$chkDEstado.Text = 'Incluir registros de estado (30xxx)'
$chkDEstado.Location = New-Object System.Drawing.Point(120, 22)
$chkDEstado.Size = New-Object System.Drawing.Size(220, 22)
$chkDEstado.Checked = $true
$tabD.Controls.Add($chkDEstado)

$chkDIdent = New-Object System.Windows.Forms.CheckBox
$chkDIdent.Text = 'Incluir identidad (30300+)'
$chkDIdent.Location = New-Object System.Drawing.Point(350, 22)
$chkDIdent.Size = New-Object System.Drawing.Size(180, 22)
$chkDIdent.Checked = $false
$tabD.Controls.Add($chkDIdent)

$btnVolcar = New-Object System.Windows.Forms.Button
$btnVolcar.Text = 'VOLCAR'
$btnVolcar.Location = New-Object System.Drawing.Point(560, 18)
$btnVolcar.Size = New-Object System.Drawing.Size(100, 28)
$btnVolcar.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnVolcar.ForeColor = [System.Drawing.Color]::White
$tabD.Controls.Add($btnVolcar)

$btnBackupJson = New-Object System.Windows.Forms.Button
$btnBackupJson.Text = 'Backup JSON'
$btnBackupJson.Location = New-Object System.Drawing.Point(670, 18)
$btnBackupJson.Size = New-Object System.Drawing.Size(110, 28)
$btnBackupJson.Enabled = $false
$tabD.Controls.Add($btnBackupJson)

$btnDCsv = New-Object System.Windows.Forms.Button
$btnDCsv.Text = 'Exportar CSV'
$btnDCsv.Location = New-Object System.Drawing.Point(790, 18)
$btnDCsv.Size = New-Object System.Drawing.Size(110, 28)
$btnDCsv.Enabled = $false
$tabD.Controls.Add($btnDCsv)

$lvD = New-Object System.Windows.Forms.ListView
$lvD.Location = New-Object System.Drawing.Point(10, 55)
$lvD.Size = New-Object System.Drawing.Size(898, 272)
$lvD.View = 'Details'; $lvD.FullRowSelect = $true; $lvD.GridLines = $true
[void]$lvD.Columns.Add('Variable', 380)
[void]$lvD.Columns.Add('Valor', 180)
[void]$lvD.Columns.Add('Nota', 330)
$tabD.Controls.Add($lvD)

$btnComparar = New-Object System.Windows.Forms.Button
$btnComparar.Text = 'Comparar con backup JSON...'
$btnComparar.Location = New-Object System.Drawing.Point(10, 335)
$btnComparar.Size = New-Object System.Drawing.Size(210, 28)
$btnComparar.Enabled = $false
$tabD.Controls.Add($btnComparar)

[void](LG $tabD 'Backup NCU, TCUs' 250 110 340)
$txtBTcus = TG $tabD '1-44' 362 337 84
$txtBTcus.Add_MouseHover({ $ttW.SetToolTip($txtBTcus, $AYUDA_TCUS) })

$btnBackupNcu = New-Object System.Windows.Forms.Button
$btnBackupNcu.Text = 'BACKUP NCU (un JSON por TCU)...'
$btnBackupNcu.Location = New-Object System.Drawing.Point(458, 335)
$btnBackupNcu.Size = New-Object System.Drawing.Size(230, 28)
$tabD.Controls.Add($btnBackupNcu)

# ============================ TAB DIAGNOSTICO ============================
$tabG = New-Object System.Windows.Forms.TabPage
$tabG.Text = 'Diagnostico'
$tabs.TabPages.Add($tabG)

[void](LG $tabG 'TCUs' 10 40)
$txtGTcus = TG $tabG '1-44' 52 22 130
$txtGTcus.Add_MouseHover({ $ttW.SetToolTip($txtGTcus, $AYUDA_TCUS) })

$btnDiag = New-Object System.Windows.Forms.Button
$btnDiag.Text = 'DIAGNOSTICAR'
$btnDiag.Location = New-Object System.Drawing.Point(200, 18)
$btnDiag.Size = New-Object System.Drawing.Size(120, 28)
$btnDiag.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnDiag.ForeColor = [System.Drawing.Color]::White
$tabG.Controls.Add($btnDiag)

$chkGPar = New-Object System.Windows.Forms.CheckBox
$chkGPar.Text = 'en paralelo'
$chkGPar.Checked = $true
$chkGPar.Location = New-Object System.Drawing.Point(536, 53)
$chkGPar.Size = New-Object System.Drawing.Size(104, 22)
$tabG.Controls.Add($chkGPar)

$chkGNcu = New-Object System.Windows.Forms.CheckBox
$chkGNcu.Text = 'via NCU'
$chkGNcu.Checked = $true
$chkGNcu.Location = New-Object System.Drawing.Point(328, 21)
$chkGNcu.Size = New-Object System.Drawing.Size(92, 22)
$tabG.Controls.Add($chkGNcu)

[void](LG $tabG 'NCUs' 425 40)
$txtGNcus = TG $tabG '' 467 22 62
$txtGNcus.Text = ''

$lblGResumen = New-Object System.Windows.Forms.Label
$lblGResumen.Text = ''
$lblGResumen.Location = New-Object System.Drawing.Point(540, 24)
$lblGResumen.Size = New-Object System.Drawing.Size(120, 20)
$tabG.Controls.Add($lblGResumen)

$btnGCsv = New-Object System.Windows.Forms.Button
$btnGCsv.Text = 'CSV'
$btnGCsv.Location = New-Object System.Drawing.Point(670, 18)
$btnGCsv.Size = New-Object System.Drawing.Size(110, 28)
$btnGCsv.Enabled = $false
$tabG.Controls.Add($btnGCsv)

$btnGJson = New-Object System.Windows.Forms.Button
$btnGJson.Text = 'JSON'
$btnGJson.Location = New-Object System.Drawing.Point(790, 18)
$btnGJson.Size = New-Object System.Drawing.Size(110, 28)
$btnGJson.Enabled = $false
$tabG.Controls.Add($btnGJson)

# mini-registrador: repite el diagnostico cada X minutos y acumula a CSV
[void](LG $tabG 'Registrador: cada' 10 108 57)
$txtGCada = TG $tabG '10' 118 54 40
[void](LG $tabG 'min' 163 28 57)
$btnGBucle = New-Object System.Windows.Forms.Button
$btnGBucle.Text = 'BUCLE CSV'
$btnGBucle.Location = New-Object System.Drawing.Point(200, 51)
$btnGBucle.Size = New-Object System.Drawing.Size(120, 28)
$tabG.Controls.Add($btnGBucle)
$lblGBucle = New-Object System.Windows.Forms.Label
$lblGBucle.Text = ''
$lblGBucle.Location = New-Object System.Drawing.Point(328, 57)
$lblGBucle.Size = New-Object System.Drawing.Size(200, 20)
$lblGBucle.ForeColor = [System.Drawing.Color]::Gray
$tabG.Controls.Add($lblGBucle)

$btnGComm = New-Object System.Windows.Forms.Button
$btnGComm.Text = 'TEST COMM (rapido)'
$btnGComm.Location = New-Object System.Drawing.Point(668, 51)
$btnGComm.Size = New-Object System.Drawing.Size(150, 28)
$btnGBat = New-Object System.Windows.Forms.Button
$btnGBat.Text = 'BATERIAS'
$btnGBat.Location = New-Object System.Drawing.Point(826, 51)
$btnGBat.Size = New-Object System.Drawing.Size(82, 28)
$btnGBat.Enabled = $false
$tabG.Controls.Add($btnGBat)

$btnGComm.BackColor = [System.Drawing.Color]::FromArgb(0,120,60)
$btnGComm.ForeColor = [System.Drawing.Color]::White
$tabG.Controls.Add($btnGComm)

# Listado para pegar en WhatsApp: los tecnicos de campo no leen un CSV en el
# movil. Respeta el filtro de NCU de al lado, asi que sirve tanto para el parte
# general como para mandarle a cada uno lo suyo.
$btnGWa = New-Object System.Windows.Forms.Button
$btnGWa.Text = 'COPIAR NO-OK'
$btnGWa.Location = New-Object System.Drawing.Point(758, 84)
$btnGWa.Size = New-Object System.Drawing.Size(150, 26)
$btnGWa.Enabled = $false
$tabG.Controls.Add($btnGWa)

# filtros de vista sobre el resultado ya leido (no relanzan lecturas)
[void](LG $tabG 'Ver' 10 30 89)
$cbGVerNcu = New-Object System.Windows.Forms.ComboBox
$cbGVerNcu.Location = New-Object System.Drawing.Point(44, 86)
$cbGVerNcu.Size = New-Object System.Drawing.Size(110, 22)
$cbGVerNcu.DropDownStyle = 'DropDownList'
[void]$cbGVerNcu.Items.Add('NCU - todas')
$cbGVerNcu.SelectedIndex = 0
$tabG.Controls.Add($cbGVerNcu)
# casillas de salud: se pueden marcar VARIAS a la vez (p. ej. ALARMA y
# OFFLINE); ninguna marcada = se muestran todas
$script:ChksSalud = @{}
$xChk = 162
foreach ($s in @('OK','AVISO','ALARMA','OFFLINE')) {
    $ch = New-Object System.Windows.Forms.CheckBox
    $ch.Text = $s
    $ch.Location = New-Object System.Drawing.Point($xChk, 86)
    $ch.Size = New-Object System.Drawing.Size($(if ($s -eq 'OFFLINE') { 78 } else { 72 }), 22)
    $tabG.Controls.Add($ch)
    $script:ChksSalud[$s] = $ch
    $xChk += $ch.Size.Width
}
$lblGVer = New-Object System.Windows.Forms.Label
$lblGVer.Text = ''
$lblGVer.Location = New-Object System.Drawing.Point(462, 89)
$lblGVer.Size = New-Object System.Drawing.Size(288, 20)
$lblGVer.ForeColor = [System.Drawing.Color]::Gray
$tabG.Controls.Add($lblGVer)

$lvG = New-Object System.Windows.Forms.ListView
$lvG.Location = New-Object System.Drawing.Point(10, 116)
$lvG.Size = New-Object System.Drawing.Size(898, 244)
$lvG.View = 'Details'; $lvG.FullRowSelect = $true; $lvG.GridLines = $true
[void]$lvG.Columns.Add('NCU', 45)
[void]$lvG.Columns.Add('TCU', 45)
# De que gateway cuelga cada TCU: en modo via NCU todo se lee por el 502, pero
# el equipo sigue estando en su GW y hay que saberlo para el updater y para
# saber a que red Zigbee pertenece.
[void]$lvG.Columns.Add('GW', 48)
[void]$lvG.Columns.Add('Salud', 65)
[void]$lvG.Columns.Add('Modo', 65)
[void]$lvG.Columns.Add('Tilt real', 58)
[void]$lvG.Columns.Add('Objetivo', 58)
[void]$lvG.Columns.Add('Dif', 46)
[void]$lvG.Columns.Add('SoC', 46)
[void]$lvG.Columns.Add('Edad s', 60)
[void]$lvG.Columns.Add('Alarmas / notas', 342)
$tabG.Controls.Add($lvG)

# ============================ TAB AUDITORIA ============================
# Se llamaba 'Flota', que no decia nada de lo que hay dentro. Sigue llevando
# tambien el inventario, y el buscador (Ctrl+K) lo encuentra por su nombre.
# ============================ TAB BATERIAS ============================
# El diagnostico ya trae de cada TCU la tension, la corriente, el SoC, el SoH,
# las temperaturas y -desde el mapa de la NCU- la tension de panel y la
# corriente de entrada. Estaban repartidas por columnas del diagnostico y en el
# CSV, pero no habia donde verlas juntas. Esta pestana no lee nada: es la misma
# lectura, puesta como el inventario de firmware.
$tabB = New-Object System.Windows.Forms.TabPage
$tabB.Text = 'Baterias'
$tabs.TabPages.Add($tabB)

$lblBInfo = LG $tabB 'Las baterias del ultimo diagnostico: VER no lee nada. LEER CARGA si lee (estado del cargador, bloque largo de la NCU).' 10 890 16
$lblBInfo.ForeColor = [System.Drawing.Color]::Gray

$btnBVer = New-Object System.Windows.Forms.Button
$btnBVer.Text = 'VER BATERIAS'
$btnBVer.Location = New-Object System.Drawing.Point(10, 40)
$btnBVer.Size = New-Object System.Drawing.Size(140, 28)
$btnBVer.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnBVer.ForeColor = [System.Drawing.Color]::White
$tabB.Controls.Add($btnBVer)

$btnBAud = New-Object System.Windows.Forms.Button
$btnBAud.Text = 'AUDITAR'
$btnBAud.Location = New-Object System.Drawing.Point(158, 40)
$btnBAud.Size = New-Object System.Drawing.Size(96, 28)
$tabB.Controls.Add($btnBAud)

# Unica lectura nueva de esta pestana: la seccion de carga del bloque largo
# de la NCU, que el diagnostico no toca.
$btnBCar = New-Object System.Windows.Forms.Button
$btnBCar.Text = 'LEER CARGA'
$btnBCar.Location = New-Object System.Drawing.Point(262, 40)
$btnBCar.Size = New-Object System.Drawing.Size(120, 28)
$tabB.Controls.Add($btnBCar)

$btnBCsv = New-Object System.Windows.Forms.Button
$btnBCsv.Text = 'CSV'
$btnBCsv.Location = New-Object System.Drawing.Point(390, 40)
$btnBCsv.Size = New-Object System.Drawing.Size(70, 28)
$btnBCsv.Enabled = $false
$tabB.Controls.Add($btnBCsv)

$btnBJson = New-Object System.Windows.Forms.Button
$btnBJson.Text = 'JSON'
$btnBJson.Location = New-Object System.Drawing.Point(468, 40)
$btnBJson.Size = New-Object System.Drawing.Size(70, 28)
$btnBJson.Enabled = $false
$tabB.Controls.Add($btnBJson)

$lblBRes = LG $tabB '' 548 360 46
$lblBRes.ForeColor = [System.Drawing.Color]::Gray

$lvB = New-Object System.Windows.Forms.ListView
$lvB.Location = New-Object System.Drawing.Point(10, 76)
$lvB.Size = New-Object System.Drawing.Size(898, 284)
$lvB.View = 'Details'; $lvB.FullRowSelect = $true; $lvB.GridLines = $true
[void]$lvB.Columns.Add('NCU', 46)
[void]$lvB.Columns.Add('TCU', 46)
[void]$lvB.Columns.Add('SoC %', 52)
[void]$lvB.Columns.Add('SoH %', 52)
[void]$lvB.Columns.Add('Vbat mV', 66)
[void]$lvB.Columns.Add('Ibat mA', 66)
[void]$lvB.Columns.Add('Vpanel mV', 74)
[void]$lvB.Columns.Add('Ient mA', 64)
[void]$lvB.Columns.Add('Tbat C', 56)
[void]$lvB.Columns.Add('Tpcb C', 56)
[void]$lvB.Columns.Add('Dia', 40)
[void]$lvB.Columns.Add('Carga', 170)
[void]$lvB.Columns.Add('Estado', 210)
$tabB.Controls.Add($lvB)

$tabF = New-Object System.Windows.Forms.TabPage
$tabF.Text = 'Auditoria'
$tabs.TabPages.Add($tabF)

$gbAud = New-Object System.Windows.Forms.GroupBox
$gbAud.Text = ' Auditoria contra preset de referencia (lista solo las desviaciones) '
$gbAud.Location = New-Object System.Drawing.Point(10, 6)
$gbAud.Size = New-Object System.Drawing.Size(898, 182)
$tabF.Controls.Add($gbAud)

[void](LG $gbAud 'TCUs' 10 40)
$txtATcus = TG $gbAud '1-44' 52 22 110
$txtATcus.Add_MouseHover({ $ttW.SetToolTip($txtATcus, $AYUDA_TCUS) })

$btnPresetRef = New-Object System.Windows.Forms.Button
$btnPresetRef.Text = 'Preset ref...'
$btnPresetRef.Location = New-Object System.Drawing.Point(168, 19)
$btnPresetRef.Size = New-Object System.Drawing.Size(96, 26)
$gbAud.Controls.Add($btnPresetRef)

# La auditoria hacia SIEMPRE su propia pasada, asi que despues de un barrido se
# recorria la planta dos veces para los mismos datos. Con esto, lo que ya se ha
# leido en esta sesion no se vuelve a pedir.
$chkAudLec = New-Object System.Windows.Forms.CheckBox
$chkAudLec.Text = 'Usar la ultima lectura'
$chkAudLec.Checked = $true
$chkAudLec.Location = New-Object System.Drawing.Point(270, 21)
$chkAudLec.Size = New-Object System.Drawing.Size(142, 22)
$gbAud.Controls.Add($chkAudLec)

$lblPresetRef = LG $gbAud '(sin preset)' 416 92

# La auditoria puede leer por su cuenta, pero leer en 'Leer variable' da la
# segunda lectura de valores anomalos, el resumen de discrepancias y el
# historial. Esto lleva alli con las variables del preset ya puestas, y luego
# se audita contra esa lectura sin volver a tocar la planta.
$btnAudLeer = New-Object System.Windows.Forms.Button
$btnAudLeer.Text = 'Leer variables'
$btnAudLeer.Location = New-Object System.Drawing.Point(512, 19)
$btnAudLeer.Size = New-Object System.Drawing.Size(96, 26)
$gbAud.Controls.Add($btnAudLeer)
$lblPresetRef.ForeColor = [System.Drawing.Color]::Gray

# Las TCUs con desviaciones son justo las que hay que reescribir, y hasta ahora
# habia que apuntarlas a mano y teclear el rango en Escribir. Esto lo prepara:
# el preset en la tabla y el rango de las que fallaron. La pestana no escribe,
# como el resto: deja cargado y lleva alli.
$btnAudEscr = New-Object System.Windows.Forms.Button
$btnAudEscr.Text = 'Escribir...'
$btnAudEscr.Location = New-Object System.Drawing.Point(612, 19)
$btnAudEscr.Size = New-Object System.Drawing.Size(90, 26)
$btnAudEscr.Enabled = $false
$gbAud.Controls.Add($btnAudEscr)

$btnAud = New-Object System.Windows.Forms.Button
$btnAud.Text = 'AUDITAR'
$btnAud.Location = New-Object System.Drawing.Point(706, 18)
$btnAud.Size = New-Object System.Drawing.Size(82, 28)
$btnAud.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnAud.ForeColor = [System.Drawing.Color]::White
$gbAud.Controls.Add($btnAud)

$btnAudCsv = New-Object System.Windows.Forms.Button
$btnAudCsv.Text = 'CSV'
$btnAudCsv.Location = New-Object System.Drawing.Point(792, 18)
$btnAudCsv.Size = New-Object System.Drawing.Size(48, 28)
$btnAudCsv.Enabled = $false
$gbAud.Controls.Add($btnAudCsv)

$btnAudJson = New-Object System.Windows.Forms.Button
$btnAudJson.Text = 'JSON'
$btnAudJson.Location = New-Object System.Drawing.Point(844, 18)
$btnAudJson.Size = New-Object System.Drawing.Size(48, 28)
$btnAudJson.Enabled = $false
$gbAud.Controls.Add($btnAudJson)

$lvA = New-Object System.Windows.Forms.ListView
$lvA.Location = New-Object System.Drawing.Point(10, 52)
$lvA.Size = New-Object System.Drawing.Size(878, 120)
$lvA.View = 'Details'; $lvA.FullRowSelect = $true; $lvA.GridLines = $true
[void]$lvA.Columns.Add('NCU', 45)
[void]$lvA.Columns.Add('TCU', 50)
[void]$lvA.Columns.Add('Variable', 300)
[void]$lvA.Columns.Add('Esperado', 150)
[void]$lvA.Columns.Add('Leido', 150)
[void]$lvA.Columns.Add('Nota', 175)
$gbAud.Controls.Add($lvA)

$gbInvF = New-Object System.Windows.Forms.GroupBox
$gbInvF.Text = ' Inventario de flota (FW, numero de serie, MAC Xbee por rango) '
$gbInvF.Location = New-Object System.Drawing.Point(10, 194)
$gbInvF.Size = New-Object System.Drawing.Size(898, 168)
$tabF.Controls.Add($gbInvF)

[void](LG $gbInvF 'TCUs' 10 40)
$txtVTcus = TG $gbInvF '1-44' 52 22 110
$txtVTcus.Add_MouseHover({ $ttW.SetToolTip($txtVTcus, $AYUDA_TCUS) })

$btnInvF = New-Object System.Windows.Forms.Button
$btnInvF.Text = 'INVENTARIO'
$btnInvF.Location = New-Object System.Drawing.Point(172, 18)
$btnInvF.Size = New-Object System.Drawing.Size(125, 28)
$btnInvF.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnInvF.ForeColor = [System.Drawing.Color]::White
$gbInvF.Controls.Add($btnInvF)

$lblInvF = LG $gbInvF '' 310 320
$lblInvF.ForeColor = [System.Drawing.Color]::Gray

$btnInvFCsv = New-Object System.Windows.Forms.Button
$btnInvFCsv.Text = 'CSV'
$btnInvFCsv.Location = New-Object System.Drawing.Point(762, 18)
$btnInvFCsv.Size = New-Object System.Drawing.Size(60, 28)
$btnInvFCsv.Enabled = $false
$gbInvF.Controls.Add($btnInvFCsv)

$btnInvJson = New-Object System.Windows.Forms.Button
$btnInvJson.Text = 'JSON'
$btnInvJson.Location = New-Object System.Drawing.Point(826, 18)
$btnInvJson.Size = New-Object System.Drawing.Size(60, 28)
$btnInvJson.Enabled = $false
$gbInvF.Controls.Add($btnInvJson)

$lvV = New-Object System.Windows.Forms.ListView
$lvV.Location = New-Object System.Drawing.Point(10, 52)
$lvV.Size = New-Object System.Drawing.Size(878, 106)
$lvV.View = 'Details'; $lvV.FullRowSelect = $true; $lvV.GridLines = $true
[void]$lvV.Columns.Add('NCU', 45)
[void]$lvV.Columns.Add('TCU', 45)
[void]$lvV.Columns.Add('Num. serie', 150)
[void]$lvV.Columns.Add('MAC Xbee', 140)
[void]$lvV.Columns.Add('FW', 100)
[void]$lvV.Columns.Add('FW fabrica', 100)
[void]$lvV.Columns.Add('HW PCBA', 70)
[void]$lvV.Columns.Add('Fecha fab.', 90)
[void]$lvV.Columns.Add('Nota', 125)
$gbInvF.Controls.Add($lvV)

# ============================ TAB PEM (PUESTA EN MARCHA) ============================
$tabP = New-Object System.Windows.Forms.TabPage
$tabP.Text = 'PEM'
$tabs.TabPages.Add($tabP)

[void](LG $tabP 'TCUs' 10 38 18)
$txtPTcus = TG $tabP '1-5' 50 14 112
$txtPTcus.Add_MouseHover({ $ttW.SetToolTip($txtPTcus, $AYUDA_TCUS) })
[void](LG $tabP 'Pulso s' 172 46 18)
$txtPPulso = TG $tabP '5' 220 14 34
[void](LG $tabP 'Umbral deg' 262 68 18)
$txtPUmbral = TG $tabP '0.5' 332 14 38

$chkPViento = New-Object System.Windows.Forms.CheckBox
$chkPViento.Text = 'guardia viento'
$chkPViento.Checked = $true
$chkPViento.Location = New-Object System.Drawing.Point(380, 13)
$chkPViento.Size = New-Object System.Drawing.Size(105, 22)
$tabP.Controls.Add($chkPViento)

$btnPMotor = New-Object System.Windows.Forms.Button
$btnPMotor.Text = 'TEST DE MOTOR'
$btnPMotor.Location = New-Object System.Drawing.Point(492, 11)
$btnPMotor.Size = New-Object System.Drawing.Size(130, 26)
$btnPMotor.BackColor = [System.Drawing.Color]::FromArgb(0,120,60)
$btnPMotor.ForeColor = [System.Drawing.Color]::White
$tabP.Controls.Add($btnPMotor)

$btnPCsv = New-Object System.Windows.Forms.Button
$btnPCsv.Text = 'CSV'
$btnPCsv.Location = New-Object System.Drawing.Point(630, 11)
$btnPCsv.Size = New-Object System.Drawing.Size(64, 26)
$btnPCsv.Enabled = $false
$tabP.Controls.Add($btnPCsv)

$lblPResumen = LG $tabP '' 704 200 18
$lblPResumen.ForeColor = [System.Drawing.Color]::Gray

[void](LG $tabP 'Modo' 10 38 50)
$cbPModo = New-Object System.Windows.Forms.ComboBox
$cbPModo.Location = New-Object System.Drawing.Point(50, 46)
$cbPModo.Size = New-Object System.Drawing.Size(90, 22)
$cbPModo.DropDownStyle = 'DropDownList'
foreach ($m in @('AUTO','MANUAL','OFF')) { [void]$cbPModo.Items.Add($m) }
$cbPModo.SelectedIndex = 0
$tabP.Controls.Add($cbPModo)

$btnPModo = New-Object System.Windows.Forms.Button
$btnPModo.Text = 'APLICAR MODO'
$btnPModo.Location = New-Object System.Drawing.Point(148, 44)
$btnPModo.Size = New-Object System.Drawing.Size(118, 24)
$tabP.Controls.Add($btnPModo)

$btnPClear = New-Object System.Windows.Forms.Button
$btnPClear.Text = 'LIMPIAR ALARMAS'
$btnPClear.Location = New-Object System.Drawing.Point(274, 44)
$btnPClear.Size = New-Object System.Drawing.Size(122, 24)
$tabP.Controls.Add($btnPClear)

[void](LG $tabP 'Safe pos' 408 52 50)
$cbPStow = New-Object System.Windows.Forms.ComboBox
$cbPStow.Location = New-Object System.Drawing.Point(462, 46)
$cbPStow.Size = New-Object System.Drawing.Size(40, 22)
$cbPStow.DropDownStyle = 'DropDownList'
foreach ($m in 1..7) { [void]$cbPStow.Items.Add("$m") }
$cbPStow.SelectedIndex = 0
$tabP.Controls.Add($cbPStow)

$btnPStow = New-Object System.Windows.Forms.Button
$btnPStow.Text = 'STOW'
$btnPStow.Location = New-Object System.Drawing.Point(510, 44)
$btnPStow.Size = New-Object System.Drawing.Size(64, 24)
$btnPStow.BackColor = [System.Drawing.Color]::FromArgb(160,80,0)
$btnPStow.ForeColor = [System.Drawing.Color]::White
$tabP.Controls.Add($btnPStow)

$btnPUnstow = New-Object System.Windows.Forms.Button
$btnPUnstow.Text = 'QUITAR STOW'
$btnPUnstow.Location = New-Object System.Drawing.Point(580, 44)
$btnPUnstow.Size = New-Object System.Drawing.Size(108, 24)
$tabP.Controls.Add($btnPUnstow)

[void](LG $tabP 'Comisionado:' 10 82 82)
$btnPComis = New-Object System.Windows.Forms.Button
$btnPComis.Text = 'ESTADO Y MODO'
$btnPComis.Location = New-Object System.Drawing.Point(94, 76)
$btnPComis.Size = New-Object System.Drawing.Size(108, 24)
$tabP.Controls.Add($btnPComis)

$cbPComis = New-Object System.Windows.Forms.ComboBox
$cbPComis.Location = New-Object System.Drawing.Point(210, 78)
$cbPComis.Size = New-Object System.Drawing.Size(150, 22)
$cbPComis.DropDownStyle = 'DropDownList'
foreach ($k in @(0,1,2,3)) { [void]$cbPComis.Items.Add("$k - $($ESTADOS_COMIS[$k])") }
$cbPComis.SelectedIndex = 0
$tabP.Controls.Add($cbPComis)

$btnPComisSet = New-Object System.Windows.Forms.Button
$btnPComisSet.Text = 'FIJAR'
$btnPComisSet.Location = New-Object System.Drawing.Point(368, 76)
$btnPComisSet.Size = New-Object System.Drawing.Size(64, 24)
$tabP.Controls.Add($btnPComisSet)

$lblPNota = LG $tabP 'Guardia de viento, parada garantizada y verificacion por efecto.' 442 296 82
$lblPNota.ForeColor = [System.Drawing.Color]::Gray

$btnPSeg = New-Object System.Windows.Forms.Button
$btnPSeg.Text = 'SEGUIMIENTO JSON'
$btnPSeg.Location = New-Object System.Drawing.Point(744, 74)
$btnPSeg.Size = New-Object System.Drawing.Size(164, 26)
$btnPSeg.Enabled = $false
$tabP.Controls.Add($btnPSeg)

$lvP = New-Object System.Windows.Forms.ListView
$lvP.Location = New-Object System.Drawing.Point(10, 108)
$lvP.Size = New-Object System.Drawing.Size(898, 252)
$lvP.View = 'Details'; $lvP.FullRowSelect = $true; $lvP.GridLines = $true
[void]$lvP.Columns.Add('NCU', 45)
[void]$lvP.Columns.Add('TCU', 50)
[void]$lvP.Columns.Add('Resultado', 100)
[void]$lvP.Columns.Add('Detalle', 685)
$tabP.Controls.Add($lvP)

# ============================ TAB FIRMWARE ============================
$tabFW = New-Object System.Windows.Forms.TabPage
$tabFW.Text = 'Firmware'
$tabs.TabPages.Add($tabFW)

[void](LG $tabFW 'Version objetivo' 10 100)
$txtFwObj = TG $tabFW 'v1.6.0' 112 22 90
[void](LG $tabFW 'min/TCU' 700 52)
$txtFwMin = TG $tabFW '20' 754 22 34

$btnFwPlan = New-Object System.Windows.Forms.Button
$btnFwPlan.Text = 'PLAN DE ACTUALIZACION'
$btnFwPlan.Location = New-Object System.Drawing.Point(212, 18)
$btnFwPlan.Size = New-Object System.Drawing.Size(180, 28)
$btnFwPlan.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnFwPlan.ForeColor = [System.Drawing.Color]::White
$tabFW.Controls.Add($btnFwPlan)

$btnFwVerif = New-Object System.Windows.Forms.Button
$btnFwVerif.Text = 'VERIFICAR TRAS ACTUALIZAR'
$btnFwVerif.Location = New-Object System.Drawing.Point(400, 18)
$btnFwVerif.Size = New-Object System.Drawing.Size(200, 28)
$btnFwVerif.Enabled = $false
$tabFW.Controls.Add($btnFwVerif)

$btnFwPrep = New-Object System.Windows.Forms.Button
$btnFwPrep.Text = 'PREPARAR 1 TCU (captura OTA)'
$btnFwPrep.Location = New-Object System.Drawing.Point(212, 51)
$btnFwPrep.Size = New-Object System.Drawing.Size(210, 26)
$tabFW.Controls.Add($btnFwPrep)
[void](LG $tabFW 'NCU' 432 30 56)
$txtFwNcu = TG $tabFW '1' 464 52 34
[void](LG $tabFW 'TCU' 506 30 56)
$txtFwTcu = TG $tabFW '1' 538 52 40

$btnFwCsv = New-Object System.Windows.Forms.Button
$btnFwCsv.Text = 'CSV'
$btnFwCsv.Location = New-Object System.Drawing.Point(798, 18)
$btnFwCsv.Size = New-Object System.Drawing.Size(110, 28)
$btnFwCsv.Enabled = $false
$tabFW.Controls.Add($btnFwCsv)

# fila de abajo: en la de arriba se solapaba con 'min/TCU' y su cuadro
$lblFw = LG $tabFW 'Haz primero un Inventario (pestana Flota) y luego el plan.' 590 318 56
$lblFw.ForeColor = [System.Drawing.Color]::Gray

$lblFwNota = LG $tabFW 'El plan sale por VENTANAS del updater (una por NCU + gateway, y se abren a la vez): cada una dice que rangos pegarle y cuanto tarda, y al final el total. PREPARAR comprueba viento, comunicacion y alarmas, y hace backup antes de actualizar/capturar una TCU.' 10 898 82
$lblFwNota.ForeColor = [System.Drawing.Color]::Gray

$lvFW = New-Object System.Windows.Forms.ListView
$lvFW.Location = New-Object System.Drawing.Point(10, 104)
$lvFW.Size = New-Object System.Drawing.Size(898, 256)
$lvFW.View = 'Details'; $lvFW.FullRowSelect = $true; $lvFW.GridLines = $true
[void]$lvFW.Columns.Add('NCU', 50)
# La tabla lleva tres cosas a la vez: la VENTANA del updater que hay que abrir,
# los rangos que se le PEGAN dentro y las TCUs pendientes una a una. Sin esta
# columna, una ventana de una sola TCU salia identica columna a columna a la
# fila de esa TCU y parecia la misma repetida.
[void]$lvFW.Columns.Add('Fila', 88)
[void]$lvFW.Columns.Add('IP', 110)
[void]$lvFW.Columns.Add('Gateway', 70)
[void]$lvFW.Columns.Add('Desde', 60)
[void]$lvFW.Columns.Add('Hasta', 60)
[void]$lvFW.Columns.Add('TCUs', 55)
[void]$lvFW.Columns.Add('Estado / nota', 400)
$tabFW.Controls.Add($lvFW)

# ============================ TAB CIERRE ============================
# Una TCU actualizada no esta terminada. Aqui se ve que le falta y desde aqui se
# PREPARA lo que toca en la pestana que corresponde: esta no escribe nada.
$tabC = New-Object System.Windows.Forms.TabPage
$tabC.Text = 'Cierre'
$tabs.TabPages.Add($tabC)

# ============================ TAB TRABAJOS ============================
# Lo que se ha hecho en campo, guardado y recuperable. Cada operacion que
# termina deja aqui su copia sola: si en medio de una campana de firmware haces
# un diagnostico, lo de antes sigue estando.
$tabT = New-Object System.Windows.Forms.TabPage
$tabT.Text = 'Trabajos'
$tabs.TabPages.Add($tabT)

$lblTInfo = LG $tabT 'Cada diagnostico, inventario, auditoria, lectura y tabla de baterias se guarda solo en trabajos/. Elige uno y CARGAR lo devuelve a su pestana.' 10 890 16
$lblTInfo.ForeColor = [System.Drawing.Color]::Gray

$btnTRef = New-Object System.Windows.Forms.Button
$btnTRef.Text = 'ACTUALIZAR'
$btnTRef.Location = New-Object System.Drawing.Point(10, 40)
$btnTRef.Size = New-Object System.Drawing.Size(110, 28)
$tabT.Controls.Add($btnTRef)

$btnTCargar = New-Object System.Windows.Forms.Button
$btnTCargar.Text = 'CARGAR'
$btnTCargar.Location = New-Object System.Drawing.Point(128, 40)
$btnTCargar.Size = New-Object System.Drawing.Size(110, 28)
$btnTCargar.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnTCargar.ForeColor = [System.Drawing.Color]::White
$tabT.Controls.Add($btnTCargar)

$btnTGuardar = New-Object System.Windows.Forms.Button
$btnTGuardar.Text = 'GUARDAR LO DE AHORA'
$btnTGuardar.Location = New-Object System.Drawing.Point(246, 40)
$btnTGuardar.Size = New-Object System.Drawing.Size(160, 28)
$tabT.Controls.Add($btnTGuardar)

$btnTBorrar = New-Object System.Windows.Forms.Button
$btnTBorrar.Text = 'Borrar'
$btnTBorrar.Location = New-Object System.Drawing.Point(414, 40)
$btnTBorrar.Size = New-Object System.Drawing.Size(80, 28)
$tabT.Controls.Add($btnTBorrar)

$btnTCarpeta = New-Object System.Windows.Forms.Button
$btnTCarpeta.Text = 'Abrir carpeta'
$btnTCarpeta.Location = New-Object System.Drawing.Point(502, 40)
$btnTCarpeta.Size = New-Object System.Drawing.Size(110, 28)
$tabT.Controls.Add($btnTCarpeta)

$lblTRes = LG $tabT '' 622 286 46
$lblTRes.ForeColor = [System.Drawing.Color]::Gray

$lvT = New-Object System.Windows.Forms.ListView
$lvT.Location = New-Object System.Drawing.Point(10, 76)
$lvT.Size = New-Object System.Drawing.Size(898, 284)
$lvT.View = 'Details'; $lvT.FullRowSelect = $true; $lvT.GridLines = $true
[void]$lvT.Columns.Add('Fecha', 140)
[void]$lvT.Columns.Add('Tipo', 100)
[void]$lvT.Columns.Add('Planta', 200)
[void]$lvT.Columns.Add('Filas', 55)
[void]$lvT.Columns.Add('Tecnico', 90)
[void]$lvT.Columns.Add('Nota', 300)
$tabT.Controls.Add($lvT)

$lblCInfo = LG $tabC 'Cada TCU actualizada entra aqui hasta tener parametros, NVM y modo AUTO. Se rellena sola al verificar, auditar, guardar en NVM y diagnosticar.' 10 890 16
$lblCInfo.ForeColor = [System.Drawing.Color]::Gray

$btnCPrep = New-Object System.Windows.Forms.Button
$btnCPrep.Text = 'PREPARAR ESCRITURA'
$btnCPrep.Location = New-Object System.Drawing.Point(10, 40)
$btnCPrep.Size = New-Object System.Drawing.Size(150, 28)
$btnCPrep.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnCPrep.ForeColor = [System.Drawing.Color]::White
$tabC.Controls.Add($btnCPrep)

$btnCModo = New-Object System.Windows.Forms.Button
$btnCModo.Text = 'PREPARAR MODO AUTO'
$btnCModo.Location = New-Object System.Drawing.Point(166, 40)
$btnCModo.Size = New-Object System.Drawing.Size(150, 28)
$tabC.Controls.Add($btnCModo)

# La lista se llena sola al VERIFICAR, pero el firmware se instala con el
# updater del fabricante, fuera de esta herramienta: si ese dia no se pasa por
# la pestana Firmware, lo actualizado no entra en ningun sitio. Con esto se
# apunta a mano, que es lo que hace falta para no olvidarse.
$btnCAdd = New-Object System.Windows.Forms.Button
$btnCAdd.Text = 'Anadir TCUs...'
$btnCAdd.Location = New-Object System.Drawing.Point(322, 40)
$btnCAdd.Size = New-Object System.Drawing.Size(112, 28)
$tabC.Controls.Add($btnCAdd)

$btnCRef = New-Object System.Windows.Forms.Button
$btnCRef.Text = 'Refrescar'
$btnCRef.Location = New-Object System.Drawing.Point(440, 40)
$btnCRef.Size = New-Object System.Drawing.Size(76, 28)
$tabC.Controls.Add($btnCRef)

$btnCQuitar = New-Object System.Windows.Forms.Button
$btnCQuitar.Text = 'Quitar de la lista'
$btnCQuitar.Location = New-Object System.Drawing.Point(522, 40)
$btnCQuitar.Size = New-Object System.Drawing.Size(116, 28)
$tabC.Controls.Add($btnCQuitar)

$btnCCsv = New-Object System.Windows.Forms.Button
$btnCCsv.Text = 'CSV'
$btnCCsv.Location = New-Object System.Drawing.Point(644, 40)
$btnCCsv.Size = New-Object System.Drawing.Size(60, 28)
$tabC.Controls.Add($btnCCsv)

$lblCRes = LG $tabC '' 712 196 46
$lblCRes.ForeColor = [System.Drawing.Color]::Gray

$lvC = New-Object System.Windows.Forms.ListView
$lvC.Location = New-Object System.Drawing.Point(10, 76)
$lvC.Size = New-Object System.Drawing.Size(898, 284)
$lvC.View = 'Details'; $lvC.FullRowSelect = $true; $lvC.GridLines = $true; $lvC.MultiSelect = $true
[void]$lvC.Columns.Add('NCU', 55)
[void]$lvC.Columns.Add('TCU', 55)
[void]$lvC.Columns.Add('Firmware', 130)
[void]$lvC.Columns.Add('Parametros', 100)
[void]$lvC.Columns.Add('NVM', 80)
[void]$lvC.Columns.Add('Modo', 80)
[void]$lvC.Columns.Add('Desde', 120)
[void]$lvC.Columns.Add('Estado', 260)
$tabC.Controls.Add($lvC)

# ============================ TAB SAT ============================
$tabSAT = New-Object System.Windows.Forms.TabPage
$tabSAT.Text = 'SAT'
$tabs.TabPages.Add($tabSAT)

# Los anchos van holgados: con el tema oscuro la letra es mayor y antes se
# comian la unidad ("Muestreo TCU" en vez de "Muestreo TCU s").
[void](LG $tabSAT 'Muestreo TCU s' 10 100)
$txtSatInt = TG $tabSAT '60' 114 22 42
[void](LG $tabSAT 'Comms s' 164 58)
$txtSatCom = TG $tabSAT '15' 226 22 38
# Duracion con unidad: el ensayo del anexo son 7 dias, pero para comprobar el
# montaje antes de arrancarlo de verdad se quieren 20 minutos.
[void](LG $tabSAT 'Duracion' 272 56)
$txtSatDur = TG $tabSAT '7' 332 22 34
$cbSatUnid = New-Object System.Windows.Forms.ComboBox
$cbSatUnid.Location = New-Object System.Drawing.Point(370, 21)
$cbSatUnid.Size = New-Object System.Drawing.Size(66, 22)
$cbSatUnid.DropDownStyle = 'DropDownList'
foreach ($u in @('min','horas','dias')) { [void]$cbSatUnid.Items.Add($u) }
$cbSatUnid.SelectedItem = 'dias'
$tabSAT.Controls.Add($cbSatUnid)

$btnSatIni = New-Object System.Windows.Forms.Button
$btnSatIni.Text = 'INICIAR REGISTRO'
$btnSatIni.Location = New-Object System.Drawing.Point(444, 18)
$btnSatIni.Size = New-Object System.Drawing.Size(160, 28)
$btnSatIni.BackColor = [System.Drawing.Color]::FromArgb(0,120,60)
$btnSatIni.ForeColor = [System.Drawing.Color]::White
$tabSAT.Controls.Add($btnSatIni)

$btnSatFin = New-Object System.Windows.Forms.Button
$btnSatFin.Text = 'PARAR'
$btnSatFin.Location = New-Object System.Drawing.Point(612, 18)
$btnSatFin.Size = New-Object System.Drawing.Size(80, 28)
$btnSatFin.Enabled = $false
$tabSAT.Controls.Add($btnSatFin)

$btnSatAnal = New-Object System.Windows.Forms.Button
$btnSatAnal.Text = 'ANALIZAR Y EMITIR'
$btnSatAnal.Location = New-Object System.Drawing.Point(700, 18)
$btnSatAnal.Size = New-Object System.Drawing.Size(160, 28)
$btnSatAnal.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnSatAnal.ForeColor = [System.Drawing.Color]::White
$tabSAT.Controls.Add($btnSatAnal)

[void](LG $tabSAT 'Ensayo' 10 44 57)
$cbSatEnsayo = New-Object System.Windows.Forms.ComboBox
$cbSatEnsayo.Location = New-Object System.Drawing.Point(58, 53)
$cbSatEnsayo.Size = New-Object System.Drawing.Size(200, 22)
$cbSatEnsayo.DropDownStyle = 'DropDownList'
foreach ($e in @('D.2.1 abanderamiento por viento','D.2.2 abanderamiento por nieve',
                 'D.2.3 abanderamiento por fallo de comunicacion','D.2.4 abanderamiento por baja bateria',
                 'D.2.5 abanderamiento por falta de alimentacion NCU','D.3 posicion objetivo manual')) {
    [void]$cbSatEnsayo.Items.Add($e)
}
$cbSatEnsayo.SelectedIndex = 0
$tabSAT.Controls.Add($cbSatEnsayo)

$btnSatCron = New-Object System.Windows.Forms.Button
$btnSatCron.Text = 'INICIAR CRONOMETRO'
$btnSatCron.Location = New-Object System.Drawing.Point(266, 51)
$btnSatCron.Size = New-Object System.Drawing.Size(170, 26)
$btnSatCron.BackColor = [System.Drawing.Color]::FromArgb(160,80,0)
$btnSatCron.ForeColor = [System.Drawing.Color]::White
$tabSAT.Controls.Add($btnSatCron)

$btnSatCronFin = New-Object System.Windows.Forms.Button
$btnSatCronFin.Text = 'PARAR Y EMITIR'
$btnSatCronFin.Location = New-Object System.Drawing.Point(444, 51)
$btnSatCronFin.Size = New-Object System.Drawing.Size(140, 26)
$btnSatCronFin.Enabled = $false
$tabSAT.Controls.Add($btnSatCronFin)

$btnSatHoja = New-Object System.Windows.Forms.Button
$btnSatHoja.Text = 'HOJA D.1.2'
$btnSatHoja.Location = New-Object System.Drawing.Point(592, 51)
$btnSatHoja.Size = New-Object System.Drawing.Size(106, 26)
$tabSAT.Controls.Add($btnSatHoja)

# Ritmo y tope del cronometro. El tope evita dejarlo corriendo toda la noche
# si el ensayo se alarga o alguien se olvida de pararlo; a 0 no para solo.
[void](LG $tabSAT 'cada s' 700 48 57)
$txtCronInt = TG $tabSAT '3' 752 51 30
[void](LG $tabSAT 'max min' 790 56 57)
$txtCronMax = TG $tabSAT '30' 850 51 34

# Criterios de aceptacion: van editables porque son de contrato, no del
# equipo. El registro no depende de ellos, asi que cambiarlos y volver a
# analizar no obliga a repetir el ensayo.
[void](LG $tabSAT 'Precision deg' 10 78 86)
$txtSatTol = TG $tabSAT '1' 92 84 34
[void](LG $tabSAT 'Disp. TCU %' 136 70 86)
$txtSatDTcu = TG $tabSAT '99' 210 84 40
[void](LG $tabSAT 'RSU/NCU %' 258 66 86)
$txtSatDRsu = TG $tabSAT '99,5' 328 84 42
[void](LG $tabSAT 'Comms TCU %' 380 78 86)
$txtSatCTcu = TG $tabSAT '98,5' 462 84 42
[void](LG $tabSAT 'Comms RSU %' 512 78 86)
$txtSatCRsu = TG $tabSAT '99,5' 594 84 42
[void](LG $tabSAT 'Ventana D.4 s' 644 84 86)
$txtSatVent = TG $tabSAT '120' 732 84 38

$lblSat = LG $tabSAT 'Anexo 4. El registro de arriba cubre D.1.1, D.3.4 y D.4; el cronometro de abajo, los abanderamientos. Deja la ventana abierta mientras dure el ensayo.' 10 890 112
$lblSat.ForeColor = [System.Drawing.Color]::Gray

$lvSat = New-Object System.Windows.Forms.ListView
$lvSat.Location = New-Object System.Drawing.Point(10, 136)
$lvSat.Size = New-Object System.Drawing.Size(898, 224)
$lvSat.View = 'Details'; $lvSat.FullRowSelect = $true; $lvSat.GridLines = $true
[void]$lvSat.Columns.Add('Hora', 130)
[void]$lvSat.Columns.Add('Ensayo', 110)
[void]$lvSat.Columns.Add('Detalle', 640)
$tabSAT.Controls.Add($lvSat)

# ============================ TAB HSU (METEO) ============================
$tabH = New-Object System.Windows.Forms.TabPage
$tabH.Text = 'HSU'
$tabs.TabPages.Add($tabH)

[void](LG $tabH 'Esclavo HSU' 10 78)
$txtHSlave = TG $tabH '185' 92 22 45

$btnHMeteo = New-Object System.Windows.Forms.Button
$btnHMeteo.Text = 'LEER METEO'
$btnHMeteo.Location = New-Object System.Drawing.Point(155, 18)
$btnHMeteo.Size = New-Object System.Drawing.Size(120, 28)
$btnHMeteo.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnHMeteo.ForeColor = [System.Drawing.Color]::White
$tabH.Controls.Add($btnHMeteo)

$btnHConfig = New-Object System.Windows.Forms.Button
$btnHConfig.Text = 'LEER CONFIG'
$btnHConfig.Location = New-Object System.Drawing.Point(285, 18)
$btnHConfig.Size = New-Object System.Drawing.Size(120, 28)
$tabH.Controls.Add($btnHConfig)

$btnHCaja = New-Object System.Windows.Forms.Button
$btnHCaja.Text = 'CAJA NEGRA 24h -> CSV'
$btnHCaja.Location = New-Object System.Drawing.Point(415, 18)
$btnHCaja.Size = New-Object System.Drawing.Size(175, 28)
$tabH.Controls.Add($btnHCaja)

$btnHReloj = New-Object System.Windows.Forms.Button
$btnHReloj.Text = 'RELOJ UTC'
$btnHReloj.Location = New-Object System.Drawing.Point(600, 18)
$btnHReloj.Size = New-Object System.Drawing.Size(95, 28)
$btnHReloj.BackColor = [System.Drawing.Color]::FromArgb(0,120,60)
$btnHReloj.ForeColor = [System.Drawing.Color]::White
$tabH.Controls.Add($btnHReloj)

$btnHNieve = New-Object System.Windows.Forms.Button
$btnHNieve.Text = 'CALIBRAR NIEVE'
$btnHNieve.Location = New-Object System.Drawing.Point(705, 18)
$btnHNieve.Size = New-Object System.Drawing.Size(125, 28)
$tabH.Controls.Add($btnHNieve)

$btnHNvm = New-Object System.Windows.Forms.Button
$btnHNvm.Text = 'NVM'
$btnHNvm.Location = New-Object System.Drawing.Point(840, 18)
$btnHNvm.Size = New-Object System.Drawing.Size(68, 28)
$btnHNvm.BackColor = [System.Drawing.Color]::FromArgb(160,80,0)
$btnHNvm.ForeColor = [System.Drawing.Color]::White
$tabH.Controls.Add($btnHNvm)

[void](LG $tabH 'Umbral ON [m/s]' 10 100 56)
$txtHMid = TG $tabH '' 112 52 55
[void](LG $tabH 'OFF [m/s]' 178 62 56)
$txtHLow = TG $tabH '' 244 52 55
[void](LG $tabH 't ON [s]' 310 50 56)
$txtHTMid = TG $tabH '' 362 52 45
[void](LG $tabH 't OFF [s]' 418 52 56)
$txtHTLow = TG $tabH '' 474 52 45

$btnHUmb = New-Object System.Windows.Forms.Button
$btnHUmb.Text = 'ESCRIBIR UMBRALES'
$btnHUmb.Location = New-Object System.Drawing.Point(535, 49)
$btnHUmb.Size = New-Object System.Drawing.Size(155, 26)
$btnHUmb.BackColor = [System.Drawing.Color]::FromArgb(0,120,60)
$btnHUmb.ForeColor = [System.Drawing.Color]::White
$tabH.Controls.Add($btnHUmb)

$lblHNota = LG $tabH 'La HSU cuelga de un gateway concreto: usa una entrada GW (o puerto manual), no (auto).' 700 210 46
$lblHNota.ForeColor = [System.Drawing.Color]::Gray

# buscador de HSUs de la planta: escanea los bloques compactos de las NCUs
$btnHBuscar = New-Object System.Windows.Forms.Button
$btnHBuscar.Text = 'BUSCAR HSUs'
$btnHBuscar.Location = New-Object System.Drawing.Point(10, 80)
$btnHBuscar.Size = New-Object System.Drawing.Size(115, 26)
$tabH.Controls.Add($btnHBuscar)
$cbHsuSel = New-Object System.Windows.Forms.ComboBox
$cbHsuSel.Location = New-Object System.Drawing.Point(133, 82)
$cbHsuSel.Size = New-Object System.Drawing.Size(300, 22)
$cbHsuSel.DropDownStyle = 'DropDownList'
$tabH.Controls.Add($cbHsuSel)
$btnHEsclavo = New-Object System.Windows.Forms.Button
$btnHEsclavo.Text = 'BUSCAR ESCLAVO'
$btnHEsclavo.Location = New-Object System.Drawing.Point(443, 80)
$btnHEsclavo.Size = New-Object System.Drawing.Size(130, 26)
$tabH.Controls.Add($btnHEsclavo)

$lblHSel = LG $tabH 'Escanea la planta para listar sus HSUs y de que NCU cuelga cada una.' 581 327 85
$lblHSel.ForeColor = [System.Drawing.Color]::Gray

$lvH = New-Object System.Windows.Forms.ListView
$lvH.Location = New-Object System.Drawing.Point(10, 112)
$lvH.Size = New-Object System.Drawing.Size(898, 248)
$lvH.View = 'Details'; $lvH.FullRowSelect = $true; $lvH.GridLines = $true
[void]$lvH.Columns.Add('Campo', 240)
[void]$lvH.Columns.Add('Valor', 160)
[void]$lvH.Columns.Add('Nota', 480)
$tabH.Controls.Add($lvH)

# ============================ TAB UTILIDADES ============================
$tabU = New-Object System.Windows.Forms.TabPage
$tabU.Text = 'Utilidades'
$tabs.TabPages.Add($tabU)

$gbSync = New-Object System.Windows.Forms.GroupBox
$gbSync.Text = ' Sincronizar fecha/hora con el PC (40001-40006 + 40007 bits 0/1) '
$gbSync.Location = New-Object System.Drawing.Point(10, 12)
$gbSync.Size = New-Object System.Drawing.Size(898, 62)
$tabU.Controls.Add($gbSync)

[void](LG $gbSync 'TCUs' 10 40)
$txtSTcus = TG $gbSync '1-44' 52 22 124
$txtSTcus.Add_MouseHover({ $ttW.SetToolTip($txtSTcus, $AYUDA_TCUS) })

$chkSVerif = New-Object System.Windows.Forms.CheckBox
$chkSVerif.Text = 'Verificar reloj tras sincronizar (lee 30079)'
$chkSVerif.Location = New-Object System.Drawing.Point(200, 22)
$chkSVerif.Size = New-Object System.Drawing.Size(280, 22)
$chkSVerif.Checked = $true
$gbSync.Controls.Add($chkSVerif)

$btnSync = New-Object System.Windows.Forms.Button
$btnSync.Text = 'SINCRONIZAR RELOJ'
$btnSync.Location = New-Object System.Drawing.Point(720, 18)
$btnSync.Size = New-Object System.Drawing.Size(165, 30)
$btnSync.BackColor = [System.Drawing.Color]::FromArgb(0,120,60)
$btnSync.ForeColor = [System.Drawing.Color]::White
$gbSync.Controls.Add($btnSync)

$gbIdent = New-Object System.Windows.Forms.GroupBox
$gbIdent.Text = ' Identificacion de TCU (bloque 30300+: FW, serie, MAC Xbee, fabricacion) '
$gbIdent.Location = New-Object System.Drawing.Point(10, 84)
$gbIdent.Size = New-Object System.Drawing.Size(898, 280)
$tabU.Controls.Add($gbIdent)

[void](LG $gbIdent 'TCU' 10 35)
$txtITcu = TG $gbIdent '1' 48 22 50

$btnIdent = New-Object System.Windows.Forms.Button
$btnIdent.Text = 'IDENTIFICAR'
$btnIdent.Location = New-Object System.Drawing.Point(120, 18)
$btnIdent.Size = New-Object System.Drawing.Size(130, 28)
$btnIdent.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnIdent.ForeColor = [System.Drawing.Color]::White
$gbIdent.Controls.Add($btnIdent)

$btnICsv = New-Object System.Windows.Forms.Button
$btnICsv.Text = 'Exportar CSV'
$btnICsv.Location = New-Object System.Drawing.Point(760, 18)
$btnICsv.Size = New-Object System.Drawing.Size(118, 28)
$btnICsv.Enabled = $false
$gbIdent.Controls.Add($btnICsv)

$btnHist = New-Object System.Windows.Forms.Button
$btnHist.Text = 'HISTORIAL LOCAL...'
$btnHist.Location = New-Object System.Drawing.Point(266, 18)
$btnHist.Size = New-Object System.Drawing.Size(160, 28)
$gbIdent.Controls.Add($btnHist)

$lvI = New-Object System.Windows.Forms.ListView
$lvI.Location = New-Object System.Drawing.Point(10, 52)
$lvI.Size = New-Object System.Drawing.Size(878, 218)
$lvI.View = 'Details'; $lvI.FullRowSelect = $true; $lvI.GridLines = $true
[void]$lvI.Columns.Add('Campo', 300)
[void]$lvI.Columns.Add('Valor', 570)
$gbIdent.Controls.Add($lvI)

# --- consola comun ---
$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.Location = New-Object System.Drawing.Point(10, 480)
$rtb.Size = New-Object System.Drawing.Size(925, 255)
$rtb.ReadOnly = $true
$rtb.BackColor = [System.Drawing.Color]::FromArgb(20,20,24)
$rtb.ForeColor = [System.Drawing.Color]::Gainsboro
$rtb.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($rtb)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = 'Guardar log'
$btnLog.Location = New-Object System.Drawing.Point(825, 741)
$btnLog.Size = New-Object System.Drawing.Size(110, 28)
$form.Controls.Add($btnLog)

# Ctrl+K tampoco se ve, asi que el buscador tiene su boton.
$btnBuscar = New-Object System.Windows.Forms.Button
$btnBuscar.Text = 'Buscar  Ctrl+K'
$btnBuscar.Location = New-Object System.Drawing.Point(366, 741)
$btnBuscar.Size = New-Object System.Drawing.Size(104, 28)
$form.Controls.Add($btnBuscar)

# Limpiar la consola estaba solo en el menu del boton derecho, que no se ve.
$btnLimpiar = New-Object System.Windows.Forms.Button
$btnLimpiar.Text = 'Limpiar'
$btnLimpiar.Location = New-Object System.Drawing.Point(476, 741)
$btnLimpiar.Size = New-Object System.Drawing.Size(100, 28)
$form.Controls.Add($btnLimpiar)

$btnUsuarios = New-Object System.Windows.Forms.Button
$btnUsuarios.Text = 'Usuarios...'
$btnUsuarios.Location = New-Object System.Drawing.Point(586, 741)
$btnUsuarios.Size = New-Object System.Drawing.Size(105, 28)
$form.Controls.Add($btnUsuarios)

$btnInforme = New-Object System.Windows.Forms.Button
$btnInforme.Text = 'INFORME HTML'
$btnInforme.Location = New-Object System.Drawing.Point(700, 741)
$btnInforme.Size = New-Object System.Drawing.Size(118, 28)
$form.Controls.Add($btnInforme)

# Barra de avance: comparte sitio con el aviso del log, que solo estorba
# mientras hay una operacion en curso. Se muestra al empezar y se esconde al
# acabar, asi no crece la ventana.
$pbProg = New-Object System.Windows.Forms.ProgressBar
$pbProg.Location = New-Object System.Drawing.Point(10, 745)
$pbProg.Size = New-Object System.Drawing.Size(190, 18)
$pbProg.Minimum = 0; $pbProg.Maximum = 1000
$pbProg.Visible = $false
$form.Controls.Add($pbProg)

$lblProg = New-Object System.Windows.Forms.Label
$lblProg.Location = New-Object System.Drawing.Point(208, 746)
$lblProg.Size = New-Object System.Drawing.Size(148, 20)
$lblProg.Visible = $false
$form.Controls.Add($lblProg)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(10, 746)
$lblLog.Size = New-Object System.Drawing.Size(346, 20)
$lblLog.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblLog)

# ---------------------------------------------------------------------------
#  Filtro y orden en las tablas de resultados
# ---------------------------------------------------------------------------
# El informe HTML ya filtraba por columna y en pantalla no se podia. Se hace al
# pulsar la cabecera de la columna, que no estaba usada para nada, y sin mover
# ni un pixel del diseno: en estas pestanas no sobra sitio para una fila de
# filtros como la del HTML.
#
# La lista original se guarda en $lv.Tag. Cada tabla la rellena su propio
# handler con Items.Add, asi que no hay un punto unico donde enterarse: se
# detecta comparando cuantas filas dejamos la ultima vez con las que hay ahora.
# Si no cuadran, la tabla se ha repintado y se vuelve a partir de cero.

# Decide que filas pasan los filtros activos. Pura: se prueba sin ventana.
# $filtros: indice de columna -> lista de valores admitidos.
function Lv-Pasa($textos, $filtros) {
    foreach ($k in $filtros.Keys) {
        $col = [int]$k
        if ($col -ge @($textos).Count) { return $false }
        if (@($filtros[$k]) -notcontains "$($textos[$col])") { return $false }
    }
    return $true
}

# Orden natural: si toda la columna son numeros, ordena como numeros; si no,
# como texto. Sin esto la TCU 10 va delante de la 9.
function Lv-Clave([string]$t) {
    $d = 0.0
    if ([double]::TryParse($t.Replace(',', '.'), [Globalization.NumberStyles]::Float, $INV, [ref]$d)) { return $d }
    return [double]::NaN
}

function Lv-Estado($lv) {
    if ($null -eq $lv.Tag -or -not ($lv.Tag -is [hashtable])) {
        $lv.Tag = @{orig=@(); filtros=@{}; dejadas=-1; cab=@()}
    }
    return $lv.Tag
}

# Las cabeceras de verdad, a partir de la copia guardada y de lo que hay ahora
# en la tabla. Si la tabla ha cambiado de columnas -'Leer variable' las rehace
# en cada lectura, una por variable- la copia vieja NO vale: se estaba
# escribiendo encima y los tres primeros nombres salian 'TCU', 'Valor' y
# 'Estado' en vez de la variable leida. Pura: se prueba sin ventana.
function Cab-Vigentes($cache, $textos) {
    $t = @($textos | ForEach-Object { "$_" -replace ' ?\u25BE\*?$', '' })
    if (@($cache).Count -ne $t.Count) { return $t }
    return @($cache)
}

# Vuelve a coger la lista completa si la tabla se ha repintado desde fuera.
function Lv-Sincronizar($lv) {
    $e = Lv-Estado $lv
    if ($e.dejadas -eq $lv.Items.Count) { return }
    $e.filtros = @{}
    $e.orig = @($lv.Items)
    $e.dejadas = $lv.Items.Count
    # Si la tabla ha cambiado de columnas, las cabeceras cacheadas ya no valen.
    # 'Leer variable' las rehace en cada lectura -una por variable- y esto las
    # estaba pisando con las de la vez anterior: los nombres de las tres
    # primeras salian como 'TCU', 'Valor' y 'Estado' en vez de la variable.
    # Y los filtros van por numero de columna, asi que tampoco valen.
    # y los filtros van por numero de columna, asi que tampoco valen
    if (@($e.cab).Count -ne $lv.Columns.Count) { $e.filtros = @{} }
    $e.cab = @(Cab-Vigentes $e.cab @($lv.Columns | ForEach-Object { $_.Text }))
    for ($i = 0; $i -lt $lv.Columns.Count -and $i -lt @($e.cab).Count; $i++) { $lv.Columns[$i].Text = $e.cab[$i] + [char]0x25BE }
}

function Lv-Aplicar($lv) {
    $e = Lv-Estado $lv
    $vis = @(@($e.orig) | Where-Object { Lv-Pasa (@($_.SubItems | ForEach-Object { $_.Text })) $e.filtros })
    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($it in $vis) { [void]$lv.Items.Add($it) }
    $lv.EndUpdate()
    $e.dejadas = $lv.Items.Count
    # marca en la cabecera que columnas filtran, y cuanto queda a la vista
    # la flechita dice "esto se pulsa"; el asterisco, "esta columna filtra"
    for ($i = 0; $i -lt $lv.Columns.Count -and $i -lt @($e.cab).Count; $i++) {
        $lv.Columns[$i].Text = $e.cab[$i] + [char]0x25BE + $(if ($e.filtros.ContainsKey("$i")) { '*' } else { '' })
    }
    if ($e.filtros.Count -gt 0) {
        Con ("Filtro en la tabla: {0} de {1} filas a la vista. Pulsa la cabecera para quitarlo." -f $vis.Count, @($e.orig).Count) ([System.Drawing.Color]::SteelBlue)
    }
}

function Lv-Ordenar($lv, [int]$col, [bool]$asc) {
    $e = Lv-Estado $lv
    $vals = @(@($e.orig) | ForEach-Object { if ($col -lt $_.SubItems.Count) { Lv-Clave $_.SubItems[$col].Text } else { [double]::NaN } })
    $numerica = (@($vals | Where-Object { [double]::IsNaN($_) }).Count -eq 0) -and @($vals).Count -gt 0
    $e.orig = @(@($e.orig) | Sort-Object -Descending:(-not $asc) -Property @{Expression={
        $t = $(if ($col -lt $_.SubItems.Count) { $_.SubItems[$col].Text } else { '' })
        if ($numerica) { Lv-Clave $t } else { $t } }})
    Lv-Aplicar $lv
}

# Menu de la cabecera: ordenar y elegir varios valores a la vez, como el HTML.
function Lv-Menu($lv, [int]$col) {
    Lv-Sincronizar $lv
    $e = Lv-Estado $lv
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $nombre = $(if ($col -lt @($e.cab).Count) { $e.cab[$col] } else { "columna $col" })
    # "A-Z" en una columna de numeros no dice nada: se mira lo que hay dentro
    $vals = @(@($e.orig) | ForEach-Object { if ($col -lt $_.SubItems.Count) { Lv-Clave $_.SubItems[$col].Text } else { [double]::NaN } })
    $esNum = (@($vals).Count -gt 0) -and (@($vals | Where-Object { [double]::IsNaN($_) }).Count -eq 0)
    $rotAsc = $(if ($esNum) { "Ordenar por '$nombre' de menor a mayor" } else { "Ordenar por '$nombre' A-Z" })
    $rotDes = $(if ($esNum) { "Ordenar por '$nombre' de mayor a menor" } else { "Ordenar por '$nombre' Z-A" })
    # Un menu de Windows se cierra al primer clic, asi que con las casillas de
    # los valores solo se podia marcar o desmarcar UNA por apertura: para dejar
    # un valor de cinco habia que abrirlo cuatro veces, y desde fuera parece que
    # no deja quitar las casillas. Se cancela el cierre por clic SIEMPRE y lo
    # cierran a mano las opciones que si terminan (ordenar, quitar, copiar); asi
    # no depende del orden en que WinForms dispare Click y Closing.
    $m.Add_Closing({ param($s2, $e2) if ($e2.CloseReason -eq 'ItemClicked') { $e2.Cancel = $true } })
    $mAsc = $m.Items.Add($rotAsc)
    $mAsc.Add_Click({ Lv-Ordenar $lv $col $true; $m.Close() }.GetNewClosure())
    $mDes = $m.Items.Add($rotDes)
    $mDes.Add_Click({ Lv-Ordenar $lv $col $false; $m.Close() }.GetNewClosure())
    [void]$m.Items.Add('-')
    # valores distintos de la columna, sobre la lista COMPLETA
    $cuenta = @{}
    foreach ($it in @($e.orig)) {
        $t = $(if ($col -lt $it.SubItems.Count) { $it.SubItems[$col].Text } else { '' })
        $cuenta[$t] = 1 + [int]$cuenta[$t]
    }
    $claves = @($cuenta.Keys | Sort-Object)
    if ($claves.Count -gt 60) {
        $mAviso = $m.Items.Add("($($claves.Count) valores distintos: demasiados para listarlos)")
        $mAviso.Enabled = $false
    } else {
        $activos = $(if ($e.filtros.ContainsKey("$col")) { @($e.filtros["$col"]) } else { $null })
        # El filtro se aplica al vuelo: la tabla de debajo se va actualizando
        # segun se marca y se desmarca, con el menu abierto.
        $aplicar = {
            $marcados = @()
            $total = 0
            foreach ($x in $m.Items) {
                if ($x -is [System.Windows.Forms.ToolStripMenuItem] -and $x.CheckOnClick) {
                    $total++
                    if ($x.Checked) { $marcados += "$($x.Tag)" }
                }
            }
            if ($total -eq 0) { return }
            $est = Lv-Estado $lv
            if ($marcados.Count -eq 0 -or $marcados.Count -eq $total) { [void]$est.filtros.Remove("$col") }
            else { $est.filtros["$col"] = $marcados }
            Lv-Aplicar $lv
        }.GetNewClosure()
        # marcar y desmarcar de golpe, que es lo que se quiere con muchos valores
        $mSolo = $m.Items.Add('Desmarcar todos')
        $mSolo.Add_Click({
            foreach ($x in $m.Items) { if ($x -is [System.Windows.Forms.ToolStripMenuItem] -and $x.CheckOnClick) { $x.Checked = $false } }
            & $aplicar
        }.GetNewClosure())
        $mTodos = $m.Items.Add('Marcar todos')
        $mTodos.Add_Click({
            foreach ($x in $m.Items) { if ($x -is [System.Windows.Forms.ToolStripMenuItem] -and $x.CheckOnClick) { $x.Checked = $true } }
            & $aplicar
        }.GetNewClosure())
        [void]$m.Items.Add('-')
        foreach ($k in $claves) {
            $it = New-Object System.Windows.Forms.ToolStripMenuItem
            $it.Text = $(if ($k -eq '') { '(vacio)' } else { $k }) + "   ($($cuenta[$k]))"
            $it.CheckOnClick = $true
            $it.Checked = ($null -eq $activos) -or (@($activos) -contains $k)
            $it.Tag = $k
            $it.Add_Click({ & $aplicar }.GetNewClosure())
            $m.Items.Add($it) | Out-Null
        }
    }
    [void]$m.Items.Add('-')
    $mQuitar = $m.Items.Add('Quitar todos los filtros')
    $mQuitar.Add_Click({ $est = Lv-Estado $lv; $est.filtros = @{}; Lv-Aplicar $lv; $m.Close() }.GetNewClosure())
    $mCopiar = $m.Items.Add('Copiar lo que se ve (TSV)')
    $mCopiar.Add_Click({
        $lin = @((@($lv.Columns | ForEach-Object { $_.Text -replace '\u25BE\*?$', '' })) -join [char]9)
        foreach ($it in $lv.Items) { $lin += (@($it.SubItems | ForEach-Object { $_.Text }) -join [char]9) }
        try { [System.Windows.Forms.Clipboard]::SetText($lin -join "`r`n") } catch {}
        $m.Close()
    }.GetNewClosure())
    $mCerrar = $m.Items.Add('Cerrar')
    $mCerrar.Add_Click({ $m.Close() }.GetNewClosure())
    return $m
}

function Lv-Filtrable($lv) {
    $e = Lv-Estado $lv
    # marca las cabeceras desde el principio, sin esperar a que haya datos
    $e.cab = @(Cab-Vigentes $e.cab @($lv.Columns | ForEach-Object { $_.Text }))
    for ($i = 0; $i -lt $lv.Columns.Count -and $i -lt @($e.cab).Count; $i++) { $lv.Columns[$i].Text = $e.cab[$i] + [char]0x25BE }
    $lv.Add_ColumnClick({
        param($s3, $e3)
        try { (Lv-Menu $s3 $e3.Column).Show([System.Windows.Forms.Control]::MousePosition) }
        catch { Con "AVISO: no se pudo abrir el filtro de la columna ($_)" ([System.Drawing.Color]::Orange) }
    })
}

# Menu del boton derecho de la consola. Ctrl+C y Ctrl+A ya funcionaban, pero
# no se ven; y "copiar toda la consola" es lo que se quiere para pegar un
# resultado en un correo.
$menuCon = New-Object System.Windows.Forms.ContextMenuStrip
$miCopiar = $menuCon.Items.Add('Copiar' + [char]9 + 'Ctrl+C')
$miCopiar.Add_Click({ if ($rtb.SelectionLength -gt 0) { $rtb.Copy() } })
$miSelTodo = $menuCon.Items.Add('Seleccionar todo' + [char]9 + 'Ctrl+A')
$miSelTodo.Add_Click({ $rtb.SelectAll(); $rtb.Focus() })
$miCopiarTodo = $menuCon.Items.Add('Copiar toda la consola')
$miCopiarTodo.Add_Click({ if ($rtb.TextLength -gt 0) { try { [System.Windows.Forms.Clipboard]::SetText($rtb.Text) } catch {} } })
[void]$menuCon.Items.Add('-')
$miGuardarLog = $menuCon.Items.Add('Guardar log...')
$miGuardarLog.Add_Click({ $btnLog.PerformClick() })
$miLimpiarCon = $menuCon.Items.Add('Limpiar consola')
$miLimpiarCon.Add_Click({ Limpiar-Consola })
$rtb.ContextMenuStrip = $menuCon

# ---------------------------------------------------------------------------
#  Estado global, consola y log automatico a fichero
# ---------------------------------------------------------------------------
$script:Fallidas = New-Object System.Collections.ArrayList
$script:UltimaLectura = @()
# recuento de la reconfirmacion de valores anomalos de la ultima lectura
$script:ReconfIntentos = 0; $script:ReconfConfirmados = 0
$script:ReconfCambios = 0;  $script:ReconfSinAcuerdo = 0
$script:UltimaEscritura = @()
$script:UltimoVolcado = @()
$script:UltimoDiag = @()
$script:UltimaBat = @()
$script:UltimaIdent = @()
$script:UltimaAud = @()
$script:UltimoInv = @()
$script:UltimoPem = @()
$script:PresetRef = $null
$script:PresetRefNombre = ''
$script:UltimoEsComm = $false   # el ultimo resultado de la lista es un TEST COMM, no un diagnostico
$script:HoraDe = @{}            # hora a la que se ejecuto cada bloque, para el informe
$script:OrdenDe = @{}           # y en que orden, para que el informe empiece por lo ultimo
$script:NBloque = 0
# Deja constancia de que un bloque se acaba de ejecutar. El informe ordena sus
# secciones con esto: si acabas de hacer un inventario, el inventario va
# primero aunque en la sesion hubiera un diagnostico anterior.
function Marcar-Bloque([string]$clave) {
    $script:HoraDe[$clave] = (Get-Date -Format 'HH:mm')
    $script:NBloque++
    $script:OrdenDe[$clave] = $script:NBloque
}
$script:SegMotor = @{}   # "ncu|tcu" -> @{ncu;tcu;estado;obs} del test de motor
$script:SegComis = @{}   # idem, de LEER ESTADO de comisionado
$script:SegAud = @{}     # idem, de la auditoria contra preset
$script:MetaVolcado = $null
$script:Ocupado = $false
$script:Cancelar = $false

$script:LogFile = $null
try {
    $logDir = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $script:LogFile = Join-Path $logDir ('tcu_toolbox_' + (Get-Date -Format 'yyyyMMdd') + '.log')
    $lblLog.Text = "Log automatico: $script:LogFile"
} catch { $lblLog.Text = 'Log automatico no disponible (carpeta logs no escribible)' }

# Vaciar la consola no toca el log de fichero: ahi queda todo, que es lo que
# vale para reconstruir una jornada.
function Limpiar-Consola {
    $rtb.Clear()
    Con "Consola limpiada. El log completo sigue en $(if ($script:LogFile) { $script:LogFile } else { '(sin log de fichero)' })." ([System.Drawing.Color]::Gainsboro)
}

function Con([string]$t, $color) {
    # Si el usuario tiene texto seleccionado no se le quita ni se le mueve la
    # vista: en una operacion larga la consola escribe cada pocos segundos y
    # antes era imposible copiar nada sin que la siguiente linea se lo llevara.
    $selIni = $rtb.SelectionStart; $selLen = $rtb.SelectionLength
    $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
    $rtb.SelectionColor = $color
    $rtb.AppendText($t + "`r`n")
    $rtb.SelectionColor = $rtb.ForeColor
    if ($selLen -gt 0) { $rtb.SelectionStart = $selIni; $rtb.SelectionLength = $selLen }
    else { $rtb.ScrollToCaret() }
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $t) -Encoding UTF8 } catch {}
    }
    [System.Windows.Forms.Application]::DoEvents()
}

$BOTONES_ACCION = @($btnEscribir, $btnFallidas, $btnNvm, $btnLeer, $btnVolcar, $btnDiag, $btnSync, $btnIdent,
                    $btnPresetSave, $btnPresetLoad, $btnLPreset, $btnCargarBackup, $btnLCsv, $btnDCsv, $btnBackupJson,
                    $btnComparar, $btnGCsv, $btnGJson, $btnGWa, $btnGBat, $btnBVer, $btnBAud, $btnBCar, $btnBCsv, $btnBJson, $btnICsv, $btnTCargar, $btnTGuardar, $btnTBorrar,
                    $btnCsvTcu, $btnBackupNcu, $btnAud, $btnAudCsv, $btnPresetRef, $btnAudEscr, $btnInvF, $btnInvFCsv,
                    $btnHMeteo, $btnHConfig, $btnHCaja, $btnHUmb, $btnHReloj, $btnHNieve, $btnHNvm, $btnHEsclavo,
                    $btnPMotor, $btnPModo, $btnPClear, $btnPStow, $btnPUnstow, $btnPComis, $btnPComisSet, $btnPCsv,
                    $btnGBucle, $btnPSeg, $btnAudJson, $btnInvJson, $btnHBuscar, $btnGComm,
                    $btnFwPlan, $btnFwVerif, $btnFwPrep)

function Set-UIOcupada([bool]$ocupada) {
    foreach ($b in $BOTONES_ACCION) { $b.Enabled = (-not $ocupada) }
    if (-not $ocupada) {
        # restaurar los botones que dependen de datos
        $btnFallidas.Enabled   = ($script:Fallidas.Count -gt 0)
        $btnLCsv.Enabled       = ($script:UltimaLectura.Count -gt 0)
        $btnDCsv.Enabled       = ($script:UltimoVolcado.Count -gt 0)
        $btnBackupJson.Enabled = ($script:UltimoVolcado.Count -gt 0)
        $btnComparar.Enabled   = ($script:UltimoVolcado.Count -gt 0)
        $btnGCsv.Enabled       = ($script:UltimoDiag.Count -gt 0)
        $btnGWa.Enabled        = ($script:UltimoDiag.Count -gt 0)
        $btnGBat.Enabled       = ($script:UltimoDiag.Count -gt 0)
        $btnGJson.Enabled      = ($script:UltimoDiag.Count -gt 0)
        $btnICsv.Enabled       = ($script:UltimaIdent.Count -gt 0)
        $btnAudCsv.Enabled     = ($script:UltimaAud.Count -gt 0)
        $btnAudJson.Enabled    = ($script:SegAud.Count -gt 0)
        $btnInvFCsv.Enabled    = ($script:UltimoInv.Count -gt 0)
        $btnInvJson.Enabled    = ($script:UltimoInv.Count -gt 0)
        $btnPCsv.Enabled       = ($script:UltimoPem.Count -gt 0)
        $btnPSeg.Enabled       = (($script:SegMotor.Count + $script:SegComis.Count + $script:SegAud.Count) -gt 0)
    }
    $btnCancelar.Enabled = $ocupada
    [System.Windows.Forms.Application]::DoEvents()
}

# Envuelve una operacion larga: guarda contra reentrada (DoEvents), habilita
# CANCELAR, y cierra la conexion Modbus pase lo que pase.
# Texto del avance. Se separa para poder probarlo: el calculo de lo que queda
# es lo unico que puede mentir. Pura.
function Prog-Texto([int]$hechos, [int]$total, [double]$segundos) {
    if ($total -le 0) { return '' }
    $pc = [Math]::Min(100, [Math]::Round(100.0 * $hechos / $total))
    $t = "$hechos/$total  $pc%"
    if ($hechos -lt 3 -or $segundos -le 0) { return $t }     # aun no hay ritmo fiable
    $restan = ($segundos / $hechos) * ($total - $hechos)
    if ($restan -lt 1) { return $t }
    $q = $(if ($restan -lt 90) { "{0:0} s" -f $restan }
           elseif ($restan -lt 5400) { "{0:0} min" -f ($restan / 60) }
           else { (("{0:0.#}" -f ($restan / 3600)) -replace '\.', ',') + ' h' })
    return "$t  ~$q"
}

$script:ProgTotal = 0; $script:ProgHechos = 0; $script:ProgIni = $null; $script:ProgUltimo = -1
function Prog-Iniciar([int]$total) {
    $script:ProgTotal = $total; $script:ProgHechos = 0; $script:ProgUltimo = -1
    $script:ProgIni = Get-Date
    if ($total -le 0) { return }
    $pbProg.Value = 0; $pbProg.Visible = $true; $lblProg.Visible = $true
    $lblProg.Text = "0/$total"
    $lblLog.Visible = $false
}
function Prog-Paso([int]$n = 1) {
    if ($script:ProgTotal -le 0) { return }
    $script:ProgHechos += $n
    # repintar en cada lectura cuesta mas que la propia lectura: solo cuando
    # cambia la decima de porcentaje
    $mil = [int](1000.0 * [Math]::Min(1.0, $script:ProgHechos / [double]$script:ProgTotal))
    if ($mil -eq $script:ProgUltimo) { return }
    $script:ProgUltimo = $mil
    $pbProg.Value = $mil
    $seg = 0.0
    if ($script:ProgIni) { $seg = ((Get-Date) - $script:ProgIni).TotalSeconds }
    $lblProg.Text = Prog-Texto $script:ProgHechos $script:ProgTotal $seg
}
function Prog-Fin {
    $script:ProgTotal = 0
    $pbProg.Visible = $false; $lblProg.Visible = $false; $lblLog.Visible = $true
}

function Lanzar([scriptblock]$accion) {
    if ($script:Ocupado) { Con 'Hay una operacion en curso (usa CANCELAR para abortarla).' ([System.Drawing.Color]::Orange); return }
    $script:Ocupado = $true; $script:Cancelar = $false; $script:NcuLog = ''
    Set-UIOcupada $true
    try { & $accion }
    catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon) }
    finally {
        Modbus-Cerrar
        Prog-Fin
        $script:Ocupado = $false
        Set-UIOcupada $false
    }
}

$btnCancelar.Add_Click({ $script:Cancelar = $true; Con 'Cancelando...' ([System.Drawing.Color]::Orange) })

function Chequear-Cancelado {
    if ($script:Cancelar) { Con 'OPERACION CANCELADA por el usuario' ([System.Drawing.Color]::Orange); return $true }
    return $false
}

function Params-Conexion {
    $ip = $txtIp.Text.Trim()
    if (-not $ip) { throw 'IP vacia' }
    $to     = Val-Int $txtTo.Text 'Timeout' 500 60000
    $reint  = Val-Int $txtRet.Text 'Reintentos' 1 10
    if ($ip -eq 'NA' -or $ip -eq '(planta)') {
        $p = $null
        if ($cbPlanta.SelectedItem) { $p = $PLANTAS[$cbPlanta.SelectedItem] }
        if (-not ($p -and $p.ncus)) { throw "IP 'NA' solo vale con una entrada (Planta completa) seleccionada" }
        return @{ip='NA'; puerto=$null; gws=$null; multi=$p.ncus; etiqueta='PLANTA'; to=$to; reint=$reint; nombre="$($cbPlanta.SelectedItem)"}
    }
    $pt = $txtPort.Text.Trim()
    if ($pt -eq 'auto') {
        $p = $null
        if ($cbPlanta.SelectedItem) { $p = $PLANTAS[$cbPlanta.SelectedItem] }
        if (-not ($p -and $p.gws) -or ($p.ip -ne $ip)) {
            throw "puerto 'auto' requiere una entrada (auto) seleccionada y su IP sin modificar"
        }
        return @{ip=$ip; puerto=$null; gws=$p.gws; etiqueta='auto'; to=$to; reint=$reint; nombre="$($cbPlanta.SelectedItem)"}
    }
    $puerto = Val-Int $pt 'Puerto' 1 65535
    return @{ip=$ip; puerto=$puerto; gws=$null; etiqueta="$puerto"; to=$to; reint=$reint; nombre="$($cbPlanta.SelectedItem)"}
}

# Etiqueta de una TCU para la consola. En Planta completa los numeros de TCU
# se repiten en cada NCU, asi que sin la NCU delante una linea de log no dice
# de que equipo habla. $script:NcuLog lo pone el bucle de cada operacion.
$script:NcuLog = ''
function Eti-Tcu($tcu) {
    if ("$script:NcuLog") { return ("NCU{0,-3} TCU {1,3}" -f $script:NcuLog, $tcu) }
    return ("TCU {0,3}" -f $tcu)
}

# Divide una lista de TCUs en segmentos consecutivos por puerto de gateway.
# Con puerto fijo devuelve un unico segmento; en modo 'auto' resuelve el
# puerto de cada TCU con los rangos de la NCU (adios al error de puerto) y
# avisa de los TCUs que no caen en ningun gateway.
function Plan-Segmentos([int[]]$tcus, [hashtable]$cx) {
    if ($cx.multi) { throw "la entrada (Planta completa) solo esta soportada en Diagnostico y Flota; elige una NCU concreta" }
    if (-not $cx.gws) { return @{puerto=$cx.puerto; tcus=$tcus} }
    $segs = New-Object System.Collections.ArrayList
    $huerfanos = @()
    $actual = $null
    foreach ($tcu in $tcus) {
        $gw = $null
        foreach ($g in $cx.gws) { if ($tcu -ge $g.ini -and $tcu -le $g.fin) { $gw = $g; break } }
        if (-not $gw) { $huerfanos += $tcu; continue }
        if ($actual -and $actual.puerto -eq $gw.puerto) { [void]$actual.tcus.Add($tcu) }
        else {
            $actual = @{puerto=$gw.puerto; tcus=(New-Object System.Collections.ArrayList)}
            [void]$actual.tcus.Add($tcu)
            [void]$segs.Add($actual)
        }
    }
    if ($huerfanos.Count -gt 0) {
        Con ("AVISO: TCUs fuera de los gateways de la NCU (saltados): " + ($huerfanos -join ', ')) ([System.Drawing.Color]::Orange)
    }
    return $segs
}

# Expande la conexion en una lista de trabajos: con la entrada "(PLANTA
# completa)" devuelve uno por NCU (rangos automaticos de sus gateways,
# opcionalmente filtrados con '1,3-5'); en modo normal, uno solo con los
# $tcus que pase el llamante. Cada trabajo: @{ncu; ip; tcus; cx}.
# Numero de NCU escondido en el nombre de una entrada de conexion ("Ayora NCU3"
# -> 3). Trabajando contra una sola NCU no hay recorrido del que sacarlo, pero
# el nombre lo lleva: sin esto la columna NCU salia vacia y la consola tampoco
# decia de que NCU era cada TCU. Pura: se prueba sin ventana.
function Ncu-DeNombre([string]$nombre) {
    $m = [regex]::Match("$nombre", '(?i)\bNCU\s*(\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# "TCU 16" cuando es una sola y "TCUs 16-20" cuando son varias: poner el rango
# repetido, o hablar de "todas", cuando solo hay un equipo despista. Pura.
function Eti-Rango($tcus) {
    $t = @($tcus)
    if ($t.Count -eq 0) { return 'sin TCUs' }
    if ($t.Count -eq 1) { return "TCU $($t[0])" }
    return "TCUs $($t[0])-$($t[-1])"
}

# Que equipos hay que tocar, en un solo sitio. Antes eran dos cuadros "de/a", y
# con eso no se puede decir "la 10, la 22 y de la 30 a la 40": habia que ir tres
# veces o pasar por un CSV.
#
#   ""  /  "NA"  /  "todas"   -> todas las de la seleccion
#   "1-44"                    -> el rango de siempre
#   "10,22,30-40"             -> lista suelta, en las NCUs elegidas
#   "12/10, 12/22, 15/5-12"   -> cada tramo con SU NCU
#   "12/*, 15/5-12"           -> toda la NCU 12, y de la 15 solo esas
#
# Devuelve @{todas; lista; porNcu}. Pura: se prueba sin planta.
function Parse-Seleccion([string]$texto, [string]$etiqueta = 'TCUs') {
    $t = "$texto".Trim()
    if ($t -eq '' -or $t -eq 'NA' -or $t -match '^(?i)todas$') { return @{todas=$true; lista=@(); porNcu=@{}} }
    $lista = @(); $porNcu = @{}
    foreach ($parte in $t.Split(',')) {
        $p = $parte.Trim()
        if ($p -eq '') { continue }
        $eti = $p
        $ncu = ''
        if ($p -match '^(\d+)\s*/\s*(.+)$') { $ncu = $Matches[1]; $p = $Matches[2].Trim() }
        $nums = @()
        if ($p -eq '*') {
            if ($ncu -eq '') { throw "$etiqueta : el * solo vale con la NCU delante (12/*)" }
            if (-not $porNcu.ContainsKey($ncu)) { $porNcu[$ncu] = @() }
            $porNcu[$ncu] += '*'
            continue
        }
        if ($p -match '^(\d+)\s*-\s*(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($b -lt $a) { throw "$etiqueta : el tramo '$eti' va al reves" }
            $nums = @($a..$b)
        }
        elseif ($p -match '^\d+$') { $nums = @([int]$p) }
        else { throw "$etiqueta : no entiendo '$eti' (usa 10, 30-40 o 12/10)" }
        foreach ($n in $nums) { if ($n -lt 1 -or $n -gt 247) { throw "$etiqueta : el $n esta fuera de 1..247" } }
        if ($ncu -ne '') {
            if (-not $porNcu.ContainsKey($ncu)) { $porNcu[$ncu] = @() }
            $porNcu[$ncu] += $nums
        } else { $lista += $nums }
    }
    # mezclarlo seria ambiguo: "12/10,22" no dice si el 22 es de la 12 o de todas
    if ($porNcu.Count -gt 0 -and $lista.Count -gt 0) {
        throw "$etiqueta : o pones la NCU delante en TODOS los tramos (12/10, 15/5-12) o en ninguno"
    }
    foreach ($k in @($porNcu.Keys)) {
        if ($porNcu[$k] -contains '*') { $porNcu[$k] = @('*') }
        else { $porNcu[$k] = @($porNcu[$k] | Sort-Object -Unique) }
    }
    return @{todas=$false; lista=@($lista | Sort-Object -Unique); porNcu=$porNcu}
}

# Los gateways de una NCU que sobreviven al filtro de GW ("503", o vacio = todos).
# Pura.
# De que gateway cuelga una TCU segun la topologia. Vacio si no cae en ninguno
# (o si la entrada lleva puerto fijo, que entonces ya se sabe cual es). Pura.
function Gw-DeTcu($gws, [int]$tcu) {
    foreach ($g in @($gws)) { if ($tcu -ge [int]$g.ini -and $tcu -le [int]$g.fin) { return "$($g.puerto)" } }
    return ''
}

function Gws-Filtrados($gws, [string]$gw) {
    $g = "$gw".Trim()
    if ($g -eq '' -or $g -match '^(?i)todos$') { return @($gws) }
    return @(@($gws) | Where-Object { "$($_.puerto)" -eq $g })
}

# Las TCUs que le tocan a UNA NCU: las de su seleccion, recortadas a los
# gateways que quedan. Sin seleccion, todas las del gateway -que es como se pide
# "toda la NCU" o "todo el GW 504" sin tener que saberse el rango-. Pura.
function Sel-TcusDe($sel, $gws, [string]$ncu) {
    $todas = @()
    foreach ($g in @($gws)) { $todas += @([int]$g.ini..[int]$g.fin) }
    $todas = @($todas | Sort-Object -Unique)
    if ($null -eq $sel -or $sel.todas) { return $todas }
    $piden = @()
    if ($sel.porNcu.Count -gt 0) { if ($sel.porNcu.ContainsKey("$ncu")) { $piden = @($sel.porNcu["$ncu"]) } }
    else { $piden = @($sel.lista) }
    if ($piden.Count -eq 0) { return @() }
    if ($piden -contains '*') { return $todas }
    return @($piden | Where-Object { $todas -contains [int]$_ } | Sort-Object -Unique)
}

function Trabajos-Planta([hashtable]$cx, [int[]]$tcus, [string]$filtro = '', $sel = $null, [string]$gw = '') {
    if (-not $cx.multi) {
        $n = Ncu-DeNombre $cx.nombre
        $g = $(if ($cx.gws) { @(Gws-Filtrados $cx.gws $gw) } else { $null })
        $t = $tcus
        if ($null -ne $sel) {
            if ($null -ne $g) {
                if ($g.Count -eq 0) { throw "esta entrada no tiene ningun gateway $gw" }
                $t = @(Sel-TcusDe $sel $g "$n")
            }
            elseif ($sel.todas) { throw 'di que TCUs: con un puerto fijo la herramienta no sabe cuantas hay (usa una entrada (auto) o escribe p. ej. 1-44)' }
            elseif ($sel.porNcu.Count -gt 0) { $t = $(if ($sel.porNcu.ContainsKey("$n")) { @($sel.porNcu["$n"]) } else { @() }) }
            else { $t = @($sel.lista) }
        }
        return @{ncu=$(if ($n -ne '') { [int]$n } else { $null }); ip=$cx.ip; tcus=@($t)
                 cx=$(if ($null -ne $g) { @{ip=$cx.ip; puerto=$cx.puerto; gws=$g; multi=$null; etiqueta=$cx.etiqueta; to=$cx.to; reint=$cx.reint} } else { $cx })}
    }
    $lista = @()
    $nums = Parse-ListaNums $filtro
    # con "12/10, 15/5-12" las NCUs las dice la propia seleccion
    if ($null -ne $sel -and $sel.porNcu.Count -gt 0) { $nums = @($sel.porNcu.Keys | ForEach-Object { [int]$_ }) }
    foreach ($n in $cx.multi) {
        if ($nums -and -not ($nums -contains [int]$n.ncu)) { continue }
        $g = @(Gws-Filtrados $n.gws $gw)
        if ($g.Count -eq 0) { continue }              # esa NCU no tiene ese gateway
        $lt = @(Sel-TcusDe $sel $g "$($n.ncu)")
        if ($lt.Count -eq 0) { continue }
        $lista += ,@{ncu=[int]$n.ncu; ip=$n.ip; tcus=$lt
            cx=@{ip=$n.ip; puerto=$null; gws=$g; multi=$null; etiqueta='auto'; to=$cx.to; reint=$cx.reint}}
    }
    return $lista
}

function Refrescar-ComboPlantas {
    $sel = $cbPlanta.SelectedItem
    $cbPlanta.Items.Clear()
    foreach ($k in $PLANTAS.Keys) { [void]$cbPlanta.Items.Add($k) }
    if ($sel -and $cbPlanta.Items.Contains($sel)) { $cbPlanta.SelectedItem = $sel } else { $cbPlanta.SelectedIndex = 0 }
}

# Importa uno o varios JSON/CSV de plantas descargados de la plataforma.
# REEMPLAZA la lista actual: en el desplegable quedan solo las NCUs de los
# ficheros cargados (mas la entrada manual). Ofrece guardarlos en plantas/.
$btnPlantas.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Plantas (*.json;*.csv)|*.json;*.csv'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -ne 'OK') { return }
    # reemplazo: fuera todo menos (manual)
    foreach ($k in @($PLANTAS.Keys)) { if ($k -ne '(manual)') { $PLANTAS.Remove($k) } }
    $importados = @()
    foreach ($f in $dlg.FileNames) {
        try {
            $n = Cargar-FicheroPlantas $f
            $importados += $f
            Con "Plantas cargadas de $([System.IO.Path]::GetFileName($f)): $n" ([System.Drawing.Color]::SteelBlue)
        } catch {
            Con "AVISO: $([System.IO.Path]::GetFileName($f)) ilegible ($_) - ignorado" ([System.Drawing.Color]::Orange)
        }
    }
    if ($importados.Count -eq 0) { Refrescar-ComboPlantas; Con 'Lista de plantas vacia (solo entrada manual).' ([System.Drawing.Color]::Orange); return }
    Construir-EntradasAuto
    Refrescar-ComboPlantas
    Con "Lista de plantas reemplazada: solo se muestran las de $($importados.Count) fichero(s) cargado(s)." ([System.Drawing.Color]::SteelBlue)
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Guardar una copia en la carpeta 'plantas' junto al script, para que se carguen solas al arrancar?",
        'Recordar plantas', 'YesNo', 'Question')
    if ($r -eq 'Yes') {
        try {
            $dir = Join-Path $PSScriptRoot 'plantas'
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
            foreach ($f in $importados) { Copy-Item $f (Join-Path $dir ([System.IO.Path]::GetFileName($f))) -Force }
            Con "Copiados $($importados.Count) ficheros a plantas/" ([System.Drawing.Color]::SteelBlue)
        } catch { Con "AVISO: no se pudo copiar a plantas/: $_" ([System.Drawing.Color]::Orange) }
    }
})

$cbPlanta.Add_SelectedIndexChanged({
    # cada planta tiene su lista de cierre
    try { Cierre-Cargar (Nombre-Planta); Cierre-Pintar } catch {}
    $p = $PLANTAS[$cbPlanta.SelectedItem]
    if ($p -and $p.ncus) {
        # planta completa: solo Diagnostico; IP, puertos y rangos van por NCU
        # (los campos se ignoran y se muestran como NA)
        $txtIp.Text = 'NA'; $txtPort.Text = 'auto'
        $txtGTcus.Text = 'NA'; $txtATcus.Text = 'NA'; $txtLTcus.Text = 'NA'; $txtWTcus.Text = 'NA'
        $txtVTcus.Text = 'NA'
        Con "Planta completa seleccionada ($(@($p.ncus).Count) NCUs): rangos automaticos por NCU. El cuadro TCUs admite '10,22,30-40' y '12/10, 15/5-12' (vacio o NA = todas), y el cuadro GW de Conexion deja trabajar solo sobre un gateway." ([System.Drawing.Color]::SteelBlue)
        return
    }
    if ($p) {
        $txtIp.Text = $p.ip
        if ($p.gws) { $txtPort.Text = 'auto' } else { $txtPort.Text = "$($p.puerto)" }
        $rango = "$($p.ini)-$($p.fin)"
        $txtWTcus.Text = $rango; $txtLTcus.Text = $rango; $txtGTcus.Text = $rango; $txtATcus.Text = $rango
        $txtSTcus.Text = $rango; $txtVTcus.Text = $rango; $txtBTcus.Text = $rango; $txtPTcus.Text = $rango
        if ($p.hsu) { $txtHSlave.Text = "$($p.hsu)" }
    }
})

function Nombre-Planta {
    $n = "$($cbPlanta.SelectedItem)"
    if ($n -eq '(manual)') { return $txtIp.Text.Trim() }
    return $n
}

# ------------------------- logica ESCRIBIR -------------------------
function Recoger-Variables {
    [void]$dgv.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    [void]$dgv.EndEdit()
    $lista = @()
    foreach ($fila in $dgv.Rows) {
        if ($fila.IsNewRow) { continue }
        $nombre = $fila.Cells[0].Value; $valor = $fila.Cells[1].Value
        if (-not $nombre -and "$valor" -eq '') { continue }
        if (-not $nombre) { Con "AVISO: fila con valor '$valor' sin variable - IGNORADA" ([System.Drawing.Color]::Orange); continue }
        if ("$valor" -eq '') { Con "AVISO: '$nombre' sin valor - IGNORADA" ([System.Drawing.Color]::Orange); continue }
        $v = $VARIABLES[$nombre]
        try { $esc = Valor-A-Escritura $v "$valor" }
        catch { Con "AVISO: '$nombre' valor invalido '$valor': $_ - IGNORADA" ([System.Drawing.Color]::Orange); continue }
        $lista += @{nombre=$nombre; texto="$valor"; addr=$v.addr; esc=$esc}
    }
    # retorno plano: los llamadores recogen con @(...); no proteger con ','
    return $lista
}

function Escribir-EnTcus($tcus) {
    $vars = @(Recoger-Variables)
    if ($vars.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('No hay variables con valor.','Aviso'); return }
    $cx = Params-Conexion
    # Con (Planta completa) se recorren todas las NCUs con sus rangos
    # automaticos, igual que en Leer y en Diagnostico. Y si lo que llega es la
    # lista de fallidas, cada una trae su NCU: hay que volver a la suya, porque
    # en una planta los numeros de TCU se repiten entre NCUs.
    if ($tcus -and (@($tcus)[0] -is [hashtable])) {
        $porNcuF = @{}
        foreach ($f in @($tcus)) {
            $k = "$($f.ncu)"
            if (-not $porNcuF.ContainsKey($k)) { $porNcuF[$k] = @() }
            $porNcuF[$k] += [int]$f.tcu
        }
        $lista = @()
        foreach ($k in @($porNcuF.Keys | Sort-Object)) {
            $n = $null
            if ($k -and $cx.multi) { $n = @($cx.multi | Where-Object { "$($_.ncu)" -eq $k })[0] }
            if ($n) {
                $lista += ,@{ncu=[int]$n.ncu; ip=$n.ip; tcus=@($porNcuF[$k] | Sort-Object)
                             cx=@{ip=$n.ip; puerto=$null; gws=$n.gws; multi=$null; etiqueta='auto'; to=$cx.to; reint=$cx.reint}}
            } else {
                if ($k) { Con "AVISO: las fallidas de NCU$k se reintentan contra la conexion actual ($($cx.ip)); vuelve a elegir la planta si no es la misma." ([System.Drawing.Color]::Orange) }
                $lista += ,@{ncu=$null; ip=$cx.ip; tcus=@($porNcuF[$k] | Sort-Object); cx=$cx}
            }
        }
        $trabajos = @($lista)
    } else {
        $trabajos = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtWTcus.Text 'Escribir') $txtGw.Text)
    }
    if ($trabajos.Count -eq 0) { Con 'La seleccion no deja ninguna TCU (mira los cuadros TCUs y GW).' ([System.Drawing.Color]::Orange); return }
    $nTcus = 0; foreach ($tr in $trabajos) { $nTcus += @($tr.tcus).Count }
    $donde = $(if ($cx.multi) { "$($trabajos.Count) NCUs de la PLANTA COMPLETA" } else { "$($cx.ip):$($cx.etiqueta)" })
    $resumen = ($vars | ForEach-Object {
        $hex = if ($_.esc.modo -eq 'fc16') { ($_.esc.palabras | ForEach-Object { '{0:X4}' -f $_ }) -join ' ' }
               else { 'AND {0:X4} OR {1:X4}' -f $_.esc.and, $_.esc.or }
        "  $($_.nombre) = $($_.texto)   [$hex]"
    }) -join "`r`n"
    $avisoRb = $(if ($nTcus -gt 3 -and -not $chkRoll.Checked) { "SIN copia de seguridad previa: no se podra deshacer.`r`n" } else { '' })
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Se escribiran $($vars.Count) variables en $nTcus TCUs de ${donde}:`r`n`r`n$resumen`r`n`r`n$avisoRb`r`nContinuar?",
        'Confirmar', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }

    # La identidad de red no se puede escribir en bloque: dos TCUs con el mismo
    # numero de esclavo hacen desaparecer a una de las dos de la red.
    $identV = @($vars | Where-Object { $ADDR_IDENTIDAD -contains $_.addr })
    if ($identV.Count -gt 0 -and -not (Puede 'admin')) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Cambiar la IDENTIDAD DE RED (esclavo, PAN ID, clave) es de administrador.`r`n`r`nTu rol es '$($script:Usuario.rol)'.",
            'Permiso insuficiente', 'OK', 'Stop')
        Con "Escritura cancelada: identidad de red requiere rol admin (tu rol: $($script:Usuario.rol))." ([System.Drawing.Color]::Salmon)
        return
    }
    if ($identV.Count -gt 0) {
        $lista = ($identV | ForEach-Object { "  $($_.nombre)" }) -join "`r`n"
        if ($nTcus -gt 1) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "No se puede escribir IDENTIDAD DE RED en $nTcus TCUs a la vez:`r`n`r`n$lista`r`n`r`nEl numero de esclavo, el PAN ID y la clave son propios de cada equipo. Escribirlos en bloque dejaria varias TCUs con el mismo esclavo y unas cuantas desaparecerian de la red.`r`n`r`nHazlo TCU a TCU (rango de una sola TCU).",
                'IDENTIDAD DE RED', 'OK', 'Stop')
            Con "Escritura cancelada: $($identV.Count) registros de identidad de red apuntando a $nTcus TCUs." ([System.Drawing.Color]::Salmon)
            return
        }
        $rId = [System.Windows.Forms.MessageBox]::Show(
            "ATENCION: vas a cambiar la IDENTIDAD DE RED de la TCU:`r`n`r`n$lista`r`n`r`nSi te equivocas, la TCU deja de responder por Zigbee y hay que ir a pie de seguidor.`r`n`r`nSeguro?",
            'IDENTIDAD DE RED', 'YesNo', 'Stop')
        if ($rId -ne 'Yes') { return }
    }

    $peligrosas = @($vars | Where-Object { $ADDR_COMANDO -contains $_.addr })
    if ($peligrosas.Count -gt 0) {
        $lista = ($peligrosas | ForEach-Object { "  $($_.nombre)" }) -join "`r`n"
        $r2 = [System.Windows.Forms.MessageBox]::Show(
            "ATENCION: vas a escribir registros de COMANDO que pueden mover el seguidor o cambiar su modo:`r`n`r`n$lista`r`n`r`nSeguro que quieres continuar?",
            'REGISTROS DE COMANDO', 'YesNo', 'Stop')
        if ($r2 -ne 'Yes') { return }
    }

    if ($nTcus -gt 3 -and $chkRoll.Checked) {
        # escritura masiva: copia de seguridad previa (rollback) de los valores
        # actuales, restaurable con "CSV por TCU...". Los registros de comando
        # se excluyen: reescribirlos relanzaria ordenes.
        $nRb = 0
        foreach ($tr in $trabajos) { foreach ($t in $tr.tcus) { foreach ($v in $vars) { if ($ADDR_COMANDO -notcontains $v.addr) { $nRb++ } } } }
        # El rollback lee uno a uno: en una planta entera son miles de lecturas
        # y puede tardar mas que la propia escritura, asi que se avisa antes.
        $saltarRb = $false
        if ($nRb -gt 400) {
            $rMasivo = [System.Windows.Forms.MessageBox]::Show(
                "La copia de seguridad previa leeria $nRb valores uno a uno; en una planta entera eso puede tardar bastante mas que la propia escritura.`r`n`r`nSI: crear la copia igualmente (recomendado).`r`nNO: escribir sin copia de seguridad.`r`nCANCELAR: no escribir nada.",
                'Rollback de planta completa', 'YesNoCancel', 'Warning')
            if ($rMasivo -eq 'Cancel') { return }
            if ($rMasivo -eq 'No') { $saltarRb = $true }
        }
        if ($nRb -gt 0 -and -not $saltarRb) {
            Con "Creando copia de seguridad (rollback) de $nRb valores actuales..." ([System.Drawing.Color]::SteelBlue)
            try {
                $filasRb = 0; $errRb = 0; $ficheroRb = ''
                foreach ($tr in $trabajos) {
                    $script:NcuLog = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
                    if ($script:Cancelar) { break }
                    $paresRb = @()
                    foreach ($t in $tr.tcus) {
                        foreach ($v in $vars) { if ($ADDR_COMANDO -notcontains $v.addr) { $paresRb += ,@{tcu=[int]$t; nombre=$v.nombre} } }
                    }
                    if ($paresRb.Count -eq 0) { continue }
                    $rb = Rollback-Crear $paresRb $tr.cx
                    $filasRb += $rb.filas; $errRb += $rb.errores; $ficheroRb = $rb.fichero
                }
                Con "Rollback guardado: $ficheroRb  ($filasRb valores$(if ($errRb) { ", $errRb sin leer" })). Restaurable con 'CSV por TCU...'." ([System.Drawing.Color]::SteelBlue)
            } catch {
                $r3 = [System.Windows.Forms.MessageBox]::Show(
                    "No se pudo crear la copia de seguridad previa (rollback):`r`n$_`r`n`r`nEscribir AUN ASI, sin copia?", 'Rollback', 'YesNo', 'Warning')
                if ($r3 -ne 'Yes') { return }
            }
            if ($script:Cancelar) { return }
        }
    }

    if ($nTcus -gt 3 -and -not $chkRoll.Checked) {
        Con 'Sin copia de seguridad previa (casilla desmarcada): esta escritura no se podra deshacer.' ([System.Drawing.Color]::Orange)
    }
    $script:Fallidas.Clear(); $btnFallidas.Enabled = $false
    $script:UltimaEscritura = @()
    $ok = 0
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Escribiendo $($vars.Count) variables en $nTcus TCUs  ($donde)" ([System.Drawing.Color]::SteelBlue)
    Prog-Iniciar ($nTcus * @($vars).Count)
    foreach ($tr in $trabajos) {
        $script:NcuLog = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
    if ($script:Cancelar) { break }
    if ($null -ne $tr.ncu) { Con ("--- NCU{0}  ({1})  TCUs {2}-{3} ---" -f $tr.ncu, $tr.ip, $tr.tcus[0], $tr.tcus[-1]) ([System.Drawing.Color]::SteelBlue) }
    $segs = @(Plan-Segmentos $tr.tcus $tr.cx)
    if ($segs.Count -eq 0) { Con 'Ningun TCU cae en los gateways de la NCU.' ([System.Drawing.Color]::Orange); continue }
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true
        if ($tr.cx.gws) { Con ("-- gateway {0}:{1}  ({2} TCUs)" -f $tr.ip, $seg.puerto, $seg.tcus.Count) ([System.Drawing.Color]::SteelBlue) }
        try { Modbus-Conectar $tr.ip $seg.puerto $tr.cx.to }
        catch { $segOk = $false; Con "ERROR de conexion ($($tr.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $fallo = $null; $hecho = $true
            $cambios = @()
            if (-not $segOk) { $hecho = $false; $fallo = "sin conexion ($($cx.ip):$($seg.puerto))" }
            else {
                foreach ($v in $vars) {
                    # valor anterior, para dejar rastro "antes -> despues" en el log
                    $previo = '?'; $ultErr = ''
                    try { $previo = Leer-Decodificado $tcu $VARIABLES[$v.nombre] } catch {}
                    $hecho = $false
                    for ($i = 1; $i -le $cx.reint -and -not $hecho; $i++) {
                        if ($script:Cancelar) { break }
                        try {
                            $e = $v.esc
                            if ($e.modo -eq 'fc16') {
                                FC16-Escribir $tcu $e.addr $e.palabras
                                if ($chkVerif.Checked) {
                                    $leido = FC03-Leer $tcu $e.addr $e.palabras.Count
                                    for ($k = 0; $k -lt $e.palabras.Count; $k++) {
                                        if ($leido[$k] -ne $e.esperado[$k]) { throw "verificacion: escrito $($e.esperado[$k]), leido $($leido[$k])" }
                                    }
                                }
                            } else {
                                FC22-Mascara $tcu $e.addr $e.and $e.or
                                if ($chkVerif.Checked) {
                                    $leido = (FC03-Leer $tcu $e.addr 1)[0]
                                    if (($leido -band $e.mascara) -ne $e.esperadoByte) { throw ("verificacion: mascara no coincide (leido 0x{0:X4})" -f $leido) }
                                }
                            }
                            $hecho = $true
                            $cambios += "$($v.nombre): $previo -> $($v.texto)"
                            $script:UltimaEscritura += [pscustomobject]@{
                                NCU=$script:NcuLog; TCU=[int]$tcu; Variable=$v.nombre
                                Antes=$previo; Despues=$v.texto; Estado='OK'}
                            Auditar 'ESCRIBIR' $script:NcuLog $tcu "$($v.nombre): $previo -> $($v.texto)"
                        } catch {
                            $fallo = "$($v.nombre): $_"
                            $ultErr = "$_"
                            if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                            Start-Sleep -Milliseconds (300 * $i)
                        }
                    }
                    if (-not $hecho) {
                        $script:UltimaEscritura += [pscustomobject]@{
                            NCU=$script:NcuLog; TCU=[int]$tcu; Variable=$v.nombre
                            Antes=$previo; Despues=$v.texto; Estado="FALLO: $ultErr"}
                        Auditar 'ESCRIBIR_FALLO' $script:NcuLog $tcu "$($v.nombre) = $($v.texto): $ultErr"
                        break
                    }
                }
            }
            Prog-Paso @($vars).Count
            if ($script:Cancelar -and -not $hecho) { break }
            if (-not $hecho) {
                [void]$script:Fallidas.Add(@{ncu=$(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' }); tcu=[int]$tcu})
                Con ((Eti-Tcu $tcu) + ("  FALLO   {0}" -f $fallo)) ([System.Drawing.Color]::Salmon)
            } else {
                $ok++
                Con ((Eti-Tcu $tcu) + ("  OK   {0}" -f ($cambios -join ' | '))) ([System.Drawing.Color]::LightGreen)
            }
        }
    }
    }
    Modbus-Cerrar
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "OK: $ok   Fallidas: $($script:Fallidas.Count)" ([System.Drawing.Color]::SteelBlue)
    if (@($script:UltimaEscritura).Count -gt 0) { Marcar-Bloque 'esc' }
    if ($script:Fallidas.Count -gt 0) {
        Con ("TCUs fallidas: " + (($script:Fallidas | ForEach-Object { $(if ($_.ncu) { "NCU$($_.ncu)/$($_.tcu)" } else { "$($_.tcu)" }) }) -join ', ')) ([System.Drawing.Color]::Salmon)
    }
}

$btnEscribir.Add_Click({ Lanzar { Escribir-EnTcus $null } })
# Reintentar fallidas tiene que volver a la NCU de cada una: en una escritura
# de planta completa los numeros de TCU se repiten entre NCUs.
$btnFallidas.Add_Click({ Lanzar {
    if ($script:Fallidas.Count -eq 0) { return }
    Escribir-EnTcus @($script:Fallidas | ForEach-Object { @{ncu=$_.ncu; tcu=[int]$_.tcu} })
} })

$btnNvm.Add_Click({ Lanzar {
    if ($script:Fallidas.Count -gt 0) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Hay $($script:Fallidas.Count) TCUs con fallos.`r`nGuardar en NVM AUN ASI?", 'Atencion', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    $cx = Params-Conexion
    $tcus = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtWTcus.Text 'NVM') $txtGw.Text).tcus
    if (@($tcus).Count -eq 0) { throw 'la seleccion no deja ninguna TCU' }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Guardar configuracion en NVM (40007 bit 15) en $(Eti-Rango $tcus) de $($cx.ip):$($cx.etiqueta)?",
        'Confirmar NVM', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { $segOk = $false; Con "ERROR de conexion ($($cx.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $hecho = $false
            if ($segOk) {
                for ($i = 1; $i -le $cx.reint -and -not $hecho; $i++) {
                    try { FC22-Mascara $tcu 40007 0x7FFF 0x8000; $hecho = $true; Cierre-MarcarSiEsta $script:NcuLog ([int]$tcu) 'nvm' 'OK' }
                    catch {
                        if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                        Start-Sleep -Milliseconds (300 * $i)
                    }
                }
            }
            if ($hecho) { Con ((Eti-Tcu $tcu) + "  NVM guardado") ([System.Drawing.Color]::LightGreen) }
            else        { Con ((Eti-Tcu $tcu) + "  NVM FALLO") ([System.Drawing.Color]::Salmon) }
        }
    }
    Modbus-Cerrar
} })

$btnSimular.Add_Click({
    $vars = @(Recoger-Variables)
    if ($vars.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('La tabla esta vacia.','Aviso'); return }
    if (@($script:UltimaLectura).Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Simular cruza lo que vas a escribir con la ULTIMA LECTURA de esta sesion, y no hay ninguna.`r`n`r`nVe a 'Leer variable', pon estas mismas variables y lee el rango (o la planta completa). Luego vuelve aqui.",
            'Falta una lectura', 'OK', 'Information')
        return
    }
    $sim = @(Simular-Escritura $vars $script:UltimaLectura $null)
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "SIMULACION (no se escribe nada): $($vars.Count) variables contra la ultima lectura de $(@($script:UltimaLectura).Count) TCUs" ([System.Drawing.Color]::SteelBlue)
    $totCambian = 0; $sinLeer = 0
    foreach ($x in $sim) {
        if ($x.Cambian -lt 0) {
            $sinLeer++
            Con ("  {0} = {1}   ->  no estaba en la ultima lectura, no se puede simular" -f $x.Variable, $x.Nuevo) ([System.Drawing.Color]::Orange)
            continue
        }
        $totCambian += $x.Cambian
        $col = $(if ($x.Cambian -eq 0) { [System.Drawing.Color]::LightGreen } else { [System.Drawing.Color]::Orange })
        Con ("  {0} = {1}   ->  cambian {2}, ya lo tienen {3}{4}" -f $x.Variable, $x.Nuevo, $x.Cambian, $x.Iguales,
             $(if ($x.SinDato -gt 0) { ", $($x.SinDato) sin leer" } else { '' })) $col
        if ($x.Reparto) { Con ("      ahora mismo: {0}" -f $x.Reparto) ([System.Drawing.Color]::Gainsboro) }
    }
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    if ($sinLeer -gt 0) { Con "$sinLeer variables no estaban en la lectura: leelas antes si quieres simularlas." ([System.Drawing.Color]::Orange) }
    if ($totCambian -eq 0) { Con 'Nada que cambiar: todas las TCUs leidas ya tienen esos valores.' ([System.Drawing.Color]::LightGreen) }
    else { Con "En total cambiarian $totCambian valores. Mira el reparto de arriba: si una variable tiene DOS valores repartidos por la planta, puede ser a proposito." ([System.Drawing.Color]::Orange) }
    Marcar-Bloque 'esc'
})

# ------------------------- presets y backups -------------------------
$btnPresetSave.Add_Click({
    $vars = @(Recoger-Variables)
    if ($vars.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('La tabla esta vacia.','Aviso'); return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Preset TCU (*.json)|*.json'
    $dlg.FileName = 'preset_tcu.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    # Un preset es para CLONAR, asi que nunca lleva identidad de red: el numero
    # de esclavo y el PAN ID son de cada TCU.
    $ident = @($vars | Where-Object { $ADDR_IDENTIDAD -contains $_.addr })
    $vars  = @($vars | Where-Object { $ADDR_IDENTIDAD -notcontains $_.addr })
    if ($vars.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('La tabla solo tiene registros de identidad de red (esclavo, PAN ID, clave), que no se guardan en un preset.','Aviso'); return }
    $obj = @($vars | ForEach-Object { @{variable=$_.nombre; valor=$_.texto} })
    ConvertTo-Json $obj | Set-Content $dlg.FileName -Encoding UTF8
    Con "Preset guardado: $($dlg.FileName)  ($($vars.Count) variables)" ([System.Drawing.Color]::SteelBlue)
    if ($ident.Count -gt 0) { Con "  fuera del preset $($ident.Count) registros de identidad de red (esclavo/PAN ID/clave): son propios de cada TCU: $(($ident | ForEach-Object { $_.nombre }) -join ', ')" ([System.Drawing.Color]::Orange) }
})

function Cargar-FilasEnGrid($pares) {
    # $pares: lista de objetos con .variable y .valor
    $dgv.Rows.Clear()
    $n = 0
    foreach ($e in $pares) {
        if ($VARIABLES.Contains([string]$e.variable)) {
            # con el filtro activo el nombre puede no estar en el combo: anadirlo
            if (-not $colVar.Items.Contains([string]$e.variable)) { [void]$colVar.Items.Add([string]$e.variable) }
            [void]$dgv.Rows.Add($e.variable, "$($e.valor)", (Info-Variable $e.variable))
            $n++
        } else {
            Con "AVISO: '$($e.variable)' no existe en el mapa - saltada" ([System.Drawing.Color]::Orange)
        }
    }
    return $n
}

$btnPresetLoad.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Preset TCU (*.json)|*.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    try { $obj = Get-Content $dlg.FileName -Raw | ConvertFrom-Json }
    catch { [void][System.Windows.Forms.MessageBox]::Show("No se pudo leer el preset: $_",'Error'); return }
    $n = Cargar-FilasEnGrid $obj
    Con "Preset cargado: $n variables" ([System.Drawing.Color]::SteelBlue)
})

$btnCargarBackup.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Backup TCU (*.json)|*.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    try { $obj = Get-Content $dlg.FileName -Raw | ConvertFrom-Json }
    catch { [void][System.Windows.Forms.MessageBox]::Show("No se pudo leer el backup: $_",'Error'); return }
    if ($obj.tipo -ne 'backup_tcu' -or -not $obj.variables) {
        [void][System.Windows.Forms.MessageBox]::Show('El fichero no es un backup de TCU (usa "Backup JSON" en la pestana Volcar).','Error'); return
    }
    # Un backup marcado incompleto (o con variables sin valor) dejaria la TCU
    # a medio configurar: avisar antes de usarlo como preset.
    $sinValor = @($obj.variables | Where-Object { "$($_.valor)" -eq '' }).Count
    if (($obj.PSObject.Properties['completo'] -and -not $obj.completo) -or $sinValor -gt 0) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Este backup esta INCOMPLETO ($sinValor variables sin valor). Si lo escribes en una TCU, las variables que faltan quedaran sin configurar.`r`n`r`nCargarlo como preset de todos modos?",
            'Backup incompleto', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    # Solo variables de configuracion: fuera comandos, fecha/hora e identidad de
    # red. Un backup se carga aqui para CLONARLO en otra TCU, y el numero de
    # esclavo y el PAN ID del equipo original no se pueden clonar.
    $pares = @(); $nIdent = 0
    foreach ($v in $obj.variables) {
        if (-not $VARIABLES.Contains([string]$v.variable)) { continue }
        $def = $VARIABLES[[string]$v.variable]
        if ($ADDR_COMANDO -contains $def.addr) { continue }
        if ($ADDR_TIEMPO -contains $def.addr) { continue }
        if ($ADDR_IDENTIDAD -contains $def.addr) { $nIdent++; continue }
        if ("$($v.valor)" -eq '') { continue }
        $pares += [pscustomobject]@{variable=$v.variable; valor=$v.valor}
    }
    $n = Cargar-FilasEnGrid $pares
    Con "Backup de TCU $($obj.tcu) ($($obj.fecha)) cargado como preset: $n variables de configuracion (comandos y fecha/hora excluidos)" ([System.Drawing.Color]::SteelBlue)
    if ($nIdent -gt 0) { Con "  excluidos $nIdent registros de identidad de red (zigbee_slave_id, rs485_slave_id, PAN ID, cifrado): son de la TCU $($obj.tcu), no se clonan" ([System.Drawing.Color]::Orange) }
})

# ------------------------- logica LEER VARIABLE -------------------------
# Recorre las filas de una lectura masiva y devuelve las celdas cuyo valor no
# tiene sentido fisico. Pura: se prueba sin planta ni ventana.
# ---------------------------------------------------------------------------
#  Auditoria de baterias
# ---------------------------------------------------------------------------
# El diagnostico ya lee de cada TCU la tension, la corriente, el SoH y las
# temperaturas: estaban en el CSV pero no se juzgaban. Esto los juzga, sin leer
# nada mas. Sistema de 24 V.
#
# Dos criterios, y el segundo es el que mas encuentra: el rango fisico dice si
# un valor es imposible, pero con 754 medidas a la vez la MEDIANA DE LA FLOTA
# dice si un valor es raro. Una TCU a 21 V con las demas a 26 V es la anomala
# aunque 21 V no sea imposible.
$BAT = @{
  vbat_min     = 15000   # por debajo: no hay bateria util conectada
  vbat_bajo    = 22000   # 24 V descargado de verdad
  vbat_alto    = 30000   # por encima: cargador o medida mal
  soc_bajo     = 40      # %
  soh_bajo     = 60      # %
  i_cero       = 50      # mA: por debajo, ni carga ni descarga
  soc_sin_carga= 80      # si esta por debajo y no entra corriente, algo pasa
  tbat_alta    = 55      # C
  tbat_baja    = -20     # C
  desvio_vbat  = 3000    # mV respecto a la mediana de la flota
  desvio_soc   = 30      # puntos respecto a la mediana
  vpanel_min   = 2000    # mV: por debajo, el panel no esta dando nada
  ient_min     = 30      # mA: por debajo, no entra corriente
}

function Mediana($valores) {
    $v = @($valores | Where-Object { $null -ne $_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    if ($v.Count % 2 -eq 1) { return $v[[int](($v.Count - 1) / 2)] }
    return (($v[$v.Count / 2 - 1] + $v[$v.Count / 2]) / 2.0)
}

# Devuelve una fila por problema encontrado. Pura: se prueba sin planta.
# Una fila por TCU con lo que trae el diagnostico de su bateria. Pura: no lee
# nada, solo ordena lo que ya hay. El estado sale de la auditoria, para no tener
# dos criterios distintos diciendo si una bateria esta bien.
# Seccion de carga: la NCU expone un bloque de 50 registros por TCU
# (50000 + (TCU-1)*50) con lo que el bloque compacto de 22 no trae. De ahi solo
# interesan los offsets 21..31: panel, corriente de panel, el estado del
# cargador y sus alarmas. Con esto el equipo DICE si esta cargando, en vez de
# tener que deducirlo de las corrientes.
$BITS_CARGA_ST = @{   # 50029 ChargingStatus
  0='BQ inicializado'; 1='hay energia para cargar'; 2='mosfet ON'; 3='cargador habilitado'
  4='Jeita activo'; 5='bateria llena'; 6='PIC reiniciado'; 7='proteccion de fabrica'
  8='BQ flash comprobada'; 9='BQ flash OK'
}
$BITS_CARGA_AL = @{   # 50031 PowerSectionAlarmRegister
  0='sobrecorriente de motor (HW)'; 1='sobrecorriente de motor (SW)'; 2='fallo del driver de motor'
  3='fallo de com con el BQ'; 4='fallo de com con el DAC'
  8='SOBRECORRIENTE DE CARGA'; 9='TIMEOUT DE CARGA'; 10='TIMEOUT DE CARGA (tension constante)'
}
# lo que de verdad hay que leer de esos dos registros, en una linea. Pura.
function Carga-Texto([int]$estado, [int]$alarmas) {
    $al = @(Bits-Texto $alarmas $BITS_CARGA_AL)
    if ($al.Count -gt 0) { return ($al -join '; ') }
    $t = @()
    if (($estado -band (1 -shl 5)) -ne 0) { $t += 'bateria llena' }
    if (($estado -band (1 -shl 3)) -eq 0) { $t += 'cargador NO habilitado' }
    if (($estado -band (1 -shl 1)) -eq 0) { $t += 'sin energia para cargar' }
    if ($t.Count -eq 0) { return 'cargando' }
    return ($t -join '; ')
}

# Que TCUs hay que pedir y a que NCU, a partir de la tabla ya pintada: asi la
# lectura de carga cubre exactamente lo que se ve, ni una TCU mas. Pura.
function Carga-Pedidos($tabla) {
    $m = @{}
    foreach ($f in @($tabla)) {
        if ("$($f.TCU)" -notmatch '^\d+$') { continue }
        $k = "$($f.NCU)"
        if (-not $m.ContainsKey($k)) { $m[$k] = @() }
        $m[$k] += [int]$f.TCU
    }
    $r = @{}
    foreach ($k in @($m.Keys)) { $r[$k] = @($m[$k] | Sort-Object -Unique) }
    return $r
}

function Bat-Tabla($diag, $hallazgos = $null, $carga = $null) {
    $porTcu = @{}
    foreach ($h in @($hallazgos)) { 
        $k = "$($h.NCU)|$($h.TCU)"
        if (-not $porTcu.ContainsKey($k)) { $porTcu[$k] = @() }
        $porTcu[$k] += "$($h.Tipo)"
    }
    $r = @()
    foreach ($f in @($diag)) {
        if ("$($f.TCU)" -notmatch '^\d+$') { continue }
        $k = "$($f.NCU)|$($f.TCU)"
        $r += ,[pscustomobject]@{
            NCU = "$($f.NCU)"; TCU = [int]$f.TCU
            SoC = "$($f.SoC)"; SoH = "$($f.SoH)"
            Vbat_mV = "$($f.Vbat_mV)"; Ibat_mA = "$($f.Ibat_mA)"
            Vpanel_mV = "$($f.Vpanel_mV)"; Ientrada_mA = "$($f.Ientrada_mA)"
            Tbat_C = "$($f.Tbat_C)"; Tpcb_C = "$($f.Tpcb_C)"
            Dia = $(if ("$($f.Dia)" -eq '1') { 'si' } elseif ("$($f.Dia)" -eq '0') { 'no' } else { '' })
            # vacia mientras no se pulse LEER CARGA: son registros que el
            # diagnostico no lee
            Carga = $(if ($null -ne $carga -and $carga.ContainsKey($k)) { "$($carga[$k].Carga)" } else { '' })
            Estado = $(if ($porTcu.ContainsKey($k)) { ($porTcu[$k] -join '; ') }
                       elseif ("$($f.Salud)" -eq 'OFFLINE') { 'sin datos' } else { 'OK' })
        }
    }
    return $r
}

function Bat-Auditar($diag, $cfg = $null) {
    if ($null -eq $cfg) { $cfg = $BAT }
    $filas = @($diag | Where-Object { "$($_.TCU)" -match '^\d+$' -and "$($_.Salud)" -ne 'OFFLINE' })
    $r = New-Object System.Collections.ArrayList
    if ($filas.Count -eq 0) { return $r.ToArray() }
    # referencia de la flota: la mediana aguanta que haya unas cuantas mal
    $medV = Mediana @($filas | ForEach-Object { $x = 0; if ([int]::TryParse("$($_.Vbat_mV)", [ref]$x) -and $x -gt $cfg.vbat_min) { $x } })
    $medS = Mediana @($filas | ForEach-Object { $x = 0; if ([int]::TryParse("$($_.SoC)", [ref]$x)) { $x } })
    foreach ($f in $filas) {
        $eti = "$($f.NCU)|$($f.TCU)"
        $v = 0; $tieneV = [int]::TryParse("$($f.Vbat_mV)", [ref]$v)
        $i = 0; $tieneI = [int]::TryParse("$($f.Ibat_mA)", [ref]$i)
        $soc = 0; $tieneSoc = [int]::TryParse("$($f.SoC)", [ref]$soc)
        $soh = 0; $tieneSoh = [int]::TryParse("$($f.SoH)", [ref]$soh)
        $tb = 0.0; $tieneTb = [double]::TryParse(("$($f.Tbat_C)" -replace ',', '.'), [Globalization.NumberStyles]::Float, $INV, [ref]$tb)
        $add = { param($tipo, $det, $grav) [void]$r.Add([pscustomobject]@{NCU="$($f.NCU)"; TCU=$f.TCU; Tipo=$tipo; Detalle=$det; Gravedad=$grav}) }
        $sinBat = $false
        # Ojo: ese texto solo sale del diagnostico DIRECTO. El bloque compat de
        # la NCU no tiene ese bit (su mapa lo da como Reserved), asi que en modo
        # via NCU la deteccion recae en la tension, que es la linea de abajo.
        if ("$($f.Alarmas)" -like '*bateria desconectada*') { & $add 'SIN BATERIA' 'la TCU declara bateria desconectada' 'ALARMA'; $sinBat = $true }
        elseif ($tieneV -and $v -lt $cfg.vbat_min) { & $add 'SIN BATERIA' "tension $v mV: no hay bateria util" 'ALARMA'; $sinBat = $true }
        if ($sinBat) { continue }          # lo demas ya no dice nada
        if ($tieneV -and $v -gt $cfg.vbat_alto) { & $add 'SOBRETENSION' "tension $v mV" 'ALARMA' }
        elseif ($tieneV -and $v -lt $cfg.vbat_bajo) { & $add 'TENSION BAJA' "tension $v mV" 'AVISO' }
        if ($tieneSoh -and $soh -gt 0 -and $soh -lt $cfg.soh_bajo) { & $add 'SALUD BAJA' "SoH $soh %: la bateria ya no aguanta" 'AVISO' }
        if ($tieneSoc -and $soc -lt $cfg.soc_bajo) { & $add 'CARGA BAJA' "SoC $soc %" 'AVISO' }
        # De donde viene la falta de carga. El bloque de la NCU trae la tension
        # del panel y la corriente de entrada, asi que se puede separar "el
        # panel no da" de "da pero no llega a la bateria", que mandan a mirar
        # sitios distintos. Sin esos datos (modo directo) queda el aviso
        # generico de siempre.
        $vp = 0; $tieneVp = [int]::TryParse("$($f.Vpanel_mV)", [ref]$vp)
        $ie = 0; $tieneIe = [int]::TryParse("$($f.Ientrada_mA)", [ref]$ie)
        # De NOCHE todos los paneles estan a 0 V: mirarlos entonces marca media
        # planta por nada. El bit 7 del MSR dice si es de dia, y si no se sabe
        # tampoco se mira: mejor callar que dar un aviso falso.
        $esDia = ("$($f.Dia)" -eq '1')
        $flojo = ($esDia -and $tieneSoc -and $soc -lt $cfg.soc_sin_carga)
        if ($flojo -and $tieneVp -and $vp -lt $cfg.vpanel_min) {
            & $add 'PANEL SIN TENSION' "panel a $vp mV con SoC $soc %: mira el panel, el cableado o el fusible" 'AVISO'
        }
        elseif ($flojo -and $tieneIe -and $ie -lt $cfg.ient_min -and $tieneVp -and $vp -ge $cfg.vpanel_min) {
            & $add 'NO ENTRA CORRIENTE' "panel a $vp mV pero solo $ie mA de entrada con SoC $soc %: el panel da y no llega" 'AVISO'
        }
        # ni carga ni descarga con la bateria a medias: panel, fusible o cargador.
        # Tambien solo de dia: de noche no cargar es lo normal.
        elseif ($flojo -and $tieneI -and [Math]::Abs($i) -lt $cfg.i_cero) {
            & $add 'NO CARGA' "corriente $i mA con SoC $soc %" 'AVISO'
        }
        if ($tieneTb -and $tb -gt $cfg.tbat_alta) { & $add 'TEMPERATURA' ("bateria a {0:0.#} C" -f $tb) 'AVISO' }
        elseif ($tieneTb -and $tb -lt $cfg.tbat_baja) { & $add 'TEMPERATURA' ("bateria a {0:0.#} C" -f $tb) 'AVISO' }
        # y lo que se sale de la flota aunque este dentro de rango
        if ($null -ne $medV -and $tieneV -and $v -gt $cfg.vbat_min -and ($medV - $v) -gt $cfg.desvio_vbat) {
            & $add 'FUERA DE LA FLOTA' ("tension $v mV con la flota en {0:0} mV" -f $medV) 'AVISO'
        }
        if ($null -ne $medS -and $tieneSoc -and ($medS - $soc) -gt $cfg.desvio_soc) {
            & $add 'FUERA DE LA FLOTA' ("SoC $soc % con la flota en {0:0} %" -f $medS) 'AVISO'
        }
    }
    return $r.ToArray()
}

function Sospechas-Lectura($filas) {
    $r = New-Object System.Collections.ArrayList
    foreach ($f in @($filas)) {
        $hay = @{}
        foreach ($pr in $f.PSObject.Properties) {
            if (@('NCU','TCU','Estado') -contains $pr.Name) { continue }
            $hay[$pr.Name] = "$($pr.Value)"
            $motivo = Rango-Sospechoso $pr.Name "$($pr.Value)"
            if ($motivo) { [void]$r.Add([pscustomobject]@{NCU="$($f.NCU)"; TCU=$f.TCU; Variable=$pr.Name; Valor="$($pr.Value)"; Motivo=$motivo}) }
        }
        # el limite este por encima (o igual) que el oeste: el seguidor no
        # tendria recorrido, asi que uno de los dos esta mal escrito
        foreach ($par in $PARES_TILT) {
            if (-not ($hay.ContainsKey($par.max) -and $hay.ContainsKey($par.min))) { continue }
            $vMax = 0.0; $vMin = 0.0
            if (-not [double]::TryParse($hay[$par.max].Replace(',', '.'), [Globalization.NumberStyles]::Float, $INV, [ref]$vMax)) { continue }
            if (-not [double]::TryParse($hay[$par.min].Replace(',', '.'), [Globalization.NumberStyles]::Float, $INV, [ref]$vMin)) { continue }
            if ($vMin -lt $vMax) { continue }
            [void]$r.Add([pscustomobject]@{NCU="$($f.NCU)"; TCU=$f.TCU; Variable=$par.min; Valor=$hay[$par.min]
                Motivo=("el limite este no puede ser mayor o igual que el oeste ({0}): el seguidor se queda sin recorrido" -f $hay[$par.max])})
        }
    }
    return $r.ToArray()
}

# Un valor merece una segunda lectura si es imposible para su variable o si se
# sale de lo que llevan TODAS las demas TCUs leidas hasta ahora. La razon es que
# el guardarrail de respuestas descolocadas NO cubre dos lecturas de la misma
# forma (dos FC03 de un registro seguidos): si la NCU sella el cuerpo de la
# anterior con el ID de la peticion en curso, cuadra todo y se cuela. Confirmar
# solo las anomalias cuesta unas pocas lecturas de mas por planta.
# $reparto: tabla valor -> cuantas TCUs lo tienen, de las ya leidas.
function Merece-Confirmar([string]$nombre, [string]$valor, $reparto, [int]$minMuestras = 8) {
    if ("$valor" -eq '') { return $false }
    if (Rango-Sospechoso $nombre $valor) { return $true }
    if ($null -eq $reparto) { return $false }
    $total = 0
    foreach ($k in $reparto.Keys) { $total += [int]$reparto[$k] }
    if ($total -lt $minMuestras) { return $false }        # aun no hay mayoria que valga
    return (-not $reparto.ContainsKey("$valor"))          # valor nunca visto: sospechoso
}

# A partir de una lectura masiva, propone el valor correcto para cada celda
# imposible: el valor MAYORITARIO entre los que si son plausibles para esa
# variable. Devuelve las filas del CSV de correccion y los avisos de lo que no
# ha podido proponer. Pura: se prueba sin planta ni ventana.
function Correccion-DeLectura($filas) {
    $r = New-Object System.Collections.ArrayList
    $avisos = New-Object System.Collections.ArrayList
    $todas = @($filas)
    if ($todas.Count -eq 0) { return @{filas=@(); avisos=@()} }
    # Se parte de lo que ya ha marcado Sospechas-Lectura, para no repetir aqui
    # las reglas: asi la comprobacion de pares (limite este por encima del
    # oeste) tambien entra en la correccion.
    $marcadas = @{}
    foreach ($sp in @(Sospechas-Lectura $todas)) { $marcadas["$($sp.NCU)|$($sp.TCU)|$($sp.Variable)"] = $true }
    $cols = @($todas[0].PSObject.Properties.Name | Where-Object { @('NCU','TCU','Estado') -notcontains $_ })
    foreach ($col in $cols) {
        # solo se puede corregir lo que se puede escribir
        if (-not $VARIABLES.Contains($col)) { continue }
        $cuenta = @{}
        $malas = @()
        foreach ($f in $todas) {
            $v = "$($f.$col)".Trim()
            if ($v -eq '' -or $v -eq '-') { continue }
            if ($marcadas.ContainsKey("$($f.NCU)|$($f.TCU)|$col")) { $malas += ,$f; continue }
            $cuenta[$v] = 1 + [int]$cuenta[$v]
        }
        if ($malas.Count -eq 0) { continue }
        if ($cuenta.Keys.Count -eq 0) {
            [void]$avisos.Add("$col : ninguna TCU tiene un valor plausible, no hay de donde sacar el correcto")
            continue
        }
        $orden = @($cuenta.Keys | Sort-Object { - [int]$cuenta[$_] }, { "$_" })
        $bueno = $orden[0]
        $nBueno = [int]$cuenta[$bueno]
        if ($orden.Count -gt 1 -and [int]$cuenta[$orden[1]] -eq $nBueno) {
            [void]$avisos.Add("$col : empate entre '$bueno' y '$($orden[1])' ($nBueno TCUs cada uno), no se propone nada")
            continue
        }
        foreach ($f in $malas) { [void]$r.Add([pscustomobject]@{NCU="$($f.NCU)"; TCU=$f.TCU; Variable=$col; Valor=$bueno}) }
        [void]$avisos.Add("$col : $($malas.Count) TCUs a corregir con $bueno (el valor de las otras $nBueno)")
    }
    return @{filas=$r.ToArray(); avisos=$avisos.ToArray()}
}

function Def-DeLectura([string]$sel) {
    if ($sel -like 'ESTADO *') { return $ESTADO[$sel.Substring(7)] }
    return $VARIABLES[$sel]
}

# De un preset (o de un backup completo) saca los nombres de variable que se
# pueden leer, sin valores: para la lectura solo importa QUE se lee. Se aceptan
# los dos formatos que ya se guardan, la lista suelta y el backup_tcu.
# Pura: se prueba sin ventana ni ficheros.
function Preset-Nombres($obj) {
    $pares = @()
    if ($null -ne $obj -and $obj.PSObject.Properties['tipo'] -and "$($obj.tipo)" -eq 'backup_tcu') { $pares = @($obj.variables) }
    else { $pares = @($obj) }
    $nombres = New-Object System.Collections.ArrayList
    $fuera = New-Object System.Collections.ArrayList
    foreach ($e in $pares) {
        if ($null -eq $e) { continue }
        $n = "$($e.variable)"
        if ($n -eq '') { continue }
        if (-not $VARIABLES.Contains($n)) { if (-not $fuera.Contains($n)) { [void]$fuera.Add($n) }; continue }
        # un preset con la misma variable dos veces no tiene que dar dos filas:
        # se leeria dos veces lo mismo y la tabla saldria con columnas repetidas
        if ($nombres.Contains($n)) { continue }
        [void]$nombres.Add($n)
    }
    return @{nombres = $nombres.ToArray(); fuera = $fuera.ToArray()}
}

$btnLeer.Add_Click({ Lanzar {
    $nombres = @(Vars-DeTablaLeer)
    if ($nombres.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Elige al menos una variable en la tabla.','Aviso'); return }
    $defs = @($nombres | ForEach-Object { @{nombre=[string]$_; vdef=(Def-DeLectura $_)} })
    $cx = Params-Conexion
    $trabajos = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtLTcus.Text 'Leer') $txtGw.Text)
    if ($trabajos.Count -eq 0) { Con 'La planta no tiene NCUs con gateways definidos.' ([System.Drawing.Color]::Orange); return }
    $lvL.Items.Clear(); $lvL.Columns.Clear(); $script:UltimaLectura = @()
    $script:ReconfIntentos = 0; $script:ReconfConfirmados = 0; $script:ReconfCambios = 0; $script:ReconfSinAcuerdo = 0
    [void]$lvL.Columns.Add('NCU', 44)
    [void]$lvL.Columns.Add('TCU', 48)
    foreach ($d in $defs) { [void]$lvL.Columns.Add($d.nombre, [math]::Max(110, [math]::Min(220, [int](746 / $defs.Count)))) }
    # 'Estado' se leia como "coincide con el preset" y no lo es: esta pestana
    # LEE, no compara. Quien compara es la Auditoria. El nombre de la propiedad
    # se queda ('Estado') porque el CSV y Aud-Indice van por el.
    [void]$lvL.Columns.Add('Respuesta', 130)
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    if ($cx.multi) {
        $totTcus = 0; foreach ($tr in $trabajos) { $totTcus += @($tr.tcus).Count }
        Con "Leyendo $($defs.Count) variable(s) en PLANTA completa: $($trabajos.Count) NCUs, $totTcus TCUs (rangos automaticos)" ([System.Drawing.Color]::SteelBlue)
    } else {
        Con "Leyendo $($defs.Count) variable(s) en $(Eti-Rango @($trabajos).tcus)  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    }
    $nLeerTot = 0; foreach ($tr in $trabajos) { $nLeerTot += @($tr.tcus).Count }
    Prog-Iniciar ($nLeerTot * @($defs).Count)
    $valores = @{}
    foreach ($d in $defs) { $valores[$d.nombre] = @{} }
    foreach ($tr in $trabajos) {
        $script:NcuLog = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
    if ($script:Cancelar) { break }
    $etNcu = ''
    if ($null -ne $tr.ncu) {
        $etNcu = "$($tr.ncu)"
        Con ("--- NCU{0}  ({1})  TCUs {2}-{3} ---" -f $tr.ncu, $tr.ip, $tr.tcus[0], $tr.tcus[-1]) ([System.Drawing.Color]::SteelBlue)
    }
    $segs = @(Plan-Segmentos $tr.tcus $tr.cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true; $errSeg = ''
        try { Modbus-Conectar $tr.ip $seg.puerto $tr.cx.to }
        catch { $segOk = $false; $errSeg = "sin conexion ($($tr.ip):$($seg.puerto))"; Con "ERROR: $errSeg : $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $fila = [ordered]@{NCU=$etNcu; TCU=[int]$tcu}
            $errores = 0; $err = $errSeg
            # Si la primera variable agota los reintentos por falta de respuesta,
            # el TCU esta mudo: no tiene sentido esperar el timeout completo de
            # las demas. Con 5 variables, 8 s y 3 reintentos eso son 2 minutos
            # por TCU muerto. Un fallo Modbus (direccion ilegal, etc.) NO cuenta:
            # ahi el equipo si contesta y el resto puede leerse.
            $mudo = $false; $iVar = -1
            foreach ($d in $defs) {
                if ($script:Cancelar) { break }
                $iVar++
                $val = $null
                $sinRespuesta = $false
                if ($segOk -and -not $mudo) {
                    for ($i = 1; $i -le $tr.cx.reint -and $null -eq $val; $i++) {
                        try { $val = Leer-Decodificado $tcu $d.vdef; $sinRespuesta = $false }
                        catch {
                            $err = "$_"
                            $sinRespuesta = -not (Es-ExcepcionModbus $_.Exception.Message)
                            if ($sinRespuesta) { Modbus-Reconectar }
                            Start-Sleep -Milliseconds (200 * $i)
                        }
                    }
                }
                # Segunda lectura de los valores anomalos, con el socket
                # rehecho: una respuesta descolocada no puede repetirse en una
                # conexion limpia, asi que si el valor se confirma es real.
                if ($null -ne $val -and (Merece-Confirmar $d.nombre "$val" $valores[$d.nombre])) {
                    $script:ReconfIntentos++
                    $val2 = $null
                    try { Modbus-Reconectar; $val2 = Leer-Decodificado $tcu $d.vdef } catch {}
                    if ($null -ne $val2 -and "$val2" -ne "$val") {
                        # las dos lecturas no coinciden: una de las dos venia
                        # descolocada. Se desempata con una tercera.
                        $val3 = $null
                        try { Modbus-Reconectar; $val3 = Leer-Decodificado $tcu $d.vdef } catch {}
                        $bueno = $(if ("$val3" -eq "$val") { "$val" } elseif ("$val3" -eq "$val2") { "$val2" } else { $null })
                        if ($null -eq $bueno) {
                            Con ((Eti-Tcu $tcu) + "  $($d.nombre): tres lecturas distintas ($val / $val2 / $val3), no me fio de ninguna") ([System.Drawing.Color]::Salmon)
                            $script:ReconfSinAcuerdo++
                            $val = $null; $sinRespuesta = $false; $err = "$($d.nombre): lecturas inconsistentes"
                        } else {
                            Con ((Eti-Tcu $tcu) + "  $($d.nombre): la primera lectura dio $val y era falsa; el valor es $bueno") ([System.Drawing.Color]::Orange)
                            $script:ReconfCambios++
                            $val = $bueno
                        }
                    } elseif ($null -ne $val2) {
                        $script:ReconfConfirmados++
                    }
                }
                if ($null -ne $val) {
                    $fila[$d.nombre] = $val
                    if (-not $valores[$d.nombre].ContainsKey($val)) { $valores[$d.nombre][$val] = 0 }
                    $valores[$d.nombre][$val]++
                } else {
                    $fila[$d.nombre] = ''; $errores++
                    if ($sinRespuesta -and $iVar -eq 0) { $mudo = $true }
                }
            }
            $estado = 'OK'
            if ($mudo) { $estado = "no responde: $err" }
            elseif ($errores -gt 0) { $estado = "$errores fallos: $err" }
            $fila['Estado'] = $estado
            $item = New-Object System.Windows.Forms.ListViewItem($etNcu)
            [void]$item.SubItems.Add("$tcu")
            foreach ($d in $defs) {
                $v = $fila[$d.nombre]
                if ("$v" -eq '') { $v = '-' }
                [void]$item.SubItems.Add("$v")
            }
            [void]$item.SubItems.Add($estado)
            if ($errores -gt 0) { $item.ForeColor = [System.Drawing.Color]::Firebrick }
            $lvL.Items.Add($item) | Out-Null
            $script:UltimaLectura += [pscustomobject]$fila
            Prog-Paso @($defs).Count
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    }
    Modbus-Cerrar
    $nLeidas = @($script:UltimaLectura).Count
    foreach ($d in $defs) {
        $v = $valores[$d.nombre]
        if ($v.Count -eq 1 -and $nLeidas -le 1) {
            Con ("  {0} = {1}" -f $d.nombre, @($v.Keys)[0]) ([System.Drawing.Color]::LightGreen)
        } elseif ($v.Count -eq 1) {
            Con ("  {0}: todas coinciden = {1}" -f $d.nombre, @($v.Keys)[0]) ([System.Drawing.Color]::LightGreen)
        } elseif ($v.Count -gt 1) {
            Con ("  ATENCION {0}: {1} valores distintos:" -f $d.nombre, $v.Count) ([System.Drawing.Color]::Orange)
            foreach ($k in $v.Keys) { Con ("     {0}  en {1} TCUs" -f $k, $v[$k]) ([System.Drawing.Color]::Orange) }
        }
    }
    if ($script:ReconfIntentos -gt 0) {
        Con ("Segunda lectura de valores anomalos: {0} comprobados, {1} confirmados, {2} eran falsos, {3} sin acuerdo." -f $script:ReconfIntentos, $script:ReconfConfirmados, $script:ReconfCambios, $script:ReconfSinAcuerdo) ([System.Drawing.Color]::SteelBlue)
        if ($script:ReconfCambios -gt 0) { Con "  Los que salieron falsos eran respuestas descolocadas de la NCU que el guardarrail no ve (dos lecturas de la misma forma). Sin esta segunda lectura habrian salido como buenos." ([System.Drawing.Color]::Orange) }
    }
    # Cordura: un valor puede coincidir en toda la planta y aun asi ser
    # imposible, asi que esto va aparte del reparto de valores.
    # queda constancia en el PC de planta: es lo que contesta "desde cuando"
    $nH = Historial-Anotar (Nombre-Planta) $script:UltimaLectura @($defs | ForEach-Object { $_.nombre })
    if ($nH -gt 0) { Con "Historial local: $nH valores anotados en $(Historial-Fichero (Nombre-Planta))" ([System.Drawing.Color]::Gainsboro) }
    $sospechas = @(Sospechas-Lectura $script:UltimaLectura)
    if ($sospechas.Count -gt 0) {
        Con ('-' * 96) ([System.Drawing.Color]::Salmon)
        Con "VALORES IMPOSIBLES: $($sospechas.Count) TCUs con algun valor fuera del rango fisico de la variable." ([System.Drawing.Color]::Salmon)
        foreach ($sp in $sospechas) { Con ("  {0}{1,3}  {2} = {3}  -> {4}" -f $(if ($sp.NCU) { "NCU$($sp.NCU) TCU " } else { 'TCU ' }), $sp.TCU, $sp.Variable, $sp.Valor, $sp.Motivo) ([System.Drawing.Color]::Salmon) }
        # CSV listo para aplicar la correccion, con el valor mayoritario de la
        # planta. Se genera solo: escribirlo a mano TCU a TCU es lo que se hacia
        # antes y es donde se cuelan los errores.
        $corr = Correccion-DeLectura $script:UltimaLectura
        foreach ($a in $corr.avisos) { Con "  $a" ([System.Drawing.Color]::Orange) }
        if (@($corr.filas).Count -gt 0) {
            try {
                $dirC = Join-Path $PSScriptRoot 'correcciones'
                if (-not (Test-Path $dirC)) { New-Item -ItemType Directory -Path $dirC | Out-Null }
                $fC = Join-Path $dirC ('correccion_' + (Planta-Fichero) + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv')
                $lin = @('NCU;TCU;variable;valor')
                foreach ($f in $corr.filas) { $lin += "$($f.NCU);$($f.TCU);$($f.Variable);$($f.Valor)" }
                Set-Content -Path $fC -Value $lin -Encoding UTF8
                Con "CSV de correccion generado: $fC  ($(@($corr.filas).Count) escrituras)" ([System.Drawing.Color]::SteelBlue)
                Con "  Para aplicarlo: pestana Escribir, entrada (Planta completa), boton 'CSV por TCU...'. REVISALO ANTES: propone el valor mayoritario, y la mayoria no siempre es lo que quieres." ([System.Drawing.Color]::SteelBlue)
            } catch { Con "No se pudo escribir el CSV de correccion: $_" ([System.Drawing.Color]::Orange) }
        }
    }
    # que nadie lea "OK" como "coincide": aqui solo se lee
    Con "La columna Respuesta dice si la TCU contesto, NO si el valor es el que toca. Para comparar contra un preset, pestana Auditoria con 'Usar la ultima lectura' marcado." ([System.Drawing.Color]::Gainsboro)
    Marcar-Bloque 'lectura'
    [void](Trabajo-Guardar 'lectura' $script:UltimaLectura "$(@($defs).Count) variables en $(@($script:UltimaLectura).Count) TCUs")
} })

$btnLCsv.Add_Click({
    [void](Exportar-Csv $script:UltimaLectura 'lectura')
})

# ---------------------------------------------------------------------------
#  Cierre post-actualizacion
# ---------------------------------------------------------------------------
# Una TCU actualizada NO esta terminada: le faltan los parametros (la
# actualizacion puede llevarselos), guardarlos en NVM y volver a AUTO. Nada
# llevaba la cuenta, y por eso se olvidaban. Esto es esa cuenta, y sobrevive a
# cerrar el programa: se guarda por planta en cierre/.
#
# La lista NO escribe nada. Se rellena sola con lo que ya se hace (verificar,
# auditar, NVM, diagnosticar) y los botones solo PREPARAN: dejan la pestana que
# toca cargada y te llevan alli. Escribir sigue viviendo en Escribir.
$script:Cierre = @{}

function Cierre-Fichero([string]$planta) {
    $dir = Join-Path $PSScriptRoot 'cierre'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    return Join-Path $dir (($planta -replace '[^\w\-\.]', '_') + '.json')
}
# De lo leido del JSON a la tabla de la lista. Pura: se prueba sin ficheros.
#
# El filtro de la TCU no es paranoia. En PowerShell 5.1 -el del PC de planta-
# ConvertFrom-Json '[]' devuelve $null, y @($null) tiene UN elemento, no cero.
# Una lista vacia guardada volvia por tanto como una entrada de nada: NCU en
# blanco, TCU 0 y "falta parametros, NVM, modo AUTO", que ademas no se podia
# cerrar nunca. Es la misma trampa que ya se llevo por delante un recuadro de la
# portada del informe.
function Cierre-DeJson($datos) {
    $r = @{}
    foreach ($e in @($datos)) {
        if ($null -eq $e) { continue }
        $t = 0
        if (-not [int]::TryParse("$($e.tcu)", [ref]$t)) { continue }
        if ($t -le 0) { continue }
        $r["$($e.ncu)|$t"] = @{ncu="$($e.ncu)"; tcu=$t; fw="$($e.fw)"
            params="$($e.params)"; nvm="$($e.nvm)"; modo="$($e.modo)"; desde="$($e.desde)"}
    }
    return $r
}
# ---------------------------------------------------------------------------
#  Trabajos guardados
# ---------------------------------------------------------------------------
# El diagnostico, el inventario, la auditoria, la lectura y las baterias vivian
# solo en memoria: lanzar lo siguiente pisaba lo anterior. En una campana eso es
# lo normal -auditas el firmware, y mientras el updater trabaja quieres
# diagnosticar-, y al volver ya no estaba lo de antes. Ahora cada operacion que
# termina se guarda sola en trabajos/, y desde su pestana se vuelve a cargar.
#
# (El cierre no entra aqui: ese ya se guardaba por planta en cierre/.)
# 'cols' son las propiedades que van a la tabla de esa pestana, en su orden.
$TRABAJO_TIPOS = @{
  diag       = @{titulo='Diagnostico'; var='UltimoDiag'
                 cols=@('NCU','TCU','GW','Salud','Modo','Tilt','Objetivo','Dif','SoC','Edad_s','Alarmas')}
  comm       = @{titulo='Test comm';   var='UltimoDiag'
                 cols=@('NCU','TCU','GW','Salud','Modo','Tilt','Objetivo','Dif','SoC','Edad_s','Alarmas')}
  inventario = @{titulo='Inventario';  var='UltimoInv'
                 cols=@('NCU','TCU','Serie','MAC','FW','FW_fabrica','HW','Fecha_fab','Nota')}
  auditoria  = @{titulo='Auditoria';   var='UltimaAud'
                 cols=@('NCU','TCU','Variable','Esperado','Leido','Nota')}
  lectura    = @{titulo='Lectura';     var='UltimaLectura'; cols=@()}
  baterias   = @{titulo='Baterias';    var='UltimaBatTabla'
                 cols=@('NCU','TCU','SoC','SoH','Vbat_mV','Ibat_mA','Vpanel_mV','Ientrada_mA','Tbat_C','Tpcb_C','Dia','Carga','Estado')}
}
$TRABAJOS_MAX = 20        # por tipo y planta: lo viejo se va solo

# Nombre de fichero de un trabajo. La planta va dentro para poder tener varias
# a la vez sin mezclarlas, y el sello ordena solo. Pura.
function Trabajo-Fichero([string]$tipo, [string]$planta, [string]$sello) {
    $p = ("$planta" -replace '[^\w\-]', '_')
    if ($p -eq '') { $p = 'sin_planta' }
    return "$tipo`__${p}__$sello.json"
}
# Una linea de la lista a partir de lo que trae el JSON. Pura.
function Trabajo-Resumen($obj, [string]$fichero = '') {
    $tipo = "$($obj.tipo)"
    $t = $TRABAJO_TIPOS[$tipo]
    return [pscustomobject]@{
        Fecha   = "$($obj.fecha)"
        Tipo    = $(if ($t) { $t.titulo } else { $tipo })
        Planta  = "$($obj.planta)"
        # @($null).Count es 1 en PS 5.1: un trabajo sin filas diria que tiene una
        Filas   = $(if ($null -eq $obj.filas) { 0 } else { @($obj.filas).Count })
        Nota    = "$($obj.nota)"
        Tecnico = "$($obj.tecnico)"
        tipoRaw = $tipo
        fichero = $fichero
    }
}
# Lo mas reciente primero: en campo interesa lo de hace un rato, no lo de ayer.
# Pura.
function Trabajos-Ordenar($lista) {
    return @(@($lista) | Sort-Object -Property @{Expression={"$($_.Fecha)"}; Descending=$true}, @{Expression={"$($_.Tipo)"}})
}
# Que ficheros sobran de un tipo: se guardan los $max mas nuevos. Sin esto, una
# semana de campana llena la carpeta de diagnosticos de 754 filas. Pura.
function Trabajos-Podar($ficheros, [int]$max = 20) {
    $l = @(@($ficheros) | Sort-Object -Descending)
    if ($l.Count -le $max) { return @() }
    return @($l[$max..($l.Count - 1)])
}

# Guardar a fichero: el mismo dialogo, el mismo sello de fecha y el mismo aviso
# en consola, que estaban copiados en diecinueve sitios. Y el MISMO separador:
# siete de los CSV salian con coma y en un Excel en espanol se abren en una sola
# columna. Devuelve la ruta, o '' si se cancela.
# El nombre de la planta, apto para un nombre de fichero. Estaba copiado con su
# expresion regular en cinco exportadores. Pura.
function Planta-Fichero { return ((Nombre-Planta) -replace '[^\w\-\.]', '_') }

function Guardar-Como([string]$pref, [string]$ext, [string]$etiqueta = '') {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = $(if ($ext -eq 'csv') { 'CSV (*.csv)|*.csv' } else { "$(if ($etiqueta) { $etiqueta } else { 'JSON' }) (*.$ext)|*.$ext" })
    $dlg.FileName = $pref + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + ".$ext"
    if ($dlg.ShowDialog() -ne 'OK') { return '' }
    return $dlg.FileName
}
function Exportar-Csv($filas, [string]$pref, [string]$que = 'CSV') {
    if (@($filas).Count -eq 0) { Con "No hay nada que exportar." ([System.Drawing.Color]::Orange); return '' }
    $f = Guardar-Como $pref 'csv'
    if ($f -eq '') { return '' }
    try {
        # ';' siempre: es lo que espera el Excel de los portatiles de campo
        $filas | Export-Csv $f -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Con "$que exportado: $f  ($(@($filas).Count) filas)" ([System.Drawing.Color]::SteelBlue)
        return $f
    } catch { Con "No se ha podido escribir el CSV: $_" ([System.Drawing.Color]::Salmon); return '' }
}
function Exportar-Json($obj, [string]$pref, [string]$que = 'JSON', [int]$prof = 5) {
    $f = Guardar-Como $pref 'json'
    if ($f -eq '') { return '' }
    try {
        ConvertTo-Json $obj -Depth $prof | Set-Content $f -Encoding UTF8
        Con "$que exportado: $f" ([System.Drawing.Color]::SteelBlue)
        return $f
    } catch { Con "No se ha podido escribir el JSON: $_" ([System.Drawing.Color]::Salmon); return '' }
}

function Trabajos-Dir {
    $dir = Join-Path $PSScriptRoot 'trabajos'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    return $dir
}
# Guarda lo que acaba de terminar. Nunca revienta la operacion que lo llama: si
# el disco falla, se avisa y ya.
function Trabajo-Guardar([string]$tipo, $filas, [string]$nota = '') {
    if (@($filas).Count -eq 0) { return '' }
    try {
        $dir = Trabajos-Dir
        $sello = Get-Date -Format 'yyyyMMdd_HHmmss'
        $planta = Nombre-Planta
        $f = Join-Path $dir (Trabajo-Fichero $tipo $planta $sello)
        $o = @{tipo=$tipo; planta=$planta; fecha=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
               toolbox=$VERSION_TOOLBOX; tecnico=$script:Usuario.usuario; nota=$nota; filas=@($filas)}
        ConvertTo-Json $o -Depth 6 | Set-Content $f -Encoding UTF8
        # y a limpiar lo viejo de ESE tipo y ESA planta
        $pref = ("$tipo`__" + ("$planta" -replace '[^\w\-]', '_') + '__')
        $mios = @(Get-ChildItem $dir -Filter "$pref*.json" -File | ForEach-Object { $_.Name })
        foreach ($v in @(Trabajos-Podar $mios $TRABAJOS_MAX)) {
            try { Remove-Item (Join-Path $dir $v) -Force } catch {}
        }
        return $f
    } catch {
        Con "AVISO: no se ha podido guardar el trabajo ($_). Lo de pantalla sigue estando." ([System.Drawing.Color]::Orange)
        return ''
    }
}

function Cierre-Cargar([string]$planta) {
    $script:Cierre = @{}
    try {
        $f = Cierre-Fichero $planta
        if (-not (Test-Path $f)) { return }
        $script:Cierre = Cierre-DeJson (Get-Content $f -Raw | ConvertFrom-Json)
    } catch {}
}
function Cierre-Guardar([string]$planta) {
    try {
        $lista = @($script:Cierre.Values | Sort-Object { [int]("0" + "$($_.ncu)") }, { [int]$_.tcu })
        ConvertTo-Json @($lista) -Depth 4 | Set-Content (Cierre-Fichero $planta) -Encoding UTF8
    } catch {}
}
# Alta o actualizacion de una TCU en la lista. $campo vacio = solo darla de alta.
function Cierre-Marcar([string]$ncu, [int]$tcu, [string]$campo, [string]$valor, [string]$fw = '') {
    if ($tcu -le 0) { return }        # no existe la TCU 0: seria una fila que no se puede cerrar
    $k = "$ncu|$tcu"
    if (-not $script:Cierre.ContainsKey($k)) {
        $script:Cierre[$k] = @{ncu=$ncu; tcu=$tcu; fw=$fw; params=''; nvm=''; modo=''; desde=(Get-Date -Format 'yyyy-MM-dd HH:mm')}
    }
    if ($fw -ne '') { $script:Cierre[$k].fw = $fw }
    if ($campo -ne '') { $script:Cierre[$k][$campo] = $valor }
}
# Solo toca a las que YA estan en la lista: auditar o diagnosticar la planta
# entera no puede meter en la cola a 754 TCUs que nadie ha actualizado.
function Cierre-MarcarSiEsta([string]$ncu, [int]$tcu, [string]$campo, [string]$valor) {
    $k = "$ncu|$tcu"
    if (-not $script:Cierre.ContainsKey($k)) { return }
    $script:Cierre[$k][$campo] = $valor
}
# Que le falta a una TCU para estar cerrada. Pura: se prueba sin ventana.
function Cierre-Estado($f) {
    $falta = @()
    if ("$($f.params)" -ne 'OK') { $falta += 'parametros' }
    if ("$($f.nvm)" -ne 'OK') { $falta += 'NVM' }
    if ("$($f.modo)" -ne 'OK') { $falta += 'modo AUTO' }
    if ($falta.Count -eq 0) { return 'CERRADA' }
    return 'falta ' + ($falta -join ', ')
}
function Cierre-Pendientes {
    return @($script:Cierre.Values | Where-Object { (Cierre-Estado $_) -ne 'CERRADA' })
}

# ---------------------------------------------------------------------------
#  Barridos de planta en paralelo
# ---------------------------------------------------------------------------
# Un barrido de 754 TCUs por el bloque compacto tarda cerca de una hora en
# serie, y sin embargo cada NCU es una conexion TCP independiente: no compiten
# entre si. Lanzandolas a la vez, esa hora son minutos.
#
# El truco es que la logica de este script (todo lo anterior a la ventana) es
# autonoma: las pruebas ya la evaluan sueltas. Cada hilo se lleva una copia y
# con ella su PROPIO estado de conexion ($script:Tcp, $Tid, $Sucio), que es
# justo lo que hace falta: compartirlo seria volver a mezclar respuestas.
$script:LogicaCache = $null
# El parametro $ruta existe para las pruebas: ahi la logica se evalua suelta y
# $PSCommandPath apunta al fichero de pruebas, no a la herramienta.
function Logica-Propia([string]$ruta = '') {
    if ($ruta -eq '' -and $script:LogicaCache) { return $script:LogicaCache }
    $cachear = ($ruta -eq '')
    if ($ruta -eq '') {
        $ruta = $PSCommandPath
        if (-not $ruta -or -not (Test-Path $ruta)) { $ruta = Join-Path $PSScriptRoot 'TCU_Toolbox.ps1' }
    }
    if (-not $ruta -or -not (Test-Path $ruta)) { throw 'no se puede localizar el propio script para repartirlo entre hilos' }
    $src = Get-Content $ruta -Raw
    $ini = $src.IndexOf('$VERSION_TOOLBOX')
    $fin = $src.IndexOf('$form = New-Object System.Windows.Forms.Form')
    if ($ini -lt 0 -or $fin -lt 0) { throw 'no se ha podido separar la logica de la ventana' }
    # $PSScriptRoot no se puede asignar dentro del hilo: se cambia por una
    # variable normal que si se puede pasar como argumento.
    # El token se construye a trozos a proposito: esta funcion habla DE el, y si
    # se escribe entero cualquiera que reescriba el fuente (las pruebas lo hacen)
    # se lo lleva por delante y el reemplazo deja de encontrar nada.
    $tokenRaiz = '$' + 'PSScriptRoot'
    $texto = $src.Substring($ini, $fin - $ini).Replace($tokenRaiz, '$RaizTb')
    if ($cachear) { $script:LogicaCache = $texto }
    return $texto
}

# Reparte una lista de tareas entre hilos. Cada tarea recibe (logica, raiz,
# argumento) y devuelve lo que devuelva $cuerpo. Los fallos de un hilo no
# tumban el barrido: esa tarea devuelve $null y se sigue.
# $alTerminar se llama en el hilo principal cada vez que una tarea acaba, con
# su tarea como argumento. Sin eso, EndInvoke en orden bloquea hasta el final y
# la barra de avance se queda en 0 todo el barrido, que es como se vio.
function Paralelo-Ejecutar($tareas, [scriptblock]$cuerpo, [int]$hilos = 8, [string]$ruta = '', [scriptblock]$alTerminar = $null) {
    $lista = @($tareas)
    if ($lista.Count -eq 0) { return @() }
    $logica = Logica-Propia $ruta
    $raiz = $(if ($ruta -ne '') { Split-Path $ruta -Parent } else { $PSScriptRoot })
    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, [Math]::Min($hilos, $lista.Count)))
    $pool.Open()
    $envio = @()
    try {
        foreach ($t in $lista) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($cuerpo).AddArgument($logica).AddArgument($raiz).AddArgument($t)
            $envio += ,@{ps=$ps; ar=$ps.BeginInvoke(); tarea=$t}
        }
        $res = @()
        # se recogen segun van acabando, no en orden de envio: asi el aviso de
        # avance llega cuando de verdad termina cada NCU
        $pend = New-Object System.Collections.ArrayList
        foreach ($e in $envio) { [void]$pend.Add($e) }
        while ($pend.Count -gt 0) {
            $acabo = $false
            for ($i = $pend.Count - 1; $i -ge 0; $i--) {
                $e = $pend[$i]
                if (-not $e.ar.IsCompleted) { continue }
                $salida = $null
                try { $salida = $e.ps.EndInvoke($e.ar) } catch { $salida = $null }
                $res += ,@{tarea=$e.tarea; salida=@($salida)
                           error=$(if ($e.ps.Streams.Error.Count -gt 0) { "$($e.ps.Streams.Error[0])" } else { '' })}
                $e.ps.Dispose()
                $pend.RemoveAt($i)
                $acabo = $true
                if ($alTerminar) { & $alTerminar $e.tarea }
            }
            if ($pend.Count -gt 0 -and -not $acabo) { Start-Sleep -Milliseconds 120 }
        }
        return $res
    } finally { $pool.Close(); $pool.Dispose() }
}

# El cuerpo que corre cada hilo del diagnostico via NCU: abre el 502 de SU NCU,
# lee el bloque compacto y devuelve las filas. No pinta nada: la ventana solo
# se toca desde el hilo principal.
$DIAG_HILO = {
    param($logica, $RaizTb, $t)
    Invoke-Expression $logica
    $out = @{ncu=$t.ncu; ip=$t.ip; filas=@(); hsus=@(); error=''}
    try {
        Modbus-Conectar $t.ip $t.puerto $t.to
        $dm = Ncu-DiagCompat $t.tcus
        foreach ($u in $t.tcus) { if ($dm[[int]$u]) { $out.filas += ,$dm[[int]$u] } }
        try { $out.hsus = @(Ncu-HsuCompat) } catch {}
    } catch { $out.error = "$_" } finally { Modbus-Cerrar }
    return $out
}

# ---------------------------------------------------------------------------
#  Historial local de la planta
# ---------------------------------------------------------------------------
# Todo lo que hace la herramienta moria al cerrarla. Esto deja en el PC de
# planta un fichero por planta y mes con una linea por valor leido, para poder
# contestar "desde cuando la TCU 34 tiene esto" sin depender de nada online.
# Formato: CSV plano, una linea por (fecha, ncu, tcu, variable, valor).
function Historial-Fichero([string]$planta) {
    $dir = Join-Path $PSScriptRoot 'historial'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    return Join-Path $dir (($planta -replace '[^\w\-\.]', '_') + '_' + (Get-Date -Format 'yyyyMM') + '.csv')
}
function Historial-Anotar([string]$planta, $filas, [string[]]$columnas) {
    if (@($filas).Count -eq 0) { return 0 }
    try {
        $f = Historial-Fichero $planta
        if (-not (Test-Path $f)) { Set-Content -Path $f -Value 'fecha;ncu;tcu;variable;valor' -Encoding UTF8 }
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $lin = New-Object System.Collections.ArrayList
        foreach ($fila in @($filas)) {
            foreach ($c in $columnas) {
                if ($null -eq $fila.PSObject.Properties[$c]) { continue }
                $v = "$($fila.$c)".Trim()
                if ($v -eq '' -or $v -eq '-') { continue }
                [void]$lin.Add(("{0};{1};{2};{3};{4}" -f $ts, "$($fila.NCU)", "$($fila.TCU)", ($c -replace ';', ','), ($v -replace ';', ',')))
            }
        }
        if ($lin.Count -eq 0) { return 0 }
        Add-Content -Path $f -Value $lin -Encoding UTF8
        return $lin.Count
    } catch { return 0 }
}
# Cronologia de una variable en una TCU: solo los CAMBIOS, que es lo que se
# pregunta. Pura: se prueba sin ficheros.
function Historial-Cambios($lineas, [string]$ncu, [string]$tcu, [string]$variable) {
    $r = New-Object System.Collections.ArrayList
    $ultimo = $null
    foreach ($l in @($lineas)) {
        $c = "$l".Split(';')
        if ($c.Count -lt 5) { continue }
        if ($c[0] -eq 'fecha') { continue }
        if ($ncu -ne '' -and $c[1] -ne $ncu) { continue }
        if ($tcu -ne '' -and $c[2] -ne $tcu) { continue }
        if ($variable -ne '' -and -not (Buscar-Casa $c[3] $variable)) { continue }
        $k = $c[1] + '|' + $c[2] + '|' + $c[3]
        if ($null -eq $ultimo) { $ultimo = @{} }
        if ($ultimo.ContainsKey($k) -and $ultimo[$k] -eq $c[4]) { continue }
        [void]$r.Add([pscustomobject]@{Fecha=$c[0]; NCU=$c[1]; TCU=$c[2]; Variable=$c[3]; Valor=$c[4]
                                       Antes=$(if ($ultimo.ContainsKey($k)) { $ultimo[$k] } else { '' })})
        $ultimo[$k] = $c[4]
    }
    return $r.ToArray()
}

# Que haria una escritura ANTES de hacerla, cruzando con la ultima lectura de
# esas mismas variables. Devuelve el reparto por variable: cuantas cambian, en
# cuantas ya esta el valor, y que valores distintos hay ahora mismo. Es lo que
# saca a la luz que media planta tiene otra configuracion antes de escribirla
# entera. Pura: se prueba sin planta ni ventana.
# $vars: lista con .nombre y .texto (lo que se va a escribir).
# $lectura: filas de la ultima lectura masiva (NCU, TCU, una columna por variable).
function Simular-Escritura($vars, $lectura, $tcusDestino) {
    $filas = @($lectura)
    $r = New-Object System.Collections.ArrayList
    foreach ($v in @($vars)) {
        $nom = "$($v.nombre)"
        $nuevo = "$($v.texto)".Trim()
        $cuenta = @{}; $sinDato = 0; $vistas = 0
        foreach ($f in $filas) {
            if ($null -eq $f.PSObject.Properties[$nom]) { continue }
            # si se ha pasado una lista de TCUs destino, solo cuentan esas
            if ($null -ne $tcusDestino -and @($tcusDestino).Count -gt 0) {
                if (@($tcusDestino) -notcontains [int]$f.TCU) { continue }
            }
            $vistas++
            $actual = "$($f.$nom)".Trim()
            if ($actual -eq '' -or $actual -eq '-') { $sinDato++; continue }
            $cuenta[$actual] = 1 + [int]$cuenta[$actual]
        }
        if ($vistas -eq 0) { [void]$r.Add([pscustomobject]@{Variable=$nom; Nuevo=$nuevo; Cambian=-1; Iguales=0; SinDato=0; Reparto=''}); continue }
        $iguales = [int]$cuenta[$nuevo]
        $cambian = 0
        $partes = @()
        foreach ($k in @($cuenta.Keys | Sort-Object { - [int]$cuenta[$_] }, { "$_" })) {
            if ($k -ne $nuevo) { $cambian += [int]$cuenta[$k] }
            $partes += "$k en $($cuenta[$k])"
        }
        [void]$r.Add([pscustomobject]@{Variable=$nom; Nuevo=$nuevo; Cambian=$cambian; Iguales=$iguales
                                       SinDato=$sinDato; Reparto=($partes -join ' | ')})
    }
    return $r.ToArray()
}

# Parte de averias en texto plano, para pegarlo en WhatsApp. Nada de tablas:
# en el movil se descuadran. Agrupa por NCU y solo saca lo que NO esta OK.
# $ncuFiltro vacio = toda la planta. Pura: se prueba sin planta ni ventana.
function Texto-NoOk($filas, [string]$planta, [string]$fecha, [string]$ncuFiltro) {
    $todas = @($filas)
    $malas = @($todas | Where-Object { $s = "$($_.Salud)".ToUpper(); $s -ne '' -and $s -ne 'OK' })
    if ($ncuFiltro -ne '') {
        $todas = @($todas | Where-Object { "$($_.NCU)" -eq $ncuFiltro })
        $malas = @($malas | Where-Object { "$($_.NCU)" -eq $ncuFiltro })
    }
    $cab = "$planta"
    if ($ncuFiltro -ne '') { $cab += " - NCU $ncuFiltro" }
    if ($fecha) { $cab += " - $fecha" }
    $lin = New-Object System.Collections.ArrayList
    [void]$lin.Add($cab)
    if ($malas.Count -eq 0) {
        [void]$lin.Add("Todo OK: $($todas.Count) equipos revisados, ninguna incidencia.")
        return ($lin -join "`r`n")
    }
    [void]$lin.Add("NO OK: $($malas.Count) de $($todas.Count) equipos revisados.")
    $ncus = @(@($malas | ForEach-Object { "$($_.NCU)" }) | Sort-Object -Unique | Sort-Object { [int]("0" + $_) })
    foreach ($n in $ncus) {
        $delGrupo = @($malas | Where-Object { "$($_.NCU)" -eq $n })
        [void]$lin.Add('')
        [void]$lin.Add("*$(if ($n -ne '') { "NCU $n" } else { 'Sin NCU' })* ($($delGrupo.Count))")
        foreach ($t in @($delGrupo | Sort-Object { [int]("0" + ("$($_.TCU)" -replace '\D', '')) })) {
            $eti = $(if ("$($t.TCU)" -eq 'NCU') { 'La NCU' } elseif ("$($t.TCU)" -like 'HSU*') { "$($t.TCU)" } else { "TCU $($t.TCU)" })
            $nota = "$($t.Alarmas)".Trim()
            [void]$lin.Add("- $eti" + ": $("$($t.Salud)".ToUpper())" + $(if ($nota) { " - $nota" } else { '' }))
        }
    }
    return ($lin -join "`r`n")
}

# Veredicto de un pulso de motor a cada lado. La clave es la CORRIENTE: si no
# hay movimiento pero tampoco corriente, el controlador ni siquiera activo el
# motor, y eso pasa cuando el seguidor esta pegado a su limite de recorrido; no
# es una averia. Si hay corriente y no se mueve, ahi si hay algo atascado.
# Devuelve @{estado; detalle; limite}. Pura: se prueba sin planta.
function Motor-Veredicto([double]$dW, [int]$iW, [double]$dE, [int]$iE, [double]$umbral, [double]$tilt0) {
    $CERO_MA = 30
    $det = ("desde {0:0.0} deg: dW {1:+0.0;-0.0} deg (I {2} mA), dE {3:+0.0;-0.0} deg (I {4} mA)" -f $tilt0, $dW, $iW, $dE, $iE)
    # el umbral es inclusivo: la inclinacion se lee en decimas, asi que un
    # movimiento de exactamente el umbral es un caso real y no puede caer en
    # tierra de nadie entre "se movio" y "esta quieto"
    $okW = $dW -ge $umbral                       # al oeste sube el angulo
    $okE = $dE -le -$umbral                      # al este baja
    $quietoW = [math]::Abs($dW) -lt $umbral
    $quietoE = [math]::Abs($dE) -lt $umbral
    $declinaW = $quietoW -and $iW -lt $CERO_MA   # el controlador no engancho el motor
    $declinaE = $quietoE -and $iE -lt $CERO_MA
    if ($okW -and $okE) { return @{estado='PASA'; detalle=$det; limite=$false} }
    if ($dW -le -$umbral -and $dE -ge $umbral) {
        return @{estado='FALLA'; detalle="sentido INVERTIDO (revisar polaridad / bit 11 de 41018) - $det"; limite=$false}
    }
    if ($quietoW -and $quietoE) {
        $causa = $(if ($declinaW -and $declinaE) { 'sin corriente de motor: el controlador no lo activa en ningun sentido' } else { 'no se mueve aunque hay corriente' })
        return @{estado='FALLA'; detalle="$causa - $det"; limite=$false}
    }
    # uno de los dos se movio bien y el otro no
    if ($okW -and $declinaE) {
        return @{estado='PASA'; detalle="solo al oeste: al este el controlador no activo el motor (0 mA), normal si esta en su limite - $det"; limite=$true}
    }
    if ($okE -and $declinaW) {
        return @{estado='PASA'; detalle="solo al este: al oeste el controlador no activo el motor (0 mA), normal si esta en su limite - $det"; limite=$true}
    }
    if ($okW -and $quietoE) { return @{estado='FALLA'; detalle="no se mueve al este con corriente ($iE mA): revisar mecanica - $det"; limite=$false} }
    if ($okE -and $quietoW) { return @{estado='FALLA'; detalle="no se mueve al oeste con corriente ($iW mA): revisar mecanica - $det"; limite=$false} }
    return @{estado='DUDOSO'; detalle="movimiento asimetrico - $det"; limite=$false}
}

# ------------------------- IDENTIFICACION (bloque 30300+) -------------------------
function Ident-Leer([byte]$tcu) {
    $w = FC03-Leer $tcu (Dir-Trama 30300) 30
    $campos = New-Object System.Collections.ArrayList
    $prod = $w[0]
    [void]$campos.Add([pscustomobject]@{Campo='Product ID (30300)';        Valor=("0x{0:X4}  (tipo {1}, HW {2}, FW corto {3})" -f $prod, ($prod -band 0xF), (($prod -shr 4) -band 0xF), (($prod -shr 8) -band 0xFF))})
    [void]$campos.Add([pscustomobject]@{Campo='FW principal';              Valor=("v{0}.{1}.{2} (map {3})" -f (($w[1] -shr 8) -band 0xFF), ($w[1] -band 0xFF), (($w[2] -shr 8) -band 0xFF), ($w[2] -band 0xFF))})
    [void]$campos.Add([pscustomobject]@{Campo='FW de fabrica';             Valor=("v{0}.{1}.{2} (map {3})" -f (($w[23] -shr 8) -band 0xFF), ($w[23] -band 0xFF), (($w[24] -shr 8) -band 0xFF), ($w[24] -band 0xFF))})
    [void]$campos.Add([pscustomobject]@{Campo='FW MCU secundario';         Valor="$($w[3])"})
    [void]$campos.Add([pscustomobject]@{Campo='FW BQ';                     Valor="$($w[4])"})
    [void]$campos.Add([pscustomobject]@{Campo='Golden image BQ';           Valor="$($w[5])"})
    [void]$campos.Add([pscustomobject]@{Campo='HW PCBA';                   Valor="$($w[6])"})
    [void]$campos.Add([pscustomobject]@{Campo='Bootloader power PIC';      Valor="$($w[7])"})
    [void]$campos.Add([pscustomobject]@{Campo='Xbee HW / FW';              Valor=("0x{0:X4} / 0x{1:X4}" -f $w[8], $w[9])})
    $macLo = ([long]$w[11] -shl 16) -bor [long]$w[10]
    $macHi = ([long]$w[13] -shl 16) -bor [long]$w[12]
    [void]$campos.Add([pscustomobject]@{Campo='MAC Xbee';                  Valor=("{0:X8}{1:X8}" -f $macHi, $macLo)})
    $serie = ''
    for ($i = 22; $i -ge 14; $i--) {
        foreach ($c in @((($w[$i] -shr 8) -band 0xFF), ($w[$i] -band 0xFF))) {
            if ($c -ge 32 -and $c -le 126) { $serie += [char]$c }
        }
    }
    [void]$campos.Add([pscustomobject]@{Campo='Numero de serie';           Valor=$serie})
    # dd/mm/aaaa: el registro trae el ano en dos cifras y antes se pintaba
    # aa-mm-dd, que se lee como fecha americana
    $fabA = [int]$w[26]; if ($fabA -lt 100) { $fabA += 2000 }
    $fabM = ($w[25] -shr 8) -band 0xFF; $fabD = $w[25] -band 0xFF
    $fabTxt = ''
    if ($fabD -gt 0 -or $fabM -gt 0) { $fabTxt = "{0:00}/{1:00}/{2}" -f $fabD, $fabM, $fabA }
    [void]$campos.Add([pscustomobject]@{Campo='Fecha de fabricacion';      Valor=$fabTxt})
    [void]$campos.Add([pscustomobject]@{Campo='Lote / verificador';        Valor="$($w[27]) / $($w[28])"})
    [void]$campos.Add([pscustomobject]@{Campo='Revision HW';               Valor="$($w[29])"})
    return $campos
}

$btnIdent.Add_Click({ Lanzar {
    $tcu = Val-Int $txtITcu.Text 'TCU' 1 247
    $cx = Params-Conexion
    $lvI.Items.Clear(); $script:UltimaIdent = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    $segs = @(Plan-Segmentos @($tcu) $cx)
    if ($segs.Count -eq 0 -or $segs[0].tcus.Count -eq 0) { Con "TCU $tcu fuera de los gateways de la NCU" ([System.Drawing.Color]::Salmon); return }
    $puertoTcu = $segs[0].puerto
    Con "Identificando TCU $tcu  ($($cx.ip):$puertoTcu)" ([System.Drawing.Color]::SteelBlue)
    try { Modbus-Conectar $cx.ip $puertoTcu $cx.to } catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon); return }
    $campos = $null; $err = ''
    for ($i = 1; $i -le $cx.reint -and $null -eq $campos; $i++) {
        try { $campos = Ident-Leer $tcu }
        catch {
            $err = "$_"
            if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
            Start-Sleep -Milliseconds (300 * $i)
        }
    }
    Modbus-Cerrar
    if ($null -eq $campos) { Con "TCU $tcu sin respuesta: $err" ([System.Drawing.Color]::Salmon); return }
    foreach ($c in $campos) {
        $item = New-Object System.Windows.Forms.ListViewItem($c.Campo)
        [void]$item.SubItems.Add($c.Valor)
        $lvI.Items.Add($item) | Out-Null
        Con ("  {0,-28} {1}" -f $c.Campo, $c.Valor) ([System.Drawing.Color]::Gainsboro)
    }
    $script:UltimaIdent = @($campos | ForEach-Object { [pscustomobject]@{TCU=$tcu; Campo=$_.Campo; Valor=$_.Valor} })
} })

$btnICsv.Add_Click({
    [void](Exportar-Csv $script:UltimaIdent ('identidad_tcu' + $txtITcu.Text))
})

# ------------------------- logica VOLCAR TCU -------------------------
$btnVolcar.Add_Click({ Lanzar {
    $tcu = Val-Int $txtDTcu.Text 'TCU' 1 247
    $cx = Params-Conexion
    $lvD.Items.Clear(); $script:UltimoVolcado = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    $segs = @(Plan-Segmentos @($tcu) $cx)
    if ($segs.Count -eq 0 -or $segs[0].tcus.Count -eq 0) { Con "TCU $tcu fuera de los gateways de la NCU" ([System.Drawing.Color]::Salmon); return }
    $puertoTcu = $segs[0].puerto
    Con "Volcando TCU $tcu  ($($cx.ip):$puertoTcu)" ([System.Drawing.Color]::SteelBlue)
    try { Modbus-Conectar $cx.ip $puertoTcu $cx.to } catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon); return }
    $mapas = @(@{m=$VARIABLES; nota='config'})
    if ($chkDEstado.Checked) { $mapas += @{m=$ESTADO; nota='estado'} }
    $okc = 0; $koc = 0
    foreach ($mm in $mapas) {
        if ($script:Cancelar) { break }
        foreach ($nombre in $mm.m.Keys) {
            if (Chequear-Cancelado) { break }
            $vdef = $mm.m[$nombre]
            $val = $null; $err = ''
            for ($i = 1; $i -le $cx.reint -and $null -eq $val; $i++) {
                if ($script:Cancelar) { break }
                try { $val = Leer-Decodificado $tcu $vdef }
                catch {
                    $err = "$_"
                    if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                    Start-Sleep -Milliseconds 200
                }
            }
            $item = New-Object System.Windows.Forms.ListViewItem($nombre)
            if ($null -ne $val) {
                [void]$item.SubItems.Add($val); [void]$item.SubItems.Add($mm.nota)
                $okc++
                $script:UltimoVolcado += [pscustomobject]@{Variable=$nombre; Valor=$val; Grupo=$mm.nota}
            } else {
                [void]$item.SubItems.Add('-'); [void]$item.SubItems.Add($err)
                $item.ForeColor = [System.Drawing.Color]::Firebrick
                $koc++
                $script:UltimoVolcado += [pscustomobject]@{Variable=$nombre; Valor=''; Grupo=$err}
            }
            $lvD.Items.Add($item) | Out-Null
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    if ($chkDIdent.Checked -and -not $script:Cancelar) {
        try {
            $campos = Ident-Leer $tcu
            foreach ($c in $campos) {
                $item = New-Object System.Windows.Forms.ListViewItem($c.Campo)
                [void]$item.SubItems.Add($c.Valor); [void]$item.SubItems.Add('identidad')
                $lvD.Items.Add($item) | Out-Null
                $okc++
                $script:UltimoVolcado += [pscustomobject]@{Variable=$c.Campo; Valor=$c.Valor; Grupo='identidad'}
            }
        } catch { Con "AVISO: identidad no legible: $_" ([System.Drawing.Color]::Orange) }
    }
    Modbus-Cerrar
    $completo = (-not $script:Cancelar) -and ($koc -eq 0)
    $script:MetaVolcado = @{
        planta = Nombre-Planta; ip = $cx.ip; puerto = $puertoTcu; tcu = $tcu
        fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        completo = $completo; errores = $koc; cancelado = [bool]$script:Cancelar
    }
    if ($completo) {
        Con "Volcado terminado: $okc leidas, $koc con error" ([System.Drawing.Color]::SteelBlue)
    } else {
        Con "Volcado INCOMPLETO: $okc leidas, $koc con error$(if ($script:Cancelar) { ', cancelado' }). Un backup exportado quedara marcado como incompleto." ([System.Drawing.Color]::Orange)
    }
} })

$btnDCsv.Add_Click({
    [void](Exportar-Csv $script:UltimoVolcado ('volcado_tcu' + $txtDTcu.Text))
})

$btnBackupJson.Add_Click({
    if (-not $script:MetaVolcado) { return }
    if (-not $script:MetaVolcado.completo) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "El volcado esta INCOMPLETO ($($script:MetaVolcado.errores) variables sin leer$(if ($script:MetaVolcado.cancelado) { ', cancelado' })).`r`n" +
            "Un backup incompleto NO sirve para restaurar una TCU entera (las variables no leidas quedarian sin configurar).`r`n`r`n" +
            "Guardar de todos modos, marcado como incompleto?",
            'Backup incompleto', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Backup TCU (*.json)|*.json'
    $sufijo = ''
    if (-not $script:MetaVolcado.completo) { $sufijo = '_INCOMPLETO' }
    $dlg.FileName = 'backup_tcu' + $script:MetaVolcado.tcu + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + $sufijo + '.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $obj = [ordered]@{
        tipo     = 'backup_tcu'
        mapa     = $VERSION_MAPA
        toolbox  = $VERSION_TOOLBOX
        planta   = $script:MetaVolcado.planta
        ip       = $script:MetaVolcado.ip
        puerto   = $script:MetaVolcado.puerto
        tcu      = $script:MetaVolcado.tcu
        fecha    = $script:MetaVolcado.fecha
        completo = [bool]$script:MetaVolcado.completo
        errores  = $script:MetaVolcado.errores
        variables = @($script:UltimoVolcado | ForEach-Object { [ordered]@{variable=$_.Variable; valor=$_.Valor; grupo=$_.Grupo} })
    }
    ConvertTo-Json $obj -Depth 5 | Set-Content $dlg.FileName -Encoding UTF8
    Con "Backup JSON guardado: $($dlg.FileName)$(if (-not $script:MetaVolcado.completo) { '  (INCOMPLETO)' })" ([System.Drawing.Color]::SteelBlue)
})

$btnComparar.Add_Click({
    if ($script:UltimoVolcado.Count -eq 0) { return }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Backup TCU (*.json)|*.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    try { $obj = Get-Content $dlg.FileName -Raw | ConvertFrom-Json }
    catch { [void][System.Windows.Forms.MessageBox]::Show("No se pudo leer el backup: $_",'Error'); return }
    if ($obj.tipo -ne 'backup_tcu' -or -not $obj.variables) {
        [void][System.Windows.Forms.MessageBox]::Show('El fichero no es un backup de TCU.','Error'); return
    }
    $ref = @{}
    foreach ($v in $obj.variables) { $ref[[string]$v.variable] = "$($v.valor)" }
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Comparando volcado actual (TCU $($script:MetaVolcado.tcu)) con backup de TCU $($obj.tcu) del $($obj.fecha)" ([System.Drawing.Color]::SteelBlue)
    $dif = 0; $soloAqui = 0
    foreach ($item in $lvD.Items) {
        $nombre = $item.Text
        $valor = $item.SubItems[1].Text
        if (-not $ref.ContainsKey($nombre)) { $soloAqui++; continue }
        if ($ref[$nombre] -ne $valor) {
            $dif++
            $item.ForeColor = [System.Drawing.Color]::DarkOrange
            $item.SubItems[2].Text = "backup: $($ref[$nombre])"
            Con ("  DIF {0,-40} actual={1}   backup={2}" -f $nombre, $valor, $ref[$nombre]) ([System.Drawing.Color]::Orange)
        }
    }
    if ($dif -eq 0) { Con "Sin diferencias con el backup ($($lvD.Items.Count) variables comparadas)" ([System.Drawing.Color]::LightGreen) }
    else            { Con "$dif diferencias encontradas (marcadas en naranja, con el valor del backup en Nota)" ([System.Drawing.Color]::Orange) }
})

# ------------------------- logica DIAGNOSTICO -------------------------
function Diag-LeerTcu([byte]$tcu) {
    $r1 = FC03-Leer $tcu (Dir-Trama 30001) 6    # main, al1..al4, status
    # 30091..30098 de un tiron: bus, panel (V e I), bateria (V e I), SoC/SoH y
    # las dos temperaturas. El panel y su corriente estan en el mapa de la TCU
    # (30092/30093), asi que el modo directo tampoco tiene por que ir sin ellos.
    $r2 = FC03-Leer $tcu (Dir-Trama 30091) 8
    $r3 = FC03-Leer $tcu (Dir-Trama 30111) 2    # tilt, target

    $al1 = $r1[1]; $al2 = $r1[2]; $al3 = $r1[3]; $al4 = $r1[4]; $st = $r1[5]
    $ibat = $r2[4]; if ($ibat -gt 32767) { $ibat -= 65536 }
    $tbat = $r2[6]; if ($tbat -gt 32767) { $tbat -= 65536 }
    $tpcb = $r2[7]; if ($tpcb -gt 32767) { $tpcb -= 65536 }
    $tilt = $r3[0]; if ($tilt -gt 32767) { $tilt -= 65536 }
    $targ = $r3[1]; if ($targ -gt 32767) { $targ -= 65536 }
    $dif = [math]::Abs($tilt - $targ) / 10.0

    $alarmas = @()
    $alarmas += Bits-Texto $al1 $BITS_AL1
    $alarmas += Bits-Texto $al2 $BITS_AL2
    $alarmas += Bits-Texto $al3 $BITS_AL3
    $alarmas += Bits-Texto $al4 $BITS_AL4

    $esAlarma = (($al1 -band $CRIT_AL1) -ne 0) -or (($al2 -band $CRIT_AL2) -ne 0) -or ($al3 -ne 0) -or (($al4 -band 0x100) -ne 0)
    $hayAviso = ($alarmas.Count -gt 0) -or ((($st -shr 15) -band 1) -eq 0) -or ($dif -gt 5) -or ((($st -shr 11) -band 1) -eq 1)

    $salud = 'OK'
    if ($esAlarma) { $salud = 'ALARMA' }
    elseif ($hayAviso) { $salud = 'AVISO' }

    $notas = @()
    if ($dif -gt 5) { $notas += ("dif {0:0.0} deg" -f $dif) }
    if ((($st -shr 15) -band 1) -eq 0) { $notas += 'system OK = 0' }
    if ((($st -shr 11) -band 1) -eq 1) { $notas += 'alarma motor enclavada' }

    $modo = @('OFF','MANUAL','AUTO','?')[(($r1[0] -shr 8) -band 0x3)]

    return [pscustomobject]@{
        TCU = [int]$tcu; Salud = $salud; Modo = $modo
        Tilt = [math]::Round($tilt/10.0, 1); Objetivo = [math]::Round($targ/10.0, 1); Dif = [math]::Round($dif, 1)
        SoC = ($r2[5] -band 0xFF); SoH = (($r2[5] -shr 8) -band 0xFF)
        Vbat_mV = $r2[3]; Ibat_mA = $ibat
        # panel y su corriente salen del mapa de la TCU (30092/30093). Las de
        # motor no estan ahi como tales: esas si se quedan vacias.
        Vpanel_mV = $r2[1]; Ientrada_mA = $r2[2]; Imotor_mA = ''; ImotorPico_mA = ''
        Dia = (($r1[0] -shr 7) -band 1)
        Tbat_C = [math]::Round($tbat/10.0, 1); Tpcb_C = [math]::Round($tpcb/10.0, 1)
        Alarmas = (($alarmas + $notas) -join '; ')
        main_status = ("0x{0:X4}" -f $r1[0]); alarmas_1 = ("0x{0:X4}" -f $al1); alarmas_2 = ("0x{0:X4}" -f $al2)
        alarmas_3 = ("0x{0:X4}" -f $al3); alarmas_4 = ("0x{0:X4}" -f $al4); system_status = ("0x{0:X4}" -f $st)
    }
}

# Un pase completo de diagnostico (usado por DIAGNOSTICAR y por el registrador)
function Diag-Correr {
    $cx = Params-Conexion
    $lvG.Items.Clear(); $script:UltimoDiag = @(); $lblGResumen.Text = ''
    $script:UltimaCarga = @{}   # lo leido de carga era de la lectura anterior
    # trabajos: una entrada por NCU (planta completa) o una sola (modo normal)
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    $trabajos = @(Trabajos-Planta $cx $null $(if ($cx.multi) { $txtGNcus.Text } else { '' }) (Parse-Seleccion $txtGTcus.Text 'Diagnostico') $txtGw.Text)
    if ($trabajos.Count -eq 0) { Con 'La seleccion no deja ninguna TCU (mira los cuadros NCUs, TCUs y GW).' ([System.Drawing.Color]::Orange); return }
    if ($cx.multi) {
        $totTcus = 0; foreach ($tr in $trabajos) { $totTcus += @($tr.tcus).Count }
        Con "Diagnostico de PLANTA: $($trabajos.Count) NCUs, $totTcus TCUs" ([System.Drawing.Color]::SteelBlue)
    } else {
        Con "Diagnostico de $(Eti-Rango @($trabajos).tcus)  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    }
    $nOk = 0; $nAviso = 0; $nAlarma = 0; $nOff = 0
    $nHOk = 0; $nHMal = 0        # las HSUs van aparte de la cuenta de TCUs
    $nDiagTot = 0; foreach ($tr in $trabajos) { $nDiagTot += @($tr.tcus).Count }
    Prog-Iniciar $nDiagTot
    # Planta completa por el bloque compacto: cada NCU es una conexion propia y
    # no compiten, asi que van a la vez. Es la diferencia entre una hora y unos
    # minutos. Si algo va mal, se desmarca 'en paralelo' y vuelve al modo serie.
    $paraleloOk = $false
    if ($chkGPar.Checked -and $chkGNcu.Checked -and @($trabajos).Count -gt 1) {
        Con "Barrido en paralelo: $(@($trabajos).Count) NCUs a la vez (desmarca 'en paralelo' si prefieres una detras de otra)." ([System.Drawing.Color]::SteelBlue)
        $tareas = @($trabajos | ForEach-Object { @{ncu=$_.ncu; ip=$_.ip; puerto=$PUERTO_NCU; to=$_.cx.to; tcus=@($_.tcus); gws=$_.cx.gws} })
        $res = $null
        $avance = { param($t) Prog-Paso @($t.tcus).Count; [System.Windows.Forms.Application]::DoEvents() }
        try { $res = @(Paralelo-Ejecutar $tareas $DIAG_HILO 8 '' $avance) } catch { Con "El barrido en paralelo no ha podido arrancar ($_): se hace en serie." ([System.Drawing.Color]::Orange) }
        if ($null -ne $res) {
            $paraleloOk = $true
            foreach ($r in ($res | Sort-Object { [int]("0" + "$($_.tarea.ncu)") })) {
                $o = @($r.salida)[0]
                $eti = "$($r.tarea.ncu)"
                if ($null -eq $o -or "$($o.error)" -ne '') {
                    $msg = $(if ($o) { "$($o.error)" } else { "$($r.error)" })
                    Con "NCU$eti ($($r.tarea.ip)): $msg - no se sabe nada de sus $(@($r.tarea.tcus).Count) TCUs" ([System.Drawing.Color]::Salmon)
                    continue
                }
                foreach ($dh in @($o.hsus)) {
                    $dh.NCU = $eti
                    $itemH = New-Object System.Windows.Forms.ListViewItem($eti)
                    foreach ($c in @($dh.TCU, '', $dh.Salud, $dh.Modo, $dh.Tilt, $dh.Objetivo, $dh.Dif, $dh.SoC, $dh.Edad_s, $dh.Alarmas)) { [void]$itemH.SubItems.Add("$c") }
                    if ("$($dh.Salud)" -eq 'OK') { $itemH.ForeColor = [System.Drawing.Color]::DarkGreen; $nHOk++ }
                    else { $itemH.ForeColor = [System.Drawing.Color]::DarkOrange; $nHMal++ }
                    $lvG.Items.Add($itemH) | Out-Null
                    $script:UltimoDiag += $dh
                }
                foreach ($d in @($o.filas)) {
                    $d | Add-Member -NotePropertyName NCU -NotePropertyValue $eti -Force
                    $d | Add-Member -NotePropertyName GW -NotePropertyValue (Gw-DeTcu $r.tarea.gws ([int]"$($d.TCU)")) -Force
                    $item = New-Object System.Windows.Forms.ListViewItem($eti)
                    foreach ($c in @($d.TCU, $d.GW, $d.Salud, $d.Modo, $d.Tilt, $d.Objetivo, $d.Dif, $d.SoC, $d.Edad_s, $d.Alarmas)) { [void]$item.SubItems.Add("$c") }
                    switch ("$($d.Salud)") {
                        'OK'      { $item.ForeColor = [System.Drawing.Color]::DarkGreen;  $nOk++ }
                        'AVISO'   { $item.ForeColor = [System.Drawing.Color]::DarkOrange; $nAviso++ }
                        'ALARMA'  { $item.ForeColor = [System.Drawing.Color]::Firebrick;  $nAlarma++ }
                        'OFFLINE' { $item.ForeColor = [System.Drawing.Color]::Gray;       $nOff++ }
                    }
                    $lvG.Items.Add($item) | Out-Null
                    $script:UltimoDiag += $d
                    if ("$($d.TCU)" -match '^\d+$') { Cierre-MarcarSiEsta $eti ([int]$d.TCU) 'modo' $(if ("$($d.Modo)" -eq 'AUTO') { 'OK' } else { "$($d.Modo)" }) }
                    if ("$($d.Salud)" -ne 'OK') { Con ("NCU{0} TCU {1,3}  {2,-8} {3}" -f $eti, $d.TCU, $d.Salud, $d.Alarmas) ([System.Drawing.Color]::Orange) }
                }
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
    }
    if (-not $paraleloOk) {
    foreach ($tr in $trabajos) {
        $script:NcuLog = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
    if ($script:Cancelar) { break }
    if ($null -ne $tr.ncu) {
        Con ("--- NCU{0}  ({1})  TCUs {2}-{3} ---" -f $tr.ncu, $tr.ip, $tr.tcus[0], $tr.tcus[-1]) ([System.Drawing.Color]::SteelBlue)
        # salud de la propia NCU (puerto 502, unit 1): GW1/GW2, UPS, seta, reloj
        $ns = $null; $nsErr = ''
        try {
            Modbus-Conectar $tr.ip $PUERTO_NCU $tr.cx.to
            $ns = Ncu-Salud
            Modbus-Cerrar
        } catch { $nsErr = "$_"; Modbus-Cerrar }
        $dn = [pscustomobject]@{
            NCU="$($tr.ncu)"; TCU='NCU'; GW=''; Salud=$(if ($ns) { $ns.salud } else { 'AVISO' }); Modo='-'
            Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''; Vbat_mV=''; Ibat_mA=''; Vpanel_mV=''; Ientrada_mA=''; Imotor_mA=''; ImotorPico_mA=''; Dia=''; Tbat_C=''; Tpcb_C=''
            # El reloj salia SIEMPRE en la columna de alarmas y parecia un
            # problema. Solo se menciona si de verdad esta desviado.
            Alarmas=$(if ($ns) { ((@($ns.alarmas) + $(Reloj-Nota $ns)) -join '; ') } else { "NCU sin respuesta en ${PUERTO_NCU}: $nsErr" })
            main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''
        }
        $itemN = New-Object System.Windows.Forms.ListViewItem("$($tr.ncu)")
        foreach ($c in @($dn.TCU, $dn.Salud, $dn.Modo, $dn.Tilt, $dn.Objetivo, $dn.Dif, $dn.SoC, '', $dn.Alarmas)) { [void]$itemN.SubItems.Add("$c") }
        switch ($dn.Salud) {
            'OK'     { $itemN.ForeColor = [System.Drawing.Color]::DarkGreen }
            'AVISO'  { $itemN.ForeColor = [System.Drawing.Color]::DarkOrange }
            'ALARMA' { $itemN.ForeColor = [System.Drawing.Color]::Firebrick }
        }
        $lvG.Items.Add($itemN) | Out-Null
        $script:UltimoDiag += $dn
        if ($dn.Salud -ne 'OK') { Con ("NCU{0}  {1,-8} {2}" -f $tr.ncu, $dn.Salud, $dn.Alarmas) ([System.Drawing.Color]::Orange) }
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($chkGNcu.Checked) {
        # modo rapido: bloque compacto que la NCU cachea de sus TCUs (30500+,
        # puerto 502) - lecturas TCP locales, sin rondas Zigbee por TCU
        $dm = $null; $hsus = @()
        try {
            Modbus-Conectar $tr.ip $PUERTO_NCU $tr.cx.to
            $dm = Ncu-DiagCompat $tr.tcus
            try { $hsus = @(Ncu-HsuCompat) } catch { Con "AVISO: bloque HSU no legible: $_" ([System.Drawing.Color]::Orange) }
        } catch { Con "ERROR via NCU ($($tr.ip):$PUERTO_NCU): $_  - desmarca 'via NCU' para el modo directo Zigbee" ([System.Drawing.Color]::Salmon) }
        Modbus-Cerrar
        foreach ($dh in $hsus) {
            $dh.NCU = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
            $itemH = New-Object System.Windows.Forms.ListViewItem($dh.NCU)
            foreach ($c in @($dh.TCU, '', $dh.Salud, $dh.Modo, $dh.Tilt, $dh.Objetivo, $dh.Dif, $dh.SoC, $dh.Edad_s, $dh.Alarmas)) { [void]$itemH.SubItems.Add("$c") }
            switch ($dh.Salud) {
                # Las HSUs se cuentan aparte: pedir una TCU y ver "OK: 1 Aviso: 1"
                # porque la meteo de esa NCU va en la misma tabla despista.
                'OK'      { $itemH.ForeColor = [System.Drawing.Color]::DarkGreen;  $nHOk++ }
                'AVISO'   { $itemH.ForeColor = [System.Drawing.Color]::DarkOrange; $nHMal++ }
                'ALARMA'  { $itemH.ForeColor = [System.Drawing.Color]::Firebrick;  $nHMal++ }
                'OFFLINE' { $itemH.ForeColor = [System.Drawing.Color]::Gray;       $nHMal++ }
            }
            $lvG.Items.Add($itemH) | Out-Null
            $script:UltimoDiag += $dh
            if ($dh.Salud -ne 'OK') { Con ("{0}{1}  {2,-8} {3}" -f $(if ($dh.NCU) { "NCU$($dh.NCU) " } else { '' }), $dh.TCU, $dh.Salud, $dh.Alarmas) ([System.Drawing.Color]::Orange) }
        }
        # Si la NCU no contesta en 502 no sabemos NADA de sus TCUs: pintarlas
        # todas como OFFLINE es mentira y llena la tabla de ruido. Se dice una
        # vez y se pasa a la siguiente NCU.
        if ($null -eq $dm) {
            $eti = $(if ($null -ne $tr.ncu) { "NCU$($tr.ncu)" } else { $tr.ip })
            Con "$eti : no se ha podido leer el bloque compacto en ${PUERTO_NCU}, asi que no se sabe nada de sus $(@($tr.tcus).Count) TCUs. Desmarca 'via NCU' para preguntarles una a una por el gateway." ([System.Drawing.Color]::Salmon)
            continue
        }
        foreach ($tcu in $tr.tcus) {
            if (Chequear-Cancelado) { break }
            $d = $null
            if ($dm) { $d = $dm[[int]$tcu] }
            if ($null -eq $d) {
                $d = [pscustomobject]@{
                    TCU=[int]$tcu; GW=''; Salud='OFFLINE'; Modo=''; Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''
                    Vbat_mV=''; Ibat_mA=''; Vpanel_mV=''; Ientrada_mA=''; Imotor_mA=''; ImotorPico_mA=''; Dia=''; Tbat_C=''; Tpcb_C=''; Alarmas='sin datos via NCU'
                    main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''
                }
            }
            $etiquetaNcu = ''
            if ($null -ne $tr.ncu) { $etiquetaNcu = "$($tr.ncu)" }
            $d | Add-Member -NotePropertyName NCU -NotePropertyValue $etiquetaNcu -Force
            $d | Add-Member -NotePropertyName GW -NotePropertyValue (Gw-DeTcu $tr.cx.gws ([int]"$($d.TCU)")) -Force
        $d | Add-Member -NotePropertyName GW -NotePropertyValue (Gw-DeTcu $tr.cx.gws ([int]"$($d.TCU)")) -Force
            $item = New-Object System.Windows.Forms.ListViewItem($etiquetaNcu)
            foreach ($c in @($d.TCU, $d.GW, $d.Salud, $d.Modo, $d.Tilt, $d.Objetivo, $d.Dif, $d.SoC, $d.Edad_s, $d.Alarmas)) { [void]$item.SubItems.Add("$c") }
            switch ($d.Salud) {
                'OK'      { $item.ForeColor = [System.Drawing.Color]::DarkGreen;  $nOk++ }
                'AVISO'   { $item.ForeColor = [System.Drawing.Color]::DarkOrange; $nAviso++ }
                'ALARMA'  { $item.ForeColor = [System.Drawing.Color]::Firebrick;  $nAlarma++ }
                'OFFLINE' { $item.ForeColor = [System.Drawing.Color]::Gray;       $nOff++ }
            }
            $lvG.Items.Add($item) | Out-Null
            $script:UltimoDiag += $d
            if ("$($d.TCU)" -match '^\d+$') { Cierre-MarcarSiEsta $etiquetaNcu ([int]$d.TCU) 'modo' $(if ("$($d.Modo)" -eq 'AUTO') { 'OK' } else { "$($d.Modo)" }) }
            Prog-Paso
            if ($d.Salud -ne 'OK') {
                Con ("{0}TCU {1,3}  {2,-8} {3}" -f $(if ($etiquetaNcu) { "NCU$etiquetaNcu " } else { '' }), $d.TCU, $d.Salud, $d.Alarmas) ([System.Drawing.Color]::Orange)
            }
        }
        [System.Windows.Forms.Application]::DoEvents()
        continue
    }
    $segs = @(Plan-Segmentos $tr.tcus $tr.cx)
    foreach ($seg in $segs) {
    if ($script:Cancelar) { break }
    $segOk = $true; $errSeg = ''
    try { Modbus-Conectar $tr.ip $seg.puerto $tr.cx.to }
    catch { $segOk = $false; $errSeg = "sin conexion ($($tr.ip):$($seg.puerto))"; Con "ERROR: $errSeg : $_" ([System.Drawing.Color]::Salmon) }
    foreach ($tcu in $seg.tcus) {
        if (Chequear-Cancelado) { break }
        $d = $null; $err = $errSeg
        if ($segOk) {
            for ($i = 1; $i -le $tr.cx.reint -and $null -eq $d; $i++) {
                if ($script:Cancelar) { break }
                try { $d = Diag-LeerTcu $tcu }
                catch {
                    $err = "$_"
                    if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                    Start-Sleep -Milliseconds (300 * $i)
                }
            }
        }
        if ($null -eq $d) {
            $d = [pscustomobject]@{
                TCU=[int]$tcu; GW=''; Salud='OFFLINE'; Modo=''; Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''
                Vbat_mV=''; Ibat_mA=''; Vpanel_mV=''; Ientrada_mA=''; Imotor_mA=''; ImotorPico_mA=''; Dia=''; Tbat_C=''; Tpcb_C=''; Alarmas=$err
                main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''
            }
        }
        $etiquetaNcu = ''
        if ($null -ne $tr.ncu) { $etiquetaNcu = "$($tr.ncu)" }
        $d | Add-Member -NotePropertyName NCU -NotePropertyValue $etiquetaNcu -Force
        $d | Add-Member -NotePropertyName GW -NotePropertyValue (Gw-DeTcu $tr.cx.gws ([int]"$($d.TCU)")) -Force
        $item = New-Object System.Windows.Forms.ListViewItem($etiquetaNcu)
        foreach ($c in @($d.TCU, $d.GW, $d.Salud, $d.Modo, $d.Tilt, $d.Objetivo, $d.Dif, $d.SoC, $d.Edad_s, $d.Alarmas)) {
            [void]$item.SubItems.Add("$c")
        }
        switch ($d.Salud) {
            'OK'      { $item.ForeColor = [System.Drawing.Color]::DarkGreen;  $nOk++ }
            'AVISO'   { $item.ForeColor = [System.Drawing.Color]::DarkOrange; $nAviso++ }
            'ALARMA'  { $item.ForeColor = [System.Drawing.Color]::Firebrick;  $nAlarma++ }
            'OFFLINE' { $item.ForeColor = [System.Drawing.Color]::Gray;       $nOff++ }
        }
        $lvG.Items.Add($item) | Out-Null
        $script:UltimoDiag += $d
        if ($d.Salud -ne 'OK') {
            Con ("{0}TCU {1,3}  {2,-8} {3}" -f $(if ($etiquetaNcu) { "NCU$etiquetaNcu " } else { '' }), $d.TCU, $d.Salud, $d.Alarmas) ([System.Drawing.Color]::Orange)
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    }
    }
    }
    Modbus-Cerrar
    Cierre-Guardar (Nombre-Planta); Cierre-Pintar
    $lblGResumen.Text = "TCUs -> OK: $nOk  Aviso: $nAviso  Alarma: $nAlarma  Off: $nOff" +
        $(if (($nHOk + $nHMal) -gt 0) { "   |   HSUs: $($nHOk + $nHMal) ($nHOk OK)" } else { '' })
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Diagnostico: OK $nOk | AVISO $nAviso | ALARMA $nAlarma | OFFLINE $nOff" ([System.Drawing.Color]::SteelBlue)
    Marcar-Bloque 'diag'
    # copia a disco: si luego lanzas otra cosa, esto no se pierde
    [void](Trabajo-Guardar 'diag' $script:UltimoDiag "OK $nOk | AVISO $nAviso | ALARMA $nAlarma | OFFLINE $nOff")
    # resumen general por NCU (planta completa) y refresco de los filtros de vista
    if ($cx.multi) {
        foreach ($g in @($script:UltimoDiag | Where-Object { $_.NCU } | Group-Object NCU)) {
            $c = @{}
            foreach ($d in $g.Group) { $c[$d.Salud] = 1 + [int]$c[$d.Salud] }
            Con ("  NCU{0}: OK {1} | AVISO {2} | ALARMA {3} | OFFLINE {4}" -f $g.Name, [int]$c['OK'], [int]$c['AVISO'], [int]$c['ALARMA'], [int]$c['OFFLINE']) ([System.Drawing.Color]::SteelBlue)
        }
    }
    $selV = $cbGVerNcu.SelectedItem
    $cbGVerNcu.Items.Clear()
    [void]$cbGVerNcu.Items.Add('NCU - todas')
    foreach ($nv in @($script:UltimoDiag | ForEach-Object { "$($_.NCU)" } | Where-Object { $_ } | Sort-Object {[int]$_} -Unique)) { [void]$cbGVerNcu.Items.Add("NCU$nv") }
    if ($selV -and $cbGVerNcu.Items.Contains($selV)) { $cbGVerNcu.SelectedItem = $selV } else { $cbGVerNcu.SelectedIndex = 0 }
    Diag-Refrescar
}

# Repinta la lista del diagnostico desde el ultimo resultado aplicando los
# filtros de vista (NCU y salud) - no relanza ninguna lectura. Los exports
# CSV/JSON siempre llevan el diagnostico completo, sin estos filtros.
function Diag-Refrescar {
    $fNcu = "$($cbGVerNcu.SelectedItem)"
    # saludes marcadas (varias a la vez); ninguna = todas
    $sal = @()
    foreach ($k in @('OK','AVISO','ALARMA','OFFLINE')) { if ($script:ChksSalud[$k].Checked) { $sal += $k } }
    $lvG.BeginUpdate()
    $lvG.Items.Clear()
    $n = 0
    foreach ($d in $script:UltimoDiag) {
        if ($fNcu -ne 'NCU - todas' -and ("NCU$($d.NCU)") -ne $fNcu) { continue }
        if ($sal.Count -gt 0 -and $sal -notcontains "$($d.Salud)") { continue }
        $item = New-Object System.Windows.Forms.ListViewItem("$($d.NCU)")
        foreach ($c in @($d.TCU, $d.GW, $d.Salud, $d.Modo, $d.Tilt, $d.Objetivo, $d.Dif, $d.SoC, $d.Edad_s, $d.Alarmas)) { [void]$item.SubItems.Add("$c") }
        switch ("$($d.Salud)") {
            'OK'      { $item.ForeColor = [System.Drawing.Color]::DarkGreen }
            'AVISO'   { $item.ForeColor = [System.Drawing.Color]::DarkOrange }
            'ALARMA'  { $item.ForeColor = [System.Drawing.Color]::Firebrick }
            'OFFLINE' { $item.ForeColor = [System.Drawing.Color]::Gray }
        }
        $lvG.Items.Add($item) | Out-Null
        $n++
    }
    $lvG.EndUpdate()
    $tot = @($script:UltimoDiag).Count
    if ($fNcu -eq 'NCU - todas' -and $sal.Count -eq 0) { $lblGVer.Text = "$tot filas" }
    else { $lblGVer.Text = "$n de $tot filas  ($fNcu / $(if ($sal.Count) { $sal -join '+' } else { 'todas' })) - el CSV/JSON exporta siempre todo" }
}

$btnDiag.Add_Click({ Lanzar { $script:UltimoEsComm = $false; Diag-Correr } })

# TEST COMM: quien habla y quien no, en segundos. Solo lastComm via NCU
# (2 regs por TCU) + la salud de cada NCU: ni bloque compacto ni Zigbee.
$btnGComm.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $trabajos = @(Trabajos-Planta $cx $null $(if ($cx.multi) { $txtGNcus.Text } else { '' }) (Parse-Seleccion $txtGTcus.Text 'Test comm') $txtGw.Text)
    if ($trabajos.Count -eq 0) { Con 'El filtro de NCUs no coincide con ninguna NCU de la planta.' ([System.Drawing.Color]::Orange); return }
    $lvG.Items.Clear(); $script:UltimoDiag = @(); $lblGResumen.Text = ''
    $script:UltimaCarga = @{}   # lo leido de carga era de la lectura anterior
    $script:UltimoEsComm = $true
    $reloj0 = Get-Date
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    $totT = 0; foreach ($tr in $trabajos) { $totT += @($tr.tcus).Count }
    Con "TEST COMM: $($trabajos.Count) NCU(s), $totT TCUs y sus HSUs - solo lastComm via NCU (puerto $PUERTO_NCU)" ([System.Drawing.Color]::SteelBlue)
    $nOk = 0; $nOff = 0; $nNcuOk = 0; $nNcuKo = 0; $nHsuOk = 0; $nHsuKo = 0
    foreach ($tr in $trabajos) {
        $script:NcuLog = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
        if ($script:Cancelar) { break }
        $et = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
        $c = $null; $err = ''
        try { Modbus-Conectar $tr.ip $PUERTO_NCU $tr.cx.to; $c = Ncu-Comm $tr.tcus }
        catch { $err = "$_" }
        Modbus-Cerrar
        if ($null -eq $c) {
            $nNcuKo++
            $d = [pscustomobject]@{NCU=$et; TCU='NCU'; GW=''; Salud='OFFLINE'; Modo='-'; Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''
                Vbat_mV=''; Ibat_mA=''; Vpanel_mV=''; Ientrada_mA=''; Imotor_mA=''; ImotorPico_mA=''; Dia=''; Tbat_C=''; Tpcb_C=''; Alarmas="NCU SIN RESPUESTA en $($tr.ip):${PUERTO_NCU} - $err"
                main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''}
            $script:UltimoDiag += $d
            $nOff += @($tr.tcus).Count
            Con ("NCU{0,-3} {1,-15} SIN RESPUESTA: {2}" -f $et, $tr.ip, $err) ([System.Drawing.Color]::Salmon)
            continue
        }
        $nNcuOk++
        $script:UltimoDiag += [pscustomobject]@{NCU=$et; TCU='NCU'; GW=''; Salud='OK'; Modo='-'; Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''
            Vbat_mV=''; Ibat_mA=''; Vpanel_mV=''; Ientrada_mA=''; Imotor_mA=''; ImotorPico_mA=''; Dia=''; Tbat_C=''; Tpcb_C=''; Alarmas="NCU responde ($($tr.ip):$PUERTO_NCU)"
            main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''}
        foreach ($h in $c.hsus) {
            if ($h.comunica) { $nHsuOk++ } else { $nHsuKo++ }
            $script:UltimoDiag += [pscustomobject]@{NCU=$et; TCU=$h.hsu; GW=''; Salud=$(if ($h.comunica) { 'OK' } else { 'OFFLINE' }); Modo='-'
                Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''; Vbat_mV=''; Ibat_mA=''; Vpanel_mV=''; Ientrada_mA=''; Imotor_mA=''; ImotorPico_mA=''; Dia=''; Tbat_C=''; Tpcb_C=''
                Alarmas=$(if ($h.comunica) { "comunica (hace $($h.edad) s)" } else { $(if ($h.lastcomm -eq 0) { 'la NCU nunca la ha leido' } else { "sin datos desde hace $($h.edad) s" }) })
                main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''}
        }
        $mudas = @()
        foreach ($tcu in $tr.tcus) {
            $e = $c.tcus[[int]$tcu]
            $ok = ($null -ne $e -and $e.comunica)
            if ($ok) { $nOk++ } else { $nOff++; $mudas += $tcu }
            $script:UltimoDiag += [pscustomobject]@{NCU=$et; TCU=[int]$tcu; GW=(Gw-DeTcu $tr.cx.gws ([int]$tcu)); Salud=$(if ($ok) { 'OK' } else { 'OFFLINE' }); Modo='-'
                Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''; Vbat_mV=''; Ibat_mA=''; Vpanel_mV=''; Ientrada_mA=''; Imotor_mA=''; ImotorPico_mA=''; Dia=''; Tbat_C=''; Tpcb_C=''
                Alarmas=$(if ($ok) { "comunica (hace $($e.edad) s)" } elseif ($null -eq $e -or $e.lastcomm -eq 0) { 'la NCU nunca ha leido este TCU' } else { "sin datos desde hace $($e.edad) s" })
                main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''}
        }
        $nT = @($tr.tcus).Count
        Con ("NCU{0,-3} {1,-15} OK  {2}/{3} TCUs comunican, {4} HSUs{5}" -f $et, $tr.ip, ($nT - $mudas.Count), $nT, @($c.hsus).Count,
            $(if ($mudas.Count) { "  |  SIN COMM: " + ($mudas -join ', ') } else { '' })) `
            $(if ($mudas.Count) { [System.Drawing.Color]::Orange } else { [System.Drawing.Color]::LightGreen })
        [System.Windows.Forms.Application]::DoEvents()
    }
    $seg = [math]::Round(((Get-Date) - $reloj0).TotalSeconds, 1)
    $lblGResumen.Text = "Comm: $nOk / $($nOk + $nOff)"
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "TEST COMM en $seg s: NCUs $nNcuOk OK / $nNcuKo sin respuesta | TCUs $nOk comunican / $nOff sin comunicacion | HSUs $nHsuOk OK / $nHsuKo sin comunicacion" ([System.Drawing.Color]::SteelBlue)
    Marcar-Bloque 'diag'
    [void](Trabajo-Guardar 'comm' $script:UltimoDiag "$nNcuOk NCUs, $nOk de $($nOk + $nOff) TCUs comunican")
    Con "Es solo una prueba de comunicacion (lastComm): para alarmas, modo y posiciones usa DIAGNOSTICAR." ([System.Drawing.Color]::Gainsboro)
    $selV = $cbGVerNcu.SelectedItem
    $cbGVerNcu.Items.Clear()
    [void]$cbGVerNcu.Items.Add('NCU - todas')
    foreach ($nv in @($script:UltimoDiag | ForEach-Object { "$($_.NCU)" } | Where-Object { $_ } | Sort-Object {[int]$_} -Unique)) { [void]$cbGVerNcu.Items.Add("NCU$nv") }
    if ($selV -and $cbGVerNcu.Items.Contains($selV)) { $cbGVerNcu.SelectedItem = $selV } else { $cbGVerNcu.SelectedIndex = 0 }
    Diag-Refrescar
} })

$cbGVerNcu.Add_SelectedIndexChanged({ if (-not $script:Ocupado) { Diag-Refrescar } })

# Trabaja sobre el ultimo diagnostico: la tension, la corriente, el SoH y las
# temperaturas ya se leyeron ahi. Cero lecturas nuevas.
$script:UltimaBatTabla = @()
# "ncu|tcu" -> lo leido en la seccion de carga. Vacio hasta que se pulsa LEER
# CARGA, y se vacia con cada diagnostico nuevo para no mezclar dos momentos.
$script:UltimaCarga = @{}

function Bat-Pintar {
    if (@($script:UltimoDiag).Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Haz primero un DIAGNOSTICAR: estas son sus baterias, no se lee nada nuevo.','Falta el diagnostico'); return $false
    }
    $script:UltimaBat = @(Bat-Auditar $script:UltimoDiag)
    $script:UltimaBatTabla = @(Bat-Tabla $script:UltimoDiag $script:UltimaBat $script:UltimaCarga)
    $lvB.BeginUpdate(); $lvB.Items.Clear()
    foreach ($f in $script:UltimaBatTabla) {
        $item = New-Object System.Windows.Forms.ListViewItem("$($f.NCU)")
        foreach ($c in @($f.TCU, $f.SoC, $f.SoH, $f.Vbat_mV, $f.Ibat_mA, $f.Vpanel_mV, $f.Ientrada_mA,
                         $f.Tbat_C, $f.Tpcb_C, $f.Dia, $f.Carga, $f.Estado)) { [void]$item.SubItems.Add("$c") }
        $item.ForeColor = $(if ($f.Estado -eq 'OK') { [System.Drawing.Color]::DarkGreen }
                            elseif ($f.Estado -eq 'sin datos') { [System.Drawing.Color]::Gray }
                            elseif ($f.Estado -like '*SIN BATERIA*' -or $f.Estado -like '*SOBRETENSION*') { [System.Drawing.Color]::Firebrick }
                            else { [System.Drawing.Color]::DarkOrange })
        $lvB.Items.Add($item) | Out-Null
    }
    $lvB.EndUpdate()
    $nMal = @($script:UltimaBatTabla | Where-Object { $_.Estado -ne 'OK' -and $_.Estado -ne 'sin datos' }).Count
    $nSin = @($script:UltimaBatTabla | Where-Object { $_.Estado -eq 'sin datos' }).Count
    $lblBRes.Text = "$($script:UltimaBatTabla.Count) TCUs | $nMal con algo que mirar | $nSin sin datos"
    $btnBCsv.Enabled = ($script:UltimaBatTabla.Count -gt 0)
    $btnBJson.Enabled = $btnBCsv.Enabled
    return $true
}

# ------------------------- TRABAJOS GUARDADOS (interfaz) -------------------------
$script:Trabajos = @()

function Trabajos-Pintar {
    $script:Trabajos = @()
    try {
        $dir = Trabajos-Dir
        foreach ($f in @(Get-ChildItem $dir -Filter '*.json' -File)) {
            try {
                $o = Get-Content $f.FullName -Raw | ConvertFrom-Json
                $script:Trabajos += ,(Trabajo-Resumen $o $f.FullName)
            } catch {}
        }
    } catch {}
    $script:Trabajos = @(Trabajos-Ordenar $script:Trabajos)
    $lvT.BeginUpdate(); $lvT.Items.Clear()
    foreach ($t in $script:Trabajos) {
        $item = New-Object System.Windows.Forms.ListViewItem("$($t.Fecha)")
        foreach ($c in @($t.Tipo, $t.Planta, $t.Filas, $t.Tecnico, $t.Nota)) { [void]$item.SubItems.Add("$c") }
        $lvT.Items.Add($item) | Out-Null
    }
    $lvT.EndUpdate()
    $lblTRes.Text = "$($script:Trabajos.Count) trabajos guardados"
    $btnTCargar.Enabled = ($script:Trabajos.Count -gt 0)
    $btnTBorrar.Enabled = $btnTCargar.Enabled
}

# Pinta en una tabla las filas de un trabajo, usando las columnas que ese tipo
# declara. Asi no hay una copia del pintado por pestana.
function Trabajo-AtabLa($lv, $filas, $cols) {
    $lv.BeginUpdate(); $lv.Items.Clear()
    foreach ($f in @($filas)) {
        $item = New-Object System.Windows.Forms.ListViewItem("$($f.($cols[0]))")
        foreach ($c in @($cols[1..($cols.Count - 1)])) { [void]$item.SubItems.Add("$($f.$c)") }
        $lv.Items.Add($item) | Out-Null
    }
    $lv.EndUpdate()
}

$btnTRef.Add_Click({ Trabajos-Pintar; Con "Trabajos guardados: $($script:Trabajos.Count)." ([System.Drawing.Color]::SteelBlue) })

$btnTCarpeta.Add_Click({ try { Start-Process (Trabajos-Dir) } catch { Con "No se ha podido abrir la carpeta: $_" ([System.Drawing.Color]::Orange) } })

$btnTBorrar.Add_Click({
    $i = $lvT.SelectedIndices
    if ($i.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Elige un trabajo de la lista.','Trabajos'); return }
    $n = 0
    foreach ($k in @($i)) {
        $t = $script:Trabajos[$k]
        try { Remove-Item $t.fichero -Force; $n++ } catch {}
    }
    Trabajos-Pintar
    Con "Borrados $n trabajos." ([System.Drawing.Color]::SteelBlue)
})

# Guarda a mano lo que haya en memoria ahora mismo, con una nota. El guardado
# automatico ya deja copia de cada operacion; esto sirve para marcar un momento
# ("antes de tocar la NCU 12").
$btnTGuardar.Add_Click({
    $nota = [Microsoft.VisualBasic.Interaction]::InputBox('Nota para este trabajo (opcional):', 'Guardar lo de ahora', '')
    $n = 0
    foreach ($tipo in @('diag','inventario','auditoria','lectura','baterias')) {
        $var = $TRABAJO_TIPOS[$tipo].var
        $filas = @(Get-Variable -Name $var -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        if (@($filas).Count -eq 0) { continue }
        $t = $(if ($tipo -eq 'diag' -and $script:UltimoEsComm) { 'comm' } else { $tipo })
        if ((Trabajo-Guardar $t $filas $nota) -ne '') { $n++ }
    }
    Trabajos-Pintar
    if ($n -eq 0) { Con 'No hay nada en memoria que guardar: haz antes un diagnostico, un inventario, una auditoria...' ([System.Drawing.Color]::Orange) }
    else { Con "Guardados $n trabajos de esta sesion." ([System.Drawing.Color]::LightGreen) }
})

function Trabajo-Cargar {
    $i = $lvT.SelectedIndices
    if ($i.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Elige un trabajo de la lista.','Trabajos'); return }
    $t = $script:Trabajos[$i[0]]
    $o = $null
    try { $o = Get-Content $t.fichero -Raw | ConvertFrom-Json }
    catch { Con "No se ha podido leer el trabajo: $_" ([System.Drawing.Color]::Salmon); return }
    $filas = @($o.filas)
    $def = $TRABAJO_TIPOS["$($o.tipo)"]
    if (-not $def) { Con "Tipo de trabajo desconocido: $($o.tipo)" ([System.Drawing.Color]::Orange); return }
    Set-Variable -Name $def.var -Scope Script -Value $filas
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Cargado: $($def.titulo) de $($o.fecha) - $($o.planta) - $(@($filas).Count) filas$(if ("$($o.nota)" -ne '') { "  ($($o.nota))" })" ([System.Drawing.Color]::LightGreen)
    switch ("$($o.tipo)") {
        'diag' {
            $script:UltimoEsComm = $false
            Trabajos-ComboNcus
            Diag-Refrescar; $tabs.SelectedTab = $tabG
        }
        'comm' {
            $script:UltimoEsComm = $true
            Trabajos-ComboNcus
            Diag-Refrescar; $tabs.SelectedTab = $tabG
        }
        'inventario' { Trabajo-AtabLa $lvV $filas $def.cols; $tabs.SelectedTab = $tabF }
        'auditoria'  { Trabajo-AtabLa $lvA $filas $def.cols; $tabs.SelectedTab = $tabF }
        'baterias'   { Trabajo-AtabLa $lvB $filas $def.cols; $tabs.SelectedTab = $tabB }
        'lectura'    {
            $tabs.SelectedTab = $tabF
            Con "  La lectura vuelve a estar en memoria: ve a Auditoria con 'Usar la ultima lectura' marcado y audita contra ella sin tocar la planta." ([System.Drawing.Color]::Gainsboro)
        }
    }
    Con "  Es una copia de disco: no se ha leido nada de la planta." ([System.Drawing.Color]::Gainsboro)
}

# El desplegable de NCUs del diagnostico se rellena con lo que haya cargado
function Trabajos-ComboNcus {
    $selV = $cbGVerNcu.SelectedItem
    $cbGVerNcu.Items.Clear()
    [void]$cbGVerNcu.Items.Add('NCU - todas')
    foreach ($nv in @($script:UltimoDiag | ForEach-Object { "$($_.NCU)" } | Where-Object { $_ } | Sort-Object {[int]$_} -Unique)) { [void]$cbGVerNcu.Items.Add("NCU$nv") }
    if ($selV -and $cbGVerNcu.Items.Contains($selV)) { $cbGVerNcu.SelectedItem = $selV } else { $cbGVerNcu.SelectedIndex = 0 }
}

$btnTCargar.Add_Click({ Trabajo-Cargar })
$lvT.Add_DoubleClick({ Trabajo-Cargar })

$btnBVer.Add_Click({ if (Bat-Pintar) { Con "Baterias: $($script:UltimaBatTabla.Count) TCUs del ultimo diagnostico." ([System.Drawing.Color]::SteelBlue) } })
$btnBAud.Add_Click({ if (Bat-Pintar) { $btnGBat.PerformClick() } })

# El bloque compacto de 22 registros por TCU no trae el estado del cargador:
# eso vive en el bloque largo (50000 + (TCU-1)*50), offsets 21..31. Una peticion
# corta por TCU, y solo cuando se pide: con esto el equipo DICE si esta
# cargando, en vez de deducirlo de la corriente.
$btnBCar.Add_Click({ Lanzar {
    if (@($script:UltimaBatTabla).Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Pulsa antes VER BATERIAS: la carga se lee para las TCUs de esa tabla.','Falta la tabla'); return
    }
    $cx = Params-Conexion
    $ped = Carga-Pedidos $script:UltimaBatTabla
    $trabajos = @(Trabajos-Planta $cx $null '')
    $tot = 0; foreach ($k in @($ped.Keys)) { $tot += @($ped[$k]).Count }
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "CARGA: $tot TCUs, bloque largo de la NCU (50000 + (TCU-1)*50, offsets 21..31) por el puerto $PUERTO_NCU" ([System.Drawing.Color]::SteelBlue)
    Prog-Iniciar $tot
    $nOk = 0; $nKo = 0
    foreach ($tr in $trabajos) {
        if ($script:Cancelar) { break }
        $et = "$($tr.ncu)"
        $script:NcuLog = $et
        # ojo: $ped[$et] de una clave que no existe es $null, y @($null) tiene
        # UN elemento en PS 5.1. Sin el ContainsKey se pediria una TCU vacia.
        if (-not $ped.ContainsKey($et)) { continue }
        $mias = @($ped[$et])
        if ($mias.Count -eq 0) { continue }
        try { Modbus-Conectar $tr.ip $PUERTO_NCU $tr.cx.to }
        catch {
            $nKo += $mias.Count; Prog-Paso $mias.Count
            Con ("NCU{0,-3} {1,-15} SIN RESPUESTA: {2}" -f $et, $tr.ip, $_) ([System.Drawing.Color]::Salmon)
            continue
        }
        foreach ($tcu in $mias) {
            if ($script:Cancelar) { break }
            $c = Ncu-CargaCompat @($tcu)
            if ($c.ContainsKey([int]$tcu)) { $script:UltimaCarga["$et|$tcu"] = $c[[int]$tcu]; $nOk++ }
            else { $nKo++ }
            Prog-Paso
            [System.Windows.Forms.Application]::DoEvents()
        }
        Modbus-Cerrar
        Con ("NCU{0,-3} {1,-15} carga leida de {2} TCUs" -f $et, $tr.ip, $mias.Count) ([System.Drawing.Color]::LightGreen)
        [System.Windows.Forms.Application]::DoEvents()
    }
    [void](Bat-Pintar)
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "CARGA: $nOk TCUs con estado de cargador, $nKo sin respuesta." $(if ($nKo) { [System.Drawing.Color]::Orange } else { [System.Drawing.Color]::SteelBlue })
    if ($nOk -eq 0) {
        Con "Ninguna respondio: puede que esta NCU no sirva el bloque largo (esta en el mapa R7.1, pero no todas las versiones lo exponen)." ([System.Drawing.Color]::Orange)
    }
} })

$btnBCsv.Add_Click({
    if (@($script:UltimaBatTabla).Count -eq 0) { return }
    [void](Exportar-Csv $script:UltimaBatTabla 'baterias' 'Baterias')
})

$btnBJson.Add_Click({
    if (@($script:UltimaBatTabla).Count -eq 0) { return }
    # la carga cruda va aparte: en la tabla solo cabe el texto, y para
    # discutir con fabrica hacen falta los registros tal cual
    $o = @{tipo='baterias_tcu'; planta=(Nombre-Planta); fecha=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
           toolbox=$VERSION_TOOLBOX; tecnico=$script:Usuario; tcus=@($script:UltimaBatTabla)
           carga=$script:UltimaCarga}
    [void](Exportar-Json $o 'baterias' 'Baterias en JSON')
})

$btnGBat.Add_Click({
    if (@($script:UltimoDiag).Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Haz primero un DIAGNOSTICAR: la auditoria de baterias se hace con esos datos, sin volver a leer.','Falta el diagnostico'); return
    }
    $script:UltimaBat = @(Bat-Auditar $script:UltimoDiag)
    $script:UltimaBatTabla = @(Bat-Tabla $script:UltimoDiag $script:UltimaBat $script:UltimaCarga)
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    $vistos = @($script:UltimoDiag | Where-Object { "$($_.TCU)" -match '^\d+$' -and "$($_.Salud)" -ne 'OFFLINE' }).Count
    if ($script:UltimaBat.Count -eq 0) {
        Con "BATERIAS: $vistos TCUs revisadas, ninguna con problema de bateria." ([System.Drawing.Color]::LightGreen)
        Marcar-Bloque 'bat'
        return
    }
    $porTipo = @{}
    foreach ($b in $script:UltimaBat) { $porTipo["$($b.Tipo)"] = 1 + [int]$porTipo["$($b.Tipo)"] }
    $afectadas = @(@($script:UltimaBat | ForEach-Object { "$($_.NCU)|$($_.TCU)" }) | Sort-Object -Unique).Count
    # "6 de 705 TCUs" y luego "1 CARGA BAJA | 3 FUERA DE LA FLOTA | 6 PANEL SIN
    # TENSION" suman 10 y parecia contradecir el 6: son unidades distintas, TCUs
    # y avisos. Una TCU puede tener tres cosas a la vez.
    $nAv = @($script:UltimaBat).Count
    Con "BATERIAS: $afectadas de $vistos TCUs con algo que mirar, $nAv $(if ($nAv -eq 1) { 'aviso' } else { 'avisos' }) en total: $((@($porTipo.Keys | Sort-Object | ForEach-Object { "$($porTipo[$_]) $_" }) -join ' | '))" ([System.Drawing.Color]::Orange)
    foreach ($b in @($script:UltimaBat | Sort-Object @{Expression={$(if ($_.Gravedad -eq 'ALARMA') { 0 } else { 1 })}}, @{Expression={[int]("0" + "$($_.NCU)")}}, @{Expression={[int]$_.TCU}})) {
        Con ("  NCU{0,-3} TCU {1,3}  {2,-18} {3}" -f $b.NCU, $b.TCU, $b.Tipo, $b.Detalle) $(if ($b.Gravedad -eq 'ALARMA') { [System.Drawing.Color]::Salmon } else { [System.Drawing.Color]::Orange })
    }
    Con "Las de FUERA DE LA FLOTA no estan fuera de rango: se salen de lo que tienen las demas, que con 754 medidas es la mejor referencia que hay." ([System.Drawing.Color]::Gainsboro)
    Con "La tabla con todas las variables de bateria esta en la pestana Baterias." ([System.Drawing.Color]::Gainsboro)
    Marcar-Bloque 'bat'
    [void](Trabajo-Guardar 'baterias' $script:UltimaBatTabla "$afectadas TCUs con algo que mirar")
})

$btnGWa.Add_Click({
    $fNcu = "$($cbGVerNcu.SelectedItem)"
    $soloNcu = ''
    if ($fNcu -ne 'NCU - todas') { $soloNcu = ($fNcu -replace '^NCU', '') }
    $txt = Texto-NoOk $script:UltimoDiag (Nombre-Planta) (Get-Date -Format 'dd/MM/yyyy HH:mm') $soloNcu
    $copiado = $false
    try { [System.Windows.Forms.Clipboard]::SetText($txt); $copiado = $true } catch {}
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    foreach ($l in ($txt -split "`r`n")) { Con $l ([System.Drawing.Color]::Gainsboro) }
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    if ($copiado) { Con 'Copiado al portapapeles: pegalo en WhatsApp con Ctrl+V.' ([System.Drawing.Color]::LightGreen) }
    else { Con 'No se pudo usar el portapapeles: selecciona el texto de arriba y copialo con Ctrl+C.' ([System.Drawing.Color]::Orange) }
})
foreach ($k in @('OK','AVISO','ALARMA','OFFLINE')) {
    $script:ChksSalud[$k].Add_CheckedChanged({ if (-not $script:Ocupado) { Diag-Refrescar } })
}

# Mini-registrador: diagnostico en bucle cada X minutos, acumulando cada pase
# (con fecha/hora y alarmas desglosadas) en informes/registro_<ts>.csv.
# Se para con el boton CANCELAR.
$COLS_REGISTRO = @('NCU','TCU','Salud','Modo','Tilt','Objetivo','Dif','SoC','SoH','Vbat_mV','Ibat_mA',
                   'Vpanel_mV','Ientrada_mA','Imotor_mA','ImotorPico_mA',
                   'Tbat_C','Tpcb_C','Alarmas','main_status','alarmas_1','alarmas_2','alarmas_3','alarmas_4','system_status')
$btnGBucle.Add_Click({ Lanzar {
    $cada = Val-Int $txtGCada.Text 'Registrador: minutos' 1 1440
    $null = Params-Conexion   # valida la conexion antes de empezar el bucle
    $dir = Join-Path $PSScriptRoot 'informes'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $fich = Join-Path $dir ('registro_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv')
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Registrador: un diagnostico cada $cada min acumulando en $fich  - pulsa CANCELAR para parar." ([System.Drawing.Color]::SteelBlue)
    $vuelta = 0
    while (-not $script:Cancelar) {
        $vuelta++
        $lblGBucle.Text = "Registrador: vuelta $vuelta en curso..."
        $script:UltimoEsComm = $false
        Diag-Correr
        $ahora = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $filas = foreach ($d in $script:UltimoDiag) {
            $o = [ordered]@{FechaHora = $ahora}
            foreach ($c in $COLS_REGISTRO) { $o[$c] = "$($d.$c)" }   # columnas fijas: -Append exige el mismo esquema
            $des = Alarmas-Desglose "$($d.alarmas_1)" "$($d.alarmas_2)"
            foreach ($k in $des.Keys) { $o[$k] = $des[$k] }
            [pscustomobject]$o
        }
        if (@($filas).Count -gt 0) { @($filas) | Export-Csv $fich -NoTypeInformation -Encoding UTF8 -Append }
        if ($script:Cancelar) { break }
        $lblGBucle.Text = "Registrador: $vuelta pases guardados. Proximo en $cada min (CANCELAR para parar)."
        $hasta = (Get-Date).AddMinutes($cada)
        while ((Get-Date) -lt $hasta) {
            if ($script:Cancelar) { break }
            Start-Sleep -Milliseconds 500
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    Con "Registrador parado tras $vuelta pases. CSV acumulado: $fich" ([System.Drawing.Color]::SteelBlue)
    $lblGBucle.Text = "Registrador parado ($vuelta pases): $fich"
} })

$btnGCsv.Add_Click({
    # con las alarmas desglosadas en columnas 0/1 (filtrables en Excel)
    $filas = foreach ($d in $script:UltimoDiag) {
        $o = [ordered]@{}
        foreach ($pr in $d.PSObject.Properties) { $o[$pr.Name] = $pr.Value }
        $des = Alarmas-Desglose "$($d.alarmas_1)" "$($d.alarmas_2)"
        foreach ($k in $des.Keys) { $o[$k] = $des[$k] }
        [pscustomobject]$o
    }
    [void](Exportar-Csv $filas 'diagnostico' 'CSV con alarmas desglosadas')
})

$btnGJson.Add_Click({
    if ($script:UltimoEsComm) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Lo ultimo que se ha ejecutado es un TEST COMM (solo comunicacion), no un diagnostico completo.`r`n`r`nSe exportara como 'test_comm' y la plataforma NO lo aceptara como diagnostico.`r`n`r`nExportar igualmente?",
            'Test de comunicacion', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    $obj = [ordered]@{
        tipo    = $(if ($script:UltimoEsComm) { 'test_comm' } else { 'diagnostico_tcu' })
        mapa    = $VERSION_MAPA
        toolbox = $VERSION_TOOLBOX
        planta  = Nombre-Planta
        ip      = $txtIp.Text.Trim()
        puerto  = $txtPort.Text.Trim()
        fecha   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        tcus    = @($script:UltimoDiag)
    }
    [void](Exportar-Json $obj $(if ($script:UltimoEsComm) { 'test_comm' } else { 'diagnostico' }))
})

# ------------------------- SINCRONIZAR RELOJ -------------------------
$btnSync.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $tcus = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtSTcus.Text 'Sincronizar') $txtGw.Text).tcus
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Sincronizar fecha/hora de $($tcus.Count) TCUs ($($tcus[0])-$($tcus[-1])) con la hora de este PC?`r`n`r`nSecuencia por TCU: 40007 bit0 (permitir) -> 40001..40006 -> 40007 bit1 (aplicar).",
        'Confirmar sincronizacion', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Sincronizando reloj de $($tcus.Count) TCUs con el PC  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    $ok = 0; $ko = 0
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
    if ($script:Cancelar) { break }
    $segOk = $true
    try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
    catch { $segOk = $false; Con "ERROR de conexion ($($cx.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
    foreach ($tcu in $seg.tcus) {
        if (Chequear-Cancelado) { break }
        $hecho = $false; $fallo = ''
        if (-not $segOk) { $fallo = "sin conexion ($($cx.ip):$($seg.puerto))" }
        for ($i = 1; $i -le $cx.reint -and -not $hecho -and $segOk; $i++) {
            if ($script:Cancelar) { break }
            try {
                # bit 0: permitir introduccion de fecha/hora
                FC22-Mascara $tcu 40007 0xFFFE 0x0001
                # tomar la hora justo antes de escribir
                $ahora = Get-Date
                FC16-Escribir $tcu 40001 @($ahora.Second, $ahora.Minute, $ahora.Hour, $ahora.Day, $ahora.Month, $ahora.Year)
                # bit 1: aplicar
                FC22-Mascara $tcu 40007 0xFFFD 0x0002
                # limpiar bits 0 y 1 por si el FW no los auto-borra
                FC22-Mascara $tcu 40007 0xFFFC 0x0000
                $hecho = $true
            } catch {
                $fallo = "$_"
                if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                Start-Sleep -Milliseconds (300 * $i)
            }
        }
        if ($hecho) {
            $ok++
            if ($chkSVerif.Checked) {
                try {
                    $reloj = Leer-Decodificado $tcu @{addr=30079; tipo='dt_bcd'}
                    Con ((Eti-Tcu $tcu) + ("  OK  reloj = {0}" -f $reloj)) ([System.Drawing.Color]::LightGreen)
                } catch {
                    Con ((Eti-Tcu $tcu) + ("  OK  (reloj no verificable: {0})" -f $_)) ([System.Drawing.Color]::LightGreen)
                }
            } else {
                Con ((Eti-Tcu $tcu) + "  OK") ([System.Drawing.Color]::LightGreen)
            }
        } else {
            $ko++
            Con ((Eti-Tcu $tcu) + ("  FALLO  {0}" -f $fallo)) ([System.Drawing.Color]::Salmon)
        }
    }
    }
    Modbus-Cerrar
    Con "Sincronizacion: $ok OK, $ko fallos" ([System.Drawing.Color]::SteelBlue)
} })

# ------------------------- ESCRIBIR CSV POR TCU -------------------------
$btnCsvTcu.Add_Click({ Lanzar {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.Title = 'CSV con cabecera TCU;variable;valor (valores distintos por TCU)'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $res = Parse-CsvPorTcu (Get-Content $dlg.FileName)
    foreach ($e in $res.errores) { Con "AVISO CSV: $e" ([System.Drawing.Color]::Orange) }
    $jobs = @($res.jobs)
    if ($jobs.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('El CSV no tiene filas validas.','Aviso'); return }
    $cx = Params-Conexion
    # Con columna NCU el CSV puede tocar TCUs de varias NCUs de una pasada, que
    # es lo que hace falta para corregir equipos sueltos repartidos por la planta.
    $rep = Grupos-CsvPorNcu $jobs $cx
    foreach ($a in $rep.avisos) { Con "AVISO CSV: $a" ([System.Drawing.Color]::Orange) }
    $grupos = @($rep.grupos)
    if ($grupos.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show("No se puede aplicar el CSV:`r`n`r`n$($rep.avisos -join "`r`n")",'CSV por TCU','OK','Error'); return }
    $nEsc = 0; $nTcusTot = 0
    foreach ($g in $grupos) { $nEsc += @($g.jobs).Count; $nTcusTot += @(@($g.jobs) | ForEach-Object { $_.tcu } | Sort-Object -Unique).Count }
    $donde = $(if ($grupos.Count -gt 1 -or $null -ne $grupos[0].ncu) { "$($grupos.Count) NCUs" } else { "$($cx.ip):$($cx.etiqueta)" })
    $r = [System.Windows.Forms.MessageBox]::Show(
        "CSV: $nEsc escrituras en $nTcusTot TCUs de $donde" +
        $(if ($res.errores.Count -gt 0) { "`r`n($($res.errores.Count) lineas con error se saltan - ver consola)" } else { '' }) +
        $(if ($rep.avisos.Count -gt 0) { "`r`n($($rep.avisos.Count) avisos - ver consola)" } else { '' }) +
        "`r`n`r`nContinuar?", 'Confirmar CSV por TCU', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $peligro = @($grupos | ForEach-Object { $_.jobs } | Where-Object { $ADDR_COMANDO -contains $VARIABLES[$_.nombre].addr })
    if ($peligro.Count -gt 0) {
        $r2 = [System.Windows.Forms.MessageBox]::Show(
            "ATENCION: el CSV toca $($peligro.Count) registros de COMANDO. Seguro?",
            'REGISTROS DE COMANDO', 'YesNo', 'Stop')
        if ($r2 -ne 'Yes') { return }
    }
    if ($nTcusTot -gt 3 -and -not $chkRoll.Checked) {
        Con 'Sin copia de seguridad previa (casilla desmarcada): esta escritura no se podra deshacer.' ([System.Drawing.Color]::Orange)
    }
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "CSV por TCU: $nEsc escrituras en $nTcusTot TCUs de $donde" ([System.Drawing.Color]::SteelBlue)
    Prog-Iniciar $nEsc
    $ok = 0; $ko = 0
    foreach ($gr in $grupos) {
    if ($script:Cancelar) { break }
    $cx = $gr.cx
    $jobs = @($gr.jobs)
    $tcus = @($jobs | ForEach-Object { $_.tcu } | Sort-Object -Unique)
    $script:NcuLog = $(if ($null -ne $gr.ncu) { "$($gr.ncu)" } else { '' })
    if ($null -ne $gr.ncu) { Con ("--- NCU{0}  ({1})  {2} escrituras en {3} TCUs ---" -f $gr.ncu, $cx.ip, $jobs.Count, $tcus.Count) ([System.Drawing.Color]::SteelBlue) }
    if ($tcus.Count -gt 3 -and $chkRoll.Checked) {
        # rollback previo con los valores actuales (sin registros de comando)
        $paresRb = @()
        foreach ($j in $jobs) { if ($ADDR_COMANDO -notcontains $VARIABLES[$j.nombre].addr) { $paresRb += ,@{tcu=[int]$j.tcu; nombre=$j.nombre} } }
        if ($paresRb.Count -gt 0) {
            Con "Creando copia de seguridad (rollback) de $($paresRb.Count) valores actuales..." ([System.Drawing.Color]::SteelBlue)
            try {
                $rb = Rollback-Crear $paresRb $cx
                Con "Rollback guardado: $($rb.fichero)  ($($rb.filas) valores$(if ($rb.errores) { ", $($rb.errores) sin leer" })). Restaurable con 'CSV por TCU...'." ([System.Drawing.Color]::SteelBlue)
            } catch {
                $r3 = [System.Windows.Forms.MessageBox]::Show(
                    "No se pudo crear la copia de seguridad previa (rollback):`r`n$_`r`n`r`nEscribir AUN ASI, sin copia?", 'Rollback', 'YesNo', 'Warning')
                if ($r3 -ne 'Yes') { continue }
            }
            if ($script:Cancelar) { break }
        }
    }
    $porTcu = @{}
    foreach ($j in $jobs) { if (-not $porTcu.ContainsKey($j.tcu)) { $porTcu[$j.tcu] = @() }; $porTcu[$j.tcu] += ,$j }
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { $segOk = $false; Con "ERROR de conexion ($($cx.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $fallo = $null; $todoOk = $segOk
            $cambios = @()
            if (-not $segOk) { $fallo = "sin conexion ($($cx.ip):$($seg.puerto))" }
            else {
                foreach ($j in $porTcu[[int]$tcu]) {
                    # valor anterior, para dejar rastro "antes -> despues" en el log
                    $previo = '?'
                    try { $previo = Leer-Decodificado $tcu $VARIABLES[$j.nombre] } catch {}
                    $hecho = $false
                    for ($i = 1; $i -le $cx.reint -and -not $hecho; $i++) {
                        if ($script:Cancelar) { break }
                        try {
                            $e = $j.esc
                            if ($e.modo -eq 'fc16') { FC16-Escribir $tcu $e.addr $e.palabras }
                            else { FC22-Mascara $tcu $e.addr $e.and $e.or }
                            if ($chkVerif.Checked) {
                                $cmp = Comparar-Escritura $tcu $e
                                if (-not $cmp.ok) { throw "verificacion: leido $($cmp.leidoRaw)" }
                            }
                            $hecho = $true
                            $cambios += "$($j.nombre): $previo -> $($j.texto)"
                        } catch {
                            $fallo = "$($j.nombre) = $($j.texto): $_"
                            if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                            Start-Sleep -Milliseconds (300 * $i)
                        }
                    }
                    if (-not $hecho) { $todoOk = $false; break }
                }
            }
            Prog-Paso @($porTcu[[int]$tcu]).Count
            if ($todoOk) { $ok++; Con ((Eti-Tcu $tcu) + ("  OK   {0}" -f ($cambios -join ' | '))) ([System.Drawing.Color]::LightGreen)
                Auditar 'CSV_POR_TCU' $script:NcuLog $tcu ($cambios -join ' | ') }
            else { $ko++; Con ((Eti-Tcu $tcu) + ("  FALLO  {0}" -f $fallo)) ([System.Drawing.Color]::Salmon)
                Auditar 'CSV_POR_TCU_FALLO' $script:NcuLog $tcu $fallo }
        }
    }
    Modbus-Cerrar
    }
    $script:NcuLog = ''
    Con "CSV por TCU terminado: $ok OK, $ko con fallo. Recuerda GUARDAR EN NVM si procede." ([System.Drawing.Color]::SteelBlue)
} })

# ------------------------- BACKUP MASIVO DE NCU -------------------------
$btnBackupNcu.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $tcus = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtBTcus.Text 'Backup NCU') $txtGw.Text).tcus
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Carpeta donde guardar los backups JSON (uno por TCU, $($tcus.Count) ficheros)"
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $dir = $dlg.SelectedPath
    $ts = Get-Date -Format 'yyyyMMdd_HHmm'
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Backup NCU: $(Eti-Rango $tcus) -> $dir  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    $ok = 0; $ko = 0
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { $segOk = $false; Con "ERROR de conexion ($($cx.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            if (-not $segOk) { $ko++; Con ((Eti-Tcu $tcu) + "  FALLO  sin conexion") ([System.Drawing.Color]::Salmon); continue }
            $vars = @(); $errs = 0
            foreach ($nombre in $VARIABLES.Keys) {
                if ($script:Cancelar) { break }
                $vdef = $VARIABLES[$nombre]
                $val = $null
                for ($i = 1; $i -le $cx.reint -and $null -eq $val; $i++) {
                    try { $val = Leer-Decodificado $tcu $vdef }
                    catch {
                        if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                        Start-Sleep -Milliseconds 150
                    }
                }
                if ($null -eq $val) { $errs++; $val = '' }
                $vars += [ordered]@{variable=$nombre; valor=$val; grupo='config'}
            }
            if ($script:Cancelar) { break }
            $completo = ($errs -eq 0)
            $obj = [ordered]@{
                tipo='backup_tcu'; mapa=$VERSION_MAPA; toolbox=$VERSION_TOOLBOX
                planta=(Nombre-Planta); ip=$cx.ip; puerto=$seg.puerto; tcu=[int]$tcu
                fecha=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); completo=$completo; errores=$errs
                variables=$vars
            }
            $suf = ''
            if (-not $completo) { $suf = '_INCOMPLETO' }
            $fich = Join-Path $dir ("backup_tcu{0}_{1}{2}.json" -f $tcu, $ts, $suf)
            ConvertTo-Json $obj -Depth 5 | Set-Content $fich -Encoding UTF8
            if ($completo) { $ok++; Con ((Eti-Tcu $tcu) + "  backup OK") ([System.Drawing.Color]::LightGreen) }
            else { $ko++; Con ((Eti-Tcu $tcu) + ("  backup INCOMPLETO ({0} errores)" -f $errs)) ([System.Drawing.Color]::Orange) }
        }
    }
    Modbus-Cerrar
    Con "Backup NCU terminado: $ok completos, $ko incompletos/fallidos. Carpeta: $dir" ([System.Drawing.Color]::SteelBlue)
} })

# Indice (ncu|tcu|variable) -> valor de la ultima lectura, para auditar sin
# volver a preguntar a la planta. Pura: se prueba sin ventana.
# BUSCAR HSUs encuentra lo que la NCU tiene en su cache. La topologia dice lo
# que DEBERIA haber (columna RSU del Excel maestro). Comparar las dos cosas es
# lo que convierte "he encontrado 9" en "falta la de NCU15", que es la
# diferencia entre enterarse y no enterarse. Pura: se prueba sin planta.
# $ncus: @(@{ncu; hsus}); $halladas: @(@{ncu}). Devuelve @{texto; faltan; sobran}
# El esclavo Modbus de UNA HSU concreta. La topologia trae la lista de esclavos
# de esa NCU (la NCU15 de Ayora lleva dos, 230 y 231) y aqui se coge el que
# toca por ORDEN DE APARICION en esa NCU: la primera que sale, el primero.
#
# Ojo con el numero del hueco: NO es un indice dentro de la NCU. El hueco de la
# cache va con la numeracion de la planta entera -en Ayora la NCU15 tiene sus
# dos estaciones en los huecos 8 y 9, y la NCU16 la suya en el 10-, asi que
# usarlo como indice se salia de la lista y las dos de la NCU15 acababan con el
# mismo esclavo. Pura.
function Hsu-EsclavoDe($ncu, [int]$indice) {
    $lst = @($ncu.hsuLista | Where-Object { "$_" -match '^\d+$' })
    if ($lst.Count -eq 0) { return $ncu.hsu }
    if ($indice -ge 0 -and $indice -lt $lst.Count) { return [int]$lst[$indice] }
    return [int]$lst[0]
}

# Las HSUs que la topologia dice que hay y la cache de la NCU no trae. Igual
# que con las TCUs: no aparecer no es informacion, hay que verlas en la tabla
# diciendo que no comunican. Pura: se prueba sin planta.
function Hsu-Faltantes($ncu, [int]$halladas, [string]$motivo = '') {
    $esperadas = [int]$ncu.hsus
    $r = @()
    if ($esperadas -le $halladas) { return $r }
    for ($i = $halladas; $i -lt $esperadas; $i++) {
        $r += ,@{
            etiqueta = ($(if ($ncu.ncu) { "NCU$($ncu.ncu) - " } else { '' }) + "HSU?")
            salud = 'OFFLINE'
            texto = $(if ($motivo) { $motivo } else { "la NCU no la tiene en su cache: nunca ha comunicado con ella" }) +
                    " (la topologia dice que esta NCU lleva $esperadas)"
        }
    }
    return $r
}

function Hsu-Cuadre($ncus, $halladas) {
    $esperadas = 0; $porNcu = @{}
    foreach ($n in @($ncus)) {
        $k = "$($n.ncu)"
        $e = [int]$n.hsus
        if ($e -le 0) { continue }
        $porNcu[$k] = @{esperadas=$e; halladas=0}
        $esperadas += $e
    }
    foreach ($h in @($halladas)) {
        $k = "$($h.ncu)"
        if (-not $porNcu.ContainsKey($k)) { $porNcu[$k] = @{esperadas=0; halladas=0} }
        $porNcu[$k].halladas++
    }
    if ($esperadas -eq 0) { return @{texto=''; faltan=@(); sobran=@(); esperadas=0} }
    $faltan = @(); $sobran = @()
    foreach ($k in @($porNcu.Keys | Sort-Object { [int]("0" + "$_") })) {
        $d = $porNcu[$k].halladas - $porNcu[$k].esperadas
        $eti = $(if ($k -ne '') { "NCU$k" } else { 'la entrada' })
        if ($d -lt 0) { $faltan += "$eti ($($porNcu[$k].halladas) de $($porNcu[$k].esperadas))" }
        elseif ($d -gt 0) { $sobran += "$eti ($($porNcu[$k].halladas), la topologia dice $($porNcu[$k].esperadas))" }
    }
    $t = ''
    if ($faltan.Count -gt 0) { $t = "FALTAN HSUs: la topologia espera $esperadas y no salen todas en " + ($faltan -join ', ') + ". O no estan dadas de alta en esa NCU, o no comunican." }
    elseif ($sobran.Count -gt 0) { $t = "Hay mas HSUs de las que dice la topologia en " + ($sobran -join ', ') + ". Actualiza la columna RSU del Excel maestro." }
    else { $t = "Las $esperadas HSUs que dice la topologia estan todas." }
    return @{texto=$t; faltan=$faltan; sobran=$sobran; esperadas=$esperadas}
}

function Aud-Indice($lectura) {
    $m = @{}
    foreach ($f in @($lectura)) {
        foreach ($pr in $f.PSObject.Properties) {
            if (@('NCU','TCU','Estado') -contains $pr.Name) { continue }
            $v = "$($pr.Value)".Trim()
            if ($v -eq '' -or $v -eq '-') { continue }
            $m["$($f.NCU)|$($f.TCU)|$($pr.Name)"] = $v
        }
    }
    return $m
}
# Compara el valor del preset con el leido. Normaliza lo que no es diferencia
# real: mayusculas del hexadecimal y coma/punto decimal. Pura.
function Aud-Igual([string]$esperado, [string]$leido) {
    $a = "$esperado".Trim(); $b = "$leido".Trim()
    if ($a -eq $b) { return $true }
    if ($a.StartsWith('0x') -or $b.StartsWith('0x')) { return ($a.ToLower() -eq $b.ToLower()) }
    $x = 0.0; $y = 0.0
    if ([double]::TryParse($a.Replace(',', '.'), [Globalization.NumberStyles]::Float, $INV, [ref]$x) -and
        [double]::TryParse($b.Replace(',', '.'), [Globalization.NumberStyles]::Float, $INV, [ref]$y)) {
        return ([Math]::Abs($x - $y) -lt 0.0000001)
    }
    return $false
}

# El resumen mezclaba dos unidades sin decirlo: "1 con desviaciones" son TCUs y
# "5 filas listadas" son variables, y ademas entre esas filas puede no haber
# ninguna desviacion (las de "sin respuesta" tambien se listan). Leido seguido
# parece que se contradice: "0 con desviaciones. 5 filas listadas."
# Aqui se dice de que son las filas. Pura: se prueba sin planta.
function Aud-Resumen($filas, [int]$tcusOk, [int]$tcusDesv, [int]$tcusErr, [int]$tcusMixtas = 0) {
    $todas = @($filas)
    $nDesv = @($todas | Where-Object { "$($_.Nota)" -like 'DESVIACION*' }).Count
    $nSin  = @($todas | Where-Object { "$($_.Nota)" -eq 'sin respuesta' }).Count
    $eq = { param($n) $(if ($n -eq 1) { 'TCU' } else { 'TCUs' }) }
    $t = "Auditoria: $tcusOk $(& $eq $tcusOk) conformes | $tcusDesv $(& $eq $tcusDesv) con desviaciones | $tcusErr $(& $eq $tcusErr) sin respuesta"
    # las tres cuentas son de TCUs distintas; las mixtas van en "sin
    # respuesta" y sin decirlo no cuadraban con las desviaciones de la tabla
    if ($tcusMixtas -gt 0) { $t += " (de esas, $tcusMixtas con desviaciones ademas)" }
    $t += "."
    if ($todas.Count -eq 0) { return $t }
    $partes = @()
    if ($nDesv -gt 0) { $partes += "$nDesv $(if ($nDesv -eq 1) { 'desviacion' } else { 'desviaciones' })" }
    if ($nSin -gt 0) { $partes += "$nSin sin respuesta" }
    $otras = $todas.Count - $nDesv - $nSin
    if ($otras -gt 0) { $partes += "$otras mas" }
    $nf = $todas.Count
    return "$t En la tabla: $nf $(if ($nf -eq 1) { 'fila' } else { 'filas' }) ($($partes -join ' y ')), una por variable."
}

# Prepara la escritura de las TCUs que la auditoria ha dejado con desviaciones.
# Pura la parte que importa: de que TCUs hablamos. Se prueba sin ventana.
# Las lineas de un CSV por TCU con el preset para las TCUs que hay que tocar.
# El rango de Escribir va de la primera a la ultima y se lleva por delante las
# buenas de en medio; con esto se escribe SOLO en las que fallaron. Pura.
function Aud-ConDesviacion($filas) {
    $r = @{}
    foreach ($f in @($filas)) {
        if ("$($f.Nota)" -notlike 'DESVIACION*') { continue }
        if ("$($f.TCU)" -notmatch '^\d+$') { continue }
        $r["$($f.NCU)|$([int]$f.TCU)"] = @{ncu="$($f.NCU)"; tcu=[int]$f.TCU}
    }
    return @($r.Values | Sort-Object { [int]("0" + "$($_.ncu)") }, { [int]$_.tcu })
}

# ---------------------------------------------------------------------------
#  Cierre post-actualizacion (interfaz)
# ---------------------------------------------------------------------------
function Cierre-Pintar {
    $lvC.BeginUpdate(); $lvC.Items.Clear()
    foreach ($f in @($script:Cierre.Values | Sort-Object { [int]("0" + "$($_.ncu)") }, { [int]$_.tcu })) {
        $est = Cierre-Estado $f
        $item = New-Object System.Windows.Forms.ListViewItem("$($f.ncu)")
        foreach ($c in @($f.tcu, $f.fw, $(if ($f.params) { $f.params } else { '-' }), $(if ($f.nvm) { $f.nvm } else { '-' }),
                         $(if ($f.modo) { $f.modo } else { '-' }), $f.desde, $est)) { [void]$item.SubItems.Add("$c") }
        $item.ForeColor = $(if ($est -eq 'CERRADA') { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkOrange })
        $lvC.Items.Add($item) | Out-Null
    }
    $lvC.EndUpdate()
    $pend = @(Cierre-Pendientes).Count
    $lblCRes.Text = "$($script:Cierre.Count) actualizadas | $pend sin cerrar"
    $tabC.Text = $(if ($pend -gt 0) { "Cierre ($pend)" } else { 'Cierre' })
}

# Aviso de pendientes: se dice una vez por sesion y cada vez que cambia la
# lista. Es lo que sustituye a acordarse.
function Cierre-Avisar {
    $p = @(Cierre-Pendientes)
    if ($p.Count -eq 0) { return }
    $q = @($p | Select-Object -First 12 | ForEach-Object { "NCU$($_.ncu) TCU $($_.tcu)" })
    Con "PENDIENTES DE CIERRE: $($p.Count) TCUs actualizadas sin terminar ($(($q) -join ', ')$(if ($p.Count -gt 12) { ' y mas' })). Mira la pestana Cierre." ([System.Drawing.Color]::Orange)
}

$btnCRef.Add_Click({ Cierre-Pintar; Cierre-Avisar })

$btnCAdd.Add_Click({
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Anadir TCUs a la lista de cierre'
    $d.Size = New-Object System.Drawing.Size(440, 230)
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterScreen'
    [void](LG $d 'NCU' 15 60 20);  $tN = TG $d '' 90 18 60
    [void](LG $d 'TCUs' 15 60 50); $tT = TG $d '' 90 48 290
    $lblA = LG $d 'Una o varias: 26  |  26,39  |  11-14,20' 90 290 74
    $lblA.ForeColor = [System.Drawing.Color]::Gray
    [void](LG $d 'Firmware' 15 70 104); $tF = TG $d "$($txtFwObj.Text)" 90 102 290
    $lblB = LG $d 'Solo para verlo en la lista: no se comprueba nada.' 90 290 128
    $lblB.ForeColor = [System.Drawing.Color]::Gray
    $bOk = New-Object System.Windows.Forms.Button
    $bOk.Text = 'Anadir'; $bOk.Location = New-Object System.Drawing.Point(200, 152); $bOk.Size = New-Object System.Drawing.Size(85, 28)
    $bCa = New-Object System.Windows.Forms.Button
    $bCa.Text = 'Cancelar'; $bCa.Location = New-Object System.Drawing.Point(295, 152); $bCa.Size = New-Object System.Drawing.Size(85, 28)
    $bCa.DialogResult = 'Cancel'
    $d.Controls.Add($bOk); $d.Controls.Add($bCa); $d.AcceptButton = $bOk; $d.CancelButton = $bCa
    # la salida va en una hashtable capturada: con GetNewClosure un $script: de
    # dentro no es el de fuera (la trampa de la v8.0)
    $sal = @{ ncu = ''; tcus = @(); fw = '' }
    $bOk.Add_Click({
        $ncu = $tN.Text.Trim()
        if ($ncu -eq '') { [void][System.Windows.Forms.MessageBox]::Show('Pon la NCU: la lista de cierre es por NCU y TCU.','Aviso'); return }
        $lista = $null
        try { $lista = Parse-ListaNums $tT.Text } catch { [void][System.Windows.Forms.MessageBox]::Show("$_",'Aviso'); return }
        if ($null -eq $lista -or @($lista).Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Pon al menos una TCU (26, o 26,39, o 11-14).','Aviso'); return }
        $sal.ncu = $ncu; $sal.tcus = @($lista); $sal.fw = $tF.Text.Trim()
        $d.DialogResult = 'OK'; $d.Close()
    }.GetNewClosure())
    if ($d.ShowDialog() -ne 'OK') { return }
    $nuevas = 0; $ya = 0
    foreach ($t in @($sal.tcus)) {
        if ($script:Cierre.ContainsKey("$($sal.ncu)|$t")) { $ya++ } else { $nuevas++ }
        Cierre-Marcar $sal.ncu ([int]$t) '' '' $sal.fw
    }
    Cierre-Guardar (Nombre-Planta); Cierre-Pintar
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Cierre: $nuevas TCUs anadidas a mano de NCU$($sal.ncu)$(if ($ya -gt 0) { " ($ya ya estaban)" })." ([System.Drawing.Color]::SteelBlue)
    Con '  Les faltan parametros, NVM y modo AUTO. Se van marcando solas al auditar, guardar en NVM y diagnosticar.' ([System.Drawing.Color]::Gainsboro)
})

$btnCQuitar.Add_Click({
    if ($lvC.SelectedItems.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Marca en la tabla las TCUs que quieras quitar.','Aviso'); return }
    $n = 0
    foreach ($it in @($lvC.SelectedItems)) { if ($script:Cierre.Remove("$($it.Text)|$($it.SubItems[1].Text)")) { $n++ } }
    Cierre-Guardar (Nombre-Planta); Cierre-Pintar
    Con "Quitadas $n TCUs de la lista de cierre." ([System.Drawing.Color]::Gainsboro)
})

$btnCCsv.Add_Click({
    if ($script:Cierre.Count -eq 0) { return }
    $filas = @($script:Cierre.Values | Sort-Object { [int]("0" + "$($_.ncu)") }, { [int]$_.tcu } | ForEach-Object {
        [pscustomobject]@{NCU=$_.ncu; TCU=$_.tcu; Firmware=$_.fw; Parametros=$_.params; NVM=$_.nvm; Modo=$_.modo; Desde=$_.desde; Estado=(Cierre-Estado $_)}
    })
    [void](Exportar-Csv $filas ('cierre_' + (Planta-Fichero)) 'CSV de cierre')
})

# PREPARAR: esta pestana no escribe. Deja Escribir cargado con el preset y las
# TCUs que faltan, y te lleva alli para que pulses tu.
$btnCPrep.Add_Click({
    $falta = @(Cierre-Pendientes | Where-Object { "$($_.params)" -ne 'OK' })
    if ($falta.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('No hay ninguna TCU pendiente de parametros.','Cierre'); return }
    if (-not $script:PresetRef -or @($script:PresetRef).Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("Carga primero el preset de referencia en la pestana Auditoria: es el que dice que hay que escribir.",'Falta el preset','OK','Information'); return
    }
    $pares = @($script:PresetRef | ForEach-Object { [pscustomobject]@{variable=$_.nombre; valor=$_.texto} })
    $n = Cargar-FilasEnGrid $pares
    $ncus = @(@($falta | ForEach-Object { "$($_.ncu)" }) | Sort-Object -Unique)
    $tcus = @($falta | ForEach-Object { [int]$_.tcu } | Sort-Object -Unique)
    $txtWTcus.Text = (Sel-Texto $falta)
    $tabs.SelectedTab = $tabW
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Preparado para escribir: $n variables del preset '$($script:PresetRefNombre)' y las TCUs exactas ($($txtWTcus.Text))." ([System.Drawing.Color]::SteelBlue)
    Con "  Faltan parametros en $($falta.Count) TCUs de $($ncus.Count) NCU(s): $(@($falta | ForEach-Object { "NCU$($_.ncu) TCU $($_.tcu)" }) -join ', ')" ([System.Drawing.Color]::Orange)
    if ($ncus.Count -gt 1) { Con "  Son de varias NCUs: elige (Planta completa) arriba para que cada una vaya a la suya." ([System.Drawing.Color]::Orange) }
    Con "  Pulsa SIMULAR para ver que cambiaria, y luego ESCRIBIR. Al terminar, GUARDAR EN NVM." ([System.Drawing.Color]::Gainsboro)
})

$btnCModo.Add_Click({
    $falta = @(Cierre-Pendientes | Where-Object { "$($_.modo)" -ne 'OK' })
    if ($falta.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('No hay ninguna TCU pendiente de volver a AUTO.','Cierre'); return }
    $txtPTcus.Text = (Sel-Texto $falta)
    $cbPModo.SelectedItem = 'AUTO'
    $tabs.SelectedTab = $tabP
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Preparado el modo: las TCUs exactas ($($txtPTcus.Text)) y modo AUTO. Pulsa APLICAR MODO." ([System.Drawing.Color]::SteelBlue)
    Con "  Sin AUTO en $($falta.Count) TCUs: $(@($falta | ForEach-Object { "NCU$($_.ncu) TCU $($_.tcu)" }) -join ', ')" ([System.Drawing.Color]::Orange)
})

# ------------------------- AUDITORIA GOLDEN PRESET -------------------------
$btnPresetRef.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Preset o backup (*.json)|*.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    try { $obj = Get-Content $dlg.FileName -Raw | ConvertFrom-Json }
    catch { [void][System.Windows.Forms.MessageBox]::Show("No se pudo leer: $_",'Error'); return }
    $pares = @()
    if ($obj.tipo -eq 'backup_tcu') { $pares = @($obj.variables) } else { $pares = @($obj) }
    $ref = @(); $nIdentRef = 0
    foreach ($e in $pares) {
        $nombre = [string]$e.variable
        if (-not $VARIABLES.Contains($nombre)) { continue }
        $def = $VARIABLES[$nombre]
        if ($ADDR_COMANDO -contains $def.addr) { continue }
        if ($ADDR_TIEMPO -contains $def.addr) { continue }
        # la identidad de red es distinta en cada TCU: auditarla daria una
        # desviacion en todas menos en la del propio preset
        if ($ADDR_IDENTIDAD -contains $def.addr) { $nIdentRef++; continue }
        if ("$($e.valor)" -eq '') { continue }
        $sosp = Rango-Sospechoso $nombre "$($e.valor)"
        if ($sosp) { Con "AVISO preset ref: '$nombre' = $($e.valor) $sosp. Si el preset esta mal, la auditoria dara por buenas las TCUs malas." ([System.Drawing.Color]::Orange) }
        try { $ref += @{nombre=$nombre; texto="$($e.valor)"; esc=(Valor-A-Escritura $def "$($e.valor)")} }
        catch { Con "AVISO preset ref: '$nombre' valor '$($e.valor)' invalido - fuera de la auditoria" ([System.Drawing.Color]::Orange) }
    }
    if ($ref.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('El fichero no tiene variables de configuracion utilizables.','Error'); return }
    $script:PresetRef = $ref
    $script:PresetRefNombre = [System.IO.Path]::GetFileName($dlg.FileName)
    $lblPresetRef.Text = "$($script:PresetRefNombre)  ($($ref.Count) variables)"
    Con "Preset de referencia cargado: $($script:PresetRefNombre) con $($ref.Count) variables" ([System.Drawing.Color]::SteelBlue)
    if ($nIdentRef -gt 0) { Con "  fuera de la auditoria $nIdentRef registros de identidad de red: son distintos en cada TCU por definicion" ([System.Drawing.Color]::Orange) }
})

$btnAudLeer.Add_Click({
    if (-not $script:PresetRef -or @($script:PresetRef).Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Carga primero un preset de referencia: es el que dice que variables hay que leer.','Falta el preset','OK','Information'); return
    }
    $dgvL.Rows.Clear()
    $n = 0
    foreach ($v in @($script:PresetRef)) {
        $nom = "$($v.nombre)"
        if (-not $VARIABLES.Contains($nom)) { continue }
        if (-not $colLVar.Items.Contains($nom)) { [void]$colLVar.Items.Add($nom) }
        [void]$dgvL.Rows.Add($nom, (Info-Lectura $nom))
        $n++
    }
    $txtLTcus.Text = $txtATcus.Text
    $tabs.SelectedTab = $tabL
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Preparada la lectura: $n variables de '$($script:PresetRefNombre)' y el rango de la auditoria." ([System.Drawing.Color]::SteelBlue)
    Con "  Pulsa LEER. Al terminar vuelve a Auditoria con 'Usar la ultima lectura' marcado: comparara contra esos datos sin volver a leer la planta." ([System.Drawing.Color]::Gainsboro)
})

$btnAudEscr.Add_Click({
    $malas = @(Aud-ConDesviacion $script:UltimaAud)
    if ($malas.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('La ultima auditoria no dejo ninguna TCU con desviaciones.','Auditoria'); return }
    if (-not $script:PresetRef -or @($script:PresetRef).Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Carga primero el preset de referencia: es el que dice que hay que escribir.','Falta el preset','OK','Information'); return
    }
    $pares = @($script:PresetRef | ForEach-Object { [pscustomobject]@{variable=$_.nombre; valor=$_.texto} })
    $n = Cargar-FilasEnGrid $pares
    $ncus = @(@($malas | ForEach-Object { "$($_.ncu)" }) | Sort-Object -Unique)
    # Antes aqui habia que elegir entre un rango -que se llevaba por delante las
    # TCUs buenas de en medio- y dejar un CSV. El cuadro TCUs dice exactamente
    # cuales son, aunque sean de varias NCUs, asi que ya no hay que elegir.
    $txtWTcus.Text = (Sel-Texto $malas)
    $tabs.SelectedTab = $tabW
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Preparado el preset '$($script:PresetRefNombre)' ($n variables) para las $($malas.Count) TCUs con desviaciones." ([System.Drawing.Color]::SteelBlue)
    Con "  $(@($malas | Select-Object -First 25 | ForEach-Object { "NCU$($_.ncu) TCU $($_.tcu)" }) -join ', ')$(if ($malas.Count -gt 25) { ' y mas' })" ([System.Drawing.Color]::Orange)
    Con "  Puestas en TCUs: $($txtWTcus.Text)  -  solo esas, ninguna mas. Pulsa SIMULAR y luego ESCRIBIR." ([System.Drawing.Color]::Gainsboro)
    if ($ncus.Count -gt 1) { Con "  Son de varias NCUs: elige (Planta completa) arriba para que cada una vaya a la suya." ([System.Drawing.Color]::Orange) }
    Con "  Al terminar, GUARDAR EN NVM." ([System.Drawing.Color]::Gainsboro)
})

$btnAud.Add_Click({ Lanzar {
    if (-not $script:PresetRef) { [void][System.Windows.Forms.MessageBox]::Show('Carga primero un preset de referencia (o un backup completo).','Aviso'); return }
    $cx = Params-Conexion
    $trabajos = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtATcus.Text 'Auditoria') $txtGw.Text)
    if ($trabajos.Count -eq 0) { Con 'La planta no tiene NCUs con gateways definidos.' ([System.Drawing.Color]::Orange); return }
    $lvA.Items.Clear(); $script:UltimaAud = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    if ($cx.multi) {
        $totTcus = 0; foreach ($tr in $trabajos) { $totTcus += @($tr.tcus).Count }
        Con "Auditoria de Planta completa: $($trabajos.Count) NCUs, $totTcus TCUs contra '$($script:PresetRefNombre)' ($($script:PresetRef.Count) variables)" ([System.Drawing.Color]::SteelBlue)
    } else {
        Con "Auditoria de $(Eti-Rango @($trabajos).tcus) contra '$($script:PresetRefNombre)' ($($script:PresetRef.Count) variables)  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    }
    $nOk = 0; $nTcusOk = 0; $nDesv = 0; $nErr = 0; $nFalsas = 0; $nCache = 0; $nMixtas = 0
    $nAudTot = 0; foreach ($tr in $trabajos) { $nAudTot += @($tr.tcus).Count }
    Prog-Iniciar ($nAudTot * @($script:PresetRef).Count)
    # Lo ya leido en esta sesion no se vuelve a pedir: antes, venir de un
    # barrido y auditar era recorrer la planta dos veces para lo mismo.
    $idxLec = @{}
    if ($chkAudLec.Checked) { $idxLec = Aud-Indice $script:UltimaLectura }
    foreach ($tr in $trabajos) {
        $script:NcuLog = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
    if ($script:Cancelar) { break }
    $etNcu = ''
    if ($null -ne $tr.ncu) {
        $etNcu = "$($tr.ncu)"
        Con ("--- NCU{0}  ({1})  TCUs {2}-{3} ---" -f $tr.ncu, $tr.ip, $tr.tcus[0], $tr.tcus[-1]) ([System.Drawing.Color]::SteelBlue)
    }
    $segs = @(Plan-Segmentos $tr.tcus $tr.cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true
        try { Modbus-Conectar $tr.ip $seg.puerto $tr.cx.to }
        catch { $segOk = $false; Con "ERROR de conexion ($($tr.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $desvTcu = 0; $errTcu = 0
            foreach ($refv in $script:PresetRef) {
                if ($script:Cancelar) { break }
                $cmp = $null
                # 1) si esa TCU y esa variable ya se leyeron, se usa aquello
                $kLec = "$etNcu|$tcu|$($refv.nombre)"
                if ($idxLec.ContainsKey($kLec)) {
                    $nCache++
                    if (Aud-Igual $refv.texto $idxLec[$kLec]) { $nOk++; continue }
                    $desvTcu++
                    $leidoC = $idxLec[$kLec]
                    $sospC = Rango-Sospechoso $refv.nombre $leidoC
                    $notaC = $(if ($sospC) { "DESVIACION - $sospC" } else { 'DESVIACION' })
                    $script:UltimaAud += [pscustomobject]@{NCU=$etNcu; TCU=[int]$tcu; Variable=$refv.nombre; Esperado=$refv.texto; Leido=$leidoC; Nota=$notaC}
                    $itemC = New-Object System.Windows.Forms.ListViewItem($etNcu)
                    [void]$itemC.SubItems.Add("$tcu"); [void]$itemC.SubItems.Add($refv.nombre); [void]$itemC.SubItems.Add($refv.texto); [void]$itemC.SubItems.Add($leidoC); [void]$itemC.SubItems.Add($notaC)
                    $itemC.ForeColor = $(if ($sospC) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DarkOrange })
                    $lvA.Items.Add($itemC) | Out-Null
                    continue
                }
                if ($segOk) {
                    for ($i = 1; $i -le $tr.cx.reint -and $null -eq $cmp; $i++) {
                        try { $cmp = Comparar-Escritura $tcu $refv.esc }
                        catch {
                            if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                            Start-Sleep -Milliseconds 150
                        }
                    }
                }
                if ($null -eq $cmp) {
                    $errTcu++
                    $script:UltimaAud += [pscustomobject]@{NCU=$etNcu; TCU=[int]$tcu; Variable=$refv.nombre; Esperado=$refv.texto; Leido=''; Nota='sin respuesta'}
                    $item = New-Object System.Windows.Forms.ListViewItem($etNcu)
                    [void]$item.SubItems.Add("$tcu"); [void]$item.SubItems.Add($refv.nombre); [void]$item.SubItems.Add($refv.texto); [void]$item.SubItems.Add('-'); [void]$item.SubItems.Add('sin respuesta')
                    $item.ForeColor = [System.Drawing.Color]::Gray
                    $lvA.Items.Add($item) | Out-Null
                } elseif (-not $cmp.ok) {
                    $leidoDec = ''
                    try { $leidoDec = Leer-Decodificado $tcu $VARIABLES[$refv.nombre] } catch { $leidoDec = "raw $($cmp.leidoRaw)" }
                    # La comparacion cruda puede fallar por una respuesta
                    # descolocada. Si al releer el valor coincide con el preset,
                    # no habia desviacion: la mala era la primera lectura. Sin
                    # esto salian filas absurdas de "esperado -10, leido -10,
                    # DESVIACION", que es como se descubrio.
                    if (Aud-Igual $refv.texto $leidoDec) {
                        $nFalsas++
                        Con ((Eti-Tcu $tcu) + "  $($refv.nombre): la primera lectura no cuadraba pero al releer da $leidoDec, que es el valor del preset: descolocacion, no desviacion") ([System.Drawing.Color]::Orange)
                        $nOk++
                        continue
                    }
                    $desvTcu++
                    # no solo distinto del preset: ademas puede ser imposible
                    $sosp = Rango-Sospechoso $refv.nombre $leidoDec
                    $nota = $(if ($sosp) { "DESVIACION - $sosp" } else { 'DESVIACION' })
                    $script:UltimaAud += [pscustomobject]@{NCU=$etNcu; TCU=[int]$tcu; Variable=$refv.nombre; Esperado=$refv.texto; Leido=$leidoDec; Nota=$nota}
                    $item = New-Object System.Windows.Forms.ListViewItem($etNcu)
                    [void]$item.SubItems.Add("$tcu"); [void]$item.SubItems.Add($refv.nombre); [void]$item.SubItems.Add($refv.texto); [void]$item.SubItems.Add($leidoDec); [void]$item.SubItems.Add($nota)
                    $item.ForeColor = $(if ($sosp) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DarkOrange })
                    $lvA.Items.Add($item) | Out-Null
                }
            }
            if ($errTcu -eq 0) { Cierre-MarcarSiEsta $etNcu ([int]$tcu) 'params' $(if ($desvTcu -eq 0) { 'OK' } else { 'NOK' }) }
            # Una TCU puede tener desviaciones Y variables sin respuesta a la vez.
            # Antes contaba solo como "sin respuesta" y su linea no se imprimia,
            # pero sus filas de DESVIACION si estaban en la tabla: el resumen
            # decia "3 TCUs con desviaciones" con 6 desviaciones listadas.
            if ($errTcu -gt 0) { $nErr++; if ($desvTcu -gt 0) { $nMixtas++ } }
            elseif ($desvTcu -gt 0) { $nDesv++ }
            else { $nTcusOk++ }
            if ($desvTcu -gt 0) {
                Con ("{0}TCU {1,3}  {2} desviaciones{3}" -f $(if ($etNcu) { "NCU$etNcu " } else { '' }), $tcu, $desvTcu,
                     $(if ($errTcu -gt 0) { " (y $errTcu variables sin respuesta)" } else { '' })) ([System.Drawing.Color]::Orange)
            }
            Prog-Paso @($script:PresetRef).Count
            # alimenta la tarea "Configuracion TCU" del seguimiento PEM
            $script:SegAud["$etNcu|$tcu"] = @{ncu=$etNcu; tcu=[int]$tcu
                estado=$(if ($errTcu -gt 0) { '' } elseif ($desvTcu -gt 0) { 'NOK' } else { 'OK' })
                obs=$(if ($errTcu -gt 0) { "sin respuesta en $errTcu variables" } elseif ($desvTcu -gt 0) { "$desvTcu desviaciones vs '$($script:PresetRefNombre)'" } else { '' })}
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    }
    Modbus-Cerrar
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    Cierre-Guardar (Nombre-Planta); Cierre-Pintar
    Con (Aud-Resumen $script:UltimaAud $nTcusOk $nDesv $nErr $nMixtas) ([System.Drawing.Color]::SteelBlue)
    if ($nCache -gt 0) { Con "  $nCache valores salieron de la ultima lectura, sin volver a preguntar a la planta." ([System.Drawing.Color]::Gainsboro) }
    if ($nFalsas -gt 0) { Con "  $nFalsas comparaciones fallaron y al releer daban el valor bueno: eran respuestas descolocadas de la NCU, no desviaciones. NO estan en la tabla ni cuentan como desviacion: la TCU que sale arriba en esas lineas quedo conforme." ([System.Drawing.Color]::Orange) }
    $btnAudEscr.Enabled = (@(Aud-ConDesviacion $script:UltimaAud).Count -gt 0)
    if ($script:UltimaAud.Count -eq 0) {
        Con 'Toda la flota coincide con el preset de referencia.' ([System.Drawing.Color]::LightGreen)
        # La tabla solo lista desviaciones, asi que sin ninguna se queda vacia y
        # parece que la auditoria no ha hecho nada. Se deja dicho ahi mismo.
        $vacio = New-Object System.Windows.Forms.ListViewItem('')
        [void]$vacio.SubItems.Add('')
        [void]$vacio.SubItems.Add($(if ($nTcusOk -gt 0) { "Sin desviaciones: $nTcusOk TCUs conformes" } else { 'No se ha auditado ninguna TCU' }))
        [void]$vacio.SubItems.Add('')
        [void]$vacio.SubItems.Add('')
        [void]$vacio.SubItems.Add($(if ($nTcusOk -gt 0) { "las $($script:PresetRef.Count) variables de '$($script:PresetRefNombre)' coinciden en todas" }
                                    elseif ($script:Cancelar) { 'cancelado antes de leer nada' } else { 'sin respuesta' }))
        $vacio.ForeColor = $(if ($nTcusOk -gt 0) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Gray })
        $lvA.Items.Add($vacio) | Out-Null
    }
    Marcar-Bloque 'aud'
    [void](Trabajo-Guardar 'auditoria' $script:UltimaAud "contra '$($script:PresetRefNombre)': $nDesv desviaciones en $nTcusOk TCUs")
} })

$btnAudCsv.Add_Click({
    [void](Exportar-Csv $script:UltimaAud 'auditoria')
})

# JSON de auditoria para el Historico de la plataforma (solo desviaciones +
# recuento de TCUs auditadas/conformes de la ultima pasada)
$btnAudJson.Add_Click({
    $conformes = @($script:SegAud.Values | Where-Object { $_.estado -eq 'OK' }).Count
    $obj = [ordered]@{
        tipo    = 'auditoria_tcu'
        mapa    = $VERSION_MAPA
        toolbox = $VERSION_TOOLBOX
        planta  = Nombre-Planta
        ip      = $txtIp.Text.Trim()
        fecha   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        preset  = $script:PresetRefNombre
        tcus_auditadas = $script:SegAud.Count
        conformes      = $conformes
        desviaciones   = @($script:UltimaAud)
    }
    if ((Exportar-Json $obj ('auditoria_' + (Planta-Fichero)) 'JSON de auditoria') -ne '') {
        Con "  $($script:SegAud.Count) TCUs, $conformes conformes, $($script:UltimaAud.Count) desviaciones. Subelo en la pagina Historico." ([System.Drawing.Color]::Gainsboro)
    }
})

# ------------------------- INVENTARIO DE FLOTA -------------------------
$btnInvF.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $tcus = $null
    if (-not $cx.multi) { $tcus = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtVTcus.Text 'Inventario') $txtGw.Text).tcus }
    $trabajos = @(Trabajos-Planta $cx $tcus)
    if ($trabajos.Count -eq 0) { Con 'La planta no tiene NCUs con gateways definidos.' ([System.Drawing.Color]::Orange); return }
    $lvV.Items.Clear(); $script:UltimoInv = @(); $lblInvF.Text = ''
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    if ($cx.multi) {
        $totTcus = 0; foreach ($tr in $trabajos) { $totTcus += @($tr.tcus).Count }
        Con "Inventario de Planta completa: $($trabajos.Count) NCUs, $totTcus TCUs (rangos por NCU automaticos)" ([System.Drawing.Color]::SteelBlue)
    } else {
        Con "Inventario de $(Eti-Rango $tcus)  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    }
    $nInvTot = 0; foreach ($tr in $trabajos) { $nInvTot += @($tr.tcus).Count }
    Prog-Iniciar $nInvTot
    $ok = 0; $ko = 0
    foreach ($tr in $trabajos) {
        $script:NcuLog = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
    if ($script:Cancelar) { break }
    $etNcu = ''
    if ($null -ne $tr.ncu) {
        $etNcu = "$($tr.ncu)"
        Con ("--- NCU{0}  ({1})  TCUs {2}-{3} ---" -f $tr.ncu, $tr.ip, $tr.tcus[0], $tr.tcus[-1]) ([System.Drawing.Color]::SteelBlue)
    }
    $segs = @(Plan-Segmentos $tr.tcus $tr.cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true
        try { Modbus-Conectar $tr.ip $seg.puerto $tr.cx.to }
        catch { $segOk = $false; Con "ERROR de conexion ($($tr.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $campos = $null; $err = ''
            if ($segOk) {
                for ($i = 1; $i -le $tr.cx.reint -and $null -eq $campos; $i++) {
                    try { $campos = Ident-Leer $tcu }
                    catch {
                        $err = "$_"
                        if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                        Start-Sleep -Milliseconds (300 * $i)
                    }
                }
            } else { $err = "sin conexion ($($tr.ip):$($seg.puerto))" }
            $item = New-Object System.Windows.Forms.ListViewItem($etNcu)
            [void]$item.SubItems.Add("$tcu")
            if ($null -ne $campos) {
                $h = @{}
                foreach ($c in $campos) { $h[$c.Campo] = $c.Valor }
                foreach ($col in @($h['Numero de serie'], $h['MAC Xbee'], $h['FW principal'], $h['FW de fabrica'], $h['HW PCBA'], $h['Fecha de fabricacion'], '')) {
                    [void]$item.SubItems.Add("$col")
                }
                $ok++
                $script:UltimoInv += [pscustomobject]@{NCU=$etNcu; TCU=[int]$tcu; Serie=$h['Numero de serie']; MAC=$h['MAC Xbee']
                    FW=$h['FW principal']; FW_fabrica=$h['FW de fabrica']; HW=$h['HW PCBA']; Fecha_fab=$h['Fecha de fabricacion']; Nota='OK'}
            } else {
                foreach ($n in 1..6) { [void]$item.SubItems.Add('-') }
                [void]$item.SubItems.Add($err)
                $item.ForeColor = [System.Drawing.Color]::Firebrick
                $ko++
                $script:UltimoInv += [pscustomobject]@{NCU=$etNcu; TCU=[int]$tcu; Serie=''; MAC=''; FW=''; FW_fabrica=''; HW=''; Fecha_fab=''; Nota=$err}
            }
            $lvV.Items.Add($item) | Out-Null
            Prog-Paso
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    }
    Modbus-Cerrar
    $lblInvF.Text = "$ok leidas, $ko sin respuesta"
    $fws = @($script:UltimoInv | Where-Object { $_.FW } | Group-Object FW)
    if ($fws.Count -gt 1) {
        Con "ATENCION: FW mezclados en la flota:" ([System.Drawing.Color]::Orange)
        foreach ($g in $fws) { Con ("   {0}  en {1} TCUs" -f $g.Name, $g.Count) ([System.Drawing.Color]::Orange) }
    }
    Con "Inventario terminado: $ok leidas, $ko sin respuesta" ([System.Drawing.Color]::SteelBlue)
    Marcar-Bloque 'inv'
    [void](Trabajo-Guardar 'inventario' $script:UltimoInv "$ok leidas, $ko sin respuesta")
} })

$btnInvFCsv.Add_Click({
    [void](Exportar-Csv $script:UltimoInv 'inventario')
})

# JSON de inventario para el Historico de la plataforma
$btnInvJson.Add_Click({
    $obj = [ordered]@{
        tipo    = 'inventario_tcu'
        mapa    = $VERSION_MAPA
        toolbox = $VERSION_TOOLBOX
        planta  = Nombre-Planta
        ip      = $txtIp.Text.Trim()
        fecha   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        tcus    = @($script:UltimoInv)
    }
    if ((Exportar-Json $obj ('inventario_' + (Planta-Fichero)) 'JSON de inventario') -ne '') {
        Con "  $($script:UltimoInv.Count) TCUs. Subelo en la pagina Historico." ([System.Drawing.Color]::Gainsboro)
    }
})

# ------------------------- PEM (PUESTA EN MARCHA) -------------------------
function Pem-Fila([string]$tcu, [string]$res, [string]$det, [string]$ncu = '') {
    $item = New-Object System.Windows.Forms.ListViewItem($ncu)
    [void]$item.SubItems.Add("$tcu"); [void]$item.SubItems.Add($res); [void]$item.SubItems.Add($det)
    switch -Wildcard ($res) {
        'PASA*'   { $item.ForeColor = [System.Drawing.Color]::DarkGreen }
        'OK*'     { $item.ForeColor = [System.Drawing.Color]::DarkGreen }
        'FALLA*'  { $item.ForeColor = [System.Drawing.Color]::Firebrick }
        'SALTADO*'{ $item.ForeColor = [System.Drawing.Color]::Gray }
        default   { $item.ForeColor = [System.Drawing.Color]::DarkOrange }
    }
    $lvP.Items.Add($item) | Out-Null
    $script:UltimoPem += [pscustomobject]@{NCU=$ncu; TCU=$tcu; Resultado=$res; Detalle=$det}
    Marcar-Bloque 'pem'
    $pre = $(if ($ncu) { "NCU$ncu " } else { '' })
    if ($res -notlike 'PASA*' -and $res -notlike 'OK*') { Con ("{0}TCU {1,3}  {2}  {3}" -f $pre, $tcu, $res, $det) ([System.Drawing.Color]::Orange) }
    else { Con ("{0}TCU {1,3}  {2}  {3}" -f $pre, $tcu, $res, $det) ([System.Drawing.Color]::LightGreen) }
    [System.Windows.Forms.Application]::DoEvents()
}

# Fija el modo (0 OFF / 1 MANUAL / 2 AUTO) tocando SOLO los bits 9:8 de 40000
# y verifica por efecto en 30001. Devuelve $true si el TCU llego al modo.
function Fijar-Modo([byte]$tcu, [int]$modo) {
    FC22-Mascara $tcu 40000 0xFCFF ($modo -shl 8)
    for ($i = 0; $i -lt 6; $i++) {
        Start-Sleep -Milliseconds 500
        $v = (FC03-Leer $tcu (Dir-Trama 30001) 1)[0]
        if (((($v -shr 8) -band 0x3)) -eq $modo) { return $true }
    }
    return $false
}

function Guardia-Viento([hashtable]$cx) {
    if (-not $chkPViento.Checked) { return $true }
    Con 'Guardia de viento: consultando HSUs via NCU...' ([System.Drawing.Color]::Gainsboro)
    $v = Viento-Seguro $cx.ip $cx.to
    if ($null -eq $v) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "No hay datos de HSU via NCU: no puedo comprobar el viento.`r`nContinuar BAJO TU RESPONSABILIDAD?",
            'Guardia de viento', 'YesNo', 'Warning')
        return ($r -eq 'Yes')
    }
    if ($v.alarma -or $v.nivel -gt 0) {
        Con ("GUARDIA DE VIENTO: nivel {0}{1} - test de movimiento BLOQUEADO." -f $v.nivel, $(if ($v.alarma) { ' con ALARMA DE VIENTO' } else { '' })) ([System.Drawing.Color]::Salmon)
        [void][System.Windows.Forms.MessageBox]::Show("Hay viento (nivel $($v.nivel)). Test de movimiento bloqueado por seguridad.", 'Guardia de viento', 'OK', 'Stop')
        return $false
    }
    Con 'Guardia de viento: nivel 0, sin alarmas - adelante.' ([System.Drawing.Color]::LightGreen)
    return $true
}

$btnPMotor.Add_Click({ Lanzar {
    $cx = Params-Conexion
    if ($cx.multi) { throw 'el test de motor va por NCU: elige una entrada (auto)/GW, no Planta completa' }
    $tcus = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtPTcus.Text 'Test motor') $txtGw.Text).tcus
    $pulso = Val-Int $txtPPulso.Text 'Pulso' 1 30
    $umbral = Parse-RealFinito $txtPUmbral.Text
    if ($umbral -le 0 -or $umbral -gt 10) { throw 'umbral fuera de rango (0-10 deg)' }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "TEST DE MOTOR en $($tcus.Count) TCUs: cada uno pasara a MANUAL, movera OESTE ${pulso}s y ESTE ${pulso}s midiendo angulo y corriente, y volvera a su modo original.`r`n`r`nLos seguidores SE VAN A MOVER. Continuar?",
        'TEST DE MOTOR', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    if (-not (Guardia-Viento $cx)) { return }
    $lvP.Items.Clear(); $script:UltimoPem = @(); $lblPResumen.Text = ''
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "TEST DE MOTOR: $(Eti-Rango $tcus), pulso ${pulso}s, umbral $umbral deg" ([System.Drawing.Color]::SteelBlue)
    $nPasa = 0; $nFalla = 0; $nSalta = 0; $nLim = 0
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { foreach ($tcu in $seg.tcus) { Pem-Fila $tcu 'SALTADO' "sin conexion ($($cx.ip):$($seg.puerto))"; $nSalta++ }; continue }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $modo0 = $null
            try {
                $v0 = FC03-Leer $tcu (Dir-Trama 30001) 3          # 30001..30003: estado + alarmas 1/2
                $modo0 = ($v0[0] -shr 8) -band 0x3
                if ((($v0[1] -band $CRIT_AL1) -ne 0) -or (($v0[2] -band $CRIT_AL2) -ne 0)) {
                    Pem-Fila $tcu 'SALTADO' 'alarma critica activa - resolver antes del test'; $nSalta++; continue
                }
                $t0 = (FC03-Leer $tcu (Dir-Trama 30111) 1)[0]; if ($t0 -gt 32767) { $t0 -= 65536 }
                if (-not (Fijar-Modo $tcu 1)) { Pem-Fila $tcu 'FALLA' 'no entra en modo MANUAL'; $nFalla++; continue }
                # OESTE
                FC16-Escribir $tcu 40017 @(1)
                Start-Sleep -Milliseconds ([int]($pulso * 500))
                $iW = (FC03-Leer $tcu (Dir-Trama 30011) 1)[0]
                Start-Sleep -Milliseconds ([int]($pulso * 500))
                FC16-Escribir $tcu 40017 @(0)
                Start-Sleep -Milliseconds 700
                $tW = (FC03-Leer $tcu (Dir-Trama 30111) 1)[0]; if ($tW -gt 32767) { $tW -= 65536 }
                # ESTE
                FC16-Escribir $tcu 40017 @(2)
                Start-Sleep -Milliseconds ([int]($pulso * 500))
                $iE = (FC03-Leer $tcu (Dir-Trama 30011) 1)[0]
                Start-Sleep -Milliseconds ([int]($pulso * 500))
                FC16-Escribir $tcu 40017 @(0)
                Start-Sleep -Milliseconds 700
                $tE = (FC03-Leer $tcu (Dir-Trama 30111) 1)[0]; if ($tE -gt 32767) { $tE -= 65536 }
                $dW = ($tW - $t0) / 10.0; $dE = ($tE - $tW) / 10.0
                $v = Motor-Veredicto $dW $iW $dE $iE $umbral ($t0 / 10.0)
                Pem-Fila $tcu $v.estado $v.detalle
                switch ($v.estado) {
                    'PASA' { $nPasa++; if ($v.limite) { $nLim++ } }
                    default { $nFalla++ }
                }
            } catch {
                Pem-Fila $tcu 'FALLA' "error durante el test: $_"; $nFalla++
                if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
            } finally {
                try { FC16-Escribir $tcu 40017 @(0) } catch {}     # parada de motor garantizada
                if ($null -ne $modo0) { try { [void](Fijar-Modo $tcu $modo0) } catch {} }
            }
        }
    }
    Modbus-Cerrar
    $colaLim = $(if ($nLim -gt 0) { " ($nLim solo en un sentido, pegadas al limite)" } else { '' })
    $lblPResumen.Text = "PASA $nPasa | FALLA $nFalla | saltados $nSalta"
    Con "TEST DE MOTOR terminado: PASA $nPasa$colaLim | FALLA $nFalla | SALTADOS $nSalta" ([System.Drawing.Color]::SteelBlue)
    if ($nLim -gt 0) { Con "  Las que solo se movieron en un sentido estaban pegadas a su limite de recorrido: el controlador no llega a activar el motor y la corriente se queda en 0. Para probar los dos sentidos, llevalas antes a una posicion mas centrada." ([System.Drawing.Color]::Gainsboro) }
    # alimenta la tarea "Prueba movimiento" del seguimiento PEM
    foreach ($p in $script:UltimoPem) {
        if ($p.Resultado -eq 'SALTADO') { continue }
        $est = switch ($p.Resultado) { 'PASA' { 'OK' } 'FALLA' { 'NOK' } default { '' } }
        $script:SegMotor["$($p.NCU)|$($p.TCU)"] = @{ncu="$($p.NCU)"; tcu=[int]$p.TCU; estado=$est; obs="$($p.Resultado): $($p.Detalle)"}
    }
} })

$btnPModo.Add_Click({ Lanzar {
    $cx = Params-Conexion
    if ($cx.multi) { throw 'el cambio de modo va por NCU: elige una entrada (auto)/GW' }
    $tcus = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtPTcus.Text 'Modo') $txtGw.Text).tcus
    $modo = @{'OFF'=0; 'MANUAL'=1; 'AUTO'=2}[[string]$cbPModo.SelectedItem]
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Pasar $($tcus.Count) TCUs a modo $($cbPModo.SelectedItem)?", 'Cambio de modo', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $lvP.Items.Clear(); $script:UltimoPem = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Cambio de modo a $($cbPModo.SelectedItem) en $(Eti-Rango $tcus)" ([System.Drawing.Color]::SteelBlue)
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { foreach ($tcu in $seg.tcus) { Pem-Fila $tcu 'FALLA' "sin conexion ($($cx.ip):$($seg.puerto))" }; continue }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            try {
                if (Fijar-Modo $tcu $modo) { Pem-Fila $tcu 'OK' "en modo $($cbPModo.SelectedItem)" }
                else { Pem-Fila $tcu 'FALLA' "no confirma el modo (30001)" }
            } catch { Pem-Fila $tcu 'FALLA' "$_"; if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar } }
        }
    }
    Modbus-Cerrar
} })

$btnPClear.Add_Click({ Lanzar {
    $cx = Params-Conexion
    if ($cx.multi) { throw 'elige una entrada (auto)/GW' }
    $tcus = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtPTcus.Text 'Clear') $txtGw.Text).tcus
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Desenclavar alarmas de motor (40007 bit 13) en $($tcus.Count) TCUs?", 'Clear alarmas', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $lvP.Items.Clear(); $script:UltimoPem = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Clear de alarmas enclavadas en $(Eti-Rango $tcus)" ([System.Drawing.Color]::SteelBlue)
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { foreach ($tcu in $seg.tcus) { Pem-Fila $tcu 'FALLA' "sin conexion" }; continue }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            try {
                FC22-Mascara $tcu 40007 0xDFFF 0x2000
                Start-Sleep -Milliseconds 400
                $st = (FC03-Leer $tcu (Dir-Trama 30006) 1)[0]
                if (($st -shr 11) -band 1) { Pem-Fila $tcu 'AVISO' 'la alarma sigue enclavada (revisar causa)' }
                else { Pem-Fila $tcu 'OK' 'sin alarmas de motor enclavadas' }
            } catch { Pem-Fila $tcu 'FALLA' "$_"; if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar } }
        }
    }
    Modbus-Cerrar
} })

function Stow-Aplicar([int]$n) {
    $cx = Params-Conexion
    if ($cx.multi) { throw 'el stow va por NCU: elige una entrada (auto)/GW' }
    $tcus = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtPTcus.Text 'Stow') $txtGw.Text).tcus
    $txtAccion = $(if ($n -gt 0) { "ACTIVAR safe position $n" } else { 'QUITAR el stow' })
    $r = [System.Windows.Forms.MessageBox]::Show(
        "$txtAccion en $($tcus.Count) TCUs? Los seguidores se moveran.", 'Stow', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $lvP.Items.Clear(); $script:UltimoPem = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "$txtAccion en $(Eti-Rango $tcus)" ([System.Drawing.Color]::SteelBlue)
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { foreach ($tcu in $seg.tcus) { Pem-Fila $tcu 'FALLA' "sin conexion" }; continue }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            try {
                FC22-Mascara $tcu 42000 0xFFF8 $n
                Start-Sleep -Milliseconds 800
                $v = (FC03-Leer $tcu (Dir-Trama 30001) 1)[0]
                $activo = ($v -shr 13) -band 0x7
                if ($n -gt 0) {
                    if ($activo -eq $n) { Pem-Fila $tcu 'OK' "safe position $n activa (en movimiento hacia stow)" }
                    else { Pem-Fila $tcu 'AVISO' "solicitada $n pero 30001 marca $activo (puede haber otra fuente de safe pos)" }
                } else {
                    if ($activo -eq 0) { Pem-Fila $tcu 'OK' 'stow retirado' }
                    else { Pem-Fila $tcu 'AVISO' "sigue en safe position $activo (otra fuente: NCU/viento?)" }
                }
            } catch { Pem-Fila $tcu 'FALLA' "$_"; if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar } }
        }
    }
    Modbus-Cerrar
}
$btnPStow.Add_Click({ Lanzar { Stow-Aplicar ([int][string]$cbPStow.SelectedItem) } })
$btnPUnstow.Add_Click({ Lanzar { Stow-Aplicar 0 } })

$btnPComis.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $lvP.Items.Clear(); $script:UltimoPem = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    $cuenta = @{}
    if ($cx.multi) {
        # Planta completa: el estado de comisionado viaja en los bits 4:3 del
        # registro de estado que la NCU cachea (bloque compacto, puerto 502)
        # - toda la planta en segundos, sin rondas Zigbee
        $trabajos = @(Trabajos-Planta $cx $null)
        Con "Comisionado de Planta completa via NCU: $($trabajos.Count) NCUs (bloque compacto, sin Zigbee)" ([System.Drawing.Color]::SteelBlue)
        foreach ($tr in $trabajos) {
            $script:NcuLog = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
            if ($script:Cancelar) { break }
            Con ("--- NCU{0}  ({1})  TCUs {2}-{3} ---" -f $tr.ncu, $tr.ip, $tr.tcus[0], $tr.tcus[-1]) ([System.Drawing.Color]::SteelBlue)
            $dm = $null
            try { Modbus-Conectar $tr.ip $PUERTO_NCU $tr.cx.to; $dm = Ncu-DiagCompat $tr.tcus }
            catch { Con "ERROR via NCU ($($tr.ip):$PUERTO_NCU): $_" ([System.Drawing.Color]::Salmon) }
            Modbus-Cerrar
            foreach ($tcu in $tr.tcus) {
                if (Chequear-Cancelado) { break }
                $d = $null; if ($dm) { $d = $dm[[int]$tcu] }
                if ($null -eq $d) { Pem-Fila $tcu 'FALLA' 'sin datos via NCU' "$($tr.ncu)"; continue }
                if ($d.Salud -eq 'OFFLINE') { Pem-Fila $tcu 'SALTADO' "OFFLINE: $($d.Alarmas)" "$($tr.ncu)"; continue }
                $v = [Convert]::ToInt32($d.main_status, 16)
                $e = Comis-De $v
                $nom = $ESTADOS_COMIS[[int]$e]
                $md = Modo-De $v
                if (-not $cuenta.ContainsKey($nom)) { $cuenta[$nom] = 0 }
                $cuenta[$nom]++
                if (-not $cuenta.ContainsKey("modo $md")) { $cuenta["modo $md"] = 0 }
                $cuenta["modo $md"]++
                Pem-Fila $tcu $(if ($e -eq 0) { 'OK' } else { 'PENDIENTE' }) "$e - $nom  |  modo $md" "$($tr.ncu)"
            }
        }
    } else {
        $tcus = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtPTcus.Text 'Comisionado') $txtGw.Text).tcus
        Con "Estado de comisionado (30001 bits 4:3) y modo (bits 9:8) en $(Eti-Rango $tcus)" ([System.Drawing.Color]::SteelBlue)
        $segs = @(Plan-Segmentos $tcus $cx)
        foreach ($seg in $segs) {
            if ($script:Cancelar) { break }
            try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
            catch { foreach ($tcu in $seg.tcus) { Pem-Fila $tcu 'FALLA' "sin conexion" }; continue }
            foreach ($tcu in $seg.tcus) {
                if (Chequear-Cancelado) { break }
                try {
                    $v = (FC03-Leer $tcu (Dir-Trama 30001) 1)[0]
                    $e = Comis-De $v
                    $nom = $ESTADOS_COMIS[[int]$e]
                    $md = Modo-De $v
                    if (-not $cuenta.ContainsKey($nom)) { $cuenta[$nom] = 0 }
                    $cuenta[$nom]++
                    if (-not $cuenta.ContainsKey("modo $md")) { $cuenta["modo $md"] = 0 }
                    $cuenta["modo $md"]++
                    Pem-Fila $tcu $(if ($e -eq 0) { 'OK' } else { 'PENDIENTE' }) "$e - $nom  |  modo $md"
                } catch { Pem-Fila $tcu 'FALLA' "$_"; if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar } }
            }
        }
    }
    Modbus-Cerrar
    $lblPResumen.Text = (@($cuenta.Keys | ForEach-Object { "$($cuenta[$_]) $_" }) -join ' | ')
    # alimenta la tarea "Cold commissioning" del seguimiento PEM
    foreach ($p in $script:UltimoPem) {
        $est = if ($p.Resultado -eq 'OK') { 'OK' } else { '' }   # pendiente/fallo no marca NOK: falta comisionar
        $script:SegComis["$($p.NCU)|$($p.TCU)"] = @{ncu="$($p.NCU)"; tcu=[int]$p.TCU; estado=$est; obs=$p.Detalle}
    }
} })

$btnPComisSet.Add_Click({ Lanzar {
    $cx = Params-Conexion
    if ($cx.multi) { throw 'elige una entrada (auto)/GW' }
    $tcus = @(Trabajos-Planta $cx $null '' (Parse-Seleccion $txtPTcus.Text 'Comisionado') $txtGw.Text).tcus
    $obj = [int]([string]$cbPComis.SelectedItem).Split(' ')[0]
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Fijar estado de comisionado '$($ESTADOS_COMIS[$obj])' ($obj) en $($tcus.Count) TCUs?`r`nRecuerda GUARDAR EN NVM despues.",
        'Comisionado', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $lvP.Items.Clear(); $script:UltimoPem = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Fijando comisionado=$obj ($($ESTADOS_COMIS[$obj])) en $(Eti-Rango $tcus)" ([System.Drawing.Color]::SteelBlue)
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { foreach ($tcu in $seg.tcus) { Pem-Fila $tcu 'FALLA' "sin conexion" }; continue }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            try {
                FC22-Mascara $tcu 40000 0xFF1F ($obj -shl 5)
                Start-Sleep -Milliseconds 500
                $v = (FC03-Leer $tcu (Dir-Trama 30001) 1)[0]
                $e = ($v -shr 3) -band 0x3
                if ($e -eq $obj) { Pem-Fila $tcu 'OK' "comisionado = $e ($($ESTADOS_COMIS[[int]$e]))" }
                else { Pem-Fila $tcu 'AVISO' "solicitado $obj pero 30001 marca $e" }
            } catch { Pem-Fila $tcu 'FALLA' "$_"; if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar } }
        }
    }
    Modbus-Cerrar
    Con 'Recuerda GUARDAR EN NVM (pestana Escribir) para que el estado sobreviva a un reinicio.' ([System.Drawing.Color]::Orange)
} })

$btnPCsv.Add_Click({
    [void](Exportar-Csv $script:UltimoPem 'pem')
})

# Seguimiento PEM de la sesion: una fila por TCU con las tres tareas de la
# ficha (Cold commissioning = LEER ESTADO de comisionado, Configuracion TCU =
# auditoria contra preset, Prueba movimiento = TEST DE MOTOR). Se sube a la
# plataforma en la pagina de Historico, como los diagnosticos.
$btnPSeg.Add_Click({
    $filas = @(Seguimiento-Filas)
    if ($filas.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Aun no hay datos: ejecuta LEER ESTADO (comisionado), la Auditoria de Flota o el TEST DE MOTOR.','Aviso'); return }
    $obj = [ordered]@{
        tipo    = 'seguimiento_pem'
        mapa    = $VERSION_MAPA
        toolbox = $VERSION_TOOLBOX
        planta  = Nombre-Planta
        ip      = $txtIp.Text.Trim()
        fecha   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        tecnico = "$env:USERNAME"
        tcus    = $filas
    }
    if ((Exportar-Json $obj ('seguimiento_pem_' + (Planta-Fichero)) 'Seguimiento PEM') -ne '') {
        $nOk = @($filas | Where-Object { $_.cold_commissioning -eq 'OK' -and $_.config_tcu -eq 'OK' -and $_.prueba_movimiento -eq 'OK' }).Count
        Con "  $($filas.Count) TCUs, $nOk con las 3 tareas OK. Subelo en la pagina Historico de la plataforma." ([System.Drawing.Color]::Gainsboro)
    }
})

# ------------------------- CAMPANA DE FIRMWARE -------------------------
# La toolbox no actualiza firmware (eso lo hace el TCU Updater de Sunner):
# planifica la campana desde el inventario y verifica el resultado.
$script:PlanFw = @()
$script:PlanFwDetalle = @()
$script:PlanFwVentanas = @()
$btnFwPlan.Add_Click({ Lanzar {
    if (@($script:UltimoInv).Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show("Haz primero un INVENTARIO en la pestana Flota (puede ser de la planta completa).`r`nEl plan se calcula con esos datos, sin volver a leer nada.", 'Falta el inventario')
        return
    }
    $cx = Params-Conexion
    $trabajos = @(Trabajos-Planta $cx $null)
    $gws = @{}; $ips = @{}
    foreach ($tr in $trabajos) {
        $script:NcuLog = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
        $k = $(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })
        $ips[$k] = $tr.ip
        $gws[$k] = $(if ($tr.cx.gws) { $tr.cx.gws } else { @(@{puerto=$tr.cx.puerto; ini=1; fin=247}) })
    }
    $plan = Plan-Firmware $script:UltimoInv $txtFwObj.Text $gws $script:UltimoDiag
    $script:PlanFw = @($plan.tramos)
    $script:PlanFwDetalle = @($plan.detalle)
    $lvFW.Items.Clear()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "PLAN DE FIRMWARE hacia $($txtFwObj.Text.Trim()): $($plan.pendientes) TCUs pendientes, $($plan.al_dia) ya al dia, $(@($plan.sin_respuesta).Count) sin respuesta en el inventario" ([System.Drawing.Color]::SteelBlue)
    # El plan sale por VENTANAS del updater (una por NCU+gateway, y se abren a la
    # vez): cada una dice que rangos pegarle y cuanto tarda, y al final el total.
    # Antes salian los tramos sueltos: con dos pendientes no consecutivas de la
    # misma NCU daba dos filas CARRIL identicas a las dos de TCU y no se veia el
    # plan por ningun lado.
    $minTcu = Val-Int $txtFwMin.Text 'min/TCU' 1 600
    $ventanas = @(Plan-Ventanas $script:PlanFw $ips $minTcu)
    $script:PlanFwVentanas = @($ventanas | ForEach-Object {
        [pscustomobject]@{Ventana=$_.Orden; NCU=$_.NCU; IP=$_.IP; Puerto=$_.Puerto; Rangos=$_.Rangos; TCUs=$_.TCUs
                          Horas=[math]::Round([double]$_.Horas, 1)} })
    $detalle = @($plan.detalle)
    # cuantas de la ventana no van a instalar por bateria, y que TCUs son
    $bajasV = @{}; $detPorV = @{}
    # las que no contestaron al inventario, por NCU: van con SU ventana, no en un
    # bloque al final. Una TCU reiniciandose con el FW nuevo sale muda, y buscarla
    # cincuenta filas mas abajo -detras de las otras quince NCUs- es no verla.
    $mudasPorNcu = @{}
    foreach ($m in @($plan.sin_respuesta)) {
        $k = "$($m.ncu)"
        if (-not $mudasPorNcu.ContainsKey($k)) { $mudasPorNcu[$k] = @() }
        $mudasPorNcu[$k] += ,$m
    }
    $mudasPuestas = @{}
    foreach ($d in $detalle) {
        $kk = "$($d.NCU)|$($d.Puerto)"
        if (-not $detPorV.ContainsKey($kk)) { $detPorV[$kk] = @() }
        $detPorV[$kk] += ,$d
        if ($d.SoC_bajo) { $bajasV[$kk] = 1 + [int]$bajasV[$kk] }
    }
    foreach ($v in $ventanas) {
        $k = "$($v.NCU)|$($v.Puerto)"
        $colaB = $(if ([int]$bajasV[$k] -gt 0) { "  -  $($bajasV[$k]) con bateria baja" } else { '' })
        $marca = $(if ($ventanas.Count -gt 1 -and $v.Orden -eq 1) { ' Es la mas larga: es la que marca el total, arrancala primero.' } else { '' })
        # Desde-Hasta solo si la ventana es UN tramo seguido. Con huecos, poner
        # el primero y el ultimo dibuja un rango que no existe: en la NCU10 con
        # 10-16 y 18-22 salia "de 10 a 22", la TCU 17 parecia estar dentro y
        # abajo no tenia fila porque no esta pendiente. Y ademas el 12 de la
        # columna TCUs no cuadraba con las 13 que van del 10 al 22. Los rangos
        # de verdad van en las filas PEGAR, que con mas de un tramo si salen.
        $unTramo = (@($v.Tramos).Count -eq 1)
        $item = New-Object System.Windows.Forms.ListViewItem("$($v.NCU)")
        foreach ($c in @('VENTANA', $v.IP, $v.Puerto,
                         $(if ($unTramo) { $v.Tramos[0].Desde } else { '(varios)' }),
                         $(if ($unTramo) { $v.Tramos[-1].Hasta } else { '(varios)' }), $v.TCUs,
                         ("Ventana $($v.Orden) de $($ventanas.Count): abrela con esta IP y este puerto. Add from...to: $($v.Rangos). $($v.TCUs) TCUs, ~$(Horas-Texto ([double]$v.Horas)).$marca$colaB$(if (@($mudasPorNcu["$($v.NCU)"]).Count -gt 0 -and $mudasPorNcu.ContainsKey("$($v.NCU)")) { "  -  $(@($mudasPorNcu[""$($v.NCU)""]).Count) sin respuesta, debajo" } else { '' })"))) { [void]$item.SubItems.Add("$c") }
        $item.ForeColor = [System.Drawing.Color]::DarkOrange
        $lvFW.Items.Add($item) | Out-Null
        # los rangos, uno por fila, solo cuando hay mas de uno: con uno solo la
        # fila de la ventana ya lleva ese Desde-Hasta y seria repetirla
        if (@($v.Tramos).Count -gt 1) {
            foreach ($t in $v.Tramos) {
                $itemT = New-Object System.Windows.Forms.ListViewItem("$($v.NCU)")
                foreach ($c in @('PEGAR', $v.IP, $v.Puerto, $t.Desde, $t.Hasta, $t.TCUs, "en la ventana $($v.Orden): Add from $($t.Desde) to $($t.Hasta)")) { [void]$itemT.SubItems.Add("$c") }
                $itemT.ForeColor = [System.Drawing.Color]::SaddleBrown
                $lvFW.Items.Add($itemT) | Out-Null
            }
        }
        # y debajo, los equipos de esa ventana: que version tienen y con que SoC
        foreach ($d in @($detPorV[$k] | Sort-Object { [int]$_.TCU })) {
            $eSoc = $(if ("$($d.SoC)" -ne '') { ", SoC $($d.SoC) %" } else { ', SoC desconocido' })
            $aviso = $(if ($d.SoC_bajo) { " - BATERIA BAJA: por debajo del $SOC_MIN_OTA % el bootloader puede no instalarlo" } else { '' })
            $itemD = New-Object System.Windows.Forms.ListViewItem("$($d.NCU)")
            foreach ($c in @('TCU', $ips["$($d.NCU)"], $d.Puerto, $d.TCU, $d.TCU, 1, "pendiente: tiene $($d.FW), objetivo $($d.Objetivo)$eSoc$aviso")) { [void]$itemD.SubItems.Add("$c") }
            $itemD.ForeColor = $(if ($d.SoC_bajo) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DarkOrange })
            $lvFW.Items.Add($itemD) | Out-Null
        }
        # y las mudas de ESA NCU, aqui mismo
        if ($mudasPorNcu.ContainsKey("$($v.NCU)") -and -not $mudasPuestas.ContainsKey("$($v.NCU)")) {
            $mudasPuestas["$($v.NCU)"] = 1
            foreach ($m in @($mudasPorNcu["$($v.NCU)"])) { $lvFW.Items.Add((Fw-FilaMuda $m $ips)) | Out-Null }
        }
    }
    foreach ($linea in @(Plan-Texto $ventanas $minTcu)) {
        Con $linea $(if ($linea -like 'TOTAL:*') { [System.Drawing.Color]::Orange } elseif ($linea -like 'PLAN:*') { [System.Drawing.Color]::SteelBlue } else { [System.Drawing.Color]::Gainsboro })
    }
    # que equipos faltan y en que version estan: es la pregunta que se hace uno
    # al abrir esta pestana, y el plan por tramos no la contestaba
    if ($detalle.Count -gt 0) {
        Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
        $porVer = @{}
        foreach ($d in $detalle) { $porVer["$($d.FW)"] = 1 + [int]$porVer["$($d.FW)"] }
        Con ("TCUs que NO estan en $($txtFwObj.Text.Trim()): " + (@($porVer.Keys | Sort-Object | ForEach-Object { "$($porVer[$_]) en $_" }) -join ' | ')) ([System.Drawing.Color]::Orange)
        foreach ($d in $detalle) {
            $eSoc = $(if ("$($d.SoC)" -ne '') { ", SoC $($d.SoC) %" } else { ', SoC desconocido' })
            $aviso = $(if ($d.SoC_bajo) { " - BATERIA BAJA: por debajo del $SOC_MIN_OTA % el bootloader puede no instalarlo" } else { '' })
            Con ("  NCU{0,-3} TCU {1,3}   {2}  ->  {3}{4}{5}" -f $d.NCU, $d.TCU, $d.FW, $d.Objetivo, $eSoc, $aviso) $(if ($d.SoC_bajo) { [System.Drawing.Color]::Salmon } else { [System.Drawing.Color]::Orange })
        }
        if ($plan.con_soc_bajo -gt 0) {
            Con "ATENCION: $($plan.con_soc_bajo) de las pendientes estan por debajo del $SOC_MIN_OTA % de bateria. El bootloader solo instala si supera su umbral (42005 soc_min_bootloader y 42006 vbat_min_bootloader), asi que esas se van a quedar como estan aunque el updater diga que ha enviado el firmware. Dejalas cargar y actualizalas en otra pasada." ([System.Drawing.Color]::Salmon)
        }
        if ($plan.sin_soc -gt 0) {
            Con "$($plan.sin_soc) pendientes sin SoC conocido: el plan cruza con el ULTIMO DIAGNOSTICO de esta sesion. Lanza un DIAGNOSTICAR (via NCU es rapido) y vuelve a pulsar PLAN para verlo." ([System.Drawing.Color]::Orange)
        }
    }
    # las de NCUs que no tienen ninguna ventana (todo lo suyo al dia, o mudo)
    foreach ($k in @($mudasPorNcu.Keys | Sort-Object { [int]("0" + "$_") })) {
        if ($mudasPuestas.ContainsKey($k)) { continue }
        foreach ($m in @($mudasPorNcu[$k])) { $lvFW.Items.Add((Fw-FilaMuda $m $ips)) | Out-Null }
    }
    $lblFw.Text = $(if ($ventanas.Count -gt 0) { "$($ventanas.Count) ventana(s) | " } else { '' }) +
                  "$($plan.pendientes) pendientes | $($plan.al_dia) al dia | $(@($plan.sin_respuesta).Count) sin respuesta"
    if ($script:PlanFw.Count -eq 0 -and $plan.al_dia -gt 0) { Con "Toda la flota inventariada ya esta en $($txtFwObj.Text.Trim())." ([System.Drawing.Color]::LightGreen) }
    else { Con 'Abre una ventana del TCU Updater por cada VENTANA del plan (NCU IP + Gateway port + Add from...to) y al terminar pulsa VERIFICAR TRAS ACTUALIZAR.' ([System.Drawing.Color]::Gainsboro) }
    $btnFwCsv.Enabled = ($lvFW.Items.Count -gt 0)
    $btnFwVerif.Enabled = ($script:PlanFw.Count -gt 0)
} })

# Una TCU que no contesto al inventario. No se puede actualizar lo que no
# comunica, pero tiene que verse -y al lado de su NCU-.
function Fw-FilaMuda($m, $ips) {
    $item = New-Object System.Windows.Forms.ListViewItem("$($m.ncu)")
    foreach ($c in @('SIN RESPUESTA', $ips["$($m.ncu)"], '-', $m.tcu, $m.tcu, 1, "sin respuesta en el inventario: $($m.nota)")) { [void]$item.SubItems.Add("$c") }
    $item.ForeColor = [System.Drawing.Color]::Gray
    return $item
}

# Repinta en la tabla del plan la fila (o filas) de una TCU concreta. Hay que
# tocar tambien las guardadas por el filtro de columnas: si el usuario tiene una
# columna filtrada, las que no se ven viven solo ahi.
function Fw-Marcar([string]$ncu, [int]$tcu, [string]$nota, $color) {
    $listas = @(,@($lvFW.Items))
    if ($lvFW.Tag -is [hashtable] -and @($lvFW.Tag.orig).Count -gt 0) { $listas += ,@($lvFW.Tag.orig) }
    foreach ($lista in $listas) {
        foreach ($it in $lista) {
            if ("$($it.Text)" -ne "$ncu") { continue }
            if ($it.SubItems.Count -lt 8) { continue }
            # solo las filas de TCU: la del carril habla de todo el tramo, y con
            # un carril de una sola TCU se le borraba el reparto de horas
            if ("$($it.SubItems[1].Text)" -ne 'TCU') { continue }
            $de = 0; $a = 0
            if (-not [int]::TryParse("$($it.SubItems[4].Text)", [ref]$de)) { continue }
            if (-not [int]::TryParse("$($it.SubItems[5].Text)", [ref]$a)) { continue }
            # solo las filas que son exactamente esa TCU: en un tramo de varias
            # no se puede decir cual de ellas se ha actualizado
            if ($de -ne $tcu -or $a -ne $tcu) { continue }
            $it.SubItems[7].Text = $nota
            $it.ForeColor = $color
        }
    }
}

$btnFwVerif.Add_Click({ Lanzar {
    if ($script:PlanFw.Count -eq 0) { return }
    $cx = Params-Conexion
    $obj = $txtFwObj.Text.Trim()
    $trabajos = @(Trabajos-Planta $cx $null)
    $porNcu = @{}
    foreach ($tr in $trabajos) { $porNcu[$(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })] = $tr }
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Verificando firmware de las TCUs del plan (objetivo $obj)..." ([System.Drawing.Color]::SteelBlue)
    # Con una entrada de una sola NCU, los tramos de las demas no se pueden
    # comprobar. Antes se saltaban en silencio y el resumen decia "0 pendientes"
    # como si estuvieran bien, cuando ni se habian mirado.
    $fuera = @($script:PlanFw | Where-Object { -not $porNcu["$($_.NCU)"] })
    if ($fuera.Count -gt 0) {
        $ncusFuera = @(@($fuera | ForEach-Object { "$($_.NCU)" }) | Sort-Object -Unique)
        Con "AVISO: $($fuera.Count) tramos de las NCUs $($ncusFuera -join ', ') NO se van a verificar: la conexion apunta solo a $(if ($cx.multi) { 'la planta' } else { "$($cx.ip)" }). Selecciona (Planta completa) para verificarlas todas." ([System.Drawing.Color]::Orange)
    }
    $ok = 0; $ko = 0; $err = 0; $saltados = 0
    foreach ($t in $script:PlanFw) {
        if ($script:Cancelar) { break }
        $tr = $porNcu["$($t.NCU)"]
        if (-not $tr) { $saltados += [int]$t.TCUs; continue }
        $tcus = @([int]$t.Desde..[int]$t.Hasta)
        foreach ($seg in @(Plan-Segmentos $tcus $tr.cx)) {
            try { Modbus-Conectar $tr.ip $seg.puerto $tr.cx.to } catch { $err += @($seg.tcus).Count; continue }
            foreach ($tcu in $seg.tcus) {
                if (Chequear-Cancelado) { break }
                $fw = $null
                try {
                    $campos = Ident-Leer $tcu
                    $fw = ($campos | Where-Object { $_.Campo -eq 'FW principal' }).Valor
                } catch {
                    $err++
                    Fw-Marcar "$($t.NCU)" ([int]$tcu) "sin respuesta al verificar: $_" ([System.Drawing.Color]::Gray)
                    continue
                }
                if ("$fw" -like "*$obj*") {
                    $ok++
                    Con ("  NCU{0,-3} TCU {1,3}  ACTUALIZADA -> {2}" -f $t.NCU, $tcu, $fw) ([System.Drawing.Color]::LightGreen)
                    Fw-Marcar "$($t.NCU)" ([int]$tcu) "ACTUALIZADA: ya en $fw" ([System.Drawing.Color]::DarkGreen)
                    # y a la lista de cierre: es el momento en que se sabe que
                    # esta en el firmware nuevo, y con el firmware nuevo llega
                    # todo lo que hay que hacerle despues (parametros, NVM, AUTO)
                    Cierre-Marcar "$($t.NCU)" ([int]$tcu) '' '' "$fw"
                } else {
                    $ko++
                    Con ("  NCU{0,-3} TCU {1,3}  sigue en {2}" -f $t.NCU, $tcu, $fw) ([System.Drawing.Color]::Orange)
                    Fw-Marcar "$($t.NCU)" ([int]$tcu) "SIGUE PENDIENTE: en $fw, objetivo $obj" ([System.Drawing.Color]::Firebrick)
                }
            }
            Modbus-Cerrar
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    Modbus-Cerrar
    $colaS = $(if ($saltados -gt 0) { " | $saltados sin comprobar" } else { '' })
    $lblFw.Text = "Verificacion: $ok en $obj | $ko pendientes | $err sin respuesta$colaS"
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Verificacion: $ok TCUs ya en $obj, $ko siguen pendientes, $err sin respuesta$(if ($saltados -gt 0) { ", $saltados SIN COMPROBAR (de otras NCUs)" })." ([System.Drawing.Color]::SteelBlue)
    if ($saltados -gt 0) { Con "Las $saltados sin comprobar siguen igual que estaban: no cuentan como buenas. Cambia a (Planta completa) y vuelve a verificar." ([System.Drawing.Color]::Orange) }
    if ($ok -gt 0) { Cierre-Guardar (Nombre-Planta); Cierre-Pintar; Cierre-Avisar }
    Con 'Lanza un INVENTARIO nuevo para dejar constancia (y subirlo al Historico).' ([System.Drawing.Color]::Gainsboro)
} })

# Preparar una TCU concreta antes de actualizarla (o de capturar su OTA) en
# una planta EN PRODUCCION: durante la actualizacion la TCU esta en
# bootloader y NO obedece un stow, asi que se comprueba el viento primero.
$btnFwPrep.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $nNcu = "$($txtFwNcu.Text)".Trim()
    $tcu = Val-Int $txtFwTcu.Text 'TCU' 1 247
    $trabajos = @(Trabajos-Planta $cx $null)
    $tr = $trabajos | Where-Object { "$($_.ncu)" -eq $nNcu } | Select-Object -First 1
    if (-not $tr) { $tr = $trabajos[0] }
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "PREPARANDO NCU$nNcu TCU $tcu ($($tr.ip)) para actualizar/capturar" ([System.Drawing.Color]::SteelBlue)
    $problemas = @()

    # 1) viento: durante el OTA la TCU no responde a stow
    $v = $null
    try { $v = Viento-Seguro $tr.ip $tr.cx.to $PUERTO_NCU } catch {}
    if ($null -eq $v) { $problemas += 'no se ha podido leer la HSU: sin guardia de viento' }
    elseif ($v.alarma -or $v.nivel -gt 0) { $problemas += "VIENTO nivel $($v.nivel) (alarma=$($v.alarma)): NO actualices ahora, la TCU no obedecera un stow" }
    else { Con '  viento: OK (sin alarma ni nivel activo en las HSU de la NCU)' ([System.Drawing.Color]::LightGreen) }

    # 2) comunicacion y estado via NCU (rapido, sin Zigbee)
    $d = $null
    try {
        Modbus-Conectar $tr.ip $PUERTO_NCU $tr.cx.to
        $dm = Ncu-DiagCompat @($tcu)
        $d = $dm[[int]$tcu]
        Modbus-Cerrar
    } catch { Modbus-Cerrar; $problemas += "no se pudo consultar la NCU: $_" }
    if ($d) {
        Con ("  estado via NCU: {0} | modo {1} | tilt {2} | SoC {3}% | {4}" -f $d.Salud, $d.Modo, $d.Tilt, $d.SoC, $(if ($d.Alarmas) { $d.Alarmas } else { 'sin alarmas' })) ([System.Drawing.Color]::Gainsboro)
        if ($d.Salud -eq 'OFFLINE') { $problemas += 'la TCU no comunica con la NCU: actualizarla seria perder el tiempo' }
        if ($d.Salud -eq 'ALARMA') { $problemas += "la TCU tiene alarma critica ($($d.Alarmas)): resuelvela antes" }
        if ("$($d.SoC)" -ne '' -and [int]$d.SoC -lt 40) { $problemas += "SoC bajo ($($d.SoC)%): si la bateria cae a mitad del OTA puedes dejarla a medias" }
    }

    # 3) backup completo de la TCU antes de tocarla
    $seg = @(Plan-Segmentos @($tcu) $tr.cx)[0]
    $fichBk = ''
    try {
        Modbus-Conectar $tr.ip $seg.puerto $tr.cx.to
        $vars = @(); $errs = 0
        foreach ($n in @(Nombres-Ordenados @($VARIABLES.Keys))) {
            try { $vars += [pscustomobject]@{variable=$n; valor=(Leer-Decodificado $tcu $VARIABLES[$n]); grupo='config'} }
            catch { $errs++ }
        }
        $fwActual = ''
        try { $fwActual = ((Ident-Leer $tcu) | Where-Object { $_.Campo -eq 'FW principal' }).Valor } catch {}
        Modbus-Cerrar
        $dirBk = Join-Path $PSScriptRoot 'backups'
        if (-not (Test-Path $dirBk)) { New-Item -ItemType Directory -Path $dirBk | Out-Null }
        $fichBk = Join-Path $dirBk ("pre_ota_ncu{0}_tcu{1}_{2}.json" -f $nNcu, $tcu, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        ConvertTo-Json ([ordered]@{
            tipo='backup_tcu'; mapa=$VERSION_MAPA; toolbox=$VERSION_TOOLBOX; motivo='pre-OTA'
            planta=(Nombre-Planta); ip=$tr.ip; puerto=$seg.puerto; tcu=[int]$tcu; ncu=$nNcu
            fecha=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); completo=($errs -eq 0); errores=$errs
            firmware_antes=$fwActual; variables=$vars
        }) -Depth 5 | Set-Content $fichBk -Encoding UTF8
        Con "  backup previo: $fichBk  ($($vars.Count) variables, $errs errores; FW actual: $fwActual)" ([System.Drawing.Color]::LightGreen)
        if ($errs -gt 0) { $problemas += "el backup previo tiene $errs variables sin leer" }
    } catch { Modbus-Cerrar; $problemas += "no se pudo hacer el backup previo: $_" }

    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    if ($problemas.Count -eq 0) {
        Con 'LISTO para actualizar esta TCU.' ([System.Drawing.Color]::LightGreen)
    } else {
        foreach ($p in $problemas) { Con "  AVISO: $p" ([System.Drawing.Color]::Orange) }
    }
    Con "En el TCU Updater:  NCU IP = $($tr.ip)   Gateway port = $($seg.puerto)   TCU = $tcu" ([System.Drawing.Color]::SteelBlue)
    Con "Para GRABAR el protocolo, lanza antes en otra ventana:" ([System.Drawing.Color]::SteelBlue)
    Con "   powershell -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'TCU_ProxyOTA.ps1')`" -Ncu $($tr.ip) -Puerto $($seg.puerto)" ([System.Drawing.Color]::Gainsboro)
    Con "   y en el updater pon NCU IP = 127.0.0.1 y Gateway port = 5020 (el resto igual)." ([System.Drawing.Color]::Gainsboro)
    Con 'Durante el OTA la TCU esta en bootloader: no sigue al sol ni obedece stow. Vigila el viento.' ([System.Drawing.Color]::Orange)
} })

$btnFwCsv.Add_Click({
    # el plan de verdad son las VENTANAS: lo que se abre y lo que se pega en
    # cada una. Los tramos sueltos van igualmente, para quien los quiera.
    $vv = @($script:PlanFwVentanas)
    $f = Exportar-Csv $(if ($vv.Count -gt 0) { $vv } else { $script:PlanFw }) 'plan_firmware' 'Plan'
    if ($f -ne '' -and @($script:PlanFwDetalle).Count -gt 0) {
        # el detalle por TCU va en su propio fichero: son dos cosas distintas,
        # los tramos se pegan en el updater y la lista es para seguimiento
        $fd = [System.IO.Path]::ChangeExtension($f, $null) + '_pendientes.csv'
        try {
            $script:PlanFwDetalle | Export-Csv $fd -NoTypeInformation -Encoding UTF8 -Delimiter ';'
            Con "TCUs pendientes una a una: $fd  ($(@($script:PlanFwDetalle).Count) equipos)" ([System.Drawing.Color]::SteelBlue)
        } catch { Con "No se ha podido escribir el detalle: $_" ([System.Drawing.Color]::Orange) }
    }
})

# ------------------------- HSU (METEO) -------------------------
# Busca las HSUs de la planta: recorre las NCUs de la seleccion (planta
# completa, (auto) o entrada suelta) y lee el bloque compacto de HSUs que
# cada NCU cachea (30200+, puerto 502). Rellena la lista y el desplegable.
$script:HsusPlanta = @()
$script:HsuSel = $null
# ---------------------------------------------------------------------------
#  Ensayos SAT: registrador continuo
#  Dos cadencias sobre el bloque compacto de la NCU (puerto 502, sin Zigbee):
#  el pase de comunicaciones es barato (4 lecturas/NCU) y va cada 15 s; el de
#  precision y alarmas cuesta mas (18/NCU) y va cada minuto. Se escribe a disco
#  en cada pase, sin acumular en memoria: si el PC se reinicia a los cuatro
#  dias, lo registrado hasta entonces esta a salvo y el ensayo continua al
#  volver a arrancar (los ficheros son diarios y se abren en modo anadir).
# ---------------------------------------------------------------------------
$script:SatOn = $false
$script:SatDir = ''
$script:SatHasta = $null
$script:SatProxTcu = [datetime]::MinValue
$script:SatProxCom = [datetime]::MinValue
$script:SatPasesT = 0; $script:SatPasesC = 0; $script:SatFallos = 0

function Sat-Log([string]$ensayo, [string]$detalle) {
    $item = New-Object System.Windows.Forms.ListViewItem((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    [void]$item.SubItems.Add($ensayo); [void]$item.SubItems.Add($detalle)
    $lvSat.Items.Insert(0, $item) | Out-Null
    while ($lvSat.Items.Count -gt 500) { $lvSat.Items.RemoveAt($lvSat.Items.Count - 1) }
}

function Sat-Fichero([string]$base) {
    return (Join-Path $script:SatDir ("{0}_{1}.csv" -f $base, (Get-Date -Format 'yyyy-MM-dd')))
}

function Sat-Cabecera([string]$fich, [string]$cab) {
    if (-not (Test-Path $fich)) { Set-Content -Path $fich -Value $cab -Encoding UTF8 }
}

# Un pase de comunicaciones: quien contesta y quien no, TCUs y HSUs.
function Sat-PaseComms($trabajos) {
    $fich = Sat-Fichero 'comm'
    Sat-Cabecera $fich 'ts;fecha;ncu;equipo;evento'
    $lineas = New-Object System.Collections.ArrayList
    $ts = [int][double]::Parse((Get-Date -UFormat %s))
    $fecha = Get-Date -Format 'yyyy-MM-dd'
    $nEq = 0; $nMal = 0
    foreach ($tr in $trabajos) {
        if (-not $script:SatOn) { break }
        $cm = $null
        try { Modbus-Conectar $tr.ip $PUERTO_NCU $tr.cx.to; $cm = Ncu-Comm $tr.tcus }
        catch { [void]$lineas.Add("$ts;$fecha;$($tr.ncu);NCU;SIN_NCU"); $nMal++ }
        Modbus-Cerrar
        if ($null -eq $cm) { continue }
        $nEq++      # la propia NCU cuenta como equipo
        foreach ($t in @($cm.tcus.Keys)) {
            $nEq++
            if (-not $cm.tcus[$t].comunica) { [void]$lineas.Add("$ts;$fecha;$($tr.ncu);TCU$t;FALLO"); $nMal++ }
        }
        foreach ($h in @($cm.hsus)) {
            $nEq++
            # el anexo llama RSU a lo que el mapa Sunner llama HSU
            $eq = "$($h.hsu)" -replace '^HSU', 'RSU'
            if (-not $h.comunica) { [void]$lineas.Add("$ts;$fecha;$($tr.ncu);$eq;FALLO"); $nMal++ }
        }
    }
    [void]$lineas.Add("$ts;$fecha;*;PASE;$nEq")
    Add-Content -Path $fich -Value $lineas -Encoding UTF8
    $script:SatPasesC++
    $script:SatFallos += $nMal
    return @{equipos=$nEq; fallos=$nMal}
}

# Un pase de precision y alarmas: posicion real, objetivo, desviacion y las
# tres familias de alarma que cuentan para la disponibilidad de operacion.
function Sat-PaseTcu($trabajos) {
    $fich = Sat-Fichero 'precision'
    Sat-Cabecera $fich 'ts;dia;ncu;tcu;real;obj;desv;modo;al_motor;al_bat;al_com'
    $lineas = New-Object System.Collections.ArrayList
    $ts = [int][double]::Parse((Get-Date -UFormat %s))
    $dia = Get-Date -Format 'yyyy-MM-dd'
    $n = 0
    foreach ($tr in $trabajos) {
        if (-not $script:SatOn) { break }
        $dm = $null
        try { Modbus-Conectar $tr.ip $PUERTO_NCU $tr.cx.to; $dm = Ncu-DiagCompat $tr.tcus }
        catch { }
        Modbus-Cerrar
        if ($null -eq $dm) { continue }
        foreach ($t in @($dm.Keys | Sort-Object)) {
            $d = $dm[$t]
            $al = "$($d.Alarmas)"
            $mot = $(if ($al -match 'eje|motor|sobrecorriente|corto|driver') { 1 } else { 0 })
            $bat = $(if ($al -match 'bateria|SoC|bat') { 1 } else { 0 })
            $com = $(if ("$($d.Salud)" -eq 'OFFLINE') { 1 } else { 0 })
            [void]$lineas.Add(("{0};{1};{2};{3};{4};{5};{6};{7};{8};{9};{10}" -f `
                $ts, $dia, $tr.ncu, $t, $d.Tilt, $d.Objetivo, $d.Dif, $d.Modo, $mot, $bat, $com))
            $n++
        }
    }
    Add-Content -Path $fich -Value $lineas -Encoding UTF8
    $script:SatPasesT++
    return $n
}

# D.3.4.2 y D.3.4.3: disponibilidad de RSU y de NCU. Misma cadencia que las
# TCUs; las alarmas meteorologicas no cuentan, como en el resto del anexo.
function Sat-PaseEquipos($trabajos) {
    $fich = Sat-Fichero 'equipos'
    Sat-Cabecera $fich 'ts;dia;ncu;equipo;al_motor;al_bat;al_com'
    $lineas = New-Object System.Collections.ArrayList
    $ts = [int][double]::Parse((Get-Date -UFormat %s))
    $dia = Get-Date -Format 'yyyy-MM-dd'
    foreach ($tr in $trabajos) {
        if (-not $script:SatOn) { break }
        $hs = @(); $vivo = 0
        try {
            Modbus-Conectar $tr.ip $PUERTO_NCU $tr.cx.to
            $vivo = 1
            try { $hs = @(Ncu-HsuCompat) } catch {}
        } catch { }
        Modbus-Cerrar
        [void]$lineas.Add("$ts;$dia;$($tr.ncu);NCU;0;0;$(1 - $vivo)")
        foreach ($h in $hs) {
            $eq = "$($h.TCU)" -replace '^HSU', 'RSU'
            $al = "$($h.Alarmas)"
            # meteorologicas fuera: solo bateria y comunicacion
            $bat = $(if ($al -match 'bateria|bat') { 1 } else { 0 })
            $com = $(if ("$($h.Salud)" -eq 'OFFLINE') { 1 } else { 0 })
            [void]$lineas.Add("$ts;$dia;$($tr.ncu);$eq;0;$bat;$com")
        }
    }
    Add-Content -Path $fich -Value $lineas -Encoding UTF8
}

$tmrSat = New-Object System.Windows.Forms.Timer
$tmrSat.Interval = 1000
$tmrSat.Add_Tick({
    if (-not $script:SatOn) { return }
    if ($script:Ocupado) { return }        # hay otra operacion en marcha: este pase se salta
    $ahora = Get-Date
    if ($script:SatHasta -and $ahora -gt $script:SatHasta) {
        $script:SatOn = $false; $tmrSat.Stop()
        $btnSatIni.Enabled = $true; $btnSatFin.Enabled = $false
        Sat-Log 'FIN' 'Ensayo terminado: se ha cumplido el plazo. Pulsa ANALIZAR Y EMITIR.'
        Con 'Registro SAT terminado.' ([System.Drawing.Color]::SteelBlue)
        return
    }
    $script:Ocupado = $true
    try {
        $cx = Params-Conexion
        $trabajos = @(Trabajos-Planta $cx $null)
        if ($ahora -ge $script:SatProxCom) {
            $script:SatProxCom = $ahora.AddSeconds([double]$script:SatIntCom)
            $r = Sat-PaseComms $trabajos
            if ($r.fallos -gt 0) { Sat-Log 'D.4 comms' "$($r.equipos) equipos, $($r.fallos) sin responder" }
        }
        if ($ahora -ge $script:SatProxTcu) {
            $script:SatProxTcu = $ahora.AddSeconds([double]$script:SatIntTcu)
            $n = Sat-PaseTcu $trabajos
            Sat-PaseEquipos $trabajos
            Sat-Log 'D.1.1 / D.3.4' "$n TCUs + RSUs y NCUs registradas (pase $($script:SatPasesT))"
        }
    } catch {
        Sat-Log 'ERROR' "$_"
    } finally {
        $script:Ocupado = $false
        Modbus-Cerrar
    }
})

$btnSatIni.Add_Click({
    try {
        $script:SatIntTcu = Val-Int $txtSatInt.Text 'Muestreo TCU' 15 3600
        $script:SatIntCom = Val-Int $txtSatCom.Text 'Muestreo comms' 5 3600
        $dur = Val-Int $txtSatDur.Text 'Duracion' 1 100000
        $unid = "$($cbSatUnid.SelectedItem)"
        $cx = Params-Conexion
        if (-not $cx.multi) {
            $r0 = [System.Windows.Forms.MessageBox]::Show(
                "El anexo pide el 100% de la planta y ahora mismo hay una NCU suelta seleccionada.`r`n`r`nContinuar de todas formas?",
                'Alcance del ensayo', 'YesNo', 'Warning')
            if ($r0 -ne 'Yes') { return }
        }
        $script:SatDir = Join-Path (Join-Path $PSScriptRoot 'informes') ('sat_' + ((Nombre-Planta) -replace '[^\w\-]', '_'))
        if (-not (Test-Path $script:SatDir)) { New-Item -ItemType Directory -Path $script:SatDir -Force | Out-Null }
        $script:SatHasta = switch ($unid) {
            'min'   { (Get-Date).AddMinutes($dur) }
            'horas' { (Get-Date).AddHours($dur) }
            default { (Get-Date).AddDays($dur) }
        }
        $script:SatProxTcu = [datetime]::MinValue; $script:SatProxCom = [datetime]::MinValue
        $script:SatPasesT = 0; $script:SatPasesC = 0; $script:SatFallos = 0
        $script:SatOn = $true
        $btnSatIni.Enabled = $false; $btnSatFin.Enabled = $true
        $tmrSat.Start()
        Sat-Log 'INICIO' "$dur ${unid}: cada $($script:SatIntTcu)s (TCU) y $($script:SatIntCom)s (comms), hasta $($script:SatHasta.ToString('yyyy-MM-dd HH:mm')). Carpeta: $script:SatDir"
        Con "Registro SAT iniciado. NO CIERRES ESTA VENTANA hasta que termine el ensayo. Carpeta: $script:SatDir" ([System.Drawing.Color]::Orange)
    } catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon) }
})

$btnSatFin.Add_Click({
    $script:SatOn = $false; $tmrSat.Stop()
    $btnSatIni.Enabled = $true; $btnSatFin.Enabled = $false
    Sat-Log 'PARADA' "Detenido a mano. Pases TCU: $($script:SatPasesT), pases comms: $($script:SatPasesC)."
    Con 'Registro SAT detenido.' ([System.Drawing.Color]::Orange)
})

# ---------------------------------------------------------------------------
#  D.2 / D.3: cronometro de abanderamiento
#  Muestrea rapido (bloque compacto de la NCU) mientras dura el ensayo y luego
#  emite la cronologia por TCU con las columnas que pide el Anexo 4. La
#  condicion la provoca el operario (bajar el umbral de viento, cortar la
#  alimentacion de la NCU...); el cronometro solo mira y apunta.
# ---------------------------------------------------------------------------
$script:CronOn = $false
$script:CronMuestras = @{}      # "ncu|tcu" -> lista de @{ts; real; obj}
$script:CronMeteo = New-Object System.Collections.ArrayList
$script:CronEnsayo = ''
$script:CronIni = $null
$script:CronTope = 30

$tmrCron = New-Object System.Windows.Forms.Timer
$tmrCron.Interval = 3000   # se ajusta al arrancar cada ensayo
$tmrCron.Add_Tick({
    if (-not $script:CronOn -or $script:Ocupado) { return }
    if ($script:CronTope -gt 0 -and $script:CronIni -and ((Get-Date) - $script:CronIni).TotalMinutes -gt $script:CronTope) {
        Sat-Log 'CRONOMETRO' "Tope de $($script:CronTope) min alcanzado: se para y se emite."
        $btnSatCronFin.PerformClick()
        return
    }
    $script:Ocupado = $true
    try {
        $cx = Params-Conexion
        $ts = [int][double]::Parse((Get-Date -UFormat %s))
        foreach ($tr in @(Trabajos-Planta $cx $null)) {
            if (-not $script:CronOn) { break }
            $dm = $null; $hs = @()
            try {
                Modbus-Conectar $tr.ip $PUERTO_NCU $tr.cx.to
                $dm = Ncu-DiagCompat $tr.tcus
                try { $hs = @(Ncu-HsuCompat) } catch {}
            } catch { }
            Modbus-Cerrar
            if ($null -eq $dm) { continue }
            foreach ($t in @($dm.Keys)) {
                $k = "$($tr.ncu)|$t"
                if (-not $script:CronMuestras.ContainsKey($k)) { $script:CronMuestras[$k] = New-Object System.Collections.ArrayList }
                [void]$script:CronMuestras[$k].Add(@{ts=$ts; real=[double]$dm[$t].Tilt; obj=[double]$dm[$t].Objetivo})
            }
            foreach ($h in $hs) {
                [void]$script:CronMeteo.Add([pscustomobject]@{ts=$ts; hora_utc=([DateTimeOffset]::FromUnixTimeSeconds($ts).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss'))
                    ncu=$tr.ncu; hsu=$h.TCU; salud=$h.Salud; detalle=$h.Alarmas})
            }
        }
    } catch { Sat-Log 'ERROR' "$_" }
    finally { $script:Ocupado = $false; Modbus-Cerrar }
})

$btnSatCron.Add_Click({
    $script:CronEnsayo = "$($cbSatEnsayo.SelectedItem)"
    $aviso = switch -Wildcard ($script:CronEnsayo) {
        'D.2.1*' { 'Provoca el abanderamiento bajando el umbral de viento de la HSU (pestana HSU > ESCRIBIR UMBRALES) y devuelvelo a su valor al terminar.' }
        'D.2.2*' { 'Provoca el abanderamiento con el umbral de nieve de la HSU y devuelvelo a su valor al terminar.' }
        'D.2.3*' { 'Provoca el fallo de comunicacion in situ (o bajando el watchdog Zigbee 40029) y restaura despues.' }
        'D.2.4*' { 'Provoca el abanderamiento subiendo el limite de bateria en la pestana Escribir y restaura despues. Hazlo cuando la posicion de seguridad se parezca a la objetivo, como pide el anexo.' }
        'D.2.5*' { 'Desconecta la alimentacion de la NCU cuando quieras: el cronometro seguira leyendo las TCUs por las NCUs que sigan en pie.' }
        default  { 'Fuerza la posicion objetivo por grupos desde la NCU y restaura el seguimiento automatico al terminar.' }
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "$($script:CronEnsayo)`r`n`r`n$aviso`r`n`r`nEl cronometro muestrea cada 3 s y apunta, por TCU, cuando llega la orden, con que inclinacion, cuando llega a la posicion de seguridad y cuando vuelve a seguimiento.`r`n`r`nEmpezar a cronometrar?",
        'Ensayo de abanderamiento', 'OKCancel', 'Information')
    if ($r -ne 'OK') { return }
    try {
        $tmrCron.Interval = 1000 * (Val-Int $txtCronInt.Text 'Intervalo del cronometro' 1 60)
        $script:CronTope = Val-Int $txtCronMax.Text 'Tope del cronometro' 0 1440
    } catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon); return }
    $script:CronMuestras = @{}
    $script:CronMeteo = New-Object System.Collections.ArrayList
    $script:CronIni = Get-Date
    $script:CronOn = $true
    $btnSatCron.Enabled = $false; $btnSatCronFin.Enabled = $true
    $tmrCron.Start()
    Sat-Log 'CRONOMETRO' "$($script:CronEnsayo) - iniciado. Provoca ya la condicion."
    Con "Cronometro de abanderamiento en marcha ($($script:CronEnsayo))." ([System.Drawing.Color]::Orange)
})

$btnSatCronFin.Add_Click({
    $script:CronOn = $false; $tmrCron.Stop()
    $btnSatCron.Enabled = $true; $btnSatCronFin.Enabled = $false
    try {
        $dir = Join-Path (Join-Path $PSScriptRoot 'informes') ('sat_' + ((Nombre-Planta) -replace '[^\w\-]', '_'))
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $filas = @()
        foreach ($k in @($script:CronMuestras.Keys | Sort-Object)) {
            $p = $k -split '\|'
            $cr = Aband-Cronologia @($script:CronMuestras[$k] | Sort-Object { $_.ts })
            if ($null -eq $cr) { continue }
            $utc = { param($t) if ("$t") { [DateTimeOffset]::FromUnixTimeSeconds([long]$t).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' } }
            $filas += [pscustomobject]@{
                Ensayo = $script:CronEnsayo; NCU = $p[0]; TCU = [int]$p[1]
                Inclinacion_inicial_deg = $cr.tilt_inicial
                Hora_UTC_recepcion_señal = (& $utc $cr.t_orden)
                Inclinacion_al_recibir_deg = $cr.tilt_orden
                Objetivo_seguridad_deg = $cr.obj_seguridad
                Hora_UTC_llegada_seguridad = (& $utc $cr.t_llegada)
                Inclinacion_en_seguridad_deg = $cr.tilt_llegada
                Segundos_hasta_seguridad = $cr.segundos_ida
                Hora_UTC_desabanderamiento = (& $utc $cr.t_vuelta)
                Hora_UTC_vuelta_seguimiento = (& $utc $cr.t_llegada_vuelta)
                Inclinacion_final_deg = $cr.tilt_final
                Segundos_hasta_seguimiento = $cr.segundos_vuelta
                Muestras = @($script:CronMuestras[$k]).Count
            }
        }
        $eti = ($script:CronEnsayo -replace '[^\w\.]', '_')
        $f1 = Join-Path $dir ("RESULTADO_{0}_{1}.csv" -f $eti, (Get-Date -Format 'yyyyMMdd_HHmm'))
        $filas | Export-Csv $f1 -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        if ($script:CronMeteo.Count -gt 0) {
            $f2 = Join-Path $dir ("RESULTADO_{0}_meteo_{1}.csv" -f $eti, (Get-Date -Format 'yyyyMMdd_HHmm'))
            $script:CronMeteo | Export-Csv $f2 -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        }
        $conOrden = @($filas | Where-Object { "$($_.Hora_UTC_recepcion_señal)" -ne '' })
        $llegaron = @($conOrden | Where-Object { "$($_.Hora_UTC_llegada_seguridad)" -ne '' })
        Sat-Log 'CRONOMETRO' ("{0}: {1} TCUs vigiladas, {2} recibieron la orden, {3} llegaron a posicion de seguridad. CSV: {4}" -f $script:CronEnsayo, $filas.Count, $conOrden.Count, $llegaron.Count, $f1)
        Con "Ensayo emitido: $f1" ([System.Drawing.Color]::LightGreen)
        if ($conOrden.Count -lt $filas.Count) {
            Con ("ATENCION: {0} TCUs no recibieron la orden de abanderamiento." -f ($filas.Count - $conOrden.Count)) ([System.Drawing.Color]::Orange)
        }
    } catch { Con "ERROR emitiendo el ensayo: $_" ([System.Drawing.Color]::Salmon) }
})

# D.1.2: la medida la hace una persona con el equipo externo; la hoja se
# entrega con todo lo demas ya puesto y una columna en blanco para anotarla.
$btnSatHoja.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $filas = @()
    $ts = [int][double]::Parse((Get-Date -UFormat %s))
    $utc = [DateTimeOffset]::FromUnixTimeSeconds($ts).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss')
    foreach ($tr in @(Trabajos-Planta $cx $null)) {
        if (Chequear-Cancelado) { break }
        $dm = $null
        try { Modbus-Conectar $tr.ip $PUERTO_NCU $tr.cx.to; $dm = Ncu-DiagCompat $tr.tcus } catch {}
        Modbus-Cerrar
        if ($null -eq $dm) { continue }
        foreach ($t in @($dm.Keys | Sort-Object)) {
            $d = $dm[$t]
            $filas += [pscustomobject]@{
                Tracker = "NCU$($tr.ncu)-TCU$t"; NCU = $tr.ncu; TCU = [int]$t
                Hora_UTC = $utc
                Posicion_tracker_deg = $d.Tilt
                Posicion_segun_algoritmo_deg = $d.Objetivo
                Desviacion_interna_deg = $d.Dif
                Modo = $d.Modo
                Desviacion_equipo_externo_deg = ''      # <- se anota en campo
                Observaciones = ''
            }
        }
    }
    if ($filas.Count -eq 0) { Con 'Sin datos: revisa la conexion.' ([System.Drawing.Color]::Orange); return }
    $dir = Join-Path (Join-Path $PSScriptRoot 'informes') ('sat_' + ((Nombre-Planta) -replace '[^\w\-]', '_'))
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $f = Join-Path $dir ("HOJA_D1.2_precision_externa_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
    $filas | Export-Csv $f -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Sat-Log 'D.1.2' "Hoja de $($filas.Count) trackers generada: $f (falta anotar la lectura del equipo externo)"
    Con "Hoja D.1.2 generada: $f" ([System.Drawing.Color]::LightGreen)
} })

$btnSatAnal.Add_Click({ Lanzar {
    $dir = $script:SatDir
    if (-not $dir -or -not (Test-Path $dir)) {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Carpeta con los CSV del ensayo SAT'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $dir = $dlg.SelectedPath
    }
    $tolPrec = Parse-RealFinito $txtSatTol.Text
    $minTcu  = Parse-RealFinito $txtSatDTcu.Text
    $minRsu  = Parse-RealFinito $txtSatDRsu.Text
    $minCTcu = Parse-RealFinito $txtSatCTcu.Text
    $minCRsu = Parse-RealFinito $txtSatCRsu.Text
    $ventD4  = Val-Int $txtSatVent.Text 'Ventana D.4' 15 600
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Analizando ensayos SAT en $dir" ([System.Drawing.Color]::SteelBlue)
    Con "Criterios: precision <=$tolPrec deg | operacion TCU >=$minTcu% RSU/NCU >=$minRsu% | comms TCU >=$minCTcu% RSU >=$minCRsu%, ventana $ventD4 s" ([System.Drawing.Color]::Gainsboro)
    $fp = @(Get-ChildItem (Join-Path $dir 'precision_*.csv') -ErrorAction SilentlyContinue)
    $fc = @(Get-ChildItem (Join-Path $dir 'comm_*.csv') -ErrorAction SilentlyContinue)
    if ($fp.Count -eq 0 -and $fc.Count -eq 0) { Con 'No hay ficheros de registro en esa carpeta.' ([System.Drawing.Color]::Orange); return }
    $lvSat.Items.Clear()

    if ($fp.Count -gt 0) {
        $filas = @()
        foreach ($f in $fp) { $filas += @(Import-Csv $f.FullName -Delimiter ';') }
        Con "  D.1.1 / D.3.4: $($filas.Count) registros de $($fp.Count) dia(s)" ([System.Drawing.Color]::Gainsboro)
        $pr = @(Sat-Precision $filas $tolPrec 2)
        $malP = @($pr | Where-Object { $_.Cumple -eq 'NO' })
        $pr | Export-Csv (Join-Path $dir 'RESULTADO_D1.1_precision.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Sat-Log 'D.1.1' ("Precision <=$tolPrec deg: {0} de {1} TCUs cumplen{2}" -f ($pr.Count - $malP.Count), $pr.Count, $(if ($malP.Count) { " - INCUMPLEN: " + (($malP | ForEach-Object { "NCU$($_.NCU)/$($_.TCU)" }) -join ', ') } else { '' }))
        $do = @(Sat-DispOperacion $filas $minTcu)
        $malO = @($do | Where-Object { $_.Cumple -eq 'NO' })
        $do | Export-Csv (Join-Path $dir 'RESULTADO_D3.4.1_disp_operacion.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Sat-Log 'D.3.4.1' ("Disponibilidad >=$minTcu%: {0} de {1} TCU-dia cumplen{2}" -f ($do.Count - $malO.Count), $do.Count, $(if ($malO.Count) { " - INCUMPLEN: " + (($malO | Select-Object -First 20 | ForEach-Object { "$($_.Dia) NCU$($_.NCU)/$($_.Equipo) $($_.Disponibilidad_pct)%" }) -join ', ') } else { '' }))
    }

    $fe = @(Get-ChildItem (Join-Path $dir 'equipos_*.csv') -ErrorAction SilentlyContinue)
    if ($fe.Count -gt 0) {
        $fq = @()
        foreach ($f in $fe) { $fq += @(Import-Csv $f.FullName -Delimiter ';') }
        $rsu = @($fq | Where-Object { "$($_.equipo)" -like 'RSU*' })
        $ncu = @($fq | Where-Object { "$($_.equipo)" -eq 'NCU' })
        if ($rsu.Count) {
            $dr = @(Sat-DispOperacion $rsu $minRsu)
            $malR = @($dr | Where-Object { $_.Cumple -eq 'NO' })
            $dr | Export-Csv (Join-Path $dir 'RESULTADO_D3.4.2_disp_RSU.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
            Sat-Log 'D.3.4.2' ("RSU >=$minRsu%: {0} de {1} RSU-dia cumplen" -f ($dr.Count - $malR.Count), $dr.Count)
        }
        if ($ncu.Count) {
            $dn = @(Sat-DispOperacion $ncu $minRsu)
            $malN = @($dn | Where-Object { $_.Cumple -eq 'NO' })
            $dn | Export-Csv (Join-Path $dir 'RESULTADO_D3.4.3_disp_NCU.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
            Sat-Log 'D.3.4.3' ("NCU >=$minRsu%: {0} de {1} NCU-dia cumplen" -f ($dn.Count - $malN.Count), $dn.Count)
        }
    }

    if ($fc.Count -gt 0) {
        $ev = @()
        foreach ($f in $fc) { $ev += @(Import-Csv $f.FullName -Delimiter ';') }
        $intentos = @{}
        foreach ($e in $ev) { if ($e.equipo -eq 'PASE') { $intentos["$($e.fecha)"] = [int]$intentos["$($e.fecha)"] + [int]$e.evento } }
        $fallos = @($ev | Where-Object { $_.evento -eq 'FALLO' } | ForEach-Object {
            [pscustomobject]@{dia=$_.fecha; ncu=$_.ncu; equipo=$_.equipo; ts=$_.ts} })
        Con "  D.4: $($ev.Count) eventos, $($fallos.Count) fallos brutos" ([System.Drawing.Color]::Gainsboro)
        $dc = @(Sat-DispComms $fallos $intentos $minCTcu $ventD4 $minCRsu)
        $malC = @($dc | Where-Object { $_.Cumple -eq 'NO' })
        $dc | Export-Csv (Join-Path $dir 'RESULTADO_D4_disp_comunicaciones.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Sat-Log 'D.4' ("Comunicaciones TCU >=$minCTcu% / RSU >=$minCRsu%: {0} de {1} equipo-dia cumplen{2}" -f ($dc.Count - $malC.Count), $dc.Count, $(if ($malC.Count) { " - INCUMPLEN: " + (($malC | Select-Object -First 20 | ForEach-Object { "$($_.Dia) NCU$($_.NCU)/$($_.Equipo) $($_.Disponibilidad_pct)%" }) -join ', ') } else { '' }))
    }
    Con "Resultados escritos en $dir (ficheros RESULTADO_*.csv)." ([System.Drawing.Color]::LightGreen)
} })

$btnHBuscar.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $p = $null; if ($cbPlanta.SelectedItem) { $p = $PLANTAS[$cbPlanta.SelectedItem] }
    $ncus = @()
    if ($cx.multi) {
        foreach ($n in $cx.multi) { $ncus += ,@{ncu="$($n.ncu)"; ip=$n.ip; hsu=$n.hsu; gws=$n.gws; hsus=[int]$n.hsus; hsuLista=@($n.hsuLista)} }
    } else {
        $eti = ''
        $m = [regex]::Match("$($cbPlanta.SelectedItem)", 'NCU(\d+)')
        if ($m.Success) { $eti = $m.Groups[1].Value }
        $ncus += ,@{ncu=$eti; ip=$cx.ip; hsu=$(if ($p) { $p.hsu } else { $null }); gws=$cx.gws; hsus=$(if ($p) { [int]$p.hsus } else { 0 }); hsuLista=@($(if ($p) { $p.hsuLista } else { @() }))}
    }
    $lvH.Items.Clear()
    $script:HsusPlanta = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Buscando HSUs en $($ncus.Count) NCU(s) via bloque compacto (puerto $PUERTO_NCU)..." ([System.Drawing.Color]::SteelBlue)
    foreach ($n in $ncus) {
        if ($script:Cancelar) { break }
        $filas = @()
        $motivo = ''
        try { Modbus-Conectar $n.ip $PUERTO_NCU $cx.to; $filas = @(Ncu-HsuCompat) }
        catch {
            $motivo = "la NCU no contesta en el puerto $PUERTO_NCU"
            Con "AVISO: NCU$($n.ncu) ($($n.ip)): sin respuesta en ${PUERTO_NCU}: $_" ([System.Drawing.Color]::Orange)
        }
        Modbus-Cerrar
        if ($filas.Count -eq 0 -and [int]$n.hsus -le 0) { Con "$(if ($n.ncu) { "NCU$($n.ncu)" } else { $n.ip }): sin HSUs en el bloque compacto." ([System.Drawing.Color]::Gainsboro); continue }
        $iEnNcu = 0
        foreach ($f in $filas) {
            $eti = ($(if ($n.ncu) { "NCU$($n.ncu) - " } else { '' }) + $f.TCU)
            $script:HsusPlanta += ,@{etiqueta=$eti; ncu="$($n.ncu)"; ip=$n.ip; hsu=(Hsu-EsclavoDe $n $iEnNcu); gws=$n.gws; salud=$f.Salud; texto=$f.Alarmas}
            $iEnNcu++
            $item = New-Object System.Windows.Forms.ListViewItem($eti)
            [void]$item.SubItems.Add("$($f.Salud)"); [void]$item.SubItems.Add("$($f.Alarmas)")
            switch ($f.Salud) {
                'OK'      { $item.ForeColor = [System.Drawing.Color]::DarkGreen }
                'AVISO'   { $item.ForeColor = [System.Drawing.Color]::DarkOrange }
                'ALARMA'  { $item.ForeColor = [System.Drawing.Color]::Firebrick }
                'OFFLINE' { $item.ForeColor = [System.Drawing.Color]::Gray }
            }
            $lvH.Items.Add($item) | Out-Null
            Con ("{0,-14} {1,-8} {2}" -f $eti, $f.Salud, $f.Alarmas) $(if ($f.Salud -eq 'OK') { [System.Drawing.Color]::LightGreen } else { [System.Drawing.Color]::Orange })
        }
        # y las que la topologia dice que hay y no han salido: en la tabla, no
        # ausentes. No van al desplegable ni a HsusPlanta -no se puede operar
        # con lo que no contesta, y el cuadre las tiene que seguir contando
        # como ausentes-, pero se ven.
        foreach ($ff in @(Hsu-Faltantes $n @($filas).Count $motivo)) {
            $itemF = New-Object System.Windows.Forms.ListViewItem($ff.etiqueta)
            [void]$itemF.SubItems.Add("$($ff.salud)"); [void]$itemF.SubItems.Add("$($ff.texto)")
            $itemF.ForeColor = [System.Drawing.Color]::Gray
            $lvH.Items.Add($itemF) | Out-Null
            Con ("{0,-14} {1,-8} {2}" -f $ff.etiqueta, $ff.salud, $ff.texto) ([System.Drawing.Color]::Salmon)
        }
    }
    $cbHsuSel.Items.Clear()
    [void]$cbHsuSel.Items.Add("(todas: $($script:HsusPlanta.Count) HSUs)")
    foreach ($h in $script:HsusPlanta) { [void]$cbHsuSel.Items.Add("$($h.etiqueta)  [$($h.ip)]") }
    $cbHsuSel.SelectedIndex = 0
    # Si la topologia dice cuantas deberia haber, eso va PRIMERO y en el rotulo:
    # "8 HSUs encontradas" a secas no deja ver que faltan dos.
    $cuadre = Hsu-Cuadre $ncus $script:HsusPlanta
    $faltan = @($cuadre.faltan)
    $lblHSel.Text = $(if ($faltan.Count -gt 0) { "FALTAN: solo $($script:HsusPlanta.Count) de las $($cuadre.esperadas) que dice la topologia ($($faltan -join ', ')). " }
                      else { "$($script:HsusPlanta.Count) HSUs encontradas. " }) +
        'Elige una para fijar su IP' + $(if (@($script:HsusPlanta | Where-Object { $_.hsu }).Count) { ' y esclavo' } else { '' }) + '.'
    $lblHSel.ForeColor = $(if ($faltan.Count -gt 0) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::Gray })
    Con "HSUs encontradas: $($script:HsusPlanta.Count). Al elegir una en el desplegable se fija su IP (y esclavo si la topologia lo trae) para las operaciones directas." ([System.Drawing.Color]::SteelBlue)
    if ($cuadre.texto) {
        Con $cuadre.texto $(if (@($cuadre.faltan).Count -gt 0) { [System.Drawing.Color]::Salmon }
                            elseif (@($cuadre.sobran).Count -gt 0) { [System.Drawing.Color]::Orange }
                            else { [System.Drawing.Color]::LightGreen })
    }
} })

# Barrido de esclavos: la caché de la NCU dice CUÁNTAS HSUs hay y cómo están,
# pero no su número de esclavo Modbus, que es lo que hace falta para hablar con
# ellas directamente. Esto lo busca probando: por cada gateway de la NCU, pide
# el Product ID (30300) a cada esclavo y apunta los que contestan.
$btnHEsclavo.Add_Click({ Lanzar {
    $h = $script:HsuSel
    $ip = ''; $gws = @(); $eti = ''
    if ($h -and $h.ip) {
        $ip = $h.ip; $eti = $h.etiqueta
        $gws = @($(if ($h.gws) { @($h.gws | ForEach-Object { [int]$_.puerto }) } else { @(Hsu-Puerto $h) }))
    } else {
        $ip = $txtIp.Text.Trim()
        if (-not $ip -or $ip -eq 'NA' -or $ip -eq '(planta)') {
            [void][System.Windows.Forms.MessageBox]::Show("Elige una HSU en el desplegable (BUSCAR HSUs), o pon a mano la IP de una NCU.`r`n`r`nEl barrido va contra UNA NCU: probar la planta entera tardaria horas.",'Buscar esclavo','OK','Information'); return
        }
        $pt = $txtPort.Text.Trim()
        $gws = @($(if ($pt -eq 'auto' -or -not $pt) { @(503, 504) } else { @([int]$pt) }))
    }
    $to = Val-Int $txtTo.Text 'Timeout' 500 60000
    $lista = @(Esclavos-Barrido ([int]$txtHSlave.Text) 1 247)
    $tot = $lista.Count * @($gws).Count
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Buscar equipos en $ip, gateways $($gws -join ' y '), esclavos 1-247.`r`n`r`n$tot consultas. Cada esclavo que no existe cuesta lo que tarde la NCU en rendirse con el Zigbee, asi que esto puede irse a varios minutos.`r`n`r`nSe puede parar con CANCELAR en cualquier momento y lo encontrado se queda en la lista.`r`n`r`nContinuar?",
        'Buscar esclavo', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $lvH.Items.Clear()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Barrido de esclavos en $ip$(if ($eti) { " ($eti)" }): gateways $($gws -join ', '), $tot consultas." ([System.Drawing.Color]::SteelBlue)
    $hallados = 0; $hechas = 0
    foreach ($puerto in $gws) {
        if ($script:Cancelar) { break }
        try { Modbus-Conectar $ip $puerto $to }
        catch { Con "ERROR de conexion (${ip}:${puerto}): $_" ([System.Drawing.Color]::Salmon); continue }
        Con "--- gateway $puerto ---" ([System.Drawing.Color]::SteelBlue)
        foreach ($u in $lista) {
            if (Chequear-Cancelado) { break }
            $hechas++
            $prod = $null
            try { $prod = (FC03-Leer ([byte]$u) (Dir-Trama 30300) 1)[0] } catch { }
            if ($null -eq $prod) {
                if ($hechas % 25 -eq 0) { Con ("  {0}/{1} probados, {2} encontrados..." -f $hechas, $tot, $hallados) ([System.Drawing.Color]::Gainsboro) }
                continue
            }
            $t = Tipo-Producto $prod
            $hallados++
            $item = New-Object System.Windows.Forms.ListViewItem("esclavo $u  (GW $puerto)")
            [void]$item.SubItems.Add($t.nombre)
            [void]$item.SubItems.Add(("Product ID 0x{0:X4}  -  HW {1}, FW corto {2}" -f $prod, $t.hw, $t.fw))
            $item.ForeColor = $(if ($t.nombre -eq 'HSU') { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Gray })
            $lvH.Items.Add($item) | Out-Null
            $color = $(if ($t.nombre -eq 'HSU') { [System.Drawing.Color]::LightGreen } else { [System.Drawing.Color]::Gainsboro })
            Con ("  GW {0}  esclavo {1,3}  ->  {2}   (0x{3:X4})" -f $puerto, $u, $t.nombre, $prod) $color
            [System.Windows.Forms.Application]::DoEvents()
        }
        Modbus-Cerrar
    }
    Modbus-Cerrar
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    $hsus = @($lvH.Items | Where-Object { $_.SubItems[1].Text -eq 'HSU' })
    if ($hsus.Count -gt 0) {
        Con "Encontradas $($hsus.Count) HSUs." ([System.Drawing.Color]::LightGreen)
        # que la herramienta aprenda: si no, hay que apuntarlo a mano en el JSON
        # y al siguiente barrido volvemos a empezar
        $m = [regex]::Match("$($hsus[0].Text)", 'esclavo (\d+)\s+\(GW (\d+)\)')
        if ($m.Success) {
            $esc = [int]$m.Groups[1].Value; $gw = [int]$m.Groups[2].Value
            $txtHSlave.Text = "$esc"
            $txtPort.Text = "$gw"
            Con "  esclavo $esc por el gateway ${gw}: ya puestos arriba, puedes leer METEO, CONFIG y caja negra." ([System.Drawing.Color]::LightGreen)
            $r2 = [System.Windows.Forms.MessageBox]::Show(
                "Guardar en la topologia de la planta que las HSU son el esclavo ${esc}?`r`n`r`nSe escribe en el JSON de la planta y no habra que volver a barrer.",
                'Aprender el esclavo', 'YesNo', 'Question')
            if ($r2 -eq 'Yes') {
                try {
                    $n = Topologia-Guardar-Hsu (Nombre-Planta) $esc
                    Con "Topologia actualizada: $n entradas con hsu=$esc. Se aplica al reiniciar o al recargar la planta." ([System.Drawing.Color]::LightGreen)
                } catch { Con "No se pudo guardar en la topologia: $_" ([System.Drawing.Color]::Orange) }
            }
        }
    } else {
        Con "Ningun equipo de tipo HSU en $hechas consultas. Si aparecieron TCUs, la conexion y el gateway son correctos y la HSU cuelga del OTRO gateway; si no aparecio nada, revisa IP y puerto." ([System.Drawing.Color]::Orange)
    }
} })

$cbHsuSel.Add_SelectedIndexChanged({
    if ($script:Ocupado) { return }
    $i = $cbHsuSel.SelectedIndex
    $script:HsuSel = $null
    if ($i -le 0 -or $i -gt $script:HsusPlanta.Count) { return }
    $h = $script:HsusPlanta[$i - 1]
    $script:HsuSel = $h
    $txtIp.Text = $h.ip
    if ($h.hsu) { $txtHSlave.Text = "$($h.hsu)" }
    # Antes solo se ponia la IP y el puerto se quedaba en 'auto', que exige una
    # entrada (auto) con su IP sin tocar: al haberla cambiado aqui, la siguiente
    # operacion moria con "puerto 'auto' requiere...". Se deja un puerto real.
    $txtPort.Text = "$(Hsu-Puerto $h)"
    Con "HSU seleccionada: $($h.etiqueta) -> $($h.ip):$($txtPort.Text)$(if ($h.hsu) { ", esclavo $($h.hsu)" } else { '' }). Si cuelga del otro gateway, cambia el puerto a mano." ([System.Drawing.Color]::SteelBlue)
})

# Gateway por el que se llega a una HSU: el que declare su NCU (el de numero
# mas bajo si hay varios) y, si la topologia no lo dice, el 503.
function Hsu-Puerto($h) {
    if ($h -and $h.gws -and @($h.gws).Count -gt 0) { return [int](@($h.gws | Sort-Object { [int]$_.puerto })[0].puerto) }
    if ($h -and $h.puerto) { return [int]$h.puerto }
    return 503
}

# Escribe el numero de esclavo de las HSU en el JSON de la planta, para que la
# herramienta no tenga que volver a descubrirlo. Solo toca el campo 'hsu' de las
# entradas de esa planta; el resto del fichero se queda como esta.
function Topologia-Guardar-Hsu([string]$planta, [int]$esclavo) {
    $dir = Join-Path $PSScriptRoot 'plantas'
    if (-not (Test-Path $dir)) { throw "no hay carpeta de plantas en $dir" }
    $base = ("$planta" -split ' \(')[0].Trim()
    $tocados = 0
    foreach ($f in @(Get-ChildItem $dir -Filter '*.json')) {
        $obj = $null
        try { $obj = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $obj.plantas) { continue }
        $cambio = $false
        foreach ($p in @($obj.plantas)) {
            if (-not ("$($p.nombre)".Trim().StartsWith($base, [StringComparison]::OrdinalIgnoreCase))) { continue }
            if ($p.PSObject.Properties['hsu']) { $p.hsu = $esclavo }
            else { $p | Add-Member -NotePropertyName hsu -NotePropertyValue $esclavo -Force }
            $cambio = $true; $tocados++
        }
        if ($cambio) { ConvertTo-Json $obj -Depth 8 | Set-Content $f.FullName -Encoding UTF8 }
    }
    if ($tocados -eq 0) { throw "no se ha encontrado ninguna entrada de '$base' en los JSON de plantas" }
    return $tocados
}

# Numeros de esclavo a probar en un barrido, en el orden en que conviene
# probarlos: primero los sospechosos (el que hay puesto, los tipicos de HSU) y
# luego el resto. Asi un barrido que se corta a media pasada ya suele haber
# encontrado algo. Pura: se prueba sin planta.
function Esclavos-Barrido([int]$actual, [int]$desde, [int]$hasta) {
    $vistos = @{}
    $r = New-Object System.Collections.ArrayList
    foreach ($v in (@($actual, 185, 200, 247, 1, 100) + @($desde..$hasta))) {
        $n = [int]$v
        if ($n -lt $desde -or $n -gt $hasta) { continue }
        if ($vistos.ContainsKey($n)) { continue }
        $vistos[$n] = $true
        [void]$r.Add($n)
    }
    return $r.ToArray()
}

# Que hay en un esclavo que ha contestado al Product ID (30300). El nibble bajo
# es el tipo de equipo; lo que no es TCU es lo que buscamos.
function Tipo-Producto([int]$prod) {
    $tipo = $prod -band 0xF
    $nom = switch ($tipo) { 1 { 'TCU' } 2 { 'HSU' } default { "tipo $tipo" } }
    return @{tipo=$tipo; nombre=$nom; hw=(($prod -shr 4) -band 0xF); fw=(($prod -shr 8) -band 0xFF)}
}

function Params-Hsu {
    # Con una HSU elegida en el desplegable no hace falta que la entrada de
    # conexion cuadre: BUSCAR HSUs ya resolvio de que NCU cuelga y por donde.
    $cx = $null
    try { $cx = Params-Conexion }
    catch {
        if (-not ($script:HsuSel -and $script:HsuSel.ip)) { throw }
        $cx = @{ip=$script:HsuSel.ip; puerto=$null; gws=$null; multi=$null; etiqueta='auto'
                to=(Val-Int $txtTo.Text 'Timeout' 500 60000); reint=(Val-Int $txtRet.Text 'Reintentos' 1 10)}
    }
    if ($cx.multi -or -not $cx.puerto) {
        # La HSU cuelga de un gateway concreto, pero si se ha elegido una en el
        # desplegable ya sabemos de que NCU es (BUSCAR HSUs lo resuelve): se usa
        # su IP y el primer gateway de esa NCU en vez de obligar a cambiar la
        # entrada de conexion a mano.
        $h = $script:HsuSel
        if ($h -and $h.ip) {
            $puerto = Hsu-Puerto $h
            $cx = @{ip=$h.ip; puerto=[int]$puerto; gws=$null; multi=$null; etiqueta="$puerto"; to=$cx.to; reint=$cx.reint}
            Con "HSU $($h.etiqueta): usando $($cx.ip):$($cx.puerto), el primer gateway de su NCU. Si cuelga del otro, pon el puerto a mano." ([System.Drawing.Color]::SteelBlue)
        } else {
            throw "elige una HSU en el desplegable (BUSCAR HSUs) o una entrada GW concreta: la HSU cuelga de un gateway"
        }
    }
    $cx.unitHsu = [byte](Val-Int $txtHSlave.Text 'Esclavo HSU' 1 255)
    return $cx
}

# Sobre que HSUs actua una lectura: la elegida en el desplegable, TODAS las
# encontradas si esta en "(todas)", o la del campo IP/puerto si se trabaja a
# mano. Con Planta completa o (auto) hay que pasar antes por BUSCAR HSUs, que
# es lo que resuelve de que NCU cuelga cada una y por que gateway se llega.
function Hsu-Objetivos {
    $unit = [byte](Val-Int $txtHSlave.Text 'Esclavo HSU' 1 255)
    $cx = $null
    try { $cx = Params-Conexion }
    catch {
        if (@($script:HsusPlanta).Count -eq 0) { throw }
        $cx = @{ip=''; puerto=$null; gws=$null; multi=$null; etiqueta='auto'
                to=(Val-Int $txtTo.Text 'Timeout' 500 60000); reint=(Val-Int $txtRet.Text 'Reintentos' 1 10)}
    }
    $lista = New-Object System.Collections.ArrayList
    $hsus = @($script:HsusPlanta)
    if ($script:HsuSel -and $script:HsuSel.ip) { $hsus = @($script:HsuSel) }
    if ($hsus.Count -eq 0) {
        if ($cx.multi -or -not $cx.puerto) {
            throw 'pulsa BUSCAR HSUs primero: con Planta completa o (auto) hay que saber de que NCU cuelga cada HSU'
        }
        [void]$lista.Add(@{etiqueta="HSU esclavo $unit"; ip=$cx.ip; puerto=[int]$cx.puerto; unit=$unit})
        return $lista.ToArray()
    }
    foreach ($h in $hsus) {
        $puerto = $null
        $gws = $(if ($h.gws) { $h.gws } else { $cx.gws })
        if ($gws -and @($gws).Count -gt 0) { $puerto = @($gws | Sort-Object { [int]$_.puerto })[0].puerto }
        if (-not $puerto -and $cx.puerto) { $puerto = $cx.puerto }
        if (-not $puerto) { $puerto = Hsu-Puerto $h }
        $u = $(if ($h.hsu) { [byte]$h.hsu } else { $unit })
        [void]$lista.Add(@{etiqueta=$h.etiqueta; ip=$h.ip; puerto=[int]$puerto; unit=$u})
    }
    return $lista.ToArray()
}

# Recorre las HSUs objetivo llamando a $leer (recibe el esclavo) y devuelve
# @{filas; oks} con una cabecera por HSU cuando hay mas de una.
function Hsu-Recorrer($objs, $cx, [scriptblock]$leer, [scriptblock]$resumen) {
    $filas = New-Object System.Collections.ArrayList
    $oks = New-Object System.Collections.ArrayList
    foreach ($o in $objs) {
        if (Chequear-Cancelado) { break }
        if (@($objs).Count -gt 1) {
            [void]$filas.Add([pscustomobject]@{Campo="--- $($o.etiqueta) ---"; Valor="$($o.ip):$($o.puerto)  esclavo $($o.unit)"; Nota=''})
        }
        $r = $null; $err = ''
        try { Modbus-Conectar $o.ip $o.puerto $cx.to } catch { $err = "$_" }
        if (-not $err) {
            for ($i = 1; $i -le $cx.reint -and $null -eq $r; $i++) {
                try { $r = & $leer $o.unit }
                catch {
                    $err = "$_"
                    if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                    Start-Sleep -Milliseconds (300 * $i)
                }
            }
        }
        Modbus-Cerrar
        if ($null -eq $r) {
            [void]$filas.Add([pscustomobject]@{Campo=$o.etiqueta; Valor='sin respuesta'; Nota="ALARMA $err"})
            Con "$($o.etiqueta): sin respuesta: $err" ([System.Drawing.Color]::Salmon)
            continue
        }
        foreach ($f in $r.filas) { [void]$filas.Add($f) }
        [void]$oks.Add(@{obj=$o; datos=$r})
        if ($resumen) { & $resumen $o $r }
    }
    return @{filas=$filas; oks=$oks}
}

function Hsu-Mostrar([array]$filas) {
    $lvH.Items.Clear()
    foreach ($f in $filas) {
        $item = New-Object System.Windows.Forms.ListViewItem($f.Campo)
        [void]$item.SubItems.Add($f.Valor); [void]$item.SubItems.Add($f.Nota)
        if ($f.Nota -match 'ALARMA') { $item.ForeColor = [System.Drawing.Color]::Firebrick }
        $lvH.Items.Add($item) | Out-Null
    }
}

$btnHMeteo.Add_Click({ Lanzar {
    $objs = @(Hsu-Objetivos)
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Leyendo meteo de $($objs.Count) HSU(s)." ([System.Drawing.Color]::SteelBlue)
    $r = Hsu-Recorrer $objs (Params-Conexion) { param($u) Hsu-LeerMeteo $u } {
        param($o, $m)
        if ($m.nivel -gt 0 -or $m.alarmas.Count -gt 0) {
            Con ("{0}: nivel de viento {1}; alarmas: {2}" -f $o.etiqueta, $m.nivel, $(if ($m.alarmas.Count) { $m.alarmas -join '; ' } else { 'ninguna' })) ([System.Drawing.Color]::Orange)
        } else {
            Con "$($o.etiqueta): sin alarmas, nivel de viento 0." ([System.Drawing.Color]::LightGreen)
        }
    }
    Hsu-Mostrar $r.filas
    if (@($objs).Count -gt 1) {
        $conAlarma = @($r.oks | Where-Object { $_.datos.nivel -gt 0 -or $_.datos.alarmas.Count -gt 0 }).Count
        Con ("Resumen: {0} de {1} HSUs respondieron; {2} con alarma o viento." -f @($r.oks).Count, @($objs).Count, $conAlarma) ([System.Drawing.Color]::SteelBlue)
    }
} })

$btnHConfig.Add_Click({ Lanzar {
    $objs = @(Hsu-Objetivos)
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Leyendo configuracion de $($objs.Count) HSU(s)." ([System.Drawing.Color]::SteelBlue)
    $r = Hsu-Recorrer $objs (Params-Conexion) { param($u) Hsu-LeerConfig $u } $null
    Hsu-Mostrar $r.filas
    if (@($r.oks).Count -eq 0) { return }
    # los cuadros de umbrales se cargan con la primera que conteste; si las
    # HSUs no llevan los mismos umbrales, se avisa en vez de disimularlo
    $c = @($r.oks)[0].datos
    $txtHMid.Text = $c.mid.ToString('0.##', $INV); $txtHLow.Text = $c.low.ToString('0.##', $INV)
    $txtHTMid.Text = "$($c.tMid)"; $txtHTLow.Text = "$($c.tLow)"
    Con "Umbrales cargados en los cuadros desde $(@($r.oks)[0].obj.etiqueta) (ON $($txtHMid.Text) / OFF $($txtHLow.Text) m/s)." ([System.Drawing.Color]::SteelBlue)
    $distintas = @($r.oks | Where-Object { $_.datos.mid -ne $c.mid -or $_.datos.low -ne $c.low -or $_.datos.tMid -ne $c.tMid -or $_.datos.tLow -ne $c.tLow })
    if ($distintas.Count) {
        Con ("ATENCION: {0} HSU(s) con umbrales distintos: {1}" -f $distintas.Count, (($distintas | ForEach-Object { "$($_.obj.etiqueta) ON $($_.datos.mid)/OFF $($_.datos.low)" }) -join ' | ')) ([System.Drawing.Color]::Orange)
    }
} })

$btnHUmb.Add_Click({ Lanzar {
    $cx = Params-Hsu
    $mid = Parse-RealFinito $txtHMid.Text
    $low = Parse-RealFinito $txtHLow.Text
    $tMid = Val-Int $txtHTMid.Text 'Tiempo activacion' 0 65535
    $tLow = Val-Int $txtHTLow.Text 'Tiempo desactivacion' 0 65535
    if ($mid -lt 0 -or $mid -gt 60 -or $low -lt 0 -or $low -gt 60) { throw 'umbral fuera de rango razonable (0-60 m/s)' }
    if ($low -gt $mid) { throw "el umbral OFF ($low) no puede ser mayor que el ON ($mid)" }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "ATENCION: vas a cambiar los umbrales de VIENTO de la HSU $($cx.unitHsu) - esto afecta a la SEGURIDAD de la planta.`r`n`r`n" +
        "ON (41013): $mid m/s  tras $tMid s`r`nOFF (41011): $low m/s  tras $tLow s`r`n`r`nContinuar?",
        'UMBRALES DE VIENTO', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    try { Modbus-Conectar $cx.ip $cx.puerto $cx.to } catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon); return }
    $trabajos = @(
        @{n='umbral ON (41013)';  esc=(Valor-A-Escritura @{addr=41013; tipo='f32'} ($mid.ToString($INV)))}
        @{n='umbral OFF (41011)'; esc=(Valor-A-Escritura @{addr=41011; tipo='f32'} ($low.ToString($INV)))}
        @{n='t ON (41018)';       esc=(Valor-A-Escritura @{addr=41018; tipo='u16'} "$tMid")}
        @{n='t OFF (41017)';      esc=(Valor-A-Escritura @{addr=41017; tipo='u16'} "$tLow")}
    )
    $ok = $true
    foreach ($t in $trabajos) {
        $hecho = $false; $fallo = ''
        for ($i = 1; $i -le $cx.reint -and -not $hecho; $i++) {
            try {
                FC16-Escribir $cx.unitHsu $t.esc.addr $t.esc.palabras
                $cmp = Comparar-Escritura $cx.unitHsu $t.esc
                if (-not $cmp.ok) { throw "verificacion: leido $($cmp.leidoRaw)" }
                $hecho = $true
            } catch {
                $fallo = "$_"
                if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                Start-Sleep -Milliseconds (300 * $i)
            }
        }
        if ($hecho) { Con "  $($t.n)  OK" ([System.Drawing.Color]::LightGreen) }
        else { $ok = $false; Con "  $($t.n)  FALLO  $fallo" ([System.Drawing.Color]::Salmon) }
    }
    Modbus-Cerrar
    if ($ok) { Con 'Umbrales escritos y verificados. RECUERDA: pulsa NVM para que sobrevivan a un reinicio.' ([System.Drawing.Color]::Orange) }
} })

$btnHReloj.Add_Click({ Lanzar {
    $cx = Params-Hsu
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Poner el reloj de la HSU $($cx.unitHsu) en hora (UTC, desde este PC)?",
        'Reloj HSU', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    try { Modbus-Conectar $cx.ip $cx.puerto $cx.to } catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon); return }
    $hecho = $false; $fallo = ''
    for ($i = 1; $i -le $cx.reint -and -not $hecho; $i++) {
        try {
            $u = [DateTime]::UtcNow
            FC16-Escribir $cx.unitHsu 40001 @($u.Second, $u.Minute, $u.Hour, $u.Day, $u.Month, $u.Year)
            $hecho = $true
        } catch {
            $fallo = "$_"
            if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
            Start-Sleep -Milliseconds (300 * $i)
        }
    }
    Modbus-Cerrar
    if ($hecho) { Con "Reloj de la HSU puesto en hora (UTC). La caja negra de 24h usa esta hora." ([System.Drawing.Color]::LightGreen) }
    else { Con "FALLO poniendo el reloj: $fallo" ([System.Drawing.Color]::Salmon) }
} })

$btnHNieve.Add_Click({ Lanzar {
    $cx = Params-Hsu
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Calibrar el CERO del sensor de nieve de la HSU $($cx.unitHsu)?`r`nHazlo SOLO sin nieve bajo el sensor.",
        'Calibrar sensor de nieve', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    try { Modbus-Conectar $cx.ip $cx.puerto $cx.to } catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon); return }
    try { FC22-Mascara $cx.unitHsu 40007 0xFFF7 0x0008; Con 'Calibracion de nieve lanzada (40007 bit 3).' ([System.Drawing.Color]::LightGreen) }
    catch { Con "FALLO: $_" ([System.Drawing.Color]::Salmon) }
    Modbus-Cerrar
} })

$btnHNvm.Add_Click({ Lanzar {
    $cx = Params-Hsu
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Guardar la configuracion de la HSU $($cx.unitHsu) en NVM (40007 bit 15)?",
        'NVM HSU', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    try { Modbus-Conectar $cx.ip $cx.puerto $cx.to } catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon); return }
    try { FC22-Mascara $cx.unitHsu 40007 0x7FFF 0x8000; Con 'NVM de la HSU guardada.' ([System.Drawing.Color]::LightGreen) }
    catch { Con "FALLO: $_" ([System.Drawing.Color]::Salmon) }
    Modbus-Cerrar
} })

$btnHCaja.Add_Click({ Lanzar {
    $cx = Params-Hsu
    $fCaja = Guardar-Como 'hsu_cajanegra' 'csv'
    if ($fCaja -eq '') { return }
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Descargando caja negra 24h de la HSU $($cx.unitHsu) (1440 minutos, 58 lecturas)..." ([System.Drawing.Color]::SteelBlue)
    try { Modbus-Conectar $cx.ip $cx.puerto $cx.to } catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon); return }
    $regsTot = 1440 * 4
    $palabras = New-Object System.Collections.Generic.List[int]
    $offset = 0; $fallo = $null
    while ($offset -lt $regsTot) {
        if (Chequear-Cancelado) { break }
        $n = [math]::Min(100, $regsTot - $offset)
        $trozo = $null
        for ($i = 1; $i -le $cx.reint -and $null -eq $trozo; $i++) {
            try { $trozo = FC03-Leer $cx.unitHsu (31000 + $offset) $n }
            catch {
                $fallo = "$_"
                if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                Start-Sleep -Milliseconds (300 * $i)
            }
        }
        if ($null -eq $trozo) { Con "FALLO leyendo el bloque en 31000+$offset : $fallo" ([System.Drawing.Color]::Salmon); break }
        foreach ($v in $trozo) { $palabras.Add($v) }
        $offset += $n
        if (($offset / 100) % 10 -eq 0) { Con ("  {0}/{1} registros..." -f $offset, $regsTot) ([System.Drawing.Color]::Gainsboro) }
    }
    Modbus-Cerrar
    $minutos = [math]::Floor($palabras.Count / 4)
    if ($minutos -eq 0) { Con 'Sin datos.' ([System.Drawing.Color]::Salmon); return }
    $filas = @()
    for ($m = 0; $m -lt $minutos; $m++) {
        $filas += Hsu-CajaFila @($palabras[$m*4], $palabras[$m*4+1], $palabras[$m*4+2], $palabras[$m*4+3]) $m
    }
    $filas | Export-Csv $fCaja -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Con "Caja negra exportada: $fCaja  ($minutos minutos$(if ($minutos -lt 1440) { ', INCOMPLETA' }))." ([System.Drawing.Color]::SteelBlue)
    $vmax = ($filas | Measure-Object -Property Vmax_kmh -Maximum).Maximum
    Con ("Viento maximo del dia registrado por la HSU: {0} km/h." -f $vmax) ([System.Drawing.Color]::SteelBlue)
} })

# ------------------------- log manual -------------------------
# Consulta del historial local: que ha cambiado y cuando, sin depender de nada
# online. Se apoya en la misma tabla de identificacion para no anadir controles.
$btnHist.Add_Click({
    $dir = Join-Path $PSScriptRoot 'historial'
    if (-not (Test-Path $dir)) { [void][System.Windows.Forms.MessageBox]::Show("Todavia no hay historial.`r`n`r`nSe va llenando solo con cada 'Leer variable': cada lectura deja constancia en $dir.",'Historial local'); return }
    $fs = @(Get-ChildItem $dir -Filter '*.csv' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($fs.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show("La carpeta $dir esta vacia.",'Historial local'); return }
    $tcu = "$($txtITcu.Text)".Trim()
    $lineas = @()
    foreach ($f in $fs) { $lineas += @(Get-Content $f.FullName -ErrorAction SilentlyContinue) }
    $cambios = @(Historial-Cambios $lineas '' $tcu '')
    $lvI.Items.Clear(); $script:UltimaIdent = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Historial local de $(@($fs).Count) fichero(s), $($lineas.Count) lineas: $($cambios.Count) cambios$(if ($tcu) { " en la TCU $tcu" } else { ' (todas las TCUs)' })" ([System.Drawing.Color]::SteelBlue)
    if ($cambios.Count -eq 0) {
        Con 'Sin cambios registrados: o es la primera lectura, o el valor no se ha movido.' ([System.Drawing.Color]::Gainsboro)
        return
    }
    foreach ($c in $cambios) {
        $txt = ("{0}  NCU{1} TCU {2}  {3}" -f $c.Fecha, $c.NCU, $c.TCU, $c.Variable)
        $val = $(if ($c.Antes -ne '') { "$($c.Antes)  ->  $($c.Valor)" } else { "$($c.Valor)  (primera lectura)" })
        $item = New-Object System.Windows.Forms.ListViewItem($txt)
        [void]$item.SubItems.Add($val)
        if ($c.Antes -ne '') { $item.ForeColor = [System.Drawing.Color]::DarkOrange }
        $lvI.Items.Add($item) | Out-Null
        $script:UltimaIdent += [pscustomobject]@{Campo=$txt; Valor=$val}
        Con "  $txt : $val" $(if ($c.Antes -ne '') { [System.Drawing.Color]::Orange } else { [System.Drawing.Color]::Gainsboro })
    }
    $btnICsv.Enabled = $true
})

$btnLimpiar.Add_Click({ Limpiar-Consola })
$btnBuscar.Add_Click({ Buscador-Abrir })

$btnLog.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Texto (*.txt)|*.txt'
    $dlg.FileName = 'tcu_toolbox_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt'
    if ($dlg.ShowDialog() -eq 'OK') { Set-Content $dlg.FileName $rtb.Text -Encoding UTF8 }
})

# ------------------------- informe HTML de la sesion -------------------------
# Nombre legible de cada bloque, para el dialogo y para el nombre del fichero
$script:NombreBloque = @{diag='Diagnostico'; lectura='Lectura de variables'; pem='PEM'
                         aud='Auditoria'; inv='Inventario'; esc='Escritura'}

$btnInforme.Add_Click({
    try {
        $dir = Join-Path $PSScriptRoot 'informes'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $datos = @{diag = $script:UltimoDiag; pem = $script:UltimoPem; aud = $script:UltimaAud
                   inv = $script:UltimoInv; esc = $script:UltimaEscritura; lectura = $script:UltimaLectura
                   cierre = @(Cierre-Pendientes); bat = $script:UltimaBat}
        $conDatos = @($datos.Keys | Where-Object { @($datos[$_]).Count -gt 0 })
        $ultimo = ''; $nUlt = -1
        foreach ($k in $conDatos) {
            $o = [int]$script:OrdenDe[$k]
            if ($o -gt $nUlt) { $nUlt = $o; $ultimo = $k }
        }
        # Con varias operaciones en la sesion hay que preguntar: un informe que
        # mezcla un TEST COMM con una verificacion de FW no vale para archivar.
        $soloUltimo = $false
        if ($conDatos.Count -gt 1 -and $ultimo) {
            $etUlt = "$($script:NombreBloque[$ultimo]) ($($script:HoraDe[$ultimo]))"
            $lista = ($conDatos | Sort-Object { - [int]$script:OrdenDe[$_] } | ForEach-Object { "  - $($script:NombreBloque[$_]) ($($script:HoraDe[$_]))" }) -join "`r`n"
            $r = [System.Windows.Forms.MessageBox]::Show(
                ("En esta sesion hay {0} operaciones:`r`n{1}`r`n`r`nSI  -> informe SOLO de lo ultimo: {2}`r`nNO  -> informe de TODA la sesion`r`nCANCELAR -> no generar nada" -f $conDatos.Count, $lista, $etUlt),
                'Que incluyo en el informe?', 'YesNoCancel', 'Question')
            if ($r -eq 'Cancel') { return }
            $soloUltimo = ($r -eq 'Yes')
        }
        $m = @{
            planta = (Nombre-Planta); ip = $txtIp.Text.Trim()
            fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm')
            usuario = $(if ($script:Usuario) { "$($script:Usuario.nombre) ($($script:Usuario.usuario))" } else { "$env:USERNAME" })
            version = $VERSION_TOOLBOX; mapa = $VERSION_MAPA
            orden = $script:OrdenDe; horas = $script:HoraDe
        }
        foreach ($k in @($datos.Keys)) {
            $m[$k] = $(if ($soloUltimo -and $k -ne $ultimo) { @() } else { $datos[$k] })
        }
        # el nombre del fichero dice de que es: asi no se lian en la carpeta
        $que = 'sesion'
        if (($soloUltimo -or $conDatos.Count -eq 1) -and $ultimo) { $que = "$($script:NombreBloque[$ultimo])" }
        $que = $que -replace '[^\w\-]', '_'
        $fich = Join-Path $dir ('informe_' + $que + '_' + ($m.planta -replace '[^\w\-\.]', '_') + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.html')
        Set-Content -Path $fich -Value (Informe-Html $m) -Encoding UTF8
        Con "Informe HTML generado: $fich" ([System.Drawing.Color]::SteelBlue)
        Start-Process $fich
    } catch { Con "ERROR generando el informe: $_" ([System.Drawing.Color]::Salmon) }
})

# ------------------------- recordar la ultima sesion -------------------------
# config_local.json junto al script: planta, IP, puerto, timeout, reintentos y
# esclavo HSU. Se guarda al cerrar y se restaura al arrancar.
$script:FichConfigLocal = Join-Path $PSScriptRoot 'config_local.json'
function Config-Guardar {
    try {
        $cfg = [ordered]@{
            planta = "$($cbPlanta.SelectedItem)"; ip = $txtIp.Text.Trim(); puerto = $txtPort.Text.Trim()
            timeout = $txtTo.Text.Trim(); reintentos = $txtRet.Text.Trim(); hsu = $txtHSlave.Text.Trim()
            tema = $script:TemaNombre; rollback = $chkRoll.Checked
            sat = @{tol=$txtSatTol.Text; dtcu=$txtSatDTcu.Text; drsu=$txtSatDRsu.Text; ctcu=$txtSatCTcu.Text; crsu=$txtSatCRsu.Text
                    vent=$txtSatVent.Text; cronint=$txtCronInt.Text; cronmax=$txtCronMax.Text; dur=$txtSatDur.Text; unid="$($cbSatUnid.SelectedItem)"
                    muestreo=$txtSatInt.Text; comms=$txtSatCom.Text}
        }
        ConvertTo-Json $cfg | Set-Content $script:FichConfigLocal -Encoding UTF8
    } catch {}
}
function Config-Restaurar {
    if (-not (Test-Path $script:FichConfigLocal)) { return }
    try {
        $cfg = Get-Content $script:FichConfigLocal -Raw | ConvertFrom-Json
        if ($cfg.planta -and $cbPlanta.Items.Contains("$($cfg.planta)")) {
            $cbPlanta.SelectedItem = "$($cfg.planta)"   # autorrellena rangos/IP via SelectedIndexChanged
        }
        if ("$($cbPlanta.SelectedItem)" -eq '(manual)') {
            if ("$($cfg.ip)") { $txtIp.Text = "$($cfg.ip)" }
            if ("$($cfg.puerto)") { $txtPort.Text = "$($cfg.puerto)" }
        }
        if ("$($cfg.timeout)") { $txtTo.Text = "$($cfg.timeout)" }
        if ("$($cfg.reintentos)") { $txtRet.Text = "$($cfg.reintentos)" }
        if ("$($cfg.hsu)") { $txtHSlave.Text = "$($cfg.hsu)" }
        if ($null -ne $cfg.rollback) { $chkRoll.Checked = [bool]$cfg.rollback }
        if ($cfg.sat) {
            if ("$($cfg.sat.tol)")  { $txtSatTol.Text  = "$($cfg.sat.tol)" }
            if ("$($cfg.sat.dtcu)") { $txtSatDTcu.Text = "$($cfg.sat.dtcu)" }
            if ("$($cfg.sat.drsu)") { $txtSatDRsu.Text = "$($cfg.sat.drsu)" }
            if ("$($cfg.sat.ctcu)") { $txtSatCTcu.Text = "$($cfg.sat.ctcu)" }
            if ("$($cfg.sat.crsu)") { $txtSatCRsu.Text = "$($cfg.sat.crsu)" }
            if ("$($cfg.sat.vent)")     { $txtSatVent.Text = "$($cfg.sat.vent)" }
            if ("$($cfg.sat.cronint)")  { $txtCronInt.Text = "$($cfg.sat.cronint)" }
            if ("$($cfg.sat.cronmax)")  { $txtCronMax.Text = "$($cfg.sat.cronmax)" }
            if ("$($cfg.sat.dur)")      { $txtSatDur.Text = "$($cfg.sat.dur)" }
            if ("$($cfg.sat.unid)" -and $cbSatUnid.Items.Contains("$($cfg.sat.unid)")) { $cbSatUnid.SelectedItem = "$($cfg.sat.unid)" }
            if ("$($cfg.sat.muestreo)") { $txtSatInt.Text  = "$($cfg.sat.muestreo)" }
            if ("$($cfg.sat.comms)")    { $txtSatCom.Text  = "$($cfg.sat.comms)" }
        }
        Con "Sesion anterior restaurada: planta '$($cbPlanta.SelectedItem)' (config_local.json)." ([System.Drawing.Color]::SteelBlue)
    } catch { Con "AVISO: config_local.json ilegible ($_) - ignorado" ([System.Drawing.Color]::Orange) }
}
$form.Add_FormClosing({ Config-Guardar })

# ------------------------- arranque -------------------------
Con "TCU Toolbox v$VERSION_TOOLBOX listo. Mapa de registros: $VERSION_MAPA." ([System.Drawing.Color]::Gainsboro)
Con 'Escribir: tabla + presets + backup como preset. Leer: varias variables a la vez en un rango, con resumen de discrepancias.' ([System.Drawing.Color]::Gainsboro)
Con 'Filtro de variables: escribe p.ej. "soc" o "tilt" en el campo Filtro y el desplegable se reduce a lo que casa.' ([System.Drawing.Color]::Gainsboro)
Con 'Entradas (auto): NCU completa con puerto resuelto por TCU; los gateways se recorren en secuencia.' ([System.Drawing.Color]::Gainsboro)
Con 'Flota: auditoria contra preset de referencia e inventario (FW/serie/MAC). Volcar: BACKUP NCU masivo. Escribir: CSV por TCU.' ([System.Drawing.Color]::Gainsboro)
Con 'Diagnostico de Planta completa: recorre todas las NCUs (filtro NCUs: 1,3-5) e incluye la salud de cada NCU (GW1/GW2, UPS, seta).' ([System.Drawing.Color]::Gainsboro)
Con 'HSU: meteo en vivo, umbrales de viento, reloj UTC, calibracion de nieve y caja negra de 24h a CSV.' ([System.Drawing.Color]::Gainsboro)
Con 'PEM: test de motor con guardia de viento, modo masivo, limpieza de alarmas enclavadas, stow test y estado de comisionado.' ([System.Drawing.Color]::Gainsboro)
Con 'Volcar: backup completo de una TCU (CSV/JSON) y comparacion contra un backup anterior.' ([System.Drawing.Color]::Gainsboro)
Con 'Diagnostico: salud OK/AVISO/ALARMA/OFFLINE de un rango con alarmas en texto. Utilidades: reloj e identificacion.' ([System.Drawing.Color]::Gainsboro)
Con 'Registrador (Diagnostico): BUCLE CSV repite el diagnostico cada X min y lo acumula en informes/registro_*.csv.' ([System.Drawing.Color]::Gainsboro)
Con 'INFORME HTML: volcado de la sesion (diagnostico, PEM, auditoria, inventario y lectura de variables) a un informe con filtros.' ([System.Drawing.Color]::Gainsboro)
Con 'Escritura masiva (>3 TCUs): se crea antes un rollback en backups/ restaurable con "CSV por TCU...".' ([System.Drawing.Color]::Gainsboro)
Con 'PEM > SEGUIMIENTO JSON: exporta la ficha de seguimiento (comisionado + auditoria + motor) para subirla al Historico de la plataforma.' ([System.Drawing.Color]::Gainsboro)
foreach ($m in $script:MsgsInicio) { Con $m ([System.Drawing.Color]::SteelBlue) }
if ($PLANTAS.Count -le 1) {
    Con 'Sin plantas cargadas: usa el boton Cargar... (o copia los JSON de la plataforma en la subcarpeta plantas/).' ([System.Drawing.Color]::Orange)
}
# ---------------------------------------------------------------------------
#  Tema visual (v4.9)
#  Se aplica al final, sobre los controles ya creados: solo cambia colores,
#  fuentes y bordes, nunca posiciones, asi que el diseno de cada pestana sigue
#  siendo exactamente el mismo. Es un tema claro a proposito: las filas de las
#  listas se colorean por salud (verde/ambar/rojo) sobre fondo blanco.
# ---------------------------------------------------------------------------
$script:Tema = @{
    Fondo   = [System.Drawing.Color]::FromArgb(244,246,249)   # lienzo
    Tarjeta = [System.Drawing.Color]::White                   # grupos, tablas
    Linea   = [System.Drawing.Color]::FromArgb(214,221,230)
    Texto   = [System.Drawing.Color]::FromArgb(26,34,45)
    Suave   = [System.Drawing.Color]::FromArgb(108,124,140)   # notas y cabeceras
    Acento  = [System.Drawing.Color]::FromArgb(0,110,180)
    Fila    = [System.Drawing.Color]::FromArgb(248,250,252)   # fila alterna
    Sel     = [System.Drawing.Color]::FromArgb(219,234,247)
    ConsBg  = [System.Drawing.Color]::FromArgb(11,15,20)      # misma consola que la plataforma web
    ConsFg  = [System.Drawing.Color]::FromArgb(231,238,244)
}
$script:FuenteUI  = New-Object System.Drawing.Font('Segoe UI', 9)
$script:FuenteNeg = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:FuenteCab = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)

function Tema-Tono($col, [int]$n) {
    $r = [Math]::Max(0, [Math]::Min(255, [int]$col.R + $n))
    $g = [Math]::Max(0, [Math]::Min(255, [int]$col.G + $n))
    $b = [Math]::Max(0, [Math]::Min(255, [int]$col.B + $n))
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

# DoubleBuffered es protegida: sin esto los grupos parpadean al redimensionar
function Tema-DobleBuffer($c) {
    try {
        $pr = $c.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($pr) { $pr.SetValue($c, $true, $null) }
    } catch {}
}

function Tema-Recoger($cont, $acc) {
    foreach ($c in $cont.Controls) {
        [void]$acc.Add($c)
        if ($c.Controls.Count -gt 0) { Tema-Recoger $c $acc }
    }
}

# La fuente nueva es algo mas ancha que la de serie: si a alguna etiqueta o
# boton se le queda corto el ancho fijo, se ensancha lo justo, sin llegar a
# tocar el control que tenga a su derecha.
function Tema-AjustarAnchos($cont) {
    foreach ($c in $cont.Controls) {
        if ($c.Controls.Count -gt 0) { Tema-AjustarAnchos $c }
        $ajustable = ($c -is [System.Windows.Forms.Label]) -or ($c -is [System.Windows.Forms.CheckBox]) -or
                     ($c -is [System.Windows.Forms.RadioButton]) -or ($c -is [System.Windows.Forms.Button])
        if (-not $ajustable) { continue }
        if ($c.AutoSize -or [string]::IsNullOrEmpty($c.Text)) { continue }
        $margen = if ($c -is [System.Windows.Forms.Label]) { 6 } else { 20 }
        $necesita = [System.Windows.Forms.TextRenderer]::MeasureText($c.Text, $c.Font).Width + $margen
        if ($necesita -le $c.Width) { continue }
        $tope = $c.Parent.ClientSize.Width - 6
        foreach ($o in $c.Parent.Controls) {
            if ($o -eq $c -or $o.Left -le $c.Left) { continue }
            if (($o.Top -ge ($c.Top + $c.Height)) -or (($o.Top + $o.Height) -le $c.Top)) { continue }
            if ($o.Left -lt $tope) { $tope = $o.Left - 4 }
        }
        $nuevo = [Math]::Min($necesita, $tope - $c.Left)
        if ($nuevo -gt $c.Width) { $c.Width = $nuevo }
    }
}

function Tema-Aplicar {
    $script:Ctrls = New-Object System.Collections.ArrayList
    Tema-Recoger $form $script:Ctrls

    # Que botones llevan color propio hay que mirarlo ANTES de tocar fondos:
    # BackColor es una propiedad ambiental y en cuanto cambia el del formulario
    # los botones sin color propio devuelven el heredado, no el del sistema.
    $script:BotonAccion = @{}
    foreach ($c in $script:Ctrls) {
        if ($c -is [System.Windows.Forms.Button]) {
            $script:BotonAccion[$c] = ($c.BackColor -ne [System.Drawing.SystemColors]::Control)
        }
    }

    $form.Font      = $script:FuenteUI
    $form.BackColor = $script:Tema.Fondo
    $form.ForeColor = $script:Tema.Texto
    Tema-DobleBuffer $form

    foreach ($c in $script:Ctrls) {
        if ($c -is [System.Windows.Forms.Button]) {
            $c.FlatStyle = 'Flat'
            $c.UseVisualStyleBackColor = $false
            if ($script:BotonAccion[$c]) {
                # boton de accion: mantiene su color (verde escribir, azul leer,
                # naranja NVM/stow, rojo cancelar) pero plano y en negrita
                $c.FlatAppearance.BorderSize = 0
                $c.ForeColor = [System.Drawing.Color]::White
                $c.Font = $script:FuenteNeg
                $c.FlatAppearance.MouseOverBackColor = (Tema-Tono $c.BackColor 26)
                $c.FlatAppearance.MouseDownBackColor = (Tema-Tono $c.BackColor (-22))
            } else {
                $c.BackColor = $script:Tema.Tarjeta
                $c.ForeColor = $script:Tema.Texto
                $c.FlatAppearance.BorderSize  = 1
                $c.FlatAppearance.BorderColor = $script:Tema.Linea
                $c.FlatAppearance.MouseOverBackColor = $script:Tema.Sel
            }
        }
        elseif ($c -is [System.Windows.Forms.GroupBox]) {
            $c.BackColor = $script:Tema.Tarjeta
            $c.ForeColor = $script:Tema.Suave
            Tema-DobleBuffer $c
            # el borde grabado de serie es lo que mas envejece la ventana: se
            # repinta el grupo entero como una tarjeta con un filete de 1 px
            $c.Add_Paint({
                param($s, $e)
                $g = $e.Graphics
                $g.Clear($script:Tema.Tarjeta)
                $lapiz = New-Object System.Drawing.Pen($script:Tema.Linea, 1)
                $g.DrawRectangle($lapiz, 0, 6, ($s.ClientSize.Width - 1), ($s.ClientSize.Height - 7))
                $lapiz.Dispose()
                $t = "$($s.Text)".Trim().ToUpper()
                if ($t) {
                    $tam = [System.Windows.Forms.TextRenderer]::MeasureText($t, $script:FuenteCab)
                    $br = New-Object System.Drawing.SolidBrush($script:Tema.Tarjeta)
                    $g.FillRectangle($br, 9, 0, ($tam.Width + 6), $tam.Height)
                    $br.Dispose()
                    [System.Windows.Forms.TextRenderer]::DrawText($g, $t, $script:FuenteCab,
                        (New-Object System.Drawing.Point(11, 0)), $script:Tema.Suave)
                }
            })
        }
        elseif ($c -is [System.Windows.Forms.TabPage]) {
            $c.UseVisualStyleBackColor = $false
            $c.BackColor = $script:Tema.Fondo
            $c.ForeColor = $script:Tema.Texto
        }
        elseif ($c -is [System.Windows.Forms.ListView]) {
            $c.BorderStyle = 'FixedSingle'
            $c.BackColor = $script:Tema.Tarjeta
            $c.ForeColor = $script:Tema.Texto
            $c.FullRowSelect = $true
            # una lista de imagenes de 1x20 solo para dar aire a las filas
            try {
                if (-not $c.SmallImageList) {
                    $il = New-Object System.Windows.Forms.ImageList
                    $il.ImageSize = New-Object System.Drawing.Size(1, 20)
                    $c.SmallImageList = $il
                }
            } catch {}
        }
        elseif ($c -is [System.Windows.Forms.DataGridView]) {
            $c.BorderStyle = 'FixedSingle'
            $c.BackgroundColor = $script:Tema.Tarjeta
            $c.GridColor = $script:Tema.Linea
            $c.CellBorderStyle = 'SingleHorizontal'
            $c.ColumnHeadersBorderStyle = 'Single'
            $c.EnableHeadersVisualStyles = $false
            $c.ColumnHeadersDefaultCellStyle.BackColor = $script:Tema.Tarjeta
            $c.ColumnHeadersDefaultCellStyle.ForeColor = $script:Tema.Suave
            $c.ColumnHeadersDefaultCellStyle.Font = $script:FuenteCab
            $c.ColumnHeadersHeightSizeMode = 'EnableResizing'   # si estuviera en AutoSize, fijar la altura lanzaria
            $c.ColumnHeadersHeight = 28
            $c.AlternatingRowsDefaultCellStyle.BackColor = $script:Tema.Fila
            $c.DefaultCellStyle.SelectionBackColor = $script:Tema.Sel
            $c.DefaultCellStyle.SelectionForeColor = $script:Tema.Texto
            $c.RowTemplate.Height = 24
            foreach ($f in $c.Rows) { $f.Height = 24 }
        }
        elseif ($c -is [System.Windows.Forms.ListBox]) {
            $c.BorderStyle = 'FixedSingle'
            $c.BackColor = $script:Tema.Tarjeta
            $c.ForeColor = $script:Tema.Texto
        }
        elseif ($c -is [System.Windows.Forms.TextBox]) {
            $c.BorderStyle = 'FixedSingle'
            $c.BackColor = $script:Tema.Tarjeta
            $c.ForeColor = $script:Tema.Texto
        }
        elseif ($c -is [System.Windows.Forms.Label]) {
            # las notas y resumenes iban en Gray; se unifican al gris del tema
            if ($c.ForeColor -eq [System.Drawing.Color]::Gray) { $c.ForeColor = $script:Tema.Suave }
        }
    }

    # Pestanas planas: las de serie son las que mas delatan la edad de la ventana.
    # SizeMode 'Normal' (no 'Fixed'): cada pestana se ajusta a su texto, que con
    # nueve pestanas es la diferencia entre que quepan todas o salgan flechas.
    $tabs.BackColor = $script:Tema.Fondo
    $tabs.DrawMode  = 'OwnerDrawFixed'
    $tabs.SizeMode  = 'Normal'
    $tabs.Padding   = New-Object System.Drawing.Point(12, 4)
    $tabs.ItemSize  = New-Object System.Drawing.Size(90, 28)
    $tabs.Add_DrawItem({
        param($s, $e)
        $g = $e.Graphics
        $r = $s.GetTabRect($e.Index)
        $activa = ($e.Index -eq $s.SelectedIndex)
        $br = New-Object System.Drawing.SolidBrush($(if ($activa) { $script:Tema.Tarjeta } else { $script:Tema.Fondo }))
        $g.FillRectangle($br, $r)
        $br.Dispose()
        if ($activa) {
            $ba = New-Object System.Drawing.SolidBrush($script:Tema.Acento)
            $g.FillRectangle($ba, $r.X, $r.Y, $r.Width, 3)
            $ba.Dispose()
        }
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $bt = New-Object System.Drawing.SolidBrush($(if ($activa) { $script:Tema.Texto } else { $script:Tema.Suave }))
        $rf = New-Object System.Drawing.RectangleF($r.X, ($r.Y + 2), $r.Width, $r.Height)
        $g.DrawString($s.TabPages[$e.Index].Text, $(if ($activa) { $script:FuenteNeg } else { $script:FuenteUI }), $bt, $rf, $fmt)
        $bt.Dispose(); $fmt.Dispose()
    })

    # Consola: misma paleta que la plataforma web
    $rtb.BorderStyle = 'None'
    $rtb.BackColor = $script:Tema.ConsBg
    $rtb.ForeColor = $script:Tema.ConsFg
    $lblLog.ForeColor = $script:Tema.Suave

    Tema-AjustarAnchos $form
}

# Escotilla de salida: con "tema": "clasico" en config_local.json la ventana
# vuelve al aspecto de siempre sin tocar el script.
$script:TemaNombre = 'claro'
try {
    if (Test-Path $script:FichConfigLocal) {
        $cfgT = Get-Content $script:FichConfigLocal -Raw | ConvertFrom-Json
        if ("$($cfgT.tema)" -eq 'clasico') { $script:TemaNombre = 'clasico' }
    }
} catch {}
if ($script:TemaNombre -ne 'clasico') { Tema-Aplicar }

# ------------------------- ventana redimensionable -------------------------
# Anclajes para que al maximizar crezcan las tablas y la consola (el diseno
# usa posiciones fijas, asi que sin esto la ventana grande dejaria huecos).
$gbCon.Anchor      = 'Top,Left,Right'
$btnCancelar.Anchor = 'Top,Right'
$tabs.Anchor       = 'Top,Left,Right,Bottom'
$rtb.Anchor        = 'Left,Right,Bottom'
$lblLog.Anchor     = 'Left,Bottom'
$btnLog.Anchor     = 'Right,Bottom'
$btnInforme.Anchor = 'Right,Bottom'

# Decide el anclaje de un control a partir de su geometria. Va aparte del
# recorrido de controles para poder probarlo sin abrir una ventana.
#   tipo: 'tabla' | 'grupo' | 'boton' | 'etiqueta' | 'otro'
#   crece: es la tabla mas baja del contenedor (la unica que puede estirarse)
#   abajoTabla: borde inferior de esa tabla, o -1 si el contenedor no tiene
function Anclaje-Para([hashtable]$g) {
    if ($g.tipo -eq 'tabla') {
        if ($g.crece) { return 'Top,Left,Right,Bottom' }
        return 'Top,Left,Right'
    }
    # Lo que esta POR DEBAJO de la tabla que crece tiene que bajar con la
    # ventana. Si se queda anclado arriba, al maximizar la tabla se estira y se
    # lo come: es lo que pasaba con ESCRIBIR y con las casillas de su fila.
    if ($g.abajoTabla -ge 0 -and $g.top -ge ($g.abajoTabla - 4)) {
        if ($g.tipo -eq 'etiqueta' -and $g.ancho -gt 300 -and -not $g.vecinoDerecha) { return 'Bottom,Left,Right' }
        if (($g.left + $g.ancho) -gt ($g.anchoRef - 60)) { return 'Bottom,Right' }
        return 'Bottom,Left'
    }
    if ($g.tipo -eq 'grupo') {
        # en Flota hay dos grupos apilados: el de abajo es el que crece
        if ($g.top -gt 150) { return 'Top,Left,Right,Bottom' }
        return 'Top,Left,Right'
    }
    if ($g.tipo -eq 'boton' -and (($g.left + $g.ancho) -gt ($g.anchoRef - 60))) { return 'Top,Right' }
    # Una etiqueta larga solo puede estirarse si no tiene nada a su derecha en
    # la misma fila. Si lo tiene, al maximizar se le echa encima y lo tapa
    # (era el caso de la nota del registrador sobre el boton TEST COMM).
    if ($g.tipo -eq 'etiqueta' -and $g.ancho -gt 300 -and -not $g.vecinoDerecha) { return 'Top,Left,Right' }
    return ''
}

# Anclar contra un contenedor que todavia no tiene su tamano definitivo deja
# los controles pegados al borde derecho fuera de la vista, y las tablas mas
# largas que su pestana. Por eso esto se hace con la ventana ya mostrada y con
# una guarda por si algun contenedor sigue sin medir lo que deberia.
function Anclar-Contenedor($cont, $anchoRef) {
    $ancho = $cont.ClientSize.Width
    $alto = $cont.ClientSize.Height
    $tablas = @($cont.Controls | Where-Object {
        $_ -is [System.Windows.Forms.ListView] -or $_ -is [System.Windows.Forms.DataGridView] -or $_ -is [System.Windows.Forms.RichTextBox] })
    $topeAbajo = -1
    foreach ($t in $tablas) { if ($t.Top -gt $topeAbajo) { $topeAbajo = $t.Top } }
    $abajoTabla = -1
    foreach ($t in $tablas) { if ($t.Top -eq $topeAbajo) { $abajoTabla = $t.Top + $t.Height } }
    foreach ($c in $cont.Controls) {
        if (($ancho -lt ($c.Left + $c.Width)) -or ($alto -lt ($c.Top + $c.Height))) {
            # el contenedor no mide lo que deberia: mejor no anclar nada
            if ($c -is [System.Windows.Forms.GroupBox]) { Anclar-Contenedor $c ($c.Width - 24) }
            continue
        }
        $tipo = 'otro'
        if ($c -is [System.Windows.Forms.ListView] -or $c -is [System.Windows.Forms.DataGridView] -or $c -is [System.Windows.Forms.RichTextBox]) { $tipo = 'tabla' }
        elseif ($c -is [System.Windows.Forms.GroupBox]) { $tipo = 'grupo' }
        elseif ($c -is [System.Windows.Forms.Button]) { $tipo = 'boton' }
        elseif ($c -is [System.Windows.Forms.Label]) { $tipo = 'etiqueta' }
        # hay algo a su derecha en la misma franja horizontal?
        $vecino = $false
        foreach ($o in $cont.Controls) {
            if ($o -eq $c -or $o.Left -le $c.Left) { continue }
            if (($o.Top -ge ($c.Top + $c.Height)) -or (($o.Top + $o.Height) -le $c.Top)) { continue }
            $vecino = $true; break
        }
        $a = Anclaje-Para @{tipo=$tipo; top=$c.Top; left=$c.Left; ancho=$c.Width; alto=$c.Height
                            anchoRef=$anchoRef; crece=($c.Top -eq $topeAbajo); abajoTabla=$abajoTabla
                            vecinoDerecha=$vecino}
        if ($a) { $c.Anchor = $a }
        if ($tipo -eq 'grupo') { Anclar-Contenedor $c ($c.Width - 24) }
    }
}

# Red de seguridad: si algo ha acabado fuera de su contenedor, se mete dentro.
# Mas vale un boton apretado contra el borde que un boton que no se ve.
function Layout-Rescatar($cont) {
    $ancho = $cont.ClientSize.Width; $alto = $cont.ClientSize.Height
    if ($ancho -lt 40 -or $alto -lt 40) { return }
    foreach ($c in $cont.Controls) {
        if ($c.Width  -gt ($ancho - 8)) { $c.Width  = $ancho - 8 }
        if ($c.Height -gt ($alto  - 8)) { $c.Height = $alto  - 8 }
        if (($c.Left + $c.Width)  -gt ($ancho - 4)) { $c.Left = [Math]::Max(4, $ancho - 4 - $c.Width) }
        if (($c.Top  + $c.Height) -gt ($alto  - 4)) { $c.Top  = [Math]::Max(4, $alto  - 4 - $c.Height) }
        if ($c.Controls.Count -gt 0) { Layout-Rescatar $c }
    }
}

# ---------------------------------------------------------------------------
#  Buscador de acciones (Ctrl+K)
# ---------------------------------------------------------------------------
# Hay 80 acciones repartidas en 10 pestanas, y la herramienta tiene mas
# capacidad que superficie: se pregunta por botones que ya existen. Esto lista
# todos y lleva al sitio. NO los ejecuta a proposito: la mitad escriben en
# equipos, y un buscador que dispara acciones por accidente es peor que no
# tenerlo. Lleva a la pestana y deja el boton marcado para que lo pulses tu.

# Normaliza para buscar sin acentos ni mayusculas. Pura: se prueba sin ventana.
function Buscar-Norm([string]$t) {
    $x = "$t".ToLower()
    foreach ($par in @(@('á','a'), @('é','e'), @('í','i'), @('ó','o'), @('ú','u'), @('ü','u'), @('ñ','n'))) {
        $x = $x.Replace($par[0], $par[1])
    }
    return $x
}

# Casan todas las palabras del filtro, en cualquier orden y en cualquier parte
# del texto: "csv flota" encuentra "Flota / INVENTARIO -> CSV". Pura.
function Buscar-Casa([string]$texto, [string]$filtro) {
    $f = (Buscar-Norm $filtro).Trim()
    if ($f -eq '') { return $true }
    $t = Buscar-Norm $texto
    foreach ($w in @($f -split '\s+')) { if ($w -ne '' -and -not $t.Contains($w)) { return $false } }
    return $true
}

# Recorre la ventana y saca una entrada por cada boton y casilla con texto,
# anotando de que pestana y de que grupo cuelga.
function Acciones-Inventario($cont, [string]$ruta = '') {
    $r = New-Object System.Collections.ArrayList
    foreach ($c in $cont.Controls) {
        $miRuta = $ruta
        if ($c -is [System.Windows.Forms.TabPage]) { $miRuta = "$($c.Text)" }
        elseif ($c -is [System.Windows.Forms.GroupBox] -and "$($c.Text)".Trim() -ne '') {
            $g = "$($c.Text)".Trim()
            if ($g.Length -gt 40) { $g = $g.Substring(0, 40).Trim() + '...' }
            $miRuta = $(if ($ruta) { "$ruta / $g" } else { $g })
        }
        $esAccion = ($c -is [System.Windows.Forms.Button]) -or ($c -is [System.Windows.Forms.CheckBox])
        if ($esAccion -and "$($c.Text)".Trim() -ne '') {
            [void]$r.Add(@{texto="$($c.Text)".Trim(); ruta=$miRuta; ctrl=$c
                           tipo=$(if ($c -is [System.Windows.Forms.CheckBox]) { 'casilla' } else { 'boton' })})
        }
        if ($c.Controls.Count -gt 0) { foreach ($x in (Acciones-Inventario $c $miRuta)) { [void]$r.Add($x) } }
    }
    return $r.ToArray()
}

function Buscador-Abrir {
    $acciones = @(Acciones-Inventario $form)
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Buscar accion'
    $d.Size = New-Object System.Drawing.Size(660, 460)
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'
    $tB = New-Object System.Windows.Forms.TextBox
    $tB.Location = New-Object System.Drawing.Point(12, 12)
    $tB.Size = New-Object System.Drawing.Size(620, 24)
    $d.Controls.Add($tB)
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = New-Object System.Drawing.Point(12, 44)
    $lb.Size = New-Object System.Drawing.Size(620, 330)
    $d.Controls.Add($lb)
    $lblA = New-Object System.Windows.Forms.Label
    $lblA.Location = New-Object System.Drawing.Point(12, 384)
    $lblA.Size = New-Object System.Drawing.Size(620, 34)
    $lblA.ForeColor = [System.Drawing.Color]::Gray
    $lblA.Text = "Escribe para filtrar. Enter (o doble clic) te lleva a la pestana y deja el boton marcado; no lo pulsa el buscador, lo pulsas tu."
    $d.Controls.Add($lblA)
    $vista = @()
    $pintar = {
        $vista = @($acciones | Where-Object { Buscar-Casa "$($_.ruta) $($_.texto)" $tB.Text })
        $lb.BeginUpdate(); $lb.Items.Clear()
        foreach ($a in $vista) { [void]$lb.Items.Add($(if ($a.ruta) { "$($a.ruta)  ->  $($a.texto)" } else { $a.texto })) }
        $lb.EndUpdate()
        if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
        $d.Text = "Buscar accion  ($($lb.Items.Count) de $($acciones.Count))"
    }.GetNewClosure()
    $ir = {
        if ($lb.SelectedIndex -lt 0 -or $lb.SelectedIndex -ge @($vista).Count) { return }
        $a = @($vista)[$lb.SelectedIndex]
        $d.Close()
        # subir hasta la pestana que lo contiene y seleccionarla
        $c = $a.ctrl
        while ($c -ne $null -and -not ($c -is [System.Windows.Forms.TabPage])) { $c = $c.Parent }
        if ($c -is [System.Windows.Forms.TabPage]) { $tabs.SelectedTab = $c }
        try { $a.ctrl.Focus() } catch {}
        Con "Buscador: $($a.texto)$(if ($a.ruta) { " (en $($a.ruta))" })" ([System.Drawing.Color]::SteelBlue)
    }.GetNewClosure()
    $tB.Add_TextChanged($pintar)
    $tB.Add_KeyDown({
        param($s2, $e2)
        if ($e2.KeyCode -eq 'Down' -and $lb.Items.Count -gt 0) { $lb.SelectedIndex = [Math]::Min($lb.SelectedIndex + 1, $lb.Items.Count - 1); $e2.Handled = $true }
        elseif ($e2.KeyCode -eq 'Up' -and $lb.Items.Count -gt 0) { $lb.SelectedIndex = [Math]::Max($lb.SelectedIndex - 1, 0); $e2.Handled = $true }
        elseif ($e2.KeyCode -eq 'Enter') { & $ir; $e2.Handled = $true }
        elseif ($e2.KeyCode -eq 'Escape') { $d.Close() }
    }.GetNewClosure())
    $lb.Add_DoubleClick($ir)
    $lb.Add_KeyDown({ param($s3, $e3) if ($e3.KeyCode -eq 'Enter') { & $ir; $e3.Handled = $true } }.GetNewClosure())
    & $pintar
    $d.Add_Shown({ $tB.Focus() }.GetNewClosure())
    [void]$d.ShowDialog($form)
}

$form.KeyPreview = $true
$form.Add_KeyDown({
    param($s, $e)
    if ($e.Control -and $e.KeyCode -eq 'K') { $e.Handled = $true; Buscador-Abrir }
})

# Todas las tablas de resultados filtran y ordenan al pulsar su cabecera.
foreach ($tabla in @($lvL, $lvD, $lvG, $lvA, $lvV, $lvP, $lvFW, $lvSat, $lvH, $lvI, $lvC, $lvB, $lvT)) { Lv-Filtrable $tabla }

$form.Add_Shown({
    try {
        if ($script:TemaNombre -ne 'clasico') { Tema-AjustarAnchos $form }
        $anchoTab = $tabs.DisplayRectangle.Width - 10
        foreach ($tp in $tabs.TabPages) { Anclar-Contenedor $tp $anchoTab }
        Layout-Rescatar $form
    } catch {
        Con "AVISO: no se pudo ajustar el diseno de la ventana ($_)" ([System.Drawing.Color]::Orange)
    }
})

# ---------------------------------------------------------------------------
#  Login (obligatorio) y aplicacion del rol
# ---------------------------------------------------------------------------
# Dialogo de alta: el primer arranque no tiene usuarios, asi que pide crear el
# administrador antes de dejar entrar a nadie.
function Dialogo-Usuario([string]$titulo, [string]$rolFijo) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $titulo; $d.Size = New-Object System.Drawing.Size(420, 280)
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterScreen'
    [void](LG $d 'Usuario' 15 80 20);    $tU = TG $d '' 110 18 270
    [void](LG $d 'Nombre' 15 80 50);     $tN = TG $d '' 110 48 270
    [void](LG $d 'Contraseña' 15 90 80); $tP = TG $d '' 110 78 270; $tP.UseSystemPasswordChar = $true
    [void](LG $d 'Repetir' 15 80 110);   $tP2 = TG $d '' 110 108 270; $tP2.UseSystemPasswordChar = $true
    [void](LG $d 'Rol' 15 80 140)
    $cbR = New-Object System.Windows.Forms.ComboBox
    $cbR.Location = New-Object System.Drawing.Point(110, 138)
    $cbR.Size = New-Object System.Drawing.Size(270, 22); $cbR.DropDownStyle = 'DropDownList'
    foreach ($r in $ROLES) { [void]$cbR.Items.Add($r) }
    $cbR.SelectedItem = $(if ($rolFijo) { $rolFijo } else { 'tecnico' })
    if ($rolFijo) { $cbR.Enabled = $false }
    $d.Controls.Add($cbR)
    $lblR = LG $d '' 110 270 165; $lblR.ForeColor = [System.Drawing.Color]::Gray
    $lblR.Text = $ROL_DESC["$($cbR.SelectedItem)"]
    $cbR.Add_SelectedIndexChanged({ $lblR.Text = $ROL_DESC["$($cbR.SelectedItem)"] }.GetNewClosure())
    $bOk = New-Object System.Windows.Forms.Button
    $bOk.Text = 'Crear'; $bOk.Location = New-Object System.Drawing.Point(200, 200); $bOk.Size = New-Object System.Drawing.Size(85, 28)
    $bCa = New-Object System.Windows.Forms.Button
    $bCa.Text = 'Cancelar'; $bCa.Location = New-Object System.Drawing.Point(295, 200); $bCa.Size = New-Object System.Drawing.Size(85, 28)
    $bCa.DialogResult = 'Cancel'
    $d.Controls.Add($bOk); $d.Controls.Add($bCa); $d.AcceptButton = $bOk; $d.CancelButton = $bCa
    # OJO: .GetNewClosure() mete el bloque en un modulo propio, asi que un
    # "$script:loquesea = ..." de dentro NO es el mismo que se lee aqui fuera.
    # Ese fue el fallo de la v7.4: el alta devolvia $null, el arranque hacia
    # return sin decir nada y no se guardaba ningun usuario. La salida va en una
    # hashtable capturada: es un objeto, y mutarlo funciona en cualquier ambito.
    $sal = @{ usuario = $null }
    $bOk.Add_Click({
        $u = $tU.Text.Trim()
        if ($u -eq '') { [void][System.Windows.Forms.MessageBox]::Show('El usuario no puede estar vacío.','Aviso'); return }
        if ($tP.Text.Length -lt 4) { [void][System.Windows.Forms.MessageBox]::Show('La contraseña necesita al menos 4 caracteres.','Aviso'); return }
        if ($tP.Text -ne $tP2.Text) { [void][System.Windows.Forms.MessageBox]::Show('Las dos contraseñas no coinciden.','Aviso'); return }
        $sal.usuario = Usuario-Nuevo $u $(if ($tN.Text.Trim()) { $tN.Text.Trim() } else { $u }) "$($cbR.SelectedItem)" $tP.Text
        $d.DialogResult = 'OK'; $d.Close()
    }.GetNewClosure())
    [void]$d.ShowDialog()
    return $sal.usuario
}

function Dialogo-Login($usuarios) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = "TCU Toolbox v$VERSION_TOOLBOX - identificate"
    $d.Size = New-Object System.Drawing.Size(400, 210)
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterScreen'
    [void](LG $d 'Usuario' 15 80 25);    $tU = TG $d "$env:USERNAME" 105 23 255
    [void](LG $d 'Contraseña' 15 90 58); $tP = TG $d '' 105 56 255; $tP.UseSystemPasswordChar = $true
    $lblE = LG $d '' 15 350 90; $lblE.ForeColor = [System.Drawing.Color]::Firebrick
    $bOk = New-Object System.Windows.Forms.Button
    $bOk.Text = 'Entrar'; $bOk.Location = New-Object System.Drawing.Point(190, 125); $bOk.Size = New-Object System.Drawing.Size(85, 28)
    $bOk.BackColor = [System.Drawing.Color]::FromArgb(0,90,160); $bOk.ForeColor = [System.Drawing.Color]::White
    $bCa = New-Object System.Windows.Forms.Button
    $bCa.Text = 'Salir'; $bCa.Location = New-Object System.Drawing.Point(285, 125); $bCa.Size = New-Object System.Drawing.Size(85, 28)
    $bCa.DialogResult = 'Cancel'
    $d.Controls.Add($bOk); $d.Controls.Add($bCa); $d.AcceptButton = $bOk; $d.CancelButton = $bCa
    $sal = @{ usuario = $null }
    $bOk.Add_Click({
        $u = Usuario-Validar $usuarios $tU.Text.Trim() $tP.Text
        if ($null -eq $u) { $lblE.Text = 'Usuario o contraseña incorrectos.'; $tP.Text = ''; $tP.Focus(); return }
        $sal.usuario = $u
        $d.DialogResult = 'OK'; $d.Close()
    }.GetNewClosure())
    $d.Add_Shown({ if ($tU.Text) { $tP.Focus() } else { $tU.Focus() } }.GetNewClosure())
    [void]$d.ShowDialog()
    return $sal.usuario
}

# Botones que cada rol NO puede usar. Todo lo que escriba en un equipo es de
# tecnico para arriba; lo que toca identidad de red, firmware o topologia, solo
# de administrador.
$BOTONES_TECNICO = @($btnEscribir, $btnNvm, $btnCsvTcu, $btnFallidas, $btnSync, $btnFwPrep,
                     $btnPMotor, $btnPModo, $btnPClear, $btnPStow, $btnPUnstow, $btnPComisSet,
                     $btnHUmb, $btnHReloj, $btnHNieve, $btnHNvm)
# La topologia decide a que equipos apunta todo lo demas: cambiarla es de admin.
$BOTONES_ADMIN   = @($btnPlantas)

function Aplicar-Rol {
    foreach ($b in $BOTONES_TECNICO) { if ($b) { $b.Enabled = (Puede 'tecnico') } }
    foreach ($b in $BOTONES_ADMIN)   { if ($b) { $b.Enabled = (Puede 'admin') } }
    $form.Text = "TCU Toolbox v$VERSION_TOOLBOX - Sunner  (mapa $VERSION_MAPA)   -   $($script:Usuario.nombre) [$($script:Usuario.rol)]"
}

# Gestion de usuarios: cualquiera puede cambiarse su propia contraseña; dar de
# alta, borrar y cambiar roles es de administrador.
$btnUsuarios.Add_Click({
    # El estado va en una hashtable por lo mismo que en Dialogo-Usuario: cada
    # .GetNewClosure() vive en su propio modulo, asi que si $lista fuera una
    # variable suelta, el boton de baja no veria lo que dio de alta el de arriba.
    $st = @{ lista = @(Usuarios-Cargar) }
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Usuarios'; $d.Size = New-Object System.Drawing.Size(560, 380)
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(12, 12)
    $lv.Size = New-Object System.Drawing.Size(520, 240)
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true
    [void]$lv.Columns.Add('Usuario', 130); [void]$lv.Columns.Add('Nombre', 200); [void]$lv.Columns.Add('Rol', 170)
    $d.Controls.Add($lv)
    $pintar = {
        $lv.Items.Clear()
        foreach ($u in $st.lista) {
            $it = New-Object System.Windows.Forms.ListViewItem("$($u.usuario)")
            [void]$it.SubItems.Add("$($u.nombre)"); [void]$it.SubItems.Add("$($u.rol)")
            if ("$($u.usuario)" -eq "$($script:Usuario.usuario)") { $it.Font = New-Object System.Drawing.Font($lv.Font, [System.Drawing.FontStyle]::Bold) }
            $lv.Items.Add($it) | Out-Null
        }
    }
    & $pintar
    $bAlta = New-Object System.Windows.Forms.Button
    $bAlta.Text = 'Alta...'; $bAlta.Location = New-Object System.Drawing.Point(12, 262); $bAlta.Size = New-Object System.Drawing.Size(110, 28)
    $bAlta.Enabled = (Puede 'admin')
    $bBaja = New-Object System.Windows.Forms.Button
    $bBaja.Text = 'Baja'; $bBaja.Location = New-Object System.Drawing.Point(130, 262); $bBaja.Size = New-Object System.Drawing.Size(110, 28)
    $bBaja.Enabled = (Puede 'admin')
    $bPass = New-Object System.Windows.Forms.Button
    $bPass.Text = 'Cambiar mi contraseña...'; $bPass.Location = New-Object System.Drawing.Point(248, 262); $bPass.Size = New-Object System.Drawing.Size(180, 28)
    $bCerrar = New-Object System.Windows.Forms.Button
    $bCerrar.Text = 'Cerrar'; $bCerrar.Location = New-Object System.Drawing.Point(436, 262); $bCerrar.Size = New-Object System.Drawing.Size(96, 28)
    $bCerrar.DialogResult = 'OK'
    $lblN = LG $d '' 12 520 300
    $lblN.ForeColor = [System.Drawing.Color]::Gray
    $lblN.Text = $(if (Puede 'admin') { 'Recuerda: esto evita errores, no protege el programa. Un .ps1 es texto plano.' }
                   else { "Tu rol es '$($script:Usuario.rol)': para dar de alta o cambiar roles hace falta un administrador." })
    $d.Controls.Add($bAlta); $d.Controls.Add($bBaja); $d.Controls.Add($bPass); $d.Controls.Add($bCerrar)
    $d.AcceptButton = $bCerrar
    $bAlta.Add_Click({
        $n = Dialogo-Usuario 'Alta de usuario' ''
        if (-not $n) { return }
        if (@($st.lista | Where-Object { "$($_.usuario)".ToLower() -eq "$($n.usuario)".ToLower() }).Count -gt 0) {
            [void][System.Windows.Forms.MessageBox]::Show('Ya existe un usuario con ese nombre.','Aviso'); return
        }
        $st.lista = @($st.lista) + $n
        try { Usuarios-Guardar $st.lista } catch { [void][System.Windows.Forms.MessageBox]::Show("No se pudo guardar: $_",'Error'); return }
        Auditar 'USUARIO_ALTA' '' '' "$($n.usuario) con rol $($n.rol)"
        Con "Usuario dado de alta: $($n.usuario) (rol $($n.rol))" ([System.Drawing.Color]::LightGreen)
        & $pintar
    }.GetNewClosure())
    $bBaja.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $u = $lv.SelectedItems[0].Text
        if ($u -eq "$($script:Usuario.usuario)") { [void][System.Windows.Forms.MessageBox]::Show('No puedes borrarte a ti mismo.','Aviso'); return }
        $admins = @($st.lista | Where-Object { "$($_.rol)" -eq 'admin' -and "$($_.usuario)" -ne $u })
        if ($admins.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Tiene que quedar al menos un administrador.','Aviso'); return }
        if ([System.Windows.Forms.MessageBox]::Show("Dar de baja a '$u'?",'Baja','YesNo','Warning') -ne 'Yes') { return }
        $st.lista = @($st.lista | Where-Object { "$($_.usuario)" -ne $u })
        try { Usuarios-Guardar $st.lista } catch { [void][System.Windows.Forms.MessageBox]::Show("No se pudo guardar: $_",'Error'); return }
        Auditar 'USUARIO_BAJA' '' '' $u
        Con "Usuario dado de baja: $u" ([System.Drawing.Color]::Orange)
        & $pintar
    }.GetNewClosure())
    $bPass.Add_Click({
        $n = Dialogo-Usuario 'Cambiar mi contraseña' "$($script:Usuario.rol)"
        if (-not $n) { return }
        if ("$($n.usuario)".ToLower() -ne "$($script:Usuario.usuario)".ToLower()) {
            [void][System.Windows.Forms.MessageBox]::Show("Escribe tu propio usuario ($($script:Usuario.usuario)).",'Aviso'); return
        }
        $st.lista = @(@($st.lista | Where-Object { "$($_.usuario)".ToLower() -ne "$($n.usuario)".ToLower() }) + $n)
        try { Usuarios-Guardar $st.lista } catch { [void][System.Windows.Forms.MessageBox]::Show("No se pudo guardar: $_",'Error'); return }
        Auditar 'USUARIO_PASS' '' '' "$($n.usuario)"
        Con "Contraseña cambiada para $($n.usuario)." ([System.Drawing.Color]::LightGreen)
        & $pintar
    }.GetNewClosure())
    [void]$d.ShowDialog($form)
})

$usuarios = @(Usuarios-Cargar)
if ($usuarios.Count -eq 0) {
    [void][System.Windows.Forms.MessageBox]::Show(
        "Primer arranque: no hay usuarios dados de alta.`r`n`r`nVas a crear el ADMINISTRADOR. Guarda bien la contraseña: si se pierde, hay que borrar usuarios.json a mano.",
        'TCU Toolbox', 'OK', 'Information')
    $nuevo = Dialogo-Usuario 'Crear administrador' 'admin'
    if (-not $nuevo) { return }
    $usuarios = @($nuevo)
    try { Usuarios-Guardar $usuarios }
    catch { [void][System.Windows.Forms.MessageBox]::Show("No se pudo guardar usuarios.json: $_",'Error'); return }
    # Comprobar que de verdad ha quedado escrito y se vuelve a leer: si la
    # carpeta no es escribible (Archivos de programa, unidad de red de solo
    # lectura), sin esto el usuario se crea, no se guarda y al reabrir vuelve a
    # pedirlo sin explicar nada.
    $rel = @(Usuarios-Cargar)
    if (@($rel).Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "El usuario no se ha podido guardar en:`r`n$FICH_USUARIOS`r`n`r`nLa carpeta no deja escribir. Mueve la herramienta a una carpeta tuya (Escritorio o Documentos) y vuelve a abrirla.",
            'No se puede guardar', 'OK', 'Error')
        return
    }
    $usuarios = $rel
    [void][System.Windows.Forms.MessageBox]::Show(
        "Administrador '$($nuevo.usuario)' creado y guardado.`r`n`r`nAhora entra con ese usuario y su contraseña.",
        'Usuario creado', 'OK', 'Information')
}
$script:Usuario = Dialogo-Login $usuarios
if (-not $script:Usuario) { return }

Config-Restaurar
Aplicar-Rol
Con "Sesion iniciada: $($script:Usuario.nombre) ($($script:Usuario.usuario)), rol $($script:Usuario.rol). $($ROL_DESC["$($script:Usuario.rol)"])" ([System.Drawing.Color]::LightGreen)
if (-not (Puede 'tecnico')) { Con 'Rol de solo lectura: los botones que escriben en los equipos estan desactivados.' ([System.Drawing.Color]::Orange) }
Auditar 'SESION' '' '' "entra $($script:Usuario.usuario)"
Cierre-Cargar (Nombre-Planta)
Cierre-Pintar
Cierre-Avisar
Trabajos-Pintar
[void]$form.ShowDialog()
Modbus-Cerrar
