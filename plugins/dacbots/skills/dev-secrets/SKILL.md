---
name: dev-secrets
description: Configure secrets management in a repo. Detects the cloud backend (GCP Secret Manager first), wires secrets:upload / secrets:download tasks into the repo's task runner (prefers go-task; adapts the a:b:c naming to make/npm/shell), keeps a committed name-manifest with gitignored values, and optionally adds a GitHub Actions download step and *.secret.tfvars terraform support. Use when the user wants to set up secrets management, sync secret files to/from a cloud secret store, or asks to add secrets tasks. Args: optional backend/runner hints (gcp, task, make, npm, shell).
user-invocable: true
allowed-tools:
  - Read
  - Edit
  - Write
  - Bash(ls *)
  - Bash(test *)
---

# /dev-secrets — configure project secrets management

Sets up a repo to sync secret files to/from a cloud secret store. Detects the
cloud backend (GCP Secret Manager is fully implemented), wires `secrets:upload`
and `secrets:download` into the repo's task runner, keeps a **committed
name-manifest** with **gitignored values**, and optionally adds a GitHub Actions
download step and `*.secret.tfvars` terraform support.

Arguments: `$ARGUMENTS` — optional space-separated hints. Backend: `gcp`.
Runner: `task`, `make`, `npm`, `shell`. With no args, detect everything from
the repo.

This skill is detection-driven and **idempotent**: re-running adds nothing
already present. The skill itself runs no cloud commands — it only writes task
definitions, gitignore entries, the manifest, and permission rules. Ask the user
whenever a choice is genuinely ambiguous (project id, runner to install,
GHA/terraform opt-in).

---

## Conventions (apply to everything you emit)

1. **Values never committed.** Only `secrets/manifest.txt` (names) and gitignore
   entries are tracked. Secret file contents stay local + gitignored.
2. **Manifest is the source of truth.** Download reads it; upload rewrites it.
   It is the name↔file map (GCP secret names disallow dots/slashes).
3. **`:`-nested, `:ask`-gated task names** (go-task house convention, see
   `/dev-tasks`). Upload/download touch the cloud and write plaintext secrets
   locally, so both are `:ask`-suffixed and gated by a permission rule.
4. **Adapt naming to the runner.** Colons where the runner allows them
   (go-task, npm), hyphens where it doesn't (make), files for shell.
5. **Idempotent + preserve.** Merge into existing files (gitignore, manifest,
   Taskfile, settings, workflows, tfvars); never overwrite or reorder unrelated
   content. When unsure about a change, collect it and ask before writing.

---

## Steps

### 1. Detect the cloud backend

If `$ARGUMENTS` names a backend, use it. Otherwise detect from the repo:

| Backend | Detection hooks | Commands | Status |
|---------|-----------------|----------|--------|
| **GCP** | `provider "google"` / `google-beta` in `*.tf`; `.gcloudignore`; `app.yaml`; `GOOGLE_CLOUD_PROJECT`; a service-account key JSON; `gcloud` config | `gcloud secrets …` | **implemented** |
| AWS | `provider "aws"` in `*.tf`; `~/.aws/`; `AWS_*` env | `aws secretsmanager …` | TODO stub |
| Azure | `provider "azurerm"` in `*.tf`; `az` config | `az keyvault secret …` | TODO stub |

Only GCP has command blocks below. If you detect **AWS or Azure**, tell the user
only GCP is implemented and ask whether to proceed GCP-style anyway or stop. If
**no backend** is detected, report that and stop (nothing to wire to) unless the
user forces `gcp`.

### 2. Detect the GCP project

Resolve the project id from, in order:

1. `$ARGUMENTS`.
2. Terraform: a `project = "…"` provider/var setting, or `project` in any
   `*.tfvars`.
3. `gcloud config get-value project` (read the config; do not assume a value).
4. `GOOGLE_CLOUD_PROJECT` / `app.yaml`.

