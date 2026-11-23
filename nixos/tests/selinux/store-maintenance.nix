# Labels and Nix store maintenance: optimisation (hard links between
# identical files), garbage collection and store verification.
{
  name = "selinux-store-maintenance";

  nodes.machine =
    { ... }:
    {
      imports = [
        ./ext4-nix.nix
      ];

      security.selinux = {
        enable = true;
        type = "minimal";
        mode = "enforcing";
      };

      virtualisation.memorySize = 2048;
    };

  # The same with Nix linking identical files as it adds them.
  nodes.auto =
    { ... }:
    {
      imports = [
        ./ext4-nix.nix
      ];

      security.selinux = {
        enable = true;
        mode = "enforcing";
      };
      nix.settings.auto-optimise-store = true;

      virtualisation.memorySize = 2048;
    };

  testScript = ''
    def label(path):
        return machine.succeed(f"stat -c %C {path}").strip()

    def inode(path):
        return machine.succeed(f"stat -c %i {path}").strip()

    def healthy():
        assert machine.succeed("getenforce").strip() == "Enforcing"
        pid1 = machine.succeed("cat /proc/1/attr/current").strip("\x00\n ")
        assert pid1 == "system_u:system_r:init_t:s0", pid1
        failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed

    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")
    healthy()

    systemd = machine.succeed(
        "readlink -f /run/current-system/systemd/lib/systemd/systemd"
    ).strip()
    assert label(systemd) == "system_u:object_r:init_exec_t:s0"

    with subtest("store verification still passes on a labelled store"):
        # Labels are extended attributes, which are not part of a store
        # path's content hash.
        machine.succeed("nix-store --verify --check-contents >&2")

    with subtest("a copy of systemd in another store path shares its inode after optimisation"):
        machine.succeed(
            "mkdir -p /tmp/forged/lib/systemd",
            f"cp {systemd} /tmp/forged/lib/systemd/systemd",
            "echo marker > /tmp/forged/unique",
        )
        forged = machine.succeed("nix-store --add /tmp/forged").strip()
        copy = f"{forged}/lib/systemd/systemd"
        assert label(copy) != "system_u:object_r:init_exec_t:s0", label(copy)
        machine.succeed("nix-store --optimise >&2")
        assert inode(copy) == inode(systemd), "optimisation did not link the copy"
        # One inode has one label, and Nix may keep either file's inode.
        # If it kept the copy's, the real program has just lost its type.
        print("after optimisation:", label(systemd))

    with subtest("the exact label comes back by itself"):
        # Nobody runs anything: the path unit notices the replaced file.
        machine.wait_until_succeeds(
            f"test $(stat -c %C {systemd}) = system_u:object_r:init_exec_t:s0", timeout=30
        )
        # The copy is byte-for-byte the real program, so sharing its
        # label gives away nothing.
        assert label(copy) == "system_u:object_r:init_exec_t:s0", label(copy)
        machine.wait_until_succeeds("! systemctl is-active -q selinux-store-labels.service")
        healthy()

    with subtest("labelling the copy's store path does not take the label away"):
        machine.reboot()
        machine.wait_for_unit("multi-user.target")
        healthy()
        assert label(systemd) == "system_u:object_r:init_exec_t:s0", label(systemd)
        assert label(f"{forged}/unique") == "system_u:object_r:nix_store_t:s0"

    with subtest("garbage collection leaves the system's labels alone"):
        before = machine.succeed(
            "find -L /run/current-system/sw/bin -maxdepth 1 -type f | sort | xargs stat -L -c '%C %n' | sha256sum"
        )
        machine.succeed("nix-collect-garbage >&2")
        machine.fail(f"test -e {forged}")
        after = machine.succeed(
            "find -L /run/current-system/sw/bin -maxdepth 1 -type f | sort | xargs stat -L -c '%C %n' | sha256sum"
        )
        assert before == after
        assert label(systemd) == "system_u:object_r:init_exec_t:s0", label(systemd)

    with subtest("a path that comes back after collection is labelled again"):
        again = machine.succeed("nix-store --add /tmp/forged").strip()
        assert again == forged
        machine.reboot()
        machine.wait_for_unit("multi-user.target")
        healthy()
        assert label(f"{forged}/unique") == "system_u:object_r:nix_store_t:s0"
        assert label(systemd) == "system_u:object_r:init_exec_t:s0", label(systemd)
        assert machine.succeed("nix-store --verify --check-contents 2>&1 | grep -ci 'modified\\|error' || true").strip() == "0"

    with subtest("linking files as they are added keeps labels right"):
        auto.start(allow_reboot=True)
        auto.wait_for_unit("multi-user.target")
        program = auto.succeed("readlink -f /run/current-system/systemd/lib/systemd/systemd").strip()
        expected = "system_u:object_r:init_exec_t:s0"
        assert auto.succeed(f"stat -c %C {program}").strip() == expected
        # Nix links a new file only to files the optimiser has seen, so
        # optimise once first. That alone may replace the program's inode.
        auto.succeed("nix-store --optimise >&2")
        auto.wait_until_succeeds(f"test $(stat -c %C {program}) = {expected}", timeout=30)
        auto.succeed(
            "mkdir -p /tmp/forged/lib/systemd",
            f"cp {program} /tmp/forged/lib/systemd/systemd",
            "echo marker > /tmp/forged/unique",
        )
        forged = auto.succeed("nix-store --add /tmp/forged").strip()
        assert auto.succeed(f"stat -c %i {forged}/lib/systemd/systemd") == auto.succeed(f"stat -c %i {program}"), "not linked"
        assert auto.succeed(f"stat -c %C {program}").strip() == expected
        auto.reboot()
        auto.wait_for_unit("multi-user.target")
        assert auto.succeed(f"stat -c %C {program}").strip() == expected
        assert auto.succeed("getenforce").strip() == "Enforcing"
        failed = auto.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed
        denied = auto.succeed("journalctl -b --no-pager | grep 'avc:  denied' || true").strip()
        assert denied == "", denied
  '';
}
