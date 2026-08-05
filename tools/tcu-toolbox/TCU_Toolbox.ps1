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
[System.Windows.Forms.Application]::EnableVisualStyles()

$VERSION_TOOLBOX = '2.7'
$VERSION_MAPA    = 'SUNNER v6.1 (FW 1.4.3)'

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
        $PLANTAS[[string]$p.nombre] = @{
            ip     = [string]$p.ip
            puerto = [int]$p.puerto
            ini    = [int]$p.tcu_ini
            fin    = [int]$p.tcu_fin
        }
        $n++
    }
    return $n
}

# Entradas "(auto)": si varias entradas comparten IP (una por gateway de la
# misma NCU), se anade una entrada agregada que cubre el rango completo y
# resuelve sola el puerto de cada TCU (adios al error de puerto).
# Entradas "(PLANTA completa)": si los nombres siguen el patron
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
        $PLANTAS["$prefijo (auto)"] = @{ip=$ip; puerto=$null; ini=[int]$ini; fin=[int]$fin; gws=$gws}
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
        if (-not $porPlanta[$planta].Contains($ncu)) { $porPlanta[$planta][$ncu] = @{ip=$p.ip; gws=@()} }
        if ($porPlanta[$planta][$ncu].ip -ne $p.ip) { continue }   # inconsistencia: ignorar
        $porPlanta[$planta][$ncu].gws += ,@{puerto=$p.puerto; ini=$p.ini; fin=$p.fin}
    }
    foreach ($planta in $porPlanta.Keys) {
        $ncus = $porPlanta[$planta]
        if ($ncus.Count -lt 2) { continue }
        $lista = @()
        foreach ($n in ($ncus.Keys | Sort-Object)) {
            $lista += ,@{ncu=[int]$n; ip=$ncus[$n].ip; gws=@($ncus[$n].gws | Sort-Object { $_.ini })}
        }
        $PLANTAS["$planta (PLANTA completa)"] = @{ip=$null; puerto=$null; ini=$null; fin=$null; ncus=$lista}
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
  '40000 CMD main_change_request [hex]'   = @{addr=40000; tipo='u16'}
  '40007 CMD extended_control [hex]'      = @{addr=40007; tipo='u16'}
  '40017 CMD manual_motor [hex] PELIGRO'  = @{addr=40017; tipo='u16'}
  '40018 CMD config_control [hex] PELIGRO'= @{addr=40018; tipo='u16'}
  '42000 CMD remote_change_request [hex]' = @{addr=42000; tipo='u16'}
  # ---- FECHA / HORA DE ENTRADA ----
  '40001 input_time_segundos'             = @{addr=40001; tipo='u16'}
  '40002 input_time_minutos'              = @{addr=40002; tipo='u16'}
  '40003 input_time_horas'                = @{addr=40003; tipo='u16'}
  '40004 input_date_dia'                  = @{addr=40004; tipo='u16'}
  '40005 input_date_mes'                  = @{addr=40005; tipo='u16'}
  '40006 input_date_ano'                  = @{addr=40006; tipo='u16'}
  # ---- CARGA / BATERIA ----
  '40008 jeita_T1 [K]'                    = @{addr=40008; tipo='u16'}
  '40009 jeita_T2 [K]'                    = @{addr=40009; tipo='u16'}
  '40010 jeita_T3 [K]'                    = @{addr=40010; tipo='u16'}
  '40011 jeita_T4 [K]'                    = @{addr=40011; tipo='u16'}
  '40012 carga_bajo_T1 [mA]'              = @{addr=40012; tipo='u16'}
  '40013 carga_T1_T2 [mA]'                = @{addr=40013; tipo='u16'}
  '40014 carga_T2_T3 [mA]'                = @{addr=40014; tipo='u16'}
  '40015 carga_T3_T4 [mA]'                = @{addr=40015; tipo='u16'}
  '40016 carga_sobre_T4 [mA]'             = @{addr=40016; tipo='u16'}
  '40037 charge_parameters [hex]'         = @{addr=40037; tipo='u16'}
  '40037 jeita_enable (bit 0)'            = @{addr=40037; tipo='bit'; bit=0}
  '40038 corriente_carga_nominal [mA]'    = @{addr=40038; tipo='u16'}
  '40039 tension_carga_nominal [mV]'      = @{addr=40039; tipo='u16'}
  '40040 corriente_fin_carga [mA]'        = @{addr=40040; tipo='u16'}
  '40041 limite_tiempo_carga [s]'         = @{addr=40041; tipo='u16'}
  '40042 limite_tiempo_CV [s]'            = @{addr=40042; tipo='u16'}
  '40043 tension_panel_MPP [mV]'          = @{addr=40043; tipo='u16'}
  # ---- CALEFACTOR ----
  '40034 heater_umbral_cargando [K]'      = @{addr=40034; tipo='u16'}
  '40035 heater_umbral_descargando [K]'   = @{addr=40035; tipo='u16'}
  '40036 heater_options [hex]'            = @{addr=40036; tipo='u16'}
  '40036 heater_histeresis [K] (byte bajo)'= @{addr=40036; tipo='u8lo'}
  '40036 heater_enable (bit 8)'           = @{addr=40036; tipo='bit'; bit=8}
  # ---- COMUNICACIONES ----
  '40022 timeout_com_NCU [min]'           = @{addr=40022; tipo='u16'}
  '40029 watchdog_zigbee [min]'           = @{addr=40029; tipo='u16'}
  '41004 zigbee_config [hex]'             = @{addr=41004; tipo='u16'}
  '41004 zigbee_slave_id (byte bajo)'     = @{addr=41004; tipo='u8lo'}
  '41004 zigbee_apply (bit 8)'            = @{addr=41004; tipo='bit'; bit=8}
  '41006 rs485_config [hex]'              = @{addr=41006; tipo='u16'}
  '41006 rs485_slave_id (byte bajo)'      = @{addr=41006; tipo='u8lo'}
  '41006 rs485_apply (bit 8)'             = @{addr=41006; tipo='bit'; bit=8}
  '41070 zigbee_pan_id_bajo [u32]'        = @{addr=41070; tipo='u32'}
  '41072 zigbee_pan_id_alto [u32]'        = @{addr=41072; tipo='u32'}
  '41074 zigbee_encryption [hex]'         = @{addr=41074; tipo='u16'}
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
  '41106 east_pitch [m]'                  = @{addr=41106; tipo='f32'}
  '41018 tracker_options [hex]'           = @{addr=41018; tipo='u16'}
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
  '41068 safe_pos_options [hex]'          = @{addr=41068; tipo='u16'}
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
  '41040 motor_overcurrent_limit [mA]'    = @{addr=41040; tipo='u16'}
  '41041 mask_time_overcurrent [ms]'      = @{addr=41041; tipo='u16'}
  '41064 axis_block_det_time [s] (b.bajo)'= @{addr=41064; tipo='u8lo'}
  '41064 axis_block_retry [x0.1s] (b.alto)'= @{addr=41064; tipo='u8hi'}
  '41065 motor_fault_retries'             = @{addr=41065; tipo='u16'}
  '41066 lowspeed_det_time [s] (b.bajo)'  = @{addr=41066; tipo='u8lo'}
  '41066 lowspeed_umbral [%] (b.alto)'    = @{addr=41066; tipo='u8hi'}
  '41067 motor_speed_no_load [mdeg/s]'    = @{addr=41067; tipo='u16'}
  '41079 min_motor_off_time [ms]'         = @{addr=41079; tipo='u16'}
  '41080 pulse_resolution [pulsos]'       = @{addr=41080; tipo='u16'}
  '41093 duty_approach (b.bajo)'          = @{addr=41093; tipo='u8lo'}
  '41093 duty_max_manual (b.alto)'        = @{addr=41093; tipo='u8hi'}
  '41094 duty_max_auto (b.bajo)'          = @{addr=41094; tipo='u8lo'}
  '41094 duty_startup (b.alto)'           = @{addr=41094; tipo='u8hi'}
  '41095 ramp_acel (b.bajo)'              = @{addr=41095; tipo='u8lo'}
  '41095 ramp_decel (b.alto)'             = @{addr=41095; tipo='u8hi'}
  # ---- NIVELES DE SoC ----
  '41081 soc_critico_enter [%] (b.bajo)'  = @{addr=41081; tipo='u8lo'}
  '41081 soc_critico_exit [%] (b.alto)'   = @{addr=41081; tipo='u8hi'}
  '41082 soc_muy_bajo_enter [%] (b.bajo)' = @{addr=41082; tipo='u8lo'}
  '41082 soc_muy_bajo_exit [%] (b.alto)'  = @{addr=41082; tipo='u8hi'}
  '41083 soc_bajo_enter [%] (b.bajo)'     = @{addr=41083; tipo='u8lo'}
  '41083 soc_bajo_exit [%] (b.alto)'      = @{addr=41083; tipo='u8hi'}
  '41084 preservacion_high [%] (b.bajo)'  = @{addr=41084; tipo='u8lo'}
  '41084 preservacion_low [%] (b.alto)'   = @{addr=41084; tipo='u8hi'}
  '42001 dias_sin_carga_completa'         = @{addr=42001; tipo='u16'}
  '42005 soc_min_auto [%] (b.bajo)'       = @{addr=42005; tipo='u8lo'}
  '42005 soc_min_bootloader [%] (b.alto)' = @{addr=42005; tipo='u8hi'}
  '42006 vbat_min_bootloader [mV]'        = @{addr=42006; tipo='u16'}
}

