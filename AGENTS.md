# Agent instructions (this workspace)

This repo is the user's dotfiles / workspace tooling root: Neovim config, tmux, Alacritty, shared scripts under `bin/`, and reusable skills under `skills/`. Each subsystem has a Makefile target that installs it into the live location on the user's machine. The rule is: **edit in this repo, then run the matching Make target before considering the change complete** — otherwise the edit exists only in the repo, not in what the user actually uses.

## Generic workspace rule

- This repo must stay generic because it is workspace tooling meant to adapt to any company, team, or project.
- Do not mention company names, team names, project names, internal service names, codebase names, environment variable names, domain terms, product names, business entities, or workflow-specific identifiers in committed files.
- This rule applies to examples, diagrams, placeholder names, comments, docs, skill instructions, scripts, config, and final output that describes repo changes.
- Use neutral placeholders such as `<user-focus>`, `<service-a>`, `<repo-a>`, `<method-name>`, `<field-name>`, `<topic-name>`, `example-service`, or `example-repo`.
- Before editing or syncing this repo, scan new text for non-generic names and replace them with neutral placeholders.

## Sync Runtime Instructions

The runtime instruction files carry the **same instructions**, mirrored for different agent runtimes. Whenever you edit ONE of them, you MUST apply the **identical change** to the other in the same turn — no exceptions, no "I'll do the other one later". A reviewer should be able to `diff CLAUDE.md AGENTS.md` and see only the title-line difference (`# Claude instructions` vs. `# Agent instructions`). If the two files drift, agents on different runtimes will follow different rules — that's the bug this rule prevents.

## Neovim configuration

- Neovim config lives under `nvim/` in this repository. The `nvim-config` Makefile target copies it to `~/.config/nvim/` and runs Packer.
- After editing any file under `nvim/**/*.lua`, run from the repository root:

```bash
make nvim-config
```

## Skills

- Reusable skills live under `skills/<skill-name>/SKILL.md`. The `skills-sync` target uses `npx skills` to install all local skills into all supported local agent skill directories.
- After adding or editing anything under `skills/**`, run:

```bash
make skills-sync
```

## Shared scripts (bin)

- CLI helpers live under `bin/` (e.g. `mkws`). The `workspace-bin` target copies `./bin/.` into `~/bin/` and installs shell setup lines from `shell/workspace.sh` into `~/.zshrc`, `~/.bashrc`, and `~/.profile`.
- After adding or editing anything under `bin/**` or `shell/**`, run:

```bash
make workspace-bin
```

## Tmux / Alacritty

- Configs live under `tmux/` and `alacritty/`. Use `make tmux-config` or `make alacritty-config` after edits to install them.

## General

- Prefer editing in this repo, then running the install target — never edit installed copies or symlinks under `~/.config/`, `~/bin/`, or agent skill directories directly, since they're overwritten or relinked on the next sync.
- `make help` lists every target with its description.
