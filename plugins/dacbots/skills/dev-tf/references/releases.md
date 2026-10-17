# dev-tf releases

What each release of the toolkit changed in a target repo, newest first. `/dev-tf`
UPDATE reads this file to identify the installed release, to find local
one-offs of what a release ships, and to report what to do afterwards.

**Identifying the installed release.** An install records no version. Read the
signatures below from the newest entry down; the installed release is the first
whose signature holds. Two pieces of evidence carry most signatures:

- **Names**: the functions `scripts/tf-stack.sh` defines, which `bash
  scripts/tf-stack.sh help` lists (it prints to stderr and exits 1; count the
  indented names, not the `usage:` and `commands:` lines).
- **Script blob**: `git hash-object scripts/tf-stack.sh`. From 0.5.0 on the
  script installs as the shipped asset byte for byte, so the blob names the
  release exactly, and a script whose other evidence places it at a release
  but whose blob matches no entry carries a local patch (SKILL.md U3 says how
  to find it). Before 0.5.0 the script's `# ---- ADAPTER ----` section was the
  repo's to edit, so a blob mismatch there is expected and the rest of the
  signature decides; it is the best available evidence, not proof.

**Releases with identical signatures.** A release that changed nothing in a
target repo (0.8.0 after 0.7.1), or only comments (0.4.1 after 0.4.0), cannot
be told from its predecessor and need not be: read the install as the newer
one, so nothing is applied between the two.

Versions are the `dacbots` plugin versions; each commit that changed the skill
bumped the version, so one commit is one release.

**Adding a release.** Bump the version in `plugins/dacbots/.claude-plugin/plugin.json`
and add an entry at the top, in this shape:

1. `## <version> — <summary>`.
2. **Changes:** what it changes in a target repo ("nothing" is an answer).
3. **Signature:** what tells an install of it from the release before it — a
   name, var, task, or a string only its script contains — and its **script
   blob** (`git hash-object skills/dev-tf/assets/tf-stack.sh`). A release that
   changes nothing in a target repo says "the same as <previous>".
4. **Toolkit-owned surface:** what it adds, renames or drops. A renamed or
   dropped var says where its value goes.
5. **Replaces:** local one-offs of what it ships, a grep that finds them, and
   what each becomes.
6. **After updating:** what the user runs themselves.

SKILL.md's UPDATE steps do not change. Two things there do, if the release
touches them: the Modes detection rule relies on every release defining the 22
base names listed under 0.3.0, so a release that drops or renames one must
change that rule; and the counts SKILL.md quotes (89 names, 46 `vars:`
entries, 8 tokens).

---

## 0.9.2 — seed plans follow moves into a seed

- **Changes:** `tf:seed:plan` (and so `tf:seeds:plan` and
  `tf:seeds:apply:ask`) also targets the other side of every root `moved`
  block that has one side inside a seed call. Lifting existing resources into
  a new seed with `moved` now plans as a move (before: it failed with
  `Moved resource instances excluded by targeting`).
- **Signature:** the same names and Taskfile as 0.9.1; the script contains
  `inseed(`. Script blob `ead0eab07cfa43fd6e24df0e3075dcb80d61cd98`.
- **Toolkit-owned surface:** nothing added, renamed or dropped; the Seeds
  section of `docs/tf-stack.md` gains "Moving existing resources into a
  seed".
- **Replaces:** a hand-run `tf:seed:plan -- -target=<old address>` or a
  `SEED_TARGETS` override that adds moved-from addresses, found with `grep -n
  SEED_TARGETS Taskfile.yml` outside the toolkit block. Both become plain
  `tf:seed:plan`.
- **After updating:** none.

## 0.9.1 — push over a destroyed secret version

- **Changes:** a secret whose latest version is destroyed counts as having no
  value. `tf:secrets:push:ask` adds a new version to it (before: it failed with
  `FAILED_PRECONDITION ... is in DESTROYED state`), `tf:secrets:pull:ask`
  reports it missing and names the push command, and `tf:secrets:status` shows
  `-` in CLOUD.
- **Signature:** the same names and Taskfile as 0.9.0; the script contains
  `value(name,state)`. Script blob
  `83cf407c6085a55320c317f079127211b3799501`.
- **Toolkit-owned surface:** nothing added, renamed or dropped.
- **Replaces:** nothing.
- **After updating:** none.

## 0.9.0 — seeds, two-phase deploy, nested task calls

