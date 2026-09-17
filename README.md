# pi-sandbox — run PI in rootless Podman, no permission prompts

The container **is** the permission boundary. PI upstream says it explicitly:
*"No permission popups. Run in a container."* So PI gets full tool access
inside, and the host only ever exposes what `config.json` allows: one
workspace dir, listed mounts, listed env. A single Python file (stdlib only),
so there's almost nothing to audit: `pi-sandbox`.

```bash
pi-sandbox init                  # writes ~/.config/pi-sandbox/config.json (600)
pi-sandbox build                 # build the image (once)
cd ~/my-project
pi-sandbox run                   # interactive pi, no prompts
pi-sandbox run -p "audit this repo"
pi-sandbox run -c                # resume previous session (they persist, see below)
pi-sandbox exec -- bash          # raw shell in the same sandbox (debugging)
pi-sandbox show                  # effective config + exact podman command
pi-sandbox --dry-run run -p "x"  # print podman command without running it

# one-off overrides for a single run (these flags must come first):
pi-sandbox run --mount ~/docs:/docs:ro -- -p "summarize /docs"
pi-sandbox run --mount ~/data --workspace ~/other-project -- -p "migrate this"
pi-sandbox run --env MODEL_FALLBACK=1 --publish 3000 -- -p "run the dev server"
```

One-off flag reference: `--mount SRC[:DST][:ro|rw]` (bare `SRC` lands at
`/mnt/<name>`, default `ro`), `--workspace DIR`, `--env KEY=VALUE`,
`--publish PORT[:CPORT]` (localhost-only, see below). CLI values override
config on conflict (mount `dst`, env key) with a warning. Same flags work on
`exec`.

## Sessions persist — reboot-safe resume

PI stores sessions under `~/.pi/agent/sessions/`, and in the sandbox `$HOME`
is the named `home_volume`, which lives on host disk and survives container
removal *and* reboots (verified: write a session file in one run, read it in
the next fresh container). So `pi-sandbox run -c` (continue), `-r` (pick),
`--session <id>`, and `--name "..."` all work across reboots. Every run is
`--rm` (ephemeral container), but the volume is forever until you
`podman volume rm` it.

One caveat: PI files sessions by working directory, and every run sees the
same cwd (`/workspace`) — so `run -c` in project B could offer project A's
session. Remedies: name important sessions (`run -- --name "auth-refactor"`),
or give a project its own home volume (`--config ./.pi-sandbox.json` with a
different `home_volume`, or `PI_SANDBOX_CONFIG` via direnv) so its sessions
are fully separate.

## Git from inside: identity + push without SSH mounts

The scratch home volume has no git identity, so set it via env (git honors
these, no files needed) in config `env`:

```json
"env": { "GIT_AUTHOR_NAME": "you", "GIT_AUTHOR_EMAIL": "you@host",
         "GIT_COMMITTER_NAME": "you", "GIT_COMMITTER_EMAIL": "you@host" }
```

For push/pull, prefer `GH_TOKEN` in `env` (or `gh auth login` once — the
token persists in the home volume) and https remotes: no `~/.ssh` mount
needed. Only mount `~/.ssh` read-only if a repo is ssh-only. Commit signing
(GPG/SSH keys) doesn't work in the sandbox by design — accept unsigned
sandbox commits, or sign on the host.

## Dev servers: `--publish` (localhost-only)

