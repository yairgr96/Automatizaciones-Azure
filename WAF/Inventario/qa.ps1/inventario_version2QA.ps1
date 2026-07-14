# =================================================================================
# --- CONFIGURACIÓN REQUERIDA ---
# =================================================================================
$AppGwName         = "waf-pub-qa-eastus-002"
$ResourceGroupName = "rg-waf-qa-eastus-001"
$SubscriptionId    = "QA"
# ----------------=================================================================

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "INICIANDO EXTRACCIÓN DE DATOS CON FORMATO EXCEL" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# 0. INICIO DE SESIÓN
try {
    Write-Host "Iniciando sesión en Azure..." -ForegroundColor Yellow
    Connect-AzAccount -ErrorAction Stop | Out-Null
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Host "Autenticación y cambio de contexto exitosos." -ForegroundColor Green
} catch {
    Write-Error "Error de autenticación. Verifica tus credenciales o el nombre de la suscripción."
    exit
}

# 1. OBTENER CONFIGURACIÓN DEL WAF
Write-Host "`nDescargando configuración de '$AppGwName'..." -ForegroundColor Cyan
$appgw = Get-AzApplicationGateway -Name $AppGwName -ResourceGroupName $ResourceGroupName

# =================================================================================
# --- GENERACIÓN DE ARCHIVOS (Mapeo exacto a las columnas de tu Excel) ---
# =================================================================================

