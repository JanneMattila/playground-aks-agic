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

subnetappgwid=$(az network vnet subnet create -g $resourceGroupName --vnet-name $vnetName \
  --name $subnetAppGw --address-prefixes 10.3.0.0/24 \
  --query id -o tsv)
echo $subnetappgwid

identityid=$(az identity create --name $identityName --resource-group $resourceGroupName --query id -o tsv)
echo $identityid

az aks get-versions -l $location -o table

# Note about private clusters:
# https://docs.microsoft.com/en-us/azure/aks/private-clusters

# For private cluster add these:
#  --enable-private-cluster
#  --private-dns-zone None

az aks create -g $resourceGroupName -n $aksName \
 --zones "1" --max-pods 150 --network-plugin azure \
 --node-count 1 --enable-cluster-autoscaler --min-count 1 --max-count 3 \
 --node-osdisk-type Ephemeral \
 --node-vm-size Standard_D8ds_v4 \
 --kubernetes-version 1.21.2 \
 --enable-addons ingress-appgw,monitoring,azure-policy \
 --appgw-name $appGwName \
 --appgw-subnet-id $subnetappgwid \
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

# Clear all authorized ip ranges
az aks update -g $resourceGroupName -n $aksName \
  --api-server-authorized-ip-ranges ""
###################################################################

sudo az aks install-cli

az aks get-credentials -n $aksName -g $resourceGroupName --overwrite-existing

kubectl get nodes

kubectl apply -f namespace.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f ingress.yaml

kubectl get service -n demos
kubectl get ingress -n demos

kubectl get ingress -n demos -o json
ingressip=$(kubectl get ingress -n demos -o jsonpath="{.items[0].status.loadBalancer.ingress[0].ip}")
echo $ingressip

curl $ingressip
# -> <html><body>Hello there!</body></html>

BODY='IPLOOKUP bing.com'
curl -X POST --data "$BODY" -H "Content-Type: text/plain" "http://$ingressip/api/commands"
# IP: 13.107.21.200
# IP: 204.79.197.200
# IP: 2620:1ec:c11::200

BODY='INFO ENV'
curl -X POST --data "$BODY" -H "Content-Type: text/plain" "http://$ingressip/api/commands"
# ...
# ENV: WEBAPP_NETWORK_TESTER_DEMO_SERVICE_HOST: 10.0.221.201
# ENV: WEBAPP_NETWORK_TESTER_DEMO_PORT: tcp://10.0.221.201:80
# ENV: DOTNET_VERSION: 6.0.0

##############
# TLS examples
##############
# Create/get yourself a certificate
# - You can use Let's Encrypt with instructions from here:
#   https://github.com/JanneMattila/some-questions-and-some-answers/blob/master/q%26a/use_ssl_certificates.md
#   ->
domainName="jannemattila.com"
sudo cp "/etc/letsencrypt/live/$domainName/privkey.pem" .
sudo cp "/etc/letsencrypt/live/$domainName/fullchain.pem" .

kubectl create secret tls tls-secret --key privkey.pem --cert fullchain.pem -n demos --dry-run=client -o yaml > tls-secret.yaml

kubectl apply -f tls-secret.yaml

kubectl apply -f ingress-tls.yaml
kubectl get ingress -n demos
kubectl describe ingress demos-ingress -n demos

# Deploy DNS e.g., "agic.jannemattila.com" -> $ingressip
address="agic.$domainName"
echo $address

# Try with HTTPS
BODY='IPLOOKUP bing.com'
curl -X POST --data "$BODY" -H "Content-Type: text/plain" "https://$address/api/commands"

# Wipe out the resources
az group delete --name $resourceGroupName -y
