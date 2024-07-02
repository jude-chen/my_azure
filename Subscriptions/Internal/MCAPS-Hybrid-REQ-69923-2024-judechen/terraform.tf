# We strongly recommend using the required_providers block to set the
# Azure Provider source and version being used
terraform {
  cloud {
    organization = "jude-demos"

    workspaces {
      name = "MCAPS-Hybrid-REQ-69923-2024-judechen"
    }
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
  required_version = "~> 1.9.0"
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  features {}
  subscription_id = "3ab3f568-ab27-413c-be5a-7a1cc89a8104"
}
