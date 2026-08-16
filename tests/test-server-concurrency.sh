#!/usr/bin/env bash

# Test that two server calls use the same mutex and counter.
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
server_script="$repo_dir/remote-gocryptfs-git-server.sh"
test_dir="$(mktemp -d)"
encrypted_root="$test_dir/encrypted"
plaintext_root="$test_dir/plaintext"
state_root="$test_dir/state"
mount_marker="$test_dir/mounted"
first_pid=""
second_pid=""

cleanup() {
  # Let a deliberately paused fake mount finish before removing its files.
  touch "$test_dir/allow-mount" 2> /dev/null || true
  [[ -n "$first_pid" ]] && kill "$first_pid" 2> /dev/null || true
  [[ -n "$second_pid" ]] && kill "$second_pid" 2> /dev/null || true
  rm -rf "$test_dir"
}
trap cleanup EXIT

mkdir "$encrypted_root" "$plaintext_root"

mountpoint() {
  local path="${!#}"
  [[ "$path" == "$plaintext_root" && -d "$mount_marker" ]]
}

findmnt() {
  printf 'fuse.gocryptfs\n'
}

gocryptfs() {
  touch "$test_dir/mount-started"
  while [[ ! -e "$test_dir/allow-mount" ]]; do
    sleep 0.05
  done
  mkdir "$mount_marker"
}

fusermount3() {
  rmdir "$mount_marker"
}

export plaintext_root mount_marker test_dir
export -f mountpoint findmnt gocryptfs fusermount3

run_server() {
  XDG_STATE_HOME="$state_root" bash "$server_script" "$@"
}

wait_for_file() {
  local path="$1"
  local attempt
  for attempt in {1..100}; do
    [[ -e "$path" ]] && return 0
    sleep 0.05
  done
  echo "Timed out waiting for $path" >&2
  return 1
}

printf 'test-passphrase\n' | run_server unlock "$encrypted_root" "$plaintext_root" > "$test_dir/first.out" 2>&1 &
first_pid=$!
wait_for_file "$test_dir/mount-started"

printf 'test-passphrase\n' | run_server unlock "$encrypted_root" "$plaintext_root" > "$test_dir/second.out" 2>&1 &
second_pid=$!
sleep 0.2

# The second call must still be waiting for the first mount to finish.
if ! kill -0 "$second_pid" 2> /dev/null; then
  echo 'The second unlock did not wait for the server mutex.' >&2
  exit 1
fi
grep -q 'waiting for the server mutex' "$test_dir/second.out"

touch "$test_dir/allow-mount"
wait "$first_pid"
first_pid=""
wait "$second_pid"
second_pid=""

grep -q 'active holders: 1' "$test_dir/first.out"
grep -q 'active holders: 2' "$test_dir/second.out"
test -d "$mount_marker"

# Two locks started at the same time must leave one holder after the first and
# unmount after the second.
run_server lock "$encrypted_root" "$plaintext_root" > "$test_dir/lock-1.out" 2>&1 &
first_pid=$!
run_server lock "$encrypted_root" "$plaintext_root" > "$test_dir/lock-2.out" 2>&1 &
second_pid=$!
wait "$first_pid"
first_pid=""
wait "$second_pid"
second_pid=""

grep -q 'Leaving the git root unlocked; active holders: 1' "$test_dir/lock-1.out" "$test_dir/lock-2.out"
grep -q 'The git root is locked.' "$test_dir/lock-1.out" "$test_dir/lock-2.out"
test ! -d "$mount_marker"

echo 'PASS: server concurrency'
