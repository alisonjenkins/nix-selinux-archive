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

  # Identifies the exact-path rules, so the store paths they apply to are
  # relabelled when those rules change and not otherwise.
  exactRevision = builtins.substring 0 32 (
    builtins.hashString "sha256" (
      lib.concatMapStrings (e: "${toString e.path}=${e.type}\n") (lib.attrValues cfg.entrypoints)
      # Rules the policy derives itself change only when the policy does.
      + builtins.unsafeDiscardStringContext (toString cfg.policy)
    )
  );

  policyFile = "${cfg.policy}/policy/policy.${toString cfg.policy.policyVersion}";

  # The setup tool with this system's policy and rules filled in.
  setup = pkgs.writeShellScript "selinux-setup" ''
    exec ${lib.getExe setupTool} \
      --policy ${policyFile} \
      --spec ${cfg.policy}/contexts/files/file_contexts \
      --rev ${cfg.labelRevision} \
      --exact-rev ${exactRevision} \
      --exact-file ${cfg.policy}/nixos/exact-paths \
      ${lib.concatMapStringsSep " " (p: "--relabel ${lib.escapeShellArg p}") cfg.relabelPaths} \
      "$@"
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
        # are fresh mounts, not binds of the initrd's own: unmounting a bind
        # of /sys would propagate back and take the initrd's cgroup mounts
        # with it. They are removed again because stage 2 mounts its own.
        mkdir -p /sysroot/proc /sysroot/sys /sysroot/dev
        mount -t proc proc /sysroot/proc
        mount -t sysfs sysfs /sysroot/sys
        mount -t selinuxfs selinuxfs /sysroot/sys/fs/selinux
        mount -t devtmpfs devtmpfs /sysroot/dev
        cleanup() {
          umount /sysroot/dev /sysroot/sys/fs/selinux /sysroot/sys /sysroot/proc
        }
        trap cleanup EXIT

        chroot /sysroot "$closure/selinux-setup"
      '';
    };

    # After activation: restore labels on the mutable paths if the rules
    # changed. On first boot this covers what activation just created.
    systemd.services = {
      selinux-relabel = {
        description = "Restore SELinux Labels on Mutable Paths";
        unitConfig = {
          DefaultDependencies = false;
          ConditionSecurity = "selinux";
        };
        wantedBy = [ "sysinit.target" ];
        after = [ "local-fs.target" ];
        before = [
          "sysinit.target"
          "shutdown.target"
          # These create and adjust files under the paths being relabelled.
          "systemd-tmpfiles-setup.service"
          "systemd-journal-flush.service"
        ];
        conflicts = [ "shutdown.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${setup} --relabel-mutable";
        };
      };

      # Store optimisation replaces identical files with hard links to one
      # inode, and may keep the inode of an unlabelled copy. Put exact
      # labels back as soon as the scheduled optimisation finishes.
      nix-optimise = lib.mkIf config.nix.optimise.automatic {
        serviceConfig.ExecStartPost = [ "${setup}" ];
      };

      # The setuid wrappers are created at boot on their own tmpfs, where
      # new files get the filesystem's default type. Give them their
      # proper labels as soon as they exist.
      suid-sgid-wrappers.serviceConfig.ExecStartPost = [
        "-${lib.getExe' pkgs.policycoreutils "restorecon"} -RF ${dirOf config.security.wrapperDir}"
      ];
    };

    warnings = lib.optional (config.nix.settings.auto-optimise-store or false) ''
      security.selinux: nix.settings.auto-optimise-store links identical
      files as they are added to the store. A file that carries a specific
      SELinux type can lose it that way until the next boot or switch.
      Prefer nix.optimise.automatic, after which labels are restored.
    '';

    # On switch: load the new generation's policy, apply its mode, and label
    # store paths that arrived with it, before any of its services start.
    system.activationScripts.selinux = {
      deps = [ "etc" ];
      text = ''
        if [ "''${IN_NIXOS_SYSTEMD_STAGE1:-}" != true ] && [ -e /sys/fs/selinux/load ]; then
          # Load the new policy first: labels that use its new types are
          # only valid once the kernel knows them.
          if [ "$(tr -d '\0' < /proc/self/attr/current)" != kernel ]; then
            ${lib.getExe' pkgs.policycoreutils "load_policy"}
            echo ${if cfg.mode == "enforcing" then "1" else "0"} > /sys/fs/selinux/enforce
          fi
          ${setup} --relabel-mutable
        fi
      '';
    };
  };
}
