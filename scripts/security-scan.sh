#!/usr/bin/env bash
# Trivy scan of the repository: plaintext secrets, misconfigurations, and any
# dependency advisory should this repository ever grow a manifest.
#
# Why this exists here at all. This repository is PUBLIC on GitHub, and its
# .gitignore says what the danger is: the control script was scrubbed of the
# addresses and the API key it used to carry, and backups of it are excluded by
# name. A secret that reaches a public remote is burned the moment it lands,
# and no later commit takes it back. This scan and the history scan next to it
# are the last things standing between a careless paste and that.
#
# Blocking policy, identical to the other repositories of the house (settled
# 2026-08-29, split in two on 2026-09-04):
#   - ANY CRITICAL blocks, published fix or not.
#   - A HIGH blocks only once a fix exists upstream (--ignore-unfixed).
#   - Everything else is printed and does not block.
#
# Fails closed. A scan that could not run must never read as a clean scan.
# Exit code 2 is reserved for "findings", so every other non-zero code means
# the scan itself broke: trivy fs --exit-code 2 returns 2 on findings and 1 on
# a real error, a single --exit-code 1 cannot tell the two apart.
#
# Why trivy runs twice: the first pass prints everything and never fails, so a
# human sees the full picture; the second re-applies the blocking filter alone.
# The database is warm on the second pass, it costs seconds.
#
# Usage: ./scripts/security-scan.sh, or automatically on git push once
# ./scripts/install-hooks.sh has been run in this clone.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCANNERS=(--scanners "vuln,secret,misconfig")

# Trivy always runs in the pinned image, never from a binary installed on the
# machine: the version that decides a push here must be the one that decides it
# everywhere else in the house. Measured on 14/09/2026 on the wiki repository,
# where a Homebrew trivy was being silently preferred to the container.
#
# The image lives on the private registry, which means this hook needs the VPN.
# That is deliberate and not an oversight: the alternative is a floating public
# tag whose content changes under us, and a scan whose verdict nobody can
# reproduce is worse than a scan that sometimes asks for the tunnel.
#
# The named volume holds the vulnerability database. Without it every run would
# download it again, which turns a seconds long scan into a minutes long one
# and makes the hook something people work around.
TRIVY_IMAGE="${TRIVY_IMAGE:-registry.shpv.work/shpv-dirupt/wiki/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969}"
TRIVY_CACHE_VOLUME="${TRIVY_CACHE_VOLUME:-llm-station-trivy-cache}"

# .git is scanned along with the rest, on purpose. Excluding it saves 0.5 s out
# of 1.16 s on the CUDA station of this family, measured on 2026-09-18, and
# gives up the one
# place where a remote URL carrying a token is written in plaintext,
# .git/config. The half second is not worth that.
trivy_fs() {
	docker run --rm \
		--volume "$REPO_ROOT:/repo:ro" \
		--volume "$TRIVY_CACHE_VOLUME:/root/.cache" \
		--workdir /repo \
		"$TRIVY_IMAGE" \
		fs "$@"
}

fail_scan_broken() {
	cat <<MSG

FAILED: the scan itself could not run (exit code $1). This is NOT a clean
report, and the push is refused for that reason.
Usual causes: Docker stopped on the machine, scan image missing from the
registry, vulnerability database not downloadable, network or VPN down.
MSG
	exit 1
}

echo "==> Trivy, full picture"
# --exit-code 0 only covers the "findings" case: a real error still exits
# non-zero and, under set -e, would kill the script with no message at all.
PICTURE_RC=0
trivy_fs "${SCANNERS[@]}" \
	--no-progress \
	--exit-code 0 \
	. || PICTURE_RC=$?
if [ "$PICTURE_RC" -ne 0 ]; then
	fail_scan_broken "$PICTURE_RC"
fi

echo ""

# Two verdicts, never a single one: they do not answer the same question, and a
# single exit code would make them indistinguishable in the failure message.
# --skip-db-update: the full picture just loaded the database.
verdict() {
	local label="$1"
	shift
	local rc=0
	trivy_fs "${SCANNERS[@]}" \
		--no-progress \
		--quiet \
		--skip-db-update \
		--exit-code 2 \
		"$@" \
		. > /dev/null || rc=$?
	case "$rc" in
		0)
			echo "OK: $label"
			;;
		2)
			echo "BLOCKING: $label"
			BLOCKED=1
			;;
		*)
			fail_scan_broken "$rc"
			;;
	esac
}

BLOCKED=0
echo "==> Trivy, blocking verdicts"
verdict "CRITICAL (fixed or not)" --severity CRITICAL
verdict "HIGH with a published fix" --severity HIGH --ignore-unfixed

if [ "$BLOCKED" -eq 0 ]; then
	echo "OK, nothing blocking."
	exit 0
fi

cat <<'MSG'

FAILED: see the BLOCKING lines above, and the detail in the full picture.
A leaked secret is not fixed by editing the file: it is rotated first, then
removed from the file, and the history is checked for earlier copies.
For anything else, in order of preference:
  1. Raise the dependency or fix the configuration.
  2. If the fix breaks the station, open an issue and write the line in
     .trivyignore WITH its re-audit date.
  3. Bypass the hook once with "git push --no-verify", which sends the finding
     to a public remote where nothing will stop it.
MSG
exit 1
