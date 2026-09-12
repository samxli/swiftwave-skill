# REST API (v2 branch, vendored summary)

Source: `swiftwave-org/swiftwave@v2:docs/rest_api.md`.
REST covers auth + a few file operations. Everything else is GraphQL.
Base: `http(s)://127.0.0.1:3333` — scheme depends on `use_tls` in the
local config; scripts auto-detect (`sw-env.sh`), use `curl -k` for the
self-signed cert when https.

## POST /auth/login

Form fields: `username`, `password`.

200:

```json
{ "token": "<jwt>" }
```

Use as `Authorization: Bearer <jwt>` for GraphQL + other REST calls.

## POST /upload/code

Form field: `file` (tar only). Returns:

```json
{ "file": "<id>.tar", "message": "file uploaded successfully" }
```

Use `scripts/sw-upload-code.sh <dir|tar>` (token via arg or `SW_TOKEN`).

## GET /persistent-volume/backup/<backup_id>/download

200 → file download. Other codes → failure.

## GET /persistent-volume/backup/:id/filename

200 → filename as text.

## POST /persistent-volume/:id/restore

Form field: `file` (tar.gz). 200:

```json
{ "message": "Restore job has been enqueued. ..." }
```

Confirm with user before restoring (overwrites volume data).
