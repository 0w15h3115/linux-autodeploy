#!/bin/bash
# container-tests.sh -- runs INSIDE a kalilinux/kali-rolling container.
# Invoked by run-tests.sh; not meant to be run on your own machine (it installs
# packages and creates users).
#
# The point of these tests is that a deploy failure on real hardware costs you
# an OS reinstall. Everything that can be caught in a container is caught here.

set -uo pipefail

SCRIPT="${SCRIPT:-/repo/kali-autodeploy-physical}"
TEST_USER="tester"
FAILED=0
PASSED=0

pass() { echo -e "\033[0;32m  PASS\033[0m $1"; PASSED=$((PASSED+1)); }
fail() { echo -e "\033[0;31m  FAIL\033[0m $1"; FAILED=$((FAILED+1)); }
head_() { echo -e "\n\033[1;34m== $1\033[0m"; }

# Mimic `sudo ./script`: root euid with SUDO_USER pointing at a real account.
as_sudo() { SUDO_USER="$TEST_USER" DEBIAN_FRONTEND=noninteractive "$SCRIPT" "$@"; }

head_ "Setup"
id "$TEST_USER" &>/dev/null || useradd -m -s /usr/bin/zsh "$TEST_USER"
USER_HOME=$(getent passwd "$TEST_USER" | cut -d: -f6)
echo "  test user: $TEST_USER ($USER_HOME)"

apt-get update -qq >/dev/null 2>&1
echo "  apt lists updated"

# The base kali-rolling image is minimal; the tests themselves need a few
# utilities that a real Kali install would already have.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    findutils coreutils gawk sed grep procps iproute2 >/dev/null 2>&1
# i3 itself, so T4 can validate the generated config with `i3 -C`. A syntax
# error there means a desktop that won't start at the greeter, which is
# precisely the failure this suite exists to catch before it reaches hardware.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    --no-install-recommends i3-wm >/dev/null 2>&1
echo "  test prerequisites installed"

# ------------------------------------------------------------------------------
head_ "T1: every package name resolves"
# This is the test that matters most. v4 died because openjdk-8-jre had no
# installation candidate and took the entire apt batch down with it.
# ------------------------------------------------------------------------------
missing=()
while read -r pkg; do
    [[ -z "$pkg" ]] && continue
    cand=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')
    if [[ -z "$cand" || "$cand" == "(none)" ]]; then
        missing+=("$pkg")
        echo "    no candidate: $pkg"
    fi
done < <("$SCRIPT" --print-packages)

