#!/bin/bash
# run-tests.sh -- validate the deploy scripts before they touch hardware.
#
# Runs static analysis on the host, then the full suite inside a throwaway
# kalilinux/kali-rolling container. Both deploy scripts are exercised. Nothing
# here modifies your machine.
#
# Usage: tests/run-tests.sh [--static-only]
#
# Requires: docker.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHYSICAL="kali-deploy-physical"      # scripts under test, repo-relative
REMOTE="kali-deploy-remote"
VM="kali-deploy-vm"                  # static analysis only; see CHECK_FILES
TAILS="test-with-tails"              # static analysis only; see CHECK_FILES
IMAGE="kalilinux/kali-rolling:latest"
STATIC_ONLY=0

[[ "${1:-}" == "--static-only" ]] && STATIC_ONLY=1

green() { echo -e "\033[0;32m$*\033[0m"; }
red()   { echo -e "\033[0;31m$*\033[0m"; }
head_() { echo -e "\n\033[1;34m== $1\033[0m"; }

rc=0

head_ "Static analysis (host)"

# Every maintained script, repo-relative. archive/ is deliberately excluded --
# those are superseded and full of the very patterns the current scripts were
# written to avoid. $TAILS is checked here but not in the container suite:
# Tails has no container image, and its install path needs Tor and the live
# session's amnesia user.
#
# $VM is static-only for a related reason: its phases branch on
# systemd-detect-virt reporting "microsoft" and on /sys probes for a battery,
# a backlight and a wireless device. A container reports none of those, so the
# hyperv phase would no-op and the config phases would be exercised on exactly
# one branch of the three they were written to choose between -- a green tick
# that proves nothing about the platform the script exists for.
CHECK_FILES=(
    "$PHYSICAL"
    "$REMOTE"
    "$VM"
    "$TAILS"
    tests/run-tests.sh
    tests/container-tests.sh
)

for f in "${CHECK_FILES[@]}"; do
    if bash -n "$REPO/$f"; then
        green "  PASS bash -n     $f"
    else
        red   "  FAIL bash -n     $f"; rc=1
    fi
done

# Prefer a host shellcheck; fall back to the container image so this works on a
# machine that has docker but not shellcheck (and in CI, which has both).
if command -v shellcheck &>/dev/null; then
    sc_run() { shellcheck -S warning "${@/#/$REPO/}"; }
elif docker image inspect koalaman/shellcheck:stable &>/dev/null 2>&1 \
     || docker pull -q koalaman/shellcheck:stable &>/dev/null; then
    sc_run() {
        docker run --rm -v "$REPO:/mnt" koalaman/shellcheck:stable \
            -S warning "${@/#//mnt/}"
    }
else
    sc_run() { return 127; }
fi

if sc_out=$(sc_run "${CHECK_FILES[@]}" 2>&1); then
    green "  PASS shellcheck  (warning+, ${#CHECK_FILES[@]} files)"
elif (( $? == 127 )); then
    echo  "  SKIP shellcheck  (no shellcheck and no docker)"
else
    red   "  FAIL shellcheck"; rc=1
    sed 's/^/    /' <<<"$sc_out" | head -40
fi

if (( STATIC_ONLY )); then
    exit $rc
fi

head_ "Container suite ($IMAGE)"

if ! docker info &>/dev/null; then
    red "  docker is not reachable -- cannot run the container suite"
    exit 1
fi

docker image inspect "$IMAGE" &>/dev/null || {
    echo "  pulling $IMAGE ..."
    docker pull "$IMAGE" || { red "  pull failed"; exit 1; }
}

# --network host so apt can reach the Kali mirrors through whatever the host
# uses. Read-only bind mount: the tests must never modify the repo.
docker run --rm \
    -v "$REPO:/repo:ro" \
    -e SCRIPT="/repo/$PHYSICAL" \
    -e SCRIPT_REMOTE="/repo/$REMOTE" \
    "$IMAGE" \
    bash /repo/tests/container-tests.sh
container_rc=$?

(( container_rc == 0 )) || rc=1

echo ""
(( rc == 0 )) && green "ALL TESTS PASSED" || red "TESTS FAILED"
exit $rc
