# 1. Definir variables para evitar errores
RG="TuResourceGroup"
WAF_POLICY="WAF-PVT-PROD-EASTUS-002" # Reemplaza por el nombre real de la política WAF

# 2. Agregar exclusión para 'storagePath' a nivel global
az network waf-policy managed-rule exclusion add \
  --resource-group $RG \
  --policy-name $WAF_POLICY \
  --match-variable RequestArgNames \
  --operator Equals \
  --values "storagePath"

# 3. Agregar exclusión para 'name' a nivel global
az network waf-policy managed-rule exclusion add \
  --resource-group $RG \
  --policy-name $WAF_POLICY \
  --match-variable RequestArgNames \
  --operator Equals \
  --values "name"