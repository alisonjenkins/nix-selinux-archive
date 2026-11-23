# Puts well-known services into the domains the reference policy has for
# them. The reference policy finds a service's programs by their FHS
# paths, which do not exist on NixOS, so the programs are named here by
# exact store path instead.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.security.selinux;
  refpolicy = cfg.type == "refpolicy";

  # The first word of the unit's ExecStart, without systemd's prefixes.
  dhcpcdProgram =
    let
      unit = config.systemd.services.dhcpcd or null;
      command = unit.serviceConfig.ExecStart or null;
      program = builtins.match "[@!+:-]*(/nix/store/[^ ]+).*" command;
    in
    if unit != null && (unit.enable or true) && lib.isString command && program != null then
      builtins.head program
    else
      null;
in
{
  options.security.selinux.confine = {
    sshd = lib.mkOption {
      type = lib.types.bool;
      default = refpolicy;
      defaultText = lib.literalExpression ''config.security.selinux.type == "refpolicy"'';
      description = "Run the OpenSSH daemon in the policy's `sshd_t` domain.";
    };

    nscd = lib.mkOption {
      type = lib.types.bool;
      default = refpolicy;
      defaultText = lib.literalExpression ''config.security.selinux.type == "refpolicy"'';
      description = ''
        Run the name service cache daemon in the policy's `nscd_t`
        domain. Confined programs resolve users and hosts through it.
      '';
    };

    getty = lib.mkOption {
      type = lib.types.bool;
      default = refpolicy;
      defaultText = lib.literalExpression ''config.security.selinux.type == "refpolicy"'';
      description = ''
        Run the console login prompt in `getty_t` and the login program
        in `local_login_t`. A user's session then starts in the context
        the policy maps the user to.
      '';
    };

    dhcpcd = lib.mkOption {
      type = lib.types.bool;
      default = refpolicy;
      defaultText = lib.literalExpression ''config.security.selinux.type == "refpolicy"'';
      description = "Run the DHCP client in the policy's `dhcpc_t` domain.";
    };

    nix = lib.mkOption {
      type = lib.types.bool;
      default = refpolicy;
      defaultText = lib.literalExpression ''config.security.selinux.type == "refpolicy"'';
      description = ''
        Run the Nix daemon in its own domain, `nix_daemon_t`. The domain
        is not restricted: the daemon manages the store as root. It is
        what {option}`security.selinux.confine.nixBuilds` builds on.
      '';
    };

    nixBuilds = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run the builders the Nix daemon starts in the confined domain
        `nix_build_t`. A build may write only its outputs and its build
        directory, may not read the password database, and may not
        signal or trace other processes, in addition to the isolation
        Nix itself provides.

        Every program the daemon starts enters this domain, including a
        `post-build-hook` and the `ssh` client used for remote builders,
        which then lack access they need. Builds without the sandbox are
        not supported with this option.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.confine.nixBuilds -> cfg.confine.nix;
        message = "security.selinux.confine.nixBuilds needs security.selinux.confine.nix.";
      }
      {
        assertion =
          (cfg.confine.sshd || cfg.confine.nscd || cfg.confine.nix || cfg.confine.getty || cfg.confine.dhcpcd)
          -> refpolicy;
        message = "security.selinux.confine.* needs security.selinux.type = \"refpolicy\".";
      }
    ];

    # Name the domain in the unit as well. The label on the program is
    # then necessary but not sufficient: if it is ever missing, the
    # service fails to start instead of running unconfined.
    systemd.services = {
      sshd = lib.mkIf (cfg.confine.sshd && config.services.openssh.enable) {
        serviceConfig.SELinuxContext = "system_u:system_r:sshd_t:s0";
      };
      nscd = lib.mkIf (cfg.confine.nscd && config.services.nscd.enable) {
        serviceConfig.SELinuxContext = "system_u:system_r:nscd_t:s0";
      };
      nix-daemon = lib.mkIf (cfg.confine.nix && config.nix.enable) {
        serviceConfig.SELinuxContext = "system_u:system_r:nix_daemon_t:s0";
      };
    };

    security.selinux.booleans = lib.mkIf refpolicy {
      nix_confine_builds = cfg.confine.nixBuilds;
    };

    security.selinux.entrypoints = lib.mkMerge [
      (lib.mkIf cfg.confine.getty {
        agetty = {
          path = lib.getExe' pkgs.util-linux "agetty";
          type = "getty_exec_t";
        };
        login = {
          path = config.services.getty.loginProgram;
          type = "login_exec_t";
        };
      })
      # The DHCP client's module builds its own variant of the package
      # and does not expose it, so the program is taken from its unit.
      (lib.mkIf (cfg.confine.dhcpcd && dhcpcdProgram != null) {
        dhcpcd = {
          path = dhcpcdProgram;
          type = "dhcpc_exec_t";
        };
      })
      # The programs of the nix package are links to one file, which this
      # names through the link the daemon's unit starts.
      (lib.mkIf (cfg.confine.nix && config.nix.enable) {
        nix = {
          path = "${config.nix.package}/bin/nix";
          type = "nix_exec_t";
        };
      })
      (lib.mkIf (cfg.confine.sshd && config.services.openssh.enable) (
        lib.genAttrs' [ "bin/sshd" "libexec/sshd-session" "libexec/sshd-auth" ] (
          file:
          lib.nameValuePair "openssh-${baseNameOf file}" {
            path = "${config.services.openssh.package}/${file}";
            type = "sshd_exec_t";
          }
        )
      ))
      # The password checking helper. Confined programs such as sshd may
      # not read the shadow file themselves; they run this helper, which
      # enters its own domain. It is reached through a setuid wrapper,
      # which keeps a generic type and only executes this file.
      (lib.mkIf refpolicy {
        pam-unix-chkpwd = {
          path = "${config.security.pam.package}/bin/unix_chkpwd";
          type = "chkpwd_exec_t";
        };
      })
      (lib.mkIf (cfg.confine.nscd && config.services.nscd.enable) {
        nscd = {
          path =
            if config.services.nscd.enableNsncd then
              "${pkgs.nsncd}/bin/nsncd"
            else
              "${config.services.nscd.package}/bin/nscd";
          type = "nscd_exec_t";
        };
      })
    ];
  };
}