# Registros de comando: exigen doble confirmacion y no entran en backups
$ADDR_COMANDO = @(40000, 40007, 40017, 40018, 42000)
$ADDR_TIEMPO  = @(40001, 40002, 40003, 40004, 40005, 40006)

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
$CRIT_AL1 = (1 -shl 2) -bor (1 -shl 4) -bor (1 -shl 14)                    # rango, seta, SoC critico <10%
$CRIT_AL2 = (1 -shl 4) -bor (1 -shl 5) -bor (1 -shl 8) -bor (1 -shl 15)   # corto, sobrecorriente, eje, driver

function Bits-Texto([int]$valor, [hashtable]$tabla) {
    $lista = @()
    foreach ($b in ($tabla.Keys | Sort-Object)) {
        if ($valor -band (1 -shl $b)) { $lista += $tabla[$b] }
    }
    return $lista
}

# Direccion: se envia el numero del PDF tal cual (asi funciona modbus-utils).
# Si alguna planta necesitara offset Modicon (-1 o -40001), cambiar aqui:
function Dir-Trama([int]$addrDoc) { return $addrDoc }

# ---------------------------------------------------------------------------
#  Cliente Modbus TCP
# ---------------------------------------------------------------------------
$script:Tcp = $null; $script:Stream = $null; $script:Tid = 0
$script:ConIp = ''; $script:ConPuerto = 0; $script:ConTimeout = 8000

