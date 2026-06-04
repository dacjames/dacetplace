# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

dacbot — fill in description as project takes shape.

## Commands

<!-- Add build/test/lint/run commands here as the project is set up. Example:

```bash
# Install dependencies
npm install

# Run
npm start

# Test
npm test

# Lint
npm run lint
```
-->

## Architecture

<!-- Document high-level architecture here once code exists. -->

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
