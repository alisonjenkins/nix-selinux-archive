# nix-selinux

A prototype of SELinux support for NixOS, developed with the aim of contributing it to nixpkgs.

**Status**: early setup. Nothing here is ready to use on a real machine.

## Approach

- No changes to Nix. The NixOS module labels the running system's closure from outside Nix.
- Privileged labels go only to exact store paths named by the system configuration.
- Policy is built in a derivation and switches and rolls back with system generations.
- Every milestone is proven by a NixOS VM test.

## Layout

| Path | Contents |
|---|---|
| `specs/001-selinux-on-nixos/` | Specification, research summary, plan and task list |
| `docs/research/` | Detailed research reports with sources |
| `nixos/modules/security/selinux/` | The NixOS module (mirrors the nixpkgs path) |
| `nixos/tests/selinux/` | NixOS VM tests |
| `pkgs/` | Packages not yet in nixpkgs |

## Running the checks

```sh
nix flake check
```

VM tests use KVM when it is available. On a machine without KVM, Nix refuses to build them unless told the feature exists, and QEMU then falls back to software emulation (the smoke test takes about two and a half minutes that way):

```sh
nix flake check --option system-features "kvm nixos-test benchmark big-parallel uid-range"
```
