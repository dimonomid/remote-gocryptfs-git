#!/usr/bin/env bash
#
# This is a server part of remote-gocryptfs-git wrapper.
# See https://github.com/dimonomid/remote-gocryptfs-git

set -Eeuo pipefail

usage() {
  >&2 echo "Usage: $0 <lock|unlock> <encrypted-git-root> <plaintext-git-root>"
}

is_gocryptfs_mount() {
  [[ "$(findmnt -rn -M "$PLAINTEXT_GIT_ROOT" -o FSTYPE 2>/dev/null)" == "fuse.gocryptfs" ]]
}

unmount_command() {
  if command -v fusermount3 > /dev/null 2>&1; then
    echo fusermount3
  elif command -v fusermount > /dev/null 2>&1; then
    echo fusermount
  else
    echo "Neither fusermount3 nor fusermount is installed." >&2
    return 1
  fi
}

unlock() {
  if mountpoint -q "$PLAINTEXT_GIT_ROOT"; then
    if is_gocryptfs_mount; then
      echo "The git root is already unlocked."
      return 0
    fi
    echo "Refusing to use $PLAINTEXT_GIT_ROOT: another filesystem is mounted there." >&2
    return 1
  fi

  if [[ ! -d "$ENCRYPTED_GIT_ROOT" ]]; then
    echo "Encrypted git root does not exist: $ENCRYPTED_GIT_ROOT" >&2
    return 1
  fi

  mkdir -p "$PLAINTEXT_GIT_ROOT"
  shopt -s nullglob dotglob
  local files=("$PLAINTEXT_GIT_ROOT"/*)
  if (( ${#files[@]} != 0 )); then
    echo "The plaintext mount directory $PLAINTEXT_GIT_ROOT is not empty." >&2
    return 1
  fi

  local passphrase
  IFS= read -r passphrase
  echo "Mounting $ENCRYPTED_GIT_ROOT -> $PLAINTEXT_GIT_ROOT"
  printf '%s\n' "$passphrase" | gocryptfs -passfile /dev/stdin "$ENCRYPTED_GIT_ROOT" "$PLAINTEXT_GIT_ROOT"
}

lock() {
  if ! mountpoint -q "$PLAINTEXT_GIT_ROOT"; then
    echo "The git root is already locked."
    return 0
  fi
  if ! is_gocryptfs_mount; then
    echo "Refusing to unmount $PLAINTEXT_GIT_ROOT: it is not a gocryptfs mount." >&2
    return 1
  fi

  local fusermount_command
  fusermount_command="$(unmount_command)"
  echo "Unmounting $PLAINTEXT_GIT_ROOT"

  local attempt
  for attempt in {1..21}; do
    "$fusermount_command" -u "$PLAINTEXT_GIT_ROOT" 2>/dev/null && return 0
    [[ "$attempt" -lt 21 ]] && sleep 0.1
  done

  echo "Could not unmount $PLAINTEXT_GIT_ROOT after waiting 2 seconds; it is still busy." >&2
  "$fusermount_command" -u "$PLAINTEXT_GIT_ROOT"
}

if [[ "$#" != 3 || ( "$1" != "lock" && "$1" != "unlock" ) ]]; then
  usage
  exit 1
fi

command="$1"
ENCRYPTED_GIT_ROOT="$2"
PLAINTEXT_GIT_ROOT="$3"

if [[ "$ENCRYPTED_GIT_ROOT" != /* || "$PLAINTEXT_GIT_ROOT" != /* ]]; then
  echo "Both git root paths must be absolute paths." >&2
  exit 1
fi

case "$command" in
  unlock) unlock ;;
  lock) lock ;;
  *)
    usage
    exit 1
    ;;
esac
