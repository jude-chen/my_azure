variable "is_new_subscription" {
  type    = bool
  default = false
}

resource "azurerm_resource_provider_registration" "cognitiveservices" {
  count = var.is_new_subscription ? 1 : 0
  name  = "Microsoft.CognitiveServices"
}
