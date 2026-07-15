# Headless Kali: Tailscale + tmux Cheat-Sheet

Companion to `kali-autodeploy`. This box has **no GUI** — you reach it over
Tailscale and run multiple terminals inside **tmux**.

---

## 1. Deploy the box

```bash
sudo ./kali-autodeploy
```

Optional environment variables (all can be combined):

| Variable | Effect |
|---|---|
| `TS_AUTHKEY=tskey-...` | Unattended tailnet join (no browser). Reusable key = same command on many boxes. |
| `TS_ADVERTISE_TAGS=tag:server,tag:kali` | Node lands with ACL tags already applied. |
| `SSH_PUBKEY='ssh-ed25519 AAAA... you@laptop'` | Installs a key for the OpenSSH fallback path. |
| `SKIP_TAILSCALE=1` | Don't touch Tailscale (join it yourself). |
| `SKIP_UFW=1` | Don't configure/enable the firewall. |

Scalable one-liner for repeat deploys:

```bash
TS_AUTHKEY=tskey-xxxx TS_ADVERTISE_TAGS=tag:kali \
  SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" sudo ./kali-autodeploy
```

**One-time tailnet setup** (in the Tailscale admin console → Access Controls):
Tailscale SSH needs an ACL rule granting SSH to this node, e.g.

```jsonc
"ssh": [
  { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:kali"], "users": ["autogroup:nonroot", "kali"] }
]
```

---

## 2. Connect from anywhere

Both work from any device already on your tailnet:

```bash
tailscale ssh kali@<hostname>     # primary — identity/ACL gated, no keys to manage
ssh kali@<tailscale-ip>           # fallback — hardened OpenSSH, key-only
```

Find the box's tailnet IP (on the box): `tailscale ip -4`  (alias: `tsip`).

Your `.zshrc` **auto-attaches to a `main` tmux session on SSH login**, so you
usually land straight into your persistent workspace.

---

## 3. tmux — the essentials

The **prefix** is `Ctrl-b`. Press it, release, then the command key.

### Sessions (persist across disconnects — the whole point over SSH)
| Keys / command | Action |
|---|---|
| `tmux new -s main` (alias `tn main`) | Start a named session |
| `Ctrl-b d` | Detach — everything keeps running on the box |
| `tmux attach -t main` (alias `ta main`) | Re-attach after a drop/reconnect |
| `tmux ls` (alias `tl`) | List sessions |
| `tmux kill-session -t main` (alias `tk main`) | End a session |

> If your laptop sleeps or Tailscale reconnects, your scans keep running.
> Reconnect and `ta main` — you're exactly where you left off.

### Windows (like tabs)
| Keys | Action |
|---|---|
| `Ctrl-b c` | New window |
| `Ctrl-b n` / `Ctrl-b p` | Next / previous window |
| `Ctrl-b 0..9` | Jump to window by number |
| `Ctrl-b ,` | Rename current window |
| `Ctrl-b w` | Visual window/session picker |
| `Ctrl-b &` | Kill window |

### Panes (tiles within a window)
| Keys | Action |
|---|---|
| `Ctrl-b \|` | Split vertical (left/right) |
| `Ctrl-b -` | Split horizontal (top/bottom) |
| `Ctrl-b h/j/k/l` | Move between panes (vim-style) |
| `Ctrl-b z` | Zoom pane fullscreen (toggle) |
| `Ctrl-b x` | Kill pane |
| `Ctrl-b {` / `}` | Swap pane position |

### Other
| Keys | Action |
|---|---|
| Mouse | Enabled — click panes, drag borders, scroll |
| `Ctrl-b [` | Scroll/copy mode (`q` to exit) |
| `Ctrl-b r` | Reload `~/.tmux.conf` |

---

## 4. A typical pentest layout

```
tmux new -s clientX          # one session per engagement, kept separate
  window 0 "recon"   → nmap / dns
  window 1 "relay"   → pane: responder | pane: impacket-ntlmrelayx
  window 2 "loot"    → netexec / bloodhound-python / secretsdump
  window 3 "notes"   → your notes / shell
Ctrl-b d                     # detach, go home, reconnect tomorrow with: ta clientX
```

Start a fresh, isolated session per client so nothing bleeds between engagements.
