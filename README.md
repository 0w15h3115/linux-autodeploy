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
| **`kali-deploy-physical`** | Physical laptop you sit at | i3 + polybar + kitty, picom on glx | local console, plus sshd |
| **`kali-deploy-vm`** | Hyper-V guest reached over a remote agent | i3 + polybar + kitty, no compositor | ScreenConnect / ConnectWise Control agent |
| **`kali-deploy-remote`** | Headless box / cloud teamserver | none | Tailscale SSH + hardened OpenSSH + ufw |
| **`kali-deploy-wsl`** | Kali as a WSL2 instance on a Windows host | none — Windows Terminal draws the shell | none; you enter with `wsl.exe` |
| **`test-with-tails`** *(beta)* | Tails OS live session | Tails' own GNOME | everything over Tor; nothing persists |

`kali-deploy-vm` is configuration only — it installs **no tools**, on the basis that
a stock Kali image already ships `kali-linux-default`. Use `kali-deploy-physical`
if you want the `kali-tools-*` metapackage set.

Superseded Ubuntu scripts live in [`archive/`](archive/). `SPEC.md` covers the
design reasoning behind the two Kali scripts.

---

## kali-deploy-physical

A Kali-first deploy for a box you sit at, physical or virtual: the full tool set,
the i3 desktop, and a hardening phase kept deliberately out of the tooling's way.

```bash
sudo ./kali-deploy-physical
```

Options:

```
--dry-run          show what would happen; change nothing
--mac-stable       clone a per-network MAC (off by default)
--mac-random       clone a fresh MAC per activation (off by default;
                   breaks long-lived connections)
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

Deliberately thin. This is a pentest box, and the controls a general-purpose
baseline applies are the same ones that break the tooling installed alongside
them — so the phase does less than its name suggests, on purpose.

- **`ufw` is not enabled**, and an earlier run's enabled state is undone. A
  default-deny inbound policy lets every listener here — Responder, `ntlmrelayx`,
  a msfconsole handler, `impacket-smbserver`, `python3 -m http.server` — bind
  successfully and then catch nothing. That failure gets debugged from the target
  end, mid-engagement, long after anyone remembers a firewall is involved.
- **`sshd` is left running.** The box is reached remotely, and a remote-access
  agent depending on X, the display manager and a vendor relay is a single point
  of failure; sshd is the way back in, and the pivot path besides.
- **`bluetooth.service` is left running** — the BT tools this script installs
  drive `bluetoothd`, so disabling it disabled the tooling.
- `avahi-daemon` and `cups`/`cups-browsed` **off**. This one is a port-conflict
  fix rather than hardening: avahi holds UDP 5353 and cups holds 631, and
  Responder needs 5353 free to poison mDNS. It binds what it can and stays quiet
  about the rest, so the symptom is a capture that never happens.
- **MAC cloning off** unless asked for — `--mac-stable` for a per-network MAC,
  `--mac-random` for a fresh one per activation. See the caveat below.
- **No idle screen lock.** `Mod+Escape` locks on demand and `xss-lock` still
  locks on suspend; there is no timeout to come back to mid-job.

The verification pass ends with an `ss -tulpn` listing of everything actually
listening. Read that rather than trusting the toggles.

If a specific engagement wants a firewall policy, set it deliberately:

```bash
fw-status                   # sudo ufw status verbose
fw-open 8000/tcp            # sudo ufw allow 8000/tcp
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
4. MAC cloning is off unless you passed `--mac-stable` or `--mac-random`; the
   `MAC:` line in the verification summary says which. If you did enable it and a
   captive portal or MAC-allowlisted network rejects you, that's why —
   `sudo rm /etc/NetworkManager/conf.d/00-macrandomize.conf`.

   `--mac-random` additionally breaks anything holding a long-lived outbound
   socket: a fresh MAC per activation means a new DHCP lease and a new IP on
   every reconnect, so a remote-access agent (ConnectWise Control, Tailscale, an
   SSH reverse tunnel) drops with "the network connection has been disconnected".
   `--mac-stable` keeps a per-network address, so the lease survives.

   **On a VM neither is safe without host cooperation.** A hypervisor's vSwitch
   forwards only frames whose source MAC it assigned to the vNIC. Hyper-V exposes
   this as *Settings → Network Adapter → Advanced Features → Enable MAC address
   spoofing*, **off by default**, and with it off any cloned MAC — stable or
   random, the switch doesn't distinguish — gets the guest's traffic dropped, and
   it stays dropped across reboots because each boot re-applies it. If a VM
   deployed by an older version of this script has no network, that's the first
   thing to check:

   ```bash
   ip link show                        # active MAC vs. the one Hyper-V assigned
   sudo rm /etc/NetworkManager/conf.d/00-macrandomize.conf
   sudo systemctl restart NetworkManager
   ```

   Re-running the deploy does the same thing for you.
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
sudo SCREENCONNECT_URL='https://<you>.screenconnect.com/Bin/ConnectWiseControl.ClientSetup.deb?e=Access&y=Guest&t=' \
     ./kali-deploy-vm --only screenconnect
