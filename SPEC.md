# Design notes

Why these scripts are built the way they are. The README covers usage; this
covers the reasoning, so that a change doesn't quietly undo a decision that was
made for a reason.

Applies to `kali-deploy-physical` and `kali-deploy-remote`. The Ubuntu
scripts in `archive/` predate most of it.

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

### Never lock the operator out

`kali-deploy-remote` will not disable SSH password authentication or enable
the firewall unless it can prove another way in exists — an installed key, or
Tailscale already up. A box that cannot reach itself is worse than one with
password auth enabled.

`kali-deploy-physical` inverts this: you have the keyboard, so default-deny
inbound is enabled unconditionally.

### Distro-native, no third-party repositories

Everything comes from the distribution's own archive. No `/opt` virtualenv, no
pipx-from-git, no `setcap` on a venv symlink, no external apt repositories.
Mixing third-party repos into a rolling release is a known way to break it, and
every tool these scripts need is already packaged.

### Don't branch on distribution version

`/etc/os-release` has no `VERSION_ID` on `kali-rolling`, so version-aware logic
crashes under `set -u`. Probe for the capability instead of inferring it from a
version number.

### Leave the platform's own configuration alone

Kali ships a tuned zsh. The script appends a marker-guarded block rather than
installing a framework over the top — faster shell startup, cleanly removable,
and no `sed` against a template that may not be there. v4 shipped exactly that
bug: its theme and plugin edits silently no-opped whenever the expected template
was absent.

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
`get_user_home`, `apt_available` / `apt_install` / `apt_install_first`, and
`check` for verification.

`kali-deploy-physical` adds `run()` and `write_file()` so `--dry-run` is
honoured in one place rather than at every call site.

## Testing

A deploy script's failure mode is a broken machine, which makes testing on the
target useless — by the time you learn, you have already paid the cost. So
everything testable is tested in a throwaway Kali container first, via
`tests/`.

The suite deliberately covers the *failure* paths, not just the happy one:
injected unavailable packages, a missing systemd, bad arguments, repeated runs.
It reads its package list from `--print-packages` so it cannot drift from the
script.

Its value is not theoretical. It caught, before any hardware was touched, that
`kali-desktop-i3` depends on `betterlockscreen`, which depends on
`i3lock-color`, which both *Conflicts* and *Provides* `i3lock` — so naming
`i3lock` explicitly made the entire package set unresolvable.

## Non-goals

- Configuring the user's dotfiles. That is a separate concern with its own repo.
- Supporting every distribution. Kali for the current scripts, and the `archive/`
  ones were Ubuntu.
- Unattended interactive prompts. `DEBIAN_FRONTEND=noninteractive` plus explicit
  debconf pre-seeding, because a package that asks a question hangs the run.
- Reproducing a specific tool version set. These track the distribution.
