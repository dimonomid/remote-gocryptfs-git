#!/usr/bin/env bash

# This test uses a real temporary gocryptfs mount. It is skipped when FUSE is
# not available, which is common in containers and CI systems.
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
server_script="$repo_dir/remote-gocryptfs-git-server.sh"

if ! command -v gocryptfs > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1 || ! command -v timeout > /dev/null 2>&1; then
  echo 'SKIP: real gocryptfs test needs gocryptfs, git, and timeout'
  exit 0
fi

test_dir="$(mktemp -d)"
encrypted_root="$test_dir/encrypted"
plaintext_root="$test_dir/plaintext"
state_root="$test_dir/state"
client_repo="$test_dir/client"
mounted=false

cleanup() {
  if [[ "$mounted" == true ]]; then
    timeout 10s env XDG_STATE_HOME="$state_root" bash "$server_script" force-lock "$encrypted_root" "$plaintext_root" > /dev/null 2>&1 || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT

mkdir "$encrypted_root" "$plaintext_root" "$client_repo"

# Create a real encrypted root, then mount it through the server helper. The
# timeout turns a mutex or mount deadlock into a test failure.
timeout 20s gocryptfs -q -init -passfile /dev/stdin "$encrypted_root" <<< 'test-passphrase'

if timeout 20s env XDG_STATE_HOME="$state_root" bash "$server_script" unlock "$encrypted_root" "$plaintext_root" <<< 'test-passphrase' > "$test_dir/unlock.out" 2>&1; then
  :
else
  unlock_status=$?
  if [[ "$unlock_status" == 124 ]]; then
    echo 'FAIL: timed out while creating a gocryptfs mount.' >&2
    exit 1
  fi
  echo 'SKIP: could not create a gocryptfs mount (FUSE may be unavailable)'
  exit 0
fi
mounted=true
mountpoint -q "$plaintext_root"

# Put a real bare repository inside the mount and push one commit to it.
git init --bare "$plaintext_root/test.git" > /dev/null
git -C "$client_repo" init > /dev/null
git -C "$client_repo" config user.name Test
git -C "$client_repo" config user.email test@example.com
printf 'test data\n' > "$client_repo/file.txt"
git -C "$client_repo" add file.txt
git -C "$client_repo" commit -m test > /dev/null
git -C "$client_repo" remote add origin "$plaintext_root/test.git"
timeout 20s git -C "$client_repo" push origin HEAD:main > /dev/null

# Take a second holder, then release both holders. The first lock must leave
# the filesystem mounted; the second one must unmount it. These timeouts also
# catch a gocryptfs daemon that accidentally keeps the server mutex open.
timeout 20s env XDG_STATE_HOME="$state_root" bash "$server_script" unlock "$encrypted_root" "$plaintext_root" <<< 'test-passphrase' > /dev/null
timeout 20s env XDG_STATE_HOME="$state_root" bash "$server_script" lock "$encrypted_root" "$plaintext_root" > /dev/null
mountpoint -q "$plaintext_root"
timeout 20s env XDG_STATE_HOME="$state_root" bash "$server_script" lock "$encrypted_root" "$plaintext_root" > /dev/null
! mountpoint -q "$plaintext_root"
mounted=false

echo 'PASS: real gocryptfs mount and Git repository'
