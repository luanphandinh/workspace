---
name: "local-workspace"
description: "Use when the user wants to create, extend, migrate, inspect, or open quick links for a multi-repo git-worktree workspace, index/setup parent-folder workstation metadata through meta-hub, discover workstation manifests, or sync workstation/workspace metadata to a git repository. Drives `mkws` for workspace operations and `meta-hub` for metadata repository sync. Works in any folder containing multiple git repos as siblings. Does not touch go.work — per-module semantics (GOWORK=off) is the default here; cross-module navigation uses `<leader>gw` worktree switching instead."
---

# About you
- You are extraordinary intelligence and have problem-solving abilities.
- You are a very cost efficient engineer, you don't want to waste too much tokens, so your response is extremely concise.

# What this skill does
Drives `mkws` and `meta-hub` (installed on `$PATH`). `mkws` manages multi-repo git-worktree workspaces. `meta-hub` stores workstation metadata in a metadata git repository, keeps the canonical `workstation.yml` files under `~/.meta-hub/<metadata-repo>/`, and restores missing workstation source repos from that metadata. These commands operate on `$PWD` unless a supported folder argument is passed. A workspace is a subfolder of the root containing one worktree per repo, a default branch plus optional per-repo branch and base-branch overrides, glued together by `workspace.yml`, and a `tech_doc/` folder initialized as its own git repo. Workspace creation and workspace worktree management remain `mkws` responsibilities.

**Go note:** `mkws` does NOT create a `go.work`. Per-module semantics (`GOWORK=off`) is the standard; the `bin/go` wrapper and gopls `cmd_env` both force `GOWORK=off` so tests/diagnostics run against each module's own deps. For cross-module navigation, use `<leader>gw` to switch worktrees instead of stitching modules with `go.work`.

