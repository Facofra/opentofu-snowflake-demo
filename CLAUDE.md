# Snowflake Service Keys → Azure Key Vault

End-to-end pipeline to generate RSA key pairs for Snowflake service users
(key-pair auth) and publish them to an Azure Key Vault, all triggered from a
GitHub Actions workflow with a plan/apply split and approval gate.

This file documents everything needed to recreate the same flow in another
repository.

---

## What it does

For each `(service, environment)` combo the user picks (or `ALL`):

1. Generates a random 32-byte hex passphrase.
2. Generates an RSA-2048 private key, encrypts it as PKCS#8 + DES3 using the
   passphrase (this is what Snowflake key-pair auth expects).
3. Extracts the public key (base64 body, no PEM headers).
4. Writes three secrets to an existing Azure Key Vault:
   - `<prefix>-passphrase`
   - `<prefix>-private-key`
   - `<prefix>-public-key`

The selective-rotation pattern: secrets passed via the variable are rotated;
secrets already in Key Vault but **not** in the variable are read via data
source and re-applied unchanged. So selecting `SERVICE_FOO + cicd` only
rotates that one service's `cicd` keys; everything else stays put.

---

## Architecture

```
.github/workflows/generate-service-keys.yml   ← single workflow, plan + apply jobs
azure/main.tf                                 ← OpenTofu config (Key Vault secrets)
azure/scripts/generate-tfvars.sh              ← optional local helper for tfvars
```

Backend: OpenTofu state lives in an Azure Storage blob (also acts as state
lock via blob lease).

Auth: a Service Principal with client-secret credentials (`ARM_CLIENT_ID`,
`ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` env vars). For a
test repo this is fine; for production prefer OIDC federated credentials.

---

## Naming convention (Snowflake side)

This repo uses:

```
snowflake-<account>[<env-suffix>]-<service-kebab>-<type>
```

- `account` segment: `drhorton`
- `env-suffix`: empty for `prod`, equal to the env name for non-prod (e.g. `cicd` → `drhortoncicd`)
- `service-kebab`: lowercased, underscores → dashes (e.g. `SERVICE_OPENTOFU` → `service-opentofu`)
- `type`: one of `passphrase`, `private-key`, `public-key`

Examples:
- `snowflake-drhorton-service-opentofu-passphrase` (prod)
- `snowflake-drhortoncicd-service-opentofu-private-key` (cicd)

**To adapt to another repo:** change the account name and env-suffix logic in
two places — `main.tf` (`local.all_possible_prefixes`) and the bash blocks
inside `generate-service-keys.yml`.

---

## File: `azure/main.tf`

Pure OpenTofu config. Three logical layers:

### Layer 1 — backend, provider, data sources

```hcl
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

data "azurerm_key_vault" "kv" {
  name                = "kv-snowflake-facu-001"
  resource_group_name = "tofu-group"
}
```

Notes:
- The Key Vault is **read**, not managed by this config. Create it once
  manually (see Azure setup below).
- `purge_soft_delete_on_destroy` is convenient for testing only.

### Layer 2 — variable + matrix

```hcl
variable "service_keys" {
  description = "Combos to rotate/create. Anything missing here is preserved as-is."
  type = map(object({
    passphrase  = string
    private_key = string
    public_key  = string
  }))
  default   = {}
  sensitive = true
}

locals {
  all_services = [
    "SERVICE_DBT", "SERVICE_DBT_CICD", "SERVICE_FIVETRAN",
    "SERVICE_UTMBUILDER", "SERVICE_SEGMENT", "SERVICE_CUBE",
    "SERVICE_COLLATE", "SERVICE_OPENTOFU",
  ]
  all_envs = ["cicd", "prod"]

  all_possible_prefixes = toset([
    for c in setproduct(local.all_services, local.all_envs) :
    c[1] == "prod"
      ? "snowflake-drhorton-${replace(lower(c[0]), "_", "-")}"
      : "snowflake-drhorton${c[1]}-${replace(lower(c[0]), "_", "-")}"
  ])
}
```

