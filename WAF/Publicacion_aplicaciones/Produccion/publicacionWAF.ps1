<#
.SYNOPSIS
    Automatiza el alta completa de aplicaciones en un Azure Application Gateway (WAF) V2,
    incluyendo la creación y asignación de políticas WAF dedicadas por sitio.
#>

# =================================================================================
# --- PARÁMETROS PRINCIPALES (Ajusta estos valores para tu entorno) ---
# =================================================================================
$resourceGroupName = "rg-waf-qa-eastus-001"
$appGatewayName = "waf-pvt-qa-eastus-001"
$subscriptionId = "QA"

# Nombres de recursos existentes en tu WAF que se usarán como base
$puertoFrontEnd443 = "port_443"          # Nombre del puerto de front-end para 443
$puertoFrontEnd80 = "port_80"           # Nombre del puerto de front-end para 80
$certificadoSsl = "cnbv-wildcard"       # Nombre de tu certificado SSL Wildcard

# =================================================================================
# --- CONFIGURACIÓN DE APLICACIONES (Aquí defines todo lo que quieres crear) ---
# =================================================================================
$ConfiguracionDeApps = @(
    @{
        Subdominio         = "balam-ha-qa"      # Solo el subdominio, sin .cnbv.gob.mx
        BackendIPs         = @("10.70.20.121")  # IP o FQDN de los servidores de backend
        PrioridadRegla     = 550                # Prioridad base para la regla
        Puerto             = 443                # <- NUEVO: Soporta 443 o 80 de forma dinámica
        NecesitaIPv6       = $false             # $true si necesitas listener y regla para IPv6
        AsociarPoliticaWaf = $true              # <- NUEVO: $true para crear y asignar una política WAF exclusiva al sitio
    }
    # Puedes añadir más bloques @{...} aquí abajo separados por comas
)

# =================================================================================
# --- LÓGICA DE AUTOMATIZACIÓN (No necesitas modificar debajo de esta línea) ---
# =================================================================================

Write-Host "Iniciando la configuración masiva en el Application Gateway '$appGatewayName'..." -ForegroundColor Cyan
Set-AzContext -SubscriptionId $subscriptionId

# Obtener la versión más reciente del WAF una sola vez al inicio
$waf = Get-AzApplicationGateway -Name $appGatewayName -ResourceGroupName $resourceGroupName

# --- Información de Front-end requerida ---
$frontendPort443 = $waf.FrontendPorts | Where-Object { $_.Name -eq $puertoFrontEnd443 }
$frontendPort80 = $waf.FrontendPorts | Where-Object { $_.Name -eq $puertoFrontEnd80 }
$sslCert = $waf.SslCertificates | Where-Object { $_.Name -eq $certificadoSsl }
$frontendIPv4 = $waf.FrontendIPConfigurations[0] 
$frontendIPv6 = $waf.FrontendIPConfigurations[1]

