# Tooling deployment scripts

[![CI](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/ci.yml/badge.svg)](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/ci.yml)
[![Kali container suite](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/container.yml/badge.svg)](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/container.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Automated deploy scripts for Kali security workstations — one for hardware you sit
at, one for a headless box you reach remotely. Both are validated against a real
Kali container before they touch a machine.

> For authorized engagements, CTFs, and lab work only.

## Which script

| Script | Target | Desktop | Access |
|---|---|---|---|
| **`kali-deploy-physical`** | Physical laptop you sit at | i3 + polybar + kitty | local only; hardened for a hostile LAN |
| **`kali-deploy-remote`** | Headless box / cloud teamserver | none | Tailscale SSH + hardened OpenSSH + ufw |

Superseded Ubuntu scripts live in [`archive/`](archive/). `SPEC.md` covers the
design reasoning behind the current pair.

---

## kali-deploy-physical

A Kali-first deploy for a laptop you carry: the full tool set, the i3 desktop, and
hardening aimed at a conference network.

```bash
sudo ./kali-deploy-physical
```

Options:

```
--dry-run          show what would happen; change nothing
--skip <phase>     skip a phase (repeatable)
--only <phase>     run only these phases (repeatable)
--list-phases      print phase names
--print-packages   print every package the script can install
--print-checked-binaries
                   print every binary the verification pass ticks
-h, --help
```

Phases: `base tools desktop harden i3 polybar kitty shell wordlists`

Re-running is always safe — every phase is idempotent, so a run that dies partway
can be resumed by running it again (or narrowed with `--only`). A full transcript
goes to `/var/log/kali-deploy-physical-<timestamp>.log`.

### What it installs

Tools come from Kali's own `kali-tools-*` metapackages rather than a hand-listed set
of package names — they're curated, dependency-resolved, and stable across rolling.
Edit `TOOL_METAS` at the top of the script to change scope.

Included: information-gathering, vulnerability, web, database, passwords,
exploitation, post-exploitation, sniffing-spoofing, windows-resources,
reverse-engineering, 802-11, wireless, bluetooth, rfid.

Not included: `kali-tools-sdr` (gnuradio is a very large dependency tree). Add it to
`TOOL_METAS` if you want it.

`EXTRA_PKGS` names the things the metapackages don't cover — including the AD and web
tooling (`netexec`, `mitm6`, `certipy-ad`, `enum4linux-ng`, `bloodhound.py`, `ffuf`,
`gobuster`), which is *not* in the `kali-tools-*` closure. Don't assume the ISO will
supply them; see the Testing section.

The desktop is `kali-desktop-i3`, which is a complete desktop — i3, lightdm, polybar,
kitty, picom, feh, network-manager, betterlockscreen — with the i3 session registered
with the display manager. On top of that the script writes the i3, polybar, and kitty
configs carried over from `archive/ubuntu-autodeploy-v5`.

Kali stages its *own* i3/polybar/kitty configs under `/usr/share/i3-dotfiles/` and
never copies them into `$HOME`, so they don't collide with these. Worth a look if you
want to borrow from them.

### Hardening

Aimed at a laptop that is physically with you on an untrusted LAN, not a remote host:

- `ufw` default-deny inbound, enabled
- no SSH server (disabled and masked if present)
- `avahi-daemon` and `cups`/`cups-browsed` off — no mDNS or printer advertisement
- `bluetooth.service` off (the BT *tools* are still installed)
- NetworkManager MAC randomization, scan-time and per-connection
- screen locks after 5 minutes idle via `xss-lock`

The verification pass ends with an `ss -tulpn` listing of everything actually
listening. Read that rather than trusting the toggles.

**Inbound is default-deny**, so Responder, mitm6, or a `python3 -m http.server` will
not be reachable from the LAN until you open the port:

```bash
sudo ufw allow 8000/tcp     # or the fw-open alias
```

### After it finishes

Some things can only be checked on the hardware, and the script prints them at the
end rather than claiming they passed:

1. **Pick the i3 session at the LightDM greeter.** Kali defaults to Xfce; i3 is not
   automatic.
2. Confirm polybar renders and the battery module finds `BAT0`.
3. Mod is **Alt**. `Mod+Return` kitty, `Mod+d` dmenu, `Mod+Escape` lock.
4. If a captive portal or MAC-allowlisted network rejects you, MAC randomization is
   why — `sudo rm /etc/NetworkManager/conf.d/00-macrandomize.conf`.
5. Verify monitor mode before relying on it: `sudo airmon-ng start wlan0`.

### Shell

Kali's own zsh config is left intact; the script appends a marker-guarded block with
PATH, wordlist variables, and aliases. Oh My Zsh is deliberately *not* installed —
Kali already ships syntax highlighting and autosuggestions, and OMZ only adds startup
cost. To remove, delete the block between the `kali-deploy-physical` markers in
`~/.zshrc`.

---

## kali-deploy-remote (headless)

For a box you reach over Tailscale rather than sit at. Installs the Kali tool set with
no GUI, joins a tailnet with Tailscale SSH as the primary auth path, hardens OpenSSH as
a fallback, and restricts inbound to the `tailscale0` interface.

```bash
sudo ./kali-deploy-remote
```

It takes the same flags as the physical script — `--dry-run`, `--skip`, `--only`,
`--list-phases`, `--print-packages`, `--help`.

Phases: `base tools tailscale ssh firewall tmux shell wordlists`

Environment knobs: `TS_AUTHKEY`, `TS_ADVERTISE_TAGS`, `SSH_PUBKEY`, `SKIP_TAILSCALE=1`,
`SKIP_UFW=1`. The last two are equivalent to `--skip tailscale` / `--skip firewall` and
are kept so older invocations don't break.

It will not disable password auth or enable the firewall unless it can prove you have
another way in (an installed key, or Tailscale already up) — a box that can't reach
itself is worse than one with password auth on.

Like the physical script it keeps Kali's own zsh and appends a marker-guarded block;
Oh My Zsh and the `agnoster` theme are deliberately *not* installed. Agnoster needs
powerline glyphs in the terminal you're connecting *from*, so over SSH from anything
unconfigured it renders as boxes.

Your shell auto-attaches to a `main` tmux session on interactive SSH login, so a
dropped connection never kills your work. For a plain shell — the day tmux itself is
what's broken — connect with `NO_AUTO_TMUX=1`.

A full transcript goes to `/var/log/kali-deploy-remote-<timestamp>.log`.

See `TMUX-TAILSCALE-CHEATSHEET.md`.

---

## Testing

Deploy scripts are hard to test because the failure mode is a half-configured machine.
`tests/` validates **both** scripts against a real Kali container before either touches
hardware:

```bash
tests/run-tests.sh                # static analysis + container suite
tests/run-tests.sh --static-only  # bash -n + shellcheck only
```

Covers, for each script: every package name resolving to an installation candidate,
full dependency resolution via `apt --simulate`, every binary the verification pass
ticks actually being delivered by that package set, `--dry-run` mutating nothing, the
config phases running for real with correct ownership, `i3 -C` / `tmux` validating the
generated configs, idempotency across repeated runs, backups surviving a re-run,
graceful degradation with no systemd, the SSH and firewall lockout guards, injected
bad-package handling, and argument validation.

The suite reads its package list from `--print-packages` and its expected-binary list
from `--print-checked-binaries`, so neither can drift out of sync with the script.

That second one exists because of a real bug: the physical script printed a green tick
for seven tools it never installed. Four of them (`netexec`, `bloodhound.py`, `ffuf`,
`gobuster`) happened to be in the ISO's `kali-linux-default`, so on a stock install they
looked fine — luck, not intent, and gone on a netinst. The other three (`mitm6`,
`certipy-ad`, `enum4linux-ng`) were missing on every path. A red X at the end of a
40-minute deploy, on the day you need the box, is how you would have found out.

Requires docker. It pulls `kalilinux/kali-rolling` and
`koalaman/shellcheck` and modifies nothing on the host.

CI runs the static checks on every push. The full container suite runs weekly on a
schedule, on pull requests, and on manual dispatch — Kali is a rolling release, so a
metapackage can be renamed or a new dependency conflict introduced without anything
in this repo changing, and the scheduled run is what catches that before a deploy
does.

---

## Archive

`archive/ubuntu-autodeploy-v5` is the last Ubuntu version and the source of the i3
desktop and the apt-resilience helpers the Kali scripts inherit. It fixed a series of
real v4 deploy failures — a package with no installation candidate aborting the whole
apt batch under `set -e`, `setcap` on a venv symlink, `gunzip` on a file that wasn't
gzip — which is why none of these scripts use `set -e`. See [`archive/`](archive/) for
the full story.

## License

MIT — see [LICENSE](LICENSE).
