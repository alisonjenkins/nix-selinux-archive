# Feature Specification: SELinux support for NixOS

**Feature Branch**: `001-selinux-on-nixos`
**Created**: 2026-11-21
**Status**: Draft
**Input**: User description: "Research how we can make SELinux work on NixOS. I want upstream support for everyone, so I can secure my servers and computers properly with SELinux, in a form suitable for upstream submission. Test on VMs created by Nix. Prototype on our own, then submit our research upstream."

**Supporting research**: [research.md](./research.md)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Boot NixOS with SELinux observing (Priority: P1)

A NixOS administrator turns on one option in their system configuration, rebuilds, and reboots into a system where SELinux is active in permissive mode with a policy loaded. Processes and files carry meaningful labels, and would-be denials are logged so the administrator can see what the policy would block. Nothing that worked before stops working.

**Why this priority**: Every later milestone depends on a system that boots with a policy loaded and labels in place. It is also the smallest result that is demonstrably new, since no public NixOS setup shows correct labels on store content.

**Independent Test**: A Nix-built VM test boots a configuration with the option enabled and asserts that SELinux reports permissive mode with the expected policy, that the init process and a sample of system files carry the intended labels, and that denials appear in the log.

**Acceptance Scenarios**:

1. **Given** a NixOS configuration with SELinux enabled in permissive mode, **When** the machine boots, **Then** the SELinux status reports enabled, permissive, and the configured policy.
2. **Given** that booted machine, **When** the administrator inspects the init process, a system service, an executable in the system closure, a unit file and a file under `/etc`, **Then** each carries the label the policy intends and none is unlabelled.
3. **Given** that booted machine, **When** a process performs an action the policy does not allow, **Then** the action succeeds and a denial record is written to the system log.
4. **Given** a NixOS configuration that does not enable SELinux, **When** it is built, **Then** the resulting system is identical to one built before this feature existed.

---

### User Story 2 - Run a minimal system in enforcing mode (Priority: P2)

An administrator switches the same configuration to enforcing mode. The machine boots, accepts console and SSH logins, and can rebuild and switch to a new configuration, with unconfined-by-default behaviour for anything that has no dedicated policy.

**Why this priority**: Enforcing mode is the point at which SELinux provides protection. Showing that ordinary NixOS operations survive it is the evidence upstream reviewers have asked for.

**Independent Test**: A VM test boots in enforcing mode, logs in on the console and over SSH, runs a configuration switch that changes a service, builds a package through the Nix daemon, reboots, and asserts no unexpected denials throughout.

**Acceptance Scenarios**:

1. **Given** an enforcing configuration, **When** the machine boots, **Then** it reaches the normal multi-user state with SELinux reporting enforcing.
2. **Given** that machine, **When** a user logs in on the console or over SSH, **Then** the session starts in the context the configuration assigns to that user.
3. **Given** that machine, **When** the administrator switches to a new configuration, **Then** the switch completes, new system content is labelled before it is used, and the new policy is active.
4. **Given** that machine, **When** a user builds or installs a package through the Nix daemon, **Then** the operation succeeds.
5. **Given** an enforcing machine whose new configuration contains a policy that fails to load, **When** the administrator switches, **Then** the switch is refused before services are changed and the running system stays on the old policy.

---

### User Story 3 - Confine a service declaratively (Priority: P3)

An administrator, or the author of a NixOS service module, declares that a service runs in its own SELinux domain and supplies the policy for it in the system configuration. After a rebuild, the service runs confined, and an attempt by that service to reach something outside its policy is blocked and logged.

**Why this priority**: Per-service confinement is the reason to choose SELinux, and declaring it in configuration is what makes it fit NixOS. It depends on the first two stories.

**Independent Test**: A VM test enables SELinux in enforcing mode with one network service confined, asserts the service runs in its declared domain and serves requests, then makes the service attempt a forbidden access and asserts it is denied and logged.

**Acceptance Scenarios**:

1. **Given** a configuration that declares a domain and policy for a service, **When** the service starts, **Then** it runs in the declared domain.
2. **Given** that confined service, **When** it attempts an access its policy does not allow, **Then** the access is denied and logged.
3. **Given** a policy fragment that is malformed or refers to something undefined, **When** the configuration is built, **Then** the build fails with an error naming the fragment.
4. **Given** a policy tunable set as a configuration option, **When** the system is rebuilt, **Then** the active policy reflects the option's value.

---

