# SELinux on NixOS: policy base, build/deployment model and system integration

Scope: the policy and system-integration side. The `/nix/store` labelling question is covered elsewhere (see `03-store-labelling-design.md`) and appears here only where policy depends on it.

Date of research: 2026-11-21.

Conventions:
- **[V]** = verified in this session, by reading upstream source (shallow clones of the repos below) or a fetched page.
- **[I]** = inference or recommendation. Not verified, or it needs a prototype.
- Local clones used: `SELinuxProject/selinux` (main, VERSION `3.12-rc3`, HEAD 2026-11-20), `SELinuxProject/refpolicy` (VERSION `2.20260922`), `fedora-selinux/selinux-policy` (rawhide), `systemd/systemd` (main), `bottlerocket-os/bottlerocket-core-kit`, `NixOS/nixpkgs` (sparse, master 2026-11-21), `NixOS/nix`, `dracut-ng/dracut-ng`.
- `gh api` against SELinux repos was refused ("sessions are bound to configured repositories"). `git clone` and `raw.githubusercontent.com` worked, and that is what I used.
- Some statements about newer upstream features are from `main`, not a release. They are flagged.

---

## 0. Executive summary

1. **Policy base: refpolicy, built modular, with a CIL-level escape hatch.**
   - It is already in nixpkgs as `selinux-refpolicy` (2.20250923). It is GPL-2.0 and has about 760 service modules.
   - Its file contexts are path-regex based, with an official alias mechanism (`file_contexts.subs_dist`). That mechanism is the right tool for mapping `/run/current-system/sw/*` to `/usr/*`.
   - Fedora's policy is a fork of refpolicy with about 1,360 contrib modules. It is more complete, but it carries RHEL/Fedora assumptions and has no NixOS-specific advantage.
   - A hand-written CIL policy (Bottlerocket-style, about 2,200 lines) is the right model for a minimal appliance. It is not a general-purpose NixOS base.
2. **Build model: build the whole policy inside Nix derivations, with no mutable store at runtime.**
   - Use `semodule --path/--store-path` (alternate root and store root) plus `semodule -B`, or `secilc` directly, producing `policy.NN`, `file_contexts`, `seusers` and `booleans`.
   - Install the result into `/etc/selinux/<type>/` as part of the system closure, so `/etc/static` symlinks it.
   - This works with unmodified libselinux `load_policy`. `main` also gains `/usr/lib/selinux` fallback roots and `ro-store-root`, which are designed for exactly this.
3. **Boot flow: load policy before activation, not after.**
   - Stock NixOS runs `$systemConfig/activate` (including `setup-etc`) *before* `exec systemd`. If systemd's built-in loader does the loading, everything activation creates carries no label.
   - A prototype can start with systemd's built-in loader. The robust design is to run `load_policy -i` at the top of `stage-2-init.sh`, or in the initrd.
   - Either way systemd itself must be built with `withSelinux = true`.
   - PID 1's domain is computed from the label on the *systemd binary*. That binary lives in the store, so this is where policy and the store-labelling work meet.
4. **Staged path**: permissive plus a tiny CIL policy, then refpolicy "targeted-style" (unconfined by default), then stricter per-service confinement. The per-service domains are best selected by `SELinuxContext=` in unit files, driven by NixOS options. That avoids needing per-package store labels. The user-facing process-launch hierarchy still needs a decision (see section 9).

---

## 1. Policy base choices

### 1.1 Comparison

| | refpolicy | Fedora `selinux-policy` | Hand-written CIL (Bottlerocket-style) | Android sepolicy |
|---|---|---|---|---|
| Source language | M4 macros → `policy.conf`/`.pp` (CIL internally via libsemanage) | Same (fork of refpolicy) | CIL directly | CIL (+ M4 `.te` sources converted to CIL at build) |
| Size [V] | ~413 `.te`, 763 files in `policy/modules/services` | 1,364 files in `policy/modules/contrib`, ~96k `.te` lines | 2,188 lines of `.cil` | n/a |
| Build | `make` (modular default: `MONOLITHIC = n` in `build.conf`; monolithic supported) | `make`, `build.conf` `DISTRO = redhat`, `TYPE = mcs` | `secilc --policyvers=N *.cil` | AOSP build, CIL |
| Licence [V] | GPL-2.0 (`COPYING`) | GPL-2.0 (`COPYING`) | Bottlerocket's: Apache-2.0 OR MIT | AOSP: Apache-2.0 |
| Distro knobs | `DISTRO=redhat/gentoo/debian` (`distro_*` m4 ifdefs), `SYSTEMD=y` | `DISTRO=redhat`, plus `dist/` overlays (`targeted`, `minimum`, `mls`) | none | none |
| File-context aliasing | `config/file_contexts.subs_dist` | `config/file_contexts.subs_dist` (includes ostree paths) | file contexts come out of CIL `filecon` | n/a |

Sources:
- refpolicy build config: `refpolicy/build.conf`, `refpolicy/Makefile` lines ~177-290 (`DISTRO`, `SYSTEMD`, `TYPE`), `refpolicy/doc/BUILD_INSTALL.md`.
- `refpolicy/Rules.modular` and `refpolicy/Rules.monolithic`.
- Fedora: `fedora-selinux/selinux-policy/README.md` ("Fedora `targeted` policy uses: `DISTRO=redhat UBAC=n DIRECT_INITRC=n MONOLITHIC=n MLS_CATS=1024 MCS_CATS=1024 UNK_PERMS=allow NAME=targeted TYPE=mcs`"), `dist/`, `config/file_contexts.subs_dist`.
- Bottlerocket: `bottlerocket-core-kit/packages/selinux-policy/` (`*.cil`, `selinux-policy.spec`).
- Android: https://source.android.com/docs/security/features/selinux/build
- Upstream repos: https://github.com/SELinuxProject/refpolicy, https://github.com/fedora-selinux/selinux-policy

### 1.2 refpolicy facts relevant to a non-FHS distro

- **[V] `DISTRO=nixos` does nothing today.**
  - nixpkgs passes `DISTRO=nixos` (`pkgs/by-name/se/selinux-refpolicy/package.nix`).
  - The refpolicy `Makefile` only special-cases `ubuntu`, `debian`, `gentoo`, `redhat` for tooling.
  - It just emits `-D distro_nixos=true` (Makefile lines ~210-216), and no module tests `distro_nixos`.
  - So an upstream `distro_nixos` is a natural, small, upstreamable hook. Today 42 modules test `distro_redhat` and 53 test `distro_gentoo`/`distro_debian`.
- **[V] File-context path equivalence.**
  - `config/file_contexts.subs_dist` is installed to `contexts/files/file_contexts.subs_dist`.
  - Format: `alias_path original_path`. It is aliasing, not sed-style substitution.
  - The shipped file maps `/bin`, `/sbin`, `/lib`, `/lib64`, `/usr/sbin` to the `/usr/...` equivalents. It also maps `/etc/systemd/system` to `/usr/lib/systemd/system`, and `/var/run` to `/run`.
  - Local `file_contexts.subs` is applied first, then `.subs_dist` (`libselinux/src/label_file.c`, `selabel_sub_key()`).
  - A NixOS-specific file can add `/run/current-system/sw /usr` (and `/run/current-system/sw/bin` is then covered through the existing `/usr/sbin /usr/bin` chain). Note that this changes only how a *path string* is looked up. It does not make store files carry those labels. See section 7.
- **[V] Wildcard subs (main only, unreleased).**
  - `selabel_file(5)` in main documents a `*` whole-path-component wildcard in the substitution source (e.g. `/var/lib/extensions/* /`).
  - `refpolicy` main already uses it for systemd-sysext, and notes it needs libselinux that includes SELinuxProject/selinux commit `3340da2` (2026-09-04).
  - This could express `/nix/store/*/bin /usr/bin`-like equivalences. **[I]** I have not tested it. Be careful: `*` matches exactly one non-empty component and the *last*-component form only applies when a further `/` follows.
  - Because nixpkgs pins userspace 3.11 (`policycoreutils` 3.11), this needs a bump to 3.12 (currently `3.12-rc3` in main).
