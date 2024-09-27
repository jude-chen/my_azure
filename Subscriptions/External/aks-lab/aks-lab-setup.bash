# Lab instructions: https://github.com/microsoft/RCG_AKS_Enablement/blob/main/AKS_Cluster_Creation_Lab.md

# Set up the environment
LOCATION="northeurope"
RG_NAME="rg-${LOCATION}-aksdemo"
RANDOM_SUFFIX="${RANDOM}"
ACR_NAME="acr${LOCATION}${RANDOM_SUFFIX}"
LOG_ANALYTICS_WORKSPACE_NAME="log-${LOCATION}-aksdemo"
AZURE_MONITOR_WORKSPACE_NAME="amw-${LOCATION}-aksdemo"
MANAGED_GRAFANA_NAME="amg-aksdemo-${RANDOM_SUFFIX}"
NSG_NAME="nsg-${LOCATION}-aksdemo"
VNET_NAME="vnet-${LOCATION}-aksdemo"
AKS_CONTROL_PLANE_MI_NAME="mi-${LOCATION}-aksdemo-controlplane"
AKS_NAME="aks-${LOCATION}-aksdemo"
AKS_VM_SIZE="Standard_D8ds_v5"

# Create the resource group
az group create --name $RG_NAME --location $LOCATION

# Create the ACR, Log Analytics workspace, Azure Monitor workspace, Managed Grafana, Managed Identity, NSG, VNET, and AKS
az acr create --resource-group $RG_NAME --name $ACR_NAME --sku Basic --location $LOCATION
az monitor log-analytics workspace create --workspace-name $LOG_ANALYTICS_WORKSPACE_NAME --resource-group $RG_NAME --sku PerGB2018
az monitor account create --name $AZURE_MONITOR_WORKSPACE_NAME --resource-group $RG_NAME --location $LOCATION
az grafana create --name $MANAGED_GRAFANA_NAME --resource-group $RG_NAME --location $LOCATION
az identity create --name $AKS_CONTROL_PLANE_MI_NAME --resource-group $RG_NAME --location $LOCATION
az network nsg create --name $NSG_NAME --resource-group $RG_NAME --location $LOCATION
az network vnet create --name $VNET_NAME --resource-group $RG_NAME  --location $LOCATION --address-prefixes 10.0.0.0/16
az network vnet subnet create --vnet-name $VNET_NAME --resource-group $RG_NAME --name "AKS-Subnet" --address-prefixes 10.0.0.0/24 --network-security-group $NSG_NAME

SUBNET_ID=$(az network vnet subnet show --vnet-name $VNET_NAME --resource-group $RG_NAME --name "AKS-Subnet" --query id --output tsv)
AKS_CONTROL_PLANE_MI_CLIENT_ID=$(az identity show --name $AKS_CONTROL_PLANE_MI_NAME --resource-group $RG_NAME --query principalId --output tsv)
az role assignment create --assignee $AKS_CONTROL_PLANE_MI_CLIENT_ID --scope $SUBNET_ID --role "Network Contributor"

ACR_ID=$(az acr show --resource-group $RG_NAME --name $ACR_NAME --query id --output tsv)
LOG_ANALYTICS_WORKSPACE_ID=$(az monitor log-analytics workspace show --workspace-name $LOG_ANALYTICS_WORKSPACE_NAME --resource-group $RG_NAME --query id --output tsv)
AZURE_MONITOR_WORKSPACE_ID=$(az monitor account show --name $AZURE_MONITOR_WORKSPACE_NAME --resource-group $RG_NAME --query id --output tsv)
MANAGED_GRAFANA_ID=$(az grafana show --name $MANAGED_GRAFANA_NAME --resource-group $RG_NAME --query id --output tsv)
AKS_CONTROL_PLANE_MI_RESOURCE_ID=$(az identity show --name $AKS_CONTROL_PLANE_MI_NAME --resource-group $RG_NAME --query id --output tsv)

az aks create --name $AKS_NAME \
    --resource-group $RG_NAME \
    --location $LOCATION \
    --assign-identity $AKS_CONTROL_PLANE_MI_RESOURCE_ID \
    --node-count 2 \
    --node-vm-size $AKS_VM_SIZE \
    --network-plugin azure \
    --network-plugin-mode overlay \
    --vnet-subnet-id $SUBNET_ID \
    --service-cidr 100.64.0.0/16 \
    --dns-service-ip 100.64.0.10 \
    --pod-cidr 100.65.0.0/16 \
    --enable-addons monitoring \
    --workspace-resource-id $LOG_ANALYTICS_WORKSPACE_ID \
    --enable-azure-monitor-metrics \
    --azure-monitor-workspace-resource-id $AZURE_MONITOR_WORKSPACE_ID \
    --grafana-resource-id $MANAGED_GRAFANA_ID \
    --attach-acr $ACR_ID \
    --no-ssh-key \
    --zones 3

az aks get-credentials --name $AKS_NAME --resource-group $RG_NAME --admin

kubectl get nodes
kubectl get pods --namespace kube-system

az aks stop --name $AKS_NAME --resource-group $RG_NAME

az aks start --name $AKS_NAME --resource-group $RG_NAME

# Environment variables needed for connecting to the AKS cluster
LOCATION="eastus2"
RG_NAME="rg-${LOCATION}-aksdemo"
AKS_NAME="aks-${LOCATION}-aksdemo"