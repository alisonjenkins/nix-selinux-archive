# SELinux in nixpkgs / NixOS: current state (2026-11-21)

Method: `git clone --depth 1 --filter=blob:none --sparse` of NixOS/nixpkgs (default branch), HEAD `f657589a605aaa836018e7092920395d5d2ec2ea` (2026-11-21), sparse paths `pkgs`, `nixos/modules`, `nixos/tests`, `nixos/lib`. Then `git grep`. GitHub search REST API for PRs/issues (titles, dates and PR bodies only; the issue/PR read endpoints were denied in this session, so PR contents beyond the first message were NOT read).

## 1. VERIFIED FROM SOURCE

### 1.1 Userspace packages (all under `pkgs/by-name/<xx>/<name>/package.nix`)
Grouped attrset: `pkgs/os-specific/linux/selinux/default.nix`, exposed as `selinuxPackages = recurseIntoAttrs (callPackage ../os-specific/linux/selinux { })` at `pkgs/top-level/all-packages.nix:9856`. It contains: checkpolicy, libselinux, libsemanage, libsepol, policycoreutils, restorecond, selinux-python, selinux-refpolicy, selinux-sandbox, semodule-utils, setools. All are also top-level via by-name.

| Package | Version | Notes |
|---|---|---|
| libsepol | 3.11 | maintainers: RossComputerGuy, numinit, naxdy (comment: "changing maintainers here changes maintainers for all SELinux-related libraries"; other packages inherit) |
| libselinux | 3.11 | `enablePython` -> `py` output; pcre2, fts; python binding via swig |
| libsemanage | 3.11 | |
| policycoreutils | 3.11 | |
| checkpolicy | 3.11 | |
| semodule-utils | 3.11 | |
| restorecond | 3.11 | |
| selinux-python | 3.11 | (audit2allow, semanage, etc.) |
| selinux-sandbox | 3.11 | |
| setools | 4.7.1 | github SELinuxProject/setools |
| selinux-refpolicy | 2.20250923 | tag `RELEASE_2_20250923`; makeFlags `DISTRO=nixos SYSTEMD=y UBAC=y`, optional `policyVersion`/`moduleVersion`; `installTargets = all install install-headers install-docs`; builds with `make conf` |
| secilc | NOT FOUND | no `pkgs/by-name/se/secilc`, no mention in all-packages (not shipped as a package; check whether checkpolicy/libsepol output includes it: not verified) |

