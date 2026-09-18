#!/usr/bin/env bash
#
# tf-stack.sh 
# -----------
#
# a simple toolkit for terraform & opentofu

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

# The live lines of an HCL file, one per input line, left-trimmed. Live means
# outside a /* */ block comment, multi-line ones included and mid-line ones cut
# out, and not on a line that starts with # or //. A trailing # or // comment
# after code is left where it is: every reader below matches from the start of
# the line and stops before it. Tabs count as indentation. Those readers work
# on this output rather than on raw lines, so comment handling is written once.
# The file may be `-`, which awk reads as stdin -- that is what lets a block
# extracted by _hcl_block be fed straight back in.
_hcl_lines() {
  local file="$1"

  awk '
    {
      line = $0
      while (1) {
        if (inblock) {
          i = index(line, "*/")
          if (i == 0) next
          line = substr(line, i + 2)
          inblock = 0
        }
        i = index(line, "/*")
        if (i == 0) break
        rest = substr(line, i + 2)
        j = index(rest, "*/")
        if (j == 0) { line = substr(line, 1, i - 1); inblock = 1; break }
        line = substr(line, 1, i - 1) substr(rest, j + 2)
      }
      sub(/^[ \t]+/, "", line)
      if (line ~ /^(#|\/\/)/) next
      print line
    }' "$file"
}

# The string value of `<key> = "..."` in an HCL file: the first live one, value
# only. Enough HCL for a backend config; not an HCL parser. Prints nothing when
# the key is absent. The first match wins but the whole input is still read:
# quitting early would SIGPIPE the _hcl_lines feeding it, which `pipefail`
# would then report as a failure of this function.
_hcl_string() {
  local key="$1" file="$2"

  _hcl_lines "$file" | awk -v key="$key" '
    !found {
      if (match($0, "^" key "[ \t]*=[ \t]*\"[^\"]*\"")) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^[^"]*"/, "", s)
        sub(/"$/, "", s)
        print s
        found = 1
      }
    }'
}

# The first `<kind> "<label>" {` block of an HCL file, header line through its
# closing brace, printed as live lines. Depth is counted from the braces left
# after quoted strings are deleted, so a brace inside a value does not open a
# block and `backend "gcs" {}` is a complete one. Prints nothing when the file
# has no such block. Takes `-` for stdin, like _hcl_lines.
_hcl_block() {
  local kind="$1" file="$2"

  _hcl_lines "$file" | awk -v kind="$kind" '
    done { next }
    {
      t = $0
      gsub(/"[^"]*"/, "", t)
      if (!started) {
        if ($0 !~ "^" kind "[ \t]*\"[^\"]*\"[ \t]*[{]") next
        started = 1
      }
      print
      depth += gsub(/[{]/, "&", t) - gsub(/[}]/, "&", t)
      if (depth <= 0) done = 1
    }'
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
  sed -n 's/^[ \t]*VARS[ \t]*=[ \t]*//p' "$ENV_FILE" | tail -n 1 | sed 's/[ \t]*$//'
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
  sed -n 's/^[ \t]*BACKEND[ \t]*=[ \t]*//p' "$ENV_FILE" | tail -n 1 | sed 's/[ \t]*$//'
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

# Which of the two backend layouts a BACKEND path is, so callers stop asking
# `test -f`: `config` is a .backend.hcl/.tfbackend handed to init as
# -backend-config, `inline` is a .tf whose `backend "<type>" {}` block carries
# the settings itself, `none` is neither (missing file, or a .tf whose block is
# the empty partial-config form) and means plan-only. A block with no
# `key = value` line in it is deliberately `none`: the bare `backend "gcs" {}`
# every other stack here keeps in backend.tf still needs its .backend.hcl.
# The path is taken as the caller has it -- stack-relative under `dir:` tasks,
# $V_STACK_DIR/$V_BACKEND_FILE from the repo root.
BACKEND_KIND() {
  local file="$1"

  if [ -z "$file" ] || [ ! -f "$file" ]; then
    printf 'none\n'
    return 0
  fi
  case "$file" in
    *.hcl|*.tfbackend)
      printf 'config\n'
      return 0
      ;;
    *.tf) ;;
    *)
      printf 'none\n'
      return 0
      ;;
  esac

  local settings
  settings=$(_hcl_block backend "$file" | awk '
    NR == 1 { sub(/^backend[ \t]*"[^"]*"[ \t]*[{][ \t]*/, "") }
    $0 ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*=/ { found = 1 }
    END { if (found) print "yes" }')
  if [ "$settings" = yes ]; then
    printf 'inline\n'
  else
    printf 'none\n'
  fi
}

# The backend type a BACKEND path selects -- the label in `backend "<type>" {`
# for an inline block. A .backend.hcl names no type (the .tf's empty block does
# that), and every one in this repo configures gcs, so `config` reports gcs
# rather than nothing. Empty for `none`.
BACKEND_TYPE() {
  local file="$1"

  case "$(BACKEND_KIND "$file")" in
    config) printf 'gcs\n' ;;
    inline) _hcl_block backend "$file" |
              sed -n '1s/^backend[[:space:]]*"\([^"]*\)".*/\1/p' ;;
  esac
}

