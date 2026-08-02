#!/bin/bash
# container-tests.sh -- runs INSIDE a kalilinux/kali-rolling container.
# Invoked by run-tests.sh; not meant to be run on your own machine (it installs
# packages and creates users).
#
# The point of these tests is that a deploy failure on real hardware costs you
# an OS reinstall. Everything that can be caught in a container is caught here.
#
# Both deploy scripts are exercised. The shared assertions (package resolution,
# dependency resolution, dry-run inertness, idempotency, argument handling, and
# the verification/install cross-check) run against each; the phases that only
# one script has get their own sections.

set -uo pipefail

PHYSICAL="${SCRIPT:-/repo/kali-deploy-physical}"
REMOTE="${SCRIPT_REMOTE:-/repo/kali-deploy-remote}"
TEST_USER="tester"
FAILED=0
PASSED=0

# Set per suite so as_sudo and the shared tests don't need it threaded through.
SCRIPT="$PHYSICAL"

pass() { echo -e "\033[0;32m  PASS\033[0m $1"; PASSED=$((PASSED+1)); }
fail() { echo -e "\033[0;31m  FAIL\033[0m $1"; FAILED=$((FAILED+1)); }
head_() { echo -e "\n\033[1;34m== $1\033[0m"; }
sect() { echo -e "\n\033[1;35m######## $1\033[0m"; }

# Mimic `sudo ./script`: root euid with SUDO_USER pointing at a real account.
as_sudo() { SUDO_USER="$TEST_USER" DEBIAN_FRONTEND=noninteractive "$SCRIPT" "$@"; }

head_ "Setup"
id "$TEST_USER" &>/dev/null || useradd -m -s /usr/bin/zsh "$TEST_USER"
USER_HOME=$(getent passwd "$TEST_USER" | cut -d: -f6)
echo "  test user: $TEST_USER ($USER_HOME)"

apt-get update -qq >/dev/null 2>&1
echo "  apt lists updated"

# apt-file maps a binary back to the package that ships it, which is how T9
# tells "installed" from "merely verified". Installed up front because the
# package-level checks below need it; nothing it pulls in ships a binary any
# deploy script verifies.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apt-file >/dev/null 2>&1
apt-file update >/dev/null 2>&1
echo "  apt-file cache built"

# The rest of the prerequisites are installed LATER, deliberately.
#
# `apt-get install --simulate` only lists packages it would newly install, so
# anything already present is absent from the closure T9 checks against. Install
# tmux here and T9 reports tmux as verified-but-not-installed -- a false alarm
# that would train you to ignore the one test that catches a real gap. So the
# package-level checks run against a pristine image, and these land afterwards.
install_test_prereqs() {
    head_ "Installing test prerequisites"
    # The base kali-rolling image is minimal; the tests need utilities a real
    # Kali install would already have. ufw so the firewall lockout guard is
    # exercised for real rather than short-circuiting on "ufw not installed".
    # git and sudo are what the dots phase runs on: without them T10 exercises
    # the "git is not installed" short circuit instead of the credential logic,
    # which is the part that actually has to degrade gracefully. Both are in the
    # scripts' own package lists, so installing them here costs the package
    # checks nothing -- those already ran, against a pristine image.
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        findutils coreutils gawk sed grep procps iproute2 tmux ufw git sudo >/dev/null 2>&1
    # i3 itself, so T4 can validate the generated config with `i3 -C`. A syntax
    # error there means a desktop that won't start at the greeter, which is
    # precisely the failure this suite exists to catch before it reaches hardware.
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        --no-install-recommends i3-wm >/dev/null 2>&1
    echo "  test prerequisites installed"
}

# ==============================================================================
# Shared assertions, run against each script.
# ==============================================================================

# T1 -- every package name resolves.
# The test that matters most: v4 died because openjdk-8-jre had no installation
# candidate and took the entire apt batch down with it.
t_packages_resolve() {
    head_ "T1: every package name resolves"
    local missing=() pkg cand
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
}

# T2 -- dependency resolution. Catches conflicts between metapackages without
# downloading gigabytes. Writes the install closure to $CLOSURE for T9.
CLOSURE=/tmp/closure.txt
t_deps_resolve() {
    head_ "T2: dependency resolution (apt --simulate)"
    local all_pkgs resolvable=() p cand sim_out rc
    mapfile -t all_pkgs < <("$SCRIPT" --print-packages)
    for p in "${all_pkgs[@]}"; do
        cand=$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2}')
        [[ -n "$cand" && "$cand" != "(none)" ]] && resolvable+=("$p")
    done

    sim_out=$(apt-get install --simulate -y "${resolvable[@]}" 2>&1); rc=$?
    awk '/^Inst /{print $2}' <<<"$sim_out" | sort -u > "$CLOSURE"

    if (( rc == 0 )); then
        pass "apt resolves the full set ($(wc -l <"$CLOSURE") packages would be installed)"
    else
        fail "apt could not resolve the set"
        grep -iE 'unmet|conflict|broken|E:' <<<"$sim_out" | head -10 | sed 's/^/    /'
    fi
}