- **[V] Modular install is not self-contained.**
  - `make install` in modular mode only installs `base.pp` and module `.pp` files into `$(sharedir)/<NAME>` (`/usr/share/selinux/<NAME>`).
  - `make load` runs `semodule -s NAME -i ... ` (`Rules.modular` lines ~60-80).
  - Producing `policy.NN` therefore needs `semodule -B` against a store. nixpkgs currently builds with `make all install install-headers install-docs`, i.e. only the `.pp` files. The "first boot stalls 40 s while a script runs semodule" in the Tristan Ross write-up is the consequence. See https://tristanxr-com.pages.dev/post/selinux-on-nixos
  - **Monolithic** (`MONOLITHIC=y`, `Rules.monolithic`): `make install` produces `policy.<ver>` and `file_contexts` directly with `checkpolicy` + `setfiles -c`, no semodule or store. That is the simplest purely-Nix path, but you lose per-service module contribution and must rebuild all policy for any change. Modular assembly in the derivation (below) keeps modularity at build time.
- **[V] Policy knobs available at build time**: `TYPE` (standard/mcs/mls), `UBAC`, `UNK_PERMS` (deny/allow unknown permissions), `OUTPUT_POLICY` (kernel policy version), `OUTPUT_MODULE`, `CUSTOM_BUILDOPT`, `MLS_CATS`, `MCS_CATS`, `NAME`. `booleans.conf` provides tunable defaults; modules are enabled via `modules.conf` (`base`/`module`/`off`).
- **[V] Tunables**: `gen_tunable()` in module `.te` files (e.g. `ssh.te`: `allow_ssh_keysign`, `ssh_sysadm_login`). Defaults are baked in from `booleans.conf` when the policy is built.
- **[V] Unconfined**: refpolicy has `policy/modules/system/unconfined.te` (`unconfined_t`, `unconfined_execmem_t`). It does not ship a "targeted" `TYPE`. Fedora gets "targeted" via `dist/targeted`, `TYPE=mcs`, `UBAC=n`, `UNK_PERMS=allow` and permissive/unconfined defaults. A targeted-style refpolicy is therefore reachable but needs the module list, `unconfined_*` modules and seusers (`__default__:unconfined_u`) selected deliberately.
- **[V] Other refpolicy features useful to us**: `udica-templates/` (container policy templates), `doc/SECURITY_GOALS.md`, `support/` scripts, `make install-headers` plus `sepolgen` interface database (`/var/lib/sepolgen/interface_info`, needed for `audit2allow -R`, Makefile line ~597).
- **[V] systemd-aware**: `SYSTEMD=y` sets `init_systemd`. `systemd.fc` labels `/usr/lib/systemd/system(/.*)?` as `systemd_unit_t`, and `init.fc` labels `/usr/lib/systemd/systemd` as `init_exec_t`.
  - **[I]** On NixOS these paths do not exist. The prefix is `/nix/store/<hash>-systemd-<ver>/lib/systemd/...`, and the `/etc/systemd/system` to `/usr/lib/systemd/system` alias covers only the `/etc`-visible symlinks.
  - A NixOS-specific `.fc` overlay (see section 7) is needed for these.

### 1.3 Fedora's selinux-policy

- **[V]** It is based on refpolicy (README: "SELinux policy based on refpolicy used in Fedora, RHEL and CentOS Stream"). Default install path is `/etc/selinux/fedora-selinux` plus `/var/lib/selinux/fedora-selinux`.
- **[V]** `config/file_contexts.subs_dist` is richer in ostree-style aliases: `/var/home /home`, `/var/roothome /root`, `/usr/etc /etc`, `/sysroot/tmp /tmp`, `/var/usrlocal /usr/local`, etc. This shows the pattern for an immutable distro: alias the distro's own physical layout onto the canonical paths.
- **[I]** Adopting it brings more services confined and container-selinux-grade policy, but also more FHS/RPM assumptions (`/usr/lib/systemd`, `/usr/bin`, rpm file contexts), Fedora's release cadence and RHEL-specific booleans. It is 2x the size of refpolicy and is a downstream fork, so upstreaming NixOS-specific work should target refpolicy first (Fedora regularly merges from refpolicy).

### 1.4 Hand-written CIL

- **[V]** Bottlerocket's policy is 14 `.cil` files (~2,188 lines), compiled with `secilc --policyvers=32 *.cil`, which also emits `file_contexts` (secilc `-f/--filecontext`, `secilc.c`). It is installed into a "factory" tree, and the `semanage` store files are placed so that `semodule` still works:
  - `/usr/share/factory/etc/selinux/{config,fortified/contexts/files/file_contexts,fortified/policy/policy.32}`
  - `/usr/share/factory/var/lib/selinux/fortified/active/modules/100/<name>/{cil,lang_ext}` (`selinux-policy.spec`)
- **[V]** Bottlerocket's `/etc` is a tmpfs, so `selinux-policy-files.service` copies `/usr/share/factory/etc/selinux` into `/etc` early, ordered before units that need file contexts (`selinux-policy-files.service`, `systemd-after-selinux-policy-files.conf`).
- **[I]** For NixOS, writing everything in CIL is cheap for a prototype (tiny, auditable, no M4, no semodule). It does not scale to confining 100s of services. CIL is however the right *extension* language: refpolicy modules can be compiled to CIL (`semodule -c`/libsemanage `hll/pp`), and NixOS modules can contribute raw CIL fragments alongside.

### 1.5 Other options

