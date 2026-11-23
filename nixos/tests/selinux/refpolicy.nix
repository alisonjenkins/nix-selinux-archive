# The reference policy with the NixOS module, in enforcing mode: the
# system boots without denials, and logins and Nix builds work.
{ selinuxModule }:
{
  name = "selinux-refpolicy";

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
        mode = "enforcing";
      };

      services.openssh.enable = true;
      virtualisation.memorySize = 2048;
    };

  testScript = ''
    def denials():
        summary = machine.succeed(
            "journalctl -b -k --no-pager -o cat | grep 'avc:  denied'"
            " | sed -E 's/.*denied  (\\{[^}]*\\}).*comm=\"([^\"]*)\".*scontext=([^ ]+) tcontext=([^ ]+) tclass=([^ ]+).*/\\3 \\4 \\5 \\1 \\2/'"
            " | sort | uniq -c | sort -rn | head -150 || true"
        ).strip()
        print(summary)
        return summary

    def label(path):
        return machine.succeed(f"stat -c %C $(readlink -f {path})").strip()

    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")

    with subtest("the reference policy is loaded and enforcing"):
        assert machine.succeed("getenforce").strip() == "Enforcing"
        status = machine.succeed("sestatus")
        print(status)
        assert "refpolicy" in status, status

    with subtest("PID 1 runs in the init domain"):
        pid1 = machine.succeed("cat /proc/1/attr/current").strip("\x00\n ")
        assert pid1 == "system_u:system_r:init_t:s0", pid1
        print(machine.succeed("ps -eZ | awk '{print $1}' | sort | uniq -c | sort -rn"))

    with subtest("store content carries reference policy types"):
        assert label("/run/current-system/systemd/lib/systemd/systemd") == "system_u:object_r:init_exec_t:s0"
        assert label("/run/current-system/sw/bin/ls") == "system_u:object_r:bin_t:s0"
        assert label("/run/current-system/sw/bin/bash") == "system_u:object_r:shell_exec_t:s0"
        assert label("/etc/systemd/system/multi-user.target") == "system_u:object_r:systemd_unit_t:s0"

    with subtest("nothing failed during boot"):
        failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed

    with subtest("SSH login works"):
        machine.wait_for_unit("sshd.service")
        machine.succeed(
            "mkdir -p -m 700 /root/.ssh",
            "ssh-keygen -q -t ed25519 -N ''' -f /root/.ssh/id_ed25519",
            "cp /root/.ssh/id_ed25519.pub /root/.ssh/authorized_keys",
        )
        print(machine.succeed(
            "ssh -o StrictHostKeyChecking=no -o BatchMode=yes root@localhost id -Z"
        ))

    with subtest("the Nix daemon builds a derivation"):
        machine.succeed(
            "nix-build --no-substitute -E '"
            "derivation { name = \"selinux-test\"; system = builtins.currentSystem;"
            " builder = \"/bin/sh\"; args = [ \"-c\" \"echo built > $out\" ]; }'"
            " -o /tmp/result"
        )
        assert machine.succeed("cat /tmp/result").strip() == "built"

    with subtest("nothing was denied"):
        assert denials() == ""

    with subtest("the system reboots cleanly into enforcing mode"):
        machine.reboot()
        machine.wait_for_unit("multi-user.target")
        assert machine.succeed("getenforce").strip() == "Enforcing"
        failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed
        assert denials() == ""
  '';
}