# --- Bucle principal para procesar cada aplicación ---
foreach ($app in $ConfiguracionDeApps) {
    
    $sub = $app.Subdominio
    $hostNameCompleto = "$sub.cnbv.gob.mx"
    $puertoApp = $app.Puerto

    Write-Host "----------------------------------------------------------------"
    Write-Host "Procesando aplicación: $hostNameCompleto (Puerto: $puertoApp)" -ForegroundColor Yellow
    Write-Host "----------------------------------------------------------------"

    # --- Lógica Intuitiva de Nombres y Protocolos basada en el Puerto ---
    if ($puertoApp -eq 80) {
        $protocolo = "Http"
        $prefijo   = "80"
        $frontendPortObj = $frontendPort80
    } else {
        $puertoApp = 443 # Validamos por defecto seguro
        $protocolo = "Https"
        $prefijo   = "s443"
        $frontendPortObj = $frontendPort443
    }

    # Asignación dinámica de nombres utilizando el nuevo prefijo
    $probeName        = "HP$($prefijo)-$sub"
    $poolName         = "BEP-$sub"
    $settingsName     = "BES$($prefijo)-$sub"
    $listenerName443  = "L$($prefijo)-$sub"
    $ruleName443      = "R$($prefijo)-$sub"
    $listenerNameIPv6 = "L$($prefijo)IPv6-$sub"
    $ruleNameIPv6     = "R$($prefijo)IPv6-$sub"
    $wafPolicyName    = "Pwaf-$sub-eastus-001" # Nombre sugerido para la política WAF del sitio

    # --- 0. CREACIÓN DE LA POLÍTICA WAF POR SITIO (NUEVO) ---
    $wafPolicy = $null
    if ($app.AsociarPoliticaWaf) {
        Write-Host "0. Validando Política WAF dedicada: $wafPolicyName..."
        $wafPolicy = Get-AzWebApplicationFirewallPolicy -Name $wafPolicyName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
        
        if ($null -eq $wafPolicy) {
            Write-Host "   -> Creando nueva política WAF en modo prevención (CRS 3.2)..." -ForegroundColor Generic
            $policySetting = New-AzWebApplicationFirewallPolicySetting -Mode Prevention -State Enabled
            $managedRules = New-AzWebApplicationFirewallPolicyManagedRule -ManagedRuleSet @(New-AzWebApplicationFirewallPolicyManagedRuleSet -RuleSetType "OWASP" -RuleSetVersion "3.2")
            $wafPolicy = New-AzWebApplicationFirewallPolicy -Name $wafPolicyName -ResourceGroupName $resourceGroupName -Location $waf.Location -PolicySetting $policySetting -ManagedRule $managedRules
        } else {
            Write-Host "   -> La política WAF '$wafPolicyName' ya existe. Reutilizando." -ForegroundColor Gray
        }
    }

    # --- 1. CREAR SONDEO DE ESTADO (HEALTH PROBE) ---
    if ($waf.Probes.Name -notcontains $probeName) {
        Write-Host "1. Creando Sondeo de Estado: $probeName ($protocolo)"
        $waf = Add-AzApplicationGatewayProbeConfig `
            -ApplicationGateway $waf `
            -Name $probeName `
            -Protocol $protocolo `
            -HostName $hostNameCompleto `
            -Path "/" `
            -Interval 30 `
            -Timeout 20 `
            -UnhealthyThreshold 3
    } else {
        Write-Host "1. El sondeo de estado '$probeName' ya existe. Omitiendo." -ForegroundColor Gray
    }

    # --- 2. CREAR GRUPO DE BACK-END (BACKEND POOL) ---
    if ($waf.BackendAddressPools.Name -notcontains $poolName) {
        Write-Host "2. Creando Grupo de Back-end: $poolName"
        $waf = Add-AzApplicationGatewayBackendAddressPool `
            -ApplicationGateway $waf `
            -Name $poolName `
            -BackendIPAddresses $app.BackendIPs
    } else {
        Write-Host "2. El grupo de back-end '$poolName' ya existe. Omitiendo." -ForegroundColor Gray
    }
    
    # --- 3. CREAR CONFIGURACIÓN DE BACK-END (BACKEND SETTINGS) ---
    $probe = $waf.Probes | Where-Object { $_.Name -eq $probeName }
    if ($waf.BackendHttpSettingsCollection.Name -notcontains $settingsName) {
        Write-Host "3. Creando Configuración de Back-end: $settingsName (Puerto: $puertoApp)"
        $waf = Add-AzApplicationGatewayBackendHttpSettings `
            -ApplicationGateway $waf `
            -Name $settingsName `
            -Port $puertoApp `
            -Protocol $protocolo `
            -CookieBasedAffinity Disabled `
            -RequestTimeout 20 `
            -HostName $hostNameCompleto `
            -Probe $probe
    } else {
        Write-Host "3. La configuración de back-end '$settingsName' ya existe. Omitiendo." -ForegroundColor Gray
    }
    
    # --- 4. CREAR AGENTES DE ESCUCHA (LISTENERS) ---
    # Usamos tablas dinámicas (Splatting) para manejar de forma limpia si lleva SSL o Política WAF
    if ($waf.HttpListeners.Name -notcontains $listenerName443) {
        Write-Host "4a. Creando Listener IPv4: $listenerName443"
        
        $listenerParams = @{
            ApplicationGateway      = $waf
            Name                    = $listenerName443
            Protocol                = $protocolo
            FrontendIPConfiguration = $frontendIPv4
            FrontendPort            = $frontendPortObj
            HostName                = $hostNameCompleto
        }

        if ($protocolo -eq "Https") {
            $listenerParams.Add("SslCertificate", $sslCert)
            $listenerParams.Add("RequireServerNameIndication", $true)
        }
        if ($app.AsociarPoliticaWaf -and $null -ne $wafPolicy) {
            $listenerParams.Add("FirewallPolicyId", $wafPolicy.Id)
        }

        $waf = Add-AzApplicationGatewayHttpListener @listenerParams
    } else {
        Write-Host "4a. El listener '$listenerName443' ya existe. Omitiendo." -ForegroundColor Gray
    }

    # Listener IPv6 (Opcional)
    if ($app.NecesitaIPv6 -and $frontendIPv6) {
        if ($waf.HttpListeners.Name -notcontains $listenerNameIPv6) {
            Write-Host "4b. Creando Listener IPv6: $listenerNameIPv6"
            
            $listenerIPv6Params = @{
                ApplicationGateway      = $waf
                Name                    = $listenerNameIPv6
                Protocol                = $protocolo
                FrontendIPConfiguration = $frontendIPv6
                FrontendPort            = $frontendPortObj
                HostName                = $hostNameCompleto
            }

            if ($protocolo -eq "Https") {
                $listenerIPv6Params.Add("SslCertificate", $sslCert)
                $listenerIPv6Params.Add("RequireServerNameIndication", $true)
            }
            if ($app.AsociarPoliticaWaf -and $null -ne $wafPolicy) {
                $listenerIPv6Params.Add("FirewallPolicyId", $wafPolicy.Id)
            }

            $waf = Add-AzApplicationGatewayHttpListener @listenerIPv6Params
        } else {
            Write-Host "4b. El listener '$listenerNameIPv6' ya existe. Omitiendo." -ForegroundColor Gray
        }
    }

    # Guardar cambios de componentes base antes de crear las reglas
    Write-Host "Guardando componentes base en Azure..." -ForegroundColor Cyan
    $waf = Set-AzApplicationGateway -ApplicationGateway $waf
    
    # --- 5. CREAR REGLAS (RULES) ---
    # Recargar el WAF para asegurar la consistencia de IDs internos de Azure
    $waf = Get-AzApplicationGateway -Name $appGatewayName -ResourceGroupName $resourceGroupName
    
    $listener443 = $waf.HttpListeners | Where-Object { $_.Name -eq $listenerName443 }
    $backendPool = $waf.BackendAddressPools | Where-Object { $_.Name -eq $poolName }
    $backendSettings = $waf.BackendHttpSettingsCollection | Where-Object { $_.Name -eq $settingsName }

    # Regla IPv4
    if ($waf.RequestRoutingRules.Name -notcontains $ruleName443) {
        Write-Host "5a. Creando Regla IPv4: $ruleName443"
        $waf = Add-AzApplicationGatewayRequestRoutingRule `
            -ApplicationGateway $waf `
            -Name $ruleName443 `
            -RuleType Basic `
            -Priority $app.PrioridadRegla `
            -HttpListener $listener443 `
            -BackendAddressPool $backendPool `
            -BackendHttpSettings $backendSettings
    } else {
        Write-Host "5a. La regla '$ruleName443' ya existe. Omitiendo." -ForegroundColor Gray
    }
    
    # Regla IPv6 (Opcional)
    if ($app.NecesitaIPv6 -and $frontendIPv6) {
        $listenerIPv6 = $waf.HttpListeners | Where-Object { $_.Name -eq $listenerNameIPv6 }
        if ($waf.RequestRoutingRules.Name -notcontains $ruleNameIPv6) {
            Write-Host "5b. Creando Regla IPv6: $ruleNameIPv6"
            $waf = Add-AzApplicationGatewayRequestRoutingRule `
                -ApplicationGateway $waf `
                -Name $ruleNameIPv6 `
                -RuleType Basic `
                -Priority ($app.PrioridadRegla + 2) `
                -HttpListener $listenerIPv6 `
                -BackendAddressPool $backendPool `
                -BackendHttpSettings $backendSettings
        } else {
            Write-Host "5b. La regla '$ruleNameIPv6' ya existe. Omitiendo." -ForegroundColor Gray
        }
    }

    # Guardar cambios finales de las reglas por cada sitio
    Write-Host "Guardando reglas y aplicando cambios finales..." -ForegroundColor Cyan
    $waf = Set-AzApplicationGateway -ApplicationGateway $waf
    Write-Host "¡Aplicación '$hostNameCompleto' configurada y protegida exitosamente!" -ForegroundColor Green
}

Write-Host "================================================================"
Write-Host "🎉 Proceso completado sin errores en las nomenclaturas." -ForegroundColor Magenta
Write-Host "================================================================"