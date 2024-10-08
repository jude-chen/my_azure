# We strongly recommend using the required_providers block to set the
# Azure Provider source and version being used
terraform {
  cloud {
    organization = "jude-demos"

    workspaces {
      name = "avdlza"
    }
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
  required_version = "~> 1.7.0"
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  features {}
  subscription_id = "3c37c1b6-f951-43bd-ad04-721b79a104a8"
}
