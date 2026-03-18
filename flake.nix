{
  description = "Akeyless IaC resource specifications and aggregate generated packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";

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

        # Rust verification tool — replaces fragile shell/Python inline checks
        iac-verify = pkgs.rustPlatform.buildRustPackage {
          pname = "iac-verify";
          version = "0.1.0";
          src = ./tools/iac-verify;
          cargoLock.lockFile = ./tools/iac-verify/Cargo.lock;
          meta.description = "Verification tool for IaC-generated artifacts";
        };

        resource-specs = pkgs.runCommand "akeyless-resource-specs" {
          src = self;
        } ''
          mkdir -p $out/share/akeyless-resources
          cp -r $src/resources $out/share/akeyless-resources/
          cp -r $src/data_sources $out/share/akeyless-resources/ 2>/dev/null || true
          cp $src/provider.toml $out/share/akeyless-resources/
        '';

        genPkgs = {
          terraform-provider = terraform-akeyless-gen.packages.${system}.default;
          ansible-collection = ansible-akeyless-gen.packages.${system}.default;
          crossplane-crds = crossplane-akeyless-gen.packages.${system}.default;
          helm-charts = helm-akeyless-gen.packages.${system}.default;
          pulumi-schema = pulumi-akeyless-gen.packages.${system}.default;
          steampipe-plugin = steampipe-akeyless-gen.packages.${system}.default;
        };

        # Verification checks — each runs iac-verify against packaged artifacts
        mkVerifyCheck = name: backend: artifactDir: pkgs.runCommand "verify-${name}" {
          nativeBuildInputs = [ iac-verify ];
        } ''
          iac-verify ${backend} ${artifactDir}
          mkdir -p $out
          iac-verify ${backend} ${artifactDir} > $out/result.txt
        '';

        verifyChecks = {
          verify-terraform = mkVerifyCheck "terraform" "go"
            "${genPkgs.terraform-provider}/share/terraform";
          verify-steampipe = mkVerifyCheck "steampipe" "go"
            "${genPkgs.steampipe-plugin}/share/steampipe";
          verify-helm = mkVerifyCheck "helm" "helm"
            "${genPkgs.helm-charts}/share/helm";
          verify-ansible = mkVerifyCheck "ansible" "ansible"
            "${genPkgs.ansible-collection}/share/ansible/collections/akeyless";
          verify-crossplane = mkVerifyCheck "crossplane" "crossplane"
            "${genPkgs.crossplane-crds}/share/crossplane/crds";
          verify-pulumi = mkVerifyCheck "pulumi" "pulumi"
            "${genPkgs.pulumi-schema}/share/pulumi";
        };

        allChecks = verifyChecks;

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
          inherit resource-specs iac-verify;

          # Single build target for kenshi: forces all 6 backend checks to pass
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
          packages = [ pkgs.rsync iac-verify ];
          shellHook = ''
            echo "akeyless-terraform-resources dev shell"
            echo "  nix run .#sync          -- run full iac-forge pipeline"
            echo "  nix flake check         -- verify all 6 backends via iac-verify"
            echo "  nix build .#verify-all  -- single derivation for kenshi"
            echo "  iac-verify <backend> <dir>  -- verify a single backend"
          '';
        };
      }
    );
}