function Modbus-Conectar([string]$ip, [int]$puerto, [int]$timeoutMs) {
    Modbus-Cerrar
    $c = New-Object System.Net.Sockets.TcpClient
    $ar = $c.BeginConnect($ip, $puerto, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne(5000)) { $c.Close(); throw "Sin conexion TCP a ${ip}:${puerto}" }
    $c.EndConnect($ar)
    $c.NoDelay = $true
    $script:Tcp = $c
    $script:Stream = $c.GetStream()
    $script:Stream.ReadTimeout = $timeoutMs
    $script:ConIp = $ip; $script:ConPuerto = $puerto; $script:ConTimeout = $timeoutMs
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

function Modbus-Transaccion([byte]$unit, [byte[]]$pdu) {
    if (-not $script:Stream) { throw "Sin conexion" }
    $script:Tid = ($script:Tid + 1) % 65535
    if ($script:Tid -eq 0) { $script:Tid = 1 }
    $len = $pdu.Length + 1
    $adu = New-Object byte[] (7 + $pdu.Length)
    $adu[0] = [byte](($script:Tid -shr 8) -band 0xFF); $adu[1] = [byte]($script:Tid -band 0xFF)
    $adu[2] = 0; $adu[3] = 0
    $adu[4] = [byte](($len -shr 8) -band 0xFF); $adu[5] = [byte]($len -band 0xFF)
    $adu[6] = $unit
    [Array]::Copy($pdu, 0, $adu, 7, $pdu.Length)
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
                throw ("{0} (0x{1:X2})" -f $nom, $exc)
            }
            return $cuerpo
        }
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
        'u16' {
            $v = Entero-Estricto $texto
            if ($v -lt 0 -or $v -gt 65535) { throw "fuera de rango U16" }
            return @{modo='fc16'; addr=$a; palabras=@($v); esperado=@($v)}
        }
        's16' {
            $v = Entero-Estricto $texto
            if ($v -lt -32768 -or $v -gt 32767) { throw "fuera de rango S16" }
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
            return @{modo='fc22'; addr=$a; and=0xFF00; or=$v; mascara=0x00FF; esperadoByte=$v}
        }
        'u8hi' {
            $v = Entero-Estricto $texto
            if ($v -lt 0 -or $v -gt 255) { throw "fuera de rango U8" }
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
function Parse-CsvPorTcu([string[]]$lineas) {
    $jobs = @(); $errores = @()
    $datos = @($lineas | Where-Object { "$_".Trim() -ne '' })
    if ($datos.Count -lt 2) { return @{jobs=@(); errores=@('CSV vacio (cabecera TCU;variable;valor + filas)')} }
    $sep = ';'
    if (-not $datos[0].Contains(';')) { $sep = ',' }
    for ($i = 1; $i -lt $datos.Count; $i++) {
        $c = $datos[$i].Split($sep)
        if ($c.Count -lt 3) { $errores += "linea $($i+1): faltan columnas (TCU${sep}variable${sep}valor)"; continue }
        try {
            $tcu = Val-Int $c[0] "linea $($i+1) TCU" 1 247
            $nombre = Resolver-Variable $c[1]
            # el valor puede llevar el separador decimal: reunir el resto de columnas
            $texto = (($c | Select-Object -Skip 2) -join $sep).Trim()
            if ($texto -eq '') { throw 'valor vacio' }
            $esc = Valor-A-Escritura $VARIABLES[$nombre] $texto
            $jobs += @{tcu=$tcu; nombre=$nombre; texto=$texto; esc=$esc}
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
#  Interfaz
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "TCU Toolbox v$VERSION_TOOLBOX - Sunner  (mapa $VERSION_MAPA)"
$form.Size = New-Object System.Drawing.Size(960, 820)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false

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
[void](LG $gbCon 'Timeout ms' 502 76)
$txtTo = TG $gbCon '8000' 578 22 50
[void](LG $gbCon 'Reintentos' 638 70)
$txtRet = TG $gbCon '3' 710 22 30

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

[void](LG $tabW 'TCU de' 10 52)
$txtWIni = TG $tabW '1' 62 22 45
[void](LG $tabW 'a' 116 12)
$txtWFin = TG $tabW '44' 131 22 45

[void](LG $tabW 'Filtro' 200 42)
$txtWFiltro = TG $tabW '' 244 22 170
$lblWFiltro = LG $tabW '' 424 180
$lblWFiltro.ForeColor = [System.Drawing.Color]::Gray

$btnPresetSave = New-Object System.Windows.Forms.Button
$btnPresetSave.Text = 'Guardar preset'
$btnPresetSave.Location = New-Object System.Drawing.Point(620, 18)
$btnPresetSave.Size = New-Object System.Drawing.Size(140, 28)
$tabW.Controls.Add($btnPresetSave)

$btnPresetLoad = New-Object System.Windows.Forms.Button
$btnPresetLoad.Text = 'Cargar preset'
$btnPresetLoad.Location = New-Object System.Drawing.Point(766, 18)
$btnPresetLoad.Size = New-Object System.Drawing.Size(140, 28)
$tabW.Controls.Add($btnPresetLoad)

$dgv = New-Object System.Windows.Forms.DataGridView
$dgv.Location = New-Object System.Drawing.Point(10, 55)
$dgv.Size = New-Object System.Drawing.Size(898, 228)
$dgv.AllowUserToAddRows = $true
$dgv.RowHeadersVisible = $false
$dgv.BackgroundColor = [System.Drawing.Color]::White
$colVar = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colVar.HeaderText = 'Variable'; $colVar.Width = 340
foreach ($k in $VARIABLES.Keys) { [void]$colVar.Items.Add($k) }
$colVal = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colVal.HeaderText = 'Nuevo valor'; $colVal.Width = 150
$colInfo = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colInfo.HeaderText = 'Registro / tipo'; $colInfo.Width = 382; $colInfo.ReadOnly = $true
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

$btnEscribir = New-Object System.Windows.Forms.Button
$btnEscribir.Text = 'ESCRIBIR'
$btnEscribir.Location = New-Object System.Drawing.Point(180, 292)
$btnEscribir.Size = New-Object System.Drawing.Size(120, 30)
$btnEscribir.BackColor = [System.Drawing.Color]::FromArgb(0,120,60)
$btnEscribir.ForeColor = [System.Drawing.Color]::White
$tabW.Controls.Add($btnEscribir)

$btnFallidas = New-Object System.Windows.Forms.Button
$btnFallidas.Text = 'Reintentar fallidas'
$btnFallidas.Location = New-Object System.Drawing.Point(310, 292)
$btnFallidas.Size = New-Object System.Drawing.Size(130, 30)
$btnFallidas.Enabled = $false
$tabW.Controls.Add($btnFallidas)

$btnCargarBackup = New-Object System.Windows.Forms.Button
$btnCargarBackup.Text = 'Backup JSON como preset'
$btnCargarBackup.Location = New-Object System.Drawing.Point(450, 292)
$btnCargarBackup.Size = New-Object System.Drawing.Size(175, 30)
$tabW.Controls.Add($btnCargarBackup)

$btnCsvTcu = New-Object System.Windows.Forms.Button
$btnCsvTcu.Text = 'CSV por TCU...'
$btnCsvTcu.Location = New-Object System.Drawing.Point(632, 292)
$btnCsvTcu.Size = New-Object System.Drawing.Size(118, 30)
$tabW.Controls.Add($btnCsvTcu)

$btnNvm = New-Object System.Windows.Forms.Button
$btnNvm.Text = 'GUARDAR EN NVM'
$btnNvm.Location = New-Object System.Drawing.Point(760, 292)
$btnNvm.Size = New-Object System.Drawing.Size(148, 30)
$btnNvm.BackColor = [System.Drawing.Color]::FromArgb(160,80,0)
$btnNvm.ForeColor = [System.Drawing.Color]::White
$tabW.Controls.Add($btnNvm)

# ============================ TAB LEER VARIABLE ============================
$tabL = New-Object System.Windows.Forms.TabPage
$tabL.Text = 'Leer variable'
$tabs.TabPages.Add($tabL)

[void](LG $tabL 'Filtro' 10 42)
$txtLFiltro = TG $tabL '' 54 22 160
$lblLFiltro = LG $tabL '' 222 130
$lblLFiltro.ForeColor = [System.Drawing.Color]::Gray

[void](LG $tabL 'Variable' 360 58)
$cbLVar = New-Object System.Windows.Forms.ComboBox
$cbLVar.Location = New-Object System.Drawing.Point(420, 21)
$cbLVar.Size = New-Object System.Drawing.Size(380, 22)
$cbLVar.DropDownStyle = 'DropDownList'
$tabL.Controls.Add($cbLVar)

$btnLAdd = New-Object System.Windows.Forms.Button
$btnLAdd.Text = 'Anadir'
$btnLAdd.Location = New-Object System.Drawing.Point(806, 19)
$btnLAdd.Size = New-Object System.Drawing.Size(102, 26)
$tabL.Controls.Add($btnLAdd)

# Rellena el combo aplicando el filtro; conserva la seleccion si sigue visible
# y autoselecciona cuando solo queda una coincidencia.
function Refrescar-FiltroLeer {
    $sel = $cbLVar.SelectedItem
    $todos = @(Nombres-Ordenados @($VARIABLES.Keys)) + @(Nombres-Ordenados @($ESTADO.Keys) | ForEach-Object { 'ESTADO ' + $_ })
    $coinciden = @(Filtrar-Nombres $todos $txtLFiltro.Text)
    $cbLVar.BeginUpdate()
    $cbLVar.Items.Clear()
    foreach ($k in $coinciden) { [void]$cbLVar.Items.Add($k) }
    $cbLVar.EndUpdate()
    if ($sel -and $cbLVar.Items.Contains($sel)) { $cbLVar.SelectedItem = $sel }
    elseif ($cbLVar.Items.Count -eq 1) { $cbLVar.SelectedIndex = 0 }
    if ("$($txtLFiltro.Text)".Trim()) { $lblLFiltro.Text = "$($coinciden.Count) de $($todos.Count)" }
    else { $lblLFiltro.Text = "$($todos.Count) variables" }
}

$txtLFiltro.Add_TextChanged({ Refrescar-FiltroLeer })
Refrescar-FiltroLeer

# lista de variables a leer (varias a la vez, como la tabla de Escribir)
$lbLSel = New-Object System.Windows.Forms.ListBox
$lbLSel.Location = New-Object System.Drawing.Point(10, 50)
$lbLSel.Size = New-Object System.Drawing.Size(500, 58)
$lbLSel.IntegralHeight = $false
$tabL.Controls.Add($lbLSel)

$btnLQuitar = New-Object System.Windows.Forms.Button
$btnLQuitar.Text = 'Quitar'
$btnLQuitar.Location = New-Object System.Drawing.Point(516, 50)
$btnLQuitar.Size = New-Object System.Drawing.Size(72, 26)
$tabL.Controls.Add($btnLQuitar)

$btnLVaciar = New-Object System.Windows.Forms.Button
$btnLVaciar.Text = 'Vaciar'
$btnLVaciar.Location = New-Object System.Drawing.Point(516, 82)
$btnLVaciar.Size = New-Object System.Drawing.Size(72, 26)
$tabL.Controls.Add($btnLVaciar)

[void](LG $tabL 'TCU de' 604 50 56)
$txtLIni = TG $tabL '1' 654 52 40
[void](LG $tabL 'a' 700 10 56)
$txtLFin = TG $tabL '44' 712 52 40

$btnLeer = New-Object System.Windows.Forms.Button
$btnLeer.Text = 'LEER'
$btnLeer.Location = New-Object System.Drawing.Point(766, 49)
$btnLeer.Size = New-Object System.Drawing.Size(112, 26)
$btnLeer.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnLeer.ForeColor = [System.Drawing.Color]::White
$tabL.Controls.Add($btnLeer)

$btnLCsv = New-Object System.Windows.Forms.Button
$btnLCsv.Text = 'Exportar CSV'
$btnLCsv.Location = New-Object System.Drawing.Point(766, 82)
$btnLCsv.Size = New-Object System.Drawing.Size(112, 26)
$btnLCsv.Enabled = $false
$tabL.Controls.Add($btnLCsv)

$btnLAdd.Add_Click({
    $s = $cbLVar.SelectedItem
    if ($s -and -not $lbLSel.Items.Contains($s)) { [void]$lbLSel.Items.Add($s) }
})
$cbLVar.Add_KeyDown({ param($s,$e) if ($e.KeyCode -eq 'Enter') { $btnLAdd.PerformClick() } })
$btnLQuitar.Add_Click({ if ($lbLSel.SelectedIndex -ge 0) { $lbLSel.Items.RemoveAt($lbLSel.SelectedIndex) } })
$btnLVaciar.Add_Click({ $lbLSel.Items.Clear() })
$lbLSel.Add_DoubleClick({ if ($lbLSel.SelectedIndex -ge 0) { $lbLSel.Items.RemoveAt($lbLSel.SelectedIndex) } })

$lvL = New-Object System.Windows.Forms.ListView
$lvL.Location = New-Object System.Drawing.Point(10, 114)
$lvL.Size = New-Object System.Drawing.Size(898, 246)
$lvL.View = 'Details'; $lvL.FullRowSelect = $true; $lvL.GridLines = $true
[void]$lvL.Columns.Add('TCU', 70)
[void]$lvL.Columns.Add('Valor', 200)
[void]$lvL.Columns.Add('Estado', 600)
$tabL.Controls.Add($lvL)

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

[void](LG $tabD 'Backup NCU de' 250 95 340)
$txtBIni = TG $tabD '1' 348 337 40
[void](LG $tabD 'a' 394 10 340)
$txtBFin = TG $tabD '44' 406 337 40

$btnBackupNcu = New-Object System.Windows.Forms.Button
$btnBackupNcu.Text = 'BACKUP NCU (un JSON por TCU)...'
$btnBackupNcu.Location = New-Object System.Drawing.Point(458, 335)
$btnBackupNcu.Size = New-Object System.Drawing.Size(230, 28)
$tabD.Controls.Add($btnBackupNcu)

# ============================ TAB DIAGNOSTICO ============================
$tabG = New-Object System.Windows.Forms.TabPage
$tabG.Text = 'Diagnostico'
$tabs.TabPages.Add($tabG)

[void](LG $tabG 'TCU de' 10 52)
$txtGIni = TG $tabG '1' 62 22 45
[void](LG $tabG 'a' 116 12)
$txtGFin = TG $tabG '44' 131 22 45

$btnDiag = New-Object System.Windows.Forms.Button
$btnDiag.Text = 'DIAGNOSTICAR'
$btnDiag.Location = New-Object System.Drawing.Point(200, 18)
$btnDiag.Size = New-Object System.Drawing.Size(140, 28)
$btnDiag.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnDiag.ForeColor = [System.Drawing.Color]::White
$tabG.Controls.Add($btnDiag)

[void](LG $tabG 'NCUs' 350 40)
$txtGNcus = TG $tabG '' 392 22 66
$txtGNcus.Text = ''

$lblGResumen = New-Object System.Windows.Forms.Label
$lblGResumen.Text = ''
$lblGResumen.Location = New-Object System.Drawing.Point(470, 24)
$lblGResumen.Size = New-Object System.Drawing.Size(190, 20)
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

$lvG = New-Object System.Windows.Forms.ListView
$lvG.Location = New-Object System.Drawing.Point(10, 55)
$lvG.Size = New-Object System.Drawing.Size(898, 305)
$lvG.View = 'Details'; $lvG.FullRowSelect = $true; $lvG.GridLines = $true
[void]$lvG.Columns.Add('NCU', 45)
[void]$lvG.Columns.Add('TCU', 45)
[void]$lvG.Columns.Add('Salud', 65)
[void]$lvG.Columns.Add('Modo', 65)
[void]$lvG.Columns.Add('Tilt real', 58)
[void]$lvG.Columns.Add('Objetivo', 58)
[void]$lvG.Columns.Add('Dif', 46)
[void]$lvG.Columns.Add('SoC', 46)
[void]$lvG.Columns.Add('Alarmas / notas', 450)
$tabG.Controls.Add($lvG)

# ============================ TAB FLOTA ============================
$tabF = New-Object System.Windows.Forms.TabPage
$tabF.Text = 'Flota'
$tabs.TabPages.Add($tabF)

$gbAud = New-Object System.Windows.Forms.GroupBox
$gbAud.Text = ' Auditoria contra preset de referencia (lista solo las desviaciones) '
$gbAud.Location = New-Object System.Drawing.Point(10, 6)
$gbAud.Size = New-Object System.Drawing.Size(898, 182)
$tabF.Controls.Add($gbAud)

[void](LG $gbAud 'TCU de' 10 52)
$txtAIni = TG $gbAud '1' 62 22 40
[void](LG $gbAud 'a' 108 10)
$txtAFin = TG $gbAud '44' 120 22 40

$btnPresetRef = New-Object System.Windows.Forms.Button
$btnPresetRef.Text = 'Preset referencia...'
$btnPresetRef.Location = New-Object System.Drawing.Point(172, 19)
$btnPresetRef.Size = New-Object System.Drawing.Size(140, 26)
$gbAud.Controls.Add($btnPresetRef)

$lblPresetRef = LG $gbAud '(sin preset de referencia)' 320 300
$lblPresetRef.ForeColor = [System.Drawing.Color]::Gray

$btnAud = New-Object System.Windows.Forms.Button
$btnAud.Text = 'AUDITAR'
$btnAud.Location = New-Object System.Drawing.Point(640, 18)
$btnAud.Size = New-Object System.Drawing.Size(115, 28)
$btnAud.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnAud.ForeColor = [System.Drawing.Color]::White
$gbAud.Controls.Add($btnAud)

$btnAudCsv = New-Object System.Windows.Forms.Button
$btnAudCsv.Text = 'CSV'
$btnAudCsv.Location = New-Object System.Drawing.Point(765, 18)
$btnAudCsv.Size = New-Object System.Drawing.Size(110, 28)
$btnAudCsv.Enabled = $false
$gbAud.Controls.Add($btnAudCsv)

$lvA = New-Object System.Windows.Forms.ListView
$lvA.Location = New-Object System.Drawing.Point(10, 52)
$lvA.Size = New-Object System.Drawing.Size(878, 120)
$lvA.View = 'Details'; $lvA.FullRowSelect = $true; $lvA.GridLines = $true
[void]$lvA.Columns.Add('TCU', 50)
[void]$lvA.Columns.Add('Variable', 330)
[void]$lvA.Columns.Add('Esperado', 150)
[void]$lvA.Columns.Add('Leido', 150)
[void]$lvA.Columns.Add('Nota', 190)
$gbAud.Controls.Add($lvA)

$gbInvF = New-Object System.Windows.Forms.GroupBox
$gbInvF.Text = ' Inventario de flota (FW, numero de serie, MAC Xbee por rango) '
$gbInvF.Location = New-Object System.Drawing.Point(10, 194)
$gbInvF.Size = New-Object System.Drawing.Size(898, 168)
$tabF.Controls.Add($gbInvF)

[void](LG $gbInvF 'TCU de' 10 52)
$txtVIni = TG $gbInvF '1' 62 22 40
[void](LG $gbInvF 'a' 108 10)
$txtVFin = TG $gbInvF '44' 120 22 40

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
$btnInvFCsv.Location = New-Object System.Drawing.Point(765, 18)
$btnInvFCsv.Size = New-Object System.Drawing.Size(110, 28)
$btnInvFCsv.Enabled = $false
$gbInvF.Controls.Add($btnInvFCsv)

$lvV = New-Object System.Windows.Forms.ListView
$lvV.Location = New-Object System.Drawing.Point(10, 52)
$lvV.Size = New-Object System.Drawing.Size(878, 106)
$lvV.View = 'Details'; $lvV.FullRowSelect = $true; $lvV.GridLines = $true
[void]$lvV.Columns.Add('TCU', 45)
[void]$lvV.Columns.Add('Num. serie', 170)
[void]$lvV.Columns.Add('MAC Xbee', 140)
[void]$lvV.Columns.Add('FW', 100)
[void]$lvV.Columns.Add('FW fabrica', 100)
[void]$lvV.Columns.Add('HW PCBA', 70)
[void]$lvV.Columns.Add('Fecha fab.', 90)
[void]$lvV.Columns.Add('Nota', 150)
$gbInvF.Controls.Add($lvV)

# ============================ TAB UTILIDADES ============================
$tabU = New-Object System.Windows.Forms.TabPage
$tabU.Text = 'Utilidades'
$tabs.TabPages.Add($tabU)

$gbSync = New-Object System.Windows.Forms.GroupBox
$gbSync.Text = ' Sincronizar fecha/hora con el PC (40001-40006 + 40007 bits 0/1) '
$gbSync.Location = New-Object System.Drawing.Point(10, 12)
$gbSync.Size = New-Object System.Drawing.Size(898, 62)
$tabU.Controls.Add($gbSync)

[void](LG $gbSync 'TCU de' 10 52)
$txtSIni = TG $gbSync '1' 62 22 45
[void](LG $gbSync 'a' 116 12)
$txtSFin = TG $gbSync '44' 131 22 45

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

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(10, 746)
$lblLog.Size = New-Object System.Drawing.Size(800, 20)
$lblLog.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblLog)

# ---------------------------------------------------------------------------
#  Estado global, consola y log automatico a fichero
# ---------------------------------------------------------------------------
$script:Fallidas = New-Object System.Collections.ArrayList
$script:UltimaLectura = @()
$script:UltimoVolcado = @()
$script:UltimoDiag = @()
$script:UltimaIdent = @()
$script:UltimaAud = @()
$script:UltimoInv = @()
$script:PresetRef = $null
$script:PresetRefNombre = ''
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

function Con([string]$t, $color) {
    $rtb.SelectionStart = $rtb.TextLength; $rtb.SelectionLength = 0
    $rtb.SelectionColor = $color
    $rtb.AppendText($t + "`r`n")
    $rtb.SelectionColor = $rtb.ForeColor
    $rtb.ScrollToCaret()
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $t) -Encoding UTF8 } catch {}
    }
    [System.Windows.Forms.Application]::DoEvents()
}

