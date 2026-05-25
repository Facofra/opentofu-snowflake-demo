terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
  backend "azurerm" {
    resource_group_name  = "tofu-group"
    storage_account_name = "opentofuttetst"
    container_name       = "azure"
    key                  = "prod/terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

data "azurerm_client_config" "current" {}

data "azurerm_key_vault" "kv" {
  name                = "kv-snowflake-facu-001"
  resource_group_name = "tofu-group"
}

variable "service_keys" {
  description = "Map de keys a rotar/crear (selected en el workflow). Los combos que NO esten aca, se leen del KV via data source y se preservan sin cambios."
  type = map(object({
    passphrase  = string
    private_key = string
    public_key  = string
  }))
  default   = {}
  sensitive = true
}

resource "azurerm_role_assignment" "kv_secrets_officer" {
  scope                = data.azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

locals {
  all_services = [
    "SERVICE_DBT",
    "SERVICE_DBT_CICD",
    "SERVICE_FIVETRAN",
    "SERVICE_UTMBUILDER",
    "SERVICE_SEGMENT",
    "SERVICE_CUBE",
    "SERVICE_COLLATE",
    "SERVICE_OPENTOFU",
  ]
  all_envs = ["cicd", "prod"]

  # Todos los prefijos posibles segun el naming convention.
  all_possible_prefixes = toset([
    for c in setproduct(local.all_services, local.all_envs) :
    c[1] == "prod"
      ? "snowflake-drhorton-${replace(lower(c[0]), "_", "-")}"
      : "snowflake-drhorton${c[1]}-${replace(lower(c[0]), "_", "-")}"
  ])
}

# Lista todos los secrets que ya existen en el KV.
data "azurerm_key_vault_secrets" "all" {
  key_vault_id = data.azurerm_key_vault.kv.id
}

locals {
  existing_secret_names = toset(data.azurerm_key_vault_secrets.all.names)

  # Prefijos que ya existen completamente (los 3 secrets) en KV.
  existing_prefixes = toset([
    for p in local.all_possible_prefixes : p
    if contains(local.existing_secret_names, "${p}-passphrase") &&
       contains(local.existing_secret_names, "${p}-private-key") &&
       contains(local.existing_secret_names, "${p}-public-key")
  ])
}

# Lee los valores existentes para los prefijos que existen.
data "azurerm_key_vault_secret" "existing_passphrase" {
  for_each     = local.existing_prefixes
  name         = "${each.key}-passphrase"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "existing_private_key" {
  for_each     = local.existing_prefixes
  name         = "${each.key}-private-key"
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_key_vault_secret" "existing_public_key" {
  for_each     = local.existing_prefixes
  name         = "${each.key}-public-key"
  key_vault_id = data.azurerm_key_vault.kv.id
}

locals {
  variable_prefixes = nonsensitive(toset(keys(var.service_keys)))

  # Combos a manejar = los del variable union los que ya existen en KV.
  effective_prefixes = setunion(local.variable_prefixes, local.existing_prefixes)

  # Para cada combo: variable gana si esta presente, si no usa el existente.
  effective_values = {
    for p in local.effective_prefixes :
    p => {
      passphrase  = contains(local.variable_prefixes, p) ? var.service_keys[p].passphrase  : data.azurerm_key_vault_secret.existing_passphrase[p].value
      private_key = contains(local.variable_prefixes, p) ? var.service_keys[p].private_key : data.azurerm_key_vault_secret.existing_private_key[p].value
      public_key  = contains(local.variable_prefixes, p) ? var.service_keys[p].public_key  : data.azurerm_key_vault_secret.existing_public_key[p].value
    }
  }
}

resource "azurerm_key_vault_secret" "passphrase" {
  for_each     = local.effective_prefixes
  name         = "${each.key}-passphrase"
  value        = local.effective_values[each.key].passphrase
  key_vault_id = data.azurerm_key_vault.kv.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "private_key" {
  for_each     = local.effective_prefixes
  name         = "${each.key}-private-key"
  value        = local.effective_values[each.key].private_key
  key_vault_id = data.azurerm_key_vault.kv.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "public_key" {
  for_each     = local.effective_prefixes
  name         = "${each.key}-public-key"
  value        = local.effective_values[each.key].public_key
  key_vault_id = data.azurerm_key_vault.kv.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}
