# The reference policy with the NixOS module, in permissive mode. This
# test records how far the policy is from fitting NixOS: it asserts the
# basics and prints the denials for the rest.
{ selinuxModule }:
{
  name = "selinux-refpolicy-permissive";

  nodes.machine =
    { ... }:
    {
      imports = [
        selinuxModule
        ./ext4-nix.nix
      ];

      security.selinux = {
        enable = true;
        type = "refpolicy";
      };

      services.openssh.enable = true;
      virtualisation.memorySize = 2048;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("the reference policy is loaded in permissive mode"):
        assert machine.succeed("getenforce").strip() == "Permissive"
        status = machine.succeed("sestatus")
        print(status)
        assert "refpolicy" in status, status

    with subtest("PID 1 runs in the init domain"):
        pid1 = machine.succeed("cat /proc/1/attr/current").strip("\x00\n ")
        assert pid1 == "system_u:system_r:init_t:s0", pid1

    with subtest("store content carries reference policy types"):
        def label(path):
            return machine.succeed(f"stat -c %C $(readlink -f {path})").strip()

        assert label("/run/current-system/systemd/lib/systemd/systemd") == "system_u:object_r:init_exec_t:s0"
        assert label("/run/current-system/sw/bin/ls") == "system_u:object_r:bin_t:s0"
        assert label("/run/current-system/sw/bin/bash") == "system_u:object_r:shell_exec_t:s0"

    with subtest("nothing failed during boot"):
        failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed

    # Not asserted yet: the work list for fitting the policy to NixOS.
    print(machine.succeed("ps -eZ | awk '{print $1}' | sort | uniq -c | sort -rn"))
    print(machine.succeed(
        "journalctl -b -k --no-pager -o cat | grep 'avc:  denied'"
        " | sed -E 's/.*denied  (\\{[^}]*\\}).*scontext=([^ ]+) tcontext=([^ ]+) tclass=([^ ]+).*/\\2 \\3 \\4 \\1/'"
        " | sort | uniq -c | sort -rn | head -150 || true"
    ))
    print(machine.succeed("journalctl -b -k --no-pager | grep -c 'avc:  denied' || true"))
  '';
}
