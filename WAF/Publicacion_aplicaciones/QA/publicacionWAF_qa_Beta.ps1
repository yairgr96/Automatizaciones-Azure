<#
.SYNOPSIS
    Automatiza el alta completa de aplicaciones en un Azure Application Gateway (WAF) con puertos dinámicos.
#>

# =================================================================================
# --- PARÁMETROS PRINCIPALES ---
# =================================================================================
$resourceGroupName = "rg-waf-qa-eastus-001"
$appGatewayName    = "waf-pvt-qa-eastus-001"
$subscriptionId    = "QA"

# Nombres de recursos existentes en tu WAF
$puertoFrontEnd443 = "port_443"         
$puertoFrontEnd80  = "port_80"          
$certificadoSsl    = "cnbv-wildcard"    

# Nombres exactos de tus configuraciones de IP en el WAF (Frontend IP Configurations)
$nombreIpPrivada   = "appGwPrivateFrontendIp" # Cambia esto por el nombre real en tu WAF
$nombreIpPublica   = "appGwPublicFrontendIp"  # Cambia esto por el nombre real en tu WAF

# =================================================================================
# --- CONFIGURACIÓN DE APLICACIONES ---
# =================================================================================
$ConfiguracionDeApps = @(
    @{
        Subdominio     = "fedata-portal-qa" 
        BackendIPs     = @("10.70.20.125") 
        PrioridadRegla = 555 
        NecesitaIPv6   = $false 
        PuertoListener = 443        # Opciones: 80 o 443
        PuertoBackend  = 443        # Opciones: 80 o 443
        TipoIpListener = "Privada"  # Opciones: "Privada" o "Publica"
    },
    @{
        Subdominio     = "fedata-validador-qa" 
        BackendIPs     = @("10.70.20.123") 
        PrioridadRegla = 560 
        NecesitaIPv6   = $false 
        PuertoListener = 80         # Ejemplo usando HTTP
        PuertoBackend  = 80         # Ejemplo usando HTTP
        TipoIpListener = "Publica"  # Ejemplo usando IP Pública
    }
)

# =================================================================================
# --- LÓGICA DE AUTOMATIZACIÓN ---
# =================================================================================

Write-Host "Iniciando la configuración masiva en el Application Gateway '$appGatewayName'..." -ForegroundColor Cyan
Set-AzContext -SubscriptionId $subscriptionId

$waf = Get-AzApplicationGateway -Name $appGatewayName -ResourceGroupName $resourceGroupName

# --- Obtener componentes base ---
$frontendPort443 = $waf.FrontendPorts | Where-Object { $_.Name -eq $puertoFrontEnd443 }
$frontendPort80  = $waf.FrontendPorts | Where-Object { $_.Name -eq $puertoFrontEnd80 }
$sslCert         = $waf.SslCertificates | Where-Object { $_.Name -eq $certificadoSsl }

$frontendIpPrivada = $waf.FrontendIPConfigurations | Where-Object { $_.Name -eq $nombreIpPrivada }
$frontendIpPublica = $waf.FrontendIPConfigurations | Where-Object { $_.Name -eq $nombreIpPublica }
$frontendIPv6      = $waf.FrontendIPConfigurations[2] # Ajusta el índice si tienes IPv6 configurado de otra forma

if (-not $sslCert -or -not $frontendPort443 -or -not $frontendPort80) {
    Write-Error "No se encontraron componentes de front-end esenciales (Certificado o Puertos). Abortando."
    return
}

