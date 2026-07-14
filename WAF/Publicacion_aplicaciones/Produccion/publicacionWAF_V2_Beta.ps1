<#
.SYNOPSIS
    Automatiza el alta completa de aplicaciones en un Azure Application Gateway (WAF) V2,
    permitiendo la asignación flexible en frontends Públicos, Privados e IPv6 de forma simultánea,
    así como la creación y asignación de políticas WAF dedicadas por sitio.
#>

# =================================================================================
# --- PARÁMETROS PRINCIPALES (Ajusta estos valores para tu entorno) ---
# =================================================================================
$resourceGroupName = "rg-waf-prod-eastus-001"
$appGatewayName    = "waf-pvt-prod-eastus-001"
$subscriptionId    = "Produccion"

# Nombres de recursos existentes en tu WAF que se usarán como base
$puertoFrontEnd443 = "port_443"          # Nombre del puerto de front-end para 443
$puertoFrontEnd80  = "port_80"           # Nombre del puerto de front-end para 80
$certificadoSsl    = "cnbv-wildcard"       # Nombre de tu certificado SSL Wildcard

# Nombres exactos de tus configuraciones de Frontend IP en el WAF
$nombreIPPublicaIPv4  = "appGatewayFrontendIP"        
$nombreIPPrivadaIPv4 = "appGatewayPrivateFrontendIP" 
$nombreIPIPv6        = "appGatewayFrontendIPv6"      

# =================================================================================
# --- CONFIGURACIÓN DE APLICACIONES (Aquí defines todo lo que quieres crear) ---
# =================================================================================
$ConfiguracionDeApps = @(
    @{
        Subdominio         = "balam-ha-qa"
        BackendIPs         = @("10.70.20.121")
        PrioridadRegla     = 550                # Prioridad base (las siguientes sumarán +1, +2 automáticamente)
        Puerto             = 443
        AsociarPoliticaWaf = $true
        
        # --- NUEVOS INTERRUPTORES DE FRONTEND SELECCIONABLES ---
        NecesitaPrivada    = $true   # $true para crear Listener/Regla en IP Privada
        NecesitaPublica    = $false  # $true para crear Listener/Regla en IP Pública
        NecesitaIPv6       = $false  # $true para crear Listener/Regla en IPv6
    }
)

# =================================================================================
# --- LÓGICA DE AUTOMATIZACIÓN (No necesitas modificar debajo de esta línea) ---
# =================================================================================

Write-Host "Iniciando la configuración masiva en el Application Gateway '$appGatewayName'..." -ForegroundColor Cyan
Set-AzContext -SubscriptionId $subscriptionId

# Obtener la versión más reciente del WAF una sola vez al inicio
$waf = Get-AzApplicationGateway -Name $appGatewayName -ResourceGroupName $resourceGroupName

# --- Componentes globales mapeados de forma segura por Nombre ---
$frontendPort443     = $waf.FrontendPorts | Where-Object { $_.Name -eq $puertoFrontEnd443 }
$frontendPort80      = $waf.FrontendPorts | Where-Object { $_.Name -eq $puertoFrontEnd80 }
$sslCert             = $waf.SslCertificates | Where-Object { $_.Name -eq $certificadoSsl }
$frontendPublicIPv4  = $waf.FrontendIPConfigurations | Where-Object { $_.Name -eq $nombreIPPublicaIPv4 }
$frontendPrivateIPv4 = $waf.FrontendIPConfigurations | Where-Object { $_.Name -eq $nombreIPPrivadaIPv4 }
$frontendIPv6        = $waf.FrontendIPConfigurations | Where-Object { $_.Name -eq $nombreIPIPv6 }

