return {
  "neovim/nvim-lspconfig",
  dependencies = {
    "williamboman/mason.nvim",
    "williamboman/mason-lspconfig.nvim",
  },
  config = function()
    -- Mason setup
    require("mason").setup()
    require("mason-lspconfig").setup({
      ensure_installed = { "pyright", "gopls" },
      automatic_installation = true,
    })

    local capabilities = require("cmp_nvim_lsp").default_capabilities()
    local on_attach = function(_, bufnr)
      local opts = { buffer = bufnr, silent = true, noremap = true }
      vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
      vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
      vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
      vim.keymap.set("n", "gi", vim.lsp.buf.implementation, opts)
      vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
      vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
      vim.keymap.set("n", "<leader>f", function()
        vim.lsp.buf.format({ async = true })
      end, opts)
    end

    -- Start servers using vim.lsp.start with lspconfig defaults
    local function start_from_lspconfig(server)
      local ok, cfg = pcall(require, "lspconfig.server_configurations." .. server)
      if not ok then return end
      local default = cfg.default_config or {}
      local name = default.name or server
      local function launch(bufnr)
        local fname = vim.api.nvim_buf_get_name(bufnr)
        local root_dir = default.root_dir and default.root_dir(fname) or vim.loop.cwd()
        if not root_dir or root_dir == "" then root_dir = vim.loop.cwd() end
        for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
          if client.name == name then return end
        end
        local config = vim.tbl_deep_extend("force", default, {
          name = name,
          root_dir = root_dir,
          capabilities = capabilities,
          on_attach = on_attach,
        })
        vim.lsp.start(config)
      end
      return launch
    end

    vim.api.nvim_create_autocmd("FileType", {
      pattern = { "python" },
      callback = function(ev)
        local launch = start_from_lspconfig("pyright")
        if launch then launch(ev.buf) end
      end,
    })

    vim.api.nvim_create_autocmd("FileType", {
      pattern = { "go", "gomod", "gowork" },
      callback = function(ev)
        local launch = start_from_lspconfig("gopls")
        if launch then launch(ev.buf) end
      end,
    })
  end,
}

