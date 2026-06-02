---
name: "local-workspace"
description: "Use when the user wants to create, extend, migrate, inspect, index, or open quick links for a multi-repo git-worktree workspace or workstation. Drives the `mkws` command to bootstrap a workspace with a default branch plus optional per-repo branch and base-branch overrides, add repos to an existing workspace, manage workspace links, build a workstation.yml repo index, or read a workspace manifest (workspace.yml). Works in any folder containing multiple git repos as siblings. Does not touch go.work — per-module semantics (GOWORK=off) is the default here; cross-module navigation uses `<leader>gw` worktree switching instead."
---

# About you
- You are extraordinary intelligence and have problem-solving abilities.
- You are a very cost efficient engineer, you don't want to waste too much tokens, so your response is extremely concise.

# What this skill does
Drives `mkws` (installed on `$PATH`) to manage multi-repo git-worktree workspaces and parent-folder workstation indexes. The command always operates on `$PWD` — whichever folder you run it from is the "root", and its sibling git repos are the pool of candidates. A workspace is a subfolder of that root containing one worktree per repo, a default branch plus optional per-repo branch and base-branch overrides, and a `workspace.yml` manifest. A workstation is the parent folder index recorded in `workstation.yml`.

**Go note:** `mkws` does NOT create a `go.work`. Per-module semantics (`GOWORK=off`) is the standard; the `bin/go` wrapper and gopls `cmd_env` both force `GOWORK=off` so tests/diagnostics run against each module's own deps. For cross-module navigation, use `<leader>gw` to switch worktrees instead of stitching modules with `go.work`.

# Command interface
```
mkws [--name <name>] [--branch <branch>] [--add <repo>...]
mkws [--name <workspace>] --link <name> <link> [<name> <link>...]
mkws index
mkws setup
mkws pull [<folder>...]
mkws push [<folder>...]
mkws master [<folder>...]
mkws rebase [<folder>...]
mkws merge <target> [<folder>...]
mkws sync [<folder>...]
mkws clean [<workspace-or-workstation-folder>]
mkws migrate [<workspace-folder>]
mkws sync_tech_doc
mkws open [<name-or-link>]
```
- `--name` — workspace folder name, or a path to an existing workspace directory that contains `workspace.yml`. Required when creating a new workspace or when invoked from the workspace root. **Optional when invoked from inside a workspace dir** (read from `workspace.yml`). Plain names create/use `<root>/local_workspaces/<name>`; path values target that workspace directly.
- `--branch` — default branch for repos that do not specify their own branch. **Required only when an added repo has no per-repo branch** (`--add repo-a`). **Optional** when every added repo uses `repo@branch`, when creating an empty workspace (no `--add`), or when extending an empty workspace with no repos. If the workspace already has a `branch_name` set, `--branch` is optional but, if passed, must match exactly. If the workspace was created empty (`branch_name:` in yml is empty) and you later pass `--branch`, the value is persisted into the yml. Once persisted, the existing-yml match-or-error rule kicks in.
- `--add` — zero or more repos. Each entry can be a **bare name** (looked up under the root), a **relative path** (resolved against `$PWD`, e.g. `../repo-a`), or an **absolute path**. Add `@<branch>` to any repo spec to override the default branch for that repo, e.g. `repo-a@feature/a`. The basename is used for the in-workspace folder name and the yml entry. Variadic: `--add a b c` and `--add a --add b` both work.
- `--link <name> <link> [<name> <link>...]` — add or update one or more quick-access workspace links in `workspace.yml`. Values are name/link pairs. Repeating `--link` also works. Run from inside a workspace dir/worktree, or pass `--name <workspace>` from the root. If an existing link URL is found, the latest provided name replaces the old name; if an existing name is found, its link is updated.
- `index` — subcommand. Builds or refreshes `<root>/workstation.yml` for the current parent folder. Scans immediate child git repos into top-level `repos`, scans immediate child git repos under `<root>/_external/` into `_external.repos`, and refreshes each repo's path, remote, upstream, and current branch metadata. It does not fetch, delete stale entries, or scan `local_workspaces/`. External repos are index-only context; they are not workspace worktrees.
- `setup` — subcommand. Reads `<root>/workstation.yml` and clones any recorded repo whose path is missing. Existing git repos are skipped; existing non-git paths fail. Uses `remote_url` and the recorded upstream branch when available. It does not fetch or pull existing repos.
- `clean` — subcommand. Context-aware cleanup. From a workstation root, removes stale repo metadata from `workstation.yml` when a recorded path is missing or no longer a git repo. From a workspace folder, removes code worktrees listed in `workspace.yml`, prunes source repos, keeps workspace-level files such as `tech_doc/`, preserves links, and resets `workspace.yml` to an empty branch/repo list. No confirmation prompt.
- `open` — subcommand. Opens a recorded workspace link in the default browser. With no query, lists all workspace links. Query can match the link name or URL exactly, or a unique substring. Run from inside a workspace dir/worktree, or pass `--name <workspace>`. Examples: `mkws open`, `mkws open design-doc`, `mkws open design-doc --name myws`.
- `pull` — subcommand. `git pull --ff-only` on the currently checked-out branch of every matching repo. Accepts **zero or more folder args** (absolute, relative, or a bare name under `$PWD`). Each arg is either a git repo (pulled directly) or a directory whose immediate git-repo subfolders are pulled. Results are deduped. Detached HEADs skipped. No args → iterate `$PWD`'s subfolders. Rejects `--add`, `--branch`, `--name`.
  Examples: `mkws pull`, `mkws pull repo-a`, `mkws pull repo-a repo-b`, `mkws pull ./local_workspaces/myws`, `mkws pull /abs/repo-a ./repo-b`.
