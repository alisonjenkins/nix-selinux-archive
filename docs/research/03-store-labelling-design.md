# SELinux on NixOS: how to label /nix/store (design comparison)

Scope: research only, no code written. Facts I fetched and read are tagged **[V]** (verified, with source). Reasoning from SELinux/Linux knowledge that I did not check against a source in this session is tagged **[I]** (inference). Anything the prototype must settle is listed at the end.

Research limits: `gh api` was blocked for NixOS/* repos in this session, so Nix and nixpkgs source was read through raw.githubusercontent.com (master branch, fetched 2026-11-21). The Guix, ostree, Android and Bottlerocket pages are the documentation or issue threads cited, not the source trees. ostree's source (`ostree-sepolicy.c`) was read.

---

## 0. Executive summary

- The biggest blocker is political, not technical. Nix's maintainers have repeatedly rejected store-side labelling as "mutable metadata in the store, like setuid binaries" (PR #2670 closed 2022-12-09; issue #5327; RFC 41 closed). The upstreamable route is therefore one that leaves Nix core untouched and labels the store from outside, or one that treats labels as a deployment concern, not store content.
- **Technically, Nix already tolerates `security.selinux` xattrs.** The default `ignored-acls` is `security.selinux system.nfs4_acl security.csm`, so canonicalisation does not strip the SELinux label on paths it processes **[V]** (local-settings.hh, below). Labelling after the fact with `setfiles`/`restorecon` is therefore not fought by Nix at registration. Whether other operations (optimise-store hardlinks, `nix-store --repair`, copy/substitute) preserve them is untested.
- Recommended direction (ranked in section 7): a **path-regex file_contexts policy for the store (Option 1), applied by NixOS at activation/boot to the system closure only, with labels baked offline into a metadata-only erofs/overlay layer as the later hardening step**. Add a **systemd `SELinuxContext=` / policy-generated exec-label bypass** for domain transitions where path labels are not enough. A single mount-wide `context=` (Option 3) is a useful stage-0 fallback but cannot support domain transitions.
- Known pitfall that bites every path-regex scheme: the store optimiser hardlinks identical files into `/nix/store/.links/<hash>`, and an inode has one label, not one per path **[V]** (Red Hat Bugzilla 2416675).

---

## 1. Facts about Nix and NixOS that constrain every option

### 1.1 What Nix does to store metadata **[V]**

Source: `src/libstore/posix-fs-canonicalise.cc` and `src/libstore/include/nix/store/local-settings.hh` (NixOS/nix master).

- Canonicalisation sets mode to 0444/0555, mtime to 1 (epoch + 1s), and (when the process may) uid/gid. Lines ~20-38 and ~221-252 of `posix-fs-canonicalise.cc`.
- It strips xattrs/ACLs only `#if NIX_SUPPORT_ACL`, via `stripXAttrs(...)`, which skips every name in `ignoredAcls` (`if (ignoredAcls.count(eaName)) continue;`).
- `local-settings.hh` line ~601: `Setting<StringSet> ignoredAcls{ this, {"security.selinux", "system.nfs4_acl", "security.csm"}, "ignored-acls", ...}` with the text "some ACLs like `security.selinux` or `system.nfs4_acl` can't be removed even by root. Therefore it's best to just ignore them."
- Consequence: a `security.selinux` xattr on a store path survives canonicalisation by default. The older claim "Nix strips xattrs" is true for other xattrs but not for this one in current master. I did not determine in which release this default arrived, so older Nix on a target may differ.
- Restore hooks (`makeCanonicalisingRestoreHooks(...ignoredAcls)`) are used in `local-store.cc` lines ~1119 and ~1311, i.e. when restoring NAR contents on import and substitution.
- Nix canonicalises only what it writes. It does not touch xattrs that a later `setfiles` adds, unless `nix-store --verify --repair` or an optimise pass rewrites the file **[I]**.

### 1.2 Hooks in Nix **[V]** (manual: https://nix.dev/manual/nix/2.28/command-ref/conf-file.html)

- `post-build-hook`: "path to a program to execute after each build"; runs synchronously and "blocks other builds from progressing". Per the Lix thread it runs for local builds, **not for substituted paths** (https://git.lix.systems/lix-project/lix/issues/546; the statement there is from the maintainers' discussion, not from source I read).
- `diff-hook`: only for diffing non-reproducible results, irrelevant.
- No SELinux code exists in libstore beyond the ignore-list above. In `src/libstore/globals.cc`, `derivation-builder.cc`, and `local-store.cc` a grep for "selinux" found only the ignored-acls plumbing at the two `local-store.cc` call sites.
- There is no hook that fires when a path is substituted or imported (`nix copy`, `nix-store --import`, `--add`). Covering all registration routes in Nix proper would need a new hook or a change in `LocalStore::registerValidPaths`/`addToStore` **[I]**.

### 1.3 Store mount in NixOS **[V]** (nixos/modules/system/boot/stage-2-init.sh)

- Stage 2 gives `/nix/store` its options by self-bind-mounting and `mount -o remount,<opts>,bind /nix/store` where the options include `ro` and `nosuid` (`@nixStoreMountOpts@`). It is a read-only bind mount of the same underlying filesystem, not a separate filesystem, unless the user has configured one.
- Important property **[I]**: `ro` is per-mount, so the underlying filesystem is writable from another mount of it (for instance a bind of `/` or the device elsewhere), and labelling can run before the ro remount or via a different view. setxattr on a `ro` bind mount fails with EROFS.
- The same script's comment says setuid binaries "should only exist in /run/wrappers". This is the exact philosophy that the Nix maintainers apply to labels, so expect the same reaction.

### 1.4 The label is per inode; store paths are not per-inode **[V]**

Red Hat Bugzilla 2416675 (https://bugzilla.redhat.com/show_bug.cgi?id=2416675): systemd running as `init_t` was denied reading `/nix/store/.links/<hash>`, a hardlink of a unit file. The file kept `default_t` despite Determinate's `nix.fc` rule `/nix/store/[^/]+/lib/systemd/system(/.*)?` -> `systemd_unit_file_t`, and relabelling by path did not help. The reporter's hypothesis (path vs inode) is plausible: SELinux checks the inode's xattr, and an optimised store has one inode for many paths **[I]**. Practical consequence: with `auto-optimise-store`, two files at different paths with different intended types but identical content share an inode and therefore a label. `setfiles` will flip the label to whichever path it visits last. Mitigations: disable `auto-optimise-store` on SELinux hosts (cost: disk), or label only content that is path-unique per type, or tolerate labels that are the same type anyway (most files in a package are `usr_t`/`lib_t`/`bin_t` and collisions between `bin_t` and `lib_t` content are rare but real).

---

## 2. Option 1: path-regex file_contexts adapted to the store

### 2.1 How it works

Ship refpolicy plus a store-aware `file_contexts.local`/`.fc` fragment, e.g.

```
/nix/store/[^/]+/bin(/.*)?          system_u:object_r:bin_t:s0
/nix/store/[^/]+/lib(/.*)?          system_u:object_r:lib_t:s0
/nix/store/[^/]+/lib/systemd/system(/.*)?  system_u:object_r:systemd_unit_file_t:s0
/nix/store/[^/]+/share(/.*)?        system_u:object_r:usr_t:s0
```

Evidence this is how everyone currently does it:

- Determinate nix-installer ships a `nix.fc` of exactly this shape (bin/sbin -> `bin_t`, lib/systemd/system -> `systemd_unit_file_t`, lib -> `lib_t`, man -> `man_t`, etc -> `etc_t`, share -> `usr_t`, `/nix/var/nix/daemon-socket` -> `var_run_t`, profiles -> `usr_t`) **[V]** (https://raw.githubusercontent.com/DeterminateSystems/nix-installer/main/src/action/linux/selinux/nix.fc; I got a paraphrase from the fetch tool, not the verbatim file).
- Guix's manual ships `etc/guix-daemon.cil` with `/gnu/store/.+-(guix-.+|profile)/bin/guix-daemon` -> `guix_daemon_exec_t`, applied by `restorecon -vR /gnu` after each `guix pull` **[V]** (https://guix.gnu.org/manual/en/html_node/SELinux-Support.html).
- Russell Coker's libselinux patch (2019) proposed `file_contexts.subs` wildcards so that `/nix/store/*` could be substituted to `/`, making every package look like its own root (`/nix/store/<hash>-httpd/bin/httpd` -> `/bin/httpd`) so stock refpolicy file contexts apply unchanged. He did not expect it to be accepted as is **[V]** (https://lore.kernel.org/all/7853167.K65cXu0y11@neuromancer/; the reply bodies were not retrievable). The NixOS wiki page for the workgroup links it too (https://wiki.nixos.org/wiki/SELinux_workgroup).

### 2.2 Variants of when labelling happens

| Variant | Mechanism | Covers | Notes |
|---|---|---|---|
| A. `setfiles`/`restorecon` at boot or in activation, **system closure only** | `nix-store -qR /run/current-system` piped to `setfiles -F -i -r ...` or `restorecon -R` per path; run in stage 2 before the ro remount, or against an rw view | everything the running system executes | Cost proportional to closure (typically a few GB, 100k-300k inodes); `-D` or `security.sehash` skips unchanged policy **[V for flag semantic, per perfinion in the Flatcar thread: https://github.com/flatcar/Flatcar/issues/673]**; only new paths need work after the first run **[I]** |
| B. Whole-store `restorecon -R /nix/store` | same, at boot | all paths including GC roots, user profiles | Minutes on big stores **[I]**; Fedora-with-Nix users run it manually (Bugzilla above) |
| C. Daemon-side `post-build-hook` running restorecon | Nix runs the hook after each local build | local builds only | Blocks other builds; does not cover substitutes **[V]** |
| D. A systemd path/timer unit that relabels new registrations | Watches `/nix/var/nix/db` or runs after `nix-daemon` | all | Race window between registration and labelling when a service starts from a new generation **[I]** |

NixOS-specific note: at `nixos-rebuild switch`, the new closure is known before activation, so variant A can run strictly before the switch (labelling only paths absent from the last labelled set).

### 2.3 What must change

- nixpkgs/NixOS only (a `security.selinux` module, a refpolicy derivation, a store `.fc`, an activation/boot labelling unit). **No Nix change is strictly required**, given the `ignored-acls` default **[V]**.
- Policy side: a NixOS-specific `.fc` module for refpolicy, and ideally an upstream-friendly one (see 2.5).
- Kernel/userspace: `libselinux`, `policycoreutils`, systemd with `withSelinux = true`, CONFIG_SECURITY_SELINUX. These are already in progress in nixpkgs per the community write-up (https://tristanxr-com.pages.dev/post/selinux-on-nixos, PRs #396105, #396155, #396168, #396177 in NixOS/nixpkgs) **[V that those PRs are cited there; I did not open them]**.

### 2.4 Per-package distinct labels?

Feasible technically (`/nix/store/[^/]+-nginx-[^/]+/bin/nginx -> nginx_exec_t`), and this is exactly what Guix does for its daemon. The cost:

- Regexes that mention package name patterns enlarge `file_contexts` and slow `selabel` lookup (libselinux sorts and matches linearly over specs, with a compiled `.bin` cache **[I]**). A few hundred package-specific rules are fine; thousands are not.
- Version and attacker issue (Guix manual): "any file with a matching name in any profile could be run in `guix_daemon_t`" **[V]**. In Nix terms, anyone who can build (every user with daemon access) can create `/nix/store/<hash>-nginx-evil/bin/nginx` and obtain `nginx_exec_t`. This is the objection Ekleog raised against RFC 41 **[V]** (https://github.com/NixOS/rfcs/pull/41): binaries are trusted by their path relative to the derivation root, and any daemon client can create content at that path.
- Version: a policy can't hold type names per version; Etbe argued per-version policy is unmaintainable **[V]** (PR #2670 discussion, https://github.com/NixOS/nix/pull/2670).

Mitigation sketch **[I]**: generate the per-package executable rules from the *system closure* at build time, with exact store paths (hash included), as a policy module in the system generation. Exact hash paths cannot be forged by an unprivileged builder (they would need a preimage), so the "any user can name a derivation `nginx`" attack is closed. Cost: the policy changes on every rebuild of that package, requiring `semodule` reload or, better, a `file_contexts.local` regenerated per generation, not a policy module. This is the same idea as a locally generated `.fc` mapping `/nix/store/<hash>-nginx/bin/nginx` to `nginx_exec_t` **[I]**.

### 2.5 Upstream acceptability

- **NixOS/nixpkgs**: plausible, because it is optional, off by default and isolated in a module. The existing Discourse thread shows interest from RossComputerGuy, numinit and others, and opposition (arianvp) only on cost/benefit grounds (https://discourse.nixos.org/t/selinux-on-nixos/62729).
- **NixOS/nix**: nothing needed, which is the key advantage.
- **SELinuxProject/refpolicy**: store fc fragment could be offered as an optional module. Etbe's guidance on PR #2670 (adopt a *single* store-wide rule, don't diverge from upstream policy) favours generic `bin/lib/share` rules over package-specific ones **[V]**.
- **libselinux**: Coker's `subs` wildcard patch would make stock policy work unchanged, but was not accepted as is **[V]**; resurrecting it is a long road **[I]**.

### 2.6 Pros / cons

Pros: no Nix change; per-type labels allow real domain transitions (bin_t, systemd_unit_file_t, lib_t for shared objects, etc.); consistent with how refpolicy is written; Guix/Determinate precedent.
Cons: the store must be writable at labelling time; labels live in the filesystem, not the closure (relabel cost, drift, GC'd and re-substituted paths are unlabelled until the next pass); the `.links` inode collision; labels on paths outside the system closure (build outputs, user profiles) are `default_t`/`unlabeled_t`; the regex trusts directory names under an untrusted-write namespace (ok if exec-type rules are generated from hashes, see 2.4).

---

## 3. Option 2: labelling inside Nix itself

### 3.1 Variants

1. **Daemon calls selabel on registration.** `LocalStore::registerValidPaths`/`addToStore`/after-build code looks up each file in `selabel_lookup()` using the *store's* file_contexts and sets `security.selinux` through `lsetxattr`. Needs libselinux linkage in libstore (optional dependency, like `NIX_SUPPORT_ACL`), CAP_MAC_ADMIN in the daemon domain, and a policy-scoped lookup from a path that must be translated like Coker's subs rule.
2. **Labels as derivation metadata.** Derivations or fixed attributes carry per-output file labels (issue #5327 proposed privileged post-install metadata). Would change derivation hashing and make labels part of identity.
3. **NAR extension.** Add an xattr section to the NAR/NarInfo so substituted paths carry labels. Breaks binary-cache compatibility and signatures; large ecosystem change.
4. **Store DB**: a `Labels` table recording the label and a content hash, replayed by the daemon on restore. Smaller than NAR changes, still a schema migration.

### 3.2 What Nix thinks

- edolstra on #5327: metadata like this "will never be implemented"; modifying store files after build conflicts with immutability and "setuid behavior is observable"; for SELinux he says AppArmor is "more compatible with Nix" because it needs no file metadata **[V]** (https://github.com/NixOS/nix/issues/5327).
- PR #2670 (SELinux support in Nix) was closed at the 2022-12-09 team meeting: "attaching labels to a mutable store is like setuid binaries in the store"; thufschmitt suggested the installer path instead **[V]** (https://github.com/NixOS/nix/pull/2670).
- RFC 41 closed by e-user and edolstra after a call, the stated direction being a minimum solution via the installer with few changes to Nix/NixOS **[V]** (https://github.com/NixOS/rfcs/pull/41).
- Lix's issue #546 shows the same position there: "Nix is unaware of SELinux", no decision, nobody committed to maintain it **[V]**. Lix is the more likely place to land variant 1 as an optional feature **[I]**.

### 3.3 Verdict

Most invasive (libstore, daemon privilege, possibly derivation/NAR format). A label that is *derived from path regexes at registration time* (variant 1) is the only version with a chance, because it adds no identity-bearing data. Pros: always-correct labels for every registration route, including substitutes and `nix copy`. Cons: contradicts maintainers' stated position, requires daemon in a MAC-admin domain, ties Nix to libselinux and a policy path. **Upstream acceptability to NixOS/nix: low** now; moderate in Lix as an optional build flag **[I]**.

---

## 4. Option 3: mount-level labelling (`context=` / `fscontext=` / `defcontext=` / genfscon)

### 4.1 How it works **[I, documented in mount(8) and the Android implementation doc]**

- `context=X` labels every inode of the mount with X and ignores/forbids per-file labels.
- `fscontext=X` labels the superblock only; `defcontext=X` is the label for unlabelled files; `rootcontext=X` labels the root inode.
- `genfscon` assigns labels in policy to filesystems without xattr support (proc, vfat, some FUSE).
- Android makes the same split: filesystems lacking xattrs get `genfs_contexts`; others get `context=` in fstab/init, and "changes to genfs_contexts might not affect in-core inodes" (reboot/remount needed) **[V]** (https://source.android.com/docs/security/features/selinux/implement).

For NixOS: mount (or bind-remount) `/nix/store` with `context=system_u:object_r:nix_store_t:s0`. Since NixOS already bind-remounts the store in stage 2 **[V, 1.3]**, adding the option is a one-line module change. Note that `context=` cannot be applied via a *remount* of an already mounted superblock with a different context; it must be present when the superblock is first mounted, or applied on a fresh mount (e.g. an overlay or loopback) **[I]**.

### 4.2 What this loses

- **Entrypoint types.** Domain transitions use `type_transition`/entrypoint rules keyed on the executable's *file type*. With one type for everything, `nix_store_t` must be an entrypoint for every domain, and `init_t` executing it would go to whichever single rule exists: no per-service domains. Essentially every `exec` from store results in the same new domain or no transition **[I]**.
- No per-file distinctions: systemd unit files, libraries, config, secrets, executables all one type. Policy can't allow "read unit files but not run binaries".
- `.links` and hardlink problem disappears (a feature: one label).

### 4.3 Workarounds for domain transitions without file types

1. **systemd `SELinuxContext=`** on units: systemd calls `setexeccon` before exec so the service enters the named domain without needing a per-binary label. Discussed by RossComputerGuy, with an objection from arianvp that systemd's access-manager checks would still need labelled unit files **[V]** (https://discourse.nixos.org/t/selinux-on-nixos/62729). Domain needs `entrypoint` on `nix_store_t` and a `dyntransition`/`transition` allow from `init_t` **[I]**.
2. **Generated per-service transition rules on *paths***, enforced by NixOS: the NixOS module compiles `systemd.services.<name>.serviceConfig.SELinuxContext = "system_u:system_r:<name>_t:s0"` from per-service declarations. Everything is determined by the module system, not by file labels. This is how container runtimes handle it (`spc_t`, `container_t` are set by the runtime) **[I]**.
3. **Mixed**: use `defcontext=nix_store_t` as the default for unlabelled files, and still allow `setfiles` on selected files (`context=` forbids this, `defcontext=` permits explicit xattrs) **[I]**. That is a graceful degradation path for Option 1: unlabelled paths get a safe, deny-by-default type instead of `unlabeled_t`.
4. **Exec through SELinux-aware launchers** such as NixOS-generated wrappers that call `setexeccon` (like `runcon`). Not nice, but declarative **[I]**.

### 4.4 Verdict

Needs nixpkgs only; trivial to implement; useful as a **baseline** (stage-0 bring-up, `defcontext` fallback) but cannot give per-service confinement through file types, so confinement quality is limited to what `SELinuxContext=` plus systemd can give. Upstream acceptability: high (just mount options), but it is a weak security story, and the design is closer to "process confinement only" as sudoBash418 argued **[V, Discourse thread]**.

---

## 5. How comparable systems solved it

| System | How labels are assigned | Lesson for NixOS |
|---|---|---|
| **Guix** | Not at all by default. Manual: a CIL policy for guix-daemon labels only paths matching `/gnu/store/.+-(guix-.+|profile)/bin/guix-daemon` as `guix_daemon_exec_t`; user must `restorecon -vR /gnu` after each upgrade. No policy for Guix System ("provides no SELinux base policy"). Symlinks keep their own labels. **[V]** https://guix.gnu.org/manual/en/html_node/SELinux-Support.html | Same path-regex idea; same spoofing concern; and it is manual. Real bugs: systemd denied read on `current-guix` symlink (https://issues.guix.gnu.org/47985), "guix-daemon fails on SELinux/systemd distros" (https://issues.guix.gnu.org/62487). Even the closest analogue has no full-system solution. |
| **Fedora/RHEL + Nix** | Nix on Fedora relies on `semanage fcontext` rules and manual `restorecon`; Determinate ships `nix.pp` with `nix.fc` (above) **[V]**. The Fedora `nix` package change page says only that `/nix` is created by tmpfiles.d and FESCo approved the exception, nothing on labels **[V]** (https://fedoraproject.org/wiki/Changes/Nix_package_tool). Open bug: labels not applied to `.links` hardlinks (Bugzilla 2416675); upstream selinux-policy issue #2963 and PR #3454 mentioned there. | Non-NixOS hosts treat the store as ordinary data with a fixed per-directory type; it is a "run Nix on SELinux" problem, not a "confine NixOS" one. Do not conflate the two when upstreaming. |
| **ostree / Silverblue / CoreOS** | `libostree` has an `OstreeSePolicy` that loads policy *from the tree being committed* (`etc/selinux`, falling back to `usr/etc/selinux`), reads `SELINUXTYPE=` and opens a `selabel` handle; `ostree_sepolicy_restorecon` / `setfscreatecon` apply labels at commit and checkout time, so **labels are stored in the OSTree objects** (xattrs are part of the content hash) **[V]** (ostree-sepolicy.c; https://ostreedev.github.io/ostree/reference/ostree-SELinux-policy-management.html). Layered content needs reset to the base policy's defaults; layered policy modules are not honoured, so Bluefin works around it with a systemd + tmpfiles relabel at boot **[V]** (https://gitlab.com/fedora/ostree/sig/-/issues/45). | The closest model to "labels baked at image build, with the policy that ships in the image". It needs a content-addressed store that *includes* xattrs. Nix's store hash does not, so labels would be a derived layer, not part of path identity. |
| **Android** | Image build applies `file_contexts` to the filesystem image; upgrades re-apply changed `file_contexts` to system/userdata; other partitions get `restorecon_recursive` from init after mount; xattr-less filesystems use `genfs_contexts`, mounts can use `context=` **[V]** (https://source.android.com/docs/security/features/selinux/implement). | Build-time labelling of a read-only image from path regexes: the model for the "bake an erofs metadata layer" idea (Option 5). Android is an image distribution; NixOS has per-path mutable store content, so only the system closure can be baked. |
| **Bottlerocket** | `filecon` rules in `packages/selinux-policy/fs.cil`; every file and directory is covered by a rule; images are built in containers, so a test asserts no container labels leak outside `/local`; labels persist across updates **[V]** (https://github.com/bottlerocket-os/bottlerocket/pull/1729). | Important lesson: **a test that every shipped path has an intentional label** is what keeps this maintainable. Build the same check for the closure. |
| **Flatcar** | `/usr` files were `unlabeled_t`; plan is `setfiles -r <root> -D` on the image at build time (with `security.sehash` to make later `restorecon -rD /` cheap), then relabel on boot/update **[V]** (https://github.com/flatcar/Flatcar/issues/673). Not finished at the time of the thread. | `-D` / sehash short-circuit is directly useful for boot-time labelling of an immutable tree. |
| **composefs/erofs** | composefs is an overlayfs with a metadata-only EROFS image over a content-addressed lower layer with fs-verity; metadata (including xattrs) lives in the image **[V for design, no SELinux detail in the article]** (https://lwn.net/Articles/933616/). bootc/composefs-boot builds the image after labelling. | A natural place to put per-path labels while leaving the store untouched. Matches ElvishJerricco's fs-verity + erofs + overlayfs design cited in the NixOS Discourse thread **[V]**. SELinux behaviour of overlayfs with a metacopy erofs layer is unverified here. |

---

## 6. Option 5 (hybrid worth stating on its own): baked metadata overlay

### How it works **[I, built from components verified above]**

1. At system build, a derivation takes the system closure's path list (`closureInfo`), the generated `file_contexts`, and computes labels for every file in the closure (either `setfiles -r` against a faked tree, or `selabel_lookup` per path via a small tool).
2. It emits a **metadata-only erofs image** whose entries carry `security.selinux` xattrs and `overlay.redirect`/`metacopy` pointing at the real store files (the composefs layout).
3. Stage 2 mounts `overlay` with the erofs layer on top and the real `/nix/store` as a data-only lower layer, then exposes it as `/nix/store`. The underlying store is never modified, and Nix still uses the real directory.
4. Paths not in the closure fall through unlabelled (labelled by `defcontext=` if possible).

### Assessment

- Pros: store stays immutable; zero Nix changes; labels are reproducible functions of (closure, policy), so they are part of the generation (rollback also rolls back labels); handles `.links` collisions because the overlay assigns labels per path; pairs with the fs-verity/dm-verity secure-boot work.
- Cons: extra mount layer and inode/dentry overhead (composefs article notes doubled inodes/dentries **[V]**); the Nix daemon must keep using the real store (writes to `/nix/store` are in the lower, not the overlay), so builds, `nix-shell` and user profile paths are not covered; the image rebuilds per generation (size roughly 10-50 MB per generation for a typical closure **[I, guess]**); kernel overlayfs+SELinux interactions (label taken from the layer inode, creator-label rules, `metacopy`) need testing; numinit and RossComputerGuy already raised open questions about metacopy performance with SELinux and bind mounts in stage 2 **[V]** (Discourse).
- Upstream: nixpkgs-only, and consistent with the direction the community has already prototyped (ElvishJerricco's design), so acceptability is moderate-high as an opt-in module. **[I]**

---

## 7. Related NixOS-specific problems

| Problem | Status | Notes |
|---|---|---|
| **Exec through symlinks** (`/run/current-system/sw/bin/foo`, profile symlinks) | SELinux uses the *target inode's* label for exec transitions; the symlink's own label matters only for traversal/readlink **[I]** (Guix confirms: "symlink labels are independent of their targets", and links inherit the directory's label, so systemd read of `current-guix` was denied **[V]**). | Need `lnk_file` read allow rules for `init_t`/callers on `/run/current-system`, `/etc/static`, and profile links, plus a correct label for symlinks the module creates in `/etc` and `/run`. The labels of tmpfs/`/run` symlinks come from `type_transition` or `restorecon` at activation, which NixOS controls. |
| **makeWrapper scripts** | A wrapper is a shell script (or `.foo-wrapped` binary) in `bin/`; labelled `bin_t` by the regex; it execs the real binary in another store path, which is also `bin_t` | No domain change unless the final binary has its own exec type, so domain transitions are fixed by the *final* exec target, not the wrapper. Services should be started by systemd with `ExecStart=` pointing to the real binary or with `SELinuxContext=`. Wrappers that exec interpreters (`bash`, `python`) will run in the caller's domain **[I]**. |
| **setuid wrappers in `/run/wrappers`** | `/run/wrappers` is a tmpfs created by a systemd mount unit and populated by activation (`security.wrappers`, uses `setcap`/setuid; `nosuid` is applied to the store only) **[V]** (nixos/modules/security/wrappers/default.nix lines ~125-146, ~311-334). | Files there are tmpfs inodes, so they can carry per-file xattrs at activation (`chcon`/`setfiles` in the same activation step, or `type_transition` rules for tmpfs). Because they are outside the store they can have real exec types (`passwd_exec_t`, `su_exec_t`...). This is a good place to start. |
| **`/etc` as symlinks into the store** | `/etc/static` -> store, `/etc/foo` -> `/etc/static/foo` -> `/nix/store/...-etc/etc/foo` **[I]** | The *target* file's label is what governs reads, so it must be `etc_t` or the policy-specific type, which requires the store regexes to produce them; for example `/nix/store/[^/]+-etc/etc/shadow` should be `shadow_t`. The `etc` derivation is a single, known path per generation, so a generated exact-path rule (see 2.4) works well. Secrets should never live in the store. |
| **systemd units pointing at store paths** | Unit files live under `/etc/systemd/system` symlinks into the store; systemd's access control checks the *unit file* label **[V]** (Discourse: "systemd Access Manager ... would not work because store files are unlabeled"; Bugzilla 2416675 for the denial). | Unit file labelling is the first place the regexes matter. Generate exact-path rules for the system's unit dir. |
| **initrd / stage 1 policy loading** | Policy load must happen before first labelled access in stage 2; `systemd` loads policy early and `semodule`-installing at boot caused a ~40s stall in a prototype **[V]** (tristanxr). | Build the policy *binary* at system build time (`policy.NN`) and let systemd load it from a fixed path, no `semodule` at boot. Match the kernel's policy version (prototype hit policy v33 vs v34 mismatch **[V]**). In scripted stage 1 / systemd stage 1, put the binary and `file_contexts.bin` in the initrd if labelling happens before stage 2 **[I]**. |
| **Impermanence / tmpfs root** | Tmpfs inodes support xattrs (security.* since kernel 4.x with `CONFIG_TMPFS_XATTR`), and new files are labelled by creation transitions or the parent label, so tmpfs `/` starts as `tmpfs_t` and must be relabelled by `setfiles` at boot after policy load **[I]**. | The persistent store (separate partition) keeps its labels across boots; the ephemeral root does not, so relabel cost is paid *every boot* for root-level content, which is small. Persistent dirs (bind-mounted from `/persist`) need labels consistent with their mount point; impermanence bind mounts need `restorecon` after mount. |

---

## 8. Ranked recommendation

1. **Option 1 variant A, generated from the closure.** Ship a generic store `.fc` (bin/lib/share/etc/unit dirs, per Etbe's single-rule advice) *plus* machine-generated exact-path rules for per-service executables, unit files and the `etc` derivation. NixOS labels the system closure at activation/boot before the ro remount, using `setfiles -D`-style skip logic. Disable or accept `auto-optimise-store` limits. **Nixpkgs only, no Nix change, opt-in.** Highest chance of getting something enforcing quickly and of upstream merging.
2. **Option 5 (erofs/overlay baked labels) as the follow-up** once the label *function* is stable. It removes relabel cost, drift and the `.links` collision, rolls back with generations, and aligns with in-flight verity work. Needs prototype data on overlayfs+SELinux.
3. **Option 3 only as scaffold**: `defcontext=`-style safe default for unlabelled store paths and `SELinuxContext=` for service domains, which is the minimum viable "process confinement" mode. Don't present it as the end state.
4. **Option 2 last**: only worth pursuing in Lix or as an optional flag; drop it for NixOS/nix core given the explicit "never" from the maintainer.

Upstream strategy: frame it as "NixOS-side, optional, no Nix change, no change to store identity", cite that `ignored-acls` already tolerates the label **[V]**, and address the Ekleog/Eelco objections head-on: exec types are only granted to *hash-exact* paths computed from the system closure, so a daemon client cannot forge a trusted path (this is the answer to the RFC 41 spoofing concern) **[I]**.

---

## 9. Open questions only a prototype can answer

1. Does an `ignored-acls`-preserved `security.selinux` label survive `nix-store --optimise`, `--repair`, `nix copy`/substitution into a store that already has labelled paths, and GC + re-substitution? Which Nix/Lix release introduced the default ignore list?
2. Real relabel time and memory for `setfiles` over a 300k-inode system closure on NVMe and on a slow disk; effectiveness of `security.sehash`/`-D` as a skip.
3. Does overlayfs (erofs metadata lower + data-only store lower, `metacopy=on`) present the erofs-layer `security.selinux` value to the kernel for permission checks, and what is the performance cost? Can the Nix daemon still write to the real store at the same time?
4. How should `.links` be treated: disable `auto-optimise-store`, or make optimisation SELinux-aware (hardlink only when the intended label matches)? Measure disk cost.
5. Which executables genuinely need distinct exec types versus `SELinuxContext=`? Prototype with `sshd`, `nginx`, `systemd-logind`, `nix-daemon` and measure how many generated exact-path rules a typical system produces, and whether `file_contexts` lookup time stays acceptable.
6. Domain for `nix-daemon` and for build users: the daemon needs `relabelto`/`mac_admin` if it ever labels, and builders create files whose labels come from creation-time transitions (`default_t` currently, per the Lix report) so does labelling after build in a separate step suffice? How are sandboxed builds (mount namespaces, `/nix/store` bind mounts) treated under a confined `nix_build_t`?
7. Initrd: can the binary policy and `file_contexts.bin` be loaded in systemd stage 1 without `semodule` at boot, and what is the minimum set of rules to boot to stage 2 enforcing?
8. Which refpolicy version and which patches (store `.fc`, `/etc/static` links, `/run/current-system`, `/run/wrappers`) are needed; can refpolicy upstream take a NixOS optional module?
9. Impermanence: confirm relabel of tmpfs root and persistence bind mounts is correct on every boot and does not race service start.
10. Do wrapper scripts (`makeWrapper`, `wrapGAppsHook`) and `/run/current-system/sw/bin` symlinks cause unexpected denials for `init_t`/`systemd --user` exec paths?

---

## Sources

- Nix source: https://github.com/NixOS/nix (src/libstore/posix-fs-canonicalise.cc, src/libstore/include/nix/store/local-settings.hh, src/libstore/local-store.cc), manual https://nix.dev/manual/nix/2.28/command-ref/conf-file.html
- Nix PR #2670: https://github.com/NixOS/nix/pull/2670 ; issue #5327: https://github.com/NixOS/nix/issues/5327 ; RFC 41: https://github.com/NixOS/rfcs/pull/41
- Lix #546: https://git.lix.systems/lix-project/lix/issues/546 ; Lix #486: https://git.lix.systems/lix-project/lix/issues/486 (title seen only)
- NixOS Discourse: https://discourse.nixos.org/t/selinux-on-nixos/62729 ; wiki: https://wiki.nixos.org/wiki/SELinux_workgroup ; write-up: https://tristanxr-com.pages.dev/post/selinux-on-nixos
- Coker libselinux subs patch: https://lore.kernel.org/all/7853167.K65cXu0y11@neuromancer/
- nixpkgs stage-2-init.sh and wrappers: https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/system/boot/stage-2-init.sh, .../security/wrappers/default.nix
- Determinate nix.fc: https://github.com/DeterminateSystems/nix-installer/blob/main/src/action/linux/selinux/nix.fc
- Red Hat Bugzilla 2416675: https://bugzilla.redhat.com/show_bug.cgi?id=2416675 ; Fedora Nix change: https://fedoraproject.org/wiki/Changes/Nix_package_tool
- Guix: https://guix.gnu.org/manual/en/html_node/SELinux-Support.html ; https://issues.guix.gnu.org/62487 ; https://issues.guix.gnu.org/47985
- ostree: https://ostreedev.github.io/ostree/reference/ostree-SELinux-policy-management.html ; https://raw.githubusercontent.com/ostreedev/ostree/main/src/libostree/ostree-sepolicy.c ; https://gitlab.com/fedora/ostree/sig/-/issues/45
- Android: https://source.android.com/docs/security/features/selinux/implement
- Bottlerocket: https://github.com/bottlerocket-os/bottlerocket/pull/1729 ; Flatcar: https://github.com/flatcar/Flatcar/issues/673
- composefs: https://lwn.net/Articles/933616/
