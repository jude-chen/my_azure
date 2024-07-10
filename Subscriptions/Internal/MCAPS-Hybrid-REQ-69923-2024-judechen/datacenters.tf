variable "is_new_subscription" {
  type    = bool
  default = false
}

resource "azurerm_resource_provider_registration" "cognitiveservices" {
  count = var.is_new_subscription ? 1 : 0
  name  = "Microsoft.CognitiveServices"
  # lifecycle {
  #   precondition {
  #     condition     = var.is_new_subscription
  #     error_message = "Resource provider is already registered!"
  #   }
  # }
}

resource "azurerm_resource_group" "datacenter_eastus" {
  location = "eastus"
  name     = "datacenter-eastus-rg"
}
