data "azurerm_virtual_network" "onprem-ad" {
  name                = "contosobeach1-vnet"
  resource_group_name = "onprem-ad-rg"
}

module "avm-ptn-network-private-link-private-dns-zones" {
  source  = "Azure/avm-ptn-network-private-link-private-dns-zones/azurerm"
  version = "0.4.0"
  # insert the 2 required variables here
  resource_group_name = "private-dns-zones-rg"
  location            = local.primary_region
  private_link_private_dns_zones = {
    "azure_storage_file" = {
      zone_name = "privatelink.file.core.windows.net"
    }
    "azure_key_vault" = {
      zone_name = "privatelink.vaultcore.azure.net"
    }
  }
  virtual_network_resource_ids_to_link_to = {
    "onprem-ad" = {
      vnet_resource_id = data.azurerm_virtual_network.onprem-ad.id
    }
  }
}