- **[V]** Android uses CIL for the combined platform+vendor policy, with a precompiled binary whose SHA-256 inputs are checked at boot. If the hashes match, init loads the precompiled policy. Otherwise it compiles on the fly in 1-2 s (https://source.android.com/docs/security/features/selinux/build). This is a good template for NixOS: the policy can be recompiled at boot only as a fallback.
- **[V]** Guix does **not** ship a system-wide policy. It ships only `etc/guix-daemon.cil` for hosts where Guix runs on top of another distro's SELinux (https://guix.gnu.org/manual/devel/en/html_node/SELinux-Support.html). Key points from the manual: it is loaded with `semodule -i`, `/gnu` and `/var/guix` are relabelled with `restorecon -R`, the daemon runs as `guix_daemon_t`, executables matching `/gnu/store/.+-(guix-.+|profile)/bin/guix-daemon` get `guix_daemon_exec_t`, and "Guix System does not provide an SELinux base policy". Limitation: after each daemon upgrade the store must be relabelled with `restorecon -vR /gnu`.
- **[V]** The Determinate Nix page claims Nix works on enforcing SELinux systems "without carve-outs" (https://determinate.systems/nix/selinux). The page gives no policy details and I could not find policy source. See `03-store-labelling-design.md`.

### 1.6 Licences

- **[V]** refpolicy: GPL-2.0. Fedora policy: GPL-2.0. A policy module that is a derivative of refpolicy is GPL-2.0. Policy is data compiled into a binary blob, so NixOS can distribute it freely, but any contribution upstream into refpolicy must be GPL-2.0-compatible.
- **[V]** Userspace licences (`LICENSE` files in `SELinuxProject/selinux`): libselinux public domain; libsepol and libsemanage LGPL-2.1; checkpolicy, policycoreutils, python bindings GPL-2.0; secilc FreeBSD (BSD-2-Clause style). nixpkgs already records `gpl2Only` for refpolicy and policycoreutils.
- **[V]** Bottlerocket's `selinux-policy` package: Apache-2.0 OR MIT. This is useful if we want CIL we can license permissively.

---

## 2. Declarative policy management

### 2.1 What SELinux userspace normally does

- **[V]** The mutable store is `/var/lib/selinux/<type>/` (libsemanage `store-root`, default `/var/lib/selinux`) with `active/` and `tmp/` subtrees. `semodule -i/-r/-e/-d/-B` and `semanage` edit it. libsemanage then expands it and writes `/etc/selinux/<type>/policy/policy.NN`, `contexts/files/file_contexts{,.homedirs,.local,.bin}`, `seusers`, `booleans`, `users/*` and loads the policy.
- **[V]** Config location: `semanage.conf` at `/etc/selinux/semanage.conf` (`DEFAULT_SEMANAGE_CONF_LOCATION` in `libsemanage/src/Makefile`). `semodule -g PATH` selects an alternate config.

### 2.2 Knobs for building offline (all [V], read from source/man pages)

- `semodule -p/--path PATH`: "alternate path for the policy root" (`semanage_set_root`).
- `semodule -S/--store-path PATH`: alternate store root, e.g. `semodule -B -S /tmp/var/lib/selinux`. Documented examples: `semodule -B -p "/tmp"` and `semodule -B -S "/tmp/var/lib/selinux"` (`policycoreutils/semodule/semodule.8`).
- `semodule -N/--noreload`: do not load the policy into the kernel (needed in a sandbox).
- `semanage.conf` keys (`libsemanage/man/man5/semanage.conf.5`):
  - `root`, `store-root`.
  - `compiler-directory` (HLL compilers, default `/usr/libexec/selinux/hll`; the nixpkgs write-up hit exactly this FHS path).
  - `[load_policy]`, `[setfiles]`, `[sefcontext_compile]`, `[verify kernel]` sections (`path =`, `args =`) to relocate helper binaries to store paths.
  - `policy-version`, `expand-check`, `handle-unknown`, `ignore-module-cache`, `bzip-*`.
- **New in main (3.12-rc3, unreleased) [V]**:
  - `ro-store-root`: colon-separated list of extra *read-only* module-store roots, e.g. `/usr/lib/selinux`. Modules at the same priority/name under the writable `store-root` shadow ones from the RO root, and `semodule -r` on an RO-only module is refused (use `-d`).
  - `libselinux/src/selinux_internal.h`: `selinux_confdirs[] = { "/etc/selinux/", SELINUXFALLBACKDIRS }` where `SELINUXFALLBACKDIRS` defaults to `"/usr/lib/selinux/"`. The header comment says these are "read-only fallbacks for hermetic-/usr / factory-reset systems where /etc and /var may be empty at boot. Distributions can override the fallback list at build time."
  - `semanage_conf_path()` also searches a vendor dir for `semanage.conf`.
  - **[I]** For NixOS, setting `SELINUXFALLBACKDIRS` to a store path would let libselinux and `load_policy` read policy straight from the closure, with `/etc/selinux/config` the only thing in `/etc`. That is cleaner than copying, but depends on 3.12.
- **[V]** `secilc -o policy -f file_contexts -c VER *.cil` builds `policy.NN` and `file_contexts` directly, with no semodule or store. `selinuxuser`, `selinuxuserdefault`, `userrole` etc. are CIL statements (`secilc/docs/cil_user_statements.md`). `secilc` is a stable pure tool that is ideal inside a sandboxed derivation.

### 2.3 Proposed build pipelines

**Pipeline A: modular refpolicy plus offline semodule (recommended for the "real" policy).** **[I]**

```
selinux-refpolicy (modules .pp, per service)  +  NixOS-contributed modules (.te/.if/.fc → .pp, or raw .cil)
 └─ derivation "selinux-policy-<type>":
      export store = $TMPDIR/var/lib/selinux
      semodule --path $TMPDIR/root --store-path $store --noreload -g <generated semanage.conf> \
               -s <type> -X 100 -i base.pp -i <module>.pp ... -B
      install  $TMPDIR/root/etc/selinux/<type>/{policy/policy.NN, contexts/, seusers, booleans*, users/}  → $out/etc/selinux/<type>/
```

- Nothing mutable remains at runtime.
- Module priorities: use 100 for the base set (Bottlerocket also uses `modules/100`) and 400 for NixOS-site overrides. Priority semantics are standard libsemanage (override at higher priority).
- Pitfall to prototype: libsemanage wants helper paths and a version-compatible kernel policy. The write-up above hit policy version 34 versus kernel 33. Set `policy-version` in `semanage.conf` (or `OUTPUT_POLICY`) from `config.boot.kernelPackages.kernel` capabilities.

**Pipeline B: monolithic refpolicy.** `make MONOLITHIC=y` gives `policy.NN` and `file_contexts` with zero libsemanage involvement. Simple, but the module list is fixed at build and any module change recompiles everything (still just a derivation). Good for the first prototype.

**Pipeline C: pure CIL.** `secilc` over a concatenation of base CIL plus CIL fragments from `config.security.selinux.cil` (or per-service options). No M4, no store. Good for stage 1 (tiny policy).

All three emit the same runtime layout:

```
/etc/selinux/config                      (SELINUX=..., SELINUXTYPE=...)  generated by the NixOS module
/etc/selinux/<type>/policy/policy.NN
/etc/selinux/<type>/contexts/files/file_contexts{,.bin?}, file_contexts.subs_dist, file_contexts.subs
/etc/selinux/<type>/contexts/*_contexts, default_contexts, users/*
/etc/selinux/<type>/seusers, booleans(.subs_dist)
```

### 2.4 NixOS module design sketch **[I]**

- `security.selinux.enable`, `.mode` (`permissive`/`enforcing`), `.policyType`/`.policy` (package), `.kernelPatches` (see section 3).
- `security.selinux.modules.<name> = { te = ...; if = ...; fc = ...; cil = ...; enable = true; }`. Each service's NixOS module can contribute `security.selinux.modules.<service>`. A service module would also set `serviceConfig.SELinuxContext`.
- `security.selinux.booleans.<name> = true|false`. Two implementations:
  - (a) baked into `booleans.conf` at build time, so policy is fully declarative and any change rebuilds the policy;
  - (b) applied at activation with `setsebool` (volatile) or via `/etc/selinux/<type>/booleans.subs_dist`/semanage `booleans.local`. Option (a) fits Nix better.
- `security.selinux.fileContexts.local`, `.substitutions` write `file_contexts.local`/`.subs`/`.subs_dist` additions.
- `security.selinux.users` / `.logins` write seusers and users definitions. See section 5.
- Policy change is switched by `nixos-rebuild switch` through a post-switch activation step (`load_policy`), see section 6.
- Because policy is built from module-supplied pieces, a `nixos-rebuild build-vm` / NixOS test can run `sestatus` and check denials, giving a strong CI story (policy regressions are build failures; `checkpolicy`/`secilc` already fail on undefined types).

### 2.5 How other immutable or declarative systems cope

- **Bottlerocket [V]**:
  - Policy and `file_contexts` come out of `secilc` at image build. The type is `fortified`, enforcing and not disableable (`SECURITY_FEATURES.md`: "There is no way to disable it").
  - Factory dir plus copy-to-tmpfs-/etc service (see 1.4).
  - `/var/lib/selinux` is reset on boot by tmpfiles (`R`, `C`, `Z` lines in `selinux-policy-tmpfiles.conf`). The store is a throwaway cache and the factory copy is the source of truth.
  - Policy objectives: stop components modifying API settings, container archives and other containers' layers. MCS is used to isolate containers (https://github.com/bottlerocket-os/bottlerocket/discussions/1747).
- **Android [V]**: CIL plus a precompiled binary with hash verification (see 1.5). Init loads the policy before anything else. There is no runtime policy editing.
- **ostree/Silverblue/Fedora CoreOS**:
  - **[V]** libostree has `OstreeSePolicy` which loads the policy *from the tree being committed* (path, fd or commit) and labels files at commit time with `ostree_sepolicy_restorecon`/`..._get_label` (https://ostreedev.github.io/ostree/reference/ostree-SELinux-policy-management.html). Labels are assigned at image build, not by the runtime.
  - **[V]** Fedora's `file_contexts.subs_dist` carries `/usr/etc /etc`, `/var/home /home`, `/sysroot/tmp /tmp` aliases for this layout.
  - **[I, from memory, not re-fetched]** Fedora moved the module store to `/var/lib/selinux` (F23 change "SELinux policy store migration") so that `/etc/selinux` can be the compiled output and `/var` mutable. In rpm-ostree image composition the policy is compiled inside the compose and local `semodule`/`semanage` changes are not part of the immutable image story. The Anubis wall blocked fetching the F23 list post.
- **Guix [V]**: no system policy (see 1.5).
- **Pattern to copy [I]**: immutable systems compile the policy as part of the image, ship the compiled outputs as the only authoritative state, and treat the libsemanage store as a cache. NixOS can go one step further and keep the entire `/etc/selinux/<type>` tree store-backed via `/etc/static`.

---

## 3. Boot flow

### 3.1 What loads policy

- **[V] systemd PID 1 loads policy itself.**
  - `src/core/main.c` `initialize_security()` calls `mac_selinux_setup()` (`src/core/selinux-setup.c`).
  - That `dlopen`s libselinux (so "built with SELinux" means `HAVE_SELINUX`; `meson.build` option `selinux`) and then calls `selinux_init_load_policy(&enforce)`.
  - On success it computes PID 1's new domain with `mac_selinux_get_create_label_from_exe(SYSTEMD_BINARY_PATH)` and `setcon`s into it.
  - If loading fails and `enforce > 0` and no policy was previously initialised, it logs `LOG_EMERG` and `mac_selinux_setup` returns error ("Failed to load SELinux policy"). That is a **boot-halting failure** in enforcing mode.
  - In the initrd it does nothing unless `selinux_path()` (`/etc/selinux`) exists (`in_initrd() && access(sym_selinux_path(), F_OK) < 0` returns 0).
  - If policy was already loaded by someone else, `initialized` is detected via `getcon` ≠ `"kernel"`, and systemd still calls load/relabel logic.
- **[V] `selinux_init_load_policy()`** (`libselinux/src/load_policy.c`):
  - Reads `SELINUX=` from `/etc/selinux/config`; `enforcing=` on the kernel command line overrides it.
  - Mounts `/proc` and `/sys` if needed.
  - Mounts selinuxfs on `/sys/fs/selinux` (`MS_NOEXEC|MS_NOSUID`; `ENODEV` means the kernel has no SELinux, so `*enforce = 0`).
  - Sets enforce state, then `selinux_mkload_policy()`, which finds `policy.NN`, searching down from the kernel's max supported version via libsepol (`kernvers`/`minvers`).
- **[V] systemd's `/sys/fs/selinux` is mounted** by its early mount table (`src/shared/mount-setup.c`, entry "SELinux file systems" `/sys/fs/selinux`), and libselinux's own mount covers the case where systemd has not mounted it yet.
- **[V] After the load**, `mount_setup()` relabels `/dev`, `/dev/shm`, `/run` (and a few extra paths) with `label_fix` (`relabel_cb`), skipping `/run/initramfs` and `/run/nextroot`; it logs "Relabeled /dev/, /dev/shm/, /run/ ...". So the tmpfs/devtmpfs/`/run` labelling problem is handled by systemd itself, provided file_contexts are readable. It does **not** relabel `/etc`, `/var`, `/home`, `/root`, `/boot`, `/nix`.
- **[V] dracut precedent**: `dracut-ng/modules.d/77selinux/selinux-loadpolicy.sh` runs `chroot $NEWROOT /sbin/load_policy -i` at pre-pivot (with `/sys` bind-mounted), sets permissive if `/.autorelabel` exists or `enforcing=0`/`SELINUX=permissive`, then `restorecon -R /dev` and re-binds `/dev`. Its own FIXME says "this should really be done after we switchroot".
- **[V] Bottlerocket** loads policy during boot in enforcing mode. Policy is loaded by init/systemd. The exact loading binary was not examined.

### 3.2 NixOS stage 1 and stage 2

- **[V]** `nixos/modules/system/boot/stage-2-init.sh` runs `$systemConfig/activate` (line ~137) *before* `exec @systemdExecutable@ "$@"` (line ~158). `setup-etc` (the `/etc` creation), users/groups, the `/run/current-system` symlink, and so on, all run in that activation phase.
- **[V]** Nixpkgs master has no SELinux module. `nixos/selinux` is open as PR #396177 (`nixos/selinux: init`, RossComputerGuy), with `pkgs/top-level/config.nix: add selinux support` (#396168) and `linux-pam: allow building with SELinux support` (#591351). `fakeroot: hide selinux xattrs` (#580953) is also open. The tracking issue "Upstream SELinux support plan for Nix installer and runtime" is #507501. `selinux-refpolicy` and `selinux-python`/`semodule-utils`/`selinux-sandbox` packages exist (the PR #396155 init, #485821 `selinuxPackages`).
- **[V]** `pkgs/os-specific/linux/systemd/default.nix` has a `withSelinux ? false` argument wired to `-Dselinux=`. The default NixOS kernel config (`pkgs/os-specific/linux/kernel/common-config.nix`) has no `SECURITY_SELINUX`. It sets `SECURITY_APPARMOR = yes; DEFAULT_SECURITY_APPARMOR = yes` instead (lines ~825-826).
- **[V] Kernel config needed** (upstream `security/selinux/Kconfig`): `SECURITY_SELINUX` (default n, depends on `SECURITY_NETWORK && AUDIT && NET && INET`). `SECURITY_SELINUX_BOOTPARAM` adds `selinux=0/1` (default n; the NixOS wiki's config used `SECURITY_SELINUX_DEVELOP y`, `SECURITY_SELINUX_AVC_STATS y`, `DEFAULT_SECURITY_SELINUX n`). `SECURITY_SELINUX_DEVELOP` (default y) makes the kernel start permissive unless `enforcing=1`.
- **[V] Kernel parameters** (`Documentation/admin-guide/kernel-parameters.txt`):
  - `lsm=a,b,...` overrides `CONFIG_LSM` and `security=`.
  - `security=` is deprecated in favour of `lsm=`.
  - `selinux=0|1` (default 1), `enforcing=0|1` (default 0), and `enforcing` can be changed at runtime through `/sys/fs/selinux/enforce`.
- **[I]** With the NixOS default LSM list, AppArmor is the default "major" LSM. A prototype must select SELinux explicitly with `lsm=` (or `security=selinux`). I did not verify whether SELinux and AppArmor can be stacked on the kernel version in use, and the NixOS AppArmor module must be off in that mode.

### 3.3 Recommended boot design **[I, derived from the verified code paths above]**

Option 1 (simplest, prototype): rely on systemd's built-in loader.
- Requires `/etc/selinux/config` plus the `policy/policy.NN` and `contexts/files/file_contexts` to be present in `/etc` at the moment PID 1 starts. They are, because `activate` runs first.
- Downsides:
  - Everything created before the load (activation's `/etc` symlinks and copied files, `/var`, `/run/wrappers` setup if done earlier, `/nix/var/nix/*`) has no label or the default fs label. Only `/dev`, `/dev/shm`, `/run` are fixed up afterwards.
  - A one-shot `restorecon -R /etc /var /root /home ...` unit would be needed after the load, and again after any activation that creates files, or `activate` itself must `setfscreatecon`.

Option 2 (preferred): load the policy in `stage-2-init.sh` before `activate`.
- Run `${policycoreutils}/bin/load_policy -i` first (needs `/proc`, `/sys` mounted. The stage-2 script already runs after switch_root), then `activate`, so created files get labels from the loaded policy through type-transition and `setfscreatecon`-aware tools.
- Then `exec systemd`. Systemd sees `initialized` and re-uses it. The exec transition `kernel_t` to `init_t` happens because the systemd binary has label `init_exec_t` (see 3.4).
- Mirrors dracut's approach, at the equivalent point.
- Same effect in systemd-initrd (`boot.initrd.systemd.enable`): add a unit that runs `load_policy -i` on the new root before `initrd-switch-root`. In that mode PID 1 inside the initrd would skip loading if `/etc/selinux` is absent in the initrd (verified code above).

Option 3: policy in the initrd image itself (compiled policy as an initrd file, loaded in stage 1 before mounting root). Gives the strongest guarantee, since the whole filesystem including `/` labelled at mount time sees the policy. The cost is that policy changes need a new initrd (acceptable because NixOS generations already bind an initrd to each system).

- **Autorelabel [V]**: libselinux/policycoreutils use the flag file `/.autorelabel` (`fixfiles onboot` writes it; contents are flags like `-F`, `-N <boottime>`), consumed on Fedora by a systemd generator plus `selinux-autorelabel.service`. The generator and service are Fedora packaging (policycoreutils-rpm), not part of upstream `SELinuxProject/selinux`: `grep autorelabel` in the upstream tree only finds `fixfiles` and man pages, and I did not find them in `systemd/systemd`. **[I]** NixOS should ship its own equivalent: a oneshot early unit that runs `setfiles -F -r / file_contexts <dirs>` with the mutable directories, *excluding* `/nix/store`, whose labels come from elsewhere (see doc 03), and ideally runs when the policy store path (system generation) changes, not only on a flag file.
- **Labelling of virtual filesystems [V/I]**: `/proc`, `/sys` are labelled by genfscon (policy). `tmpfs` and `devtmpfs` use `fs_use_trans`/type-transition (inode labels computed at create time). `/dev`, `/dev/shm`, `/run` are then fixed by systemd's relabel (verified above). Mount options `context=`/`defcontext=`/`fscontext=` exist as a policy-independent alternative to per-file labels (useful for `/nix/store` read-only mounts. See doc 03).

### 3.4 PID 1's domain depends on the store label of the systemd binary **[V + I]**

`mac_selinux_get_create_label_from_exe()` (`src/shared/selinux-util.c`) calls `getfilecon_raw(exe)` on `SYSTEMD_BINARY_PATH` (= `libexecdir/systemd`, i.e. a `/nix/store/...-systemd-.../lib/systemd/systemd` path, `meson.build`) and then `security_compute_create(current_context, file_context, "process")`. The label is read from the *actual file xattr*, not from file_contexts. If the store file has no `security.selinux` xattr, the file gets the filesystem default (unlabeled/`defcontext`), no type_transition matches, and PID 1 stays in its initial domain (`kernel_t`-like "kernel"). All the policy's `init_t` rules are bypassed, which in enforcing mode makes the system unusable or fully unconfined depending on policy. Policy design must therefore be paired with whatever store-labelling scheme is chosen (doc 03): at least `systemd`, `udev`, `dbus`, etc. need entrypoint labels. The same applies to any binary used as a domain entrypoint. This is why "domain by unit" via `SELinuxContext=` (sections 7 and 8) is attractive as a fallback.

---

## 4. Staged plan

Stage 0: plumbing, no policy value.
- Kernel with `SECURITY_SELINUX` and `lsm=selinux` (or security=selinux), systemd with `withSelinux`, `policycoreutils`/`libselinux` in the closure. Boot with `enforcing=0`. A policy loaded via Pipeline C. Verify `sestatus`, `/sys/fs/selinux`, `getcon` and `ps -Z`.

Stage 1: permissive plus tiny CIL policy ("Bottlerocket-lite").
- One or two types (`kernel_t`, `init_t`, `unconfined_t`, `nix_store_t`, `etc_t`, `tmp_t`, ...), an `allow unconfined_t * *`-style catch-all, `unlabeled_t` allowed, and the minimal rules required for `systemd` to run in permissive mode without noise. Purpose: exercise `load_policy`, labelling of `/run`, `/dev`, `/etc`, `/var`, boot-time relabel, AVC logging, with an easy-to-read policy. **[I]** Estimated 100-300 lines of CIL.

Stage 2: "targeted-style".
- Switch to refpolicy (modular, Pipeline A) with `unconfined` module and `__default__:unconfined_u:s0-s0:c0.c1023` seusers so that login sessions and anything not explicitly confined run as `unconfined_t`. Confine a few exposed system daemons with real domains: `sshd`, `nginx`/`httpd`, `dbus`, `nix-daemon`, `NetworkManager`/`systemd-networkd`.
- Per-service domain selection through the NixOS option `SELinuxContext=system_u:system_r:<domain>_t:s0` in `serviceConfig`.
- Everything else is initially `unconfined_service_t` (refpolicy provides `init_t` → `unconfined_service_t` for unlabelled-exec services; **[I]** verify the exact type name in the checked-out version).
- Enforcing mode only when `journalctl`/auditd shows zero unexpected AVCs on the NixOS test matrix.

Stage 3: stricter.
- Add `SELinuxContext=` for most services, remove unconfined services, enable `ubac`, optionally MCS for containers (Bottlerocket model: per-pod MCS pairs), and consider `confined` users via `semanage login`-equivalent seusers.
- Possibly the policy distinguishes the Nix build sandbox (`nix_build_t`) from the daemon (section 6.4).

---

## 5. Userspace integration for a usable system

All items are **[V]** facts about what exists, followed by **[I]** NixOS-specific implications.

### 5.1 PAM and login contexts

- **[V]** `pam_selinux` comes from linux-pam built with `selinux` support. nixpkgs currently builds linux-pam with `(lib.mesonEnable "selinux" false)` (`pkgs/by-name/li/linux-pam/package.nix` line ~111). PR #591351 (open) addresses this. `nixos/modules/security/pam.nix` has no `pam_selinux` entries.
- **[I]** Needed: `open`-type `session` lines (`pam_selinux.so close` early in the stack, `open` after `pam_limits`, standard Fedora ordering), in `login`, `sshd`, `su`, `sudo`, `systemd-user` (via the PAM module options). It reads `default_contexts`, `users/*`, `failsafe_context`, `default_type`, `seusers` under `/etc/selinux/<type>/contexts/` (refpolicy ships `config/appconfig-{standard,mcs,mls}/`).
- **[V]** systemd `pam_systemd`-spawned user managers get contexts from `user@.service`/policy. The `systemd` source has `SELinuxContext=` and a user-context lookup via `get_default_context`. I did not walk through the user-session path in this session.

### 5.2 sshd, sudo, su, login

- **[V]** nixpkgs `openssh` (`pkgs/tools/networking/openssh/common.nix`) has `withSelinux ? false` / `--with-selinux`. The `sshd` PAM session must also include `pam_selinux`. `sshd` itself needs the `sshd_t` domain with `selinux_ssh` interfaces, and Fedora patches openssh for privsep contexts (**[I]**).
- **[V]** nixpkgs `sudo` has no SELinux references (count 0). sudo needs `--with-selinux` for `-r`/`-t` role/type switching, otherwise `sudo` just keeps the user's domain (acceptable early on).
- **[I]** The `su`/`login` from util-linux/shadow have no selinux hooks in nixpkgs (grep count 0 in `util-linux`/`shadow` package files).
- **[V]** `newrole`, `run_init`, `setfiles`, `load_policy`, `semodule`, `sestatus`, `setsebool` all come from `policycoreutils` (nixpkgs 3.11).

### 5.3 users, roles, seusers

- **[V]** Linux login to SELinux user mapping lives in `/etc/selinux/<type>/seusers` (`login:selinux_user:range`), SELinux users and role/level are defined in policy (`policy/users` in refpolicy, `userrole`/`selinuxuser` in CIL), and `contexts/users/*`, `default_contexts`, `failsafe_context` choose the context at login. `config/appconfig-*/seusers` ships in refpolicy; `config/local.users` is a local override template.
- **[I]** Declarative form: `security.selinux.logins = { "alice" = "staff_u"; "__default__" = "unconfined_u"; }` rendered to `seusers` at build time. Note the policy build is by then decided before `users.users` is evaluated, which is fine because the mapping is plain data.

### 5.4 systemd integration (units, SELinuxContext, access checks)

- **[V]** `SELinuxContext=` sets the exec context of the service process (man `systemd.exec.xml`: "Set the SELinux security context of the executed process... If prefixed by `-`, failing to set the context is ignored").
- **[V]** systemd's own SELinux *access checks* for unit operations use `unit->access_selinux_context`, which `load-fragment.c` fills by `fgetfilecon_raw()` on the unit file at load time ("Cache the SELinux context of the unit file here"). The class is `service`. If the unit has no context, systemd falls back to its own context and class `system` (`src/core/selinux-access.c`: `get_our_contexts`).
- **[I]** On NixOS, unit files are in `/nix/store/...-unit-foo.service/foo.service` (linked via `/etc/systemd/system`→`/etc/static/...`), so per-unit access checks (`systemctl start foo` allowed or denied per unit type) only work if those store files carry meaningful labels; otherwise every unit has the same (unlabeled/default) label and checks degrade to "can this domain start *a* service". That is acceptable for stage 2 and a real limit for stage 3. Mount-option labelling (`context=`) of the unit-file store path is not possible, because `/nix/store` is one mount. See doc 03.
- **[V]** Socket activation: `SELinuxContextFromNet=` for sockets (systemd NEWS).
- **[V]** systemd now has offline-root support for labelling: NEWS (current main) says tools that create files in `--root=`/`--image=` trees (`systemd-firstboot`, `-sysusers`, `-tmpfiles`) use the SELinux policy from the target tree, and "if the target `/etc/selinux/config` names an SELINUXTYPE=, that policy must be present in the target". That supports building NixOS images/VMs with correct labels.

### 5.5 dbus, udev, polkit

- **[V]** nixpkgs `dbus` builds with `-Dselinux=disabled` (`pkgs/by-name/db/dbus/package.nix` line ~129, with `# ToDo: optional selinux?`). With it disabled, dbus-daemon does not mediate messages by SELinux (`send_msg` checks, `dbus_contexts`, `selinux` policy elements). Enabling it requires `libselinux` and `audit`. systemd 's `systemctl` bus permission checks (above) are evaluated in PID 1, independently of dbus-daemon.
- **[V]** `udev`: no SELinux references in the nixpkgs `udev` package (count 0). systemd-udevd labels device nodes in `/dev` using `label_fix`/selabel when systemd is built with SELinux, so enabling `withSelinux` should cover it (**[I]**, the udev code is built from the same systemd source).
- **[I]** `polkit`/`pkexec` have no policy dependency at first.

### 5.6 Logging: audit, AVC denials, audit2allow

- **[V]** Kernel requires `AUDIT` for SELinux (`Kconfig` `depends on ... AUDIT`). AVC denials go to the audit subsystem. With no `auditd` they are `printk`ed to the kernel log, so `journalctl -k | grep avc` works from day one. `libselinux/src/avc_internal.c` formats `avc:` records and `op=setenforce lsm=selinux enforcing=%d`.
- **[V]** NixOS has `nixos/modules/security/audit.nix` (the module comments mention `auditctl --signal`) for `auditd`/rules. systemd's `SELinuxContext` failures appear as exit status `EXIT_SELINUX_CONTEXT` (`systemd.exec.xml`).
- **[V]** `audit2allow`/`audit2why`/`sepolgen` live in `selinux-python` (packaged in nixpkgs, bumped to 3.11). `audit2allow -R` needs refpolicy's interface database: `make install-headers` plus `sepolgen-ifgen` writes `/var/lib/sepolgen/interface_info` (refpolicy Makefile line ~597). So the NixOS refpolicy package should ship a prebuilt interface DB and the module should point `sepolgen` at it (**[I]**: path override via `/etc/selinux/<type>/...` or an env var; check `sepolgen` search paths).
- **[I]** For policy development ergonomics: a `security.selinux.developmentMode = true` option that sets `dontaudit`-disabling build (`semodule -DB`, equivalent to `NO_DONTAUDIT`-style), installs `setools`, `audit2allow`, `sepolicy`, and enables auditd, would shorten the loop considerably.

### 5.7 Container runtimes

- **[V]** refpolicy has `udica-templates/`. **[I]** Fedora's container policy comes from the separate `container-selinux` project (not examined in this session). Docker/podman need `container_t`, `container_file_t`, `container_runtime_t` types, MCS category generation by the runtime (libselinux `selinux_init`, `label` library in podman/runc), and volume relabel (`:z`/`:Z`). Bottlerocket's MCS-per-pod design is the reference for MCS use (Discussion #1747, [V]).
- **[I]** NixOS's podman/docker/containerd packages must be built with SELinux support (rancher module already has `selinux` option for containerd, `nixos/modules/services/cluster/rancher/default.nix`, [V]). Defer containers to stage 3.

---

## 6. NixOS-specific friction

### 6.1 Activation and `nixos-rebuild switch`

- **[V]** Activation runs `setup-etc`, user/group creation, wrappers etc. both at boot (before `exec systemd`, see 3.3) and on `switch-to-configuration`.
- **[I]** On `switch`, new policy must be loaded with `load_policy` (plus `setsebool` for volatile booleans) in the activation script. Policy reload preserves process contexts but can fail with the version check. A failed load must not abort `switch` in permissive mode (log and continue). In enforcing mode, abort before the generation is switched. Make policy reload a separate step that runs *before* services restart, and run a `restorecon` for mutable paths whose contexts changed.
- **[I]** Activation scripts run as root in the context of the caller (stage 2: PID 1/kernel domain; `switch`: the admin's domain, `sysadm_t`/`unconfined_t`). Under a non-unconfined admin domain the activation needs a transition to a dedicated `nixos_activate_t` (or the admin simply runs `unconfined_t`).
- **[V]** A first attempt (https://tristanxr-com.pages.dev/post/selinux-on-nixos) ran the policy install from the activation script, which took ~40 s at boot, hit the FHS `hll` compiler path, and needed the kernel policy version pinned. The build-in-derivation approach above eliminates all three.

### 6.2 `/etc` generated from store symlinks

- **[V]** `setup-etc` links `/etc/<f>` → `/etc/static/<f>` → `/nix/store/...`. Some files are copied with a mode instead of linked (e.g. shadow).
- **[I]** Consequences:
  - The *symlink* inode gets the label of its creating context/directory (`etc_t`), but the target content has the store's label. SELinux checks the final inode when a file is opened, so `/etc/shadow`-like secrets as store files would carry the generic store type unless labelled at build time. The copied files (e.g. shadow) *are* individually labelable by `restorecon`/`setfscreatecon` at setup time, so `setup-etc` should call `restorecon` or run under `setfscreatecon`.
  - Policies that name specific `/etc` types (`passwd_file_t`, `shadow_t`) will not apply to store targets. The coarse-grained approach is to give all of `/etc/static` content a single `etc_t`-like type through the store labelling scheme, and handle only the copied secrets individually.

### 6.3 Setuid wrappers in `/run/wrappers`

- **[V]** In current nixpkgs, `nixos/modules/security/wrappers/default.nix` mounts a `tmpfs` at `/run/wrappers` (nodev, mode=755, via `systemd.mounts`) and the `suid-sgid-wrappers.service` fills it with `mktemp --directory --tmpdir=...` plus `chmod u+s` copies of the wrapper binary (`wantedBy = sysinit.target`, `RestrictSUIDSGID = false`).
- **[I]** Needed: (a) file-context entries for `/run/wrappers(/.*)?` (e.g. `wrapper_exec_t` or reuse the target program's type via a type-transition on the creating domain); (b) the service must run in a domain permitted to create setuid files in `tmpfs_t` or `var_run_t`; (c) because the wrapper `execve`s a store binary, domain transitions on `su`, `sudo`, `mount`, `passwd`, `newuidmap`, ... need an entrypoint that the policy knows. The wrapper's path is stable (`/run/wrappers/bin/<name>`) so `file_contexts` can label each by name. Since wrappers are *copies* created at boot, systemd's post-load `/run` relabel (verified) will label them from `file_contexts`; but the `suid-sgid-wrappers` service runs after load, so labels must be correct at creation or fixed with `restorecon` at the end of the script.
- **[I]** Bonus: `/run/current-system`, `/run/booted-system`, `/run/current-system/sw`, `/run/opengl-driver` etc. are symlinks created by activation under `/run`. They get `var_run_t` or similar, and the policy must allow reading them from every domain.

### 6.4 `nix-daemon` and the build sandbox

- **[V]** Upstream Nix has no SELinux policy. The multi-user installer refuses to run on enforcing systems (`packaging/scripted-installer/install-multi-user.sh` `check_selinux()`: "Nix does not work with selinux enabled yet!"). The docs say the default install on "Linux with SELinux" is single-user (`doc/manual/source/installation/installing-binary.md`). The `ignored-acls` setting defaults to `security.selinux, system.nfs4_acl, security.csm` because "some ACLs like `security.selinux` ... can't be removed even by root" (`src/libstore/include/nix/store/local-settings.hh`). Nix 2.35 release notes: the Linux sandbox now returns `ENOTSUP` for `listxattr`/`llistxattr`/`flistxattr` as well as the get/set/remove calls, "preventing host xattrs (e.g. `security.selinux`) from leaking into builds" (PR #15743). **This was merged into the 2.35 development notes in `rl-2.35.md`**, and it confirms the build sandbox is deliberately xattr-blind: builders cannot create or see SELinux labels.
- **[V]** The Guix daemon policy is the closest reference: it labels the daemon binary `guix_daemon_exec_t`, runs it as `guix_daemon_t`, and uses `restorecon -R /gnu /var/guix` (above). Guix's builders are the daemon's children, so they inherit `guix_daemon_t`. I did not read the CIL (the Savannah/Codeberg raw URLs returned nothing in this session). **[I]** Treat it as a template for permission shape, not as verified content.
- **[I]** Design for NixOS:
  - `nix-daemon.service` runs as `nix_daemon_t` (selected by `SELinuxContext=`, no need to label its store binary).
  - It needs: manage `nix_store_t` (create/rename/setattr/relabelto for new store paths), read/write `nix_var_t` (`/nix/var/nix`), create sandbox mount namespaces/`chroot`/`unshare` (capabilities `sys_admin`, `sys_chroot`, `setuid`, `setgid`, userns with `userns_create`), fork builders.
  - Builders run as `nixbld*` users and *inherit the daemon's domain* unless a transition is configured. The default (inherit) is simplest, and the builder is then as privileged as the daemon. A stricter model transitions builders to `nix_builder_t` through `setexeccon` in the daemon (Nix would need a patch, since the build forks and `execve`s the builder directly), with rules: write only to the build dir and output paths, no access to the network (FOD builders excepted) or to the rest of the system.
  - **[I]** Because builders' output labelling cannot be done inside the xattr-blind sandbox, relabelling store paths after build is a daemon-side step. This is the store-labelling question in doc 03. From the policy side, `nix_daemon_t` needs `relabelfrom/relabelto` on the store types and an `.fc` entry that gives each newly registered store path its label.
- **[V]** The Determinate Nix installer claims enforcing-SELinux compatibility but gives no policy specifics (see 1.5).

---

## 7. Open design problem: file contexts vs. store paths **[I]**

A reality check on the `file_contexts` strategy, to be reconciled with doc 03.

- refpolicy `.fc` entries are regexes on absolute paths: `/usr/sbin/sshd -- sshd_exec_t`. After `file_contexts.subs_dist` aliasing, a path like `/run/current-system/sw/bin/sshd` is looked up as `/usr/bin/sshd`.
- But the file actually run is `/nix/store/<hash>-openssh-X/bin/sshd` (what `/run/current-system/sw/bin/sshd` resolves to). `restorecon /run/current-system/sw/bin/sshd` labels the *symlink* (`restorecon -h`) or follows it, depending on flags, and `setfiles` of the store would use the real path.
- A subs rule `/nix/store/*/bin /usr/bin` (wildcard, needs libselinux 3.12) would alias `/nix/store/<hash>-pkg/bin/<x>` to `/usr/bin/<x>` for *all* packages. That labels `openssh`'s sshd and also `/nix/store/<hash>-bash/bin/sshd` if any, and, worse, gives `/usr/bin/<name>` labels to a name that is not unique across packages (two packages can ship `bin/ls`). Name-collision means the label is by command name, not by package. Usually harmless (same name → same intent), but a security boundary on it is weak.
- **Alternative:** write `.fc` entries with store regexes: `/nix/store/[^/]+-openssh-[^/]+/bin/sshd -- gen_context(system_u:object_r:sshd_exec_t,s0)`. Generated per NixOS module from the package derivation path (the path is known at eval time, so the NixOS module could emit an *exact* `.fc` line per service binary). This is precise and fits Nix well: file contexts become data derived from the closure. Cost: file_contexts grows with the number of confined binaries (small) rather than every store path.
- Either way, labels must be applied by a tool that writes `security.selinux` on store paths; a policy-side approach that avoids labelling every store path is `SELinuxContext=` plus a generic entrypoint type on the store (`nix_store_exec_t`, allowed as `entrypoint` for each service domain). Then it is the *unit* that picks the domain and the store needs only a few broad types (`nix_store_t` for data, `nix_store_exec_t` for executables, reflecting the mode bits). This is the lowest-friction first target and matches the Discourse suggestion by RossComputerGuy ("`SELinuxContext` service option as a workaround, which would not require labeling the binary", https://discourse.nixos.org/t/selinux-on-nixos/62729), though arianvp noted this does not solve unit-file access checks.

---

## 8. Recommendation

### 8.1 Policy base

**Use SELinuxProject/refpolicy**, built as modular policy in a Nix derivation, plus a small NixOS-owned policy layer.

Reasons:
- Already packaged (`selinux-refpolicy` in nixpkgs, maintained by the same people as the other SELinux packages), GPL-2.0.
- The most upstream-friendly: refpolicy accepts distro-specific code through `distro_<name>` ifdefs and has a documented subs mechanism, so NixOS-specific interfaces and the `distro_nixos` flag can be proposed upstream (the build flag already exists in nixpkgs but is unused, [V]).
- Mature module breadth (~760 files under `services/`) with tunables (booleans) as the natural mapping to NixOS options.
- Fedora's policy is a superset, but is a downstream fork. Prefer refpolicy as the base, and consider cherry-picking container-related modules later.
- Use a *thin NixOS layer* of our own: a `nixos` refpolicy module (`policy/modules/system/nixos.{te,if,fc}`, or a downstream-only module) defining `nix_store_t`, `nix_store_exec_t`, `nix_daemon_t`, `nix_builder_t`, `nixos_activate_t`, `nix_wrapper_exec_t`, `/run/current-system(/.*)?` labels, and NixOS-aware path aliases in `file_contexts.subs_dist`.
- **Stage 1 uses hand-written CIL via `secilc`** (Bottlerocket model), moving to refpolicy at stage 2 without changing the on-disk layout.

### 8.2 Build and deployment model

1. A Nix derivation assembles the policy for a given NixOS configuration (Pipeline A for refpolicy, C for CIL), outputting `$out/etc/selinux/<type>/...` plus `$out/etc/selinux/config`. `semodule` is run with `--path/--store-path/--noreload` and a generated `semanage.conf` that points helpers at store paths and sets `policy-version`.
2. `environment.etc."selinux"` (or `/etc/selinux` as a symlink to that derivation) installs it. No mutable `/var/lib/selinux` is needed. `semanage`/`semodule` are not supported for runtime edits in enforcing mode (a debug option can enable a local store using `ro-store-root`-style layering once libsemanage 3.12 is in nixpkgs).
3. A `security.selinux` NixOS module exposes: mode, policy package/type, per-service modules (`te`/`if`/`fc`/`cil`), booleans (baked at build time), seusers/users, file-context substitutions, `lsm=`/kernel config, and the PAM/sshd/systemd/dbus/coreutils packages with SELinux enabled. Services declare their domain with `SELinuxContext`.
4. Policy is part of the system closure: switching generations changes the policy atomically, and rollback restores the old one.
5. Load policy before activation (stage-2-init or initrd), keep systemd's own loader as a fallback and for reloads.
6. Ship a NixOS relabel unit (not a `/.autorelabel` flag) that restores labels on mutable paths and is keyed on the policy store path.

### 8.3 Upstreaming targets

- nixpkgs: complete #396177/#396168/#591351 stack, bump userspace to 3.12 when released, enable `withSelinux` for systemd, openssh, dbus, linux-pam, coreutils, sudo as needed.
- refpolicy: `distro_nixos` support and `file_contexts.subs_dist` entries. Upstream refpolicy has no `nixos` mention in `Changelog`/modules ([V] grep).
- SELinuxProject/selinux: confirm that the 3.12 features (`ro-store-root`, `/usr/lib/selinux` fallback, wildcard subs) land in the release and cover `SELINUXFALLBACKDIRS` override from the Nix build.
- systemd: nothing needed for the first stage. If `access_selinux_context` for store unit files proves too coarse, an option to take unit access context from a label database instead of the file would be a longer-term upstream topic.

---

## 9. Open questions for a prototype

1. **Policy load timing**: does `load_policy -i` at the start of `stage-2-init.sh` work in the NixOS VM test framework (no `/sys/fs/selinux` mounted yet, `/proc` available)? Does `exec systemd` then get `init_t` with a labelled store binary?
2. **Initial unlabeled store**: with an unlabeled `/nix/store` (or `defcontext=`/`context=` mount option), what do systemd, udevd, `activate`, `nix-daemon` do in permissive mode? Count the AVC volume. If `context=` is used, what is the entrypoint story for services?
3. **Per-unit access checks**: how bad is it that every unit file has the same label (section 5.4)? Is there any cheap way to label unit files (e.g. labelling the generated `unit-*` derivation outputs at build or activation time, outside the store, e.g. `/etc/systemd/system` copies instead of links)?
4. **Policy tooling inside the sandbox**: confirm `semodule --path --store-path --noreload -B` works in a pure sandbox with libsemanage 3.11 (helper path config, `bzip`, `sefcontext_compile`), and measure build time for full refpolicy.
5. **Targeted base**: which refpolicy module set and seusers/unconfined defaults reproduce "everything unconfined except selected services"? Is `unconfined_service_t` available in the pinned version for services without a domain?
6. **Booleans**: baked into the build vs `setsebool -P`-like behaviour. Cost of rebuilding the policy on a boolean flip (build time) versus runtime volatility.
7. **Wildcard subs vs exact `.fc` lines** (section 7): which is better for `file_contexts` size, correctness and collision avoidance? Also, which tool applies the labels on store paths and when (doc 03)?
8. **`/etc` labelling**: can `setup-etc` run under `setfscreatecon` or call `restorecon` per copied file? What labels do `/etc/static` targets get?
9. **Wrappers**: confirm the label of files created by `suid-sgid-wrappers.service` after the policy is loaded and the domain transitions through them (`sudo`, `mount`, `su`).
10. **Nix daemon**: which minimal `nix_daemon_t`/`nix_builder_t` rule set lets builds, GC, `nix-store --optimise` (hard links, `relabel`), remote store protocol, and substituter fetches work? Does keeping builders in the daemon's domain suffice for stage 2?
11. **AppArmor coexistence**: with the NixOS default kernel (`DEFAULT_SECURITY_APPARMOR=y`), what is the cleanest LSM selection (`lsm=landlock,lockdown,yama,selinux,bpf`?) and what breaks in NixOS modules that assume AppArmor?
12. **Kernel policy version**: automate `OUTPUT_POLICY`/`policy-version` from the configured kernel, to avoid the v33/v34 mismatch reported by the NixOS wiki write-up.
13. **Reload semantics**: behaviour of `load_policy` at `switch-to-configuration` when types are removed or renamed. Do we need `semodule -B`-style "policy diff" checks or a required reboot class?
14. **Policy and `systemd` units generated at runtime** (generators, transient units, `systemd-run`): labelled from `/run/systemd/...` rules; verify with an unconfined baseline.
15. **Licensing/packaging**: do we want NixOS-specific policy contributed as a refpolicy module (GPL-2.0) or kept as separately licensed CIL?

---

## 10. Caveats on this research

- I did not run any of the code. All `[V]` statements come from reading source or docs. The VM-level behaviour is `[I]`.
- The SELinux userspace features called out as "main" are not in a release. `VERSION` at HEAD says `3.12-rc3`, while nixpkgs uses 3.11 (`policycoreutils` 3.11 in `package.nix`). I did not check their final release status.
- `gh api` was blocked for the SELinux and NixOS repos (the sandbox only allows repository-scoped endpoints for the bound repository), so PR/issue details come from `git clone`, raw file reads and `api.github.com/search`.
- Fedora's F23 policy-store migration mail and the Guix `guix-daemon.cil` source could not be fetched (bot wall / empty responses). Statements about those are flagged.

## 11. Source index

Upstream sources read (local shallow clones, paths relative to repo root):
- `SELinuxProject/selinux`: `libselinux/src/{load_policy.c,label_file.c,selinux_config.c,selinux_internal.h}`, `libselinux/man/man5/selabel_file.5`, `libsemanage/man/man5/semanage.conf.5`, `libsemanage/src/{Makefile,semanage_store.c}`, `policycoreutils/semodule/{semodule.c,semodule.8}`, `policycoreutils/scripts/fixfiles`, `secilc/{secilc.c,secilc.8.xml,docs/cil_user_statements.md}`, `*/LICENSE`.
- `SELinuxProject/refpolicy`: `build.conf`, `Makefile`, `Rules.modular`, `Rules.monolithic`, `config/file_contexts.subs_dist`, `config/appconfig-*`, `doc/BUILD_INSTALL.md`, `policy/modules/system/{unconfined.te,init.fc,systemd.fc}`, `policy/modules/services/ssh.te`, `COPYING`.
- `fedora-selinux/selinux-policy`: `README.md`, `build.conf`, `config/file_contexts.subs_dist`, `dist/`.
- `systemd/systemd`: `src/core/{selinux-setup.c,main.c,selinux-access.c,load-fragment.c}`, `src/shared/{mount-setup.c,selinux-util.c}`, `meson.build`, `NEWS`, `man/systemd.exec.xml`.
- `bottlerocket-os/bottlerocket-core-kit`: `packages/selinux-policy/*`; `bottlerocket-os/bottlerocket`: `SECURITY_FEATURES.md`.
- `NixOS/nixpkgs`: `pkgs/by-name/se/selinux-refpolicy/package.nix`, `pkgs/by-name/po/policycoreutils/package.nix`, `pkgs/os-specific/linux/systemd/default.nix`, `pkgs/by-name/li/linux-pam/package.nix`, `pkgs/by-name/db/dbus/package.nix`, `pkgs/tools/networking/openssh/common.nix`, `pkgs/os-specific/linux/kernel/common-config.nix`, `nixos/modules/system/boot/stage-2-init.sh`, `nixos/modules/security/wrappers/default.nix`; issues/PRs #396177, #396168, #396155, #591351, #580953, #507501, #485821.
- `NixOS/nix`: `packaging/scripted-installer/install-multi-user.sh`, `src/libstore/include/nix/store/local-settings.hh`, `doc/manual/source/installation/installing-binary.md`, `doc/manual/source/release-notes/rl-2.35.md`.
- `dracut-ng/dracut-ng`: `modules.d/77selinux/{module-setup.sh,selinux-loadpolicy.sh}`.
- Linux kernel: `security/selinux/Kconfig`, `Documentation/admin-guide/kernel-parameters.txt` (torvalds/linux master via raw.githubusercontent.com).

Web pages:
- https://discourse.nixos.org/t/selinux-on-nixos/62729
- https://tristanxr-com.pages.dev/post/selinux-on-nixos
- https://wiki.nixos.org/wiki/SELinux_workgroup
- https://gist.github.com/xeji/78d4abbb493fc5a5b6f069b41ebdafbe
- https://guix.gnu.org/manual/devel/en/html_node/SELinux-Support.html
- https://source.android.com/docs/security/features/selinux/build
- https://ostreedev.github.io/ostree/reference/ostree-SELinux-policy-management.html
- https://github.com/bottlerocket-os/bottlerocket/discussions/1747
- https://determinate.systems/nix/selinux
- https://developers.redhat.com/articles/2025/08/25/what-image-mode-3-way-merge (only the `/etc` three-way merge, nothing on SELinux)
