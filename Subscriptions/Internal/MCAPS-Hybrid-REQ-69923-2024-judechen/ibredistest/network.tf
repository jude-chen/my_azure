module "ibredistest-vnet-primary" {
  source              = "Azure/avm-res-network-virtualnetwork/azurerm"
  version             = "0.4.0"
  address_space       = ["10.0.0.0/16"]
  location            = local.primary_region
  name                = "ibredistest-vnet-primary"
  resource_group_name = azurerm_resource_group.ibredistest-rg.name
  subnets = {
    "subnet1" = {
      name             = "default"
      address_prefixes = ["10.0.0.0/24"]
    }
    "subnet2" = {
      name             = "redis-subnet"
      address_prefixes = ["10.0.1.0/24"]
    }
  }
}

module "ibredistest-vnet-secondary" {
  source              = "Azure/avm-res-network-virtualnetwork/azurerm"
  version             = "0.4.0"
  address_space       = ["10.1.0.0/16"]
  location            = local.secondary_region
  name                = "ibredistest-vnet-secondary"
  resource_group_name = azurerm_resource_group.ibredistest-rg.name
  subnets = {
    "subnet1" = {
      name             = "default"
      address_prefixes = ["10.1.0.0/24"]
    }
    "subnet2" = {
      name             = "redis-subnet"
      address_prefixes = ["10.1.1.0/24"]
    }
  }
}

module "redis-private-dns-zone" {
  source              = "Azure/avm-res-network-privatednszone/azurerm"
  version             = "0.1.2"
  domain_name         = "privatelink.redisenterprise.cache.azure.net"
  resource_group_name = azurerm_resource_group.ibredistest-rg.name
  virtual_network_links = {
    "primary" = {
      vnetlinkname = "ibredistest-vnet-primary"
      vnetid       = module.ibredistest-vnet-primary.resource_id
    }
    "secondary" = {
      vnetlinkname = "ibredistest-vnet-secondary"
      vnetid       = module.ibredistest-vnet-secondary.resource_id
    }
  }
}
