---
name: dev-tf
description: Replicate the tf-stack terraform/opentofu toolkit into a repo. Copies a proven scripts/tf-stack.sh and a go-task tf:* block out of this skill, detects greenfield vs. update, detects the repo's shape (single stack, multi-env, multi-stack) by locating each root module's backend in a config file or inline in a .tf, backs up the Taskfile and freezes the CI-called task names behind gated compat shims on update, derives VARS_MAP/BACKEND_MAP from the tfvars and backend configs the repo actually has, and verifies the install offline with task tf:verify. Use when a repo needs terraform or opentofu tasks, when adopting the STACK/VARS/BACKEND stack convention, when harmonizing a hand-rolled tf Taskfile, or asks to replicate tf-stack. Args: optional hints (greenfield, update, tofu, terraform) to force the mode or toolchain.
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
  - Bash(scripts/tf-stack.sh BACKEND_KIND*)
  - Bash(scripts/tf-stack.sh BACKEND_INLINE_FILE*)
  - Bash(bash scripts/tf-stack.sh help*)
  - Bash(cmp *)
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
Toolchain: `tofu`, `terraform`. With no args, detect both from the repo. The
backend is never an argument — it is read off the repo's own backend
configuration in step 2.

---

## What ships with this skill

| Source | Destination | How |
|---|---|---|
| `assets/tf-stack.sh` | `scripts/tf-stack.sh` | verbatim |
| `assets/taskfile-tf.yml` | merged into the Taskfile | templated, 8 tokens |
| `assets/tf-verify.sh` | `scripts/tf-verify.sh` | verbatim |
| `assets/stack/*` | `stacks/<name>/` | greenfield only |
| `assets/backends/gcs.hcl` | `variables/<id>.backend.hcl` | templated |
| `references/tf-stack.md` | `docs/tf-stack.md` | adapted |
| `references/migration.md` | read on demand | never copied |

`assets/tf-stack.sh` is the upstream `scripts/tf-stack.sh` minus five
functions specific to its home repo; the 31 that remain are the ABI. Step 2
runs `bash scripts/tf-stack.sh help` in the target and reads that name list to
tell a prior `/dev-tf` install apart from a hand-written script of the same
name.

---

## What tf-stack is

| Part | What it holds | What breaks if wrong |
|---|---|---|
| `tf:*` tasks + variable chain | Selection (`STACK`/`VARS`/`BACKEND`/`TF`), guards, init/plan/apply/validate wiring | A misnamed var silently no-ops a task instead of erroring |
| `scripts/tf-stack.sh` | The 13 uppercase resolvers plus every function a Taskfile `sh:` block calls by name | Renaming a function breaks variable evaluation for every task, with an opaque `unknown command` |
| `stacks/<name>/` layout | One root module per stack, each with its own `variables/*.tfvars` and `variables/*.backend.hcl` | Two stacks sharing a data dir or plan file corrupt each other's plan/state silently |

| Selector | Picks | Source |
|---|---|---|
| `STACK` | which root module | CLI, or the remembered `<stack>.env` |
| `VARS` | which `-var-file` set | id, explicit comma list, or glob |
| `BACKEND` | which backend config — a `.backend.hcl` or a `.tf` holding the backend inline | id, or `<id>:<path>` |
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
| no `Taskfile.{yml,yaml}` | `tf-new` | none; write freely |
| a Taskfile with no task invoking `terraform`/`tofu` | `tf-add` | backup; leave every non-tf task untouched |
| a Taskfile with tasks invoking `terraform`/`tofu`, **under any name** | `tf-replace` | backup, frozen CI-name list, remove-then-replace |
| `scripts/tf-stack.sh` whose `help` lists the 31 ABI names | `tf-refresh` | diff-only harmonize; no backup, no shims |

*Shape axis* — **which pattern the repo already uses**, hence what stack
structure it migrates to. This is a detection, not a decision: two counts,
root modules and backends per root module. Step 2 says how to get them.

