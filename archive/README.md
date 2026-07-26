# archive

Superseded scripts, kept for reference and because the current Kali scripts
inherit real work from them. Not maintained, not covered by CI, and not
recommended for a new deploy.

| File | What |
|------|------|
| `ubuntu-autodeploy-v5` | Last Ubuntu version. Source of the i3 / polybar / kitty configuration that `kali-deploy-physical` carries over, and of the `apt_available` / `apt_install` resilience helpers both Kali scripts use. |
| `ubuntu-autodeploy-v4` | Superseded by v5, which fixed a series of real deploy failures in it. |
| `Ubuntu-Autodeploy-Original-Recipe.sh` | The original monolithic recipe everything grew out of. |

## Why v5 exists

Each v5 change fixed a crash observed on an actual v4 run, and the lessons are
why none of the current scripts use `set -e`:

- `openjdk-8-jre` had no installation candidate on Ubuntu 22.04+. Under `set -e`
  that single unavailable package aborted the entire `apt-get install` and the
  script died having installed nothing. This is the failure that motivated
  `apt_available` / `apt_install`, and on the Kali side the move to
  metapackages.
- `setcap` was called on `venv/bin/python3`, which `python3 -m venv` creates as
  a symlink — `setcap` refuses to operate on symlinks.
- `gunzip` was run on a rockyou download that was plain text from one source and
  bzip2 from the other, so it never succeeded.
- `get_real_user`'s `exit 1` only exited the `$(...)` subshell, and `warn`/`err`
  wrote to stdout where the command substitution captured their text into the
  username.

The current scripts are `kali-deploy-physical` and `kali-deploy-remote`
in the repository root.
