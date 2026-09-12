# Local config reference (co-located, redacted)

## Paths

- Daemon config: `/var/lib/swiftwave/config.yml` (root-only, contains secrets)
- Proxy state: `/etc/swiftwave/haproxy/`, `/etc/swiftwave/udpproxy/`
- Data: `/var/lib/swiftwave/{cert,haproxy,postgres,pvbackup,pvrestore,registry,tarball,udpproxy}`
- Binary: `/usr/bin/swiftwave`

## Ports (defaults)

- Service/API: `3333` (`bind_address 0.0.0.0`; `use_tls` is configurable —
  toggled by `swiftwave tls enable|disable`, scripts auto-detect the scheme)
- Local registry: `3334`
- Local postgres: `127.0.0.1:3335`

## Config keys (structure only — never output values)

`dev_mode`, `service.{use_tls,management_node_address,auto_renew_management_node_cert,bind_address,bind_port,ssh_timeout}`,
`postgresql.{host,port,user,password,database,time_zone,ssl_mode,run_local_postgres}`,
`local_image_registry.{port,username,password,image}`,
`environment_variables.{SSH_AUTH_SOCK,SSH_KNOWN_HOSTS}`,
`management_node_tunnelling.{enabled,...}`.

## Rules

- Read-only inspection preferred; edit only via `swiftwave config` or `init` with backup.
- Never print `password`, `token`, or full file contents. Redact in any output.
- `tls generate|renew` affects daemon endpoints, not hosted app domains.

## Registry URL derivation (build-breaker — read carefully)

The in-cluster builder tags git/sourceCode images as
`<registry-prefix>/<appID>:<depID>`, where the prefix comes from
`GetRegistryURL()`:

- tunnelling **enabled** → `management_node_tunnelling.local_image_registry_node_address:port`
- tunnelling **disabled** → `service.management_node_address` + `local_image_registry.port`

If tunnelling is enabled but the node address is `""` / port `0`, the
prefix becomes `":0"` — an invalid reference. The daemon rejects
`ImageBuild` instantly, so the deployment fails with exactly three
`deployment_logs` rows at the same millisecond and **zero build-output
lines** ("Started building docker image" → "Failed to build docker
image" → "Failed to build application"). The Dockerfile and tarball are
irrelevant in that case — check this FIRST (see `scripts/sw-doctor.sh`).
For single-node hosts a loopback prefix (`127.0.0.1:3334`) is proven to
work for build tag + push + swarm pull.
