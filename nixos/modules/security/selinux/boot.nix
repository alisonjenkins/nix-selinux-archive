# Loads the policy and labels the filesystem early in boot, and keeps the
# store labelled when the system is switched.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.security.selinux;

  setupTool = pkgs.callPackage ../../../../pkgs/nixos-selinux-setup { };

  policyFile = "${cfg.policy}/policy/policy.${toString cfg.policy.policyVersion}";

  # The setup tool with this system's policy and rules filled in.
  setup = pkgs.writeShellScript "selinux-setup" ''
    exec ${lib.getExe setupTool} \
      --policy ${policyFile} \
      --spec ${cfg.policy}/contexts/files/file_contexts \
      --rev ${cfg.labelRevision} \
      ${
        lib.concatMapStringsSep " " (e: "--exact ${lib.escapeShellArg (toString e.path)}") (
          lib.attrValues cfg.entrypoints
        )
      } \
      ${lib.concatMapStringsSep " " (p: "--relabel ${lib.escapeShellArg p}") cfg.relabelPaths}
  '';
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.system.nixos-init.enable;
        message = ''
          security.selinux.enable does not support system.nixos-init.enable
          yet: the policy is loaded by a unit that runs before the NixOS
          activation unit in the initrd.
        '';
      }
    ];

    # Found by the initrd through the system closure it is about to boot.
    system.systemBuilderCommands = ''
      ln -s ${setup} $out/selinux-setup
    '';

    # Before activation, with the store still writable: load the policy and
    # label the new root. Activation then creates correctly labelled files,
    # and the real systemd enters its domain when the initrd hands over.
    boot.initrd.systemd.services.initrd-selinux-setup = {
      description = "Load SELinux Policy and Label the New Root";
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = [ "/sysroot/nix/store" ];
      };
      after = [
        "initrd-find-nixos-closure.service"
        "initrd-fs.target"
      ];
      before = [ "initrd-nixos-activation.service" ];
      # Permissive systems still boot if this fails. Enforcing ones must not.
      ${if cfg.mode == "enforcing" then "requiredBy" else "wantedBy"} = [
        "initrd-nixos-activation.service"
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -uo pipefail
        export PATH="/bin:${config.boot.initrd.systemd.package.util-linux}/bin"

        closure=$(readlink /nixos-closure)
        if [ ! -e "/sysroot$closure/selinux-setup" ] && [ ! -L "/sysroot$closure/selinux-setup" ]; then
          echo "$closure has no SELinux setup - skipping"
          exit 0
        fi

        if [ ! -d /sys/fs/selinux ]; then
          echo "SELinux is not active in this kernel - skipping"
          exit 0
        fi
        mountpoint -q /sys/fs/selinux || mount -t selinuxfs selinuxfs /sys/fs/selinux

        # The setup tool lives in the new root and needs these there. They
        # are unmounted again because stage 2 mounts its own.
        mkdir -p /sysroot/proc /sysroot/sys /sysroot/dev
        mount -t proc proc /sysroot/proc
        mount --rbind /sys /sysroot/sys
        mount --rbind /dev /sysroot/dev
        cleanup() {
          umount -R /sysroot/dev /sysroot/sys /sysroot/proc
        }
        trap cleanup EXIT

        chroot /sysroot "$closure/selinux-setup"
      '';
    };

    # On switch: label store paths that arrived with the new generation and
    # load its policy, before any of its services start.
    system.activationScripts.selinux = {
      deps = [ "etc" ];
      text = ''
        if [ "''${IN_NIXOS_SYSTEMD_STAGE1:-}" != true ] && [ -e /sys/fs/selinux/load ]; then
          ${setup}
          if [ "$(tr -d '\0' < /proc/self/attr/current)" != kernel ]; then
            ${lib.getExe' pkgs.policycoreutils "load_policy"}
          fi
        fi
      '';
    };
  };
}
