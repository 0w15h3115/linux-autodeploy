# Tooling deployment scripts

[![CI](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/ci.yml/badge.svg)](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/ci.yml)
[![Kali container suite](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/container.yml/badge.svg)](https://github.com/owlshells/tooling-deployment-scripts/actions/workflows/container.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Automated deploy scripts for security workstations — Kali on hardware you sit at,
Kali on a headless box you reach remotely, and a Tails live session stocked with
pentest tooling over Tor.

> For authorized engagements, CTFs, and lab work only.

## Which script

| Script | Target | Desktop | Access |
|---|---|---|---|
| **`kali-deploy-physical`** | Physical laptop you sit at | i3 + polybar + kitty | local only; hardened for a hostile LAN |
| **`kali-deploy-vm`** | Hyper-V guest you screen-share into | i3 + polybar + kitty, no compositor | ScreenConnect / ConnectWise Control agent |
| **`kali-deploy-remote`** | Headless box / cloud teamserver | none | Tailscale SSH + hardened OpenSSH + ufw |
| **`kali-deploy-remote`** *(on WSL)* | Kali under WSL2 — same script, detected | none | none; the access layer is skipped |
| **`test-with-tails`** *(beta)* | Tails OS live session | Tails' own GNOME | everything over Tor; nothing persists |

`kali-deploy-vm` is configuration only — it installs **no tools**, on the basis that
a stock Kali image already ships `kali-linux-default`. Use `kali-deploy-physical`
if you want the `kali-tools-*` metapackage set.

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

Phases: `base tools desktop harden i3 polybar kitty shell dots wordlists`

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

### The `dots` phase

Clones the [`owlshells/dots`](https://github.com/owlshells/dots) shell kit into
`~/dots` and runs its `install.sh`, which symlinks `~/.bash_aliases` and adds a
guarded hook to `~/.zshrc`. It then seeds the command-recall index from any logs
already on the box, so the shell is useful on the first login rather than the tenth.

`dots` is public, so a freshly imaged box with no credentials at all still gets it.
The authenticated transports are tried first anyway, because `DOTS_REPO` can point
at a private fork; the phase **skips rather than fails** if every one is unreachable
— a shell kit is never a reason to redo an install:

| Order | Transport | Needs |
|-------|-----------|-------|
| 1 | `DOTS_TOKEN` | `sudo DOTS_TOKEN=<pat> ./kali-deploy-... ` |
| 2 | SSH | a key already on the box, agent or on disk |
| 3 | `gh` | `gh auth login`, *if* gh is present — it ships from GitHub's own apt repo, not Kali's, so a stock box will not have it |
| 4 | anonymous HTTPS | nothing — the path a stock box actually takes |

A token is passed as a per-invocation `http.extraHeader`, never embedded in the
remote URL — a URL credential gets persisted into `.git/config` and echoed back in
git's error output, and this script's transcript goes to `/var/log`. `git` is also
pinned to `BatchMode`/`GIT_TERMINAL_PROMPT=0` so it can never sit waiting for input
on a box nobody is standing in front of.

Finish it later with `sudo DOTS_TOKEN=<token> ./kali-deploy-<physical|remote>
--only dots`. On a freshly imaged box `DOTS_TOKEN` or a restored SSH key are the
only transports that exist: `gh` is not in Kali's repos, and adding GitHub's apt
source would mean a second third-party repo when Tailscale is the one declared
exception.

Set `DOTS_REPO=owner/name` to point the phase at a different kit.

The zshrc block the `shell` phase writes defines `serve`, `ports`, `listening`,
`myip`, `WORDLISTS`/`SECLISTS` and the encoders **only when dots is absent**. dots
provides richer versions, and `alias serve` would otherwise permanently shadow its
`serve()` function, since zsh resolves aliases before functions. `extip` is kept
unguarded as its own name, because "what the internet sees" is a different question
from dots' local-interface `myip`.

On the remote script `install.sh` is invoked with `--no-tmux`: that box's
`~/.tmux.conf` is the headless SSH one written by the `tmux` phase, which suits it
better than the repo's — and leaving it a real file stops `write_file`'s `cat >`
from writing into the dots checkout through a symlink.

### After it finishes

Some things can only be checked on the hardware, and the script prints them at the
end rather than claiming they passed:

1. **Pick the i3 session at the LightDM greeter.** Kali defaults to Xfce; i3 is not
   automatic.
2. Confirm polybar renders and the battery module finds `BAT0`.
3. Mod is the **Windows/Super** key. `Mod+Return` kitty, `Mod+d` dmenu,
   `Mod+Escape` lock.
4. If a captive portal or MAC-allowlisted network rejects you, MAC randomization is
   why — `sudo rm /etc/NetworkManager/conf.d/00-macrandomize.conf`.
5. Verify monitor mode before relying on it: `sudo airmon-ng start wlan0`.

### Shell

Kali's own zsh config is left intact; the script appends a marker-guarded block with
PATH, wordlist variables, aliases, and `lfcd` — a wrapper around the `lf` file manager
that leaves you in whatever directory you quit from. Oh My Zsh is deliberately *not*
installed — Kali already ships syntax highlighting and autosuggestions, and OMZ only
adds startup cost. To remove, delete the block between the `kali-deploy-physical`
markers in `~/.zshrc`.

---

## kali-deploy-vm

For Kali as a Hyper-V guest that you reach with a remote-desktop agent instead of
sitting at it. Configuration only — no tools, no firewall, no dotfiles.

```bash
sudo ./kali-deploy-vm
sudo SC_URL='https://<you>.screenconnect.com/Bin/ConnectWiseControl.ClientSetup.deb?e=Access&y=Guest&t=' \
     ./kali-deploy-vm --only screenconnect
```

Phases: `base hyperv desktop i3 polybar kitty shell screenconnect`

Options are the same grammar as the other two, plus `--autologin` and
`--compositor <xrender|glx|egl>`.

### Why this isn't kali-deploy-physical with the laptop bits removed

Three differences are load-bearing, and the first one is the reason the script
exists at all:

**No compositor.** A Hyper-V guest has no hardware GLX — Mesa falls back to
llvmpipe. `picom --backend glx` fails *after* it has already mapped the composite
overlay window, and that overlay is full-screen, opaque, and never made
input-transparent. The result is a black screen that swallows every keystroke,
with i3 running perfectly underneath: your terminal really did open, you just
can't see or reach it. `kali-deploy-physical` hardcodes `--backend glx` (its
header flags this as an untested assumption), which is exactly why it breaks on
Hyper-V. This script starts no compositor; `--compositor xrender` opts back in
with the backend that has no GL dependency.

**No idle lock, no DPMS blanking.** On a remote box a blanked screen is
indistinguishable from a hung one, and an idle lock you didn't ask for means
typing a password down a laggy link to get back into a session you never left.
`$mod+Escape` still locks manually.

**Nothing that assumes hardware.** The battery module, the wireless module and
the backlight keys are emitted only if `/sys` says the hardware is there — so the
bar has no permanently-blank `BAT0` and no permanent "wlan down". These are
probed, not assumed, so the script is still correct on bare metal.

Two smaller ones that matter in practice: `sync_to_monitor no` in `kitty.conf`
(vsync against a display that isn't real is what makes kitty paint late or appear
to hang on software rendering), and `$mod+Shift+Return` bound to **xterm** as a
fallback, because kitty wants OpenGL 3.3 and a tiling WM whose only terminal
binding is broken is a box you can't use.

### The screenconnect phase

The agent is the second declared exception to "everything comes from the
distribution's archive", for the same reason Tailscale is in `kali-deploy-remote`:
it isn't packaged anywhere else and it *is* the access layer. Unlike Tailscale
there's no apt repo — the `.deb` is generated per-instance and carries the
instance fingerprint, so you have to supply the URL:

| Variable | Meaning |
|---|---|
| `SC_URL` | ClientSetup URL from **Access → Build Installer → Linux** |
| `SC_DEB` | path to an already-downloaded `.deb`; takes precedence |

With neither set the phase **skips and prints what to do** — it is never a reason
for the run to fail, and the desktop is already up by the time it runs.

The phase installs the X libraries the agent links against before the `.deb`,
because a missing one produces an agent that installs cleanly, starts cleanly, and
shows you a black rectangle. `libicu` is resolved dynamically since its version
suffix moves with every Debian import.

### Autologin

Off by default. With a greeter, a box that reboots comes back to a locked login
screen the agent can still show you — you lose a password prompt. With
`--autologin` it comes back to an unlocked desktop holding your keys, your loot and
your shell history, reachable by anyone who reaches the agent. It's offered because
some agent configurations only attach to an active user session, but it isn't a
choice to make on someone's behalf.

### Resolution

Host-side on a Gen 2 VM — the guest's `hyperv_drm` takes its mode from the host and
`xrandr` can't add modes it was never offered. From an elevated PowerShell prompt,
VM powered off:

```powershell
Set-VMVideo -VMName <name> -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single
```

### If you land in a black screen anyway

`Ctrl+Alt+F3` for a TTY, log in, `unstick` (aliased by the `shell` phase — it's
`pkill picom; i3-msg restart`), then `Ctrl+Alt+F7`. That path works regardless of
what's on the display, so you're never actually locked out.

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

Phases: `base tools tailscale ssh firewall tmux shell dots wordlists`

Environment knobs: `TS_AUTHKEY`, `TS_ADVERTISE_TAGS`, `SSH_PUBKEY`, `SKIP_TAILSCALE=1`,
`SKIP_UFW=1`. The last two are equivalent to `--skip tailscale` / `--skip firewall` and
are kept so older invocations don't break.

It will not disable password auth or enable the firewall unless it can prove you have
another way in (an installed key, or Tailscale already up) — a box that can't reach
itself is worse than one with password auth on.

Like the physical script it keeps Kali's own zsh and appends a marker-guarded block —
including `lfcd`, the `lf` file-manager wrapper that leaves you in whatever directory
you quit from. Oh My Zsh and the `agnoster` theme are deliberately *not* installed.
Agnoster needs powerline glyphs in the terminal you're connecting *from*, so over SSH
from anything unconfigured it renders as boxes.

Your shell auto-attaches to a `main` tmux session on interactive SSH login, so a
dropped connection never kills your work. For a plain shell — the day tmux itself is
what's broken — connect with `NO_AUTO_TMUX=1`.

A full transcript goes to `/var/log/kali-deploy-remote-<timestamp>.log`.

See `TMUX-TAILSCALE-CHEATSHEET.md`.

### Kali on WSL

Run the same script — it detects WSL and adjusts itself:

```bash
sudo ./kali-deploy-remote
```

A WSL instance is a headless Kali, which is why this lives here rather than in the
physical script: there is no display, and the terminal drawing it is a Windows
application, so the font probe the physical script does would answer a question about
the wrong machine. Only the access layer differs, and it is skipped by default —
`tailscale` (run Tailscale on the Windows host instead), `ssh` (with `systemd = true`
in `wsl.conf`, enabling sshd actually takes effect, on a box you enter with
`wsl.exe`), and `firewall` (WSL2 is NAT'd behind the host; rules naming `tailscale0`
stage an interface that will never exist). Force one back on with `--only <phase>`.

The tools phase adds `WSL_PKGS` — `ffuf`, `gobuster`, `sqlmap` — on top of the
headless set, since a WSL box is a workstation and web tooling is the gap you notice
first.

Detection keys on WSL's userspace (`/run/WSL`, `/mnt/wsl`, `/init`), never on the
kernel name: a container shares its host's kernel, so `/proc/sys/kernel/osrelease`
says `microsoft` inside every container on a WSL2 host — including the one this
repo's tests run in. R8 pins both directions.

For glyphs in the prompt, install the patched font on the *Windows* side and point
Windows Terminal at it; `VINNY_ASCII=1` is the fallback.

---

## test-with-tails (Tails OS) — beta

Stocks a Tails live session with the tools it doesn't ship: Nmap (and Ncat),
Impacket, NetExec, Sliver, Burp Suite Community, proxychains, neovim,
build-essential, an Apache server, and a staged copy of Mythic. The awkward part is that every fetch has
to go through Tor, as the `amnesia` user — dealing with those quirks, and the
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
  `~/burpsuite.sh`. It's the current Community build, ~380 MB, which makes it the
  slow part of the run over Tor.
- Mythic is cloned to `~/Mythic` but not built or started. See below.
- Tails is amnesic. Unless you are running from Persistent Storage, all of this is
  gone at the next boot and the script has to run again, over Tor.

**Operating notes**

- All traffic goes through Tor, and Tor carries **neither ICMP nor UDP**. Nmap has
  to run with `-Pn`, wrapped in `proxychains` or `torify`.
- Standing up the Apache server opens a listener on your Tails session — it pokes a
  hole in your persec. It is started but not enabled (nothing survives the session
  anyway); `sudo systemctl stop apache2` if you don't need it.

**Two C2s, and only one of them actually runs here.**

`sliver-server` installs to `/usr/local/bin` — one static Go binary, ~270 MB over
Tor, arch-suffixed asset (`sliver-server_linux-amd64`). It works offline once it's
down: first run unpacks its embedded toolchain rather than fetching one, so implant
compilation needs no network at all. Two limits worth knowing before you rely on it:

- **`torify` does nothing for Sliver itself.** torsocks is `LD_PRELOAD` over libc,
  and Go makes raw syscalls straight past it — so Sliver's traffic goes direct and
  the Tails firewall drops it. Anything that reaches out (`armory install`) needs
  Go's own proxy support instead:

  ```bash
  HTTPS_PROXY=socks5://127.0.0.1:9050 sliver-server
  ```

- **Implants can't call back to a Tails box** without an onion service you set up by
  hand — and Tails regenerates `torrc` every boot, so that's per-session work. As a
  local implant builder and workbench it's fine; as a callback server it isn't.

**Mythic is staged, not installed.** It's a Docker stack, and two things about Tails
get in its way. The Docker daemon runs as root, and root's traffic is not torified — the
Tails firewall drops it, so image pulls fail, and so does `make`, which pulls its
builder image from `ghcr.io`. And the images run to several GB against a filesystem
that is RAM. So the script installs the daemon and clones the repo:

```bash
cd ~/Mythic && sudo make        # builds mythic-cli
sudo ./mythic-cli start         # brings the stack up
```

Both of those need egress the Tails firewall doesn't give the daemon, so bringing
Mythic up is a decision you make with a plan for that, not something the script does
behind your back. Sliver is the one to reach for on a live session; the better use
of Mythic from Tails is as an *operator*, pointing a browser at a Mythic you already
run elsewhere (`https://<server>:7443`), which needs no Docker here at all.

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
