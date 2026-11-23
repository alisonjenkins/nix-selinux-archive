{
  description = "SELinux support for NixOS (prototype)";

  # The channel tarball is used in place of `github:NixOS/nixpkgs/nixos-unstable`
  # because it needs no GitHub API access to lock or fetch.
  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };

      # A VM test written as it would be in nixpkgs, where the module is
      # part of NixOS. Here it is added to every node. The package set of
      # the test already has the overlay.
      selinuxTest =
        pkgs: test:
        pkgs.testers.runNixOSTest {
          imports = [ test ];
          defaults.imports = [ ./nixos/modules/security/selinux ];
        };
    in
    {
      overlays.default = final: _prev: {
        secilc = final.callPackage ./pkgs/by-name/se/secilc/package.nix { };
        selinux-policy-minimal = final.callPackage ./pkgs/by-name/se/selinux-policy-minimal/package.nix { };
      };

      # The module as it would sit in nixpkgs, plus the two packages it
      # expects to find there.
      nixosModules = {
        selinux = {
          imports = [ ./nixos/modules/security/selinux ];
          nixpkgs.overlays = [ self.overlays.default ];
        };
        default = self.nixosModules.selinux;
      };

      packages = forAllSystems (system: {
        inherit (pkgsFor system) secilc selinux-policy-minimal;

        # Measures the cost of labelling a desktop-sized closure. Large,
        # so it is not among the checks.
        selinux-measure-desktop = selinuxTest (pkgsFor system) ./nixos/tests/selinux/measure.nix;
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          nixFiles = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ./.;
          };
          evalChecks = lib.mapAttrs' (name: lib.nameValuePair "selinux-eval-${name}") (
            # callPackage adds override functions, which are not checks.
            lib.filterAttrs (_: lib.isDerivation) (
              pkgs.callPackage ./nixos/tests/selinux/eval.nix {
                inherit (lib) nixosSystem;
                selinuxModule = self.nixosModules.selinux;
              }
            )
          );
        in
        evalChecks
        // {
          inherit (pkgs) secilc selinux-policy-minimal;
          nixos-selinux-setup = pkgs.callPackage ./nixos/modules/security/selinux/setup { };

          selinux-smoke = pkgs.testers.runNixOSTest ./nixos/tests/selinux/smoke.nix;

          selinux-permissive-boot = selinuxTest pkgs ./nixos/tests/selinux/permissive-boot.nix;

          selinux-enforcing = selinuxTest pkgs ./nixos/tests/selinux/enforcing.nix;

          selinux-switch-rollback = selinuxTest pkgs ./nixos/tests/selinux/switch-rollback.nix;

          selinux-recovery = selinuxTest pkgs ./nixos/tests/selinux/recovery.nix;

          selinux-ephemeral-root = selinuxTest pkgs ./nixos/tests/selinux/ephemeral-root.nix;

          selinux-refpolicy = selinuxTest pkgs (import ./nixos/tests/selinux/refpolicy.nix { });

          selinux-store-maintenance = selinuxTest pkgs ./nixos/tests/selinux/store-maintenance.nix;

          # Not a pass/fail test of the policy: prints what it denies.
          selinux-refpolicy-audit = selinuxTest pkgs (
            import ./nixos/tests/selinux/refpolicy.nix { enforcing = false; }
          );

          formatting = pkgs.runCommand "check-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            find ${nixFiles} -name '*.nix' -print0 | xargs -0 nixfmt --check
            touch $out
          '';

          statix = pkgs.runCommand "check-statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
            statix check ${nixFiles}
            touch $out
          '';
        }
      );
    };
}