`var.service_keys` is `sensitive = true` so values never appear in plan
output. Keys are extracted with `nonsensitive(toset(keys(...)))` below
because `for_each` cannot use a sensitive value.

### Layer 3 — read existing + merge + write

This is the selective-rotation core:

```hcl
data "azurerm_key_vault_secrets" "all" {
  key_vault_id = data.azurerm_key_vault.kv.id
}

locals {
  existing_secret_names = toset(data.azurerm_key_vault_secrets.all.names)

  existing_prefixes = toset([
    for p in local.all_possible_prefixes : p
    if contains(local.existing_secret_names, "${p}-passphrase") &&
       contains(local.existing_secret_names, "${p}-private-key") &&
       contains(local.existing_secret_names, "${p}-public-key")
  ])
}

data "azurerm_key_vault_secret" "existing_passphrase" {
  for_each     = local.existing_prefixes
  name         = "${each.key}-passphrase"
  key_vault_id = data.azurerm_key_vault.kv.id
}
# (similar blocks for existing_private_key and existing_public_key)

locals {
  variable_prefixes  = nonsensitive(toset(keys(var.service_keys)))
  effective_prefixes = setunion(local.variable_prefixes, local.existing_prefixes)

  effective_values = {
    for p in local.effective_prefixes : p => {
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
}
# (similar resources for private_key and public_key)
```

Truth table for what tofu does per combo:

| In variable? | In KV? | Action                                     |
|--------------|--------|--------------------------------------------|
| yes          | yes    | Update (rotation)                          |
| yes          | no     | Create                                     |
| no           | yes    | No-op (data source value == current value) |
| no           | no     | Not in `effective_prefixes`, untouched     |

No `lifecycle { ignore_changes = [value] }` is needed — selectivity is driven
purely by what the workflow puts into the variable.

---

## File: `.github/workflows/generate-service-keys.yml`

Single workflow, two jobs.

### Triggers

```yaml
on:
  workflow_dispatch:
    inputs:
      service_name:
        description: "Snowflake service (ALL = todos)"
        type: choice
        default: ALL
        options: [ALL, SERVICE_DBT, ..., SERVICE_OPENTOFU]
      environment:
        description: "Target environment (ALL = todos)"
        type: choice
        default: ALL
        options: [ALL, cicd, prod]
```

### Global env

```yaml
env:
  ARM_CLIENT_ID:       ${{ secrets.AZURE_CLIENT_ID }}
  ARM_CLIENT_SECRET:   ${{ secrets.AZURE_CLIENT_SECRET }}
  ARM_TENANT_ID:       ${{ secrets.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  TOFU_VERSION:        "1.11.5"
```

OpenTofu picks up these `ARM_*` env vars automatically — no `azure/login`
action needed.

### Job `plan`

1. Checks out the repo.
2. Installs OpenTofu via `opentofu/setup-opentofu@v1`.
3. Builds `terraform.tfvars.json` inline with **dummy** values (literal
   `"PLAN_PREVIEW"` for every field). The matrix selection logic for
   `service_name` and `environment` mirrors the apply job.
4. `tofu init`.
5. `tofu plan`. Output shows the resources that would change; secret values
   appear as `(sensitive value)`.
6. Cleanup step deletes `terraform.tfvars.json` (`if: always()`).

The plan is **illustrative** — its values do not match what apply will write.
The point is to let an approver see "X secrets will be touched, with these
names".

### Job `apply`

1. `needs: plan` — waits for plan to succeed.
2. `environment: azure-keyvault-apply` — gates the job behind GitHub's
   environment-approval mechanism.
3. Same checkout / setup-opentofu steps.
4. Builds `terraform.tfvars.json` inline with **real** values generated by
   `openssl`. Bash logic per combo:

   ```bash
   PASSPHRASE=$(openssl rand -hex 32)
   openssl genrsa 2048 2>/dev/null \
     | openssl pkcs8 -topk8 -v2 des3 -inform PEM \
         -out "$PRIV" -passout "pass:$PASSPHRASE"
   openssl rsa -in "$PRIV" -pubout -out "$PUB" -passin "pass:$PASSPHRASE" 2>/dev/null
   PRIVATE_KEY=$(cat "$PRIV")
   PUBLIC_KEY=$(grep -v '^-----' "$PUB" | tr -d '\n')
   ```

   Each combo is added to the JSON via `jq`.
