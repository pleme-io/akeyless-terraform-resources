#!/usr/bin/env bash
# sync-gen-repos.sh
#
# Generates IaC artifacts from Akeyless resource specs and distributes them
# to the corresponding -gen repos. Idempotent and safe to run repeatedly.
#
# Usage:
#   ./scripts/sync-gen-repos.sh [--spec <openapi.yaml>] [--dry-run]
#
# Environment:
#   IAC_FORGE  -- path to iac-forge binary (default: iac-forge in PATH or nix result)
#   PLEME_DIR  -- base dir for pleme-io repos (default: ~/code/github/pleme-io)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
PLEME_DIR="${PLEME_DIR:-$HOME/code/github/pleme-io}"
SPEC="${1:---spec}"
DRY_RUN=false

# Parse arguments
OPENAPI_SPEC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec)
      OPENAPI_SPEC="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Default OpenAPI spec location
if [[ -z "$OPENAPI_SPEC" ]]; then
  OPENAPI_SPEC="$HOME/code/github/akeylesslabs/akeyless-go/api/openapi.yaml"
fi

if [[ ! -f "$OPENAPI_SPEC" ]]; then
  echo "ERROR: OpenAPI spec not found: $OPENAPI_SPEC"
  exit 1
fi

# Find iac-forge binary
if [[ -n "${IAC_FORGE:-}" ]]; then
  IAC_FORGE_BIN="$IAC_FORGE"
elif command -v iac-forge &>/dev/null; then
  IAC_FORGE_BIN="iac-forge"
elif [[ -x "$PLEME_DIR/iac-forge-cli/result/bin/iac-forge" ]]; then
  IAC_FORGE_BIN="$PLEME_DIR/iac-forge-cli/result/bin/iac-forge"
else
  echo "ERROR: iac-forge not found. Set IAC_FORGE or add it to PATH."
  exit 1
fi

echo "=> Using iac-forge: $IAC_FORGE_BIN"
echo "=> OpenAPI spec:    $OPENAPI_SPEC"
echo "=> Resources:       $REPO_ROOT/resources"
echo "=> Provider:        $REPO_ROOT/provider.toml"

# Backend -> gen repo mapping
declare -A BACKEND_REPOS=(
  [terraform]="terraform-akeyless-gen"
  [ansible]="ansible-akeyless-gen"
  [crossplane]="crossplane-akeyless-gen"
  [helm]="helm-akeyless-gen"
  [pulumi]="pulumi-akeyless-gen"
  [steampipe]="steampipe-akeyless-gen"
)

# Create temp output directory
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo ""
echo "=> Generating artifacts into $TMPDIR"

# Track which backends succeed
SUCCEEDED_BACKENDS=()

# Generate for each backend individually (some may not be implemented yet)
for backend in terraform pulumi crossplane ansible steampipe; do
  echo ""
  echo "--- Generating: $backend ---"
  if "$IAC_FORGE_BIN" generate \
    --spec "$OPENAPI_SPEC" \
    --resources "$REPO_ROOT/resources" \
    --provider "$REPO_ROOT/provider.toml" \
    --output "$TMPDIR/$backend" \
    --backend "$backend" 2>&1; then
    SUCCEEDED_BACKENDS+=("$backend")
    echo "  [OK] $backend"
  else
    echo "  [SKIP] $backend (not yet implemented or failed)"
  fi
done

echo ""
echo "=> Successfully generated: ${SUCCEEDED_BACKENDS[*]:-none}"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "=> Dry run -- not copying to gen repos."
  echo "=> Generated files:"
  find "$TMPDIR" -type f | sort
  exit 0
fi

