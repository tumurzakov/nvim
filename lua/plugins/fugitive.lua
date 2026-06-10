return {
  {
    "tpope/vim-fugitive",
  },
  {
    "lewis6991/gitsigns.nvim",
    config = function()
      require("gitsigns").setup({})
    end,
  },
  {
    "sindrets/diffview.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diffview: all changes" },
      { "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: file history" },
      { "<leader>gH", "<cmd>DiffviewFileHistory<cr>", desc = "Diffview: branch history" },
      { "<leader>gc", "<cmd>DiffviewClose<cr>", desc = "Diffview: close" },
    },
    opts = {
      enhanced_diff_hl = true,
      default_args = { DiffviewFileHistory = {} },
      view = {
        default = { layout = "diff2_horizontal" },
        merge_tool = { layout = "diff3_mixed" },
      },
      file_panel = {
        listing_style = "tree",
        win_config = { width = 35 },
      },
      file_history_panel = {
        log_options = {
          git = {
            single_file = { follow = false },
            multi_file = {},
          },
        },
      },
    },
    config = function(_, opts)
      require("diffview").setup(opts)

      -- Override DiffviewOpen and DiffviewFileHistory so that `A..B` / `A...B`
      -- ranges auto-resolve to `origin/A`-style refs when the bare name doesn't
      -- exist locally (e.g. only `origin/develop` is fetched, not `develop`).
      local function toplevel()
        local out = vim.fn.systemlist({ "git", "-C", vim.fn.getcwd(), "rev-parse", "--show-toplevel" })
        if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then return out[1] end
        return vim.fn.getcwd()
      end

      local function verify(top, ref)
        vim.fn.systemlist({ "git", "-C", top, "rev-parse", "--verify", "--quiet", ref })
        return vim.v.shell_error == 0
      end

      local function resolve_ref(top, ref)
        if not ref or ref == "" then return ref end
        if verify(top, ref) then return ref end
        if not ref:match("^origin/") and verify(top, "origin/" .. ref) then
          return "origin/" .. ref
        end
        return ref
      end

      local function rewrite_ranges(args)
        local top = toplevel()
        -- Ref token: word/dash/slash chars only — so `--range=A..B` rewrites just A and B,
        -- leaving the `--range=` prefix intact.
        return (args:gsub("([%w_%-/]+)(%.%.%.?)([%w_%-/]+)", function(left, sep, right)
          return resolve_ref(top, left) .. sep .. resolve_ref(top, right)
        end))
      end

      local arg_parser = require("diffview.lazy").require("diffview.arg_parser")
      local diffview = require("diffview.lazy").require("diffview")

      vim.api.nvim_create_user_command("DiffviewOpen", function(ctx)
        local rewritten = rewrite_ranges(ctx.args)
        diffview.open(arg_parser.scan(rewritten).args)
      end, { nargs = "*", complete = function(...) return diffview.completion(...) end })

      vim.api.nvim_create_user_command("DiffviewFileHistory", function(ctx)
        local range
        if ctx.range > 0 then range = { ctx.line1, ctx.line2 } end
        local rewritten = rewrite_ranges(ctx.args)
        diffview.file_history(range, arg_parser.scan(rewritten).args)
      end, { nargs = "*", complete = function(...) return diffview.completion(...) end, range = true })
    end,
  },
}
