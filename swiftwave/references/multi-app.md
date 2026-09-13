# Multi-app pattern (app + database)

SwiftWave has no managed-databases feature — run the database as a plain
image app and connect over swarm DNS at `<app-name>:<port>`. Proven with
`postgres:17` + a Node app (see live `tododb` + `todo`).

## Database app

- `createApplication` with `upstreamType: image`, e.g. `dockerImage: postgres:17`.
- Env: `POSTGRES_USER`, `POSTGRES_PASSWORD` (alphanumeric-only generated
  secret — avoids URL-encoding bugs in connection strings),
  `POSTGRES_DB`.
- One persistent volume bound to the data dir (`/var/lib/postgresql/data`
  for postgres). The volume outlives the app; deleting it wipes the data.
- No ingress rule needed for internal-only access. No `dockerfile`
  (pass `""`), no build.
- Verify readiness: co-located via container
  (`docker exec $(docker ps -q -f name=<app>.1.) pg_isready -U <user>`);
  remote via `scripts/sw-logs.sh runtime <app-id>` (look for postgres'
  "ready to accept connections") — `realtimeInfo` itself lags.

## Consumer app

- Connection string via env, e.g.
  `DATABASE_URL=postgres://<user>:<pass>@<db-app-name>:5432/<db>`.
  URL-encode the password if it contains special chars.
- Boot must retry DB connect (database may start slower than the app —
  30 × 2s backoff works).
- `/health` should report DB reachability so swarm health reflects reality.

## Notes

- For pulls from the local registry (co-located `127.0.0.1:3334`, remote
  `<SW_HOST>:3334`), store an `ImageRegistryCredential` first and
  reference it; public Hub images need none.
- To rotate DB credentials: `updateApplication` on BOTH apps with the new
  env values (each update enqueues a redeploy that re-creates the
  container with the new env — a plain restart does not re-render env),
  then verify with a fresh connection.