foreach ($app in $ConfiguracionDeApps) {
    $sub = $app.Subdominio
    $hostNameCompleto = "$sub.cnbv.gob.mx"
    
    Write-Host "----------------------------------------------------------------"
    Write-Host "Procesando aplicación: $hostNameCompleto" -ForegroundColor Yellow
    Write-Host "----------------------------------------------------------------"

    # --- Lógica de Nomenclatura Dinámica ---
    $sufijoBackend  = if ($app.PuertoBackend -eq 443) { "s443" } else { "80" }
    $sufijoListener = if ($app.PuertoListener -eq 443) { "s443" } else { "80" }

    $protocoloBackend  = if ($app.PuertoBackend -eq 443) { "Https" } else { "Http" }
    $protocoloListener = if ($app.PuertoListener -eq 443) { "Https" } else { "Http" }

    $probeName    = "HP${sufijoBackend}-$sub"
    $poolName     = "BEP-$sub"
    $settingsName = "BES${sufijoBackend}-$sub"
    $listenerName = "L${sufijoListener}-$sub"
    $ruleName     = "R${sufijoListener}-$sub"
    
    $listenerNameIPv6 = "L${sufijoListener}IPv6-$sub"
    $ruleNameIPv6     = "R${sufijoListener}IPv6-$sub"

    # --- Selección de IP de Frontend ---
    $ipSeleccionada = if ($app.TipoIpListener -eq "Privada") { $frontendIpPrivada } else { $frontendIpPublica }

    if (-not $ipSeleccionada) {
        Write-Warning "No se encontró la IP $($app.TipoIpListener) para $sub. Verifica los nombres. Omitiendo app."
        continue
    }

    # --- 1. CREAR SONDEO DE ESTADO ---
    if ($waf.Probes.Name -notcontains $probeName) {
        Write-Host "1. Creando Sondeo de Estado: $probeName ($protocoloBackend)"
        $waf = Add-AzApplicationGatewayProbeConfig -ApplicationGateway $waf -Name $probeName -Protocol $protocoloBackend -HostName $hostNameCompleto -Path "/" -Interval 30 -Timeout 20 -UnhealthyThreshold 3
    } else {
        Write-Host "1. El sondeo '$probeName' ya existe." -ForegroundColor Gray
    }

    # --- 2. CREAR GRUPO DE BACK-END ---
    if ($waf.BackendAddressPools.Name -notcontains $poolName) {
        Write-Host "2. Creando Grupo de Back-end: $poolName"
        $waf = Add-AzApplicationGatewayBackendAddressPool -ApplicationGateway $waf -Name $poolName -BackendIPAddresses $app.BackendIPs
    } else {
        Write-Host "2. El grupo de back-end '$poolName' ya existe." -ForegroundColor Gray
    }
    
    # --- 3. CREAR CONFIGURACIÓN DE BACK-END ---
    $probe = $waf.Probes | Where-Object { $_.Name -eq $probeName }
    if ($waf.BackendHttpSettingsCollection.Name -notcontains $settingsName) {
        Write-Host "3. Creando Configuración de Back-end: $settingsName"
        $waf = Add-AzApplicationGatewayBackendHttpSettings -ApplicationGateway $waf -Name $settingsName -Port $app.PuertoBackend -Protocol $protocoloBackend -CookieBasedAffinity Disabled -RequestTimeout 20 -HostName $hostNameCompleto -Probe $probe
    } else {
        Write-Host "3. La configuración '$settingsName' ya existe." -ForegroundColor Gray
    }
    
    # --- 4. CREAR AGENTES DE ESCUCHA ---
    $puertoEscucha = if ($app.PuertoListener -eq 443) { $frontendPort443 } else { $frontendPort80 }

    if ($waf.HttpListeners.Name -notcontains $listenerName) {
        Write-Host "4a. Creando Listener IPv4: $listenerName"
        if ($protocoloListener -eq "Https") {
            $waf = Add-AzApplicationGatewayHttpListener -ApplicationGateway $waf -Name $listenerName -Protocol $protocoloListener -FrontendIPConfiguration $ipSeleccionada -FrontendPort $puertoEscucha -HostName $hostNameCompleto -SslCertificate $sslCert -RequireServerNameIndication $true
        } else {
            $waf = Add-AzApplicationGatewayHttpListener -ApplicationGateway $waf -Name $listenerName -Protocol $protocoloListener -FrontendIPConfiguration $ipSeleccionada -FrontendPort $puertoEscucha -HostName $hostNameCompleto
        }
    } else {
        Write-Host "4a. El listener '$listenerName' ya existe." -ForegroundColor Gray
    }

    Write-Host "Guardando componentes base..." -ForegroundColor Cyan
    $waf = Set-AzApplicationGateway -ApplicationGateway $waf
    
    # --- 5. CREAR REGLAS ---
    $waf = Get-AzApplicationGateway -Name $appGatewayName -ResourceGroupName $resourceGroupName
    
    $listenerBase = $waf.HttpListeners | Where-Object { $_.Name -eq $listenerName }
    $backendPool  = $waf.BackendAddressPools | Where-Object { $_.Name -eq $poolName }
    $backendSet   = $waf.BackendHttpSettingsCollection | Where-Object { $_.Name -eq $settingsName }

    if ($waf.RequestRoutingRules.Name -notcontains $ruleName) {
        Write-Host "5a. Creando Regla: $ruleName"
        $waf = Add-AzApplicationGatewayRequestRoutingRule -ApplicationGateway $waf -Name $ruleName -RuleType Basic -Priority $app.PrioridadRegla -HttpListener $listenerBase -BackendAddressPool $backendPool -BackendHttpSettings $backendSet
    } else {
        Write-Host "5a. La regla '$ruleName' ya existe." -ForegroundColor Gray
    }
    
    Write-Host "Guardando reglas..." -ForegroundColor Cyan
    $waf = Set-AzApplicationGateway -ApplicationGateway $waf
    Write-Host "Aplicación '$hostNameCompleto' configurada exitosamente." -ForegroundColor Green
}

Write-Host "🎉 Proceso completado." -ForegroundColor Magenta