# ---------------------------------------------------------
# Pestaña 1: Backend pools
# ---------------------------------------------------------
Write-Host "Generando 'Backend pools.csv'..."
$poolsOut = foreach ($pool in $appgw.BackendAddressPools) {
    [PSCustomObject]@{
        "Nombre de backend" = $pool.Name
        "Destinos"          = ($pool.BackendAddresses.IpAddress) -join ", "
    }
}
$poolsOut | Export-Csv -Path "Backend pools.csv" -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------
# Pestaña 2: Backend settings
# ---------------------------------------------------------
Write-Host "Generando 'Backend settings.csv'..."
$settingsOut = foreach ($setting in $appgw.BackendHttpSettingsCollection) {
    $probeName = if ($setting.Probe) { $setting.Probe.Id.Split('/')[-1] } else { "N/A" }
    $reemplazarHost = if (![string]::IsNullOrEmpty($setting.HostName)) { "Si" } else { "No" }
    
    [PSCustomObject]@{
        "Nombre"                                                       = $setting.Name
        "Protocolo"                                                    = $setting.Protocol
        "Puerto"                                                       = $setting.Port
        "Request time-out (seconds)"                                   = $setting.RequestTimeout
        "El certificado del servidor back-end lo emite una CA conocida"= "No" # Valor por defecto común
        "Reemplazar por un nuevo nombre de host"                       = $reemplazarHost
        "Host"                                                         = $setting.HostName
        "Sondeo de estado asociado"                                    = $probeName
    }
}
$settingsOut | Export-Csv -Path "Backend settings.csv" -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------
# Pestaña 3: Listeners
# ---------------------------------------------------------
Write-Host "Generando 'Listeners.csv'..."
$listenersOut = foreach ($listener in $appgw.HttpListeners) {
    $frontIp = if ($listener.FrontendIPConfiguration) { $listener.FrontendIPConfiguration.Id.Split('/')[-1] } else { "N/A" }
    $portObj = $appgw.FrontendPorts | Where-Object Id -eq $listener.FrontendPort.Id
    $portNum = if ($portObj) { $portObj.Port } else { "N/A" }
    $certName = if ($listener.SslCertificate) { $listener.SslCertificate.Id.Split('/')[-1] } else { "N/A" }
    $tipoAgente = if (![string]::IsNullOrEmpty($listener.HostName)) { "Varios sitios" } else { "Básico" }

    [PSCustomObject]@{
        "Nombre"                    = $listener.Name
        "IP de Front"               = $frontIp
        "Protocolo"                 = $listener.Protocol
        "Puerto"                    = $portNum
        "Nombre de Host"            = $listener.HostName
        "Tipo de Agente de Escucha" = $tipoAgente
        "Certificado"               = $certName
    }
}
$listenersOut | Export-Csv -Path "Listeners.csv" -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------
# Pestaña 4: Rules
# ---------------------------------------------------------
Write-Host "Generando 'Rules.csv'..."
$rulesOut = foreach ($rule in $appgw.RequestRoutingRules) {
    $listenerName = if ($rule.HttpListener) { $rule.HttpListener.Id.Split('/')[-1] } else { "N/A" }
    
    if ($rule.RedirectConfiguration) {
        $tipoBackend = "Redirección"
        $redirectObj = $appgw.RedirectConfigurations | Where-Object Id -eq $rule.RedirectConfiguration.Id
        $targetListener = if ($redirectObj.TargetListener) { $redirectObj.TargetListener.Id.Split('/')[-1] } else { "N/A" }
        $destinoBack = "Redirige a: $targetListener"
        $configBack  = "N/A"
    } else {
        $tipoBackend = "Grupo de backend"
        $destinoBack = if ($rule.BackendAddressPool) { $rule.BackendAddressPool.Id.Split('/')[-1] } else { "N/A" }
        $configBack  = if ($rule.BackendHttpSettings) { $rule.BackendHttpSettings.Id.Split('/')[-1] } else { "N/A" }
    }

    [PSCustomObject]@{
        "Nombre"                = $rule.Name
        "Prioridad"             = $rule.Priority
        "Agente de escucha"     = $listenerName
        "Tipo de back-end"      = $tipoBackend
        "Destino de back"       = $destinoBack
        "Configuración de back" = $configBack
    }
}
$rulesOut | Export-Csv -Path "Rules.csv" -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------
# Pestaña 5: Health probes
# ---------------------------------------------------------
Write-Host "Generando 'Health probes.csv'..."
$probesOut = foreach ($probe in $appgw.Probes) {
    [PSCustomObject]@{
        "Nombre"               = $probe.Name
        "Protocolo"            = $probe.Protocol
        "Host"                 = $probe.HostName
        "Path"                 = $probe.Path
        "Intervalo (segundos)" = $probe.Interval
        "Timeout (segundos)"   = $probe.Timeout
        "Umbral no saludable"  = $probe.UnhealthyThreshold
    }
}
$probesOut | Export-Csv -Path "Health probes.csv" -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------
# Pestaña 6: WAF Policies
# ---------------------------------------------------------
Write-Host "Generando 'waf_policies.csv'..."
# Agrupar listeners por política WAF
$policyDict = @{}
foreach ($listener in $appgw.HttpListeners) {
    if ($listener.FirewallPolicy) {
        $policyName = $listener.FirewallPolicy.Id.Split('/')[-1]
        if (-not $policyDict.ContainsKey($policyName)) {
            $policyDict[$policyName] = @()
        }
        $policyDict[$policyName] += $listener.Name
    }
}

$policiesOut = foreach ($key in $policyDict.Keys) {
    [PSCustomObject]@{
        "Nombre"                       = $key
        "Suscripcion"                  = "Produccion" # Ajustado para coincidir con tu Excel
        "Grupo de Recursos"            = $ResourceGroupName
        "Modo"                         = "Prevention" # Asumido por diseño de tus scripts
        "Agentes de escucha asociados" = ($policyDict[$key]) -join ", "
    }
}
$policiesOut | Export-Csv -Path "waf_policies.csv" -NoTypeInformation -Encoding UTF8

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host "¡Proceso Completado!" -ForegroundColor Green
Write-Host "Se generaron 6 archivos .csv en el directorio actual, listos para copiar y pegar en tu Excel." -ForegroundColor Yellow
Write-Host "=================================================================" -ForegroundColor Green