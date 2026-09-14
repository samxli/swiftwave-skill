# GraphQL (primary API)

Source: `swiftwave-org/swiftwave@v2:docs/api_docs.md` points to
`https://graphql.docs.swiftwave.org/` (JS app, not vendored).

## Endpoint

- URL: `$SW_SCHEME://$SW_HOST:$SW_PORT/graphql` — co-located default
  `http(s)://127.0.0.1:3333/graphql`; remote: `SW_HOST=<server-ip>`.
  `scripts/sw-env.sh` auto-detects the scheme: the daemon serves
  **https only when `use_tls: true`** in the server's
  `/var/lib/swiftwave/config.yml`, otherwise plain http. Set `SW_SCHEME`
  explicitly to skip probing. Self-signed certs need `curl -k`
  (`SW_INSECURE=1`, the default).
- Header: `Authorization: Bearer <jwt>` from `POST /auth/login`
- POST JSON: `{ "query": "...", "variables": {...} }` via `scripts/sw-graphql.sh`
  (token via first arg or `SW_TOKEN` env — env preferred).
- Websocket subscriptions use the SAME `/graphql` URL (HTTP Upgrade);
  the JWT goes in the `connection_init` payload (`Authorization` key),
  NOT in an HTTP header. `scripts/sw-logs.sh` implements this in pure
  python3 stdlib, speaking both `graphql-transport-ws` and legacy
  `graphql-ws` dialects.

## Schema: introspection is DISABLED on stock v2

`{ __schema ... }` returns `{"errors":[{"message":"introspection disabled"}]}`.
Might be enabled on a non-stock build — `scripts/sw-introspect.sh` is the
live check (exits 2 on stock). Either way the versioned schema files are
the source of truth:

- `https://github.com/swiftwave-org/swiftwave/tree/v2/swiftwave_service/graphql/schema`
- Key files: `application.graphqls` (`ApplicationInput`, `createApplication`,
  `updateApplication`), `domain.graphqls`, `ingress_rule.graphqls`,
  `persistent_volume*.graphqls`, `deployment.graphqls`,
  `docker_config_generator.graphqls`, `image_registry_credential.graphqls`.

Field-name traps that 422 on sight (`upstreamType` is input-only,
`persistentVolumeID`/`mountingPath` spelling, credential has no `name`,
volume creation needs dummy nfs/cifs configs) are tabulated in
`references/schema-cheatsheet.md` — check it before hand-writing a
query. Pinned raw URLs for all 32 schema files live there too.

Only re-check live introspection after an upgrade; do not build anything
that depends on it.

## Conventions

- Apps, ingress rules, domains, redirect rules, persistent volumes,
  environment variables, deployments, git/image credentials, servers,
  users: all via GraphQL queries/mutations (see schema files above).
- File upload and volume backup download/restore stay on REST.
- On `401/UNAUTHENTICATED`: re-login (JWT expiry), then retry once.
- Deploy status: poll `application { latestDeployment { status } }`
  via `scripts/sw-wait-deployment.sh` (`pending/deployPending/deploying`
  → `deployed`, terminal failures: `failed/stalled/stopped/cancelled`).
- Async mutations: `issueSSL` returns `sslStatus: pending` (poll `domain
  { sslStatus }` to `issued`; `none|pending|issued|failed`); `create`/
  `deleteIngressRule` move through `status: pending|deleting` (poll the
  rule or the parent `ingressRules` list until `applied`/gone).

## Users, servers, system (remote-management surface)

No RBAC in v2 — ANY authenticated user can run ALL of these, including
`deleteUser` on the first admin (no guard). Confirmed on 2.23.x: user
deletion succeeded without error and without confirmation.

```
# users (schema: user.graphqls.graphqls)
{ users { id username totpEnabled } }        { currentUser { id username } }
mutation { createUser(input: {username: "...", password: "..."}) { id } }
mutation { deleteUser(id: 5) }               # succeeds against ANY id
mutation { changePassword(input: {oldPassword: "...", newPassword: "..."}) }

# servers (schema: server.graphqls) — status is daemon-reported readiness
{ servers { hostname status swarmNodeStatus proxyEnabled } }
{ server(id: 1) { status logs { id title } } }   # co-located service-log index
{ fetchServerLogContent(id: 1) }                  # systemd-style log text
{ serverLatestResourceAnalytics(id: 1, ...) } / serverDiskUsage(id: 1)

# system (schema: system.graphqls)
mutation { restartSystem }   # systemctl restart swiftwave.service after 2s — confirm first
```

CLI ops with NO remote equivalent: `tq` (inspect/purge), `tls
generate|renew`, `db-migrate`, `snapshot`, `auto-update`, `postgres`
and `localregistry` start/stop, `swiftwave config` edits.

## Log subscriptions (schema: deployment_log / runtime_log.graphqls)

Both are subscription-only (no plain query) — use `scripts/sw-logs.sh`.

- `fetchDeploymentLog(id: String!)` — replays ALL rows of the
  deployment_logs table first, then live-tails via pubsub while the
  deployment is still `pending`/`deployPending`. Terminal deployments
  return history then the server completes the stream.
- `fetchRuntimeLog(applicationId: String!, timeframe: RuntimeLogTimeframe!)`
  — docker service logs with `Follow: true` ALWAYS; `timeframe` only
  sets the `since` offset (`live`=1min … `lifetime`=all). A quiet app
  produces silence, not a close — clients must end on idle-timeout.
- Auth quirk: the JWT rides in the `connection_init` payload
  (`{"Authorization": "<jwt>"}`); an invalid/expired token is answered
  by an immediate close before `connection_ack`.
