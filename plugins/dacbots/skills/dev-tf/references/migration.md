# Migrating an existing Taskfile (MIGRATE)

This is the MIGRATE path of `/dev-tf`'s INSTALL mode; updating a repo that
already has a dev-tf install is UPDATE, which does not follow it and reads
only §6 (see `references/releases.md`). It applies whenever `Taskfile.yml`
already has tasks that invoke `terraform`/`tofu`, under any name (mode
`tf-replace`), or already has other tasks but none that do (mode `tf-add`). The
goal: replace whatever tf tooling exists today with the full tf-stack surface,
without breaking anything CI actually calls, and without moving any stack's
state.

## 1. Discover the CI interface

Before touching `Taskfile.yml`, find every name that is called from
outside a human's terminal — that list is frozen and everything else is
allowed to break. Grep, in this repo, for `task <name>` and for direct
`terraform`/`tofu` invocations:

```
.github/workflows/**
.gitlab-ci.yml
.circleci/config.yml
.buildkite/**
atlantis.yaml
Makefile
scripts/*.sh
```

If no CI configuration lives in this repo at all — a shared runner, a
platform team's pipeline, anything you cannot read — say so plainly and
ask the user. Only fall back to the shape below as a **labelled
assumption**, never as a silent default:

```
set-env-<env>
tf:init
tf:plan
tf:apply
```

That shape is small on purpose: real CI usually calls only a handful of
names, and stating that back to the user up front is what makes the
"remove every legacy task, then replace" approach in step 2 affordable —
anything not on the frozen list was never a compatibility obligation.

## 2. Frozen name → task → shim → permission rule

For each frozen name the new `tf:*` surface does not already provide
under that exact spelling, add the smallest shim that restores it —
and, if the shim exposes something that writes, its own permission rule
**in the same edit**. A shim with no rule is not a smaller change, it is
a hole: `Bash(task *:ask)` matches the command text typed, and knows
nothing about what a wrapper task's `cmds:` actually run.

| Frozen CI name | Canonical `tf:*` task | Shim | Permission rule |
| --- | --- | --- | --- |
| `tf:init` | `tf:init:once` | `aliases:` on the canonical task | none — read-only |
| `tf:validate` | `tf:validate` | already the canonical name | none |
| `tf:fmt` | `tf:fmt` | already the canonical name | none |
| `tf:apply` | `tf:apply:ask` | visible wrapper task, `desc: 'CI compat shim for tf:apply:ask -- remove after stabilization'`, `env: *tf_stack_env` and one shell command line `scripts/tf-stack.sh task tf:apply:ask STACK=<s> VARS=<id>` (never `cmds: [{task: …, vars: …}]`, whose vars do not reach the guards; SKILL.md step 10) | `Bash(task tf:apply)` in `permissions.ask` |
| `tf:destroy` | `tf:destroy:deny` | visible wrapper task, same shape, worded for destroy | `Bash(task tf:destroy)` in `permissions.deny` |
| `set-env-<env>` | `tf:use STACK=<s> VARS=<env>` | one ungated wrapper task per env running that command | none — writes only a local, gitignored `<stack>.env` file |

Two shim shapes only, chosen by whether the frozen name **writes**:

- **Read-only names** (`tf:init`, `tf:validate`, `tf:fmt`) become
  `aliases:` entries on the task that already does the work. An alias is
  just a second name for the same task — nothing new to gate.
- **Writing names** (`tf:apply`, `tf:destroy`) become their own small,
  *visible* task (never an alias, so it shows in `task --list` with a
  `desc:` explaining it is temporary) whose one `cmds:` line delegates to
  the gated canonical task. Because the delegate is reached by its own
  wrapper name, not the `:ask`/`:deny`-suffixed one, the wrapper needs
  its own permission rule naming *that* command string — this is the
  entire reason the table's third column exists.

`set-env-<env>` is neither an alias nor a delegation to a gated task: it
just writes a `tf:use` selection, which is itself ungated (it only
writes a gitignored `<stack>.env` file, never state), so no rule is
added for it.

## 3. Move the layout

