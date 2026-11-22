# The module enabled before any policy exists: the system must still boot,
# with SELinux active, SELinux-aware userland, and nothing enforced.
{ selinuxModule }:
{
  name = "selinux-no-policy";

  nodes.machine = {
    imports = [ selinuxModule ];
    security.selinux.enable = true;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("SELinux is active but no policy is loaded"):
        assert "selinux" in machine.succeed("cat /sys/kernel/security/lsm").strip().split(",")
        machine.succeed("test -e /sys/fs/selinux/policyvers")
        assert machine.succeed("cat /sys/fs/selinux/enforce").strip() == "0"

    with subtest("systemd is built with SELinux support"):
        assert "+SELINUX" in machine.succeed("systemctl --version")

    with subtest("the configuration file is in place"):
        config = machine.succeed("cat /etc/selinux/config")
        assert "SELINUX=permissive" in config, config
        assert "SELINUXTYPE=minimal" in config, config

    with subtest("coreutils understands security contexts"):
        machine.succeed("ls -Zd /")
        print(machine.succeed("id -Z || true"))

    with subtest("nothing failed during boot"):
        failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed
  '';
}
