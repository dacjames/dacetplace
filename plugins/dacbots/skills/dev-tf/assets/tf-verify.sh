#!/usr/bin/env bash
#
# tf-verify.sh
# ------------
#
# offline self-check for a tf-stack install (scripts/tf-stack.sh + the tf:*
# Taskfile block). read-only: no credentials, no cloud calls, no state
# lock. Run from the repo root -- this is what `task tf:verify` does.
#
# Prints one line per check, "PASS <n> ..." or "FAIL <n> ...: <reason>",
# and exits non-zero if any check FAILs. `--offline` skips checks 10 and
# 11 (the tf:use round trip and tf:fmt:check:all / tf:validate:all), the
# only two that shell out to tofu/terraform itself.

set -uo pipefail

# go-task accepts either spelling, and repos in the wild use both. Detect
# rather than assume: hardcoding .yml makes check 3 report "not found" on a
# .yaml repo, and the only way out would be editing this file -- which
# convention 1 forbids.
if [ -f "Taskfile.yml" ]; then
  TASKFILE="Taskfile.yml"
elif [ -f "Taskfile.yaml" ]; then
  TASKFILE="Taskfile.yaml"
else
  TASKFILE="Taskfile.yml"   # absent either way; check 3 reports it
fi
SCRIPT="scripts/tf-stack.sh"
FAILED=0
OFFLINE=0

for arg in "$@"; do
  case "$arg" in
    --offline) OFFLINE=1 ;;
  esac
done

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAILED=1
}

skip() {
  printf 'SKIP %s (--offline)\n' "$1"
}

# -- shared helpers -- #

# the stack names tf_stacks_list prints, one per line, in the order given.
# each row is fixed-width ("%-14s %-9s %-9s %s"), so a stack name never
# collides with the WRITABLE/BACKEND/STATE columns.
list_stacks() {
  task tf:stacks:list 2>/dev/null |
    sed '1d' |
    cut -c1-14 |
    sed 's/[[:space:]]*$//' |
    sed '/^$/d'
}

# stacks live under stacks/: the one layout tf-stack.sh's tf_stacks_list and
# the Taskfile's STACK_DIR both hardcode. Spelled here rather than asked of
# `task`, because a stack with no valid default VARS/BACKEND (any real
# multi-env stack) refuses tf:backend before ever printing a DATA_DIR/FILE
# line STACK_DIR could be parsed back out of.
stack_dir_for() {
  printf 'stacks/%s' "$1"
}

# picks one stack and one VARS id that actually resolves for it, printed
# as "STACK ID" -- needed because a stack's own bare default only exists
# for a single-module repo (VARS_MAP empty); anywhere VARS_MAP is
# populated, a stack may have no file for the first (or any) global id.
pick_stack_and_id() {
  local stacks map s stack_dir ids id
  stacks=$(list_stacks)
  map=$(task tf:vars:map 2>/dev/null)
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    stack_dir=$(stack_dir_for "$s")
    if [ -n "$map" ]; then
      ids=$(bash "$SCRIPT" VARS_IDS_PRESENT "$stack_dir" "$map" 2>/dev/null)
      id=$(printf '%s\n' "$ids" | sed -n '1p')
      if [ -n "$id" ]; then
        printf '%s %s\n' "$s" "$id"
        return 0
      fi
    elif [ -e "$stack_dir/variables/$s.tfvars" ]; then
      # Single- or multi-stack shape (VARS_MAP empty, one
      # variables/<stack>.tfvars per stack). Spell the pick out in full,
      # colon included, so it bypasses the empty map: a bare "VARS=<stack>"
      # would be looked up in VARS_MAP and fail, unlike leaving VARS unset.
      printf '%s %s:variables/%s.tfvars\n' "$s" "$s" "$s"
      return 0
    fi
  done <<STACKS
$stacks
STACKS
  return 1
}

