# Core userland built with SELinux support.
#
# nixpkgs builds these without it by default, so enabling SELinux rebuilds
# them. Only the packages needed to load a policy and inspect labels are
# switched here. Login-related packages (PAM, OpenSSH, D-Bus) follow with the
# enforcing milestone.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.security.selinux;
in
{
  config = lib.mkIf cfg.enable {
    # PID 1 loads the policy, labels /dev and /run, and applies
    # SELinuxContext= only when systemd is built with SELinux support.
    systemd.package = pkgs.systemd.override { withSelinux = true; };

    environment.systemPackages = [
      # `ls -Z`, `id -Z`, `cp --preserve=context` and friends.
      (lib.hiPrio (pkgs.coreutils.override { selinuxSupport = true; }))
      pkgs.libselinux # getenforce, selinuxenabled, getfilecon, ...
      pkgs.policycoreutils # load_policy, setfiles, restorecon, sestatus, ...
    ]
    ++ lib.optionals cfg.developmentTools [
      pkgs.setools
      pkgs.selinux-python # audit2allow, audit2why
      pkgs.checkpolicy
      pkgs.secilc
    ];

    security.auditd.enable = lib.mkIf cfg.developmentTools (lib.mkDefault true);
  };
}
