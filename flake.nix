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
      treeSitterGrammars = pkgs: [
        {
          lang = "go";
          grammar = pkgs.tree-sitter-grammars.tree-sitter-go;
        }
        {
          lang = "json";
          grammar = pkgs.tree-sitter-grammars.tree-sitter-json;
        }
        {
          lang = "bash";
          grammar = pkgs.tree-sitter-grammars.tree-sitter-bash;
        }
        {
          lang = "yaml";
          grammar = pkgs.tree-sitter-grammars.tree-sitter-yaml;
        }
      ];
      nvimTreesitterParsers = pkgs:
        pkgs.runCommand "workspace-nvim-treesitter-parsers" { } ''
          mkdir -p "$out/parser" "$out/queries"
          ${builtins.concatStringsSep "\n" (map (parser: ''
            ln -s ${parser.grammar}/parser "$out/parser/${parser.lang}.so"
            ln -s ${parser.grammar}/queries "$out/queries/${parser.lang}"
          '') (treeSitterGrammars pkgs))}
        '';
      packageList = system: pkgs:
        let
          x86DarwinPkgs = import nixpkgs {
            system = "x86_64-darwin";
            config.allowUnfree = true;
          };
          goPackage =
            if system == "aarch64-darwin"
            then x86DarwinPkgs.go_1_25
            else pkgs.go_1_25;
          treesitterParsersPackage = nvimTreesitterParsers pkgs;
          systemPackages = with pkgs; [
            btop
            newsboat
            tmux
            yazi
          ];
          codingPackages = with pkgs; [
            gcc
            gopls
            nerd-fonts.fira-code
            neovim
            nodejs
            python3
            rust-analyzer
            tree-sitter
          ] ++ [
            goPackage
            treesitterParsersPackage
          ];
          terminalPackages = with pkgs; [
            bashInteractive
            alacritty
            curl
            csvlens
            fd
            fontconfig
            fzf
            git
            git-lfs
            gnumake
            jq
            kitty
            ripgrep
            unzip
            xz
            zoxide
            zsh
          ];
          darwinPackages = with pkgs; [
            terminal-notifier
          ];
          allPackages =
            systemPackages
            ++ codingPackages
            ++ terminalPackages
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin darwinPackages;
        in
        allPackages;
    in
    {
      packages = forAllSystems (pkgs: {
        nvim-treesitter-parsers = nvimTreesitterParsers pkgs;
        workspace-deps = pkgs.buildEnv {
          name = "workspace-deps";
          paths = packageList pkgs.stdenv.hostPlatform.system pkgs;
        };
        default = pkgs.buildEnv {
          name = "workspace-deps";
          paths = packageList pkgs.stdenv.hostPlatform.system pkgs;
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = packageList pkgs.stdenv.hostPlatform.system pkgs;
        };
      });
    };
}