# Copy artifacts to -gen repos
for backend in "${SUCCEEDED_BACKENDS[@]}"; do
  repo_name="${BACKEND_REPOS[$backend]}"
  repo_path="$PLEME_DIR/$repo_name"

  if [[ ! -d "$repo_path" ]]; then
    echo "  [WARN] Repo dir missing, creating: $repo_path"
    mkdir -p "$repo_path"
  fi

  gen_dir="$TMPDIR/$backend"

  # For terraform, the generate command outputs into a terraform/ subdir
  if [[ -d "$gen_dir/terraform" ]]; then
    gen_dir="$gen_dir/terraform"
  fi

  if [[ ! -d "$gen_dir" ]] || [[ -z "$(ls -A "$gen_dir" 2>/dev/null)" ]]; then
    echo "  [SKIP] No artifacts for $backend"
    continue
  fi

  echo "=> Syncing $backend -> $repo_path"

  # Copy generated files, preserving directory structure
  # Skip .git and existing flake.nix in target
  rsync -av --delete \
    --exclude='.git' \
    --exclude='.git/**' \
    "$gen_dir/" "$repo_path/" \
    --filter='P flake.nix' \
    --filter='P flake.lock' \
    --filter='P .git' \
    --filter='P .git/**' \
    --filter='P .gitignore' \
    --filter='P LICENSE' \
    --filter='P CLAUDE.md' \
    --filter='P README.md'

  echo "  [OK] $repo_name updated"
done

echo ""
echo "=> Ensuring flake.nix exists in each -gen repo"

# --- Flake generation for repos that don't have one ---

