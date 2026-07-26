# Tooling deployment scripts

[![CI](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/ci.yml/badge.svg)](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/ci.yml)
[![Kali container suite](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/container.yml/badge.svg)](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/container.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Automated deploy scripts for security workstations — Kali on hardware you sit at,
Kali on a headless box you reach remotely, and a Tails live session stocked with
pentest tooling over Tor. The two Kali scripts are validated against a real Kali
container before they touch a machine.

> For authorized engagements, CTFs, and lab work only.

## Which script

| Script | Target | Desktop | Access |
|---|---|---|---|
| **`kali-deploy-physical`** | Physical laptop you sit at | i3 + polybar + kitty | local only; hardened for a hostile LAN |
| **`kali-deploy-remote`** | Headless box / cloud teamserver | none | Tailscale SSH + hardened OpenSSH + ufw |
| **`test-with-tails`** *(beta)* | Tails OS live session | Tails' own GNOME | everything over Tor; nothing persists |

Superseded Ubuntu scripts live in [`archive/`](archive/). `SPEC.md` covers the
design reasoning behind the two Kali scripts.

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

## test-with-tails (Tails OS) — beta

Stocks a Tails live session with the tools it doesn't ship: Nmap (and Ncat),
Impacket, Sliver, NetExec, Burp Suite Community, proxychains, neovim,
build-essential, and an Apache server. The awkward part is that every fetch has to
go through Tor, as the `amnesia` user — dealing with those quirks, and the
permissions problems that come with them, is the reason the script exists.

```bash
sudo ./test-with-tails
```

**Before you run it**

1. Set an **administration password** at the Tails greeter when you log in. Without
   one there is no root, and this must be run from a **root terminal**.
2. If `git clone` fails over Tor, `wget` the raw file instead and `chmod +x` it.

**After it finishes**

- Burp Suite is downloaded but not installed — run the GUI installer yourself:
  `./burpsuite.sh`. It's the current Community build, ~380 MB, which makes it the
  slow part of the run over Tor.
- Tails is amnesic. Unless you are running from Persistent Storage, all of this is
  gone at the next boot and the script has to run again, over Tor.

**Operating notes**

- All traffic goes through Tor, and Tor carries **neither ICMP nor UDP**. Nmap has
  to run with `-Pn`, wrapped in `proxychains` or `torify`.
- Standing up the Apache server opens a listener on your Tails session — it pokes a
  hole in your persec. It is started but not enabled (nothing survives the session
  anyway); `sudo systemctl stop apache2` if you don't need it.

NetExec installs as **`nxc`** in `/usr/local/bin` — that's the command name, not
`netexec`. Its Linux build comes from a GitHub release asset, and because the newest
release doesn't always carry one (v1.5.1 ships no assets, so `/releases/latest/`
404s) and the asset name has changed shape across versions, the script asks the API
for the newest release that actually has a Linux build rather than hardcoding a URL.
If it can't find one it says so and points you at the releases page.

**Still a beta.** It was imported as written rather than rewritten, so it has no
phase engine, no `--dry-run`, no verification pass, and no idempotency guarantee —
none of what makes the Kali scripts safe to re-run or testable in a container. A
failed step is silent; read the output. Treat it as a convenience for a throwaway
live session, not as a deploy you'd trust unattended.

---

## Testing

Deploy scripts are hard to test because the failure mode is a half-configured machine.
`tests/` validates **both Kali scripts** against a real Kali container before either
touches hardware:

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

`test-with-tails` gets the static checks (`bash -n`, shellcheck) and nothing more.
Tails publishes no container image, and the script's install path depends on Tor and
on the live session's `amnesia` user — neither of which a container reproduces, so a
container pass would prove nothing about the run that matters.

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
