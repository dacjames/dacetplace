#!/usr/bin/env bash
#
# tf-stack-version: 1
# installed by /dev-tf (dacbots) -- edit only the ADAPTER section
#
# a simple toolkit for terraform & opentofu

# Portability note: \t inside a sed/grep bracket expression ([ \t]) is a GNU
# extension -- stock macOS /usr/bin/sed and BSD grep read it as "space,
# backslash, or the letter t", so a tab-indented line matches nothing. Every
# sed/grep bracket expression below uses the POSIX [[:space:]] class instead.
# awk is different: its ERE honors \t inside brackets in both gawk and BSD
# awk, so the awk [ \t] sites below are left exactly as they are -- don't
# "unify" them with the sed/grep fix above; that would break the proven half.

set -euo pipefail

# Whitespace-normalize a <id>:<glob>[,<glob>...] spec so the human-friendly
# spacings all resolve: "dev: a.tfvars, b.tfvars" -> "dev:a.tfvars,b.tfvars".
# Only the separators are touched -- the first colon and each comma -- so a
# path is never rewritten. [[:space:]] not [ \t]: inside a bracket expression
# \t is a GNU sed extension, and stock macOS sed reads it as space/backslash/t.
_normalize_spec() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      -e 's/[[:space:]]*:[[:space:]]*/:/' \
      -e 's/[[:space:]]*,[[:space:]]*/,/g'
}

# VARS_RESOLVED / BACKEND_RESOLVED: expand a bare id (VARS=dev) through its
# map to the spelled-out <id>:<glob,...> or <id>:<path>. A value that already
# has a ':' passes through (normalized) -- only the bare-id form needs a
# lookup, and an id with no match in the map resolves to empty (caller's job
# to refuse that, as vars:assert-vars / backend:assert-backend do). Both the
# id and the map line are whitespace-normalized here, once, because every
# consumer (VAR_FILES, VARS_IDS_PRESENT, BACKEND_FILE, the asserts) reads the
# output through `cut -d: -f2-`.
VARS_RESOLVED() {
  local _VARS
  _VARS=$(printf '%s' "$1" | _normalize_spec)
  local VARS_MAP="$2"

  case "$_VARS" in
    *:*) printf '%s' "$_VARS" ;;
    *) printf '%s\n' "$VARS_MAP" |
          awk -v id="$_VARS" -F: '{sub(/^[ \t]+/, ""); k=$1; gsub(/[ \t]+$/, "", k)} k == id {printf "%s", $0; exit}' |
          _normalize_spec ;;
  esac
}

# USE_VARS / USE_BACKEND: the last VARS=/BACKEND= line `tf:use` wrote to
# STACK.env, or empty if the file or the key is missing -- never an error,
# since having nothing remembered is the common case.
USE_VARS() {
  local ENV_FILE="$1"

  [ -f "$ENV_FILE" ] || exit 0
  sed -n 's/^[[:space:]]*VARS[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" | tail -n 1 | sed 's/[[:space:]]*$//'
}

# The -var-file=... flags for a resolved VARS. Runs from STACK_DIR because the
# globs are stack-relative; a glob matching nothing is silently dropped here
# (vars:assert-vars is what catches a typo, not this).
VAR_FILES() {
  local STACK_DIR="$1"
  local VARS_RESOLVED="$2"

  cd "$STACK_DIR" 2>/dev/null || exit 0
  local globs
  globs=$(printf '%s' "$VARS_RESOLVED" | cut -d: -f2-)
  IFS=','
  for f in $globs; do
    if [ -e "$f" ]; then
      printf '%s ' "-var-file=$f"
    fi
  done
  exit 0
}

