terraform {
  backend "azurerm" {
    resource_group_name  = "tofu-group"
    storage_account_name = "opentofuttetst"
    container_name       = "tfstate"
    key                  = "azure/terraform.tfstate"

    use_oidc         = true
    use_azuread_auth = true
  }
}

# provider "azurerm" {
#   features {}
#   use_oidc = true
# }

# A very simple configuration that doesn't need external providers
resource "null_resource" "example2" {
  provisioner "local-exec" {
    command = "echo 'Hello OpenTofu! Environment:. The secret value is: nothing3'"
  }
}

