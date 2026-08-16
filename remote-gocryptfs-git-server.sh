#!/usr/bin/env bash
#
# This is a server part of remote-gocryptfs-git wrapper.
# See https://github.com/dimonomid/remote-gocryptfs-git

set -Eeuo pipefail

STALE_AFTER_SECONDS=600
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/remote-gocryptfs-git"

usage() {
  >&2 echo "Usage: $0 <lock|unlock|force-lock> <encrypted-git-root> <plaintext-git-root>"
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

read_state() {
  REF_COUNT=0
  MOUNTED_SINCE=0
  STATE_PLAINTEXT_GIT_ROOT=""

  if [[ -f "$STATE_FILE" ]]; then
    local key value
    while IFS='=' read -r key value; do
      case "$key" in
        ref_count) REF_COUNT="$value" ;;
        mounted_since) MOUNTED_SINCE="$value" ;;
        plaintext_git_root) STATE_PLAINTEXT_GIT_ROOT="$value" ;;
      esac
    done < "$STATE_FILE"
  fi

  if [[ ! "$REF_COUNT" =~ ^[0-9]+$ || ! "$MOUNTED_SINCE" =~ ^[0-9]+$ ]]; then
    echo "The state file is invalid: $STATE_FILE" >&2
    return 1
  fi
}

write_state() {
  local temporary_state_file="$STATE_FILE.$$"
  umask 077
  {
    echo "ref_count=$REF_COUNT"
    echo "mounted_since=$MOUNTED_SINCE"
    echo "plaintext_git_root=$STATE_PLAINTEXT_GIT_ROOT"
  } > "$temporary_state_file"
  mv -f "$temporary_state_file" "$STATE_FILE"
}

warn_if_stale() {
  if (( REF_COUNT == 0 || MOUNTED_SINCE == 0 )); then
    return
  fi

  local now elapsed
  now="$(date +%s)"
  elapsed=$(( now - MOUNTED_SINCE ))
  if (( elapsed > STALE_AFTER_SECONDS )); then
    echo "WARNING: this gocryptfs root has been mounted for $(( elapsed / 60 )) minutes and still has $REF_COUNT holder(s)." >&2
    echo "WARNING: a client may have crashed without running lock." >&2
    echo "WARNING: if you are sure nobody is using it, run your client wrapper with force-lock." >&2
  fi
}