# The VARS_MAP ids this stack can actually plan: those whose globs all match at
# least one file under STACK_DIR. VARS_MAP is global while a stack's variables/
# is not, so in a repo with several stacks most ids belong to some other stack;
# tf:plan:all skips those rather than failing on them, the same courtesy
# tf:setup:all extends to backends. Prints nothing when no id matches, which is
# the caller's cue to fall back to the stack's default VARS.
#
# Takes its two inputs as arguments rather than reading V_STACK_DIR/V_VARS_MAP,
# because tf:plan:all cannot carry the tf_stack_env block: with it in place, the
# `task tf:plan VARS=$v` calls in its loop lose VARS and silently plan the
# stack's default instead. Same bug the `inline because` comment there refers to.
VARS_IDS_PRESENT() {
  local STACK_DIR="$1"
  local VARS_MAP="$2"

  local id resolved globs
  for id in $(printf '%s\n' "$VARS_MAP" | awk -F: '{sub(/^[ \t]+/, "")} NF {print $1}'); do
    resolved=$(VARS_RESOLVED "$id" "$VARS_MAP")
    globs=$(printf '%s' "$resolved" | cut -d: -f2-)
    [ -n "$globs" ] || continue
    # In a subshell: the cd is stack-relative like the globs are, and a glob
    # that matches nothing exits non-zero, disqualifying the whole id.
    (
      cd "$STACK_DIR" 2>/dev/null || exit 1
      IFS=','
      for g in $globs; do
        set -- $g
        [ -e "$1" ] || exit 1
      done
    ) && printf '%s\n' "$id"
  done
  # An empty list is an answer, not a failure: without this the status of the
  # last mismatched id would leave the whole script exiting 1.
  return 0
}

# See USE_VARS -- same thing, for the BACKEND= line.
USE_BACKEND() {
  local ENV_FILE="$1"

  [ -f "$ENV_FILE" ] || exit 0
  sed -n 's/^[[:space:]]*BACKEND[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" | tail -n 1 | sed 's/[[:space:]]*$//'
}

# See VARS_RESOLVED -- same lookup, over BACKEND_MAP.
BACKEND_RESOLVED() {
  local _BACKEND
  _BACKEND=$(printf '%s' "$1" | _normalize_spec)
  local BACKEND_MAP="$2"

  case "$_BACKEND" in
    *:*) printf '%s' "$_BACKEND" ;;
    *) printf '%s\n' "$BACKEND_MAP" |
          awk -v id="$_BACKEND" -F: '{sub(/^[ \t]+/, ""); k=$1; gsub(/[ \t]+$/, "", k)} k == id {printf "%s", $0; exit}' |
          _normalize_spec ;;
  esac
}

# The path half of BACKEND_RESOLVED -- one file, not a glob list, since a
# stack has exactly one backend config per backend_id.
BACKEND_FILE() {
  local BACKEND_RESOLVED="$1"

  printf '%s' "$BACKEND_RESOLVED" | cut -d: -f2-
}

