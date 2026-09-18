# Backend flavors

`init` only ever passes `-backend-config=<file>` through to tofu, so
`tf:init:*`, `tf:plan*`, `tf:apply:ask`, the guards, `tf:use`, and every
discovery task work identically on every flavor from day one. The two
places that are *not* backend-agnostic are `tf_setup` (which needs a
CLI and credentials to provision storage) and the human-readable `STATE`
string `tf:stacks:list`/`tf:backend` print, which is rendered by a small
`BACKEND_STATE` helper that sniffs the keys present in a stack's
`variables/<id>.backend.hcl`.

A stack with **no** `backend.hcl` at all is a supported mode, not a
misconfiguration, on every flavor: `WRITABLE no`, `STATE local,
plan-only`, and `tf:stack:assert` refuses every writing task against it.

## At a glance

| Flavor | `backend.hcl` keys | `STATE` string | `tf_setup` | CLI / credentials | What degrades when absent |
| --- | --- | --- | --- | --- | --- |
| **gcs** | `bucket`, `prefix` | `gs://<bucket>/<prefix>` | implemented — idempotent describe-then-create, then enables versioning | `gcloud`, authenticated (`gcloud auth login` or ADC) | `tf:setup` refuses with a clear message; `plan`/`apply`/discovery still work once the bucket exists and tofu's own GCS auth can reach it |
| **local** | `path` | the path itself | implemented — `mkdir -p $(dirname path)` | none | nothing degrades; state lives on this machine only, so it is not shared between operators or CI runners |
| **s3** | `bucket`, `key`, `region`, `use_lockfile` | `s3://<bucket>/<key>` | documented only — prints the keys found and the exact `aws` commands, then exits 1 | `aws` CLI, authenticated | `tf:setup` exits 1 until you paste in the adapter below; everything else works once the bucket exists and AWS credentials are exported |
| **azurerm** | `storage_account_name`, `container_name`, `key` | `az://<account>/<container>/<key>` | documented only — prints the keys found and the exact `az` commands, then exits 1 | `az` CLI, authenticated (`az login`) | same as s3: `tf:setup` exits 1 until adapted; rest works once the storage account and container already exist |
| **other** (`http`, `cloud`, `consul`, `remote`, …) | whatever that backend defines | `address` value, `tfe://<org>/<workspace>` for `cloud`/`remote`, or the filename plus `(unrecognized backend)` | not applicable — `tf:setup`/`tf:setup:all` are omitted entirely | whatever that backend needs, outside tf-stack's scope | nothing tf-stack owns degrades — provisioning is entirely out of band |
| **none** | (no file) | `local, plan-only` | not applicable | none | every writing task refuses (`tf:stack:assert`); this is the "adopting a stack, not ready to write yet" mode |

## gcs and local: fully implemented

These two are the only flavors `tf_setup` provisions for you, and both
ship in `scripts/tf-stack.sh` unmodified — nothing to paste in.

`gcs` describes the bucket first (so re-running is a no-op), otherwise
enables the Storage API and creates it with
`--uniform-bucket-level-access --public-access-prevention`, then always
runs `buckets update --versioning` so a bucket created by hand earlier
still ends up versioned. The project that owns the bucket is a separate
value from the project(s) your stacks manage — set once, not per stack.

`local` only ensures the parent directory of `path` exists; the state
file itself is created by tofu on first `apply`. Because that file *is*
the state, never delete it, or the `.terraform-*/` directory next to it,
without asking first — there is no remote copy to recover from.

## s3 and azurerm: documented only

Neither is implemented in the shipped script. Running `tf:setup` against
either prints the keys `BACKEND` resolved and the hand-run commands that
would provision them, then exits 1 — deliberately, so a repo can adopt
these flavors without a builder guessing at IAM, resource groups, or
locking semantics it cannot verify.

The snippets below are **paste-in adapters**, not shipped code. They go
inside `tf_setup`, below the `# ---- ADAPTER ----` marker, as additional
`case "$V_TF_BACKEND"` arms alongside the existing `gcs`/`local` ones.
Apply either **only when the user explicitly asks for it**, and report
it back as **unverified** — it has not run against a real bucket or
storage account the way the gcs path has.

