# Design notes

Why these scripts are built the way they are. The README covers usage; this
covers the reasoning, so that a change doesn't quietly undo a decision that was
made for a reason.

Applies to `kali-deploy-physical`, `kali-deploy-remote`, `kali-deploy-vm` and
`kali-deploy-wsl`. The Ubuntu scripts in `archive/` predate most of it.

The four split on target, not on options: hardware you sit at, a headless box you
reach over Tailscale, a guest you reach over a remote-desktop agent, and a WSL2
instance you enter with `wsl.exe`. That is why `kali-deploy-physical` hardcodes
`picom --backend glx` and is left that way — it is correct on a real GPU, and a
VM's graphics stack is `kali-deploy-vm`'s problem to have. Teaching one script to
detect the other's platform is how both end up carrying accommodations neither
target needs.

### Why WSL became the fourth script

It was the third script's detected profile first, and the header there argued the
case: a WSL instance is a headless Kali, so the headless script should own it.

The test of "same target" is not whether the phases happen to fit, though. It is
whether the script's *defining* feature applies. `kali-deploy-remote` is its
access layer — Tailscale SSH, a hardened OpenSSH, ufw — and on WSL all three are
skipped by default. Running it there meant running it with the entire reason it
exists switched off, and a target that needs that is a different target. So the
access layer is absent from `kali-deploy-wsl` rather than skipped, and the rule
at the top of this file is what decided it, not an exception to it.

Two things follow, and they are the cost of the split:

- `is_wsl()` is duplicated verbatim, comment and all. It encodes a subtlety that
  is easy to get wrong in a way no CI run would catch (see below), and a second,
  looser copy would be the bug. Copied deliberately; keep them identical.
- `kali-deploy-remote` keeps its WSL detection. Removing it would break R8, which
  pins the detection in both directions, and an existing invocation on a WSL box
  still does the right thing. The README points WSL at the new script.

## The requirement everything else follows from

These scripts exist to bring up a machine quickly. A run that dies halfway
leaves a half-configured box, and the usual recovery is to reinstall the OS and
start over — which costs more time than the script ever saved.

So the goal is not "install the tools". It is **finish, first time, or degrade
into something still usable**. Every rule below is downstream of that.

## Rules

### No `set -e`

An installer should keep going when an optional piece fails. `set -u` and
`pipefail` stay on; `set -e` does not. Every fallible step ends in `|| warn`,
`|| true`, or sits inside an `if`.

This is not a style preference. Under `set -e`, v4 died at the first
`apt-get install` because one package in a 40-name list had no installation
candidate on that release — and installed nothing at all. Partial success beats
an abort.

### Prefer curated package sets over hand-maintained lists

`kali-deploy-physical` installs `kali-tools-*` metapackages rather than
naming individual tools. Kali curates them and resolves their dependencies, so
they survive rolling-release churn that a hand-listed set does not. A package
name that no longer resolves is the single most common way a deploy dies.

Where a name must be listed individually, probe it with `apt_available` first so
a rename is a warning, not a failure.

### Never assume a name resolves — including a metapackage

`apt_available` gates every install. `apt_install` falls back from a bulk
install to one-at-a-time so a single bad name cannot take the batch with it.

### Idempotent, resumable phases

Re-running must always be safe, so that a failure is recoverable by running the
script again rather than by reimaging. Config writes are overwrite-with-backup;
appends are marker-guarded; `--only` and `--skip` let a single failed phase be
retried in isolation.

A backup is taken **once**, the first time we are about to replace a file. Copying
on every run means the second run overwrites the backup with the config the first
run generated, so the original is recoverable exactly once — which is to say, not
when you actually need it.

### A file the operator maintains is added to, never rewritten

Overwrite-with-backup is right for a file the script owns — `~/.tmux.conf` has no
author but this repo. It is wrong for `/etc/wsl.conf`, which is how you set the
default user, systemd, and mount behaviour, and which is therefore usually
hand-edited before any deploy script runs.

So the `wslconf` phase creates the file when absent, appends a section that is
entirely absent, and never rewrites a section that is already there. Where a
section exists but lacks a key it wants, it prints the line to add rather than
editing around it. A `[boot]` that says something we would not have written is a
decision someone made, and silently reversing it is the kind of surprise that
costs more trust than the fix was worth.

The same reasoning is why `WSL_HOSTNAME` is opt-in and does nothing if
`[network]` already exists.

### Never lock the operator out

`kali-deploy-remote` will not disable SSH password authentication or enable
the firewall unless it can prove another way in exists — an installed key, or
Tailscale already up. A box that cannot reach itself is worse than one with
password auth enabled.

`kali-deploy-physical` inverts this: you have the keyboard, so default-deny
inbound is enabled unconditionally.

### Distro-native, with one declared exception

Everything comes from the distribution's own archive. No `/opt` virtualenv, no
pipx-from-git, no `setcap` on a venv symlink. Mixing third-party repos into a
rolling release is a known way to break it, and every *tool* these scripts need
is already packaged.