| Root modules | Backends each | Value | Migrates to |
|---|---|---|---|
| — (no `*.tf`) | — | `shape-none` | scaffold `stacks/main/` |
| 1 | 1 | `shape-single` | one stack; `variables/<stack>.tfvars`; both maps empty |
| 1 | >1 | `shape-multi-env` | one stack; a `.backend.hcl` + tfvars per env; both maps populated; **no** `<stack>.tfvars` |
| >1 | 1 each | `shape-multi-stack` | one stack per root module; `variables/<stack>.tfvars` each; both maps empty |
| >1 | >1 | `shape-multi-both` | per stack as `shape-multi-env`, ids deconflicted across stacks |
| workspaces in use | — | `shape-workspaces` | **stop and ask** |

Two degenerate readings, both common:

- A repo that looks multi-env but defines **one** environment is
  `shape-single`. That is legacy, not a shape to preserve.
- `envs/<env>/` directories that are near-copies of each other are **one**
  root module in E environments — `shape-multi-env`, not `shape-multi-stack`.
  The discriminator is content, not count: directories that differ only in
  values are one module; directories that declare different resources, or
  call different sets of shared `modules/`, are different stacks.

*Placement* is a consequence of the shape, decided **per root module** in step
8 — each one either already sits at `stacks/<name>/` or gets a proposed
`git mv` into it. `stacks/` is the layout, not a knob: there is nothing to
configure and nowhere else for a stack to live. It is never a repo-wide
verdict, and never a reason to skip the inspection above.

`GREENFIELD = tf-new + (shape-none | every root module already placed)`.
Everything else is UPDATE. `tf-refresh` is its own lighter path. Ambiguity →
AskUserQuestion, never a guess.

---

## Conventions (non-negotiable — copy, do not re-derive)

1. **Copy, never retype.** `cp` byte-for-byte; `tf-stack.sh` has no editable
   region, and nothing in it is meant to be adjusted per repo.
2. **The variable chain is adopted whole.** All 32 vars, all of them or none —
   adopting the chain piecemeal is fragile: a var the anchor lacks reads as an
   empty string in the script.
3. **Names are an ABI.** The 13 uppercase resolvers are called by exact string
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
  `references/migration.md` §1's `set-env-<env>`/`tf:init`/`tf:plan`/`tf:apply`
  shape is a fallback only; the source repo itself ships no workflows at all.
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

Confirm all five `assets/` entries exist under the resolved path before
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

**Detecting the shape: find the root modules, then find each one's backend.**
The second half is what the table's "backends each" column counts, and it is
the step that is easy to skip — a backend lives in one of two places and only
one of them is a file you can glob for.

1. **Root modules.** Every directory holding `*.tf` that is not a
   shared module. Exclude `modules/**`, `.terraform*/`, and any directory
   another module names as `source = "./…"`. A root module normally carries a
   `terraform {` block, a `provider` block, or a backend.

2. **Each root module's backend, in both of its homes:**

   - **A backend config file** — `*.backend.hcl`, `*.tfbackend`,
     `backend*.hcl`. Look in the module directory and in `variables/`,
     `config/`, `backends/`, `envs/` beneath it. Also grep CI, the Makefile
     and the Taskfile for `-backend-config=`: that flag is the only thing that
     can name a config file living outside the module.
   - **Inline in a `.tf`** — a `backend "<type>" { … }` block **with at
     least one setting in it**, inside the module's `terraform {}` block. This
     is the layout most terraform repos use. It is usually `main.tf` and
     often not: `backend.tf`, `providers.tf`, `terraform.tf`, `versions.tf`
     are all normal homes. Grep every `*.tf` in the module; never open
     `main.tf` alone and conclude.
   - **An empty `backend "<type>" {}` is not a backend.** It is the
     partial-config form, and it means the settings arrive by
     `-backend-config` — so finding one means the real location is a config
     file (or a CI flag), and the search continues.
   - **Neither** → the module has no remote state: local, plan-only. Report
     it; it is a legitimate state to install against, and `tf:setup` is how it
     gets adopted.

   Once step 5 has copied the assets in, the installed toolkit answers this
   same question and is the check on the detection:
   `scripts/tf-stack.sh BACKEND_KIND <path>` prints `config`, `inline` or
   `none`, and `scripts/tf-stack.sh BACKEND_INLINE_FILE <dir>` names the `.tf`
   holding an inline backend, if any.

