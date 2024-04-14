{
  plugins.undotree.enable = true;
  keymaps = [{
    mode = "n";
    key = "U";
    action = "vim.cmd.UndotreeToggle";
    lua = true;
  }];
}
