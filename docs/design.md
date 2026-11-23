# SELinux on NixOS: design

This document describes how the prototype works, why it is built this way, what the tests show, and what is still open. It is written to become the design section of an upstream proposal.

## Summary

- **No change to Nix.** Labels are extended attributes that the NixOS module sets on the store from outside Nix. Nix neither sets nor strips them (`security.selinux` is in its default `ignored-acls`), and they are not part of a store path's content hash.
- **The whole store is labelled with generic, unprivileged types** by path-pattern rules: programs, libraries, data, configuration, unit files.
- **Types that carry privilege are given only to exact store paths.** A rule names the full path including its hash. Whoever builds another package cannot choose its hash, so cannot obtain such a type by imitating a layout.
- **The policy is a derivation in the system closure.** It is loaded in the initrd before NixOS activation, and it switches and rolls back with the system generation.
- **Two policies.** `minimal` is a small policy written for NixOS, used to prove the mechanism. `refpolicy` is the SELinux reference policy with a NixOS module; with it, sshd, nscd, D-Bus and systemd's helper daemons run in the reference policy's own domains.

## Why earlier attempts stalled, and the answer here

| Objection | Answer |
|---|---|
| Nix will not store labels (Nix PR 2670, issue 5327, RFC 41) | Nothing is asked of Nix. Labels are applied by NixOS at boot and at switch. |
| A label granted by a pattern such as `/nix/store/*-nginx-*/bin/nginx` can be forged by any user who can build a path that matches (RFC 41) | Patterns give only generic types. Specific types come from rules with the exact hashed path, generated from the system configuration. Test: `selinux-enforcing`, subtest "a store path imitating systemd gets no privileged label". |
| Untested global options will not be merged (nixpkgs PR 396168) | Everything is behind `security.selinux.enable`, and each claim below is a NixOS VM test. |
| Nobody has shown NixOS booting in enforcing mode | `selinux-enforcing` and `selinux-refpolicy` boot enforcing, log in, build with Nix and reboot, with zero denials. |

## How it works

### Boot

1. The stock NixOS kernel already has SELinux compiled in. The module adds `selinux` to `security.lsm`.
2. In the systemd initrd, a unit ordered after the new root is mounted and before `initrd-nixos-activation.service` chroots into the new root and runs the setup tool from the system closure (`$toplevel/selinux-setup`).
3. The setup tool writes the binary policy to `/sys/fs/selinux/load`, labels the top-level directories, and labels the store (next section). The store is still writable at this point.
4. Activation then runs with a policy loaded, so the files it creates get labels by type transition. When the initrd hands over, the real systemd is executed from a file labelled `init_exec_t` and enters `init_t`.
5. `selinux-relabel.service` runs after local filesystems are mounted and before tmpfiles. It relabels the mutable paths in `security.selinux.relabelPaths`, only when the labelling rules changed since the last pass.

In enforcing mode the initrd unit is required: if the policy cannot be loaded or the store cannot be labelled, the boot stops instead of continuing unprotected.

### Labelling the store

The setup tool lists the top-level store paths and reads a marker attribute, `trusted.nixos-selinux`, from each. The marker records the revision of the rules the path was labelled under. Paths with a current marker are skipped; the rest are labelled with `setfiles` and then marked. Markers are written only after the whole batch is labelled, so an interrupted run repeats.

A path that is garbage collected and later comes back is a new inode without a marker, so it is labelled again without any bookkeeping.

On a later boot with nothing new, the store pass does no writes and finishes in a few seconds.

### Exact rules

Three sources produce exact rules:

- `security.selinux.entrypoints.<name> = { path; type; }` for individual files.
- `security.selinux.fhsLabelledPackages`: for each program in these packages, the policy build asks the reference policy what type it gives the same file under `/usr`, and writes an exact rule when that differs from the generic type. This reuses the reference policy's own file contexts with no table to maintain. systemd and D-Bus are in the list by default; 128 programs get their types this way.
- `security.selinux.confine.<service>`: per-service switches that add the entrypoints a service needs (sshd, nscd, the Nix daemon).

