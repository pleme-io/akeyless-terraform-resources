{
  description = "Akeyless IaC resource specifications and aggregate generated packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";

    # Generated artifact repos
    # For local testing, override with:
    #   nix flake show --override-input terraform-akeyless-gen git+file:///path/to/local/repo
    terraform-akeyless-gen = {
      url = "github:pleme-io/terraform-akeyless-gen";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    ansible-akeyless-gen = {
      url = "github:pleme-io/ansible-akeyless-gen";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    crossplane-akeyless-gen = {
      url = "github:pleme-io/crossplane-akeyless-gen";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    helm-akeyless-gen = {
      url = "github:pleme-io/helm-akeyless-gen";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    pulumi-akeyless-gen = {
      url = "github:pleme-io/pulumi-akeyless-gen";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    steampipe-akeyless-gen = {
      url = "github:pleme-io/steampipe-akeyless-gen";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    terraform-akeyless-gen,
    ansible-akeyless-gen,
    crossplane-akeyless-gen,
    helm-akeyless-gen,
    pulumi-akeyless-gen,
    steampipe-akeyless-gen,
  }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        # Resource specs as a derivation (for validation / downstream consumption)
        resource-specs = pkgs.runCommand "akeyless-resource-specs" {
          src = self;
        } ''
          mkdir -p $out/share/akeyless-resources
          cp -r $src/resources $out/share/akeyless-resources/
          cp -r $src/data_sources $out/share/akeyless-resources/ 2>/dev/null || true
          cp $src/provider.toml $out/share/akeyless-resources/
        '';

        # Collect generated packages from each -gen repo
        genPkgs = {
          terraform-provider = terraform-akeyless-gen.packages.${system}.default;
          ansible-collection = ansible-akeyless-gen.packages.${system}.default;
          crossplane-crds = crossplane-akeyless-gen.packages.${system}.default;
          helm-charts = helm-akeyless-gen.packages.${system}.default;
          pulumi-schema = pulumi-akeyless-gen.packages.${system}.default;
          steampipe-plugin = steampipe-akeyless-gen.packages.${system}.default;
        };

        # Content validation from each -gen repo
        contentChecks = {
          terraform-syntax = terraform-akeyless-gen.checks.${system}.default;
          steampipe-syntax = steampipe-akeyless-gen.checks.${system}.default;
          helm-lint = helm-akeyless-gen.checks.${system}.default;
          ansible-syntax = ansible-akeyless-gen.checks.${system}.default;
          crossplane-crds = crossplane-akeyless-gen.checks.${system}.default;
          pulumi-schema = pulumi-akeyless-gen.checks.${system}.default;
        };

        # Package build verification
        packageChecks = builtins.mapAttrs (name: pkg:
          pkgs.runCommand "check-pkg-${name}" {} ''
            test -d ${pkg} || (echo "FAIL: ${name} did not produce output" && exit 1)
            echo "OK: ${name} (${pkg})"
            mkdir -p $out
            echo "${name}: ${pkg}" > $out/result.txt
          ''
        ) genPkgs;

        allChecks = contentChecks // packageChecks;

        # Sync script wrapper
        sync-script = pkgs.writeShellApplication {
          name = "akeyless-iac-sync";
          runtimeInputs = [ pkgs.rsync ];
          text = ''
            exec "${self}/scripts/sync-gen-repos.sh" "$@"
          '';
        };
      in
      {
        packages = genPkgs // {
          default = resource-specs;
          inherit resource-specs;

          # Single build target that forces all checks to pass.
          # Used by kenshi: nix build .#verify-all
          verify-all = let
            checkRefs = lib.mapAttrsToList (name: drv:
              "echo '  ${name}: ${drv}' >> $out/result.txt && cat ${drv}/result.txt >> $out/result.txt 2>/dev/null || true"
            ) allChecks;
            numChecks = toString (builtins.length (builtins.attrNames allChecks));
          in pkgs.runCommand "verify-all-iac-backends" {} ''
            mkdir -p $out
            echo "=== IaC Backend Verification Report ===" > $out/result.txt
            ${builtins.concatStringsSep "\n" checkRefs}
            echo "" >> $out/result.txt
            echo "All ${numChecks} checks passed" >> $out/result.txt
            cat $out/result.txt
          '';
        };

        apps.sync = {
          type = "app";
          program = "${sync-script}/bin/akeyless-iac-sync";
        };

        apps.default = self.apps.${system}.sync;

        checks = allChecks;

        devShells.default = pkgs.mkShellNoCC {
          packages = [
            pkgs.rsync
          ];
          shellHook = ''
            echo "akeyless-terraform-resources dev shell"
            echo "  nix run .#sync       -- run full iac-forge pipeline"
            echo "  nix flake check      -- verify all 7 backends (content + packaging)"
            echo "  nix build .#verify-all -- single derivation that forces all checks"
          '';
        };
      }
    );
}
