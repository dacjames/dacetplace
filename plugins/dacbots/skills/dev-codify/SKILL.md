---
name: dev-codify
description: Codify throwaway scripts instead of inlining them. When you are about to write and run an inline script (bash -c, python -c, node -e, a heredoc piped into an interpreter, or an ad-hoc one-off file), stop and put the logic in a durable place instead — a task in the Taskfile, a committed script, or an updated existing script/test. Use when about to run inline code, when a one-off script would otherwise be thrown away, or when the user asks to codify/persist a script. Args: none.
user-invocable: true
allowed-tools:
  - Read
  - Edit
  - Write
  - Glob
  - Grep
  - Bash(ls *)
  - Bash(test *)
---

# /dev-codify — codify scripts instead of inlining them

Core rule: **if you would inline a script and run it, add or update a script
and/or a Taskfile task, then run that.** Inline programs are approved once and
thrown away; codified logic is reviewed once, reused, and survives edits without
re-prompting.

Behavioral counterpart to [`/dev-tasks`](../dev-tasks/SKILL.md) (scaffolds the
Taskfile) and [`/dev-permissions`](../dev-permissions/SKILL.md) (denies `python
-c` / `bash -c` / `node -e`). Those set the guardrails; this decides **where the
code goes** each time you reach for a script.

Arguments: none.

---

## When this fires

About to do any of these:

- `bash -c '...'`, `python -c '...'`, `python3 -c`, `node -e`/`-p`
- a heredoc piped into an interpreter (`cat <<EOF | python`)
- writing a temp/scratch file just to run it once and delete it
- re-pasting a multi-line pipeline you ran two turns ago

Stop. Route the logic to a durable home via the procedure below.

---

## Decision procedure

First match wins.

### 1. Does a similar task or script already exist?

**Prefer updating it.** Duplicating a similar script to keep each one simple is
fine; contorting one with flags/branches just to reuse it is not. Cheap
generalization yes, complexity-to-force-reuse no.

- New case for a smoke/e2e test → update the test.
- `deploy` task needs one more region → add the region.

### 2. What language?

- **bash** → step 3.
- **python / js / ts / anything else** → **always a file.** Never a `-c`/`-e`
  program. Write (or reuse) `scripts/foo.py` and call it — from a Taskfile task
  if one exists, else directly.

### 3. bash: inline in a task, or its own script?

- **Small (≈1–5 lines)** → **Taskfile task** with bash inlined in `cmds`. Default
  for bash.
- **Larger** → **script file** (`scripts/foo.sh`) called from a task. Keeps the
  Taskfile readable and the script independently runnable.

No Taskfile? Run [`/dev-tasks`](../dev-tasks/SKILL.md) to scaffold one, or drop
the script in `scripts/` and call it directly.

### 4. Last resort: temp location

Reusability is **consistently underestimated at write time** — exhaust 1–3
first. A "one-off" test usually belongs in the existing smoke test; a "one-off"
query usually belongs in a task.

If nothing durable fits, write to a **gitignored dir in the repo** (`tmp/` /
`wip/` / `scratch/`), never the system temp dir. Even a true one-off is approved
once and re-runs after edits — inline re-prompts every time.

---

## Placement summary

| Situation | Home |
|---|---|
| Similar task/script exists | Update it (dup over complexity) |
| bash, 1–5 lines | New Taskfile task, bash inline in `cmds` |
| bash, larger | `scripts/*.sh` called from a task |
| python / js / ts / other | `scripts/*.py` (etc.), never `-c`/`-e` |
| new test case | Extend the existing smoke/e2e test |
| nothing durable fits | Gitignored `tmp/`|`wip/` file, never system temp |

---

## Steps when invoked

1. **Identify** the inline script — language, size, purpose.
2. **Search** for an existing home — Glob/Grep `Taskfile.yml`, `scripts/`,
   `tmp/`, `wip/`, and test files for a match; prefer updating it.
3. **Route** per the procedure: update existing → task-inline bash → script file
   → gitignored temp.
4. **Write** it, then run **that** (task or file), not the inline form.
5. **Report** where it landed, how to re-run (`task <name>` or the path), and
   anything deferred for the user to confirm.

---

## Caveats to surface to the user

- **Duplication beats complexity, but not always.** Reuse when cheap; duplicate a
  simple script rather than adding branches that obscure it. Say which way you
  went.
- **Temp is the last resort, not the default.** Writing to `tmp/` for something
  that plausibly recurs (a test case, a data check) → it belongs in the existing
  test or a task.
- **Pairs with `/dev-permissions`.** With those rules, inline `-c`/`-e` is
  *denied* — codifying is the only path that runs without a prompt. Heredocs/pipes
  bypass the deny, so this convention is the real guard.
