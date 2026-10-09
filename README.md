# workspace

- Shared shell tools, Git worktrees, Neovim, Neovide, Codex, and tmux.
- Components run independently and connect through workspace files, working directories, or client/server connections.

## Setup

```sh
make setup
exec zsh -l
make help
```

- **Tools:** Nix pins dependencies; the Makefile installs configurations and agent CLIs.
- **Skills:** Install separately with `make skills-sync`.
- **Configuration:** Edit files here, then run `make workspace-bin`, `make nvim-config`, `make neovide-config`, or `make tmux-config`.
- **Linux:** Run setup as your normal user. Fresh installations use single-user Nix and require a writable `/nix`. Reuse shared installations without changing ownership.
- **macOS:** Uses the Nix daemon installer.
- **Shell:** Setup keeps your login shell without administrator access. Run `exec zsh -l` to start the installed shell.

## Local workspaces

- Run [`mkws`](bin/mkws) from a folder containing sibling repositories to create one Git worktree per selected repository:

```sh
mkws --name example-a --branch example-branch-a --add repo-a repo-b
mkws --name example-b --branch example-branch-b --add repo-b repo-c@example-branch-c
```

```text
<root>/
├── repo-a/
├── repo-b/
├── repo-c/
└── local_workspaces/
    ├── example-a/
    │   ├── workspace.yml
    │   ├── tech_doc/
    │   ├── repo-a/    # example-branch-a
    │   └── repo-b/    # example-branch-a
    └── example-b/
        ├── workspace.yml
        ├── tech_doc/
        ├── repo-b/    # example-branch-b
        └── repo-c/    # example-branch-c
```

- Worktrees have separate working files and share history with their source repositories.
- `repo@branch` overrides the workspace's default branch for that repository.
- `workspace.yml` records branches and repositories; `tech_doc/` holds shared notes.
- `mkws resume` restores missing worktrees when the source repositories exist.
- **Neovim navigation:** Space is `<leader>`. Use `<leader>wp` for workspaces, `<leader>wr` for repositories, and `<leader>ww` for worktrees.

## Editor and agent

![Local editor and agent connections](docs/local-development.svg)

- **Neovide:** Provides the graphical UI for Neovim.
- **Neovim:** Runs [`mcodex`](bin/mcodex) in a terminal buffer scoped to the working directory.
- **mcodex:** Starts or reuses the managed Codex daemon and connects its terminal UI. Without arguments, it opens the resume picker.
- **Shared files:** The editor and agent work on the same saved files.
- **Agent view:** `<leader>;` toggles the view or sends a visual selection. Switching repositories preserves agent terminals.
- **Lifetime:** Hiding the view keeps its job running. Quitting the agent terminal disconnects its UI from the separate daemon.

## tmux as the glue

- Groups editors, agents, tests, and logs, keeping processes running across terminal disconnects.
- Run `nvim` and `mcodex` in separate panes, or use Neovide alongside them. New panes inherit the current directory.
- `Ctrl-b a` pins a session; `Ctrl-b A` toggles the sidebar.

## Remote development

![Remote development: local and remote component connections](docs/remote-development.svg)

```sh
# Remote machine, from the workspace directory:
tmux new-session -s example-workspace
neovide-server 6666

# Local machine:
neovide-client example-host:6666

# Separate local terminal, for browser and clipboard forwarding:
tunnel connect example-host
```

- **Editor:** The client attaches local Neovide over SSH to remote headless Neovim. Files and agent jobs stay remote.
- **Lifetime:** Disconnecting the GUI leaves the hosted editor available; quitting Neovim ends it. The Codex daemon runs separately.
- **Tunnel:** The separate [`tunnel`](bin/tunnel) connection opens remote URLs locally and transfers copied files or images to the remote machine.