If you find **none**, **multiple distinct** ids, or the choice is **ambiguous**,
**ask the user** (AskUserQuestion). Record the chosen id; every emitted task
passes `--project=<id>`.

### 3. Detect the task runner + adapt naming

Prefer **go-task**. Detect in order:

- `Taskfile.yml` → **go-task** (preferred).
- `Makefile` → **make**.
- `package.json` with a `scripts` block → **npm**.
- `scripts/*.sh` / shell scripts → **shell**.

If **none found**, ask the user which to install. On yes, **invoke `/dev-tasks`**
to scaffold a convention-compliant `Taskfile.yml`, then add the secrets tasks to
it. (`/dev-tasks` also installs the `Bash(task *:ask)` gate this skill relies
on.)

Adapt the `a:b:c` convention to the runner:

| Runner | upload | download | gated form |
|--------|--------|----------|------------|
| go-task | `secrets:upload` | `secrets:download` | `secrets:upload:ask` |
| npm | `secrets:upload` | `secrets:download` | (gate via `ask` perm rule) |
| make | `secrets-upload` | `secrets-download` | `ask-secrets-upload` |
| shell | `scripts/secrets-upload.sh` | `scripts/secrets-download.sh` | — |

Note which backend, project, and runner you chose and why (detected vs. asked).

### 4. Secrets directory + manifest

Default secrets dir: `secrets/` at the repo root (reuse an existing one if
found).

- **Gitignore the contents, keep the dir + manifest tracked.** Merge into
  `.gitignore` (dedupe, preserve other entries):
  ```
  secrets/*
  !secrets/.gitignore
  !secrets/manifest.txt
  ```
  Also write an empty `secrets/.gitignore` so the dir is committable even when
  empty.
- **Manifest** `secrets/manifest.txt` — committed, **names only**. One line per
  secret:
  ```
  <gcp-secret-name> <relative-file-path>
  ```
  The secret name is the filename sanitized to `[a-zA-Z0-9_-]` (GCP disallows
  dots/slashes), e.g. `db.password.json` → `db-password-json`. Create the
  manifest if missing; never write secret values into it.

### 5. Generate upload/download tasks

Emit into the detected runner, `:ask`-gated. go-task shape (adapt per the table
in step 3); substitute `<id>` with the project from step 2 and `<dir>` with the
secrets dir:

```yaml
  secrets:upload:ask:
    desc: Upload all secret files to GCP Secret Manager (ai-ask gated)
    cmds:
      - |
        for f in <dir>/*; do
          case "$f" in <dir>/.gitignore|<dir>/manifest.txt) continue ;; esac
          [ -e "$f" ] || continue
          name=$(basename "$f" | tr -c 'a-zA-Z0-9_-' '-')
          if gcloud secrets describe "$name" --project=<id> >/dev/null 2>&1; then
            gcloud secrets versions add "$name" --project=<id> --data-file="$f"
          else
            gcloud secrets create "$name" --project=<id> --data-file="$f"
          fi
          grep -q " $f$" <dir>/manifest.txt || echo "$name $f" >> <dir>/manifest.txt
        done

  secrets:download:ask:
    desc: Download all secrets from GCP Secret Manager into the secrets dir (ai-ask gated)
    cmds:
      - mkdir -p <dir>
      - |
        while read -r name file; do
          [ -n "$name" ] || continue
          mkdir -p "$(dirname "$file")"
          gcloud secrets versions access latest --secret="$name" --project=<id> > "$file"
        done < <dir>/manifest.txt
```

For **make**, write the same loops as recipe lines under `secrets-upload:` /
`secrets-download:` (hyphenated). For **npm**, point the script at a small shell
one-liner or a `scripts/secrets-*.sh` file (npm scripts can't hold multi-line
shell cleanly). For **shell**, write `scripts/secrets-upload.sh` /
`scripts/secrets-download.sh` with the loop bodies.

