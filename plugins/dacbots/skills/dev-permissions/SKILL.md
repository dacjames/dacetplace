---
name: dev-permissions
description: Configure secure auto-approval of dev-tool commands in .claude/settings.local.json. Detects the repo's toolchain and allowlists git/build/test/lint/file commands while gating history-rewriting and destructive ops. Use when the user wants fewer permission prompts for dev work, to grant a toolchain ruleset, or asks to set up safe auto-approval. Args: optional ruleset names (go, node, python, rust) to install on demand.
user-invocable: true
allowed-tools:
  - Read
  - Edit
  - Write
  - Bash(ls *)
  - Bash(test *)
---

# /dev-permissions — secure auto-approval for dev tools

Writes curated Claude Code permission rules to `.claude/settings.local.json` so
common dev-tool commands auto-approve, while history-rewriting and destructive
ops stay gated behind a prompt. Also writes a filesystem-navigation summary into
the project `CLAUDE.md`.

Arguments: `$ARGUMENTS` — optional space-separated ruleset names to install on
demand: `go`, `node`, `python`, `rust`. With no args, detect the toolchain from
repo manifests.

---

## How the permission model works (so you apply rules correctly)

- `permissions` in `.claude/settings.local.json` has three arrays: `allow`,
  `ask`, `deny`.
- Precedence is **deny → ask → allow**, first match wins. An `ask` rule
  therefore overrides a broad `allow` — that is how a broad `Bash(git:*)` allow
  coexists with a gated `Bash(git commit:*)` ask.
- Bash patterns match the **literal command string**: prefix plus `*` glob,
  where a space is a word boundary. `Bash(git:*)` ≡ `Bash(git *)`.
- **Matching is on command text, not resolved paths.** Path-scoped rules (the
  `.claude/worktrees/` and `cd` rules below) only fire when the command
  references that path literally.
- Built-in read-only commands (`ls cat grep find head tail wc which diff stat
  du`, read-only git) never prompt — do not allowlist them.

---

## Steps

### 1. Choose rulesets

- If `$ARGUMENTS` names one or more rulesets → install exactly those (plus
  **base**, always).
- Otherwise detect manifests at the repo root and map to rulesets:
  - `go.mod` → **go**
  - `package.json` → **node**
  - `pyproject.toml` / `requirements.txt` / `setup.py` → **python**
  - `Cargo.toml` → **rust**
  - `Taskfile.yml` / `Makefile` → covered by **base** (no extra ruleset)
- **base** is always included. Base carries the **scripting** rules (python /
  bash / node script execution) regardless of what manifests are detected —
  agents reach for these languages for ad-hoc scripts in any repo.
- Note which rulesets you chose and why (detected vs. requested).

### 1b. Resolve the temp/scratch dir (`<TMP>`)

Agents must run scripts from files (not inline), and those files need a home.
Detect a project scratch dir, preferring one inside the repo:

- Look for a **gitignored** folder named one of `tmp` / `temp` / `wip` /
  `scratch` / `.tmp` / `.scratch` — check `.gitignore` entries and existing
  dirs at the repo root.
- Use the first match (relative path, e.g. `tmp`).
- If none found, default to `tmp` as the project scratch dir and suggest the
  user gitignore it; or fall back to the system temp dir (`$TMPDIR` or `/tmp`)
  and scope the scripting rules to that **absolute** path instead.

Substitute the chosen dir for `<TMP>` in the scripting `allow` rules below.

### 2. Merge into `.claude/settings.local.json`

- Read the existing file if present. Create `.claude/` and the file if missing.
- Union the chosen rules into `permissions.allow` / `permissions.ask` /
  `permissions.deny`, **deduplicating** — never add a rule string that already
  exists.
- **Preserve every other key** in the file. Do not reorder or drop unrelated
  settings. Write valid JSON.
- This must be idempotent: running again adds nothing new.

### 3. Update `CLAUDE.md`

Insert or replace this exact block (between the markers). If the markers already
exist, replace the content between them; otherwise append the block to the end
of `CLAUDE.md`. Idempotent.

```markdown
<!-- dev-permissions:fs-nav -->
## Filesystem navigation

- Only `cd` to the project root or `.claude/worktrees/<worktree>`. Do **NOT**
  `cd` to any other directory.
- Instead of changing directories, use paths directly in filesystem commands:
  **relative** paths for locations inside the root, **absolute** paths for
  locations outside it.

## Running scripts

- Do **NOT** run inline programs (`python -c`, `bash -c`, `node -e`/`-p`) — they
  re-prompt on every edit and can't be approved once.
- Write the script to a file under the scratch dir (`<TMP>`), then run the file.
  Approved once, it re-runs after edits without re-prompting.
- Prefer a gitignored scratch dir in the repo over the system temp dir.
<!-- /dev-permissions:fs-nav -->
```

