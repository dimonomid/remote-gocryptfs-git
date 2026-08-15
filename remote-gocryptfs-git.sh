#!/usr/bin/env bash

# This is a client part of remote-gocryptfs-git wrapper.
# See https://github.com/dimonomid/remote-gocryptfs-git

set -Eeuo pipefail

PORT="${PORT:-22}"

# SSH destination from the environment. Examples: "user@example.com" or
# "user@192.0.2.10".
DEST="${DEST:-}"

# Path on the remote server to the gocryptfs-encrypted dir with git repos.
ENCRYPTED_GIT_ROOT="${ENCRYPTED_GIT_ROOT:-}"
# Path on the remote server to the mountpoint where plaintext git repos
# dir will be mounted.
PLAINTEXT_GIT_ROOT="${PLAINTEXT_GIT_ROOT:-}"
REMOTE_HELPER="remote-gocryptfs-git-server.sh"

usage() {
  >&2 echo "Usage: $0 <git|lock|unlock>"
}

read_passphrase() {
  passphrase="${REMOTE_REPO_GOCRYPTFS_PASSPHRASE:-}"
  if [[ "$passphrase" == "" ]]; then
    # Read secret in a POSIX-compliant way (https://stackoverflow.com/a/3980713)
    stty -echo
    echo "NOTE: If you don't want to be asked the passphrase every single time, do this:"
    echo '$ export REMOTE_REPO_GOCRYPTFS_PASSPHRASE=$(read -s passphrase; echo $passphrase)'
    echo ''
    printf 'But if you want to enter it just for this session, then go ahead: '
    read -r passphrase
    stty echo
    printf "\n"
  fi
}

shell_quote() {
  # Quote a value for the remote login shell. This also keeps spaces and shell
  # characters in configured paths from changing the remote command.
  printf "'%s'" "${1//\'/\'\"\'\"\'}"
}

run_remote() {
  local remote_command
  remote_command="$(shell_quote "$REMOTE_HELPER")"

  local argument
  for argument in "$@"; do
    remote_command+=" $(shell_quote "$argument")"
  done

  ssh -p "$PORT" -- "$DEST" "$remote_command"
}

unlock_remote() {
  read_passphrase
  # The password goes through the encrypted SSH connection on standard input,
  # which is a secure way of transmitting it.
  printf '%s\n' "$passphrase" | run_remote unlock "$ENCRYPTED_GIT_ROOT" "$PLAINTEXT_GIT_ROOT"
}

lock_remote() {
  run_remote lock "$ENCRYPTED_GIT_ROOT" "$PLAINTEXT_GIT_ROOT"
}

acquire_client_mutex() {
  # Do not let two local calls mount and unmount the remote directory at once.
  local runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
  umask 077
  exec 9>"$runtime_dir/remote-gocryptfs-git.lock"
  if ! flock -n 9; then
    echo "Another remote-gocryptfs-git command is running; waiting for it to finish..."
    flock 9
  fi
}

cleanup_after_git() {
  local git_exit_code=$?
  trap - EXIT

  echo "Locking remote repos back..."
  if ! lock_remote; then
    echo "Could not lock the remote git directory." >&2
    if [[ "$git_exit_code" == "0" ]]; then
      exit 1
    fi
  fi

  exit "$git_exit_code"
}

command="${1:-}"
if [[ -z "$DEST" ]]; then
  >&2 echo "Set DEST before using this script, for example: user@example.com or user@192.0.2.10"
  exit 1
fi
if [[ -z "$ENCRYPTED_GIT_ROOT" ]]; then
  >&2 echo "Set ENCRYPTED_GIT_ROOT before using this script: a path on the remote server to the gocryptfs-encrypted dir with git repos, e.g. /home/user/repos_encrypted"
  exit 1
fi
if [[ -z "$PLAINTEXT_GIT_ROOT" ]]; then
  >&2 echo "Set PLAINTEXT_GIT_ROOT before using this script: a path on the remote server to the mountpoint where plaintext git repos dir should be mounted, e.g. /home/user/repos_plain"
  exit 1
fi

if [[ "$command" != "lock" && "$command" != "unlock" && "$command" != "git" ]]; then
  >&2 echo "Unknown command '$command'"
  usage
  exit 1
fi

case "$command" in
  lock)
    acquire_client_mutex
    lock_remote
    ;;
  unlock)
    acquire_client_mutex
    unlock_remote
    ;;
  git)
    shift
    acquire_client_mutex
    echo "Unlocking remote repos..."
    unlock_remote
    trap cleanup_after_git EXIT
    echo "Running git command: git $*"
    echo "------------------------------------------"
    if git "$@"; then
      git_exit_code=0
    else
      git_exit_code=$?
    fi
    echo "------------------------------------------"
    exit "$git_exit_code"
    ;;
esac
