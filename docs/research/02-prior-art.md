# SELinux on NixOS: prior art and upstream discussion (as of 2026-11-21)

## 0. Method and confidence

- Read-only research. Nothing was posted anywhere.
- **Tooling limits.** `gh api repos/...` and the GitHub MCP were refused for the NixOS repos ("repository not configured for this session"); I did not widen access. What worked: `gh api search/issues` (titles, bodies, counts, merge state) and WebFetch of public pages. WebFetch returns a model-written summary, not raw text, so comment content below is paraphrase, and many pages gave no dates.
- Labels: **[V]** = read on the page (via WebFetch summary or API search result). **[I]** = my inference. **[U]** = not confirmed or could not read.
- No quotes are verbatim unless in quote marks.

## 1. Executive summary

1. The blocker is the same since 2018. Nix never records or preserves xattrs (including `security.selinux`) in the store or in NARs, and Nix maintainers consider labels on files in a store that is meant to be immutable a design problem. The official position since 2022-12-09 is "approach SELinux through the installer", not the core.
2. NixOS-side work exists but is a small, partly stalled effort. RossComputerGuy and numinit got refpolicy packaged and an SELinux NixOS VM booting in 2025. The module and global-flag PRs remain open and unmerged, and reviewers objected to merging untested global options. **[V]** One user-visible hard problem is unsolved: how store binaries get labelled.
3. The installer-level policy (Determinate / nix-community) is a minimal path-based hack that keeps the daemon working on Fedora/RHEL. It is known to be fragile (hardlink `.links`, `restorecon` after upgrade, optimise).
4. Late 2026 activity: a new PR, nixpkgs#591351 (filed 2026-11-21), adds SELinux to linux-pam and claims an SELinux NixOS guest VM test. Naxdy (author) is a person to contact. A Discourse revival (Nov 2026) is mostly debate; achille claims policy-labelling dataset work.

## 2. nixpkgs: issues and PRs

### 2.1 The ExpidusOS / Tristan Ross (RossComputerGuy) + numinit series (April 2025 onward) **[V]**