The exception is Tailscale, in `kali-deploy-remote`: it is not in Kali's archive
and it is the entire access layer, so the script adds Tailscale's signed apt repo
(pinned to the `bookworm` channel, which doesn't churn) and falls back to the
official installer only if that fails. It is called out here rather than left as
a surprise, and it is the only one.

### A verification tick must mean something

The end-of-run `check` list is the last thing you read before trusting the box,
so it must not be able to lie in either direction. Checking for a binary nothing
installs is worse than not checking at all: it trains you to skim past red.

The lists live in `VERIFY_BINS_*` arrays, are exposed by
`--print-checked-binaries`, and `tests/` T9 asserts every entry is delivered by
the closure of `--print-packages`. Note these are *binary* names, not package
names — `certipy-ad` ships `/usr/bin/certipy-ad`, while `/usr/bin/certipy`
belongs to `python3-certipy`, an unrelated library.

### Don't inherit what the ISO happens to provide

`kali-linux-default` ships with the Kali installer, so a tool it contains looks
present whether or not the script installs it. That is luck, and it evaporates on
a netinst or a minimal image. Anything the script depends on, the script names.

### Don't branch on distribution version

`/etc/os-release` has no `VERSION_ID` on `kali-rolling`, so version-aware logic
crashes under `set -u`. Probe for the capability instead of inferring it from a
version number.

### Leave the platform's own configuration alone

Kali ships a tuned zsh. Both scripts append a marker-guarded block rather than
installing a framework over the top — faster shell startup, cleanly removable,
and no `sed` against a template that may not be there. v4 shipped exactly that
bug: its theme and plugin edits silently no-opped whenever the expected template
was absent, and `kali-deploy-remote` carried the same `sed` until it was rewritten.

The `agnoster` theme went with it. It needs powerline glyphs in the terminal you
are connecting *from*, which on a headless box is not a thing the deploy script
can install.

### A credential the box does not have is a skip, not a failure

The `dots` phase pulls a repo that `DOTS_REPO` may point at a **private** fork
of. A freshly imaged machine has no SSH key and no `gh` token, so the common
case is that it cannot authenticate at all. It tries `DOTS_TOKEN`, then SSH,
then `gh`, then a plain anonymous clone, and when none work it warns, prints the
one command that finishes the job later, and lets the run continue. The
governing requirement applies here as everywhere: nothing optional gets to be
the reason an install is redone.

The anonymous fallback is load-bearing, not a courtesy. The default `DOTS_REPO`
is public, and while it was **not** tried, a stock box — the exact machine this
phase exists to serve — skipped the phase on every deploy and came up with
Kali's default shell, because "no credentials" was being read as "unreachable"
for a repo that needed none.

Two supporting rules fall out of it:

- **git must never block on a prompt.** `GIT_TERMINAL_PROMPT=0` and
  `BatchMode=yes` are set for every git call in the phase. Without them an
  unknown host key or a private HTTPS URL waits forever for input, on a box
  nobody is watching — the failure mode the whole spec exists to avoid.
- **A token never goes in a URL.** It is passed as a per-invocation
  `http.extraHeader`. A URL-embedded credential is persisted into `.git/config`
  by `clone` and repeated in git's error output, and this script's transcript is
  written to `/var/log`. The suite asserts a canary token never reaches the log.

### Never define what another layer already owns

When both the deploy script and a shell kit define `serve`, the loser is
whichever the shell resolves second — and in zsh an alias beats a function, so
`alias serve='python3 -m http.server'` would permanently shadow dots' richer
`serve()`. The overlapping definitions are therefore wrapped in a
"dots is not installed" guard rather than deleted outright, because the dots
phase is allowed to fail and the box must be fully equipped either way.

Where the two genuinely mean different things, they get different names:
`myip` is local interfaces, `extip` is what the internet sees.

### Say what could not be verified

Some things are only observable on real hardware — whether i3 actually starts,
whether polybar finds `BAT0`, whether an adapter supports monitor mode. The
script prints these as a checklist instead of reporting success it cannot
confirm.

## Structure

Both scripts follow the same shape:

```
header/usage -> arg parsing -> logging -> helpers -> pre-flight
  -> numbered phases -> verification
```

Shared helpers: `msg`/`warn`/`err` (warnings and errors to **stderr**, so they
are never captured by a `$(...)` substitution), `get_real_user` /
`get_user_home`, `apt_available` / `apt_install` / `apt_install_first`, `run()`
and `write_file()` so `--dry-run` is honoured in one place rather than at every
call site, `backup_once()`, and `check` for verification.

Both scripts take the same flags and both are phase-based. That symmetry is
deliberate: two scripts with different argument grammars is two things to
remember at 3am.

## Testing

A deploy script's failure mode is a broken machine, which makes testing on the
target useless — by the time you learn, you have already paid the cost. So
everything testable is tested in a throwaway Kali container first, via
`tests/`.

Both scripts are exercised. The suite deliberately covers the *failure* paths,
not just the happy one: injected unavailable packages, a missing systemd, bad
arguments, repeated runs, and the lockout guards. It reads its package list from
`--print-packages` and its binary list from `--print-checked-binaries` so neither
can drift from the script.

Its value is not theoretical. It has caught, before any hardware was touched:

- `kali-desktop-i3` depends on `betterlockscreen`, which depends on
  `i3lock-color`, which both *Conflicts* and *Provides* `i3lock` — so naming
  `i3lock` explicitly made the entire package set unresolvable.
- Seven tools the physical script ticked and never installed, three of them
  missing on every install path.
- `dnsutils`, which the remote script had installed for as long as it existed,
  has no candidate on current Kali — it is `bind9-dnsutils` now. The box came up
  without `dig` and said nothing about it.

The package-level checks run against a **pristine** image, before the suite
installs its own prerequisites. `apt-get install --simulate` only reports what it
would *newly* install, so a package the test harness pulled in first vanishes
from the closure and T9 reports it as missing. A test that cries wolf about the
one thing it uniquely catches is worse than no test.

## Non-goals

- Configuring the user's dotfiles. That is a separate concern with its own repo.
- Supporting every distribution. Kali for the current scripts, and the `archive/`
  ones were Ubuntu.
- Unattended interactive prompts. `DEBIAN_FRONTEND=noninteractive` plus explicit
  debconf pre-seeding, because a package that asks a question hangs the run.
- Reproducing a specific tool version set. These track the distribution.
