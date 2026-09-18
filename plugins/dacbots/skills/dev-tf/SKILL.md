---
name: dev-tf
description: Replicate the tf-stack terraform/opentofu toolkit into a repo. Copies a proven scripts/tf-stack.sh and a go-task tf:* block out of this skill, detects greenfield vs. update, backs up Taskfile.yml and freezes the CI-called task names behind gated compat shims on update, derives VARS_MAP/BACKEND_MAP from the tfvars and backend configs the repo actually has, and verifies the install offline with task tf:verify. Use when a repo needs terraform or opentofu tasks, when adopting the STACK/VARS/BACKEND stack convention, when harmonizing a hand-rolled tf Taskfile, or asks to replicate tf-stack. Args: optional hints (greenfield, update, gcs, s3, azurerm, local, tofu, terraform) to force the mode, backend or toolchain.
user-invocable: true
allowed-tools:
  - Read
  - Edit
  - Write
  - Glob
  - Grep
  - Bash(ls *)
  - Bash(test *)
  - Bash(cp *)
  - Bash(chmod +x *)
  - Bash(mkdir *)
  - Bash(bash -n *)
  - Bash(git mv *)
  - Bash(git status *)
  - Bash(git ls-files *)
  - Bash(git check-ignore *)
  - Bash(task --list*)
  - Bash(task tf:verify*)
  - Bash(task tf:stacks:list*)
  - Bash(task tf:vars*)
  - Bash(task tf:backend*)
  - Bash(task tf:use*)
  - Bash(task tf:fmt:check*)
  - Bash(task tf:validate:local*)
  - Bash(task tf:validate:all*)
---

# /dev-tf — replicate the tf-stack toolkit into a repo

Installs three things this skill has already proven elsewhere: the `tf:*`
go-task block and its variable-resolution chain, `scripts/tf-stack.sh` (the
functions those tasks call by name), and the `stacks/<name>/` layout convention
that keeps each root module's `variables/*.tfvars` and `*.backend.hcl` self
contained. On top of that it adds selection of a stack by name, guards that
run before tofu ever touches a backend, and collision-free `TF_DATA_DIR`/plan
file names across every stack × vars × backend × toolchain combination. **This
skill copies artifacts; it does not regenerate them.** See
[`/dev-tasks`](../dev-tasks/SKILL.md) for the base Taskfile conventions and
permission-rule mechanics this skill builds on, and
[`/dev-codify`](../dev-codify/SKILL.md) for why the logic ships as one dispatch
script rather than inline `cmds` scattered across tasks.

Arguments: `$ARGUMENTS` — optional hints. Mode: `greenfield`, `update`.
Backend: `gcs`, `s3`, `azurerm`, `local`. Toolchain: `tofu`, `terraform`. With
no args, detect all three from the repo.

---

## What ships with this skill

| Source | Destination | How |
|---|---|---|
| `assets/tf-stack.sh` | `scripts/tf-stack.sh` | verbatim |
| `assets/taskfile-tf.yml` | merged into `Taskfile.yml` | templated, 10 tokens |
| `assets/tf-verify.sh` | `scripts/tf-verify.sh` | verbatim |
| `assets/stack/*` | `<STACKS_DIR>/<name>/` | greenfield only |
| `assets/backends/<flavor>.hcl` | `variables/<id>.backend.hcl` | templated |
| `references/tf-stack.md` | `docs/tf-stack.md` | adapted |
| `references/backends.md` | read on demand | never copied |
| `references/migration.md` | read on demand | never copied |

`assets/tf-stack.sh` carries `# tf-stack-version: 1` on line 3. Step 2 greps
for that stamp to tell a prior `/dev-tf` install apart from a hand-written
script of the same name.

---

## What tf-stack is

| Part | What it holds | What breaks if wrong |
|---|---|---|
| `tf:*` tasks + variable chain | Selection (`STACK`/`VARS`/`BACKEND`/`TF`), guards, init/plan/apply/validate wiring | A misnamed var silently no-ops a task instead of erroring |
| `scripts/tf-stack.sh` | The 7 uppercase resolvers plus every function a Taskfile `sh:` block calls by name | Renaming a function breaks variable evaluation for every task, with an opaque `unknown command` |
| `stacks/<name>/` layout | One root module per stack, each with its own `variables/*.tfvars` and `variables/*.backend.hcl` | Two stacks sharing a data dir or plan file corrupt each other's plan/state silently |

| Selector | Picks | Source |
|---|---|---|
| `STACK` | which root module | CLI, or the remembered `<stack>.env` |
| `VARS` | which `-var-file` set | id, explicit comma list, or glob |
| `BACKEND` | which `backend.hcl` | id, explicit comma list, or glob |
| `TF` | which binary | `tofu` or `terraform` |

