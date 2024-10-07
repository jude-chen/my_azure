resource "azurerm_resource_group" "private-dns-rg" {
  location = local.primary_region
  name     = "private-dns-rg"
}