Substitute the resolved scratch dir for `<TMP>` when writing the block.

### 4. Report

Summarize: rulesets applied, count of allow/ask/deny rules added (vs. already
present), that the `CLAUDE.md` fs-nav section was written, and the two caveats
below.

---

## Rule sets

Apply the rule strings verbatim.

### base (always)

`allow`:
```
Bash(git:*)
Bash(make:*)
Bash(task:*)
Bash(just:*)
Bash(rg:*)
Bash(fd:*)
Bash(tree:*)
Bash(jq:*)
Bash(mkdir:*)
Bash(touch:*)
Bash(cp:*)
Bash(mv:*)
Bash(cd ./*)
Bash(cd .claude/worktrees/*)
Bash(rm -rf .claude/worktrees/*)
Bash(rm -r .claude/worktrees/*)
Bash(rm .claude/worktrees/*)
```

`ask` (gates — these override the broad `git`/`task` allow):
```
Bash(git commit:*)
Bash(git merge:*)
Bash(git rebase:*)
Bash(git cherry-pick:*)
Bash(git push --force*)
Bash(git reset --hard:*)
Bash(task ask:*)
```

`deny` (unambiguous `cd` escapes — no collision with legitimate project paths):
```
Bash(task deny:*)
Bash(cd ..)
Bash(cd ../*)
Bash(cd ~)
Bash(cd ~/*)
Bash(cd -)
Bash(cd $HOME*)
```

### scripting (always on, part of base)

Run scripts from files in the scratch dir, not inline. Substitute `<TMP>` with
the resolved scratch dir (see step 1b).

`allow`:
```
Bash(python <TMP>/*)
Bash(python3 <TMP>/*)
Bash(bash <TMP>/*)
Bash(sh <TMP>/*)
Bash(node <TMP>/*)
```

`deny` (block inline programs outright — force scripts into a temp file):
```
Bash(python -c:*)
Bash(python3 -c:*)
Bash(bash -c:*)
Bash(sh -c:*)
Bash(node -e:*)
Bash(node -p:*)
```

### go

`allow`:
```
Bash(go build:*)
Bash(go test:*)
Bash(go run:*)
Bash(go vet:*)
Bash(go get:*)
Bash(gofmt:*)
Bash(golangci-lint:*)
```

### node

`allow`:
```
Bash(npm run:*)
Bash(npm test:*)
Bash(npm ci:*)
Bash(npm install:*)
Bash(yarn:*)
Bash(pnpm:*)
Bash(npx:*)
Bash(tsc:*)
Bash(eslint:*)
Bash(prettier:*)
Bash(jest:*)
Bash(vitest:*)
```

### python

`allow`:
```
Bash(pytest:*)
Bash(python -m pytest:*)
Bash(ruff:*)
Bash(black:*)
Bash(mypy:*)
Bash(pip install:*)
Bash(uv:*)
Bash(poetry:*)
```

### rust

`allow`:
```
Bash(cargo build:*)
Bash(cargo test:*)
Bash(cargo check:*)
Bash(cargo run:*)
Bash(cargo clippy:*)
Bash(cargo fmt:*)
```

---

## Caveats to surface to the user

- **Worktree path matching is literal.** `Bash(rm -rf .claude/worktrees/*)` only
  auto-approves when the command uses that exact relative path. Absolute paths
  or `cd`-ing into the worktree first will not match — keep destructive fs ops
  expressed relative to the project root.
- **`cd` cannot be fully locked down by rules.** The permission model can't
  express "deny all `cd` except these" (deny is unconditional and can't be
  excepted by allow). A raw absolute `cd /some/path` outside the root will
  **prompt** rather than hard-deny. The `CLAUDE.md` fs-navigation rules are the
  primary guard; the deny patterns only catch the common relative escapes.
- **Inline scripts are denied.** `python -c` / `bash -c` / `node -e`/`-p` are
  hard-blocked — write the script to `<TMP>/` and run the file instead (that
  path auto-approves and survives edits). The deny can still be bypassed via
  heredocs or piping into the interpreter (`cat x | python`); the `CLAUDE.md`
  instruction is the real guard for those.