# extract the value half of one "%-10s %s" line tf_vars/tf_backend print,
# reading candidate lines on stdin. Prints nothing (rc 1) if FIELD never
# appears. The value starts at column 12 no matter how short the label is,
# since %-10s always pads the label to exactly 10 columns before the
# format's own literal space.
kv_value() {
  local field="$1" line label
  while IFS= read -r line; do
    label=$(printf '%s' "$line" | cut -c1-10 | sed 's/[[:space:]]*$//')
    if [ "$label" = "$field" ]; then
      printf '%s\n' "$line" | cut -c12-
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------
# 1. bash -n scripts/tf-stack.sh parses; shellcheck if installed.
# shellcheck's own findings are informational only, not gating: several
# tf-stack.sh patterns (unscoped IFS, deliberate exit-vs-return, a bare
# cd guarded only by a later exit) are load-bearing and documented in the
# source, and shellcheck has no way to know that.
# ---------------------------------------------------------------------
check1() {
  local label="1 bash -n $SCRIPT parses"
  if [ ! -f "$SCRIPT" ]; then
    fail "$label" "$SCRIPT not found"
    return
  fi
  local out rc
  out=$(bash -n "$SCRIPT" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$label" "bash -n failed: $out"
    return
  fi
  pass "$label"
  if command -v shellcheck >/dev/null 2>&1; then
    out=$(shellcheck "$SCRIPT" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '     shellcheck: clean\n'
    else
      printf '     shellcheck: findings (informational, not gating):\n'
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  else
    printf '     shellcheck: not installed, skipped\n'
  fi
}

# ---------------------------------------------------------------------
# 2. scripts/tf-stack.sh help lists exactly the expected 31 function
# names -- catches a truncated copy. This set is the frozen ABI (dev-tf
# plan section 4): a byte-for-byte copy always carries all 31, regardless
# of which backend/toolchain the target repo uses, and regardless of
# whether its stacks keep their backends in .backend.hcl files or inline.
# ---------------------------------------------------------------------
check2() {
  local label="2 $SCRIPT help lists exactly 31 functions"
  if [ ! -x "$SCRIPT" ] && [ ! -f "$SCRIPT" ]; then
    fail "$label" "$SCRIPT not found"
    return
  fi
  local expected
  expected=$(cat <<'NAMES'
BACKEND_DEFAULT
BACKEND_FILE
BACKEND_INLINE_FILE
BACKEND_KIND
BACKEND_TYPE
BACKEND_VALUE
_hcl_block
_hcl_lines
_hcl_string
_normalize_spec
BACKEND_RESOLVED
BACKEND_STATE
USE_BACKEND
USE_VARS
VARS_IDS_PRESENT
VARS_RESOLVED
VAR_FILES
tf_backend
tf_backend_assert
tf_init_init
tf_setup
tf_stack_assert
tf_stacks_list
tf_toolchain_install
tf_toolchain_show
tf_toolchain_use_ask
tf_use
tf_use_clear
tf_validate_all
tf_vars
tf_vars_assert
NAMES
)
  local expected_sorted expected_count
  expected_sorted=$(printf '%s\n' "$expected" | sort)
  expected_count=$(printf '%s\n' "$expected_sorted" | grep -c .)
  if [ "$expected_count" -ne 31 ]; then
    fail "$label" "internal error in tf-verify.sh: expected list has $expected_count names, not 31"
    return
  fi

  local raw actual_sorted actual_count
  raw=$(bash "$SCRIPT" help 2>&1 1>/dev/null)
  actual_sorted=$(printf '%s\n' "$raw" | sed -n 's/^  //p' | sort)
  actual_count=$(printf '%s\n' "$actual_sorted" | grep -c .)

  if [ "$actual_sorted" = "$expected_sorted" ]; then
    pass "$label"
    return
  fi

  local missing added
  missing=$(comm -23 <(printf '%s\n' "$expected_sorted") <(printf '%s\n' "$actual_sorted") | tr '\n' ' ')
  added=$(comm -13 <(printf '%s\n' "$expected_sorted") <(printf '%s\n' "$actual_sorted") | tr '\n' ' ')
  fail "$label" "got $actual_count names; missing: [$missing] extra: [$added]"
}

# ---------------------------------------------------------------------
# 3. task --list exits 0 and names every expected tf: task; the four
# guards exist and are internal. go-task 3.53.1 hides internal:true tasks
# from both --list and --list-all, so "is it internal" is asked of `task`
# itself (`task --summary <name>` prints `... is internal` and exits 202
# for one, or a normal summary and exits 0 for an ordinary task, or `...
# does not exist` and exits 200 for neither) rather than grepped out of
# the YAML, which is the other builder's file and format is not ours to
# assume.
# ---------------------------------------------------------------------
CORE_TASKS='tf:stacks:list
tf:vars
tf:vars:ids
tf:vars:map
tf:backend
tf:backend:ids
tf:backend:map
tf:use
tf:use:clear
tf:init:once
tf:init:init
tf:init:once:all
tf:init:local
tf:init:upgrade:ask
tf:fmt
tf:fmt:check
tf:fmt:check:all
tf:validate
tf:validate:local
tf:validate:all
tf:plan
tf:plan:all
tf:plan:show
tf:plan:debug
tf:output
tf:clean
tf:apply:ask
tf:refresh:ask
tf:destroy:deny
tf:verify'

GUARD_TASKS='tf:stack:assert
tf:backend:assert
tf:vars:assert'

check3() {
  local label="3 task --list / guards"
  if [ ! -f "$TASKFILE" ]; then
    fail "$label" "$TASKFILE not found"
    return
  fi
  local list_out list_rc
  list_out=$(task --list 2>&1); list_rc=$?
  if [ "$list_rc" -ne 0 ]; then
    fail "$label" "task --list exited $list_rc: $list_out"
    return
  fi
  local all_rc
  task --list-all >/dev/null 2>&1; all_rc=$?
  if [ "$all_rc" -ne 0 ]; then
    fail "$label" "task --list-all exited $all_rc (a broken YAML anchor fails the whole file at parse time)"
    return
  fi

  local bad="" t rc
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    task --summary "$t" >/dev/null 2>&1; rc=$?
    if [ "$rc" -ne 0 ]; then
      bad="$bad $t(rc=$rc,want-0)"
      continue
    fi
    printf '%s\n' "$list_out" | grep -q "^\* $t:" || bad="$bad $t(missing-from---list)"
  done <<CORE
$CORE_TASKS
CORE

  while IFS= read -r t; do
    [ -n "$t" ] || continue
    task --summary "$t" >/dev/null 2>&1; rc=$?
    if [ "$rc" -ne 202 ]; then
      bad="$bad $t(rc=$rc,want-202-internal)"
      continue
    fi
    printf '%s\n' "$list_out" | grep -q "^\* $t:" && bad="$bad $t(internal-but-listed)"
  done <<GUARDS
$GUARD_TASKS
GUARDS

  task --summary tf:toolchain:assert:tofu >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 202 ]; then
    task --summary tf:toolchain:assert:terraform >/dev/null 2>&1; rc=$?
    if [ "$rc" -ne 202 ]; then
      bad="$bad tf:toolchain:assert:tofu-or-terraform(not-internal)"
    fi
  fi

  if [ -n "$bad" ]; then
    fail "$label" "$bad"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------
# 4. no __DEV_TF_ tokens survive the install.
# ---------------------------------------------------------------------
check4() {
  local label="4 no __DEV_TF_ tokens remain"
  local targets="" p
  for p in "$TASKFILE" scripts docs; do
    [ -e "$p" ] && targets="$targets $p"
  done
  if [ -z "$targets" ]; then
    fail "$label" "none of $TASKFILE, scripts/, docs/ exist to check"
    return
  fi
  local hits
  # match a real token shape (double underscore, DEV_TF_NAME, double
  # underscore), not the generic prefix, so a comment that merely names
  # the prefix is not reported as a survivor. Exclude this script too --
  # it legitimately spells the pattern in order to grep for it, and is
  # installed verbatim into scripts/.
  # shellcheck disable=SC2086
  hits=$(grep -rnE '__DEV_TF_[A-Z_]+__' $targets 2>/dev/null | grep -v '^scripts/tf-verify\.sh:')
  if [ -n "$hits" ]; then
    fail "$label" "$(printf '%s' "$hits" | tr '\n' ' ')"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------
# 5. task tf:stacks:list -- one row per stack, correct WRITABLE, a state
# string on every writable row.
# ---------------------------------------------------------------------
check5() {
  local label="5 task tf:stacks:list rows are well-formed"
  local out rc
  out=$(task tf:stacks:list 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$label" "exited $rc: $out"
    return
  fi
  local header hname
  header=$(printf '%s\n' "$out" | sed -n '1p')
  hname=$(printf '%s' "$header" | cut -c1-14 | sed 's/[[:space:]]*$//')
  if [ "$hname" != "NAME" ]; then
    fail "$label" "unexpected header row: [$header]"
    return
  fi

  local bad="" line name writable backend state
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=$(printf '%s' "$line" | cut -c1-14 | sed 's/[[:space:]]*$//')
    writable=$(printf '%s' "$line" | cut -c16-24 | sed 's/[[:space:]]*$//')
    backend=$(printf '%s' "$line" | cut -c26-34 | sed 's/[[:space:]]*$//')
    state=$(printf '%s' "$line" | cut -c36-)
    case "$writable" in
      yes)
        [ -n "$backend" ] || bad="$bad ${name:-<cont>}:empty-backend-id"
        [ -n "$state" ] || bad="$bad ${name:-<cont>}:empty-state"
        [ "$state" != "local, plan-only" ] || bad="$bad ${name:-<cont>}:writable-yes-but-state-is-plan-only"
        ;;
      no)
        [ "$backend" = "-" ] || bad="$bad $name:writable-no-but-backend=[$backend]"
        [ "$state" = "local, plan-only" ] || bad="$bad $name:writable-no-but-state=[$state]"
        ;;
      "")
        [ -n "$backend" ] || bad="$bad <cont-of-prev>:empty-backend-id"
        [ -n "$state" ] || bad="$bad <cont-of-prev>:empty-state"
        ;;
      *)
        bad="$bad ${name:-<cont>}:unexpected-writable=[$writable]"
        ;;
    esac
  done <<ROWS
$(printf '%s\n' "$out" | sed '1d')
ROWS

  if [ -n "$bad" ]; then
    fail "$label" "$bad"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------
# 6. task tf:vars:ids / task tf:backend:ids -- exactly the derived ids,
# no strays: every id is non-blank, [A-Za-z0-9._-] (the same charset the
# asserts require), and unique.
# ---------------------------------------------------------------------
check_ids() {
  # $1 = list (possibly empty), $2 = label used in bad entries
  local list="$1" tag="$2" bad="" id dup
  if [ -n "$list" ]; then
    while IFS= read -r id; do
      if [ -z "$id" ]; then
        bad="$bad $tag:blank-line"
        continue
      fi
      case "$id" in
        *[!A-Za-z0-9._-]*) bad="$bad $tag:bad-chars=[$id]" ;;
      esac
    done <<IDS
$list
IDS
    dup=$(printf '%s\n' "$list" | sort | uniq -d | tr '\n' ',')
    [ -z "$dup" ] || bad="$bad $tag:duplicates=[$dup]"
  fi
  printf '%s' "$bad"
}

check6() {
  local label="6 task tf:vars:ids / tf:backend:ids"
  local vids vids_rc bids bids_rc
  vids=$(task tf:vars:ids 2>&1); vids_rc=$?
  bids=$(task tf:backend:ids 2>&1); bids_rc=$?
  if [ "$vids_rc" -ne 0 ] || [ "$bids_rc" -ne 0 ]; then
    fail "$label" "tf:vars:ids exited $vids_rc, tf:backend:ids exited $bids_rc"
    return
  fi
  local bad
  bad="$(check_ids "$vids" vars-id)$(check_ids "$bids" backend-id)"
  if [ -n "$bad" ]; then
    fail "$label" "$bad"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------
# 7. per stack x present id: tf:vars prints a non-empty FILES list, every
# named file exists, in the map's written order; tf:vars also prints a
# PLAN path carrying all four key parts; tf:backend prints a SOURCE and a
# STATE.
# ---------------------------------------------------------------------
expected_files_for_id() {
  # independently re-derives the ordered file list for STACK_DIR=$1,
  # VARS id=$2, by expanding the same comma-separated globs tf-stack.sh's
  # VAR_FILES would -- using bash's own globbing, not the shipped
  # function -- so this actually exercises VAR_FILES's real output for a
  # match instead of just re-running the same code path against itself.
  local stack_dir="$1" id="$2" map resolved globs g f
  map=$(task tf:vars:map 2>/dev/null)
  resolved=$(bash "$SCRIPT" VARS_RESOLVED "$id" "$map" 2>/dev/null)
  globs=$(printf '%s' "$resolved" | cut -d: -f2-)
  ( cd "$stack_dir" 2>/dev/null || exit 0
    IFS=','
    for g in $globs; do
      for f in $g; do
        [ -e "$f" ] && printf '%s\n' "$f"
      done
    done
  )
}

check7() {
  local label="7 tf:vars FILES/PLAN and tf:backend SOURCE/STATE per stack x id"
  local stacks
  stacks=$(list_stacks)
  if [ -z "$stacks" ]; then
    fail "$label" "no stacks found (task tf:stacks:list printed none)"
    return
  fi

  local bad="" s stack_dir map ids id resolved_any=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    stack_dir=$(stack_dir_for "$s")
    map=$(task tf:vars:map 2>/dev/null)
    ids=$(bash "$SCRIPT" VARS_IDS_PRESENT "$stack_dir" "$map" 2>/dev/null)
    [ -n "$ids" ] || continue
    resolved_any=1

    while IFS= read -r id; do
      [ -n "$id" ] || continue

      local vout vrc
      vout=$(task tf:vars STACK="$s" VARS="$id" 2>&1); vrc=$?
      if [ "$vrc" -ne 0 ]; then
        bad="$bad $s/$id:tf:vars-exited-$vrc"
        continue
      fi

      local files_section exp_files plan_val
      files_section=$(printf '%s\n' "$vout" | sed -n '/^FILES/,$p' | sed -e '1d' -e 's/^  //')
      if [ -z "$files_section" ]; then
        bad="$bad $s/$id:empty-FILES"
      else
        local missing_file=""
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          [ -e "$stack_dir/$f" ] || missing_file="$missing_file $f"
        done <<FSEC
$files_section
FSEC
        [ -z "$missing_file" ] || bad="$bad $s/$id:missing-files=[$missing_file]"

        exp_files=$(expected_files_for_id "$stack_dir" "$id")
        if [ "$files_section" != "$exp_files" ]; then
          bad="$bad $s/$id:FILES-order-mismatch"
        fi
      fi

      plan_val=$(printf '%s\n' "$vout" | kv_value PLAN)
      if [ -z "$plan_val" ]; then
        bad="$bad $s/$id:no-PLAN-line"
      else
        local plan_base middle
        plan_base=$(basename "$plan_val")
        case "$plan_base" in
          "$s-$id-"*".tfplan")
            middle=${plan_base#"$s-$id-"}
            middle=${middle%.tfplan}
            case "$middle" in
              *-*) : ;;
              *) bad="$bad $s/$id:PLAN-missing-backend_id-or-tf=[$plan_base]" ;;
            esac
            ;;
          *) bad="$bad $s/$id:PLAN-name-does-not-start-$s-$id-=[$plan_base]" ;;
        esac
      fi

      local bout brc
      bout=$(task tf:backend STACK="$s" VARS="$id" 2>&1); brc=$?
      if [ "$brc" -ne 0 ]; then
        bad="$bad $s/$id:tf:backend-exited-$brc"
        continue
      fi
      local source_val state_val
      source_val=$(printf '%s\n' "$bout" | kv_value SOURCE)
      state_val=$(printf '%s\n' "$bout" | kv_value STATE)
      [ -n "$source_val" ] || bad="$bad $s/$id:no-SOURCE-line"
      [ -n "$state_val" ] || bad="$bad $s/$id:no-STATE-line"
    done <<IDS
