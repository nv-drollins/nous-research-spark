#!/usr/bin/env bash
# Convenience wrapper so `./install.sh` from the repo root works too.
# All logic lives in scripts/install.sh.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${DIR}/scripts/install.sh" "$@"
