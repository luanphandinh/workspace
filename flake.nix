{
  description = "Workspace terminal and development tool dependencies";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f (import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          }));
      packageList = pkgs:
        let
          commonPackages = with pkgs; [
            bashInteractive
            alacritty
            btop
            curl
            csvlens
            fd
            fontconfig
            fzf
            gcc
            git
            git-lfs
            gnumake
            go
            gopls
            jq
            kitty
            nerd-fonts.fira-code
            neovim
            newsboat
            nodejs
            python3
            ripgrep
            rust-analyzer
            tmux
            tree-sitter
            unzip
            xz
            yazi
            zoxide
            zsh
          ];
          darwinPackages = with pkgs; [
            terminal-notifier
          ];
        in
        commonPackages
        ++ pkgs.lib.optionals pkgs.stdenv.isDarwin darwinPackages;
    in
    {
      packages = forAllSystems (pkgs: {
        workspace-deps = pkgs.buildEnv {
          name = "workspace-deps";
          paths = packageList pkgs;
        };
        default = pkgs.buildEnv {
          name = "workspace-deps";
          paths = packageList pkgs;
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = packageList pkgs;
        };
      });
    };
}
