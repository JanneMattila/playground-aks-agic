#!/bin/bash

# All the variables for the deployment
subscriptionName="AzureDev"
aadAdminGroupContains="janne''s"

aksName="myaksagic"
acrName="myacragic0000010"
workspaceName="myagicworkspace"
vnetName="myaksagic-vnet"
subnetAks="AksSubnet"
subnetAppGw="AppGwSubnet"
appGwName="myagic"
identityName="myaksagic"
resourceGroupName="rg-myaksagic"
location="northeurope"

# Login and set correct context
az login -o table
az account set --subscription $subscriptionName -o table

subscriptionID=$(az account show -o tsv --query id)
az group create -l $location -n $resourceGroupName -o table

# Enable feature
az feature register --name AKS-IngressApplicationGatewayAddon --namespace Microsoft.ContainerService
az provider register -n Microsoft.ContainerService
az feature list --namespace Microsoft.ContainerService -o table | grep Addon

# Prepare extensions and providers
az extension add --upgrade --yes --name aks-preview

# Remove extension in case conflicting previews
az extension remove --name aks-preview

acrid=$(az acr create -l $location -g $resourceGroupName -n $acrName --sku Basic --query id -o tsv)
echo $acrid

aadAdmingGroup=$(az ad group list --display-name $aadAdminGroupContains --query [].objectId -o tsv)
echo $aadAdmingGroup

workspaceid=$(az monitor log-analytics workspace create -g $resourceGroupName -n $workspaceName --query id -o tsv)
echo $workspaceid

vnetid=$(az network vnet create -g $resourceGroupName --name $vnetName \
  --address-prefix 10.0.0.0/8 \
  --query newVNet.id -o tsv)
echo $vnetid

subnetaksid=$(az network vnet subnet create -g $resourceGroupName --vnet-name $vnetName \
  --name $subnetAks --address-prefixes 10.2.0.0/24 \
  --query id -o tsv)
echo $subnetaksid

subnetappgwsid=$(az network vnet subnet create -g $resourceGroupName --vnet-name $vnetName \
  --name $subnetAppGw --address-prefixes 10.3.0.0/24 \
  --query id -o tsv)
echo $subnetappgwsid

identityid=$(az identity create --name $identityName --resource-group $resourceGroupName --query id -o tsv)
echo $identityid

az aks get-versions -l $location -o table

# Note about private clusters:
# https://docs.microsoft.com/en-us/azure/aks/private-clusters

# For private cluster add these:
#  --enable-private-cluster \ # aks-preview
#  --private-dns-zone None \ # aks-preview

az aks create -g $resourceGroupName -n $aksName \
 --zones "1" --max-pods 150 --network-plugin azure \
 --node-count 1 --enable-cluster-autoscaler --min-count 1 --max-count 3 \
 --node-osdisk-type Ephemeral \
 --node-vm-size Standard_D8ds_v4 \
 --kubernetes-version 1.21.2 \
 --enable-addons ingress-appgw,monitoring,azure-policy \
 --appgw-name $appGwName \
 --appgw-subnet-id $subnetappgwsid \
 --enable-aad \
 --enable-managed-identity \
 --aad-admin-group-object-ids $aadAdmingGroup \
 --workspace-resource-id $workspaceid \
 --attach-acr $acrid \
 --load-balancer-sku standard \
 --vnet-subnet-id $subnetaksid \
 --assign-identity $identityid \
 -o table 

###################################################################
# Note: for public cluster you need to authorize your ip to use api
myip=$(curl --no-progress-meter https://api.ipify.org)
echo $myip

# Enable current ip
az aks update -g $resourceGroupName -n $aksName \
  --api-server-authorized-ip-ranges $myip

# Disable all authorized ip ranges
az aks update -g $resourceGroupName -n $aksName \
  --api-server-authorized-ip-ranges ""
###################################################################

sudo az aks install-cli

az aks get-credentials -n $aksName -g $resourceGroupName

kubectl get nodes

kubectl apply -f namespace.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

kubectl get service -n demos

#------------------------------------------------------------------------------

ingressNamespace="ingress-demo"
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | sudo bash

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install nginx-ingress ingress-nginx/ingress-nginx \
    --create-namespace --namespace $ingressNamespace \
    --set controller.replicaCount=2 \
    --set controller.nodeSelector."kubernetes\.io/os"=linux \
    --set controller.admissionWebhooks.patch.nodeSelector."kubernetes\.io/os"=linux \
    --set controller.service.loadBalancerIP=10.2.0.123 \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"="true"

kubectl get services nginx-ingress-ingress-nginx-controller -o wide -n ingress-demo
kubectl describe services nginx-ingress-ingress-nginx-controller -n ingress-demo
# It should show -> External IP: 10.2.0.123
#
# IMPORTANT: If you provided IP address to "controller.service.loadBalancerIP",
# which is not inside allowed IP range (example IP that fails: 10.0.0.123) then you will get
# following error message from command:
kubectl describe services nginx-ingress-ingress-nginx-controller -n ingress-demo
# ->
 #"error": {
#    "code": "PrivateIPAddressNotInSubnet",
#    "message": "Private static IP address 10.0.0.123 does not belong to the range of subnet prefix 10.2.0.0/24.",
#    "details": []
#  }

# To remove installation:
# helm uninstall nginx-ingress --namespace $ingressNamespace

kubectl apply -f ingress.yaml

#------------------------------------------------------------------------------

kubectl get endpoints -n demos
kubectl get service -n demos
kubectl get ingress -n demos
kubectl describe ingress demos-ingress -n demos
# Default backend:  default-http-backend:80 (<error: endpoints "default-http-backend" not found>)

# kubectl get service -n demos
# NAME                         TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
# webapp-network-tester-demo   LoadBalancer   10.0.97.103   10.2.0.6      80:32288/TCP   19m
curl 10.2.0.6
# -> <html><body>Hello there!</body></html>

# kubectl get ingress -n demos
# NAME            CLASS    HOSTS        ADDRESS      PORTS   AGE
# demos-ingress   <none>   thingy.xyz   10.2.0.123   80      2m20s
curl 10.2.0.123
# -> 404 (Default backend:  default-http-backend:80 (<error: endpoints "default-http-backend" not found>))

# Setup DNS
curl thingy.xyz
# -> <html><body>Hello there!</body></html>

#------------------------------------------------------------------------------
# Wipe out the resources
az group delete --name $resourceGroupName -y
