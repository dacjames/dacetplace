---
name: dev-tf
description: Install or update the tf-stack terraform/opentofu toolkit (scripts/tf-stack.sh plus a go-task tf:* block with STACK/VARS/BACKEND selection, guards, and tf:secrets:* on GCP Secret Manager) in a repo. UPDATE, whenever the repo already has a dev-tf install - identifies the installed release, overwrites the toolkit-owned files, keeps the repo's own settings, retires local one-offs of features the release ships, verifies and reports. INSTALL otherwise - GREENFIELD, or MIGRATE a hand-rolled terraform Taskfile (tracked backup, CI task names kept behind gated shims); detects the repo's shape and each root module's backend, derives VARS_MAP/BACKEND_MAP from the files present, verifies offline with task tf:verify. Use when a repo needs terraform or opentofu tasks, to adopt the STACK/VARS/BACKEND convention, to migrate a repo's terraform tasks to dev-tf, to replicate tf-stack, or to update or upgrade dev-tf where it is installed ("update dev-tf in this repo"). Args: update, migrate, greenfield, tofu, terraform.
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
  - Bash(git log *)
  - Bash(git hash-object *)
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
  - Bash(task tf:secrets:assert*)
  - Bash(scripts/tf-stack.sh BACKEND_KIND*)
  - Bash(scripts/tf-stack.sh BACKEND_INLINE_FILE*)
  - Bash(bash scripts/tf-stack.sh help*)
  - Bash(cmp *)
  - Bash(diff *)
  - Bash(git diff *)
  - Bash(tofu version*)
---

# /dev-tf — replicate the tf-stack toolkit into a repo

Installs, or updates, three things this skill has already proven elsewhere: the
`tf:*` go-task block and its variable-resolution chain, `scripts/tf-stack.sh`
(the functions those tasks call by name), and the `<STACKS_DIR>/<name>/` layout
convention (`STACKS_DIR` defaults to `stacks`) that keeps each root module's
`variables/*.tfvars` and `*.backend.hcl` self contained. On top of that it adds
selection of a stack by name, guards that run before tofu ever touches a
backend, collision-free `TF_DATA_DIR`/plan file names across every stack × vars
× backend × toolchain combination, and secret management: a `variable` with
`sensitive = true` or `ephemeral = true` is a secret, stored one per variable in
GCP Secret Manager (`tf:secrets:*`). **This skill copies artifacts; it does not
regenerate them.** See [`/dev-tasks`](../dev-tasks/SKILL.md) for the base
Taskfile conventions and permission-rule mechanics, and
[`/dev-codify`](../dev-codify/SKILL.md) for why the logic ships as one dispatch
script rather than inline `cmds`.

Arguments: `$ARGUMENTS` — optional hints. Mode: `update` (update an existing
install), `migrate` (the migration path of INSTALL; what `update` used to mean),
`greenfield`; Modes says exactly what each does. Toolchain: `tofu`, `terraform`. With no args, detect both from the
repo. The backend is never an argument — it is read off the repo's own backend
configuration in step 2.

---

## What ships with this skill

| Source | Destination | How |
|---|---|---|
| `assets/tf-stack.sh` | `scripts/tf-stack.sh` | verbatim |
| `assets/taskfile-tf.yml` | merged into the Taskfile | templated, 8 tokens; includes the `tf:secrets:*` tasks |
| `assets/tf-verify.sh` | `scripts/tf-verify.sh` | verbatim |
| `assets/stack/*` | `<STACKS_DIR>/<name>/` | greenfield only |
| `assets/backends/gcs.hcl` | `variables/<id>.backend.hcl` | templated |
| `references/tf-stack.md` | `docs/tf-stack.md` | adapted |
| `references/migration.md` | read on demand (MIGRATE) | never copied |
| `references/releases.md` | read on demand (UPDATE) | never copied |
| `*.secret.tfvars`, `/secrets/` | `.gitignore` | two lines, each guarded by `grep -qxF` (step 10) |

`assets/tf-stack.sh` is the upstream `scripts/tf-stack.sh` minus five
functions specific to its home repo; the 89 that remain are the ABI: 31 core
names (selection, guards, init, setup), 31 that carry secret management
(`SECRETS_DISCOVER`, `_hcl_blocks`, `tf_secrets*`, 23 `_secrets_*` helpers),
and 27 that carry seeds and the nested-call wrapper (`SEED_TARGETS`,
`tf_seed*`, `tf_deploy_*`, the `_seeds_*`/`_deploy_*` helpers, and `task`).
`bash scripts/tf-stack.sh help` lists them. Every release since 0.3.0 carries
22 of them, which is how Modes tells a prior install, of any release, from a
hand-written script of the same name.

