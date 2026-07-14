# =================================================================================
# --- PARÁMETROS PRINCIPALES Y CONFIGURACIÓN ---
# =================================================================================
$rg      = "rg-waf-prod-eastus-001"
$wafName = "waf-pvt-prod-eastus-003"

$ConfiguracionDeApps = @(
    @{ Subdominio = "supervision"; NecesitaIPv6 = $false }
)

# Iniciar sesión si no lo has hecho: az login
Write-Host "Iniciando eliminación con Azure CLI..." -ForegroundColor Yellow

foreach ($app in $ConfiguracionDeApps) {
    $sub = $app.Subdominio
    Write-Host "Procesando baja de: $sub" -ForegroundColor Magenta

    # Mapeo de nombres
    $probeName        = "HPs443-$sub"
    $poolName         = "BEP-$sub"
    $settingsName     = "BESs443-$sub"
    $listenerName443  = "Ls443-$sub"
    $ruleName443      = "Rs443-$sub"
    $listenerNameIPv6 = "Ls443IPv6-$sub"
    $ruleNameIPv6     = "Rs443IPv6-$sub"

    # 1. Eliminar Reglas (Routing Rules)
    if ($app.NecesitaIPv6) {
        Write-Host "Removiendo Regla IPv6..."
        az network application-gateway routing-rule delete -g $rg --gateway-name $wafName -n $ruleNameIPv6
    }
    Write-Host "Removiendo Regla IPv4..."
    az network application-gateway routing-rule delete -g $rg --gateway-name $wafName -n $ruleName443

    # 2. Eliminar Agentes de Escucha (Listeners)
    if ($app.NecesitaIPv6) {
        Write-Host "Removiendo Listener IPv6..."
        az network application-gateway http-listener delete -g $rg --gateway-name $wafName -n $listenerNameIPv6
    }
    Write-Host "Removiendo Listener IPv4..."
    az network application-gateway http-listener delete -g $rg --gateway-name $wafName -n $listenerName443

    # 3. Eliminar Configuración HTTP de Backend (Http Settings)
    Write-Host "Removiendo Backend HTTP Settings..."
    az network application-gateway http-settings delete -g $rg --gateway-name $wafName -n $settingsName

    # 4. Eliminar Grupo de Backend (Backend Pool)
    Write-Host "Removiendo Backend Address Pool..."
    az network application-gateway address-pool delete -g $rg --gateway-name $wafName -n $poolName

    # 5. Eliminar Sondeo de Estado (Probe)
    Write-Host "Removiendo Health Probe..."
    az network application-gateway probe delete -g $rg --gateway-name $wafName -n $probeName
}

Write-Host "🎉 Proceso completado con Azure CLI." -ForegroundColor Green