---
name: "local-workspace"
description: "Use when the user wants to create, extend, or inspect a multi-repo git-worktree workspace. Drives the `mkws` command to bootstrap a new workspace with a shared branch, add repos to an existing workspace (from either the root or from inside the workspace), or read a workspace manifest (workspace.yml). Works in any folder containing multiple git repos as siblings. Does not touch go.work — per-module semantics (GOWORK=off) is the default here; cross-module navigation uses `<leader>gw` worktree switching instead."
---

# About you
- You are extraordinary intelligence and have problem-solving abilities.
- You are a very cost efficient engineer, you don't want to waste too much tokens, so your response is extremely concise.

# What this skill does
Drives `mkws` (installed on `$PATH`) to manage multi-repo git-worktree workspaces. The command always operates on `$PWD` — whichever folder you run it from is the "root", and its sibling git repos are the pool of candidates. A workspace is a subfolder of that root containing one worktree per repo, all on the same branch, plus a `workspace.yml` manifest.

**Go note:** `mkws` does NOT create a `go.work`. Per-module semantics (`GOWORK=off`) is the standard; the `bin/go` wrapper and gopls `cmd_env` both force `GOWORK=off` so tests/diagnostics run against each module's own deps. For cross-module navigation, use `<leader>gw` to switch worktrees instead of stitching modules with `go.work`.

# Command interface
```
mkws [--name <name>] [--branch <branch>] [--add <repo>...]
mkws pull [<folder>...]
mkws push [<folder>...]
mkws master [<folder>...]
mkws rebase [<folder>...]
mkws sync [<folder>...]
mkws drop <folder>
```
- `--name` — workspace folder name. Required when creating a new workspace or when invoked from the workspace root. **Optional when invoked from inside a workspace dir** (read from `workspace.yml`). `/` in the name becomes `_` in the folder.
- `--branch` — required on first invocation (when no `workspace.yml` yet). Optional on later invocations; if passed, must match the yml exactly.
- `--add` — zero or more repos. Each entry can be a **bare name** (looked up under the root), a **relative path** (resolved against `$PWD`, e.g. `../repo-a`), or an **absolute path**. The basename is used for the in-workspace folder name and the yml entry. Variadic: `--add a b c` and `--add a --add b` both work.
- `pull` — subcommand. `git pull --ff-only` on the currently checked-out branch of every matching repo. Accepts **zero or more folder args** (absolute, relative, or a bare name under `$PWD`). Each arg is either a git repo (pulled directly) or a directory whose immediate git-repo subfolders are pulled. Results are deduped. Detached HEADs skipped. No args → iterate `$PWD`'s subfolders. Rejects `--add`, `--branch`, `--name`.
  Examples: `mkws pull`, `mkws pull repo-a`, `mkws pull repo-a repo-b`, `mkws pull ./local_workspaces/myws`, `mkws pull /abs/repo-a ./repo-b`.
- `push` — subcommand. `git push origin HEAD` on the current branch of every matching repo. Parallel. Detached HEAD is skipped. Non-ff / auth failures are reported in the summary but do not halt the batch. Same folder-args form as `pull`. Rejects `--add`, `--branch`, `--name`.
- `master` — subcommand. For every matching repo: `git clean -d -f`, optional `git checkout -- .` to discard local changes (only runs when dirty), switch to master (fallback main), and `git pull --ff-only`. **Destructive** to uncommitted work. Accepts the same folder-args form as `pull`. **BLOCKED when any target folder itself contains a `workspace.yml`** — running it in a workspace would wipe feature-branch state across the worktrees. Rejects `--add`, `--branch`, `--name`.
  Examples: `mkws master`, `mkws master repo-a repo-b`, `mkws master /abs/path/to/root`.
- `rebase` — subcommand. For every matching repo on a feature branch: stash dirty edits (`git stash push -u`), `git fetch origin <base>`, `git merge origin/<base>` into the current branch, pop the stash. Serial — conflicts need attention. On conflict: **HALTS** — leaves the merge + stash in place, prints resolve-and-finish instructions, skips remaining repos. Non-conflict failures trigger `git merge --abort` + stash-pop. Already-on-base / detached HEAD repos are skipped. Same folder-args form as `pull`.
- `sync` — subcommand. Composite: for every matching repo, `pull` the current branch → `rebase` onto master (skipped if already on `master`/`main`) → `push`. Serial. **Halts on rebase conflict** (same behavior as `mkws rebase`). Pull/push failures for one repo are recorded but don't halt — the run continues to the next repo. Same folder-args form as `pull`.
- `drop` — subcommand. **Destructive.** Removes every worktree listed in the manifest via `git worktree remove --force`, prunes the source repos, and deletes the workspace folder (and the empty `local_workspaces/` container if nothing else is left). Uncommitted work in the worktrees is lost. No confirmation prompt. Takes a required positional **folder path** (relative or absolute). Rejects `--add`, `--branch`, and `--name`.

## Layout — all workspaces live under `local_workspaces/`
Every workspace is placed at `<root>/local_workspaces/<name>/` instead of directly under the root. This keeps the root folder clean even when many workspaces accumulate. `mkws` creates the `local_workspaces/` container on demand.

