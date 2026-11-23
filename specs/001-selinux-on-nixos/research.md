# Research: SELinux on NixOS

**Date**: 2026-11-21 | **Feature**: [spec.md](./spec.md)

This is the combined summary of four research strands: what nixpkgs and NixOS ship today, earlier attempts and upstream discussion, options for labelling `/nix/store`, and the policy base, build model, boot flow and userspace.

Nothing here has been run. Everything about runtime behaviour is a hypothesis for the prototype to test.

## 1. Where things stand today

Verified against nixpkgs master (commit f657589a, 2026-11-21):

| Area | State |
|---|---|
| SELinux userspace | Packaged and maintained as `selinuxPackages` at 3.11 (libselinux, libsepol, libsemanage, policycoreutils, checkpolicy, setools, selinux-python). No `secilc` package. |
| Policy | `selinux-refpolicy` 2.20250923 is packaged with `DISTRO=nixos`, but no refpolicy module reacts to `distro_nixos`, so the flag does nothing. Only `.pp` modules are built, not a loadable `policy.NN`. |
| Kernel | **Corrected 2026-11-22 from the built config of the default kernel (6.18.64):** `SECURITY_SELINUX=y` is already set, along with `SECURITY_SELINUX_BOOTPARAM`, `SECURITY_SELINUX_DEVELOP`, `AUDIT`, `SECURITY_NETWORK`, `NETLABEL`, `EXT4_FS_SECURITY` and `TMPFS_XATTR`. `common-config.nix` does not mention it because it is picked up from kernel defaults. AppArmor is the default major LSM, and SELinux is inactive only because NixOS's `lsm=` parameter leaves it out. No kernel rebuild is needed. |
| LSM selection | `security.lsm` exists and renders `lsm=...`. It asserts against `security=`. Open issue #510901 says that assertion misfires. |
| NixOS module | None merged. Draft PR #396177 (`nixos/selinux: init`) has been open since April 2025 and is stalled. |
| NixOS tests | None for SELinux. |
| Core userland | SELinux support is off by default in systemd, coreutils, openssh and postgresql (flags exist), hard-disabled in linux-pam (PR #591351 open) and dbus, and absent as an option in sudo, shadow and util-linux. |

## 2. Why earlier attempts stalled

1. **Nix core will not carry labels.** Nix PR #2670 was closed at the Nix team meeting of 2022-12-09 with "approach SELinux through the installer". On nix#5327 store metadata of this kind was rejected, with a pointer to AppArmor. NARs carry no xattrs by design (nix#185). RFC 41 was closed in 2019.
2. **The RFC 41 threat-model objection.** If a label is granted by a path pattern such as `/nix/store/*-nginx-*/bin/nginx`, any user who can ask the daemon to build something can create a matching path and obtain a trusted label.
3. **The nixpkgs review bar.** PR #396168 (global `selinuxSupport` flag) stalled because reviewers (flokli, Ma27, winterqt) will not merge untested global options with no NixOS test, no documentation and no proof that the end-to-end system works.
4. **No working end-to-end demo.** The furthest public result is an April 2025 VM with refpolicy loaded (mode not confirmed). No one has shown an enforcing NixOS boot.

As of November 2026 there are open nixpkgs pull requests for SELinux support in linux-pam and openssh, for the SELinux packages, and for a draft module. Anything published from this work should be demonstrable.

## 3. Key technical findings

- **Nix already leaves the SELinux label alone.** The default `ignored-acls` setting includes `security.selinux`, so canonicalisation does not strip it. Labelling the store from outside Nix is therefore possible with no Nix change. Whether labels survive `--optimise`, `--repair` and re-substitution is untested.
- **The Nix build sandbox is xattr-blind** (Nix 2.35 notes), so builds can neither see nor set labels. Labelling has to be a step outside the build.
- **Hardlinks break path-based labels.** `auto-optimise-store` hardlinks identical files through `/nix/store/.links`, and an inode has exactly one label. This is a live bug for Nix on Fedora (Red Hat Bugzilla 2416675).
- **Nothing fires on substitution.** `post-build-hook` covers local builds only, so a Nix-daemon hook cannot label everything.
- **PID 1's domain comes from the label on the systemd binary itself**, which lives in the store. systemd reads the file's xattr, not `file_contexts`. So policy work cannot be separated from store labelling.
- **systemd's unit access checks use the unit file's label**, and unit files are also in the store.
- **Activation runs before systemd.** NixOS stage 2 runs `activate` and then `exec systemd`. If systemd's built-in loader loads the policy, everything activation created is unlabelled. dracut solves the same problem by running `load_policy -i` before the switch.
- **Policy can be built entirely in a derivation.** `semodule --path --store-path --noreload -B`, monolithic refpolicy, or `secilc` all produce `policy.NN` and `file_contexts` offline. This removes the 40-second boot stall and FHS path problems seen in the 2025 prototype. The kernel's maximum policy version must be matched.
- **SELinux userspace 3.12 (release candidate) adds features aimed at immutable systems**: read-only module store roots, a fallback policy directory, and wildcard path substitutions. nixpkgs is on 3.11.

## 4. Options for labelling the store

| Option | Needs Nix changes | Per-service domains | Main weakness | Upstream chance |
|---|---|---|---|---|
| A. Path-rule `file_contexts`, applied to the system closure at activation or boot | No | Yes | Relabel cost, hardlink collisions, paths outside the closure stay generic | Good (opt-in NixOS module) |
| B. Labels baked into a metadata-only erofs layer overlaid on the store | No | Yes | Unproven overlayfs and SELinux interaction, extra mount layer | Moderate to good |
| C. One mount-wide label plus `SELinuxContext=` on units | No | Only via systemd | No file-type distinctions, weak security story | High, but only as scaffolding |
| D. Labelling inside the Nix daemon | Yes | Yes | Explicitly rejected by Nix maintainers | Low (possibly Lix) |

How comparable systems do it: Guix and the Determinate installer use path rules plus `restorecon` and are fragile. ostree, Android, Bottlerocket and Flatcar label at image build time, and Bottlerocket tests that every shipped path has an intentional label.

## 5. Recommended design

1. **Store labelling: option A, generated from the system closure.** Generic rules give store content broad, unprivileged types (`bin_t`, `lib_t`, `usr_t`, unit files, the `etc` derivation). Privileged entrypoint types are granted only by rules that name the exact store path, hash included, generated from the system configuration. An unprivileged user cannot forge a path with a chosen hash, which answers the RFC 41 objection. Only the system closure is labelled, before the store is remounted read-only, and unchanged paths are skipped.
2. **Policy: refpolicy plus a thin NixOS layer**, built modular in a derivation and delivered in the system closure, so policy switches and rolls back with generations. No mutable policy store at runtime. Booleans are options baked in at build time. The very first bring-up can use a tiny hand-written CIL policy.
3. **Boot: load policy before activation** in stage 2 (and the systemd-initrd equivalent), keeping systemd's loader for reloads. A NixOS relabel unit handles mutable paths, keyed on the policy's store path.
4. **Domains: `SELinuxContext=` from NixOS options first**, exact-path entrypoint labels where a file type is really needed.
5. **Staging**: permissive with a minimal policy, then targeted-style (unconfined by default, selected services confined), then stricter.
6. **Keep Nix core out of the critical path.** Treat option B as the follow-up hardening step and option D as out of scope.

Upstream targets, in order: nixpkgs (small, default-off, tested pieces), refpolicy (`distro_nixos` support), and SELinux userspace only if a gap appears.

## 6. Questions only a prototype can answer

1. Do labels survive `nix-store --optimise`, `--repair`, garbage collection and re-substitution?
2. How long does labelling a real system closure take, and how well does skipping unchanged paths work?
3. How should hardlinked files be handled: disable optimisation on SELinux hosts, or accept collisions between files of identical content?
4. Does `load_policy -i` before activation work in the NixOS VM test framework, and does systemd then enter `init_t`?
5. Does offline `semodule` work in the Nix sandbox with libsemanage 3.11, and how long does a full refpolicy build take?
6. Which refpolicy module set gives a usable targeted-style system?
7. What rules do `nix-daemon`, builders, activation and the setuid wrappers in `/run/wrappers` need?
8. What is the cleanest LSM selection alongside the default AppArmor kernel config?
9. Is a single label for all unit files acceptable for the first enforcing milestone?

## 7. Caveats

- Researchers could not use the GitHub API for the NixOS repositories, so PR and issue discussions were read through search results and page summaries. Comment content is paraphrased, and the contents of PRs #396177, #396168 and #591351 should be read directly before building on them.
- The first version of this summary said the default kernel lacked SELinux. That was inferred from the config source and was wrong. The built `.config` has it enabled (see section 1).
- The SELinux 3.12 features were read from the development branch and are not yet released.
