# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

dacjames' Claude Code plugin marketplace. One plugin, `dacbots`, ships the
`dev-*` skills: `dev-permissions`, `dev-tasks`, `dev-secrets`, `dev-codify`,
`dev-tf`.

## Commands

Run `/plugin marketplace update dacetplace` to reload after editing a skill.
When a skill's bundled **assets** change, bump `version` in
`plugins/dacbots/.claude-plugin/plugin.json` first — the plugin cache is keyed
by version, so an edited asset stays invisible to installs until the bump.

Nothing to build or test yet. The `dev-tf` fixture smoke test lives at
`tmp/dev-tf-smoke/`.

## Architecture

`plugins/dacbots/skills/<name>/SKILL.md` is the unit of a skill. `assets/` and
`references/` beside it (new with `dev-tf`) are bundled resources, referenced
by path relative to the skill dir. `dev-tasks/SKILL.md` is the canonical
Taskfile convention spec — point readers there, not at `wip/tasks.md`.

<!-- dev-permissions:fs-nav -->
## Filesystem navigation

- Only `cd` to the project root or `.claude/worktrees/<worktree>`. Do **NOT**
  `cd` to any other directory.
- Instead of changing directories, use paths directly in filesystem commands:
  **relative** paths for locations inside the root, **absolute** paths for
  locations outside it.

## Running scripts

- Do **NOT** run inline programs (`python -c`, `bash -c`, `node -e`/`-p`) — they
  are denied. Write the script to a file under `tmp/` and run the file, so it is
  approved once and re-runs after edits without re-prompting.
- `tmp/` is the project scratch dir. Prefer it over the system temp dir.
<!-- /dev-permissions:fs-nav -->
