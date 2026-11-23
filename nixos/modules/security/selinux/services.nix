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
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.confine.sshd || cfg.confine.nscd) -> refpolicy;
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
    };

    security.selinux.entrypoints = lib.mkMerge [
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