- **Changes:**
  - **Seeds.** A stack can publish the stateful values other stacks read as a
    seed in `stacks/<maker>/seeds/<seed>/`, read through a scaffolded `read/`
    module over the maker's state. Until the seed exists the reader returns
    placeholders, so a plan works and any apply refuses. The seed phase
    (`tf:seeds:apply:ask`) applies only the seed calls, in dependency order;
    the deploy phase (`tf:deploy:plan`, `tf:deploy:apply:ask`) then runs every
    stack and VARS id in parallel. Nothing changes for a repo with no `seeds/`
    dir.
  - **Nested task calls.** The `:all` loops, and every other task that runs
    `task` from its shell, go through `scripts/tf-stack.sh task`. It clears
    `V_*` and `TF_DATA_DIR` and passes on the run-wide selectors, so `task
    tf:plan:all TF=terraform` now plans every VARS id with terraform (before:
    tofu), and `NO_LOCK=true` reaches each plan.
- **Signature:** 89 names: 0.7.x's 62 plus `SEED_TARGETS`, `task`,
  `tf_seed_new`, `tf_seed_plan`, five `tf_seeds_*`, two `tf_deploy_*`, 13
  `_seeds_*` and three `_deploy_*` helpers. `task` alone tells it apart. The
  Taskfile has 46 `vars:` entries and the nine tasks below. Script blob
  `408f173251fc45dcb70e5c25d7720bf34299028f`.
- **Toolkit-owned surface:**
  - nine tasks: `tf:seeds:list`, `tf:seeds:check`, `tf:seed:new`,
    `tf:seed:plan`, `tf:seed:apply:ask`, `tf:seeds:plan`,
    `tf:seeds:apply:ask`, `tf:deploy:plan`, `tf:deploy:apply:ask`;
  - three `vars:` entries (`SEED_PLAN_FILE`, `SEED_TARGETS`, `PARALLEL`) and
    six anchor keys (`V_SEED_PLAN_FILE`, `V_SEED_TARGETS`, `V_PARALLEL`,
    `V_VAR_FILES`, `V__NO_COLOR`, `V__NO_LOCK`);
  - `env: *tf_stack_env` on `tf:plan:all`, `tf:init:once:all` and
    `tf:setup:all`, whose nested calls become `scripts/tf-stack.sh task …`;
  - `tf:verify` check 2 expecting 89 names and check 3 the nine tasks;
  - the Seeds section of `docs/tf-stack.md`.

  **Changed meaning:** `V_NO_COLOR` and `V_NO_LOCK` now hold the raw
  `true`/`false`; the rendered flags moved to `V__NO_COLOR`/`V__NO_LOCK`. The
  script and the block must change together, as U5 does: a 0.9.0 script under
  a 0.8.x block silently drops `-no-color` and `-lock=false`. `PARALLEL`
  (default 4) is a repo-owned setting: kept when already set.
- **Replaces:** a hand-written loop or CI compat shim that nests `task` from
  its shell, found with `grep -n 'env -u TF_DATA_DIR task' Taskfile.yml`
  outside the toolkit block. Each becomes `scripts/tf-stack.sh task <same
  arguments>`, with `env: *tf_stack_env` on its task; a shim keeps its
  permission rule. Seeds are opt-in, so cross-stack reads are not retired:
  list any `data "terraform_remote_state"` in a stack (`grep -rn
  terraform_remote_state <STACKS_DIR>`) in the report as seed candidates.
- **After updating:** none required. To adopt a seed: `task tf:seed:new
  STACK=… SEED=…`, then `task tf:init:init STACK=…` once for the new module
  call; `docs/tf-stack.md` ("Seeds") has the rest.

## 0.8.1 — exact mode arguments

- **Changes:** nothing in a target repo. `migrate` and `greenfield` now say
  exactly what they do: `migrate` adds MIGRATE's obligations (and reads a
  `tf-add` Taskfile as `tf-replace`); `greenfield` checks detection rather
  than overriding it. Neither can remove a backup, CI-name freeze or move
  confirmation.
- **Signature:** the same as 0.7.1 (script blob
  `25fb1f081f1e1f92cf6b885a32836576d29bb6fe`); reads as 0.8.1.
- **Replaces:** nothing.
- **After updating:** none.
- **Published:** never on its own. dacbots went from 0.8.0 to 0.9.0, which
  carries this change.

## 0.8.0 — UPDATE mode

