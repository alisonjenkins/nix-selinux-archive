# Not a pass/fail test of behaviour: measures what labelling costs on a
# closure the size of a desktop installation. Prints the size of the
# store, the time the labelling pass takes on the first boot and on an
# unchanged boot, and what systemd-analyze reports for each.
{
  name = "selinux-measure-desktop";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        ./ext4-nix.nix
      ];

      security.selinux = {
        enable = true;
        type = "refpolicy";
        mode = "enforcing";
      };

      # Large applications, for the size of their closures. They are not
      # started.
      environment.systemPackages = with pkgs; [
        firefox
        thunderbird
        libreoffice
        gimp
        inkscape
        vlc
      ];

      virtualisation = {
        memorySize = 4096;
        cores = 4;
      };
    };

  testScript = ''
    import re

    def setup_pass():
        journal = machine.succeed(
            "journalctl -b -u initrd-selinux-setup.service --no-pager -o short-monotonic"
        )
        print(journal)
        stamps = [float(s) for s in re.findall(r"^\[\s*([0-9.]+)\]", journal, re.M)]
        return journal, (max(stamps) - min(stamps) if stamps else -1.0)

    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")

    paths = int(machine.succeed("ls /nix/store | wc -l"))
    files = int(machine.succeed("find /nix/store -xdev | wc -l"))
    size = machine.succeed("du -sh /nix/store | cut -f1").strip()

    journal, first = setup_pass()
    assert "labelled" in journal, journal
    analyze_first = machine.succeed("systemd-analyze").strip()
    assert machine.succeed("getenforce").strip() == "Enforcing"
    machine.succeed(
        "getfattr -R -h --absolute-names -n security.selinux /nix/store"
        " 2>/dev/null | grep '^security.selinux=' > /tmp/labels"
    )
    print(machine.succeed("sort /tmp/labels | uniq -c | sort -rn | head -40"))
    unlabelled = int(machine.succeed("grep -c -e unlabeled_t -e default_t /tmp/labels || true"))
    assert unlabelled == 0, unlabelled
    conflicts = int(machine.succeed(
        "journalctl -b --no-pager | grep -c 'conflicting specifications' || true"
    ))
    denials = machine.succeed("journalctl -b --no-pager | grep 'avc:  denied' || true")
    print(denials)

    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    journal, second = setup_pass()
    assert "store labels are up to date" in journal, journal
    analyze_second = machine.succeed("systemd-analyze").strip()

    print(f"MEASURE store paths: {paths}")
    print(f"MEASURE store files: {files}")
    print(f"MEASURE store size: {size}")
    print(f"MEASURE hard link pairs with two different rules: {conflicts}")
    print(f"MEASURE first boot labelling pass: {first:.1f} s")
    print(f"MEASURE first boot: {analyze_first}")
    print(f"MEASURE unchanged boot labelling pass: {second:.1f} s")
    print(f"MEASURE unchanged boot: {analyze_second}")
  '';
}
