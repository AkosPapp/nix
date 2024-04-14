{ pkgs, ... }: {
  plugins.dap = { enable = true; };
  extraConfigLuaPost = ''
        local dap = require('dap')

        dap.adapters.gdb = {
            name = "gdb",
            type = "executable",
            command = "${pkgs.lldb}/bin/lldb",
            --args = { "-i", "dap" }
        }

    dap.adapters.cpp = {
        type = "executable",
        command = "${pkgs.gdb}/bin/gdb",
        args = { "-i", "dap" },
        name = "gdb",
    }


    dap.adapters.lldb = {
        name = "${pkgs.gdb}/bin/gdb",
        type = "executable",
        command = "gdb",
        args = { "-i", "dap" }
    }

    local pickers = require("telescope.pickers")
        local finders = require("telescope.finders")
        local conf = require("telescope.config").values
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")
        dap.configurations.cpp = {
            {
                name = "cpp",
                type = "gdb",
                request = "launch",
                program = function()
                    return coroutine.create(function(coro)
                            local opts = {}
                            pickers
                            .new(opts, {
                                prompt_title = "Path to executable",
                                finder = finders.new_oneshot_job({ "fd", "--hidden", "--no-ignore", "--type", "x" }, {}),
                                sorter = conf.generic_sorter(opts),
                                attach_mappings = function(buffer_number)
                                actions.select_default:replace(function()
                                        actions.close(buffer_number)
                                        coroutine.resume(coro, action_state.get_selected_entry()[1])
                                        end)
                                return true
                                end,
                                })
                            :find()
                            end)
                    end,
            },
        }
  '';

  keymaps = [
    {
      mode = "n";
      key = "<leader>lf";
      action = "<cmd>lua vim.lsp.buf.format()<CR>";
    }
    {
      mode = "n";
      key = "<leader>ld";
      action = "<cmd>lua vim.lsp.buf.definition()<CR>";
    }
    {
      mode = "n";
      key = "<leader>lh";
      action = "<cmd>lua vim.lsp.buf.hover()<CR>";
    }
    {
      mode = "n";
      key = "<leader>lr";
      action = "<cmd>lua vim.lsp.buf.references()<CR>";
    }
    {
      mode = "n";
      key = "<leader>ls";
      action = "<cmd>lua vim.lsp.buf.document_symbol()<CR>";
    }
    {
      mode = "n";
      key = "<leader>lw";
      action = "<cmd>lua vim.lsp.buf.workspace_symbol()<CR>";
    }
    {
      mode = "n";
      key = "<leader>lD";
      action = "<cmd>lua vim.lsp.buf.type_definition()<CR>";
    }
    {
      mode = "n";
      key = "<leader>li";
      action = "<cmd>lua vim.lsp.buf.implementation()<CR>";
    }
    {
      mode = "n";
      key = "<leader>lR";
      action = "<cmd>lua vim.lsp.buf.rename()<CR>";
    }
    {
      mode = "n";
      key = "<leader>lca";
      action = "<cmd>lua vim.lsp.buf.code_action()<CR>";
    }
    {
      mode = "n";
      key = "<leader>lwa";
      action = "<cmd>lua vim.lsp.buf.add_workspace_folder()<CR>";
    }
    {
      mode = "n";
      key = "<leader>lwr";
      action = "<cmd>lua vim.lsp.buf.remove_workspace_folder()<CR>";
    }
    {
      mode = "n";
      key = "<leader>lwl";
      action =
        "<cmd>lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))<CR>";
    }
    {
      mode = "n";
      key = "<leader>lq";
      action = "<cmd>lua vim.lsp.diagnostic.set_loclist()<CR>";
    }
    {
      mode = "n";
      key = "<leader>ln";
      action = "<cmd>lua vim.lsp.diagnostic.goto_next()<CR>";
    }
    {
      mode = "n";
      key = "<leader>lp";
      action = "<cmd>lua vim.lsp.diagnostic.goto_prev()<CR>";
    }
    {
      mode = "n";
      key = "<leader>lS";
      action = "<cmd>lua vim.lsp.diagnostic.show_line_diagnostics()<CR>";
    }
    {
      mode = "n";
      key = "<leader>l=";
      action = "<cmd>lua vim.lsp.diagnostic.set_signs()<CR>";
    }
    {
      mode = "n";
      key = "<leader>l0";
      action = "<cmd>lua vim.lsp.diagnostic.set_loclist()<CR>";
    }
  ];
}