- **Changes:** nothing in a target repo. The skill gained a separate UPDATE
  mode and this file; no asset and no `references/tf-stack.md` line changed.
- **Signature:** the same as 0.7.1 (script blob
  `25fb1f081f1e1f92cf6b885a32836576d29bb6fe`). An install of 0.8.0 cannot be
  told from one of 0.7.1; both read as the newest release with that
  signature.
- **Replaces:** nothing.
- **After updating:** none.

## 0.7.1 — pull reports what changed

- **Changes:** `tf:secrets:pull:ask` lists each secret as `new`, `updated`
  (with the version it replaced) or `unchanged`, writes only what changed, and
  says `up to date: nothing written.` when nothing did.
- **Signature:** 62 names, the same as 0.7.0, and `scripts/tf-stack.sh`
  contains the text `up to date: nothing written.`. Script blob
  `25fb1f081f1e1f92cf6b885a32836576d29bb6fe`.
- **Toolkit-owned surface:** `scripts/tf-stack.sh`, and the
  `tf:secrets:pull:ask` row of `docs/tf-stack.md`.
- **Replaces:** nothing.
- **After updating:** none.

## 0.7.0 — secret management

- **Changes:** a variable with `sensitive = true` or `ephemeral = true` is a
  secret, stored one per variable in GCP Secret Manager and pulled into a
  gitignored `variables/<vars_id>.secret.tfvars` that `VAR_FILES` appends last.
  `tf:apply:ask` passes the var files along with the saved plan.
- **Signature:** 62 names (the 31 core plus `SECRETS_DISCOVER`, `_hcl_blocks`,
  `tf_secrets*` and 23 `_secrets_*` helpers); the Taskfile has the
  `tf:secrets`, `tf:secrets:setup`, `tf:secrets:new:ask`, `tf:secrets:pull:ask`,
  `tf:secrets:push:ask` and `tf:secrets:assert` tasks and 43 `vars:` entries.
  Script blob `9b8d24b0ba8bbb94fcb457034bbc91d920a80ff9`.
- **Toolkit-owned surface:** the six `tf:secrets*` tasks; six `vars:` entries
  (`SECRETS_PROJECT`, `SECRET_PREFIX`, `SECRETS_DIR`, `SECRETS_FILE`,
  `SECRET_TFVARS`, `SECRETS_TF`) and seven `tf_stack_env` anchor keys
  (`V_SECRETS_PROJECT`, `V_SECRET_PREFIX`, `V_SECRETS_DIR`, `V_SECRETS_FILE`,
  `V_SECRET_TFVARS`, `V_SECRETS_TF`, `V_USER_WORKING_DIR`); the third `VAR_FILES`
  argument; `tf:secrets:assert` in `tf:plan`, `tf:plan:debug`, `tf:apply:ask`,
  `tf:refresh:ask` and `tf:destroy:deny`; `{{.VAR_FILES}}` in `tf:apply:ask`;
  `tf:verify` check 2 expecting all 62 names; the `.gitignore` lines
  `*.secret.tfvars` and `/<SECRETS_DIR>/`. `SECRETS_PROJECT` (defaults to
  `BOOTSTRAP_PROJECT`), `SECRET_PREFIX` and `SECRETS_DIR` are repo-owned
  settings: kept when already set.
- **Replaces:** the older dacbots `dev-secrets` arrangement, and any other hand
  wiring of a secret tfvars. Find it with `grep -n 'secret.tfvars' Taskfile.yml
  .gitignore`, a `secrets/manifest.txt`, `secrets:*` tasks, and `-var-file=`
  naming a `*.secret.tfvars` in CI, the Makefile or `scripts/`.
  `references/migration.md` §6 says what each becomes; in UPDATE that is:
  - a `*.secret.tfvars` entry in a `VARS_MAP` line comes out (§6 step 1);
    one naming another vars id's or a per-feature file is renamed (§6 step 2,
    asking which of its two names);
  - `secrets:upload*`/`secrets:download*` are removed (§6 step 4's last
    option), with the `secrets/*`, `!secrets/manifest.txt` `.gitignore` block
    and `secrets/manifest.txt` itself. List what the manifest named first: each
    entry is a value the user stores again, per variable (`tfvars-<env>`) or as
    a file-only secret in `variables/<vars_id>.secrets.hcl` (any other file);
  - a hand-added `-var-file=` of a secret tfvars on apply comes out (§6 step 5);
  - never deleted: the local `variables/<vars_id>.secret.tfvars` and the old
    `tfvars-<env>` secrets in Secret Manager. They hold the values until the
    user has moved them, and plans keep reading that file meanwhile, since
    `VAR_FILES` appends the same path.
