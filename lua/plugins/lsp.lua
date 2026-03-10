return {
  "neovim/nvim-lspconfig",
  dependencies = {
    "williamboman/mason.nvim",
    "williamboman/mason-lspconfig.nvim",
  },
  config = function()
    vim.filetype.add({
      filename = { ["go.work"] = "gowork" },
      extension = { gotmpl = "gotmpl" },
    })

    -- Mason setup
    require("mason").setup()
    require("mason-lspconfig").setup({
      ensure_installed = { "pyright", "ruff", "gopls", "jsonls" },
      automatic_installation = true,
    })

    local capabilities = require("cmp_nvim_lsp").default_capabilities()
    local cfg_dir = vim.fn.stdpath("config")
    local function resolve_cmd(bin, args)
      local cmd = { bin }
      vim.list_extend(cmd, args or {})
      return cmd
    end

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

    vim.lsp.config("pyright", {
      cmd = vim.fn.has("win32") == 1
        and { "bash", cfg_dir .. "/bin/pyright-langserver-wrapper" }
        or { cfg_dir .. "/bin/pyright-langserver-wrapper" },
      capabilities = capabilities,
      on_attach = on_attach,
      root_markers = {
        "pyproject.toml",
        "poetry.lock",
        "setup.py",
        "setup.cfg",
        "requirements.txt",
        "Pipfile",
        ".git"
      },
      on_init = function(client)
        local root = client.root_dir
        if not root then return end

        -- Resolve Poetry virtualenv and tell pyright the exact pythonPath
        local poetry_lock = root .. "/poetry.lock"
        if not vim.uv.fs_stat(poetry_lock) then return end

        local result = vim.system(
          { "poetry", "env", "info", "-p" },
          { cwd = root, text = true }
        ):wait()
        if result.code ~= 0 then return end

        local venv = vim.trim(result.stdout)
        if venv == "" or not vim.uv.fs_stat(venv) then return end

        local python = venv .. "/bin/python"
        if vim.fn.has("win32") == 1 then
          python = venv .. "/Scripts/python.exe"
        end

        client.settings = vim.tbl_deep_extend("force", client.settings or {}, {
          python = { pythonPath = python },
        })
        client:notify("workspace/didChangeConfiguration", { settings = client.settings })
      end,
      settings = {
        python = {
          analysis = {
            autoSearchPaths = true,
            useLibraryCodeForTypes = true,
            diagnosticMode = "openFilesOnly",
          },
        },
      },
    })

    vim.lsp.config("ruff", {
      cmd = resolve_cmd("ruff", { "server" }),
      capabilities = capabilities,
      on_attach = on_attach,
    })

    vim.lsp.config("gopls", {
      cmd = resolve_cmd("gopls"),
      filetypes = { "go", "gomod" },
      capabilities = capabilities,
      on_attach = on_attach,
    })

    vim.lsp.config("jsonls", {
      cmd = resolve_cmd("vscode-json-language-server", { "--stdio" }),
      filetypes = { "json", "jsonc" },
      capabilities = vim.tbl_deep_extend("force", capabilities, {
        textDocument = {
          foldingRange = {
            dynamicRegistration = false,
            lineFoldingOnly = true,
          },
        },
      }),
      on_attach = on_attach,
    })

    vim.lsp.enable({ "pyright", "ruff", "gopls", "jsonls" })
    vim.api.nvim_create_autocmd("VimEnter", {
      group = vim.api.nvim_create_augroup("user.lsp.bootstrap", { clear = true }),
      once = true,
      callback = function()
        vim.cmd.doautoall("nvim.lsp.enable FileType")
      end,
    })
  end,
}
