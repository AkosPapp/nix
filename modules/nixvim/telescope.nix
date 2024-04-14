{
    plugins.telescope.enable = true;
    keymaps = [
{mode="n"; key = "<leader>ff"; action = "require('telescope.builtin').find_files";lua=true;}
{mode="n"; key = "<leader>fg"; action = "require('telescope.builtin').live_grep";lua=true;}
{mode="n"; key = "<leader>fb"; action = "require('telescope.builtin').buffers";lua=true;}
{mode="n"; key = "<leader>fh"; action = "require('telescope.builtin').help_tags";lua=true;}
{mode="n"; key = "<leader>gf"; action = "require('telescope.builtin').git_files";lua=true;}
    ];
}
