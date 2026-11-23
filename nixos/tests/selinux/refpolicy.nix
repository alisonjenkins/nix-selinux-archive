# The reference policy with the NixOS module: the system boots without
# denials, and logins and Nix builds work.
#
# With `enforcing = false` the same script runs in permissive mode and
# only prints the denials. That variant is a development tool: it shows
# everything a policy change breaks in one run.
{
  selinuxModule,
  enforcing ? true,
}:
{
  name = if enforcing then "selinux-refpolicy" else "selinux-refpolicy-audit";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        selinuxModule
        ./ext4-nix.nix
      ];

      security.selinux = {
        enable = true;
        type = "refpolicy";
        mode = if enforcing then "enforcing" else "permissive";
        logAllDenials = !enforcing;
        confine.nixBuilds = true;
      };

      services.openssh.enable = true;
      environment.systemPackages = [ pkgs.setools ];
      users.users.alice = {
        isNormalUser = true;
        password = "foobar";
      };
      virtualisation.memorySize = 2048;
    };

  testScript = ''
    strict = ${if enforcing then "True" else "False"}

    def denials():
        summary = machine.succeed(
            "journalctl -b --no-pager -o cat | grep 'avc:  denied'"
            " | sed -E 's/.*denied  (\\{[^}]*\\}).*comm=\"([^\"]*)\".*scontext=([^ ]+) tcontext=([^ ]+) tclass=([^ ]+).*/\\3 \\4 \\5 \\1 \\2/'"
            " | sort | uniq -c | sort -rn | head -150 || true"
        ).strip()
        print(summary)
        return summary if strict else ""

    def label(path):
        return machine.succeed(f"stat -c %C $(readlink -f {path})").strip()

    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")

    with subtest("the reference policy is loaded and enforcing"):
        assert machine.succeed("getenforce").strip() == ("Enforcing" if strict else "Permissive")
        status = machine.succeed("sestatus")
        print(status)
        assert "refpolicy" in status, status

    with subtest("PID 1 runs in the init domain"):
        pid1 = machine.succeed("cat /proc/1/attr/current").strip("\x00\n ")
        assert pid1 == "system_u:system_r:init_t:s0", pid1
        print(machine.succeed("ps -eo label,comm | sort | uniq -c | sort -rn"))

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
        daemon = machine.succeed("ps -o label= -p $(systemctl show -P MainPID sshd.service)").strip()
        assert daemon == "system_u:system_r:sshd_t:s0", daemon
        session = machine.succeed(
            "ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes root@localhost id -Z"
        ).strip()
        assert session == "unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023", session

    with subtest("console login starts in the mapped context"):
        # In permissive mode the kernel prints every denial on the console,
        # which scrolls the login prompt away.
        if strict:
            machine.wait_until_tty_matches("1", "login: ")
            machine.send_chars("alice\n")
            machine.wait_until_tty_matches("1", "Password: ")
            machine.send_chars("foobar\n")
            machine.wait_until_succeeds("pgrep -u alice bash")
            machine.send_chars("id -Z > /tmp/console-context\n")
            machine.wait_for_file("/tmp/console-context")
            console = machine.succeed("cat /tmp/console-context").strip()
            assert console == "unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023", console

    with subtest("confined services run in their domains"):
        def domain(unit):
            return machine.succeed(
                f"ps -o label= -p $(systemctl show -P MainPID {unit})"
            ).strip().split(":")[2]

        for unit, expected in {
            "nscd.service": "nscd_t",
            "systemd-journald.service": "syslogd_t",
            "systemd-logind.service": "systemd_logind_t",
            "systemd-udevd.service": "udev_t",
            "dbus.service": "system_dbusd_t",
        }.items():
            assert domain(unit) == expected, (unit, domain(unit))
        # What confinement buys: unlike an unconfined service, sshd may
        # not read the shadow file or load a kernel module.
        for rule in [
            "-s sshd_t -t shadow_t -c file -p read",
            "-s sshd_t -c system -p module_load",
            "-s nscd_t -t shadow_t -c file -p read",
        ]:
            # Rules under a boolean that is off are listed with ":False".
            found = machine.succeed(f"sesearch -A {rule} | grep -v ':False$' || true").strip()
            assert found == "", found
        assert machine.succeed("sesearch -A -s initrc_t -t shadow_t -c file -p read").strip() != ""

    with subtest("the Nix daemon runs in its domain and builds in the build domain"):
        machine.succeed("systemctl start nix-daemon.service")
        assert domain("nix-daemon.service") == "nix_daemon_t"
        # The builder reports its own context. Through the daemon, as
        # every user's builds go.
        machine.succeed(
            "NIX_REMOTE=daemon nix-build --no-substitute -E '"
            "derivation { name = \"selinux-test\"; system = builtins.currentSystem;"
            " builder = \"/bin/sh\"; args = [ \"-c\""
            " \"read -r context < /proc/self/attr/current; echo $context > $out\" ]; }'"
            " -o /tmp/result"
        )
        context = machine.succeed("tr -d '\\000' < /tmp/result").strip()
        print(context)
        if strict:
            assert context == "system_u:system_r:nix_build_t:s0", context
        # A build cannot read the password database, write the Nix
        # database or act on other processes.
        for query in [
            "-t shadow_t -c file -p read",
            "-t nix_var_t -c file -p write",
            "-t etc_t -c file -p write",
            "-t init_t -c process -p signal",
            "-t unconfined_t -c process -p ptrace",
        ]:
            rules = machine.succeed(f"sesearch -A -s nix_build_t {query} | grep -v ':False$' || true")
            assert "allow" not in rules, rules

    with subtest("nothing was denied"):
        assert denials() == ""

    with subtest("the system reboots cleanly into enforcing mode"):
        machine.reboot()
        machine.wait_for_unit("multi-user.target")
        assert machine.succeed("getenforce").strip() == ("Enforcing" if strict else "Permissive")
        failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed
        assert denials() == ""
  '';
}