$BOTONES_ACCION = @($btnEscribir, $btnFallidas, $btnNvm, $btnLeer, $btnVolcar, $btnDiag, $btnSync, $btnIdent,
                    $btnPresetSave, $btnPresetLoad, $btnCargarBackup, $btnLCsv, $btnDCsv, $btnBackupJson,
                    $btnComparar, $btnGCsv, $btnGJson, $btnICsv,
                    $btnCsvTcu, $btnBackupNcu, $btnAud, $btnAudCsv, $btnPresetRef, $btnInvF, $btnInvFCsv)

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
        $btnGJson.Enabled      = ($script:UltimoDiag.Count -gt 0)
        $btnICsv.Enabled       = ($script:UltimaIdent.Count -gt 0)
        $btnAudCsv.Enabled     = ($script:UltimaAud.Count -gt 0)
        $btnInvFCsv.Enabled    = ($script:UltimoInv.Count -gt 0)
    }
    $btnCancelar.Enabled = $ocupada
    [System.Windows.Forms.Application]::DoEvents()
}

# Envuelve una operacion larga: guarda contra reentrada (DoEvents), habilita
# CANCELAR, y cierra la conexion Modbus pase lo que pase.
function Lanzar([scriptblock]$accion) {
    if ($script:Ocupado) { Con 'Hay una operacion en curso (usa CANCELAR para abortarla).' ([System.Drawing.Color]::Orange); return }
    $script:Ocupado = $true; $script:Cancelar = $false
    Set-UIOcupada $true
    try { & $accion }
    catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon) }
    finally {
        Modbus-Cerrar
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
    if ($ip -eq '(planta)') {
        $p = $null
        if ($cbPlanta.SelectedItem) { $p = $PLANTAS[$cbPlanta.SelectedItem] }
        if (-not ($p -and $p.ncus)) { throw "'(planta)' requiere una entrada (PLANTA completa) seleccionada" }
        return @{ip='(planta)'; puerto=$null; gws=$null; multi=$p.ncus; etiqueta='PLANTA'; to=$to; reint=$reint}
    }
    $pt = $txtPort.Text.Trim()
    if ($pt -eq 'auto') {
        $p = $null
        if ($cbPlanta.SelectedItem) { $p = $PLANTAS[$cbPlanta.SelectedItem] }
        if (-not ($p -and $p.gws) -or ($p.ip -ne $ip)) {
            throw "puerto 'auto' requiere una entrada (auto) seleccionada y su IP sin modificar"
        }
        return @{ip=$ip; puerto=$null; gws=$p.gws; etiqueta='auto'; to=$to; reint=$reint}
    }
    $puerto = Val-Int $pt 'Puerto' 1 65535
    return @{ip=$ip; puerto=$puerto; gws=$null; etiqueta="$puerto"; to=$to; reint=$reint}
}

