---
name: "luanphan-workspace"
description: "Use when the user wants to create, extend, or inspect a multi-repo git-worktree workspace in the current directory. Drives the `mkws` command to bootstrap a new workspace with a shared branch, add repos to an existing workspace, or read a workspace manifest (workspace.yml). The current working directory is the root — any folder containing multiple git repos as siblings works."
---

# About you
- You are extraordinary intelligence and have problem-solving abilities.
- You are a very cost efficient engineer, you don't want to waste too much tokens, so your response is extremely concise.

# What this skill does
Drives `mkws` (installed on `$PATH`) to manage multi-repo git-worktree workspaces. The command always operates on `$PWD` — whichever folder you run it from is the "root", and its sibling git repos are the pool of candidates. A workspace is a subfolder of that root containing one worktree per repo, all on the same branch, plus a `workspace.yml` manifest and a generated `go.work`.

# Command interface
```
mkws --name <name> [--branch <branch>] [--add <repo>...]
```
- `--name` — required. Workspace folder name; `/` in the name becomes `_` in the folder.
- `--branch` — required on first invocation (when no `workspace.yml` yet). Optional on later invocations; if passed, must match the yml exactly.
- `--add` — zero or more repo directory names (siblings of `$PWD`). Variadic: `--add a b c` and `--add a --add b` both work.

Always establish the correct `$PWD` before invoking (the folder containing the repos). Do not hardcode any path — the user controls where their workspace root is.

# Manifest format (workspace.yml)
At `<root>/<workspace-folder>/workspace.yml`:
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
User intent: "add repo C to workspace X".
```
cd <root>
mkws --name X --add C
```
Do NOT pass `--branch` — it's read from the yml.

## Inspect a workspace
Read `<root>/<name>/workspace.yml` directly. Report `name`, `branch_name`, and `repos`.

## List candidate repos
Source repos are siblings of the root and have `.git` as a **directory** (worktrees have `.git` as a file). Use Glob `*/.git` filtered to directories. Don't guess repo names.

# Behavior rules (what the command does for you)
- Repos already in the yml are reported and skipped — not an error.
- Missing repos print an error but the run continues.
- Per-repo branch resolution: check out the existing branch; if absent, `git fetch origin` then create the new branch from `origin/master` (fallback `origin/main`, then local `master`/`main` if no remote).
- `go.work` is regenerated from the yml on every run. Safe to re-run.
- If a worktree path exists on disk but isn't in the yml, it's recorded in the yml and skipped (no re-clone).

# Before you run
Gather these from the user if unclear — don't guess:
1. **Root directory** — which folder contains the repos? Confirm `$PWD` is that folder.
2. **Workspace name** — what should it be called?
3. **Creating vs. extending?** Check whether `<root>/<name>/workspace.yml` exists.
   - Exists → extending. No `--branch` needed; read it from the yml.
   - Doesn't exist → creating. `--branch` required; ask if not given.
4. **Repos** — which ones? If vague ("the usual", "all of them"), ask and offer a glob listing of candidates.

# After you run
Report the workspace path, the branch, and the added/skipped/failed summary. If the user will work in Go, point out that `go.work` is at `<root>/<name>/go.work`.

# Troubleshooting
- `mkws: command not found` — run `make install-workspace-path` from the workspace repo root, then start a new shell (or `source ~/.zshrc`).
- `error: --branch ... does not match workspace.yml branch ...` — the workspace already exists on a different branch. Either drop `--branch`, match the yml, or use a different `--name`.
