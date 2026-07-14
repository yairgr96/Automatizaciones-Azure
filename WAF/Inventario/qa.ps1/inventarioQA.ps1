# =================================================================================
# --- CONFIGURACIÓN REQUERIDA ---
# =================================================================================
$AppGwName         = "waf-pub-qa-eastus-002"
$ResourceGroupName = "rg-waf-qa-eastus-001"
$SubscriptionId    = "QA"
# ----------------=================================================================
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "INICIANDO PROCESO DE AUTENTICACIÓN EN AZURE" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# 0. INICIO DE SESIÓN (Equivalente a az login en Azure CLI)
try {
    Write-Host "Abriendo ventana de inicio de sesión interactivo..." -ForegroundColor Yellow
    # Abre la ventana emergente del navegador para autenticarte
    $azContext = Connect-AzAccount -ErrorAction Stop
    Write-Host "¡Autenticación exitosa como: $($azContext.Context.Account.Id)!" -ForegroundColor Green
}
catch {
    Write-Error "No se pudo iniciar sesión en Azure. Valida tus credenciales."
    exit
}

# 0.1. CAMBIO DE CONTEXTO A LA SUSCRIPCIÓN CORRECTA
Write-Host "`nCambiando contexto a la suscripción '$SubscriptionId'..." -ForegroundColor Cyan
try {
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Host "Contexto asignado correctamente a la suscripción de destino." -ForegroundColor Green
}
catch {
    Write-Error "No se encontró la suscripción '$SubscriptionId' o no tienes permisos sobre ella."
    exit
}

Write-Host "Cambiando contexto a la suscripción '$SubscriptionId'..." -ForegroundColor Cyan
Set-AzContext -SubscriptionId $subscriptionId | Out-Null

# 1. Obtenemos la configuración completa del Application Gateway
Write-Host "Obteniendo la configuración viva de '$AppGwName'..." -ForegroundColor Cyan
$appgw = Get-AzApplicationGateway -Name $AppGwName -ResourceGroupName $ResourceGroupName

# 2. Lista para almacenar los resultados
$results = @()

# 3. Recorremos cada regla de enrutamiento (el núcleo que conecta todo)
Write-Host "Procesando reglas y extrayendo topología detallada..." -ForegroundColor Yellow
foreach ($rule in $appgw.RequestRoutingRules) {
    
    # Resolver componentes amarrados a la regla por su ID interno de Azure
    $listener        = $appgw.HttpListeners | Where-Object { $_.Id -eq $rule.HttpListener.Id }
    $backendPool     = $appgw.BackendAddressPools | Where-Object { $_.Id -eq $rule.BackendAddressPool.Id }
    $backendSettings = $appgw.BackendHttpSettingsCollection | Where-Object { $_.Id -eq $rule.BackendHttpSettings.Id }

    # --- RESOLVER DETALLES DEL FRONTEND ---
    # Extraer el puerto real (el listener guarda una referencia, buscamos el número real)
    $frontendPortObj = $appgw.FrontendPorts | Where-Object { $_.Id -eq $listener.FrontendPort.Id }
    $puertoFrontend  = $frontendPortObj ? $frontendPortObj.Port : "N/A"

    # Identificar qué Frontend IP está usando (Pública, Privada o IPv6) extrayendo el nombre final del ID
    $frontendIpName = "N/A"
    if ($listener.FrontendIPConfiguration -and $listener.FrontendIPConfiguration.Id) {
        $frontendIpName = $listener.FrontendIPConfiguration.Id.Split('/')[-1]
    }

    # Extraer el nombre del Certificado SSL si aplica
    $sslCertName = "Ninguno (HTTP)"
    if ($listener.SslCertificate -and $listener.SslCertificate.Id) {
        $sslCertName = $listener.SslCertificate.Id.Split('/')[-1]
    }

    # --- RESOLVER POLÍTICA WAF ASOCIADA AL SITIO (Listener) ---
    $politicaWafAsociada = "N/A (Usa la Global del WAF)"
    if ($listener.FirewallPolicy -and $listener.FirewallPolicy.Id) {
        $politicaWafAsociada = $listener.FirewallPolicy.Id.Split('/')[-1]
    }

    # --- RESOLVER DETALLES DEL BACKEND ---
    # Unificar las IPs del pool
    $backendTargets = ($backendPool.BackendAddresses.IpAddress) -join ", "
    if ([string]::IsNullOrEmpty($backendTargets)) { $backendTargets = "Sin IPs asignadas" }

    # Extraer el Health Probe asociado a la configuración HTTP
    $probeName = "Ninguno (Por defecto)"
    if ($backendSettings.Probe -and $backendSettings.Probe.Id) {
        $probeName = $backendSettings.Probe.Id.Split('/')[-1]
    }

    # 4. Construcción del objeto consolidado con todos los datos requeridos
    $siteInfo = [PSCustomObject]@{
        "Sitio (Hostname)"       = $listener.HostName
        "Nombre Frontend IP"     = $frontendIpName
        "Puerto Frontend"        = $puertoFrontend
        "Protocolo Frontend"     = $listener.Protocol
        "Certificado SSL"        = $sslCertName
        "Requiere SNI"           = $listener.RequireServerNameIndication
        "Politica WAF del Sitio" = $politicaWafAsociada
        "Nombre de la Regla"     = $rule.Name
        "Prioridad de la Regla"  = $rule.Priority   # <-- NUEVO: Columna de prioridad agregada
        "Tipo de Regla"          = $rule.RuleType
        "Grupo de Backend"       = $backendPool.Name
        "Destinos (IPs Backend)" = $backendTargets
        "Configuracion Backend"  = $backendSettings.Name
        "Protocolo Backend"      = $backendSettings.Protocol
        "Puerto Backend"         = $backendSettings.Port
        "Sondeo de Estado (HP)"  = $probeName       # <-- NUEVO: Nombre del Health Probe amarrado
    }

    $results += $siteInfo
}

# 5. Exportamos a CSV
$fileName = "inventario_detallado_$($AppGwName).csv" #inventario_detallado_waf-pub-qa-eastus-002.csv
$results | Export-Csv -Path $fileName -NoTypeInformation -Encoding UTF8

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host "¡Éxito! El inventario se generó correctamente." -ForegroundColor Green
Write-Host "Archivo guardado como: $fileName" -ForegroundColor Yellow
Write-Host "Campos críticos incluidos: Prioridades, Frontend IPs, Certificados y Políticas WAF por Sitio." -ForegroundColor White
Write-Host "=================================================================" -ForegroundColor Green