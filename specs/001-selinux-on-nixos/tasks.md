# Tasks: SELinux support for NixOS

**Input**: Design documents from `specs/001-selinux-on-nixos/`
**Prerequisites**: plan.md, spec.md, research.md, contracts/nixos-options.md

**Tests**: Included. The spec requires VM tests for every milestone (FR-021), and each test is written to fail before its implementation.

**Format**: `[ID] [P?] [Story] Description`. `[P]` means it can run in parallel with its neighbours. Paths are relative to the prototype repository root.

## Phase 1: Setup (M0)

- [x] T001 Create the repository skeleton from plan.md and move `specs/` into it
- [x] T002 Write `flake.nix` with pinned nixpkgs unstable, `nixosModules.selinux`, `packages`, and `checks` wired to `nixos/tests/selinux/`
- [x] T003 [P] Add formatting and lint checks (`nixfmt`, `statix`) to `flake.nix` checks; `shellcheck` joins when the first shell script lands
- [x] T004 [P] Build the default NixOS kernel's config file and record its SELinux-related settings in research.md. Result: SELinux is already built in
- [x] T005 ~~Define and build an SELinux-enabled kernel~~ Not needed, see T004. Replaced by a kernel-config assertion in T008
- [x] T006 [P] Package `secilc` in `pkgs/secilc/default.nix` from the SELinux userspace source already used by nixpkgs
- [x] T007 Add VM test `nixos/tests/selinux/smoke.nix` that boots the stock kernel with `selinux` in `security.lsm` and checks SELinux is active with no policy loaded, to prove the harness

**Checkpoint**: `nix flake check` passes.

## Phase 2: Foundational (blocks all stories)