# Command interface
```
mkws [--name <name>] [--branch <branch>] [--add <repo>...]
mkws [--name <workspace>] --link <name> <link> [<name> <link>...]
mkws pull [<folder>...]
mkws push [<folder>...]
mkws merge <target> [<folder>...]
mkws sync [--push] [<folder>...]
mkws clean [<workspace-folder>]
mkws migrate [<workspace-folder>]
mkws skill-sync
mkws open [<name-or-link>]
meta-hub -f <folder> -r <git-repository>
meta-hub -r <git-repository>
meta-hub index
meta-hub index -p <workstation-folder>
meta-hub sync [pick]
meta-hub sync_tech_doc [pick]
meta-hub push [pick]
meta-hub project
meta-hub p
meta-hub repo
meta-hub r
```
- `--name` — workspace folder name, or a path to an existing workspace directory that contains `workspace.yml`. Required when creating a new workspace or when invoked from the workspace root. **Optional when invoked from inside a workspace dir** (read from `workspace.yml`). Plain names create/use `<root>/local_workspaces/<name>`; path values target that workspace directly.
- `--branch` — default branch for repos that do not specify their own branch. **Required only when an added repo has no per-repo branch** (`--add repo-a`). **Optional** when every added repo uses `repo@branch`, when creating an empty workspace (no `--add`), or when extending an empty workspace with no repos. If the workspace already has a `branch_name` set and `--add` is present, a different `--branch` applies only to the newly added repo(s) and does not change the workspace default branch. If the workspace already has a `branch_name` set and `--add` is absent, a different `--branch` is rejected. If the workspace was created empty (`branch_name:` in yml is empty) and you later pass `--branch`, the value is persisted into the yml.
- `--add` — zero or more repos. Each entry can be a **bare name** (looked up under the root), a **relative path** (resolved against `$PWD`, e.g. `../repo-a`), or an **absolute path**. Add `@<branch>` to any repo spec to override the default branch for that repo, e.g. `repo-a@feature/a`. The basename is used for the in-workspace folder name and the yml entry. Variadic: `--add a b c` and `--add a --add b` both work.
- `--link <name> <link> [<name> <link>...]` — add or update one or more quick-access workspace links in `workspace.yml`. Values are name/link pairs. Repeating `--link` also works. Run from inside a workspace dir/worktree, or pass `--name <workspace>` from the root. If an existing link URL is found, the latest provided name replaces the old name; if an existing name is found, its link is updated.
- `mkws clean` — removes code worktrees listed in `workspace.yml`, prunes source repos, keeps workspace-level files such as `tech_doc/`, preserves links, and resets `workspace.yml` to an empty branch/repo list. No confirmation prompt.
- `meta-hub -f <folder> -r <git-repository>` — registers a metadata source root and metadata git repository. `-f` defaults to the current folder. The command clones the repository under `~/.meta-hub/<git-repo>` and stores the local root/clone mapping in `~/.meta-hub/info.yml`. The remote is read from the clone's Git config.
- `meta-hub index` — pulls each metadata repository first, reads its `registry.yml`, resolves each listed workstation path under the registered local root, and refreshes metadata for every listed workstation folder that exists locally. It prints per-workstation repo status (`added`, `updated`, `already indexed`, missing upstream warnings), indexed metadata paths (`workstation.yml` plus every copied `local_workspaces/*/workspace.yml`), and resolved metadata conflict paths. It does not write `workstation.yml` into local workstation folders.
- `meta-hub index -p <workstation-folder>` — targeted form. Pulls the metadata repository first, rejects the workstation folder unless it is under a registered root from `~/.meta-hub/info.yml`, scans immediate source repos in that workstation folder, prints per-repo status and indexed metadata paths, writes `<metadata-repo>/<relative-workstation-path>/workstation.yml`, updates `<metadata-repo>/registry.yml`, copies existing workspace manifests for jump metadata, syncs optional home-scoped metadata, and commits changed metadata with `sync from <machineusername>@<machinename>`.
- `meta-hub sync [pick]` — from any folder, pulls each metadata repository first, resolves supported metadata conflicts, reads `<metadata-repo>/registry.yml`, creates missing local workstation folders under each registered root, and clones missing workstation source repos from `<metadata-repo>/<relative-workstation-path>/workstation.yml`. It creates missing `local_workspaces/<workspace>` directories for indexed workspaces but does not write local `workstation.yml`, does not write local `workspace.yml`, and does not create workspace worktrees. With `pick`, choose one registered mapping through `fzf`; without it, sync all.
- `meta-hub sync_tech_doc [pick]` — from any folder, reads indexed workstations from the metadata repository, then mirrors local workspace tech docs into each workstation's `tech_doc/<workspace-name>/tech_doc` symlink index. With `pick`, choose one registered mapping through `fzf`; without it, sync all.
- `meta-hub push [pick]` — pushes registered metadata repositories explicitly to `main` or `master`. With `pick`, choose one registered mapping through `fzf`; without it, push all.
- `meta-hub project` / `meta-hub p` — from any folder, lists every registered workstation workspace folder under `local_workspaces/` in `fzf`, then changes the current shell to the selected workspace folder. This shell jump works through `~/bin/shell/workspace.sh`; direct executable use prints the selected path.
- `meta-hub repo` / `meta-hub r` — from any folder, lists registered workstation source repos plus git repos directly under registered `local_workspaces/<workspace>/` folders in `fzf`, then changes the current shell to the selected repo. This shell jump works through `~/bin/shell/workspace.sh`; direct executable use prints the selected path.
- `open` — subcommand. Opens a recorded workspace link in the default browser. With no query, lists all workspace links. Query can match the link name or URL exactly, or a unique substring. Run from inside a workspace dir/worktree, or pass `--name <workspace>`. Examples: `mkws open`, `mkws open design-doc`, `mkws open design-doc --name myws`.
- `pull` — subcommand. `git pull --ff-only` on the currently checked-out branch of every matching repo. Accepts **zero or more folder args** (absolute, relative, or a bare name under `$PWD`). Each arg is either a git repo (pulled directly) or a directory whose immediate git-repo subfolders are pulled. Results are deduped. Detached HEADs skipped. No args → iterate `$PWD`'s subfolders and immediate git repos under `$PWD/_external/` when present. External repos are pulled in parallel and reported separately, but remain read-only context for workspace creation/coding. Rejects `--add`, `--branch`, `--name`.
  Examples: `mkws pull`, `mkws pull repo-a`, `mkws pull repo-a repo-b`, `mkws pull _external`, `mkws pull ./local_workspaces/myws`, `mkws pull /abs/repo-a ./repo-b`.