3. **Count distinct state locations, not files.** Two `.backend.hcl` naming
   the same bucket and prefix are one backend. Two modules whose inline blocks
   name the same location are a collision — surface it, do not average it away.

Report the counts, the shape they resolve to, and where each backend was
found, before step 3.

**Both Taskfile spellings count.** `Taskfile.yml` and `Taskfile.yaml` are
equally valid to go-task; read "the Taskfile" everywhere below as whichever
one this repo has. Taking the literal `.yml` reading on a `.yaml` repo detects
`tf-new`, "writes freely", and leaves a second Taskfile shadowing the real one.

**The `tf-replace` signal is behaviour, not namespace.** A repo whose
terraform tasks are named `init`, `plan`, `apply`, `otel-plan` is
`tf-replace`, not `tf-add` — grep the Taskfile for `terraform`/`tofu`
invocations rather than for a `tf:` prefix. Reading it as `tf-add` installs a
complete second terraform surface beside the first. Where legacy un-namespaced
names survive, report the overlap explicitly in step 11, and check whether
`.claude/settings.local.json` already allowlists them (`Bash(task plan)`,
`Bash(task apply)`) — those are ungated names that convention 8 assumes do not
exist.

**Already-installed short-circuit.** If the mode is `tf-refresh` and
`scripts/tf-stack.sh` matches this skill's asset byte-for-byte, no
`__DEV_TF_*__` token survives, and `task tf:verify` passes, then the install is
current: report that and stop. Steps 3–10 all read as though work remains, and
for a re-run — which is the common case — none does.

**`tf-refresh` is detected by the ABI, not by a marker in the file.**
`scripts/tf-stack.sh` exists **and** `bash scripts/tf-stack.sh help` lists the
frozen names (the 31 `tf:verify` check 2 expects) → a prior install. A script
of that name whose `help` lists none of them is someone's own; never overwrite
it silently — ask. `$ARGUMENTS` `greenfield`/`update` forces the
Taskfile axis only; the shape axis is always detected regardless of args.
Announce the resolved pair (each axis, and whether it was detected or forced)
before step 3.

### 3. Freeze the CI interface (`tf-add`/`tf-replace` only)

Grep `.github/workflows/**`, `.gitlab-ci.yml`, `.circleci/config.yml`,
`.buildkite/**`, `atlantis.yaml`, `Makefile`, the Taskfile, and `scripts/*.sh`
for `task <name>` and for direct `terraform`/`tofu` invocations. That list is
the frozen interface.

**The direct-invocation half of this grep is not gated on the Taskfile axis.**
This step's `task <name>` freeze is; the sweep for `-chdir=`, `-var-file=`,
`-backend-config=`, `path:`, `working-directory:` and bare `cd <dir>` is an
obligation of **any run that moves a directory**, including a `tf-new` repo
whose CI drives tofu directly and calls no task at all. Every such hit is a
rewrite obligation shipping in the same commit as the `git mv` — see step 8.
Present the count with the layout plan; it is usually the real cost of a move. If no CI config lives in this repo, say so, ask the user, and fall
back to `references/migration.md` §1's shape **only as a labelled
assumption**. Everything not on the list is explicitly allowed to break —
state that back to the user; it is what makes step 10's remove-then-replace
affordable.

### 4. Back up the Taskfile (`tf-add`/`tf-replace` only)