Precedence, always in this order:

```
CLI > <stack>.env (tf:use) > VARS_ID > stack name
```

**A run's state moves when `VARS` moves.** Treat every `VARS`/`BACKEND` change
as a state-affecting decision, not a convenience flag.

---

## Modes (pick before you write anything)

*Taskfile axis* — governs rollback and CI obligations:

| Signal | Value | Obligations |
|---|---|---|
| no `Taskfile.yml` | `tf-new` | none; write freely |
| `Taskfile.yml`, no `tf:` task | `tf-add` | backup; leave every non-tf task untouched |
| `Taskfile.yml` with `tf:` tasks | `tf-replace` | backup, frozen CI-name list, remove-then-replace |
| `scripts/tf-stack.sh` carries `# tf-stack-version:` | `tf-refresh` | diff-only harmonize; no backup, no shims |

*Layout axis* — governs migration and state risk:

| Signal | Value | Obligations |
|---|---|---|
| no `*.tf`/`*.tofu` | `layout-none` | scaffold `<STACKS_DIR>/main/` |
| root modules already under `stacks/<name>/` (or `terraform/`, `infra/`, `live/`) | `layout-ok` | set `STACKS_DIR`, nothing else |
| root modules at repo root, `envs/<env>/`, `environments/<env>/` | `layout-move` | propose `git mv` per stack, confirm, never silent |
| workspaces in use | `layout-workspaces` | **stop and ask** |

`GREENFIELD = tf-new + (layout-none | layout-ok)`. Everything else is UPDATE.
`tf-refresh` is its own lighter path. Ambiguity → AskUserQuestion, never a
guess.

---

## Conventions (non-negotiable — copy, do not re-derive)

1. **Copy, never retype.** `cp` byte-for-byte; the only editable region of
   `tf-stack.sh` is the marked `# ---- ADAPTER ----` section.
2. **The variable chain is adopted whole.** All 28 vars, all of them or none —
   REPLICATE.md is explicit that adopting the chain piecemeal is fragile.
3. **Names are an ABI.** The 7 uppercase resolvers are called by exact string
   from `sh:` blocks and dispatched by `declare -F`; renaming one breaks
   variable evaluation for every task with an opaque `unknown command`.
4. **Three loop tasks carry no env anchor.** `tf:plan:all`, `tf:init:once:all`,
   and `tf:setup:all` skip `env: *tf_stack_env`, and every nested call inside
   them keeps `env -u TF_DATA_DIR`. Both failures are silent-wrong-answer, not
   errors.
5. **Guards before tofu.** The four `internal: true` guards ship even when
   `TF` is hardcoded; a glob matching nothing must be an error, because tofu
   happily plans from variable defaults instead.
6. **Order is precedence.** Written order wins — the last `-var-file` wins;
   within one glob, alphabetical. Verify with `task tf:vars`, never by
   reading.
7. **Keys stay composite.** `DATA_DIR = .terraform-<tf>-<backend_id>`;
   `PLAN_FILE = <stack>-<vars_id>-<backend_id>-<tf>.tfplan`.
8. **Gated names end in `:ask` / `:deny`,** and nothing else grants the gate.
   Any alias or shim exposing a gated task under an ungated name ships with
   its own permission rule **in the same edit**.
9. **Nothing of the source repo's identity survives.** See
   `references/migration.md`'s strip list before writing anything.
10. **Zero `__DEV_TF_*__` tokens remain.** Grep is the check, not a read-through.

---

## Migration safety rules (UPDATE only)

- **Back up before touching anything,** and the backup must be **tracked, not
  gitignored** — a gitignored backup satisfies nothing.
- **The CI contract comes from the target, never from assumption.**
  REPLICATE.md's `set-env-<env>`/`tf:init`/`tf:plan`/`tf:apply` shape is a
  fallback only; the source repo itself ships no workflows at all.
- **Tasks CI does not call are allowed to break.** Say so back to the user —
  it is what makes remove-then-replace affordable.
- **Remove, then replace. Never merge.** A legacy tf var merged into the new
  chain reintroduces the fragility convention 2 exists to prevent.
- **State never moves.** A `git mv` is a refactor as long as bucket/prefix (or
  key) are unchanged. Workspaces are the one exception and are never
  converted unattended.

---

## Steps

### 1. Locate this skill's assets

Resolve in this order, stopping at the first hit:

1. `${CLAUDE_PLUGIN_ROOT}/skills/dev-tf/`
2. `ls ~/.claude/plugins/cache/*/dacbots/*/skills/dev-tf/`
3. `~/.claude/plugins/marketplaces/*/plugins/dacbots/skills/dev-tf/`
4. `*/plugins/dacbots/skills/dev-tf/` under this repo
5. else ask the user where the skill lives.

Confirm all four `assets/` entries exist under the resolved path before
touching the target repo (`tf-stack.sh`, `taskfile-tf.yml`, `tf-verify.sh`,
plus `stack/` and `backends/`). A partial `assets/` dir means a stale
version-keyed cache — tell the user to bump `plugin.json` and run `/plugin
marketplace update dacetplace`.

For each asset, **Read it from the resolved path and Write it into the target
repo** — treat this as the primary method, since it does not depend on
`${CLAUDE_PLUGIN_ROOT}` resolving inside a `Bash` invocation, which this skill
has not verified. Fall back to `Bash(cp *)` only once the resolved source path
is confirmed present on disk. **Never reconstruct a missing asset from
memory** — a missing or truncated file at every resolution candidate means
stop and ask, not improvise a replacement.

### 2. Detect the mode (both axes)

Compute both signals from the tables above before writing anything.
`scripts/tf-stack.sh` present with **no** version stamp is hand-written; never
overwrite it silently — ask. `$ARGUMENTS` `greenfield`/`update` forces the
Taskfile axis only; the layout axis is always detected regardless of args.
Announce the resolved pair (each axis, and whether it was detected or forced)
before step 3.

### 3. Freeze the CI interface (`tf-add`/`tf-replace` only)

Grep `.github/workflows/**`, `.gitlab-ci.yml`, `.circleci/config.yml`,
`.buildkite/**`, `atlantis.yaml`, `Makefile`, and `scripts/*.sh` for `task
<name>` and for direct `terraform`/`tofu` invocations. That list is the frozen
interface. If no CI config lives in this repo, say so, ask the user, and fall
back to REPLICATE.md's shape **only as a labelled assumption**. Everything not
on the list is explicitly allowed to break — state that back to the user; it
is what makes step 10's remove-then-replace affordable.

### 4. Back up the Taskfile (`tf-add`/`tf-replace` only)

`cp Taskfile.yml Taskfile.yml.bckp`, `git add` it, and verify with `git
check-ignore -q Taskfile.yml.bckp` (must fail) and `git ls-files
--error-unmatch Taskfile.yml.bckp` (must succeed) — a gitignored backup cannot
satisfy REPLICATE.md's "commit the backup, remove after a stabilization
period." An existing `.bckp` belongs to an earlier migration: ask before
replacing it. Record the backup path and the removal criterion (one green CI
run on every frozen name) for step 10's migration note.

### 5. Copy the artifacts in

`mkdir -p scripts`; `cp assets/tf-stack.sh scripts/tf-stack.sh`; `chmod +x`;
`cp assets/tf-verify.sh scripts/tf-verify.sh`; `chmod +x`. **Do not open
`tf-stack.sh` to edit anything above the `# ---- ADAPTER ----` marker.** Then
merge `assets/taskfile-tf.yml` into `Taskfile.yml`: no Taskfile → invoke
`/dev-tasks` first so the frame (`default`, `test`, `silent: true`, permission
rules) comes from one place, then splice in the tf block. Merging into an
existing Taskfile: `tf_stack_env: &tf_stack_env` is a **top-level key above
`tasks:`** (YAML anchors must be defined before use; go-task ignores the
unknown top-level key); the three global `env:` keys merge into any existing
`env:`; the tf `vars:` merge into any existing `vars:`. Preserve every
existing key and task.

Splice **from the `# ---- BEGIN SPLICE ----` line only**. The comment banner
above it describes the asset, not the repo the block lands in, and it names
the token prefix — leaving it in makes step 6's grep report a false survivor
forever.

### 6. Set the ten project values

Replace every `__DEV_TF_*__` token, then grep the prefix — a survivor is an
incomplete install.

| Token | Value |
|---|---|
| `__DEV_TF_TF__` | `tofu` unless args/repo say otherwise |
| `__DEV_TF_TF_VERSION__` | only consumed when `TF=terraform`; else drop the `tf:toolchain:*` family |
| `__DEV_TF_TMP__` | reuse the repo's existing gitignored scratch dir, else `.task-tmp` |
| `__DEV_TF_STACKS_DIR__` | `stacks`, or the existing parent from step 2 |
| `__DEV_TF_BACKEND__` | step 7 |
| `__DEV_TF_STATE_PROJECT__` | GCP project owning state; empty for non-GCS |
| `__DEV_TF_STATE_BUCKET__` | `tf_setup` fallback when a backend.hcl names none |
| `__DEV_TF_STATE_LOCATION__` | e.g. `US` |
| `__DEV_TF_VARS_MAP__` | step 9 |
| `__DEV_TF_BACKEND_MAP__` | step 9 |