# --- Bucle principal para procesar cada aplicación ---
foreach ($app in $ConfiguracionDeApps) {
    
    $sub = $app.Subdominio
    $hostNameCompleto = "$sub.cnbv.gob.mx"
    $puertoApp = $app.Puerto

    Write-Host "----------------------------------------------------------------"
    Write-Host "Procesando aplicación: $hostNameCompleto" -ForegroundColor Yellow
    Write-Host "----------------------------------------------------------------"

    # --- Lógica de Nombres y Protocolos basada en el Puerto ---
    if ($puertoApp -eq 80) {
        $protocolo = "Http"
        $prefijo   = "80"
        $frontendPortObj = $frontendPort80
    } else {
        $puertoApp = 443 
        $protocolo = "Https"
        $prefijo   = "s443"
        $frontendPortObj = $frontendPort443
    }

    # Nombres de componentes base (Backend y Probes son compartidos por la App)
    $probeName    = "HP$($prefijo)-$sub"
    $poolName     = "BEP-$sub"
    $settingsName = "BES$($prefijo)-$sub"
    
    # Nomenclatura estricta WAF solicitada
    $wafPolicyName = "Pwaf-$sub-prod-eastus-001" 

    # --- 0. CREACIÓN DE LA POLÍTICA WAF POR SITIO ---
    $wafPolicy = $null
    if ($app.AsociarPoliticaWaf) {
        Write-Host "0. Validando Política WAF dedicada: $wafPolicyName..."
        $wafPolicy = Get-AzWebApplicationFirewallPolicy -Name $wafPolicyName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
        
        if ($null -eq $wafPolicy) {
            Write-Host "   -> Creando nueva política WAF en modo prevención (CRS 3.2)..." -ForegroundColor Generic
            $policySetting = New-AzWebApplicationFirewallPolicySetting -Mode Prevention -State Enabled
            $managedRules = New-AzWebApplicationFirewallPolicyManagedRule -ManagedRuleSet @(New-AzWebApplicationFirewallPolicyManagedRuleSet -RuleSetType "OWASP" -RuleSetVersion "3.2")
            $wafPolicy = New-AzWebApplicationFirewallPolicy -Name $wafPolicyName -ResourceGroupName $resourceGroupName -Location $waf.Location -PolicySetting $policySetting -ManagedRule $managedRules
            Write-Host "   -> Política WAF creada con éxito." -ForegroundColor Green
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
    }

    # --- 2. CREAR GRUPO DE BACK-END (BACKEND POOL) ---
    if ($waf.BackendAddressPools.Name -notcontains $poolName) {
        Write-Host "2. Creando Grupo de Back-end: $poolName"
        $waf = Add-AzApplicationGatewayBackendAddressPool `
            -ApplicationGateway $waf `
            -Name $poolName `
            -BackendIPAddresses $app.BackendIPs
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
    }
    
    # --- 4. CREAR AGENTES DE ESCUCHA (LISTENERS) CONDICIONALES ---
    
    # 4a. Listener Privado IPv4
    $listenerNamePriv = "Lpriv-$prefijo-$sub"
    if ($app.NecesitaPrivada -and $frontendPrivateIPv4 -and ($waf.HttpListeners.Name -notcontains $listenerNamePriv)) {
        Write-Host "4a. Creando Listener Privado IPv4: $listenerNamePriv"
        $params = @{ ApplicationGateway = $waf; Name = $listenerNamePriv; Protocol = $protocolo; FrontendIPConfiguration = $frontendPrivateIPv4; FrontendPort = $frontendPortObj; HostName = $hostNameCompleto }
        if ($protocolo -eq "Https") { $params.Add("SslCertificate", $sslCert); $params.Add("RequireServerNameIndication", $true) }
        if ($app.AsociarPoliticaWaf -and $wafPolicy) { $params.Add("FirewallPolicyId", $wafPolicy.Id) }
        $waf = Add-AzApplicationGatewayHttpListener @params
    }

    # 4b. Listener Público IPv4
    $listenerNamePub = "Lpub-$prefijo-$sub"
    if ($app.NecesitaPublica -and $frontendPublicIPv4 -and ($waf.HttpListeners.Name -notcontains $listenerNamePub)) {
        Write-Host "4b. Creando Listener Público IPv4: $listenerNamePub"
        $params = @{ ApplicationGateway = $waf; Name = $listenerNamePub; Protocol = $protocolo; FrontendIPConfiguration = $frontendPublicIPv4; FrontendPort = $frontendPortObj; HostName = $hostNameCompleto }
        if ($protocolo -eq "Https") { $params.Add("SslCertificate", $sslCert); $params.Add("RequireServerNameIndication", $true) }
        if ($app.AsociarPoliticaWaf -and $wafPolicy) { $params.Add("FirewallPolicyId", $wafPolicy.Id) }
        $waf = Add-AzApplicationGatewayHttpListener @params
    }

    # 4c. Listener IPv6
    $listenerNameIPv6 = "Lipv6-$prefijo-$sub"
    if ($app.NecesitaIPv6 -and $frontendIPv6 -and ($waf.HttpListeners.Name -notcontains $listenerNameIPv6)) {
        Write-Host "4c. Creando Listener IPv6: $listenerNameIPv6"
        $params = @{ ApplicationGateway = $waf; Name = $listenerNameIPv6; Protocol = $protocolo; FrontendIPConfiguration = $frontendIPv6; FrontendPort = $frontendPortObj; HostName = $hostNameCompleto }
        if ($protocolo -eq "Https") { $params.Add("SslCertificate", $sslCert); $params.Add("RequireServerNameIndication", $true) }
        if ($app.AsociarPoliticaWaf -and $wafPolicy) { $params.Add("FirewallPolicyId", $wafPolicy.Id) }
        $waf = Add-AzApplicationGatewayHttpListener @params
    }

    # Guardar componentes base en Azure para generar los IDs requeridos por las reglas
    Write-Host "Guardando componentes base en Azure..." -ForegroundColor Cyan
    $waf = Set-AzApplicationGateway -ApplicationGateway $waf
    
    # --- 5. CREAR REGLAS DE ENRUTAMIENTO (RULES) ---
    # Recargar WAF
    $waf = Get-AzApplicationGateway -Name $appGatewayName -ResourceGroupName $resourceGroupName
    
    $backendPool = $waf.BackendAddressPools | Where-Object { $_.Name -eq $poolName }
    $backendSettings = $waf.BackendHttpSettingsCollection | Where-Object { $_.Name -eq $settingsName }

    # 5a. Regla Privada IPv4
    $ruleNamePriv = "Rpriv-$prefijo-$sub"
    if ($app.NecesitaPrivada -and $frontendPrivateIPv4 -and ($waf.RequestRoutingRules.Name -notcontains $ruleNamePriv)) {
        Write-Host "5a. Creando Regla Privada: $ruleNamePriv (Prioridad: $($app.PrioridadRegla))"
        $listenerPriv = $waf.HttpListeners | Where-Object { $_.Name -eq $listenerNamePriv }
        $waf = Add-AzApplicationGatewayRequestRoutingRule -ApplicationGateway $waf -Name $ruleNamePriv -RuleType Basic -Priority $app.PrioridadRegla -HttpListener $listenerPriv -BackendAddressPool $backendPool -BackendHttpSettings $backendSettings
    }

    # 5b. Regla Pública IPv4
    $ruleNamePub = "Rpub-$prefijo-$sub"
    if ($app.NecesitaPublica -and $frontendPublicIPv4 -and ($waf.RequestRoutingRules.Name -notcontains $ruleNamePub)) {
        $prioridadPub = $app.PrioridadRegla + 1
        Write-Host "5b. Creando Regla Pública: $ruleNamePub (Prioridad: $prioridadPub)"
        $listenerPub = $waf.HttpListeners | Where-Object { $_.Name -eq $listenerNamePub }
        $waf = Add-AzApplicationGatewayRequestRoutingRule -ApplicationGateway $waf -Name $ruleNamePub -RuleType Basic -Priority $prioridadPub -HttpListener $listenerPub -BackendAddressPool $backendPool -BackendHttpSettings $backendSettings
    }
    
    # 5c. Regla IPv6
    $ruleNameIPv6 = "Ripv6-$prefijo-$sub"
    if ($app.NecesitaIPv6 -and $frontendIPv6 -and ($waf.RequestRoutingRules.Name -notcontains $ruleNameIPv6)) {
        $prioridadIPv6 = $app.PrioridadRegla + 2
        Write-Host "5c. Creando Regla IPv6: $ruleNameIPv6 (Prioridad: $prioridadIPv6)"
        $listenerIPv6 = $waf.HttpListeners | Where-Object { $_.Name -eq $listenerNameIPv6 }
        $waf = Add-AzApplicationGatewayRequestRoutingRule -ApplicationGateway $waf -Name $ruleNameIPv6 -RuleType Basic -Priority $prioridadIPv6 -HttpListener $listenerIPv6 -BackendAddressPool $backendPool -BackendHttpSettings $backendSettings
    }

    # Guardar cambios finales del aplicativo
    Write-Host "Guardando reglas y aplicando cambios finales..." -ForegroundColor Cyan
    $waf = Set-AzApplicationGateway -ApplicationGateway $waf
    Write-Host "¡Aplicación '$hostNameCompleto' configurada y protegida exitosamente!" -ForegroundColor Green
}

Write-Host "================================================================"
Write-Host "🎉 Proceso de aprovisionamiento por flags completado." -ForegroundColor Magenta
Write-Host "================================================================"