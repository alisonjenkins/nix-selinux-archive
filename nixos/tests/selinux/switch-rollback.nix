# Switching to a generation with a different policy and rolling back:
# the loaded policy and the labels follow the active generation.
{ selinuxModule }:
{
  name = "selinux-switch-rollback";

  nodes.machine =
    { ... }:
    {
      imports = [
        selinuxModule
        ./ext4-nix.nix
      ];

      security.selinux = {
        enable = true;
        mode = "enforcing";
      };

      # A second generation whose policy adds a type and a labelling rule.
      specialisation.newpolicy.configuration = {
        security.selinux = {
          modules.switchtest.cil = ''
            (type switch_test_file_t)
            (typeattributeset base_type (switch_test_file_t))
          '';
          fileContexts = ''
            /var/lib/switch-test(/.*)?	system_u:object_r:switch_test_file_t:s0
          '';
        };
      };

      virtualisation.memorySize = 2048;
    };

  testScript = ''
    new_type = "system_u:object_r:switch_test_file_t:s0"

    def healthy():
        assert machine.succeed("getenforce").strip() == "Enforcing"
        pid1 = machine.succeed("cat /proc/1/attr/current").strip("\x00\n ")
        assert pid1 == "system_u:system_r:init_t:s0", pid1
        failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed

    def label(path):
        return machine.succeed(f"stat -c %C {path}").strip()

    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")
    base = machine.succeed("readlink -f /run/current-system").strip()
    machine.succeed("mkdir -p /var/lib/switch-test && touch /var/lib/switch-test/file /tmp/probe")

    with subtest("the base generation does not know the new type"):
        healthy()
        machine.fail(f"chcon {new_type} /tmp/probe")
        assert label("/var/lib/switch-test/file") == "system_u:object_r:var_t:s0"

    with subtest("switching loads the new policy and applies its labels"):
        machine.succeed(
            f"{base}/specialisation/newpolicy/bin/switch-to-configuration test >&2"
        )
        healthy()
        machine.succeed(f"chcon {new_type} /tmp/probe")
        assert label("/var/lib/switch-test/file") == new_type
        systemd = label("$(readlink -f /run/current-system/systemd/lib/systemd/systemd)")
        assert systemd == "system_u:object_r:init_exec_t:s0", systemd

    with subtest("rolling back restores the old policy and labels"):
        machine.succeed(f"{base}/bin/switch-to-configuration test >&2")
        healthy()
        machine.fail(f"chcon {new_type} /var/lib/switch-test/file")
        assert label("/var/lib/switch-test/file") == "system_u:object_r:var_t:s0"

    with subtest("nothing was denied along the way"):
        denials = machine.succeed(
            "journalctl -b -k --no-pager | grep 'avc:  denied' || true"
        ).strip()
        assert denials == "", denials

    with subtest("the system reboots cleanly afterwards"):
        machine.reboot()
        machine.wait_for_unit("multi-user.target")
        healthy()
        assert label("/var/lib/switch-test/file") == "system_u:object_r:var_t:s0"
  '';
}
