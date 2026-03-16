# akeyless-terraform-resources

119 TOML resource specifications covering the full Akeyless API surface.
These specs are the declarative input for `iac-forge` code generation across
all backends (Terraform, Pulumi, Crossplane, Ansible, Pangea, Steampipe).

## Directory Structure

```
resources/
  auth_methods/     # 15 specs: API key, AWS IAM, Azure AD, cert, email, GCP, Huawei, K8s, Kerberos, LDAP, OAuth2, OCI, OIDC, SAML, universal identity
  dynamic_secrets/  # Dynamic secret producers
  event_forwarders/ # Event forwarding targets
  gateway/          # Gateway configuration
  keys/             # Encryption keys
  misc/             # Miscellaneous resources
  roles/            # Role-based access
  rotated_secrets/  # Auto-rotating secrets
  secrets/          # Static secrets, PKI cert issuers, SSH cert issuers
  targets/          # Backend targets (DB, cloud, etc.)
data_sources/       # Data source specs (empty -- not yet populated)
provider.toml       # Provider-level configuration
```

## TOML Resource Format

Each resource spec defines a complete CRUD mapping:

```toml
[resource]
name = "akeyless_static_secret"
description = "Manages a static secret"
category = "secret"

[crud]
create_endpoint = "/create-secret"
create_schema = "CreateSecret"
update_endpoint = "/update-secret-val"       # optional
update_schema = "UpdateSecretVal"             # optional
read_endpoint = "/describe-item"
read_schema = "describeItem"
read_response_schema = "Item"                 # optional: response type differs from request
delete_endpoint = "/delete-item"
delete_schema = "deleteItem"

[identity]
id_field = "name"                             # field used as resource ID
import_field = "name"                         # field used for import (optional, defaults to id_field)
force_new_fields = ["name"]                   # changing these forces resource replacement

[fields]
# Override field behavior detected from OpenAPI spec
"field-name" = { type_override = "bool", description = "Override description" }
"skip-field" = { skip = true }                # exclude from generated code

[read_mapping]
# Map API response fields to resource state fields
"item_name" = "name"
"item_type" = "type"
"item_metadata" = "description"
"item_tags" = "tags"
```

## provider.toml

```toml
[provider]
name = "akeyless"
description = "Akeyless Vault Provider"
version = "1.0.0"
sdk_import = "github.com/akeylesslabs/akeyless-go/v5"

[auth]
token_field = "token"
env_var = "AKEYLESS_ACCESS_TOKEN"
gateway_url_field = "api_gateway_address"
gateway_env_var = "AKEYLESS_GATEWAY"

[defaults]
skip_fields = ["token", "uid-token", "json", ...]   # fields excluded from all resources
```

## Adding a New Resource

1. Identify the CRUD endpoints in the Akeyless OpenAPI spec
2. Create a TOML file in the appropriate `resources/<category>/` directory
3. Define `[resource]`, `[crud]`, `[identity]` sections
4. Add `[fields]` overrides for type corrections or skipped fields
5. Add `[read_mapping]` if the read response uses different field names
6. Validate: `iac-forge validate --spec api.yaml --resources resources/`
7. Generate: `iac-forge generate --backend all --spec api.yaml --resources resources/ --output ./out/`

Or use auto-scaffolding to generate a starter spec:
```bash
iac-forge scaffold --spec api.yaml --output resources/
```

## Validation

```bash
# Check all specs against the OpenAPI spec
iac-forge validate --spec api.yaml --resources resources/

# Detect missing or extra resources vs the API
iac-forge drift --spec api.yaml --resources resources/
```

## Generation

```bash
# Generate for all backends
iac-forge generate --backend all --spec api.yaml --resources resources/ --output ./out/ --provider provider.toml

# Generate for a specific backend
iac-forge generate --backend terraform --spec api.yaml --resources resources/ --output ./out/ --provider provider.toml

# Full API evolution sync (diff + drift + scaffold + validate + generate)
iac-forge sync --spec-old old-api.yaml --spec-new new-api.yaml --resources resources/ --output ./out/ --provider provider.toml --auto-scaffold
```
