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
# the line and stops before it. Comment markers inside a quoted string are
# text, so "stacks/*/x" opens no comment. The body of a heredoc (<<EOT or
# <<-EOT through the line that is only EOT) comes out as blank lines, so prose
# in a description can neither set an attribute nor unbalance a brace count.
# Tabs count as indentation. Those readers work on this output rather than on
# raw lines, so this is written once. The file may be `-`, which awk reads as
# stdin -- that is what lets a block extracted by _hcl_block be fed straight
# back in.
_hcl_lines() {
  local file="$1"

  awk '
    hd != "" {
      t = $0
      sub(/^[ \t]+/, "", t)
      sub(/[ \t]+$/, "", t)
      if (t == hd) hd = ""
      print ""
      next
    }
    {
      line = $0
      if (inblock && index(line, "*/") == 0) next
      out = ""; code = ""; instr = 0; n = length(line); i = 1; tail = 0
      while (i <= n) {
        if (inblock) {
          j = index(substr(line, i), "*/")
          if (j == 0) break
          i += j + 1
          inblock = 0
          continue
        }
        c = substr(line, i, 1)
        if (instr) {
          if (c == "\\") { out = out substr(line, i, 2); i += 2; continue }
          if (c == "\"") instr = 0
          out = out c
          i++
          continue
        }
        two = substr(line, i, 2)
        if (two == "/*") { inblock = 1; i += 2; continue }
        if (c == "#" || two == "//") { code = out; out = out substr(line, i); tail = 1; break }
        if (c == "\"") instr = 1
        out = out c
        i++
      }
      if (!tail) code = out
      if (!instr && match(code, /<<-?[A-Za-z_][A-Za-z0-9_]*[ \t]*$/)) {
        hd = substr(code, RSTART, RLENGTH)
        sub(/^<<-?/, "", hd)
        sub(/[ \t]+$/, "", hd)
      }
      sub(/^[ \t]+/, "", out)
      if (out ~ /^(#|\/\/)/) next
      print out
    }' "$file"
}

# The string value of `<key> = "..."` in an HCL file: the first live one, value
# only. Enough HCL for a backend config; not an HCL parser. Prints nothing when
# the key is absent. It matches at any block depth, so a nested block with a
# clashing key (a `validation {}` inside a `variable`, say) can answer for the
# outer one: a known limit, fine for the flat blocks this is pointed at. The
# first match wins but the whole input is still read:
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

# Every `<kind> "<label>" {` block of an HCL file, not only the first: each one
# from its header line through its closing brace, as live lines, one after the
# other. A consumer starts a new record at each header line. Depth is counted
# over every line, so a block of the same kind nested inside another block is
# not mistaken for a top-level one, and braces are counted the way _hcl_block
# counts them: after quoted strings are deleted (heredoc bodies are already
# blank). Takes `-` for stdin, like _hcl_lines.
_hcl_blocks() {
  local kind="$1" file="$2"

  _hcl_lines "$file" | awk -v kind="$kind" '
    {
      t = $0
      gsub(/"[^"]*"/, "", t)
      opens = gsub(/[{]/, "&", t)
      closes = gsub(/[}]/, "&", t)
      if (!inblock && depth == 0 && $0 ~ "^" kind "[ \t]*\"[^\"]*\"[ \t]*[{]") inblock = 1
      if (inblock) print
      depth += opens - closes
      if (depth <= 0) { depth = 0; inblock = 0 }
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
  sed -n 's/^[[:space:]]*VARS[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" | tail -n 1 | sed 's/[[:space:]]*$//'
}

# The -var-file=... flags for a resolved VARS. Runs from STACK_DIR because the
# globs are stack-relative; a glob matching nothing is silently dropped here
# (vars:assert-vars is what catches a typo, not this). The optional third
# argument is the stack-relative secret tfvars, appended last, so it wins, when
# the file exists. It is named rather than globbed because a VARS_MAP entry
# need not cover it: prod's glob list is variables/prod.tfvars and would miss it.
# For the same reason a glob never loads one: dev's variables/dev*.tfvars would
# match dev.secret.tfvars in the middle of the list, and a broader glob would
# load another vars_id's secrets.
VAR_FILES() {
  local STACK_DIR="$1"
  local VARS_RESOLVED="$2"
  local SECRET_TFVARS="${3:-}"

  cd "$STACK_DIR" 2>/dev/null || exit 0
  local globs
  globs=$(printf '%s' "$VARS_RESOLVED" | cut -d: -f2-)
  IFS=','
  for f in $globs; do
    case "$f" in
      *.secret.tfvars|"$SECRET_TFVARS") continue ;;
    esac
    if [ -e "$f" ]; then
      printf '%s ' "-var-file=$f"
    fi
  done
  if [ -n "$SECRET_TFVARS" ] && [ -f "$SECRET_TFVARS" ]; then
    printf '%s ' "-var-file=$SECRET_TFVARS"
  fi
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
    # that matches nothing exits non-zero, disqualifying the whole id. A
    # *.secret.tfvars entry is skipped, as tf_vars_assert skips it.
    (
      cd "$STACK_DIR" 2>/dev/null || exit 1
      IFS=','
      for g in $globs; do
        case "$g" in *.secret.tfvars) continue ;; esac
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

# tf:stacks:list -- one row per stack, one sub-row per backend.hcl it has. A
# stack with no backend.hcl gets a single row from its inline backend instead,
# under the stack's own name as the backend id -- that is the id BACKEND_DEFAULT
# gives it, since there is no map entry to name it otherwise. Only a stack with
# neither is the plan-only row.
tf_stacks_list() {
  printf '%-14s %-9s %-9s %s\n' NAME WRITABLE BACKEND STATE
  local root="${V_STACKS_DIR:-stacks}"
  local s first backend id bucket prefix inline
  for s in $V_STACKS; do
    first=1
    for backend in "$root/$s"/variables/*.backend.hcl; do
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
      inline=$(BACKEND_INLINE_FILE "$root/$s")
      if [ -n "$inline" ]; then
        printf '%-14s %-9s %-9s %s\n' "$s" yes "$s" "$(BACKEND_STATE "$root/$s/$inline")"
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
# files, with a message that says why. A *.secret.tfvars entry is not checked:
# VAR_FILES never loads one through VARS, and tf:secrets:assert owns the
# current one, which a clean clone does not have until tf:secrets:pull:ask
# writes it -- requiring it here would block the pull that creates it.
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
    case "$g" in
      *.secret.tfvars)
        if [ "$g" != "$V_SECRET_TFVARS" ]; then
          echo "note: VARS entry '$g' is never loaded. Secret values come from $V_SECRET_TFVARS," >&2
          echo "      written by task tf:secrets:pull:ask; see Secrets in docs/tf-stack.md." >&2
        fi
        continue ;;
    esac
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
    init="$V_TF init -input=false -backend-config=$V_BACKEND_FILE $V_NO_COLOR"
  else
    init="$V_TF init -input=false $V_NO_COLOR"
  fi
  $init "$@" || {
    echo "init failed; retrying with -reconfigure (stale backend cache in $V_DATA_DIR?)" >&2
    $init -reconfigure "$@"
  }
}

# tf:validate:all -- tf:validate:local across every stack under STACKS_DIR.
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
  if [ -f "$V_STACK_DIR/$V_SECRETS_FILE" ]; then
    printf '%-10s %s (present)\n' SECRETS "$V_SECRETS_FILE"
  else
    printf '%-10s %s (absent)\n' SECRETS "$V_SECRETS_FILE"
  fi
  printf '%-10s\n' FILES
  local f
  for f in $(VAR_FILES "$V_STACK_DIR" "$V_VARS_RESOLVED" "$V_SECRET_TFVARS"); do
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
  grep -v '^[[:space:]]*\(VARS\|BACKEND\)[[:space:]]*=' "$file" > "$new" || true
  if [ -s "$new" ]; then
    mv "$new" "$file"
    echo "removed VARS and BACKEND from $file"
  else
    rm -f "$new" "$file"
    echo "removed $file"
  fi
}

# tf:secrets:* -- Secret Manager secrets for a stack, one secret per variable.
#
# A variable with `sensitive = true` or `ephemeral = true` IS a secret; nothing
# else declares one. The optional variables/<vars_id>.secrets.hcl only says where
# a secret lands (`file`) or which Secret Manager id backs it (`id`) and is
# written by hand, never by a task. A secret is `inline` (its value becomes
# `<var> = "..."` in the stack's gitignored secret tfvars) or `file` (its payload
# is written to a path and the variable's value is that path). SECRETS_DISCOVER
# computes the rows offline; every task below consumes them. Values only ever
# travel through files and stdin, never argv and never echo, and every task that
# handles one runs under umask 077 with its scratch files in a private dir that
# is removed however the script exits.

TAB=$'\t'

# Secret Manager caps a payload at 64 KiB.
SECRETS_MAX_BYTES=65536

# The awk shared by the two block readers below. It splits _hcl_blocks output
# into records and calls the reader's own begin_block(label), attr(text) and
# end_block(); attr sees only the lines at depth 1 of the block, so a nested
# `validation {}` or a multi-line `default` cannot answer for the block itself.
# Needs -v kind=<block kind>.
_SECRETS_BLOCK_AWK='
  $0 ~ "^" kind "[ \t]*\"" {
    if (open) end_block()
    open = 1
    label = $0
    sub(/^[^"]*"/, "", label)
    sub(/".*/, "", label)
    begin_block(label)
    rest = $0
    sub(/^[^{]*[{][ \t]*/, "", rest)
    t = rest
    gsub(/"[^"]*"/, "", t)
    depth = 1 + gsub(/[{]/, "&", t) - gsub(/[}]/, "&", t)
    if (depth <= 0) sub(/[ \t]*[}][ \t]*$/, "", rest)
    if (rest != "") attr(rest)
    next
  }
  open {
    if (depth == 1) attr($0)
    t = $0
    gsub(/"[^"]*"/, "", t)
    depth += gsub(/[{]/, "&", t) - gsub(/[}]/, "&", t)
  }
  END { if (open) end_block() }'

# One `V<TAB>name<TAB>secret<TAB>default<TAB>type` row per `variable` block in
# the stack's *.tf files (not subdirectories: those are modules). secret is 1
# when the block sets `sensitive = true` or `ephemeral = true`, else 0. default
# is none (no default), null (`default = null`) or value (anything else). type
# is the text after `type =`, empty when the variable has none.
_secrets_variables() {
  local dir="$1" f
  for f in "$dir"/*.tf; do
    [ -f "$f" ] || continue
    _hcl_blocks variable "$f" | awk -v kind=variable '
      BEGIN { OFS = "\t" }
      function begin_block(l) { name = l; secret = 0; def = "none"; type = "" }
      function value(s, key,   v) {
        v = s
        sub("^" key "[ \t]*=[ \t]*", "", v)
        sub(/[ \t]*(#|\/\/).*$/, "", v)
        sub(/[ \t]+$/, "", v)
        return v
      }
      function attr(s) {
        if (s ~ /^(sensitive|ephemeral)[ \t]*=[ \t]*true([^A-Za-z0-9_]|$)/) secret = 1
        else if (s ~ /^default[ \t]*=/) def = (value(s, "default") == "null") ? "null" : "value"
        else if (s ~ /^type[ \t]*=/) type = value(s, "type")
      }
      function end_block() { print "V", name, secret, def, type }
      '"$_SECRETS_BLOCK_AWK"
  done
  return 0
}

# One `M<TAB>label<TAB>file<TAB>id<TAB>errors` row per `secret` block of a
# manifest. errors is empty unless the block holds an attribute other than a
# quoted `file` or `id`.
_secrets_manifest() {
  local file="$1"

  _hcl_blocks secret "$file" | awk -v kind=secret '
    BEGIN { OFS = "\t" }
    function err(m) { errs = errs sep m; sep = "; " }
    function begin_block(l) { name = l; file = ""; id = ""; errs = ""; sep = "" }
    function attr(s,   key, rest, v) {
      if (s == "" || s ~ /^[}]/) return
      if (!match(s, /^[A-Za-z_][A-Za-z0-9_-]*/)) { err("cannot read the line \"" s "\""); return }
      key = substr(s, 1, RLENGTH)
      rest = substr(s, RLENGTH + 1)
      if (rest !~ /^[ \t]*=/) { err("cannot read the line \"" s "\""); return }
      sub(/^[ \t]*=[ \t]*/, "", rest)
      if (key != "file" && key != "id") { err("unknown attribute \"" key "\" (only file and id are allowed)"); return }
      if (!match(rest, /^"[^"]*"/)) { err(key " must be a quoted string"); return }
      v = substr(rest, 2, RLENGTH - 2)
      if (v == "") { err(key " is empty"); return }
      if (key == "file") file = v
      else id = v
    }
    function end_block() { print "M", name, file, id, errs }
    '"$_SECRETS_BLOCK_AWK"
}

# SECRETS_DIR, checked and tidied: relative to the repo root, a directory below
# it. Prints the path without a leading ./, doubled or trailing slashes; prints
# what it must be and returns 1 for an empty value, an absolute path, or one
# with a .. segment (or one that is the root itself).
_secrets_dir_clean() {
  local d="$1" clean=""
  case "$d" in
    ''|/*) ;;
    *) case "/$d/" in
         */../*) ;;
         *) clean=$(_secrets_norm "$d") ;;
       esac ;;
  esac
  if [ -z "$clean" ] || [ "$clean" = . ]; then
    echo "SECRETS_DIR='$d' is not valid: it must be a directory below the repo root, written relative to it (default: secrets) -- not empty, not absolute, with no .. segment." >&2
    return 1
  fi
  printf '%s\n' "$clean"
}

# SECRETS_DISCOVER <stack_dir> <vars_id> <manifest> <prefix> <stack> <secrets_dir>
# One tab-separated row per secret, sorted by variable:
#
#   var  kind  required  id  dest  tfvar
#
# kind is inline or file. required is yes for a variable with no default and for
# every file-only secret, no for one with `default = null`; any other default is
# an error, since it would put a value in git. id is the manifest's `id`, else
# <prefix><stack>-<vars_id>-<var>. dest is `-` for inline, else the payload's
# path relative to the stack, which is also the value a pull writes for a file
# variable, since tofu runs in the stack dir. A bare manifest `file` lives in
# <secrets_dir>/<stack>/<vars_id>/ -- secrets_dir is relative to the repo root,
# so dest climbs out of the stack dir to reach it (stacks/app, SECRETS_DIR
# secrets: ../../secrets/app/dev/sa.json). A file starting ./ ../ or / is taken
# as written. tfvar is no only for a file-only secret, a manifest block whose
# label is not a variable, which gets no line in the secret tfvars. manifest is
# stack-relative and may be absent.
# Offline. Every problem is reported on stderr and the exit status is 1, with no
# rows on stdout.
SECRETS_DISCOVER() {
  local stack_dir="$1" vars_id="$2" manifest="$3" prefix="$4" stack="$5" secrets_dir="$6"
  local sdir

  sdir=$(_secrets_dir_clean "$secrets_dir") || return 1

  [ -d "$stack_dir" ] || {
    echo "secrets: no stack directory $stack_dir" >&2
    return 1
  }

  {
    _secrets_variables "$stack_dir"
    if [ -f "$stack_dir/$manifest" ]; then
      _secrets_manifest "$stack_dir/$manifest"
    fi
  } | awk -F'\t' -v mpath="$stack_dir/$manifest" -v stack_dir="$stack_dir" \
        -v vars_id="$vars_id" -v prefix="$prefix" -v stack="$stack" -v sdir="$sdir" '
    function fail(m) { errs++; print "secrets: " m > "/dev/stderr" }
    function add(var, kind, req, id, dest, tfvar) {
      if (id !~ /^[A-Za-z0-9_-]+$/ || length(id) > 255)
        fail("the Secret Manager id \"" id "\" for " var " is not valid (letters, digits, _ and - only, at most 255 characters). Set id = \"<valid id>\" for it in " mpath ".")
      if (dest != "-" && (dest in seen))
        fail(var " and " seen[dest] " both write " dest ". Give one of them another file.")
      seen[dest] = var
      rows[++nr] = var "\t" kind "\t" req "\t" id "\t" dest "\t" tfvar
    }
    $1 == "V" { nv++; vn[nv] = $2; vs[nv] = $3; vd[nv] = $4; vt[nv] = $5; vi[$2] = nv; next }
    $1 == "M" {
      nm++; ml[nm] = $2; mf[nm] = $3; mi[nm] = $4; me[nm] = $5
      if ($2 in mx) fail(mpath ": secret \"" $2 "\" is declared twice.")
      mx[$2] = nm
      next
    }
    END {
      # The way back up from the stack dir to the repo root, ../ per segment
      # (stacks/app gives ../../), so a path under SECRETS_DIR can be written
      # as tofu, which runs in the stack dir, resolves it. Lexical: macOS has no
      # realpath --relative-to.
      ups = ""
      nseg = split(stack_dir, seg, "/")
      if (stack_dir ~ /^\//) fail("the stack directory " stack_dir " must be relative to the repo root.")
      for (i = 1; i <= nseg; i++) {
        if (seg[i] == "" || seg[i] == ".") continue
        if (seg[i] == "..") fail("the stack directory " stack_dir " must be relative to the repo root, with no .. segment.")
        else ups = ups "../"
      }
      for (i = 1; i <= nv; i++) {
        if (!vs[i]) continue
        n = vn[i]
        if (vt[i] != "" && vt[i] != "string")
          fail("variable \"" n "\" is a secret (sensitive or ephemeral) but has type = " vt[i] ". A secret is a string: store JSON in a string variable and jsondecode(var." n ") in the configuration.")
        if (vd[i] == "value")
          fail("variable \"" n "\" is a secret (sensitive or ephemeral) but has a default value, which would put that value in git. Remove the default to make it required, or write default = null to make it optional.")
        f = ""; id = ""
        if (n in mx) { f = mf[mx[n]]; id = mi[mx[n]] }
        if (id == "") id = prefix stack "-" vars_id "-" n
        req = (vd[i] == "none") ? "yes" : "no"
        if (f == "") add(n, "inline", req, id, "-", "yes")
        else add(n, "file", req, id, (f ~ /^(\.\/|\.\.\/|\/)/) ? f : ups sdir "/" stack "/" vars_id "/" f, "yes")
      }
      for (j = 1; j <= nm; j++) {
        l = ml[j]
        if (me[j] != "") fail(mpath ": secret \"" l "\": " me[j] ".")
        if (l !~ /^[A-Za-z_][A-Za-z0-9_-]*$/) fail(mpath ": \"" l "\" is not a valid name.")
        if (l in vi) {
          if (!vs[vi[l]]) fail(mpath ": \"" l "\" is a variable but neither sensitive nor ephemeral. Set sensitive = true on variable \"" l "\" to make it a secret.")
        } else if (mf[j] == "") {
          fail(mpath ": \"" l "\" is not a variable in " stack_dir " and has no file. A secret that is not a variable is a file some other tool reads: add file = \"<path>\".")
        } else {
          id = mi[j]
          if (id == "") id = prefix stack "-" vars_id "-" l
          add(l, "file", "yes", id, (mf[j] ~ /^(\.\/|\.\.\/|\/)/) ? mf[j] : ups sdir "/" stack "/" vars_id "/" mf[j], "no")
        }
      }
      if (errs) exit 1
      for (r = 1; r <= nr; r++) print rows[r]
    }' | LC_ALL=C sort
}

# The rows for the current task's STACK and VARS, from the V_* environment.
_secrets_rows() {
  SECRETS_DISCOVER "$V_STACK_DIR" "$V_VARS_ID" "$V_SECRETS_FILE" "$V_SECRET_PREFIX" "$V_STACK" "$V_SECRETS_DIR"
}

# The gcloud check tf_setup makes.
_secrets_need_gcloud() {
  command -v gcloud >/dev/null 2>&1 || {
    echo "gcloud not found. Install the Google Cloud CLI and run 'gcloud auth login'." >&2
    exit 1
  }
}

# A private scratch dir under $V_TMP for payloads and staged files, removed when
# the script exits however it exits (an EXIT trap: bash runs it on INT, TERM and
# HUP too). _SECRETS_WORK names it. From here on the umask is 077, so every file
# and directory the task creates -- scratch, secret tfvars, file secrets and
# their parent dirs -- is owner-only from the moment it exists; _SECRETS_UMASK
# keeps the caller's for the files that are not secret (.gitignore, secrets.tf).
_secrets_work_init() {
  _SECRETS_UMASK=$(umask)
  umask 077
  mkdir -p "$V_TMP"
  _SECRETS_WORK=$(mktemp -d "$V_TMP/secrets.XXXXXX")
  trap 'rm -rf "$_SECRETS_WORK"' EXIT
}

# Whether a gcloud failure, whose stderr is in $1, means the secret or version
# does not exist, as against something worth stopping for (auth, permissions).
_secrets_not_found() {
  grep -qE 'NOT_FOUND|not found' "$1"
}

# The latest version number of a secret, in _SECRETS_VERSION. Returns 3 when the
# secret or any version of it is missing, 1 (stderr shown) on any other failure.
_secrets_latest() {
  local id="$1" err="$_SECRETS_WORK/gcloud.err" name
  if name=$(gcloud secrets versions describe latest --secret="$id" --project="$V_SECRETS_PROJECT" \
              --format='value(name)' 2>"$err" </dev/null); then
    _SECRETS_VERSION="${name##*/}"
    return 0
  fi
  _secrets_not_found "$err" && return 3
  cat "$err" >&2
  return 1
}

