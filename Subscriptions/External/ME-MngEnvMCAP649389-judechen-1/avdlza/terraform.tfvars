##############  Modify the following variables to match your environment by replacing the values in quotes #####################
avdLocation               = "northeurope"                              # change to your Azure region
avdLocationShort          = "neu"                                      # change to your Azure region short name
prefix                    = "cb01"                                     # change to your prefix 4 characters (letters and numbers only)
environment               = "prod"                                     # change to your environment (development, test, production)
local_admin_username      = "azureadmin"                               # Your AVD VM local Windows administrator login username (administrator is not allowed)
ou_path                   = "OU=AVD,DC=contosobeach,DC=com"            # optional 
vm_size                   = "Standard_D2s_v4"                          # Session host compute 
vnet_range                = ["10.100.0.0/20"]                          # change to your cidr for the avd spoke vnet to be created
subnet_range              = ["10.100.0.0/24"]                          # change to your cidr for the avd spoke subnet to be created
pesubnet_range            = ["10.100.1.0/27"]                          # change to your cider for avd spoke private endpoint subnet to be created
allow_list_ip             = ["24.55.25.14"]                            # optional for access to browswer resources with private endpoint you can add your IP address to allowlist
dns_servers               = ["192.168.1.4", "168.63.129.16"]           # optional if you want to use your own DNS servers
next_hop_ip               = "10.100.0.4"                               # next hop ip address for route table
netbios_domain_name       = "contosobeach"                             # netbios domain name
domain_guid               = "09590c0c-ba5a-4a16-92a3-bdfc0f688e6a"     # domain guid
domain_sid                = "S-1-5-21-377382073-3809256461-2890635483" # domain sid
user_group_name           = "avdusersgrp"                              # user group must pre-created on your AD server and sync to Azure AD
domain_name               = "contosobeach.com"                         # your on-perm AD server domain name 
domain_user               = "adjoin"                                   # do not include domain name as this is appended
rdsh_count                = 2                                          # Number of session host vm to deploy
hub_vnet                  = "contosobeach1-vnet"                       # hub connectivity vnet name 
hub_connectivity_rg       = "onprem-ad-rg"                             # hub connectivity subscription network resource group
hub_dns_zone_rg           = "private-dns-zones-rg"                     # private DNS zones resource group name
identity_rg               = "onprem-ad-rg"                             # identity subscription resource group
identity_vnet             = "contosobeach1-vnet"                       # identity subscription vnet name
fw_policy                 = "fwpol-hub"                                # firewall policy for AVD assumes that firewall is already deployed in hub subscription
spoke_subscription_id     = "3c37c1b6-f951-43bd-ad04-721b79a104a8"     # subscription where AVD resources will be deployed
hub_subscription_id       = "3c37c1b6-f951-43bd-ad04-721b79a104a8"     # subscription where hub resources are deployed (If you are using a single subscription for hub and spoke, use the same subscription id as spoke_subscription_id)
identity_subscription_id  = "3c37c1b6-f951-43bd-ad04-721b79a104a8"     # subscription where identity resources are deployed (If you are using a single subscription for hub and spoke, use the same subscription id as spoke_subscription_id)
avdshared_subscription_id = "3c37c1b6-f951-43bd-ad04-721b79a104a8"     # optional subscription where shared resources are deployed (If you are using a single subscription for hub and spoke, use the same subscription id as spoke_subscription_id)

## Session host Image options
# Marketplace Image
publisher = "MicrosoftWindowsDesktop"
offer     = "Windows-11"
sku       = "win11-24h2-avd"
# Custom Image uncomment the following lines and comment the above lines to use custom image
# image_rg                  = "rg-image-resources"                   # resource group for custom image and image gallery
# gallery_name              = "avdgallery"                           # azure compute gallery name for custom image
# image_name                = "avdImage-win11-23h2-avd-m365"         # custom image name

############## Do not modify below this line unless you want to change naming convention#####################
# Resource Groups
rg_shared_name = "shared-resources" #output rg-avd-<Azure Region>-<prefix>-shared-resources
rg_network     = "network"          #rg-avd-<Azure Region>-<prefix>-network
rg_stor        = "storage"          #rg-avd-<Aazure Region>-<prefix>-storage
rg_pool        = "pool-compute"     #rg-avd-<Azure Region>-<prefix>-pool-compute
rg_so          = "service-objects"  #rg-avd-<Azure Region>-<prefix>-service-objects
rg_avdi        = "monitoring"       #rg-avd-<Azure Region>-<prefix>-avdi

# Azure Virtual Desktop Objects
## Host Pool Objects
hostpool     = "vdpool"  #vdpool-<azure region>-<prefix> multi-session host pool
personalpool = "vdppool" #vdpool-<azure region>-<prefix> personal host pool
raghostpool  = "vdrpool" #vdpool-<azure region>-<prefix> remote app group host pool

## Workspace Objects
workspace    = "vdws"  #vdmws-<azure region>-<prefix>-<nnn> AVD workspace for multi-session host pool
pworkspace   = "vdpws" #vdpws-<azure region>-<prefix>-<nnn> AVD workspace for personal host pool
ragworkspace = "vdrws" #vdrws-<azure region>-<prefix>-<nnn> AVD workspace for remote app group host pool

## Application Group Objects
pag = "vpag" #AVD personal pool desktop application group
dag = "vdag" #vdag-desktop-<azure region>-<prefix>-<nnn> AVD mulit-session pool desktop application group 
rag = "vrag" #vdag-rapp-<azure region>-<prefix>-<nnn> AVD remote application pool desktop application group

## Scaling Plan Objects
scplan = "vdscaling" #avd-<location>-<prefix>-scaling-plan

# Network Objects
rt     = "route-avd"  #route-avd-<azure region>-<prefix>-<nnn> Route Table
nsg    = "nsg-avd"    #nsg-avd-<azure region>-<prefix>-<nnn> Network Security Group
vnet   = "vnet-avd"   #vnet-avd-<azure region>-<prefix>-<nnn> Virtual Network
snet   = "snet-avd"   #snet-avd-<azure region>-<prefix>-<nnn> Subnet
pesnet = "pesnet-avd" #snet-avd-<azure region>-<prefix>-<nnn> Private Endpoint Subnet