# Divide una lista de TCUs en segmentos consecutivos por puerto de gateway.
# Con puerto fijo devuelve un unico segmento; en modo 'auto' resuelve el
# puerto de cada TCU con los rangos de la NCU (adios al error de puerto) y
# avisa de los TCUs que no caen en ningun gateway.
function Plan-Segmentos([int[]]$tcus, [hashtable]$cx) {
    if ($cx.multi) { throw "la entrada (PLANTA completa) solo esta soportada en Diagnostico; elige una NCU concreta" }
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

function Rango-Tcus([string]$tIni, [string]$tFin, [string]$etiqueta) {
    $ini = Val-Int $tIni "$etiqueta TCU inicial" 1 247
    $fin = Val-Int $tFin "$etiqueta TCU final" 1 247
    if ($fin -lt $ini) { throw "$etiqueta : el TCU final ($fin) es menor que el inicial ($ini)" }
    return @($ini..$fin)
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
    $p = $PLANTAS[$cbPlanta.SelectedItem]
    if ($p -and $p.ncus) {
        # planta completa: solo Diagnostico; rangos y puertos por NCU automaticos
        $txtIp.Text = '(planta)'; $txtPort.Text = 'auto'
        Con "PLANTA completa seleccionada ($(@($p.ncus).Count) NCUs): usa DIAGNOSTICAR; el filtro NCUs admite '1,3-5' (vacio = todas)." ([System.Drawing.Color]::SteelBlue)
        return
    }
    if ($p) {
        $txtIp.Text = $p.ip
        if ($p.gws) { $txtPort.Text = 'auto' } else { $txtPort.Text = "$($p.puerto)" }
        $txtWIni.Text = "$($p.ini)"; $txtWFin.Text = "$($p.fin)"
        $txtLIni.Text = "$($p.ini)"; $txtLFin.Text = "$($p.fin)"
        $txtGIni.Text = "$($p.ini)"; $txtGFin.Text = "$($p.fin)"
        $txtSIni.Text = "$($p.ini)"; $txtSFin.Text = "$($p.fin)"
        $txtAIni.Text = "$($p.ini)"; $txtAFin.Text = "$($p.fin)"
        $txtVIni.Text = "$($p.ini)"; $txtVFin.Text = "$($p.fin)"
        $txtBIni.Text = "$($p.ini)"; $txtBFin.Text = "$($p.fin)"
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

function Escribir-EnTcus([int[]]$tcus) {
    $vars = @(Recoger-Variables)
    if ($vars.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('No hay variables con valor.','Aviso'); return }
    $cx = Params-Conexion
    $resumen = ($vars | ForEach-Object {
        $hex = if ($_.esc.modo -eq 'fc16') { ($_.esc.palabras | ForEach-Object { '{0:X4}' -f $_ }) -join ' ' }
               else { 'AND {0:X4} OR {1:X4}' -f $_.esc.and, $_.esc.or }
        "  $($_.nombre) = $($_.texto)   [$hex]"
    }) -join "`r`n"
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Se escribiran $($vars.Count) variables en $($tcus.Count) TCUs de $($cx.ip):$($cx.puerto):`r`n`r`n$resumen`r`n`r`nContinuar?",
        'Confirmar', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }

    $peligrosas = @($vars | Where-Object { $ADDR_COMANDO -contains $_.addr })
    if ($peligrosas.Count -gt 0) {
        $lista = ($peligrosas | ForEach-Object { "  $($_.nombre)" }) -join "`r`n"
        $r2 = [System.Windows.Forms.MessageBox]::Show(
            "ATENCION: vas a escribir registros de COMANDO que pueden mover el seguidor o cambiar su modo:`r`n`r`n$lista`r`n`r`nSeguro que quieres continuar?",
            'REGISTROS DE COMANDO', 'YesNo', 'Stop')
        if ($r2 -ne 'Yes') { return }
    }

    $script:Fallidas.Clear(); $btnFallidas.Enabled = $false
    $ok = 0
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Escribiendo $($vars.Count) variables en $($tcus.Count) TCUs  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    $segs = @(Plan-Segmentos $tcus $cx)
    if ($segs.Count -eq 0) { Con 'Ningun TCU cae en los gateways de la NCU.' ([System.Drawing.Color]::Orange); return }
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true
        if ($cx.gws) { Con ("-- gateway {0}:{1}  ({2} TCUs)" -f $cx.ip, $seg.puerto, $seg.tcus.Count) ([System.Drawing.Color]::SteelBlue) }
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { $segOk = $false; Con "ERROR de conexion ($($cx.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $fallo = $null; $hecho = $true
            if (-not $segOk) { $hecho = $false; $fallo = "sin conexion ($($cx.ip):$($seg.puerto))" }
            else {
                foreach ($v in $vars) {
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
                        } catch {
                            $fallo = "$($v.nombre): $_"
                            if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                            Start-Sleep -Milliseconds (300 * $i)
                        }
                    }
                    if (-not $hecho) { break }
                }
            }
            if ($script:Cancelar -and -not $hecho) { break }
            if (-not $hecho) {
                [void]$script:Fallidas.Add($tcu)
                Con ("TCU {0,3}  FALLO   {1}" -f $tcu, $fallo) ([System.Drawing.Color]::Salmon)
            } else {
                $ok++
                Con ("TCU {0,3}  OK" -f $tcu) ([System.Drawing.Color]::LightGreen)
            }
        }
    }
    Modbus-Cerrar
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "OK: $ok   Fallidas: $($script:Fallidas.Count)" ([System.Drawing.Color]::SteelBlue)
    if ($script:Fallidas.Count -gt 0) {
        Con ("TCUs fallidas: " + ($script:Fallidas -join ', ')) ([System.Drawing.Color]::Salmon)
    }
}

$btnEscribir.Add_Click({ Lanzar { Escribir-EnTcus (Rango-Tcus $txtWIni.Text $txtWFin.Text 'Escribir') } })
$btnFallidas.Add_Click({ Lanzar { if ($script:Fallidas.Count -gt 0) { Escribir-EnTcus @($script:Fallidas | ForEach-Object { [int]$_ }) } } })

$btnNvm.Add_Click({ Lanzar {
    if ($script:Fallidas.Count -gt 0) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Hay $($script:Fallidas.Count) TCUs con fallos.`r`nGuardar en NVM AUN ASI?", 'Atencion', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    $cx = Params-Conexion
    $tcus = Rango-Tcus $txtWIni.Text $txtWFin.Text 'NVM'
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Guardar configuracion en NVM (40007 bit 15) en TCUs $($tcus[0]) a $($tcus[-1]) de $($cx.ip):$($cx.etiqueta)?",
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
                    try { FC22-Mascara $tcu 40007 0x7FFF 0x8000; $hecho = $true }
                    catch {
                        if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                        Start-Sleep -Milliseconds (300 * $i)
                    }
                }
            }
            if ($hecho) { Con ("TCU {0,3}  NVM guardado" -f $tcu) ([System.Drawing.Color]::LightGreen) }
            else        { Con ("TCU {0,3}  NVM FALLO" -f $tcu) ([System.Drawing.Color]::Salmon) }
        }
    }
    Modbus-Cerrar
} })