# Whether a secret exists: 0 yes, 3 no, 1 on any other failure.
_secrets_exists() {
  local id="$1" err="$_SECRETS_WORK/gcloud.err"
  if gcloud secrets describe "$id" --project="$V_SECRETS_PROJECT" --format='value(name)' \
       >/dev/null 2>"$err" </dev/null; then
    return 0
  fi
  _secrets_not_found "$err" && return 3
  cat "$err" >&2
  return 1
}

# Fetch a secret's latest payload, raw, into the file $2; its version lands in
# _SECRETS_VERSION. Same return codes as _secrets_latest. The version is read
# first and the payload fetched by number, so the two always belong together.
_secrets_fetch() {
  local id="$1" out="$2" err="$_SECRETS_WORK/gcloud.err" rc=0
  _secrets_latest "$id" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  if gcloud secrets versions access "$_SECRETS_VERSION" --secret="$id" --project="$V_SECRETS_PROJECT" \
       >"$out" 2>"$err" </dev/null; then
    return 0
  fi
  _secrets_not_found "$err" && return 3
  cat "$err" >&2
  return 1
}

# Add one line to .gitignore unless it is already there, as tf_use does for *.env.
# A missing .gitignore is created with the caller's umask: it is committed.
_secrets_gitignore_line() {
  local line="$1"
  [ -f .gitignore ] || ( umask "${_SECRETS_UMASK:-$(umask)}"; : > .gitignore )
  grep -qxF "$line" .gitignore && return 0
  # A file that does not end in a newline would swallow the line.
  [ -z "$(tail -c 1 .gitignore)" ] || echo >> .gitignore
  echo "$line" >> .gitignore
  echo ".gitignore: added $line"
}