`cp <taskfile> <taskfile>.bckp` (the spelling the repo actually uses), `git add` it, and verify with `git
check-ignore -q <taskfile>.bckp` (must fail) and `git ls-files
--error-unmatch <taskfile>.bckp` (must succeed) — a gitignored backup cannot
satisfy `references/migration.md` §5's "commit the backup, remove it after a
stabilization period." An existing `.bckp` belongs to an earlier migration: ask before
replacing it. Record the backup path and the removal criterion (one green CI
run on every frozen name) for step 10's migration note.

### 5. Copy the artifacts in

`mkdir -p scripts`; `cp assets/tf-stack.sh scripts/tf-stack.sh`; `chmod +x`;
`cp assets/tf-verify.sh scripts/tf-verify.sh`; `chmod +x`. **Do not edit
`tf-stack.sh` at all — it installs exactly as it ships.** Then
merge `assets/taskfile-tf.yml` into the Taskfile: no Taskfile → invoke
`/dev-tasks` first so the frame (`default`, `test`, `silent: true`, permission
rules) comes from one place, then splice in the tf block. Merging into an
existing Taskfile: `tf_stack_env: &tf_stack_env` is a **top-level key above
`tasks:`** (YAML anchors must be defined before use; go-task ignores the
unknown top-level key); the three global `env:` keys merge into any existing
`env:`; the tf `vars:` merge into any existing `vars:`. Preserve every
existing key and task.

Splice **from the `# ---- BEGIN SPLICE ----` line only**. The comment banner
above it describes the asset, not the repo the block lands in.

### 6. Set the eight project values

Replace every `__DEV_TF_*__` token, then grep the prefix — a survivor is an
incomplete install.

| Token | Value |
|---|---|
| `__DEV_TF_TF__` | `tofu` unless args/repo say otherwise |
| `__DEV_TF_TF_VERSION__` | only consumed when `TF=terraform`; else drop the `tf:toolchain:show`/`:install`/`:use:ask` block — the `tf:toolchain:assert:tofu` guard stays |
| `__DEV_TF_TMP__` | reuse the repo's existing gitignored scratch dir, else `.task-tmp` |
| `__DEV_TF_BOOTSTRAP_PROJECT__` | the GCP project owning the state bucket — `tf_setup` enables `storage.googleapis.com` and creates the bucket there; leave empty when step 7 omits the setup block |
| `__DEV_TF_STATE_BUCKET__` | `tf_setup` fallback for a stack with no backend config at all (prefix = the stack name) |
| `__DEV_TF_STATE_LOCATION__` | e.g. `US` |
| `__DEV_TF_VARS_MAP__` | step 9 |
| `__DEV_TF_BACKEND_MAP__` | step 9 |

`DEBUG_LOG` ships pre-set to
`{{.ROOT_DIR}}/{{.TMP}}/{{.STACK}}-debug-{{.TF}}.log` — no token to fill in.

### 7. Read the backend type, and decide on `tf:setup`

The type is detected, never chosen and never argued: it is the label of each
`backend "<type>"` block step 2 located, and for a stack that keeps its
backend in a `*.backend.hcl`, `gcs` — that file names no type, and `gcs` is
what the toolkit reads it as.

**gcs**: keep the asset's `CONDITIONAL: gcs backend only` block, so `tf:setup`
and `tf:setup:all` ship, and fill `BOOTSTRAP_PROJECT`, `STATE_BUCKET` and
`STATE_LOCATION` in step 6. `tf:setup` drives `gcloud`, so note in the report
that it must be installed and authenticated; if it is missing, install anyway
and say `tf:setup` will refuse until it is present.

**Any other type**: omit that block, leave those three values empty, and say
in the report that the state bucket or container is provisioned out of band.
Nothing else changes — every other `tf:*` task is backend-agnostic, because
`init` only ever passes `-backend-config=<file>` through, or nothing at all
for a stack whose backend is inline.