# T9 -- every binary the verification pass ticks is actually installed.
#
# This is the test that would have caught the real bug: the physical script
# verified netexec, mitm6, certipy, enum4linux-ng, bloodhound-python, ffuf and
# gobuster while installing none of them. Four were present only because the
# Kali ISO ships kali-linux-default -- luck, not intent, and gone on a netinst.
# A red X at the end of a 40-minute deploy is how you'd have found out.
#
# EXTERNAL_BINS are the deliberate exceptions: things installed from outside
# Kali's repos. Anything else with no providing package is a typo and fails.
t_verified_is_installed() {
    local EXTERNAL_BINS=" tailscale "
    head_ "T9: verified binaries are actually installed"
    local bins b owner o hit missing=() external=()
    mapfile -t bins < <("$SCRIPT" --print-checked-binaries)

    for b in "${bins[@]}"; do
        [[ -z "$b" ]] && continue
        if [[ "$EXTERNAL_BINS" == *" $b "* ]]; then
            external+=("$b"); continue
        fi
        owner=$(apt-file search -x "/(s?bin)/${b}$" 2>/dev/null | cut -d: -f1 | sort -u)
        if [[ -z "$owner" ]]; then
            missing+=("$b (no Kali package ships this binary -- typo?)")
            continue
        fi
        hit=""
        for o in $owner; do
            grep -qxF "$o" "$CLOSURE" && { hit="$o"; break; }
        done
        [[ -z "$hit" ]] && missing+=("$b (needs: $(tr '\n' ' ' <<<"$owner"))")
    done

    if (( ${#missing[@]} == 0 )); then
        pass "all ${#bins[@]} verified binaries are in the install set"
    else
        fail "${#missing[@]} binary(ies) verified but never installed"
        printf '    %s\n' "${missing[@]}"
    fi
    (( ${#external[@]} )) && echo "    (not from Kali repos, by design: ${external[*]})"
    return 0
}

# T3 -- --dry-run changes nothing.
t_dry_run_inert() {
    head_ "T3: --dry-run changes nothing"
    local watch=("$USER_HOME" /etc/NetworkManager /etc/ssh /etc/apt/sources.list.d)
    local before after
    before=$(find "${watch[@]}" -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)
    if as_sudo --dry-run >/tmp/dryrun.log 2>&1; then
        pass "--dry-run exits 0"
    else
        fail "--dry-run exited non-zero (see /tmp/dryrun.log)"
        tail -15 /tmp/dryrun.log | sed 's/^/    /'
    fi
    after=$(find "${watch[@]}" -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum)
    [[ "$before" == "$after" ]] \
        && pass "--dry-run left the filesystem untouched" \
        || fail "--dry-run modified the filesystem"

    grep -q 'dry-run' /tmp/dryrun.log \
        && pass "--dry-run annotated its actions" \
        || fail "--dry-run produced no [dry-run] lines"
}

# T5 -- idempotency. The zshrc block must appear exactly once no matter how many
# times the script runs. The remote script used to have no marker at all, so a
# second run duplicated every alias and the tmux auto-attach hook.
t_idempotent_shell() {
    local marker="$1"
    head_ "T5: idempotency -- second run must not duplicate"
    as_sudo --only shell >/dev/null 2>&1
    as_sudo --only shell >/dev/null 2>&1
    as_sudo --only shell >/dev/null 2>&1
    local n
    n=$(grep -cF "$marker" "$USER_HOME/.zshrc" 2>/dev/null || echo 0)
    (( n == 1 )) \
        && pass "zshrc block appears exactly once after 3 runs" \
        || fail "zshrc block appears $n times (expected 1)"
}

# T10 -- the dots phase. The container has no GitHub credentials, which is
# exactly the state of a freshly imaged box, so the credential-less path is the
# one that gets exercised here -- and it is the one that matters.
#
# What "correct" means here depends on whether github.com is reachable, so the
# suite probes once and asserts the matching outcome rather than accepting
# either. The default DOTS_REPO is public: with a network, no credentials must
# still produce a real checkout via the anonymous clone. This assertion used to
# read the other way -- it required ~/dots to be ABSENT after a credential-less
# run, which was right while the repo was private and silently locked in the
# bug that made a stock box skip the phase on every deploy. Without a network,
# the requirement falls back to the original one: warn, name the command that
# finishes the job, change nothing.
t_dots_phase() {
    head_ "T10: dots phase degrades instead of failing"
    local marker="$1"
    local online=0
    GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/owlshells/dots.git &>/dev/null && online=1

    "$SCRIPT" --list-phases 2>/dev/null | grep -qw dots \
        && pass "dots is a registered phase" \
        || fail "dots missing from --list-phases"

    rm -rf "$USER_HOME/dots"
    if as_sudo --only dots >/tmp/dots.log 2>&1; then
        pass "dots phase exits 0 with no credentials"
    else
        fail "dots phase exited non-zero with no credentials"
        tail -15 /tmp/dots.log | sed 's/^/    /'
    fi

    if (( online )); then
        [[ -d "$USER_HOME/dots/.git" ]] \
            && pass "anonymous clone lands a real checkout with no credentials" \
            || { fail "no ~/dots after a credential-less run against a public repo"
                 tail -15 /tmp/dots.log | sed 's/^/    /'; }
        grep -q 'over public' /tmp/dots.log \
            && pass "reports the anonymous transport it used" \
            || fail "did not name the anonymous transport"
        rm -rf "$USER_HOME/dots"
    else
        echo "    (github.com unreachable -- asserting the offline skip instead)"
        [[ ! -e "$USER_HOME/dots" ]] \
            && pass "no half-made checkout left behind on failure" \
            || fail "$USER_HOME/dots exists after an unreachable run"

        # Every exit from this phase must name the command that completes it later.
        if grep -q 'only dots' /tmp/dots.log; then
            pass "tells you how to finish it later"
        else
            fail "gave no recovery instructions"
            sed 's/^/    /' /tmp/dots.log | tail -10
        fi
    fi

    # A token must never reach the transcript: this script's output is teed to
    # /var/log, and a leaked PAT there outlives the engagement.
    rm -rf "$USER_HOME/dots"
    DOTS_TOKEN="ghp_SUPERSECRETCANARY123" DOTS_REPO="owlshells/definitely-not-a-repo" \
        as_sudo --only dots >/tmp/dotstok.log 2>&1
    if grep -q 'SUPERSECRETCANARY' /tmp/dotstok.log; then
        fail "DOTS_TOKEN leaked into the transcript"
        grep -n 'SUPERSECRETCANARY' /tmp/dotstok.log | head -3 | sed 's/^/    /'
    else
        pass "DOTS_TOKEN never appears in output"
    fi
    [[ ! -e "$USER_HOME/dots" ]] \
        && pass "failed token clone leaves no checkout" \
        || fail "checkout left behind after a failed token clone"

    # An existing non-git directory is someone else's; do not touch it.
    mkdir -p "$USER_HOME/dots"; echo keep > "$USER_HOME/dots/mine.txt"
    chown -R "$TEST_USER:$TEST_USER" "$USER_HOME/dots"
    as_sudo --only dots >/tmp/dots3.log 2>&1
    [[ -f "$USER_HOME/dots/mine.txt" ]] \
        && pass "a non-git ~/dots is left alone" \
        || fail "clobbered a pre-existing non-git ~/dots"
    rm -rf "$USER_HOME/dots"

    # The zshrc block must not define anything dots also defines, except behind
    # the not-installed guard -- `alias serve` would otherwise permanently shadow
    # dots' serve(), since zsh resolves aliases before functions.
    local blk
    blk=$(awk "/${marker}/,/<<< /" "$USER_HOME/.zshrc" 2>/dev/null)
    if [[ -z "$blk" ]]; then
        fail "no zshrc block to inspect (run the shell phase first)"
        return
    fi
    grep -q 'dots/shell/zshrc' <<<"$blk" \
        && pass "zshrc block guards its duplicates on dots being absent" \
        || fail "zshrc block has no dots guard"

    local dup unguarded=0
    for dup in "alias serve=" "alias ports=" "alias listening=" "alias myip=" \
               "export WORDLISTS=" "export SECLISTS=" "b64e()" "urlencode()"; do
        # Every occurrence must sit inside the `if [[ ! -r ...dots... ]]` block.
        if grep -qF "$dup" <<<"$blk" && \
           ! awk '/if \[\[ ! -r .*dots\/shell\/zshrc/,/^fi$/' <<<"$blk" | grep -qF "$dup"; then
            fail "'$dup' is defined outside the dots guard"
            unguarded=1
        fi
    done
    (( unguarded )) || pass "every dots-overlapping definition sits inside the guard"
}

# T11 -- the desktop wallpaper. ~/.fehbg is written by dots' install.sh
# (hook_wallpaper), not by this script: the deploy owns the mechanism -- feh in
# the package list, i3 running ~/.fehbg at session start -- and dots owns the
# image. That split is why this went unnoticed. The defect that left boxes on
# Kali's stock prompt left them on Kali's stock background too, from the same
# skipped phase, and nothing here was watching the second one.
#
# kali-deploy-physical only: feh is in this script's package list and not the
# remote's, and a headless box has no session to draw a background in.
t_wallpaper() {
    head_ "T11: the wallpaper lands via the dots phase"

    if ! GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/owlshells/dots.git &>/dev/null; then
        echo "    (github.com unreachable -- skipped, this needs a real checkout)"
        return
    fi

    rm -rf "$USER_HOME/dots" "$USER_HOME/.fehbg"

    # feh is not installed yet, which is the headless case: the hook must skip
    # rather than leave a ~/.fehbg that i3 would exec into a missing binary.
    as_sudo --only dots >/tmp/wall0.log 2>&1
    [[ ! -e "$USER_HOME/.fehbg" ]] \
        && pass "no ~/.fehbg written on a box without feh" \
        || fail "wrote ~/.fehbg despite feh being absent"

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        --no-install-recommends feh >/dev/null 2>&1
    if ! command -v feh &>/dev/null; then
        echo "    (feh unavailable in this image -- skipping the rest)"
        return
    fi

    rm -rf "$USER_HOME/dots"
    as_sudo --only dots >/tmp/wall1.log 2>&1

    [[ -f "$USER_HOME/dots/terminal/wallpaper.png" ]] \
        && pass "the checkout carries terminal/wallpaper.png" \
        || fail "no terminal/wallpaper.png in the checkout"

    # i3's line is `[ -x $HOME/.fehbg ] && $HOME/.fehbg`, so a file that exists
    # but is not executable is silently no desktop background at all.
    [[ -x "$USER_HOME/.fehbg" ]] \
        && pass "the ~/.fehbg hook exists and is executable (i3's guard tests -x)" \
        || fail "the ~/.fehbg hook is missing or not executable -- i3 will skip it"

    head -1 "$USER_HOME/.fehbg" 2>/dev/null | grep -q '^#!' \
        && pass "the ~/.fehbg hook starts with a shebang" \
        || fail "the ~/.fehbg hook has no shebang -- i3 cannot exec it"

    grep -q 'dots/terminal/wallpaper.png' "$USER_HOME/.fehbg" 2>/dev/null \
        && pass "the ~/.fehbg hook points at the dots wallpaper" \
        || { fail "the ~/.fehbg hook does not reference the dots wallpaper"
             sed 's/^/      /' "$USER_HOME/.fehbg" 2>/dev/null; }

    # A background already on the box is never overruled -- correct, since a
    # re-run must not discard one you picked. The cost is that a box deployed
    # while the dots phase was broken keeps whatever it had and a re-deploy will
    # not repair it, so this is asserted to keep the behaviour deliberate.
    printf '#!/bin/sh\nfeh --bg-fill /usr/share/images/desktop-base/kali.png\n' \
        > "$USER_HOME/.fehbg"
    chmod 755 "$USER_HOME/.fehbg"
    chown "$TEST_USER:$TEST_USER" "$USER_HOME/.fehbg"
    rm -rf "$USER_HOME/dots"
    as_sudo --only dots >/tmp/wall2.log 2>&1
    grep -q 'kali.png' "$USER_HOME/.fehbg" \
        && pass "an existing ~/.fehbg is left alone" \
        || fail "clobbered a background that was already set"

    # Put the container back as it was found. feh is not in the remote script's
    # package list and its dots phase runs later in this same suite.
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq feh >/dev/null 2>&1
    rm -rf "$USER_HOME/dots" "$USER_HOME/.fehbg"
}

# T12 -- the derived picom config. Kali ships options picom 13 deprecated, and
# picom raises a GUI dialog for them on every session start. The i3 phase copies
# Kali's config and strips them.
#
# No picom needed: the phase is a text transform, so a synthetic source exercises
# it exactly. The assertions that matter are the two failure directions -- dead
# options must go, and the shadow-exclude rule must survive, because dropping
# that one puts a shadow behind every GTK client-side-decorated window.
t_picom_conf() {
    head_ "T12: picom config is derived, minus the deprecated options"

    mkdir -p /etc/xdg
    cat > /etc/xdg/picom.conf <<'PSRC'
backend = "glx";
glx-no-stencil = true;
  glx-no-rebind-pixmap = true;
shadow = true;
shadow-exclude = [
  "name = 'Notification'",
  "_GTK_FRAME_EXTENTS@:c"    # GTK+ 3 CSD windows
];
PSRC

    rm -rf "$USER_HOME/.config/picom" "$USER_HOME/.config/picom.conf"
    as_sudo --only i3 >/tmp/picom1.log 2>&1
    local dst="$USER_HOME/.config/picom/picom.conf"

    if [[ ! -f "$dst" ]]; then
        fail "no picom.conf written"
        tail -5 /tmp/picom1.log | sed 's/^/      /'
        return
    fi
    pass "picom.conf written to ~/.config/picom/"

    grep -qE '^[[:space:]]*(glx-no-stencil|glx-no-rebind-pixmap)[[:space:]]*=' "$dst" \
        && fail "a deprecated option survived the copy" \
        || pass "deprecated options stripped"

    grep -q '_GTK_FRAME_EXTENTS@"' "$dst" \
        && pass "the GTK shadow-exclude rule survived, without its type specifier" \
        || { fail "GTK shadow-exclude rule lost or still carries ':c'"
             grep -n 'GTK_FRAME' "$dst" | sed 's/^/      /'; }

    grep -q 'backend = "glx"' "$dst" \
        && pass "the rest of Kali's config came along" \
        || fail "unrelated settings were dropped"

    # Regenerating must not stack headers or otherwise drift.
    as_sudo --only i3 >/dev/null 2>&1
    [[ $(grep -c 'Generated by kali-deploy-physical' "$dst") -eq 1 ]] \
        && pass "a second run regenerates cleanly" \
        || fail "re-running duplicated the generated header"

    # ~/.config/picom.conf outranks ours in picom's search order, so writing
    # ours there would produce a file picom never reads. It must decline.
    printf 'backend = "xrender";\n' > "$USER_HOME/.config/picom.conf"
    rm -rf "$USER_HOME/.config/picom"
    as_sudo --only i3 >/tmp/picom2.log 2>&1
    [[ ! -f "$dst" ]] \
        && pass "declines to write a config that would be outranked" \
        || fail "wrote $dst even though ~/.config/picom.conf outranks it"
    rm -f "$USER_HOME/.config/picom.conf"

    # A picom.conf someone else wrote is theirs.
    mkdir -p "$USER_HOME/.config/picom"
    printf 'backend = "xrender";\n' > "$dst"
    as_sudo --only i3 >/dev/null 2>&1
    grep -q 'xrender' "$dst" \
        && pass "a picom.conf we did not write is left alone" \
        || fail "clobbered a picom config that was not ours"

    rm -rf "$USER_HOME/.config/picom" /etc/xdg/picom.conf
}

# T13 -- the lock screen and the greeter, which are meant to be one look.
#
# Neither can be seen without a display, so what is asserted here is the wiring:
# the two configs exist, agree on the same image and the same palette, and the
# locker cannot end up with no fallback on one of its two entry points.
t_lock_and_greeter() {
    head_ "T13: lock screen and greeter are configured as one"

    as_sudo --only i3 >/tmp/lock1.log 2>&1

    local wrapper=/usr/local/bin/owl-lock
    local rc="$USER_HOME/.config/betterlockscreen/betterlockscreenrc"
    local gconf=/etc/lightdm/lightdm-gtk-greeter.conf
    local gcss=/usr/share/themes/owlshells/gtk-3.0/gtk.css
    local i3conf="$USER_HOME/.config/i3/config"

    [[ -x "$wrapper" ]] \
        && pass "owl-lock wrapper is executable" \
        || fail "owl-lock missing or not executable"

    grep -q 'i3lock -c 282828' "$wrapper" 2>/dev/null \
        && pass "owl-lock falls back to plain i3lock" \
        || fail "owl-lock has no fallback -- a missing cache would leave the screen unlocked"

    # The asymmetry this wrapper exists to prevent: xss-lock takes a command,
    # not a shell expression, so a fallback written inline on the bindsym line
    # would protect the keybinding and silently not protect the idle timeout.
    # Both must route through the wrapper.
    local bind_ok=0 idle_ok=0
    grep -qE '^bindsym .*\$mod\+Escape .*owl-lock' "$i3conf" && bind_ok=1
    grep -qE '^exec .*xss-lock .*owl-lock' "$i3conf" && idle_ok=1
    if (( bind_ok && idle_ok )); then
        pass "both the keybinding and xss-lock route through owl-lock"
    else
        fail "lock paths diverge (bindsym=$bind_ok xss-lock=$idle_ok)"
        grep -nE 'owl-lock|xss-lock|Escape' "$i3conf" | sed 's/^/      /'
    fi

    # 4.4.0 still reads ~/.config/betterlockscreenrc but prints a migration
    # error on every single invocation, so the XDG path is the only correct one.
    [[ -f "$rc" ]] \
        && pass "betterlockscreenrc is at the non-deprecated XDG path" \
        || fail "no rc at $rc"
    [[ ! -f "$USER_HOME/.config/betterlockscreenrc" ]] \
        && pass "nothing written to the deprecated rc path" \
        || fail "wrote the deprecated ~/.config/betterlockscreenrc"

    grep -q 'no-unlock-indicator' "$rc" 2>/dev/null \
        && pass "the unlock ring is suppressed" \
        || fail "no --no-unlock-indicator -- the ring will be drawn"

    # lockargs must append: betterlockscreen sets lockargs=(-n) before sourcing
    # this file, and losing -n breaks xss-lock.
    grep -q 'lockargs+=(' "$rc" 2>/dev/null \
        && pass "lockargs appends rather than replacing (-n survives)" \
        || fail "lockargs assigned rather than appended -- would drop -n/nofork"

    [[ -f "$gconf" ]] \
        && pass "greeter config written" \
        || fail "no $gconf"

    grep -q '^hide-user-image=true' "$gconf" 2>/dev/null \
        && pass "the greeter's avatar circle is hidden" \
        || fail "avatar circle not hidden"

    [[ -f "$gcss" ]] \
        && pass "greeter GTK theme written (its only route to custom colour)" \
        || fail "no $gcss -- theme-name points at nothing"

    # Naming a theme replaces Adwaita rather than extending it. Without this
    # import every widget loses its base style and the login box renders as a
    # small pale rectangle, silently.
    grep -q '@import.*Adwaita' "$gcss" 2>/dev/null \
        && pass "the theme extends Adwaita instead of replacing it" \
        || fail "no Adwaita import -- widgets will render with no base style"

    # `position=50% 50%` is NOT the documented default: a string with no anchor
    # part parses to anchor=start, which pins the window's top-left to the
    # centre point instead of centring it. Omitting the key is the only way.
    grep -q '^position=' "$gconf" 2>/dev/null \
        && fail "position= is set -- without an explicit anchor this off-centres the window" \
        || pass "no position= key, so the centred default applies"

    # The whole point: one image, both surfaces, and a path the lightdm user can
    # actually read. Anything under $USER_HOME is silently never drawn.
    local img=/usr/share/backgrounds/owlshells/lock.png
    grep -q "^background=$img" "$gconf" 2>/dev/null \
        && pass "greeter points at the shared image" \
        || fail "greeter background is not the shared image"

    # The published image must be the owl composite, not the desktop wallpaper.
    # They are different pictures on purpose -- the GitS card stays on the
    # desktop, the bird goes on the screens you are locked behind -- and pointing
    # this back at wallpaper.png would read as a tidy-up rather than a mistake.
    grep -q 'owl-lock\.png' "$SCRIPT" \
        && pass "the dots phase publishes the owl composite" \
        || fail "publish source is not owl-lock.png"
    # Comments stripped first: the block deliberately names wallpaper.png to say
    # it is NOT the source, and grepping the prose flags the explanation as the
    # very thing it is explaining.
    sed -n '/Publish the lock.login image/,/^        return 0/p' "$SCRIPT" \
        | grep -vE '^[[:space:]]*#' | grep -q 'terminal/wallpaper\.png' \
        && fail "the lock image is being taken from the desktop wallpaper again" \
        || pass "the desktop wallpaper is not reused as the lock image"
    grep -qE "^background=$USER_HOME|^background=~" "$gconf" 2>/dev/null \
        && fail "greeter background is under \$HOME -- lightdm cannot read it" \
        || pass "greeter background is outside \$HOME"

    # Palette parity: the accents must be the prompt's, on both sides.
    local c miss=0
    for c in 83A0A4 B2A1C0 FF2D2D; do
        grep -qi "$c" "$rc" || { fail "lock screen is missing palette colour #$c"; miss=1; }
    done
    (( miss )) || pass "lock screen carries the prompt palette"

    miss=0
    for c in 83A0A4 B2A1C0 FF2D2D; do
        grep -qi "$c" "$gcss" || { fail "greeter theme is missing palette colour #$c"; miss=1; }
    done
    (( miss )) || pass "greeter carries the same palette"
}

# T8 -- bad input is rejected, and --help stays clean.
t_bad_input() {
    head_ "T8: bad input is rejected"
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

    # --help prints the header comment block. It used to do that by hardcoded
    # line range, so trimming the header spilled `set -uo pipefail` and the
    # readonly declarations into the help output.
    local help_out
    help_out=$("$SCRIPT" --help 2>&1)
    if grep -qE '^\s*(set -|readonly |[A-Z_]+=\(|\}|fi$)' <<<"$help_out"; then
        fail "--help is leaking shell code"
        grep -nE '^\s*(set -|readonly |[A-Z_]+=\(|\}|fi$)' <<<"$help_out" \
            | head -5 | sed 's/^/    /'
    else
        pass "--help contains no shell code"
    fi

    grep -q -- '--dry-run' <<<"$help_out" \
        && pass "--help documents the options" \
        || fail "--help is missing the options block"
}

# ==============================================================================
sect "Package-level checks (pristine image, both scripts)"
# These must run before any test prerequisite is installed -- see the comment on
# install_test_prereqs.
# ==============================================================================
for _s in "$PHYSICAL" "$REMOTE"; do
    echo -e "\n\033[1m--- $(basename "$_s") ---\033[0m"
    SCRIPT="$_s"
    t_packages_resolve
    t_deps_resolve
    t_verified_is_installed
done

install_test_prereqs

# ==============================================================================
sect "kali-deploy-physical"
# ==============================================================================
SCRIPT="$PHYSICAL"

t_dry_run_inert

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

t_idempotent_shell '>>> kali-deploy-physical >>>'
t_dots_phase '>>> kali-deploy-physical >>>'
t_wallpaper
t_picom_conf
t_lock_and_greeter

as_sudo --only i3 --only polybar --only kitty >/tmp/rerun.log 2>&1 \
    && pass "config phases re-run cleanly" \
    || fail "config phases failed on re-run"

# The i3 backup must survive a re-run. Copying unconditionally meant the second
# run overwrote config.backup with our own generated config.
head_ "T4b: the original config backup survives re-runs"
printf 'THIS IS THE ORIGINAL\n' > "$USER_HOME/.config/i3/config"
rm -f "$USER_HOME/.config/i3/config.backup"
as_sudo --only i3 >/dev/null 2>&1
as_sudo --only i3 >/dev/null 2>&1
if grep -qF 'THIS IS THE ORIGINAL' "$USER_HOME/.config/i3/config.backup" 2>/dev/null; then
    pass "config.backup still holds the pre-script original after 2 runs"
else
    fail "config.backup was overwritten by a generated config"
fi

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

# disable_unit used to warn on failure and then claim success anyway.
if grep -qE '^\S*\[\+\]\S* disabled ' /tmp/harden.log; then
    fail "harden claimed it disabled a unit on a container with no systemd"
else
    pass "harden does not claim to have disabled units it could not touch"
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
    fail "run aborted on a bogus package"
    tail -15 /tmp/inject.log | sed 's/^/    /'
fi

t_bad_input

# ==============================================================================
sect "kali-deploy-remote"
# ==============================================================================
SCRIPT="$REMOTE"

# Start this suite from a clean home so the physical script's zshrc block and
# configs can't mask a remote-side bug.
rm -rf "${USER_HOME:?}"/.zshrc "$USER_HOME"/.zshrc.backup "$USER_HOME"/.tmux.conf \
       "$USER_HOME"/.tmux.conf.backup
touch "$USER_HOME/.zshrc" && chown "$TEST_USER:$TEST_USER" "$USER_HOME/.zshrc"

t_dry_run_inert

# ------------------------------------------------------------------------------
head_ "R4: config phases run for real and exit 0"
# ------------------------------------------------------------------------------
if as_sudo --only tmux --only shell --only wordlists >/tmp/rconfig.log 2>&1; then
    pass "config phases exit 0"
else
    fail "config phases exited non-zero (see /tmp/rconfig.log)"
    tail -20 /tmp/rconfig.log | sed 's/^/    /'
fi

for f in .tmux.conf .zshrc; do
    if [[ -f "$USER_HOME/$f" ]]; then
        owner=$(stat -c '%U' "$USER_HOME/$f")
        [[ "$owner" == "$TEST_USER" ]] \
            && pass "$f written, owned by $TEST_USER" \
            || fail "$f owned by $owner, expected $TEST_USER"
    else
        fail "$f was not created"
    fi
done

# The shell phase must not resurrect Oh My Zsh, and must not leave the
# interpolated-into-Python encoders behind.
grep -q "oh-my-zsh\|ZSH_THEME" "$USER_HOME/.zshrc" \
    && fail "zshrc references Oh My Zsh / ZSH_THEME" \
    || pass "no Oh My Zsh in the generated zshrc"

if grep -q 'sys.argv\[1\]' "$USER_HOME/.zshrc"; then
    pass "urlencode/urldecode pass arguments as argv"
else
    fail "urlencode/urldecode still interpolate into the Python source"
fi

# The auto-attach hook needs an escape hatch for the day tmux is what's broken.
grep -q 'NO_AUTO_TMUX' "$USER_HOME/.zshrc" \
    && pass "tmux auto-attach honours NO_AUTO_TMUX" \
    || fail "tmux auto-attach has no escape hatch"

# tmux must accept the generated config. -f with a no-op command parses the file
# without needing a server or a terminal.
if command -v tmux &>/dev/null; then
    if tmux -f "$USER_HOME/.tmux.conf" start-server \; kill-server >/tmp/tmuxcheck.log 2>&1; then
        pass "tmux validates the generated config"
    else
        fail "tmux rejected the generated config"
        head -10 /tmp/tmuxcheck.log | sed 's/^/    /'
    fi
else
    echo "    (tmux not installed in container -- skipping config validation)"
fi

t_idempotent_shell '>>> kali-deploy-remote >>>'
t_dots_phase '>>> kali-deploy-remote >>>'

# ------------------------------------------------------------------------------
head_ "R5: backups survive a re-run"
# ------------------------------------------------------------------------------
printf 'THIS IS THE ORIGINAL\n' > "$USER_HOME/.tmux.conf"
rm -f "$USER_HOME/.tmux.conf.backup"
as_sudo --only tmux >/dev/null 2>&1
as_sudo --only tmux >/dev/null 2>&1
if grep -qF 'THIS IS THE ORIGINAL' "$USER_HOME/.tmux.conf.backup" 2>/dev/null; then
    pass ".tmux.conf.backup still holds the pre-script original after 2 runs"
else
    fail ".tmux.conf.backup was overwritten by a generated config"
fi

# ------------------------------------------------------------------------------
head_ "R6: lockout guards and graceful degradation"
# The ssh and firewall phases are the ones that can strand a remote box. With no
# systemd, no key and no tailnet they must degrade rather than abort -- and must
# NOT disable password auth or enable the firewall.
# ------------------------------------------------------------------------------
rm -f "$USER_HOME/.ssh/authorized_keys"
if as_sudo --only ssh >/tmp/rssh.log 2>&1; then
    pass "ssh phase exits 0 without systemd"
else
    fail "ssh phase exited non-zero without systemd"
    tail -15 /tmp/rssh.log | sed 's/^/    /'
fi

dropin=/etc/ssh/sshd_config.d/99-hardening.conf
if [[ -f "$dropin" ]]; then
    if grep -q '^PasswordAuthentication no' "$dropin"; then
        fail "password auth disabled with no key and no tailnet (lockout risk)"
    else
        pass "password auth left ON when there is no other way in"
    fi
else
    fail "ssh phase wrote no drop-in"
fi

# With a key present, it must harden.
mkdir -p "$USER_HOME/.ssh"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test@example" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$TEST_USER:$TEST_USER" "$USER_HOME/.ssh"
as_sudo --only ssh >/tmp/rssh2.log 2>&1
if grep -q '^PasswordAuthentication no' "$dropin" 2>/dev/null; then
    pass "password auth disabled once an authorized key exists"
else
    fail "password auth still on despite an installed key"
fi

# SSH_PUBKEY must not be appended twice.
SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIdup dup@example" as_sudo --only ssh >/dev/null 2>&1
SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIdup dup@example" as_sudo --only ssh >/dev/null 2>&1
n=$(grep -cF 'dup@example' "$USER_HOME/.ssh/authorized_keys")
(( n == 1 )) && pass "SSH_PUBKEY installed exactly once across runs" \
             || fail "SSH_PUBKEY appears $n times (expected 1)"

if as_sudo --only firewall >/tmp/rufw.log 2>&1; then
    pass "firewall phase exits 0 with no tailnet"
else
    fail "firewall phase exited non-zero"
    tail -15 /tmp/rufw.log | sed 's/^/    /'
fi
grep -q 'left DISABLED to avoid lockout' /tmp/rufw.log \
    && pass "ufw left disabled while Tailscale is down" \
    || fail "ufw was not held back despite no tailnet"

# ------------------------------------------------------------------------------
head_ "R7: legacy SKIP_* environment knobs still map onto phases"
# ------------------------------------------------------------------------------
if SKIP_TAILSCALE=1 SKIP_UFW=1 as_sudo --dry-run >/tmp/rskip.log 2>&1; then
    grep -q 'Skipping:.*tailscale' /tmp/rskip.log \
        && pass "SKIP_TAILSCALE=1 maps to --skip tailscale" \
        || fail "SKIP_TAILSCALE=1 was ignored"
    grep -q 'Skipping:.*firewall' /tmp/rskip.log \
        && pass "SKIP_UFW=1 maps to --skip firewall" \
        || fail "SKIP_UFW=1 was ignored"
else
    fail "run with SKIP_* knobs exited non-zero"
    tail -10 /tmp/rskip.log | sed 's/^/    /'
fi

# ------------------------------------------------------------------------------
head_ "R8: the WSL profile fires on WSL, and only on WSL"
# ------------------------------------------------------------------------------
# This container is not WSL -- but it may well be running ON a WSL2 host, and a
# container shares its host's kernel, so /proc/sys/kernel/osrelease reads
# "microsoft" in here whenever a developer runs the suite from WSL. The baseline
# below is the regression test for that. Detection has to key on WSL's userspace
# (/run/WSL, /mnt/wsl, /init), never on the kernel name alone, or the access
# layer silently stops being tested on exactly one machine: the maintainer's.

as_sudo --dry-run >/tmp/rwsl-base.log 2>&1
grep -q 'Target:.*WSL' /tmp/rwsl-base.log \
    && fail "container mistaken for WSL (kernel string leaked into detection?)" \
    || pass "a container on a WSL host is not mistaken for WSL"
grep -q '=== Phase: tailscale ===' /tmp/rwsl-base.log \
    && pass "access layer still runs when not on WSL" \
    || fail "tailscale phase skipped on a box that is not WSL"
grep -q 'ffuf' /tmp/rwsl-base.log \
    && fail "WSL_PKGS installed on a box that is not WSL" \
    || pass "WSL_PKGS held back when not on WSL"

# /run/WSL is a plain directory created by the WSL2 init, so the positive path
# is testable without a WSL kernel.
mkdir -p /run/WSL
as_sudo --dry-run >/tmp/rwsl-on.log 2>&1
grep -q 'Target:.*WSL' /tmp/rwsl-on.log \
    && pass "WSL detected via /run/WSL" \
    || fail "WSL not detected despite /run/WSL"

wsl_ran=""
for p in tailscale ssh firewall; do
    grep -q "=== Phase: $p ===" /tmp/rwsl-on.log && wsl_ran="$wsl_ran $p"
done
[[ -z "$wsl_ran" ]] \
    && pass "access layer skipped on WSL (tailscale/ssh/firewall)" \
    || fail "ran on WSL and should not have:$wsl_ran"

wsl_missing=""
for p in base tools tmux shell dots wordlists; do
    grep -q "=== Phase: $p ===" /tmp/rwsl-on.log || wsl_missing="$wsl_missing $p"
done
[[ -z "$wsl_missing" ]] \
    && pass "every other phase still runs on WSL" \
    || fail "WSL profile also dropped:$wsl_missing"

grep -q 'ffuf' /tmp/rwsl-on.log \
    && pass "WSL_PKGS added to the install set on WSL" \
    || fail "WSL_PKGS missing from the install set on WSL"

# --only is the documented escape hatch: should_run consults ONLY_PHASES before
# it ever looks at the skip list, so a WSL default skip must not survive it.
as_sudo --only ssh --dry-run >/tmp/rwsl-only.log 2>&1
grep -q '=== Phase: ssh ===' /tmp/rwsl-only.log \
    && pass "--only ssh overrides the WSL skip" \
    || fail "--only ssh did not run the ssh phase on WSL"

# An explicit --skip of a phase WSL already skips must not list it twice.
n=$(as_sudo --skip ssh --dry-run 2>&1 | grep -c 'Skipping:.*ssh.*ssh')
(( n == 0 )) \
    && pass "explicit --skip of a WSL-skipped phase is not doubled" \
    || fail "phase listed twice in the pre-flight summary"

rmdir /run/WSL

t_bad_input

# ==============================================================================
echo ""
echo "=============================================="
echo "  passed: $PASSED   failed: $FAILED"
echo "=============================================="
exit $(( FAILED > 0 ? 1 : 0 ))
