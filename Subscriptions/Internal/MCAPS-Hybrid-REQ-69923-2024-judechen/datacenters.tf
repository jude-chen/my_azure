resource "azurerm_resource_provider_registration" "cognitiveservices" {
  name  = "Microsoft.CognitiveServices"
  lifecycle {
    ignore_changes = all
  }
}
