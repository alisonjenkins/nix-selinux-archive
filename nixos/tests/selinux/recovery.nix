# The two ways out of an enforcing system that does not work, as they
# would be typed into a boot loader entry: boot permissive once with
# `enforcing=0`, or boot without SELinux by leaving it out of `lsm=`.
let
  enforcingSystem = {
    imports = [
      ./ext4-nix.nix
    ];

    security.selinux = {
      enable = true;
      mode = "enforcing";
    };
  };
in
{
  name = "selinux-recovery";

  nodes = {
    permissive =
      { lib, ... }:
      {
        imports = [ enforcingSystem ];
        # After the parameters the configuration renders, as an addition
        # typed at the boot loader would be.
        boot.kernelParams = lib.mkAfter [ "enforcing=0" ];
      };

    disabled =
      { lib, ... }:
      {
        imports = [ enforcingSystem ];
        # The kernel uses the last `lsm=` it is given.
        boot.kernelParams = lib.mkAfter [ "lsm=landlock,yama,bpf" ];
      };
  };

  testScript = ''
    start_all()

    with subtest("enforcing=0 boots the enforcing configuration in permissive mode"):
        permissive.wait_for_unit("multi-user.target")
        assert "enforcing=0" in permissive.succeed("cat /proc/cmdline")
        assert permissive.succeed("getenforce").strip() == "Permissive"
        # The policy is loaded and labels are in place, so denials are
        # logged and the system can be repaired and switched.
        pid1 = permissive.succeed("cat /proc/1/attr/current").strip("\x00\n ")
        assert pid1 == "system_u:system_r:init_t:s0", pid1
        failed = permissive.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed

    with subtest("without selinux in lsm= the system boots with SELinux off"):
        disabled.wait_for_unit("multi-user.target")
        assert not disabled.succeed("cat /sys/kernel/security/lsm").count("selinux")
        disabled.fail("test -e /sys/fs/selinux/load")
        failed = disabled.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed
        print(disabled.succeed("journalctl -b --no-pager | grep -i selinux || true"))
        # Files made now have no labels, so the next boot with SELinux
        # must relabel: the record of the last relabelling is removed.
        disabled.succeed(
            "mkdir -p /var/lib/selinux-nixos && touch /var/lib/selinux-nixos/relabelled",
            "systemctl restart selinux-relabel-after-disabled.service",
        )
        disabled.fail("test -e /var/lib/selinux-nixos/relabelled")
  '';
}