**Greenfield writes the type into the stack too.** `assets/stack/backend.tf`
ships its `backend "<type>" {}` block with a `__DEV_TF_*__` placeholder in the
type slot, so the copy step 5 made at `stacks/<name>/backend.tf` does not parse
until the detected type is written in. Nothing else catches it: `tf:verify`
check 4 scans the Taskfile, `scripts/` and `docs/`, never `stacks/`.

### 8. Settle placement and extraction, per root module

**Placement.** For each root module the shape found, decide whether it already
sits at `stacks/<name>/` or needs to move there. List every one and its
proposed destination, present the list, move only after confirmation, one
stack at a time, `git mv` so history follows. Keep each backend's
`bucket`/`prefix` (or `key`) **unchanged** — the move is a refactor, not a
state migration. Never delete `.terraform*/` or a local `terraform.tfstate`
without asking (for a local backend, that file *is* the state). Move per-env
tfvars into `<stack>/variables/`.

**Extraction — only `shape-multi-env` and `shape-multi-both` need it.** A
module can hold one backend block, so per-environment state means a
`.backend.hcl` per environment plus a bare `backend "<type>" {}` to receive
them. Extracting an inline backend is therefore obligatory for those two
shapes and **only** those: move `bucket`/`prefix` (or `key`) out of the block
into `variables/<id>.backend.hcl` unchanged, reduce the block to
`backend "<type>" {}`, and ask before rewriting any `.tf`.

`shape-single` and `shape-multi-stack` **keep their inline backends exactly as
they are.** tf-stack reads an inline backend directly: `BACKEND` resolves to
the `.tf`, `init` runs without `-backend-config`, and `tf:stacks:list` /
`tf:backend` read the state location out of the block. Rewriting those `.tf`
files buys nothing and touches state configuration for no reason.

