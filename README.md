# swiftwave-skill

Agent skill for operating **SwiftWave v2** via **CLI + API**, co-located
on the same server SwiftWave runs on. No dashboard/UI coverage.
Works with opencode, Claude Code, and any harness that loads
`SKILL.md`-style skills (e.g. `~/.agents/skills`).

## Layout

```text
swiftwave/               <- the skill (name must stay `swiftwave`)
  SKILL.md
  scripts/               <- sw-env.sh, sw-login.sh, sw-graphql.sh, sw-upload-code.sh, sw-wait-deployment.sh, sw-introspect.sh, sw-doctor.sh
  references/            <- cli-reference.md, rest-api.md, graphql.md, config-reference.md, stack-spec.md, multi-app.md
```

## Install

The skill is the `swiftwave/` directory (it must keep that name — it
matches `name:` in `SKILL.md` frontmatter). Copy it into whichever
harness you use:

```bash
# opencode: project skill
mkdir -p .opencode/skills
cp -r swiftwave .opencode/skills/

# opencode: global skill
mkdir -p ~/.config/opencode/skills
cp -r swiftwave ~/.config/opencode/skills/

# generic agents harness (e.g. opencode external skills, other agents)
mkdir -p ~/.agents/skills
cp -r swiftwave ~/.agents/skills/

# Claude Code
mkdir -p ~/.claude/skills
cp -r swiftwave ~/.claude/skills/
```

Or, for opencode, point config at this repo in `opencode.jsonc`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "skills": { "paths": ["/abs/path/to/swiftwave-skill"] }
}
```

Then quit and restart the harness (skills are loaded at startup).

## Harness compatibility

Kept portable on purpose — please preserve these when editing:

- Frontmatter uses `name` + `description` only (the common denominator
  across opencode, Claude Code, and `~/.agents` loaders). No
  harness-specific keys. `name` is lowercase, matches the folder,
  max 64 chars; keep `description` under ~1024 chars with trigger
  keywords up front.
- All `scripts/` and `references/` links in `SKILL.md` are relative —
  never absolute paths.
- Scripts are plain `bash` + `curl` + `python3`, no harness CLI calls.

## Version pin

Targets SwiftWave `v2` branch (latest known `2.23.1-1`).
Local `swiftwave --help` is source of truth; `swiftwave.org/docs/2.1.x`
is fallback. GraphQL introspection is disabled on stock v2 — after
upgrades, diff the versioned schema
(`swiftwave_service/graphql/schema/*.graphqls` in the repo) instead of
relying on a snapshot; `scripts/sw-introspect.sh` just tells you if
introspection got enabled.

## Requirements

`curl` + `python3` on the agent host (`jq` optional — scripts use python
for JSON). All scripts default to co-located access
(`127.0.0.1:3333`, scheme auto-detected from daemon TLS state).

## Security

Scripts use env vars only (`SW_HOST`, `SW_USER`, `SW_PASS`).
Never commit tokens, passwords, or `/var/lib/swiftwave/config.yml` contents.
