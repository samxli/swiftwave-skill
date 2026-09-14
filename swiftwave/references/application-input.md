# createApplication input (sourceCode path)

Minimal mutation that succeeds on 2.23.x:

```graphql
mutation CreateApp($input: ApplicationInput!) {
  createApplication(input: $input) { id name latestDeployment { id status } }
}
```

```json
{"input": {
  "name": "example-app",
  "hostname": "example-app",
  "environmentVariables": [{"key": "K", "value": "V"}],
  "persistentVolumeBindings": [],
  "configMounts": [],
  "capabilities": [],
  "sysctls": [],
  "dockerfile": "<Dockerfile text from dockerConfigGenerator>",
  "buildArgs": [],
  "deploymentMode": "replicated",
  "replicas": 1,
  "resourceLimit": {"memoryMb": 512},
  "reservedResource": {"memoryMb": 128},
  "upstreamType": "sourceCode",
  "command": "",
  "sourceCodeCompressedFileName": "<uuid>.tar",
  "preferredServerHostnames": [],
  "dockerProxyConfig": {"enabled": false, "permission": {
    "ping": "none", "version": "none", "info": "none", "events": "none",
    "auth": "none", "secrets": "none", "build": "none", "commit": "none",
    "configs": "none", "containers": "none", "distribution": "none",
    "exec": "none", "grpc": "none", "images": "none", "networks": "none",
    "nodes": "none", "plugins": "none", "services": "none",
    "session": "none", "swarm": "none", "system": "none", "tasks": "none",
    "volumes": "none"}},
  "customHealthCheck": {"enabled": false, "test_command": "",
    "interval_seconds": 30, "timeout_seconds": 10, "start_period_seconds": 10,
    "start_interval_seconds": 5, "retries": 3}
}}
```

## Required-field gotchas

Missing any of these returns HTTP 422, e.g.
`{"errors":[{"message":"must be defined","path":["variable","input",
"preferredServerHostnames"],"extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}]}`:

- `preferredServerHostnames: []` — required, no default.
- `dockerProxyConfig.permission` — all 23 keys required even when
  `enabled: false` (use `"none"` for each).
- `customHealthCheck` — all 7 fields required even when `enabled: false`.
- `hostname` — required; keep equal to `name` (swarm DNS name, other apps
  reach it at `<name>:<port>`).
- Also pass `buildArgs: []`, `command: ""`, `configMounts: []`,
  `persistentVolumeBindings: []` (empty, not null).

## dockerConfigGenerator round trip (source deploys)

1. Upload tar → `{"file": "<uuid>.tar"}` (`sw-upload-code.sh`).
2. Query the Dockerfile text back:
   ```graphql
   query ($in: DockerConfigGeneratorInput!) {
     dockerConfigGenerator(input: $in) { dockerFile }
   }
   ```
   with `{"in": {"sourceType": "sourceCode",
   "sourceCodeCompressedFileName": "<uuid>.tar"}}`.
3. Echo that text into `input.dockerfile` in the mutation above
   (build via JSON, never string interpolation — the Dockerfile holds
   quotes/newlines).

Defaults observed on this server: `replicated` / 1 replica /
512 MB limit / 128 MB reserved.

## Redeploy: updateApplication round trip

For new code on an EXISTING app, `updateApplication(id, input)` takes the
same `ApplicationInput` — re-fetch the live config and resubmit it, swapping
only the code fields. Unlike create, this input REPLACES the whole config,
so never feed create-time defaults (they would reset replicas/resources/
volumes). All config fields round-trip from the `Application` type, but
`dockerfile` and `sourceCodeCompressedFileName` exist on the input only:
re-upload + `dockerConfigGenerator` again (steps above).
`scripts/sw-redeploy-app.sh` does all of this; `rebuildApplication(id)`
reuses the stored code (git re-clone only) — use it when the code did not
change.