- `push` — subcommand. `git push origin HEAD` on the current branch of every matching repo. Parallel. Detached HEAD is skipped. Non-ff / auth failures are reported in the summary but do not halt the batch. Same folder-args form as `pull`. Rejects `--add`, `--branch`, `--name`.
- `master` — subcommand. For every matching repo: `git clean -d -f`, optional `git checkout -- .` to discard local changes (only runs when dirty), switch to the detected default base branch, and `git pull --ff-only`. **Destructive** to uncommitted work. Accepts the same folder-args form as `pull`. **BLOCKED when any target folder itself contains a `workspace.yml`** — running it in a workspace would wipe feature-branch state across the worktrees. Rejects `--add`, `--branch`, `--name`.
  Examples: `mkws master`, `mkws master repo-a repo-b`, `mkws master /abs/path/to/root`.
- `rebase` — subcommand. For every matching repo on a feature branch: stash dirty edits (`git stash push -u`), merge the repo's configured `base_branch` (or default `main`/`master`) into the current branch, pop the stash. Serial — conflicts need attention. On conflict: **HALTS** — leaves the merge + stash in place, prints resolve-and-finish instructions, skips remaining repos. Non-conflict failures trigger `git merge --abort` + stash-pop. Already-on-base / detached HEAD repos are skipped. Same folder-args form as `pull`.
- `merge` — subcommand. **Bidirectional** merge driven by the required `<target>` argument:
  - **`mkws merge master`** (or `main`) — *Case B: integrate latest base INTO the feature branch*. For each worktree: use the repo's configured `base_branch` when present, otherwise `main`/`master`; stash dirty edits, pull `origin/<feature>` if it exists, merge the base into the feature branch, pop stash, `git push origin <feature>`. Halts on conflict (state left in place to resolve). **Replaces `mkws rebase`** with the added feature-pull and post-merge push.
  - **`mkws merge <workspace-name>`** — *Case A: land each repo branch INTO base, locally only*. Reads the workspace's manifest, then for each source sibling repo (`<root>/<repo>`, NOT the worktree): verifies it is on the configured `base_branch` or default `main`/`master` and clean, pulls the base if it exists on `origin`, then `git merge --no-ff <repo-branch>`. **NO push** — review the merge commits, then `git push origin <base>` per repo when satisfied. **Workspace is kept** for further work.
  - **Context-aware cwd** — both cases honor `$PWD`:
    - Run from the **root** (Case A) or **workspace dir** (Case B) → operates on every matching repo.
    - Run from inside a **single git repo** → auto-scopes to that one repo (the source repo for Case A, the worktree for Case B). Same scoping behavior as `pull` / `push` / `rebase`.
  - Both cases: serial, halt on conflict, optional folder args to further scope by repo name. Rejects `--add` / `--branch` / `--name`.