| PR | Title | State | Notes |
|---|---|---|---|
| [#395855](https://github.com/NixOS/nixpkgs/pull/395855) | nixos/security: init lsm option | merged 2025-04-18 | `security.lsm`, prerequisite for choosing LSMs |
| [#396155](https://github.com/NixOS/nixpkgs/pull/396155) | selinux-refpolicy: init 2.20250213 | merged 2025-04-07 | refpolicy packaged |
| [#396725](https://github.com/NixOS/nixpkgs/pull/396725) | selinux: fix various issues (numinit) | merged 2025-04-07 | libselinux Python split output, libsemanage, selinux-python; "fastlined into staging" |
| [#407748](https://github.com/NixOS/nixpkgs/pull/407748) | nixos/security: landlock, yama, bpf defaults | merged 2025-05-24 | LSM defaults |
| [#485821](https://github.com/NixOS/nixpkgs/pull/485821) | selinuxPackages: init; bump all to 3.10; refpolicy 2.20250923 | merged 2026-02-13 | numinit; includes upstream commit 04a592bf needed to build policy inside a derivation (without it: missing `/usr/libexec/selinux/hll/pp`). Ross noted this unblocks continuing #396177. |
| [#396168](https://github.com/NixOS/nixpkgs/pull/396168) | pkgs/top-level/config.nix: add selinux support (`selinuxSupport` flag) | **open** since 2025-04-05, 20 comments | see below |
| [#396177](https://github.com/NixOS/nixpkgs/pull/396177) | nixos/selinux: init | **open** since 2025-04-05, 5 comments | see below |

**#396177 (the module)** **[V]**: new `nixos/modules/security/selinux.nix`. Options for `type` (sets SELINUXTYPE) and policy packages, loads policy in an activation script. Review points: use `lsm=selinux`, not deprecated `security=selinux` (M0ustach3); build policy into a derivation instead of at activation (numinit); how to remove stale modules (numinit proposed a state file of loaded modules); module load order matters, refpolicy first (4z3, who has a similar implementation); expose multiple policy packages (twoolie). Author said they "haven't had time to continue". Status: stalled.

**#396168 (global flag)** **[V]**: why it stalled:
- Ma27 (maintainer): unclear SELinux is feasible on NixOS; maintainers should not QA an option nobody can test; asked to delay.
- flokli: wants the PRs batched or kept in a downstream branch until something works end to end; no NixOS test or testing docs; unclear if enabling could break existing machines on switch. "Global options enabling untested support shouldn't land."
- winterqt: SELinux in Nix "is broken and unlikely to be fixed soon" (cites the RFC and a Nix PR); questions value; asks if `nix-store --repair` could leave a broken enabled policy.
- arianvp: points to AppArmor roadmap; "I dont think the SELinux route is going to end anywhere"; asks what it does when the Nix daemon drops SELinux attributes on add.
- Ross: labelling `/run/current-system` symlink inodes (idea credited to numinit) gives no security alone because software can reach the store directly; suggested wrapping the store.
- Supporters: illdefined (ran nixpkgs-review, 89 packages build), panchoh, LordGrimmauld/JohnRTitor (AppArmor-side, not opposing SELinux).

### 2.2 Other related nixpkgs items **[V]**

- [#591351](https://github.com/NixOS/nixpkgs/pull/591351) linux-pam: allow building with SELinux support. Naxdy, opened 2026-11-21, open, 0 comments, review requested from RossComputerGuy and numinit. `withSelinux` default false. Author says it was verified "in a NixOS VM test with an SELinux-enabled NixOS guest" where pam sets exec context from `default_contexts`; no link to that test or branch. LLM-assistance disclosed (research/debug, not code).
- [#570124](https://github.com/NixOS/nixpkgs/pull/570124) openssh: allow building with SELinux support (Naxdy), merged 2026-10-04. Naming of the flag is inconsistent in nixpkgs (`selinuxSupport`, `withSelinux`, `withSELinuxModule`).
- [#580953](https://github.com/NixOS/nixpkgs/pull/580953) fakeroot: hide selinux xattrs (jane400), open 2026-10-30. Building a NixOS sdimage on Fedora with SELinux fails (`mkfs.ext4` populate error on `security.selinux`). States "nixpkgs and SELinux isn't a supported combination anyway".
- [#507501](https://github.com/NixOS/nixpkgs/issues/507501) "Upstream SELinux support plan for Nix installer and runtime" (YongDo-Hyun, 2026-04-07), closed by the author on 2026-04-15 with a one-line comment; no maintainer engagement. Proposed CI matrix, `/nix` file-context strategy, restorecon/libselinux runtime investigation. **[I]** Low-signal; do not treat as a real effort.
- [#375257](https://github.com/NixOS/nixpkgs/pull/375257) stage-2-init: RO store bind-mount false positives; referenced by numinit as related to the overlay idea. **[V]** that it was referenced; **[U]** details.
- Package maintenance: policycoreutils/setools/libsepol bumps, CVE issues ([#551117](https://github.com/NixOS/nixpkgs/issues/551117) fixfiles TOCTOU, closed). Open: [#510901](https://github.com/NixOS/nixpkgs/issues/510901) security kernel param conflicts with `security.lsm` (title read only), [#414135](https://github.com/NixOS/nixpkgs/issues/414135) distrobox/SELinux.
- Earlier history: 2019 e-user nixpkgs PRs #56960 to #56965 (bump selinux libs to 2.8), mentioned in NixOS/nix#2670 **[V that they were mentioned]**; [#15271](https://github.com/NixOS/nixpkgs/issues/15271) (2016, system-config-selinux pkexec path).

## 3. NixOS/nix core

- [#2374](https://github.com/NixOS/nix/issues/2374) (open, 2018-08-26, 67 comments): multi-user installer on Fedora fails because `init_t` cannot read `default_t` symlinks under `/nix` (`systemctl link` denied). No Nix maintainer statements in the thread. **[V]** Workarounds: setenforce 0, policy module, third-party installers.
- [PR #2670](https://github.com/NixOS/nix/pull/2670) "Provide SELinux support for Nix" (outergod / Alexander Kahl / e-user, 2019-02-08, closed). Made Nix write file contexts; shipped an installer that loads a policy. **Closed at the Nix team meeting 2022-12-09** ([minutes](https://discourse.nixos.org/t/2022-12-09-nix-team-meeting-minutes-15/23951)), underlying issue left open. Recorded notes: "we should approach SELinux through the installer". Via the PR thread, edolstra is reported to have said the earlier conclusion was that SELinux support is "not realistic", and that labels on files in a mutable store are "like having setuid binaries in the store" **[V: PR page summary; I could not see the original wording]**. thufschmitt suggested the installer route (nix-community/nix-installers).
- Mailing list 2019-02: etbe (Russell Coker) argued per-derivation contexts diverge from upstream policy; map `/nix/store/*` onto `/` via a single `semanage fcontext -e` rule; also posted a libselinux patch adding wildcards to `file_contexts.subs` ([lore](https://lore.kernel.org/all/7853167.K65cXu0y11@neuromancer/), 2019-02-22; he did not expect it accepted as written). **[V]** The NixOS wiki links this as the `subst` approach. **[U]** whether libselinux ever merged it.
- [#5327](https://github.com/NixOS/nix/issues/5327) "Add metadata support for derivations" (2021-10-04, closed stale by tomberek): post-install root hook for setcap/labels/PaX. **edolstra rejected**: post-build modification conflicts with store immutability; setuid handled by wrappers outside the store; "AppArmor is considered more compatible with Nix because it doesn't require attaching metadata to files". **[V]** (summary says "AppArmor considered more compatible"). This is the clearest maintainer statement of what is unacceptable.
- [#185](https://github.com/NixOS/nix/issues/185) NAR support for xattrs (2013, closed): vcunat wants NAR<->store conversion to be a bijection per platform/filesystem, calls metadata portability "a serious concern"; xattrs omitted "on purpose" per `archive.hh` comment. **[V]**
- [#7850](https://github.com/NixOS/nix/issues/7850) "SELinux support" (2023, closed stale) and [#7906](https://github.com/NixOS/nix/issues/7906) (open, 2023-02-25, 3 comments, not read in detail). Ericson2314 suggested merging into #2374.
- Installer-abort PRs [#6639](https://github.com/NixOS/nix/pull/6639) (abort if SELinux on) and [#6881](https://github.com/NixOS/nix/pull/6881) (only fail in enforcing), both closed; **[U]** whether either merged. Per #2374, users report the legacy installer still aborts/fails on SELinux hosts.
- Store behaviour today **[V]** ([manual, conf-file](https://nix.dev/manual/nix/latest/command-ref/conf-file.html)): `ignored-acls` default is `security.csm security.selinux system.nfs4_acl`. Nix tries to strip ACLs/xattrs from store files, ignores errors for these because they cannot be removed even by root. That is the entire SELinux awareness in the daemon. [PR #4765](https://github.com/NixOS/nix/pull/4765) introduced the setting (2021, closed).
- [#15743](https://github.com/NixOS/nix/pull/15743) linux-derivation-builder: also block `*listxattr` (pcc, 2026-04-25, closed) **[V title only]**, relevant if sandbox xattr access policy changes.

## 4. RFCs **[V unless stated]**

- [RFC 0041 SELinux Support](https://github.com/NixOS/rfcs/pull/41) (e-user, start 2019-03-10, closed). Shepherd team never settled (edolstra, shlevy, thoughtpolice, joachifm were named; scheduling failed repeatedly). Main objection (Ekleog): trusting binaries by path relative to the derivation root means any user who can ask the daemon to build arbitrary content gets a trusted label; asked for a threat model; said NixOS could generate policy via modules but not how Nix interoperates. zimbatm: the real motivation is running Nix on SELinux distros. Closed by the author after a call with edolstra: refocus on a minimum viable solution for running store binaries from systemd on SELinux hosts, via the installer. I could not read the RFC text itself.
- [RFC 0143 Nix Store ACLs](https://github.com/NixOS/rfcs/pull/143) (balsoft, 2023-01-16, still open): POSIX ACL/permissions in the store; no SELinux mention. Discussion shows resistance to adding mutable-ish metadata to the store (Ericson2314 prefers capabilities; roberth urged finishing existing projects first).
- [RFC 0196 Self-describing store](https://github.com/NixOS/rfcs/pull/196) (roberth, 2026-01-18, open): `nix-store.json`; does not address xattrs but is a possible hook for a "store has labels" feature flag. **[I]**
- Adjacent: [RFC 0152 local-overlay store](https://github.com/NixOS/rfcs/pull/152) and [RFC 0017 intensional store](https://github.com/NixOS/rfcs/pull/17) appeared in the search for metadata; not read. **[U]**
- Search found no RFC about AppArmor/MAC/xattrs beyond RFC 41.

## 5. Installers and other Nix implementations

### Determinate nix-installer **[V]**
- Ships a policy module `nix` ([nix.te](https://github.com/DeterminateSystems/nix-installer/blob/main/src/action/linux/selinux/nix.te), [nix.fc](https://github.com/DeterminateSystems/nix-installer/blob/main/src/action/linux/selinux/nix.fc)). The whole `.te` is one rule: `allow init_t default_t:lnk_file read;` (plus a require block). The `.fc` maps path regexes under `/nix/store/[^/]+/` onto stock types: `s?bin` to `bin_t`, `lib/systemd/system` to `systemd_unit_file_t`, `lib` to `lib_t`, `man` to `man_t`, `etc` to `etc_t`, `share` to `usr_t`; `/nix/var/nix/daemon-socket` to `var_run_t`; profiles to `usr_t`. So this is the "treat store as `/`" idea from 2019, implemented as regexes, with no per-package types and no confinement of the daemon or builds.
- History: Hoverbear's [#123](https://github.com/DeterminateSystems/nix-installer/pull/123) and [#465](https://github.com/DeterminateSystems/nix-installer/pull/465) (2022-12 / 2023-05; tested Fedora 36/37, RHEL 7/8/9); [issue #124](https://github.com/DeterminateSystems/nix-installer/issues/124). Open bugs: [#829](https://github.com/DeterminateSystems/nix-installer/issues/829) (after upgrade the daemon unit is invisible until `restorecon -Rv /nix`), [#1490](https://github.com/DeterminateSystems/nix-installer/issues/1490) (restorecon labels hard-linked/optimised files `default_t`), [#1279](https://github.com/DeterminateSystems/nix-installer/issues/1279), [#835](https://github.com/DeterminateSystems/nix-installer/issues/835), [#1383](https://github.com/DeterminateSystems/nix-installer/issues/1383), [#1325](https://github.com/DeterminateSystems/nix-installer/issues/1325), PR [#1733](https://github.com/DeterminateSystems/nix-installer/pull/1733) (cole-h; only remove module if present). Titles read; bodies only for #829/#465.
- [determinate.systems/nix/selinux](https://determinate.systems/nix/selinux): marketing page, says Determinate Nix "works on SELinux-enabled systems without disabling enforcement". No design details. **[V]**
- Upstream [NixOS/nix-installer](https://github.com/NixOS/nix-installer) appears to exist as of 2026 (issues #155, #248 on ostree/Fedora Atomic) **[V from search listing; not otherwise read]**.
- The older nix-community/nix-installers (adisbladis; RPM/DEB with policy) is the project thufschmitt pointed to in 2022. **[V]**

### Lix **[V from two issues]**
- [lix #546](https://git.lix.systems/lix-project/lix/issues/546) "SELinux, incorrect labelling from derivation" (soupglasses, 2024-10-14). A Lix maintainer wrote that neither Lix nor CppNix handle SELinux metadata, listed the open questions (apply labels on substitution? store contexts in NARs, needing a format change? is restoring contexts for untrusted-user paths a security risk?), said a `post-build-hook` running `restorecon` helps builds but not substitutes, and that deferring to the installer is not acceptable because `nix upgrade-nix` and System-Manager break. States the feature needs SELinux expertise and a long-term maintainer, and the core team has not been polled. Real design discussion, no commitment.
- [lix #486](https://git.lix.systems/lix-project/lix/issues/486): `upgrade-nix` replaces unit files with wrong labels (needs restorecon). No maintainer reply seen.
- A Lix-installer fork with SELinux commits exists (artemist) **[U, not read]**.
- GitHub search of lix-project/lix returned 0 hits (the real tracker is Forgejo).

### Distros
- Fedora packages Nix (41 to 43 stable, planned 44 per [#2374](https://github.com/NixOS/nix/issues/2374) commenters). [RH Bugzilla 2416675](https://bugzilla.redhat.com/show_bug.cgi?id=2416675) (filed 2025-11-23, assigned to Jens Petersen, still ASSIGNED 2026-10-07): systemd denied reading `/nix/store/.links/<hash>` (`default_t`) when enabling a unit from the store, even with the Determinate `nix.pp` loaded. Jens opened fedora selinux-policy issue #2963 and PR #3454 (2026-10-07). **[V]** This is the live place where Fedora policy maintainers are engaging with the Nix store label problem.
- Guix has an [SELinux support section](https://guix.gnu.org/manual/en/html_node/SELinux-Support.html) and an issue ([62487](https://issues.guix.gnu.org/62487)) for guix-daemon on SELinux/systemd. **[V titles from search; not read]** Possibly a model to compare.

## 6. Discourse, blogs, talks, wiki

- [SELinux on NixOS](https://discourse.nixos.org/t/selinux-on-nixos/62729) (started 2025-04-06 by RossComputerGuy; revived 2026-01-14 and again 2026-11-11 onward) **[V, via two pages; post 26 and posts ~9-20 only partly seen]**:
  - rnhmjoj: is SELinux "fundamentally useless" since store metadata can't change?
  - numinit: separate labelling store paths from labelling their activation-time targets (path-based contexts); proposes testing at NixOS level; overlay needs benchmarking (overlayfs metacopy with SELinux, whether the daemon's stage-2 bind mount works); suggests policy baked into a squashfs store image plus overlay, dm-verity.
  - Ross: store overlay (store lower, tmpfs SELinux layer upper, set up in stage 2); 2025-04-10 reports baking policy into squashfs "seems very much to be possible".
  - arianvp: AppArmor instead; labels would need to propagate through NARs; systemd unit/ExecStart point into the unlabelled store.
  - waffle8946: a MAC that skips the store is "a tiny hole". sudoBash418: still useful for processes, `/var`, secrets.
  - ElvishJerricco (2025-04-07): experimental stage-2 verification: patched Nix enables fs-verity on store files at registration, metadata-only erofs of expected root hashes, overlayfs enforces; unmounted in the daemon's private mount namespace. Suggests combining with SELinux overlay ideas.
  - RazeLighter777 (2026-01-14): own attempt with overlayfs `metacopy=on`; asks whether changing the lower layer while mounted is undefined (it is documented as such for overlayfs **[I]**).
  - 2026-11 round: tomf asks for use cases; achille says they are producing a dataset mapping refpolicy paths to Debian/Repology/nixpkgs packages and labelling store binaries via xattrs, with LLM-assisted auto-labelling (systemd in progress, visualised on relix.fyi; cost estimate $100 to $1000), bogorad supportive for nspawn/QEMU use, stefan-hacks skeptical about contexts at scale, Ross says xattr handling "is solvable". Thread ended with no working implementation shown. Tone partly hostile (accusations of LLM output).
- [Tristan Ross, "SELinux on NixOS"](https://tristanxr.com/post/selinux-on-nixos/) (2025-04-05) **[V]**: SELinux enabled on a NixOS VM, `sestatus` ok, refpolicy policy v33 loaded. Packaging with GNU Make; NixOS module generating `/etc/selinux/config`, kernel options, systemd with SELinux, activation script installing policy per generation (~40 s boot stall); policy version mismatch (userspace default 34 vs kernel 33) solved with `policyVersion`/`moduleVersion` options; libsemanage pointed at store tool paths. Limits: refpolicy "in no way a fully secure policy"; VM only; effect on Nix daemon/builds unexamined; declarative policy future work. State reached: policy loads, system boots. **Whether enforcing or permissive is not stated in the summary [U].**
- NixOS wiki [Workgroup:SELinux](https://nixos.wiki/wiki/Workgroup:SELinux) / [wiki.nixos.org copy](https://wiki.nixos.org/wiki/SELinux_workgroup) (last edited 2025-06-08, flagged as deletion candidate, "may no longer be active", no members). Documents the old recipe: `security=selinux`, kernel patch, policycoreutils, systemd with SELinux, and a `subst` file-contexts patch mapping `/nix/store/*` to `/`. **[V]**
- Other threads seen only by title: [RFC 41 shepherd nomination (2019)](https://discourse.nixos.org/t/rfc-41-selinux-support-is-open-for-shepherd-nomination/2420), [TOMOYO MAC on NixOS](https://discourse.nixos.org/t/tomoyo-mac-on-nixos/73691), [AppArmor on NixOS roadmap](https://discourse.nixos.org/t/apparmor-on-nixos-roadmap/57217), [Privacy Guides: current state of MAC on NixOS](https://discuss.privacyguides.net/t/whats-the-current-state-of-mac-on-nixos-seeking-recommendations/39673), gists by [xeji](https://gist.github.com/xeji/78d4abbb493fc5a5b6f069b41ebdafbe) and [matthewpi](https://gist.github.com/matthewpi/08c3d652e7879e4c4c30bead7021ff73), dnkmmr69420's ["install nix without disabling selinux"](https://discourse.nixos.org/t/there-is-a-way-to-install-nix-without-completely-disabling-selinux/26166) (2023-03-09; actually disables then re-enables SELinux). **[U]** contents.
- No NixCon/FOSDEM talk on SELinux was found in my searches **[U: absence of evidence]**.
- Third-party flake/repo that boots NixOS under enforcing SELinux: **none found**. The only claim of a working SELinux NixOS guest is Naxdy's VM test in #591351 (not linked) and Ross's 2025 VM. e-user's 2019 NixOS fork (linked from the wiki) was not retrieved. **[U]**

## 7. Maintainer statements: what they would / would not accept

(All second-hand through page summaries unless noted.)
- Would not accept: post-build mutation of store files for metadata (edolstra, nix#5327); labels on mutable store files; core Nix changes for SELinux (Nix team 2022-12-09, "not realistic" per edolstra via #2670); path-trust labelling without a threat model (Ekleog, RFC 41); xattrs in NAR unless NAR<->store stays a bijection per platform (vcunat, #185).
- Would consider / pointed to: installer-level support (thufschmitt, Nix team 2022); AppArmor as the more Nix-compatible MAC (edolstra, arianvp, Atemu roadmap); for nixpkgs, working, tested, documented end-to-end pieces with NixOS tests, not untested global options (flokli, Ma27, winterqt).
- Lix: open to discussing; wants SELinux expertise and long-term maintainer; does not accept "installer only" as the answer (lix#546).
- Nix team has not issued any SELinux statement newer than 2022-12-09 that I could find. **[U]**

## 8. Lessons for a new attempt

1. Pick a store-labelling story first. Every prior effort died on "labels in an immutable, content-addressed store". Candidate designs seen: (a) path-regex file contexts, no xattrs (Determinate, Coker's subst); (b) post-build hook `restorecon` (Lix idea, not for substitutes); (c) labelled overlay over a read-only store (Ross/numinit/RazeLighter777); (d) xattrs in NAR/store (needs Nix format change, historically rejected); (e) policy baked into a squashfs/erofs store image (numinit, ElvishJerricco's fs-verity overlay). (a)/(c)/(e) need no Nix core changes and fit the maintainers' stated constraints. Write down a threat model for whichever is chosen (Ekleog's RFC 41 objection).
2. Keep core Nix out of the critical path. Maintainers said no repeatedly; aim for NixOS-module-level and installer-level changes first. Also consider the `.links`/optimise hardlink problem (determinate#1490, RH bug 2416675): path labels on hardlinked store files are wrong.
3. Land small, testable, default-off pieces with NixOS VM tests. #396168/#396177 stalled on "no test, no docs, might break switch". Merged work was package fixes and the `security.lsm` option. Provide a NixOS test and a clear "does nothing unless enabled" guarantee.
4. Use `lsm=`/`security.lsm`, not `security=`; build policy in a derivation and handle module removal/order (review notes on #396177). Avoid activation-time compile; mind the ~40 s stall.
5. Be explicit about the motivation and audience: running Nix on SELinux hosts (installer) versus a confined NixOS. Reviewers conflate them.
6. Be wary of the AppArmor comparison; have a concrete example of what SELinux enforces that AppArmor cannot (tomf's Nov 2026 question is exactly this).
7. Avoid LLM-hype posture: the Nov 2026 Discourse thread turned hostile over suspected LLM-generated claims; nixpkgs has an AI/automation policy checkbox. Disclose usage.
8. Fedora/RHEL policy side matters: upstreaming label rules into fedora selinux-policy / refpolicy may be easier than into Nix (selinux-policy#2963, PR #3454).

## 9. People and projects to coordinate with

- Tristan Ross (RossComputerGuy; ExpidusOS): #396155/#396168/#396177, blog, Discourse.
- numinit (Morgan Jones): selinuxPackages, overlay/squashfs/dm-verity ideas, policy-in-derivation.
- Naxdy: #591351, #570124, claims an SELinux NixOS VM test. Highest priority to contact (current, active).
- Alexander Kahl (e-user / outergod): PR #2670, RFC 41, NixOS fork; institutional memory. Activity currently unknown.
- Eelco Dolstra (edolstra), thufschmitt, tomberek, Ericson2314, vcunat: Nix-side positions.
- flokli, Ma27, winterqt, arianvp: reviewers who set the nixpkgs acceptance bar.
- ElvishJerricco: fs-verity/erofs overlay store verification, overlaps with labelled-overlay design.
- Russell Coker (etbe) and Nicolas Iooss (libselinux/refpolicy): file_contexts.subs and refpolicy upstream.
- Jens Petersen and Fedora selinux-policy maintainers (RH bug 2416675).
- Determinate Systems (Hoverbear, cole-h, lucperkins), Lix maintainers (issue #546), adisbladis (nix-installers), artemist (lix-installer fork).
- achille (dataset/labelling effort), RazeLighter777 (overlay metacopy experiments), jane400 (fakeroot, sdimage on SELinux hosts), soupglasses (System-Manager on SELinux).
- Projects: SELinuxProject/refpolicy and selinux userspace, Fedora selinux-policy, Guix (SELinux support docs) as a comparison.

## 10. Gaps (not confirmed)

Comment bodies of nix#7906, nixpkgs#396177/#396168 were read only as page summaries (no dates). RFC 41 text, e-user's NixOS fork, Lix installer fork, Guix details, TOMOYO and AppArmor roadmap threads, RFC 152/17, nix#6639/#6881 merge status, the content of Naxdy's VM test, and whether any enforcing-mode NixOS boot was ever demonstrated were not verified. Searches may have missed repos with no "selinux" in title/body.