# ------------------------- presets y backups -------------------------
$btnPresetSave.Add_Click({
    $vars = @(Recoger-Variables)
    if ($vars.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('La tabla esta vacia.','Aviso'); return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Preset TCU (*.json)|*.json'
    $dlg.FileName = 'preset_tcu.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $obj = @($vars | ForEach-Object { @{variable=$_.nombre; valor=$_.texto} })
    ConvertTo-Json $obj | Set-Content $dlg.FileName -Encoding UTF8
    Con "Preset guardado: $($dlg.FileName)  ($($vars.Count) variables)" ([System.Drawing.Color]::SteelBlue)
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
    # Solo variables de configuracion: fuera comandos y fecha/hora de entrada
    $pares = @()
    foreach ($v in $obj.variables) {
        if (-not $VARIABLES.Contains([string]$v.variable)) { continue }
        $def = $VARIABLES[[string]$v.variable]
        if ($ADDR_COMANDO -contains $def.addr) { continue }
        if ($ADDR_TIEMPO -contains $def.addr) { continue }
        if ("$($v.valor)" -eq '') { continue }
        $pares += [pscustomobject]@{variable=$v.variable; valor=$v.valor}
    }
    $n = Cargar-FilasEnGrid $pares
    Con "Backup de TCU $($obj.tcu) ($($obj.fecha)) cargado como preset: $n variables de configuracion (comandos y fecha/hora excluidos)" ([System.Drawing.Color]::SteelBlue)
})

# ------------------------- logica LEER VARIABLE -------------------------
function Def-DeLectura([string]$sel) {
    if ($sel -like 'ESTADO *') { return $ESTADO[$sel.Substring(7)] }
    return $VARIABLES[$sel]
}

$btnLeer.Add_Click({ Lanzar {
    # lista de variables: las anadidas, o la seleccionada en el combo si la lista esta vacia
    $nombres = @($lbLSel.Items)
    if ($nombres.Count -eq 0 -and $cbLVar.SelectedItem) { $nombres = @([string]$cbLVar.SelectedItem) }
    if ($nombres.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Elige una variable (o anade varias a la lista).','Aviso'); return }
    $defs = @($nombres | ForEach-Object { @{nombre=[string]$_; vdef=(Def-DeLectura $_)} })
    $cx = Params-Conexion
    $tcus = Rango-Tcus $txtLIni.Text $txtLFin.Text 'Leer'
    $lvL.Items.Clear(); $lvL.Columns.Clear(); $script:UltimaLectura = @()
    [void]$lvL.Columns.Add('TCU', 48)
    foreach ($d in $defs) { [void]$lvL.Columns.Add($d.nombre, [math]::Max(110, [math]::Min(220, [int](790 / $defs.Count)))) }
    [void]$lvL.Columns.Add('Estado', 130)
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Leyendo $($defs.Count) variable(s) en TCUs $($tcus[0])-$($tcus[-1])  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    $valores = @{}
    foreach ($d in $defs) { $valores[$d.nombre] = @{} }
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true; $errSeg = ''
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { $segOk = $false; $errSeg = "sin conexion ($($cx.ip):$($seg.puerto))"; Con "ERROR: $errSeg : $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $fila = [ordered]@{TCU=[int]$tcu}
            $errores = 0; $err = $errSeg
            foreach ($d in $defs) {
                if ($script:Cancelar) { break }
                $val = $null
                if ($segOk) {
                    for ($i = 1; $i -le $cx.reint -and $null -eq $val; $i++) {
                        try { $val = Leer-Decodificado $tcu $d.vdef }
                        catch {
                            $err = "$_"
                            if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                            Start-Sleep -Milliseconds (200 * $i)
                        }
                    }
                }
                if ($null -ne $val) {
                    $fila[$d.nombre] = $val
                    if (-not $valores[$d.nombre].ContainsKey($val)) { $valores[$d.nombre][$val] = 0 }
                    $valores[$d.nombre][$val]++
                } else { $fila[$d.nombre] = ''; $errores++ }
            }
            $estado = 'OK'
            if ($errores -gt 0) { $estado = "$errores fallos: $err" }
            $fila['Estado'] = $estado
            $item = New-Object System.Windows.Forms.ListViewItem("$tcu")
            foreach ($d in $defs) {
                $v = $fila[$d.nombre]
                if ("$v" -eq '') { $v = '-' }
                [void]$item.SubItems.Add("$v")
            }
            [void]$item.SubItems.Add($estado)
            if ($errores -gt 0) { $item.ForeColor = [System.Drawing.Color]::Firebrick }
            $lvL.Items.Add($item) | Out-Null
            $script:UltimaLectura += [pscustomobject]$fila
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    Modbus-Cerrar
    foreach ($d in $defs) {
        $v = $valores[$d.nombre]
        if ($v.Count -eq 1) {
            Con ("  {0}: todas coinciden = {1}" -f $d.nombre, @($v.Keys)[0]) ([System.Drawing.Color]::LightGreen)
        } elseif ($v.Count -gt 1) {
            Con ("  ATENCION {0}: {1} valores distintos:" -f $d.nombre, $v.Count) ([System.Drawing.Color]::Orange)
            foreach ($k in $v.Keys) { Con ("     {0}  en {1} TCUs" -f $k, $v[$k]) ([System.Drawing.Color]::Orange) }
        }
    }
} })

$btnLCsv.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'lectura_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:UltimaLectura | Export-Csv $dlg.FileName -NoTypeInformation -Encoding UTF8
        Con "CSV exportado: $($dlg.FileName)" ([System.Drawing.Color]::SteelBlue)
    }
})

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
    [void]$campos.Add([pscustomobject]@{Campo='Fecha de fabricacion';      Valor=("{0}-{1:00}-{2:00}" -f $w[26], (($w[25] -shr 8) -band 0xFF), ($w[25] -band 0xFF))})
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
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'identidad_tcu' + $txtITcu.Text + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:UltimaIdent | Export-Csv $dlg.FileName -NoTypeInformation -Encoding UTF8
        Con "CSV exportado: $($dlg.FileName)" ([System.Drawing.Color]::SteelBlue)
    }
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
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'volcado_tcu' + $txtDTcu.Text + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:UltimoVolcado | Export-Csv $dlg.FileName -NoTypeInformation -Encoding UTF8
        Con "CSV exportado: $($dlg.FileName)" ([System.Drawing.Color]::SteelBlue)
    }
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
    $r2 = FC03-Leer $tcu (Dir-Trama 30094) 5    # vbat, ibat, soc/soh, tbat, tpcb
    $r3 = FC03-Leer $tcu (Dir-Trama 30111) 2    # tilt, target

    $al1 = $r1[1]; $al2 = $r1[2]; $al3 = $r1[3]; $al4 = $r1[4]; $st = $r1[5]
    $ibat = $r2[1]; if ($ibat -gt 32767) { $ibat -= 65536 }
    $tbat = $r2[3]; if ($tbat -gt 32767) { $tbat -= 65536 }
    $tpcb = $r2[4]; if ($tpcb -gt 32767) { $tpcb -= 65536 }
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
        SoC = ($r2[2] -band 0xFF); SoH = (($r2[2] -shr 8) -band 0xFF)
        Vbat_mV = $r2[0]; Ibat_mA = $ibat
        Tbat_C = [math]::Round($tbat/10.0, 1); Tpcb_C = [math]::Round($tpcb/10.0, 1)
        Alarmas = (($alarmas + $notas) -join '; ')
        main_status = ("0x{0:X4}" -f $r1[0]); alarmas_1 = ("0x{0:X4}" -f $al1); alarmas_2 = ("0x{0:X4}" -f $al2)
        alarmas_3 = ("0x{0:X4}" -f $al3); alarmas_4 = ("0x{0:X4}" -f $al4); system_status = ("0x{0:X4}" -f $st)
    }
}

$btnDiag.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $lvG.Items.Clear(); $script:UltimoDiag = @(); $lblGResumen.Text = ''
    # trabajos: una entrada por NCU (planta completa) o una sola (modo normal)
    $trabajos = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    if ($cx.multi) {
        $filtro = Parse-ListaNums $txtGNcus.Text
        foreach ($n in $cx.multi) {
            if ($filtro -and -not ($filtro -contains [int]$n.ncu)) { continue }
            $lt = @()
            foreach ($g in $n.gws) { $lt += @([int]$g.ini..[int]$g.fin) }
            $lt = @($lt | Sort-Object -Unique)
            $trabajos += ,@{ncu=[int]$n.ncu; ip=$n.ip; tcus=$lt
                cx=@{ip=$n.ip; puerto=$null; gws=$n.gws; multi=$null; etiqueta='auto'; to=$cx.to; reint=$cx.reint}}
        }
        if ($trabajos.Count -eq 0) { Con 'El filtro de NCUs no coincide con ninguna NCU de la planta.' ([System.Drawing.Color]::Orange); return }
        $totTcus = 0; foreach ($tr in $trabajos) { $totTcus += @($tr.tcus).Count }
        Con "Diagnostico de PLANTA: $($trabajos.Count) NCUs, $totTcus TCUs (rangos por NCU automaticos)" ([System.Drawing.Color]::SteelBlue)
    } else {
        $tcus = Rango-Tcus $txtGIni.Text $txtGFin.Text 'Diagnostico'
        $trabajos += ,@{ncu=$null; ip=$cx.ip; tcus=$tcus; cx=$cx}
        Con "Diagnostico de TCUs $($tcus[0])-$($tcus[-1])  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    }
    $nOk = 0; $nAviso = 0; $nAlarma = 0; $nOff = 0
    foreach ($tr in $trabajos) {
    if ($script:Cancelar) { break }
    if ($null -ne $tr.ncu) { Con ("--- NCU{0}  ({1})  TCUs {2}-{3} ---" -f $tr.ncu, $tr.ip, $tr.tcus[0], $tr.tcus[-1]) ([System.Drawing.Color]::SteelBlue) }
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
                TCU=[int]$tcu; Salud='OFFLINE'; Modo=''; Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''
                Vbat_mV=''; Ibat_mA=''; Tbat_C=''; Tpcb_C=''; Alarmas=$err
                main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''
            }
        }
        $etiquetaNcu = ''
        if ($null -ne $tr.ncu) { $etiquetaNcu = "$($tr.ncu)" }
        $d | Add-Member -NotePropertyName NCU -NotePropertyValue $etiquetaNcu -Force
        $item = New-Object System.Windows.Forms.ListViewItem($etiquetaNcu)
        foreach ($c in @($d.TCU, $d.Salud, $d.Modo, $d.Tilt, $d.Objetivo, $d.Dif, $d.SoC, $d.Alarmas)) {
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
    Modbus-Cerrar
    $lblGResumen.Text = "OK: $nOk  Aviso: $nAviso  Alarma: $nAlarma  Off: $nOff"
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Diagnostico: OK $nOk | AVISO $nAviso | ALARMA $nAlarma | OFFLINE $nOff" ([System.Drawing.Color]::SteelBlue)
} })

