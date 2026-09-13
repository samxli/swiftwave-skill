---
name: swiftwave
description: Use when managing SwiftWave v2 via CLI or API, co-located or remote. Triggers on swiftwave CLI, swiftwave GraphQL, REST auth, upload code, persistent volumes, ingress, stack deploy, task queue, TLS, service, postgres, localregistry, remote server, SW_HOST, SW_TOKEN, deployment logs, runtime logs.
---

# SwiftWave (CLI + API, co-located or remote)

Operate a SwiftWave v2 PaaS instance either from the same server it runs
on (CLI-first) or from a different machine (API-only). API covers
everything the CLI does not (apps, ingress, volumes, deployments). No
dashboard/UI operations.

## Mode selection

- **Co-located** (default): `swiftwave` binary at `/usr/bin/swiftwave`,
  API on `127.0.0.1:3333`. Full CLI available.
- **Remote**: `export SW_HOST=<server-ip>` before anything else — scripts
  auto-detect scheme/port and set `SW_REMOTE=1`. **API-only**: no
  `swiftwave` CLI, no `/var/lib/swiftwave/config.yml`. Auth needs an
  account on the target server (`SW_USER`/`SW_PASS` → `sw-login.sh`);
  any account works (see RBAC warning below).
- **Config file instead of exports**: keep credentials in an env file —
  `./.env.swiftwave` (project), `~/.config/swiftwave/env` (user), or the
  skill dir's own `.env.swiftwave` (last-resort fallback), or point
  `SW_ENV_FILE` at any path. Template: `env.example`. Only `SW_*`
  keys are read; the real environment always wins over the file.
  `chmod 600` it (scripts warn on loose perms). YAML is deliberately
  not supported (would add a PyYAML dependency).
- Remote transport: prefer `SW_SCHEME=https` (self-signed cert,
  `SW_INSECURE=1` handles it) or an SSH tunnel
  (`ssh -L 3333:127.0.0.1:3333 user@server` + default `SW_HOST`).
  `sw-env.sh` warns loudly on remote+http — credentials and the JWT
  cross the network in cleartext.
- No RBAC exists in v2: every authenticated user is effectively admin
  and `deleteUser` can remove ANY user including the first admin (no
  guard, no confirmation). Treat credentials as full-power secrets;
  never "test" destructive mutations; keep a recovery path (server-root
  `swiftwave user create`) for lockout.

## Scope and assumptions

- Version pin: `v2` branch, latest known `2.23.1-1`. Co-located,
  `swiftwave [cmd] --help` wins over `swiftwave.org/docs/2.1.x`.
- Auth: `POST /auth/login` → JWT → `Authorization: Bearer <token>` for
  GraphQL, REST, and websocket subscriptions. Prefer `SW_TOKEN` env over
  CLI args (avoids leaking the JWT via the process list). Never print
  tokens, passwords, or full config.
- Destructive commands need explicit user confirmation:
  `init --overwrite`, `service disable`, `tq purge`, `user delete`,
  `deleteUser`, `restartSystem`, volume restore, app/stack destroy.

## Fast paths

### 1. CLI ops — CO-LOCATED ONLY

```bash
swiftwave --help
swiftwave service status
swiftwave postgres status
swiftwave localregistry status
swiftwave tq ls
swiftwave user create -u <name> [-p <pass>]
```

Full table: `references/cli-reference.md`.

### 2. Remote equivalents (GraphQL/API)

| Co-located CLI / local op | Remote replacement |
|---|---|
| `swiftwave user create/delete` | `createUser(input:{username,password})` / `deleteUser(id)` |
| `users` list, `currentUser` | same queries (plain GraphQL) |
| `swiftwave service status` | `servers { hostname status swarmNodeStatus proxyEnabled }` |
| `swiftwave service restart` | `mutation { restartSystem }` (systemctl restart after 2s — confirm first) |
| `deployment_logs` DB table | `scripts/sw-logs.sh deployment <dep-id>` |
| `docker logs` | `scripts/sw-logs.sh runtime <app-id> [timeframe]` |
| `docker exec` health checks | `sw-logs.sh runtime` + HTTP `/health` through ingress |
| `sw-doctor.sh` config-derived registry URL | `SW_REGISTRY_ADDR` override (default `<SW_HOST>:3334`) |
| `tq`, `tls`, `db-migrate`, `snapshot`, `auto-update`, `postgres`/`localregistry` control, config edits | **no API** — server operator / co-located CLI only |

### 3. API auth (needed for GraphQL + REST)

```bash
export SW_USER=admin SW_PASS='...'
export SW_TOKEN=$(./scripts/sw-login.sh)
```