Maintenance evidence: recent bump PRs (search API): policycoreutils 3.10->3.11 (#540539, closed), selinux-python 3.10->3.11 (#584854, closed 2026-11-08), setools 4.7.0->4.7.1 (#547261), security issues on policycoreutils 3.11 (#545314, #551117 closed). So actively maintained, with an update script (`gitUpdater`) and a small team (the 3 maintainers above). Python module `python-packages.nix:9944` wraps libselinux.

### 1.2 Kernel
- `pkgs/os-specific/linux/kernel/common-config.nix`: NO `SECURITY_SELINUX`, no `SECURITY_NETWORK`-for-SELinux, no `DEFAULT_SECURITY_SELINUX`, no `AUDIT`-related SELinux entries (grep for "selinux" across `pkgs/os-specific/linux/kernel` and `pkgs/top-level/linux-kernels.nix` is empty). So default NixOS kernels leave `CONFIG_SECURITY_SELINUX` at the kernel default (unset). Not confirmed from a built kernel .config; a built `.config` would be needed to be certain, including whether `SECURITY_NETWORK`, `AUDIT`, `NETLABEL`, `FS_SECURITY` xattr support are on.
- Enabled LSMs in common-config (lines ~812-857): `SECURITY_YAMA` (option yes), `SECURITY_LANDLOCK`, `SECURITY_IPE` (>=6.12), `SECURITY_APPARMOR = yes` + `DEFAULT_SECURITY_APPARMOR = yes` (lines 825-826), `SECURITY_LOCKDOWN_LSM(_EARLY)`, `BPF_LSM` (option yes, line 79), IMA/integrity.
- LSM selection: `nixos/modules/security/default.nix` defines `security.lsm` (`listOf str`, default `[]`, "LSMs to initialize in order"). The module itself sets defaults `[ "landlock" "yama" ]` plus `lib.mkAfter [ "bpf" ]` (comment references PR #533428: AppArmor and others must come before BPF). If list non-empty: adds `boot.kernelParams = [ "lsm=<comma list>" ]` and an assertion that no `security=` param is in `boot.kernelParams`. AppArmor module (`nixos/modules/security/apparmor.nix:201-202`) sets `boot.kernelParams = [ "apparmor=1" ]` and `security.lsm = [ "apparmor" ]`.
- Open issue #510901 (2026-10): "nixos/security: assertion 'security parameter in boot.kernelParams cannot be used when security.lsm is used' always fires" (title only read). Relevant because SELinux enable typically uses `security=selinux`.
- Note `lsm=` without selinux means SELinux can't be selected even if built in; needs `selinux` in the list in the right position (selinux is a "major" LSM; stacking order matters with AppArmor).

### 1.3 NixOS modules / tests
- There is NO `security.selinux` module in master. `git grep -il selinux nixos` hits only: `nixos/modules/misc/locate.nix:137` (prunes fs type `selinuxfs`), `services/cluster/rancher/default.nix:530` (`selinux` bool option, passes `--selinux` to rke2/k3s containerd), `services/desktops/flatpak.nix:60` (comment only), `services/network-filesystems/glusterfs.nix:180-185` (excludes `S10selinux-label-brick.sh` hook "due to missing SELinux binaries").
- NO NixOS tests mention selinux (`git grep -i selinux nixos/tests` empty). The only related test content: `nixos/tests/systemd-nsresourced-mountfsd.nix` checks `/sys/kernel/security/lsm` for bpf.
- `pkgs/build-support/vm/default.nix:1093` lists `rpm-plugin-selinux` (RPM VM-image helper, unrelated to NixOS runtime).
- In-flight (search API, titles/dates only): PR #396177 "nixos/selinux: init" by RossComputerGuy (open since 2025-04-05, 5 comments; body: "Adds the SELinux module to NixOS, would be great to get #396155 before this so we can default to it"); PR #396168 "pkgs/top-level/config.nix: add selinux support" (open; presumably a `config.selinux`-style global switch; contents not read); PR #591351 "linux-pam: allow building with SELinux support" (Naxdy, open, 2026-11-21); PR #580953 "fakeroot: hide selinux xattrs" (open); PR #570124 "openssh: allow building with SELinux support" (closed 2026-10-04; `withSelinux` exists in tree so presumably merged, not verified). Issue #507501 "Upstream SELinux support plan for Nix installer and runtime" (closed, 2026-04, by an outside contributor, scope: installer on Fedora/RHEL, file-contexts for /nix, restorecon, audit of packages built without SELinux).

### 1.4 Package SELinux flags (defaults in master)
| Package | File | Flag / state |
|---|---|---|
| systemd | `pkgs/os-specific/linux/systemd/default.nix:52,366,519` | `withSelinux ? false` -> `mesonEnable "selinux"` + libselinux |
| coreutils | `pkgs/by-name/co/coreutils/package.nix:16,171` | `selinuxSupport ? false` (asserts libselinux+libsepol; `--with-selinux`, `-lsepol`) |
| uutils-coreutils | `pkgs/by-name/uu/uutils-coreutils/package.nix:14` | `selinuxSupport ? false` |
| openssh | `pkgs/tools/networking/openssh/common.nix:34,157` | `withSelinux ? false` -> `--with-selinux` |
| linux-pam | `pkgs/by-name/li/linux-pam/package.nix:111` | hardcoded `mesonEnable "selinux" false` (PR #591351 open to make it optional) |
| dbus | `pkgs/by-name/db/dbus/package.nix:94,129` | `-Dselinux=disabled`, comment "ToDo: optional selinux?" |
| rpm | `pkgs/by-name/rp/rpm/package.nix:23,97` | `-DWITH_SELINUX=OFF` (libselinux commented out, "missing propagatedBuildInputs") |
| sssd | `pkgs/by-name/ss/sssd/package.nix:119` | `--without-selinux` |
| postgresql | `pkgs/servers/sql/postgresql/generic.nix:114,350` | `selinuxSupport ? false` |
| erofs-utils | `.../er/erofs-utils/package.nix:17` | `selinuxSupport ? false` |
| casync | `.../ca/casync/package.nix:16` | `selinuxSupport ? true` |
| account-utils | `.../ac/account-utils/package.nix:19` | auto: `availableOn libselinux` |
| flatpak | `.../fl/flatpak/package.nix:77` | `withSELinuxModule ? false` |
| emacs | `pkgs/applications/editors/emacs/make-emacs.nix:86` | `withSelinux ? isLinux` |
| Always link libselinux (unconditional buildInput) | | elogind, networkmanager, glib, lxc, podman, ostree, bubblewrap, runc, aide, gdm, qtbase (qt6), libreswan, nilfs-utils, f2fs-tools, and others |
| util-linux, shadow, sudo, cronie, findutils, gnutar, procps | `git grep -i selinux` finds nothing in util-linux/shadow/sudo/cronie/findutils package.nix, so no SELinux option is exposed (upstream `--with-selinux`/`--without-selinux` autodetect or explicit disable not verified; gnutar has only a libiconv patch mention). Whether their built binaries link libselinux was NOT checked. |
| audit | `pkgs/by-name/au/audit/testsuite.nix:36` | one test excluded because it needs SELinux (`id -Z`) |

Takeaway: the core stack that has to be SELinux-aware (systemd, coreutils, pam, openssh, dbus) is off by default; there is no global switch in master (PR #396168 aims at one).

### 1.5 AppArmor as comparison (fully integrated)
- Module: `nixos/modules/security/apparmor.nix` (+ `apparmor/includes.nix`, `apparmor/profiles.nix`; maintainer team `lib.teams.apparmor`). Options: `security.apparmor.enable`, `.policies.<name>.{state,profile|path}` (state enum enforce/complain/..., exactly one of profile/path), `.includes`, `.packages` (default `[ apparmor-profiles ]`), `.enableCache`, `.killUnconfinedConfinables`.
- Kernel: `SECURITY_APPARMOR = yes`, `DEFAULT_SECURITY_APPARMOR = yes`; module adds `apparmor=1` and `security.lsm = [ "apparmor" ]`.
- Policy handling: `/etc/apparmor.d` is a `linkFarm` of generated profiles; `/etc/apparmor/parser.conf` with `Include` of `cfg.packages`; systemd service `apparmor` (`ConditionSecurity=apparmor`) runs `aa-teardown`, `apparmor_parser --add/--replace`, `aa-remove-unknown`; reload on change; caching off by default because "policies almost always contain Nix store paths".
- Store paths: profiles written by Nix interpolate `${pkgs.foo}/bin/foo`; includes use `etcRule` (resolves `config.environment.etc.<x>.source`) and `pkgs.apparmorRulesFromClosure` (`nixos/modules/config/malloc.nix`). Other modules contribute via `security.apparmor.includes.*` (fontconfig.nix, malloc.nix) and PAM via `apparmor-pam` (`pam.nix:1727`, `enableAppArmor`).
- Packages: apparmor-parser/utils/bin-utils/init/profiles/pam; systemd `withApparmor ? true`.
- Test: `nixos/tests/apparmor/` (registered `all-tests.nix:293`), covers enforce/complain, profile text and path.
- Contrast: AppArmor is path-based so store paths are natural; SELinux is label-based, so the equivalent problem is labeling `/nix/store` (file_contexts), xattrs on the store, and not path-in-policy. (Inference.)

## 2. INFERRED / NOT CONFIRMED
- Default kernel .config has SELinux off: inferred from absence in common-config; unverified against a built kernel (`nix build nixpkgs#linux.configfile`).
- Whether `selinux` can currently be put in `security.lsm` and work at boot: untested. Also no `selinux=1`/`enforcing=` handling and no module for `/etc/selinux/config`.
- Contents of PRs #396177, #396168, #396155, #591351, #580953: only titles/dates/short bodies seen. Worth reading before designing anything.
- Whether Nix itself (nix-daemon, store writes, `nix-env` profiles) preserves/sets xattrs: not investigated here.

## 3. GAPS for a working SELinux system
1. Kernel: no `SECURITY_SELINUX`, `SECURITY_NETWORK`, `SECURITY_SELINUX_*`, `NETLABEL`, `AUDIT` guarantees; no `DEFAULT_SECURITY_SELINUX`; `lsm=` ordering with apparmor/bpf unsettled (#510901).
2. NixOS module: none merged (`nixos/selinux` #396177 open since 2025-04): needs enable option, `/etc/selinux/{config,<type>/...}` generation, policy store (`semodule`/`libsemanage` writes under `/var/lib/selinux`, mutable vs. declarative), `selinux-autorelabel`, kernel params, and `restorecond`.
3. Policy: only upstream refpolicy 2.20250923 is packaged with `DISTRO=nixos` knob; unknown if refpolicy has real NixOS file contexts (`/nix/store`, `/run/current-system`, `/etc/static`, `/run/wrappers`); no declarative policy-module option; no test that loads a policy.
4. Userland built without support: systemd (off), coreutils (off, `id -Z`, `ls -Z`), linux-pam (hard off; PR open), openssh (off), dbus (disabled), util-linux/shadow/sudo/cronie/findutils unverified, rpm/sssd off. systemd needs it for labeling `/run`, `/dev`, unit `SELinuxContext=`, `systemd-tmpfiles` relabeling, and PID1 policy load (`selinux-setup`).
5. Labeling the Nix store and activation: the activation script/`nixos-rebuild`/nix-daemon/`/etc` symlinks and `/run/wrappers` setuid wrappers have no label handling.
6. Tests: zero NixOS VM tests for SELinux (compare `nixos/tests/apparmor`).
7. Packaging: no `secilc` package; global enable switch (#396168) unmerged.
