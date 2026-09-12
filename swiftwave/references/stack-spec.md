# Stack / compose subset (v2)

Deploy Stack accepts a docker-stack-like file with a limited subset.

| Feature | Supported |
|---|---|
| services | Yes |
| image name | Yes |
| deploy mode | Yes |
| command | Yes |
| replicas | Yes |
| volumes | Yes |
| environment variables | Yes |
| cap_add | Yes |
| sysctls | Yes |
| ports | No — use ingress rules |
| networks | No |
| depends_on | No |
| healthcheck | No |

Tips: expose apps via ingress rules, not `ports`. Validate files for
unsupported keys before submitting via GraphQL; fail fast with a clear
message listing the offending keys.