Remote: same, plus `SW_HOST`. Self-signed https needs nothing extra
(`SW_INSECURE=1` is default); use an SSH tunnel if the operator keeps
`use_tls: false`.

### 4. GraphQL (apps, ingress, volumes, deployments)

```bash
./scripts/sw-graphql.sh '{ applications(includeGroupedApplications: true) { id name } }'
./scripts/sw-graphql.sh "$(cat query.graphql)" '{"id":"..."}'
```

Schema source is the versioned `*.graphqls` files (live introspection
is disabled on stock v2). Details: `references/graphql.md`.
REST-only exceptions (upload code, volume backup/restore): `references/rest-api.md`.

### 5. Deploy via API

- Which path? **Remote without operator-shared registry creds → use
  the sourceCode path** (zero extra prereqs; in-cluster builder handles
  plain Dockerfiles). The prebuilt-image path additionally requires a
  local docker daemon with `insecure-registries` configured + restarted
  and registry creds the API never exposes — only worth it when the
  builder's failure logs prove insufficient.
- Ingress requires the proxy: `enableProxyOnServer` on at least one
  online server first, otherwise port 80/443 never listens.
- One-shot source deploy (upload → dockerfile → create → wait):
  `scripts/sw-create-app.sh <name> <dir> [-e KEY=VALUE]... [--no-wait]`.
  Required `ApplicationInput` fields are documented in
  `references/application-input.md` (several are required-but-unguessable:
  `preferredServerHostnames`, full `dockerProxyConfig.permission`,
  full `customHealthCheck`, `hostname` = `name`).
