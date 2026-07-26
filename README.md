# linux-autodeploy

Automated deploy scripts for security workstations. Two current Kali scripts, plus
the Ubuntu recipes they grew out of.

> For authorized engagements, CTFs, and lab work only.

## Which script

| Script | Target | Desktop | Access |
|---|---|---|---|
| **`kali-autodeploy-laptop`** | Physical laptop you sit at | i3 + polybar + kitty | local only; hardened for a hostile LAN |
| **`kali-autodeploy`** | Headless box / cloud teamserver | none | Tailscale SSH + hardened OpenSSH + ufw |
| `ubuntu-autodeploy-v5` | Ubuntu workstation | i3 + polybar + kitty | n/a |
| `ubuntu-autodeploy-v4` | superseded by v5 | | |
| `Ubuntu-Autodeploy-Original-Recipe.sh` | kept for reference | | |

---

## kali-autodeploy-laptop

A Kali-first deploy for a laptop you carry: the full tool set, the i3 desktop, and
hardening aimed at a conference network.

```bash
sudo ./kali-autodeploy-laptop
```

Options:

```
--dry-run          show what would happen; change nothing
--skip <phase>     skip a phase (repeatable)
--only <phase>     run only these phases (repeatable)
--list-phases      print phase names
--print-packages   print every package the script can install
-h, --help
```

Phases: `base tools desktop harden i3 polybar kitty shell wordlists`

Re-running is always safe — every phase is idempotent, so a run that dies partway
can be resumed by running it again (or narrowed with `--only`). A full transcript
goes to `/var/log/kali-autodeploy-laptop-<timestamp>.log`.

### What it installs

Tools come from Kali's own `kali-tools-*` metapackages rather than a hand-listed set
of package names — they're curated, dependency-resolved, and stable across rolling.
Edit `TOOL_METAS` at the top of the script to change scope.

Included: information-gathering, vulnerability, web, database, passwords,
exploitation, post-exploitation, sniffing-spoofing, windows-resources,
reverse-engineering, 802-11, wireless, bluetooth, rfid.

Not included: `kali-tools-sdr` (gnuradio is a very large dependency tree). Add it to
`TOOL_METAS` if you want it.

The desktop is `kali-desktop-i3`, which is a complete desktop — i3, lightdm, polybar,
kitty, picom, feh, network-manager, betterlockscreen — with the i3 session registered
with the display manager. On top of that the script writes the i3, polybar, and kitty
configs carried over from `ubuntu-autodeploy-v5`.

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
cost. To remove, delete the block between the `kali-autodeploy-laptop` markers in
`~/.zshrc`.

---

## kali-autodeploy (headless)

For a box you reach over Tailscale rather than sit at. Installs the Kali tool set with
no GUI, joins a tailnet with Tailscale SSH as the primary auth path, hardens OpenSSH as
a fallback, and restricts inbound to the `tailscale0` interface.

```bash
sudo ./kali-autodeploy [agent] [profile]
```

Environment knobs: `TS_AUTHKEY`, `TS_ADVERTISE_TAGS`, `SSH_PUBKEY`, `SKIP_TAILSCALE=1`,
`SKIP_UFW=1`.

It will not disable password auth or enable the firewall unless it can prove you have
another way in (an installed key, or Tailscale already up) — a box that can't reach
itself is worse than one with password auth on.

See `TMUX-TAILSCALE-CHEATSHEET.md`.

---

## Testing

Deploy scripts are hard to test because the failure mode is a half-configured machine.
`tests/` validates the laptop script against a real Kali container before it touches
hardware:

```bash
tests/run-tests.sh                # static analysis + container suite
tests/run-tests.sh --static-only  # bash -n + shellcheck only
```

Covers: every package name resolving to an installation candidate, full dependency
resolution via `apt --simulate`, `--dry-run` mutating nothing, the config phases
running for real with correct ownership, `i3 -C` validating the generated config,
idempotency across repeated runs, graceful degradation with no systemd, injected
bad-package handling, and argument validation.

The suite reads its package list from `--print-packages`, so it cannot drift out of
sync with the script.

Requires docker. It pulls `kalilinux/kali-rolling` and
`koalaman/shellcheck` and modifies nothing on the host.

---

## Ubuntu scripts

`ubuntu-autodeploy-v5` is the last Ubuntu version and the source of the i3 desktop the
Kali laptop script inherits. `SPEC.md` describes the v3 rewrite that established the
current structure. v5 fixed a series of real v4 deploy failures — a package with no
installation candidate aborting the whole apt batch under `set -e`, `setcap` on a venv
symlink, `gunzip` on a file that wasn't gzip — which is why none of these scripts use
`set -e`.
