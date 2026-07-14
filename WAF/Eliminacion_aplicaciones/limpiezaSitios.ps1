<#
.SYNOPSIS
    Automatiza la baja masiva de aplicaciones en un Azure Application Gateway (WAF).
    
.DESCRIPTION
    Este script elimina de forma segura y ordenada todos los componentes asociados
    a una o más aplicaciones: Reglas, Listeners, Backend Settings, Pools y Probes.
    Realiza una sola actualización (Set-AzApplicationGateway) al final del ciclo 
    para optimizar tiempos de ejecución en Azure.

.USAGE
    1. Configura las variables en la sección "PARÁMETROS PRINCIPALES".
    2. Añade los subdominios que deseas eliminar en "CONFIGURACIÓN DE APLICACIONES".
    3. Ejecuta el script.
#>

# =================================================================================
# --- PARÁMETROS PRINCIPALES (Ajusta estos valores para tu entorno) ---
# =================================================================================
$resourceGroupName = "rg-waf-prod-eastus-001"
$appGatewayName    = "waf-pvt-prod-eastus-003"
$subscriptionId    = "Produccion"

# =================================================================================
# --- CONFIGURACIÓN DE APLICACIONES (Define aquí lo que vas a dar de baja) ---
# =================================================================================
$ConfiguracionDeApps = @(
    @{
        Subdominio   = "supervision" # Solo el subdominio a eliminar
        NecesitaIPv6 = $false        # $true si también se había creado el listener/regla IPv6
    }
    # Puedes añadir más bloques @{...} para borrar múltiples aplicativos de un solo golpe
)

# =================================================================================
# --- LÓGICA DE DEGRADACIÓN / ELIMINACIÓN (No requiere modificaciones) ---
# =================================================================================

Write-Host "Iniciando proceso de eliminación masiva en el WAF '$appGatewayName'..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $subscriptionId

# Obtener el estado actual del WAF en memoria
$waf = Get-AzApplicationGateway -Name $appGatewayName -ResourceGroupName $resourceGroupName

$appsProcesadas = 0

foreach ($app in $ConfiguracionDeApps) {
    $sub = $app.Subdominio
    $hostNameCompleto = "$sub.cnbv.gob.mx"
    
    Write-Host "----------------------------------------------------------------"
    Write-Host "Preparando eliminación de la aplicación: $hostNameCompleto" -ForegroundColor Magenta
    Write-Host "----------------------------------------------------------------"

    # Mapeo exacto de los nombres de componentes generados en la creación
    $probeName        = "HPs443-$sub"
    $poolName         = "BEP-$sub"
    $settingsName     = "BESs443-$sub"
    $listenerName443  = "Ls443-$sub"
    $ruleName443      = "Rs443-$sub"
    $listenerNameIPv6 = "Ls443IPv6-$sub"
    $ruleNameIPv6     = "Rs443IPv6-$sub"

    # --- 1. ELIMINAR REGLAS DE ENRUTAMIENTO (RULES) ---
    if ($waf.RequestRoutingRules.Name -contains $ruleNameIPv6) {
        Write-Host "1a. Removiendo Regla IPv6: $ruleNameIPv6" -ForegroundColor Cyan
        $waf = Remove-AzApplicationGatewayRequestRoutingRule -ApplicationGateway $waf -Name $ruleNameIPv6
    }
    if ($waf.RequestRoutingRules.Name -contains $ruleName443) {
        Write-Host "1b. Removiendo Regla IPv4: $ruleName443" -ForegroundColor Cyan
        $waf = Remove-AzApplicationGatewayRequestRoutingRule -ApplicationGateway $waf -Name $ruleName443
    }

    # --- 2. ELIMINAR AGENTES DE ESCUCHA (LISTENERS) ---
    if ($waf.HttpListeners.Name -contains $listenerNameIPv6) {
        Write-Host "2a. Removiendo Listener IPv6: $listenerNameIPv6" -ForegroundColor Cyan
        $waf = Remove-AzApplicationGatewayHttpListener -ApplicationGateway $waf -Name $listenerNameIPv6
    }
    if ($waf.HttpListeners.Name -contains $listenerName443) {
        Write-Host "2b. Removiendo Listener IPv4: $listenerName443" -ForegroundColor Cyan
        $waf = Remove-AzApplicationGatewayHttpListener -ApplicationGateway $waf -Name $listenerName443
    }

    # --- 3. ELIMINAR CONFIGURACIÓN DE BACK-END (BACKEND HTTP SETTINGS) ---
    if ($waf.BackendHttpSettingsCollection.Name -contains $settingsName) {
        Write-Host "3. Removiendo Configuración de Back-end: $settingsName" -ForegroundColor Cyan
        $waf = Remove-AzApplicationGatewayBackendHttpSettings -ApplicationGateway $waf -Name $settingsName
    }

    # --- 4. ELIMINAR GRUPO DE DIRECCIONES DE BACK-END (BACKEND POOL) ---
    if ($waf.BackendAddressPools.Name -contains $poolName) {
        Write-Host "4. Removiendo Grupo de Back-end: $poolName" -ForegroundColor Cyan
        $waf = Remove-AzApplicationGatewayBackendAddressPool -ApplicationGateway $waf -Name $poolName
    }

    # --- 5. ELIMINAR SONDEO DE ESTADO (HEALTH PROBE) ---
    if ($waf.Probes.Name -contains $probeName) {
        Write-Host "5. Removiendo Sondeo de Estado: $probeName" -ForegroundColor Cyan
        $waf = Remove-AzApplicationGatewayProbeConfig -ApplicationGateway $waf -Name $probeName
    }

    $appsProcesadas++
    Write-Host "Componentes de '$hostNameCompleto' removidos de la memoria local." -ForegroundColor DarkYellow
}

# --- APLICAR CAMBIOS EN AZURE ---
if ($appsProcesadas -gt 0) {
    Write-Host "================================================================"
    Write-Host "Enviando actualizaciones a Azure. Esto puede tomar unos minutos..." -ForegroundColor Blue
    Write-Host "================================================================"
    
    # Un solo commit para procesar todas las bajas juntas
    $waf = Set-AzApplicationGateway -ApplicationGateway $waf
    
    Write-Host "🎉 La desconfiguración masiva se ha completado en producción de manera exitosa." -ForegroundColor Green
} else {
    Write-Host "No se encontraron aplicaciones válidas para procesar en el arreglo." -ForegroundColor Red
}