# tf-stack

A thin layer over `tofu`/`terraform` for repos with more than one root
module, more than one environment, or both. Three parts: **`Taskfile.yml`**
(the `tf:*` tasks and the `STACK` / `VARS` / `BACKEND` / `TF` variables that
steer them), **`scripts/tf-stack.sh`** (the resolvers, guards and `show`
commands behind them), and **a layout convention** — `stacks/<name>/` for
root modules, `modules/` for shared modules, `stacks/<name>/variables/` for
a stack's tfvars and backend configs.

Nothing replaces Terraform: every task ends in an ordinary `tofu
plan`/`apply` with `-var-file` and `-backend-config` worked out for you.
What it adds:

- **One command shape** for every stack and environment — `task tf:plan
  STACK=x VARS=y`.
- **Selection by name, not path.** `VARS=prod` stands for a list of tfvars
  files, `BACKEND=prod` for a state bucket; both mappings live in one
  place.
- **Guards before tofu runs.** A glob matching nothing, an unknown
  environment, an apply against a stack with no remote state — each
  refused with a message naming the real problem, instead of reaching
  tofu as `bucket must be set` or a plan that creates everything.
- **No collisions.** `TF_DATA_DIR` is keyed by toolchain and backend, the
  saved plan file by stack, vars, backend and toolchain — so planning prod
  after dev cannot leave `apply` holding the wrong plan.

