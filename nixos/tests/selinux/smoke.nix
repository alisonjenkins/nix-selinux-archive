# Proves the test harness and that the stock NixOS kernel can activate SELinux
# without a rebuild. No policy is loaded here.
{
  name = "selinux-smoke";

  nodes.machine = {
    security.lsm = [ "selinux" ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("SELinux is among the active security modules"):
        lsm = machine.succeed("cat /sys/kernel/security/lsm").strip()
        print(f"active LSMs: {lsm}")
        assert "selinux" in lsm.split(","), lsm

    with subtest("selinuxfs can be mounted and reports a policy version"):
        machine.succeed("mountpoint -q /sys/fs/selinux || mount -t selinuxfs selinuxfs /sys/fs/selinux")
        version = int(machine.succeed("cat /sys/fs/selinux/policyvers").strip())
        print(f"kernel maximum policy version: {version}")
        assert version >= 33, version

    with subtest("no policy is loaded, so the kernel is not enforcing"):
        assert machine.succeed("cat /sys/fs/selinux/enforce").strip() == "0"
  '';
}
