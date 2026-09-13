# CLI reference (SwiftWave v2, local binary)

CO-LOCATED ONLY — the `swiftwave` binary needs local systemd, postgres,
and config access. From a remote machine use the GraphQL equivalents in
`SKILL.md` § "Remote equivalents" (users, servers status, restartSystem)
plus `scripts/sw-logs.sh`; `tq`/`tls`/`db-migrate`/`snapshot`/
`auto-update`/`postgres`/`localregistry` have no API at all.

Source of truth: `swiftwave [cmd] --help` on this host.
Binary: `/usr/bin/swiftwave`. No `--version` flag.

## Top level

`swiftwave [flags|command]` — `-h/--help` only global flag.

| Command | Purpose |
|---|---|
| `init [--domain --auto-domain --remote-postgres --overwrite]` | Initialize server config. `--overwrite` is destructive — confirm first |
| `config [-e editor]` | Open config file in editor |
| `db-migrate` | Migrate local database |
| `tls` | Daemon TLS only (not app domains) |
| `user` | Manage users |
| `start` | Start Swiftwave |
| `service` | Daemon service |
| `postgres` | Local postgres (port 3335) |
| `localregistry` | Local image registry (port 3334) |
| `tq` | Task queue inspection |
| `auto-update` | Auto-update every 15 min |
| `snapshot` | System snapshot |
| `completion [bash|zsh|fish|powershell]` | Shell completions |

## Subcommands

- `user create -u <name> [-p <pass>]` | `user delete` (confirm) | `user disable-totp -u <name>`
- `service enable|disable` (disable = confirm) `|restart|status`
- `postgres start|stop|status`, `localregistry start|stop|status|restart`
- `tls enable|disable|generate|renew` — generate/renew are daemon endpoint certs only
- `tq ls` | `tq inspect <queue>` | `tq purge <all|queue>` (confirm — deletes queued jobs)
- `auto-update enable|disable`

## Notes

- Even `--help` may print `Local postgres ... running` / `Database migrated` lines; harmless.
- `tls generate` text states: not for hosted application domains.
- `tls generate` mints a Let's Encrypt cert for the management address via
  http-01 on port 80 — it FAILS while the ingress proxy occupies port 80
  (its pre-check gets HAProxy's 502 instead of the challenge server).
  If a valid cert already exists in the cert dir, `tls enable` alone is
  enough (it flips `use_tls` + restarts). For a fresh issuance with the
  proxy on, briefly disable the proxy, generate, re-enable. Watch the
  auto-renewal the same way.
- Prefer CLI for daemon/server state; use GraphQL/REST for apps, ingress, volumes.
