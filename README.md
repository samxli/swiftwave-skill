# swiftwave-skill

Teach your AI coding agent to run a **SwiftWave v2** PaaS for you — deploy
apps, wire up domains and TLS, manage volumes and logs — safely, from the
terminal. No dashboard clicking.

It works in two modes:

| Mode | Agent runs on... | How it talks to SwiftWave |
|---|---|---|
| **Co-located** | the same server as SwiftWave | `swiftwave` CLI + local API (`127.0.0.1:3333`) |
| **Remote** | your laptop / CI / anywhere | the API over the network (`SW_HOST=<server-ip>`) |

Works with [opencode](https://opencode.ai), Claude Code, and any harness
that loads `SKILL.md`-style skills.

> New to SwiftWave? It's an open-source platform (like a self-hosted Heroku)
> that deploys apps from source code or Docker images onto Docker Swarm:
> [swiftwave.org](https://swiftwave.org).

---

## What your agent can do

Once the skill is installed, just ask in plain language:

- *"List my apps and show which are running"*
- *"Deploy this folder as an app and put it on app.example.com with HTTPS"*
- *"Show me the logs of the failed deployment"* (works remotely too)
- *"Create a postgres database app and connect my app to it"*
- *"Check the server's health and tell me why builds fail"*

## Requirements

Just two things on the machine where the agent runs:

- `bash`
- `curl` + `python3`

That's it — no extra packages, no pip installs. The `swiftwave` binary is
only needed in co-located mode.

## Quick start

### 1. Install the skill

The skill is the `swiftwave/` directory (the name must stay `swiftwave`).
Copy it into whichever harness you use:

```bash
# opencode: project skill
mkdir -p .opencode/skills
cp -r swiftwave .opencode/skills/

# opencode: global skill
mkdir -p ~/.config/opencode/skills
cp -r swiftwave ~/.config/opencode/skills/

# generic agents harness (other agents too)
mkdir -p ~/.agents/skills
cp -r swiftwave ~/.agents/skills/

# Claude Code
mkdir -p ~/.claude/skills
cp -r swiftwave ~/.claude/skills/
```

Or, for opencode, point config at this repo in `opencode.jsonc`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "skills": { "paths": ["/abs/path/to/swiftwave-skill"] }
}
```

Then restart the harness (skills load at startup).

### 2. Give it credentials

**Co-located** (agent on the SwiftWave server): nothing to configure —
scripts default to `127.0.0.1:3333` and auto-detect http/https.

**Remote** (agent somewhere else): point it at the server and log in with
any SwiftWave account the server admin creates for you.

The simplest way is a config file. Copy the template and fill it in:

```bash
cp swiftwave/env.example .env.swiftwave   # or ~/.config/swiftwave/env
chmod 600 .env.swiftwave                  # it holds secrets — keep it private
```

```bash
# .env.swiftwave
SW_HOST=your-server.example.com
SW_USER=myuser
SW_PASS='...'
```

Or just export the variables in your shell — shell env always beats the
file:

```bash
export SW_HOST=your-server.example.com
export SW_USER=myuser
export SW_PASS='...'
```

Prefer `https` (SwiftWave's `use_tls`) or an SSH tunnel — over plain
`http` your password travels unencrypted, and the skill will warn you.

> **Why not YAML?** The skill sticks to `.env`-style files on purpose:
> they need no extra packages (YAML parsing would require PyYAML), and
> every language the scripts use already understands them. Only `SW_*`
> keys are read, so pointing the skill at a bigger shared `.env` is safe.

### 3. Try it

Ask your agent, or run the scripts yourself:

```bash
source scripts/sw-env.sh
export SW_TOKEN="$(./scripts/sw-login.sh)"     # login, token stays in env
./scripts/sw-doctor.sh                          # health check
./scripts/sw-graphql.sh '{ applications { id name } }'
./scripts/sw-logs.sh deployment <deployment-id> # build/deploy logs
```

## The scripts

| Script | What it does |
|---|---|
| `sw-env.sh` | Shared config — source it first (host, port, scheme, remote detection). Loads `SW_*` from `.env.swiftwave` / `~/.config/swiftwave/env` / `$SW_ENV_FILE` |
| `sw-login.sh` | Log in, print JWT to stdout only |
| `sw-graphql.sh` | Run any GraphQL query/mutation |
| `sw-logs.sh` | Stream deployment or container logs (websocket, remote-friendly) |
| `sw-upload-code.sh` | Tar + upload a source folder with a Dockerfile |
| `sw-wait-deployment.sh` | Poll a deployment until it succeeds or fails |
| `sw-doctor.sh` | Read-only health check: API, image registry, server status |
| `sw-introspect.sh` | Check whether GraphQL introspection is enabled (normally off) |

All scripts read configuration from environment variables only —
`SW_HOST`, `SW_PORT`, `SW_SCHEME`, `SW_INSECURE`, `SW_USER`, `SW_PASS`,
`SW_TOKEN`. Nothing is hardcoded, nothing is written to disk.

## What works remotely (and what doesn't)

| Task | Co-located | Remote |
|---|---|---|
| Deploy apps, domains, TLS, volumes, ingress | ✅ API | ✅ API |
| Users (create/delete), server status, restart | ✅ | ✅ GraphQL |
| Deployment & runtime logs | ✅ | ✅ `sw-logs.sh` |
| Task queue, TLS daemon certs, db-migrate, snapshots, postgres/registry control | ✅ CLI | ❌ needs server access |

## Safety notes — please read

- **SwiftWave v2 has no role system.** Every account is effectively an
  admin: `deleteUser` can remove *any* user, including the first admin,
  with no confirmation. Treat credentials like root passwords, and keep
  server access as your recovery path.
- Destructive operations (app destroy, volume delete/restore, user
  delete, service restart, `init --overwrite`) always require your
  explicit confirmation — the skill instructs the agent to ask first.
- Never commit tokens, passwords, or the server's
  `/var/lib/swiftwave/config.yml` contents. Scripts never print secrets.

## Layout

```text
swiftwave/               <- the skill (name must stay `swiftwave`)
  SKILL.md               <- the instructions your agent reads
  scripts/               <- bash + curl + python3 helpers (see table above)
  references/            <- CLI, REST, GraphQL, config, stack, multi-app docs
```

## Harness compatibility

Kept portable on purpose — please preserve these when editing:

- Frontmatter uses `name` + `description` only (the common denominator
  across opencode, Claude Code, and `~/.agents` loaders). No
  harness-specific keys. `name` is lowercase, matches the folder,
  max 64 chars; keep `description` under ~1024 chars with trigger
  keywords up front.
- All `scripts/` and `references/` links in `SKILL.md` are relative —
  never absolute paths.
- Scripts are plain `bash` + `curl` + `python3`, no harness CLI calls.

## Version pin

Targets SwiftWave `v2` branch (latest known `2.23.1-1`, tested against a
live instance). Local `swiftwave --help` is source of truth;
`swiftwave.org/docs/2.1.x` is fallback. GraphQL introspection is disabled
on stock v2 — after upgrades, diff the versioned schema
(`swiftwave_service/graphql/schema/*.graphqls` in the repo) instead of
relying on a snapshot; `scripts/sw-introspect.sh` just tells you if
introspection got enabled.

## License

Apache-2.0 — see [LICENSE](LICENSE).