```

Phases: `base hyperv desktop i3 polybar kitty shell screenconnect`

Options are the same grammar as the other two, plus `--autologin` and
`--compositor <xrender|glx|egl>`.

### How this differs from kali-deploy-physical

The split is deliberate: **`kali-deploy-physical` is for hardware you sit at, and
stays that way.** It hardcodes `picom --backend glx`, which is correct on a real
GPU and has worked on that deploy for as long as it's existed — there's no VM
accommodation in it, and nothing here asks it to grow one. Pick between them on
the target, not on the options.

If you want the tools, use `kali-deploy-physical`; this script installs none.

**No compositor.** A Hyper-V guest has no hardware GLX — Mesa falls back to
llvmpipe. `picom --backend glx` fails *after* it has already mapped the composite
overlay window, and that overlay is full-screen, opaque, and never made
input-transparent: a black screen that swallows every keystroke, with i3 running
fine underneath. Beyond that, on a box reached by screen-scraping, compositing
buys nothing you can see and costs bandwidth on every frame. `--compositor
xrender` opts back in with the backend that has no GL dependency.

**No idle lock, no DPMS blanking.** On a remote box a blanked screen is
indistinguishable from a hung one, and an idle lock you didn't ask for means
typing a password down a laggy link to get back into a session you never left.
`$mod+Escape` still locks manually.

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

**It asks you for the URL.** Run the script with nothing set and the phase prompts,
reads it back for proofreading, and lets you re-enter up to three times:

```
[+] The ScreenConnect agent needs the installer URL from your instance.
[+]   Access -> Build Installer -> Linux -> copy the .deb link.

[+]   No clipboard in the guest yet? Two ways round it:
[+]     - VMConnect menu: Clipboard -> Type clipboard text
[+]     - or serve the .deb off the host and type a short LAN URL

  URL: https://acme.screenconnect.com/Bin/...

  You typed:
    https://acme.screenconnect.com/Bin/ConnectWiseControl.ClientSetup.deb?e=...

  Correct? [Y/n] 
