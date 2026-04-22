---
name: "luanphan-workspace"
description: "Use when the user wants to create, extend, sync, or inspect a multi-repo git-worktree workspace. Drives the `mkws` command to bootstrap a new workspace with a shared branch, add repos to an existing workspace (from either the root or from inside the workspace), run `go work sync` to sync Go module deps, or read a workspace manifest (workspace.yml). Works in any folder containing multiple git repos as siblings."
---

# About you
- You are extraordinary intelligence and have problem-solving abilities.
- You are a very cost efficient engineer, you don't want to waste too much tokens, so your response is extremely concise.

# What this skill does
Drives `mkws` (installed on `$PATH`) to manage multi-repo git-worktree workspaces. The command always operates on `$PWD` — whichever folder you run it from is the "root", and its sibling git repos are the pool of candidates. A workspace is a subfolder of that root containing one worktree per repo, all on the same branch, plus a `workspace.yml` manifest and a generated `go.work`.

# Command interface
```
mkws [--name <name>] [--branch <branch>] [--add <repo>...]
mkws sync [<folder>]
```
- `--name` — workspace folder name. Required when creating a new workspace or when invoked from the workspace root. **Optional when invoked from inside a workspace dir** (read from `workspace.yml`). `/` in the name becomes `_` in the folder.
- `--branch` — required on first invocation (when no `workspace.yml` yet). Optional on later invocations; if passed, must match the yml exactly.
- `--add` — zero or more repos. Each entry can be a **bare name** (looked up under the root), a **relative path** (resolved against `$PWD`, e.g. `../repo-a`), or an **absolute path**. The basename is used for the in-workspace folder name and the yml entry. Variadic: `--add a b c` and `--add a --add b` both work.
- `sync` — subcommand. Regenerates `go.work` from the yml and runs `go work sync`. Takes an optional positional **folder path** (relative or absolute); defaults to `$PWD`. The folder must contain a `workspace.yml`. Rejects `--add`, `--branch`, and `--name` — sync is purely path-based.

## Layout — all workspaces live under `lpworkspaces/`
Every workspace is placed at `<root>/lpworkspaces/<name>/` instead of directly under the root. This keeps the root folder clean even when many workspaces accumulate. `mkws` creates the `lpworkspaces/` container on demand.

## Context detection (important!)
`mkws` detects its context from `$PWD`:
- If `$PWD/workspace.yml` exists → `$PWD` **is** the workspace dir; root is its **grandparent** (because the workspace lives at `<root>/lpworkspaces/<name>/`). `--name` is optional.
- If `$PWD`'s basename is `lpworkspaces` → root is its parent. `--name` is required.
- Otherwise → `$PWD` is the **root**; workspace goes to `$PWD/lpworkspaces/<name>/`. `--name` is required.

This means `--add` can be run from the root, from the `lpworkspaces/` container, or from inside the workspace — `mkws` figures it out.

# Manifest format (workspace.yml)
At `<root>/lpworkspaces/<name>/workspace.yml`:
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
cd <root>/lpworkspaces/X
mkws --add C
```

Either way, do NOT pass `--branch` — it's read from the yml.

## Sync Go deps
User intent: "sync deps", "run go work sync", "pull module deps into the workspace". `mkws sync` is path-based:
```
# sync the workspace at $PWD (must be a workspace folder):
cd <root>/lpworkspaces/<name>
mkws sync

# sync a specific folder from anywhere (relative or absolute path):
mkws sync ./lpworkspaces/<name>
mkws sync /abs/path/to/<root>/lpworkspaces/<name>
```
All forms regenerate `go.work` from the yml and run `go work sync`. The target folder must contain a `workspace.yml`. Requires `go` on PATH.

## Inspect a workspace
Read `<root>/lpworkspaces/<name>/workspace.yml` directly. Report `name`, `branch_name`, and `repos`.

## List candidate repos
Source repos are siblings of the root and have `.git` as a **directory** (worktrees have `.git` as a file). Use Glob `*/.git` filtered to directories. Don't guess repo names.

# Behavior rules (what the command does for you)
- Repos already in the yml are reported and skipped — not an error.
- Missing repos print an error but the run continues.
- Per-repo branch resolution: check out the existing branch; if absent, `git fetch origin` then create the new branch from `origin/master` (fallback `origin/main`, then local `master`/`main` if no remote).
- `go.work` is regenerated from the yml on every run. Safe to re-run.
- If a worktree path exists on disk but isn't in the yml, it's recorded in the yml and skipped (no re-clone).
- `sync` and `--add` are separate operations. Adding repos does **not** auto-run `go work sync`; the user must call `mkws sync` explicitly when they want deps synced.

# Before you run
Gather these from the user if unclear — don't guess:
1. **Root directory** — which folder contains the repos? Confirm `$PWD` is that folder.
2. **Workspace name** — what should it be called?
3. **Creating vs. extending?** Check whether `<root>/lpworkspaces/<name>/workspace.yml` exists.
   - Exists → extending. No `--branch` needed; read it from the yml.
   - Doesn't exist → creating. `--branch` required; ask if not given.
4. **Repos** — which ones? If vague ("the usual", "all of them"), ask and offer a glob listing of candidates.

# After you run
Report the workspace path, the branch, and the added/skipped/failed summary. If the user will work in Go, point out that `go.work` is at `<root>/lpworkspaces/<name>/go.work`.

# Troubleshooting
- `mkws: command not found` — run `make install-workspace-path` from the workspace repo root, then start a new shell (or `source ~/.zshrc`).
- `error: --branch ... does not match workspace.yml branch ...` — the workspace already exists on a different branch. Either drop `--branch`, match the yml, or use a different `--name`.
