# dacetplace

dacjames' Claude Code plugin marketplace.

## Install

Add the marketplace, then install the plugin:

```
/plugin marketplace add dacjames/dacetplace
/plugin install dacbots@dacetplace
```

To hack on the plugins locally, add the marketplace by **path** instead of
`owner/repo` — that points Claude Code at your working tree, so local edits are
picked up without a push:

```
/plugin marketplace add /path/to/dacetplace
/plugin install dacbots@dacetplace
```

After editing a skill, refresh with `/plugin marketplace update dacetplace`.
Browse and manage everything with `/plugin`. Remove with
`/plugin marketplace remove dacetplace`.

## Usage

Each skill is `user-invocable`, so it shows up as a slash command once installed.
Run a skill with no args to auto-detect the repo's toolchain, or pass names to
force a ruleset.

```
/dev-permissions              # detect toolchain, write safe auto-approval rules
/dev-permissions go python    # force the go + python rulesets

/dev-tasks                    # detect toolchain, scaffold a Taskfile.yml
/dev-tasks go tf              # force the go + terraform namespaces

/dev-secrets                  # detect cloud backend + runner, wire secrets tasks
/dev-secrets gcp              # force the GCP Secret Manager backend
```

## Plugins

### dacbots

Secure dev-tool permission setup and project scaffolding skills.

| Skill | Description |
|-------|-------------|
| `dev-permissions` | Writes curated auto-approval rules to `.claude/settings.local.json` (allow/ask/deny) and fs-navigation rules to `CLAUDE.md`. Detects toolchain or takes ruleset args (`go`, `node`, `python`, `rust`). |
| `dev-tasks` | Scaffolds a convention-compliant go-task `Taskfile.yml`: idempotent, `:`-nested, quiet-by-default, `CLI_ARGS` passthrough, local temp dir, `:ask`/`:deny`-suffixed tasks gated by permission rules. Detects toolchain or takes args (`go`, `tf`, `py`, `node`). |
| `dev-secrets` | Wires `secrets:upload` / `secrets:download` tasks (GCP Secret Manager) into the repo's task runner — adapts the `:`-naming to go-task/make/npm/shell. Committed name-manifest, gitignored values. Optional GitHub Actions download step and `*.secret.tfvars` terraform support (per-env, gitignored, round-tripped). Detects backend/runner or takes args (`gcp`, `task`, `make`, `npm`, `shell`). |
