# Implementation Plan: SELinux support for NixOS

**Branch**: `001-selinux-on-nixos` | **Date**: 2026-11-21 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/001-selinux-on-nixos/spec.md`

## Summary

Make NixOS boot and run with SELinux, first permissive and then enforcing, without changing Nix. A NixOS module builds the policy in a derivation, loads it before system activation, and labels the running system's closure from outside Nix. Privileged labels are granted only to exact store paths named by the configuration. The work is prototyped in a standalone flake whose layout mirrors nixpkgs, proven with NixOS VM tests, and then split into small default-off changes for upstream.

Design rationale and sources are in [research.md](./research.md). The option interface is in [contracts/nixos-options.md](./contracts/nixos-options.md).

## Technical Context

**Language/Version**: Nix (module system, derivations), Bash for boot and labelling scripts, SELinux CIL for the minimal policy, refpolicy M4 (`.te`, `.fc`, `.if`) for the NixOS policy layer, Python for NixOS VM test scripts.
**Primary Dependencies**: nixpkgs unstable pinned by flake lock; `selinuxPackages` 3.11 (libselinux, libsepol, libsemanage, policycoreutils, checkpolicy); `selinux-refpolicy` 2.20250923; systemd built with `withSelinux = true`; the default NixOS kernel, which already has `SECURITY_SELINUX`.
**Storage**: Labels are `security.selinux` extended attributes on store files. Labelling progress is a small state file under `/var/lib/selinux-nixos/`. Policy lives in the system closure and is exposed at `/etc/selinux`.
**Testing**: NixOS VM tests (`pkgs.testers.runNixOSTest`), run through `nix flake check`. Build-time policy checks with `secilc` and `checkpolicy`.
**Target Platform**: NixOS on x86_64-linux first, aarch64-linux second. Filesystems with extended attribute support (ext4, xfs, btrfs).
**Project Type**: Operating system module set with packages and VM tests, in a flake.
**Performance Goals**: No more than 30 seconds added to first boot and 5 seconds to later unchanged boots for a typical server closure (SC-005).
**Constraints**: Unmodified Nix (FR-008). Zero change when disabled (FR-002). Policy fully built at build time (FR-004). SELinux and AppArmor mutually exclusive in version 1 (FR-025). No upstream contact until Alison decides.
**Scale/Scope**: System closures of roughly 100,000 to 300,000 files. First milestone confines nothing. Enforcing milestone covers boot, login, SSH, switch and Nix daemon use on a minimal server.

## Constitution Check

No project constitution exists yet. Until one is written, the plan holds itself to these gates, taken from the spec and from what upstream reviewers asked for:

| Gate | How the plan meets it |
|---|---|
| Off by default, no effect when disabled | Everything sits behind `security.selinux.enable`. A test compares a disabled system's closure against a baseline. |
| Test before claim | Every milestone has a VM test that fails before the work and passes after. |
| No Nix changes | Labelling runs from NixOS units and scripts. |
| Upstream shaped | Files mirror nixpkgs paths so each piece can move across unchanged. |
| Honest limits | Threat model and known gaps are documented alongside the code. |

## Project Structure

### Documentation (this feature)

```text
specs/001-selinux-on-nixos/
├── spec.md
├── research.md
├── plan.md
├── tasks.md
└── contracts/
    └── nixos-options.md
```

### Source Code (prototype repository root)

```text
flake.nix
nixos/
├── modules/security/selinux/
│   ├── default.nix          # options, assertions, kernel and LSM selection
│   ├── policy.nix           # composes policy fragments, exposes /etc/selinux
│   ├── boot.nix             # early policy load, mutable-path relabel unit
│   ├── labelling.nix        # closure labelling at boot and at switch
│   └── userland.nix         # SELinux-enabled systemd, coreutils, pam, openssh, dbus
└── tests/selinux/
    ├── disabled-noop.nix
    ├── permissive-boot.nix
    ├── closure-labels.nix
    ├── forged-path.nix
    ├── enforcing-boot.nix
    ├── switch-rollback.nix
    └── confined-service.nix