# What pull and setup keep out of git: the secret tfvars, and the secrets dir.
# The dir is anchored to the repo root so it cannot match a module directory that
# happens to be called secrets/ somewhere else.
_secrets_gitignore() {
  local dir
  dir=$(_secrets_dir_clean "$V_SECRETS_DIR") || exit 1
  _secrets_gitignore_line '*.secret.tfvars'
  _secrets_gitignore_line "/$dir/"
}

# A path with . and .. segments and doubled slashes resolved, lexically. Used so
# the path git is asked about, and the .gitignore line suggested, read cleanly.
_secrets_norm() {
  printf '%s\n' "$1" | awk -F/ '
    {
      abs = ($0 ~ /^\//)
      n = 0
      for (i = 1; i <= NF; i++) {
        p = $i
        if (p == "" || p == ".") continue
        if (p == "..") {
          if (n > 0 && st[n] != "..") n--
          else if (!abs) st[++n] = ".."
          continue
        }
        st[++n] = p
      }
      out = abs ? "/" : ""
      for (i = 1; i <= n; i++) out = out (i > 1 ? "/" : "") st[i]
      if (out == "") out = "."
      print out
    }'
}

# Where a row's dest really is, from the repo root.
_secrets_dest_path() {
  case "$1" in
    /*) _secrets_norm "$1" ;;
    *)  _secrets_norm "$V_STACK_DIR/$1" ;;
  esac
}

# Prints a refusal and returns 1 unless git ignores the path. In-situ file
# destinations are the reason this exists: nothing else stops a pull from writing
# a credential somewhere a `git add .` would pick it up.
_secrets_check_ignored() {
  local path="$1" rc=0
  git check-ignore -q -- "$path" 2>/dev/null || rc=$?
  [ "$rc" != 0 ] || return 0
  echo "refusing to write $path: git does not ignore it. Add this line to .gitignore:" >&2
  case "$path" in
    /*|../*|..) echo "  $path   (it is outside this repository, so git cannot ignore it: choose another file)" >&2 ;;
    *)          echo "  /$path" >&2 ;;
  esac
  return 1
}

# Whether a row's secret is on this machine: an inline row has a `<var> =` line in
# the secret tfvars, a file row has its file (and, when it is a variable, the line).
_secrets_local_present() {
  local var="$1" kind="$2" dest="$3" tfvar="$4" tfvars="$V_STACK_DIR/$V_SECRET_TFVARS"
  if [ "$kind" = file ] && [ ! -f "$(_secrets_dest_path "$dest")" ]; then
    return 1
  fi
  [ "$tfvar" = no ] && return 0
  [ -f "$tfvars" ] && grep -Eq "^$var[[:space:]]*=" "$tfvars"
}

# The version recorded for a secret id in the secret tfvars' header, if any.
_secrets_local_version() {
  local tfvars="$1" id="$2"
  [ -f "$tfvars" ] || return 0
  awk -v id="$id" '
    /^#/ {
      v = $0
      sub(/^#[ \t]*[^ \t]+[ \t]*=[ \t]*/, "", v)
      n = index(v, "@")
      if (n > 0 && substr(v, 1, n - 1) == id) { print substr(v, n + 1); exit }
    }' "$tfvars"
}