- `push` — subcommand. `git push origin HEAD` on the current branch of every matching repo. Parallel. Detached HEAD is skipped. Non-ff / auth failures are reported in the summary but do not halt the batch. Same folder-args form as `pull`. Rejects `--add`, `--branch`, `--name`.
- `merge` — subcommand. **Bidirectional** merge driven by the required `<target>` argument:
  - **`mkws merge master`** (or `main`) — *Case B: integrate latest base INTO the feature branch*. For each worktree: use the repo's configured `base_branch` when present, otherwise `main`/`master`; stash dirty edits, pull `origin/<feature>` if it exists, merge the base into the feature branch, pop stash, `git push origin <feature>`. Halts on conflict (state left in place to resolve).
  - **`mkws merge <workspace-name>`** — *Case A: land each repo branch INTO base, locally only*. Reads the workspace's manifest, then for each source sibling repo (`<root>/<repo>`, NOT the worktree): verifies it is on the configured `base_branch` or default `main`/`master` and clean, pulls the base if it exists on `origin`, then `git merge --no-ff <repo-branch>`. **NO push** — review the merge commits, then `git push origin <base>` per repo when satisfied. **Workspace is kept** for further work.
  - **Context-aware cwd** — both cases honor `$PWD`:
    - Run from the **root** (Case A) or **workspace dir** (Case B) → operates on every matching repo.
    - Run from inside a **single git repo** → auto-scopes to that one repo (the source repo for Case A, the worktree for Case B). Same scoping behavior as `pull` / `push` / `sync`.
  - Both cases: serial, halt on conflict, optional folder args to further scope by repo name. Rejects `--add` / `--branch` / `--name`.
- `sync` — subcommand. Composite: for every matching repo, `pull` the current branch → merge the repo's configured `base_branch` (or default `main`/`master`) into the current branch. With `--push`, also push the current branch to the remote after the base merge. Serial. **Halts on merge conflict**. Pull/push failures for one repo are recorded but don't halt — the run continues to the next repo. Same folder-args form as `pull`.
- `migrate` — subcommand. Rewrites an existing `workspace.yml` into v2 format. Takes an optional workspace folder path; no arg means the current directory. Rejects `--add`, `--branch`, and `--name`.
- `skill-sync` — subcommand. Copies workspace-scoped skills from `<workspace>/skills/<skill-name>/` into project-local agent skill folders for service repos: `.agent/skills/`, `.claude/skills/`, and `.cursor/skills/`. Run from the workspace root to sync every repo listed in `workspace.yml`; run from inside a service repo under that workspace to sync only that repo. It overwrites same-named copied skill folders and leaves unrelated target skills alone. Takes no args and rejects `--add`, `--branch`, `--name`, and `--link`.

## Layout — all workspaces live under `local_workspaces/`
Every workspace is placed at `<root>/local_workspaces/<name>/` instead of directly under the root. This keeps the root folder clean even when many workspaces accumulate. `mkws` creates the `local_workspaces/` container on demand and initializes `<workspace>/tech_doc/` as a standalone git repo for technical-design milestone commits.

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
`meta-hub index -p <workstation-folder>` creates or refreshes this file inside the metadata repository. Existing entries that are not currently present on disk are kept and reported as missing. `_external.repos` is for read-only context used by exploration/design skills; `meta-hub sync` uses only top-level `repos`.

# Local metadata info format
At `~/.meta-hub/info.yml`:
```yaml
version: v3
roots:
  - path: "/absolute/path/to/source-root"
    clone: "/home/user/.meta-hub/example-repo"
```
The local info file maps source roots to metadata repository clones and keeps machine-local absolute paths out of the synced metadata repo. The remote URL is not stored here; it is read from each clone's Git config. The metadata repository stores its portable workstation list in `registry.yml`:
```yaml
version: v2
remote: "git@example.com:example-repo.git"
workstations:
  - name: <workstation-name>
    root: <relative-path-to-workstation-root>
    manifest: <relative-path-to-workstation-root>/workstation.yml
```
The metadata repository also stores each listed `workstation.yml`, existing `local_workspaces/<workspace-name>/workspace.yml` files for jump metadata, and optional home-scoped metadata at `.skills-hub/execute_plugins` and `.cmds-hub/cmd_history`. Local workstation folders do not need a local `workstation.yml` when using the `meta-hub` flow.

# Playbook

## Register metadata sync
User intent: "sync this workstation metadata to a git repo", "remember this metadata repo", "set up metadata sync".
```
cd <root>
meta-hub -f . -r <git-repository>

# equivalent when already in the source root
meta-hub -r <git-repository>
```
The command validates the folder, validates the repository with git, clones it under `~/.meta-hub/<git-repo>`, and records the local root and clone path in `~/.meta-hub/info.yml`.