- **After updating:** `task tf:secrets:setup` once (needs `gcloud`,
  authenticated; enables Secret Manager and gitignores `*.secret.tfvars` and
  `/<SECRETS_DIR>/`); then `task tf:secrets:new:ask STACK=… VARS=… ID=<var>`
  per secret, or `tf:secrets:pull:ask` on a clone. A repo leaving `dev-secrets`
  moves its values **before** the first `new:ask` or `pull:ask`: both rewrite
  `variables/<vars_id>.secret.tfvars` from Secret Manager, so copy each value
  out of the old file (or the old `tfvars-<env>` secret) first, then delete the
  old secrets once nothing reads them. Ephemeral variables need OpenTofu >= 1.11
  or Terraform >= 1.10 and a stack `required_version` that allows them; check
  the toolchain and say so in the report. A repo with no GCP project drops the
  five gcloud tasks and keeps `tf:secrets:assert`.

## 0.6.1 — `NO_COLOR` and `NO_LOCK`

- **Changes:** every tf invocation that supports it gets `-no-color` (on by
  default), and `tf:plan` gets `-lock=false` when `NO_LOCK=true`.
- **Signature:** 31 names; the Taskfile has the `NO_COLOR` and `NO_LOCK` vars
  and `V_NO_COLOR`/`V_NO_LOCK` anchor keys and `tf:force-unlock:ask`; no
  `tf:secrets*` tasks. Script blob `691344ae022366a829cf4d7e6ced18b481eee70e`.
- **Toolkit-owned surface:** the two vars, their `_NO_COLOR`/`_NO_LOCK`
  derivations, and the `{{._NO_COLOR}}` / `{{._NO_LOCK}}` splices in the tasks;
  `scripts/tf-stack.sh` (`init` flags).
- **Replaces:** hand-added `-no-color` or `-lock=false` flags in local `tf:*`
  tasks: `grep -n -e '-no-color' -e '-lock=false'` in the Taskfile.
- **After updating:** none. Output is uncoloured by default; `NO_COLOR=false`
  restores colour.

## 0.6.0 — `STACKS_DIR`, `tf:force-unlock:ask`

- **Changes:** every stack path derives from the `STACKS_DIR` var (default
  `stacks`, overridable on the CLI) instead of a hardcoded `stacks/`; a new
  `tf:force-unlock:ask` drops a stale state lock through the same
  `STACK`/`VARS`/`BACKEND` selection that created it.
- **Signature:** 31 names; `STACKS_DIR` appears in both the Taskfile and
  `scripts/tf-stack.sh` (`V_STACKS_DIR`); `tf:force-unlock:ask` exists; no
  `NO_COLOR`. Script blob `0181e65d550855a4ff8aecb95deb3d052fa23e38`.
- **Toolkit-owned surface:** `tf:force-unlock:ask`; the `STACKS_DIR` var and
  `V_STACKS_DIR` anchor key, `STACKS_DIR`'s wiring in `STACK_DIR`, `STACKS` and
  `tf:validate:all`, and the script's stack listing. The `STACKS_DIR` default
  itself is repo-owned.
- **Replaces:** a hand-edited stacks path (`stacks/` changed to another
  directory in the Taskfile or the script) and hand-rolled lock tasks:
  `grep -n 'stacks/\|force-unlock'` in the Taskfile and `scripts/tf-stack.sh`.
  A repo that moved its stacks by editing the path must keep that location:
  carry it into `STACKS_DIR`'s default, not back to `stacks`. (Same for the
  `STACKS_DIR` value an install before 0.5.0 had.)
- **After updating:** none.

## 0.5.0 — upstream script byte for byte

- **Changes:** `scripts/tf-stack.sh` becomes the upstream script minus five
  home-repo functions, with no local edits and no ADAPTER section. A stack may
  keep its backend inline in a `.tf` instead of a `.backend.hcl`
  (`BACKEND_KIND`, `BACKEND_INLINE_FILE`, `BACKEND_DEFAULT`). `tf:stack:assert`
  calls the script. The Taskfile block has eight project tokens instead of ten:
  `STATE_PROJECT` is now `BOOTSTRAP_PROJECT`, and `TF_BACKEND` and the token for
  `STACKS_DIR` are gone (`STACKS_DIR` returns in 0.6.0). `tf:setup` and
  `tf:setup:all` are a gcs-only conditional block. `tf:verify` runs 11 checks.
