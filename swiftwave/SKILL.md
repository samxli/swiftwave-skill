---
name: swiftwave
description: Use when managing SwiftWave v2 via CLI or API on the same host. Triggers on swiftwave CLI, swiftwave GraphQL, REST auth, upload code, persistent volumes, ingress, stack deploy, task queue, TLS, service, postgres, localregistry.
---

# SwiftWave (CLI + API, co-located)

Operate a SwiftWave v2 PaaS instance from the same server it runs on.
CLI-first. API for everything the CLI does not cover (apps, ingress,
volumes, deployments). No dashboard/UI operations.

## Scope and assumptions

- Co-located agent: `swiftwave` binary at `/usr/bin/swiftwave`, service on
  `127.0.0.1:3333` (https with self-signed cert when `use_tls: true`,
  else plain http — scripts auto-detect), registry `:3334`,
  local postgres `127.0.0.1:3335`. See `references/config-reference.md`.
- Version pin: `v2` branch, latest known `2.23.1-1`. Local
  `swiftwave [cmd] --help` wins over `swiftwave.org/docs/2.1.x`.
- Auth: `POST /auth/login` → JWT → `Authorization: Bearer <token>`
  for GraphQL and REST. Prefer `SW_TOKEN` env over CLI args (avoids
  leaking the JWT via the process list). Never print tokens, passwords,
  or full config.
- Destructive commands need explicit user confirmation:
  `init --overwrite`, `service disable`, `tq purge`, `user delete`,
  volume restore, app/stack destroy.

## Fast paths

### 1. CLI ops (prefer for daemon/server)

```bash
swiftwave --help
swiftwave service status
swiftwave postgres status
swiftwave localregistry status
swiftwave tq ls
swiftwave user create -u <name> [-p <pass>]
```

Full table: `references/cli-reference.md`.

### 2. API auth (needed for GraphQL + REST)

```bash
export SW_USER=admin SW_PASS='...'
export SW_TOKEN=$(./scripts/sw-login.sh)
```

### 3. GraphQL (apps, ingress, volumes, deployments)

```bash
./scripts/sw-graphql.sh '{ applications(includeGroupedApplications: true) { id name } }'
./scripts/sw-graphql.sh "$(cat query.graphql)" '{"id":"..."}'
```

Schema source is the versioned `*.graphqls` files (live introspection
is disabled on stock v2). Details: `references/graphql.md`.
REST-only exceptions (upload code, volume backup/restore): `references/rest-api.md`.

### 4. Deploy via API

- Ingress requires the proxy: `enableProxyOnServer` on at least one
  online server first, otherwise port 80/443 never listens.
- Recommended: **prebuilt image** via local registry. Build + push to
  `127.0.0.1:3334` (registry creds in local config), store them with
  `createImageRegistryCredential`, then `createApplication` with
  `upstreamType: image`. This skips the in-cluster builder, whose
  failure logs are terse (`deployment_logs` only says "failed to build").
- Source-code path: upload with `scripts/sw-upload-code.sh <dir>`
  (archives directory CONTENTS so the Dockerfile lands at tar root,
  forces `Content-Type: application/x-tar`), then `createApplication`
  with `upstreamType: sourceCode`.
- Volume names allow alphabets/numbers/underscore only (no hyphens).
- Wait with `scripts/sw-wait-deployment.sh <app-id> <timeout> <dep-id>`
  using the deployment id from the create/update/rebuild mutation response
  (the `latestDeployment` pointer flips asynchronously — see below); on
  failure read `deployment_logs` for that deployment id (DB table,
  `content` column).
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

All in `scripts/`, env-only config (`SW_HOST` default `127.0.0.1`,
`SW_PORT` default `3333`, `SW_SCHEME` auto-detected unless set,
`SW_INSECURE=1` default for self-signed cert, `SW_TOKEN` for auth).
Requires `curl` + `python3` (`jq` optional). Source `sw-env.sh` for defaults:

- `sw-env.sh` — shared env, dep check, scheme probe, base URL derivation
- `sw-login.sh` — JWT login, token on stdout only
- `sw-graphql.sh [<token>] <query> [vars-json]` — authed GraphQL POST
- `sw-upload-code.sh [<token>] <dir|tar>` — tar (root-level Dockerfile) + upload
- `sw-wait-deployment.sh [<token>] <app-id> [timeout] [expected-dep-id]` — poll to terminal state (pass the id from the mutation response)
- `sw-doctor.sh` — read-only health check: API reachability + derived
  registry-URL validation (the instant-build-failure cause)
- `sw-introspect.sh [<token>] [out.json]` — live schema snapshot; exits 2
  with repo pointer when the server has introspection disabled (normal on v2)

## Lifecycle and ordering (learned the hard way)

- Mutations are async: after create/update, `latestDeployment` still points
  at the previous deployment until the worker flips it. Always wait with an
  explicit expected deployment id; never trust the first `deployed` read.
- `realtimeInfo` (replicas/health) lags the real state — confirm with
  container/HTTP checks (`/health`, `docker exec`) instead.
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

## Troubleshooting order

1. `swiftwave service status` → `restart` if down
2. `swiftwave postgres status` / `localregistry status`
3. `swiftwave tq ls` → `tq inspect <queue>` (never `purge` unconfirmed)
4. `swiftwave tls generate|renew` — daemon endpoints only, not app domains
5. `swiftwave db-migrate`, `swiftwave snapshot`, `swiftwave auto-update enable|disable`
6. API failures: re-login (expired JWT); if connection fails, check
   `use_tls`/port in local config (scripts auto-detect, but explicit
   `SW_SCHEME` overrides)
7. App stays 0 replicas / deployment `failed`: run `scripts/sw-doctor.sh`
   first. Instant failure with no build-output lines in `deployment_logs`
   means the derived registry URL is broken (e.g. tunnelling enabled with
   empty node address/port → tag `":0/..."` rejected as invalid reference),
   not a bad Dockerfile — see `references/config-reference.md`

## References

- `references/cli-reference.md` — every CLI command + flags
- `references/rest-api.md` — vendored v2 REST docs
- `references/graphql.md` — endpoint, auth, schema source (introspection disabled)
- `references/config-reference.md` — local paths/ports (redacted)
- `references/stack-spec.md` — supported compose subset
- `references/multi-app.md` — app + managed-database pattern
