---
name: dev-tasks
description: Scaffold a convention-compliant go-task Taskfile.yml in a repo. Auto-detects the toolchain (go/terraform/python/node) and emits idempotent, :-nested tasks that are quiet by default, pass through CLI_ARGS, use a local temp dir, and gate :ask/:deny-suffixed tasks behind Claude permission rules. Use when the user wants to set up a Taskfile, add go-task to a project, scaffold dev tasks, or harmonize an existing Taskfile to house conventions. Args: optional toolchain names (go, tf, py, node) to force on demand.
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
`CLI_ARGS` passthrough, a local temp dir, full command output, and `:ask`/`:deny`
suffixes wired to Claude permission rules.

Arguments: `$ARGUMENTS` — optional space-separated toolchains to force:
`go`, `tf`, `py`, `node`. With no args, detect the toolchain from repo manifests.

---

## Conventions (non-negotiable — apply to every task you emit)

1. **Idempotent.** Every task is safe to run repeatedly. `mkdir -p`, append-only
   guards (`grep -qxF ... || echo ...`), `rm -rf` against known paths, etc.
2. **`:`-nested names.** Use `:` for nesting: `go:setup`, `test:e2e-suite-1`,
   `ssh:canary:us-west2`, `db:migrate:ask`. go-task allows `:` directly in task
   names — a single flat `Taskfile.yml` is the default. (For large repos,
   `includes:` to per-namespace Taskfiles is an option; mention but don't force.)
3. **`CLI_ARGS` passthrough.** Run/test-style tasks thread `{{.CLI_ARGS}}` so
   `task go:test -- -run TestFoo` works.
4. **`silent: true` is the frame; user-facing leaf tasks set `silent:
   false`.** Global `silent: true` suppresses go-task's command echo, and
   that's the right default only for orchestration — wrapper tasks like
   `default` and tasks whose whole job is a `deps:`/ordered `cmds: - task:`
   chain to other tasks. A task the user runs to see something actually
   happen — a build, a test run, `tmp:setup`, most leaf tasks in every
   namespace — sets `silent: false` so its own command line shows next to
   its output. This is the common case, not a short exception list: in the
   reference implementation this pattern is scaled from, `silent: false` is
   set on 64 of 87 tasks against a single global `silent: true`. Read "quiet
   by default" as describing the orchestration frame, never the leaves
   hanging off it.
5. **Full command output.** Never suppress a program's stdout/stderr — **no**
   `> /dev/null`, `2>/dev/null`, or `&>/dev/null` in task `cmds`. This is
   independent of convention 4: `silent` hides go-task's *command echo* only,
   never a program's output, so a `silent: true` wrapper task still shows
   everything its `cmds` print — suppressing output is a separate, forbidden
   thing regardless of a task's `silent` setting.
6. **Local temp dir.** Never write temp files to the project root. Reference a
   `TMP` var; provision the dir via a `tmp:setup` task (create + gitignore).
7. **`default` lists tasks** (`task --list`); **every task has a `desc:`** so it
   shows up in the listing.
8. **`:ask` / `:deny` suffixes** mark tasks gated by `task *:ask` / `task *:deny`
   permission rules (written in step 5).
9. **`dir:` scopes a task to a subtree.** Set it whenever a task's `cmds` must
   run relative to something other than the repo root — the reason one task
   ends up stack-relative and another root-relative in the same Taskfile.
   ```yaml
   node:test:
     desc: Run the node test suite from its subtree
     dir: web/
     cmds: ['npm test {{.CLI_ARGS}}']
   ```
10. **`internal: true` hides plumbing from `task --list`.** Use it for guard
    and precondition tasks nothing outside this file should call directly —
    they still run fine as `deps:`/`cmds: - task:` targets, just never as a
    listed, user-facing entry point.
    ```yaml
    go:mod:assert:
      internal: true
      cmds: [test -f go.mod || (echo 'no go.mod' >&2 && exit 1)]
    ```
11. **`status:` is go-task's own skip-if-done check.** It is stronger than
    convention 1's idempotence: convention 1 makes a task *safe* to re-run;
    `status:` makes go-task *skip the `cmds` entirely* once the check already
    holds, so a re-run costs nothing instead of merely doing no harm.
    ```yaml
    go:setup:
      desc: Install the Go toolchain / module deps
      status: [test -d {{.TMP}}/gomodcache]
      cmds: [go mod download]
    ```
12. **`deps:` is unordered; an ordered `cmds:` list of `- task:` entries is a
    guard chain — a correctness distinction, not a style choice.** Use
    `deps:` only when the listed tasks have no ordering relationship and may
    run in parallel; use ordered `- task:` entries in `cmds:` when one task
    must finish before the next starts. Getting this backwards can run a
    precondition concurrently with the thing it was meant to guard.
    ```yaml
    setup:
      desc: Install toolchains and provision local state
      deps: [go:setup, node:setup]     # no ordering needed; may parallelize

    db:migrate:ask:
      desc: Run pending database migrations (ai-ask gated)
      cmds:
        - task: db:conn:assert         # must finish first
        - task: db:backup:assert       # then this, in order
        - migrate-tool up {{.CLI_ARGS}}
    ```
13. **`aliases:` adds a second callable name without duplicating the task.**
    Handy for a short or legacy name; see the Caveats section below for the
    permission-gate hazard this creates on a `:ask`/`:deny` task.
    ```yaml
    go:mod:tidy:
      desc: Tidy go.mod and go.sum
      aliases: [go:mod-tidy]
      cmds: [go mod tidy]
    ```
14. **`env: &anchor` / `*anchor` carries many vars into a script at one
    prefix.** Define the anchor once above `tasks:` and reuse it on every
    task that shells out to the same script, commonly at a `V_` prefix so the
    script's own names never collide with the caller's `vars:`.
    ```yaml
    my_script_env: &my_script_env
      V_ROOT_DIR: '{{.ROOT_DIR}}'
      V_STACK: '{{.STACK}}'

    tasks:
      deploy:run:
        desc: Run the deploy script with the shared var set
        env: *my_script_env
        cmds: [scripts/deploy.sh]
    ```

---

## Steps

### 1. Detect toolchain → namespaces

- If `$ARGUMENTS` names toolchains → emit exactly those namespaces.
- Otherwise detect manifests at the repo root and map to namespaces:
  - `go.mod` → **go** (`go:setup`, `go:test`, `go:run`, …)
  - `*.tf` / `*.tofu` / `.terraform/` → **invoke
    [`/dev-tf`](../dev-tf/SKILL.md)** instead of emitting a tf namespace
    here — it copies the proven `scripts/tf-stack.sh` and `tf:*` task block
    rather than re-deriving them.
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
      - touch .gitignore
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

  # --- ai-gated tasks (suffix → permission rule, see step 5) ---
  db:migrate:ask:
    desc: Run pending database migrations (ai-ask gated)
    cmds: ['migrate-tool up {{.CLI_ARGS}}']
  db:drop:deny:
    desc: Drop the database (ai-deny gated)
    cmds: [migrate-tool drop]
```

Detected `*.tf`/`*.tofu` → run [`/dev-tf`](../dev-tf/SKILL.md) instead of
emitting tf tasks here.

`tmp:setup`'s `touch .gitignore` runs before the `grep -qxF` guard so a fresh
clone with no `.gitignore` file yet still satisfies the guard instead of
failing outright — omit it and the task is not idempotent on its very first
run, breaking convention 1. If a tf namespace's vars are already in this
Taskfile (`/dev-tf` has been run), also `mkdir -p {{.PLUGIN_CACHE}}` here so
its plugin cache dir exists before anything reads it.

Apply every convention from the list above. In particular: no output redirects
to `/dev/null`; `setup`/`clean`/`tmp:setup` and other user-facing leaf tasks are
`silent: false`; every task has a `desc`; `{{.CLI_ARGS}}` on run/test-style
tasks.

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

- `permissions.ask`: `Bash(task *:ask)`
- `permissions.deny`: `Bash(task *:deny)`

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
- **Suffix-to-permission coupling is by convention.** `:ask`/`:deny` only gate if
  the task name actually ends with that suffix and the matching `Bash(task
  *:ask)` / `Bash(task *:deny)` rule exists. Renaming a task out of the suffix
  silently removes the gate.
- **`aliases:` can silently reopen a closed gate.** It adds a second, fully
  callable name for the same task. Aliasing an un-suffixed name onto an
  `:ask`/`:deny` task defeats the gate, because the permission rule matches
  only the suffix of the name Claude actually invokes — calling the alias
  runs the exact same `cmds` as the gated task, ungated. Never add an alias
  to a gated task without also either suffixing the alias itself or leaving
  it off entirely.
- **`:` in names vs. includes.** Flat colon-named tasks live in one file and are
  the default. If the repo later splits into `includes:`, namespace prefixes are
  generated from the include key — keep names consistent if migrating.
