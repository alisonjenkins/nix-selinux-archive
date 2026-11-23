#!/usr/bin/env python3
"""Turns this repository into a series of commits on a nixpkgs checkout.

usage: make-series.py NIXPKGS_DIR

NIXPKGS_DIR must be a clean git checkout of nixpkgs. Four commits are
added on top of whatever is checked out, authored by whoever runs this
(git's configured identity). Nothing is pushed.

The nixos/ and pkgs/ trees of this repository already have the paths and
contents they need in nixpkgs. This script copies them and adds the
registrations that nixpkgs keeps in shared files.
"""

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

here = Path(__file__).resolve().parent.parent
target = Path(sys.argv[1]).resolve()

MODULE = "nixos/modules/security/selinux"
TESTS = "nixos/tests/selinux"

# VM tests registered in nixpkgs, and how all-tests.nix refers to each.
TEST_ENTRIES = {
    "selinux-enforcing": "runTest ./selinux/enforcing.nix",
    "selinux-ephemeral-root": "runTest ./selinux/ephemeral-root.nix",
    "selinux-permissive-boot": "runTest ./selinux/permissive-boot.nix",
    "selinux-recovery": "runTest ./selinux/recovery.nix",
    "selinux-refpolicy": "runTest (import ./selinux/refpolicy.nix { })",
    "selinux-store-maintenance": "runTest ./selinux/store-maintenance.nix",
    "selinux-switch-rollback": "runTest ./selinux/switch-rollback.nix",
}
# Kept in this repository only: evaluation checks that need the flake,
# and the measurement, which is too large for the test set.
TESTS_NOT_UPSTREAM = {"eval.nix", "measure.nix", "smoke.nix"}

RELEASE_NOTE = (
    "- SELinux support, available as [security.selinux](#opt-security.selinux.enable). "
    "The policy is part of the system closure, is loaded in the initrd and switches and "
    "rolls back with the system generation. The Nix store is labelled without changes to Nix. "
    "Two policies are offered: a minimal one, and the SELinux reference policy, with which "
    "systemd's daemons, D-Bus, OpenSSH and the Nix daemon run in their own domains. "
    "The module is experimental. See the [SELinux chapter](#module-security-selinux).\n"
)


def git(*args, capture=False):
    result = subprocess.run(
        ["git", "-C", str(target), *args], check=True, text=True, capture_output=capture
    )
    return result.stdout if capture else None


def copy(relative, skip=()):
    source, destination = here / relative, target / relative
    if source.is_dir():
        destination.mkdir(parents=True, exist_ok=True)
        for item in sorted(source.iterdir()):
            if item.name not in skip:
                copy(str(Path(relative) / item.name))
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def insert_sorted(path, new_line, key_pattern, new_key):
    """Adds new_line before the first line whose key sorts after new_key."""
    lines = (target / path).read_text().splitlines(keepends=True)
    last_match = None
    for index, line in enumerate(lines):
        match = re.match(key_pattern, line)
        if not match:
            continue
        last_match = index
        if match.group(1) == new_key:
            return
        if match.group(1) > new_key:
            lines.insert(index, new_line)
            break
    else:
        if last_match is None:
            sys.exit(f"{path}: found no place for {new_key}")
        lines.insert(last_match + 1, new_line)
    (target / path).write_text("".join(lines))


def add_test(name, expression):
    insert_sorted(
        "nixos/tests/all-tests.nix",
        f"  {name} = {expression};\n",
        r"^  ([A-Za-z0-9_-]+) = ",
        name,
    )


def commit(message):
    git("add", "-A")
    git("commit", "-q", "-m", message)
    print(f"committed: {message.splitlines()[0]}")


if git("status", "--porcelain", capture=True).strip():
    sys.exit(f"{target} has uncommitted changes")

# 1. The CIL compiler.
copy("pkgs/by-name/se/secilc")
version = re.search(
    r'version = "([^"]+)"', (here / "pkgs/by-name/se/secilc/package.nix").read_text()
)
commit(f"secilc: init at {version.group(1)}" if version else "secilc: init")

# 2. The stock kernel can activate SELinux. No module yet.
copy(f"{TESTS}/smoke.nix")
add_test("selinux-smoke", "runTest ./selinux/smoke.nix")
commit(
    "nixosTests.selinux-smoke: init\n\n"
    "Shows that the default kernel activates SELinux when it is added to\n"
    "security.lsm, without a rebuild."
)

# 3. The minimal policy.
copy("pkgs/by-name/se/selinux-policy-minimal")
commit("selinux-policy-minimal: init")

# 4. The module, its tests and its documentation.
copy(MODULE)
copy(TESTS, skip=TESTS_NOT_UPSTREAM)
for name, expression in TEST_ENTRIES.items():
    add_test(name, expression)
insert_sorted(
    "nixos/modules/module-list.nix",
    "  ./security/selinux/default.nix\n",
    r"^  (\./security/[^ \n]+)",
    "./security/selinux/default.nix",
)

redirects_path = target / "nixos/doc/manual/redirects.json"
redirects = json.loads(redirects_path.read_text())
for anchor in re.findall(r"\{#([a-z0-9-]+)\}", (here / MODULE / "selinux.md").read_text()):
    redirects.setdefault(anchor, [f"index.html#{anchor}"])
redirects_path.write_text(json.dumps(redirects, indent=2, ensure_ascii=False) + "\n")

notes = sorted((target / "nixos/doc/manual/release-notes").glob("rl-*.section.md"))
unreleased = [n for n in notes if "new-modules}" in n.read_text()]
# The release in preparation is the newest file that has entries.
note_path = max(unreleased, key=lambda n: (len(n.read_text()) > 2000, n.name))
note = note_path.read_text()
head, marker, rest = note.partition("new-modules}\n")
comment_end = rest.find("-->\n")
position = comment_end + 4 if comment_end != -1 and comment_end < 400 else 0
rest = rest[:position] + "\n" + RELEASE_NOTE + rest[position:]
note_path.write_text(head + marker + rest)

commit(
    "nixos/selinux: init\n\n"
    "Adds security.selinux: the policy is a derivation in the system\n"
    "closure, loaded in the initrd before activation and reloaded on switch.\n"
    "The Nix store is labelled from outside Nix: generic types by path\n"
    "pattern, and types that carry privilege only for exact store paths, so\n"
    "that a package imitating another's layout gains nothing.\n\n"
    "Two policy types: `minimal`, written for NixOS, and `refpolicy`, the\n"
    "SELinux reference policy with a NixOS module.\n\n"
    "Everything is behind security.selinux.enable."
)
print("done. Review with: git -C", target, "log --stat -4")