# One backend setting (bucket, prefix, ...) whichever layout holds it: read
# from the file itself for `config`, from inside the block for `inline`. This
# is what lets tf_setup, tf_stacks_list and tf_backend ask for a bucket without
# knowing which layout the stack uses. Empty for `none`, and empty for a key
# the backend does not set.
BACKEND_VALUE() {
  local key="$1" file="$2"

  case "$(BACKEND_KIND "$file")" in
    config) _hcl_string "$key" "$file" ;;
    inline) _hcl_block backend "$file" | _hcl_string "$key" - ;;
  esac
}

# The STATE column tf_stacks_list and tf_backend print for a BACKEND path: the
# gs:// URL for a gcs backend, the type alone for anything else (this repo
# creates buckets, so it has nothing to say about an s3 or azurerm location),
# and the plan-only wording when there is no backend config at all.
BACKEND_STATE() {
  local file="$1"

  local type
  type=$(BACKEND_TYPE "$file")
  case "$type" in
    '')  printf 'local, plan-only\n' ;;
    gcs) printf 'gs://%s/%s\n' "$(BACKEND_VALUE bucket "$file")" "$(BACKEND_VALUE prefix "$file")" ;;
    *)   printf '%s backend\n' "$type" ;;
  esac
}

# The stack's own inline backend, if it has one: the first *.tf in the stack
# directory (shell glob order, which is `ls` order) whose backend block carries
# settings, named stack-relative so it can be used as a BACKEND path directly.
# Prints nothing when the stack keeps its backend in a .backend.hcl or has none.
BACKEND_INLINE_FILE() {
  local dir="$1"

  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  local f
  for f in "$dir"/*.tf; do
    [ -f "$f" ] || continue
    if [ "$(BACKEND_KIND "$f")" = inline ]; then
      basename "$f"
      return 0
    fi
  done
  return 0
}

# The BACKEND a run falls back to when neither the command line nor <stack>.env
# named one. A variables/<vars_id>.backend.hcl wins, so a multi-env stack keeps
# following its vars_id; failing that an inline backend in a .tf is used, which
# is what makes a stack in the ordinary Terraform layout writable without a
# .backend.hcl; failing both it still resolves to the .backend.hcl path, so the
# asserts' messages keep naming the file they expected to find.
BACKEND_DEFAULT() {
  local dir="$1" vars_id="$2"

  local hcl="variables/$vars_id.backend.hcl"
  if [ ! -f "$dir/$hcl" ]; then
    local inline
    inline=$(BACKEND_INLINE_FILE "$dir")
    if [ -n "$inline" ]; then
      printf '%s:%s' "$vars_id" "$inline"
      return 0
    fi
  fi
  printf '%s:%s' "$vars_id" "$hcl"
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
    grep -v '^[ \t]*\(VARS\|BACKEND\)[ \t]*=' "$file" > "$new" || true
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

# tf:stacks:list -- one row per stack, one sub-row per backend.hcl it has. A
# stack with no backend.hcl gets a single row from its inline backend instead,
# under the stack's own name as the backend id -- that is the id BACKEND_DEFAULT
# gives it, since there is no map entry to name it otherwise. Only a stack with
# neither is the plan-only row.
tf_stacks_list() {
  printf '%-14s %-9s %-9s %s\n' NAME WRITABLE BACKEND STATE
  local s first backend id bucket prefix inline
  for s in $V_STACKS; do
    first=1
    for backend in "stacks/$s"/variables/*.backend.hcl; do
      [ -f "$backend" ] || continue
      id=$(basename "$backend" .backend.hcl)
      bucket=$(_hcl_string bucket "$backend")
      prefix=$(_hcl_string prefix "$backend")
      if [ "$first" = 1 ]; then
        printf '%-14s %-9s %-9s %s\n' "$s" yes "$id" "gs://$bucket/$prefix"
        first=0
      else
        printf '%-14s %-9s %-9s %s\n' '' '' "$id" "gs://$bucket/$prefix"
      fi
    done
    if [ "$first" = 1 ]; then
      inline=$(BACKEND_INLINE_FILE "stacks/$s")
      if [ -n "$inline" ]; then
        printf '%-14s %-9s %-9s %s\n' "$s" yes "$s" "$(BACKEND_STATE "stacks/$s/$inline")"
      else
        printf '%-14s %-9s %-9s %s\n' "$s" no '-' "local, plan-only"
      fi
    fi
  done
}

# tf:stack:assert -- refuse a writing task when the stack has no backend config
# of either form, since its state is then local and empty. Distinct from
# tf:backend:assert, which polices the BACKEND value itself: this one is about
# what the stack is, and runs from the repo root rather than from STACK_DIR.
tf_stack_assert() {
  [ "$(BACKEND_KIND "$V_STACK_DIR/$V_BACKEND_FILE")" = none ] || return 0

  echo "stack '$V_STACK' has no backend config (BACKEND=$V__BACKEND): no" >&2
  echo "$V_BACKEND_FILE, and no .tf holding the backend inline, as in" >&2
  echo "terraform { backend \"gcs\" { bucket = ... } }. So this run is plan-only." >&2
  echo "Its state is local and empty: a plan shows every resource as new even when" >&2
  echo "the resource already exists in GCP. Nothing that writes runs against it." >&2
  echo "See $V_STACK_DIR/README.md." >&2
  exit 1
}

# tf:backend:assert -- refuse to proceed if BACKEND doesn't resolve to a real
# backend config, with a message that says why.
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
  if [ -f "$V_BACKEND_FILE" ]; then
    if [ "$(BACKEND_KIND "$V_BACKEND_FILE")" = none ]; then
      echo "BACKEND=$V_BACKEND_ID selects $V_BACKEND_FILE, which exists but holds no" >&2
      echo "backend block with settings in it. A BACKEND path is either a .backend.hcl" >&2
      echo "(or .tfbackend) passed to init as -backend-config, or a .tf whose" >&2
      echo "terraform { backend \"gcs\" { ... } } block sets bucket and prefix itself." >&2
      echo "An empty backend \"gcs\" {} is the partial-config form: its settings belong" >&2
      echo "in a .backend.hcl, so name that file instead." >&2
      exit 1
    fi
  else
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
    local inline
    inline=$(BACKEND_INLINE_FILE "$PWD")
    if [ -n "$inline" ]; then
      echo "BACKEND=$V_BACKEND_ID selects $V_BACKEND_FILE, which does not exist -- but" >&2
      echo "$inline holds this stack's backend inline. Drop BACKEND to use it, or name it:" >&2
      echo "  BACKEND=$V_BACKEND_ID:$inline" >&2
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

# tf:setup -- create (idempotent) and version the GCS bucket BACKEND names,
# before the first tf:init. The bucket is read from whichever backend layout
# the stack uses; a stack with no backend config at all falls back to the
# global STATE_BUCKET under a prefix of its own, which is what makes tf:setup
# the first step of adopting a plan-only stack.
tf_setup() {
  local state_bucket="$1"
  local state_location="$2"

  command -v gcloud >/dev/null 2>&1 || {
    echo "gcloud not found. Install the Google Cloud CLI and run 'gcloud auth login'." >&2
    exit 1
  }

  local backend="$V_STACK_DIR/$V_BACKEND_FILE"
  local kind type bucket prefix
  kind=$(BACKEND_KIND "$backend")
  if [ "$kind" = none ]; then
    bucket="$state_bucket"
    prefix="$V_STACK"
  else
    type=$(BACKEND_TYPE "$backend")
    if [ "$type" != gcs ]; then
      echo "tf:setup manages GCS state buckets; $backend declares a $type backend." >&2
      exit 1
    fi
    bucket=$(BACKEND_VALUE bucket "$backend")
    prefix=$(BACKEND_VALUE prefix "$backend")
  fi
  [ -n "$bucket" ] || {
    echo "$backend names no bucket." >&2
    exit 1
  }

  # One describe answers both questions: does the bucket exist, and is it
  # versioned. A run against a bucket that is already both is then read-only,
  # so it leaves no audit entry and needs no update permission.
  local versioning
  if versioning=$(gcloud storage buckets describe "gs://$bucket" --format='value(versioning_enabled)' 2>/dev/null); then
    echo "gs://$bucket already exists"
  else
    versioning=
    echo "creating gs://$bucket in $V_BOOTSTRAP_PROJECT"
    gcloud services enable storage.googleapis.com --project="$V_BOOTSTRAP_PROJECT"
    gcloud storage buckets create "gs://$bucket" \
      --project="$V_BOOTSTRAP_PROJECT" \
      --location="$state_location" \
      --uniform-bucket-level-access \
      --public-access-prevention
  fi

  # State is the only copy of what this org looks like; keep old generations.
  # buckets create has no --versioning flag, so a new bucket takes this path too.
  if [ "$versioning" = True ]; then
    echo "gs://$bucket versioning already on"
  else
    gcloud storage buckets update "gs://$bucket" --versioning
  fi

  echo "state bucket ready: gs://$bucket/$prefix (BACKEND=$V_BACKEND_ID)"
}

# tf:init:init -- init unconditionally, retrying with -reconfigure if the
# backend cache in TF_DATA_DIR is stale. Only a `config` backend takes
# -backend-config; an inline one is already in the configuration tofu reads,
# and passing the .tf file as a config would be a parse error.
tf_init_init() {
  local init
  if [ "$(BACKEND_KIND "$V_BACKEND_FILE")" = config ]; then
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
  local kind
  kind=$(BACKEND_KIND "$V_STACK_DIR/$V_BACKEND_FILE")
  case "$kind" in
    config) printf '%-10s %s\n' FORMAT 'backend config, passed as -backend-config' ;;
    inline) printf '%-10s %s\n' FORMAT 'inline backend block' ;;
    *)      printf '%-10s %s\n' FORMAT 'none' ;;
  esac
  printf '%-10s %s\n' STATE "$(BACKEND_STATE "$V_STACK_DIR/$V_BACKEND_FILE")"
  if [ "$kind" = none ]; then
    printf '%-10s %s\n' WRITABLE no
  else
    printf '%-10s %s\n' WRITABLE yes
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
  grep -v '^[ \t]*\(VARS\|BACKEND\)[ \t]*=' "$file" > "$new" || true
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
