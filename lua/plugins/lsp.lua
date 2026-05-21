return {
  "neovim/nvim-lspconfig",
  dependencies = {
    "williamboman/mason.nvim",
    "williamboman/mason-lspconfig.nvim",
  },
  config = function()
    local ok, settings_local = pcall(require, "config.settings_local")
    local disabled = {}
    if ok and type(settings_local) == "table" and type(settings_local.lsp_disabled) == "table" then
      for _, name in ipairs(settings_local.lsp_disabled) do disabled[name] = true end
    end
    local function enabled(name) return not disabled[name] end
    local function filter(list)
      local out = {}
      for _, name in ipairs(list) do if enabled(name) then out[#out + 1] = name end end
      return out
    end

    vim.filetype.add({
      filename = { ["go.work"] = "gowork" },
      extension = { gotmpl = "gotmpl" },
    })

    -- Mason setup
    require("mason").setup()
    require("mason-lspconfig").setup({
      ensure_installed = filter({ "pyright", "ruff", "gopls", "jsonls" }),
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
        "uv.lock",
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

        local python
        local is_win = vim.fn.has("win32") == 1

        -- uv project: .venv in project root
        local uv_lock = root .. "/uv.lock"
        local uv_venv = root .. "/.venv"
        if vim.uv.fs_stat(uv_lock) and vim.uv.fs_stat(uv_venv) then
          python = is_win and (uv_venv .. "/Scripts/python.exe") or (uv_venv .. "/bin/python")
        else
          -- Poetry project
          local poetry_lock = root .. "/poetry.lock"
          if not vim.uv.fs_stat(poetry_lock) then return end

          local result = vim.system(
            { "poetry", "env", "info", "-p" },
            { cwd = root, text = true }
          ):wait()
          if result.code ~= 0 then return end

          local venv = vim.trim(result.stdout)
          if venv == "" or not vim.uv.fs_stat(venv) then return end
          python = is_win and (venv .. "/Scripts/python.exe") or (venv .. "/bin/python")
        end

        if not python then return end

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

    if enabled("gopls") then
      vim.lsp.config("gopls", {
        cmd = resolve_cmd("gopls"),
        filetypes = { "go", "gomod" },
        capabilities = capabilities,
        on_attach = on_attach,
      })
    end

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

    vim.lsp.enable(filter({ "pyright", "ruff", "gopls", "jsonls" }))
    vim.api.nvim_create_autocmd("VimEnter", {
      group = vim.api.nvim_create_augroup("user.lsp.bootstrap", { clear = true }),
      once = true,
      callback = function()
        vim.cmd.doautoall("nvim.lsp.enable FileType")
      end,
    })
  end,
}
