# Claude Sandbox
An isolated Docker sandbox for running Claude Code with `--dangerously-skip-permissions` safely.

> [!CAUTION]
> The blast radius of "skip permissions" is therefore that one repo/folder + the network allowlist.
> Claude can freely edit/run code in the repo but cannot touch the rest of your machine.

## What it isolates
- **Filesystem**: Claude only sees the one repo folder you mount (at its real
  host path, so per-project memory keys match). No other host folder is visible
  — not your home dir, not `~/.ssh`, nothing else.
- **Memory & config**: your per-project memory (`memory/` + `MEMORY.md`),
  `skills/`, global `CLAUDE.md` and `settings.json` are mounted **read-only**
  from `~/.claude`, so the sandbox can recall/use them but cannot modify them.
  Your cross-session `*.jsonl` transcripts are **not** exposed.
- **Git**: `~/.gitconfig` and `~/.ssh` are mounted **read-only** so commits
  carry your identity and `git push` over SSH works (through the corporate
  proxy defined in `~/.ssh/config`). ⚠️ This means your real SSH private key is
  readable by the sandboxed Claude — see the caveat under Notes.
- **Network**: default-deny egress. Only your auth endpoint (Bedrock /
  api.anthropic.com / custom base URL) and any domains you explicitly allow can
  be reached.
- **Privileges**: the entrypoint briefly runs as root to program the firewall,
  then drops to the non-root `node` user (remapped to your host UID so edited files stay owned by you).
  There is no `sudo` in the image, and `no-new-privileges` blocks any escalation back to root.

## Setup
Copy environment variables and update values:
```sh
cp .env.example .env
```

Configure auth by exporting **one** of the following (in your shell or `.env`).
The matching endpoint is allowlisted automatically:
```sh
# Amazon Bedrock:
export AWS_BEARER_TOKEN_BEDROCK=...   # and optionally AWS_REGION (default us-east-2)
# Anthropic API:
export ANTHROPIC_API_KEY=sk-ant-...
# Gateway / proxy (custom endpoint + token):
export ANTHROPIC_AUTH_TOKEN=...
export ANTHROPIC_BASE_URL=https://llm-gateway.example.com
```
Symlink the launcher into a directory already on your `PATH` so you can run it from anywhere:
```sh
ln -sf ~/claude-sandbox/sandbox.sh ~/.local/bin/sandbox-claude
```
The script resolves the symlink back to its real location, so it still finds the `Dockerfile` and `.env`. Then, from any folder:
```sh
sandbox-claude --shell ../test
```

## Usage

```sh
./sandbox.sh # Map the current directory and start claude --dangerously-skip-permissions
./sandbox.sh ../test # Map a specific folder instead
./sandbox.sh --shell # Drop into a bash shell instead of claude
```

## Files

| File | Runs where | What it does |
|------|-----------|--------------|
| `sandbox.sh` | host | The launcher you invoke. Parses args (`[--shell] [folder]`), resolves the folder to map (defaults to the current dir), rebuilds the image, assembles the read-only `~/.claude` / git / ssh mounts, and `docker run`s the container. Also always allowlists the git-over-ssh hosts. |
| `Dockerfile` | build | Defines the image: Node 20 base + `git`, `openssh-client`, `netcat-openbsd`, firewall tooling (`iptables`, `ipset`, `dnsutils`), `gosu`, and the Claude Code CLI. Copies in the two runtime scripts and sets the entrypoint. No `USER` line — the entrypoint starts as root and drops privileges itself. |
| `entrypoint.sh` | container (root → node) | The container's entrypoint. Runs the firewall, remaps the `node` user to your host UID/GID (so files you edit stay owned by you), prints status, then drops root via `gosu` and execs the requested command (`claude …` or `bash`). |
| `init-firewall.sh` | container (root) | The egress firewall. Flushes rules, allows loopback + DNS + established traffic, resolves the allowlisted domains (`ALLOWED_DOMAINS`, which `sandbox.sh` has already populated with the auth endpoint + git + pypi) to IPs, permits outbound TCP to only those IPs on the allowed ports, then sets the default policy to DROP. |
| `.env` | host (sourced by `sandbox.sh`) | Local machine config (gitignored) — e.g. corporate proxy host + `ALLOWED_PORTS`. Sourced before defaults; command-line values still win. Copy `.env.example` to start. |

## Notes

- The image is (re)built on every launch — fully cached, so it adds ~1–2s.
- **Your auth endpoint is always allowed** (Claude can't run otherwise) —
  Bedrock (`bedrock-runtime.$AWS_REGION.amazonaws.com`), `api.anthropic.com`, or
  the host from `ANTHROPIC_BASE_URL`, depending on which auth you set. Add
  whatever else you need via `ALLOWED_DOMAINS`.
- **PyPI is allowed by default** (`pypi.org` + `files.pythonhosted.org`, both
  needed for `pip install`), alongside the git-over-ssh hosts. Edit the
  `DEFAULT_DOMAINS` line in `sandbox.sh` to change this.
- The allowlist is resolved to IPs **once at container start**. If a service
  rotates IPs (CDNs), restart the container to re-resolve, or add its stable
  domains.
- Claude's login/config persists in the `claude-sandbox-config` Docker volume,
  so you don't re-auth every run. Remove it with
  `docker volume rm claude-sandbox-config`.
- **Memory is read-only**: the sandbox can *recall* memories but cannot *save*
  new ones back to the host (by design — a `--dangerously-skip-permissions`
  Claude shouldn't rewrite your real memory). New memories it writes land in the
  container's own config volume and vanish on exit. Flip the `:ro` mounts to
  `:rw` in `sandbox.sh` if you want writes to persist.
- To run with the firewall OFF (open network) for debugging, pass
  `-e SANDBOX_FIREWALL=0` — but then you've lost the network isolation.
- **SSH key exposure**: `~/.ssh` is mounted read-only so `git push` works, which
  means a `--dangerously-skip-permissions` Claude *can read your private key*.
  The firewall limits where it could exfiltrate to (only the allowlist, on the
  allowed ports), but if that tradeoff bothers you, switch to a dedicated
  sandbox-only key: generate one, add its `.pub` to GitHub, and mount only that
  keypair instead of all of `~/.ssh`. Then a leak costs you one revocable key,
  not your primary identity.
- `sandbox.sh` always allowlists `ssh.github.com`/`github.com` for git push.
  If your `~/.ssh/config` routes github through a corporate proxy, set the proxy
  host and its port **once** in a local `.env` (copy `.env.example`,
  it's gitignored) so every run picks them up automatically:
  ```sh
  : "${GIT_SSH_DOMAINS:=proxy.example.com ssh.github.com github.com}"
  : "${ALLOWED_PORTS:=443 80 22 912}"
  ```
  Default ports are 443/80/22. Anything you pass on the command line
  (`ALLOWED_PORTS="..." sandbox-claude`) overrides the file.