`DEBUG_LOG` ships pre-set to
`{{.ROOT_DIR}}/{{.TMP}}/{{.STACK}}-debug-{{.TF}}.log` — no token to fill in.

### 7. Choose the backend

From `$ARGUMENTS`, else from existing `backend "<flavor>"` blocks and existing
`*.backend.hcl` keys, else ask. Set `TF_BACKEND`. **gcs and local**: `tf_setup`
works; emit `tf:setup` and `tf:setup:all`. **s3 and azurerm**: emit everything
*except* `tf:setup`/`tf:setup:all`, and say in the report that the
bucket/container is provisioned out of band; the paste-in adapter snippets in
`references/backends.md` are applied **only if the user explicitly asks**, and
are then reported as unverified. **Anything else** (`http`, `cloud`,
`consul`, …): leave `TF_BACKEND` unset and omit `tf:setup*`; every other task
still works because `init` only ever passes `-backend-config=<file>` through.
If the flavor's CLI is missing, install anyway and note that `tf:setup` will
refuse until it is present.

### 8. Settle the layout (`layout-move` / `layout-workspaces` only)

`layout-move`: list every root module and its proposed destination, present
it, move only after confirmation, one stack at a time, `git mv` so history
follows. Keep each backend's `bucket`/`prefix` (or `key`) **unchanged** — the
move is a refactor, not a state migration. Never delete `.terraform*/` or a
local `terraform.tfstate` without asking (for a local backend, that file *is*
the state). Move per-env tfvars into `<stack>/variables/` and inline backend
settings into `variables/<id>.backend.hcl`, reducing the `.tf` block to a bare
`backend "<flavor>" {}` — ask before rewriting any `.tf`.

