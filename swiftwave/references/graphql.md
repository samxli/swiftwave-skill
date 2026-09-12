# GraphQL (primary API)

Source: `swiftwave-org/swiftwave@v2:docs/api_docs.md` points to
`https://graphql.docs.swiftwave.org/` (JS app, not vendored).

## Endpoint

- URL: `$SW_SCHEME://$SW_HOST:$SW_PORT/graphql` — co-located default
  `http(s)://127.0.0.1:3333/graphql`. `scripts/sw-env.sh` auto-detects
  the scheme: the daemon serves **https only when `use_tls: true`** in
  `/var/lib/swiftwave/config.yml`, otherwise plain http. Set `SW_SCHEME`
  explicitly to skip probing. Self-signed certs need `curl -k`
  (`SW_INSECURE=1`, the default).
- Header: `Authorization: Bearer <jwt>` from `POST /auth/login`
- POST JSON: `{ "query": "...", "variables": {...} }` via `scripts/sw-graphql.sh`
  (token via first arg or `SW_TOKEN` env — env preferred).

## Schema: introspection is DISABLED on stock v2

`{ __schema ... }` returns `{"errors":[{"message":"introspection disabled"}]}`.
`scripts/sw-introspect.sh` detects this and exits 2. Use the versioned
schema as source of truth instead:

- `https://github.com/swiftwave-org/swiftwave/tree/v2/swiftwave_service/graphql/schema`
- Key files: `application.graphqls` (`ApplicationInput`, `createApplication`,
  `updateApplication`), `domain.graphqls`, `ingress_rule.graphqls`,
  `persistent_volume*.graphqls`, `deployment.graphqls`,
  `docker_config_generator.graphqls`, `image_registry_credential.graphqls`.

Only re-check live introspection after an upgrade in case it gets enabled;
do not rely on it.

## Conventions

- Apps, ingress rules, domains, redirect rules, persistent volumes,
  environment variables, deployments, git/image credentials, servers,
  users: all via GraphQL queries/mutations (see schema files above).
- File upload and volume backup download/restore stay on REST.
- On `401/UNAUTHENTICATED`: re-login (JWT expiry), then retry once.
- Deploy status: poll `application { latestDeployment { status } }`
  via `scripts/sw-wait-deployment.sh` (`pending/deployPending/deploying`
  → `deployed`, terminal failures: `failed/stalled/stopped/cancelled`).