5. `tofu init`.
6. `tofu apply -input=false -auto-approve`. Apply computes its own plan
   internally — the apply matches its own plan, not the preview job's.
7. Cleanup step deletes `terraform.tfvars.json` (`if: always()`).

The values from the apply job are the ones that end up in Key Vault. The
plan job's dummy values are discarded before that job ends.

---

## File: `azure/scripts/generate-tfvars.sh`

Local-dev helper. Generates the same RSA + passphrase per combo but writes
HCL (not JSON) into `azure/terraform.tfvars`, for use with `tofu apply` from
a workstation. Same `openssl` pipeline as the workflow.

Refuses to overwrite an existing `terraform.tfvars`. Pass a different path as
the first arg if you need to.

This script is **out of sync** with the new naming convention unless you
update its `KEY_NAME` construction to match `main.tf`/the workflow.

---

## Azure setup (one-time)

Everything below has to exist before the workflow can run.

### 1. Key Vault

```bash
RG="tofu-group"
KV_NAME="kv-snowflake-facu-001"
LOCATION="eastus"

az group create -n "$RG" -l "$LOCATION"
az keyvault create -n "$KV_NAME" -g "$RG" -l "$LOCATION" \
  --enable-rbac-authorization true
```

`--enable-rbac-authorization true` is required — the config assumes RBAC,
not access policies.

### 2. State backend (storage account + container)

```bash
SA_NAME="opentofuttetst"
az storage account create -n "$SA_NAME" -g "$RG" -l "$LOCATION" --sku Standard_LRS
az storage container create -n "azure" --account-name "$SA_NAME"
```

### 3. Service Principal for CI

```bash
SUB_ID=$(az account show --query id -o tsv)
MSYS_NO_PATHCONV=1 az ad sp create-for-rbac \
  --name "github-tofu-snowflake-demo" \
  --role Owner \
  --scopes "/subscriptions/$SUB_ID"
```

Returns `appId`, `password`, `tenant`. Save them — `password` is only shown
once.

`MSYS_NO_PATHCONV=1` is **required** on Git Bash for Windows, otherwise
arguments starting with `/` get rewritten to Windows paths.

For production: prefer a narrower role (Contributor + User Access
Administrator scoped to the RG) and OIDC federated credentials instead of a
client secret.

### 4. Grant the SP data-plane access to the Key Vault

The trickiest part. **Owner on subscription does NOT grant data-plane access
to Key Vault secrets** — RBAC for secrets is separate. The data sources in
`main.tf` (`azurerm_key_vault_secrets`, `azurerm_key_vault_secret`) run at
plan time and need this role.

```bash
SP_APP_ID="<appId from step 3>"
KV_ID=$(az keyvault show --name "$KV_NAME" --query id -o tsv)

MSYS_NO_PATHCONV=1 az role assignment create \
  --role "Key Vault Secrets Officer" \
  --assignee-object-id <SP_OBJECT_ID> \
  --assignee-principal-type ServicePrincipal \
  --scope "$KV_ID"
```

Wait ~30 seconds for RBAC propagation before the first plan/apply.

Get the SP's object ID with:

```bash
az ad sp show --id "$SP_APP_ID" --query id -o tsv
```

(The `appId` is the application's client-id; the `object-id` is the
principal's directory object id. They are different. Always use object-id
for role assignments.)

### 5. Grant the SP access to the state storage

The SP needs to be able to write the OpenTofu state blob:

```bash
SA_ID=$(az storage account show -n "$SA_NAME" -g "$RG" --query id -o tsv)
MSYS_NO_PATHCONV=1 az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id <SP_OBJECT_ID> \
  --assignee-principal-type ServicePrincipal \
  --scope "$SA_ID"
```