`STACK_DIR` is `STACKS_DIR/{{.STACK}}` (`STACKS_DIR` a Taskfile var,
defaulting to `stacks`), and stack discovery globs `STACKS_DIR/*/` — so the
root every stack lives under is a single, repo-wide setting, not a hardcoded
path.

Discover two directories before deciding anything:

- **`IMPLIED_STACKS_DIR`** — the one parent directory every root module found
  in step 2 already shares (that module's own directory, if there is exactly
  one).
- **`IMPLIED_MAIN_STACK_DIR`** — the directory actually holding a root
  module's own `.tf` files (one per module, if there are several).

**They must never be the same directory** — one dir cannot be both the list
of stacks and a stack's own files.

- **Conforming** (they already differ — the common multi-stack case, and any
  single-module repo whose module already sits in a named subdirectory): no
  module needs to move. Renaming `IMPLIED_STACKS_DIR` itself is optional —
  ask the user:
  1. Do nothing — point `STACKS_DIR` at `IMPLIED_STACKS_DIR` as it already
     is, by editing its default in the spliced Taskfile block (`STACKS_DIR:
     '{{.STACKS_DIR | default "stacks"}}'`).
  2. Rename to the conventional `stacks/` — `git mv <IMPLIED_STACKS_DIR>
     stacks`, and `STACKS_DIR` stays the shipped default.
