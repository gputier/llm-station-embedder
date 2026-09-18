#!/usr/bin/env bash
# Gitleaks over the commits a push is about to send.
#
# Why this exists next to security-scan.sh, which already looks for secrets.
# Trivy scans the FILESYSTEM: the working tree as it stands right now. A secret
# added in one commit and removed by the next is invisible to it, and both
# commits still leave in the same push. On a public remote that is the whole
# accident: the file looks clean, the history carries the key, and GitHub
# indexes the history.
#
# Gitleaks reads the object graph instead, so it sees what is actually sent.
# Measured on 2026-09-18: 2 commits, 48 KB, 89 ms. It costs nothing worth
# skipping.
#
# Called with no argument, it scans every reachable commit. Called with a
# revision range, only that range, which is what the pre-push hook passes.
#
# Image pinned by digest, like the Trivy one, and for the same reason: a
# floating tag changes content under us and makes a verdict impossible to
# reproduce. This one comes from Docker Hub rather than the private registry,
# so the gate keeps working from a clone with no VPN.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GITLEAKS_IMAGE="${GITLEAKS_IMAGE:-zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f}"

RANGE="${1:-}"

fail_scan_broken() {
	cat <<MSG

FAILED: the history scan itself could not run ($1). This is NOT a clean
report, and the push is refused for that reason.
Usual causes: Docker stopped on the machine, image not pullable, network down,
or a git directory the container cannot reach.
MSG
	exit 1
}

# In a linked worktree, .git is a FILE pointing at a directory outside the
# mount, and gitleaks then reads nothing. Measured on 2026-09-18: it printed
# "not a git repository", scanned 0 commits, reported "no leaks found" AND
# exited 0. A gate that passes because it saw nothing is worse than no gate, so
# the real git directory is mounted at its own absolute path when it sits
# outside the repository, and the commit count is checked below regardless.
GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)"
MOUNTS=(--volume "$REPO_ROOT:/repo:ro")
case "$GIT_COMMON" in
	"$REPO_ROOT"/*) ;;
	*) MOUNTS+=(--volume "$GIT_COMMON:$GIT_COMMON:ro") ;;
esac

# What the host says is in the range, to be compared with what the container
# reports having read.
if [ -n "$RANGE" ]; then
	EXPECTED="$(git -C "$REPO_ROOT" rev-list --count "$RANGE")"
	echo "==> Gitleaks, history being pushed ($RANGE, $EXPECTED commits)"
else
	EXPECTED="$(git -C "$REPO_ROOT" rev-list --count --all)"
	echo "==> Gitleaks, whole reachable history ($EXPECTED commits)"
fi

if [ "$EXPECTED" -eq 0 ]; then
	echo "OK, nothing new to read."
	exit 0
fi

# --redact: a finding is printed without its value. The point is to say which
# commit and which file, never to write the secret into a terminal log that
# then needs cleaning too.
rc=0
OUTPUT="$(docker run --rm "${MOUNTS[@]}" --workdir /repo \
	"$GITLEAKS_IMAGE" \
	git --no-banner --redact ${RANGE:+--log-opts="$RANGE"} /repo 2>&1)" || rc=$?
echo "$OUTPUT"

if [ "$rc" -gt 1 ]; then
	fail_scan_broken "exit code $rc"
fi

# Two checks, because "no leaks found" alone proves nothing.
#
# A git error first. When gitleaks cannot open the repository it says so on one
# line, keeps going, reports no leak and exits 0. Nothing else in a normal run
# prints "fatal:", so the line is the signal.
#
# Then the presence of a count. No count means the run did not reach the end,
# whatever the exit code says.
#
# The count itself is NOT compared to the host's. Measured on 2026-09-18 over a
# range of two commits, one adding a file and one deleting it: gitleaks reports
# "1 commits scanned", because it only reads added lines. Requiring equality
# would refuse any push carrying a pure deletion.
if printf '%s\n' "$OUTPUT" | grep -q "fatal:"; then
	fail_scan_broken "git could not read the repository"
fi

SCANNED="$(printf '%s\n' "$OUTPUT" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) commits scanned.*/\1/p' | tail -1)"
if [ -z "$SCANNED" ]; then
	fail_scan_broken "no commit count in the output"
fi

if [ "$rc" -eq 1 ]; then
	cat <<'MSG'

FAILED: gitleaks found a secret in a commit this push would send.
Editing the file is not enough, the commit still carries it. Rotate the secret
first, then rewrite the history that holds it, then push.
MSG
	exit 1
fi

echo "OK, no secret in the $SCANNED commits gitleaks read out of $EXPECTED pushed."