Exact rules are appended to the policy's `file_contexts`, where they take precedence over patterns. A label belongs to a file, not to a name, so a configured path that is a symbolic link is resolved when the policy is built and the rule is written for the file it leads to. The programs of the `nix` package are such links.

### Switch and rollback

The activation script loads the new generation's policy, applies its mode, labels store paths that arrived with the generation, and relabels the mutable paths if the rules changed. Rolling back is the same operation with the old generation. Test: `selinux-switch-rollback`.

### Policy

`security.selinux.type = "refpolicy"` builds the nixpkgs reference policy source as one monolithic binary policy (MCS, systemd support, unknown permissions allowed), with:

- `nixos.te` and `nixos.fc`: the store types, generic labels for store content, and the rules NixOS needs that the reference policy does not have.
- `security.selinux.modules.<name>.te`: the system's own modules, compiled in.
- `security.selinux.booleans`: boolean and tunable values, built in.
- `security.selinux.loginMappings`: the `seusers` file.

There is no mutable policy store at run time. The policy changes only by changing the system configuration.

The rules in `nixos.te` fall into three groups, each commented in the file:

1. **Consequences of the NixOS layout.** Every domain may read the store and follow `/run/current-system`, `/etc` symlinks and Nix profiles. `nosuid_transition` is allowed because the store is mounted nosuid.
2. **Programs that still carry generic types.** Services whose programs are not named by exact path run in `initrc_t`, which is left unconfined. Confinement is opt-in per service.
3. **Gaps between the reference policy and current systemd**, such as memory pressure files and logind's varlink socket. These are candidates for the reference policy itself.

### Nix daemon and builds

The daemon runs in `nix_daemon_t`. This domain is not restricted, because the daemon manages the store as root for every user. It exists so that what the daemon starts can be told apart from what a user starts.

With `security.selinux.confine.nixBuilds` (off by default), every program the daemon starts enters `nix_build_t`. A build may write its outputs, which are new store files with the generic store type, and its build directory (`/nix/var/nix/builds`, type `nix_build_tmp_t`). It may read and run store content, use the sandbox's devices and the network. It may not read the password database, write the Nix database or any other file, or signal or trace other processes. This is a second layer under the isolation Nix already provides, for a build that breaks out of it.

The option is off by default because the transition applies to everything the daemon runs: a `post-build-hook` and the `ssh` client for remote builders would run in the build domain and lack access. Builds without the sandbox are not supported with it.

### Userland

systemd, coreutils, PAM and OpenSSH are rebuilt with SELinux support through their NixOS package options, so nothing else in nixpkgs is rebuilt. Console logins use `pam_selinux`; OpenSSH sets the session context itself.

Setuid wrappers keep a generic type. The program a wrapper executes carries the specific type, for example `unix_chkpwd`.

## Threat model

Protected against:

- **A compromised confined service.** With `refpolicy`, sshd, nscd, D-Bus, journald, udev, logind and the other systemd helpers are limited to what their domains allow. The test checks, for example, that the loaded policy has no rule letting `sshd_t` read the shadow file or load a kernel module.
- **A local user imitating a trusted program** to obtain its type. Only exact paths carry specific types.

Not protected against, by design in this version:

- Services that are not confined. They run in an unconfined domain, as on other distributions with a targeted policy.
- Users with root in an unconfined domain.
- An attacker who can change the system configuration, which decides the policy.

### Store optimisation

`nix-store --optimise` replaces identical files in different store paths with hard links to one inode. One inode has one label.

- If a user adds a byte-for-byte copy of a program that has an exact rule, the copy can end up sharing the program's inode and so its type. This gives nothing away: the copy is the same program.
- The reverse matters. Nix may keep the copy's inode, and the trusted program then carries the copy's generic label. Test `selinux-store-maintenance` reproduces this.

Three measures deal with it:

1. The setup tool checks the files with exact rules on every run and puts their labels back last, whatever the markers say.
2. Scheduled optimisation (`nix.optimise.automatic`) is followed by a run of the setup tool. `nix.settings.auto-optimise-store` produces a warning.
3. Confined services name their domain in the unit (`SELinuxContext=`). The label is then necessary but not sufficient: without it the service fails to start instead of running unconfined.