## Index workstation metadata
User intent: "index this workstation into meta-hub", "copy workstation, workspace, skill hub, and command history metadata to the metadata repo".
```
meta-hub index -p <workstation-folder>
meta-hub index  # refresh every locally present workstation already listed in registry.yml
```
The targeted workstation folder must be under a root registered in `~/.meta-hub/info.yml`. Both forms pull `origin/main` or `origin/master` first, resolve supported metadata conflicts, scan immediate source repos in each workstation folder, report per-repo index status, list the metadata `workstation.yml` plus every copied `local_workspaces/*/workspace.yml`, write the metadata clone's `registry.yml` and `<relative-workstation-path>/workstation.yml`, copy existing workspace manifests for jump metadata, preserve remote-only metadata, and commit if anything changed. When a supported YAML or line-based metadata conflict is merged, the command prints the resolved relative metadata path. Bare `meta-hub index` uses the metadata clone's existing `registry.yml` to decide which local workstation folders to refresh; use `-p` when adding a new workstation path to `registry.yml`. Neither form creates or updates local `workstation.yml`.

## Sync workstation setup
User intent: "set up this machine from meta-hub", "clone missing workstation repos from metadata".
```
meta-hub sync       # all registered metadata repos
meta-hub sync pick  # choose one with fzf
```
The command can run from any folder. For each selected entry, it pulls `origin/main` or `origin/master` first, resolves supported metadata conflicts, reads the metadata clone's `registry.yml`, creates missing local workstation folders under the registered root, and clones missing source repos recorded in each metadata `workstation.yml`. It skips existing git repos and fails on existing non-git repo paths. Workspace-level worktrees remain managed by `mkws`; `meta-hub sync` only creates missing `local_workspaces/<workspace>` directories for indexed workspaces and leaves local `workspace.yml` files absent.

## Sync workspace tech docs
User intent: "preview all tech docs per workstation", "refresh the tech doc index", "link every workspace tech doc under each workstation".
```
meta-hub sync_tech_doc       # all registered source roots
meta-hub sync_tech_doc pick  # choose one with fzf
```
The command can run from any folder. For each indexed workstation in the metadata repository, it processes local workspaces that already exist on disk. For every workspace in a workstation that has a `tech_doc/` folder, it creates or updates:
```
<workstation-root>/tech_doc/<workspace-name>/tech_doc -> <workstation-root>/local_workspaces/<workspace-name>/tech_doc
```
If a workspace `tech_doc/` folder is removed, the matching generated symlink is removed on the next run. Real files and real directories are never deleted.

## Jump to a workspace or repo
User intent: "jump to a project", "open a workspace folder", "jump to a repo from anywhere".
```
meta-hub project  # or: meta-hub p
meta-hub repo     # or: meta-hub r
```
Both commands can run from any folder. They read `~/.meta-hub/info.yml`, the synced `registry.yml`, and metadata files inside each metadata clone, then build `fzf` choices from indexed workstations. They do not run workstation discovery on each jump, so they stay fast; run `meta-hub index -p <workstation-folder>` when workstation metadata changes and `meta-hub sync` when local workstation folders or repos need restoration. `meta-hub project` includes existing local workspace folders under `local_workspaces/`. `meta-hub repo` includes existing workstation source repos and git repos directly under existing workspace folders, including workspace worktrees. The interactive `cd` requires the shell setup installed by `make workspace-bin`; running the executable directly prints the selected absolute path.

## Push metadata
User intent: "push metadata", "send metadata repo changes to remote".
```
meta-hub push
meta-hub push pick
```
`push` can run from any folder. If `~/.meta-hub/info.yml` is missing but an older local `~/.meta-hub/registry.yml` or `~/.meta-sync/registry.yml` exists, `meta-hub` migrates it into `~/.meta-hub/info.yml` on first use. Pulling and conflict resolution are part of `meta-hub index` and `meta-hub sync`; supported YAML metadata conflicts are resolved by unioning manifest entries, and conflicts in `.skills-hub/execute_plugins` and `.cmds-hub/cmd_history` are resolved by unioning lines. Unsupported conflicts are left for manual resolution. `push` sends the current metadata commit to `main` or `master` explicitly, so first pushes to empty metadata repositories do not depend on local git upstream configuration.

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
The workspace includes `<root>/local_workspaces/X/tech_doc/`, already initialized with `git init`.

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

