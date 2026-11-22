# Loads the SELinux policy if none is loaded yet, and labels the filesystem.
#
# Runs in two places:
#   - in the initrd, chrooted into the new root, before NixOS activation, so
#     that everything activation creates is labelled correctly;
#   - from the activation script on `nixos-rebuild switch`, to label store
#     paths that arrived since the last run.
#
# Nix is not involved. Nix leaves `security.selinux` attributes alone
# (its `ignored-acls` default), so labels set here stay in place.

set -euo pipefail

store=/nix/store
marker=trusted.nixos-selinux
stateDir=/var/lib/selinux-nixos

saved_args=("$@")

policy=
spec=
rev=
remounted=
exact=()
relabel=()

while [ $# -gt 0 ]; do
  case "$1" in
    --policy) policy=$2; shift 2 ;;
    --spec) spec=$2; shift 2 ;;
    --rev) rev=$2; shift 2 ;;
    --exact) exact+=("$2"); shift 2 ;;
    --relabel) relabel+=("$2"); shift 2 ;;
    --remounted) remounted=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

log() { echo "selinux-setup: $*"; }

if [ -n "$remounted" ]; then
  mount -o remount,bind,rw "$store"
fi

if [ ! -e /sys/fs/selinux/load ]; then
  log "SELinux is not active in the running kernel, nothing to do"
  exit 0
fi

# --- Policy -------------------------------------------------------------------

# Before the first policy load every process runs in the context "kernel".
current=$(tr -d '\0' < /proc/self/attr/current)
if [ "$current" = kernel ]; then
  # The kernel takes the whole policy in a single write.
  dd if="$policy" of=/sys/fs/selinux/load bs=256M status=none
  log "loaded policy $policy"
fi

label_one() {
  # Label a single path without descending into it.
  local path=$1 context
  context=$(selabel_lookup -b file -f "$spec" -k "$path" 2>/dev/null \
    | sed -n 's/^Default context: //p')
  if [ -n "$context" ]; then
    setfilecon "$context" "$path" 2>/dev/null || true
  fi
}

# --- Mutable paths ------------------------------------------------------------

# Top-level directories, every time. New files take their parent
# directory's type, so this alone gets most of activation's output right.
for dir in / /etc /var /nix /nix/var "$store" /home /root /tmp /boot /bin /usr /usr/bin; do
  if [ -d "$dir" ]; then label_one "$dir"; fi
done

# A full pass over the mutable paths only when the labelling rules changed.
if [ "$(cat "$stateDir/relabelled" 2>/dev/null || true)" != "$rev" ]; then
  existing=()
  for path in "${relabel[@]}"; do
    if [ -e "$path" ]; then existing+=("$path"); fi
  done
  if [ ${#existing[@]} -gt 0 ]; then
    log "relabelling ${existing[*]}"
    setfiles -F "$spec" "${existing[@]}"
  fi
  mkdir -p "$stateDir"
  echo "$rev" > "$stateDir/relabelled.tmp"
  mv "$stateDir/relabelled.tmp" "$stateDir/relabelled"
  label_one /var/lib
  setfiles -F "$spec" "$stateDir"
fi

# --- Nix store ----------------------------------------------------------------

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Every top-level store path, except the hard-link farm of the optimiser.
find "$store" -mindepth 1 -maxdepth 1 ! -name .links -print | sort > "$work/all"

# Store paths already labelled under the current rules carry a marker on
# their top-level inode. A path that is garbage collected and fetched again
# is a new inode without a marker, so it is picked up again by itself.
{
  xargs -a "$work/all" -d '\n' -r \
    getfattr -h --absolute-names -n "$marker" -e text 2>/dev/null || true
} | awk -v want="$marker=\"$rev\"" '
    /^# file: / { file = substr($0, 9) }
    $0 == want { print file }
  ' | sort > "$work/done"

comm -23 "$work/all" "$work/done" > "$work/todo"

# Paths with an exact rule are always redone. They are few, and their rules
# change without the generic rules changing.
for path in "${exact[@]}"; do
  root=$(echo "$path" | cut -d/ -f1-4)
  if [ -e "$root" ]; then echo "$root" >> "$work/todo"; fi
done
sort -u -o "$work/todo" "$work/todo"

count=$(wc -l < "$work/todo")
if [ "$count" -eq 0 ]; then
  log "store labels are up to date"
  exit 0
fi

# The store is normally mounted read-only. Make it writable in a private
# mount namespace, the same way the Nix daemon does, and start over there.
if [ ! -w "$store" ]; then
  if [ -n "$remounted" ]; then
    echo "selinux-setup: cannot make $store writable" >&2
    exit 1
  fi
  exec unshare --mount -- "$0" --remounted "${saved_args[@]}"
fi

start=$(date +%s)
log "labelling $count store paths"
setfiles -F -f "$work/todo" "$spec"

# Mark the paths only once all of them are labelled, so an interrupted run
# is repeated in full.
xargs -a "$work/todo" -d '\n' -r \
  setfattr -h -n "$marker" -v "$rev" 2>/dev/null || true

log "labelled $count store paths in $(( $(date +%s) - start ))s"