Open point: whether an unprivileged user can trigger optimisation through the Nix daemon, and so cause a confined service to fail at its next restart. If so, this is a local denial of service until the next boot, switch or optimisation run, and the upstream discussion should cover whether Nix can prefer the existing inode.

## What the tests show

All run as NixOS VM tests (`nix flake check`).

| Test | Shows |
|---|---|
| `selinux-smoke` | The stock kernel activates SELinux with one option. |
| `selinux-permissive-boot` | Policy loaded in the initrd, every file in the system closure labelled, PID 1 in `init_t`, activation-created files labelled, denials logged, second boot relabels nothing. |
| `selinux-enforcing` | Enforcing boot, SSH, a Nix build, a confined demo service denied a file it has no rule for, forged path gets no privileged type, reboot. |
| `selinux-switch-rollback` | Switching to a generation with a different policy and back changes the loaded policy and the labels both ways, with no denials. |
| `selinux-refpolicy` | Reference policy, enforcing, zero denials: sshd, nscd, journald, logind, udev, D-Bus and the Nix daemon in their domains; SSH and console logins land in the mapped user context and are registered with logind; a Nix build runs in the build domain; reboot. |
| `selinux-store-maintenance` | Store verification passes on a labelled store; optimisation and the label; garbage collection; a path that returns is labelled again. |
| `selinux-recovery` | An enforcing configuration boots permissive with `enforcing=0` on the kernel command line, and without SELinux when it is left out of `lsm=`. |
| `selinux-refpolicy-audit` | Development tool: the reference policy test in permissive mode, printing a summary of denials. |

Measured with KVM on a 32-core desktop (`nix build .#selinux-measure-desktop` for the second row):

| Closure | Store paths | Files | First-boot labelling | Unchanged boot |
|---|---|---|---|---|
| Minimal system | about 590 | about 59,000 | about 2 s | no store writes |
| Desktop applications (Firefox, Thunderbird, LibreOffice, GIMP, Inkscape, VLC), 6.7 GB | 1,102 | 121,766 | 6.1 s | 0.5 s |

The first boot of the desktop closure took 17.6 s in total and an unchanged boot 12.5 s. Under software emulation the minimal first-boot pass takes 35 to 45 s.

## Known limits and open questions

- **Not yet tried on a real machine** or on an ephemeral root. The first-boot pass scales with the number of files in the store.
- **A change to a generic rule that can apply to the store relabels the whole store** at the next boot or switch. Rules for paths outside the store do not.
- **Hard links inside one store path** can join two names whose rules give different types, for example a file under `lib/` that is also linked under `share/`. The inode gets one of the two generic types and `setfiles` prints a warning. 72 such pairs appear in a desktop closure; none involves an exact rule.
- **The whole store is labelled, not only the system closure.** This is simpler and covers user profiles, at the cost of a longer first pass.
- **Paths built at run time carry the generic store type** until the next labelling run. Unconfined users can run them; a confined domain cannot.
- **Confined builds are opt-in** and do not yet distinguish builders from hooks and the remote-build `ssh` client. A build may write any store file that still has the generic type, where file permissions allow it.
- **D-Bus is not built with SELinux support**, so it does not mediate messages by context.
- **Password logins over SSH and `sudo` role changes are not tested.**
- **`system.nixos-init.enable` is not supported**: the policy is loaded by a unit ordered before the scripted activation unit in the initrd.
- **Boot-loader rollback** into an older generation is not tested, only `switch-to-configuration`.
- **AppArmor and SELinux are mutually exclusive** in this version.

## Path to upstream

In order, each default-off and with its test:

1. `secilc` package and the smoke test.
2. The module skeleton, the minimal policy, the setup tool and the permissive boot test.
3. Enforcing mode, entrypoints, the confined service example and the forged path test.
4. Switch and rollback.
5. The reference policy type, login contexts, and service confinement.
6. The Nix daemon and build domains.

Policy rules in group 3 above can be offered to the reference policy independently.