pkgs/
├── secilc/                  # not yet in nixpkgs
├── selinux-policy-minimal/  # CIL policy built with secilc (milestone 1)
├── selinux-policy-nixos/    # refpolicy plus NixOS layer, built offline (milestone 2)
├── nixos-store-file-contexts/   # generates generic and exact-path labelling rules
└── nixos-selinux-label/     # labels a list of store paths, skips labelled ones
policy/
├── minimal/*.cil
└── nixos/nixos.{te,fc,if}
docs/
├── design.md                # design write-up and threat model (FR-023)
└── manual.md                # user documentation, later a NixOS manual chapter
```

**Structure Decision**: One flake. Paths under `nixos/` and `pkgs/` match where the files would live in nixpkgs, so upstreaming is a copy plus registration. The project files folder holds the specs until the repository exists, then they move into it.

## Key design decisions

1. **Kernel.** The default NixOS kernel already has SELinux built in (checked against the built config on 2026-11-22). It is inactive only because `lsm=` leaves it out, so the module just adds `selinux` to `security.lsm`. No kernel rebuild and no kernel change upstream are needed. The module asserts that the configured kernel has `SECURITY_SELINUX`, for users with custom kernels.
2. **LSM selection.** `security.lsm` gains `selinux`. An assertion rejects configurations that also enable AppArmor.
3. **Policy build.** Milestone 1 uses a small CIL policy compiled by `secilc`. Milestone 2 switches to refpolicy with a NixOS layer, assembled offline. Both produce the same `/etc/selinux/<type>/` layout, with the policy version matched to the kernel.
4. **Policy load.** The policy is loaded before activation. On systems using the systemd initrd, an initrd unit loads it from the new root before the activation unit runs. This needs no nixpkgs patch and is the prototype's first route. Scripted stage 2 has no hook before activation, so supporting it needs a small change to `stage-2-init.sh`, carried as a patch until upstreamed. Both routes are unverified until the first test runs.
5. **Store labelling.** A build-time derivation turns the system closure into a path list and a `file_contexts` file: generic rules for broad unprivileged types, plus exact-path rules for the systemd binary, unit files, the `etc` tree and designated service entry points. At boot the labeller runs before the store becomes read-only. At switch it runs in a private mount namespace with the store remounted writable, before the new generation's services start. Paths already labelled under the same rules are skipped.
6. **Everything else in the store** gets a default unprivileged store type through the generic rule or the filesystem default.
7. **Domains.** Services get their domain from `SELinuxContext=`, set by NixOS options. Exact-path entry point labels are used only where a file type is required, starting with systemd itself.
8. **Store optimisation.** Version 1 documents that `nix.settings.auto-optimise-store` should be off and warns when it is on. Measuring the real impact of shared files is a milestone 1 task.

## Milestones

| Milestone | Delivers | Spec stories | Exit test |
|---|---|---|---|
| M0 Setup | Repository, flake, pinned nixpkgs, `secilc`, test harness | none | `nix flake check` runs the smoke VM test |
| M1 Permissive boot | Module, minimal policy, early load, closure labelling, denials logged | US1 | `permissive-boot`, `closure-labels`, `disabled-noop` pass |
| M2 Enforcing minimal system | refpolicy with NixOS layer, logins, SSH, switch, Nix daemon | US2, US4 | `enforcing-boot`, `switch-rollback` pass with no unexpected denials |
| M3 Declarative confinement | Per-service policy fragments, tunables as options, forged-path proof | US3 | `confined-service`, `forged-path` pass |
| M4 Hardening and measurement | Timing, large closures, ephemeral root, interrupted labelling, store maintenance | edge cases | Measured against SC-005, results in `docs/design.md` |
| M5 Upstream package | Design write-up, threat model, manual chapter, patch series | US5 | Each patch builds and tests alone on upstream's branch |

Detailed tasks for M0 and M1 are in [tasks.md](./tasks.md). M2 onward are listed there as outline phases and get detailed tasks when M1 has answered the open questions.

## Risks

| Risk | Effect | Response |
|---|---|---|
| systemd does not enter its intended domain because the store binary is unlabelled at exec time | No useful policy enforcement | Label the systemd path in the initrd before switch-root. This is the first thing M1 proves. |
| Labels lost on store optimisation, repair or re-substitution | Unlabelled system files | Test each operation in M1. Relabel on switch and at boot. |
| VM tests are slow without KVM | Slow iteration where KVM is unavailable | Keep tests small and split. Run them on a machine with KVM where possible. |
| Offline refpolicy assembly fails in the sandbox with userspace 3.11 | M2 blocked | Fall back to monolithic refpolicy, which needs no module store. |
| refpolicy too noisy on a non-FHS system | Long path to zero denials | Unconfined by default, confine incrementally, add path aliases for NixOS locations. |
| Upstream reviewers reject SELinux on principle | US5 stalls | Lead with tests, a threat model and zero cost when disabled. Keep the flake usable on its own. |

## Complexity Tracking

| Deviation | Why needed | Simpler alternative rejected because |
|---|---|---|
| Two policy bases (CIL, then refpolicy) | A tiny readable policy isolates boot and labelling problems from policy problems | Starting on refpolicy mixes hundreds of modules into the first debugging session |
| Carried patch for scripted stage 2 | No pre-activation hook exists there | Supporting only the systemd initrd would exclude many current systems |