### User Story 4 - Roll back and upgrade safely (Priority: P3)

An administrator rolls back to an earlier system generation, or upgrades to a later one, and the policy and labels in effect match the generation that is running.

**Why this priority**: Atomic upgrades and rollbacks are a core NixOS promise. A security feature that breaks them would not be accepted upstream.

**Independent Test**: A VM test builds two generations with different policies, switches forward, rolls back, reboots into each, and asserts that the active policy and sampled labels match the running generation each time.

**Acceptance Scenarios**:

1. **Given** two generations with different policies, **When** the administrator boots or switches to either, **Then** the policy in effect is the one belonging to that generation.
2. **Given** a generation built without SELinux, **When** the administrator rolls back to it from an SELinux generation, **Then** it boots and runs normally.

---

### User Story 5 - Review and adopt upstream (Priority: P2)

A nixpkgs reviewer receives the work as a series of small changes. Each is off by default, comes with a VM test and documentation, and can be reviewed and merged on its own. An accompanying write-up explains the design, the threat model and how the known objections are addressed.

**Why this priority**: The goal is support for everyone, and earlier attempts stalled at review for lack of tests, documentation and a demonstrated end-to-end system.

**Independent Test**: Each proposed change builds and passes its tests on its own against the current upstream branch, and a reviewer who was not involved can follow the documentation to reproduce the P1 and P2 results.

**Acceptance Scenarios**:

1. **Given** the patch series, **When** any single change is applied to upstream in order, **Then** existing systems that do not enable SELinux are unaffected and all tests pass.
2. **Given** the design write-up, **When** a reviewer looks for the response to a previously raised objection (store immutability, forged trusted paths, untested global options), **Then** they find a specific answer backed by a test or a stated limit.

---

### Edge Cases

- **Forged paths**: A local user builds a package whose name and layout imitate a trusted program. It must not receive a privileged label.
- **Shared files**: Store optimisation makes two paths share one file. What label does the file get when the two paths would be labelled differently?
- **Content outside the system closure**: Packages a user builds or installs into a profile after boot must get a safe default label, never a privileged one, and must not be left in a state that breaks the system.
- **Store maintenance**: Garbage collection, store repair, optimisation and re-download of a previously labelled path must not leave system content unlabelled while it is in use.
- **Policy fails to load at boot in enforcing mode**: The administrator must have a documented way to recover, for example by booting an earlier generation or in permissive mode.
- **Interrupted labelling**: A power loss during labelling must not leave the machine unbootable.
- **Large systems**: Labelling time must stay acceptable for a large system closure and must not be repeated in full on every boot or switch.
- **Ephemeral root filesystems**: Systems whose root is recreated at every boot must still end up correctly labelled.
- **Another security module already enabled**: Enabling SELinux alongside an AppArmor configuration must fail at build time with a clear message.
- **Programs reached through links and wrappers**: Commands run through profile links, wrapper scripts and the privileged wrappers directory must start in the intended context.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Administrators MUST be able to enable SELinux for a NixOS system, and choose permissive or enforcing mode, entirely through the system configuration.
- **FR-002**: With the feature disabled, the built system MUST be unchanged from one built without this work.
- **FR-003**: The system MUST load the configured policy early enough in boot that files created during system activation and service start-up are labelled correctly.
- **FR-004**: The policy MUST be produced entirely at build time as part of the system generation, with no policy state that can only be changed by hand on the running machine.
- **FR-005**: Every file in the running system's closure MUST carry an intentional label before it is first used, and the test suite MUST verify that no such file is unlabelled.
- **FR-006**: Labels that grant a privileged role, such as the entry point of a confined service, MUST be assigned only to content the system configuration explicitly designates, in a way an unprivileged local user cannot imitate.
- **FR-007**: Store content outside the running system's closure MUST receive a safe default label that confers no privilege.
- **FR-008**: The feature MUST work with unmodified Nix. It MUST NOT depend on changes to the Nix daemon, the store format or binary caches.
- **FR-009**: Labelling MUST skip content that is already correctly labelled, so that repeated boots and switches do not relabel the whole system.
- **FR-010**: Switching to a new generation MUST label new system content and activate the new policy before services from that generation start.
- **FR-011**: In enforcing mode, a switch whose policy cannot be loaded MUST be refused before the running system is changed.
- **FR-012**: Booting or rolling back to any generation MUST put that generation's policy into effect.
- **FR-013**: The init process, system services and login sessions (console and SSH) MUST start in the contexts the policy and configuration assign.
- **FR-014**: The Nix daemon MUST keep working in enforcing mode for building, substituting, garbage collection and configuration switches.
- **FR-015**: Programs in the privileged wrappers directory MUST work in enforcing mode and carry appropriate labels.
- **FR-016**: Administrators and service module authors MUST be able to declare, in configuration, a service's domain and the policy fragments it needs.
- **FR-017**: Policy tunables MUST be settable as configuration options.
- **FR-018**: An invalid policy MUST cause the system build to fail with an error that identifies the offending part.
- **FR-019**: Denials MUST be recorded where administrators can read them, and the tools needed to interpret them and draft policy from them MUST be available on the system.
- **FR-020**: The documented behaviour for the edge cases above (shared files, store maintenance, interrupted labelling, failed policy load) MUST be defined and covered by tests where a test is practical.
- **FR-021**: Every milestone MUST be covered by automated tests that run in VMs built by Nix.
- **FR-022**: The work MUST be delivered as a series of independently reviewable, default-off changes, each with tests and user documentation.
- **FR-023**: The work MUST include a design write-up with a threat model stating what the feature protects against, what it does not, and how it answers the objections recorded in the research.
- **FR-024**: The initial policy MUST treat anything without dedicated policy as unconfined, so that enabling the feature does not require policy for every package. This unconfined-by-default policy is the first upstream target.
- **FR-025**: In the first version SELinux and AppArmor MUST be mutually exclusive. A configuration that enables both MUST fail at build time with a clear message.

