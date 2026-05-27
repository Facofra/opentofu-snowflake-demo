terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    null    = { source = "hashicorp/null",    version = "~> 3.2" }
  }
  backend "azurerm" {
    resource_group_name  = "tofu-group"
    storage_account_name = "opentofuttetst"
    container_name       = "azure"
    key                  = "snowflake.tfstate"
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_key_vault" "kv" {
  name                = "kv-snowflake-facu-001"
  resource_group_name = "tofu-group"
}

# Lista todos los nombres de secrets en el KV.
data "azurerm_key_vault_secrets" "all" {
  key_vault_id = data.azurerm_key_vault.kv.id
}

locals {
  # Filtra solo los public keys.
  public_key_names = toset([
    for n in data.azurerm_key_vault_secrets.all.names : n
    if endswith(n, "-public-key")
  ])
}

# Lee el valor de cada public key.
data "azurerm_key_vault_secret" "public_keys" {
  for_each     = local.public_key_names
  name         = each.key
  key_vault_id = data.azurerm_key_vault.kv.id
}

# Echo de los primeros 50 caracteres de cada public key en el apply.
resource "null_resource" "echo_public_keys" {
  for_each = data.azurerm_key_vault_secret.public_keys

  triggers = {
    snippet = substr(nonsensitive(each.value.value), 0, 50)
  }

  provisioner "local-exec" {
    command = "echo '${each.key}: ${substr(nonsensitive(each.value.value), 0, 50)}'"
  }
}