`layout-workspaces`: **stop**. Explain the one safe conversion (a
`BACKEND_MAP` id per workspace whose `backend.hcl` prefix points at the
workspace's existing state path, e.g. GCS `prefix =
"<old-prefix>/env:/<ws>"`, so nothing is copied), require the user to verify
it with a zero-change plan, and never run `terraform workspace delete`.

### 9. Derive `VARS_MAP` and `BACKEND_MAP` from the files that exist

Both maps are block scalars holding a plain-text list, one line per id. Write
the canonical shape — no space after the colon, none after a comma — though
`tf-stack.sh` normalizes whitespace around both, so the YAML-looking spelling
(`dev: variables/…, variables/…`) resolves identically:

```
dev:variables/common.tfvars,variables/dev.tfvars
prod:variables/common.tfvars,variables/prod.tfvars
```

It looks like YAML and is not: the parser is `cut -d: -f2-`, so `dev: vari…`
puts a leading space inside the first glob, which then matches nothing.
`task tf:vars` fails with ``glob ' variables/common.tfvars' matched no
files``, and worse, `task tf:plan:all` **silently** falls back to a single
default run instead of one run per id. Leading indentation is stripped and
does not matter. Confirm with `task tf:vars:ids`, then `task tf:vars
STACK=<s> VARS=<id>`, before moving on — `task tf:verify` check 7 also
catches it.

For each stack, list `variables/*.tfvars` and `variables/*.backend.hcl`.
Detect a shared base (`common`/`base`/`shared`/`global`) and put it **first**;
the environment file **last**. Prefer an explicit comma-separated list over a
glob whenever two files for one id must be ordered — a single glob expands
alphabetically. Backend ids come from `variables/*.backend.hcl` basenames.

Shape rules: **single module** → both maps empty (the `VARS_DEFAULT`/
`BACKEND_DEFAULT` pair already covers it; copying a three-env map into a
single-env repo is the likeliest mistake here). **Multi-stack** → usually
still empty. **Multi-env** → both populated, and deliberately *no*
`<stack>.tfvars`/`<stack>.backend.hcl`, so a bare run is refused rather than
silently defaulted. **Multi-stack multi-env** → maps are global while
`variables/` is per stack, so reuse ids across stacks or namespace them
(`app_dev`, `data_dev`); the `:all` tasks already skip ids a stack has no
files for.

Flag any `*.auto.tfvars` — tofu auto-loads it independently of `-var-file` and
`task tf:vars` will not show it. Present both maps for confirmation whenever
there are more than two ids: this is the one step that infers rather than
copies.

### 10. Write the Taskfile block, the shims, gitignore, permissions, docs

`tf-replace`: delete **every** legacy `tf:*` task and legacy tf var in one
edit, then write the new block in the next — never merge a legacy var into
the new chain. `tf-add`: insert, preserving everything. `tf-refresh`: diff and
apply only differences; present anything ambiguous instead of changing it.

For each frozen CI name the new surface lacks: a **read-only name**
(`tf:init`, `tf:validate`, `tf:fmt`) gets an `aliases:` entry on the canonical
task; a **writing name** (`tf:apply`, `tf:destroy`) gets a **visible wrapper
task** with `desc: 'CI compat shim for tf:apply:ask — remove after
stabilization'` whose `cmds` is `[{task: tf:apply:ask}]`, **plus its own
permission rule written in this same step** (`Bash(task tf:apply)` →
`permissions.ask`; `Bash(task tf:destroy)` → `permissions.deny`) — this is the
whole point: `Bash(task *:ask)` matches the name typed, so a shim without a
rule silently restores an ungated apply. `set-env-<env>` maps to one ungated
wrapper per env running `task tf:use STACK=<s> VARS=<env>`.

Merge `.gitignore` (each guarded by `grep -qxF`): `<TMP>/`, `.terraform*/`,
`.terraform.lock.hcl`, `*.env`, `*.tfplan`; confirm `Taskfile.yml.bckp` is
**not** matched. Merge `.claude/settings.local.json`: `Bash(task *:ask)` /
`Bash(task *:deny)` (delegate to `/dev-tasks` step 5 if absent) plus the shim
rules; **write no raw `Bash(tofu…)`/`Bash(terraform…)`/`Bash(gcloud…)`
allow**, and if one already exists, surface it as the run's most important
finding.

Copy `references/tf-stack.md` → `docs/tf-stack.md`, re-pointing examples at
this repo's stacks and dropping inapplicable shape sections; append a
**Migration** section recording the mode pair, frozen CI names and where they
came from (found vs. assumed), every shim with its rule, the backup path, and
the removal criterion. The migration record is an output file for the user,
not a chat message.

### 11. Report

Summarize: mode pair resolved (each axis, detected vs. forced, and the
signal); artifacts installed and their version stamp; backup committed and CI
names frozen (confirmed from workflow files vs. taken on the user's word); the
ten values set (detected vs. asked vs. defaulted); `VARS_MAP`/`BACKEND_MAP` as
written, per id, with the files each resolves to (and, for a single-env repo,
that both are deliberately empty); backend chosen, whether `tf:setup` was
emitted, adapted-but-unverified, or omitted, and whether its CLI is present;
layout decision (already conventional vs. migrated vs. `STACKS_DIR` changed
vs. stopped on workspaces); legacy tasks removed, kept, or shimmed, each shim
with its permission rule; `task tf:verify` PASS/FAIL lines with any check
skipped for lack of network named explicitly; and the first commands for the
user to run themselves (`task tf:setup:all STACK=…`, then `task tf:plan
STACK=… VARS=…`). End with the caveats below.

---

## Caveats to surface to the user

- **A shim or alias reopens the gate.** Exposing a gated `:ask`/`:deny` task
  under a new name grants nothing on its own, but forgetting the paired
  permission rule silently restores an ungated apply/destroy.
- **Never allowlist `tofu`, `terraform`, or `gcloud` directly.** Every safe
  path runs through a gated `task` name; a raw binary allow bypasses every
  guard this skill installs.
- **`tf:apply:ask` takes no `-var-file`.** It applies a previously saved plan
  file; values were already resolved when that plan was produced by `tf:plan`.
- **`VARS=id:glob` bypasses the map entirely.** An explicit glob on the CLI
  skips `VARS_MAP` lookup and its ordering guarantees — useful for one-off
  debugging, risky as a habit.
- **The `:all` tasks are load-bearing-weird.** `tf:plan:all`,
  `tf:init:once:all`, and `tf:setup:all` deliberately carry no env anchor and
  keep `env -u TF_DATA_DIR` on their nested calls; do not "clean up" that
  asymmetry.
- **`tf:use` gitignores `*.env`, not `<stack>.env`.** Any dotfile matching
  `*.env` in the repo root is covered by the same gitignore line; that is
  intentional, not a narrower per-stack rule.
- **`task tf:validate:all` can pass while validating nothing.** An empty
  `<STACKS_DIR>/` makes it a zero-iteration success — check the output, not
  just the exit code.
- **The plugin cache is version-keyed.** An edited asset is invisible until
  `plugins/dacbots/.claude-plugin/plugin.json`'s `version` is bumped and
  `/plugin marketplace update dacetplace` runs.
