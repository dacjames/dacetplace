# Migrating an existing Taskfile

This applies whenever `Taskfile.yml` already has `tf:` tasks (mode
`tf-replace`) or already has other tasks but no `tf:` namespace yet
(mode `tf-add`). The goal: replace whatever tf tooling exists today with
the full tf-stack surface, without breaking anything CI actually calls,
and without moving any stack's state.

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
| `tf:apply` | `tf:apply:ask` | visible wrapper task, `desc: 'CI compat shim for tf:apply:ask -- remove after stabilization'`, `cmds: [{task: tf:apply:ask}]` | `Bash(task tf:apply)` in `permissions.ask` |
| `tf:destroy` | `tf:destroy:deny` | visible wrapper task, same shape, worded for destroy | `Bash(task tf:destroy)` in `permissions.deny` |
| `set-env-<env>` | `tf:use STACK=<s> VARS=<env>` | one ungated wrapper task per env running that command | none — writes only a local, gitignored `.env` file |

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
writes a gitignored `.env` file, never state), so no rule is added for
it.

## 3. Move the layout

Only when root modules are not already under a `stacks/<name>/`-shaped
directory (or an equivalent parent such as `terraform/`, `infra/`, or
`live/`). This is a refactor, never a state migration — the checklist
exists to keep it that way:

1. **List every root module** and its proposed destination. Present the
   full list before moving anything.
2. **Confirm with the user**, then move **one stack at a time** with
   `git mv`, so history follows the files.
3. **Keep each backend's `bucket`/`prefix` (or `key`) unchanged.** The
   directory moves; the state address it points at does not.
4. **Never delete `.terraform*/` or a local `terraform.tfstate`** as
   part of the move, without asking first — for a local backend, that
   file *is* the state, and for a remote one the cached provider
   directory is expensive but not dangerous to lose, so the two need
   different confirmations.
5. **Move per-env tfvars into `<stack>/variables/`**, and inline backend
   settings out of the `.tf` file into `variables/<id>.backend.hcl`,
   leaving the `.tf` block as a bare `backend "<flavor>" {}`. Ask before
   rewriting any `.tf` file — this step touches code, not just paths.
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

## Strip list

Everything below is intentionally absent from the assets this skill
ships and from anything it writes into a target repo. If any of these
names or values shows up after an install, that install used a stale or
hand-edited copy of the asset — treat it as a bug, not a style choice.

**Functions dropped from `tf-stack.sh` (5):** `tf_export_show`,
`tf_export_publish`, `tf_export_query`, `tf_export_query_json`
(BigQuery publishing), `tf_refresh_diff` (Cloud Asset Inventory-backed
freshness checking). None of the surviving 21 functions call these, and
none of the surviving `tf:*` tasks depend on them.

**Tasks dropped (21), by group:**

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

**Namespaces dropped whole:** `vpcsc:`, `org:`, `cai:`, `wif:`, `iam:`,
`projects:`, and any per-repro debug namespace. None of these are part
of tf-stack; they belonged to the source repo's own infrastructure.

**Top-level `test` task:** trimmed to depend only on
`tf:fmt:check:all` and `tf:validate:all` — the offline tf checks. The
source's `test` also depended on `org:test`, `tf:export:test`, and
`tf:refresh-diff:test`, all of which tested namespaces this skill does
not ship.

**Anchor keys dropped:** the `tf_stack_env` anchor carries only the keys
the 21 surviving functions read. Dropped: `V_ORG_ID`,
`V_REFRESH_DIFF_DIR`, `V_REFRESH_DIFF_TYPES`, `V_VAR_FILES` (all read
only by `tf_refresh_diff`), and `V_BOOTSTRAP_PROJECT` (renamed
`V_STATE_PROJECT` for the surviving gcs-only use, so it does not carry
the old key's association with one specific bootstrap project).

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