mount_plaintext_root() {
  if mountpoint -q "$PLAINTEXT_GIT_ROOT"; then
    if is_gocryptfs_mount; then
      echo "The git root is already unlocked; not mounting it again."
      return 0
    fi
    echo "Refusing to use $PLAINTEXT_GIT_ROOT: another filesystem is mounted there." >&2
    return 1
  fi

  shopt -s nullglob dotglob
  local files=("$PLAINTEXT_GIT_ROOT"/*)
  if (( ${#files[@]} != 0 )); then
    echo "The plaintext mount directory $PLAINTEXT_GIT_ROOT is not empty." >&2
    return 1
  fi

  local passphrase
  IFS= read -r passphrase
  echo "Mounting $ENCRYPTED_GIT_ROOT -> $PLAINTEXT_GIT_ROOT"
  # fd 9 is the mutex for this encrypted root. gocryptfs starts a background
  # daemon. Normally, child processes inherit all open file descriptors, so
  # that daemon would inherit fd 9 and keep the mutex locked after this server
  # script exits. The next lock or unlock would then wait for the mutex, but
  # the daemon only exits after an unmount, which needs that same next command.
  #
  # 9>&- closes fd 9 only for gocryptfs. This server script still holds fd 9
  # while the mount is being created and while it writes the new counter.
  printf '%s\n' "$passphrase" | gocryptfs -passfile /dev/stdin "$ENCRYPTED_GIT_ROOT" "$PLAINTEXT_GIT_ROOT" 9>&-
}

unmount_plaintext_root() {
  if ! mountpoint -q "$PLAINTEXT_GIT_ROOT"; then
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
    "$fusermount_command" -u "$PLAINTEXT_GIT_ROOT" 2> /dev/null && return 0
    [[ "$attempt" -lt 21 ]] && sleep 0.1
  done

  echo "Could not unmount $PLAINTEXT_GIT_ROOT after waiting 2 seconds; it is still busy." >&2
  "$fusermount_command" -u "$PLAINTEXT_GIT_ROOT"
}

ensure_plaintext_root_matches_state() {
  if [[ -n "$STATE_PLAINTEXT_GIT_ROOT" && "$STATE_PLAINTEXT_GIT_ROOT" != "$PLAINTEXT_GIT_ROOT" && "$MOUNTED_SINCE" != 0 ]]; then
    echo "This encrypted root is already associated with $STATE_PLAINTEXT_GIT_ROOT." >&2
    echo "Refusing to use a different plaintext root: $PLAINTEXT_GIT_ROOT" >&2
    return 1
  fi
}

unlock() {
  ensure_plaintext_root_matches_state

  if ! mountpoint -q "$PLAINTEXT_GIT_ROOT" && (( REF_COUNT > 0 )); then
    echo "The mount disappeared while $REF_COUNT client(s) still held it; resetting the stale counter." >&2
    REF_COUNT=0
    MOUNTED_SINCE=0
  fi

  mount_plaintext_root
  if (( REF_COUNT == 0 )); then
    MOUNTED_SINCE="$(date +%s)"
    STATE_PLAINTEXT_GIT_ROOT="$PLAINTEXT_GIT_ROOT"
  fi
  REF_COUNT=$(( REF_COUNT + 1 ))
  write_state
  echo "The git root is unlocked; active holders: $REF_COUNT"
}

lock() {
  ensure_plaintext_root_matches_state

  if (( REF_COUNT > 0 )); then
    REF_COUNT=$(( REF_COUNT - 1 ))
  else
    echo "The git root has no active holders; trying to lock it anyway." >&2
  fi

  if (( REF_COUNT > 0 )); then
    write_state
    echo "Leaving the git root unlocked; active holders: $REF_COUNT"
    warn_if_stale
    return 0
  fi

  if unmount_plaintext_root; then
    MOUNTED_SINCE=0
    STATE_PLAINTEXT_GIT_ROOT=""
    write_state
    echo "The git root is locked."
  else
    write_state
    return 1
  fi
}

force_lock() {
  ensure_plaintext_root_matches_state
  if (( REF_COUNT > 0 )); then
    echo "WARNING: force-lock is discarding $REF_COUNT active holder(s)." >&2
  fi
  REF_COUNT=0

  if unmount_plaintext_root; then
    MOUNTED_SINCE=0
    STATE_PLAINTEXT_GIT_ROOT=""
    write_state
    echo "The git root was force-locked."
  else
    write_state
    return 1
  fi
}

if [[ "$#" != 3 || ( "$1" != "lock" && "$1" != "unlock" && "$1" != "force-lock" ) ]]; then
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
if [[ ! -d "$ENCRYPTED_GIT_ROOT" ]]; then
  echo "Encrypted git root does not exist: $ENCRYPTED_GIT_ROOT" >&2
  exit 1
fi

mkdir -p "$PLAINTEXT_GIT_ROOT"
ENCRYPTED_GIT_ROOT="$(readlink -f -- "$ENCRYPTED_GIT_ROOT")"
PLAINTEXT_GIT_ROOT="$(readlink -f -- "$PLAINTEXT_GIT_ROOT")"

umask 077
mkdir -p "$STATE_DIR"
state_key="$(printf '%s\0%s' "$ENCRYPTED_GIT_ROOT" "remote-gocryptfs-git" | sha256sum | awk '{print $1}')"
STATE_FILE="$STATE_DIR/$state_key.state"
STATE_LOCK_FILE="$STATE_DIR/$state_key.lock"
# fd 9 is closed for gocryptfs above so its daemon cannot keep this mutex.
exec 9> "$STATE_LOCK_FILE"
if ! flock -n 9; then
  echo "Another client is changing this git root; waiting for the server mutex..."
  flock 9
fi
read_state

case "$command" in
  unlock) unlock ;;
  lock) lock ;;
  force-lock) force_lock ;;
  # No default case: the command was validated above.
esac