**Permission gating** — merge into `.claude/settings.local.json` (read existing,
create if missing, dedupe, preserve all other keys, write valid JSON):

- go-task: `permissions.ask` += `Bash(task *:ask)` (already present if
  `/dev-tasks` or `/dev-permissions` ran — then nothing to add).
- make: `permissions.ask` += `Bash(make ask-secrets-upload)` +
  `Bash(make ask-secrets-download)` (make has no prefix glob convention).
- npm: `permissions.ask` += `Bash(npm run secrets:upload)` +
  `Bash(npm run secrets:download)`.
- shell: `permissions.ask` += `Bash(bash scripts/secrets-upload.sh)` +
  `Bash(bash scripts/secrets-download.sh)`.

If the broad go-task `ask` gate isn't present, note that running `/dev-tasks` or
`/dev-permissions` complements this skill.

### 6. GitHub Actions (conditional)

Detect `.github/workflows/*.yml`. If found, detect cloud auth for the backend —
GCP: a `google-github-actions/auth` step, `workload_identity_provider`, or
`credentials_json`. **Only if auth is present**, ask the user whether to add a
secrets-download step.

On yes, insert a step **after** the auth step that runs the download task
(`task secrets:download`, or the adapted command for the runner). Idempotent:
skip if a step running that command already exists. Preserve all other workflow
content; if placement is ambiguous (multiple jobs / auth steps), ask which job.

### 7. Terraform (conditional)

Detect `*.tf` / `*.tofu` / `.terraform/`. If found, **ask** whether to add
terraform secrets. On yes:

- **Locate the params dir** — where existing `*.tfvars` live (repo root,
  `envs/`, `environments/<env>/`, or per-workspace). Support `*.secret.tfvars`
  there, alongside the existing vars.
- **Environment support** — if the project uses environments (per-env tfvars
  dirs or workspaces), use `<env>.secret.tfvars` per env, colocated with that
  env's other vars.
- The secret tfvars must be:
  1. **Passed to terraform/opentofu tasks** via `-var-file=<…>.secret.tfvars`.
     Harmonize the existing `tf:*:ask` tasks from `/dev-tasks` (per env) to
     thread the flag; if those tasks don't exist, note it and add the flag where
     the project invokes terraform/tofu.
  2. **Gitignored** — merge `*.secret.tfvars` into `.gitignore`.
  3. **Round-tripped** — add each secret tfvars path to `secrets/manifest.txt`
     (they live with the tfvars, not inside `secrets/`), so `secrets:upload` /
     `secrets:download` carry them too. Use a descriptive secret name, e.g.
     `tfvars-<env>`.

### 8. Report

Summarize: backend + project chosen (detected vs. asked); runner + adapted task
names; secrets dir, gitignore entries, and manifest written; permission rules
added vs. already present; and which conditionals fired (GHA download step,
terraform `-var-file` per env) vs. skipped. End with the caveats below.

---

## Caveats to surface to the user

- **Values are never committed.** Only `secrets/manifest.txt` (names) and the
  gitignore entries are tracked. **Verify the gitignore took** (`git check-ignore
  secrets/<file>`) before the first `secrets:upload`, so a plaintext secret
  isn't accidentally staged.
- **GCP secret names disallow dots/slashes.** The manifest holds the
  name→filename map. Renaming a secret file without updating the manifest
  orphans the old cloud secret and creates a new one on next upload.
- **Download overwrites local files** with the cloud `latest` version —
  uncommitted local edits to secret files are lost. Upload first if local is
  authoritative.
- **`:ask`-gating is by name suffix only** (go-task). Renaming a task out of the
  `:ask` suffix silently drops the permission gate — same coupling caveat as
  `/dev-tasks`.
- **Only GCP is implemented.** AWS / Azure detection hooks exist but their
  command blocks are TODO; the skill will tell you and stop (or proceed
  GCP-style only if you force it).
