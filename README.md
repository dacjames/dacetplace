# dacetplace

dacjames' Claude Code plugin marketplace.

## Install

```
/plugin marketplace add dacjames/dacetplace
/plugin install dacbots@dacetplace
```

## Plugins

### dacbots

Secure dev-tool permission setup and project scaffolding skills.

| Skill | Description |
|-------|-------------|
| `dev-permissions` | Writes curated auto-approval rules to `.claude/settings.local.json` (allow/ask/deny) and fs-navigation rules to `CLAUDE.md`. Detects toolchain or takes ruleset args (`go`, `node`, `python`, `rust`). |
| `dev-tasks` | Scaffolds a convention-compliant go-task `Taskfile.yml`: idempotent, `:`-nested, quiet-by-default, `CLI_ARGS` passthrough, local temp dir, `ask:`/`deny:`-prefixed tasks gated by permission rules. Detects toolchain or takes args (`go`, `tf`, `py`, `node`). |
