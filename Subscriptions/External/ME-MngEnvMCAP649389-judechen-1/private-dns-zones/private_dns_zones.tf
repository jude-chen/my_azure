module "avm-ptn-network-private-link-private-dns-zones" {
  source  = "Azure/avm-ptn-network-private-link-private-dns-zones/azurerm"
  version = "0.4.0"
  # insert the 2 required variables here
  resource_group_name = "private-dns-rg"
  location            = local.primary_region
}
