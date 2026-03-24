# Agent instructions (this workspace)

## Neovim configuration

- Neovim config lives under `nvim/` in this repository. The `nvim-config` Makefile target copies it to `~/.config/nvim/` and runs Packer.
- After editing any file under `nvim/**/*.lua`, run from the repository root:

```bash
make nvim-config
```

Do this before considering Neovim-related changes complete so they take effect locally.
