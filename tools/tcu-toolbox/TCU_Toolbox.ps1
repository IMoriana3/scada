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

$VERSION_TOOLBOX = '6.6'
$VERSION_MAPA    = 'SUNNER TCU v6.1 (FW 1.4.3) + NCU R7.1 + HSU R23'

# La propia NCU expone sus registros en el puerto 502, unit id 1 (mapa R7.1)
$PUERTO_NCU = 502
$UNIT_NCU   = 1

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
        if (-not $porPlanta[$planta].Contains($ncu)) { $porPlanta[$planta][$ncu] = @{ip=$p.ip; gws=@(); hsu=$null} }
        if ($porPlanta[$planta][$ncu].ip -ne $p.ip) { continue }   # inconsistencia: ignorar
        $porPlanta[$planta][$ncu].gws += ,@{puerto=$p.puerto; ini=$p.ini; fin=$p.fin}
        if ($p.hsu -and -not $porPlanta[$planta][$ncu].hsu) { $porPlanta[$planta][$ncu].hsu = $p.hsu }
    }
    foreach ($planta in $porPlanta.Keys) {
        $ncus = $porPlanta[$planta]
        if ($ncus.Count -lt 2) { continue }
        $lista = @()
        foreach ($n in ($ncus.Keys | Sort-Object)) {
            $lista += ,@{ncu=[int]$n; ip=$ncus[$n].ip; gws=@($ncus[$n].gws | Sort-Object { $_.ini }); hsu=$ncus[$n].hsu}
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

$ESTADOS_COMIS = @{3='Factory'; 2='TCU configurado'; 1='Motor verificado'; 0='COMISIONADO'}

function Html-Esc([string]$s) {
    return "$s".Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

# Informe PEM autocontenido en HTML. $m: planta, ip, fecha, usuario, version,
# mapa + listas opcionales diag/inv/aud/pem (objetos de la sesion).
function Informe-Html([hashtable]$m) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Informe PEM - ' + (Html-Esc $m.planta) + '</title><style>')
    [void]$sb.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;font-size:13px;margin:24px;color:#222}h1{font-size:20px}h2{font-size:15px;margin-top:26px;border-bottom:2px solid #345;padding-bottom:4px}table{border-collapse:collapse;width:100%;margin-top:8px}th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;font-size:12px}th{background:#eef2f6;cursor:pointer;user-select:none}tr.ok td{background:#eaf7ee}tr.aviso td{background:#fff6e0}tr.alarma td{background:#fdeaea}tr.off td{background:#f0f0f0;color:#777}.meta{color:#555}.res{font-weight:600;margin:6px 0}.ok2{color:#137333;font-weight:400}.ko2{color:#a50e0e;font-weight:400}')
    [void]$sb.AppendLine('tr.filtros td{background:#f7f9fb;padding:2px 4px}tr.filtros input[type=text],tr.filtros input:not([type]){width:100%;box-sizing:border-box;font-size:11px;padding:2px;border:1px solid #bbb;border-radius:3px}.vis{color:#555;font-weight:400;font-size:12px}th:hover{background:#dde6ef}th .fl{color:#06c}')
    [void]$sb.AppendLine('.fm{position:relative;display:block}.fmb{width:100%;box-sizing:border-box;font:inherit;font-size:11px;padding:2px 4px;border:1px solid #bbb;border-radius:3px;background:#fff;cursor:pointer;text-align:left;overflow:hidden;white-space:nowrap}.fmb.act{border-color:#06c;color:#06c;font-weight:700}')
    [void]$sb.AppendLine('.fmp{position:absolute;z-index:30;top:100%;left:0;min-width:100%;max-height:250px;overflow:auto;background:#fff;border:1px solid #bbb;border-radius:3px;box-shadow:0 6px 18px rgba(20,30,45,.2);padding:5px 7px;display:none;white-space:nowrap;text-align:left}')
    [void]$sb.AppendLine('.fmp label{display:block;font-weight:400;font-size:12px;padding:1px 0;cursor:pointer}.fmp .fmt{border-bottom:1px solid #e6ebf0;margin-bottom:4px;padding-bottom:4px}.fmp .fmt a{color:#06c;cursor:pointer;text-decoration:underline;margin-right:10px;font-size:11px}')
    [void]$sb.AppendLine('.indice{background:#eef4fb;border:1px solid #cfe0f2;border-radius:4px;padding:7px 10px;margin:14px 0;font-size:13px}.indice a{color:#06c;text-decoration:none;font-weight:700}.indice a:hover{text-decoration:underline}')
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine('<h1>Informe de puesta en marcha &mdash; ' + (Html-Esc $m.planta) + '</h1>')
    [void]$sb.AppendLine('<p class="meta">Fecha: ' + (Html-Esc $m.fecha) + ' &middot; IP/conexion: ' + (Html-Esc $m.ip) + ' &middot; Tecnico: ' + (Html-Esc $m.usuario) + '<br>TCU Toolbox v' + (Html-Esc $m.version) + ' &middot; Mapa: ' + (Html-Esc $m.mapa) + '</p>')
    $clase = { param($s) switch -Wildcard ("$s") { 'OK*'{'ok'} 'PASA*'{'ok'} 'ALARMA*'{'alarma'} 'FALLA*'{'alarma'} 'FALLO*'{'alarma'} 'AVISO*'{'aviso'} 'DUDOSO*'{'aviso'} 'PENDIENTE*'{'aviso'} 'OFFLINE*'{'off'} 'SALTADO*'{'off'} default{''} } }
    $tabla = {
        param($titulo, $filas, $cols, $colEstado, $clave)
        if (-not $filas -or @($filas).Count -eq 0) { return }
        $hh = ''
        if ($m.horas -and $m.horas[$clave]) { $hh = ' <span class="meta">(' + (Html-Esc $m.horas[$clave]) + ')</span>' }
        [void]$sb.AppendLine('<h2 id="s-' + $clave + '">' + (Html-Esc $titulo) + $hh + ' <span class="meta">(' + @($filas).Count + ' filas)</span></h2>')
        $grupos = @($filas) | Group-Object $colEstado | ForEach-Object { "$($_.Count) $($_.Name)" }
        [void]$sb.AppendLine('<div class="res">' + (Html-Esc ($grupos -join ' | ')) + ' <span class="vis"></span></div>')
        [void]$sb.AppendLine('<table class="filtrable"><thead><tr>' + (($cols | ForEach-Object { '<th title="clic para ordenar">' + (Html-Esc $_) + '<span class="fl"></span></th>' }) -join '') + '</tr></thead><tbody>')
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
            if ($claves.Count -eq 1) {
                $disc += '<span class="ok2">' + (Html-Esc $c) + ': todas coinciden = ' + (Html-Esc $claves[0]) + '</span>'
            } elseif ($claves.Count -gt 1) {
                $det = ($claves | ForEach-Object { (Html-Esc $_) + ' en ' + $cuenta[$_] + ' TCUs' }) -join ' &middot; '
                $disc += '<span class="ko2">' + (Html-Esc $c) + ': ' + $claves.Count + ' valores distintos &rarr; ' + $det + '</span>'
            }
        }
        if ($disc.Count) { [void]$sb.AppendLine('<div class="res">' + ($disc -join '<br>') + '</div>') }
        [void]$sb.AppendLine('<table class="filtrable"><thead><tr>' + (($colsL | ForEach-Object { '<th title="clic para ordenar">' + (Html-Esc $_) + '<span class="fl"></span></th>' }) -join '') + '</tr></thead><tbody>')
        foreach ($f in $filasL) {
            $cl = $(if ("$($f.Estado)" -and "$($f.Estado)" -ne 'OK') { ' class="alarma"' } else { '' })
            [void]$sb.AppendLine('<tr' + $cl + '>' + (($colsL | ForEach-Object { '<td>' + (Html-Esc "$($f.$_)") + '</td>' }) -join '') + '</tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
    }

    # Las secciones se pintan EMPEZANDO POR LA ULTIMA QUE SE EJECUTO. Si acabas
    # de hacer un inventario, el inventario va arriba aunque en la sesion
    # hubiera un diagnostico anterior: si no, el informe parece de otra cosa.
    $secciones = @(
        @{clave='lectura'; titulo='Lectura de variables'; filas=$m.lectura; pinta=$tablaLectura}
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
function Plan-Firmware([array]$inv, [string]$objetivo, [hashtable]$gwsPorNcu) {
    $obj = "$objetivo".Trim()
    if (-not $obj) { throw 'indica la version de firmware objetivo (p. ej. v1.6.0)' }
    $pend = @{}; $mudas = @(); $alDia = 0
    foreach ($f in $inv) {
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
    return @{tramos=$filas; pendientes=$totalPend; al_dia=$alDia; sin_respuesta=$mudas}
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
                $dif = [math]::Abs($tilt - $targ)
                $edad = -1
                if ($reloj -gt 1000000000 -and $lastc[$tcu] -gt 1000000000) { $edad = $reloj - $lastc[$tcu] }
                $alarmas = @(Bits-Texto $al1 $BITS_AL1) + @(Bits-Texto $al2 $BITS_AL2)
                $notas = @()
                if ($dif -gt 5) { $notas += ("dif {0:0.0} deg" -f $dif) }
                if ((($fl -shr 15) -band 1) -eq 0) { $notas += 'system OK = 0' }
                if ((($fl -shr 11) -band 1) -eq 1) { $notas += 'alarma motor enclavada' }
                if ($edad -gt 90) { $notas += "datos de hace $edad s" }
                $salud = 'OK'
                if ($lastc[$tcu] -eq 0 -or ($edad -ge 0 -and $edad -gt 300)) {
                    $salud = 'OFFLINE'
                    $notas = @($(if ($lastc[$tcu] -eq 0) { 'la NCU nunca ha leido este TCU' } else { "sin datos en la NCU desde hace $edad s" }))
                }
                elseif ((($al1 -band $CRIT_AL1) -ne 0) -or (($al2 -band $CRIT_AL2) -ne 0)) { $salud = 'ALARMA' }
                elseif ($alarmas.Count -gt 0 -or $notas.Count -gt 0) { $salud = 'AVISO' }
                $res[$tcu] = [pscustomobject]@{
                    TCU = $tcu; Salud = $salud
                    Modo = @('OFF','MANUAL','AUTO','?')[(($msr -shr 8) -band 0x3)]
                    Tilt = [math]::Round($tilt, 1); Objetivo = [math]::Round($targ, 1); Dif = [math]::Round($dif, 1)
                    SoC = ($w[$b+13] -band 0xFF); SoH = ($w[$b+21] -band 0xFF)
                    Vbat_mV = $w[$b+16]; Ibat_mA = $ibat
                    Tbat_C = [math]::Round(($w[$b+20] / 10.0) - 273.15, 1); Tpcb_C = [math]::Round(($w[$b+19] / 10.0) - 273.15, 1)
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
            Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''; Vbat_mV=''; Ibat_mA=''; Tbat_C=''; Tpcb_C=''
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
    $fecha = ''
    try {
        $epoch = ([long]$w[5] -shl 16) -bor [long]$w[4]
        if ($epoch -gt 1000000000) { $fecha = [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC' }
    } catch {}
    return @{salud=$salud; alarmas=$alarmas; fecha=$fecha; din=$din; principal=$principal}
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
    if (-not $ar.AsyncWaitHandle.WaitOne(5000)) { $c.Close(); throw "Sin conexion TCP a ${ip}:${puerto}" }
    $c.EndConnect($ar)
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
    $porTcu = @{}
    foreach ($f in $filas) {
        $k = "$($f.dia)|$($f.ncu)|$($f.tcu)"
        if (-not $porTcu.ContainsKey($k)) { $porTcu[$k] = @{n=0; mal=0} }
        $porTcu[$k].n++
        if ([int]$f.al_motor -or [int]$f.al_bat -or [int]$f.al_com) { $porTcu[$k].mal++ }
    }
    $res = @()
    foreach ($k in @($porTcu.Keys | Sort-Object)) {
        $v = $porTcu[$k]; $p = $k -split '\|'
        $pct = $(if ($v.n -gt 0) { [math]::Round(100.0 * ($v.n - $v.mal) / $v.n, 2) } else { 0 })
        $res += [pscustomobject]@{Dia=$p[0]; NCU=$p[1]; TCU=[int]$p[2]; Registros=$v.n
            Indisponibles=$v.mal; Disponibilidad_pct=$pct
            Cumple=$(if ($pct -ge $minimo) { 'SI' } else { 'NO' })}
    }
    return $res
}

# D.4 Disponibilidad de comunicaciones. Regla del anexo: un intento fallido
# suelto NO cuenta si el siguiente se restablece, salvo que se repita dentro de
# dos minutos; en ese caso cuentan todos los fallos.
function Sat-DispComms($fallos, $intentosPorClave, [double]$minimo = 98.5, [int]$ventana = 120) {
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
        $res += [pscustomobject]@{Dia=$p[0]; NCU=$p[1]; Equipo=$p[2]; Intentos=$n
            Fallos_brutos=$ts.Count; Fallos_computados=$cuenta; Disponibilidad_pct=$pct
            Cumple=$(if ($pct -ge $minimo) { 'SI' } else { 'NO' })}
    }
    return $res
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
$lblWFiltro = LG $tabW '' 424 104
$lblWFiltro.ForeColor = [System.Drawing.Color]::Gray

$btnWQuitar = New-Object System.Windows.Forms.Button
$btnWQuitar.Text = 'Quitar'
$btnWQuitar.Location = New-Object System.Drawing.Point(534, 18)
$btnWQuitar.Size = New-Object System.Drawing.Size(78, 28)
$tabW.Controls.Add($btnWQuitar)

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
# Misma maqueta que Escribir: una tabla con una fila por variable, en vez del
# combo + Anadir + lista que habia antes. Las dos pestanas se usan seguidas y
# no tenia sentido que se eligieran las variables de dos maneras distintas.
$tabL = New-Object System.Windows.Forms.TabPage
$tabL.Text = 'Leer variable'
$tabs.TabPages.Add($tabL)

[void](LG $tabL 'TCU de' 10 52)
$txtLIni = TG $tabL '1' 62 22 45
[void](LG $tabL 'a' 116 12)
$txtLFin = TG $tabL '44' 131 22 45

[void](LG $tabL 'Filtro' 200 42)
$txtLFiltro = TG $tabL '' 244 22 170
$lblLFiltro = LG $tabL '' 424 104
$lblLFiltro.ForeColor = [System.Drawing.Color]::Gray

# Quitar la variable seleccionada. Existia con la lista de la v5.1 y se perdio
# al pasar a tabla; sin cabeceras de fila no hay forma evidente de borrar una.
$btnLQuitar = New-Object System.Windows.Forms.Button
$btnLQuitar.Text = 'Quitar'
$btnLQuitar.Location = New-Object System.Drawing.Point(534, 18)
$btnLQuitar.Size = New-Object System.Drawing.Size(78, 28)
$tabL.Controls.Add($btnLQuitar)

$btnLeer = New-Object System.Windows.Forms.Button
$btnLeer.Text = 'LEER'
$btnLeer.Location = New-Object System.Drawing.Point(620, 18)
$btnLeer.Size = New-Object System.Drawing.Size(140, 28)
$btnLeer.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnLeer.ForeColor = [System.Drawing.Color]::White
$tabL.Controls.Add($btnLeer)

$btnLCsv = New-Object System.Windows.Forms.Button
$btnLCsv.Text = 'Exportar CSV'
$btnLCsv.Location = New-Object System.Drawing.Point(766, 18)
$btnLCsv.Size = New-Object System.Drawing.Size(140, 28)
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
$btnDiag.Size = New-Object System.Drawing.Size(120, 28)
$btnDiag.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnDiag.ForeColor = [System.Drawing.Color]::White
$tabG.Controls.Add($btnDiag)

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
$lblGBucle.Size = New-Object System.Drawing.Size(330, 20)
$lblGBucle.ForeColor = [System.Drawing.Color]::Gray
$tabG.Controls.Add($lblGBucle)

$btnGComm = New-Object System.Windows.Forms.Button
$btnGComm.Text = 'TEST COMM (rapido)'
$btnGComm.Location = New-Object System.Drawing.Point(668, 51)
$btnGComm.Size = New-Object System.Drawing.Size(150, 28)
$btnGComm.BackColor = [System.Drawing.Color]::FromArgb(0,120,60)
$btnGComm.ForeColor = [System.Drawing.Color]::White
$tabG.Controls.Add($btnGComm)

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
$lblGVer.Size = New-Object System.Drawing.Size(446, 20)
$lblGVer.ForeColor = [System.Drawing.Color]::Gray
$tabG.Controls.Add($lblGVer)

$lvG = New-Object System.Windows.Forms.ListView
$lvG.Location = New-Object System.Drawing.Point(10, 116)
$lvG.Size = New-Object System.Drawing.Size(898, 244)
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
$btnAudCsv.Location = New-Object System.Drawing.Point(762, 18)
$btnAudCsv.Size = New-Object System.Drawing.Size(60, 28)
$btnAudCsv.Enabled = $false
$gbAud.Controls.Add($btnAudCsv)

$btnAudJson = New-Object System.Windows.Forms.Button
$btnAudJson.Text = 'JSON'
$btnAudJson.Location = New-Object System.Drawing.Point(826, 18)
$btnAudJson.Size = New-Object System.Drawing.Size(60, 28)
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

[void](LG $tabP 'TCU de' 10 50 18)
$txtPIni = TG $tabP '1' 60 14 42
[void](LG $tabP 'a' 108 10 18)
$txtPFin = TG $tabP '5' 120 14 42
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
$btnPComis.Text = 'LEER ESTADO'
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

$lblFwNota = LG $tabFW 'Cada tramo es un CARRIL (NCU + gateway): el updater admite varias ventanas a la vez, una por carril. PREPARAR comprueba viento, comunicacion y alarmas, y hace backup antes de actualizar/capturar una TCU.' 10 898 82
$lblFwNota.ForeColor = [System.Drawing.Color]::Gray

$lvFW = New-Object System.Windows.Forms.ListView
$lvFW.Location = New-Object System.Drawing.Point(10, 104)
$lvFW.Size = New-Object System.Drawing.Size(898, 256)
$lvFW.View = 'Details'; $lvFW.FullRowSelect = $true; $lvFW.GridLines = $true
[void]$lvFW.Columns.Add('NCU', 50)
[void]$lvFW.Columns.Add('IP', 110)
[void]$lvFW.Columns.Add('Gateway', 70)
[void]$lvFW.Columns.Add('Desde', 60)
[void]$lvFW.Columns.Add('Hasta', 60)
[void]$lvFW.Columns.Add('TCUs', 55)
[void]$lvFW.Columns.Add('Estado / nota', 470)
$tabFW.Controls.Add($lvFW)

# ============================ TAB SAT ============================
$tabSAT = New-Object System.Windows.Forms.TabPage
$tabSAT.Text = 'SAT'
$tabs.TabPages.Add($tabSAT)

[void](LG $tabSAT 'Muestreo TCU s' 10 86)
$txtSatInt = TG $tabSAT '60' 100 22 42
[void](LG $tabSAT 'Comms s' 150 52)
$txtSatCom = TG $tabSAT '15' 206 22 38
[void](LG $tabSAT 'Dias' 252 30)
$txtSatDias = TG $tabSAT '7' 286 22 32

$btnSatIni = New-Object System.Windows.Forms.Button
$btnSatIni.Text = 'INICIAR REGISTRO'
$btnSatIni.Location = New-Object System.Drawing.Point(330, 18)
$btnSatIni.Size = New-Object System.Drawing.Size(160, 28)
$btnSatIni.BackColor = [System.Drawing.Color]::FromArgb(0,120,60)
$btnSatIni.ForeColor = [System.Drawing.Color]::White
$tabSAT.Controls.Add($btnSatIni)

$btnSatFin = New-Object System.Windows.Forms.Button
$btnSatFin.Text = 'PARAR'
$btnSatFin.Location = New-Object System.Drawing.Point(498, 18)
$btnSatFin.Size = New-Object System.Drawing.Size(90, 28)
$btnSatFin.Enabled = $false
$tabSAT.Controls.Add($btnSatFin)

$btnSatAnal = New-Object System.Windows.Forms.Button
$btnSatAnal.Text = 'ANALIZAR Y EMITIR'
$btnSatAnal.Location = New-Object System.Drawing.Point(596, 18)
$btnSatAnal.Size = New-Object System.Drawing.Size(170, 28)
$btnSatAnal.BackColor = [System.Drawing.Color]::FromArgb(0,90,160)
$btnSatAnal.ForeColor = [System.Drawing.Color]::White
$tabSAT.Controls.Add($btnSatAnal)

$lblSat = LG $tabSAT 'Anexo 4: D.1.1 precision, D.3.4 disponibilidad de operacion y D.4 de comunicaciones. Deja la ventana abierta los dias que dure el ensayo.' 10 890 56
$lblSat.ForeColor = [System.Drawing.Color]::Gray

$lvSat = New-Object System.Windows.Forms.ListView
$lvSat.Location = New-Object System.Drawing.Point(10, 82)
$lvSat.Size = New-Object System.Drawing.Size(898, 278)
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
$lblHSel = LG $tabH 'Escanea la planta para listar sus HSUs y de que NCU cuelga cada una.' 443 465 85
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

$btnInforme = New-Object System.Windows.Forms.Button
$btnInforme.Text = 'INFORME HTML'
$btnInforme.Location = New-Object System.Drawing.Point(700, 741)
$btnInforme.Size = New-Object System.Drawing.Size(118, 28)
$form.Controls.Add($btnInforme)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(10, 746)
$lblLog.Size = New-Object System.Drawing.Size(680, 20)
$lblLog.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblLog)

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
$miLimpiarCon.Add_Click({ $rtb.Clear() })
$rtb.ContextMenuStrip = $menuCon

# ---------------------------------------------------------------------------
#  Estado global, consola y log automatico a fichero
# ---------------------------------------------------------------------------
$script:Fallidas = New-Object System.Collections.ArrayList
$script:UltimaLectura = @()
$script:UltimaEscritura = @()
$script:UltimoVolcado = @()
$script:UltimoDiag = @()
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
                    $btnPresetSave, $btnPresetLoad, $btnCargarBackup, $btnLCsv, $btnDCsv, $btnBackupJson,
                    $btnComparar, $btnGCsv, $btnGJson, $btnICsv,
                    $btnCsvTcu, $btnBackupNcu, $btnAud, $btnAudCsv, $btnPresetRef, $btnInvF, $btnInvFCsv,
                    $btnHMeteo, $btnHConfig, $btnHCaja, $btnHUmb, $btnHReloj, $btnHNieve, $btnHNvm,
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
function Lanzar([scriptblock]$accion) {
    if ($script:Ocupado) { Con 'Hay una operacion en curso (usa CANCELAR para abortarla).' ([System.Drawing.Color]::Orange); return }
    $script:Ocupado = $true; $script:Cancelar = $false; $script:NcuLog = ''
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
    if ($ip -eq 'NA' -or $ip -eq '(planta)') {
        $p = $null
        if ($cbPlanta.SelectedItem) { $p = $PLANTAS[$cbPlanta.SelectedItem] }
        if (-not ($p -and $p.ncus)) { throw "IP 'NA' solo vale con una entrada (Planta completa) seleccionada" }
        return @{ip='NA'; puerto=$null; gws=$null; multi=$p.ncus; etiqueta='PLANTA'; to=$to; reint=$reint}
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
function Trabajos-Planta([hashtable]$cx, [int[]]$tcus, [string]$filtro = '') {
    if (-not $cx.multi) { return @{ncu=$null; ip=$cx.ip; tcus=$tcus; cx=$cx} }
    $lista = @()
    $nums = Parse-ListaNums $filtro
    foreach ($n in $cx.multi) {
        if ($nums -and -not ($nums -contains [int]$n.ncu)) { continue }
        $lt = @()
        foreach ($g in $n.gws) { $lt += @([int]$g.ini..[int]$g.fin) }
        $lt = @($lt | Sort-Object -Unique)
        $lista += ,@{ncu=[int]$n.ncu; ip=$n.ip; tcus=$lt
            cx=@{ip=$n.ip; puerto=$null; gws=$n.gws; multi=$null; etiqueta='auto'; to=$cx.to; reint=$cx.reint}}
    }
    return $lista
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
        # planta completa: solo Diagnostico; IP, puertos y rangos van por NCU
        # (los campos se ignoran y se muestran como NA)
        $txtIp.Text = 'NA'; $txtPort.Text = 'auto'
        $txtGIni.Text = 'NA'; $txtGFin.Text = 'NA'
        $txtAIni.Text = 'NA'; $txtAFin.Text = 'NA'
        $txtVIni.Text = 'NA'; $txtVFin.Text = 'NA'
        $txtLIni.Text = 'NA'; $txtLFin.Text = 'NA'
        Con "Planta completa seleccionada ($(@($p.ncus).Count) NCUs): vale en Diagnostico, Leer variable, Flota (auditoria e inventario) y comisionado, con rangos automaticos por NCU; el filtro NCUs del diagnostico admite '1,3-5' (vacio = todas)." ([System.Drawing.Color]::SteelBlue)
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
        $txtPIni.Text = "$($p.ini)"; $txtPFin.Text = "$($p.fin)"
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
        $trabajos = @(Trabajos-Planta $cx $tcus)
    }
    if ($trabajos.Count -eq 0) { Con 'La planta no tiene NCUs con gateways definidos.' ([System.Drawing.Color]::Orange); return }
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
                        break
                    }
                }
            }
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

$btnEscribir.Add_Click({ Lanzar {
    $cxW = Params-Conexion
    $tcusW = $null
    if (-not $cxW.multi) { $tcusW = Rango-Tcus $txtWIni.Text $txtWFin.Text 'Escribir' }
    Escribir-EnTcus $tcusW
} })
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
            if ($hecho) { Con ((Eti-Tcu $tcu) + "  NVM guardado") ([System.Drawing.Color]::LightGreen) }
            else        { Con ((Eti-Tcu $tcu) + "  NVM FALLO") ([System.Drawing.Color]::Salmon) }
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
    $nombres = @(Vars-DeTablaLeer)
    if ($nombres.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Elige al menos una variable en la tabla.','Aviso'); return }
    $defs = @($nombres | ForEach-Object { @{nombre=[string]$_; vdef=(Def-DeLectura $_)} })
    $cx = Params-Conexion
    $tcus = $null
    if (-not $cx.multi) { $tcus = Rango-Tcus $txtLIni.Text $txtLFin.Text 'Leer' }
    $trabajos = @(Trabajos-Planta $cx $tcus)
    if ($trabajos.Count -eq 0) { Con 'La planta no tiene NCUs con gateways definidos.' ([System.Drawing.Color]::Orange); return }
    $lvL.Items.Clear(); $lvL.Columns.Clear(); $script:UltimaLectura = @()
    [void]$lvL.Columns.Add('NCU', 44)
    [void]$lvL.Columns.Add('TCU', 48)
    foreach ($d in $defs) { [void]$lvL.Columns.Add($d.nombre, [math]::Max(110, [math]::Min(220, [int](746 / $defs.Count)))) }
    [void]$lvL.Columns.Add('Estado', 130)
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    if ($cx.multi) {
        $totTcus = 0; foreach ($tr in $trabajos) { $totTcus += @($tr.tcus).Count }
        Con "Leyendo $($defs.Count) variable(s) en PLANTA completa: $($trabajos.Count) NCUs, $totTcus TCUs (rangos automaticos)" ([System.Drawing.Color]::SteelBlue)
    } else {
        Con "Leyendo $($defs.Count) variable(s) en TCUs $($tcus[0])-$($tcus[-1])  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    }
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
            [System.Windows.Forms.Application]::DoEvents()
        }
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
    Marcar-Bloque 'lectura'
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

# Un pase completo de diagnostico (usado por DIAGNOSTICAR y por el registrador)
function Diag-Correr {
    $cx = Params-Conexion
    $lvG.Items.Clear(); $script:UltimoDiag = @(); $lblGResumen.Text = ''
    # trabajos: una entrada por NCU (planta completa) o una sola (modo normal)
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    if ($cx.multi) {
        $trabajos = @(Trabajos-Planta $cx $null $txtGNcus.Text)
        if ($trabajos.Count -eq 0) { Con 'El filtro de NCUs no coincide con ninguna NCU de la planta.' ([System.Drawing.Color]::Orange); return }
        $totTcus = 0; foreach ($tr in $trabajos) { $totTcus += @($tr.tcus).Count }
        Con "Diagnostico de PLANTA: $($trabajos.Count) NCUs, $totTcus TCUs (rangos por NCU automaticos)" ([System.Drawing.Color]::SteelBlue)
    } else {
        $tcus = Rango-Tcus $txtGIni.Text $txtGFin.Text 'Diagnostico'
        $trabajos = @(Trabajos-Planta $cx $tcus)
        Con "Diagnostico de TCUs $($tcus[0])-$($tcus[-1])  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    }
    $nOk = 0; $nAviso = 0; $nAlarma = 0; $nOff = 0
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
            NCU="$($tr.ncu)"; TCU='NCU'; Salud=$(if ($ns) { $ns.salud } else { 'AVISO' }); Modo='-'
            Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''; Vbat_mV=''; Ibat_mA=''; Tbat_C=''; Tpcb_C=''
            Alarmas=$(if ($ns) { ((@($ns.alarmas) + $(if ($ns.fecha) { @("reloj NCU: $($ns.fecha)") } else { @() })) -join '; ') } else { "NCU sin respuesta en ${PUERTO_NCU}: $nsErr" })
            main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''
        }
        $itemN = New-Object System.Windows.Forms.ListViewItem("$($tr.ncu)")
        foreach ($c in @($dn.TCU, $dn.Salud, $dn.Modo, $dn.Tilt, $dn.Objetivo, $dn.Dif, $dn.SoC, $dn.Alarmas)) { [void]$itemN.SubItems.Add("$c") }
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
            foreach ($c in @($dh.TCU, $dh.Salud, $dh.Modo, $dh.Tilt, $dh.Objetivo, $dh.Dif, $dh.SoC, $dh.Alarmas)) { [void]$itemH.SubItems.Add("$c") }
            switch ($dh.Salud) {
                'OK'      { $itemH.ForeColor = [System.Drawing.Color]::DarkGreen;  $nOk++ }
                'AVISO'   { $itemH.ForeColor = [System.Drawing.Color]::DarkOrange; $nAviso++ }
                'ALARMA'  { $itemH.ForeColor = [System.Drawing.Color]::Firebrick;  $nAlarma++ }
                'OFFLINE' { $itemH.ForeColor = [System.Drawing.Color]::Gray;       $nOff++ }
            }
            $lvG.Items.Add($itemH) | Out-Null
            $script:UltimoDiag += $dh
            if ($dh.Salud -ne 'OK') { Con ("{0}{1}  {2,-8} {3}" -f $(if ($dh.NCU) { "NCU$($dh.NCU) " } else { '' }), $dh.TCU, $dh.Salud, $dh.Alarmas) ([System.Drawing.Color]::Orange) }
        }
        foreach ($tcu in $tr.tcus) {
            if (Chequear-Cancelado) { break }
            $d = $null
            if ($dm) { $d = $dm[[int]$tcu] }
            if ($null -eq $d) {
                $d = [pscustomobject]@{
                    TCU=[int]$tcu; Salud='OFFLINE'; Modo=''; Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''
                    Vbat_mV=''; Ibat_mA=''; Tbat_C=''; Tpcb_C=''; Alarmas='sin datos via NCU'
                    main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''
                }
            }
            $etiquetaNcu = ''
            if ($null -ne $tr.ncu) { $etiquetaNcu = "$($tr.ncu)" }
            $d | Add-Member -NotePropertyName NCU -NotePropertyValue $etiquetaNcu -Force
            $item = New-Object System.Windows.Forms.ListViewItem($etiquetaNcu)
            foreach ($c in @($d.TCU, $d.Salud, $d.Modo, $d.Tilt, $d.Objetivo, $d.Dif, $d.SoC, $d.Alarmas)) { [void]$item.SubItems.Add("$c") }
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
    Marcar-Bloque 'diag'
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
        foreach ($c in @($d.TCU, $d.Salud, $d.Modo, $d.Tilt, $d.Objetivo, $d.Dif, $d.SoC, $d.Alarmas)) { [void]$item.SubItems.Add("$c") }
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
    $tcus = $null
    if (-not $cx.multi) { $tcus = Rango-Tcus $txtGIni.Text $txtGFin.Text 'Test comm' }
    $trabajos = @(Trabajos-Planta $cx $tcus $(if ($cx.multi) { $txtGNcus.Text } else { '' }))
    if ($trabajos.Count -eq 0) { Con 'El filtro de NCUs no coincide con ninguna NCU de la planta.' ([System.Drawing.Color]::Orange); return }
    $lvG.Items.Clear(); $script:UltimoDiag = @(); $lblGResumen.Text = ''
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
            $d = [pscustomobject]@{NCU=$et; TCU='NCU'; Salud='OFFLINE'; Modo='-'; Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''
                Vbat_mV=''; Ibat_mA=''; Tbat_C=''; Tpcb_C=''; Alarmas="NCU SIN RESPUESTA en $($tr.ip):${PUERTO_NCU} - $err"
                main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''}
            $script:UltimoDiag += $d
            $nOff += @($tr.tcus).Count
            Con ("NCU{0,-3} {1,-15} SIN RESPUESTA: {2}" -f $et, $tr.ip, $err) ([System.Drawing.Color]::Salmon)
            continue
        }
        $nNcuOk++
        $script:UltimoDiag += [pscustomobject]@{NCU=$et; TCU='NCU'; Salud='OK'; Modo='-'; Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''
            Vbat_mV=''; Ibat_mA=''; Tbat_C=''; Tpcb_C=''; Alarmas="NCU responde ($($tr.ip):$PUERTO_NCU)"
            main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''}
        foreach ($h in $c.hsus) {
            if ($h.comunica) { $nHsuOk++ } else { $nHsuKo++ }
            $script:UltimoDiag += [pscustomobject]@{NCU=$et; TCU=$h.hsu; Salud=$(if ($h.comunica) { 'OK' } else { 'OFFLINE' }); Modo='-'
                Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''; Vbat_mV=''; Ibat_mA=''; Tbat_C=''; Tpcb_C=''
                Alarmas=$(if ($h.comunica) { "comunica (hace $($h.edad) s)" } else { $(if ($h.lastcomm -eq 0) { 'la NCU nunca la ha leido' } else { "sin datos desde hace $($h.edad) s" }) })
                main_status=''; alarmas_1=''; alarmas_2=''; alarmas_3=''; alarmas_4=''; system_status=''}
        }
        $mudas = @()
        foreach ($tcu in $tr.tcus) {
            $e = $c.tcus[[int]$tcu]
            $ok = ($null -ne $e -and $e.comunica)
            if ($ok) { $nOk++ } else { $nOff++; $mudas += $tcu }
            $script:UltimoDiag += [pscustomobject]@{NCU=$et; TCU=[int]$tcu; Salud=$(if ($ok) { 'OK' } else { 'OFFLINE' }); Modo='-'
                Tilt=''; Objetivo=''; Dif=''; SoC=''; SoH=''; Vbat_mV=''; Ibat_mA=''; Tbat_C=''; Tpcb_C=''
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
    Con "Es solo una prueba de comunicacion (lastComm): para alarmas, modo y posiciones usa DIAGNOSTICAR." ([System.Drawing.Color]::Gainsboro)
    $selV = $cbGVerNcu.SelectedItem
    $cbGVerNcu.Items.Clear()
    [void]$cbGVerNcu.Items.Add('NCU - todas')
    foreach ($nv in @($script:UltimoDiag | ForEach-Object { "$($_.NCU)" } | Where-Object { $_ } | Sort-Object {[int]$_} -Unique)) { [void]$cbGVerNcu.Items.Add("NCU$nv") }
    if ($selV -and $cbGVerNcu.Items.Contains($selV)) { $cbGVerNcu.SelectedItem = $selV } else { $cbGVerNcu.SelectedIndex = 0 }
    Diag-Refrescar
} })

$cbGVerNcu.Add_SelectedIndexChanged({ if (-not $script:Ocupado) { Diag-Refrescar } })
foreach ($k in @('OK','AVISO','ALARMA','OFFLINE')) {
    $script:ChksSalud[$k].Add_CheckedChanged({ if (-not $script:Ocupado) { Diag-Refrescar } })
}

# Mini-registrador: diagnostico en bucle cada X minutos, acumulando cada pase
# (con fecha/hora y alarmas desglosadas) en informes/registro_<ts>.csv.
# Se para con el boton CANCELAR.
$COLS_REGISTRO = @('NCU','TCU','Salud','Modo','Tilt','Objetivo','Dif','SoC','SoH','Vbat_mV','Ibat_mA',
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
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'diagnostico_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        # con las alarmas desglosadas en columnas 0/1 (filtrables en Excel)
        $filas = foreach ($d in $script:UltimoDiag) {
            $o = [ordered]@{}
            foreach ($pr in $d.PSObject.Properties) { $o[$pr.Name] = $pr.Value }
            $des = Alarmas-Desglose "$($d.alarmas_1)" "$($d.alarmas_2)"
            foreach ($k in $des.Keys) { $o[$k] = $des[$k] }
            [pscustomobject]$o
        }
        $filas | Export-Csv $dlg.FileName -NoTypeInformation -Encoding UTF8
        Con "CSV exportado con alarmas desglosadas: $($dlg.FileName)" ([System.Drawing.Color]::SteelBlue)
    }
})

$btnGJson.Add_Click({
    if ($script:UltimoEsComm) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Lo ultimo que se ha ejecutado es un TEST COMM (solo comunicacion), no un diagnostico completo.`r`n`r`nSe exportara como 'test_comm' y la plataforma NO lo aceptara como diagnostico.`r`n`r`nExportar igualmente?",
            'Test de comunicacion', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'JSON (*.json)|*.json'
    $dlg.FileName = $(if ($script:UltimoEsComm) { 'test_comm_' } else { 'diagnostico_' }) + (Get-Date -Format 'yyyyMMdd_HHmm') + '.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
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
    if ($tcus.Count -gt 3 -and -not $chkRoll.Checked) {
        Con 'Sin copia de seguridad previa (casilla desmarcada): esta escritura no se podra deshacer.' ([System.Drawing.Color]::Orange)
    }
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
                if ($r3 -ne 'Yes') { return }
            }
            if ($script:Cancelar) { return }
        }
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
            if ($todoOk) { $ok++; Con ((Eti-Tcu $tcu) + ("  OK   {0}" -f ($cambios -join ' | '))) ([System.Drawing.Color]::LightGreen) }
            else { $ko++; Con ((Eti-Tcu $tcu) + ("  FALLO  {0}" -f $fallo)) ([System.Drawing.Color]::Salmon) }
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
    $tcus = $null
    if (-not $cx.multi) { $tcus = Rango-Tcus $txtAIni.Text $txtAFin.Text 'Auditoria' }
    $trabajos = @(Trabajos-Planta $cx $tcus)
    if ($trabajos.Count -eq 0) { Con 'La planta no tiene NCUs con gateways definidos.' ([System.Drawing.Color]::Orange); return }
    $lvA.Items.Clear(); $script:UltimaAud = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    if ($cx.multi) {
        $totTcus = 0; foreach ($tr in $trabajos) { $totTcus += @($tr.tcus).Count }
        Con "Auditoria de Planta completa: $($trabajos.Count) NCUs, $totTcus TCUs contra '$($script:PresetRefNombre)' ($($script:PresetRef.Count) variables)" ([System.Drawing.Color]::SteelBlue)
    } else {
        Con "Auditoria de TCUs $($tcus[0])-$($tcus[-1]) contra '$($script:PresetRefNombre)' ($($script:PresetRef.Count) variables)  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    }
    $nOk = 0; $nDesv = 0; $nErr = 0
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
                    $desvTcu++
                    $leidoDec = ''
                    try { $leidoDec = Leer-Decodificado $tcu $VARIABLES[$refv.nombre] } catch { $leidoDec = "raw $($cmp.leidoRaw)" }
                    $script:UltimaAud += [pscustomobject]@{NCU=$etNcu; TCU=[int]$tcu; Variable=$refv.nombre; Esperado=$refv.texto; Leido=$leidoDec; Nota='DESVIACION'}
                    $item = New-Object System.Windows.Forms.ListViewItem($etNcu)
                    [void]$item.SubItems.Add("$tcu"); [void]$item.SubItems.Add($refv.nombre); [void]$item.SubItems.Add($refv.texto); [void]$item.SubItems.Add($leidoDec); [void]$item.SubItems.Add('DESVIACION')
                    $item.ForeColor = [System.Drawing.Color]::DarkOrange
                    $lvA.Items.Add($item) | Out-Null
                }
            }
            if ($errTcu -gt 0) { $nErr++ }
            elseif ($desvTcu -gt 0) { $nDesv++; Con ("{0}TCU {1,3}  {2} desviaciones" -f $(if ($etNcu) { "NCU$etNcu " } else { '' }), $tcu, $desvTcu) ([System.Drawing.Color]::Orange) }
            else { $nOk++ }
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
    Con "Auditoria: $nOk TCUs conformes | $nDesv con desviaciones | $nErr sin respuesta. $($script:UltimaAud.Count) filas listadas." ([System.Drawing.Color]::SteelBlue)
    if ($script:UltimaAud.Count -eq 0) { Con 'Toda la flota coincide con el preset de referencia.' ([System.Drawing.Color]::LightGreen) }
    Marcar-Bloque 'aud'
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

# JSON de auditoria para el Historico de la plataforma (solo desviaciones +
# recuento de TCUs auditadas/conformes de la ultima pasada)
$btnAudJson.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'JSON (*.json)|*.json'
    $dlg.FileName = 'auditoria_' + ((Nombre-Planta) -replace '[^\w\-\.]', '_') + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
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
    ConvertTo-Json $obj -Depth 5 | Set-Content $dlg.FileName -Encoding UTF8
    Con "JSON de auditoria exportado: $($dlg.FileName)  ($($script:SegAud.Count) TCUs, $conformes conformes, $($script:UltimaAud.Count) desviaciones). Subelo en la pagina Historico." ([System.Drawing.Color]::SteelBlue)
})

# ------------------------- INVENTARIO DE FLOTA -------------------------
$btnInvF.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $tcus = $null
    if (-not $cx.multi) { $tcus = Rango-Tcus $txtVIni.Text $txtVFin.Text 'Inventario' }
    $trabajos = @(Trabajos-Planta $cx $tcus)
    if ($trabajos.Count -eq 0) { Con 'La planta no tiene NCUs con gateways definidos.' ([System.Drawing.Color]::Orange); return }
    $lvV.Items.Clear(); $script:UltimoInv = @(); $lblInvF.Text = ''
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    if ($cx.multi) {
        $totTcus = 0; foreach ($tr in $trabajos) { $totTcus += @($tr.tcus).Count }
        Con "Inventario de Planta completa: $($trabajos.Count) NCUs, $totTcus TCUs (rangos por NCU automaticos)" ([System.Drawing.Color]::SteelBlue)
    } else {
        Con "Inventario de TCUs $($tcus[0])-$($tcus[-1])  ($($cx.ip):$($cx.etiqueta))" ([System.Drawing.Color]::SteelBlue)
    }
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

# JSON de inventario para el Historico de la plataforma
$btnInvJson.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'JSON (*.json)|*.json'
    $dlg.FileName = 'inventario_' + ((Nombre-Planta) -replace '[^\w\-\.]', '_') + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $obj = [ordered]@{
        tipo    = 'inventario_tcu'
        mapa    = $VERSION_MAPA
        toolbox = $VERSION_TOOLBOX
        planta  = Nombre-Planta
        ip      = $txtIp.Text.Trim()
        fecha   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        tcus    = @($script:UltimoInv)
    }
    ConvertTo-Json $obj -Depth 5 | Set-Content $dlg.FileName -Encoding UTF8
    Con "JSON de inventario exportado: $($dlg.FileName)  ($($script:UltimoInv.Count) TCUs). Subelo en la pagina Historico." ([System.Drawing.Color]::SteelBlue)
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
    $tcus = Rango-Tcus $txtPIni.Text $txtPFin.Text 'Test motor'
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
    Con "TEST DE MOTOR: TCUs $($tcus[0])-$($tcus[-1]), pulso ${pulso}s, umbral $umbral deg" ([System.Drawing.Color]::SteelBlue)
    $nPasa = 0; $nFalla = 0; $nSalta = 0
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
                $det = ("dW {0:+0.0;-0.0} deg (I {1} mA), dE {2:+0.0;-0.0} deg (I {3} mA)" -f $dW, $iW, $dE, $iE)
                if ([math]::Abs($dW) -lt $umbral -and [math]::Abs($dE) -lt $umbral) {
                    $causa = $(if ($iW -lt 30 -and $iE -lt 30) { 'sin corriente de motor' } else { 'no se mueve' })
                    Pem-Fila $tcu 'FALLA' "$causa - $det"; $nFalla++
                } elseif ($dW -lt -$umbral -and $dE -gt $umbral) {
                    Pem-Fila $tcu 'FALLA' "sentido INVERTIDO (revisar polaridad / bit 11 de 41018) - $det"; $nFalla++
                } elseif ($dW -gt $umbral -and $dE -lt -$umbral) {
                    Pem-Fila $tcu 'PASA' $det; $nPasa++
                } else {
                    Pem-Fila $tcu 'DUDOSO' "movimiento asimetrico - $det"; $nFalla++
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
    $lblPResumen.Text = "PASA $nPasa | FALLA $nFalla | saltados $nSalta"
    Con "TEST DE MOTOR terminado: PASA $nPasa | FALLA $nFalla | SALTADOS $nSalta" ([System.Drawing.Color]::SteelBlue)
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
    $tcus = Rango-Tcus $txtPIni.Text $txtPFin.Text 'Modo'
    $modo = @{'OFF'=0; 'MANUAL'=1; 'AUTO'=2}[[string]$cbPModo.SelectedItem]
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Pasar $($tcus.Count) TCUs a modo $($cbPModo.SelectedItem)?", 'Cambio de modo', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $lvP.Items.Clear(); $script:UltimoPem = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Cambio de modo a $($cbPModo.SelectedItem) en TCUs $($tcus[0])-$($tcus[-1])" ([System.Drawing.Color]::SteelBlue)
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
    $tcus = Rango-Tcus $txtPIni.Text $txtPFin.Text 'Clear'
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Desenclavar alarmas de motor (40007 bit 13) en $($tcus.Count) TCUs?", 'Clear alarmas', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $lvP.Items.Clear(); $script:UltimoPem = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Clear de alarmas enclavadas en TCUs $($tcus[0])-$($tcus[-1])" ([System.Drawing.Color]::SteelBlue)
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
    $tcus = Rango-Tcus $txtPIni.Text $txtPFin.Text 'Stow'
    $txtAccion = $(if ($n -gt 0) { "ACTIVAR safe position $n" } else { 'QUITAR el stow' })
    $r = [System.Windows.Forms.MessageBox]::Show(
        "$txtAccion en $($tcus.Count) TCUs? Los seguidores se moveran.", 'Stow', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $lvP.Items.Clear(); $script:UltimoPem = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "$txtAccion en TCUs $($tcus[0])-$($tcus[-1])" ([System.Drawing.Color]::SteelBlue)
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
                $e = ($v -shr 3) -band 0x3
                $nom = $ESTADOS_COMIS[[int]$e]
                if (-not $cuenta.ContainsKey($nom)) { $cuenta[$nom] = 0 }
                $cuenta[$nom]++
                Pem-Fila $tcu $(if ($e -eq 0) { 'OK' } else { 'PENDIENTE' }) "$e - $nom" "$($tr.ncu)"
            }
        }
    } else {
        $tcus = Rango-Tcus $txtPIni.Text $txtPFin.Text 'Comisionado'
        Con "Estado de comisionado (30001 bits 4:3) en TCUs $($tcus[0])-$($tcus[-1])" ([System.Drawing.Color]::SteelBlue)
        $segs = @(Plan-Segmentos $tcus $cx)
        foreach ($seg in $segs) {
            if ($script:Cancelar) { break }
            try { Modbus-Conectar $cx.ip $seg.puerto $cx.to }
            catch { foreach ($tcu in $seg.tcus) { Pem-Fila $tcu 'FALLA' "sin conexion" }; continue }
            foreach ($tcu in $seg.tcus) {
                if (Chequear-Cancelado) { break }
                try {
                    $v = (FC03-Leer $tcu (Dir-Trama 30001) 1)[0]
                    $e = ($v -shr 3) -band 0x3
                    $nom = $ESTADOS_COMIS[[int]$e]
                    if (-not $cuenta.ContainsKey($nom)) { $cuenta[$nom] = 0 }
                    $cuenta[$nom]++
                    Pem-Fila $tcu $(if ($e -eq 0) { 'OK' } else { 'PENDIENTE' }) "$e - $nom"
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
    $tcus = Rango-Tcus $txtPIni.Text $txtPFin.Text 'Comisionado'
    $obj = [int]([string]$cbPComis.SelectedItem).Split(' ')[0]
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Fijar estado de comisionado '$($ESTADOS_COMIS[$obj])' ($obj) en $($tcus.Count) TCUs?`r`nRecuerda GUARDAR EN NVM despues.",
        'Comisionado', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $lvP.Items.Clear(); $script:UltimoPem = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Fijando comisionado=$obj ($($ESTADOS_COMIS[$obj])) en TCUs $($tcus[0])-$($tcus[-1])" ([System.Drawing.Color]::SteelBlue)
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
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'pem_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:UltimoPem | Export-Csv $dlg.FileName -NoTypeInformation -Encoding UTF8
        Con "CSV exportado: $($dlg.FileName)" ([System.Drawing.Color]::SteelBlue)
    }
})

# Seguimiento PEM de la sesion: una fila por TCU con las tres tareas de la
# ficha (Cold commissioning = LEER ESTADO de comisionado, Configuracion TCU =
# auditoria contra preset, Prueba movimiento = TEST DE MOTOR). Se sube a la
# plataforma en la pagina de Historico, como los diagnosticos.
$btnPSeg.Add_Click({
    $filas = @(Seguimiento-Filas)
    if ($filas.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Aun no hay datos: ejecuta LEER ESTADO (comisionado), la Auditoria de Flota o el TEST DE MOTOR.','Aviso'); return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'JSON (*.json)|*.json'
    $dlg.FileName = 'seguimiento_pem_' + ((Nombre-Planta) -replace '[^\w\-\.]', '_') + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.json'
    if ($dlg.ShowDialog() -ne 'OK') { return }
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
    ConvertTo-Json $obj -Depth 5 | Set-Content $dlg.FileName -Encoding UTF8
    $nOk = @($filas | Where-Object { $_.cold_commissioning -eq 'OK' -and $_.config_tcu -eq 'OK' -and $_.prueba_movimiento -eq 'OK' }).Count
    Con "Seguimiento PEM exportado: $($dlg.FileName)  ($($filas.Count) TCUs, $nOk con las 3 tareas OK). Subelo en la pagina Historico de la plataforma." ([System.Drawing.Color]::SteelBlue)
})

# ------------------------- CAMPANA DE FIRMWARE -------------------------
# La toolbox no actualiza firmware (eso lo hace el TCU Updater de Sunner):
# planifica la campana desde el inventario y verifica el resultado.
$script:PlanFw = @()
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
    $plan = Plan-Firmware $script:UltimoInv $txtFwObj.Text $gws
    $script:PlanFw = @($plan.tramos)
    $lvFW.Items.Clear()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "PLAN DE FIRMWARE hacia $($txtFwObj.Text.Trim()): $($plan.pendientes) TCUs pendientes, $($plan.al_dia) ya al dia, $(@($plan.sin_respuesta).Count) sin respuesta en el inventario" ([System.Drawing.Color]::SteelBlue)
    # carril = NCU + gateway: cada uno puede llevar su propia ventana del updater
    $minTcu = Val-Int $txtFwMin.Text 'min/TCU' 1 600
    $carga = @{}
    foreach ($t in $script:PlanFw) {
        $k = "$($t.NCU)|$($t.Puerto)"
        $carga[$k] = [int]$carga[$k] + [int]$t.TCUs
    }
    foreach ($t in $script:PlanFw) {
        $k = "$($t.NCU)|$($t.Puerto)"
        $h = [math]::Round(($carga[$k] * $minTcu) / 60.0, 1)
        $item = New-Object System.Windows.Forms.ListViewItem("$($t.NCU)")
        foreach ($c in @($ips["$($t.NCU)"], $t.Puerto, $t.Desde, $t.Hasta, $t.TCUs, "carril NCU$($t.NCU)/GW$($t.Puerto): $($carga[$k]) TCUs ~ $h h")) { [void]$item.SubItems.Add("$c") }
        $item.ForeColor = [System.Drawing.Color]::DarkOrange
        $lvFW.Items.Add($item) | Out-Null
        Con ("  NCU{0,-3} {1,-15} GW {2}   TCUs {3}-{4}  ({5})" -f $t.NCU, $ips["$($t.NCU)"], $t.Puerto, $t.Desde, $t.Hasta, $t.TCUs) ([System.Drawing.Color]::Gainsboro)
    }
    if ($plan.pendientes -gt 0) {
        $hSec = [math]::Round(($plan.pendientes * $minTcu) / 60.0, 1)
        $hPar = [math]::Round(((@($carga.Values | Measure-Object -Maximum).Maximum) * $minTcu) / 60.0, 1)
        Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
        Con ("A {0} min/TCU: una sola ventana = {1} h ({2} dias de 8 h). Con {3} carriles en paralelo (una ventana del updater por NCU+gateway) = {4} h, marcadas por el carril mas cargado." -f `
            $minTcu, $hSec, [math]::Round($hSec / 8.0, 1), $carga.Count, $hPar) ([System.Drawing.Color]::Orange)
    }
    foreach ($m in @($plan.sin_respuesta)) {
        $item = New-Object System.Windows.Forms.ListViewItem("$($m.ncu)")
        foreach ($c in @($ips["$($m.ncu)"], '-', $m.tcu, $m.tcu, 1, "sin respuesta en el inventario: $($m.nota)")) { [void]$item.SubItems.Add("$c") }
        $item.ForeColor = [System.Drawing.Color]::Gray
        $lvFW.Items.Add($item) | Out-Null
    }
    $lblFw.Text = "$($plan.pendientes) pendientes | $($plan.al_dia) al dia | $(@($plan.sin_respuesta).Count) sin respuesta"
    if ($script:PlanFw.Count -eq 0 -and $plan.al_dia -gt 0) { Con "Toda la flota inventariada ya esta en $($txtFwObj.Text.Trim())." ([System.Drawing.Color]::LightGreen) }
    else { Con 'Pega cada tramo en el TCU Updater (NCU IP + Gateway port + Add from...to) y al terminar pulsa VERIFICAR TRAS ACTUALIZAR.' ([System.Drawing.Color]::Gainsboro) }
    $btnFwCsv.Enabled = ($lvFW.Items.Count -gt 0)
    $btnFwVerif.Enabled = ($script:PlanFw.Count -gt 0)
} })

$btnFwVerif.Add_Click({ Lanzar {
    if ($script:PlanFw.Count -eq 0) { return }
    $cx = Params-Conexion
    $obj = $txtFwObj.Text.Trim()
    $trabajos = @(Trabajos-Planta $cx $null)
    $porNcu = @{}
    foreach ($tr in $trabajos) { $porNcu[$(if ($null -ne $tr.ncu) { "$($tr.ncu)" } else { '' })] = $tr }
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Verificando firmware de las TCUs del plan (objetivo $obj)..." ([System.Drawing.Color]::SteelBlue)
    $ok = 0; $ko = 0; $err = 0
    foreach ($t in $script:PlanFw) {
        if ($script:Cancelar) { break }
        $tr = $porNcu["$($t.NCU)"]
        if (-not $tr) { continue }
        $tcus = @([int]$t.Desde..[int]$t.Hasta)
        foreach ($seg in @(Plan-Segmentos $tcus $tr.cx)) {
            try { Modbus-Conectar $tr.ip $seg.puerto $tr.cx.to } catch { $err += @($seg.tcus).Count; continue }
            foreach ($tcu in $seg.tcus) {
                if (Chequear-Cancelado) { break }
                $fw = $null
                try {
                    $campos = Ident-Leer $tcu
                    $fw = ($campos | Where-Object { $_.Campo -eq 'FW principal' }).Valor
                } catch { $err++; continue }
                if ("$fw" -like "*$obj*") { $ok++ }
                else { $ko++; Con ("  NCU{0} TCU {1,3}  sigue en {2}" -f $t.NCU, $tcu, $fw) ([System.Drawing.Color]::Orange) }
            }
            Modbus-Cerrar
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    Modbus-Cerrar
    $lblFw.Text = "Verificacion: $ok en $obj | $ko pendientes | $err sin respuesta"
    Con ('-' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Verificacion: $ok TCUs ya en $obj, $ko siguen pendientes, $err sin respuesta. Lanza un INVENTARIO nuevo para dejar constancia (y subirlo al Historico)." ([System.Drawing.Color]::SteelBlue)
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
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'plan_firmware_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:PlanFw | Export-Csv $dlg.FileName -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Con "Plan exportado: $($dlg.FileName)" ([System.Drawing.Color]::SteelBlue)
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
            if (-not $h.comunica) { [void]$lineas.Add("$ts;$fecha;$($tr.ncu);$($h.hsu);FALLO"); $nMal++ }
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
            Sat-Log 'D.1.1 / D.3.4' "$n TCUs registradas (pase $($script:SatPasesT))"
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
        $dias = Val-Int $txtSatDias.Text 'Dias' 1 30
        $cx = Params-Conexion
        if (-not $cx.multi) {
            $r0 = [System.Windows.Forms.MessageBox]::Show(
                "El anexo pide el 100% de la planta y ahora mismo hay una NCU suelta seleccionada.`r`n`r`nContinuar de todas formas?",
                'Alcance del ensayo', 'YesNo', 'Warning')
            if ($r0 -ne 'Yes') { return }
        }
        $script:SatDir = Join-Path (Join-Path $PSScriptRoot 'informes') ('sat_' + ((Nombre-Planta) -replace '[^\w\-]', '_'))
        if (-not (Test-Path $script:SatDir)) { New-Item -ItemType Directory -Path $script:SatDir -Force | Out-Null }
        $script:SatHasta = (Get-Date).AddDays($dias)
        $script:SatProxTcu = [datetime]::MinValue; $script:SatProxCom = [datetime]::MinValue
        $script:SatPasesT = 0; $script:SatPasesC = 0; $script:SatFallos = 0
        $script:SatOn = $true
        $btnSatIni.Enabled = $false; $btnSatFin.Enabled = $true
        $tmrSat.Start()
        Sat-Log 'INICIO' "Cada $($script:SatIntTcu)s (TCU) y $($script:SatIntCom)s (comms) hasta $($script:SatHasta.ToString('yyyy-MM-dd HH:mm')). Carpeta: $script:SatDir"
        Con "Registro SAT iniciado. NO CIERRES ESTA VENTANA hasta que termine el ensayo. Carpeta: $script:SatDir" ([System.Drawing.Color]::Orange)
    } catch { Con "ERROR: $_" ([System.Drawing.Color]::Salmon) }
})

$btnSatFin.Add_Click({
    $script:SatOn = $false; $tmrSat.Stop()
    $btnSatIni.Enabled = $true; $btnSatFin.Enabled = $false
    Sat-Log 'PARADA' "Detenido a mano. Pases TCU: $($script:SatPasesT), pases comms: $($script:SatPasesC)."
    Con 'Registro SAT detenido.' ([System.Drawing.Color]::Orange)
})

$btnSatAnal.Add_Click({ Lanzar {
    $dir = $script:SatDir
    if (-not $dir -or -not (Test-Path $dir)) {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Carpeta con los CSV del ensayo SAT'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $dir = $dlg.SelectedPath
    }
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Analizando ensayos SAT en $dir" ([System.Drawing.Color]::SteelBlue)
    $fp = @(Get-ChildItem (Join-Path $dir 'precision_*.csv') -ErrorAction SilentlyContinue)
    $fc = @(Get-ChildItem (Join-Path $dir 'comm_*.csv') -ErrorAction SilentlyContinue)
    if ($fp.Count -eq 0 -and $fc.Count -eq 0) { Con 'No hay ficheros de registro en esa carpeta.' ([System.Drawing.Color]::Orange); return }
    $lvSat.Items.Clear()

    if ($fp.Count -gt 0) {
        $filas = @()
        foreach ($f in $fp) { $filas += @(Import-Csv $f.FullName -Delimiter ';') }
        Con "  D.1.1 / D.3.4: $($filas.Count) registros de $($fp.Count) dia(s)" ([System.Drawing.Color]::Gainsboro)
        $pr = @(Sat-Precision $filas 1.0 2)
        $malP = @($pr | Where-Object { $_.Cumple -eq 'NO' })
        $pr | Export-Csv (Join-Path $dir 'RESULTADO_D1.1_precision.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Sat-Log 'D.1.1' ("Precision <=1 deg: {0} de {1} TCUs cumplen{2}" -f ($pr.Count - $malP.Count), $pr.Count, $(if ($malP.Count) { " - INCUMPLEN: " + (($malP | ForEach-Object { "NCU$($_.NCU)/$($_.TCU)" }) -join ', ') } else { '' }))
        $do = @(Sat-DispOperacion $filas 99.0)
        $malO = @($do | Where-Object { $_.Cumple -eq 'NO' })
        $do | Export-Csv (Join-Path $dir 'RESULTADO_D3.4.1_disp_operacion.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Sat-Log 'D.3.4.1' ("Disponibilidad >=99%: {0} de {1} TCU-dia cumplen{2}" -f ($do.Count - $malO.Count), $do.Count, $(if ($malO.Count) { " - INCUMPLEN: " + (($malO | Select-Object -First 20 | ForEach-Object { "$($_.Dia) NCU$($_.NCU)/$($_.TCU) $($_.Disponibilidad_pct)%" }) -join ', ') } else { '' }))
    }

    if ($fc.Count -gt 0) {
        $ev = @()
        foreach ($f in $fc) { $ev += @(Import-Csv $f.FullName -Delimiter ';') }
        $intentos = @{}
        foreach ($e in $ev) { if ($e.equipo -eq 'PASE') { $intentos["$($e.fecha)"] = [int]$intentos["$($e.fecha)"] + [int]$e.evento } }
        $fallos = @($ev | Where-Object { $_.evento -eq 'FALLO' } | ForEach-Object {
            [pscustomobject]@{dia=$_.fecha; ncu=$_.ncu; equipo=$_.equipo; ts=$_.ts} })
        Con "  D.4: $($ev.Count) eventos, $($fallos.Count) fallos brutos" ([System.Drawing.Color]::Gainsboro)
        $dc = @(Sat-DispComms $fallos $intentos 98.5 120)
        $malC = @($dc | Where-Object { $_.Cumple -eq 'NO' })
        $dc | Export-Csv (Join-Path $dir 'RESULTADO_D4_disp_comunicaciones.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Sat-Log 'D.4' ("Comunicaciones >=98,5%: {0} de {1} equipo-dia cumplen{2}" -f ($dc.Count - $malC.Count), $dc.Count, $(if ($malC.Count) { " - INCUMPLEN: " + (($malC | Select-Object -First 20 | ForEach-Object { "$($_.Dia) NCU$($_.NCU)/$($_.Equipo) $($_.Disponibilidad_pct)%" }) -join ', ') } else { '' }))
    }
    Con "Resultados escritos en $dir (ficheros RESULTADO_*.csv)." ([System.Drawing.Color]::LightGreen)
} })

$btnHBuscar.Add_Click({ Lanzar {
    $cx = Params-Conexion
    $p = $null; if ($cbPlanta.SelectedItem) { $p = $PLANTAS[$cbPlanta.SelectedItem] }
    $ncus = @()
    if ($cx.multi) {
        foreach ($n in $cx.multi) { $ncus += ,@{ncu="$($n.ncu)"; ip=$n.ip; hsu=$n.hsu; gws=$n.gws} }
    } else {
        $eti = ''
        $m = [regex]::Match("$($cbPlanta.SelectedItem)", 'NCU(\d+)')
        if ($m.Success) { $eti = $m.Groups[1].Value }
        $ncus += ,@{ncu=$eti; ip=$cx.ip; hsu=$(if ($p) { $p.hsu } else { $null }); gws=$cx.gws}
    }
    $lvH.Items.Clear()
    $script:HsusPlanta = @()
    Con ('=' * 96) ([System.Drawing.Color]::SteelBlue)
    Con "Buscando HSUs en $($ncus.Count) NCU(s) via bloque compacto (puerto $PUERTO_NCU)..." ([System.Drawing.Color]::SteelBlue)
    foreach ($n in $ncus) {
        if ($script:Cancelar) { break }
        $filas = @()
        try { Modbus-Conectar $n.ip $PUERTO_NCU $cx.to; $filas = @(Ncu-HsuCompat) }
        catch { Con "AVISO: NCU$($n.ncu) ($($n.ip)): sin respuesta en ${PUERTO_NCU}: $_" ([System.Drawing.Color]::Orange) }
        Modbus-Cerrar
        if ($filas.Count -eq 0) { Con "$(if ($n.ncu) { "NCU$($n.ncu)" } else { $n.ip }): sin HSUs en el bloque compacto." ([System.Drawing.Color]::Gainsboro); continue }
        foreach ($f in $filas) {
            $eti = ($(if ($n.ncu) { "NCU$($n.ncu) - " } else { '' }) + $f.TCU)
            $script:HsusPlanta += ,@{etiqueta=$eti; ncu="$($n.ncu)"; ip=$n.ip; hsu=$n.hsu; gws=$n.gws; salud=$f.Salud; texto=$f.Alarmas}
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
    }
    $cbHsuSel.Items.Clear()
    [void]$cbHsuSel.Items.Add("(todas: $($script:HsusPlanta.Count) HSUs)")
    foreach ($h in $script:HsusPlanta) { [void]$cbHsuSel.Items.Add("$($h.etiqueta)  [$($h.ip)]") }
    $cbHsuSel.SelectedIndex = 0
    $lblHSel.Text = "$($script:HsusPlanta.Count) HSUs encontradas. Elige una para fijar su IP" + $(if (@($script:HsusPlanta | Where-Object { $_.hsu }).Count) { ' y esclavo' } else { '' }) + ' (las operaciones directas van por su GW).'
    Con "HSUs encontradas: $($script:HsusPlanta.Count). Al elegir una en el desplegable se fija su IP (y esclavo si la topologia lo trae) para las operaciones directas." ([System.Drawing.Color]::SteelBlue)
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
    Con "HSU seleccionada: $($h.etiqueta) -> IP $($h.ip)$(if ($h.hsu) { ", esclavo $($h.hsu)" } else { '' }). Pon el puerto del GW del que cuelga para METEO/CONFIG/caja negra." ([System.Drawing.Color]::SteelBlue)
})

function Params-Hsu {
    $cx = Params-Conexion
    if ($cx.multi -or -not $cx.puerto) {
        # La HSU cuelga de un gateway concreto, pero si se ha elegido una en el
        # desplegable ya sabemos de que NCU es (BUSCAR HSUs lo resuelve): se usa
        # su IP y el primer gateway de esa NCU en vez de obligar a cambiar la
        # entrada de conexion a mano.
        $h = $script:HsuSel
        if ($h -and $h.ip) {
            $puerto = $null
            $gws = $(if ($h.gws) { $h.gws } else { $cx.gws })
            if ($gws -and @($gws).Count -gt 0) { $puerto = @($gws | Sort-Object { [int]$_.puerto })[0].puerto }
            if (-not $puerto) { $puerto = 503 }   # GW1, el habitual cuando la topologia no lo declara
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
    $cx = Params-Conexion
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
        if (-not $puerto) { $puerto = 503 }
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
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'hsu_cajanegra_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.csv'
    if ($dlg.ShowDialog() -ne 'OK') { return }
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
    $filas | Export-Csv $dlg.FileName -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Con "Caja negra exportada: $($dlg.FileName)  ($minutos minutos$(if ($minutos -lt 1440) { ', INCOMPLETA' }))." ([System.Drawing.Color]::SteelBlue)
    $vmax = ($filas | Measure-Object -Property Vmax_kmh -Maximum).Maximum
    Con ("Viento maximo del dia registrado por la HSU: {0} km/h." -f $vmax) ([System.Drawing.Color]::SteelBlue)
} })

# ------------------------- log manual -------------------------
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
                   inv = $script:UltimoInv; esc = $script:UltimaEscritura; lectura = $script:UltimaLectura}
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
            fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm'); usuario = "$env:USERNAME"
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

Config-Restaurar
[void]$form.ShowDialog()
Modbus-Cerrar