### `backend.hcl` for s3

```hcl
bucket       = "example-tfstate"
key          = "app/terraform.tfstate"
region       = "us-east-1"
use_lockfile = true
```

Prefer tofu's native `use_lockfile = true` (tofu ≥ 1.10) over a
DynamoDB lock table: one fewer resource to provision and tear down, no
`dynamodb_table` key to keep in sync with a table that might not exist
yet. If a stack is migrating off an older config that set
`dynamodb_table`, drop that key when adding `use_lockfile` — the two
locking mechanisms should not run at once.

### paste-in adapter: s3 (UNVERIFIED)

```bash
    s3)
      command -v aws >/dev/null 2>&1 || {
        echo "aws not found. Install the AWS CLI and run 'aws configure'." >&2
        exit 1
      }

      local bucket region
      bucket=$(sed -n 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$backend")
      region=$(sed -n 's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$backend")
      [ -n "$bucket" ] || { echo "$backend names no bucket." >&2; exit 1; }
      [ -n "$region" ] || region="$state_location"

      if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        echo "s3://$bucket already exists"
      else
        echo "creating s3://$bucket in $region"
        if [ "$region" = "us-east-1" ]; then
          aws s3api create-bucket --bucket "$bucket"
        else
          aws s3api create-bucket --bucket "$bucket" --region "$region" \
            --create-bucket-configuration LocationConstraint="$region"
        fi
      fi

      aws s3api put-bucket-versioning --bucket "$bucket" \
        --versioning-configuration Status=Enabled

      echo "state bucket ready: s3://$bucket (BACKEND=$V_BACKEND_ID)"
      echo "reminder: this does not create a lock table -- use backend.hcl's" >&2
      echo "'use_lockfile = true' instead of dynamodb_table." >&2
      ;;
```

### `backend.hcl` for azurerm

```hcl
storage_account_name = "exampletfstate"
container_name       = "tfstate"
key                  = "app.terraform.tfstate"
```

### paste-in adapter: azurerm (UNVERIFIED)

```bash
    azurerm)
      command -v az >/dev/null 2>&1 || {
        echo "az not found. Install the Azure CLI and run 'az login'." >&2
        exit 1
      }

      local account container
      account=$(sed -n 's/^[[:space:]]*storage_account_name[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$backend")
      container=$(sed -n 's/^[[:space:]]*container_name[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$backend")
      [ -n "$account" ] || { echo "$backend names no storage_account_name." >&2; exit 1; }
      [ -n "$container" ] || { echo "$backend names no container_name." >&2; exit 1; }

      if az storage account show --name "$account" >/dev/null 2>&1; then
        echo "storage account $account already exists"
      else
        echo "$account does not exist. Creating one needs a resource group," >&2
        echo "which backend.hcl has no key for -- run by hand:" >&2
        echo "  az storage account create --name $account --resource-group <rg> \\" >&2
        echo "    --location $state_location --sku Standard_LRS --kind StorageV2" >&2
        exit 1
      fi

      az storage container create --account-name "$account" \
        --name "$container" --auth-mode login

      echo "state container ready: az://$account/$container (BACKEND=$V_BACKEND_ID)"
      ;;
```

azurerm's resource group is not one of `backend.hcl`'s keys, so this
adapter can create the container once the storage account already
exists, but stops and asks for the account itself — creating storage
accounts touches subscription-level naming and quota decisions this
tool has no basis to make unattended.

## `other` backends

`http`, `cloud`, `consul`, `remote` and anything else tofu supports are
left alone entirely: `TF_BACKEND` stays whatever the stack's own
`backend "<flavor>" {}` block says, `tf:setup`/`tf:setup:all` are
omitted from the emitted Taskfile so there is nothing to accidentally
run against them, and `BACKEND_STATE` falls back to printing an
`address` field, a `tfe://<org>/<workspace>` pair for Terraform
Cloud/Enterprise-shaped config, or the bare filename tagged
`(unrecognized backend)` when it recognizes neither. Everything that
does not touch provisioning — plan, apply, the guards, `tf:use`,
discovery — still works, because none of it is backend-specific.