# ansible-akeyless-gen (Python)
ANSIBLE_GEN="$PLEME_DIR/ansible-akeyless-gen"
if [[ -d "$ANSIBLE_GEN" ]] && [[ ! -f "$ANSIBLE_GEN/flake.nix" ]]; then
  echo "  Creating flake.nix for ansible-akeyless-gen"
  cat > "$ANSIBLE_GEN/flake.nix" << 'FLAKE_EOF'
{
  description = "Generated Ansible collection for Akeyless";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        packages.default = pkgs.runCommand "ansible-akeyless-gen" {
          src = self;
        } ''
          mkdir -p $out/share/ansible/collections/akeyless
          cp -r $src/modules $out/share/ansible/collections/akeyless/ 2>/dev/null || true
          cp -r $src/plugins $out/share/ansible/collections/akeyless/ 2>/dev/null || true
          cp -r $src/*.py $out/share/ansible/collections/akeyless/ 2>/dev/null || true
          # Ensure at least one file exists
          touch $out/share/ansible/collections/akeyless/.generated
        '';
      }
    );
}
FLAKE_EOF
fi

# crossplane-akeyless-gen (YAML CRDs)
CROSSPLANE_GEN="$PLEME_DIR/crossplane-akeyless-gen"
if [[ -d "$CROSSPLANE_GEN" ]] && [[ ! -f "$CROSSPLANE_GEN/flake.nix" ]]; then
  echo "  Creating flake.nix for crossplane-akeyless-gen"
  cat > "$CROSSPLANE_GEN/flake.nix" << 'FLAKE_EOF'
{
  description = "Generated Crossplane CRDs for Akeyless";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        packages.default = pkgs.runCommand "crossplane-akeyless-gen" {
          src = self;
        } ''
          mkdir -p $out/share/crossplane/crds
          find $src -name '*.yaml' -exec cp {} $out/share/crossplane/crds/ \;
          # Ensure at least one file exists
          touch $out/share/crossplane/crds/.generated
        '';
      }
    );
}
FLAKE_EOF
fi

# helm-akeyless-gen (Helm charts)
HELM_GEN="$PLEME_DIR/helm-akeyless-gen"
if [[ -d "$HELM_GEN" ]] && [[ ! -f "$HELM_GEN/flake.nix" ]]; then
  echo "  Creating flake.nix for helm-akeyless-gen"
  cat > "$HELM_GEN/flake.nix" << 'FLAKE_EOF'
{
  description = "Generated Helm charts for Akeyless";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        packages.default = pkgs.runCommand "helm-akeyless-gen" {
          src = self;
        } ''
          mkdir -p $out/share/helm/charts
          for dir in $src/charts/*/; do
            if [ -d "$dir" ]; then
              cp -r "$dir" $out/share/helm/charts/
            fi
          done
          # Copy any top-level chart dirs too
          for f in $src/*/Chart.yaml; do
            if [ -f "$f" ]; then
              chart_dir="$(dirname "$f")"
              cp -r "$chart_dir" $out/share/helm/charts/
            fi
          done
          touch $out/share/helm/charts/.generated
        '';
      }
    );
}
FLAKE_EOF
fi

# pulumi-akeyless-gen (JSON schema)
PULUMI_GEN="$PLEME_DIR/pulumi-akeyless-gen"
if [[ -d "$PULUMI_GEN" ]] && [[ ! -f "$PULUMI_GEN/flake.nix" ]]; then
  echo "  Creating flake.nix for pulumi-akeyless-gen"
  cat > "$PULUMI_GEN/flake.nix" << 'FLAKE_EOF'
{
  description = "Generated Pulumi schema for Akeyless";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        packages.default = pkgs.runCommand "pulumi-akeyless-gen" {
          src = self;
        } ''
          mkdir -p $out/share/pulumi
          find $src -name '*.json' -exec cp {} $out/share/pulumi/ \;
          touch $out/share/pulumi/.generated
        '';
      }
    );
}
FLAKE_EOF
fi

# steampipe-akeyless-gen (Go)
STEAMPIPE_GEN="$PLEME_DIR/steampipe-akeyless-gen"
if [[ -d "$STEAMPIPE_GEN" ]] && [[ ! -f "$STEAMPIPE_GEN/flake.nix" ]]; then
  echo "  Creating flake.nix for steampipe-akeyless-gen"
  cat > "$STEAMPIPE_GEN/flake.nix" << 'FLAKE_EOF'
{
  description = "Generated Steampipe plugin for Akeyless";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        packages.default = pkgs.runCommand "steampipe-akeyless-gen" {
          src = self;
        } ''
          mkdir -p $out/share/steampipe
          cp -r $src/*.go $out/share/steampipe/ 2>/dev/null || true
          cp -r $src/tables $out/share/steampipe/ 2>/dev/null || true
          touch $out/share/steampipe/.generated
        '';

        # When go.mod exists and vendorHash is known, replace with:
        # packages.default = pkgs.buildGoModule {
        #   pname = "steampipe-plugin-akeyless";
        #   version = "0.1.0";
        #   src = self;
        #   vendorHash = null; # update after first build
        # };
      }
    );
}
FLAKE_EOF
fi

# terraform-akeyless-gen (Go) -- only create if missing
TERRAFORM_GEN="$PLEME_DIR/terraform-akeyless-gen"
if [[ -d "$TERRAFORM_GEN" ]] && [[ ! -f "$TERRAFORM_GEN/flake.nix" ]]; then
  echo "  Creating flake.nix for terraform-akeyless-gen"
  cat > "$TERRAFORM_GEN/flake.nix" << 'FLAKE_EOF'
{
  description = "Generated Terraform provider for Akeyless";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        packages.default = pkgs.runCommand "terraform-akeyless-gen" {
          src = self;
        } ''
          mkdir -p $out/share/terraform
          cp -r $src/resources $out/share/terraform/ 2>/dev/null || true
          cp -r $src/provider $out/share/terraform/ 2>/dev/null || true
          touch $out/share/terraform/.generated
        '';

        # When go.mod exists, replace with:
        # packages.default = pkgs.buildGoModule {
        #   pname = "terraform-provider-akeyless";
        #   version = "0.1.0";
        #   src = self;
        #   vendorHash = null; # update after first build
        # };
      }
    );
}
FLAKE_EOF
fi

echo ""
echo "=> Sync complete."
echo ""
echo "Backend summary:"
for backend in terraform ansible crossplane helm pulumi steampipe; do
  repo="${BACKEND_REPOS[$backend]}"
  repo_path="$PLEME_DIR/$repo"
  count="$(find "$repo_path" -type f -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')"
  has_flake="$(test -f "$repo_path/flake.nix" && echo "yes" || echo "no")"
  echo "  $repo: $count files, flake.nix=$has_flake"
done