- `sync` — subcommand. Composite: for every matching repo, `pull` the current branch → merge the repo's configured `base_branch` (or default `main`/`master`) into the current branch → `push`. Serial. **Halts on merge conflict** (same behavior as `mkws rebase`). Pull/push failures for one repo are recorded but don't halt — the run continues to the next repo. Same folder-args form as `pull`.
- `migrate` — subcommand. Rewrites an existing `workspace.yml` into v2 format. Takes an optional workspace folder path; no arg means the current directory. Rejects `--add`, `--branch`, and `--name`.
- `sync_tech_doc` — subcommand. Builds a root-level tech-doc index by symlinking each workspace tech doc into `<root>/tech_doc/<workspace-name>/tech_doc`. Creates links for newly created workspace tech docs and removes stale generated symlinks for workspace tech docs that disappeared. It never deletes real files or real directories. Takes no args and rejects `--add`, `--branch`, and `--name`.

## Layout — all workspaces live under `local_workspaces/`
Every workspace is placed at `<root>/local_workspaces/<name>/` instead of directly under the root. This keeps the root folder clean even when many workspaces accumulate. `mkws` creates the `local_workspaces/` container on demand.

## Context detection (important!)
`mkws` detects its context from `$PWD`:
- If `$PWD/workspace.yml` exists → `$PWD` **is** the workspace dir; root is its **grandparent** (because the workspace lives at `<root>/local_workspaces/<name>/`). `--name` is optional.
- If `--name` is an absolute or relative path to a directory with `workspace.yml` → that directory is the workspace dir, and root is its grandparent.
- If `$PWD`'s basename is `local_workspaces` → root is its parent. `--name` is required.
- Otherwise → `$PWD` is the **root**; workspace goes to `$PWD/local_workspaces/<name>/`. `--name` is required.

This means `--add` can be run from the root, from the `local_workspaces/` container, or from inside the workspace — `mkws` figures it out.

# Manifest format (workspace.yml)
At `<root>/local_workspaces/<name>/workspace.yml`:
```yaml
version: v2
name: <workspace-name>
branch_name: <default-branch>
links:
  - name: design-doc
    link: https://example.com/design
repos:
  - name: repo-a
    branch_name: feature/a
    base_branch: release/a
  - name: repo-b
    branch_name: feature/b
```
`base_branch` is optional per repo. Omit it for normal default `main`/`master` behavior. Set it when a repo's feature branch should start from, sync with, or merge back into a different local or remote base branch.
The command can still read the older flat repo-list manifest. Run `mkws migrate [<workspace-folder>]` to rewrite it as v2.

# Workstation index format (workstation.yml)
At `<root>/workstation.yml`:
```yaml
version: v1
name: <workstation-name>
repos:
  - name: repo-a
    path: repo-a
    remote: origin
    remote_url: https://example.com/repo-a.git
    upstream: origin/main
    branch: main
_external:
  repos:
    - name: external-repo-a
      path: _external/external-repo-a
      remote: origin
      remote_url: https://example.com/external-repo-a.git
      upstream: origin/main
      branch: main
```
Run `mkws index` from the parent folder to create or refresh this file. Existing entries that are not currently present on disk are kept and reported as missing; they are not deleted automatically unless you run `mkws clean`. `_external.repos` is for read-only context used by exploration/design skills; `mkws setup` and workspace code operations use only top-level `repos`.