$btnGCsv.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'diagnostico_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:UltimoDiag | Export-Csv $dlg.FileName -NoTypeInformation -Encoding UTF8
        Con "CSV exportado: $($dlg.FileName)" ([System.Drawing.Color]::SteelBlue)
    }
})

$btnGJson.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'JSON (*.json)|*.json'
    $dlg.FileName = 'diagnostico_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $obj = [ordered]@{
        tipo    = 'diagnostico_tcu'
        mapa    = $VERSION_MAPA
        toolbox = $VERSION_TOOLBOX
        planta  = Nombre-Planta
        ip      = $txtIp.Text.Trim()
        puerto  = $txtPort.Text.Trim()
        fecha   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        tcus    = @($script:UltimoDiag)
    }
    ConvertTo-Json $obj -Depth 5 | Set-Content $dlg.FileName -Encoding UTF8
    Con "JSON exportado: $($dlg.FileName)" ([System.Drawing.Color]::SteelBlue)
})

# ------------------------- SINCRONIZAR RELOJ -------------------------
$btnSync.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $tcus = Rango-Tcus $txtSIni.Text $txtSFin.Text 'Sincronizar'
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
                    Con ("TCU {0,3}  OK  reloj = {1}" -f $tcu, $reloj) ([System.Drawing.Color]::LightGreen)
                } catch {
                    Con ("TCU {0,3}  OK  (reloj no verificable: {1})" -f $tcu, $_) ([System.Drawing.Color]::LightGreen)
                }
            } else {
                Con ("TCU {0,3}  OK" -f $tcu) ([System.Drawing.Color]::LightGreen)
            }
        } else {
            $ko++
            Con ("TCU {0,3}  FALLO  {1}" -f $tcu, $fallo) ([System.Drawing.Color]::Salmon)
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
    $tcus = @($jobs | ForEach-Object { $_.tcu } | Sort-Object -Unique)
    $r = [System.Windows.Forms.MessageBox]::Show(
        "CSV: $($jobs.Count) escrituras en $($tcus.Count) TCUs de $($cx.ip):$($cx.etiqueta)" +
        $(if ($res.errores.Count -gt 0) { "`r`n($($res.errores.Count) lineas con error se saltan - ver consola)" } else { '' }) +
        "`r`n`r`nContinuar?", 'Confirmar CSV por TCU', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $peligro = @($jobs | Where-Object { $ADDR_COMANDO -contains $VARIABLES[$_.nombre].addr })
    if ($peligro.Count -gt 0) {
        $r2 = [System.Windows.Forms.MessageBox]::Show(
            "ATENCION: el CSV toca $($peligro.Count) registros de COMANDO. Seguro?",
            'REGISTROS DE COMANDO', 'YesNo', 'Stop')
        if ($r2 -ne 'Yes') { return }
    }
    $porTcu = @{}
    foreach ($j in $jobs) { if (-not $porTcu.ContainsKey($j.tcu)) { $porTcu[$j.tcu] = @() }; $porTcu[$j.tcu] += ,$j }
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "CSV por TCU: $($jobs.Count) escrituras en $($tcus.Count) TCUs  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    $ok = 0; $ko = 0
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { $segOk = $false; Con "ERROR de conexion ($($cx.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $fallo = $null; $todoOk = $segOk
            if (-not $segOk) { $fallo = "sin conexion ($($cx.ip):$($seg.puerto))" }
            else {
                foreach ($j in $porTcu[[int]$tcu]) {
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
                        } catch {
                            $fallo = "$($j.nombre) = $($j.texto): $_"
                            if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                            Start-Sleep -Milliseconds (300 * $i)
                        }
                    }
                    if (-not $hecho) { $todoOk = $false; break }
                }
            }
            if ($todoOk) { $ok++; Con ("TCU {0,3}  OK  ({1} valores)" -f $tcu, $porTcu[[int]$tcu].Count) ([System.Drawing.Color]::LightGreen) }
            else { $ko++; Con ("TCU {0,3}  FALLO  {1}" -f $tcu, $fallo) ([System.Drawing.Color]::Salmon) }
        }
    }
    Modbus-Cerrar
    Con "CSV por TCU terminado: $ok OK, $ko con fallo. Recuerda GUARDAR EN NVM si procede." ([System.Drawing.Color]::SteelBlue)
} })

# ------------------------- BACKUP MASIVO DE NCU -------------------------
$btnBackupNcu.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $tcus = Rango-Tcus $txtBIni.Text $txtBFin.Text 'Backup NCU'
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Carpeta donde guardar los backups JSON (uno por TCU, $($tcus.Count) ficheros)"
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $dir = $dlg.SelectedPath
    $ts = Get-Date -Format 'yyyyMMdd_HHmm'
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Backup NCU: TCUs $($tcus[0])-$($tcus[-1]) -> $dir  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    $ok = 0; $ko = 0
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { $segOk = $false; Con "ERROR de conexion ($($cx.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            if (-not $segOk) { $ko++; Con ("TCU {0,3}  FALLO  sin conexion" -f $tcu) ([System.Drawing.Color]::Salmon); continue }
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
            if ($completo) { $ok++; Con ("TCU {0,3}  backup OK" -f $tcu) ([System.Drawing.Color]::LightGreen) }
            else { $ko++; Con ("TCU {0,3}  backup INCOMPLETO ({1} errores)" -f $tcu, $errs) ([System.Drawing.Color]::Orange) }
        }
    }
    Modbus-Cerrar
    Con "Backup NCU terminado: $ok completos, $ko incompletos/fallidos. Carpeta: $dir" ([System.Drawing.Color]::SteelBlue)
} })

# ------------------------- AUDITORIA GOLDEN PRESET -------------------------
$btnPresetRef.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Preset o backup (*.json)|*.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    try { $obj = Get-Content $dlg.FileName -Raw | ConvertFrom-Json }
    catch { [void][System.Windows.Forms.MessageBox]::Show("No se pudo leer: $_",'Error'); return }
    $pares = @()
    if ($obj.tipo -eq 'backup_tcu') { $pares = @($obj.variables) } else { $pares = @($obj) }
    $ref = @()
    foreach ($e in $pares) {
        $nombre = [string]$e.variable
        if (-not $VARIABLES.Contains($nombre)) { continue }
        $def = $VARIABLES[$nombre]
        if ($ADDR_COMANDO -contains $def.addr) { continue }
        if ($ADDR_TIEMPO -contains $def.addr) { continue }
        if ("$($e.valor)" -eq '') { continue }
        try { $ref += @{nombre=$nombre; texto="$($e.valor)"; esc=(Valor-A-Escritura $def "$($e.valor)")} }
        catch { Con "AVISO preset ref: '$nombre' valor '$($e.valor)' invalido - fuera de la auditoria" ([System.Drawing.Color]::Orange) }
    }
    if ($ref.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('El fichero no tiene variables de configuracion utilizables.','Error'); return }
    $script:PresetRef = $ref
    $script:PresetRefNombre = [System.IO.Path]::GetFileName($dlg.FileName)
    $lblPresetRef.Text = "$($script:PresetRefNombre)  ($($ref.Count) variables)"
    Con "Preset de referencia cargado: $($script:PresetRefNombre) con $($ref.Count) variables" ([System.Drawing.Color]::SteelBlue)
})

