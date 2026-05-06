# Claude instructions (this workspace)

This repo is the user's dotfiles / workspace tooling root: Neovim config, tmux, Alacritty, shared scripts under `bin/`, and reusable skills under `skills/`. Each subsystem has a Makefile target that installs it into the live location on the user's machine. The rule is: **edit in this repo, then run the matching Make target before considering the change complete** — otherwise the edit exists only in the repo, not in what the user actually uses.

## Neovim configuration

- Neovim config lives under `nvim/` in this repository. The `nvim-config` Makefile target copies it to `~/.config/nvim/` and runs Packer.
- After editing any file under `nvim/**/*.lua`, run from the repository root:

```bash
make nvim-config
```

## Skills

- Reusable skills live under `skills/<skill-name>/SKILL.md`. The `skills-sync` target copies the folder into `~/.claude/skills/`, `~/.cursor/skills/`, and `~/.agents/skills/`.
- After adding or editing anything under `skills/**`, run:

```bash
make skills-sync
```

## Shared scripts (bin)

- CLI helpers live under `bin/` (e.g. `mkws`). The `install-workspace` target copies `./bin/.` into `~/bin/` and ensures `export PATH="$HOME/bin:$PATH"` is in `~/.zshrc`.
- After adding or editing anything under `bin/**`, run:

```bash
make install-workspace
```

## Tmux / Alacritty

- Configs live under `tmux/` and `alacritty/`. Use `make tmux-config` or `make alacritty-config` after edits to install them.

## General

- Prefer editing in this repo, then running the install target — never edit the copies under `~/.config/`, `~/bin/`, or `~/.claude/skills/` directly, since they're overwritten on the next sync.
- `make help` lists every target with its description.
- This repo is supposed to be as generic as possible, since this is workspace and suppose to adapt to any companies any teams or any projects, for all development, avoid mentioning any company, team or project name, and avoid specific terms related to the tools, services, codebases, evironment variables or anything that the teams or the companies use.