---

## What tf-stack is

Three parts: the `tf:*` tasks with their variable chain, seeds and the
two-phase deploy (`tf:seed*`, `tf:deploy:*`) among them (a misnamed var
silently no-ops a task), `scripts/tf-stack.sh` (the 15 uppercase resolvers,
every function a Taskfile `sh:` block calls by name, and `task`, the wrapper
every nested task call goes through), and one root module per stack under
`STACKS_DIR` (two stacks sharing a data dir or plan file corrupt each other's
plan/state silently).

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

Two modes, decided first, before any other detection:

| Mode | Signal | What it does |
|---|---|---|
| UPDATE | `scripts/tf-stack.sh` defines all 22 **base names**, the ABI every release since 0.3.0 carries (listed in `references/releases.md`, 0.3.0); a current install defines 89 | brings the existing install up to the current release — see "Updating an install" |
| INSTALL | everything else | puts the toolkit into a repo for the first time, on the two axes below; resolves to GREENFIELD or MIGRATE |

Check by reading before running: Grep `scripts/tf-stack.sh` for the base
names' definitions (`^<name>\(\)`). All 22 → a prior install, whatever
release; it is never INSTALL's to migrate, even though its Taskfile invokes
tofu. None → someone's own script; some → unclear: either way ask, and never
overwrite it silently. Only a prior install is run (`bash scripts/tf-stack.sh
help`, which prints to stderr and exits 1 by design).

`$ARGUMENTS` pick a mode. They never change what detection found, and an
argument can only add caution, never remove it:

- `update` on a repo with no prior install stops and says so, offering
  INSTALL and naming what it would resolve to (GREENFIELD or MIGRATE).
- `migrate` or `greenfield` on a repo with a prior install asks before going
  on, recommending UPDATE: MIGRATE would treat the installed `tf:*` block as
  legacy, back it up and re-derive every repo-owned value instead of carrying
  it.
- `migrate` on INSTALL runs MIGRATE even where detection says GREENFIELD, and
  reads a `tf-add` Taskfile as `tf-replace`: the user is saying terraform is
  driven from somewhere the detection grep cannot see (a task calling a
  wrapper script, make, terragrunt). Ask which tasks those are; they are the
  legacy surface that steps 3 and 10 freeze and replace. `tf-new` and
  `tf-replace` keep their detected value, and the shape axis is always
  detected.