$ids
IDS
  done <<STACKS
$stacks
STACKS

  # A populated VARS_MAP that resolves for no stack at all is an install bug,
  # not a shape: the ids name files no stack has. (Spacing is no longer a
  # cause -- _normalize_spec in tf-stack.sh absorbs whitespace around the
  # colon and the commas -- so what is left is a genuine id/filename
  # mismatch.) Without this the whole check would pass vacuously, having
  # probed nothing.
  if [ "$resolved_any" = 0 ] && [ -n "$(task tf:vars:map 2>/dev/null)" ]; then
    bad="$bad VARS_MAP-is-non-empty-but-resolves-for-no-stack(ids-name-files-no-stack-has)"
  fi

  if [ -n "$bad" ]; then
    fail "$label" "$bad"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------
# 8. negative -- the guards are the point. A bad VARS, a bad BACKEND, and
# an unmatched glob must each be refused (non-zero exit); the first two
# must print "Known names:" on stderr. These run the real probes through
# the real `task`/scripts/tf-stack.sh, not a reimplementation, so an
# `exit` that regressed to a `return` fails this check open -- it does
# not fail closed silently.
# ---------------------------------------------------------------------
check8() {
  local label="8 negative guards (bad VARS / bad BACKEND / unmatched glob)"
  local s
  s=$(list_stacks | sed -n '1p')
  if [ -z "$s" ]; then
    fail "$label" "no stack found to probe against"
    return
  fi

  local bad="" out rc

  out=$(task tf:vars STACK="$s" VARS=__dev_tf_probe__ 2>&1 1>/dev/null); rc=$?
  if [ "$rc" -eq 0 ]; then
    bad="$bad bad-VARS-exited-0-FAILED-OPEN"
  elif ! printf '%s\n' "$out" | grep -q "Known names:"; then
    bad="$bad bad-VARS-missing-Known-names(rc=$rc)"
  fi

  out=$(task tf:backend STACK="$s" BACKEND=__dev_tf_probe__ 2>&1 1>/dev/null); rc=$?
  if [ "$rc" -eq 0 ]; then
    bad="$bad bad-BACKEND-exited-0-FAILED-OPEN"
  elif ! printf '%s\n' "$out" | grep -q "Known names:"; then
    bad="$bad bad-BACKEND-missing-Known-names(rc=$rc)"
  fi

  out=$(task tf:vars STACK="$s" VARS='__dev_tf_probe__:variables/__dev_tf_nothere__*.tfvars' 2>&1 1>/dev/null); rc=$?
  if [ "$rc" -eq 0 ]; then
    bad="$bad unmatched-glob-exited-0-FAILED-OPEN"
  fi

  if [ -n "$bad" ]; then
    fail "$label" "$bad"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------
# 9. VARS_IDS_PRESENT must exit 0 even when it prints nothing -- the only
# check that catches a dropped trailing `return 0`.
# ---------------------------------------------------------------------
check9() {
  local label="9 VARS_IDS_PRESENT exits 0 even printing nothing"
  local s
  s=$(list_stacks | sed -n '1p')
  if [ -z "$s" ]; then
    fail "$label" "no stack found to probe against"
    return
  fi
  local stack_dir map
  stack_dir=$(stack_dir_for "$s")
  map=$(task tf:vars:map 2>&1)

  local out rc
  out=$(bash "$SCRIPT" VARS_IDS_PRESENT "$stack_dir" "$map"); rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$label" "VARS_IDS_PRESENT STACK_DIR=$stack_dir exited $rc (want 0); output=[$out]"
    return
  fi

  # force the empty-output branch directly: a map whose only id can never
  # match a file must still exit 0 -- this is the exact shape a dropped
  # trailing `return 0` breaks (see tf-stack.sh source comment above it).
  out=$(bash "$SCRIPT" VARS_IDS_PRESENT "$stack_dir" '__dev_tf_probe__:variables/__dev_tf_nothere__*.tfvars'); rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$label" "VARS_IDS_PRESENT with an all-unmatched map exited $rc (want 0)"
    return
  fi
  if [ -n "$out" ]; then
    fail "$label" "VARS_IDS_PRESENT with an all-unmatched map printed [$out] (want nothing)"
    return
  fi

  pass "$label"
}

# ---------------------------------------------------------------------
# 10. round trip: tf:use writes <stack>.env; tf:vars reports SOURCE
# <stack>.env; git check-ignore passes; tf:use:clear removes it.
# ---------------------------------------------------------------------
check10() {
  local label="10 tf:use / tf:vars SOURCE / git check-ignore / tf:use:clear"
  if [ "$OFFLINE" -eq 1 ]; then
    skip "$label"
    return
  fi
  local picked s id
  picked=$(pick_stack_and_id)
  if [ -z "$picked" ]; then
    fail "$label" "no stack has a resolvable VARS id to probe with"
    return
  fi
  s=${picked% *}
  id=${picked#* }
  local env_file="$s.env"
  if [ -e "$env_file" ]; then
    fail "$label" "$env_file already exists; refusing to overwrite it for this check"
    return
  fi

  local use_out use_rc
  use_out=$(task tf:use STACK="$s" VARS="$id" 2>&1); use_rc=$?
  if [ "$use_rc" -ne 0 ]; then
    fail "$label" "tf:use STACK=$s VARS=$id exited $use_rc: $use_out"
    return
  fi
  if [ ! -f "$env_file" ]; then
    fail "$label" "tf:use did not write $env_file"
    return
  fi

  local vars_out source_val
  vars_out=$(task tf:vars STACK="$s" 2>&1)
  source_val=$(printf '%s\n' "$vars_out" | kv_value SOURCE)
  if [ "$source_val" != "$env_file" ]; then
    task tf:use:clear STACK="$s" >/dev/null 2>&1
    fail "$label" "tf:vars after tf:use reported SOURCE=[$source_val], want $env_file"
    return
  fi

  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if ! git check-ignore -q "$env_file"; then
      task tf:use:clear STACK="$s" >/dev/null 2>&1
      fail "$label" "$env_file is not gitignored"
      return
    fi
  fi

  local clear_out clear_rc
  clear_out=$(task tf:use:clear STACK="$s" 2>&1); clear_rc=$?
  if [ "$clear_rc" -ne 0 ] || [ -f "$env_file" ]; then
    fail "$label" "tf:use:clear STACK=$s exited $clear_rc; $env_file still present: $([ -f "$env_file" ] && echo yes || echo no)"
    return
  fi

  pass "$label"
}

# ---------------------------------------------------------------------
# 11. tf:fmt:check:all, then tf:validate:all. Can legitimately pass with
# zero iterations when stacks/ is empty -- said explicitly, not just
# reported as a bare PASS.
# ---------------------------------------------------------------------
check11() {
  local label="11 tf:fmt:check:all then tf:validate:all"
  if [ "$OFFLINE" -eq 1 ]; then
    skip "$label"
    return
  fi
  local fmt_out fmt_rc
  fmt_out=$(task tf:fmt:check:all 2>&1); fmt_rc=$?
  if [ "$fmt_rc" -ne 0 ]; then
    fail "$label" "tf:fmt:check:all exited $fmt_rc: $fmt_out"
    return
  fi
  local val_out val_rc
  val_out=$(task tf:validate:all 2>&1); val_rc=$?
  if [ "$val_rc" -ne 0 ]; then
    fail "$label" "tf:validate:all exited $val_rc: $val_out"
    return
  fi
  local iterations
  iterations=$(printf '%s\n' "$val_out" | grep -c '^== ')
  if [ "$iterations" -eq 0 ]; then
    printf 'PASS %s (0 iterations -- stacks/ is empty, nothing was actually validated)\n' "$label"
  else
    pass "$label"
  fi
}

# -- run -- #

check1
check2
check3
check4
check5
check6
check7
check8
check9
check10
check11

exit "$FAILED"
