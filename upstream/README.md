# Preparing the upstream patch series

`make-series.py` applies this repository to a nixpkgs checkout as four commits. It pushes nothing and contacts nobody; opening a pull request upstream is a separate decision.

```sh
git clone --depth 1 https://github.com/NixOS/nixpkgs.git /tmp/nixpkgs
upstream/make-series.py /tmp/nixpkgs
```

The commits, in order:

| Commit | Contents | Test |
|---|---|---|
| `secilc: init` | The CIL policy compiler, `pkgs/by-name/se/secilc` | its install check compiles a policy |
| `nixosTests.selinux-smoke: init` | No module: the stock kernel activates SELinux through `security.lsm` | `nixosTests.selinux-smoke` |
| `selinux-policy-minimal: init` | The minimal policy, `pkgs/by-name/se/selinux-policy-minimal` | the build validates the file contexts against the policy |
| `nixos/selinux: init` | The module, the setup tool, the reference policy build, the manual chapter, a release note, and seven VM tests | `nixosTests.selinux-*` |

The `nixos/` and `pkgs/` trees of this repository are copied unchanged. The script adds only what nixpkgs keeps in shared files: entries in `module-list.nix`, `all-tests.nix`, the manual's `redirects.json` and the release notes. It also adds one line to the module, `meta.doc`, which declares the manual chapter; outside nixpkgs that line would break the manual build of any system using the module.

Run the tests from the checkout:

```sh
cd /tmp/nixpkgs
nix-build -A nixosTests.selinux-enforcing -A nixosTests.selinux-refpolicy
nix-build nixos/release.nix -A manualHTML.x86_64-linux
```

## State

Checked against nixpkgs `2786a2a72088` (the revision this repository's flake is locked to): the two packages build, the NixOS manual builds with the chapter, and all eight VM tests pass from the patched tree (with KVM, 55 to 105 s each).

## Before submitting

- **Maintainers.** The packages and the module name no maintainer. Whoever submits adds themselves to `maintainers/maintainer-list.nix` and to the `meta.maintainers` of the two packages and the module.
- **Size of the last commit.** It can be split into the module with the minimal policy first and the reference policy second, if reviewers ask. That split needs hand-made intermediate versions of `policy.nix`, `userland.nix` and `services.nix`, so it is left until the review asks for it.
- **Rebase.** Run the script on current nixpkgs master, not on the locked revision, and run the tests again there.
- **Discussion first.** `docs/design.md` is written to be the body of that discussion. Earlier attempts stalled on design objections, which it answers one by one.
