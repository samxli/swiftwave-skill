# Schema cheatsheet (v2 branch, verified against upstream + live 2.23.x)

Live introspection is disabled — this file exists so queries can be
written with zero 422 round trips. Field lists below are the full
queryable fields per type (traps marked ⚠️).

## ID types

App and deployment ids are `String!`; volume, domain, ingress-rule,
server, and credential ids are `Uint!` (numbers, not quoted).

## Application ⚠️

`upstreamType`, `dockerfile`, `sourceCodeCompressedFileName`,
`dockerImage` exist on `ApplicationInput` (and `upstreamType` on
`Deployment`) — NOT on `Application`. Querying them on the type 422s.
⚠️ `ConfigMountInput.content` is `String!` — round-tripping config
mounts must query `content` (secret-bearing; don't print it).

```
id name hostname command deploymentMode replicas
environmentVariables { key value }
persistentVolumeBindings { persistentVolumeID mountingPath }
configMounts { content mountingPath uid gid } capabilities sysctls
resourceLimit { memoryMb } reservedResource { memoryMb }
realtimeInfo { InfoFound DesiredReplicas RunningReplicas DeploymentMode HealthStatus }
latestDeployment { id status } deployments { id status }
ingressRules { id protocol port targetPort status domain { name } }
preferredServerHostnames dockerProxyHost
dockerProxyConfig { enabled ... } customHealthCheck { enabled ... }
replicas webhookToken isDeleted isSleeping applicationGroupID
```

## Deployment

```
id applicationID upstreamType status createdAt
dockerfile buildArgs { key value } dockerImage sourceCodeCompressedFileName
commitHash commitMessage repositoryBranch repositoryUrl
```

`status`: `pending|deployPending|deploying` →
`deployed` (terminal failures: `failed|stalled|stopped|cancelled`).

## PersistentVolumeBinding ⚠️

```
id persistentVolumeID mountingPath
persistentVolume { id name } applicationID application { id name }
```

Trap: `persistentVolumeID` / `mountingPath` — NOT
`volumeId`/`mountPath`/`volume`. Input takes only
`{ persistentVolumeID, mountingPath }`.

## PersistentVolume

```
id name type nfsConfig { host path version } cifsConfig { host ... }
persistentVolumeBindings { applicationID mountingPath }
```

### Creating a `local` volume ⚠️

`nfsConfig` AND `cifsConfig` are required even for `type: local`
(all sub-fields `!`-required: `nfsConfig.version` is `Int!`, so `""`
422s; `file_mode`/`dir_mode` are `String!`). Verified-live mutation:

```graphql
mutation {
  createPersistentVolume(input: {
    name: "guestbookdb_data", type: local,
    nfsConfig: {host: "", path: "", version: 4},
    cifsConfig: {host: "", share: "", username: "", password: "",
                 file_mode: "0777", dir_mode: "0777", uid: 0, gid: 0}
  }) { id name }
}
```

## ImageRegistryCredential ⚠️

```
id url username deployments { id status }
```

Trap: NO `name` field. (`password` exists on the type — don't query
it; secrets stay out of logs.)

## IngressRule

```
id targetType domainId domain { name } protocol port
applicationId application { name } externalService targetPort
httpsRedirect authenticationType status createdAt updatedAt
```

`status`: `pending|applied|deleting|failed` — create/delete are async,
poll until `applied`/gone (see async notes in `graphql.md`).

Trap: `IngressRuleInput` requires BOTH `applicationId: String!` and
`externalService: String!` whatever the `targetType` — pass `""` for
the unused one or the mutation 422s.

## Domain

```
id name sslStatus sslIssuedAt sslIssuer sslAutoRenew
ingressRules { id } redirectRules { id }
```

`sslStatus`: `none|pending|issued|failed` — `issueSSL` is async, poll
to terminal; DNS must point at the server first.

## Server

```
id ip hostname user ssh_port swarmMode swarmNodeStatus
scheduleDeployments maintenanceMode proxyEnabled proxyType status
```

## Example queries (all verified live)

```graphql
# apps with their ingress wiring
{ applications(includeGroupedApplications: true) {
  id name hostname latestDeployment { id status }
  ingressRules { id protocol port targetPort status domain { name } } } }

# volumes and what binds them
{ persistentVolumes { id name type
  persistentVolumeBindings { applicationID mountingPath } } }

# registry credentials (no secrets)
{ imageRegistryCredentials { id url username } }

# domains with rule counts
{ domains { id name sslStatus
  ingressRules { id } redirectRules { id } } }
```

## Schema sources (pinned, one per file)

Base: `https://raw.githubusercontent.com/swiftwave-org/swiftwave/v2/swiftwave_service/graphql/schema/`

```
app_authentication.graphqls  application.graphqls
application_group.graphqls   application_healthcheck.graphqls
base.graphqls                build_arg.graphqls
cifs_config.graphqls         config_mount.graphqls
deployment.graphqls          deployment_log.graphqls
docker_config_generator.graphqls  docker_proxy_config.graphqls
domain.graphqls              environment_variable.graphqls
git.graphqls                 git_credential.graphqls
image_registry_credential.graphqls  ingress_rule.graphqls
nfs_config.graphqls          persistent_volume.graphqls
persistent_volume_backup.graphqls
persistent_volume_binding.graphqls
persistent_volume_restore.graphqls  redirect_rule.graphqls
runtime_log.graphqls         server.graphqls
server_log.graphqls          stack.graphqls
system.graphqls              system_log.graphqls
totp.graphqls                user.graphqls.graphqls
```

Notes: the user file really has a doubled extension
(`user.graphqls.graphqls`); there is NO
`persistent_volume_nfs_cifs.graphqls` — NFS/CIFS live in
`nfs_config.graphqls` + `cifs_config.graphqls`. `createApplication`
input details: `references/application-input.md`.
