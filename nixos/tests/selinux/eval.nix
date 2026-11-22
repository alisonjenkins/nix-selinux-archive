# Checks that need only evaluation, not a VM.
{
  lib,
  runCommand,
  nixosSystem,
  selinuxModule,
  stdenv,
}:
let
  base = {
    nixpkgs.hostPlatform = stdenv.hostPlatform.system;
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
    system.stateVersion = lib.trivial.release;
  };

  eval = modules: nixosSystem { modules = [ base ] ++ modules; };

  toplevel = modules: (eval modules).config.system.build.toplevel.drvPath;

  failedAssertions =
    modules: map (a: a.message) (lib.filter (a: !a.assertion) (eval modules).config.assertions);

  check =
    name: condition: detail:
    runCommand "selinux-eval-${name}" { } (
      if condition then
        "touch $out"
      else
        ''
          echo ${lib.escapeShellArg "${name} failed: ${detail}"} >&2
          exit 1
        ''
    );

  without = toplevel [ ];
  disabled = toplevel [ selinuxModule ];

  bothMessages = failedAssertions [
    selinuxModule
    {
      security.selinux.enable = true;
      security.apparmor.enable = true;
    }
  ];

  storeMessages = failedAssertions [
    selinuxModule
    {
      security.selinux.enable = true;
      security.selinux.relabelPaths = [ "/nix/store" ];
    }
  ];

  enabledMessages = failedAssertions [
    selinuxModule
    { security.selinux.enable = true; }
  ];
in
{
  # FR-002: importing the module without enabling it changes nothing.
  disabled-noop = check "disabled-noop" (
    without == disabled
  ) "system differs: ${without} vs ${disabled}";

  # FR-025: SELinux and AppArmor are mutually exclusive.
  apparmor-exclusive = check "apparmor-exclusive" (lib.any (
    m: lib.hasInfix "security.selinux.enable" m && lib.hasInfix "security.apparmor.enable" m
  ) bothMessages) "no assertion names both options; got: ${toString bothMessages}";

  store-not-relabelled =
    check "store-not-relabelled" (lib.any (lib.hasInfix "relabelPaths") storeMessages)
      "no assertion about relabelPaths; got: ${toString storeMessages}";

  # The stock kernel satisfies the kernel-config assertion.
  enabled-evaluates = check "enabled-evaluates" (
    enabledMessages == [ ]
  ) "unexpected failed assertions: ${toString enabledMessages}";
}
