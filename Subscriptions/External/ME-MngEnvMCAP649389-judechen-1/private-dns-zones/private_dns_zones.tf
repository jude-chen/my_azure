module "avm-ptn-network-private-link-private-dns-zones" {
  source  = "Azure/avm-ptn-network-private-link-private-dns-zones/azurerm"
  version = "0.4.0"
  # insert the 2 required variables here
  resource_group_name = azurerm_resource_group.private-dns-rg.name
  location            = local.primary_region
}