- **Non-conforming** (they are the same — the common single-stack case,
  usually the repo root holding the one module's `.tf` files directly): a
  name is missing, not a directory. Infer `IMPLIED_STACK` from repo context
  (the repo's own name is usually it, e.g. `tf-gcp-networking` implies
  `gcp-networking`) and **always confirm it with the user**, never assume
  silently. Then offer exactly two moves and let the user pick:
  1. `STACKS_DIR='stacks'`, `STACK='<IMPLIED_STACK>'` — the standard layout;
     the module moves two levels, into `stacks/<IMPLIED_STACK>/`.
  2. `STACKS_DIR='.'`, `STACK='<IMPLIED_STACK>'` — the root stays
     `STACKS_DIR`; the module moves one level, into `<IMPLIED_STACK>/`.

Either way, this is a refactor, never a state migration — the checklist
exists to keep it that way:

1. **List every root module** and its proposed destination. Present the
   full list before moving anything.
2. **Confirm with the user**, then move **one stack at a time** with
   `git mv`, so history follows the files.
3. **Keep each backend's state address unchanged** — `bucket`/`prefix`,
   or whichever keys its type names. The directory moves; the state
   address it points at does not.
4. **Never delete `.terraform*/` or a local `terraform.tfstate`** as
   part of the move, without asking first — for a local backend, that
   file *is* the state, and for a remote one the cached provider
   directory is expensive but not dangerous to lose, so the two need
   different confirmations.
5. **Move per-env tfvars into `<stack>/variables/`.** Extract an inline
   backend **only when the stack needs more than one environment** —
   `shape-multi-env` and `shape-multi-both`. A module holds one backend
   block, so per-environment state means moving the address keys out of
   the `.tf` into `variables/<id>.backend.hcl` unchanged and leaving the
   block bare as `backend "<type>" {}`. Ask before rewriting any `.tf`
   file — this step touches code, not just paths.
   A single-stack or multi-stack repo **keeps its inline backends as they
   are**: tf-stack resolves `BACKEND` to the `.tf` and inits without
   `-backend-config`, so rewriting them changes state configuration for
   no gain.
6. **Re-run discovery** (`task tf:stacks:list`, `task tf:vars`) after
   the move and confirm the state string is unchanged from before the
   move, not just present.

## 4. Workspaces: stop and ask

Detected by any of: a `.terraform/environment` file, `terraform.workspace`
referenced in any `*.tf`, or a `-workspace`/`TF_WORKSPACE` argument in
CI. When any of these are present, **stop** rather than propose a full
conversion — workspaces put one state split many ways with the
environment invisible in the code, and getting that migration wrong
loses state, not just organization.

The one conversion that is safe to propose is additive, not
destructive: one `BACKEND_MAP` id per existing workspace, whose
`backend.hcl` points at that workspace's *existing* state path
unchanged — for a GCS-backed workspace, that means a prefix shaped like
`prefix = "<old-prefix>/env:/<workspace-name>"`, matching where
Terraform already stores workspace state under the hood. Nothing is
copied and nothing is deleted; the new id is just a name for a path
that already exists.

Before treating that as done:

- **Require the user to verify it themselves** with a zero-change plan
  per workspace (`task tf:plan STACK=<s> VARS=<workspace-id>` should
  show no diff against the workspace's last known-good state).
- **Never run `terraform workspace delete`** as part of this or any
  later cleanup — that command is destructive to the old access path
  and is not this skill's decision to make.

## 5. Rollback

Before any edit in `tf-add`/`tf-replace` mode, `Taskfile.yml` is copied
to `Taskfile.yml.bckp` and **committed, not gitignored** — a gitignored
backup cannot satisfy "commit the backup, remove it after a
stabilization period," because it would never appear in the diff a
reviewer or a future rollback depends on. Verify both properties before
relying on it:

```
git check-ignore -q Taskfile.yml.bckp   # must fail (exit 1): not ignored
git ls-files --error-unmatch Taskfile.yml.bckp   # must succeed: tracked
```

If an existing `Taskfile.yml.bckp` is already present, it belongs to an
earlier, possibly unfinished migration — ask before replacing it rather
than overwriting silently.

**Removal criterion:** one green CI run on every frozen name from step
1, with the new `tf:*` surface and any shims in place. Before that,
treat the backup as live.

**To roll back:** `cp Taskfile.yml.bckp Taskfile.yml`, then re-check
CI's frozen names against the restored file. Rolling back the Taskfile
does **not** undo a layout move from step 3 — a `git mv` is a normal
commit and needs its own `git revert` if the move itself needs undoing.
Scripts copied to `scripts/tf-stack.sh`/`scripts/tf-verify.sh` and
permission rules added to `.claude/settings.local.json` are not removed
by restoring the Taskfile either; decide separately whether they should
stay.

## 6. Secrets: a repo that already wires `*.secret.tfvars`

MIGRATE reads this section before installing. UPDATE reads it for release
0.7.0's one-offs and does not choose in step 4: the release wins over a local
one-off, so it takes the last option and retires `secrets:upload`/`:download`
(`references/releases.md`, 0.7.0).

`tf:secrets:*` is the toolkit's own secret management (see
`references/tf-stack.md`, "Secrets"): a `variable` with `sensitive = true`
or `ephemeral = true` is a secret, one Secret Manager secret per variable,
written to `variables/<vars_id>.secret.tfvars`, which `VAR_FILES` appends
**last**. A target repo may already carry its own arrangement for a secret
tfvars, by hand or from the older dacbots `dev-secrets` skill. That skill
appends the secret tfvars as an explicit **last entry in each `VARS_MAP`
line**, gitignores `secrets/*`, and round-trips the file through
`secrets/manifest.txt` and `secrets:upload`/`secrets:download` as one
whole-file secret per environment (`tfvars-<env>`). Look for it before
installing: `grep -n 'secret.tfvars' Taskfile.yml .gitignore`, any
`secrets/manifest.txt`, any `secrets:*` task, and `-var-file=` flags naming
a `*.secret.tfvars` in CI, the Makefile or `scripts/`.

**What the new `VAR_FILES` does with such a line** (tested against the
shipped script; the third argument is `variables/<vars_id>.secret.tfvars`):

| `VARS_MAP` entry | File present | File absent |
|---|---|---|
| the current `variables/<vars_id>.secret.tfvars`, last | skipped in place, appended once, last: **not passed twice** | skipped; the guards skip it too, so a clean clone can still pull |
| the same, anywhere else in the list | same: skipped, then appended last | same |
| a glob that matches it (`variables/dev*.tfvars`) | never loads it in place; appended last | not applicable |
| a *different* `*.secret.tfvars` (another vars id's, a per-feature one) | **never loaded**; `tf:vars:assert` prints a note naming it | same note |

So an explicit entry for the current file is harmless, before the first
pull as well as after. `tf:vars:assert` and `VARS_IDS_PRESENT` skip every
`*.secret.tfvars` entry the way `VAR_FILES` does, so a clean clone can
still run `tf:secrets:pull:ask` and `tf:secrets:new:ask` (both run
`tf:vars:assert` first), and `tf:plan:all` and `tf:verify` still see the
environment. A `*.secret.tfvars` that is not the current one is never
loaded, even when the file exists: tofu then plans from the variables'
defaults, or prompts. `tf:vars:assert` prints a note naming the entry but
does not fail, which is why removing it is a step of the migration and
not left to the guards.

**Migrate, per repo:**

1. **Take the secret tfvars out of every `VARS_MAP` line.** Leave the
   non-secret files and their order alone; `VAR_FILES` adds the secret
   tfvars last by itself. Confirm with `task tf:vars:map`, then `task
   tf:vars STACK=<s> VARS=<id>` on a clone where the file is absent.
2. **Rename any other `*.secret.tfvars` the maps named.** Either to
   `<vars_id>.secret.tfvars` (only one per vars id loads) or to a name
   not ending `.secret.tfvars`, if it is not a secret and is meant to be
   committed.
3. **Turn each value into a variable.** Mark the variable
   `sensitive = true` or `ephemeral = true` (ephemeral needs OpenTofu
   1.11 or Terraform 1.10 and a stack `required_version` that says so;
   see "Ephemeral by default" in `references/tf-stack.md`), then store its
   value with `task tf:secrets:new:ask STACK=<s> VARS=<id> ID=<var>` (or
   `tf:secrets:push:ask` for an existing secret). The ids are
   `<SECRET_PREFIX><stack>-<vars_id>-<var>`, one per variable, so the
   old whole-file `tfvars-<env>` secret does not map onto them: the user
   reads each value out of it and pushes it. Those are real Secret
   Manager calls and are the user's to run, not this skill's.
   Delete the old secret tfvars entry from `secrets/manifest.txt` once its
   values are moved, so the two systems do not both write one file.
4. **Reconcile `.gitignore`.** `tf:secrets:setup` appends `*.secret.tfvars`
   (already there) and `/<SECRETS_DIR>/`, `/secrets/` by default. The
   `dev-secrets` block `secrets/*`, `!secrets/manifest.txt` cannot coexist
   with it: git cannot re-include a file whose directory is ignored, so a
   repo-root `secrets/manifest.txt` becomes ignored (checked with `git
   check-ignore -v`), and the toolkit's file secrets would land in the
   same directory. Either move the old directory to another name
   (`secret-files/`) in its tasks and manifest, or set `SECRETS_DIR` to
   another name for the toolkit, or retire `secrets:upload`
   and `secrets:download` by converting what they carry to `tf:secrets:*`
   (a file some other tool reads is a *file-only* secret in
   `variables/<vars_id>.secrets.hcl`).
5. **Drop any hand-added `-var-file=` from apply.** The `dev-secrets`
   skill warned never to give an `:ask` apply task a var-file, because
   `tf:apply:ask` used to take none. It does now (a saved plan holds no
   ephemeral value), and the var files come from `VAR_FILES`, so there is
   nothing to thread by hand, here or in a CI step that calls the task.
6. **Verify offline:** `task tf:vars` (the secret tfvars last under
   `FILES` once pulled), `task tf:secrets:assert`, `task tf:verify`.

## Strip list

Everything below is intentionally absent from the assets this skill
ships and from anything it writes into a target repo. If any of these
names or values shows up after an install, that install used a stale or
hand-edited copy of the asset — treat it as a bug, not a style choice.

**Functions dropped from `tf-stack.sh` (5):** `tf_export_show`,
`tf_export_publish`, `tf_export_query`, `tf_export_query_json`
(BigQuery publishing), `tf_refresh_diff` (Cloud Asset Inventory-backed
freshness checking). None of the surviving 89 functions call these, and
none of the surviving `tf:*` tasks depend on them. That strip is the
only transformation: `assets/tf-stack.sh` is the source repo's
`scripts/tf-stack.sh` with those five functions removed and nothing
else changed, so 89 of its 94 functions survive byte for byte. The
secrets functions are among the survivors (`SECRETS_DISCOVER`,
`tf_secrets`, `tf_secrets_setup`, `tf_secrets_new`, `tf_secrets_pull`,
`tf_secrets_push`, `tf_secrets_assert` and 23 `_secrets_*` helpers), as
is the `_hcl_blocks` reader they share.

**Tasks dropped (23), by group:**

- `tf:export:show`, `:publish`, `:run`, `:fields`, `:query`,
  `:query:json`, `:test` (7) — the BigQuery export pipeline.
- `tf:refresh-diff:map`, `:check`, `:plan`, `:plan:ask`, `:refresh:ask`,
  `:bootstrap:ask`, `:commit:ask`, `:apply:ask`, `:drain:ask`, `:test`
  (10) — the Cloud Asset Inventory diff-refresh pipeline.
- `tf:use:dev`, `tf:use:preprod`, `tf:use:prod` (3) — shorthands that
  hardcoded one source repo's demo stack name; use plain `tf:use
  STACK=<s> VARS=<env>` instead.
- `tf:hack` (1) — a debug scratch task with no `desc:`, so it never
  appeared in `task --list` even in the source.
- `tf:fmt:all` (1) — formatted the source repo's own `TF_DIRS` list;
  `tf:fmt` (one stack) and `tf:fmt:check:all` (everything) ship instead.
- `tf:secrets:test` (1) — runs the source repo's own offline suite for
  the secrets tasks (`scripts/tests/tf-secrets.sh` and its fake
  `gcloud`), which this skill does not ship. The six other
  `tf:secrets:*` tasks ship.

**Namespaces dropped whole:** `vpcsc:`, `org:`, `cai:`, `wif:`, `iam:`,
`projects:`, and any per-repro debug namespace. None of these are part
of tf-stack; they belonged to the source repo's own infrastructure.

**Top-level `test` task:** the fragment ships none — `test` comes from
the base Taskfile, and should depend only on `tf:fmt:check:all` and
`tf:validate:all` for the tf side — the offline tf checks. The
source's `test` also depended on `org:test`, `tf:export:test`,
`tf:refresh-diff:test` and `tf:secrets:test`, all of which tested
namespaces or suites this skill does not ship.

**Anchor keys dropped:** the `tf_stack_env` anchor carries the keys the
89 surviving functions read (the secrets ones among them:
`V_SECRETS_PROJECT`, `V_SECRET_PREFIX`, `V_SECRETS_DIR`, `V_SECRETS_FILE`,
`V_SECRET_TFVARS`, `V_SECRETS_TF`, `V_USER_WORKING_DIR`; the seeds ones:
`V_SEED_PLAN_FILE`, `V_SEED_TARGETS`, `V_PARALLEL`, and `V_VAR_FILES`, which
`tf_seed_plan` passes to tofu), plus `V_ROOT_DIR` for the repo root.
Dropped: `V_ORG_ID`, `V_PLUGIN_CACHE`, `V_REFRESH_DIFF_DIR`,
`V_REFRESH_DIFF_TYPES` — each read only by a dropped function or a dropped
namespace. Every key that stays
keeps its source spelling, `V_BOOTSTRAP_PROJECT` included: it names the
project that owns the state bucket, which is what `tf_setup` still reads
it for.

**Values that never appear, in assets or in any target repo** — verify
absence with `git grep -n '<term>'` after any install:

```
homaway-bootstrap          homaway-bootstrap-tfstate
65933351275                (an org id)
a billing account number   a personal @<company>.com address
PROJECT_ID_PREFIX          PROJECT_MATCH
WIF_*                      EXPORT_*
BQ_QUERY                   REFRESH_DIFF_*
TF_VERSION: '1.15.6'       a vpcsc-debug log filename
prod-locks.tfvars          a dne: fixture line in VARS_MAP/BACKEND_MAP
```

These are the source repo's own identity and fixture data, not
tf-stack's — none of them are needed to reproduce the tooling, and
carrying any of them into a target repo would mean copying someone
else's project id, billing account, or personal address by accident.

## Where the specifics land

This file describes the general procedure. The specifics of one actual
migration — which mode pair was detected, the frozen names as found
(from CI) versus assumed (labelled as such), every shim with the
permission rule it got, the backup path, and the removal criterion — are
recorded in a **Migration** section appended to that repo's own
`docs/tf-stack.md`, not in a separate report. That section is the
record for the next person who touches this repo; this file is the
reference for the next migration.
