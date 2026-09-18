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

Some skills (`dev-tf`) ship bundled assets, and the plugin cache is keyed by
version (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/…` —
`0.1.0` and `0.2.0` coexist there today), so editing an asset requires bumping
`version` in `plugins/dacbots/.claude-plugin/plugin.json` before
`/plugin marketplace update dacetplace` serves the new copy.

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

/dev-codify                   # route an inline throwaway script to a durable home

/dev-tf                       # detect toolchain/backend/mode, install tf:* tasks
/dev-tf s3                    # force the s3 backend
/dev-tf update                # force the harmonize (update) path
```

## Plugins

### dacbots

Secure dev-tool permission setup and project scaffolding skills.

| Skill | Description |
|-------|-------------|
| `dev-permissions` | Writes curated auto-approval rules to `.claude/settings.local.json` (allow/ask/deny) and fs-navigation rules to `CLAUDE.md`. Detects toolchain or takes ruleset args (`go`, `node`, `python`, `rust`). |
| `dev-tasks` | Scaffolds a convention-compliant go-task `Taskfile.yml`: idempotent, `:`-nested, quiet-by-default, `CLI_ARGS` passthrough, local temp dir, `:ask`/`:deny`-suffixed tasks gated by permission rules. Detects toolchain or takes args (`go`, `tf`, `py`, `node`). |
| `dev-secrets` | Wires `secrets:upload` / `secrets:download` tasks (GCP Secret Manager) into the repo's task runner — adapts the `:`-naming to go-task/make/npm/shell. Committed name-manifest, gitignored values. Optional GitHub Actions download step and `*.secret.tfvars` terraform support (per-env, gitignored, round-tripped). Detects backend/runner or takes args (`gcp`, `task`, `make`, `npm`, `shell`). |
| `dev-codify` | Routes an inline throwaway script (`bash -c`, `python -c`, `node -e`, a heredoc) to a durable home instead of running and discarding it — an existing script/task first, then a new Taskfile task or script file. No args. |
| `dev-tf` | Replicates the tf-stack terraform/opentofu toolkit — `scripts/tf-stack.sh`, the `tf:*` namespace, the `stacks/<name>/variables/` layout. Selection by name (`VARS=dev`, `BACKEND=prod`), guards before tofu runs, collision-free `TF_DATA_DIR` and plan files. Detects greenfield vs. update; on update backs up the Taskfile and freezes CI-called names behind gated compat shims. GCS and local provisioning implemented; s3/azurerm documented. Args: `greenfield`/`update`, a backend (`gcs`, `s3`, `azurerm`, `local`), a toolchain. |
