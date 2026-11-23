# A root filesystem that is empty on every boot (tmpfs), with only the
# Nix store kept. Every boot is then a first boot for everything outside
# the store: directories are created and labelled from nothing, while
# the store's labels persist.
let
  ephemeral =
    { lib, ... }:
    {
      imports = [
        ./ext4-nix.nix
      ];

      virtualisation.fileSystems."/" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [
          "mode=0755"
          "size=1G"
        ];
      };

      virtualisation.memorySize = 2048;
    };
in
{
  name = "selinux-ephemeral-root";

  nodes = {
    minimal = {
      imports = [ ephemeral ];
      security.selinux = {
        enable = true;
        mode = "enforcing";
      };
    };

    refpolicy = {
      imports = [ ephemeral ];
      security.selinux = {
        enable = true;
        type = "refpolicy";
        mode = "enforcing";
      };
    };
  };

  testScript = ''
    def check(machine, boot):
        machine.wait_for_unit("multi-user.target")
        assert "tmpfs" in machine.succeed("findmnt -no FSTYPE /")
        assert machine.succeed("getenforce").strip() == "Enforcing"
        pid1 = machine.succeed("cat /proc/1/attr/current").strip("\x00\n ")
        assert pid1 == "system_u:system_r:init_t:s0", pid1
        failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", failed
        print(machine.succeed("ls -Zd / /etc /var /var/lib /var/log /home /root /tmp /run"))
        journal = machine.succeed("journalctl -b --no-pager | grep 'selinux-setup:'")
        print(journal)
        if boot == 1:
            assert "labelled" in journal, journal
        else:
            assert "store labels are up to date" in journal, journal
        # Nothing on the fresh root was left with the type of the
        # filesystem or without a label.
        stray = machine.succeed(
            "getfattr -R -h --absolute-names -n security.selinux /etc /var /root /home 2>/dev/null"
            " | grep -B1 -e ':tmpfs_t:' -e ':unlabeled_t:' -e ':default_t:' || true"
        ).strip()
        assert stray == "", stray
        denials = machine.succeed("journalctl -b --no-pager | grep 'avc:  denied' || true").strip()
        assert denials == "", denials

    for machine in [minimal, refpolicy]:
        machine.start(allow_reboot=True)

    for machine in [minimal, refpolicy]:
        with subtest(f"{machine.name}: boots enforcing on an empty root"):
            check(machine, 1)

        with subtest(f"{machine.name}: boots again with the root emptied and the store labels kept"):
            machine.succeed("touch /var/lib/marker")
            machine.reboot()
            check(machine, 2)
            machine.fail("test -e /var/lib/marker")
  '';
}
