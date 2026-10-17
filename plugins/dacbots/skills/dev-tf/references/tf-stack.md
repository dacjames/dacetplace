# tf-stack

A thin layer over `tofu`/`terraform` for repos with more than one root
module, more than one environment, or both. Three parts: **`Taskfile.yml`**
(the `tf:*` tasks and the `STACK` / `VARS` / `BACKEND` / `TF` variables that
steer them), **`scripts/tf-stack.sh`** (the resolvers, guards and `show`
commands behind them), and **a layout convention** — `stacks/<name>/` for
root modules, `modules/` for shared modules, `stacks/<name>/variables/` for
a stack's tfvars and backend configs. The root directory (`stacks/` above) is
`STACKS_DIR`, defaulting to `stacks/`; set it once on the CLI or in
`Taskfile.yml` to use a different layout.

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
- **Secrets without a list to maintain.** A variable marked `sensitive` or
  `ephemeral` is a secret, stored in Secret Manager and pulled to a
  gitignored tfvars file before a plan; a plan that needs one it does not
  have is refused. See [Secrets](#secrets).
- **No collisions.** `TF_DATA_DIR` is keyed by toolchain and backend, the
  saved plan file by stack, vars, backend and toolchain — so planning prod
  after dev cannot leave `apply` holding the wrong plan.

Needs [go-task](https://taskfile.dev) and `tofu`. Nothing else to plan or
apply against a state store that already exists; `gcloud` only if this
repo carries the `tf:setup` tasks that create its GCS state buckets, or for
the secrets tasks (`tf:secrets:*`); `terraform` + `tfenv` only if you want
the plan-only second toolchain.

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
PLAN       …/app-dev-dev-tofu.tfplan           FORMAT     backend config, …
SECRETS    variables/dev.secrets.hcl (absent)  STATE      gs://…-tfstate-dev/app
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
and every `tf:*` task that reaches tofu runs with that as its working
directory, so all paths in `VARS` and `BACKEND` are **stack-relative**.
Defaults to `main`. The directory is `STACK_DIR = STACKS_DIR/STACK`, so
overriding `STACKS_DIR` moves every stack at once.

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

With no `VARS`, a stack loads `variables/<stack>.tfvars` — one named file
rather than a sweep of `variables/`, so a stack can keep several tfvars
files there without a bare run collecting them all. Two rules govern that
file:

- **A multi-env stack MUST NOT have one.** There is no sensible default
  environment, so a bare run should be refused, not answered.
- **A single-stack or multi-stack repo SHOULD have one per stack**, and
  needs no `VARS_MAP` at all.

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
  backend.tf                         # terraform { backend "<type>" {} }
  variables/
    main.tfvars                      # matches the default VARS
    main.backend.hcl                 # matches the default BACKEND
```

`STACK` defaults to `main`, `VARS` to `main:variables/main.tfvars`,
`BACKEND` to the vars id — so `task tf:plan` and `task tf:apply:ask` need
no arguments and neither map needs an entry. Growing a second environment
later is additive: write the tfvars, add a `VARS_MAP` line, and commands
gain a `VARS=` argument.

A single module that instead writes its bucket and prefix straight into
`backend "<type>" { … }` needs no `main.backend.hcl` and no
`backend.tf` — see [the two places a backend
lives](#the-two-places-a-backend-lives) below. Nothing else changes.

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

Each has its own `variables/<stack>.tfvars` and its own backend — a
`variables/<stack>.backend.hcl`, or the location inline in its own `.tf`,
whichever the stack already uses — so each gets its own state prefix,
`TF_DATA_DIR` and plan file:

```
task tf:plan STACK=data
task tf:stacks:list        # every stack, its backends, where each one's state lives
task tf:validate:all       # offline-validate every stack
```

`backend.tf` in each stack is a bare `backend "<type>" {}` — bucket and
prefix come from `-backend-config`, which is what lets one root module
serve every environment's state.

### The two places a backend lives

A `BACKEND` path is one of two things, and tf-stack reads both:

- **A backend config file** — `variables/<id>.backend.hcl` (or
  `.tfbackend`), handed to `init` as `-backend-config`. The `.tf` holds a
  bare `backend "<type>" {}` to receive it. One file per environment,
  which is what makes per-environment state possible.
- **An inline backend** — a `backend "<type>" { … }` block in one of the
  stack's own `.tf` files, with the location written into it. This is the
  layout most terraform repos use. The stack then needs no `.backend.hcl`:
  `BACKEND` defaults to the first `*.tf` with such a block, `init` runs
  without `-backend-config`, and `tf:stacks:list` / `tf:backend` read the
  location straight out of the block. Pin it with `BACKEND=<id>:main.tf`
  if you would rather state it than derive it.

`task tf:backend` prints which one is in play on its `FORMAT` line. Its
`STATE` line — the same value `tf:stacks:list` shows — is
`gs://<bucket>/<prefix>` for a gcs backend, `<type> backend` for an inline
block of any other type, and `local, plan-only` when there is none; a
`.backend.hcl` names no type, so one configuring something other than gcs
is still reported as gcs.

An **empty** `backend "<type>" {}` is not an inline backend — it is the
partial-config form, and its settings still have to arrive from a
`.backend.hcl`. One backend block per root module, so per-environment
state means the `.backend.hcl` form.

**A stack with no backend config at all — no `backend.hcl` and no inline
block — is plan-only**, shown as `WRITABLE no`. Its state is local and
empty, so a plan shows every resource as new, and every writing task
refuses to run against it. That is a deliberate mode: it is how a stack
that duplicates resources another stack already owns is kept harmless
while it is being adopted.

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
`BACKEND_MAP` mapping each id to its `.backend.hcl`). Three choices in
there are load-bearing:

- **No `app.tfvars` and no `app.backend.hcl`, on purpose** — rule 1 above.
  The shared base is named `common.tfvars` instead, so a bare run is
  refused rather than silently picking an environment.
- **The environments need not be symmetric** — a glob matching two
  files, a single file, two named files. Explicit lists make real-world
  asymmetry cost a line rather than an exception.
- **Derived values stay out of tfvars.** A flag like
  `deletion_protection` is computed in `main.tf` from
  `environment == "prod"`, so it cannot be forgotten in an environment
  file.

Per-environment loops: `tf:setup:all` (one bucket per backend),
`tf:init:once:all`, `tf:plan:all` (one plan per name in `VARS_MAP`, each
against its own state). Each iteration is its own `task` run through
`scripts/tf-stack.sh task`, which works out the stack, vars and data dir
afresh and passes on the run-wide selectors, so `task tf:plan:all
STACK=multi-env TF=terraform NO_LOCK=true` holds for every environment. The
forwarded names are `TASK_FORWARD` in the script.

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

## Secrets

Infrastructure needs keys and credentials that cannot live in git. The rule
here is **one secret per variable**: a variable declared `sensitive = true`
or `ephemeral = true` in the stack's `.tf` files *is* a secret, kept in
[Secret Manager](https://cloud.google.com/secret-manager) in
`SECRETS_PROJECT` (by default `BOOTSTRAP_PROJECT`, the project that owns the
state bucket). There is no list of secrets to keep in step with the code,
because the code is the list. A clean clone finds out what it needs with
`task tf:secrets`, fetches it with `task tf:secrets:pull:ask`, and plans.

```hcl
variable "db_password" {
  type      = string
  sensitive = true          # either flag makes it a secret
  ephemeral = true          # and this one keeps it out of state: see below
}                           # no default: a plan refuses to run without it

variable "api_token" {
  type      = string
  sensitive = true
  ephemeral = true
  default   = null          # optional: pulled if it exists, skipped if not
}
```

Secret variables are strings. A secret with any other `type` is an error;
store JSON in the string and `jsondecode(var.x)` in the configuration. Its
default is either absent (required) or `null` (optional); any other default
is an error, because the value would then be in git.

### The first secret

```
task tf:secrets:setup                                      # once per repo: enable the API, check access
task tf:secrets:new:ask STACK=app VARS=dev ID=db_password  # create it, declare the variable, pull
task tf:secrets STACK=app VARS=dev                         # what the stack needs and where each is
task tf:plan    STACK=app VARS=dev                         # plans with the pulled values
```

Creating a cloud secret is a write, so `tf:secrets:new:ask` carries the
`:ask` suffix and an agent's permission rule for `task *:ask` stops to
confirm it, as it does for push and pull. It prompts for the value twice
with the input hidden, or reads it from `FILE=<path>` (relative to the directory you run `task` in) or
stdin. If no variable called `ID` exists it appends one to
`stacks/<stack>/secrets.tf`: `sensitive` and `ephemeral`, no default, so
required. A variable that exists but is neither sensitive nor ephemeral is
refused: mark it first. A secret that already exists is refused too, and
the message names the push command that adds a version instead.

On a new machine, `tf:secrets:pull:ask` is all that is needed. Creating
secrets and adding versions takes `roles/secretmanager.admin` on the
project; pulling takes only `roles/secretmanager.secretAccessor`. All of it
drives `gcloud`, which must be installed and authenticated.

### Ephemeral by default

`sensitive = true` hides a value in plan and apply output and does nothing
else: tofu still writes it in plaintext to state, to the saved plan file,
and to `show -json`. `ephemeral = true` keeps it out of all three. That is
why `tf:secrets:new:ask` declares both.

The cost is where the value may go. An ephemeral value, and anything
computed from it, may feed only:

- a `provider` block, e.g. `access_token = var.token`;
- a write-only argument, one of the `*_wo` attributes such as
  `google_secret_manager_secret_version.secret_data_wo` or
  `google_sql_user.password_wo`. The provider sends it when the resource is
  created and whenever the matching `*_wo_version` changes, and never
  stores it;
- an `ephemeral` resource, a `provisioner` or a `connection` block;
- locals, and child-module outputs marked `ephemeral = true` (a root module
  cannot have one), that carry it on to one of the above.

Anywhere else, a regular resource argument for example, the plan fails with
`Ephemeral value used in non-ephemeral context`. When a value has to go
into such an argument (an attribute with no `*_wo` form), delete
`ephemeral = true` from its variable by hand and keep `sensitive = true`.
It still works as a secret, but its value then lands in state and in every
saved plan file, where anyone who can read the state bucket or the temp dir
can read it.

A saved plan holds no ephemeral value, so tofu needs it again at apply.
`tf:apply:ask` therefore passes the same var files as the plan, the secret
tfvars included. tofu refuses a non-ephemeral value that differs from the
one saved in the plan (`Mismatch between input and plan variable value`)
and takes ephemeral ones as given.

**Version floor.** Ephemeral input variables need OpenTofu 1.11 or later
(Terraform 1.10). `tf:secrets:new:ask` writes `ephemeral = true` into the
variable it declares and does not check the toolchain, so on an older one
the next `validate` fails on the unknown argument. A stack that declares an
ephemeral variable should say so in `required_version` (`>= 1.11.0` for
tofu); a stack on an older tofu can still use secrets by declaring its
variables `sensitive = true` alone, by hand, and accepting the plaintext in
state described above.

### Where things live

```
stacks/<stack>/
  secrets.tf                  committed   variables declared by tf:secrets:new:ask (any .tf will do)
  variables/
    dev.tfvars                committed
    dev.secrets.hcl           committed   the manifest: optional, written by hand, never holds values
    dev.secret.tfvars         IGNORED     written by tf:secrets:pull:ask, mode 600
secrets/                      IGNORED     the repo's one home of file secrets (SECRETS_DIR), at the root
  <stack>/<vars_id>/          IGNORED     one directory per stack and vars id, so file names never collide
```

There is one `SECRETS_DIR` for the whole repo, relative to the repo root and
`secrets` by default. It must not be empty, absolute or contain a `..`
segment, and the tasks refuse it otherwise. Both ignored paths are appended
to the root `.gitignore` by `tf:secrets:setup` and `tf:secrets:pull:ask`
when missing: `*.secret.tfvars`, and `/secrets/` (`/<SECRETS_DIR>/`),
anchored to the root so a module directory that happens to be called
`secrets/` is not ignored. The pull also asks git (`git check-ignore`) about
every file it is about to write and **refuses any that git would not
ignore**, naming the path and the line to add; that check is what makes it
safe for a manifest to point a file somewhere other than `SECRETS_DIR`.

`<vars_id>.secret.tfvars` is passed to tofu as a `-var-file` after the
files `VARS` names, so it wins, whenever it exists; `task tf:vars` lists it
under `FILES`. It is named explicitly, and a `VARS_MAP` glob never loads a
`*.secret.tfvars`: prod's list ends at `variables/prod.tfvars` and would
miss it, dev's `variables/dev*.tfvars` would match it in the middle, and a
broader glob would pick up another environment's.

So **do not name the current secret tfvars in `VARS_MAP`**; it is added for
you, once, last. If a line does carry it, it is skipped in place and added
at the end, so nothing is passed twice. `tf:vars:assert` does not require
it to exist either, so a clean clone can still pull. Any other
`*.secret.tfvars` named in a map is never loaded at all; `tf:vars:assert`
prints a note naming it.

### Names

The Secret Manager id is `<SECRET_PREFIX><stack>-<vars_id>-<variable>`, in
`SECRETS_PROJECT`. So `db_password` for `STACK=app VARS=dev` is
`app-dev-db_password`. Variable names pass through unchanged, and the id is
always computed from the three parts, never parsed back. Set
`SECRET_PREFIX` in the Taskfile to share a project between repos. Secret
Manager ids allow `A-Za-z0-9_-` and at most 255 characters; a stack or
vars_id outside that is reported with the id to set in the manifest
instead.

### The manifest

`variables/<vars_id>.secrets.hcl` changes where a secret lands or which id
backs it. Nothing is required in it: a secret variable with no block is an
inline secret under its convention id.

```hcl
secret "db_password" {
  id = "legacy-db-pw"              # another Secret Manager id, still inline
}

secret "sa_key" {
  file = "sa.json"                 # file secret: written to secrets/<stack>/<vars_id>/sa.json
}

secret "tls_cert" {
  file = "../../certs/dev.pem"     # ./, ../ or / means a path, relative to the stack
}

secret "kubeconfig" {
  file = "../../.kube/config"      # not a variable: a file some other tool reads
}
```

Two kinds:

- **inline** (the default): the value goes into `dev.secret.tfvars` as
  `db_password = "..."`.
- **file** (`file = ...`): the payload is written to the path, mode 600, and
  the variable's value is that path, relative to the stack directory,
  because tofu runs there. A bare name goes under
  `SECRETS_DIR/<stack>/<vars_id>/` at the repo root, so two stacks, or two
  vars ids, can both say `file = "sa.json"`; for `stacks/app` and
  `VARS=dev` the variable holds `../../secrets/app/dev/sa.json`. A path
  starting `./`, `../` or `/` is used as written, relative to the stack, and
  must be ignored by git. Parent directories are created, mode 700.

A file secret's variable holds only the path, so `sensitive` and
`ephemeral` protect the path, not the file. What happens to the content is
up to the configuration: `file(var.sa_key)` in a `provider` block or a
write-only argument stays out of state, and in a regular argument it is
stored there. If the variable is ephemeral, tofu treats `file(var.sa_key)`
as ephemeral too and refuses the regular argument, which is one more reason
to keep the flag.

Only `file` and `id` exist; anything else is an error. So is a block for a
variable that is neither sensitive nor ephemeral (mark it), and a block
whose label is not a variable and has no `file` (there is nowhere to put
it). A block with a `file` whose label is not a variable is a **file-only
secret**: pulled to its path, nothing added to the tfvars, and always
required. Problems anywhere in the manifest or the variables are reported
together and refuse every `tf:secrets` task and every plan.

### The tasks

`tf:secrets:setup` is the one-time step; `tf:secrets:new:ask` the usual way
to add a secret; the rest are what you run day to day. Like the other `:ask`
tasks, `new:ask`, `pull:ask` and `push:ask` write and are meant to be
confirmed.

| Task | What it does |
| --- | --- |
| `tf:secrets:setup` | Enable Secret Manager on `SECRETS_PROJECT` if it is not, check the caller can list secrets (and say which roles are needed if not), gitignore the secret files. Idempotent; the second run only reads |
| `tf:secrets:new:ask` | `ID=<var>` and optionally `FILE=<path>`. Create the secret, declare the variable (sensitive, ephemeral) in `secrets.tf` if it is not declared, then pull. Interactive |
| `tf:secrets` | Report: the project, manifest and tfvars paths, then a row per secret with its kind, whether it is required, its id and destination (from the repo root), its latest version in the cloud (`CLOUD`) and whether it is here (`LOCAL`: `yes`, `no`, or `stale` when the cloud has a newer version than the one pulled) |
| `tf:secrets:pull:ask` | Fetch every secret and write `dev.secret.tfvars` and the file secrets. All or nothing: nothing is written if a required secret is missing, a fetch fails, or a destination is not ignored. Optional secrets that do not exist are skipped with a note. Reports each secret as `new`, `updated` (with the version it replaced) or `unchanged`, and rewrites only what changed: an up-to-date pull writes nothing |
| `tf:secrets:push:ask` | `VAR=<var>`, and optionally `FILE=<path>`. Store a secret: create it, or add a version if the bytes differ from the latest or the latest is destroyed. The source is `FILE`, else a file secret's own path, else stdin |
| `tf:secrets:assert` | Offline guard; fails if a required secret is not on this machine. Runs before every task whose tofu command evaluates the variables (see [The guards](#the-guards)) |

An inline value goes in on stdin, byte for byte; use `printf`, not `echo`,
which adds a newline the secret then contains:

```
printf '%s' "$password" | task tf:secrets:push:ask STACK=app VARS=dev VAR=db_password
```

Values only ever travel through files and stdin, never as arguments, so
they stay out of `ps`, shell history and the task output. The tasks that
handle them run under `umask 077`: the secret tfvars, the file secrets, the
directories created for them and every scratch file are owner-only from the
moment they exist, and the scratch files are removed however the task ends.
`FILE` is relative to the directory you run `task` in.

### What a value looks like in the tfvars

Secret variables are strings, so an inline value is always written as one.

- A payload with no newline is a quoted string with `\`, `"`, `${` and `%{`
  escaped (`${` and `%{` become `$${` and `%%{`, so a value is never
  interpolated).
- A payload with a newline is a heredoc (`<<EOT`, or `EOT1`, `EOT2`... if
  the payload has a line that is itself `EOT`), with `${` and `%{` escaped.
  HCL keeps a heredoc's final newline, so a config that cares writes
  `chomp(var.x)`.
- A zero-length payload is an error: Secret Manager accepts it and
  Terraform would see `""`, which is nearly always a mistake.

Secret Manager caps a payload at 64 KiB. Inline secrets are stored as they
are and must fit. **File secrets are gzipped** (`gzip -n`, so the same file
is the same bytes and an unchanged file does not add a version) and must fit
after compression. On pull the first two bytes decide: `1f 8b` is
gunzipped, anything else is written as it is, so a file uploaded by other
tools uncompressed still works. A new secret is labelled `stack`, `vars`,
`var` (and `encoding=gzip` for files) for whoever audits the project;
nothing reads the labels.

`dev.secret.tfvars` starts with a header, which `tf:secrets` reads to tell
whether you are behind:

```
# written by: task tf:secrets:pull:ask STACK=app VARS=dev
# do not edit, do not commit. Regenerate with the same command.
# db_password = app-dev-db_password@3
```

### Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `SECRETS_PROJECT` | `BOOTSTRAP_PROJECT` | Project holding the secrets. Set it when `BOOTSTRAP_PROJECT` is empty or is not where the secrets belong: the tasks do not check it |
| `SECRET_PREFIX` | empty | Prepended to every convention id |
| `SECRETS_DIR` | `secrets` | The repo's one home of file secrets, relative to the repo root; files go in `<SECRETS_DIR>/<stack>/<vars_id>/` |
| `SECRETS_FILE` | `variables/<vars_id>.secrets.hcl` | The manifest, stack-relative |
| `SECRET_TFVARS` | `variables/<vars_id>.secret.tfvars` | What pull writes, stack-relative |
| `SECRETS_TF` | `secrets.tf` | Where `tf:secrets:new:ask` declares variables, stack-relative |

## Seeds

A **seed** is the small part of a stack that creates the values other stacks need (an OAuth
client, a table of allocated ids), lifted into a module of its own and published through the
maker's state. Users read the seed instead of depending on the whole maker, so the makers
can be applied first, only for their seeds, and then every stack deployed at once. The
channel is the maker's Terraform state (`terraform_remote_state`); nothing else is built
yet.

Only **stateful** values become seeds: anything state has to remember, whether a cloud resource
or a calculation such as a random id or a CIDR allocation. A **stateless** value, one that is
a function of its inputs alone, is an ordinary module in `modules/` that every stack needing
it calls for itself. Stacks never depend on each other directly, only on seeds.

```
stacks/portal/                  # the maker
  main.tf  seeds.tf
  seeds/oauth_client/
    main.tf                     # the seed: its resources, one output per value
    read/main.tf                # the reader: the same outputs, fed from portal's state
stacks/web/main.tf              # a user: module "oauth" { source = "../portal/seeds/oauth_client/read" ... }
```

Three files, only the first by hand. The seed is an ordinary module; `seeds.tf` holds its call
and one root output, `seed_<name>`, which is the whole seed as an object; the reader is plain
Terraform that `task tf:seed:new` writes for you. Nothing is registered: the tasks find
seeds by reading these `.tf` files.

```hcl
# stacks/portal/seeds/oauth_client/main.tf
resource "google_iap_client" "this" { ... }

output "client_id" { value = google_iap_client.this.client_id }
output "client_secret" {
  value     = google_iap_client.this.secret
  sensitive = true
}
```

```
task tf:seed:new STACK=portal SEED=oauth_client     # reader + the call and output in seeds.tf
task tf:init:init STACK=portal                      # the new module call needs an init
```

The scaffold is specialised to the maker's backend (`local` and `gcs` are supported, any
other type is refused): it takes the state location from `variables/<maker>.backend.hcl`, or
from the `.tf` holding the backend block when the stack keeps its backend inline. It also
writes a **placeholder** for each output, `"placeholder-<name>"`. Replace them with
well-formed values (the real one where it is known in advance, like a client id). The reader's
outputs must keep the seed's names and `sensitive` flags; `task tf:seeds:check` compares them.

### Moving existing resources into a seed

When the stack already has the resources, move them into the seed instead of creating new
ones: write the seed as above, delete the resources from the stack's root, and add a `moved`
block for each, also in the root. Anything else in the stack that used them now reads
`module.oauth_client.<output>`.

```hcl
# stacks/portal/moved.tf
moved {
  from = google_iap_client.this
  to   = module.oauth_client.google_iap_client.this
}
```

A plan with `-target` must cover both sides of a move, or tofu refuses it ("Moved resource
instances excluded by targeting"). So for every root `moved` block with one side inside a seed
call, `tf:seed:plan` also targets the other side. The seed plan then shows `has moved to`,
with nothing created or destroyed. Keep the blocks after the apply: by then the old addresses
match nothing.

### Using a seed

From another stack, call the reader and name the maker's backend id:

```hcl
module "oauth" {
  source = "../portal/seeds/oauth_client/read"
  maker  = "standard"            # BACKEND id of the maker's run: portal's standard.backend.hcl
}

resource "google_cloud_run_v2_service" "web" {
  # ... module.oauth.client_id, module.oauth.client_secret
}
```

**Same stack, two instances.** `portal` runs as `VARS=standard` and `VARS=beta`; beta should reuse
standard's client, not make its own. That is a hand-written toggle in the stack, with the
variable true in the maker's tfvars:

```hcl
variable "oauth_client_maker" {
  type    = bool
  default = false                # true in standard.tfvars
}

module "oauth_client" {
  source = "./seeds/oauth_client"
  count  = var.oauth_client_maker ? 1 : 0
}

module "oauth_client_read" {
  source = "./seeds/oauth_client/read"
  count  = var.oauth_client_maker ? 0 : 1
  maker  = "standard"
}

locals {
  oauth_client = var.oauth_client_maker ? module.oauth_client[0] : module.oauth_client_read[0]
}

output "seed_oauth_client" {
  value     = one(module.oauth_client)    # null where the seed is not made
  sensitive = true
}
```

The two branches have the same type because the reader's outputs mirror the seed's.

### Placeholders and the guard

Until the maker has applied the seed, its state has no value to read. The reader does not
fail: it returns the placeholders, so a user can still be planned. A plan in that state
shows them:

```
  + resource "terraform_data" "app" {
      + input = { client_id = "placeholder-client_id", ... }
```

and any apply refuses. The reader also plans a `placeholder_guard` resource whose
postcondition can never hold, so applying that plan fails and creates nothing that uses the seed:

```
Error: Resource postcondition failed
  seed portal.oauth_client is a placeholder: its maker (stack portal, BACKEND=standard)
  has not applied it. Seed first with task tf:seeds:apply:ask, then plan again.
```

Once the maker has applied the seed, planning the user again reads the real values and
removes the guard.

### Two phases

```
task tf:seeds:apply:ask        # 1. seed: every maker stack, in dependency order, only its seed calls
task tf:deploy:plan            # 2. deploy: plan every stack...
task tf:deploy:apply:ask       #    ...then apply every stack, four at a time (PARALLEL=n)
```

The seed phase is `tf:seed:plan` (a plan limited with `-target` to the stack's seed calls, saved
beside the normal plan file as `*.seed.tfplan`) and `tf:seed:apply:ask` for each maker stack
and `VARS` id, applied only when there are changes. `tf:seeds:plan` stops after the plans.
tofu's warning that `-target` is in use is expected here. A stack goes after the stacks
whose seeds it reads, which the tasks work out from the `.tf` files: a file under its `seeds/`
that calls another stack's reader, or a seed call in its root that refers to one. A cycle is an
error naming the stacks.

The deploy phase initialises every stack and `VARS` id one at a time (the plugin cache is not
safe under concurrent init), runs the plans or applies in parallel with a log per unit under
`<TMP>/deploy/`, then prints every log in full followed by a summary, and exits 1 if
any unit failed. An apply skips plan-only stacks. Run it before the seed phase and the makers
apply while the users hit the guard: the failure is the point.

### Checking

```
$ task tf:seeds:list
STACK   SEED          CALL          OUTPUT             READERS
portal  oauth_client  oauth_client  seed_oauth_client  portal:seeds.tf,web:main.tf
$ task tf:seeds:check
```

`tf:seeds:check` exits 1 listing every problem: a seed with no call whose `source` is
exactly `./seeds/<seed>`; no root output `seed_<seed>`; no `read/`; a reader whose outputs
differ from the seed's in name or `sensitive`; a reader `source` that is the `read/` of no
existing seed; a seed dependency cycle.

### Limits (v1)

- Only the `remote_state` channel; `gcs` and `secret_manager` channels are not built.
- A `gcs` reader decides whether the maker has written its state by listing the bucket for
  `<prefix>/default.tfstate`; that check has not been run against GCP.
- A `local` reader treats an empty state file as absent, since a plan of the maker creates
  one to take its lock.
- Seeds are found one level down: `STACKS_DIR/<stack>/seeds/<seed>/`.
- The reader mirrors the seed's outputs by hand; the check catches drift, nothing regenerates it.
- Seed order is per stack; the `VARS` ids of one stack run in `VARS_MAP` order, so a seed
  reading another `VARS` id of its own stack may need a second `tf:seeds:apply:ask` (the guard
  keeps the first one safe). Ordering follows direct `module.<reader>` references only.

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
| `tf:setup` | Create and version the GCS bucket `BACKEND` names — or `STATE_BUCKET` under a prefix of the stack's own, for a stack with no backend config yet. Idempotent, and read-only against a bucket that already exists and is versioned |
| `tf:setup:all` | `tf:setup` once per backend the stack actually has |
| `tf:init:once` | Init unless `TF_DATA_DIR` already exists. Most plan/apply tasks depend on this |
| `tf:init:init` | Init unconditionally; retries with `-reconfigure` if the backend cache is stale |
| `tf:init:once:all` | `tf:init:once` for every backend the stack has |
| `tf:init:local` | Init with `-backend=false` into a separate data dir. Offline, no credentials |
| `tf:init:upgrade:ask` | Re-init with `-upgrade`, rewriting the lock file |

`tf:setup` creates GCS buckets and nothing else, so it and `tf:setup:all`
are only present in a repo whose state lives in GCS; elsewhere the state
store is provisioned out of band and these two tasks are absent. Every
other `tf:*` task is indifferent to the backend, because `init` only
passes `-backend-config=<file>` through.

### `tf:fmt:*`, `tf:validate:*` — checks

| Task | What it does |
| --- | --- |
| `tf:fmt` / `tf:fmt:check` | `fmt -recursive` on the stack, rewriting / checking only |
| `tf:fmt:check:all` | The same check across every stack and module |
| `tf:validate` | `validate` against the real backend (inits first) |
| `tf:validate:local` | `validate` offline — no backend, no credentials |
| `tf:validate:all` | Offline-validate every stack under `STACKS_DIR` |
| `tf:verify` | Offline self-check of the install — scripts, tasks, maps and guards. `-- --offline` skips the two that run tofu |

`task test` runs `tf:fmt:check:all` and `tf:validate:all` — the offline
check set.

### `tf:secrets:*` — secrets

Secret Manager, one secret per sensitive variable. The tasks, the manifest
and the layout are described under [Secrets](#secrets).

| Task | What it does |
| --- | --- |
| `tf:secrets:setup` / `:new` | One-time setup; create a secret (`ID=<var> [FILE=<path>]`) and declare its variable |
| `tf:secrets` | What the stack needs, and each secret's state in the cloud and here |
| `tf:secrets:pull:ask` / `:push:ask` | Fetch every secret into `<vars_id>.secret.tfvars` and the file secrets; store one (`VAR=<var> [FILE=<path>]`) |
| `tf:secrets:assert` | Offline: fail unless every required secret is on this machine |

### `tf:plan:*` — plan

| Task | What it does |
| --- | --- |
| `tf:plan` | Plan and save to `<TMP>/<stack>-<vars_id>-<backend_id>-<tf>.tfplan` |
| `tf:plan:all` | `tf:plan` once per name in `VARS_MAP` the stack has files for, one plan file each; falls back to one default run if it has none |
| `tf:plan:show` | Re-read the saved plan for this combination |
| `tf:plan:debug` | Plan with full provider HTTP logging to `<TMP>/<stack>-debug-<tf>.log` |

The plan filename carries all four keys, so distinct combinations never
share one. With one filename per stack, planning prod after dev would
leave `tf:apply:ask` holding prod's plan under a dev invocation, with
nothing to notice. `tf:apply:ask` does pass the var files again (a saved
plan holds no ephemeral value, so tofu needs those again), but tofu
refuses a non-ephemeral value that differs from the one in the plan, so
the plan stays the record of what was planned.

`tf:plan:debug` writes OAuth bearer tokens and full API payloads to that
log. It stays in the gitignored temp dir; redact before attaching it to
a bug report.

### Write tasks

`tf:apply:ask`, `tf:refresh:ask` and `tf:destroy:deny` each refuse first
if the stack is plan-only, if `TF` is not `tofu`, or if `VARS` does not
resolve. `tf:output` and `tf:clean` are ungated.

| Task | What it does |
| --- | --- |
| `tf:apply:ask` | Apply the **saved plan file**, not a fresh plan, with the plan's var files (ephemeral values are not saved in it) |
| `tf:refresh:ask` | `apply -refresh-only` — reconcile state with reality, change nothing |
| `tf:force-unlock:ask` | `force-unlock -force <var-files> ID=<lock id>` — drop a stale state lock on the chosen `BACKEND` |
| `tf:destroy:deny` | `destroy` everything the stack manages |
| `tf:output` | Print the stack's outputs |
| `tf:clean` | Remove every toolchain's provider dir, the lock file and stash, and the temp dir |

### `tf:seeds:*`, `tf:seed:*`, `tf:deploy:*` — seeds and the two phases

The singular tasks take `STACK` and `VARS` like `tf:plan`; the plural ones cover the whole
repo. See [Seeds](#seeds).

| Task | What it does |
| --- | --- |
| `tf:seeds:list` | Every seed: stack, call, root output, and the `stack:file` of each reader |
| `tf:seeds:check` | Lint every seed and the seed order; exit 1 on a problem |
| `tf:seed:new` | `SEED=<name>`. Scaffold the reader, the seed stub if the seed is new, and the call and output in `seeds.tf`. Files only, so no `:ask` |
| `tf:seed:plan` | Plan only the stack's seed calls (`-target`, plus the other side of a move into one), saved as `<plan file>.seed.tfplan` |
| `tf:seed:apply:ask` | Apply that saved seed plan |
| `tf:seeds:plan` | `tf:seed:plan` for every maker stack and `VARS` id, in seed order |
| `tf:seeds:apply:ask` | For each of those: plan, and apply when there are changes |
| `tf:deploy:plan` | `tf:plan` for every stack and `VARS` id, `PARALLEL` (default 4) at a time, a log per unit in `<TMP>/deploy/` |
| `tf:deploy:apply:ask` | `tf:apply:ask` for the same, plan-only stacks skipped |

## The guards

Five tasks refuse a run before tofu starts. Worth knowing by
name, because their messages are what you see when something is
misconfigured — and each prints the names that *do* exist, so the
recovery is in the error.

| Guard | Refuses when | Because |
| --- | --- | --- |
| `tf:vars:assert` | `VARS` names nothing in `VARS_MAP`, or a glob matches no file (`*.secret.tfvars` entries excepted: `tf:secrets:assert` owns those) | tofu treats a missing `-var-file` as fine and plans from variable defaults |
| `tf:backend:assert` | `BACKEND` resolves to no backend config that exists — no `backend.hcl`, no `.tf` with an inline backend block | otherwise tofu says `bucket must be set` — true, and silent about what was missing |
| `tf:stack:assert` | a writing task targets a stack with no backend config of either form | its state is local and empty; an apply would create a second copy of resources another stack owns |
| `tf:toolchain:assert:tofu`\* | a writing task runs under `TF=terraform` | both toolchains share one remote state |
| `tf:secrets:assert` | a required secret is not on this machine: an inline one with no line in `<vars_id>.secret.tfvars`, a file one whose file does not exist | tofu would prompt for the variable, or plan with a missing credential file |

\* named `tf:toolchain:assert:terraform` in a terraform-only repo — the
purpose is "one toolchain writes", named after whichever one that is.

`tf:secrets:assert` runs right after `tf:vars:assert` in every task whose
tofu command evaluates the variables: `tf:plan`, `tf:plan:debug`,
`tf:apply:ask`, `tf:refresh:ask` and `tf:destroy:deny`. It reads the
variables and the manifest and nothing else, so it needs neither network
nor `gcloud`. It stays out of `tf:force-unlock:ask`, which only touches the
lock: a missing secret must not block an emergency unlock.

## Local state

Everything tf-stack writes locally is gitignored: the configured `TMP`
dir (plan files, the debug log, stashed locks, plugin cache),
`.terraform-*/` (per-toolchain, per-backend working directories),
`<stack>.env` (written by `tf:use`), `.terraform.lock.hcl`, and the
secrets (`variables/*.secret.tfvars` and the repo's `secrets/` directory). `task
tf:clean` removes the temp dir, the data directories and the lock file, and
leaves `<stack>.env`, which `tf:use:clear` drops, and the secrets: pulling
them again costs a round trip, and a file secret may be the only copy you
have been editing. Delete them by hand. `task tmp:setup` recreates the temp
dir and is already a dependency of every task that needs it.
