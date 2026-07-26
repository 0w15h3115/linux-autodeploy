#!/bin/bash
# run-tests.sh -- validate kali-autodeploy-laptop before it touches hardware.
#
# Runs static analysis on the host, then the full suite inside a throwaway
# kalilinux/kali-rolling container. Nothing here modifies your machine.
#
# Usage: tests/run-tests.sh [--static-only]
#
# Requires: docker.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/kali-autodeploy-laptop"
IMAGE="kalilinux/kali-rolling:latest"
STATIC_ONLY=0

[[ "${1:-}" == "--static-only" ]] && STATIC_ONLY=1

green() { echo -e "\033[0;32m$*\033[0m"; }
red()   { echo -e "\033[0;31m$*\033[0m"; }
head_() { echo -e "\n\033[1;34m== $1\033[0m"; }

rc=0

head_ "Static analysis (host)"

if bash -n "$SCRIPT"; then
    green "  PASS bash -n"
else
    red   "  FAIL bash -n"; rc=1
fi

if command -v shellcheck &>/dev/null; then
    SC=(shellcheck)
elif docker image inspect koalaman/shellcheck:stable &>/dev/null; then
    SC=(docker run --rm -v "$REPO:/mnt" koalaman/shellcheck:stable)
    SCRIPT_IN_SC="/mnt/$(basename "$SCRIPT")"
else
    SC=()
fi

if (( ${#SC[@]} )); then
    target="${SCRIPT_IN_SC:-$SCRIPT}"
    if "${SC[@]}" -S warning "$target"; then
        green "  PASS shellcheck (warning+)"
    else
        red   "  FAIL shellcheck"; rc=1
    fi
else
    echo "  SKIP shellcheck (not installed; docker pull koalaman/shellcheck:stable)"
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
    -e SCRIPT=/repo/kali-autodeploy-laptop \
    "$IMAGE" \
    bash /repo/tests/container-tests.sh
container_rc=$?

(( container_rc == 0 )) || rc=1

echo ""
(( rc == 0 )) && green "ALL TESTS PASSED" || red "TESTS FAILED"
exit $rc