# Playbook

## Index a workstation
User intent: "index this parent folder", "refresh workstation.yml", "record every repo under this folder".
```
cd <root>
mkws index
```
The command scans immediate child git repos for top-level `repos`. It skips `local_workspaces/`, does not fetch from remotes, and does not remove stale entries.
If `<root>/_external/` exists, the command also scans its immediate child git repos and records them under `_external.repos`. These external entries support read-only exploration/design context only.

## Clean a workstation index
User intent: "remove stale repos from workstation.yml", "clean the workstation metadata", "repo folder was deleted, remove it from the index".
```
cd <root>
mkws clean
```
The command reads `<root>/workstation.yml` and removes entries whose recorded `path` is missing or no longer a git repo. It also applies the same stale-entry cleanup under `_external.repos`. It does not delete repo directories, fetch, pull, or add newly discovered repos; use `mkws index` for discovery.

## Set up a workstation from the index
User intent: "set up this workstation", "clone every missing repo from workstation.yml", "restore repos under this parent folder".
```
cd <root>
mkws setup
```
The command reads `<root>/workstation.yml`, clones entries whose `path` does not exist, skips paths that are already git repos, and fails on existing non-git paths. It uses `remote_url` plus the recorded upstream branch when available. It does not fetch or pull existing repos.

## Create a new workspace
User intent: "make a workspace called X with repos A, B on branch feature/Y".
Confirm the root (ask if unclear), then:
```
cd <root>
mkws --name X --branch feature/Y --add A B
```

## Create a workspace with per-repo branches
User intent: "make a workspace called X where repo A uses feature/A and repo B uses feature/B".
Confirm the root (ask if unclear), then:
```
cd <root>
mkws --name X --add A@feature/A B@feature/B
```
Use `--branch <default>` together with `repo@branch` when most repos share a branch and only some repos need overrides.

## Create an empty workspace (no repos yet, branch can wait)
User intent: "make an empty workspace called X — I'll add repos later". Useful when bootstrapping a tech-design folder before microservices are mapped in. Branch is optional here; you can set it later when you add the first repo.
```
cd <root>
mkws --name X                    # no --add, no --branch — empty workspace, blank branch
mkws --name X --branch feature/Y # later: persist the branch into the yml
```

## Add repos to an existing workspace
User intent: "add repo C to workspace X". Two equivalent ways:

From the root:
```
cd <root>
mkws --name X --add C
mkws --name <root>/local_workspaces/X --add C
```

From inside the workspace (preferred if the user is already there):
```
cd <root>/local_workspaces/X
mkws --add C
```

Either way, do NOT pass `--branch` when the workspace already has a default branch — it's read from the yml. To add one repo on a different branch, use `mkws --add C@feature/C`.

## Use a non-default base branch
User intent: "this repo's workspace branch should be based on another local or remote branch instead of main/master".
Create or edit the workspace manifest:
```yaml
repos:
  - name: repo-a
    branch_name: feature/a
    base_branch: release/a
```
Then run from the workspace:
```
mkws --add repo-a   # if missing, creates feature/a from release/a
mkws sync repo-a    # later, merges release/a into feature/a and pushes feature/a
```
Do not add `base_branch` for normal repos; default `main`/`master` behavior is implied.

## Migrate a workspace manifest to v2
User intent: "migrate this workspace.yml to the new format".
```
cd <root>/local_workspaces/X
mkws migrate

# or from elsewhere
mkws migrate <root>/local_workspaces/X
```
After migration, `repos` is a list of `{name, branch_name}` entries with optional `base_branch`. Existing flat repo entries inherit the top-level `branch_name`.