$btnAud.Add_Click({ Lanzar {
    if (-not $script:PresetRef) { [void][System.Windows.Forms.MessageBox]::Show('Carga primero un preset de referencia (o un backup completo).','Aviso'); return }
    $cx = Params-Conexion
    $tcus = Rango-Tcus $txtAIni.Text $txtAFin.Text 'Auditoria'
    $lvA.Items.Clear(); $script:UltimaAud = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Auditoria de TCUs $($tcus[0])-$($tcus[-1]) contra '$($script:PresetRefNombre)' ($($script:PresetRef.Count) variables)  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    $nOk = 0; $nDesv = 0; $nErr = 0
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { $segOk = $false; Con "ERROR de conexion ($($cx.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $desvTcu = 0; $errTcu = 0
            foreach ($refv in $script:PresetRef) {
                if ($script:Cancelar) { break }
                $cmp = $null
                if ($segOk) {
                    for ($i = 1; $i -le $cx.reint -and $null -eq $cmp; $i++) {
                        try { $cmp = Comparar-Escritura $tcu $refv.esc }
                        catch {
                            if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                            Start-Sleep -Milliseconds 150
                        }
                    }
                }
                if ($null -eq $cmp) {
                    $errTcu++
                    $script:UltimaAud += [pscustomobject]@{TCU=[int]$tcu; Variable=$refv.nombre; Esperado=$refv.texto; Leido=''; Nota='sin respuesta'}
                    $item = New-Object System.Windows.Forms.ListViewItem("$tcu")
                    [void]$item.SubItems.Add($refv.nombre); [void]$item.SubItems.Add($refv.texto); [void]$item.SubItems.Add('-'); [void]$item.SubItems.Add('sin respuesta')
                    $item.ForeColor = [System.Drawing.Color]::Gray
                    $lvA.Items.Add($item) | Out-Null
                } elseif (-not $cmp.ok) {
                    $desvTcu++
                    $leidoDec = ''
                    try { $leidoDec = Leer-Decodificado $tcu $VARIABLES[$refv.nombre] } catch { $leidoDec = "raw $($cmp.leidoRaw)" }
                    $script:UltimaAud += [pscustomobject]@{TCU=[int]$tcu; Variable=$refv.nombre; Esperado=$refv.texto; Leido=$leidoDec; Nota='DESVIACION'}
                    $item = New-Object System.Windows.Forms.ListViewItem("$tcu")
                    [void]$item.SubItems.Add($refv.nombre); [void]$item.SubItems.Add($refv.texto); [void]$item.SubItems.Add($leidoDec); [void]$item.SubItems.Add('DESVIACION')
                    $item.ForeColor = [System.Drawing.Color]::DarkOrange
                    $lvA.Items.Add($item) | Out-Null
                }
            }
            if ($errTcu -gt 0) { $nErr++ }
            elseif ($desvTcu -gt 0) { $nDesv++; Con ("TCU {0,3}  {1} desviaciones" -f $tcu, $desvTcu) ([System.Drawing.Color]::Orange) }
            else { $nOk++ }
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    Modbus-Cerrar
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Auditoria: $nOk TCUs conformes | $nDesv con desviaciones | $nErr sin respuesta. $($script:UltimaAud.Count) filas listadas." ([System.Drawing.Color]::SteelBlue)
    if ($script:UltimaAud.Count -eq 0) { Con 'Toda la flota coincide con el preset de referencia.' ([System.Drawing.Color]::LightGreen) }
} })

$btnAudCsv.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'auditoria_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:UltimaAud | Export-Csv $dlg.FileName -NoTypeInformation -Encoding UTF8
        Con "CSV exportado: $($dlg.FileName)" ([System.Drawing.Color]::SteelBlue)
    }
})

# ------------------------- INVENTARIO DE FLOTA -------------------------
$btnInvF.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $tcus = Rango-Tcus $txtVIni.Text $txtVFin.Text 'Inventario'
    $lvV.Items.Clear(); $script:UltimoInv = @(); $lblInvF.Text = ''
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Inventario de TCUs $($tcus[0])-$($tcus[-1])  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    $ok = 0; $ko = 0
    $segs = @(Plan-Segmentos $tcus $cx)
    foreach ($seg in $segs) {
        if ($script:Cancelar) { break }
        $segOk = $true
        try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
        catch { $segOk = $false; Con "ERROR de conexion ($($cx.ip):$($seg.puerto)): $_" ([System.Drawing.Color]::Salmon) }
        foreach ($tcu in $seg.tcus) {
            if (Chequear-Cancelado) { break }
            $campos = $null; $err = ''
            if ($segOk) {
                for ($i = 1; $i -le $cx.reint -and $null -eq $campos; $i++) {
                    try { $campos = Ident-Leer $tcu }
                    catch {
                        $err = "$_"
                        if (-not (Es-ExcepcionModbus $_.Exception.Message)) { Modbus-Reconectar }
                        Start-Sleep -Milliseconds (300 * $i)
                    }
                }
            } else { $err = "sin conexion ($($cx.ip):$($seg.puerto))" }
            $item = New-Object System.Windows.Forms.ListViewItem("$tcu")
            if ($null -ne $campos) {
                $h = @{}
                foreach ($c in $campos) { $h[$c.Campo] = $c.Valor }
                foreach ($col in @($h['Numero de serie'], $h['MAC Xbee'], $h['FW principal'], $h['FW de fabrica'], $h['HW PCBA'], $h['Fecha de fabricacion'], '')) {
                    [void]$item.SubItems.Add("$col")
                }
                $ok++
                $script:UltimoInv += [pscustomobject]@{TCU=[int]$tcu; Serie=$h['Numero de serie']; MAC=$h['MAC Xbee']
                    FW=$h['FW principal']; FW_fabrica=$h['FW de fabrica']; HW=$h['HW PCBA']; Fecha_fab=$h['Fecha de fabricacion']; Nota='OK'}
            } else {
                foreach ($n in 1..6) { [void]$item.SubItems.Add('-') }
                [void]$item.SubItems.Add($err)
                $item.ForeColor = [System.Drawing.Color]::Firebrick
                $ko++
                $script:UltimoInv += [pscustomobject]@{TCU=[int]$tcu; Serie=''; MAC=''; FW=''; FW_fabrica=''; HW=''; Fecha_fab=''; Nota=$err}
            }
            $lvV.Items.Add($item) | Out-Null
            [System.Windows.Forms.Application]::DoEvents()
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
} })

$btnInvFCsv.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'inventario_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:UltimoInv | Export-Csv $dlg.FileName -NoTypeInformation -Encoding UTF8
        Con "CSV exportado: $($dlg.FileName)" ([System.Drawing.Color]::SteelBlue)
    }
})

# ------------------------- log manual -------------------------
$btnLog.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Texto (*.txt)|*.txt'
    $dlg.FileName = 'tcu_toolbox_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt'
    if ($dlg.ShowDialog() -eq 'OK') { Set-Content $dlg.FileName $rtb.Text -Encoding UTF8 }
})

# ------------------------- arranque -------------------------
Con "TCU Toolbox v$VERSION_TOOLBOX listo. Mapa de registros: $VERSION_MAPA." ([System.Drawing.Color]::Gainsboro)
Con 'Escribir: tabla + presets + backup como preset. Leer: varias variables a la vez en un rango, con resumen de discrepancias.' ([System.Drawing.Color]::Gainsboro)
Con 'Filtro de variables: escribe p.ej. "soc" o "tilt" en el campo Filtro y el desplegable se reduce a lo que casa.' ([System.Drawing.Color]::Gainsboro)
Con 'Entradas (auto): NCU completa con puerto resuelto por TCU; los gateways se recorren en secuencia.' ([System.Drawing.Color]::Gainsboro)
Con 'Flota: auditoria contra preset de referencia e inventario (FW/serie/MAC). Volcar: BACKUP NCU masivo. Escribir: CSV por TCU.' ([System.Drawing.Color]::Gainsboro)
Con 'Diagnostico de PLANTA completa: elige la entrada "(PLANTA completa)" y DIAGNOSTICAR recorre todas las NCUs (filtro NCUs: 1,3-5).' ([System.Drawing.Color]::Gainsboro)
Con 'Volcar: backup completo de una TCU (CSV/JSON) y comparacion contra un backup anterior.' ([System.Drawing.Color]::Gainsboro)
Con 'Diagnostico: salud OK/AVISO/ALARMA/OFFLINE de un rango con alarmas en texto. Utilidades: reloj e identificacion.' ([System.Drawing.Color]::Gainsboro)
foreach ($m in $script:MsgsInicio) { Con $m ([System.Drawing.Color]::SteelBlue) }
if ($PLANTAS.Count -le 1) {
    Con 'Sin plantas cargadas: usa el boton Cargar... (o copia los JSON de la plataforma en la subcarpeta plantas/).' ([System.Drawing.Color]::Orange)
}
[void]$form.ShowDialog()
Modbus-Cerrar
