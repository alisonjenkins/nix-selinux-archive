# Not a pass/fail test of behaviour: measures what labelling costs on a
# closure the size of a desktop installation. Prints the size of the
# store, the time the labelling pass takes on the first boot and on an
# unchanged boot, and what systemd-analyze reports for each.
{ selinuxModule }:
{
  name = "selinux-measure-desktop";

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
    unlabelled = machine.succeed(
        "find /nix/store -xdev -context '*:unlabeled_t:*' | head -5"
    ).strip()
    assert unlabelled == "", unlabelled

    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    journal, second = setup_pass()
    assert "store labels are up to date" in journal, journal
    analyze_second = machine.succeed("systemd-analyze").strip()

    print(f"MEASURE store paths: {paths}")
    print(f"MEASURE store files: {files}")
    print(f"MEASURE store size: {size}")
    print(f"MEASURE first boot labelling pass: {first:.1f} s")
    print(f"MEASURE first boot: {analyze_first}")
    print(f"MEASURE unchanged boot labelling pass: {second:.1f} s")
    print(f"MEASURE unchanged boot: {analyze_second}")
  '';
}