- `greenfield` on INSTALL is a check, not an override. If detection says
  GREENFIELD, go on. If it says MIGRATE, stop, name the signals that made it
  so (the Taskfile's terraform tasks, the modules that need moving), and ask.
  It never skips MIGRATE's backup, CI-name freeze or move confirmation.

Announce the resolved mode, and for INSTALL each axis with its detected value
and anything an argument changed, before writing anything.

### INSTALL: the two axes

*Taskfile axis* — governs rollback and CI obligations:

| Signal | Value | Obligations |
|---|---|---|
| no `Taskfile.{yml,yaml}` | `tf-new` | none; write freely |
| a Taskfile with no task invoking `terraform`/`tofu` | `tf-add` | backup; leave every non-tf task untouched |
| a Taskfile with tasks invoking `terraform`/`tofu`, **under any name** | `tf-replace` | backup, frozen CI-name list, remove-then-replace |

*Shape axis* — **which pattern the repo already uses**, hence what stack
structure it is installed as. This is a detection, not a decision: two counts,
root modules and backends per root module. Step 2 says how to get them.

| Root modules | Backends each | Value | Installs as |
|---|---|---|---|
| — (no `*.tf`) | — | `shape-none` | scaffold `<STACKS_DIR>/main/` (default `stacks/main/`) |
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

*Placement* follows from the shape and is settled per root module in step 8.
`STACKS_DIR` (a Taskfile var, default `stacks`) names the **one** dir every
stack lives under — a repo-wide knob, not a per-stack one. Modules that
already sit together under one consistent dir (`terraform/`, `infra/`,
`live/`) are **already placed**: `STACKS_DIR` points at that dir as-is, or it
is renamed to `stacks/` (step 8 asks which). What still forces a move is a
module whose `.tf` files sit directly in that shared parent, most often the
repo root, with no name of its own (a dir cannot be both the list of stacks
and a stack's own files), or modules that share no common parent. This is
never a reason to skip the inspection above.

`GREENFIELD = tf-new + (shape-none | every root module already placed)`.
Everything else is MIGRATE. Ambiguity → AskUserQuestion, never a guess.

---

## Conventions (non-negotiable — copy, do not re-derive)

1. **Copy, never retype.** `cp` byte-for-byte; `tf-stack.sh` has no editable
   region, and nothing in it is meant to be adjusted per repo.
2. **The variable chain is adopted whole.** All 46 `vars:` entries (the six secrets and three seeds ones among them), all of them or none —
   adopting the chain piecemeal is fragile: a var the anchor lacks reads as an
   empty string in the script.
3. **Names are an ABI.** The 15 uppercase resolvers are called by exact string
   from `sh:` blocks and dispatched by `declare -F`; renaming one breaks
   variable evaluation for every task with an opaque `unknown command`.
4. **Every nested task call goes through `scripts/tf-stack.sh task`.** A task
   that runs `task` from its shell (the `:all` loops, the seeds and deploy
   loops, a CI shim) must call `scripts/tf-stack.sh task …`, never bare
   `task` or `env -u TF_DATA_DIR task`, and carries `env: *tf_stack_env` so
   the wrapper has the `V_*` to read. go-task lets an inherited variable beat a
   task's own `env:` block, so the wrapper clears every `V_*` and `TF_DATA_DIR`
   for the child to recompute. A child process sees none of the caller's
   command-line vars, so it passes the run-wide selectors in `TASK_FORWARD`
   (`TF`, `NO_LOCK`, `STACKS_DIR`, …) on again. Both failures are
   silent-wrong-answer, not errors: a prod iteration planning against dev's
   data dir, or `TF=terraform` planning with tofu.
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

## Migration safety rules (MIGRATE only)

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

### 1. Locate this skill's assets (both modes)

Resolve in this order, stopping at the first hit:

1. `${CLAUDE_PLUGIN_ROOT}/skills/dev-tf/`
2. `ls ~/.claude/plugins/cache/*/dacbots/*/skills/dev-tf/` (the cache keeps
   old versions too: take the highest)
3. `~/.claude/plugins/marketplaces/*/plugins/dacbots/skills/dev-tf/`
4. `*/plugins/dacbots/skills/dev-tf/` under this repo
5. else ask the user where the skill lives.

Confirm all five `assets/` entries exist under the resolved path before
touching the target repo (`tf-stack.sh`, `taskfile-tf.yml`, `tf-verify.sh`,
plus `stack/` and `backends/`). A partial `assets/` dir means a stale
version-keyed cache — tell the user to bump `plugin.json` and run `/plugin
marketplace update dacetplace`.

For each asset, **Read it from the resolved path and Write it into the target
repo** — this does not depend on `${CLAUDE_PLUGIN_ROOT}` resolving inside a
`Bash` invocation, which this skill has not verified. Fall back to `Bash(cp *)`
only once the resolved source path is confirmed on disk. **Never reconstruct a
missing asset from memory**: a missing or truncated file at every candidate
means stop and ask.

---

## Updating an install (UPDATE)

Brings a repo that already has a dev-tf install up to this skill's current
release. After step 1 it follows its own steps, U1–U7, not steps 2–11, and
none of MIGRATE's machinery: no backup, no CI-name freezing, no shape
detection, no placement moves, no map derivation — unless a release entry in
`references/releases.md` says it requires one. It makes no cloud call and runs
no `tf:secrets:*` task that writes; everything it changes stays in the working
tree for review.

| Category | What | On update |
|---|---|---|
| Toolkit-owned | `scripts/tf-stack.sh`, `scripts/tf-verify.sh`; every anchor key, `env:` key, var and task the shipped block defines (`tmp:setup` included) and any a release dropped; the block's `.gitignore` lines; `docs/tf-stack.md` | **The release wins.** Overwrite without asking; list local edits that were overwritten in the report |
| Repo-owned | the eight project values (INSTALL step 6); the `STACKS_DIR`, `SECRETS_PROJECT`, `SECRET_PREFIX`, `SECRETS_DIR`, `NO_COLOR` and `NO_LOCK` settings; `VARS_MAP`/`BACKEND_MAP`; which CONDITIONAL sections the install kept (dual-toolchain, gcs `tf:setup`) and whether it dropped the five gcloud secrets tasks; CI compat shims, the `aliases:` it added to shipped tasks, and their permission rules; non-tf tasks; the stacks themselves | **Kept**, except what a release entry's **Replaces** names in them |
| Local one-offs of a shipped feature | e.g. hand-rolled `secrets:*` tasks and `secrets/manifest.txt` from the older dacbots `dev-secrets` skill, `*.secret.tfvars` entries in `VARS_MAP`, a local patch to `tf-stack.sh` | **The release wins.** Remove and replace; report what was retired and flag any behaviour the shipped version lacks |
| Extra local `tf:*` tasks the block doesn't ship | | Kept, and checked against the new var chain |

A setting is repo-owned when its value differs from the shipped default; where
a release renamed one, carry the value to the new name. Where two rows claim
one thing, the release entry wins: for example `VARS_MAP` is kept, minus its
`*.secret.tfvars` entries.

**U1. Identify the installed release** from the signatures in
`references/releases.md`; its header says how (`git hash-object
scripts/tf-stack.sh` against each entry's blob is exact for an unedited
script). The releases newer than it are the ones being applied; the later
steps read their entries. A script defining names the newest entry lacks is
either locally patched (its history, as in U3, shows a local commit adding
them) or an install newer than this skill: then stop and tell the user to
update the plugin, since a downgrade is not an update.

**U2. Short-circuit.** The install is current when the installed release is
the newest entry, both scripts match their assets byte for byte (`cmp`), the
Taskfile's toolkit-owned vars and tasks match the block's filled with the
repo's values, no `__DEV_TF_*__` token survives, no "Replaces" grep (U3) finds
a one-off, and `task tf:verify` passes. Report that and stop.

**U3. Inventory the target** into the four categories; nothing is written yet.

- Diff each toolkit-owned file against its asset (`diff`). A script whose blob
  matches no entry carries a local patch. The diff against the current asset
  mixes it with the releases' own changes; the repo's history (`git log -p --
  scripts/tf-stack.sh`, the commits after the one that installed it) shows
  what the patch did.
- Compare the Taskfile's anchor keys, vars and tasks with the block's by name,
  plus those the applied entries say a release dropped. A `tf:*` task the
  block does not define is an extra, unless `docs/tf-stack.md`'s
  **Migration** section lists it as a CI shim.
- Run the "Replaces" greps of **every** entry in `releases.md`, not only the
  applied ones: a one-off can be added after the install. A hit inside the
  shipped block is the block, not a one-off.
- Grep CI (the files INSTALL step 3 lists) for each one-off's name.

**U4. Require a clean tree** for every file U5 will touch: the scripts, the
Taskfile, `.gitignore`, `docs/tf-stack.md`, and each file a one-off lives in.
`git status` must show none of them modified or untracked; git is the only
record of what the update overwrites, and it stands in for MIGRATE's tracked
backup. Otherwise stop, name the files, and ask the user to commit or stash
them. Never write over uncommitted changes, even when they look unrelated.

**U5. Apply per the table.**

- Copy both scripts as INSTALL step 5 does.
- Rebuild the block from the asset (from `# ---- BEGIN SPLICE ----`) with the
  CONDITIONAL sections the install kept; fill each repo-owned value from the
  Taskfile as it stands rather than asking (a renamed one under its new name);
  put back the `aliases:` the install added. Replace the old block's anchor,
  `env:` keys, vars and tasks with it where they stand, leaving every other key
  and task.
- Merge the `.gitignore` lines INSTALL step 10 lists, each guarded by
  `grep -qxF`.
- Regenerate `docs/tf-stack.md` as INSTALL step 10 does, keeping its appended
  **Migration** section.
- Retire each one-off as its release entry says: remove it and put in its
  replacement. One that CI calls is the exception: ask first (retire it and
  rewrite the CI call now, or keep it and report it as pending), since removing
  it breaks CI until the replacement works there — for `dev-secrets`, until the
  per-variable secrets exist.
- Never loosen a gate: nothing that stays loses its `:ask`/`:deny` suffix, and
  every shim keeps its permission rule (convention 8). Removing a retired
  one-off loosens nothing.

**U6. Verify offline:** `task tf:verify` (all checks that need no network;
name any skipped), `task tf:vars` and `task tf:backend` for each map id,
`task tf:stacks:list`, `task tf:secrets:assert`, and `task tf:fmt:check` /
`task tf:validate:local` where stacks exist. Extras must still resolve against
the new var chain; grep for `__DEV_TF_` and fix any survivor.

**U7. Report:** release from → to; local edits to toolkit-owned files that
were overwritten (a script patch as U3 found it, the rest summarised from
`git diff`); one-offs retired, any kept at the user's word, and any behaviour
the shipped version lacks; extras kept and whether they still work; the
post-update steps from each applied release's entry (what the user runs
themselves); `task tf:verify` PASS/FAIL; then the caveats below that an
applied release introduced. Leave the changes uncommitted for review.

## Installing (INSTALL): steps 2–11

### 2. Detect both INSTALL axes

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

**Toolchain floor for secrets.** Ephemeral input variables need OpenTofu
>= 1.11 or Terraform >= 1.10, and `tf:secrets:new:ask` declares its variables
`sensitive = true` **and** `ephemeral = true` without checking either the
toolchain or the stack's `required_version`. Read the toolchain off the repo:
`tofu version` (offline), or for terraform the `TF_VERSION` var,
`.terraform-version` or the stack's `required_version`, since `terraform
version` phones home. Record whether it clears the floor and what each stack's
`required_version` allows (greenfield `assets/stack/versions.tf` ships `>=
1.7.0`, deliberately: a stack with no secrets runs on older tofu). Below the floor, secrets still work with variables
declared `sensitive = true` alone, by hand, which leaves the value in state and
plan files; say so in step 11 rather than raising anyone's `required_version`.

**Both Taskfile spellings count.** `Taskfile.yml` and `Taskfile.yaml` are
equally valid to go-task; read "the Taskfile" below as whichever this repo has,
or a `.yaml` repo reads as `tf-new` and gains a second, shadowing Taskfile.

**The `tf-replace` signal is behaviour, not namespace.** A repo whose
terraform tasks are named `init`, `plan`, `apply`, `otel-plan` is `tf-replace`,
not `tf-add`: grep the Taskfile for `terraform`/`tofu` invocations, not for a
`tf:` prefix, or a complete second terraform surface is installed beside the
first. Report surviving legacy un-namespaced names in step 11, and check
whether `.claude/settings.local.json` already allowlists them (`Bash(task
plan)`): ungated names that convention 8 assumes do not exist.

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
Present the count with the layout plan; it is usually the real cost of a move.
If no CI config lives in this repo, say so, ask the user, and fall back to
`references/migration.md` §1's shape **only as a labelled assumption**.
Everything not on the list is explicitly allowed to break — state that back to
the user; it is what makes step 10's remove-then-replace affordable.

### 4. Back up the Taskfile (`tf-add`/`tf-replace` only)

`cp <taskfile> <taskfile>.bckp` (the spelling the repo uses), `git add` it, and
verify with `git check-ignore -q <taskfile>.bckp` (must fail) and `git ls-files
--error-unmatch <taskfile>.bckp` (must succeed) — a gitignored backup cannot
satisfy `references/migration.md` §5's "commit the backup, remove it after a
stabilization period." An existing `.bckp` belongs to an earlier migration: ask
before replacing it. Record the backup path and the removal criterion (one green
CI run on every frozen name) for step 10's migration note.

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
| `__DEV_TF_BOOTSTRAP_PROJECT__` | the GCP project owning the state bucket — `tf_setup` enables `storage.googleapis.com` and creates the bucket there; also the default `SECRETS_PROJECT`, the project the secrets live in. Leave empty only when step 7 omits the setup block **and** the repo has no GCP project for secrets; then set `SECRETS_PROJECT` explicitly (the secrets tasks do not check it) |
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
in the report that the state store is provisioned out of band. Nothing else
changes: every other `tf:*` task is backend-agnostic, because `init` only
passes `-backend-config=<file>` through, or nothing for an inline backend.

**Secrets are GCP Secret Manager whatever the state backend is.** The
`tf:secrets` report and `:setup`, `:new`, `:pull:ask`, `:push:ask` drive
`gcloud` against `SECRETS_PROJECT`, so the report notes it must be installed and
authenticated. `tf:secrets:assert` is offline and stays in every repo, because
plan, apply, refresh and destroy call it; with no secret declared it passes. A
repo not using GCP drops the five gcloud tasks and keeps the guard.

**Greenfield writes the type into the stack too.** `assets/stack/backend.tf`
ships a `__DEV_TF_*__` placeholder in its `backend "<type>" {}` type slot, so
the copy at `<STACKS_DIR>/<name>/backend.tf` does not parse until the detected
type is written in. Nothing else catches it: `tf:verify` check 4 never scans
`STACKS_DIR`.

### 8. Settle placement and extraction, per root module

**Placement.** Two directories, both discovered before anything moves:

- **`IMPLIED_STACKS_DIR`** — the closest thing to a stacks root the repo
  already has: the one parent directory every root module the shape found
  already shares. For `shape-multi-stack`/`shape-multi-both` this is usually
  a real subdirectory (`terraform/`, `infra/`); for `shape-single`/
  `shape-multi-env` (one root module) it is that module's own parent, which
  is frequently the repo root itself.
- **`IMPLIED_MAIN_STACK_DIR`** — the directory actually holding a root
  module's own `.tf` files: one per module for `shape-multi-stack`/
  `shape-multi-both`, or the repo's one root module's directory for
  `shape-single`/`shape-multi-env`.

**`IMPLIED_STACKS_DIR` and `IMPLIED_MAIN_STACK_DIR` must never be the same
directory** — one dir cannot be both the list of stacks and a stack's own
files.

- **Conforming** (`IMPLIED_STACKS_DIR` ≠ `IMPLIED_MAIN_STACK_DIR` — the
  common `shape-multi-stack` case, and any `shape-single`/`shape-multi-env`
  repo whose one module already sits in a named subdirectory): no module
  needs to move. Renaming `IMPLIED_STACKS_DIR` itself is optional — ask the
  user:
  1. **Do nothing** — point `STACKS_DIR` at `IMPLIED_STACKS_DIR` as it
     already is, by editing its default in the spliced Taskfile block
     (`STACKS_DIR: '{{.STACKS_DIR | default "stacks"}}'`).
  2. **Rename to the conventional `stacks/`** — `git mv
     <IMPLIED_STACKS_DIR> stacks`, and `STACKS_DIR` stays the shipped
     default.
- **Non-conforming** (`IMPLIED_STACKS_DIR` = `IMPLIED_MAIN_STACK_DIR` — the
  common `shape-single`/`shape-multi-env` case, where the one module's `.tf`
  files sit directly at what would be `STACKS_DIR`, usually the repo root):
  what's missing is a name, not a directory. Infer `IMPLIED_STACK` from repo
  context — the repo's own name is usually it, e.g. a repo named
  `tf-gcp-networking` implies `gcp-networking` — and **always confirm it
  with the user**, never assume silently. Then present exactly two moves and
  let the user pick (tweak the wording to the repo's actual context):
  1. **Convert to the standard layout** — `STACKS_DIR='stacks'`,
     `STACK='<IMPLIED_STACK>'`; the module moves two levels, from the repo
     root into `stacks/<IMPLIED_STACK>/`.
  2. **Keep the root as `STACKS_DIR`** — `STACKS_DIR='.'`,
     `STACK='<IMPLIED_STACK>'`; the module moves one level, from the repo
     root into `<IMPLIED_STACK>/`, with no `stacks/` wrapper introduced.

Once `STACKS_DIR` is settled: for each root module, decide whether it already
sits at `STACKS_DIR/<name>/` or needs the proposed move there. List every one
and its proposed destination, present the list, move only after confirmation,
one stack at a time, `git mv` so history follows. Keep each backend's
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
they are.** tf-stack reads an inline backend directly (`BACKEND` resolves to the
`.tf`, `init` runs without `-backend-config`, `tf:stacks:list` and `tf:backend`
read the state location out of the block), so rewriting those `.tf` files
touches state configuration for no reason.

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

What matters is **order**: written order is precedence order, because tofu lets
the last `-var-file` win. Confirm with `task tf:vars:ids`, then `task tf:vars
STACK=<s> VARS=<id>`, before moving on.

For each stack, list `variables/*.tfvars` and `variables/*.backend.hcl`.
Detect a shared base (`common`/`base`/`shared`/`global`) and put it **first**;
the environment file **last**. Prefer an explicit comma-separated list over a
glob whenever two files for one id must be ordered — a single glob expands
alphabetically.

Backend ids come from `variables/*.backend.hcl` basenames. **A stack whose
backend is inline needs no `BACKEND_MAP` entry** — `BACKEND_DEFAULT` finds the
`.tf` itself and names the id after the resolved `VARS_ID`. Add an entry only to
pin it (`<id>:main.tf`); an id spelled into `BACKEND_MAP` is resolved by path,
so a `.tfbackend` or a path outside `variables/` works as written.

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

**Never write a `*.secret.tfvars` into a `VARS_MAP` line.** `VAR_FILES` appends
the current `variables/<vars_id>.secret.tfvars` itself, last and once. Grep the
existing maps and `variables/` for one first; `references/migration.md` §6 says
how to take it out.

Flag every file tofu auto-loads independently of `-var-file`, because
`task tf:vars` will not show it and the values still reach the plan:
`terraform.tfvars`, `terraform.tfvars.json`, and any `*.auto.tfvars` /
`*.auto.tfvars.json` at the module root.

`terraform.tfvars` is the one to look for hardest, and it interacts with step
8's tfvars move. **Do not move it silently.** Moving it into `variables/` stops
the auto-load, so a frozen CI step running `tofu -chdir=<stack> plan` with no
`-var-file` loses every value in it; leaving it means `task tf:vars` reports a
var set that is not the one applied. Present both options; if it stays, say so
in step 11 and add it to the front of that stack's `VARS_MAP` entry so the two
paths agree.

Present both maps for confirmation whenever there are more than two ids: this
is the one step that infers rather than copies.

### 10. Write the Taskfile block, the shims, gitignore, permissions, docs

`tf-replace`: delete **every** legacy `tf:*` task and legacy tf var in one
edit, then write the new block in the next — never merge a legacy var into
the new chain. `tf-add`: insert, preserving everything.

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
    env: *tf_stack_env
    cmds:
      - scripts/tf-stack.sh task tf:apply:ask STACK=<s> VARS=<id>
```

A call-scoped `vars:` block propagates **one level only**: `tf:apply:ask` opens
with four nested `- task:` guard calls, so the structured form hands
`tf:stack:assert`, `tf:toolchain:assert:tofu`, `tf:vars:assert` and
`tf:init:once` an **empty** `STACK` — the guards validate the default stack and
the apply runs anyway. A selector on a command line is a global and reaches
every depth. `scripts/tf-stack.sh task` for the same reason the `:all` loops
use it (convention 4): `DATA_DIR` must be recomputed from the shim's own
`BACKEND_ID`, and a `TF=` given to the shim must reach the apply.
`set-env-<env>` maps to one ungated wrapper per env running `task tf:use
STACK=<s> VARS=<env>`.

Merge `.gitignore` (each guarded by `grep -qxF`): `<TMP>/`, `.terraform*/`,
`.terraform.lock.hcl`, `*.env`, `*.tfplan`, `*.secret.tfvars`, `/secrets/`
(the last two are also appended by `tf:secrets:setup` and `:pull:ask`; committed
here so a fresh clone is safe before anyone runs them. `/secrets/` is
`/<SECRETS_DIR>/` for the `SECRETS_DIR` in effect, anchored to the root so a
module directory called `secrets/` is not ignored; a tracked `dev-secrets` `secrets/manifest.txt` has
to be resolved first, `references/migration.md` §6 step 4); confirm
`<taskfile>.bckp` is **not** matched. Merge `.claude/settings.local.json`:
`Bash(task *:ask)` / `Bash(task *:deny)` (delegate to `/dev-tasks` step 5 if
absent) plus the shim rules; **write no raw `Bash(tofu…)`/`Bash(terraform…)`/
`Bash(gcloud…)` allow**, and if one already exists, surface it as the run's
most important finding.

Copy `references/tf-stack.md` → `docs/tf-stack.md`, re-pointing examples at
this repo's stacks and dropping inapplicable shape sections; append a
**Migration** section recording the mode pair, frozen CI names and where they
came from (found vs. assumed), every shim with its rule, the backup path, and
the removal criterion. The migration record is an output file for the user,
not a chat message.

### 11. Report

Summarize: GREENFIELD or MIGRATE, and the mode pair behind it (each axis, its
detected value and signal, and anything an argument changed); artifacts installed; backup committed and CI names frozen (confirmed
from workflow files vs. taken on the user's word); the eight values set
(detected vs. asked vs. defaulted); `VARS_MAP`/`BACKEND_MAP` as written, per id,
with the files each resolves to (and, for a single-env repo, that both are
deliberately empty); the backend type detected, whether the `tf:setup` block
was emitted or omitted, and for gcs whether `gcloud` is present; layout
decision (`STACKS_DIR` value, already conventional vs. pointed at an existing
dir vs. migrated via `git mv` vs. stopped on workspaces); legacy tasks removed,
kept, or shimmed, each shim with its permission rule; `task tf:verify` PASS/FAIL
lines with any check skipped for lack of network named explicitly; the
toolchain against the ephemeral floor (tofu >= 1.11 / terraform >= 1.10) and
what each stack's `required_version` allows; the `SECRETS_PROJECT` in effect;
the first commands for the user to run themselves (`task tf:setup:all
STACK=…`, then `task tf:plan STACK=… VARS=…`) and, for secrets, `task
tf:secrets:setup` once, then `task tf:secrets:new:ask STACK=… VARS=… ID=<var>`
per secret (needs `gcloud`, `roles/secretmanager.admin`, a toolchain at or above
the floor and a `required_version` that allows `ephemeral`; a clone that only
plans needs `tf:secrets:pull:ask` and `roles/secretmanager.secretAccessor`). End
with the caveats below.

---

## Caveats to surface to the user

- **A shim or alias reopens the gate.** Exposing a gated `:ask`/`:deny` task
  under a new name grants nothing on its own, but forgetting the paired
  permission rule silently restores an ungated apply/destroy.
- **Never allowlist `tofu`, `terraform`, or `gcloud` directly.** Every safe
  path runs through a gated `task` name; a raw binary allow bypasses every
  guard this skill installs.
- **`tf:apply:ask` applies a saved plan and passes the var files again.** A
  saved plan holds no ephemeral value, so tofu needs them at apply; a changed
  non-ephemeral value is refused (`Mismatch between input and plan variable
  value`), an ephemeral one is taken as given. Pull before applying, not only
  before planning.
- **`tf:secrets:assert` is a guard, not a fetch.** It fails when a required
  secret is not on the machine and never calls the cloud; `tf:secrets:pull:ask`
  is the fix it names. `tf:secrets:new:ask` is gated by `Bash(task *:ask)` like
  `pull:ask` and `push:ask`.
- **File secrets share one directory.** `SECRETS_DIR` (default `secrets`) is
  relative to the repo root, one per repo; a bare `file = "sa.json"` lands in
  `<SECRETS_DIR>/<stack>/<vars_id>/`, and the variable holds the path from the
  stack directory (`../../secrets/app/dev/sa.json`). It is git-ignored as
  `/<SECRETS_DIR>/`; an empty, absolute or `..` value is refused.
- **Ephemeral has a cost.** The value may feed only providers and write-only
  (`*_wo`) arguments; otherwise drop `ephemeral = true` by hand and accept the
  value in state (`references/tf-stack.md`, "Ephemeral by default").
- **`VARS=id:glob` bypasses the map entirely.** An explicit glob on the CLI
  skips `VARS_MAP` lookup and its ordering guarantees — useful for one-off
  debugging, risky as a habit.
- **Nested task calls go through the wrapper.** A hand-written loop or shim
  that runs bare `task` from its shell inherits the caller's `V_*` and
  `TF_DATA_DIR` and loses its command-line selectors. Use `scripts/tf-stack.sh
  task …` (convention 4), even where a bare call looks like it works.
- **`tf:use` gitignores `*.env`, not `<stack>.env`.** Any file ending `.env`,
  anywhere in the repo, is covered by the same gitignore line; that is
  intentional, not a narrower per-stack rule.
- **`task tf:validate:all` can pass while validating nothing.** An empty
  `STACKS_DIR` (default `stacks/`) makes it a zero-iteration success — check
  the output, not just the exit code.
- **The plugin cache is version-keyed.** An edited asset is invisible until
  `plugins/dacbots/.claude-plugin/plugin.json`'s `version` is bumped and
  `/plugin marketplace update dacetplace` runs.
