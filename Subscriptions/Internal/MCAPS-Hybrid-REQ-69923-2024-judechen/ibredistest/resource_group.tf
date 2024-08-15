resource "azurerm_resource_group" "ibredistest-rg" {
  location = local.primary_region
  name     = "ib-redis-test-rg"
}