Needs [go-task](https://taskfile.dev) and `tofu`. Nothing else for a
`local` backend; `gcloud`, `aws` or `az` only for the backend flavor
you use (`tf:setup`); `terraform` + `tfenv` only if you want the
plan-only second toolchain.

## Arguments go after the task name

```
task tf:plan STACK=app VARS=dev          # yes
VARS=dev task tf:plan STACK=app          # no -- VARS is silently ignored
```

The shell-environment form falls back to the default for `VARS` and
`BACKEND` — refused on a multi-environment stack (fine), quietly wrong on
a single-environment one.

## A worked example

Two stacks: `app` has two environments, each with its own state; `data`
has one environment and no state bucket yet, so it plans without writing
anywhere.

```
$ task tf:stacks:list
NAME   WRITABLE  BACKEND  STATE
app    yes       dev      gs://example-tfstate-dev/app
                  prod     gs://example-tfstate-prod/app
data   no        -        local, plan-only
```

Ask what a run would do before running it:

```
$ task tf:vars STACK=app VARS=dev              $ task tf:backend STACK=app VARS=dev
STACK      app                                 STACK      app
VARS       dev                                 BACKEND    dev:variables/dev.backend.hcl
RESOLVED   dev:variables/common.tfvars,…       SOURCE     VARS_ID=dev
VARS_ID    dev                                 BACKEND_ID dev
BACKEND    dev                                 FILE       …/variables/dev.backend.hcl
PLAN       …/app-dev-dev-tofu.tfplan           STATE      gs://…-tfstate-dev/app
FILES                                          WRITABLE   yes
  variables/common.tfvars                      DATA_DIR   …/.terraform-tofu-dev
  variables/dev-extra.tfvars
  variables/dev.tfvars
```

Then the ordinary cycle, or every environment at once:

```
task tf:setup:all STACK=app                     # create the state buckets (idempotent)
task tf:plan      STACK=app VARS=dev            # inits if needed, saves a plan file
task tf:plan:show STACK=app VARS=dev            # re-read the saved plan
task tf:apply:ask STACK=app VARS=dev            # apply that saved plan

task tf:plan:all  STACK=app                     # one plan per name in VARS_MAP
```

### The three selectors

**`STACK`** is the root module directory — `STACK=app` means `stacks/app/`,
and every `tf:*` task runs with that as its working directory, so all
paths in `VARS` and `BACKEND` are **stack-relative**. Defaults to `main`.

**`VARS`** selects tfvars, in two equivalent forms — `VARS=<vars_id>`,
looked up in `VARS_MAP`, or `VARS=<vars_id>:<glob>[,<glob>...]` spelled
out inline. `VARS_MAP` in `Taskfile.yml` is just a list of the second
form:

```
dev:variables/common.tfvars,variables/dev*.tfvars
prod:variables/common.tfvars,variables/prod.tfvars,variables/prod-extra.tfvars
```

Globs expand in the order written and tofu lets the **last `-var-file`
win**, so written order is precedence order: base first, environment
last. Within one glob, expansion is alphabetical — `dev*.tfvars` loads
`dev-extra.tfvars` *before* `dev.tfvars`. Check with `task tf:vars`.

A glob matching no file is an error, not a silent drop: without that
check a typo leaves the run with no `-var-file` at all, which tofu
happily plans from the variables' own defaults.

Default: `VARS=<stack>:variables/<stack>.tfvars` — one named file rather
than a sweep of `variables/`, so a stack can keep several tfvars files
there without a bare run collecting them all.

**`BACKEND`** selects state, same two forms, mapped by `BACKEND_MAP`.
Usually not typed, because of where it comes from when missing:

```
CLI BACKEND  >  <stack>.env (tf:use)  >  VARS_ID  >  stack name
```

So `VARS=dev` reaches dev state too, as long as `dev` names a backend —
which means **a run's state moves when `VARS` moves**. Three things keep
that visible: `tf:backend` always prints a `SOURCE` line saying which
rule supplied the value; `TF_DATA_DIR` carries the backend id
(`.terraform-tofu-dev` vs `-prod`), so switching is an `init` rather
than tofu offering to migrate state; and the plan filename carries both
ids, so a crossed `VARS=dev BACKEND=prod` saves
`app-dev-prod-tofu.tfplan` and cannot be confused with
`app-dev-dev-tofu.tfplan`.

### Remembering a selection

Passing `VARS` every time is the default, and is what keeps `tf:plan:all`
a loop rather than three stateful steps. When you are on one environment
for a while:

```
task tf:use       STACK=app VARS=dev      # writes app.env (gitignored)
task tf:plan      STACK=app                # -> dev
task tf:use:clear STACK=app                # forget it
```

The command line always wins; `task tf:vars` prints a `SOURCE` line
whenever a value came from the file; and the file stores the *name*, not
the files, so editing `VARS_MAP` takes effect immediately. `BACKEND` is
written **only when you name one** — a line restating a derived backend
would freeze state while `VARS` kept moving. `STACK` is not remembered
and cannot be: the file's own name depends on it.

`tf:use` validates before writing; `tf:use:clear` deliberately does not,
because clearing has to work when the remembered value is the problem.

## Project structures

The same tasks cover every shape below. What changes is the contents of
`stacks/` and of the two maps.

### Single module

One root module, one environment, one state — the default everything.

```
stacks/main/
  main.tf  variables.tf  outputs.tf  versions.tf
  backend.tf                         # terraform { backend "<flavor>" {} }
  variables/
    main.tfvars                      # matches the default VARS
    main.backend.hcl                 # matches the default BACKEND
```

`STACK` defaults to `main`, `VARS` to `main:variables/main.tfvars`,
`BACKEND` to the vars id — so `task tf:plan` and `task tf:apply:ask` need
no arguments and neither map needs an entry. Growing a second environment
later is additive: write the tfvars, add a `VARS_MAP` line, and commands
gain a `VARS=` argument.

### Multi-stack

Several root modules with unrelated lifecycles. Split one out when a
change to it should not plan the other, or when a bad apply in one must
not take the other's state with it.

```
stacks/
  app/     # the service
  data/    # data pipelines and storage
  edge/    # not provisioned yet
```

Each has its own `variables/<stack>.tfvars` and
`variables/<stack>.backend.hcl`, so each gets its own state prefix,
`TF_DATA_DIR` and plan file:

```
task tf:plan STACK=data
task tf:stacks:list        # every stack, its backends, where each one's state lives
task tf:validate:all       # offline-validate every stack
```

`backend.tf` in each stack is a bare `backend "<flavor>" {}` — bucket and
prefix (or key) come from `-backend-config`, which is what makes the same
root module reusable across backends.

**A stack with no `backend.hcl` is plan-only**, shown as `WRITABLE no`.
Its state is local and empty, so a plan shows every resource as new, and
every writing task refuses to run against it. That is a deliberate mode:
it is how a stack that duplicates resources another stack already owns
is kept harmless while it is being adopted.

### Multi-env

Terraform gives you no built-in way to say "plan dev, not prod". The
usual answers are a directory per environment (copies that drift) or
workspaces (one state split many ways, the environment invisible in the
code). This is the third: **one root module, one set of `.tf` files,
different `.tfvars` per run, a state bucket per environment.** The
environment is data — what differs is a variable, what follows is an
expression over it.

```
stacks/app/
  main.tf  variables.tf  outputs.tf  versions.tf  backend.tf
  variables/
    common.tfvars          # shared base, loaded first by every environment
    dev.tfvars
    dev-extra.tfvars       # second dev file, matched by the dev*.tfvars glob
    prod.tfvars
    prod-extra.tfvars      # loaded by prod and nothing else
    dev.backend.hcl        # one bucket per environment
    prod.backend.hcl
```

with the environments named in both maps (`VARS_MAP` as above,
`BACKEND_MAP` mapping each id to its `.backend.hcl`). Four choices in
there are load-bearing:

- **No `app.tfvars` and no `app.backend.hcl`, on purpose.** The shared
  base is named `common.tfvars` so the *default* `VARS` resolves to a
  file that does not exist and the run is refused. A stack with several
  environments has no sensible default environment.
- **The environments need not be symmetric** — a glob matching two
  files, a single file, two named files. Explicit lists make real-world
  asymmetry cost a line rather than an exception.
- **Derived values stay out of tfvars.** A flag like
  `deletion_protection` is computed in `main.tf` from
  `environment == "prod"`, so it cannot be forgotten in an environment
  file.

Per-environment loops: `tf:setup:all` (one bucket per backend),
`tf:init:once:all`, `tf:plan:all` (one plan per name in `VARS_MAP`, each
against its own state).

### Multi-stack multi-env

Uncommon but it works. `VARS_MAP` and `BACKEND_MAP` are global, so a
`vars_id` means the same glob list everywhere. The globs are
stack-relative, so one id covers every stack whose `variables/` uses the
same structure.

```
task tf:plan STACK=app  VARS=dev        # stacks/app/variables/{common,dev}.tfvars
task tf:plan STACK=data VARS=dev        # stacks/data/variables/{common,dev}.tfvars
```

Where two stacks disagree on file names:

- **Namespace the ids** — `app_dev`, `data_dev`, a line each in both
  maps. Maps grow as stacks × environments.
- **Spell it out per run** — `VARS=adhoc:variables/one.tfvars,variables/two.tfvars`
  needs no map entry.
- **`tf:use` per stack** — `<stack>.env` is per stack, so each remembers
  its own environment.

The `:all` tasks skip ids the stack has no files for, so a shared map
does not make them fail on another stack's environments; a stack
matching no id at all gets one run on its default `VARS`.

## Toolchains

`TF` picks the binary; `tofu` is the default.

```
$ task tf:toolchain:show STACK=app
TF          = tofu
TF_DATA_DIR = .terraform-tofu-app
version     = OpenTofu v1.9.1
lock        = registry.opentofu.org
```

`TF=terraform` is **plan-only** — `tf:apply:ask`, `tf:refresh:ask` and
`tf:destroy:deny` refuse it, because both toolchains share one remote
state and state written by one may not be readable by the other. Use it
to compare plan output, not to write. `TF_DATA_DIR` includes the
toolchain name so the two never share a provider directory; the lock
file cannot be split the same way (fixed path), so
`tf:toolchain:use:ask` stashes the outgoing lock under the temp dir and
restores the incoming one.

## Command reference

`STACK`, `VARS`, `BACKEND` and `TF` apply to every `tf:*` task and are
omitted below. Anything after `--` passes through to tofu (`task
tf:plan -- -target=module.x`). The `:ask` and `:deny` suffixes are
conventions for AI-agent permission gating, not different behaviour:
`:ask` writes and should be confirmed, `:deny` is destructive.

### `tf:stacks:*`, `tf:toolchain:*` — discovery

| Task | What it does |
| --- | --- |
| `tf:stacks:list` | Every stack, each backend it has, where that state lives, whether it is writable |
| `tf:toolchain:show` | Active `TF`, version, `TF_DATA_DIR`, which registry the lock names, what is stashed |
| `tf:toolchain:install` | `tfenv install/use` the version in `TF_VERSION` (no-op for tofu) |
| `tf:toolchain:use:ask` | Switch the working dir to `TF`, stashing/restoring the lock, then re-init |

### `tf:vars:*`, `tf:backend:*` — what would this run do

Read-only. Use before anything that writes.

| Task | What it does |
| --- | --- |
| `tf:vars` | Which tfvars this stack would load, in order, and where its plan file goes |
| `tf:vars:ids` / `tf:vars:map` | The names in `VARS_MAP` / the full value each stands for |
| `tf:backend` | Which backend a run would use, where that state lives, and **why** (`SOURCE`) |
| `tf:backend:ids` / `tf:backend:map` | The same two, over `BACKEND_MAP` |

### `tf:use:*` — remember a selection

| Task | What it does |
| --- | --- |
| `tf:use` | Write `VARS` (and `BACKEND`, only if you named one) to `<stack>.env` |
| `tf:use:clear` | Drop those lines; remove the file if that is all it held |

### `tf:setup`, `tf:init:*` — get ready to plan

| Task | What it does |
| --- | --- |
| `tf:setup` | Provision the state backend `BACKEND` names. Idempotent for `gcs` and `local`; for other flavors it prints the keys found and exits — see the backends reference |
| `tf:setup:all` | `tf:setup` once per backend the stack actually has |
| `tf:init:once` | Init unless `TF_DATA_DIR` already exists. Most plan/apply tasks depend on this |
| `tf:init:init` | Init unconditionally; retries with `-reconfigure` if the backend cache is stale |
| `tf:init:once:all` | `tf:init:once` for every backend the stack has |
| `tf:init:local` | Init with `-backend=false` into a separate data dir. Offline, no credentials |
| `tf:init:upgrade:ask` | Re-init with `-upgrade`, rewriting the lock file |

### `tf:fmt:*`, `tf:validate:*` — checks

| Task | What it does |
| --- | --- |
| `tf:fmt` / `tf:fmt:check` | `fmt -recursive` on the stack, rewriting / checking only |
| `tf:fmt:check:all` | The same check across every stack and module |
| `tf:validate` | `validate` against the real backend (inits first) |
| `tf:validate:local` | `validate` offline — no backend, no credentials |
| `tf:validate:all` | Offline-validate every stack under `stacks/` |

`task test` runs `tf:fmt:check:all` and `tf:validate:all` — the offline
check set.

### `tf:plan:*` — plan

| Task | What it does |
| --- | --- |
| `tf:plan` | Plan and save to `<TMP>/<stack>-<vars_id>-<backend_id>-<tf>.tfplan` |
| `tf:plan:all` | `tf:plan` once per name in `VARS_MAP` the stack has files for, one plan file each; falls back to one default run if it has none |
| `tf:plan:show` | Re-read the saved plan for this combination |
| `tf:plan:debug` | Plan with full provider HTTP logging to `<TMP>/<stack>-debug-<tf>.log` |

The plan filename carries all four keys, so distinct combinations never
share one. Applying a saved plan takes no `-var-file`, which makes the
plan the only record of which values went into it — with one filename
per stack, planning prod after dev would leave `tf:apply:ask` holding
prod's plan under a dev invocation, with nothing to notice.

`tf:plan:debug` writes OAuth bearer tokens and full API payloads to that
log. It stays in the gitignored temp dir; redact before attaching it to
a bug report.

### Write tasks

Each refuses first if the stack is plan-only, if `TF` is not `tofu`, or
if `VARS` does not resolve.

| Task | What it does |
| --- | --- |
| `tf:apply:ask` | Apply the **saved plan file**, not a fresh plan |
| `tf:refresh:ask` | `apply -refresh-only` — reconcile state with reality, change nothing |
| `tf:destroy:deny` | `destroy` everything the stack manages |
| `tf:output` | Print the stack's outputs |
| `tf:clean` | Remove every toolchain's provider dir, the lock file and stash, and the temp dir |

## The guards

Four internal tasks refuse a run before tofu starts. Worth knowing by
name, because their messages are what you see when something is
misconfigured — and each prints the names that *do* exist, so the
recovery is in the error.

| Guard | Refuses when | Because |
| --- | --- | --- |
| `tf:vars:assert` | `VARS` names nothing in `VARS_MAP`, or a glob matches no file | tofu treats a missing `-var-file` as fine and plans from variable defaults |
| `tf:backend:assert` | `BACKEND` resolves to no `backend.hcl` that exists | otherwise tofu says `bucket must be set` — true, and silent about what was missing |
| `tf:stack:assert` | a writing task targets a stack with no backend file | its state is local and empty; an apply would create a second copy of resources another stack owns |
| `tf:toolchain:assert:tofu`\* | a writing task runs under `TF=terraform` | both toolchains share one remote state |

\* named `tf:toolchain:assert:terraform` in a terraform-only repo — the
purpose is "one toolchain writes", named after whichever one that is.

## Local state

Everything tf-stack writes locally is gitignored: the configured `TMP`
dir (plan files, state dumps, stashed locks, plugin cache),
`.terraform-*/` (per-toolchain, per-backend working directories),
`<stack>.env` (written by `tf:use`), and `.terraform.lock.hcl`. `task
tf:clean` removes all of it for a stack; `task tmp:setup` recreates the
temp dir and is already a dependency of every task that needs it.
