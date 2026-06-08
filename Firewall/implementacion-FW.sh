#!/bin/bash

# Evita que el script continúe si ocurre un error
set -e

# ==========================================
# 1. VARIABLES (Acompletadas y Ajustadas)
# ==========================================
RESOURCE_GROUP="rg-network-dev-eastus-001"
LOCATION="eastus"

# Redes y Subredes
VNET_NAME="vnet-fw-pdnsr-dev-001"
VNET_PREFIX="10.60.14.0/24"          # Espacio total para albergar ambas subredes

# Subred Requerida por Azure Firewall (Mínimo /26)
FW_SUBNET_NAME="AzureFirewallSubnet"
FW_SUBNET_PREFIX="10.60.14.0/26"

# Tu subred de carga de trabajo / servicios
SUBNET_NAME="sbnet-fw-pdnsr-dev-001"
SUBNET_PREFIX="10.60.14.64/26"       # Siguiente segmento disponible

# Componentes del Firewall
FW_NAME="fw-pdnsr-dev-001"
FW_POLICY_NAME="policy-fwp-pdnsr-dev-001"
FW_PIP_NAME="pip-fw-pdnsr-dev-001"

echo "=== Iniciando despliegue de infraestructura de red y seguridad ==="

# ==========================================
# 2. CREACIÓN DE GRUPO DE RECURSOS
# ==========================================
echo "Creando Grupo de Recursos..."
az group create --name $RESOURCE_GROUP --location $LOCATION

# ==========================================
# 3. CREACIÓN DE LA VNET Y SUBREDES
# ==========================================


echo "Creando la subred obligatoria para el Azure Firewall..."
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $FW_SUBNET_NAME \
  --address-prefixes $FW_SUBNET_PREFIX

echo "Creando tu subred de desarrollo de datos/servicios..."
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $SUBNET_NAME \
  --address-prefixes $SUBNET_PREFIX

# ==========================================
# 4. REQUISITOS DEL FIREWALL (IP Pública y Política)
# ==========================================
echo "Creando IP Pública para el Firewall (SKU Standard, Estática)..."
az network public-ip create \
  --resource-group $RESOURCE_GROUP \
  --name $FW_PIP_NAME \
  --location $LOCATION \
  --sku Standard \
  --allocation-method Static

echo "Creando la Política del Azure Firewall (Standard)..."
az network firewall policy create \
  --resource-group $RESOURCE_GROUP \
  --name $FW_POLICY_NAME \
  --location $LOCATION \
  --sku Standard

# ==========================================
# 5. CREACIÓN Y CONFIGURACIÓN DEL FIREWALL
# ==========================================
echo "Desplegando Azure Firewall (Esto puede tomar entre 5 y 10 minutos)..."
az network firewall create \
  --resource-group $RESOURCE_GROUP \
  --name $FW_NAME \
  --location $LOCATION \
  --sku Standard \
  --firewall-policy $FW_POLICY_NAME \
  --vnet-name $VNET_NAME \
  --public-ip $FW_PIP_NAME

echo "=== ¡Despliegue completado con éxito! ==="