# BACKEND_STATE -- the human-readable "where does state live" string for a
# backend.hcl. Sniffs the flavor from whichever keys are present, so a
# mixed-backend repo needs no extra config: bucket+prefix -> gs://b/p,
# bucket+key -> s3://b/k, storage_account_name+container_name+key ->
# az://a/c/k, path -> the path as-is, address -> the address as-is,
# organization+workspaces{name} -> tfe://org/workspace. No file -> "local,
# plan-only". None of the above -> the filename, flagged unrecognized.
#
# bucket alone is ambiguous between gcs and s3, so it's disambiguated against
# the stack's own `backend "<flavor>" {}` block, falling back to V_TF_BACKEND
# when no .tf file says so.
BACKEND_STATE() {
  local file="$1"
  local stack_dir="$2"

  [ -f "$file" ] || { printf 'local, plan-only'; exit 0; }

  local bucket prefix key storage_account container path address organization wsname
  bucket=$(sed -n 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$file")
  prefix=$(sed -n 's/^[[:space:]]*prefix[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$file")
  key=$(sed -n 's/^[[:space:]]*key[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$file")
  storage_account=$(sed -n 's/^[[:space:]]*storage_account_name[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$file")
  container=$(sed -n 's/^[[:space:]]*container_name[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$file")
  path=$(sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$file")
  address=$(sed -n 's/^[[:space:]]*address[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$file")
  organization=$(sed -n 's/^[[:space:]]*organization[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$file")
  wsname=$(sed -n 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$file")

  if [ -n "$storage_account" ] && [ -n "$container" ] && [ -n "$key" ]; then
    printf 'az://%s/%s/%s' "$storage_account" "$container" "$key"
    exit 0
  fi
  if [ -n "$organization" ] && [ -n "$wsname" ]; then
    printf 'tfe://%s/%s' "$organization" "$wsname"
    exit 0
  fi
  if [ -n "$bucket" ] && [ -n "$key" ]; then
    printf 's3://%s/%s' "$bucket" "$key"
    exit 0
  fi
  if [ -n "$bucket" ] && [ -n "$prefix" ]; then
    printf 'gs://%s/%s' "$bucket" "$prefix"
    exit 0
  fi
  if [ -n "$bucket" ]; then
    # bucket alone is ambiguous between gcs and s3 -- ask the stack's own
    # backend "<flavor>" declaration before falling back to V_TF_BACKEND.
    local flavor
    flavor=$(grep -ho 'backend[[:space:]]*"[a-z0-9_]*"' "$stack_dir"/*.tf 2>/dev/null |
              sed -n 's/.*"\(.*\)"/\1/p' | head -1) || true
    [ -n "$flavor" ] || flavor="$V_TF_BACKEND"
    case "$flavor" in
      s3) printf 's3://%s' "$bucket" ;;
      *) printf 'gs://%s' "$bucket" ;;
    esac
    exit 0
  fi
  if [ -n "$path" ]; then
    printf '%s' "$path"
    exit 0
  fi
  if [ -n "$address" ]; then
    printf '%s' "$address"
    exit 0
  fi

  printf '%s (unrecognized backend)' "$(basename "$file")"
  exit 0
}

# tf:use -- write the VARS (and BACKEND, if given) to remember for this stack
# into STACK.env.
tf_use() {
  local file="$V_ENV_FILE"

  touch .gitignore
  grep -qxF '*.env' .gitignore || echo '*.env' >> .gitignore

  mkdir -p "$V_TMP"
  local new="$V_TMP/$(basename "$file").new"
  if [ -f "$file" ]; then
    grep -v '^[[:space:]]*\(VARS\|BACKEND\)[[:space:]]*=' "$file" > "$new" || true
  else
    : > "$new"
  fi

  local vars="$V_VARS"
  [ -n "$vars" ] || vars="$V_USE_VARS"
  [ -n "$vars" ] || {
    echo "nothing to remember: pass VARS=<id>, e.g." >&2
    echo "  task tf:use STACK=$V_STACK VARS=dev" >&2
    rm -f "$new"
    exit 1
  }
  printf 'VARS=%s\n' "$vars" >> "$new"

  local derived
  if [ -n "$V_BACKEND" ]; then
    printf 'BACKEND=%s\n' "$V_BACKEND" >> "$new"
    derived=0
  else
    derived=1
  fi
  mv "$new" "$file"

  echo "$file: VARS=$vars"
  echo "resolves to: $V_VARS_RESOLVED"
  if [ "$derived" = 0 ]; then
    echo "$file: BACKEND=$V_BACKEND"
    echo "resolves to: $V_BACKEND_RESOLVED"
  else
    echo "backend: $V_VARS_ID, derived from VARS -- not written, so it follows VARS"
    if [ -n "$V_USE_BACKEND" ]; then
      echo "dropped the remembered BACKEND=$V_USE_BACKEND; restate it to keep it:"
      echo "  task tf:use STACK=$V_STACK VARS=$vars BACKEND='$V_USE_BACKEND'"
    fi
  fi
  echo "forget it with: task tf:use:clear STACK=$V_STACK"
}

# tf:stacks:list -- one row per stack, one sub-row per backend.hcl it has.
tf_stacks_list() {
  printf '%-14s %-9s %-9s %s\n' NAME WRITABLE BACKEND STATE
  local s first backend id state
  for s in $V_STACKS; do
    first=1
    for backend in "$V_STACKS_DIR/$s"/variables/*.backend.hcl; do
      [ -f "$backend" ] || continue
      id=$(basename "$backend" .backend.hcl)
      state=$(BACKEND_STATE "$backend" "$V_STACKS_DIR/$s")
      if [ "$first" = 1 ]; then
        printf '%-14s %-9s %-9s %s\n' "$s" yes "$id" "$state"
        first=0
      else
        printf '%-14s %-9s %-9s %s\n' '' '' "$id" "$state"
      fi
    done
    if [ "$first" = 1 ]; then
      printf '%-14s %-9s %-9s %s\n' "$s" no '-' "local, plan-only"
    fi
  done
}

# tf:backend:assert -- refuse to proceed if BACKEND doesn't resolve to a real
# backend.hcl, with a message that says why.
tf_backend_assert() {
  fail() {
    echo "$1" >&2
    echo "BACKEND is <backend_id>:<path> and its path is stack-relative: this runs" >&2
    echo "with dir: $V_STACK_DIR, so 'variables/dev.backend.hcl' means" >&2
    echo "$V_STACK_DIR/variables/dev.backend.hcl, not a path from the repo root." >&2
    exit 1
  }

  local backend="$V__BACKEND"
  local resolved="$V_BACKEND_RESOLVED"
  if [ -z "$resolved" ]; then
    echo "BACKEND=$backend is not a name in BACKEND_MAP. Known names:" >&2
    printf '%s\n' "$V_BACKEND_MAP" | awk -F: '{sub(/^[ \t]+/, "")} NF {print "  " $1}' >&2
    echo "Or spell it out: BACKEND=$backend:<path>" >&2
    exit 1
  fi
  case "$V_BACKEND_ID" in
    '') fail "BACKEND=$backend has an empty backend_id." ;;
    *[!A-Za-z0-9._-]*) fail "backend_id '$V_BACKEND_ID' must be [A-Za-z0-9._-]; it names TF_DATA_DIR and the plan file." ;;
  esac
  [ -n "$V_BACKEND_FILE" ] || fail "BACKEND=$backend selects no file."
  if [ ! -f "$V_BACKEND_FILE" ]; then
    local found
    found=$(ls variables/*.backend.hcl 2>/dev/null || true)
    if [ -n "$found" ]; then
      echo "BACKEND=$V_BACKEND_ID selects $V_BACKEND_FILE, which does not exist in" >&2
      echo "$V_STACK_DIR -- but that stack does have backends:" >&2
      printf '%s\n' "$found" | sed 's|variables/||; s|\.backend\.hcl$||; s|^|  |' >&2
      echo "Pass one: BACKEND=<id>. It defaults to the vars_id (VARS=$V_VARS_ID here)," >&2
      echo "which itself defaults to the stack name." >&2
      exit 1
    fi
  fi
}

# tf:vars:assert -- refuse to proceed if VARS doesn't resolve to real tfvars
# files, with a message that says why.
tf_vars_assert() {
  fail() {
    echo "$1" >&2
    echo "VARS is <vars_id>:<glob>[,<glob>...] and its globs are stack-relative:" >&2
    echo "this runs with dir: $V_STACK_DIR, so 'variables/dev*.tfvars' means" >&2
    echo "$V_STACK_DIR/variables/dev*.tfvars, not a path from the repo root." >&2
    exit 1
  }

  local vars="$V__VARS"
  local resolved="$V_VARS_RESOLVED"
  if [ -z "$resolved" ]; then
    echo "VARS=$vars is not a name in VARS_MAP. Known names:" >&2
    printf '%s\n' "$V_VARS_MAP" | awk -F: '{sub(/^[ \t]+/, "")} NF {print "  " $1}' >&2
    echo "Or spell the combination out: VARS=$vars:<glob>[,<glob>...]" >&2
    exit 1
  fi
  case "$V_VARS_ID" in
    '') fail "VARS=$vars has an empty vars_id." ;;
    *[!A-Za-z0-9._-]*) fail "vars_id '$V_VARS_ID' must be [A-Za-z0-9._-]; it names the plan file." ;;
  esac
  local globs
  globs=$(printf '%s' "$resolved" | cut -d: -f2-)
  [ -n "$globs" ] || fail "VARS=$vars selects no files."
  IFS=','
  for g in $globs; do
    set -- $g
    [ -e "$1" ] || fail "VARS glob '$g' matched no files in $V_STACK_DIR."
  done
}

# tf:toolchain:show -- report active TF binary, its version, which registry
# the lock file names, and what's stashed.
tf_toolchain_show() {
  echo "TF          = $V_TF"
  echo "TF_DATA_DIR = ${TF_DATA_DIR:-unset}"

  if command -v "$V_TF" >/dev/null 2>&1; then
    echo "version     = $("$V_TF" version 2>&1 | head -1)"
  else
    echo "version     = NOT INSTALLED"
  fi

  if [ "$V_TF" = "terraform" ]; then
    echo "tfenv req   = $V_TF_VERSION"
    echo "tfenv have  = $(tfenv list 2>&1 | tr '\n' ' ')"
  fi

  if [ -f .terraform.lock.hcl ]; then
    echo "lock        = $(grep -o 'registry\.[a-z.]*' .terraform.lock.hcl | head -1)"
  else
    echo "lock        = (absent)"
  fi

  echo "stashed     = $(ls "$V_LOCK_STASH" 2>/dev/null | tr '\n' ' ')"
}

# tf:toolchain:install -- tfenv install/use TF_VERSION. No-op for tofu, which
# tfenv doesn't manage.
tf_toolchain_install() {
  if [ "$V_TF" != "terraform" ]; then
    echo "TF=$V_TF: nothing to install, tfenv only manages terraform"
    exit 0
  fi

  command -v tfenv >/dev/null 2>&1 || {
    echo "tfenv not found. brew install tfenv" >&2
    exit 1
  }

  tfenv install "$V_TF_VERSION"
  tfenv use "$V_TF_VERSION"
  terraform version | head -1
}

# tf:toolchain:use:ask -- switch the working dir to TF, stashing the other
# toolchain's lock file so switching back doesn't lose it.
tf_toolchain_use_ask() {
  mkdir -p "$V_LOCK_STASH"

  if [ -f .terraform.lock.hcl ]; then
    local current
    if grep -q 'registry.opentofu.org' .terraform.lock.hcl; then
      current=tofu
    else
      current=terraform
    fi
    if [ "$current" != "$V_TF" ]; then
      cp .terraform.lock.hcl "$V_LOCK_STASH/${current}.lock.hcl"
      echo "stashed ${current} lock"
    fi
  fi

  if [ -f "$V_LOCK_STASH/$V_TF.lock.hcl" ]; then
    cp "$V_LOCK_STASH/$V_TF.lock.hcl" .terraform.lock.hcl
    echo "restored $V_TF lock"
  else
    rm -f .terraform.lock.hcl
    echo "no stashed $V_TF lock; init will create one"
  fi
}

# ---- ADAPTER ----
# Everything below this marker is the per-backend adapter -- the only section
# meant to be edited when adding a backend flavor. gcs and local are
# implemented; every other flavor documents the commands to run by hand (see
# references/backends.md for paste-in s3/azurerm bodies).

# tf:setup -- create (idempotent) and version the storage that BACKEND's
# backend.hcl names, before the first tf:init. Dispatches on V_TF_BACKEND.
tf_setup() {
  local state_bucket="$1"
  local state_location="$2"

  local backend="$V_STACK_DIR/$V_BACKEND_FILE"

  case "$V_TF_BACKEND" in
    gcs)
      command -v gcloud >/dev/null 2>&1 || {
        echo "gcloud not found. Install the Google Cloud CLI and run 'gcloud auth login'." >&2
        exit 1
      }

      local bucket prefix
      if [ -f "$backend" ]; then
        bucket=$(sed -n 's/^ *bucket *= *"\(.*\)"/\1/p' "$backend")
        prefix=$(sed -n 's/^ *prefix *= *"\(.*\)"/\1/p' "$backend")
      else
        bucket="$state_bucket"
        prefix="$V_STACK"
      fi
      [ -n "$bucket" ] || {
        echo "$backend names no bucket." >&2
        exit 1
      }

      if gcloud storage buckets describe "gs://$bucket" >/dev/null 2>&1; then
        echo "gs://$bucket already exists"
      else
        echo "creating gs://$bucket in $V_STATE_PROJECT"
        gcloud services enable storage.googleapis.com --project="$V_STATE_PROJECT"
        gcloud storage buckets create "gs://$bucket" \
          --project="$V_STATE_PROJECT" \
          --location="$state_location" \
          --uniform-bucket-level-access \
          --public-access-prevention
      fi

      gcloud storage buckets update "gs://$bucket" --versioning

      echo "state bucket ready: gs://$bucket/$prefix (BACKEND=$V_BACKEND_ID)"
      ;;
    local)
      if [ ! -f "$backend" ]; then
        echo "$backend not found; nothing to set up." >&2
        exit 1
      fi
      local path
      path=$(sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$backend")
      [ -n "$path" ] || {
        echo "$backend names no path." >&2
        exit 1
      }
      mkdir -p "$(dirname "$path")"
      echo "state dir ready: $(dirname "$path") (BACKEND=$V_BACKEND_ID)"
      ;;
    *)
      echo "tf_setup has no automation for BACKEND=$V_TF_BACKEND -- provision it by hand." >&2
      if [ -f "$backend" ]; then
        echo "keys in $backend:" >&2
        grep -o '^[[:space:]]*[a-z_][a-z_]*[[:space:]]*=' "$backend" 2>/dev/null | sed 's/[[:space:]]*=$//; s/^[[:space:]]*/  /' >&2
      else
        echo "no backend.hcl at $backend" >&2
      fi
      echo "see references/backends.md for the exact commands for BACKEND=$V_TF_BACKEND." >&2
      exit 1
      ;;
  esac
}

# tf:init:init -- init unconditionally, retrying with -reconfigure if the
# backend cache in TF_DATA_DIR is stale.
tf_init_init() {
  local init
  if [ -f "$V_BACKEND_FILE" ]; then
    init="$V_TF init -input=false -backend-config=$V_BACKEND_FILE"
  else
    init="$V_TF init -input=false"
  fi
  $init "$@" || {
    echo "init failed; retrying with -reconfigure (stale backend cache in $V_DATA_DIR?)" >&2
    $init -reconfigure "$@"
  }
}

# tf:validate:all -- tf:validate:local across every stack under stacks/.
tf_validate_all() {
  local s
  for s in $V_STACKS; do
    echo "== $s"
    env -u TF_DATA_DIR task tf:validate:local STACK="$s"
  done
}

# tf:vars -- report which tfvars this stack would load and where its plan
# would be written.
tf_vars() {
  printf '%-10s %s\n' STACK "$V_STACK"
  printf '%-10s %s\n' VARS "$V__VARS"
  if [ -z "$V_VARS" ] && [ -n "$V_USE_VARS" ]; then
    printf '%-10s %s\n' SOURCE "$V_ENV_FILE"
  fi
  if [ "$V__VARS" != "$V_VARS_RESOLVED" ]; then
    printf '%-10s %s\n' RESOLVED "$V_VARS_RESOLVED"
  fi
  printf '%-10s %s\n' VARS_ID "$V_VARS_ID"
  printf '%-10s %s\n' BACKEND "$V_BACKEND_ID"
  printf '%-10s %s\n' PLAN "$V_PLAN_FILE"
  printf '%-10s\n' FILES
  local f
  for f in $(VAR_FILES "$V_STACK_DIR" "$V_VARS_RESOLVED"); do
    echo "  ${f#-var-file=}"
  done
}

# tf:backend -- report which backend resolves for this stack, why (CLI,
# remembered, derived, or default), and where its state lives.
tf_backend() {
  printf '%-10s %s\n' STACK "$V_STACK"
  printf '%-10s %s\n' BACKEND "$V__BACKEND"
  if [ -n "$V_BACKEND" ]; then
    printf '%-10s %s\n' SOURCE 'command line'
  elif [ -n "$V_USE_BACKEND" ]; then
    printf '%-10s %s\n' SOURCE "$V_ENV_FILE"
  elif [ "$V_VARS_ID" != "$V_STACK" ]; then
    printf '%-10s %s\n' SOURCE "VARS_ID=$V_VARS_ID"
  else
    printf '%-10s %s\n' SOURCE 'BACKEND_DEFAULT (stack name)'
  fi
  if [ "$V__BACKEND" != "$V_BACKEND_RESOLVED" ]; then
    printf '%-10s %s\n' RESOLVED "$V_BACKEND_RESOLVED"
  fi
  printf '%-10s %s\n' BACKEND_ID "$V_BACKEND_ID"
  printf '%-10s %s\n' FILE "$V_STACK_DIR/$V_BACKEND_FILE"
  printf '%-10s %s\n' STATE "$(BACKEND_STATE "$V_STACK_DIR/$V_BACKEND_FILE" "$V_STACK_DIR")"
  if [ -f "$V_STACK_DIR/$V_BACKEND_FILE" ]; then
    printf '%-10s %s\n' WRITABLE yes
  else
    printf '%-10s %s\n' WRITABLE no
  fi
  printf '%-10s %s\n' DATA_DIR "$V_STACK_DIR/$V_DATA_DIR"
}

# tf:use:clear -- drop the VARS/BACKEND lines from STACK.env, removing the
# file entirely if that's all it had.
tf_use_clear() {
  local file="$V_ENV_FILE"
  if [ ! -f "$file" ]; then
    echo "no $file; nothing to forget"
    exit 0
  fi
  mkdir -p "$V_TMP"
  local new="$V_TMP/$(basename "$file").new"
  grep -v '^[[:space:]]*\(VARS\|BACKEND\)[[:space:]]*=' "$file" > "$new" || true
  if [ -s "$new" ]; then
    mv "$new" "$file"
    echo "removed VARS and BACKEND from $file"
  else
    rm -f "$new" "$file"
    echo "removed $file"
  fi
}


cmd="${1:-}"
[ -n "$cmd" ] && shift || true

case "$cmd" in
  ''|-h|--help|help)
    echo "usage: $0 <command> [args...]" >&2
    echo "commands:" >&2
    declare -F | awk '{print $3}' | sed 's/^/  /' >&2
    exit 1
    ;;
esac

if ! declare -F "$cmd" >/dev/null; then
  echo "$0: unknown command '$cmd'" >&2
  echo "commands:" >&2
  declare -F | awk '{print $3}' | sed 's/^/  /' >&2
  exit 1
fi

"$cmd" "$@"
