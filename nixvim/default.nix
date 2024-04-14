{ pkgs, pkgs-unstable, ... }: {
# Import all your configuration modules here
    imports = [
        ./dap.nix
            ./dracula.nix
            ./indent-blankline.nix
            ./lsp.nix
            ./nvim-tree.nix
            ./oil.nix
            ./rainbow-delimiters.nix
            ./telescope.nix
            ./treesitter.nix
            ./undotree.nix
            ./options.nix
    ];

    }