# The HCL assignment for an inline payload, on stdout. A payload with no newline
# is one quoted string, with \ " ${ and %{ escaped. One with a newline is a
# heredoc, whose delimiter is the first of EOT, EOT1, EOT2 ... that is not a line
# of the payload; only ${ and %{ are escaped there, since a heredoc takes
# backslashes and quotes as they are. HCL keeps the heredoc's final newline, so a
# payload that lacks one gains it: configs that care use chomp().
_secrets_encode_inline() {
  local var="$1" file="$2" mode=single
  [ "$(wc -l < "$file" | tr -d ' ')" = 0 ] || mode=heredoc
  LC_ALL=C awk -v var="$var" -v mode="$mode" '
    function esc(s, quoted,   out, i, n, c, d) {
      if (s !~ /[\\"$%]/) return s
      out = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        d = substr(s, i + 1, 1)
        if (quoted && c == "\\") out = out "\\\\"
        else if (quoted && c == "\"") out = out "\\\""
        else if ((c == "$" || c == "%") && d == "{") out = out c c
        else out = out c
      }
      return out
    }
    { line[NR] = $0 }
    END {
      if (mode == "single") {
        print var " = \"" esc(line[1], 1) "\""
        exit
      }
      for (k = 0; ; k++) {
        delim = (k == 0) ? "EOT" : "EOT" k
        clash = 0
        for (i = 1; i <= NR; i++) {
          t = line[i]
          sub(/^[ \t]+/, "", t)
          sub(/[ \t]+$/, "", t)
          if (t == delim) { clash = 1; break }
        }
        if (!clash) break
      }
      print var " = <<" delim
      for (i = 1; i <= NR; i++) print esc(line[i], 0)
      print delim
    }' "$file"
}

# Copy FILE=<path> to $2. A relative path is taken from the directory task was
# run in (V_USER_WORKING_DIR), not the repo root that go-task runs commands from.
_secrets_read_file() {
  local file="$1" out="$2"
  case "$file" in
    /*) ;;
    *) file="${V_USER_WORKING_DIR:-.}/$file" ;;
  esac
  [ -f "$file" ] || {
    echo "FILE=$file does not exist." >&2
    exit 1
  }
  cp "$file" "$out"
}

# Check a payload source and turn it into what is stored, in _SECRETS_PAYLOAD.
# Inline is the bytes as they are. File is gzip -n, which keeps no name or
# timestamp, so the same input is the same bytes and an unchanged file can be
# recognized. Both must fit Secret Manager's 64 KiB, and neither may be empty.
_secrets_prepare() {
  local kind="$1" src="$2" label="$3" size
  if [ ! -s "$src" ]; then
    echo "the value for $label is empty. Secret Manager would store it, and Terraform would see \"\": almost always a mistake." >&2
    exit 1
  fi
  size=$(wc -c < "$src" | tr -d ' ')
  if [ "$kind" = file ]; then
    _SECRETS_PAYLOAD="$_SECRETS_WORK/payload.gz"
    gzip -n -c "$src" > "$_SECRETS_PAYLOAD"
    local gz
    gz=$(wc -c < "$_SECRETS_PAYLOAD" | tr -d ' ')
    if [ "$gz" -gt "$SECRETS_MAX_BYTES" ]; then
      echo "$label is $gz bytes after gzip ($size before): over Secret Manager's $SECRETS_MAX_BYTES-byte (64 KiB) limit." >&2
      exit 1
    fi
  else
    _SECRETS_PAYLOAD="$src"
    if [ "$size" -gt "$SECRETS_MAX_BYTES" ]; then
      echo "$label is $size bytes: over Secret Manager's $SECRETS_MAX_BYTES-byte (64 KiB) limit. Inline secrets are not compressed." >&2
      exit 1
    fi
  fi
}

# A label value: lowercased, anything gcloud would refuse made _, 63 characters at most.
_secrets_label() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '_' | cut -c1-63
}

# Create a secret holding the payload file as its first version. The labels
# record where it came from for anyone auditing the project; nothing reads them.
_secrets_create() {
  local id="$1" payload="$2" kind="$3" var="$4"
  local labels
  labels="stack=$(_secrets_label "$V_STACK"),vars=$(_secrets_label "$V_VARS_ID"),var=$(_secrets_label "$var")"
  [ "$kind" != file ] || labels="$labels,encoding=gzip"
  gcloud secrets create "$id" --project="$V_SECRETS_PROJECT" \
    --replication-policy=automatic --labels="$labels" --data-file=- < "$payload"
}

# Add the payload file as a new version of an existing secret.
_secrets_add_version() {
  local id="$1" payload="$2"
  gcloud secrets versions add "$id" --project="$V_SECRETS_PROJECT" --data-file=- < "$payload"
}

# tf:secrets -- what discovery says this stack's secrets are, and where each
# stands: in the cloud (CLOUD, the latest version), and on this machine (LOCAL:
# yes, no, or stale when the version recorded in the secret tfvars header is
# older than CLOUD).
tf_secrets() {
  _secrets_need_gcloud
  _secrets_work_init

  local rows
  rows=$(_secrets_rows)

  local manifest="$V_STACK_DIR/$V_SECRETS_FILE" tfvars="$V_STACK_DIR/$V_SECRET_TFVARS"
  printf '%-10s %s\n' STACK "$V_STACK"
  printf '%-10s %s\n' VARS_ID "$V_VARS_ID"
  printf '%-10s %s\n' PROJECT "$V_SECRETS_PROJECT"
  printf '%-10s %s\n' PREFIX "${V_SECRET_PREFIX:-(none)}"
  if [ -f "$manifest" ]; then
    printf '%-10s %s (present)\n' MANIFEST "$manifest"
  else
    printf '%-10s %s (absent)\n' MANIFEST "$manifest"
  fi
  if [ -f "$tfvars" ]; then
    printf '%-10s %s (present)\n' TFVARS "$tfvars"
  else
    printf '%-10s %s (absent)\n' TFVARS "$tfvars"
  fi
  [ -n "$rows" ] || {
    echo
    echo "no secrets: no variable in $V_STACK_DIR is sensitive or ephemeral"
    return 0
  }

  local table="$_SECRETS_WORK/table"
  printf 'VAR\tKIND\tREQUIRED\tID\tDEST\tCLOUD\tLOCAL\n' > "$table"
  local var kind required id dest tfvar cloud local_state rc shown_kind shown_dest lv
  while IFS=$TAB read -r var kind required id dest tfvar; do
    rc=0
    _secrets_latest "$id" || rc=$?
    case "$rc" in
      0) cloud="$_SECRETS_VERSION" ;;
      3) cloud='-' ;;
      *) exit 1 ;;
    esac
    if _secrets_local_present "$var" "$kind" "$dest" "$tfvar"; then
      local_state=yes
      lv=$(_secrets_local_version "$tfvars" "$id")
      case "$lv$cloud" in
        *[!0-9]*|'') ;;
        *) [ "$cloud" != '-' ] && [ -n "$lv" ] && [ "$lv" -lt "$cloud" ] && local_state=stale ;;
      esac
    else
      local_state=no
    fi
    shown_kind="$kind"
    [ "$tfvar" = yes ] || shown_kind=file-only
    shown_dest="$dest"
    [ "$kind" = file ] && shown_dest=$(_secrets_dest_path "$dest")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$var" "$shown_kind" "$required" "$id" "$shown_dest" "$cloud" "$local_state" >> "$table"
  done <<EOF
$rows
EOF

  echo
  awk -F'\t' '
    { r[NR] = $0; for (i = 1; i <= 7; i++) if (length($i) > w[i]) w[i] = length($i) }
    END {
      for (n = 1; n <= NR; n++) {
        split(r[n], f, "\t")
        line = ""
        for (i = 1; i <= 7; i++) line = line sprintf("%-" w[i] "s", f[i]) (i < 7 ? "  " : "")
        sub(/ +$/, "", line)
        print line
      }
    }' "$table"
}

# tf:secrets:pull:ask -- fetch every secret this stack needs and write the secret
# tfvars and the file-kind files. All or nothing: everything is fetched and
# decoded into a scratch dir first, and nothing is written when a required
# secret is missing, a fetch fails, or a destination is not ignored by git.
tf_secrets_pull() {
  _secrets_need_gcloud
  _secrets_work_init

  local rows
  rows=$(_secrets_rows)
  if [ -z "$rows" ]; then
    echo "no secrets: no variable in $V_STACK_DIR is sensitive or ephemeral. Nothing to pull."
    return 0
  fi

  local entries="$_SECRETS_WORK/entries" missing="$_SECRETS_WORK/missing"
  : > "$entries"
  : > "$missing"
  local n=0 var kind required id dest tfvar rc
  while IFS=$TAB read -r var kind required id dest tfvar; do
    n=$((n + 1))
    rc=0
    _secrets_fetch "$id" "$_SECRETS_WORK/$n.raw" || rc=$?
    case "$rc" in
      0) printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$var" "$kind" "$id" "$dest" "$tfvar" "$_SECRETS_VERSION" >> "$entries" ;;
      3)
        if [ "$required" = yes ]; then
          printf '%s\t%s\n' "$var" "$id" >> "$missing"
        else
          echo "skipping optional $var ($id): not in $V_SECRETS_PROJECT"
        fi
        ;;
      *) exit 1 ;;
    esac
  done <<EOF
$rows
EOF

  if [ -s "$missing" ]; then
    echo "required secrets missing from $V_SECRETS_PROJECT, nothing written:" >&2
    while IFS=$TAB read -r var id; do
      echo "  $var ($id)" >&2
      echo "    task tf:secrets:push:ask STACK=$V_STACK VARS=$V_VARS_ID VAR=$var" >&2
    done < "$missing"
    exit 1
  fi

  # Stage everything: the new secret tfvars and each file-kind payload, mode 600,
  # fully decoded, so the writes at the end are only renames.
  local tfvars="$V_STACK_DIR/$V_SECRET_TFVARS" staged="$_SECRETS_WORK/tfvars.new" width=0 ver magic
  local files="$_SECRETS_WORK/files"
  : > "$files"
  while IFS=$TAB read -r n var kind id dest tfvar ver; do
    [ "${#var}" -le "$width" ] || width=${#var}
  done < "$entries"
  {
    echo "# written by: task tf:secrets:pull:ask STACK=$V_STACK VARS=$V_VARS_ID"
    echo "# do not edit, do not commit. Regenerate with the same command."
    while IFS=$TAB read -r n var kind id dest tfvar ver; do
      printf '# %-*s = %s@%s\n' "$width" "$var" "$id" "$ver"
    done < "$entries"
  } > "$staged"
  while IFS=$TAB read -r n var kind id dest tfvar ver; do
    if [ ! -s "$_SECRETS_WORK/$n.raw" ]; then
      echo "secret $id ($var) is empty in $V_SECRETS_PROJECT. Push a value for it." >&2
      exit 1
    fi
    if [ "$kind" = inline ]; then
      echo >> "$staged"
      _secrets_encode_inline "$var" "$_SECRETS_WORK/$n.raw" >> "$staged"
      continue
    fi
    magic=$(od -An -tx1 -N2 "$_SECRETS_WORK/$n.raw" | tr -d ' \n')
    if [ "$magic" = 1f8b ]; then
      gzip -dc "$_SECRETS_WORK/$n.raw" > "$_SECRETS_WORK/$n.out" || {
        echo "secret $id ($var) starts like gzip but does not decompress." >&2
        exit 1
      }
    else
      cp "$_SECRETS_WORK/$n.raw" "$_SECRETS_WORK/$n.out"
    fi
    chmod 600 "$_SECRETS_WORK/$n.out"
    printf '%s\t%s\n' "$n" "$(_secrets_dest_path "$dest")" >> "$files"
    if [ "$tfvar" = yes ]; then
      printf '%s' "$dest" > "$_SECRETS_WORK/$n.dest"
      echo >> "$staged"
      _secrets_encode_inline "$var" "$_SECRETS_WORK/$n.dest" >> "$staged"
    fi
  done < "$entries"
  chmod 600 "$staged"

  _secrets_gitignore
  local path refused=0
  while IFS=$TAB read -r n path; do
    _secrets_check_ignored "$path" || refused=1
    if [ -d "$path" ]; then
      echo "refusing to write $path: it is a directory. Name a file in $V_STACK_DIR/$V_SECRETS_FILE." >&2
      refused=1
    fi
  done < "$files"
  _secrets_check_ignored "$(_secrets_norm "$tfvars")" || refused=1
  [ "$refused" = 0 ] || exit 1

  # Each secret against what is here before anything is replaced: new (no local
  # copy), updated, or unchanged. An inline secret compares the id@version the
  # current tfvars header records; a file compares bytes, so an edited or deleted
  # file counts as changed. Only changed files are rewritten, and the tfvars only
  # when its bytes differ, so a pull that changes nothing writes nothing.
  local st old
  while IFS=$TAB read -r n var kind id dest tfvar ver; do
    old=""
    if [ "$kind" = inline ]; then
      old=$(_secrets_local_version "$tfvars" "$id")
      if ! _secrets_local_present "$var" "$kind" "$dest" "$tfvar"; then
        st=new
      elif [ "$old" != "$ver" ]; then
        st=updated
      else
        st=unchanged
      fi
    else
      path=$(_secrets_dest_path "$dest")
      if [ ! -f "$path" ]; then
        st=new
      elif cmp -s "$_SECRETS_WORK/$n.out" "$path"; then
        st=unchanged
      else
        st=updated
      fi
    fi
    printf '%s' "$st" > "$_SECRETS_WORK/$n.status"
    if [ "$st" = updated ] && [ -n "$old" ]; then
      printf ' (was @%s)' "$old" > "$_SECRETS_WORK/$n.was"
    else
      : > "$_SECRETS_WORK/$n.was"
    fi
  done < "$entries"

  # Every parent dir first, so the one step that can fail on a bad path does so
  # before anything is replaced; then only renames.
  while IFS=$TAB read -r n path; do
    mkdir -p "$(dirname "$path")"
  done < "$files"
  mkdir -p "$(dirname "$tfvars")"
  local wrote=""
  while IFS=$TAB read -r n path; do
    [ "$(cat "$_SECRETS_WORK/$n.status")" != unchanged ] || continue
    mv -f "$_SECRETS_WORK/$n.out" "$path"
    wrote="$wrote  $path"$'\n'
  done < "$files"
  if ! { [ -f "$tfvars" ] && cmp -s "$staged" "$tfvars"; }; then
    mv -f "$staged" "$tfvars"
    wrote="  $tfvars"$'\n'"$wrote"
  fi

  echo "secrets for $V_STACK (VARS=$V_VARS_ID) from $V_SECRETS_PROJECT:"
  while IFS=$TAB read -r n var kind id dest tfvar ver; do
    printf '  %-*s  %-9s  %s@%s%s\n' "$width" "$var" "$(cat "$_SECRETS_WORK/$n.status")" \
      "$id" "$ver" "$(cat "$_SECRETS_WORK/$n.was")"
  done < "$entries"
  if [ -n "$wrote" ]; then
    echo "wrote:"
    printf '%s' "$wrote"
  else
    echo "up to date: nothing written."
  fi
}

# tf:secrets:push:ask -- store one secret: create it, or add a version when it
# exists and the bytes differ. The source is FILE if given, else a file-kind
# secret's own destination, else stdin, taken byte for byte.
tf_secrets_push() {
  local var="$1" file="${2:-}"
  [ -n "$var" ] || {
    echo "VAR is required: the variable the secret belongs to, e.g." >&2
    echo "  task tf:secrets:push:ask STACK=$V_STACK VARS=$V_VARS_ID VAR=<var>" >&2
    exit 1
  }
  _secrets_need_gcloud
  _secrets_work_init

  local rows row
  rows=$(_secrets_rows)
  row=$(printf '%s\n' "$rows" | awk -F'\t' -v v="$var" '$1 == v && !f { print; f = 1 }')
  [ -n "$row" ] || {
    echo "$var is not a secret of $V_STACK (VARS=$V_VARS_ID). A secret is a variable with" >&2
    echo "sensitive = true or ephemeral = true, or a block in $V_STACK_DIR/$V_SECRETS_FILE." >&2
    echo "To add one: task tf:secrets:new:ask STACK=$V_STACK VARS=$V_VARS_ID ID=$var" >&2
    exit 1
  }
  local kind id dest
  IFS=$TAB read -r var kind _ id dest _ <<EOF
$row
EOF

  local src="$_SECRETS_WORK/src"
  if [ -n "$file" ]; then
    _secrets_read_file "$file" "$src"
  elif [ "$kind" = file ]; then
    local path
    path=$(_secrets_dest_path "$dest")
    [ -f "$path" ] || {
      echo "$var is a file secret and $path does not exist. Pass FILE=<path> to push from elsewhere." >&2
      exit 1
    }
    cp "$path" "$src"
  elif [ -t 0 ]; then
    echo "$var is an inline secret: pipe the value in, e.g." >&2
    echo "  printf '%s' \"\$value\" | task tf:secrets:push:ask STACK=$V_STACK VARS=$V_VARS_ID VAR=$var" >&2
    echo "or pass FILE=<path>." >&2
    exit 1
  else
    cat > "$src"
  fi
  _secrets_prepare "$kind" "$src" "$var ($id)"

  local rc=0
  _secrets_exists "$id" || rc=$?
  case "$rc" in
    0)
      local latest="$_SECRETS_WORK/latest"
      rc=0
      _secrets_fetch "$id" "$latest" || rc=$?
      case "$rc" in
        0)
          if cmp -s "$latest" "$_SECRETS_PAYLOAD"; then
            echo "$id already holds this value (version $_SECRETS_VERSION): nothing to add"
            return 0
          fi
          ;;
        3) ;;
        *) exit 1 ;;
      esac
      _secrets_add_version "$id" "$_SECRETS_PAYLOAD"
      echo "added a version to $id in $V_SECRETS_PROJECT"
      ;;
    3)
      _secrets_create "$id" "$_SECRETS_PAYLOAD" "$kind" "$var"
      echo "created $id in $V_SECRETS_PROJECT"
      ;;
    *) exit 1 ;;
  esac
}

# tf:secrets:assert -- offline guard for anything that plans: refuse when a
# required secret is not on this machine. A required inline secret needs a
# `<var> =` line in the secret tfvars, a required file secret needs its file.
tf_secrets_assert() {
  local rows
  rows=$(_secrets_rows)
  [ -n "$rows" ] || return 0

  local tfvars="$V_STACK_DIR/$V_SECRET_TFVARS" missing=""
  local var kind required id dest tfvar
  while IFS=$TAB read -r var kind required id dest tfvar; do
    [ "$required" = yes ] || continue
    _secrets_local_present "$var" "$kind" "$dest" "$tfvar" && continue
    if [ "$kind" = file ] && [ ! -f "$(_secrets_dest_path "$dest")" ]; then
      missing="$missing  $var: $(_secrets_dest_path "$dest") does not exist"$'\n'
    else
      missing="$missing  $var: no '$var =' line in $tfvars"$'\n'
    fi
  done <<EOF
$rows
EOF
  [ -n "$missing" ] || return 0

  echo "required secrets are not on this machine (STACK=$V_STACK VARS=$V_VARS_ID):" >&2
  printf '%s' "$missing" >&2
  echo "fetch them with: task tf:secrets:pull:ask STACK=$V_STACK VARS=$V_VARS_ID" >&2
  exit 1
}

# tf:secrets:setup -- one-time, idempotent setup of Secret Manager for the repo.
# Each step reads before it writes, so a second run changes nothing.
tf_secrets_setup() {
  _secrets_dir_clean "$V_SECRETS_DIR" >/dev/null || exit 1
  _secrets_need_gcloud

  local p="$V_SECRETS_PROJECT" api=secretmanager.googleapis.com enabled
  enabled=$(gcloud services list --enabled --project="$p" --filter="config.name=$api" \
              --format='value(config.name)' </dev/null)
  if [ -n "$enabled" ]; then
    echo "$api already enabled in $p"
  else
    echo "enabling $api in $p"
    gcloud services enable "$api" --project="$p"
  fi

  if gcloud secrets list --project="$p" --limit=1 >/dev/null </dev/null; then
    echo "Secret Manager in $p is reachable"
  else
    echo "cannot list secrets in $p. You need:" >&2
    echo "  roles/secretmanager.admin           to create secrets and add versions" >&2
    echo "  roles/secretmanager.secretAccessor  to pull them" >&2
    exit 1
  fi

  _secrets_gitignore

  echo "secrets are ready. Next:"
  echo "  task tf:secrets:new:ask ID=<var>  create a secret, and declare its variable if needed"
  echo "  task tf:secrets                   see what a stack needs and what is where"
}

# tf:secrets:new:ask -- create a secret and, if no variable declares it yet, declare
# one, sensitive and ephemeral: an ephemeral value never reaches state or a plan
# file, and tofu refuses it anywhere that would put it there, so a config that
# needs the value in a regular resource argument drops `ephemeral` by hand.
# ID is the variable name (or a file-only manifest label). The value comes from
# FILE, else a hidden prompt on a terminal, else stdin. Ordered so that a
# failure leaves nothing half done: all checks, then the secret, then the
# declaration, then a pull to put the value where Terraform will find it.
tf_secrets_new() {
  local var="$1" file="${2:-}"
  [ -n "$var" ] || {
    echo "ID is required: the variable name for the new secret, e.g." >&2
    echo "  task tf:secrets:new:ask STACK=$V_STACK VARS=$V_VARS_ID ID=db_password" >&2
    exit 1
  }
  case "$var" in
    [!A-Za-z_]*|*[!A-Za-z0-9_-]*)
      echo "ID=$var is not a valid Terraform variable name (letters, digits, _ and -; not starting with a digit)." >&2
      exit 1
      ;;
  esac
  _secrets_need_gcloud
  _secrets_work_init

  local rows row kind=inline id declared=no
  rows=$(_secrets_rows)
  row=$(printf '%s\n' "$rows" | awk -F'\t' -v v="$var" '$1 == v && !f { print; f = 1 }')
  if [ -n "$row" ]; then
    declared=yes
    IFS=$TAB read -r _ kind _ id _ _ <<EOF
$row
EOF
  else
    if _secrets_variables "$V_STACK_DIR" | awk -F'\t' -v v="$var" '$2 == v && $3 == 0 { f = 1 } END { exit !f }'; then
      echo "variable \"$var\" exists in $V_STACK_DIR but is neither sensitive nor ephemeral. Set sensitive = true on it to make it a secret." >&2
      exit 1
    fi
    id="$V_SECRET_PREFIX$V_STACK-$V_VARS_ID-$var"
    case "$id" in
      *[!A-Za-z0-9_-]*)
        echo "the Secret Manager id \"$id\" is not valid (letters, digits, _ and - only)." >&2
        echo "Declare $var in $V_STACK_DIR/$V_SECRETS_FILE with an id of your own." >&2
        exit 1
        ;;
    esac
  fi

  local rc=0
  _secrets_exists "$id" || rc=$?
  case "$rc" in
    0)
      echo "secret $id already exists in $V_SECRETS_PROJECT. To store a new version:" >&2
      echo "  task tf:secrets:push:ask STACK=$V_STACK VARS=$V_VARS_ID VAR=$var" >&2
      exit 1
      ;;
    3) ;;
    *) exit 1 ;;
  esac

  local src="$_SECRETS_WORK/src"
  if [ -n "$file" ]; then
    _secrets_read_file "$file" "$src"
  elif [ -t 0 ]; then
    local a b
    printf 'value for %s (one line, hidden): ' "$var" >&2
    IFS= read -rs a
    echo >&2
    printf 'again: ' >&2
    IFS= read -rs b
    echo >&2
    [ "$a" = "$b" ] || {
      echo "the two entries differ; nothing created." >&2
      exit 1
    }
    printf '%s' "$a" > "$src"
    a=
    b=
  else
    cat > "$src"
  fi
  _secrets_prepare "$kind" "$src" "$var ($id)"

  _secrets_create "$id" "$_SECRETS_PAYLOAD" "$kind" "$var"
  echo "created $id in $V_SECRETS_PROJECT"

  if [ "$declared" = no ]; then
    # Staged and renamed into place like the tfvars, but this file is committed
    # source, not a secret: an existing one keeps its mode (cp -p), a new one
    # gets the caller's umask rather than 077.
    local tf="$V_STACK_DIR/$V_SECRETS_TF" staged="$_SECRETS_WORK/secrets.tf"
    if [ -f "$tf" ]; then
      cp -p "$tf" "$staged"
      [ -z "$(tail -c 1 "$staged")" ] || echo >> "$staged"
    else
      ( umask "$_SECRETS_UMASK"; : > "$staged" )
      echo '# Secret variables, declared by task tf:secrets:new:ask. Values live in Secret Manager.' >> "$staged"
    fi
    {
      echo
      echo "variable \"$var\" {"
      echo '  type      = string'
      echo '  sensitive = true'
      echo '  ephemeral = true'
      echo '}'
    } >> "$staged"
    mv -f "$staged" "$tf"
    echo "declared variable \"$var\" in $tf"
  fi

  rc=0
  bash "$0" tf_secrets_pull || rc=$?
  if [ "$rc" != 0 ]; then
    echo "the secret $id itself was created; the pull above failed (exit $rc)." >&2
    exit "$rc"
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