## Add and open workspace links
User intent: "add a quick link to this workspace", "open the design doc", "show workspace links".
```
cd <root>/local_workspaces/X
mkws --link design-doc https://example.com/design
mkws --link design-doc https://example.com/design runbook https://example.com/runbook
mkws --link design-doc https://example.com/design --link runbook https://example.com/runbook
mkws open                    # list links
mkws open design-doc         # open in default browser

cd <root>/local_workspaces/X/repo-a
mkws --link runbook https://example.com/runbook

# or from the root
cd <root>
mkws --name X --link design-doc https://example.com/design
mkws open design-doc --name X
```
Links are stored in `workspace.yml` under `links:` and are preserved by code-only operations such as `mkws clean`.

## Pull latest
User intent: "refresh the repos", "pull latest", "bring all worktrees up to date". `mkws pull` walks the immediate subfolders and runs `git pull --ff-only` on each git repo it finds, using that repo's own currently checked-out branch.
```
# from the root: pulls every source repo on its branch
cd <root>
mkws pull

# inside a workspace: pulls every worktree on its current branch
cd <root>/local_workspaces/<name>
mkws pull

# target any folder explicitly
mkws pull /abs/path/to/folder
```
Detached-HEAD repos are skipped with a warning. `--ff-only` means a diverged branch fails rather than silently merging.

## Reset source repos to the default base
User intent: "reset all repos to base", "clean everything and pull base", "fresh base state across the root". `mkws master` runs `git clean -d -f` + discard-local + checkout of the detected default base branch + `git pull --ff-only` on every git subfolder. **Destructive** — uncommitted work is lost.
```
cd <root>
mkws master
```
**Refuse** if the user asks to run this inside a workspace folder — the command is blocked and will error. Explain that workspaces hold feature-branch state per worktree, and they should `cd <root>` first (or use `mkws pull` which is branch-agnostic and safe inside a workspace).

## Land feature → base locally (per-repo, no push)
User intent: "merge my workspace branch back to base locally so I can review before pushing", "I don't want to push the feature branch to remote and merge there — just merge locally and push base myself".
```
cd <root>
mkws merge <workspace-name>            # all repos in the manifest
mkws merge <workspace-name> repo-a     # scope to one repo

# OR from inside a single source repo — auto-scopes to that repo only
cd <root>/repo-a
mkws merge <workspace-name>
```
Each source sibling repo (NOT the worktree) is pulled `--ff-only` on its configured `base_branch` or default `main`/`master`, then `git merge --no-ff <repo-branch>` is run. **No push** — review the merge, then `git push origin <base>` per repo. The workspace stays intact for further work; clean its code worktrees with `mkws clean` when fully done.

## Bring latest base into the feature branch + push
User intent: "merge base into my feature branch", "keep my workspace up to date with base and push the result". This replaces `mkws rebase` with auto-pull of the feature branch first and auto-push at the end. Repos with `base_branch` use that configured base instead of default `main`/`master`.
```
cd <root>/local_workspaces/<workspace-name>
mkws merge master           # or `mkws merge main`
mkws merge master repo-a    # scope to one worktree by name

# OR from inside a single worktree — auto-scopes to that worktree only
cd <root>/local_workspaces/<workspace-name>/repo-a
mkws merge master
```
Per worktree: stash → fetch or use local <base> → pull origin/<feature> if remote exists → merge --no-ff <base> → pop stash → push origin <feature>. Halts on conflict.

## Clean workspace code
User intent: "clean workspace X", "clean up the worktrees for X", "remove the code from this workspace", "we're done with this feature branch". This is **destructive for code worktrees** — `mkws clean` removes every worktree in the manifest and prunes the source repos, but keeps the workspace folder and workspace-level files such as `tech_doc/`.
```
mkws clean <root>/local_workspaces/<name>
mkws clean ./local_workspaces/<name>    # relative from the root
cd <root>/local_workspaces/<name> && mkws clean
```
After removing code worktrees, `mkws clean` rewrites `workspace.yml` with the same workspace name, blank `branch_name`, preserved `links:`, and an empty `repos:` list. Removing the workspace directory itself is a separate user decision.