- Prebuilt image via local registry: build + push, store
  creds with `createImageRegistryCredential`, then `createApplication`
  with `upstreamType: image`. This skips the in-cluster builder, whose
  failure logs are terse (`sw-logs.sh deployment` only shows
  "failed to build").
  - Co-located: push to `127.0.0.1:3334` (creds in local config).
  - Remote: push to `<SW_HOST>:3334` using the registry
    username/password the server operator shares from
    `local_image_registry` in `config.yml` (not exposed via API). The
    agent's docker daemon needs `{ "insecure-registries":
    ["<SW_HOST>:3334"] }` (self-signed cert) and a daemon restart —
    plan for it before the first push. Verify reachability with
    `sw-doctor.sh` (registry probe) first.
- Source-code path: upload with `scripts/sw-upload-code.sh <dir>`
  (archives directory CONTENTS so the Dockerfile lands at tar root,
  forces `Content-Type: application/x-tar`), then `createApplication`
  with `upstreamType: sourceCode` — or the one-shot
  `scripts/sw-create-app.sh` above, which does both plus the
  `dockerConfigGenerator` round trip and the wait.
- Volume names allow alphabets/numbers/underscore only (no hyphens).
- Wait with `scripts/sw-wait-deployment.sh <app-id> <timeout> <dep-id>`
  using the deployment id from the create/update/rebuild mutation response
  (the `latestDeployment` pointer flips asynchronously — see below); on
  failure read logs with `scripts/sw-logs.sh deployment <dep-id>` (works
  remote; replaces the old DB-table read).
- Domains: `addDomain` → `createIngressRule` (http 80 / https 443 →
  container `targetPort`) → `issueSSL` (needs public DNS pointing here)
  → optional `enableHttpsRedirectIngressRule` (requires deleting the
  plain port-80 rule on the same domain first).
- Stack: docker-stack subset only — see `references/stack-spec.md`.
  Expose via ingress rules, not `ports`.
- Multi-app (e.g. app + database): deploy the database as an image app
  first, reach it from other apps at `<app-name>:<port>` over swarm DNS —
  see `references/multi-app.md`.

## Scripts

All in `scripts/`, env-only config (`SW_HOST` default `127.0.0.1` — set
to the server IP to go remote, `SW_PORT` default `3333`, `SW_SCHEME`
auto-detected unless set, `SW_INSECURE=1` default for self-signed cert,
`SW_USER`/`SW_PASS` for login, `SW_TOKEN` for auth). Requires `curl` +
`python3` + `bash` (macOS/BSD compatible, no GNU-only flags, no jq, no
pip packages). Source `sw-env.sh` for defaults (`sw-env.sh` itself is
also sourceable from `zsh`):

- `sw-env.sh` — shared env, dep check, scheme probe, remote detection
  (`SW_REMOTE=1`), cleartext warning, base URL derivation; also loads
  `SW_*` from an env file (`SW_ENV_FILE` > `./.env.swiftwave` >
  `~/.config/swiftwave/env` > skill-dir `.env.swiftwave`; shell env wins)
- `sw-login.sh` — JWT login, token on stdout only
- `sw-graphql.sh [<token>] <query> [vars-json]` — authed GraphQL POST
- `sw-create-app.sh [<token>] <name> <dir|tar> [-e KEY=VALUE]... [--no-wait] [timeout]` — one-shot source deploy (upload → dockerfile → create → wait)
- `sw-logs.sh [<token>] deployment <dep-id> [timeout]` — replay + tail
  deployment logs via websocket subscription
- `sw-logs.sh [<token>] runtime <app-id> [timeframe] [idle-timeout]` —
  container logs (`live|last_1_hour|…|lifetime`); tails forever, so it
  ends on idle-timeout (default 30s) or Ctrl+C
- `sw-upload-code.sh [<token>] <dir|tar>` — tar (root-level Dockerfile) + upload
- `sw-wait-deployment.sh [<token>] <app-id> [timeout] [expected-dep-id]` — poll to terminal state (pass the id from the mutation response)
- `sw-doctor.sh` — read-only health check: API reachability, registry
  URL validation (the instant-build-failure cause; remote mode probes
  `SW_REGISTRY_ADDR` directly), `servers` status when `SW_TOKEN` set
- `sw-introspect.sh [<token>] [out.json]` — live schema snapshot; exits 2
  with repo pointer when the server has introspection disabled (normal on v2)

## Lifecycle and ordering (learned the hard way)

- Mutations are async: after create/update, `latestDeployment` still points
  at the previous deployment until the worker flips it. Always wait with an
  explicit expected deployment id; never trust the first `deployed` read.
- `realtimeInfo` (replicas/health) lags the real state — confirm with
  container/HTTP checks (`sw-logs.sh runtime`, `/health`, or `docker exec`
  when co-located) instead.
- Deleting an app with active ingress rules is rejected — delete its
  ingress rules first (rule deletion is also async; retry the app delete
  after they disappear from `ingressRules`).
- Deleting an app removes service + deployments + bindings only. Volumes,
  domains (and their SSL state), and credentials survive. Deleting a volume
  destroys its data permanently — same confirmation bar as other
  destructive ops. There is no delete-deployment API (only
  `cancelDeployment` for in-flight ones); superseded deployments are inert
  history.
- `rebuildApplication(id)` redeploys the current config as a new deployment
  (no config change needed); `updateApplication` is for config changes.
- Users are NOT role-separated: `deleteUser` succeeds against any id —
  including the first admin — from any account. Deleting all users
  locks everyone out until server-root `swiftwave user create`.

## Troubleshooting order

1. Co-located: `swiftwave service status` → `restart` if down.
   Remote: `servers { status }` → `restartSystem` (confirm) if offline.
2. Co-located: `swiftwave postgres status` / `localregistry status`.
   Remote: registry probe via `sw-doctor.sh`.
3. Co-located: `swiftwave tq ls` → `tq inspect <queue>` (never `purge`
   unconfirmed). Remote: not available — ask the operator.
4. Co-located: `swiftwave tls generate|renew` — daemon endpoints only,
   not app domains.
5. Co-located: `swiftwave db-migrate`, `snapshot`, `auto-update
   enable|disable` — CLI-only, no remote equivalent.
6. API failures: re-login (expired JWT); if connection fails, check
   `use_tls`/port on the server and firewall on 3333 (scripts
   auto-detect, but explicit `SW_SCHEME` overrides).
7. App stays 0 replicas / deployment `failed`: run `scripts/sw-doctor.sh`
   first. Instant failure with no build-output lines in
   `sw-logs.sh deployment <id>` means the derived registry URL is broken
   (e.g. tunnelling enabled with empty node address/port → tag
   `":0/..."` rejected as invalid reference), not a bad Dockerfile — see
   `references/config-reference.md`. Remote push failures usually mean
   the agent's docker lacks the `<SW_HOST>:3334` insecure-registries
   entry, or port 3334 is firewalled.

## References

- `references/cli-reference.md` — every CLI command + flags (co-located only)
- `references/rest-api.md` — vendored v2 REST docs
- `references/graphql.md` — endpoint, auth, schema source (introspection
  disabled), user/server/system/log queries + log subscriptions
- `references/application-input.md` — working `createApplication` input
  for sourceCode deploys (required-but-unguessable fields, 422 sample,
  `dockerConfigGenerator` round trip)
- `references/config-reference.md` — local paths/ports, redacted (co-located only)
- `references/stack-spec.md` — supported compose subset
- `references/multi-app.md` — app + managed-database pattern
