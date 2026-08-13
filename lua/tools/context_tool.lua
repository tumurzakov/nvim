-- Factory for CodeCompanion tools that run a python snippet against
-- ~/sources/context/src (email / Teams fetchers). The four tool files were
-- template clones; each is now a declarative spec over this shared shape.
local fmt = string.format

local M = {}

local PYTHON_CMD = "python3"
local CONTEXT_SRC = os.getenv("HOME") .. "/sources/context/src"

---@param spec { name: string, description: string, properties: table?, code: fun(args: table): string, prompt: fun(args: table): string, label: fun(args: table): string, err_prefix: string }
function M.make(spec)
  return {
    name = spec.name,
    cmds = {
      function(self, args)
        -- argv form (no shell): the snippet is passed straight to python -c,
        -- so nothing in it needs shell quoting.
        local code = fmt("import sys; sys.path.insert(0,'%s'); %s", CONTEXT_SRC, spec.code(args or {}))
        local output = vim.fn.system({ PYTHON_CMD, "-c", code })
        if vim.v.shell_error ~= 0 then
          return { status = "error", data = fmt("%s: %s", spec.err_prefix, output) }
        end
        return { status = "success", data = output }
      end,
    },
    schema = {
      type = "function",
      ["function"] = {
        name = spec.name,
        description = spec.description,
        parameters = {
          type = "object",
          properties = spec.properties or {},
        },
      },
    },
    output = {
      prompt = function(self)
        return spec.prompt(self.args or {})
      end,
      success = function(self, tools, cmd, stdout)
        local output = vim.iter(stdout):flatten():join("\n")
        tools.chat:add_tool_output(self, output, spec.label(self.args or {}))
      end,
      error = function(self, tools, cmd, stderr)
        local errors = vim.iter(stderr):flatten():join("\n")
        tools.chat:add_tool_output(self, fmt("%s:\n%s", spec.err_prefix, errors))
      end,
    },
  }
end

return M