`shape-workspaces`: **stop**. Explain the one safe conversion (a
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

It looks like YAML and is not: the parser is `cut -d: -f2-`, and
`_normalize_spec` absorbs whitespace around the first colon and each comma
before it gets there. What still matters is **order**: written order is
precedence order, because tofu lets the last `-var-file` win. Confirm with
`task tf:vars:ids`, then `task tf:vars STACK=<s> VARS=<id>`, before moving on.

For each stack, list `variables/*.tfvars` and `variables/*.backend.hcl`.
Detect a shared base (`common`/`base`/`shared`/`global`) and put it **first**;
the environment file **last**. Prefer an explicit comma-separated list over a
glob whenever two files for one id must be ordered — a single glob expands
alphabetically.

Backend ids come from `variables/*.backend.hcl` basenames. **A stack whose
backend is inline needs no `BACKEND_MAP` entry** — `BACKEND_DEFAULT` finds the
`.tf` itself and names the id after the resolved `VARS_ID`. Add an entry only to pin it
(`<id>:main.tf`), and note that an id spelled into `BACKEND_MAP` is resolved
by path, so a `.tfbackend` or a path outside `variables/` works as written.

Two rules decide the `variables/<stack>.tfvars` question:

1. **`shape-multi-env`: MUST NOT** have a `variables/<stack>.tfvars`. A stack
   with several environments has no sensible default one, so a bare run must
   be refused rather than quietly picking an environment. Name the shared base
   `common.tfvars`, and populate both maps.
2. **`shape-single` or `shape-multi-stack`: SHOULD** have a
   `variables/<stack>.tfvars`, one per stack, and leave both maps empty.

**`shape-multi-both`** follows rule 1 per stack. The maps are global while
`variables/` is per stack, so reuse ids across stacks where the file names
agree, or namespace them (`app_dev`, `data_dev`) where they don't; the `:all`
tasks skip ids a stack has no backend config for.

Flag every file tofu auto-loads independently of `-var-file`, because
`task tf:vars` will not show it and the values still reach the plan:
`terraform.tfvars`, `terraform.tfvars.json`, and any `*.auto.tfvars` /
`*.auto.tfvars.json` at the module root.

`terraform.tfvars` is the one to look for hardest — it is the commonest tfvars
name at a module root, and it interacts with step 8's tfvars move. **Do not
move it silently.** Moving it into `variables/` stops the auto-load, so any
frozen CI step running `tofu -chdir=<stack> plan` with no `-var-file` loses
every value in it; leaving it means `task tf:vars` reports a var set that is
not the one applied. Present both options and let the user choose; if it
stays, say so in step 11 and add it to the front of that stack's `VARS_MAP`
entry so the two paths agree.

Present both maps for confirmation whenever there are more than two ids: this
is the one step that infers rather than copies.

### 10. Write the Taskfile block, the shims, gitignore, permissions, docs

`tf-replace`: delete **every** legacy `tf:*` task and legacy tf var in one
edit, then write the new block in the next — never merge a legacy var into
the new chain. `tf-add`: insert, preserving everything. `tf-refresh`: diff and
apply only differences; present anything ambiguous instead of changing it.

For each frozen CI name the new surface lacks: a **read-only name** (`tf:init`,
`tf:validate`, `tf:fmt`) gets an `aliases:` entry on the canonical task; a
**writing name** (`tf:apply`, `tf:destroy`) gets a **visible wrapper task**,
**plus its own permission rule written in this same step** (`Bash(task
tf:apply)` → `permissions.ask`; `Bash(task tf:destroy)` → `permissions.deny`)
— this is the whole point: `Bash(task *:ask)` matches the name typed, so a
shim without a rule silently restores an ungated apply.

**Write every shim as a shell wrapper, exactly like the `:all` tasks** — one
`task …` command line carrying the selectors, never a `cmds: [{task: …, vars:
{…}}]` call:

```yaml
  tf:apply:
    desc: CI compat shim for tf:apply:ask (remove after stabilization)
    cmds:
      - env -u TF_DATA_DIR task tf:apply:ask STACK=<s> VARS=<id>
```

A call-scoped `vars:` block propagates **one level only**. `tf:apply:ask`
opens with four nested `- task:` guard calls, so the structured form gives
`tf:apply:ask` the right `STACK` and then hands `tf:stack:assert`,
`tf:toolchain:assert:tofu`, `tf:vars:assert` and `tf:init:once` an **empty**
one: the guards validate the default stack, `tf:init:once` initialises the
default stack's backend, and the apply runs anyway. A selector passed on a
command line is a global, so it reaches every depth. `env -u TF_DATA_DIR` for
the same reason the `:all` loops carry it — `DATA_DIR` must be recomputed from
the shim's own `BACKEND_ID`, not inherited. `set-env-<env>` maps to one
ungated wrapper per env running `task tf:use STACK=<s> VARS=<env>`.

Merge `.gitignore` (each guarded by `grep -qxF`): `<TMP>/`, `.terraform*/`,
`.terraform.lock.hcl`, `*.env`, `*.tfplan`; confirm `<taskfile>.bckp` is
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
signal); artifacts installed; backup committed and CI
names frozen (confirmed from workflow files vs. taken on the user's word); the
eight values set (detected vs. asked vs. defaulted); `VARS_MAP`/`BACKEND_MAP` as
written, per id, with the files each resolves to (and, for a single-env repo,
that both are deliberately empty); the backend type detected, whether the
`tf:setup` block was emitted or omitted, and for gcs whether `gcloud` is
present; layout decision (already conventional vs. migrated into `stacks/`
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
  `stacks/` makes it a zero-iteration success — check the output, not
  just the exit code.
- **The plugin cache is version-keyed.** An edited asset is invisible until
  `plugins/dacbots/.claude-plugin/plugin.json`'s `version` is bumped and
  `/plugin marketplace update dacetplace` runs.
