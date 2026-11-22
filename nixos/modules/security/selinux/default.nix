{
  config,
  lib,
  ...
}:
let
  cfg = config.security.selinux;
  inherit (config.boot.kernelPackages) kernel;
in
{
  imports = [
    ./userland.nix
  ];

  options.security.selinux = {
    enable = lib.mkEnableOption "SELinux, a mandatory access control system";

    mode = lib.mkOption {
      type = lib.types.enum [
        "permissive"
        "enforcing"
      ];
      default = "permissive";
      description = ''
        Enforcement mode at boot. In permissive mode, actions the policy
        does not allow still succeed and are logged.
      '';
    };

    type = lib.mkOption {
      type = lib.types.str;
      default = "minimal";
      description = ''
        Name of the policy, written to {file}`/etc/selinux/config` as
        `SELINUXTYPE` and used as the directory name under
        {file}`/etc/selinux`.
      '';
    };

    policyVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        Kernel policy format version to build the policy for. When null,
        the highest version the policy tools support is used, which must
        not be newer than what the running kernel accepts.
      '';
    };

    relabelPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [
        "/etc"
        "/var"
        "/root"
        "/home"
      ];
      description = ''
        Mutable paths whose labels are restored when the policy changes.
        The Nix store is labelled separately and must not be listed here.
      '';
    };

    developmentTools = lib.mkEnableOption "tools for analysing denials and writing policy";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.security.apparmor.enable;
        message = ''
          security.selinux.enable and security.apparmor.enable cannot both
          be set. Running both security modules together is not supported.
        '';
      }
      {
        # `kernel.config` holds only the options nixpkgs sets explicitly. The
        # stock kernel gets SELinux from the kernel's own defaults, so only an
        # explicit opt-out can be detected here.
        assertion =
          !(kernel ? config)
          || !(kernel.config.isSet "SECURITY_SELINUX")
          || kernel.config.isYes "SECURITY_SELINUX";
        message = ''
          security.selinux.enable requires a kernel built with
          CONFIG_SECURITY_SELINUX=y, but ${kernel.name or "the configured kernel"}
          sets it to something else.
        '';
      }
      {
        assertion = !(lib.any (lib.hasPrefix "/nix/store") cfg.relabelPaths);
        message = ''
          security.selinux.relabelPaths must not contain the Nix store,
          which is labelled separately.
        '';
      }
    ];

    # The stock kernel has SELinux built in. It is inactive only because it
    # is absent from the `lsm=` parameter that this option renders.
    security.lsm = [ "selinux" ];

    environment.etc."selinux/config".text = ''
      SELINUX=${cfg.mode}
      SELINUXTYPE=${cfg.type}
    '';
  };
}