## Context detection (important!)
`mkws` detects its context from `$PWD`:
- If `$PWD/workspace.yml` exists → `$PWD` **is** the workspace dir; root is its **grandparent** (because the workspace lives at `<root>/local_workspaces/<name>/`). `--name` is optional.
- If `$PWD`'s basename is `local_workspaces` → root is its parent. `--name` is required.
- Otherwise → `$PWD` is the **root**; workspace goes to `$PWD/local_workspaces/<name>/`. `--name` is required.

This means `--add` can be run from the root, from the `local_workspaces/` container, or from inside the workspace — `mkws` figures it out.

# Manifest format (workspace.yml)
At `<root>/local_workspaces/<name>/workspace.yml`:
```yaml
name: <workspace-name>
branch_name: <branch>
repos:
  - repo-a
  - repo-b
```

# Playbook

## Create a new workspace
User intent: "make a workspace called X with repos A, B on branch feature/Y".
Confirm the root (ask if unclear), then:
```
cd <root>
mkws --name X --branch feature/Y --add A B
```

## Add repos to an existing workspace
User intent: "add repo C to workspace X". Two equivalent ways:

From the root:
```
cd <root>
mkws --name X --add C
```

From inside the workspace (preferred if the user is already there):
```
cd <root>/local_workspaces/X
mkws --add C
```

Either way, do NOT pass `--branch` — it's read from the yml.

## Pull latest
User intent: "refresh the repos", "pull latest", "bring all worktrees up to date", "update all source repos to master". `mkws pull` walks the immediate subfolders and runs `git pull --ff-only` on each git repo it finds, using that repo's own currently checked-out branch.
```
# from the root: pulls every source repo on its branch
cd <root>
mkws pull

# inside a workspace: pulls every worktree on the shared feature branch
cd <root>/local_workspaces/<name>
mkws pull

# target any folder explicitly
mkws pull /abs/path/to/folder
```
Detached-HEAD repos are skipped with a warning. `--ff-only` means a diverged branch fails rather than silently merging.

## Reset source repos to master
User intent: "reset all repos to master", "clean everything and pull master", "fresh master state across the root". `mkws master` runs `git clean -d -f` + discard-local + `git checkout master` + `git pull --ff-only` on every git subfolder. **Destructive** — uncommitted work is lost.
```
cd <root>
mkws master
```
**Refuse** if the user asks to run this inside a workspace folder — the command is blocked and will error. Explain that workspaces hold feature-branch state per worktree, and they should `cd <root>` first (or use `mkws pull` which is branch-agnostic and safe inside a workspace).

## Drop a workspace
User intent: "drop workspace X", "delete the workspace", "clean up the worktrees for X", "we're done with this feature branch, wipe it". This is **destructive** — `mkws drop` removes every worktree in the manifest, prunes the source repos, and deletes the workspace folder.
```
mkws drop <root>/local_workspaces/<name>
mkws drop ./local_workspaces/<name>    # relative from the root
```
**Warn the user** before running if there may be uncommitted changes in the worktrees — `mkws drop` runs `git worktree remove --force` without a confirmation prompt, so local edits are lost. If unsure, ask the user to commit/push first (or inspect with `git -C <root>/<repo> worktree list`).

## Inspect a workspace
Read `<root>/local_workspaces/<name>/workspace.yml` directly. Report `name`, `branch_name`, and `repos`.

## List candidate repos
Source repos are siblings of the root and have `.git` as a **directory** (worktrees have `.git` as a file). Use Glob `*/.git` filtered to directories. Don't guess repo names.

# Behavior rules (what the command does for you)
- Repos already in the yml are reported and skipped — not an error.
- Missing repos print an error but the run continues.
- Per-repo branch resolution: check out the existing branch; if absent, `git fetch origin` then create the new branch from `origin/master` (fallback `origin/main`, then local `master`/`main` if no remote).
- If a worktree path exists on disk but isn't in the yml, it's recorded in the yml and skipped (no re-clone).
- `mkws` does NOT create a `go.work`. Per-module semantics is the norm (tests and gopls run with `GOWORK=off`); cross-module navigation happens via `<leader>gw` worktree switching.

# Before you run
Gather these from the user if unclear — don't guess:
1. **Root directory** — which folder contains the repos? Confirm `$PWD` is that folder.
2. **Workspace name** — what should it be called?
3. **Creating vs. extending?** Check whether `<root>/local_workspaces/<name>/workspace.yml` exists.
   - Exists → extending. No `--branch` needed; read it from the yml.
   - Doesn't exist → creating. `--branch` required; ask if not given.
4. **Repos** — which ones? If vague ("the usual", "all of them"), ask and offer a glob listing of candidates.

# After you run
Report the workspace path, the branch, and the added/skipped/failed summary.

# Troubleshooting
- `mkws: command not found` — run `make install-workspace-path` from the workspace repo root, then start a new shell (or `source ~/.zshrc`).
- `error: --branch ... does not match workspace.yml branch ...` — the workspace already exists on a different branch. Either drop `--branch`, match the yml, or use a different `--name`.
