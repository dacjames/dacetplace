---
name: dev-tasks
description: Scaffold a convention-compliant go-task Taskfile.yml in a repo. Auto-detects the toolchain (go/terraform/python/node) and emits idempotent, :-nested tasks that are quiet by default, pass through CLI_ARGS, use a local temp dir, and gate ask:/deny:-prefixed tasks behind Claude permission rules. Use when the user wants to set up a Taskfile, add go-task to a project, scaffold dev tasks, or harmonize an existing Taskfile to house conventions. Args: optional toolchain names (go, tf, py, node) to force on demand.
user-invocable: true
allowed-tools:
  - Read
  - Edit
  - Write
  - Bash(ls *)
  - Bash(test *)
---

# /dev-tasks — scaffold a convention-compliant go-task Taskfile

Writes (or harmonizes) a [go-task](https://taskfile.dev) `Taskfile.yml` that
follows house conventions: idempotent tasks, `:`-nested names, quiet by default,
`CLI_ARGS` passthrough, a local temp dir, full command output, and `ask:`/`deny:`
prefixes wired to Claude permission rules.

Arguments: `$ARGUMENTS` — optional space-separated toolchains to force:
`go`, `tf`, `py`, `node`. With no args, detect the toolchain from repo manifests.

---

## Conventions (non-negotiable — apply to every task you emit)

1. **Idempotent.** Every task is safe to run repeatedly. `mkdir -p`, append-only
   guards (`grep -qxF ... || echo ...`), `rm -rf` against known paths, etc.
2. **`:`-nested names.** Use `:` for nesting: `go:setup`, `test:e2e-suite-1`,
   `ssh:canary:us-west2`, `ask:tf:apply`. go-task allows `:` directly in task
   names — a single flat `Taskfile.yml` is the default. (For large repos,
   `includes:` to per-namespace Taskfiles is an option; mention but don't force.)
3. **`CLI_ARGS` passthrough.** Run/test-style tasks thread `{{.CLI_ARGS}}` so
   `task go:test -- -run TestFoo` works.
4. **Quiet by default.** Global `silent: true`. **Exception:** `setup` and
   `clean` (and `tmp:setup`) set `silent: false` so the user sees provisioning
   and teardown steps.
5. **Full command output.** Never suppress a program's stdout/stderr — **no**
   `> /dev/null`, `2>/dev/null`, or `&>/dev/null` in task `cmds`. (`silent` hides
   go-task's *command echo* only, not program output — the two are independent;
   suppressing output is a separate, forbidden thing.)
6. **Local temp dir.** Never write temp files to the project root. Reference a
   `TMP` var; provision the dir via a `tmp:setup` task (create + gitignore).
7. **`default` lists tasks** (`task --list`); **every task has a `desc:`** so it
   shows up in the listing.
8. **`ask:` / `deny:` prefixes** mark tasks gated by `task ask:*` / `task deny:*`
   permission rules (written in step 5).

---

## Steps

### 1. Detect toolchain → namespaces

- If `$ARGUMENTS` names toolchains → emit exactly those namespaces.
- Otherwise detect manifests at the repo root and map to namespaces:
  - `go.mod` → **go** (`go:setup`, `go:test`, `go:run`, …)
  - `*.tf` / `*.tofu` / `.terraform/` → **tf** (`tf:setup`, `tf:clean`, …)
  - `pyproject.toml` / `requirements.txt` / `setup.py` → **py** (`py:setup`,
    `py:test`, `py:clean`, …)
  - `package.json` → **node** (`node:setup`, `node:test`, …)
- Only emit namespaces for detected/requested toolchains. Do **not** add deps to
  tasks that don't exist (e.g. omit `py:setup` from `setup` deps if no Python).
- Note which namespaces you chose and why (detected vs. requested).

### 2. Resolve the temp dir (`TMP`)

- Probe for an existing **gitignored** dir named one of `tmp` / `temp` / `wip` /
  `scratch` / `.tmp` / `.scratch` (check `.gitignore` entries and existing dirs
  at the repo root). If found, reuse it as the `TMP` value.
- If none found, **do not create it now.** Default `TMP` to `.task-tmp` and rely
  on the emitted `tmp:setup` task to create + gitignore it on first run.

### 3. Generate `Taskfile.yml`

Single file at the repo root. Structure (fill per detected namespaces; this is
the shape, not a literal copy):

```yaml
version: '3'

silent: true                         # quiet by default (echo only; output stays)

vars:
  TMP: '.task-tmp'                    # or the reused gitignored dir from step 2

tasks:
  default:
    desc: List available tasks
    cmds: [task --list]

  tmp:setup:
    desc: Create the local temp dir and gitignore it
    silent: false
    cmds:
      - mkdir -p {{.TMP}}
      - grep -qxF '{{.TMP}}/' .gitignore || echo '{{.TMP}}/' >> .gitignore

  setup:
    desc: Install toolchains and provision local state
    silent: false
    deps: [tmp:setup, go:setup]      # only detected namespaces

  test:
    desc: Run all test suites
    deps: [go:test]                  # + test:e2e-* suites if present

  run:
    desc: Run the primary dev instance of the app
    cmds: [task go:run -- '{{.CLI_ARGS}}']

  clean:
    desc: Remove local state and installed files
    silent: false
    deps: [go:clean]                 # only detected namespaces

  # --- go namespace (emit only if detected) ---
  go:setup:
    desc: Install the Go toolchain / module deps
    cmds: [go mod download]
  go:test:
    desc: Run Go tests
    cmds: ['go test ./... {{.CLI_ARGS}}']
  go:run:
    desc: Run the Go app
    cmds: ['go run . {{.CLI_ARGS}}']
  go:clean:
    desc: Remove Go build artifacts
    cmds: [rm -rf {{.TMP}}/build]

  # --- ai-gated tasks (prefix → permission rule, see step 5) ---
  ask:tf:apply:
    desc: Apply terraform/opentofu (ai-ask gated)
    cmds: ['tofu apply {{.CLI_ARGS}}']
  deny:tf:init-upgrade:
    desc: terraform/opentofu init -upgrade (ai-deny gated)
    cmds: [tofu init -upgrade]
```

Apply every convention from the list above. In particular: no output redirects
to `/dev/null`; `setup`/`clean`/`tmp:setup` are `silent: false`; every task has a
`desc`; `{{.CLI_ARGS}}` on run/test-style tasks.

### 4. Harmonize an existing `Taskfile.yml`

If `Taskfile.yml` already exists, **do not overwrite it.** Read it, then:

- Add only **missing** convention pieces: a `default`→`--list` task, `silent:
  true` global if absent, `tmp:setup`, `TMP` var, missing namespace tasks, and
  `desc` on tasks that lack one.
- **Preserve every existing task and key.** Never reorder or drop the user's
  content.
- If **unsure** about any change — a conflicting `silent` value, a same-named
  task with different cmds, an existing `/dev/null` redirect, ambiguous structure
  — **do not change it.** Collect the proposed/uncertain changes, present them to
  the user, and ask them to confirm before writing.
- Idempotent: re-running adds nothing already present.

### 5. Write permission gate rules

Merge into `.claude/settings.local.json` (read existing, create if missing,
dedupe, preserve all other keys, write valid JSON):

- `permissions.ask`: `Bash(task ask:*)`
- `permissions.deny`: `Bash(task deny:*)`

Precedence is **deny → ask → allow**, first match wins, so these override the
broad `Bash(task:*)` allow (installed by `/dev-permissions` base ruleset). If
that broad allow isn't present, note that running `/dev-permissions` complements
this skill for the rest of the toolchain.

### 6. Report

Summarize: namespaces emitted (detected vs. absent), `Taskfile.yml` created vs.
harmonized (and any changes deferred for user confirmation), temp-dir decision
(reused existing vs. `tmp:setup` emitted with `TMP=.task-tmp`), and permission
rules added vs. already present.

---

## Caveats to surface to the user

- **`silent` ≠ hiding output.** `silent: true` suppresses go-task's command
  *echo*, not the program's stdout/stderr. Full output still shows — that's
  intended. Do not "fix" noisy tasks with `/dev/null` redirects.
- **Prefix-to-permission coupling is by convention.** `ask:`/`deny:` only gate if
  the task name actually starts with that prefix and the matching `Bash(task
  ask:*)` / `Bash(task deny:*)` rule exists. Renaming a task out of the prefix
  silently removes the gate.
- **`:` in names vs. includes.** Flat colon-named tasks live in one file and are
  the default. If the repo later splits into `includes:`, namespace prefixes are
  generated from the include key — keep names consistent if migrating.
