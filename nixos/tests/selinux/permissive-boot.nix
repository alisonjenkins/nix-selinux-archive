# Milestone 1: boot in permissive mode with a policy loaded, the store
# labelled, systemd in its own domain and denials logged.
{
  name = "selinux-permissive-boot";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        ./ext4-nix.nix
      ];

      security.selinux = {
        enable = true;
        type = "minimal";

        # A type no domain is allowed to touch, to provoke a denial.
        modules.test.cil = ''
          (type test_secret_t)
          (roletype object_r test_secret_t)
        '';
      };

      environment.systemPackages = [ pkgs.attr ];
      virtualisation.memorySize = 2048;
    };

  testScript = ''
    import shlex

    def context(path: str) -> str:
        return machine.succeed(
            f"getfattr -h --absolute-names --only-values -n security.selinux {shlex.quote(path)}"
        ).strip("\x00\n ")

    def setype(path: str) -> str:
        return context(path).split(":")[2]

    # Reboots keep the same qemu process, and with it the disk contents.
    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")

    with subtest("SELinux is permissive with the configured policy loaded"):
        assert machine.succeed("getenforce").strip() == "Permissive"
        status = machine.succeed("sestatus")
        print(status)
        assert "minimal" in status, status
        machine.succeed("selinuxenabled")

    with subtest("the policy was loaded and the root labelled in the initrd"):
        journal = machine.succeed("journalctl -b -u initrd-selinux-setup.service --no-pager")
        print(journal)
        assert "loaded policy" in journal, journal
        assert "labelled" in journal, journal

    with subtest("PID 1 runs in the init domain"):
        pid1 = machine.succeed("cat /proc/1/attr/current").strip("\x00\n ")
        assert pid1 == "system_u:system_r:init_t:s0", pid1

    with subtest("processes started by systemd leave the init domain"):
        me = machine.succeed("id -Z").strip()
        assert me == "system_u:system_r:unconfined_t:s0", me

    with subtest("no file in the system closure is unlabelled"):
        machine.succeed(
            "nix-store -qR /run/current-system > /tmp/closure",
            "xargs -a /tmp/closure getfattr -R -h --absolute-names -n security.selinux"
            " 2>/dev/null | grep '^security.selinux=' > /tmp/labels",
        )
        total = int(machine.succeed("wc -l < /tmp/labels"))
        unlabelled = int(machine.succeed("grep -c unlabeled_t /tmp/labels || true"))
        print(machine.succeed("sort /tmp/labels | uniq -c | sort -rn"))
        print(f"{total} files in the closure, {unlabelled} unlabelled")
        assert total > 10000, total
        assert unlabelled == 0, unlabelled

    with subtest("store content carries the intended types"):
        systemd = machine.succeed("readlink -f /run/current-system/systemd").strip()
        for path, expected in [
            (f"{systemd}/lib/systemd/systemd", "init_exec_t"),
            (machine.succeed("readlink -f /run/current-system/sw/bin/ls").strip(), "bin_t"),
            (machine.succeed("readlink -f /etc/systemd/system").strip(), "systemd_unit_t"),
            (machine.succeed("readlink -f /etc/os-release").strip(), "etc_t"),
            (machine.succeed("readlink -f /etc/static").strip(), "etc_t"),
        ]:
            actual = setype(path)
            assert actual == expected, f"{path}: {actual}, expected {expected}"

    with subtest("files created by activation and at boot are labelled"):
        for path, expected in [
            ("/", "root_t"),
            ("/etc", "etc_t"),
            ("/etc/passwd", "etc_t"),
            ("/etc/static", "etc_t"),
            ("/var", "var_t"),
            ("/var/lib", "var_t"),
            ("/nix/var", "nix_var_t"),
            ("/run", "var_run_t"),
            ("/run/current-system", "var_run_t"),
            ("/dev/null", "device_t"),
        ]:
            actual = setype(path)
            assert actual == expected, f"{path}: {actual}, expected {expected}"

    with subtest("an action the policy forbids succeeds and is logged"):
        machine.succeed(
            "echo hello > /root/secret",
            "chcon system_u:object_r:test_secret_t:s0 /root/secret",
        )
        assert setype("/root/secret") == "test_secret_t"
        assert machine.succeed("cat /root/secret").strip() == "hello"
        denials = machine.succeed("journalctl -b -k --no-pager | grep 'avc:  denied' | grep test_secret_t")
        print(denials)
        assert "permissive=1" in denials, denials

    with subtest("nothing failed during boot"):
        failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed

    with subtest("labels persist across a reboot and are not redone"):
        machine.reboot()
        machine.wait_for_unit("multi-user.target")
        journal = machine.succeed("journalctl -b -u initrd-selinux-setup.service --no-pager")
        print(journal)
        assert "store labels are up to date" in journal, journal
        pid1 = machine.succeed("cat /proc/1/attr/current").strip("\x00\n ")
        assert pid1 == "system_u:system_r:init_t:s0", pid1
  '';
}