**Warn the user** before running if there may be uncommitted changes in the worktrees — `mkws clean` runs `git worktree remove --force` without a confirmation prompt, so local edits inside code worktrees are lost. If unsure, ask the user to commit/push first (or inspect with `git -C <root>/<repo> worktree list`).

## Sync workspace tech docs
User intent: "preview all tech docs in one folder", "refresh the tech doc index", "link workspace tech docs into the root tech_doc folder".
```
cd <root>
mkws sync_tech_doc
```
The command scans `<root>/local_workspaces/*/workspace.yml`. For every workspace that has a `tech_doc/` folder, it creates or updates:
```
<root>/tech_doc/<workspace-name>/tech_doc -> <root>/local_workspaces/<workspace-name>/tech_doc
```
If a workspace `tech_doc/` folder is removed, the matching generated symlink is removed on the next run. If `<root>/tech_doc/<workspace-name>/tech_doc` already exists as a real file or directory, `mkws sync_tech_doc` warns and skips it rather than deleting user content.

## Inspect a workspace
Read `<root>/local_workspaces/<name>/workspace.yml` directly. Report `name`, default `branch_name`, quick links, and each repo's `name`, `branch_name`, and optional `base_branch`.

## List candidate repos
Source repos are siblings of the root and have `.git` as a **directory** (worktrees have `.git` as a file). Use Glob `*/.git` filtered to directories. Don't guess repo names.

# Behavior rules (what the command does for you)
- Repos already in the yml are reported and skipped — not an error.
- Missing repos print an error but the run continues.
- Per-repo branch resolution: the branch is the repo's v2 `branch_name` if present, otherwise the top-level default `branch_name`. `git fetch origin` first; if a same-named local branch exists, check it out and set it to track `origin/<branch>` when that remote branch exists. If no local branch exists but `origin/<branch>` does, create a local tracking branch from it. If no same-named remote branch exists, create the branch from the repo's configured `base_branch` when present, otherwise default `main`/`master`.
- If a worktree path exists on disk but isn't in the yml, it's recorded in the yml and skipped (no re-clone).
- `mkws` does NOT create a `go.work`. Per-module semantics is the norm (tests and gopls run with `GOWORK=off`); cross-module navigation happens via `<leader>gw` worktree switching.

# Before you run
Gather these from the user if unclear — don't guess:
1. **Root directory** — which folder contains the repos? Confirm `$PWD` is that folder.
2. **Workspace name** — what should it be called?
3. **Creating vs. extending?** Check whether `<root>/local_workspaces/<name>/workspace.yml` exists.
   - Exists with `branch_name` set → extending. No `--branch` needed for repos using the default branch; use `repo@branch` for per-repo overrides.
   - Exists but `branch_name` is empty → workspace was bootstrapped empty. `--branch` is required only for added repos that do not use `repo@branch`; otherwise still optional.
   - Doesn't exist → creating. `--branch` required ONLY if any `--add` repo lacks `@branch`. For an empty workspace (no `--add`), `--branch` is optional and can be filled in later.
4. **Repos** — which ones? If vague ("the usual", "all of them"), ask and offer a glob listing of candidates.

# After you run
Report the workspace path, the default branch, any per-repo branch/base overrides that matter, and the added/skipped/failed summary.

# Troubleshooting
- `mkws: command not found` — run `make install-workspace-path` from the workspace repo root, then start a new shell (or `source ~/.zshrc`).
- `error: --branch ... does not match workspace.yml branch ...` — the workspace already exists on a different branch. Either omit `--branch`, match the yml, or use a different `--name`.
