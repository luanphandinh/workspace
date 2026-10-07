# workspace
Install a workspace on your termnial with nvim and tmux.

On Linux, run `make setup` as your normal user. An existing Nix installation is
reused. Fresh installations use single-user Nix without sudo, build users, or a
system daemon. Standard Nix still requires `/nix` to exist and be writable by your
account; an administrator must prepare that directory once if it is missing.
Do not change ownership of an existing shared Nix installation.

Setup keeps your current login shell when running without administrator access.
Run `exec zsh -l` after setup to use the installed shell. Changing the system login
shell is a separate administrator operation. macOS still uses the Nix daemon
installer because single-user installation is not supported there.
