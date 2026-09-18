#!/usr/bin/env bash
# Wire the versioned hooks of .githooks into this clone.
#
# Run once per clone, and once per worktree: core.hooksPath is a repository
# setting, so a fresh clone starts with none and every hook in .githooks is
# dead until this runs. Nothing warns about it, which is exactly why the last
# line below prints what git actually resolved rather than claiming success.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

git config --local core.hooksPath .githooks
# Full path on purpose: the workstation profile aliases chmod, and the alias
# chokes on these arguments.
/bin/chmod +x .githooks/* scripts/*.sh

echo "$(basename "$REPO_ROOT"): core.hooksPath = $(git config --get core.hooksPath), pre-push runs scripts/history-scan.sh then scripts/security-scan.sh"
