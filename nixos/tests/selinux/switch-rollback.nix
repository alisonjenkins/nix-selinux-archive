# Switching to a generation with a different policy and rolling back:
# the loaded policy and the labels follow the active generation.
{
  name = "selinux-switch-rollback";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        ./ext4-nix.nix
      ];

      security.selinux = {
        enable = true;
        type = "minimal";
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

      # A third generation whose policy claims a format version no kernel
      # accepts.
      specialisation.badpolicy.configuration = {
        security.selinux.policy =
          let
            good = pkgs.selinux-policy-minimal;
          in
          pkgs.runCommand "selinux-policy-unloadable"
            {
              passthru = { inherit (good) policyVersion; };
            }
            ''
              cp -r ${good} $out
              chmod -R u+w $out
              printf '\x63\x00\x00\x00' \
                | dd of=$out/policy/policy.${toString good.policyVersion} bs=1 seek=16 conv=notrunc
            '';
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
        output = machine.succeed(
            f"{base}/specialisation/newpolicy/bin/switch-to-configuration test 2>&1"
        )
        print(output)
        healthy()
        # The new rule is for a path outside the store, so the store is
        # not labelled again: only the few paths with exact rules are.
        assert "relabelling" in output, output
        import re
        relabelled = re.search(r"labelling (\d+) store paths", output)
        assert relabelled is None or int(relabelled.group(1)) < 20, output
        machine.succeed(f"chcon {new_type} /tmp/probe")
        assert label("/var/lib/switch-test/file") == new_type
        systemd = label("$(readlink -f /run/current-system/systemd/lib/systemd/systemd)")
        assert systemd == "system_u:object_r:init_exec_t:s0", systemd

    with subtest("rolling back restores the old policy and labels"):
        machine.succeed(f"{base}/bin/switch-to-configuration test >&2")
        healthy()
        machine.fail(f"chcon {new_type} /var/lib/switch-test/file")
        assert label("/var/lib/switch-test/file") == "system_u:object_r:var_t:s0"

    with subtest("a policy the kernel cannot load is refused before the switch"):
        status, output = machine.execute(
            f"{base}/specialisation/badpolicy/bin/switch-to-configuration test 2>&1"
        )
        print(output)
        assert status != 0, output
        assert "format version 99" in output, output
        assert "Pre-switch check 'selinux' failed" in output, output
        healthy()
        assert machine.succeed("readlink -f /run/current-system").strip() == base
        # The running policy is still the base one.
        machine.fail(f"chcon {new_type} /tmp/probe")

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