---

## GitHub setup (one-time)

### 1. Repository secrets

Settings → Secrets and variables → Actions → New repository secret:

| Name                    | Value                          |
|-------------------------|--------------------------------|
| `AZURE_CLIENT_ID`       | `appId` from `sp create-for-rbac` |
| `AZURE_CLIENT_SECRET`   | `password` from `sp create-for-rbac` |
| `AZURE_TENANT_ID`       | `tenant` from `sp create-for-rbac` |
| `AZURE_SUBSCRIPTION_ID` | output of `az account show --query id -o tsv` |

### 2. Environment with approval gate

Settings → Environments → New environment → name `azure-keyvault-apply`.

Configure:
- **Required reviewers**: add yourself / approvers.
- (Optional) **Deployment branches and tags**: restrict to `main` so a
  branch can't ship its own modified workflow through this gate.

The job named `apply` references this environment with
`environment: azure-keyvault-apply`. Until the environment exists, the apply
job will fail at validation.

---

## How to run

1. GitHub UI → Actions → "Generate Snowflake Service Keys → Azure Key Vault".
2. "Run workflow", pick `service_name` and `environment` (default `ALL`/`ALL`).
3. `plan` job runs unattended (~10 s, no openssl, dummy values).
4. `apply` job goes into *Waiting*. Approve in the UI.
5. `apply` job generates real keys (~30–60 s with openssl) and writes them.

---

## Security trade-offs that were made deliberately

- `terraform.tfvars.json` containing private keys exists on the runner only
  for the duration of the job. The cleanup step has `if: always()`. No
  artifact is uploaded.
- Plan/apply split shows the approver "what will happen" without persisting
  any secrets between jobs. The plan uses placeholder values, the apply
  generates fresh ones. The trade-off: the approver sees *names and counts*,
  not the literal bytes that get written.
- All key material (including the encrypted private key bytes) ends up in
  the OpenTofu state file in the storage account. Lock down read access to
  that container as tightly as possible. This is inherent to Terraform/
  OpenTofu — there is no way to manage a secret resource without its value
  living in state.
- The variable is `sensitive = true` so values do not appear in plan output
  logs, even on the apply side.

---

## Common gotchas

- **`MissingSubscription` errors on `az` commands** on Git Bash for Windows:
  prepend `MSYS_NO_PATHCONV=1` to anything whose argument starts with `/`.
- **`Caller is not authorized... readMetadata`** during `tofu plan`: the SP
  is missing `Key Vault Secrets Officer` on the vault. RBAC needs ~30 s to
  propagate after creation.
- **`azurerm_role_assignment` in state but not in code** after refactoring:
  `tofu state rm <addr>` to forget without deleting from Azure. Plain
  `tofu apply` would delete it.
- **First apply seems to fail intermittently**: RBAC propagation lag. Re-run.
- **`for_each` over sensitive value**: wrap with `nonsensitive(toset(keys(...)))`.
  Keys (the map's key strings) are identifiers, not secrets.
- **Heredoc vs JSON for `terraform.tfvars`**: workflows use JSON because it's
  trivial to build incrementally with `jq` and escape-safe. Local script uses
  HCL heredocs because they read better in a terminal.

---

## What you need to change for another repo

- `data "azurerm_key_vault" "kv"` → name + RG of your vault.
- Backend block (`resource_group_name`, `storage_account_name`,
  `container_name`, `key`) → your state storage.
- `local.all_services` → your Snowflake service users.
- `local.all_envs` → your environments.
- Prefix construction in `local.all_possible_prefixes` (the
  `snowflake-drhorton...` literal) → your naming convention.
- The `workflow_dispatch.inputs.service_name.options` list and the
  `ALL_SERVICES` arrays inside both bash blocks → mirror your services.
- Environment name `azure-keyvault-apply` in the apply job → whatever you
  named your GitHub environment.
- (Optional) `TOFU_VERSION`.

Everything else is generic and can stay as-is.