### Key Entities

- **System generation**: One built NixOS configuration. Carries its own policy and the list of content that must be labelled.
- **Policy**: The set of rules in force. Composed at build time from a base policy, NixOS-specific rules, per-service fragments and tunable values.
- **Policy fragment**: Rules contributed by one service or by the administrator.
- **Label**: The security context on a file or process.
- **Labelling rule**: A mapping from store content to a label. Either generic (broad, unprivileged) or exact (names specific designated content and may confer privilege).
- **Domain**: The context a confined service runs in.
- **Login mapping**: The association between a system user and the context their sessions start in.
- **Denial record**: A log entry describing an access the policy blocked, or would have blocked in permissive mode.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A NixOS VM with the feature enabled boots in permissive mode with every file in the system closure labelled. The automated check finds zero unlabelled files.
- **SC-002**: A minimal NixOS VM boots in enforcing mode, accepts console and SSH logins, completes a configuration switch, builds a package and reboots, with zero unexpected denials.
- **SC-003**: At least one network-facing service runs confined in enforcing mode, and a test shows a forbidden access by that service is blocked.
- **SC-004**: A package built by an unprivileged user to imitate a confined service's program is shown by a test to receive no privileged label.
- **SC-005**: Enabling the feature adds no more than 30 seconds to the first boot of a typical server configuration and no more than 5 seconds to later boots where nothing changed.
- **SC-006**: Switching between two generations with different policies, in either direction, leaves the correct policy active in 100% of test runs.
- **SC-007**: Systems that do not enable the feature build to identical results before and after the changes.
- **SC-008**: Someone not involved in the work can reproduce the permissive and enforcing results from the documentation in under 30 minutes.
- **SC-009**: The first change in the series is accepted for upstream review with its tests passing in upstream's automated checks.

## Clarifications

### Session 2026-11-21

- Q: Is an unconfined-by-default policy acceptable as the first upstream target? → A: Yes.
- Q: Should SELinux and AppArmor be mutually exclusive in the first version? → A: Yes.
- Q: Build on the open upstream pull requests and contact their authors now, or stay independent? → A: Stay independent for the moment.

## Assumptions

- The work targets NixOS itself. Making Nix run on other SELinux distributions (the installer problem) is a separate effort and out of scope.
- Changes to Nix core are out of scope, because Nix maintainers have declined them repeatedly. See research.md section 2.
- The reference policy already packaged in nixpkgs is the base, extended by a NixOS-specific layer. See research.md section 5.
- Confinement of the Nix build sandbox beyond what the daemon already provides, confined desktop sessions, multi-level security and container isolation are later work.
- The prototype is developed independently for now. We do not contact the people already working on this upstream, or post in upstream discussions, until Alison decides to. Public upstream work may be read as reference.
- Testing uses VMs built by Nix. No physical hardware is required.
- Secrets are kept out of the Nix store, as NixOS already recommends, so no store content needs a confidentiality label.
