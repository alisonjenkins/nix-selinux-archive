# nix-selinux

A prototype of SELinux support for NixOS, developed with the aim of contributing it to nixpkgs.

**Status**: prototype, proven in VM tests only. A NixOS system boots enforcing with the SELinux reference policy, a labelled store, working logins, Nix builds, switch and rollback. A handful of system services are confined; everything else is unconfined until you confine it. It has not been tried on a real machine.

## Using it

```nix
{
  inputs.nix-selinux.url = "github:alisonjenkins/nix-selinux";
  # in your system's modules:
  #   nix-selinux.nixosModules.selinux
  #   { security.selinux.enable = true; }
}
```

Reboot, then run `nixos-selinux status`. The system starts permissive (logging only).

**If an enforcing system will not boot:** in the boot loader, pick the previous generation, or add `enforcing=0` to the kernel command line.

The [manual chapter](nixos/modules/security/selinux/selinux.md) is short and covers the rest: confining a service, reading denials, recovery.

## Approach

- No changes to Nix. The NixOS module labels the store from outside Nix.
- Privileged labels go only to exact store paths named by the system configuration.
- Policy is built in a derivation and switches and rolls back with system generations.
- Every milestone is proven by a NixOS VM test.

## Layout

| Path | Contents |
|---|---|
| `specs/001-selinux-on-nixos/` | Specification, research summary, plan and task list |
| `docs/design.md` | How it works, threat model, test results, open questions |
| `nixos/modules/security/selinux/selinux.md` | The manual chapter: how to enable and use it, and how to recover |
| `docs/research/` | Detailed research reports with sources |
| `nixos/modules/security/selinux/` | The NixOS module, with the setup tool (`setup/`) and the reference policy build (`refpolicy/`) |
| `nixos/tests/selinux/` | NixOS VM tests |
| `pkgs/by-name/` | Packages not yet in nixpkgs: `secilc` and the minimal policy |

The `nixos/` and `pkgs/` trees have the paths and the contents they would have in nixpkgs, so they can be copied into a nixpkgs checkout unchanged. `flake.nix` supplies what nixpkgs would: the two packages as an overlay, and the module added to every test node.

## Running the checks

```sh
nix flake check
```

VM tests use KVM when it is available. On a machine without KVM, Nix refuses to build them unless told the feature exists, and QEMU then falls back to software emulation (the smoke test takes about two and a half minutes that way):

```sh
nix flake check --option system-features "kvm nixos-test benchmark big-parallel uid-range"
```

## Licence

MIT, the same as nixpkgs. The built reference policy is a derived work of the SELinux reference policy, which is GPL-2.0.