- **Signature:** 31 names including `BACKEND_KIND`, `BACKEND_INLINE_FILE`,
  `BACKEND_DEFAULT` and `tf_stack_assert`; the Taskfile has `BOOTSTRAP_PROJECT`
  and `STACK_DIR: 'stacks/…'`; no `STACKS_DIR`, no `tf:force-unlock:ask`.
  Script blob `e524c95cd81ee3cae6d2c37bfb391e9df0bbb65b`.
- **Toolkit-owned surface:** the whole script and block as above. Dropped: the
  vars `STATE_PROJECT`, `TF_BACKEND` and `STACKS_DIR`, and the anchor keys
  `V_STATE_PROJECT`, `V_TF_BACKEND`, `V_STACKS_DIR` and `V_PLUGIN_CACHE`.
- **Replaces:** the ADAPTER-edited script of 0.3.0-0.4.1 and its Taskfile vars
  `STATE_PROJECT` and `TF_BACKEND`: `grep -n 'STATE_PROJECT\|TF_BACKEND'
  Taskfile.yml`. Carry the `STATE_PROJECT` value into `BOOTSTRAP_PROJECT`.
  Behaviour the shipped version lacks: `tf:setup` no longer provisions `local`,
  `s3` or `azurerm` state, and the s3/azurerm/local backend templates are gone;
  report any repo that used them (the state store is then provisioned out of
  band and the `tf:setup` block is dropped).
- **After updating:** none beyond `task tf:verify`.

## 0.4.0 and 0.4.1 — field-report fixes

- **Changes (0.4.0):** `_hcl_string` (a trailing comment in a `backend.hcl` no
  longer corrupts the bucket name) and `tf:verify` accepting `Taskfile.yaml`.
  The skill also stopped writing CI compat shims as `cmds: [{task: …}]` calls
  and wrote them as shell wrappers. **(0.4.1):** comment wording only, in the
  Taskfile block and `tf:verify`.
- **Signature:** 23 names (the 22 below plus `_hcl_string`); the script has a
  `# ---- ADAPTER ----` section; the Taskfile has `STATE_PROJECT`, `TF_BACKEND`
  and `STACKS_DIR`. Script blob, ADAPTER section unedited,
  `d114ff462e621f081105a09cef2da42c950123fb` for both: 0.4.0 and 0.4.1 cannot
  be told apart and need not be, since they differ in comments.
- **Replaces:** a CI compat shim in 0.3.0's `cmds: [{task: tf:apply:ask}]`
  form that carries a `vars:` block to pin its stack: call-scoped vars reach
  one level only, so the guards and `tf:init:once` act on the default stack and
  the apply runs anyway. Find shims by their `CI compat shim` `desc:`; rewrite
  each one with `vars:` as SKILL.md step 10's shell wrapper, keeping its name
  and permission rule. One without `vars:` works (CLI vars are global) and is
  left alone.

## 0.3.0 — first release

- **Changes:** the `tf:*` block, an adapted `scripts/tf-stack.sh` (a
  `[[:space:]]` portability fix, `BACKEND_STATE`, a `tf_setup` adapter for gcs
  and local in its editable ADAPTER section), `scripts/tf-verify.sh` with 12
  checks, and backend templates for gcs, s3, azurerm and local.
- **Signature:** exactly 22 names, the **base names**: `BACKEND_FILE`,
  `BACKEND_RESOLVED`, `BACKEND_STATE`, `USE_BACKEND`, `USE_VARS`,
  `VARS_IDS_PRESENT`, `VARS_RESOLVED`, `VAR_FILES`, `_normalize_spec`,
  `tf_backend`, `tf_backend_assert`, `tf_init_init`, `tf_setup`,
  `tf_stacks_list`, `tf_toolchain_install`, `tf_toolchain_show`,
  `tf_toolchain_use_ask`, `tf_use`, `tf_use_clear`, `tf_validate_all`,
  `tf_vars`, `tf_vars_assert`. All of them are in every later release's list
  (through 0.8.0's 62), so a script defining all 22 is a prior install; one
  defining none is someone's own. No `_hcl_string`. Script blob, ADAPTER
  section unedited, `2b87c2fc237101ba7a39b5142163aaa93802416e`.
- **Replaces:** nothing; superseded by 0.5.0.