[+] got a URL for https://acme.screenconnect.com
```

The proofreading matters because **this is the phase that bootstraps the
clipboard** — until the agent is up, a Hyper-V guest in a basic VMConnect session
has no path from the host clipboard, and the URL is ~150 characters of session
parameters. If you have to type it by hand, a one-shot prompt that only fails at
download time is not usable. Surrounding whitespace is trimmed, since
*Type clipboard text* can pick up a stray leading space or trailing newline.

The read-back goes to `/dev/tty`, **not** through stdout — stdout is teed to
`/var/log` and the URL carries session parameters (`y=`, `c=`, `s=`), so echoing it
into the transcript would defeat every other guard here. Only the host is logged.
The URL is also never passed through the `run()` helper (which prints its
arguments under `--dry-run`), and it's scrubbed out of curl's stderr before any
error is printed.

If you'd rather not type it at all: serve the `.deb` from the Windows host
(`python -m http.server 8000`) and type a short LAN URL instead — the phase takes
any URL, not just a Control one.

The prompt appears **only when stdin is a terminal** and not under `--dry-run`.
SPEC.md rules out interactive prompts because a prompt that hangs an unattended
run is the exact failure the whole spec exists to avoid — so from cron, a pipe, or
CI this falls straight through to the skip path instead of waiting. Pre-supply it
to skip the question entirely:

| Variable | Meaning |
|---|---|
| `SCREENCONNECT_URL` | ClientSetup URL from **Access → Build Installer → Linux** |
| `SCREENCONNECT_DEB` | path to an already-downloaded `.deb`; takes precedence |

Same variable names `kali-deploy-physical` uses, so a box that gets one script can
be handed the other unchanged.

Press Enter alone and the phase **skips and prints what to do** — it is never a
reason for the run to fail, and the desktop is already up by the time it runs.

The phase installs the X libraries the agent links against before the `.deb`,
because a missing one produces an agent that installs cleanly, starts cleanly, and
shows you a black rectangle. `libicu` is resolved dynamically since its version
suffix moves with every Debian import.

This phase takes a `.deb` only — prefer the one your Control server builds.
`ClientSetup.sh` takes its RPM branch whenever `rpm(1)` exists, and on Debian that
fails: ConnectWise's noarch RPMs ship unsigned and without file digests, while
Debian's rpm defaults `%_pkgverify_level` to `all`, so the install dies on
`does not verify: no digest`. A `.deb` skips the branch entirely.

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

Use [`kali-deploy-wsl`](#kali-deploy-wsl). This script still detects WSL and skips its
access layer there, so an existing invocation keeps working, but WSL is no longer its
target — see the section below for why it moved.

---

## kali-deploy-wsl

Kali as a WSL2 instance on a Windows host: the box you sit at all day and enter with
`wsl.exe` from Windows Terminal.

```bash
sudo ./kali-deploy-wsl
```

### Why it is its own script

WSL support used to be a detected profile inside `kali-deploy-remote`. It moved because
that script *is* its access layer — Tailscale SSH, a hardened OpenSSH, and a default-deny
ufw — and on WSL all three are wrong, so running it there meant running it with the whole
thing switched off. A target that needs a script's defining feature disabled is a
different target, not an option of that one, which is the split `SPEC.md` already argues
for. Here the access layer is **absent**, not skipped: no `tailscale`, no `sshd`, no
`ufw`, and no phases for them.

### What it leaves out

| Left out | Why |
|---|---|
| i3 / polybar / picom | No window manager. WSLg gives each GUI application its own Windows window, so there is no session for a WM to own and `kali-desktop-i3` installs a stack that cannot start. GUI *applications* do work — see the `wslg` phase. |
| kitty | The terminal is a Windows application. Configuring a Linux terminal emulator would configure the wrong machine. |
| font probing | Same reason — `fc-list` here answers a question about the guest while Windows draws the glyphs. |
| tailscale / ssh / ufw | Run Tailscale on the *Windows* host; the tailnet is reachable from inside without a second `tailscaled`. WSL2 is NAT'd behind the host, so inbound is Windows Firewall's business. |
| MAC cloning, monitor mode, bluetooth | The adapters belong to Windows and WSL2 sees none of them. The `802-11`, `wireless`, `bluetooth` and `rfid` metapackages are excluded from `--with-metas` for the same reason. |

### What it adds

A `wslconf` phase — the only phase in this repo that configures the boundary with the
Windows host rather than anything inside Kali. It writes `/etc/wsl.conf` with `systemd`,
`[interop]`, and the `automount` **`metadata`** option, that last one being the fix for
every file under `/mnt/c` reading as `0777 root:root` — which makes `chmod` a no-op, stops
`ssh` accepting a key stored there, and shows the whole tree as mode-changed in `git`.

The phase is non-destructive by construction: `wsl.conf` is routinely hand-edited, so it
creates the file, appends a section that is entirely absent, and **never rewrites a
section that is already there**. Where a section exists but lacks a key, it prints the
line to add rather than editing around it. Changes need `wsl --shutdown` from Windows,
which the script says rather than pretends to do.

### The `wslg` phase — GUI apps on the GPU

Kali under WSL runs GUI applications fine, but renders them on the **CPU** out of the
box, and the symptom looks like a broken display rather than a missing driver:

```
[GFX1-]: glxtest: libpci missing
[GFX1-]: glxtest: libEGL missing
[GFX1-]: glxtest: EGL test failed
[GFX1-]: No GPUs detected via PCI
```

Every one of those lines is a missing package, not a missing GPU. Windows *is* passing
the GPU through — it appears as `/usr/lib/wsl/lib/libd3d12.so` — but Kali ships no Mesa
userspace, and Mesa's **d3d12 gallium driver** (in `libgl1-mesa-dri`) is the bridge.
`libpci3` is what lets `glxtest` enumerate the bus at all, which is why its absence reads
as *"No GPUs detected"*.

So the phase installs `libgl1`, `libegl1`, `libglx-mesa0`, `libgl1-mesa-dri`, `libpci3`,
`mesa-utils` and `firefox-esr` — gated on `/mnt/wslg`, since without a way to display a
window that is ~200MB of driver for nothing. Firefox is **named rather than inherited**:
it is on a stock image but not on a netinst, and it is `firefox-esr` — plain `firefox` has
no candidate on Kali, so naming the obvious one installs nothing silently.

The phase also compiles the **dconf system db**. Kali's `/etc/dconf/profile/user` declares
`system-db:local` but never builds it, so every GTK app opens with an alarming
`unable to open file '/etc/dconf/db/local' ... expect degraded performance`. Cosmetic, and
noisy enough to send you debugging a display problem you don't have.

Verification reads the **renderer**, not the package list — `d3d12` means the GPU bound,
`llvmpipe` means Mesa fell back to software and every window will feel like it.

### Windows interop

Windows interop lands in the shell block: `pbcopy` / `pbpaste` against the Windows
clipboard, `open` (via `wslview` if you have it, else `explorer.exe`), `cdwin` and
`winhome` for the host profile directory, and `winhost` for the host's IP as seen from
inside. tmux copy-mode `y` pipes to `clip.exe`, so a selection lands on the clipboard you
are actually going to paste from.

`wslu` is deliberately **not** installed: Kali carries no such package, and listing a name
that never resolves is what T1 exists to reject. Adding Debian's repo to a rolling release
is ruled out by `SPEC.md`. `explorer.exe` covers the gap, and `wslview` is probed at
runtime in case you install it by hand.

### Tools

The headless set plus `ffuf`, `gobuster` and `sqlmap` — on a workstation those are
baseline, not an extra. `--with-metas` additionally installs the ten software-only
`kali-tools-*` metapackages for the breadth `kali-deploy-physical` gives a laptop; it is
off by default because it is a multi-gigabyte install onto a disk that is a growable file
on the host's NTFS volume.

### tmux auto-attach is opt-in here

The reverse of `kali-deploy-remote`, where a dropped SSH connection kills your work so
attaching every login to a persistent session is a straight win. Here every Windows
Terminal tab is a fresh login shell, and auto-attaching them all to one session means the
second tab steals the first one's panes. Set `AUTO_TMUX=1` for the remote behaviour.

### Fonts

Install a Nerd Font on the **Windows** side and select it in the Windows Terminal profile.
Nothing inside the instance can check this, so the script says so instead of ticking it;
`VINNY_ASCII=1` is the fallback.

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
