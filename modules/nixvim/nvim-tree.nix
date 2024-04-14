{
    plugins.nvim-tree = {
        enable = true;
    };

    keymaps = [
    {mode = "n";key = "<leader>nt";action= ":NvimTreeToggle<CR>";}
    {mode = "n";key = "<leader>nr";action= ":NvimTreeRefresh<CR>";}
    {mode = "n";key = "<leader>nf";action= ":NvimTreeFindFile<CR>";}
    ];
}