The agent can't be reached from outside by default. For a one-off dev server:
`pi-sandbox run --publish 3000 -- -p "start the dev server"`, then open
`http://localhost:3000` on the host. Published ports bind `127.0.0.1` only
(verified with `ss`: LAN can't connect). There is no config equivalent —
ports are per-run by design.

Don't run two sandboxes on the same directory at once: both would mount the
same workspace `rw` and the agents would step on each other (and on PI's
session files).

## Why Python and not shell?

The first version of this wrapper was bash. It died the moment config became
structured: JSON parsing needs `jq`, env values with spaces/`$`/quotes break
naive quoting, mount lists need arrays, and validation becomes unreadable.
Python's stdlib (`json`, `argparse`-free manual parsing, `os.execvp`) handles
all of that with zero dependencies. Same `pi-sandbox run` UX, none of the
quoting footguns. `run`/`exec` replace themselves with podman via `execvp`,
so TTY/signals behave exactly like a shell `exec`.

## config.json reference

Resolution: `--config PATH` > `$PI_SANDBOX_CONFIG` >
`~/.config/pi-sandbox/config.json` > `./config.json`.
`init` also picks up the legacy `~/.config/pi-sandbox/api.env` if present
(referenced via `env_file`, your keys keep working).

| key | meaning |
|---|---|
| `image` | image tag to build/run (default `pi-sandbox:latest`) |
| `env` | object of `KEY: value` passed as `-e` (e.g. `OPENROUTER_API_KEY`). One place for all secrets. |
| `env_file` | list of env files (`--env-file` each). Missing file = error. |
| `mounts` | list of `{src, dst, mode, required}`. `src` supports `~`, relative = relative to cwd. `mode` is `ro` (default) or `rw`. `required: false` skips silently if `src` is missing. This replaces the old `--ssh` special case: just add `{"src": "~/.ssh", "dst": "/home/agent/.ssh", "mode": "ro"}`. |
| `workspace` | dir mounted at `/workspace`. `null` = current directory. |
| `memory` / `cpus` / `pids_limit` | resource caps (`4g` / `2` / `256`). |
| `home_volume` | named volume for `/home/agent` (PI sessions/config persist here, host home stays hidden). |
| `extra_args` | escape hatch: raw args inserted before the image name. Bypasses validation — you own whatever you put here. |

`dst` may not overlay container internals (`/`, `/workspace`, `/tmp`,
`/home/agent`, `/proc`, `/sys`, `/dev`, `/run`, `/etc`, `/boot`); `src: "/"`.
is refused. Everything a mount exposes is readable (and if `rw`, writable) by
the agent — prefer `ro`, never mount `$HOME` or secret stores `rw`.

Every image rebuild is `pi-sandbox build`; every run is `--rm` (ephemeral —
only `/workspace`, mounts, and the home volume survive).

## Networking: host default, nothing to configure

The container uses podman's default network, which NATs through the host
routing table — so whatever the host does, the sandbox does. If `wg0` carries
your default route, container traffic exits via `wg0`. Verify once:

```bash
curl -s ifconfig.me                        # host egress IP
pi-sandbox exec -- curl -s ifconfig.me     # container egress IP (same = good)
```

There is deliberately no network option in `config.json`: no `host` mode (it
would destroy the isolation), no sidecars, nothing to misconfigure.

## Arch laptop setup

```bash
sudo pacman -S podman buildah python3
grep $USER /etc/subuid || echo "$USER:100000:65536" | sudo tee -a /etc/subuid /etc/subgid
pi-sandbox init            # edit env/mounts in ~/.config/pi-sandbox/config.json
pi-sandbox build
```

## Rules (where the safety comes from)

The tool enforces the important ones: no `--privileged`, no host namespaces,
no `host` network, no mounts outside the allowlist above, `cap-drop all` +
`no-new-privileges` always on. Via `extra_args` you *could* undo all of this —
don't. Verified: `CapEff 0`, host FS invisible except `/workspace`, and even
`rm -rf / --no-preserve-root` inside the container leaves host and image
intact (system files are root-owned, we run as `agent`).

## Residual risk

The container blocks *breaking your system*. It does not block *using your
network*: with network access the agent can exfiltrate whatever is mounted,
mine crypto (capped here), or probe LAN. Mitigation: mount the minimum,
keep secrets in `env` (not in files under `/workspace`), no sensitive
unauthenticated services on host localhost. Kernel 0-day escapes are
VM-territory — traded away for no-VM overhead. For a coding agent (stray
`rm -rf`, malicious install script), nothing can realistically happen.