if (( ${#missing[@]} == 0 )); then
    pass "all packages have an installation candidate"
else
    fail "${#missing[@]} package(s) unresolvable: ${missing[*]}"
fi

# ------------------------------------------------------------------------------
head_ "T2: dependency resolution (apt --simulate)"
# Catches conflicts between metapackages without downloading gigabytes.
# ------------------------------------------------------------------------------
mapfile -t all_pkgs < <("$SCRIPT" --print-packages)
resolvable=()
for p in "${all_pkgs[@]}"; do
    cand=$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2}')
    [[ -n "$cand" && "$cand" != "(none)" ]] && resolvable+=("$p")
done

sim_out=$(apt-get install --simulate -y "${resolvable[@]}" 2>&1)
if (( $? == 0 )); then
    n=$(grep -cE '^Inst ' <<<"$sim_out")
    pass "apt resolves the full set ($n packages would be installed)"
else
    fail "apt could not resolve the set"
    grep -iE 'unmet|conflict|broken|E:' <<<"$sim_out" | head -10 | sed 's/^/    /'
fi

# ------------------------------------------------------------------------------
head_ "T3: --dry-run changes nothing"
# ------------------------------------------------------------------------------
before=$(find "$USER_HOME" /etc/NetworkManager -type f 2>/dev/null | sort | md5sum)
if as_sudo --dry-run >/tmp/dryrun.log 2>&1; then
    pass "--dry-run exits 0"
else
    fail "--dry-run exited $? (see /tmp/dryrun.log)"
    tail -15 /tmp/dryrun.log | sed 's/^/    /'
fi
after=$(find "$USER_HOME" /etc/NetworkManager -type f 2>/dev/null | sort | md5sum)
[[ "$before" == "$after" ]] \
    && pass "--dry-run left the filesystem untouched" \
    || fail "--dry-run modified the filesystem"

grep -q 'dry-run' /tmp/dryrun.log \
    && pass "--dry-run annotated its actions" \
    || fail "--dry-run produced no [dry-run] lines"

# ------------------------------------------------------------------------------
head_ "T4: config phases run for real and exit 0"
# The apt phases are simulated above; here we actually execute the phases that
# write configuration, which is where ownership and idempotency bugs live.
# ------------------------------------------------------------------------------
if as_sudo --only i3 --only polybar --only kitty --only shell --only wordlists \
        >/tmp/config.log 2>&1; then
    pass "config phases exit 0"
else
    fail "config phases exited non-zero (see /tmp/config.log)"
    tail -20 /tmp/config.log | sed 's/^/    /'
fi

for f in .config/i3/config .config/polybar/config.ini .config/polybar/launch.sh \
         .config/kitty/kitty.conf; do
    if [[ -f "$USER_HOME/$f" ]]; then
        owner=$(stat -c '%U' "$USER_HOME/$f")
        [[ "$owner" == "$TEST_USER" ]] \
            && pass "$f written, owned by $TEST_USER" \
            || fail "$f owned by $owner, expected $TEST_USER"
    else
        fail "$f was not created"
    fi
done

[[ -x "$USER_HOME/.config/polybar/launch.sh" ]] \
    && pass "launch.sh is executable" \
    || fail "launch.sh is not executable"

# i3 config must actually parse. i3 -C validates without an X display.
if command -v i3 &>/dev/null; then
    if i3 -C -c "$USER_HOME/.config/i3/config" >/tmp/i3check.log 2>&1; then
        pass "i3 validates the generated config"
    else
        fail "i3 rejected the generated config"
        head -10 /tmp/i3check.log | sed 's/^/    /'
    fi
else
    echo "    (i3 not installed in container -- skipping config validation)"
fi

# ------------------------------------------------------------------------------
head_ "T5: idempotency -- second run must not duplicate"
# ------------------------------------------------------------------------------
as_sudo --only shell >/dev/null 2>&1
as_sudo --only shell >/dev/null 2>&1
n=$(grep -cF '>>> kali-autodeploy-physical >>>' "$USER_HOME/.zshrc")
(( n == 1 )) \
    && pass "zshrc block appears exactly once after 3 runs" \
    || fail "zshrc block appears $n times (expected 1)"

as_sudo --only i3 --only polybar --only kitty >/tmp/rerun.log 2>&1 \
    && pass "config phases re-run cleanly" \
    || fail "config phases failed on re-run"

# ------------------------------------------------------------------------------
head_ "T6: graceful degradation -- no systemd, no ufw"
# A container has no systemd and no running firewall. The harden phase must warn
# and carry on, not abort. This is the same code path as a phase failing on real
# hardware.
# ------------------------------------------------------------------------------
if as_sudo --only harden >/tmp/harden.log 2>&1; then
    pass "harden phase exits 0 without systemd"
else
    fail "harden phase exited non-zero without systemd"
    tail -15 /tmp/harden.log | sed 's/^/    /'
fi

# ------------------------------------------------------------------------------
head_ "T7: failure injection -- a bogus package must not abort the run"
# ------------------------------------------------------------------------------
sed 's/^    kali-tools-rfid$/    kali-tools-rfid\n    kali-tools-doesnotexist/' \
    "$SCRIPT" > /tmp/injected && chmod +x /tmp/injected

if SCRIPT=/tmp/injected as_sudo --only wordlists >/dev/null 2>&1; then
    pass "script still parses with an injected bad package"
fi

inj_out=$(SUDO_USER="$TEST_USER" /tmp/injected --print-packages 2>/dev/null | grep -c doesnotexist)
(( inj_out == 1 )) && pass "injection landed in the package list" \
                   || fail "injection did not land (test is not exercising anything)"

# The real assertion: probing an unavailable package reports it and moves on.
if SUDO_USER="$TEST_USER" DEBIAN_FRONTEND=noninteractive /tmp/injected \
        --only tools --dry-run >/tmp/inject.log 2>&1; then
    grep -q "kali-tools-doesnotexist" /tmp/inject.log \
        && pass "bogus package reported as unavailable" \
        || fail "bogus package was not reported"
    pass "run continued to completion despite bogus package"
else
    fail "run aborted on a bogus package (exit $?)"
    tail -15 /tmp/inject.log | sed 's/^/    /'
fi

# ------------------------------------------------------------------------------
head_ "T8: bad input is rejected"
# ------------------------------------------------------------------------------
as_sudo --only nosuchphase >/dev/null 2>&1 \
    && fail "unknown phase was accepted" \
    || pass "unknown phase rejected"

as_sudo --skip >/dev/null 2>&1 \
    && fail "--skip with no argument was accepted" \
    || pass "--skip with no argument rejected"

if SUDO_USER="root" "$SCRIPT" --only wordlists >/dev/null 2>&1; then
    fail "running as root directly was accepted"
else
    pass "running as root directly is rejected"
fi

# --help prints the header comment block. It used to do that by hardcoded line
# range, so trimming the header spilled `set -uo pipefail` and the readonly
# declarations into the help output. Assert no shell code leaks.
help_out=$("$SCRIPT" --help 2>&1)
if grep -qE '^\s*(set -|readonly |[A-Z_]+=\(|\}|fi$)' <<<"$help_out"; then
    fail "--help is leaking shell code"
    grep -nE '^\s*(set -|readonly |[A-Z_]+=\(|\}|fi$)' <<<"$help_out" | head -5 | sed 's/^/    /'
else
    pass "--help contains no shell code"
fi

grep -q -- '--dry-run' <<<"$help_out" \
    && pass "--help documents the options" \
    || fail "--help is missing the options block"

# ------------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  passed: $PASSED   failed: $FAILED"
echo "=============================================="
exit $(( FAILED > 0 ? 1 : 0 ))