Either way, omit `--branch` to use the workspace default branch. To add repo(s) on a different branch, use either `mkws --add C@feature/C` or `mkws --add C --branch feature/C`; this records only the added repo(s) on the override branch and keeps the workspace default branch unchanged.

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
mkws sync repo-a    # later, merges release/a into feature/a locally
mkws sync --push repo-a
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
User intent: "refresh the repos", "pull latest", "bring all worktrees up to date". `mkws pull` walks the immediate subfolders and runs `git pull --ff-only` on each git repo it finds, using that repo's own currently checked-out branch. From a workstation root, no-arg `mkws pull` also includes immediate git repos under `_external/` and reports the external result count separately.
```
# from the root: pulls every source repo plus _external repos on their branches
cd <root>
mkws pull

# inside a workspace: pulls every worktree on its current branch
cd <root>/local_workspaces/<name>
mkws pull

# target any folder explicitly
mkws pull /abs/path/to/folder
```
Detached-HEAD repos are skipped with a warning. `--ff-only` means a diverged branch fails rather than silently merging.

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

## Sync feature branches with latest base
User intent: "merge base into my feature branch", "keep my workspace up to date with base", "push my synced feature branch". Repos with `base_branch` use that configured base instead of default `main`/`master`.
```
cd <root>/local_workspaces/<workspace-name>
mkws sync                   # pull current branch + merge base locally
mkws sync --push            # also push current branch to remote
mkws sync repo-a            # scope to one worktree by name

# OR from inside a single worktree — auto-scopes to that worktree only
cd <root>/local_workspaces/<workspace-name>/repo-a
mkws sync --push
```
Per worktree: pull `origin/<current-branch>` when that remote branch exists, stash dirty edits, fetch or use local `<base>`, merge `<base>` into the current branch, pop stash, and optionally push when `--push` is present. Halts on conflict.

## Clean workspace code
User intent: "clean workspace X", "clean up the worktrees for X", "remove the code from this workspace", "we're done with this feature branch". This is **destructive for code worktrees** — `mkws clean` removes every worktree in the manifest and prunes the source repos, but keeps the workspace folder and workspace-level files such as `tech_doc/`.
```
mkws clean <root>/local_workspaces/<name>
mkws clean ./local_workspaces/<name>    # relative from the root
cd <root>/local_workspaces/<name> && mkws clean
```
After removing code worktrees, `mkws clean` rewrites `workspace.yml` with the same workspace name, blank `branch_name`, preserved `links:`, and an empty `repos:` list. Removing the workspace directory itself is a separate user decision.

**Warn the user** before running if there may be uncommitted changes in the worktrees — `mkws clean` runs `git worktree remove --force` without a confirmation prompt, so local edits inside code worktrees are lost. If unsure, ask the user to commit/push first (or inspect with `git -C <root>/<repo> worktree list`).

## Sync workspace skills to service repos
User intent: "sync workspace skills into each service repo", "copy this workspace's skills for Codex and Claude Code", "refresh project-local skills".
```
cd <root>/local_workspaces/<workspace-name>
mkws skill-sync
```
The command copies each skill directory with a `SKILL.md` from:
```
<root>/local_workspaces/<workspace-name>/skills/<skill-name>/
```
into every repo listed in that workspace manifest:
```
<repo>/.agent/skills/<skill-name>/
<repo>/.claude/skills/<skill-name>/
<repo>/.cursor/skills/<skill-name>/
```
When run from inside one service repo under the workspace, including a nested subdirectory, only that repo is synced:
```
cd <root>/local_workspaces/<workspace-name>/<repo-a>
mkws skill-sync
```
The command overwrites same-named copied skill folders in the agent targets and leaves unrelated target skills alone. It does not edit global agent skill directories.

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
- `mkws: command not found` or `meta-hub: command not found` — run `make workspace-bin` from this repo root, then start a new shell (or `source ~/.zshrc`).
- `error: --branch ... does not match workspace.yml branch ...` — the workspace already exists on a different branch and you passed `--branch` without `--add`. Either omit `--branch`, match the yml, use `--add` to apply the branch to new repo(s), or use a different `--name`.
