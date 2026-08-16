#!/usr/bin/env bash

set -Eeuo pipefail

tests_dir="$(cd "$(dirname "$0")" && pwd)"

bash "$tests_dir/test-server-state.sh"
bash "$tests_dir/test-server-concurrency.sh"
bash "$tests_dir/test-gocryptfs.sh"
