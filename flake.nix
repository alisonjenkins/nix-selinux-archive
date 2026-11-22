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
    in
    {
      overlays.default = final: _prev: {
        secilc = final.callPackage ./pkgs/secilc { };
      };

      nixosModules = {
        selinux = {
          imports = [ ./nixos/modules/security/selinux ];
          nixpkgs.overlays = [ self.overlays.default ];
        };
        default = self.nixosModules.selinux;
      };

      packages = forAllSystems (system: {
        inherit (pkgsFor system) secilc;
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
            pkgs.callPackage ./nixos/tests/selinux/eval.nix {
              inherit (lib) nixosSystem;
              selinuxModule = self.nixosModules.selinux;
            }
          );
        in
        evalChecks
        // {
          inherit (pkgs) secilc;

          selinux-smoke = pkgs.testers.runNixOSTest ./nixos/tests/selinux/smoke.nix;

          selinux-no-policy = pkgs.testers.runNixOSTest (
            import ./nixos/tests/selinux/no-policy.nix { selinuxModule = self.nixosModules.selinux; }
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
