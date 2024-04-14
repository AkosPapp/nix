{...}:{
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
    ];

    opts = {
# line numbers
        number = true;
        relativenumber = true;
#options
        nu = true;
        tabstop = 4;
        softtabstop = 4;
        shiftwidth = 4;
        expandtab = true;

        smartindent = true;

        wrap = true;

        swapfile = false;
        backup = false;
        undodir = ''"os.getenv("HOME") .. "/.vim/undodir"'';
        undofile = true;

        hlsearch = false;
        incsearch = true;

        termguicolors = true;

        scrolloff = 8;
        signcolumn = "yes";

        updatetime = 50;

        colorcolumn = "80";
    };
# keybinds
    globals.mapleader = " ";
    keymaps = [
    {
        mode = "n";
        key = "<leader>pv";
        action = ":Ex";
    }


    {
        mode = "n";
        key = "<leader>pn";
        action = ":edit ";
    }

    {
        mode = "n";
        key = "<leader>y";
        action = "\"+y";
    }

    {
        mode = "n";
        key = "<leader>yy";
        action = "\"+yy";

    }

    {
        mode = "n";
        key = "<leader>p";
        action = "\"+p";
    }

    {
        mode = "n";
        key = "<leader>P";
        action = "\"+P";
    }

    {
        mode = "n";
        key = "<leader>q";
        action = ":wa<CR>:q<CR>";
    }

    {
        mode = "n";
        key = "<leader>QQ";
        action = ":q!<CR>";

    }

    {
        mode = "n";
        key = "<leader>w";
        action = ":wa<CR>";

    }

    {
        mode = "n";
        key = "<leader>=";
        action = "gg=G<CO>";
    }
    ];
      }
