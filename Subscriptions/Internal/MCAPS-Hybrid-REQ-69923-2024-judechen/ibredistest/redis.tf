resource "azurerm_redis_enterprise_cluster" "ibredistest-primary" {
  name                = "ibredistest-primary"
  resource_group_name = azurerm_resource_group.ibredistest-rg.name
  location            = local.primary_region

  sku_name = "Enterprise_E5-2"
}

resource "azurerm_private_endpoint" "ibredistest-pe-primary" {
  name                = "ibredistest-pe-primary"
  location            = local.primary_region
  resource_group_name = azurerm_resource_group.ibredistest-rg.name

  subnet_id = module.ibredistest-vnet-primary.subnets["subnet2"].resource_id

  private_service_connection {
    name                           = "ibredistest-psc-primary"
    private_connection_resource_id = azurerm_redis_enterprise_cluster.ibredistest-primary.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "ibredistest-pe-primary"
    private_dns_zone_ids = [module.redis-private-dns-zone.resource_id]
  }
}

resource "azurerm_redis_enterprise_cluster" "ibredistest-secondary" {
  name                = "ibredistest-secondary"
  resource_group_name = azurerm_resource_group.ibredistest-rg.name
  location            = local.secondary_region

  sku_name = "Enterprise_E5-2"
}

resource "azurerm_private_endpoint" "ibredistest-pe-secondary" {
  name                = "ibredistest-pe-secondary"
  location            = local.secondary_region
  resource_group_name = azurerm_resource_group.ibredistest-rg.name

  subnet_id = module.ibredistest-vnet-secondary.subnets["subnet2"].resource_id

  private_service_connection {
    name                           = "ibredistest-psc-secondary"
    private_connection_resource_id = azurerm_redis_enterprise_cluster.ibredistest-secondary.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "ibredistest-pe-secondary"
    private_dns_zone_ids = [module.redis-private-dns-zone.resource_id]
  }
}

resource "azurerm_redis_enterprise_database" "default-primary" {
  name              = "default"
  cluster_id        = azurerm_redis_enterprise_cluster.ibredistest-primary.id
  clustering_policy = "EnterpriseCluster"
  eviction_policy   = "NoEviction"
  module {
    name = "RediSearch"
  }
  module {
    name = "RedisJSON"
  }
  linked_database_id = [
    "${azurerm_redis_enterprise_cluster.ibredistest-primary.id}/databases/default",
    "${azurerm_redis_enterprise_cluster.ibredistest-secondary.id}/databases/default"
  ]

  linked_database_group_nickname = "ibredistestGeoGroup"
}

resource "azurerm_redis_enterprise_database" "default-secondary" {
  name              = "default"
  cluster_id        = azurerm_redis_enterprise_cluster.ibredistest-secondary.id
  clustering_policy = "EnterpriseCluster"
  eviction_policy   = "NoEviction"
  module {
    name = "RediSearch"
  }
  module {
    name = "RedisJSON"
  }
  linked_database_id = [
    "${azurerm_redis_enterprise_cluster.ibredistest-primary.id}/databases/default",
    "${azurerm_redis_enterprise_cluster.ibredistest-secondary.id}/databases/default"
  ]

  linked_database_group_nickname = "ibredistestGeoGroup"
}