- [x] T008 Write option declarations and assertions in `nixos/modules/security/selinux/default.nix` per contracts/nixos-options.md, including the AppArmor exclusion and a check that the kernel has `SECURITY_SELINUX`
- [x] T009 [P] Write `nixos/tests/selinux/disabled-noop.nix`: a system with the module imported but disabled has the same closure as one without it
- [x] T010 [P] Write an evaluation test that enabling SELinux and AppArmor together fails with the expected message
- [x] T011 Add `selinux` to `security.lsm` and the needed kernel parameters in `default.nix`, and check how the open `security=` assertion issue (#510901) affects it
- [x] T012 Write `nixos/modules/security/selinux/userland.nix`: systemd with `withSelinux`, coreutils with `selinuxSupport`, tools in `environment.systemPackages`
- [x] T013 Confirm the system builds with those overrides and record the rebuild cost of SELinux-enabled systemd

**Checkpoint**: A system with the option enabled builds. It does not yet load a policy.

## Phase 3: User Story 1 - Boot NixOS with SELinux observing (Priority: P1) 🎯 MVP (M1)

**Goal**: Boot permissive with a policy loaded, every closure file labelled, denials logged.

**Independent Test**: `nix build .#checks.x86_64-linux.selinux-permissive-boot .#checks.x86_64-linux.selinux-closure-labels`

### Tests for User Story 1 (write first, confirm they fail)

- [x] T014 [P] [US1] `nixos/tests/selinux/permissive-boot.nix`: `selinuxenabled` succeeds, `getenforce` is Permissive, loaded policy name and version match the configuration
- [x] T015 [P] [US1] In the same test: PID 1 runs in the init domain, not the kernel's initial context
- [x] T016 [P] [US1] `nixos/tests/selinux/closure-labels.nix`: walk every file in the system closure and fail on any unlabelled or default-labelled file; assert the systemd binary, a unit file, a closure executable and a file reached through `/etc` carry their intended types (done inside `permissive-boot.nix`)
- [x] T017 [P] [US1] In `permissive-boot.nix`: trigger an action the policy does not allow, assert it succeeds and a denial record appears in the journal
- [x] T018 [P] [US1] In `closure-labels.nix`: files created by activation under `/etc`, `/var` and `/run` carry intended labels (done inside `permissive-boot.nix`)

### Implementation for User Story 1

- [x] T019 [US1] Write the minimal CIL policy in `policy/minimal/` : initial contexts, kernel, init, unconfined, store data and executable types, etc, runtime and temporary types, and a broad allow for the unconfined domain
- [x] T020 [US1] Build it in `pkgs/selinux-policy-minimal/default.nix` with `secilc`, emitting `policy.NN` and `file_contexts` in the `/etc/selinux/<type>/` layout, with the version taken from the kernel
- [x] T021 [US1] Write `nixos/modules/security/selinux/policy.nix`: `/etc/selinux/config`, the policy tree under `environment.etc`, and helper paths pointing into the store
- [x] T022 [US1] Write `pkgs/nixos-store-file-contexts/default.nix`: from the system closure, generate generic rules and exact-path rules for systemd, unit files and the `etc` tree (done differently: generic rules live in `policy/minimal/file_contexts`, exact rules come from `security.selinux.entrypoints` in `policy.nix`)
- [x] T023 [US1] Write `pkgs/nixos-selinux-label/`: label a given list of store paths with `setfiles`, skip paths recorded as labelled under the same rule set, record progress atomically so an interrupted run resumes safely (done as `pkgs/nixos-selinux-setup`, which labels the whole store and marks each path with a `trusted.nixos-selinux` attribute)
- [x] T024 [US1] Write `nixos/modules/security/selinux/boot.nix` for the systemd initrd: a unit that loads the policy from the new root and labels the closure before the activation unit and before the store is made read-only
- [x] T025 [US1] Verify systemd in the real root detects the loaded policy and transitions to the init domain; fix labels or policy until T015 passes
- [x] T026 [US1] Add the mutable-path relabel unit to `boot.nix`, keyed on the policy's store path, covering `security.selinux.relabelPaths`
- [x] T027 ~~Scripted stage 2 route~~ Not needed: nixpkgs has removed the scripted initrd, so the systemd initrd is the only boot route
- [x] T028 [US1] Add `security.selinux.developmentTools` (analysis tools, audit daemon) to `default.nix`

### Measurements and open questions for User Story 1

- [x] T029 [P] [US1] Measure labelling time and boot time added, first boot and unchanged boot, for the minimal closure and a larger server closure; record against SC-005 in `docs/design.md`
- [x] T030 [P] [US1] Test whether labels survive `nix-store --optimise`, `nix-store --verify --repair`, and garbage collection followed by re-substitution; record results
- [x] T031 [P] [US1] Test what a shared (hardlinked) file's label is when two paths map to different types, and decide the version 1 rule for store optimisation
- [x] T032 [US1] Write the M1 section of `docs/design.md`: what works, measured numbers, answers to research.md questions 1 to 4, and what remains unknown

**Checkpoint**: User Story 1 is demonstrable on its own. Review before starting M2.

## Phase 4: User Story 2 - Enforcing minimal system (Priority: P2) (M2, outline)

- [x] T033 [US2] Tests first: `enforcing-boot.nix` covering boot, console login, SSH login, a configuration switch, a package build, reboot, with an allow-list of expected denials that must end empty (done as `enforcing.nix`, `refpolicy.nix` and `switch-rollback.nix`)
- [x] T034 [US2] Build refpolicy offline in `pkgs/selinux-policy-nixos/` (modular assembly, monolithic as fallback) with an unconfined-by-default module set (done as `pkgs/selinux-policy-refpolicy`: monolithic build of the nixpkgs refpolicy source, selected with `security.selinux.type = "refpolicy"`)
- [x] T035 [US2] Write the NixOS policy layer in `policy/nixos/`: store types, Nix daemon, activation, wrappers directory, path aliases for NixOS locations (started: `nixos.te` and `nixos.fc` give store types and generic labels, and `refpolicy.nix` boots enforcing with no denials; services all run in the unconfined `initrc_t`, there is no Nix daemon domain, and `security.selinux.modules` is not supported with refpolicy yet) Nix daemon domain `nix_daemon_t` and opt-in build domain `nix_build_t` added (`confine.nix`, `confine.nixBuilds`).
- [x] T036 [US2] Enable SELinux in PAM, OpenSSH and D-Bus in `userland.nix`; add login mappings and PAM session entries (for the refpolicy type; D-Bus through `security.selinux.dbusMediation`)
- [x] T037 [US2] Label at switch: run the labeller in a private mount namespace before the new generation's services start, and load the new policy
- [x] T038 [US2] Refuse a switch whose policy fails to load in enforcing mode (`system.preSwitchChecks.selinux` compares the policy format version with the kernel; a rejected load skips labelling and fails the activation)
- [x] T039 [US2] Label and allow the privileged wrappers in `/run/wrappers` (labelled by `restorecon` after the wrappers service; wrappers keep a generic type and their targets get exact-path types, for example `unix_chkpwd`)
- [x] T040 [US2] Document recovery when an enforcing system fails to boot (`docs/manual.md`)

## Phase 5: User Story 4 - Roll back and upgrade safely (Priority: P3) (M2, outline)

- [x] T041 [US4] `switch-rollback.nix`: two generations with different policies, switch forward, roll back, reboot into each, assert the active policy and sampled labels each time; include rollback to a generation without SELinux (done as `switch-rollback.nix` using a specialisation and `switch-to-configuration test`; booting into each generation through the boot loader is not covered yet)
- [x] T042 [US4] Fix whatever that test exposes in labelling state and policy reload

## Phase 6: User Story 3 - Confine a service declaratively (Priority: P3) (M3, outline)

- [x] T043 [US3] Tests first: `confined-service.nix` (service runs in its domain, forbidden access denied and logged) and `forged-path.nix` (an imitating package built by an unprivileged user gets no privileged label) (done inside `enforcing.nix` and `refpolicy.nix`)
- [x] T044 [US3] Implement `security.selinux.modules`, `entrypoints` and `booleans`, with build failures that name the offending fragment (`modules.<name>.cil` for minimal, `modules.<name>.te` for refpolicy)
- [x] T045 [US3] Confine one network service end to end as the worked example (sshd runs in `sshd_t` with refpolicy, with nscd and the password helper in their domains; see `services.nix` and `refpolicy.nix`)

## Phase 7: Hardening (M4, outline)

- [x] T046 Ephemeral root filesystems, large closures, interrupted labelling, store maintenance during use: one test or documented limit for each edge case in the spec (`ephemeral-root.nix`, `measure.nix`, `store-maintenance.nix`; interrupted labelling repeats because markers are written last)
- [x] T047 Tune labelling until SC-005 is met (known cost: any change to file context rules, even one outside the store, relabels the whole store at switch; the revision should cover store rules only)

## Phase 8: User Story 5 - Upstream package (Priority: P2) (M5, outline)

- [x] T048 [US5] Finish `docs/design.md` with the threat model and the answers to each recorded objection
- [x] T049 [US5] Write the user manual chapter in `docs/manual.md` (`docs/manual.md`)
- [x] T050 [US5] Split the work into an ordered patch series against nixpkgs, each default-off with its test, starting with the smallest (kernel support and `secilc`) (`upstream/make-series.py`; four commits, checked against the locked nixpkgs revision)
- [ ] T051 [US5] Have someone uninvolved reproduce M1 and M2 from the documentation (SC-008)
- [ ] T052 [US5] With the maintainer's go-ahead, open the upstream discussion and the first pull request

## Dependencies & Execution Order

- Phase 1 then Phase 2 block everything.
- User Story 1 (Phase 3) blocks User Stories 2, 3 and 4.
- User Story 4 depends on the switch labelling from User Story 2.
- User Story 5 starts in parallel as documentation from M1 onward, and its final tasks wait for M3.
- Within User Story 1: T014 to T018 first; T019 to T021 before T024; T022 and T023 before T024; T025 after T024; T029 to T031 after T025.

## Implementation Strategy

Stop after Phase 3 and validate. A permissive boot with a fully labelled closure and systemd in its intended domain is already more than any public NixOS result, and it answers the questions that decide how M2 is built. T052 is the only task that reaches outside the project and needs explicit approval.
