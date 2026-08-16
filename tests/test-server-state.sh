#!/usr/bin/env bash

# Test the server-side counter without mounting a real FUSE filesystem.
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
server_script="$repo_dir/remote-gocryptfs-git-server.sh"
test_dir="$(mktemp -d)"
encrypted_root="$test_dir/encrypted"
plaintext_root="$test_dir/plaintext"
other_plaintext_root="$test_dir/other-plaintext"
state_root="$test_dir/state"
mount_marker="$test_dir/mounted"

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT

mkdir "$encrypted_root" "$plaintext_root" "$other_plaintext_root"

# These commands replace the real mount commands for this test. They are
# exported so that the server script sees them when it starts a new Bash.
mountpoint() {
  local path="${!#}"
  [[ "$path" == "$plaintext_root" && -d "$mount_marker" ]]
}

findmnt() {
  printf 'fuse.gocryptfs\n'
}

gocryptfs() {
  mkdir "$mount_marker"
}

fusermount3() {
  rmdir "$mount_marker"
}

export plaintext_root mount_marker
export -f mountpoint findmnt gocryptfs fusermount3

run_server() {
  XDG_STATE_HOME="$state_root" bash "$server_script" "$@"
}

unlock() {
  printf 'test-passphrase\n' | run_server unlock "$encrypted_root" "$plaintext_root"
}

lock() {
  run_server lock "$encrypted_root" "$plaintext_root"
}

force_lock() {
  run_server force-lock "$encrypted_root" "$plaintext_root"
}

unlock > "$test_dir/unlock-1.out"
grep -q 'active holders: 1' "$test_dir/unlock-1.out"
test -d "$mount_marker"

unlock > "$test_dir/unlock-2.out"
grep -q 'active holders: 2' "$test_dir/unlock-2.out"

lock > "$test_dir/lock-1.out"
grep -q 'Leaving the git root unlocked; active holders: 1' "$test_dir/lock-1.out"
test -d "$mount_marker"

# Make the continuous mount look old. A second holder lets lock leave it
# mounted and print the warning instead of unmounting it.
state_file="$(find "$state_root" -name '*.state' -print -quit)"
sed -i 's/^mounted_since=.*/mounted_since=1/' "$state_file"
unlock > /dev/null
lock > "$test_dir/stale-lock.out" 2>&1
grep -q 'WARNING: this gocryptfs root has been mounted' "$test_dir/stale-lock.out"
test -d "$mount_marker"

# A different plaintext root for the same encrypted root must not share the
# state while the original root is mounted.
if run_server lock "$encrypted_root" "$other_plaintext_root" > "$test_dir/conflict.out" 2>&1; then
  echo 'Using a conflicting plaintext root unexpectedly succeeded.' >&2
  exit 1
fi
grep -q 'Refusing to use a different plaintext root' "$test_dir/conflict.out"

force_lock > "$test_dir/force-lock.out" 2>&1
grep -q 'force-locked' "$test_dir/force-lock.out"
test ! -d "$mount_marker"

state_file="$(find "$state_root" -name '*.state' -print -quit)"
grep -qx 'ref_count=0' "$state_file"
grep -qx 'mounted_since=0' "$state_file"

echo 'PASS: server state and counter'
