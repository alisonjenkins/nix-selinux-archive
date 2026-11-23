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
